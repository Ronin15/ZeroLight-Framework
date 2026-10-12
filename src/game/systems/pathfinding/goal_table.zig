// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The per-step goal table: one projection per distinct blocked goal of the step's
//! navigation intents, shared by every status query, intake request, group-field decision,
//! and solve of that step. `PathfindingSystem.resolveGoals` builds it in two threaded
//! stages, `goal_scan` over intents and `goal_project` over distinct blocked goals, with an
//! ordered main-thread merge between them; every grid change invalidates it.

const std = @import("std");
const simd = @import("../../../core/simd.zig");
const ParallelRange = @import("../../../app/thread_system.zig").ParallelRange;
const WorkerId = @import("../../../app/thread_system.zig").WorkerId;
const maxRangeCount = @import("../../../app/thread_system.zig").maxRangeCount;
const NavGraph = @import("nav_graph.zig").NavGraph;
const NavGrid = @import("nav_grid.zig").NavGrid;
const ElementMap = @import("connectivity.zig").ElementMap;
const types = @import("types.zig");
const GridCell = types.GridCell;
const TraversalClass = types.TraversalClass;
const traversalOf = types.traversalOf;
const no_cell = types.no_cell;
const default_goal_projection_radius = types.default_goal_projection_radius;
const thread_shared_record_alignment = types.thread_shared_record_alignment;

/// `goal_scan` range alignment: every range's window of u64 goal refs starts on a cache
/// line.
pub const scan_range_alignment_items: usize = thread_shared_record_alignment / @sizeOf(u64);
/// `goal_project` range alignment: every range's run of u32 live cells starts on a cache
/// line.
pub const project_range_alignment_items: usize = thread_shared_record_alignment / @sizeOf(u32);

comptime {
    std.debug.assert(scan_range_alignment_items % simd.lane_count == 0);
    std.debug.assert(@sizeOf(ScanTally) % thread_shared_record_alignment == 0);
}

/// Each traversal's nav graph. Every graph covers the world's extent.
pub const Graphs = std.EnumArray(TraversalClass, *const NavGraph);

/// The table key of a blocked goal: its traversal, goal level, and goal cell index.
pub fn goalRef(traversal: TraversalClass, level: u16, cell: usize) u64 {
    // A validated level's cell indices stay below 2^32.
    const cell_bits: u32 = @intCast(cell);
    return (@as(u64, @backingInt(traversal)) << 48) | (@as(u64, level) << 32) | cell_bits;
}

fn refTraversal(ref: u64) TraversalClass {
    return @fromBackingInt(@as(u8, @truncate(ref >> 48)));
}

fn refLevel(ref: u64) u16 {
    return @truncate(ref >> 32);
}

fn refCell(ref: u64) u32 {
    return @truncate(ref);
}

/// One `goal_scan` range's count of distinct refs in its window and of blocked intents,
/// on its own cache line.
pub const ScanTally = struct {
    count: usize align(thread_shared_record_alignment) = 0,
    blocked: usize = 0,
};

/// One step's distinct blocked goals and their live cells. Built by
/// `PathfindingSystem.resolveGoals` on the main thread around its two dispatches; read-only
/// from the end of that call to the next one or the next grid change, so const readers are
/// safe on workers. Storage follows the logical item `limit` (intents per step), reserved at
/// the population seam and grown geometrically at the resolve's entry.
pub const GoalTable = struct {
    // Goal ref -> entry index, generation-cleared each resolve.
    map: ElementMap = .{},
    // Per entry, in first-seen intent order: its goal ref (the project stage's items) and
    // its live cell (`no_cell`: no open cell within the projection radius).
    refs: std.ArrayList(u64) = .empty,
    live: std.ArrayListAligned(u32, .fromByteUnits(thread_shared_record_alignment)) = .empty,
    // `goal_scan` staging: range r writes its distinct refs from `r * items_per_range`, and
    // its tally.
    scan_refs: std.ArrayListAligned(u64, .fromByteUnits(thread_shared_record_alignment)) = .empty,
    scan_tallies: std.ArrayListAligned(ScanTally, .fromByteUnits(thread_shared_record_alignment)) = .empty,
    // Intents one resolve covers without growing; assigned only after every reserve
    // succeeded.
    limit: usize = 0,
    // Entries match the grid now (cleared at every grid change and on a failed resolve).
    valid: bool = false,

    pub fn deinit(self: *GoalTable, allocator: std.mem.Allocator) void {
        self.scan_tallies.deinit(allocator);
        self.scan_refs.deinit(allocator);
        self.live.deinit(allocator);
        self.refs.deinit(allocator);
        self.map.deinit(allocator);
        self.* = undefined;
    }

    /// Sizes the table for `limit` intents per resolve: one entry and one scan slot per
    /// intent, and a scan tally per range any partition of them can form. Leaves the table
    /// invalid. On error the logical limit and every buffer's contents stay usable at the
    /// old limit.
    pub fn reserve(self: *GoalTable, allocator: std.mem.Allocator, limit: usize) !void {
        self.valid = false;
        if (limit <= self.limit) return;
        try self.map.reserve(allocator, limit);
        try self.refs.ensureTotalCapacity(allocator, limit);
        try self.live.ensureTotalCapacity(allocator, limit);
        try self.scan_refs.ensureTotalCapacity(allocator, limit);
        try self.scan_tallies.ensureTotalCapacity(allocator, maxRangeCount(limit, scan_range_alignment_items));
        self.limit = limit;
        std.debug.assert(self.refs.capacity >= limit and self.live.capacity >= limit and self.scan_refs.capacity >= limit);
    }

    pub fn invalidate(self: *GoalTable) void {
        self.valid = false;
    }

    /// The live cell of blocked goal `ref` when the valid table holds it: the nearest open
    /// cell within the projection radius, or `no_cell` for none. Null when the table is
    /// invalid or did not see the goal this step. O(1).
    pub fn lookup(self: *const GoalTable, ref: u64) ?u32 {
        // An empty table may hold no map slots at all.
        if (!self.valid or self.refs.items.len == 0) return null;
        const entry = self.map.get(ref) orelse return null;
        return self.live.items[entry];
    }

    /// Opens a resolve's scan over `item_count` intents in `range_count` ranges. Reserved:
    /// `item_count` within the limit and the tallies within their reserve.
    pub fn beginScan(self: *GoalTable, item_count: usize, range_count: usize) void {
        std.debug.assert(item_count <= self.limit);
        std.debug.assert(self.scan_refs.capacity >= item_count and self.scan_tallies.capacity >= range_count);
        self.valid = false;
        self.scan_refs.items.len = item_count;
        self.scan_tallies.items.len = range_count;
        @memset(self.scan_tallies.items, .{});
    }

    /// The scan's ordered merge: each range's window of distinct refs in range order, each
    /// ref new to the map appended as the next entry, so entries follow first occurrence in
    /// intent order for any partition. O(1) per window entry. Returns the blocked intents.
    pub fn mergeScan(self: *GoalTable, items_per_range: usize) usize {
        self.map.clear();
        self.refs.clearRetainingCapacity();
        var blocked: usize = 0;
        for (self.scan_tallies.items, 0..) |tally, range_index| {
            blocked += tally.blocked;
            for (self.scan_refs.items[range_index * items_per_range ..][0..tally.count]) |ref| {
                const entry = self.map.getOrPut(ref);
                if (entry.found) continue;
                // Entries stay below the item limit, a u32 index width.
                entry.value.* = @intCast(self.refs.items.len);
                self.refs.appendAssumeCapacity(ref);
            }
        }
        self.live.items.len = self.refs.items.len;
        return blocked;
    }

    /// Marks the projected entries valid until the next grid change.
    pub fn finish(self: *GoalTable) void {
        std.debug.assert(self.live.items.len == self.refs.items.len);
        self.valid = true;
    }
};

// The goal ref of each recently seen blocked goal in one scan range, so a repeat writes no
// second window entry. A ref evicted from this fixed table opens a new entry on its next
// occurrence; the merge dedupes, so the table stays exact.
const RecentRefs = struct {
    const slot_count = 8;

    refs: [slot_count]u64 = undefined,
    len: usize = 0,
    next_replace: usize = 0,

    fn contains(self: *const RecentRefs, ref: u64) bool {
        for (self.refs[0..self.len]) |recent| {
            if (recent == ref) return true;
        }
        return false;
    }

    fn remember(self: *RecentRefs, ref: u64) void {
        if (self.len < slot_count) {
            self.refs[self.len] = ref;
            self.len += 1;
        } else {
            self.refs[self.next_replace] = ref;
            self.next_replace = (self.next_replace + 1) % slot_count;
        }
    }
};

/// The goal cell of each intent, four intents per vector (goal positions packed from the
/// AoS intents) with a scalar tail; bit-identical to `worldToCellClamped`. Every level
/// shares one extent, so one grid converts all of them.
// SIMD verdict: the conversion is uniform float math over packed lanes; the gather from
// AoS intents is a fixed four-field copy per lane.
pub fn goalCells(comptime Intent: type, grid: *const NavGrid, intents: []const Intent, out: []GridCell) void {
    std.debug.assert(out.len == intents.len);
    std.debug.assert(grid.width != 0 and grid.height != 0);
    const cell_size = simd.splatFloat4(grid.cell_size);
    const min_cell = simd.splatInt4(0);
    // Grid dimensions fit i32, as in worldToCellClamped.
    const max_x = simd.splatInt4(@intCast(grid.width - 1));
    const max_y = simd.splatInt4(@intCast(grid.height - 1));
    const vector_end = simd.vectorizedEnd(intents.len);
    var index: usize = 0;
    while (index < vector_end) : (index += simd.lane_count) {
        var goal_x: [simd.lane_count]f32 = undefined;
        var goal_y: [simd.lane_count]f32 = undefined;
        inline for (0..simd.lane_count) |lane| {
            goal_x[lane] = intents[index + lane].goal.x;
            goal_y[lane] = intents[index + lane].goal.y;
        }
        const cell_x = simd.toIntArray(simd.clampInt4(simd.floorToI4(simd.divFloat4(simd.loadFloat4(&goal_x), cell_size)), min_cell, max_x));
        const cell_y = simd.toIntArray(simd.clampInt4(simd.floorToI4(simd.divFloat4(simd.loadFloat4(&goal_y), cell_size)), min_cell, max_y));
        inline for (0..simd.lane_count) |lane| out[index + lane] = .{ .x = cell_x[lane], .y = cell_y[lane] };
    }
    while (index < intents.len) : (index += 1) out[index] = grid.worldToCellClamped(intents[index].goal);
}

/// One `goal_scan` range over `Intent`s (any type with `agent_class`, `goal_level`, and a
/// `goal` position): each intent's goal cell, and for a blocked one its ref into the
/// range's window unless the range's recent refs hold it. An unbuilt goal level adds
/// nothing. Reads the graphs only.
pub fn ScanJob(comptime Intent: type) type {
    return struct {
        const Self = @This();

        intents: []const Intent,
        // The extent's grid: every traversal's level 0.
        extent: *const NavGrid,
        graphs: Graphs,
        items_per_range: usize,
        refs: []u64,
        tallies: []ScanTally,

        // SIMD verdict: goal cells four-lane (`goalCells`); the blocked read is a directory
        // and bit gather and the recent-ref probe a key compare, both scalar.
        pub fn run(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
            const job: *Self = @ptrCast(@alignCast(context));
            std.debug.assert(range.index < job.tallies.len);
            std.debug.assert(range.start == range.index * job.items_per_range);
            std.debug.assert(range.start <= range.end and range.end <= job.intents.len and range.end <= job.refs.len);
            var tally = ScanTally{};
            var recent: RecentRefs = .{};
            var block_start = range.start;
            while (block_start < range.end) : (block_start += simd.lane_count) {
                const block = job.intents[block_start..@min(block_start + simd.lane_count, range.end)];
                var cells: [simd.lane_count]GridCell = undefined;
                goalCells(Intent, job.extent, block, cells[0..block.len]);
                for (block, cells[0..block.len]) |intent, cell| {
                    const traversal = traversalOf(intent.agent_class);
                    const grid = job.graphs.get(traversal).grid(intent.goal_level) orelse continue;
                    // A clamped cell lies in the extent.
                    const index = grid.indexForCell(cell).?;
                    if (!grid.isBlockedIndex(index)) continue;
                    tally.blocked += 1;
                    const ref = goalRef(traversal, intent.goal_level, index);
                    if (recent.contains(ref)) continue;
                    recent.remember(ref);
                    job.refs[range.start + tally.count] = ref;
                    tally.count += 1;
                }
            }
            job.tallies[range.index] = tally;
        }
    };
}

/// One `goal_project` range: each entry's live cell, at most one write per item into its
/// `[start, end)` run of `live`.
pub const ProjectJob = struct {
    refs: []const u64,
    live: []u32,
    graphs: Graphs,
    range_count: usize,

    // SIMD verdict: scalar. A ring scan with an early exit; its row tests are already
    // word-wide (`NavGrid.firstOpenInRow`).
    pub fn run(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
        const job: *ProjectJob = @ptrCast(@alignCast(context));
        std.debug.assert(range.index < job.range_count);
        std.debug.assert(range.start <= range.end and range.end <= job.refs.len and range.end <= job.live.len);
        for (job.refs[range.start..range.end], job.live[range.start..range.end]) |ref, *live| live.* = projectRef(job.graphs, ref);
    }
};

/// The nearest open cell to blocked goal `ref` within the projection radius, or `no_cell`.
pub fn projectRef(graphs: Graphs, ref: u64) u32 {
    // A table ref names a built level of its traversal's graph.
    const grid = graphs.get(refTraversal(ref)).grid(refLevel(ref)).?;
    const cell = refCell(ref);
    const goal = GridCell{ .x = @intCast(cell % grid.width), .y = @intCast(cell / grid.width) };
    const projected = grid.projectToNearestOpen(goal, default_goal_projection_radius) orelse return no_cell;
    // Below the level's cell count.
    return @intCast(projected);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const math = @import("../../../core/math.zig");
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const PathAgentClass = @import("../../simulation.zig").PathAgentClass;
const DataSystem = @import("../../data_system.zig").DataSystem;
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const test_support = @import("test_support.zig");

const TestIntent = struct {
    agent_class: PathAgentClass = .default,
    goal_level: u16 = 0,
    goal: math.Vec2,
};

test "goal cells in four lanes equal the scalar conversion over lane bodies, tails, and out-of-extent positions" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserve(test_support.baselineCapacity());
    try system.rebuildStaticNavGrid(&data, 320, 160, 32);
    const grid = system.graph.grid(0).?;
    const positions = [_]math.Vec2{
        .{ .x = 0, .y = 0 },         .{ .x = 31.999, .y = 32 },  .{ .x = -40, .y = 12 },     .{ .x = 5000, .y = -1 },
        .{ .x = 319.5, .y = 159.5 }, .{ .x = 160, .y = 80.25 },  .{ .x = 64.5, .y = 1e9 },   .{ .x = -1e9, .y = 95.9 },
        .{ .x = 33, .y = 0.5 },      .{ .x = 288.75, .y = 127 }, .{ .x = 1.5, .y = 158.99 },
    };
    for (0..positions.len + 1) |len| {
        var intents: [positions.len]TestIntent = undefined;
        for (&intents, positions) |*intent, position| intent.* = .{ .goal = position };
        var cells: [positions.len]GridCell = undefined;
        goalCells(TestIntent, grid, intents[0..len], cells[0..len]);
        for (intents[0..len], cells[0..len]) |intent, cell| try std.testing.expectEqual(grid.worldToCellClamped(intent.goal), cell);
    }
}

// A 10x10-cell world-less level of 32-unit cells in 4-cell chunks: a 5x5 blocking block at
// cells (1..5, 1..5) and a blocking column at x 8, rows 0..7.
fn blockedGoalSystem(allocator: std.mem.Allocator, data: *DataSystem) !PathfindingSystem {
    _ = try test_support.addNavBody(data, .{ .x = 32, .y = 32 }, .{ .x = 160, .y = 160 }, true);
    _ = try test_support.addNavBody(data, .{ .x = 256, .y = 0 }, .{ .x = 32, .y = 256 }, true);
    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    var capacity = test_support.baselineCapacity();
    capacity.nav_chunk_tiles = 4;
    try system.reserve(capacity);
    try system.rebuildStaticNavGrid(data, 320, 320, 32);
    return system;
}

fn cellPosition(cell: GridCell) math.Vec2 {
    return .{ .x = @as(f32, @floatFromInt(cell.x)) * 32 + 16, .y = @as(f32, @floatFromInt(cell.y)) * 32 + 16 };
}

// The level's blocked cells in index order.
fn blockedCells(grid: *const NavGrid, out: []GridCell) []GridCell {
    var len: usize = 0;
    for (0..grid.cellCount()) |index| {
        if (!grid.isBlockedIndex(index) or len == out.len) continue;
        out[len] = .{ .x = @intCast(index % grid.width), .y = @intCast(index / grid.width) };
        len += 1;
    }
    return out[0..len];
}

// Intents over open goals, an unbuilt level, and every blocked cell, interleaved so one
// range sees more distinct blocked goals than its recent refs hold.
fn mixedIntents(grid: *const NavGrid, intents: []TestIntent) void {
    var buffer: [100]GridCell = undefined;
    const blocked = blockedCells(grid, &buffer);
    std.debug.assert(blocked.len > 16);
    for (intents, 0..) |*intent, index| {
        intent.* = switch (index % 5) {
            0, 3 => .{ .goal = cellPosition(blocked[(index * 7) % blocked.len]) },
            1 => .{ .goal = cellPosition(.{ .x = @intCast(index % 10), .y = 9 }) },
            2 => .{ .goal_level = 3, .goal = cellPosition(.{ .x = 3, .y = 3 }) },
            else => .{ .goal = cellPosition(blocked[index % blocked.len]) },
        };
    }
}

// The reference table: the distinct blocked goal refs in first-seen intent order, each with
// its projection.
fn expectReferenceTable(system: *const PathfindingSystem, intents: []const TestIntent) !void {
    var expected: std.ArrayList(u64) = .empty;
    defer expected.deinit(std.testing.allocator);
    for (intents) |intent| {
        const grid = system.graph.grid(intent.goal_level) orelse continue;
        const index = grid.indexForCell(grid.worldToCellClamped(intent.goal)).?;
        if (!grid.isBlockedIndex(index)) continue;
        const ref = goalRef(traversalOf(intent.agent_class), intent.goal_level, index);
        if (std.mem.indexOfScalar(u64, expected.items, ref) == null) try expected.append(std.testing.allocator, ref);
    }
    const table = &system.goals;
    try std.testing.expect(table.valid);
    try std.testing.expectEqualSlices(u64, expected.items, table.refs.items);
    for (expected.items, table.live.items) |ref, live| {
        const grid = system.graph.grid(refLevel(ref)).?;
        const cell = refCell(ref);
        const projected = grid.projectToNearestOpen(.{ .x = @intCast(cell % grid.width), .y = @intCast(cell / grid.width) }, default_goal_projection_radius);
        try std.testing.expectEqual(if (projected) |open| @as(u32, @intCast(open)) else no_cell, live);
        try std.testing.expectEqual(live, table.lookup(ref).?);
    }
}

test "the goal table holds exactly the distinct blocked goals in first-seen order with their projections, and nothing for open goals or unbuilt levels" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = try blockedGoalSystem(std.testing.allocator, &data);
    defer system.deinit();
    const grid = system.graph.grid(0).?;
    var intents: [97]TestIntent = undefined;
    mixedIntents(grid, &intents);
    try system.reserveGoals(intents.len);
    const stats = try system.resolveGoals(TestIntent, &intents, null, .{});
    try expectReferenceTable(&system, &intents);
    try std.testing.expectEqual(intents.len, stats.intents);
    try std.testing.expectEqual(system.goals.refs.items.len, stats.distinct);
    try std.testing.expectEqual(stats.distinct, stats.projections);
    try std.testing.expect(stats.distinct > RecentRefs.slot_count);
    var blocked: usize = 0;
    for (intents) |intent| {
        const level_grid = system.graph.grid(intent.goal_level) orelse continue;
        if (level_grid.isBlockedCell(level_grid.worldToCellClamped(intent.goal))) blocked += 1;
    }
    try std.testing.expectEqual(blocked, stats.blocked);
    // An open goal and an unbuilt level hold no entry.
    try std.testing.expectEqual(@as(?u32, null), system.goals.lookup(goalRef(.walk, 0, 9 * 10 + 1)));
    try std.testing.expectEqual(@as(?u32, null), system.goals.lookup(goalRef(.walk, 3, 3 * 10 + 3)));
}

test "the goal table is equal serial and threaded across worker counts and range sizes, with both stages on workers" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = try blockedGoalSystem(std.testing.allocator, &data);
    defer system.deinit();
    var intents: [203]TestIntent = undefined;
    mixedIntents(system.graph.grid(0).?, &intents);
    try system.reserveGoals(intents.len);
    _ = try system.resolveGoals(TestIntent, &intents, null, .{});
    const serial_refs = try std.testing.allocator.dupe(u64, system.goals.refs.items);
    defer std.testing.allocator.free(serial_refs);
    const serial_live = try std.testing.allocator.dupe(u32, system.goals.live.items);
    defer std.testing.allocator.free(serial_live);
    for ([_]usize{ 1, 2, 4 }) |workers| {
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers, .items_per_range = 1 });
        defer threads.deinit();
        for ([_]usize{ 1, 2, 7, 8 }) |items_per_range| {
            const stats = try system.resolveGoals(TestIntent, &intents, &threads, .{ .items_per_range = items_per_range, .adaptive = false });
            try std.testing.expectEqualSlices(u64, serial_refs, system.goals.refs.items);
            try std.testing.expectEqualSlices(u32, serial_live, system.goals.live.items);
            for (serial_refs, serial_live) |ref, live| try std.testing.expectEqual(live, system.goals.lookup(ref).?);
            try std.testing.expect(!stats.scan_batch.ran_inline and stats.scan_batch.range_count > 1);
            try std.testing.expect(!stats.project_batch.ran_inline and stats.project_batch.range_count > 1);
        }
        // No intents, and intents with no blocked goal: empty stages, a valid empty table.
        const open_goals = [_]TestIntent{ .{ .goal = cellPosition(.{ .x = 9, .y = 9 }) }, .{ .goal = cellPosition(.{ .x = 0, .y = 9 }) } };
        for ([_][]const TestIntent{ intents[0..0], &open_goals }) |batch| {
            const stats = try system.resolveGoals(TestIntent, batch, &threads, .{ .items_per_range = 1, .adaptive = false });
            try std.testing.expectEqual(@as(usize, 0), stats.distinct);
            try std.testing.expect(system.goals.valid and system.goals.refs.items.len == 0);
        }
    }
}

test "a reserved goal resolve allocates nothing on a real multi-worker thread system, and a failed growth leaves the table invalid and its storage intact (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = try blockedGoalSystem(std.testing.allocator, &data);
    defer system.deinit();
    const grid = system.graph.grid(0).?;
    var intents: [131]TestIntent = undefined;
    mixedIntents(grid, &intents);
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 4, .items_per_range = 1 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    try system.reserveGoals(intents.len);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    for ([_]?usize{ 1, 7, null }) |items_per_range| {
        const stats = try system.resolveGoals(TestIntent, &intents, &threads, .{ .items_per_range = items_per_range, .adaptive = items_per_range == null });
        try std.testing.expect(stats.distinct != 0);
        try std.testing.expect(!stats.scan_batch.ran_inline or items_per_range == null);
        _ = try system.resolveGoals(TestIntent, intents[0..17], null, .{});
    }
    try expectReferenceTable(&system, intents[0..17]);
    // Past the limit the resolve grows at its entry; the failed growth writes no entry.
    const refs_before = system.goals.refs.items.len;
    const limit_before = system.goals.limit;
    var more: [263]TestIntent = undefined;
    mixedIntents(grid, &more);
    try std.testing.expectError(error.OutOfMemory, system.resolveGoals(TestIntent, &more, &threads, .{}));
    try std.testing.expect(!system.goals.valid);
    try std.testing.expectEqual(limit_before, system.goals.limit);
    try std.testing.expectEqual(refs_before, system.goals.refs.items.len);
    try std.testing.expectEqual(@as(?u32, null), system.goals.lookup(system.goals.refs.items[0]));
    // The retry with memory grows, counted.
    system.allocator = std.testing.allocator;
    const grows_before = system.goal_table_grows;
    _ = try system.resolveGoals(TestIntent, &more, &threads, .{});
    try std.testing.expectEqual(grows_before + 1, system.goal_table_grows);
    try expectReferenceTable(&system, &more);
}

test "a nav batch, an apply of edits, or a rebuild invalidates the goal table, and lookups then compute the projection on the grid now" {
    const allocator = std.testing.allocator;
    var meta = try test_support.loadTestWorldMeta(allocator);
    defer meta.deinit();
    var world = try test_support.abstractTestWorld(&meta, 320, 320);
    defer world.deinit();
    const grass = try test_support.requireTestTile(&meta, "grass");
    const tree = try test_support.requireTestTile(&meta, "tree_0");
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
    for (4..7) |y| {
        for (4..7) |x| _ = try world.setDenseTile(obstacle, @intCast(x), @intCast(y), tree);
    }
    var data = DataSystem.init(allocator);
    defer data.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    try system.reserve(test_support.abstractCapacity());
    try system.rebuildStaticNavGridWithWorld(&data, &world, null);
    try system.reserveGoals(1);
    const intents = [_]TestIntent{.{ .goal = cellPosition(.{ .x = 5, .y = 5 }) }};
    const key = system.graph.keyForWorld(0, intents[0].goal, .default).?;
    const ref = goalRef(.walk, 0, 5 * 10 + 5);
    // Each opened cell comes first in the projection's ring scan over the cells opened so far.
    const changes = [_][3]u16{ .{ 4, 6, 0 }, .{ 6, 5, 1 }, .{ 4, 5, 2 } };
    for (changes) |change| {
        _ = try system.resolveGoals(TestIntent, &intents, null, .{});
        try std.testing.expect(system.goals.lookup(ref) != null);
        // Open a cell of the block, so the projection moves to it.
        const changed = (try world.setDenseTile(obstacle, change[0], change[1], grass)).?;
        switch (change[2]) {
            0 => _ = try system.applyNavUpdates(&test_support.no_colliders, &world, &.{.{ .level = changed.level, .x = changed.x, .y = changed.y }}),
            1 => {
                try system.markNavDirty(changed.level, changed.x, changed.y);
                _ = try system.applyBufferedNavUpdates(&test_support.no_colliders, &world, null);
            },
            else => try system.rebuildStaticNavGridWithWorld(&data, &world, null),
        }
        try std.testing.expectEqual(@as(?u32, null), system.goals.lookup(ref));
        const grid = system.graph.grid(0).?;
        const live = system.liveGoal(if (change[2] == 2) system.graph.keyForWorld(0, intents[0].goal, .default).? else key, grid);
        try std.testing.expect(live.fallback);
        try std.testing.expectEqual(grid.projectToNearestOpen(.{ .x = 5, .y = 5 }, default_goal_projection_radius), live.cell);
        try std.testing.expectEqual(@as(?usize, @as(usize, change[1]) * 10 + change[0]), live.cell);
    }
}

test "an empty goal table that reserved no slots misses every lookup, and the live goal is computed" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var system = try blockedGoalSystem(std.testing.allocator, &data);
    defer system.deinit();
    const stats = try system.resolveGoals(TestIntent, &.{}, null, .{});
    try std.testing.expectEqual(@as(usize, 0), stats.distinct);
    try std.testing.expect(system.goals.valid and system.goals.limit == 0);
    const ref = goalRef(.walk, 0, 3 * 10 + 3);
    try std.testing.expectEqual(@as(?u32, null), system.goals.lookup(ref));
    const grid = system.graph.grid(0).?;
    const live = system.liveGoal(system.graph.keyForWorld(0, cellPosition(.{ .x = 3, .y = 3 }), .default).?, grid);
    try std.testing.expect(live.fallback);
    try std.testing.expectEqual(grid.projectToNearestOpen(.{ .x = 3, .y = 3 }, default_goal_projection_radius), live.cell);
}
