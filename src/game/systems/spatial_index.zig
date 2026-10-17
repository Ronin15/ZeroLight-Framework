// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The shared neighbor index: one per pipeline, built each step from a handed population
//! and read by every neighbor query that step. Slot k of the population is its row; a slot
//! whose entity has no movement body holds no entry.
//!
//! Cells tile the world's chunk grid, every cell in one chunk; positions outside the grid
//! clamp to its edge cells. Entries are sorted by (level, chunk_y, chunk_x, faction,
//! local_y, local_x, slot).
//!
//! A query reads one level and a faction set and visits (cell row, chunk, faction, cell_x,
//! slot). Each run, a (piece, faction)'s cells inside the box, is scanned in lane groups
//! from its first entry, so an entry's lane is its position in the run mod 4; consumers
//! that sum floats follow this order. Every structure the view exposes is identical for any
//! partition of the build.
//!
//! Collision broadphase keeps its own sweep-and-prune order and does not use this index.

const std = @import("std");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const pdqSort = @import("../../core/sort.zig").pdq;
const shl = simd.shiftLeftUint4;
const builtin = @import("builtin");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const inlineBatch = @import("../../app/thread_system.zig").inlineBatch;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const setRowCount = @import("../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const Faction = @import("../data_system.zig").Faction;
const FactionSet = @import("../faction.zig").FactionSet;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const WorldSystem = @import("../world/system.zig").WorldSystem;

pub const spatial_index_range_alignment_items: usize = movement_range_alignment_items;

// Partition width of the threaded build, not a capacity: the index is the same for any
// band count and splitters, and a range's band histogram stays on the worker stack.
const band_count: usize = 64;
// Population slots sampled per step for the band splitters: four per band, a fixed count.
// Balance only.
const splitter_sample_count: usize = 4 * band_count;
// The golden ratio's fractional part in 0.64 fixed point.
const sample_fraction_step: u64 = 0x9E3779B97F4A7C15;

// The most cells per chunk edge: a row part's cells are one 64-bit mask. A format width,
// never a refusal: a finer configured cell gets a coarser effective one.
const max_cells_per_chunk: u32 = 64;

/// The rows one build indexes: slot k is `entities[rows[k]]`, or `entities[k]` without
/// `rows`. Read during the build only.
pub const IndexPopulation = struct {
    entities: []const EntityId,
    rows: ?[]const u32 = null,

    fn len(self: IndexPopulation) usize {
        return if (self.rows) |rows| rows.len else self.entities.len;
    }

    fn entity(self: IndexPopulation, slot: usize) EntityId {
        return self.entities[if (self.rows) |rows| rows[slot] else slot];
    }
};

/// The world chunk grid an index tiles: `chunks_x` x `chunks_y` chunks of
/// `chunk_size_tiles` tiles of `tile_size` world units, on `level_count` levels.
pub const IndexGeometry = struct {
    /// Finite and positive.
    tile_size: f32,
    /// At least 1.
    chunk_size_tiles: u16,
    /// At least 1 each.
    chunks_x: u32,
    chunks_y: u32,
    level_count: usize,

    /// `world`'s chunk grid over its extent and its levels. A world before its first level
    /// still has its extent: the index grows a directory for any level a body is on.
    pub fn ofWorld(world: *const WorldSystem) IndexGeometry {
        const chunk_tiles: u32 = @max(world.chunk_size_tiles, 1);
        return .{
            .tile_size = world.tile_size,
            .chunk_size_tiles = @intCast(chunk_tiles),
            // Ceiling divisions of u16 sides, so each is at most its side.
            .chunks_x = @max((@as(u32, world.width) + chunk_tiles - 1) / chunk_tiles, 1),
            .chunks_y = @max((@as(u32, world.height) + chunk_tiles - 1) / chunk_tiles, 1),
            .level_count = world.levelCount(),
        };
    }
};

// An index's cell grid over its geometry's chunks: K = `cells_per_chunk` cells per chunk
// edge, each `cell_size` wide.
const Grid = struct {
    cells_per_chunk: u32 = 1,
    cell_size: f32 = 1,
    chunks_x: u32 = 0,
    chunks_y: u32 = 0,
    cells_x: u32 = 0,
    cells_y: u32 = 0,

    // K is the configured cell's count per chunk width, rounded, in [1, 64] and at most
    // maxInt(i32) cells per axis, so the lane cell math stays in i32; no geometry is refused.
    fn of(geometry: IndexGeometry, configured_cell_size: f32) Grid {
        std.debug.assert(std.math.isFinite(geometry.tile_size) and geometry.tile_size > 0);
        std.debug.assert(geometry.chunk_size_tiles >= 1 and geometry.chunks_x >= 1 and geometry.chunks_y >= 1);
        const chunk_world = geometry.tile_size * @as(f32, @floatFromInt(geometry.chunk_size_tiles));
        const widest: u32 = @max(geometry.chunks_x, geometry.chunks_y);
        const cells_cap: u32 = @intCast(@min(max_cells_per_chunk, std.math.maxInt(i32) / widest));
        // `lossyCast` saturates a huge or non-finite ratio before the clamp.
        const rounded: u32 = std.math.lossyCast(u32, @round(chunk_world / configured_cell_size));
        const cells_per_chunk = std.math.clamp(rounded, 1, @max(cells_cap, 1));
        return .{
            .cells_per_chunk = cells_per_chunk,
            .cell_size = chunk_world / @as(f32, @floatFromInt(cells_per_chunk)),
            .chunks_x = geometry.chunks_x,
            .chunks_y = geometry.chunks_y,
            .cells_x = geometry.chunks_x * cells_per_chunk,
            .cells_y = geometry.chunks_y * cells_per_chunk,
        };
    }

    fn chunkCount(self: Grid) usize {
        return @as(usize, self.chunks_x) * self.chunks_y;
    }
};

pub const SpatialIndexConfig = struct {
    /// World-unit side of one cell, finite and positive; the effective cell is the nearest
    /// whole fraction of a chunk's width. A query's scan radius in cells derives from it.
    cell_size: f32 = 32.0,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

const StageThreads = @import("../../app/thread_system.zig").StageThreads(SpatialIndexConfig);

/// One four-entry batch of a query's scan: entry `first + lane` at each lane. Lanes set in
/// `inside` are entries of the query's level and factions, strictly inside its radius, within
/// its check budget, and never `self`; every other lane holds any value. `dx, dy` is the query
/// point minus the entry's position and `dist2` is `dx * dx + dy * dy`, bit for bit.
pub const NeighborLanes = struct {
    first: u32,
    x: simd.Float4,
    y: simd.Float4,
    dx: simd.Float4,
    dy: simd.Float4,
    dist2: simd.Float4,
    inside: simd.MaskBits,
};

/// A lane visit's answer: null keeps scanning; a lane set in `inside` ends the query after
/// that lane's entry, which counts as its last check.
pub const LaneStop = ?simd.LaneIndex;

/// `pass` cut to its lowest `room` set lanes, and the stop at the last kept lane when that
/// fills `room`: every consumer's visit cap.
pub const LaneCap = struct { pass: simd.MaskBits, stop: LaneStop };

/// `room` is at least 1.
pub fn capLanes(pass: simd.MaskBits, room: usize) LaneCap {
    std.debug.assert(room >= 1);
    const kept = simd.keepLowestSetBits(pass, room);
    return .{ .pass = kept, .stop = if (@popCount(pass) >= room) std.math.log2_int(simd.MaskBits, kept) else null };
}

pub const NeighborQueryStats = struct {
    candidate_checks: u16 = 0,
};

/// One neighbor query: the entries on `level` of a faction in `factions` strictly within
/// `radius` of `(x, y)`, visited in scan order (see the module doc). Every scanned entry of
/// that level and those factions but `self` counts as a candidate check before its radius
/// test; the scan stops before the check that would pass `max_candidate_checks`.
pub const NeighborQuery = struct {
    x: f32,
    y: f32,
    level: u16,
    /// Finite and at least 0.
    radius: f32,
    max_candidate_checks: u16,
    factions: FactionSet = .full,
    /// Skipped without counting as a candidate wherever the scan meets its entry in the piece
    /// (cell row, chunk) holding `(x, y)` on `level`; indexed anywhere else it is a candidate.
    self: EntityId = EntityId.invalid,
};

pub const SpatialIndexStats = struct {
    /// Entries built: the population's slots with a movement body.
    entity_count: usize = 0,
    bucket_batch: BatchStats = .{},
    sort_batch: BatchStats = .{},
    link_batch: BatchStats = .{},
};

comptime {
    // The key's faction field is two bits wide.
    std.debug.assert(FactionSet.len <= 4);
}

/// One step's built index, read-only. Valid until the next build or reserve of its system.
pub const SpatialIndexView = struct {
    /// Entry-order columns: a visit's entry index reads them.
    x: []const f32,
    y: []const f32,
    entity_index: []const u32,
    entity_generation: []const u32,
    // Each populated cell's first entry in key order, then the entry count: cell c's entries
    // are `[cells[c], cells[c + 1])`.
    cells: []const u32,
    rows: []const RowPart,
    chunk_records: []const ChunkRecord,
    level_slots: []const []ChunkSlot,
    build_stamp: u64,
    // The factions with an entry.
    factions: FactionSet,
    cell_size: f32,
    cells_per_chunk: u32,
    chunks_x: u32,
    cells_x: u32,
    cells_y: u32,

    /// The entity indexed at `entry`.
    pub fn entityAt(self: SpatialIndexView, entry: u32) EntityId {
        return .{ .index = self.entity_index[entry], .generation = self.entity_generation[entry] };
    }

    pub fn entryCount(self: SpatialIndexView) usize {
        return self.x.len;
    }

    /// Visits `query`'s neighbors in scan order through `visitor`, a pointer to a value with
    /// `visitLanes(*const NeighborLanes) LaneStop`, where `dx, dy` is the query point minus
    /// the entry's position. A stop ends the whole query.
    pub fn queryNeighbors(self: SpatialIndexView, query: NeighborQuery, visitor: anytype) NeighborQueryStats {
        std.debug.assert(std.math.isFinite(query.radius) and query.radius >= 0);
        const wanted = query.factions.bits.intersectWith(self.factions.bits);
        if (wanted.mask == 0 or query.level >= self.level_slots.len) return .{};
        const slots = self.level_slots[query.level];
        const cells_per_chunk = self.cells_per_chunk;
        const scan_radius: i64 = cellScanRadius(query.radius, self.cell_size);
        const own_x = math.worldPosToCell(query.x, self.cell_size, self.cells_x);
        const own_y = math.worldPosToCell(query.y, self.cell_size, self.cells_y);
        // Widened, clamped to the grid, then narrowed.
        const min_x: u32 = @intCast(@max(@as(i64, own_x) - scan_radius, 0));
        const max_x: u32 = @intCast(@min(@as(i64, own_x) + scan_radius, @as(i64, self.cells_x) - 1));
        const min_y: u32 = @intCast(@max(@as(i64, own_y) - scan_radius, 0));
        const max_y: u32 = @intCast(@min(@as(i64, own_y) + scan_radius, @as(i64, self.cells_y) - 1));
        const self_index = if (query.self.isValid()) query.self.index else no_entry;
        var scan = Scan{
            .x = self.x,
            .y = self.y,
            .entity_index = self.entity_index,
            .entity_generation = self.entity_generation,
            .query_x = query.x,
            .query_y = query.y,
            .lane_x = simd.splatFloat4(query.x),
            .lane_y = simd.splatFloat4(query.y),
            .lane_radius2 = simd.splatFloat4(query.radius * query.radius),
            .cap = query.max_candidate_checks,
            .self_index = self_index,
            .self_generation = query.self.generation,
            .lane_self = simd.splatUint4(self_index),
        };
        // Self is compared only in the piece holding the query point.
        const self_chunk_x: u32 = if (query.self.isValid()) own_x / cells_per_chunk else std.math.maxInt(u32);
        const first_chunk_x = min_x / cells_per_chunk;
        const last_chunk_x = max_x / cells_per_chunk;
        const first_lo: u32 = min_x % cells_per_chunk;
        const last_hi: u32 = max_x % cells_per_chunk;
        var chunk_y = min_y / cells_per_chunk;
        var local_y = min_y % cells_per_chunk;
        var cell_y = min_y;
        // Scalar: per piece and per present faction, dependent directory, record, and row
        // loads with popcounts, and no uniform float work; the runs go to `visitRun`.
        while (cell_y <= max_y) : (cell_y += 1) {
            const row_slots = slots[@as(usize, chunk_y) * self.chunks_x ..];
            // local_y < cells_per_chunk <= 64.
            const row_bit = @as(u64, 1) << @intCast(local_y);
            var chunk_x = first_chunk_x;
            while (chunk_x <= last_chunk_x) : (chunk_x += 1) {
                const slot = &row_slots[chunk_x];
                if (slot.build != self.build_stamp) continue;
                const present = slot.factions.bits.intersectWith(wanted);
                if (present.mask == 0) continue;
                const record = &self.chunk_records[slot.record];
                const lo: u32 = if (chunk_x == first_chunk_x) first_lo else 0;
                const hi: u32 = if (chunk_x == last_chunk_x) last_hi else cells_per_chunk - 1;
                const span = spanBits(lo, hi);
                const own_piece = cell_y == own_y and chunk_x == self_chunk_x;
                var factions = present.iterator(.{});
                while (factions.next()) |faction| {
                    const row_mask = record.row_masks[faction];
                    if (row_mask & row_bit == 0) continue;
                    const row = &self.rows[record.first_rows[faction] + @popCount(row_mask & (row_bit - 1))];
                    const count = @popCount(row.cells & span);
                    if (count == 0) continue;
                    const first = row.first_cell + @popCount(row.cells & bitsBelow(lo));
                    if (visitRun(&scan, self.cells[first], self.cells[first + count], own_piece, visitor)) return .{ .candidate_checks = scan.checks };
                }
            }
            local_y += 1;
            if (local_y == cells_per_chunk) {
                local_y = 0;
                chunk_y += 1;
            }
        }
        return .{ .candidate_checks = scan.checks };
    }
};

// No entry: never inside a run, since entries are below maxInt(u32), and never an indexed
// entity's index.
const no_entry: u32 = std.math.maxInt(u32);

// A query's per-query constants and its running check count, shared by pointer with the
// run visit.
const Scan = struct {
    x: []const f32,
    y: []const f32,
    entity_index: []const u32,
    entity_generation: []const u32,
    // A masked final batch's fill.
    query_x: f32,
    query_y: f32,
    lane_x: simd.Float4,
    lane_y: simd.Float4,
    lane_radius2: simd.Float4,
    cap: u16,
    checks: u16 = 0,
    // Self's entity index until the scan meets it, then `no_entry`.
    self_index: u32,
    self_generation: u32,
    lane_self: simd.Uint4,
};

// Entries `[start, end)` of one run in lane batches from `start`, each but self one candidate
// check up to the budget; past the column's end the last batch is filled and masked. Self is
// compared in `own_piece`'s runs only. Returns true on a stop, or with the budget spent before
// the run's end, which ends the query.
fn visitRun(scan: *Scan, start: u32, end: u32, own_piece: bool, visitor: anytype) bool {
    std.debug.assert(start <= end and end <= scan.x.len);
    var limit: usize = @min(end, @as(usize, start) + (scan.cap - scan.checks));
    var entry: usize = start;
    while (entry < limit) : (entry += simd.lane_count) {
        const x = simd.loadFloat4OrFill(scan.x[entry..], scan.query_x);
        const y = simd.loadFloat4OrFill(scan.y[entry..], scan.query_y);
        var self_bits: simd.MaskBits = 0;
        if (own_piece and scan.self_index != no_entry) {
            // Lanes past the run belong to another run.
            self_bits = simd.equalUint4Bits(simd.loadUint4OrFill(scan.entity_index[entry..], no_entry), scan.lane_self) & simd.lanesBelow(end - entry);
            if (self_bits != 0) {
                scan.self_index = no_entry;
                const self_entry = entry + @ctz(self_bits);
                if (scan.entity_generation[self_entry] != scan.self_generation) {
                    self_bits = 0;
                } else if (self_entry < limit) {
                    // Self costs no check, so the budget reaches one entry further.
                    limit = @min(end, limit + 1);
                }
            }
        }
        const counted = simd.lanesBelow(limit - entry) & ~self_bits;
        const dx = simd.subFloat4(scan.lane_x, x);
        const dy = simd.subFloat4(scan.lane_y, y);
        const dist2 = simd.lengthSquared2Float4(dx, dy);
        const inside = simd.lessThanFloat4Bits(dist2, scan.lane_radius2) & counted;
        const before = scan.checks;
        // At most the budget's remainder, a u16.
        scan.checks += @popCount(counted);
        if (inside == 0) continue;
        // Entries are below maxInt(u32).
        const lanes = NeighborLanes{ .first = @intCast(entry), .x = x, .y = y, .dx = dx, .dy = dy, .dist2 = dist2, .inside = inside };
        if (visitor.visitLanes(&lanes)) |stop| {
            std.debug.assert(inside >> stop & 1 != 0);
            scan.checks = before + @popCount(counted & simd.lanesBelow(@as(usize, stop) + 1));
            return true;
        }
    }
    return limit < end;
}

// A row part's bits below local cell `lo`, a plain shift.
fn bitsBelow(lo: u32) u64 {
    std.debug.assert(lo < max_cells_per_chunk);
    return (@as(u64, 1) << @intCast(lo)) - 1;
}

// A row part's bits of local cells `lo` to `hi`, as plain shifts: once per piece, where
// `setRangeValue`'s general range checks do not pay.
fn spanBits(lo: u32, hi: u32) u64 {
    std.debug.assert(lo <= hi and hi < max_cells_per_chunk);
    return (~@as(u64, 0) >> @intCast(63 - hi)) & ~bitsBelow(lo);
}

/// One chunk's entry in its level's directory. Valid only when `build` is the view's
/// stamp; its record is `chunk_records[record]`, and `factions` the factions it holds.
pub const ChunkSlot = struct {
    build: u64 = 0,
    record: u32 = 0,
    factions: FactionSet = .empty,
};

/// Bytes of one directory slot: a level's directory is this times its world's chunks.
pub const chunk_slot_bytes: usize = @sizeOf(ChunkSlot);

comptime {
    std.debug.assert(chunk_slot_bytes == 16);
}

// One populated chunk's row parts by faction index f: bit y of `row_masks[f]` is set when
// faction f's row part at local row y exists, and that row part is
// `rows[first_rows[f] + rank(row_masks[f], y)]`. A chunk's faction-f row parts are
// contiguous and ascend by y.
const ChunkRecord = struct {
    row_masks: [FactionSet.len]u64,
    first_rows: [FactionSet.len]u32,
};

comptime {
    std.debug.assert(@sizeOf(ChunkRecord) == 48);
}

// One (chunk, faction, local row)'s populated cells: bit `local_x` of `cells` per cell
// holding an entry. Those cells are `cells[first_cell..][0..popCount(cells)]` of the view,
// in local_x order, and their entries one contiguous run.
const RowPart = struct {
    cells: u64,
    first_cell: u32,
};

comptime {
    std.debug.assert(@sizeOf(RowPart) == 16);
}

// An entry's sort key, packed high to low: level:16 | chunk_y:32 | chunk_x:32 | faction:2 |
// local_y:6 | local_x:6 | slot:32. Total over a build, since slots are distinct; a cell, a
// row part, a (chunk, faction), and a chunk are each a contiguous key range.
const SortKey = u128;
const key_cell_shift = 32;
const key_row_shift = 38;
const key_faction_shift = 44;
const key_chunk_shift = 46;
const key_chunk_y_shift = 78;
const key_level_shift = 110;
// The largest key; splitters at it leave the bands after them empty.
const max_key: SortKey = std.math.maxInt(SortKey);

fn packKey(level: u16, chunk_x: u32, chunk_y: u32, local_x: u32, local_y: u32, faction: usize, slot: u32) SortKey {
    std.debug.assert(local_x < max_cells_per_chunk and local_y < max_cells_per_chunk and faction < 4);
    return (@as(SortKey, level) << key_level_shift) |
        (@as(SortKey, chunk_y) << key_chunk_y_shift) |
        (@as(SortKey, chunk_x) << key_chunk_shift) |
        (@as(SortKey, faction) << key_faction_shift) |
        (@as(SortKey, local_y) << key_row_shift) |
        (@as(SortKey, local_x) << key_cell_shift) |
        slot;
}

// The key's fields by u32 word: word 1 holds local_x up to chunk_x's low bits, word 2
// chunk_x's high bits and chunk_y's low bits, word 3 chunk_y's high bits and the level.
comptime {
    std.debug.assert(key_cell_shift == 32 and key_chunk_shift < 64);
    std.debug.assert(key_chunk_y_shift == key_chunk_shift + 32 and key_chunk_y_shift >= 64 and key_chunk_y_shift < 96);
    std.debug.assert(key_level_shift == key_chunk_y_shift + 32 and key_level_shift >= 96);
}

fn keySlot(key: SortKey) u32 {
    return @truncate(key);
}

fn keyFaction(key: SortKey) usize {
    return @as(u2, @truncate(key >> key_faction_shift));
}

fn keyLocalX(key: SortKey) u32 {
    return @as(u6, @truncate(key >> key_cell_shift));
}

fn keyLocalY(key: SortKey) u32 {
    return @as(u6, @truncate(key >> key_row_shift));
}

fn keyChunkX(key: SortKey) u32 {
    return @truncate(key >> key_chunk_shift);
}

fn keyChunkY(key: SortKey) u32 {
    return @truncate(key >> key_chunk_y_shift);
}

fn keyLevel(key: SortKey) u16 {
    return @truncate(key >> key_level_shift);
}

// One population slot as resolved this build; `entity` is invalid for a slot with no
// movement body.
const SlotRow = struct {
    entity: EntityId,
    x: f32,
    y: f32,
    level: u16,
    faction: Faction,
};

const EntryRow = struct {
    x: f32,
    y: f32,
    entity_index: u32,
    entity_generation: u32,
};

// With a 16-slot range alignment every bucket range's windows start on a cache line.
const SlotRowList = std.array_list.Aligned(SlotRow, .fromByteUnits(thread_shared_record_alignment));
const SortKeyList = std.array_list.Aligned(SortKey, .fromByteUnits(thread_shared_record_alignment));

comptime {
    std.debug.assert(spatial_index_range_alignment_items * @sizeOf(SlotRow) % thread_shared_record_alignment == 0);
    std.debug.assert(spatial_index_range_alignment_items * @sizeOf(SortKey) % thread_shared_record_alignment == 0);
}

// A bucket range's keys before each band: band b's are `[offsets[b], offsets[b + 1])` of its
// staging window.
const BandOffsets = struct {
    offsets: [band_count + 1]u32 = @splat(0),
};

// One sorted band's cells, and its row-part and chunk starts after its first entry: the
// main thread adds whether the first entry starts each.
const BandTally = struct {
    cell_count: u32 = 0,
    row_starts: u32 = 0,
    chunk_starts: u32 = 0,
    factions: FactionSet = .empty,
    max_level: u16 = 0,
};

comptime {
    for ([_]type{ BandOffsets, BandTally }) |T| std.debug.assert(@sizeOf(PaddedSlot(T)) % thread_shared_record_alignment == 0);
}

// The three stages of a threaded build, each under its own tuner.
const BuildStages = struct {
    bucket: Dispatch,
    sort: Dispatch,
    link: Dispatch,
};

pub const SpatialIndexSystem = struct {
    allocator: std.mem.Allocator,
    // By population slot.
    slot_rows: SlotRowList = .empty,
    // Sorted entry keys; a threaded build first fills each bucket range's window of it.
    keys: SortKeyList = .empty,
    // A threaded build's band-ordered bucket windows.
    staging: SortKeyList = .empty,
    entries: std.MultiArrayList(EntryRow) = .{},
    // Sort scratch: band b's cell starts sit in its own slice from its entry start; the rest
    // of the slice is unused.
    band_cells: std.ArrayList(u32) = .empty,
    // Every populated cell's first entry in key order, then the entry count.
    cells: std.ArrayList(u32) = .empty,
    // Every (chunk, faction, local row)'s row part, contiguous in key order.
    rows: std.ArrayList(RowPart) = .empty,
    // Every populated chunk's record, in key order.
    chunk_records: std.ArrayList(ChunkRecord) = .empty,
    // One directory per level, `grid.chunkCount()` slots each.
    level_slots: std.ArrayList([]ChunkSlot) = .empty,
    // The current build's; never wraps.
    build_stamp: u64 = 0,
    grid: Grid = .{},
    // The level count the last `reserveGeometry` covered: never released for an absence of
    // bodies.
    geometry_level_count: usize = 0,
    // The factions with an entry this build.
    factions: FactionSet = .empty,
    band_offsets: SlotList(BandOffsets) = .empty,
    band_tallies: SlotList(BandTally) = .empty,
    bucket_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    sort_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    link_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

    pub fn init(allocator: std.mem.Allocator) SpatialIndexSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SpatialIndexSystem) void {
        self.freeLevels(0);
        self.level_slots.deinit(self.allocator);
        self.band_tallies.deinit(self.allocator);
        self.band_offsets.deinit(self.allocator);
        self.chunk_records.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.cells.deinit(self.allocator);
        self.band_cells.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.staging.deinit(self.allocator);
        self.keys.deinit(self.allocator);
        self.slot_rows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Sizes every build buffer for a population of `capacity` slots under any partition
    /// the tuners can pick, so a build at or below it allocates nothing. Grow-only; the
    /// pipeline calls it at init and at its population seam.
    pub fn reserve(self: *SpatialIndexSystem, capacity: usize) error{OutOfMemory}!void {
        // The u32 widths are exhausted only past maxInt(u32) slots, which the population
        // cannot reach (`beginBuild`); past it this is allocator exhaustion.
        if (capacity > std.math.maxInt(u32)) return error.OutOfMemory;
        try self.slot_rows.ensureTotalCapacity(self.allocator, capacity);
        try self.keys.ensureTotalCapacity(self.allocator, capacity);
        try self.staging.ensureTotalCapacity(self.allocator, capacity);
        try self.entries.ensureTotalCapacity(self.allocator, capacity);
        try self.band_cells.ensureTotalCapacity(self.allocator, capacity);
        // The cell starts and their end sentinel.
        try self.cells.ensureTotalCapacity(self.allocator, capacity + 1);
        try self.rows.ensureTotalCapacity(self.allocator, capacity);
        try self.chunk_records.ensureTotalCapacity(self.allocator, capacity);
        try self.band_offsets.ensureTotalCapacity(self.allocator, maxRangeCount(capacity, spatial_index_range_alignment_items));
        try self.band_tallies.ensureTotalCapacity(self.allocator, band_count);
    }

    // Sizes the level directories for `geometry` at `config`'s cell, so a build of a
    // population on its levels allocates none: no-op when unchanged, released and rebuilt on
    // a grid change, grown to the level count otherwise. A build calls it first on the
    // calling thread; a body on a level past the count gets its directory after the sort.
    fn reserveGeometry(self: *SpatialIndexSystem, geometry: IndexGeometry, config: SpatialIndexConfig) error{OutOfMemory}!void {
        const grid = Grid.of(geometry, config.cell_size);
        if (!std.meta.eql(grid, self.grid)) {
            self.freeLevels(0);
            self.grid = grid;
        }
        self.geometry_level_count = geometry.level_count;
        if (self.level_slots.items.len < geometry.level_count) try self.fitLevels(geometry.level_count);
    }

    /// Bytes the level directories hold.
    pub fn directoryBytes(self: *const SpatialIndexSystem) usize {
        var bytes: usize = 0;
        for (self.level_slots.items) |slots| bytes += slots.len * chunk_slot_bytes;
        return bytes;
    }

    // Grows or shrinks the directories to `level_count` levels, new ones all stale.
    fn fitLevels(self: *SpatialIndexSystem, level_count: usize) error{OutOfMemory}!void {
        self.freeLevels(level_count);
        if (self.level_slots.items.len == level_count) return;
        try self.level_slots.ensureTotalCapacity(self.allocator, level_count);
        while (self.level_slots.items.len < level_count) {
            const slots = try self.allocator.alloc(ChunkSlot, self.grid.chunkCount());
            @memset(slots, .{});
            self.level_slots.appendAssumeCapacity(slots);
        }
    }

    // Frees every directory past the first `keep`.
    fn freeLevels(self: *SpatialIndexSystem, keep: usize) void {
        while (self.level_slots.items.len > keep) self.allocator.free(self.level_slots.pop().?);
    }

    /// The last build's index.
    pub fn view(self: *const SpatialIndexSystem) SpatialIndexView {
        const entries = self.entries.slice();
        return .{
            .x = entries.items(.x),
            .y = entries.items(.y),
            .entity_index = entries.items(.entity_index),
            .entity_generation = entries.items(.entity_generation),
            .cells = self.cells.items,
            .rows = self.rows.items,
            .chunk_records = self.chunk_records.items,
            .level_slots = self.level_slots.items,
            .build_stamp = self.build_stamp,
            .factions = self.factions,
            .cell_size = self.grid.cell_size,
            .cells_per_chunk = self.grid.cells_per_chunk,
            .chunks_x = self.grid.chunks_x,
            .cells_x = self.grid.cells_x,
            .cells_y = self.grid.cells_y,
        };
    }

    /// Builds the index of `population`'s slots from their previous positions over
    /// `geometry`'s grid. Every stage runs on workers under the index's own tuners, or
    /// inline as they select; with no worker available it builds serially. Allocates only
    /// past `reserve`'s capacity or `reserveGeometry`'s directories, on the calling thread
    /// before any dispatch that uses them.
    pub fn build(
        self: *SpatialIndexSystem,
        data: *const DataSystem,
        population: IndexPopulation,
        geometry: IndexGeometry,
        thread_system: *ThreadSystem,
        config: SpatialIndexConfig,
    ) !SpatialIndexStats {
        const slot_count = try self.beginBuild(population, geometry, config);
        if (slot_count == 0) return self.finishEmptyBuild(.{});
        const threads = StageThreads.withWorkers(.{ .thread_system = thread_system, .config = config }) orelse return self.buildDirect(data, population);
        const stages = BuildStages{ .bucket = threads.stage(&self.bucket_tuner), .sort = threads.stage(&self.sort_tuner), .link = threads.stage(&self.link_tuner) };
        return self.buildBanded(data, population, stages, chooseSplitters(data, population, self.grid));
    }

    /// `build` on the calling thread alone.
    pub fn buildSerial(self: *SpatialIndexSystem, data: *const DataSystem, population: IndexPopulation, geometry: IndexGeometry, config: SpatialIndexConfig) !SpatialIndexStats {
        const slot_count = try self.beginBuild(population, geometry, config);
        if (slot_count == 0) return self.finishEmptyBuild(.{});
        return self.buildDirect(data, population);
    }

    // A build with no entries: the directories cut back to the geometry's levels, so levels
    // grown for bodies that are gone are released.
    fn finishEmptyBuild(self: *SpatialIndexSystem, stats: SpatialIndexStats) error{OutOfMemory}!SpatialIndexStats {
        try self.fitLevels(self.geometry_level_count);
        return stats;
    }

    // Starts a new build stamp, so every directory slot of the last build is stale, clears
    // the last build, and sizes every buffer and directory for `population` and `geometry`.
    // Returns its slot count.
    fn beginBuild(self: *SpatialIndexSystem, population: IndexPopulation, geometry: IndexGeometry, config: SpatialIndexConfig) !usize {
        std.debug.assert(std.math.isFinite(config.cell_size) and config.cell_size > 0);
        self.build_stamp += 1;
        self.factions = .empty;
        self.entries.clearRetainingCapacity();
        self.band_cells.clearRetainingCapacity();
        self.cells.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
        self.chunk_records.clearRetainingCapacity();
        try self.reserveGeometry(geometry, config);
        const slot_count = population.len();
        // u32 slots, entries, cells, rows, and records: `createEntity` refuses past maxInt(u32).
        std.debug.assert(slot_count <= std.math.maxInt(u32));
        try self.reserve(slot_count);
        std.debug.assert(self.slot_rows.capacity >= slot_count and self.keys.capacity >= slot_count and self.staging.capacity >= slot_count);
        self.slot_rows.items.len = slot_count;
        self.keys.items.len = slot_count;
        return slot_count;
    }

    // The serial build: one fill straight into the keys, then one band's sort and link.
    fn buildDirect(self: *SpatialIndexSystem, data: *const DataSystem, population: IndexPopulation) !SpatialIndexStats {
        const slot_count = population.len();
        const fill = self.fillContext(data, population);
        // At most slot_count <= maxInt(u32) keys.
        const entry_count: u32 = @intCast(fillSlots(&fill, 0, slot_count, self.keys.items));
        self.setEntryCount(entry_count);
        var band_start: [band_count + 1]u32 = @splat(entry_count);
        band_start[0] = 0;
        var tallies: [band_count]BandTally = @splat(.{});
        if (entry_count != 0) tallies[0] = self.bandWriter().finishBand(0, entry_count);
        var link = try self.prepareLink(band_start, tallies, 1);
        if (tallies[0].cell_count != 0) linkBand(&link, 0);
        return .{
            .entity_count = entry_count,
            .bucket_batch = inlineBatch(slot_count, spatial_index_range_alignment_items),
            .sort_batch = inlineBatch(entry_count, spatial_index_range_alignment_items),
            .link_batch = inlineBatch(tallies[0].cell_count, spatial_index_range_alignment_items),
        };
    }

    // `index_bucket` over the slots into the bands of `splitters` (nondecreasing cell
    // starts), the band starts on the main thread, `index_sort` over the keys, the band
    // prefixes and levels on the main thread, then `index_link` over the cells.
    fn buildBanded(self: *SpatialIndexSystem, data: *const DataSystem, population: IndexPopulation, stages: BuildStages, splitters: [band_count - 1]SortKey) !SpatialIndexStats {
        const slot_count = population.len();
        std.debug.assert(slot_count > 0 and self.slot_rows.items.len == slot_count and self.keys.items.len == slot_count);
        for (splitters[0 .. band_count - 2], splitters[1..]) |lower, upper| std.debug.assert(lower <= upper);
        for (splitters) |splitter| std.debug.assert(splitter == max_key or splitter & cell_low_bits == 0);
        const bucket_selection = stages.bucket.select(slot_count, spatial_index_range_alignment_items);
        std.debug.assert(self.band_offsets.capacity >= bucket_selection.range_count and self.band_tallies.capacity >= band_count);
        self.staging.items.len = slot_count;
        setSlotCount(BandOffsets, &self.band_offsets, bucket_selection.range_count);
        var bucket = BucketJob{
            .fill = self.fillContext(data, population),
            .splitters = splitters,
            .scratch = self.keys.items,
            .staging = self.staging.items,
            .items_per_range = bucket_selection.items_per_range,
            .band_offsets = self.band_offsets.items,
        };
        var stats = SpatialIndexStats{};
        stats.bucket_batch = stages.bucket.run(bucket_selection, slot_count, spatial_index_range_alignment_items, &bucket, bucketJob);

        // Each band's keys start after every range's keys of the earlier bands.
        var band_start: [band_count + 1]u32 = @splat(0);
        for (self.band_offsets.items) |slot| {
            for (&band_start, slot.value.offsets) |*start, range_offset| start.* += range_offset;
        }
        const entry_count = band_start[band_count];
        self.setEntryCount(entry_count);
        setSlotCount(BandTally, &self.band_tallies, band_count);
        stats.entity_count = entry_count;
        if (entry_count == 0) return self.finishEmptyBuild(stats);
        const sort_selection = stages.sort.select(entry_count, spatial_index_range_alignment_items);
        var sort = SortJob{
            .staging = self.staging.items,
            .band_offsets = self.band_offsets.items,
            .bucket_items_per_range = bucket_selection.items_per_range,
            .band_start = band_start,
            .writer = self.bandWriter(),
            .tallies = self.band_tallies.items,
            .range_count = sort_selection.range_count,
        };
        stats.sort_batch = stages.sort.run(sort_selection, entry_count, spatial_index_range_alignment_items, &sort, sortJob);

        var tallies: [band_count]BandTally = undefined;
        for (&tallies, self.band_tallies.items) |*tally, slot| tally.* = slot.value;
        const link_selection = stages.link.select(cellTotal(tallies), spatial_index_range_alignment_items);
        var link = try self.prepareLink(band_start, tallies, link_selection.range_count);
        stats.link_batch = stages.link.run(link_selection, link.cell_prefix[band_count], spatial_index_range_alignment_items, &link, linkJob);
        return stats;
    }

    // The link stage's job over `tallies`' bands at `band_start`, after the sort: the band
    // cell, row-part, and chunk prefixes, the factions, and every level's directory, sized
    // here on the calling thread. Sets the cell, row-part, and record counts and writes the
    // cells' end sentinel. O(bands): two key reads per band.
    fn prepareLink(self: *SpatialIndexSystem, band_start: [band_count + 1]u32, tallies: [band_count]BandTally, range_count: usize) error{OutOfMemory}!LinkJob {
        const keys = self.keys.items;
        var job = LinkJob{
            .keys = keys,
            .band_cells = self.band_cells.items,
            .cells = undefined,
            .rows = undefined,
            .chunk_records = undefined,
            .level_slots = undefined,
            .chunks_x = self.grid.chunks_x,
            .chunk_count = self.grid.chunkCount(),
            .build_stamp = self.build_stamp,
            .band_start = band_start,
            .cell_counts = undefined,
            .cell_prefix = undefined,
            .row_prefix = undefined,
            .chunk_prefix = undefined,
            .range_count = range_count,
        };
        var max_level: u16 = 0;
        job.cell_prefix[0] = 0;
        job.row_prefix[0] = 0;
        job.chunk_prefix[0] = 0;
        for (tallies, 0..) |tally, band| {
            job.cell_counts[band] = tally.cell_count;
            var row_starts = tally.row_starts;
            var chunk_starts = tally.chunk_starts;
            if (tally.cell_count != 0) {
                // The band's first entry starts a row part or chunk unless the entry before it,
                // the last of an earlier band, shares it.
                const first = band_start[band];
                if (first == 0 or keys[first - 1] >> key_row_shift != keys[first] >> key_row_shift) row_starts += 1;
                if (first == 0 or keys[first - 1] >> key_chunk_shift != keys[first] >> key_chunk_shift) chunk_starts += 1;
                max_level = @max(max_level, tally.max_level);
            }
            job.cell_prefix[band + 1] = job.cell_prefix[band] + tally.cell_count;
            job.row_prefix[band + 1] = job.row_prefix[band] + row_starts;
            job.chunk_prefix[band + 1] = job.chunk_prefix[band] + chunk_starts;
            self.factions.setUnion(tally.factions);
        }
        const cell_count = job.cell_prefix[band_count];
        const row_count = job.row_prefix[band_count];
        const chunk_count = job.chunk_prefix[band_count];
        // A level the world lacks gets its directory here; levels past both the world's and
        // the bodies' are released.
        const body_levels: usize = if (cell_count == 0) 0 else @as(usize, max_level) + 1;
        try self.fitLevels(@max(self.geometry_level_count, body_levels));
        std.debug.assert(self.cells.capacity >= cell_count + 1 and self.rows.capacity >= row_count and self.chunk_records.capacity >= chunk_count);
        self.cells.items.len = cell_count + 1;
        self.cells.items[cell_count] = band_start[band_count];
        self.rows.items.len = row_count;
        self.chunk_records.items.len = chunk_count;
        job.cells = self.cells.items;
        job.rows = self.rows.items;
        job.chunk_records = self.chunk_records.items;
        job.level_slots = self.level_slots.items;
        return job;
    }

    fn fillContext(self: *SpatialIndexSystem, data: *const DataSystem, population: IndexPopulation) FillContext {
        return .{
            .population = population,
            .data = data,
            .movement = data.movementBodySliceConst(),
            .grid = self.grid,
            .slot_rows = self.slot_rows.items,
        };
    }

    // Sizes the entry list and the sort's cell scratch for `entry_count` entries, within
    // capacity.
    fn setEntryCount(self: *SpatialIndexSystem, entry_count: u32) void {
        std.debug.assert(self.band_cells.capacity >= entry_count);
        setRowCount(EntryRow, &self.entries, entry_count);
        self.band_cells.items.len = entry_count;
    }

    fn bandWriter(self: *SpatialIndexSystem) BandWriter {
        const entries = self.entries.slice();
        return .{
            .keys = self.keys.items,
            .slot_rows = self.slot_rows.items,
            .entry_x = entries.items(.x),
            .entry_y = entries.items(.y),
            .entry_entity_index = entries.items(.entity_index),
            .entry_entity_generation = entries.items(.entity_generation),
            .band_cells = self.band_cells.items,
        };
    }
};

fn keyLessThan(_: void, lhs: SortKey, rhs: SortKey) bool {
    return lhs < rhs;
}

fn cellTotal(tallies: [band_count]BandTally) usize {
    var total: usize = 0;
    for (tallies) |tally| total += tally.cell_count;
    return total;
}

// ---- Build stages -------------------------------------------------------------

// ceil(radius / cell_size) cells, saturated at maxInt(i32).
fn cellScanRadius(radius: f32, cell_size: f32) i32 {
    return std.math.lossyCast(i32, @ceil(radius / cell_size));
}

// A key's bits below its cell: the slot.
const cell_low_bits: SortKey = (@as(SortKey, 1) << key_cell_shift) - 1;

// The scalar key of a body on `level` at `(x, y)`, clamped to `grid`: bit for bit the lane
// fill's.
fn keyForPosition(grid: Grid, level: u16, x: f32, y: f32, faction: usize, slot: u32) SortKey {
    const cell_x = math.worldPosToCell(x, grid.cell_size, grid.cells_x);
    const cell_y = math.worldPosToCell(y, grid.cell_size, grid.cells_y);
    const per_chunk = grid.cells_per_chunk;
    return packKey(level, cell_x / per_chunk, cell_y / per_chunk, cell_x % per_chunk, cell_y % per_chunk, faction, slot);
}

const FillContext = struct {
    population: IndexPopulation,
    data: *const DataSystem,
    movement: ConstMovementBodySlice,
    grid: Grid,
    // Written at the filled slots only.
    slot_rows: []SlotRow,

    // Scalar: one dense-index point lookup per slot, with a skip.
    fn resolveSlot(self: *const FillContext, slot: usize) SlotRow {
        const entity = self.population.entity(slot);
        const row: SlotRow = if (self.data.bodyLevelFaction(entity)) |found| .{
            .entity = entity,
            .x = self.movement.previous_x[found.movement_body],
            .y = self.movement.previous_y[found.movement_body],
            .level = found.level orelse 0,
            .faction = found.faction orelse .neutral,
        } else .{ .entity = EntityId.invalid, .x = 0, .y = 0, .level = 0, .faction = .neutral };
        self.slot_rows[slot] = row;
        return row;
    }
};

// Resolves slots `[start, end)` into their rows and writes a key to `keys` for each with a
// movement body, in slot order; returns the key count. Clamped cells, their chunk and local
// coordinates, and the key's words in lanes over the packed rows with a scalar tail, bit
// for bit `keyForPosition`.
fn fillSlots(fill: *const FillContext, start: usize, end: usize, keys: []SortKey) usize {
    std.debug.assert(start <= end and end <= fill.slot_rows.len and keys.len >= end - start);
    const grid = fill.grid;
    // At most 64.
    const per_chunk_lanes = simd.splatInt4(@intCast(grid.cells_per_chunk));
    var count: usize = 0;
    var slot = start;
    const vector_end = start + simd.vectorizedEnd(end - start);
    while (slot < vector_end) : (slot += simd.lane_count) {
        var x: [simd.lane_count]f32 = undefined;
        var y: [simd.lane_count]f32 = undefined;
        var level: [simd.lane_count]u32 = undefined;
        var faction: [simd.lane_count]u32 = undefined;
        var valid: [simd.lane_count]bool = undefined;
        inline for (0..simd.lane_count) |lane| {
            const row = fill.resolveSlot(slot + lane);
            x[lane] = row.x;
            y[lane] = row.y;
            level[lane] = row.level;
            // A faction index is below `FactionSet.len` (4).
            faction[lane] = @intCast(FactionSet.Indexer.indexOf(row.faction));
            valid[lane] = row.entity.isValid();
        }
        const cell_x = simd.worldPosToCell4(simd.loadFloat4(&x), grid.cell_size, grid.cells_x);
        const cell_y = simd.worldPosToCell4(simd.loadFloat4(&y), grid.cell_size, grid.cells_y);
        const chunk_x = simd.divInt4(cell_x, per_chunk_lanes);
        const chunk_y = simd.divInt4(cell_y, per_chunk_lanes);
        // Clamped cells are in [0, cells - 1], so every coordinate is non-negative.
        const local_x: simd.Uint4 = @bitCast(simd.subInt4(cell_x, simd.mulInt4(chunk_x, per_chunk_lanes)));
        const local_y: simd.Uint4 = @bitCast(simd.subInt4(cell_y, simd.mulInt4(chunk_y, per_chunk_lanes)));
        const chunk_x_words: simd.Uint4 = @bitCast(chunk_x);
        const chunk_y_words: simd.Uint4 = @bitCast(chunk_y);
        const word1 = shl(local_x, key_cell_shift - 32) | shl(local_y, key_row_shift - 32) |
            shl(simd.loadUint4(&faction), key_faction_shift - 32) | shl(chunk_x_words, key_chunk_shift - 32);
        const word2 = simd.shiftRightUint4(chunk_x_words, 64 - key_chunk_shift) | shl(chunk_y_words, key_chunk_y_shift - 64);
        const word3 = simd.shiftRightUint4(chunk_y_words, 96 - key_chunk_y_shift) | shl(simd.loadUint4(&level), key_level_shift - 96);
        // The key's u32 words store low word first.
        comptime std.debug.assert(builtin.cpu.arch.endian() == .little);
        inline for (0..simd.lane_count) |lane| {
            if (valid[lane]) {
                // A slot is below slot_count <= maxInt(u32).
                keys[count] = @bitCast([4]u32{ @intCast(slot + lane), word1[lane], word2[lane], word3[lane] });
                count += 1;
            }
        }
    }
    while (slot < end) : (slot += 1) {
        const row = fill.resolveSlot(slot);
        if (!row.entity.isValid()) continue;
        // A slot is below slot_count <= maxInt(u32).
        keys[count] = keyForPosition(grid, row.level, row.x, row.y, FactionSet.Indexer.indexOf(row.faction), @intCast(slot));
        count += 1;
    }
    return count;
}

// A key's band among nondecreasing `splitters`: the count at or below it. Splitters sit at
// cell starts, so a cell lies in exactly one band and the bands follow key order.
fn bandOfKey(splitters: *const [band_count - 1]SortKey, key: SortKey) usize {
    return std.sort.partitionPoint(SortKey, splitters, key, splitterAtOrBelow);
}

fn splitterAtOrBelow(key: SortKey, splitter: SortKey) bool {
    return splitter <= key;
}

// `index_bucket`: one range of population slots.
const BucketJob = struct {
    fill: FillContext,
    splitters: [band_count - 1]SortKey,
    // Range r's windows start at `r * items_per_range`.
    scratch: []SortKey,
    staging: []SortKey,
    items_per_range: usize,
    band_offsets: []PaddedSlot(BandOffsets),
};

// Fills the range's keys into its scratch window, then places them in its staging window
// by band, in slot order within a band, and records the band offsets. The band search runs
// twice per key rather than storing each band: scalar, a six-step binary search.
fn bucketJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *BucketJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.band_offsets.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= job.fill.population.len());
    std.debug.assert(range.end <= job.scratch.len and range.end <= job.staging.len and range.end <= job.fill.slot_rows.len);
    const filled = job.scratch[range.start..][0..fillSlots(&job.fill, range.start, range.end, job.scratch[range.start..range.end])];
    var offsets: [band_count + 1]u32 = @splat(0);
    for (filled) |key| offsets[bandOfKey(&job.splitters, key) + 1] += 1;
    for (1..band_count + 1) |band| offsets[band] += offsets[band - 1];
    job.band_offsets[range.index].value.offsets = offsets;
    var cursor = offsets;
    for (filled) |key| {
        const band = bandOfKey(&job.splitters, key);
        job.staging[range.start + cursor[band]] = key;
        cursor[band] += 1;
    }
}

// `index_sort`: one range of entry keys. A range owns every nonempty band that starts in
// it, so each band has one owner and the ranges' work follows their key counts.
const SortJob = struct {
    staging: []const SortKey,
    band_offsets: []const PaddedSlot(BandOffsets),
    bucket_items_per_range: usize,
    // Band b's keys, cell starts, and entries go to `[band_start[b], band_start[b + 1])`.
    band_start: [band_count + 1]u32,
    writer: BandWriter,
    tallies: []PaddedSlot(BandTally),
    range_count: usize,
};

// Each owned band gathers every bucket range's segment of it in range order into its slice
// of the keys, then finishes there.
fn sortJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SortJob = @ptrCast(@alignCast(context));
    const entry_count = job.band_start[band_count];
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= entry_count);
    std.debug.assert(entry_count <= job.writer.keys.len and entry_count <= job.writer.band_cells.len and entry_count <= job.writer.entry_x.len);
    std.debug.assert(job.tallies.len == band_count);
    var band = std.sort.partitionPoint(u32, job.band_start[0..band_count], range.start, startsBefore);
    while (band < band_count and job.band_start[band] < range.end) : (band += 1) {
        const start = job.band_start[band];
        const end = job.band_start[band + 1];
        if (start == end) continue;
        var cursor: usize = start;
        for (job.band_offsets, 0..) |slot, bucket_range| {
            const window = job.staging[bucket_range * job.bucket_items_per_range ..];
            const segment = window[slot.value.offsets[band]..slot.value.offsets[band + 1]];
            @memcpy(job.writer.keys[cursor..][0..segment.len], segment);
            cursor += segment.len;
        }
        std.debug.assert(cursor == end);
        job.tallies[band].value = job.writer.finishBand(start, end);
    }
}

fn startsBefore(range_start: usize, band_start: u32) bool {
    return band_start < range_start;
}

// Writes one band's slice of the sorted keys, cell starts, and entries.
const BandWriter = struct {
    keys: []SortKey,
    slot_rows: []const SlotRow,
    entry_x: []f32,
    entry_y: []f32,
    entry_entity_index: []u32,
    entry_entity_generation: []u32,
    band_cells: []u32,

    // Sorts the band's keys `[start, end)`, writes each (level, cell, faction) run's first
    // entry from `band_cells[start]`, counts the band's row-part and chunk starts after its
    // first entry, and gathers the entries' payload. pdqsort: the key is total, so an
    // unstable sort is exact. Scalar: a comparison sort, run compaction (one key compare per
    // entry, two more per cell), and record copies.
    fn finishBand(self: BandWriter, start: u32, end: u32) BandTally {
        const keys = self.keys[start..end];
        pdqSort(SortKey, keys, {}, keyLessThan);
        var tally = BandTally{};
        var previous_cell: SortKey = keys[0] >> key_cell_shift;
        self.band_cells[start] = start;
        tally.cell_count = 1;
        tally.factions.bits.set(keyFaction(keys[0]));
        for (keys[1..], start + 1..) |key, entry| {
            const cell = key >> key_cell_shift;
            if (cell == previous_cell) continue;
            // entry < end <= maxInt(u32).
            self.band_cells[start + tally.cell_count] = @intCast(entry);
            tally.cell_count += 1;
            tally.factions.bits.set(keyFaction(key));
            // Row-part and chunk bits sit above the cell's local x.
            if (cell >> (key_row_shift - key_cell_shift) != previous_cell >> (key_row_shift - key_cell_shift)) tally.row_starts += 1;
            if (cell >> (key_chunk_shift - key_cell_shift) != previous_cell >> (key_chunk_shift - key_cell_shift)) tally.chunk_starts += 1;
            previous_cell = cell;
        }
        // Keys ascend by level first.
        tally.max_level = keyLevel(keys[keys.len - 1]);

        for (start..end) |index| {
            const row = self.slot_rows[keySlot(self.keys[index])];
            self.entry_x[index] = row.x;
            self.entry_y[index] = row.y;
            self.entry_entity_index[index] = row.entity.index;
            self.entry_entity_generation[index] = row.entity.generation;
        }
        return tally;
    }
};

// `index_link`: one range of cells, counted through the bands' cell prefixes. A range owns
// every nonempty band whose cells start in it, and a band's owner writes every chunk whose
// first cell lies in the band, reading on into later bands for a chunk that continues; a
// chunk therefore has one writer, which writes its cells, row parts, and record at their
// key-order indices and its directory slot.
const LinkJob = struct {
    keys: []const SortKey,
    band_cells: []const u32,
    cells: []u32,
    rows: []RowPart,
    chunk_records: []ChunkRecord,
    level_slots: []const []ChunkSlot,
    chunks_x: u32,
    chunk_count: usize,
    build_stamp: u64,
    // Band b's cell starts are `band_cells[band_start[b]..][0..cell_counts[b]]`.
    band_start: [band_count + 1]u32,
    cell_counts: [band_count]u32,
    // Band b's first cell, row part, and chunk starting in it are the `cell_prefix[b]`-th,
    // `row_prefix[b]`-th, and `chunk_prefix[b]`-th in key order.
    cell_prefix: [band_count + 1]u32,
    row_prefix: [band_count + 1]u32,
    chunk_prefix: [band_count + 1]u32,
    range_count: usize,

    fn cellKey(self: *const LinkJob, cell: u32) SortKey {
        return self.keys[self.band_cells[cell]];
    }
};

fn linkJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *LinkJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.cell_prefix[band_count]);
    std.debug.assert(job.cells.len == job.cell_prefix[band_count] + 1 and job.rows.len == job.row_prefix[band_count] and job.chunk_records.len == job.chunk_prefix[band_count]);
    std.debug.assert(job.band_start[band_count] <= job.band_cells.len);
    var band = std.sort.partitionPoint(u32, job.cell_prefix[0..band_count], range.start, startsBefore);
    while (band < band_count and job.cell_prefix[band] < range.end) : (band += 1) {
        if (job.cell_counts[band] != 0) linkBand(job, band);
    }
}

// The cell after `cell` in key order across the bands from `band`, or null past the last:
// its band and index.
fn nextCell(job: *const LinkJob, band: usize, cell: u32) ?struct { band: usize, cell: u32 } {
    if (cell + 1 < job.band_start[band] + job.cell_counts[band]) return .{ .band = band, .cell = cell + 1 };
    var next = band + 1;
    while (next < band_count) : (next += 1) {
        if (job.cell_counts[next] != 0) return .{ .band = next, .cell = job.band_start[next] };
    }
    return null;
}

// Writes the cells, row parts, record, and directory slot of every chunk whose first cell
// lies in `band`, skipping the leading cells of a chunk an earlier band started. Scalar:
// bit-set compaction over scattered cell starts.
fn linkBand(job: *LinkJob, band: usize) void {
    const band_first = job.band_start[band];
    const band_cells_end = band_first + job.cell_counts[band];
    var cell = band_first;
    var row = job.row_prefix[band];
    var chunk_index = job.chunk_prefix[band];
    // Entries are contiguous across bands: the band continues a chunk when its first entry's
    // chunk is the entry before it's. That chunk's row parts starting here are its owner's.
    if (band_first > 0 and job.keys[band_first] >> key_chunk_shift == job.keys[band_first - 1] >> key_chunk_shift) {
        const continued = job.keys[band_first] >> key_chunk_shift;
        var last_row_part = job.keys[band_first - 1] >> key_row_shift;
        while (cell < band_cells_end and job.cellKey(cell) >> key_chunk_shift == continued) : (cell += 1) {
            const row_part = job.cellKey(cell) >> key_row_shift;
            if (row_part != last_row_part) {
                row += 1;
                last_row_part = row_part;
            }
        }
    }
    const cell_total = job.cells.len - 1;
    while (cell < band_cells_end) {
        const first_key = job.cellKey(cell);
        const chunk = first_key >> key_chunk_shift;
        var record = ChunkRecord{ .row_masks = @splat(0), .first_rows = @splat(0) };
        var factions = FactionSet.empty;
        // Never a real row part's: a chunk y is below maxInt(i32).
        var last_row_part: SortKey = max_key >> key_row_shift;
        var at_band = band;
        var at_cell: ?u32 = cell;
        while (at_cell) |current| {
            const key = job.cellKey(current);
            if (key >> key_chunk_shift != chunk) break;
            const global = job.cell_prefix[at_band] + (current - job.band_start[at_band]);
            std.debug.assert(global < cell_total);
            job.cells[global] = job.band_cells[current];
            const row_part = key >> key_row_shift;
            if (row_part != last_row_part) {
                const faction = keyFaction(key);
                if (record.row_masks[faction] == 0) record.first_rows[faction] = row;
                record.row_masks[faction] |= @as(u64, 1) << @intCast(keyLocalY(key));
                factions.bits.set(faction);
                std.debug.assert(row < job.rows.len);
                job.rows[row] = .{ .cells = 0, .first_cell = global };
                row += 1;
                last_row_part = row_part;
            }
            job.rows[row - 1].cells |= @as(u64, 1) << @intCast(keyLocalX(key));
            const next = nextCell(job, at_band, current) orelse {
                at_cell = null;
                break;
            };
            at_band = next.band;
            at_cell = next.cell;
        }
        std.debug.assert(chunk_index < job.chunk_records.len);
        job.chunk_records[chunk_index] = record;
        const level = keyLevel(first_key);
        std.debug.assert(level < job.level_slots.len);
        const slots = job.level_slots[level];
        std.debug.assert(slots.len == job.chunk_count);
        const slot_index = @as(usize, keyChunkY(first_key)) * job.chunks_x + keyChunkX(first_key);
        std.debug.assert(slot_index < slots.len);
        slots[slot_index] = .{ .build = job.build_stamp, .record = chunk_index, .factions = factions };
        chunk_index += 1;
        // The chunk ended inside this band, or it ran on and this band holds no more.
        cell = if (at_band == band) at_cell orelse band_cells_end else band_cells_end;
    }
}

// The `band_count - 1` band splitters: the cells at the band quantiles of up to
// `splitter_sample_count` slots (slots without a body skipped), sorted, as cell start keys.
// Every slot when they fit the sample, else slots at a golden-ratio sequence of fractions of
// the slot count, which shares no period with a periodic slot order. Fixed work on the main
// thread; with no sampled body every splitter is `max_key`.
fn chooseSplitters(data: *const DataSystem, population: IndexPopulation, grid: Grid) [band_count - 1]SortKey {
    const slot_count = population.len();
    const sample_count = @min(splitter_sample_count, slot_count);
    const movement = data.movementBodySliceConst();
    var samples: [splitter_sample_count]SortKey = undefined;
    var valid: usize = 0;
    var fraction: u64 = 0;
    for (0..sample_count) |sample| {
        fraction +%= sample_fraction_step;
        // The high word of fraction * slot_count is below slot_count.
        const slot: usize = if (slot_count <= splitter_sample_count) sample else @intCast(std.math.mulWide(u64, fraction, slot_count) >> 64);
        const found = data.bodyLevelFaction(population.entity(slot)) orelse continue;
        // The faction sits above the cell in the key, so a sample carries its body's.
        const faction = FactionSet.Indexer.indexOf(found.faction orelse .neutral);
        const key = keyForPosition(grid, found.level orelse 0, movement.previous_x[found.movement_body], movement.previous_y[found.movement_body], faction, 0);
        samples[valid] = key & ~cell_low_bits;
        valid += 1;
    }
    var splitters: [band_count - 1]SortKey = @splat(max_key);
    if (valid == 0) return splitters;
    pdqSort(SortKey, samples[0..valid], {}, keyLessThan);
    for (&splitters, 1..) |*splitter, band| splitter.* = samples[band * valid / band_count];
    return splitters;
}

// ---- Tests --------------------------------------------------------------------

const testing = std.testing;

// A query visitor that records every visit in lane order, stopping after `stop_after`
// visits.
const RecordingVisitor = struct {
    entries: [512]u32 = undefined,
    dx: [512]f32 = undefined,
    dy: [512]f32 = undefined,
    dist2: [512]f32 = undefined,
    count: usize = 0,
    stop_after: usize = std.math.maxInt(usize),

    // Records one visit; true when it is the last.
    fn record(self: *RecordingVisitor, entry: u32, dx: f32, dy: f32, dist2: f32) bool {
        self.entries[self.count] = entry;
        self.dx[self.count] = dx;
        self.dy[self.count] = dy;
        self.dist2[self.count] = dist2;
        self.count += 1;
        return self.count >= self.stop_after;
    }

    fn visitLanes(self: *RecordingVisitor, lanes: *const NeighborLanes) LaneStop {
        const dx = simd.toFloatArray(lanes.dx);
        const dy = simd.toFloatArray(lanes.dy);
        const dist2 = simd.toFloatArray(lanes.dist2);
        const inside: std.bit_set.Integer(simd.lane_count) = .{ .mask = lanes.inside };
        var bits = inside.iterator(.{});
        while (bits.next()) |bit| {
            // A set bit's index is below lane_count.
            const lane: simd.LaneIndex = @intCast(bit);
            if (self.record(lanes.first + lane, dx[lane], dy[lane], dist2[lane])) return lane;
        }
        return null;
    }

    fn visited(self: *const RecordingVisitor) []const u32 {
        return self.entries[0..self.count];
    }

    fn expectEqual(self: *const RecordingVisitor, other: *const RecordingVisitor) !void {
        try testing.expectEqualSlices(u32, self.visited(), other.visited());
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(self.dx[0..self.count]), std.mem.sliceAsBytes(other.dx[0..other.count]));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(self.dy[0..self.count]), std.mem.sliceAsBytes(other.dy[0..other.count]));
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(self.dist2[0..self.count]), std.mem.sliceAsBytes(other.dist2[0..other.count]));
    }
};

// An AI agent with a movement body at `(x, y)`.
fn addTestBody(data: *DataSystem, x: f32, y: f32) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = y }, .previous_position = .{ .x = x, .y = y }, .velocity = .{}, .speed = 20 });
    try data.setAiAgent(entity, .{ .active_behavior = .wander });
    return entity;
}

// An AI agent with no movement body.
fn addTestBodiless(data: *DataSystem) !EntityId {
    const entity = try data.createEntity();
    try data.setAiAgent(entity, .{ .active_behavior = .wander });
    return entity;
}

fn aiPopulation(data: *const DataSystem) IndexPopulation {
    return .{ .entities = data.aiAgentSliceConst().entities };
}

// A grid of `chunks` x `chunks` chunks of 16 cells of `cell_size`, on `levels` levels,
// built at the default config: the effective cell is `cell_size` exactly.
fn testGeometry(cell_size: f32, chunks: u32, levels: usize) IndexGeometry {
    return .{ .tile_size = cell_size, .chunk_size_tiles = 16, .chunks_x = chunks, .chunks_y = chunks, .level_count = levels };
}

const test_cells_per_chunk: u32 = 16;

// The default config at `cell_size`: with `testGeometry` it builds cells of exactly that size.
fn testConfig(cell_size: f32) SpatialIndexConfig {
    return .{ .cell_size = cell_size };
}

// Index test layouts of `layout_slot_count` AI agents, every seventh from slot 3 bodiless.
// Factions vary, and levels too except in `one_cell` and `dense_row_part`.
const TestLayout = enum {
    // One cell row across about 200 cells.
    one_row,
    // Many cell rows.
    spread,
    // Outside the grid, with a NaN y, a -inf x, a +inf y, and a -inf y.
    outside,
    // One cell.
    one_cell,
    // A 10x10-cell cluster and one body far outside the grid.
    cluster_outlier,
    // Local x 0 and 15 on both sides of chunk edges in four rows, and one body past each
    // grid extreme.
    chunk_edges,
    // Sites with a body on each of `stacked_level_count` levels at shared xy.
    stacked_levels,
    // One chunk's one cell row, all hostile on one level: a splitter carries its faction.
    dense_row_part,
};
const stacked_level_count: u16 = 6;
const chunk_edge_cells = [_]i32{ 0, 15, 16, 31, 32, 47, 48, 63, 64, 1023 };
const layout_slot_count: usize = 1000;
const layout_cell_size: f32 = 20;
const layout_chunks: u32 = 64;
const layout_outlier_slot: usize = layout_slot_count - 1;
const layout_geometry = testGeometry(layout_cell_size, layout_chunks, 3);

fn fillTestLayout(data: *DataSystem, layout: TestLayout) !void {
    var prng = std.Random.DefaultPrng.init(0x6e1d_b4d5);
    const random = prng.random();
    for (0..layout_slot_count) |slot| {
        if (slot % 7 == 3) {
            _ = try addTestBodiless(data);
            continue;
        }
        var x: f32 = 0;
        var y: f32 = 0;
        switch (layout) {
            .one_row => {
                x = random.float(f32) * 4000;
                y = 3 + random.float(f32) * 6;
            },
            .spread => {
                x = random.float(f32) * 120;
                y = random.float(f32) * 640;
            },
            .outside => {
                x = random.float(f32) * 120 - 300;
                y = -20 - random.float(f32) * 640;
            },
            .one_cell => {
                x = 1 + random.float(f32) * 18;
                y = 1 + random.float(f32) * 18;
            },
            .cluster_outlier => {
                x = random.float(f32) * 200;
                y = random.float(f32) * 200;
                if (slot == layout_outlier_slot) {
                    x = 1e6;
                    y = 1e6;
                }
            },
            .chunk_edges => {
                const cell_x = chunk_edge_cells[slot % chunk_edge_cells.len];
                const cell_y: i32 = @as(i32, @intCast(slot / chunk_edge_cells.len % 4)) + 14;
                x = (@as(f32, @floatFromInt(cell_x)) + 0.1 + random.float(f32) * 0.8) * layout_cell_size;
                y = (@as(f32, @floatFromInt(cell_y)) + 0.1 + random.float(f32) * 0.8) * layout_cell_size;
                // Finite, and past the grid on each side.
                if (slot == layout_outlier_slot) {
                    x = 3e38;
                    y = 3e38;
                }
                if (slot == layout_outlier_slot - 1) {
                    x = -3e38;
                    y = -3e38;
                }
            },
            .stacked_levels => {
                const site = slot / stacked_level_count;
                x = @as(f32, @floatFromInt(site % 12)) * 37 + 3;
                y = @as(f32, @floatFromInt(site / 12)) * 41 + 5;
            },
            .dense_row_part => {
                x = (@as(f32, @floatFromInt(slot % test_cells_per_chunk)) + 0.1 + random.float(f32) * 0.8) * layout_cell_size;
                y = (0.1 + random.float(f32) * 0.8) * layout_cell_size;
            },
        }
        const entity = try addTestBody(data, x, y);
        try data.setFaction(entity, if (layout == .dense_row_part) .hostile else @fromBackingInt(@intCast(slot % 4)));
        if (layout == .stacked_levels) {
            try data.setWorldLevel(entity, @intCast(slot % stacked_level_count));
        } else if (layout != .one_cell and layout != .dense_row_part and slot % 5 == 0) {
            try data.setWorldLevel(entity, @intCast(slot % 3));
        }
    }
    if (layout == .outside) {
        // The store refuses non-finite positions; a column write is how one arrives.
        const entities = data.aiAgentSliceConst().entities;
        const movement = data.movementBodySlice();
        movement.previous_y[data.movementBodyDenseIndex(entities[501]).?] = std.math.nan(f32);
        movement.previous_x[data.movementBodyDenseIndex(entities[502]).?] = -std.math.inf(f32);
        movement.previous_y[data.movementBodyDenseIndex(entities[503]).?] = std.math.inf(f32);
        movement.previous_y[data.movementBodyDenseIndex(entities[504]).?] = -std.math.inf(f32);
    }
}

// Explicit nondecreasing band splitter sets over a build's cell start keys.
const TestSplitters = enum {
    // All past every key.
    all_max,
    // All one cell.
    one_cell,
    // Cells at a stride.
    stride,
    // The first key and past every key around cells.
    extremes,
    // Cells in equal pairs.
    pairs,
    // The second row part of the chunk with the most: the chunk straddles two bands.
    straddle_chunk,
    // The second cell of the row part with the most: the row part straddles two bands.
    straddle_row,
    // Every cell of the chunk with the most: it runs across that many bands.
    every_cell,
};

// The first index and unit count of the group of `cell_keys` (keys equal above
// `group_shift`) holding the most units (keys distinct above `unit_shift`), the first on a
// tie.
fn widestGroup(cell_keys: []const SortKey, group_shift: u7, unit_shift: u7) struct { start: usize, units: usize } {
    var best_start: usize = 0;
    var best_units: usize = 0;
    var start: usize = 0;
    var units: usize = 0;
    for (cell_keys, 0..) |key, index| {
        if (index == 0 or key >> group_shift != cell_keys[index - 1] >> group_shift) {
            start = index;
            units = 0;
        }
        if (index == start or key >> unit_shift != cell_keys[index - 1] >> unit_shift) units += 1;
        if (units > best_units) {
            best_units = units;
            best_start = start;
        }
    }
    return .{ .start = best_start, .units = best_units };
}

fn testSplitters(set: TestSplitters, cell_keys: []const SortKey) [band_count - 1]SortKey {
    std.debug.assert(cell_keys.len > 0);
    var splitters: [band_count - 1]SortKey = @splat(max_key);
    switch (set) {
        .all_max => {},
        .one_cell => splitters = @splat(cell_keys[cell_keys.len / 2]),
        .stride, .extremes => for (&splitters, 0..) |*splitter, index| {
            splitter.* = cell_keys[index * cell_keys.len / (band_count - 1)];
            if (set == .extremes and index < 8) splitter.* = 0;
            if (set == .extremes and index >= band_count - 9) splitter.* = max_key;
        },
        .pairs => for (&splitters, 0..) |*splitter, index| {
            splitter.* = cell_keys[(index / 2) * cell_keys.len / (band_count / 2)];
        },
        .straddle_chunk => {
            const chunk = widestGroup(cell_keys, key_chunk_shift, key_row_shift);
            if (chunk.units > 1) {
                var cell = chunk.start + 1;
                while (cell_keys[cell] >> key_row_shift == cell_keys[cell - 1] >> key_row_shift) cell += 1;
                splitters[0] = cell_keys[cell];
            }
        },
        .straddle_row => {
            const row = widestGroup(cell_keys, key_row_shift, key_cell_shift);
            if (row.units > 1) splitters[0] = cell_keys[row.start + 1];
        },
        .every_cell => {
            const chunk = widestGroup(cell_keys, key_chunk_shift, key_cell_shift);
            for (1..@min(chunk.units, band_count)) |cell| splitters[cell - 1] = cell_keys[chunk.start + cell];
        },
    }
    return splitters;
}

// A build's entries, cells, row parts, records, valid directory slots, and cell start keys.
const TestCapture = struct {
    x: std.ArrayList(f32) = .empty,
    y: std.ArrayList(f32) = .empty,
    entity_index: std.ArrayList(u32) = .empty,
    entity_generation: std.ArrayList(u32) = .empty,
    cells: std.ArrayList(u32) = .empty,
    rows: std.ArrayList(RowPart) = .empty,
    chunk_records: std.ArrayList(ChunkRecord) = .empty,
    // Each populated cell's first key with its slot cleared, in key order.
    cell_keys: std.ArrayList(SortKey) = .empty,
    // Every level's directory, valid slots only, by level and slot index.
    slots: std.ArrayList(struct { level: usize, index: usize, slot: ChunkSlot }) = .empty,

    fn capture(system: *const SpatialIndexSystem) !TestCapture {
        var copy = TestCapture{};
        errdefer copy.deinit();
        const index = system.view();
        try copy.x.appendSlice(testing.allocator, index.x);
        try copy.y.appendSlice(testing.allocator, index.y);
        try copy.entity_index.appendSlice(testing.allocator, index.entity_index);
        try copy.entity_generation.appendSlice(testing.allocator, index.entity_generation);
        try copy.cells.appendSlice(testing.allocator, index.cells);
        try copy.rows.appendSlice(testing.allocator, index.rows);
        try copy.chunk_records.appendSlice(testing.allocator, index.chunk_records);
        if (index.cells.len > 0) {
            for (index.cells[0 .. index.cells.len - 1]) |start| try copy.cell_keys.append(testing.allocator, system.keys.items[start] & ~cell_low_bits);
        }
        for (index.level_slots, 0..) |slots, level| {
            for (slots, 0..) |slot, slot_index| {
                if (slot.build != index.build_stamp) continue;
                var stored = slot;
                stored.build = 0;
                try copy.slots.append(testing.allocator, .{ .level = level, .index = slot_index, .slot = stored });
            }
        }
        return copy;
    }

    fn entityAt(self: *const TestCapture, entry: u32) EntityId {
        return .{ .index = self.entity_index.items[entry], .generation = self.entity_generation.items[entry] };
    }

    fn deinit(self: *TestCapture) void {
        self.slots.deinit(testing.allocator);
        self.cell_keys.deinit(testing.allocator);
        self.chunk_records.deinit(testing.allocator);
        self.rows.deinit(testing.allocator);
        self.cells.deinit(testing.allocator);
        self.entity_generation.deinit(testing.allocator);
        self.entity_index.deinit(testing.allocator);
        self.y.deinit(testing.allocator);
        self.x.deinit(testing.allocator);
    }
};

const parity_query_radii = [_]f32{ 0, 48, 96, 192 };
// Every faction; one; two runs apart; and two adjacent.
const parity_query_factions = [_]FactionSet{ .full, .initOne(.hostile), .initMany(&.{ .neutral, .ally }), .initMany(&.{ .player, .ally }) };
const parity_query_checks: u16 = 64;
// Cells sampled for the query battery, at a stride over the reference's cells.
const parity_query_cells: usize = 48;

fn factionIndex(faction: Faction) usize {
    return FactionSet.Indexer.indexOf(faction);
}

// `system`'s index holds bit for bit the reference's entries, cells, row parts, records, and
// directory, its records agree with its entries, and it answers the query battery with the
// same visits and stats.
fn expectIndexMatches(system: *const SpatialIndexSystem, reference: *const TestCapture, reference_system: *const SpatialIndexSystem) !void {
    const index = system.view();
    var actual = try TestCapture.capture(system);
    defer actual.deinit();
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(reference.x.items), std.mem.sliceAsBytes(index.x));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(reference.y.items), std.mem.sliceAsBytes(index.y));
    try testing.expectEqualSlices(u32, reference.entity_index.items, index.entity_index);
    try testing.expectEqualSlices(u32, reference.entity_generation.items, index.entity_generation);
    try testing.expectEqualSlices(u32, reference.cells.items, actual.cells.items);
    try testing.expectEqualSlices(SortKey, reference.cell_keys.items, actual.cell_keys.items);
    try testing.expectEqualSlices(RowPart, reference.rows.items, actual.rows.items);
    try testing.expectEqualSlices(ChunkRecord, reference.chunk_records.items, actual.chunk_records.items);
    try testing.expectEqual(reference.slots.items.len, actual.slots.items.len);
    for (reference.slots.items, actual.slots.items) |want, got| {
        try testing.expectEqual(want.level, got.level);
        try testing.expectEqual(want.index, got.index);
        try testing.expectEqual(want.slot.record, got.slot.record);
        try testing.expect(want.slot.factions.eql(got.slot.factions));
    }
    try expectRecordsAgree(system);

    const reference_index = reference_system.view();
    const stride = @max(reference.cell_keys.items.len / parity_query_cells, 1);
    var cell_index: usize = 0;
    while (cell_index < reference.cell_keys.items.len) : (cell_index += stride) {
        const key = reference.cell_keys.items[cell_index];
        const cell_x = keyChunkX(key) * index.cells_per_chunk + keyLocalX(key);
        const cell_y = keyChunkY(key) * index.cells_per_chunk + keyLocalY(key);
        const centre_x = (@as(f32, @floatFromInt(cell_x)) + 0.5) * index.cell_size;
        const centre_y = (@as(f32, @floatFromInt(cell_y)) + 0.5) * index.cell_size;
        for (parity_query_radii) |radius| {
            for (parity_query_factions) |factions| {
                const query = NeighborQuery{ .x = centre_x, .y = centre_y, .level = keyLevel(key), .radius = radius, .max_candidate_checks = parity_query_checks, .factions = factions, .self = reference.entityAt(reference.cells.items[cell_index]) };
                var expected = RecordingVisitor{};
                const expected_stats = reference_index.queryNeighbors(query, &expected);
                var got = RecordingVisitor{};
                const got_stats = index.queryNeighbors(query, &got);
                try testing.expectEqual(expected_stats, got_stats);
                try expected.expectEqual(&got);
            }
        }
    }
}

// Records, row parts, cells, and entries agree with the keys, gapless, in key order.
fn expectRecordsAgree(system: *const SpatialIndexSystem) !void {
    const index = system.view();
    const keys = system.keys.items;
    if (index.cells.len == 0) {
        try testing.expectEqual(@as(usize, 0), index.entryCount());
        return;
    }
    var records_seen: u32 = 0;
    var rows_seen: u32 = 0;
    var cells_seen: u32 = 0;
    var entries_seen: u32 = 0;
    var all_factions = FactionSet.empty;
    for (index.level_slots, 0..) |slots, level| {
        for (slots, 0..) |slot, slot_index| {
            if (slot.build != index.build_stamp) continue;
            // Key order is level, then chunk y and x: slot order.
            try testing.expectEqual(records_seen, slot.record);
            records_seen += 1;
            const record = index.chunk_records[slot.record];
            var chunk_factions = FactionSet.empty;
            for (std.meta.tags(Faction)) |faction| {
                var row_bits = record.row_masks[factionIndex(faction)];
                if (row_bits == 0) continue;
                chunk_factions.insert(faction);
                try testing.expectEqual(rows_seen, record.first_rows[factionIndex(faction)]);
                while (row_bits != 0) : (row_bits &= row_bits - 1) {
                    const local_y: u32 = @ctz(row_bits);
                    const row = index.rows[rows_seen];
                    rows_seen += 1;
                    try testing.expectEqual(cells_seen, row.first_cell);
                    try testing.expect(row.cells != 0);
                    var cell_bits = row.cells;
                    while (cell_bits != 0) : (cell_bits &= cell_bits - 1) {
                        const local_x: u32 = @ctz(cell_bits);
                        const start = index.cells[cells_seen];
                        const end = index.cells[cells_seen + 1];
                        cells_seen += 1;
                        try testing.expectEqual(entries_seen, start);
                        try testing.expect(start < end);
                        for (keys[start..end]) |key| {
                            try testing.expectEqual(@as(u16, @intCast(level)), keyLevel(key));
                            try testing.expectEqual(slot_index, @as(usize, keyChunkY(key)) * index.chunks_x + keyChunkX(key));
                            try testing.expectEqual(factionIndex(faction), keyFaction(key));
                            try testing.expectEqual(local_y, keyLocalY(key));
                            try testing.expectEqual(local_x, keyLocalX(key));
                        }
                        entries_seen = end;
                    }
                }
            }
            try testing.expect(slot.factions.eql(chunk_factions));
            all_factions.setUnion(chunk_factions);
        }
    }
    try testing.expectEqual(index.chunk_records.len, records_seen);
    try testing.expectEqual(index.rows.len, rows_seen);
    try testing.expectEqual(index.cells.len, cells_seen + 1);
    try testing.expectEqual(index.entryCount(), entries_seen);
    try testing.expectEqual(index.entryCount(), index.cells[cells_seen]);
    try testing.expect(index.factions.eql(all_factions));
}

// The three stages under fixed controls: `bucket_items`, `sort_items`, and `link_items`
// per range, on up to `workers` workers.
fn testStages(threads: *ThreadSystem, tuners: *[3]AdaptiveWorkTuner, workers: usize, bucket_items: usize, sort_items: usize, link_items: usize) BuildStages {
    return .{
        .bucket = Dispatch.init(threads, &tuners[0], .{ .items_per_range = bucket_items, .max_worker_threads = workers, .adaptive = false }),
        .sort = Dispatch.init(threads, &tuners[1], .{ .items_per_range = sort_items, .max_worker_threads = workers, .adaptive = false }),
        .link = Dispatch.init(threads, &tuners[2], .{ .items_per_range = link_items, .max_worker_threads = workers, .adaptive = false }),
    };
}

test "serial and threaded index builds match across layouts, splitters, range sizes, and worker counts" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 3, .items_per_range = 16 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    for (std.meta.tags(TestLayout)) |layout| {
        var data = DataSystem.init(testing.allocator);
        defer data.deinit();
        try fillTestLayout(&data, layout);
        const population = aiPopulation(&data);
        const config = testConfig(layout_cell_size);

        var reference_system = SpatialIndexSystem.init(testing.allocator);
        defer reference_system.deinit();
        _ = try reference_system.buildSerial(&data, population, layout_geometry, config);
        var reference = try TestCapture.capture(&reference_system);
        defer reference.deinit();
        // The one cell holds every faction, each its own cell.
        try testing.expectEqual(layout == .one_cell, reference.cell_keys.items.len == FactionSet.len);
        try expectRecordsAgree(&reference_system);

        var system = SpatialIndexSystem.init(testing.allocator);
        defer system.deinit();
        var tuners: [3]AdaptiveWorkTuner = @splat(AdaptiveWorkTuner.init(.{}));

        // Stage range sizes and worker counts under the production splitters.
        for ([_]usize{ 1, 3 }) |workers| {
            for ([_]usize{ 16, 64 }) |bucket_items| {
                for ([_]usize{ 16, 1024 }) |sort_items| {
                    for ([_]usize{ 16, 1024 }) |link_items| {
                        _ = try system.beginBuild(population, layout_geometry, config);
                        const stats = try system.buildBanded(&data, population, testStages(&threads, &tuners, workers, bucket_items, sort_items, link_items), chooseSplitters(&data, population, system.grid));
                        try testing.expect(!stats.bucket_batch.ran_inline);
                        try expectIndexMatches(&system, &reference, &reference_system);
                    }
                }
            }
        }

        // Explicit splitter sets over one partition.
        const stages = testStages(&threads, &tuners, 3, 64, 64, 16);
        for (std.meta.tags(TestSplitters)) |set| {
            _ = try system.beginBuild(population, layout_geometry, config);
            const stats = try system.buildBanded(&data, population, stages, testSplitters(set, reference.cell_keys.items));
            try testing.expect(!stats.bucket_batch.ran_inline and !stats.sort_batch.ran_inline);
            try expectIndexMatches(&system, &reference, &reference_system);
        }

        // The production build, and a config that allows no worker builds serially.
        const threaded = try system.build(&data, population, layout_geometry, &threads, .{ .cell_size = layout_cell_size, .items_per_range = 16, .max_worker_threads = 3, .adaptive = false });
        try testing.expect(!threaded.bucket_batch.ran_inline and !threaded.sort_batch.ran_inline);
        // The link stage partitions the cells: one range of them may run inline.
        try testing.expect(reference.cell_keys.items.len <= 16 or !threaded.link_batch.ran_inline);
        try expectIndexMatches(&system, &reference, &reference_system);
        const serial = try system.build(&data, population, layout_geometry, &threads, .{ .cell_size = layout_cell_size, .max_worker_threads = 0 });
        try testing.expect(serial.bucket_batch.ran_inline and serial.sort_batch.ran_inline and serial.link_batch.ran_inline);
        try expectIndexMatches(&system, &reference, &reference_system);
    }
}

test "the threaded index splits a one-row corridor, a cluster with a far outlier, and a one-row-part crowd across bands" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    for ([_]TestLayout{ .one_row, .cluster_outlier, .dense_row_part }) |layout| {
        var data = DataSystem.init(testing.allocator);
        defer data.deinit();
        try fillTestLayout(&data, layout);
        var system = SpatialIndexSystem.init(testing.allocator);
        defer system.deinit();
        const population = aiPopulation(&data);
        _ = try system.beginBuild(population, layout_geometry, testConfig(layout_cell_size));
        const splitters = chooseSplitters(&data, population, system.grid);
        var tuners: [3]AdaptiveWorkTuner = @splat(AdaptiveWorkTuner.init(.{}));
        const stats = try system.buildBanded(&data, population, testStages(&threads, &tuners, 3, 64, 64, 64), splitters);
        try testing.expect(stats.entity_count > 0);
        // The largest band's entries, counted from the splitters over the sorted keys.
        var largest: usize = 0;
        var band_start: usize = 0;
        for (0..band_count) |band| {
            var band_end: usize = band_start;
            while (band_end < stats.entity_count and bandOfKey(&splitters, system.keys.items[band_end]) == band) band_end += 1;
            largest = @max(largest, band_end - band_start);
            band_start = band_end;
        }
        try testing.expectEqual(stats.entity_count, band_start);
        try testing.expect(largest <= stats.entity_count / 8);
    }
}

test "queryNeighbors visits a cell's entries in slot order, skipping self without a check, inside a strict radius" {
    // Every body in cell (0, 0) at cell size 10; slot 2 sits exactly at the radius.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const self_entity = try addTestBody(&data, 0, 0);
    _ = try addTestBody(&data, 3, 0);
    _ = try addTestBody(&data, 5, 0);
    _ = try addTestBody(&data, 4.9, 0);
    _ = try addTestBody(&data, 1, 0);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(10, 4, 1), testConfig(10));
    const index = system.view();

    var visitor = RecordingVisitor{};
    const stats = index.queryNeighbors(.{ .x = 0, .y = 0, .level = 0, .radius = 5, .max_candidate_checks = 128, .self = self_entity }, &visitor);
    // Slot 2 (dist2 == 25) is checked but not visited; self is neither.
    try testing.expectEqualSlices(u32, &.{ 1, 3, 4 }, visitor.visited());
    try testing.expectEqual(@as(u16, 4), stats.candidate_checks);
    try testing.expectEqual(@as(f32, -3), visitor.dx[0]);
    try testing.expectEqual(@as(f32, 9), visitor.dist2[0]);

    // Without a self, slot 0 is a candidate at distance 0.
    var all = RecordingVisitor{};
    _ = index.queryNeighbors(.{ .x = 0, .y = 0, .level = 0, .radius = 5, .max_candidate_checks = 128 }, &all);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 3, 4 }, all.visited());
}

test "queryNeighbors stops at its check budget before the tipping entry, and on a visitor stop" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const self_entity = try addTestBody(&data, 0, 0);
    _ = try addTestBody(&data, 1, 0);
    _ = try addTestBody(&data, 2, 0);
    _ = try addTestBody(&data, 3, 0);
    // Cell rows below and a cell to the right, past the first cell's entries.
    _ = try addTestBody(&data, 15, 0);
    _ = try addTestBody(&data, 5, 15);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(10, 4, 1), testConfig(10));
    const index = system.view();

    var capped = RecordingVisitor{};
    const capped_stats = index.queryNeighbors(.{ .x = 0, .y = 0, .level = 0, .radius = 100, .max_candidate_checks = 1, .self = self_entity }, &capped);
    try testing.expectEqualSlices(u32, &.{1}, capped.visited());
    try testing.expectEqual(@as(u16, 1), capped_stats.candidate_checks);

    // A stop in the first cell ends the row and the scan.
    var stopped = RecordingVisitor{ .stop_after = 2 };
    const stopped_stats = index.queryNeighbors(.{ .x = 0, .y = 0, .level = 0, .radius = 100, .max_candidate_checks = 64 }, &stopped);
    try testing.expectEqualSlices(u32, &.{ 0, 1 }, stopped.visited());
    try testing.expectEqual(@as(u16, 2), stopped_stats.candidate_checks);

    // Unbounded, the scan runs cell_y outer, cell_x inner: (0, 0), (0, 1), then (1, 0).
    var full = RecordingVisitor{};
    _ = index.queryNeighbors(.{ .x = 0, .y = 0, .level = 0, .radius = 100, .max_candidate_checks = 64 }, &full);
    try testing.expectEqual(@as(usize, 6), full.count);
    try testing.expectEqual(@as(f32, 15), index.x[full.entries[4]]);
    try testing.expectEqual(@as(f32, 15), index.y[full.entries[5]]);
}

test "an index over population rows maps each slot to its row's entity, skips bodiless slots, and links each chunk's rows" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const near = try addTestBody(&data, 4, 4);
    _ = try addTestBody(&data, 6, 6);
    const bodiless = try addTestBodiless(&data);
    const far = try addTestBody(&data, 12, 4);
    try data.setFaction(far, .hostile);
    try data.setWorldLevel(far, 2);
    _ = bodiless;
    // Agent 1 is outside the rows; agent 2 has no body.
    const rows = [_]u32{ 3, 2, 0 };
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    const stats = try system.buildSerial(&data, .{ .entities = data.aiAgentSliceConst().entities, .rows = &rows }, testGeometry(10, 4, 1), testConfig(10));
    try testing.expectEqual(@as(usize, 2), stats.entity_count);
    const index = system.view();
    // Level 0's cell (0, 0) holds slot 2 (`near`), level 2's cell (1, 0) slot 0 (`far`),
    // each its chunk's one neutral or hostile row part; level 2 has a directory though the
    // geometry has one level.
    var entities: [2]EntityId = undefined;
    try testing.expectEqualSlices(EntityId, &.{ near, far }, viewEntities(index, &entities));
    try testing.expectEqual(@as(usize, 3), index.level_slots.len);
    try testing.expectEqual(@as(usize, 2), index.rows.len);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, index.cells);
    const level_0 = index.level_slots[0][0];
    try testing.expectEqual(index.build_stamp, level_0.build);
    try testing.expectEqual(@as(u32, 0), level_0.record);
    try testing.expect(level_0.factions.eql(.initOne(.neutral)));
    const level_2 = index.level_slots[2][0];
    try testing.expectEqual(index.build_stamp, level_2.build);
    try testing.expectEqual(@as(u32, 1), level_2.record);
    try testing.expect(level_2.factions.eql(.initOne(.hostile)));
    try testing.expect(index.level_slots[1][0].build != index.build_stamp);
    try testing.expectEqualSlices(ChunkRecord, &.{
        .{ .row_masks = .{ 1, 0, 0, 0 }, .first_rows = .{ 0, 0, 0, 0 } },
        .{ .row_masks = .{ 0, 0, 0, 1 }, .first_rows = .{ 0, 0, 0, 1 } },
    }, index.chunk_records);
    try testing.expectEqualSlices(RowPart, &.{ .{ .cells = 1, .first_cell = 0 }, .{ .cells = 1 << 1, .first_cell = 1 } }, index.rows);
    try testing.expect(index.factions.eql(.initMany(&.{ .neutral, .hostile })));
    try expectRecordsAgree(&system);

    var visitor = RecordingVisitor{};
    _ = index.queryNeighbors(.{ .x = 12, .y = 4, .level = 2, .radius = 5, .max_candidate_checks = 8 }, &visitor);
    try testing.expectEqualSlices(u32, &.{1}, visitor.visited());
}

// An AI agent with a movement body at `(x, y)` on `level`, of `faction`.
fn addTaggedBody(data: *DataSystem, x: f32, y: f32, level: u16, faction: Faction) !EntityId {
    const entity = try addTestBody(data, x, y);
    try data.setWorldLevel(entity, level);
    try data.setFaction(entity, faction);
    return entity;
}

// The entities `visitor` visited, in visit order.
fn visitedEntities(index: SpatialIndexView, visitor: *const RecordingVisitor, out: []EntityId) []const EntityId {
    for (visitor.visited(), 0..) |entry, visit| out[visit] = index.entityAt(entry);
    return out[0..visitor.count];
}

// The view's entities in entry order.
fn viewEntities(index: SpatialIndexView, out: []EntityId) []const EntityId {
    for (out[0..index.entryCount()], 0..) |*entity, entry| entity.* = index.entityAt(@intCast(entry));
    return out[0..index.entryCount()];
}

test "a query visits only its own level: rows at the same xy on other levels are neither visited nor checked" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const self_entity = try addTaggedBody(&data, 5, 5, 0, .neutral);
    const same_level = try addTaggedBody(&data, 8, 5, 0, .neutral);
    var stacked: [3]EntityId = undefined;
    for (&stacked, 1..) |*entity, level| entity.* = try addTaggedBody(&data, 8, 5, @intCast(level), .neutral);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(10, 4, 1), testConfig(10));
    const index = system.view();

    var visitor = RecordingVisitor{};
    const stats = index.queryNeighbors(.{ .x = 5, .y = 5, .level = 0, .radius = 10, .max_candidate_checks = 64, .self = self_entity }, &visitor);
    var visited: [8]EntityId = undefined;
    try testing.expectEqualSlices(EntityId, &.{same_level}, visitedEntities(index, &visitor, &visited));
    try testing.expectEqual(@as(u16, 1), stats.candidate_checks);

    for (stacked, 1..) |entity, level| {
        var level_visitor = RecordingVisitor{};
        const level_stats = index.queryNeighbors(.{ .x = 5, .y = 5, .level = @intCast(level), .radius = 10, .max_candidate_checks = 64, .self = self_entity }, &level_visitor);
        try testing.expectEqualSlices(EntityId, &.{entity}, visitedEntities(index, &level_visitor, &visited));
        try testing.expectEqual(@as(u16, 1), level_stats.candidate_checks);
    }

    var empty_visitor = RecordingVisitor{};
    const empty_stats = index.queryNeighbors(.{ .x = 5, .y = 5, .level = 9, .radius = 10, .max_candidate_checks = 64 }, &empty_visitor);
    try testing.expectEqual(@as(usize, 0), empty_visitor.count);
    try testing.expectEqual(@as(u16, 0), empty_stats.candidate_checks);
}

test "a hostile-masked query checks only hostile rows on its level: an ally crowd and stacked hostiles spend no budget" {
    // 200 allies over 4x4 cells around the query point, 3 hostiles among them, and a
    // hostile on each of 8 other levels at the query point.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..200) |ally| _ = try addTaggedBody(&data, @floatFromInt(ally % 20 * 2), @floatFromInt(ally / 20 * 4), 0, .player);
    var hostiles: [3]EntityId = undefined;
    for (&hostiles, 0..) |*entity, hostile| entity.* = try addTaggedBody(&data, 6 + @as(f32, @floatFromInt(hostile)) * 11, 21, 0, .hostile);
    for (1..9) |level| _ = try addTaggedBody(&data, 20, 20, @intCast(level), .hostile);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(10, 4, 1), testConfig(10));
    const index = system.view();

    var visitor = RecordingVisitor{};
    const stats = index.queryNeighbors(.{ .x = 20, .y = 20, .level = 0, .radius = 40, .max_candidate_checks = 64, .factions = .initOne(.hostile) }, &visitor);
    var visited: [8]EntityId = undefined;
    try testing.expectEqualSlices(EntityId, &hostiles, visitedEntities(index, &visitor, &visited));
    try testing.expectEqual(@as(u16, hostiles.len), stats.candidate_checks);

    // Every faction: the allies spend the budget.
    var all = RecordingVisitor{};
    const all_stats = index.queryNeighbors(.{ .x = 20, .y = 20, .level = 0, .radius = 40, .max_candidate_checks = 64 }, &all);
    try testing.expectEqual(@as(u16, 64), all_stats.candidate_checks);
}

test "a query visits each piece's faction runs in (cell row, chunk, faction, cell, slot) order, under its budget" {
    // Cells (0, 0) and (0, 1) at cell size 10, factions mixed out of slot order.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const cell_a_hostile = try addTaggedBody(&data, 1, 1, 0, .hostile);
    const cell_a_neutral = try addTaggedBody(&data, 2, 2, 0, .neutral);
    const cell_a_ally = try addTaggedBody(&data, 3, 3, 0, .ally);
    const cell_b_neutral = try addTaggedBody(&data, 12, 1, 0, .neutral);
    const cell_b_hostile = try addTaggedBody(&data, 13, 2, 0, .hostile);
    const cell_a_neutral_late = try addTaggedBody(&data, 4, 4, 0, .neutral);
    const cell_b_player = try addTaggedBody(&data, 14, 4, 0, .player);
    const cell_b_hostile_late = try addTaggedBody(&data, 15, 5, 0, .hostile);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(10, 4, 1), testConfig(10));
    const index = system.view();

    const cases = [_]struct { factions: FactionSet, checks: u16, expected: []const EntityId }{
        .{ .factions = .full, .checks = 64, .expected = &.{ cell_a_neutral, cell_a_neutral_late, cell_b_neutral, cell_b_player, cell_a_ally, cell_a_hostile, cell_b_hostile, cell_b_hostile_late } },
        .{ .factions = .initMany(&.{ .neutral, .hostile }), .checks = 64, .expected = &.{ cell_a_neutral, cell_a_neutral_late, cell_b_neutral, cell_a_hostile, cell_b_hostile, cell_b_hostile_late } },
        .{ .factions = .initMany(&.{ .neutral, .hostile }), .checks = 4, .expected = &.{ cell_a_neutral, cell_a_neutral_late, cell_b_neutral, cell_a_hostile } },
        .{ .factions = .initMany(&.{ .player, .ally }), .checks = 64, .expected = &.{ cell_b_player, cell_a_ally } },
        .{ .factions = .initOne(.hostile), .checks = 64, .expected = &.{ cell_a_hostile, cell_b_hostile, cell_b_hostile_late } },
        .{ .factions = .empty, .checks = 64, .expected = &.{} },
    };
    for (cases) |case| {
        var visitor = RecordingVisitor{};
        const stats = index.queryNeighbors(.{ .x = 5, .y = 5, .level = 0, .radius = 30, .max_candidate_checks = case.checks, .factions = case.factions }, &visitor);
        var visited: [8]EntityId = undefined;
        try testing.expectEqualSlices(EntityId, case.expected, visitedEntities(index, &visitor, &visited));
        try testing.expectEqual(@as(u16, @intCast(case.expected.len)), stats.candidate_checks);
    }

    // A visitor stop ends the query: a prefix, each visit one check.
    const masked_order = [_]EntityId{ cell_a_neutral, cell_a_neutral_late, cell_b_neutral, cell_a_hostile, cell_b_hostile, cell_b_hostile_late };
    for ([_]usize{ 2, 4 }) |stop_after| {
        var visitor = RecordingVisitor{ .stop_after = stop_after };
        const stats = index.queryNeighbors(.{ .x = 5, .y = 5, .level = 0, .radius = 30, .max_candidate_checks = 64, .factions = .initMany(&.{ .neutral, .hostile }) }, &visitor);
        var visited: [8]EntityId = undefined;
        try testing.expectEqualSlices(EntityId, masked_order[0..stop_after], visitedEntities(index, &visitor, &visited));
        try testing.expectEqual(@as(u16, @intCast(stop_after)), stats.candidate_checks);
    }
}

test "self is skipped without a check at its cell's first, middle, and last entry, and only where it is indexed" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    // One cell of neutrals, a hostile in it, and a neutral at the same xy on level 1.
    var cell: [5]EntityId = undefined;
    for (&cell, 0..) |*entity, slot| entity.* = try addTaggedBody(&data, 2 + @as(f32, @floatFromInt(slot)), 3, 0, .neutral);
    const hostile = try addTaggedBody(&data, 4, 4, 0, .hostile);
    const upstairs = try addTaggedBody(&data, 2, 3, 1, .neutral);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(10, 4, 2), testConfig(10));
    const index = system.view();
    const movement = data.movementBodySliceConst();

    for ([_]usize{ 0, 2, 4 }) |position| {
        const self_entity = cell[position];
        const body = data.movementBodyDenseIndex(self_entity).?;
        var visitor = RecordingVisitor{};
        const stats = index.queryNeighbors(.{ .x = movement.previous_x[body], .y = movement.previous_y[body], .level = 0, .radius = 20, .max_candidate_checks = 64, .factions = .initOne(.neutral), .self = self_entity }, &visitor);
        try testing.expectEqual(@as(u16, cell.len - 1), stats.candidate_checks);
        var visited: [8]EntityId = undefined;
        for (visitedEntities(index, &visitor, &visited)) |entity| try testing.expect(!entity.eql(self_entity));
    }

    // Every faction: self in the first faction's run, and in the last's.
    for ([_]EntityId{ cell[2], hostile }) |self_entity| {
        const body = data.movementBodyDenseIndex(self_entity).?;
        var visitor = RecordingVisitor{};
        const stats = index.queryNeighbors(.{ .x = movement.previous_x[body], .y = movement.previous_y[body], .level = 0, .radius = 20, .max_candidate_checks = 64, .self = self_entity }, &visitor);
        try testing.expectEqual(@as(u16, cell.len), stats.candidate_checks);
        var visited: [8]EntityId = undefined;
        for (visitedEntities(index, &visitor, &visited)) |entity| try testing.expect(!entity.eql(self_entity));
    }

    // Self's faction not wanted: no effect.
    var hostile_visitor = RecordingVisitor{};
    const hostile_stats = index.queryNeighbors(.{ .x = 2, .y = 3, .level = 0, .radius = 20, .max_candidate_checks = 64, .factions = .initOne(.hostile), .self = cell[0] }, &hostile_visitor);
    try testing.expectEqual(@as(u16, 1), hostile_stats.candidate_checks);
    var visited: [8]EntityId = undefined;
    try testing.expectEqualSlices(EntityId, &.{hostile}, visitedEntities(index, &hostile_visitor, &visited));

    // A self indexed on another level is not resolved: level 1's entry is a candidate.
    var other_level = RecordingVisitor{};
    const other_stats = index.queryNeighbors(.{ .x = 2, .y = 3, .level = 1, .radius = 20, .max_candidate_checks = 64, .self = cell[0] }, &other_level);
    try testing.expectEqual(@as(u16, 1), other_stats.candidate_checks);
    try testing.expectEqualSlices(EntityId, &.{upstairs}, visitedEntities(index, &other_level, &visited));

    // An invalid self resolves nothing.
    var no_self = RecordingVisitor{};
    const no_self_stats = index.queryNeighbors(.{ .x = 2, .y = 3, .level = 0, .radius = 20, .max_candidate_checks = 64, .self = EntityId.invalid }, &no_self);
    try testing.expectEqual(@as(u16, cell.len + 1), no_self_stats.candidate_checks);
}

// Each entry's level and faction as `data` holds them, read independently of the index.
const EntryTags = struct {
    level: [512]u16 = undefined,
    faction: [512]Faction = undefined,

    fn read(data: *const DataSystem, index: SpatialIndexView) EntryTags {
        std.debug.assert(index.entryCount() <= 512);
        var tags = EntryTags{};
        for (0..index.entryCount()) |entry| {
            const entity = index.entityAt(@intCast(entry));
            tags.level[entry] = data.worldLevelConst(entity) orelse 0;
            tags.faction[entry] = data.factionConst(entity) orelse .neutral;
        }
        return tags;
    }
};

// One brute-force candidate, ordered by the scan's (cell_y, chunk_x, faction, cell_x,
// entry).
const BruteCandidate = struct {
    cell_y: u32,
    chunk_x: u32,
    faction: usize,
    cell_x: u32,
    entry: u32,

    fn lessThan(_: void, lhs: BruteCandidate, rhs: BruteCandidate) bool {
        if (lhs.cell_y != rhs.cell_y) return lhs.cell_y < rhs.cell_y;
        if (lhs.chunk_x != rhs.chunk_x) return lhs.chunk_x < rhs.chunk_x;
        if (lhs.faction != rhs.faction) return lhs.faction < rhs.faction;
        if (lhs.cell_x != rhs.cell_x) return lhs.cell_x < rhs.cell_x;
        return lhs.entry < rhs.entry;
    }
};

// A query's visits by brute force: every entry on the query's level, of a faction in its
// set, whose clamped cell lies in its box, in the scan's (cell_y, chunk_x, faction, cell_x,
// slot) order (slots ascend with entries inside a cell), self skipped, counted against the
// budget, then visited inside the strict radius.
fn bruteForceVisits(index: SpatialIndexView, tags: *const EntryTags, query: NeighborQuery, expected: *RecordingVisitor) NeighborQueryStats {
    var candidates: [512]BruteCandidate = undefined;
    var candidate_count: usize = 0;
    const scan = cellScanRadius(query.radius, index.cell_size);
    const own_x = math.worldPosToCell(query.x, index.cell_size, index.cells_x);
    const own_y = math.worldPosToCell(query.y, index.cell_size, index.cells_y);
    for (0..index.x.len) |entry| {
        if (index.entityAt(@intCast(entry)).eql(query.self)) continue;
        if (tags.level[entry] != query.level or !query.factions.contains(tags.faction[entry])) continue;
        const cell_x = math.worldPosToCell(index.x[entry], index.cell_size, index.cells_x);
        const cell_y = math.worldPosToCell(index.y[entry], index.cell_size, index.cells_y);
        if (@abs(@as(i64, cell_x) - own_x) > scan or @abs(@as(i64, cell_y) - own_y) > scan) continue;
        candidates[candidate_count] = .{ .cell_y = cell_y, .chunk_x = cell_x / index.cells_per_chunk, .faction = factionIndex(tags.faction[entry]), .cell_x = cell_x, .entry = @intCast(entry) };
        candidate_count += 1;
    }
    std.sort.pdq(BruteCandidate, candidates[0..candidate_count], {}, BruteCandidate.lessThan);
    var stats = NeighborQueryStats{};
    for (candidates[0..candidate_count]) |candidate| {
        if (stats.candidate_checks >= query.max_candidate_checks) break;
        stats.candidate_checks += 1;
        const dx = query.x - index.x[candidate.entry];
        const dy = query.y - index.y[candidate.entry];
        const dist2 = dx * dx + dy * dy;
        if (dist2 < query.radius * query.radius) _ = expected.record(candidate.entry, dx, dy, dist2);
    }
    return stats;
}

// Bodies over cells 25..174 at cell size 4 in a 16 x 4 chunk grid, in 20 cell rows on 3
// levels, of every faction: radius 300 crosses five chunks per row. A dense block of one
// cell per level gives masked runs of a lane block and more, and ten bodies past each grid
// side clamp to its edge cells.
fn fillBruteForceLayout(data: *DataSystem) !void {
    var prng = std.Random.DefaultPrng.init(0x0b5e_55ed);
    const random = prng.random();
    for (0..200) |_| {
        const entity = try addTestBody(data, 100 + random.float(f32) * 600, 60 + random.float(f32) * 80);
        try data.setWorldLevel(entity, random.uintLessThan(u16, 3));
        try data.setFaction(entity, @fromBackingInt(random.int(u2)));
    }
    for (0..90) |_| {
        const entity = try addTestBody(data, 401 + random.float(f32) * 2, 101 + random.float(f32) * 2);
        try data.setWorldLevel(entity, random.uintLessThan(u16, 3));
        try data.setFaction(entity, @fromBackingInt(random.int(u2)));
    }
    const sides = [_][2]f32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
    for (sides) |side| {
        for (0..10) |_| {
            const along_x = 100 + random.float(f32) * 600;
            const along_y = 60 + random.float(f32) * 80;
            const x = if (side[0] < 0) -random.float(f32) * 50 else if (side[0] > 0) 1024 + random.float(f32) * 50 else along_x;
            const y = if (side[1] < 0) -random.float(f32) * 50 else if (side[1] > 0) 256 + random.float(f32) * 50 else along_y;
            const entity = try addTestBody(data, x, y);
            try data.setWorldLevel(entity, random.uintLessThan(u16, 3));
            try data.setFaction(entity, @fromBackingInt(random.int(u2)));
        }
    }
}

const brute_force_geometry = IndexGeometry{ .tile_size = 4, .chunk_size_tiles = 16, .chunks_x = 16, .chunks_y = 4, .level_count = 3 };

test "queryNeighbors visits exactly a brute-force scan's in-box entries of its level and factions in scan order, up to its check budget" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    try fillBruteForceLayout(&data);
    const population = aiPopulation(&data);
    const config = testConfig(4);

    var serial = SpatialIndexSystem.init(testing.allocator);
    defer serial.deinit();
    _ = try serial.buildSerial(&data, population, brute_force_geometry, config);
    var reference = try TestCapture.capture(&serial);
    defer reference.deinit();

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = if (builtin.single_threaded) 0 else 3 });
    defer threads.deinit();
    var tuners: [3]AdaptiveWorkTuner = @splat(AdaptiveWorkTuner.init(.{}));
    var banded = SpatialIndexSystem.init(testing.allocator);
    defer banded.deinit();
    _ = try banded.beginBuild(population, brute_force_geometry, config);
    _ = try banded.buildBanded(&data, population, testStages(&threads, &tuners, 3, 16, 16, 16), testSplitters(.pairs, reference.cell_keys.items));

    const query_factions = [_]FactionSet{ .full, .initOne(.hostile), .initMany(&.{ .neutral, .ally }), .initMany(&.{ .player, .ally }) };
    for ([_]*const SpatialIndexSystem{ &serial, &banded }) |system| {
        const index = system.view();
        const tags = EntryTags.read(&data, index);
        for (0..index.x.len) |origin| {
            // The origin's own level and one other.
            for ([_]u16{ tags.level[origin], (tags.level[origin] + 1) % 3 }) |level| {
                for ([_]f32{ 0, 20, 100, 300 }) |radius| {
                    for ([_]u16{ 16, 1000 }) |checks| {
                        for (query_factions) |factions| {
                            const query = NeighborQuery{ .x = index.x[origin], .y = index.y[origin], .level = level, .radius = radius, .max_candidate_checks = checks, .factions = factions, .self = index.entityAt(@intCast(origin)) };
                            var expected = RecordingVisitor{};
                            const expected_stats = bruteForceVisits(index, &tags, query, &expected);
                            var actual = RecordingVisitor{};
                            const actual_stats = index.queryNeighbors(query, &actual);
                            try testing.expectEqual(expected_stats, actual_stats);
                            try expected.expectEqual(&actual);
                        }
                    }
                }
            }
        }
    }
}

test "queries from inside and outside the grid visit exactly the entries within the strict radius" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    try fillBruteForceLayout(&data);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), brute_force_geometry, testConfig(4));
    const index = system.view();
    const tags = EntryTags.read(&data, index);
    const points = [_][2]f32{ .{ 400, 100 }, .{ 2, 2 }, .{ -30, 120 }, .{ 1050, 20 }, .{ 500, 280 }, .{ -40, -40 } };
    for (points) |point| {
        for ([_]f32{ 20, 100, 300 }) |radius| {
            for (0..3) |level| {
                const query = NeighborQuery{ .x = point[0], .y = point[1], .level = @intCast(level), .radius = radius, .max_candidate_checks = std.math.maxInt(u16) };
                var expected = RecordingVisitor{};
                const expected_stats = bruteForceVisits(index, &tags, query, &expected);
                var actual = RecordingVisitor{};
                const actual_stats = index.queryNeighbors(query, &actual);
                try testing.expectEqual(expected_stats, actual_stats);
                try expected.expectEqual(&actual);
                // Exactly the entries within the radius by true distance.
                var within: usize = 0;
                for (0..index.x.len) |entry| {
                    const dx = point[0] - index.x[entry];
                    const dy = point[1] - index.y[entry];
                    if (tags.level[entry] == level and dx * dx + dy * dy < radius * radius) within += 1;
                }
                try testing.expectEqual(within, actual.count);
            }
        }
    }
}

test "row parts hold each chunk row's cells at their local x, and a chunk or row part straddling bands keeps one slot and one row record" {
    // Cell size 10: cells 15 | 16, 31 | 32, 47 lie at local x 15 | 0, 15 | 0, 15 of chunks
    // 0..2 in row 0, and cell (20, 3) in chunk 1's row 3; one body per cell.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for ([_]u32{ 15, 16, 31, 32, 47 }) |cell_x| _ = try addTestBody(&data, @as(f32, @floatFromInt(cell_x)) * 10 + 5, 5);
    _ = try addTestBody(&data, 205, 35);
    const population = aiPopulation(&data);
    const geometry = testGeometry(10, 4, 1);
    const config = testConfig(10);

    var serial = SpatialIndexSystem.init(testing.allocator);
    defer serial.deinit();
    _ = try serial.buildSerial(&data, population, geometry, config);
    const one_band = serial.view();
    // Chunk-major: chunk 0's row 0, chunk 1's rows 0 and 3, chunk 2's row 0.
    try testing.expectEqualSlices(RowPart, &.{
        .{ .cells = 1 << 15, .first_cell = 0 },
        .{ .cells = 1 | 1 << 15, .first_cell = 1 },
        .{ .cells = 1 << 4, .first_cell = 3 },
        .{ .cells = 1 | 1 << 15, .first_cell = 4 },
    }, one_band.rows);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6 }, one_band.cells);
    const neutral = factionIndex(.neutral);
    const expected_records = [_]struct { row_mask: u64, first_row: u32 }{ .{ .row_mask = 1, .first_row = 0 }, .{ .row_mask = 1 | 1 << 3, .first_row = 1 }, .{ .row_mask = 1, .first_row = 3 } };
    try testing.expectEqual(expected_records.len, one_band.chunk_records.len);
    for (expected_records, one_band.chunk_records, one_band.level_slots[0][0..3], 0..) |want, record, slot, chunk| {
        try testing.expectEqual(one_band.build_stamp, slot.build);
        try testing.expectEqual(@as(u32, @intCast(chunk)), slot.record);
        try testing.expectEqual(want.row_mask, record.row_masks[neutral]);
        try testing.expectEqual(want.first_row, record.first_rows[neutral]);
    }
    try testing.expect(one_band.level_slots[0][3].build != one_band.build_stamp);

    // A splitter at chunk 1's row 3 puts its row parts in two bands; one at its row 0's
    // second cell puts that row part's cells in two bands.
    var reference = try TestCapture.capture(&serial);
    defer reference.deinit();
    try testing.expectEqual(reference.cell_keys.items[3], testSplitters(.straddle_chunk, reference.cell_keys.items)[0]);
    try testing.expectEqual(reference.cell_keys.items[2], testSplitters(.straddle_row, reference.cell_keys.items)[0]);
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = if (builtin.single_threaded) 0 else 2 });
    defer threads.deinit();
    var tuners: [3]AdaptiveWorkTuner = @splat(AdaptiveWorkTuner.init(.{}));
    var banded = SpatialIndexSystem.init(testing.allocator);
    defer banded.deinit();
    const query = NeighborQuery{ .x = 325, .y = 5, .level = 0, .radius = 1000, .max_candidate_checks = 64 };
    var one_band_visits = RecordingVisitor{};
    _ = one_band.queryNeighbors(query, &one_band_visits);
    try testing.expectEqual(@as(usize, 6), one_band_visits.count);
    for ([_]TestSplitters{ .straddle_chunk, .straddle_row }) |set| {
        _ = try banded.beginBuild(population, geometry, config);
        _ = try banded.buildBanded(&data, population, testStages(&threads, &tuners, 2, 16, 16, 16), testSplitters(set, reference.cell_keys.items));
        try expectIndexMatches(&banded, &reference, &serial);
        // Both indexes visit every entry, in order, across the chunk edges.
        var two_band_visits = RecordingVisitor{};
        _ = banded.view().queryNeighbors(query, &two_band_visits);
        try one_band_visits.expectEqual(&two_band_visits);
    }
}

test "index keys in lanes match keyForPosition, including the scalar tail, at 12 and 16 cells per chunk" {
    // 25 slots: six lane blocks and a one-slot tail, some outside the grid, on levels 0..5,
    // of every faction. Cell size 32 gives 12 cells per 384-unit chunk and 16 per 512-unit
    // chunk.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..25) |slot| {
        _ = try addTaggedBody(&data, @as(f32, @floatFromInt(slot % 23)) * 47.0 - 40.0, @as(f32, @floatFromInt(slot / 23)) * 405.0 - 20.0, @intCast(slot % 6), @fromBackingInt(@intCast(slot % 4)));
    }
    for ([_]f32{ 24, 32 }) |tile_size| {
        const geometry = IndexGeometry{ .tile_size = tile_size, .chunk_size_tiles = 16, .chunks_x = 2, .chunks_y = 2, .level_count = 1 };
        var system = SpatialIndexSystem.init(testing.allocator);
        defer system.deinit();
        const stats = try system.buildSerial(&data, aiPopulation(&data), geometry, .{});
        try testing.expectEqual(@as(usize, 25), stats.entity_count);
        try testing.expectEqual(@as(u32, if (tile_size == 24) 12 else 16), system.grid.cells_per_chunk);
        try testing.expectEqual(@as(f32, 32), system.grid.cell_size);
        for (system.keys.items[0..system.view().entryCount()]) |key| {
            // Recomputed from the fixture's own formula, not read back from the index.
            const slot = keySlot(key);
            const faction: Faction = @fromBackingInt(@intCast(slot % 4));
            const expected = keyForPosition(system.grid, @intCast(slot % 6), @as(f32, @floatFromInt(slot % 23)) * 47.0 - 40.0, @as(f32, @floatFromInt(slot / 23)) * 405.0 - 20.0, factionIndex(faction), slot);
            try testing.expectEqual(expected, key);
        }
    }
}

// Entries `[start, end)` but `skip` visited one at a time with the query's semantics: the
// scalar reference of the lane visit. Returns true when the query ends; `met_skip` is set
// when the walk reaches `skip` inside the budget.
fn visitScalar(index: SpatialIndexView, query: NeighborQuery, start: u32, end: u32, skip: u32, visitor: *RecordingVisitor, stats: *NeighborQueryStats, met_skip: *bool) bool {
    for (start..end) |entry| {
        if (entry == skip) {
            met_skip.* = stats.candidate_checks < query.max_candidate_checks;
            continue;
        }
        if (stats.candidate_checks >= query.max_candidate_checks) return true;
        stats.candidate_checks += 1;
        const dx = query.x - index.x[entry];
        const dy = query.y - index.y[entry];
        const dist2 = dx * dx + dy * dy;
        if (dist2 < query.radius * query.radius and visitor.record(@intCast(entry), dx, dy, dist2)) return true;
    }
    return false;
}

test "the run visit in lanes matches the scalar visit over run offsets, the column end, self anywhere, every budget, and a stop" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    // Nine bodies in cell (0, 0): one NaN position, one exactly at the radius.
    const positions = [_][2]f32{ .{ 1, 1 }, .{ 2, 3 }, .{ 0, 0 }, .{ 4, 4 }, .{ 9, 1 }, .{ 3, 0 }, .{ 5, 5 }, .{ 1, 8 }, .{ 7, 7 } };
    for (positions) |position| _ = try addTestBody(&data, position[0], position[1]);
    data.movementBodySlice().previous_x[4] = std.math.nan(f32);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(10, 1, 1), testConfig(10));
    const index = system.view();
    try testing.expectEqual(@as(usize, 1), index.rows.len);
    const column_end: u32 = positions.len;

    // Runs from offsets 0..3, over-reading the entries past them, to every end up to the
    // column's, where the last batch fills.
    for (0..simd.lane_count) |start| {
        for (start + 1..column_end + 1) |end| {
            // Self at every entry of the column, inside the run or not, then none.
            for (0..column_end + 1) |self_at| {
                const self: EntityId = if (self_at == column_end) EntityId.invalid else index.entityAt(@intCast(self_at));
                const skip: u32 = if (self_at >= start and self_at < end) @intCast(self_at) else no_entry;
                for (0..end - start + 2) |checks| {
                    for ([_]usize{ std.math.maxInt(usize), 1, 2 }) |stop_after| {
                        const query = NeighborQuery{ .x = 2, .y = 1, .level = 0, .radius = 3, .max_candidate_checks = @intCast(checks), .self = self };
                        const self_index = if (self.isValid()) self.index else no_entry;
                        var scan = Scan{
                            .x = index.x,
                            .y = index.y,
                            .entity_index = index.entity_index,
                            .entity_generation = index.entity_generation,
                            .query_x = query.x,
                            .query_y = query.y,
                            .lane_x = simd.splatFloat4(query.x),
                            .lane_y = simd.splatFloat4(query.y),
                            .lane_radius2 = simd.splatFloat4(query.radius * query.radius),
                            .cap = query.max_candidate_checks,
                            .self_index = self_index,
                            .self_generation = self.generation,
                            .lane_self = simd.splatUint4(self_index),
                        };
                        var lanes = RecordingVisitor{ .stop_after = stop_after };
                        const lane_stop = visitRun(&scan, @intCast(start), @intCast(end), true, &lanes);
                        var scalar = RecordingVisitor{ .stop_after = stop_after };
                        var scalar_stats = NeighborQueryStats{};
                        var met_self = false;
                        const scalar_stop = visitScalar(index, query, @intCast(start), @intCast(end), skip, &scalar, &scalar_stats, &met_self);
                        // The lane scan may also end with the budget spent and only self left.
                        try testing.expect(scalar_stop == lane_stop or (lane_stop and scan.checks == query.max_candidate_checks));
                        try testing.expectEqual(scalar_stats.candidate_checks, scan.checks);
                        try scalar.expectEqual(&lanes);
                        // A self the budget reaches before any stop is met in its batch.
                        if (met_self and scalar.count < stop_after and self_at - start < checks) try testing.expectEqual(no_entry, scan.self_index);
                    }
                }
            }
        }
    }
}

test "self in a dense cell is skipped where the budget reaches it and costs no check past it" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    var prng = std.Random.DefaultPrng.init(0xde45_e5e1);
    const random = prng.random();
    for (0..512) |_| _ = try addTestBody(&data, 1 + random.float(f32) * 8, 1 + random.float(f32) * 8);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(10, 4, 1), testConfig(10));
    const index = system.view();
    try testing.expectEqual(@as(usize, 1), index.rows.len);

    var expected: [16]u32 = undefined;
    for ([_]u32{ 5, 511 }) |self_at| {
        const self = index.entityAt(self_at);
        var visitor = RecordingVisitor{};
        const stats = index.queryNeighbors(.{ .x = index.x[self_at], .y = index.y[self_at], .level = 0, .radius = 100, .max_candidate_checks = 16, .self = self }, &visitor);
        try testing.expectEqual(@as(u16, 16), stats.candidate_checks);
        var next: u32 = 0;
        for (&expected) |*entry| {
            if (next == self_at) next += 1;
            entry.* = next;
            next += 1;
        }
        try testing.expectEqualSlices(u32, &expected, visitor.visited());
    }
}

test "a self indexed in another piece than the query point's is a candidate" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const self = try addTestBody(&data, 5, 5);
    const other = try addTestBody(&data, 6, 25);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(10, 4, 1), testConfig(10));
    const index = system.view();

    // Two cell rows below self's: self is in the box but not in the query point's piece.
    var visitor = RecordingVisitor{};
    const stats = index.queryNeighbors(.{ .x = 5, .y = 25, .level = 0, .radius = 30, .max_candidate_checks = 64, .self = self }, &visitor);
    var visited: [2]EntityId = undefined;
    try testing.expectEqualSlices(EntityId, &.{ self, other }, visitedEntities(index, &visitor, &visited));
    try testing.expectEqual(@as(u16, 2), stats.candidate_checks);

    // From self's own position it is skipped.
    var own = RecordingVisitor{};
    const own_stats = index.queryNeighbors(.{ .x = 5, .y = 5, .level = 0, .radius = 30, .max_candidate_checks = 64, .self = self }, &own);
    try testing.expectEqualSlices(EntityId, &.{other}, visitedEntities(index, &own, &visited));
    try testing.expectEqual(@as(u16, 1), own_stats.candidate_checks);
}

test "a radius of 1e30 scans the whole level without overflow" {
    try testing.expectEqual(@as(i32, std.math.maxInt(i32)), cellScanRadius(1e30, 32));
    for ([_]f32{ 0, 16, 32, 48 }, [_]i32{ 0, 1, 1, 2 }) |radius, cells| try testing.expectEqual(cells, cellScanRadius(radius, 32));

    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    try fillBruteForceLayout(&data);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), brute_force_geometry, testConfig(4));
    const index = system.view();
    const tags = EntryTags.read(&data, index);
    for (0..3) |level| {
        const query = NeighborQuery{ .x = index.x[0], .y = index.y[0], .level = @intCast(level), .radius = 1e30, .max_candidate_checks = std.math.maxInt(u16), .self = index.entityAt(0) };
        var expected = RecordingVisitor{};
        const expected_stats = bruteForceVisits(index, &tags, query, &expected);
        var actual = RecordingVisitor{};
        const actual_stats = index.queryNeighbors(query, &actual);
        try testing.expectEqual(expected_stats, actual_stats);
        try expected.expectEqual(&actual);
        try testing.expect(actual.count > 0);
    }
}

test "a build after a populated one leaves no stale cells or slots, serial and threaded" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..40) |slot| _ = try addTestBody(&data, @floatFromInt(slot * 3), 0);
    var empty_data = DataSystem.init(testing.allocator);
    defer empty_data.deinit();
    // Slots, none with a body.
    for (0..20) |_| _ = try addTestBodiless(&empty_data);
    // A body in chunk (1, 1) only.
    var moved_data = DataSystem.init(testing.allocator);
    defer moved_data.deinit();
    _ = try addTestBody(&moved_data, 600, 600);

    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = if (builtin.single_threaded) 0 else 2 });
    defer threads.deinit();
    const geometry = testGeometry(32, 4, 1);

    const empties = [_]IndexPopulation{ aiPopulation(&empty_data), .{ .entities = &.{} } };
    for (empties) |empty| {
        for ([_]bool{ false, true }) |threaded| {
            _ = try system.buildSerial(&data, aiPopulation(&data), geometry, .{});
            try testing.expect(system.view().entryCount() == 40);
            const stats = if (threaded)
                try system.build(&empty_data, empty, geometry, &threads, .{ .items_per_range = 16, .adaptive = false })
            else
                try system.buildSerial(&empty_data, empty, geometry, .{});
            try testing.expectEqual(@as(usize, 0), stats.entity_count);
            const index = system.view();
            try testing.expectEqual(@as(usize, 0), index.entryCount());
            try testing.expectEqual(@as(usize, 0), index.rows.len);
            try testing.expect(index.factions.eql(.empty));
            for (index.level_slots) |slots| {
                for (slots) |slot| try testing.expect(slot.build != index.build_stamp);
            }
            var visitor = RecordingVisitor{};
            const query_stats = index.queryNeighbors(.{ .x = 3, .y = 0, .level = 0, .radius = 64, .max_candidate_checks = 64 }, &visitor);
            try testing.expectEqual(@as(usize, 0), visitor.count);
            try testing.expectEqual(@as(u16, 0), query_stats.candidate_checks);
        }
    }

    // Chunk (0, 0) populated in one build and empty in the next is rejected by its stamp.
    _ = try system.buildSerial(&data, aiPopulation(&data), geometry, .{});
    _ = try system.buildSerial(&moved_data, aiPopulation(&moved_data), geometry, .{});
    const moved = system.view();
    try testing.expect(moved.level_slots[0][0].build != moved.build_stamp);
    try testing.expectEqual(moved.build_stamp, moved.level_slots[0][4 + 1].build);
    var near_origin = RecordingVisitor{};
    _ = moved.queryNeighbors(.{ .x = 3, .y = 0, .level = 0, .radius = 64, .max_candidate_checks = 64 }, &near_origin);
    try testing.expectEqual(@as(usize, 0), near_origin.count);
    try expectRecordsAgree(&system);
}

test "the level directories follow the geometry: reset on a grid change, grown for a body's level, and the tail released" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const body = try addTestBody(&data, 10, 10);
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(32, 4, 2), .{});
    try testing.expectEqual(@as(usize, 2), system.level_slots.items.len);
    try testing.expectEqual(2 * 16 * chunk_slot_bytes, system.directoryBytes());

    // A body on a level past the geometry's gets its directory, and the next build without
    // it releases the tail.
    try data.setWorldLevel(body, 4);
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(32, 4, 2), .{});
    try testing.expectEqual(@as(usize, 5), system.level_slots.items.len);
    var visitor = RecordingVisitor{};
    _ = system.view().queryNeighbors(.{ .x = 10, .y = 10, .level = 4, .radius = 8, .max_candidate_checks = 8 }, &visitor);
    try testing.expectEqual(@as(usize, 1), visitor.count);
    try data.setWorldLevel(body, 1);
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(32, 4, 2), .{});
    try testing.expectEqual(@as(usize, 2), system.level_slots.items.len);

    // An empty build, with no slots or with only bodiless ones, serial and threaded,
    // releases the tail too.
    var bodiless_data = DataSystem.init(testing.allocator);
    defer bodiless_data.deinit();
    for (0..20) |_| _ = try addTestBodiless(&bodiless_data);
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = if (builtin.single_threaded) 0 else 2 });
    defer threads.deinit();
    const empties = [_]struct { data: *const DataSystem, population: IndexPopulation }{
        .{ .data = &data, .population = .{ .entities = &.{} } },
        .{ .data = &bodiless_data, .population = aiPopulation(&bodiless_data) },
    };
    for (empties) |empty| {
        for ([_]bool{ false, true }) |threaded| {
            try data.setWorldLevel(body, 4);
            _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(32, 4, 2), .{});
            try testing.expectEqual(@as(usize, 5), system.level_slots.items.len);
            const stats = if (threaded)
                try system.build(empty.data, empty.population, testGeometry(32, 4, 2), &threads, .{ .items_per_range = 16, .adaptive = false })
            else
                try system.buildSerial(empty.data, empty.population, testGeometry(32, 4, 2), .{});
            try testing.expectEqual(@as(usize, 0), stats.entity_count);
            try testing.expectEqual(@as(usize, 2), system.level_slots.items.len);
            try testing.expectEqual(2 * 16 * chunk_slot_bytes, system.directoryBytes());
        }
    }
    try data.setWorldLevel(body, 1);

    // A grid change rebuilds every directory at the new chunk count.
    _ = try system.buildSerial(&data, aiPopulation(&data), testGeometry(32, 8, 3), .{});
    try testing.expectEqual(@as(usize, 3), system.level_slots.items.len);
    try testing.expectEqual(3 * 64 * chunk_slot_bytes, system.directoryBytes());
    for (system.level_slots.items) |slots| try testing.expectEqual(@as(usize, 64), slots.len);
    try expectRecordsAgree(&system);
}

test "the index cell is the configured cell rounded to a whole fraction of the chunk, never refusing a geometry" {
    const default_world = IndexGeometry{ .tile_size = 32, .chunk_size_tiles = 16, .chunks_x = 8, .chunks_y = 8, .level_count = 1 };
    const default_grid = Grid.of(default_world, (SpatialIndexConfig{}).cell_size);
    try testing.expectEqual(@as(u32, 16), default_grid.cells_per_chunk);
    try testing.expectEqual(@as(f32, 32), default_grid.cell_size);
    try testing.expectEqual(@as(u32, 128), default_grid.cells_x);

    var tile_30 = default_world;
    tile_30.tile_size = 30;
    try testing.expectEqual(@as(u32, 15), Grid.of(tile_30, 32).cells_per_chunk);

    const tiny = IndexGeometry{ .tile_size = 2, .chunk_size_tiles = 1, .chunks_x = 3, .chunks_y = 2, .level_count = 1 };
    const tiny_grid = Grid.of(tiny, 32);
    try testing.expectEqual(@as(u32, 1), tiny_grid.cells_per_chunk);
    try testing.expectEqual(@as(f32, 2), tiny_grid.cell_size);

    var huge = default_world;
    huge.tile_size = 1e6;
    try testing.expectEqual(max_cells_per_chunk, Grid.of(huge, 32).cells_per_chunk);

    const wide = IndexGeometry{ .tile_size = 32, .chunk_size_tiles = 64, .chunks_x = 1 << 26, .chunks_y = 1, .level_count = 1 };
    const wide_grid = Grid.of(wide, 32);
    try testing.expectEqual(@as(u32, std.math.maxInt(i32) / (1 << 26)), wide_grid.cells_per_chunk);
    try testing.expect(wide_grid.cells_x <= std.math.maxInt(i32));
}

test "the index builds correctly above a small reserved capacity" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..40) |slot| _ = try addTestBody(&data, @floatFromInt(slot * 7), @floatFromInt(slot % 5));
    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    try system.reserve(4);
    const stats = try system.buildSerial(&data, aiPopulation(&data), testGeometry(32, 4, 1), .{});
    try testing.expectEqual(@as(usize, 40), stats.entity_count);
    try testing.expectEqual(@as(usize, 40), system.view().entryCount());
    try testing.expect(system.view().rows.len > 0);
}

test "after reserve and reserveGeometry, threaded builds at 2 and 4 partitions per stage, a serial build, and queries allocate nothing" {
    // No warm build: the reserves alone cover every partition the tuners can pick.
    if (builtin.single_threaded) return error.SkipZigTest;

    // One body per cell, so the link stage partitions like the others.
    const population_count: usize = 64;
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..population_count) |slot| {
        const entity = try addTestBody(&data, @as(f32, @floatFromInt(slot % 16)) * 40.0 + 5, @as(f32, @floatFromInt(slot / 16)) * 40.0 + 5);
        try data.setFaction(entity, @fromBackingInt(@intCast(slot % 4)));
    }
    const population = aiPopulation(&data);
    const geometry = testGeometry(32, 4, 1);

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    // Without real workers the threaded build runs serially and this proof passes falsely.
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var reference = SpatialIndexSystem.init(testing.allocator);
    defer reference.deinit();
    _ = try reference.buildSerial(&data, population, geometry, .{});

    var system = SpatialIndexSystem.init(testing.allocator);
    defer system.deinit();
    try system.reserve(population_count);
    try system.reserveGeometry(geometry, .{});
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original_allocator = system.allocator;
    system.allocator = failing.allocator();
    defer system.allocator = original_allocator;

    for ([_]usize{ 32, 16 }) |items_per_range| {
        const stats = try system.build(&data, population, geometry, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = 2, .adaptive = false });
        try testing.expectEqual(population_count, stats.entity_count);
        try testing.expect(!stats.bucket_batch.ran_inline and !stats.sort_batch.ran_inline and !stats.link_batch.ran_inline);
        for ([_]BatchStats{ stats.bucket_batch, stats.sort_batch, stats.link_batch }) |batch| {
            try testing.expectEqual(population_count / items_per_range, batch.range_count);
        }
        try testing.expectEqualSlices(u32, reference.view().entity_index, system.view().entity_index);
        try testing.expectEqualSlices(u32, reference.view().entity_generation, system.view().entity_generation);
    }
    const serial_stats = try system.buildSerial(&data, population, geometry, .{});
    try testing.expectEqual(population_count, serial_stats.entity_count);
    var visitor = RecordingVisitor{};
    const full_stats = system.view().queryNeighbors(.{ .x = 0, .y = 0, .level = 0, .radius = 400, .max_candidate_checks = 16 }, &visitor);
    try testing.expectEqual(@as(u16, 16), full_stats.candidate_checks);
    try testing.expect(visitor.count > 0);
    for ([_]FactionSet{ .initMany(&.{ .neutral, .hostile }), .initMany(&.{ .player, .ally }) }) |factions| {
        var masked = RecordingVisitor{};
        const masked_stats = system.view().queryNeighbors(.{ .x = 0, .y = 0, .level = 0, .radius = 400, .max_candidate_checks = 16, .factions = factions }, &masked);
        try testing.expectEqual(@as(u16, 16), masked_stats.candidate_checks);
        try testing.expect(masked.count > 0);
    }
    try testing.expectEqual(@as(usize, 0), failing.allocations);
}
