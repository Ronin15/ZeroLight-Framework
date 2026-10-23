// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The nav builds and the post-commit nav reaction of `PathfindingSystem`: nav is built over
//! a bounds rect or every level of a world; the collider sync and terrain writers record
//! their changes as pending marks into room reserved before their write (`nav_mark`
//! interprets terrain events, threaded per event range, merged in range order); each step's
//! apply builds the levels the world added, rebuilds the levels whose content revision
//! moved, and applies the marks and new links as one batch with its scoped eviction, then
//! emits one `nav_region_invalidated` when the graph changed. Free functions over
//! `*PathfindingSystem`; the system exposes the public ones as its declarations.

const std = @import("std");
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const navDispatch = @import("system.zig").navDispatch;
const simd = @import("../../../core/simd.zig");
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const maxRangeCount = @import("../../../app/thread_system.zig").maxRangeCount;
const runShaped = @import("../../../app/thread_system.zig").runShaped;
const StageShape = @import("../../../app/thread_system.zig").StageShape;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const runtime_perf_log = @import("../../../app/runtime_perf_log.zig");
const StageTimer = runtime_perf_log.StageTimer;
const DataSystem = @import("../../data_system.zig").DataSystem;
const StructuralCommand = @import("../../data_system.zig").StructuralCommand;
const EntityTemplate = @import("../../data_system.zig").EntityTemplate;
const WorldSystem = @import("../../world/system.zig").WorldSystem;
const ChunkGridError = @import("../../world/system.zig").ChunkGridError;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const SimulationEvent = @import("../../simulation.zig").SimulationEvent;
const NavInvalidationReason = @import("../../simulation.zig").NavInvalidationReason;
const StaticColliderSystem = @import("../static_colliders.zig").StaticColliderSystem;
const ColliderChange = @import("../static_colliders.zig").ColliderChange;
const NavExtent = @import("nav_graph.zig").NavExtent;
const NavUpdateThreads = @import("nav_graph.zig").NavUpdateThreads;
const eviction = @import("eviction.zig");
const publish = @import("publish.zig");
const types = @import("types.zig");
const NavMark = @import("types.zig").NavMark;
const NavUpdateStats = @import("types.zig").NavUpdateStats;

// A nav build's failures: memory (an exhausted id pool included), or a budget or level grid
// past its index widths. A nav apply's: memory, an exhausted id pool included.
const NavBuildError = error{OutOfMemory} || types.BudgetError || ChunkGridError;
const NavApplyError = error{OutOfMemory};

/// Pending-mark staging for `nav_mark`, on thread-shared record alignment.
pub const NavMarkList = std.array_list.Aligned(NavMark, .fromByteUnits(thread_shared_record_alignment));
/// `nav_mark` range tallies, on thread-shared record alignment.
pub const NavMarkTallyList = std.array_list.Aligned(NavMarkTally, .fromByteUnits(thread_shared_record_alignment));

/// One `nav_mark` range's mark count, padded to its own cache line.
pub const NavMarkTally = struct {
    count: usize align(thread_shared_record_alignment) = 0,
};

/// `nav_mark` range alignment: every range's staging window (one mark slot per event)
/// starts on a cache line.
pub const nav_mark_range_alignment_items: usize = 4 * simd.lane_count;

comptime {
    std.debug.assert((nav_mark_range_alignment_items * @sizeOf(NavMark)) % thread_shared_record_alignment == 0);
    std.debug.assert(@sizeOf(NavMarkTally) % thread_shared_record_alignment == 0);
}

/// The extent of a world-less build: one level over the bounds rect in `cell_size` cells
/// and `capacity.nav_chunk_tiles` chunks.
pub fn boundsNavExtent(self: *const PathfindingSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) NavExtent {
    return .{ .bounds = .{
        .width = bounds_width,
        .height = bounds_height,
        .cell_size = cell_size,
        .chunk_tiles = self.capacity.nav_chunk_tiles,
    } };
}

/// The extent of a build over every level of `world`.
pub fn worldNavExtent(world: *const WorldSystem) NavExtent {
    return .{ .world = world };
}

/// Builds world-less nav over the bounds rect with the statics `data` holds now, through
/// a static-collider build discarded afterwards. A nav that later applies changes takes
/// its colliders from the caller (`rebuildNavFromColliders`).
pub fn rebuildStaticNavGrid(self: *PathfindingSystem, data: *const DataSystem, bounds_width: f32, bounds_height: f32, cell_size: f32) NavBuildError!void {
    try rebuildNavFromData(self, data, boundsNavExtent(self, bounds_width, bounds_height, cell_size), null);
}

/// Builds nav over every level of `world` with the statics `data` holds now, through a
/// static-collider build discarded afterwards: nav cells are the world's tiles and nav
/// chunks its chunks. Fails loudly (`ChunkGridError`) when the nav grid's index widths
/// do not fit, before sizing anything from them.
pub fn rebuildStaticNavGridWithWorld(self: *PathfindingSystem, data: *const DataSystem, world: *const WorldSystem, thread_system: ?*ThreadSystem) NavBuildError!void {
    try rebuildNavFromData(self, data, .{ .world = world }, thread_system);
}

fn rebuildNavFromData(self: *PathfindingSystem, data: *const DataSystem, extent: NavExtent, thread_system: ?*ThreadSystem) NavBuildError!void {
    var colliders = StaticColliderSystem.init(self.allocator);
    defer colliders.deinit();
    try colliders.rebuild(data, try extent.colliderGeometry(), thread_system);
    try rebuildNavFromColliders(self, &colliders, extent, thread_system);
}

/// Builds nav over `extent` with `colliders`' rows, which must be placed on the
/// extent's cell grid (`NavExtent.colliderGeometry`). Every later apply passes the same
/// colliders, synced at the commit seam.
pub fn rebuildNavFromColliders(self: *PathfindingSystem, colliders: *const StaticColliderSystem, extent: NavExtent, thread_system: ?*ThreadSystem) NavBuildError!void {
    if (self.scratch_slots.items.len == 0) {
        try self.reserve(self.capacity);
    }
    self.goals.invalidate();
    _ = try self.graph.rebuild(colliders.view(), extent, navUpdateThreads(self, thread_system));
    // Search scratch and group fields follow budgets reserved at the capacity seam, never
    // the level's cell count, so the build sizes nothing for them.
    // Grid versions are part of query keys. A rebuild invalidates pending
    // work and caches instead of trying to remap old requests onto new cells.
    self.clearRuntimeState();
    try publish.openRegistryLevels(self, self.graph.levelCount());
    self.nav_marks.clearRetainingCapacity();
    // A rebuild can change cell/chunk counts and thus the per-item work cost, so the
    // adaptive tuners' learned profiles no longer apply: they relearn against the new
    // topology.
    self.tuners = .{};
}

fn navUpdateThreads(self: *PathfindingSystem, thread_system: ?*ThreadSystem) ?NavUpdateThreads {
    const threads = thread_system orelse return null;
    return .{
        .thread_system = threads,
        .tuners = &self.tuners.nav,
        .controls = self.nav_controls,
    };
}

/// The commit seam's static mark reserve, before the structural commit: room for the
/// old and new span of `change_bound` collider changes (the colliders' pending changes
/// plus one per command). No mark may be recorded between it and
/// `recordStaticColliderChanges`. On error nothing changes.
pub fn reserveStaticColliderMarks(self: *PathfindingSystem, change_bound: usize) error{OutOfMemory}!void {
    try reserveNavMarks(self, 2 * change_bound);
}

/// Records a successful collider sync's changes for the next nav batch: each change's
/// old and new cell spans. O(1) per change; allocation-free after
/// `reserveStaticColliderMarks` covered them.
pub fn recordStaticColliderChanges(self: *PathfindingSystem, changes: []const ColliderChange) void {
    std.debug.assert(self.nav_marks.capacity - self.nav_marks.items.len >= 2 * changes.len);
    appendColliderMarks(self, changes);
}

/// A terrain writer's record reserve, before its world write: room to record
/// `event_bound` events (the writer's `maxEventsPerStep`) into the pending marks and
/// through the `nav_mark` stage's staging and tallies. Geometric and counted. On error
/// nothing changes and the writer must not write.
pub fn reserveTerrainNavRecord(self: *PathfindingSystem, event_bound: usize) error{OutOfMemory}!void {
    var grew = try growNavMarks(self, event_bound);
    if (event_bound > self.nav_mark_staging.capacity) {
        try self.nav_mark_staging.ensureTotalCapacity(self.allocator, event_bound);
        grew = true;
    }
    const tally_bound = maxRangeCount(event_bound, nav_mark_range_alignment_items);
    if (tally_bound > self.nav_mark_tallies.capacity) {
        try self.nav_mark_tallies.ensureTotalCapacity(self.allocator, tally_bound);
        grew = true;
    }
    if (grew) countNavMarkGrowth(self);
}

/// Records the events one terrain writer appended (`world_tile_changed`,
/// `world_obstacle_changed`) as pending marks, right after its world write and even when
/// the writer failed after writing, so a written change reaches nav at the next apply.
/// Allocation-free after `reserveTerrainNavRecord` covering `events.len`, with no mark
/// recorded in between. A non-null `thread_system` lets the `nav_mark` stage thread;
/// main work is O(1) per mark.
pub fn recordTerrainNavEvents(self: *PathfindingSystem, events: []const SimulationEvent, world: *const WorldSystem, thread_system: ?*ThreadSystem) void {
    if (events.len == 0) return;
    markNavEvents(self, events, world, thread_system);
}

// Appends each change's old and new cell spans into reserved mark capacity.
fn appendColliderMarks(self: *PathfindingSystem, changes: []const ColliderChange) void {
    for (changes) |change| {
        inline for (.{ change.old, change.new }) |side| {
            if (side) |placement| appendMergedMark(&self.nav_marks, .{
                .level = placement.level,
                .kind = .static_span,
                .min_x = placement.cells.min_x,
                .min_y = placement.cells.min_y,
                .max_x = placement.cells.max_x,
                .max_y = placement.cells.max_y,
            }, self.graph.geometry.chunk_tiles);
        }
    }
}

// Grows the mark buffer to hold `count` more marks: the mark seam. Geometric, counted.
fn reserveNavMarks(self: *PathfindingSystem, count: usize) !void {
    if (try growNavMarks(self, count)) countNavMarkGrowth(self);
}

// Grows the mark buffer to hold `count` more marks, geometrically; true when it grew.
fn growNavMarks(self: *PathfindingSystem, count: usize) !bool {
    const needed = self.nav_marks.items.len + count;
    if (needed <= self.nav_marks.capacity) return false;
    try self.nav_marks.ensureTotalCapacity(self.allocator, needed);
    return true;
}

fn countNavMarkGrowth(self: *PathfindingSystem) void {
    self.nav_mark_growth.record(1, .info, "nav mark storage grew to {d} marks and {d} staged events", .{ self.nav_marks.capacity, self.nav_mark_staging.capacity });
}

/// Whether the next nav update has work: recorded marks, or (nav built over `world`) a
/// level, a link, or a content revision nav has not applied. O(1).
pub fn hasPendingNavUpdates(self: *const PathfindingSystem, world: *const WorldSystem) bool {
    if (self.nav_marks.items.len != 0) return true;
    if (!self.graph.world_backed) return false;
    return world.levelCount() != self.graph.levelCount() or
        world.levelLinks().len != self.graph.links_applied or
        world.contentRevision() != self.graph.built_world_revision;
}

/// Applies every pending nav change, each step its own transaction: builds the levels
/// the world added, rebuilds the levels whose content revision moved (evicting the
/// results with a path run on each and its group fields), then applies the recorded marks
/// and new links as one batch, evicting only the results and group fields it reaches;
/// pending requests and group tallies survive both, since a solve re-checks its live goal
/// and reach. Invalidates the step's goal table. A committed step stays on a later error;
/// marks and the level, revision, and link gaps stay pending for the next call. The
/// world-wide revision is compared once; levels are walked only when it moved. Each stage
/// threads on `thread_system` under its tuner. Counts one step of
/// the batch staging's release windows (`NavGraph.tickStagingStep`).
pub fn applyBufferedNavUpdates(self: *PathfindingSystem, colliders: *const StaticColliderSystem, world: *const WorldSystem, thread_system: *ThreadSystem) NavApplyError!NavUpdateStats {
    var stats = NavUpdateStats{};
    self.goals.invalidate();
    // The step's tick of the batch staging's release windows, before any batch; the
    // release, if the window closes, after every batch and level build of the step.
    self.graph.tickStagingStep(self.capacity.capacity_shrink_window);
    defer self.graph.finishStagingStep();
    const threads = navUpdateThreads(self, thread_system);
    // A level build's relocated closure blocks land even when a later build or the marks
    // batch fails, before the step's staging release.
    errdefer self.graph.landClosure(threads, &stats);
    // A registry flush that failed is finished first: a level rebuild finds the results to
    // evict through their registered runs, and its retires must not land on a reused owner
    // id whose new runs still wait in the publish windows.
    try publish.recoverRegistry(self, eviction.evictFlushDispatch(self, thread_system));
    const view = colliders.view();
    if (self.graph.world_backed) {
        // Every level build of the step shares one level-sized staging, freed once at the
        // step's end (`finishStagingStep`), after the marks batch. Directory slots for the
        // world's levels open first, so a failed open leaves every level unbuilt.
        try publish.openRegistryLevels(self, world.levelCount());
        while (self.graph.levelCount() < world.levelCount()) {
            try self.graph.buildLevel(view, world, @intCast(self.graph.levelCount()), threads, &stats);
        }
        if (world.contentRevision() != self.graph.built_world_revision) {
            var rebuilt = false;
            for (0..self.graph.levelCount()) |level_index| {
                const level: u16 = @intCast(level_index);
                if (self.graph.level_graphs.items[level].built_revision == world.levelContentRevision(level)) continue;
                self.graph.buildLevel(view, world, level, threads, &stats) catch |err| {
                    // Levels already evicted, and a log a failed flush left behind, flush
                    // before the error returns. A flush failure is that error. The world
                    // revision stays unpublished either way.
                    if (rebuilt or self.completed.core.ownerLog().len != 0) {
                        _ = try eviction.flushRebuildEvictions(self, thread_system);
                    }
                    return err;
                };
                rebuilt = true;
                // The level changed without per-cell changes: no result through it and none
                // of its fields is known good.
                const evict_timer = StageTimer.begin();
                eviction.evictLevel(self, level, &stats);
                stats.addMain(.evict_ns, evict_timer.lap());
            }
            // One flush unlinks every rebuilt level's evictions, including a log left when
            // the level revisions were stored and the flush then failed. The world revision
            // is published only after that flush, so the marks batch's eviction starts flushed.
            if (rebuilt or self.completed.core.ownerLog().len != 0) {
                stats.addStageTime(try eviction.flushRebuildEvictions(self, thread_system));
            }
            self.graph.built_world_revision = world.contentRevision();
        }
    }
    if (try self.graph.prepareMarks(world, view, self.nav_marks.items, threads, &stats)) |prepared| {
        {
            // Every eviction allocation precedes the commit; on error the batch and its
            // marks stay pending.
            errdefer self.graph.abortMarks(prepared);
            try eviction.prepareEviction(self, thread_system, &stats);
        }
        const batch = self.graph.commitMarks(prepared, view, threads, &stats);
        if (batch.changed) {
            // Graph node ids never persist, so cached results stay keyed by cells: evict
            // only those with a cell within one cell of a changed cell, and the fields
            // with a costed cell next to a changed cell.
            try eviction.evictScoped(self, batch, thread_system, &stats);
        }
    }
    // The step's relocated closure blocks leave the batch tail, whatever built them.
    self.graph.landClosure(threads, &stats);
    self.nav_marks.clearRetainingCapacity();
    return stats;
}

/// The post-commit nav reaction: applies every pending nav change (the marks terrain
/// writers and the collider sync recorded, and the world's level, link, and revision
/// gaps) and emits one `nav_region_invalidated` when the graph changed. Runs after
/// `colliders` synced this step's commit. A failed apply keeps the marks and gaps for the
/// next step.
pub fn reactToPostCommitNavEvents(self: *PathfindingSystem, frame: *SimulationFrame, colliders: *const StaticColliderSystem, world: *const WorldSystem, thread_system: *ThreadSystem) (NavApplyError || error{EventCapacityExceeded})!NavUpdateStats {
    // The terrain records' mark time since the last reaction folds into this one's stats.
    var marks = NavUpdateStats{};
    if (comptime runtime_perf_log.enabled) {
        marks.perf.off_main_stage_ns = self.perf.mark_off_main_ns;
        marks.perf.inline_stage_ns = self.perf.mark_inline_ns;
        marks.perf.main.mark_ns = self.perf.mark_main_ns;
        self.perf.mark_off_main_ns = 0;
        self.perf.mark_inline_ns = 0;
        self.perf.mark_main_ns = 0;
    }
    if (!hasPendingNavUpdates(self, world)) {
        // A quiet step still counts toward the batch staging's release windows.
        self.graph.tickStagingStep(self.capacity.capacity_shrink_window);
        self.graph.finishStagingStep();
        return marks;
    }
    try frame.events.ensureCanAppend(1);
    var stats = try applyBufferedNavUpdates(self, colliders, world, thread_system);
    if (comptime runtime_perf_log.enabled) {
        stats.perf.off_main_stage_ns += marks.perf.off_main_stage_ns;
        stats.perf.inline_stage_ns += marks.perf.inline_stage_ns;
        stats.perf.main.mark_ns += marks.perf.main.mark_ns;
    }
    if (stats.incremental_rebuilds == 0 and stats.levels_built == 0) return stats;
    try frame.events.appendRequired(.{
        .stage = .domain_reaction,
        .payload = .{ .nav_region_invalidated = .{ .reason = NavInvalidationReason.static_obstacle_changed } },
    });
    return stats;
}

// `nav_mark`: interprets world events into marks; `reserveTerrainNavRecord` reserved one
// mark, one staging slot per event, and the tallies. Each range (one inline range without
// a thread system or when the tuner keeps the stage inline) writes its events' marks into
// its staging window, merging consecutive tile boxes of one (level, chunk), and the main
// thread appends the windows in range order with the same merge, so the marks are equal
// for any partition. Main work is O(marks after the merge). With `runtime_perf_log.enabled`
// its times add to the pending mark times the next reaction folds in.
fn markNavEvents(self: *PathfindingSystem, events: []const SimulationEvent, world: *const WorldSystem, thread_system: ?*ThreadSystem) void {
    if (comptime runtime_perf_log.enabled) self.perf.last_mark_batch = .{};
    if (events.len == 0) return;
    std.debug.assert(self.nav_marks.capacity - self.nav_marks.items.len >= events.len);
    var section = StageTimer.begin();
    const dispatch = navDispatch(self, thread_system, &self.tuners.nav_mark);
    const shape = StageShape.select(dispatch, events.len, nav_mark_range_alignment_items);
    std.debug.assert(self.nav_mark_staging.capacity >= events.len);
    std.debug.assert(self.nav_mark_tallies.capacity >= shape.range_count);
    self.nav_mark_staging.items.len = events.len;
    self.nav_mark_tallies.items.len = shape.range_count;
    @memset(self.nav_mark_tallies.items, .{});
    var job = NavMarkJob{
        .chunk_tiles = self.graph.geometry.chunk_tiles,
        .world = world,
        .events = events,
        .items_per_range = shape.items_per_range,
        .staging = self.nav_mark_staging.items,
        .tallies = self.nav_mark_tallies.items,
    };
    if (comptime runtime_perf_log.enabled) self.perf.mark_main_ns += section.lap();
    const batch = runShaped(dispatch, shape, events.len, nav_mark_range_alignment_items, &job, navMarkJob);
    section = StageTimer.begin();
    if (comptime runtime_perf_log.enabled) self.perf.last_mark_batch = batch;
    for (self.nav_mark_tallies.items, 0..) |tally, range_index| {
        const window_start = range_index * shape.items_per_range;
        for (self.nav_mark_staging.items[window_start .. window_start + tally.count]) |mark| appendEventMark(self, mark);
    }
    if (comptime runtime_perf_log.enabled) {
        self.perf.mark_main_ns += section.lap();
        if (batch.ran_inline) {
            self.perf.mark_inline_ns += batch.batch_duration_ns;
        } else {
            self.perf.mark_off_main_ns += batch.batch_duration_ns;
        }
    }
}

// Appends one event's mark into reserved capacity, merging a tile box into the previous
// mark when both lie in one chunk.
fn appendEventMark(self: *PathfindingSystem, mark: NavMark) void {
    appendMergedMark(&self.nav_marks, mark, self.graph.geometry.chunk_tiles);
}

/// Whether the post-commit nav reaction may run and emit its event this step: a pending
/// structural command may change nav, or nav has recorded marks, levels, links, or a
/// content revision still to apply. Callers reserve its event slot first.
pub fn navReactionMayEmit(self: *const PathfindingSystem, data: *const DataSystem, frame: *const SimulationFrame, world: *const WorldSystem) bool {
    return structuralCommandsMayInvalidateNavigation(data, frame) or hasPendingNavUpdates(self, world);
}

// Whether a committed world event changes nav cells. Static colliders reach nav through
// the collider sync's change list, not events.
fn eventInvalidatesNavigation(event: SimulationEvent) bool {
    switch (event.payload) {
        .world_tile_changed => |changed| return changed.old_blocks_movement != changed.new_blocks_movement,
        .world_obstacle_changed => return true,
        else => return false,
    }
}

// Whether any pending structural command may invalidate navigation once applied.
fn structuralCommandsMayInvalidateNavigation(data: *const DataSystem, frame: *const SimulationFrame) bool {
    for (frame.structural_commands.mergedItems()) |command| {
        if (structuralCommandMayInvalidateNavigation(data, command)) return true;
    }
    return false;
}

fn structuralCommandMayInvalidateNavigation(data: *const DataSystem, command: StructuralCommand) bool {
    return switch (command) {
        .create_entity => |template| templateCreatesStaticNavigationObstacle(template),
        .destroy_entity => |entity| data.isStaticNavigationObstacle(entity),
        .set_movement_body => |set| data.isAlive(set.entity),
        .set_collision_bounds => |set| data.isAlive(set.entity),
        .set_collision_response => |set| data.isAlive(set.entity),
        .set_world_level => |set| data.isStaticNavigationObstacle(set.entity),
        else => false,
    };
}

fn templateCreatesStaticNavigationObstacle(template: EntityTemplate) bool {
    const response = template.collision_response orelse return false;
    return response.mobility == .static and
        template.movement_body != null and
        template.collision_bounds != null;
}

fn tileMark(level: u16, min_x: u32, min_y: u32, max_x: u32, max_y: u32) NavMark {
    return .{ .level = level, .kind = .tile_box, .min_x = min_x, .min_y = min_y, .max_x = max_x, .max_y = max_y };
}

// An exclusive world-tile rect clamped to the world as an inclusive tile box; null when
// empty or fully outside.
fn tileRectMark(world: *const WorldSystem, level: u16, min_x: u16, min_y: u16, max_x_exclusive: u16, max_y_exclusive: u16) ?NavMark {
    const clamped_max_x = @min(max_x_exclusive, world.width);
    const clamped_max_y = @min(max_y_exclusive, world.height);
    if (min_x >= clamped_max_x or min_y >= clamped_max_y) return null;
    return tileMark(level, min_x, min_y, clamped_max_x - 1, clamped_max_y - 1);
}

// Whether two tile boxes lie in one `chunk_tiles` chunk of one level, so their bounding
// box covers exactly that chunk.
fn tileBoxesShareChunk(a: NavMark, b: NavMark, chunk_tiles: u16) bool {
    if (a.kind != .tile_box or b.kind != .tile_box or a.level != b.level) return false;
    const ct: u32 = @max(chunk_tiles, 1);
    const chunk_x = a.min_x / ct;
    const chunk_y = a.min_y / ct;
    return a.max_x / ct == chunk_x and a.max_y / ct == chunk_y and
        b.min_x / ct == chunk_x and b.max_x / ct == chunk_x and
        b.min_y / ct == chunk_y and b.max_y / ct == chunk_y;
}

// Writes `mark` after the first `count` marks of `marks`, merged into the last one when
// both are tile boxes in one chunk; returns the new count. Merging only with the last mark
// makes the result independent of how a mark sequence is split and rejoined.
fn foldMark(marks: []NavMark, count: usize, mark: NavMark, chunk_tiles: u16) usize {
    if (count != 0) {
        const last = &marks[count - 1];
        if (tileBoxesShareChunk(last.*, mark, chunk_tiles)) {
            last.min_x = @min(last.min_x, mark.min_x);
            last.min_y = @min(last.min_y, mark.min_y);
            last.max_x = @max(last.max_x, mark.max_x);
            last.max_y = @max(last.max_y, mark.max_y);
            return count;
        }
    }
    std.debug.assert(count < marks.len);
    marks[count] = mark;
    return count + 1;
}

// `foldMark` onto a list with reserved capacity.
fn appendMergedMark(list: *std.ArrayList(NavMark), mark: NavMark, chunk_tiles: u16) void {
    std.debug.assert(list.items.len < list.capacity);
    const count = foldMark(list.items.ptr[0..list.capacity], list.items.len, mark, chunk_tiles);
    list.items.len = count;
}

// One committed event's nav mark: a blocking tile flip becomes its tile, an obstacle rect
// its clamped tile box. Reads only the world, so ranges interpret in parallel.
fn interpretNavEvent(world: *const WorldSystem, event: SimulationEvent) ?NavMark {
    if (event.stage != .structural_commit) return null;
    if (!eventInvalidatesNavigation(event)) return null;
    return switch (event.payload) {
        .world_tile_changed => |changed| tileMark(changed.level, changed.x, changed.y, changed.x, changed.y),
        .world_obstacle_changed => |changed| tileRectMark(world, changed.level, changed.min_x, changed.min_y, changed.max_x_exclusive, changed.max_y_exclusive),
        else => null,
    };
}

// `nav_mark` takes only what a terrain writer appends.
fn assertTerrainNavEvent(event: SimulationEvent) void {
    std.debug.assert(event.payload == .world_tile_changed or event.payload == .world_obstacle_changed);
}

// One range of the `nav_mark` stage: its events' marks, folded, in its staging window.
const NavMarkJob = struct {
    chunk_tiles: u16,
    world: *const WorldSystem,
    events: []const SimulationEvent,
    items_per_range: usize,
    staging: []NavMark,
    tallies: []NavMarkTally,
};

fn navMarkJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *NavMarkJob = @ptrCast(@alignCast(context));
    // Dual worker asserts: range.index vs the dispatched tallies, and the window the merge
    // reads, inside the staging buffer.
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.events.len);
    std.debug.assert(range.end <= job.staging.len);
    const window = job.staging[range.start..range.end];
    var count: usize = 0;
    for (job.events[range.start..range.end]) |event| {
        assertTerrainNavEvent(event);
        if (interpretNavEvent(job.world, event)) |mark| count = foldMark(window, count, mark, job.chunk_tiles);
    }
    job.tallies[range.index] = .{ .count = count };
}

// ----------------------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------------------

const math = @import("../../../core/math.zig");
const BatchStats = @import("../../../app/thread_system.zig").BatchStats;
const EntityId = @import("../../data_system.zig").EntityId;
const PathRequest = @import("../../simulation.zig").PathRequest;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const PathStatus = @import("types.zig").PathStatus;
const test_support = @import("test_support.zig");
const updatePathfindingInline = @import("test_support.zig").updatePathfindingInline;
const addNavBody = @import("test_support.zig").addNavBody;
const appendPathRequest = @import("test_support.zig").appendPathRequest;
const baselineCapacity = @import("test_support.zig").baselineCapacity;
const abstractCapacity = @import("test_support.zig").abstractCapacity;
const loadTestWorldMeta = @import("test_support.zig").loadTestWorldMeta;
const requireTestTile = @import("test_support.zig").requireTestTile;
const tileCenter = @import("test_support.zig").tileCenter;
const buildCorridorWorld = @import("test_support.zig").buildCorridorWorld;
const solveStep = @import("test_support.zig").solveStep;
const statusOf = test_support.statusOf;
const cachedStep = test_support.cachedStep;
const solvedLastStep = test_support.solvedLastStep;
const navMarkTestEvents = @import("test_support.zig").navMarkTestEvents;
const no_colliders = &test_support.no_colliders;

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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    _ = try solveStep(&system, requester, start, goal);
    try std.testing.expect(solvedLastStep(&system, goal));
    const view_before = system.statusForWorld(0, start, 0, goal, .default, null);
    try std.testing.expectEqual(PathStatus.available, view_before.status);

    // The cached path must cross the wall through exactly one of the two gaps: which one
    // the abstract search prefers is a cost-estimate detail (consolidated boundary portals
    // change the abstract graph's cost landscape without changing which corridors exist),
    // not the invariant under test — the invariant is that blocking whichever gap was used
    // forces a reroute through the other.
    const used_near = cachedPathTouchesCell(&system, start, goal, 5, 3);
    const used_far = cachedPathTouchesCell(&system, start, goal, 5, 9);
    try std.testing.expect(used_near != used_far);
    const used_row: u16 = if (used_near) 3 else 9;
    const other_row: u16 = if (used_near) 9 else 3;

    const version_before = system.graph.version;

    // Flip the gap the path actually used to a tree (now blocking) via the world tile API.
    const changed = (try world.setDenseTile(built.wall_layer, 5, used_row, tree)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement != changed.new_blocks_movement);
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);

    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
    // A pure incremental dig keeps nav_version stable; invalidation is scoped.
    try std.testing.expect(system.graph.version == version_before);
    // The cached path crossed the now-blocked gap, so it was evicted: missing.
    try std.testing.expectEqual(PathStatus.missing, system.statusForWorld(0, start, 0, goal, .default, null).status);

    // Next solve produces a DIFFERENT path that avoids the now-blocked gap and routes
    // through the other one.
    _ = try solveStep(&system, requester, start, goal);
    try std.testing.expect(solvedLastStep(&system, goal));
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, start, 0, goal, .default, null).status);
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 5, used_row));
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, other_row));
}

// Returns whether the cached completed (or stitched) path for the goal includes the
// nav cell at tile (cx, cy). Walks the stored cells directly; used to assert a route
// crosses a specific corridor gap.
fn cachedPathTouchesCell(system: *const PathfindingSystem, start: math.Vec2, goal: math.Vec2, cx: u16, cy: u16) bool {
    const key = system.graph.keyForWorld(0, goal, .default) orelse return false;
    _ = start;
    const slot = system.completed.slotIndex(key) orelse return false;
    const result = system.completed.resultAt(slot);
    const grid = system.graph.grid(0) orelse return false;
    const target = grid.indexForCell(.{ .x = @intCast(cx), .y = @intCast(cy) }) orelse return false;
    if (result.stitched_len != 0) {
        const stitched = system.completed.stitchedSlice(slot, result.stitched_len);
        for (stitched.cells, stitched.levels) |cell, level| {
            if (level == 0 and cell == target) return true;
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    _ = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(PathStatus.available, statusOf(&system, start, goal));

    const changed = (try world.setDenseTile(built.wall_layer, 5, 3, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

    // The cached path crossed the now-closed gap (5,3), so it was evicted, and reach answers
    // the re-request unavailable, not a stale cached available, with no solve.
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, start, 0, goal, .default, null).status);
    _ = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(PathStatus.unavailable, statusOf(&system, start, goal));
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expect(system.completed.slotIndex(system.graph.keyForWorld(0, goal, .default).?) == null);
}

test "pathfinding incremental update retains a still-valid cached path when an off-path tile is unblocked" {
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    _ = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(PathStatus.available, statusOf(&system, start, goal));
    // Path crosses only at row 9 (the near gap is closed).
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 9));
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 5, 3));

    // Unblock the near gap (5,3): a cell the cached path (via row 9) does not cross, so
    // it is retained. Opening a shortcut does not re-route existing agents.
    const changed = (try world.setDenseTile(built.wall_layer, 5, 3, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

    // The path survived: still available and still routing through the far gap (row 9).
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, start, 0, goal, .default, null).status);
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 9));
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 5, 3));
}

test "pathfinding incremental update blocking an off-path cell keeps the cached path as a cache hit" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");

    const built = try buildCorridorWorld(&meta, &.{3});
    var world = built.world;
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const requester = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 4, .y = 4 }, false);

    const start = tileCenter(1, 5);
    const goal = tileCenter(9, 5);
    _ = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(PathStatus.available, statusOf(&system, start, goal));
    // The cached route crosses the row-3 gap and never visits the far corner (9,11).
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 3));
    try std.testing.expect(!cachedPathTouchesCell(&system, start, goal, 9, 11));

    // Block an off-path cell far from the route: the cached path is left intact (an edit
    // elsewhere does not invalidate unrelated cached paths).
    const changed = (try world.setDenseTile(built.wall_layer, 9, 11, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

    // The same goal is served from the surviving cache (a hit): nothing re-solved.
    const key = system.graph.keyForWorld(0, goal, .default).?;
    const stored_step = cachedStep(&system, key).?;
    _ = try solveStep(&system, requester, start, goal);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);
    try std.testing.expectEqual(stored_step, cachedStep(&system, key).?);
    try std.testing.expectEqual(PathStatus.available, statusOf(&system, start, goal));
    try std.testing.expect(cachedPathTouchesCell(&system, start, goal, 5, 3));
}

test "pathfinding incremental update leaves an unaffected second level untouched" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    const level1_layer = try world.addDenseLayer(1, 0, .floor, grass);
    // A distinctive obstacle on level 1 cell (7,7) so we can confirm level 1 is
    // unchanged by an edit on level 0.
    _ = try world.setDenseTile(level1_layer, 7, 7, tree);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Snapshot level 1's blocked count and component label of its obstacle cell.
    const level1_blocked_before = system.graph.grid(1).?.blocked_count;
    const level1_cell77 = system.graph.grid(1).?.indexForCell(.{ .x = 7, .y = 7 }).?;
    try std.testing.expect(system.graph.grid(1).?.isBlockedIndex(level1_cell77));

    // Edit a tile on LEVEL 0 only.
    const obstacle_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    const changed = (try world.setDenseTile(obstacle_layer, 2, 2, tree)) orelse return error.TestExpectedEqual;
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);

    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);
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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const version_before = system.graph.version;

    // An empty edit batch is a no-op: no version bump, no counters.
    const stats = try test_support.applyTileEdits(&system, no_colliders, &world, &.{});
    try std.testing.expectEqual(@as(usize, 0), stats.incremental_rebuilds);
    try std.testing.expectEqual(version_before, system.graph.version);
}

test "pathfinding buffered nav updates grow without dropping and clear after apply" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    // 512 extent at cell_size 32 is 16 nav cells/side; with 4-tile chunks that is a 4x4 chunk
    // grid, so the far block below lands in the opposite-corner chunk from the near block.
    const extent: f32 = 512;
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    // Mark far more dirty cells than the steady-path reserve (max_frame_requests = 8): a 24-cell
    // near block, then a 3-cell far block in the opposite-corner chunk LAST. A drop-on-cap would
    // lose the far block and its chunk would never remask; the grow-don't-drop buffer must carry
    // every cell so the far chunk still ends blocked.
    var marked: usize = 0;
    var ny: u16 = 0;
    while (ny < 6) : (ny += 1) {
        var nx: u16 = 0;
        while (nx < 4) : (nx += 1) {
            _ = (try world.setDenseTile(obstacle, nx, ny, tree)) orelse return error.TestExpectedEqual;
            try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = nx, .y = ny }});
            marked += 1;
        }
    }
    var fx: u16 = 13;
    while (fx < 16) : (fx += 1) {
        _ = (try world.setDenseTile(obstacle, fx, 13, tree)) orelse return error.TestExpectedEqual;
        try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = fx, .y = 13 }});
        marked += 1;
    }
    try std.testing.expect(marked > system.limits.frame_requests);
    try std.testing.expect(system.hasPendingNavUpdates(&world));

    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // The far block — marked last, the first a fixed cap would drop — reached the graph.
    const nav = system.graph.grid(0).?;
    fx = 13;
    while (fx < 16) : (fx += 1) try std.testing.expect(nav.isBlockedCell(.{ .x = @intCast(fx), .y = 13 }));
    // applyBuffered clears the buffer, so the next step starts empty.
    try std.testing.expect(!system.hasPendingNavUpdates(&world));
}

test "nav over a world takes the world's chunk edge and tile size; a world-less build takes its config" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    // World chunk 8 and a deliberately different config: nav chunk 16, cell size 8.
    var world = try WorldSystem.initDemoFromMetaWithChunkSize(std.testing.allocator, &meta, 512, 256, 8);
    defer world.deinit();
    var capacity = baselineCapacity();
    capacity.nav_chunk_tiles = 16;

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    try std.testing.expectEqual(world.chunk_size_tiles, system.graph.geometry.chunk_tiles);
    try std.testing.expectEqual(world.tile_size, system.graph.cell_size);
    try std.testing.expectEqual(@as(usize, world.width), system.graph.geometry.width);
    try std.testing.expectEqual(@as(usize, world.height), system.graph.geometry.height);
    const level_grid = system.graph.grid(0).?;
    try std.testing.expectEqual(world.chunk_size_tiles, level_grid.geometry.chunk_tiles);
    try std.testing.expectEqual(world.chunkGeometry().chunks_x, level_grid.geometry.chunks_x);
    try std.testing.expectEqual(world.chunkGeometry().chunks_y, level_grid.geometry.chunks_y);
    // Every tile's nav chunk is its world chunk.
    for (0..world.height) |y| {
        for (0..world.width) |x| {
            const tile_chunk = world.chunkCoordForCell(@intCast(x), @intCast(y));
            const expected: u32 = @intCast(tile_chunk.y * @as(i32, @intCast(world.chunkGeometry().chunks_x)) + tile_chunk.x);
            try std.testing.expectEqual(expected, level_grid.geometry.chunkOfCell(y * level_grid.geometry.width + x));
        }
    }

    try system.rebuildStaticNavGrid(&data, 512, 256, 8);
    try std.testing.expectEqual(capacity.nav_chunk_tiles, system.graph.geometry.chunk_tiles);
    try std.testing.expectEqual(@as(f32, 8), system.graph.cell_size);
}

test "nav build fails loudly when its chunk edge or index widths do not fit" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    var bad_edge = baselineCapacity();
    bad_edge.nav_chunk_tiles = 3;
    var bad_edge_system = PathfindingSystem.init(std.testing.allocator);
    defer bad_edge_system.deinit();
    try bad_edge_system.reserve(bad_edge);
    try std.testing.expectError(error.InvalidChunkSize, bad_edge_system.rebuildStaticNavGrid(&data, 256, 256, 32));

    // Chunk edge 1 gives 2 labels per chunk: 65535 x 32769 cells crosses the label sentinel.
    var unit_edge = baselineCapacity();
    unit_edge.nav_chunk_tiles = 1;
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(unit_edge);
    try std.testing.expectError(error.ChunkLabelOverflow, system.rebuildStaticNavGrid(&data, 65535, 32769, 1));
    try std.testing.expectError(error.LevelCellIndexOverflow, system.rebuildStaticNavGrid(&data, 1.0e6, 1.0e6, 1));
    // A side past 2^32 cells, a side past usize, and a subnormal cell size's inf quotient each
    // reach the validator rather than trapping in the float conversion.
    try std.testing.expectError(error.LevelCellIndexOverflow, system.rebuildStaticNavGrid(&data, 0x1p33, 1, 1));
    try std.testing.expectError(error.LevelCellIndexOverflow, system.rebuildStaticNavGrid(&data, 1.0e30, 1.0e30, 1));
    try std.testing.expectError(error.LevelCellIndexOverflow, system.rebuildStaticNavGrid(&data, 1, 1, std.math.floatTrueMin(f32)));
    const huge_extent = system.boundsNavExtent(1.0e30, 1, 1);
    try std.testing.expectError(error.LevelCellIndexOverflow, system.graph.rebuild(.{}, huge_extent, null));
}

test "a nav update reports its marks batch's remask, and an update without marks reports none" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 128, 128);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    const changed = (try world.setDenseTile(obstacle, 2, 2, tree)) orelse return error.TestExpectedEqual;
    const stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expect(stats.remask_batch.item_count > 0);
    try std.testing.expectEqual(stats.dirty_chunks, stats.remask_batch.item_count);

    // The graph keeps its last remask; an update with no batch must not report it again.
    const idle = try test_support.applyTileEdits(&system, no_colliders, &world, &.{});
    try std.testing.expectEqual(@as(usize, 0), idle.incremental_rebuilds);
    try std.testing.expectEqual(BatchStats{}, idle.remask_batch);

    // A batch whose only mark misses every built level commits without changing the graph.
    const unbuilt = try test_support.applyTileEdits(&system, no_colliders, &world, &.{.{ .level = 99, .x = 2, .y = 2 }});
    try std.testing.expectEqual(@as(usize, 0), unbuilt.incremental_rebuilds);
    try std.testing.expectEqual(BatchStats{}, unbuilt.remask_batch);
}

test "reactToPostCommitNavEvents preserves buffered marks across a failed apply instead of dropping them" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 128, 128);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();

    // A real committed tile edit that blocks movement.
    const changed = (try world.setDenseTile(obstacle, 2, 2, tree)) orelse return error.TestExpectedEqual;
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
    try test_support.recordTerrainEvents(&system, frame.events.mergedItems(), &world);
    // Cap the events stream at its current size so this call's own ensureCanAppend(1) (for the
    // nav_region_invalidated event it would emit) fails deterministically, WITHOUT ever reaching
    // applyBufferedNavUpdates.
    frame.events.setCapacityLimit(frame.events.mergedItems().len);

    try std.testing.expectError(error.EventCapacityExceeded, system.reactToPostCommitNavEvents(&frame, no_colliders, &world, &serial_threads));
    // The mark from this failed call must survive: no entry-clear on the next call may drop a
    // pending edit the world already committed but the nav graph has not yet learned about.
    try std.testing.expect(system.hasPendingNavUpdates(&world));
    try std.testing.expect(!system.graph.grid(0).?.isBlockedCell(.{ .x = 2, .y = 2 }));

    // Next step: no new committed events, room to append again. The leftover mark from the
    // failed step must still reach the graph.
    frame.events.setCapacityLimit(null);
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expect(!system.hasPendingNavUpdates(&world));
    try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = 2, .y = 2 }));
}

test "reactToPostCommitNavEvents maps world_obstacle_changed to one mark (not O(tiles) marks)" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    // A multi-tile world_obstacle_changed must record one tile-box mark, not one mark per
    // tile. Multi-chunk fixture
    // (nav_chunk_tiles=4) so the dirty rect spans ≥2 abstract chunks and a control
    // cell in an untouched chunk stays open.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // 256 world units / 32 cell size = 8 nav cells; with nav_chunk_tiles=4 that is a
    // 2×2 chunk grid so a rect crossing x=4 spans two chunks on the same row.
    const extent: f32 = 256;
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const grid = system.graph.grid(0).?;
    try std.testing.expect(grid.geometry.width >= 8);
    try std.testing.expectEqual(@as(u16, 4), system.capacity.nav_chunk_tiles);

    // Paint a rect that crosses the chunk boundary at x=4 (tiles 2..5 inclusive).
    const min_x: u16 = 2;
    const min_y: u16 = 1;
    const max_x_exclusive: u16 = 6;
    const max_y_exclusive: u16 = 3;
    // Control tile in the bottom-right chunk — never part of the dirty rect.
    const control_x: u16 = 6;
    const control_y: u16 = 6;
    var y: u16 = min_y;
    while (y < max_y_exclusive) : (y += 1) {
        var x: u16 = min_x;
        while (x < max_x_exclusive) : (x += 1) {
            _ = (try world.setDenseTile(obstacle, x, y, tree)) orelse return error.TestExpectedEqual;
        }
    }

    // Expected span = union of per-tile world-rect spans (must match the O(1) mark).
    var expected_span = grid.cellSpanForWorldRect(0, 0, 0, 0);
    var first_tile = true;
    y = min_y;
    while (y < max_y_exclusive) : (y += 1) {
        var x: u16 = min_x;
        while (x < max_x_exclusive) : (x += 1) {
            const rect = world.cellRect(x, y).?;
            const tile_span = grid.cellSpanForWorldRect(rect.x, rect.y, rect.x + rect.w, rect.y + rect.h);
            if (first_tile) {
                expected_span = tile_span;
                first_tile = false;
            } else {
                expected_span.min_x = @min(expected_span.min_x, tile_span.min_x);
                expected_span.min_y = @min(expected_span.min_y, tile_span.min_y);
                expected_span.max_x = @max(expected_span.max_x, tile_span.max_x);
                expected_span.max_y = @max(expected_span.max_y, tile_span.max_y);
            }
        }
    }
    // The union itself must cross a nav-chunk boundary (otherwise the multi-chunk claim is vacuous).
    const ct: usize = system.capacity.nav_chunk_tiles;
    try std.testing.expect(expected_span.min_x / ct != expected_span.max_x / ct);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{
        .level = 0,
        .min_x = min_x,
        .min_y = min_y,
        .max_x_exclusive = max_x_exclusive,
        .max_y_exclusive = max_y_exclusive,
    } } });
    try test_support.recordTerrainEvents(&system, frame.events.mergedItems(), &world);

    // Record only (don't apply): inspect the recorded marks by
    // forcing ensureCanAppend to fail before applyBufferedNavUpdates, same pattern
    // as the preserve-buffered-marks test above.
    frame.events.setCapacityLimit(frame.events.mergedItems().len);
    try std.testing.expectError(error.EventCapacityExceeded, system.reactToPostCommitNavEvents(&frame, no_colliders, &world, &serial_threads));

    // One mark covering the rect: O(1) per event, not O(tiles).
    try std.testing.expectEqual(@as(usize, 1), system.nav_marks.items.len);
    const mark = system.nav_marks.items[0];
    try std.testing.expectEqual(@as(u16, 0), mark.level);
    try std.testing.expectEqual(expected_span, grid.cellSpanForTileBox(&world, mark.min_x, mark.min_y, mark.max_x, mark.max_y).?);

    // Apply the leftover mark: dirty tiles block; control cell in the untouched chunk stays open.
    frame.events.setCapacityLimit(null);
    frame.beginStep();
    const stats = try system.reactToPostCommitNavEvents(&frame, no_colliders, &world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    y = min_y;
    while (y < max_y_exclusive) : (y += 1) {
        var x: u16 = min_x;
        while (x < max_x_exclusive) : (x += 1) {
            const rect = world.cellRect(x, y).?;
            const cell = grid.worldToCellClamped(.{
                .x = rect.x + rect.w * 0.5,
                .y = rect.y + rect.h * 0.5,
            });
            try std.testing.expect(grid.isBlockedCell(cell));
        }
    }
    {
        const control_rect = world.cellRect(control_x, control_y).?;
        const control_cell = grid.worldToCellClamped(.{
            .x = control_rect.x + control_rect.w * 0.5,
            .y = control_rect.y + control_rect.h * 0.5,
        });
        try std.testing.expect(!grid.isBlockedCell(control_cell));
    }
}

test "a recorded obstacle-rect event past the world edge marks its in-world part" {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    // A rect whose max corner is past the world edge still dirties the in-bounds
    // portion (perception-style clamp), rather than all-or-nothing no-op on cellRect miss.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // 128 / tile_size ≈ 4 tiles on a side — small enough that max=100 is clearly OOB.
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 128, 128);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const grid = system.graph.grid(0).?;

    // Paint the last two columns so the clamped in-bounds slice actually flips blocked.
    const in_min_x: u16 = world.width - 2;
    const in_min_y: u16 = 0;
    var y: u16 = 0;
    while (y < world.height) : (y += 1) {
        var x: u16 = in_min_x;
        while (x < world.width) : (x += 1) {
            _ = (try world.setDenseTile(obstacle, x, y, tree)) orelse return error.TestExpectedEqual;
        }
    }

    // min in-bounds, max far past the edge.
    try test_support.recordTerrainEvents(&system, &.{obstacleRectEvent(0, in_min_x, in_min_y, 1000, 1000)}, &world);
    try std.testing.expectEqual(@as(usize, 1), system.nav_marks.items.len);

    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, &serial_threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);

    // Every in-bounds tile of the painted strip is blocked after the clamped dirty apply.
    y = 0;
    while (y < world.height) : (y += 1) {
        var x: u16 = in_min_x;
        while (x < world.width) : (x += 1) {
            const rect = world.cellRect(x, y).?;
            const cell = grid.worldToCellClamped(.{
                .x = rect.x + rect.w * 0.5,
                .y = rect.y + rect.h * 0.5,
            });
            try std.testing.expect(grid.isBlockedCell(cell));
        }
    }

    // Fully OOB / empty after clamp still no-ops.
    try test_support.recordTerrainEvents(&system, &.{obstacleRectEvent(0, world.width, world.height, 1000, 1000)}, &world);
    try std.testing.expectEqual(@as(usize, 0), system.nav_marks.items.len);
}

fn obstacleRectEvent(level: u16, min_x: u16, min_y: u16, max_x_exclusive: u16, max_y_exclusive: u16) SimulationEvent {
    return .{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{
        .level = level,
        .min_x = min_x,
        .min_y = min_y,
        .max_x_exclusive = max_x_exclusive,
        .max_y_exclusive = max_y_exclusive,
    } } };
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    const high_water = test_support.totalPortals(&system.graph);
    try std.testing.expect(high_water > 0);

    // Warmup: the same block and reopen, so every batch buffer and record pool reaches
    // its steady capacity.
    for ([_]@TypeOf(tree){ tree, grass }) |tile| {
        const warm = (try world.setDenseTile(built.wall_layer, 5, 3, tile)) orelse return error.TestExpectedEqual;
        _ = try test_support.applyTileChange(&system, no_colliders, &world, warm);
    }

    // The failing allocator must cover BOTH the system AND the nav graph (which holds
    // its own captured allocator copy): every batch buffer and record pool flows through
    // graph.allocator, so swapping only system.allocator would let a graph allocation slip
    // through undetected.
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;

    // Block an existing open gap: removes portals, stays within high-water.
    const blocked = (try world.setDenseTile(built.wall_layer, 5, 3, tree)) orelse return error.TestExpectedEqual;
    const block_stats = try test_support.applyTileChange(&system, no_colliders, &world, blocked);
    try std.testing.expectEqual(@as(usize, 1), block_stats.incremental_rebuilds);

    // Reopen the same gap: re-adds portals back to <= the init high-water count, so it
    // reuses retained capacity and allocates nothing.
    const opened = (try world.setDenseTile(built.wall_layer, 5, 3, grass)) orelse return error.TestExpectedEqual;
    const open_stats = try test_support.applyTileChange(&system, no_colliders, &world, opened);
    try std.testing.expectEqual(@as(usize, 1), open_stats.incremental_rebuilds);
    try std.testing.expect(test_support.totalPortals(&system.graph) <= high_water);

    system.graph.allocator = original;
    system.allocator = original;
}

test "pathfinding threaded incremental nav update is allocation-free at steady state" {
    // The serial allocation-free tests above only cover the inline stages. Only
    // applyBufferedNavUpdates/reactToPostCommitNavEvents with a real ThreadSystem drive the
    // plan, remask, and patch jobs, the remask indexing a per-participant scratch slot. Five
    // edits in five distinct chunks, adaptive=false/items_per_range=1 to force every stage
    // off the inline path, under a failing allocator on both system.allocator and
    // system.graph.allocator.

    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const grass = try requireTestTile(&meta, "grass");
    const tree = try requireTestTile(&meta, "tree_0");

    const extent: f32 = 512;
    var world = try test_support.abstractTestWorld(&meta, extent, extent);
    defer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var cap = abstractCapacity();
    cap.worker_participant_count = threads.participantSlotCount();
    try system.reserve(cap);
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    // Force the parallel schedule rather than letting the tuner keep the small batch inline.
    system.nav_controls = .{ .adaptive = false, .items_per_range = 1 };

    // Five cells in five distinct nav_chunk_tiles=4 chunks, so both the remask changed-chunk
    // set and the patch set exceed one chunk and actually fan out across workers.
    const cells = [_]struct { x: u16, y: u16 }{
        .{ .x = 1, .y = 1 },  .{ .x = 13, .y = 1 },
        .{ .x = 1, .y = 13 }, .{ .x = 13, .y = 13 },
        .{ .x = 7, .y = 7 },
    };
    // Warmup: block and reopen the cells through the threaded path.
    for ([_]@TypeOf(tree){ tree, grass }) |tile| {
        for (cells) |cell| {
            _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tile)) orelse return error.TestExpectedEqual;
            try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = cell.x, .y = cell.y }});
        }
        _ = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);
    }

    // The failing allocator must cover BOTH the system AND the nav graph (which holds its own
    // captured allocator copy): every per-participant remask scratch slot, plus every batch
    // buffer and record pool, flows through graph.allocator.
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    for (cells) |cell| {
        _ = (try world.setDenseTile(obstacle, cell.x, cell.y, tree)) orelse return error.TestExpectedEqual;
        try test_support.recordTileEdits(&system, &world, &.{.{ .level = 0, .x = cell.x, .y = cell.y }});
    }
    const stats = try system.applyBufferedNavUpdates(no_colliders, &world, &threads);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);

    // Every stage must have actually threaded, not fallen back to the inline slot-0 path —
    // otherwise this would silently retest the already-covered serial path. A plan over
    // several ranges merges through the plan order set into its reserved key lists.
    try std.testing.expect(!stats.remask_batch.ran_inline);
    try std.testing.expect(system.graph.plan_tallies.items.len > 1);

    for (cells) |cell| {
        try std.testing.expect(system.graph.grid(0).?.isBlockedCell(.{ .x = cell.x, .y = cell.y }));
    }

    system.graph.allocator = original;
    system.allocator = original;
}

test "a fully walled level opened past its prior records grows at the reserve and the next apply allocates nothing" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    const tree = try requireTestTile(&meta, "tree_0");
    const grass = try requireTestTile(&meta, "grass");

    // Start fully walled so the init build holds no record. Opening a block grows the
    // record pools at the batch reserve with the real allocator.
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    try std.testing.expectEqual(@as(usize, 0), test_support.totalPortals(&system.graph));

    // Open a 6x6 block spanning chunk borders, creating records past the (zero) init pool.
    var edits = std.ArrayList(test_support.TileEdit).empty;
    defer edits.deinit(std.testing.allocator);
    y = 2;
    while (y < 8) : (y += 1) {
        var x: u16 = 2;
        while (x < 8) : (x += 1) {
            const opened = (try world.setDenseTile(wall_layer, x, y, grass)) orelse continue;
            try edits.append(std.testing.allocator, .{ .level = opened.level, .x = opened.x, .y = opened.y });
        }
    }
    const stats = try test_support.applyTileEdits(&system, no_colliders, &world, edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    // The opened block holds portals.
    try std.testing.expect(test_support.totalPortals(&system.graph) > 0);

    // A subsequent edit within the NEW high-water mark (a cell of a chunk already mixed, so
    // no new block) is allocation-free again.
    const closed = (try world.setDenseTile(wall_layer, 3, 3, tree)) orelse return error.TestExpectedEqual;
    const original = system.allocator;
    system.allocator = std.testing.failing_allocator;
    system.graph.allocator = std.testing.failing_allocator;
    const close_stats = try test_support.applyTileChange(&system, no_colliders, &world, closed);
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

    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(0);
    const level1_floor = try world.addDenseLayer(1, 0, .floor, grass);
    // Obstacle layer on level 1 so the link endpoint cell (2,2) can be flipped via the
    // dense tile API (which emits a WorldTileChangedEvent that drives the nav update).
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
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
    _ = try updatePathfindingInline(&system, &blocked_stream, 8, .{});
    try std.testing.expectEqual(PathStatus.unavailable, system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, .{ .x = 304, .y = 304 }, .default, null).status);
    try std.testing.expectEqual(@as(usize, 0), system.pending.len);

    // Open the endpoint cell (2,2) on level 1 via the world tile API + incremental update:
    // the endpoint's record gains the link, so the same cross-level goal is now reachable.
    const changed = (try world.setDenseTile(level1_obstacle, 2, 2, grass)) orelse return error.TestExpectedEqual;
    try std.testing.expect(changed.old_blocks_movement and !changed.new_blocks_movement);
    const nav_stats = try test_support.applyTileChange(&system, no_colliders, &world, changed);
    // Incremental edit keeps nav_version stable; the prior unavailable entry is dropped,
    // so the same cross-level goal re-solves as live.
    try std.testing.expectEqual(@as(usize, 1), nav_stats.incremental_rebuilds);

    var open_stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer open_stream.deinit();
    try appendPathRequest(&open_stream, .{
        .entity = requester,
        .start_level = 0,
        .goal_level = 1,
        .start = .{ .x = 16, .y = 16 },
        .goal = .{ .x = 304, .y = 304 },
    });
    _ = try updatePathfindingInline(&system, &open_stream, 8, .{});
    try std.testing.expectEqual(PathStatus.available, system.statusForWorld(0, .{ .x = 16, .y = 16 }, 1, .{ .x = 304, .y = 304 }, .default, null).status);
}

test "a static mark record after its reserve allocates nothing (FailingAllocator)" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    // A move, a create, and a destroy: four spans.
    const changes = [_]ColliderChange{
        .{ .entity = try EntityId.init(1, 1), .old = .{ .level = 0, .cells = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }, .aabb = .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 } }, .new = .{ .level = 0, .cells = .{ .min_x = 4, .min_y = 0, .max_x = 5, .max_y = 1 } } },
        .{ .entity = try EntityId.init(2, 1), .old = null, .new = .{ .level = 1, .cells = .{ .min_x = 2, .min_y = 2, .max_x = 2, .max_y = 2 } } },
        .{ .entity = try EntityId.init(3, 1), .old = .{ .level = 2, .cells = .{ .min_x = 7, .min_y = 7, .max_x = 9, .max_y = 8 }, .aabb = .{ .min_x = 0, .min_y = 0, .max_x = 0, .max_y = 0 } }, .new = null },
    };
    try system.reserveStaticColliderMarks(changes.len);
    system.allocator = std.testing.failing_allocator;
    defer system.allocator = std.testing.allocator;
    system.recordStaticColliderChanges(&changes);
    try std.testing.expectEqual(@as(usize, 4), system.nav_marks.items.len);
    for (system.nav_marks.items) |mark| try std.testing.expectEqual(types.NavMarkKind.static_span, mark.kind);
    try std.testing.expectEqual(@as(u32, 4), system.nav_marks.items[1].min_x);
    try std.testing.expectEqual(@as(u16, 2), system.nav_marks.items[3].level);
}

test "a terrain nav record reserve grows the marks, staging, or tallies only past a covered reserve, and logs the first growth" {
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(baselineCapacity());
    // The capacity seam reserves the steady high-water unlogged; a record within it grows
    // nothing.
    const capacities = .{ system.nav_marks.capacity, system.nav_mark_staging.capacity, system.nav_mark_tallies.capacity };
    try system.reserveTerrainNavRecord(system.limits.frame_requests);
    try std.testing.expectEqual(capacities, .{ system.nav_marks.capacity, system.nav_mark_staging.capacity, system.nav_mark_tallies.capacity });
    try std.testing.expect(!system.nav_mark_growth.logged);

    // Room for the marks, so only the staging and tallies grow.
    const staging_bound = system.nav_mark_staging.capacity + 1;
    try system.nav_marks.ensureTotalCapacity(system.allocator, 2 * staging_bound);
    const marks = system.nav_marks.capacity;
    try system.reserveTerrainNavRecord(staging_bound);
    try std.testing.expectEqual(marks, system.nav_marks.capacity);
    try std.testing.expect(system.nav_mark_staging.capacity >= staging_bound);
    try std.testing.expect(system.nav_mark_growth.logged);

    // All three grow in one reserve.
    const all_bound = @max(system.nav_marks.capacity, system.nav_mark_staging.capacity) + 1;
    try system.reserveTerrainNavRecord(all_bound);
    try std.testing.expect(system.nav_marks.capacity >= all_bound);
    try std.testing.expect(system.nav_mark_staging.capacity >= all_bound);
    try std.testing.expect(system.nav_mark_tallies.capacity >= maxRangeCount(all_bound, nav_mark_range_alignment_items));
}

// The terrain record's reserve, then `nav_mark` over `events`.
fn markEventsForTest(system: *PathfindingSystem, events: []const SimulationEvent, world: *const WorldSystem, thread_system: ?*ThreadSystem) !void {
    try system.reserveTerrainNavRecord(events.len);
    markNavEvents(system, events, world, thread_system);
}

test "threaded nav mark interpretation equals serial for a dense multi-chunk edit with runs straddling ranges and mixed tile and obstacle events" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(-16);
    var events = try navMarkTestEvents(std.testing.allocator, &world);
    defer events.deinit(std.testing.allocator);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var serial = PathfindingSystem.init(std.testing.allocator);
    defer serial.deinit();
    try serial.reserve(abstractCapacity());
    try serial.rebuildStaticNavGridWithWorld(&data, &world, null);
    try markEventsForTest(&serial, events.items, &world, null);
    // The merge folds same-chunk tile runs, so there are fewer marks than events.
    try std.testing.expect(serial.nav_marks.items.len < events.items.len);
    for (serial.nav_marks.items) |mark| try std.testing.expectEqual(types.NavMarkKind.tile_box, mark.kind);

    for ([_]usize{ 8, 16, 24 }) |items_per_range| {
        var threaded = PathfindingSystem.init(std.testing.allocator);
        defer threaded.deinit();
        try threaded.reserve(abstractCapacity());
        try threaded.rebuildStaticNavGridWithWorld(&data, &world, null);
        threaded.nav_controls = .{ .adaptive = false, .items_per_range = items_per_range };
        try markEventsForTest(&threaded, events.items, &world, &threads);
        try std.testing.expectEqual(serial.nav_marks.items.len, threaded.nav_marks.items.len);
        for (serial.nav_marks.items, threaded.nav_marks.items) |a, b| try std.testing.expectEqual(a, b);
    }
}

test "a terrain nav record after its reserve allocates nothing inline and on a multi-worker ThreadSystem, threaded equal to inline; an out-of-memory reserve records no mark (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var meta = try loadTestWorldMeta(std.testing.allocator);
    defer meta.deinit();
    var world = try test_support.abstractTestWorld(&meta, 384, 384);
    defer world.deinit();
    _ = try world.addLevel(-16);
    var events = try navMarkTestEvents(std.testing.allocator, &world);
    defer events.deinit(std.testing.allocator);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2, .items_per_range = 1 });
    defer threads.deinit();

    var inline_system = PathfindingSystem.init(std.testing.allocator);
    defer inline_system.deinit();
    try inline_system.reserve(abstractCapacity());
    try inline_system.rebuildStaticNavGridWithWorld(&data, &world, null);
    try inline_system.reserveTerrainNavRecord(events.items.len);
    var inline_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    inline_system.allocator = inline_failing.allocator();
    inline_system.recordTerrainNavEvents(events.items, &world, null);
    inline_system.allocator = std.testing.allocator;
    try std.testing.expect(!inline_failing.has_induced_failure);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    system.nav_controls = .{ .adaptive = false, .items_per_range = 8 };

    // A reserve past the steady capacity that runs out of memory records nothing.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, system.reserveTerrainNavRecord(events.items.len));
    try std.testing.expectEqual(@as(usize, 0), system.nav_marks.items.len);
    system.allocator = std.testing.allocator;

    // Reserve, then record across several worker ranges with every allocation failing.
    try system.reserveTerrainNavRecord(events.items.len);
    var steady = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = steady.allocator();
    system.recordTerrainNavEvents(events.items, &world, &threads);
    system.allocator = std.testing.allocator;
    try std.testing.expect(!steady.has_induced_failure);
    try std.testing.expectEqual(inline_system.nav_marks.items.len, system.nav_marks.items.len);
    for (inline_system.nav_marks.items, system.nav_marks.items) |a, b| try std.testing.expectEqual(a, b);
}
