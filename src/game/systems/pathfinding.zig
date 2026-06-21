// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Frame-delayed grid pathfinding system.
//! Owns transient request queues, result caches, nav-grid state, fixed scratch,
//! and stage tuners. Fixed-step update is allocation-free after reserve/rebuild.

const std = @import("std");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const PathAgentClass = @import("../simulation.zig").PathAgentClass;
const PathRequest = @import("../simulation.zig").PathRequest;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;

pub const pathfinding_range_alignment_items: usize = simd.lane_count;

const default_cell_size: f32 = 32.0;
const default_max_frame_requests: usize = 1024;
const default_max_pending_requests: usize = 1024;
const default_max_cached_results: usize = 1024;
const default_max_goal_fields: usize = 8;
const default_max_worker_scratch_slots: usize = 64;
const default_max_solved_requests_per_step: usize = 128;
pub const default_max_fallback_requests_per_step: usize = 128;
const no_parent: usize = std.math.maxInt(usize);
const no_component: u32 = 0;
const diagonal_cost: u32 = 14;
const cardinal_cost: u32 = 10;
const unreachable_cost: u32 = std.math.maxInt(u32);

pub const PathStatus = enum {
    missing,
    pending,
    available,
    unavailable,
};

pub const PathView = struct {
    status: PathStatus = .missing,
    next_waypoint: math.Vec2 = .{},
    path_len: usize = 0,
};

pub const GridCell = struct {
    x: i32,
    y: i32,
};

pub const PathQueryKey = struct {
    nav_version: u32,
    agent_class: PathAgentClass,
    start: GridCell,
    goal: GridCell,
};

const GoalKey = struct {
    nav_version: u32,
    agent_class: PathAgentClass,
    goal: GridCell,
};

pub const PathfindingCapacity = struct {
    max_frame_requests: usize = default_max_frame_requests,
    max_pending_requests: usize = default_max_pending_requests,
    max_cached_results: usize = default_max_cached_results,
    max_goal_fields: usize = default_max_goal_fields,
    max_worker_scratch_slots: usize = default_max_worker_scratch_slots,
    max_solved_requests_per_step: usize = default_max_solved_requests_per_step,
    max_fallback_requests_per_step: usize = default_max_fallback_requests_per_step,
};

pub const PathfindingConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    field_result_adaptive_tuner: ?*AdaptiveWorkTuner = null,
    fallback_adaptive_tuner: ?*AdaptiveWorkTuner = null,
    max_solved_requests_per_step: ?usize = null,
    max_fallback_requests_per_step: ?usize = null,
};

pub const PathfindingStats = struct {
    accepted_requests: usize = 0,
    duplicate_requests: usize = 0,
    pending_requests: usize = 0,
    solved_requests: usize = 0,
    field_requests: usize = 0,
    fallback_requests: usize = 0,
    available_results: usize = 0,
    unavailable_results: usize = 0,
    dropped_requests: usize = 0,
    deferred_requests: usize = 0,
    fallback_deferred_requests: usize = 0,
    cache_hits: usize = 0,
    field_cache_hits: usize = 0,
    goal_fields_built: usize = 0,
    goal_fields_reused: usize = 0,
    cache_evictions: usize = 0,
    field_result_batch: BatchStats = .{},
    fallback_batch: BatchStats = .{},

    pub fn solveBatch(self: PathfindingStats) BatchStats {
        return if (self.fallback_batch.item_count != 0) self.fallback_batch else self.field_result_batch;
    }
};

const PreparedRequest = struct {
    entity: EntityId,
    key: PathQueryKey,
};

const PendingRequest = struct {
    entity: EntityId,
    key: PathQueryKey,
};

const PathResult = struct {
    key: PathQueryKey,
    next_waypoint: math.Vec2,
    path_len: usize,
};

const EntityPathResult = struct {
    entity: EntityId,
    key: PathQueryKey,
    status: PathStatus,
    next_waypoint: math.Vec2 = .{},
    path_len: usize = 0,
};

const PathSolveResult = union(enum) {
    available: PathResult,
    unavailable: PathQueryKey,
    deferred: PathQueryKey,
};

const GoalGroup = struct {
    key: GoalKey,
    count: usize = 0,
};

const OpenNode = struct {
    index: usize,
    f: u32,
    h: u32,
};

const Portal = struct {
    a: usize,
    b: usize,
};

const NavGrid = struct {
    cell_size: f32 = default_cell_size,
    width: usize = 0,
    height: usize = 0,
    version: u32 = 1,
    blocked_count: usize = 0,
    blocked: std.ArrayList(bool) = .empty,
    components: std.ArrayList(u32) = .empty,
    component_queue: std.ArrayList(usize) = .empty,
    portals: std.ArrayList(Portal) = .empty,

    fn deinit(self: *NavGrid, allocator: std.mem.Allocator) void {
        self.portals.deinit(allocator);
        self.component_queue.deinit(allocator);
        self.components.deinit(allocator);
        self.blocked.deinit(allocator);
        self.* = undefined;
    }

    fn rebuild(self: *NavGrid, allocator: std.mem.Allocator, data: *const DataSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) !void {
        self.cell_size = cell_size;
        self.width = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(bounds_width / cell_size))));
        self.height = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(bounds_height / cell_size))));
        const cell_count = self.cellCount();

        try self.blocked.ensureTotalCapacity(allocator, cell_count);
        try self.components.ensureTotalCapacity(allocator, cell_count);
        try self.component_queue.ensureTotalCapacity(allocator, cell_count);
        try self.portals.ensureTotalCapacity(allocator, cell_count);
        self.blocked.items.len = cell_count;
        self.components.items.len = cell_count;
        @memset(self.blocked.items, false);
        @memset(self.components.items, no_component);
        self.blocked_count = 0;
        self.component_queue.clearRetainingCapacity();
        self.portals.clearRetainingCapacity();

        const bounds = data.collisionBoundsSliceConst();
        const responses = data.collisionResponseSliceConst();
        for (responses.entities, 0..) |entity, response_index| {
            if (responses.mobilities[response_index] != .static) continue;
            const bounds_index = collisionBoundsIndex(bounds.entities, entity) orelse continue;
            const body = data.movementBodyConst(entity) orelse continue;
            const min_x = body.position.x + bounds.offset_x[bounds_index];
            const min_y = body.position.y + bounds.offset_y[bounds_index];
            const max_x = min_x + bounds.size_x[bounds_index];
            const max_y = min_y + bounds.size_y[bounds_index];
            self.markBlockedRectSimd(min_x, min_y, max_x, max_y);
        }

        self.version +%= 1;
        if (self.version == 0) self.version = 1;
        self.buildComponentsAndWaypoints();
    }

    fn cellCount(self: *const NavGrid) usize {
        return self.width * self.height;
    }

    fn valid(self: *const NavGrid) bool {
        return self.width != 0 and self.height != 0 and self.blocked.items.len == self.cellCount();
    }

    fn keyForWorld(self: *const NavGrid, start: math.Vec2, goal: math.Vec2, agent_class: PathAgentClass) ?PathQueryKey {
        if (!self.valid()) return null;
        return .{
            .nav_version = self.version,
            .agent_class = agent_class,
            .start = self.worldToCellClamped(start),
            .goal = self.worldToCellClamped(goal),
        };
    }

    fn goalKey(key: PathQueryKey) GoalKey {
        return .{ .nav_version = key.nav_version, .agent_class = key.agent_class, .goal = key.goal };
    }

    fn worldToCellClamped(self: *const NavGrid, value: math.Vec2) GridCell {
        const max_x: i32 = @intCast(self.width - 1);
        const max_y: i32 = @intCast(self.height - 1);
        const raw_x: i32 = @intFromFloat(@floor(value.x / self.cell_size));
        const raw_y: i32 = @intFromFloat(@floor(value.y / self.cell_size));
        return .{
            .x = std.math.clamp(raw_x, 0, max_x),
            .y = std.math.clamp(raw_y, 0, max_y),
        };
    }

    fn cellCenter(self: *const NavGrid, index: usize) math.Vec2 {
        const x = index % self.width;
        const y = index / self.width;
        return .{
            .x = (@as(f32, @floatFromInt(x)) + 0.5) * self.cell_size,
            .y = (@as(f32, @floatFromInt(y)) + 0.5) * self.cell_size,
        };
    }

    fn indexForCell(self: *const NavGrid, cell: GridCell) ?usize {
        if (cell.x < 0 or cell.y < 0) return null;
        const x: usize = @intCast(cell.x);
        const y: usize = @intCast(cell.y);
        if (x >= self.width or y >= self.height) return null;
        return y * self.width + x;
    }

    fn isBlockedIndex(self: *const NavGrid, index: usize) bool {
        std.debug.assert(index < self.blocked.items.len);
        return self.blocked.items[index];
    }

    fn isBlockedCell(self: *const NavGrid, cell: GridCell) bool {
        const index = self.indexForCell(cell) orelse return true;
        return self.isBlockedIndex(index);
    }

    fn markBlockedRectSimd(self: *NavGrid, min_x: f32, min_y: f32, max_x: f32, max_y: f32) void {
        if (!self.valid()) return;
        const min_cell = self.worldToCellClamped(.{ .x = min_x, .y = min_y });
        const max_cell = self.worldToCellClamped(.{ .x = @max(min_x, max_x - 0.001), .y = @max(min_y, max_y - 0.001) });
        const row_start: usize = @intCast(@min(min_cell.y, max_cell.y));
        const row_end: usize = @intCast(@max(min_cell.y, max_cell.y));
        const col_start_i = @min(min_cell.x, max_cell.x);
        const col_end_i = @max(min_cell.x, max_cell.x);
        const col_start: usize = @intCast(col_start_i);
        const col_end: usize = @intCast(col_end_i);
        const col_end_vec = simd.splatInt4(@intCast(col_end_i));

        var y = row_start;
        while (y <= row_end) : (y += 1) {
            var x = col_start;
            while (x + simd.lane_count <= col_end + 1) : (x += simd.lane_count) {
                const lanes = simd.int4(@intCast(x), @intCast(x + 1), @intCast(x + 2), @intCast(x + 3));
                const active = lanes <= col_end_vec;
                inline for (0..simd.lane_count) |lane| {
                    if (active[lane]) self.markBlockedIndex(y * self.width + x + lane);
                }
            }
            while (x <= col_end) : (x += 1) {
                self.markBlockedIndex(y * self.width + x);
            }
        }
    }

    fn markBlockedIndex(self: *NavGrid, index: usize) void {
        if (!self.blocked.items[index]) {
            self.blocked.items[index] = true;
            self.blocked_count += 1;
        }
    }

    fn buildComponentsAndWaypoints(self: *NavGrid) void {
        @memset(self.components.items, no_component);
        self.component_queue.clearRetainingCapacity();
        self.portals.clearRetainingCapacity();

        var next_component: u32 = 1;
        for (self.blocked.items, 0..) |blocked, index| {
            if (blocked or self.components.items[index] != no_component) continue;
            self.floodComponent(index, next_component);
            next_component +%= 1;
            if (next_component == no_component) next_component = 1;
        }

        self.buildPortals();
    }

    fn floodComponent(self: *NavGrid, start_index: usize, component: u32) void {
        self.component_queue.clearRetainingCapacity();
        self.component_queue.appendAssumeCapacity(start_index);
        self.components.items[start_index] = component;
        var read_index: usize = 0;
        while (read_index < self.component_queue.items.len) : (read_index += 1) {
            const current = self.component_queue.items[read_index];
            const current_x: i32 = @intCast(current % self.width);
            const current_y: i32 = @intCast(current / self.width);
            for (neighbor_dirs) |dir| {
                const next_cell = GridCell{ .x = current_x + dir.x, .y = current_y + dir.y };
                const next_index = self.indexForCell(next_cell) orelse continue;
                if (self.blocked.items[next_index] or self.components.items[next_index] != no_component) continue;
                if (dir.diagonal and (self.isBlockedCell(.{ .x = current_x + dir.x, .y = current_y }) or self.isBlockedCell(.{ .x = current_x, .y = current_y + dir.y }))) {
                    continue;
                }
                self.components.items[next_index] = component;
                self.component_queue.appendAssumeCapacity(next_index);
            }
        }
    }

    fn connected(self: *const NavGrid, a: usize, b: usize) bool {
        return self.components.items[a] != no_component and self.components.items[a] == self.components.items[b];
    }

    fn buildPortals(self: *NavGrid) void {
        if (self.blocked_count == 0) return;
        for (self.blocked.items, 0..) |blocked, index| {
            if (blocked) continue;
            const x: i32 = @intCast(index % self.width);
            const y: i32 = @intCast(index / self.width);
            if (self.isBlockedCell(.{ .x = x, .y = y - 1 }) and self.isBlockedCell(.{ .x = x, .y = y + 1 })) {
                self.addPortalCells(.{ .x = x - 1, .y = y }, .{ .x = x + 1, .y = y });
            }
            if (self.isBlockedCell(.{ .x = x - 1, .y = y }) and self.isBlockedCell(.{ .x = x + 1, .y = y })) {
                self.addPortalCells(.{ .x = x, .y = y - 1 }, .{ .x = x, .y = y + 1 });
            }
        }
    }

    fn addPortalCells(self: *NavGrid, a_cell: GridCell, b_cell: GridCell) void {
        const a = self.indexForCell(a_cell) orelse return;
        const b = self.indexForCell(b_cell) orelse return;
        if (self.blocked.items[a] or self.blocked.items[b]) return;
        if (!self.connected(a, b)) return;
        if (self.portals.items.len >= self.portals.capacity) return;
        self.portals.appendAssumeCapacity(.{ .a = a, .b = b });
    }
};

const KeySet = struct {
    slots: std.ArrayList(KeySetSlot) = .empty,
    len: usize = 0,

    fn deinit(self: *KeySet, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *KeySet, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.slots.ensureTotalCapacity(allocator, capacity);
        self.slots.items.len = capacity;
        self.clear();
    }

    fn clear(self: *KeySet) void {
        for (self.slots.items) |*slot| slot.occupied = false;
        self.len = 0;
    }

    fn contains(self: *const KeySet, key: PathQueryKey) bool {
        return self.findIndex(key) != null;
    }

    fn insert(self: *KeySet, key: PathQueryKey) bool {
        const capacity = self.slots.items.len;
        if (capacity == 0) return false;
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.key, key)) return true;
            if (!slot.occupied and self.len < capacity) {
                self.slots.items[index] = .{ .occupied = true, .key = key };
                self.len += 1;
                return true;
            }
        }
        return false;
    }

    fn findIndex(self: *const KeySet, key: PathQueryKey) ?usize {
        const capacity = self.slots.items.len;
        if (capacity == 0) return null;
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.key, key)) return index;
            if (!slot.occupied and self.len < capacity) return null;
        }
        return null;
    }
};

const KeySetSlot = struct {
    occupied: bool = false,
    key: PathQueryKey = emptyKey(0),
};

const ResultCache = struct {
    slots: std.ArrayList(ResultCacheSlot) = .empty,
    len: usize = 0,
    next_evict: usize = 0,

    fn deinit(self: *ResultCache, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.slots.ensureTotalCapacity(allocator, capacity);
        self.slots.items.len = capacity;
        self.clear();
    }

    fn clear(self: *ResultCache) void {
        for (self.slots.items) |*slot| slot.occupied = false;
        self.len = 0;
        self.next_evict = 0;
    }

    fn find(self: *const ResultCache, key: PathQueryKey) ?PathResult {
        const capacity = self.slots.items.len;
        if (capacity == 0) return null;
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.result.key, key)) return slot.result;
            if (!slot.occupied and self.len < capacity) return null;
        }
        return null;
    }

    fn put(self: *ResultCache, result: PathResult, stats: *PathfindingStats) void {
        const capacity = self.slots.items.len;
        if (capacity == 0) return;
        const start = hashPathKey(result.key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.result.key, result.key)) {
                self.slots.items[index].result = result;
                return;
            }
            if (!slot.occupied and self.len < capacity) {
                self.slots.items[index] = .{ .occupied = true, .result = result };
                self.len += 1;
                return;
            }
        }
        self.slots.items[self.next_evict] = .{ .occupied = true, .result = result };
        self.next_evict = (self.next_evict + 1) % capacity;
        stats.cache_evictions += 1;
    }
};

const ResultCacheSlot = struct {
    occupied: bool = false,
    result: PathResult = .{ .key = emptyKey(0), .next_waypoint = .{}, .path_len = 0 },
};

const EntityResultCache = struct {
    slots: std.ArrayList(EntityResultCacheSlot) = .empty,
    len: usize = 0,
    next_evict: usize = 0,

    fn deinit(self: *EntityResultCache, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *EntityResultCache, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.slots.ensureTotalCapacity(allocator, capacity);
        self.slots.items.len = capacity;
        self.clear();
    }

    fn clear(self: *EntityResultCache) void {
        for (self.slots.items) |*slot| slot.occupied = false;
        self.len = 0;
        self.next_evict = 0;
    }

    fn find(self: *const EntityResultCache, entity: EntityId, key: PathQueryKey) ?EntityPathResult {
        const capacity = self.slots.items.len;
        if (capacity == 0) return null;
        const start = hashEntity(entity) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and entityEqual(slot.result.entity, entity)) {
                if (keysEqual(slot.result.key, key)) return slot.result;
                return null;
            }
            if (!slot.occupied and self.len < capacity) return null;
        }
        return null;
    }

    fn put(self: *EntityResultCache, result: EntityPathResult, stats: *PathfindingStats) void {
        const capacity = self.slots.items.len;
        if (capacity == 0) return;
        const start = hashEntity(result.entity) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and entityEqual(slot.result.entity, result.entity)) {
                self.slots.items[index].result = result;
                return;
            }
            if (!slot.occupied and self.len < capacity) {
                self.slots.items[index] = .{ .occupied = true, .result = result };
                self.len += 1;
                return;
            }
        }
        self.slots.items[self.next_evict] = .{ .occupied = true, .result = result };
        self.next_evict = (self.next_evict + 1) % capacity;
        stats.cache_evictions += 1;
    }
};

const EntityResultCacheSlot = struct {
    occupied: bool = false,
    result: EntityPathResult = .{
        .entity = .{ .index = 0, .generation = 0 },
        .key = emptyKey(0),
        .status = .missing,
    },
};

const GoalField = struct {
    occupied: bool = false,
    key: GoalKey = emptyGoalKey(0),
    generation: u32 = 1,
    costs: std.ArrayList(u32) = .empty,
    stamps: std.ArrayList(u32) = .empty,
    heap: std.ArrayList(OpenNode) = .empty,

    fn deinit(self: *GoalField, allocator: std.mem.Allocator) void {
        self.heap.deinit(allocator);
        self.stamps.deinit(allocator);
        self.costs.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *GoalField, allocator: std.mem.Allocator, cell_count: usize) !void {
        try self.costs.ensureTotalCapacity(allocator, cell_count);
        try self.stamps.ensureTotalCapacity(allocator, cell_count);
        try self.heap.ensureTotalCapacity(allocator, cell_count);
        self.costs.items.len = cell_count;
        self.stamps.items.len = cell_count;
        @memset(self.costs.items, unreachable_cost);
        @memset(self.stamps.items, 0);
        self.heap.clearRetainingCapacity();
    }

    fn build(self: *GoalField, grid: *const NavGrid, key: GoalKey) bool {
        const goal_index = grid.indexForCell(key.goal) orelse return false;
        if (grid.isBlockedIndex(goal_index)) return false;
        self.occupied = false;
        self.key = key;
        self.nextGeneration();
        self.heap.clearRetainingCapacity();
        self.setCost(goal_index, 0);
        self.heapPush(.{ .index = goal_index, .f = 0, .h = 0 }) catch return false;

        while (self.heap.items.len != 0) {
            const current = self.heapPop();
            if (self.cost(current.index) != current.f) continue;
            const current_x: i32 = @intCast(current.index % grid.width);
            const current_y: i32 = @intCast(current.index / grid.width);
            for (neighbor_dirs) |dir| {
                const next_cell = GridCell{ .x = current_x + dir.x, .y = current_y + dir.y };
                const next_index = grid.indexForCell(next_cell) orelse continue;
                if (grid.isBlockedIndex(next_index)) continue;
                if (dir.diagonal and (grid.isBlockedCell(.{ .x = current_x + dir.x, .y = current_y }) or grid.isBlockedCell(.{ .x = current_x, .y = current_y + dir.y }))) {
                    continue;
                }
                const step_cost = if (dir.diagonal) diagonal_cost else cardinal_cost;
                const candidate = current.f + step_cost;
                if (candidate >= self.cost(next_index)) continue;
                self.setCost(next_index, candidate);
                self.heapPush(.{ .index = next_index, .f = candidate, .h = 0 }) catch return false;
            }
        }
        self.occupied = true;
        return true;
    }

    fn resultFor(self: *const GoalField, grid: *const NavGrid, key: PathQueryKey) ?PathResult {
        const start_index = grid.indexForCell(key.start) orelse return null;
        const goal_index = grid.indexForCell(key.goal) orelse return null;
        if (self.cost(start_index) == unreachable_cost) return null;
        if (start_index == goal_index) {
            return .{ .key = key, .next_waypoint = grid.cellCenter(goal_index), .path_len = 1 };
        }
        var best_index = no_parent;
        var best_cost = self.cost(start_index);
        const start_x: i32 = @intCast(start_index % grid.width);
        const start_y: i32 = @intCast(start_index / grid.width);
        for (neighbor_dirs) |dir| {
            const next_cell = GridCell{ .x = start_x + dir.x, .y = start_y + dir.y };
            const next_index = grid.indexForCell(next_cell) orelse continue;
            const next_cost = self.cost(next_index);
            if (next_cost >= best_cost) continue;
            if (dir.diagonal and (grid.isBlockedCell(.{ .x = start_x + dir.x, .y = start_y }) or grid.isBlockedCell(.{ .x = start_x, .y = start_y + dir.y }))) {
                continue;
            }
            best_cost = next_cost;
            best_index = next_index;
        }
        if (best_index == no_parent) return null;
        return .{
            .key = key,
            .next_waypoint = grid.cellCenter(best_index),
            .path_len = @max(@as(usize, 2), @as(usize, best_cost / cardinal_cost + 1)),
        };
    }

    fn cost(self: *const GoalField, index: usize) u32 {
        return if (self.stamps.items[index] == self.generation) self.costs.items[index] else unreachable_cost;
    }

    fn setCost(self: *GoalField, index: usize, value: u32) void {
        self.stamps.items[index] = self.generation;
        self.costs.items[index] = value;
    }

    fn nextGeneration(self: *GoalField) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.stamps.items, 0);
            self.generation = 1;
        }
    }

    fn heapPush(self: *GoalField, node: OpenNode) !void {
        if (self.heap.items.len >= self.heap.capacity) return error.OutOfMemory;
        self.heap.appendAssumeCapacity(node);
        siftUp(self.heap.items, self.heap.items.len - 1);
    }

    fn heapPop(self: *GoalField) OpenNode {
        const result = self.heap.items[0];
        const last = self.heap.items.len - 1;
        self.heap.items[0] = self.heap.items[last];
        self.heap.items.len = last;
        if (self.heap.items.len != 0) siftDown(self.heap.items, 0);
        return result;
    }
};

const SearchScratch = struct {
    generation: u32 = 1,
    open: std.ArrayList(OpenNode) = .empty,
    touched: std.ArrayList(usize) = .empty,
    g_costs: std.ArrayList(u32) = .empty,
    parents: std.ArrayList(usize) = .empty,
    g_stamps: std.ArrayList(u32) = .empty,
    closed_stamps: std.ArrayList(u32) = .empty,

    fn deinit(self: *SearchScratch, allocator: std.mem.Allocator) void {
        self.closed_stamps.deinit(allocator);
        self.g_stamps.deinit(allocator);
        self.parents.deinit(allocator);
        self.g_costs.deinit(allocator);
        self.touched.deinit(allocator);
        self.open.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *SearchScratch, allocator: std.mem.Allocator, cell_count: usize) !void {
        try self.open.ensureTotalCapacity(allocator, cell_count);
        try self.touched.ensureTotalCapacity(allocator, cell_count);
        try self.g_costs.ensureTotalCapacity(allocator, cell_count);
        try self.parents.ensureTotalCapacity(allocator, cell_count);
        try self.g_stamps.ensureTotalCapacity(allocator, cell_count);
        try self.closed_stamps.ensureTotalCapacity(allocator, cell_count);
        self.g_costs.items.len = cell_count;
        self.parents.items.len = cell_count;
        self.g_stamps.items.len = cell_count;
        self.closed_stamps.items.len = cell_count;
        @memset(self.g_costs.items, unreachable_cost);
        @memset(self.parents.items, no_parent);
        @memset(self.g_stamps.items, 0);
        @memset(self.closed_stamps.items, 0);
        self.open.clearRetainingCapacity();
        self.touched.clearRetainingCapacity();
    }

    fn reset(self: *SearchScratch) void {
        self.open.clearRetainingCapacity();
        self.touched.clearRetainingCapacity();
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.g_stamps.items, 0);
            @memset(self.closed_stamps.items, 0);
            self.generation = 1;
        }
    }

    fn g(self: *const SearchScratch, index: usize) u32 {
        return if (self.g_stamps.items[index] == self.generation) self.g_costs.items[index] else unreachable_cost;
    }

    fn setG(self: *SearchScratch, index: usize, value: u32) void {
        if (self.g_stamps.items[index] != self.generation) {
            self.g_stamps.items[index] = self.generation;
            self.parents.items[index] = no_parent;
            self.touched.appendAssumeCapacity(index);
        }
        self.g_costs.items[index] = value;
    }

    fn closed(self: *const SearchScratch, index: usize) bool {
        return self.closed_stamps.items[index] == self.generation;
    }

    fn close(self: *SearchScratch, index: usize) void {
        self.closed_stamps.items[index] = self.generation;
    }

    fn pushOpen(self: *SearchScratch, node: OpenNode) bool {
        if (self.open.items.len >= self.open.capacity) return false;
        self.open.appendAssumeCapacity(node);
        siftUp(self.open.items, self.open.items.len - 1);
        return true;
    }

    fn popOpen(self: *SearchScratch) OpenNode {
        const result = self.open.items[0];
        const last = self.open.items.len - 1;
        self.open.items[0] = self.open.items[last];
        self.open.items.len = last;
        if (self.open.items.len != 0) siftDown(self.open.items, 0);
        return result;
    }
};

pub const PathfindingSystem = struct {
    allocator: std.mem.Allocator,
    capacity: PathfindingCapacity = .{},
    grid: NavGrid = .{},
    pending: std.ArrayList(PendingRequest) = .empty,
    prepared_requests: std.ArrayList(PreparedRequest) = .empty,
    solve_results: std.ArrayList(PathSolveResult) = .empty,
    fallback_indices: std.ArrayList(usize) = .empty,
    groups: std.ArrayList(GoalGroup) = .empty,
    entity_results: EntityResultCache = .{},
    completed: ResultCache = .{},
    unavailable: KeySet = .{},
    pending_keys: KeySet = .{},
    goal_fields: std.ArrayList(GoalField) = .empty,
    scratch_slots: std.ArrayList(SearchScratch) = .empty,
    next_field_evict: usize = 0,
    field_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    fallback_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

    pub fn init(allocator: std.mem.Allocator) PathfindingSystem {
        return .{
            .allocator = allocator,
            .field_tuner = AdaptiveWorkTuner.init(.{}),
            .fallback_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *PathfindingSystem) void {
        for (self.scratch_slots.items) |*scratch| scratch.deinit(self.allocator);
        for (self.goal_fields.items) |*field| field.deinit(self.allocator);
        self.scratch_slots.deinit(self.allocator);
        self.goal_fields.deinit(self.allocator);
        self.pending_keys.deinit(self.allocator);
        self.unavailable.deinit(self.allocator);
        self.completed.deinit(self.allocator);
        self.entity_results.deinit(self.allocator);
        self.groups.deinit(self.allocator);
        self.fallback_indices.deinit(self.allocator);
        self.solve_results.deinit(self.allocator);
        self.prepared_requests.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.grid.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reserve(self: *PathfindingSystem, capacity: PathfindingCapacity) !void {
        self.capacity = capacity;
        try self.pending.ensureTotalCapacity(self.allocator, capacity.max_pending_requests);
        try self.prepared_requests.ensureTotalCapacity(self.allocator, capacity.max_frame_requests);
        try self.solve_results.ensureTotalCapacity(self.allocator, capacity.max_solved_requests_per_step);
        try self.fallback_indices.ensureTotalCapacity(self.allocator, capacity.max_solved_requests_per_step);
        try self.groups.ensureTotalCapacity(self.allocator, capacity.max_solved_requests_per_step);
        try self.entity_results.reserve(self.allocator, capacity.max_cached_results);
        try self.completed.reserve(self.allocator, capacity.max_cached_results);
        try self.unavailable.reserve(self.allocator, capacity.max_cached_results);
        try self.pending_keys.reserve(self.allocator, capacity.max_pending_requests * 2);
        try self.goal_fields.ensureTotalCapacity(self.allocator, capacity.max_goal_fields);
        while (self.goal_fields.items.len < capacity.max_goal_fields) {
            self.goal_fields.appendAssumeCapacity(.{});
        }
        try self.scratch_slots.ensureTotalCapacity(self.allocator, capacity.max_worker_scratch_slots);
        while (self.scratch_slots.items.len < capacity.max_worker_scratch_slots) {
            self.scratch_slots.appendAssumeCapacity(.{});
        }
    }

    pub fn rebuildStaticNavGrid(self: *PathfindingSystem, data: *const DataSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) !void {
        if (self.goal_fields.items.len == 0 or self.scratch_slots.items.len == 0) {
            try self.reserve(self.capacity);
        }
        try self.grid.rebuild(self.allocator, data, bounds_width, bounds_height, cell_size);
        const cell_count = self.grid.cellCount();
        for (self.goal_fields.items) |*field| {
            try field.reserve(self.allocator, cell_count);
            field.occupied = false;
        }
        for (self.scratch_slots.items) |*scratch| {
            try scratch.reserve(self.allocator, cell_count);
        }
        self.clearRuntimeState();
    }

    pub fn clearRuntimeState(self: *PathfindingSystem) void {
        self.pending.clearRetainingCapacity();
        self.prepared_requests.clearRetainingCapacity();
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.entity_results.clear();
        self.completed.clear();
        self.unavailable.clear();
        self.pending_keys.clear();
        for (self.goal_fields.items) |*field| field.occupied = false;
        self.next_field_evict = 0;
    }

    pub fn clearTransientRequestsRetainingFields(self: *PathfindingSystem) void {
        self.pending.clearRetainingCapacity();
        self.prepared_requests.clearRetainingCapacity();
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        self.groups.clearRetainingCapacity();
        self.entity_results.clear();
        self.completed.clear();
        self.unavailable.clear();
        self.pending_keys.clear();
    }

    pub fn statusForWorld(self: *const PathfindingSystem, start: math.Vec2, goal: math.Vec2, agent_class: PathAgentClass) PathView {
        const key = self.grid.keyForWorld(start, goal, agent_class) orelse return .{ .status = .unavailable };
        return self.statusForKey(key);
    }

    pub fn statusForEntityWorld(self: *const PathfindingSystem, entity: EntityId, start: math.Vec2, goal: math.Vec2, agent_class: PathAgentClass) PathView {
        const key = self.grid.keyForWorld(start, goal, agent_class) orelse return .{ .status = .unavailable };
        if (self.entity_results.find(entity, key)) |result| {
            return .{ .status = result.status, .next_waypoint = result.next_waypoint, .path_len = result.path_len };
        }
        return self.statusForKey(key);
    }

    pub fn statusForKey(self: *const PathfindingSystem, key: PathQueryKey) PathView {
        if (self.findGoalField(NavGrid.goalKey(key))) |field| {
            if (field.resultFor(&self.grid, key)) |result| {
                return .{ .status = .available, .next_waypoint = result.next_waypoint, .path_len = result.path_len };
            }
            return .{ .status = .unavailable };
        }
        if (self.completed.find(key)) |result| {
            return .{ .status = .available, .next_waypoint = result.next_waypoint, .path_len = result.path_len };
        }
        if (self.unavailable.contains(key)) return .{ .status = .unavailable };
        if (self.pending_keys.contains(key)) return .{ .status = .pending };
        return .{ .status = .missing };
    }

    pub fn update(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), thread_system: *ThreadSystem, config: PathfindingConfig) !PathfindingStats {
        var stats = self.acceptRequests(requests.mergedItems());
        const solve_count = self.effectiveSolveLimit(config);
        stats.deferred_requests += self.pending.items.len - solve_count;
        if (solve_count == 0) {
            stats.pending_requests = self.pending.items.len;
            return stats;
        }
        var system_config = config;
        self.prepareSolveBuffers(solve_count);
        self.prepareGoalGroups(solve_count);
        self.buildGroupedFields(&stats);
        stats.field_result_batch = self.emitFieldResults(solve_count, thread_system, &system_config, &stats);
        self.prepareFallbackIndices(solve_count, self.effectiveFallbackLimit(system_config), &stats);

        if (self.fallback_indices.items.len != 0) {
            if (system_config.adaptive and system_config.fallback_adaptive_tuner == null and system_config.items_per_range == null) {
                system_config.fallback_adaptive_tuner = &self.fallback_tuner;
            }
            const participants = thread_system.participantSlotCount();
            if (participants > self.scratch_slots.items.len) return error.PathfindingScratchCapacityExceeded;
            var context = SolveJobContext{ .system = self };
            stats.fallback_batch = thread_system.parallelForWithOptions(self.fallback_indices.items.len, &context, solveFallbackJob, .{
                .items_per_range = system_config.items_per_range,
                .max_worker_threads = system_config.max_worker_threads,
                .range_alignment_items = pathfinding_range_alignment_items,
                .adaptive = system_config.adaptive,
                .adaptive_tuner = system_config.fallback_adaptive_tuner,
            });
        }

        self.publishSolvedResults(solve_count, &stats);
        self.compactPendingAfterSolve(solve_count);
        stats.pending_requests = self.pending.items.len;
        stats.deferred_requests = stats.pending_requests;
        return stats;
    }

    pub fn updateSerial(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), config: PathfindingConfig) !PathfindingStats {
        var stats = self.acceptRequests(requests.mergedItems());
        const solve_count = self.effectiveSolveLimit(config);
        stats.deferred_requests += self.pending.items.len - solve_count;
        if (solve_count == 0) {
            stats.pending_requests = self.pending.items.len;
            return stats;
        }
        self.prepareSolveBuffers(solve_count);
        self.prepareGoalGroups(solve_count);
        self.buildGroupedFields(&stats);
        self.emitFieldResultsSerial(solve_count, &stats);
        self.prepareFallbackIndices(solve_count, self.effectiveFallbackLimit(config), &stats);
        if (self.fallback_indices.items.len != 0) {
            if (self.scratch_slots.items.len == 0) return error.PathfindingScratchCapacityExceeded;
            const scratch = &self.scratch_slots.items[0];
            for (self.fallback_indices.items) |pending_index| {
                self.solve_results.items[pending_index] = solveOne(&self.grid, self.pending.items[pending_index], scratch);
            }
        }
        stats.fallback_batch = .{
            .item_count = self.fallback_indices.items.len,
            .range_count = if (self.fallback_indices.items.len == 0) 0 else 1,
            .items_per_range = self.fallback_indices.items.len,
            .range_alignment_items = pathfinding_range_alignment_items,
            .main_thread_ranges = if (self.fallback_indices.items.len == 0) 0 else 1,
            .ran_inline = true,
        };
        self.publishSolvedResults(solve_count, &stats);
        self.compactPendingAfterSolve(solve_count);
        stats.pending_requests = self.pending.items.len;
        stats.deferred_requests = stats.pending_requests;
        return stats;
    }

    fn acceptRequests(self: *PathfindingSystem, requests: []const PathRequest) PathfindingStats {
        var stats = PathfindingStats{};
        if (requests.len == 0 or !self.grid.valid()) return stats;
        self.prepareRequestKeysSimd(requests, &stats);
        for (self.prepared_requests.items) |prepared| {
            if (self.completed.find(prepared.key)) |path| {
                self.publishEntityAvailable(prepared.entity, path, &stats);
                stats.duplicate_requests += 1;
                stats.cache_hits += 1;
                stats.available_results += 1;
                continue;
            }
            if (self.unavailable.contains(prepared.key)) {
                self.publishEntityUnavailable(prepared.entity, prepared.key, &stats);
                stats.duplicate_requests += 1;
                stats.cache_hits += 1;
                stats.unavailable_results += 1;
                continue;
            }
            if (self.pending_keys.contains(prepared.key)) {
                stats.duplicate_requests += 1;
                continue;
            }
            if (self.pending.items.len >= self.capacity.max_pending_requests) {
                stats.dropped_requests += 1;
                continue;
            }
            self.pending.appendAssumeCapacity(.{ .entity = prepared.entity, .key = prepared.key });
            _ = self.pending_keys.insert(prepared.key);
            stats.accepted_requests += 1;
        }
        stats.pending_requests = self.pending.items.len;
        return stats;
    }

    fn prepareRequestKeysSimd(self: *PathfindingSystem, requests: []const PathRequest, stats: *PathfindingStats) void {
        self.prepared_requests.clearRetainingCapacity();
        if (!self.grid.valid()) return;
        const capacity = self.prepared_requests.capacity;
        const limit = @min(requests.len, capacity);
        stats.dropped_requests += requests.len - limit;

        const cell_size = simd.splatFloat4(self.grid.cell_size);
        const zero = simd.splatInt4(0);
        const max_x = simd.splatInt4(@intCast(self.grid.width - 1));
        const max_y = simd.splatInt4(@intCast(self.grid.height - 1));

        var index: usize = 0;
        while (index + simd.lane_count <= limit) : (index += simd.lane_count) {
            const start_xf = @floor(simd.float4(requests[index].start.x, requests[index + 1].start.x, requests[index + 2].start.x, requests[index + 3].start.x) / cell_size);
            const start_yf = @floor(simd.float4(requests[index].start.y, requests[index + 1].start.y, requests[index + 2].start.y, requests[index + 3].start.y) / cell_size);
            const goal_xf = @floor(simd.float4(requests[index].goal.x, requests[index + 1].goal.x, requests[index + 2].goal.x, requests[index + 3].goal.x) / cell_size);
            const goal_yf = @floor(simd.float4(requests[index].goal.y, requests[index + 1].goal.y, requests[index + 2].goal.y, requests[index + 3].goal.y) / cell_size);
            const start_x = simd.toIntArray(simd.clampInt4(@as(simd.Int4, @intFromFloat(start_xf)), zero, max_x));
            const start_y = simd.toIntArray(simd.clampInt4(@as(simd.Int4, @intFromFloat(start_yf)), zero, max_y));
            const goal_x = simd.toIntArray(simd.clampInt4(@as(simd.Int4, @intFromFloat(goal_xf)), zero, max_x));
            const goal_y = simd.toIntArray(simd.clampInt4(@as(simd.Int4, @intFromFloat(goal_yf)), zero, max_y));
            inline for (0..simd.lane_count) |lane| {
                self.prepared_requests.appendAssumeCapacity(.{
                    .entity = requests[index + lane].entity,
                    .key = .{
                        .nav_version = self.grid.version,
                        .agent_class = requests[index + lane].agent_class,
                        .start = .{ .x = start_x[lane], .y = start_y[lane] },
                        .goal = .{ .x = goal_x[lane], .y = goal_y[lane] },
                    },
                });
            }
        }

        while (index < limit) : (index += 1) {
            self.prepared_requests.appendAssumeCapacity(.{
                .entity = requests[index].entity,
                .key = self.grid.keyForWorld(requests[index].start, requests[index].goal, requests[index].agent_class).?,
            });
        }
    }

    fn prepareSolveBuffers(self: *PathfindingSystem, solve_count: usize) void {
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        for (0..solve_count) |_| {
            self.solve_results.appendAssumeCapacity(.{ .deferred = emptyKey(self.grid.version) });
        }
    }

    fn effectiveSolveLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_solved_requests_per_step orelse self.capacity.max_solved_requests_per_step;
        return @min(
            self.pending.items.len,
            @min(
                @min(requested_limit, self.capacity.max_solved_requests_per_step),
                @min(self.solve_results.capacity, @min(self.fallback_indices.capacity, self.groups.capacity)),
            ),
        );
    }

    fn effectiveFallbackLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_fallback_requests_per_step orelse self.capacity.max_fallback_requests_per_step;
        return @min(requested_limit, self.capacity.max_fallback_requests_per_step);
    }

    fn prepareGoalGroups(self: *PathfindingSystem, solve_count: usize) void {
        self.groups.clearRetainingCapacity();
        for (self.pending.items[0..solve_count]) |pending_request| {
            const group_key = NavGrid.goalKey(pending_request.key);
            if (self.findGroupIndex(group_key)) |index| {
                self.groups.items[index].count += 1;
            } else if (self.groups.items.len < self.groups.capacity) {
                self.groups.appendAssumeCapacity(.{ .key = group_key, .count = 1 });
            }
        }
    }

    fn buildGroupedFields(self: *PathfindingSystem, stats: *PathfindingStats) void {
        for (self.groups.items) |group| {
            if (group.count < 2) continue;
            _ = self.ensureGoalField(group.key, stats);
        }
    }

    fn emitFieldResults(self: *PathfindingSystem, solve_count: usize, thread_system: *ThreadSystem, config: *PathfindingConfig, stats: *PathfindingStats) BatchStats {
        const emit_count = self.fieldEmissionCount(solve_count);
        if (emit_count == 0) return .{};
        if (config.adaptive and config.field_result_adaptive_tuner == null and config.items_per_range == null) {
            config.field_result_adaptive_tuner = &self.field_tuner;
        }
        var context = FieldResultJobContext{ .system = self, .solve_count = solve_count };
        const batch = thread_system.parallelForWithOptions(solve_count, &context, emitFieldResultJob, .{
            .items_per_range = config.items_per_range,
            .max_worker_threads = config.max_worker_threads,
            .range_alignment_items = pathfinding_range_alignment_items,
            .adaptive = config.adaptive,
            .adaptive_tuner = config.field_result_adaptive_tuner,
        });
        stats.field_requests += emit_count;
        return batch;
    }

    fn emitFieldResultsSerial(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        for (0..solve_count) |pending_index| {
            self.emitFieldResultAt(pending_index);
        }
        const emit_count = self.fieldEmissionCount(solve_count);
        stats.field_requests += emit_count;
        stats.field_result_batch = .{
            .item_count = emit_count,
            .range_count = if (emit_count == 0) 0 else 1,
            .items_per_range = emit_count,
            .range_alignment_items = pathfinding_range_alignment_items,
            .main_thread_ranges = if (emit_count == 0) 0 else 1,
            .ran_inline = true,
        };
    }

    fn emitFieldResultAt(self: *PathfindingSystem, pending_index: usize) void {
        const pending_request = self.pending.items[pending_index];
        const group_key = NavGrid.goalKey(pending_request.key);
        const group_index = self.findGroupIndex(group_key) orelse return;
        if (self.groups.items[group_index].count < 2) return;
        const field = self.findGoalField(group_key) orelse return;
        if (field.resultFor(&self.grid, pending_request.key)) |result| {
            self.solve_results.items[pending_index] = .{ .available = result };
        } else {
            self.solve_results.items[pending_index] = .{ .unavailable = pending_request.key };
        }
    }

    fn fieldEmissionCount(self: *const PathfindingSystem, solve_count: usize) usize {
        var count: usize = 0;
        for (self.pending.items[0..solve_count]) |pending_request| {
            const group_key = NavGrid.goalKey(pending_request.key);
            const group_index = self.findGroupIndex(group_key) orelse continue;
            if (self.groups.items[group_index].count >= 2 and self.findGoalField(group_key) != null) {
                count += 1;
            }
        }
        return count;
    }

    fn prepareFallbackIndices(self: *PathfindingSystem, solve_count: usize, fallback_limit: usize, stats: *PathfindingStats) void {
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            if (result == .deferred) {
                if (fastSolve(&self.grid, self.pending.items[pending_index])) |fast_result| {
                    self.solve_results.items[pending_index] = fast_result;
                } else if (self.fallback_indices.items.len < fallback_limit) {
                    self.fallback_indices.appendAssumeCapacity(pending_index);
                } else {
                    stats.fallback_deferred_requests += 1;
                }
            }
        }
    }

    fn publishSolvedResults(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            const entity = self.pending.items[pending_index].entity;
            switch (result) {
                .available => |path| {
                    self.completed.put(path, stats);
                    self.publishEntityAvailable(entity, path, stats);
                    stats.solved_requests += 1;
                    stats.available_results += 1;
                },
                .unavailable => |key| {
                    if (!self.unavailable.insert(key)) stats.cache_evictions += 1;
                    self.publishEntityUnavailable(entity, key, stats);
                    stats.solved_requests += 1;
                    stats.unavailable_results += 1;
                },
                .deferred => {
                    continue;
                },
            }
        }
        stats.fallback_requests = self.fallback_indices.items.len;
    }

    fn publishEntityAvailable(self: *PathfindingSystem, entity: EntityId, path: PathResult, stats: *PathfindingStats) void {
        self.entity_results.put(.{
            .entity = entity,
            .key = path.key,
            .status = .available,
            .next_waypoint = path.next_waypoint,
            .path_len = path.path_len,
        }, stats);
    }

    fn publishEntityUnavailable(self: *PathfindingSystem, entity: EntityId, key: PathQueryKey, stats: *PathfindingStats) void {
        self.entity_results.put(.{
            .entity = entity,
            .key = key,
            .status = .unavailable,
        }, stats);
    }

    fn compactPendingAfterSolve(self: *PathfindingSystem, solve_count: usize) void {
        if (solve_count == 0) return;
        var write_index: usize = 0;
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            if (result != .deferred) continue;
            self.pending.items[write_index] = self.pending.items[pending_index];
            write_index += 1;
        }
        for (self.pending.items[solve_count..]) |pending_request| {
            self.pending.items[write_index] = pending_request;
            write_index += 1;
        }
        self.pending.items.len = write_index;
        self.pending_keys.clear();
        for (self.pending.items) |pending_request| {
            _ = self.pending_keys.insert(pending_request.key);
        }
    }

    fn findGoalField(self: *const PathfindingSystem, key: GoalKey) ?*const GoalField {
        for (self.goal_fields.items) |*field| {
            if (field.occupied and goalKeysEqual(field.key, key)) return field;
        }
        return null;
    }

    fn ensureGoalField(self: *PathfindingSystem, key: GoalKey, stats: *PathfindingStats) ?*GoalField {
        for (self.goal_fields.items) |*field| {
            if (field.occupied and goalKeysEqual(field.key, key)) {
                stats.goal_fields_reused += 1;
                return field;
            }
        }
        if (self.goal_fields.items.len == 0) return null;
        for (self.goal_fields.items) |*field| {
            if (!field.occupied) {
                if (!field.build(&self.grid, key)) return null;
                stats.goal_fields_built += 1;
                return field;
            }
        }
        const index = self.next_field_evict;
        self.next_field_evict = (self.next_field_evict + 1) % self.goal_fields.items.len;
        const field = &self.goal_fields.items[index];
        if (!field.build(&self.grid, key)) return null;
        stats.goal_fields_built += 1;
        stats.cache_evictions += 1;
        return field;
    }

    fn findGroupIndex(self: *const PathfindingSystem, key: GoalKey) ?usize {
        for (self.groups.items, 0..) |group, index| {
            if (goalKeysEqual(group.key, key)) return index;
        }
        return null;
    }
};

const SolveJobContext = struct {
    system: *PathfindingSystem,
};

const FieldResultJobContext = struct {
    system: *PathfindingSystem,
    solve_count: usize,
};

fn emitFieldResultJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *FieldResultJobContext = @ptrCast(@alignCast(context));
    for (range.start..range.end) |pending_index| {
        std.debug.assert(pending_index < job.solve_count);
        job.system.emitFieldResultAt(pending_index);
    }
}

fn solveFallbackJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *SolveJobContext = @ptrCast(@alignCast(context));
    const scratch = &job.system.scratch_slots.items[worker_id.index];
    for (range.start..range.end) |fallback_index| {
        const pending_index = job.system.fallback_indices.items[fallback_index];
        job.system.solve_results.items[pending_index] = solveOne(&job.system.grid, job.system.pending.items[pending_index], scratch);
    }
}

fn solveOne(grid: *const NavGrid, request: PendingRequest, scratch: *SearchScratch) PathSolveResult {
    if (fastSolve(grid, request)) |result| return result;

    const start_index = grid.indexForCell(request.key.start).?;
    const goal_index = grid.indexForCell(request.key.goal).?;

    scratch.reset();
    scratch.setG(start_index, 0);
    scratch.parents.items[start_index] = start_index;
    if (!scratch.pushOpen(.{ .index = start_index, .f = heuristic(grid, start_index, goal_index), .h = heuristic(grid, start_index, goal_index) })) {
        return .{ .deferred = request.key };
    }

    while (scratch.open.items.len != 0) {
        const current = scratch.popOpen();
        if (scratch.closed(current.index)) continue;
        scratch.close(current.index);
        if (current.index == goal_index) {
            return .{ .available = reconstructResult(grid, request.key, start_index, goal_index, scratch.parents.items) };
        }
        const current_x: i32 = @intCast(current.index % grid.width);
        const current_y: i32 = @intCast(current.index / grid.width);
        for (neighbor_dirs) |dir| {
            const next_cell = GridCell{ .x = current_x + dir.x, .y = current_y + dir.y };
            const next_index = grid.indexForCell(next_cell) orelse continue;
            if (scratch.closed(next_index) or grid.isBlockedIndex(next_index)) continue;
            if (dir.diagonal and (grid.isBlockedCell(.{ .x = current_x + dir.x, .y = current_y }) or grid.isBlockedCell(.{ .x = current_x, .y = current_y + dir.y }))) {
                continue;
            }
            const step_cost = if (dir.diagonal) diagonal_cost else cardinal_cost;
            const candidate_g = scratch.g(current.index) + step_cost;
            if (candidate_g >= scratch.g(next_index)) continue;
            scratch.setG(next_index, candidate_g);
            scratch.parents.items[next_index] = current.index;
            const h = heuristic(grid, next_index, goal_index);
            if (!scratch.pushOpen(.{ .index = next_index, .f = candidate_g + h, .h = h })) {
                return .{ .deferred = request.key };
            }
        }
    }
    return .{ .unavailable = request.key };
}

fn fastSolve(grid: *const NavGrid, request: PendingRequest) ?PathSolveResult {
    if (!grid.valid()) return .{ .unavailable = request.key };
    const start_index = grid.indexForCell(request.key.start) orelse return .{ .unavailable = request.key };
    const goal_index = grid.indexForCell(request.key.goal) orelse return .{ .unavailable = request.key };
    if (grid.isBlockedIndex(start_index) or grid.isBlockedIndex(goal_index)) return .{ .unavailable = request.key };
    if (!grid.connected(start_index, goal_index)) return .{ .unavailable = request.key };
    if (start_index == goal_index) {
        return .{ .available = .{ .key = request.key, .next_waypoint = grid.cellCenter(goal_index), .path_len = 1 } };
    }
    if (directLineResult(grid, request.key)) |result| {
        return .{ .available = result };
    }
    if (portalDetourResult(grid, request.key)) |result| {
        return .{ .available = result };
    }
    return null;
}

const NeighborDir = struct {
    x: i32,
    y: i32,
    diagonal: bool = false,
};

const neighbor_dirs = [_]NeighborDir{
    .{ .x = 1, .y = 0 },
    .{ .x = 0, .y = 1 },
    .{ .x = -1, .y = 0 },
    .{ .x = 0, .y = -1 },
    .{ .x = 1, .y = 1, .diagonal = true },
    .{ .x = -1, .y = 1, .diagonal = true },
    .{ .x = -1, .y = -1, .diagonal = true },
    .{ .x = 1, .y = -1, .diagonal = true },
};

fn heuristic(grid: *const NavGrid, from_index: usize, to_index: usize) u32 {
    const from_x: i32 = @intCast(from_index % grid.width);
    const from_y: i32 = @intCast(from_index / grid.width);
    const to_x: i32 = @intCast(to_index % grid.width);
    const to_y: i32 = @intCast(to_index / grid.width);
    const dx: u32 = @intCast(@abs(to_x - from_x));
    const dy: u32 = @intCast(@abs(to_y - from_y));
    const diagonal = @min(dx, dy);
    const straight = @max(dx, dy) - diagonal;
    return diagonal * diagonal_cost + straight * cardinal_cost;
}

fn lessNode(a: OpenNode, b: OpenNode) bool {
    return a.f < b.f or
        (a.f == b.f and a.h < b.h) or
        (a.f == b.f and a.h == b.h and a.index < b.index);
}

fn siftUp(heap: []OpenNode, start_index: usize) void {
    var index = start_index;
    while (index != 0) {
        const parent = (index - 1) / 2;
        if (!lessNode(heap[index], heap[parent])) break;
        std.mem.swap(OpenNode, &heap[index], &heap[parent]);
        index = parent;
    }
}

fn siftDown(heap: []OpenNode, start_index: usize) void {
    var index = start_index;
    while (true) {
        const left = index * 2 + 1;
        if (left >= heap.len) break;
        const right = left + 1;
        var best = left;
        if (right < heap.len and lessNode(heap[right], heap[left])) best = right;
        if (!lessNode(heap[best], heap[index])) break;
        std.mem.swap(OpenNode, &heap[index], &heap[best]);
        index = best;
    }
}

fn reconstructResult(grid: *const NavGrid, key: PathQueryKey, start_index: usize, goal_index: usize, parents: []const usize) PathResult {
    var current = goal_index;
    var previous = goal_index;
    var path_len: usize = 1;
    while (current != start_index and current != no_parent) {
        previous = current;
        current = parents[current];
        path_len += 1;
    }
    return .{
        .key = key,
        .next_waypoint = grid.cellCenter(previous),
        .path_len = path_len,
    };
}

fn directLineResult(grid: *const NavGrid, key: PathQueryKey) ?PathResult {
    if (grid.blocked_count == 0) return openGridLineResult(grid, key);
    const direct = directLinePath(grid, key.start, key.goal) orelse return null;
    return .{
        .key = key,
        .next_waypoint = grid.cellCenter(direct.next_index),
        .path_len = direct.path_len,
    };
}

fn openGridLineResult(grid: *const NavGrid, key: PathQueryKey) ?PathResult {
    const first = firstLineStep(key.start, key.goal) orelse return null;
    const first_index = grid.indexForCell(first) orelse return null;
    const dx: usize = @intCast(@abs(key.goal.x - key.start.x));
    const dy: usize = @intCast(@abs(key.goal.y - key.start.y));
    return .{
        .key = key,
        .next_waypoint = grid.cellCenter(first_index),
        .path_len = @max(dx, dy) + 1,
    };
}

fn portalDetourResult(grid: *const NavGrid, key: PathQueryKey) ?PathResult {
    if (grid.portals.items.len == 0) return null;
    var best: ?PathResult = null;
    var best_cost: u32 = unreachable_cost;
    const start_index = grid.indexForCell(key.start) orelse return null;
    const goal_index = grid.indexForCell(key.goal) orelse return null;
    for (grid.portals.items) |portal| {
        const a = cellForIndex(grid, portal.a);
        const b = cellForIndex(grid, portal.b);
        const candidate_ab = portalCandidate(grid, key, start_index, goal_index, a, b, portal.a, portal.b);
        const candidate_ba = portalCandidate(grid, key, start_index, goal_index, b, a, portal.b, portal.a);
        const candidate = if (candidate_ab.cost <= candidate_ba.cost) candidate_ab else candidate_ba;
        if (!candidate.valid or candidate.cost >= best_cost) continue;
        best_cost = candidate.cost;
        best = candidate.result;
    }
    return best;
}

const PortalCandidate = struct {
    valid: bool = false,
    cost: u32 = unreachable_cost,
    result: PathResult = .{ .key = emptyKey(0), .next_waypoint = .{}, .path_len = 0 },
};

fn portalCandidate(
    grid: *const NavGrid,
    key: PathQueryKey,
    start_index: usize,
    goal_index: usize,
    entry: GridCell,
    exit: GridCell,
    entry_index: usize,
    exit_index: usize,
) PortalCandidate {
    const first_leg = directLinePath(grid, key.start, entry) orelse return .{};
    _ = directLinePath(grid, entry, exit) orelse return .{};
    _ = directLinePath(grid, exit, key.goal) orelse return .{};
    const cost = heuristic(grid, start_index, entry_index) +
        heuristic(grid, entry_index, exit_index) +
        heuristic(grid, exit_index, goal_index);
    return .{
        .valid = true,
        .cost = cost,
        .result = .{
            .key = key,
            .next_waypoint = grid.cellCenter(first_leg.next_index),
            .path_len = estimatePathLen(key.start, entry) + estimatePathLen(entry, exit) + estimatePathLen(exit, key.goal) + 1,
        },
    };
}

const DirectLinePath = struct {
    next_index: usize,
    path_len: usize,
};

fn directLinePath(grid: *const NavGrid, start: GridCell, goal: GridCell) ?DirectLinePath {
    var x = start.x;
    var y = start.y;
    const dx: i32 = @intCast(@abs(goal.x - start.x));
    const dy: i32 = @intCast(@abs(goal.y - start.y));
    const sx = stepDirection(start.x, goal.x);
    const sy = stepDirection(start.y, goal.y);
    var err = dx - dy;
    var next_index = no_parent;
    var path_len: usize = 1;

    while (x != goal.x or y != goal.y) {
        const previous_x = x;
        const previous_y = y;
        const e2 = err * 2;
        if (e2 > -dy) {
            err -= dy;
            x += sx;
        }
        if (e2 < dx) {
            err += dx;
            y += sy;
        }
        if (x == previous_x and y == previous_y) return null;

        const diagonal = x != previous_x and y != previous_y;
        if (diagonal and (grid.isBlockedCell(.{ .x = x, .y = previous_y }) or grid.isBlockedCell(.{ .x = previous_x, .y = y }))) {
            return null;
        }
        const index = grid.indexForCell(.{ .x = x, .y = y }) orelse return null;
        if (grid.isBlockedIndex(index)) return null;
        if (next_index == no_parent) next_index = index;
        path_len += 1;
    }

    if (next_index == no_parent) return null;
    return .{ .next_index = next_index, .path_len = path_len };
}

fn firstLineStep(start: GridCell, goal: GridCell) ?GridCell {
    var x = start.x;
    var y = start.y;
    const dx: i32 = @intCast(@abs(goal.x - start.x));
    const dy: i32 = @intCast(@abs(goal.y - start.y));
    const sx = stepDirection(start.x, goal.x);
    const sy = stepDirection(start.y, goal.y);
    const err = dx - dy;
    const e2 = err * 2;
    if (e2 > -dy) {
        x += sx;
    }
    if (e2 < dx) {
        y += sy;
    }
    if (x == start.x and y == start.y) return null;
    return .{ .x = x, .y = y };
}

fn cellForIndex(grid: *const NavGrid, index: usize) GridCell {
    return .{
        .x = @intCast(index % grid.width),
        .y = @intCast(index / grid.width),
    };
}

fn estimatePathLen(start: GridCell, goal: GridCell) usize {
    const dx: usize = @intCast(@abs(goal.x - start.x));
    const dy: usize = @intCast(@abs(goal.y - start.y));
    return @max(dx, dy);
}

fn stepDirection(from: i32, to: i32) i32 {
    return if (from < to) 1 else if (from > to) -1 else 0;
}

fn collisionBoundsIndex(entities: []const EntityId, target: EntityId) ?usize {
    for (entities, 0..) |entity, index| {
        if (entity.index == target.index and entity.generation == target.generation) return index;
    }
    return null;
}

fn entityEqual(a: EntityId, b: EntityId) bool {
    return a.index == b.index and a.generation == b.generation;
}

fn goalKeysEqual(a: GoalKey, b: GoalKey) bool {
    return a.nav_version == b.nav_version and
        a.agent_class == b.agent_class and
        a.goal.x == b.goal.x and
        a.goal.y == b.goal.y;
}

fn keysEqual(a: PathQueryKey, b: PathQueryKey) bool {
    return a.nav_version == b.nav_version and
        a.agent_class == b.agent_class and
        a.start.x == b.start.x and
        a.start.y == b.start.y and
        a.goal.x == b.goal.x and
        a.goal.y == b.goal.y;
}

fn hashPathKey(key: PathQueryKey) usize {
    var h: u64 = 14695981039346656037;
    inline for (.{ key.nav_version, @intFromEnum(key.agent_class), @as(u32, @bitCast(key.start.x)), @as(u32, @bitCast(key.start.y)), @as(u32, @bitCast(key.goal.x)), @as(u32, @bitCast(key.goal.y)) }) |part| {
        h ^= @as(u64, part);
        h *%= 1099511628211;
    }
    return @intCast(h);
}

fn hashEntity(entity: EntityId) usize {
    var h: u64 = 14695981039346656037;
    h ^= @as(u64, entity.index);
    h *%= 1099511628211;
    h ^= @as(u64, entity.generation);
    h *%= 1099511628211;
    return @intCast(h);
}

fn emptyKey(nav_version: u32) PathQueryKey {
    return .{
        .nav_version = nav_version,
        .agent_class = .default,
        .start = .{ .x = 0, .y = 0 },
        .goal = .{ .x = 0, .y = 0 },
    };
}

fn emptyGoalKey(nav_version: u32) GoalKey {
    return .{
        .nav_version = nav_version,
        .agent_class = .default,
        .goal = .{ .x = 0, .y = 0 },
    };
}

fn appendPathRequest(stream: *RangeOutputStream(PathRequest), request: PathRequest) !void {
    const range_base = try stream.appendRangeCounts(1);
    stream.addCount(range_base, 1);
    try stream.prefixAppendedRanges(range_base);
    var writer = stream.rangeWriter(range_base);
    writer.write(request);
    writer.finish();
    stream.finishWrite();
}

fn addNavBody(data: *DataSystem, position: math.Vec2, size: math.Vec2, static: bool) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try data.setCollisionBounds(entity, .{ .size = size });
    try data.setCollisionResponse(entity, .{ .mobility = if (static) .static else .dynamic });
    return entity;
}

const HardFallbackRequest = struct {
    entity: EntityId,
    start: math.Vec2,
    goal: math.Vec2,
};

fn appendHardFallbackRequest(data: *DataSystem, stream: *RangeOutputStream(PathRequest), row: usize) !HardFallbackRequest {
    const y_cell = 2 + row * 3;
    const y = @as(f32, @floatFromInt(y_cell)) * 32.0;
    const entity = try addNavBody(data, .{ .x = 32, .y = y }, .{ .x = 8, .y = 8 }, false);
    _ = try addNavBody(data, .{ .x = 1024, .y = y }, .{ .x = 8, .y = 8 }, true);
    const request = HardFallbackRequest{
        .entity = entity,
        .start = .{ .x = 40, .y = y + 8 },
        .goal = .{ .x = 1992, .y = y + 8 },
    };
    try appendPathRequest(stream, .{
        .entity = request.entity,
        .start = request.start,
        .goal = request.goal,
    });
    return request;
}

fn expectTrueFallbackRequest(system: *const PathfindingSystem, request: HardFallbackRequest) !void {
    const key = system.grid.keyForWorld(request.start, request.goal, .default).?;
    try std.testing.expect(directLineResult(&system.grid, key) == null);
    try std.testing.expect(fastSolve(&system.grid, .{ .entity = request.entity, .key = key }) == null);
}

test "pathfinding caches unavailable requests without requeueing duplicates" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    _ = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 32, .y = 96 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try system.rebuildStaticNavGrid(&data, 96, 96, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 80, .y = 8 } });

    var stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_results);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(.{ .x = 8, .y = 8 }, .{ .x = 80, .y = 8 }, .default).status);

    stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.duplicate_requests);
    try std.testing.expectEqual(@as(usize, 0), stats.solved_requests);
}

test "pathfinding produces deterministic available path and next waypoint" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });
    const stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);

    const view = system.statusForWorld(.{ .x = 8, .y = 8 }, .{ .x = 96, .y = 96 }, .default);
    try std.testing.expectEqual(PathStatus.available, view.status);
    try std.testing.expectEqual(@as(f32, 48), view.next_waypoint.x);
    try std.testing.expectEqual(@as(f32, 48), view.next_waypoint.y);
    try std.testing.expect(view.path_len >= 2);
}

test "pathfinding open grid direct path is allocation-free and constant work" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);
    try std.testing.expectEqual(@as(usize, 0), system.grid.blocked_count);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 488, .y = 488 } });

    const original_allocator = system.allocator;
    system.allocator = std.testing.failing_allocator;
    const stats = try system.updateSerial(&stream, .{});
    system.allocator = original_allocator;

    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_requests);
    const view = system.statusForWorld(.{ .x = 8, .y = 8 }, .{ .x = 488, .y = 488 }, .default);
    try std.testing.expectEqual(PathStatus.available, view.status);
    try std.testing.expectEqual(@as(f32, 48), view.next_waypoint.x);
    try std.testing.expectEqual(@as(f32, 48), view.next_waypoint.y);
}

test "pathfinding direct serial solve does not require fallback scratch" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 1, .max_pending_requests = 1, .max_cached_results = 2, .max_goal_fields = 0, .max_worker_scratch_slots = 0, .max_solved_requests_per_step = 1 });
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });

    const stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_requests);
}

test "pathfinding blocked direct line falls back to obstacle-aware search" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    _ = try addNavBody(&data, .{ .x = 32, .y = 32 }, .{ .x = 32, .y = 32 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try system.rebuildStaticNavGrid(&data, 160, 160, 32);
    try std.testing.expect(system.grid.blocked_count != 0);

    const key = system.grid.keyForWorld(.{ .x = 8, .y = 8 }, .{ .x = 128, .y = 128 }, .default).?;
    try std.testing.expect(directLineResult(&system.grid, key) == null);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 128, .y = 128 } });

    const stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    const view = system.statusForWorld(.{ .x = 8, .y = 8 }, .{ .x = 128, .y = 128 }, .default);
    try std.testing.expectEqual(PathStatus.available, view.status);
    try std.testing.expect(view.next_waypoint.x != 48 or view.next_waypoint.y != 48);
}

test "pathfinding true fallback fixture executes heap search" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    const request = try appendHardFallbackRequest(&data, &stream, 0);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 1, .max_pending_requests = 1, .max_cached_results = 4, .max_goal_fields = 1, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 1, .max_fallback_requests_per_step = 1 });
    try system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    try expectTrueFallbackRequest(&system, request);

    const stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_requests);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_deferred_requests);
    try std.testing.expectEqual(@as(usize, 0), stats.pending_requests);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(request.start, request.goal, .default).status);
}

test "pathfinding fallback budget defers hard paths in stable order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(3, 3);
    const first = try appendHardFallbackRequest(&data, &stream, 0);
    const second = try appendHardFallbackRequest(&data, &stream, 1);
    const third = try appendHardFallbackRequest(&data, &stream, 2);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 3, .max_pending_requests = 3, .max_cached_results = 8, .max_goal_fields = 1, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 3, .max_fallback_requests_per_step = 1 });
    try system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    try expectTrueFallbackRequest(&system, first);
    try expectTrueFallbackRequest(&system, second);
    try expectTrueFallbackRequest(&system, third);

    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();

    var stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.fallback_deferred_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.deferred_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.pending_requests);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(first.start, first.goal, .default).status);
    try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(second.start, second.goal, .default).status);
    try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(third.start, third.goal, .default).status);

    stats = try system.updateSerial(&empty, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_requests);
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_deferred_requests);
    try std.testing.expectEqual(@as(usize, 1), stats.pending_requests);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(second.start, second.goal, .default).status);
    try std.testing.expectEqual(PathStatus.pending, system.statusForWorld(third.start, third.goal, .default).status);

    stats = try system.updateSerial(&empty, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.fallback_requests);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_deferred_requests);
    try std.testing.expectEqual(@as(usize, 0), stats.pending_requests);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(third.start, third.goal, .default).status);
}

test "pathfinding rejects disconnected goals before heap fallback" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    _ = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 32, .y = 160 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try system.rebuildStaticNavGrid(&data, 160, 160, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 128, .y = 8 } });

    const stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_requests);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(.{ .x = 8, .y = 8 }, .{ .x = 128, .y = 8 }, .default).status);
}

test "pathfinding uses portal detour before heap fallback" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 32, .y = 32 }, .{ .x = 8, .y = 8 }, false);
    for (0..8) |y| {
        if (y == 4) continue;
        _ = try addNavBody(&data, .{ .x = 128, .y = @as(f32, @floatFromInt(y)) * 32.0 }, .{ .x = 8, .y = 8 }, true);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);
    try std.testing.expect(system.grid.portals.items.len != 0);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 40, .y = 40 }, .goal = .{ .x = 232, .y = 40 } });

    const stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 0), stats.fallback_requests);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(.{ .x = 40, .y = 40 }, .{ .x = 232, .y = 40 }, .default).status);
}

test "pathfinding groups common goals into a reusable field" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try system.rebuildStaticNavGrid(&data, 160, 160, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(2, 2);
    try appendPathRequest(&stream, .{ .entity = a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 128, .y = 128 } });
    try appendPathRequest(&stream, .{ .entity = b, .start = .{ .x = 40, .y = 8 }, .goal = .{ .x = 128, .y = 128 } });

    const stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.goal_fields_built);
    try std.testing.expectEqual(@as(usize, 2), stats.field_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.available_results);
}

test "entity path status reuses goal field when moving between start cells" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 1, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try system.rebuildStaticNavGrid(&data, 160, 160, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(2, 2);
    try appendPathRequest(&stream, .{ .entity = a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 128, .y = 128 } });
    try appendPathRequest(&stream, .{ .entity = b, .start = .{ .x = 40, .y = 8 }, .goal = .{ .x = 128, .y = 128 } });

    const stats = try system.updateSerial(&stream, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.goal_fields_built);

    const moved_view = system.statusForEntityWorld(a, .{ .x = 72, .y = 8 }, .{ .x = 128, .y = 128 }, .default);
    try std.testing.expectEqual(PathStatus.available, moved_view.status);
    try std.testing.expect(moved_view.path_len >= 2);
}

test "pathfinding solve limit is clamped to reserved buffers" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const c = try addNavBody(&data, .{ .x = 64, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 1, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 1 });
    try system.rebuildStaticNavGrid(&data, 160, 160, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(3, 3);
    try appendPathRequest(&stream, .{ .entity = a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 128, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = b, .start = .{ .x = 40, .y = 8 }, .goal = .{ .x = 128, .y = 40 } });
    try appendPathRequest(&stream, .{ .entity = c, .start = .{ .x = 72, .y = 8 }, .goal = .{ .x = 128, .y = 72 } });

    const stats = try system.updateSerial(&stream, .{ .max_solved_requests_per_step = 4 });
    try std.testing.expectEqual(@as(usize, 1), stats.solved_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.deferred_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.pending_requests);
}

test "pathfinding failed goal field build is not reusable" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 2, .max_pending_requests = 2, .max_cached_results = 4, .max_goal_fields = 1, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 2 });
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var field = GoalField{};
    defer field.deinit(std.testing.allocator);
    const cell_count = system.grid.cellCount();
    try field.costs.ensureTotalCapacity(std.testing.allocator, cell_count);
    try field.stamps.ensureTotalCapacity(std.testing.allocator, cell_count);
    field.costs.items.len = cell_count;
    field.stamps.items.len = cell_count;
    @memset(field.costs.items, unreachable_cost);
    @memset(field.stamps.items, 0);

    const key = NavGrid.goalKey(system.grid.keyForWorld(.{ .x = 8, .y = 8 }, .{ .x = 96, .y = 96 }, .default).?);
    try std.testing.expect(!field.build(&system.grid, key));
    try std.testing.expect(!field.occupied);
}

test "pathfinding fixed-capacity result caches evict deterministically" {
    var stats = PathfindingStats{};
    var results = ResultCache{};
    defer results.deinit(std.testing.allocator);
    try results.reserve(std.testing.allocator, 1);
    var first_key = emptyKey(1);
    first_key.goal.x = 1;
    var second_key = emptyKey(1);
    second_key.goal.x = 2;

    results.put(.{ .key = first_key, .next_waypoint = .{ .x = 1, .y = 1 }, .path_len = 2 }, &stats);
    try std.testing.expect(results.find(first_key) != null);
    results.put(.{ .key = second_key, .next_waypoint = .{ .x = 2, .y = 2 }, .path_len = 3 }, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(results.find(first_key) == null);
    try std.testing.expect(results.find(second_key) != null);

    var entity_results = EntityResultCache{};
    defer entity_results.deinit(std.testing.allocator);
    try entity_results.reserve(std.testing.allocator, 1);
    const entity_a = try EntityId.init(1, 1);
    const entity_b = try EntityId.init(2, 1);
    entity_results.put(.{ .entity = entity_a, .key = first_key, .status = .available, .next_waypoint = .{ .x = 1, .y = 1 }, .path_len = 2 }, &stats);
    try std.testing.expect(entity_results.find(entity_a, first_key) != null);
    entity_results.put(.{ .entity = entity_b, .key = second_key, .status = .available, .next_waypoint = .{ .x = 2, .y = 2 }, .path_len = 3 }, &stats);
    try std.testing.expectEqual(@as(usize, 2), stats.cache_evictions);
    try std.testing.expect(entity_results.find(entity_a, first_key) == null);
    try std.testing.expect(entity_results.find(entity_b, second_key) != null);
}

test "pathfinding unavailable key set has explicit fixed capacity" {
    var keys = KeySet{};
    defer keys.deinit(std.testing.allocator);
    try keys.reserve(std.testing.allocator, 1);
    var first_key = emptyKey(1);
    first_key.goal.x = 1;
    var second_key = emptyKey(1);
    second_key.goal.x = 2;

    try std.testing.expect(keys.insert(first_key));
    try std.testing.expect(keys.contains(first_key));
    try std.testing.expect(!keys.insert(second_key));
    try std.testing.expect(keys.contains(first_key));
    try std.testing.expect(!keys.contains(second_key));
}

test "pathfinding goal fields evict by fixed slot order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 2, .max_pending_requests = 2, .max_cached_results = 2, .max_goal_fields = 1, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 2 });
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var stats = PathfindingStats{};
    const first = NavGrid.goalKey(system.grid.keyForWorld(.{ .x = 8, .y = 8 }, .{ .x = 96, .y = 96 }, .default).?);
    const second = NavGrid.goalKey(system.grid.keyForWorld(.{ .x = 8, .y = 8 }, .{ .x = 96, .y = 8 }, .default).?);
    try std.testing.expect(system.ensureGoalField(first, &stats) != null);
    try std.testing.expectEqual(@as(usize, 1), stats.goal_fields_built);
    try std.testing.expect(system.findGoalField(first) != null);
    try std.testing.expect(system.ensureGoalField(second, &stats) != null);
    try std.testing.expectEqual(@as(usize, 2), stats.goal_fields_built);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(system.findGoalField(first) == null);
    try std.testing.expect(system.findGoalField(second) != null);
}

test "pathfinding warmed update does not allocate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });

    const original_allocator = system.allocator;
    system.allocator = std.testing.failing_allocator;
    const stats = try system.updateSerial(&stream, .{});
    system.allocator = original_allocator;

    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
}

test "pathfinding warmed hard fallback update does not allocate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    const request = try appendHardFallbackRequest(&data, &stream, 0);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(.{ .max_frame_requests = 1, .max_pending_requests = 1, .max_cached_results = 4, .max_goal_fields = 1, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 1, .max_fallback_requests_per_step = 1 });
    try system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    try expectTrueFallbackRequest(&system, request);

    const original_allocator = system.allocator;
    system.allocator = std.testing.failing_allocator;
    const stats = try system.updateSerial(&stream, .{});
    system.allocator = original_allocator;

    try std.testing.expectEqual(@as(usize, 1), stats.fallback_requests);
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
}

test "pathfinding threaded solve matches serial solve" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    _ = try addNavBody(&data, .{ .x = 64, .y = 32 }, .{ .x = 32, .y = 96 }, true);

    var serial_system = PathfindingSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    try serial_system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 4 });
    try serial_system.rebuildStaticNavGrid(&data, 160, 160, 32);
    var threaded_system = PathfindingSystem.init(std.testing.allocator);
    defer threaded_system.deinit();
    try threaded_system.reserve(.{ .max_frame_requests = 4, .max_pending_requests = 4, .max_cached_results = 8, .max_goal_fields = 2, .max_worker_scratch_slots = 3, .max_solved_requests_per_step = 4 });
    try threaded_system.rebuildStaticNavGrid(&data, 160, 160, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 16, .y = 16 }, .goal = .{ .x = 144, .y = 144 } });

    _ = try serial_system.updateSerial(&stream, .{});
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();
    _ = try threaded_system.update(&stream, &threads, .{ .adaptive = false, .items_per_range = 1 });

    const serial_view = serial_system.statusForWorld(.{ .x = 16, .y = 16 }, .{ .x = 144, .y = 144 }, .default);
    const threaded_view = threaded_system.statusForWorld(.{ .x = 16, .y = 16 }, .{ .x = 144, .y = 144 }, .default);
    try std.testing.expectEqual(serial_view.status, threaded_view.status);
    try std.testing.expectEqual(serial_view.next_waypoint.x, threaded_view.next_waypoint.x);
    try std.testing.expectEqual(serial_view.next_waypoint.y, threaded_view.next_waypoint.y);
    try std.testing.expectEqual(serial_view.path_len, threaded_view.path_len);
}

test "pathfinding threaded hard fallback matches serial solve" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(2, 2);
    const first = try appendHardFallbackRequest(&data, &stream, 0);
    const second = try appendHardFallbackRequest(&data, &stream, 1);

    var serial_system = PathfindingSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    try serial_system.reserve(.{ .max_frame_requests = 2, .max_pending_requests = 2, .max_cached_results = 8, .max_goal_fields = 1, .max_worker_scratch_slots = 1, .max_solved_requests_per_step = 2, .max_fallback_requests_per_step = 2 });
    try serial_system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    var threaded_system = PathfindingSystem.init(std.testing.allocator);
    defer threaded_system.deinit();
    try threaded_system.reserve(.{ .max_frame_requests = 2, .max_pending_requests = 2, .max_cached_results = 8, .max_goal_fields = 1, .max_worker_scratch_slots = 3, .max_solved_requests_per_step = 2, .max_fallback_requests_per_step = 2 });
    try threaded_system.rebuildStaticNavGrid(&data, 2048, 2048, 32);
    try expectTrueFallbackRequest(&serial_system, first);
    try expectTrueFallbackRequest(&serial_system, second);

    const serial_stats = try serial_system.updateSerial(&stream, .{});
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();
    const threaded_stats = try threaded_system.update(&stream, &threads, .{ .adaptive = false, .items_per_range = 1 });

    try std.testing.expectEqual(@as(usize, 2), serial_stats.fallback_requests);
    try std.testing.expectEqual(@as(usize, 2), threaded_stats.fallback_requests);
    for ([_]HardFallbackRequest{ first, second }) |request| {
        const serial_view = serial_system.statusForWorld(request.start, request.goal, .default);
        const threaded_view = threaded_system.statusForWorld(request.start, request.goal, .default);
        try std.testing.expectEqual(serial_view.status, threaded_view.status);
        try std.testing.expectEqual(serial_view.next_waypoint.x, threaded_view.next_waypoint.x);
        try std.testing.expectEqual(serial_view.next_waypoint.y, threaded_view.next_waypoint.y);
        try std.testing.expectEqual(serial_view.path_len, threaded_view.path_len);
    }
}
