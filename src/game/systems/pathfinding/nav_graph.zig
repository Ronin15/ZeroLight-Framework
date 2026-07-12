// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-level chunk-portal abstract navigation graph plus inter-level link edges.
//! Owns one NavGrid per level, a geometric chunk-stable slot layout, and the
//! incremental dirty-chunk patch path used by in-place digs.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../../core/math.zig");
const logging = @import("../../../core/logging.zig");
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../../../app/thread_system.zig").AdaptiveWorkTuner;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
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

// Re-exported from types so callers can import either module.
pub const PortalNode = types.PortalNode;
pub const AbstractEdge = types.AbstractEdge;

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

// Entry in the sorted per-(level, cell) index into link_edges. Sorted by (level, cell)
// so abstractCorridor can binary-search for the incident-link range instead of scanning
// all link_edges per portal expansion.
pub const LinkEdgeRef = struct {
    level: u16,
    cell: u32,
    index: u32, // index into link_edges.items
    reverse: bool, // true: this ref covers the "to" end of a bidirectional link

    fn lessThan(_: void, a: LinkEdgeRef, b: LinkEdgeRef) bool {
        if (a.level != b.level) return a.level < b.level;
        return a.cell < b.cell;
    }
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
    fn liveCount(self: *const NavLevelGraph) usize {
        var count: usize = 0;
        for (self.chunk_order_len.items) |len| count += len;
        return count;
    }
};
// Per-worker scratch for one chunk patch: the chunk's transient edge list (filled by
// discover/intra, drained into the chunk's fixed edge window) and the compaction cursor.
// One slot per threaded participant so chunk patches run in parallel without sharing
// writable state; the serial path uses slot 0. Both buffers are per-chunk transient,
// cleared at the start of each patch. Distinct from NavLevelGraph.edge_scratch, which the
// init full build reuses to accumulate a whole level's edges.
// align(64) on `edges` forces @alignOf(ChunkPatchScratch)==64 and @sizeOf==64 (Zig rounds
// struct size up to its alignment), so adjacent worker slots occupy separate cache lines
// and workers patching chunks in parallel see no false sharing.
const ChunkPatchScratch = struct {
    edges: std.ArrayList(NavLevelGraph.EdgeScratch) align(64) = .empty,
    cursor: std.ArrayList(u32) = .empty,
    // Set when this chunk's edges overflowed its fixed window during compaction.
    overflow: bool = false,

    comptime {
        std.debug.assert(@sizeOf(ChunkPatchScratch) == 64);
        std.debug.assert(@alignOf(ChunkPatchScratch) == 64);
    }

    fn deinit(self: *ChunkPatchScratch, allocator: std.mem.Allocator) void {
        self.edges.deinit(allocator);
        self.cursor.deinit(allocator);
    }
};

// Per-worker scratch for the threaded remask + component re-flood stage: the BFS queue for the
// chunk-local component flood and a private blocked-count delta. One slot per participant so
// chunks re-flood in parallel without sharing the queue or racing the shared blocked counter;
// the serial path uses slot 0 and the deltas are summed once after the barrier.
// align(64) on `queue` forces @alignOf(ChunkRemaskScratch)==64 and @sizeOf==64 (Zig rounds
// struct size up to its alignment), so adjacent worker slots occupy separate cache lines
// and workers accumulating blocked_delta in parallel see no false sharing.
const ChunkRemaskScratch = struct {
    queue: std.ArrayList(usize) align(64) = .empty,
    blocked_delta: isize = 0,

    comptime {
        std.debug.assert(@sizeOf(ChunkRemaskScratch) == 64);
        std.debug.assert(@alignOf(ChunkRemaskScratch) == 64);
    }

    fn deinit(self: *ChunkRemaskScratch, allocator: std.mem.Allocator) void {
        self.queue.deinit(allocator);
    }
};

// Threading context for ONE incremental nav-update stage (remask or patch): the shared thread
// system plus that stage's own adaptive tuner. The adaptive tuner keeps small digs inline and
// threads only dig-storms, so there is no fixed per-step budget — the tuner IS the policy.
// `adaptive`/`items_per_range` are control knobs: production runs adaptive (tuner decides), but
// the benchmark can pin a FIXED range partition so the adaptive tuner is measured against fixed
// controls (the shared bench theme).
const NavStageThreads = struct {
    thread_system: *ThreadSystem,
    tuner: *AdaptiveWorkTuner,
    adaptive: bool = true,
    items_per_range: ?usize = null,
};

// Threading for a whole incremental update: the shared thread system plus a SEPARATE tuner per
// stage (remask/re-flood vs. abstract patch are different work shapes, so each owns its tuner
// per the one-tuner-per-stage rule). `adaptive`/`items_per_range` are the per-update control
// config (defaults: adaptive, tuner-chosen ranges). Absent → fully serial.
pub const NavUpdateThreads = struct {
    thread_system: *ThreadSystem,
    remask_tuner: *AdaptiveWorkTuner,
    patch_tuner: *AdaptiveWorkTuner,
    adaptive: bool = true,
    items_per_range: ?usize = null,

    fn remask(self: NavUpdateThreads) NavStageThreads {
        return .{ .thread_system = self.thread_system, .tuner = self.remask_tuner, .adaptive = self.adaptive, .items_per_range = self.items_per_range };
    }
    fn patch(self: NavUpdateThreads) NavStageThreads {
        return .{ .thread_system = self.thread_system, .tuner = self.patch_tuner, .adaptive = self.adaptive, .items_per_range = self.items_per_range };
    }
};

// Job context for the threaded chunk patch. Each dirty chunk is independent — it writes only
// its own disjoint portal/edge slot windows and uses its worker's own ChunkPatchScratch slot —
// so chunk patches run race-free and the threaded result is byte-identical to the serial one.
const NavPatchJob = struct {
    graph: *NavGraph,
    world: *const WorldSystem,
    level: u16,
    chunks: []const u32,
};

fn patchChunkJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *NavPatchJob = @ptrCast(@alignCast(context));
    // Guards the reserve-before-dispatch invariant: patch_scratch was sized to the
    // participant count that patchDirtyChunks checked before dispatching this batch.
    std.debug.assert(worker_id.index < job.graph.patch_scratch.items.len);
    const scratch = &job.graph.patch_scratch.items[worker_id.index];
    for (range.start..range.end) |i| {
        const overflowed = job.graph.patchChunk(job.level, job.world, job.chunks[i], scratch) catch {
            // Any patchChunk error (today only OOM) is folded into the same `overflow` flag as a
            // genuine edge-window overflow, so both route into the post-barrier full rebuild. This
            // intentionally conflates the two recovery triggers: the fallback is correct for either,
            // and an OOM there surfaces loudly anyway. Split the signal only if OOM needs distinct handling.
            scratch.overflow = true;
            continue;
        };
        if (overflowed) scratch.overflow = true;
    }
}

// Job context for the threaded remask + component re-flood. Each changed chunk re-derives only
// its own mask/component cells (disjoint), so chunks run race-free; the blocked-count delta is
// accumulated into this worker's scratch slot and summed after the barrier.
const NavRemaskJob = struct {
    graph: *NavGraph,
    data: *const DataSystem,
    world: *const WorldSystem,
    level: u16,
    chunks: []const u32,
};

fn remaskChunkJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *NavRemaskJob = @ptrCast(@alignCast(context));
    const level_grid = &job.graph.levels.items[job.level];
    // Guards the reserve-before-dispatch invariant: remask_scratch was sized to the
    // participant count that remaskChangedChunks checked before dispatching this batch.
    std.debug.assert(worker_id.index < job.graph.remask_scratch.items.len);
    const scratch = &job.graph.remask_scratch.items[worker_id.index];
    for (range.start..range.end) |i| {
        scratch.blocked_delta += level_grid.remaskChunkFromWorld(job.chunks[i], job.data, job.world);
        level_grid.recomputeChunkComponents(job.chunks[i], &scratch.queue);
    }
}

const NavLevelMaskJob = struct {
    graph: *NavGraph,
    world: ?*const WorldSystem,
};

fn navLevelMaskJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *NavLevelMaskJob = @ptrCast(@alignCast(context));
    const world_system = job.world orelse return;
    for (range.start..range.end) |level_index| {
        const level_grid = &job.graph.levels.items[level_index];
        level_grid.markWorldObstacles(world_system);
        level_grid.buildComponents();
    }
}

// Whether `level_index` appears in the whole-level-dirty id list. The list is tiny (one
// entry per fully-changed level this batch), so a linear scan is cheaper than a bitset.
fn levelIsFull(full_level_ids: []const u16, level_index: usize) bool {
    for (full_level_ids) |id| {
        if (@as(usize, id) == level_index) return true;
    }
    return false;
}

// Per-level chunk-portal navigation graph plus inter-level link edges. Owns one
// NavGrid per level (Z-floor) sharing dimensions/cell_size. Built once at nav
// rebuild; queried read-only afterward.
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
    // Sorted per-(level, cell) index into link_edges, rebuilt alongside it. Each entry
    // points from a (level, cell) key to the link_edges slot incident to it; bidirectional
    // links get two entries. Sorted by (level, cell) so abstractCorridor binary-searches
    // for the incident range rather than scanning all link_edges per portal expansion.
    link_edge_refs: std.ArrayList(LinkEdgeRef) = .empty,
    // Persistent u32 scratch reused (non-overlapping) by the per-level abstract-graph
    // build helpers for the portal sort order and the CSR cursors. Persisting it (vs a
    // per-build allocator.alloc) keeps both the init build and the incremental
    // `applyNavUpdates` rebuild allocation-free once the graph has been built once.
    build_u32_scratch: std.ArrayList(u32) = .empty,
    // Per-participant chunk-patch scratch (worker count + 1, min 1), sized at rebuild. The
    // threaded incremental patch indexes this by worker id; the serial path uses slot 0.
    patch_scratch: std.ArrayList(ChunkPatchScratch) = .empty,
    // Per-participant scratch for the threaded remask + component re-flood stage (workers + 1,
    // min 1), sized at rebuild. Indexed by worker id; the serial path uses slot 0.
    remask_scratch: std.ArrayList(ChunkRemaskScratch) = .empty,
    // Batch shape of the most recent patch / remask stage (which worker profile the tuner
    // picked), for benchmark/diagnostic reporting. Not part of the graph contract.
    last_patch_batch: BatchStats = .{},
    last_remask_batch: BatchStats = .{},

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
    // Deduped list of CHANGED chunks (those containing edits) for one level, the work-list for
    // the remask-from-world + component re-flood stage. Distinct from dirty_set, which also
    // includes border neighbors for the abstract patch stage.
    changed_chunks: std.ArrayList(u32) = .empty,

    pub fn deinit(self: *NavGraph) void {
        self.dirty_stamp.deinit(self.allocator);
        self.dirty_set.deinit(self.allocator);
        self.changed_chunks.deinit(self.allocator);
        self.chunk_link_count.deinit(self.allocator);
        self.chunk_link_base.deinit(self.allocator);
        self.chunk_link_cells.deinit(self.allocator);
        self.chunk_edge_base.deinit(self.allocator);
        self.chunk_edge_cap.deinit(self.allocator);
        self.chunk_portal_base.deinit(self.allocator);
        self.chunk_portal_cap.deinit(self.allocator);
        self.build_u32_scratch.deinit(self.allocator);
        for (self.patch_scratch.items) |*scratch| scratch.deinit(self.allocator);
        self.patch_scratch.deinit(self.allocator);
        for (self.remask_scratch.items) |*scratch| scratch.deinit(self.allocator);
        self.remask_scratch.deinit(self.allocator);
        self.link_edge_refs.deinit(self.allocator);
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
        thread_system: ?*ThreadSystem,
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
            try level_grid.prepare(self.allocator, level, self.width, self.height, safe_cell_size, self.chunk_tiles);
            // Only level 0 sources DataSystem collision bodies; the demo's
            // entities live on the ground floor. World mask drives every level.
            if (level == 0) try level_grid.markStaticBodies(self.allocator, data);
        }

        // Ensure one chunk-patch scratch slot per threaded participant (workers + main) BEFORE
        // the abstract build, because buildLevelInit uses one slot per worker.
        const participant_count = @max(@as(usize, 1), memory_budget.worker_participant_count);
        try self.patch_scratch.ensureTotalCapacity(self.allocator, participant_count);
        while (self.patch_scratch.items.len < participant_count) self.patch_scratch.appendAssumeCapacity(.{});

        const prepared_level_count = self.levels.items.len;
        if (world) |world_system| {
            if (thread_system) |threads| {
                if (prepared_level_count > 1) {
                    var mask_job = NavLevelMaskJob{ .graph = self, .world = world };
                    _ = threads.parallelForWithOptions(prepared_level_count, &mask_job, navLevelMaskJob, .{
                        .items_per_range = 1,
                        .range_alignment_items = 1,
                        .adaptive = false,
                    });
                } else {
                    for (self.levels.items) |*level_grid| {
                        level_grid.markWorldObstacles(world_system);
                        level_grid.buildComponents();
                    }
                }
            } else {
                for (self.levels.items) |*level_grid| {
                    level_grid.markWorldObstacles(world_system);
                    level_grid.buildComponents();
                }
            }
        } else {
            for (self.levels.items) |*level_grid| {
                level_grid.buildComponents();
            }
        }

        self.edge_slack = default_edge_slack;
        try self.buildAbstractGraphs(world);
        try self.rebuildLinkEdges(world);

        // Pre-reserve each slot's edge buffer and compaction cursor so a patch — serial OR
        // threaded — never reallocates, including the overflow path that is detected only AFTER
        // a chunk's full transient edge list is built. The transient list is bounded by a chunk's
        // border edges (<= pcap) plus its same-component intra pairs (<= pcap*(pcap-1)), i.e.
        // pcap^2; reserving that keeps a worker-thread append allocation-free even when a chunk's
        // edges exceed its compaction window (which then triggers the loud full-rebuild fallback).
        var max_portal_cap: usize = 0;
        for (self.chunk_portal_cap.items) |cap| max_portal_cap = @max(max_portal_cap, cap);
        const max_transient_edges = max_portal_cap *| max_portal_cap;
        for (self.patch_scratch.items) |*scratch| {
            try scratch.edges.ensureTotalCapacity(self.allocator, max_transient_edges);
            try scratch.cursor.ensureTotalCapacity(self.allocator, max_portal_cap);
        }

        // Per-participant remask/re-flood scratch: a BFS queue sized to one chunk's cell count
        // (a chunk-local flood never leaves its chunk) so a threaded re-flood is allocation-free.
        try self.remask_scratch.ensureTotalCapacity(self.allocator, participant_count);
        while (self.remask_scratch.items.len < participant_count) self.remask_scratch.appendAssumeCapacity(.{});
        const chunk_cells = @as(usize, self.chunk_tiles) * @as(usize, self.chunk_tiles);
        for (self.remask_scratch.items) |*scratch| {
            try scratch.queue.ensureTotalCapacity(self.allocator, chunk_cells);
        }
    }

    // (Re)builds the chunk-stable slot geometry and every level's full abstract graph from
    // the current masks/components. Used by the init rebuild and by the edge-cap fallback;
    // it re-measures per-chunk edge caps from the current topology, so it never overflows.
    fn buildAbstractGraphs(self: *NavGraph, world: ?*const WorldSystem) !void {
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
    // when emitting link_edges. `version` stays stable on the common incremental-patch
    // path — node slots are geometry-stable, so old goal-keyed cache/pending entries
    // still index correctly and the caller scope-evicts only the edited cells instead.
    // `version` bumps only on a full relabel or an edge-cap-overflow fallback rebuild
    // (stats.version_bumps), where node identities can actually change and every
    // goal-keyed entry must re-solve. `affected_levels` is caller-owned pre-reserved
    // scratch (sized to level count), but this function grows/frees it with `self.allocator`
    // (the graph's own), not a caller-supplied one — the caller MUST deinit it with the
    // same allocator instance passed to this NavGraph, or the alloc/free pair mismatches.
    // PathfindingSystem satisfies this because it constructs itself and its NavGraph from
    // one shared allocator.
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
        world: *const WorldSystem,
        edits: []const NavCellEdit,
        cell_edits: []const types.ChangedSpan,
        full_level_ids: []const u16,
        affected_levels: *std.ArrayList(bool),
        full_relabel_level_threshold: usize,
        update_threads: ?NavUpdateThreads,
    ) !NavUpdateStats {
        var stats = NavUpdateStats{};
        if ((edits.len == 0 and cell_edits.len == 0 and full_level_ids.len == 0) or !self.valid()) return stats;
        // Each stage runs through its own tuner (remask/re-flood vs. abstract patch).
        const remask_threads: ?NavStageThreads = if (update_threads) |t| t.remask() else null;
        const patch_threads: ?NavStageThreads = if (update_threads) |t| t.patch() else null;

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
        // Entity-driven obstacle changes: a world-space rect already resolved to a nav-cell
        // span (see PathfindingSystem.markNavObstacleRectDirty), so no tile lookup is needed.
        for (cell_edits) |edit| {
            if (@as(usize, edit.level) >= level_count) continue;
            if (!affected_levels.items[edit.level]) {
                affected_levels.items[edit.level] = true;
                affected_level_count += 1;
            }
        }
        // Whole-level dirty requests mark a level fully changed (every chunk remasked + patched).
        // Used when a change cannot be localized to cells — e.g. a destroyed/toggled static
        // obstacle whose nav cell is no longer resolvable from the entity.
        for (full_level_ids) |full_level| {
            if (@as(usize, full_level) >= level_count) continue;
            if (!affected_levels.items[full_level]) {
                affected_levels.items[full_level] = true;
                affected_level_count += 1;
            }
        }
        if (affected_level_count == 0) return stats;
        // Purely diagnostic, O(edits) via the dirty-chunk stamp; only pay for it when perf
        // logging consumes it.
        if (runtime_perf_log.enabled) stats.dirty_chunks = self.countDirtyChunks(world, edits, cell_edits);

        // Re-derive the static-body coverage cache from the CURRENT live static-body set before
        // any chunk remask reads it (staticBodyCoversNavCell's fast path is a cache read, so a
        // stale cache would otherwise still report a destroyed/moved body's old cells blocked).
        // A whole-level-dirty request rebuilds via markStaticBodies (O(bodies), one rasterize per
        // body's own footprint) rather than refreshStaticCoverageSpan over the whole grid, which
        // would scan every live body per cell (O(cells x bodies)); an entity rect still uses the
        // cell-scoped refresh since its span is small by construction.
        for (full_level_ids) |full_level| {
            if (@as(usize, full_level) >= self.levels.items.len) continue;
            const level_grid = &self.levels.items[full_level];
            if (level_grid.cellCount() == 0) continue;
            try level_grid.markStaticBodies(self.allocator, data);
        }
        for (cell_edits) |edit| {
            if (@as(usize, edit.level) >= self.levels.items.len) continue;
            self.levels.items[edit.level].refreshStaticCoverageSpan(data, edit.span);
        }

        // Re-derive the blocked mask + chunk-local components of every chunk an edit touched
        // (or every chunk on a whole-level-dirty level), reading the world over the WHOLE chunk
        // (not just enumerated cells) so cells the producer coalesced or dropped upstream are
        // still correct. Deduped per chunk and byte-identical to a full mark. Past the threshold
        // a level-count blowup degenerates to a full graph rebuild; flag it loudly rather than
        // silently doing whole-world work.
        const full_relabel = affected_level_count > full_relabel_level_threshold;
        if (full_relabel) {
            for (self.levels.items, 0..) |_, level_index| {
                if (!affected_levels.items[level_index]) continue;
                self.remaskChangedChunks(@intCast(level_index), data, world, edits, cell_edits, levelIsFull(full_level_ids, level_index), remask_threads);
            }
            for (self.levels.items) |*level_grid| level_grid.buildComponents();
            try self.buildAbstractGraphs(world);
            stats.full_relabel = 1;
        } else {
            var overflow = false;
            for (self.levels.items, 0..) |_, level_index| {
                if (!affected_levels.items[level_index]) continue;
                const level: u16 = @intCast(level_index);
                const full_level = levelIsFull(full_level_ids, level_index);
                // Changed chunks: remask from world + re-flood components (deduped). Neighbor
                // chunks added by buildDirtySet are NOT remasked/re-flooded — their mask is
                // untouched — only their abstract layer is patched below.
                self.remaskChangedChunks(level, data, world, edits, cell_edits, full_level, remask_threads);
                self.buildDirtySet(level, world, edits, cell_edits, full_level);
                stats.chunks_patched += self.dirty_set.items.len;
                if (try self.patchDirtyChunks(level, world, patch_threads)) overflow = true;
            }
            if (overflow) {
                // A chunk's edges blew past its fixed window: bump slack and rebuild the
                // whole abstract graph (re-measuring caps so they fit the new topology). Also
                // surfaced via the edge_cap_fallback counter (recorded as a perf metric by the
                // app-layer caller). This is a cold dig-triggered event (not the per-frame path),
                // so the recovered-degradation warn is gated on the warn level (a release build
                // still surfaces it) rather than the Debug-only hot-path flag — but stays out of
                // test builds, which legitimately trigger this and should not spam stderr.
                self.edge_slack = std.math.add(u32, self.edge_slack, self.edge_slack) catch self.edge_slack;
                if (comptime logging.enabled(.warn) and !builtin.is_test)
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
            stats.version_bumps = 1;
        }

        stats.incremental_rebuilds = 1;
        return stats;
    }

    // Patches the current self.dirty_set for one level, serial or threaded. Threaded only when a
    // patch context is present, there is more than one chunk, and the live participant count fits
    // the pre-sized scratch slots; otherwise serial (slot 0). Returns true if any chunk overflowed
    // its edge window. parallelForWithOptions is a barrier, so self.dirty_set stays stable across
    // the batch and the next level's buildDirtySet runs only after it completes.
    fn patchDirtyChunks(self: *NavGraph, level: u16, world: *const WorldSystem, patch_threads: ?NavStageThreads) !bool {
        const chunks = self.dirty_set.items;
        if (patch_threads) |threads| {
            const participants = threads.thread_system.participantSlotCount();
            if (chunks.len > 1 and participants <= self.patch_scratch.items.len) {
                for (self.patch_scratch.items) |*scratch| scratch.overflow = false;
                var job = NavPatchJob{ .graph = self, .world = world, .level = level, .chunks = chunks };
                self.last_patch_batch = threads.thread_system.parallelForWithOptions(chunks.len, &job, patchChunkJob, .{
                    .adaptive = threads.adaptive,
                    .adaptive_tuner = threads.tuner,
                    .items_per_range = threads.items_per_range,
                    .range_alignment_items = 1,
                });
                var overflow = false;
                for (self.patch_scratch.items) |*scratch| {
                    if (scratch.overflow) overflow = true;
                }
                return overflow;
            }
        }
        self.last_patch_batch = .{ .item_count = chunks.len, .ran_inline = true };
        var overflow = false;
        const scratch = &self.patch_scratch.items[0];
        for (chunks) |chunk| {
            if (try self.patchChunk(level, world, chunk, scratch)) overflow = true;
        }
        return overflow;
    }

    // Builds this batch's dirty-chunk set for one level into self.dirty_set: every chunk a
    // dirty cell falls in, plus each of those chunks' orthogonal (border-sharing) internal
    // neighbors. Diagonal neighbors are excluded — they share only a corner, never a border
    // line, so no transition edge crosses them. Deduped via an epoch-stamped marker.
    fn buildDirtySet(self: *NavGraph, level: u16, world: *const WorldSystem, edits: []const NavCellEdit, cell_edits: []const types.ChangedSpan, full_level: bool) void {
        self.dirty_set.clearRetainingCapacity();
        _ = self.bumpDirtyEpoch();
        if (full_level) {
            // Whole level dirty: every chunk is patched (each chunk's own border set already
            // covers its neighbors, so no separate neighbor pass is needed).
            const total: u32 = @intCast(self.chunkCount());
            var chunk: u32 = 0;
            while (chunk < total) : (chunk += 1) self.addDirtyChunk(chunk);
            return;
        }
        const ct: usize = self.chunk_tiles;
        const cx_count = self.chunksX();
        const cy_count = self.chunksY();
        const level_grid = &self.levels.items[level];
        for (edits) |edit| {
            if (edit.level != level) continue;
            const span = level_grid.navSpanForTile(world, edit) orelse continue;
            self.addDirtySpanNeighbors(span, ct, cx_count, cy_count);
        }
        for (cell_edits) |edit| {
            if (edit.level != level) continue;
            self.addDirtySpanNeighbors(edit.span, ct, cx_count, cy_count);
        }
    }

    // Marks every chunk a nav-cell span touches plus each touched chunk's orthogonal
    // (border-sharing) internal neighbors dirty. Shared by buildDirtySet's tile-edit and
    // entity-driven cell-edit passes so both add neighbors identically.
    fn addDirtySpanNeighbors(self: *NavGraph, span: types.NavSpan, ct: usize, cx_count: usize, cy_count: usize) void {
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

    fn addDirtyChunk(self: *NavGraph, chunk: u32) void {
        if (self.dirty_stamp.items[chunk] == self.dirty_epoch) return;
        self.dirty_stamp.items[chunk] = self.dirty_epoch;
        self.dirty_set.appendAssumeCapacity(chunk);
    }

    // Advances the dirty-chunk epoch used for O(1) per-batch dedup, returning the live epoch.
    // On the (astronomically rare) u32 wrap back to 0 it re-zeroes the stamps and skips 0, so a
    // never-stamped chunk (stamp 0) can never be mistaken for "already seen this batch".
    fn bumpDirtyEpoch(self: *NavGraph) u32 {
        self.dirty_epoch +%= 1;
        if (self.dirty_epoch == 0) {
            @memset(self.dirty_stamp.items, 0);
            self.dirty_epoch = 1;
        }
        return self.dirty_epoch;
    }

    // Counts distinct abstract chunks touched by the batch — a diagnostic recorded only when
    // perf logging is enabled. Uses each edit's full navSpanForTile rect (matching the real
    // remask/patch work), so a tile whose cell rect straddles a chunk border is not undercounted.
    // O(edit-spans) via the dirty-chunk stamp; the prior O(edits^2) pairwise scan was only
    // acceptable while edits were capped, but the dirty buffer is now uncapped (scales with
    // simultaneous diggers), so the quadratic form must not run. Dedup is by chunk id; a
    // cross-level same-chunk-id collision under-counts by one, immaterial for a diagnostic.
    // Bumps the dirty epoch, which downstream stages re-bump.
    fn countDirtyChunks(self: *NavGraph, world: *const WorldSystem, edits: []const NavCellEdit, cell_edits: []const types.ChangedSpan) usize {
        const epoch = self.bumpDirtyEpoch();
        const ct: usize = self.chunk_tiles;
        const cx_count = self.chunksX();
        var count: usize = 0;
        for (edits) |edit| {
            const level_grid = self.grid(edit.level) orelse continue;
            const span = level_grid.navSpanForTile(world, edit) orelse continue;
            count += self.countChangedSpanChunks(span, ct, cx_count, epoch);
        }
        for (cell_edits) |edit| {
            if (@as(usize, edit.level) >= self.levels.items.len) continue;
            count += self.countChangedSpanChunks(edit.span, ct, cx_count, epoch);
        }
        return count;
    }

    // Counts distinct not-yet-stamped chunks a span touches, stamping them along the way.
    // Shared helper for countDirtyChunks' tile-edit and entity-driven cell-edit passes.
    fn countChangedSpanChunks(self: *NavGraph, span: types.NavSpan, ct: usize, cx_count: usize, epoch: u32) usize {
        var count: usize = 0;
        var cy = span.min_y / ct;
        const cy1 = span.max_y / ct;
        while (cy <= cy1) : (cy += 1) {
            var cx = span.min_x / ct;
            const cx1 = span.max_x / ct;
            while (cx <= cx1) : (cx += 1) {
                const chunk: u32 = @intCast(cy * cx_count + cx);
                if (self.dirty_stamp.items[chunk] == epoch) continue;
                self.dirty_stamp.items[chunk] = epoch;
                count += 1;
            }
        }
        return count;
    }

    // For ONE level, re-derives the blocked mask (from the world, whole-chunk) and re-floods
    // the chunk-local components of every distinct chunk an edit's navSpanForTile rect touches.
    // Deduped via the dirty-chunk stamp so a multi-cell edit, a border-straddling rect, or
    // several edits sharing a chunk remask/re-flood it exactly once. Bounded by the edit
    // footprint's chunk set, not the level cell count. Reads the world whole-chunk so cells the
    // producer coalesced or dropped are still correct. The epoch bump is independent of
    // buildDirtySet's (called next per level), so the two never alias a stamp.
    fn remaskChangedChunks(self: *NavGraph, level: u16, data: *const DataSystem, world: *const WorldSystem, edits: []const NavCellEdit, cell_edits: []const types.ChangedSpan, full_level: bool, remask_threads: ?NavStageThreads) void {
        const world_system = world;
        const level_grid = &self.levels.items[level];
        const ct: usize = self.chunk_tiles;
        const cx_count = level_grid.chunksX();
        // Build the deduped changed-chunk work-list for this level.
        self.changed_chunks.clearRetainingCapacity();
        const epoch = self.bumpDirtyEpoch();
        if (full_level) {
            // Whole level dirty: remask + re-flood every chunk on the level.
            const total: u32 = @intCast(self.chunkCount());
            var chunk: u32 = 0;
            while (chunk < total) : (chunk += 1) {
                self.dirty_stamp.items[chunk] = epoch;
                self.changed_chunks.appendAssumeCapacity(chunk);
            }
        } else {
            for (edits) |edit| {
                if (edit.level != level) continue;
                const span = level_grid.navSpanForTile(world_system, edit) orelse continue;
                self.addChangedSpanChunks(span, ct, cx_count, epoch);
            }
            for (cell_edits) |edit| {
                if (edit.level != level) continue;
                self.addChangedSpanChunks(edit.span, ct, cx_count, epoch);
            }
        }

        // Remask-from-world + component re-flood for each changed chunk. Each chunk writes only
        // its own mask/component cells (disjoint), so this fans across workers; remaskChunkFromWorld
        // returns a blocked-count delta accumulated per worker (no shared counter write) and applied
        // once after the barrier.
        const chunks = self.changed_chunks.items;
        var delta: isize = 0;
        if (remask_threads) |threads| {
            const participants = threads.thread_system.participantSlotCount();
            if (chunks.len > 1 and participants <= self.remask_scratch.items.len) {
                for (self.remask_scratch.items) |*scratch| scratch.blocked_delta = 0;
                var job = NavRemaskJob{ .graph = self, .data = data, .world = world_system, .level = level, .chunks = chunks };
                self.last_remask_batch = threads.thread_system.parallelForWithOptions(chunks.len, &job, remaskChunkJob, .{
                    .adaptive = threads.adaptive,
                    .adaptive_tuner = threads.tuner,
                    .items_per_range = threads.items_per_range,
                    .range_alignment_items = 1,
                });
                for (self.remask_scratch.items) |*scratch| delta += scratch.blocked_delta;
                applyBlockedDelta(level_grid, delta);
                return;
            }
        }
        self.last_remask_batch = .{ .item_count = chunks.len, .ran_inline = true };
        const queue = &self.remask_scratch.items[0].queue;
        for (chunks) |chunk| {
            delta += level_grid.remaskChunkFromWorld(chunk, data, world_system);
            level_grid.recomputeChunkComponents(chunk, queue);
        }
        applyBlockedDelta(level_grid, delta);
    }

    // Marks every chunk a nav-cell span touches as changed (deduped via the epoch stamp),
    // WITHOUT border neighbors — remaskChangedChunks only re-derives the exact touched chunks
    // (neighbor chunks are patched, not remasked, by buildDirtySet/patchDirtyChunks). Shared by
    // the tile-edit and entity-driven cell-edit passes so both add chunks identically.
    fn addChangedSpanChunks(self: *NavGraph, span: types.NavSpan, ct: usize, cx_count: usize, epoch: u32) void {
        var cy = span.min_y / ct;
        const cy1 = span.max_y / ct;
        while (cy <= cy1) : (cy += 1) {
            var cx = span.min_x / ct;
            const cx1 = span.max_x / ct;
            while (cx <= cx1) : (cx += 1) {
                const chunk: u32 = @intCast(cy * cx_count + cx);
                if (self.dirty_stamp.items[chunk] == epoch) continue;
                self.dirty_stamp.items[chunk] = epoch;
                self.changed_chunks.appendAssumeCapacity(chunk);
            }
        }
    }

    // Applies a signed blocked-cell delta to a level grid's count after a (possibly threaded)
    // remask. The net count is always non-negative (a remask cannot unblock more than is blocked).
    fn applyBlockedDelta(level_grid: *NavGrid, delta: isize) void {
        const signed: isize = @as(isize, @intCast(level_grid.blocked_count)) + delta;
        // The summed per-worker deltas must keep blocked_count non-negative; a negative
        // net would mean a remask double-counted an unblock. Assert before the @intCast
        // would otherwise wrap into a huge usize.
        std.debug.assert(signed >= 0);
        level_grid.blocked_count = @intCast(signed);
    }

    // Nav cell index of the nav cell containing a world tile's origin corner.
    fn navCellIndexForTile(self: *const NavGraph, world: *const WorldSystem, edit: NavCellEdit) ?usize {
        const level_grid = self.grid(edit.level) orelse return null;
        const rect = world.cellRect(edit.x, edit.y) orelse return null;
        const cell = level_grid.worldToCellClamped(.{ .x = rect.x, .y = rect.y });
        return level_grid.indexForCell(cell);
    }

    // Chunk-tiling geometry for this graph; the shared source agreeing with every level's
    // NavGrid so the chunk_id<->cell mapping and label encode/decode cannot drift apart.
    fn chunkGeometry(self: *const NavGraph) types.ChunkGeometry {
        return .{ .width = self.width, .height = self.height, .chunk_tiles = self.chunk_tiles };
    }

    fn chunksX(self: *const NavGraph) usize {
        return self.chunkGeometry().chunksX();
    }

    fn chunksY(self: *const NavGraph) usize {
        return self.chunkGeometry().chunksY();
    }

    fn chunkOf(self: *const NavGraph, cell_index: usize) u32 {
        return self.chunkGeometry().chunkOf(cell_index);
    }

    fn chunkCount(self: *const NavGraph) usize {
        return self.chunksX() * self.chunksY();
    }

    // Chunk-local coordinate of a cell within its owning chunk.
    fn localOfCell(self: *const NavGraph, cell_index: usize) struct { x: usize, y: usize } {
        return .{ .x = (cell_index % self.width) % self.chunk_tiles, .y = (cell_index / self.width) % self.chunk_tiles };
    }

    fn isPerimeterCell(self: *const NavGraph, cell_index: usize) bool {
        const ct: usize = self.chunk_tiles;
        const lc = self.localOfCell(cell_index);
        return lc.x == 0 or lc.x == ct - 1 or lc.y == 0 or lc.y == ct - 1;
    }

    // Fixed bijection from a chunk's perimeter cells to [0, 4*ct): a canonical slot per
    // perimeter cell (corners resolved to a single edge), so a border cell's node id is a
    // pure function of its position and never moves for the life of the graph.
    fn perimeterSlot(self: *const NavGraph, cell_index: usize) u32 {
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
    fn slotForCell(self: *const NavGraph, cell_index: usize) u32 {
        const chunk = self.chunkOf(cell_index);
        const base = self.chunk_portal_base.items[chunk];
        if (self.isPerimeterCell(cell_index)) return base + self.perimeterSlot(cell_index);
        const ct: u32 = self.chunk_tiles;
        return base + 4 * ct + self.linkTailIndex(chunk, cell_index);
    }

    // Tail index of an interior link-endpoint cell within its chunk's link-cell run.
    fn linkTailIndex(self: *const NavGraph, chunk: u32, cell_index: usize) u32 {
        const lo = self.chunk_link_base.items[chunk];
        const len = self.chunk_link_count.items[chunk];
        const run = self.chunk_link_cells.items[lo .. lo + len];
        // slotForCell only reaches here for a non-perimeter portal cell that was already
        // admitted as a portal. Border cells (tryBorderPair) are perimeter; link endpoints are
        // gated by tryLinkPortal, which skips any interior cell absent from this run, so a miss
        // is an invariant violation (a Debug/ReleaseSafe panic; the invariant is covered by the
        // "runtime interior link endpoint is deferred" regression test) rather than a real path.
        const rel = std.sort.binarySearch(u32, run, @as(u32, @intCast(cell_index)), orderU32) orelse unreachable; // lint:allow catch-unreachable: interior portal cell provably present in run (see above)
        return @intCast(rel);
    }

    // Computes the chunk-stable slot geometry (portal caps/base/total_slots and the per-chunk
    // interior link-endpoint runs) from the current dimensions and the world's link set. Pure
    // geometry, independent of obstacles, so it is invariant across digs.
    fn computePortalGeometry(self: *NavGraph, world: ?*const WorldSystem) !void {
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
        // Endpoints were appended in discovery order; regroup them into per-chunk contiguous
        // sorted runs so an interior link endpoint maps to a stable tail slot.
        try self.groupLinkCellRuns(chunk_count);

        // Portal caps: 4*ct perimeter slots plus the chunk's interior link tail count.
        try setLen(&self.chunk_portal_cap, self.allocator, chunk_count);
        try setLen(&self.chunk_portal_base, self.allocator, chunk_count);
        var running: u32 = 0;
        for (0..chunk_count) |c| {
            self.chunk_portal_base.items[c] = running;
            const cap = 4 * ct + self.chunk_link_count.items[c];
            self.chunk_portal_cap.items[c] = cap;
            // Saturating, matching the edge-cap prefix sum: the memory-budget gate rejects
            // worlds anywhere near a u32 slot-count overflow, but keep the arithmetic loud
            // rather than silently wrapping if one ever slips through.
            running +|= cap;
        }
        self.total_slots = running;

        // Size the dirty-set scratch (bounded by chunk count) and per-chunk stamps.
        try self.dirty_set.ensureTotalCapacity(self.allocator, chunk_count);
        try self.changed_chunks.ensureTotalCapacity(self.allocator, chunk_count);
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

    fn recordLinkEndpoint(self: *NavGraph, x: u16, y: u16) !void {
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
    fn groupLinkCellRuns(self: *NavGraph, chunk_count: usize) !void {
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
    fn buildLevelInit(self: *NavGraph, level: u16, world: ?*const WorldSystem) !void {
        const lg = &self.level_graphs.items[level];
        @memset(lg.cell_to_portal.items, no_cell);
        @memset(lg.portals.items, .{ .level = level, .cell_index = no_cell, .chunk = 0 });
        @memset(lg.portal_edge_count.items, 0);
        @memset(lg.chunk_order_len.items, 0);
        @memset(lg.chunk_label_len.items, 0);
        lg.edge_scratch.clearRetainingCapacity();
        // The init build is serial (never threaded), so slot 0 is always the right — and
        // only — patch scratch to use here.
        const scratch = &self.patch_scratch.items[0];
        const chunk_count = self.chunkCount();
        var chunk: u32 = 0;
        while (chunk < chunk_count) : (chunk += 1) {
            scratch.edges.clearRetainingCapacity();
            try self.discoverChunkPortals(level, chunk, scratch);
            if (world) |world_system| self.addChunkLinkPortals(level, chunk, world_system);
            try self.connectChunkIntraEdges(level, chunk, scratch);
            self.orderChunkPortals(level, chunk);
            try lg.edge_scratch.appendSlice(self.allocator, scratch.edges.items);
        }
    }

    // Rebuilds the global live cross-level link edges (O(links)). A link is live only
    // when BOTH endpoint cells are open in their level masks. A live link references its
    // endpoints by CELL, resolved to portal nodes through the partner level's
    // cell_to_portal at search time, so it never depends on either level's node numbering
    // and a liveness toggle forces no per-level graph rebuild. Also rebuilds link_edge_refs,
    // the sorted (level, cell) index that lets abstractCorridor find incident links in
    // O(log(link_count)) rather than scanning the full link_edges slice per portal expansion.
    fn rebuildLinkEdges(self: *NavGraph, world: ?*const WorldSystem) !void {
        self.link_edges.clearRetainingCapacity();
        self.link_edge_refs.clearRetainingCapacity();
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
        // Build one ref entry per incident (level, cell) so abstractCorridor can range-lookup
        // without touching unrelated links. Bidirectional links get a second reverse entry.
        for (self.link_edges.items, 0..) |link, i| {
            try self.link_edge_refs.append(self.allocator, .{
                .level = link.from_level,
                .cell = link.from_cell,
                .index = @intCast(i),
                .reverse = false,
            });
            if (link.bidirectional) {
                try self.link_edge_refs.append(self.allocator, .{
                    .level = link.to_level,
                    .cell = link.to_cell,
                    .index = @intCast(i),
                    .reverse = true,
                });
            }
        }
        std.sort.pdq(LinkEdgeRef, self.link_edge_refs.items, {}, LinkEdgeRef.lessThan);
    }

    // Returns a persistent u32 scratch slice of `len`, growing the backing buffer only
    // when a build needs more than any prior build. The three abstract-graph build
    // helpers use this sequentially (never overlapping), so one buffer serves all.
    fn buildScratch(self: *NavGraph, len: usize) ![]u32 {
        try setLen(&self.build_u32_scratch, self.allocator, len);
        return self.build_u32_scratch.items;
    }

    // Per-chunk label stride matching NavGrid's chunk-local label encoding (one shared
    // definition in ChunkGeometry), so a chunk id can be recovered from one of its encoded
    // labels by integer division.
    fn labelStride(self: *const NavGraph) u64 {
        return self.chunkGeometry().labelStride();
    }

    // Returns the LIVE portal node slots on `level` owning chunk-local `component` (an
    // encoded label), a contiguous sub-run of the owning chunk's portal_order window, so
    // abstract seeding scans only the start chunk's local-component portals. The chunk is
    // recovered from the label; the chunk's small key run is binary-searched.
    pub fn levelComponentPortals(self: *const NavGraph, level: u16, component: u32) []const u32 {
        if (component == no_component) return &.{};
        const lg = self.levelGraph(level) orelse return &.{};
        const chunk: usize = @intCast(@as(u64, component) / self.labelStride());
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
    fn patchChunk(self: *NavGraph, level: u16, world: *const WorldSystem, chunk: u32, scratch: *ChunkPatchScratch) !bool {
        self.clearChunkSlots(level, chunk);
        scratch.edges.clearRetainingCapacity();
        try self.discoverChunkPortals(level, chunk, scratch);
        self.addChunkLinkPortals(level, chunk, world);
        try self.connectChunkIntraEdges(level, chunk, scratch);
        self.orderChunkPortals(level, chunk);
        return try self.compactChunkEdges(level, chunk, scratch);
    }

    // Tombstones a chunk's whole slot window and clears the cell_to_portal entries of the
    // cells it owned, so a patch starts from a clean chunk independent of its prior content.
    fn clearChunkSlots(self: *NavGraph, level: u16, chunk: u32) void {
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
    fn chunkBounds(self: *const NavGraph, chunk: u32) types.ChunkGeometry.Bounds {
        return self.chunkGeometry().chunkBounds(chunk);
    }

    // Scans one chunk's up-to-four INTERNAL borders, materializing one portal PER MAXIMAL
    // CONTIGUOUS OPEN RUN along each border (not one per open cell) — an open cell pair
    // that borders a blocked cell on the far side, or the chunk edge, closes a run. Two
    // cardinally-adjacent open cells are always the same chunk-local component by
    // construction of the flood, so a run is always one connected region: collapsing it to
    // one representative loses no reachability. This matters because unconsolidated
    // per-cell portals scale with BORDER LENGTH regardless of terrain — an open,
    // obstacle-free area is the WORST case (a wall only removes boundary cells from portal
    // candidacy), making the abstract chunk-portal search (solve.zig's abstractCorridor)
    // needlessly dense exactly where it should be cheapest. The reverse edge lives in the
    // neighbor chunk's window and is emitted when that chunk is patched (both source and
    // neighbor are always in the dirty set), so each shared transition edge is emitted
    // exactly once. Run selection must be a PURE FUNCTION of this border's blocked[]
    // pattern: both chunks sharing a border independently scan the identical physical
    // open/blocked pattern, so a deterministic rule (the run's midpoint) lands on the same
    // cell-pair from both sides without cross-chunk coordination — required for the
    // incremental-patch-matches-full-rebuild invariant this module is tested against.
    fn discoverChunkPortals(self: *NavGraph, level: u16, chunk: u32, scratch: *ChunkPatchScratch) !void {
        const lg = &self.level_graphs.items[level];
        const blocked = self.levels.items[level].blocked.items;
        const w = self.width;
        const b = self.chunkBounds(chunk);
        if (b.x0 > 0) {
            try self.discoverBorderRuns(lg, level, blocked, b.y0, b.y1, b.y0 * w + b.x0, w, -1, chunk, scratch);
        }
        if (b.x1 < w) {
            try self.discoverBorderRuns(lg, level, blocked, b.y0, b.y1, b.y0 * w + b.x1 - 1, w, 1, chunk, scratch);
        }
        if (b.y0 > 0) {
            try self.discoverBorderRuns(lg, level, blocked, b.x0, b.x1, b.y0 * w + b.x0, 1, -@as(isize, @intCast(w)), chunk, scratch);
        }
        if (b.y1 < self.height) {
            try self.discoverBorderRuns(lg, level, blocked, b.x0, b.x1, (b.y1 - 1) * w + b.x0, 1, @as(isize, @intCast(w)), chunk, scratch);
        }
    }

    // Scans loop indices [lo, hi) along one border line. `c_base`/`c_step` give this
    // chunk's border cell at a given index (c_cell = c_base + (index - lo) * c_step);
    // `n_offset` is the fixed signed offset from a c_cell to its neighbor-chunk mirror
    // (-1/+1 for a vertical border scanned by row, -w/+w for a horizontal border scanned
    // by column). Both cells open extends the current run; a block (or reaching `hi`)
    // closes it and materializes exactly one portal pair at the run's midpoint.
    fn discoverBorderRuns(
        self: *NavGraph,
        lg: *NavLevelGraph,
        level: u16,
        blocked: []const bool,
        lo: usize,
        hi: usize,
        c_base: usize,
        c_step: usize,
        n_offset: isize,
        chunk: u32,
        scratch: *ChunkPatchScratch,
    ) !void {
        var run_start: ?usize = null;
        var i: usize = lo;
        while (i < hi) : (i += 1) {
            const c_cell = c_base + (i - lo) * c_step;
            const n_cell: usize = @intCast(@as(isize, @intCast(c_cell)) + n_offset);
            if (!blocked[c_cell] and !blocked[n_cell]) {
                if (run_start == null) run_start = i;
            } else if (run_start) |start| {
                try self.emitBorderRunPortal(lg, level, c_base, c_step, n_offset, lo, start, i, chunk, scratch);
                run_start = null;
            }
        }
        if (run_start) |start| {
            try self.emitBorderRunPortal(lg, level, c_base, c_step, n_offset, lo, start, hi, chunk, scratch);
        }
    }

    // Materializes the single portal pair representing an open run [run_start, run_end),
    // at its midpoint (floor-biased toward the start on an even-length run) — deterministic
    // given only the run's own bounds, so both chunks sharing this border compute the same
    // representative independently.
    fn emitBorderRunPortal(
        self: *NavGraph,
        lg: *NavLevelGraph,
        level: u16,
        c_base: usize,
        c_step: usize,
        n_offset: isize,
        lo: usize,
        run_start: usize,
        run_end: usize,
        chunk: u32,
        scratch: *ChunkPatchScratch,
    ) !void {
        const mid = run_start + (run_end - run_start) / 2;
        const c_cell = c_base + (mid - lo) * c_step;
        const n_cell: usize = @intCast(@as(isize, @intCast(c_cell)) + n_offset);
        self.addPortalCell(lg, level, c_cell, chunk);
        try scratch.edges.append(self.allocator, .{
            .from = self.slotForCell(c_cell),
            .edge = .{ .target = self.slotForCell(n_cell), .cost = cardinal_cost },
        });
    }

    // Marks a cell live at its geometric slot. Idempotent: a corner cell touched by two of
    // its chunk's borders keeps a single node.
    fn addPortalCell(self: *NavGraph, lg: *NavLevelGraph, level: u16, cell_index: usize, chunk: u32) void {
        if (lg.cell_to_portal.items[cell_index] != no_cell) return;
        const slot = self.slotForCell(cell_index);
        lg.portals.items[slot] = .{ .level = level, .cell_index = @intCast(cell_index), .chunk = chunk };
        lg.cell_to_portal.items[cell_index] = slot;
    }

    // Adds this chunk's open link-endpoint cells (on this level) as portals so the intra-chunk
    // pass can connect them to their chunk-local-component peers. Liveness of the cross-level
    // link itself is decided later in rebuildLinkEdges; membership depends only on this level.
    fn addChunkLinkPortals(self: *NavGraph, level: u16, chunk: u32, world: *const WorldSystem) void {
        const lg = &self.level_graphs.items[level];
        const level_grid = &self.levels.items[level];
        for (world.levelLinks()) |link| {
            if (link.level_a == level) self.tryLinkPortal(lg, level_grid, link.cell_a.x, link.cell_a.y, chunk);
            if (link.level_b == level) self.tryLinkPortal(lg, level_grid, link.cell_b.x, link.cell_b.y, chunk);
        }
    }

    fn tryLinkPortal(self: *NavGraph, lg: *NavLevelGraph, level_grid: *const NavGrid, x: u16, y: u16, chunk: u32) void {
        const cell = level_grid.indexForCell(.{ .x = x, .y = y }) orelse return;
        if (self.chunkOf(cell) != chunk or level_grid.blocked.items[cell]) return;
        // The per-chunk interior link-endpoint runs (and thus the interior slot space) are built
        // once at init from the init-time link set (computePortalGeometry); the whole-world build
        // is init-only. A link added at RUNTIME (dig_controller.digRamp) whose INTERIOR endpoint
        // was not in that set has no reserved slot, so it stays out of the abstract tier: skip it
        // (no portal, no cross-level edge — exactly as a blocked endpoint) rather than resolving
        // against an absent run. Perimeter endpoints keep their positional slot and are added
        // incrementally as normal. The deferred interior endpoint is picked up by the next full
        // rebuild; cross-level NPC pathing is not active, so this changes no live query.
        if (!self.isPerimeterCell(cell) and !self.interiorLinkSlotExists(chunk, cell)) return;
        self.addPortalCell(lg, level_grid.level, cell, chunk);
    }

    // Whether an interior cell has a reserved slot in its chunk's init-built link-endpoint run.
    // Guards tryLinkPortal so a runtime-added interior endpoint is deferred instead of reaching
    // linkTailIndex's `orelse unreachable` against a run it was never recorded in.
    fn interiorLinkSlotExists(self: *const NavGraph, chunk: u32, cell_index: usize) bool {
        const lo = self.chunk_link_base.items[chunk];
        const len = self.chunk_link_count.items[chunk];
        const run = self.chunk_link_cells.items[lo .. lo + len];
        return std.sort.binarySearch(u32, run, @as(u32, @intCast(cell_index)), orderU32) != null;
    }

    // Connects this chunk's live same-chunk-component portals pairwise with octile cost. Both
    // endpoints share the chunk so both directions land in this chunk's edge window.
    fn connectChunkIntraEdges(self: *NavGraph, level: u16, chunk: u32, scratch: *ChunkPatchScratch) !void {
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
                try scratch.edges.append(self.allocator, .{ .from = i, .edge = .{ .target = j, .cost = cost } });
                try scratch.edges.append(self.allocator, .{ .from = j, .edge = .{ .target = i, .cost = cost } });
            }
        }
    }

    // Writes this chunk's live slots into its portal_order window sorted by (chunk-local
    // label, cell) and builds the chunk's compact label sub-index. Labels of one chunk are
    // disjoint from every other chunk's, so no cross-chunk ordering is needed.
    fn orderChunkPortals(self: *NavGraph, level: u16, chunk: u32) void {
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
    fn compactChunkEdges(self: *NavGraph, level: u16, chunk: u32, scratch: *ChunkPatchScratch) !bool {
        const lg = &self.level_graphs.items[level];
        const pbase = self.chunk_portal_base.items[chunk];
        const pcap = self.chunk_portal_cap.items[chunk];
        const ebase = self.chunk_edge_base.items[chunk];
        const ecap = self.chunk_edge_cap.items[chunk];
        var slot = pbase;
        while (slot < pbase + pcap) : (slot += 1) lg.portal_edge_count.items[slot] = 0;
        for (scratch.edges.items) |entry| lg.portal_edge_count.items[entry.from] += 1;
        var running = ebase;
        slot = pbase;
        while (slot < pbase + pcap) : (slot += 1) {
            lg.portal_edge_start.items[slot] = running;
            running += lg.portal_edge_count.items[slot];
        }
        if (running - ebase > ecap) {
            // The counts above claim adjacency that was never written into portal_edges (this
            // chunk's window still holds whatever the last successful build/patch left there).
            // The caller always follows an overflow with a full buildAbstractGraphs rebuild, but
            // that rebuild can itself fail (OOM) before reaching this chunk, and a failed `try`
            // leaves the graph object exactly as it stands right now. Re-zero the counts so a
            // reader in that window sees empty (not dangling/stale) adjacency for this chunk
            // instead of a CSR range whose content was never refreshed for the new topology.
            // Also pin each slot's start back to ebase: the prefix sum above walked `running`
            // past ebase+ecap, so a later slot's start can exceed portal_edges.len; a reader
            // slices [start, start+count). With count re-zeroed, start must stay in-bounds or
            // that empty slice traps (Debug/ReleaseSafe) / is UB (ReleaseFast). ebase is the
            // chunk's window base, always < len, so [ebase, ebase) is a safe empty slice.
            var zero_slot = pbase;
            while (zero_slot < pbase + pcap) : (zero_slot += 1) {
                lg.portal_edge_count.items[zero_slot] = 0;
                lg.portal_edge_start.items[zero_slot] = ebase;
            }
            return true;
        }
        // Per-slot write cursor (indexed window-relative) seeded at each slot's edge start. Uses
        // this worker's own cursor buffer so parallel chunk patches never share writable state.
        try setLen(&scratch.cursor, self.allocator, pcap);
        const cursor = scratch.cursor.items;
        var i: u32 = 0;
        while (i < pcap) : (i += 1) cursor[i] = lg.portal_edge_start.items[pbase + i];
        for (scratch.edges.items) |entry| {
            const dst = cursor[entry.from - pbase];
            lg.portal_edges.items[dst] = entry.edge;
            cursor[entry.from - pbase] = dst + 1;
        }
        return false;
    }

    // Drains a fully-built level's edge_scratch (all chunks) into the edge arena, grouped by
    // source slot within each chunk's window. Used only by the full build, where caps were
    // measured to fit, so it cannot overflow.
    fn placeLevelEdges(self: *NavGraph, level: u16) !void {
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
    fn computeEdgeCaps(self: *NavGraph) !void {
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
    fn portalIndex(self: *const NavGraph, level: u16, cell_index: u32) ?u32 {
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
const PortalComponentSort = struct {
    portals: []const PortalNode,
    components: []const u32,

    fn lessThan(self: PortalComponentSort, lhs: u32, rhs: u32) bool {
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
const EntityId = @import("../../data_system.zig").EntityId;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const test_support = @import("test_support.zig");
const abstractCapacity = test_support.abstractCapacity;
const baselineCapacity = test_support.baselineCapacity;
const addNavBody = test_support.addNavBody;
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

test "regression: destroying a static body and remasking leaves its cell correctly open (coverage-cache staleness)" {
    // NavGrid.markStaticBodies rasterizes a per-cell static-body coverage cache
    // (static_blocked) only when the WHOLE graph rebuilds. Before the fix, neither the
    // whole-level-dirty path nor the incremental patch ever refreshed that cache, so
    // staticBodyCoversNavCell's O(1) fast path kept reporting a destroyed/moved body's old
    // cells as covered forever after the first rebuild. This spawns a static body, destroys
    // it, and remasks via the whole-level-dirty path (markNavLevelDirty), asserting the
    // vacated cell is correctly open — this would fail (stay blocked) without the
    // refreshStaticCoverageSpan calls in NavGraph.applyNavUpdates.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());

    const entity = try addNavBody(&data, .{ .x = 100, .y = 100 }, .{ .x = 16, .y = 16 }, true);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);

    const cell = system.graph.grid(0).?.worldToCellClamped(.{ .x = 100, .y = 100 });
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(cell));

    _ = data.destroyEntity(entity);
    try system.markNavLevelDirty(0);
    _ = try system.applyBufferedNavUpdates(&data, &world, null);

    try std.testing.expect(!system.graph.grid(0).?.isBlockedCell(cell));
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);

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
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "threaded initial nav build matches a serial build across levels" {
    // navLevelMaskJob (the threaded per-level world-mask/component-build fan-out
    // in NavGraph.rebuild) only fires when the initial build is given both a real
    // ThreadSystem and more than one level. Every other rebuildStaticNavGridWithWorld
    // call in this file passes thread_system=null, so without this test that path
    // has zero coverage: a serial/threaded divergence there would ship undetected.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();
    try world.addUndergroundLevels(&meta);
    try std.testing.expect(world.levelCount() > 1);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();

    var threaded = PathfindingSystem.init(std.testing.allocator);
    defer threaded.deinit();
    try threaded.reserve(cap);
    try threaded.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, &threads);

    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    try serial.reserve(cap);
    try serial.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);

    try expectGraphsEquivalent(&threaded.graph, &serial.graph);
}

test "whole-level dirty re-derives the level from the world and matches a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 12x12 open world, 4-tile chunks (abstractCapacity) -> a 3x3 chunk grid.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    const obstacle_layer = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    // Block a cell far from chunk (0,0) WITHOUT recording it as an individual dirty cell.
    // A cell-less reaction (markNavLevelDirty, used for entity-driven obstacle changes whose
    // footprint is no longer resolvable) must still pick it up via the whole-level remask.
    const far = (try world.setDenseTile(obstacle_layer, 10, 10, tree)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u16, 0), far.level);
    try system.markNavLevelDirty(0);
    const stats = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // A whole-level remask keeps nav_version stable (no topology rebuild).
    try std.testing.expectEqual(@as(usize, 0), stats.version_bumps);

    // The far cell is blocked even though it was never marked as an individual dirty cell —
    // the old sentinel-cell reaction only remasked chunk (0,0) and would have missed it.
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 10, .y = 10 }));

    // Byte-identical to a full rebuild against the same post-edit world.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

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
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental nav update on a chunk border flips a neighbor chunk's portal" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 12x12 world, 4-tile chunks. The vertical border at x=4 spans y=4..7 for chunk row 1;
    // (3,4)/(3,6)/(3,7) start blocked so (3,5)|(4,5) is the border's ONLY open cell pair —
    // an isolated 1-cell run, so it is unambiguously the run's own representative portal
    // under discoverChunkPortals' run consolidation (see that function's doc comment),
    // rather than depending on which cell a multi-cell run's midpoint happens to land on.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    const isolation_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    for ([_]u16{ 4, 6, 7 }) |wy| {
        _ = try world.setDenseTile(isolation_layer, 3, wy, tree);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    const grid = system.graph.grid(0).?;
    const near = grid.indexForCell(.{ .x = 3, .y = 5 }).?; // chunk (0,1), the edited side
    const neighbor = grid.indexForCell(.{ .x = 4, .y = 5 }).?; // chunk (1,1)
    try std.testing.expect(system.graph.portalIndex(0, @intCast(near)) != null);
    try std.testing.expect(system.graph.portalIndex(0, @intCast(neighbor)) != null);
    const neighbor_label_before = grid.componentOf(neighbor);

    // Block (3,5) on the chunk (0,1) side: the (3,5)|(4,5) portal pair disappears, so
    // the NEIGHBOR chunk (1,1)'s portal at (4,5) flips off even though only chunk (0,1)
    // is relabeled.
    const changed = (try world.setDenseTile(isolation_layer, 3, 5, tree)) orelse return error.TestExpectedEqual;
    _ = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    try std.testing.expect(system.graph.portalIndex(0, @intCast(near)) == null);
    try std.testing.expect(system.graph.portalIndex(0, @intCast(neighbor)) == null);
    // The neighbor chunk's component labels were NOT recomputed: (4,5) keeps its label.
    try std.testing.expectEqual(neighbor_label_before, grid.componentOf(neighbor));

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

// Regression guard for discoverChunkPortals' run consolidation: an open chunk border must
// yield ONE portal per contiguous open run, not one per open cell — an obstacle-free area
// is the WORST case for portal density under the old per-cell scheme (a wall only ever
// removes boundary cells from candidacy), which made the abstract chunk-portal search
// needlessly expensive exactly where it should be cheapest (see discoverChunkPortals'
// doc comment). A fully-interior chunk with all four borders open has at most one live
// portal per side (4), never one per open boundary cell (up to chunk_tiles per side).
test "a fully-open interior chunk yields at most one portal per border side, not one per open cell" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // 12x12 open world, 4-tile chunks: a 3x3 chunk grid whose CENTER chunk (1,1) is the
    // only one with all four sides internal (bordering another chunk on every side).
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGrid(&data, 384, 384, 32);

    const chunk_tiles = system.capacity.nav_chunk_tiles;
    const chunks_per_side = 3;
    const center_chunk: u32 = 1 * chunks_per_side + 1;
    const pbase = system.graph.chunk_portal_base.items[center_chunk];
    const pcap = system.graph.chunk_portal_cap.items[center_chunk];
    var live_count: usize = 0;
    for (system.graph.level_graphs.items[0].portals.items[pbase .. pbase + pcap]) |portal| {
        if (portal.cell_index != no_cell) live_count += 1;
    }
    // One border-consolidated portal per side (4), well under one per open boundary cell
    // per side on all four sides (up to chunk_tiles * 4) that the pre-consolidation scheme
    // would have produced for a fully-open chunk.
    try std.testing.expect(live_count <= 4);
    try std.testing.expect(live_count < @as(usize, chunk_tiles) * 4);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
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
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "runtime interior link endpoint is deferred by the incremental patch, then slotted by a full rebuild" {
    // dig_controller.digRamp adds a LevelLink AFTER the init geometry build. The abstract slot
    // geometry is init-only, so a runtime interior endpoint has no reserved slot: the incremental
    // patch must DEFER it (no portal, no cross-level edge), not resolve against an absent run
    // (linkTailIndex unreachable). The next full rebuild reserves the slot.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 4-tile chunks (abstractCapacity): cell (2,2) is interior to chunk (0,0); (3,2) is a
    // diggable perimeter neighbor in the same chunk that triggers the chunk's incremental patch.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    const level1_obstacle = try world.addDenseLayer(1, 0, .obstacle, grass);
    _ = try world.setDenseTile(level1_obstacle, 3, 2, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const endpoint: u32 = @intCast(system.graph.grid(1).?.indexForCell(.{ .x = 2, .y = 2 }).?);
    try std.testing.expect(system.graph.portalIndex(1, endpoint) == null); // no link yet

    // Runtime link whose interior endpoint (2,2) was never in the init slot geometry.
    try world.addLevelLink(.{
        .kind = .ramp,
        .level_a = 1,
        .cell_a = .{ .x = 2, .y = 2 },
        .level_b = 0,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 1,
        .bidirectional = true,
    });

    // Dig the neighbor open: drives the incremental patch over chunk (0,0). Must NOT panic.
    const changed = (try world.setDenseTile(level1_obstacle, 3, 2, grass)) orelse return error.TestExpectedEqual;
    _ = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    // Deferred: the interior endpoint is NOT slotted as a portal. The walkability-keyed
    // link_edge still exists, but it is inert — the abstract solver skips any link whose
    // endpoint resolves to no_cell in cell_to_portal (solve.zig), so it is never traversed.
    try std.testing.expect(system.graph.portalIndex(1, endpoint) == null);

    // A fresh full rebuild WITH the link present at init reserves the interior slot.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    try std.testing.expect(rebuilt.graph.portalIndex(1, endpoint) != null);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

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
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    const changed = (try world.setDenseTile(level1_obstacle, 5, 5, grass)) orelse return error.TestExpectedEqual;
    _ = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    // The slot layout is pure geometry and liveness a pure function of the (identical) mask,
    // so portals[] and cell_to_portal[] on the CHANGED level are byte-identical to a fresh
    // full rebuild even though the edge windows (per-chunk slack) are not.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

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
    try second.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

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
    // Border-run consolidation (nav_graph.zig's discoverChunkPortals) means a solidly-open
    // chunk now yields only a handful of portals (one per contiguous open run per border
    // side), not one per open cell, so opening this whole world no longer produces enough
    // edges on its own to exceed chunk_edge_floor. Force the overflow directly instead —
    // the same technique "compactChunkEdges zeroes the chunk's edge counts on overflow..."
    // already uses below — so this test exercises the actual overflow->fallback->rebuild
    // response through the real applyNavUpdates entry point, independent of how many edges
    // a given portal scheme happens to produce for this geometry.
    for (system.graph.chunk_edge_cap.items) |*cap| cap.* = 0;
    const stats = try system.applyNavUpdates(&data, &world, edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 1), stats.edge_cap_fallback);

    // The fallback still produces a graph equivalent to an independent full rebuild.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "compactChunkEdges zeroes the chunk's edge counts on overflow instead of leaving them dangling" {
    // Isolates compactChunkEdges from the caller's always-follows-with-a-full-rebuild
    // convention: an overflow must leave the chunk's OWN CSR self-consistent (empty
    // adjacency) even if nothing else runs afterward (e.g. the fallback rebuild OOMs).
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);

    const chunk: u32 = 0;
    const pbase = system.graph.chunk_portal_base.items[chunk];
    const pcap = system.graph.chunk_portal_cap.items[chunk];
    // Sanity: the init build gave this chunk real edges to lose on a forced overflow.
    var had_edges = false;
    for (system.graph.level_graphs.items[0].portal_edge_count.items[pbase .. pbase + pcap]) |count| {
        if (count != 0) had_edges = true;
    }
    try std.testing.expect(had_edges);

    // Force overflow: shrink this chunk's edge window below any possible edge count.
    system.graph.chunk_edge_cap.items[chunk] = 0;
    const overflowed = try system.graph.patchChunk(0, &world, chunk, &system.graph.patch_scratch.items[0]);
    try std.testing.expect(overflowed);

    // The chunk's counts must be zero (empty adjacency), not stale/dangling into whatever
    // patchChunk's clearChunkSlots + re-discovery left in portal_edges for this window.
    for (system.graph.level_graphs.items[0].portal_edge_count.items[pbase .. pbase + pcap]) |count| {
        try std.testing.expectEqual(@as(u32, 0), count);
    }
}

test "compactChunkEdges keeps portal_edge_start in-bounds for the last chunk on overflow" {
    // The last chunk's edge window ends exactly at portal_edges.len, so an overflow whose
    // prefix sum climbs `running` past ebase+ecap leaves a later slot's start beyond the
    // buffer. With counts re-zeroed but start left stale, a reader slicing
    // [start, start+count) traps (Debug/ReleaseSafe) / is UB (ReleaseFast). Pinning start
    // back to ebase keeps every count-0 slot's slice a safe in-bounds empty range.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);

    const lg = &system.graph.level_graphs.items[0];
    const chunk: u32 = @intCast(system.graph.chunkCount() - 1);
    const pbase = system.graph.chunk_portal_base.items[chunk];
    const pcap = system.graph.chunk_portal_cap.items[chunk];
    const ebase = system.graph.chunk_edge_base.items[chunk];
    const ecap = system.graph.chunk_edge_cap.items[chunk];
    // Precondition for the OOB: this chunk's window ends at the very end of the arena, and
    // it has at least two slots so a later slot's start can climb past the buffer.
    try std.testing.expectEqual(system.graph.total_edge_slots, ebase + ecap);
    try std.testing.expect(pcap >= 2);

    // Synthesize a transient edge list that overflows the window: ecap+4 edges all on the
    // chunk's first slot, so the prefix sum pushes every later slot's start past the arena.
    const scratch = &system.graph.patch_scratch.items[0];
    scratch.edges.clearRetainingCapacity();
    var e: u32 = 0;
    while (e < ecap + 4) : (e += 1) {
        try scratch.edges.append(system.graph.allocator, .{ .from = pbase, .edge = .{ .target = 0, .cost = 1 } });
    }

    const overflowed = try system.graph.compactChunkEdges(0, chunk, scratch);
    try std.testing.expect(overflowed);

    // Every slot must yield an in-bounds empty CSR slice — reading it must not trap.
    const edges_len = lg.portal_edges.items.len;
    var slot = pbase;
    while (slot < pbase + pcap) : (slot += 1) {
        const begin = lg.portal_edge_start.items[slot];
        const count = lg.portal_edge_count.items[slot];
        try std.testing.expectEqual(@as(u32, 0), count);
        try std.testing.expect(begin <= edges_len);
        try std.testing.expectEqual(@as(usize, 0), lg.portal_edges.items[begin .. begin + count].len);
    }
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
        try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

        // Cell (5,5) sits in chunk (1,1) (4-tile chunks): interior for both worlds.
        const changed = (try world.setDenseTile(obstacle, 5, 5, tree)) orelse return error.TestExpectedEqual;
        const stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
        patched[i] = stats.chunks_patched;
    }
    try std.testing.expectEqual(@as(usize, 5), patched[0]);
    try std.testing.expectEqual(patched[0], patched[1]);
}

test "incremental nav update across distant chunks in one batch matches a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 512 extent at cell_size 32 is 16 nav cells/side; with 4-tile chunks that is a 4x4 chunk
    // grid, so the two digs below land in opposite-corner chunks with clear space between them.
    const extent: f32 = 512;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    // Two digs in opposite-corner chunks applied as ONE batch. The whole-chunk remask-from-world
    // must reach BOTH distant chunks; a producer that dropped either (or a per-cell remask that
    // missed a coalesced cell) would leave that chunk stale, so the incremental graph must equal
    // a fresh full rebuild against the same world.
    const cells = [_]struct { x: u16, y: u16 }{ .{ .x = 1, .y = 1 }, .{ .x = 13, .y = 13 } };
    var edits: [cells.len]NavCellEdit = undefined;
    for (cells, 0..) |cell, i| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        edits[i] = .{ .level = 0, .x = cell.x, .y = cell.y };
    }
    _ = try system.applyNavUpdates(&data, &world, &edits);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(abstractCapacity());
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    const inc = system.graph.levelGraph(0).?;
    const full = rebuilt.graph.levelGraph(0).?;
    try std.testing.expectEqualSlices(PortalNode, full.portals.items, inc.portals.items);
    try std.testing.expectEqualSlices(u32, full.cell_to_portal.items, inc.cell_to_portal.items);
    // Both distant chunks ended blocked in the incremental graph's mask (no dropped cell).
    const nav = system.graph.grid(0).?;
    for (cells) |cell| try std.testing.expect(nav.isBlockedCell(.{ .x = @intCast(cell.x), .y = @intCast(cell.y) }));
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental nav update forced-parallel remask and patch match a serial full rebuild" {
    // The adaptive tuner usually runs a small dig inline, so the threaded remask/patch branches go
    // unexercised. This pins both: forcing adaptive=false with items_per_range=1 over a multi-chunk
    // dig drives the parallel path (asserted via ran_inline == false for BOTH stages), and the
    // disjoint-window result must still be byte-identical to a fresh serial full rebuild.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);
    // Force the parallel schedule rather than letting the tuner keep the small batch inline.
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;

    // Five cells in five distinct nav_chunk_tiles=4 chunks, so both the remask changed-chunk set
    // and the patch dirty set exceed one chunk and actually fan out.
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    for (cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try system.markNavDirty(0, cell.x, cell.y);
    }
    _ = try system.applyBufferedNavUpdates(&data, &world, &threads);

    // Both stages must have actually threaded, not fallen back to the inline slot-0 path.
    try std.testing.expect(!system.graph.last_remask_batch.ran_inline);
    try std.testing.expect(!system.graph.last_patch_batch.ran_inline);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(cap);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    const inc = system.graph.levelGraph(0).?;
    const full = rebuilt.graph.levelGraph(0).?;
    try std.testing.expectEqualSlices(PortalNode, full.portals.items, inc.portals.items);
    try std.testing.expectEqualSlices(u32, full.cell_to_portal.items, inc.cell_to_portal.items);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "incremental nav update threaded chunk patch matches a serial full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    // Dig several chunks (each corner plus the center) in one batch, applied through the
    // THREADED buffered path. Each chunk patches disjoint slot/edge windows with its own worker
    // scratch slot, so the threaded result must be byte-identical to a fresh serial full rebuild.
    // (The adaptive tuner may run this small batch inline; patchChunkJob runs either way, and
    // parity holds by the disjoint-window design regardless of how it is scheduled.)
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    for (cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try system.markNavDirty(0, cell.x, cell.y);
    }
    _ = try system.applyBufferedNavUpdates(&data, &world, &threads);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(cap);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    const inc = system.graph.levelGraph(0).?;
    const full = rebuilt.graph.levelGraph(0).?;
    try std.testing.expectEqualSlices(PortalNode, full.portals.items, inc.portals.items);
    try std.testing.expectEqualSlices(u32, full.cell_to_portal.items, inc.cell_to_portal.items);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "entity obstacle create/destroy patches a constant chunk set independent of world size and matches a full rebuild" {
    // Mirrors "incremental single-chunk dig patches a constant chunk set independent of world
    // size" but for an entity-driven obstacle rect resolved through markNavObstacleRectDirty
    // instead of a tile edit, proving the same chunk-bounded localization for entities.
    const extents = [_]f32{ 512, 1024 };
    var patched: [extents.len]usize = undefined;
    for (extents, 0..) |extent, i| {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var meta = try loadTestWorldMeta(std.testing.allocator);
        defer meta.deinit();

        var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
        defer world.deinit();

        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());
        try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

        // Cell (5,5) sits in chunk (1,1) (4-tile chunks): interior for both worlds.
        const entity = try addNavBody(&data, .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 }, true);
        const rect = data.staticObstacleWorldRect(entity).?;
        try system.markNavObstacleRectDirty(0, rect);
        const create_stats = try system.applyBufferedNavUpdates(&data, &world, null);
        patched[i] = create_stats.chunks_patched;

        var rebuilt_created = PathfindingSystem.init(std.testing.allocator);
        defer rebuilt_created.deinit();
        try rebuilt_created.reserve(abstractCapacity());
        try rebuilt_created.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);
        try expectGraphsEquivalent(&system.graph, &rebuilt_created.graph);

        _ = data.destroyEntity(entity);
        try system.markNavObstacleRectDirty(0, rect);
        _ = try system.applyBufferedNavUpdates(&data, &world, null);

        var rebuilt_destroyed = PathfindingSystem.init(std.testing.allocator);
        defer rebuilt_destroyed.deinit();
        try rebuilt_destroyed.reserve(abstractCapacity());
        try rebuilt_destroyed.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);
        try expectGraphsEquivalent(&system.graph, &rebuilt_destroyed.graph);
    }
    try std.testing.expectEqual(@as(usize, 5), patched[0]);
    try std.testing.expectEqual(patched[0], patched[1]);
}

test "entity obstacle move marks both old and new spans dirty at a distance-independent patch cost" {
    // Moves a static obstacle corner-to-corner in one batch (two markNavObstacleRectDirty
    // calls: old rect then new rect — never a bounding box spanning both). A corner chunk
    // has exactly two orthogonal neighbors (self + 2), so each span patches 3 chunks; the two
    // spans never share a chunk once the grid is at least 3 chunks wide, so the total (6) is
    // identical regardless of how far apart the corners are in world units.
    const extents = [_]f32{ 512, 1024 };
    var patched: [extents.len]usize = undefined;
    for (extents, 0..) |extent, i| {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var meta = try loadTestWorldMeta(std.testing.allocator);
        defer meta.deinit();

        var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
        defer world.deinit();

        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());

        const entity = try addNavBody(&data, .{ .x = 8, .y = 8 }, .{ .x = 8, .y = 8 }, true);
        try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);
        const old_rect = data.staticObstacleWorldRect(entity).?;
        const old_cell = system.graph.grid(0).?.worldToCellClamped(.{ .x = 8, .y = 8 });
        try std.testing.expect(system.graph.grid(0).?.isBlockedCell(old_cell));

        const cells_side: u16 = @intFromFloat(extent / 32.0);
        const far_coord: f32 = @as(f32, @floatFromInt(cells_side - 1)) * 32.0 + 8.0;
        const body = data.movementBodyPtr(entity).?;
        body.position_x.* = far_coord;
        body.position_y.* = far_coord;
        body.previous_x.* = far_coord;
        body.previous_y.* = far_coord;
        const new_rect = data.staticObstacleWorldRect(entity).?;
        const new_cell = system.graph.grid(0).?.worldToCellClamped(.{ .x = far_coord, .y = far_coord });

        try system.markNavObstacleRectDirty(0, old_rect);
        try system.markNavObstacleRectDirty(0, new_rect);
        const stats = try system.applyBufferedNavUpdates(&data, &world, null);
        patched[i] = stats.chunks_patched;

        try std.testing.expect(!system.graph.grid(0).?.isBlockedCell(old_cell));
        try std.testing.expect(system.graph.grid(0).?.isBlockedCell(new_cell));

        var rebuilt = PathfindingSystem.init(std.testing.allocator);
        defer rebuilt.deinit();
        try rebuilt.reserve(abstractCapacity());
        try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);
        try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
    }
    try std.testing.expectEqual(@as(usize, 6), patched[0]);
    try std.testing.expectEqual(patched[0], patched[1]);
}

test "overlapping static bodies: destroying one leaves the shared cell blocked by the survivor" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());

    // Two static bodies fully overlapping the same cell.
    const a = try addNavBody(&data, .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 }, true);
    const b = try addNavBody(&data, .{ .x = 162, .y = 162 }, .{ .x = 8, .y = 8 }, true);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);

    const cell = system.graph.grid(0).?.worldToCellClamped(.{ .x = 160, .y = 160 });
    try std.testing.expectEqual(cell, system.graph.grid(0).?.worldToCellClamped(.{ .x = 162, .y = 162 }));
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(cell));

    // Destroy body `a`; `b` still covers the shared cell, so it must stay blocked (proving
    // refreshStaticCoverageSpan re-derives from the CURRENT live body set, not a blind toggle).
    const rect_a = data.staticObstacleWorldRect(a).?;
    _ = data.destroyEntity(a);
    try system.markNavObstacleRectDirty(0, rect_a);
    _ = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(cell));

    // Destroying the survivor `b` too finally opens the cell.
    const rect_b = data.staticObstacleWorldRect(b).?;
    _ = data.destroyEntity(b);
    try system.markNavObstacleRectDirty(0, rect_b);
    _ = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expect(!system.graph.grid(0).?.isBlockedCell(cell));
}

test "static-to-dynamic-to-static toggle blocks and unblocks in place without moving" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());

    const entity = try addNavBody(&data, .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 }, true);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);
    const cell = system.graph.grid(0).?.worldToCellClamped(.{ .x = 160, .y = 160 });
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(cell));

    // Toggle static -> dynamic in place: old rect == new rect; only the "old" side fires
    // (the entity is no longer a static obstacle, so there is no new-side rect to block).
    const rect = data.staticObstacleWorldRect(entity).?;
    try data.setCollisionResponse(entity, .{ .mobility = .dynamic });
    try system.markNavObstacleRectDirty(0, rect);
    _ = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expect(!system.graph.grid(0).?.isBlockedCell(cell));

    // Toggle back dynamic -> static in place: only the "new" side fires.
    try data.setCollisionResponse(entity, .{ .mobility = .static });
    const new_rect = data.staticObstacleWorldRect(entity).?;
    try std.testing.expectEqual(rect, new_rect);
    try system.markNavObstacleRectDirty(0, new_rect);
    _ = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(cell));
}

test "incremental nav update threaded chunk patch matches a serial full rebuild with an entity-obstacle cell edit" {
    // Extends the threaded tile-edit parity test with a cell_edits-sourced entry (an
    // entity-driven obstacle destroy) folded into the SAME threaded batch, proving the
    // cell_edits path through NavGraph.applyNavUpdates/buildDirtySet/remaskChangedChunks
    // matches a serial full rebuild exactly like the tile-edit path already does.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);

    // A static body present at build time, destroyed as part of the same threaded batch below.
    const entity = try addNavBody(&data, .{ .x = 224, .y = 224 }, .{ .x = 8, .y = 8 }, true);
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
    };
    for (cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try system.markNavDirty(0, cell.x, cell.y);
    }
    const rect = data.staticObstacleWorldRect(entity).?;
    _ = data.destroyEntity(entity);
    try system.markNavObstacleRectDirty(0, rect);
    _ = try system.applyBufferedNavUpdates(&data, &world, &threads);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(cap);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

test "entity-obstacle rect nav update is allocation-free at steady state" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    const extent: f32 = 512;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    // Warmup: one entity-obstacle create+destroy churn through the real
    // markNavObstacleRectDirty + applyBufferedNavUpdates path, so every buffer it touches
    // (nav_dirty_cell_spans, dirty_set/dirty_stamp, patch/remask scratch) reaches steady-state
    // capacity before the failing-allocator proof below.
    {
        const entity = try addNavBody(&data, .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 }, true);
        const rect = data.staticObstacleWorldRect(entity).?;
        try system.markNavObstacleRectDirty(0, rect);
        _ = try system.applyBufferedNavUpdates(&data, &world, null);
        _ = data.destroyEntity(entity);
        try system.markNavObstacleRectDirty(0, rect);
        _ = try system.applyBufferedNavUpdates(&data, &world, null);
    }

    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    const entity = try addNavBody(&data, .{ .x = 320, .y = 320 }, .{ .x = 8, .y = 8 }, true);
    const rect = data.staticObstacleWorldRect(entity).?;
    try system.markNavObstacleRectDirty(0, rect);
    const stats = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);

    system.graph.allocator = original;
    system.allocator = original;
}

test "threaded multi-worker chunk patch/remask is allocation-free at steady state (FailingAllocator)" {
    // The serial slot-0 proof above swaps in a failing allocator with thread_system=null,
    // so the worker append (scratch.edges.append / setLen on worker threads at
    // remaskChangedChunks/patchChunkJob) is only ever proven allocation-free on the inline
    // slot-0 path. This drives the SAME failing-allocator proof through a REAL multi-worker
    // ThreadSystem so the reserve-before-dispatch invariant (patch/remask scratch sized to
    // the participant count) is proven on the path that actually fans out to worker threads.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);
    // Force the parallel schedule rather than letting the tuner keep the small batch inline,
    // so the proof exercises the worker-thread append, not the serial slot-0 fallback.
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;

    // Five cells in five distinct nav_chunk_tiles=4 chunks, so both the remask changed-chunk
    // set and the patch dirty set exceed one chunk and actually fan out to workers.
    const warm_cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    // A distinct cell in each of the SAME five chunks, dug during the failing-allocator proof
    // below. Same per-chunk/per-worker footprint as the warmup, so no buffer grows.
    const proof_cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 2, .y = 2 },  .{ .x = 14, .y = 1 },
        .{ .x = 2, .y = 14 }, .{ .x = 14, .y = 14 },
        .{ .x = 6, .y = 6 },
    };

    // Warmup: toggle the warm cells on then off through the THREADED path, so every buffer the
    // threaded remask/patch touches (dirty_set/dirty_stamp, changed spans, per-participant patch
    // and remask scratch) reaches steady-state capacity before the failing-allocator proof.
    for ([_]@TypeOf(tree){ tree, grass }) |tile| {
        for (warm_cells) |cell| {
            _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tile)) orelse return error.TestExpectedEqual;
            try system.markNavDirty(0, cell.x, cell.y);
        }
        const warm_stats = try system.applyBufferedNavUpdates(&data, &world, &threads);
        try std.testing.expectEqual(@as(usize, 1), warm_stats.incremental_rebuilds);
        // The warmup itself must have threaded (not fallen back inline), or it would not have
        // grown the per-participant worker scratch the proof relies on.
        try std.testing.expect(!system.graph.last_remask_batch.ran_inline);
        try std.testing.expect(!system.graph.last_patch_batch.ran_inline);
    }

    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    for (proof_cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try system.markNavDirty(0, cell.x, cell.y);
    }
    const stats = try system.applyBufferedNavUpdates(&data, &world, &threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // Both stages threaded under the failing allocator: the worker append allocated zero times.
    try std.testing.expect(!system.graph.last_remask_batch.ran_inline);
    try std.testing.expect(!system.graph.last_patch_batch.ran_inline);

    system.graph.allocator = original;
    system.allocator = original;
}

// Commits a single set_movement_body structural command through `frame` (real
// structural-commit -> event pipeline, mirroring how the game state drives it) and
// applies it, so the produced component_changed event carries real
// old/new_obstacle_world_rect fields resolved from DataSystem, not a hand-built event.
fn commitMovedStaticObstacle(frame: *SimulationFrame, data: *DataSystem, entity: EntityId, position: math.Vec2) !void {
    frame.beginStep();
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, 1);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    writer.write(.{ .set_movement_body = .{
        .entity = entity,
        .body = .{ .position = position, .previous_position = position },
    } });
    writer.finish();
    frame.structural_commands.finishWrite();
    _ = try frame.applyStructuralCommands(data);
}

test "reactToPostCommitNavEvents appends both old and new obstacle spans for one moved static obstacle, allocation-free at steady state (FailingAllocator)" {
    // The steady-state test above only ever exercises ONE markNavObstacleRectDirty append
    // per applyBufferedNavUpdates call (a create, then a destroy), called directly rather
    // than through reactToPostCommitNavEvents. reactToPostCommitNavEvents's component_changed
    // handling appends up to TWO spans per event -- old_obstacle_world_rect and
    // new_obstacle_world_rect -- whenever a moving entity stays a static nav obstacle across
    // the change, so this drives that real 2-appends-in-one-batch case through the actual
    // structural-commit -> event -> react pipeline.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    const extent: f32 = 512;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());

    const entity = try addNavBody(&data, .{ .x = 160, .y = 160 }, .{ .x = 8, .y = 8 }, true);
    try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();

    // Warmup: move the obstacle once through the real pipeline (2 appends in one batch)
    // so nav_dirty_cell_spans reaches its real steady-state high-water mark, along with
    // every other buffer reactToPostCommitNavEvents touches, before the failing-allocator
    // proof below.
    try commitMovedStaticObstacle(&frame, &data, entity, .{ .x = 224, .y = 224 });
    const warmup_stats = try system.reactToPostCommitNavEvents(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), warmup_stats.incremental_rebuilds);

    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    // Move it again: a second single-batch, 2-append occurrence must not allocate.
    try commitMovedStaticObstacle(&frame, &data, entity, .{ .x = 64, .y = 64 });
    const stats = try system.reactToPostCommitNavEvents(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);

    system.graph.allocator = original;
    system.allocator = original;
}
