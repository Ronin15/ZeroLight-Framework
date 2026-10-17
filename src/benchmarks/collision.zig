// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Collision detect throughput: `collision` (a dense 7 px grid of 9 px bodies),
//! `collision-sparse` (isolated pairs), and the broadphase shape groups on the dense grid at
//! a fixed population:
//! - `collision-tall`: the grid's aspect (rows over columns) grows.
//! - `collision-thin`: the grid's aspect (columns over rows) grows.
//! - `collision-stacked`: a 32 x 32 grid copied onto more levels.
//! Pass shape (the three shape groups): time and sweep work per body flat in aspect and in
//! levels. Asserts check the contact count (the grid's analytic same-level overlap count),
//! the entries (at most one per strip a body spans), and the sweep's visits per entry
//! against the grid's bound: the entries of one strip in the columns a body's width reaches,
//! flat in column height, row width, and level count. `collision` and `collision-sparse`:
//! time linear in bodies; asserts check the analytic contact count (the 512-wide grid's
//! neighbour pairs; one pair per group of 20 sparse bodies).
//!
//! The static groups hold the item count of one-tile statics on a two-tile pitch, so the
//! world grows with the static count, plus a fixed 2,048 dynamic bodies, half of them
//! overlapping one static each and half in the free tiles:
//! - `collision-static-heavy-sap`: the dynamics clustered in a fixed 64 x 64-tile region.
//!   Pass shape: tuned time and main flat in statics.
//! - `collision-static-heavy`: the dynamics spread uniformly over the world. Pass shape:
//!   time per dynamic flat in statics.
//! - `collision-static-index-change`: the clustered fixture; each step moves one static
//!   through the commit seam (`fixtures.CommitSeam`: reserve, budgeted commit, collider
//!   capture, and sync) and then runs one collision step. Pass shape: flat in statics.
//! Asserts check fixture invariants only: the analytic contact count (one per overlapping
//! dynamic) in every static group; in `collision-static-index-change` also the collider row
//! count, and that each move commits, syncs, and changes chunks.
//!
//! Every group prints `candidate_pairs=` and `contacts=`, the shape groups `per_body=`
//! (mean time per body), the static groups `per_dynamic=`; `--details` adds each stage's
//! shape and batch time, `fill=`, `sort=`, `broad=` (the row's batch, its mean time; the
//! others the last step's), and `narrow=`, with the fill, sort, and narrowphase tuners'
//! state in brackets (each stage tunes on its own; the broadphase's is the row's tuning
//! cell), then `entries=` (sweep entries), `visits_per_body=` (candidates the sweep tested,
//! counted with the perf log only), and `main=` with `main_per_item=` per body: the time
//! outside the four stages' worker dispatches.

const std = @import("std");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const math = @import("../core/math.zig");
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const CollisionStats = @import("../game/systems/collision.zig").CollisionStats;
const CollisionStrips = @import("../game/systems/collision.zig").CollisionStrips;
const CollisionSystem = @import("../game/systems/collision.zig").CollisionSystem;
const collision_range_alignment_items = @import("../game/systems/collision.zig").collision_range_alignment_items;
const EntityId = @import("../game/data_system.zig").EntityId;
const CollisionContact = @import("../game/simulation.zig").CollisionContact;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const ColliderGeometry = @import("../game/systems/static_colliders.zig").ColliderGeometry;
const StaticColliderSystem = @import("../game/systems/static_colliders.zig").StaticColliderSystem;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const tile_size = @import("../assets/world_tileset_meta.zig").required_tile_size;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "collision",
    .item_label = "collision bodies",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = writeCollisionWorkload,
};

pub const sparse_group = suite.BenchmarkGroup{
    .name = "collision-sparse",
    .item_label = "collision bodies",
    .item_counts = &suite.event_scale_counts,
    .runCase = runSparseCase,
    .write_workload = writeCollisionWorkload,
};

pub const tall_group = suite.BenchmarkGroup{
    .name = "collision-tall",
    .item_label = ShapeCode.label,
    .item_counts = &tall_item_counts,
    .runCase = runShapeCase,
    .write_workload = writeCollisionWorkload,
};

pub const stacked_group = suite.BenchmarkGroup{
    .name = "collision-stacked",
    .item_label = ShapeCode.label,
    .item_counts = &stacked_item_counts,
    .runCase = runShapeCase,
    .write_workload = writeCollisionWorkload,
};

pub const thin_group = suite.BenchmarkGroup{
    .name = "collision-thin",
    .item_label = ShapeCode.label,
    .item_counts = &thin_item_counts,
    .runCase = runShapeCase,
    .write_workload = writeCollisionWorkload,
};

pub const static_heavy_sap_group = suite.BenchmarkGroup{
    .name = "collision-static-heavy-sap",
    .item_label = "static bodies",
    .item_counts = &static_item_counts,
    .runCase = runStaticHeavySapCase,
    .write_workload = writeStaticWorkload,
};

pub const static_heavy_group = suite.BenchmarkGroup{
    .name = "collision-static-heavy",
    .item_label = "static bodies",
    .item_counts = &static_item_counts,
    .runCase = runStaticHeavyCase,
    .write_workload = writeStaticWorkload,
};

pub const static_index_change_group = suite.BenchmarkGroup{
    .name = "collision-static-index-change",
    .item_label = "static bodies",
    .item_counts = &static_item_counts,
    .runCase = runStaticIndexChangeCase,
    .write_workload = writeStaticWorkload,
};

const FixtureMode = enum {
    dense,
    sparse,
};

// The dense grid's body size and pitch: each body overlaps its eight neighbours.
const dense_body_size: f32 = 9;
const dense_pitch: f32 = 7;

const ShapeVariant = enum(u8) { tall, stacked, thin };
// `axis` is the grid's rows over columns (tall), its level count (stacked), or its columns
// over rows (thin).
const ShapeCode = suite.ItemCode(struct { variant: ShapeVariant, axis: u32 }, &.{6});

// The tall and thin groups' fixed population, and the stacked group's grid side per level:
// the sweep's growth in column height, row width, and levels shows at these sizes.
const shape_bodies: usize = 4_096;
const stacked_side: usize = 32;

const tall_item_counts = [_]usize{
    ShapeCode.of(.{ .variant = .tall, .axis = 1 }),
    ShapeCode.of(.{ .variant = .tall, .axis = 16 }),
    ShapeCode.of(.{ .variant = .tall, .axis = 256 }),
};

const stacked_item_counts = [_]usize{
    ShapeCode.of(.{ .variant = .stacked, .axis = 1 }),
    ShapeCode.of(.{ .variant = .stacked, .axis = 4 }),
    ShapeCode.of(.{ .variant = .stacked, .axis = 16 }),
};

const thin_item_counts = [_]usize{
    ShapeCode.of(.{ .variant = .thin, .axis = 1 }),
    ShapeCode.of(.{ .variant = .thin, .axis = 16 }),
    ShapeCode.of(.{ .variant = .thin, .axis = 256 }),
};

// A grid of `columns` x `rows` dense bodies on each of `levels` levels, the same xy on
// every level; levels are set only when `stamp_levels`.
const GridShape = struct {
    columns: usize,
    rows: usize,
    levels: u16,
    stamp_levels: bool,

    fn bodies(self: GridShape) usize {
        return self.columns * self.rows * self.levels;
    }

    // Same-level overlapping pairs: horizontal, vertical, and both diagonals per level.
    fn contacts(self: GridShape) usize {
        const c = self.columns;
        const r = self.rows;
        return self.levels * ((c - 1) * r + c * (r - 1) + 2 * (c - 1) * (r - 1));
    }
};

fn gridShapeFor(code: usize) !GridShape {
    const fields = try ShapeCode.decode(code);
    switch (fields.variant) {
        .tall => {
            std.debug.assert(fields.axis > 0 and shape_bodies % fields.axis == 0);
            const columns: usize = std.math.sqrt(shape_bodies / fields.axis);
            std.debug.assert(columns * columns * fields.axis == shape_bodies);
            return .{ .columns = columns, .rows = shape_bodies / columns, .levels = 1, .stamp_levels = false };
        },
        .stacked => return .{ .columns = stacked_side, .rows = stacked_side, .levels = @intCast(fields.axis), .stamp_levels = true },
        .thin => {
            std.debug.assert(fields.axis > 0 and shape_bodies % fields.axis == 0);
            const rows: usize = std.math.sqrt(shape_bodies / fields.axis);
            std.debug.assert(rows * rows * fields.axis == shape_bodies);
            return .{ .columns = shape_bodies / rows, .rows = rows, .levels = 1, .stamp_levels = false };
        },
    }
}

// The most strips a dense body spans.
fn denseStripsPerBodyBound() usize {
    return @as(usize, @intFromFloat(@ceil(dense_body_size / CollisionStrips.default.height))) + 1;
}

// The dense grid's sweep candidates per entry: the entries one strip holds in a column (rows
// whose span meets the strip) times the columns starting inside a body's width, its own
// included, less the entry itself.
fn denseVisitsPerEntryBound() usize {
    const rows_per_strip: usize = @intFromFloat(@ceil((CollisionStrips.default.height + dense_body_size) / dense_pitch));
    const columns_reached: usize = @intFromFloat(@ceil(dense_body_size / dense_pitch));
    return rows_per_strip * columns_reached - 1;
}

// A dense-sized body at `position`, with no collision response.
fn addDenseBody(data: *DataSystem, position: math.Vec2) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = dense_body_size, .y = dense_body_size } });
    return entity;
}

fn createGridFixture(allocator: std.mem.Allocator, shape: GridShape) !DataSystem {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    for (0..shape.levels) |level| {
        for (0..shape.rows) |row| {
            for (0..shape.columns) |column| {
                const entity = try addDenseBody(&data, .{
                    .x = @as(f32, @floatFromInt(column)) * dense_pitch,
                    .y = @as(f32, @floatFromInt(row)) * dense_pitch,
                });
                if (shape.stamp_levels) try data.setWorldLevel(entity, @intCast(level));
            }
        }
    }
    return data;
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !DataSystem {
    return createFixtureWithMode(allocator, count, .dense);
}

fn createFixtureWithMode(allocator: std.mem.Allocator, count: usize, mode: FixtureMode) !DataSystem {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const columns: usize = 512;
    for (0..count) |index| _ = try addDenseBody(&data, benchmarkPosition(index, columns, mode));

    return data;
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .dense);
}

pub fn runSparseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .sparse);
}

fn runShapeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const shape = try gridShapeFor(item_count);
    var data = try createGridFixture(allocator, shape);
    defer data.deinit();
    var stats = try measureCase(allocator, io, options, case, shape.bodies(), &data, null);
    std.debug.assert(stats.output_count == shape.contacts());
    const stages = stats.collision_stages.?;
    if (stages.entries > shape.bodies() * denseStripsPerBodyBound()) return error.CollisionEntriesPastStripBound;
    // The sweep counts its visits only with the perf log.
    if (runtime_perf_log.enabled and stages.visits > stages.entries * denseVisitsPerEntryBound()) return error.CollisionVisitsPastStripBound;
    // The header names the config; throughput stays per body.
    stats.item_count = item_count;
    return stats;
}

fn runCaseWithMode(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, mode: FixtureMode) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var data = try createFixtureWithMode(allocator, item_count, mode);
    defer data.deinit();
    const stats = try measureCase(allocator, io, options, case, item_count, &data, null);
    if (stats.iterations > 0 and stats.output_count != fixtureContacts(item_count, mode)) return error.CollisionContactCountMismatch;
    return stats;
}

// Contacts of `count` bodies in `mode`: a dense body overlaps its row, column, and diagonal
// neighbours in the 512-wide grid; a sparse group of 20 holds one overlapping pair.
fn fixtureContacts(count: usize, mode: FixtureMode) usize {
    const columns: usize = 512;
    switch (mode) {
        .sparse => return count / 20 + @intFromBool(count % 20 >= 2),
        .dense => {
            var contacts: usize = 0;
            var row_start: usize = 0;
            var above: usize = 0;
            while (row_start < count) : (row_start += columns) {
                const width: usize = @min(columns, count - row_start);
                contacts += width - 1;
                // Vertical pairs, then both diagonals against the full row above.
                if (above != 0) contacts += width + (width - 1) + @min(width, above - 1);
                above = width;
            }
            return contacts;
        },
    }
}

// ----------------------------------------------------------------------------
// Static-heavy: a fixed dynamic population among a growing static grid.
// ----------------------------------------------------------------------------

const static_item_counts = [_]usize{ 4_096, 16_384, 65_536 };
const static_dynamic_count: usize = 2_048;
// Statics are one tile on a two-tile pitch; their grid's side is the square root of the
// static count, so the world grows with it.
const static_size: f32 = tile_size;
const static_pitch: f32 = 2 * tile_size;
// Dynamic slot offsets inside a static's pitch cell: slot 0 overlaps the static, slot 1
// sits in the free tile diagonal to it.
const overlap_slot_offset: f32 = 12;
const free_slot_offset: f32 = tile_size + 12;
// The clustered dynamics fill this many pitch cells a side: a fixed 64 x 64-tile region.
const cluster_cells_side: usize = 32;

const DynamicPlacement = enum { clustered, spread };

const StaticHeavyFixture = struct {
    data: DataSystem,
    // Statics per grid side.
    side: usize,
    // The static at the grid's last pitch cell, outside the cluster at every count.
    last_static: EntityId,
};

fn pitchCellOrigin(cell_x: usize, cell_y: usize) math.Vec2 {
    return .{ .x = @as(f32, @floatFromInt(cell_x)) * static_pitch, .y = @as(f32, @floatFromInt(cell_y)) * static_pitch };
}

// `static_count` solid statics, row-major on the pitch grid, then the dynamics by
// `placement`: dynamic k in slot k % 2 of its pitch cell, (cell, slot) distinct.
fn createStaticHeavyFixture(allocator: std.mem.Allocator, static_count: usize, placement: DynamicPlacement) !StaticHeavyFixture {
    const side = std.math.sqrt(static_count);
    if (side * side != static_count) return error.StaticCountNotSquare;
    if (side < cluster_cells_side + 1) return error.StaticGridSmallerThanCluster;
    if (static_count % static_dynamic_count != 0) return error.StaticCountNotDynamicMultiple;
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    var last_static = EntityId.invalid;
    for (0..side) |cell_y| for (0..side) |cell_x| {
        const position = pitchCellOrigin(cell_x, cell_y);
        last_static = try fixtures.addBody(&data, position, .{ .x = static_size, .y = static_size }, .static);
    };

    const spread_step = static_count / static_dynamic_count;
    for (0..static_dynamic_count) |index| {
        const cell = switch (placement) {
            .clustered => index / 2,
            .spread => index * spread_step,
        };
        const cells_x = if (placement == .clustered) cluster_cells_side else side;
        const origin = pitchCellOrigin(cell % cells_x, cell / cells_x);
        const offset = if (index % 2 == 0) overlap_slot_offset else free_slot_offset;
        const position = math.Vec2{ .x = origin.x + offset, .y = origin.y + offset };
        _ = try fixtures.addBody(&data, position, .{ .x = dense_body_size, .y = dense_body_size }, .dynamic);
    }
    return .{ .data = data, .side = side, .last_static = last_static };
}

// Every slot-0 dynamic overlaps its static and nothing else overlaps.
const static_fixture_contacts = static_dynamic_count / 2;

fn runStaticHeavySapCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runStaticCase(allocator, io, options, case, item_count, .clustered, false);
}

fn runStaticHeavyCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runStaticCase(allocator, io, options, case, item_count, .spread, false);
}

fn runStaticIndexChangeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runStaticCase(allocator, io, options, case, item_count, .clustered, true);
}

fn runStaticCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, static_count: usize, placement: DynamicPlacement, move_static: bool) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var fixture = try createStaticHeavyFixture(allocator, static_count, placement);
    defer fixture.data.deinit();
    var mover: ?StaticMover = if (move_static) try StaticMover.init(allocator, &fixture, case) else null;
    defer if (mover) |*static_mover| static_mover.deinit();

    var stats = try measureCase(allocator, io, options, case, static_dynamic_count, &fixture.data, if (mover) |*static_mover| static_mover else null);
    std.debug.assert(stats.output_count == static_fixture_contacts);
    // The header names the static count; throughput and `per_dynamic=` stay per dynamic.
    stats.item_count = static_count;
    return stats;
}

// One static moved through the commit seam each step, alternating between its pitch cell's
// static tile and a free tile one chunk and one tile back on both axes, so every move leaves
// one chunk for another; it overlaps nothing at either.
const StaticMover = struct {
    frame: SimulationFrame,
    colliders: StaticColliderSystem,
    move: fixtures.StaticMove,

    fn init(allocator: std.mem.Allocator, fixture: *const StaticHeavyFixture, case: suite.BenchmarkCase) !StaticMover {
        var frame = SimulationFrame.init(allocator);
        errdefer frame.deinit();
        // One command and its one component event per step.
        try frame.reserveStreams(1, 1, 0, 0, 0, 1);
        var colliders = StaticColliderSystem.init(allocator);
        errdefer colliders.deinit();
        // The statics' tiles: two tiles per pitch cell a side.
        const cells: u32 = @intCast(2 * fixture.side);
        try colliders.rebuild(&fixture.data, ColliderGeometry.init(tile_size, cells, cells, default_chunk_size_tiles));
        if (colliders.rowCount() != fixture.side * fixture.side) return error.WrongStaticCount;
        fixtures.setSpliceTuners(&colliders, case);
        const home = pitchCellOrigin(fixture.side - 1, fixture.side - 1);
        // Statics sit on even tiles, so an odd tile offset lands on a free tile.
        const away_tiles = default_chunk_size_tiles + 1;
        comptime std.debug.assert(away_tiles % 2 == 1);
        const away = @as(f32, @floatFromInt(away_tiles)) * tile_size;
        return .{
            .frame = frame,
            .colliders = colliders,
            .move = .{ .entity = fixture.last_static, .positions = .{ home, .{ .x = home.x - away, .y = home.y - away } } },
        };
    }

    fn deinit(self: *StaticMover) void {
        self.colliders.deinit();
        self.frame.deinit();
        self.* = undefined;
    }

    // The move's set_movement_body through the commit seam (its splice stages on
    // `thread_system` when set).
    fn moveAndSync(self: *StaticMover, data: *DataSystem, thread_system: ?*ThreadSystem) !void {
        self.frame.beginStep();
        const seam = fixtures.CommitSeam{ .colliders = &self.colliders, .structural_headroom = fixtures.StaticMove.structural_headroom };
        const commit = try seam.commit(&self.frame, data, &.{self.move.command()}, thread_system);
        if (commit.structural.components_set != 1) return error.StaticMoveNotApplied;
        const changes = self.colliders.changesThisStep();
        if (changes.len != 1) return error.StaticChangeNotSynced;
        const chunk_tiles = self.colliders.geometry.?.grid.chunk_tiles;
        const old_cells = (changes[0].old orelse return error.StaticMoverUnplaced).cells;
        const new_cells = (changes[0].new orelse return error.StaticMoverUnplaced).cells;
        if (old_cells.min_x / chunk_tiles == new_cells.min_x / chunk_tiles or old_cells.min_y / chunk_tiles == new_cells.min_y / chunk_tiles) return error.StaticMoverStayedInChunk;
        self.move.advance();
    }

    fn spliceOffMainNs(self: *const StaticMover) u64 {
        return offMainNs(self.colliders.last_splice_batch) + offMainNs(self.colliders.last_query_splice_batch);
    }
};

// Warms up, settles the stage tuners, and times one step per iteration: `mover`'s static
// move through the commit seam when set, then the collision update over `data`.
fn measureCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, data: *DataSystem, mover: ?*StaticMover) !suite.RunStats {
    var system = CollisionSystem.init(allocator);
    defer system.deinit();
    useCaseTuners(&system, case);
    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    defer contacts.deinit();

    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    for (0..options.warmup_iterations) |_| {
        _ = try runOnce(&system, data, mover, &contacts, thread_ptr, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!stageTunersSettled(&system) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, data, mover, &contacts, thread_ptr, case);
        }
    }
    const fill_settled_before_measurement = case.adaptive and system.fill_tuner.isSettled();
    const sort_settled_before_measurement = case.adaptive and system.sort_tuner.isSettled();
    const broadphase_settled_before_measurement = if (case.adaptive) system.broadphase_tuner.isSettled() else false;
    const narrowphase_settled_before_measurement = if (case.adaptive) system.narrowphase_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_collision_stats = CollisionStats{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_collision_stats = try runOnce(&system, data, mover, &contacts, thread_ptr, case);
        const end_ns = suite.nowNs(io);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, last_collision_stats.broadphase_batch);
        const mover_off_main_ns = if (mover) |static_mover| static_mover.spliceOffMainNs() else 0;
        const off_main_ns = offMainNs(last_collision_stats.fill_batch) + offMainNs(last_collision_stats.sort_batch) +
            offMainNs(last_collision_stats.broadphase_batch) + offMainNs(last_collision_stats.narrowphase_batch);
        main_total += elapsed_ns -| off_main_ns -| mover_off_main_ns;
    }

    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.collision_stages = .{
        .fill = suite.batchSummaryFromBatch(last_collision_stats.fill_batch),
        .sort = suite.batchSummaryFromBatch(last_collision_stats.sort_batch),
        .fill_tuning = if (case.adaptive) suite.workTuningSummary(system.fill_tuner.report(), fill_settled_before_measurement) else null,
        .sort_tuning = if (case.adaptive) suite.workTuningSummary(system.sort_tuner.report(), sort_settled_before_measurement) else null,
        .entries = last_collision_stats.entry_count,
        .visits = last_collision_stats.broadphase_visits,
    };
    stats.sample_count = item_count;
    stats.candidate_pairs = last_collision_stats.candidate_pair_count;
    stats.output_count = last_collision_stats.contact_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_collision_stats.narrowphase_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.broadphase_tuner.report(), broadphase_settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(system.narrowphase_tuner.report(), narrowphase_settled_before_measurement);
    }
    return stats;
}

/// Gives each of `system`'s stage tuners the case's own tuner (an adaptive case only).
pub fn useCaseTuners(system: *CollisionSystem, case: suite.BenchmarkCase) void {
    for ([_]*AdaptiveWorkTuner{ &system.fill_tuner, &system.sort_tuner, &system.broadphase_tuner, &system.narrowphase_tuner }) |tuner| {
        tuner.* = suite.adaptiveTunerForCase(case, collision_range_alignment_items) orelse return;
    }
}

/// Every stage tuner of `system` settled.
pub fn stageTunersSettled(system: *const CollisionSystem) bool {
    return system.fill_tuner.isSettled() and system.sort_tuner.isSettled() and
        system.broadphase_tuner.isSettled() and system.narrowphase_tuner.isSettled();
}

fn runOnce(
    system: *CollisionSystem,
    data: *DataSystem,
    mover: ?*StaticMover,
    contacts: *RangeOutputStream(CollisionContact),
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) !CollisionStats {
    if (mover) |static_mover| try static_mover.moveAndSync(data, if (case.usesThreadSystem()) thread_system else null);
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(data, contacts);
    }

    return try system.update(data, contacts, thread_system.?, .{
        .items_per_range = case.stageItemsPerRange(collision_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkPosition(index: usize, columns: usize, mode: FixtureMode) math.Vec2 {
    return switch (mode) {
        .dense => .{
            .x = @as(f32, @floatFromInt(index % columns)) * dense_pitch,
            .y = @as(f32, @floatFromInt(index / columns)) * dense_pitch,
        },
        .sparse => sparseBenchmarkPosition(index, columns),
    };
}

fn sparseBenchmarkPosition(index: usize, columns: usize) math.Vec2 {
    const sparse_group_index = index / 20;
    const slot = index % 20;
    const base_index = sparse_group_index * 20 + if (slot == 1) @as(usize, 0) else slot;
    const offset_x: usize = if (slot == 1) 6 else 0;
    return .{
        .x = @floatFromInt((base_index % columns) * 32 + offset_x),
        .y = @floatFromInt((base_index / columns) * 32),
    };
}

fn writeCollisionWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("candidate_pairs={} contacts={}", .{ stats.candidate_pairs, stats.output_count });
    // `sample_count` holds the body count.
    if (stats.sample_count != 0) try writer.print(" per_body={f}", .{suite.formatDuration(stats.mean_ns / stats.sample_count)});
    if (view == .summary) return;
    try writeCollisionDetails(writer, stats);
}

fn writeStaticWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("candidate_pairs={} contacts={}", .{ stats.candidate_pairs, stats.output_count });
    // `sample_count` holds the dynamic count.
    if (stats.sample_count != 0) try writer.print(" per_dynamic={f}", .{suite.formatDuration(stats.mean_ns / stats.sample_count)});
    if (view == .summary) return;
    try writeCollisionDetails(writer, stats);
}

// ` <label>=<shape>(<batch time>)`, then the stage tuner's state when the case has one.
fn writeStage(writer: *std.Io.Writer, label: []const u8, batch: suite.BatchSummary, tuning: ?suite.WorkTuningSummary) std.Io.Writer.Error!void {
    try writer.print(" {s}=", .{label});
    try suite.writeStageShape(writer, batch);
    try writer.print("({f})", .{suite.formatDuration(batch.batch_duration_ns)});
    if (tuning) |summary| {
        try writer.writeAll("[");
        try suite.writeWorkTuning(writer, summary);
        try writer.writeAll("]");
    }
}

fn writeCollisionDetails(writer: *std.Io.Writer, stats: suite.RunStats) std.Io.Writer.Error!void {
    const stages = stats.collision_stages orelse return;
    try writeStage(writer, "fill", stages.fill, stages.fill_tuning);
    try writeStage(writer, "sort", stages.sort, stages.sort_tuning);
    // The primary batch is the broadphase, its tuner the primary tuning cell.
    try writeStage(writer, "broad", stats.batch, null);
    if (stats.secondary_batch) |narrow| try writeStage(writer, "narrow", narrow, stats.secondary_work_tuning);
    // `sample_count` holds the body (or dynamic) count.
    const bodies = @max(stats.sample_count, 1);
    try writer.print(" entries={} visits_per_body={d:.2}", .{ stages.entries, @as(f64, @floatFromInt(stages.visits)) / @as(f64, @floatFromInt(bodies)) });
    try suite.writeMainShare(writer, stats, bodies);
}
