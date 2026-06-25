// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Stateless collision processor over DataSystem movement/bounds/response SoA.
//! Broadphase writes range-owned candidate buffers; narrowphase writes
//! range-owned contact buffers; both merge by range index to preserve
//! deterministic contact order before response consumes the stream.

const std = @import("std");
const builtin = @import("builtin");
const AdaptiveWorkProfile = @import("../../app/thread_system.zig").AdaptiveWorkProfile;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const hot_soa_column_alignment = @import("../data_system.zig").hot_soa_column_alignment;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const simd = @import("../../core/simd.zig");
const CollisionContact = @import("../simulation.zig").CollisionContact;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;

pub const collision_range_alignment_items: usize = movement_range_alignment_items;

const HotF32List = std.ArrayListAligned(f32, .fromByteUnits(hot_soa_column_alignment));
const thread_shared_record_alignment: usize = 64;

pub const CollisionConfig = struct {
    items_per_range: ?usize = null,
    broadphase_items_per_range: ?usize = null,
    narrowphase_items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    broadphase_adaptive_tuner: ?*AdaptiveWorkTuner = null,
    narrowphase_adaptive_tuner: ?*AdaptiveWorkTuner = null,
    full_sort_disorder_percent: u8 = 12,
};

pub const CollisionStats = struct {
    body_count: usize = 0,
    contact_count: usize = 0,
    candidate_pair_count: usize = 0,
    broadphase_simd_groups: usize = 0,
    broadphase_batch: BatchStats = .{},
    narrowphase_batch: BatchStats = .{},
    used_full_sort: bool = false,
};

const CandidatePair = struct {
    a: usize,
    b: usize,
};

const BroadphaseRangeBuffer = struct {
    pairs: std.ArrayList(CandidatePair) = .empty,
    required_capacity: usize = 0,
    simd_groups: usize = 0,

    fn clearRetainingCapacity(self: *BroadphaseRangeBuffer) void {
        self.pairs.clearRetainingCapacity();
        self.required_capacity = 0;
        self.simd_groups = 0;
    }

    fn appendCandidateAssumeCapacity(self: *BroadphaseRangeBuffer, pair: CandidatePair) void {
        self.required_capacity += 1;
        if (self.pairs.items.len < self.pairs.capacity) {
            self.pairs.appendAssumeCapacity(pair);
        }
    }

    fn overflowed(self: *const BroadphaseRangeBuffer) bool {
        return self.required_capacity > self.pairs.capacity;
    }

    fn deinit(self: *BroadphaseRangeBuffer, allocator: std.mem.Allocator) void {
        self.pairs.deinit(allocator);
        self.* = undefined;
    }
};

const NarrowphaseRangeBuffer = struct {
    contacts: std.ArrayList(CollisionContact) = .empty,

    fn clearRetainingCapacity(self: *NarrowphaseRangeBuffer) void {
        self.contacts.clearRetainingCapacity();
    }

    fn appendContactAssumeCapacity(self: *NarrowphaseRangeBuffer, contact: CollisionContact) void {
        self.contacts.appendAssumeCapacity(contact);
    }

    fn deinit(self: *NarrowphaseRangeBuffer, allocator: std.mem.Allocator) void {
        self.contacts.deinit(allocator);
        self.* = undefined;
    }
};

const BroadphaseRangeSlot = struct {
    // Each worker writes only its assigned slot. Padding keeps hot append state
    // from sharing cache lines across concurrently written range records.
    buffer: BroadphaseRangeBuffer = .{},
    padding: [paddingForCacheLine(BroadphaseRangeBuffer)]u8 = [_]u8{0} ** paddingForCacheLine(BroadphaseRangeBuffer),
};

const NarrowphaseRangeSlot = struct {
    // Narrowphase has the same ownership contract as broadphase: one range, one
    // slot, merged serially after all workers finish.
    buffer: NarrowphaseRangeBuffer = .{},
    padding: [paddingForCacheLine(NarrowphaseRangeBuffer)]u8 = [_]u8{0} ** paddingForCacheLine(NarrowphaseRangeBuffer),
};

const BroadphaseRangeSlotList = std.ArrayListAligned(BroadphaseRangeSlot, .fromByteUnits(thread_shared_record_alignment));
const NarrowphaseRangeSlotList = std.ArrayListAligned(NarrowphaseRangeSlot, .fromByteUnits(thread_shared_record_alignment));

pub const CollisionSystem = struct {
    allocator: std.mem.Allocator,
    entities: std.ArrayList(EntityId) = .empty,
    movement_indices: std.ArrayList(usize) = .empty,
    min_x: HotF32List = .empty,
    min_y: HotF32List = .empty,
    max_x: HotF32List = .empty,
    max_y: HotF32List = .empty,
    order: std.ArrayList(usize) = .empty,
    broadphase_ranges: BroadphaseRangeSlotList = .empty,
    candidate_pairs: std.ArrayList(CandidatePair) = .empty,
    narrowphase_ranges: NarrowphaseRangeSlotList = .empty,
    broadphase_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    narrowphase_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

    pub fn init(allocator: std.mem.Allocator) CollisionSystem {
        return .{
            .allocator = allocator,
            .broadphase_tuner = AdaptiveWorkTuner.init(.{}),
            .narrowphase_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *CollisionSystem) void {
        for (self.narrowphase_ranges.items) |*slot| {
            slot.buffer.deinit(self.allocator);
        }
        self.narrowphase_ranges.deinit(self.allocator);
        self.candidate_pairs.deinit(self.allocator);
        for (self.broadphase_ranges.items) |*slot| {
            slot.buffer.deinit(self.allocator);
        }
        self.broadphase_ranges.deinit(self.allocator);
        self.order.deinit(self.allocator);
        self.max_y.deinit(self.allocator);
        self.max_x.deinit(self.allocator);
        self.min_y.deinit(self.allocator);
        self.min_x.deinit(self.allocator);
        self.movement_indices.deinit(self.allocator);
        self.entities.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn update(
        self: *CollisionSystem,
        data: *const DataSystem,
        contacts: *RangeOutputStream(CollisionContact),
        thread_system: *ThreadSystem,
        config: CollisionConfig,
    ) !CollisionStats {
        try self.gatherBodies(data);
        const body_count = self.entities.items.len;
        if (body_count <= 1) {
            contacts.clearRetainingCapacity();
            return .{ .body_count = body_count };
        }

        const used_full_sort = self.sortWarm(config.full_sort_disorder_percent);
        var system_config = config;
        if (system_config.adaptive) {
            if (system_config.broadphase_adaptive_tuner == null and system_config.broadphase_items_per_range == null and system_config.items_per_range == null) {
                system_config.broadphase_adaptive_tuner = &self.broadphase_tuner;
            }
            if (system_config.narrowphase_adaptive_tuner == null and system_config.narrowphase_items_per_range == null and system_config.items_per_range == null) {
                system_config.narrowphase_adaptive_tuner = &self.narrowphase_tuner;
            }
        }

        const broadphase_selection = selectStageWork(
            thread_system,
            body_count,
            system_config.broadphase_items_per_range orelse system_config.items_per_range,
            system_config.max_worker_threads,
            system_config.adaptive,
            system_config.broadphase_adaptive_tuner,
        );
        const broadphase = try self.buildBroadphaseCandidatesThreaded(
            thread_system,
            broadphase_selection,
        );
        const candidate_pair_count = self.candidate_pairs.items.len;
        if (broadphase_selection.active_tuner) |tuner| {
            tuner.record(broadphase.batch);
        }
        if (candidate_pair_count == 0) {
            contacts.clearRetainingCapacity();
            return .{
                .body_count = body_count,
                .candidate_pair_count = 0,
                .broadphase_simd_groups = broadphase.simd_groups,
                .broadphase_batch = broadphase.batch,
                .used_full_sort = used_full_sort,
            };
        }

        const narrowphase_selection = selectStageWork(
            thread_system,
            candidate_pair_count,
            system_config.narrowphase_items_per_range orelse system_config.items_per_range,
            system_config.max_worker_threads,
            system_config.adaptive,
            system_config.narrowphase_adaptive_tuner,
        );

        try self.prepareNarrowphaseRangeBuffers(candidate_pair_count, narrowphase_selection.items_per_range, narrowphase_selection.range_count);
        var context = NarrowphaseJobContext{
            .system = self,
        };
        const narrowphase_batch = thread_system.parallelForWithOptions(candidate_pair_count, &context, narrowphaseContactsJob, .{
            .max_worker_threads = narrowphase_selection.worker_threads,
            .range_alignment_items = collision_range_alignment_items,
            .adaptive_tuner = narrowphase_selection.active_tuner,
            .selected_profile = narrowphase_selection.profile,
        });
        const contact_count = try self.mergeNarrowphaseContacts(contacts, narrowphase_selection.range_count);

        return .{
            .body_count = body_count,
            .contact_count = contact_count,
            .candidate_pair_count = candidate_pair_count,
            .broadphase_simd_groups = broadphase.simd_groups,
            .broadphase_batch = broadphase.batch,
            .narrowphase_batch = narrowphase_batch,
            .used_full_sort = used_full_sort,
        };
    }

    pub fn updateSerial(
        self: *CollisionSystem,
        data: *const DataSystem,
        contacts: *RangeOutputStream(CollisionContact),
    ) !CollisionStats {
        try self.gatherBodies(data);
        const body_count = self.entities.items.len;
        if (body_count <= 1) {
            contacts.clearRetainingCapacity();
            return .{ .body_count = body_count };
        }
        const used_full_sort = self.sortWarm(100);
        const broadphase = try self.buildBroadphaseCandidatesSimd();
        const candidate_pair_count = self.candidate_pairs.items.len;
        if (candidate_pair_count == 0) {
            contacts.clearRetainingCapacity();
            return .{
                .body_count = body_count,
                .candidate_pair_count = 0,
                .broadphase_simd_groups = broadphase.simd_groups,
                .broadphase_batch = serialBatch(body_count),
                .used_full_sort = used_full_sort,
            };
        }

        try self.prepareNarrowphaseRangeBuffers(candidate_pair_count, candidate_pair_count, 1);
        const range = ParallelRange{ .index = 0, .start = 0, .end = candidate_pair_count };
        writeNarrowphaseContactsSimd(self, range);
        const contact_count = try self.mergeNarrowphaseContacts(contacts, 1);

        return .{
            .body_count = body_count,
            .contact_count = contact_count,
            .candidate_pair_count = candidate_pair_count,
            .broadphase_simd_groups = broadphase.simd_groups,
            .broadphase_batch = serialBatch(body_count),
            .narrowphase_batch = serialBatch(candidate_pair_count),
            .used_full_sort = used_full_sort,
        };
    }

    pub fn bodyCount(self: *const CollisionSystem) usize {
        return self.entities.items.len;
    }

    fn gatherBodies(self: *CollisionSystem, data: *const DataSystem) !void {
        const bounds = data.collisionBoundsSliceConst();
        self.clearProxiesRetainingCapacity();
        try self.ensureProxyCapacity(bounds.entities.len);

        for (bounds.entities, 0..) |entity, bounds_index| {
            const movement_index = data.movementBodyDenseIndex(entity) orelse continue;
            const body = data.movementBodyConst(entity) orelse continue;
            const offset_x = bounds.offset_x[bounds_index];
            const offset_y = bounds.offset_y[bounds_index];
            const size_x = bounds.size_x[bounds_index];
            const size_y = bounds.size_y[bounds_index];
            const min_x = body.position.x + offset_x;
            const min_y = body.position.y + offset_y;
            self.entities.appendAssumeCapacity(entity);
            self.movement_indices.appendAssumeCapacity(movement_index);
            self.min_x.appendAssumeCapacity(min_x);
            self.min_y.appendAssumeCapacity(min_y);
            self.max_x.appendAssumeCapacity(min_x + size_x);
            self.max_y.appendAssumeCapacity(min_y + size_y);
        }
        try self.ensureOrder();
    }

    fn clearProxiesRetainingCapacity(self: *CollisionSystem) void {
        self.entities.clearRetainingCapacity();
        self.movement_indices.clearRetainingCapacity();
        self.min_x.clearRetainingCapacity();
        self.min_y.clearRetainingCapacity();
        self.max_x.clearRetainingCapacity();
        self.max_y.clearRetainingCapacity();
    }

    fn ensureProxyCapacity(self: *CollisionSystem, capacity: usize) !void {
        try self.entities.ensureTotalCapacity(self.allocator, capacity);
        try self.movement_indices.ensureTotalCapacity(self.allocator, capacity);
        try self.min_x.ensureTotalCapacity(self.allocator, capacity);
        try self.min_y.ensureTotalCapacity(self.allocator, capacity);
        try self.max_x.ensureTotalCapacity(self.allocator, capacity);
        try self.max_y.ensureTotalCapacity(self.allocator, capacity);
    }

    fn ensureOrder(self: *CollisionSystem) !void {
        const count = self.entities.items.len;
        if (self.order.items.len == count) return;
        self.order.clearRetainingCapacity();
        try self.order.ensureTotalCapacity(self.allocator, count);
        for (0..count) |index| {
            self.order.appendAssumeCapacity(index);
        }
    }

    fn prepareNarrowphaseRangeBuffers(self: *CollisionSystem, candidate_pair_count: usize, items_per_range: usize, range_count: usize) !void {
        try self.narrowphase_ranges.ensureTotalCapacity(self.allocator, range_count);
        while (self.narrowphase_ranges.items.len < range_count) {
            self.narrowphase_ranges.appendAssumeCapacity(.{});
        }
        for (self.narrowphase_ranges.items[0..range_count], 0..) |*slot, range_index| {
            const buffer = &slot.buffer;
            buffer.clearRetainingCapacity();
            try buffer.contacts.ensureTotalCapacity(
                self.allocator,
                rangeLenForIndex(candidate_pair_count, items_per_range, range_index),
            );
        }
    }

    fn mergeNarrowphaseContacts(
        self: *CollisionSystem,
        contacts: *RangeOutputStream(CollisionContact),
        range_count: usize,
    ) !usize {
        try contacts.prepareRangeCounts(range_count);
        var contact_count: usize = 0;
        for (self.narrowphase_ranges.items[0..range_count], 0..) |*slot, range_index| {
            const count = slot.buffer.contacts.items.len;
            contacts.addCount(range_index, count);
            contact_count += count;
        }
        try contacts.prefix();
        for (self.narrowphase_ranges.items[0..range_count], 0..) |*slot, range_index| {
            var writer = contacts.rangeWriter(range_index);
            for (slot.buffer.contacts.items) |contact| {
                writer.write(contact);
            }
            writer.finish();
        }
        contacts.finishWrite();
        return contact_count;
    }

    fn prepareBroadphaseRangeBuffers(self: *CollisionSystem, range_count: usize) !void {
        try self.broadphase_ranges.ensureTotalCapacity(self.allocator, range_count);
        while (self.broadphase_ranges.items.len < range_count) {
            self.broadphase_ranges.appendAssumeCapacity(.{});
        }
    }

    fn reserveInitialBroadphaseRangeCapacity(self: *CollisionSystem, selection: StageWorkSelection) !void {
        const sorted_count = self.order.items.len;
        for (self.broadphase_ranges.items[0..selection.range_count], 0..) |*slot, range_index| {
            const buffer = &slot.buffer;
            if (buffer.pairs.capacity != 0) continue;
            const range_len = rangeLenForIndex(sorted_count, selection.items_per_range, range_index);
            const estimated_capacity = if (range_len > std.math.maxInt(usize) / 4)
                std.math.maxInt(usize)
            else
                range_len * 4;
            const target_capacity = @min(sorted_count, @max(simd.lane_count, estimated_capacity));
            try buffer.pairs.ensureTotalCapacity(self.allocator, target_capacity);
        }
    }

    fn growBroadphaseRangeBuffersIfNeeded(self: *CollisionSystem, range_count: usize) !bool {
        var grew = false;
        for (self.broadphase_ranges.items[0..range_count]) |*slot| {
            const buffer = &slot.buffer;
            if (buffer.overflowed()) {
                try buffer.pairs.ensureTotalCapacity(self.allocator, buffer.required_capacity);
                grew = true;
            }
        }
        return grew;
    }

    fn mergeBroadphaseRangeBuffers(self: *CollisionSystem, range_count: usize) !void {
        self.candidate_pairs.clearRetainingCapacity();
        var total: usize = 0;
        for (self.broadphase_ranges.items[0..range_count]) |*slot| {
            const buffer = &slot.buffer;
            total += buffer.pairs.items.len;
        }
        try self.candidate_pairs.ensureTotalCapacity(self.allocator, total);
        for (self.broadphase_ranges.items[0..range_count]) |*slot| {
            const buffer = &slot.buffer;
            const start = self.candidate_pairs.items.len;
            self.candidate_pairs.items.len = start + buffer.pairs.items.len;
            @memcpy(self.candidate_pairs.items[start..][0..buffer.pairs.items.len], buffer.pairs.items);
        }
    }

    fn broadphaseSimdGroupCount(self: *const CollisionSystem, range_count: usize) usize {
        var total: usize = 0;
        for (self.broadphase_ranges.items[0..range_count]) |*slot| {
            total += slot.buffer.simd_groups;
        }
        return total;
    }

    fn sortWarm(self: *CollisionSystem, full_sort_disorder_percent: u8) bool {
        if (self.order.items.len <= 1) return false;
        const max_percent = @min(full_sort_disorder_percent, @as(u8, 100));
        const inversion_count = self.adjacentInversionCount();
        if (inversion_count == 0) return false;
        // Movement between fixed steps is usually small, so insertion sort keeps
        // the sweep order warm. Full sort is reserved for genuinely disordered
        // frames where insertion sort would become the expensive path.
        const full_sort = @as(u128, inversion_count) * 100 > @as(u128, self.order.items.len) * max_percent;
        if (full_sort) {
            std.mem.sort(usize, self.order.items, self, proxyIndexLessThan);
            return true;
        }
        self.insertionSortOrder();
        return false;
    }

    fn adjacentInversionCount(self: *const CollisionSystem) usize {
        var inversions: usize = 0;
        for (1..self.order.items.len) |index| {
            if (proxyIndexLessThan(self, self.order.items[index], self.order.items[index - 1])) {
                inversions += 1;
            }
        }
        return inversions;
    }

    fn insertionSortOrder(self: *CollisionSystem) void {
        var index: usize = 1;
        while (index < self.order.items.len) : (index += 1) {
            const value = self.order.items[index];
            var insert = index;
            while (insert > 0 and proxyIndexLessThan(self, value, self.order.items[insert - 1])) : (insert -= 1) {
                self.order.items[insert] = self.order.items[insert - 1];
            }
            self.order.items[insert] = value;
        }
    }

    fn buildBroadphaseCandidatesSimd(self: *CollisionSystem) !BroadphaseStats {
        self.candidate_pairs.clearRetainingCapacity();
        var stats = BroadphaseStats{};
        const sorted_count = self.order.items.len;
        for (0..sorted_count) |sorted_index| {
            const proxy_index = self.order.items[sorted_index];
            const proxy_max_x = self.max_x.items[proxy_index];
            const proxy_min_y = self.min_y.items[proxy_index];
            const proxy_max_y = self.max_y.items[proxy_index];
            var candidate_sorted_index = sorted_index + 1;

            while (candidate_sorted_index + simd.lane_count <= sorted_count) {
                var candidate_indices: [simd.lane_count]usize = undefined;
                inline for (0..simd.lane_count) |lane| {
                    candidate_indices[lane] = self.order.items[candidate_sorted_index + lane];
                }
                const candidate_min_x = simd.gatherFloat4(self.min_x.items, candidate_indices);
                const x_active = candidate_min_x < simd.splatFloat4(proxy_max_x);
                if (!x_active[0]) break;

                const candidate_min_y = simd.gatherFloat4(self.min_y.items, candidate_indices);
                const candidate_max_y = simd.gatherFloat4(self.max_y.items, candidate_indices);
                const overlaps = x_active & (simd.splatFloat4(proxy_max_y) > candidate_min_y) & (candidate_max_y > simd.splatFloat4(proxy_min_y));
                inline for (0..simd.lane_count) |lane| {
                    if (overlaps[lane]) {
                        try self.candidate_pairs.append(self.allocator, .{ .a = proxy_index, .b = candidate_indices[lane] });
                    }
                }
                stats.simd_groups += 1;
                candidate_sorted_index += simd.lane_count;
                if (!x_active[simd.lane_count - 1]) break;
            }

            while (candidate_sorted_index < sorted_count) : (candidate_sorted_index += 1) {
                const candidate_index = self.order.items[candidate_sorted_index];
                if (self.min_x.items[candidate_index] >= proxy_max_x) break;
                if (overlapsY(self, proxy_index, candidate_index)) {
                    try self.candidate_pairs.append(self.allocator, .{ .a = proxy_index, .b = candidate_index });
                }
            }
        }
        return stats;
    }

    fn buildBroadphaseCandidatesThreaded(
        self: *CollisionSystem,
        thread_system: *ThreadSystem,
        selection: StageWorkSelection,
    ) !BroadphaseBuildResult {
        try self.prepareBroadphaseRangeBuffers(selection.range_count);
        try self.reserveInitialBroadphaseRangeCapacity(selection);

        var context = BroadphaseJobContext{ .system = self };
        var result = BroadphaseBuildResult{};
        while (true) {
            for (self.broadphase_ranges.items[0..selection.range_count]) |*slot| {
                slot.buffer.clearRetainingCapacity();
            }
            const batch = thread_system.parallelForWithOptions(self.order.items.len, &context, broadphaseCandidatesJob, .{
                .max_worker_threads = selection.worker_threads,
                .range_alignment_items = collision_range_alignment_items,
                .selected_profile = selection.profile,
            });
            result.batch = if (result.batch.item_count == 0 and result.batch.range_count == 0)
                batch
            else
                combineStageBatches(result.batch, batch);

            // Broadphase jobs do not allocate. If a range overflows its warmed
            // buffer, grow after the batch and replay the stage deterministically.
            if (try self.growBroadphaseRangeBuffersIfNeeded(selection.range_count)) {
                continue;
            }

            result.simd_groups = self.broadphaseSimdGroupCount(selection.range_count);
            try self.mergeBroadphaseRangeBuffers(selection.range_count);
            return result;
        }
    }
};

const BroadphaseStats = struct {
    simd_groups: usize = 0,
};

const BroadphaseBuildResult = struct {
    simd_groups: usize = 0,
    batch: BatchStats = .{},
};

const BroadphaseJobContext = struct {
    system: *CollisionSystem,
};

fn broadphaseCandidatesJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *BroadphaseJobContext = @ptrCast(@alignCast(context));
    writeBroadphaseRangeCandidatesSimd(job.system, range);
}

fn writeBroadphaseRangeCandidatesSimd(system: *CollisionSystem, range: ParallelRange) void {
    const sorted_count = system.order.items.len;
    const buffer = &system.broadphase_ranges.items[range.index].buffer;

    for (range.start..range.end) |sorted_index| {
        const proxy_index = system.order.items[sorted_index];
        const proxy_max_x = system.max_x.items[proxy_index];
        const proxy_min_y = system.min_y.items[proxy_index];
        const proxy_max_y = system.max_y.items[proxy_index];
        var candidate_sorted_index = sorted_index + 1;

        while (candidate_sorted_index + simd.lane_count <= sorted_count) {
            var candidate_indices: [simd.lane_count]usize = undefined;
            inline for (0..simd.lane_count) |lane| {
                candidate_indices[lane] = system.order.items[candidate_sorted_index + lane];
            }
            const candidate_min_x = simd.gatherFloat4(system.min_x.items, candidate_indices);
            const x_active = candidate_min_x < simd.splatFloat4(proxy_max_x);
            if (!x_active[0]) break;

            const candidate_min_y = simd.gatherFloat4(system.min_y.items, candidate_indices);
            const candidate_max_y = simd.gatherFloat4(system.max_y.items, candidate_indices);
            const overlaps = x_active & (simd.splatFloat4(proxy_max_y) > candidate_min_y) & (candidate_max_y > simd.splatFloat4(proxy_min_y));
            inline for (0..simd.lane_count) |lane| {
                if (overlaps[lane]) {
                    buffer.appendCandidateAssumeCapacity(.{ .a = proxy_index, .b = candidate_indices[lane] });
                }
            }
            buffer.simd_groups += 1;
            candidate_sorted_index += simd.lane_count;
            if (!x_active[simd.lane_count - 1]) break;
        }

        while (candidate_sorted_index < sorted_count) : (candidate_sorted_index += 1) {
            const candidate_index = system.order.items[candidate_sorted_index];
            if (system.min_x.items[candidate_index] >= proxy_max_x) break;
            if (overlapsY(system, proxy_index, candidate_index)) {
                buffer.appendCandidateAssumeCapacity(.{ .a = proxy_index, .b = candidate_index });
            }
        }
    }
}

const NarrowphaseJobContext = struct {
    system: *CollisionSystem,
};

fn narrowphaseContactsJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *NarrowphaseJobContext = @ptrCast(@alignCast(context));
    writeNarrowphaseContactsSimd(job.system, range);
}

fn writeNarrowphaseContactsSimd(system: *CollisionSystem, range: ParallelRange) void {
    const buffer = &system.narrowphase_ranges.items[range.index].buffer;
    var index = range.start;
    const zero = simd.splatFloat4(0);
    const one = simd.splatFloat4(1);
    const negative_one = simd.splatFloat4(-1);

    while (index + simd.lane_count <= range.end) : (index += simd.lane_count) {
        var a_indices: [simd.lane_count]usize = undefined;
        var b_indices: [simd.lane_count]usize = undefined;
        inline for (0..simd.lane_count) |lane| {
            const pair = system.candidate_pairs.items[index + lane];
            a_indices[lane] = pair.a;
            b_indices[lane] = pair.b;
        }

        const a_min_x = simd.gatherFloat4(system.min_x.items, a_indices);
        const a_max_x = simd.gatherFloat4(system.max_x.items, a_indices);
        const a_min_y = simd.gatherFloat4(system.min_y.items, a_indices);
        const a_max_y = simd.gatherFloat4(system.max_y.items, a_indices);
        const b_min_x = simd.gatherFloat4(system.min_x.items, b_indices);
        const b_max_x = simd.gatherFloat4(system.max_x.items, b_indices);
        const b_min_y = simd.gatherFloat4(system.min_y.items, b_indices);
        const b_max_y = simd.gatherFloat4(system.max_y.items, b_indices);

        const overlap_left = a_max_x - b_min_x;
        const overlap_right = b_max_x - a_min_x;
        const overlap_x = @min(overlap_left, overlap_right);
        const overlap_top = a_max_y - b_min_y;
        const overlap_bottom = b_max_y - a_min_y;
        const overlap_y = @min(overlap_top, overlap_bottom);
        const valid = (overlap_x > zero) & (overlap_y > zero);
        const use_x_axis = overlap_x <= overlap_y;
        const a_center_x = (a_min_x + a_max_x) * simd.splatFloat4(0.5);
        const b_center_x = (b_min_x + b_max_x) * simd.splatFloat4(0.5);
        const a_center_y = (a_min_y + a_max_y) * simd.splatFloat4(0.5);
        const b_center_y = (b_min_y + b_max_y) * simd.splatFloat4(0.5);
        const normal_x = simd.selectFloat4(use_x_axis, simd.selectFloat4(a_center_x <= b_center_x, negative_one, one), zero);
        const normal_y = simd.selectFloat4(use_x_axis, zero, simd.selectFloat4(a_center_y <= b_center_y, negative_one, one));
        const penetration = simd.selectFloat4(use_x_axis, overlap_x, overlap_y);

        inline for (0..simd.lane_count) |lane| {
            if (valid[lane]) {
                buffer.appendContactAssumeCapacity(
                    contactForResolved(
                        system,
                        a_indices[lane],
                        b_indices[lane],
                        normal_x[lane],
                        normal_y[lane],
                        penetration[lane],
                    ),
                );
            }
        }
    }

    while (index < range.end) : (index += 1) {
        const pair = system.candidate_pairs.items[index];
        if (contactForCandidate(system, pair.a, pair.b)) |contact| {
            buffer.appendContactAssumeCapacity(contact);
        }
    }
}

fn overlapsY(system: *const CollisionSystem, a: usize, b: usize) bool {
    return system.max_y.items[a] > system.min_y.items[b] and system.max_y.items[b] > system.min_y.items[a];
}

fn contactForCandidate(system: *const CollisionSystem, a: usize, b: usize) ?CollisionContact {
    const overlap_left = system.max_x.items[a] - system.min_x.items[b];
    const overlap_right = system.max_x.items[b] - system.min_x.items[a];
    const overlap_x = @min(overlap_left, overlap_right);
    const overlap_top = system.max_y.items[a] - system.min_y.items[b];
    const overlap_bottom = system.max_y.items[b] - system.min_y.items[a];
    const overlap_y = @min(overlap_top, overlap_bottom);
    if (overlap_x <= 0 or overlap_y <= 0) return null;

    var normal_x: f32 = 0;
    var normal_y: f32 = 0;
    var penetration = overlap_x;
    if (overlap_x <= overlap_y) {
        const center_a = (system.min_x.items[a] + system.max_x.items[a]) * 0.5;
        const center_b = (system.min_x.items[b] + system.max_x.items[b]) * 0.5;
        normal_x = if (center_a <= center_b) -1 else 1;
    } else {
        const center_a = (system.min_y.items[a] + system.max_y.items[a]) * 0.5;
        const center_b = (system.min_y.items[b] + system.max_y.items[b]) * 0.5;
        normal_y = if (center_a <= center_b) -1 else 1;
        penetration = overlap_y;
    }

    return contactForResolved(system, a, b, normal_x, normal_y, penetration);
}

fn contactForResolved(
    system: *const CollisionSystem,
    a: usize,
    b: usize,
    normal_x: f32,
    normal_y: f32,
    penetration: f32,
) CollisionContact {
    return .{
        .a = system.entities.items[a],
        .b = system.entities.items[b],
        .a_movement_index = system.movement_indices.items[a],
        .b_movement_index = system.movement_indices.items[b],
        .normal_x = normal_x,
        .normal_y = normal_y,
        .penetration = penetration,
    };
}

fn proxyIndexLessThan(system: *const CollisionSystem, lhs: usize, rhs: usize) bool {
    const lhs_min_x = system.min_x.items[lhs];
    const rhs_min_x = system.min_x.items[rhs];
    if (lhs_min_x != rhs_min_x) return lhs_min_x < rhs_min_x;
    const lhs_min_y = system.min_y.items[lhs];
    const rhs_min_y = system.min_y.items[rhs];
    if (lhs_min_y != rhs_min_y) return lhs_min_y < rhs_min_y;
    const lhs_entity = system.entities.items[lhs];
    const rhs_entity = system.entities.items[rhs];
    if (lhs_entity.index != rhs_entity.index) return lhs_entity.index < rhs_entity.index;
    return lhs_entity.generation < rhs_entity.generation;
}

const StageWorkSelection = struct {
    profile: AdaptiveWorkProfile,
    items_per_range: usize,
    worker_threads: usize,
    range_count: usize,
    active_tuner: ?*AdaptiveWorkTuner = null,
};

fn selectStageWork(
    thread_system: *const ThreadSystem,
    item_count: usize,
    items_per_range_override: ?usize,
    max_worker_threads_override: ?usize,
    adaptive: bool,
    adaptive_tuner: ?*AdaptiveWorkTuner,
) StageWorkSelection {
    const available_workers = thread_system.workerThreadCount();
    const max_worker_threads = @min(max_worker_threads_override orelse available_workers, available_workers);
    const requested_items_per_range = items_per_range_override orelse thread_system.config.items_per_range;
    const active_tuner = if (adaptive and items_per_range_override == null and max_worker_threads > 0)
        adaptive_tuner
    else
        null;
    const profile = if (active_tuner) |tuner|
        tuner.selectProfile(.{
            .item_count = item_count,
            .available_worker_threads = available_workers,
            .max_worker_threads = max_worker_threads,
            .fallback_items_per_range = requested_items_per_range,
            .range_alignment_items = collision_range_alignment_items,
        })
    else
        AdaptiveWorkProfile{
            .worker_threads = max_worker_threads,
            .items_per_range = requested_items_per_range,
        };
    const aligned_items_per_range = alignItemCount(@max(profile.items_per_range, @as(usize, 1)), collision_range_alignment_items);
    const selected_range_count = rangeCount(item_count, aligned_items_per_range);
    const selected_worker_threads = if (selected_range_count <= 1)
        @as(usize, 0)
    else
        @min(profile.worker_threads, @min(max_worker_threads, selected_range_count - 1));
    const items_per_range = if (selected_worker_threads == 0 and active_tuner != null and profile.worker_threads == 0)
        item_count
    else
        aligned_items_per_range;

    return .{
        .profile = .{
            .worker_threads = selected_worker_threads,
            .items_per_range = items_per_range,
        },
        .items_per_range = items_per_range,
        .worker_threads = selected_worker_threads,
        .range_count = rangeCount(item_count, items_per_range),
        .active_tuner = active_tuner,
    };
}

fn paddingForCacheLine(comptime T: type) usize {
    const rem = @sizeOf(T) % thread_shared_record_alignment;
    return if (rem == 0) 0 else thread_shared_record_alignment - rem;
}

fn rangeLenForIndex(item_count: usize, items_per_range: usize, range_index: usize) usize {
    const start = range_index * items_per_range;
    if (start >= item_count) return 0;
    return @min(start + items_per_range, item_count) - start;
}

fn serialBatch(item_count: usize) BatchStats {
    return .{
        .item_count = item_count,
        .range_count = if (item_count > 0) 1 else 0,
        .items_per_range = item_count,
        .range_alignment_items = collision_range_alignment_items,
        .main_thread_ranges = if (item_count > 0) 1 else 0,
        .ran_inline = true,
    };
}

fn combineStageBatches(first: BatchStats, second: BatchStats) BatchStats {
    const total_range_count = first.range_count + second.range_count;
    const total_worker_ranges = first.worker_thread_ranges + second.worker_thread_ranges;
    const active_worker_threads = @max(first.active_worker_threads, second.active_worker_threads);
    const worker_utilization = if (total_range_count == 0 or active_worker_threads == 0)
        @as(f32, 0)
    else
        @as(f32, @floatFromInt(total_worker_ranges)) / @as(f32, @floatFromInt(total_range_count));

    return .{
        .item_count = first.item_count,
        .range_count = total_range_count,
        .items_per_range = first.items_per_range,
        .range_alignment_items = first.range_alignment_items,
        .available_worker_threads = @max(first.available_worker_threads, second.available_worker_threads),
        .active_worker_threads = active_worker_threads,
        .main_thread_ranges = first.main_thread_ranges + second.main_thread_ranges,
        .worker_thread_ranges = total_worker_ranges,
        .worker_utilization = worker_utilization,
        .batch_duration_ns = first.batch_duration_ns + second.batch_duration_ns,
        .main_thread_wait_ns = first.main_thread_wait_ns + second.main_thread_wait_ns,
        .ran_inline = first.ran_inline and second.ran_inline,
    };
}

fn addBody(data: *DataSystem, position_x: f32, position_y: f32, size: f32) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = position_x, .y = position_y },
        .previous_position = .{ .x = position_x, .y = position_y },
        .velocity = .{},
        .speed = 0,
    });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = size, .y = size } });
    return entity;
}

test "collision contacts are stable and reject non-overlaps" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try addBody(&data, 0, 0, 10);
    const second = try addBody(&data, 8, 2, 10);
    _ = try addBody(&data, 30, 30, 4);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const stats = try system.updateSerial(&data, &contacts);

    try std.testing.expectEqual(@as(usize, 3), stats.body_count);
    try std.testing.expectEqual(@as(usize, 1), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 1), stats.contact_count);
    try std.testing.expectEqual(@as(usize, 1), stats.broadphase_batch.range_count);
    try std.testing.expectEqual(@as(usize, 1), stats.broadphase_batch.main_thread_ranges);
    try std.testing.expectEqual(@as(usize, 1), stats.narrowphase_batch.range_count);
    try std.testing.expectEqual(@as(usize, 1), stats.narrowphase_batch.main_thread_ranges);
    const merged = contacts.mergedItems();
    try std.testing.expectEqual(first.index, merged[0].a.index);
    try std.testing.expectEqual(second.index, merged[0].b.index);
    try std.testing.expectEqual(@as(f32, -1), merged[0].normal_x);
    try std.testing.expectEqual(@as(f32, 0), merged[0].normal_y);
    try std.testing.expectApproxEqAbs(@as(f32, 2), merged[0].penetration, 0.001);
}

test "collision broadphase filters y misses before narrowphase" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addBody(&data, 0, 0, 5);
    _ = try addBody(&data, 3, 20, 5);
    _ = try addBody(&data, 4, 1, 5);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const stats = try system.updateSerial(&data, &contacts);

    try std.testing.expectEqual(@as(usize, 1), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 1), stats.contact_count);
}

test "collision broadphase uses simd groups while preserving contact order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try addBody(&data, 0, 0, 10);
    const second = try addBody(&data, 1, -9, 10);
    _ = try addBody(&data, 2, 40, 10);
    const fourth = try addBody(&data, 3, 9, 10);
    _ = try addBody(&data, 4, 60, 10);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const stats = try system.updateSerial(&data, &contacts);
    const merged = contacts.mergedItems();

    try std.testing.expect(stats.broadphase_simd_groups > 0);
    try std.testing.expectEqual(@as(usize, 2), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 2), stats.contact_count);
    try std.testing.expectEqual(first.index, merged[0].a.index);
    try std.testing.expectEqual(second.index, merged[0].b.index);
    try std.testing.expectEqual(first.index, merged[1].a.index);
    try std.testing.expectEqual(fourth.index, merged[1].b.index);
}

test "warm sorted collision order skips repair when already ordered" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..16) |index| {
        _ = try addBody(&data, @floatFromInt(index * 16), 0, 8);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const first = try system.updateSerial(&data, &contacts);
    const second = try system.updateSerial(&data, &contacts);

    try std.testing.expect(!first.used_full_sort);
    try std.testing.expect(!second.used_full_sort);
    try std.testing.expectEqual(@as(usize, 0), second.candidate_pair_count);
}

test "threaded collision matches serial contact order" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var serial_data = DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    var threaded_data = DataSystem.init(std.testing.allocator);
    defer threaded_data.deinit();

    for (0..64) |index| {
        const x: f32 = @floatFromInt((index % 16) * 6);
        const y: f32 = @floatFromInt((index / 16) * 6);
        _ = try addBody(&serial_data, x, y, 8);
        _ = try addBody(&threaded_data, x, y, 8);
    }

    var serial_system = CollisionSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    var threaded_system = CollisionSystem.init(std.testing.allocator);
    defer threaded_system.deinit();
    var serial_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer serial_contacts.deinit();
    var threaded_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer threaded_contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = collision_range_alignment_items,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    _ = try serial_system.updateSerial(&serial_data, &serial_contacts);
    const threaded_stats = try threaded_system.update(&threaded_data, &threaded_contacts, &threads, .{
        .items_per_range = collision_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    try std.testing.expect(!threaded_stats.broadphase_batch.ran_inline);
    try std.testing.expect(!threaded_stats.narrowphase_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 64), threaded_stats.broadphase_batch.item_count);
    try std.testing.expectEqual(threaded_stats.candidate_pair_count, threaded_stats.narrowphase_batch.item_count);
    const serial_items = serial_contacts.mergedItems();
    const threaded_items = threaded_contacts.mergedItems();
    try std.testing.expectEqual(serial_items.len, threaded_items.len);
    for (serial_items, threaded_items) |serial, threaded| {
        try std.testing.expectEqual(serial.a.index, threaded.a.index);
        try std.testing.expectEqual(serial.b.index, threaded.b.index);
        try std.testing.expectEqual(serial.a_movement_index, threaded.a_movement_index);
        try std.testing.expectEqual(serial.b_movement_index, threaded.b_movement_index);
        try std.testing.expectEqual(serial.normal_x, threaded.normal_x);
        try std.testing.expectEqual(serial.normal_y, threaded.normal_y);
        try std.testing.expectApproxEqAbs(serial.penetration, threaded.penetration, 0.001);
    }
}

test "narrowphase range buffers merge deterministic contacts and skip rejected candidates" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try addBody(&data, 0, 0, 10);
    const second = try addBody(&data, 5, 0, 10);
    _ = try addBody(&data, 50, 50, 4);
    const fourth = try addBody(&data, 6, 1, 10);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.gatherBodies(&data);
    try system.candidate_pairs.append(std.testing.allocator, .{ .a = 0, .b = 1 });
    try system.candidate_pairs.append(std.testing.allocator, .{ .a = 0, .b = 2 });
    try system.candidate_pairs.append(std.testing.allocator, .{ .a = 0, .b = 3 });
    try system.prepareNarrowphaseRangeBuffers(system.candidate_pairs.items.len, 2, 2);

    writeNarrowphaseContactsSimd(&system, .{ .index = 0, .start = 0, .end = 2 });
    writeNarrowphaseContactsSimd(&system, .{ .index = 1, .start = 2, .end = 3 });

    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const contact_count = try system.mergeNarrowphaseContacts(&contacts, 2);
    const merged = contacts.mergedItems();

    try std.testing.expectEqual(@as(usize, 2), contact_count);
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqual(first.index, merged[0].a.index);
    try std.testing.expectEqual(second.index, merged[0].b.index);
    try std.testing.expectEqual(first.index, merged[1].a.index);
    try std.testing.expectEqual(fourth.index, merged[1].b.index);
}

test "thread-written collision range scratch uses cache-line sized slots" {
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(BroadphaseRangeSlot) % thread_shared_record_alignment);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(NarrowphaseRangeSlot) % thread_shared_record_alignment);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.prepareBroadphaseRangeBuffers(2);
    try system.prepareNarrowphaseRangeBuffers(8, 4, 2);

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.broadphase_ranges.items.ptr) % thread_shared_record_alignment);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.narrowphase_ranges.items.ptr) % thread_shared_record_alignment);
}

test "threaded broadphase prewarms empty range buffers before dispatch" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..64) |index| {
        const x: f32 = @floatFromInt((index % 16) * 4);
        const y: f32 = @floatFromInt((index / 16) * 4);
        _ = try addBody(&data, x, y, 8);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = collision_range_alignment_items,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const stats = try system.update(&data, &contacts, &threads, .{
        .items_per_range = collision_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    const expected_broadphase_ranges = rangeCount(stats.body_count, collision_range_alignment_items);
    try std.testing.expectEqual(expected_broadphase_ranges, stats.broadphase_batch.range_count);
    try std.testing.expect(stats.candidate_pair_count > 0);
}

test "collision update reuses warmed scratch without steady state allocation" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..32) |index| {
        _ = try addBody(&data, @floatFromInt(index * 2), 0, 4);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try system.updateSerial(&data, &contacts);

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const fail = failing_allocator.allocator();
    system.allocator = fail;
    contacts.allocator = fail;
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }

    const stats = try system.updateSerial(&data, &contacts);
    try std.testing.expectEqual(@as(usize, 32), stats.body_count);
    try std.testing.expect(contacts.mergedItems().len > 0);
}

test "threaded collision update reuses warmed range scratch without steady state allocation" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..32) |index| {
        const x: f32 = @floatFromInt((index % 8) * 3);
        const y: f32 = @floatFromInt((index / 8) * 3);
        _ = try addBody(&data, x, y, 6);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = collision_range_alignment_items,
    });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    _ = try system.update(&data, &contacts, &threads, .{
        .items_per_range = collision_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const fail = failing_allocator.allocator();
    system.allocator = fail;
    contacts.allocator = fail;
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }

    const stats = try system.update(&data, &contacts, &threads, .{
        .items_per_range = collision_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    try std.testing.expectEqual(@as(usize, 32), stats.body_count);
    try std.testing.expect(contacts.mergedItems().len > 0);
}

test "collision scratch columns are cache-line aligned" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..collision_range_alignment_items + 1) |index| {
        _ = try addBody(&data, @floatFromInt(index * 4), 0, 6);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try system.updateSerial(&data, &contacts);

    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.min_x.items.ptr) % hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.min_y.items.ptr) % hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.max_x.items.ptr) % hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(system.max_y.items.ptr) % hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, 0), simd.vectorizedEnd(system.bodyCount()) % simd.lane_count);
}
