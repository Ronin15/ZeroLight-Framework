// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Frame-delayed, Z-aware grid pathfinding with two coordinated solver modes per
//! request kind:
//!   * individual: goal-keyed budget-bounded local A*; long-range/cross-level queries
//!     route through an abstract chunk-portal + link graph and stitch a full
//!     obstacle-aware (level,cell) path the per-agent query walks cell by cell.
//!   * group: demand-driven reverse-Dijkstra flow field toward a shared declared goal,
//!     lazily built and budgeted across frames (zero cost when unused).
//! Owns transient request queues, result caches, per-level nav-grid state, the
//! abstract chunk-portal/link graph, and per-worker scratch. The fixed-step update is
//! allocation-free after reserve/rebuild.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const sdl = @import("../../platform/sdl.zig").c;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const WorldSystem = @import("../world_system.zig").WorldSystem;
const PathAgentClass = @import("../simulation.zig").PathAgentClass;
const PathRequest = @import("../simulation.zig").PathRequest;
const PathRequestKind = @import("../simulation.zig").PathRequestKind;
const RangeOutputStream = @import("../simulation.zig").RangeOutputStream;

pub const pathfinding_range_alignment_items: usize = simd.lane_count;

const default_cell_size: f32 = 32.0;
const default_max_frame_requests: usize = 1024;
const default_max_pending_requests: usize = 1024;
const default_max_cached_results: usize = 1024;
const default_max_worker_scratch_slots: usize = 64;
const default_max_solved_requests_per_step: usize = 128;
pub const default_max_fallback_requests_per_step: usize = 128;
// Budget-bounded A* scratch is sized to this many explored nodes rather than the
// whole grid. Hitting the budget spills the request to a later frame.
const default_max_explored_nodes: usize = 4096;
// Cap on the stored path length per cached individual result. Longer paths are
// downsampled by stride so a moving agent can still derive a forward waypoint.
const default_max_stored_path_cells: usize = 512;
// Demand-driven managed shared-goal flow fields.
const default_max_group_fields: usize = 4;
const default_group_field_rebuild_min_steps: u32 = 30;
const default_group_field_build_budget: usize = 8192;
// Floor for the group-field agent threshold. The operating threshold is derived
// each step as a RATIO of the live capacity (see group_field_agent_ratio), so the
// field engages with ~a quarter of the crowd at any scale. This is only a hard
// minimum so a tiny crowd never builds a field for one or two agents.
const default_min_group_field_agents: usize = 2;
// Fraction of the live capacity that must share a goal before a flow field is
// built. At 4096-agent scale this is ~1024; at tiny scale the min floor dominates.
const default_group_field_agent_ratio: f32 = 0.25;
// Hard ceiling on the elastically-derived per-step/memory capacity. The only fixed
// capacity number; requests beyond it follow the existing dropped_requests path.
// Caps worst-case resident memory so a safe-point resize can never OOM.
const default_max_agent_budget: usize = 4096;
// Smallest agent count the per-step caps are derived for. The derived capacity
// tracks the live crowd down to this floor (so a tiny demo settles tiny), but never
// below it, so an empty/near-empty step keeps a usable minimum and avoids thrash.
const min_capacity_floor: usize = 8;
// Sustained-low-load window (in steps, ~2s at 60Hz) the agent count must stay below
// half of the live capacity before pools shrink. Grow-fast / shrink-slow hysteresis
// keeps an oscillating battle from reallocating every frame.
const default_capacity_shrink_window: u32 = 120;
// Per-step / per-memory caps are derived from agent_count via these ratios so a
// crowd of n drives n in-flight requests and a 4n result cache.
const cached_results_per_agent: usize = 4;
// Fixed per-frame A* solve/fallback amortization ceiling, independent of the agent
// population: population scales the queue and cache (all agents can be queued, all
// paths cached), NOT the per-tick A* work, so frame time does not grow with army
// size. The adaptive fallback tuner sets the actual operating point under this
// ceiling; 256 is only the burst cap. Clamped down to the population so a tiny demo
// (8 agents) still caps at 8, and held at 256 once the crowd grows past it.
const default_max_solves_per_frame: usize = 256;
// Generous default nav-memory ceiling. The build-time gate fails loud well before
// real allocation pressure; tests use a tiny ceiling to exercise the gate.
const default_max_nav_memory_bytes: usize = 512 * 1024 * 1024;
// Bounded outward radius (in cells) for projecting a blocked goal to the nearest
// open cell on its level.
const default_goal_projection_radius: i32 = 16;
// Side length (in nav cells) of one abstract chunk. The chunk-portal graph is the
// structure that bounds per-query work independent of total cell count.
const default_nav_chunk_tiles: u16 = 16;
// When an incremental nav update touches more than this many distinct levels, the
// per-affected-level relabel degenerates into a full relabel of every level. It
// increments a loud `nav_full_relabel` counter so a runaway batch is visible. The
// demo's worlds have very few levels, so a real edit stays well under this.
const default_nav_full_relabel_level_threshold: usize = 8;
// Fixed abstract-cost penalty added when an abstract A* edge crosses a LevelLink.
// Kept above any single octile step so the search prefers staying on one level.
const inter_level_penalty: u32 = cardinal_cost * 4;
// Bounded node budget for the abstract A* over portal/link nodes. The abstract
// graph is small (portals scale with chunk borders, not cells), so this caps the
// per-query abstract work; refinement of each segment uses the local budget.
const default_max_abstract_nodes: usize = 4096;
// Cap on the stored stitched-path cells per cached cross-chunk/cross-level result.
// An abstract corridor is refined into a single grid-adjacent (level,cell) path by
// stitching local A* segments; this bounds that path. A stitched path that exceeds
// the cap spills to a later frame (budget_exhausted) and is retried from the agent's
// advanced position, so the cap is never a silent truncation.
const default_max_stitched_path_cells: usize = 512;

const no_parent: usize = std.math.maxInt(usize);
const no_cell: u32 = std.math.maxInt(u32);
const no_component: u32 = 0;
const diagonal_cost: u32 = 14;
const cardinal_cost: u32 = 10;
const unreachable_cost: u32 = std.math.maxInt(u32);

pub const NavGridError = error{NavWorldTooLarge};

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

// One static-obstacle edit for incremental nav rebuild: a world tile flip on
// `level` at tile `(x, y)`. Carries only compact coordinates (no world handle), so
// the caller maps a `world_tile_changed`/`world_obstacle_changed` event into this
// before feeding `applyNavUpdates`. The world reference is passed alongside the edit
// batch so the affected level's blocked mask is re-derived from authoritative state.
pub const NavCellEdit = struct {
    level: u16,
    x: u16,
    y: u16,
};

// Diagnostics for one incremental `applyNavUpdates` batch. Recorded by the caller
// into runtime perf metrics. A batch that finds no real obstacle change does no
// work and leaves every counter zero.
pub const NavUpdateStats = struct {
    // Distinct abstract chunks touched by the dirty cells (membership-counted, not
    // double-counted) across affected levels.
    dirty_chunks: usize = 0,
    // 1 when this batch recomputed affected-level masks/components and the abstract
    // graph (an incremental rebuild that did NOT touch the whole world); else 0.
    incremental_rebuilds: usize = 0,
    // 1 when the affected-level count exceeded the configured full-relabel
    // threshold and every level was relabeled (a loud bounded fallback); else 0.
    full_relabel: usize = 0,
    // 1 when this batch bumped `nav_version` (invalidating goal-keyed caches); else 0.
    version_bumps: usize = 0,
};

pub const GridCell = struct {
    x: i32,
    y: i32,
};

/// Goal-keyed query identity. nav_version invalidates old work on rebuild without
/// pointer comparisons. The start cell is intentionally absent so a moving agent
/// reuses one shared in-flight/cached result per goal. The goal level is part of
/// the key so cross-level goals to the same cell on different floors are distinct
/// cache/pending/group entries.
pub const PathQueryKey = struct {
    nav_version: u32,
    agent_class: PathAgentClass,
    goal_level: u16 = 0,
    goal: GridCell,
};

pub const PathfindingCapacity = struct {
    max_frame_requests: usize = default_max_frame_requests,
    max_pending_requests: usize = default_max_pending_requests,
    max_cached_results: usize = default_max_cached_results,
    max_worker_scratch_slots: usize = default_max_worker_scratch_slots,
    max_solved_requests_per_step: usize = default_max_solved_requests_per_step,
    max_fallback_requests_per_step: usize = default_max_fallback_requests_per_step,
    // Budget-bounded A* sizing.
    max_explored_nodes: usize = default_max_explored_nodes,
    max_stored_path_cells: usize = default_max_stored_path_cells,
    // Abstract chunk-portal tier sizing. nav_chunk_tiles sets the abstract chunk
    // side length; max_abstract_nodes bounds abstract A* work.
    nav_chunk_tiles: u16 = default_nav_chunk_tiles,
    max_abstract_nodes: usize = default_max_abstract_nodes,
    max_stitched_path_cells: usize = default_max_stitched_path_cells,
    // Incremental nav update: when an `applyNavUpdates` batch touches more than this
    // many levels, it relabels every level (a loud, counted fallback) rather than
    // only the affected ones.
    nav_full_relabel_level_threshold: usize = default_nav_full_relabel_level_threshold,
    // Build-time nav memory ceiling. Exceeding it fails the rebuild loudly.
    max_nav_memory_bytes: usize = default_max_nav_memory_bytes,
    // Managed shared-goal flow fields.
    max_group_fields: usize = default_max_group_fields,
    group_field_rebuild_min_steps: u32 = default_group_field_rebuild_min_steps,
    group_field_build_budget: usize = default_group_field_build_budget,
    // Hard floor for the group-field threshold. The operating threshold is derived
    // each step from group_field_agent_ratio x live capacity, clamped up to this.
    min_group_field_agents: usize = default_min_group_field_agents,
    // Fraction of the live capacity sharing a goal before a flow field builds.
    group_field_agent_ratio: f32 = default_group_field_agent_ratio,
    // Elastic capacity ceiling (the only fixed capacity number). Live capacity
    // tracks the agent count up to this, then requests follow dropped_requests.
    max_agent_budget: usize = default_max_agent_budget,
    // Steps the agent count must stay below half capacity before pools shrink.
    capacity_shrink_window: u32 = default_capacity_shrink_window,
};

pub const PathfindingConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    fallback_adaptive_tuner: ?*AdaptiveWorkTuner = null,
    max_solved_requests_per_step: ?usize = null,
    max_fallback_requests_per_step: ?usize = null,
};

// Comptime-gated monotonic phase timer for the fixed-step pathfinding update.
// Zero-cost no-op when perf logging is disabled; uses the SDL monotonic clock
// (gated, perf-only) like the other fixed-step stage timers.
const PhaseTimer = if (runtime_perf_log.enabled) struct {
    start_ns: u64,
    fn begin() PhaseTimer {
        return .{ .start_ns = sdl.SDL_GetTicksNS() };
    }
    fn lap(self: *PhaseTimer) u64 {
        const now = sdl.SDL_GetTicksNS();
        return if (now > self.start_ns) now - self.start_ns else 0;
    }
} else struct {
    fn begin() PhaseTimer {
        return .{};
    }
    fn lap(_: *PhaseTimer) u64 {
        return 0;
    }
};

pub const PathfindingStats = struct {
    accepted_requests: usize = 0,
    duplicate_requests: usize = 0,
    pending_requests: usize = 0,
    solved_requests: usize = 0,
    fallback_requests: usize = 0,
    available_results: usize = 0,
    unavailable_results: usize = 0,
    dropped_requests: usize = 0,
    deferred_requests: usize = 0,
    fallback_deferred_requests: usize = 0,
    cache_hits: usize = 0,
    cache_evictions: usize = 0,
    // Solver and flow-field counters.
    budget_exhausted: usize = 0,
    goal_projected: usize = 0,
    group_fields_built: usize = 0,
    group_field_reuses: usize = 0,
    group_field_rebuild_throttled: usize = 0,
    group_field_samples: usize = 0,
    // Abstract-tier and cross-level routing counters.
    abstract_solves: usize = 0,
    cross_level_solves: usize = 0,
    fallback_batch: BatchStats = .{},
    // Per-phase update timings (ns); zero when perf logging is disabled. Recorded
    // as pathfinding_* sub-stage timers that break down pipeline_pathfinding.
    accept_ns: u64 = 0,
    group_service_ns: u64 = 0,
    solve_ns: u64 = 0,
    publish_ns: u64 = 0,

    pub fn solveBatch(self: PathfindingStats) BatchStats {
        return self.fallback_batch;
    }
};

// A distinct group goal and how many agents declared it this step; the count
// gates flow-field building.
const GroupRequestTally = struct {
    key: PathQueryKey,
    count: usize,
};

const PreparedRequest = struct {
    entity: EntityId,
    kind: PathRequestKind,
    key: PathQueryKey,
    start_level: u16,
    start: GridCell,
};

const PendingRequest = struct {
    entity: EntityId,
    key: PathQueryKey,
    // Level the representative start cell lives on. The goal level is carried by
    // key.goal_level; a differing start/goal level routes cross-level.
    start_level: u16,
    // Representative start cell for the single A* solve run for this goal key.
    start: GridCell,
    // Projected open goal cell index (the original goal may be blocked).
    // `no_parent` means projection found no open cell near the goal: a
    // definitive unavailable.
    goal_index: usize,
};

// One cell of a stitched obstacle-aware corridor path, tagged with its level. The
// stitched path is grid-adjacent within each level's contiguous run; at an
// inter-level link the level changes between consecutive cells (a discrete jump,
// the only non-adjacent step). The query walks the run matching the agent's current
// level cell by cell, exactly like a single-level individual A* path.
const StitchedCell = struct {
    level: u16,
    cell: u32,
};

const PathResult = struct {
    key: PathQueryKey,
    // Plain-path cells (start-to-goal order) for a same-component local solve,
    // stored in the cache slot's path buffer and indexed on path_level.
    path_len: usize,
    // Level the plain path cells index into (equals key.goal_level for a local solve).
    path_level: u16 = 0,
    // Number of stitched (level,cell) cells stored in the slot's stitched buffer.
    // Zero for a plain same-component local solve (path_len cells suffice); set for
    // an abstract chunk/cross-level corridor, whose full obstacle-aware path is
    // stitched from per-segment local A* and walked per-agent on its current level.
    stitched_len: usize = 0,
};

const PathSolveResult = union(enum) {
    // Successful solve carries the solved path through pending_index lookup.
    available: PathQueryKey,
    unavailable: PathQueryKey,
    deferred: PathQueryKey,
    // Budget spill: request stays pending; counted as budget-exhausted.
    budget_exhausted: PathQueryKey,
};

const OpenNode = struct {
    index: usize,
    f: u32,
    h: u32,
};

const NavGrid = struct {
    // Static navigation grid for ONE level (Z-floor). Derived from DataSystem
    // collision rows (level 0 only) and this level's composed world mask. Owns
    // component labels for cheap disconnected-goal rejection. All levels share the
    // same dimensions/cell_size; the owning NavGraph holds one NavGrid per level.
    level: u16 = 0,
    cell_size: f32 = default_cell_size,
    width: usize = 0,
    height: usize = 0,
    version: u32 = 1,
    blocked_count: usize = 0,
    // Highest component label assigned by buildComponents (labels are dense 1..N on
    // a world-bounded grid). Used to size the per-(level,component) portal index so
    // abstract seeding scans only the start component's portals.
    component_count: u32 = 0,
    blocked: std.ArrayList(bool) = .empty,
    components: std.ArrayList(u32) = .empty,
    component_queue: std.ArrayList(usize) = .empty,

    fn deinit(self: *NavGrid, allocator: std.mem.Allocator) void {
        self.component_queue.deinit(allocator);
        self.components.deinit(allocator);
        self.blocked.deinit(allocator);
        self.* = undefined;
    }

    // Sizes this level's arrays and clears them. Dimensions/version are assigned
    // by the owning NavGraph so every level stays consistent.
    fn prepare(
        self: *NavGrid,
        allocator: std.mem.Allocator,
        level: u16,
        width: usize,
        height: usize,
        cell_size: f32,
        version: u32,
    ) !void {
        self.level = level;
        self.cell_size = cell_size;
        self.width = width;
        self.height = height;
        self.version = version;
        const cell_count = self.cellCount();
        try self.blocked.ensureTotalCapacity(allocator, cell_count);
        try self.components.ensureTotalCapacity(allocator, cell_count);
        try self.component_queue.ensureTotalCapacity(allocator, cell_count);
        self.blocked.items.len = cell_count;
        self.components.items.len = cell_count;
        @memset(self.blocked.items, false);
        @memset(self.components.items, no_component);
        self.blocked_count = 0;
        self.component_queue.clearRetainingCapacity();
    }

    // Marks DataSystem static collision bodies as blocked. Only level 0 consumes
    // collision bodies (the demo's entities live on the ground floor); other
    // levels source obstacles purely from their world mask.
    fn markStaticBodies(self: *NavGrid, data: *const DataSystem) void {
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
    }

    fn cellCount(self: *const NavGrid) usize {
        return self.width * self.height;
    }

    fn valid(self: *const NavGrid) bool {
        return self.width != 0 and self.height != 0 and self.blocked.items.len == self.cellCount();
    }

    fn worldToCellClamped(self: *const NavGrid, value: math.Vec2) GridCell {
        const max_x: i32 = @intCast(self.width - 1);
        const max_y: i32 = @intCast(self.height - 1);
        const raw_x: i32 = math.floorToI32(value.x / self.cell_size);
        const raw_y: i32 = math.floorToI32(value.y / self.cell_size);
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

    // Composes this level's blocked mask from the world's dense bands and sparse
    // obstacles by iterating those columns directly. Dense bands cost
    // O(bands x cells) inherently; sparse obstacles cost O(sparse) total. This
    // avoids polling levelBlocksMovement per cell, which rescanned every sparse
    // obstacle for every cell (O(cells x sparse)).
    fn markWorldObstacles(self: *NavGrid, world: *const WorldSystem) void {
        if (@as(usize, self.level) >= world.levelCount()) return;
        for (0..world.denseLayerCount()) |layer_index| {
            if (world.denseLayerLevel(layer_index) != self.level) continue;
            for (0..world.height) |y_usize| {
                const y: u16 = @intCast(y_usize);
                for (0..world.width) |x_usize| {
                    const x: u16 = @intCast(x_usize);
                    if (!world.denseTileBlocksMovement(layer_index, x, y)) continue;
                    self.markWorldCell(world, x, y);
                }
            }
        }
        for (0..world.sparseTileCount()) |sparse_index| {
            if (world.sparseTileLevel(sparse_index) != self.level) continue;
            if (!world.sparseTileBlocksMovement(sparse_index)) continue;
            const cell = world.sparseTileCellCoord(sparse_index);
            self.markWorldCell(world, cell.x, cell.y);
        }
    }

    fn markWorldCell(self: *NavGrid, world: *const WorldSystem, x: u16, y: u16) void {
        const rect = world.cellRect(x, y) orelse return;
        self.markBlockedRectSimd(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h);
    }

    // Re-derives this single level's blocked mask in place from authoritative static
    // sources (level-0 collision bodies plus the world mask). Used by the incremental
    // nav update: a single dirty world cell may overlap several nav cells via its
    // rect, and a nav cell may be kept blocked by an unrelated overlapping rect, so a
    // correct unblock requires recomposing this level's mask rather than clearing the
    // edited cell alone. Bounded by ONE level's cells plus its bodies/sparse columns;
    // never touches another level. Dimensions/version are retained.
    fn remarkStaticMask(self: *NavGrid, data: *const DataSystem, world: ?*const WorldSystem) void {
        @memset(self.blocked.items, false);
        self.blocked_count = 0;
        if (self.level == 0) self.markStaticBodies(data);
        if (world) |world_system| self.markWorldObstacles(world_system);
    }

    fn buildComponents(self: *NavGrid) void {
        @memset(self.components.items, no_component);
        self.component_queue.clearRetainingCapacity();

        var next_component: u32 = 1;
        for (self.blocked.items, 0..) |blocked, index| {
            if (blocked or self.components.items[index] != no_component) continue;
            self.floodComponent(index, next_component);
            next_component +%= 1;
            if (next_component == no_component) next_component = 1;
        }
        // next_component is one past the last label assigned (labels are 1..N).
        self.component_count = next_component -% 1;
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

    fn componentOf(self: *const NavGrid, index: usize) u32 {
        return self.components.items[index];
    }

    // Projects a blocked goal cell to the nearest open cell on this level within a
    // bounded radius. Returns the open index, or null if none is reachable.
    fn projectToNearestOpen(self: *const NavGrid, cell: GridCell, radius: i32) ?usize {
        if (self.indexForCell(cell)) |index| {
            if (!self.isBlockedIndex(index)) return index;
        }
        var ring: i32 = 1;
        while (ring <= radius) : (ring += 1) {
            var dy: i32 = -ring;
            while (dy <= ring) : (dy += 1) {
                var dx: i32 = -ring;
                while (dx <= ring) : (dx += 1) {
                    // Only walk the ring perimeter; interior rings were checked.
                    if (@abs(dx) != ring and @abs(dy) != ring) continue;
                    const candidate = GridCell{ .x = cell.x + dx, .y = cell.y + dy };
                    const index = self.indexForCell(candidate) orelse continue;
                    if (!self.isBlockedIndex(index)) return index;
                }
            }
        }
        return null;
    }
};

// An abstract-graph node: a portal cell on a specific level. Portals sit on the
// open border between two adjacent chunks. Abstract A* searches over these nodes
// plus inter-level link edges, never over raw cells, so its work scales with the
// chunk-border count, not the total cell count.
const PortalNode = struct {
    level: u16,
    cell_index: u32,
    // Chunk this portal belongs to (chunk_y * chunks_x + chunk_x within a level).
    chunk: u32,
};

// One directed abstract edge in CSR form: edge_targets[i] is reached from the
// node owning the offset window, at cost edge_costs[i]. crosses_level marks link
// edges so cross-level traversal can be counted and so refinement knows the first
// segment ends at a link endpoint rather than a same-level portal.
const AbstractEdge = struct {
    target: u32,
    cost: u32,
    crosses_level: bool,
};

// Per-level chunk-portal navigation graph plus inter-level link edges. Owns one
// NavGrid per level (Z-floor) sharing dimensions/cell_size/version. Built once at
// nav rebuild; queried read-only afterward.
const NavGraph = struct {
    allocator: std.mem.Allocator,
    cell_size: f32 = default_cell_size,
    width: usize = 0,
    height: usize = 0,
    chunk_tiles: u16 = default_nav_chunk_tiles,
    version: u32 = 1,
    levels: std.ArrayList(NavGrid) = .empty,

    // Abstract nodes (portals) across all levels, with CSR adjacency.
    portals: std.ArrayList(PortalNode) = .empty,
    portal_offsets: std.ArrayList(u32) = .empty,
    portal_edges: std.ArrayList(AbstractEdge) = .empty,
    // Per-level index into a level-sorted portal-node ordering. A level's portal
    // nodes occupy level_portal_order[level_portal_offsets[level]..[level+1]]. Within
    // a level the run is further grouped by connected component, so a level's
    // component-C portals occupy a contiguous sub-run, and abstract seeding scans only
    // the START component's portals rather than every portal on the level.
    level_portal_order: std.ArrayList(u32) = .empty,
    level_portal_offsets: std.ArrayList(u32) = .empty,
    // CSR over (level, component): component_portal_offsets is a flat
    // [level_component_base[level] + component_count[level] + 1] array of begin/end
    // boundaries into level_portal_order. level_component_base[level] is the start of
    // a level's block (one entry per component plus a trailing terminator), so the
    // portals of component C on a level are level_portal_order over
    // [component_portal_offsets[base+C-1] .. component_portal_offsets[base+C]].
    // Components are 1..N per level (dense), so the index by C is direct.
    component_portal_offsets: std.ArrayList(u32) = .empty,
    level_component_base: std.ArrayList(u32) = .empty,
    // Scratch used only during rebuild to discover edges before CSR compaction.
    edge_scratch: std.ArrayList(EdgeScratch) = .empty,
    // Per-level fast lookup from cell index to portal node index (no_cell when the
    // cell is not a portal). Sized levels x cell_count and rebuilt each build.
    cell_to_portal: std.ArrayList(u32) = .empty,
    // Persistent u32 scratch reused (non-overlapping) by the abstract-graph build
    // helpers for the portal sort order and the CSR/level cursors. Persisting it (vs
    // a per-build allocator.alloc) keeps both the init build and the incremental
    // `applyNavUpdates` rebuild allocation-free once the graph has been built once.
    build_u32_scratch: std.ArrayList(u32) = .empty,

    const EdgeScratch = struct {
        from: u32,
        edge: AbstractEdge,
    };

    fn deinit(self: *NavGraph) void {
        self.build_u32_scratch.deinit(self.allocator);
        self.cell_to_portal.deinit(self.allocator);
        self.edge_scratch.deinit(self.allocator);
        self.level_component_base.deinit(self.allocator);
        self.component_portal_offsets.deinit(self.allocator);
        self.level_portal_offsets.deinit(self.allocator);
        self.level_portal_order.deinit(self.allocator);
        self.portal_edges.deinit(self.allocator);
        self.portal_offsets.deinit(self.allocator);
        self.portals.deinit(self.allocator);
        for (self.levels.items) |*level_grid| level_grid.deinit(self.allocator);
        self.levels.deinit(self.allocator);
        self.* = undefined;
    }

    fn levelCount(self: *const NavGraph) usize {
        return self.levels.items.len;
    }

    fn grid(self: *const NavGraph, level: u16) ?*const NavGrid {
        if (@as(usize, level) >= self.levels.items.len) return null;
        return &self.levels.items[level];
    }

    fn valid(self: *const NavGraph) bool {
        return self.levels.items.len != 0 and self.levels.items[0].valid();
    }

    fn cellCount(self: *const NavGraph) usize {
        return self.width * self.height;
    }

    // Rebuilds every level grid plus the abstract chunk-portal/link graph. The
    // only path that reads static obstacles; afterward queries touch immutable
    // arrays and scratch only.
    fn rebuild(
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

        for (self.levels.items, 0..) |*level_grid, level_index| {
            const level: u16 = @intCast(level_index);
            try level_grid.prepare(self.allocator, level, self.width, self.height, safe_cell_size, self.version);
            // Only level 0 sources DataSystem collision bodies; the demo's
            // entities live on the ground floor. World mask drives every level.
            if (level == 0) level_grid.markStaticBodies(data);
            if (world) |world_system| level_grid.markWorldObstacles(world_system);
            level_grid.buildComponents();
        }

        try self.buildAbstractGraph(world);
    }

    // Incrementally folds a batch of static-obstacle edits into the existing graph
    // WITHOUT a whole-world rebuild. Re-derives the blocked mask + components of only
    // the affected levels (the bounded per-affected-level fallback: true per-chunk
    // portal/CSR surgery would require a per-chunk-addressable portal store, a larger
    // redesign), rebuilds the abstract graph once (bounded by chunk borders), and
    // bumps `version` once so every goal-keyed cache/pending entry keyed on the old
    // version re-solves. Unaffected levels keep their masks and components untouched.
    // `affected_levels` is caller-owned pre-reserved scratch (sized to level count).
    // Allocation contract: this call is allocation-free at steady state — the abstract
    // buffers are reused at the init build's high-water capacity. A genuine topology
    // expansion past that high-water mark (an edit that opens more portals/edges than
    // any prior build) does ONE bounded amortized growth. That is acceptable per
    // coding-standards.md allocation exceptions: this is a cold, event-triggered
    // main-thread path (fires only on nav-changing tile/obstacle events, never per
    // frame), with NavGraph as the explicit owner, and the cost cannot move to init
    // because the new topology is only known when the edit arrives. Returns the batch
    // diagnostics.
    fn applyNavUpdates(
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
        try affected_levels.ensureTotalCapacity(self.allocator, level_count);
        affected_levels.items.len = level_count;
        @memset(affected_levels.items, false);

        // Membership-count distinct dirty chunks and flag affected levels. A tile
        // edit maps to the abstract chunk owning the nav cell at the tile origin;
        // counting is for diagnostics, the per-level remask covers the full rects.
        var affected_level_count: usize = 0;
        for (edits) |edit| {
            if (@as(usize, edit.level) >= level_count) continue;
            if (!affected_levels.items[edit.level]) {
                affected_levels.items[edit.level] = true;
                affected_level_count += 1;
            }
        }
        if (affected_level_count == 0) return stats;
        stats.dirty_chunks = self.countDirtyChunks(world, edits);

        // Past the threshold the per-level relabel degenerates to relabeling every
        // level; flag it loudly rather than silently doing whole-world work.
        const full_relabel = affected_level_count > full_relabel_level_threshold;
        for (self.levels.items, 0..) |*level_grid, level_index| {
            if (!full_relabel and !affected_levels.items[level_index]) continue;
            level_grid.remarkStaticMask(data, world);
            level_grid.buildComponents();
        }

        // The abstract graph is shared global structure (portals/CSR span all levels)
        // and is bounded by chunk borders, not cells, so rebuilding it once after the
        // affected-level masks change is the bounded incremental step.
        try self.buildAbstractGraph(world);

        self.version +%= 1;
        if (self.version == 0) self.version = 1;
        for (self.levels.items) |*level_grid| level_grid.version = self.version;

        stats.incremental_rebuilds = 1;
        stats.version_bumps = 1;
        if (full_relabel) stats.full_relabel = 1;
        return stats;
    }

    // Counts distinct abstract chunks (per level) touched by the dirty edits, using
    // the nav cell at each edited tile's origin. Quadratic in the edit count, which
    // is bounded by the per-step world-event budget; purely diagnostic.
    fn countDirtyChunks(self: *const NavGraph, world: ?*const WorldSystem, edits: []const NavCellEdit) usize {
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

    // Nav cell index of the nav cell containing a world tile's origin corner.
    fn navCellIndexForTile(self: *const NavGraph, world: *const WorldSystem, edit: NavCellEdit) ?usize {
        const level_grid = self.grid(edit.level) orelse return null;
        const rect = world.cellRect(edit.x, edit.y) orelse return null;
        const cell = level_grid.worldToCellClamped(.{ .x = rect.x, .y = rect.y });
        return level_grid.indexForCell(cell);
    }

    fn chunksX(self: *const NavGraph) usize {
        return (self.width + self.chunk_tiles - 1) / self.chunk_tiles;
    }

    fn chunksY(self: *const NavGraph) usize {
        return (self.height + self.chunk_tiles - 1) / self.chunk_tiles;
    }

    fn chunkOf(self: *const NavGraph, cell_index: usize) u32 {
        const x = cell_index % self.width;
        const y = cell_index / self.width;
        const cx = x / self.chunk_tiles;
        const cy = y / self.chunk_tiles;
        return @intCast(cy * self.chunksX() + cx);
    }

    // Discovers portals on open chunk borders, builds CSR intra-level adjacency,
    // then appends inter-level link edges. All work is bounded by chunk borders
    // (O(levels x cells/chunk_tiles)) and the link count, not total cells.
    fn buildAbstractGraph(self: *NavGraph, world: ?*const WorldSystem) !void {
        self.portals.clearRetainingCapacity();
        self.edge_scratch.clearRetainingCapacity();

        const cell_count = self.cellCount();
        const total = cell_count * self.levels.items.len;
        // Cell indices are stored as u32 with no_cell as the sentinel; the
        // NavMemoryBudget gate enforces this long before the cap is reachable.
        std.debug.assert(total < no_cell);
        try self.cell_to_portal.ensureTotalCapacity(self.allocator, total);
        self.cell_to_portal.items.len = total;
        @memset(self.cell_to_portal.items, no_cell);

        // Discover portal cells: a cell on a chunk border whose neighbor across
        // the border is open too. Both border cells become portal nodes.
        for (self.levels.items, 0..) |*level_grid, level_index| {
            const level: u16 = @intCast(level_index);
            try self.discoverLevelPortals(level_grid, level);
        }

        // Intra-level edges: connect portals within the same chunk-pair span and
        // portals reachable within a chunk via the level's connected components.
        try self.buildIntraLevelEdges();
        // Inter-level link edges from persistent world facts.
        if (world) |world_system| try self.buildLinkEdges(world_system);

        try self.compactEdges();
        try self.indexPortalsByLevel();
    }

    // Returns a persistent u32 scratch slice of `len`, growing the backing buffer only
    // when a build needs more than any prior build. The three abstract-graph build
    // helpers use this sequentially (never overlapping), so one buffer serves all.
    fn buildScratch(self: *NavGraph, len: usize) ![]u32 {
        try self.build_u32_scratch.ensureTotalCapacity(self.allocator, len);
        self.build_u32_scratch.items.len = len;
        return self.build_u32_scratch.items;
    }

    // Builds the per-level portal index (level_portal_order grouped by level, then by
    // connected component within each level) plus the (level, component) CSR so
    // abstract seeding scans only the START component's portals on the start level,
    // not every portal on the level or across all levels. Runs after all
    // portals (including late link endpoints) are appended.
    fn indexPortalsByLevel(self: *NavGraph) !void {
        const level_count = self.levels.items.len;
        try self.level_portal_offsets.ensureTotalCapacity(self.allocator, level_count + 1);
        self.level_portal_offsets.items.len = level_count + 1;
        @memset(self.level_portal_offsets.items, 0);
        for (self.portals.items) |portal| {
            self.level_portal_offsets.items[@as(usize, portal.level) + 1] += 1;
        }
        for (1..level_count + 1) |i| {
            self.level_portal_offsets.items[i] += self.level_portal_offsets.items[i - 1];
        }
        try self.level_portal_order.ensureTotalCapacity(self.allocator, self.portals.items.len);
        self.level_portal_order.items.len = self.portals.items.len;
        const cursor = try self.buildScratch(level_count);
        for (0..level_count) |i| cursor[i] = self.level_portal_offsets.items[i];
        for (self.portals.items, 0..) |portal, node_index| {
            const level: usize = portal.level;
            self.level_portal_order.items[cursor[level]] = @intCast(node_index);
            cursor[level] += 1;
        }

        // Per-level base into the flat component CSR: each level contributes
        // (component_count[level] + 1) offset entries (one begin boundary per
        // component 1..N plus a trailing terminator). Component 0 (no_component) never
        // holds a seedable portal, so component C indexes [base + C - 1 .. base + C].
        try self.level_component_base.ensureTotalCapacity(self.allocator, level_count + 1);
        self.level_component_base.items.len = level_count + 1;
        self.level_component_base.items[0] = 0;
        for (self.levels.items, 0..) |*level_grid, i| {
            self.level_component_base.items[i + 1] =
                self.level_component_base.items[i] + level_grid.component_count + 1;
        }
        const total_offsets = self.level_component_base.items[level_count];
        try self.component_portal_offsets.ensureTotalCapacity(self.allocator, total_offsets);
        self.component_portal_offsets.items.len = total_offsets;

        // For each level, order its portal sub-run by component (an in-place sort over
        // the level's slice of level_portal_order) and record each component's
        // [begin, end). The sort keeps seeding's per-component scan contiguous; it is
        // bounded by the level's portal count (chunk-border count), not by cells.
        for (self.levels.items, 0..) |*level_grid, level_index| {
            const level: u16 = @intCast(level_index);
            const begin = self.level_portal_offsets.items[level];
            const end = self.level_portal_offsets.items[@as(usize, level) + 1];
            const base = self.level_component_base.items[level];
            const slots = level_grid.component_count + 1; // entries this level owns
            const offsets = self.component_portal_offsets.items[base .. base + slots];
            const run = self.level_portal_order.items[begin..end];
            const sort_ctx = PortalComponentSort{ .portals = self.portals.items, .components = level_grid.components.items };
            std.sort.pdq(u32, run, sort_ctx, PortalComponentSort.lessThan);
            // After the stable-ordered sort, fill each component's begin boundary by a
            // single pass: offsets[c-1] is where component c starts (relative to the
            // global level_portal_order). Components with no portal get an empty range
            // (begin == end), which the seeding scan skips.
            var cursor_pos: u32 = begin;
            var component: u32 = 1;
            // offsets are indexed 0..slots-1; offsets[c-1] = begin of component c,
            // offsets[c] = end of component c (= begin of c+1).
            while (component <= level_grid.component_count) : (component += 1) {
                offsets[component - 1] = cursor_pos;
                while (cursor_pos < end and
                    level_grid.components.items[self.portals.items[run[cursor_pos - begin]].cell_index] == component)
                {
                    cursor_pos += 1;
                }
            }
            offsets[slots - 1] = cursor_pos; // trailing terminator (== end for present components)
        }
    }

    // Returns the portal node indices on `level` (membership in level_portal_order).
    fn levelPortals(self: *const NavGraph, level: u16) []const u32 {
        if (@as(usize, level) + 1 >= self.level_portal_offsets.items.len) return &.{};
        const begin = self.level_portal_offsets.items[level];
        const end = self.level_portal_offsets.items[@as(usize, level) + 1];
        return self.level_portal_order.items[begin..end];
    }

    // Returns the portal node indices on `level` that belong to connected `component`
    // (a contiguous sub-run of levelPortals), so abstract seeding scans only the start
    // component's portals. An out-of-range component yields an empty slice.
    fn levelComponentPortals(self: *const NavGraph, level: u16, component: u32) []const u32 {
        if (component == no_component) return &.{};
        if (@as(usize, level) + 1 >= self.level_component_base.items.len) return &.{};
        const level_grid = &self.levels.items[level];
        if (component > level_grid.component_count) return &.{};
        const base = self.level_component_base.items[level];
        const begin = self.component_portal_offsets.items[base + component - 1];
        const end = self.component_portal_offsets.items[base + component];
        return self.level_portal_order.items[begin..end];
    }

    // Discovers border portals and the direct cross-border transition edge between
    // each open pair. The transition edge is what lets the abstract search step
    // from one chunk into its neighbor; intra-chunk edges (built later) connect a
    // chunk's portals to each other.
    fn discoverLevelPortals(self: *NavGraph, level_grid: *const NavGrid, level: u16) !void {
        const w = self.width;
        const h = self.height;
        const ct = self.chunk_tiles;
        // Vertical borders (between horizontally adjacent chunks): x = k*ct.
        var bx: usize = ct;
        while (bx < w) : (bx += ct) {
            var y: usize = 0;
            while (y < h) : (y += 1) {
                const left = (y * w) + (bx - 1);
                const right = (y * w) + bx;
                if (level_grid.blocked.items[left] or level_grid.blocked.items[right]) continue;
                try self.addBorderPair(level, @intCast(left), @intCast(right));
            }
        }
        // Horizontal borders (between vertically adjacent chunks): y = k*ct.
        var by: usize = ct;
        while (by < h) : (by += ct) {
            var x: usize = 0;
            while (x < w) : (x += 1) {
                const up = ((by - 1) * w) + x;
                const down = (by * w) + x;
                if (level_grid.blocked.items[up] or level_grid.blocked.items[down]) continue;
                try self.addBorderPair(level, @intCast(up), @intCast(down));
            }
        }
    }

    fn addBorderPair(self: *NavGraph, level: u16, a: u32, b: u32) !void {
        try self.addPortal(level, a);
        try self.addPortal(level, b);
        const node_a = self.portalIndex(level, a).?;
        const node_b = self.portalIndex(level, b).?;
        try self.edge_scratch.append(self.allocator, .{
            .from = node_a,
            .edge = .{ .target = node_b, .cost = cardinal_cost, .crosses_level = false },
        });
        try self.edge_scratch.append(self.allocator, .{
            .from = node_b,
            .edge = .{ .target = node_a, .cost = cardinal_cost, .crosses_level = false },
        });
    }

    fn addPortal(self: *NavGraph, level: u16, cell_index: u32) !void {
        const lookup = @as(usize, level) * self.cellCount() + cell_index;
        if (self.cell_to_portal.items[lookup] != no_cell) return;
        const node_index: u32 = @intCast(self.portals.items.len);
        try self.portals.append(self.allocator, .{
            .level = level,
            .cell_index = cell_index,
            .chunk = self.chunkOf(cell_index),
        });
        self.cell_to_portal.items[lookup] = node_index;
    }

    // Connects portals that share a chunk and connected component on the same
    // level, using octile distance as abstract cost. Grouping by chunk keeps this
    // O(portals-per-chunk^2 x chunks): portal counts scale with chunk perimeter,
    // not cells, so the build stays bounded independent of total cell count.
    fn buildIntraLevelEdges(self: *NavGraph) !void {
        // Order portal indices by (level, chunk) so each chunk's portals form a
        // contiguous run we can connect pairwise without a global quadratic scan.
        const order = try self.buildScratch(self.portals.items.len);
        for (0..self.portals.items.len) |i| order[i] = @intCast(i);
        std.sort.pdq(u32, order, self.portals.items, portalChunkLessThan);

        var i: usize = 0;
        while (i < order.len) {
            const head = self.portals.items[order[i]];
            var j = i + 1;
            while (j < order.len) {
                const next = self.portals.items[order[j]];
                if (next.level != head.level or next.chunk != head.chunk) break;
                j += 1;
            }
            try self.connectChunkPortals(order[i..j]);
            i = j;
        }
    }

    fn connectChunkPortals(self: *NavGraph, group: []const u32) !void {
        for (group, 0..) |from_node, a| {
            const from = self.portals.items[from_node];
            const level_grid = &self.levels.items[from.level];
            const from_component = level_grid.components.items[from.cell_index];
            if (from_component == no_component) continue;
            for (group[a + 1 ..]) |to_node| {
                const to = self.portals.items[to_node];
                if (level_grid.components.items[to.cell_index] != from_component) continue;
                const cost = octileCells(self.width, from.cell_index, to.cell_index);
                try self.edge_scratch.append(self.allocator, .{
                    .from = from_node,
                    .edge = .{ .target = to_node, .cost = cost, .crosses_level = false },
                });
                try self.edge_scratch.append(self.allocator, .{
                    .from = to_node,
                    .edge = .{ .target = from_node, .cost = cost, .crosses_level = false },
                });
            }
        }
    }

    // Resolves persistent LevelLink facts into abstract edges. A link is live only
    // when both endpoint cells are open in their levels' current masks. Each
    // endpoint cell becomes a portal node (if it was not already a border portal)
    // so the abstract search can enter/leave the link.
    fn buildLinkEdges(self: *NavGraph, world: *const WorldSystem) !void {
        for (world.levelLinks()) |link| {
            if (@as(usize, link.level_a) >= self.levels.items.len) continue;
            if (@as(usize, link.level_b) >= self.levels.items.len) continue;
            const grid_a = &self.levels.items[link.level_a];
            const grid_b = &self.levels.items[link.level_b];
            const cell_a = grid_a.indexForCell(.{ .x = link.cell_a.x, .y = link.cell_a.y }) orelse continue;
            const cell_b = grid_b.indexForCell(.{ .x = link.cell_b.x, .y = link.cell_b.y }) orelse continue;
            // Live only if both endpoints are open in their level masks.
            if (grid_a.blocked.items[cell_a] or grid_b.blocked.items[cell_b]) continue;
            try self.addPortal(link.level_a, @intCast(cell_a));
            try self.addPortal(link.level_b, @intCast(cell_b));
            const node_a = self.portalIndex(link.level_a, @intCast(cell_a)).?;
            const node_b = self.portalIndex(link.level_b, @intCast(cell_b)).?;
            const cost = link.traversal_cost +| inter_level_penalty;
            try self.edge_scratch.append(self.allocator, .{
                .from = node_a,
                .edge = .{ .target = node_b, .cost = cost, .crosses_level = true },
            });
            if (link.bidirectional) {
                try self.edge_scratch.append(self.allocator, .{
                    .from = node_b,
                    .edge = .{ .target = node_a, .cost = cost, .crosses_level = true },
                });
            }
        }
    }

    // Compacts edge_scratch into CSR (portal_offsets/portal_edges). A new portal
    // appended by buildLinkEdges after intra-level edges still gets a valid (empty
    // or link-only) adjacency window because offsets cover every portal.
    fn compactEdges(self: *NavGraph) !void {
        const node_count = self.portals.items.len;
        try self.portal_offsets.ensureTotalCapacity(self.allocator, node_count + 1);
        self.portal_offsets.items.len = node_count + 1;
        @memset(self.portal_offsets.items, 0);
        for (self.edge_scratch.items) |scratch| {
            self.portal_offsets.items[scratch.from + 1] += 1;
        }
        for (1..node_count + 1) |i| {
            self.portal_offsets.items[i] += self.portal_offsets.items[i - 1];
        }
        const edge_count = self.edge_scratch.items.len;
        try self.portal_edges.ensureTotalCapacity(self.allocator, edge_count);
        self.portal_edges.items.len = edge_count;
        const cursor = try self.buildScratch(node_count);
        for (0..node_count) |i| cursor[i] = self.portal_offsets.items[i];
        for (self.edge_scratch.items) |scratch| {
            const slot = cursor[scratch.from];
            self.portal_edges.items[slot] = scratch.edge;
            cursor[scratch.from] = slot + 1;
        }
    }

    fn portalIndex(self: *const NavGraph, level: u16, cell_index: u32) ?u32 {
        if (@as(usize, level) >= self.levels.items.len) return null;
        const lookup = @as(usize, level) * self.cellCount() + cell_index;
        const value = self.cell_to_portal.items[lookup];
        return if (value == no_cell) null else value;
    }

    fn keyForWorld(self: *const NavGraph, level: u16, goal: math.Vec2, agent_class: PathAgentClass) ?PathQueryKey {
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

// Orders portal node indices by (level, chunk) so each chunk's portals form a
// contiguous run. Ties break on cell index for a deterministic build.
fn portalChunkLessThan(portals: []const PortalNode, lhs: u32, rhs: u32) bool {
    const a = portals[lhs];
    const b = portals[rhs];
    if (a.level != b.level) return a.level < b.level;
    if (a.chunk != b.chunk) return a.chunk < b.chunk;
    return a.cell_index < b.cell_index;
}

// Orders a level's portal node indices by connected component (then cell index for a
// deterministic build) so each component's portals form a contiguous sub-run that
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

// Octile distance between two cell indices, in the same cardinal/diagonal cost
// units used by the local A*, so abstract and refined costs are comparable.
fn octileCells(width: usize, a: u32, b: u32) u32 {
    const ax: i64 = @intCast(a % width);
    const ay: i64 = @intCast(a / width);
    const bx: i64 = @intCast(b % width);
    const by: i64 = @intCast(b / width);
    const dx: u64 = @intCast(@abs(bx - ax));
    const dy: u64 = @intCast(@abs(by - ay));
    const diagonal = @min(dx, dy);
    const straight = @max(dx, dy) - diagonal;
    const cost = diagonal * diagonal_cost + straight * cardinal_cost;
    return @intCast(@min(cost, @as(u64, std.math.maxInt(u32))));
}

const NavMemoryBudget = struct {
    max_bytes: usize,
    level_count: usize,
    group_field_bytes_per_cell: usize,
    max_group_fields: usize,
    // Capacity terms for the allocations that scale with reserve config rather
    // than cell count.
    max_explored_nodes: usize,
    max_stored_path_cells: usize,
    max_worker_scratch_slots: usize,
    max_cached_results: usize,
    max_solved_requests_per_step: usize,
    max_stitched_path_cells: usize,
    // Abstract chunk-portal graph sizing. The portal/edge buffers grow to their real
    // (obstacle-dependent) size at the init build and are not pre-reserved to a
    // worst case; the gate uses a realistic estimate (portals <= internal-border
    // cells, edges <= portals * a small abstract degree) so large SPARSE worlds pass
    // while a world whose real nav structures exceed the budget still fails loud.
    chunk_tiles: usize,
    link_count: usize,
    // Realistic upper bound on the abstract degree of a portal node (intra-chunk
    // peers + cross-border + link edges). Used to estimate the CSR edge buffers
    // without the pathological per-chunk pairwise (O(cells)) term.
    const abstract_degree: usize = 8;

    // Per SearchScratch direct per-cell entry: slot_g/slot_parent/slot_stamp
    // (3 x u32) plus slot_closed (bool). The direct array is indexed by cell_index,
    // so there is no separate slot_cell column.
    const scratch_slot_bytes: usize = 3 * @sizeOf(u32) + 1;
    // edge_scratch entry (EdgeScratch: u32 from + AbstractEdge{u32,u32,bool}) and the
    // compacted CSR edge entry (AbstractEdge). Both buffers are reserved to the edge
    // worst case.
    const edge_scratch_bytes: usize = @sizeOf(u32) + 2 * @sizeOf(u32) + 1;
    const portal_edge_bytes: usize = 2 * @sizeOf(u32) + 1;
    // PortalNode (u16 level + u32 cell_index + u32 chunk), padded.
    const portal_node_bytes: usize = @sizeOf(u16) + 2 * @sizeOf(u32);

    // Saturating estimate of total nav memory. An overflowing term clamps to
    // maxInt so the gate rejects rather than wrapping to a small value.
    fn requiredBytes(self: NavMemoryBudget, width: usize, height: usize) usize {
        const cell_count = width *| height;
        const levels = @max(@as(usize, 1), self.level_count);
        // Per-level static nav state: components + blocked bitset + flood queue,
        // one set of arrays per level.
        const per_level_bytes = (cell_count *| @sizeOf(u32)) +| cell_count +| (cell_count *| @sizeOf(usize));
        const static_bytes = per_level_bytes *| levels;
        // Group-field registry: max_group_fields x cells x per-cell field bytes.
        const group_registry_bytes = self.max_group_fields *| cell_count *| self.group_field_bytes_per_cell;
        // Per-worker A* scratch is direct per-cell arrays, so each slot is O(cells),
        // not O(node budget). The gate counts it so an over-provisioned slot count on a
        // large world fails loud here rather than degrading at query time. Kept
        // conservative (slot cap, not participant count) so the gate never under-budgets;
        // actual resident scratch is now bounded by participant count (ensureWorkerScratch).
        const scratch_bytes = self.max_worker_scratch_slots *| cell_count *| scratch_slot_bytes;
        // Goal-keyed completed-path cache pool.
        const result_path_bytes = self.max_cached_results *| self.max_stored_path_cells *| @sizeOf(u32);
        // Per-request worker path stripes.
        const worker_path_bytes = self.max_solved_requests_per_step *| self.max_stored_path_cells *| @sizeOf(u32);
        // Goal-keyed stitched-corridor cache plus per-request worker stitched stripes
        // (config-scaled, independent of cell count).
        const stitched_bytes = (self.max_cached_results +| self.max_solved_requests_per_step) *|
            self.max_stitched_path_cells *| @sizeOf(StitchedCell);
        // Realistic abstract chunk-portal graph buffers (cell_to_portal is exact;
        // portals/edges are estimated from border structure, not a per-cell worst case).
        const abstract_bytes = self.abstractGraphBytes(width, height, levels);
        return static_bytes +| group_registry_bytes +|
            scratch_bytes +| result_path_bytes +| worker_path_bytes +| stitched_bytes +|
            abstract_bytes;
    }

    // Realistic bytes for the abstract-graph buffers. The cell_to_portal lookup is
    // genuinely sized to levels * cell_count every build (O(cells), unavoidable). The
    // portal/edge buffers are estimated from structure rather than a pathological
    // worst case: portals <= internal-border cells (NOT all cells), and CSR edges <=
    // portals * abstract_degree (NOT the per-chunk pairwise (4*ct)^2 term that made
    // the estimate ~16*cells and rejected large sparse worlds). This keeps the gate
    // honest for genuinely oversized worlds while letting big sparse worlds build.
    fn abstractGraphBytes(self: NavMemoryBudget, width: usize, height: usize, levels: usize) usize {
        const cell_count = width *| height;
        const ct = @max(@as(usize, 1), self.chunk_tiles);
        const cx = (width + ct - 1) / ct;
        const cy = (height + ct - 1) / ct;
        const internal_vertical = if (cx > 0) cx - 1 else 0;
        const internal_horizontal = if (cy > 0) cy - 1 else 0;
        // Portals live on internal chunk borders (both sides): a structural cap well
        // below cell_count for any non-degenerate chunk size.
        const border_cells_per_level = 2 *| internal_vertical *| height +|
            2 *| internal_horizontal *| width;
        const portals = levels *| border_cells_per_level +| 2 *| self.link_count;
        // CSR edges scale with portals times a small abstract degree, not with cells.
        const edges = portals *| abstract_degree;
        const cell_to_portal_bytes = levels *| cell_count *| @sizeOf(u32);
        // portals buffer + level_portal_order (u32) + portal_offsets (u32) + build
        // scratch (u32).
        const portal_buffers = portals *| (portal_node_bytes +| 3 *| @sizeOf(u32));
        const edge_buffers = edges *| (edge_scratch_bytes +| portal_edge_bytes);
        // (level, component) seeding CSR: component_portal_offsets has at most
        // one entry per portal plus per-level terminators; level_component_base has one
        // entry per level. Bounded by portals + levels, never by cells.
        const component_index_bytes = (portals +| levels) *| @sizeOf(u32) +|
            (levels +| 1) *| @sizeOf(u32);
        return cell_to_portal_bytes +| portal_buffers +| edge_buffers +| component_index_bytes;
    }

    // Pure validation helper: returns the error and stays log-free. A lifecycle
    // diagnostic for an oversized world belongs at the app-layer caller that
    // handles the error, not in this helper.
    fn check(self: NavMemoryBudget, width: usize, height: usize) NavGridError!void {
        if (self.requiredBytes(width, height) > self.max_bytes) return NavGridError.NavWorldTooLarge;
    }
};

const KeySet = struct {
    // Fixed-capacity linear-probe set for pending keys. Full sets drop new inserts
    // instead of allocating during the fixed-step update.
    slots: std.ArrayList(KeySetSlot) = .empty,
    len: usize = 0,

    fn deinit(self: *KeySet, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *KeySet, allocator: std.mem.Allocator, capacity: usize) !void {
        // Free the backing on a shrink so an elastic down-resize releases memory; the
        // probe positions depend on capacity, so a resized set is always rebuilt.
        if (capacity < self.slots.capacity) self.slots.shrinkAndFree(allocator, 0);
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

// Goal-keyed cache. Each slot owns a fixed path buffer so a moving agent can
// derive a forward waypoint from its current cell against the stored path.
const ResultCache = struct {
    slots: std.ArrayList(ResultCacheSlot) = .empty,
    path_cells: std.ArrayList(u32) = .empty,
    path_stride: usize = 0,
    // Per-slot full stitched (level,cell) corridor path: one obstacle-aware, mostly
    // grid-adjacent path per slot (the level changes only across an inter-level
    // link). Walked per-agent on its current level exactly like a plain A* path.
    stitched: std.ArrayList(StitchedCell) = .empty,
    stitched_stride: usize = 0,
    len: usize = 0,
    next_evict: usize = 0,

    fn deinit(self: *ResultCache, allocator: std.mem.Allocator) void {
        self.stitched.deinit(allocator);
        self.path_cells.deinit(allocator);
        self.slots.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *ResultCache, allocator: std.mem.Allocator, capacity: usize, path_stride: usize, stitched_stride: usize) !void {
        self.path_stride = path_stride;
        self.stitched_stride = stitched_stride;
        // Free the backing on a shrink so an elastic down-resize releases memory; slot
        // probe positions and per-slot strides depend on capacity, so a resized cache
        // is always rebuilt (the goal-keyed entries re-solve on next request).
        const total_cells = capacity * path_stride;
        const total_stitched = capacity * stitched_stride;
        if (capacity < self.slots.capacity) self.slots.shrinkAndFree(allocator, 0);
        if (total_cells < self.path_cells.capacity) self.path_cells.shrinkAndFree(allocator, 0);
        if (total_stitched < self.stitched.capacity) self.stitched.shrinkAndFree(allocator, 0);
        try self.slots.ensureTotalCapacity(allocator, capacity);
        self.slots.items.len = capacity;
        try self.path_cells.ensureTotalCapacity(allocator, total_cells);
        self.path_cells.items.len = total_cells;
        @memset(self.path_cells.items, no_cell);
        try self.stitched.ensureTotalCapacity(allocator, total_stitched);
        self.stitched.items.len = total_stitched;
        @memset(self.stitched.items, .{ .level = 0, .cell = no_cell });
        self.clear();
    }

    fn clear(self: *ResultCache) void {
        for (self.slots.items) |*slot| slot.occupied = false;
        self.len = 0;
        self.next_evict = 0;
    }

    fn pathSlice(self: *const ResultCache, slot_index: usize, path_len: usize) []const u32 {
        const base = slot_index * self.path_stride;
        return self.path_cells.items[base .. base + @min(path_len, self.path_stride)];
    }

    fn stitchedSlice(self: *const ResultCache, slot_index: usize, stitched_len: usize) []const StitchedCell {
        const base = slot_index * self.stitched_stride;
        return self.stitched.items[base .. base + @min(stitched_len, self.stitched_stride)];
    }

    fn slotIndex(self: *const ResultCache, key: PathQueryKey) ?usize {
        const capacity = self.slots.items.len;
        if (capacity == 0) return null;
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.result.key, key)) return index;
            if (!slot.occupied and self.len < capacity) return null;
        }
        return null;
    }

    fn find(self: *const ResultCache, key: PathQueryKey) ?PathResult {
        const index = self.slotIndex(key) orelse return null;
        return self.slots.items[index].result;
    }

    // Writes a plain local-solve path (start-to-goal cell order) on `path_level` plus
    // an optional full stitched (level,cell) corridor path. The plain path, when used,
    // is only downsampled when it exceeds the stride; the stitched path is bounded at
    // the solve side and stored whole, so its consecutive cells stay traversable.
    fn put(self: *ResultCache, key: PathQueryKey, path: []const u32, stitched: []const StitchedCell, path_level: u16, stats: *PathfindingStats) void {
        const capacity = self.slots.items.len;
        if (capacity == 0 or self.path_stride == 0) return;
        const slot_index = self.findOrEvictSlot(key, stats);
        const stored_len = self.writePath(slot_index, path);
        const stitched_len = self.writeStitched(slot_index, stitched);
        self.slots.items[slot_index] = .{
            .occupied = true,
            .result = .{ .key = key, .path_len = stored_len, .path_level = path_level, .stitched_len = stitched_len },
        };
    }

    fn writeStitched(self: *ResultCache, slot_index: usize, stitched: []const StitchedCell) usize {
        if (self.stitched_stride == 0) return 0;
        const base = slot_index * self.stitched_stride;
        const copy_len = @min(stitched.len, self.stitched_stride);
        @memcpy(self.stitched.items[base .. base + copy_len], stitched[0..copy_len]);
        return copy_len;
    }

    fn findOrEvictSlot(self: *ResultCache, key: PathQueryKey, stats: *PathfindingStats) usize {
        const capacity = self.slots.items.len;
        const start = hashPathKey(key) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            const slot = self.slots.items[index];
            if (slot.occupied and keysEqual(slot.result.key, key)) return index;
            if (!slot.occupied and self.len < capacity) {
                self.len += 1;
                return index;
            }
        }
        const index = self.next_evict;
        self.next_evict = (self.next_evict + 1) % capacity;
        stats.cache_evictions += 1;
        return index;
    }

    fn writePath(self: *ResultCache, slot_index: usize, path: []const u32) usize {
        const base = slot_index * self.path_stride;
        const dst = self.path_cells.items[base .. base + self.path_stride];
        if (path.len <= self.path_stride) {
            @memcpy(dst[0..path.len], path);
            return path.len;
        }
        // Downsample by stride to preserve forward direction within the budget.
        const stored = self.path_stride;
        for (0..stored) |i| {
            const src_index = (i * (path.len - 1)) / (stored - 1);
            dst[i] = path[src_index];
        }
        return stored;
    }
};

const ResultCacheSlot = struct {
    occupied: bool = false,
    result: PathResult = .{ .key = emptyKey(0), .path_len = 0 },
};

// Per-agent waypoint derivation against a cached path. This is the per-step,
// per-entity refinement promised by the goal-keyed cache.
fn waypointFromPath(grid: *const NavGrid, path: []const u32, start_index: usize) ?math.Vec2 {
    if (path.len == 0) return null;
    if (path.len == 1) return grid.cellCenter(path[0]);
    // Exact match: step to the next cell on the path.
    for (path[0 .. path.len - 1], 0..) |cell, i| {
        if (cell == start_index) return grid.cellCenter(path[i + 1]);
    }
    if (path[path.len - 1] == start_index) return grid.cellCenter(path[path.len - 1]);
    // Off-path: head toward the nearest path cell's successor.
    const start_x: i32 = @intCast(start_index % grid.width);
    const start_y: i32 = @intCast(start_index / grid.width);
    var best_index: usize = 0;
    var best_dist: i64 = std.math.maxInt(i64);
    for (path, 0..) |cell, i| {
        const cx: i32 = @intCast(cell % grid.width);
        const cy: i32 = @intCast(cell / grid.width);
        const ddx: i64 = cx - start_x;
        const ddy: i64 = cy - start_y;
        const dist = ddx * ddx + ddy * ddy;
        if (dist < best_dist) {
            best_dist = dist;
            best_index = i;
        }
    }
    const next = if (best_index + 1 < path.len) best_index + 1 else best_index;
    return grid.cellCenter(path[next]);
}

// Per-agent waypoint derivation against a stitched cross-chunk/cross-level corridor
// path. The stitched path is a single obstacle-aware (level,cell) sequence; within
// each level its cells are grid-adjacent (the level changes only across a link). The
// agent's forward waypoint is found by walking the contiguous run of cells on the
// agent's CURRENT level with the exact same cell-by-cell logic as a plain A* path,
// so the heading is always to a traversable neighbor — never a straight-line cut
// across a blocked cell. Returns null when the agent's level has no run in the path
// (a cross-level agent has not yet reached a level the corridor covers).
fn waypointFromStitched(graph: *const NavGraph, stitched: []const StitchedCell, start_level: u16, start_index: usize) ?math.Vec2 {
    const start_grid = graph.grid(start_level) orelse return null;
    // Scan the path's contiguous runs on the agent's level. An exact match (the agent
    // is on a path cell) walks to that cell's successor within the run. Otherwise fall
    // back to the run holding the nearest cell on this level and walk from there.
    var i: usize = 0;
    var best_run_begin: ?usize = null;
    var best_run_end: usize = 0;
    var best_dist: i64 = std.math.maxInt(i64);
    const start_x: i32 = @intCast(start_index % start_grid.width);
    const start_y: i32 = @intCast(start_index / start_grid.width);
    while (i < stitched.len) {
        if (stitched[i].level != start_level) {
            i += 1;
            continue;
        }
        const run_begin = i;
        while (i < stitched.len and stitched[i].level == start_level) : (i += 1) {}
        const run_end = i; // exclusive
        for (run_begin..run_end) |j| {
            if (stitched[j].cell == start_index) {
                const next = if (j + 1 < run_end) j + 1 else j;
                return start_grid.cellCenter(stitched[next].cell);
            }
            const cx: i32 = @intCast(stitched[j].cell % start_grid.width);
            const cy: i32 = @intCast(stitched[j].cell / start_grid.width);
            const ddx: i64 = cx - start_x;
            const ddy: i64 = cy - start_y;
            const dist = ddx * ddx + ddy * ddy;
            if (dist < best_dist) {
                best_dist = dist;
                best_run_begin = run_begin;
                best_run_end = run_end;
            }
        }
    }
    const run_begin = best_run_begin orelse return null;
    // Off-path on this level: head toward the nearest run cell's successor. The run is
    // grid-adjacent, so the successor is one traversable step from the nearest cell.
    var nearest = run_begin;
    var nearest_dist: i64 = std.math.maxInt(i64);
    for (run_begin..best_run_end) |j| {
        const cx: i32 = @intCast(stitched[j].cell % start_grid.width);
        const cy: i32 = @intCast(stitched[j].cell / start_grid.width);
        const ddx: i64 = cx - start_x;
        const ddy: i64 = cy - start_y;
        const dist = ddx * ddx + ddy * ddy;
        if (dist < nearest_dist) {
            nearest_dist = dist;
            nearest = j;
        }
    }
    const next = if (nearest + 1 < best_run_end) nearest + 1 else nearest;
    return start_grid.cellCenter(stitched[next].cell);
}

// Reverse-Dijkstra managed shared-goal flow field. Built lazily and budgeted
// across frames; an agent samples the flow direction at its current cell.
const GroupFieldState = enum {
    empty,
    building,
    ready,
};

// Bucket count for the integration's monotone bucket queue (Dial's algorithm). Step
// costs are octile {cardinal_cost, diagonal_cost}, so a (current_distance % B) bucket
// holds only cells at exactly current_distance when B > max step cost.
const group_field_buckets: u32 = diagonal_cost + 1;

const GroupField = struct {
    state: GroupFieldState = .empty,
    key: PathQueryKey = emptyKey(0),
    goal_index: usize = 0,
    generation: u32 = 1,
    last_build_step: u32 = 0,
    // Monotone distance cursor for the bucket queue; resumed across budgeted frames.
    current_distance: u32 = 0,
    // Set when (re)built this step so reuse is not double-counted in the same step.
    fresh_this_step: bool = false,
    // Integration cost-to-goal and per-cell flow direction (index into neighbor_dirs,
    // or no_flow). stamps gate costs/flow_dir to the current build without a clear.
    costs: std.ArrayList(u32) = .empty,
    flow_dir: std.ArrayList(u8) = .empty,
    stamps: std.ArrayList(u32) = .empty,
    // Dial's bucket queue: `buckets` holds per-bucket head cell indices; `bucket_next`/
    // `bucket_prev` are intrusive per-cell links so a decrease-key unlinks in O(1). A
    // cell is in at most one bucket; `queued_stamp == generation` marks it queued.
    buckets: std.ArrayList(u32) = .empty,
    bucket_next: std.ArrayList(u32) = .empty,
    bucket_prev: std.ArrayList(u32) = .empty,
    queued_stamp: std.ArrayList(u32) = .empty,

    const no_flow: u8 = 0xff;

    fn deinit(self: *GroupField, allocator: std.mem.Allocator) void {
        self.queued_stamp.deinit(allocator);
        self.bucket_prev.deinit(allocator);
        self.bucket_next.deinit(allocator);
        self.buckets.deinit(allocator);
        self.stamps.deinit(allocator);
        self.flow_dir.deinit(allocator);
        self.costs.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *GroupField, allocator: std.mem.Allocator, cell_count: usize) !void {
        try self.costs.ensureTotalCapacity(allocator, cell_count);
        try self.flow_dir.ensureTotalCapacity(allocator, cell_count);
        try self.stamps.ensureTotalCapacity(allocator, cell_count);
        try self.buckets.ensureTotalCapacity(allocator, group_field_buckets);
        try self.bucket_next.ensureTotalCapacity(allocator, cell_count);
        try self.bucket_prev.ensureTotalCapacity(allocator, cell_count);
        try self.queued_stamp.ensureTotalCapacity(allocator, cell_count);
        self.costs.items.len = cell_count;
        self.flow_dir.items.len = cell_count;
        self.stamps.items.len = cell_count;
        self.buckets.items.len = group_field_buckets;
        self.bucket_next.items.len = cell_count;
        self.bucket_prev.items.len = cell_count;
        self.queued_stamp.items.len = cell_count;
        @memset(self.costs.items, unreachable_cost);
        @memset(self.flow_dir.items, no_flow);
        @memset(self.stamps.items, 0);
        @memset(self.buckets.items, no_cell);
        @memset(self.queued_stamp.items, 0);
        self.state = .empty;
    }

    fn cost(self: *const GroupField, index: usize) u32 {
        return if (self.stamps.items[index] == self.generation) self.costs.items[index] else unreachable_cost;
    }

    fn setCost(self: *GroupField, index: usize, value: u32, dir: u8) void {
        self.stamps.items[index] = self.generation;
        self.costs.items[index] = value;
        self.flow_dir.items[index] = dir;
    }

    fn nextGeneration(self: *GroupField) void {
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.stamps.items, 0);
            @memset(self.queued_stamp.items, 0);
            self.generation = 1;
        }
    }

    // Links `index` (already costed) into its distance bucket at the head.
    fn bucketPush(self: *GroupField, index: usize, distance: u32) void {
        const b = distance % group_field_buckets;
        const head = self.buckets.items[b];
        self.bucket_next.items[index] = head;
        self.bucket_prev.items[index] = no_cell;
        if (head != no_cell) self.bucket_prev.items[head] = @intCast(index);
        self.buckets.items[b] = @intCast(index);
        self.queued_stamp.items[index] = self.generation;
    }

    // Unlinks `index` from its current distance bucket in O(1).
    fn bucketUnlink(self: *GroupField, index: usize, distance: u32) void {
        const prev = self.bucket_prev.items[index];
        const next = self.bucket_next.items[index];
        if (prev != no_cell) {
            self.bucket_next.items[prev] = next;
        } else {
            self.buckets.items[distance % group_field_buckets] = next;
        }
        if (next != no_cell) self.bucket_prev.items[next] = prev;
    }

    fn beginBuild(self: *GroupField, grid: *const NavGrid, key: PathQueryKey, goal_index: usize, step: u32) bool {
        self.key = key;
        self.goal_index = goal_index;
        self.last_build_step = step;
        self.nextGeneration();
        @memset(self.buckets.items, no_cell);
        self.current_distance = 0;
        if (grid.isBlockedIndex(goal_index)) {
            self.state = .empty;
            return false;
        }
        self.setCost(goal_index, 0, no_flow);
        self.bucketPush(goal_index, 0);
        self.state = .building;
        return true;
    }

    // Expands at most `budget` cells of the integration via Dial's monotone bucket
    // queue. Returns true when the field finished. The distance cursor advances only
    // forward, so the build resumes correctly across budgeted frames.
    fn expand(self: *GroupField, grid: *const NavGrid, budget: usize) bool {
        var expansions: usize = 0;
        while (true) {
            if (expansions >= budget) return false;
            const current_index = self.popNext() orelse {
                self.state = .ready;
                return true;
            };
            expansions += 1;
            const current_cost = self.costs.items[current_index];
            const current_x: i32 = @intCast(current_index % grid.width);
            const current_y: i32 = @intCast(current_index / grid.width);
            for (neighbor_dirs, 0..) |dir, dir_index| {
                const nx = current_x + dir.x;
                const ny = current_y + dir.y;
                const next_index = grid.indexForCell(.{ .x = nx, .y = ny }) orelse continue;
                if (grid.isBlockedIndex(next_index)) continue;
                if (dir.diagonal and (grid.isBlockedCell(.{ .x = nx, .y = current_y }) or grid.isBlockedCell(.{ .x = current_x, .y = ny }))) {
                    continue;
                }
                const step_cost = if (dir.diagonal) diagonal_cost else cardinal_cost;
                const candidate = current_cost + step_cost;
                const existing = self.cost(next_index);
                if (candidate < existing) {
                    if (existing != unreachable_cost and self.queued_stamp.items[next_index] == self.generation) {
                        self.bucketUnlink(next_index, existing);
                    }
                    self.setCost(next_index, candidate, oppositeDirIndex(dir_index));
                    self.bucketPush(next_index, candidate);
                } else if (candidate == existing) {
                    // Equal-cost tie: a priority-queue Dijkstra pops predecessors in
                    // (cost, index) order and the FIRST to relax a child sets its flow
                    // direction (strict-improvement rejects later equal relaxations). So
                    // the winning predecessor is the one with the smaller (cost, index).
                    // Replicate that here so the field is byte-identical regardless of
                    // the bucket queue's intra-distance pop order: overwrite only when
                    // the existing recorded predecessor has the SAME cost as `current`
                    // but a strictly higher index (a lower-cost predecessor already won
                    // and a higher-cost one cannot have been processed yet).
                    const existing_parent = self.flowParentIndex(grid, next_index);
                    if (self.cost(existing_parent) == current_cost and existing_parent > @as(usize, current_index)) {
                        self.flow_dir.items[next_index] = oppositeDirIndex(dir_index);
                    }
                }
            }
        }
    }

    // Pops the next-lowest-distance queued cell, advancing the monotone distance cursor
    // over empty buckets. Returns null when the queue is empty.
    fn popNext(self: *GroupField) ?usize {
        var scanned: u32 = 0;
        while (scanned <= group_field_buckets) : (scanned += 1) {
            const b = self.current_distance % group_field_buckets;
            const head = self.buckets.items[b];
            if (head != no_cell) {
                const next = self.bucket_next.items[head];
                self.buckets.items[b] = next;
                if (next != no_cell) self.bucket_prev.items[next] = no_cell;
                self.queued_stamp.items[head] = 0;
                return head;
            }
            // Empty bucket: advance to the next distance. A full wrap with every bucket
            // empty means the queue is drained.
            self.current_distance += 1;
        }
        return null;
    }

    // The cell index of next_index's recorded flow parent (the cell its flow_dir points
    // to), used only for the equal-cost predecessor tie-break.
    fn flowParentIndex(self: *const GroupField, grid: *const NavGrid, next_index: usize) usize {
        const dir = self.flow_dir.items[next_index];
        if (dir == no_flow) return next_index;
        const neighbor = neighbor_dirs[dir];
        const x: i32 = @intCast(next_index % grid.width);
        const y: i32 = @intCast(next_index / grid.width);
        return grid.indexForCell(.{ .x = x + neighbor.x, .y = y + neighbor.y }) orelse next_index;
    }

    // Samples the flow direction at `cell_index`, returning the stepped waypoint.
    fn sample(self: *const GroupField, grid: *const NavGrid, cell_index: usize) ?math.Vec2 {
        if (self.state != .ready and self.state != .building) return null;
        if (self.stamps.items[cell_index] != self.generation) return null;
        const dir = self.flow_dir.items[cell_index];
        if (dir == no_flow) {
            // At the goal cell itself.
            if (cell_index == self.goal_index) return grid.cellCenter(self.goal_index);
            return null;
        }
        const neighbor = neighbor_dirs[dir];
        const cx: i32 = @intCast(cell_index % grid.width);
        const cy: i32 = @intCast(cell_index / grid.width);
        const next = GridCell{ .x = cx + neighbor.x, .y = cy + neighbor.y };
        const next_index = grid.indexForCell(next) orelse return grid.cellCenter(cell_index);
        return grid.cellCenter(next_index);
    }
};

// Budget-bounded A* over abstract portal nodes. Node g-cost/parent/closed use a
// node->slot open-addressed hash with generation stamps, so memory is
// O(max_abstract_nodes), independent of the portal count. `corridor` holds the
// ordered portal node indices of the chosen route (root start-level portal -> goal
// portal); `corridor_link[i]` marks whether corridor[i] was reached from corridor
// [i-1] over an inter-level/teleport LINK edge (a discrete jump) rather than an
// intra-level edge (walkable by local A*). The stitcher refines each non-link span
// with local A* and treats each link span as a single jump.
const AbstractScratch = struct {
    generation: u32 = 1,
    slot_capacity: usize = 0,
    open: std.ArrayList(OpenNode) = .empty,
    slot_node: std.ArrayList(u32) = .empty,
    slot_g: std.ArrayList(u32) = .empty,
    slot_parent: std.ArrayList(u32) = .empty,
    slot_closed: std.ArrayList(bool) = .empty,
    slot_stamp: std.ArrayList(u32) = .empty,
    corridor: std.ArrayList(u32) = .empty,
    corridor_link: std.ArrayList(bool) = .empty,

    fn deinit(self: *AbstractScratch, allocator: std.mem.Allocator) void {
        self.corridor_link.deinit(allocator);
        self.corridor.deinit(allocator);
        self.slot_stamp.deinit(allocator);
        self.slot_closed.deinit(allocator);
        self.slot_parent.deinit(allocator);
        self.slot_g.deinit(allocator);
        self.slot_node.deinit(allocator);
        self.open.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *AbstractScratch, allocator: std.mem.Allocator, max_abstract_nodes: usize) !void {
        const slot_capacity = @max(@as(usize, 16), max_abstract_nodes * 2);
        self.slot_capacity = slot_capacity;
        try self.open.ensureTotalCapacity(allocator, max_abstract_nodes);
        try self.slot_node.ensureTotalCapacity(allocator, slot_capacity);
        try self.slot_g.ensureTotalCapacity(allocator, slot_capacity);
        try self.slot_parent.ensureTotalCapacity(allocator, slot_capacity);
        try self.slot_closed.ensureTotalCapacity(allocator, slot_capacity);
        try self.slot_stamp.ensureTotalCapacity(allocator, slot_capacity);
        try self.corridor.ensureTotalCapacity(allocator, max_abstract_nodes);
        try self.corridor_link.ensureTotalCapacity(allocator, max_abstract_nodes);
        self.slot_node.items.len = slot_capacity;
        self.slot_g.items.len = slot_capacity;
        self.slot_parent.items.len = slot_capacity;
        self.slot_closed.items.len = slot_capacity;
        self.slot_stamp.items.len = slot_capacity;
        @memset(self.slot_stamp.items, 0);
        self.generation = 1;
        self.open.clearRetainingCapacity();
    }

    fn reset(self: *AbstractScratch) void {
        self.open.clearRetainingCapacity();
        self.corridor.clearRetainingCapacity();
        self.corridor_link.clearRetainingCapacity();
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.slot_stamp.items, 0);
            self.generation = 1;
        }
    }

    fn slotFor(self: *AbstractScratch, node: u32) ?usize {
        const capacity = self.slot_capacity;
        if (capacity == 0) return null;
        const start = hashUsize(node) % capacity;
        for (0..capacity) |probe| {
            const index = (start + probe) % capacity;
            if (self.slot_stamp.items[index] == self.generation) {
                if (self.slot_node.items[index] == node) return index;
                continue;
            }
            self.slot_stamp.items[index] = self.generation;
            self.slot_node.items[index] = node;
            self.slot_g.items[index] = unreachable_cost;
            self.slot_parent.items[index] = no_cell;
            self.slot_closed.items[index] = false;
            return index;
        }
        return null;
    }
};

const SearchScratch = struct {
    // One scratch slot per ThreadSystem participant. The local A* node state
    // (g-cost/parent/closed) lives in GENERATION-STAMPED DIRECT per-cell arrays
    // indexed by cell_index: O(1) access with zero hash collisions/probes and good
    // cache locality, in exchange for per-worker storage that is O(cells) (the
    // intended speed-for-bounded-memory trade — the grid is world-bounded). A
    // "reset" bumps the generation rather than clearing the arrays, only @memset-ing
    // the stamps on the rare generation wraparound. `max_explored_nodes` remains the
    // node BUDGET: an explicit expansion counter caps how many distinct cells one
    // solve may stamp, spilling the request to a later frame when exceeded (storage
    // is per-cell but the budget is unchanged).
    generation: u32 = 1,
    cell_count: usize = 0,
    // Per-solve count of distinct cells stamped this generation, bounded by the
    // node budget so a long-range solve spills instead of fully exploring the grid.
    explored: usize = 0,
    explored_budget: usize = 0,
    open: std.ArrayList(OpenNode) = .empty,
    // Direct per-cell arrays, indexed by cell_index (NOT a hash slot). slot_g/parent/
    // closed carry the A* state; slot_stamp marks which generation last touched the
    // cell so stale values from a prior solve read as "untouched".
    slot_g: std.ArrayList(u32) = .empty,
    slot_parent: std.ArrayList(u32) = .empty,
    slot_closed: std.ArrayList(bool) = .empty,
    slot_stamp: std.ArrayList(u32) = .empty,
    // Path reconstruction scratch (cell indices, goal-to-start then reversed).
    path_scratch: std.ArrayList(u32) = .empty,
    // Stitched (level,cell) corridor path assembled from per-segment local A* runs
    // before it is copied into the worker corridor stripe.
    stitched_scratch: std.ArrayList(StitchedCell) = .empty,
    // Worker-private abstract-tier scratch so long-range/cross-level routing stays
    // disjoint per worker, matching the local A* scratch ownership.
    abstract: AbstractScratch = .{},

    fn deinit(self: *SearchScratch, allocator: std.mem.Allocator) void {
        self.abstract.deinit(allocator);
        self.stitched_scratch.deinit(allocator);
        self.path_scratch.deinit(allocator);
        self.slot_stamp.deinit(allocator);
        self.slot_closed.deinit(allocator);
        self.slot_parent.deinit(allocator);
        self.slot_g.deinit(allocator);
        self.open.deinit(allocator);
        self.* = undefined;
    }

    fn reserve(self: *SearchScratch, allocator: std.mem.Allocator, max_explored_nodes: usize, max_stored_path_cells: usize, max_abstract_nodes: usize, max_stitched_path_cells: usize, cell_count: usize) !void {
        try self.abstract.reserve(allocator, max_abstract_nodes);
        // Direct per-cell arrays sized to the grid cell count; cell_index is the
        // array index, so there is no probe and no collision. The node budget stays
        // independent of this storage and is enforced by the expansion counter.
        self.cell_count = cell_count;
        self.explored_budget = max_explored_nodes;
        try self.open.ensureTotalCapacity(allocator, max_explored_nodes);
        try self.slot_g.ensureTotalCapacity(allocator, cell_count);
        try self.slot_parent.ensureTotalCapacity(allocator, cell_count);
        try self.slot_closed.ensureTotalCapacity(allocator, cell_count);
        try self.slot_stamp.ensureTotalCapacity(allocator, cell_count);
        try self.path_scratch.ensureTotalCapacity(allocator, @max(max_explored_nodes, max_stored_path_cells));
        // One extra slot lets a segment overflow be detected before truncation.
        try self.stitched_scratch.ensureTotalCapacity(allocator, max_stitched_path_cells + 1);
        self.slot_g.items.len = cell_count;
        self.slot_parent.items.len = cell_count;
        self.slot_closed.items.len = cell_count;
        self.slot_stamp.items.len = cell_count;
        @memset(self.slot_stamp.items, 0);
        self.generation = 1;
        self.open.clearRetainingCapacity();
    }

    fn reset(self: *SearchScratch) void {
        self.open.clearRetainingCapacity();
        self.explored = 0;
        self.generation +%= 1;
        if (self.generation == 0) {
            @memset(self.slot_stamp.items, 0);
            self.generation = 1;
        }
    }

    // Returns the direct cell slot, freshening it on first touch this generation.
    // Returns null only when freshening a NEW cell would exceed the node budget
    // (the spill cap) — already-touched cells always resolve, so reopening a cell
    // never spills. cell_index must be < cell_count (a valid grid cell).
    fn slotFor(self: *SearchScratch, cell: usize) ?usize {
        if (cell >= self.cell_count) return null;
        if (self.slot_stamp.items[cell] == self.generation) return cell;
        if (self.explored >= self.explored_budget) return null;
        self.explored += 1;
        self.slot_stamp.items[cell] = self.generation;
        self.slot_g.items[cell] = unreachable_cost;
        self.slot_parent.items[cell] = no_cell;
        self.slot_closed.items[cell] = false;
        return cell;
    }
};

pub const PathfindingSystem = struct {
    allocator: std.mem.Allocator,
    capacity: PathfindingCapacity = .{},
    step_counter: u32 = 0,
    graph: NavGraph,
    pending: std.ArrayList(PendingRequest) = .empty,
    prepared_requests: std.ArrayList(PreparedRequest) = .empty,
    solve_results: std.ArrayList(PathSolveResult) = .empty,
    fallback_indices: std.ArrayList(usize) = .empty,
    completed: ResultCache = .{},
    unavailable: KeySet = .{},
    pending_keys: KeySet = .{},
    group_fields: std.ArrayList(GroupField) = .empty,
    // Requested group goal keys this step (declared, never detected).
    group_requests: std.ArrayList(GroupRequestTally) = .empty,
    scratch_slots: std.ArrayList(SearchScratch) = .empty,
    // Grid cell count the per-cell scratch arrays are sized against. Only slots that
    // will actually be indexed get O(cells) arrays (sized lazily by participant count
    // in the threaded path); the rest stay empty until used.
    scratch_cell_count: usize = 0,
    // Per-worker reconstructed paths, written into completed by the main thread
    // after the worker batch finishes.
    solved_paths: std.ArrayList(SolvedPath) = .empty,
    // Per-worker path pool. Each worker owns a disjoint stripe so reconstruction
    // never shares writable storage during the batch.
    worker_path_pool: std.ArrayList(u32) = .empty,
    // Per-solved-request disjoint stitched-path stripe, mirroring worker_path_pool,
    // so a worker's stitched corridor never overwrites another request's during the
    // batch. Plain local solves leave their stripe unused (stitched_len 0).
    worker_stitched_pool: std.ArrayList(StitchedCell) = .empty,
    next_group_evict: usize = 0,
    // Pre-reserved per-level affected-flag scratch for incremental nav updates. Sized
    // to the level count at rebuild so `applyNavUpdates` allocates nothing per edit on
    // the steady path; it is the main-thread post-commit reaction, never a worker.
    affected_levels: std.ArrayList(bool) = .empty,
    // Heap A* is the only worker-driven solver tier, so a single tuner owns its
    // adaptive batch profile.
    fallback_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // Live agent count the per-step/memory caps are currently sized for. Elastic
    // resize keeps this tracking the steering-agent crowd: grows fast for battles,
    // shrinks slowly after sustained low load. Zero until the first reserve.
    effective_agent_capacity: usize = 0,
    // Consecutive steps the agent count has stayed below half the live capacity.
    // Shrink fires only after this reaches capacity_shrink_window (hysteresis).
    low_load_steps: u32 = 0,
    // Reusable safe-point snapshot buffers. A resize wipes the goal-keyed caches
    // (reconstructable) but preserves the non-reconstructable live deferred work and
    // group tally by round-tripping them through these. Allocated only at resize.
    resize_pending_snapshot: std.ArrayList(PendingRequest) = .empty,
    resize_group_snapshot: std.ArrayList(GroupRequestTally) = .empty,

    const SolvedPath = struct {
        key: PathQueryKey,
        offset: usize,
        len: usize,
        // Disjoint corridor stripe (offset/len into worker_stitched_pool) for this
        // solved request. Zero len means a plain local solve with no corridor.
        stitched_offset: usize = 0,
        stitched_len: usize = 0,
        // Level the stored cells index into (start level for cross-level corridors).
        path_level: u16 = 0,
        // Set when the solve routed through the abstract chunk-portal/link graph.
        via_abstract: bool = false,
        // Set when the chosen corridor crosses at least one inter-level link.
        cross_level: bool = false,
    };

    pub fn init(allocator: std.mem.Allocator) PathfindingSystem {
        return .{
            .allocator = allocator,
            .graph = .{ .allocator = allocator },
            .fallback_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *PathfindingSystem) void {
        for (self.scratch_slots.items) |*scratch| scratch.deinit(self.allocator);
        for (self.group_fields.items) |*field| field.deinit(self.allocator);
        self.resize_group_snapshot.deinit(self.allocator);
        self.resize_pending_snapshot.deinit(self.allocator);
        self.affected_levels.deinit(self.allocator);
        self.worker_stitched_pool.deinit(self.allocator);
        self.worker_path_pool.deinit(self.allocator);
        self.solved_paths.deinit(self.allocator);
        self.scratch_slots.deinit(self.allocator);
        self.group_requests.deinit(self.allocator);
        self.group_fields.deinit(self.allocator);
        self.pending_keys.deinit(self.allocator);
        self.unavailable.deinit(self.allocator);
        self.completed.deinit(self.allocator);
        self.fallback_indices.deinit(self.allocator);
        self.solve_results.deinit(self.allocator);
        self.prepared_requests.deinit(self.allocator);
        self.pending.deinit(self.allocator);
        self.graph.deinit();
        self.* = undefined;
    }

    // Derives the per-step/memory caps from an agent count, clamped to [floor,
    // max_agent_budget ceiling]. Population scales the QUEUE and CACHE (frame/pending
    // requests, 4n cached results) so every agent can be queued and every path
    // cached. Per-frame A* SOLVE work does NOT scale with population: the solve and
    // fallback budgets are pinned to a fixed amortization ceiling (clamped down to
    // the population so a tiny crowd caps low), so frame time stays bounded as the
    // army grows. Algorithm/memory sizing (scratch, path strides, chunk size, group
    // field count) is left untouched.
    fn deriveCapacity(base: PathfindingCapacity, agent_count: usize) PathfindingCapacity {
        var cap = base;
        const clamped = std.math.clamp(agent_count, min_capacity_floor, @max(min_capacity_floor, base.max_agent_budget));
        cap.max_frame_requests = clamped;
        cap.max_pending_requests = clamped;
        cap.max_cached_results = clamped *| cached_results_per_agent;
        // Fixed per-frame solve/fallback ceiling, capped down to the population (fallback
        // <= solves). Independent of crowd size; the adaptive tuner operates under it.
        const solve_ceiling = @min(default_max_solves_per_frame, clamped);
        cap.max_solved_requests_per_step = solve_ceiling;
        cap.max_fallback_requests_per_step = solve_ceiling;
        return cap;
    }

    // Effective group-field threshold for the current live capacity: ratio x the
    // in-flight request capacity, clamped up to the configured floor. Scales the
    // group path with the crowd (a few agents at tiny scale, ~1024 near the ceiling)
    // without a knob to bump.
    fn groupFieldThreshold(self: *const PathfindingSystem) usize {
        const ratio_term: usize = @intFromFloat(@floor(self.capacity.group_field_agent_ratio * @as(f32, @floatFromInt(self.capacity.max_pending_requests))));
        return @max(self.capacity.min_group_field_agents, ratio_term);
    }

    pub fn reserve(self: *PathfindingSystem, capacity: PathfindingCapacity) !void {
        // Reserve modestly for the floor agent count, not the full ceiling, so the
        // elastic path can later grow and shrink. The ceiling/ratio/window knobs are
        // retained in self.capacity; per-step caps are derived and grown on demand.
        try self.applyDerivedCapacity(capacity, min_capacity_floor);
    }

    // Sizes every pool from caps derived for `agent_count`. Used by reserve() at init
    // and by adjustCapacityForAgentCount() at the safe point. ArrayList pools grow
    // amortized and shrink-and-free; the open-addressed caches are re-reserved (which
    // wipes them — reconstructable, and resizes are rare under hysteresis). The
    // caller is responsible for preserving any live cross-step state across the wipe.
    fn applyDerivedCapacity(self: *PathfindingSystem, base: PathfindingCapacity, agent_count: usize) !void {
        const capacity = deriveCapacity(base, agent_count);
        self.capacity = capacity;
        self.effective_agent_capacity = capacity.max_pending_requests;
        try resizeArrayList(PendingRequest, &self.pending, self.allocator, capacity.max_pending_requests);
        try resizeArrayList(PreparedRequest, &self.prepared_requests, self.allocator, capacity.max_frame_requests);
        try resizeArrayList(PathSolveResult, &self.solve_results, self.allocator, capacity.max_solved_requests_per_step);
        try resizeArrayList(usize, &self.fallback_indices, self.allocator, capacity.max_solved_requests_per_step);
        try resizeArrayList(SolvedPath, &self.solved_paths, self.allocator, capacity.max_solved_requests_per_step);
        try self.completed.reserve(self.allocator, capacity.max_cached_results, capacity.max_stored_path_cells, capacity.max_stitched_path_cells);
        try self.unavailable.reserve(self.allocator, capacity.max_cached_results);
        try self.pending_keys.reserve(self.allocator, capacity.max_pending_requests * 2);
        try self.group_fields.ensureTotalCapacity(self.allocator, capacity.max_group_fields);
        while (self.group_fields.items.len < capacity.max_group_fields) {
            self.group_fields.appendAssumeCapacity(.{});
        }
        try resizeArrayList(GroupRequestTally, &self.group_requests, self.allocator, capacity.max_solved_requests_per_step);
        const scratch_slots = @max(@as(usize, 1), capacity.max_worker_scratch_slots);
        try self.scratch_slots.ensureTotalCapacity(self.allocator, scratch_slots);
        while (self.scratch_slots.items.len < scratch_slots) {
            self.scratch_slots.appendAssumeCapacity(.{});
        }
        // One disjoint path stripe per solved request this step (indexed by the
        // dense fallback position), so workers never overwrite each other's
        // reconstructed paths even when one worker solves several requests.
        const pool_cells = capacity.max_solved_requests_per_step * capacity.max_stored_path_cells;
        try resizeFilledArrayList(u32, &self.worker_path_pool, self.allocator, pool_cells, no_cell);
        const pool_stitched = capacity.max_solved_requests_per_step * capacity.max_stitched_path_cells;
        try resizeFilledArrayList(StitchedCell, &self.worker_stitched_pool, self.allocator, pool_stitched, .{ .level = 0, .cell = no_cell });
    }

    // Adjusts the live capacity toward the agent count at the pre-dispatch safe
    // point: after the previous frame's results were published and before this
    // step's accept/solve, on the single thread, with no in-flight worker indices or
    // pool offsets. Grows fast (amortized ~2x) for a battle; shrinks only after a
    // sustained low-load window (hysteresis). The per-step solve loop never allocates
    // because capacity is already adequate by the time it runs.
    //
    // Index/pointer-stability invariant verified for every resized pool: at this
    // point the per-step scratch pools (prepared_requests, solve_results,
    // fallback_indices, solved_paths, worker_path_pool, worker_stitched_pool) are
    // empty/cleared from last step's prepare*, so no live offset spans the resize.
    // pending/pending_keys/group_requests/completed/unavailable hold cross-step state;
    // resize wipes the reconstructable caches and round-trips the non-reconstructable
    // pending deferred work + group tally through reusable snapshots, then rebuilds
    // pending_keys from the restored pending. scratch_slots are participant-derived
    // (ensureWorkerScratch) and not touched here. No worker is running.
    fn adjustCapacityForAgentCount(self: *PathfindingSystem, agent_count: usize) !void {
        if (self.effective_agent_capacity == 0) return; // not reserved yet
        const target = deriveCapacity(self.capacity, agent_count).max_pending_requests;
        const current = self.effective_agent_capacity;
        if (target > current) {
            self.low_load_steps = 0;
            // Amortized grow: at least double, clamped to the ceiling, so one realloc
            // covers many future spawns.
            const grown = @min(@max(target, current *| 2), @max(min_capacity_floor, self.capacity.max_agent_budget));
            try self.resizePreservingLiveState(grown);
            return;
        }
        // Shrink only after the agent count stays below half capacity for the window.
        if (agent_count * 2 < current) {
            self.low_load_steps +|= 1;
            if (self.low_load_steps >= self.capacity.capacity_shrink_window) {
                self.low_load_steps = 0;
                try self.resizePreservingLiveState(target);
            }
        } else {
            self.low_load_steps = 0;
        }
    }

    // Re-sizes all pools to `agent_count` while preserving the non-reconstructable
    // live deferred-work queue and group tally. The goal-keyed caches are wiped (a
    // resize behaves like a routine cache miss; re-requests re-solve), exactly as a
    // nav rebuild already does.
    fn resizePreservingLiveState(self: *PathfindingSystem, agent_count: usize) !void {
        self.resize_pending_snapshot.clearRetainingCapacity();
        try self.resize_pending_snapshot.ensureTotalCapacity(self.allocator, self.pending.items.len);
        self.resize_pending_snapshot.appendSliceAssumeCapacity(self.pending.items);
        self.resize_group_snapshot.clearRetainingCapacity();
        try self.resize_group_snapshot.ensureTotalCapacity(self.allocator, self.group_requests.items.len);
        self.resize_group_snapshot.appendSliceAssumeCapacity(self.group_requests.items);

        try self.applyDerivedCapacity(self.capacity, agent_count);

        // Restore live deferred work (dropping any beyond the new, smaller capacity),
        // rebuild pending_keys to match, and restore the surviving group tally.
        self.pending.clearRetainingCapacity();
        const keep_pending = @min(self.resize_pending_snapshot.items.len, self.pending.capacity);
        self.pending.appendSliceAssumeCapacity(self.resize_pending_snapshot.items[0..keep_pending]);
        self.pending_keys.clear();
        for (self.pending.items) |pending_request| _ = self.pending_keys.insert(pending_request.key);
        self.group_requests.clearRetainingCapacity();
        const keep_group = @min(self.resize_group_snapshot.items.len, self.group_requests.capacity);
        self.group_requests.appendSliceAssumeCapacity(self.resize_group_snapshot.items[0..keep_group]);
    }

    pub fn rebuildStaticNavGrid(self: *PathfindingSystem, data: *const DataSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) !void {
        try self.rebuildStaticNavGridWithWorld(data, null, bounds_width, bounds_height, cell_size);
    }

    pub fn rebuildStaticNavGridWithWorld(
        self: *PathfindingSystem,
        data: *const DataSystem,
        world: ?*const WorldSystem,
        bounds_width: f32,
        bounds_height: f32,
        cell_size: f32,
    ) !void {
        if (self.scratch_slots.items.len == 0) {
            try self.reserve(self.capacity);
        }
        const level_count: usize = if (world) |world_system| @max(@as(usize, 1), world_system.levelCount()) else 1;
        const link_count: usize = if (world) |world_system| world_system.levelLinks().len else 0;
        const budget = NavMemoryBudget{
            .max_bytes = self.capacity.max_nav_memory_bytes,
            .level_count = level_count,
            // group field per-cell: cost(u32) + flow(u8) + stamp(u32) + the Dial's
            // bucket-queue links bucket_next/bucket_prev(u32) + queued_stamp(u32).
            .group_field_bytes_per_cell = @sizeOf(u32) + 1 + 4 * @sizeOf(u32),
            .max_group_fields = self.capacity.max_group_fields,
            .max_explored_nodes = self.capacity.max_explored_nodes,
            .max_stored_path_cells = self.capacity.max_stored_path_cells,
            .max_worker_scratch_slots = @max(@as(usize, 1), self.capacity.max_worker_scratch_slots),
            .max_cached_results = self.capacity.max_cached_results,
            .max_solved_requests_per_step = self.capacity.max_solved_requests_per_step,
            .max_stitched_path_cells = self.capacity.max_stitched_path_cells,
            .chunk_tiles = @max(@as(usize, 1), self.capacity.nav_chunk_tiles),
            .link_count = link_count,
        };
        try self.graph.rebuild(data, world, bounds_width, bounds_height, cell_size, self.capacity.nav_chunk_tiles, budget);
        // The init buildAbstractGraph (inside rebuild) grows the portal/edge buffers to
        // their real size; clearRetainingCapacity keeps that high-water mark. A later
        // incremental applyNavUpdates within the high-water mark allocates nothing; a
        // genuine topology expansion past it does one bounded amortized growth (a cold,
        // event-triggered main-thread path — see applyNavUpdates). No O(cells)
        // pre-reserve, so large SPARSE worlds (few portals) stay cheap and pass the gate.
        const cell_count = self.graph.cellCount();
        for (self.group_fields.items) |*field| {
            try field.reserve(self.allocator, cell_count);
        }
        // Per-cell A* scratch is O(cells) per slot, but only participant-count slots
        // (~workers+1) are ever indexed. Size slot 0 here (the serial updateSerial
        // path) and defer the rest to ensureWorkerScratch, called from the threaded
        // update once the participant count is known — so resident scratch is bounded
        // by participants, not the slot cap.
        self.scratch_cell_count = cell_count;
        if (self.scratch_slots.items.len != 0) {
            try self.scratch_slots.items[0].reserve(self.allocator, self.capacity.max_explored_nodes, self.capacity.max_stored_path_cells, self.capacity.max_abstract_nodes, self.capacity.max_stitched_path_cells, cell_count);
        }
        // Pre-reserve the per-level affected-flag scratch so a steady-path
        // applyNavUpdates allocates nothing per edit.
        try self.affected_levels.ensureTotalCapacity(self.allocator, self.graph.levelCount());
        self.affected_levels.items.len = self.graph.levelCount();
        // Grid versions are part of query keys. A rebuild invalidates pending
        // work and caches instead of trying to remap old requests onto new cells.
        self.clearRuntimeState();
    }

    // Incrementally folds a batch of static-obstacle edits into the existing nav
    // graph at the main-thread post-commit reaction point (never on a worker). Only
    // affected levels' masks/components are recomputed; the abstract graph is rebuilt
    // once; `nav_version` bumps once so goal-keyed caches/pending entries re-solve.
    // Runtime request/result state is cleared (caches invalidate on the version bump),
    // while group fields are dropped to .empty so a stale field is never sampled. No
    // whole-world rebuild and no scratch reallocation occur on the steady path.
    pub fn applyNavUpdates(
        self: *PathfindingSystem,
        data: *const DataSystem,
        world: ?*const WorldSystem,
        edits: []const NavCellEdit,
    ) !NavUpdateStats {
        const stats = try self.graph.applyNavUpdates(
            data,
            world,
            edits,
            &self.affected_levels,
            self.capacity.nav_full_relabel_level_threshold,
        );
        if (stats.version_bumps != 0) {
            // The version bump invalidated every goal-keyed key; drop stale work and
            // group fields so the next request re-solves against the new mask.
            self.clearTransientRequestsRetainingFields();
            for (self.group_fields.items) |*field| field.state = .empty;
            self.next_group_evict = 0;
        }
        return stats;
    }

    pub fn clearRuntimeState(self: *PathfindingSystem) void {
        self.pending.clearRetainingCapacity();
        self.prepared_requests.clearRetainingCapacity();
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        self.solved_paths.clearRetainingCapacity();
        self.group_requests.clearRetainingCapacity();
        self.completed.clear();
        self.unavailable.clear();
        self.pending_keys.clear();
        for (self.group_fields.items) |*field| field.state = .empty;
        self.next_group_evict = 0;
    }

    // Clears request/result state while keeping the nav grid and group fields.
    pub fn clearTransientRequestsRetainingFields(self: *PathfindingSystem) void {
        self.pending.clearRetainingCapacity();
        self.prepared_requests.clearRetainingCapacity();
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        self.solved_paths.clearRetainingCapacity();
        self.group_requests.clearRetainingCapacity();
        self.completed.clear();
        self.unavailable.clear();
        self.pending_keys.clear();
    }

    pub fn statusForWorld(self: *const PathfindingSystem, start_level: u16, start: math.Vec2, goal_level: u16, goal: math.Vec2, agent_class: PathAgentClass) PathView {
        const key = self.graph.keyForWorld(goal_level, goal, agent_class) orelse return .{ .status = .unavailable };
        const start_grid = self.graph.grid(start_level) orelse return .{ .status = .unavailable };
        const start_cell = start_grid.worldToCellClamped(start);
        const start_index = start_grid.indexForCell(start_cell) orelse return .{ .status = .unavailable };
        return self.statusForKeyAndStart(key, start_level, start_index);
    }

    pub fn statusForEntityWorld(self: *const PathfindingSystem, entity: EntityId, start_level: u16, start: math.Vec2, goal_level: u16, goal: math.Vec2, agent_class: PathAgentClass) PathView {
        _ = entity;
        return self.statusForWorld(start_level, start, goal_level, goal, agent_class);
    }

    pub fn statusForKey(self: *const PathfindingSystem, key: PathQueryKey) PathView {
        const goal_grid = self.graph.grid(key.goal_level) orelse return .{ .status = .unavailable };
        if (goal_grid.indexForCell(key.goal)) |goal_index| {
            return self.statusForKeyAndStart(key, key.goal_level, goal_index);
        }
        return self.statusForKeyAndStart(key, key.goal_level, 0);
    }

    // Group field first (when ready), then individual cache, then negative cache,
    // then pending. Missing means the caller may enqueue a request. The start cell
    // is interpreted on `start_level`; cached corridors derive against the level
    // their stored cells index into (start level for cross-level corridors).
    fn statusForKeyAndStart(self: *const PathfindingSystem, key: PathQueryKey, start_level: u16, start_index: usize) PathView {
        if (self.findGroupField(key)) |field| {
            if (field.state == .ready) {
                // The group field is built on the goal level. Sample at the agent's
                // cell when it is on that level; otherwise the field is not its
                // refinement (a cross-level agent uses the individual corridor).
                if (start_level == key.goal_level) {
                    if (self.graph.grid(key.goal_level)) |goal_grid| {
                        if (field.sample(goal_grid, start_index)) |waypoint| {
                            return .{ .status = .available, .next_waypoint = waypoint, .path_len = 2 };
                        }
                    }
                    return .{ .status = .unavailable };
                }
            }
        }
        if (self.completed.slotIndex(key)) |slot| {
            const result = self.completed.slots.items[slot].result;
            const path_grid = self.graph.grid(result.path_level) orelse return .{ .status = .unavailable };
            const path = self.completed.pathSlice(slot, result.path_len);
            // Abstract chunk/cross-level corridor: a full obstacle-aware stitched
            // (level,cell) path. Walk the run on the agent's CURRENT level cell by
            // cell (every consecutive pair is a traversable neighbor), so multi-hop
            // and cross-floor routes converge without any straight-line cut.
            if (result.stitched_len != 0) {
                const stitched = self.completed.stitchedSlice(slot, result.stitched_len);
                if (waypointFromStitched(&self.graph, stitched, start_level, start_index)) |waypoint| {
                    return .{ .status = .available, .next_waypoint = waypoint, .path_len = result.stitched_len };
                }
                // Agent's level is not yet covered by the corridor (e.g. it has not
                // reached the start-level run): steer toward the stored first cell.
                if (path.len != 0) {
                    return .{ .status = .available, .next_waypoint = path_grid.cellCenter(path[0]), .path_len = result.path_len };
                }
                return .{ .status = .unavailable };
            }
            // Plain same-component local solve: derive a forward waypoint from the
            // agent's current cell against the stored path.
            if (result.path_level == start_level) {
                if (waypointFromPath(path_grid, path, start_index)) |waypoint| {
                    return .{ .status = .available, .next_waypoint = waypoint, .path_len = result.path_len };
                }
            }
            if (path.len != 0) {
                return .{ .status = .available, .next_waypoint = path_grid.cellCenter(path[0]), .path_len = result.path_len };
            }
            return .{ .status = .unavailable };
        }
        if (self.unavailable.contains(key)) return .{ .status = .unavailable };
        if (self.pending_keys.contains(key)) return .{ .status = .pending };
        return .{ .status = .missing };
    }

    // Lazily sizes the per-cell A* scratch arrays for slots [0, slot_count) to the
    // current grid cell count. Idempotent: a slot already sized for this cell count is
    // skipped, so this is a no-op after the first post-rebuild frame, preserving the
    // allocation-free-after-warmup contract. Called from the single-threaded point in
    // the threaded update before dispatch (allocation is safe there).
    fn ensureWorkerScratch(self: *PathfindingSystem, slot_count: usize) !void {
        const limit = @min(slot_count, self.scratch_slots.items.len);
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            const scratch = &self.scratch_slots.items[i];
            if (scratch.cell_count == self.scratch_cell_count) continue;
            try scratch.reserve(self.allocator, self.capacity.max_explored_nodes, self.capacity.max_stored_path_cells, self.capacity.max_abstract_nodes, self.capacity.max_stitched_path_cells, self.scratch_cell_count);
        }
    }

    pub fn update(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, thread_system: *ThreadSystem, config: PathfindingConfig) !PathfindingStats {
        self.step_counter +%= 1;
        // Safe-point elastic resize: single-threaded, after last frame's publish and
        // before any accept/solve, so no live worker index or pool offset spans it.
        try self.adjustCapacityForAgentCount(agent_count);
        var accept_timer = PhaseTimer.begin();
        var stats = self.acceptRequests(requests.mergedItems());
        stats.accept_ns = accept_timer.lap();
        var group_timer = PhaseTimer.begin();
        self.serviceGroupFields(&stats);
        stats.group_service_ns = group_timer.lap();
        const solve_count = self.effectiveSolveLimit(config);
        if (solve_count == 0) {
            stats.pending_requests = self.pending.items.len;
            stats.deferred_requests = self.pending.items.len;
            return stats;
        }
        var solve_timer = PhaseTimer.begin();
        var system_config = config;
        self.prepareSolveBuffers(solve_count);
        self.prepareFallbackIndices(solve_count, self.effectiveFallbackLimit(system_config), &stats);

        if (self.fallback_indices.items.len != 0) {
            if (system_config.adaptive and system_config.fallback_adaptive_tuner == null and system_config.items_per_range == null) {
                system_config.fallback_adaptive_tuner = &self.fallback_tuner;
            }
            const participants = thread_system.participantSlotCount();
            if (participants > self.scratch_slots.items.len) return error.PathfindingScratchCapacityExceeded;
            // Single-threaded point: size per-cell scratch for the slots this batch
            // will actually index (no-op after the first post-rebuild frame).
            try self.ensureWorkerScratch(participants);
            self.resetSolvedPaths();
            var context = SolveJobContext{ .system = self };
            stats.fallback_batch = thread_system.parallelForWithOptions(self.fallback_indices.items.len, &context, solveFallbackJob, .{
                .items_per_range = system_config.items_per_range,
                .max_worker_threads = system_config.max_worker_threads,
                .range_alignment_items = pathfinding_range_alignment_items,
                .adaptive = system_config.adaptive,
                .adaptive_tuner = system_config.fallback_adaptive_tuner,
            });
        }
        stats.solve_ns = solve_timer.lap();

        var publish_timer = PhaseTimer.begin();
        self.publishSolvedResults(solve_count, &stats);
        self.compactPendingAfterSolve(solve_count);
        stats.publish_ns = publish_timer.lap();
        stats.pending_requests = self.pending.items.len;
        stats.deferred_requests = self.pending.items.len;
        return stats;
    }

    pub fn updateSerial(self: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig) !PathfindingStats {
        self.step_counter +%= 1;
        // Safe-point elastic resize (see update()): nothing live spans this point.
        try self.adjustCapacityForAgentCount(agent_count);
        var accept_timer = PhaseTimer.begin();
        var stats = self.acceptRequests(requests.mergedItems());
        stats.accept_ns = accept_timer.lap();
        var group_timer = PhaseTimer.begin();
        self.serviceGroupFields(&stats);
        stats.group_service_ns = group_timer.lap();
        const solve_count = self.effectiveSolveLimit(config);
        if (solve_count == 0) {
            stats.pending_requests = self.pending.items.len;
            stats.deferred_requests = self.pending.items.len;
            return stats;
        }
        var solve_timer = PhaseTimer.begin();
        self.prepareSolveBuffers(solve_count);
        self.prepareFallbackIndices(solve_count, self.effectiveFallbackLimit(config), &stats);
        if (self.fallback_indices.items.len != 0) {
            if (self.scratch_slots.items.len == 0) return error.PathfindingScratchCapacityExceeded;
            self.resetSolvedPaths();
            const scratch = &self.scratch_slots.items[0];
            for (self.fallback_indices.items, 0..) |pending_index, path_slot| {
                self.solve_results.items[pending_index] = solveOne(self, pending_index, scratch, path_slot);
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
        stats.solve_ns = solve_timer.lap();
        var publish_timer = PhaseTimer.begin();
        self.publishSolvedResults(solve_count, &stats);
        self.compactPendingAfterSolve(solve_count);
        stats.publish_ns = publish_timer.lap();
        stats.pending_requests = self.pending.items.len;
        stats.deferred_requests = self.pending.items.len;
        return stats;
    }

    fn resetSolvedPaths(self: *PathfindingSystem) void {
        self.solved_paths.clearRetainingCapacity();
        for (0..self.solve_results.items.len) |_| {
            self.solved_paths.appendAssumeCapacity(.{ .key = emptyKey(self.graph.version), .offset = 0, .len = 0 });
        }
    }

    // Acceptance is the only stage that mutates the pending-key set. Cached hits
    // never enter pending work. Group-declared requests are recorded so a field
    // can be (re)built lazily; they still get a per-agent fallback while building.
    fn acceptRequests(self: *PathfindingSystem, requests: []const PathRequest) PathfindingStats {
        var stats = PathfindingStats{};
        // Cross-step decaying accumulation: halve every carried tally before this
        // step's requests fold in, so a SUSTAINED shared goal accumulates toward the
        // threshold (~2x per-step intake at equilibrium) while a transient burst
        // decays back to zero. Runs every step (even with no requests) so a crowd
        // that stops requesting decays away. Zero-count tallies are compacted after
        // threshold-service in serviceGroupFields.
        for (self.group_requests.items) |*tally| tally.count /= 2;
        if (requests.len == 0 or !self.graph.valid()) return stats;
        self.prepareRequestKeys(requests, &stats);
        for (self.prepared_requests.items) |prepared| {
            if (prepared.kind == .group) {
                self.recordGroupRequest(prepared.key);
                // A ready group field is the authoritative answer ONLY for members
                // already on the goal level: the field is built on the goal level
                // and an off-level member cannot sample it. A ready field for an
                // off-level member must NOT short-circuit, or that member would stall
                // forever; it falls through to individual cross-level acceptance and
                // gets its own corridor across the link.
                if (prepared.start_level == prepared.key.goal_level) {
                    if (self.findGroupField(prepared.key)) |field| {
                        if (field.state == .ready) {
                            stats.group_field_samples += 1;
                            stats.duplicate_requests += 1;
                            continue;
                        }
                    }
                }
            }
            if (self.completed.find(prepared.key) != null) {
                stats.duplicate_requests += 1;
                stats.cache_hits += 1;
                stats.available_results += 1;
                continue;
            }
            if (self.unavailable.contains(prepared.key)) {
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
            // Nearest-open goal projection happens once at acceptance, on the GOAL
            // level, so the counter is deterministic and the worker solve reuses it.
            const goal_grid = self.graph.grid(prepared.key.goal_level);
            var goal_index: usize = no_parent;
            if (goal_grid) |grid| {
                if (grid.indexForCell(prepared.key.goal)) |index| {
                    if (grid.isBlockedIndex(index)) {
                        if (grid.projectToNearestOpen(prepared.key.goal, default_goal_projection_radius)) |projected| {
                            goal_index = projected;
                            stats.goal_projected += 1;
                        }
                    } else {
                        goal_index = index;
                    }
                }
            }
            self.pending.appendAssumeCapacity(.{
                .entity = prepared.entity,
                .key = prepared.key,
                .start_level = prepared.start_level,
                .start = prepared.start,
                .goal_index = goal_index,
            });
            _ = self.pending_keys.insert(prepared.key);
            stats.accepted_requests += 1;
        }
        stats.pending_requests = self.pending.items.len;
        return stats;
    }

    fn recordGroupRequest(self: *PathfindingSystem, key: PathQueryKey) void {
        for (self.group_requests.items) |*existing| {
            if (keysEqual(existing.key, key)) {
                existing.count += 1;
                return;
            }
        }
        if (self.group_requests.items.len < self.group_requests.capacity) {
            self.group_requests.appendAssumeCapacity(.{ .key = key, .count = 1 });
        }
    }

    // Builds/advances managed shared-goal flow fields for declared group goals.
    // Lazy on first request, throttled on goal-cell change, budgeted per frame.
    // The min_group_field_agents threshold is checked against the cross-step
    // accumulator (acceptRequests), so it reflects SUSTAINED shared-goal demand
    // (~2x per-step intake at equilibrium), not a single-step burst. Raising
    // min_group_field_agents for scale also requires raising the per-step request
    // budget (max_frame_requests / max_solved_requests_per_step) so the accumulator
    // can actually reach the threshold.
    fn serviceGroupFields(self: *PathfindingSystem, stats: *PathfindingStats) void {
        if (!self.graph.valid()) return;
        // Threshold scales with the live capacity (ratio x in-flight request cap,
        // floored), so the group path engages at a fixed crowd fraction at any scale.
        const threshold = self.groupFieldThreshold();
        // Advance any field still building, on its own goal level.
        for (self.group_fields.items) |*field| {
            field.fresh_this_step = false;
            if (field.state == .building) {
                if (self.graph.grid(field.key.goal_level)) |grid| {
                    _ = field.expand(grid, self.capacity.group_field_build_budget);
                }
            }
        }
        for (self.group_requests.items) |tally| {
            // Only build/maintain a shared flow field once sustained demand for the
            // same goal amortizes its O(cells) build. Smaller groups already took an
            // individual A* solve during acceptance, so a handful of agents never pay
            // the flow-field cost — pathfinding stays cheap at low agent counts and
            // the field engages only at crowd scale.
            if (tally.count < threshold) continue;
            self.ensureGroupField(tally.key, stats);
        }
        // Compact out tallies that decayed to zero this step (they received no new
        // request to keep them alive), so a transient crowd releases its slot.
        var i: usize = 0;
        while (i < self.group_requests.items.len) {
            if (self.group_requests.items[i].count == 0) {
                _ = self.group_requests.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn ensureGroupField(self: *PathfindingSystem, key: PathQueryKey, stats: *PathfindingStats) void {
        if (self.group_fields.items.len == 0) return;
        // Exact goal cell already has a field: reuse it (build is still advancing
        // if it has not finished). The goal did not cross into a new cell.
        if (self.findGroupFieldMut(key)) |field| {
            if (!field.fresh_this_step) stats.group_field_reuses += 1;
            return;
        }
        const goal_grid = self.graph.grid(key.goal_level) orelse return;
        const goal_index = goal_grid.projectToNearestOpen(key.goal, default_goal_projection_radius) orelse return;
        // Same agent class targeting a different (now stale) cell: the declared
        // goal crossed into a new nav cell. Rebuild only if throttle elapsed.
        if (self.staleGroupSlot(key)) |slot_index| {
            const field = &self.group_fields.items[slot_index];
            const elapsed = self.step_counter -% field.last_build_step;
            if (elapsed < self.capacity.group_field_rebuild_min_steps) {
                // Throttled: keep the slightly stale field for general direction.
                stats.group_field_rebuild_throttled += 1;
                return;
            }
            self.buildGroupSlot(field, key, goal_index, stats);
            return;
        }
        // Allocate an empty slot, else evict deterministically.
        for (self.group_fields.items) |*field| {
            if (field.state == .empty) {
                self.buildGroupSlot(field, key, goal_index, stats);
                return;
            }
        }
        const index = self.next_group_evict;
        self.next_group_evict = (self.next_group_evict + 1) % self.group_fields.items.len;
        const field = &self.group_fields.items[index];
        self.buildGroupSlot(field, key, goal_index, stats);
        stats.cache_evictions += 1;
    }

    fn buildGroupSlot(self: *PathfindingSystem, field: *GroupField, key: PathQueryKey, goal_index: usize, stats: *PathfindingStats) void {
        const grid = self.graph.grid(key.goal_level) orelse return;
        if (field.beginBuild(grid, key, goal_index, self.step_counter)) {
            _ = field.expand(grid, self.capacity.group_field_build_budget);
            field.fresh_this_step = true;
            stats.group_fields_built += 1;
        }
    }

    // A stale slot targets the same agent class/version/goal-level but a different
    // goal cell. When several such slots exist, the one whose stored goal is
    // nearest the new goal cell is chosen so rebuild selection is deterministic and
    // reuses the most relevant field rather than an arbitrary first match.
    fn staleGroupSlot(self: *PathfindingSystem, key: PathQueryKey) ?usize {
        var best_index: ?usize = null;
        var best_dist: i64 = std.math.maxInt(i64);
        for (self.group_fields.items, 0..) |field, index| {
            if (field.state == .empty) continue;
            if (keysEqual(field.key, key)) continue;
            if (field.key.agent_class != key.agent_class) continue;
            if (field.key.nav_version != key.nav_version) continue;
            if (field.key.goal_level != key.goal_level) continue;
            const dx: i64 = field.key.goal.x - key.goal.x;
            const dy: i64 = field.key.goal.y - key.goal.y;
            const dist = dx * dx + dy * dy;
            // Tie-break on lower slot index for full determinism.
            if (dist < best_dist or (dist == best_dist and (best_index == null or index < best_index.?))) {
                best_dist = dist;
                best_index = index;
            }
        }
        return best_index;
    }

    fn findGroupField(self: *const PathfindingSystem, key: PathQueryKey) ?*const GroupField {
        for (self.group_fields.items) |*field| {
            if (field.state != .empty and keysEqual(field.key, key)) return field;
        }
        return null;
    }

    fn findGroupFieldMut(self: *PathfindingSystem, key: PathQueryKey) ?*GroupField {
        for (self.group_fields.items) |*field| {
            if (field.state != .empty and keysEqual(field.key, key)) return field;
        }
        return null;
    }

    fn prepareRequestKeys(self: *PathfindingSystem, requests: []const PathRequest, stats: *PathfindingStats) void {
        self.prepared_requests.clearRetainingCapacity();
        if (!self.graph.valid()) return;
        const capacity = self.prepared_requests.capacity;
        const limit = @min(requests.len, capacity);
        stats.dropped_requests += requests.len - limit;
        for (requests[0..limit]) |request| {
            // Clamp levels to the built range so a stray level never indexes out of
            // bounds; an unknown level resolves to level 0's mask (fail-safe).
            const level_count: u16 = @intCast(self.graph.levelCount());
            const goal_level = if (request.goal_level < level_count) request.goal_level else 0;
            const start_level = if (request.start_level < level_count) request.start_level else 0;
            const goal_grid = self.graph.grid(goal_level).?;
            const start_grid = self.graph.grid(start_level).?;
            self.prepared_requests.appendAssumeCapacity(.{
                .entity = request.entity,
                .kind = request.kind,
                .start_level = start_level,
                .key = .{
                    .nav_version = self.graph.version,
                    .agent_class = request.agent_class,
                    .goal_level = goal_level,
                    .goal = goal_grid.worldToCellClamped(request.goal),
                },
                .start = start_grid.worldToCellClamped(request.start),
            });
        }
    }

    fn prepareSolveBuffers(self: *PathfindingSystem, solve_count: usize) void {
        self.solve_results.clearRetainingCapacity();
        self.fallback_indices.clearRetainingCapacity();
        for (0..solve_count) |_| {
            self.solve_results.appendAssumeCapacity(.{ .deferred = emptyKey(self.graph.version) });
        }
    }

    fn effectiveSolveLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_solved_requests_per_step orelse self.capacity.max_solved_requests_per_step;
        return @min(
            self.pending.items.len,
            @min(
                @min(requested_limit, self.capacity.max_solved_requests_per_step),
                @min(self.solve_results.capacity, self.fallback_indices.capacity),
            ),
        );
    }

    fn effectiveFallbackLimit(self: *const PathfindingSystem, config: PathfindingConfig) usize {
        const requested_limit = config.max_fallback_requests_per_step orelse self.capacity.max_fallback_requests_per_step;
        return @min(requested_limit, self.capacity.max_fallback_requests_per_step);
    }

    fn prepareFallbackIndices(self: *PathfindingSystem, solve_count: usize, fallback_limit: usize, stats: *PathfindingStats) void {
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            if (result == .deferred) {
                if (self.fallback_indices.items.len < fallback_limit) {
                    self.fallback_indices.appendAssumeCapacity(pending_index);
                } else {
                    stats.fallback_deferred_requests += 1;
                }
            }
        }
    }

    fn publishSolvedResults(self: *PathfindingSystem, solve_count: usize, stats: *PathfindingStats) void {
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            switch (result) {
                .available => |key| {
                    const solved = self.solved_paths.items[pending_index];
                    const path = self.worker_path_pool.items[solved.offset .. solved.offset + solved.len];
                    const stitched = self.worker_stitched_pool.items[solved.stitched_offset .. solved.stitched_offset + solved.stitched_len];
                    self.completed.put(key, path, stitched, solved.path_level, stats);
                    stats.solved_requests += 1;
                    stats.available_results += 1;
                    if (solved.via_abstract) stats.abstract_solves += 1;
                    if (solved.cross_level) stats.cross_level_solves += 1;
                },
                .unavailable => |key| {
                    if (!self.unavailable.insert(key)) stats.cache_evictions += 1;
                    stats.solved_requests += 1;
                    stats.unavailable_results += 1;
                },
                .budget_exhausted => {
                    stats.budget_exhausted += 1;
                },
                .deferred => continue,
            }
        }
        stats.fallback_requests = self.fallback_indices.items.len;
    }

    // Deferred and budget-exhausted entries keep relative order. Solved entries
    // (available/unavailable) are removed, then pending_keys is rebuilt to match.
    fn compactPendingAfterSolve(self: *PathfindingSystem, solve_count: usize) void {
        if (solve_count == 0) return;
        var write_index: usize = 0;
        for (self.solve_results.items[0..solve_count], 0..) |result, pending_index| {
            const keep = switch (result) {
                .deferred, .budget_exhausted => true,
                else => false,
            };
            if (!keep) continue;
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
};

const SolveJobContext = struct {
    system: *PathfindingSystem,
};

// Fallback workers share the system for read-only graph/pending access but use
// worker-indexed scratch and a worker-disjoint path stripe to stay private.
fn solveFallbackJob(context: *anyopaque, range: ParallelRange, worker_id: WorkerId) void {
    const job: *SolveJobContext = @ptrCast(@alignCast(context));
    const system = job.system;
    const scratch = &system.scratch_slots.items[worker_id.index];
    for (range.start..range.end) |fallback_index| {
        const pending_index = system.fallback_indices.items[fallback_index];
        // The dense fallback index is this request's disjoint path stripe; two
        // requests never share a stripe even when one worker solves several.
        system.solve_results.items[pending_index] = solveOne(system, pending_index, scratch, fallback_index);
    }
}

// Outcome of a budget-bounded local A* over one level's grid.
const LocalSolve = enum { found, budget_exhausted, none };

// Solves one request. Short same-component hops use the budget-bounded local A*
// directly and store a plain path (no stitched corridor). Long-range or cross-level
// queries route through the abstract chunk-portal/link graph to pick a corridor, then
// stitch the full obstacle-aware (level,cell) path from per-segment local A* runs;
// the query walks it per-agent on its current level. Per-solve work is bounded by the
// abstract node budget plus the per-segment local budget, independent of total cells.
fn solveOne(system: *PathfindingSystem, pending_index: usize, scratch: *SearchScratch, path_slot: usize) PathSolveResult {
    const graph = &system.graph;
    const request = system.pending.items[pending_index];
    if (!graph.valid()) return .{ .unavailable = request.key };

    const start_grid = graph.grid(request.start_level) orelse return .{ .unavailable = request.key };
    const goal_grid = graph.grid(request.key.goal_level) orelse return .{ .unavailable = request.key };
    const start_index = start_grid.indexForCell(request.start) orelse return .{ .unavailable = request.key };
    if (start_grid.isBlockedIndex(start_index)) return .{ .unavailable = request.key };

    // Projection (including failure) was resolved at acceptance against the goal
    // level. no_parent means no open cell near the goal: a definitive negative.
    if (request.goal_index == no_parent) return .{ .unavailable = request.key };
    const goal_index = request.goal_index;

    const same_level = request.start_level == request.key.goal_level;
    if (same_level) {
        if (start_index == goal_index) {
            recordPath(system, pending_index, path_slot, &.{@intCast(goal_index)}, request.start_level);
            return .{ .available = request.key };
        }
        // Same component: a short hop the local A* can usually finish.
        if (start_grid.connected(start_index, goal_index)) {
            switch (localAStar(start_grid, scratch, start_index, goal_index)) {
                .found => {
                    recordPath(system, pending_index, path_slot, scratch.path_scratch.items, request.start_level);
                    return .{ .available = request.key };
                },
                // Budget spill on a short same-component hop is a transient: keep
                // it pending so a later frame retries rather than mislabeling it.
                .budget_exhausted => return .{ .budget_exhausted = request.key },
                .none => return .{ .unavailable = request.key },
            }
        }
        // Same level but different component: only a link corridor (e.g. a
        // teleport back onto this level) could connect them. Fall to abstract.
    }

    return solveAbstract(system, pending_index, scratch, path_slot, request, start_grid, goal_grid, start_index, goal_index);
}

// Abstract A* over portal nodes + link edges to choose a corridor across
// chunks/levels, then stitches the FULL obstacle-aware path: per-segment local A*
// between consecutive corridor portals (and start->first portal, last portal->goal)
// concatenated into one grid-adjacent (level,cell) path, with a discrete jump only
// across an inter-level link. The query walks that path per-agent on its current
// level, so every heading is to a traversable neighbor. Saturating the abstract
// scratch or a segment's node budget spills to a later frame (budget_exhausted)
// rather than mislabeling it; only a genuinely missing corridor is unavailable.
fn solveAbstract(
    system: *PathfindingSystem,
    pending_index: usize,
    scratch: *SearchScratch,
    path_slot: usize,
    request: PendingRequest,
    start_grid: *const NavGrid,
    goal_grid: *const NavGrid,
    start_index: usize,
    goal_index: usize,
) PathSolveResult {
    const graph = &system.graph;
    const corridor = switch (abstractCorridor(graph, scratch, start_grid, goal_grid, request.start_level, request.key.goal_level, start_index, goal_index)) {
        .found => |c| c,
        // Abstract scratch saturated: retry next frame instead of a hard negative.
        .saturated => return .{ .budget_exhausted = request.key },
        .none => return .{ .unavailable = request.key },
    };

    // Stitch the full obstacle-aware path across every corridor segment. A node-budget
    // spill or an overflow of the stitched buffer is a transient: retry next frame.
    switch (stitchCorridor(system, scratch, request, goal_grid, start_index, goal_index)) {
        .found => {},
        .budget_exhausted => return .{ .budget_exhausted = request.key },
        .none => return .{ .unavailable = request.key },
    }

    const stitched = scratch.stitched_scratch.items;
    if (stitched.len == 0) return .{ .unavailable = request.key };
    // Record the start-level prefix as the plain path (a first-cell fallback) and the
    // full stitched path the query walks.
    recordStartLevelPrefix(system, pending_index, path_slot, stitched, request.start_level);
    recordStitched(system, pending_index, path_slot, stitched);
    var solved = &system.solved_paths.items[pending_index];
    solved.via_abstract = true;
    solved.cross_level = corridor.crosses_level;
    return .{ .available = request.key };
}

// Stitches the chosen abstract corridor (scratch.abstract.corridor, ordered portal
// node indices root->goal) into scratch.stitched_scratch as one (level,cell) path.
// A NON-link transition (corridor_link[i] == false) is walked with local A* between
// consecutive portal cells; a LINK transition (corridor_link[i] == true) is a single
// discrete jump (no intermediate cells), whether it crosses Z or is a same-level
// teleport. The final span (last portal -> goal) is a same-level local A*. Returns
// budget_exhausted on any segment node-budget spill or stitched-buffer overflow.
fn stitchCorridor(
    system: *PathfindingSystem,
    scratch: *SearchScratch,
    request: PendingRequest,
    goal_grid: *const NavGrid,
    start_index: usize,
    goal_index: usize,
) LocalSolve {
    const graph = &system.graph;
    const cap = system.capacity.max_stitched_path_cells;
    scratch.stitched_scratch.clearRetainingCapacity();
    if (cap == 0) return .budget_exhausted;
    // Seed the path with the start cell on the start level.
    scratch.stitched_scratch.appendAssumeCapacity(.{ .level = request.start_level, .cell = @intCast(start_index) });

    var prev_level = request.start_level;
    var prev_cell: usize = start_index;
    for (scratch.abstract.corridor.items, 0..) |node, i| {
        const portal = graph.portals.items[node];
        // The first corridor portal (i == 0) is on the start level and reached from
        // the start cell by a walkable span; later portals follow corridor_link.
        const is_link = i != 0 and scratch.abstract.corridor_link.items[i];
        if (is_link) {
            // Discrete link jump: append the far endpoint cell with no intermediate
            // cells (the agent crosses the link rather than walking).
            if (scratch.stitched_scratch.items.len >= cap) return .budget_exhausted;
            scratch.stitched_scratch.appendAssumeCapacity(.{ .level = portal.level, .cell = portal.cell_index });
        } else {
            const grid = graph.grid(prev_level).?;
            switch (appendSegment(scratch, grid, prev_level, prev_cell, portal.cell_index, cap)) {
                .found => {},
                else => |r| return r,
            }
        }
        prev_level = portal.level;
        prev_cell = portal.cell_index;
    }
    // Final span: last corridor cell -> goal cell, a walkable same-level segment.
    if (prev_level != request.key.goal_level) return .budget_exhausted;
    switch (appendSegment(scratch, goal_grid, prev_level, prev_cell, @intCast(goal_index), cap)) {
        .found => {},
        else => |r| return r,
    }
    return .found;
}

// Runs local A* from `from` to `to` on `grid` and appends the resulting cells
// (skipping the first, already present as the previous segment's tail) to the
// stitched buffer, tagged with `level`. Returns the local A* outcome, or
// budget_exhausted if appending would overflow the stitched cap.
fn appendSegment(scratch: *SearchScratch, grid: *const NavGrid, level: u16, from: usize, to: usize, cap: usize) LocalSolve {
    if (from == to) return .found;
    switch (localAStar(grid, scratch, from, to)) {
        .found => {},
        .budget_exhausted => return .budget_exhausted,
        .none => return .none,
    }
    // path_scratch is start->goal for this segment; its first cell equals `from`,
    // already the tail of the stitched buffer, so skip it.
    const seg = scratch.path_scratch.items;
    if (seg.len <= 1) return .found;
    for (seg[1..]) |cell| {
        if (scratch.stitched_scratch.items.len >= cap) return .budget_exhausted;
        scratch.stitched_scratch.appendAssumeCapacity(.{ .level = level, .cell = cell });
    }
    return .found;
}

const AbstractCorridor = struct {
    // Whether the chosen corridor crosses at least one inter-level link.
    crosses_level: bool,
};

const AbstractResult = union(enum) {
    found: AbstractCorridor,
    // The bounded abstract scratch saturated (open/slot table full); the corridor
    // may exist but could not be searched this frame.
    saturated,
    // No corridor reaches the goal level/cell from the start.
    none,
};

// Runs abstract A* over portal/link nodes. On success it writes the ordered corridor
// of portal node indices (root start-level portal -> goal-level portal) into
// scratch.abstract.corridor for the stitcher to refine, and reports whether the
// corridor crosses a level. Per-query work is bounded by the abstract node budget;
// seeding scans only the start level's portals via the per-level portal index, so it
// stays bounded independent of total cell count and total portals on other levels.
fn abstractCorridor(
    graph: *const NavGraph,
    scratch: *SearchScratch,
    start_grid: *const NavGrid,
    goal_grid: *const NavGrid,
    start_level: u16,
    goal_level: u16,
    start_index: usize,
    goal_index: usize,
) AbstractResult {
    const abstract = &scratch.abstract;
    abstract.reset();

    // Seed the open set with the start cell's component portals on the start level,
    // costed by octile distance from the start. The (level, component) portal index
    // yields only that component's portals, so seeding never scans unreachable
    // components.
    const start_component = start_grid.components.items[start_index];
    if (start_component == no_component) return .none;
    var seeded: usize = 0;
    for (graph.levelComponentPortals(start_level, start_component)) |node_index| {
        const portal = graph.portals.items[node_index];
        const slot = abstract.slotFor(node_index) orelse return .saturated;
        const g = octileCells(graph.width, @intCast(start_index), portal.cell_index);
        abstract.slot_g.items[slot] = g;
        abstract.slot_parent.items[slot] = no_cell;
        if (abstract.open.items.len >= abstract.open.capacity) return .saturated;
        const h = octileCells(graph.width, portal.cell_index, @intCast(goal_index));
        abstract.open.appendAssumeCapacity(.{ .index = node_index, .f = g + h, .h = h });
        siftUp(abstract.open.items, abstract.open.items.len - 1);
        seeded += 1;
    }
    if (seeded == 0) return .none;

    const goal_component = goal_grid.components.items[goal_index];

    while (abstract.open.items.len != 0) {
        const current = popHeap(&abstract.open);
        const node_index: u32 = @intCast(current.index);
        const current_slot = abstract.slotFor(node_index) orelse return .saturated;
        if (abstract.slot_closed.items[current_slot]) continue;
        abstract.slot_closed.items[current_slot] = true;

        const portal = graph.portals.items[node_index];
        // Goal reached: this portal is on the goal level and shares the goal's
        // component, so the local refiner can finish from here.
        if (portal.level == goal_level and goal_component != no_component and
            goal_grid.components.items[portal.cell_index] == goal_component)
        {
            if (!buildCorridor(graph, abstract, node_index, start_level)) return .none;
            return .{ .found = .{ .crosses_level = start_level != goal_level } };
        }

        const begin = graph.portal_offsets.items[node_index];
        const end = graph.portal_offsets.items[node_index + 1];
        const current_g = abstract.slot_g.items[current_slot];
        for (graph.portal_edges.items[begin..end]) |edge| {
            const next_slot = abstract.slotFor(edge.target) orelse return .saturated;
            if (abstract.slot_closed.items[next_slot]) continue;
            const candidate = current_g +| edge.cost;
            if (candidate >= abstract.slot_g.items[next_slot]) continue;
            abstract.slot_g.items[next_slot] = candidate;
            abstract.slot_parent.items[next_slot] = node_index;
            const target_portal = graph.portals.items[edge.target];
            // Cross-level (non-goal) hops use h=0: admissible but Dijkstra-like
            // across non-goal levels (no cell coordinate is comparable to the goal
            // until the search reaches a goal-level portal), so it never overestimates.
            const h = if (target_portal.level == goal_level)
                octileCells(graph.width, target_portal.cell_index, @intCast(goal_index))
            else
                0;
            if (abstract.open.items.len >= abstract.open.capacity) return .saturated;
            abstract.open.appendAssumeCapacity(.{ .index = edge.target, .f = candidate +| h, .h = h });
            siftUp(abstract.open.items, abstract.open.items.len - 1);
        }
    }
    return .none;
}

// Walks the abstract parent chain from the reached goal-level portal back to its
// seeded start-level root, writing the ordered portal node sequence (root -> goal
// portal) into abstract.corridor. Returns true when the corridor is well-formed
// (its root is a start-level portal). O(hops), not O(cells).
fn buildCorridor(graph: *const NavGraph, abstract: *AbstractScratch, goal_node: u32, start_level: u16) bool {
    abstract.corridor.clearRetainingCapacity();
    // Walk parents goal->root into the corridor buffer, then reverse to root->goal.
    var node = goal_node;
    while (true) {
        if (abstract.corridor.items.len >= abstract.corridor.capacity) break;
        abstract.corridor.appendAssumeCapacity(node);
        const slot = abstract.slotFor(node) orelse break;
        const parent = abstract.slot_parent.items[slot];
        if (parent == no_cell) break;
        node = parent;
    }
    std.mem.reverse(u32, abstract.corridor.items);
    if (abstract.corridor.items.len == 0) return false;
    // Mark which corridor transitions are LINK edges (discrete jumps) by inspecting
    // the abstract edge between each consecutive pair. corridor_link[0] is false
    // (no predecessor); corridor_link[i] is the edge type into corridor[i].
    abstract.corridor_link.clearRetainingCapacity();
    abstract.corridor_link.appendAssumeCapacity(false);
    for (1..abstract.corridor.items.len) |i| {
        const from_node = abstract.corridor.items[i - 1];
        const to_node = abstract.corridor.items[i];
        abstract.corridor_link.appendAssumeCapacity(edgeIsLink(graph, from_node, to_node));
    }
    const root_portal = graph.portals.items[abstract.corridor.items[0]];
    return root_portal.level == start_level;
}

// Returns whether the abstract edge from `from_node` to `to_node` is a link edge
// (discrete inter-level/teleport jump) rather than a walkable intra-level edge.
fn edgeIsLink(graph: *const NavGraph, from_node: u32, to_node: u32) bool {
    const begin = graph.portal_offsets.items[from_node];
    const end = graph.portal_offsets.items[from_node + 1];
    for (graph.portal_edges.items[begin..end]) |edge| {
        if (edge.target == to_node) return edge.crosses_level;
    }
    return false;
}

// Budget-bounded heap A* over one level's grid. Fills scratch.path_scratch with
// the reconstructed start-to-goal cells on success. The node budget keeps explored
// count bounded; exhausting it spills the request to a later frame.
fn localAStar(grid: *const NavGrid, scratch: *SearchScratch, start_index: usize, goal_index: usize) LocalSolve {
    if (start_index == goal_index) {
        scratch.path_scratch.clearRetainingCapacity();
        scratch.path_scratch.appendAssumeCapacity(@intCast(goal_index));
        return .found;
    }
    scratch.reset();
    const width: i32 = @intCast(grid.width);
    const goal_x: i32 = @intCast(goal_index % grid.width);
    const goal_y: i32 = @intCast(goal_index / grid.width);
    const start_slot = scratch.slotFor(start_index) orelse return .budget_exhausted;
    scratch.slot_g.items[start_slot] = 0;
    scratch.slot_parent.items[start_slot] = @intCast(start_index);
    const h0 = octileXY(@intCast(start_index % grid.width), @intCast(start_index / grid.width), goal_x, goal_y);
    scratch.open.appendAssumeCapacity(.{ .index = start_index, .f = h0, .h = h0 });

    while (scratch.open.items.len != 0) {
        const current = popOpen(scratch);
        const current_slot = scratch.slotFor(current.index) orelse return .budget_exhausted;
        if (scratch.slot_closed.items[current_slot]) continue;
        scratch.slot_closed.items[current_slot] = true;
        if (current.index == goal_index) {
            reconstructLocalPath(scratch, start_index, goal_index);
            return .found;
        }
        // Derive current (x,y) once and step neighbors by the direction offset; the
        // neighbor coordinates feed the heuristic directly, so the inner loop has no
        // per-neighbor div/mod.
        const current_x: i32 = @intCast(current.index % grid.width);
        const current_y: i32 = @intCast(current.index / grid.width);
        const current_g = scratch.slot_g.items[current_slot];
        for (neighbor_dirs) |dir| {
            const nx = current_x + dir.x;
            const ny = current_y + dir.y;
            if (nx < 0 or ny < 0 or nx >= width or ny >= @as(i32, @intCast(grid.height))) continue;
            const next_index: usize = @intCast(ny * width + nx);
            if (grid.isBlockedIndex(next_index)) continue;
            if (dir.diagonal and (grid.isBlockedCell(.{ .x = nx, .y = current_y }) or grid.isBlockedCell(.{ .x = current_x, .y = ny }))) {
                continue;
            }
            const next_slot = scratch.slotFor(next_index) orelse return .budget_exhausted;
            if (scratch.slot_closed.items[next_slot]) continue;
            const step_cost = if (dir.diagonal) diagonal_cost else cardinal_cost;
            const candidate_g = current_g + step_cost;
            if (candidate_g >= scratch.slot_g.items[next_slot]) continue;
            scratch.slot_g.items[next_slot] = candidate_g;
            scratch.slot_parent.items[next_slot] = @intCast(current.index);
            const h = octileXY(nx, ny, goal_x, goal_y);
            if (scratch.open.items.len >= scratch.open.capacity) return .budget_exhausted;
            scratch.open.appendAssumeCapacity(.{ .index = next_index, .f = candidate_g + h, .h = h });
            siftUp(scratch.open.items, scratch.open.items.len - 1);
        }
    }
    return .none;
}

fn reconstructLocalPath(scratch: *SearchScratch, start_index: usize, goal_index: usize) void {
    scratch.path_scratch.clearRetainingCapacity();
    var current = goal_index;
    while (true) {
        scratch.path_scratch.appendAssumeCapacity(@intCast(current));
        if (current == start_index) break;
        const slot = scratch.slotFor(current) orelse break;
        const parent = scratch.slot_parent.items[slot];
        if (parent == no_cell) break;
        current = parent;
        if (scratch.path_scratch.items.len >= scratch.path_scratch.capacity) break;
    }
    // path_scratch is goal-to-start; reverse into start-to-goal.
    std.mem.reverse(u32, scratch.path_scratch.items);
}

fn recordPath(system: *PathfindingSystem, pending_index: usize, path_slot: usize, path: []const u32, path_level: u16) void {
    const stride = system.capacity.max_stored_path_cells;
    const offset = path_slot * stride;
    const copy_len = @min(path.len, stride);
    @memcpy(system.worker_path_pool.items[offset .. offset + copy_len], path[0..copy_len]);
    system.solved_paths.items[pending_index] = .{
        .key = system.pending.items[pending_index].key,
        .offset = offset,
        .len = copy_len,
        .path_level = path_level,
    };
}

// Records the leading start-level run of the stitched path as the plain path buffer
// (used only as a first-cell fallback in the query). Writes the rest of the
// SolvedPath entry, mirroring recordPath's contract for a local solve.
fn recordStartLevelPrefix(system: *PathfindingSystem, pending_index: usize, path_slot: usize, stitched: []const StitchedCell, start_level: u16) void {
    const stride = system.capacity.max_stored_path_cells;
    const offset = path_slot * stride;
    var count: usize = 0;
    for (stitched) |sc| {
        if (sc.level != start_level) break; // first level change ends the prefix
        if (count >= stride) break;
        system.worker_path_pool.items[offset + count] = sc.cell;
        count += 1;
    }
    system.solved_paths.items[pending_index] = .{
        .key = system.pending.items[pending_index].key,
        .offset = offset,
        .len = count,
        .path_level = start_level,
    };
}

// Copies the full stitched (level,cell) corridor path into this request's disjoint
// stripe. Must run after recordStartLevelPrefix, which writes the rest of the entry.
fn recordStitched(system: *PathfindingSystem, pending_index: usize, path_slot: usize, stitched: []const StitchedCell) void {
    const stride = system.capacity.max_stitched_path_cells;
    if (stride == 0) return;
    const offset = path_slot * stride;
    const count = @min(stitched.len, stride);
    @memcpy(system.worker_stitched_pool.items[offset .. offset + count], stitched[0..count]);
    system.solved_paths.items[pending_index].stitched_offset = offset;
    system.solved_paths.items[pending_index].stitched_len = count;
}

fn popOpen(scratch: *SearchScratch) OpenNode {
    return popHeap(&scratch.open);
}

fn popHeap(heap: *std.ArrayList(OpenNode)) OpenNode {
    const result = heap.items[0];
    const last = heap.items.len - 1;
    heap.items[0] = heap.items[last];
    heap.items.len = last;
    if (heap.items.len != 0) siftDown(heap.items, 0);
    return result;
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

fn oppositeDirIndex(dir_index: usize) u8 {
    // neighbor_dirs is laid out so the opposite of i (cardinals 0..3, diagonals
    // 4..7) is found by negating components.
    const dir = neighbor_dirs[dir_index];
    inline for (neighbor_dirs, 0..) |candidate, index| {
        if (candidate.x == -dir.x and candidate.y == -dir.y) return @intCast(index);
    }
    return GroupField.no_flow;
}

// Octile heuristic over explicit cell coordinates; callers pass coordinates they
// already hold so the hot loop avoids re-deriving them via div/mod.
fn octileXY(from_x: i32, from_y: i32, to_x: i32, to_y: i32) u32 {
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

fn collisionBoundsIndex(entities: []const EntityId, target: EntityId) ?usize {
    for (entities, 0..) |entity, index| {
        if (entity.index == target.index and entity.generation == target.generation) return index;
    }
    return null;
}

fn keysEqual(a: PathQueryKey, b: PathQueryKey) bool {
    return a.nav_version == b.nav_version and
        a.agent_class == b.agent_class and
        a.goal_level == b.goal_level and
        a.goal.x == b.goal.x and
        a.goal.y == b.goal.y;
}

fn hashPathKey(key: PathQueryKey) usize {
    var h: u64 = 14695981039346656037;
    inline for (.{ key.nav_version, @intFromEnum(key.agent_class), @as(u32, key.goal_level), @as(u32, @bitCast(key.goal.x)), @as(u32, @bitCast(key.goal.y)) }) |part| {
        h ^= @as(u64, part);
        h *%= 1099511628211;
    }
    return @intCast(h);
}

fn hashUsize(value: usize) usize {
    var h: u64 = 14695981039346656037;
    h ^= @as(u64, @intCast(value));
    h *%= 1099511628211;
    return @intCast(h);
}

fn emptyKey(nav_version: u32) PathQueryKey {
    return .{
        .nav_version = nav_version,
        .agent_class = .default,
        .goal = .{ .x = 0, .y = 0 },
    };
}

// Grows (amortized) or shrinks-and-frees a per-step scratch list's backing capacity
// to `capacity`, leaving it empty. Used for lists the update repopulates each step,
// so no contents need to survive the resize. Shrinking frees memory back.
fn resizeArrayList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, capacity: usize) !void {
    if (capacity < list.capacity) {
        list.clearRetainingCapacity();
        list.shrinkAndFree(allocator, 0);
    }
    try list.ensureTotalCapacity(allocator, capacity);
    list.clearRetainingCapacity();
}

// Like resizeArrayList but for a pool sized to exactly `capacity` and memset to a
// fill value (the disjoint worker path/stitched stripes). Shrinking frees memory.
fn resizeFilledArrayList(comptime T: type, list: *std.ArrayList(T), allocator: std.mem.Allocator, capacity: usize, fill: T) !void {
    if (capacity < list.capacity) list.shrinkAndFree(allocator, 0);
    try list.ensureTotalCapacity(allocator, capacity);
    list.items.len = capacity;
    @memset(list.items, fill);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

fn addNavBody(data: *DataSystem, position: math.Vec2, size: math.Vec2, static: bool) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try data.setCollisionBounds(entity, .{ .size = size });
    try data.setCollisionResponse(entity, .{ .mobility = if (static) .static else .dynamic });
    return entity;
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

fn baselineCapacity() PathfindingCapacity {
    // Per-step request/cache caps are derived elastically from the agent count
    // (floored at min_capacity_floor = 8), so only the non-derived knobs are set
    // here. The ratio is zeroed so min_group_field_agents is the sole operating
    // group-field threshold: these tests exercise the field mechanics with a handful
    // of agents at an explicit threshold, independent of capacity scale.
    return .{
        .max_group_fields = 2,
        .max_worker_scratch_slots = 1,
        .group_field_agent_ratio = 0,
        .min_group_field_agents = 1,
    };
}

test "pathfinding nav grid blocked set matches per-level composed mask" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        std.testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const extra_band = try world.addDenseLayer(0, 0, .obstacle, grass);
    _ = try world.setDenseTile(extra_band, 5, 6, tree);
    _ = try world.setDenseTile(extra_band, 2, 1, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 256, 256, 32);

    var expected_blocked: usize = 0;
    for (0..world.height) |y_usize| {
        const y: u16 = @intCast(y_usize);
        for (0..world.width) |x_usize| {
            const x: u16 = @intCast(x_usize);
            const expect_blocked = world.levelBlocksMovement(0, x, y);
            if (expect_blocked) expected_blocked += 1;
            try std.testing.expectEqual(expect_blocked, system.graph.grid(0).?.isBlockedCell(.{
                .x = @intCast(x),
                .y = @intCast(y),
            }));
        }
    }
    try std.testing.expect(expected_blocked > 0);
    try std.testing.expectEqual(expected_blocked, system.graph.grid(0).?.blocked_count);
}

test "pathfinding individual solve produces deterministic available path and waypoint" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });
    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);

    const view = system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, .{ .x = 96, .y = 96 }, .default);
    try std.testing.expectEqual(PathStatus.available, view.status);
    try std.testing.expectEqual(@as(f32, 48), view.next_waypoint.x);
    try std.testing.expectEqual(@as(f32, 48), view.next_waypoint.y);
    try std.testing.expect(view.path_len >= 2);
}

test "pathfinding goal-keyed dedup reuses one accepted request under start drift" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    var accepted_total: usize = 0;
    const steps: usize = 6;
    for (0..steps) |i| {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        // The agent's start cell drifts toward a fixed goal each step.
        const start_x: f32 = 8.0 + @as(f32, @floatFromInt(i)) * 40.0;
        try appendPathRequest(&stream, .{
            .entity = requester,
            .start = .{ .x = start_x, .y = 8 },
            .goal = .{ .x = 480, .y = 480 },
        });
        const stats = try system.updateSerial(&stream, 8, .{});
        accepted_total += stats.accepted_requests;
    }
    // Exactly one A* solve was accepted; later drifting starts reuse the cache.
    try std.testing.expectEqual(@as(usize, 1), accepted_total);
}

test "pathfinding projects goal in obstacle to nearest open cell" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    // Block the single cell containing the goal.
    _ = try addNavBody(&data, .{ .x = 96, .y = 96 }, .{ .x = 32, .y = 32 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 3, .y = 3 }));

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    // Goal world position falls inside the blocked cell.
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 104, .y = 104 } });

    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.goal_projected);
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, .{ .x = 104, .y = 104 }, .default).status);
}

test "pathfinding spills to pending when node budget is exhausted" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    // A tiny node budget cannot explore the open grid to the far goal.
    capacity.max_explored_nodes = 20;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 488, .y = 488 } });

    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.budget_exhausted);
    try std.testing.expectEqual(@as(usize, 0), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 1), stats.pending_requests);
    const key = system.graph.keyForWorld(0, .{ .x = 488, .y = 488 }, .default).?;
    try std.testing.expectEqual(PathStatus.pending, system.statusForKey(key).status);
}

test "pathfinding rejects disconnected goals" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    _ = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 32, .y = 160 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 160, 160, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 128, .y = 8 } });

    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_results);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, .{ .x = 128, .y = 8 }, .default).status);
}

test "pathfinding rebuild fails loud on oversized nav world" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_nav_memory_bytes = 1024;
    try system.reserve(capacity);
    // 512x512 cells far exceed a 1 KiB nav-memory ceiling.
    try std.testing.expectError(NavGridError.NavWorldTooLarge, system.rebuildStaticNavGrid(&data, 512, 512, 32));
}

test "pathfinding deferred_requests equals post-compaction pending in both update paths" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const c = try addNavBody(&data, .{ .x = 64, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(3, 3);
    try appendPathRequest(&stream, .{ .entity = a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 200, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = b, .start = .{ .x = 40, .y = 8 }, .goal = .{ .x = 200, .y = 40 } });
    try appendPathRequest(&stream, .{ .entity = c, .start = .{ .x = 72, .y = 8 }, .goal = .{ .x = 200, .y = 72 } });

    // Per-step solve budget of 1 (config override) throttles to one solve/step.
    const stats = try system.updateSerial(&stream, 3, .{ .max_solved_requests_per_step = 1 });
    try std.testing.expectEqual(@as(usize, 1), stats.solved_requests);
    try std.testing.expectEqual(stats.pending_requests, stats.deferred_requests);
    try std.testing.expectEqual(@as(usize, 2), stats.pending_requests);
}

test "pathfinding deferred_requests equals pending in threaded update path" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_worker_scratch_slots = 4;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(2, 2);
    try appendPathRequest(&stream, .{ .entity = a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 200, .y = 8 } });
    try appendPathRequest(&stream, .{ .entity = b, .start = .{ .x = 40, .y = 8 }, .goal = .{ .x = 200, .y = 40 } });

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    const stats = try system.update(&stream, 2, &threads, .{ .adaptive = false, .items_per_range = 1, .max_solved_requests_per_step = 1 });
    try std.testing.expectEqual(stats.pending_requests, stats.deferred_requests);
    try std.testing.expectEqual(@as(usize, 1), stats.pending_requests);
}

test "pathfinding group mode builds one shared field sampled by all agents" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const c = try addNavBody(&data, .{ .x = 64, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(3, 3);
    const goal = math.Vec2{ .x = 200, .y = 200 };
    try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&stream, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    try appendPathRequest(&stream, .{ .entity = c, .kind = .group, .start = .{ .x = 72, .y = 8 }, .goal = goal });

    // First step: the field does not exist yet during acceptance, so the shared
    // goal dedups to exactly one individual fallback solve while the field is
    // built (and finishes, given the default budget) this same step.
    const first_stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), first_stats.group_fields_built);
    try std.testing.expectEqual(@as(usize, 1), first_stats.accepted_requests);
    var ready_field_count: usize = 0;
    for (system.group_fields.items) |field| {
        if (field.state == .ready) ready_field_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ready_field_count);

    // Second step: the ready field answers all three; no individual solves, and
    // every agent samples the one shared field.
    const second_stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), second_stats.accepted_requests);
    try std.testing.expectEqual(@as(usize, 0), second_stats.group_fields_built);
    try std.testing.expectEqual(@as(usize, 3), second_stats.group_field_samples);

    const view = system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, goal, .default);
    try std.testing.expectEqual(PathStatus.available, view.status);
}

test "pathfinding skips the group flow field below the agent threshold" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const c = try addNavBody(&data, .{ .x = 64, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Require three same-goal agents before a shared field is built.
    var capacity = baselineCapacity();
    capacity.min_group_field_agents = 3;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    const goal = math.Vec2{ .x = 200, .y = 200 };

    // Two agents (< threshold): no field builds; the shared goal still resolves via
    // one individual A* solve, so a small group never pays the flow-field cost.
    var below = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer below.deinit();
    try below.reserve(3, 3);
    try appendPathRequest(&below, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&below, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    const below_stats = try system.updateSerial(&below, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), below_stats.group_fields_built);
    try std.testing.expectEqual(@as(usize, 1), below_stats.accepted_requests);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, .{ .x = 8, .y = 8 }, 0, goal, .default).status);

    // Three agents (== threshold): the shared field now builds.
    var at = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer at.deinit();
    try at.reserve(3, 3);
    try appendPathRequest(&at, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&at, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    try appendPathRequest(&at, .{ .entity = c, .kind = .group, .start = .{ .x = 72, .y = 8 }, .goal = goal });
    const at_stats = try system.updateSerial(&at, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), at_stats.group_fields_built);
}

test "pathfinding builds no group field when no group requests arrive" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = a, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 200, .y = 200 } });

    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), stats.group_fields_built);
    for (system.group_fields.items) |field| {
        try std.testing.expectEqual(GroupFieldState.empty, field.state);
    }
}

test "pathfinding group field reuses within a nav cell and throttles cross-cell rebuilds" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.group_field_rebuild_min_steps = 5;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var rebuild_count: usize = 0;
    const steps: usize = 12;
    for (0..steps) |i| {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        // The goal moves a few pixels each step but stays mostly within one nav
        // cell; cross into a new cell occasionally.
        const goal_x: f32 = 100.0 + @as(f32, @floatFromInt(i)) * 10.0;
        try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = goal_x, .y = 100 } });
        const stats = try system.updateSerial(&stream, 8, .{});
        rebuild_count += stats.group_fields_built;
    }
    // Without throttle a moving goal would rebuild every cell crossing; the
    // throttle bounds rebuilds well below the step count.
    try std.testing.expect(rebuild_count >= 1);
    try std.testing.expect(rebuild_count <= steps / capacity.group_field_rebuild_min_steps + 2);
}

test "pathfinding group field latches via cross-step accumulation when intake is staggered" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Threshold of 3, but only 2 same-goal requests arrive per step (below the
    // threshold per step). The decaying accumulator equilibrates near ~2x intake,
    // so sustained demand crosses the threshold within a couple of steps.
    var capacity = baselineCapacity();
    capacity.min_group_field_agents = 3;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    const goal = math.Vec2{ .x = 200, .y = 200 };
    var built: usize = 0;
    for (0..4) |_| {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        try stream.reserve(2, 2);
        try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
        try appendPathRequest(&stream, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
        const stats = try system.updateSerial(&stream, 8, .{});
        built += stats.group_fields_built;
    }
    // No single step ever delivered the threshold count, yet accumulation latched.
    try std.testing.expect(built >= 1);
    var ready: usize = 0;
    for (system.group_fields.items) |field| {
        if (field.state == .ready) ready += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), ready);
}

test "pathfinding sub-threshold transient crowd decays back to no group field" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Threshold of 4: a single 2-agent burst never reaches it and then stops, so
    // the accumulator decays back to zero and the tally is compacted out.
    var capacity = baselineCapacity();
    capacity.min_group_field_agents = 4;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    const goal = math.Vec2{ .x = 200, .y = 200 };
    var burst = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer burst.deinit();
    try burst.reserve(2, 2);
    try appendPathRequest(&burst, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    try appendPathRequest(&burst, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
    const burst_stats = try system.updateSerial(&burst, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), burst_stats.group_fields_built);

    // No further group requests: the carried tally halves to zero and compacts away,
    // and no field is ever built.
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    for (0..3) |_| {
        const stats = try system.updateSerial(&empty, 8, .{});
        try std.testing.expectEqual(@as(usize, 0), stats.group_fields_built);
    }
    try std.testing.expectEqual(@as(usize, 0), system.group_requests.items.len);
    for (system.group_fields.items) |field| {
        try std.testing.expectEqual(GroupFieldState.empty, field.state);
    }
}

test "pathfinding nav grid survives degenerate cell size and bounds" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, true);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());

    // cell_size 0 and a non-finite bound would feed inf/NaN into @intFromFloat;
    // the guard collapses to at least a 1x1 grid instead of crashing.
    try system.rebuildStaticNavGrid(&data, std.math.inf(f32), 256, 0);
    try std.testing.expect(system.graph.width >= 1);
    try std.testing.expect(system.graph.height >= 1);
}

test "pathfinding group field within the same nav cell reuses without rebuilding" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    // First request builds a field for goal cell (1,1) (32px cells).
    var first = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer first.deinit();
    try appendPathRequest(&first, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 40, .y = 40 } });
    const first_stats = try system.updateSerial(&first, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), first_stats.group_fields_built);

    // A goal that stays inside the same nav cell reuses the field, no rebuild.
    var second = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer second.deinit();
    try appendPathRequest(&second, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 56, .y = 56 } });
    const reuse_stats = try system.updateSerial(&second, 8, .{});
    try std.testing.expectEqual(@as(usize, 0), reuse_stats.group_fields_built);
    try std.testing.expect(reuse_stats.group_field_reuses >= 1);
}

test "pathfinding group field reports building across frames under tiny budget" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    // One cell expanded per frame: the field cannot finish in a single frame.
    capacity.group_field_build_budget = 1;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 256, 256, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    const goal = math.Vec2{ .x = 240, .y = 240 };
    try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
    _ = try system.updateSerial(&stream, 8, .{});

    const key = system.graph.keyForWorld(0, goal, .default).?;
    const field_after_first = system.findGroupField(key).?;
    try std.testing.expectEqual(GroupFieldState.building, field_after_first.state);

    // Advance frames until the field completes; it must finish within the cell
    // count given a positive budget.
    var guard: usize = 0;
    while (system.findGroupField(key).?.state == .building and guard < system.graph.cellCount() + 1) : (guard += 1) {
        var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer empty.deinit();
        try empty.reserve(1, 0);
        try empty.prepareRangeCounts(0);
        try empty.prefix();
        empty.finishWrite();
        _ = try system.updateSerial(&empty, 8, .{});
    }
    try std.testing.expect(guard > 0);
    try std.testing.expectEqual(GroupFieldState.ready, system.findGroupField(key).?.state);
}

// Reference reverse-Dijkstra integration field over a NavGrid using a binary heap with
// the same octile step costs, strict-improvement relaxation, and (cost, index) tie
// order as a priority-queue Dijkstra. The production GroupField's Dial's bucket queue
// must reproduce this field byte-for-byte (costs AND flow directions).
fn referenceFlowField(allocator: std.mem.Allocator, grid: *const NavGrid, goal_index: usize, out_cost: []u32, out_dir: []u8) !void {
    @memset(out_cost, unreachable_cost);
    @memset(out_dir, GroupField.no_flow);
    var heap = std.ArrayList(OpenNode).empty;
    defer heap.deinit(allocator);
    out_cost[goal_index] = 0;
    try heap.append(allocator, .{ .index = goal_index, .f = 0, .h = 0 });
    while (heap.items.len != 0) {
        const current = popHeap(&heap);
        if (out_cost[current.index] != current.f) continue;
        const cx: i32 = @intCast(current.index % grid.width);
        const cy: i32 = @intCast(current.index / grid.width);
        for (neighbor_dirs, 0..) |dir, dir_index| {
            const next_index = grid.indexForCell(.{ .x = cx + dir.x, .y = cy + dir.y }) orelse continue;
            if (grid.isBlockedIndex(next_index)) continue;
            if (dir.diagonal and (grid.isBlockedCell(.{ .x = cx + dir.x, .y = cy }) or grid.isBlockedCell(.{ .x = cx, .y = cy + dir.y }))) continue;
            const candidate = current.f + (if (dir.diagonal) diagonal_cost else cardinal_cost);
            if (candidate >= out_cost[next_index]) continue;
            out_cost[next_index] = candidate;
            out_dir[next_index] = oppositeDirIndex(dir_index);
            try heap.append(allocator, .{ .index = next_index, .f = candidate, .h = 0 });
            siftUp(heap.items, heap.items.len - 1);
        }
    }
}

test "pathfinding group flow field (Dial's) equals a reference heap Dijkstra field" {
    const allocator = std.testing.allocator;
    var grid = NavGrid{};
    defer grid.deinit(allocator);
    try grid.prepare(allocator, 0, 20, 20, default_cell_size, 1);
    // A diagonal-ish obstacle pattern so the field has equal-cost cells reachable from
    // multiple predecessors (the case where pop order could change flow directions).
    const blocked_cells = [_][2]usize{ .{ 5, 3 }, .{ 5, 4 }, .{ 5, 5 }, .{ 6, 5 }, .{ 7, 5 }, .{ 10, 10 }, .{ 11, 10 }, .{ 12, 10 }, .{ 3, 12 }, .{ 4, 12 }, .{ 14, 6 }, .{ 14, 7 } };
    for (blocked_cells) |bc| grid.markBlockedIndex(bc[1] * grid.width + bc[0]);
    grid.buildComponents();

    const cell_count = grid.cellCount();
    const ref_cost = try allocator.alloc(u32, cell_count);
    defer allocator.free(ref_cost);
    const ref_dir = try allocator.alloc(u8, cell_count);
    defer allocator.free(ref_dir);
    const goal_index = 9 * grid.width + 9;
    try referenceFlowField(allocator, &grid, goal_index, ref_cost, ref_dir);

    var field = GroupField{};
    defer field.deinit(allocator);
    try field.reserve(allocator, cell_count);
    try std.testing.expect(field.beginBuild(&grid, emptyKey(1), goal_index, 1));
    // Build in tiny budgeted chunks so the cross-frame resume path is exercised too.
    var guard: usize = 0;
    while (field.state == .building and guard < cell_count + 8) : (guard += 1) {
        _ = field.expand(&grid, 7);
    }
    try std.testing.expectEqual(GroupFieldState.ready, field.state);

    // Every cell's integration cost and flow direction matches the reference exactly.
    for (0..cell_count) |i| {
        const dial_cost = field.cost(i);
        try std.testing.expectEqual(ref_cost[i], dial_cost);
        if (ref_cost[i] != unreachable_cost) {
            try std.testing.expectEqual(ref_dir[i], field.flow_dir.items[i]);
        }
    }
}

test "pathfinding threaded solve matches serial solve" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    _ = try addNavBody(&data, .{ .x = 64, .y = 32 }, .{ .x = 32, .y = 96 }, true);

    var serial_system = PathfindingSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    try serial_system.reserve(baselineCapacity());
    try serial_system.rebuildStaticNavGrid(&data, 160, 160, 32);
    var threaded_system = PathfindingSystem.init(std.testing.allocator);
    defer threaded_system.deinit();
    var threaded_capacity = baselineCapacity();
    threaded_capacity.max_worker_scratch_slots = 3;
    try threaded_system.reserve(threaded_capacity);
    try threaded_system.rebuildStaticNavGrid(&data, 160, 160, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 16, .y = 16 }, .goal = .{ .x = 144, .y = 144 } });

    _ = try serial_system.updateSerial(&stream, 8, .{});
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    _ = try threaded_system.update(&stream, 8, &threads, .{ .adaptive = false, .items_per_range = 1 });

    const serial_view = serial_system.statusForWorld(0, .{ .x = 16, .y = 16 }, 0, .{ .x = 144, .y = 144 }, .default);
    const threaded_view = threaded_system.statusForWorld(0, .{ .x = 16, .y = 16 }, 0, .{ .x = 144, .y = 144 }, .default);
    try std.testing.expectEqual(serial_view.status, threaded_view.status);
    try std.testing.expectEqual(serial_view.next_waypoint.x, threaded_view.next_waypoint.x);
    try std.testing.expectEqual(serial_view.next_waypoint.y, threaded_view.next_waypoint.y);
}

test "pathfinding threaded multi-goal solve keeps disjoint per-request paths" {
    if (builtin.single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const count = 8;
    var entities: [count]EntityId = undefined;
    for (0..count) |i| {
        entities[i] = try addNavBody(&data, .{ .x = 0, .y = @as(f32, @floatFromInt(i)) * 32.0 }, .{ .x = 8, .y = 8 }, false);
    }

    var serial_system = PathfindingSystem.init(std.testing.allocator);
    defer serial_system.deinit();
    var serial_cap = baselineCapacity();
    serial_cap.max_frame_requests = count;
    serial_cap.max_pending_requests = count;
    serial_cap.max_solved_requests_per_step = count;
    serial_cap.max_fallback_requests_per_step = count;
    serial_cap.max_cached_results = count * 2;
    try serial_system.reserve(serial_cap);
    try serial_system.rebuildStaticNavGrid(&data, 512, 512, 32);

    var threaded_system = PathfindingSystem.init(std.testing.allocator);
    defer threaded_system.deinit();
    var threaded_cap = serial_cap;
    threaded_cap.max_worker_scratch_slots = 4;
    try threaded_system.reserve(threaded_cap);
    try threaded_system.rebuildStaticNavGrid(&data, 512, 512, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(count, count);
    // Each agent has a distinct goal cell, forcing a distinct individual solve.
    for (0..count) |i| {
        const gy: f32 = @as(f32, @floatFromInt(i)) * 32.0 + 8.0;
        try appendPathRequest(&stream, .{
            .entity = entities[i],
            .start = .{ .x = 8, .y = gy },
            .goal = .{ .x = 480, .y = gy },
        });
    }

    _ = try serial_system.updateSerial(&stream, 8, .{});
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();
    _ = try threaded_system.update(&stream, 8, &threads, .{ .adaptive = false, .items_per_range = 1 });

    // Every distinct goal must resolve to the same waypoint serially and
    // threaded; a shared worker path stripe would corrupt all-but-one.
    for (0..count) |i| {
        const gy: f32 = @as(f32, @floatFromInt(i)) * 32.0 + 8.0;
        const serial_view = serial_system.statusForWorld(0, .{ .x = 8, .y = gy }, 0, .{ .x = 480, .y = gy }, .default);
        const threaded_view = threaded_system.statusForWorld(0, .{ .x = 8, .y = gy }, 0, .{ .x = 480, .y = gy }, .default);
        try std.testing.expectEqual(PathStatus.available, serial_view.status);
        try std.testing.expectEqual(serial_view.status, threaded_view.status);
        try std.testing.expectEqual(serial_view.next_waypoint.x, threaded_view.next_waypoint.x);
        try std.testing.expectEqual(serial_view.next_waypoint.y, threaded_view.next_waypoint.y);
    }
}

test "pathfinding warmed individual update does not allocate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 128, 128, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 96, .y = 96 } });

    const original_allocator = system.allocator;
    system.allocator = std.testing.failing_allocator;
    const stats = try system.updateSerial(&stream, 8, .{});
    system.allocator = original_allocator;

    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
}

test "pathfinding fixed-capacity unavailable key set has explicit fixed capacity" {
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

test "pathfinding result cache evicts deterministically and stores paths" {
    var stats = PathfindingStats{};
    var cache = ResultCache{};
    defer cache.deinit(std.testing.allocator);
    try cache.reserve(std.testing.allocator, 1, 4, 8);
    var first_key = emptyKey(1);
    first_key.goal.x = 1;
    var second_key = emptyKey(1);
    second_key.goal.x = 2;

    cache.put(first_key, &.{ 0, 1, 2 }, &.{}, 0, &stats);
    try std.testing.expect(cache.find(first_key) != null);
    cache.put(second_key, &.{ 3, 4 }, &.{}, 0, &stats);
    try std.testing.expectEqual(@as(usize, 1), stats.cache_evictions);
    try std.testing.expect(cache.find(first_key) == null);
    const slot = cache.slotIndex(second_key).?;
    const stored = cache.pathSlice(slot, cache.slots.items[slot].result.path_len);
    try std.testing.expectEqual(@as(usize, 2), stored.len);
    try std.testing.expectEqual(@as(u32, 3), stored[0]);
}

// ----------------------------------------------------------------------------
// Abstract-tier and cross-level test fixtures and tests
// ----------------------------------------------------------------------------

// Loads the world tileset metadata used by the demo. Cross-level/abstract tests
// build real `WorldSystem` worlds from it (no test-only production hooks).
fn loadTestWorldMeta(allocator: std.mem.Allocator) !@import("../../assets/world_tileset_meta.zig").WorldTilesetMeta {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(allocator, std.testing.io, "assets");
    return @import("../../assets/world_tileset_meta.zig").load(
        allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
}

fn requireTestTile(meta: *const @import("../../assets/world_tileset_meta.zig").WorldTilesetMeta, name: []const u8) !@import("../world_system.zig").TileId {
    return (meta.tileByName(name) orelse return error.TestExpectedEqual).id;
}

// Capacity tuned for the abstract tier: small chunks so a modest world spans
// several chunks (real portals), plus headroom for cross-level corridor storage.
fn abstractCapacity() PathfindingCapacity {
    return .{
        .max_frame_requests = 8,
        .max_pending_requests = 8,
        .max_cached_results = 16,
        .max_group_fields = 2,
        .max_worker_scratch_slots = 1,
        .max_solved_requests_per_step = 8,
        .max_fallback_requests_per_step = 8,
        .nav_chunk_tiles = 4,
        .max_stitched_path_cells = 256,
        .min_group_field_agents = 1,
    };
}

test "pathfinding cross-level link steers an off-level agent toward the start-level endpoint" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    // 384px = 12x12 nav cells; level 0 and level 1 both open grass floors.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // Bidirectional link from level 0 cell (10,10) to level 1 cell (2,2).
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

    // Agent on level 0 wants a goal on level 1: must route across the link.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), stats.cross_level_solves);
    try std.testing.expectEqual(@as(usize, 1), stats.abstract_solves);

    const view = system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, .{ .x = 304, .y = 304 }, .default);
    try std.testing.expectEqual(PathStatus.available, view.status);
    // First waypoint steers toward the level-0 link endpoint (10,10) center area,
    // i.e. to the right/down of the start cell (0,0).
    try std.testing.expect(view.next_waypoint.x > 16);
    try std.testing.expect(view.next_waypoint.y > 16);
}

test "pathfinding cross-level goal with no link is unavailable, not pending forever" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // No level link added: the two floors are disconnected.

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 0), stats.pending_requests);
    const view = system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, .{ .x = 304, .y = 304 }, .default);
    try std.testing.expectEqual(PathStatus.unavailable, view.status);
}

test "pathfinding blocked link endpoint excludes the link until unblocked and rebuilt" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // World with the level-1 link endpoint cell (2,2) blocked: the link is not live.
    var blocked_world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer blocked_world.deinit();
    _ = try blocked_world.addLevel(0);
    _ = try blocked_world.addDenseLayer(1, 0, .floor, grass);
    try blocked_world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });
    _ = try blocked_world.addSparseTile(1, 2, 2, tree, 0, .obstacle);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &blocked_world, 384, 384, 32);
    const blocked_version = system.graph.version;

    var blocked_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer blocked_stream.deinit();
    try appendPathRequest(&blocked_stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const blocked_stats = try system.updateSerial(&blocked_stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), blocked_stats.unavailable_results);

    // Identical world but the endpoint is open. Rebuilding the same system bumps
    // nav_version (invalidating the prior negative) and the link becomes live.
    var open_world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer open_world.deinit();
    _ = try open_world.addLevel(0);
    _ = try open_world.addDenseLayer(1, 0, .floor, grass);
    try open_world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 5,
        .bidirectional = true,
    });
    try system.rebuildStaticNavGridWithWorld(&data, &open_world, 384, 384, 32);
    try std.testing.expect(system.graph.version != blocked_version);

    var open_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer open_stream.deinit();
    try appendPathRequest(&open_stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const open_stats = try system.updateSerial(&open_stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), open_stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), open_stats.cross_level_solves);
}

test "pathfinding per-level obstacle independence: level 0 obstacle is absent on level 1" {
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
    // Obstacle only on level 0 cell (5,5).
    _ = try world.addSparseTile(0, 5, 5, tree, 0, .obstacle);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    // Cell (5,5) is blocked on level 0 but open on level 1.
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 5, .y = 5 }));
    try std.testing.expect(!system.graph.grid(1).?.isBlockedCell(.{ .x = 5, .y = 5 }));

    // A level-1 solve through (5,5) ignores the level-0 obstacle.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 1,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 176, .y = 176 },
    });
    const stats = try system.updateSerial(&stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    const view = system.statusForWorld(1, .{ .x = 16, .y = 16 }, 1, .{ .x = 176, .y = 176 }, .default);
    try std.testing.expectEqual(PathStatus.available, view.status);
}

test "pathfinding multi-hop same-level corridor travels obstacle-free past a concave wall" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");

    // 512px = 16x16 cells. A full wall at x=8 splits level 0 into left/right
    // components; a same-level teleport bridges (7,8)->(9,8). In the RIGHT component a
    // short CONCAVE wall (column x=11, y=7..10) sits directly between the teleport
    // exit (9,8) and the goal (13,8), so NO straight line connects them -- the path
    // must detour up and over. The right region stays one component (the wall is
    // local), so a corridor exists. Driving the agent in single CELL steps toward each
    // returned waypoint and FAILING on any step into a blocked or non-adjacent cell
    // proves continuous obstacle-free travel -- not a straight-line snap.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer world.deinit();
    for (0..16) |y| {
        _ = try world.addSparseTile(0, 8, @intCast(y), tree, 0, .obstacle);
    }
    var wy: u16 = 7;
    while (wy <= 10) : (wy += 1) {
        _ = try world.addSparseTile(0, 11, wy, tree, 0, .obstacle);
    }
    try world.addLevelLink(.{
        .kind = .teleport,
        .level_a = 0,
        .cell_a = .{ .x = 7, .y = 8 },
        .level_b = 0,
        .cell_b = .{ .x = 9, .y = 8 },
        .traversal_cost = 1,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    capacity.max_cached_results = 8;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32);

    const link_near = GridCell{ .x = 7, .y = 8 };
    const link_far = GridCell{ .x = 9, .y = 8 };
    const goal_cell = GridCell{ .x = 13, .y = 8 };
    const grid = system.graph.grid(0).?;

    var agent = GridCell{ .x = 1, .y = 8 };
    var reached = false;
    var first_via_abstract = false;
    var step: usize = 0;
    while (step < 256) : (step += 1) {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        const start_world = cellCenterWorld(agent);
        try appendPathRequest(&stream, .{
            .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
            .start = start_world,
            .goal = cellCenterWorld(goal_cell),
        });
        const stats = try system.updateSerial(&stream, 8, .{});
        if (step == 0 and stats.abstract_solves != 0) first_via_abstract = true;
        const view = system.statusForWorld(0, start_world, 0, cellCenterWorld(goal_cell), .default);
        if (view.status == .unavailable) return error.TestUnexpectedResult;
        if (view.status != .available) continue;
        if (agent.x == goal_cell.x and agent.y == goal_cell.y) {
            reached = true;
            break;
        }
        const target = grid.worldToCellClamped(view.next_waypoint);
        if (target.x == agent.x and target.y == agent.y) continue;
        // Discrete teleport jump is allowed only at the link endpoint; otherwise the
        // returned waypoint must be a physically ADJACENT OPEN cell. A grid-adjacent
        // stitched path yields exactly that; a straight-line cut would produce a
        // non-adjacent or blocked heading and fail here.
        if (agent.x == link_near.x and agent.y == link_near.y and target.x == link_far.x and target.y == link_far.y) {
            agent = link_far;
            continue;
        }
        if (@abs(target.x - agent.x) > 1 or @abs(target.y - agent.y) > 1) return error.TestUnexpectedResult;
        if (grid.isBlockedCell(target)) return error.TestUnexpectedResult;
        agent = target;
    }
    try std.testing.expect(first_via_abstract);
    try std.testing.expect(reached);
}

fn cellCenterWorld(cell: GridCell) math.Vec2 {
    return .{
        .x = @as(f32, @floatFromInt(cell.x)) * 32 + 16,
        .y = @as(f32, @floatFromInt(cell.y)) * 32 + 16,
    };
}

test "pathfinding abstract seeding scans only the start level and stays within budget" {
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    // Build a single-level and a multi-level world of the SAME size and identical
    // level-0 topology. Seeding scans only the start level's portals, so level 0's
    // seeded portal count must be IDENTICAL regardless of how many other levels and
    // how many total portals exist. This proves seeding is per-level-bounded.
    var one_data = DataSystem.init(std.testing.allocator);
    defer one_data.deinit();
    var one_world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer one_world.deinit();
    var one_system = PathfindingSystem.init(std.testing.allocator);
    defer one_system.deinit();
    try one_system.reserve(abstractCapacity());
    try one_system.rebuildStaticNavGridWithWorld(&one_data, &one_world, 512, 512, 32);
    const one_level_start_portals = one_system.graph.levelPortals(0).len;

    var four_data = DataSystem.init(std.testing.allocator);
    defer four_data.deinit();
    var four_world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer four_world.deinit();
    _ = try four_world.addLevel(0);
    _ = try four_world.addLevel(0);
    _ = try four_world.addLevel(0);
    _ = try four_world.addDenseLayer(1, 0, .floor, grass);
    _ = try four_world.addDenseLayer(2, 0, .floor, grass);
    _ = try four_world.addDenseLayer(3, 0, .floor, grass);
    var four_system = PathfindingSystem.init(std.testing.allocator);
    defer four_system.deinit();
    try four_system.reserve(abstractCapacity());
    try four_system.rebuildStaticNavGridWithWorld(&four_data, &four_world, 512, 512, 32);
    const four_level_start_portals = four_system.graph.levelPortals(0).len;

    try std.testing.expect(one_level_start_portals > 0);
    // The extra open levels add many total portals, but the start level's seeded
    // count is unchanged: seeding never touches the other levels' portals.
    try std.testing.expect(four_system.graph.portals.items.len > four_level_start_portals);
    try std.testing.expectEqual(one_level_start_portals, four_level_start_portals);

    // The per-query abstract search completes within the node budget regardless of
    // world size: a long diagonal solve never surfaces saturation as a hard negative.
    const extents = [_]f32{ 512, 1024 };
    for (extents) |extent| {
        var data = DataSystem.init(std.testing.allocator);
        defer data.deinit();
        var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, extent, extent);
        defer world.deinit();
        var system = PathfindingSystem.init(std.testing.allocator);
        defer system.deinit();
        try system.reserve(abstractCapacity());
        try system.rebuildStaticNavGridWithWorld(&data, &world, extent, extent, 32);

        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        try appendPathRequest(&stream, .{
            .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
            .start = .{ .x = 16, .y = 16 },
            .goal = .{ .x = extent - 16, .y = extent - 16 },
        });
        const stats = try system.updateSerial(&stream, 8, .{});
        try std.testing.expectEqual(@as(usize, 0), stats.unavailable_results);
    }
}

test "pathfinding cross-level group member falls back to an individual corridor" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
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

    const on_level = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const off_level = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const goal = math.Vec2{ .x = 304, .y = 304 }; // goal on level 1

    // Step 1: a level-1 group member declares the goal so the field builds on
    // level 1; the off-level member (start_level 0) also requests.
    var first = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer first.deinit();
    try first.reserve(2, 2);
    try appendPathRequest(&first, .{ .entity = on_level, .kind = .group, .start_level = 1, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
    try appendPathRequest(&first, .{ .entity = off_level, .kind = .group, .start_level = 0, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
    _ = try system.updateSerial(&first, 8, .{});

    // Advance until the group field is ready on level 1.
    var guard: usize = 0;
    while (guard < 64) : (guard += 1) {
        var ready = false;
        for (system.group_fields.items) |field| {
            if (field.state == .ready) ready = true;
        }
        if (ready) break;
        var step_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer step_stream.deinit();
        try step_stream.reserve(2, 2);
        try appendPathRequest(&step_stream, .{ .entity = on_level, .kind = .group, .start_level = 1, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
        try appendPathRequest(&step_stream, .{ .entity = off_level, .kind = .group, .start_level = 0, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
        _ = try system.updateSerial(&step_stream, 8, .{});
    }

    // The on-level member samples the ready group field.
    const on_view = system.statusForWorld(1, .{ .x = 16, .y = 16 }, 1, goal, .default);
    try std.testing.expectEqual(PathStatus.available, on_view.status);

    // After the field is ready, the off-level member must still reach .available
    // via an individual cross-level corridor (pins C1: no permanent stall).
    var reached = false;
    var off_guard: usize = 0;
    while (off_guard < 64) : (off_guard += 1) {
        const off_view = system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, goal, .default);
        if (off_view.status == .available) {
            reached = true;
            break;
        }
        try std.testing.expect(off_view.status != .unavailable);
        var step_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer step_stream.deinit();
        try step_stream.reserve(2, 2);
        try appendPathRequest(&step_stream, .{ .entity = on_level, .kind = .group, .start_level = 1, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
        try appendPathRequest(&step_stream, .{ .entity = off_level, .kind = .group, .start_level = 0, .goal_level = 1, .start = .{ .x = 16, .y = 16 }, .goal = goal });
        _ = try system.updateSerial(&step_stream, 8, .{});
    }
    try std.testing.expect(reached);
}

test "pathfinding directed link traverses one way only" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // Directed (non-bidirectional) link: level 0 -> level 1 only.
    try world.addLevelLink(.{
        .kind = .teleport,
        .level_a = 0,
        .cell_a = .{ .x = 10, .y = 10 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 1,
        .bidirectional = false,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    // A -> B (0 -> 1) succeeds.
    var forward = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer forward.deinit();
    try appendPathRequest(&forward, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const forward_stats = try system.updateSerial(&forward, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), forward_stats.available_results);

    // B -> A (1 -> 0) fails: no reverse edge.
    var backward = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer backward.deinit();
    try appendPathRequest(&backward, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 1,
        .goal_level = 0,
        .start = .{ .x = 80, .y = 80 },
        .goal = .{ .x = 16, .y = 16 },
    });
    const backward_stats = try system.updateSerial(&backward, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), backward_stats.unavailable_results);
}

test "pathfinding cross-level corridor stays obstacle-free on the destination level" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // Level 0 open; level 1 open except a concave wall between the link exit (2,2)
    // and the goal (13,8), forcing the destination-level segment to route around it.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    var wy: u16 = 0;
    while (wy <= 10) : (wy += 1) {
        _ = try world.addSparseTile(1, 6, wy, tree, 0, .obstacle); // wall x=6, y=0..10
    }
    try world.addLevelLink(.{
        .kind = .stair,
        .level_a = 0,
        .cell_a = .{ .x = 2, .y = 2 },
        .level_b = 1,
        .cell_b = .{ .x = 2, .y = 2 },
        .traversal_cost = 1,
        .bidirectional = true,
    });

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = abstractCapacity();
    capacity.max_cached_results = 8;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32);

    const link0 = GridCell{ .x = 2, .y = 2 };
    const link1 = GridCell{ .x = 2, .y = 2 };
    const goal_cell = GridCell{ .x = 13, .y = 8 };
    const grid1 = system.graph.grid(1).?;

    // Phase 1: walk level 0 to the link, in single open cell steps.
    var agent = GridCell{ .x = 14, .y = 14 };
    var level: u16 = 0;
    var reached = false;
    var crossed_link = false;
    var step: usize = 0;
    while (step < 256) : (step += 1) {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        const start_world = cellCenterWorld(agent);
        try appendPathRequest(&stream, .{
            .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
            .start_level = level,
            .goal_level = 1,
            .start = start_world,
            .goal = cellCenterWorld(goal_cell),
        });
        _ = try system.updateSerial(&stream, 8, .{});
        const view = system.statusForWorld(level, start_world, 1, cellCenterWorld(goal_cell), .default);
        if (view.status == .unavailable) return error.TestUnexpectedResult;
        if (view.status != .available) continue;
        if (level == 1 and agent.x == goal_cell.x and agent.y == goal_cell.y) {
            reached = true;
            break;
        }
        // At the level-0 link endpoint, cross to level 1's endpoint (discrete jump).
        if (level == 0 and agent.x == link0.x and agent.y == link0.y) {
            level = 1;
            agent = link1;
            crossed_link = true;
            continue;
        }
        const grid = system.graph.grid(level).?;
        const target = grid.worldToCellClamped(view.next_waypoint);
        if (target.x == agent.x and target.y == agent.y) continue;
        // On level 1, every heading must be an adjacent OPEN cell (obstacle-free).
        if (@abs(target.x - agent.x) > 1 or @abs(target.y - agent.y) > 1) return error.TestUnexpectedResult;
        if (level == 1 and grid1.isBlockedCell(target)) return error.TestUnexpectedResult;
        agent = target;
    }
    try std.testing.expect(crossed_link);
    try std.testing.expect(reached);
}

test "pathfinding abstract saturation returns pending, not a cached unavailable" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 512, 512);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    // A live cross-level link so a corridor genuinely exists to be searched.
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
    var capacity = abstractCapacity();
    // A tiny abstract node budget saturates the open/slot table before the search
    // can reach the goal-level portal, even though a corridor exists.
    capacity.max_abstract_nodes = 1;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, 512, 512, 32);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{
        .entity = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false),
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const stats = try system.updateSerial(&stream, 8, .{});
    // Saturation spills to a later frame: counted as budget_exhausted, NOT cached
    // as a hard negative, and the status reads pending (retryable).
    try std.testing.expect(stats.budget_exhausted >= 1);
    try std.testing.expectEqual(@as(usize, 0), stats.unavailable_results);
    try std.testing.expectEqual(@as(usize, 1), stats.pending_requests);
    const view = system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, .{ .x = 304, .y = 304 }, .default);
    try std.testing.expectEqual(PathStatus.pending, view.status);
}

test "pathfinding component-scoped portal seeding only scans the start component" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    // A 12x12-cell world split into TWO disconnected open regions by a SOLID vertical
    // tree wall at column 5 (no gaps). Left (cols 0..4) and right (cols 6..11) are
    // different connected components on level 0, each spanning several 4-tile chunks
    // so each has its own border portals.
    const built = try buildCorridorWorld(&meta, &.{});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    const grid = system.graph.grid(0).?;
    const left_cell = grid.indexForCell(.{ .x = 1, .y = 5 }).?;
    const right_cell = grid.indexForCell(.{ .x = 9, .y = 5 }).?;
    const left_component = grid.componentOf(left_cell);
    const right_component = grid.componentOf(right_cell);
    // The wall genuinely splits the world into two components.
    try std.testing.expect(left_component != no_component);
    try std.testing.expect(right_component != no_component);
    try std.testing.expect(left_component != right_component);

    // The (level, component) index partitions the level's portals: every portal in a
    // component's slice belongs to that component, the two slices are disjoint, and
    // together they cover all of the level's portals. Seeding therefore scans ONLY the
    // start component's portals instead of the level's full border.
    const left_portals = system.graph.levelComponentPortals(0, left_component);
    const right_portals = system.graph.levelComponentPortals(0, right_component);
    try std.testing.expect(left_portals.len > 0);
    try std.testing.expect(right_portals.len > 0);
    for (left_portals) |node| {
        try std.testing.expectEqual(left_component, grid.componentOf(system.graph.portals.items[node].cell_index));
    }
    for (right_portals) |node| {
        try std.testing.expectEqual(right_component, grid.componentOf(system.graph.portals.items[node].cell_index));
    }
    try std.testing.expectEqual(system.graph.levelPortals(0).len, left_portals.len + right_portals.len);

    // Correctness preserved: a cross-component goal (no link) is unavailable, and a
    // same-component goal stays reachable.
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);
    const cross = try solveStep(&system, requester, tileCenter(1, 5), tileCenter(9, 5));
    try std.testing.expectEqual(@as(usize, 1), cross.unavailable_results);
    const same = try solveStep(&system, requester, tileCenter(1, 1), tileCenter(1, 10));
    try std.testing.expectEqual(@as(usize, 1), same.available_results);
}

test "pathfinding warmed cross-level abstract solve does not allocate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
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
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(1, 1);
    try appendPathRequest(&stream, .{
        .entity = requester,
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });

    // A multi-hop abstract+stitched solve under the failing allocator must not touch
    // the heap (all scratch and corridor stripes were warmed at reserve/rebuild).
    const original_allocator = system.allocator;
    system.allocator = std.testing.failing_allocator;
    const stats = try system.updateSerial(&stream, 8, .{});
    system.allocator = original_allocator;

    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), stats.abstract_solves);
    try std.testing.expectEqual(@as(usize, 1), stats.cross_level_solves);
}

// ----------------------------------------------------------------------------
// Incremental nav update tests
// ----------------------------------------------------------------------------

// World center (px) of tile cell (cx, cy) at the demo 32px tile size, used to seed
// requests/queries at a known nav cell.
fn tileCenter(cx: u16, cy: u16) math.Vec2 {
    return .{ .x = @as(f32, @floatFromInt(cx)) * 32 + 16, .y = @as(f32, @floatFromInt(cy)) * 32 + 16 };
}

// Builds a 12x12-tile single-level world with a vertical tree wall at column 5 that
// leaves open gaps at the given rows. The base floor is open grass, so the only way
// across the wall is through a gap. Returns the world plus the obstacle layer index
// so a test can flip the gap cells.
fn buildCorridorWorld(meta: *const @import("../../assets/world_tileset_meta.zig").WorldTilesetMeta, open_rows: []const u16) !struct { world: WorldSystem, wall_layer: usize } {
    const grass = try requireTestTile(meta, "grass");
    const tree = try requireTestTile(meta, "tree_0");
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, meta, 384, 384);
    errdefer world.deinit();
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    var y: u16 = 0;
    while (y < 12) : (y += 1) {
        var open = false;
        for (open_rows) |row| {
            if (row == y) open = true;
        }
        if (open) continue;
        _ = try world.setDenseTile(wall_layer, 5, y, tree);
    }
    return .{ .world = world, .wall_layer = wall_layer };
}

fn solveStep(system: *PathfindingSystem, requester: EntityId, start: math.Vec2, goal: math.Vec2) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
    return system.updateSerial(&stream, 8, .{});
}

test "pathfinding incremental update reroutes when a corridor gap is flipped to blocking" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");

    // Two gaps in the wall: the nearer (row 3) is used first; closing it forces a
    // reroute through the far gap (row 9).
    const built = try buildCorridorWorld(&meta, &.{ 3, 9 });
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    const before = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 1), before.available_results);
    const view_before = system.statusForWorld(0, start, 0, goal, .default);
    try std.testing.expectEqual(PathStatus.available, view_before.status);

    // The cached path must cross the wall through the near gap (row 3): some stored
    // path cell sits on the wall column at row 3.
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 3));
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 5, 9));

    const version_before = system.graph.version;

    // Flip the near gap (5,3) to a tree (now blocking) via the world tile API.
    const changed = (try world.setDenseTile(built.wall_layer, 5, 3, tree)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement != changed.new_blocks_movement);
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 1), nav_stats.version_bumps);
    try std.testing.expect(system.graph.version != version_before);
    // The previously cached completed entry was keyed on the old nav_version: it must
    // no longer answer this goal until re-solved.
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, goal, .default).status);

    // Next solve produces a DIFFERENT path that avoids the now-blocked near gap and
    // routes through the far gap (row 9).
    const after = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 1), after.available_results);
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, start, 0, goal, .default).status);
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 5, 3));
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 9));
}

// Returns whether the cached completed (or stitched) path for the goal includes the
// nav cell at tile (cx, cy). Walks the stored cells directly; used to assert a route
// crosses a specific corridor gap.
fn cachedPathTouchesCell(system: *const PathfindingSystem, start: math.Vec2, goal: math.Vec2, cx: u16, cy: u16) bool {
    const key = system.graph.keyForWorld(0, goal, .default) orelse return false;
    _ = start;
    const slot = system.completed.slotIndex(key) orelse return false;
    const result = system.completed.slots.items[slot].result;
    const grid = system.graph.grid(0) orelse return false;
    const target = grid.indexForCell(.{ .x = @intCast(cx), .y = @intCast(cy) }) orelse return false;
    if (result.stitched_len != 0) {
        for (system.completed.stitchedSlice(slot, result.stitched_len)) |sc| {
            if (sc.level == 0 and sc.cell == target) return true;
        }
        return false;
    }
    for (system.completed.pathSlice(slot, result.path_len)) |cell| {
        if (cell == target) return true;
    }
    return false;
}

test "pathfinding incremental update disconnects a goal when the last gap is closed" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");

    // A single gap at row 3 is the only crossing.
    const built = try buildCorridorWorld(&meta, &.{3});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    try std.testing.expectEqual(@as(usize, 1), (try solveStep(&system, requester, start, goal)).available_results);

    const changed = (try world.setDenseTile(built.wall_layer, 5, 3, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), nav_stats.version_bumps);

    // The wall is now solid: the goal is truly disconnected, so the re-solve is a
    // definitive unavailable rather than a stale cached available.
    const after = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 1), after.unavailable_results);
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, start, 0, goal, .default).status);
}

test "pathfinding incremental update opens a shorter path when a tile is unblocked" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");

    // Start with only the far gap (row 9) open; the near gap (row 3) is a tree.
    const built = try buildCorridorWorld(&meta, &.{9});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    try std.testing.expectEqual(@as(usize, 1), (try solveStep(&system, requester, start, goal)).available_results);
    // Path crosses only at row 9 (the near gap is closed).
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 9));
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 5, 3));

    // Open the near gap (5,3) back to grass.
    const changed = (try world.setDenseTile(built.wall_layer, 5, 3, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

    // The now-shorter route uses the near gap.
    try std.testing.expectEqual(@as(usize, 1), (try solveStep(&system, requester, start, goal)).available_results);
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 3));
}

test "pathfinding incremental update leaves an unaffected second level untouched" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    const level1_layer = try world.addDenseLayer(1, 0, .floor, grass);
    // A distinctive obstacle on level 1 cell (7,7) so we can confirm level 1 is
    // unchanged by an edit on level 0.
    _ = try world.setDenseTile(level1_layer, 7, 7, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);

    // Snapshot level 1's blocked count and component label of its obstacle cell.
    const level1_blocked_before = system.graph.grid(1).?.blocked_count;
    const level1_cell77 = system.graph.grid(1).?.indexForCell(.{ .x = 7, .y = 7 }).?;
    try std.testing.expect(system.graph.grid(1).?.isBlockedIndex(level1_cell77));

    // Edit a tile on LEVEL 0 only.
    const obstacle_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    const changed = (try world.setDenseTile(obstacle_layer, 2, 2, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});

    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), nav_stats.full_relabel);
    // Level 1's mask is byte-for-byte what it was: the incremental update never
    // re-marked it. Its obstacle cell and blocked count are intact.
    try std.testing.expectEqual(level1_blocked_before, system.graph.grid(1).?.blocked_count);
    try std.testing.expect(system.graph.grid(1).?.isBlockedIndex(level1_cell77));
    // Level 0 gained the new obstacle.
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 2, .y = 2 }));
}

test "pathfinding incremental update with no real change does no work" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    const version_before = system.graph.version;

    // An empty edit batch is a no-op: no version bump, no counters.
    const stats = try system.applyNavUpdates(&data, &world, &.{});
    try std.testing.expectEqual(@as(usize, 0), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.version_bumps);
    try std.testing.expectEqual(version_before, system.graph.version);
}

test "pathfinding incremental update is allocation-free at steady state (within init high-water mark)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // The corridor world opens its gaps at the INIT build, so the abstract buffers
    // reach their high-water capacity during rebuild. Blocking an existing open gap
    // (removes portals) and reopening it (re-adds <= the init count) both stay WITHIN
    // that high-water mark — the real steady-state contract.
    const built = try buildCorridorWorld(&meta, &.{ 3, 9 });
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    const high_water = system.graph.portals.items.len;
    try std.testing.expect(high_water > 0);

    // The failing allocator must cover BOTH the system AND the nav graph (which holds
    // its own captured allocator copy): every graph-rebuild buffer (portals/edges/
    // cell_to_portal/build scratch) flows through graph.allocator, so swapping only
    // system.allocator would let a graph allocation slip through undetected.
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    // Block an existing open gap: removes portals, stays within high-water.
    const blocked = (try world.setDenseTile(built.wall_layer, 5, 3, tree)) orelse return error.TestExpectedEqual;
    const block_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = blocked.level, .x = blocked.x, .y = blocked.y }});
    try std.testing.expectEqual(@as(usize, 1), block_stats.incremental_rebuilds);

    // Reopen the same gap: re-adds portals back to <= the init high-water count, so it
    // reuses retained capacity and allocates nothing.
    const opened = (try world.setDenseTile(built.wall_layer, 5, 3, grass)) orelse return error.TestExpectedEqual;
    const open_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = opened.level, .x = opened.x, .y = opened.y }});
    try std.testing.expectEqual(@as(usize, 1), open_stats.incremental_rebuilds);
    try std.testing.expect(system.graph.portals.items.len <= high_water);

    system.graph.allocator = original;
    system.allocator = original;
}

test "pathfinding incremental update expands beyond init high-water mark with bounded growth" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // Start fully walled so the init build has zero portals (minimal high-water).
    // Opening a block later expands the abstract graph past it. This is the documented
    // amortized-growth exception (a cold, event-triggered path), NOT the alloc-free
    // contract: it must SUCCEED and produce the new topology, using the real allocator.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, tree);
    var y: u16 = 0;
    while (y < 12) : (y += 1) {
        var x: u16 = 0;
        while (x < 12) : (x += 1) {
            _ = try world.setDenseTile(wall_layer, x, y, tree);
        }
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, 384, 384, 32);
    try std.testing.expectEqual(@as(usize, 0), system.graph.portals.items.len);

    // Open a 6x6 block spanning chunk borders, creating new portals past the (zero)
    // init high-water mark. The growth is allowed and the build completes correctly.
    var edits = std.ArrayList(NavCellEdit).empty;
    defer edits.deinit(std.testing.allocator);
    y = 2;
    while (y < 8) : (y += 1) {
        var x: u16 = 2;
        while (x < 8) : (x += 1) {
            const opened = (try world.setDenseTile(wall_layer, x, y, grass)) orelse continue;
            try edits.append(std.testing.allocator, .{ .level = opened.level, .x = opened.x, .y = opened.y });
        }
    }
    const stats = try system.applyNavUpdates(&data, &world, edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 1), stats.version_bumps);
    // The expansion produced new portals (the abstract graph grew past init).
    try std.testing.expect(system.graph.portals.items.len > 0);

    // A subsequent edit within the NEW high-water mark is allocation-free again.
    const closed = (try world.setDenseTile(wall_layer, 4, 4, tree)) orelse return error.TestExpectedEqual;
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const close_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = closed.level, .x = closed.x, .y = closed.y }});
    system.graph.allocator = original;
    system.allocator = original;
    try std.testing.expectEqual(@as(usize, 1), close_stats.incremental_rebuilds);
}

test "pathfinding incremental update flips cross-level link liveness when the endpoint cell changes" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    const level1_floor = try world.addDenseLayer(1, 0, .floor, grass);
    // Obstacle layer on level 1 so the link endpoint cell (2,2) can be flipped via the
    // dense tile API (which emits a WorldTileChangedEvent that drives applyNavUpdates).
    const level1_obstacle = try world.addDenseLayer(1, 0, .obstacle, grass);
    _ = level1_floor;
    _ = try world.setDenseTile(level1_obstacle, 2, 2, tree); // endpoint blocked
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
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    // Blocked endpoint: the link is not live, so the cross-level goal is unavailable.
    var blocked_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer blocked_stream.deinit();
    try appendPathRequest(&blocked_stream, .{
        .entity = requester,
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    try std.testing.expectEqual(@as(usize, 1), (try system.updateSerial(&blocked_stream, 8, .{})).unavailable_results);

    // Open the endpoint cell (2,2) on level 1 via the world tile API + incremental
    // update. buildLinkEdges re-derives link liveness against the current masks, so
    // the link becomes live and the same cross-level goal is now reachable.
    const changed = (try world.setDenseTile(level1_obstacle, 2, 2, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const nav_stats = try system.applyNavUpdates(&data, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }});
    try std.testing.expectEqual(@as(usize, 1), nav_stats.version_bumps);

    var open_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer open_stream.deinit();
    try appendPathRequest(&open_stream, .{
        .entity = requester,
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    const open_stats = try system.updateSerial(&open_stream, 8, .{});
    try std.testing.expectEqual(@as(usize, 1), open_stats.available_results);
    try std.testing.expectEqual(@as(usize, 1), open_stats.cross_level_solves);
}

// Drives `count` simultaneous single-goal individual requests in one step, one per
// requester, returning the step stats. Used by the elastic-capacity tests.
fn driveAgentCount(system: *PathfindingSystem, requesters: []const EntityId, count: usize) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try stream.reserve(count, count);
    for (requesters[0..count], 0..) |entity, i| {
        const start_x: f32 = 8.0 + @as(f32, @floatFromInt(i)) * 32.0;
        try appendPathRequest(&stream, .{ .entity = entity, .start = .{ .x = start_x, .y = 8 }, .goal = .{ .x = 480, .y = 480 } });
    }
    return system.updateSerial(&stream, count, .{});
}

test "pathfinding capacity grows when agent count jumps past the current cap" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [40]EntityId = undefined;
    for (0..requesters.len) |i| {
        requesters[i] = try addNavBody(&data, .{ .x = @floatFromInt(i * 16), .y = 0 }, .{ .x = 8, .y = 8 }, false);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 256;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    // Floored at the initial reserve (min_capacity_floor = 8).
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);

    // A jump to 40 agents grows the live capacity amortized to at least 40 and the
    // per-step caps follow; every distinct goal still solves (here all share one).
    const stats = try driveAgentCount(&system, &requesters, 40);
    try std.testing.expect(system.effective_agent_capacity >= 40);
    try std.testing.expect(system.capacity.max_pending_requests >= 40);
    try std.testing.expect(system.completed.slots.items.len >= 40 * cached_results_per_agent);
    try std.testing.expectEqual(@as(usize, 1), stats.accepted_requests);
    try std.testing.expectEqual(@as(usize, 1), stats.available_results);
}

test "pathfinding per-frame solve budget stays fixed while queue and cache scale to population" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 4096;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    // A 4096-agent population grows the queue and cache to population, but the
    // per-frame A* solve and fallback budgets stay pinned to the fixed ceiling.
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = .{ .x = 8, .y = 8 }, .goal = .{ .x = 480, .y = 480 } });
    _ = try system.updateSerial(&stream, 4096, .{});

    try std.testing.expectEqual(@as(usize, 4096), system.capacity.max_pending_requests);
    try std.testing.expectEqual(@as(usize, 4096), system.capacity.max_frame_requests);
    try std.testing.expectEqual(@as(usize, 4096 * cached_results_per_agent), system.capacity.max_cached_results);
    // Solve/fallback budgets capped at the fixed per-frame ceiling, NOT population.
    try std.testing.expectEqual(default_max_solves_per_frame, system.capacity.max_solved_requests_per_step);
    try std.testing.expectEqual(default_max_solves_per_frame, system.capacity.max_fallback_requests_per_step);
    // The worker path-pool stride sizes off the fixed solve ceiling, not population.
    try std.testing.expectEqual(default_max_solves_per_frame * system.capacity.max_stored_path_cells, system.worker_path_pool.items.len);
    try std.testing.expect(system.solve_results.capacity <= default_max_solves_per_frame * 2);
}

test "pathfinding capacity shrinks only after the sustained low-load window" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [40]EntityId = undefined;
    for (0..requesters.len) |i| {
        requesters[i] = try addNavBody(&data, .{ .x = @floatFromInt(i * 16), .y = 0 }, .{ .x = 8, .y = 8 }, false);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 256;
    capacity.capacity_shrink_window = 5;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    _ = try driveAgentCount(&system, &requesters, 40);
    const grown = system.effective_agent_capacity;
    try std.testing.expect(grown >= 40);

    // Low load (1 agent, below half capacity) for fewer than the window steps: the
    // hysteresis holds capacity steady, no shrink yet.
    for (0..capacity.capacity_shrink_window - 1) |_| {
        _ = try driveAgentCount(&system, &requesters, 1);
        try std.testing.expectEqual(grown, system.effective_agent_capacity);
    }
    // The window-th sustained low-load step shrinks toward the floor.
    _ = try driveAgentCount(&system, &requesters, 1);
    try std.testing.expectEqual(min_capacity_floor, system.effective_agent_capacity);
}

test "pathfinding capacity stays unchanged across a steady-state solve" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var requesters: [16]EntityId = undefined;
    for (0..requesters.len) |i| {
        requesters[i] = try addNavBody(&data, .{ .x = @floatFromInt(i * 16), .y = 0 }, .{ .x = 8, .y = 8 }, false);
    }

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 256;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    // Grow once to a steady 16-agent load.
    _ = try driveAgentCount(&system, &requesters, 16);
    const steady_cap = system.effective_agent_capacity;
    const steady_pending = system.pending.capacity;
    const steady_cache = system.completed.slots.items.len;
    const steady_pool = system.worker_path_pool.items.len;
    // A constant agent count holds capacity (and every pool's backing) fixed across
    // many steps, so the per-step solve loop never reallocates after warmup.
    for (0..30) |_| {
        _ = try driveAgentCount(&system, &requesters, 16);
        try std.testing.expectEqual(steady_cap, system.effective_agent_capacity);
        try std.testing.expectEqual(steady_pending, system.pending.capacity);
        try std.testing.expectEqual(steady_cache, system.completed.slots.items.len);
        try std.testing.expectEqual(steady_pool, system.worker_path_pool.items.len);
    }
}

test "pathfinding group-field threshold scales with the live capacity ratio" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const a = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);
    const b = try addNavBody(&data, .{ .x = 32, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // Real default ratio (0.25), tiny budget so the floor governs at small scale.
    try system.reserve(.{ .max_group_fields = 2, .max_worker_scratch_slots = 1, .max_agent_budget = 64 });
    try system.rebuildStaticNavGrid(&data, 512, 512, 32);

    // At the floor capacity (8), the threshold is ratio x cap = floor(0.25 x 8) = 2:
    // a tiny crowd engages the field with few agents, with no knob to bump.
    try std.testing.expectEqual(@as(usize, 2), system.groupFieldThreshold());

    const goal = math.Vec2{ .x = 400, .y = 400 };
    var built: usize = 0;
    // Two same-goal group agents per step reach the scaled threshold via the decaying
    // accumulator (equilibrium ~2x intake), so the field engages at small scale.
    for (0..4) |_| {
        var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
        defer stream.deinit();
        try stream.reserve(2, 2);
        try appendPathRequest(&stream, .{ .entity = a, .kind = .group, .start = .{ .x = 8, .y = 8 }, .goal = goal });
        try appendPathRequest(&stream, .{ .entity = b, .kind = .group, .start = .{ .x = 40, .y = 8 }, .goal = goal });
        const stats = try system.updateSerial(&stream, 2, .{});
        built += stats.group_fields_built;
    }
    try std.testing.expect(built >= 1);
}
