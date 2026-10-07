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
const LevelLink = @import("../../world_system.zig").LevelLink;
const CellCoord = @import("../../world_system.zig").CellCoord;
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
const nav_interior_link_slots_per_chunk = types.nav_interior_link_slots_per_chunk;
const no_cell = types.no_cell;
const no_component = types.no_component;
const cardinal_cost = types.cardinal_cost;
const inter_level_penalty = types.inter_level_penalty;
const PathQueryKey = types.PathQueryKey;
const NavGridError = types.NavGridError;
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
// Cache-line separation for per-worker scratch slots, same policy as collision.zig,
// simulation_scope.zig and spatial_index.zig.
const thread_shared_record_alignment: usize = 64;

// Per-worker scratch for one chunk patch: the chunk's transient edge list (filled by
// discover/intra, drained into the chunk's fixed edge window) and the compaction cursor.
// One slot per threaded participant so chunk patches run in parallel without sharing
// writable state; the serial path uses slot 0. Both buffers are per-chunk transient,
// cleared at the start of each patch. Distinct from NavLevelGraph.edge_scratch, which the
// init full build reuses to accumulate a whole level's edges.
// align(thread_shared_record_alignment) on `edges` forces @alignOf(ChunkPatchScratch)==64 and
// rounds @sizeOf up to a multiple of 64, so adjacent worker slots never share a cache line and
// workers patching chunks in parallel see no false sharing. The slot is 64 B in
// ReleaseFast/ReleaseSmall and 128 B in Debug/ReleaseSafe: since Zig 0.17 each std.ArrayList
// carries a runtime-safety lock field that is zero-sized only when runtime safety is off.
const ChunkPatchScratch = struct {
    edges: std.ArrayList(NavLevelGraph.EdgeScratch) align(thread_shared_record_alignment) = .empty,
    cursor: std.ArrayList(u32) = .empty,

    comptime {
        std.debug.assert(@alignOf(ChunkPatchScratch) == thread_shared_record_alignment);
        std.debug.assert(@sizeOf(ChunkPatchScratch) % thread_shared_record_alignment == 0);
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
// align(thread_shared_record_alignment) on `queue` forces @alignOf(ChunkRemaskScratch)==64 and
// rounds @sizeOf up to a multiple of 64, so adjacent worker slots never share a cache line and
// workers accumulating blocked_delta in parallel see no false sharing. The slot is 64 B in
// every mode today (the 0.17 ArrayList runtime-safety lock still fits in one line here); the
// assert pins the multiple-of-64 invariant rather than one exact size.
const ChunkRemaskScratch = struct {
    queue: std.ArrayList(usize) align(thread_shared_record_alignment) = .empty,
    blocked_delta: isize = 0,

    comptime {
        std.debug.assert(@alignOf(ChunkRemaskScratch) == thread_shared_record_alignment);
        std.debug.assert(@sizeOf(ChunkRemaskScratch) % thread_shared_record_alignment == 0);
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
    range_count: usize,
};

fn patchChunkJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *NavPatchJob = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig): range.index vs
    // dispatched range count AND range.end vs the chunk buffer this job walks.
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.chunks.len);
    // Guards the reserve-before-dispatch invariant: patch_scratch was sized to the
    // participant count that patchDirtyChunks checked before dispatching this batch.
    std.debug.assert(worker_id.index < job.graph.patch_scratch.items.len);
    const scratch = &job.graph.patch_scratch.items[worker_id.index];
    for (range.start..range.end) |i| {
        const chunk = job.chunks[i];
        // Each chunk is patched by exactly one worker, so its flag slot is a disjoint write
        // (sized at the build, before any dispatch). Any patchChunk error (today only OOM) sets
        // the same flag as a genuine edge-window overflow: the post-barrier serial pass re-patches
        // the chunk, which either grows its window or surfaces the error from the main thread.
        const overflowed = job.graph.patchChunk(job.level, job.world, chunk, scratch) catch true;
        if (overflowed) job.graph.chunk_edge_overflow.items[chunk] = true;
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
    range_count: usize,
};

fn remaskChunkJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *NavRemaskJob = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig): range.index vs
    // dispatched range count AND range.end vs the chunk buffer this job walks.
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.chunks.len);
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
    range_count: usize,
};

fn navLevelMaskJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *NavLevelMaskJob = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig): range.index vs
    // dispatched range count AND range.end vs the level grid buffer this job walks.
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.graph.levels.items.len);
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
    // Failures of one chunk's patch or edge-window growth: an allocation, or a growth the nav
    // memory gate refuses (relocateChunkEdgeWindow).
    const ChunkPatchError = std.mem.Allocator.Error || NavGridError;

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
    // lives on NavGraph, not per level). chunk_portal_cap[D] = 4*ct +
    // nav_interior_link_slots_per_chunk for EVERY chunk (a pure function of the dimensions,
    // never of the link set); chunk_portal_base is its exclusive prefix-sum; total_slots
    // their sum.
    chunk_portal_cap: std.ArrayList(u32) = .empty,
    chunk_portal_base: std.ArrayList(u32) = .empty,
    total_slots: u32 = 0,
    // Per-chunk edge windows (shared by every level): a full build sets cap =
    // max-across-levels measured edge count * default_edge_slack (with a floor), base its
    // exclusive prefix-sum, total_edge_slots their sum. A chunk's edge count is a function of
    // its live topology (quadratic in same-component portals: border runs, dug openings, and
    // runtime ramp endpoints), so an incremental patch that outgrows a window relocates just
    // that chunk's window to the arena tail (growChunkEdgeWindow) instead of rebuilding the
    // graph; the old window becomes an unreferenced hole (edge_hole_slots) until the arena is
    // compacted (compactEdgeArena) or the next full build re-measures it.
    // Sizing every window for the layout maximum instead (all 4*ct-4 perimeter cells + K link
    // endpoints in one component, ~4.6k edges at ct = 16) would cost ~37 KB per chunk-level,
    // ~300 MB for a 256x256x32 world, against ~2 MB measured.
    chunk_edge_cap: std.ArrayList(u32) = .empty,
    chunk_edge_base: std.ArrayList(u32) = .empty,
    total_edge_slots: u32 = 0,
    // Arena slots vacated by window relocations and referenced by no window: the same count in
    // every level's arena (windows are shared). total_edge_slots - edge_hole_slots is the slots
    // live windows own (edgeArenaLiveSlots), the quantity the nav memory gate charges. Zeroed by
    // a full build and by compactEdgeArena (run by a growth that reaches the nav memory gate). Each relocation adds its old cap here and more than that to
    // the live windows (growth at least doubles), so holes never exceed live slots: the arena
    // is at most about 2x its live windows. applyNavUpdates asserts that invariant.
    edge_hole_slots: u32 = 0,
    // Per-level edge-arena slot ceiling from the nav memory gate the graph was last admitted
    // under (NavMemoryBudget.edgeArenaSlotLimit, set at every full build and on re-admission),
    // charged against the arena's live slots (edgeArenaLiveSlots), never its physical capacity.
    // A window growth past it compacts first and otherwise fails loudly (NavWorldTooLarge,
    // edge_growth_refused_total, one count per refused chunk; the rest of the dirty set is still
    // patched), so in-place growth never allocates past max_nav_memory_bytes.
    edge_arena_slot_limit: u32 = std.math.maxInt(u32),
    // Lifetime diagnostics: arena compactions run, and window growths the gate refused.
    edge_compactions_total: u64 = 0,
    edge_growth_refused_total: u64 = 0,
    // Per-chunk "outgrew its edge window this patch" flags, sized at every full build (before
    // any dispatch). The threaded patch writes only its own chunks' slots (disjoint); the
    // post-barrier serial pass in patchDirtyChunks reads and clears them.
    chunk_edge_overflow: std.ArrayList(bool) = .empty,
    // Fixed-stride table of interior link-endpoint cells (deduped by cell across all levels):
    // chunk D's run is chunk_link_cells[D*K .. D*K + chunk_link_count[D]) with
    // K = nav_interior_link_slots_per_chunk, in assignment (link) order; unused entries hold
    // no_cell. An interior endpoint's index within its run is its stable slot offset past the
    // chunk's 4*ct perimeter slots. Sized at every full build; the runtime link cursor
    // (assignLinkEndpointSlots) only fills entries, never reallocates.
    chunk_link_cells: std.ArrayList(u32) = .empty,
    chunk_link_count: std.ArrayList(u32) = .empty,
    // Unslotted link endpoints counted by the most recent full slot assignment
    // (computePortalGeometry). Diagnostic only; the incremental cursor reports its own count
    // through NavUpdateStats.link_endpoints_unslotted.
    full_build_link_endpoints_unslotted: usize = 0,
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
        self.chunk_link_cells.deinit(self.allocator);
        self.chunk_edge_overflow.deinit(self.allocator);
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
        self.edge_arena_slot_limit = memory_budget.edgeArenaSlotLimit(self.width, self.height);

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
                    // Pre-select so the job context can dual-assert range.index against
                    // the dispatched range count (mirror affect.zig / collision.zig).
                    const selection = threads.selectBatchProfile(null, .{
                        .item_count = prepared_level_count,
                        .items_per_range = 1,
                        .range_alignment_items = 1,
                        .adaptive = false,
                    });
                    var mask_job = NavLevelMaskJob{
                        .graph = self,
                        .world = world,
                        .range_count = selection.range_count,
                    };
                    _ = threads.parallelForWithOptions(prepared_level_count, &mask_job, navLevelMaskJob, .{
                        .items_per_range = 1,
                        .range_alignment_items = 1,
                        .adaptive = false,
                        .selected_profile = selection.profile,
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

        try self.buildAbstractGraphs(world);
        // Reserve the global link edges for the world's reserved link limit (which the memory
        // gate above admitted), so runtime links within it never grow them.
        if (world) |world_system| try self.reserveLinkEdges(world_system.levelLinkLimit());
        try self.rebuildLinkEdges(world);

        // Pre-reserve each slot's edge buffer and compaction cursor so a patch — serial OR
        // threaded — never reallocates, including the overflow path that is detected only AFTER
        // a chunk's full transient edge list is built. The transient list is bounded by a chunk's
        // border edges (<= pcap) plus its same-component intra pairs (<= pcap*(pcap-1)), i.e.
        // pcap^2; reserving that keeps a worker-thread append allocation-free even when a chunk's
        // edges exceed its compaction window (which the serial post-barrier pass then grows).
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
    // the current masks/components. Used by the init rebuild and by a full relabel; it
    // re-measures per-chunk edge caps from the current topology (compacting any windows an
    // incremental patch relocated), so it never overflows. A measured arena past the nav memory
    // gate fails (computeEdgeCaps) before any edge-layout write.
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
    // `version` bumps only on a full relabel (stats.version_bumps), the one path that
    // rebuilds every level and makes every goal-keyed entry re-solve; an edge-window growth
    // stays on the incremental path and keeps `version`. `affected_levels` is caller-owned pre-reserved
    // scratch (sized to level count), but this function grows/frees it with `self.allocator`
    // (the graph's own), not a caller-supplied one — the caller MUST deinit it with the
    // same allocator instance passed to this NavGraph, or the alloc/free pair mismatches.
    // PathfindingSystem satisfies this because it constructs itself and its NavGraph from
    // one shared allocator.
    //
    // Allocation contract: allocation-free at steady state — the abstract buffers are reused
    // at the prior build's high-water capacity, and the slot/order arrays are geometrically
    // sized so they never grow on a dig. The only growth is a chunk outgrowing its edge window
    // (a dig or runtime ramp adding same-component portals), which relocates that one chunk's
    // window to the arena tail at slack * its new edge count (growChunkEdgeWindow); each
    // level's edge arena grows geometrically up to the nav memory gate's ceiling, so most
    // relocations fit the existing capacity. Holes the relocations leave stay below the live
    // window slots (growth at least doubles); a growth past the gate compacts them in place (no
    // allocation) first, then fails loudly; a failed step still patches every dirty chunk of
    // the failing level (the refused chunk keeps live portals with empty adjacency, so no edge
    // targets a tombstone), and later affected levels keep their old, self-consistent mask and
    // abstract layer until the retry. That is acceptable per
    // coding-standards.md allocation exceptions: a
    // cold, event-triggered main-thread step (after the patch barrier) with NavGraph as the
    // explicit owner, whose cost cannot move to init because the topology is only known when
    // the edit arrives, and sizing every window for the layout maximum costs ~150x the memory
    // (see chunk_edge_cap). The growth never changes the result: the graph equals a full
    // rebuild either way, and the step stays an incremental patch.
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
            const compactions_before = self.edge_compactions_total;
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
                stats.edge_windows_grown += try self.patchDirtyChunks(level, world, patch_threads);
            }
            // Compactions run only inside a growth that reached the nav memory gate.
            stats.edge_compactions = @intCast(self.edge_compactions_total - compactions_before);
            // Holes never exceed the slots live windows own, so the arena needs no compaction
            // trigger of its own: every relocation adds its old cap to the holes and a new cap
            // of max(2 * needed, floor) > 2 * old cap to the live windows (relocateChunkEdgeWindow),
            // and a full build or compaction zeroes the holes.
            std.debug.assert(self.edge_hole_slots <= self.edgeArenaLiveSlots());
            // Every seam that sets or spends the ceiling keeps the live slots within it: the
            // build, an admitted relocation, and an admitted re-admission (edgeArenaFitsBudget).
            std.debug.assert(self.edgeArenaLiveSlots() <= self.edge_arena_slot_limit);
        }
        try self.rebuildLinkEdges(world);

        // Incremental patch (window growth included) keeps nav_version stable (caller
        // scope-evicts only crossing paths); a full relabel bumps it to invalidate all
        // goal-keyed work.
        if (stats.full_relabel != 0) {
            self.version +%= 1;
            if (self.version == 0) self.version = 1;
            stats.version_bumps = 1;
        }

        stats.incremental_rebuilds = 1;
        return stats;
    }

    // Patches the current self.dirty_set for one level, serial or threaded. Threaded only when a
    // patch context is present, there is more than one chunk, and the live participant count fits
    // the pre-sized scratch slots; otherwise serial (slot 0). Returns how many chunk edge windows
    // grew. A chunk that outgrows its window is grown and re-patched on the main thread
    // (growChunkEdgeWindow): inline on the serial path, and on the threaded path by a serial
    // pass after the barrier over the flagged chunks, so no edge arena ever reallocates under a
    // worker. Both paths grow in dirty-set order, so the relocated layout is identical either
    // way. parallelForWithOptions is a barrier, so self.dirty_set stays stable across the batch
    // and the next level's buildDirtySet runs only after it completes.
    //
    // Failure policy (both paths): every chunk of the dirty set is patched (and grown where it
    // overflowed) even after a growth fails; the first error is returned after the loop. A
    // chunk whose growth failed keeps the live portals buildChunkPatch rebuilt, with empty
    // adjacency, and every other dirty chunk is patched against them, so no CSR edge targets a
    // tombstoned slot: stopping at the failed chunk would leave its orthogonal neighbors' edges
    // pointing at border-run slots that patch just tombstoned. The serial and threaded failure
    // layouts are identical, and the retry re-patches the whole dirty set.
    fn patchDirtyChunks(self: *NavGraph, level: u16, world: *const WorldSystem, patch_threads: ?NavStageThreads) ChunkPatchError!usize {
        const chunks = self.dirty_set.items;
        if (patch_threads) |threads| {
            const participants = threads.thread_system.participantSlotCount();
            if (chunks.len > 1 and participants <= self.patch_scratch.items.len) {
                // Pre-select so the job context can dual-assert range.index against
                // the dispatched range count (mirror affect.zig / collision.zig).
                const selection = threads.thread_system.selectBatchProfile(threads.tuner, .{
                    .item_count = chunks.len,
                    .items_per_range = threads.items_per_range,
                    .range_alignment_items = 1,
                    .adaptive = threads.adaptive,
                });
                var job = NavPatchJob{
                    .graph = self,
                    .world = world,
                    .level = level,
                    .chunks = chunks,
                    .range_count = selection.range_count,
                };
                self.last_patch_batch = threads.thread_system.parallelForWithOptions(chunks.len, &job, patchChunkJob, .{
                    .adaptive = threads.adaptive,
                    .adaptive_tuner = selection.active_tuner,
                    .items_per_range = threads.items_per_range,
                    .range_alignment_items = 1,
                    .selected_profile = selection.profile,
                });
                // Visits (and clears) every flag of the batch even past a failed growth, so no
                // stale flag survives into a later patch (the retry re-patches the dirty set).
                var grown: usize = 0;
                var first_error: ?ChunkPatchError = null;
                for (chunks) |chunk| {
                    if (!self.chunk_edge_overflow.items[chunk]) continue;
                    self.chunk_edge_overflow.items[chunk] = false;
                    const grew = self.growChunkEdgeWindow(level, world, chunk, &self.patch_scratch.items[0]) catch |err| {
                        if (first_error == null) first_error = err;
                        continue;
                    };
                    if (grew) grown += 1;
                }
                if (first_error) |err| return err;
                return grown;
            }
        }
        self.last_patch_batch = .{ .item_count = chunks.len, .ran_inline = true };
        var grown: usize = 0;
        var first_error: ?ChunkPatchError = null;
        const scratch = &self.patch_scratch.items[0];
        for (chunks) |chunk| {
            // Same policy as patchChunkJob: any patch error routes through the main-thread
            // re-patch below, which either grows the window or surfaces the error.
            const overflowed = self.patchChunk(level, world, chunk, scratch) catch true;
            if (!overflowed) continue;
            const grew = self.growChunkEdgeWindow(level, world, chunk, scratch) catch |err| {
                if (first_error == null) first_error = err;
                continue;
            };
            if (grew) grown += 1;
        }
        if (first_error) |err| return err;
        return grown;
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
                // Pre-select so the job context can dual-assert range.index against
                // the dispatched range count (mirror affect.zig / collision.zig).
                const selection = threads.thread_system.selectBatchProfile(threads.tuner, .{
                    .item_count = chunks.len,
                    .items_per_range = threads.items_per_range,
                    .range_alignment_items = 1,
                    .adaptive = threads.adaptive,
                });
                var job = NavRemaskJob{
                    .graph = self,
                    .data = data,
                    .world = world_system,
                    .level = level,
                    .chunks = chunks,
                    .range_count = selection.range_count,
                };
                self.last_remask_batch = threads.thread_system.parallelForWithOptions(chunks.len, &job, remaskChunkJob, .{
                    .adaptive = threads.adaptive,
                    .adaptive_tuner = selection.active_tuner,
                    .items_per_range = threads.items_per_range,
                    .range_alignment_items = 1,
                    .selected_profile = selection.profile,
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
        // net would mean a remask double-counted an unblock. Saturate to 0 before
        // @intCast — never wrap a negative isize into a huge usize (ReleaseFast would
        // otherwise make that wrap silent UB-adjacent corruption of the count).
        if (signed < 0) {
            level_grid.blocked_count = 0;
            return;
        }
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
        const lc = self.localOfCell(cell_index);
        return isPerimeterLocal(lc.x, lc.y, self.chunk_tiles);
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

    // Chunk D's assigned interior link-endpoint run (at most K entries, link order).
    fn chunkLinkRun(self: *const NavGraph, chunk: u32) []const u32 {
        const lo = @as(usize, chunk) * nav_interior_link_slots_per_chunk;
        return self.chunk_link_cells.items[lo .. lo + self.chunk_link_count.items[chunk]];
    }

    // Tail index of an interior link-endpoint cell within its chunk's link-cell run: a linear
    // scan of at most nav_interior_link_slots_per_chunk entries.
    fn linkTailIndex(self: *const NavGraph, chunk: u32, cell_index: usize) u32 {
        const run = self.chunkLinkRun(chunk);
        // slotForCell only reaches here for a non-perimeter portal cell that was already
        // admitted as a portal. Border cells (tryBorderPair) are perimeter; link endpoints are
        // gated by tryLinkPortal, which skips any interior cell absent from this run (an
        // endpoint left unslotted by the K cap, or one a deferred link cursor has not reached),
        // so a miss is an invariant violation (a Debug/ReleaseSafe panic; covered by the "ninth
        // authored interior link endpoint ... stays unslotted" test) rather than a real path.
        const rel = std.mem.indexOfScalar(u32, run, @as(u32, @intCast(cell_index))) orelse unreachable; // lint:allow catch-unreachable: interior portal cell provably present in run (see above)
        return @intCast(rel);
    }

    // Computes the chunk-stable slot geometry (portal caps/base/total_slots and the fixed-stride
    // per-chunk interior link-endpoint table) from the current dimensions, then assigns the
    // world's whole link set into the table from index 0. The slot layout is a pure function of
    // the dimensions (never of the link set), so the incremental link cursor and a full build
    // share one layout and adding a link never renumbers a slot.
    fn computePortalGeometry(self: *NavGraph, world: ?*const WorldSystem) !void {
        const cell_count = self.cellCount();
        std.debug.assert(cell_count < no_cell);
        const chunk_count = self.chunkCount();
        const ct: u32 = self.chunk_tiles;

        // Fixed-stride interior link-endpoint table: K entries per chunk, empty = no_cell.
        try setLen(&self.chunk_link_count, self.allocator, chunk_count);
        try setLen(&self.chunk_link_cells, self.allocator, chunk_count * nav_interior_link_slots_per_chunk);
        @memset(self.chunk_link_count.items, 0);
        @memset(self.chunk_link_cells.items, no_cell);
        self.full_build_link_endpoints_unslotted = if (world) |world_system|
            self.assignLinkEndpointSlots(world_system.levelLinks(), 0, .full_build)
        else
            0;

        // Portal caps: 4*ct perimeter slots plus the fixed K interior link slots, every chunk.
        try setLen(&self.chunk_portal_cap, self.allocator, chunk_count);
        try setLen(&self.chunk_portal_base, self.allocator, chunk_count);
        var running: u32 = 0;
        for (0..chunk_count) |c| {
            self.chunk_portal_base.items[c] = running;
            const cap = 4 * ct + nav_interior_link_slots_per_chunk;
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

    // Who is assigning link-endpoint slots: a full build (count only) or the incremental link
    // cursor (count, and warn once for a newly unslotted endpoint).
    pub const LinkSlotAssignSource = enum { full_build, cursor };

    // The single slot-assignment rule shared by the full build and the incremental link cursor.
    // Visits `links[first..]` in link order (endpoint a, then b when it is a different cell): an
    // interior endpoint cell already in its chunk's run is skipped; otherwise it is appended at
    // tail index chunk_link_count[D] while the run holds fewer than K entries; otherwise it stays
    // UNSLOTTED (inert, exactly like a blocked endpoint). Links are append-only, so processing
    // new links from a cursor yields exactly the table a full build computes from index 0, and
    // an existing endpoint never loses its slot. Returns the unslotted endpoint cells visited.
    // Allocation-free (the table is sized at the full build); main thread, before any dispatch.
    pub fn assignLinkEndpointSlots(self: *NavGraph, links: []const LevelLink, first: usize, source: LinkSlotAssignSource) usize {
        var unslotted: usize = 0;
        for (links[first..], first..) |link, link_index| {
            if (!self.assignLinkEndpointCell(link.cell_a)) {
                unslotted += 1;
                self.warnUnslottedLinkEndpoint(source, link_index, link.cell_a);
            }
            if (link.cell_b.x == link.cell_a.x and link.cell_b.y == link.cell_a.y) continue;
            if (!self.assignLinkEndpointCell(link.cell_b)) {
                unslotted += 1;
                self.warnUnslottedLinkEndpoint(source, link_index, link.cell_b);
            }
        }
        return unslotted;
    }

    // Assigns one endpoint cell per the shared rule. Returns false only when the cell is an
    // interior cell absent from its chunk's run and the run is full (unslotted). Perimeter and
    // out-of-grid endpoints need no interior slot.
    fn assignLinkEndpointCell(self: *NavGraph, coord: CellCoord) bool {
        const cell = self.levels.items[0].indexForCell(.{ .x = coord.x, .y = coord.y }) orelse return true;
        if (self.isPerimeterCell(cell)) return true; // perimeter endpoints reuse their perimeter slot
        const chunk = self.chunkOf(cell);
        if (self.interiorLinkSlotExists(chunk, cell)) return true;
        const count = self.chunk_link_count.items[chunk];
        if (count >= nav_interior_link_slots_per_chunk) return false;
        self.chunk_link_cells.items[@as(usize, chunk) * nav_interior_link_slots_per_chunk + count] = @intCast(cell);
        self.chunk_link_count.items[chunk] = count + 1;
        return true;
    }

    // Recovered degradation: a NEW link endpoint (first assigned by the incremental cursor)
    // found its chunk's fixed interior slots full and stays inert. Full builds only count, so a
    // world with one unslotted authored link warns once per session, not once per rebuild. Cold
    // (per new link, never per step), main thread; kept out of test builds, which author this
    // case on purpose.
    fn warnUnslottedLinkEndpoint(self: *const NavGraph, source: LinkSlotAssignSource, link_index: usize, coord: CellCoord) void {
        if (source != .cursor) return;
        if (comptime logging.enabled(.warn) and !builtin.is_test) {
            const cell = self.levels.items[0].indexForCell(.{ .x = coord.x, .y = coord.y }) orelse return;
            logging.game.warn("nav chunk {d} interior link slots full ({d}); link {d} endpoint ({d},{d}) stays inert", .{ self.chunkOf(cell), nav_interior_link_slots_per_chunk, link_index, coord.x, coord.y });
        }
    }

    // The slot geometry a link producer needs to predict assignment (see
    // interiorLinkSlotsAvailable). Valid after any full build.
    pub fn linkSlotGeometry(self: *const NavGraph) NavLinkSlotGeometry {
        // An unbuilt graph has no slot geometry: report the sentinel so a producer fails loud
        // (UnresolvedNavLinkGeometry) instead of predicting against default dimensions.
        if (!self.valid()) return .unresolved;
        return .{ .chunk_tiles = self.chunk_tiles, .width = @intCast(self.width), .height = @intCast(self.height) };
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

    // Grow-only reserve of the global link edges for `link_limit` world links (one edge and
    // up to two refs per link). Called by the full build and, through
    // `PathfindingSystem.reserveLinkCapacity`, by the dig commit seam's link growth.
    pub fn reserveLinkEdges(self: *NavGraph, link_limit: usize) !void {
        try self.link_edges.ensureTotalCapacity(self.allocator, link_limit);
        try self.link_edge_refs.ensureTotalCapacity(self.allocator, 2 * link_limit);
    }

    // Rebuilds the global live cross-level link edges (O(links)). A link is live only
    // when BOTH endpoint cells are open in their level masks. A live link references its
    // endpoints by CELL, resolved to portal nodes through the partner level's
    // cell_to_portal at search time, so it never depends on either level's node numbering
    // and a liveness toggle forces no per-level graph rebuild. Also rebuilds link_edge_refs,
    // the sorted (level, cell) index that lets abstractCorridor find incident links in
    // O(log(link_count)) rather than scanning the full link_edges slice per portal expansion.
    //
    // Allocation: the full build reserves both arrays to the world's reserved link limit
    // (`WorldSystem.levelLinkLimit`, the same count the nav memory gate admits), and the dig
    // commit seam's link growth re-reserves them (`reserveLinkEdges`) before the world's limit
    // rises, so a runtime link never grows them here. The ensure below is only the safety net
    // for a direct authoring add (links added without `reserveLevelLinks`).
    fn rebuildLinkEdges(self: *NavGraph, world: ?*const WorldSystem) !void {
        self.link_edges.clearRetainingCapacity();
        self.link_edge_refs.clearRetainingCapacity();
        const world_system = world orelse return;
        const link_count = world_system.levelLinks().len;
        try self.link_edges.ensureTotalCapacity(self.allocator, link_count);
        try self.link_edge_refs.ensureTotalCapacity(self.allocator, 2 * link_count);
        for (world_system.levelLinks()) |link| {
            if (@as(usize, link.level_a) >= self.levels.items.len) continue;
            if (@as(usize, link.level_b) >= self.levels.items.len) continue;
            const grid_a = &self.levels.items[link.level_a];
            const grid_b = &self.levels.items[link.level_b];
            const cell_a = grid_a.indexForCell(.{ .x = link.cell_a.x, .y = link.cell_a.y }) orelse continue;
            const cell_b = grid_b.indexForCell(.{ .x = link.cell_b.x, .y = link.cell_b.y }) orelse continue;
            if (grid_a.blocked.items[cell_a] or grid_b.blocked.items[cell_b]) continue;
            self.link_edges.appendAssumeCapacity(.{
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
            self.link_edge_refs.appendAssumeCapacity(.{
                .level = link.from_level,
                .cell = link.from_cell,
                .index = @intCast(i),
                .reverse = false,
            });
            if (link.bidirectional) {
                self.link_edge_refs.appendAssumeCapacity(.{
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
    // renumbers or rebuilds an unaffected chunk. Returns true on an edge-window overflow (the
    // chunk is then left with empty adjacency until growChunkEdgeWindow re-patches it).
    fn patchChunk(self: *NavGraph, level: u16, world: *const WorldSystem, chunk: u32, scratch: *ChunkPatchScratch) !bool {
        try self.buildChunkPatch(level, world, chunk, scratch);
        return try self.compactChunkEdges(level, chunk, scratch);
    }

    // The part of a chunk patch before compaction: clears the chunk's slot window and rebuilds
    // its portals, ordering/labels, and transient edge list into `scratch.edges`. Idempotent.
    fn buildChunkPatch(self: *NavGraph, level: u16, world: *const WorldSystem, chunk: u32, scratch: *ChunkPatchScratch) !void {
        self.clearChunkSlots(level, chunk);
        scratch.edges.clearRetainingCapacity();
        try self.discoverChunkPortals(level, chunk, scratch);
        self.addChunkLinkPortals(level, chunk, world);
        try self.connectChunkIntraEdges(level, chunk, scratch);
        self.orderChunkPortals(level, chunk);
    }

    // Main thread only (never under a worker): re-patches a chunk flagged by a patch, first
    // relocating its edge window to the arena tail at slack * the new edge count when its edges
    // outgrew it. Returns whether the window grew (false only when a threaded patch flagged the
    // chunk for an error rather than an overflow, so the plain re-patch fits). The re-patch
    // rebuilds the transient edge list (the threaded path's worker scratch was reused by later
    // chunks), so the result is exactly the chunk's patch, just in a bigger window.
    fn growChunkEdgeWindow(self: *NavGraph, level: u16, world: *const WorldSystem, chunk: u32, scratch: *ChunkPatchScratch) ChunkPatchError!bool {
        try self.buildChunkPatch(level, world, chunk, scratch);
        const old_cap = self.chunk_edge_cap.items[chunk];
        const grow = scratch.edges.items.len > old_cap;
        if (grow) try self.relocateChunkEdgeWindow(chunk, scratch.edges.items.len);
        const overflowed = try self.compactChunkEdges(level, chunk, scratch);
        std.debug.assert(!overflowed);
        if (!grow) return false;
        // Low-frequency growth diagnostic (a cold dig-triggered event, at most a few times per
        // chunk between full builds since each growth at least doubles the window). The count
        // is also surfaced through stats.edge_windows_grown. Kept out of test builds, which
        // trigger it on purpose.
        if (comptime logging.enabled(.debug) and !builtin.is_test)
            logging.game.debug("nav chunk {d} level {d} edge window grown {d} -> {d} ({d} edges); arena {d} slots per level", .{ chunk, level, old_cap, self.chunk_edge_cap.items[chunk], scratch.edges.items.len, self.total_edge_slots });
        return true;
    }

    // Moves one chunk's edge window (shared by every level) to the tail of the edge arena with
    // cap = max(needed * default_edge_slack, chunk_edge_floor), copying every level's current
    // window contents and rebasing that chunk's portal_edge_start entries. The vacated window
    // becomes a hole (edge_hole_slots). The growth respects the nav memory gate
    // (edge_arena_slot_limit): past it the arena is compacted first, and a growth that still
    // does not fit is refused loudly (counted, NavWorldTooLarge): the chunk keeps the live
    // portals buildChunkPatch just rebuilt with zero edge counts, and patchDirtyChunks still
    // patches the rest of the dirty set and returns the first error after the loop. Every
    // level's arena capacity is ensured BEFORE the relocation mutates anything, so an OOM
    // leaves a valid layout (compacted at most).
    fn relocateChunkEdgeWindow(self: *NavGraph, chunk: u32, needed: usize) ChunkPatchError!void {
        const old_cap = self.chunk_edge_cap.items[chunk];
        std.debug.assert(needed > old_cap);
        const needed_u32 = std.math.cast(u32, needed) orelse return error.NavWorldTooLarge;
        const new_cap = @max(needed_u32 *| default_edge_slack, chunk_edge_floor);
        if (!self.edgeArenaAdmits(new_cap) and self.edge_hole_slots != 0) try self.compactEdgeArena();
        if (!self.edgeArenaAdmits(new_cap)) {
            @branchHint(.cold);
            self.edge_growth_refused_total += 1;
            if (comptime logging.enabled(.err) and !builtin.is_test)
                logging.game.err("nav chunk {d} edge window growth to {d} refused: arena {d} live + {d} slots per level exceeds the nav memory gate's {d}-slot ceiling (max_nav_memory_bytes); refusal {d}", .{ chunk, new_cap, self.edgeArenaLiveSlots(), new_cap, self.edge_arena_slot_limit, self.edge_growth_refused_total });
            return error.NavWorldTooLarge;
        }
        // Read after any compaction above, which moves windows.
        const old_base = self.chunk_edge_base.items[chunk];
        const new_base = self.total_edge_slots;
        const new_total = new_base + new_cap; // admitted, so within the u32 limit
        for (self.level_graphs.items) |*lg| try self.ensureEdgeArenaCapacity(lg, new_total);
        const pbase = self.chunk_portal_base.items[chunk];
        const pcap = self.chunk_portal_cap.items[chunk];
        for (self.level_graphs.items) |*lg| {
            // Ensured above; the std check behind a .len write is stripped in ReleaseFast.
            std.debug.assert(lg.portal_edges.capacity >= new_total);
            lg.portal_edges.items.len = new_total;
            @memcpy(lg.portal_edges.items[new_base..][0..old_cap], lg.portal_edges.items[old_base..][0..old_cap]);
            for (lg.portal_edge_start.items[pbase .. pbase + pcap]) |*start| {
                std.debug.assert(start.* >= old_base and start.* <= old_base + old_cap);
                start.* = start.* - old_base + new_base;
            }
        }
        self.chunk_edge_base.items[chunk] = new_base;
        self.chunk_edge_cap.items[chunk] = new_cap;
        self.total_edge_slots = new_total;
        self.edge_hole_slots += old_cap;
    }

    // Whether appending a `new_cap`-slot window keeps every level's arena within the nav memory
    // gate's per-level ceiling. Post-compaction (no holes) this is live + new_cap.
    fn edgeArenaAdmits(self: *const NavGraph, new_cap: u32) bool {
        return @as(u64, self.total_edge_slots) + new_cap <= self.edge_arena_slot_limit;
    }

    // Grows one level's edge arena to hold `needed` slots: geometrically (1.5x) so most later
    // relocations fit without allocating, but never past the gated ceiling.
    fn ensureEdgeArenaCapacity(self: *NavGraph, lg: *NavLevelGraph, needed: u32) !void {
        if (lg.portal_edges.capacity >= needed) return;
        const geometric = lg.portal_edges.capacity +| lg.portal_edges.capacity / 2;
        const target = @min(@max(@as(usize, needed), geometric), @as(usize, self.edge_arena_slot_limit));
        try lg.portal_edges.ensureTotalCapacityPrecise(self.allocator, target);
    }

    // Packs every chunk edge window toward the arena front in place, removing the holes window
    // relocations left (edge_hole_slots -> 0). Windows are visited in ascending current base
    // (arena order), so each one moves toward the front and a forward copy never overwrites a
    // window that has not moved yet. Caps, per-slot adjacency order, and every level's content
    // are unchanged; only window positions move (portal_edge_start is rebased). The arenas keep
    // their capacity, so later growths reuse the freed tail. Allocation-free: the chunk order
    // lives in build_u32_scratch, sized to total_slots (>= chunk count) at every full build.
    // Main thread only, never under a patch dispatch. Deterministic: the result is a function of
    // the current layout, which the serial and threaded patches build identically.
    fn compactEdgeArena(self: *NavGraph) std.mem.Allocator.Error!void {
        const order = try self.buildScratch(self.chunkCount());
        for (order, 0..) |*chunk, index| chunk.* = @intCast(index);
        std.sort.pdq(u32, order, ChunkEdgeBaseOrder{ .bases = self.chunk_edge_base.items }, ChunkEdgeBaseOrder.lessThan);
        var running: u32 = 0;
        for (order) |chunk| {
            const old_base = self.chunk_edge_base.items[chunk];
            const cap = self.chunk_edge_cap.items[chunk];
            std.debug.assert(running <= old_base);
            if (running != old_base) {
                const pbase = self.chunk_portal_base.items[chunk];
                const pcap = self.chunk_portal_cap.items[chunk];
                for (self.level_graphs.items) |*lg| {
                    std.mem.copyForwards(AbstractEdge, lg.portal_edges.items[running..][0..cap], lg.portal_edges.items[old_base..][0..cap]);
                    for (lg.portal_edge_start.items[pbase .. pbase + pcap]) |*start| {
                        std.debug.assert(start.* >= old_base and start.* <= old_base + cap);
                        start.* = start.* - old_base + running;
                    }
                }
                self.chunk_edge_base.items[chunk] = running;
            }
            running += cap;
        }
        std.debug.assert(running == self.edgeArenaLiveSlots());
        for (self.level_graphs.items) |*lg| lg.portal_edges.items.len = running;
        self.total_edge_slots = running;
        self.edge_hole_slots = 0;
        self.edge_compactions_total += 1;
    }

    // The per-level edge-arena slots live windows own (total minus holes): what the arena
    // occupies after a compaction, and the quantity the nav memory gate charges. Holes are
    // reclaimable in place without allocating, and physical capacity past the live slots is
    // build rounding or geometric growth clamped to the ceiling current at that time, so
    // neither is charged.
    pub fn edgeArenaLiveSlots(self: *const NavGraph) u32 {
        return self.total_edge_slots - self.edge_hole_slots;
    }

    // Whether the arena's live slots fit the per-level edge-arena ceiling of a budget the system
    // is re-admitting (agent-budget raise, link growth): edge growth past the build-time
    // estimate spends the same headroom those raises consume. The same predicate the relocation
    // gate applies after a compaction (live + new_cap <= limit), so the two never disagree.
    pub fn edgeArenaFitsBudget(self: *const NavGraph, budget: NavMemoryBudget) bool {
        return self.edgeArenaLiveSlots() <= budget.edgeArenaSlotLimit(self.width, self.height);
    }

    // Re-derives the gated per-level edge-arena ceiling from a re-admitted budget. Callers gate
    // first (raiseAgentBudget via edgeArenaFitsBudget, the dig seam via admitsLinkLimit before
    // reserveLinkCapacity), so the live slots stay within the new ceiling.
    pub fn applyEdgeArenaBudget(self: *NavGraph, budget: NavMemoryBudget) void {
        self.edge_arena_slot_limit = budget.edgeArenaSlotLimit(self.width, self.height);
        std.debug.assert(self.edgeArenaLiveSlots() <= self.edge_arena_slot_limit);
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
        // Perimeter endpoints use their positional slot. An interior endpoint needs an entry in
        // its chunk's fixed interior run, assigned by the shared rule (assignLinkEndpointSlots):
        // for the whole link set at a full build, and at runtime by the post-commit link cursor
        // (PathfindingSystem.markNewNavLinksDirty) BEFORE the patch that reaches here. A miss
        // therefore means the endpoint is UNSLOTTED by the K cap (or not yet reached by a
        // deferred cursor): skip it (no portal, so the abstract solver never traverses the link,
        // exactly as with a blocked endpoint) rather than resolving against an absent run.
        // Underground NPCs request cross-level paths to the surface, so this gate is live.
        if (!self.isPerimeterCell(cell) and !self.interiorLinkSlotExists(chunk, cell)) return;
        self.addPortalCell(lg, level_grid.level, cell, chunk);
    }

    // Whether an interior cell has an assigned slot in its chunk's fixed link-endpoint run.
    // Guards tryLinkPortal so an unslotted endpoint is skipped instead of reaching
    // linkTailIndex's `orelse unreachable` against a run it was never assigned into.
    fn interiorLinkSlotExists(self: *const NavGraph, chunk: u32, cell_index: usize) bool {
        return std.mem.indexOfScalar(u32, self.chunkLinkRun(chunk), @as(u32, @intCast(cell_index))) != null;
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
            // The caller always follows an overflow with growChunkEdgeWindow (relocate + re-patch),
            // but that growth can itself fail (OOM) before re-patching this chunk, and a failed
            // `try` leaves the graph object exactly as it stands right now. Re-zero the counts so a
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

    // Sizes the per-chunk edge windows from the measured per-chunk MAX edge count across
    // levels, times the slack multiplier, with a floor. Shared geometry, so the cap of a chunk
    // covers every level's count for that chunk. Also resets the per-chunk overflow flags.
    // Measure, check, commit: a measured arena past the nav memory gate's per-level ceiling
    // (edge_arena_slot_limit; holes are zero at this seam, so this is its live slots) fails
    // loudly with NavWorldTooLarge BEFORE any layout field is written. The init build then
    // fails at load as the gate promises; a full relabel keeps the old windows, caps, bases,
    // and arena (its portals are rebuilt with zero edge counts, so the graph stays solve-safe)
    // and does not bump `version`.
    fn computeEdgeCaps(self: *NavGraph) (std.mem.Allocator.Error || NavGridError)!void {
        const chunk_count = self.chunkCount();
        // Allocation-free after the first build: build_u32_scratch then holds total_slots
        // (>= 2 * chunk_count) entries.
        const scratch = try self.buildScratch(2 * chunk_count);
        const per_level = scratch[0..chunk_count];
        const max_edges = scratch[chunk_count..];
        @memset(max_edges, 0);
        for (self.level_graphs.items) |*lg| {
            @memset(per_level, 0);
            for (lg.edge_scratch.items) |entry| per_level[lg.portals.items[entry.from].chunk] += 1;
            for (max_edges, per_level) |*max_count, count| max_count.* = @max(max_count.*, count);
        }
        var running: u32 = 0;
        for (max_edges) |raw| running +|= @max(raw *| default_edge_slack, chunk_edge_floor);
        if (running > self.edge_arena_slot_limit) {
            @branchHint(.cold);
            if (comptime logging.enabled(.err) and !builtin.is_test)
                logging.game.err("nav graph build: measured edge arena {d} slots per level exceeds the nav memory gate's {d}-slot ceiling (max_nav_memory_bytes); raise max_nav_memory_bytes or shrink the world", .{ running, self.edge_arena_slot_limit });
            return NavGridError.NavWorldTooLarge;
        }

        try setLen(&self.chunk_edge_cap, self.allocator, chunk_count);
        try setLen(&self.chunk_edge_base, self.allocator, chunk_count);
        try setLen(&self.chunk_edge_overflow, self.allocator, chunk_count);
        @memset(self.chunk_edge_overflow.items, false);
        var base: u32 = 0;
        for (max_edges, self.chunk_edge_cap.items, self.chunk_edge_base.items) |raw, *cap, *chunk_base| {
            cap.* = @max(raw *| default_edge_slack, chunk_edge_floor);
            chunk_base.* = base;
            base +|= cap.*;
        }
        std.debug.assert(base == running);
        self.total_edge_slots = running;
        self.edge_hole_slots = 0;
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
// Whether a chunk-local coordinate lies on its chunk's perimeter: the single predicate shared
// by NavGraph.isPerimeterCell and interiorLinkSlotsAvailable.
fn isPerimeterLocal(local_x: usize, local_y: usize, chunk_tiles: usize) bool {
    return local_x == 0 or local_x == chunk_tiles - 1 or local_y == 0 or local_y == chunk_tiles - 1;
}

// Nav-grid slot geometry (in nav cells) a LevelLink producer needs to predict interior slot
// assignment. Taken from NavGraph.linkSlotGeometry after a full build.
pub const NavLinkSlotGeometry = struct {
    chunk_tiles: u32,
    width: u32,
    height: u32,

    // Unresolved sentinel: chunk_tiles 0 is never a built graph's geometry (it is >= 1).
    pub const unresolved: NavLinkSlotGeometry = .{ .chunk_tiles = 0, .width = 0, .height = 0 };

    pub fn isResolved(self: NavLinkSlotGeometry) bool {
        return self.chunk_tiles != 0;
    }
};

// Producer-side admission check for a NEW link endpoint at `cell`: true when `cell` is a
// perimeter (or out-of-grid) cell, when it already HOLDS one of its chunk's interior slots, or
// when its nav chunk still has a free interior slot. It replays the shared assignment rule
// (assignLinkEndpointSlots: link order, endpoint a then b, deduped by cell across levels): the
// first nav_interior_link_slots_per_chunk distinct interior endpoint cells of the chunk are
// exactly the slotted ones. So a cell that is an existing but UNSLOTTED endpoint (past the cap)
// is refused like any new cell, and an accepted link is never inert. Counts over the whole link
// set (including links the incremental cursor has not reached yet), so a refusal agrees with the
// assignment the cursor will make. O(links), allocation-free, cold (once per dig attempt). Pure.
pub fn interiorLinkSlotsAvailable(links: []const LevelLink, cell: CellCoord, geometry: NavLinkSlotGeometry) bool {
    std.debug.assert(geometry.isResolved());
    const ct: usize = geometry.chunk_tiles;
    if (cell.x >= geometry.width or cell.y >= geometry.height) return true;
    if (isPerimeterLocal(cell.x % ct, cell.y % ct, ct)) return true;
    const chunk_x = cell.x / ct;
    const chunk_y = cell.y / ct;
    var slotted: [nav_interior_link_slots_per_chunk]CellCoord = undefined;
    var slotted_count: usize = 0;
    outer: for (links) |link| {
        for ([2]CellCoord{ link.cell_a, link.cell_b }) |endpoint| {
            if (slotted_count == slotted.len) break :outer;
            if (endpoint.x >= geometry.width or endpoint.y >= geometry.height) continue;
            if (endpoint.x / ct != chunk_x or endpoint.y / ct != chunk_y) continue;
            if (isPerimeterLocal(endpoint.x % ct, endpoint.y % ct, ct)) continue;
            const already_slotted = for (slotted[0..slotted_count]) |prior| {
                if (prior.x == endpoint.x and prior.y == endpoint.y) break true;
            } else false;
            if (already_slotted) continue;
            slotted[slotted_count] = endpoint;
            slotted_count += 1;
        }
    }
    for (slotted[0..slotted_count]) |held| {
        if (held.x == cell.x and held.y == cell.y) return true;
    }
    return slotted_count < nav_interior_link_slots_per_chunk;
}

// Orders chunk ids by their current edge-window base (arena order) for compactEdgeArena.
// Window bases are distinct, so the order is total and deterministic.
const ChunkEdgeBaseOrder = struct {
    bases: []const u32,

    fn lessThan(self: ChunkEdgeBaseOrder, lhs: u32, rhs: u32) bool {
        return self.bases[lhs] < self.bases[rhs];
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
const NavLinkCursorStats = PathfindingSystem.NavLinkCursorStats;
const EntityId = @import("../../data_system.zig").EntityId;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const test_support = @import("test_support.zig");
const abstractCapacity = test_support.abstractCapacity;
const baselineCapacity = test_support.baselineCapacity;
const addNavBody = test_support.addNavBody;
const loadTestWorldMeta = test_support.loadTestWorldMeta;
const requireTestTile = test_support.requireTestTile;
const appendPathRequest = test_support.appendPathRequest;
const WorldTilesetMeta = @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const PathRequest = @import("../../simulation.zig").PathRequest;
const nav_new_links_per_step_max = types.nav_new_links_per_step_max;
const budgetForCapacity = @import("nav_memory.zig").budgetForCapacity;
const TileId = @import("../../world_system.zig").TileId;

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

test "applyBlockedDelta saturates a negative net to zero (M8)" {
    // blocked_count=0 + delta=-1 must NOT @intCast-wrap into a huge usize.
    // Private NavGraph helper is visible same-file via the container name.
    var grid = NavGrid{ .blocked_count = 0 };
    NavGraph.applyBlockedDelta(&grid, -1);
    try std.testing.expectEqual(@as(usize, 0), grid.blocked_count);

    // Over-unblock from a positive count also saturates, never wraps.
    grid.blocked_count = 3;
    NavGraph.applyBlockedDelta(&grid, -5);
    try std.testing.expectEqual(@as(usize, 0), grid.blocked_count);

    // Positive path still accumulates normally.
    grid.blocked_count = 2;
    NavGraph.applyBlockedDelta(&grid, 1);
    try std.testing.expectEqual(@as(usize, 3), grid.blocked_count);
    NavGraph.applyBlockedDelta(&grid, -1);
    try std.testing.expectEqual(@as(usize, 2), grid.blocked_count);
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
    // (e) per-portal edge SEQUENCES: abstract A* relaxes a node's edges in its CSR order
    // (solve.zig's abstractCorridor walks portal_edges[start..start+count]), so the order
    // decides tie-breaking and must match too, not only the sorted set above.
    try expectPortalEdgeSequencesEqual(a, b);
}

// Asserts every live portal of `a` has the same ordered adjacency as the same (level, cell)
// portal of `b`, keyed by cell so it holds across different slot numberings and window
// layouts: same edge count, then per position the same target cell and cost.
fn expectPortalEdgeSequencesEqual(a: *const NavGraph, b: *const NavGraph) !void {
    const t = std.testing;
    for (a.level_graphs.items, b.level_graphs.items) |*la, *lb| {
        for (la.cell_to_portal.items, lb.cell_to_portal.items) |slot_a, slot_b| {
            try t.expectEqual(slot_a == no_cell, slot_b == no_cell);
            if (slot_a == no_cell) continue;
            const count = la.portal_edge_count.items[slot_a];
            try t.expectEqual(count, lb.portal_edge_count.items[slot_b]);
            const seq_a = la.portal_edges.items[la.portal_edge_start.items[slot_a]..][0..count];
            const seq_b = lb.portal_edges.items[lb.portal_edge_start.items[slot_b]..][0..count];
            for (seq_a, seq_b) |ea, eb| {
                try t.expectEqual(la.portals.items[ea.target].cell_index, lb.portals.items[eb.target].cell_index);
                try t.expectEqual(ea.cost, eb.cost);
            }
        }
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

test "a nav dirty mark past the reservation grows, counts once, and matches a full rebuild" {
    // reserveNavDirty(4) reserves 4 + 2 * nav_new_links_per_step_max = 20 dirty cells. 21
    // marks outrun it: the buffer grows (never drops), the apply counts the overflow once,
    // and the incremental graph still equals a fresh full build.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const floor0 = world.denseFloorLayerForLevel(0).?;

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.reserveNavDirty(4);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);
    try std.testing.expectEqual(@as(usize, 4 + 2 * types.nav_new_links_per_step_max), system.nav_dirty_edits_reserved);

    var marked: usize = 0;
    outer: for (0..world.height) |y_usize| {
        for (0..world.width) |x_usize| {
            if (marked == 21) break :outer;
            const x: u16 = @intCast(x_usize);
            const y: u16 = @intCast(y_usize);
            _ = try world.setDenseTile(floor0, x, y, tree);
            try system.markNavDirty(0, x, y);
            marked += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 21), system.nav_dirty_edits.items.len);
    const stats = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.dirty_buffer_grown);
    try std.testing.expectEqual(@as(u64, 1), system.nav_dirty_buffer_grown_total);

    // A following step within the reservation counts nothing more.
    _ = try world.setDenseTile(floor0, 7, 7, tree);
    try system.markNavDirty(0, 7, 7);
    const quiet = try system.applyBufferedNavUpdates(&data, &world, null);
    try std.testing.expectEqual(@as(usize, 0), quiet.dirty_buffer_grown);
    try std.testing.expectEqual(@as(u64, 1), system.nav_dirty_buffer_grown_total);

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

// Two-level world for runtime-link tests: the demo surface (level 0) plus an all-grass
// level 1, both fully open, `extent` px square (32 px cells).
fn initTwoLevelOpenWorld(meta: *const WorldTilesetMeta, extent: f32) !WorldSystem {
    const grass = try requireTestTile(meta, "grass");
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, meta, extent, extent);
    errdefer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    return world;
}

// A bidirectional ramp-shaped link joining level 1 and level 0 at the same cell.
fn rampLink(x: u16, y: u16) LevelLink {
    return .{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = x, .y = y }, .level_b = 0, .cell_b = .{ .x = x, .y = y }, .traversal_cost = 1, .bidirectional = true };
}

// Runs one step's real post-commit nav reaction (no structural events: the link cursor is
// the only trigger) and returns its stats.
fn reactOneStep(system: *PathfindingSystem, frame: *SimulationFrame, data: *const DataSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) !NavUpdateStats {
    frame.beginStep();
    return system.reactToPostCommitNavEvents(frame, data, world, thread_system);
}

// Slice 64E parity: the incremental graph equals a fresh full rebuild over the same world:
// portals and cell_to_portal byte-identical per level, the shared interior link-slot table
// identical, per-portal edge sets equal (expectGraphsEquivalent), and link_edges /
// link_edge_refs equal.
fn expectLinkPatchMatchesFullRebuild(system: *const PathfindingSystem, data: *const DataSystem, world: *const WorldSystem, extent: f32, capacity: types.PathfindingCapacity) !void {
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(capacity);
    try rebuilt.rebuildStaticNavGridWithWorld(data, world, extent, extent, 32, null);
    const inc = &system.graph;
    const full = &rebuilt.graph;
    try std.testing.expectEqual(full.level_graphs.items.len, inc.level_graphs.items.len);
    for (full.level_graphs.items, inc.level_graphs.items) |*full_level, *inc_level| {
        try std.testing.expectEqualSlices(PortalNode, full_level.portals.items, inc_level.portals.items);
        try std.testing.expectEqualSlices(u32, full_level.cell_to_portal.items, inc_level.cell_to_portal.items);
    }
    try std.testing.expectEqualSlices(u32, full.chunk_link_count.items, inc.chunk_link_count.items);
    try std.testing.expectEqualSlices(u32, full.chunk_link_cells.items, inc.chunk_link_cells.items);
    try std.testing.expectEqualSlices(LinkEdge, full.link_edges.items, inc.link_edges.items);
    try std.testing.expectEqualSlices(LinkEdgeRef, full.link_edge_refs.items, inc.link_edge_refs.items);
    try expectGraphsEquivalent(inc, full);
}

test "runtime interior ramp link is slotted and live after the incremental patch" {
    // A LevelLink added AFTER the init build (DigController.digRamp's runtime path) with an
    // INTERIOR endpoint joins the abstract tier in the same step's post-commit reaction, on
    // BOTH levels: the link cursor assigns its fixed interior slot and dirties both endpoint
    // levels, so the cross-level corridor is routable without any full rebuild.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // 4-tile chunks (abstractCapacity): (2,2) is interior to chunk (0,0).
    var world = try initTwoLevelOpenWorld(&meta, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    const endpoint: u32 = @intCast(system.graph.grid(1).?.indexForCell(.{ .x = 2, .y = 2 }).?);
    try std.testing.expect(system.graph.portalIndex(1, endpoint) == null);

    try world.addLevelLink(rampLink(2, 2));
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const stats = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.version_bumps);
    try std.testing.expectEqual(@as(usize, 0), stats.links_deferred);
    // Slotted and live on both linked levels.
    try std.testing.expect(system.graph.portalIndex(1, endpoint) != null);
    try std.testing.expect(system.graph.portalIndex(0, endpoint) != null);

    // An underground request to the surface now routes through the new ramp.
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = requester,
        .start_level = 1,
        .goal_level = 0,
        .start = .{ .x = 10 * 32 + 16, .y = 10 * 32 + 16 },
        .goal = .{ .x = 8 * 32 + 16, .y = 8 * 32 + 16 },
    });
    const path_stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), path_stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), path_stats.cross_level_solves);
}

test "runtime link patch matches a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const cobblestone = try requireTestTile(&meta, "cobblestone");
    const capacity = abstractCapacity();
    // 12x12 cells, 4-tile chunks (3x3 chunk grid); each case lands in its own chunk.
    var world = try initTwoLevelOpenWorld(&meta, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();

    // (a) Interior endpoint: (2,2) in chunk (0,0).
    try world.addLevelLink(rampLink(2, 2));
    _ = try reactOneStep(&system, &frame, &data, &world, null);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 384, capacity);

    // (b) Perimeter endpoint: (4,5) is chunk (1,1)'s left border column.
    try world.addLevelLink(rampLink(4, 5));
    _ = try reactOneStep(&system, &frame, &data, &world, null);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 384, capacity);

    // (c) A ramp on an already-walkable cell: the tile change flips no blocking state, so no
    // nav-invalidating event exists; the link cursor alone must patch the graph.
    const floor1 = world.denseFloorLayerForLevel(1).?;
    const changed = (try world.setDenseTile(floor1, 10, 6, cobblestone)) orelse return error.TestExpectedEqual;
    try std.testing.expect(!changed.old_blocks_movement and !changed.new_blocks_movement);
    try std.testing.expect(!PathfindingSystem.eventInvalidatesNavigation(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } }));
    try world.addLevelLink(rampLink(10, 6));
    const flip_free = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), flip_free.incremental_rebuilds);
    try std.testing.expect(system.graph.portalIndex(1, @intCast(system.graph.grid(1).?.indexForCell(.{ .x = 10, .y = 6 }).?)) != null);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 384, capacity);

    // (d) Links added across two steps.
    try world.addLevelLink(rampLink(9, 9));
    _ = try reactOneStep(&system, &frame, &data, &world, null);
    try world.addLevelLink(rampLink(2, 10));
    _ = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expect(!system.hasPendingNavLinks(&world));
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 384, capacity);
}

test "a ninth authored interior link endpoint in one chunk stays unslotted in incremental and full builds" {
    // Authored links only (DigController refuses this case before the world changes). An
    // 8-tile nav chunk has 36 interior cells, so nine distinct interior endpoints fit the
    // chunk but exceed K = nav_interior_link_slots_per_chunk.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    var world = try initTwoLevelOpenWorld(&meta, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);

    const cells = [_]CellCoord{
        .{ .x = 1, .y = 1 }, .{ .x = 2, .y = 1 }, .{ .x = 3, .y = 1 }, .{ .x = 4, .y = 1 }, .{ .x = 5, .y = 1 },
        .{ .x = 6, .y = 1 }, .{ .x = 1, .y = 2 }, .{ .x = 2, .y = 2 }, .{ .x = 3, .y = 2 },
    };
    comptime std.debug.assert(cells.len == nav_interior_link_slots_per_chunk + 1);
    for (cells) |cell| try world.addLevelLink(rampLink(cell.x, cell.y));

    // Nine new links exceed the per-step budget (8): step 1 folds links 0..7, step 2 the ninth.
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var unslotted: usize = 0;
    var steps: usize = 0;
    while (system.hasPendingNavLinks(&world) and steps < 4) : (steps += 1) {
        const stats = try reactOneStep(&system, &frame, &data, &world, null);
        unslotted += stats.link_endpoints_unslotted;
    }
    try std.testing.expectEqual(@as(usize, 2), steps);
    try std.testing.expectEqual(@as(usize, 1), unslotted);

    const ninth: u32 = @intCast(system.graph.grid(1).?.indexForCell(.{ .x = 3, .y = 2 }).?);
    try std.testing.expect(system.graph.portalIndex(1, ninth) == null);
    try std.testing.expect(system.graph.portalIndex(0, ninth) == null);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 384, capacity);

    // The full build leaves the same ninth endpoint inert and counts it once.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(capacity);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32, null);
    try std.testing.expectEqual(@as(usize, 1), rebuilt.graph.full_build_link_endpoints_unslotted);
    try std.testing.expect(rebuilt.graph.portalIndex(1, ninth) == null);
    try std.testing.expect(rebuilt.graph.portalIndex(0, ninth) == null);
}

// Ramp endpoint cells filling chunk (1,1)'s K interior slots (8-tile chunks over 24x24 cells),
// or eight of its perimeter cells off the border-run midpoints (index 4 of each fully-open
// side), so every ramp adds a new portal to the chunk's one open component.
fn chunkOneOneRampCells(perimeter: bool) [nav_interior_link_slots_per_chunk]CellCoord {
    return if (perimeter) .{
        .{ .x = 8, .y = 9 }, .{ .x = 8, .y = 14 }, .{ .x = 15, .y = 9 }, .{ .x = 15, .y = 14 },
        .{ .x = 9, .y = 8 }, .{ .x = 14, .y = 8 }, .{ .x = 9, .y = 15 }, .{ .x = 14, .y = 15 },
    } else .{
        .{ .x = 9, .y = 9 },   .{ .x = 11, .y = 9 },  .{ .x = 13, .y = 9 }, .{ .x = 9, .y = 11 },
        .{ .x = 11, .y = 11 }, .{ .x = 13, .y = 11 }, .{ .x = 9, .y = 13 }, .{ .x = 11, .y = 13 },
    };
}

test "runtime ramps filling one chunk's link capacity grow its edge window in place, never rebuilding" {
    // Regression (2026-10-06 manual run): every ramp endpoint is a portal in its chunk's open
    // component, so each one adds 2*(peers) intra edges. An open interior chunk builds with 4
    // border portals (16 edges, a floor-sized 32-edge window), so the SECOND ramp in one chunk
    // (4 + 6*5 = 34 edges) used to overflow into the full-rebuild fallback (version bump,
    // whole-graph hitch). Now the chunk's window grows in place (at ramps 2 and 5 here) and
    // every step stays an incremental patch equal to a full rebuild, serial and through the
    // real threaded patch's post-barrier growth pass.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    for ([_]bool{ false, true }) |perimeter| {
        for ([_]bool{ false, true }) |threaded| {
            var data = DataSystem.init(std.testing.allocator);
            defer data.deinit();
            var meta = try loadTestWorldMeta(std.testing.allocator);
            defer meta.deinit();
            var capacity = abstractCapacity();
            capacity.nav_chunk_tiles = 8;
            capacity.worker_participant_count = threads.participantSlotCount();
            // 24x24 cells, 8-tile chunks (3x3): chunk (1,1) spans cells 8..15 with four neighbors.
            var world = try initTwoLevelOpenWorld(&meta, 768);
            defer world.deinit();

            var system = PathfindingSystem.init(std.testing.allocator);
            defer system.deinit();
            try system.reserve(capacity);
            try system.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
            system.nav_thread_adaptive = false;
            system.nav_thread_items_per_range = 1;
            const chunk: u32 = 4;
            try std.testing.expectEqual(chunk_edge_floor, system.graph.chunk_edge_cap.items[chunk]);
            const built_version = system.graph.version;

            var frame = SimulationFrame.init(std.testing.allocator);
            defer frame.deinit();
            var grown: usize = 0;
            for (chunkOneOneRampCells(perimeter)) |cell| {
                try world.addLevelLink(rampLink(cell.x, cell.y));
                const stats = try reactOneStep(&system, &frame, &data, &world, if (threaded) &threads else null);
                try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
                try std.testing.expectEqual(@as(usize, 0), stats.full_relabel);
                try std.testing.expectEqual(@as(usize, 0), stats.version_bumps);
                try std.testing.expectEqual(threaded, !system.graph.last_patch_batch.ran_inline);
                grown += stats.edge_windows_grown;
            }
            try std.testing.expectEqual(built_version, system.graph.version);
            // The window (shared by both levels) grew geometrically, not once per ramp: at ramp 2
            // (34 edges -> 68-edge window) and ramp 5 (76 -> 152), which then holds ramp 8's 136.
            try std.testing.expectEqual(@as(usize, 2), grown);
            try std.testing.expectEqual(@as(u32, 152), system.graph.chunk_edge_cap.items[chunk]);
            try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 768, capacity);
        }
    }
}

test "after an edge-window growth, ramps that fit the grown window are allocation-free" {
    // The growth itself is a cold, dig-triggered allocation point (each level's edge arena grows
    // geometrically); it must not leave the steady path allocating. Ramps 1-2 fill chunk (1,1)
    // and grow its window to 68 edges; ramps 3-4 (46 and 60 edges) then patch inside it with a
    // FailingAllocator on the world, graph, and system, through the threaded and serial paths.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try initTwoLevelOpenWorld(&meta, 768);
    defer world.deinit();
    try world.reserveLevelLinks(nav_interior_link_slots_per_chunk);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    capacity.worker_participant_count = threads.participantSlotCount();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const cells = chunkOneOneRampCells(false);
    var warm_grown: usize = 0;
    for (cells[0..2]) |cell| {
        try world.addLevelLink(rampLink(cell.x, cell.y));
        warm_grown += (try reactOneStep(&system, &frame, &data, &world, &threads)).edge_windows_grown;
    }
    try std.testing.expect(warm_grown > 0);

    const original = system.allocator;
    const world_original = world.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    system.graph.allocator = failing.allocator();
    world.allocator = failing.allocator();
    defer {
        world.allocator = world_original;
        system.graph.allocator = original;
        system.allocator = original;
    }
    for (cells[2..4], [_]bool{ true, false }) |cell, threaded| {
        try world.addLevelLink(rampLink(cell.x, cell.y));
        const stats = try reactOneStep(&system, &frame, &data, &world, if (threaded) &threads else null);
        try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
        try std.testing.expectEqual(@as(usize, 0), stats.edge_windows_grown);
        try std.testing.expectEqual(threaded, !system.graph.last_patch_batch.ran_inline);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    }
    world.allocator = world_original;
    system.graph.allocator = original;
    system.allocator = original;
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 768, capacity);
}

test "incremental dig opening many border crossings in one chunk grows its edge window in place" {
    // Classification companion to the ramp regression: digging alone (no links) can also
    // outgrow a chunk's build-measured window. A walled level builds every window at the
    // floor; carving a corridor lattice through chunk (1,1) gives it 12 border-run portals
    // in one component (12 + 12*11 = 144 edges), which used to force the full-rebuild fallback.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 768, 768);
    defer world.deinit();
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, tree);
    var y: u16 = 0;
    while (y < 24) : (y += 1) {
        var x: u16 = 0;
        while (x < 24) : (x += 1) _ = try world.setDenseTile(wall_layer, x, y, tree);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);

    var edits = std.ArrayList(NavCellEdit).empty;
    defer edits.deinit(std.testing.allocator);
    const lanes = [_]u16{ 9, 11, 13 };
    for (lanes) |lane| {
        var i: u16 = 0;
        while (i < 24) : (i += 1) {
            for ([_][2]u16{ .{ i, lane }, .{ lane, i } }) |xy| {
                const opened = (try world.setDenseTile(wall_layer, xy[0], xy[1], grass)) orelse continue;
                try edits.append(std.testing.allocator, .{ .level = opened.level, .x = opened.x, .y = opened.y });
            }
        }
    }
    const stats = try system.applyNavUpdates(&data, &world, edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.version_bumps);
    try std.testing.expect(stats.edge_windows_grown > 0);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(capacity);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
    try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
}

// A 24x24-cell level-0 world (768 px, 32 px cells) walled solid at init, so every 8-tile
// chunk window builds at the floor. `digCorridorLattice` then opens every odd row and column,
// giving every chunk 8-16 border runs in one component (64-256 edges): one batch outgrows all
// nine chunk windows at once.
const WalledWorld = struct {
    world: WorldSystem,
    wall_layer: usize,
    grass: TileId,
};

fn initWalledWorld(meta: *const WorldTilesetMeta) !WalledWorld {
    const tree = try requireTestTile(meta, "tree_0");
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, meta, 768, 768);
    errdefer world.deinit();
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, tree);
    var y: u16 = 0;
    while (y < 24) : (y += 1) {
        var x: u16 = 0;
        while (x < 24) : (x += 1) _ = try world.setDenseTile(wall_layer, x, y, tree);
    }
    return .{ .world = world, .wall_layer = wall_layer, .grass = try requireTestTile(meta, "grass") };
}

fn digCorridorLattice(walled: *WalledWorld, edits: *std.ArrayList(NavCellEdit)) !void {
    var lane: u16 = 1;
    while (lane < 24) : (lane += 2) {
        var i: u16 = 0;
        while (i < 24) : (i += 1) {
            for ([_][2]u16{ .{ i, lane }, .{ lane, i } }) |xy| {
                const opened = (try walled.world.setDenseTile(walled.wall_layer, xy[0], xy[1], walled.grass)) orelse continue;
                try edits.append(std.testing.allocator, .{ .level = opened.level, .x = opened.x, .y = opened.y });
            }
        }
    }
}

// Asserts two graphs built from one world share an identical edge-window LAYOUT, not just
// equal adjacency: the same window bases, caps, arena size, hole count, per-slot CSR starts
// and counts, and per-portal edge sequences.
fn expectSameEdgeLayout(a: *const NavGraph, b: *const NavGraph) !void {
    const t = std.testing;
    try t.expectEqual(a.total_edge_slots, b.total_edge_slots);
    try t.expectEqual(a.edge_hole_slots, b.edge_hole_slots);
    try t.expectEqualSlices(u32, a.chunk_edge_base.items, b.chunk_edge_base.items);
    try t.expectEqualSlices(u32, a.chunk_edge_cap.items, b.chunk_edge_cap.items);
    for (a.level_graphs.items, b.level_graphs.items) |*la, *lb| {
        try t.expectEqualSlices(u32, la.portal_edge_start.items, lb.portal_edge_start.items);
        try t.expectEqualSlices(u32, la.portal_edge_count.items, lb.portal_edge_count.items);
    }
    try expectPortalEdgeSequencesEqual(a, b);
}

// The build capacity the edge-window tests share: 8-tile nav chunks, one patch-scratch slot per
// participant of `threads`.
fn windowGrowthCapacity(threads: *const ThreadSystem) types.PathfindingCapacity {
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    capacity.worker_participant_count = threads.participantSlotCount();
    return capacity;
}

fn installFailingAllocator(system: *PathfindingSystem, failing: *std.testing.FailingAllocator) void {
    system.allocator = failing.allocator();
    system.graph.allocator = failing.allocator();
}

fn restoreTestingAllocator(system: *PathfindingSystem) void {
    system.allocator = std.testing.allocator;
    system.graph.allocator = std.testing.allocator;
}

test "an edge-window growth failing at any allocation retries to a full-rebuild graph" {
    // Sweeps an OOM through every allocation of the post-commit step whose second ramp
    // outgrows chunk (1,1)'s window (34 edges > 32), serial and through the real 3-worker
    // patch. Whichever allocation fails, no overflow flag is left set, nav_version is
    // unchanged, and the retry (the step's dirty marks stay buffered across a failed apply)
    // yields the uninterrupted result: the 68-edge window and a graph equal to a full rebuild.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    const capacity = windowGrowthCapacity(&threads);
    const cells = chunkOneOneRampCells(false);
    for ([_]bool{ false, true }) |threaded| {
        const thread_arg: ?*ThreadSystem = if (threaded) &threads else null;
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var data = DataSystem.init(std.testing.allocator);
            defer data.deinit();
            var world = try initTwoLevelOpenWorld(&meta, 768);
            defer world.deinit();
            var system = PathfindingSystem.init(std.testing.allocator);
            defer system.deinit();
            try system.reserve(capacity);
            try system.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
            system.nav_thread_adaptive = false;
            system.nav_thread_items_per_range = 1;
            var frame = SimulationFrame.init(std.testing.allocator);
            defer frame.deinit();
            try world.addLevelLink(rampLink(cells[0].x, cells[0].y));
            _ = try reactOneStep(&system, &frame, &data, &world, thread_arg);
            try world.addLevelLink(rampLink(cells[1].x, cells[1].y));
            const version = system.graph.version;
            // Trim each arena to its length so the growth must allocate (the build's geometric
            // capacity would otherwise hold the relocated window and no failure could land there).
            for (system.graph.level_graphs.items) |*lg| lg.portal_edges.shrinkAndFree(std.testing.allocator, lg.portal_edges.items.len);

            var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
            installFailingAllocator(&system, &failing);
            const result = reactOneStep(&system, &frame, &data, &world, thread_arg);
            restoreTestingAllocator(&system);
            for (system.graph.chunk_edge_overflow.items) |flag| try std.testing.expect(!flag);
            const succeeded = if (result) |stats| blk: {
                try std.testing.expect(!failing.has_induced_failure);
                try std.testing.expectEqual(@as(usize, 1), stats.edge_windows_grown);
                break :blk true;
            } else |err| blk: {
                try std.testing.expectEqual(error.OutOfMemory, err);
                _ = try reactOneStep(&system, &frame, &data, &world, thread_arg);
                break :blk false;
            };
            try std.testing.expectEqual(version, system.graph.version);
            try std.testing.expectEqual(@as(u32, 68), system.graph.chunk_edge_cap.items[4]);
            try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 768, capacity);
            if (succeeded) break;
        }
        // The growth step allocates (the arena outgrows its build capacity), so the sweep
        // really injected failures before the first clean run.
        try std.testing.expect(fail_index > 0);
    }
}

test "a threaded multi-chunk window growth that fails clears every overflow flag" {
    // Regression: the post-barrier pass cleared a chunk's flag only when it reached it, so a
    // growth that failed left every LATER flagged chunk of the batch flagged into the next
    // patch. The lattice dig overflows several chunks in one threaded batch; an OOM at any
    // allocation must leave no flag set, and the retried batch must equal a full rebuild.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    const capacity = windowGrowthCapacity(&threads);
    var failures: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var walled = try initWalledWorld(&meta);
        defer walled.world.deinit();
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &walled.world, 768, 768, 32, null);
        system.nav_thread_adaptive = false;
        system.nav_thread_items_per_range = 1;
        var edits = std.ArrayList(NavCellEdit).empty;
        defer edits.deinit(std.testing.allocator);
        try digCorridorLattice(&walled, &edits);
        for (edits.items) |edit| try system.markNavDirty(edit.level, edit.x, edit.y);
        for (system.graph.level_graphs.items) |*lg| lg.portal_edges.shrinkAndFree(std.testing.allocator, lg.portal_edges.items.len);

        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index, .resize_fail_index = 0 });
        installFailingAllocator(&system, &failing);
        const result = system.applyBufferedNavUpdates(&data, &walled.world, &threads);
        restoreTestingAllocator(&system);
        try std.testing.expect(!system.graph.last_patch_batch.ran_inline);
        for (system.graph.chunk_edge_overflow.items) |flag| try std.testing.expect(!flag);
        const succeeded = if (result) |stats| blk: {
            try std.testing.expect(stats.edge_windows_grown > 1);
            break :blk true;
        } else |err| blk: {
            try std.testing.expectEqual(error.OutOfMemory, err);
            failures += 1;
            const retried = try system.applyBufferedNavUpdates(&data, &walled.world, &threads);
            try std.testing.expectEqual(@as(usize, 0), retried.version_bumps);
            break :blk false;
        };
        var rebuilt = PathfindingSystem.init(std.testing.allocator);
        defer rebuilt.deinit();
        try rebuilt.reserve(capacity);
        try rebuilt.rebuildStaticNavGridWithWorld(&data, &walled.world, 768, 768, 32, null);
        try expectGraphsEquivalent(&system.graph, &rebuilt.graph);
        if (succeeded) break;
    }
    try std.testing.expect(failures > 0);
}

test "serial and threaded edge-window growth build identical layouts" {
    // The threaded patch defers growth to a post-barrier pass in dirty-set order, the serial
    // patch grows inline in the same order, so both must relocate windows to the same bases.
    // Checked on a multi-chunk lattice dig (several windows grow in one batch) and on the
    // per-step ramp sequence (two growths of one chunk), one world shared by both systems.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    const capacity = windowGrowthCapacity(&threads);
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    {
        var walled = try initWalledWorld(&meta);
        defer walled.world.deinit();
        var serial = PathfindingSystem.init(std.testing.allocator);
        defer serial.deinit();
        var threaded = PathfindingSystem.init(std.testing.allocator);
        defer threaded.deinit();
        for ([_]*PathfindingSystem{ &serial, &threaded }) |system| {
            try system.reserve(capacity);
            try system.rebuildStaticNavGridWithWorld(&data, &walled.world, 768, 768, 32, null);
            system.nav_thread_adaptive = false;
            system.nav_thread_items_per_range = 1;
        }
        var edits = std.ArrayList(NavCellEdit).empty;
        defer edits.deinit(std.testing.allocator);
        try digCorridorLattice(&walled, &edits);
        const serial_stats = try serial.applyNavUpdates(&data, &walled.world, edits.items);
        for (edits.items) |edit| try threaded.markNavDirty(edit.level, edit.x, edit.y);
        const threaded_stats = try threaded.applyBufferedNavUpdates(&data, &walled.world, &threads);
        try std.testing.expect(serial.graph.last_patch_batch.ran_inline);
        try std.testing.expect(!threaded.graph.last_patch_batch.ran_inline);
        try std.testing.expect(serial_stats.edge_windows_grown > 1);
        try std.testing.expectEqual(serial_stats.edge_windows_grown, threaded_stats.edge_windows_grown);
        try expectSameEdgeLayout(&serial.graph, &threaded.graph);
    }

    var world = try initTwoLevelOpenWorld(&meta, 768);
    defer world.deinit();
    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    var threaded = PathfindingSystem.init(std.testing.allocator);
    defer threaded.deinit();
    for ([_]*PathfindingSystem{ &serial, &threaded }) |system| {
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
        system.nav_thread_adaptive = false;
        system.nav_thread_items_per_range = 1;
    }
    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    var threaded_frame = SimulationFrame.init(std.testing.allocator);
    defer threaded_frame.deinit();
    var grown: usize = 0;
    for (chunkOneOneRampCells(false)) |cell| {
        try world.addLevelLink(rampLink(cell.x, cell.y));
        grown += (try reactOneStep(&serial, &serial_frame, &data, &world, null)).edge_windows_grown;
        _ = try reactOneStep(&threaded, &threaded_frame, &data, &world, &threads);
        try std.testing.expect(!threaded.graph.last_patch_batch.ran_inline);
        try expectSameEdgeLayout(&serial.graph, &threaded.graph);
    }
    try std.testing.expectEqual(@as(usize, 2), grown);
}

// Solves one request on `system` (serial) and returns the cache slot holding its result.
fn solveAndCache(system: *PathfindingSystem, requester: EntityId, request: PathRequest) !usize {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    var keyed = request;
    keyed.entity = requester;
    try appendPathRequest(&stream, keyed);
    _ = try system.updateSerial(&stream, 8, .{});
    return cachedSlot(system, request) orelse error.TestExpectedEqual;
}

fn cachedSlot(system: *const PathfindingSystem, request: PathRequest) ?usize {
    const key = system.graph.keyForWorld(request.goal_level, request.goal, request.agent_class) orelse return null;
    return system.completed.freshSlotIndex(key, system.step_counter, types.default_cache_ttl_steps);
}

// Asserts two cached results hold the same path: plain cells, level, and stitched corridor.
fn expectSameCachedPath(a: *const PathfindingSystem, slot_a: usize, b: *const PathfindingSystem, slot_b: usize) !void {
    const result_a = a.completed.resultAt(slot_a);
    const result_b = b.completed.resultAt(slot_b);
    try std.testing.expectEqual(result_a.path_level, result_b.path_level);
    try std.testing.expectEqualSlices(u32, a.completed.pathSlice(slot_a, result_a.path_len), b.completed.pathSlice(slot_b, result_b.path_len));
    try std.testing.expectEqualSlices(types.StitchedCell, a.completed.stitchedSlice(slot_a, result_a.stitched_len), b.completed.stitchedSlice(slot_b, result_b.stitched_len));
}

fn cellCenterRequest(start_level: u16, start: [2]u16, goal_level: u16, goal: [2]u16) PathRequest {
    return .{
        .entity = undefined,
        .start_level = start_level,
        .goal_level = goal_level,
        .start = .{ .x = @as(f32, @floatFromInt(start[0])) * 32 + 16, .y = @as(f32, @floatFromInt(start[1])) * 32 + 16 },
        .goal = .{ .x = @as(f32, @floatFromInt(goal[0])) * 32 + 16, .y = @as(f32, @floatFromInt(goal[1])) * 32 + 16 },
    };
}

test "abstract A* after an edge-window growth returns the paths of a fresh full rebuild" {
    // Window growth moves a chunk's edges to a new arena position; the abstract search walks
    // each portal's edges in CSR order, so the incremental graph must yield the exact paths a
    // fresh full rebuild yields: same-level paths across the grown chunk on both levels and
    // cross-level paths through its ramps.
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = try initTwoLevelOpenWorld(&meta, 768);
    defer world.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var grown: usize = 0;
    for (chunkOneOneRampCells(false)[0..5]) |cell| {
        try world.addLevelLink(rampLink(cell.x, cell.y));
        grown += (try reactOneStep(&system, &frame, &data, &world, null)).edge_windows_grown;
    }
    try std.testing.expectEqual(@as(usize, 2), grown);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(capacity);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const requests = [_]PathRequest{
        cellCenterRequest(0, .{ 1, 12 }, 0, .{ 22, 12 }),
        cellCenterRequest(1, .{ 12, 1 }, 1, .{ 12, 22 }),
        cellCenterRequest(1, .{ 2, 2 }, 0, .{ 21, 21 }),
        cellCenterRequest(0, .{ 20, 3 }, 1, .{ 3, 20 }),
    };
    for (requests) |request| {
        const slot = try solveAndCache(&system, requester, request);
        const fresh_slot = try solveAndCache(&rebuilt, requester, request);
        try std.testing.expect(system.completed.resultAt(slot).stitched_len != 0);
        try expectSameCachedPath(&system, slot, &rebuilt, fresh_slot);
    }
}

test "a cached path outside the dirty batch survives an edge-window growth and equals a fresh solve" {
    // Slice 64E (Slice 72 E4's surviving-cache case): a window growth stays an incremental
    // patch, so nav_version (part of every cache key) is unchanged and scoped eviction drops
    // only paths crossing the edited cells. A path along the top row (chunks 0-2) never
    // touches the ramp cells in chunk (1,1), so it must stay cached, unchanged, through the
    // step that grows chunk (1,1)'s window, and still equal a fresh solve on a full rebuild.
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = try initTwoLevelOpenWorld(&meta, 768);
    defer world.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const cells = chunkOneOneRampCells(false);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try world.addLevelLink(rampLink(cells[0].x, cells[0].y));
    _ = try reactOneStep(&system, &frame, &data, &world, null);

    const request = cellCenterRequest(0, .{ 1, 1 }, 0, .{ 22, 2 });
    const slot = try solveAndCache(&system, requester, request);
    const before = system.completed.resultAt(slot);
    try std.testing.expect(before.stitched_len != 0);
    var stitched_before = std.ArrayList(types.StitchedCell).empty;
    defer stitched_before.deinit(std.testing.allocator);
    try stitched_before.appendSlice(std.testing.allocator, system.completed.stitchedSlice(slot, before.stitched_len));
    const version = system.graph.version;

    try world.addLevelLink(rampLink(cells[1].x, cells[1].y));
    const stats = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.edge_windows_grown);
    try std.testing.expectEqual(version, system.graph.version);
    const kept = cachedSlot(&system, request) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(slot, kept);
    try std.testing.expectEqualSlices(types.StitchedCell, stitched_before.items, system.completed.stitchedSlice(kept, system.completed.resultAt(kept).stitched_len));
    const view = system.statusForWorld(request.start_level, request.start, request.goal_level, request.goal, .default, null);
    try std.testing.expectEqual(types.PathStatus.available, view.status);

    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(capacity);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
    const fresh_slot = try solveAndCache(&rebuilt, requester, request);
    try expectSameCachedPath(&system, kept, &rebuilt, fresh_slot);
}

test "an edge-window growth past the nav memory gate compacts first, then refuses loudly" {
    // The gate's per-level arena ceiling (edge_arena_slot_limit) is pinned just below what
    // ramp 5's growth needs with the ramp-2 hole still in place, but enough once it is
    // reclaimed: the growth compacts first and succeeds, through the real 3-worker patch's
    // post-barrier pass with a FailingAllocator on the graph and system (the compaction moves
    // windows in place and allocates nothing; the arenas are pre-sized to the ceiling so the
    // relocation needs no allocation either). Then, with the ceiling at the arena's current
    // size, the next growth has no hole to reclaim and is refused: NavWorldTooLarge, counted
    // once per attempt, identically on a retry, with no overflow flag left set; once the
    // ceiling admits it, the retry grows and matches a full rebuild.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    const capacity = windowGrowthCapacity(&threads);
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = try initTwoLevelOpenWorld(&meta, 768);
    defer world.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;
    // The default ceiling leaves the gate's estimate plus headroom: far above this world's arena.
    try std.testing.expect(system.graph.edge_arena_slot_limit > 4 * system.graph.total_edge_slots);
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const cells = chunkOneOneRampCells(false);
    // Ramps 1-4, threaded: ramp 2 grows the window (the dirty buffers reach steady capacity).
    for (cells[0..4]) |cell| {
        try world.addLevelLink(rampLink(cell.x, cell.y));
        _ = try reactOneStep(&system, &frame, &data, &world, &threads);
    }
    try std.testing.expectEqual(@as(u32, 68), system.graph.chunk_edge_cap.items[4]);
    try std.testing.expectEqual(@as(u32, 32), system.graph.edge_hole_slots);

    // Ramp 5 needs a 152-slot window: total + 152 overflows the ceiling, total - 32 + 152 fits.
    system.graph.edge_arena_slot_limit = system.graph.total_edge_slots - 32 + 152;
    for (system.graph.level_graphs.items) |*lg| try lg.portal_edges.ensureTotalCapacityPrecise(std.testing.allocator, system.graph.edge_arena_slot_limit);
    try world.addLevelLink(rampLink(cells[4].x, cells[4].y));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    installFailingAllocator(&system, &failing);
    const grown_result = reactOneStep(&system, &frame, &data, &world, &threads);
    restoreTestingAllocator(&system);
    const grown = try grown_result;
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!system.graph.last_patch_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 1), grown.edge_windows_grown);
    try std.testing.expectEqual(@as(usize, 1), grown.edge_compactions);
    try std.testing.expectEqual(@as(u64, 1), system.graph.edge_compactions_total);
    try std.testing.expectEqual(@as(u64, 0), system.graph.edge_growth_refused_total);
    try std.testing.expectEqual(@as(u32, 68), system.graph.edge_hole_slots);
    try std.testing.expectEqual(system.graph.edge_arena_slot_limit, system.graph.total_edge_slots);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 768, capacity);

    // Ramps 6-8 fit the 152 window; a perimeter ramp then pushes chunk (1,1) past it with the
    // only hole (68) too small to make room under a ceiling pinned at the arena size.
    for (cells[5..8]) |cell| {
        try world.addLevelLink(rampLink(cell.x, cell.y));
        try std.testing.expectEqual(@as(usize, 0), (try reactOneStep(&system, &frame, &data, &world, null)).edge_windows_grown);
    }
    const version = system.graph.version;
    const perimeter = chunkOneOneRampCells(true);
    try world.addLevelLink(rampLink(perimeter[0].x, perimeter[0].y));
    try std.testing.expectError(error.NavWorldTooLarge, reactOneStep(&system, &frame, &data, &world, null));
    try std.testing.expectEqual(@as(u64, 1), system.graph.edge_growth_refused_total);
    try std.testing.expectError(error.NavWorldTooLarge, reactOneStep(&system, &frame, &data, &world, null));
    try std.testing.expectEqual(@as(u64, 2), system.graph.edge_growth_refused_total);
    for (system.graph.chunk_edge_overflow.items) |flag| try std.testing.expect(!flag);
    try std.testing.expectEqual(version, system.graph.version);

    system.graph.edge_arena_slot_limit = std.math.maxInt(u32);
    const retried = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), retried.edge_windows_grown);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 768, capacity);
}

// Regression oracle for a failed patch step: every slot with adjacency is live, its CSR range
// lies inside the arena, and every edge targets a live slot of its level. A tombstone target
// is what abstract A* would pop and index `components` with (no_cell).
fn expectNoEdgeTargetsTombstone(graph: *const NavGraph) !void {
    for (graph.level_graphs.items) |*lg| {
        for (lg.portal_edge_count.items, lg.portal_edge_start.items, 0..) |count, start, slot| {
            if (count == 0) continue;
            try std.testing.expect(lg.portals.items[slot].cell_index != no_cell);
            try std.testing.expect(start + count <= lg.portal_edges.items.len);
            for (lg.portal_edges.items[start..][0..count]) |edge| {
                try std.testing.expect(edge.target < lg.portals.items.len);
                try std.testing.expect(lg.portals.items[edge.target].cell_index != no_cell);
            }
        }
    }
}

// Nav cell index of (x, y) on `level` of a built graph.
fn navCellIndex(graph: *const NavGraph, level: u16, x: u16, y: u16) !u32 {
    const level_grid = graph.grid(level) orelse return error.TestUnexpectedResult;
    const index = level_grid.indexForCell(.{ .x = x, .y = y }) orelse return error.TestUnexpectedResult;
    return @intCast(index);
}

test "a refused edge-window growth still patches the rest of the dirty set, serial and threaded, with no edge into a tombstone" {
    // Regression: the serial patch returned at the first refused growth, so the refused chunk's
    // orthogonal neighbors (later in the dirty set) kept CSR edges into its old border-run slot,
    // which that chunk's patch had just tombstoned; abstract A* then indexed `components` by
    // no_cell (Debug panic, ReleaseFast UB). Chunk (1,1) holds one ramp; one step adds a second
    // ramp and blocks (8,12), the midpoint of its left border run [8,16), so the run splits into
    // [8,12) and [13,16) and the (8,12) slot dies. The chunk then needs 5 border + 2 link
    // portals = 5 + 7*6 = 47 edges > its 32-edge window, under a gate pinned at the arena size,
    // so the growth is refused. Serial and threaded must still patch every dirty chunk, leave
    // identical layouts, route around the refused chunk, and retry to full-rebuild parity.
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    const capacity = windowGrowthCapacity(&threads);
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    // 24x24 cells, 8-tile chunks (3x3); chunk (1,1) = chunk 4 spans cells 8..15.
    var world = try initTwoLevelOpenWorld(&meta, 768);
    defer world.deinit();
    // An open (grass-filled) obstacle layer on level 0, so one cell can be blocked later.
    const obstacle_layer = try world.addDenseLayer(0, 0, .obstacle, try requireTestTile(&meta, "grass"));
    const tree = try requireTestTile(&meta, "tree_0");
    // An authored ramp in chunk (0,0), away from the refused chunk, for a cross-level route.
    try world.addLevelLink(rampLink(2, 2));

    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    var threaded = PathfindingSystem.init(std.testing.allocator);
    defer threaded.deinit();
    var serial_frame = SimulationFrame.init(std.testing.allocator);
    defer serial_frame.deinit();
    var threaded_frame = SimulationFrame.init(std.testing.allocator);
    defer threaded_frame.deinit();
    const systems = [_]*PathfindingSystem{ &serial, &threaded };
    const frames = [_]*SimulationFrame{ &serial_frame, &threaded_frame };
    const thread_args = [_]?*ThreadSystem{ null, &threads };
    for (systems) |system| {
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
        system.nav_thread_adaptive = false;
        system.nav_thread_items_per_range = 1;
    }
    // The demo surface's own obstacles, (6,8) and (18,16), lie off chunk (1,1) and its borders.
    const blocked_before = serial.graph.levels.items[0].blocked_count;

    // Step 1: one ramp fits chunk (1,1)'s 32-edge window (4 border + 1 link portals, 24 edges).
    try world.addLevelLink(rampLink(9, 9));
    for (systems, frames, thread_args) |system, frame, thread_arg| {
        try std.testing.expectEqual(@as(usize, 0), (try reactOneStep(system, frame, &data, &world, thread_arg)).edge_windows_grown);
    }

    // Step 2: a second ramp plus the run-splitting block, refused by the pinned gate.
    try world.addLevelLink(rampLink(11, 9));
    _ = try world.setDenseTile(obstacle_layer, 8, 12, tree);
    const chunk: u32 = 4;
    for (systems, frames, thread_args) |system, frame, thread_arg| {
        const graph = &system.graph;
        try system.markNavDirty(0, 8, 12);
        // No holes yet, so no compaction can make room.
        try std.testing.expectEqual(@as(u32, 0), graph.edge_hole_slots);
        graph.edge_arena_slot_limit = graph.total_edge_slots;
        const version = graph.version;
        try std.testing.expectError(error.NavWorldTooLarge, reactOneStep(system, frame, &data, &world, thread_arg));
        try std.testing.expectEqual(thread_arg != null, !graph.last_patch_batch.ran_inline);
        try std.testing.expectEqual(blocked_before + 1, graph.levels.items[0].blocked_count);
        try std.testing.expectEqual(@as(u64, 1), graph.edge_growth_refused_total);
        try std.testing.expectEqual(version, graph.version);
        for (graph.chunk_edge_overflow.items) |flag| try std.testing.expect(!flag);
        // The refused chunk keeps its rebuilt live portals with empty adjacency.
        const lg = &graph.level_graphs.items[0];
        const pbase = graph.chunk_portal_base.items[chunk];
        for (lg.portal_edge_count.items[pbase..][0..graph.chunk_portal_cap.items[chunk]]) |count| {
            try std.testing.expectEqual(@as(u32, 0), count);
        }
        for ([_][2]u16{ .{ 9, 9 }, .{ 11, 9 }, .{ 8, 10 }, .{ 8, 14 } }) |xy| {
            try std.testing.expect(graph.portalIndex(0, try navCellIndex(graph, 0, xy[0], xy[1])) != null);
        }
        try std.testing.expect(graph.portalIndex(0, try navCellIndex(graph, 0, 8, 12)) == null);
        // Pre-fix: chunk (0,1)'s (7,12) portal still targeted the tombstoned (8,12) slot.
        try expectNoEdgeTargetsTombstone(graph);
    }
    try expectSameEdgeLayout(&serial.graph, &threaded.graph);
    for (serial.graph.level_graphs.items, threaded.graph.level_graphs.items) |*serial_level, *threaded_level| {
        try std.testing.expectEqualSlices(PortalNode, serial_level.portals.items, threaded_level.portals.items);
        try std.testing.expectEqualSlices(u32, serial_level.cell_to_portal.items, threaded_level.cell_to_portal.items);
    }

    // Before the retry, solves route around the refused chunk: a same-level one across the row
    // (chunks 3-0-1-2-5) and a cross-level one up the (2,2) ramp. The cross-level search runs
    // with h = 0 on level 0, so it pops every reached level-0 node in cost order: pre-fix that
    // included the tombstoned (8,12) slot (a Debug trap; ReleaseFast reads components[no_cell]).
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const before_retry = [_]PathRequest{
        cellCenterRequest(0, .{ 4, 12 }, 0, .{ 20, 12 }),
        cellCenterRequest(0, .{ 4, 12 }, 1, .{ 20, 12 }),
    };
    for (systems) |system| {
        for (before_retry) |request| {
            const slot = try solveAndCache(system, requester, request);
            try std.testing.expect(system.completed.resultAt(slot).stitched_len != 0);
            const view = system.statusForWorld(request.start_level, request.start, request.goal_level, request.goal, .default, null);
            try std.testing.expectEqual(types.PathStatus.available, view.status);
        }
    }

    // Admitted, the retry (the step's marks stay buffered) grows the window once.
    for (systems, frames, thread_args) |system, frame, thread_arg| {
        system.graph.edge_arena_slot_limit = std.math.maxInt(u32);
        const retried = try reactOneStep(system, frame, &data, &world, thread_arg);
        try std.testing.expectEqual(@as(usize, 1), retried.edge_windows_grown);
        // 2 x the 47 edges the refused step measured.
        try std.testing.expectEqual(@as(u32, 94), system.graph.chunk_edge_cap.items[chunk]);
        try expectNoEdgeTargetsTombstone(&system.graph);
        try expectLinkPatchMatchesFullRebuild(system, &data, &world, 768, capacity);
    }
    try expectSameEdgeLayout(&serial.graph, &threaded.graph);

    // A request the pre-retry solve did not cache equals a fresh solve on a full rebuild.
    var rebuilt = PathfindingSystem.init(std.testing.allocator);
    defer rebuilt.deinit();
    try rebuilt.reserve(capacity);
    try rebuilt.rebuildStaticNavGridWithWorld(&data, &world, 768, 768, 32, null);
    const across = cellCenterRequest(0, .{ 3, 11 }, 0, .{ 21, 11 });
    const fresh_slot = try solveAndCache(&rebuilt, requester, across);
    for (systems) |system| {
        const slot = try solveAndCache(system, requester, across);
        try expectSameCachedPath(system, slot, &rebuilt, fresh_slot);
    }
}

test "new links beyond the per-step budget defer in link order" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const capacity = abstractCapacity();
    // 16x16 cells, 4-tile chunks: one interior link per chunk keeps every edge window in range.
    var world = try initTwoLevelOpenWorld(&meta, 512);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);

    // Ten links in one step, each at the interior cell (1,1) of a distinct chunk.
    const link_count = 10;
    comptime std.debug.assert(link_count > nav_new_links_per_step_max);
    var cells: [link_count]CellCoord = undefined;
    for (&cells, 0..) |*cell, i| {
        cell.* = .{ .x = @intCast((i % 4) * 4 + 1), .y = @intCast((i / 4) * 4 + 1) };
        try world.addLevelLink(rampLink(cell.x, cell.y));
    }

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const step1 = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 2), step1.links_deferred);
    try std.testing.expectEqual(nav_new_links_per_step_max, system.nav_links_processed);
    // Links 0..7 are live; 8..9 wait for the next step, in link order.
    for (cells, 0..) |cell, i| {
        const index: u32 = @intCast(system.graph.grid(1).?.indexForCell(.{ .x = cell.x, .y = cell.y }).?);
        try std.testing.expectEqual(i < nav_new_links_per_step_max, system.graph.portalIndex(1, index) != null);
    }

    const step2 = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 0), step2.links_deferred);
    try std.testing.expectEqual(@as(usize, link_count), system.nav_links_processed);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 512, capacity);
}

test "runtime link patch touches a constant chunk set independent of world size" {
    // Mirrors "entity obstacle create/destroy patches a constant chunk set independent of world
    // size": one interior ramp link at (5,5) (chunk (1,1), 4-tile chunks) patches that chunk
    // plus its four orthogonal neighbors on EACH of its two levels, regardless of level size.
    const extents = [_]f32{ 512, 1024 };
    var patched: [extents.len]usize = undefined;
    for (extents, 0..) |extent, i| {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var meta = try loadTestWorldMeta(std.testing.allocator);
        defer meta.deinit();
        var world = try initTwoLevelOpenWorld(&meta, extent);
        defer world.deinit();

        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());
        try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32, null);

        try world.addLevelLink(rampLink(5, 5));
        var frame = SimulationFrame.init(std.testing.allocator);
        defer frame.deinit();
        patched[i] = (try reactOneStep(&system, &frame, &data, &world, null)).chunks_patched;
    }
    try std.testing.expectEqual(@as(usize, 10), patched[0]);
    try std.testing.expectEqual(patched[0], patched[1]);
}

test "incremental runtime link assignment is allocation-free after warmup" {
    // The world's level-link storage is reserved at load (reserveLevelLinks) for every link
    // this test adds, and the full build reserves the graph's link edges to that same limit
    // (the count the memory gate admits). After one warm link reaction (an interior and a
    // perimeter link through the cursor) brings the dirty buffers and patch scratch to their
    // steady capacity, a FailingAllocator is installed on the WORLD, the graph, and the system,
    // and one more interior and one more perimeter link are added and folded through the REAL
    // 3-worker threaded chunk patch (forced multi-range), then again through the serial path.
    // Every step allocates zero times (world link storage, link edges, dirty buffers, patch
    // scratch) and matches a full rebuild. A link past the reservation is refused.
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try initTwoLevelOpenWorld(&meta, 512);
    defer world.deinit();
    try world.reserveLevelLinks(6);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 3, .items_per_range = 1 });
    defer threads.deinit();
    var capacity = abstractCapacity();
    capacity.worker_participant_count = threads.participantSlotCount();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);
    system.nav_thread_adaptive = false;
    system.nav_thread_items_per_range = 1;
    // The build reserved the link edges for the world's whole link limit up front.
    try std.testing.expect(system.graph.link_edges.capacity >= world.levelLinkLimit());
    try std.testing.expect(system.graph.link_edge_refs.capacity >= 2 * world.levelLinkLimit());

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    // Warm: interior (5,5) in chunk (1,1) + perimeter (8,13) on chunk (2,3)'s left column.
    try world.addLevelLink(rampLink(5, 5));
    try world.addLevelLink(rampLink(8, 13));
    _ = try reactOneStep(&system, &frame, &data, &world, &threads);

    const original = system.allocator;
    const world_original = world.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    system.graph.allocator = failing.allocator();
    world.allocator = failing.allocator();
    defer {
        world.allocator = world_original;
        system.graph.allocator = original;
        system.allocator = original;
    }

    // Threaded: interior (9,6) in chunk (2,1) + perimeter (12,2) on chunk (3,0)'s left column.
    try world.addLevelLink(rampLink(9, 6));
    try world.addLevelLink(rampLink(12, 2));
    const threaded = try reactOneStep(&system, &frame, &data, &world, &threads);
    try std.testing.expectEqual(@as(usize, 1), threaded.incremental_rebuilds);
    try std.testing.expect(!system.graph.last_patch_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    // Serial: interior (2,9) in chunk (0,2) + perimeter (6,12) on chunk (1,3)'s top row.
    try world.addLevelLink(rampLink(2, 9));
    try world.addLevelLink(rampLink(6, 12));
    const serial = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), serial.incremental_rebuilds);
    try std.testing.expect(system.graph.last_patch_batch.ran_inline);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    // A seventh direct link past the reservation is refused without growing anything: only
    // the dig commit seam's admitted growth raises the limit, so the link edges can never be
    // outgrown in-step.
    try std.testing.expectError(error.LevelLinkRoomUnreserved, world.addLevelLink(rampLink(10, 10)));
    try std.testing.expectEqual(@as(usize, 6), world.levelLinks().len);
    try std.testing.expectEqual(@as(usize, 6), world.levelLinkLimit());
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);

    world.allocator = world_original;
    system.graph.allocator = original;
    system.allocator = original;
    // The seam's order with real allocators: the nav link stores, then the world's limit;
    // the seventh link then lands and folds in.
    try system.reserveLinkCapacity(7);
    try world.reserveLevelLinks(7);
    try world.addLevelLink(rampLink(10, 10));
    try std.testing.expectEqual(@as(usize, 7), world.levelLinkLimit());
    _ = try reactOneStep(&system, &frame, &data, &world, null);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 512, capacity);
}

test "nav memory gate admits the world's reserved link limit, not just its current link count" {
    // The gate and the build's link-edge reservation measure the same thing
    // (WorldSystem.levelLinkLimit): a world reserving room for many runtime links is charged
    // for them at build even while it holds none, so the gate can never admit a build whose
    // reservation then exceeds max_nav_memory_bytes.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var unreserved = try initTwoLevelOpenWorld(&meta, 384);
    defer unreserved.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    // A ceiling that admits exactly the zero-link world (12x12 cells, 2 levels).
    const zero_link_bytes = budgetForCapacity(system.capacity, 2, 0).requiredBytes(12, 12);
    system.capacity.max_nav_memory_bytes = zero_link_bytes;
    try system.rebuildStaticNavGridWithWorld(&data, &unreserved, 384, 384, 32, null);

    var reserved = try initTwoLevelOpenWorld(&meta, 384);
    defer reserved.deinit();
    try reserved.reserveLevelLinks(4096);
    try std.testing.expectEqual(@as(usize, 0), reserved.levelLinks().len);
    var gated = PathfindingSystem.init(std.testing.allocator);
    defer gated.deinit();
    try gated.reserve(abstractCapacity());
    gated.capacity.max_nav_memory_bytes = zero_link_bytes;
    try std.testing.expectError(NavGridError.NavWorldTooLarge, gated.rebuildStaticNavGridWithWorld(&data, &reserved, 384, 384, 32, null));
}

// The 36 ramp endpoint cells of the one-chunk 8x8 fixture (8-tile nav chunks): 8 interior
// cells first (the chunk's K interior link slots), then all 28 perimeter cells (positional
// slots), so every ramp adds a portal to the chunk's one open component on the all-grass level.
fn oneChunkRampCells() [36]CellCoord {
    var cells: [36]CellCoord = undefined;
    var n: usize = 0;
    for ([_][2]u16{ .{ 1, 1 }, .{ 3, 1 }, .{ 5, 1 }, .{ 1, 3 }, .{ 3, 3 }, .{ 5, 3 }, .{ 1, 5 }, .{ 3, 5 } }) |xy| {
        cells[n] = .{ .x = xy[0], .y = xy[1] };
        n += 1;
    }
    var y: u16 = 0;
    while (y < 8) : (y += 1) {
        var x: u16 = 0;
        while (x < 8) : (x += 1) {
            if (x != 0 and y != 0 and x != 7 and y != 7) continue;
            cells[n] = .{ .x = x, .y = y };
            n += 1;
        }
    }
    std.debug.assert(n == cells.len);
    return cells;
}

// The per-level edge-arena ceiling `capacity`'s nav memory gate yields for the two-level 8x8
// fixture charging `link_limit` world links.
fn oneChunkGateSlotLimit(capacity: types.PathfindingCapacity, link_limit: usize) u32 {
    return budgetForCapacity(capacity, 2, link_limit).edgeArenaSlotLimit(8, 8);
}

// The max_nav_memory_bytes at which `capacity`'s gate, charging `link_limit` links on the
// two-level 8x8 fixture, yields exactly `slots` per-level edge-arena slots: the required bytes
// (whose ceiling is the gate's own arena estimate) plus one edge per level per extra slot.
fn oneChunkGateBytesForSlotLimit(capacity: types.PathfindingCapacity, link_limit: usize, slots: u32) usize {
    var budget = budgetForCapacity(capacity, 2, link_limit);
    budget.max_bytes = budget.requiredBytes(8, 8);
    const estimate = budget.edgeArenaSlotLimit(8, 8);
    std.debug.assert(slots >= estimate);
    return budget.max_bytes + 2 * @sizeOf(AbstractEdge) * @as(usize, slots - estimate);
}

test "link growth and agent-budget raises charge the edge arena's live slots grown by real relocations, never physical capacity or holes" {
    // The re-admissions (the dig seam's link growth through admitsLinkLimit, the population
    // seam's agent-budget raise) charge the edge arena's LIVE slots, total minus holes: the
    // quantity the relocation gate itself admits after a compaction. Real relocations drive it:
    // 36 ramps, 8 added per step, in the one 8-tile chunk of an 8x8 two-level world grow its window
    // 32 -> 112 -> 480 -> 1104 -> 2520 (k(k-1) edges for k = 8/16/24/32/36 portals; the
    // fourth step's 992 fits), leaving 1728 hole slots. A ceiling one slot under the live 2520
    // refuses and a ceiling at it admits, though total_edge_slots (4248) exceeds both; the
    // arena's physical capacity never changes an answer.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    var world = try initTwoLevelOpenWorld(&meta, 256);
    defer world.deinit();
    const cells = oneChunkRampCells();
    try world.reserveLevelLinks(cells.len);
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);
    const graph = &system.graph;
    try std.testing.expectEqual(@as(u32, 32), graph.total_edge_slots);
    // Keep the growths out of the relocation gate (its refusal path has its own test); the
    // re-admission answers below read only system.capacity and the arena.
    graph.edge_arena_slot_limit = std.math.maxInt(u32);

    const live_grown: u32 = 2520;
    const big_link_limit: usize = 600;
    // At big_link_limit links the ceiling sits one slot under the grown arena's live slots;
    // the world's own reserved limit leaves more headroom.
    system.capacity.max_nav_memory_bytes = oneChunkGateBytesForSlotLimit(system.capacity, big_link_limit, live_grown - 1);
    try std.testing.expect(oneChunkGateSlotLimit(system.capacity, cells.len) >= live_grown);
    try std.testing.expect(system.admitsLinkLimit(cells.len));
    try std.testing.expect(system.admitsLinkLimit(big_link_limit));

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    // Eight ramps join the world per step (a chunk patch admits every world link endpoint it
    // finds, and perimeter endpoints need no cursor slot, so adding all 36 at once would land
    // them in one step).
    for ([_]u32{ 112, 480, 1104, 1104, live_grown }, 0..) |cap, step| {
        const first = step * 8;
        for (cells[first..@min(first + 8, cells.len)]) |cell| try world.addLevelLink(rampLink(cell.x, cell.y));
        _ = try reactOneStep(&system, &frame, &data, &world, null);
        try std.testing.expectEqual(cap, graph.chunk_edge_cap.items[0]);
        try std.testing.expect(graph.edge_hole_slots <= graph.edgeArenaLiveSlots());
    }
    try std.testing.expect(!system.hasPendingNavLinks(&world));
    try std.testing.expectEqual(@as(u32, 32 + 112 + 480 + 1104), graph.edge_hole_slots);
    try std.testing.expectEqual(@as(u32, 4248), graph.total_edge_slots);
    try std.testing.expectEqual(live_grown, graph.edgeArenaLiveSlots());

    // Only the relocations flipped the big limit, and the holes are not charged: total exceeds
    // the ceiling the reserved limit still admits.
    try std.testing.expect(graph.total_edge_slots > oneChunkGateSlotLimit(system.capacity, cells.len));
    try std.testing.expect(system.admitsLinkLimit(cells.len));
    try std.testing.expect(!system.admitsLinkLimit(big_link_limit));
    // Physical capacity is not an input: far past the live slots, then trimmed to the length.
    for (graph.level_graphs.items) |*lg| try lg.portal_edges.ensureTotalCapacityPrecise(std.testing.allocator, 10_000);
    try std.testing.expect(system.admitsLinkLimit(cells.len));
    try std.testing.expect(!system.admitsLinkLimit(big_link_limit));
    for (graph.level_graphs.items) |*lg| lg.portal_edges.shrinkAndFree(std.testing.allocator, lg.portal_edges.items.len);
    try std.testing.expect(system.admitsLinkLimit(cells.len));
    try std.testing.expect(!system.admitsLinkLimit(big_link_limit));

    // The agent-budget raise charges the same live slots: a raised ceiling one slot under them
    // is refused (the gate's byte check itself passes) and leaves the growth ceiling alone; a
    // raised ceiling at them is admitted and becomes the growth ceiling.
    const requested = system.agentBudget() * 2;
    var raised = system.capacity;
    raised.max_agent_budget = requested;
    system.capacity.max_nav_memory_bytes = oneChunkGateBytesForSlotLimit(raised, cells.len, live_grown - 1);
    try std.testing.expect(!system.raiseAgentBudget(requested, cells.len));
    try std.testing.expectEqual(@as(u64, 1), system.agent_budget_raise_refused);
    try std.testing.expectEqual(std.math.maxInt(u32), graph.edge_arena_slot_limit);
    system.capacity.max_nav_memory_bytes = oneChunkGateBytesForSlotLimit(raised, cells.len, live_grown);
    try std.testing.expect(system.raiseAgentBudget(requested, cells.len));
    try std.testing.expectEqual(requested, system.agentBudget());
    try std.testing.expectEqual(live_grown, graph.edge_arena_slot_limit);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 256, capacity);
}

test "a measured edge arena past the nav memory gate fails the build loudly" {
    // The gate estimates the edge arena structurally (704 slots per level on this 8x8,
    // one-chunk, two-level world) and the build re-measures it from real topology. 36 ramps
    // authored before the build put 36 portals in the chunk's one open component: 36*35 = 1260
    // edges, a 2520-slot window. A byte ceiling whose per-level arena ceiling is one slot under
    // that measured arena fails the build with NavWorldTooLarge; at it, the build lands with
    // the arena exactly at the ceiling. (Before the check, both built and every later
    // relocation and re-admission was refused against an arena already past its ceiling.)
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    var world = try initTwoLevelOpenWorld(&meta, 256);
    defer world.deinit();
    const cells = oneChunkRampCells();
    try world.reserveLevelLinks(cells.len);
    for (cells) |cell| try world.addLevelLink(rampLink(cell.x, cell.y));

    var measured = PathfindingSystem.init(std.testing.allocator);
    defer measured.deinit();
    try measured.reserve(capacity);
    try measured.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);
    const total = measured.graph.total_edge_slots;
    try std.testing.expectEqual(@as(u32, 2 * 36 * 35), total);
    // The gate's own estimate is far below the measured arena.
    var exact = budgetForCapacity(measured.capacity, 2, cells.len);
    exact.max_bytes = exact.requiredBytes(8, 8);
    try std.testing.expectEqual(@as(u32, 704), exact.edgeArenaSlotLimit(8, 8));

    var refused = PathfindingSystem.init(std.testing.allocator);
    defer refused.deinit();
    try refused.reserve(capacity);
    refused.capacity.max_nav_memory_bytes = oneChunkGateBytesForSlotLimit(refused.capacity, cells.len, total - 1);
    try std.testing.expectError(NavGridError.NavWorldTooLarge, refused.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null));

    var admitted = PathfindingSystem.init(std.testing.allocator);
    defer admitted.deinit();
    try admitted.reserve(capacity);
    admitted.capacity.max_nav_memory_bytes = oneChunkGateBytesForSlotLimit(admitted.capacity, cells.len, total);
    try admitted.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32, null);
    try std.testing.expectEqual(total, admitted.graph.total_edge_slots);
    try std.testing.expectEqual(admitted.graph.total_edge_slots, admitted.graph.edge_arena_slot_limit);
    try std.testing.expectEqual(total, admitted.graph.edgeArenaLiveSlots());
}

test "a full relabel whose re-measured arena exceeds the gate fails before touching the edge layout" {
    // A full relabel re-measures every window (computeEdgeCaps) against the same ceiling as the
    // build. Pinned one slot under the current arena, a relabel triggered by one interior ramp
    // (two affected levels past a threshold of 1) must fail with NavWorldTooLarge before any
    // edge-layout write: caps, bases, arena size, and every level's arena untouched, no holes,
    // `version` unchanged. buildLevelInit has already rebuilt every level's portals with zero
    // edge counts, so the graph stays solve-safe (no edge targets a tombstone). Admitted, the
    // retry relabels and matches a full rebuild.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    // 16x16 cells, 8-tile chunks (2x2).
    var world = try initTwoLevelOpenWorld(&meta, 512);
    defer world.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);
    system.capacity.nav_full_relabel_level_threshold = 1;
    const graph = &system.graph;

    var caps_before = std.ArrayList(u32).empty;
    defer caps_before.deinit(std.testing.allocator);
    try caps_before.appendSlice(std.testing.allocator, graph.chunk_edge_cap.items);
    var bases_before = std.ArrayList(u32).empty;
    defer bases_before.deinit(std.testing.allocator);
    try bases_before.appendSlice(std.testing.allocator, graph.chunk_edge_base.items);
    var arena_before = std.ArrayList(AbstractEdge).empty;
    defer arena_before.deinit(std.testing.allocator);
    for (graph.level_graphs.items) |*lg| {
        try std.testing.expectEqual(@as(usize, graph.total_edge_slots), lg.portal_edges.items.len);
        try arena_before.appendSlice(std.testing.allocator, lg.portal_edges.items);
    }
    const total_before = graph.total_edge_slots;
    const version = graph.version;
    graph.edge_arena_slot_limit = total_before - 1;

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try world.addLevelLink(rampLink(3, 3));
    try std.testing.expectError(error.NavWorldTooLarge, reactOneStep(&system, &frame, &data, &world, null));
    try std.testing.expectEqualSlices(u32, caps_before.items, graph.chunk_edge_cap.items);
    try std.testing.expectEqualSlices(u32, bases_before.items, graph.chunk_edge_base.items);
    try std.testing.expectEqual(total_before, graph.total_edge_slots);
    try std.testing.expectEqual(@as(u32, 0), graph.edge_hole_slots);
    try std.testing.expectEqual(version, graph.version);
    var offset: usize = 0;
    for (graph.level_graphs.items, 0..) |*lg, level_index| {
        try std.testing.expectEqualSlices(AbstractEdge, arena_before.items[offset..][0..total_before], lg.portal_edges.items);
        offset += total_before;
        for (lg.portal_edge_count.items) |count| try std.testing.expectEqual(@as(u32, 0), count);
        try std.testing.expect(graph.portalIndex(@intCast(level_index), try navCellIndex(graph, @intCast(level_index), 3, 3)) != null);
    }
    try expectNoEdgeTargetsTombstone(graph);
    // With every level's adjacency empty a cross-chunk solve finds no abstract corridor, but it
    // completes safely (no tombstone to pop, no out-of-bounds CSR range).
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    var request = cellCenterRequest(0, .{ 2, 2 }, 0, .{ 13, 13 });
    request.entity = requester;
    try appendPathRequest(&stream, request);
    _ = try system.updateSerial(&stream, 8, .{});

    graph.edge_arena_slot_limit = std.math.maxInt(u32);
    const retried = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), retried.full_relabel);
    try std.testing.expectEqual(@as(usize, 1), retried.version_bumps);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 512, capacity);
}

test "interiorLinkSlotsAvailable refuses a cell that is an existing but unslotted endpoint" {
    // Nine distinct interior endpoints in chunk (0,0): the first K (link order) hold the slots,
    // the ninth is an existing link endpoint that stays unslotted (inert). A new ramp at that
    // ninth cell must be refused like any new cell, or the accepted link would be inert too.
    const k = nav_interior_link_slots_per_chunk;
    const geometry = NavLinkSlotGeometry{ .chunk_tiles = 8, .width = 16, .height = 16 };
    var links: [k + 1]LevelLink = undefined;
    for (&links, 0..) |*link, i| link.* = rampLink(@intCast(1 + i % 6), @intCast(1 + i / 6));
    const ninth = links[k].cell_a;
    try std.testing.expect(!interiorLinkSlotsAvailable(&links, ninth, geometry));
    // A slotted existing endpoint still admits.
    try std.testing.expect(interiorLinkSlotsAvailable(&links, links[0].cell_a, geometry));
    try std.testing.expect(interiorLinkSlotsAvailable(&links, links[k - 1].cell_a, geometry));

    // Same answer the shared assignment rule gives: the graph leaves that cell unslotted.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try initTwoLevelOpenWorld(&meta, 512);
    defer world.deinit();
    for (links) |link| try world.addLevelLink(link);
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);
    try std.testing.expectEqual(@as(usize, 1), system.graph.full_build_link_endpoints_unslotted);
    const ninth_index: u32 = @intCast(system.graph.grid(1).?.indexForCell(.{ .x = ninth.x, .y = ninth.y }).?);
    try std.testing.expect(system.graph.portalIndex(1, ninth_index) == null);
    try std.testing.expectEqual(system.graph.linkSlotGeometry(), geometry);
}

test "linkSlotGeometry is unresolved on an unbuilt graph" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try std.testing.expect(!system.graph.valid());
    try std.testing.expect(!system.graph.linkSlotGeometry().isResolved());
    try std.testing.expectEqual(NavLinkSlotGeometry.unresolved, system.graph.linkSlotGeometry());

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGrid(&data, 384, 384, 32);
    try std.testing.expectEqual(NavLinkSlotGeometry{ .chunk_tiles = 4, .width = 12, .height = 12 }, system.graph.linkSlotGeometry());
}

test "a failed link mark assigns, counts, and warns nothing; the retry does it exactly once" {
    // Success-path-only side effects: markNewNavLinksDirty runs its fallible dirty marks BEFORE
    // the infallible slot assignment, so a failed mark leaves the slot table, the unslotted
    // count, and the cursor untouched, and the retry assigns and counts each endpoint once.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    var world = try initTwoLevelOpenWorld(&meta, 512);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);

    // Fill chunk (0,0)'s K interior slots through the cursor.
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    for (0..nav_interior_link_slots_per_chunk) |i| try world.addLevelLink(rampLink(@intCast(1 + i % 6), @intCast(1 + i / 6)));
    _ = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expect(!system.hasPendingNavLinks(&world));

    // Next batch: a ninth interior cell in the full chunk (0,0) (unslotted) and an interior
    // cell of chunk (1,1) (would take that chunk's first slot).
    try world.addLevelLink(rampLink(3, 2));
    try world.addLevelLink(rampLink(9, 9));
    const chunk11: u32 = @intCast(system.graph.chunkOf(system.graph.grid(0).?.indexForCell(.{ .x = 9, .y = 9 }).?));
    const cursor_before = system.nav_links_processed;

    // Make the first dirty mark fail: the dirty buffer is full and the allocator refuses growth.
    system.clearNavDirty();
    while (system.nav_dirty_edits.items.len < system.nav_dirty_edits.capacity) {
        system.nav_dirty_edits.appendAssumeCapacity(.{ .level = 0, .x = 0, .y = 0 });
    }
    const original = system.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, system.markNewNavLinksDirty(&world));
    system.allocator = original;
    try std.testing.expectEqual(cursor_before, system.nav_links_processed);
    try std.testing.expectEqual(@as(u32, 0), system.graph.chunk_link_count.items[chunk11]);

    // Retry: assigns chunk (1,1)'s slot and counts the unslotted endpoint exactly once.
    system.clearNavDirty();
    const retry = try system.markNewNavLinksDirty(&world);
    try std.testing.expectEqual(@as(usize, 2), retry.processed);
    try std.testing.expectEqual(@as(usize, 1), retry.unslotted);
    try std.testing.expectEqual(@as(u32, 1), system.graph.chunk_link_count.items[chunk11]);
    _ = try system.applyBufferedNavUpdates(&data, &world, null);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 512, capacity);
}

test "link cursor stats of a failed apply are reported once by the successful retry" {
    // The cursor advances (and counts) when its dirty marks land, before the apply. A step whose
    // apply then fails used to lose those counts: the retry's cursor call finds no new links and
    // reported links_deferred = link_endpoints_unslotted = 0 for the links it actually folds.
    // Step 2 adds a ninth interior ramp in the full chunk (0,0) (unslotted) and five interior
    // ramps in chunk (1,1), which then needs 2 border + 5 link portals = 2 + 7*6 = 44 edges > its
    // 32-edge window, under a gate pinned at the arena size: the growth is refused. The retry
    // reports the unslotted endpoint exactly once.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    // 16x16 cells, 8-tile chunks (2x2).
    var world = try initTwoLevelOpenWorld(&meta, 512);
    defer world.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);

    // Step 1: fill chunk (0,0)'s K interior slots through the cursor.
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    for (0..nav_interior_link_slots_per_chunk) |i| try world.addLevelLink(rampLink(@intCast(1 + i % 6), @intCast(1 + i / 6)));
    const step1 = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 0), step1.link_endpoints_unslotted);
    try std.testing.expectEqual(NavLinkCursorStats{}, system.nav_link_cursor_pending);

    // Step 2: six links in one step; the chunk (1,1) growth is refused.
    try world.addLevelLink(rampLink(3, 2));
    for ([_][2]u16{ .{ 9, 9 }, .{ 11, 9 }, .{ 13, 9 }, .{ 9, 11 }, .{ 11, 11 } }) |xy| try world.addLevelLink(rampLink(xy[0], xy[1]));
    system.graph.edge_arena_slot_limit = system.graph.total_edge_slots;
    try std.testing.expectError(error.NavWorldTooLarge, reactOneStep(&system, &frame, &data, &world, null));
    try std.testing.expectEqual(@as(u64, 1), system.graph.edge_growth_refused_total);
    try std.testing.expectEqual(nav_interior_link_slots_per_chunk + 6, system.nav_links_processed);
    try std.testing.expectEqual(NavLinkCursorStats{ .processed = 6, .deferred = 0, .unslotted = 1 }, system.nav_link_cursor_pending);

    // Step 3 (no new links): the admitted retry folds them and reports the unslotted endpoint.
    system.graph.edge_arena_slot_limit = std.math.maxInt(u32);
    const step3 = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), step3.edge_windows_grown);
    try std.testing.expectEqual(@as(usize, 1), step3.link_endpoints_unslotted);
    try std.testing.expectEqual(@as(usize, 0), step3.links_deferred);
    try std.testing.expectEqual(NavLinkCursorStats{}, system.nav_link_cursor_pending);
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 512, capacity);
}

test "links deferred past the per-step budget across a full relabel stay on the cursor" {
    // A full relabel rebuilds the abstract graph from the WHOLE link set, including links the
    // cursor deferred this step. The cursor must stay put, so the next step still visits the
    // deferred links: parity holds and their unslotted endpoint is counted exactly once, by
    // the cursor, on the step that folds it. (An edge-window growth is not a rebuild: it
    // re-patches one chunk from the already-assigned slot table and never touches the cursor.)
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var capacity = abstractCapacity();
    capacity.nav_chunk_tiles = 8;
    var world = try initTwoLevelOpenWorld(&meta, 512);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32, null);
    // Two affected levels exceed a threshold of 1.
    system.capacity.nav_full_relabel_level_threshold = 1;

    // Ten links in one step: K fill chunk (0,0)'s interior slots; link 8 is a ninth distinct
    // interior cell there (unslotted); link 9 is interior to chunk (1,1).
    comptime std.debug.assert(nav_interior_link_slots_per_chunk == nav_new_links_per_step_max);
    for (0..nav_interior_link_slots_per_chunk) |i| try world.addLevelLink(rampLink(@intCast(1 + i % 6), @intCast(1 + i / 6)));
    try world.addLevelLink(rampLink(3, 2));
    try world.addLevelLink(rampLink(9, 9));

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const step1 = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), step1.version_bumps);
    try std.testing.expectEqual(@as(usize, 1), step1.full_relabel);
    try std.testing.expectEqual(@as(usize, 2), step1.links_deferred);
    try std.testing.expectEqual(@as(usize, 0), step1.link_endpoints_unslotted);
    // The relabel assigned the whole link set but left the cursor on the deferred links.
    try std.testing.expectEqual(nav_new_links_per_step_max, system.nav_links_processed);

    const step2 = try reactOneStep(&system, &frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 0), step2.links_deferred);
    try std.testing.expectEqual(@as(usize, 1), step2.link_endpoints_unslotted);
    try std.testing.expect(!system.hasPendingNavLinks(&world));
    try expectLinkPatchMatchesFullRebuild(&system, &data, &world, 512, capacity);
}

test "interiorLinkSlotsAvailable admits perimeter and known cells and refuses a ninth distinct interior cell" {
    const k = nav_interior_link_slots_per_chunk;
    const geometry = NavLinkSlotGeometry{ .chunk_tiles = 8, .width = 16, .height = 16 };
    var links: [k]LevelLink = undefined;
    // K distinct interior cells of chunk (0,0) (interior = local 1..6).
    for (&links, 0..) |*link, i| link.* = rampLink(@intCast(1 + i % 6), @intCast(1 + i / 6));

    // Perimeter cells always admit, even with the chunk's interior slots full.
    try std.testing.expect(interiorLinkSlotsAvailable(&links, .{ .x = 0, .y = 3 }, geometry));
    try std.testing.expect(interiorLinkSlotsAvailable(&links, .{ .x = 7, .y = 7 }, geometry));
    // An already-present interior endpoint admits at a full chunk.
    try std.testing.expect(interiorLinkSlotsAvailable(&links, links[3].cell_a, geometry));
    // A ninth distinct interior cell is refused.
    try std.testing.expect(!interiorLinkSlotsAvailable(&links, .{ .x = 6, .y = 6 }, geometry));
    // A different chunk is unaffected.
    try std.testing.expect(interiorLinkSlotsAvailable(&links, .{ .x = 10, .y = 10 }, geometry));

    // Links on two different level pairs at the same cell count once (dedupe by cell).
    var shared: [k]LevelLink = undefined;
    for (shared[0 .. k - 1], 0..) |*link, i| link.* = rampLink(@intCast(1 + i % 6), @intCast(1 + i / 6));
    shared[k - 1] = .{ .kind = .stair, .level_a = 2, .cell_a = shared[0].cell_a, .level_b = 1, .cell_b = shared[0].cell_a, .traversal_cost = 1, .bidirectional = true };
    // K-1 distinct cells: one more distinct interior cell still fits.
    try std.testing.expect(interiorLinkSlotsAvailable(&shared, .{ .x = 6, .y = 6 }, geometry));
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

test "incremental dig overflowing every chunk edge window grows each in place and matches a full rebuild" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // Wall the whole world at init so every chunk's edge window is sized to the floor. Then
    // open the whole world so every chunk's edges outgrow its window, forcing a window growth
    // (relocation + re-patch) for every chunk in one batch.
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
    // already uses below — so this test exercises the actual overflow->grow->re-patch
    // response through the real applyNavUpdates entry point, independent of how many edges
    // a given portal scheme happens to produce for this geometry.
    for (system.graph.chunk_edge_cap.items) |*cap| cap.* = 0;
    const stats = try system.applyNavUpdates(&data, &world, edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.version_bumps);
    try std.testing.expectEqual(system.graph.chunkCount(), stats.edge_windows_grown);
    for (system.graph.chunk_edge_cap.items) |cap| try std.testing.expect(cap >= chunk_edge_floor);

    // The grown windows hold a graph equivalent to an independent full rebuild.
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
