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
const paddingForCacheLine = @import("../../app/thread_system.zig").paddingForCacheLine;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const rebuild_tuner_config = @import("../../app/thread_system.zig").rebuild_tuner_config;
const setRowCount = @import("../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const required_tile_size = @import("../../assets/world_tileset_meta.zig").required_tile_size;
const ConstCollisionBoundsSlice = @import("../data_system.zig").ConstCollisionBoundsSlice;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const ConstScopeColumnsSlice = @import("../data_system.zig").ConstScopeColumnsSlice;
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
const ColliderView = @import("static_colliders.zig").ColliderView;
const ColliderChange = @import("static_colliders.zig").ColliderChange;
const SpanIds = @import("static_colliders.zig").SpanIds;
const idleSpanIds = @import("static_colliders.zig").idleSpanIds;
const OldPlacement = @import("static_colliders.zig").OldPlacement;
const collision_triggers = @import("collision_triggers.zig");
const TriggerStore = collision_triggers.TriggerStore;
const StoreThreads = collision_triggers.StoreThreads;
const EditSource = collision_triggers.EditSource;
const InsertEdit = collision_triggers.InsertEdit;
const PageLocation = collision_triggers.PageLocation;
const DropPiece = collision_triggers.DropPiece;

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
const strip_bits = 16;
const strip_count: u32 = 1 << strip_bits;
/// Where a contact key's (level, strip) run starts: below the store's level bits, so the
/// level is the key's top 16 bits for both.
const contact_run_shift = collision_triggers.key_level_shift - strip_bits;

const hotStoreCapacity = @import("../data_system.zig").hotStoreCapacity;

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
    level: u16 = 0,
    /// 1 when the body's tier allows collision, else 0. Gathered from its movement row at
    /// the fill, so the static query reads no tier column.
    allow: u8 = 0,
    // The fill input the slot read: an index into the scope list, or into `dynamic_ids`.
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
    level: []u16,
    allow: []u8,
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
            .level = rows.items(.level),
            .allow = rows.items(.allow),
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
    level: []const u16,
    allow: []const u8,
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
            .level = rows.items(.level),
            .allow = rows.items(.allow),
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
    return (@as(u32, level) << strip_bits) | strip;
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
    /// this step (the scope system excludes dormant/kinematic entities). Null = the
    /// dynamic bounds index: no tier exclusion, and static obstacles are not swept.
    scope_dense_indices: ?[]const u32 = null,
    /// Static query columns from the previous commit. Empty until a rebuild.
    static_colliders: ColliderView = .{},
};

const Threads = StageThreads(CollisionConfig);

pub const CollisionStats = struct {
    /// Bodies swept: fill inputs with a movement body.
    body_count: usize = 0,
    /// Sweep entries: one per strip each body spans.
    entry_count: usize = 0,
    contact_count: usize = 0,
    candidate_pair_count: usize = 0,
    /// Sweep lane groups: counted and set only with `runtime_perf_log.enabled`, else 0.
    broadphase_simd_groups: usize = 0,
    broadphase_batch: BatchStats = .{},
    narrowphase_batch: BatchStats = .{},
    perf: Perf = .{},

    /// Kept only with `runtime_perf_log.enabled`: whether the step outgrew its pair bound,
    /// the entries the sweep tested against an earlier entry of its run inside that entry's
    /// x span, and the batches of the stages the step ran. A stage that did not run leaves
    /// its batch zero: the Debug stored-rect compare in every other mode, the stored-trigger
    /// refresh on a step whose allow epoch did not move, the emission count pass on a step
    /// that emits every stored pair.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        /// This reserved step outgrew the pair bound, so a main-thread grow path ran: the
        /// candidate pairs exceeded `CollisionSystem.reserved_pair_bound`, a broadphase
        /// range held more than `broadphase_pairs_per_item` pairs per entry its slot was
        /// reserved for (the slot grew and the broadphase replayed), a static query range
        /// outgrew its pair or hit rows (the slot grew and the query replayed), or the
        /// stored and dynamic contacts exceeded the contact bound (the pair bound plus
        /// `CollisionSystem.reserved_trigger_bound`; the contact stream grew). Set
        /// once per step, with one `CollisionSystem.perf.pair_bound_overflows` count.
        pair_bound_exceeded: bool = false,
        broadphase_visits: usize = 0,
        fill_batch: BatchStats = .{},
        sort_batch: BatchStats = .{},
        static_pairs_batch: BatchStats = .{},
        static_rect_batch: BatchStats = .{},
        static_place_batch: BatchStats = .{},
        static_sort_batch: BatchStats = .{},
        trigger_refresh_batch: BatchStats = .{},
        trigger_emit_count_batch: BatchStats = .{},
        trigger_emit_batch: BatchStats = .{},
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
    perf: SweepPerf = .{},

    fn clearRetainingCapacity(self: *BroadphaseRangeBuffer) void {
        self.pairs.clearRetainingCapacity();
        self.required_capacity = 0;
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

const KeyedContact = struct {
    key: u256,
    contact: CollisionContact,
};

/// Narrowphase emits at most one contact per candidate pair, so it needs no per-range
/// buffers: range r writes only its own `[range.start, range.end)` window of one
/// candidate-pair-count staging list and its count into a padded tally. When a
/// static pair is in the merge, the same window of `narrowphase_keys` holds the
/// order key taken from the proxy columns. The main thread streams the windows
/// in range order.
const ContactStagingList = std.array_list.Aligned(CollisionContact, .fromByteUnits(thread_shared_record_alignment));
const NarrowphaseKeyList = std.array_list.Aligned(u256, .fromByteUnits(thread_shared_record_alignment));

/// One narrowphase range's contact count, written once by the range's job.
const ContactCountTally = struct {
    // Padding keeps concurrently written tallies off shared cache lines.
    count: usize = 0,
    padding: [paddingForCacheLine(usize)]u8 = @splat(0),
};

comptime {
    std.debug.assert(@sizeOf(ContactCountTally) % thread_shared_record_alignment == 0);
    std.debug.assert(@sizeOf(PaddedSlot(SpillCopies)) % thread_shared_record_alignment == 0);
    // One narrowphase range starts on a cache line when the previous one does.
    std.debug.assert(collision_range_alignment_items * @sizeOf(CollisionContact) % thread_shared_record_alignment == 0);
    std.debug.assert(collision_range_alignment_items * @sizeOf(u256) % thread_shared_record_alignment == 0);
    std.debug.assert(@sizeOf(PaddedSlot(TriggerQuerySlot)) % thread_shared_record_alignment == 0);
    std.debug.assert(@sizeOf(PaddedSlot(EmitRange)) % thread_shared_record_alignment == 0);
}

const ContactCountTallyList = std.array_list.Aligned(ContactCountTally, .fromByteUnits(thread_shared_record_alignment));

const HitRow = struct {
    entity: u32,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    movement_index: u32,
    generation: u32,
    allow: u32,
    velocity_x: f32,
    velocity_y: f32,
};

const HitColumns = struct {
    entity: []u32,
    min_x: []f32,
    min_y: []f32,
    max_x: []f32,
    max_y: []f32,
    movement_index: []u32,
    generation: []u32,
    allow: []u32,
    velocity_x: []f32,
    velocity_y: []f32,

    fn of(rows: std.MultiArrayList(HitRow).Slice) HitColumns {
        return .{
            .entity = rows.items(.entity),
            .min_x = rows.items(.min_x),
            .min_y = rows.items(.min_y),
            .max_x = rows.items(.max_x),
            .max_y = rows.items(.max_y),
            .movement_index = rows.items(.movement_index),
            .generation = rows.items(.generation),
            .allow = rows.items(.allow),
            .velocity_x = rows.items(.velocity_x),
            .velocity_y = rows.items(.velocity_y),
        };
    }
};

// Exactly `n` rows. `setCapacity` allocates even when the capacity already matches,
// so a warm slot only sets the row count.
fn ensureHitRows(hits: *std.MultiArrayList(HitRow), allocator: std.mem.Allocator, n: usize) error{OutOfMemory}!void {
    if (hits.capacity < n) try hits.setCapacity(allocator, n);
    setRowCount(HitRow, hits, n);
}

// A range's static query output. `pairs` accumulates over the range's queries; `hits` is
// one query's scratch, so it is sized to the largest single query, not the range's pairs.
const StaticPairBuffer = struct {
    pairs: std.ArrayList(KeyedContact) = .empty,
    hits: std.MultiArrayList(HitRow) = .{},
    // The pair count the range needed past `pairs.capacity`; 0 when it fit.
    required: usize = 0,
    // The largest single query's hit count past `hits.len`; 0 when every query fit.
    hits_required: usize = 0,
    // Set at the first query that did not fit; that query and every later one in the range
    // write no pairs. `pending` is their hits, which bounds the pairs they owe.
    overflowed: bool = false,
    pending: usize = 0,
    // Debug: entity indices the range's uncapped walks read. ReleaseFast leaves both empty.
    ids: std.ArrayList(u32) = .empty,
    ids_required: usize = 0,

    fn clear(self: *StaticPairBuffer) void {
        self.pairs.clearRetainingCapacity();
        self.required = 0;
        self.hits_required = 0;
        self.overflowed = false;
        self.pending = 0;
        if (comptime builtin.mode == .debug) {
            self.ids.clearRetainingCapacity();
            self.ids_required = 0;
        }
    }

    fn deinit(self: *StaticPairBuffer, allocator: std.mem.Allocator) void {
        self.pairs.deinit(allocator);
        self.hits.deinit(allocator);
        self.ids.deinit(allocator);
    }

    // Whether a query of `full` hits writes its pairs. From the first query that does not
    // fit, every later query in the range only records its need: its hits past the rows,
    // and the pairs the range would hold with every hit a pair. The range runs to its end,
    // so one grow sizes it for the replay.
    fn admit(self: *StaticPairBuffer, full: usize) bool {
        if (!self.overflowed and full <= self.hits.len and self.pairs.items.len + full <= self.pairs.capacity) return true;
        self.overflowed = true;
        if (full > self.hits.len) self.hits_required = @max(self.hits_required, full);
        self.pending += full;
        const pairs_needed = self.pairs.items.len + self.pending;
        if (pairs_needed > self.pairs.capacity) self.required = @max(self.required, pairs_needed);
        return false;
    }
};

// The largest need past its rows any static slot showed in a pass: a range's pairs, one
// query's hits, a range's Debug walked ids. All 0 when every slot fit.
const StaticSlotGrowth = struct {
    pairs: usize = 0,
    hits: usize = 0,
    ids: usize = 0,

    fn grew(self: StaticSlotGrowth) bool {
        return self.pairs != 0 or self.hits != 0 or self.ids != 0;
    }

    fn merge(self: StaticSlotGrowth, other: StaticSlotGrowth) StaticSlotGrowth {
        return .{ .pairs = @max(self.pairs, other.pairs), .hits = @max(self.hits, other.hits), .ids = @max(self.ids, other.ids) };
    }
};

/// Hit rows `reserve` gives each static query slot: one query's overlaps, up to the pairs
/// one alignment window of items is reserved for, and never more than the slot's pairs. A
/// query with more overlaps grows its slot's rows geometrically past that count on the
/// counted grow path.
const reserved_query_hits: usize = broadphase_pairs_per_item * collision_range_alignment_items;

/// Stored-trigger edit records reserved per trigger query item: a reserve heuristic, never
/// a gate. A range past it grows its slot and replays.
const trigger_records_per_item: usize = broadphase_pairs_per_item;

// A trigger query's items: the revision's changes (a patch), or every row-pool id (a
// rebuild).
const TriggerQueryMode = enum { patch, rebuild };

// One trigger query range's edits in item order, and one query's hits and kernel contacts.
// Grow-only across patches, so each slot keeps its lists' capacity; a rebuild frees what
// only its query reserved (`releaseRebuildQuerySlots`).
const TriggerQuerySlot = struct {
    hits: std.MultiArrayList(HitRow) = .{},
    contacts: std.ArrayList(KeyedContact) = .empty,
    inserts: std.ArrayList(InsertEdit) = .empty,
    // Patch only: the page `inserts[i]`'s key falls in.
    insert_pages: std.ArrayList(PageLocation) = .empty,
    drops: std.ArrayList(DropPiece) = .empty,
    // The records the range's items owe, held or not.
    insert_need: usize = 0,
    drop_need: usize = 0,
    // The largest single query's hit count past `hits.len`; 0 when every query fit.
    hits_required: usize = 0,
    // Set at the first record or query that did not fit: from there the range only counts
    // its needs, so one grow sizes it for the replay.
    overflowed: bool = false,

    fn clear(self: *TriggerQuerySlot) void {
        self.contacts.clearRetainingCapacity();
        self.inserts.clearRetainingCapacity();
        self.insert_pages.clearRetainingCapacity();
        self.drops.clearRetainingCapacity();
        self.insert_need = 0;
        self.drop_need = 0;
        self.hits_required = 0;
        self.overflowed = false;
    }

    fn deinit(self: *TriggerQuerySlot, allocator: std.mem.Allocator) void {
        self.hits.deinit(allocator);
        self.contacts.deinit(allocator);
        self.inserts.deinit(allocator);
        self.insert_pages.deinit(allocator);
        self.drops.deinit(allocator);
    }

    // `page` is null in a rebuild, which locates nothing.
    fn pushInsert(self: *TriggerQuerySlot, edit: InsertEdit, page: ?PageLocation) void {
        self.insert_need += 1;
        if (self.overflowed) return;
        const fits = self.inserts.items.len < self.inserts.capacity and
            (page == null or self.insert_pages.items.len < self.insert_pages.capacity);
        if (!fits) {
            self.overflowed = true;
            return;
        }
        self.inserts.appendAssumeCapacity(edit);
        if (page) |located| self.insert_pages.appendAssumeCapacity(located);
    }

    fn pushDrop(self: *TriggerQuerySlot, piece: DropPiece) void {
        self.drop_need += 1;
        if (self.overflowed) return;
        if (self.drops.items.len == self.drops.capacity) {
            self.overflowed = true;
            return;
        }
        self.drops.appendAssumeCapacity(piece);
    }

    fn noteHits(self: *TriggerQuerySlot, full: usize) void {
        self.hits_required = @max(self.hits_required, full);
        self.overflowed = true;
    }
};

// One emission range's split of the merged order: its stored pairs, its dynamic-side
// contacts, and the contacts it writes. Written once by its range's count job.
const EmitRange = struct {
    stored_start: u32 = 0,
    stored_end: u32 = 0,
    dynamic_start: usize = 0,
    dynamic_end: usize = 0,
    out: usize = 0,
};

const no_static_row: u32 = std.math.maxInt(u32);

// A fill's band starts: band b's entries are `[entry_start[b], entry_start[b + 1])`.
// Its first copies rank `[first_start[b], first_start[b + 1])` among all first copies,
// and its second copies rank `[second_start[b], second_start[b + 1])` among all second
// copies. Within the band the runs are first, then second, then spill.
const BandStarts = struct {
    entry_start: [band_count + 1]u32,
    first_start: [band_count + 1]u32,
    second_start: [band_count + 1]u32,
};

pub const CollisionSystem = struct {
    allocator: std.mem.Allocator,
    // By fill slot.
    proxies: std.MultiArrayList(ProxyRow) = .{},
    // Packed inputs for the fill's lane kernel, by fill slot. Reserved with `proxies`.
    fill_inputs: std.MultiArrayList(FillInput) = .{},
    // Sort elements in sweep order; the fill first writes each range's first copies
    // into its window.
    keys: SortEntryList = .empty,
    // The banded sort's merge tails, indexed like `keys` and reserved with them.
    merge_scratch: SortEntryList = .empty,
    // The fill's band-placed first-copy windows.
    staging: SortEntryList = .empty,
    first_offsets: SlotList(BandOffsets) = .empty,
    // By fill slot window: the second copies of the slots' bodies, then their band-placed
    // windows.
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
    // Order keys for `narrowphase_staging`, same index. Written only when this step
    // merges static pairs; a dynamic-only step leaves it unused.
    narrowphase_keys: NarrowphaseKeyList = .empty,
    narrowphase_tallies: ContactCountTallyList = .empty,
    fill_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    sort_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    broadphase_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    narrowphase_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    static_pair_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // Debug stored-rect compare. A query replay must not teach it, and it must not teach
    // `static_pair_tuner`. ReleaseFast never selects it, so `sample_count` stays 0.
    static_rect_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    static_place_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    static_sort_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    trigger_query_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    trigger_query_rebuild_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(rebuild_tuner_config),
    emit_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    /// The last `update`'s strips, or the ones the owner set before a step ran (the world's,
    /// for the pipeline's init build); the engine tile until either.
    strips: CollisionStrips = .default,
    static_pair_slots: SlotList(StaticPairBuffer) = .empty,
    static_pairs: std.ArrayList(KeyedContact) = .empty,
    // Debug distinct entity indices, the compare's scratch (one row per distinct id, each
    // range writing its own window), and its per-range flags. ReleaseFast does not touch them.
    distinct_ids: std.ArrayList(u32) = .empty,
    rect_scratch: RectScratch = .{},
    rect_moved: SlotList(RectMoved) = .empty,
    // By entity index: the `rect_generation` that last listed it.
    rect_stamp: std.ArrayList(u32) = .empty,
    rect_generation: u32 = 1,
    ordered: std.ArrayList(KeyedContact) = .empty,
    sort_staging: std.ArrayList(KeyedContact) = .empty,
    sort_offsets: SlotList(BandOffsets) = .empty,
    /// The static-static pairs with a trigger side, in contact-key order.
    trigger_store: TriggerStore,
    // The strips the stored keys were built with.
    trigger_strips: CollisionStrips = .default,
    // Per trigger query range; never reset through `setSlotCount`, so a slot keeps its
    // lists. Patches only grow them; a rebuild trims them to the patches' slots.
    trigger_query_slots: SlotList(TriggerQuerySlot) = .empty,
    trigger_edit_sources: std.ArrayList(EditSource) = .empty,
    emit_ranges: SlotList(EmitRange) = .empty,
    /// The last patch query's batch shape; `resetSeamBatches` clears it at seam entry, so
    /// after a seam that rebuilt or did nothing it holds none.
    trigger_query_batch: BatchStats = .{},
    /// The last rebuild query's batch shape; reset by every rebuild.
    trigger_rebuild_query_batch: BatchStats = .{},
    // By entity index: the `change_generation` that last stamped it as changed.
    change_mark: std.ArrayList(u32) = .empty,
    change_generation: u32 = 1,
    /// The pair bound `reserve` declared (`broadphasePairBound(body_capacity)`, grow-only);
    /// 0 until `reserve` runs. Telemetry compares against this logical limit, never a
    /// list's `.capacity`, which `ensureTotalCapacity` rounds past it.
    reserved_pair_bound: usize = 0,
    /// The entry bound `reserve` declared (`entries_per_body` per body, grow-only); 0 until
    /// `reserve` runs.
    reserved_entry_bound: usize = 0,
    /// The stored trigger contacts the commit seam declared (`reserveTriggerContacts`,
    /// grow-only); 0 until a seam tops it up. The contact bound every contact-sized reserve
    /// covers is `reserved_pair_bound +| reserved_trigger_bound`.
    reserved_trigger_bound: usize = 0,
    pair_bound_warned: bool = false,
    static_slot_warned: bool = false,
    entry_bound_warned: bool = false,
    contact_bound_warned: bool = false,
    trigger_slot_growth_logged: bool = false,
    perf: Perf = .{},

    /// Telemetry, kept only with `runtime_perf_log.enabled`. Every grow path it counts runs on
    /// the main thread between batches; the contacts are identical either way, and each
    /// logs once.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        /// Reserved steps that outgrew the pair bound (perf metric
        /// `collision_pair_bound_exceeded`), counted once per step. Either the candidate
        /// pairs exceeded `reserved_pair_bound`, so the merged candidates, the narrowphase
        /// staging, the contact stream and the response reserves (all sized to that bound
        /// under the pipeline) grew, or a range's pairs outgrew its broadphase slot, so the
        /// slot grew and the broadphase replayed, or a static query range outgrew its slot,
        /// so the slot grew and the query replayed, or the stored and dynamic contacts
        /// exceeded the contact bound (`reserved_pair_bound +| reserved_trigger_bound`), so
        /// the contact stream and its emission ranges grew.
        pair_bound_overflows: u64 = 0,
        /// Reserved steps whose entries exceeded `reserved_entry_bound` (the keys and entries
        /// grew the first time) or whose fill spilled past a range's spill slot (the slot
        /// grew and the fill replayed), counted once per step.
        entry_bound_overflows: u64 = 0,
        /// Trigger queries whose range slots grew, before the query or for its replay,
        /// counted once per query.
        trigger_slot_grows: u64 = 0,
    } else struct {};

    pub fn init(allocator: std.mem.Allocator) CollisionSystem {
        return .{ .allocator = allocator, .trigger_store = .init(allocator) };
    }

    pub fn deinit(self: *CollisionSystem) void {
        self.change_mark.deinit(self.allocator);
        self.emit_ranges.deinit(self.allocator);
        self.trigger_edit_sources.deinit(self.allocator);
        for (self.trigger_query_slots.items) |*slot| slot.value.deinit(self.allocator);
        self.trigger_query_slots.deinit(self.allocator);
        self.trigger_store.deinit();
        self.sort_offsets.deinit(self.allocator);
        self.sort_staging.deinit(self.allocator);
        self.ordered.deinit(self.allocator);
        self.static_pairs.deinit(self.allocator);
        self.distinct_ids.deinit(self.allocator);
        self.rect_stamp.deinit(self.allocator);
        self.rect_scratch.deinit(self.allocator);
        self.rect_moved.deinit(self.allocator);
        for (self.static_pair_slots.items) |*slot| slot.value.deinit(self.allocator);
        self.static_pair_slots.deinit(self.allocator);
        self.narrowphase_tallies.deinit(self.allocator);
        self.narrowphase_keys.deinit(self.allocator);
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
        self.merge_scratch.deinit(self.allocator);
        self.keys.deinit(self.allocator);
        self.fill_inputs.deinit(self.allocator);
        self.proxies.deinit(self.allocator);
        self.* = undefined;
    }

    /// Pre-sizes every step buffer for `body_capacity` bodies, so an inline or threaded
    /// step is allocation-free from the first step under every partition the tuners can
    /// pick. Grow-only; re-run by the pipeline's population seam.
    ///
    /// A body's first and second copies write their slot's own windows, so the fill
    /// reserves O(bodies); copies past a second strip spill to unreserved per-range slots.
    /// Broadphase pairs are data-dependent and keep per-range slots sized for the most
    /// entries range r of any partition covers (`@divCeil(entries, r + 1)`, r full ranges
    /// precede it), never clamped to the total: `broadphase_pairs_per_item` pairs per entry
    /// for every `r < maxRangeCount`. The keys, the merge buffer, and the entries hold
    /// `entries_per_body` per body;
    /// the merged candidates, the narrowphase staging (at most one contact per candidate
    /// pair, one window per range), and its tallies hold the pair bound over the body
    /// capacity (`broadphasePairBound`). Static query slots hold the same per-range pair
    /// bound, and one query's hit rows (`reserved_query_hits`, at most the slot's pairs).
    /// The stored-trigger emission's range records cover the contact bound's ranges (the
    /// pair bound plus `reserved_trigger_bound`). A denser or taller scene, in total or
    /// inside one range, takes the counted grow paths (`Perf`).
    pub fn reserve(self: *CollisionSystem, body_capacity: usize) !void {
        if (body_capacity == 0) return;
        // The u32 slots, sources, and pair indices are exhausted only past maxInt(u32)
        // proxies, which the entity index cannot reach; past it this is allocator exhaustion.
        if (body_capacity > std.math.maxInt(u32) / entries_per_body) return error.OutOfMemory;
        const entry_capacity = body_capacity * entries_per_body;
        const pair_capacity = broadphasePairBound(body_capacity);
        try self.proxies.ensureTotalCapacity(self.allocator, hotStoreCapacity(body_capacity));
        try self.fill_inputs.ensureTotalCapacity(self.allocator, hotStoreCapacity(body_capacity));
        try self.keys.ensureTotalCapacity(self.allocator, entry_capacity);
        try self.merge_scratch.ensureTotalCapacity(self.allocator, entry_capacity);
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
        try self.narrowphase_keys.ensureTotalCapacityPrecise(self.allocator, pair_capacity);
        try self.narrowphase_tallies.ensureTotalCapacityPrecise(self.allocator, maxRangeCount(pair_capacity, collision_range_alignment_items));
        const static_ranges = maxRangeCount(body_capacity, collision_range_alignment_items);
        try self.prepareStaticPairSlots(static_ranges);
        for (self.static_pair_slots.items[0..static_ranges], 0..) |*slot, range_index| {
            const bound = broadphasePairBound(@divCeil(body_capacity, range_index + 1));
            try slot.value.pairs.ensureTotalCapacityPrecise(self.allocator, bound);
            // One query's scratch: the slot's rows stay O(1), so all slots are O(bodies).
            const hit_rows = @min(bound, reserved_query_hits);
            if (slot.value.hits.len < hit_rows) try ensureHitRows(&slot.value.hits, self.allocator, hit_rows);
            // Same bound as the pairs: the range's walks read ids across all its queries.
            if (comptime builtin.mode == .debug) try slot.value.ids.ensureTotalCapacityPrecise(self.allocator, bound);
        }
        try self.static_pairs.ensureTotalCapacity(self.allocator, pair_capacity);
        try self.ordered.ensureTotalCapacity(self.allocator, pair_capacity);
        try self.sort_staging.ensureTotalCapacity(self.allocator, pair_capacity);
        // The static place runs over up to the pair bound's items.
        const pair_ranges = maxRangeCount(pair_capacity, collision_range_alignment_items);
        try self.sort_offsets.ensureTotalCapacity(self.allocator, pair_ranges);
        try self.emit_ranges.ensureTotalCapacity(self.allocator, maxRangeCount(pair_capacity +| self.reserved_trigger_bound, collision_range_alignment_items));
        self.reserved_pair_bound = @max(self.reserved_pair_bound, pair_capacity);
        self.reserved_entry_bound = @max(self.reserved_entry_bound, entry_capacity);
    }

    /// Reserves a contact stream for `contact_capacity` contacts: its values to that count
    /// and its ranges to the emission's range bound over it (`update` streams one range per
    /// emission range, at most `maxRangeCount(contacts, collision_range_alignment_items)`).
    /// Callers pass the contact bound (`estimateContactCapacity` plus any stored trigger
    /// bound). Grow-only.
    pub fn reserveContactStream(contacts: *RangeOutputStream(CollisionContact), contact_capacity: usize) !void {
        try contacts.reserve(maxRangeCount(contact_capacity, collision_range_alignment_items), contact_capacity);
    }

    /// Declares `bound` stored trigger contacts on top of the pair bound: grows the emission's
    /// range records to the summed contact bound, then raises `reserved_trigger_bound` last,
    /// so an OOM leaves it unchanged. The caller reserves the contact-sized streams to the
    /// same sum first. Grow-only; main thread, at the commit seam.
    pub fn reserveTriggerContacts(self: *CollisionSystem, bound: usize) error{OutOfMemory}!void {
        if (bound <= self.reserved_trigger_bound) return;
        const range_bound = maxRangeCount(self.reserved_pair_bound +| bound, collision_range_alignment_items);
        try self.emit_ranges.ensureTotalCapacity(self.allocator, range_bound);
        std.debug.assert(self.emit_ranges.capacity >= range_bound);
        self.reserved_trigger_bound = bound;
    }

    /// Clears the seam's trigger batch records (the patch query's and the store's stages), so
    /// a seam that fails, rebuilds, or does nothing leaves none from an earlier seam.
    pub fn resetSeamBatches(self: *CollisionSystem) void {
        self.trigger_query_batch = .{};
        self.trigger_store.last_batches = .initFill(.{});
    }

    /// Brings the trigger store up to `view` after a collider sync; a view with no geometry
    /// is skipped. A contiguous revision with changes patches: a query over the changes
    /// builds exact drops and located inserts, and the store rewrites only the pages they
    /// touch. Anything else rebuilds from the row pool. Growth is this call's, on this
    /// thread; the query and the store's stages use `thread_system` and run inline below
    /// their gates. Strips are `strips`: the last collision step's, or the owner's before one.
    /// The next `update` with this revision does not patch. A patch error leaves the stored
    /// pairs and revision unchanged; a rebuild error leaves the store empty and not ready.
    /// Either way the next call, or the next `update`, retries: a rebuild after a rebuild
    /// error.
    pub fn syncCommittedTriggers(self: *CollisionSystem, data: *const DataSystem, view: ColliderView, thread_system: *ThreadSystem) error{OutOfMemory}!void {
        // Reset first: the seam's patch batches are recorded every step, patched or not.
        self.resetSeamBatches();
        if (view.geometry == null) return;
        try self.syncTriggers(data, view, .{
            .thread_system = thread_system,
            .config = .{ .strips = self.strips, .static_colliders = view },
        });
    }

    /// One collision step over the bounds rows (or `config.scope_dense_indices`): the fill,
    /// sort, broadphase, and narrowphase, the static query, the stored-trigger refresh, and
    /// the key-ordered emission of stored and dynamic contacts, each on workers under its
    /// own tuner or inline as it selects. With no worker the same functions run inline.
    /// Allocates only past `reserve`'s bounds, on the calling thread between dispatches.
    pub fn update(
        self: *CollisionSystem,
        data: *const DataSystem,
        contacts: *RangeOutputStream(CollisionContact),
        thread_system: *ThreadSystem,
        config: CollisionConfig,
    ) !CollisionStats {
        // The sweep and the trigger patch's half-open strip span need exact strip division.
        std.debug.assert(std.math.frexp(config.strips.height).significand == 0.5);
        self.strips = config.strips;
        const view = config.static_colliders;
        if (comptime builtin.mode == .debug) {
            if (view.geometry == null) {
                std.debug.assert(data.collision_bounds.dynamic_ids.items.len == data.collision_bounds.len());
            }
        }
        const threads: Threads = .{ .thread_system = thread_system, .config = config };
        var stats = CollisionStats{};
        const sweep = try self.buildBanded(data, config.scope_dense_indices, config.strips, threads, &stats);
        // The query reads proxies only, so it runs before the narrowphase and the
        // narrowphase writes order keys only when a static or stored pair will be merged.
        const exclude = data.tierCount(.dormant) + data.tierCount(.kinematic) != 0;
        const moved = try self.gatherStaticPairs(data, view, threads, exclude, &stats);
        if (moved) return error.StaticMovedOutsideCommit;
        const store = &self.trigger_store;
        const stored_emitted: u32 = if (view.geometry == null or store.pair_count == 0) 0 else if (exclude) store.allowed_count else store.valid_count;
        // A step that emits no stored pair merges none.
        const stored: u32 = if (stored_emitted == 0) 0 else store.pair_count;
        const write_keys = self.static_pairs.items.len != 0 or stored_emitted != 0;
        var narrow_items: usize = 0;
        var narrow_ran = false;
        if (sweep) {
            const broadphase_stage = threads.stage(&self.broadphase_tuner);
            const broadphase_selection = broadphase_stage.select(stats.entry_count, collision_range_alignment_items);
            const broadphase = try self.buildBroadphaseCandidatesThreaded(thread_system, broadphase_selection, stats.entry_count);
            if (broadphase_selection.active_tuner) |tuner| tuner.record(broadphase.batch);
            stats.broadphase_batch = broadphase.batch;
            if (comptime runtime_perf_log.enabled) {
                stats.broadphase_simd_groups = broadphase.perf.simd_groups;
                stats.perf.broadphase_visits = broadphase.perf.visits;
            }
            const candidate_pair_count = self.candidate_pairs.items.len;
            stats.candidate_pair_count = candidate_pair_count;
            self.countPairBoundOverflow(&stats, candidate_pair_count, broadphase.grew);
            if (candidate_pair_count != 0) {
                const narrowphase_stage = threads.stage(&self.narrowphase_tuner);
                const narrowphase_selection = narrowphase_stage.select(candidate_pair_count, collision_range_alignment_items);
                try self.prepareNarrowphaseStaging(candidate_pair_count, narrowphase_selection.range_count, write_keys);
                var context = NarrowphaseJobContext{
                    .system = self,
                    .range_count = narrowphase_selection.range_count,
                    .candidate_pair_count = candidate_pair_count,
                    .items_per_range = narrowphase_selection.items_per_range,
                    .write_keys = write_keys,
                };
                stats.narrowphase_batch = narrowphase_stage.run(narrowphase_selection, candidate_pair_count, collision_range_alignment_items, &context, narrowphaseContactsJob);
                narrow_items = narrowphase_selection.items_per_range;
                narrow_ran = true;
            }
        }

        if (!write_keys) {
            if (narrow_ran) {
                stats.contact_count = try self.mergeNarrowphaseContacts(contacts, narrow_items);
            } else {
                contacts.clearRetainingCapacity();
            }
            return stats;
        }
        try self.sortStaticPairs(threads, &stats);
        const dynamic = try self.mergeOrdered(narrow_ran, narrow_items);
        stats.contact_count = try self.emitContacts(contacts, dynamic, stored, stored_emitted, exclude, threads, &stats);
        return stats;
    }

    // ---- Fill and sort ------------------------------------------------------------

    // Sizes the step's slot buffers for `input_count` fill inputs: the proxies, the packed
    // fill columns, the keys as the fill's first-copy output, and the warm order's capacity.
    fn beginStep(self: *CollisionSystem, input_count: usize) !void {
        // u32 slots and sources: the bounds rows are indexed by u32 entity rows.
        std.debug.assert(input_count <= std.math.maxInt(u32));
        const slot_capacity = hotStoreCapacity(input_count);
        try self.proxies.ensureTotalCapacity(self.allocator, slot_capacity);
        try self.fill_inputs.ensureTotalCapacity(self.allocator, slot_capacity);
        setRowCount(ProxyRow, &self.proxies, input_count);
        setRowCount(FillInput, &self.fill_inputs, input_count);
        try self.keys.ensureTotalCapacity(self.allocator, input_count);
        self.keys.items.len = input_count;
        try self.second_scratch.ensureTotalCapacity(self.allocator, input_count);
        self.second_scratch.items.len = input_count;
        try self.warm_sources.ensureTotalCapacity(self.allocator, input_count);
    }

    // A step with no fill input: no entries and no warm order.
    fn finishEmpty(self: *CollisionSystem) void {
        self.proxies.clearRetainingCapacity();
        self.fill_inputs.clearRetainingCapacity();
        self.keys.clearRetainingCapacity();
        self.entries.clearRetainingCapacity();
        self.warm_count = 0;
    }

    fn fillContext(self: *CollisionSystem, data: *const DataSystem, scope_dense_indices: ?[]const u32, strips: CollisionStrips, input_count: usize) FillContext {
        return .{
            .data = data,
            .bounds = data.collisionBoundsSliceConst(),
            .movement = data.movementBodySliceConst(),
            .tier = data.scopeColumnsSliceConst().tier,
            .levels = data.worldLevelSliceConst().levels,
            .scope = scope_dense_indices,
            .dynamic_ids = data.collision_bounds.dynamic_ids.items,
            .warm_sources = if (self.warm_count == input_count) self.warm_sources.items[0..input_count] else null,
            .strips = strips,
            .proxies = ProxyColumns.of(self.proxies.slice()),
            .inputs = FillColumns.of(self.fill_inputs.slice()),
        };
    }

    // The step's build: `collision_fill` over the slots into the bands of sampled
    // splitters, the band starts on the main thread, then `collision_sort` over the entries.
    // With no worker each of those stages runs inline. Returns whether more than one body
    // was filled.
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
        // Before `sizeEntries`: a failed ensure leaves the step's lengths unchanged.
        try self.merge_scratch.ensureTotalCapacity(self.allocator, entry_count);
        self.merge_scratch.items.len = entry_count;
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
                .scratch = self.merge_scratch.items,
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
    fn prepareNarrowphaseStaging(self: *CollisionSystem, candidate_pair_count: usize, range_count: usize, write_keys: bool) !void {
        try self.narrowphase_staging.ensureTotalCapacity(self.allocator, candidate_pair_count);
        self.narrowphase_staging.items.len = candidate_pair_count;
        if (write_keys) {
            try self.narrowphase_keys.ensureTotalCapacity(self.allocator, candidate_pair_count);
            self.narrowphase_keys.items.len = candidate_pair_count;
        }
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
    /// count. Dense/clustered scenes can exceed this; the broadphase grows the range slot
    /// and replays. Used to pre-size an empty per-range slot, including the one range a
    /// no-worker step sweeps, when `reserve` has not run (`reserve` sizes every slot to
    /// the unclamped `broadphasePairBound`).
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
    /// exceeds `reserved_pair_bound`, or `broadphase_grew` (a broadphase slot grew
    /// in-stage). Main thread, after the broadphase merge and before the narrowphase
    /// dispatch.
    fn countPairBoundOverflow(self: *CollisionSystem, stats: *CollisionStats, candidate_pair_count: usize, broadphase_grew: bool) void {
        if (self.reserved_pair_bound == 0) return;
        if (!broadphase_grew and candidate_pair_count <= self.reserved_pair_bound) return;
        self.notePairBoundOverflow(stats, candidate_pair_count);
    }

    // Flags the step and counts it once, however many grow paths it took.
    fn markPairBoundExceeded(self: *CollisionSystem, stats: *CollisionStats) void {
        if (comptime !runtime_perf_log.enabled) return;
        if (stats.perf.pair_bound_exceeded) return;
        stats.perf.pair_bound_exceeded = true;
        self.perf.pair_bound_overflows += 1;
    }

    fn notePairBoundOverflow(self: *CollisionSystem, stats: *CollisionStats, candidate_pair_count: usize) void {
        @branchHint(.cold);
        self.markPairBoundExceeded(stats);
        if (self.pair_bound_warned) return;
        self.pair_bound_warned = true;
        if (comptime logging.enabled(.warn)) logging.game.warn(
            "collision: {d} candidate pairs outgrew the reserved pair bound {d} (total or per range); collision stores or contact streams grew in-stage",
            .{ candidate_pair_count, self.reserved_pair_bound },
        );
    }

    // A reserved step whose static query slots grew and replayed. `growth` is the largest
    // need of any slot, so the log names the quantity that outgrew its rows.
    fn noteStaticSlotOverflow(self: *CollisionSystem, stats: *CollisionStats, growth: StaticSlotGrowth) void {
        @branchHint(.cold);
        if (self.reserved_pair_bound == 0) return;
        self.markPairBoundExceeded(stats);
        if (self.static_slot_warned) return;
        self.static_slot_warned = true;
        if (comptime logging.enabled(.warn)) logging.game.warn(
            "collision: static query slots grew in-stage: a range needed {d} pairs, one query {d} hit rows, a range {d} walked ids (0 = within its slot)",
            .{ growth.pairs, growth.hits, growth.ids },
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
            if (comptime runtime_perf_log.enabled) {
                for (self.broadphase_ranges.items[0..selection.range_count]) |*slot| {
                    result.perf.simd_groups += slot.buffer.perf.simd_groups;
                    result.perf.visits += slot.buffer.perf.visits;
                }
            }
            try self.mergeBroadphaseRangeBuffers(selection.range_count);
            return result;
        }
    }

    fn prepareStaticPairSlots(self: *CollisionSystem, range_count: usize) !void {
        try self.static_pair_slots.ensureTotalCapacity(self.allocator, range_count);
        while (self.static_pair_slots.items.len < range_count) self.static_pair_slots.appendAssumeCapacity(.{});
    }

    // Grows each slot the last pass outgrew, before its replay: hit rows, pairs, and Debug
    // ids geometrically past the slot's largest query, the range's pairs, and its walked ids.
    fn growStaticPairSlots(self: *CollisionSystem, range_count: usize) !StaticSlotGrowth {
        var growth = StaticSlotGrowth{};
        for (self.static_pair_slots.items[0..range_count]) |*slot| {
            if (slot.value.hits_required > slot.value.hits.len) {
                // std's growth past the need, so a query that widens a little does not
                // grow and replay again. `reserve` keeps its exact rows.
                try ensureHitRows(&slot.value.hits, self.allocator, std.MultiArrayList(HitRow).growCapacity(slot.value.hits_required));
                growth.hits = @max(growth.hits, slot.value.hits_required);
            }
            if (slot.value.required > slot.value.pairs.capacity) {
                try slot.value.pairs.ensureTotalCapacity(self.allocator, slot.value.required);
                growth.pairs = @max(growth.pairs, slot.value.required);
            }
            if (comptime builtin.mode == .debug) {
                if (slot.value.ids_required > slot.value.ids.capacity) {
                    // Geometric, not the exact id count: the next step's walk can read
                    // one more row without another allocation.
                    try slot.value.ids.ensureTotalCapacity(self.allocator, slot.value.ids_required);
                    growth.ids = @max(growth.ids, slot.value.ids_required);
                }
            }
        }
        return growth;
    }

    // The trigger store brought to `view` (the seam's retry) and refreshed to the allow
    // epoch, then one query over the filled dynamics. `static_pairs` is the dynamic x static
    // contacts. Returns the Debug out-of-band flag.
    fn gatherStaticPairs(self: *CollisionSystem, data: *const DataSystem, view: ColliderView, threads: Threads, exclude_tiers: bool, stats: *CollisionStats) !bool {
        self.static_pairs.clearRetainingCapacity();
        if (view.geometry == null) return false;
        try self.syncTriggers(data, view, threads);
        if (self.trigger_store.refresh(storeThreads(threads), data)) {
            if (comptime runtime_perf_log.enabled) stats.perf.trigger_refresh_batch = self.trigger_store.last_batches.get(.refresh);
        }
        const input_count = self.proxies.len;
        if (input_count != 0) {
            const stage = threads.stage(&self.static_pair_tuner);
            const selection = stage.select(input_count, collision_range_alignment_items);
            try self.prepareStaticPairSlots(selection.range_count);
            const slots = self.static_pair_slots.items[0..selection.range_count];
            var job = StaticQueryJob{
                .data = data,
                .view = view,
                .proxies = ConstProxyColumns.of(self.proxies.slice()),
                .strips = self.strips,
                .slots = slots,
                .exclude_tiers = exclude_tiers,
                .items_per_range = selection.items_per_range,
                .range_count = selection.range_count,
                .input_count = input_count,
            };
            var largest = StaticSlotGrowth{};
            var batch = BatchStats{};
            while (true) {
                for (slots) |*slot| slot.value.clear();
                // An overflowing range stops writing pairs at its first query that did
                // not fit. Record only the batch that wrote every pair, so a pass that
                // skipped the packing does not teach the tuner the query is cheaper.
                batch = threads.thread_system.parallelForWithOptions(input_count, &job, staticQueryJob, .{
                    .items_per_range = threads.config.items_per_range,
                    .max_worker_threads = threads.config.max_worker_threads,
                    .range_alignment_items = collision_range_alignment_items,
                    .adaptive = threads.config.adaptive,
                    .adaptive_tuner = null,
                    .selected_profile = selection.profile,
                });
                const growth = try self.growStaticPairSlots(selection.range_count);
                if (!growth.grew()) break;
                largest = largest.merge(growth);
            }
            if (selection.active_tuner) |tuner| tuner.record(batch);
            if (largest.grew()) self.noteStaticSlotOverflow(stats, largest);
            if (comptime runtime_perf_log.enabled) stats.perf.static_pairs_batch = batch;
            for (slots) |*slot| {
                try self.static_pairs.ensureTotalCapacity(self.allocator, self.static_pairs.items.len + slot.value.pairs.items.len);
                self.static_pairs.appendSliceAssumeCapacity(slot.value.pairs.items);
            }
            if (comptime builtin.mode == .debug) {
                try self.compactDistinctIds(view, slots);
                if (try self.dispatchRectCompare(data, view, threads, stats)) return true;
            }
        }
        return false;
    }

    /// Sizes the Debug rect stamp, the distinct-id list, and the compare scratch to the
    /// collider index space: O(index_count) in total, one stamp, id, and compare row per
    /// index and one flag per range any partition of them can produce. A walk reads only
    /// ids the view placed, each below its index count, and the stamp lists each once, so
    /// the distinct ids never outgrow `index_count`. The collider seam calls this after
    /// `row_of_index` grows, so the next detect does not allocate. Grow-only. ReleaseFast
    /// does not keep this state.
    pub fn reserveDebugRects(self: *CollisionSystem, index_count: usize) !void {
        if (comptime builtin.mode != .debug) return;
        if (index_count == 0) return;
        if (self.rect_stamp.items.len < index_count) {
            try self.rect_stamp.appendNTimes(self.allocator, 0, index_count - self.rect_stamp.items.len);
        }
        try self.distinct_ids.ensureTotalCapacity(self.allocator, index_count);
        try self.prepareRectCompare(index_count, maxRangeCount(index_count, collision_range_alignment_items));
    }

    // One integer stamp per recorded id, in range order. No DataSystem read.
    fn compactDistinctIds(self: *CollisionSystem, view: ColliderView, slots: []const PaddedSlot(StaticPairBuffer)) !void {
        const index_len = view.row_of_index.len;
        try self.reserveDebugRects(index_len);
        std.debug.assert(self.rect_stamp.items.len >= index_len and self.distinct_ids.capacity >= index_len);
        self.rect_generation +%= 1;
        if (self.rect_generation == 0) {
            @memset(self.rect_stamp.items, 0);
            self.rect_generation = 1;
        }
        self.distinct_ids.clearRetainingCapacity();
        const stamp = self.rect_stamp.items;
        const generation = self.rect_generation;
        for (slots) |slot| {
            for (slot.value.ids.items) |entity_index| {
                // The view places only indices below its index count.
                std.debug.assert(entity_index < index_len);
                if (stamp[entity_index] == generation) continue;
                stamp[entity_index] = generation;
                self.distinct_ids.appendAssumeCapacity(entity_index);
            }
        }
    }

    // One compare over the distinct ids. Below the tuner gate the same job runs inline.
    fn dispatchRectCompare(self: *CollisionSystem, data: *const DataSystem, view: ColliderView, threads: Threads, stats: *CollisionStats) !bool {
        const count = self.distinct_ids.items.len;
        if (count == 0) return false;
        const stage = threads.stage(&self.static_rect_tuner);
        const selection = stage.select(count, collision_range_alignment_items);
        try self.prepareRectCompare(count, selection.range_count);
        const flags = self.rect_moved.items[0..selection.range_count];
        for (flags) |*flag| flag.value = .{};
        var job = RectCompareJob{
            .data = data,
            .view = view,
            .movement = data.movement_bodies.sliceConst(),
            .bounds = data.collision_bounds.sliceConst(),
            .distinct = self.distinct_ids.items,
            .scratch = self.rect_scratch,
            .flags = flags,
            .items_per_range = selection.items_per_range,
            .range_count = selection.range_count,
        };
        const batch = stage.run(selection, count, collision_range_alignment_items, &job, compareStoredRects);
        if (comptime runtime_perf_log.enabled) stats.perf.static_rect_batch = batch;
        var moved = false;
        for (flags) |flag| moved = moved or flag.value.moved;
        return moved;
    }

    // Compare rows for `item_count` ids and flags for `range_count` ranges. Grow-only, so
    // after `reserveDebugRects` a compare over at most its index count does not allocate.
    fn prepareRectCompare(self: *CollisionSystem, item_count: usize, range_count: usize) !void {
        try self.rect_scratch.ensure(self.allocator, item_count);
        try self.rect_moved.ensureTotalCapacity(self.allocator, range_count);
        while (self.rect_moved.items.len < range_count) self.rect_moved.appendAssumeCapacity(.{});
    }

    // Brings the trigger store up to `view`: nothing at its revision, a patch for the next
    // revision with changes at the same strips, else a rebuild. A patch allocates only
    // before the store's first stored mutation, so its error keeps the stored pairs and
    // revision; a rebuild's error leaves the store empty and not ready, so the retry
    // rebuilds.
    fn syncTriggers(self: *CollisionSystem, data: *const DataSystem, view: ColliderView, threads: Threads) error{OutOfMemory}!void {
        const store = &self.trigger_store;
        const same = store.ready and self.trigger_strips.height == self.strips.height;
        if (same and view.revision == store.seen_revision) return;
        if (same and view.revision == store.seen_revision +% 1 and view.changes.len != 0) {
            try self.markChanges(view.changes);
            const range_count = try self.runTriggerQuery(data, view, threads, .patch);
            try store.patch(storeThreads(threads), self.triggerEditSources(range_count, .patch), view.revision);
            return;
        }
        const range_count = try self.runTriggerQuery(data, view, threads, .rebuild);
        try store.rebuild(storeThreads(threads), self.triggerEditSources(range_count, .rebuild), view.revision, data.collision_allow_epoch);
        self.trigger_strips = self.strips;
        self.releaseRebuildQuerySlots();
    }

    // A rebuild is a cold one-off over the row pool: frees what its query reserved past the
    // patch query's, so the slots follow changes, not rows. A patch reserves `insert_pages`
    // with `inserts` in every range it runs, so the slots patches used are the prefix
    // holding pages; the rest are the rebuild's alone. Cannot fail: a shrink that cannot
    // move keeps its capacity.
    fn releaseRebuildQuerySlots(self: *CollisionSystem) void {
        const slots = self.trigger_query_slots.items;
        var patch_slots: usize = 0;
        while (patch_slots < slots.len and slots[patch_slots].value.insert_pages.capacity != 0) patch_slots += 1;
        for (slots[0..patch_slots]) |*padded| {
            const slot = &padded.value;
            if (slot.inserts.capacity > slot.insert_pages.capacity) slot.inserts.clearAndFree(self.allocator);
        }
        for (slots[patch_slots..]) |*padded| padded.value.deinit(self.allocator);
        self.trigger_query_slots.shrinkAndFree(self.allocator, patch_slots);
        const sources = &self.trigger_edit_sources;
        sources.shrinkAndFree(self.allocator, @min(patch_slots, sources.items.len));
        sources.clearRetainingCapacity();
    }

    // The trigger query stage over the revision's changes or the row pool, under that mode's
    // tuner and into that mode's batch record; returns its range count. A range past its
    // slot grows it and the stage replays, and only the pass that wrote every record is
    // recorded.
    fn runTriggerQuery(self: *CollisionSystem, data: *const DataSystem, view: ColliderView, threads: Threads, mode: TriggerQueryMode) error{OutOfMemory}!usize {
        const record = switch (mode) {
            .patch => &self.trigger_query_batch,
            .rebuild => &self.trigger_rebuild_query_batch,
        };
        record.* = .{};
        const items = switch (mode) {
            .patch => view.changes.len,
            .rebuild => view.row_entity.len,
        };
        if (items == 0) return 0;
        const tuner = switch (mode) {
            .patch => &self.trigger_query_tuner,
            .rebuild => &self.trigger_query_rebuild_tuner,
        };
        const selection = threads.stage(tuner).select(items, collision_range_alignment_items);
        var grew = try self.prepareTriggerQuerySlots(selection, items, mode);
        const slots = self.trigger_query_slots.items[0..selection.range_count];
        var job = TriggerQueryJob{
            .data = data,
            .view = view,
            .store = &self.trigger_store,
            .strips = self.strips,
            .mode = mode,
            .change_mark = self.change_mark.items,
            .change_generation = self.change_generation,
            .slots = slots,
            .items_per_range = selection.items_per_range,
            .range_count = selection.range_count,
            .item_count = items,
        };
        var batch = BatchStats{};
        while (true) {
            for (slots) |*slot| slot.value.clear();
            batch = threads.thread_system.parallelForWithOptions(items, &job, triggerQueryJob, .{
                .items_per_range = threads.config.items_per_range,
                .max_worker_threads = threads.config.max_worker_threads,
                .range_alignment_items = collision_range_alignment_items,
                .adaptive = threads.config.adaptive,
                .adaptive_tuner = null,
                .selected_profile = selection.profile,
            });
            if (!try self.growTriggerQuerySlots(selection.range_count, mode)) break;
            grew = true;
        }
        if (selection.active_tuner) |active| active.record(batch);
        record.* = batch;
        if (grew) self.noteTriggerSlotGrowth();
        return selection.range_count;
    }

    // A trigger query whose range slots grew. `reserve` does not size these slots (a patch's
    // records follow its changes), so growth is their designed warm-up and logs at info, as
    // the spill slots do.
    fn noteTriggerSlotGrowth(self: *CollisionSystem) void {
        @branchHint(.cold);
        if (comptime runtime_perf_log.enabled) self.perf.trigger_slot_grows += 1;
        if (self.trigger_slot_growth_logged) return;
        self.trigger_slot_growth_logged = true;
        if (comptime logging.enabled(.info)) logging.game.info("collision trigger query slots grew", .{});
    }

    // Reserves every range's slot at the selection: `trigger_records_per_item` edit records
    // per item it covers and one query's hit rows. Grow-only; returns whether any list grew.
    fn prepareTriggerQuerySlots(self: *CollisionSystem, selection: BatchSelection, items: usize, mode: TriggerQueryMode) error{OutOfMemory}!bool {
        const range_count = selection.range_count;
        var grew = false;
        if (self.trigger_query_slots.capacity < range_count) {
            try self.trigger_query_slots.ensureTotalCapacity(self.allocator, range_count);
            grew = true;
        }
        while (self.trigger_query_slots.items.len < range_count) self.trigger_query_slots.appendAssumeCapacity(.{});
        for (self.trigger_query_slots.items[0..range_count], 0..) |*padded, range_index| {
            const slot = &padded.value;
            const records = trigger_records_per_item * rangeLenForIndex(items, selection.items_per_range, range_index);
            grew = try reserveRecords(InsertEdit, &slot.inserts, self.allocator, records) or grew;
            if (mode == .patch) {
                grew = try reserveRecords(PageLocation, &slot.insert_pages, self.allocator, records) or grew;
                grew = try reserveRecords(DropPiece, &slot.drops, self.allocator, records) or grew;
            }
            if (slot.hits.len < reserved_query_hits) {
                try ensureHitRows(&slot.hits, self.allocator, reserved_query_hits);
                grew = true;
            }
            grew = try reserveRecords(KeyedContact, &slot.contacts, self.allocator, slot.hits.len) or grew;
        }
        if (self.trigger_edit_sources.capacity < range_count) {
            try self.trigger_edit_sources.ensureTotalCapacity(self.allocator, range_count);
            grew = true;
        }
        return grew;
    }

    // Grows each slot the last pass outgrew, before its replay: hit rows geometrically past
    // its largest query (its contacts with them), and each record list past its need.
    fn growTriggerQuerySlots(self: *CollisionSystem, range_count: usize, mode: TriggerQueryMode) error{OutOfMemory}!bool {
        var grew = false;
        for (self.trigger_query_slots.items[0..range_count]) |*padded| {
            const slot = &padded.value;
            if (slot.hits_required > slot.hits.len) {
                try ensureHitRows(&slot.hits, self.allocator, std.MultiArrayList(HitRow).growCapacity(slot.hits_required));
                try slot.contacts.ensureTotalCapacity(self.allocator, slot.hits.len);
                grew = true;
            }
            grew = try reserveRecords(InsertEdit, &slot.inserts, self.allocator, slot.insert_need) or grew;
            if (mode == .patch) grew = try reserveRecords(PageLocation, &slot.insert_pages, self.allocator, slot.insert_need) or grew;
            grew = try reserveRecords(DropPiece, &slot.drops, self.allocator, slot.drop_need) or grew;
        }
        return grew;
    }

    // One edit source per query range, in range order, within reserved capacity.
    fn triggerEditSources(self: *CollisionSystem, range_count: usize, mode: TriggerQueryMode) []const EditSource {
        self.trigger_edit_sources.clearRetainingCapacity();
        for (self.trigger_query_slots.items[0..range_count]) |*padded| {
            const slot = &padded.value;
            std.debug.assert(!slot.overflowed);
            self.trigger_edit_sources.appendAssumeCapacity(.{
                .inserts = slot.inserts.items,
                .insert_pages = if (mode == .patch) slot.insert_pages.items else &.{},
                .drops = slot.drops.items,
            });
        }
        return self.trigger_edit_sources.items;
    }

    // Stamps every changed entity index with a fresh generation, growing the column to the
    // highest changed index. O(changes).
    fn markChanges(self: *CollisionSystem, changes: []const ColliderChange) error{OutOfMemory}!void {
        self.change_generation +%= 1;
        if (self.change_generation == 0) {
            @memset(self.change_mark.items, 0);
            self.change_generation = 1;
        }
        var max_index: usize = self.change_mark.items.len;
        for (changes) |change| max_index = @max(max_index, @as(usize, change.entity.index) + 1);
        if (self.change_mark.items.len < max_index) {
            try self.change_mark.ensureTotalCapacity(self.allocator, max_index);
            self.change_mark.appendNTimesAssumeCapacity(0, max_index - self.change_mark.items.len);
        }
        for (changes) |change| self.change_mark.items[change.entity.index] = self.change_generation;
    }

    // The static place, then the sort back into `static_pairs`, each under its own tuner.
    fn sortStaticPairs(self: *CollisionSystem, threads: Threads, stats: *CollisionStats) error{OutOfMemory}!void {
        const segments = [_][]const KeyedContact{self.static_pairs.items};
        const segment_starts = [_]usize{0};
        const batches = try PairSort.sortSegments(
            self.allocator,
            threads.stage(&self.static_place_tuner),
            threads.stage(&self.static_sort_tuner),
            &segments,
            &segment_starts,
            collision_range_alignment_items,
            &self.sort_staging,
            &self.sort_offsets,
            self.static_pairs.items,
        );
        if (comptime runtime_perf_log.enabled) {
            stats.perf.static_place_batch = batches.place;
            stats.perf.static_sort_batch = batches.sort;
        }
    }

    // The dynamic side of the emission in key order: the sorted static pairs alone, or the
    // narrowphase windows merged with them in `ordered`.
    fn mergeOrdered(self: *CollisionSystem, narrow_ran: bool, items_per_range: usize) ![]const KeyedContact {
        const dynamic_count = if (narrow_ran) try self.compactDynamicKeys(items_per_range) else 0;
        if (dynamic_count == 0) return self.static_pairs.items;
        const static_count = self.static_pairs.items.len;
        std.debug.assert(self.ordered.capacity >= dynamic_count + static_count);
        self.ordered.items.len = dynamic_count + static_count;
        mergeIntoSorted(KeyedContact, keyedGreater, self.ordered.items, dynamic_count, self.static_pairs.items);
        return self.ordered.items;
    }

    // Copies the narrowphase windows, keys included, to the front of `ordered`.
    fn compactDynamicKeys(self: *CollisionSystem, items_per_range: usize) !usize {
        const tallies = self.narrowphase_tallies.items;
        var count: usize = 0;
        for (tallies) |slot| count += slot.count;
        try self.ordered.ensureTotalCapacity(self.allocator, count + self.static_pairs.items.len);
        self.ordered.items.len = count;
        const staging = self.narrowphase_staging.items;
        const keys = self.narrowphase_keys.items;
        var cursor: usize = 0;
        for (tallies, 0..) |slot, range_index| {
            const window_start = range_index * items_per_range;
            const window = staging[window_start..][0..slot.count];
            for (window, 0..) |contact, offset| {
                self.ordered.items[cursor] = .{ .key = keys[window_start + offset], .contact = contact };
                cursor += 1;
            }
        }
        return count;
    }

    // Merges the first `stored` stored pairs with `dynamic` by key straight into the contact
    // stream's range windows, on workers. Each range finds its split by merge path; a count
    // pass at the write's selection sizes the windows when some stored pair is filtered.
    // Main work is O(ranges). Returns the contacts written.
    fn emitContacts(
        self: *CollisionSystem,
        contacts: *RangeOutputStream(CollisionContact),
        dynamic: []const KeyedContact,
        stored: u32,
        stored_emitted: u32,
        exclude: bool,
        threads: Threads,
        stats: *CollisionStats,
    ) !usize {
        const items = stored + dynamic.len;
        if (items == 0) {
            contacts.clearRetainingCapacity();
            return 0;
        }
        // Covers both grows below: the values are at most `items`, and the ranges at most
        // `maxRangeCount(items, collision_range_alignment_items)`.
        if (self.reserved_pair_bound != 0 and items > self.reserved_pair_bound +| self.reserved_trigger_bound) self.noteContactBoundOverflow(stats, items);
        const dispatch = threads.stage(&self.emit_tuner);
        const selection = dispatch.select(items, collision_range_alignment_items);
        const range_count = selection.range_count;
        try self.emit_ranges.ensureTotalCapacity(self.allocator, range_count);
        setSlotCount(EmitRange, &self.emit_ranges, range_count);
        const counted = stored_emitted < stored;
        var job = EmitJob{
            .store = &self.trigger_store,
            .dynamic = dynamic,
            .stored = stored,
            .exclude = exclude,
            .counted = counted,
            .ranges = self.emit_ranges.items,
            .contacts = contacts,
            .items_per_range = selection.items_per_range,
            .range_count = range_count,
            .item_count = items,
        };
        if (counted) {
            // Rides the write's selection unrecorded: its O(pages + ranges x page) is small
            // next to the write it sizes.
            const count_batch = threads.thread_system.parallelForWithOptions(items, &job, emitCountJob, .{
                .items_per_range = threads.config.items_per_range,
                .max_worker_threads = threads.config.max_worker_threads,
                .range_alignment_items = collision_range_alignment_items,
                .adaptive = threads.config.adaptive,
                .adaptive_tuner = null,
                .selected_profile = selection.profile,
            });
            if (comptime runtime_perf_log.enabled) stats.perf.trigger_emit_count_batch = count_batch;
        }
        try contacts.prepareRangeCounts(range_count);
        for (self.emit_ranges.items, 0..) |slot, range_index| {
            contacts.addCount(range_index, if (counted) slot.value.out else rangeLenForIndex(items, selection.items_per_range, range_index));
        }
        try contacts.prefix();
        const batch = dispatch.run(selection, items, collision_range_alignment_items, &job, emitWriteJob);
        if (comptime runtime_perf_log.enabled) stats.perf.trigger_emit_batch = batch;
        contacts.finishWrite();
        return stored_emitted + dynamic.len;
    }

    // A step whose stored and dynamic contacts outgrew the reserved contact bound: the
    // contact stream and the emission ranges grow on main.
    fn noteContactBoundOverflow(self: *CollisionSystem, stats: *CollisionStats, items: usize) void {
        @branchHint(.cold);
        self.markPairBoundExceeded(stats);
        if (self.contact_bound_warned) return;
        self.contact_bound_warned = true;
        if (comptime logging.enabled(.warn)) logging.game.warn(
            "collision: {d} stored trigger and dynamic contacts outgrew the reserved contact bound {d}; the contact stream grew in-stage",
            .{ items, self.reserved_pair_bound +| self.reserved_trigger_bound },
        );
    }
};

// The store's stage controls: the collision config's.
fn storeThreads(threads: Threads) StoreThreads {
    return .{ .thread_system = threads.thread_system, .config = .{
        .items_per_range = threads.config.items_per_range,
        .max_worker_threads = threads.config.max_worker_threads,
        .adaptive = threads.config.adaptive,
    } };
}

// Grows `list` to hold `count` records; true when it allocated.
fn reserveRecords(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, count: usize) error{OutOfMemory}!bool {
    if (list.capacity >= count) return false;
    try list.ensureTotalCapacity(allocator, count);
    return true;
}

// ---- Stored-trigger query (workers) -----------------------------------------------------

const TriggerQueryJob = struct {
    data: *const DataSystem,
    view: ColliderView,
    // Read only: no patch runs during the query.
    store: *const TriggerStore,
    strips: CollisionStrips,
    mode: TriggerQueryMode,
    change_mark: []const u32,
    change_generation: u32,
    slots: []PaddedSlot(TriggerQuerySlot),
    items_per_range: usize,
    range_count: usize,
    item_count: usize,

    fn changed(self: *const TriggerQueryJob, entity_index: u32) bool {
        return entity_index < self.change_mark.len and self.change_mark[entity_index] == self.change_generation;
    }
};

// A patch item drops its change's old pairs and queries its new row; a rebuild item queries
// its row when it is live and a trigger.
fn triggerQueryJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *TriggerQueryJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count and range.index < job.slots.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.item_count);
    const slot = &job.slots[range.index].value;
    const view = job.view;
    for (range.start..range.end) |item| switch (job.mode) {
        .patch => {
            const change = view.changes[item];
            const entity_index = change.entity.index;
            // A change whose level and box stay walks once: the old part's hits are the new
            // part's.
            var shared = false;
            if (change.new) |placement| {
                std.debug.assert(entity_index < view.row_of_index.len and view.row_of_index[entity_index] != no_static_row);
                if (change.old) |old| shared = old.level == placement.level and std.meta.eql(old.aabb, viewRowBox(view, view.row_of_index[entity_index]));
            }
            const shared_hits = if (change.old) |old| queryOldTriggerPairs(job, slot, old, entity_index, shared) else null;
            if (change.new) |placement| {
                // A shared walk that overflowed replays the range; the new part would too.
                if (shared and shared_hits == null) continue;
                queryNewTriggerPairs(job, slot, view.row_of_index[entity_index], placement.level, shared_hits);
            }
        },
        .rebuild => {
            // Rebuild items are row-pool ids, u32 by `ColliderView.row_of_index`.
            const row: u32 = @intCast(item);
            const entity = view.row_entity[row];
            if (entity.index >= view.row_of_index.len or view.row_of_index[entity.index] != row) continue;
            queryNewTriggerPairs(job, slot, row, job.data.worldLevelConst(entity) orelse 0, null);
        },
    };
}

// Inserts the stored pairs row `row` on `level` owns: each positive overlap with a partner
// that has a movement row, where either side is a trigger, unless the partner also queries
// and is the pair's a. Rows and emit bits are current now. `collected` is the count of hits
// already in the slot from a walk over this row's box and level, else null.
// SIMD verdict: the overlap and contact math is the `writeStaticHitContacts` lane kernel;
// the hit pack and the pair rule are scalar (pair-stream point lookups), and each kept
// pair drains into a tree descent, which is irreducible.
fn queryNewTriggerPairs(job: *const TriggerQueryJob, slot: *TriggerQuerySlot, row: u32, level: u16, collected: ?usize) void {
    const data = job.data;
    const view = job.view;
    const entity = view.row_entity[row];
    const response = data.collisionResponseConst(entity) orelse return;
    const own_trigger = response.mode == .trigger;
    if (job.mode == .rebuild and !own_trigger) return;
    const own_move = data.movementBodyDenseIndex(entity) orelse return;
    const box = viewRowBox(view, row);
    const hits = HitColumns.of(slot.hits.slice());
    const full = collected orelse view.collectOverlaps(level, box, hits.entity, hits.min_x, hits.min_y, hits.max_x, hits.max_y, idleSpanIds());
    if (full > slot.hits.len) {
        slot.noteHits(full);
        return;
    }
    const bodies = data.movement_bodies.sliceConst();
    const scope = data.movement_bodies.scopeSliceConst();
    packStaticHits(view, data, hits, full, entity, bodies, scope, false);
    slot.contacts.clearRetainingCapacity();
    std.debug.assert(slot.contacts.capacity >= full);
    // Movement rows are u32 throughout collision.
    writeStaticHitContacts(&slot.contacts, hits, full, entity, @intCast(own_move), box, bodies.velocity_x[own_move], bodies.velocity_y[own_move], level, job.strips);
    for (slot.contacts.items) |keyed| {
        const contact = keyed.contact;
        const partner_is_a = !contact.a.eql(entity);
        const partner = if (partner_is_a) contact.a else contact.b;
        const partner_response = data.collisionResponseConst(partner) orelse continue;
        const partner_trigger = partner_response.mode == .trigger;
        if (!own_trigger and !partner_trigger) continue;
        const partner_queries = switch (job.mode) {
            .patch => job.changed(partner.index),
            .rebuild => partner_trigger,
        };
        if (partner_queries and partner_is_a) continue;
        const edit = InsertEdit{
            .key = keyed.key,
            .contact = contact,
            .emit = collision_triggers.emitBits(scope.tier[contact.a_movement_index].allowsCollision(), scope.tier[contact.b_movement_index].allowsCollision()),
        };
        slot.pushInsert(edit, switch (job.mode) {
            .patch => job.store.locateKey(keyed.key).page,
            .rebuild => null,
        });
    }
}

fn viewRowBox(view: ColliderView, row: u32) math.Aabb {
    return .{ .min_x = view.row_min_x[row], .min_y = view.row_min_y[row], .max_x = view.row_max_x[row], .max_y = view.row_max_y[row] };
}

// Drops every stored pair entity index `entity_index` held at its old row: its a-pairs as
// one key range per occupied strip of its old box, and its b-pairs by exact key against
// each unchanged partner overlapping its old box. A changed partner drops their pair from
// its own a-range. With `share_hits`, the old box's hits stay in the slot for the new part
// and their count is returned; null otherwise or when the walk overflowed.
// SIMD verdict: scalar. Tree descents and page searches per strip and per hit; the
// per-hit overlap filter is a compaction feeding one tree descent per survivor, so lane
// masks would drain into per-item descents (pair-stream exemption).
fn queryOldTriggerPairs(job: *const TriggerQueryJob, slot: *TriggerQuerySlot, old: OldPlacement, entity_index: u32, share_hits: bool) ?usize {
    const store = job.store;
    if (store.pair_count == 0 and !share_hits) return null;
    const view = job.view;
    const box = old.aabb;
    const old_run = bodyRunKey(box.min_x, box.min_y, entity_index);
    if (store.pair_count != 0) {
        // A pair's key strip holds y in [box.min_y, box.max_y): the box's half-open strips.
        var strip = stripOf(job.strips, box.min_y);
        const last_strip = math.lastCellOfSpan(box.min_y, box.max_y, job.strips.height, strip_count);
        while (strip <= last_strip) : (strip += 1) {
            const bounds = keyRangeOfARun(old.level, strip, old_run);
            var cursor = store.seek(bounds[0]);
            if (!cursor.valid()) break;
            var keys = cursor.pageKeys();
            const first_key = keys[cursor.offset];
            if (collision_triggers.keyLevel(first_key) != old.level) break;
            // Jump to the next occupied strip, so the walk costs occupied strips, not the box.
            const first_strip = keyStrip(first_key);
            if (first_strip > strip) {
                if (first_strip > last_strip) break;
                strip = first_strip - 1;
                continue;
            }
            while (true) {
                const offset = cursor.offset;
                var end = offset;
                while (end < cursor.page_len and keys[end] <= bounds[1]) end += 1;
                if (end > offset) slot.pushDrop(cursor.dropPiece(offset, end));
                if (end == offset or end < cursor.page_len) break;
                cursor.nextPage();
                if (!cursor.valid()) break;
                keys = cursor.pageKeys();
            }
        }
    }
    const hits = HitColumns.of(slot.hits.slice());
    const full = view.collectOverlaps(old.level, box, hits.entity, hits.min_x, hits.min_y, hits.max_x, hits.max_y, idleSpanIds());
    if (full > slot.hits.len) {
        slot.noteHits(full);
        return null;
    }
    if (store.pair_count != 0) {
        for (0..full) |hit| {
            const partner = hits.entity[hit];
            if (partner == entity_index) continue;
            // A stored pair overlaps positively on both axes; a touching hit holds none.
            if (!(hits.min_x[hit] < box.max_x and box.min_x < hits.max_x[hit] and hits.min_y[hit] < box.max_y and box.min_y < hits.max_y[hit])) continue;
            if (job.changed(partner)) continue;
            const partner_run = bodyRunKey(hits.min_x[hit], hits.min_y[hit], partner);
            if (partner_run >= old_run) continue;
            const key = contactOrderKey(old.level, stripOf(job.strips, @max(hits.min_y[hit], box.min_y)), partner_run, old_run);
            if (store.storedPiece(key)) |piece| slot.pushDrop(piece);
        }
    }
    return if (share_hits) full else null;
}

fn stripOf(strips: CollisionStrips, y: f32) u32 {
    return math.worldPosToCell(y, strips.height, strip_count);
}

// ---- Stored-trigger emission (workers) --------------------------------------------------

const EmitJob = struct {
    // Read only: the emission runs after every refresh and patch.
    store: *const TriggerStore,
    dynamic: []const KeyedContact,
    stored: u32,
    exclude: bool,
    counted: bool,
    ranges: []PaddedSlot(EmitRange),
    contacts: *RangeOutputStream(CollisionContact),
    items_per_range: usize,
    range_count: usize,
    item_count: usize,

    fn assertRange(self: *const EmitJob, range: ParallelRange) void {
        std.debug.assert(range.index < self.range_count and range.index < self.ranges.len);
        std.debug.assert(range.start == range.index * self.items_per_range);
        std.debug.assert(range.start <= range.end and range.end <= self.item_count);
    }

    // The stored pairs among the first `position` merged positions: a binary search on the
    // merge path, comparing stored pair i with dynamic contact `position - i - 1`. Keys are
    // distinct across the streams (static-static against dynamic-involving pairs).
    // Hand-rolled: `std.sort.partitionPoint` needs a slice, and one side is a tree select.
    fn split(self: *const EmitJob, position: usize) u32 {
        var lo: usize = position -| self.dynamic.len;
        var hi: usize = @min(position, self.stored);
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const cursor = self.store.cursorAt(@intCast(mid));
            if (cursor.page().keys[cursor.offset] < self.dynamic[position - mid - 1].key) lo = mid + 1 else hi = mid;
        }
        return @intCast(lo);
    }

    fn rangeSplit(self: *const EmitJob, range: ParallelRange) EmitRange {
        const stored_start = self.split(range.start);
        const stored_end = self.split(range.end);
        return .{ .stored_start = stored_start, .stored_end = stored_end, .dynamic_start = range.start - stored_start, .dynamic_end = range.end - stored_end };
    }
};

// Sizes each range's window: its dynamic contacts plus its stored pairs that pass the
// filter, whole pages from their header sums.
// SIMD verdict: scalar. One header load per whole page and at most two partial pages of u8
// emit bytes; `simd.zig` has no u8 lanes.
fn emitCountJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *EmitJob = @ptrCast(@alignCast(context));
    job.assertRange(range);
    var bounds = job.rangeSplit(range);
    var stored: usize = 0;
    var at = bounds.stored_start;
    if (at < bounds.stored_end) {
        var cursor = job.store.cursorAt(at);
        while (true) {
            const page = cursor.page();
            const take: u32 = @min(cursor.page_len - cursor.offset, bounds.stored_end - at);
            if (cursor.offset == 0 and take == cursor.page_len) {
                stored += if (job.exclude) page.header.allowed else page.header.valid;
            } else {
                for (page.emit[cursor.offset..][0..take]) |emit| stored += @intFromBool(collision_triggers.emits(emit, job.exclude));
            }
            at += take;
            if (at == bounds.stored_end) break;
            cursor.nextPage();
        }
    }
    bounds.out = stored + (bounds.dynamic_end - bounds.dynamic_start);
    job.ranges[range.index].value = bounds;
}

// Merges the range's stored pairs and dynamic contacts by key into its window, the stored
// ones that pass the filter transposed from the page columns.
// SIMD verdict: scalar. A compare-driven merge with a byte filter, and a SoA-to-AoS
// transpose with usize widening.
fn emitWriteJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *EmitJob = @ptrCast(@alignCast(context));
    job.assertRange(range);
    const bounds = if (job.counted) job.ranges[range.index].value else job.rangeSplit(range);
    var writer = job.contacts.rangeWriter(range.index);
    var stored = bounds.stored_start;
    var dynamic = bounds.dynamic_start;
    var cursor: collision_triggers.Cursor = undefined;
    // The cursor's page view, built once per page: building it per pair is two pool slot
    // resolves and a column-pointer set per merged item.
    var page: collision_triggers.Page = undefined;
    if (stored < bounds.stored_end) {
        cursor = job.store.cursorAt(stored);
        page = cursor.page();
    }
    while (stored < bounds.stored_end or dynamic < bounds.dynamic_end) {
        const take_stored = stored < bounds.stored_end and
            (dynamic == bounds.dynamic_end or page.keys[cursor.offset] < job.dynamic[dynamic].key);
        if (!take_stored) {
            writer.write(job.dynamic[dynamic].contact);
            dynamic += 1;
            continue;
        }
        const slot = cursor.offset;
        if (collision_triggers.emits(page.emit[slot], job.exclude)) writer.write(page.contactAt(slot));
        stored += 1;
        if (stored < bounds.stored_end) {
            cursor.next();
            // `next` leaves offset 0 only when it stepped onto a new page.
            if (cursor.offset == 0) page = cursor.page();
        }
    }
    writer.finish();
}

// ---- Static pairs --------------------------------------------------------------------

const StaticQueryJob = struct {
    data: *const DataSystem,
    view: ColliderView,
    proxies: ConstProxyColumns,
    strips: CollisionStrips,
    slots: []PaddedSlot(StaticPairBuffer),
    exclude_tiers: bool,
    items_per_range: usize,
    range_count: usize,
    input_count: usize,
};

fn staticQueryJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *StaticQueryJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count and range.index < job.slots.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.input_count);
    const slot = &job.slots[range.index].value;
    const hits = HitColumns.of(slot.hits.slice());
    const bodies = job.data.movement_bodies.sliceConst();
    const scope = job.data.movement_bodies.scopeSliceConst();
    const proxies = job.proxies;
    var slot_index = range.start;
    while (slot_index < range.end) : (slot_index += 1) {
        const entity = proxies.entity[slot_index];
        if (!entity.isValid()) continue;
        if (job.exclude_tiers and proxies.allow[slot_index] == 0) continue;
        const box = math.Aabb{
            .min_x = proxies.min_x[slot_index],
            .min_y = proxies.min_y[slot_index],
            .max_x = proxies.max_x[slot_index],
            .max_y = proxies.max_y[slot_index],
        };
        // Debug: a range whose walks outgrow its id list keeps recording its need to the
        // end, so the replay after one grow holds it.
        const full = if (comptime builtin.mode == .debug) blk: {
            var span_ids = SpanIds{ .ids = &slot.ids, .required = &slot.ids_required };
            break :blk job.view.collectOverlaps(proxies.level[slot_index], box, hits.entity, hits.min_x, hits.min_y, hits.max_x, hits.max_y, &span_ids);
        } else job.view.collectOverlaps(proxies.level[slot_index], box, hits.entity, hits.min_x, hits.min_y, hits.max_x, hits.max_y, {});
        if (!slot.admit(full)) continue;
        packStaticHits(job.view, job.data, hits, full, entity, bodies, scope, job.exclude_tiers);
        writeStaticHitContacts(&slot.pairs, hits, full, entity, proxies.movement_index[slot_index], box, proxies.velocity_x[slot_index], proxies.velocity_y[slot_index], proxies.level[slot_index], job.strips);
    }
}

// Movement index, generation, allow, and velocity onto the hits just scanned.
// `allow` is 0 or 1. A rejected hit stores zeros; the kernel does not read it.
fn packStaticHits(
    view: ColliderView,
    data: *const DataSystem,
    hits: HitColumns,
    full: usize,
    dynamic: EntityId,
    bodies: ConstMovementBodySlice,
    scope: ConstScopeColumnsSlice,
    exclude_tiers: bool,
) void {
    for (0..full) |hit| {
        const entity_index = hits.entity[hit];
        const admitted = admit: {
            if (entity_index >= view.row_of_index.len) break :admit null;
            const row = view.row_of_index[entity_index];
            if (row == no_static_row or row >= view.row_entity.len) break :admit null;
            const other = view.row_entity[row];
            if (other.eql(dynamic)) break :admit null;
            const move = data.movementBodyDenseIndex(other) orelse break :admit null;
            if (exclude_tiers and !scope.tier[move].allowsCollision()) break :admit null;
            break :admit .{
                .movement_index = @as(u32, @intCast(move)),
                .generation = other.generation,
                .velocity_x = bodies.velocity_x[move],
                .velocity_y = bodies.velocity_y[move],
            };
        };
        if (admitted) |hit_pack| {
            hits.movement_index[hit] = hit_pack.movement_index;
            hits.generation[hit] = hit_pack.generation;
            hits.allow[hit] = 1;
            hits.velocity_x[hit] = hit_pack.velocity_x;
            hits.velocity_y[hit] = hit_pack.velocity_y;
        } else {
            hits.movement_index[hit] = 0;
            hits.generation[hit] = 0;
            hits.allow[hit] = 0;
            hits.velocity_x[hit] = 0;
            hits.velocity_y[hit] = 0;
        }
    }
}

// One group, including a 1–3 hit tail: prefix loads, then the same overlap lanes.
// A shared edge stays in the hit row and fails the positive-overlap mask.
fn writeStaticHitContacts(
    pairs: *std.ArrayList(KeyedContact),
    hits: HitColumns,
    full: usize,
    dynamic: EntityId,
    dynamic_move: u32,
    box: math.Aabb,
    dynamic_velocity_x: f32,
    dynamic_velocity_y: f32,
    level: u16,
    strips: CollisionStrips,
) void {
    const key_dynamic = bodyRunKey(box.min_x, box.min_y, dynamic.index);
    const dyn_min_x = simd.splatFloat4(box.min_x);
    const dyn_min_y = simd.splatFloat4(box.min_y);
    const dyn_max_x = simd.splatFloat4(box.max_x);
    const dyn_max_y = simd.splatFloat4(box.max_y);
    const dyn_vx = simd.splatFloat4(dynamic_velocity_x);
    const dyn_vy = simd.splatFloat4(dynamic_velocity_y);
    const zero = simd.splatFloat4(0);
    const one = simd.splatFloat4(1);
    const negative_one = simd.splatFloat4(-1);
    const half = simd.splatFloat4(0.5);
    const allow_one = simd.splatUint4(1);
    var index: usize = 0;
    while (index < full) {
        const group = @min(simd.lane_count, full - index);
        const hit_min_x = simd.loadFloat4Lanes(hits.min_x[index..], group);
        const hit_min_y = simd.loadFloat4Lanes(hits.min_y[index..], group);
        const hit_max_x = simd.loadFloat4Lanes(hits.max_x[index..], group);
        const hit_max_y = simd.loadFloat4Lanes(hits.max_y[index..], group);
        const hit_vx = simd.loadFloat4Lanes(hits.velocity_x[index..], group);
        const hit_vy = simd.loadFloat4Lanes(hits.velocity_y[index..], group);
        const entity = simd.loadUint4Lanes(hits.entity[index..], group);
        const movement = simd.loadUint4Lanes(hits.movement_index[index..], group);
        const generation = simd.loadUint4Lanes(hits.generation[index..], group);
        const allow = simd.loadUint4Lanes(hits.allow[index..], group);

        var key_static = [_]u128{ 0, 0, 0, 0 };
        var dynamic_is_a_lanes = [_]bool{ false, false, false, false };
        inline for (0..simd.lane_count) |lane| {
            if (lane < group and allow[lane] == 1) {
                key_static[lane] = bodyRunKey(hit_min_x[lane], hit_min_y[lane], entity[lane]);
                dynamic_is_a_lanes[lane] = key_dynamic <= key_static[lane];
            }
        }
        const dynamic_is_a = simd.Mask4{
            dynamic_is_a_lanes[0],
            dynamic_is_a_lanes[1],
            dynamic_is_a_lanes[2],
            dynamic_is_a_lanes[3],
        };
        const a_min_x = simd.selectFloat4(dynamic_is_a, dyn_min_x, hit_min_x);
        const b_min_x = simd.selectFloat4(dynamic_is_a, hit_min_x, dyn_min_x);
        const a_min_y = simd.selectFloat4(dynamic_is_a, dyn_min_y, hit_min_y);
        const b_min_y = simd.selectFloat4(dynamic_is_a, hit_min_y, dyn_min_y);
        const a_max_x = simd.selectFloat4(dynamic_is_a, dyn_max_x, hit_max_x);
        const b_max_x = simd.selectFloat4(dynamic_is_a, hit_max_x, dyn_max_x);
        const a_max_y = simd.selectFloat4(dynamic_is_a, dyn_max_y, hit_max_y);
        const b_max_y = simd.selectFloat4(dynamic_is_a, hit_max_y, dyn_max_y);
        const a_vx = simd.selectFloat4(dynamic_is_a, dyn_vx, hit_vx);
        const b_vx = simd.selectFloat4(dynamic_is_a, hit_vx, dyn_vx);
        const a_vy = simd.selectFloat4(dynamic_is_a, dyn_vy, hit_vy);
        const b_vy = simd.selectFloat4(dynamic_is_a, hit_vy, dyn_vy);

        const overlap_x = simd.minFloat4(simd.subFloat4(a_max_x, b_min_x), simd.subFloat4(b_max_x, a_min_x));
        const overlap_y = simd.minFloat4(simd.subFloat4(a_max_y, b_min_y), simd.subFloat4(b_max_y, a_min_y));
        const use_x_axis = simd.lessEqualFloat4(overlap_x, overlap_y);
        const a_center_x = simd.mulFloat4(simd.addFloat4(a_min_x, a_max_x), half);
        const b_center_x = simd.mulFloat4(simd.addFloat4(b_min_x, b_max_x), half);
        const a_center_y = simd.mulFloat4(simd.addFloat4(a_min_y, a_max_y), half);
        const b_center_y = simd.mulFloat4(simd.addFloat4(b_min_y, b_max_y), half);
        const normal_x = simd.selectFloat4(use_x_axis, simd.selectFloat4(simd.lessEqualFloat4(a_center_x, b_center_x), negative_one, one), zero);
        const normal_y = simd.selectFloat4(use_x_axis, zero, simd.selectFloat4(simd.lessEqualFloat4(a_center_y, b_center_y), negative_one, one));
        const penetration = simd.selectFloat4(use_x_axis, overlap_x, overlap_y);
        const speed_a_sq = simd.addFloat4(simd.mulFloat4(a_vx, a_vx), simd.mulFloat4(a_vy, a_vy));
        const speed_b_sq = simd.addFloat4(simd.mulFloat4(b_vx, b_vx), simd.mulFloat4(b_vy, b_vy));
        const rel_x = simd.subFloat4(a_vx, b_vx);
        const rel_y = simd.subFloat4(a_vy, b_vy);
        const max_speed_sq = simd.maxFloat4(speed_a_sq, speed_b_sq);
        const rel_speed_sq = simd.addFloat4(simd.mulFloat4(rel_x, rel_x), simd.mulFloat4(rel_y, rel_y));
        const emit = simd.maskBits(simd.greaterThanFloat4(overlap_x, zero) & simd.greaterThanFloat4(overlap_y, zero) & simd.equalUint4(allow, allow_one)) & simd.lanesBelow(group);

        inline for (0..simd.lane_count) |lane| {
            if (emit & (1 << lane) != 0) {
                const static_entity = EntityId{ .index = entity[lane], .generation = generation[lane] };
                const dynamic_first = dynamic_is_a_lanes[lane];
                const a_entity = if (dynamic_first) dynamic else static_entity;
                const b_entity = if (dynamic_first) static_entity else dynamic;
                const a_move = if (dynamic_first) dynamic_move else movement[lane];
                const b_move = if (dynamic_first) movement[lane] else dynamic_move;
                const strip = math.worldPosToCell(@max(a_min_y[lane], b_min_y[lane]), strips.height, strip_count);
                const key_a = if (dynamic_first) key_dynamic else key_static[lane];
                const key_b = if (dynamic_first) key_static[lane] else key_dynamic;
                pairs.appendAssumeCapacity(.{
                    .key = contactOrderKey(level, strip, key_a, key_b),
                    .contact = .{
                        .a = a_entity,
                        .b = b_entity,
                        .a_movement_index = a_move,
                        .b_movement_index = b_move,
                        .normal_x = normal_x[lane],
                        .normal_y = normal_y[lane],
                        .penetration = penetration[lane],
                        .pre_response_max_speed_sq = max_speed_sq[lane],
                        .pre_response_relative_speed_sq = rel_speed_sq[lane],
                    },
                });
            }
        }
        index += group;
    }
}

// The stored-rect compare's columns, one row per distinct id. Range r writes only its own
// `[range.start, range.end)` window. The block is 64-byte aligned and each column's length
// is a whole number of `collision_range_alignment_items` rows (64 bytes), so every window
// starts on a cache line and two ranges never share one. Not a row pool.
const RectScratch = struct {
    block: []align(64) u8 = &.{},
    stored_min_x: []f32 = &.{},
    stored_min_y: []f32 = &.{},
    stored_max_x: []f32 = &.{},
    stored_max_y: []f32 = &.{},
    live_min_x: []f32 = &.{},
    live_min_y: []f32 = &.{},
    live_max_x: []f32 = &.{},
    live_max_y: []f32 = &.{},
    bad: []u32 = &.{},

    fn ensure(self: *RectScratch, allocator: std.mem.Allocator, n: usize) !void {
        if (self.stored_min_x.len >= n) return;
        const stride = hotStoreCapacity(n);
        const float_bytes = 8 * stride * @sizeOf(f32);
        const bad_bytes = stride * @sizeOf(u32);
        const block = try allocator.alignedAlloc(u8, .@"64", float_bytes + bad_bytes);
        errdefer allocator.free(block);
        const floats = std.mem.bytesAsSlice(f32, block[0..float_bytes]);
        // `float_bytes` is a multiple of 64 and `block` is align(64), so the tail is too.
        const bad_tail: []align(4) u8 = @alignCast(block[float_bytes..]);
        const bad = std.mem.bytesAsSlice(u32, bad_tail);
        if (self.block.len != 0) allocator.free(self.block);
        self.block = block;
        self.stored_min_x = floats[0 * stride ..][0..stride];
        self.stored_min_y = floats[1 * stride ..][0..stride];
        self.stored_max_x = floats[2 * stride ..][0..stride];
        self.stored_max_y = floats[3 * stride ..][0..stride];
        self.live_min_x = floats[4 * stride ..][0..stride];
        self.live_min_y = floats[5 * stride ..][0..stride];
        self.live_max_x = floats[6 * stride ..][0..stride];
        self.live_max_y = floats[7 * stride ..][0..stride];
        self.bad = bad[0..stride];
    }

    fn deinit(self: *RectScratch, allocator: std.mem.Allocator) void {
        if (self.block.len != 0) allocator.free(self.block);
        self.* = .{};
    }
};

// One range's compare result, written once by the range's job.
const RectMoved = struct {
    moved: bool = false,
};

const RectCompareJob = struct {
    data: *const DataSystem,
    view: ColliderView,
    movement: ConstMovementBodySlice,
    bounds: ConstCollisionBoundsSlice,
    distinct: []const u32,
    scratch: RectScratch,
    flags: []PaddedSlot(RectMoved),
    items_per_range: usize,
    range_count: usize,
};

fn compareStoredRects(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *RectCompareJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count and range.index < job.flags.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.distinct.len);
    const scratch = &job.scratch;
    std.debug.assert(range.end <= scratch.stored_min_x.len and range.end <= scratch.bad.len);
    for (job.distinct[range.start..range.end], range.start..) |entity_index, at| {
        storeComparedRect(job.data, job.movement, job.bounds, job.view, entity_index, scratch, at);
    }
    const start = range.start;
    job.flags[range.index].value.moved = rectsMismatch(
        scratch.stored_min_x[start..],
        scratch.stored_min_y[start..],
        scratch.stored_max_x[start..],
        scratch.stored_max_y[start..],
        scratch.live_min_x[start..],
        scratch.live_min_y[start..],
        scratch.live_max_x[start..],
        scratch.live_max_y[start..],
        scratch.bad[start..],
        range.end - start,
    );
}

fn storeComparedRect(
    data: *const DataSystem,
    movement: ConstMovementBodySlice,
    bounds: ConstCollisionBoundsSlice,
    view: ColliderView,
    entity_index: u32,
    slot: *const RectScratch,
    at: usize,
) void {
    const indexed = entity_index < view.row_of_index.len and blk: {
        const row = view.row_of_index[entity_index];
        break :blk row != no_static_row and row < view.row_entity.len and row < view.row_min_x.len and row < view.row_min_y.len and row < view.row_max_x.len and row < view.row_max_y.len;
    };
    if (!indexed) {
        slot.stored_min_x[at] = 0;
        slot.stored_min_y[at] = 0;
        slot.stored_max_x[at] = 0;
        slot.stored_max_y[at] = 0;
        slot.live_min_x[at] = 0;
        slot.live_min_y[at] = 0;
        slot.live_max_x[at] = 0;
        slot.live_max_y[at] = 0;
        slot.bad[at] = 1;
        return;
    }
    const row = view.row_of_index[entity_index];
    slot.stored_min_x[at] = view.row_min_x[row];
    slot.stored_min_y[at] = view.row_min_y[row];
    slot.stored_max_x[at] = view.row_max_x[row];
    slot.stored_max_y[at] = view.row_max_y[row];
    const live = liveObstacleRect(data, movement, bounds, view.row_entity[row]);
    if (live) |rect| {
        slot.live_min_x[at] = rect.min_x;
        slot.live_min_y[at] = rect.min_y;
        slot.live_max_x[at] = rect.max_x;
        slot.live_max_y[at] = rect.max_y;
        slot.bad[at] = 0;
    } else {
        slot.live_min_x[at] = 0;
        slot.live_min_y[at] = 0;
        slot.live_max_x[at] = 0;
        slot.live_max_y[at] = 0;
        slot.bad[at] = 1;
    }
}

// One slot resolve, then the movement and bounds columns. Null when either component is absent.
fn liveObstacleRect(data: *const DataSystem, movement: ConstMovementBodySlice, bounds: ConstCollisionBoundsSlice, entity: EntityId) ?math.Aabb {
    const slot = data.resolveSlotConst(entity) orelse return null;
    const move = slot.movement_body_index orelse return null;
    const bounds_index = slot.collision_bounds_index orelse return null;
    if (move >= movement.position_x.len or bounds_index >= bounds.offset_x.len) return null;
    return math.aabbFromOffsetSize(
        .{ .x = movement.position_x[move], .y = movement.position_y[move] },
        .{ .x = bounds.offset_x[bounds_index], .y = bounds.offset_y[bounds_index] },
        .{ .x = bounds.size_x[bounds_index], .y = bounds.size_y[bounds_index] },
    );
}

fn loadCompareFloat(values: []const f32, group: usize) simd.Float4 {
    return if (group == simd.lane_count) simd.loadFloat4(values) else simd.loadFloat4Prefix(values, group);
}

fn loadCompareUint(values: []const u32, group: usize) simd.Uint4 {
    return if (group == simd.lane_count) simd.loadUint4(values) else simd.loadUint4Prefix(values, group);
}

// Lanes below `count` that are not four equal edges with `bad == 0`.
fn rectMismatchMask(
    stored_min_x: simd.Float4,
    stored_min_y: simd.Float4,
    stored_max_x: simd.Float4,
    stored_max_y: simd.Float4,
    live_min_x: simd.Float4,
    live_min_y: simd.Float4,
    live_max_x: simd.Float4,
    live_max_y: simd.Float4,
    bad: simd.Uint4,
    count: usize,
) simd.MaskBits {
    const same = simd.equalFloat4(stored_min_x, live_min_x) &
        simd.equalFloat4(stored_min_y, live_min_y) &
        simd.equalFloat4(stored_max_x, live_max_x) &
        simd.equalFloat4(stored_max_y, live_max_y) &
        simd.equalUint4(bad, simd.splatUint4(0));
    return simd.lanesBelow(count) & ~simd.maskBits(same);
}

fn rectsMismatch(
    stored_min_x: []const f32,
    stored_min_y: []const f32,
    stored_max_x: []const f32,
    stored_max_y: []const f32,
    live_min_x: []const f32,
    live_min_y: []const f32,
    live_max_x: []const f32,
    live_max_y: []const f32,
    bad: []const u32,
    count: usize,
) bool {
    var index: usize = 0;
    while (index < count) {
        const group = @min(simd.lane_count, count - index);
        const mask = rectMismatchMask(
            loadCompareFloat(stored_min_x[index..], group),
            loadCompareFloat(stored_min_y[index..], group),
            loadCompareFloat(stored_max_x[index..], group),
            loadCompareFloat(stored_max_y[index..], group),
            loadCompareFloat(live_min_x[index..], group),
            loadCompareFloat(live_min_y[index..], group),
            loadCompareFloat(live_max_x[index..], group),
            loadCompareFloat(live_max_y[index..], group),
            loadCompareUint(bad[index..], group),
            group,
        );
        if (mask != 0) return true;
        index += group;
    }
    return false;
}

const PairSort = banded_sort.BandedSort(KeyedContact, keyedKeyOf);

fn keyedKeyOf(item: KeyedContact) u256 {
    return item.key;
}

fn keyedGreater(a: KeyedContact, b: KeyedContact) bool {
    return a.key > b.key;
}

// The reference run key: ordered min_x, ordered min_y, entity. Level and the contact
// strip stay in the contact key's high word, not here.
fn bodyRunKey(min_x: f32, min_y: f32, entity_index: u32) u128 {
    return packKey(0, math.orderedBits(min_x), math.orderedBits(min_y), entity_index);
}

fn reducedRunKey(key: u128) u96 {
    return @truncate(key);
}

fn contactOrderKey(level: u16, strip: u32, key_a: u128, key_b: u128) u256 {
    // High word is the contact run. Each tail is the 96-bit reference run key, a then b.
    return (@as(u256, runOf(level, strip)) << contact_run_shift) | (@as(u256, reducedRunKey(key_a)) << 96) | reducedRunKey(key_b);
}

comptime {
    // One key layout: the store reads the level from the key collision builds.
    std.debug.assert(contact_run_shift >= 2 * 96);
    const top = std.math.maxInt(u128);
    std.debug.assert(collision_triggers.keyLevel(contactOrderKey(std.math.maxInt(u16), strip_count - 1, top, top)) == std.math.maxInt(u16));
    std.debug.assert(collision_triggers.keyLevel(contactOrderKey(0, strip_count - 1, top, top)) == 0);
}

// The strip of contact key `key`.
fn keyStrip(key: u256) u32 {
    return @as(u16, @truncate(key >> contact_run_shift));
}

// The keys of every pair on `strip` of `level` whose a has run key `a_run`, inclusive.
fn keyRangeOfARun(level: u16, strip: u32, a_run: u128) [2]u256 {
    return .{ contactOrderKey(level, strip, a_run, 0), contactOrderKey(level, strip, a_run, std.math.maxInt(u128)) };
}

fn contactKeyFromProxies(strips: CollisionStrips, proxies: ConstProxyColumns, a: usize, b: usize) u256 {
    const strip = math.worldPosToCell(@max(proxies.min_y[a], proxies.min_y[b]), strips.height, strip_count);
    return contactOrderKey(
        proxies.level[a],
        strip,
        bodyRunKey(proxies.min_x[a], proxies.min_y[a], proxies.entity[a].index),
        bodyRunKey(proxies.min_x[b], proxies.min_y[b], proxies.entity[b].index),
    );
}

// ---- Fill ---------------------------------------------------------------------------

// The fill's input count: the scoped bounds rows, or the dynamic bounds index.
fn fillInputCount(data: *const DataSystem, scope_dense_indices: ?[]const u32) usize {
    return if (scope_dense_indices) |indices| indices.len else data.collision_bounds.dynamic_ids.items.len;
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
    allow: u8,
};

// One slot's packed fill inputs. The fill job writes its range; `fillSlots` only loads
// these columns. `filled` is 0 or 1, and u32 so one fill range of the column is a cache line.
const FillInput = struct {
    x: f32,
    y: f32,
    offset_x: f32,
    offset_y: f32,
    size_x: f32,
    size_y: f32,
    level: u32,
    entity_index: u32,
    filled: u32,
};

comptime {
    std.debug.assert(collision_range_alignment_items * @sizeOf(f32) % hot_soa_column_alignment == 0);
    std.debug.assert(collision_range_alignment_items * @sizeOf(u32) % hot_soa_column_alignment == 0);
}

const FillColumns = struct {
    x: []f32,
    y: []f32,
    offset_x: []f32,
    offset_y: []f32,
    size_x: []f32,
    size_y: []f32,
    level: []u32,
    entity_index: []u32,
    filled: []u32,

    fn of(rows: std.MultiArrayList(FillInput).Slice) FillColumns {
        return .{
            .x = rows.items(.x),
            .y = rows.items(.y),
            .offset_x = rows.items(.offset_x),
            .offset_y = rows.items(.offset_y),
            .size_x = rows.items(.size_x),
            .size_y = rows.items(.size_y),
            .level = rows.items(.level),
            .entity_index = rows.items(.entity_index),
            .filled = rows.items(.filled),
        };
    }
};

const FillContext = struct {
    data: *const DataSystem,
    bounds: ConstCollisionBoundsSlice,
    movement: ConstMovementBodySlice,
    // The movement store's tier column, row for row with `movement`.
    tier: @FieldType(ConstScopeColumnsSlice, "tier"),
    // The world-level store's level column.
    levels: []const u16,
    scope: ?[]const u32,
    // Bounds indexes of the dynamic rows, used when `scope` is null.
    dynamic_ids: []const u32,
    // Slot p reads input `warm_sources[p]` when set, else input p.
    warm_sources: ?[]const u32,
    strips: CollisionStrips,
    // Identity columns for every slot in the range; min and max from the lane kernel.
    proxies: ProxyColumns,
    // Lane inputs for every slot in the range, packed before `fillSlots`.
    inputs: FillColumns,

    fn source(self: *const FillContext, slot: usize) u32 {
        // A slot is below the input count <= maxInt(u32).
        return if (self.warm_sources) |order| order[slot] else @intCast(slot);
    }

    // Scalar: one dense-index point lookup per input, with a skip. A missing world level is
    // the surface (0).
    fn resolve(self: *const FillContext, input: u32) ?ResolvedSlot {
        const row: usize = if (self.scope) |indices| indices[input] else self.dynamic_ids[input];
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
            .allow = @intFromBool(self.tier[body].allowsCollision()),
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

// The copies a fill range wrote to its slot windows.
const FillCounts = struct {
    firsts: usize = 0,
    seconds: usize = 0,
};

// One scalar pass over `[start, end)`: the warm-order input, then that input's bounds and
// movement row. Writes the proxy identity columns and the packed lane inputs. An unresolved
// slot stores an invalid entity and zeros, so the lane kernel's min and max stay zero.
fn packFillRange(fill: *const FillContext, start: usize, end: usize) void {
    const proxies = fill.proxies;
    const inputs = fill.inputs;
    std.debug.assert(start <= end and end <= proxies.entity.len and end <= inputs.x.len);
    var slot = start;
    while (slot < end) : (slot += 1) {
        const input = fill.source(slot);
        proxies.source[slot] = input;
        if (fill.resolve(input)) |row| {
            inputs.x[slot] = row.x;
            inputs.y[slot] = row.y;
            inputs.offset_x[slot] = row.offset_x;
            inputs.offset_y[slot] = row.offset_y;
            inputs.size_x[slot] = row.size_x;
            inputs.size_y[slot] = row.size_y;
            inputs.level[slot] = row.level;
            inputs.entity_index[slot] = row.entity.index;
            inputs.filled[slot] = 1;
            proxies.entity[slot] = row.entity;
            proxies.movement_index[slot] = row.movement_index;
            proxies.level[slot] = row.level;
            proxies.velocity_x[slot] = row.velocity_x;
            proxies.velocity_y[slot] = row.velocity_y;
            proxies.allow[slot] = row.allow;
        } else {
            inputs.x[slot] = 0;
            inputs.y[slot] = 0;
            inputs.offset_x[slot] = 0;
            inputs.offset_y[slot] = 0;
            inputs.size_x[slot] = 0;
            inputs.size_y[slot] = 0;
            inputs.level[slot] = 0;
            inputs.entity_index[slot] = 0;
            inputs.filled[slot] = 0;
            proxies.entity[slot] = EntityId.invalid;
            proxies.movement_index[slot] = 0;
            proxies.level[slot] = 0;
            proxies.velocity_x[slot] = 0;
            proxies.velocity_y[slot] = 0;
            proxies.allow[slot] = 0;
        }
    }
}

// Writes each filled slot's first copy to `firsts` and its second-strip copy to `seconds`,
// both in slot order, and spills its copies in later strips to `spill`. Bounds, strips,
// ordered coordinates, and key words in lanes over the packed inputs, the last group one
// masked batch; copy compaction scalar (a data-dependent copy count).
fn fillSlots(fill: *const FillContext, start: usize, end: usize, firsts: []SortEntry, seconds: []SortEntry, spill: *SpillCopies) FillCounts {
    comptime std.debug.assert(entries_per_body == 2);
    const proxies = fill.proxies;
    const inputs = fill.inputs;
    std.debug.assert(start <= end and end <= proxies.entity.len and end <= inputs.x.len);
    std.debug.assert(firsts.len >= end - start and seconds.len >= end - start);
    const height = fill.strips.height;
    var counts = FillCounts{};
    var group = start;
    while (group < end) : (group += simd.lane_count) {
        const count = end - group;
        const x = simd.loadFloat4Lanes(inputs.x[group..], count);
        const y = simd.loadFloat4Lanes(inputs.y[group..], count);
        const offset_x = simd.loadFloat4Lanes(inputs.offset_x[group..], count);
        const offset_y = simd.loadFloat4Lanes(inputs.offset_y[group..], count);
        const size_x = simd.loadFloat4Lanes(inputs.size_x[group..], count);
        const size_y = simd.loadFloat4Lanes(inputs.size_y[group..], count);
        const level = simd.loadUint4Lanes(inputs.level[group..], count);
        const entity_index = simd.loadUint4Lanes(inputs.entity_index[group..], count);
        const filled_words = simd.loadUint4Lanes(inputs.filled[group..], count);
        var filled: simd.MaskBits = 0;
        inline for (0..simd.lane_count) |lane| {
            if (filled_words[lane] != 0) filled |= 1 << lane;
        }
        const min_x = x + offset_x;
        const min_y = y + offset_y;
        const max_x = min_x + size_x;
        const max_y = min_y + size_y;
        simd.storeFloat4Lanes(proxies.min_x[group..], min_x, count);
        simd.storeFloat4Lanes(proxies.min_y[group..], min_y, count);
        simd.storeFloat4Lanes(proxies.max_x[group..], max_x, count);
        simd.storeFloat4Lanes(proxies.max_y[group..], max_y, count);
        // Clamped strips are in [0, strip_count - 1], so non-negative.
        const first_strip: simd.Uint4 = @bitCast(simd.worldPosToCell4(min_y, height, strip_count));
        const last_strip: simd.Uint4 = @bitCast(simd.lastCellOfSpan4(min_y, max_y, height, strip_count));
        const ordered_x = simd.orderedBitsFloat4(min_x);
        const ordered_y = simd.orderedBitsFloat4(min_y);
        const level_words = simd.shiftLeftUint4(level, 16);
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
    std.debug.assert(range.end <= job.fill.inputs.x.len and range.end <= job.fill.proxies.entity.len);
    const spill = &job.spill_slots[range.index].value;
    const firsts = job.scratch[range.start..range.end];
    const seconds = job.second_scratch[range.start..range.end];
    packFillRange(&job.fill, range.start, range.end);
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
    var starts = BandStarts{ .entry_start = @splat(0), .first_start = @splat(0), .second_start = @splat(0) };
    for (first_offsets) |slot| {
        for (&starts.first_start, slot.value.offsets) |*start, offset| start.* += offset;
    }
    starts.entry_start = starts.first_start;
    for (second_offsets) |slot| {
        for (&starts.entry_start, slot.value.offsets) |*start, offset| start.* += offset;
    }
    // Seconds before each band, before the spill sum moves `entry_start`.
    for (&starts.second_start, starts.entry_start, starts.first_start) |*second, entry, first| {
        second.* = entry - first;
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
    // Indexed like the keys. The owner of a band writes only that band's slice.
    scratch: []SortEntry,
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
        const first_len = job.bands.first_start[band + 1] - job.bands.first_start[band];
        const second_len = job.bands.second_start[band + 1] - job.bands.second_start[band];
        const band_len = end - start;
        std.debug.assert(first_len + second_len <= band_len);
        const spill_len = band_len - first_len - second_len;
        std.debug.assert(first_len + second_len + spill_len == band_len);
        std.debug.assert(end <= job.scratch.len);
        job.writer.finishBand(start, end, job.bands.first_start[band], first_len, second_len, spill_len, job.scratch);
    }
}

// Writes one band's slice of the sorted keys, entries, and warm order.
const EntryWriter = struct {
    keys: []SortEntry,
    proxies: ConstProxyColumns,
    entries: EntryColumns,
    warm_sources: []u32,

    // Sorts the band's first, second, and spill runs, merges the second and spill tails
    // back from `scratch`, and writes the band. A warm first or second run is already
    // ordered, so those sorts are linear. Spill copies are emitted in slot order, so
    // that sort is not. The key is total, so the unstable sort matches the merge.
    fn finishBand(self: EntryWriter, start: u32, end: u32, first_rank: u32, first_len: u32, second_len: u32, spill_len: u32, scratch: []SortEntry) void {
        const first_end = start + first_len;
        const second_end = first_end + second_len;
        std.debug.assert(second_end + spill_len == end);
        pdqSort(SortEntry, self.keys[start..first_end], {}, entryLessThan);
        pdqSort(SortEntry, self.keys[first_end..second_end], {}, entryLessThan);
        pdqSort(SortEntry, self.keys[second_end..end], {}, entryLessThan);
        @memcpy(scratch[first_end..second_end], self.keys[first_end..second_end]);
        @memcpy(scratch[second_end..end], self.keys[second_end..end]);
        mergeIntoSorted(SortEntry, entryGreater, self.keys[start..second_end], first_len, scratch[first_end..second_end]);
        mergeIntoSorted(SortEntry, entryGreater, self.keys[start..end], second_end - start, scratch[second_end..end]);
        self.writeSorted(start, end, first_rank);
    }

    // Scalar: the slot read is the sort permutation, so the columns are not a dense run.
    // A first copy writes its fill input into the warm order in the same pass.
    fn writeSorted(self: EntryWriter, start: u32, end: u32, first_rank: u32) void {
        var rank = first_rank;
        for (self.keys[start..end], start..) |entry, index| {
            const slot: usize = entry.slot;
            self.entries.min_x[index] = self.proxies.min_x[slot];
            self.entries.min_y[index] = self.proxies.min_y[slot];
            self.entries.max_x[index] = self.proxies.max_x[slot];
            self.entries.max_y[index] = self.proxies.max_y[slot];
            self.entries.run[index] = keyRun(entry.key);
            self.entries.first[index] = @intFromBool(entry.first);
            self.entries.slot[index] = entry.slot;
            if (!entry.first) continue;
            self.warm_sources[rank] = self.proxies.source[slot];
            rank += 1;
        }
    }
};

// Merges the sorted `tail` into `keys`, whose first `head_len` entries are sorted, from the
// back: one move per entry and no buffer. Hand-written: std has no merge of sorted runs.
// Scalar: a merge is one compare per entry.
fn entryGreater(a: SortEntry, b: SortEntry) bool {
    return a.key > b.key;
}

fn mergeIntoSorted(comptime T: type, comptime greater: fn (T, T) bool, keys: []T, head_len: usize, tail: []const T) void {
    std.debug.assert(keys.len == head_len + tail.len);
    var head = head_len;
    var rest = tail.len;
    var out = keys.len;
    while (rest > 0) {
        out -= 1;
        if (head > 0 and greater(keys[head - 1], tail[rest - 1])) {
            head -= 1;
            keys[out] = keys[head];
        } else {
            rest -= 1;
            keys[out] = tail[rest];
        }
    }
}

// ---- Broadphase -----------------------------------------------------------------------

// The sweep's lane groups (`CollisionStats.broadphase_simd_groups`) and visits
// (`CollisionStats.perf.broadphase_visits`), kept only with `runtime_perf_log.enabled`.
const SweepPerf = if (runtime_perf_log.enabled) struct { simd_groups: usize = 0, visits: usize = 0 } else struct {};

const BroadphaseBuildResult = struct {
    perf: SweepPerf = .{},
    batch: BatchStats = .{},
    /// A range slot allocated in-stage: an unreserved slot warmed, or a slot grew and the
    /// broadphase replayed.
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
                buffer.perf.simd_groups += 1;
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
    // Set when this step merges static pairs. Dynamic-only steps leave keys unwritten.
    write_keys: bool = false,
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
    writeNarrowphaseContactsSimd(job.system, range, job.write_keys);
}

/// Writes range `range`'s contacts into its own staging window
/// (`narrowphase_staging.items[range.start..range.end]`, at most one contact per
/// candidate pair) and its count into its tally. When `write_keys` is set, the
/// same slots of `narrowphase_keys` receive the proxy order key.
/// A group shorter than a lane repeats the last in-range pair index; the store
/// mask drops those lanes, so a gather never reads past `range.end`.
fn writeNarrowphaseContactsSimd(system: *CollisionSystem, range: ParallelRange, write_keys: bool) void {
    const proxies = ConstProxyColumns.of(system.proxies.slice());
    std.debug.assert(range.index < system.narrowphase_tallies.items.len);
    std.debug.assert(range.end <= system.narrowphase_staging.items.len);
    if (write_keys) std.debug.assert(range.end <= system.narrowphase_keys.items.len);
    const window = system.narrowphase_staging.items[range.start..range.end];
    var count: usize = 0;
    var index = range.start;
    const zero = simd.splatFloat4(0);
    const one = simd.splatFloat4(1);
    const negative_one = simd.splatFloat4(-1);

    while (index < range.end) {
        const group = @min(simd.lane_count, range.end - index);
        const active = simd.lanesBelow(group);
        var a_indices: [simd.lane_count]usize = undefined;
        var b_indices: [simd.lane_count]usize = undefined;
        inline for (0..simd.lane_count) |lane| {
            const offset = if (lane < group) lane else group - 1;
            const pair = system.candidate_pairs.items[index + offset];
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
        const a_vx = simd.gatherFloat4(proxies.velocity_x, a_indices);
        const a_vy = simd.gatherFloat4(proxies.velocity_y, a_indices);
        const b_vx = simd.gatherFloat4(proxies.velocity_x, b_indices);
        const b_vy = simd.gatherFloat4(proxies.velocity_y, b_indices);

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
        const speed_a_sq = simd.addFloat4(simd.mulFloat4(a_vx, a_vx), simd.mulFloat4(a_vy, a_vy));
        const speed_b_sq = simd.addFloat4(simd.mulFloat4(b_vx, b_vx), simd.mulFloat4(b_vy, b_vy));
        const rel_x = simd.subFloat4(a_vx, b_vx);
        const rel_y = simd.subFloat4(a_vy, b_vy);
        const max_speed_sq = simd.maxFloat4(speed_a_sq, speed_b_sq);
        const rel_speed_sq = simd.addFloat4(simd.mulFloat4(rel_x, rel_x), simd.mulFloat4(rel_y, rel_y));

        const emit = simd.maskBits(valid) & active;
        inline for (0..simd.lane_count) |lane| {
            if (emit & (1 << lane) != 0) {
                const a = a_indices[lane];
                const b = b_indices[lane];
                if (write_keys) {
                    system.narrowphase_keys.items[range.start + count] = contactKeyFromProxies(system.strips, proxies, a, b);
                }
                window[count] = .{
                    .a = proxies.entity[a],
                    .b = proxies.entity[b],
                    .a_movement_index = proxies.movement_index[a],
                    .b_movement_index = proxies.movement_index[b],
                    .normal_x = normal_x[lane],
                    .normal_y = normal_y[lane],
                    .penetration = penetration[lane],
                    .pre_response_max_speed_sq = max_speed_sq[lane],
                    .pre_response_relative_speed_sq = rel_speed_sq[lane],
                };
                count += 1;
            }
        }
        index += group;
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
    return contactForAabbs(
        proxies.entity[a],
        proxies.entity[b],
        proxies.movement_index[a],
        proxies.movement_index[b],
        .{ .min_x = proxies.min_x[a], .min_y = proxies.min_y[a], .max_x = proxies.max_x[a], .max_y = proxies.max_y[a] },
        .{ .min_x = proxies.min_x[b], .min_y = proxies.min_y[b], .max_x = proxies.max_x[b], .max_y = proxies.max_y[b] },
        proxies.velocity_x[a],
        proxies.velocity_y[a],
        proxies.velocity_x[b],
        proxies.velocity_y[b],
    );
}

fn contactForAabbs(
    a: EntityId,
    b: EntityId,
    a_move: u32,
    b_move: u32,
    a_box: math.Aabb,
    b_box: math.Aabb,
    a_vx: f32,
    a_vy: f32,
    b_vx: f32,
    b_vy: f32,
) CollisionContact {
    const overlap_x = @min(a_box.max_x - b_box.min_x, b_box.max_x - a_box.min_x);
    const overlap_y = @min(a_box.max_y - b_box.min_y, b_box.max_y - a_box.min_y);
    var normal_x: f32 = 0;
    var normal_y: f32 = 0;
    var penetration = overlap_x;
    if (overlap_x <= overlap_y) {
        const center_a = (a_box.min_x + a_box.max_x) * 0.5;
        const center_b = (b_box.min_x + b_box.max_x) * 0.5;
        normal_x = if (center_a <= center_b) -1 else 1;
    } else {
        const center_a = (a_box.min_y + a_box.max_y) * 0.5;
        const center_b = (b_box.min_y + b_box.max_y) * 0.5;
        normal_y = if (center_a <= center_b) -1 else 1;
        penetration = overlap_y;
    }
    return contactFields(a, b, a_move, b_move, a_vx, a_vy, b_vx, b_vy, normal_x, normal_y, penetration);
}

fn contactFields(
    a: EntityId,
    b: EntityId,
    a_move: u32,
    b_move: u32,
    a_vx: f32,
    a_vy: f32,
    b_vx: f32,
    b_vy: f32,
    normal_x: f32,
    normal_y: f32,
    penetration: f32,
) CollisionContact {
    const speed_a_sq = a_vx * a_vx + a_vy * a_vy;
    const speed_b_sq = b_vx * b_vx + b_vy * b_vy;
    const rel_x = a_vx - b_vx;
    const rel_y = a_vy - b_vy;
    return .{
        .a = a,
        .b = b,
        .a_movement_index = a_move,
        .b_movement_index = b_move,
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

// The production fill and sort over every bounds row at the default strips, inline on a
// thread system with no workers. Callers inject candidate pairs, so a full `update` would
// sweep first.
fn buildBandedInline(system: *CollisionSystem, data: *const DataSystem) !CollisionStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var stats = CollisionStats{};
    _ = try system.buildBanded(data, null, .default, .{ .thread_system = &threads, .config = .{} }, &stats);
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
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
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
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillReferenceLayout(&data);
    const expected = try referenceContacts(std.testing.allocator, &data, .default);
    defer std.testing.allocator.free(expected);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = collision_range_alignment_items });
    defer threads.deinit();
    for ([_]usize{ 16, 32, 48, 128 }) |items_per_range| for ([_]usize{ 1, 2, 4 }) |workers| {
        var system = CollisionSystem.init(std.testing.allocator);
        defer system.deinit();
        var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
        defer contacts.deinit();
        _ = try system.update(&data, &contacts, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = workers, .adaptive = false });
        try expectSameContacts(expected, contacts.mergedItems());
    };

    // One sort range with workers present: the banded path run inline.
    var inline_system = CollisionSystem.init(std.testing.allocator);
    defer inline_system.deinit();
    var inline_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer inline_contacts.deinit();
    const inline_stats = try inline_system.update(&data, &inline_contacts, &threads, .{
        .items_per_range = 4096,
        .max_worker_threads = 1,
        .adaptive = false,
    });
    try std.testing.expect(threads.workerThreadCount() > 0);
    try std.testing.expectEqual(@as(usize, 1), inline_stats.broadphase_batch.range_count);
    try std.testing.expect(inline_stats.broadphase_batch.ran_inline);
    // Workers are present, so the inline batch still reports them.
    try std.testing.expect(inline_stats.broadphase_batch.available_worker_threads != 0);
    try expectSameContacts(expected, inline_contacts.mergedItems());
}

test "fill, sort, broadphase, and narrowphase run on workers" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillReferenceLayout(&data);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
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
    const stats = try buildBandedInline(&system, &data);
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

fn expectSamePackedFill(serial: *const CollisionSystem, threaded: *const CollisionSystem) !void {
    try std.testing.expectEqual(serial.fill_inputs.len, threaded.fill_inputs.len);
    try std.testing.expectEqual(serial.proxies.len, threaded.proxies.len);
    const packed_serial = FillColumns.of(serial.fill_inputs.slice());
    const packed_threaded = FillColumns.of(threaded.fill_inputs.slice());
    const proxies_serial = ConstProxyColumns.of(serial.proxies.slice());
    const proxies_threaded = ConstProxyColumns.of(threaded.proxies.slice());
    for (0..packed_serial.x.len) |slot| {
        try std.testing.expectEqual(packed_serial.x[slot], packed_threaded.x[slot]);
        try std.testing.expectEqual(packed_serial.y[slot], packed_threaded.y[slot]);
        try std.testing.expectEqual(packed_serial.offset_x[slot], packed_threaded.offset_x[slot]);
        try std.testing.expectEqual(packed_serial.offset_y[slot], packed_threaded.offset_y[slot]);
        try std.testing.expectEqual(packed_serial.size_x[slot], packed_threaded.size_x[slot]);
        try std.testing.expectEqual(packed_serial.size_y[slot], packed_threaded.size_y[slot]);
        try std.testing.expectEqual(packed_serial.level[slot], packed_threaded.level[slot]);
        try std.testing.expectEqual(packed_serial.entity_index[slot], packed_threaded.entity_index[slot]);
        try std.testing.expectEqual(packed_serial.filled[slot], packed_threaded.filled[slot]);
        try std.testing.expect(proxies_serial.entity[slot].eql(proxies_threaded.entity[slot]));
        try std.testing.expectEqual(proxies_serial.movement_index[slot], proxies_threaded.movement_index[slot]);
        try std.testing.expectEqual(proxies_serial.min_x[slot], proxies_threaded.min_x[slot]);
        try std.testing.expectEqual(proxies_serial.min_y[slot], proxies_threaded.min_y[slot]);
        try std.testing.expectEqual(proxies_serial.max_x[slot], proxies_threaded.max_x[slot]);
        try std.testing.expectEqual(proxies_serial.max_y[slot], proxies_threaded.max_y[slot]);
        try std.testing.expectEqual(proxies_serial.velocity_x[slot], proxies_threaded.velocity_x[slot]);
        try std.testing.expectEqual(proxies_serial.velocity_y[slot], proxies_threaded.velocity_y[slot]);
        try std.testing.expectEqual(proxies_serial.level[slot], proxies_threaded.level[slot]);
        try std.testing.expectEqual(proxies_serial.source[slot], proxies_threaded.source[slot]);
    }
}

fn expectUnresolvedFillSlot(columns: FillColumns, proxies: ConstProxyColumns, slot: usize) !void {
    try std.testing.expectEqual(@as(f32, 0), columns.x[slot]);
    try std.testing.expectEqual(@as(f32, 0), columns.y[slot]);
    try std.testing.expectEqual(@as(f32, 0), columns.offset_x[slot]);
    try std.testing.expectEqual(@as(f32, 0), columns.offset_y[slot]);
    try std.testing.expectEqual(@as(f32, 0), columns.size_x[slot]);
    try std.testing.expectEqual(@as(f32, 0), columns.size_y[slot]);
    try std.testing.expectEqual(@as(u32, 0), columns.level[slot]);
    try std.testing.expectEqual(@as(u32, 0), columns.entity_index[slot]);
    try std.testing.expectEqual(@as(u32, 0), columns.filled[slot]);
    try std.testing.expect(proxies.entity[slot].eql(EntityId.invalid));
    try std.testing.expectEqual(@as(u32, 0), proxies.movement_index[slot]);
    try std.testing.expectEqual(@as(u16, 0), proxies.level[slot]);
    try std.testing.expectEqual(@as(f32, 0), proxies.velocity_x[slot]);
    try std.testing.expectEqual(@as(f32, 0), proxies.velocity_y[slot]);
    try std.testing.expectEqual(@as(f32, 0), proxies.min_x[slot]);
    try std.testing.expectEqual(@as(f32, 0), proxies.min_y[slot]);
    try std.testing.expectEqual(@as(f32, 0), proxies.max_x[slot]);
    try std.testing.expectEqual(@as(f32, 0), proxies.max_y[slot]);
}

test "collision warm fill reads packed columns not the stores" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Five bodies, not in sweep order: one full lane group and a masked tail.
    const xs = [_]f32{ 40, 0, 30, 10, 20 };
    var entities: [xs.len]EntityId = undefined;
    for (xs, &entities) |x, *entity| {
        entity.* = try addBox(&data, .{
            .x = x,
            .y = 4,
            .w = 6,
            .h = 6,
            .offset_x = 1,
            .offset_y = 2,
            .velocity_x = x,
            .velocity_y = 3,
            .level = 1,
        });
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try updateInline(&system, &data, &contacts);
    _ = try updateInline(&system, &data, &contacts);
    try std.testing.expectEqual(xs.len, system.warm_count);

    // Sweep order by min_x: inputs 1, 3, 4, 2, 0.
    const warm_inputs = [_]u32{ 1, 3, 4, 2, 0 };
    const columns = FillColumns.of(system.fill_inputs.slice());
    const proxies = ConstProxyColumns.of(system.proxies.slice());
    const bounds = data.collisionBoundsSliceConst();
    const movement = data.movementBodySliceConst();
    for (warm_inputs, 0..) |input, slot| {
        try std.testing.expectEqual(input, system.warm_sources.items[slot]);
        try std.testing.expectEqual(input, proxies.source[slot]);
        const bounds_row = data.collision_bounds.dynamic_ids.items[input];
        const entity = bounds.entities[bounds_row];
        try std.testing.expect(entity.eql(entities[input]));
        const body = data.movementBodyDenseIndex(entity).?;
        try std.testing.expectEqual(movement.position_x[body], columns.x[slot]);
        try std.testing.expectEqual(movement.position_y[body], columns.y[slot]);
        try std.testing.expectEqual(bounds.offset_x[bounds_row], columns.offset_x[slot]);
        try std.testing.expectEqual(bounds.offset_y[bounds_row], columns.offset_y[slot]);
        try std.testing.expectEqual(bounds.size_x[bounds_row], columns.size_x[slot]);
        try std.testing.expectEqual(bounds.size_y[bounds_row], columns.size_y[slot]);
        try std.testing.expectEqual(@as(u32, data.worldLevelConst(entity) orelse 0), columns.level[slot]);
        try std.testing.expectEqual(entity.index, columns.entity_index[slot]);
        try std.testing.expectEqual(@as(u32, 1), columns.filled[slot]);
        try std.testing.expect(proxies.entity[slot].eql(entity));
        try std.testing.expectEqual(@as(u32, @intCast(body)), proxies.movement_index[slot]);
        try std.testing.expectEqual(@as(u16, 1), proxies.level[slot]);
        try std.testing.expectEqual(movement.velocity_x[body], proxies.velocity_x[slot]);
        try std.testing.expectEqual(movement.velocity_y[body], proxies.velocity_y[slot]);
    }
    try std.testing.expect(columns.x[0] != xs[0]);

    // The lane kernel must keep the packed mins after the stores move.
    const moved = data.movementBodySlice();
    for (moved.position_x) |*x| x.* += 1000;
    try std.testing.expect(moved.position_x[data.movementBodyDenseIndex(entities[warm_inputs[0]]).?] != columns.x[0]);

    var firsts: [xs.len]SortEntry = undefined;
    var seconds: [xs.len]SortEntry = undefined;
    var spill = SpillCopies{};
    defer spill.deinit(std.testing.allocator);
    const fill = system.fillContext(&data, null, .default, xs.len);
    const counts = fillSlots(&fill, 0, xs.len, &firsts, &seconds, &spill);
    try std.testing.expectEqual(xs.len, counts.firsts);
    try std.testing.expectEqual(@as(usize, 0), counts.seconds);

    const proxies_after = ConstProxyColumns.of(system.proxies.slice());
    for (0..xs.len) |slot| {
        const min_x = columns.x[slot] + columns.offset_x[slot];
        const min_y = columns.y[slot] + columns.offset_y[slot];
        try std.testing.expectEqual(min_x, proxies_after.min_x[slot]);
        try std.testing.expectEqual(min_y, proxies_after.min_y[slot]);
        try std.testing.expectEqual(min_x + columns.size_x[slot], proxies_after.max_x[slot]);
        try std.testing.expectEqual(min_y + columns.size_y[slot], proxies_after.max_y[slot]);
        try std.testing.expectEqual(math.orderedBits(min_x), @as(u32, @truncate(firsts[slot].key >> 64)));
        try std.testing.expectEqual(math.orderedBits(min_y), @as(u32, @truncate(firsts[slot].key >> 32)));
        try std.testing.expectEqual(columns.entity_index[slot], @as(u32, @truncate(firsts[slot].key)));
        try std.testing.expectEqual(@as(u32, 1), keyRun(firsts[slot].key) >> 16);
        try std.testing.expect(firsts[slot].first);
        try std.testing.expectEqual(@as(u32, @intCast(slot)), firsts[slot].slot);
    }
}

test "collision unresolved fill slots stay empty across threads" {
    const input_count = collision_range_alignment_items * 4 + 1;
    // Inside a full lane group, inside a later range, and the one-slot tail range.
    const bare_slots = [_]usize{ 1, 20, input_count - 1 };
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..input_count) |index| {
        const bare = index == bare_slots[0] or index == bare_slots[1] or index == bare_slots[2];
        if (bare) {
            const entity = try data.createEntity();
            try data.setCollisionBounds(entity, .{ .size = .{ .x = 4, .y = 4 } });
        } else {
            _ = try addBox(&data, .{ .x = @floatFromInt(index * 8), .y = 2, .w = 4, .h = 4, .velocity_x = 1.5, .velocity_y = -2 });
        }
    }

    var serial = CollisionSystem.init(std.testing.allocator);
    defer serial.deinit();
    var threaded = CollisionSystem.init(std.testing.allocator);
    defer threaded.deinit();
    var serial_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer serial_contacts.deinit();
    var threaded_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer threaded_contacts.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    const config: CollisionConfig = .{
        .items_per_range = collision_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    };

    const serial_stats = try updateInline(&serial, &data, &serial_contacts);
    const threaded_stats = try threaded.update(&data, &threaded_contacts, &threads, config);
    try std.testing.expectEqual(input_count - bare_slots.len, serial_stats.body_count);
    try std.testing.expectEqual(serial_stats.body_count, threaded_stats.body_count);
    try std.testing.expect(!threaded_stats.broadphase_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 0), serial.warm_count);
    try std.testing.expectEqual(@as(usize, 0), threaded.warm_count);
    try expectSameContacts(serial_contacts.mergedItems(), threaded_contacts.mergedItems());
    try expectSamePackedFill(&serial, &threaded);

    const movement = data.movementBodySlice();
    for (movement.position_x) |*position_x| position_x.* += 50;
    const serial_again = try updateInline(&serial, &data, &serial_contacts);
    const threaded_again = try threaded.update(&data, &threaded_contacts, &threads, config);
    try std.testing.expectEqual(serial_stats.body_count, serial_again.body_count);
    try std.testing.expectEqual(serial_again.body_count, threaded_again.body_count);
    try std.testing.expectEqual(serial_again.entry_count, threaded_again.entry_count);
    try std.testing.expect(!threaded_again.broadphase_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 0), serial.warm_count);
    try std.testing.expectEqual(@as(usize, 0), threaded.warm_count);
    try expectSameContacts(serial_contacts.mergedItems(), threaded_contacts.mergedItems());
    try expectSamePackedFill(&serial, &threaded);

    const columns = FillColumns.of(serial.fill_inputs.slice());
    const proxies = ConstProxyColumns.of(serial.proxies.slice());
    for (bare_slots) |slot| try expectUnresolvedFillSlot(columns, proxies, slot);
    for ([_]*const CollisionSystem{ &serial, &threaded }) |system| {
        for (system.keys.items[0..serial_again.entry_count]) |entry| {
            for (bare_slots) |bare| try std.testing.expect(entry.slot != bare);
        }
    }
    // Cold order: slot 0 is still input 0 after the move. Slot 21 is the live row after the bare at 20.
    try std.testing.expectEqual(@as(u32, 0), proxies.source[0]);
    try std.testing.expectEqual(@as(u32, 1), proxies.source[bare_slots[0]]);
    try std.testing.expectEqual(@as(f32, 50), columns.x[0]);
    try std.testing.expectEqual(@as(f32, 2), columns.y[0]);
    try std.testing.expectEqual(@as(u32, 1), columns.filled[0]);
    try std.testing.expectEqual(@as(f32, 50), proxies.min_x[0]);
    try std.testing.expectEqual(@as(f32, 2), proxies.min_y[0]);
    try std.testing.expectEqual(@as(f32, 54), proxies.max_x[0]);
    try std.testing.expectEqual(@as(f32, 6), proxies.max_y[0]);
    try std.testing.expectEqual(@as(f32, 1.5), proxies.velocity_x[0]);
    try std.testing.expectEqual(@as(f32, -2), proxies.velocity_y[0]);
    try std.testing.expect(proxies.entity[0].isValid());
    try std.testing.expectEqual(@as(f32, 21 * 8 + 50), columns.x[21]);
    try std.testing.expectEqual(@as(f32, 21 * 8 + 50), proxies.min_x[21]);
}

test "warm and cold steps write identical contacts" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try fillReferenceLayout(&data);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
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
    const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false });
    try std.testing.expectEqual(@as(usize, 96), stats.entry_count);
    try std.testing.expect(stats.entry_count <= system.reserved_entry_bound);
    try expectSameContacts(expected, contacts.mergedItems());
}

test "a serial fill past its spill slot replays to the reference contacts" {
    // Eight bodies over four strips each: two spilled copies apiece into an empty slot, so
    // the no-worker fill (one range) grows it and replays; a fill that kept the first
    // pass's copies would duplicate entries.
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
    _ = try system.update(&data, &contacts, &threads, .{ .items_per_range = collision_range_alignment_items, .max_worker_threads = 2, .adaptive = false, .strips = strips });
    try expectSameContacts(expected, contacts.mergedItems());
}

test "after a spill slot grows, later multi-worker steps allocate nothing" {
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
    try CollisionSystem.reserveContactStream(&contacts, CollisionSystem.estimateContactCapacity(body_count));
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
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
    try CollisionSystem.reserveContactStream(&contacts, CollisionSystem.estimateContactCapacity(body_count));
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
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

    // Cold, then warm.
    for (0..2) |_| {
        const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false });
        try std.testing.expect(stats.entry_count > body_count);
        for ([_]BatchStats{ stats.broadphase_batch, stats.narrowphase_batch }) |batch| {
            try std.testing.expect(!batch.ran_inline);
        }
        try expectSameContacts(expected, contacts.mergedItems());
    }
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

test "threaded collision matches serial contact order" {
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

test "threaded collision records one sample into each stage tuner" {
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

    const stats = try system.update(&data, &contacts, &threads, .{});
    try std.testing.expectEqual(@as(usize, 64), stats.broadphase_batch.item_count);
    try std.testing.expect(stats.narrowphase_batch.item_count > 0);
    for ([_]*const AdaptiveWorkTuner{ &system.fill_tuner, &system.sort_tuner, &system.broadphase_tuner, &system.narrowphase_tuner }) |tuner| {
        try std.testing.expectEqual(@as(usize, 1), tuner.sample_count);
        try std.testing.expect(tuner.last_request != null);
    }
}

test "threaded collision broadphase overflow-replay matches serial contacts" {
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
    _ = try buildBandedInline(&system, &data);
    try system.candidate_pairs.append(std.testing.allocator, .{ .a = 0, .b = 1 });
    try system.candidate_pairs.append(std.testing.allocator, .{ .a = 0, .b = 2 });
    try system.candidate_pairs.append(std.testing.allocator, .{ .a = 0, .b = 3 });
    try system.prepareNarrowphaseStaging(system.candidate_pairs.items.len, 2, false);

    writeNarrowphaseContactsSimd(&system, .{ .index = 0, .start = 0, .end = 2 }, false);
    writeNarrowphaseContactsSimd(&system, .{ .index = 1, .start = 2, .end = 3 }, false);

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
    try system.prepareNarrowphaseStaging(8, 2, false);

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
        @intFromPtr(system.merge_scratch.items.ptr),
        @intFromPtr(system.staging.items.ptr),
    }) |address| try std.testing.expectEqual(@as(usize, 0), address % thread_shared_record_alignment);
}

test "threaded broadphase prewarms empty range buffers before dispatch" {
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
    // The pipeline's path with no worker: `update` runs the banded stages inline.
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
    try CollisionSystem.reserveContactStream(&contacts, CollisionSystem.estimateContactCapacity(body_count));
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
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

    for ([_][2]usize{ .{ 48, 2 }, .{ 32, 3 } }) |partition| {
        const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = partition[0], .max_worker_threads = 2, .adaptive = false });
        try std.testing.expect(!stats.broadphase_batch.ran_inline);
        try std.testing.expectEqual(partition[1], stats.broadphase_batch.range_count);
        try expectSameContactPairs(reference_contacts.mergedItems(), contacts.mergedItems());
    }
    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
}

test "a broadphase slot replay within the total pair bound matches serial and then allocates nothing" {
    // 64 bodies at a 64-body reserve (256-pair bound, 128-entry bound), four broadphase
    // ranges of 16 entries: slot 2 holds 4 * ceil(128 / 3) = 172 pairs. Ranges 0 and 1 are
    // 32 isolated bodies; range 2 is 16 wide bodies that all overlap (120 pairs) and the four
    // narrow bodies of range 3 they cover in y (64 pairs): 184, past slot 2 but inside the
    // total bound. The slot grows and the broadphase replays, contacts identical to the
    // serial run. The grown slot then holds the cluster, so the next step allocates nothing.

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
    try CollisionSystem.reserveContactStream(&contacts, CollisionSystem.estimateContactCapacity(body_count));
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    const config: CollisionConfig = .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false };
    const replayed = try system.update(&data, &contacts, &threads, config);
    try std.testing.expect(!replayed.broadphase_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 4), replayed.broadphase_batch.range_count);
    try expectSameContacts(reference_contacts.mergedItems(), contacts.mergedItems());

    const allocator = system.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    defer system.allocator = allocator;
    _ = try system.update(&data, &contacts, &threads, config);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try expectSameContacts(reference_contacts.mergedItems(), contacts.mergedItems());
}

test "candidate pairs past the reserved pair bound match an unreserved run, even inside the physical slack" {
    // `reserve(4)` declares a 16-pair bound. 8 overlapping bodies make 28 pairs: inside
    // `candidate_pairs`' rounded-up capacity, past the bound. Each such step, through
    // `update` with no workers, matches an unreserved run (the grow paths are
    // deterministic). A reserve whose bound covers the scene then allocates nothing.
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
        try std.testing.expectEqual(@as(usize, 28), stats.candidate_pair_count);
        try expectSameContactPairs(expected, contacts.mergedItems());
    }

    try system.reserve(8);
    try std.testing.expectEqual(@as(usize, 32), system.reserved_pair_bound);
    const allocator = system.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    defer system.allocator = allocator;
    _ = try updateInline(&system, &data, &contacts);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try expectSameContactPairs(expected, contacts.mergedItems());
}

test "candidate pairs past the reserved pair bound match serial on every step of the multi-worker path" {
    // `reserve(32)` declares a 128-pair bound. 32 bodies each overlapping their next
    // five make 145 pairs, over broadphase ranges of 16: past the bound every step.
    // Contacts match the serial run both times.

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

    for (0..2) |_| {
        const stats = try system.update(&data, &contacts, &threads, .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false });
        try std.testing.expect(!stats.broadphase_batch.ran_inline);
        try std.testing.expect(!stats.narrowphase_batch.ran_inline);
        try expectSameContactPairs(reference_contacts.mergedItems(), contacts.mergedItems());
    }
}

test "a contact stream reserved for a body capacity holds the pair bound" {
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try CollisionSystem.reserveContactStream(&contacts, CollisionSystem.estimateContactCapacity(64));
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
    try std.testing.expectEqual(system.proxies.len, system.fill_inputs.len);
    try std.testing.expect(system.fill_inputs.capacity >= hotStoreCapacity(system.fill_inputs.len));
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
    // Overlaps, a shared-edge miss, and an axis tie. Nonzero velocities make the
    // speed squares part of the oracle. The counts below are every short-group length.
    _ = try addBox(&data, .{ .x = 0, .y = 0, .w = 10, .h = 10, .velocity_x = 4, .velocity_y = 0 }); // 0
    _ = try addBox(&data, .{ .x = 8, .y = 0, .w = 10, .h = 10, .velocity_x = -2, .velocity_y = 3 }); // 1: x-axis overlap with 0
    _ = try addBox(&data, .{ .x = 0, .y = 8, .w = 10, .h = 10, .velocity_x = 0, .velocity_y = 5 }); // 2: y-axis overlap with 0
    _ = try addBox(&data, .{ .x = 5, .y = 5, .w = 10, .h = 10, .velocity_x = 1, .velocity_y = 1 }); // 3: equal-ish x/y penetration with 0
    _ = try addBox(&data, .{ .x = 50, .y = 50, .w = 4, .h = 4, .velocity_x = 9, .velocity_y = -4 }); // 4: non-overlap vs others
    _ = try addBox(&data, .{ .x = 10, .y = 0, .w = 10, .h = 10, .velocity_x = 7, .velocity_y = 2 }); // 5: shared edge with 0, not a contact
    _ = try addBox(&data, .{ .x = 9, .y = 1, .w = 10, .h = 10, .velocity_x = -3, .velocity_y = -2 }); // 6: overlap with 0 and 1

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    // A cold fill puts bounds row k at slot k.
    _ = try buildBandedInline(&system, &data);
    const proxies = ConstProxyColumns.of(system.proxies.slice());

    const pairs = [_]CandidatePair{
        .{ .a = 0, .b = 1 },
        .{ .a = 0, .b = 2 },
        .{ .a = 0, .b = 3 },
        .{ .a = 0, .b = 4 },
        .{ .a = 0, .b = 5 },
        .{ .a = 0, .b = 6 },
        .{ .a = 1, .b = 6 },
        .{ .a = 1, .b = 4 },
        .{ .a = 2, .b = 3 },
        .{ .a = 3, .b = 6 },
    };
    try system.candidate_pairs.ensureTotalCapacity(std.testing.allocator, pairs.len);
    for (pairs) |pair| {
        system.candidate_pairs.appendAssumeCapacity(pair);
    }

    // One range per count. A count that is not a multiple of the lane width uses the
    // same kernel with a store mask; zero overlap, including a shared edge, is no contact.
    for ([_]usize{ 1, 2, 3, 4, 5, 6, pairs.len }) |count| {
        var expected: std.ArrayList(CollisionContact) = .empty;
        defer expected.deinit(std.testing.allocator);
        try expected.ensureTotalCapacity(std.testing.allocator, count);
        for (pairs[0..count]) |pair| {
            if (contactForCandidate(proxies, pair.a, pair.b)) |contact| {
                expected.appendAssumeCapacity(contact);
            }
        }

        try system.prepareNarrowphaseStaging(count, 1, false);
        writeNarrowphaseContactsSimd(&system, .{ .index = 0, .start = 0, .end = count }, false);

        var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
        defer contacts.deinit();
        const contact_count = try system.mergeNarrowphaseContacts(&contacts, count);

        try std.testing.expectEqual(expected.items.len, contact_count);
        try expectSameContacts(expected.items, contacts.mergedItems());
    }
}

test "merging sorted runs equals sorting their concatenation" {
    var prng = std.Random.DefaultPrng.init(0x6d_65_72_67);
    const random = prng.random();
    // Three runs, unique keys: the two merges `finishBand` makes, every entry field.
    for ([_][3]usize{
        .{ 0, 0, 0 },
        .{ 5, 0, 0 },
        .{ 0, 5, 0 },
        .{ 0, 0, 5 },
        .{ 1, 1, 1 },
        .{ 40, 13, 7 },
        .{ 7, 60, 3 },
        .{ 0, 4, 9 },
    }) |lengths| {
        const first_len = lengths[0];
        const second_len = lengths[1];
        const spill_len = lengths[2];
        const total = first_len + second_len + spill_len;
        var keys: [120]SortEntry = undefined;
        var scratch: [120]SortEntry = undefined;
        var order: [120]u128 = undefined;
        for (order[0..total], 0..) |*key, index| key.* = index;
        random.shuffle(u128, order[0..total]);
        for (keys[0..first_len], order[0..first_len]) |*entry, key| {
            entry.* = .{ .key = key, .slot = random.int(u32), .first = true };
        }
        for (keys[first_len..][0..second_len], order[first_len..][0..second_len]) |*entry, key| {
            entry.* = .{ .key = key, .slot = random.int(u32), .first = false };
        }
        for (keys[first_len + second_len ..][0..spill_len], order[first_len + second_len ..][0..spill_len]) |*entry, key| {
            entry.* = .{ .key = key, .slot = random.int(u32), .first = false };
        }
        pdqSort(SortEntry, keys[0..first_len], {}, entryLessThan);
        pdqSort(SortEntry, keys[first_len..][0..second_len], {}, entryLessThan);
        pdqSort(SortEntry, keys[first_len + second_len ..][0..spill_len], {}, entryLessThan);
        var expected: [120]SortEntry = undefined;
        @memcpy(expected[0..total], keys[0..total]);
        std.sort.pdq(SortEntry, expected[0..total], {}, entryLessThan);
        const second_end = first_len + second_len;
        @memcpy(scratch[first_len..second_end], keys[first_len..second_end]);
        @memcpy(scratch[second_end..total], keys[second_end..total]);
        mergeIntoSorted(SortEntry, entryGreater, keys[0..second_end], first_len, scratch[first_len..second_end]);
        mergeIntoSorted(SortEntry, entryGreater, keys[0..total], second_end, scratch[second_end..total]);
        for (expected[0..total], keys[0..total]) |want, got| try std.testing.expectEqual(want, got);
    }

    // Equal keys take the tail (`>`), so the tail entry is the later one.
    var tied = [_]SortEntry{
        .{ .key = 4, .slot = 1, .first = true },
        .{ .key = 4, .slot = 1, .first = true },
    };
    const tied_tail = [_]SortEntry{
        .{ .key = 4, .slot = 2, .first = false },
    };
    mergeIntoSorted(SortEntry, entryGreater, &tied, 1, &tied_tail);
    try std.testing.expectEqual(@as(u32, 1), tied[0].slot);
    try std.testing.expectEqual(@as(u32, 2), tied[1].slot);
    try std.testing.expect(tied[0].first);
    try std.testing.expect(!tied[1].first);
}

test "strips are the tile size rounded down to a power of two" {
    try std.testing.expectEqual(@as(f32, 32), CollisionStrips.ofTileSize(32).height);
    try std.testing.expectEqual(@as(f32, 16), CollisionStrips.ofTileSize(24).height);
    try std.testing.expectEqual(@as(f32, 0.5), CollisionStrips.ofTileSize(0.75).height);
    try std.testing.expectEqual(required_tile_size, CollisionStrips.default.height);
}

const StaticColliderSystem = @import("static_colliders.zig").StaticColliderSystem;
const ColliderGeometry = @import("static_colliders.zig").ColliderGeometry;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const StructuralCommand = @import("../data_system.zig").StructuralCommand;

fn testGeometry() ColliderGeometry {
    return ColliderGeometry.init(32, 64, 64, 4);
}

fn addObstacle(data: *DataSystem, box: TestBox, mobility: @import("../data_system.zig").CollisionResponseMobility, mode: @import("../data_system.zig").CollisionResponseMode) !EntityId {
    const entity = try addBox(data, box);
    try data.setCollisionResponse(entity, .{ .mobility = mobility, .mode = mode, .restitution = 0 });
    return entity;
}

fn isSolidStatic(data: *const DataSystem, id: EntityId) bool {
    if (!data.isStaticNavigationObstacle(id)) return false;
    const response = data.collisionResponseConst(id).?;
    return response.mode != .trigger;
}

fn filteredReference(data: *const DataSystem, strips: CollisionStrips) ![]CollisionContact {
    const all = try referenceContacts(std.testing.allocator, data, strips);
    defer std.testing.allocator.free(all);
    var kept: std.ArrayList(CollisionContact) = .empty;
    errdefer kept.deinit(std.testing.allocator);
    for (all) |contact| {
        if (isSolidStatic(data, contact.a) and isSolidStatic(data, contact.b)) continue;
        try kept.append(std.testing.allocator, contact);
    }
    return try kept.toOwnedSlice(std.testing.allocator);
}

fn updateView(system: *CollisionSystem, data: *const DataSystem, contacts: *RangeOutputStream(CollisionContact), view: ColliderView, workers: usize, items_per_range: ?usize) !CollisionStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers });
    defer threads.deinit();
    return system.update(data, contacts, &threads, .{
        .static_colliders = view,
        .max_worker_threads = workers,
        .items_per_range = items_per_range,
        .adaptive = false,
    });
}

fn expectDynamicIndex(data: *const DataSystem, want: []const u32) !void {
    const ids = data.collision_bounds.dynamic_ids.items;
    const pos = data.collision_bounds.dynamic_pos.items;
    try std.testing.expectEqual(data.collision_bounds.len(), pos.len);
    try std.testing.expectEqual(want.len, ids.len);
    for (want) |bounds_index| {
        try std.testing.expect(bounds_index < pos.len);
        const slot = pos[bounds_index];
        try std.testing.expect(slot != std.math.maxInt(u32));
        try std.testing.expectEqual(bounds_index, ids[slot]);
    }
    for (pos, 0..) |slot, bounds_index| {
        const listed = for (want) |want_index| {
            if (want_index == bounds_index) break true;
        } else false;
        if (!listed) try std.testing.expectEqual(std.math.maxInt(u32), slot);
    }
}

test "static split contacts match the filtered reference" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Solid wall, coarse class: larger than a 4-tile chunk.
    _ = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 300, .h = 300 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 20, .h = 20 }, .dynamic, .solid);
    // Trigger over a solid, and trigger over trigger. Two solids that overlap each
    // other produce no contact; the trigger pairs stay.
    const beside = try addObstacle(&data, .{ .x = 800, .y = 0, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 810, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 820, .y = 20, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 0, .y = 800, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 10, .y = 810, .w = 40, .h = 40 }, .static, .solid);
    // A shared edge is not a contact, for a dynamic or a trigger.
    _ = try addObstacle(&data, .{ .x = 200, .y = 800, .w = 32, .h = 32 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 232, .y = 804, .w = 16, .h = 16 }, .dynamic, .solid);
    _ = try addObstacle(&data, .{ .x = 400, .y = 800, .w = 32, .h = 32 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 432, .y = 800, .w = 32, .h = 32 }, .static, .solid);
    // mins in different strips: the lower strip has the larger min_x, so a/b follows x.
    _ = try addObstacle(&data, .{ .x = 600, .y = 840, .w = 20, .h = 20 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 610, .y = 820, .w = 20, .h = 30 }, .dynamic, .solid);
    // Cell and chunk boundary (128) straddled once.
    _ = try addObstacle(&data, .{ .x = 120, .y = 400, .w = 20, .h = 20 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 124, .y = 404, .w = 10, .h = 10 }, .dynamic, .solid);
    // Equal min_x, order follows min_y then entity index.
    _ = try addObstacle(&data, .{ .x = 500, .y = 100, .w = 16, .h = 16 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 500, .y = 108, .w = 16, .h = 16 }, .dynamic, .solid);
    // Negative mins clamp into cell 0; contact fields keep the real floats.
    _ = try addObstacle(&data, .{ .x = -20, .y = -20, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = -10, .y = -10, .w = 16, .h = 16 }, .dynamic, .solid);
    // Cross-level overlap is not a contact.
    const below = try addObstacle(&data, .{ .x = 1400, .y = 0, .w = 20, .h = 20, .level = 1 }, .static, .solid);
    _ = below;
    _ = try addObstacle(&data, .{ .x = 1402, .y = 2, .w = 20, .h = 20, .level = 0 }, .dynamic, .solid);
    // Two dynamics still overlap each other.
    _ = try addObstacle(&data, .{ .x = 1600, .y = 0, .w = 20, .h = 20 }, .dynamic, .solid);
    _ = try addObstacle(&data, .{ .x = 1610, .y = 4, .w = 20, .h = 20 }, .dynamic, .solid);
    // Enough dynamics that a 16-wide range alignment covers more than one range.
    for (0..24) |index| {
        _ = try addObstacle(&data, .{ .x = 2000 + @as(f32, @floatFromInt(index)) * 40, .y = 2000, .w = 8, .h = 8 }, .dynamic, .solid);
    }

    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    const expected = try filteredReference(&data, .default);
    defer std.testing.allocator.free(expected);
    try std.testing.expect(expected.len > 0);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const serial = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
    try expectSameContacts(expected, contacts.mergedItems());

    var threaded = CollisionSystem.init(std.testing.allocator);
    defer threaded.deinit();
    var threaded_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer threaded_contacts.deinit();
    // One item per range: the 24 spread dynamics alone span two aligned query ranges.
    const parallel = try updateView(&threaded, &data, &threaded_contacts, colliders.view(), 2, 1);
    try expectSameContacts(expected, threaded_contacts.mergedItems());
    try std.testing.expectEqual(serial.contact_count, parallel.contact_count);

    var tuned_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer tuned_threads.deinit();
    var tuned = CollisionSystem.init(std.testing.allocator);
    defer tuned.deinit();
    var tuned_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer tuned_contacts.deinit();
    const tuned_stats = try tuned.update(&data, &tuned_contacts, &tuned_threads, .{ .static_colliders = colliders.view() });
    try expectSameContacts(expected, tuned_contacts.mergedItems());
    var static_rows: usize = 0;
    for (colliders.view().row_of_index) |row| {
        if (row != std.math.maxInt(u32)) static_rows += 1;
    }
    try std.testing.expect(static_rows != tuned.proxies.len);
    try std.testing.expectEqual(tuned.proxies.len, tuned.static_pair_tuner.learned_item_count);
    try std.testing.expect(tuned_stats.body_count > 0);

    var relocated = data.movementBodyConst(beside).?;
    relocated.position.x = 802;
    relocated.previous_position = relocated.position;
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    frame.beginStep();
    try colliders.reserveForCommit(&data, 1);
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, 1);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    writer.write(.{ .set_movement_body = .{ .entity = beside, .body = relocated } });
    writer.finish();
    frame.structural_commands.finishWrite();
    _ = try frame.applyStructuralCommands(&data);
    colliders.capture(&frame);
    try colliders.sync(&data, &tuned_threads);
    try std.testing.expect(colliders.view().changes.len != 0);
    const expected_after = try filteredReference(&data, .default);
    defer std.testing.allocator.free(expected_after);
    _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
    try expectSameContacts(expected_after, contacts.mergedItems());
}

test "a kinematic static drops its contact only when scope excludes" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const wall = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 32, .h = 32 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 8, .y = 8, .w = 16, .h = 16 }, .dynamic, .solid);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const open = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
    try std.testing.expectEqual(@as(usize, 1), open.contact_count);

    try data.setSimulationTier(wall, .kinematic);
    const closed = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
    try std.testing.expectEqual(@as(usize, 0), closed.contact_count);
}

fn expectKinematicDynamicDropsStaticContacts(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const wall = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 64, .h = 32 }, .static, .solid);
    const walker = try addObstacle(&data, .{ .x = 4, .y = 8, .w = 8, .h = 8 }, .dynamic, .solid);
    const parked = try addObstacle(&data, .{ .x = 44, .y = 8, .w = 8, .h = 8 }, .dynamic, .solid);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const both = try filteredReference(&data, .default);
    defer std.testing.allocator.free(both);
    try std.testing.expectEqual(@as(usize, 2), both.len);
    _ = try updateView(&system, &data, &contacts, colliders.view(), workers, null);
    try expectSameContacts(both, contacts.mergedItems());

    // Exclusion on: the parked body's own tier, packed at the fill, drops its contact only.
    try data.setSimulationTier(parked, .kinematic);
    _ = try updateView(&system, &data, &contacts, colliders.view(), workers, null);
    const kept = try contactsNotNamingAny(both, &.{parked});
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqual(@as(usize, 1), kept.len);
    try std.testing.expect(kept[0].a.eql(wall) or kept[0].b.eql(wall));
    try std.testing.expect(kept[0].a.eql(walker) or kept[0].b.eql(walker));
    try expectSameContacts(kept, contacts.mergedItems());

    try data.setSimulationTier(parked, .locomotion);
    _ = try updateView(&system, &data, &contacts, colliders.view(), workers, null);
    try expectSameContacts(both, contacts.mergedItems());
}

test "a kinematic dynamic body drops its static contacts while exclusion is on" {
    try expectKinematicDynamicDropsStaticContacts(0);
    try expectKinematicDynamicDropsStaticContacts(2);
}

// The contacts naming none of `ids`.
fn contactsNotNamingAny(contacts: []const CollisionContact, ids: []const EntityId) ![]CollisionContact {
    var kept: std.ArrayList(CollisionContact) = .empty;
    errdefer kept.deinit(std.testing.allocator);
    outer: for (contacts) |contact| {
        for (ids) |id| if (contact.a.eql(id) or contact.b.eql(id)) continue :outer;
        try kept.append(std.testing.allocator, contact);
    }
    return try kept.toOwnedSlice(std.testing.allocator);
}

fn expectStoredTriggerAllowFollowsTier(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const left = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, .static, .trigger);
    const right = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    // Default rows are cognition. Locomotion crosses no allow bit, so setup leaves epoch 0.
    try data.setSimulationTier(left, .locomotion);
    try data.setSimulationTier(right, .locomotion);

    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const view = colliders.view();

    const open = try updateView(&system, &data, &contacts, view, workers, null);
    try std.testing.expect(open.contact_count > 0);
    try std.testing.expectEqual(@as(u64, 0), data.collision_allow_epoch);
    var first: std.ArrayList(CollisionContact) = .empty;
    defer first.deinit(std.testing.allocator);
    try first.appendSlice(std.testing.allocator, contacts.mergedItems());

    try data.setSimulationTier(right, .kinematic);
    _ = try updateView(&system, &data, &contacts, view, workers, null);
    try std.testing.expectEqual(@as(u64, 1), data.collision_allow_epoch);
    const dropped = try contactsNotNamingAny(first.items, &.{right});
    defer std.testing.allocator.free(dropped);
    try expectSameContacts(dropped, contacts.mergedItems());

    try data.setSimulationTier(right, .dormant);
    // Exclusion stays on and the epoch did not move: the stored column still drops right.
    _ = try updateView(&system, &data, &contacts, view, workers, null);
    try std.testing.expectEqual(@as(u64, 1), data.collision_allow_epoch);
    try expectSameContacts(dropped, contacts.mergedItems());

    try data.setSimulationTier(right, .locomotion);
    _ = try updateView(&system, &data, &contacts, view, workers, null);
    try std.testing.expectEqual(@as(u64, 2), data.collision_allow_epoch);
    try expectSameContacts(first.items, contacts.mergedItems());

    try data.setSimulationMetadata(right, .{ .tier = .kinematic });
    _ = try updateView(&system, &data, &contacts, view, workers, null);
    try std.testing.expectEqual(@as(u64, 3), data.collision_allow_epoch);
    try expectSameContacts(dropped, contacts.mergedItems());
}

test "collision stored trigger allow follows allowsCollision without a collider sync" {
    try expectStoredTriggerAllowFollowsTier(0);
    try expectStoredTriggerAllowFollowsTier(2);
}

fn expectStoredTriggerAllowFollowsMovedRow(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Movement rows: the walker 0, left 1, right 2.
    const walker = try addObstacle(&data, .{ .x = 1000, .y = 1000, .w = 8, .h = 8 }, .dynamic, .solid);
    const left = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, .static, .trigger);
    const right = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    try data.setSimulationTier(left, .locomotion);
    try data.setSimulationTier(right, .locomotion);
    try std.testing.expectEqual(@as(usize, 2), data.movementBodyDenseIndex(right).?);

    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const view = colliders.view();
    _ = try updateView(&system, &data, &contacts, view, workers, null);
    const trigger_pair = try filteredReference(&data, .default);
    defer std.testing.allocator.free(trigger_pair);
    try std.testing.expectEqual(@as(usize, 1), trigger_pair.len);
    try expectSameContacts(trigger_pair, contacts.mergedItems());

    // Removing the dynamic walker swaps right onto row 0; no static changed, so the store
    // holds right's row 2 until the removal's allow epoch refreshes it. A kinematic body
    // then takes row 2 and turns exclusion on.
    try std.testing.expect(data.destroyEntity(walker));
    const parked = try addObstacle(&data, .{ .x = 2000, .y = 2000, .w = 8, .h = 8 }, .dynamic, .solid);
    try data.setSimulationTier(parked, .kinematic);
    try std.testing.expectEqual(@as(usize, 0), data.movementBodyDenseIndex(right).?);
    try std.testing.expectEqual(@as(usize, 2), data.movementBodyDenseIndex(parked).?);
    try std.testing.expectEqual(view.revision, colliders.view().revision);

    // Both triggers still allow collision, so their pair stays; row 2's tier is not theirs.
    // The contact carries right's current row.
    _ = try updateView(&system, &data, &contacts, view, workers, null);
    const moved_pair = try filteredReference(&data, .default);
    defer std.testing.allocator.free(moved_pair);
    try std.testing.expectEqual(@as(usize, 1), moved_pair.len);
    try expectSameContacts(moved_pair, contacts.mergedItems());

    // Right's own tier, on its new row, drops the pair.
    try data.setSimulationTier(right, .dormant);
    _ = try updateView(&system, &data, &contacts, view, workers, null);
    try std.testing.expectEqual(@as(usize, 0), contacts.mergedItems().len);
}

// The stored row past the shrunk column: the swapRemove leaves the movement store one row
// shorter than the row the stored pair names.
fn expectStoredTriggerAllowPastColumnEnd(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Movement rows: parked 0 (kinematic, so exclusion is on from the first step), the
    // walker 1, left 2, right 3.
    const parked = try addObstacle(&data, .{ .x = 2000, .y = 2000, .w = 8, .h = 8 }, .dynamic, .solid);
    try data.setSimulationTier(parked, .kinematic);
    const walker = try addObstacle(&data, .{ .x = 1000, .y = 1000, .w = 8, .h = 8 }, .dynamic, .solid);
    const left = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, .static, .trigger);
    const right = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    try data.setSimulationTier(left, .locomotion);
    try data.setSimulationTier(right, .locomotion);
    try std.testing.expectEqual(@as(usize, 3), data.movementBodyDenseIndex(right).?);

    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const view = colliders.view();
    _ = try updateView(&system, &data, &contacts, view, workers, null);
    const trigger_pair = try filteredReference(&data, .default);
    defer std.testing.allocator.free(trigger_pair);
    try std.testing.expectEqual(@as(usize, 1), trigger_pair.len);
    try expectSameContactPairs(trigger_pair, contacts.mergedItems());

    // Right swaps from row 3 to row 1; the stored pair's row 3 is now past the column end.
    try std.testing.expect(data.destroyEntity(walker));
    try std.testing.expectEqual(@as(usize, 1), data.movementBodyDenseIndex(right).?);
    try std.testing.expectEqual(@as(usize, 3), data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(view.revision, colliders.view().revision);
    _ = try updateView(&system, &data, &contacts, view, workers, null);
    const moved_pair = try filteredReference(&data, .default);
    defer std.testing.allocator.free(moved_pair);
    try std.testing.expectEqual(@as(usize, 1), moved_pair.len);
    try expectSameContacts(moved_pair, contacts.mergedItems());
}

test "collision stored trigger contacts carry their entities' current movement rows after a swapRemove" {
    try expectStoredTriggerAllowFollowsMovedRow(0);
    try expectStoredTriggerAllowFollowsMovedRow(2);
    try expectStoredTriggerAllowPastColumnEnd(0);
    try expectStoredTriggerAllowPastColumnEnd(2);
}

test "collision stored trigger refresh and emission over several ranges match serial and allocate nothing after the rebuild" {
    const span = 2 * collision_range_alignment_items;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const pitch: f32 = 48;
    const wide: f32 = @as(f32, @floatFromInt(span)) * pitch;
    _ = try addObstacle(&data, .{ .x = 0, .y = 0, .w = wide, .h = 40 }, .static, .trigger);
    var smalls: [span]EntityId = undefined;
    for (0..span) |index| {
        smalls[index] = try addObstacle(&data, .{
            .x = @as(f32, @floatFromInt(index)) * pitch + 8,
            .y = 8,
            .w = 16,
            .h = 16,
        }, .static, .trigger);
    }
    try data.setSimulationTier(smalls[0], .kinematic);

    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    const view = colliders.view();

    var serial = CollisionSystem.init(std.testing.allocator);
    defer serial.deinit();
    var serial_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer serial_contacts.deinit();
    _ = try updateView(&serial, &data, &serial_contacts, view, 0, collision_range_alignment_items);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try updateView(&system, &data, &contacts, view, 2, collision_range_alignment_items);
    try expectSameContacts(serial_contacts.mergedItems(), contacts.mergedItems());
    // More stored pairs than one aligned range, so the refresh and emission split across
    // ranges.
    try std.testing.expect(system.trigger_store.pair_count > collision_range_alignment_items);
    const all = try filteredReference(&data, .default);
    defer std.testing.allocator.free(all);
    const kept = try contactsNotNamingAny(all, &.{smalls[0]});
    defer std.testing.allocator.free(kept);
    try std.testing.expect(kept.len < all.len);
    try expectSameContacts(kept, contacts.mergedItems());

    // The first allow cross after the cold rebuild moves the epoch and keeps exclusion on:
    // the rebuild reserved the refresh's range slots, so this step allocates nothing.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    setTestAllocator(&system, failing.allocator());
    defer setTestAllocator(&system, std.testing.allocator);
    try data.setSimulationTier(smalls[1], .kinematic);
    _ = try updateView(&system, &data, &contacts, view, 2, collision_range_alignment_items);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    setTestAllocator(&system, std.testing.allocator);
    _ = try updateView(&serial, &data, &serial_contacts, view, 0, collision_range_alignment_items);
    try expectSameContacts(serial_contacts.mergedItems(), contacts.mergedItems());
    for (contacts.mergedItems()) |contact| {
        for (smalls[0..2]) |excluded| try std.testing.expect(!contact.a.eql(excluded) and !contact.b.eql(excluded));
    }
}

test "an unsynced static move is out of band" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const wall = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 32, .h = 32 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 8, .y = 8, .w = 16, .h = 16 }, .dynamic, .solid);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);

    const body = data.movementBodyConst(wall).?;
    try data.setMovementBody(wall, .{
        .position = .{ .x = 4, .y = 4 },
        .previous_position = body.previous_position,
        .velocity = body.velocity,
    });
    if (comptime builtin.mode == .debug) {
        try std.testing.expectError(error.StaticMovedOutsideCommit, updateView(&system, &data, &contacts, colliders.view(), 0, null));
    }

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    frame.beginStep();
    try colliders.reserveForCommit(&data, 1);
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, 1);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    writer.write(.{ .set_movement_body = .{ .entity = wall, .body = data.movementBodyConst(wall).? } });
    writer.finish();
    frame.structural_commands.finishWrite();
    _ = try frame.applyStructuralCommands(&data);
    colliders.capture(&frame);
    try colliders.sync(&data, &threads);
    _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
}

fn placeBody(data: *DataSystem, entity: EntityId, x: f32, y: f32) !void {
    const body = data.movementBodyConst(entity).?;
    try data.setMovementBody(entity, .{
        .position = .{ .x = x, .y = y },
        .previous_position = body.previous_position,
        .velocity = body.velocity,
    });
}

fn commitBody(data: *DataSystem, colliders: *StaticColliderSystem, entity: EntityId) !void {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    try commitCommands(data, colliders, &threads, &.{.{ .set_movement_body = .{ .entity = entity, .body = data.movementBodyConst(entity).? } }});
}

// One structural commit of `commands`, then the collider capture and sync, as the seam runs them.
fn commitCommands(data: *DataSystem, colliders: *StaticColliderSystem, threads: *ThreadSystem, commands: []const StructuralCommand) !void {
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    frame.beginStep();
    try colliders.reserveForCommit(data, commands.len);
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, commands.len);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    for (commands) |command| writer.write(command);
    writer.finish();
    frame.structural_commands.finishWrite();
    _ = try frame.applyStructuralCommands(data);
    colliders.capture(&frame);
    try colliders.sync(data, threads);
}

test "collision debug seam check flags a walked non-hit and ignores a static outside the walk" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const near = try addObstacle(&data, .{ .x = 20, .y = 0, .w = 8, .h = 8 }, .static, .solid);
    const far = try addObstacle(&data, .{ .x = 1000, .y = 1000, .w = 8, .h = 8 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .dynamic, .solid);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);

    try placeBody(&data, near, 24, 4);
    if (comptime builtin.mode == .debug) {
        try std.testing.expectError(error.StaticMovedOutsideCommit, updateView(&system, &data, &contacts, colliders.view(), 0, null));
    } else {
        _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
    }
    try placeBody(&data, near, 20, 0);
    _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);

    try placeBody(&data, far, 1004, 1004);
    _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
}

test "collision debug seam check matches across workers" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .static, .solid);
    const near = try addObstacle(&data, .{ .x = 20, .y = 0, .w = 8, .h = 8 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 16, .h = 16 }, .dynamic, .solid);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);

    var serial = CollisionSystem.init(std.testing.allocator);
    defer serial.deinit();
    var serial_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer serial_contacts.deinit();
    var parallel = CollisionSystem.init(std.testing.allocator);
    defer parallel.deinit();
    var parallel_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer parallel_contacts.deinit();

    try placeBody(&data, near, 24, 4);
    if (comptime builtin.mode == .debug) {
        try std.testing.expectError(error.StaticMovedOutsideCommit, updateView(&serial, &data, &serial_contacts, colliders.view(), 0, null));
        try std.testing.expectError(error.StaticMovedOutsideCommit, updateView(&parallel, &data, &parallel_contacts, colliders.view(), 2, collision_range_alignment_items));
    } else {
        _ = try updateView(&serial, &data, &serial_contacts, colliders.view(), 0, null);
        _ = try updateView(&parallel, &data, &parallel_contacts, colliders.view(), 2, collision_range_alignment_items);
        try expectSameContacts(serial_contacts.mergedItems(), parallel_contacts.mergedItems());
    }

    try commitBody(&data, &colliders, near);
    _ = try updateView(&serial, &data, &serial_contacts, colliders.view(), 0, null);
    _ = try updateView(&parallel, &data, &parallel_contacts, colliders.view(), 2, collision_range_alignment_items);
    try expectSameContacts(serial_contacts.mergedItems(), parallel_contacts.mergedItems());
    try std.testing.expect(serial_contacts.mergedItems().len > 0);
}

test "collision stored-rect lanes match scalar inequality" {
    var stored_min_x = [_]f32{ 0, 0, 0, 0 };
    var stored_min_y = [_]f32{ 1, 1, 1, 1 };
    var stored_max_x = [_]f32{ 4, 4, 4, 4 };
    var stored_max_y = [_]f32{ 5, 5, 5, 5 };
    var live_min_x = [_]f32{ 0, 0, 0, 0 };
    var live_min_y = [_]f32{ 1, 1, 1, 1 };
    var live_max_x = [_]f32{ 4, 4, 4, 4 };
    var live_max_y = [_]f32{ 5, 5, 5, 5 };
    var bad = [_]u32{ 0, 0, 0, 0 };
    const expect = struct {
        fn check(
            stored_min_x_all: []const f32,
            stored_min_y_all: []const f32,
            stored_max_x_all: []const f32,
            stored_max_y_all: []const f32,
            live_min_x_all: []const f32,
            live_min_y_all: []const f32,
            live_max_x_all: []const f32,
            live_max_y_all: []const f32,
            bad_all: []const u32,
            count: usize,
        ) !void {
            var scalar = false;
            for (0..count) |lane| {
                if (bad_all[lane] != 0 or stored_min_x_all[lane] != live_min_x_all[lane] or stored_min_y_all[lane] != live_min_y_all[lane] or stored_max_x_all[lane] != live_max_x_all[lane] or stored_max_y_all[lane] != live_max_y_all[lane]) scalar = true;
            }
            try std.testing.expectEqual(scalar, rectsMismatch(
                stored_min_x_all[0..count],
                stored_min_y_all[0..count],
                stored_max_x_all[0..count],
                stored_max_y_all[0..count],
                live_min_x_all[0..count],
                live_min_y_all[0..count],
                live_max_x_all[0..count],
                live_max_y_all[0..count],
                bad_all[0..count],
                count,
            ));
        }
    };
    for (1..5) |count| {
        try expect.check(&stored_min_x, &stored_min_y, &stored_max_x, &stored_max_y, &live_min_x, &live_min_y, &live_max_x, &live_max_y, &bad, count);
        stored_min_x[count - 1] = 9;
        try expect.check(&stored_min_x, &stored_min_y, &stored_max_x, &stored_max_y, &live_min_x, &live_min_y, &live_max_x, &live_max_y, &bad, count);
        stored_min_x[count - 1] = 0;
        stored_min_y[count - 1] = 8;
        try expect.check(&stored_min_x, &stored_min_y, &stored_max_x, &stored_max_y, &live_min_x, &live_min_y, &live_max_x, &live_max_y, &bad, count);
        stored_min_y[count - 1] = 1;
        stored_max_x[count - 1] = 11;
        try expect.check(&stored_min_x, &stored_min_y, &stored_max_x, &stored_max_y, &live_min_x, &live_min_y, &live_max_x, &live_max_y, &bad, count);
        stored_max_x[count - 1] = 4;
        stored_max_y[count - 1] = 2;
        try expect.check(&stored_min_x, &stored_min_y, &stored_max_x, &stored_max_y, &live_min_x, &live_min_y, &live_max_x, &live_max_y, &bad, count);
        stored_max_y[count - 1] = 5;
        bad[count - 1] = 1;
        try expect.check(&stored_min_x, &stored_min_y, &stored_max_x, &stored_max_y, &live_min_x, &live_min_y, &live_max_x, &live_max_y, &bad, count);
        bad[count - 1] = 0;
    }
    stored_min_x[0] = std.math.nan(f32);
    live_min_x[0] = std.math.nan(f32);
    try expect.check(&stored_min_x, &stored_min_y, &stored_max_x, &stored_max_y, &live_min_x, &live_min_y, &live_max_x, &live_max_y, &bad, 1);
    try expect.check(&stored_min_x, &stored_min_y, &stored_max_x, &stored_max_y, &live_min_x, &live_min_y, &live_max_x, &live_max_y, &bad, 4);
}

test "collision debug rect compare flags a static moved in its second range on any worker count" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const static_count = collision_range_alignment_items + 1;
    var statics: [static_count]EntityId = undefined;
    for (0..static_count) |index| {
        statics[index] = try addObstacle(&data, .{
            .x = @as(f32, @floatFromInt(index)) * 32,
            .y = 0,
            .w = 16,
            .h = 16,
        }, .static, .solid);
    }
    _ = try addObstacle(&data, .{ .x = 0, .y = 0, .w = @as(f32, @floatFromInt(static_count)) * 32, .h = 16 }, .dynamic, .solid);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try updateView(&system, &data, &contacts, colliders.view(), 2, collision_range_alignment_items);
    if (comptime builtin.mode == .debug) {
        // More distinct ids than one aligned range, so the compare has a second range.
        try std.testing.expect(system.distinct_ids.items.len > collision_range_alignment_items);
        // The second compare range holds this id. A dropped flag there must fail both worker counts.
        const second = system.distinct_ids.items[collision_range_alignment_items];
        const moved = for (statics) |entity| {
            if (entity.index == second) break entity;
        } else unreachable;
        try placeBody(&data, moved, data.movementBodyConst(moved).?.position.x + 4, 4);
        try std.testing.expectError(error.StaticMovedOutsideCommit, updateView(&system, &data, &contacts, colliders.view(), 0, collision_range_alignment_items));
        // The warm multi-range compare (its scratch rows and per-range flags) allocates
        // nothing past the seam reserve.
        const allocator = system.allocator;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        system.allocator = failing.allocator();
        const multi_range = updateView(&system, &data, &contacts, colliders.view(), 2, collision_range_alignment_items);
        system.allocator = allocator;
        try std.testing.expectError(error.StaticMovedOutsideCommit, multi_range);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
        try commitBody(&data, &colliders, moved);
    } else {
        const moved = statics[static_count - 1];
        try placeBody(&data, moved, data.movementBodyConst(moved).?.position.x + 4, 4);
        _ = try updateView(&system, &data, &contacts, colliders.view(), 0, collision_range_alignment_items);
        try commitBody(&data, &colliders, moved);
    }
    var serial_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer serial_contacts.deinit();
    _ = try updateView(&system, &data, &serial_contacts, colliders.view(), 0, collision_range_alignment_items);
    _ = try updateView(&system, &data, &contacts, colliders.view(), 2, collision_range_alignment_items);
    try expectSameContacts(serial_contacts.mergedItems(), contacts.mergedItems());
}

test "dynamic bounds index tracks static membership through removal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 8, .h = 8 }, .dynamic, .solid);
    const wall = try addObstacle(&data, .{ .x = 40, .y = 0, .w = 8, .h = 8 }, .static, .solid);
    const other = try addObstacle(&data, .{ .x = 80, .y = 0, .w = 8, .h = 8 }, .dynamic, .solid);
    const dynamic_index = data.resolveSlotConst(dynamic).?.collision_bounds_index.?;
    const wall_index = data.resolveSlotConst(wall).?.collision_bounds_index.?;
    const other_index = data.resolveSlotConst(other).?.collision_bounds_index.?;
    try expectDynamicIndex(&data, &.{ dynamic_index, other_index });

    try data.setCollisionResponse(wall, .{ .mobility = .dynamic, .mode = .solid });
    try expectDynamicIndex(&data, &.{ dynamic_index, wall_index, other_index });
    try data.setCollisionResponse(wall, .{ .mobility = .static, .mode = .solid });
    try expectDynamicIndex(&data, &.{ dynamic_index, other_index });

    try std.testing.expect(data.destroyEntity(dynamic));
    const other_now = data.resolveSlotConst(other).?.collision_bounds_index.?;
    try expectDynamicIndex(&data, &.{other_now});
}

const LaneStatic = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    velocity_x: f32,
    velocity_y: f32,
    kinematic: bool = false,
    shared_edge: bool = false,
    equal_center: bool = false,
};

fn expectStaticHitLanes(dynamic_box: TestBox, statics: []const LaneStatic) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addObstacle(&data, dynamic_box, .dynamic, .solid);
    var kinematic_id: ?EntityId = null;
    var equal_center: ?EntityId = null;
    var shared_edge: ?EntityId = null;
    var expect_static_first = false;
    var expect_dynamic_first = false;
    var static_index: [8]u32 = undefined;
    const dynamic_key = bodyRunKey(dynamic_box.x, dynamic_box.y, dynamic.index);
    for (statics, 0..) |spec, index| {
        const entity = try addObstacle(&data, .{
            .x = spec.x,
            .y = spec.y,
            .w = spec.w,
            .h = spec.h,
            .velocity_x = spec.velocity_x,
            .velocity_y = spec.velocity_y,
        }, .static, .solid);
        static_index[index] = entity.index;
        if (spec.kinematic) {
            try data.setSimulationTier(entity, .kinematic);
            kinematic_id = entity;
        }
        if (spec.equal_center) equal_center = entity;
        if (spec.shared_edge) shared_edge = entity;
        if (!spec.shared_edge and !spec.kinematic) {
            const static_key = bodyRunKey(spec.x, spec.y, entity.index);
            if (static_key < dynamic_key) expect_static_first = true else expect_dynamic_first = true;
        }
    }

    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    var out_entity: [8]u32 = undefined;
    var out_min_x: [8]f32 = undefined;
    var out_min_y: [8]f32 = undefined;
    var out_max_x: [8]f32 = undefined;
    var out_max_y: [8]f32 = undefined;
    const queried = colliders.view().collectOverlaps(0, .{
        .min_x = dynamic_box.x,
        .min_y = dynamic_box.y,
        .max_x = dynamic_box.x + dynamic_box.w,
        .max_y = dynamic_box.y + dynamic_box.h,
    }, &out_entity, &out_min_x, &out_min_y, &out_max_x, &out_max_y, idleSpanIds());
    // One cell, so query order is creation order. A later case relies on that.
    try std.testing.expectEqual(statics.len, queried);
    try std.testing.expectEqualSlices(u32, static_index[0..statics.len], out_entity[0..queried]);

    const all = try filteredReference(&data, .default);
    defer std.testing.allocator.free(all);
    var expected_list: std.ArrayList(CollisionContact) = .empty;
    defer expected_list.deinit(std.testing.allocator);
    var kinematic_named = false;
    for (all) |contact| {
        if (kinematic_id) |id| {
            if (contact.a.eql(id) or contact.b.eql(id)) {
                kinematic_named = true;
                continue;
            }
        }
        try expected_list.append(std.testing.allocator, contact);
    }
    const expected = expected_list.items;
    try std.testing.expect(expected.len > 0);
    try std.testing.expect(expected[0].pre_response_max_speed_sq != 0);
    if (kinematic_id != null) try std.testing.expect(kinematic_named);
    if (expect_static_first) {
        var found = false;
        for (expected) |contact| found = found or contact.b.eql(dynamic);
        try std.testing.expect(found);
    }
    if (expect_dynamic_first) {
        var found = false;
        for (expected) |contact| found = found or contact.a.eql(dynamic);
        try std.testing.expect(found);
    }
    if (equal_center) |id| {
        var found = false;
        for (expected) |contact| {
            if (!contact.a.eql(id) and !contact.b.eql(id)) continue;
            try std.testing.expectEqual(@as(f32, -1), contact.normal_x);
            try std.testing.expectEqual(@as(f32, 0), contact.normal_y);
            found = true;
        }
        try std.testing.expect(found);
    }
    if (shared_edge) |id| {
        for (expected) |contact| try std.testing.expect(!contact.a.eql(id) and !contact.b.eql(id));
    }

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
    try expectSameContacts(expected, contacts.mergedItems());
}

test "collision static hit lanes match contactForAabbs" {
    const dynamic = TestBox{ .x = 0, .y = 0, .w = 16, .h = 16, .velocity_x = 2, .velocity_y = -3 };
    try expectStaticHitLanes(dynamic, &.{
        .{ .x = 8, .y = 2, .w = 16, .h = 16, .velocity_x = 1, .velocity_y = 4 },
    });
    try expectStaticHitLanes(.{ .x = 0, .y = 0, .w = 16, .h = 16, .velocity_x = 3, .velocity_y = 1 }, &.{
        .{ .x = -8, .y = 2, .w = 16, .h = 16, .velocity_x = -2, .velocity_y = 2 },
        .{ .x = 8, .y = 2, .w = 16, .h = 16, .velocity_x = 4, .velocity_y = -2 },
    });
    try expectStaticHitLanes(.{ .x = 0, .y = 0, .w = 16, .h = 16, .velocity_x = 2, .velocity_y = 3 }, &.{
        .{ .x = -6, .y = 4, .w = 12, .h = 12, .velocity_x = -1, .velocity_y = 2 },
        .{ .x = 10, .y = 6, .w = 12, .h = 12, .velocity_x = 5, .velocity_y = 1 },
        .{ .x = 0, .y = 0, .w = 16, .h = 16, .velocity_x = 1, .velocity_y = -1, .equal_center = true },
    });
    // Shared edge and kinematic are query rows 0 and 1 and emit nothing. Rows 3 and 4
    // overlap, so lane 3 of the full group and the one-row tail both have to emit.
    try expectStaticHitLanes(.{ .x = 0, .y = 0, .w = 16, .h = 16, .velocity_x = 4, .velocity_y = -2 }, &.{
        .{ .x = 16, .y = 0, .w = 16, .h = 16, .velocity_x = 6, .velocity_y = 1, .shared_edge = true },
        .{ .x = 4, .y = 4, .w = 8, .h = 8, .velocity_x = 3, .velocity_y = 3, .kinematic = true },
        .{ .x = -6, .y = 4, .w = 12, .h = 12, .velocity_x = -1, .velocity_y = 2 },
        .{ .x = 10, .y = 6, .w = 12, .h = 12, .velocity_x = 5, .velocity_y = 1 },
        .{ .x = 0, .y = 0, .w = 16, .h = 16, .velocity_x = 1, .velocity_y = -1, .equal_center = true },
    });
}

test "a reserved warm static step allocates nothing" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 4, .y = 4, .w = 16, .h = 16 }, .dynamic, .solid);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(8);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try CollisionSystem.reserveContactStream(&contacts, CollisionSystem.estimateContactCapacity(8));
    _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
    try std.testing.expect(system.trigger_store.ready);
    try std.testing.expect(contacts.mergedItems().len > 0);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    setTestAllocator(&system, failing.allocator());
    defer setTestAllocator(&system, std.testing.allocator);
    _ = try updateView(&system, &data, &contacts, colliders.view(), 0, null);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    const worker_bodies = 2 * collision_range_alignment_items;
    var worker_data = DataSystem.init(std.testing.allocator);
    defer worker_data.deinit();
    _ = try addObstacle(&worker_data, .{ .x = 0, .y = 0, .w = 4000, .h = 40, .velocity_x = 1, .velocity_y = 1 }, .static, .solid);
    for (0..worker_bodies) |index| {
        _ = try addObstacle(&worker_data, .{
            .x = @as(f32, @floatFromInt(index)) * 8,
            .y = 4,
            .w = 8,
            .h = 8,
            .velocity_x = 2,
            .velocity_y = -1,
        }, .dynamic, .solid);
    }
    var worker_colliders = StaticColliderSystem.init(std.testing.allocator);
    defer worker_colliders.deinit();
    try worker_colliders.rebuild(&worker_data, testGeometry(), null);
    var worker_system = CollisionSystem.init(std.testing.allocator);
    defer worker_system.deinit();
    try worker_system.reserve(worker_bodies);
    var worker_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer worker_contacts.deinit();
    try CollisionSystem.reserveContactStream(&worker_contacts, CollisionSystem.estimateContactCapacity(worker_bodies));
    _ = try updateView(&worker_system, &worker_data, &worker_contacts, worker_colliders.view(), 2, collision_range_alignment_items);

    var worker_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    setTestAllocator(&worker_system, worker_failing.allocator());
    defer setTestAllocator(&worker_system, std.testing.allocator);
    _ = try updateView(&worker_system, &worker_data, &worker_contacts, worker_colliders.view(), 2, collision_range_alignment_items);
    try std.testing.expectEqual(@as(usize, 0), worker_failing.allocations);
}

fn movedBody(data: *const DataSystem, entity: EntityId, x: f32, y: f32) StructuralCommand {
    var body = data.movementBodyConst(entity).?;
    body.position = .{ .x = x, .y = y };
    body.previous_position = body.position;
    return .{ .set_movement_body = .{ .entity = entity, .body = body } };
}

// Points `system` and its trigger store at `allocator`.
fn setTestAllocator(system: *CollisionSystem, allocator: std.mem.Allocator) void {
    system.allocator = allocator;
    system.trigger_store.allocator = allocator;
}

// Every stored pair in walk order, rows widened as emitted, and its emit byte.
const StoredPairs = struct {
    pairs: []KeyedContact,
    emit: []u8,
};

// Walks the store from its first pair with the production cursor; keys strictly increase.
fn storedPairs(system: *const CollisionSystem, arena: std.mem.Allocator) !StoredPairs {
    const store = &system.trigger_store;
    const walked = StoredPairs{
        .pairs = try arena.alloc(KeyedContact, store.pair_count),
        .emit = try arena.alloc(u8, store.pair_count),
    };
    if (store.pair_count == 0) return walked;
    var cursor = store.cursorAt(0);
    for (walked.pairs, walked.emit, 0..) |*pair, *emit, index| {
        try std.testing.expect(cursor.valid());
        const page = cursor.page();
        const slot = cursor.offset;
        pair.* = .{ .key = page.keys[slot], .contact = page.contactAt(slot) };
        emit.* = page.emit[slot];
        if (index != 0) try std.testing.expect(walked.pairs[index - 1].key < pair.key);
        cursor.next();
    }
    try std.testing.expect(!cursor.valid());
    return walked;
}

// The same stored pairs in the same order: keys, contacts, emit bytes, and store sums.
fn expectSameTriggerPairs(expected: *const CollisionSystem, actual: *const CollisionSystem) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const want = try storedPairs(expected, arena);
    const got = try storedPairs(actual, arena);
    try std.testing.expectEqual(want.pairs.len, got.pairs.len);
    const want_contacts = try arena.alloc(CollisionContact, want.pairs.len);
    const got_contacts = try arena.alloc(CollisionContact, got.pairs.len);
    for (want.pairs, got.pairs, want_contacts, got_contacts) |w, g, *want_contact, *got_contact| {
        try std.testing.expectEqual(w.key, g.key);
        want_contact.* = w.contact;
        got_contact.* = g.contact;
    }
    try expectSameContacts(want_contacts, got_contacts);
    try std.testing.expectEqualSlices(u8, want.emit, got.emit);
    try std.testing.expectEqual(expected.trigger_store.valid_count, actual.trigger_store.valid_count);
    try std.testing.expectEqual(expected.trigger_store.allowed_count, actual.trigger_store.allowed_count);
}

fn updateOn(system: *CollisionSystem, data: *const DataSystem, contacts: *RangeOutputStream(CollisionContact), view: ColliderView, threads: *ThreadSystem, workers: usize) !void {
    _ = try system.update(data, contacts, threads, .{
        .static_colliders = view,
        .max_worker_threads = workers,
        .items_per_range = collision_range_alignment_items,
        .adaptive = false,
    });
}

// Commits `commands`, refreshes `patched` at the seam (a contiguous revision with changes,
// so the incremental patch), and checks its stored pairs and contacts against a system that
// rebuilds from the same view.
fn expectPatchMatchesRebuild(
    data: *DataSystem,
    colliders: *StaticColliderSystem,
    threads: *ThreadSystem,
    workers: usize,
    patched: *CollisionSystem,
    patched_contacts: *RangeOutputStream(CollisionContact),
    commands: []const StructuralCommand,
) !void {
    const revision = colliders.view().revision;
    try commitCommands(data, colliders, threads, commands);
    const view = colliders.view();
    try std.testing.expectEqual(revision + 1, view.revision);
    try std.testing.expect(view.changes.len != 0);
    try std.testing.expect(patched.trigger_store.ready and patched.trigger_store.seen_revision == revision);
    try patched.syncCommittedTriggers(data, view, threads);
    try std.testing.expectEqual(view.revision, patched.trigger_store.seen_revision);
    try updateOn(patched, data, patched_contacts, view, threads, workers);

    var rebuilt = CollisionSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    var rebuilt_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer rebuilt_contacts.deinit();
    try updateOn(&rebuilt, data, &rebuilt_contacts, view, threads, workers);
    try expectSameTriggerPairs(&rebuilt, patched);
    try expectSameContacts(rebuilt_contacts.mergedItems(), patched_contacts.mergedItems());
    const expected = try filteredReference(data, .default);
    defer std.testing.allocator.free(expected);
    try expectSameContactPairs(expected, patched_contacts.mergedItems());
}

// A stored pair names `entity`, and `other` when set.
fn storesPairNaming(system: *const CollisionSystem, entity: EntityId, other: ?EntityId) !bool {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    for ((try storedPairs(system, arena_state.allocator())).pairs) |pair| {
        const a = pair.contact.a;
        const b = pair.contact.b;
        if (!a.eql(entity) and !b.eql(entity)) continue;
        const partner = if (a.eql(entity)) b else a;
        if (other == null or partner.eql(other.?)) return true;
    }
    return false;
}

fn expectTriggerPatchesMatchRebuild(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Chunks are 128 units. A trigger on a solid, two overlapping triggers, a lone solid and
    // a lone trigger, each in its own chunk.
    const trigger_a = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    const solid_a = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 260, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    const trigger_b = try addObstacle(&data, .{ .x = 280, .y = 20, .w = 40, .h = 40 }, .static, .trigger);
    const solid_c = try addObstacle(&data, .{ .x = 10, .y = 260, .w = 40, .h = 40 }, .static, .solid);
    const trigger_d = try addObstacle(&data, .{ .x = 520, .y = 520, .w = 40, .h = 40 }, .static, .trigger);
    // A chain of overlapping triggers over two chunks: more trigger rows than one range.
    var chain_link = EntityId.invalid;
    for (0..2 * collision_range_alignment_items) |index| {
        const link = try addObstacle(&data, .{ .x = 1024 + @as(f32, @floatFromInt(index)) * 12, .y = 1024, .w = 16, .h = 16 }, .static, .trigger);
        if (index == collision_range_alignment_items) chain_link = link;
    }
    // Dynamic until it is added as a static.
    const late = try addObstacle(&data, .{ .x = 1800, .y = 1800, .w = 40, .h = 40 }, .dynamic, .trigger);
    _ = try addObstacle(&data, .{ .x = 40, .y = 40, .w = 8, .h = 8 }, .dynamic, .solid);
    _ = try addObstacle(&data, .{ .x = 290, .y = 30, .w = 8, .h = 8 }, .dynamic, .solid);
    // Last movement row and kinematic: exclusion is on, so emission filters on the allow
    // bit, and a destroyed static's row swap moves only this body.
    const parked = try addObstacle(&data, .{ .x = 1900, .y = 100, .w = 8, .h = 8 }, .dynamic, .solid);
    try data.setSimulationTier(parked, .kinematic);

    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers });
    defer threads.deinit();
    var patched = CollisionSystem.init(std.testing.allocator);
    defer patched.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    try updateOn(&patched, &data, &contacts, colliders.view(), &threads, workers);
    try std.testing.expect(patched.trigger_store.pair_count > collision_range_alignment_items);

    // Multi-chunk: a trigger crosses onto the trigger pair, a solid onto the lone trigger.
    try expectPatchMatchesRebuild(&data, &colliders, &threads, workers, &patched, &contacts, &.{
        movedBody(&data, trigger_a, 270, 15),
        movedBody(&data, solid_c, 530, 530),
    });
    // An overlapping trigger is added, moved onto the lone trigger and the solid in one commit.
    var add: [2]StructuralCommand = .{
        .{ .set_collision_response = .{ .entity = late, .response = .{ .mobility = .static, .mode = .trigger, .restitution = 0 } } },
        movedBody(&data, late, 540, 540),
    };
    try expectPatchMatchesRebuild(&data, &colliders, &threads, workers, &patched, &contacts, &add);
    // Statics removed: a trigger leaves the static set, a solid is destroyed.
    try expectPatchMatchesRebuild(&data, &colliders, &threads, workers, &patched, &contacts, &.{
        .{ .set_collision_response = .{ .entity = trigger_b, .response = .{ .mobility = .dynamic, .mode = .trigger, .restitution = 0 } } },
        .{ .destroy_entity = solid_a },
    });
    // Live partners destroyed: the solid on the lone trigger since the first commit, and a
    // chain trigger whose pairs sit on both of its neighbours.
    try std.testing.expect(try storesPairNaming(&patched, solid_c, trigger_d));
    try std.testing.expect(try storesPairNaming(&patched, chain_link, null));
    try expectPatchMatchesRebuild(&data, &colliders, &threads, workers, &patched, &contacts, &.{
        .{ .destroy_entity = solid_c },
        .{ .destroy_entity = chain_link },
    });
    // Repeated patches: the crossed trigger returns, then the lone trigger straddles a chunk edge.
    try expectPatchMatchesRebuild(&data, &colliders, &threads, workers, &patched, &contacts, &.{movedBody(&data, trigger_a, 10, 10)});
    try expectPatchMatchesRebuild(&data, &colliders, &threads, workers, &patched, &contacts, &.{movedBody(&data, trigger_d, 620, 500)});
    try expectPatchMatchesRebuild(&data, &colliders, &threads, workers, &patched, &contacts, &.{movedBody(&data, trigger_a, 1030, 1020)});
}

test "incremental trigger patches match a full trigger rebuild" {
    try expectTriggerPatchesMatchRebuild(0);
    try expectTriggerPatchesMatchRebuild(2);
}

// A patched system's cold store over `data`'s statics, stepped at fixed 16-item ranges on
// `workers` workers; `commit` checks each seam patch against a rebuild. Initialized in place:
// the thread system stays where it started.
const TriggerPatchFixture = struct {
    colliders: StaticColliderSystem,
    threads: ThreadSystem,
    patched: CollisionSystem,
    contacts: RangeOutputStream(CollisionContact),
    workers: usize,

    fn init(self: *TriggerPatchFixture, data: *const DataSystem, workers: usize) !void {
        self.workers = workers;
        self.colliders = StaticColliderSystem.init(std.testing.allocator);
        errdefer self.colliders.deinit();
        try self.colliders.rebuild(data, testGeometry(), null);
        self.threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers });
        errdefer self.threads.deinit();
        self.patched = CollisionSystem.init(std.testing.allocator);
        errdefer self.patched.deinit();
        self.contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
        errdefer self.contacts.deinit();
        try updateOn(&self.patched, data, &self.contacts, self.colliders.view(), &self.threads, workers);
    }

    fn deinit(self: *TriggerPatchFixture) void {
        self.contacts.deinit();
        self.patched.deinit();
        self.threads.deinit();
        self.colliders.deinit();
    }

    fn commit(self: *TriggerPatchFixture, data: *DataSystem, commands: []const StructuralCommand) !void {
        try expectPatchMatchesRebuild(data, &self.colliders, &self.threads, self.workers, &self.patched, &self.contacts, commands);
    }
};

fn expectTwoLevelPatch(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const ground_trigger = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 300, .y = 300, .w = 40, .h = 40 }, .static, .solid);
    const deep_trigger = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40, .level = 1 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40, .level = 1 }, .static, .trigger);
    const deep_solid = try addObstacle(&data, .{ .x = 500, .y = 500, .w = 40, .h = 40, .level = 1 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 520, .y = 520, .w = 40, .h = 40, .level = 2 }, .static, .trigger);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    // Both stored levels change in one commit, and a solid joins a third level's trigger.
    try fixture.commit(&data, &.{
        movedBody(&data, ground_trigger, 290, 290),
        movedBody(&data, deep_trigger, 900, 900),
        .{ .set_world_level = .{ .entity = deep_solid, .level = 2 } },
    });
    // A trigger crosses levels onto a level the store has never held.
    try fixture.commit(&data, &.{.{ .set_world_level = .{ .entity = ground_trigger, .level = 3 } }});
    try fixture.commit(&data, &.{.{ .set_world_level = .{ .entity = ground_trigger, .level = 0 } }});
}

test "collision trigger patch with triggers on two levels changed in one commit matches a rebuild" {
    try expectTwoLevelPatch(0);
    try expectTwoLevelPatch(2);
}

fn expectWideTriggerPatch(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // The trigger is at min_x 0, so it is the a of every pair, all in one strip: one a-run
    // longer than a page, so dropping it walks across a page boundary.
    const partners = 70;
    const wide = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 1800, .h = 40 }, .static, .trigger);
    for (0..partners) |index| {
        _ = try addObstacle(&data, .{ .x = @as(f32, @floatFromInt(index)) * 25 + 4, .y = 8, .w = 16, .h = 16 }, .static, .solid);
    }
    // Bystander pairs keyed after the run, in a later strip. A rebuild splits the 80 pairs
    // into two pages of 40, so they sit on the run's last page at offsets the first page's
    // run keys also fill: a walk that reads the first page's keys there drops them.
    const bystanders = 10;
    _ = try addObstacle(&data, .{ .x = 0, .y = 1500, .w = 300, .h = 40 }, .static, .trigger);
    for (0..bystanders) |index| {
        _ = try addObstacle(&data, .{ .x = @as(f32, @floatFromInt(index)) * 25 + 4, .y = 1508, .w = 16, .h = 16 }, .static, .solid);
    }
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    try std.testing.expectEqual(partners + bystanders, fixture.patched.trigger_store.pair_count);
    comptime std.debug.assert(partners > collision_triggers.page_capacity);
    // The far end shrinks off its last solids with the min corner kept, then grows back.
    try fixture.commit(&data, &.{.{ .set_collision_bounds = .{ .entity = wide, .bounds = .{ .size = .{ .x = 1300, .y = 40 } } } }});
    try fixture.commit(&data, &.{.{ .set_collision_bounds = .{ .entity = wide, .bounds = .{ .size = .{ .x = 1800, .y = 40 } } } }});
    // A shift moves every pair's key.
    try fixture.commit(&data, &.{movedBody(&data, wide, 30, 2)});
}

test "collision trigger patch of a wide trigger changed at its far end matches a rebuild" {
    try expectWideTriggerPatch(0);
    try expectWideTriggerPatch(2);
}

fn expectGridEdgePatch(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // The test grid is 2048 units a side. At its last cell, past both far edges.
    const edge_trigger = try addObstacle(&data, .{ .x = 2030, .y = 2030, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 2040, .y = 2050, .w = 30, .h = 30 }, .static, .solid);
    // Left of it, so the pair's a: the trigger's old b-pair is dropped by exact key.
    _ = try addObstacle(&data, .{ .x = 2020, .y = 2040, .w = 20, .h = 20 }, .static, .solid);
    // Wholly below the level.
    const below = try addObstacle(&data, .{ .x = 600, .y = 2100, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 620, .y = 2120, .w = 40, .h = 40 }, .static, .trigger);
    // A trigger over 60 strips with partners on only two of them.
    const tall = try addObstacle(&data, .{ .x = 300, .y = 0, .w = 20, .h = 1900 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 310, .y = 100, .w = 20, .h = 20 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 310, .y = 1800, .w = 20, .h = 20 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 295, .y = 1000, .w = 10, .h = 10 }, .static, .solid);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    try fixture.commit(&data, &.{movedBody(&data, edge_trigger, 2034, 2034)});
    try fixture.commit(&data, &.{movedBody(&data, below, 610, 2110)});
    try fixture.commit(&data, &.{movedBody(&data, tall, 302, 2)});
    try fixture.commit(&data, &.{
        movedBody(&data, edge_trigger, 2030, 2030),
        movedBody(&data, below, 600, 2100),
        movedBody(&data, tall, 300, 0),
    });
}

test "collision trigger patch at the grid's last cell and below the level matches a rebuild" {
    try expectGridEdgePatch(0);
    try expectGridEdgePatch(2);
}

fn expectTurnedTriggerPatch(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const turned = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 20, .y = 40, .w = 40, .h = 40 }, .static, .trigger);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    // Only the mode changes: the solid-solid neighbour gains a pair, and back.
    try fixture.commit(&data, &.{.{ .set_collision_response = .{ .entity = turned, .response = .{ .mobility = .static, .mode = .trigger, .restitution = 0 } } }});
    try fixture.commit(&data, &.{.{ .set_collision_response = .{ .entity = turned, .response = .{ .mobility = .static, .mode = .solid, .restitution = 0 } } }});
}

test "collision trigger patch of a solid turned trigger with no move matches a rebuild" {
    try expectTurnedTriggerPatch(0);
    try expectTurnedTriggerPatch(2);
}

fn expectEmptyStoreTurnedTriggerPatch(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const turned = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40 }, .static, .solid);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    // All statics are solid: the store is ready with no pairs, yet the mode-only change's
    // shared walk must still feed its new part.
    try std.testing.expectEqual(@as(usize, 0), fixture.patched.trigger_store.pair_count);
    try fixture.commit(&data, &.{.{ .set_collision_response = .{ .entity = turned, .response = .{ .mobility = .static, .mode = .trigger, .restitution = 0 } } }});
    try std.testing.expectEqual(@as(usize, 1), fixture.patched.trigger_store.pair_count);
}

test "collision trigger patch of a solid turned trigger on an empty store matches a rebuild" {
    try expectEmptyStoreTurnedTriggerPatch(0);
    try expectEmptyStoreTurnedTriggerPatch(2);
}

fn expectIndexReusePatch(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const doomed = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 400, .y = 400, .w = 40, .h = 40 }, .static, .solid);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    const reborn = math.Vec2{ .x = 410, .y = 410 };
    try fixture.commit(&data, &.{
        .{ .destroy_entity = doomed },
        .{ .create_entity = .{
            .movement_body = .{ .position = reborn, .previous_position = reborn },
            .collision_bounds = .{ .size = .{ .x = 40, .y = 40 } },
            .collision_response = .{ .mobility = .static, .mode = .trigger, .restitution = 0 },
        } },
    });
    // The create took the destroyed index: one change for it.
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.view().changes.len);
    try std.testing.expectEqual(doomed.index, fixture.colliders.view().changes[0].entity.index);
    // The index reused at the same box and level: one walk serves the old and new parts,
    // the old part drops the pair with the solid at (400,400), and the new one re-inserts it.
    const reborn_id = fixture.colliders.view().changes[0].entity;
    try std.testing.expect(data.isAlive(reborn_id));
    try std.testing.expect(try storesPairNaming(&fixture.patched, reborn_id, null));
    try fixture.commit(&data, &.{
        .{ .destroy_entity = reborn_id },
        .{ .create_entity = .{
            .movement_body = .{ .position = reborn, .previous_position = reborn },
            .collision_bounds = .{ .size = .{ .x = 40, .y = 40 } },
            .collision_response = .{ .mobility = .static, .mode = .trigger, .restitution = 0 },
        } },
    });
    const view = fixture.colliders.view();
    const changes = view.changes;
    try std.testing.expectEqual(@as(usize, 1), changes.len);
    try std.testing.expectEqual(doomed.index, changes[0].entity.index);
    try std.testing.expect(!changes[0].entity.eql(reborn_id));
    try std.testing.expectEqual(changes[0].old.?.level, changes[0].new.?.level);
    try std.testing.expect(std.meta.eql(changes[0].old.?.aabb, viewRowBox(view, view.row_of_index[doomed.index])));
    try std.testing.expect(try storesPairNaming(&fixture.patched, changes[0].entity, null));
}

test "collision trigger patch of a destroy and an index reuse in one commit matches a rebuild" {
    try expectIndexReusePatch(0);
    try expectIndexReusePatch(2);
}

fn expectOverlappingChangedTriggersPatch(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const first = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    const second = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 300, .y = 300, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 320, .y = 290, .w = 40, .h = 40 }, .static, .solid);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    // Both changed triggers keep their pair and meet the lone trigger and the solid.
    try fixture.commit(&data, &.{ movedBody(&data, first, 290, 300), movedBody(&data, second, 310, 310) });
    try fixture.commit(&data, &.{ movedBody(&data, second, 30, 30), movedBody(&data, first, 10, 10) });
}

test "collision trigger patch of two overlapping changed triggers matches a rebuild" {
    try expectOverlappingChangedTriggersPatch(0);
    try expectOverlappingChangedTriggersPatch(2);
}

fn expectStripEdgePatch(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const strip_height = CollisionStrips.default.height;
    // A trigger over two strips whose box ends on the second strip's far edge.
    const edge = try addObstacle(&data, .{ .x = 100, .y = 0, .w = 40, .h = 2 * strip_height }, .static, .trigger);
    // Its a-pair, keyed in its last strip.
    _ = try addObstacle(&data, .{ .x = 120, .y = 2 * strip_height - 1, .w = 20, .h = 20 }, .static, .solid);
    // Touching its far y edge in the next strip: no pair.
    _ = try addObstacle(&data, .{ .x = 110, .y = 2 * strip_height, .w = 20, .h = 20 }, .static, .solid);
    // Its b-pair, a sliver over its min x edge.
    _ = try addObstacle(&data, .{ .x = 60, .y = 10, .w = 40.5, .h = 20 }, .static, .solid);
    // Touching its min x edge: no pair.
    _ = try addObstacle(&data, .{ .x = 60, .y = 40, .w = 40, .h = 10 }, .static, .solid);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    try std.testing.expectEqual(@as(usize, 2), fixture.patched.trigger_store.pair_count);
    try fixture.commit(&data, &.{movedBody(&data, edge, 600, 600)});
    try fixture.commit(&data, &.{movedBody(&data, edge, 100, 0)});
}

test "collision trigger patch of a static whose box ends on a strip edge matches a rebuild" {
    try expectStripEdgePatch(0);
    try expectStripEdgePatch(2);
}

fn expectModeOnlyOverflowPatch(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // A trigger over 80 solids, more than a query's reserved hit rows, and one trigger.
    const columns: usize = 16;
    const rows: usize = 5;
    comptime std.debug.assert(columns * rows > reserved_query_hits);
    for (0..columns * rows) |index| {
        _ = try addObstacle(&data, .{ .x = @as(f32, @floatFromInt(index % columns)) * 32 + 1, .y = @as(f32, @floatFromInt(index / columns)) * 32 + 1, .w = 30, .h = 30 }, .static, .solid);
    }
    _ = try addObstacle(&data, .{ .x = 40, .y = 40, .w = 20, .h = 20 }, .static, .trigger);
    const box = math.Vec2{ .x = @as(f32, @floatFromInt(columns)) * 32, .y = @as(f32, @floatFromInt(rows)) * 32 };
    const turned = try addObstacle(&data, .{ .x = 0, .y = 0, .w = box.x, .h = box.y }, .static, .trigger);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    // Only the mode changes, so one walk serves the change's old and new parts; it outgrows
    // the patch's fresh hit rows, so the range grows its slot and replays.
    try std.testing.expectEqual(@as(usize, 0), fixture.patched.trigger_query_slots.items.len);
    try fixture.commit(&data, &.{.{ .set_collision_response = .{ .entity = turned, .response = .{ .mobility = .static, .mode = .solid, .restitution = 0 } } }});
    try std.testing.expect(fixture.patched.trigger_query_slots.items[0].value.hits.len > reserved_query_hits);
    try fixture.commit(&data, &.{.{ .set_collision_response = .{ .entity = turned, .response = .{ .mobility = .static, .mode = .trigger, .restitution = 0 } } }});
}

test "collision trigger patch of a mode-only change over more partners than a query's reserved hits matches a rebuild" {
    try expectModeOnlyOverflowPatch(0);
    try expectModeOnlyOverflowPatch(2);
}

// A chain of 81 overlapping triggers (80 stored pairs) and 24 dynamics on every third one:
// 104 merged positions in one strip, so 112-, 64- and 16-item ranges give one, two and
// seven ranges. With `dormant`, every third trigger from the second is dormant, so two in
// three stored pairs are filtered, some at range edges.
fn expectEmissionAcrossRanges(dormant: bool) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var chain: [81]EntityId = undefined;
    for (&chain, 0..) |*link, index| {
        link.* = try addObstacle(&data, .{ .x = @as(f32, @floatFromInt(index)) * 12, .y = 0, .w = 16, .h = 16 }, .static, .trigger);
    }
    for (0..24) |index| {
        _ = try addObstacle(&data, .{ .x = @as(f32, @floatFromInt(index)) * 36 + 4, .y = 4, .w = 4, .h = 8, .velocity_x = 1 }, .dynamic, .solid);
    }
    var excluded: std.ArrayList(EntityId) = .empty;
    defer excluded.deinit(std.testing.allocator);
    if (dormant) {
        var index: usize = 1;
        while (index < chain.len) : (index += 3) {
            try data.setSimulationTier(chain[index], .dormant);
            try excluded.append(std.testing.allocator, chain[index]);
        }
    }
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    const all = try filteredReference(&data, .default);
    defer std.testing.allocator.free(all);
    try std.testing.expectEqual(@as(usize, 104), all.len);
    const expected = try contactsNotNamingAny(all, excluded.items);
    defer std.testing.allocator.free(expected);
    for ([_]usize{ 112, 64, 16 }) |items_per_range| {
        for ([_]usize{ 0, 2 }) |workers| {
            var system = CollisionSystem.init(std.testing.allocator);
            defer system.deinit();
            var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
            defer contacts.deinit();
            const stats = try updateView(&system, &data, &contacts, colliders.view(), workers, items_per_range);
            try std.testing.expectEqual(expected.len, stats.contact_count);
            try expectSameContacts(expected, contacts.mergedItems());
        }
    }
}

test "collision trigger emission matches the reference at one, two and seven ranges, with disallowed pairs at range edges" {
    try expectEmissionAcrossRanges(false);
    try expectEmissionAcrossRanges(true);
}

// Two levels, each a chain of 70 overlapping triggers (69 stored pairs: a full page and a
// partial one) and 20 dynamics, every third trigger from the second dormant. Level 1's
// stored pairs and dynamic contacts follow level 0's in key order, so 16-item ranges split,
// count, and page across the level end.
fn expectEmissionAcrossLevels(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var excluded: std.ArrayList(EntityId) = .empty;
    defer excluded.deinit(std.testing.allocator);
    for ([_]u16{ 0, 1 }) |level| {
        for (0..70) |index| {
            const link = try addObstacle(&data, .{ .x = @as(f32, @floatFromInt(index)) * 12, .y = 0, .w = 16, .h = 16, .level = level }, .static, .trigger);
            if (index % 3 != 1) continue;
            try data.setSimulationTier(link, .dormant);
            try excluded.append(std.testing.allocator, link);
        }
        for (0..20) |index| {
            _ = try addObstacle(&data, .{ .x = @as(f32, @floatFromInt(index)) * 40 + 4, .y = 4, .w = 4, .h = 8, .level = level, .velocity_x = 1 }, .dynamic, .solid);
        }
    }
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    const all = try filteredReference(&data, .default);
    defer std.testing.allocator.free(all);
    const expected = try contactsNotNamingAny(all, excluded.items);
    defer std.testing.allocator.free(expected);
    try std.testing.expect(expected.len < all.len);
    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    const stats = try updateView(&system, &data, &contacts, colliders.view(), workers, 16);
    try std.testing.expectEqual(@as(u32, 2 * 69), system.trigger_store.pair_count);
    try std.testing.expectEqual(expected.len, stats.contact_count);
    try expectSameContacts(expected, contacts.mergedItems());
}

test "collision trigger emission across a level end with dynamics on both levels matches the reference" {
    try expectEmissionAcrossLevels(0);
    try expectEmissionAcrossLevels(2);
}

test "collision trigger warm patch allocates nothing on a 2-worker pool" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    for (0..4) |index| {
        const x = @as(f32, @floatFromInt(index)) * 128;
        _ = try addObstacle(&data, .{ .x = x, .y = 0, .w = 40, .h = 40 }, .static, .trigger);
        _ = try addObstacle(&data, .{ .x = x + 20, .y = 20, .w = 40, .h = 40 }, .static, .trigger);
    }
    const solid = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 16, .h = 16 }, .static, .solid);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, 2);
    defer fixture.deinit();
    try fixture.commit(&data, &.{movedBody(&data, solid, 138, 10)});
    try commitCommands(&data, &fixture.colliders, &fixture.threads, &.{movedBody(&data, solid, 10, 10)});
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    setTestAllocator(&fixture.patched, failing.allocator());
    defer setTestAllocator(&fixture.patched, std.testing.allocator);
    try fixture.patched.syncCommittedTriggers(&data, fixture.colliders.view(), &fixture.threads);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(fixture.colliders.view().revision, fixture.patched.trigger_store.seen_revision);
}

test "collision trigger rebuild releases its row-pool query records and keeps the patch query's" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const moved = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40 }, .static, .trigger);
    // More rows than one range, so the rebuild query runs over several.
    for (0..3 * collision_range_alignment_items) |index| {
        _ = try addObstacle(&data, .{ .x = 200 + @as(f32, @floatFromInt(index)) * 20, .y = 600, .w = 8, .h = 8 }, .static, .solid);
    }
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, 2);
    defer fixture.deinit();
    // No patch has run: the cold rebuild keeps no query slot.
    try std.testing.expectEqual(@as(usize, 0), fixture.patched.trigger_query_slots.items.len);
    try fixture.commit(&data, &.{movedBody(&data, moved, 20, 20)});
    const patch_slots = fixture.patched.trigger_query_slots.items.len;
    try std.testing.expect(patch_slots != 0);
    // Two commits with no seam refresh skip a revision, so the next refresh rebuilds.
    try commitCommands(&data, &fixture.colliders, &fixture.threads, &.{movedBody(&data, moved, 10, 10)});
    try commitCommands(&data, &fixture.colliders, &fixture.threads, &.{movedBody(&data, moved, 20, 20)});
    try fixture.patched.syncCommittedTriggers(&data, fixture.colliders.view(), &fixture.threads);
    try std.testing.expectEqual(fixture.colliders.view().revision, fixture.patched.trigger_store.seen_revision);
    try std.testing.expectEqual(patch_slots, fixture.patched.trigger_query_slots.items.len);
    for (fixture.patched.trigger_query_slots.items) |padded| {
        try std.testing.expect(padded.value.inserts.capacity <= padded.value.insert_pages.capacity);
    }
    // The next patch re-reserves its records and still matches a rebuild.
    try fixture.commit(&data, &.{movedBody(&data, moved, 10, 10)});
}

test "collision trigger seam that rebuilt holds no patch batches, and the next seam's patch records its changes" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const moved = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40 }, .static, .trigger);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, 0);
    defer fixture.deinit();
    const patched = &fixture.patched;
    // A seam patch fills the patch batches.
    try commitCommands(&data, &fixture.colliders, &fixture.threads, &.{movedBody(&data, moved, 20, 20)});
    try patched.syncCommittedTriggers(&data, fixture.colliders.view(), &fixture.threads);
    try std.testing.expect(patched.trigger_query_batch.item_count != 0);
    // Two commits with no seam refresh skip a revision, so the next seam rebuilds over a
    // nonempty row pool.
    try commitCommands(&data, &fixture.colliders, &fixture.threads, &.{movedBody(&data, moved, 10, 10)});
    try commitCommands(&data, &fixture.colliders, &fixture.threads, &.{movedBody(&data, moved, 20, 20)});
    const rebuild_view = fixture.colliders.view();
    try std.testing.expect(rebuild_view.row_entity.len != 0);
    try patched.syncCommittedTriggers(&data, rebuild_view, &fixture.threads);
    try std.testing.expectEqual(rebuild_view.revision, patched.trigger_store.seen_revision);
    try std.testing.expectEqual(@as(usize, 0), patched.trigger_query_batch.item_count);
    try std.testing.expectEqual(rebuild_view.row_entity.len, patched.trigger_rebuild_query_batch.item_count);
    for (patched.trigger_store.last_batches.values) |batch| try std.testing.expectEqual(@as(usize, 0), batch.item_count);
    // One commit later the seam patches, and its query batch covers exactly the changes.
    try commitCommands(&data, &fixture.colliders, &fixture.threads, &.{movedBody(&data, moved, 10, 10)});
    const patch_view = fixture.colliders.view();
    try std.testing.expect(patch_view.changes.len != 0);
    try patched.syncCommittedTriggers(&data, patch_view, &fixture.threads);
    try std.testing.expectEqual(patch_view.changes.len, patched.trigger_query_batch.item_count);
}

fn expectPatchFailuresKeepStore(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const trigger = try addObstacle(&data, .{ .x = 10, .y = 10, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 30, .y = 30, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 300, .y = 300, .w = 40, .h = 40 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 320, .y = 320, .w = 40, .h = 40 }, .static, .solid);
    var fixture: TriggerPatchFixture = undefined;
    try fixture.init(&data, workers);
    defer fixture.deinit();
    const revision = fixture.patched.trigger_store.seen_revision;
    try commitCommands(&data, &fixture.colliders, &fixture.threads, &.{movedBody(&data, trigger, 290, 290)});
    const view = fixture.colliders.view();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const before = try storedPairs(&fixture.patched, arena);
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        setTestAllocator(&fixture.patched, failing.allocator());
        const result = fixture.patched.syncCommittedTriggers(&data, view, &fixture.threads);
        setTestAllocator(&fixture.patched, std.testing.allocator);
        if (result) |_| break else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(revision, fixture.patched.trigger_store.seen_revision);
        const after = try storedPairs(&fixture.patched, arena);
        try std.testing.expectEqual(before.pairs.len, after.pairs.len);
        for (before.pairs, after.pairs) |kept, now| {
            try std.testing.expectEqual(kept.key, now.key);
            try std.testing.expect(kept.contact.a.eql(now.contact.a) and kept.contact.b.eql(now.contact.b));
        }
        try std.testing.expectEqualSlices(u8, before.emit, after.emit);
    }
    // The sweep reached the patch's allocations, then the retry patched.
    try std.testing.expect(fail_index > 0);
    try std.testing.expectEqual(view.revision, fixture.patched.trigger_store.seen_revision);
    try updateOn(&fixture.patched, &data, &fixture.contacts, view, &fixture.threads, workers);
    var rebuilt = CollisionSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    var rebuilt_contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer rebuilt_contacts.deinit();
    try updateOn(&rebuilt, &data, &rebuilt_contacts, view, &fixture.threads, workers);
    try expectSameTriggerPairs(&rebuilt, &fixture.patched);
    try expectSameContacts(rebuilt_contacts.mergedItems(), fixture.contacts.mergedItems());
}

test "collision trigger patch under every allocation failure leaves the stored pairs unchanged, and the retry matches a rebuild" {
    try expectPatchFailuresKeepStore(0);
    try expectPatchFailuresKeepStore(2);
}

test "collision trigger store rebuilds when the strip height changes" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Pairs whose larger min_y lies in different strips at 32 and 16 units.
    _ = try addObstacle(&data, .{ .x = 0, .y = 0, .w = 40, .h = 60 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 20, .y = 20, .w = 40, .h = 40 }, .static, .solid);
    _ = try addObstacle(&data, .{ .x = 10, .y = 40, .w = 20, .h = 20 }, .static, .trigger);
    _ = try addObstacle(&data, .{ .x = 4, .y = 50, .w = 8, .h = 8 }, .dynamic, .solid);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    for ([_]CollisionStrips{ .default, .ofTileSize(16), .default }) |strips| {
        _ = try system.update(&data, &contacts, &threads, .{ .static_colliders = colliders.view(), .strips = strips });
        const expected = try filteredReference(&data, strips);
        defer std.testing.allocator.free(expected);
        try expectSameContacts(expected, contacts.mergedItems());
    }
}

test "collision trigger a-run key range holds exactly its a-run's keys" {
    const run = bodyRunKey(100, 40, 7);
    const below = bodyRunKey(100, 40, 6);
    const above = bodyRunKey(100.5, 40, 0);
    const range = keyRangeOfARun(3, 5, run);
    for ([_]u128{ 0, bodyRunKey(-50, 0, 0), run, above, std.math.maxInt(u128) }) |b| {
        const key = contactOrderKey(3, 5, run, b);
        try std.testing.expect(range[0] <= key and key <= range[1]);
    }
    for ([_]u256{
        contactOrderKey(3, 5, below, std.math.maxInt(u128)),
        contactOrderKey(3, 5, above, 0),
        contactOrderKey(3, 4, run, std.math.maxInt(u128)),
        contactOrderKey(3, 6, run, 0),
        contactOrderKey(2, strip_count - 1, run, std.math.maxInt(u128)),
        contactOrderKey(4, 0, run, 0),
    }) |key| try std.testing.expect(key < range[0] or key > range[1]);
    try std.testing.expectEqual(@as(u32, 5), keyStrip(range[0]));
    try std.testing.expectEqual(@as(u16, 3), collision_triggers.keyLevel(range[1]));
}

// The Debug rect reserve's own bytes on a system reserved for as many bodies, so the
// static query slots' walked-id capacity is in place before it.
fn debugRectReserveBytes(index_count: usize) !usize {
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var system = CollisionSystem.init(counting.allocator());
    defer system.deinit();
    try system.reserve(index_count);
    const before = counting.allocated_bytes;
    try system.reserveDebugRects(index_count);
    return counting.allocated_bytes - before;
}

test "the debug rect reserve grows linearly in the collider index space" {
    const small: usize = 256;
    const large: usize = 16 * small;
    const small_bytes = try debugRectReserveBytes(small);
    const large_bytes = try debugRectReserveBytes(large);
    if (comptime builtin.mode != .debug) {
        try std.testing.expectEqual(@as(usize, 0), large_bytes);
        return;
    }
    try std.testing.expect(small_bytes > 0);
    // 16 times the indices costs at most twice the bytes per index (geometric list slack).
    try std.testing.expect(large_bytes * small <= 2 * small_bytes * large);
}

test "reserve gives each static query slot one query's hit rows, not its range's pairs" {
    const bodies: usize = 64 * collision_range_alignment_items;
    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(bodies);
    const ranges = maxRangeCount(bodies, collision_range_alignment_items);
    try std.testing.expect(system.static_pair_slots.items.len >= ranges);
    for (system.static_pair_slots.items[0..ranges], 0..) |slot, range_index| {
        try std.testing.expect(slot.value.hits.len <= reserved_query_hits);
        try std.testing.expect(slot.value.hits.len <= slot.value.pairs.capacity);
        // The pairs keep the range's bound, so the one-range slot still holds every body's.
        if (range_index == 0) try std.testing.expect(slot.value.pairs.capacity >= CollisionSystem.broadphasePairBound(bodies));
    }
}

fn expectWideQueryReplays(workers: usize) !void {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // Six rows of 16 statics; the wide dynamic first covers five rows, more than a slot's
    // reserved hit rows.
    const columns: usize = 16;
    const rows: usize = 6;
    for (0..columns * rows) |index| {
        _ = try addObstacle(&data, .{ .x = @as(f32, @floatFromInt(index % columns)) * 32, .y = @as(f32, @floatFromInt(index / columns)) * 32, .w = 32, .h = 32 }, .static, .solid);
    }
    const wide = try addObstacle(&data, .{ .x = 1, .y = 1, .w = @as(f32, @floatFromInt(columns)) * 32 - 2, .h = @as(f32, @floatFromInt(rows - 1)) * 32 - 2 }, .dynamic, .solid);
    // A second dynamic, so the sweep and its pair-bound check run after the query.
    _ = try addObstacle(&data, .{ .x = 1500, .y = 1500, .w = 8, .h = 8 }, .dynamic, .solid);
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    defer colliders.deinit();
    try colliders.rebuild(&data, testGeometry(), null);
    const expected = try filteredReference(&data, .default);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqual(columns * (rows - 1), expected.len);
    try std.testing.expect(expected.len > reserved_query_hits);

    var system = CollisionSystem.init(std.testing.allocator);
    defer system.deinit();
    // The slots' pairs and Debug walked ids hold both steps; only the hit rows outgrow
    // their reserve.
    try system.reserve(256);
    try std.testing.expect(system.static_pair_slots.items[0].value.hits.len < expected.len);
    var contacts = RangeOutputStream(CollisionContact).init(std.testing.allocator);
    defer contacts.deinit();
    _ = try updateView(&system, &data, &contacts, colliders.view(), workers, null);
    try expectSameContacts(expected, contacts.mergedItems());

    // Half a tile down, the query reads one more row of statics. Growth past the first need
    // already holds it: the wider step allocates nothing and matches its reference.
    const body = data.movementBodyDenseIndex(wide).?;
    data.movementBodySlice().position_y[body] += 16;
    data.movementBodySlice().previous_y[body] += 16;
    const widened = try filteredReference(&data, .default);
    defer std.testing.allocator.free(widened);
    try std.testing.expectEqual(columns * rows, widened.len);
    const allocator = system.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    defer system.allocator = allocator;
    _ = try updateView(&system, &data, &contacts, colliders.view(), workers, null);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try expectSameContacts(widened, contacts.mergedItems());
}

test "a static query past its reserved hit rows grows its slot and replays to the reference" {
    try expectWideQueryReplays(0);
    try expectWideQueryReplays(2);
}
