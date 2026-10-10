// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared static-collider rows: one row per static navigation obstacle (an entity with a
//! movement body, collision bounds, and a static collision response), holding its
//! committed world AABB, its level, and the cell span it covers, listed per (level, chunk)
//! in entity-index order. Rows change only at the structural-commit seam: the step's
//! entity changes are captured into a persistent dirty list right after the commit and
//! applied by `sync` from the entities' final state, so each changed entity costs its own
//! footprint chunks (none when its chunks are unchanged), never the static count. Readers
//! (nav) take a `ColliderView`.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../core/math.zig");
const logging = @import("../../core/logging.zig");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const ChunkListMap = @import("chunk_list_map.zig").ChunkListMap;
const chunkKey = @import("chunk_list_map.zig").chunkKey;
const no_entry = @import("chunk_list_map.zig").no_entry;
const SpliceThreads = @import("chunk_list_map.zig").SpliceThreads;

const no_row: u32 = std.math.maxInt(u32);

// Half-open-rect shrink applied to an AABB's max corner before it maps to a cell, so a
// rect whose edge lands exactly on a cell boundary does not cover the next cell.
const footprint_edge_epsilon: f32 = 0.001;

/// The cell grid rows are placed on: `cell_size` world units per cell, `width` x
/// `height` cells per level, `chunk_tiles` (a power of two) cells per chunk edge.
pub const ColliderGeometry = struct {
    cell_size: f32,
    width: u32,
    height: u32,
    chunk_tiles: u16,

    fn chunkShift(self: ColliderGeometry) u5 {
        return @intCast(@ctz(self.chunk_tiles));
    }

    pub fn chunksX(self: ColliderGeometry) u32 {
        return (self.width + self.chunk_tiles - 1) >> self.chunkShift();
    }

    /// The inclusive cells `aabb` covers, clamped to the grid: its min corner's cell to its
    /// max corner's cell, the max corner shrunk by an epsilon first.
    pub fn footprint(self: ColliderGeometry, aabb: math.Aabb) CellSpan {
        const min_x = math.worldPosToCell(aabb.min_x, self.cell_size, self.width);
        const min_y = math.worldPosToCell(aabb.min_y, self.cell_size, self.height);
        const max_x = math.worldPosToCell(@max(aabb.min_x, aabb.max_x - footprint_edge_epsilon), self.cell_size, self.width);
        const max_y = math.worldPosToCell(@max(aabb.min_y, aabb.max_y - footprint_edge_epsilon), self.cell_size, self.height);
        return .{ .min_x = @min(min_x, max_x), .min_y = @min(min_y, max_y), .max_x = @max(min_x, max_x), .max_y = @max(min_y, max_y) };
    }

    fn chunkRect(self: ColliderGeometry, placement: Placement) ChunkRect {
        const shift = self.chunkShift();
        return .{
            .level = placement.level,
            .chunks_x = self.chunksX(),
            .min_x = placement.cells.min_x >> shift,
            .min_y = placement.cells.min_y >> shift,
            .max_x = placement.cells.max_x >> shift,
            .max_y = placement.cells.max_y >> shift,
        };
    }
};

// The inclusive chunk rectangle a placement covers on its level; `contains` tests a
// `chunkKey` for `ChunkListMap.unlinkOwnerOutside`.
const ChunkRect = struct {
    level: u16,
    chunks_x: u32,
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,

    fn count(self: ChunkRect) usize {
        return (@as(usize, self.max_x) - self.min_x + 1) * (@as(usize, self.max_y) - self.min_y + 1);
    }

    fn holds(self: ChunkRect, chunk_x: u32, chunk_y: u32) bool {
        return chunk_x >= self.min_x and chunk_x <= self.max_x and chunk_y >= self.min_y and chunk_y <= self.max_y;
    }

    pub fn contains(self: ChunkRect, key: u64) bool {
        const level: u16 = @truncate(key >> 32);
        const chunk: u32 = @truncate(key);
        return level == self.level and self.holds(chunk % self.chunks_x, chunk / self.chunks_x);
    }

    fn eql(self: ChunkRect, other: ChunkRect) bool {
        return self.level == other.level and self.min_x == other.min_x and self.min_y == other.min_y and self.max_x == other.max_x and self.max_y == other.max_y;
    }

    // Chunks `self` and `other` share (zero across levels).
    fn overlap(self: ChunkRect, other: ChunkRect) usize {
        if (self.level != other.level) return 0;
        const min_x = @max(self.min_x, other.min_x);
        const min_y = @max(self.min_y, other.min_y);
        const max_x = @min(self.max_x, other.max_x);
        const max_y = @min(self.max_y, other.max_y);
        if (min_x > max_x or min_y > max_y) return 0;
        return (@as(usize, max_x) - min_x + 1) * (@as(usize, max_y) - min_y + 1);
    }
};

// `ChunkListMap.unlinkOwnerOutside` keep set that keeps nothing.
const KeepNone = struct {
    pub fn contains(_: KeepNone, _: u64) bool {
        return false;
    }
};

// One pending index's row after the sync: its placement and AABB, or null for no row.
const PlannedRow = struct { placement: Placement, aabb: math.Aabb };

/// An inclusive cell rectangle.
pub const CellSpan = struct { min_x: u32, min_y: u32, max_x: u32, max_y: u32 };

/// Where a row sits: its level and the cells it covers.
pub const Placement = struct { level: u16, cells: CellSpan };

/// One entity's row change at the last sync: its placement before (null when it had no
/// row) and after (null when it has none now).
pub const ColliderChange = struct {
    entity: EntityId,
    old: ?Placement,
    new: ?Placement,
};

const Row = struct {
    entity: EntityId,
    level: u16,
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,
    cell_min_x: u32,
    cell_min_y: u32,
    cell_max_x: u32,
    cell_max_y: u32,
};

/// Read-only rows and chunk lists for readers between seams, safe for concurrent reads:
/// nothing here mutates. Valid until the next `sync` or `rebuild`.
pub const ColliderView = struct {
    /// Null for a system never rebuilt (it holds no rows).
    geometry: ?ColliderGeometry = null,
    lists: ?*const ChunkListMap = null,
    level: []const u16 = &.{},
    min_x: []const f32 = &.{},
    min_y: []const f32 = &.{},
    max_x: []const f32 = &.{},
    max_y: []const f32 = &.{},
    cell_min_x: []const u32 = &.{},
    cell_min_y: []const u32 = &.{},
    cell_max_x: []const u32 = &.{},
    cell_max_y: []const u32 = &.{},

    /// Whether any row covers a cell of `chunk` on `level`. O(1) expected.
    pub fn chunkHasRows(self: ColliderView, level: u16, chunk: u32) bool {
        const lists = self.lists orelse return false;
        return lists.head(chunkKey(level, chunk)) != no_entry;
    }

    /// The rows covering a cell of `chunk` on `level`, in entity-index order.
    pub fn chunkRows(self: ColliderView, level: u16, chunk: u32) ChunkListMap.Iterator {
        const lists = self.lists orelse return .{ .owners = &.{}, .next_entries = &.{}, .entry = no_entry };
        return lists.iterator(chunkKey(level, chunk));
    }

    pub fn rowCells(self: ColliderView, row: u32) CellSpan {
        return .{ .min_x = self.cell_min_x[row], .min_y = self.cell_min_y[row], .max_x = self.cell_max_x[row], .max_y = self.cell_max_y[row] };
    }
};

pub const StaticColliderSystem = struct {
    allocator: std.mem.Allocator,
    geometry: ?ColliderGeometry = null,
    rows: std.MultiArrayList(Row) = .{},
    // Released row ids; capacity always covers every pooled row. An entity index keeps its
    // row while it stays static, across a destroy and a reusing create.
    row_free: std.ArrayList(u32) = .empty,
    // Per entity index, its row or `no_row`.
    row_of_index: std.ArrayList(u32) = .empty,
    // Entity indices whose rows the next `sync` re-derives, in first-capture order, kept
    // across a failed sync; `dirty_stamp[index] == dirty_generation` marks membership and
    // `dirty_entity[index]` holds the index's last captured id.
    pending_dirty: std.ArrayList(u32) = .empty,
    dirty_stamp: std.ArrayList(u32) = .empty,
    dirty_entity: std.ArrayList(EntityId) = .empty,
    dirty_generation: u32 = 1,
    changes: std.ArrayList(ColliderChange) = .empty,
    // Per pending index, in order: its row after the sync. Sync scratch, high-water.
    sync_plan: std.ArrayList(?PlannedRow) = .empty,
    chunk_lists: ChunkListMap,
    // The chunk lists' splice stage: its tuner and range controls (production runs
    // adaptive; benches pin a fixed partition), and its last batch shape.
    splice_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    splice_adaptive: bool = true,
    splice_items_per_range: ?usize = null,
    last_splice_batch: BatchStats = .{},
    // Column views refreshed whenever the row pool grows.
    row_entity: []EntityId = &.{},
    row_level: []u16 = &.{},
    row_min_x: []f32 = &.{},
    row_min_y: []f32 = &.{},
    row_max_x: []f32 = &.{},
    row_max_y: []f32 = &.{},
    row_cell_min_x: []u32 = &.{},
    row_cell_min_y: []u32 = &.{},
    row_cell_max_x: []u32 = &.{},
    row_cell_max_y: []u32 = &.{},
    /// Telemetry: row-pool growths, logged once.
    row_grows: u64 = 0,
    row_growth_logged: bool = false,

    pub fn init(allocator: std.mem.Allocator) StaticColliderSystem {
        return .{ .allocator = allocator, .chunk_lists = ChunkListMap.init(allocator) };
    }

    pub fn deinit(self: *StaticColliderSystem) void {
        self.chunk_lists.deinit();
        self.sync_plan.deinit(self.allocator);
        self.changes.deinit(self.allocator);
        self.dirty_entity.deinit(self.allocator);
        self.dirty_stamp.deinit(self.allocator);
        self.pending_dirty.deinit(self.allocator);
        self.row_of_index.deinit(self.allocator);
        self.row_free.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    fn refreshColumns(self: *StaticColliderSystem) void {
        const columns = self.rows.slice();
        self.row_entity = columns.items(.entity);
        self.row_level = columns.items(.level);
        self.row_min_x = columns.items(.min_x);
        self.row_min_y = columns.items(.min_y);
        self.row_max_x = columns.items(.max_x);
        self.row_max_y = columns.items(.max_y);
        self.row_cell_min_x = columns.items(.cell_min_x);
        self.row_cell_min_y = columns.items(.cell_min_y);
        self.row_cell_max_x = columns.items(.cell_max_x);
        self.row_cell_max_y = columns.items(.cell_max_y);
    }

    pub fn view(self: *const StaticColliderSystem) ColliderView {
        return .{
            .geometry = self.geometry,
            .lists = &self.chunk_lists,
            .level = self.row_level,
            .min_x = self.row_min_x,
            .min_y = self.row_min_y,
            .max_x = self.row_max_x,
            .max_y = self.row_max_y,
            .cell_min_x = self.row_cell_min_x,
            .cell_min_y = self.row_cell_min_y,
            .cell_max_x = self.row_cell_max_x,
            .cell_max_y = self.row_cell_max_y,
        };
    }

    /// Live rows.
    pub fn rowCount(self: *const StaticColliderSystem) usize {
        return self.rows.len - self.row_free.items.len;
    }

    /// Whether captured changes wait for a `sync` (a failed sync keeps them). O(1).
    pub fn hasPendingChanges(self: *const StaticColliderSystem) bool {
        return self.pending_dirty.items.len != 0;
    }

    /// Entity indices waiting for a `sync`: the next sync records one change per index.
    pub fn pendingChangeCount(self: *const StaticColliderSystem) usize {
        return self.pending_dirty.items.len;
    }

    /// The row changes the last `sync` applied, valid until the next `sync` or `rebuild`.
    pub fn changesThisStep(self: *const StaticColliderSystem) []const ColliderChange {
        return self.changes.items;
    }

    fn rowPlacement(self: *const StaticColliderSystem, row: u32) Placement {
        return .{ .level = self.row_level[row], .cells = .{
            .min_x = self.row_cell_min_x[row],
            .min_y = self.row_cell_min_y[row],
            .max_x = self.row_cell_max_x[row],
            .max_y = self.row_cell_max_y[row],
        } };
    }

    /// Replaces every row with the statics `data` holds now, placed on `geometry`, built
    /// into fresh storage: an error leaves the system unchanged. Drops pending changes.
    /// O(S log S) for S statics; cold (pipeline init, world replace).
    pub fn rebuild(self: *StaticColliderSystem, data: *const DataSystem, geometry: ColliderGeometry) !void {
        std.debug.assert(geometry.chunk_tiles != 0 and std.math.isPowerOfTwo(geometry.chunk_tiles));
        var statics: std.ArrayList(EntityId) = .empty;
        defer statics.deinit(self.allocator);
        const responses = data.collisionResponseSliceConst();
        for (responses.entities, responses.mobilities) |entity, mobility| {
            if (mobility != .static or !data.isStaticNavigationObstacle(entity)) continue;
            try statics.append(self.allocator, entity);
        }
        std.sort.pdq(EntityId, statics.items, {}, struct {
            fn lessThan(_: void, a: EntityId, b: EntityId) bool {
                return a.index < b.index;
            }
        }.lessThan);

        var fresh = StaticColliderSystem.init(self.allocator);
        errdefer fresh.deinit();
        fresh.geometry = geometry;
        // Growth telemetry spans rebuilds: a growth already logged stays logged.
        fresh.row_growth_logged = self.row_growth_logged;
        fresh.chunk_lists.growth_logged = self.chunk_lists.growth_logged;
        var index_count: usize = 0;
        var footprint_chunks: usize = 0;
        for (statics.items) |entity| {
            index_count = @max(index_count, @as(usize, entity.index) + 1);
            footprint_chunks += geometry.chunkRect(fresh.placementOf(data, entity).?).count();
        }
        try fresh.reserveIndices(index_count);
        try fresh.ensureFreeRows(statics.items.len);
        try fresh.chunk_lists.reserve(footprint_chunks, footprint_chunks, fresh.rows.len);
        // Ascending entity index, so every row appends at its lists' tails.
        for (statics.items) |entity| {
            const placement = fresh.placementOf(data, entity).?;
            const row = fresh.claimRow(entity.index);
            fresh.writeRow(row, entity, placement, data.staticObstacleWorldRect(entity).?);
            const rect = geometry.chunkRect(placement);
            var chunk_y = rect.min_y;
            while (chunk_y <= rect.max_y) : (chunk_y += 1) {
                var chunk_x = rect.min_x;
                while (chunk_x <= rect.max_x) : (chunk_x += 1) fresh.chunk_lists.appendTail(row, chunkKey(rect.level, chunk_y * rect.chunks_x + chunk_x), entity.index);
            }
        }
        fresh.splice_tuner = self.splice_tuner;
        fresh.splice_adaptive = self.splice_adaptive;
        fresh.splice_items_per_range = self.splice_items_per_range;
        fresh.row_grows += self.row_grows;
        fresh.chunk_lists.grows += self.chunk_lists.grows;
        self.deinit();
        self.* = fresh;
    }

    // Grows the per-index arrays to cover entity indices below `index_count`.
    fn reserveIndices(self: *StaticColliderSystem, index_count: usize) !void {
        if (self.row_of_index.items.len >= index_count) return;
        try self.row_of_index.ensureTotalCapacity(self.allocator, index_count);
        try self.dirty_stamp.ensureTotalCapacity(self.allocator, index_count);
        try self.dirty_entity.ensureTotalCapacity(self.allocator, index_count);
        try self.pending_dirty.ensureTotalCapacity(self.allocator, index_count);
        const added = index_count - self.row_of_index.items.len;
        self.row_of_index.appendNTimesAssumeCapacity(no_row, added);
        self.dirty_stamp.appendNTimesAssumeCapacity(0, added);
        self.dirty_entity.appendNTimesAssumeCapacity(EntityId.invalid, added);
    }

    // Grows the free row list to at least `needed` ids. Geometric and counted.
    fn ensureFreeRows(self: *StaticColliderSystem, needed: usize) !void {
        if (self.row_free.items.len >= needed) return;
        const added = needed - self.row_free.items.len;
        const total = self.rows.len + added;
        // At most one row per entity index, and entity indices are below maxInt(u32).
        std.debug.assert(total < no_row);
        if (total > self.rows.capacity) {
            try self.rows.ensureTotalCapacity(self.allocator, @max(total, self.rows.capacity *| 2));
            // The pool moved: the column views follow it before anything else can fail.
            self.refreshColumns();
            self.countRowGrowth();
        }
        try self.row_free.ensureTotalCapacity(self.allocator, self.rows.capacity);
        // Pushed in descending id order so pops hand out ascending ids.
        const first: u32 = @intCast(self.rows.len);
        for (0..added) |_| self.rows.appendAssumeCapacity(undefined);
        var id: u32 = @intCast(self.rows.len);
        while (id > first) {
            id -= 1;
            self.row_free.appendAssumeCapacity(id);
        }
        self.refreshColumns();
    }

    fn countRowGrowth(self: *StaticColliderSystem) void {
        self.row_grows += 1;
        if (self.row_growth_logged) return;
        self.row_growth_logged = true;
        if (comptime logging.enabled(.info) and !builtin.is_test)
            logging.game.info("static collider rows grew ({} growths so far)", .{self.row_grows});
    }

    /// The commit seam's reserve, before the structural commit: sizes the dirty list and the
    /// per-index arrays to every entity index the commit can produce (the live slot count
    /// plus one per command), so `capture` after the commit allocates nothing.
    pub fn reserveForCommit(self: *StaticColliderSystem, data: *const DataSystem, command_count: usize) !void {
        // A commit creates at most one entity slot per command.
        try self.reserveIndices(data.slots.items.len + command_count);
    }

    /// Records the committed step's static changes into the dirty list: destroys of a
    /// static, and changes to a body, bounds, response, or level that make or leave an
    /// entity static. Reads only the step's entity change list, so a step without entity
    /// changes costs O(1). Allocation-free after `reserveForCommit`; never fails.
    pub fn capture(self: *StaticColliderSystem, frame: *const SimulationFrame) void {
        const stats = frame.events.stats;
        if (stats.entity_destroyed + stats.component_changed == 0) return;
        for (frame.structural_changes_scratch.items) |change| {
            const entity = switch (change) {
                .entity_created => continue,
                .entity_destroyed => |destroyed| if (destroyed.was_static_navigation_obstacle) destroyed.entity else continue,
                .component_changed => |changed| switch (changed.component) {
                    .movement_body, .collision_bounds, .collision_response, .world_level => if (changed.was_static_navigation_obstacle or changed.is_static_navigation_obstacle) changed.entity else continue,
                    else => continue,
                },
            };
            self.markDirty(entity);
        }
    }

    fn markDirty(self: *StaticColliderSystem, entity: EntityId) void {
        const index = entity.index;
        // `reserveForCommit` sized the per-index arrays before the commit.
        std.debug.assert(index < self.dirty_stamp.items.len);
        self.dirty_entity.items[index] = entity;
        if (self.dirty_stamp.items[index] == self.dirty_generation) return;
        self.dirty_stamp.items[index] = self.dirty_generation;
        std.debug.assert(self.pending_dirty.items.len < self.pending_dirty.capacity);
        self.pending_dirty.appendAssumeCapacity(index);
    }

    /// Applies every captured change from `data`'s final state: per dirty index, its row
    /// follows its last captured id (kept, moved, freed, or claimed) and is listed in exactly
    /// the chunks it covers. Records one `ColliderChange` per dirty index. The main thread
    /// does O(1) per change, plus O(1) per footprint chunk of a row whose level or chunks
    /// changed (its unlinks and staged inserts); a row whose level and chunks are unchanged
    /// touches no list. The sorted list placement runs in the chunk lists' splice
    /// stage, threaded under `thread_system`; lists are identical for any partition. Every
    /// reserve runs first: on error nothing changes and the dirty list stays for the next
    /// sync. The change list resets on every call.
    // SIMD verdict: scalar. Per changed entity, gather-bound placement reads
    // (`isStaticNavigationObstacle`, the obstacle rect) and branchy row and list edits.
    pub fn sync(self: *StaticColliderSystem, data: *const DataSystem, thread_system: ?*ThreadSystem) !void {
        self.changes.clearRetainingCapacity();
        self.last_splice_batch = .{};
        const pending = self.pending_dirty.items;
        if (pending.len == 0) return;
        const geometry = self.geometry.?;

        // Plan each dirty index's row and count what the sync claims: rows for adds, list
        // entries for chunks entered, removals for chunks left.
        try self.sync_plan.ensureTotalCapacity(self.allocator, pending.len);
        self.sync_plan.clearRetainingCapacity();
        var adds: usize = 0;
        var inserts: usize = 0;
        var removals: usize = 0;
        for (pending) |index| {
            const entity = self.dirty_entity.items[index];
            const old_row = self.row_of_index.items[index];
            const old_rect: ?ChunkRect = if (old_row != no_row) geometry.chunkRect(self.rowPlacement(old_row)) else null;
            const planned: ?PlannedRow = if (self.placementOf(data, entity)) |placement| .{ .placement = placement, .aabb = data.staticObstacleWorldRect(entity).? } else null;
            if (planned) |next| {
                const new_rect = geometry.chunkRect(next.placement);
                if (old_rect == null) adds += 1;
                inserts += new_rect.count() - if (old_rect) |old| new_rect.overlap(old) else 0;
            }
            if (old_rect) |old| removals += old.count() - if (planned) |next| old.overlap(geometry.chunkRect(next.placement)) else 0;
            self.sync_plan.appendAssumeCapacity(planned);
        }
        try self.ensureFreeRows(adds);
        try self.chunk_lists.reserve(inserts, inserts, self.rows.len);
        try self.chunk_lists.reserveBatch(inserts, removals);
        try self.changes.ensureTotalCapacity(self.allocator, pending.len);

        self.chunk_lists.beginBatch();
        for (pending, self.sync_plan.items) |index, planned| {
            const entity = self.dirty_entity.items[index];
            const old_row = self.row_of_index.items[index];
            var change = ColliderChange{ .entity = entity, .old = null, .new = null };
            if (old_row != no_row) change.old = self.rowPlacement(old_row);
            if (planned) |next| {
                const row = if (old_row != no_row) old_row else self.claimRow(index);
                const new_rect = geometry.chunkRect(next.placement);
                if (change.old) |old| {
                    const old_rect = geometry.chunkRect(old);
                    if (!new_rect.eql(old_rect)) {
                        if (new_rect.level == old_rect.level) self.chunk_lists.unlinkOwnerOutside(row, new_rect) else self.chunk_lists.unlinkOwnerOutside(row, KeepNone{});
                        self.stageRowChunks(row, entity.index, new_rect, old_rect);
                    }
                } else {
                    self.stageRowChunks(row, entity.index, new_rect, null);
                }
                self.writeRow(row, entity, next.placement, next.aabb);
                change.new = next.placement;
            } else if (old_row != no_row) {
                self.chunk_lists.unlinkOwnerOutside(old_row, KeepNone{});
                std.debug.assert(self.row_free.items.len < self.row_free.capacity);
                self.row_free.appendAssumeCapacity(old_row);
                self.row_of_index.items[index] = no_row;
            }
            self.changes.appendAssumeCapacity(change);
        }
        const threads: ?SpliceThreads = if (thread_system) |ts| .{
            .thread_system = ts,
            .tuner = &self.splice_tuner,
            .adaptive = self.splice_adaptive,
            .items_per_range = self.splice_items_per_range,
        } else null;
        self.last_splice_batch = self.chunk_lists.commitBatch(threads);

        self.pending_dirty.clearRetainingCapacity();
        self.dirty_generation +%= 1;
        if (self.dirty_generation == 0) {
            @memset(self.dirty_stamp.items, 0);
            self.dirty_generation = 1;
        }
    }

    // `entity`'s placement when it is a live static navigation obstacle.
    fn placementOf(self: *const StaticColliderSystem, data: *const DataSystem, entity: EntityId) ?Placement {
        if (!data.isStaticNavigationObstacle(entity)) return null;
        const aabb = data.staticObstacleWorldRect(entity) orelse return null;
        return .{ .level = data.worldLevelConst(entity) orelse 0, .cells = self.geometry.?.footprint(aabb) };
    }

    // Takes a free row for entity index `index`; the reserve grew the free list.
    fn claimRow(self: *StaticColliderSystem, index: u32) u32 {
        std.debug.assert(self.row_free.items.len != 0);
        const row = self.row_free.pop().?;
        std.debug.assert(self.row_of_index.items[index] == no_row);
        self.row_of_index.items[index] = row;
        return row;
    }

    fn writeRow(self: *StaticColliderSystem, row: u32, entity: EntityId, placement: Placement, aabb: math.Aabb) void {
        self.row_entity[row] = entity;
        self.row_level[row] = placement.level;
        self.row_min_x[row] = aabb.min_x;
        self.row_min_y[row] = aabb.min_y;
        self.row_max_x[row] = aabb.max_x;
        self.row_max_y[row] = aabb.max_y;
        self.row_cell_min_x[row] = placement.cells.min_x;
        self.row_cell_min_y[row] = placement.cells.min_y;
        self.row_cell_max_x[row] = placement.cells.max_x;
        self.row_cell_max_y[row] = placement.cells.max_y;
    }

    // Stages `row` into every chunk of `rect` outside `listed` (the chunks it already sits
    // in on the same level, or null). O(1) per chunk of `rect`.
    fn stageRowChunks(self: *StaticColliderSystem, row: u32, order: u32, rect: ChunkRect, listed: ?ChunkRect) void {
        const skip = if (listed) |old| (if (old.level == rect.level) old else null) else null;
        var chunk_y = rect.min_y;
        while (chunk_y <= rect.max_y) : (chunk_y += 1) {
            var chunk_x = rect.min_x;
            while (chunk_x <= rect.max_x) : (chunk_x += 1) {
                if (skip) |old| if (old.holds(chunk_x, chunk_y)) continue;
                self.chunk_lists.stageInsert(row, chunkKey(rect.level, chunk_y * rect.chunks_x + chunk_x), order);
            }
        }
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const StructuralCommand = @import("../data_system.zig").StructuralCommand;
const EntityTemplate = @import("../data_system.zig").EntityTemplate;

// 64 x 64 cells of 32 units in 4-cell chunks: a 16 x 16 chunk grid.
const test_geometry = ColliderGeometry{ .cell_size = 32, .width = 64, .height = 64, .chunk_tiles = 4 };

// The placement of entity `index`'s row, or null when it has none.
fn placementOfIndex(colliders: *const StaticColliderSystem, index: u32) ?Placement {
    if (index >= colliders.row_of_index.items.len) return null;
    const row = colliders.row_of_index.items[index];
    if (row == no_row) return null;
    return colliders.rowPlacement(row);
}

// Entries held in the chunk lists.
fn listEntryCount(colliders: *const StaticColliderSystem) usize {
    return colliders.chunk_lists.entries.len - colliders.chunk_lists.entry_free.items.len;
}

fn staticTemplate(position: math.Vec2, size: math.Vec2) EntityTemplate {
    return .{
        .movement_body = .{ .position = position, .previous_position = position },
        .collision_bounds = .{ .size = size },
        .collision_response = .{ .mobility = .static },
    };
}

// The commit seam in order: reserve, commit `commands`, capture, sync.
fn commitForTest(frame: *SimulationFrame, data: *DataSystem, colliders: *StaticColliderSystem, commands: []const StructuralCommand) !void {
    return commitForTestWith(frame, data, colliders, commands, null);
}

// `commitForTest` with the sync's splice stage under `thread_system`.
fn commitForTestWith(frame: *SimulationFrame, data: *DataSystem, colliders: *StaticColliderSystem, commands: []const StructuralCommand, thread_system: ?*ThreadSystem) !void {
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
    colliders.capture(frame);
    try colliders.sync(data, thread_system);
}

// Whether `a` and `b` hold identical rows, change lists, and list entries (entry ids
// included) over `levels` levels.
fn expectIdenticalLayout(a: *const StaticColliderSystem, b: *const StaticColliderSystem, levels: u16) !void {
    try std.testing.expectEqualSlices(u32, a.row_of_index.items, b.row_of_index.items);
    try std.testing.expectEqual(a.changes.items.len, b.changes.items.len);
    for (a.changes.items, b.changes.items) |change_a, change_b| try std.testing.expectEqual(change_a, change_b);
    const chunk_count = test_geometry.chunksX() * test_geometry.chunksX();
    for (0..levels) |level| for (0..chunk_count) |chunk| {
        const key = chunkKey(@intCast(level), @intCast(chunk));
        var entry_a = a.chunk_lists.head(key);
        var entry_b = b.chunk_lists.head(key);
        while (entry_a != no_entry or entry_b != no_entry) {
            try std.testing.expectEqual(entry_a, entry_b);
            try std.testing.expectEqual(a.chunk_lists.entry_owner[entry_a], b.chunk_lists.entry_owner[entry_b]);
            entry_a = a.chunk_lists.entry_next[entry_a];
            entry_b = b.chunk_lists.entry_next[entry_b];
        }
    };
}

// Rows listed at (level, chunk), as entity indices in list order.
fn listedIndices(colliders: *const StaticColliderSystem, level: u16, chunk: u32, out: *std.ArrayList(u32)) !void {
    out.clearRetainingCapacity();
    var rows = colliders.view().chunkRows(level, chunk);
    while (rows.next()) |row| try out.append(std.testing.allocator, colliders.row_entity[row].index);
}

// Whether `a` and `b` hold the same rows and the same lists over `levels` levels.
fn expectSameRows(a: *const StaticColliderSystem, b: *const StaticColliderSystem, levels: u16) !void {
    try std.testing.expectEqual(a.rowCount(), b.rowCount());
    const index_count = @max(a.row_of_index.items.len, b.row_of_index.items.len);
    for (0..index_count) |index| {
        try std.testing.expectEqual(placementOfIndex(a, @intCast(index)), placementOfIndex(b, @intCast(index)));
    }
    var listed_a: std.ArrayList(u32) = .empty;
    defer listed_a.deinit(std.testing.allocator);
    var listed_b: std.ArrayList(u32) = .empty;
    defer listed_b.deinit(std.testing.allocator);
    const chunk_count = test_geometry.chunksX() * test_geometry.chunksX();
    for (0..levels) |level| for (0..chunk_count) |chunk| {
        try listedIndices(a, @intCast(level), @intCast(chunk), &listed_a);
        try listedIndices(b, @intCast(level), @intCast(chunk), &listed_b);
        try std.testing.expectEqualSlices(u32, listed_b.items, listed_a.items);
    };
    try std.testing.expectEqual(listEntryCount(a), listEntryCount(b));
}

const SeamFixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    colliders: StaticColliderSystem,

    fn init() !SeamFixture {
        var fixture = SeamFixture{
            .data = DataSystem.init(std.testing.allocator),
            .frame = SimulationFrame.init(std.testing.allocator),
            .colliders = StaticColliderSystem.init(std.testing.allocator),
        };
        errdefer fixture.deinit();
        try fixture.colliders.rebuild(&fixture.data, test_geometry);
        return fixture;
    }

    fn deinit(self: *SeamFixture) void {
        self.colliders.deinit();
        self.frame.deinit();
        self.data.deinit();
    }

    fn rebuilt(self: *const SeamFixture) !StaticColliderSystem {
        var colliders = StaticColliderSystem.init(std.testing.allocator);
        errdefer colliders.deinit();
        try colliders.rebuild(&self.data, test_geometry);
        return colliders;
    }
};

test "creating a static from a template indexes it once" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // A 1.5-cell box at a chunk corner covers four chunks.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 112, .y = 112 }, .{ .x = 48, .y = 48 }) }});
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.rowCount());
    try std.testing.expectEqual(@as(usize, 4), listEntryCount(&fixture.colliders));
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.changesThisStep().len);
    const change = fixture.colliders.changesThisStep()[0];
    try std.testing.expect(change.old == null);
    try std.testing.expectEqual(CellSpan{ .min_x = 3, .min_y = 3, .max_x = 4, .max_y = 4 }, change.new.?.cells);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "destroying a template-created static frees every footprint entry" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 100, .y = 100 }, .{ .x = 200, .y = 40 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    try std.testing.expect(listEntryCount(&fixture.colliders) > 1);
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .destroy_entity = entity }});
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.rowCount());
    try std.testing.expectEqual(@as(usize, 0), listEntryCount(&fixture.colliders));
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.chunk_lists.live_keys);
    const change = fixture.colliders.changesThisStep()[0];
    try std.testing.expect(change.old != null and change.new == null);
}

test "a static's level change moves its row to the new level" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .set_world_level = .{ .entity = entity, .level = 2 } }});
    try std.testing.expectEqual(@as(u16, 2), placementOfIndex(&fixture.colliders, entity.index).?.level);
    try std.testing.expect(!fixture.colliders.view().chunkHasRows(0, 0));
    try std.testing.expect(fixture.colliders.view().chunkHasRows(2, 0));
    const change = fixture.colliders.changesThisStep()[0];
    try std.testing.expectEqual(@as(u16, 0), change.old.?.level);
    try std.testing.expectEqual(@as(u16, 2), change.new.?.level);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 3);
}

test "a destroy and a create reusing the index in one commit keep only the new row" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    const old = fixture.colliders.changesThisStep()[0].entity;
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{
        .{ .destroy_entity = old },
        .{ .create_entity = staticTemplate(.{ .x = 1000, .y = 1000 }, .{ .x = 8, .y = 8 }) },
    });
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.rowCount());
    const change = fixture.colliders.changesThisStep()[0];
    // The slot was reused: one change for the index, from the old row to the new one.
    try std.testing.expectEqual(@as(usize, 1), fixture.colliders.changesThisStep().len);
    try std.testing.expectEqual(old.index, change.entity.index);
    try std.testing.expect(!change.entity.eql(old));
    try std.testing.expectEqual(@as(u32, 1), change.old.?.cells.min_x);
    try std.testing.expectEqual(@as(u32, 31), change.new.?.cells.min_x);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "chunk lists stay in entity order under any add/remove order" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var prng = std.Random.DefaultPrng.init(0x5c5);
    const random = prng.random();
    var live: std.ArrayList(EntityId) = .empty;
    defer live.deinit(std.testing.allocator);
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..12) |_| {
        commands.clearRetainingCapacity();
        // Destroys, moves, mobility flips, and creates, all crowding a few chunks.
        for (live.items) |entity| {
            const position = math.Vec2{ .x = random.float(f32) * 300, .y = random.float(f32) * 300 };
            switch (random.uintLessThan(u8, 4)) {
                0 => try commands.append(std.testing.allocator, .{ .destroy_entity = entity }),
                1 => try commands.append(std.testing.allocator, .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } }),
                2 => try commands.append(std.testing.allocator, .{ .set_collision_response = .{ .entity = entity, .response = .{ .mobility = if (random.boolean()) .static else .dynamic } } }),
                else => {},
            }
        }
        for (0..random.uintLessThan(usize, 6)) |_| {
            const position = math.Vec2{ .x = random.float(f32) * 300, .y = random.float(f32) * 300 };
            try commands.append(std.testing.allocator, .{ .create_entity = staticTemplate(position, .{ .x = 10 + random.float(f32) * 60, .y = 10 + random.float(f32) * 60 }) });
        }
        try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
        live.clearRetainingCapacity();
        for (fixture.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
        // Every list is ascending in entity index and equals a rebuild's.
        var rebuilt = try fixture.rebuilt();
        defer rebuilt.deinit();
        try expectSameRows(&fixture.colliders, &rebuilt, 1);
        var listed: std.ArrayList(u32) = .empty;
        defer listed.deinit(std.testing.allocator);
        for (0..test_geometry.chunksX() * test_geometry.chunksX()) |chunk| {
            try listedIndices(&fixture.colliders, 0, @intCast(chunk), &listed);
            for (0..listed.items.len -| 1) |at| try std.testing.expect(listed.items[at] < listed.items[at + 1]);
        }
    }
}

test "sync runs out of memory at every allocation and leaves the structure unchanged; the retry applies it, serial and threaded" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    for ([_]?*ThreadSystem{ null, &threads }) |thread_system| try expectSyncOutOfMemorySafe(thread_system);
}

fn expectSyncOutOfMemorySafe(thread_system: ?*ThreadSystem) !void {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var fixture = try SeamFixture.init();
        defer fixture.deinit();
        fixture.colliders.splice_adaptive = false;
        fixture.colliders.splice_items_per_range = 8;
        try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
        const moved = fixture.colliders.changesThisStep()[0].entity;
        var before = try fixture.rebuilt();
        defer before.deinit();

        // One commit growing the rows and lists past their reserve: a move plus new statics.
        var commands: [9]StructuralCommand = undefined;
        commands[0] = .{ .set_movement_body = .{ .entity = moved, .body = .{ .position = .{ .x = 900, .y = 900 }, .previous_position = .{ .x = 900, .y = 900 } } } };
        for (commands[1..], 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 150), .y = 500 }, .{ .x = 140, .y = 140 }) };
        fixture.frame.beginStep();
        try fixture.colliders.reserveForCommit(&fixture.data, commands.len);
        try fixture.frame.structural_commands.prepareRangeCounts(1);
        fixture.frame.structural_commands.addCount(0, commands.len);
        try fixture.frame.structural_commands.prefix();
        var writer = fixture.frame.structural_commands.rangeWriter(0);
        for (commands) |command| writer.write(command);
        writer.finish();
        fixture.frame.structural_commands.finishWrite();
        _ = try fixture.frame.applyStructuralCommands(&fixture.data);
        fixture.colliders.capture(&fixture.frame);

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = fail_index });
        fixture.colliders.allocator = failing.allocator();
        fixture.colliders.chunk_lists.allocator = failing.allocator();
        const result = fixture.colliders.sync(&fixture.data, thread_system);
        fixture.colliders.allocator = std.testing.allocator;
        fixture.colliders.chunk_lists.allocator = std.testing.allocator;
        if (result) |_| {
            try std.testing.expect(!failing.has_induced_failure);
            if (thread_system != null) try std.testing.expect(!fixture.colliders.last_splice_batch.ran_inline);
            break;
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try expectSameRows(&fixture.colliders, &before, 1);
            try std.testing.expectEqual(@as(usize, 0), fixture.colliders.changesThisStep().len);
            // The next step's sync, with nothing new captured, applies the kept change.
            try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &.{}, thread_system);
            try std.testing.expectEqual(commands.len, fixture.colliders.changesThisStep().len);
            var after = try fixture.rebuilt();
            defer after.deinit();
            try expectSameRows(&fixture.colliders, &after, 1);
        }
    }
}

test "sync after reserve allocates nothing (FailingAllocator)" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var templates: [16]StructuralCommand = undefined;
    for (&templates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 100), .y = 300 }, .{ .x = 90, .y = 90 }) };
    // Warm: create, then destroy, so rows, lists, and the change list hold their high-water.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &templates);
    var destroys: [16]StructuralCommand = undefined;
    for (fixture.colliders.changesThisStep(), &destroys) |change, *command| command.* = .{ .destroy_entity = change.entity };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &destroys);

    // The seam's reserve runs with the real allocator before the commit, as the pipeline
    // does; the commit reuses the freed slots, and capture and sync allocate nothing.
    fixture.frame.beginStep();
    try fixture.colliders.reserveForCommit(&fixture.data, templates.len);
    try fixture.frame.structural_commands.prepareRangeCounts(1);
    fixture.frame.structural_commands.addCount(0, templates.len);
    try fixture.frame.structural_commands.prefix();
    var writer = fixture.frame.structural_commands.rangeWriter(0);
    for (templates) |command| writer.write(command);
    writer.finish();
    fixture.frame.structural_commands.finishWrite();
    _ = try fixture.frame.applyStructuralCommands(&fixture.data);
    fixture.colliders.allocator = std.testing.failing_allocator;
    fixture.colliders.chunk_lists.allocator = std.testing.failing_allocator;
    defer {
        fixture.colliders.allocator = std.testing.allocator;
        fixture.colliders.chunk_lists.allocator = std.testing.allocator;
    }
    fixture.colliders.capture(&fixture.frame);
    try fixture.colliders.sync(&fixture.data, null);
    try std.testing.expectEqual(@as(usize, 16), fixture.colliders.rowCount());
}

test "a step with no entity changes captures nothing" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    // A dynamic body's create and move touch no static.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = .{ .movement_body = .{ .position = .{ .x = 5, .y = 5 } } } }});
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.changesThisStep().len);
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.pending_dirty.items.len);
}

// Random statics crowding the first 300 x 300 units (a few chunks each way), sizes up to
// several chunks.
fn randomStatic(random: std.Random) StructuralCommand {
    const position = math.Vec2{ .x = random.float(f32) * 300, .y = random.float(f32) * 300 };
    return .{ .create_entity = staticTemplate(position, .{ .x = 6 + random.float(f32) * 150, .y = 6 + random.float(f32) * 150 }) };
}

// One dense mixed commit over `live`: destroys, moves inside the static's chunks and across
// chunks, level changes, mobility flips, then creates that reuse the freed indices.
fn denseMixedCommands(random: std.Random, data: *const DataSystem, live: []const EntityId, commands: *std.ArrayList(StructuralCommand)) !void {
    commands.clearRetainingCapacity();
    for (live) |entity| {
        const body = data.movementBodyConst(entity).?;
        switch (random.uintLessThan(u8, 7)) {
            0 => try commands.append(std.testing.allocator, .{ .destroy_entity = entity }),
            1 => {
                // One unit over: the chunk rect almost always holds.
                const position = math.Vec2{ .x = body.position.x + 1, .y = body.position.y };
                try commands.append(std.testing.allocator, .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } });
            },
            2 => {
                const position = math.Vec2{ .x = random.float(f32) * 300, .y = random.float(f32) * 300 };
                try commands.append(std.testing.allocator, .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } });
            },
            3 => try commands.append(std.testing.allocator, .{ .set_world_level = .{ .entity = entity, .level = random.uintLessThan(u16, 3) } }),
            4 => try commands.append(std.testing.allocator, .{ .set_collision_response = .{ .entity = entity, .response = .{ .mobility = if (random.boolean()) .static else .dynamic } } }),
            else => {},
        }
    }
    for (0..random.uintLessThan(usize, 24)) |_| try commands.append(std.testing.allocator, randomStatic(random));
}

test "a dense mixed collider sync lists every chunk in entity order, threaded equal to serial and to a rebuild" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var serial = try SeamFixture.init();
    defer serial.deinit();
    var threaded = try SeamFixture.init();
    defer threaded.deinit();
    threaded.colliders.splice_adaptive = false;
    threaded.colliders.splice_items_per_range = 8;
    var prng = std.Random.DefaultPrng.init(0xd5e5);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..120) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTest(&serial.frame, &serial.data, &serial.colliders, commands.items);
    try commitForTestWith(&threaded.frame, &threaded.data, &threaded.colliders, commands.items, &threads);
    var live: std.ArrayList(EntityId) = .empty;
    defer live.deinit(std.testing.allocator);
    var threaded_ranges: usize = 0;
    for (0..10) |_| {
        live.clearRetainingCapacity();
        for (serial.data.movementBodySliceConst().entities) |entity| try live.append(std.testing.allocator, entity);
        try denseMixedCommands(random, &serial.data, live.items, &commands);
        try commitForTest(&serial.frame, &serial.data, &serial.colliders, commands.items);
        try commitForTestWith(&threaded.frame, &threaded.data, &threaded.colliders, commands.items, &threads);
        try expectIdenticalLayout(&serial.colliders, &threaded.colliders, 3);
        var rebuilt = try serial.rebuilt();
        defer rebuilt.deinit();
        try expectSameRows(&serial.colliders, &rebuilt, 3);
        const batch = threaded.colliders.last_splice_batch;
        if (!batch.ran_inline and batch.range_count > 1) threaded_ranges += 1;
    }
    try std.testing.expect(threaded_ranges != 0);
}

test "a rebuild adds its growths to the row and chunk-list growth counters and keeps their logged flags" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var prng = std.Random.DefaultPrng.init(0x9e0);
    const random = prng.random();
    var commands: std.ArrayList(StructuralCommand) = .empty;
    defer commands.deinit(std.testing.allocator);
    for (0..60) |_| try commands.append(std.testing.allocator, randomStatic(random));
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, commands.items);
    const row_grows = fixture.colliders.row_grows;
    const list_grows = fixture.colliders.chunk_lists.grows;
    try std.testing.expect(row_grows != 0 and list_grows != 0);
    try std.testing.expect(fixture.colliders.row_growth_logged and fixture.colliders.chunk_lists.growth_logged);

    // A rebuild of the same statics grows as a fresh one does, on top of the earlier count.
    var reference = try fixture.rebuilt();
    defer reference.deinit();
    try fixture.colliders.rebuild(&fixture.data, test_geometry);
    try std.testing.expectEqual(row_grows + reference.row_grows, fixture.colliders.row_grows);
    try std.testing.expectEqual(list_grows + reference.chunk_lists.grows, fixture.colliders.chunk_lists.grows);

    // A rebuild over no statics keeps the counts and the logged flags.
    var empty = DataSystem.init(std.testing.allocator);
    defer empty.deinit();
    var empty_reference = StaticColliderSystem.init(std.testing.allocator);
    defer empty_reference.deinit();
    try empty_reference.rebuild(&empty, test_geometry);
    const total_rows = fixture.colliders.row_grows;
    const total_lists = fixture.colliders.chunk_lists.grows;
    try fixture.colliders.rebuild(&empty, test_geometry);
    try std.testing.expectEqual(total_rows + empty_reference.row_grows, fixture.colliders.row_grows);
    try std.testing.expectEqual(total_lists + empty_reference.chunk_lists.grows, fixture.colliders.chunk_lists.grows);
    try std.testing.expect(fixture.colliders.row_growth_logged and fixture.colliders.chunk_lists.growth_logged);
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.rowCount());
}

test "a move inside its footprint chunks touches no list" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    // A 3-chunk-wide static, then a move that keeps its chunk rect.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 140, .y = 140 }, .{ .x = 300, .y = 20 }) }});
    const entity = fixture.colliders.changesThisStep()[0].entity;
    var heads_before: [16 * 16]u32 = undefined;
    for (&heads_before, 0..) |*head, chunk| head.* = fixture.colliders.chunk_lists.head(chunkKey(0, @intCast(chunk)));
    const live_before = listEntryCount(&fixture.colliders);
    const position = math.Vec2{ .x = 150, .y = 150 };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } }});
    const change = fixture.colliders.changesThisStep()[0];
    try std.testing.expect(!std.meta.eql(change.old.?.cells, change.new.?.cells));
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.last_splice_batch.item_count);
    try std.testing.expectEqual(live_before, listEntryCount(&fixture.colliders));
    for (heads_before, 0..) |head, chunk| try std.testing.expectEqual(head, fixture.colliders.chunk_lists.head(chunkKey(0, @intCast(chunk))));
    try std.testing.expectEqual(change.new.?, placementOfIndex(&fixture.colliders, entity.index).?);
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "a destroy-heavy sync grows no rows" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    var creates: [32]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt(at * 60), .y = 100 }, .{ .x = 8, .y = 8 }) };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &creates);
    const pooled = fixture.colliders.rows.len;
    const grows = fixture.colliders.row_grows;
    var destroys: [32]StructuralCommand = undefined;
    for (fixture.colliders.changesThisStep(), &destroys) |change, *command| command.* = .{ .destroy_entity = change.entity };
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &destroys);
    try std.testing.expectEqual(@as(usize, 0), fixture.colliders.rowCount());
    try std.testing.expectEqual(pooled, fixture.colliders.rows.len);
    try std.testing.expectEqual(grows, fixture.colliders.row_grows);
}

test "a threaded sync after its reserves allocates nothing on a multi-worker ThreadSystem (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    fixture.colliders.splice_adaptive = false;
    fixture.colliders.splice_items_per_range = 8;
    // 48 one-cell statics over 48 chunks, each then moved one chunk over and back.
    var creates: [48]StructuralCommand = undefined;
    for (&creates, 0..) |*command, at| command.* = .{ .create_entity = staticTemplate(.{ .x = @floatFromInt((at % 12) * 128 + 4), .y = @floatFromInt((at / 12) * 128 + 4) }, .{ .x = 8, .y = 8 }) };
    try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &creates, &threads);
    var statics: [48]EntityId = undefined;
    for (fixture.colliders.changesThisStep(), &statics) |change, *entity| entity.* = change.entity;
    var moves: [48]StructuralCommand = undefined;
    for (0..3) |round| {
        for (statics, &moves, 0..) |entity, *command, at| {
            const offset: f32 = if (round % 2 == 0) 128 else 0;
            const position = math.Vec2{ .x = @as(f32, @floatFromInt((at % 12) * 128 + 4)) + offset, .y = @floatFromInt((at / 12) * 128 + 4) };
            command.* = .{ .set_movement_body = .{ .entity = entity, .body = .{ .position = position, .previous_position = position } } };
        }
        if (round < 2) {
            try commitForTestWith(&fixture.frame, &fixture.data, &fixture.colliders, &moves, &threads);
            continue;
        }
        // The seam's reserve runs with the real allocator; capture and sync allocate nothing.
        fixture.frame.beginStep();
        try fixture.colliders.reserveForCommit(&fixture.data, moves.len);
        try fixture.frame.structural_commands.prepareRangeCounts(1);
        fixture.frame.structural_commands.addCount(0, moves.len);
        try fixture.frame.structural_commands.prefix();
        var writer = fixture.frame.structural_commands.rangeWriter(0);
        for (moves) |command| writer.write(command);
        writer.finish();
        fixture.frame.structural_commands.finishWrite();
        _ = try fixture.frame.applyStructuralCommands(&fixture.data);
        fixture.colliders.allocator = std.testing.failing_allocator;
        fixture.colliders.chunk_lists.allocator = std.testing.failing_allocator;
        defer {
            fixture.colliders.allocator = std.testing.allocator;
            fixture.colliders.chunk_lists.allocator = std.testing.allocator;
        }
        fixture.colliders.capture(&fixture.frame);
        try fixture.colliders.sync(&fixture.data, &threads);
        try std.testing.expect(!fixture.colliders.last_splice_batch.ran_inline and fixture.colliders.last_splice_batch.range_count > 1);
    }
    try std.testing.expectEqual(@as(usize, 48), fixture.colliders.rowCount());
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}

test "a row pool grow that fails after the pool moved keeps the column views on the live pool" {
    var fixture = try SeamFixture.init();
    defer fixture.deinit();
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 40, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    // Growing past the pool moves it (allocation 0); growing the free list (allocation 1,
    // after a refused in-place resize) fails.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1, .resize_fail_index = 0 });
    fixture.colliders.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, fixture.colliders.ensureFreeRows(fixture.colliders.rows.capacity + 1));
    fixture.colliders.allocator = std.testing.allocator;
    const columns = fixture.colliders.rows.slice();
    try std.testing.expectEqual(columns.items(.level).ptr, fixture.colliders.row_level.ptr);
    try std.testing.expectEqual(columns.items(.entity).ptr, fixture.colliders.row_entity.ptr);
    try std.testing.expectEqual(columns.items(.cell_max_y).ptr, fixture.colliders.row_cell_max_y.ptr);
    // The retry adds rows beside the kept one.
    try commitForTest(&fixture.frame, &fixture.data, &fixture.colliders, &.{.{ .create_entity = staticTemplate(.{ .x = 400, .y = 40 }, .{ .x = 8, .y = 8 }) }});
    try std.testing.expectEqual(@as(usize, 2), fixture.colliders.rowCount());
    var rebuilt = try fixture.rebuilt();
    defer rebuilt.deinit();
    try expectSameRows(&fixture.colliders, &rebuilt, 1);
}
