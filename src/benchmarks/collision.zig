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
//! neighbour pairs; one pair per group of 20 sparse bodies). Every measured step checks the
//! sweep's work: the broadphase over every entry, the narrowphase over every candidate
//! pair, and in a fixed threaded case one broadphase range per aligned range of entries.
//! `collision` also checks the pair-bound flag counts, untimed, on systems apart from the measured one: reserved to a
//! quarter of the grid's bodies, every step on the case's dispatch path is flagged and
//! counted once; and a broadphase slot that outgrows its reserve inside the total bound
//! (a fixed four-range cluster on two workers) flags and counts its replayed step once and
//! the next step not at all.
//!
//! The static groups hold the item count of one-tile statics on a two-tile pitch, so the
//! world grows with the static count, plus a fixed 2,048 dynamic bodies, half of them
//! overlapping one static each and half in the free tiles:
//! - `collision-static-heavy-sap`: the dynamics clustered in a fixed 64 x 64-tile region.
//!   Pass shape: tuned time and main flat in statics.
//! - `collision-static-heavy`: the dynamics spread uniformly over the world. Pass shape:
//!   time per dynamic flat in statics.
//! - `collision-static-index-change`: the clustered fixture; each step moves one static
//!   through the production commit seam (`SimulationPipeline.commitStructuralAndReact` on a
//!   pipeline built over the fixture, nav over a one-level walkable world of the statics'
//!   tiles) and then runs one collision step on the pipeline's collision system. Pass shape:
//!   flat in statics.
//! Asserts check fixture invariants only: the analytic contact count (one per overlapping
//! dynamic) in every static group; sweep `body_count` and `entry_count` follow the dynamic
//! bodies (one strip each on this fixture), not the statics; in `collision-static-index-change`
//! also the collider row count, that each move commits, syncs, and changes chunks, and that
//! the warm syncs grow no collider rows or payloads (each rewrites its two chunks in place).
//! - `collision-static-rebuild`: the clustered fixture's statics rebuilt whole each step
//!   (`StaticColliderSystem.rebuild`, every stage on the case's thread system), each timed
//!   rebuild into a fresh system with fresh rebuild tuners, as a world create's one-off
//!   rebuild runs (nothing settles; the warmup rebuilds warm caches only). Pass shape: time
//!   and main per static flat in statics, and every stage with more than one aligned block
//!   on workers in the tuned case. Asserts: the row count; each stage's work (`select`
//!   every entity slot, `plan` and `touch` every static, `group` one touch per static, a fill
//!   of at least two units per static, and `install` one item per occupied chunk); each
//!   stage dispatched in the fixed-partition cases; in the adaptive threaded cases each
//!   stage's selection through its own rebuild tuner; and in the tuned case with workers
//!   every stage with more than one aligned block on workers.
//! - `collision-static-rebuild-sparse`: the same rebuild on a fixed world of 256 x 256
//!   chunks, one one-tile static at the middle tile of each occupied chunk and no other body;
//!   the item count of chunks is occupied on an even stride (every fourth, second, or each
//!   chunk a side), so every static is its chunk's only record, the worst case for per-chunk
//!   main work. Pass shape: time and main per static flat in statics; a per-level-extent term
//!   shows as an intercept, falling per static as the occupied count grows. Asserts as
//!   `collision-static-rebuild`.
//! - `collision-static-dense-change`: a fixed world of 65,536 statics (the static groups'
//!   grid, 1,024 chunks of 64, no dynamics); each step moves every static of a square region
//!   of chunks whose count grows with the change count (16, 64, 256 chunks), an explosion's
//!   shape, as one structural commit through the commit seam. Moves pair-swap across chunks:
//!   a static in an even chunk column (row) moves ahead one chunk and one tile, one in an odd
//!   column (row) back one chunk less one tile, so every destination is a free tile, no two
//!   coincide, every region chunk gets its own count of inserts in both directions, and the
//!   next step moves each back, each step through the production commit seam on a pipeline
//!   over the world (nav over a one-level walkable world of its tiles). One sample is the
//!   seam's collider sync time (`SimulationPipeline.Perf.seam_collider_sync_ns`: `StaticColliderSystem.sync`
//!   alone), every stage on the case's thread system under its own sync tuner; the tuned
//!   case settles all six first. Pass shape:
//!   main per changed static flat in the change count, the chunks outside the region a
//!   control: a term in the world's chunk count shows as a per-change intercept falling with
//!   the change count. A move is a remove and an insert across chunks, a superset of an
//!   explosion's per-change destroys. Asserts: every move commits, and the sync records one
//!   change per moved static, each leaving its chunk, with the changes touching exactly the
//!   region's chunks; each stage's work (`plan`, `touch`, and `apply` every change, `group`
//!   a removal and an insert touch per change, `install` one item per region chunk); each
//!   stage dispatched in the fixed-partition cases, and in the adaptive threaded cases each
//!   stage's selection through its own sync tuner; and no row or payload growth in any
//!   measured sync (warmup runs both directions). Last, untimed, where the moves are every
//!   static of the region, one commit destroys them: every region chunk empties, and the
//!   sync's fill runs one unit per emptied chunk.
//! - `collision-static-dense-spike`: the dense-change fixture, serial and tuned cases only,
//!   also at 16, 64, and 256 changes: below 256 the changes thin over the 2 x 2-chunk region,
//!   each chunk moving the same first share of its statics.
//!   One untimed dense round trip grows the region chunks first; then fresh sync tuners
//!   settle on single-static syncs (one static outside the region moved through the commit
//!   seam, a quiet world's in-band load), and one untimed spike each way grows the per-range
//!   scratch to the settled tuners' spike shape; each measured step runs one in-band
//!   single-static sync, untimed, then, with the tuners still settled, times one dense sync of
//!   the change count, an explosion after a quiet spell. Pass shape: main per changed static
//!   flat in the change count; in the tuned case each stage's shape the same across the timed
//!   spikes (the held jump shape, shown in the stage details) and the main share reported.
//!   The tuned shapes are learned from timing, so no worker count is asserted.
//!   Asserts are fixture invariants only: each single sync commits and syncs its one change,
//!   and leaves the tuned case's tuners settled; each dense sync's work as
//!   `collision-static-dense-change`, each stage's selection through its own sync tuner, and
//!   no row or payload growth (sync scratch included) in any measured sync after the warmup.
//!
//! `collision-static-triggers` holds the item count of stored trigger pairs: two overlapping
//! one-tile triggers per pitch cell, 512 dynamics on the first cells (half on a trigger), and
//! one dynamic over a 10 x 10-cell square of them. One trigger is kinematic, so exclusion
//! stays on, and another crosses the allow bit before every step, so every step moves the
//! allow epoch and refreshes the stored pairs' rows and emit bits. The system is reserved to
//! the movement bodies first, as the population seam reserves it. Pass shape: time per stored
//! pair flat in pairs (the refresh and the stored-pair emission are linear in them). Asserts:
//! the analytic contact count; every measured step refreshes every stored pair, on workers in
//! a fixed threaded case; one step with no allow crossing refreshes nothing; and the cold step,
//! whose wide dynamic outgrows its static query slot's reserved hit rows while the broadphase
//! stays inside the pair bound, is flagged and counted once. Its dormant variant (item code
//! `1_000_000 + pairs`) makes every eighth trigger dormant (trigger B of each cell 4m + 3), so a
//! quarter of the stored pairs are kept but filtered from the contacts; same pass shape and
//! asserts, the contact count less the dormant pairs and the wide dynamic's dormant hits.
//!
//! The trigger patch groups run each change through the production commit seam on a pipeline
//! over the fixture (nav over a one-level walkable world fixed at the largest size's), on the
//! case's thread system; one sample is the seam's trigger sync time
//! (`SimulationPipeline.Perf.seam_trigger_sync_ns`:
//! `CollisionSystem.syncCommittedTriggers`). The pipeline's init builds the cold store;
//! `reserveFrame` tops up the bound. They assert fixture invariants only, not their pass
//! shapes: the cold store's pair count, that each sync changes exactly the moved statics,
//! that the patch queried only the changes (not a rebuild over the row pool), the stored
//! pair count after every patch, and that after the first, untimed seam and after the last
//! measured seam (each growing the stored-trigger contact bound as needed) a second
//! collision step at the world's strips counts no pair-bound overflow (the first may count
//! a one-off slot growth). They run `serial-direct` and the fixed worker-count cases only,
//! no adaptive case. Each prints `per_change=`, and with
//! `--details` the main share in `serial-direct` only (no worker exists, so the whole
//! sync is main) and, under each row, the query items and the stored pairs.
//! - `collision-static-trigger-change`: the `collision-static-triggers` fixture's stored pairs
//!   in the corner of the largest count's grid, plus one solid alternating between cell 0's
//!   and cell 1's triggers (drops two pairs, adds two; queries the solid's one change).
//!   Pass shape: patch time and main per change flat in stored pairs.
//! - `collision-static-trigger-dense-change`: the `collision-static-dense-change` world and
//!   moves, with every other static (a checkerboard, the last row and column solid) a
//!   trigger reaching half a tile into its neighbours' cells, so each overlaps its right and
//!   lower solids and its diagonal triggers; the home pair count is checked against those
//!   overlaps, the away count against a cold rebuild at the first away revision. Pass shape:
//!   main per changed static flat in the change count. Last, untimed: a collision system one
//!   revision behind the seam, stepped at the case's controls, patches one dense change; its
//!   query covers exactly the changes, each store patch stage runs, the fixed threaded cases
//!   dispatch them all, and the patch leaves the rebuild's stage records.
//! - `collision-static-trigger-wide`: one trigger one chunk row tall and the world wide over
//!   the item count of solids, in eight rows on the two-tile pitch, the world as wide as the
//!   largest count's columns and the solids on a column stride of the largest count over the
//!   item count; the middle solid alternates with its free diagonal tile each step (queries
//!   its one change). Pass shape: flat in the solids under the trigger.
//!
//! Every collision-step group prints `candidate_pairs=` and `contacts=`, the shape groups `per_body=`
//! (mean time per body), the static groups `per_dynamic=` (`collision-static-triggers`
//! `per_pair=`, per stored pair); `--details` adds each stage's
//! shape and batch time, `fill=`, `sort=`, `broad=` (the row's batch, its mean time; the
//! others the last step's), and `narrow=`, with the fill, sort, and narrowphase tuners'
//! state in brackets (each stage tunes on its own; the broadphase's is the row's tuning
//! cell), then `entries=` (sweep entries), `visits_per_body=` (candidates the sweep tested,
//! counted with the perf log only), and `main=` with `main_per_item=` per body: the time
//! outside the stages' worker dispatches. The `--details` line under each row gives the
//! measured steps' static query, Debug rect compare, static sort, and stored-trigger refresh
//! shapes, and in `collision-static-index-change` the collider sync's splice shape and its
//! `row_grows=` and `payload_grows=` counts. `collision-static-rebuild` and
//! `collision-static-rebuild-sparse` print `per_static=`, and with `--details` the rewrite
//! stage and the main share per static (main is elapsed less every stage's worker time), and
//! under each row every stage's shape and mean batch time; `collision-static-dense-change`
//! prints `per_change=`, and with `--details` the rewrite stage (its tuner in the tuned case),
//! the main share per changed static (main is elapsed less every stage's worker time), and
//! under each row every stage's shape and mean batch time and the timed syncs' `row_grows=`
//! and `payload_grows=` counts; `collision-static-dense-spike` prints the same.

const std = @import("std");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const CollisionStats = @import("../game/systems/collision.zig").CollisionStats;
const CollisionStrips = @import("../game/systems/collision.zig").CollisionStrips;
const CollisionSystem = @import("../game/systems/collision.zig").CollisionSystem;
const CollisionConfig = @import("../game/systems/collision.zig").CollisionConfig;
const collision_range_alignment_items = @import("../game/systems/collision.zig").collision_range_alignment_items;
const EntityId = @import("../game/data_system.zig").EntityId;
const CollisionContact = @import("../game/simulation.zig").CollisionContact;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const structuralEventHeadroom = @import("../game/simulation.zig").structuralEventHeadroom;
const StructuralCommand = @import("../game/data_system.zig").StructuralCommand;
const ColliderGeometry = @import("../game/systems/static_colliders.zig").ColliderGeometry;
const ColliderView = @import("../game/systems/static_colliders.zig").ColliderView;
const StaticColliderSystem = @import("../game/systems/static_colliders.zig").StaticColliderSystem;
const RebuildStage = @import("../game/systems/static_colliders.zig").RebuildStage;
const SyncStage = @import("../game/systems/static_colliders.zig").SyncStage;
const splice_range_alignment_items = @import("../game/systems/chunk_list_map.zig").splice_range_alignment_items;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const SimulationPipeline = @import("../game/simulation_pipeline.zig").SimulationPipeline;
const CommitSeamResult = @import("../game/simulation_pipeline.zig").CommitSeamResult;
const tile_size = @import("../assets/world_tileset_meta.zig").required_tile_size;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");
const static_colliders_test_support = @import("../game/systems/static_colliders_test_support.zig");

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
    .describe_item = ShapeCode.describe,
    .item_counts = &tall_item_counts,
    .runCase = runShapeCase,
    .write_workload = writeCollisionWorkload,
};

pub const stacked_group = suite.BenchmarkGroup{
    .name = "collision-stacked",
    .item_label = ShapeCode.label,
    .describe_item = ShapeCode.describe,
    .item_counts = &stacked_item_counts,
    .runCase = runShapeCase,
    .write_workload = writeCollisionWorkload,
};

pub const thin_group = suite.BenchmarkGroup{
    .name = "collision-thin",
    .item_label = ShapeCode.label,
    .describe_item = ShapeCode.describe,
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

pub const static_rebuild_group = suite.BenchmarkGroup{
    .name = "collision-static-rebuild",
    .item_label = "static bodies",
    .item_counts = &static_item_counts,
    .runCase = runStaticRebuildCase,
    .write_workload = writeRebuildWorkload,
};

pub const static_rebuild_sparse_group = suite.BenchmarkGroup{
    .name = "collision-static-rebuild-sparse",
    .item_label = "static bodies (one per chunk)",
    .item_counts = &static_item_counts,
    .runCase = runStaticRebuildSparseCase,
    .write_workload = writeRebuildWorkload,
};

pub const static_dense_change_group = suite.BenchmarkGroup{
    .name = "collision-static-dense-change",
    .item_label = "statics changed in one commit",
    .item_counts = &dense_change_counts,
    .runCase = runStaticDenseChangeCase,
    .write_workload = writeDenseChangeWorkload,
};

pub const static_dense_spike_group = suite.BenchmarkGroup{
    .name = "collision-static-dense-spike",
    .item_label = "statics changed in the spike",
    .item_counts = &dense_spike_counts,
    .runCase = runStaticDenseSpikeCase,
    .write_workload = writeDenseChangeWorkload,
    .cases = &suite.serial_and_tuned_cases,
};

pub const static_triggers_group = suite.BenchmarkGroup{
    .name = "collision-static-triggers",
    .item_label = TriggerCode.label,
    .describe_item = TriggerCode.describe,
    .item_counts = &static_triggers_item_counts,
    .runCase = runStaticTriggersCase,
    .write_workload = writeTriggerWorkload,
};

pub const static_trigger_change_group = suite.BenchmarkGroup{
    .name = "collision-static-trigger-change",
    .item_label = "stored trigger pairs",
    .item_counts = &trigger_pair_counts,
    .runCase = runStaticTriggerChangeCase,
    .write_workload = writeTriggerPatchWorkload,
    .cases = &trigger_patch_cases,
};

pub const static_trigger_dense_change_group = suite.BenchmarkGroup{
    .name = "collision-static-trigger-dense-change",
    .item_label = "statics changed in one commit",
    .item_counts = &dense_change_counts,
    .runCase = runStaticTriggerDenseChangeCase,
    .write_workload = writeTriggerPatchWorkload,
    .cases = &trigger_patch_cases,
};

pub const static_trigger_wide_group = suite.BenchmarkGroup{
    .name = "collision-static-trigger-wide",
    .item_label = "statics under the wide trigger",
    .item_counts = &trigger_wide_counts,
    .runCase = runStaticTriggerWideCase,
    .write_workload = writeTriggerPatchWorkload,
    .cases = &trigger_patch_cases,
};

// Fixed worker-count cases only: the warmup does not settle the patch stages' tuners.
const trigger_patch_cases = suite.casesNamed(&.{ "serial-direct", "thread-fixed-1", "thread-fixed-2", "thread-fixed-auto" });

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

fn createFixture(allocator: std.mem.Allocator, count: usize) !DataSystem {
    return createFixtureWithMode(allocator, count, .dense);
}

fn createFixtureWithMode(allocator: std.mem.Allocator, count: usize, mode: FixtureMode) !DataSystem {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const columns: usize = 512;
    for (0..count) |index| _ = try addDenseBody(&data, benchmarkPosition(index, columns, mode));

    return data;
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .dense);
}

fn runSparseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithMode(allocator, io, options, case, item_count, .sparse);
}

fn runShapeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const shape = try gridShapeFor(item_count);
    var data = try createGridFixture(allocator, shape);
    defer data.deinit();
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var stats = try measureCase(allocator, io, options, case, shape.bodies(), &data, &threads, .{});
    std.debug.assert(stats.output_count == shape.contacts());
    const stages = stats.collision_stages.?;
    if (stages.entries > shape.bodies() * denseStripsPerBodyBound()) return error.CollisionEntriesPastStripBound;
    if (stages.visits > stages.entries * denseVisitsPerEntryBound()) return error.CollisionVisitsPastStripBound;
    // The header names the config; throughput stays per body.
    stats.item_count = item_count;
    return stats;
}

fn runCaseWithMode(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, mode: FixtureMode) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var data = try createFixtureWithMode(allocator, item_count, mode);
    defer data.deinit();
    if (mode == .dense) try checkPairBoundFlags(allocator, io, case, &data);
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const stats = try measureCase(allocator, io, options, case, item_count, &data, &threads, .{});
    if (stats.iterations > 0 and stats.output_count != fixtureContacts(item_count, mode)) return error.CollisionContactCountMismatch;
    // A dense strip's rows overlap in x past one lane group, so the sweep runs its lanes.
    if (mode == .dense and stats.iterations > 0 and stats.collision_stages.?.simd_groups == 0) return error.CollisionSweepRanNoLanes;
    return stats;
}

// The pair-bound flag counts, untimed, on systems apart from the measured one. Through the
// case's thread system and controls, a reserve to a quarter of the dense grid's bodies sits
// below its candidates: every step is flagged and counted once. Then a broadphase slot that
// outgrows its reserve inside the total bound flags its step (`checkSlotReplayFlag`).
fn checkPairBoundFlags(allocator: std.mem.Allocator, io: std.Io, case: suite.BenchmarkCase, data: *DataSystem) !void {
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var system = CollisionSystem.init(allocator);
    defer system.deinit();
    useCaseTuners(&system, case);
    const bodies = data.movementBodySliceConst().entities.len;
    try system.reserve(@max(bodies / 4, 1));
    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    defer contacts.deinit();
    const config: CollisionConfig = .{
        .items_per_range = case.stageItemsPerRange(collision_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    };
    for (0..3) |step| {
        const stats = try system.update(data, &contacts, &threads, config);
        if (stats.candidate_pair_count <= system.reserved_pair_bound) return error.CollisionBoundFixtureInsideBound;
        if (!stats.perf.pair_bound_exceeded or system.perf.pair_bound_overflows != step + 1) return error.CollisionPastBoundStepNotFlagged;
    }
    try checkSlotReplayFlag(allocator, io);
}

// A body with `box`'s bounds and no collision response.
fn addBoxBody(data: *DataSystem, x: f32, y: f32, w: f32, h: f32) !void {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = y }, .previous_position = .{ .x = x, .y = y } });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = w, .y = h } });
}

// 64 bodies at a 64-body reserve (256-pair bound, 128-entry bound), four broadphase ranges
// of 16 entries: slot 2 holds 4 * ceil(128 / 3) = 172 pairs. Ranges 0 and 1 are 32
// isolated bodies; range 2 is 16 wide bodies that all overlap (120 pairs) and the four
// narrow bodies of range 3 they cover in y (64 pairs): 184, past slot 2 but inside the
// total bound. The slot grows and the broadphase replays: one flagged, counted step. The
// grown slot then holds the cluster, so the next step is not flagged. The four ranges run on
// two workers of its own thread system, whatever the case's.
fn checkSlotReplayFlag(allocator: std.mem.Allocator, io: std.Io) !void {
    var threads = try ThreadSystem.init(allocator, io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    const body_count: usize = 64;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    for (0..32) |index| try addBoxBody(&data, @floatFromInt(index * 100), 0, 22, 8);
    for (0..16) |index| try addBoxBody(&data, 10_000 + @as(f32, @floatFromInt(index)), 0, 1000, 8);
    for (0..16) |index| try addBoxBody(&data, 10_100 + @as(f32, @floatFromInt(index * 50)), if (index < 4) 4 else 10, 8, 8);
    var system = CollisionSystem.init(allocator);
    defer system.deinit();
    try system.reserve(body_count);
    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    defer contacts.deinit();
    try CollisionSystem.reserveContactStream(&contacts, CollisionSystem.estimateContactCapacity(body_count));
    const config: CollisionConfig = .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false };
    const replayed = try system.update(&data, &contacts, &threads, config);
    if (replayed.candidate_pair_count != 120 + 64 or replayed.candidate_pair_count > system.reserved_pair_bound) return error.CollisionReplayFixtureMismatch;
    if (replayed.perf.broadphase_batch.range_count != 4 or replayed.perf.broadphase_batch.ran_inline) return error.CollisionReplayFixtureMismatch;
    if (!replayed.perf.pair_bound_exceeded or system.perf.pair_bound_overflows != 1) return error.CollisionSlotReplayNotFlagged;
    const settled = try system.update(&data, &contacts, &threads, config);
    if (settled.perf.pair_bound_exceeded or system.perf.pair_bound_overflows != 1) return error.CollisionGrownSlotFlagged;
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
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var mover: ?StaticMover = if (move_static) try StaticMover.init(allocator, io, &fixture, case, &threads) else null;
    defer if (mover) |*static_mover| static_mover.deinit();
    var colliders = StaticColliderSystem.init(allocator);
    defer colliders.deinit();
    if (!move_static) {
        // The fixture's two-tile pitch grid side fits u32.
        const cells: u32 = @intCast(2 * fixture.side);
        try colliders.rebuild(&fixture.data, ColliderGeometry.init(tile_size, cells, cells, default_chunk_size_tiles), null);
    }

    var stats = try measureCase(allocator, io, options, case, static_dynamic_count, &fixture.data, &threads, .{
        .mover = if (mover) |*static_mover| static_mover else null,
        .colliders = if (move_static) null else &colliders,
        .swept_bodies = static_dynamic_count,
        .one_strip_per_body = true,
    });
    std.debug.assert(stats.output_count == static_fixture_contacts);
    // The header names the static count; throughput and `per_dynamic=` stay per dynamic.
    stats.item_count = static_count;
    return stats;
}

// ----------------------------------------------------------------------------
// Static triggers: stored trigger pairs refreshed to the allow epoch every step.
// ----------------------------------------------------------------------------

const trigger_pair_counts = [_]usize{ 1_024, 4_096, 16_384 };
// `collision-static-triggers`' configs: the stored pair count, and whether every eighth
// trigger is dormant. The all-allowed configs' codes are their pair counts.
const TriggerCode = suite.ItemCode(struct { every_eighth_trigger_dormant: bool, stored_trigger_pairs: u32 }, &.{6});
const static_triggers_item_counts = blk: {
    var codes: [2 * trigger_pair_counts.len]usize = undefined;
    for (trigger_pair_counts, 0..) |pairs, index| {
        codes[index] = TriggerCode.of(.{ .every_eighth_trigger_dormant = false, .stored_trigger_pairs = pairs });
        codes[trigger_pair_counts.len + index] = TriggerCode.of(.{ .every_eighth_trigger_dormant = true, .stored_trigger_pairs = pairs });
    }
    break :blk codes;
};
const trigger_dynamic_count: usize = 512;
// Trigger B sits half a tile down and right of trigger A in its pitch cell: one stored pair
// per cell, clear of the next cell (B ends at 48 of the 64-unit pitch).
const trigger_pair_offset: f32 = tile_size / 2;
// Dynamic slot 1 sits past trigger B in its cell and overlaps nothing.
const trigger_free_slot_offset: f32 = tile_size + trigger_pair_offset + 2;
// The wide dynamic covers a square of this many pitch cells a side, both triggers of each.
const trigger_wide_cells: usize = 10;
// In the dormant variant, every eighth trigger in creation order is dormant: trigger B of
// each cell 4m + 3, so its cell's stored pair is kept and filtered from the contacts.
const trigger_dormant_cell_stride: usize = 4;
const trigger_dormant_cell: usize = 3;

// One trigger whose tier crosses the allow bit each step, so every step moves the collision
// allow epoch and refreshes the stored pairs' rows and emit bits.
const AllowToggle = struct {
    entity: EntityId,
    // The fixture's stored pairs, which every refresh covers.
    stored_pairs: usize,
    excluded: bool = false,

    fn flip(self: *AllowToggle, data: *DataSystem) !void {
        self.excluded = !self.excluded;
        try data.setSimulationTier(self.entity, if (self.excluded) .kinematic else .cognition);
    }
};

const TriggerFixture = struct {
    data: DataSystem,
    side: usize,
    toggle: AllowToggle,
    // Dormant triggers: every one's stored pair, and those under the wide dynamic.
    dormant_pairs: usize = 0,
    dormant_wide: usize = 0,

    // The kinematic trigger's pair, the toggled trigger's pair while it is excluded, and the
    // dormant triggers' pairs are filtered; every slot-0 dynamic is on its cell's trigger A,
    // and the wide dynamic on both triggers of its cells less the dormant ones.
    fn contacts(self: *const TriggerFixture) usize {
        const pairs = self.toggle.stored_pairs - 1 - @intFromBool(self.toggle.excluded) - self.dormant_pairs;
        return pairs + trigger_dynamic_count / 2 + 2 * trigger_wide_cells * trigger_wide_cells - self.dormant_wide;
    }
};

fn addTrigger(data: *DataSystem, position: math.Vec2, size: math.Vec2) !EntityId {
    const entity = try fixtures.addBody(data, position, size, .static);
    try data.setCollisionResponse(entity, .{ .mobility = .static, .mode = .trigger });
    return entity;
}

fn triggerCellDormant(cell: usize, dormant_eighth: bool) bool {
    return dormant_eighth and cell % trigger_dormant_cell_stride == trigger_dormant_cell;
}

// `pair_count` cells row-major on the pitch grid, two overlapping triggers each. Cell 0's
// trigger B is kinematic, so exclusion stays on; cell 1's is the toggle; with
// `dormant_eighth`, trigger B of each cell 4m + 3 is dormant. The dynamics fill the first
// cells, dynamic k in slot k % 2 of cell k / 2, and one wide dynamic covers the grid's last
// `trigger_wide_cells` square.
fn createTriggerFixture(allocator: std.mem.Allocator, pair_count: usize, dormant_eighth: bool) !TriggerFixture {
    const side = std.math.sqrt(pair_count);
    if (side * side != pair_count) return error.TriggerPairCountNotSquare;
    if (trigger_dynamic_count / 2 + trigger_wide_cells * side > pair_count) return error.TriggerGridTooSmall;
    comptime std.debug.assert(!triggerCellDormant(0, true) and !triggerCellDormant(1, true));
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const trigger_size = math.Vec2{ .x = static_size, .y = static_size };
    var toggled = EntityId.invalid;
    var dormant_pairs: usize = 0;
    var dormant_wide: usize = 0;
    for (0..side) |cell_y| for (0..side) |cell_x| {
        const origin = pitchCellOrigin(cell_x, cell_y);
        _ = try addTrigger(&data, origin, trigger_size);
        const b = try addTrigger(&data, .{ .x = origin.x + trigger_pair_offset, .y = origin.y + trigger_pair_offset }, trigger_size);
        const cell = cell_y * side + cell_x;
        if (cell == 0) try data.setSimulationTier(b, .kinematic);
        if (cell == 1) toggled = b;
        if (triggerCellDormant(cell, dormant_eighth)) {
            try data.setSimulationTier(b, .dormant);
            dormant_pairs += 1;
            if (cell_x >= side - trigger_wide_cells and cell_y >= side - trigger_wide_cells) dormant_wide += 1;
        }
    };
    if (dormant_eighth and dormant_pairs != pair_count / trigger_dormant_cell_stride) return error.TriggerDormantCountMismatch;
    for (0..trigger_dynamic_count) |index| {
        const cell = index / 2;
        const origin = pitchCellOrigin(cell % side, cell / side);
        const offset: f32 = if (index % 2 == 0) 2 else trigger_free_slot_offset;
        _ = try fixtures.addBody(&data, .{ .x = origin.x + offset, .y = origin.y + offset }, .{ .x = dense_body_size, .y = dense_body_size }, .dynamic);
    }
    const corner = pitchCellOrigin(side - trigger_wide_cells, side - trigger_wide_cells);
    const wide = @as(f32, @floatFromInt(trigger_wide_cells)) * static_pitch - 2;
    _ = try fixtures.addBody(&data, .{ .x = corner.x + 1, .y = corner.y + 1 }, .{ .x = wide, .y = wide }, .dynamic);
    return .{
        .data = data,
        .side = side,
        .toggle = .{ .entity = toggled, .stored_pairs = pair_count },
        .dormant_pairs = dormant_pairs,
        .dormant_wide = dormant_wide,
    };
}

fn runStaticTriggersCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try TriggerCode.decode(item_count);
    const pair_count: usize = config.stored_trigger_pairs;
    var fixture = try createTriggerFixture(allocator, pair_count, config.every_eighth_trigger_dormant);
    defer fixture.data.deinit();
    var colliders = StaticColliderSystem.init(allocator);
    defer colliders.deinit();
    // The fixture's two-tile pitch grid side fits u32.
    const cells: u32 = @intCast(2 * fixture.side);
    try colliders.rebuild(&fixture.data, ColliderGeometry.init(tile_size, cells, cells, default_chunk_size_tiles), null);
    if (static_colliders_test_support.liveRowCount(colliders) != 2 * pair_count) return error.WrongStaticCount;

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var stats = try measureCase(allocator, io, options, case, pair_count, &fixture.data, &threads, .{
        .colliders = &colliders,
        .toggle = &fixture.toggle,
        .reserved_cold_growth = true,
        .swept_bodies = trigger_dynamic_count + 1,
    });
    if (stats.iterations > 0 and stats.output_count != fixture.contacts()) return error.CollisionContactCountMismatch;
    // The header names the config; throughput and `per_pair=` stay per stored pair.
    stats.item_count = item_count;
    return stats;
}

// ----------------------------------------------------------------------------
// Static trigger patches: statics moved through the production commit seam, which brings the
// stored trigger pairs up to the synced colliders (`CollisionSystem.syncCommittedTriggers`);
// the seam's trigger sync time (`SimulationPipeline.Perf.seam_trigger_sync_ns`) is the sample.
// ----------------------------------------------------------------------------

// A solid's offset in its pitch cell: it overlaps both of the cell's triggers.
const trigger_change_solid_offset: f32 = tile_size / 4;
// The change group's fixed world in tiles a side: the largest count's pitch grid, every
// count's grid in its corner.
const trigger_change_cells: u32 = 2 * std.math.sqrt(trigger_pair_counts[trigger_pair_counts.len - 1]);
const trigger_wide_counts = [_]usize{ 256, 1_024, 4_096 };
// Static rows under the wide trigger: one chunk row of tiles on the two-tile pitch.
const trigger_wide_rows: usize = default_chunk_size_tiles / 2;
// The wide group's fixed world width: the largest count's columns on the two-tile pitch.
const trigger_wide_max_columns: usize = trigger_wide_counts[trigger_wide_counts.len - 1] / trigger_wide_rows;
const trigger_wide_tiles_x: usize = 2 * trigger_wide_max_columns;

// One timed trigger sync: its time and the items its patch query ran over.
const TriggerPatch = struct {
    ns: u64,
    query_items: usize,
};

// The timed syncs of one case. Main time is known only on a thread system with no
// workers, where the whole sync runs on main.
const TriggerPatchSamples = struct {
    accumulator: suite.StatsAccumulator,
    last_query_items: ?usize = null,

    fn init(item_count: usize) TriggerPatchSamples {
        return .{ .accumulator = suite.StatsAccumulator.init(item_count) };
    }

    fn record(self: *TriggerPatchSamples, patch: TriggerPatch) void {
        self.accumulator.record(patch.ns, .{});
        self.last_query_items = patch.query_items;
    }

    // `changes` is the statics changed per patch (`per_change=`), `stored_pairs` the last
    // patch's.
    fn finish(self: *const TriggerPatchSamples, threads: *const ThreadSystem, changes: usize, stored_pairs: usize) suite.RunStats {
        var stats = self.accumulator.finish();
        stats.batch_carried = false;
        stats.sample_count = changes;
        if (threads.workerThreadCount() == 0 and stats.iterations > 0) stats.main_ns = stats.mean_ns;
        if (self.last_query_items) |items| stats.details.print("query_items={} stored_pairs={}\n", .{ items, stored_pairs });
        return stats;
    }
};

// What one moved static's patch must show: the colliders' rows, the stored pairs after
// every patch (the cold rebuild's too), and the patch's query items.
const TriggerPatchShape = struct {
    static_count: usize,
    stored_pairs: usize,
    query_items: usize,
};

fn runStaticTriggerChangeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, pair_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var fixture = try createTriggerFixture(allocator, pair_count, false);
    defer fixture.data.deinit();
    // One solid alternating between cell 0's and cell 1's triggers: each move drops two
    // stored pairs and adds two.
    const home = pitchCellOrigin(0, 0);
    const away = pitchCellOrigin(1, 0);
    const offset = trigger_change_solid_offset;
    const solid = try fixtures.addBody(&fixture.data, .{ .x = home.x + offset, .y = home.y + offset }, .{ .x = static_size, .y = static_size }, .static);
    var move = fixtures.StaticMove{ .entity = solid, .positions = .{ .{ .x = home.x + offset, .y = home.y + offset }, .{ .x = away.x + offset, .y = away.y + offset } } };
    var stats = try measureTriggerPatches(allocator, io, options, case, &fixture.data, .{ trigger_change_cells, trigger_change_cells }, &move, .{
        .static_count = 2 * pair_count + 1,
        .stored_pairs = pair_count + 2,
        // The moved solid's change.
        .query_items = 1,
    });
    stats.item_count = pair_count;
    return stats;
}

fn runStaticTriggerWideCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, static_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    if (static_count % trigger_wide_rows != 0) return error.TriggerWideCountNotPerRow;
    const columns = static_count / trigger_wide_rows;
    if (columns == 0 or trigger_wide_max_columns % columns != 0) return error.TriggerWideCountNotStride;
    // Fewer solids spread over the fixed world on a wider column stride.
    const column_stride = trigger_wide_max_columns / columns;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    // The trigger covers the whole world: one chunk row tall, every static under it.
    _ = try addTrigger(&data, .{ .x = 0, .y = 0 }, .{
        .x = @as(f32, @floatFromInt(trigger_wide_tiles_x)) * tile_size,
        .y = @as(f32, @floatFromInt(default_chunk_size_tiles)) * tile_size,
    });
    var move: ?fixtures.StaticMove = null;
    for (0..trigger_wide_rows) |cell_y| for (0..columns) |column| {
        const cell_x = column * column_stride;
        const home = pitchCellOrigin(cell_x, cell_y);
        const entity = try fixtures.addBody(&data, home, .{ .x = static_size, .y = static_size }, .static);
        // The middle static alternates with the free tile diagonal to it, still under the
        // trigger.
        if (column == columns / 2 and cell_y == trigger_wide_rows / 2) move = .{ .entity = entity, .positions = .{ home, .{ .x = home.x + tile_size, .y = home.y + tile_size } } };
    };
    var moved = move orelse return error.TriggerWideMissingMove;
    // The largest count's world width and one chunk row fit u32.
    var stats = try measureTriggerPatches(allocator, io, options, case, &data, .{ @intCast(trigger_wide_tiles_x), default_chunk_size_tiles }, &moved, .{
        .static_count = static_count + 1,
        .stored_pairs = static_count,
        // The moved static's change.
        .query_items = 1,
    });
    stats.item_count = static_count;
    return stats;
}

// Builds the pipeline over a `cells` world, whose init builds the cold trigger store (a
// rebuild over every row; `reserveFrame` tops up the stored-trigger contact bound), then
// moves `move`'s static through the production commit seam each step; the sample is each
// seam's trigger sync. After the first seam and after the last measured seam, one collision
// step emits the stored pairs with no pair-bound overflow.
fn measureTriggerPatches(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, data: *DataSystem, cells: [2]u32, move: *fixtures.StaticMove, shape: TriggerPatchShape) !suite.RunStats {
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var seam = try StaticSeam.init(allocator, io, data, cells[0], cells[1], fixtures.StaticMove.structural_headroom, case, &threads);
    defer seam.deinit();
    if (static_colliders_test_support.liveRowCount(seam.colliders().*) != shape.static_count) return error.WrongStaticCount;
    // Untimed: the first seam, with the cold store built at init.
    _ = try seam.commit(data, &.{}, &threads);
    const system = &seam.pipeline().collision;
    if (system.trigger_store.pair_count != shape.stored_pairs) return error.TriggerPairCountMismatch;
    try seam.checkStoredPairsInBound(data, &threads, case);

    // Fixed worker-count cases only, so nothing settles; two steps run both directions.
    var warm = suite.Warmup.init(options, case, 2);
    while (warm.next(true)) _ = try patchMovedStatic(&seam, data, move, &threads, shape);
    var samples = TriggerPatchSamples.init(shape.stored_pairs);
    for (0..options.iterations) |_| samples.record(try patchMovedStatic(&seam, data, move, &threads, shape));
    try seam.checkStoredPairsInBound(data, &threads, case);
    return samples.finish(&threads, 1, shape.stored_pairs);
}

// One move through the production commit seam, whose trigger sync is the sample: the sync
// changes only the moved static, and the warm patch queries the shape's items and keeps its
// pair count.
fn patchMovedStatic(seam: *StaticSeam, data: *DataSystem, move: *fixtures.StaticMove, threads: *ThreadSystem, shape: TriggerPatchShape) !TriggerPatch {
    const commit = try seam.commit(data, &.{move.command()}, threads);
    if (commit.structural.components_set != 1) return error.StaticMoveNotApplied;
    const changes = seam.colliders().changesThisStep();
    if (changes.len != 1 or !changes[0].entity.eql(move.entity)) return error.StaticChangeNotSynced;
    move.advance();
    const patch = try seam.triggerPatch();
    if (patch.query_items != shape.query_items) return error.TriggerPatchMissedQuery;
    if (seam.pipeline().collision.trigger_store.pair_count != shape.stored_pairs) return error.TriggerPairCountMismatch;
    return patch;
}

fn writeTriggerPatchWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    // `sample_count` holds the statics changed per patch.
    const changes = @max(stats.sample_count, 1);
    try writer.print("per_change={f}", .{suite.formatDuration(stats.mean_ns / changes)});
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, changes);
}

// ----------------------------------------------------------------------------
// Static rebuild: the whole collider structure built from the static-heavy fixture
// (`SimulationPipeline.init`): each timed rebuild fills a fresh system with fresh rebuild
// tuners, as a world create's rebuild does, and its teardown runs outside the window.
// ----------------------------------------------------------------------------

fn runStaticRebuildCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, static_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var fixture = try createStaticHeavyFixture(allocator, static_count, .clustered);
    defer fixture.data.deinit();
    // The fixture's two-tile pitch grid side fits u32.
    const cells: u32 = @intCast(2 * fixture.side);
    const geometry = ColliderGeometry.init(tile_size, cells, cells, default_chunk_size_tiles);
    // Pitch cells per chunk side: the occupied chunks.
    const chunks_side = std.math.divCeil(usize, fixture.side, default_chunk_size_tiles / 2) catch unreachable; // lint:allow catch-unreachable: the chunk edge is a nonzero constant
    return measureRebuild(allocator, io, options, case, &fixture.data, geometry, static_count, chunks_side * chunks_side);
}

// The sparse rebuild's fixed world: chunks a side, whatever the occupied count.
const sparse_world_chunks_side: usize = 256;

// One one-tile static at the middle tile of `static_count` chunks of the fixed world, a
// square on an even stride, and nothing else: every static is its chunk's only record.
fn runStaticRebuildSparseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, static_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const side = std.math.sqrt(static_count);
    if (side * side != static_count) return error.SparseChunkCountNotSquare;
    if (side == 0 or sparse_world_chunks_side % side != 0) return error.SparseChunkCountNotStride;
    const stride = sparse_world_chunks_side / side;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const middle = default_chunk_size_tiles / 2;
    for (0..side) |row| for (0..side) |column| {
        const tile_x = column * stride * default_chunk_size_tiles + middle;
        const tile_y = row * stride * default_chunk_size_tiles + middle;
        const position = math.Vec2{ .x = @as(f32, @floatFromInt(tile_x)) * tile_size, .y = @as(f32, @floatFromInt(tile_y)) * tile_size };
        _ = try fixtures.addBody(&data, position, .{ .x = static_size, .y = static_size }, .static);
    };
    // The sparse world's tile side fits u32.
    const cells: u32 = @intCast(sparse_world_chunks_side * default_chunk_size_tiles);
    const geometry = ColliderGeometry.init(tile_size, cells, cells, default_chunk_size_tiles);
    return measureRebuild(allocator, io, options, case, &data, geometry, static_count, static_count);
}

// A rebuild's stages in dispatch order.
const rebuild_stages = [_]RebuildStage{ .select, .plan, .touch, .group, .rewrite, .install };

// Times `rebuild` of `data`'s `static_count` one-tile statics on `geometry`, occupying
// `chunk_count` chunks, each timed rebuild into a fresh system with fresh rebuild tuners.
fn measureRebuild(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, data: *const DataSystem, geometry: ColliderGeometry, static_count: usize, chunk_count: usize) !suite.RunStats {
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    // Every rebuild is a world create's one-off on untrained tuners, so nothing settles;
    // the warmup rebuilds warm the caches and the allocator only.
    var warm = suite.Warmup.custom(case, options.warmup_iterations, 0);
    while (warm.next(true)) {
        var colliders = freshRebuildSystem(allocator, case);
        defer colliders.deinit();
        try colliders.rebuild(data, geometry, &threads);
    }

    var accumulator = suite.StatsAccumulator.init(static_count);
    var main_total: u128 = 0;
    var stage_shapes = suite.StageShapes(rebuild_stages.len){};
    var stage_ns: [rebuild_stages.len]u128 = @splat(0);
    const stage_range = case.stageItemsPerRange(splice_range_alignment_items);
    // The last timed rebuild's rewrite tuner, for the tuned case's tuning summary.
    var rewrite_tuner: ?AdaptiveWorkTuner = null;
    for (0..options.iterations) |_| {
        var colliders = freshRebuildSystem(allocator, case);
        defer colliders.deinit();
        const start_ns = suite.nowNs(io);
        try colliders.rebuild(data, geometry, &threads);
        const end_ns = suite.nowNs(io);
        const tuners = &colliders.rebuild_tuners;
        rewrite_tuner = tuners.get(.rewrite);
        if (static_colliders_test_support.liveRowCount(colliders) != static_count) return error.WrongStaticCount;
        var batches: [rebuild_stages.len]BatchStats = undefined;
        for (&batches, rebuild_stages) |*batch, stage| batch.* = colliders.perf.last_batches.get(static_colliders_test_support.colliderStage(stage));
        try suite.checkRebuildWork(batches, data.slots.items.len, static_count, chunk_count);
        try suite.checkStagesDispatched(case, &threads, stage_range, &batches);
        for (batches, rebuild_stages) |batch, stage| try checkTunerSelected(case, &threads, tuners.getPtrConst(stage), batch);
        for (batches) |batch| try suite.checkRebuildOnWorkers(case, &threads, batch);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, colliders.perf.last_batches.get(.rewrite));
        main_total += elapsed_ns -| static_colliders_test_support.lastOffMainNs(colliders);
        stage_shapes.add(batches);
        for (&stage_ns, batches) |*total, batch| total.* += batch.batch_duration_ns;
    }
    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.sample_count = static_count;
    if (case.adaptive) {
        if (rewrite_tuner) |*tuner| stats.work_tuning = suite.workTuningSummary(suite.tunerReport(tuner), false);
    }
    printStageDetails(&stats, &rebuild_stages, &stage_shapes, &stage_ns);
    return stats;
}

// Each stage's busiest shape and mean batch time over the measured calls, on one line.
fn printStageDetails(stats: *suite.RunStats, stages: anytype, shapes: anytype, stage_ns: anytype) void {
    var label_buffer: [48]u8 = undefined;
    for (stages, 0..) |stage, index| {
        const mean_ns: u64 = if (stats.iterations > 0) @intCast(stage_ns[index] / stats.iterations) else 0;
        stats.details.print("{s}={s}({f}) ", .{ @tagName(stage), shapes.label(index, &label_buffer), suite.formatDuration(mean_ns) });
    }
    stats.details.print("\n", .{});
}

// An adaptive case's rebuild or sync stage, whenever the case allows a worker, selects its
// shape through its own tuner at the stage's items.
fn checkTunerSelected(case: suite.BenchmarkCase, threads: *const ThreadSystem, tuner: *const AdaptiveWorkTuner, batch: BatchStats) error{ColliderStageSkippedItsTuner}!void {
    if (!case.adaptive or batch.item_count == 0 or threads.workerThreadCount() == 0 or case.maxWorkerThreads() == @as(?usize, 0)) return;
    const request = tuner.last_request orelse return error.ColliderStageSkippedItsTuner;
    if (request.item_count != batch.item_count) return error.ColliderStageSkippedItsTuner;
}

// An empty collider system with the case's stage controls and fresh tuners, as a new
// world's is.
fn freshRebuildSystem(allocator: std.mem.Allocator, case: suite.BenchmarkCase) StaticColliderSystem {
    var colliders = StaticColliderSystem.init(allocator);
    fixtures.setSpliceTuners(&colliders, case);
    return colliders;
}

fn writeRebuildWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    // `sample_count` holds the static count.
    const statics = @max(stats.sample_count, 1);
    try writer.print("per_static={f}", .{suite.formatDuration(stats.mean_ns / statics)});
    if (view == .summary) return;
    try writeStage(writer, "rewrite", stats.batch, stats.work_tuning);
    try suite.writeMainShare(writer, stats, statics);
}

// ----------------------------------------------------------------------------
// Static dense change: one structural commit moves many statics across chunks, and the
// commit seam's collider sync applies them.
// ----------------------------------------------------------------------------

const dense_change_counts = [_]usize{ 1_024, 4_096, 16_384 };
// The spike also runs small changes (a room's worth), which thin over the 2 x 2-chunk region.
const dense_spike_counts = [_]usize{ 16, 64, 128, 256 } ++ dense_change_counts;
// The fixed world: the static grid's side in pitch cells (65,536 statics on 1,024 chunks of
// 64 each), whatever the change count.
const dense_change_side: usize = 256;
// Pitch cells per chunk side, and chunks per world side.
const dense_change_chunk_cells: usize = default_chunk_size_tiles / 2;
const dense_change_chunks_side: usize = dense_change_side / dense_change_chunk_cells;
// Every static of a region chunk changes: the region grows with the change count at this
// fixed density. Below the smallest paired region's statics, that region's chunks each change
// the same share of theirs.
const dense_change_per_chunk: usize = dense_change_chunk_cells * dense_change_chunk_cells;
// A move's offset in tiles on each axis, by its chunk's parity there: an even chunk's
// statics move ahead into the next chunk, an odd chunk's back into the previous one. From
// any tile of its chunk each lands in its partner chunk, and statics sit on even tiles, so
// an odd offset lands on a free tile; the two ranges never meet, so no two destinations
// coincide.
const dense_change_ahead_tiles: usize = default_chunk_size_tiles + 1;
const dense_change_back_tiles: usize = default_chunk_size_tiles - 1;
comptime {
    std.debug.assert(dense_change_ahead_tiles % 2 == 1 and dense_change_back_tiles % 2 == 1);
}

// The dense-change world's statics: all solid, or every other one (a checkerboard) a trigger.
const DenseStatics = enum { solid, checkered_triggers };
// A checkered trigger covers its pitch cell and half a tile past it, so it overlaps the
// solids right of and below it and the triggers diagonal to it; a moved static lands in the
// reach of the triggers around its free tile.
const dense_trigger_size: f32 = static_pitch + static_size / 2;

// Checkered triggers sit on even cells; the last row and column stay solid, so no trigger
// reaches past the world.
fn denseCellTrigger(statics: DenseStatics, cell_x: usize, cell_y: usize) bool {
    if (statics != .checkered_triggers) return false;
    return (cell_x + cell_y) % 2 == 0 and cell_x + 1 < dense_change_side and cell_y + 1 < dense_change_side;
}

fn denseHomeRect(statics: DenseStatics, cell_x: usize, cell_y: usize) math.Aabb {
    const origin = pitchCellOrigin(cell_x, cell_y);
    const size: f32 = if (denseCellTrigger(statics, cell_x, cell_y)) dense_trigger_size else static_size;
    return .{ .min_x = origin.x, .min_y = origin.y, .max_x = origin.x + size, .max_y = origin.y + size };
}

// The stored trigger pairs with every static home: each pair of neighbouring cells, one
// a trigger, whose rects overlap. Footprints reach only the next cell, so the right, down,
// and both diagonal neighbours visit each such pair once.
fn denseHomeTriggerPairs(statics: DenseStatics) usize {
    const neighbours = [_][2]isize{ .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 1, -1 } };
    var pairs: usize = 0;
    for (0..dense_change_side) |cell_y| for (0..dense_change_side) |cell_x| {
        const rect = denseHomeRect(statics, cell_x, cell_y);
        const trigger = denseCellTrigger(statics, cell_x, cell_y);
        for (neighbours) |step| {
            const x = @as(isize, @intCast(cell_x)) + step[0];
            const y = @as(isize, @intCast(cell_y)) + step[1];
            if (x < 0 or y < 0 or x >= dense_change_side or y >= dense_change_side) continue;
            // In range by the check above.
            const other_x: usize = @intCast(x);
            const other_y: usize = @intCast(y);
            if (!trigger and !denseCellTrigger(statics, other_x, other_y)) continue;
            const other = denseHomeRect(statics, other_x, other_y);
            if (rect.min_x < other.max_x and other.min_x < rect.max_x and rect.min_y < other.max_y and other.min_y < rect.max_y) pairs += 1;
        }
    };
    return pairs;
}

const DenseChangeFixture = struct {
    data: DataSystem,
    // The production commit seam every change commits through.
    seam: StaticSeam,
    // The changed statics, each moved between its home tile and its away tile every step.
    moves: []fixtures.StaticMove,
    // The world's last static, outside the region, moved alone by `changeOneAndSync`.
    single: fixtures.StaticMove,
    commands: []StructuralCommand,
    // Chunks a side of the changed region, from the world's first chunk.
    region_side: usize,
    // One bit per world chunk, set where a step's changes touch it (fixture check scratch).
    touched: std.DynamicBitSetUnmanaged,
    allocator: std.mem.Allocator,

    // Every static of a square region of `change_count / dense_change_per_chunk` chunks
    // changes; the region has an even side, so each chunk's pair-swap partner is in it. A
    // smaller count changes the first `change_count / 4` statics of each 2 x 2-region chunk.
    fn init(allocator: std.mem.Allocator, io: std.Io, change_count: usize, case: suite.BenchmarkCase, statics: DenseStatics, threads: *ThreadSystem) !DenseChangeFixture {
        const region_chunks = @max(change_count / dense_change_per_chunk, 4);
        const moves_per_chunk = change_count / region_chunks;
        if (moves_per_chunk == 0 or moves_per_chunk > dense_change_per_chunk or moves_per_chunk * region_chunks != change_count) return error.DenseChangeNotPerChunk;
        const region_side = std.math.sqrt(region_chunks);
        if (region_side * region_side != region_chunks) return error.DenseChangeRegionNotSquare;
        if (region_side % 2 != 0 or region_side > dense_change_chunks_side) return error.DenseChangeRegionNotPaired;
        // The single move's last chunk and its partner stay outside the region.
        if (region_side + 2 > dense_change_chunks_side) return error.DenseChangeRegionCoversSingle;

        var data = DataSystem.init(allocator);
        errdefer data.deinit();
        const moves = try allocator.alloc(fixtures.StaticMove, change_count);
        errdefer allocator.free(moves);
        const commands = try allocator.alloc(StructuralCommand, change_count);
        errdefer allocator.free(commands);
        var touched = try std.DynamicBitSetUnmanaged.initEmpty(allocator, dense_change_chunks_side * dense_change_chunks_side);
        errdefer touched.deinit(allocator);
        var moved: usize = 0;
        var single: fixtures.StaticMove = undefined;
        for (0..dense_change_side) |cell_y| for (0..dense_change_side) |cell_x| {
            const home = pitchCellOrigin(cell_x, cell_y);
            const entity = if (denseCellTrigger(statics, cell_x, cell_y))
                try addTrigger(&data, home, .{ .x = dense_trigger_size, .y = dense_trigger_size })
            else
                try fixtures.addBody(&data, home, .{ .x = static_size, .y = static_size }, .static);
            const away = math.Vec2{
                .x = home.x + awayOffset(cell_x),
                .y = home.y + awayOffset(cell_y),
            };
            if (cell_x == dense_change_side - 1 and cell_y == dense_change_side - 1) single = .{ .entity = entity, .positions = .{ home, away } };
            if (cell_x / dense_change_chunk_cells >= region_side or cell_y / dense_change_chunk_cells >= region_side) continue;
            const chunk_cell = (cell_y % dense_change_chunk_cells) * dense_change_chunk_cells + cell_x % dense_change_chunk_cells;
            if (chunk_cell >= moves_per_chunk) continue;
            moves[moved] = .{ .entity = entity, .positions = .{ home, away } };
            moved += 1;
        };
        std.debug.assert(moved == change_count);

        // The dense world's two-tile pitch grid side fits u32.
        const cells: u32 = @intCast(2 * dense_change_side);
        var seam = try StaticSeam.init(allocator, io, &data, cells, cells, structuralEventHeadroom(0, change_count), case, threads);
        errdefer seam.deinit();
        if (static_colliders_test_support.liveRowCount(seam.colliders().*) != dense_change_side * dense_change_side) return error.WrongStaticCount;
        return .{
            .data = data,
            .seam = seam,
            .moves = moves,
            .single = single,
            .commands = commands,
            .region_side = region_side,
            .touched = touched,
            .allocator = allocator,
        };
    }

    fn deinit(self: *DenseChangeFixture) void {
        self.seam.deinit();
        self.touched.deinit(self.allocator);
        self.allocator.free(self.commands);
        self.allocator.free(self.moves);
        self.data.deinit();
        self.* = undefined;
    }

    // The signed tile offset of a move on an axis whose pitch cell is `cell`: ahead from an
    // even chunk, back from an odd one.
    fn awayOffset(cell: usize) f32 {
        const odd_chunk = (cell / dense_change_chunk_cells) % 2 == 1;
        const tiles: f32 = @floatFromInt(if (odd_chunk) dense_change_back_tiles else dense_change_ahead_tiles);
        return if (odd_chunk) -tiles * tile_size else tiles * tile_size;
    }

    // Every move as one commit through the production commit seam; returns the seam's
    // collider sync time (`SimulationPipeline.Perf.seam_collider_sync_ns`, `StaticColliderSystem.sync` alone) and
    // its stages' batches.
    fn changeAndSync(self: *DenseChangeFixture, thread_system: *ThreadSystem) !DenseSync {
        for (self.moves, self.commands) |*move, *command| command.* = move.command();
        const commit = try self.seam.commit(&self.data, self.commands, thread_system);
        if (commit.structural.components_set != self.moves.len) return error.DenseChangeNotApplied;
        try self.checkChanges();
        for (self.moves) |*move| move.advance();
        const colliders = self.seam.collidersConst();
        var batches: [sync_stages.len]BatchStats = undefined;
        for (&batches, sync_stages) |*batch, stage| batch.* = colliders.perf.last_batches.get(static_colliders_test_support.colliderStage(stage));
        return .{
            .ns = self.seam.pipeline().perf.seam_collider_sync_ns,
            .batches = batches,
            .off_main_ns = static_colliders_test_support.lastOffMainNs(colliders.*),
        };
    }

    // The single static moved as one commit through the production commit seam and synced:
    // an in-band sync for tuners that learned on single-static syncs. Untimed.
    fn changeOneAndSync(self: *DenseChangeFixture, thread_system: *ThreadSystem) !void {
        const commands = [1]StructuralCommand{self.single.command()};
        const commit = try self.seam.commit(&self.data, &commands, thread_system);
        if (commit.structural.components_set != 1) return error.DenseSpikeSingleNotApplied;
        if (self.seam.colliders().changesThisStep().len != 1) return error.DenseSpikeSingleNotSynced;
        self.single.advance();
    }

    // The sync's pass-shape counts on this fixture: every moved static planned and applied,
    // a removal and an insert touch each (one-tile statics: one chunk, no coarse cell), and
    // one installed item per region chunk, each its leavers' source and its arrivals'
    // destination.
    fn checkSyncWork(self: *const DenseChangeFixture, batches: [sync_stages.len]BatchStats) !void {
        const plan, const touch, const group_batch, const apply, _, const install = batches;
        if (plan.item_count != self.moves.len or touch.item_count != self.moves.len) return error.DenseChangePlanMissedChanges;
        if (apply.item_count != self.moves.len) return error.DenseChangeApplyMissedChanges;
        if (group_batch.item_count != 2 * self.moves.len) return error.DenseChangeGroupMissedTouches;
        if (install.item_count != self.region_side * self.region_side) return error.DenseChangeInstallMissedChunks;
    }

    // Untimed, last: one commit destroying every moved static. When the moves are every
    // static of the region's chunks, each region chunk empties (one-tile statics hold no
    // coarse cell), and the sync's fill runs one unit per emptied chunk, never its records
    // plus one.
    fn checkEmptyingSyncWork(self: *DenseChangeFixture, thread_system: *ThreadSystem) !void {
        const region_chunks = self.region_side * self.region_side;
        if (self.moves.len != region_chunks * dense_change_per_chunk) return;
        for (self.moves, self.commands) |move, *command| command.* = .{ .destroy_entity = move.entity };
        _ = try self.seam.commit(&self.data, self.commands, thread_system);
        const colliders = self.seam.collidersConst();
        if (colliders.changesThisStep().len != self.moves.len) return error.DenseChangeNotSynced;
        const view = colliders.view();
        const chunks_x = colliders.geometry.?.grid.chunks_x;
        for (0..self.region_side) |chunk_y| for (0..self.region_side) |chunk_x| {
            if (view.chunkHasRows(0, @intCast(chunk_y * chunks_x + chunk_x))) return error.DenseChangeRegionNotEmptied;
        };
        if (colliders.perf.last_batches.get(.rewrite).item_count != region_chunks) return error.DenseChangeEmptyFillNotPerItem;
    }

    // One change per moved static, each leaving its chunk for another in the region, and
    // the changes together touching exactly the region's chunks.
    fn checkChanges(self: *DenseChangeFixture) !void {
        const colliders = self.seam.colliders();
        const changes = colliders.changesThisStep();
        if (changes.len != self.moves.len) return error.DenseChangeNotSynced;
        const chunk_tiles = colliders.geometry.?.grid.chunk_tiles;
        self.touched.unsetAll();
        for (changes) |change| {
            const old_cells = (change.old orelse return error.DenseChangeUnplaced).cells;
            const new_cells = (change.new orelse return error.DenseChangeUnplaced).cells;
            if (old_cells.min_x / chunk_tiles == new_cells.min_x / chunk_tiles or old_cells.min_y / chunk_tiles == new_cells.min_y / chunk_tiles) return error.DenseChangeStayedInChunk;
            for ([_]@TypeOf(old_cells){ old_cells, new_cells }) |cells| {
                const chunk_x: usize = @intCast(cells.min_x / chunk_tiles);
                const chunk_y: usize = @intCast(cells.min_y / chunk_tiles);
                if (chunk_x >= self.region_side or chunk_y >= self.region_side) return error.DenseChangeLeftRegion;
                self.touched.set(chunk_y * dense_change_chunks_side + chunk_x);
            }
        }
        if (self.touched.count() != self.region_side * self.region_side) return error.DenseChangeWrongTouchedChunks;
    }

    // The colliders' row-pool and payload growths so far.
    fn grows(self: *const DenseChangeFixture) [2]u64 {
        const colliders = self.seam.collidersConst();
        return .{ colliders.perf.row_grows, colliders.perf.payload_grows };
    }
};

// A sync's stages in dispatch order.
const sync_stages = [_]SyncStage{ .plan, .touch, .group, .apply, .rewrite, .install };

const DenseSync = struct {
    ns: u64,
    batches: [sync_stages.len]BatchStats,
    // Every stage's worker dispatch time.
    off_main_ns: u64,
};

fn syncTunersSettled(colliders: *const StaticColliderSystem) bool {
    for (sync_stages) |stage| {
        if (colliders.tuners.getPtrConst(stage).phase != .settled) return false;
    }
    return true;
}

// What the sync tuners settle on before each measured dense sync.
const DenseLoad = enum {
    // Dense syncs: the tuners learn the timed shape (`collision-static-dense-change`).
    sustained,
    // Single-static syncs, and one more before each timed dense sync
    // (`collision-static-dense-spike`).
    spike,
};

fn runStaticDenseChangeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, change_count: usize) !suite.RunStats {
    return measureDenseSyncs(allocator, io, options, case, change_count, .sustained);
}

fn runStaticDenseSpikeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, change_count: usize) !suite.RunStats {
    return measureDenseSyncs(allocator, io, options, case, change_count, .spike);
}

fn measureDenseSyncs(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, change_count: usize, load: DenseLoad) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var fixture = try DenseChangeFixture.init(allocator, io, change_count, case, .solid, &threads);
    defer fixture.deinit();

    // The first dense sync grows the region chunks' payloads. A spike's warmup has no dense
    // sync, so one untimed dense round trip takes that growth out of the timed syncs, and
    // fresh tuners then settle on single-static syncs only.
    if (load == .spike) {
        for (0..2) |_| _ = try fixture.changeAndSync(&threads);
        fixtures.setSpliceTuners(fixture.seam.colliders(), case);
    }
    // Sync's tuners train in play, so the tuned case settles all six first: on dense syncs,
    // or for a spike on single-static syncs. At least two steps, so the dense statics (or
    // the single one) have been at both their tiles.
    var warm = suite.Warmup.init(options, case, 2);
    while (warm.next(syncTunersSettled(fixture.seam.collidersConst()))) switch (load) {
        .sustained => _ = try fixture.changeAndSync(&threads),
        .spike => try fixture.changeOneAndSync(&threads),
    };
    const settled = case.adaptive and syncTunersSettled(fixture.seam.collidersConst());
    // A spike is measured only from settled tuners.
    if (load == .spike and case.adaptive and !settled) return error.DenseSpikeTunersNotSettled;
    // The settled tuners' spike shape sizes the per-range scratch (the touch windows), so one
    // untimed spike each way grows it to the timed shape. A spike's record is skipped, but
    // these spikes set each tuner's held jump shape, which the timed spikes reuse.
    if (load == .spike) for (0..2) |_| {
        try fixture.changeOneAndSync(&threads);
        _ = try fixture.changeAndSync(&threads);
    };

    var accumulator = suite.StatsAccumulator.init(change_count);
    var main_total: u128 = 0;
    var stage_shapes = suite.StageShapes(sync_stages.len){};
    var stage_ns: [sync_stages.len]u128 = @splat(0);
    const stage_range = case.stageItemsPerRange(splice_range_alignment_items);
    const warm_grows = fixture.grows();
    for (0..options.iterations) |_| {
        if (load == .spike) {
            try fixture.changeOneAndSync(&threads);
            // Every timed spike runs on tuners settled at the single-static count.
            if (case.adaptive and !syncTunersSettled(fixture.seam.collidersConst())) return error.DenseSpikeTunersNotSettled;
        }
        const sync = try fixture.changeAndSync(&threads);
        try fixture.checkSyncWork(sync.batches);
        try suite.checkStagesDispatched(case, &threads, stage_range, &sync.batches);
        for (sync.batches, sync_stages) |batch, stage| try checkTunerSelected(case, &threads, fixture.seam.collidersConst().tuners.getPtrConst(stage), batch);
        accumulator.record(sync.ns, sync.batches[comptime std.mem.indexOfScalar(SyncStage, &sync_stages, .rewrite).?]);
        main_total += sync.ns -| sync.off_main_ns;
        stage_shapes.add(sync.batches);
        for (&stage_ns, sync.batches) |*total, batch| total.* += batch.batch_duration_ns;
    }
    const grows = fixture.grows();
    // Both directions' dense syncs ran before timing, so each measured one rewrites its
    // region in place.
    if (!std.mem.eql(u64, &grows, &warm_grows)) return error.DenseChangeWarmSyncGrewColliders;
    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.sample_count = change_count;
    if (case.adaptive) stats.work_tuning = suite.workTuningSummary(suite.tunerReport(fixture.seam.colliders().tuners.getPtr(.rewrite)), settled);
    printStageDetails(&stats, &sync_stages, &stage_shapes, &stage_ns);
    stats.details.print("row_grows={} payload_grows={}\n", .{ grows[0] - warm_grows[0], grows[1] - warm_grows[1] });
    try fixture.checkEmptyingSyncWork(&threads);
    return stats;
}

// The dense-change world with checkered triggers: each step's dense commit through the
// commit seam, then the timed trigger sync.
fn runStaticTriggerDenseChangeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, change_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var fixture = try DenseChangeFixture.init(allocator, io, change_count, case, .checkered_triggers, &threads);
    defer fixture.deinit();
    // Untimed: the first seam, with the cold store built at init over every row, every static
    // home, and the stored-trigger contact bound topped up by `reserveFrame`.
    _ = try fixture.seam.commit(&fixture.data, &.{}, &threads);
    const system = &fixture.seam.pipeline().collision;
    const home_pairs = denseHomeTriggerPairs(.checkered_triggers);
    if (system.trigger_store.pair_count != home_pairs) return error.TriggerPairCountMismatch;
    try fixture.seam.checkStoredPairsInBound(&fixture.data, &threads, case);
    // Untimed, once: the region moved away (its seam patches the store), then a cold rebuild
    // at that revision on a separate system is the away count every away patch keeps.
    _ = try fixture.changeAndSync(&threads);
    const away_pairs = blk: {
        var cold = CollisionSystem.init(allocator);
        defer cold.deinit();
        cold.strips = CollisionStrips.ofWorld(&fixture.seam.world);
        try cold.syncCommittedTriggers(&fixture.data, fixture.seam.collidersConst().view(), &threads);
        break :blk cold.trigger_store.pair_count;
    };
    // Stored pairs with the region home and away.
    const pairs = [2]usize{ home_pairs, away_pairs };
    _ = try denseTriggerSync(&fixture, pairs);

    // Fixed worker-count cases only, so nothing settles; two steps run both directions.
    var warm = suite.Warmup.init(options, case, 2);
    while (warm.next(true)) _ = try denseTriggerPatch(&fixture, &threads, pairs);
    var samples = TriggerPatchSamples.init(change_count);
    for (0..options.iterations) |_| samples.record(try denseTriggerPatch(&fixture, &threads, pairs));
    try fixture.seam.checkStoredPairsInBound(&fixture.data, &threads, case);
    const stats = samples.finish(&threads, change_count, system.trigger_store.pair_count);
    try checkFixedPatchStages(allocator, &fixture, &threads, case);
    return stats;
}

// Untimed: one dense change's trigger patch at the case's fixed controls, on a collision
// system one revision behind the seam that its collision step patches. The patch query runs
// over the change's statics, and the store's patch stages over at least one item each, all
// dispatched in a fixed threaded case; the patch leaves the rebuild's records. Then two
// changes skip a revision, so the next step rebuilds: its query covers every row, and it
// clears the patch's records.
fn checkFixedPatchStages(allocator: std.mem.Allocator, fixture: *DenseChangeFixture, threads: *ThreadSystem, case: suite.BenchmarkCase) !void {
    var fixed = CollisionSystem.init(allocator);
    defer fixed.deinit();
    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    defer contacts.deinit();
    const stage_range = case.stageItemsPerRange(collision_range_alignment_items);
    // The first step rebuilds the store at the seam's revision.
    _ = try fixed.update(&fixture.data, &contacts, threads, fixedStepConfig(fixture, case));
    const rebuild_batches = fixed.trigger_store.perf.last_rebuild_batches;
    _ = try fixture.changeAndSync(threads);
    _ = try fixed.update(&fixture.data, &contacts, threads, fixedStepConfig(fixture, case));
    if (fixed.perf.trigger_query_batch.item_count != fixture.moves.len) return error.TriggerPatchMissedQuery;
    const batches = fixed.trigger_store.perf.last_batches;
    const patch_stages = [_]BatchStats{ batches.get(.insert_place), batches.get(.insert_sort), batches.get(.leaf), batches.get(.node) };
    for (patch_stages) |batch| if (batch.item_count == 0) return error.TriggerPatchStageSkipped;
    try suite.checkStagesDispatched(case, threads, stage_range, &([1]BatchStats{fixed.perf.trigger_query_batch} ++ patch_stages));
    if (!std.meta.eql(rebuild_batches, fixed.trigger_store.perf.last_rebuild_batches)) return error.TriggerPatchReplacedRebuildRecord;
    for (0..2) |_| _ = try fixture.changeAndSync(threads);
    _ = try fixed.update(&fixture.data, &contacts, threads, fixedStepConfig(fixture, case));
    if (fixed.perf.trigger_rebuild_query_batch.item_count != fixture.seam.collidersConst().view().row_entity.len) return error.TriggerRebuildQueryMissedRows;
    if (fixed.perf.trigger_query_batch.item_count != 0) return error.TriggerRebuildKeptPatchRecord;
    for (fixed.trigger_store.perf.last_batches.values) |batch| if (batch.item_count != 0) return error.TriggerRebuildKeptPatchRecord;
}

// A collision step's config at the case's controls over `fixture`'s world strips and colliders.
fn fixedStepConfig(fixture: *const DenseChangeFixture, case: suite.BenchmarkCase) CollisionConfig {
    return .{
        .items_per_range = case.stageItemsPerRange(collision_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .strips = CollisionStrips.ofWorld(&fixture.seam.world),
        .static_colliders = fixture.seam.collidersConst().view(),
    };
}

// One dense commit through the production commit seam (`changeAndSync` checks every move
// synced), whose trigger sync is the sample.
fn denseTriggerPatch(fixture: *DenseChangeFixture, threads: *ThreadSystem, pairs: [2]usize) !TriggerPatch {
    _ = try fixture.changeAndSync(threads);
    return denseTriggerSync(fixture, pairs);
}

// The seam's trigger sync after a dense collider sync: the warm patch queries exactly the
// changed statics, and keeps the stored pair count of the region's side.
fn denseTriggerSync(fixture: *DenseChangeFixture, pairs: [2]usize) !TriggerPatch {
    const patch = try fixture.seam.triggerPatch();
    if (patch.query_items != fixture.moves.len) return error.TriggerPatchMissedQuery;
    // `changeAndSync` advanced every move, so the first move's side is the region's.
    if (fixture.seam.pipeline().collision.trigger_store.pair_count != pairs[@intFromBool(fixture.moves[0].at_second)]) return error.TriggerPairCountMismatch;
    return patch;
}

fn writeDenseChangeWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    // `sample_count` holds the change count.
    const changes = @max(stats.sample_count, 1);
    try writer.print("per_change={f}", .{suite.formatDuration(stats.mean_ns / changes)});
    if (view == .summary) return;
    try writeStage(writer, "rewrite", stats.batch, stats.work_tuning);
    try suite.writeMainShare(writer, stats, changes);
}

// A static fixture's production commit seam: a `SimulationPipeline` over the fixture's data
// with nav over a one-level walkable world of the statics' tile grid, its colliders built at
// the pipeline's init and its sync and nav stages on the case's controls.
const StaticSeam = struct {
    world: WorldSystem,
    seam: fixtures.PipelineSeam,

    // `threads` is the case's thread system, which builds the colliders, nav, and the stored
    // trigger pairs at init and runs the case's seams after.
    fn init(allocator: std.mem.Allocator, io: std.Io, data: *const DataSystem, cells_x: u32, cells_y: u32, structural_headroom: usize, case: suite.BenchmarkCase, threads: *ThreadSystem) !StaticSeam {
        var tileset = try fixtures.loadTilesetMeta(allocator, io);
        defer tileset.deinit();
        // The bench grids' tile counts fit a level side.
        var world = try fixtures.buildBandedWorldSized(allocator, &tileset, @intCast(cells_x), @intCast(cells_y), 1, "grass", "grass");
        errdefer world.deinit();
        if (world.tile_size != tile_size or world.chunk_size_tiles != default_chunk_size_tiles) return error.StaticSeamWorldGridMismatch;
        var seam = try fixtures.PipelineSeam.init(allocator, data, &world, .{
            .structural_headroom = structural_headroom,
            .build_thread_system = threads,
        });
        errdefer seam.deinit();
        seam.setCaseTuners(case);
        return .{ .world = world, .seam = seam };
    }

    fn deinit(self: *StaticSeam) void {
        self.seam.deinit();
        self.world.deinit();
        self.* = undefined;
    }

    fn pipeline(self: *StaticSeam) *SimulationPipeline {
        return &self.seam.pipeline;
    }

    fn colliders(self: *StaticSeam) *StaticColliderSystem {
        return &self.seam.pipeline.static_colliders;
    }

    fn collidersConst(self: *const StaticSeam) *const StaticColliderSystem {
        return &self.seam.pipeline.static_colliders;
    }

    // One step's commit of `commands` through the production seam, in a new frame step.
    fn commit(self: *StaticSeam, data: *DataSystem, commands: []const StructuralCommand, thread_system: *ThreadSystem) !CommitSeamResult {
        self.seam.frame.beginStep();
        return self.seam.commit(data, &self.world, commands, thread_system);
    }

    // The last seam's trigger sync: its time and its patch query's items. A seam that rebuilt
    // records no patch query, so callers check the items for the warm patch.
    fn triggerPatch(self: *const StaticSeam) !TriggerPatch {
        const pipe = &self.seam.pipeline;
        if (pipe.collision.trigger_store.seen_revision != pipe.static_colliders.view().revision) return error.TriggerSyncMissedRevision;
        return .{ .ns = pipe.perf.seam_trigger_sync_ns, .query_items = pipe.collision.perf.trigger_query_batch.item_count };
    }

    // Two untimed collision steps on the pipeline after its trigger seams, at the world's
    // strips and the case's controls (`PipelineSeam.collisionStep`). The first may count a
    // one-off slot growth (a wide dynamic's static query slot); the second counts no
    // pair-bound overflow. Every step checks its stored and dynamic contacts against the
    // contact bound init's reserve and the seams declared, so that bound covers the stored
    // pairs.
    fn checkStoredPairsInBound(self: *StaticSeam, data: *const DataSystem, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !void {
        const collision = &self.seam.pipeline.collision;
        _ = try self.seam.collisionStep(data, &self.world, thread_system, case);
        const before = collision.perf.pair_bound_overflows;
        _ = try self.seam.collisionStep(data, &self.world, thread_system, case);
        if (collision.perf.pair_bound_overflows != before) return error.TriggerSeamPairBoundOverflowed;
    }
};

// One static moved through the production commit seam each step, alternating between its
// pitch cell's static tile and a free tile one chunk and one tile back on both axes, so every
// move leaves one chunk for another; it overlaps nothing at either.
const StaticMover = struct {
    seam: StaticSeam,
    move: fixtures.StaticMove,
    // The last seam's nav reaction stages' worker time.
    nav_off_main_ns: u64 = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, fixture: *const StaticHeavyFixture, case: suite.BenchmarkCase, threads: *ThreadSystem) !StaticMover {
        // The statics' tiles: two tiles per pitch cell a side.
        const cells: u32 = @intCast(2 * fixture.side);
        var seam = try StaticSeam.init(allocator, io, &fixture.data, cells, cells, fixtures.StaticMove.structural_headroom, case, threads);
        errdefer seam.deinit();
        if (static_colliders_test_support.liveRowCount(seam.colliders().*) != fixture.side * fixture.side) return error.WrongStaticCount;
        const home = pitchCellOrigin(fixture.side - 1, fixture.side - 1);
        // Statics sit on even tiles, so an odd tile offset lands on a free tile.
        const away_tiles = default_chunk_size_tiles + 1;
        comptime std.debug.assert(away_tiles % 2 == 1);
        const away = @as(f32, @floatFromInt(away_tiles)) * tile_size;
        return .{
            .seam = seam,
            .move = .{ .entity = fixture.last_static, .positions = .{ home, .{ .x = home.x - away, .y = home.y - away } } },
        };
    }

    fn deinit(self: *StaticMover) void {
        self.seam.deinit();
        self.* = undefined;
    }

    // The pipeline's collision system, which the measured steps run, as production's step
    // after its seam does.
    fn collision(self: *StaticMover) *CollisionSystem {
        return &self.seam.seam.pipeline.collision;
    }

    // The move's set_movement_body through the production commit seam on `thread_system`.
    fn moveAndSync(self: *StaticMover, data: *DataSystem, thread_system: *ThreadSystem) !void {
        const commit = try self.seam.commit(data, &.{self.move.command()}, thread_system);
        if (commit.structural.components_set != 1) return error.StaticMoveNotApplied;
        self.nav_off_main_ns = commit.nav_update.perf.off_main_stage_ns;
        const colliders = self.seam.colliders();
        const changes = colliders.changesThisStep();
        if (changes.len != 1) return error.StaticChangeNotSynced;
        const chunk_tiles = colliders.geometry.?.grid.chunk_tiles;
        const old_cells = (changes[0].old orelse return error.StaticMoverUnplaced).cells;
        const new_cells = (changes[0].new orelse return error.StaticMoverUnplaced).cells;
        if (old_cells.min_x / chunk_tiles == new_cells.min_x / chunk_tiles or old_cells.min_y / chunk_tiles == new_cells.min_y / chunk_tiles) return error.StaticMoverStayedInChunk;
        self.move.advance();
    }

    // The last seam's collider sync and nav reaction worker time.
    fn seamOffMainNs(self: *const StaticMover) u64 {
        return static_colliders_test_support.lastOffMainNs(self.seam.collidersConst().*) + self.nav_off_main_ns;
    }

    // The colliders' row-pool and payload growths so far.
    fn grows(self: *const StaticMover) [2]u64 {
        const colliders = self.seam.collidersConst();
        return .{ colliders.perf.row_grows, colliders.perf.payload_grows };
    }
};

// What a measured step runs besides the collision update, and the fixture invariants the
// measurement checks.
const StepInputs = struct {
    // A static moved through the production commit seam before each update, whose
    // pipeline's collision system runs the update.
    mover: ?*StaticMover = null,
    // A collider structure built once; its view feeds every update.
    colliders: ?*StaticColliderSystem = null,
    // A trigger whose tier crosses the allow bit before each update.
    toggle: ?*AllowToggle = null,
    // `reserve`s the system to the fixture's movement bodies first, as the population seam
    // does, and checks the cold step: one static query slot outgrows its reserved hit rows,
    // flagged once while the broadphase stays inside the pair bound.
    reserved_cold_growth: bool = false,
    // Every step sweeps this many bodies, one strip each when `one_strip_per_body`.
    swept_bodies: ?usize = null,
    one_strip_per_body: bool = false,
};

// Warms up, settles the stage tuners, and times one step per iteration on the case's
// `thread_ptr`: the inputs' static move or tier flip, then the collision update over `data`.
fn measureCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, data: *DataSystem, thread_ptr: *ThreadSystem, inputs: StepInputs) !suite.RunStats {
    var own_system = CollisionSystem.init(allocator);
    defer own_system.deinit();
    // A mover's steps run on its pipeline's collision system, which its seams synced.
    const system = if (inputs.mover) |static_mover| static_mover.collision() else &own_system;
    useCaseTuners(system, case);
    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    defer contacts.deinit();

    if (inputs.reserved_cold_growth) {
        try system.reserve(data.movementBodySliceConst().entities.len);
        const cold = try runOnce(system, data, inputs, &contacts, thread_ptr, case);
        // A broadphase inside its bound cannot flag the step, so the flag is the static
        // slot's growth, kept through the later broadphase.
        if (cold.candidate_pair_count > system.reserved_pair_bound) return error.CollisionColdBroadphaseOutgrewBound;
        if (!cold.perf.pair_bound_exceeded or system.perf.pair_bound_overflows != 1) return error.CollisionColdSlotGrowthNotFlagged;
    }
    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(stageTunersSettled(system))) {
        _ = try runOnce(system, data, inputs, &contacts, thread_ptr, case);
    }
    const fill_settled_before_measurement = case.adaptive and (system.fill_tuner.phase == .settled);
    const sort_settled_before_measurement = case.adaptive and (system.sort_tuner.phase == .settled);
    const broadphase_settled_before_measurement = if (case.adaptive) (system.broadphase_tuner.phase == .settled) else false;
    const narrowphase_settled_before_measurement = if (case.adaptive) (system.narrowphase_tuner.phase == .settled) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_collision_stats = CollisionStats{};
    var main_total: u128 = 0;
    // A warm system grows no slot or bound past its reserve again.
    const warm_overflows = .{ system.perf.entry_bound_overflows, system.perf.pair_bound_overflows };
    // A warm mover's sync rewrites its two chunks in place: no row or payload growth.
    const warm_collider_grows = if (inputs.mover) |static_mover| static_mover.grows() else .{ 0, 0 };
    // Static query, Debug rect compare, static sort, and stored-trigger refresh; the mover's
    // splice.
    var static_stages = suite.StageShapes(4){};
    var splice_stages = suite.StageShapes(1){};
    const stage_range = case.stageItemsPerRange(collision_range_alignment_items);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_collision_stats = try runOnce(system, data, inputs, &contacts, thread_ptr, case);
        const end_ns = suite.nowNs(io);
        if (inputs.swept_bodies) |bodies| std.debug.assert(last_collision_stats.body_count == bodies);
        if (inputs.one_strip_per_body) std.debug.assert(last_collision_stats.entry_count == last_collision_stats.body_count);
        const perf = last_collision_stats.perf;
        // Every flip moves the allow epoch, so every measured step refreshes the stored pairs.
        if (inputs.toggle) |toggle| if (perf.trigger_refresh_batch.item_count != toggle.stored_pairs) return error.CollisionTriggerRefreshMissed;
        try suite.checkStagesDispatched(case, thread_ptr, stage_range, &.{ perf.fill_batch, perf.sort_batch, perf.broadphase_batch, perf.narrowphase_batch, perf.static_pairs_batch, perf.static_rect_batch, perf.static_place_batch, perf.static_sort_batch, perf.trigger_refresh_batch, perf.trigger_emit_count_batch, perf.trigger_emit_batch });
        try checkSweepWork(case, thread_ptr, stage_range, last_collision_stats);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, last_collision_stats.perf.broadphase_batch);
        const seam_off_main_ns = if (inputs.mover) |static_mover| static_mover.seamOffMainNs() else 0;
        const off_main_ns = offMainNs(perf.fill_batch) + offMainNs(perf.sort_batch) +
            offMainNs(last_collision_stats.perf.broadphase_batch) + offMainNs(last_collision_stats.perf.narrowphase_batch) +
            offMainNs(perf.static_pairs_batch) + offMainNs(perf.static_rect_batch) +
            offMainNs(perf.static_place_batch) + offMainNs(perf.static_sort_batch) + offMainNs(perf.trigger_refresh_batch) +
            offMainNs(perf.trigger_emit_count_batch) + offMainNs(perf.trigger_emit_batch);
        main_total += elapsed_ns -| off_main_ns -| seam_off_main_ns;
        static_stages.add(.{ perf.static_pairs_batch, perf.static_rect_batch, perf.static_sort_batch, perf.trigger_refresh_batch });
        if (inputs.mover) |static_mover| splice_stages.add(.{static_mover.seam.collidersConst().perf.last_batches.get(.rewrite)});
    }

    if (system.perf.entry_bound_overflows != warm_overflows[0] or system.perf.pair_bound_overflows != warm_overflows[1]) return error.CollisionWarmStepOverflowed;
    if (inputs.mover) |static_mover| {
        const grows = static_mover.grows();
        if (grows[0] != warm_collider_grows[0] or grows[1] != warm_collider_grows[1]) return error.CollisionWarmSyncGrewColliders;
    }
    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.collision_stages = .{
        .fill = suite.batchSummaryFromBatch(last_collision_stats.perf.fill_batch),
        .sort = suite.batchSummaryFromBatch(last_collision_stats.perf.sort_batch),
        .fill_tuning = if (case.adaptive) suite.workTuningSummary(suite.tunerReport(&system.fill_tuner), fill_settled_before_measurement) else null,
        .sort_tuning = if (case.adaptive) suite.workTuningSummary(suite.tunerReport(&system.sort_tuner), sort_settled_before_measurement) else null,
        .entries = last_collision_stats.entry_count,
        .visits = last_collision_stats.perf.broadphase_visits,
        .simd_groups = last_collision_stats.broadphase_simd_groups,
    };
    writeStaticStageDetails(&stats.details, &static_stages);
    if (inputs.mover) |static_mover| {
        var splice_buffer: [48]u8 = undefined;
        const grows = static_mover.grows();
        stats.details.print("splice={s} row_grows={} payload_grows={}\n", .{ splice_stages.label(0, &splice_buffer), grows[0], grows[1] });
    }
    stats.sample_count = item_count;
    stats.candidate_pairs = last_collision_stats.candidate_pair_count;
    stats.output_count = last_collision_stats.contact_count;
    stats.secondary_batch = suite.batchSummaryFromBatch(last_collision_stats.perf.narrowphase_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&system.broadphase_tuner), broadphase_settled_before_measurement);
        stats.secondary_work_tuning = suite.workTuningSummary(suite.tunerReport(&system.narrowphase_tuner), narrowphase_settled_before_measurement);
    }

    if (inputs.toggle != null) {
        // A step with no allow crossing keeps the stored rows and emit bits: no refresh runs.
        var quiet_inputs = inputs;
        quiet_inputs.toggle = null;
        const quiet = try runOnce(system, data, quiet_inputs, &contacts, thread_ptr, case);
        if (quiet.perf.trigger_refresh_batch.item_count != 0) return error.CollisionTriggerRefreshedQuietStep;
        if (quiet.contact_count != last_collision_stats.contact_count) return error.CollisionQuietStepChangedContacts;
    }
    return stats;
}

// The measured steps' static query, Debug rect compare, static sort, and stored-trigger
// refresh shapes (`StageShapes.label`).
fn writeStaticStageDetails(details: *suite.DetailLines, stages: *const suite.StageShapes(4)) void {
    var buffers: [4][48]u8 = undefined;
    details.print("static_pairs={s} static_rect={s} static_sort={s} trigger_refresh={s}\n", .{
        stages.label(0, &buffers[0]),
        stages.label(1, &buffers[1]),
        stages.label(2, &buffers[2]),
        stages.label(3, &buffers[3]),
    });
}

/// Gives each of `system`'s stage tuners the case's own tuner (an adaptive case only).
fn useCaseTuners(system: *CollisionSystem, case: suite.BenchmarkCase) void {
    for ([_]*AdaptiveWorkTuner{ &system.fill_tuner, &system.sort_tuner, &system.broadphase_tuner, &system.narrowphase_tuner, &system.static_pair_tuner, &system.static_rect_tuner, &system.static_place_tuner, &system.static_sort_tuner, system.trigger_store.tuners.getPtr(.refresh), &system.emit_tuner }) |tuner| {
        tuner.* = suite.adaptiveTunerForCase(case, collision_range_alignment_items) orelse return;
    }
}

/// Every stage tuner of `system` settled.
fn stageTunersSettled(system: *const CollisionSystem) bool {
    return (system.fill_tuner.phase == .settled) and (system.sort_tuner.phase == .settled) and
        (system.broadphase_tuner.phase == .settled) and (system.narrowphase_tuner.phase == .settled) and
        (system.static_pair_tuner.sample_count == 0 or system.static_pair_tuner.phase == .settled) and
        (system.static_rect_tuner.sample_count == 0 or system.static_rect_tuner.phase == .settled) and
        (system.static_place_tuner.sample_count == 0 or system.static_place_tuner.phase == .settled) and
        (system.static_sort_tuner.sample_count == 0 or system.static_sort_tuner.phase == .settled) and
        (system.trigger_store.tuners.getPtrConst(.refresh).sample_count == 0 or system.trigger_store.tuners.getPtrConst(.refresh).phase == .settled) and
        (system.emit_tuner.sample_count == 0 or system.emit_tuner.phase == .settled);
}

// Fails when a step's sweep batches miss their work: the broadphase covers every sweep
// entry, the narrowphase every candidate pair, and a fixed threaded case's broadphase spans
// one range per aligned `stage_range` of entries.
fn checkSweepWork(case: suite.BenchmarkCase, thread_system: ?*const ThreadSystem, stage_range: ?usize, stats: CollisionStats) !void {
    if (stats.perf.broadphase_batch.item_count != stats.entry_count) return error.CollisionBroadphaseMissedEntries;
    if (stats.perf.narrowphase_batch.item_count != stats.candidate_pair_count) return error.CollisionNarrowphaseMissedPairs;
    try suite.checkFixedRangeCount(case, thread_system, stage_range, stats.perf.broadphase_batch);
}

fn runOnce(
    system: *CollisionSystem,
    data: *DataSystem,
    inputs: StepInputs,
    contacts: *RangeOutputStream(CollisionContact),
    thread_system: *ThreadSystem,
    case: suite.BenchmarkCase,
) !CollisionStats {
    if (inputs.mover) |static_mover| try static_mover.moveAndSync(data, thread_system);
    if (inputs.toggle) |toggle| try toggle.flip(data);
    const view: ColliderView = if (inputs.mover) |static_mover|
        static_mover.seam.collidersConst().view()
    else if (inputs.colliders) |static_colliders|
        static_colliders.view()
    else
        .{};

    return try system.update(data, contacts, thread_system, .{
        .items_per_range = case.stageItemsPerRange(collision_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
        .static_colliders = view,
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

fn writeTriggerWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("candidate_pairs={} contacts={}", .{ stats.candidate_pairs, stats.output_count });
    // `sample_count` holds the stored pair count.
    if (stats.sample_count != 0) try writer.print(" per_pair={f}", .{suite.formatDuration(stats.mean_ns / stats.sample_count)});
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
