// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Collision detect over DataSystem movement/bounds SoA. Each step builds its own sweep: a
//! fill resolves every collider into a proxy and banded sort keys, a banded sort writes the
//! sweep entries in key order, the broadphase sweeps contiguous entries into range-owned
//! candidate slots, and the narrowphase writes range-owned contact windows. Every stage
//! merges in range order, so the contact stream is identical for any partition.
//!
//! An entry is one copy of a body per strip its y span crosses, keyed (level, strip, min_x,
//! min_y, entity index). A pair is swept only inside one (level, strip) run and emitted only
//! in the strip holding the larger min_y, where both bodies have a copy, so each same-level
//! overlapping pair appears once. Contacts are ordered by (level, that strip), then by the
//! key of a, then of b; a precedes b.

const std = @import("std");
const builtin = @import("builtin");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchSelection = @import("../../app/thread_system.zig").BatchSelection;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const StageThreads = @import("../../app/thread_system.zig").StageThreads;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const inlineBatch = @import("../../app/thread_system.zig").inlineBatch;
const paddingForCacheLine = @import("../../app/thread_system.zig").paddingForCacheLine;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const setRowCount = @import("../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const required_tile_size = @import("../../assets/world_tileset_meta.zig").required_tile_size;
const ConstCollisionBoundsSlice = @import("../data_system.zig").ConstCollisionBoundsSlice;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const hot_soa_column_alignment = @import("../data_system.zig").hot_soa_column_alignment;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const WorldSystem = @import("../world/system.zig").WorldSystem;
const banded_sort = @import("banded_sort.zig");
const BandOffsets = banded_sort.BandOffsets;
const OwnedBands = banded_sort.OwnedBands;
const band_count = banded_sort.band_count;
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const logging = @import("../../core/logging.zig");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const pdqSort = @import("../../core/sort.zig").pdq;
const CollisionContact = @import("../simulation.zig").CollisionContact;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;

pub const collision_range_alignment_items: usize = movement_range_alignment_items;

/// Broadphase candidate pairs reserved per swept item: each per-range slot holds this
/// many for the most entries its range can cover, and over the body capacity it is the
/// merged-candidate / narrowphase-staging bound.
const broadphase_pairs_per_item: usize = 4;

/// Sweep copies reserved per body: a body no taller than a strip spans at most two strips,
/// its first and second copies, each in a per-slot window. Copies past the second spill to
/// per-range slots on the counted grow paths.
const entries_per_body: usize = 2;

/// Strips per level: a u16 strip index. A level's pixel height over the strip height stays
/// within it (`CollisionStrips.ofWorld` asserts it); positions past the last strip clamp
/// into it.
const strip_count: u32 = 1 << 16;

fn hotStoreCapacity(min_len: usize) usize {
    return std.mem.alignForwardAnyAlign(usize, min_len, collision_range_alignment_items);
}

/// The sweep's y partition: horizontal strips of `height` world units on every level.
pub const CollisionStrips = struct {
    height: f32,

    /// The engine's tile size, the strip height `CollisionConfig` defaults to.
    pub const default: CollisionStrips = ofTileSize(required_tile_size);

    /// One tile per strip, rounded down to a power of two: the division by it is exact, so
    /// every point of a span lies in one of the span's strips.
    pub fn ofTileSize(tile_size: f32) CollisionStrips {
        std.debug.assert(std.math.isFinite(tile_size) and tile_size > 0);
        // tile_size = significand * 2^exponent, significand in [0.5, 1).
        const parts = std.math.frexp(tile_size);
        return .{ .height = std.math.ldexp(@as(f32, 1), parts.exponent - 1) };
    }

    pub fn ofWorld(world: *const WorldSystem) CollisionStrips {
        const strips = ofTileSize(world.tile_size);
        std.debug.assert(@as(f32, @floatFromInt(world.height)) * world.tile_size / strips.height <= strip_count);
        return strips;
    }
};

// One fill slot as resolved this step; `entity` is invalid for a slot with no movement body.
const ProxyRow = struct {
    entity: EntityId,
    movement_index: u32,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    /// Pre-response velocity, so contacts carry an approach-speed snapshot the response has
    /// not yet zeroed.
    velocity_x: f32,
    velocity_y: f32,
    // The fill input the slot read: an index into the scope list, or into the bounds rows.
    source: u32,
};

const ProxyColumns = struct {
    entity: []EntityId,
    movement_index: []u32,
    min_x: []f32,
    min_y: []f32,
    max_x: []f32,
    max_y: []f32,
    velocity_x: []f32,
    velocity_y: []f32,
    source: []u32,

    fn of(rows: std.MultiArrayList(ProxyRow).Slice) ProxyColumns {
        return .{
            .entity = rows.items(.entity),
            .movement_index = rows.items(.movement_index),
            .min_x = rows.items(.min_x),
            .min_y = rows.items(.min_y),
            .max_x = rows.items(.max_x),
            .max_y = rows.items(.max_y),
            .velocity_x = rows.items(.velocity_x),
            .velocity_y = rows.items(.velocity_y),
            .source = rows.items(.source),
        };
    }
};

const ConstProxyColumns = struct {
    entity: []const EntityId,
    movement_index: []const u32,
    min_x: []const f32,
    min_y: []const f32,
    max_x: []const f32,
    max_y: []const f32,
    velocity_x: []const f32,
    velocity_y: []const f32,
    source: []const u32,

    fn of(rows: std.MultiArrayList(ProxyRow).Slice) ConstProxyColumns {
        return .{
            .entity = rows.items(.entity),
            .movement_index = rows.items(.movement_index),
            .min_x = rows.items(.min_x),
            .min_y = rows.items(.min_y),
            .max_x = rows.items(.max_x),
            .max_y = rows.items(.max_y),
            .velocity_x = rows.items(.velocity_x),
            .velocity_y = rows.items(.velocity_y),
            .source = rows.items(.source),
        };
    }
};

// One sweep copy's sort element. The key is (level, strip, ordered min_x, ordered min_y,
// entity index), most significant first: total, since a body has one copy per strip.
const SortEntry = struct {
    key: u128,
    slot: u32,
    // The copy in the body's first strip.
    first: bool,
};

fn sortKeyOf(entry: SortEntry) u128 {
    return entry.key;
}

const EntrySort = banded_sort.BandedSort(SortEntry, sortKeyOf);
const SortEntryList = std.array_list.Aligned(SortEntry, .fromByteUnits(thread_shared_record_alignment));

comptime {
    std.debug.assert(@sizeOf(SortEntry) == 32);
    // With a 16-slot range alignment every fill range's windows start on a cache line.
    std.debug.assert(collision_range_alignment_items * @sizeOf(SortEntry) % thread_shared_record_alignment == 0);
}

fn entryLessThan(_: void, lhs: SortEntry, rhs: SortEntry) bool {
    return lhs.key < rhs.key;
}

// The key of a copy in `run`. Its u32 words store low word first.
fn packKey(run: u32, ordered_min_x: u32, ordered_min_y: u32, entity_index: u32) u128 {
    comptime std.debug.assert(builtin.cpu.arch.endian() == .little);
    return @bitCast([4]u32{ entity_index, ordered_min_y, ordered_min_x, run });
}

// A (level, strip) run's id: the key's top word.
fn runOf(level: u16, strip: u32) u32 {
    return (@as(u32, level) << 16) | strip;
}

fn keyRun(key: u128) u32 {
    return @truncate(key >> 96);
}

// One sweep entry, in key order.
const EntryRow = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    run: u32,
    // 1 for the copy in the body's first strip, else 0.
    first: u32,
    slot: u32,
};

const EntryColumns = struct {
    min_x: []f32,
    min_y: []f32,
    max_x: []f32,
    max_y: []f32,
    run: []u32,
    first: []u32,
    slot: []u32,

    fn of(rows: std.MultiArrayList(EntryRow).Slice) EntryColumns {
        return .{
            .min_x = rows.items(.min_x),
            .min_y = rows.items(.min_y),
            .max_x = rows.items(.max_x),
            .max_y = rows.items(.max_y),
            .run = rows.items(.run),
            .first = rows.items(.first),
            .slot = rows.items(.slot),
        };
    }
};

const ConstEntryColumns = struct {
    min_x: []const f32,
    min_y: []const f32,
    max_x: []const f32,
    max_y: []const f32,
    run: []const u32,
    first: []const u32,
    slot: []const u32,

    fn of(rows: std.MultiArrayList(EntryRow).Slice) ConstEntryColumns {
        return .{
            .min_x = rows.items(.min_x),
            .min_y = rows.items(.min_y),
            .max_x = rows.items(.max_x),
            .max_y = rows.items(.max_y),
            .run = rows.items(.run),
            .first = rows.items(.first),
            .slot = rows.items(.slot),
        };
    }
};

// Ends every sweep: no min_x is below a max_x past +inf.
const sentinel_entry = EntryRow{
    .min_x = std.math.inf(f32),
    .min_y = 0,
    .max_x = 0,
    .max_y = 0,
    .run = std.math.maxInt(u32),
    .first = 0,
    .slot = 0,
};

// One fill range's copies past each body's second strip: written unplaced to `raw` while it
// has room, then placed by band into `placed`. Past `raw`'s capacity the range counts on in
// `required` and the fill replays after the main thread grows both. Never reserved: only
// bodies taller than a strip spill.
const SpillCopies = struct {
    raw: std.ArrayList(SortEntry) = .empty,
    placed: std.ArrayList(SortEntry) = .empty,
    required: usize = 0,
    offsets: BandOffsets = .{},

    fn clearRetainingCapacity(self: *SpillCopies) void {
        self.raw.clearRetainingCapacity();
        self.placed.clearRetainingCapacity();
        self.required = 0;
        self.offsets = .{};
    }

    fn append(self: *SpillCopies, entry: SortEntry) void {
        self.required += 1;
        if (self.raw.items.len < self.raw.capacity) self.raw.appendAssumeCapacity(entry);
    }

    fn overflowed(self: *const SpillCopies) bool {
        return self.required > self.raw.capacity;
    }

    // Both lists hold at least `capacity` copies, grown geometrically.
    fn grow(self: *SpillCopies, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.raw.ensureTotalCapacity(allocator, capacity);
        try self.placed.ensureTotalCapacityPrecise(allocator, self.raw.capacity);
    }

    fn deinit(self: *SpillCopies, allocator: std.mem.Allocator) void {
        self.placed.deinit(allocator);
        self.raw.deinit(allocator);
        self.* = undefined;
    }
};

// The fill ranges' band-placed spilled copies, a segment source of the banded sort's gather.
const SpillSource = struct {
    slots: []const PaddedSlot(SpillCopies),

    pub fn rangeCount(self: SpillSource) usize {
        return self.slots.len;
    }

    /// Range `range_index`'s spilled copies of `band`.
    pub fn segment(self: SpillSource, range_index: usize, band: usize) []const SortEntry {
        const copies = &self.slots[range_index].value;
        return copies.placed.items[copies.offsets.offsets[band]..copies.offsets.offsets[band + 1]];
    }
};

pub const CollisionConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    strips: CollisionStrips = .default,
    /// When non-null, only these dense collision-bounds indices generate contacts
    /// this step (the scope system excludes dormant/kinematic entities). Null = all.
    scope_dense_indices: ?[]const u32 = null,
};

const Threads = StageThreads(CollisionConfig);

pub const CollisionStats = struct {
    /// Bodies swept: fill inputs with a movement body.
    body_count: usize = 0,
    /// Sweep entries: one per strip each body spans.
    entry_count: usize = 0,
    contact_count: usize = 0,
    candidate_pair_count: usize = 0,
    /// Sweep lane groups. Counted only with `runtime_perf_log.enabled`, else 0.
    broadphase_simd_groups: usize = 0,
    broadphase_batch: BatchStats = .{},
    narrowphase_batch: BatchStats = .{},
    /// This step outgrew the reserved pair bound, so a main-thread grow path ran: the
    /// candidate pairs exceeded `CollisionSystem.reserved_pair_bound`, or a broadphase
    /// range held more than `broadphase_pairs_per_item` pairs per entry its slot was
    /// reserved for (the slot grew and the broadphase replayed).
    pair_bound_exceeded: bool = false,
    perf: Perf = .{},

    /// Kept only with `runtime_perf_log.enabled`: the entries the sweep tested against an
    /// earlier entry of its run inside that entry's x span, and the fill and sort batches.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        broadphase_visits: usize = 0,
        fill_batch: BatchStats = .{},
        sort_batch: BatchStats = .{},
    } else struct {};
};

const CandidatePair = struct {
    // Proxy slots; `a` sorts first.
    a: u32,
    b: u32,
};

const BroadphaseRangeBuffer = struct {
    pairs: std.ArrayList(CandidatePair) = .empty,
    required_capacity: usize = 0,
    simd_groups: usize = 0,
    perf: SweepPerf = .{},

    fn clearRetainingCapacity(self: *BroadphaseRangeBuffer) void {
        self.pairs.clearRetainingCapacity();
        self.required_capacity = 0;
        self.simd_groups = 0;
        self.perf = .{};
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

const BroadphaseRangeSlot = struct {
    // Each worker writes only its assigned slot. Padding keeps hot append state
    // from sharing cache lines across concurrently written range records.
    buffer: BroadphaseRangeBuffer = .{},
    padding: [paddingForCacheLine(BroadphaseRangeBuffer)]u8 = @splat(0),
};

const BroadphaseRangeSlotList = std.array_list.Aligned(BroadphaseRangeSlot, .fromByteUnits(thread_shared_record_alignment));

/// Narrowphase emits at most one contact per candidate pair, so it needs no per-range
/// buffers: range r writes only its own `[range.start, range.end)` window of one
/// candidate-pair-count staging list and its count into a padded tally; the main
/// thread streams the windows in range order.
const ContactStagingList = std.array_list.Aligned(CollisionContact, .fromByteUnits(thread_shared_record_alignment));

/// One narrowphase range's contact count, written once by the range's job.
const ContactCountTally = struct {
    // Padding keeps concurrently written tallies off shared cache lines.
    count: usize = 0,
    padding: [paddingForCacheLine(usize)]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(ContactCountTally) % thread_shared_record_alignment == 0);
    std.debug.assert(@sizeOf(PaddedSlot(SpillCopies)) % thread_shared_record_alignment == 0);
}

const ContactCountTallyList = std.array_list.Aligned(ContactCountTally, .fromByteUnits(thread_shared_record_alignment));

// A fill's band starts: band b's entries are `[entry_start[b], entry_start[b + 1])`, of
// which the first copies rank `[first_start[b], first_start[b + 1])` among all first copies.
const BandStarts = struct {
    entry_start: [band_count + 1]u32,
    first_start: [band_count + 1]u32,
};

pub const CollisionSystem = struct {
    allocator: std.mem.Allocator,
    // By fill slot.
    proxies: std.MultiArrayList(ProxyRow) = .{},
    // Sort elements in sweep order; a threaded fill first writes each range's first copies
    // into its window.
    keys: SortEntryList = .empty,
    // A threaded fill's band-placed first-copy windows.
    staging: SortEntryList = .empty,
    first_offsets: SlotList(BandOffsets) = .empty,
    // By fill slot window: the second copies of the slots' bodies, then (threaded) their
    // band-placed windows.
    second_scratch: SortEntryList = .empty,
    second_staging: SortEntryList = .empty,
    second_offsets: SlotList(BandOffsets) = .empty,
    // Per fill range; grow-only, so each slot keeps its lists' capacity.
    spill_slots: SlotList(SpillCopies) = .empty,
    // In sweep order, then `simd.lane_count` sentinel rows.
    entries: std.MultiArrayList(EntryRow) = .{},
    // The last step's first copies' fill inputs in sweep order: slot p's input next step.
    warm_sources: std.ArrayList(u32) = .empty,
    // The input count `warm_sources` orders; 0 when the last step left no full order.
    warm_count: usize = 0,
    broadphase_ranges: BroadphaseRangeSlotList = .empty,
    candidate_pairs: std.ArrayList(CandidatePair) = .empty,
    narrowphase_staging: ContactStagingList = .empty,
    narrowphase_tallies: ContactCountTallyList = .empty,
    fill_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    sort_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    broadphase_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    narrowphase_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    /// The pair bound `reserve` declared (`broadphasePairBound(body_capacity)`, grow-only);
    /// 0 until `reserve` runs. Telemetry compares against this logical limit, never a
    /// list's `.capacity`, which `ensureTotalCapacity` rounds past it.
    reserved_pair_bound: usize = 0,
    /// The entry bound `reserve` declared (`entries_per_body` per body, grow-only); 0 until
    /// `reserve` runs.
    reserved_entry_bound: usize = 0,
    pair_bound_warned: bool = false,
    entry_bound_warned: bool = false,
    perf: Perf = .{},

    /// Telemetry, kept only with `runtime_perf_log.enabled`. Every grow path it counts runs on
    /// the main thread between batches; the contacts are identical either way, and each
    /// warns once.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        /// Reserved steps that outgrew the pair bound (perf metric
        /// `collision_pair_bound_exceeded`), counted once per step. Either the candidate
        /// pairs exceeded `reserved_pair_bound`, so the merged candidates, the narrowphase
        /// staging, the contact stream and the response reserves (all sized to that bound
        /// under the pipeline) grew, or a range's pairs outgrew its broadphase slot, so the
        /// slot grew and the broadphase replayed.
        pair_bound_overflows: u64 = 0,
        /// Reserved steps whose entries exceeded `reserved_entry_bound` (the keys and entries
        /// grew the first time) or whose fill spilled past a range's spill slot (the slot
        /// grew and the fill replayed), counted once per step.
        entry_bound_overflows: u64 = 0,
    } else struct {};

    pub fn init(allocator: std.mem.Allocator) CollisionSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CollisionSystem) void {
        self.narrowphase_tallies.deinit(self.allocator);
        self.narrowphase_staging.deinit(self.allocator);
        self.candidate_pairs.deinit(self.allocator);
        for (self.broadphase_ranges.items) |*slot| slot.buffer.deinit(self.allocator);
        self.broadphase_ranges.deinit(self.allocator);
        self.warm_sources.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        for (self.spill_slots.items) |*slot| slot.value.deinit(self.allocator);
        self.spill_slots.deinit(self.allocator);
        self.second_offsets.deinit(self.allocator);
        self.second_staging.deinit(self.allocator);
        self.second_scratch.deinit(self.allocator);
        self.first_offsets.deinit(self.allocator);
        self.staging.deinit(self.allocator);
        self.keys.deinit(self.allocator);
        self.proxies.deinit(self.allocator);
        self.* = undefined;
    }

    /// Pre-sizes every step buffer for `body_capacity` bodies, so the serial and threaded
    /// paths are allocation-free from the first step under every partition the tuners can
    /// pick. Grow-only; re-run by the pipeline's population seam.
    ///
    /// A body's first and second copies write their slot's own windows, so the fill
    /// reserves O(bodies); copies past a second strip spill to unreserved per-range slots.
    /// Broadphase pairs are data-dependent and keep per-range slots sized for the most
    /// entries range r of any partition covers (`@divCeil(entries, r + 1)`, r full ranges
    /// precede it), never clamped to the total: `broadphase_pairs_per_item` pairs per entry
    /// for every `r < maxRangeCount`. The keys and entries hold `entries_per_body` per body;
    /// the merged candidates, the narrowphase staging (at most one contact per candidate
    /// pair, one window per range), and its tallies hold the pair bound over the body
    /// capacity (`broadphasePairBound`). A denser or taller scene, in total or inside one
    /// range, takes the counted grow paths (`Perf`).
    pub fn reserve(self: *CollisionSystem, body_capacity: usize) !void {
        if (body_capacity == 0) return;
        // The u32 slots, sources, and pair indices are exhausted only past maxInt(u32)
        // proxies, which the entity index cannot reach; past it this is allocator exhaustion.
        if (body_capacity > std.math.maxInt(u32) / entries_per_body) return error.OutOfMemory;
        const entry_capacity = body_capacity * entries_per_body;
        const pair_capacity = broadphasePairBound(body_capacity);
        try self.proxies.ensureTotalCapacity(self.allocator, hotStoreCapacity(body_capacity));
        try self.keys.ensureTotalCapacity(self.allocator, entry_capacity);
        try self.staging.ensureTotalCapacity(self.allocator, body_capacity);
        try self.entries.ensureTotalCapacity(self.allocator, hotStoreCapacity(entry_capacity + simd.lane_count));
        try self.warm_sources.ensureTotalCapacity(self.allocator, body_capacity);
        try self.second_scratch.ensureTotalCapacity(self.allocator, body_capacity);
        try self.second_staging.ensureTotalCapacity(self.allocator, body_capacity);
        const fill_range_count = maxRangeCount(body_capacity, collision_range_alignment_items);
        try self.first_offsets.ensureTotalCapacity(self.allocator, fill_range_count);
        try self.second_offsets.ensureTotalCapacity(self.allocator, fill_range_count);
        try self.prepareSpillSlots(fill_range_count);
        try self.candidate_pairs.ensureTotalCapacity(self.allocator, pair_capacity);
        const broadphase_range_count = maxRangeCount(entry_capacity, collision_range_alignment_items);
        try self.prepareBroadphaseRangeBuffers(broadphase_range_count);
        for (self.broadphase_ranges.items[0..broadphase_range_count], 0..) |*slot, range_index| {
            // Precise: the bound is exact, so no geometric slack per slot.
            try slot.buffer.pairs.ensureTotalCapacityPrecise(self.allocator, broadphasePairBound(@divCeil(entry_capacity, range_index + 1)));
        }
        try self.narrowphase_staging.ensureTotalCapacityPrecise(self.allocator, pair_capacity);
        try self.narrowphase_tallies.ensureTotalCapacityPrecise(self.allocator, maxRangeCount(pair_capacity, collision_range_alignment_items));
        self.reserved_pair_bound = @max(self.reserved_pair_bound, pair_capacity);
        self.reserved_entry_bound = @max(self.reserved_entry_bound, entry_capacity);
    }

    /// Reserves a contact stream to the pair bound for `body_capacity` bodies: its
    /// values to `estimateContactCapacity` and its ranges to the narrowphase's range
    /// bound over those pairs (`update` streams one range per narrowphase range, at most
    /// `maxRangeCount(pairs, collision_range_alignment_items)`; the serial path uses
    /// one). Grow-only.
    pub fn reserveContactStream(contacts: *RangeOutputStream(CollisionContact), body_capacity: usize) !void {
        const contact_capacity = estimateContactCapacity(body_capacity);
        try contacts.reserve(maxRangeCount(contact_capacity, collision_range_alignment_items), contact_capacity);
    }

    /// One collision step over the bounds rows (or `config.scope_dense_indices`): the fill,
    /// sort, broadphase, and narrowphase each on workers under their own tuner, or inline
    /// as they select; with no worker available the step runs serially. Allocates only past
    /// `reserve`'s bounds, on the calling thread between dispatches.
    pub fn update(
        self: *CollisionSystem,
        data: *const DataSystem,
        contacts: *RangeOutputStream(CollisionContact),
        thread_system: *ThreadSystem,
        config: CollisionConfig,
    ) !CollisionStats {
        const threads = Threads.withWorkers(.{ .thread_system = thread_system, .config = config }) orelse
            return self.updateDirect(data, contacts, config.scope_dense_indices, config.strips);
        var stats = CollisionStats{};
        if (!try self.buildBanded(data, config.scope_dense_indices, config.strips, threads, &stats)) {
            contacts.clearRetainingCapacity();
            return stats;
        }

        const broadphase_stage = threads.stage(&self.broadphase_tuner);
        const broadphase_selection = broadphase_stage.select(stats.entry_count, collision_range_alignment_items);
        const broadphase = try self.buildBroadphaseCandidatesThreaded(thread_system, broadphase_selection, stats.entry_count);
        if (broadphase_selection.active_tuner) |tuner| tuner.record(broadphase.batch);
        stats.broadphase_batch = broadphase.batch;
        stats.broadphase_simd_groups = broadphase.simd_groups;
        if (comptime runtime_perf_log.enabled) stats.perf.broadphase_visits = broadphase.perf.visits;
        const candidate_pair_count = self.candidate_pairs.items.len;
        stats.candidate_pair_count = candidate_pair_count;
        if (candidate_pair_count == 0) {
            contacts.clearRetainingCapacity();
            return stats;
        }
        stats.pair_bound_exceeded = self.countPairBoundOverflow(candidate_pair_count, broadphase.grew);

        const narrowphase_stage = threads.stage(&self.narrowphase_tuner);
        const narrowphase_selection = narrowphase_stage.select(candidate_pair_count, collision_range_alignment_items);
        try self.prepareNarrowphaseStaging(candidate_pair_count, narrowphase_selection.range_count);
        var context = NarrowphaseJobContext{
            .system = self,
            .range_count = narrowphase_selection.range_count,
            .candidate_pair_count = candidate_pair_count,
            .items_per_range = narrowphase_selection.items_per_range,
        };
        stats.narrowphase_batch = narrowphase_stage.run(narrowphase_selection, candidate_pair_count, collision_range_alignment_items, &context, narrowphaseContactsJob);
        stats.contact_count = try self.mergeNarrowphaseContacts(contacts, narrowphase_selection.items_per_range);
        return stats;
    }

    // The serial step: one fill straight into the keys, one band's sort, one sweep, and one
    // narrowphase range.
    fn updateDirect(
        self: *CollisionSystem,
        data: *const DataSystem,
        contacts: *RangeOutputStream(CollisionContact),
        scope_dense_indices: ?[]const u32,
        strips: CollisionStrips,
    ) !CollisionStats {
        var stats = CollisionStats{};
        if (!try self.buildDirect(data, scope_dense_indices, strips, &stats)) {
            contacts.clearRetainingCapacity();
            return stats;
        }

        const broadphase = try self.buildBroadphaseCandidatesDirect(stats.entry_count);
        stats.broadphase_batch = inlineBatch(stats.entry_count, collision_range_alignment_items);
        stats.broadphase_simd_groups = broadphase.simd_groups;
        if (comptime runtime_perf_log.enabled) stats.perf.broadphase_visits = broadphase.perf.visits;
        const candidate_pair_count = self.candidate_pairs.items.len;
        stats.candidate_pair_count = candidate_pair_count;
        if (candidate_pair_count == 0) {
            contacts.clearRetainingCapacity();
            return stats;
        }
        stats.pair_bound_exceeded = self.countPairBoundOverflow(candidate_pair_count, broadphase.grew);

        try self.prepareNarrowphaseStaging(candidate_pair_count, 1);
        writeNarrowphaseContactsSimd(self, .{ .index = 0, .start = 0, .end = candidate_pair_count });
        stats.narrowphase_batch = inlineBatch(candidate_pair_count, collision_range_alignment_items);
        stats.contact_count = try self.mergeNarrowphaseContacts(contacts, candidate_pair_count);
        return stats;
    }

    // ---- Fill and sort ------------------------------------------------------------

    // Sizes the step's slot buffers for `input_count` fill inputs: the proxies, the keys
    // as the fill's first-copy output, and the warm order's capacity.
    fn beginStep(self: *CollisionSystem, input_count: usize) !void {
        // u32 slots and sources: the bounds rows are indexed by u32 entity rows.
        std.debug.assert(input_count <= std.math.maxInt(u32));
        try self.proxies.ensureTotalCapacity(self.allocator, hotStoreCapacity(input_count));
        setRowCount(ProxyRow, &self.proxies, input_count);
        try self.keys.ensureTotalCapacity(self.allocator, input_count);
        self.keys.items.len = input_count;
        try self.second_scratch.ensureTotalCapacity(self.allocator, input_count);
        self.second_scratch.items.len = input_count;
        try self.warm_sources.ensureTotalCapacity(self.allocator, input_count);
    }

    // A step with no fill input: no entries and no warm order.
    fn finishEmpty(self: *CollisionSystem) void {
        self.proxies.clearRetainingCapacity();
        self.keys.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
        self.warm_count = 0;
    }

    fn fillContext(self: *CollisionSystem, data: *const DataSystem, scope_dense_indices: ?[]const u32, strips: CollisionStrips, input_count: usize) FillContext {
        return .{
            .data = data,
            .bounds = data.collisionBoundsSliceConst(),
            .movement = data.movementBodySliceConst(),
            .levels = data.worldLevelSliceConst().levels,
            .scope = scope_dense_indices,
            .warm_sources = if (self.warm_count == input_count) self.warm_sources.items[0..input_count] else null,
            .strips = strips,
            .proxies = ProxyColumns.of(self.proxies.slice()),
        };
    }

    // The serial build: the fill writes every first copy to the keys, every second copy to
    // the second scratch, and every spilled copy to spill slot 0, replaying past its
    // capacity; each run sorts on its own and merges into the first copies from the back,
    // one band. On a warm order the first and second runs arrive sorted, so their sort is
    // linear. Returns whether more than one body was filled.
    fn buildDirect(self: *CollisionSystem, data: *const DataSystem, scope_dense_indices: ?[]const u32, strips: CollisionStrips, stats: *CollisionStats) !bool {
        const input_count = fillInputCount(data, scope_dense_indices);
        if (input_count == 0) {
            self.finishEmpty();
            return false;
        }
        try self.beginStep(input_count);
        try self.prepareSpillSlots(1);
        const spill = &self.spill_slots.items[0].value;
        const fill = self.fillContext(data, scope_dense_indices, strips, input_count);
        var fill_grew = false;
        const counts = while (true) {
            spill.clearRetainingCapacity();
            const counts = fillSlots(&fill, 0, input_count, self.keys.items[0..input_count], self.second_scratch.items[0..input_count], spill);
            if (!spill.overflowed()) break counts;
            try spill.grow(self.allocator, spill.required);
            fill_grew = true;
        };
        const seconds = self.second_scratch.items[0..counts.seconds];
        const head_count = counts.firsts + counts.seconds;
        const entry_count = head_count + spill.raw.items.len;
        if (comptime runtime_perf_log.enabled) stats.perf.fill_batch = inlineBatch(input_count, collision_range_alignment_items);
        pdqSort(SortEntry, self.keys.items[0..counts.firsts], {}, entryLessThan);
        pdqSort(SortEntry, seconds, {}, entryLessThan);
        pdqSort(SortEntry, spill.raw.items, {}, entryLessThan);
        // The keys keep the first copies through the resize.
        try self.sizeEntries(entry_count, input_count);
        mergeIntoSorted(self.keys.items[0..head_count], counts.firsts, seconds);
        mergeIntoSorted(self.keys.items[0..entry_count], head_count, spill.raw.items);
        if (entry_count != 0) self.entryWriter().writeSorted(0, @intCast(entry_count), 0);
        if (comptime runtime_perf_log.enabled) stats.perf.sort_batch = inlineBatch(entry_count, collision_range_alignment_items);
        return self.finishBuild(input_count, counts.firsts, entry_count, fill_grew, stats);
    }

    // The threaded build: `collision_fill` over the slots into the bands of sampled
    // splitters, the band starts on the main thread, then `collision_sort` over the entries.
    // Returns whether more than one body was filled.
    fn buildBanded(self: *CollisionSystem, data: *const DataSystem, scope_dense_indices: ?[]const u32, strips: CollisionStrips, threads: Threads, stats: *CollisionStats) !bool {
        const input_count = fillInputCount(data, scope_dense_indices);
        if (input_count == 0) {
            self.finishEmpty();
            return false;
        }
        try self.beginStep(input_count);
        try self.staging.ensureTotalCapacity(self.allocator, input_count);
        self.staging.items.len = input_count;
        try self.second_staging.ensureTotalCapacity(self.allocator, input_count);
        self.second_staging.items.len = input_count;
        const fill = self.fillContext(data, scope_dense_indices, strips, input_count);

        const fill_stage = threads.stage(&self.fill_tuner);
        const fill_selection = fill_stage.select(input_count, collision_range_alignment_items);
        const range_count = fill_selection.range_count;
        try self.first_offsets.ensureTotalCapacity(self.allocator, range_count);
        setSlotCount(BandOffsets, &self.first_offsets, range_count);
        try self.second_offsets.ensureTotalCapacity(self.allocator, range_count);
        setSlotCount(BandOffsets, &self.second_offsets, range_count);
        try self.prepareSpillSlots(range_count);
        const spill_slots = self.spill_slots.items[0..range_count];
        var fill_job = FillJob{
            .fill = fill,
            .splitters = chooseSplitters(&fill, input_count),
            .scratch = self.keys.items[0..input_count],
            .staging = self.staging.items[0..input_count],
            .second_scratch = self.second_scratch.items[0..input_count],
            .second_staging = self.second_staging.items[0..input_count],
            .items_per_range = fill_selection.items_per_range,
            .first_offsets = self.first_offsets.items,
            .second_offsets = self.second_offsets.items,
            .spill_slots = spill_slots,
        };
        var fill_grew = false;
        while (true) {
            for (spill_slots) |*slot| slot.value.clearRetainingCapacity();
            const batch = threads.thread_system.parallelForWithOptions(input_count, &fill_job, fillJob, .{
                .max_worker_threads = fill_selection.worker_threads,
                .range_alignment_items = collision_range_alignment_items,
                .selected_profile = fill_selection.profile,
            });
            // Fill jobs do not allocate: a range past its spill slot grows here and the fill
            // replays. Only the final batch reaches the tuner.
            if (try self.growSpillSlotsIfNeeded(spill_slots)) {
                fill_grew = true;
                continue;
            }
            if (fill_selection.active_tuner) |tuner| tuner.record(batch);
            if (comptime runtime_perf_log.enabled) stats.perf.fill_batch = batch;
            break;
        }

        const bands = bandStarts(self.first_offsets.items, self.second_offsets.items, spill_slots);
        const entry_count: usize = bands.entry_start[band_count];
        const first_count: usize = bands.first_start[band_count];
        try self.sizeEntries(entry_count, input_count);
        if (entry_count != 0) {
            const sort_stage = threads.stage(&self.sort_tuner);
            const sort_selection = sort_stage.select(entry_count, collision_range_alignment_items);
            var sort_job = SortJob{
                .firsts = .{ .staging = self.staging.items, .band_offsets = self.first_offsets.items, .window_stride = fill_selection.items_per_range },
                .seconds = .{ .staging = self.second_staging.items, .band_offsets = self.second_offsets.items, .window_stride = fill_selection.items_per_range },
                .spills = .{ .slots = spill_slots },
                .bands = bands,
                .writer = self.entryWriter(),
                .range_count = sort_selection.range_count,
            };
            const sort_batch = sort_stage.run(sort_selection, entry_count, collision_range_alignment_items, &sort_job, sortJob);
            if (comptime runtime_perf_log.enabled) stats.perf.sort_batch = sort_batch;
        }
        return self.finishBuild(input_count, first_count, entry_count, fill_grew, stats);
    }

    // Sizes the keys and entries for `entry_count` entries, writes the sentinel rows past
    // them, and sizes the warm order to `input_count`. Main thread, before the sort.
    fn sizeEntries(self: *CollisionSystem, entry_count: usize, input_count: usize) !void {
        // u32 entry indices and band offsets: past maxInt(u32) copies this is allocator
        // exhaustion.
        if (entry_count > std.math.maxInt(u32) - simd.lane_count) return error.OutOfMemory;
        try self.keys.ensureTotalCapacity(self.allocator, entry_count);
        self.keys.items.len = entry_count;
        const row_count = entry_count + simd.lane_count;
        try self.entries.ensureTotalCapacity(self.allocator, hotStoreCapacity(row_count));
        setRowCount(EntryRow, &self.entries, row_count);
        for (entry_count..row_count) |row| self.entries.set(row, sentinel_entry);
        std.debug.assert(self.warm_sources.capacity >= input_count);
        self.warm_sources.items.len = input_count;
    }

    // Records the build's counts and whether its order is warm for the next step.
    fn finishBuild(self: *CollisionSystem, input_count: usize, first_count: usize, entry_count: usize, fill_grew: bool, stats: *CollisionStats) bool {
        // Every input filled: `warm_sources` is a permutation of them.
        self.warm_count = if (first_count == input_count) input_count else 0;
        stats.body_count = first_count;
        stats.entry_count = entry_count;
        self.countEntryBoundOverflow(entry_count, fill_grew);
        return first_count > 1;
    }

    fn entryWriter(self: *CollisionSystem) EntryWriter {
        return .{
            .keys = self.keys.items,
            .proxies = ConstProxyColumns.of(self.proxies.slice()),
            .entries = EntryColumns.of(self.entries.slice()),
            .warm_sources = self.warm_sources.items,
        };
    }

    // Spill slot records for `range_count` ranges; their lists start empty.
    fn prepareSpillSlots(self: *CollisionSystem, range_count: usize) !void {
        try self.spill_slots.ensureTotalCapacity(self.allocator, range_count);
        while (self.spill_slots.items.len < range_count) self.spill_slots.appendAssumeCapacity(.{});
    }

    fn growSpillSlotsIfNeeded(self: *CollisionSystem, slots: []PaddedSlot(SpillCopies)) !bool {
        var grew = false;
        for (slots) |*slot| {
            if (!slot.value.overflowed()) continue;
            try slot.value.grow(self.allocator, slot.value.required);
            grew = true;
        }
        return grew;
    }

    // ---- Broadphase and narrowphase -----------------------------------------------

    /// Sizes the narrowphase staging to `candidate_pair_count` window slots and resets
    /// `range_count` tallies. Main thread, before dispatch. Grow-only safety nets: after
    /// `reserve` they allocate only when candidate pairs outgrow the reserved pair
    /// capacity (the kept pair-density path), never for a partition change.
    fn prepareNarrowphaseStaging(self: *CollisionSystem, candidate_pair_count: usize, range_count: usize) !void {
        try self.narrowphase_staging.ensureTotalCapacity(self.allocator, candidate_pair_count);
        self.narrowphase_staging.items.len = candidate_pair_count;
        try self.narrowphase_tallies.ensureTotalCapacity(self.allocator, range_count);
        self.narrowphase_tallies.items.len = range_count;
        for (self.narrowphase_tallies.items) |*slot| slot.count = 0;
    }

    /// Streams each range's staging window (`count` contacts at `r * items_per_range`)
    /// into `contacts` in range order.
    fn mergeNarrowphaseContacts(
        self: *CollisionSystem,
        contacts: *RangeOutputStream(CollisionContact),
        items_per_range: usize,
    ) !usize {
        const tallies = self.narrowphase_tallies.items;
        try contacts.prepareRangeCounts(tallies.len);
        var contact_count: usize = 0;
        for (tallies, 0..) |*slot, range_index| {
            contacts.addCount(range_index, slot.count);
            contact_count += slot.count;
        }
        try contacts.prefix();
        const staging = self.narrowphase_staging.items;
        for (tallies, 0..) |*slot, range_index| {
            var writer = contacts.rangeWriter(range_index);
            const window_start = range_index * items_per_range;
            for (staging[window_start..][0..slot.count]) |contact| {
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

    /// Warms any slot `reserve` did not size (an unreserved system, or more entries than
    /// the reserved capacity). Returns whether any slot allocated.
    fn reserveInitialBroadphaseRangeCapacity(self: *CollisionSystem, selection: BatchSelection, entry_count: usize) !bool {
        var grew = false;
        for (self.broadphase_ranges.items[0..selection.range_count], 0..) |*slot, range_index| {
            const buffer = &slot.buffer;
            if (buffer.pairs.capacity != 0) continue;
            const range_len = rangeLenForIndex(entry_count, selection.items_per_range, range_index);
            const target_capacity = estimateBroadphasePairCapacity(entry_count, range_len);
            try buffer.pairs.ensureTotalCapacity(self.allocator, target_capacity);
            grew = true;
        }
        return grew;
    }

    /// Shared broadphase pair-capacity WARM heuristic (not a combinatorial
    /// worst-case ceiling): `broadphase_pairs_per_item` candidate pairs per swept entry
    /// in the range, bounded below by one SIMD lane group and above by the total entry
    /// count. Dense/clustered scenes can exceed this; both serial and threaded paths
    /// grow-and-replay when they do. Used to pre-size the per-range scratch buffers for
    /// the threaded broadphase and `candidate_pairs` for the serial broadphase when
    /// `reserve` has not run (`reserve` sizes both to the unclamped `broadphasePairBound`).
    fn estimateBroadphasePairCapacity(entry_count: usize, range_len: usize) usize {
        return @min(entry_count, @max(simd.lane_count, broadphasePairBound(range_len)));
    }

    /// `broadphase_pairs_per_item` pairs for each of `item_count` items (saturating): over
    /// the most entries a range can cover, the size `reserve` gives its slot; over a whole
    /// body capacity, the bound it sizes the merged candidates, narrowphase staging and
    /// tallies to.
    fn broadphasePairBound(item_count: usize) usize {
        return std.math.mul(usize, item_count, broadphase_pairs_per_item) catch std.math.maxInt(usize);
    }

    /// Contact-stream capacity for `body_capacity` bodies: the pair bound
    /// (`broadphasePairBound`, `broadphase_pairs_per_item` per body). Collision's own
    /// domain knowledge for callers sizing `SimulationFrame.reserveStreams`,
    /// `SimulationPipelineConfig.contact_capacity`, the trigger stream and the response
    /// reserves. Narrow-phase contacts are a subset of broadphase candidates, so a scene
    /// within the bound that `reserve` sizes the collision stores to never outgrows a
    /// stream reserved to it. Past it, the streams grow on the main thread
    /// (`RangeOutputStream.prefix`, the response's intent ensure), counted in
    /// `perf.pair_bound_overflows`; this is not a drop ceiling (`SimulationEvents` is the
    /// stream that drops).
    pub fn estimateContactCapacity(body_capacity: usize) usize {
        return broadphasePairBound(body_capacity);
    }

    /// Counts, once, a reserved step that outgrew the pair bound: `candidate_pair_count`
    /// exceeds `reserved_pair_bound`, or `broadphase_grew` (a broadphase slot or the
    /// serial candidate list grew in-stage). Main thread, after the broadphase merge and
    /// before the narrowphase dispatch.
    fn countPairBoundOverflow(self: *CollisionSystem, candidate_pair_count: usize, broadphase_grew: bool) bool {
        if (self.reserved_pair_bound == 0) return false;
        if (!broadphase_grew and candidate_pair_count <= self.reserved_pair_bound) return false;
        self.notePairBoundOverflow(candidate_pair_count);
        return true;
    }

    fn notePairBoundOverflow(self: *CollisionSystem, candidate_pair_count: usize) void {
        @branchHint(.cold);
        if (comptime runtime_perf_log.enabled) self.perf.pair_bound_overflows += 1;
        if (self.pair_bound_warned) return;
        self.pair_bound_warned = true;
        if (comptime logging.enabled(.warn)) logging.game.warn(
            "collision: {d} candidate pairs outgrew the reserved pair bound {d} (total or per range); collision stores or contact streams grew in-stage",
            .{ candidate_pair_count, self.reserved_pair_bound },
        );
    }

    /// Counts, once, a reserved step whose `entry_count` exceeds `reserved_entry_bound` or
    /// whose fill grew a spill slot in-stage (`fill_grew`). Main thread, after the fill.
    fn countEntryBoundOverflow(self: *CollisionSystem, entry_count: usize, fill_grew: bool) void {
        if (self.reserved_entry_bound == 0) return;
        if (!fill_grew and entry_count <= self.reserved_entry_bound) return;
        self.noteEntryBoundOverflow(entry_count, fill_grew);
    }

    // A spill slot growing is the designed path for bodies past their second strip (spill
    // slots are never reserved), so it logs at info; entries past the reserved bound warn.
    fn noteEntryBoundOverflow(self: *CollisionSystem, entry_count: usize, fill_grew: bool) void {
        @branchHint(.cold);
        if (comptime runtime_perf_log.enabled) self.perf.entry_bound_overflows += 1;
        if (self.entry_bound_warned) return;
        self.entry_bound_warned = true;
        if (entry_count > self.reserved_entry_bound) {
            if (comptime logging.enabled(.warn)) logging.game.warn(
                "collision: {d} sweep entries exceeded the reserved entry bound {d}; collision stores grew in-stage",
                .{ entry_count, self.reserved_entry_bound },
            );
        } else if (fill_grew) {
            if (comptime logging.enabled(.info)) logging.game.info(
                "collision spill slots grew for bodies past their second strip ({d} sweep entries)",
                .{entry_count},
            );
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

    // The serial sweep straight into `candidate_pairs`: append while it has room, count what
    // the scene needs, then grow once to it and replay (the sweep reads only const entry
    // columns), so the serial broadphase allocates nothing after warmup even when pairs
    // outnumber entries.
    fn buildBroadphaseCandidatesDirect(self: *CollisionSystem, entry_count: usize) !BroadphaseBuildResult {
        var buffer = BroadphaseRangeBuffer{ .pairs = self.candidate_pairs };
        defer self.candidate_pairs = buffer.pairs;
        try buffer.pairs.ensureTotalCapacity(self.allocator, estimateBroadphasePairCapacity(entry_count, entry_count));
        const entries = ConstEntryColumns.of(self.entries.slice());
        var grew = false;
        while (true) {
            buffer.clearRetainingCapacity();
            sweepEntries(entries, 0, entry_count, &buffer);
            if (buffer.overflowed()) {
                try buffer.pairs.ensureTotalCapacity(self.allocator, buffer.required_capacity);
                grew = true;
                continue;
            }
            return .{ .simd_groups = buffer.simd_groups, .perf = buffer.perf, .grew = grew };
        }
    }

    fn buildBroadphaseCandidatesThreaded(
        self: *CollisionSystem,
        thread_system: *ThreadSystem,
        selection: BatchSelection,
        entry_count: usize,
    ) !BroadphaseBuildResult {
        try self.prepareBroadphaseRangeBuffers(selection.range_count);
        var result = BroadphaseBuildResult{
            .grew = try self.reserveInitialBroadphaseRangeCapacity(selection, entry_count),
        };

        var context = BroadphaseJobContext{
            .system = self,
            .entries = ConstEntryColumns.of(self.entries.slice()),
            .range_count = selection.range_count,
            .entry_count = entry_count,
        };
        while (true) {
            for (self.broadphase_ranges.items[0..selection.range_count]) |*slot| {
                slot.buffer.clearRetainingCapacity();
            }
            const batch = thread_system.parallelForWithOptions(entry_count, &context, broadphaseCandidatesJob, .{
                .max_worker_threads = selection.worker_threads,
                .range_alignment_items = collision_range_alignment_items,
                .selected_profile = selection.profile,
            });

            // Broadphase jobs do not allocate. If a range overflows its warmed
            // buffer, grow after the batch and replay the stage deterministically.
            // Failed overflow passes are NOT recorded into broadphase_tuner —
            // only the final successful batch is returned (and recorded by update).
            if (try self.growBroadphaseRangeBuffersIfNeeded(selection.range_count)) {
                result.grew = true;
                continue;
            }

            result.batch = batch;
            for (self.broadphase_ranges.items[0..selection.range_count]) |*slot| {
                result.simd_groups += slot.buffer.simd_groups;
                if (comptime runtime_perf_log.enabled) result.perf.visits += slot.buffer.perf.visits;
            }
            try self.mergeBroadphaseRangeBuffers(selection.range_count);
            return result;
        }
    }
};

// ---- Fill ---------------------------------------------------------------------------

// The fill's input count: the scoped bounds rows, or every bounds row.
fn fillInputCount(data: *const DataSystem, scope_dense_indices: ?[]const u32) usize {
    return if (scope_dense_indices) |indices| indices.len else data.collisionBoundsSliceConst().entities.len;
}

// One fill input as resolved this step.
const ResolvedSlot = struct {
    entity: EntityId,
    movement_index: u32,
    level: u16,
    x: f32,
    y: f32,
    offset_x: f32,
    offset_y: f32,
    size_x: f32,
    size_y: f32,
    velocity_x: f32,
    velocity_y: f32,
};

const FillContext = struct {
    data: *const DataSystem,
    bounds: ConstCollisionBoundsSlice,
    movement: ConstMovementBodySlice,
    // The world-level store's level column.
    levels: []const u16,
    scope: ?[]const u32,
    // Slot p reads input `warm_sources[p]` when set, else input p.
    warm_sources: ?[]const u32,
    strips: CollisionStrips,
    // Written at the filled slots only.
    proxies: ProxyColumns,

    fn source(self: *const FillContext, slot: usize) u32 {
        // A slot is below the input count <= maxInt(u32).
        return if (self.warm_sources) |order| order[slot] else @intCast(slot);
    }

    // Scalar: one dense-index point lookup per input, with a skip. A missing world level is
    // the surface (0).
    fn resolve(self: *const FillContext, input: u32) ?ResolvedSlot {
        const row: usize = if (self.scope) |indices| indices[input] else input;
        const entity = self.bounds.entities[row];
        const found = self.data.collisionBodyRefs(entity, self.levels) orelse return null;
        const body = found.movement_body;
        return .{
            .entity = entity,
            .movement_index = body,
            .level = found.level orelse 0,
            .x = self.movement.position_x[body],
            .y = self.movement.position_y[body],
            .offset_x = self.bounds.offset_x[row],
            .offset_y = self.bounds.offset_y[row],
            .size_x = self.bounds.size_x[row],
            .size_y = self.bounds.size_y[row],
            .velocity_x = self.movement.velocity_x[body],
            .velocity_y = self.movement.velocity_y[body],
        };
    }
};

// A resolved input's first-copy key, bit for bit the fill lanes'.
fn firstKey(strips: CollisionStrips, row: ResolvedSlot) u128 {
    const min_x = row.x + row.offset_x;
    const min_y = row.y + row.offset_y;
    const strip = math.worldPosToCell(min_y, strips.height, strip_count);
    return packKey(runOf(row.level, strip), math.orderedBits(min_x), math.orderedBits(min_y), row.entity.index);
}

// Stores `values`' lanes in `lanes` to `column[start..]`: one store for a full group, lane
// by lane for the masked last one.
fn storeFloatLanes(column: []f32, start: usize, values: simd.Float4, lanes: simd.MaskBits) void {
    if (lanes == simd.lanesBelow(simd.lane_count)) return simd.storeFloat4Slice(column[start..], values);
    inline for (0..simd.lane_count) |lane| {
        if (lanes & (1 << lane) != 0) column[start + lane] = values[lane];
    }
}

// The copies a fill range wrote to its slot windows.
const FillCounts = struct {
    firsts: usize = 0,
    seconds: usize = 0,
};

// Resolves slots `[start, end)` into their proxies, writes each filled slot's first copy to
// `firsts` and its second-strip copy to `seconds`, both in slot order, and spills its
// copies in later strips to `spill`. Bounds, strips, ordered coordinates, and key words in
// lanes over the packed inputs, the last group one masked batch; resolve and copy
// compaction scalar (a point lookup per input, a data-dependent copy count).
fn fillSlots(fill: *const FillContext, start: usize, end: usize, firsts: []SortEntry, seconds: []SortEntry, spill: *SpillCopies) FillCounts {
    comptime std.debug.assert(entries_per_body == 2);
    const proxies = fill.proxies;
    std.debug.assert(start <= end and end <= proxies.entity.len and firsts.len >= end - start and seconds.len >= end - start);
    const height = fill.strips.height;
    var counts = FillCounts{};
    var group = start;
    while (group < end) : (group += simd.lane_count) {
        const lanes = simd.lanesBelow(end - group);
        var x: [simd.lane_count]f32 = @splat(0);
        var y: [simd.lane_count]f32 = @splat(0);
        var offset_x: [simd.lane_count]f32 = @splat(0);
        var offset_y: [simd.lane_count]f32 = @splat(0);
        var size_x: [simd.lane_count]f32 = @splat(0);
        var size_y: [simd.lane_count]f32 = @splat(0);
        var level: [simd.lane_count]u32 = @splat(0);
        var entity_index: [simd.lane_count]u32 = @splat(0);
        var filled: simd.MaskBits = 0;
        inline for (0..simd.lane_count) |lane| {
            if (lanes & (1 << lane) != 0) {
                const slot = group + lane;
                const input = fill.source(slot);
                proxies.source[slot] = input;
                if (fill.resolve(input)) |row| {
                    filled |= 1 << lane;
                    x[lane] = row.x;
                    y[lane] = row.y;
                    offset_x[lane] = row.offset_x;
                    offset_y[lane] = row.offset_y;
                    size_x[lane] = row.size_x;
                    size_y[lane] = row.size_y;
                    level[lane] = row.level;
                    entity_index[lane] = row.entity.index;
                    proxies.entity[slot] = row.entity;
                    proxies.movement_index[slot] = row.movement_index;
                    proxies.velocity_x[slot] = row.velocity_x;
                    proxies.velocity_y[slot] = row.velocity_y;
                } else {
                    proxies.entity[slot] = EntityId.invalid;
                    proxies.movement_index[slot] = 0;
                    proxies.velocity_x[slot] = 0;
                    proxies.velocity_y[slot] = 0;
                }
            }
        }
        const min_x = simd.loadFloat4(&x) + simd.loadFloat4(&offset_x);
        const min_y = simd.loadFloat4(&y) + simd.loadFloat4(&offset_y);
        const max_x = min_x + simd.loadFloat4(&size_x);
        const max_y = min_y + simd.loadFloat4(&size_y);
        storeFloatLanes(proxies.min_x, group, min_x, lanes);
        storeFloatLanes(proxies.min_y, group, min_y, lanes);
        storeFloatLanes(proxies.max_x, group, max_x, lanes);
        storeFloatLanes(proxies.max_y, group, max_y, lanes);
        // Clamped strips are in [0, strip_count - 1], so non-negative.
        const first_strip: simd.Uint4 = @bitCast(simd.worldPosToCell4(min_y, height, strip_count));
        const last_strip: simd.Uint4 = @bitCast(simd.lastCellOfSpan4(min_y, max_y, height, strip_count));
        const ordered_x = simd.orderedBitsFloat4(min_x);
        const ordered_y = simd.orderedBitsFloat4(min_y);
        const level_words = simd.shiftLeftUint4(simd.loadUint4(&level), 16);
        inline for (0..simd.lane_count) |lane| {
            if (filled & (1 << lane) != 0) {
                // A slot is below the input count <= maxInt(u32).
                const slot: u32 = @intCast(group + lane);
                firsts[counts.firsts] = .{ .key = packKey(level_words[lane] | first_strip[lane], ordered_x[lane], ordered_y[lane], entity_index[lane]), .slot = slot, .first = true };
                counts.firsts += 1;
                if (last_strip[lane] > first_strip[lane]) {
                    seconds[counts.seconds] = .{ .key = packKey(level_words[lane] | (first_strip[lane] + 1), ordered_x[lane], ordered_y[lane], entity_index[lane]), .slot = slot, .first = false };
                    counts.seconds += 1;
                }
                var strip = first_strip[lane] + 2;
                while (strip <= last_strip[lane]) : (strip += 1) {
                    spill.append(.{ .key = packKey(level_words[lane] | strip, ordered_x[lane], ordered_y[lane], entity_index[lane]), .slot = slot, .first = false });
                }
            }
        }
    }
    return counts;
}

// The band splitters: the band quantiles of the sampled slots' first-copy keys (slots
// without a body skipped). Fixed work on the main thread; with no sampled body every
// splitter is `max_key`.
fn chooseSplitters(fill: *const FillContext, input_count: usize) EntrySort.Splitters {
    var samples: [banded_sort.splitter_sample_count]u128 = undefined;
    var valid: usize = 0;
    for (0..banded_sort.sampleCount(input_count)) |sample| {
        const row = fill.resolve(fill.source(banded_sort.sampleSlot(sample, input_count))) orelse continue;
        samples[valid] = firstKey(fill.strips, row);
        valid += 1;
    }
    return EntrySort.splittersFromSamples(samples[0..valid]);
}

// `collision_fill`: one range of fill slots.
const FillJob = struct {
    fill: FillContext,
    splitters: EntrySort.Splitters,
    // Range r's windows start at `r * items_per_range`.
    scratch: []SortEntry,
    staging: []SortEntry,
    second_scratch: []SortEntry,
    second_staging: []SortEntry,
    items_per_range: usize,
    first_offsets: []PaddedSlot(BandOffsets),
    second_offsets: []PaddedSlot(BandOffsets),
    spill_slots: []PaddedSlot(SpillCopies),
};

// Fills the range's slots, placing its first and second copies by band into its staging
// windows and its spilled copies by band into its spill slot. A range past its spill slot
// places no spill: the fill replays.
fn fillJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *FillJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.first_offsets.len and range.index < job.second_offsets.len and range.index < job.spill_slots.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.scratch.len and range.end <= job.staging.len);
    std.debug.assert(range.end <= job.second_scratch.len and range.end <= job.second_staging.len);
    const spill = &job.spill_slots[range.index].value;
    const firsts = job.scratch[range.start..range.end];
    const seconds = job.second_scratch[range.start..range.end];
    const counts = fillSlots(&job.fill, range.start, range.end, firsts, seconds, spill);
    job.first_offsets[range.index].value = EntrySort.placeByBand(&job.splitters, firsts[0..counts.firsts], job.staging[range.start..range.end]);
    job.second_offsets[range.index].value = EntrySort.placeByBand(&job.splitters, seconds[0..counts.seconds], job.second_staging[range.start..range.end]);
    if (spill.overflowed()) return;
    std.debug.assert(spill.placed.capacity >= spill.raw.items.len);
    spill.placed.items.len = spill.raw.items.len;
    spill.offsets = EntrySort.placeByBand(&job.splitters, spill.raw.items, spill.placed.items);
}

// Each band's entries start after every range's copies of the earlier bands. O(ranges *
// bands) on the main thread.
fn bandStarts(first_offsets: []const PaddedSlot(BandOffsets), second_offsets: []const PaddedSlot(BandOffsets), spill_slots: []const PaddedSlot(SpillCopies)) BandStarts {
    var starts = BandStarts{ .entry_start = @splat(0), .first_start = @splat(0) };
    for (first_offsets) |slot| {
        for (&starts.first_start, slot.value.offsets) |*start, offset| start.* += offset;
    }
    starts.entry_start = starts.first_start;
    for (second_offsets) |slot| {
        for (&starts.entry_start, slot.value.offsets) |*start, offset| start.* += offset;
    }
    for (spill_slots) |slot| {
        for (&starts.entry_start, slot.value.offsets.offsets) |*start, offset| start.* += offset;
    }
    return starts;
}

// `collision_sort`: one range of entries. A range owns every nonempty band that starts in
// it, so each band has one owner and the ranges' work follows their entry counts.
const SortJob = struct {
    // The fill ranges' band-placed first, second, and spilled copies.
    firsts: EntrySort.WindowSource,
    seconds: EntrySort.WindowSource,
    spills: SpillSource,
    bands: BandStarts,
    writer: EntryWriter,
    range_count: usize,
};

// Each owned band gathers every fill range's copies of it in range order, first copies,
// then second, then spilled, into its slice of the keys, then finishes there.
fn sortJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SortJob = @ptrCast(@alignCast(context));
    const entry_count = job.bands.entry_start[band_count];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= entry_count);
    std.debug.assert(entry_count <= job.writer.keys.len and entry_count + simd.lane_count <= job.writer.entries.min_x.len);
    std.debug.assert(job.bands.first_start[band_count] <= job.writer.warm_sources.len);
    var owned = OwnedBands.init(&job.bands.entry_start, range.start, range.end);
    while (owned.next()) |band| {
        const start = job.bands.entry_start[band];
        const end = job.bands.entry_start[band + 1];
        const gathered = EntrySort.gatherBand(job.writer.keys[start..end], band, .{ job.firsts, job.seconds, job.spills });
        std.debug.assert(gathered == end - start);
        job.writer.finishBand(start, end, job.bands.first_start[band]);
    }
}

// Writes one band's slice of the sorted keys, entries, and warm order.
const EntryWriter = struct {
    keys: []SortEntry,
    proxies: ConstProxyColumns,
    entries: EntryColumns,
    warm_sources: []u32,

    // Sorts the band's keys `[start, end)` and writes it. pdqsort: the key is total, so an
    // unstable sort is exact.
    fn finishBand(self: EntryWriter, start: u32, end: u32, first_rank: u32) void {
        pdqSort(SortEntry, self.keys[start..end], {}, entryLessThan);
        self.writeSorted(start, end, first_rank);
    }

    // Writes the sorted keys `[start, end)`'s entries, and their first copies' fill inputs to
    // the warm order from `first_rank`. Entry bounds gathered by slot in lanes, the last group
    // masked; the run, first, and slot columns and the warm order are scalar copies.
    fn writeSorted(self: EntryWriter, start: u32, end: u32, first_rank: u32) void {
        const band = self.keys[start..end];
        var group: usize = start;
        while (group < end) : (group += simd.lane_count) {
            const lanes = simd.lanesBelow(end - group);
            var slots: [simd.lane_count]usize = undefined;
            inline for (0..simd.lane_count) |lane| {
                // Absent lanes repeat the band's last entry.
                const entry = self.keys[@min(group + lane, end - 1)];
                slots[lane] = entry.slot;
                if (lanes & (1 << lane) != 0) {
                    self.entries.run[group + lane] = keyRun(entry.key);
                    self.entries.first[group + lane] = @intFromBool(entry.first);
                    self.entries.slot[group + lane] = entry.slot;
                }
            }
            storeFloatLanes(self.entries.min_x, group, simd.gatherFloat4(self.proxies.min_x, slots), lanes);
            storeFloatLanes(self.entries.min_y, group, simd.gatherFloat4(self.proxies.min_y, slots), lanes);
            storeFloatLanes(self.entries.max_x, group, simd.gatherFloat4(self.proxies.max_x, slots), lanes);
            storeFloatLanes(self.entries.max_y, group, simd.gatherFloat4(self.proxies.max_y, slots), lanes);
        }
        var rank = first_rank;
        for (band) |entry| {
            if (!entry.first) continue;
            self.warm_sources[rank] = self.proxies.source[entry.slot];
            rank += 1;
        }
    }
};

// Merges the sorted `tail` into `keys`, whose first `head_len` entries are sorted, from the
// back: one move per entry and no buffer. Hand-written: std has no merge of sorted runs.
// Scalar: a merge is one compare per entry.
fn mergeIntoSorted(keys: []SortEntry, head_len: usize, tail: []const SortEntry) void {
    std.debug.assert(keys.len == head_len + tail.len);
    var head = head_len;
    var rest = tail.len;
    var out = keys.len;
    while (rest > 0) {
        out -= 1;
        if (head > 0 and keys[head - 1].key > tail[rest - 1].key) {
            head -= 1;
            keys[out] = keys[head];
        } else {
            rest -= 1;
            keys[out] = tail[rest];
        }
    }
}

// ---- Broadphase -----------------------------------------------------------------------

// The sweep's visits (`CollisionStats.Perf.perf.broadphase_visits`), kept only with
// `runtime_perf_log.enabled`.
const SweepPerf = if (runtime_perf_log.enabled) struct { visits: usize = 0 } else struct {};

const BroadphaseBuildResult = struct {
    simd_groups: usize = 0,
    perf: SweepPerf = .{},
    batch: BatchStats = .{},
    /// A range slot (or the serial candidate list) allocated in-stage: an unreserved slot
    /// warmed, or a slot grew and the broadphase replayed.
    grew: bool = false,
};

const BroadphaseJobContext = struct {
    system: *CollisionSystem,
    entries: ConstEntryColumns,
    range_count: usize,
    entry_count: usize,
};

fn broadphaseCandidatesJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *BroadphaseJobContext = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count and range.index < job.system.broadphase_ranges.items.len);
    std.debug.assert(range.start <= range.end and range.end <= job.entry_count);
    sweepEntries(job.entries, range.start, range.end, &job.system.broadphase_ranges.items[range.index].buffer);
}

// Sweeps entries `[start, end)`: each tests the entries after it in lane groups of
// contiguous columns. A candidate is active while it shares the entry's run and starts
// inside its x span, a prefix in key order that the sentinel rows end. An active candidate
// overlapping in y emits a pair when either copy is its body's first: the strip of the
// larger min_y. Pair compaction scalar (set bits in lane order).
fn sweepEntries(entries: ConstEntryColumns, start: usize, end: usize, buffer: *BroadphaseRangeBuffer) void {
    std.debug.assert(start <= end and end + simd.lane_count <= entries.min_x.len);
    const all_lanes = simd.lanesBelow(simd.lane_count);
    for (start..end) |entry| {
        const run = simd.splatUint4(entries.run[entry]);
        const max_x = simd.splatFloat4(entries.max_x[entry]);
        const min_y = simd.splatFloat4(entries.min_y[entry]);
        const max_y = simd.splatFloat4(entries.max_y[entry]);
        const entry_first: simd.MaskBits = if (entries.first[entry] != 0) all_lanes else 0;
        const slot = entries.slot[entry];
        var candidate = entry + 1;
        while (true) : (candidate += simd.lane_count) {
            const active = simd.equalUint4Bits(simd.loadUint4(entries.run[candidate..]), run) &
                simd.lessThanFloat4Bits(simd.loadFloat4(entries.min_x[candidate..]), max_x);
            if (active == 0) break;
            if (comptime runtime_perf_log.enabled) {
                buffer.simd_groups += 1;
                buffer.perf.visits += @popCount(active);
            }
            const overlap_y = simd.greaterThanFloat4Bits(max_y, simd.loadFloat4(entries.min_y[candidate..])) &
                simd.greaterThanFloat4Bits(simd.loadFloat4(entries.max_y[candidate..]), min_y);
            const candidate_first = ~simd.equalUint4Bits(simd.loadUint4(entries.first[candidate..]), simd.splatUint4(0));
            var emit = active & overlap_y & (entry_first | candidate_first);
            while (emit != 0) : (emit &= emit - 1) {
                const lane: simd.LaneIndex = @intCast(@ctz(emit));
                buffer.appendCandidateAssumeCapacity(.{ .a = slot, .b = entries.slot[candidate + lane] });
            }
            if (active != all_lanes) break;
        }
    }
}

// ---- Narrowphase ----------------------------------------------------------------------

const NarrowphaseJobContext = struct {
    system: *CollisionSystem,
    range_count: usize,
    candidate_pair_count: usize,
    items_per_range: usize,
};

fn narrowphaseContactsJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *NarrowphaseJobContext = @ptrCast(@alignCast(context));
    // Dual worker asserts: range.index vs dispatched range count AND range.end
    // vs the candidate-pair buffer this job reads; the range is the staging window
    // the main-thread merge expects.
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.candidate_pair_count);
    std.debug.assert(range.start == range.index * job.items_per_range);
    writeNarrowphaseContactsSimd(job.system, range);
}

/// Writes range `range`'s contacts into its own staging window
/// (`narrowphase_staging.items[range.start..range.end]`, at most one contact per
/// candidate pair) and its count into its tally.
fn writeNarrowphaseContactsSimd(system: *CollisionSystem, range: ParallelRange) void {
    const proxies = ConstProxyColumns.of(system.proxies.slice());
    std.debug.assert(range.index < system.narrowphase_tallies.items.len);
    std.debug.assert(range.end <= system.narrowphase_staging.items.len);
    const window = system.narrowphase_staging.items[range.start..range.end];
    var count: usize = 0;
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

        const a_min_x = simd.gatherFloat4(proxies.min_x, a_indices);
        const a_max_x = simd.gatherFloat4(proxies.max_x, a_indices);
        const a_min_y = simd.gatherFloat4(proxies.min_y, a_indices);
        const a_max_y = simd.gatherFloat4(proxies.max_y, a_indices);
        const b_min_x = simd.gatherFloat4(proxies.min_x, b_indices);
        const b_max_x = simd.gatherFloat4(proxies.max_x, b_indices);
        const b_min_y = simd.gatherFloat4(proxies.min_y, b_indices);
        const b_max_y = simd.gatherFloat4(proxies.max_y, b_indices);

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
                window[count] = contactForResolved(
                    proxies,
                    a_indices[lane],
                    b_indices[lane],
                    normal_x[lane],
                    normal_y[lane],
                    penetration[lane],
                );
                count += 1;
            }
        }
    }

    while (index < range.end) : (index += 1) {
        const pair = system.candidate_pairs.items[index];
        if (contactForCandidate(proxies, pair.a, pair.b)) |contact| {
            window[count] = contact;
            count += 1;
        }
    }
    system.narrowphase_tallies.items[range.index].count = count;
}

fn contactForCandidate(proxies: ConstProxyColumns, a: usize, b: usize) ?CollisionContact {
    const overlap_left = proxies.max_x[a] - proxies.min_x[b];
    const overlap_right = proxies.max_x[b] - proxies.min_x[a];
    const overlap_x = @min(overlap_left, overlap_right);
    const overlap_top = proxies.max_y[a] - proxies.min_y[b];
    const overlap_bottom = proxies.max_y[b] - proxies.min_y[a];
    const overlap_y = @min(overlap_top, overlap_bottom);
    if (overlap_x <= 0 or overlap_y <= 0) return null;

    var normal_x: f32 = 0;
    var normal_y: f32 = 0;
    var penetration = overlap_x;
    if (overlap_x <= overlap_y) {
        const center_a = (proxies.min_x[a] + proxies.max_x[a]) * 0.5;
        const center_b = (proxies.min_x[b] + proxies.max_x[b]) * 0.5;
        normal_x = if (center_a <= center_b) -1 else 1;
    } else {
        const center_a = (proxies.min_y[a] + proxies.max_y[a]) * 0.5;
        const center_b = (proxies.min_y[b] + proxies.max_y[b]) * 0.5;
        normal_y = if (center_a <= center_b) -1 else 1;
        penetration = overlap_y;
    }

    return contactForResolved(proxies, a, b, normal_x, normal_y, penetration);
}

fn contactForResolved(
    proxies: ConstProxyColumns,
    a: usize,
    b: usize,
    normal_x: f32,
    normal_y: f32,
    penetration: f32,
) CollisionContact {
    const va_x = proxies.velocity_x[a];
    const va_y = proxies.velocity_y[a];
    const vb_x = proxies.velocity_x[b];
    const vb_y = proxies.velocity_y[b];
    const speed_a_sq = va_x * va_x + va_y * va_y;
    const speed_b_sq = vb_x * vb_x + vb_y * vb_y;
    const rel_x = va_x - vb_x;
    const rel_y = va_y - vb_y;
    return .{
        .a = proxies.entity[a],
        .b = proxies.entity[b],
        .a_movement_index = proxies.movement_index[a],
        .b_movement_index = proxies.movement_index[b],
        .normal_x = normal_x,
        .normal_y = normal_y,
        .penetration = penetration,
        .pre_response_max_speed_sq = @max(speed_a_sq, speed_b_sq),
        .pre_response_relative_speed_sq = rel_x * rel_x + rel_y * rel_y,
    };
}

fn rangeLenForIndex(item_count: usize, items_per_range: usize, range_index: usize) usize {
    const start = range_index * items_per_range;
    if (start >= item_count) return 0;
    return @min(start + items_per_range, item_count) - start;
}
// ---- Tests ----------------------------------------------------------------------------

fn addBody(data: *DataSystem, position_x: f32, position_y: f32, size: f32) !EntityId {
    return addBox(data, .{ .x = position_x, .y = position_y, .w = size, .h = size });
}

const TestBox = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    level: ?u16 = null,
    velocity_x: f32 = 0,
    velocity_y: f32 = 0,
    offset_x: f32 = 0,
    offset_y: f32 = 0,
};

fn addBox(data: *DataSystem, box: TestBox) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = box.x, .y = box.y },
        .previous_position = .{ .x = box.x, .y = box.y },
        .velocity = .{ .x = box.velocity_x, .y = box.velocity_y },
    });
    try data.setCollisionBounds(entity, .{ .offset = .{ .x = box.offset_x, .y = box.offset_y }, .size = .{ .x = box.w, .y = box.h } });
    if (box.level) |level| try data.setWorldLevel(entity, level);
    return entity;
}

// Runs the serial fill and sort over every bounds row at the default strips.
fn buildForTest(system: *CollisionSystem, data: *const DataSystem) !CollisionStats {
    var stats = CollisionStats{};
    _ = try system.buildDirect(data, null, .default, &stats);
    return stats;
}

// Every field of every contact, in order.
fn expectSameContacts(expected: []const CollisionContact, actual: []const CollisionContact) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expect(want.a.eql(got.a));
        try std.testing.expect(want.b.eql(got.b));
        try std.testing.expectEqual(want.a_movement_index, got.a_movement_index);
        try std.testing.expectEqual(want.b_movement_index, got.b_movement_index);
        try std.testing.expectEqual(want.normal_x, got.normal_x);
        try std.testing.expectEqual(want.normal_y, got.normal_y);
        try std.testing.expectEqual(want.penetration, got.penetration);
        try std.testing.expectEqual(want.pre_response_max_speed_sq, got.pre_response_max_speed_sq);
        try std.testing.expectEqual(want.pre_response_relative_speed_sq, got.pre_response_relative_speed_sq);
    }
}

fn expectSameContactPairs(expected: []const CollisionContact, actual: []const CollisionContact) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| {
        try std.testing.expectEqual(want.a.index, got.a.index);
        try std.testing.expectEqual(want.b.index, got.b.index);
    }
}

// A body as the brute-force reference reads it from the stores.
const ReferenceBody = struct {
    entity: EntityId,
    movement_index: u32,
    level: u16,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    velocity_x: f32,
    velocity_y: f32,

    // The order inside one (level, strip) run.
    fn runKey(self: ReferenceBody) u128 {
        return packKey(0, math.orderedBits(self.min_x), math.orderedBits(self.min_y), self.entity.index);
    }
};

const ReferenceContact = struct {
    level: u16,
    strip: u32,
    key_a: u128,
    key_b: u128,
    contact: CollisionContact,

    fn lessThan(_: void, lhs: ReferenceContact, rhs: ReferenceContact) bool {
        if (lhs.level != rhs.level) return lhs.level < rhs.level;
        if (lhs.strip != rhs.strip) return lhs.strip < rhs.strip;
        if (lhs.key_a != rhs.key_a) return lhs.key_a < rhs.key_a;
        return lhs.key_b < rhs.key_b;
    }
};

// Every same-level pair of bodies overlapping on both axes, a sorting first, ordered by
// (level, strip of the larger min_y, key of a, key of b), each contact field computed from
// the two bodies alone.
fn referenceContacts(allocator: std.mem.Allocator, data: *const DataSystem, strips: CollisionStrips) ![]CollisionContact {
    const bounds = data.collisionBoundsSliceConst();
    var bodies: std.ArrayList(ReferenceBody) = .empty;
    defer bodies.deinit(allocator);
    for (bounds.entities, 0..) |entity, row| {
        const body = data.movementBodyConst(entity) orelse continue;
        const min_x = body.position.x + bounds.offset_x[row];
        const min_y = body.position.y + bounds.offset_y[row];
        try bodies.append(allocator, .{
            .entity = entity,
            .movement_index = @intCast(data.movementBodyDenseIndex(entity).?),
            .level = data.worldLevelConst(entity) orelse 0,
            .min_x = min_x,
            .min_y = min_y,
            .max_x = min_x + bounds.size_x[row],
            .max_y = min_y + bounds.size_y[row],
            .velocity_x = body.velocity.x,
            .velocity_y = body.velocity.y,
        });
    }
    var found: std.ArrayList(ReferenceContact) = .empty;
    defer found.deinit(allocator);
    for (bodies.items, 0..) |first, index| for (bodies.items[index + 1 ..]) |second| {
        if (first.level != second.level) continue;
        const a, const b = if (first.runKey() < second.runKey()) .{ first, second } else .{ second, first };
        const overlap_x = @min(a.max_x - b.min_x, b.max_x - a.min_x);
        const overlap_y = @min(a.max_y - b.min_y, b.max_y - a.min_y);
        if (overlap_x <= 0 or overlap_y <= 0) continue;
        var contact = CollisionContact{
            .a = a.entity,
            .b = b.entity,
            .a_movement_index = a.movement_index,
            .b_movement_index = b.movement_index,
            .normal_x = 0,
            .normal_y = 0,
            .penetration = overlap_x,
            .pre_response_max_speed_sq = @max(a.velocity_x * a.velocity_x + a.velocity_y * a.velocity_y, b.velocity_x * b.velocity_x + b.velocity_y * b.velocity_y),
            .pre_response_relative_speed_sq = (a.velocity_x - b.velocity_x) * (a.velocity_x - b.velocity_x) + (a.velocity_y - b.velocity_y) * (a.velocity_y - b.velocity_y),
        };
        if (overlap_x <= overlap_y) {
            contact.normal_x = if ((a.min_x + a.max_x) * 0.5 <= (b.min_x + b.max_x) * 0.5) -1 else 1;
        } else {
            contact.normal_y = if ((a.min_y + a.max_y) * 0.5 <= (b.min_y + b.max_y) * 0.5) -1 else 1;
            contact.penetration = overlap_y;
        }
        try found.append(allocator, .{
            .level = a.level,
            .strip = math.worldPosToCell(@max(a.min_y, b.min_y), strips.height, strip_count),
            .key_a = a.runKey(),
            .key_b = b.runKey(),
            .contact = contact,
        });
    };
    std.mem.sort(ReferenceContact, found.items, {}, ReferenceContact.lessThan);
    const contacts = try allocator.alloc(CollisionContact, found.items.len);
    for (contacts, found.items) |*contact, reference| contact.* = reference.contact;
    return contacts;
}

// The sweep's hard shapes, apart in x: a tall column, 16 stacked levels, bodies over one to
// three strips, a max edge on a strip edge, equal mins, negative and past-the-level
// coordinates, a body over many strips, and a cross-level overlap. Velocities vary so every
// speed field is checked.
fn fillReferenceLayout(data: *DataSystem) !void {
    var count: usize = 0;
    const Add = struct {
        fn box(target: *DataSystem, counter: *usize, box_value: TestBox) !void {
            var with_velocity = box_value;
            with_velocity.velocity_x = @as(f32, @floatFromInt(counter.* % 5)) - 2;
            with_velocity.velocity_y = @floatFromInt(counter.* % 3);
            counter.* += 1;
            _ = try addBox(target, with_velocity);
        }
    };
    // A column 40 bodies tall, each overlapping its two neighbours above and below.
    for (0..40) |row| try Add.box(data, &count, .{ .x = 0, .y = @as(f32, @floatFromInt(row)) * 7, .w = 9, .h = 9 });
    // A 4 x 4 grid copied onto 16 levels.
    for (0..16) |level| for (0..4) |row| for (0..4) |column| {
        try Add.box(data, &count, .{ .x = 200 + @as(f32, @floatFromInt(column)) * 7, .y = @as(f32, @floatFromInt(row)) * 7, .w = 9, .h = 9, .level = @intCast(level) });
    };
    // One, two, and three strips, crossed by narrow bodies.
    try Add.box(data, &count, .{ .x = 400, .y = 4, .w = 10, .h = 10 });
    try Add.box(data, &count, .{ .x = 402, .y = 20, .w = 10, .h = 40 });
    try Add.box(data, &count, .{ .x = 404, .y = 30, .w = 10, .h = 70 });
    try Add.box(data, &count, .{ .x = 406, .y = 60, .w = 3, .h = 3 });
    try Add.box(data, &count, .{ .x = 405, .y = 95, .w = 3, .h = 3 });
    // A max edge on a strip edge touches the body starting there and overlaps the one
    // starting a pixel above.
    try Add.box(data, &count, .{ .x = 600, .y = 0, .w = 10, .h = 32 });
    try Add.box(data, &count, .{ .x = 602, .y = 32, .w = 10, .h = 8 });
    try Add.box(data, &count, .{ .x = 604, .y = 31, .w = 10, .h = 8 });
    // Equal mins on both axes, and on x alone.
    try Add.box(data, &count, .{ .x = 700, .y = 100, .w = 10, .h = 10 });
    try Add.box(data, &count, .{ .x = 700, .y = 100, .w = 10, .h = 10 });
    try Add.box(data, &count, .{ .x = 700, .y = 105, .w = 10, .h = 10 });
    // Negative coordinates clamp to strip 0, coordinates past the level to the last strip.
    try Add.box(data, &count, .{ .x = -500, .y = -100, .w = 20, .h = 20 });
    try Add.box(data, &count, .{ .x = -490, .y = -95, .w = 20, .h = 120 });
    try Add.box(data, &count, .{ .x = -485, .y = 10, .w = 20, .h = 20 });
    try Add.box(data, &count, .{ .x = 800, .y = 3.0e6, .w = 20, .h = 20 });
    try Add.box(data, &count, .{ .x = 805, .y = 3.0e6 + 5, .w = 20, .h = 20 });
    // A body over 13 strips, overlapped along its height.
    try Add.box(data, &count, .{ .x = 900, .y = 0, .w = 20, .h = 400 });
    for ([_]f32{ 50, 150, 390, 399.5 }) |y| try Add.box(data, &count, .{ .x = 905, .y = y, .w = 10, .h = 10 });
    // An xy overlap across levels, beside a same-level one.
    try Add.box(data, &count, .{ .x = 1000, .y = 0, .w = 10, .h = 10, .level = 0 });
    try Add.box(data, &count, .{ .x = 1002, .y = 2, .w = 10, .h = 10, .level = 3 });
    try Add.box(data, &count, .{ .x = 1004, .y = 4, .w = 10, .h = 10 });
}

// `CollisionSystem.update` over the scoped bodies (null = all), inline: a thread system with
// no workers.
fn updateScopedInline(system: *CollisionSystem, data: *const DataSystem, contacts: *RangeOutputStream(CollisionContact), scope_dense_indices: ?[]const u32) !CollisionStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0, .items_per_range = std.math.maxInt(u32) });
    defer threads.deinit();
    return system.update(data, contacts, &threads, .{ .scope_dense_indices = scope_dense_indices });
}

fn updateInline(system: *CollisionSystem, data: *const DataSystem, contacts: *RangeOutputStream(CollisionContact)) !CollisionStats {
    return updateScopedInline(system, data, contacts, null);
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

    const stats = try updateInline(&system, &data, &contacts);

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

    const stats = try updateInline(&system, &data, &contacts);

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

    const stats = try updateInline(&system, &data, &contacts);
    const merged = contacts.mergedItems();

    try std.testing.expectEqual(@as(usize, 2), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 2), stats.contact_count);
    try std.testing.expectEqual(first.index, merged[0].a.index);
    try std.testing.expectEqual(second.index, merged[0].b.index);
    try std.testing.expectEqual(first.index, merged[1].a.index);
    try std.testing.expectEqual(fourth.index, merged[1].b.index);
}

test "serial contacts equal a brute-force same-level reference in every field and order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillReferenceLayout(&data);
    const expected = try referenceContacts(std.testing.allocator, &data, .default);
    defer std.testing.allocator.free(expected);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const stats = try updateInline(&system, &data, &contacts);
    // Bodies over two or more strips have more than one entry.
    try std.testing.expect(stats.entry_count > stats.body_count);
    try expectSameContacts(expected, contacts.mergedItems());
}

test "threaded contacts equal the reference across range sizes and worker counts" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillReferenceLayout(&data);
    const expected = try referenceContacts(std.testing.allocator, &data, .default);
    defer std.testing.allocator.free(expected);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = collision_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    for ([_]usize{ 16, 32, 48, 128 }) |items_per_range| for ([_]usize{ 1, 2, 4 }) |workers| {
        var system = CollisionSystem.init(std.testing.allocator);
        defer system.deinit();
        var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
        defer contacts.deinit();
        _ = try system.update(&data, &contacts, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = workers, .adaptive = false });
        try expectSameContacts(expected, contacts.mergedItems());
    };
}

test "fill, sort, broadphase, and narrowphase run on workers" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillReferenceLayout(&data);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = collision_range_alignment_items, .max_worker_threads = 2, .adaptive = false });
    for ([_]BatchStats{ stats.broadphase_batch, stats.narrowphase_batch }) |batch| {
        try std.testing.expect(!batch.ran_inline);
        try std.testing.expect(batch.active_worker_threads > 0);
    }
}

test "fill lanes write the scalar key for every copy of every body" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Seven bodies, so one full lane group and a masked one; a signed zero, negative and
    // past-the-level coordinates, and one, two, and five strips.
    _ = try addBox(&data, .{ .x = -0.0, .y = -0.0, .w = 4, .h = 4, .offset_x = -0.0, .offset_y = -0.0 });
    _ = try addBox(&data, .{ .x = 3, .y = 30, .w = 4, .h = 4, .level = 2 });
    _ = try addBox(&data, .{ .x = -40, .y = -70, .w = 4, .h = 150 });
    _ = try addBox(&data, .{ .x = 5, .y = 3.0e6, .w = 4, .h = 4, .level = 9 });
    _ = try addBox(&data, .{ .x = 1.5, .y = 10, .w = 4, .h = 130, .offset_y = 2 });
    const bodiless = try data.createEntity();
    try data.setCollisionBounds(bodiless, .{ .size = .{ .x = 4, .y = 4 } });
    _ = try addBox(&data, .{ .x = 7, .y = 64, .w = 4, .h = 4 });

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    const stats = try buildForTest(&system, &data);
    try std.testing.expectEqual(@as(usize, 6), stats.body_count);

    const fill = system.fillContext(&data, null, .default, system.proxies.len);
    const proxies = ConstProxyColumns.of(system.proxies.slice());
    var copies: usize = 0;
    for (system.keys.items[0..stats.entry_count]) |entry| {
        const row = fill.resolve(proxies.source[entry.slot]).?;
        const first_key = firstKey(.default, row);
        const min_y = row.y + row.offset_y;
        const first_strip = math.worldPosToCell(min_y, CollisionStrips.default.height, strip_count);
        const last_strip = math.lastCellOfSpan(min_y, min_y + row.size_y, CollisionStrips.default.height, strip_count);
        const strip = keyRun(entry.key) & 0xFFFF;
        try std.testing.expectEqual(@as(u32, row.level), keyRun(entry.key) >> 16);
        try std.testing.expect(strip >= first_strip and strip <= last_strip);
        try std.testing.expectEqual(strip == first_strip, entry.first);
        // Every copy shares the first copy's words below the run.
        try std.testing.expectEqual(@as(u96, @truncate(first_key)), @as(u96, @truncate(entry.key)));
        if (entry.first) try std.testing.expectEqual(first_key, entry.key);
        copies += 1;
    }
    // 1 + 2 + 3 + 1 + 5 + 1 copies, the signed zero's key the positive zero's.
    try std.testing.expectEqual(@as(usize, 13), copies);
    try std.testing.expectEqual(math.orderedBits(0), @as(u32, @truncate(firstKey(.default, fill.resolve(0).?) >> 64)));
}

test "warm and cold steps write identical contacts" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillReferenceLayout(&data);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const config: CollisionConfig = .{ .items_per_range = collision_range_alignment_items, .max_worker_threads = 2, .adaptive = false };

    var warm = CollisionSystem.init(std.testing.allocator);
    defer warm.deinit();
    var warm_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer warm_contacts.deinit();
    var serial = CollisionSystem.init(std.testing.allocator);
    defer serial.deinit();
    var serial_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer serial_contacts.deinit();
    _ = try warm.update(&data, &warm_contacts, &threads, config);
    _ = try updateInline(&serial, &data, &serial_contacts);

    // Every body moves, so the warm order is stale on both paths.
    const movement = data.movementBodySlice();
    for (movement.position_x, movement.position_y, 0..) |*x, *y, index| {
        x.* += @as(f32, @floatFromInt(index % 7)) - 3;
        y.* += @as(f32, @floatFromInt(index % 11)) - 5;
    }
    const expected = try referenceContacts(std.testing.allocator, &data, .default);
    defer std.testing.allocator.free(expected);
    try std.testing.expect(warm.warm_count == data.collisionBoundsSliceConst().entities.len and serial.warm_count == warm.warm_count);
    _ = try warm.update(&data, &warm_contacts, &threads, config);
    _ = try updateInline(&serial, &data, &serial_contacts);
    try expectSameContacts(expected, warm_contacts.mergedItems());
    try expectSameContacts(expected, serial_contacts.mergedItems());

    var cold = CollisionSystem.init(std.testing.allocator);
    defer cold.deinit();
    var cold_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer cold_contacts.deinit();
    _ = try cold.update(&data, &cold_contacts, &threads, config);
    try expectSameContacts(expected, cold_contacts.mergedItems());
}

test "a fill range past its spill slot replays to the reference contacts" {
    if (builtin.single_threaded) return error.SkipZigTest;
    // 64 bodies at a 64-body reserve (128-entry bound), four fill ranges of 16. The last 16
    // bodies span three strips each: their third copies spill to slot 3, which `reserve`
    // leaves empty, so the slot grows and the fill replays inside the total bound.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..48) |index| _ = try addBox(&data, .{ .x = @as(f32, @floatFromInt(index)) * 6, .y = 2, .w = 8, .h = 8 });
    for (0..16) |index| _ = try addBox(&data, .{ .x = 1000 + @as(f32, @floatFromInt(index)) * 6, .y = 2, .w = 8, .h = 70 });
    const expected = try referenceContacts(std.testing.allocator, &data, .default);
    defer std.testing.allocator.free(expected);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(64);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false });
    try std.testing.expectEqual(@as(usize, 96), stats.entry_count);
    try std.testing.expect(stats.entry_count <= system.reserved_entry_bound);
    try expectSameContacts(expected, contacts.mergedItems());
}

test "a serial fill past its spill slot replays to the reference contacts" {
    // Eight bodies over four strips each: two spilled copies apiece into an empty slot, so
    // the serial fill grows it and replays; a fill that kept the first pass's copies would
    // duplicate entries.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..8) |index| _ = try addBox(&data, .{ .x = @as(f32, @floatFromInt(index)) * 6, .y = 2, .w = 8, .h = 100 });
    const expected = try referenceContacts(std.testing.allocator, &data, .default);
    defer std.testing.allocator.free(expected);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const stats = try updateInline(&system, &data, &contacts);
    try std.testing.expectEqual(@as(usize, 8 * 4), stats.entry_count);
    try std.testing.expect(expected.len > 0);
    try expectSameContacts(expected, contacts.mergedItems());
}

test "threaded contacts at a non-default strip height equal its reference" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillReferenceLayout(&data);
    // A 24-unit tile gives 16-unit strips.
    const strips = CollisionStrips.ofTileSize(24);
    try std.testing.expectEqual(@as(f32, 16), strips.height);
    const expected = try referenceContacts(std.testing.allocator, &data, strips);
    defer std.testing.allocator.free(expected);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    _ = try system.update(&data, &contacts, &threads, .{ .items_per_range = collision_range_alignment_items, .max_worker_threads = 2, .adaptive = false, .strips = strips });
    try expectSameContacts(expected, contacts.mergedItems());
}

test "after a spill slot grows, later multi-worker steps allocate nothing" {
    if (builtin.single_threaded) return error.SkipZigTest;
    // Tall bodies spill past their second strip. The first steps grow the spill slots (the
    // cold order, then the warm one); a step at the same warm order reuses them.
    const body_count: usize = 64;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..body_count) |index| {
        const tall = index % 4 == 0;
        _ = try addBox(&data, .{ .x = @floatFromInt((index % 8) * 6), .y = @floatFromInt((index / 8) * 6), .w = 8, .h = if (tall) 80 else 8 });
    }
    const expected = try referenceContacts(std.testing.allocator, &data, .default);
    defer std.testing.allocator.free(expected);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(body_count);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try CollisionSystem.reserveContactStream(&contacts, body_count);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    const config: CollisionConfig = .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false };
    for (0..2) |_| _ = try system.update(&data, &contacts, &threads, config);

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_allocator.allocator();
    contacts.allocator = failing_allocator.allocator();
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }
    _ = try system.update(&data, &contacts, &threads, config);
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
    try expectSameContacts(expected, contacts.mergedItems());
}

test "after reserve, a multi-worker step over bodies on two strips allocates nothing" {
    if (builtin.single_threaded) return error.SkipZigTest;
    // An 8 x 8 grid (pitch 6, size 8) whose lower rows cross the strip edge at 32: within
    // one extra copy per body and four pairs per entry.
    const body_count: usize = 64;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..body_count) |index| {
        _ = try addBox(&data, .{ .x = @floatFromInt((index % 8) * 6), .y = @floatFromInt((index / 8) * 6), .w = 8, .h = 8 });
    }
    const expected = try referenceContacts(std.testing.allocator, &data, .default);
    defer std.testing.allocator.free(expected);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(body_count);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try CollisionSystem.reserveContactStream(&contacts, body_count);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_allocator.allocator();
    contacts.allocator = failing_allocator.allocator();
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }

    // Cold, then warm.
    for (0..2) |_| {
        const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false });
        try std.testing.expect(stats.entry_count > body_count);
        for ([_]BatchStats{ stats.broadphase_batch, stats.narrowphase_batch }) |batch| {
            try std.testing.expect(!batch.ran_inline);
        }
        try std.testing.expect(!stats.pair_bound_exceeded);
        try expectSameContacts(expected, contacts.mergedItems());
    }
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
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

    _ = try updateInline(&serial_system, &serial_data, &serial_contacts);
    const threaded_stats = try threaded_system.update(&threaded_data, &threaded_contacts, &threads, .{
        .items_per_range = collision_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    try std.testing.expect(!threaded_stats.broadphase_batch.ran_inline);
    try std.testing.expect(!threaded_stats.narrowphase_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 64), threaded_stats.broadphase_batch.item_count);
    try std.testing.expectEqual(threaded_stats.candidate_pair_count, threaded_stats.narrowphase_batch.item_count);
    try expectSameContacts(serial_contacts.mergedItems(), threaded_contacts.mergedItems());
}

test "threaded collision records one sample into each stage tuner and none into the shared tuner" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..64) |index| {
        const x: f32 = @floatFromInt((index % 16) * 6);
        const y: f32 = @floatFromInt((index / 16) * 6);
        _ = try addBody(&data, x, y, 8);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const stats = try system.update(&data, &contacts, &threads, .{});
    try std.testing.expectEqual(@as(usize, 64), stats.broadphase_batch.item_count);
    try std.testing.expect(stats.narrowphase_batch.item_count > 0);
    for ([_]*const AdaptiveWorkTuner{ &system.fill_tuner, &system.sort_tuner, &system.broadphase_tuner, &system.narrowphase_tuner }) |tuner| {
        try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
        try std.testing.expect(tuner.last_request != null);
    }
    try std.testing.expectEqual(@as(usize, 0), threads.adaptive_tuner.sample_count);
    try std.testing.expect(threads.adaptive_tuner.last_request == null);
}

test "threaded collision broadphase overflow-replay matches serial contacts" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var serial_data = DataSystem.init(std.testing.allocator);
    defer serial_data.deinit();
    var threaded_data = DataSystem.init(std.testing.allocator);
    defer threaded_data.deinit();

    // 64 tightly clustered bodies (jitter << body size, so all mutually overlap):
    // candidate pairs (~N^2) far exceed each range's broadphase reservation, forcing the
    // multi-worker grow-and-replay path. 64 bodies keep the batch off the inline fallback
    // so real workers run the replay.
    for (0..64) |index| {
        const xj: f32 = @floatFromInt(index % 3);
        const yj: f32 = @floatFromInt(index % 5);
        _ = try addBody(&serial_data, xj * 0.25, yj * 0.25, 8);
        _ = try addBody(&threaded_data, xj * 0.25, yj * 0.25, 8);
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

    _ = try updateInline(&serial_system, &serial_data, &serial_contacts);
    const threaded_stats = try threaded_system.update(&threaded_data, &threaded_contacts, &threads, .{
        .items_per_range = collision_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    // The batch ran on real workers and the fixture overflowed a range's reservation
    // (candidate pairs exceed body count), so the cross-worker regrow+replay path ran.
    try std.testing.expect(!threaded_stats.broadphase_batch.ran_inline);
    try std.testing.expect(threaded_stats.candidate_pair_count > threaded_stats.body_count);
    try std.testing.expect(serial_contacts.mergedItems().len > 0);
    try expectSameContacts(serial_contacts.mergedItems(), threaded_contacts.mergedItems());
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
    // A cold fill puts bounds row k at slot k.
    _ = try buildForTest(&system, &data);
    try system.candidate_pairs.append(std.testing.allocator, .{ .a = 0, .b = 1 });
    try system.candidate_pairs.append(std.testing.allocator, .{ .a = 0, .b = 2 });
    try system.candidate_pairs.append(std.testing.allocator, .{ .a = 0, .b = 3 });
    try system.prepareNarrowphaseStaging(system.candidate_pairs.items.len, 2);

    writeNarrowphaseContactsSimd(&system, .{ .index = 0, .start = 0, .end = 2 });
    writeNarrowphaseContactsSimd(&system, .{ .index = 1, .start = 2, .end = 3 });

    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    // Two 2-pair range windows.
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
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(ContactCountTally) % thread_shared_record_alignment);
    try std.testing.expectEqual(@as(usize, 0), @sizeOf(PaddedSlot(SpillCopies)) % thread_shared_record_alignment);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(64);
    try system.prepareNarrowphaseStaging(8, 2);

    for ([_]usize{
        @intFromPtr(system.broadphase_ranges.items.ptr),
        @intFromPtr(system.narrowphase_tallies.items.ptr),
        @intFromPtr(system.narrowphase_staging.items.ptr),
        @intFromPtr(system.spill_slots.items.ptr),
        @intFromPtr(system.first_offsets.items.ptr),
        @intFromPtr(system.second_offsets.items.ptr),
        @intFromPtr(system.second_scratch.items.ptr),
        @intFromPtr(system.second_staging.items.ptr),
        @intFromPtr(system.keys.items.ptr),
        @intFromPtr(system.staging.items.ptr),
    }) |address| try std.testing.expectEqual(@as(usize, 0), address % thread_shared_record_alignment);
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

    const expected_broadphase_ranges = rangeCount(stats.entry_count, collision_range_alignment_items);
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
    _ = try updateInline(&system, &data, &contacts);

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

    const stats = try updateInline(&system, &data, &contacts);
    try std.testing.expectEqual(@as(usize, 32), stats.body_count);
    try std.testing.expect(contacts.mergedItems().len > 0);
}

test "serial collision broadphase warms clustered overflow without steady state allocation" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Tightly clustered bodies all mutually overlap, so the candidate pair count
    // (~N*(N-1)/2) far exceeds the entry-count-capped broadphase estimate. The warmup
    // update must overflow the reserved candidate buffer and regrow it once; the
    // failing-allocator update then reuses that warmed capacity with zero allocation.
    for (0..24) |index| {
        const jitter: f32 = @floatFromInt(index % 3);
        _ = try addBody(&data, jitter * 0.25, 0, 8);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const warm_stats = try updateInline(&system, &data, &contacts);
    // Confirm the fixture actually exercises the overflow-regrow path.
    try std.testing.expect(warm_stats.candidate_pair_count > warm_stats.body_count);

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

    const stats = try updateInline(&system, &data, &contacts);
    try std.testing.expectEqual(@as(usize, 24), stats.body_count);
    try std.testing.expect(stats.candidate_pair_count > stats.body_count);
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

    const warmup = try system.update(&data, &contacts, &threads, .{
        .items_per_range = collision_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    // Warmup must have exercised real multi-worker range writes; an inline
    // fallback would make the FailingAllocator proof a serial false pass.
    if (warmup.candidate_pair_count > 0) {
        try std.testing.expect(!warmup.broadphase_batch.ran_inline);
        try std.testing.expect(!warmup.narrowphase_batch.ran_inline);
        try std.testing.expect(warmup.broadphase_batch.active_worker_threads > 0);
        try std.testing.expect(warmup.narrowphase_batch.active_worker_threads > 0);
    }

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
    if (stats.candidate_pair_count > 0) {
        try std.testing.expect(!stats.broadphase_batch.ran_inline);
        try std.testing.expect(!stats.narrowphase_batch.ran_inline);
        try std.testing.expect(stats.broadphase_batch.active_worker_threads > 0);
        try std.testing.expect(stats.narrowphase_batch.active_worker_threads > 0);
    }
}

fn addFourBodiesTwoOverlappingPairs(data: *DataSystem) !void {
    _ = try addBody(data, 0, 0, 10);
    _ = try addBody(data, 8, 2, 10);
    _ = try addBody(data, 100, 0, 10);
    _ = try addBody(data, 106, 4, 10);
}

test "collision reserve makes the first serial update allocation-free" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try addFourBodiesTwoOverlappingPairs(&data);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(4);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try contacts.reserve(1, 4);

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_allocator.allocator();
    contacts.allocator = failing_allocator.allocator();
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }

    const stats = try updateInline(&system, &data, &contacts);
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
    try std.testing.expectEqual(@as(usize, 4), stats.body_count);
    try std.testing.expectEqual(@as(usize, 2), contacts.mergedItems().len);
}

test "collision reserve makes the first single-range threaded update allocation-free" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try addFourBodiesTwoOverlappingPairs(&data);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(4);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try contacts.reserve(1, 4);
    // The pipeline's path with no worker: `update` runs the serial step.
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_allocator.allocator();
    contacts.allocator = failing_allocator.allocator();
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }

    const stats = try system.update(&data, &contacts, &threads, .{ .adaptive = false });
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
    try std.testing.expectEqual(@as(usize, 4), stats.body_count);
    try std.testing.expectEqual(@as(usize, 2), contacts.mergedItems().len);
}

test "after reserve, threaded broad/narrowphase at 32- then 16-item ranges allocate nothing" {
    // `reserve` alone (no warm update) covers every partition the tuners can pick: fill
    // slots, broadphase slots reserved to the per-range bound for maxRangeCount ranges, the
    // narrowphase staging to the candidate pairs. A sparse chain (each body overlaps only
    // its neighbour) keeps the pair count within the reserved pair capacity.
    if (builtin.single_threaded) return error.SkipZigTest;

    const body_count: usize = 64;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..body_count) |index| {
        _ = try addBody(&data, @floatFromInt(index * 10), 0, 12);
    }

    var reference = CollisionSystem.init(std.testing.allocator);
    defer reference.deinit();
    var reference_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer reference_contacts.deinit();
    _ = try updateInline(&reference, &data, &reference_contacts);
    const expected = reference_contacts.mergedItems();
    try std.testing.expect(expected.len > 0);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(body_count);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try contacts.reserve(maxRangeCount(body_count, collision_range_alignment_items), body_count);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_allocator.allocator();
    contacts.allocator = failing_allocator.allocator();
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }

    for ([_]usize{ 32, 16 }) |items_per_range| {
        const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = 2, .adaptive = false });
        try std.testing.expect(!stats.broadphase_batch.ran_inline);
        try std.testing.expect(!stats.narrowphase_batch.ran_inline);
        try std.testing.expectEqual(rangeCount(body_count, items_per_range), stats.broadphase_batch.range_count);
        try expectSameContactPairs(expected, contacts.mergedItems());
    }
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

test "after reserve, ~2 pairs per body on the multi-worker path allocate nothing" {
    // Every body overlaps its next two neighbours (spacing 10, size 22): 125 candidate
    // pairs over 64 bodies, within the per-range slot bound, so the broadphase never
    // replays. The merged candidates, narrowphase staging and tallies must hold them from
    // `reserve` alone, not grow in-stage.
    if (builtin.single_threaded) return error.SkipZigTest;

    const body_count: usize = 64;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..body_count) |index| {
        _ = try addBody(&data, @floatFromInt(index * 10), 0, 22);
    }

    var reference = CollisionSystem.init(std.testing.allocator);
    defer reference.deinit();
    var reference_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer reference_contacts.deinit();
    const reference_stats = try updateInline(&reference, &data, &reference_contacts);
    try std.testing.expectEqual(@as(usize, 2 * body_count - 3), reference_stats.candidate_pair_count);
    const expected = reference_contacts.mergedItems();
    try std.testing.expect(expected.len > body_count);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(body_count);
    const pair_bound = CollisionSystem.broadphasePairBound(body_count);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try contacts.reserve(maxRangeCount(pair_bound, collision_range_alignment_items), pair_bound);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_allocator.allocator();
    contacts.allocator = failing_allocator.allocator();
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }

    for ([_]usize{ 32, 16 }) |items_per_range| {
        const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = 2, .adaptive = false });
        try std.testing.expect(!stats.broadphase_batch.ran_inline);
        try std.testing.expect(!stats.narrowphase_batch.ran_inline);
        try std.testing.expectEqual(reference_stats.candidate_pair_count, stats.candidate_pair_count);
        try expectSameContactPairs(expected, contacts.mergedItems());
    }
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

test "after reserve, 2- and 3-range broadphase partitions at ~3.9 pairs per body allocate nothing" {
    // 96 bodies in a row (spacing 10, 45 wide, inside one strip): each overlaps its next
    // four, so every range except the last holds exactly `broadphase_pairs_per_item` pairs
    // per item (374 pairs, 3.9 per body). A 2-range partition puts 48 entries (192 pairs) in
    // range 0, a 3-range one 32 (128 pairs): past a slot clamped to the 96-body capacity, so
    // range slots must be reserved per entry, not per body.
    if (builtin.single_threaded) return error.SkipZigTest;

    const body_count: usize = 96;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..body_count) |index| {
        _ = try addBox(&data, .{ .x = @floatFromInt(index * 10), .y = 0, .w = 45, .h = 8 });
    }

    var reference = CollisionSystem.init(std.testing.allocator);
    defer reference.deinit();
    var reference_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer reference_contacts.deinit();
    const reference_stats = try updateInline(&reference, &data, &reference_contacts);
    try std.testing.expectEqual(@as(usize, 4 * body_count - 10), reference_stats.candidate_pair_count);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(body_count);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try CollisionSystem.reserveContactStream(&contacts, body_count);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const original_system_allocator = system.allocator;
    const original_contacts_allocator = contacts.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_allocator.allocator();
    contacts.allocator = failing_allocator.allocator();
    defer {
        system.allocator = original_system_allocator;
        contacts.allocator = original_contacts_allocator;
    }

    for ([_][2]usize{ .{ 48, 2 }, .{ 32, 3 } }) |partition| {
        const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = partition[0], .max_worker_threads = 2, .adaptive = false });
        try std.testing.expect(!stats.broadphase_batch.ran_inline);
        try std.testing.expectEqual(partition[1], stats.broadphase_batch.range_count);
        try std.testing.expect(!stats.pair_bound_exceeded);
        try expectSameContactPairs(reference_contacts.mergedItems(), contacts.mergedItems());
    }
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

test "a broadphase slot replay within the total pair bound flags its step" {
    // 64 bodies at a 64-body reserve (256-pair bound, 128-entry bound), four broadphase
    // ranges of 16 entries: slot 2 holds 4 * ceil(128 / 3) = 172 pairs. Ranges 0 and 1 are
    // 32 isolated bodies; range 2 is 16 wide bodies that all overlap (120 pairs) and the four
    // narrow bodies of range 3 they cover in y (64 pairs): 184, past slot 2 but inside the
    // total bound. The slot grows and the broadphase replays: one flagged step, contacts
    // identical to the serial run. The grown slot then holds the cluster, so the next step
    // flags nothing.
    if (builtin.single_threaded) return error.SkipZigTest;

    const body_count: usize = 64;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..32) |index| _ = try addBox(&data, .{ .x = @floatFromInt(index * 100), .y = 0, .w = 22, .h = 8 });
    for (0..16) |index| _ = try addBox(&data, .{ .x = 10_000 + @as(f32, @floatFromInt(index)), .y = 0, .w = 1000, .h = 8 });
    for (0..16) |index| {
        const y: f32 = if (index < 4) 4 else 10;
        _ = try addBox(&data, .{ .x = 10_100 + @as(f32, @floatFromInt(index * 50)), .y = y, .w = 8, .h = 8 });
    }

    var reference = CollisionSystem.init(std.testing.allocator);
    defer reference.deinit();
    var reference_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer reference_contacts.deinit();
    const reference_stats = try updateInline(&reference, &data, &reference_contacts);
    try std.testing.expectEqual(@as(usize, 120 + 64), reference_stats.candidate_pair_count);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(body_count);
    try std.testing.expect(reference_stats.candidate_pair_count <= system.reserved_pair_bound);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try CollisionSystem.reserveContactStream(&contacts, body_count);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    const config: CollisionConfig = .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false };
    const replayed = try system.update(&data, &contacts, &threads, config);
    try std.testing.expect(!replayed.broadphase_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 4), replayed.broadphase_batch.range_count);
    try std.testing.expect(replayed.pair_bound_exceeded);
    try expectSameContacts(reference_contacts.mergedItems(), contacts.mergedItems());

    const settled = try system.update(&data, &contacts, &threads, config);
    try std.testing.expect(!settled.pair_bound_exceeded);
    try expectSameContacts(reference_contacts.mergedItems(), contacts.mergedItems());
}

test "candidate pairs past the reserved pair bound flag the step, even inside the physical slack" {
    // `reserve(4)` declares a 16-pair bound. 8 overlapping bodies make 28 pairs: inside
    // `candidate_pairs`' rounded-up capacity, past the bound. Each such step is flagged,
    // on the serial and the `update` path, and the contacts match an unreserved run (the
    // grow paths are deterministic). An unreserved system declares no bound and never flags.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..8) |index| {
        _ = try addBody(&data, @floatFromInt(index), 0, 22);
    }

    var reference = CollisionSystem.init(std.testing.allocator);
    defer reference.deinit();
    var reference_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer reference_contacts.deinit();
    const reference_stats = try updateInline(&reference, &data, &reference_contacts);
    try std.testing.expectEqual(@as(usize, 28), reference_stats.candidate_pair_count);
    try std.testing.expect(!reference_stats.pair_bound_exceeded);
    const expected = reference_contacts.mergedItems();

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(4);
    try std.testing.expectEqual(@as(usize, 16), system.reserved_pair_bound);
    try std.testing.expect(system.candidate_pairs.capacity >= 28);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    for (0..2) |step| {
        const stats = if (step == 0)
            try updateInline(&system, &data, &contacts)
        else
            try system.update(&data, &contacts, &threads, .{});
        try std.testing.expect(stats.pair_bound_exceeded);
        try expectSameContactPairs(expected, contacts.mergedItems());
    }

    // A capacity whose bound covers the scene stops counting.
    try system.reserve(8);
    try std.testing.expectEqual(@as(usize, 32), system.reserved_pair_bound);
    const covered = try updateInline(&system, &data, &contacts);
    try std.testing.expect(!covered.pair_bound_exceeded);
}

test "candidate pairs past the reserved pair bound flag every step on the multi-worker path" {
    // `reserve(32)` declares a 128-pair bound. 32 bodies each overlapping their next
    // five make 145 pairs, over broadphase ranges of 16: past the bound every step, each
    // flagged. Contacts match the serial run both times.
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..32) |index| {
        _ = try addBody(&data, @floatFromInt(index * 10), 0, 55);
    }

    var reference = CollisionSystem.init(std.testing.allocator);
    defer reference.deinit();
    var reference_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer reference_contacts.deinit();
    const reference_stats = try updateInline(&reference, &data, &reference_contacts);
    try std.testing.expectEqual(@as(usize, 145), reference_stats.candidate_pair_count);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(32);
    try std.testing.expectEqual(@as(usize, 128), system.reserved_pair_bound);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    for (0..2) |_| {
        const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false });
        try std.testing.expect(!stats.broadphase_batch.ran_inline);
        try std.testing.expect(!stats.narrowphase_batch.ran_inline);
        try std.testing.expect(stats.pair_bound_exceeded);
        try expectSameContactPairs(reference_contacts.mergedItems(), contacts.mergedItems());
    }
}

test "a contact stream reserved for a body capacity holds the pair bound" {
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try CollisionSystem.reserveContactStream(&contacts, 64);
    const pair_bound = CollisionSystem.broadphasePairBound(64);
    try std.testing.expectEqual(pair_bound, CollisionSystem.estimateContactCapacity(64));
    try std.testing.expect(contacts.values.capacity >= pair_bound);
    try std.testing.expect(contacts.counts.capacity >= maxRangeCount(pair_bound, collision_range_alignment_items));
}

test "collision proxies and entries round capacity for cache-line range splitting" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..collision_range_alignment_items * 3 + 1) |index| {
        _ = try addBody(&data, @floatFromInt(index * 4), 0, 6);
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const stats = try updateInline(&system, &data, &contacts);

    // MultiArrayList columns are not 64-byte aligned; capacity is still rounded
    // for cache-line range splitting via hotStoreCapacity.
    try std.testing.expectEqual(@as(usize, 16), collision_range_alignment_items);
    try std.testing.expectEqual(@as(usize, 0), (collision_range_alignment_items * @sizeOf(f32)) % hot_soa_column_alignment);
    try std.testing.expectEqual(@as(usize, collision_range_alignment_items * 3 + 1), system.proxies.len);
    try std.testing.expectEqual(@as(usize, collision_range_alignment_items * 4), hotStoreCapacity(system.proxies.len));
    try std.testing.expectEqual(stats.entry_count + simd.lane_count, system.entries.len);
}

test "collision ignores XY overlap across different world_levels" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try addBody(&data, 0, 0, 10);
    const second = try addBody(&data, 5, 0, 10);
    try data.setWorldLevel(first, 0);
    try data.setWorldLevel(second, 1);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const stats = try updateInline(&system, &data, &contacts);
    try std.testing.expectEqual(@as(usize, 2), stats.body_count);
    try std.testing.expectEqual(@as(usize, 0), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 0), stats.contact_count);
    try std.testing.expectEqual(@as(usize, 0), contacts.mergedItems().len);
}

test "collision same world_level still emits XY overlap contacts" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try addBody(&data, 0, 0, 10);
    const second = try addBody(&data, 5, 0, 10);
    try data.setWorldLevel(first, 2);
    try data.setWorldLevel(second, 2);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const stats = try updateInline(&system, &data, &contacts);
    try std.testing.expectEqual(@as(usize, 1), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 1), stats.contact_count);
    try std.testing.expectEqual(first.index, contacts.mergedItems()[0].a.index);
    try std.testing.expectEqual(second.index, contacts.mergedItems()[0].b.index);
}

test "collision simd broadphase same-level gate filters mixed world_levels" {
    // ≥5 mutually X-overlapping proxies so the first body's sweep hits a lane group. Levels
    // span 0 and 1, so the run gate is exercised inside that group.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const e0 = try addBody(&data, 0, 0, 10);
    const e1 = try addBody(&data, 1, 0, 10);
    const e2 = try addBody(&data, 2, 0, 10);
    const e3 = try addBody(&data, 3, 0, 10);
    const e4 = try addBody(&data, 4, 0, 10);
    try data.setWorldLevel(e0, 0);
    try data.setWorldLevel(e1, 0);
    try data.setWorldLevel(e2, 1);
    try data.setWorldLevel(e3, 1);
    try data.setWorldLevel(e4, 0);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const stats = try updateInline(&system, &data, &contacts);

    // Same-level only: level-0 pairs among {e0,e1,e4} (3) + level-1 {e2,e3} (1).
    // All five bodies mutually XY-overlap, so without the gate there would be C(5,2)=10.
    try std.testing.expectEqual(@as(usize, 4), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 4), stats.contact_count);

    const merged = contacts.mergedItems();
    try std.testing.expectEqual(@as(usize, 4), merged.len);
    for (merged) |contact| {
        const level_a = data.worldLevelConst(contact.a) orelse 0;
        const level_b = data.worldLevelConst(contact.b) orelse 0;
        try std.testing.expectEqual(level_a, level_b);
    }
}

test "scope_dense_indices limits collision fill to scoped bounds rows" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Three overlapping bounds rows; only the middle dense index is in scope.
    _ = try addBody(&data, 0, 0, 10);
    const middle = try addBody(&data, 0, 0, 10);
    _ = try addBody(&data, 0, 0, 10);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();

    const scope = [_]u32{1};
    const stats = try updateScopedInline(&system, &data, &contacts, &scope);
    try std.testing.expectEqual(@as(usize, 1), stats.body_count);
    try std.testing.expectEqual(@as(usize, 0), stats.candidate_pair_count);
    try std.testing.expectEqual(@as(usize, 0), stats.contact_count);
    try std.testing.expectEqual(@as(usize, 0), contacts.mergedItems().len);
    try std.testing.expect(system.proxies.items(.entity)[0].eql(middle));
}

test "narrowphase simd contacts match scalar contactForCandidate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Mix of overlaps, near-misses, axis ties (equal x/y penetration), and
    // multi-lane counts so both the SIMD chunk and scalar tail are exercised.
    _ = try addBody(&data, 0, 0, 10); // 0
    _ = try addBody(&data, 8, 0, 10); // 1: x-axis overlap with 0
    _ = try addBody(&data, 0, 8, 10); // 2: y-axis overlap with 0
    _ = try addBody(&data, 5, 5, 10); // 3: equal-ish x/y penetration with 0
    _ = try addBody(&data, 50, 50, 4); // 4: non-overlap vs others
    _ = try addBody(&data, 9, 1, 10); // 5: overlap with 0 and 1

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    // A cold fill puts bounds row k at slot k.
    _ = try buildForTest(&system, &data);
    const proxies = ConstProxyColumns.of(system.proxies.slice());

    const pairs = [_]CandidatePair{
        .{ .a = 0, .b = 1 },
        .{ .a = 0, .b = 2 },
        .{ .a = 0, .b = 3 },
        .{ .a = 0, .b = 4 },
        .{ .a = 0, .b = 5 },
        .{ .a = 1, .b = 5 },
        .{ .a = 1, .b = 4 },
        .{ .a = 2, .b = 3 },
        .{ .a = 3, .b = 5 },
    };
    try system.candidate_pairs.ensureTotalCapacity(std.testing.allocator, pairs.len);
    for (pairs) |pair| {
        system.candidate_pairs.appendAssumeCapacity(pair);
    }

    // Scalar reference: one optional contact per candidate, in pair order.
    var expected: std.ArrayList(CollisionContact) = .empty;
    defer expected.deinit(std.testing.allocator);
    try expected.ensureTotalCapacity(std.testing.allocator, pairs.len);
    for (pairs) |pair| {
        if (contactForCandidate(proxies, pair.a, pair.b)) |contact| {
            expected.appendAssumeCapacity(contact);
        }
    }

    // One range over a non-multiple-of-lane-count pair list exercises both the
    // SIMD chunk loop and the scalar tail inside writeNarrowphaseContactsSimd.
    try system.prepareNarrowphaseStaging(pairs.len, 1);
    writeNarrowphaseContactsSimd(&system, .{ .index = 0, .start = 0, .end = pairs.len });

    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const contact_count = try system.mergeNarrowphaseContacts(&contacts, pairs.len);

    try std.testing.expectEqual(expected.items.len, contact_count);
    try expectSameContacts(expected.items, contacts.mergedItems());
}

test "merging sorted runs equals sorting their concatenation" {
    var prng = std.Random.DefaultPrng.init(0x6d_65_72_67);
    const random = prng.random();
    for ([_][2]usize{ .{ 0, 0 }, .{ 5, 0 }, .{ 0, 5 }, .{ 1, 1 }, .{ 40, 13 }, .{ 7, 60 } }) |lengths| {
        var keys: [120]SortEntry = undefined;
        var tail: [60]SortEntry = undefined;
        const head = keys[0..lengths[0]];
        for (head) |*entry| entry.* = .{ .key = random.uintLessThan(u128, 50), .slot = 0, .first = true };
        for (tail[0..lengths[1]], 0..) |*entry, index| entry.* = .{ .key = random.uintLessThan(u128, 50), .slot = @intCast(index), .first = false };
        std.sort.pdq(SortEntry, head, {}, entryLessThan);
        std.sort.pdq(SortEntry, tail[0..lengths[1]], {}, entryLessThan);
        var expected: [120]SortEntry = undefined;
        @memcpy(expected[0..lengths[0]], head);
        @memcpy(expected[lengths[0]..][0..lengths[1]], tail[0..lengths[1]]);
        const total = lengths[0] + lengths[1];
        std.sort.pdq(SortEntry, expected[0..total], {}, entryLessThan);
        mergeIntoSorted(keys[0..total], lengths[0], tail[0..lengths[1]]);
        for (expected[0..total], keys[0..total]) |want, got| try std.testing.expectEqual(want.key, got.key);
    }
}

test "strips are the tile size rounded down to a power of two" {
    try std.testing.expectEqual(@as(f32, 32), CollisionStrips.ofTileSize(32).height);
    try std.testing.expectEqual(@as(f32, 16), CollisionStrips.ofTileSize(24).height);
    try std.testing.expectEqual(@as(f32, 0.5), CollisionStrips.ofTileSize(0.75).height);
    try std.testing.expectEqual(required_tile_size, CollisionStrips.default.height);
}
