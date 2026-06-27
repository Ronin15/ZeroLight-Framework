// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-level chunk-portal abstract navigation graph plus inter-level link edges.
//! Owns one NavGrid per level, a geometric chunk-stable slot layout, and the
//! incremental dirty-chunk patch path used by in-place digs.

const std = @import("std");
const math = @import("../../../core/math.zig");
const logging = @import("../../../core/logging.zig");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const PathAgentClass = @import("../../simulation.zig").PathAgentClass;
const NavGrid = @import("nav_grid.zig").NavGrid;
const NavMemoryBudget = @import("nav_memory.zig").NavMemoryBudget;
const types = @import("types.zig");
const default_cell_size = types.default_cell_size;
const default_nav_chunk_tiles = types.default_nav_chunk_tiles;
const default_edge_slack = types.default_edge_slack;
const chunk_edge_floor = types.chunk_edge_floor;
const no_cell = types.no_cell;
const no_component = types.no_component;
const cardinal_cost = types.cardinal_cost;
const inter_level_penalty = types.inter_level_penalty;
const PathQueryKey = types.PathQueryKey;
const NavCellEdit = types.NavCellEdit;
const NavUpdateStats = types.NavUpdateStats;
const GridCell = types.GridCell;
const setLen = types.setLen;
const octileCells = types.octileCells;
const orderU32 = types.orderU32;

// An abstract-graph node: a portal cell on a specific level. Portals sit on the
// open border between two adjacent chunks. Abstract A* searches over these nodes
// plus inter-level link edges, never over raw cells, so its work scales with the
// chunk-border count, not the total cell count.
pub const PortalNode = struct {
    level: u16,
    cell_index: u32,
    // Chunk this portal belongs to (chunk_y * chunks_x + chunk_x within a level).
    chunk: u32,
};

// One directed intra-level abstract edge in CSR form: `target` is a LOCAL node index
// on the SAME level as the owning node, reached at `cost`. Cross-level transitions are
// NOT edges here — they live in NavGraph.link_edges so a level's CSR depends only on
// that level's own mask.
pub const AbstractEdge = struct {
    target: u32,
    cost: u32,
};

// A live cross-level (or same-level teleport) link, keyed by CELL on both ends so it
// survives either endpoint level's node renumbering: the search resolves a cell to a
// portal node through the partner level's cell_to_portal at query time. Emitted
// (O(links)) only for links whose BOTH endpoints are open in their level masks.
pub const LinkEdge = struct {
    from_level: u16,
    from_cell: u32,
    to_level: u16,
    to_cell: u32,
    cost: u32,
    bidirectional: bool,
};

// One level's chunk-portal abstract graph over GEOMETRIC, chunk-stable node slots. A
// portal cell's node id is a pure function of its position (chunk slot base plus a fixed
// perimeter/link slot), so it never moves for the life of the graph: a dig only toggles
// whether a slot is live (a tombstone otherwise). Every per-slot array indexes that
// stable slot space, and every per-chunk array is keyed by chunk, so one chunk can be
// patched in isolation without renumbering or touching any other chunk or level.
pub const NavLevelGraph = struct {
    // Sized to NavGraph.total_slots. A tombstone slot has cell_index == no_cell.
    portals: std.ArrayList(PortalNode) = .empty,
    // cell_index -> node slot (no_cell when the cell is not a portal). Sized to cell_count.
    cell_to_portal: std.ArrayList(u32) = .empty,
    // Edge arena sized to NavGraph.total_edge_slots. Chunk D's edges live in the window
    // [chunk_edge_base[D], chunk_edge_base[D] + chunk_edge_cap[D]); a slot's adjacency is
    // [portal_edge_start[slot], +portal_edge_count[slot]) inside its chunk's window.
    portal_edges: std.ArrayList(AbstractEdge) = .empty,
    // Per slot: absolute start of its adjacency in portal_edges, and edge count (0 for a
    // tombstone). Sized to total_slots. Reads never depend on a neighbor slot, which is
    // what lets per-chunk edge windows work without global contiguity.
    portal_edge_start: std.ArrayList(u32) = .empty,
    portal_edge_count: std.ArrayList(u32) = .empty,
    // Per-chunk live-portal ordering: chunk D's run lives in
    // [chunk_portal_base[D], +chunk_portal_cap[D]); its first chunk_order_len[D] entries
    // are the chunk's live slots sorted by (chunk-local label, cell). Sized to total_slots.
    portal_order: std.ArrayList(u32) = .empty,
    chunk_order_len: std.ArrayList(u32) = .empty,
    // Per-chunk compact label sub-index, paired with portal_order. chunk_label_keys holds
    // the chunk's distinct labels (sorted) in its window; chunk_label_starts holds the
    // matching absolute offset into portal_order; chunk_label_len[D] is the run length.
    chunk_label_keys: std.ArrayList(u32) = .empty,
    chunk_label_starts: std.ArrayList(u32) = .empty,
    chunk_label_len: std.ArrayList(u32) = .empty,
    // Per-chunk edge scratch, filled by discover/intra and drained into the chunk's edge
    // window. Holds one chunk's edges during a patch (or one whole level during init).
    edge_scratch: std.ArrayList(EdgeScratch) = .empty,

    const EdgeScratch = struct {
        from: u32,
        edge: AbstractEdge,
    };

    pub fn deinit(self: *NavLevelGraph, allocator: std.mem.Allocator) void {
        self.edge_scratch.deinit(allocator);
        self.chunk_label_len.deinit(allocator);
        self.chunk_label_starts.deinit(allocator);
        self.chunk_label_keys.deinit(allocator);
        self.chunk_order_len.deinit(allocator);
        self.portal_order.deinit(allocator);
        self.portal_edge_count.deinit(allocator);
        self.portal_edge_start.deinit(allocator);
        self.portal_edges.deinit(allocator);
        self.cell_to_portal.deinit(allocator);
        self.portals.deinit(allocator);
        self.* = undefined;
    }

    // Live portal nodes summed across the level's per-chunk order windows.
    pub fn liveCount(self: *const NavLevelGraph) usize {
        var count: usize = 0;
        for (self.chunk_order_len.items) |len| count += len;
        return count;
    }
};
// Per-level chunk-portal navigation graph plus inter-level link edges. Owns one
// NavGrid per level (Z-floor) sharing dimensions/cell_size/version. Built once at
// nav rebuild; queried read-only afterward.
pub const NavGraph = struct {
    allocator: std.mem.Allocator,
    cell_size: f32 = default_cell_size,
    width: usize = 0,
    height: usize = 0,
    chunk_tiles: u16 = default_nav_chunk_tiles,
    version: u32 = 1,
    levels: std.ArrayList(NavGrid) = .empty,

    // One per-level abstract graph, paired index-for-index with `levels`. A level's
    // portal/edge/label arrays are rebuilt independently, so an edit on one level never
    // touches another level's NavLevelGraph.
    level_graphs: std.ArrayList(NavLevelGraph) = .empty,
    // Global live cross-level link edges, rebuilt O(links) every build. Kept OUT of the
    // per-level CSR so a level's graph depends only on that level's mask; a link edge
    // references its partner by cell, resolved through the partner level's cell_to_portal
    // at search time.
    link_edges: std.ArrayList(LinkEdge) = .empty,
    // Persistent u32 scratch reused (non-overlapping) by the per-level abstract-graph
    // build helpers for the portal sort order and the CSR cursors. Persisting it (vs a
    // per-build allocator.alloc) keeps both the init build and the incremental
    // `applyNavUpdates` rebuild allocation-free once the graph has been built once.
    build_u32_scratch: std.ArrayList(u32) = .empty,

    // Geometric, chunk-stable slot layout, computed once per dimensions/chunk_tiles and
    // invariant across applyNavUpdates (chunk geometry is identical across levels, so this
    // lives on NavGraph, not per level). chunk_portal_cap[D] = 4*ct + interior link
    // endpoints in D; chunk_portal_base is its exclusive prefix-sum; total_slots their sum.
    chunk_portal_cap: std.ArrayList(u32) = .empty,
    chunk_portal_base: std.ArrayList(u32) = .empty,
    total_slots: u32 = 0,
    // Per-chunk edge windows: cap = max-across-levels init edge count * edge_slack (with a
    // floor); base its exclusive prefix-sum; total_edge_slots their sum. Recomputed only on
    // a full build or an edge-cap fallback.
    chunk_edge_cap: std.ArrayList(u32) = .empty,
    chunk_edge_base: std.ArrayList(u32) = .empty,
    total_edge_slots: u32 = 0,
    // Slack multiplier on measured per-chunk edge counts. Bumped on an edge-cap fallback so
    // a topology blow-up does not re-trigger the fallback every subsequent dig.
    edge_slack: u32 = default_edge_slack,
    // Union (across all levels) of interior link-endpoint cells, per chunk: chunk D's run is
    // [chunk_link_base[D], +chunk_link_count[D]), sorted, so an interior link endpoint maps
    // to a stable tail slot independent of which level owns it.
    chunk_link_cells: std.ArrayList(u32) = .empty,
    chunk_link_base: std.ArrayList(u32) = .empty,
    chunk_link_count: std.ArrayList(u32) = .empty,
    // Dirty-set scratch for incremental patching: the deduped chunk list to patch this
    // batch plus a per-chunk stamp (epoch-compared, never cleared) for O(1) membership.
    dirty_set: std.ArrayList(u32) = .empty,
    dirty_stamp: std.ArrayList(u32) = .empty,
    dirty_epoch: u32 = 0,

    pub fn deinit(self: *NavGraph) void {
        self.dirty_stamp.deinit(self.allocator);
        self.dirty_set.deinit(self.allocator);
        self.chunk_link_count.deinit(self.allocator);
        self.chunk_link_base.deinit(self.allocator);
        self.chunk_link_cells.deinit(self.allocator);
        self.chunk_edge_base.deinit(self.allocator);
        self.chunk_edge_cap.deinit(self.allocator);
        self.chunk_portal_base.deinit(self.allocator);
        self.chunk_portal_cap.deinit(self.allocator);
        self.build_u32_scratch.deinit(self.allocator);
        self.link_edges.deinit(self.allocator);
        for (self.level_graphs.items) |*level_graph| level_graph.deinit(self.allocator);
        self.level_graphs.deinit(self.allocator);
        for (self.levels.items) |*level_grid| level_grid.deinit(self.allocator);
        self.levels.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn levelCount(self: *const NavGraph) usize {
        return self.levels.items.len;
    }

    pub fn levelGraph(self: *const NavGraph, level: u16) ?*const NavLevelGraph {
        if (@as(usize, level) >= self.level_graphs.items.len) return null;
        return &self.level_graphs.items[level];
    }

    // Total LIVE portal nodes across all levels (diagnostic / test helper). The portal
    // arrays are geometrically sized (with tombstones), so this counts live slots, not the
    // array length.
    pub fn totalPortals(self: *const NavGraph) usize {
        var count: usize = 0;
        for (self.level_graphs.items) |*level_graph| count += level_graph.liveCount();
        return count;
    }

    // Live portal nodes on one level (diagnostic / test helper).
    pub fn levelLivePortalCount(self: *const NavGraph, level: u16) usize {
        const lg = self.levelGraph(level) orelse return 0;
        return lg.liveCount();
    }

    pub fn grid(self: *const NavGraph, level: u16) ?*const NavGrid {
        if (@as(usize, level) >= self.levels.items.len) return null;
        return &self.levels.items[level];
    }

    pub fn valid(self: *const NavGraph) bool {
        return self.levels.items.len != 0 and self.levels.items[0].valid();
    }

    pub fn cellCount(self: *const NavGraph) usize {
        return self.width * self.height;
    }

    // Rebuilds every level grid plus the abstract chunk-portal/link graph. The
    // only path that reads static obstacles; afterward queries touch immutable
    // arrays and scratch only.
    pub fn rebuild(
        self: *NavGraph,
        data: *const DataSystem,
        world: ?*const WorldSystem,
        bounds_width: f32,
        bounds_height: f32,
        cell_size: f32,
        chunk_tiles: u16,
        memory_budget: NavMemoryBudget,
    ) !void {
        // A 0/negative/non-finite cell_size or bound would make @intFromFloat see
        // inf/NaN (illegal behavior); degenerate config collapses to a 1x1 grid.
        const safe_cell_size = if (std.math.isFinite(cell_size) and cell_size > 0) cell_size else 1.0;
        const safe_w: f32 = if (std.math.isFinite(bounds_width) and bounds_width > 0) bounds_width else 0;
        const safe_h: f32 = if (std.math.isFinite(bounds_height) and bounds_height > 0) bounds_height else 0;
        self.cell_size = safe_cell_size;
        self.chunk_tiles = @max(@as(u16, 1), chunk_tiles);
        self.width = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(safe_w / safe_cell_size))));
        self.height = @max(@as(usize, 1), @as(usize, @intFromFloat(@ceil(safe_h / safe_cell_size))));

        // Fail loud at build instead of degrading at query time.
        try memory_budget.check(self.width, self.height);

        const level_count: u16 = if (world) |world_system|
            @intCast(@max(@as(usize, 1), world_system.levelCount()))
        else
            1;

        self.version +%= 1;
        if (self.version == 0) self.version = 1;

        try self.levels.ensureTotalCapacity(self.allocator, level_count);
        while (self.levels.items.len < level_count) self.levels.appendAssumeCapacity(.{});
        while (self.levels.items.len > level_count) {
            var removed = self.levels.pop().?;
            removed.deinit(self.allocator);
        }
        // Keep one NavLevelGraph per level, paired with `levels`.
        try self.level_graphs.ensureTotalCapacity(self.allocator, level_count);
        while (self.level_graphs.items.len < level_count) self.level_graphs.appendAssumeCapacity(.{});
        while (self.level_graphs.items.len > level_count) {
            var removed = self.level_graphs.pop().?;
            removed.deinit(self.allocator);
        }

        for (self.levels.items, 0..) |*level_grid, level_index| {
            const level: u16 = @intCast(level_index);
            try level_grid.prepare(self.allocator, level, self.width, self.height, safe_cell_size, self.chunk_tiles, self.version);
            // Only level 0 sources DataSystem collision bodies; the demo's
            // entities live on the ground floor. World mask drives every level.
            if (level == 0) level_grid.markStaticBodies(data);
            if (world) |world_system| level_grid.markWorldObstacles(world_system);
            level_grid.buildComponents();
        }

        self.edge_slack = default_edge_slack;
        try self.buildAbstractGraphs(world);
        try self.rebuildLinkEdges(world);
    }

    // (Re)builds the chunk-stable slot geometry and every level's full abstract graph from
    // the current masks/components. Used by the init rebuild and by the edge-cap fallback;
    // it re-measures per-chunk edge caps from the current topology, so it never overflows.
    pub fn buildAbstractGraphs(self: *NavGraph, world: ?*const WorldSystem) !void {
        try self.computePortalGeometry(world);
        // Pass 1: build portals/order/labels and fill each level's edge_scratch (retained
        // per level so pass 2 can drain it after the shared edge caps are known).
        for (0..self.levels.items.len) |level_index| {
            try self.buildLevelInit(@intCast(level_index), world);
        }
        // Size per-chunk edge windows from the measured per-chunk max count across levels.
        try self.computeEdgeCaps();
        // Pass 2: place each level's edge_scratch into its chunk windows.
        for (0..self.levels.items.len) |level_index| {
            try self.placeLevelEdges(@intCast(level_index));
        }
    }

    // Incrementally folds a batch of static-obstacle edits into the existing graph
    // WITHOUT a whole-world rebuild. Re-derives the blocked mask + chunk-local components
    // of only the dirty chunks, then patches ONLY the affected abstract chunks: each dirty
    // chunk plus its border-adjacent (orthogonal) neighbors. Because node slots are a pure
    // function of geometry, patching one chunk never renumbers another, so the work is
    // bounded by the edit's chunk footprint, not the level size — a single-chunk dig stops
    // scaling with the world. The global link_edges array is rebuilt once (O(links)); a
    // link's liveness toggle needs no per-chunk rebuild because liveness is enforced only
    // when emitting link_edges. Bumps `version` once so every goal-keyed cache/pending
    // entry keyed on the old version re-solves. `affected_levels` is caller-owned
    // pre-reserved scratch (sized to level count).
    //
    // Allocation contract: allocation-free at steady state — the abstract buffers are reused
    // at the prior build's high-water capacity, and the slot/order arrays are geometrically
    // sized so they never grow on a dig. The only growth is a genuine per-chunk edge-window
    // overflow (a real topology blow-up), which triggers a loud full rebuild with more
    // slack. That is acceptable per coding-standards.md allocation exceptions: a cold,
    // event-triggered main-thread path with NavGraph as the explicit owner, whose cost
    // cannot move to init because the new topology is only known when the edit arrives.
    pub fn applyNavUpdates(
        self: *NavGraph,
        data: *const DataSystem,
        world: ?*const WorldSystem,
        edits: []const NavCellEdit,
        affected_levels: *std.ArrayList(bool),
        full_relabel_level_threshold: usize,
    ) !NavUpdateStats {
        var stats = NavUpdateStats{};
        if (edits.len == 0 or !self.valid()) return stats;

        const level_count = self.levels.items.len;
        // Capacity is pre-reserved to the level count at rebuild, so this is a no-op
        // on the steady path; the ensure guards against a future level-count change
        // OOB-writing the affected-flag scratch.
        try setLen(affected_levels, self.allocator, level_count);
        @memset(affected_levels.items, false);

        var affected_level_count: usize = 0;
        for (edits) |edit| {
            if (@as(usize, edit.level) >= level_count) continue;
            if (!affected_levels.items[edit.level]) {
                affected_levels.items[edit.level] = true;
                affected_level_count += 1;
            }
        }
        if (affected_level_count == 0) return stats;
        // Purely diagnostic and O(edits^2); only pay for it when perf logging consumes it.
        if (runtime_perf_log.enabled) stats.dirty_chunks = self.countDirtyChunks(world, edits);

        // Re-derive the blocked mask of affected levels over the edit footprint only.
        // Past the threshold a level-count blowup degenerates to a full graph rebuild;
        // flag it loudly rather than silently doing whole-world component work.
        const full_relabel = affected_level_count > full_relabel_level_threshold;
        for (self.levels.items, 0..) |*level_grid, level_index| {
            if (!full_relabel and !affected_levels.items[level_index]) continue;
            level_grid.remarkStaticMaskCells(data, world, edits);
        }

        if (full_relabel) {
            for (self.levels.items) |*level_grid| level_grid.buildComponents();
            try self.buildAbstractGraphs(world);
            stats.full_relabel = 1;
        } else {
            // Chunk-local labels: only chunks whose cells changed need re-flooding (a tile
            // rect can straddle a chunk border, so dirty chunks come from the full
            // navSpanForTile rect). Neighbor chunks added below are NOT re-flooded — their
            // mask is untouched — only their abstract layer is patched.
            self.recomputeDirtyChunks(world, edits);
            var overflow = false;
            for (self.levels.items, 0..) |_, level_index| {
                if (!affected_levels.items[level_index]) continue;
                const level: u16 = @intCast(level_index);
                self.buildDirtySet(level, world, edits);
                stats.chunks_patched += self.dirty_set.items.len;
                for (self.dirty_set.items) |chunk| {
                    if (try self.patchChunk(level, world, chunk)) overflow = true;
                }
            }
            if (overflow) {
                // A chunk's edges blew past its fixed window: bump slack and rebuild the
                // whole abstract graph (re-measuring caps so they fit the new topology). Also
                // surfaced via the edge_cap_fallback counter (recorded as a perf metric by the
                // app-layer caller). The recovered-degradation warn is comptime-gated to the
                // hot-path logger so it compiles out in release and test builds.
                self.edge_slack = std.math.add(u32, self.edge_slack, self.edge_slack) catch self.edge_slack;
                if (runtime_perf_log.hot_log_enabled)
                    logging.game.warn("nav abstract-graph edge-cap fallback: per-chunk edge window overflow, full rebuild with slack {}", .{self.edge_slack});
                try self.buildAbstractGraphs(world);
                stats.edge_cap_fallback = 1;
            }
        }
        try self.rebuildLinkEdges(world);

        // Incremental patch keeps nav_version stable (caller scope-evicts only crossing
        // paths); a full relabel/edge-cap rebuild bumps it to invalidate all goal-keyed work.
        const full_rebuild = stats.full_relabel != 0 or stats.edge_cap_fallback != 0;
        if (full_rebuild) {
            self.version +%= 1;
            if (self.version == 0) self.version = 1;
            for (self.levels.items) |*level_grid| level_grid.version = self.version;
            stats.version_bumps = 1;
        }

        stats.incremental_rebuilds = 1;
        return stats;
    }

    // Builds this batch's dirty-chunk set for one level into self.dirty_set: every chunk a
    // dirty cell falls in, plus each of those chunks' orthogonal (border-sharing) internal
    // neighbors. Diagonal neighbors are excluded — they share only a corner, never a border
    // line, so no transition edge crosses them. Deduped via an epoch-stamped marker.
    pub fn buildDirtySet(self: *NavGraph, level: u16, world: ?*const WorldSystem, edits: []const NavCellEdit) void {
        self.dirty_set.clearRetainingCapacity();
        self.dirty_epoch +%= 1;
        const world_system = world orelse return;
        const level_grid = &self.levels.items[level];
        const ct: usize = self.chunk_tiles;
        const cx_count = self.chunksX();
        const cy_count = self.chunksY();
        for (edits) |edit| {
            if (edit.level != level) continue;
            const span = level_grid.navSpanForTile(world_system, edit) orelse continue;
            var cy = span.min_y / ct;
            const cy1 = span.max_y / ct;
            while (cy <= cy1) : (cy += 1) {
                var cx = span.min_x / ct;
                const cx1 = span.max_x / ct;
                while (cx <= cx1) : (cx += 1) {
                    self.addDirtyChunk(@intCast(cy * cx_count + cx));
                    if (cx > 0) self.addDirtyChunk(@intCast(cy * cx_count + cx - 1));
                    if (cx + 1 < cx_count) self.addDirtyChunk(@intCast(cy * cx_count + cx + 1));
                    if (cy > 0) self.addDirtyChunk(@intCast((cy - 1) * cx_count + cx));
                    if (cy + 1 < cy_count) self.addDirtyChunk(@intCast((cy + 1) * cx_count + cx));
                }
            }
        }
    }

    pub fn addDirtyChunk(self: *NavGraph, chunk: u32) void {
        if (self.dirty_stamp.items[chunk] == self.dirty_epoch) return;
        self.dirty_stamp.items[chunk] = self.dirty_epoch;
        self.dirty_set.appendAssumeCapacity(chunk);
    }

    // Counts distinct abstract chunks (per level) touched by the dirty edits, using
    // the nav cell at each edited tile's origin. Quadratic in the edit count, which
    // is bounded by the per-step world-event budget; purely diagnostic.
    pub fn countDirtyChunks(self: *const NavGraph, world: ?*const WorldSystem, edits: []const NavCellEdit) usize {
        const world_system = world orelse return 0;
        var count: usize = 0;
        for (edits, 0..) |edit, i| {
            const cell_index = self.navCellIndexForTile(world_system, edit) orelse continue;
            const chunk = self.chunkOf(cell_index);
            var seen = false;
            for (edits[0..i]) |prior| {
                if (prior.level != edit.level) continue;
                const prior_index = self.navCellIndexForTile(world_system, prior) orelse continue;
                if (self.chunkOf(prior_index) == chunk) {
                    seen = true;
                    break;
                }
            }
            if (!seen) count += 1;
        }
        return count;
    }

    // Re-floods the chunk-local components of every chunk whose cells were touched by
    // an edit's navSpanForTile rect. recomputeChunkComponents is idempotent, so an edit
    // straddling a chunk border (or two edits sharing a chunk) re-flooding the same
    // chunk twice is harmless. Bounded by the edit footprint, not the level cell count.
    pub fn recomputeDirtyChunks(self: *NavGraph, world: ?*const WorldSystem, edits: []const NavCellEdit) void {
        const world_system = world orelse return;
        const ct: usize = self.chunk_tiles;
        for (edits) |edit| {
            if (@as(usize, edit.level) >= self.levels.items.len) continue;
            const level_grid = &self.levels.items[edit.level];
            const span = level_grid.navSpanForTile(world_system, edit) orelse continue;
            const cx_count = level_grid.chunksX();
            const cx0 = span.min_x / ct;
            const cx1 = span.max_x / ct;
            const cy0 = span.min_y / ct;
            const cy1 = span.max_y / ct;
            var cy = cy0;
            while (cy <= cy1) : (cy += 1) {
                var cx = cx0;
                while (cx <= cx1) : (cx += 1) {
                    level_grid.recomputeChunkComponents(@intCast(cy * cx_count + cx));
                }
            }
        }
    }

    // Nav cell index of the nav cell containing a world tile's origin corner.
    pub fn navCellIndexForTile(self: *const NavGraph, world: *const WorldSystem, edit: NavCellEdit) ?usize {
        const level_grid = self.grid(edit.level) orelse return null;
        const rect = world.cellRect(edit.x, edit.y) orelse return null;
        const cell = level_grid.worldToCellClamped(.{ .x = rect.x, .y = rect.y });
        return level_grid.indexForCell(cell);
    }

    pub fn chunksX(self: *const NavGraph) usize {
        return (self.width + self.chunk_tiles - 1) / self.chunk_tiles;
    }

    pub fn chunksY(self: *const NavGraph) usize {
        return (self.height + self.chunk_tiles - 1) / self.chunk_tiles;
    }

    pub fn chunkOf(self: *const NavGraph, cell_index: usize) u32 {
        const x = cell_index % self.width;
        const y = cell_index / self.width;
        const cx = x / self.chunk_tiles;
        const cy = y / self.chunk_tiles;
        return @intCast(cy * self.chunksX() + cx);
    }

    pub fn chunkCount(self: *const NavGraph) usize {
        return self.chunksX() * self.chunksY();
    }

    // Chunk-local coordinate of a cell within its owning chunk.
    pub fn localOfCell(self: *const NavGraph, cell_index: usize) struct { x: usize, y: usize } {
        return .{ .x = (cell_index % self.width) % self.chunk_tiles, .y = (cell_index / self.width) % self.chunk_tiles };
    }

    pub fn isPerimeterCell(self: *const NavGraph, cell_index: usize) bool {
        const ct: usize = self.chunk_tiles;
        const lc = self.localOfCell(cell_index);
        return lc.x == 0 or lc.x == ct - 1 or lc.y == 0 or lc.y == ct - 1;
    }

    // Fixed bijection from a chunk's perimeter cells to [0, 4*ct): a canonical slot per
    // perimeter cell (corners resolved to a single edge), so a border cell's node id is a
    // pure function of its position and never moves for the life of the graph.
    pub fn perimeterSlot(self: *const NavGraph, cell_index: usize) u32 {
        const ct: usize = self.chunk_tiles;
        const lc = self.localOfCell(cell_index);
        const slot: usize = if (lc.y == 0)
            lc.x // top row: [0, ct)
        else if (lc.y == ct - 1)
            ct + lc.x // bottom row: [ct, 2ct)
        else if (lc.x == 0)
            2 * ct + (lc.y - 1) // left column interior: [2ct, 3ct-2)
        else
            (3 * ct - 2) + (lc.y - 1); // right column interior: [3ct-2, 4ct-4)
        return @intCast(slot);
    }

    // Geometric node slot for a portal cell: chunk slot base plus its fixed perimeter slot,
    // or (for a non-perimeter interior link endpoint) base + 4*ct + its stable tail index.
    pub fn slotForCell(self: *const NavGraph, cell_index: usize) u32 {
        const chunk = self.chunkOf(cell_index);
        const base = self.chunk_portal_base.items[chunk];
        if (self.isPerimeterCell(cell_index)) return base + self.perimeterSlot(cell_index);
        const ct: u32 = self.chunk_tiles;
        return base + 4 * ct + self.linkTailIndex(chunk, cell_index);
    }

    // Tail index of an interior link-endpoint cell within its chunk's link-cell run.
    pub fn linkTailIndex(self: *const NavGraph, chunk: u32, cell_index: usize) u32 {
        const lo = self.chunk_link_base.items[chunk];
        const len = self.chunk_link_count.items[chunk];
        const run = self.chunk_link_cells.items[lo .. lo + len];
        const rel = std.sort.binarySearch(u32, run, @as(u32, @intCast(cell_index)), orderU32) orelse return 0;
        return @intCast(rel);
    }

    // Computes the chunk-stable slot geometry (portal caps/base/total_slots and the per-chunk
    // interior link-endpoint runs) from the current dimensions and the world's link set. Pure
    // geometry, independent of obstacles, so it is invariant across digs.
    pub fn computePortalGeometry(self: *NavGraph, world: ?*const WorldSystem) !void {
        const cell_count = self.cellCount();
        std.debug.assert(cell_count < no_cell);
        const chunk_count = self.chunkCount();
        const ct: u32 = self.chunk_tiles;

        // Per-chunk union of interior link-endpoint cells across all levels (sorted/distinct),
        // so an interior link endpoint maps to a stable tail slot regardless of owning level.
        try setLen(&self.chunk_link_count, self.allocator, chunk_count);
        try setLen(&self.chunk_link_base, self.allocator, chunk_count);
        @memset(self.chunk_link_count.items, 0);
        self.chunk_link_cells.clearRetainingCapacity();
        if (world) |world_system| {
            for (world_system.levelLinks()) |link| {
                try self.recordLinkEndpoint(link.cell_a.x, link.cell_a.y);
                try self.recordLinkEndpoint(link.cell_b.x, link.cell_b.y);
            }
        }
        // Sort each chunk's link-cell run in place (counts already grouped them by chunk on
        // append? no — append is by discovery order); rebuild as grouped sorted runs.
        try self.groupLinkCellRuns(chunk_count);

        // Portal caps: 4*ct perimeter slots plus the chunk's interior link tail count.
        try setLen(&self.chunk_portal_cap, self.allocator, chunk_count);
        try setLen(&self.chunk_portal_base, self.allocator, chunk_count);
        var running: u32 = 0;
        for (0..chunk_count) |c| {
            self.chunk_portal_base.items[c] = running;
            const cap = 4 * ct + self.chunk_link_count.items[c];
            self.chunk_portal_cap.items[c] = cap;
            running += cap;
        }
        self.total_slots = running;

        // Size the dirty-set scratch (bounded by chunk count) and per-chunk stamps.
        try self.dirty_set.ensureTotalCapacity(self.allocator, chunk_count);
        try setLen(&self.dirty_stamp, self.allocator, chunk_count);
        @memset(self.dirty_stamp.items, 0);
        self.dirty_epoch = 0;

        // Size every level's slot-indexed arrays to total_slots and the cell map to cells.
        for (self.level_graphs.items) |*lg| {
            try setLen(&lg.cell_to_portal, self.allocator, cell_count);
            try setLen(&lg.portals, self.allocator, self.total_slots);
            try setLen(&lg.portal_edge_start, self.allocator, self.total_slots);
            try setLen(&lg.portal_edge_count, self.allocator, self.total_slots);
            try setLen(&lg.portal_order, self.allocator, self.total_slots);
            try setLen(&lg.chunk_label_keys, self.allocator, self.total_slots);
            try setLen(&lg.chunk_label_starts, self.allocator, self.total_slots);
            try setLen(&lg.chunk_order_len, self.allocator, chunk_count);
            try setLen(&lg.chunk_label_len, self.allocator, chunk_count);
        }
    }

    pub fn recordLinkEndpoint(self: *NavGraph, x: u16, y: u16) !void {
        const cell = self.levels.items[0].indexForCell(.{ .x = x, .y = y }) orelse return;
        if (self.isPerimeterCell(cell)) return; // perimeter endpoints reuse their perimeter slot
        const chunk = self.chunkOf(cell);
        // Skip duplicates already recorded for this chunk.
        for (self.chunk_link_cells.items) |existing| {
            if (existing == cell) return;
        }
        try self.chunk_link_cells.append(self.allocator, @intCast(cell));
        self.chunk_link_count.items[chunk] += 1;
    }

    // Reorders chunk_link_cells into per-chunk contiguous sorted runs and fills the per-chunk
    // base offsets, so linkTailIndex can binary-search a chunk's run.
    pub fn groupLinkCellRuns(self: *NavGraph, chunk_count: usize) !void {
        var running: u32 = 0;
        for (0..chunk_count) |c| {
            self.chunk_link_base.items[c] = running;
            running += self.chunk_link_count.items[c];
        }
        const total = running;
        if (total == 0) return;
        // Stable bucket the recorded cells into their chunk runs using a cursor copy.
        const cursor = try self.buildScratch(chunk_count);
        for (0..chunk_count) |c| cursor[c] = self.chunk_link_base.items[c];
        const sorted = try self.allocator.alloc(u32, total);
        defer self.allocator.free(sorted);
        for (self.chunk_link_cells.items) |cell| {
            const c = self.chunkOf(cell);
            sorted[cursor[c]] = cell;
            cursor[c] += 1;
        }
        // Sort each chunk run so binary search is valid.
        for (0..chunk_count) |c| {
            const lo = self.chunk_link_base.items[c];
            const len = self.chunk_link_count.items[c];
            std.sort.pdq(u32, sorted[lo .. lo + len], {}, std.sort.asc(u32));
        }
        try setLen(&self.chunk_link_cells, self.allocator, total);
        @memcpy(self.chunk_link_cells.items, sorted);
    }

    // Full per-level build into the geometric slot space: tombstone every slot, rebuild each
    // chunk's portals/order/labels, and accumulate the level's edges into edge_scratch (left
    // for placeLevelEdges after the shared edge caps are measured).
    pub fn buildLevelInit(self: *NavGraph, level: u16, world: ?*const WorldSystem) !void {
        const lg = &self.level_graphs.items[level];
        @memset(lg.cell_to_portal.items, no_cell);
        @memset(lg.portals.items, .{ .level = level, .cell_index = no_cell, .chunk = 0 });
        @memset(lg.portal_edge_count.items, 0);
        @memset(lg.chunk_order_len.items, 0);
        @memset(lg.chunk_label_len.items, 0);
        lg.edge_scratch.clearRetainingCapacity();
        const chunk_count = self.chunkCount();
        var chunk: u32 = 0;
        while (chunk < chunk_count) : (chunk += 1) {
            try self.discoverChunkPortals(level, chunk);
            if (world) |world_system| self.addChunkLinkPortals(level, chunk, world_system);
            try self.connectChunkIntraEdges(level, chunk);
            self.orderChunkPortals(level, chunk);
        }
    }

    // Rebuilds the global live cross-level link edges (O(links)). A link is live only
    // when BOTH endpoint cells are open in their level masks. A live link references its
    // endpoints by CELL, resolved to portal nodes through the partner level's
    // cell_to_portal at search time, so it never depends on either level's node numbering
    // and a liveness toggle forces no per-level graph rebuild.
    pub fn rebuildLinkEdges(self: *NavGraph, world: ?*const WorldSystem) !void {
        self.link_edges.clearRetainingCapacity();
        const world_system = world orelse return;
        for (world_system.levelLinks()) |link| {
            if (@as(usize, link.level_a) >= self.levels.items.len) continue;
            if (@as(usize, link.level_b) >= self.levels.items.len) continue;
            const grid_a = &self.levels.items[link.level_a];
            const grid_b = &self.levels.items[link.level_b];
            const cell_a = grid_a.indexForCell(.{ .x = link.cell_a.x, .y = link.cell_a.y }) orelse continue;
            const cell_b = grid_b.indexForCell(.{ .x = link.cell_b.x, .y = link.cell_b.y }) orelse continue;
            if (grid_a.blocked.items[cell_a] or grid_b.blocked.items[cell_b]) continue;
            try self.link_edges.append(self.allocator, .{
                .from_level = link.level_a,
                .from_cell = @intCast(cell_a),
                .to_level = link.level_b,
                .to_cell = @intCast(cell_b),
                .cost = link.traversal_cost +| inter_level_penalty,
                .bidirectional = link.bidirectional,
            });
        }
    }

    // Returns a persistent u32 scratch slice of `len`, growing the backing buffer only
    // when a build needs more than any prior build. The three abstract-graph build
    // helpers use this sequentially (never overlapping), so one buffer serves all.
    pub fn buildScratch(self: *NavGraph, len: usize) ![]u32 {
        try setLen(&self.build_u32_scratch, self.allocator, len);
        return self.build_u32_scratch.items;
    }

    // Per-chunk label stride matching NavGrid's chunk-local label encoding, so a chunk id
    // can be recovered from one of its encoded labels by integer division.
    pub fn labelStride(self: *const NavGraph) u32 {
        const ct: u32 = self.chunk_tiles;
        return ct * ct + 1;
    }

    // Returns the LIVE portal node slots on `level` owning chunk-local `component` (an
    // encoded label), a contiguous sub-run of the owning chunk's portal_order window, so
    // abstract seeding scans only the start chunk's local-component portals. The chunk is
    // recovered from the label; the chunk's small key run is binary-searched.
    pub fn levelComponentPortals(self: *const NavGraph, level: u16, component: u32) []const u32 {
        if (component == no_component) return &.{};
        const lg = self.levelGraph(level) orelse return &.{};
        const chunk = component / self.labelStride();
        if (chunk >= self.chunkCount()) return &.{};
        const pbase = self.chunk_portal_base.items[chunk];
        const klen = lg.chunk_label_len.items[chunk];
        const keys = lg.chunk_label_keys.items[pbase .. pbase + klen];
        const rel = std.sort.binarySearch(u32, keys, component, orderU32) orelse return &.{};
        const start = lg.chunk_label_starts.items[pbase + rel];
        const end = if (rel + 1 < klen)
            lg.chunk_label_starts.items[pbase + rel + 1]
        else
            pbase + lg.chunk_order_len.items[chunk];
        return lg.portal_order.items[start..end];
    }

    // Patches ONE chunk's abstract layer in isolation: clears its stable slot window, rebuilds
    // its border portals + cross-border transition edges, its open link-endpoint portals, its
    // intra-chunk edges, its ordering/label sub-index, and compacts its edges into its fixed
    // window. Touches no other chunk's slots, so the dirty-bounded incremental update never
    // renumbers or rebuilds an unaffected chunk. Returns true on an edge-window overflow.
    pub fn patchChunk(self: *NavGraph, level: u16, world: ?*const WorldSystem, chunk: u32) !bool {
        self.clearChunkSlots(level, chunk);
        self.level_graphs.items[level].edge_scratch.clearRetainingCapacity();
        try self.discoverChunkPortals(level, chunk);
        if (world) |world_system| self.addChunkLinkPortals(level, chunk, world_system);
        try self.connectChunkIntraEdges(level, chunk);
        self.orderChunkPortals(level, chunk);
        return try self.compactChunkEdges(level, chunk);
    }

    // Tombstones a chunk's whole slot window and clears the cell_to_portal entries of the
    // cells it owned, so a patch starts from a clean chunk independent of its prior content.
    pub fn clearChunkSlots(self: *NavGraph, level: u16, chunk: u32) void {
        const lg = &self.level_graphs.items[level];
        const pbase = self.chunk_portal_base.items[chunk];
        const pcap = self.chunk_portal_cap.items[chunk];
        var slot = pbase;
        while (slot < pbase + pcap) : (slot += 1) {
            const cell = lg.portals.items[slot].cell_index;
            if (cell != no_cell) lg.cell_to_portal.items[cell] = no_cell;
            // Canonical tombstone (chunk 0) matching buildLevelInit's memset, so the changed
            // level's portals stay byte-identical to a full rebuild after a patch.
            lg.portals.items[slot] = .{ .level = level, .cell_index = no_cell, .chunk = 0 };
            lg.portal_edge_count.items[slot] = 0;
        }
        lg.chunk_order_len.items[chunk] = 0;
        lg.chunk_label_len.items[chunk] = 0;
    }

    // Inclusive cell bounds of one chunk, clamped to the grid.
    pub fn chunkBounds(self: *const NavGraph, chunk: u32) struct { x0: usize, y0: usize, x1: usize, y1: usize } {
        const cx_count = self.chunksX();
        const ct: usize = self.chunk_tiles;
        const cx = chunk % cx_count;
        const cy = chunk / cx_count;
        return .{
            .x0 = cx * ct,
            .y0 = cy * ct,
            .x1 = @min(cx * ct + ct, self.width),
            .y1 = @min(cy * ct + ct, self.height),
        };
    }

    // Scans one chunk's up-to-four INTERNAL borders, adding each open border cell on the
    // chunk side as a portal and emitting the directed transition edge into its open
    // neighbor. The reverse edge lives in the neighbor chunk's window and is emitted when
    // that chunk is patched (both source and neighbor are always in the dirty set), so each
    // shared transition edge is emitted exactly once.
    pub fn discoverChunkPortals(self: *NavGraph, level: u16, chunk: u32) !void {
        const lg = &self.level_graphs.items[level];
        const blocked = self.levels.items[level].blocked.items;
        const w = self.width;
        const b = self.chunkBounds(chunk);
        if (b.x0 > 0) {
            var y = b.y0;
            while (y < b.y1) : (y += 1) try self.tryBorderPair(lg, level, blocked, y * w + b.x0, y * w + b.x0 - 1, chunk);
        }
        if (b.x1 < w) {
            var y = b.y0;
            while (y < b.y1) : (y += 1) try self.tryBorderPair(lg, level, blocked, y * w + b.x1 - 1, y * w + b.x1, chunk);
        }
        if (b.y0 > 0) {
            var x = b.x0;
            while (x < b.x1) : (x += 1) try self.tryBorderPair(lg, level, blocked, b.y0 * w + x, (b.y0 - 1) * w + x, chunk);
        }
        if (b.y1 < self.height) {
            var x = b.x0;
            while (x < b.x1) : (x += 1) try self.tryBorderPair(lg, level, blocked, (b.y1 - 1) * w + x, b.y1 * w + x, chunk);
        }
    }

    pub fn tryBorderPair(self: *NavGraph, lg: *NavLevelGraph, level: u16, blocked: []const bool, c_cell: usize, n_cell: usize, chunk: u32) !void {
        if (blocked[c_cell] or blocked[n_cell]) return;
        self.addPortalCell(lg, level, c_cell, chunk);
        try lg.edge_scratch.append(self.allocator, .{
            .from = self.slotForCell(c_cell),
            .edge = .{ .target = self.slotForCell(n_cell), .cost = cardinal_cost },
        });
    }

    // Marks a cell live at its geometric slot. Idempotent: a corner cell touched by two of
    // its chunk's borders keeps a single node.
    pub fn addPortalCell(self: *NavGraph, lg: *NavLevelGraph, level: u16, cell_index: usize, chunk: u32) void {
        if (lg.cell_to_portal.items[cell_index] != no_cell) return;
        const slot = self.slotForCell(cell_index);
        lg.portals.items[slot] = .{ .level = level, .cell_index = @intCast(cell_index), .chunk = chunk };
        lg.cell_to_portal.items[cell_index] = slot;
    }

    // Adds this chunk's open link-endpoint cells (on this level) as portals so the intra-chunk
    // pass can connect them to their chunk-local-component peers. Liveness of the cross-level
    // link itself is decided later in rebuildLinkEdges; membership depends only on this level.
    pub fn addChunkLinkPortals(self: *NavGraph, level: u16, chunk: u32, world: *const WorldSystem) void {
        const lg = &self.level_graphs.items[level];
        const level_grid = &self.levels.items[level];
        for (world.levelLinks()) |link| {
            if (link.level_a == level) self.tryLinkPortal(lg, level_grid, link.cell_a.x, link.cell_a.y, chunk);
            if (link.level_b == level) self.tryLinkPortal(lg, level_grid, link.cell_b.x, link.cell_b.y, chunk);
        }
    }

    pub fn tryLinkPortal(self: *NavGraph, lg: *NavLevelGraph, level_grid: *const NavGrid, x: u16, y: u16, chunk: u32) void {
        const cell = level_grid.indexForCell(.{ .x = x, .y = y }) orelse return;
        if (self.chunkOf(cell) != chunk or level_grid.blocked.items[cell]) return;
        self.addPortalCell(lg, level_grid.level, cell, chunk);
    }

    // Connects this chunk's live same-chunk-component portals pairwise with octile cost. Both
    // endpoints share the chunk so both directions land in this chunk's edge window.
    pub fn connectChunkIntraEdges(self: *NavGraph, level: u16, chunk: u32) !void {
        const lg = &self.level_graphs.items[level];
        const components = self.levels.items[level].components.items;
        const pbase = self.chunk_portal_base.items[chunk];
        const pcap = self.chunk_portal_cap.items[chunk];
        var i = pbase;
        while (i < pbase + pcap) : (i += 1) {
            const cell_i = lg.portals.items[i].cell_index;
            if (cell_i == no_cell) continue;
            const comp_i = components[cell_i];
            if (comp_i == no_component) continue;
            var j = i + 1;
            while (j < pbase + pcap) : (j += 1) {
                const cell_j = lg.portals.items[j].cell_index;
                if (cell_j == no_cell or components[cell_j] != comp_i) continue;
                const cost = octileCells(self.width, cell_i, cell_j);
                try lg.edge_scratch.append(self.allocator, .{ .from = i, .edge = .{ .target = j, .cost = cost } });
                try lg.edge_scratch.append(self.allocator, .{ .from = j, .edge = .{ .target = i, .cost = cost } });
            }
        }
    }

    // Writes this chunk's live slots into its portal_order window sorted by (chunk-local
    // label, cell) and builds the chunk's compact label sub-index. Labels of one chunk are
    // disjoint from every other chunk's, so no cross-chunk ordering is needed.
    pub fn orderChunkPortals(self: *NavGraph, level: u16, chunk: u32) void {
        const lg = &self.level_graphs.items[level];
        const components = self.levels.items[level].components.items;
        const pbase = self.chunk_portal_base.items[chunk];
        const pcap = self.chunk_portal_cap.items[chunk];
        var live: u32 = 0;
        var slot = pbase;
        while (slot < pbase + pcap) : (slot += 1) {
            if (lg.portals.items[slot].cell_index == no_cell) continue;
            lg.portal_order.items[pbase + live] = slot;
            live += 1;
        }
        lg.chunk_order_len.items[chunk] = live;
        const run = lg.portal_order.items[pbase .. pbase + live];
        std.sort.pdq(u32, run, PortalComponentSort{ .portals = lg.portals.items, .components = components }, PortalComponentSort.lessThan);
        var klen: u32 = 0;
        var i: u32 = 0;
        while (i < live) {
            const label = components[lg.portals.items[run[i]].cell_index];
            lg.chunk_label_keys.items[pbase + klen] = label;
            lg.chunk_label_starts.items[pbase + klen] = pbase + i;
            var k = i + 1;
            while (k < live and components[lg.portals.items[run[k]].cell_index] == label) k += 1;
            i = k;
            klen += 1;
        }
        lg.chunk_label_len.items[chunk] = klen;
    }

    // Drains this chunk's edge_scratch into its fixed edge window, grouped by source slot,
    // setting portal_edge_start/portal_edge_count per slot. Returns true (without writing past
    // the window) when the chunk's edges exceed its cap, so the caller can fall back.
    pub fn compactChunkEdges(self: *NavGraph, level: u16, chunk: u32) !bool {
        const lg = &self.level_graphs.items[level];
        const pbase = self.chunk_portal_base.items[chunk];
        const pcap = self.chunk_portal_cap.items[chunk];
        const ebase = self.chunk_edge_base.items[chunk];
        const ecap = self.chunk_edge_cap.items[chunk];
        var slot = pbase;
        while (slot < pbase + pcap) : (slot += 1) lg.portal_edge_count.items[slot] = 0;
        for (lg.edge_scratch.items) |scratch| lg.portal_edge_count.items[scratch.from] += 1;
        var running = ebase;
        slot = pbase;
        while (slot < pbase + pcap) : (slot += 1) {
            lg.portal_edge_start.items[slot] = running;
            running += lg.portal_edge_count.items[slot];
        }
        if (running - ebase > ecap) return true;
        // Per-slot write cursor (indexed window-relative) seeded at each slot's edge start.
        const cursor = try self.buildScratch(pcap);
        var i: u32 = 0;
        while (i < pcap) : (i += 1) cursor[i] = lg.portal_edge_start.items[pbase + i];
        for (lg.edge_scratch.items) |scratch| {
            const dst = cursor[scratch.from - pbase];
            lg.portal_edges.items[dst] = scratch.edge;
            cursor[scratch.from - pbase] = dst + 1;
        }
        return false;
    }

    // Drains a fully-built level's edge_scratch (all chunks) into the edge arena, grouped by
    // source slot within each chunk's window. Used only by the full build, where caps were
    // measured to fit, so it cannot overflow.
    pub fn placeLevelEdges(self: *NavGraph, level: u16) !void {
        const lg = &self.level_graphs.items[level];
        try setLen(&lg.portal_edges, self.allocator, self.total_edge_slots);
        @memset(lg.portal_edge_count.items, 0);
        for (lg.edge_scratch.items) |scratch| lg.portal_edge_count.items[scratch.from] += 1;
        const chunk_count = self.chunkCount();
        var chunk: u32 = 0;
        while (chunk < chunk_count) : (chunk += 1) {
            const pbase = self.chunk_portal_base.items[chunk];
            const pcap = self.chunk_portal_cap.items[chunk];
            var running = self.chunk_edge_base.items[chunk];
            var slot = pbase;
            while (slot < pbase + pcap) : (slot += 1) {
                lg.portal_edge_start.items[slot] = running;
                running += lg.portal_edge_count.items[slot];
            }
            std.debug.assert(running - self.chunk_edge_base.items[chunk] <= self.chunk_edge_cap.items[chunk]);
        }
        const cursor = try self.buildScratch(self.total_slots);
        @memcpy(cursor, lg.portal_edge_start.items);
        for (lg.edge_scratch.items) |scratch| {
            lg.portal_edges.items[cursor[scratch.from]] = scratch.edge;
            cursor[scratch.from] += 1;
        }
    }

    // Sizes the per-chunk edge windows from the measured per-chunk MAX init edge count across
    // levels, times the slack multiplier, with a floor. Shared geometry, so the cap of a chunk
    // covers every level's count for that chunk.
    pub fn computeEdgeCaps(self: *NavGraph) !void {
        const chunk_count = self.chunkCount();
        try setLen(&self.chunk_edge_cap, self.allocator, chunk_count);
        try setLen(&self.chunk_edge_base, self.allocator, chunk_count);
        @memset(self.chunk_edge_cap.items, 0);
        const per_level = try self.buildScratch(chunk_count);
        for (self.level_graphs.items) |*lg| {
            @memset(per_level, 0);
            for (lg.edge_scratch.items) |scratch| per_level[lg.portals.items[scratch.from].chunk] += 1;
            for (0..chunk_count) |c| self.chunk_edge_cap.items[c] = @max(self.chunk_edge_cap.items[c], per_level[c]);
        }
        var running: u32 = 0;
        for (0..chunk_count) |c| {
            const raw = self.chunk_edge_cap.items[c];
            const cap = @max(raw *| self.edge_slack, chunk_edge_floor);
            self.chunk_edge_cap.items[c] = cap;
            self.chunk_edge_base.items[c] = running;
            running +|= cap;
        }
        self.total_edge_slots = running;
    }

    // Local portal node index for a cell on `level`, or null when the cell is not a
    // portal. Indexes that level's own cell_to_portal directly.
    pub fn portalIndex(self: *const NavGraph, level: u16, cell_index: u32) ?u32 {
        const lg = self.levelGraph(level) orelse return null;
        if (cell_index >= lg.cell_to_portal.items.len) return null;
        const value = lg.cell_to_portal.items[cell_index];
        return if (value == no_cell) null else value;
    }

    pub fn keyForWorld(self: *const NavGraph, level: u16, goal: math.Vec2, agent_class: PathAgentClass) ?PathQueryKey {
        const level_grid = self.grid(level) orelse return null;
        if (!level_grid.valid()) return null;
        return .{
            .nav_version = self.version,
            .agent_class = agent_class,
            .goal_level = level,
            .goal = level_grid.worldToCellClamped(goal),
        };
    }
};
// Orders a level's portal node indices by chunk-local component label (then cell index
// for a deterministic build) so each label's portals form a contiguous sub-run that
// abstract seeding can scan in isolation.
pub const PortalComponentSort = struct {
    portals: []const PortalNode,
    components: []const u32,

    pub fn lessThan(self: PortalComponentSort, lhs: u32, rhs: u32) bool {
        const a_cell = self.portals[lhs].cell_index;
        const b_cell = self.portals[rhs].cell_index;
        const a_comp = self.components[a_cell];
        const b_comp = self.components[b_cell];
        if (a_comp != b_comp) return a_comp < b_comp;
        return a_cell < b_cell;
    }
};

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const PathfindingSystem = @import("system.zig").PathfindingSystem;
const test_support = @import("test_support.zig");
const abstractCapacity = test_support.abstractCapacity;
const loadTestWorldMeta = test_support.loadTestWorldMeta;
const requireTestTile = test_support.requireTestTile;

// Normalized abstract edge identity for parity comparison: stable across the two
// independent builds' portal-node numbering because it keys on (level, cell) endpoints.
const ParityEdge = struct {
    level_from: u16,
    cell_from: u32,
    level_to: u16,
    cell_to: u32,
    cost: u32,
    crosses_level: bool,

    fn lessThan(_: void, a: ParityEdge, b: ParityEdge) bool {
        if (a.level_from != b.level_from) return a.level_from < b.level_from;
        if (a.cell_from != b.cell_from) return a.cell_from < b.cell_from;
        if (a.level_to != b.level_to) return a.level_to < b.level_to;
        if (a.cell_to != b.cell_to) return a.cell_to < b.cell_to;
        if (a.cost != b.cost) return a.cost < b.cost;
        return @intFromBool(a.crosses_level) < @intFromBool(b.crosses_level);
    }
};

// Collects every abstract edge of `graph` as a normalized (level,cell)->(level,cell)
// tuple multiset (sorted), independent of portal-node numbering: each level's CSR edges
// (crosses_level=false) plus the global link_edges (crosses_level=true, both directions
// for a bidirectional link).
fn collectParityEdges(graph: *const NavGraph, out: *std.ArrayList(ParityEdge)) !void {
    out.clearRetainingCapacity();
    for (graph.level_graphs.items) |*lg| {
        for (lg.portals.items, 0..) |from, node_index| {
            if (from.cell_index == no_cell) continue;
            const begin = lg.portal_edge_start.items[node_index];
            const end = begin + lg.portal_edge_count.items[node_index];
            for (lg.portal_edges.items[begin..end]) |edge| {
                const to = lg.portals.items[edge.target];
                try out.append(std.testing.allocator, .{
                    .level_from = from.level,
                    .cell_from = from.cell_index,
                    .level_to = to.level,
                    .cell_to = to.cell_index,
                    .cost = edge.cost,
                    .crosses_level = false,
                });
            }
        }
    }
    for (graph.link_edges.items) |link| {
        try out.append(std.testing.allocator, .{
            .level_from = link.from_level,
            .cell_from = link.from_cell,
            .level_to = link.to_level,
            .cell_to = link.to_cell,
            .cost = link.cost,
            .crosses_level = true,
        });
        if (link.bidirectional) {
            try out.append(std.testing.allocator, .{
                .level_from = link.to_level,
                .cell_from = link.to_cell,
                .level_to = link.from_level,
                .cell_to = link.from_cell,
                .cost = link.cost,
                .crosses_level = true,
            });
        }
    }
    std.sort.pdq(ParityEdge, out.items, {}, ParityEdge.lessThan);
}

// Asserts the incremental graph `a` is identical to the full-rebuild graph `b`:
// (a) per-level blocked mask + count, (b) per-level chunk-local component labels
// cell-by-cell, (c) portals as the normalized {(level,cell)} set via cell_to_portal
// membership agreement, and (d) edges as the normalized multiset.
fn expectGraphsEquivalent(a: *const NavGraph, b: *const NavGraph) !void {
    const t = std.testing;
    try t.expectEqual(a.levels.items.len, b.levels.items.len);
    try t.expectEqual(a.cellCount(), b.cellCount());
    const cell_count = a.cellCount();
    for (a.levels.items, 0..) |*ga, level_index| {
        const gb = &b.levels.items[level_index];
        try t.expectEqual(ga.blocked_count, gb.blocked_count);
        for (0..cell_count) |i| {
            try t.expectEqual(ga.blocked.items[i], gb.blocked.items[i]);
            try t.expectEqual(ga.components.items[i], gb.components.items[i]);
        }
    }
    // (c) per-level cell_to_portal membership agreement (the {(level,cell)} portal set
    // agrees on which cells are portals).
    for (a.level_graphs.items, 0..) |*la, level_index| {
        const lb = &b.level_graphs.items[level_index];
        try t.expectEqual(cell_count, la.cell_to_portal.items.len);
        try t.expectEqual(cell_count, lb.cell_to_portal.items.len);
        for (0..cell_count) |i| {
            try t.expectEqual(la.cell_to_portal.items[i] == no_cell, lb.cell_to_portal.items[i] == no_cell);
        }
    }
    // (d) edges as a normalized sorted multiset.
    var a_edges = std.ArrayList(ParityEdge).empty;
    defer a_edges.deinit(std.testing.allocator);
    var b_edges = std.ArrayList(ParityEdge).empty;
    defer b_edges.deinit(std.testing.allocator);
    try collectParityEdges(a, &a_edges);
    try collectParityEdges(b, &b_edges);
    try t.expectEqual(a_edges.items.len, b_edges.items.len);
    for (a_edges.items, b_edges.items) |ea, eb| {
        try t.expectEqual(ea, eb);
    }
}

test "incremental nav update remask matches the composed world mask across levels" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const asset_store = @import("../../../assets/assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try @import("../../../assets/world_tileset_meta.zig").load(
        std.testing.allocator,
        asset_store,
        @import("../../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);

    // Small 4-tile chunks (abstractCapacity) so the 8x8 nav grid spans 2x2 chunks per
    // level and the edits straddle chunk boundaries — exercising chunk-local relabel.
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32);

    // Each edit flips a tile's blocking state: carve an underground tunnel cell,
    // punch an underground drop-hole, and block a surface cell.
    const cave_0 = (meta.tileByName("cave_0") orelse return error.TestExpectedEqual).id;
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const floor1 = world.denseFloorLayerForLevel(1).?;
    _ = try world.setDenseTile(floor1, 3, 3, cave_0); // solid dirt -> walkable tunnel
    _ = try world.clearDenseTile(floor1, 4, 3); // solid dirt -> see-through hole
    const floor0 = world.denseFloorLayerForLevel(0).?;
    _ = try world.setDenseTile(floor0, 2, 2, tree); // surface walkable -> blocked

    const edits = [_]NavCellEdit{
        .{ .level = 1, .x = 3, .y = 3 },
        .{ .level = 1, .x = 4, .y = 3 },
        .{ .level = 0, .x = 2, .y = 2 },
    };
    _ = try system.applyNavUpdates(&data, &world, &edits);

    // The incremental remask must equal the authoritative composed mask on every
    // level and cell, with a consistent blocked_count — i.e. identical to a full
    // recompose, but touching only the dirty footprint.
    for (0..world.levelCount()) |level_usize| {
        const level: u16 = @intCast(level_usize);
        const grid = system.graph.grid(level).?;
        var expected_blocked: usize = 0;
        for (0..world.height) |y_usize| {
            const y: u16 = @intCast(y_usize);
            for (0..world.width) |x_usize| {
                const x: u16 = @intCast(x_usize);
                const expect = world.levelBlocksMovement(level, x, y);
                if (expect) expected_blocked += 1;
                try std.testing.expectEqual(expect, grid.isBlockedCell(.{ .x = @intCast(x), .y = @intCast(y) }));
            }
        }
        try std.testing.expectEqual(expected_blocked, grid.blocked_count);
    }

    // The incremental graph must be IDENTICAL to a full rebuild against the same
    // post-edit world/data: same masks, same chunk-local component labels, same portals,
    // and the same abstract edge multiset.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

// Counts live cross-level link edges in `graph` (directed, expanding a bidirectional
// link into its two directions to match collectParityEdges).
fn countCrossLevelEdges(graph: *const NavGraph) usize {
    var count: usize = 0;
    for (graph.link_edges.items) |link| count += if (link.bidirectional) 2 else 1;
    return count;
}

test "incremental nav update splitting a chunk-local component matches a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 12x12 open world, 4-tile chunks. Chunk (1,1) spans cells x4..7, y4..7 and starts
    // as one open local component.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    const grid = system.graph.grid(0).?;
    const left = grid.indexForCell(.{ .x = 4, .y = 5 }).?;
    const right = grid.indexForCell(.{ .x = 6, .y = 5 }).?;
    // Before: both cells share chunk (1,1)'s single open local component.
    try std.testing.expect(grid.connected(left, right));

    // Drop a full-height wall at x=5 inside chunk (1,1), bisecting its open region.
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    var edits = std.ArrayList(NavCellEdit).empty;
    defer edits.deinit(std.testing.allocator);
    var wy: u16 = 4;
    while (wy <= 7) : (wy += 1) {
        const changed = (try world.setDenseTile(wall_layer, 5, wy, tree)) orelse return error.TestExpectedEqual;
        try edits.append(std.testing.allocator, .{ .level = changed.level, .x = changed.x, .y = changed.y });
    }
    _ = try system.applyNavUpdates(&data, &world, edits.items);

    // After: the chunk-local component split into two distinct labels.
    try std.testing.expect(grid.componentOf(left) != no_component);
    try std.testing.expect(grid.componentOf(right) != no_component);
    try std.testing.expect(!grid.connected(left, right));

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental nav update on a chunk border flips a neighbor chunk's portal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 12x12 open world, 4-tile chunks. The vertical border at x=4 puts cell (3,5) in
    // chunk (0,1) and its open neighbor (4,5) in chunk (1,1); both are border portals.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    const grid = system.graph.grid(0).?;
    const near = grid.indexForCell(.{ .x = 3, .y = 5 }).?; // chunk (0,1), the edited side
    const neighbor = grid.indexForCell(.{ .x = 4, .y = 5 }).?; // chunk (1,1)
    try std.testing.expect(system.graph.portalIndex(0, @intCast(near)) != null);
    try std.testing.expect(system.graph.portalIndex(0, @intCast(neighbor)) != null);
    const neighbor_label_before = grid.componentOf(neighbor);

    // Block (3,5) on the chunk (0,1) side: the (3,5)|(4,5) portal pair disappears, so
    // the NEIGHBOR chunk (1,1)'s portal at (4,5) flips off even though only chunk (0,1)
    // is relabeled.
    const obstacle_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    const changed = (try world.setDenseTile(obstacle_layer, 3, 5, tree)) orelse return error.TestExpectedEqual;
    _ = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    try std.testing.expect(system.graph.portalIndex(0, @intCast(near)) == null);
    try std.testing.expect(system.graph.portalIndex(0, @intCast(neighbor)) == null);
    // The neighbor chunk's component labels were NOT recomputed: (4,5) keeps its label.
    try std.testing.expectEqual(neighbor_label_before, grid.componentOf(neighbor));

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental nav update opening a ramp endpoint adds a live LevelLink edge" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    const level1_obstacle = try world.addDenseLayer(1, 0, .obstacle, grass);
    _ = try world.setDenseTile(level1_obstacle, 2, 2, tree); // ramp endpoint starts blocked
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    // Endpoint blocked => link not live => no cross-level edge.
    try std.testing.expectEqual(@as(usize, 0), countCrossLevelEdges(&system.graph));

    // Dig the ramp endpoint open: buildLinkEdges re-derives the link as live.
    const changed = (try world.setDenseTile(level1_obstacle, 2, 2, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    _ = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    // Bidirectional link now contributes its crosses_level edge pair.
    try std.testing.expect(countCrossLevelEdges(&system.graph) > 0);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental underground dig leaves the surface level abstract graph byte-identical" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // Open 12x12 surface (level 0) spanning many 4-tile chunks, plus an underground
    // level 1 with a diggable obstacle. The surface graph is large (the regression the
    // per-level split targets); an underground dig must do ZERO work on it.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    const level1_obstacle = try world.addDenseLayer(1, 0, .obstacle, grass);
    _ = try world.setDenseTile(level1_obstacle, 5, 5, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    // Snapshot level 0's per-level abstract graph contents.
    const lg0 = system.graph.levelGraph(0).?;
    try std.testing.expect(lg0.liveCount() > 0);
    const portals_before = try std.testing.allocator.dupe(PortalNode, lg0.portals.items);
    defer std.testing.allocator.free(portals_before);
    const edges_before = try std.testing.allocator.dupe(AbstractEdge, lg0.portal_edges.items);
    defer std.testing.allocator.free(edges_before);
    const start_before = try std.testing.allocator.dupe(u32, lg0.portal_edge_start.items);
    defer std.testing.allocator.free(start_before);
    const count_before = try std.testing.allocator.dupe(u32, lg0.portal_edge_count.items);
    defer std.testing.allocator.free(count_before);
    const c2p_before = try std.testing.allocator.dupe(u32, lg0.cell_to_portal.items);
    defer std.testing.allocator.free(c2p_before);

    // Dig an UNDERGROUND-only cell open (level 1).
    const changed = (try world.setDenseTile(level1_obstacle, 5, 5, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);

    // The surface's portals, CSR edges/windows, and cell_to_portal are byte-for-byte
    // unchanged: an underground edit costs nothing on the (large) surface graph.
    const lg0_after = system.graph.levelGraph(0).?;
    try std.testing.expectEqualSlices(PortalNode, portals_before, lg0_after.portals.items);
    try std.testing.expectEqualSlices(AbstractEdge, edges_before, lg0_after.portal_edges.items);
    try std.testing.expectEqualSlices(u32, start_before, lg0_after.portal_edge_start.items);
    try std.testing.expectEqualSlices(u32, count_before, lg0_after.portal_edge_count.items);
    try std.testing.expectEqualSlices(u32, c2p_before, lg0_after.cell_to_portal.items);
    // Sanity: the underground level DID change (not a no-op batch).
    try std.testing.expect(!system.graph.grid(1).?.isBlockedCell(.{ .x = 5, .y = 5 }));

    // And it still matches a full rebuild on every level.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental dig keeps the changed level's portal slots byte-identical to a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    const level1_obstacle = try world.addDenseLayer(1, 0, .obstacle, grass);
    _ = try world.setDenseTile(level1_obstacle, 5, 5, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    const changed = (try world.setDenseTile(level1_obstacle, 5, 5, grass)) orelse return error.TestExpectedEqual;
    _ = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    // The slot layout is pure geometry and liveness a pure function of the (identical) mask,
    // so portals[] and cell_to_portal[] on the CHANGED level are byte-identical to a fresh
    // full rebuild even though the edge windows (per-chunk slack) are not.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    const inc = system.graph.levelGraph(1).?;
    const full = rebuilt.graph.levelGraph(1).?;
    try std.testing.expectEqualSlices(PortalNode, full.portals.items, inc.portals.items);
    try std.testing.expectEqualSlices(u32, full.cell_to_portal.items, inc.cell_to_portal.items);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental nav update applies the same edit batch deterministically" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    // Apply a multi-cell straddling edit, snapshot the changed level, then rebuild from the
    // same start state and apply the same batch again: the result must be identical.
    const edits = [_]NavCellEdit{ .{ .level = 0, .x = 5, .y = 5 }, .{ .level = 0, .x = 6, .y = 5 }, .{ .level = 0, .x = 5, .y = 6 } };
    _ = (try world.setDenseTile(obstacle, 5, 5, tree)) orelse return error.TestExpectedEqual;
    _ = (try world.setDenseTile(obstacle, 6, 5, tree)) orelse return error.TestExpectedEqual;
    _ = (try world.setDenseTile(obstacle, 5, 6, tree)) orelse return error.TestExpectedEqual;
    _ = try system.applyNavUpdates(&data, &world, &edits);

    const portals_a = try std.testing.allocator.dupe(PortalNode, system.graph.levelGraph(0).?.portals.items);
    defer std.testing.allocator.free(portals_a);
    const c2p_a = try std.testing.allocator.dupe(u32, system.graph.levelGraph(0).?.cell_to_portal.items);
    defer std.testing.allocator.free(c2p_a);
    var edges_a = std.ArrayList(ParityEdge).empty;
    defer edges_a.deinit(std.testing.allocator);
    try collectParityEdges(&system.graph, &edges_a);

    var second = PathfindingSystem.init(std.testing.allocator);
    defer second.deinit();
    try second.reserve(abstractCapacity());
    try second.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    var edges_b = std.ArrayList(ParityEdge).empty;
    defer edges_b.deinit(std.testing.allocator);
    try collectParityEdges(&second.graph, &edges_b);

    try std.testing.expectEqualSlices(PortalNode, portals_a, second.graph.levelGraph(0).?.portals.items);
    try std.testing.expectEqualSlices(u32, c2p_a, second.graph.levelGraph(0).?.cell_to_portal.items);
    try std.testing.expectEqual(edges_a.items.len, edges_b.items.len);
    for (edges_a.items, edges_b.items) |ea, eb| try std.testing.expectEqual(ea, eb);
}

test "incremental dig overflowing a chunk edge window falls back to a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // Wall the whole world at init so every chunk's edge window is sized to the floor. Then
    // open a large block so an affected chunk's edges blow past the floor*slack window,
    // forcing the loud edge-cap fallback.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, tree);
    var y: u16 = 0;
    while (y < 12) : (y += 1) {
        var x: u16 = 0;
        while (x < 12) : (x += 1) _ = try world.setDenseTile(wall_layer, x, y, tree);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    var edits = std.ArrayList(NavCellEdit).empty;
    defer edits.deinit(std.testing.allocator);
    y = 0;
    while (y < 12) : (y += 1) {
        var x: u16 = 0;
        while (x < 12) : (x += 1) {
            const opened = (try world.setDenseTile(wall_layer, x, y, grass)) orelse continue;
            try edits.append(std.testing.allocator, .{ .level = opened.level, .x = opened.x, .y = opened.y });
        }
    }
    const stats = try system.applyNavUpdates(&data, &world, edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 1), stats.edge_cap_fallback);

    // The fallback still produces a graph equivalent to an independent full rebuild.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental single-chunk dig patches a constant chunk set independent of world size" {
    // The dirty-bounded work proxy: a one-cell dig in an interior chunk patches that chunk
    // plus its four orthogonal neighbors (5), regardless of how large the level is. If this
    // ever scaled with world size, dirty-bounding would have silently regressed.
    const extents = [_]f32{ 512, 1024 };
    var patched: [extents.len]usize = undefined;
    for (extents, 0..) |extent, i| {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var meta = try loadTestWorldMeta(std.testing.allocator);
        defer meta.deinit();
        const grass = try requireTestTile(&meta, "grass");
        const tree = try requireTestTile(&meta, "tree_0");

        var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
        defer world.deinit();
        const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());
        try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32);

        // Cell (5,5) sits in chunk (1,1) (4-tile chunks): interior for both worlds.
        const changed = (try world.setDenseTile(obstacle, 5, 5, tree)) orelse return error.TestExpectedEqual;
        const stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
        patched[i] = stats.chunks_patched;
    }
    try std.testing.expectEqual(@as(usize, 5), patched[0]);
    try std.testing.expectEqual(patched[0], patched[1]);
}
