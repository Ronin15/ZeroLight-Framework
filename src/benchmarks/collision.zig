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
//! counted once; and a broadphase slot that outgrows its prepared pairs inside the total
//! bound (a fixed four-range cluster on two workers) counts one replay in the broadphase
//! set, flags no step, and the next step replays nothing. Every measured step adds no
//! pair- or entry-bound overflow, and a range slot set grows or replays only on a step
//! whose stage changed its shape from the step before (a retune). Every measured
//! group's `--details` prints `slot_records=`: the broadphase and static query range slots'
//! held pairs over their items' pair bound, and the most ranges each set prepared; each is
//! asserted at most 2 * H(ranges) (the grow-only slots' bound over every shape they
//! followed) on a set that never replayed, past the seam's slot 0 on a reserved system;
//! `static_hit_rows=` the static query slots' hit rows (each asserted at most the widest
//! query's grown rows or one alignment window's pairs) and their bytes, beside the set's
//! held pairs and their bytes; and `slot_growth=` each set's prepare growths and replays.
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
//!   rebuild runs (the tuned case is measured fresh, `settled=fresh`; the warmup rebuilds
//!   warm caches only). Pass shape: time
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
//!   spikes (shown in the stage details) and the main share reported.
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
//! a fixed threaded case, its static sort covers only the dynamic-by-static contacts, and its
//! emission the stored pairs plus those contacts; one step with no allow crossing refreshes
//! nothing; and the cold step,
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
//! `reserveFrame` tops up the bound. The fixed threaded cases pin the five patch stages' tuners
//! (the patch query, insert place and sort at the case's element range, the leaf at one
//! aligned page range, the node at one node per range); the tuned case warms until every patch tuner that ran has settled.
//! Asserts: the cold store's pair count; that each sync changes exactly the changed statics;
//! that the patch queried only the changes (not a rebuild over the row pool); the stored pair
//! count after every patch; in a pinned case every patch stage over more than one range on
//! workers (the node pass, one round per tree height, by its widest round); that each patch
//! writes at most two pages per edit (a drop piece or an insert, each in one page) and as
//! many nodes per tree height (the taller of the tree before and after); on every measured
//! patch no store page or level growth, and no patch scratch growth or growth or replay in
//! the patch query's range slot set, except in the tuned case at a retune: the slot set at a
//! patch whose query shape changed from the patch before, the scratch at one whose query or
//! insert place shape changed; and after the first, untimed seam and after the last
//! measured seam (each growing the stored-trigger contact bound as needed) two collision steps
//! at the world's strips count no pair-bound overflow. Each prints `per_change=`, and with
//! `--details` the main share (the sample less the patch stages' worker time) and, under each
//! row, in the tuned case the patch tuners' `step_tuners: settled=k/n` (each unsettled one
//! named), each patch stage's shape over the measured patches (`StageShapes.label`) and mean
//! batch time, in the tuned case each patch tuner's phase, final shape, and probe windows,
//! demotions, restores, and shift skips over them (`tuners:`), then
//! the query items, the stored pairs, the store's patch scratch growths, and the patch slot
//! set's prepare growths and replays.
//! - `collision-static-trigger-change`: the `collision-static-triggers` fixture's stored pairs
//!   in the corner of the largest count's grid, plus one solid alternating between cell 0's
//!   and cell 1's triggers (drops two pairs, adds two; queries the solid's one change). Its
//!   mode-only variant (item code `1_000_000 + pairs`) toggles the cell-0 solid between solid
//!   and trigger in place: two stored pairs either way, one change queried, and the patch
//!   walks once for the old and new pairs. Pass shape: patch time and main per change flat in
//!   stored pairs, up to the tree height H.
//! - `collision-static-trigger-dense-change`: the `collision-static-dense-change` world and
//!   moves, with every other static (a checkerboard, the last row and column solid) a
//!   trigger reaching half a tile into its neighbours' cells, so each overlaps its right and
//!   lower solids and its diagonal triggers; the home pair count is checked against those
//!   overlaps, the away count against a cold rebuild at the first away revision. Pass shape:
//!   main per changed static flat in the change count. Asserts: each patch queries exactly
//!   the changes. Last, untimed: a collision system one revision behind the seam, stepped at
//!   the case's controls, patches one dense change; its query covers exactly the changes,
//!   each store patch stage runs, the fixed threaded cases dispatch them all, and the patch
//!   leaves the rebuild's stage records.
//! - `collision-static-trigger-wide`: one trigger one chunk row tall and the world wide over
//!   the item count of solids, in eight rows on the two-tile pitch, the world as wide as the
//!   largest count's columns and the solids on a column stride of the largest count over the
//!   item count; the middle solid alternates with its free diagonal tile each step (queries
//!   its one change). Pass shape: patch cost follows the store's tree height (logarithmic in
//!   the stored pairs), flat in the solids otherwise.
//!
//! Every collision-step group prints `candidate_pairs=` and `contacts=`, the shape groups `per_body=`
//! (mean time per body), the static groups `per_dynamic=` (`collision-static-triggers`
//! `per_pair=`, per stored pair); `--details` adds each stage's
//! shape and batch time, `fill=`, `sort=`, `broad=` (the row's batch, its mean time; the
//! others the busiest over the measured steps), and `narrow=`, with the fill and sort tuners'
//! state in brackets (each stage tunes on its own; the row's tuning cell is the broadphase's,
//! the `secondary_tuning:` line the narrowphase's; `collision-static-triggers`, judged per
//! stored pair, prints `refresh=` and `emit=` in their place: the stored-trigger refresh is
//! its row's batch and tuner and the emission its secondary batch and tuner), then `entries=` (sweep entries), `visits_per_body=` (candidates the
//! sweep tested, counted with the perf log only), and `main=` with `main_per_item=` per body:
//! the time outside the stages' worker dispatches (and, in `collision-static-index-change`,
//! outside the seam's). The `--details` lines under each row give the measured steps' shapes
//! (`StageShapes.label`: the busiest batch, then threaded over non-empty batches) of the fill,
//! sort, broadphase, narrowphase, emission count, and emission (`steps:`), and of the static
//! query, Debug rect compare, static place, static sort, and stored-trigger refresh
//! (`static:`), in the tuned case the step tuners' `step_tuners: settled=k/n` (in
//! `collision-static-index-change` the seam's sync, trigger patch, and nav tuners too) and
//! each step tuner's phase, final shape, and probe windows, demotions, restores, and shift
//! skips over the measured steps (`tuners:`), and in `collision-static-index-change` the seam's
//! collider sync and trigger patch stage shapes (`seam:`) and its `row_grows=` and
//! `payload_grows=` counts. Each case checks once, before its warmup, that its named tuner
//! lists' lengths plus the rebuild stages' add up to `CollisionSystem`'s tuner count (a count,
//! not which tuners the lists name). `collision-static-rebuild` and
//! `collision-static-rebuild-sparse` print `per_static=`, and with `--details` the rewrite
//! stage and the main share per static (main is elapsed less every stage's worker time), and
//! under each row every stage's shape and mean batch time; `collision-static-dense-change`
//! prints `per_change=`, and with `--details` the rewrite stage (its tuner in the tuned case),
//! the main share per changed static (main is elapsed less every stage's worker time), and
//! under each row every stage's shape and mean batch time, in the tuned case the sync tuners'
//! `step_tuners: settled=k/n` and each one's state (`tuners:`), and the timed syncs'
//! `row_grows=` and `payload_grows=` counts; `collision-static-dense-spike` prints the same.

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
const NavUpdateStats = @import("../game/systems/pathfinding/types.zig").NavUpdateStats;
const CommitSeamResult = @import("../game/simulation_pipeline.zig").CommitSeamResult;
const tile_size = @import("../assets/world_tileset_meta.zig").required_tile_size;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");
const static_colliders_test_support = @import("../game/systems/static_colliders_test_support.zig");
const pinThreadedProfile = @import("../game/simulation_pipeline_test_support.zig").pinThreadedProfile;
const TriggerStore = @import("../game/systems/collision_triggers.zig").TriggerStore;

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
    .item_label = TriggerChangeCode.label,
    .describe_item = TriggerChangeCode.describe,
    .item_counts = &trigger_change_item_counts,
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

// Fixed cases pin the patch stages; the tuned case settles them.
const trigger_patch_cases = suite.casesNamed(&.{ "serial-direct", "thread-fixed-1", "thread-fixed-2", "thread-fixed-auto", "thread-adaptive-tuned-range" });

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
// outgrows its prepared pairs inside the total bound counts in its set
// (`checkSlotReplayCounted`).
fn checkPairBoundFlags(allocator: std.mem.Allocator, io: std.Io, case: suite.BenchmarkCase, data: *DataSystem) !void {
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var system = CollisionSystem.init(allocator);
    defer system.deinit();
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
    try checkSlotReplayCounted(allocator, io);
}

// A body with `box`'s bounds and no collision response.
fn addBoxBody(data: *DataSystem, x: f32, y: f32, w: f32, h: f32) !void {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = y }, .previous_position = .{ .x = x, .y = y } });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = w, .y = h } });
}

// 64 bodies at a 64-body reserve (256-pair bound, 128-entry bound), four broadphase ranges
// of 16 entries: slot 2 is prepared for 4 * 16 = 64 pairs. Ranges 0 and 1 are 32
// isolated bodies; range 2 is 16 wide bodies that all overlap (120 pairs) and the four
// narrow bodies of range 3 they cover in y (64 pairs): 184, past slot 2 but inside the
// total bound. The slot grows and the broadphase replays once, counted by the broadphase
// set and never as a pair-bound overflow. The grown slot then holds the cluster, so the
// next step replays nothing. The four ranges run on two workers of its own thread system,
// whatever the case's.
fn checkSlotReplayCounted(allocator: std.mem.Allocator, io: std.Io) !void {
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
    if (system.broadphase_slots.replays != 1) return error.CollisionSlotReplayNotCounted;
    if (replayed.perf.pair_bound_exceeded or system.perf.pair_bound_overflows != 0) return error.CollisionSlotReplayFlaggedPairBound;
    const settled = try system.update(&data, &contacts, &threads, config);
    if (system.broadphase_slots.replays != 1) return error.CollisionGrownSlotReplayed;
    if (settled.perf.pair_bound_exceeded or system.perf.pair_bound_overflows != 0) return error.CollisionGrownSlotFlagged;
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

    // The emitted stored pairs (the kinematic trigger's pair, the toggled trigger's pair while
    // it is excluded, and the dormant triggers' pairs are filtered) and the dynamic-by-static
    // contacts; no two dynamics overlap.
    fn contacts(self: *const TriggerFixture) usize {
        const pairs = self.toggle.stored_pairs - 1 - @intFromBool(self.toggle.excluded) - self.dormant_pairs;
        return pairs + self.dynamicStaticContacts();
    }

    // Every slot-0 dynamic is on its cell's trigger A, and the wide dynamic on both triggers
    // of its cells less the dormant ones.
    fn dynamicStaticContacts(self: *const TriggerFixture) usize {
        return trigger_dynamic_count / 2 + 2 * trigger_wide_cells * trigger_wide_cells - self.dormant_wide;
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
        .static_contacts = fixture.dynamicStaticContacts(),
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

// The trigger patch's stages, each under its own tuner: the collision system's patch query,
// then the store's insert place, insert sort, leaf, and node passes.
const trigger_patch_stage_count = 5;
const trigger_patch_stage_names = [trigger_patch_stage_count][]const u8{ "query", "insert_place", "insert_sort", "leaf", "node" };
const trigger_patch_query = 0;
const trigger_patch_insert_place = 1;
const trigger_patch_leaf = 3;
const trigger_patch_node = 4;

fn triggerPatchTuners(system: *const CollisionSystem) [trigger_patch_stage_count]*const AdaptiveWorkTuner {
    const tuners = &system.trigger_store.tuners;
    return .{ &system.trigger_query_tuner, tuners.getPtrConst(.insert_place), tuners.getPtrConst(.insert_sort), tuners.getPtrConst(.leaf), tuners.getPtrConst(.node) };
}

// The patch tuners whose stages ran, and how many of them settled.
fn patchTunerSettle(system: *const CollisionSystem) suite.TunerSettle {
    return suite.TunerSettle.ofNamed(&trigger_patch_stage_names, &triggerPatchTuners(system));
}

// A fixed threaded case pins the patch tuners at its controls, so the seam's sync, which
// runs production's tuned controls, runs the fixed shape: the query and inserts at the
// case's element range, the leaf at one aligned page range and the node at one node per
// range, as one chunk is for the chunk stages. Serial and tuned cases keep their tuners.
fn pinTriggerPatchStages(system: *CollisionSystem, case: suite.BenchmarkCase, threads: *const ThreadSystem) void {
    const workers = threads.workerThreadCount();
    if (workers == 0) return;
    const element_range = case.stageItemsPerRange(collision_range_alignment_items) orelse return;
    const page_range = case.stageItemsPerRangeForPartition(suite.chunk_partition_items, 1) orelse return;
    const tuners = &system.trigger_store.tuners;
    for ([_]*AdaptiveWorkTuner{ &system.trigger_query_tuner, tuners.getPtr(.insert_place), tuners.getPtr(.insert_sort) }) |tuner| {
        pinThreadedProfile(tuner, .{ .worker_threads = workers, .items_per_range = element_range });
    }
    for ([_]*AdaptiveWorkTuner{ tuners.getPtr(.leaf), tuners.getPtr(.node) }) |tuner| {
        pinThreadedProfile(tuner, .{ .worker_threads = workers, .items_per_range = page_range });
    }
}

// The tallest level tree's height: a page root is height 0, and each node level adds one.
fn triggerTreeHeight(store: *const TriggerStore) usize {
    var height: usize = 0;
    for (store.levels.items) |level| height = @max(height, level.height);
    return height;
}

// The store's page, level, and patch scratch growth counts.
const StoreGrowth = struct { pages: u64, levels: u64, scratch: u64 };

// One timed trigger sync: its time and the items its patch query ran over, the page edits
// its query emitted (drop pieces and inserts, each in one page), each patch stage's batch
// and their worker time, the patch query slot set's growth counts, the store's growth
// counts, and the tallest tree after it.
const TriggerPatch = struct {
    ns: u64,
    query_items: usize,
    edits: usize,
    batches: [trigger_patch_stage_count]BatchStats,
    off_main_ns: u64,
    slot_growth: SlotGrowth,
    store_growth: StoreGrowth,
    height: usize,

    fn stageShape(self: TriggerPatch, stage: usize) SlotShape {
        return .{ .range_count = self.batches[stage].range_count, .items_per_range = self.batches[stage].items_per_range };
    }
};

// A patch's work bound: a run's outputs are at most its touched pages plus one per page
// capacity of its inserts (an underfull run absorbs one neighbour, two outputs at most), so
// the leaf writes at most two pages per edit, and each node height as many nodes.
fn checkPatchWorkBound(patch: TriggerPatch, height_before: usize) !void {
    const page_bound = 2 * patch.edits;
    if (patch.batches[trigger_patch_leaf].item_count > page_bound) return error.TriggerPatchLeafPastBound;
    if (patch.batches[trigger_patch_node].item_count > page_bound * @max(height_before, patch.height)) return error.TriggerPatchNodePastBound;
}

// A warm patch's dispatch proof: in a pinned fixed threaded case every patch stage over
// more than one range ran on workers. The node pass runs one round per tree height under
// one sample, so its widest round spans at least its items over the heights it covered
// (the taller of the tree before and after).
fn checkPatchDispatched(case: suite.BenchmarkCase, threads: *const ThreadSystem, patch: TriggerPatch, height_before: usize) !void {
    const element_range = case.stageItemsPerRange(collision_range_alignment_items);
    const page_range = case.stageItemsPerRangeForPartition(suite.chunk_partition_items, 1);
    try suite.checkStagesDispatched(case, threads, element_range, patch.batches[0..trigger_patch_leaf]);
    try suite.checkStageDispatched(case, threads, page_range, patch.batches[trigger_patch_leaf]);
    const node = patch.batches[trigger_patch_node];
    const rounds = @max(height_before, patch.height, 1);
    try suite.checkRoundsDispatched(case, threads, page_range, node, (node.item_count + rounds - 1) / rounds);
}

// The timed syncs of one case, from its last warm patch: main is each sample less the
// patch stages' worker time. The store's pages and levels never grow on a measured patch.
// The patch query's slot set and the patch scratch grow only in the tuned case, at a
// retune: the slot set where the query's shape changed from the patch before, the scratch
// (sized from the query's and insert place's range counts) where either's did.
const TriggerPatchSamples = struct {
    accumulator: suite.StatsAccumulator,
    case: suite.BenchmarkCase,
    last: TriggerPatch,
    // The patch tuners' snapshot before measurement.
    settle: suite.TunerSettle,
    leaf_start: suite.TunerStart,
    retunes: suite.TunerWindow(trigger_patch_stage_count),
    main_total: u128 = 0,
    shapes: suite.StageShapes(trigger_patch_stage_count) = .{},
    stage_ns: [trigger_patch_stage_count]u128 = @splat(0),

    fn init(item_count: usize, case: suite.BenchmarkCase, system: *const CollisionSystem, warm: TriggerPatch) TriggerPatchSamples {
        const tuners = triggerPatchTuners(system);
        const settle = patchTunerSettle(system);
        return .{
            .accumulator = suite.StatsAccumulator.init(item_count),
            .case = case,
            .last = warm,
            .settle = settle,
            .leaf_start = .of(tuners[trigger_patch_leaf], case),
            .retunes = .begin(tuners),
        };
    }

    fn record(self: *TriggerPatchSamples, patch: TriggerPatch) !void {
        const last = self.last;
        if (patch.store_growth.pages != last.store_growth.pages or patch.store_growth.levels != last.store_growth.levels) return error.TriggerWarmPatchGrew;
        const scratch_grew = patch.store_growth.scratch != last.store_growth.scratch;
        if (self.case.adaptive) {
            try checkSlotSetGrowthAtRetune(last.slot_growth, patch.slot_growth, last.stageShape(trigger_patch_query), patch.stageShape(trigger_patch_query));
            const plan_kept = std.meta.eql(last.stageShape(trigger_patch_query), patch.stageShape(trigger_patch_query)) and
                std.meta.eql(last.stageShape(trigger_patch_insert_place), patch.stageShape(trigger_patch_insert_place));
            if (scratch_grew and plan_kept) return error.TriggerWarmPatchGrew;
        } else if (scratch_grew or !std.meta.eql(patch.slot_growth, last.slot_growth)) return error.TriggerWarmPatchGrew;
        self.accumulator.record(patch.ns, .{});
        self.main_total += patch.ns -| patch.off_main_ns;
        self.shapes.add(patch.batches);
        for (&self.stage_ns, patch.batches) |*total, batch| total.* += batch.batch_duration_ns;
        self.last = patch;
    }

    // `changes` is the statics changed per patch (`per_change=`), `stored_pairs` the last
    // patch's.
    fn finish(self: *const TriggerPatchSamples, system: *const CollisionSystem, changes: usize, stored_pairs: usize) !suite.RunStats {
        var stats = self.accumulator.finish();
        stats.batch_carried = false;
        stats.sample_count = changes;
        if (stats.iterations > 0) stats.main_ns = @intCast(self.main_total / stats.iterations);
        const tuners = triggerPatchTuners(system);
        if (self.case.adaptive) {
            stats.work_tuning = suite.workTuningSummary(tuners[trigger_patch_leaf], self.leaf_start);
            stats.tuner_settle = self.settle.measured();
        }
        var buffer: [48]u8 = undefined;
        for (trigger_patch_stage_names, self.stage_ns, 0..) |name, total_ns, index| {
            const mean_ns: u64 = if (stats.iterations > 0) @intCast(total_ns / stats.iterations) else 0;
            stats.details.print("{s}={s}({f}) ", .{ name, self.shapes.label(index, &buffer), suite.formatDuration(mean_ns) });
        }
        stats.details.print("\n", .{});
        if (self.case.adaptive) self.retunes.printTuning(&stats.details, trigger_patch_stage_names, tuners);
        stats.details.print("query_items={} stored_pairs={} scratch_grows={} slot_prepare_grows={} slot_replays={}\n", .{
            self.last.query_items,
            stored_pairs,
            self.last.store_growth.scratch,
            self.last.slot_growth.prepare_grows,
            self.last.slot_growth.replays,
        });
        return stats;
    }
};

// What one changed static's patch must show: the colliders' rows, the stored pairs after
// every patch (the cold rebuild's too), and the patch's query items.
const TriggerPatchShape = struct {
    static_count: usize,
    stored_pairs: usize,
    query_items: usize,
};

// `collision-static-trigger-change`'s configs: the stored pair count, and whether the cell-0
// solid toggles its mode in place instead of moving. The moving configs' codes are their
// pair counts.
const TriggerChangeCode = suite.ItemCode(struct { mode_only: bool, stored_trigger_pairs: u32 }, &.{6});
const trigger_change_item_counts = blk: {
    var codes: [2 * trigger_pair_counts.len]usize = undefined;
    for (trigger_pair_counts, 0..) |pairs, index| {
        codes[index] = TriggerChangeCode.of(.{ .mode_only = false, .stored_trigger_pairs = pairs });
        codes[trigger_pair_counts.len + index] = TriggerChangeCode.of(.{ .mode_only = true, .stored_trigger_pairs = pairs });
    }
    break :blk codes;
};

// A static whose collision mode toggles in place between solid and trigger, one
// `set_collision_response` a step; it starts solid.
const ModeToggle = struct {
    /// The commit seam's share for the toggle's one command a step.
    const structural_headroom = structuralEventHeadroom(0, 1);

    entity: EntityId,
    trigger: bool = false,

    fn command(self: *const ModeToggle) StructuralCommand {
        return .{ .set_collision_response = .{ .entity = self.entity, .response = .{ .mode = if (self.trigger) .solid else .trigger, .mobility = .static } } };
    }

    fn advance(self: *ModeToggle) void {
        self.trigger = !self.trigger;
    }
};

// The one static a trigger patch group changes each step: moved, or its mode toggled.
const TriggerPatchChange = union(enum) {
    move: fixtures.StaticMove,
    mode: ModeToggle,

    comptime {
        std.debug.assert(fixtures.StaticMove.structural_headroom == ModeToggle.structural_headroom);
    }
    const structural_headroom = ModeToggle.structural_headroom;

    fn command(self: *const TriggerPatchChange) StructuralCommand {
        return switch (self.*) {
            .move => |*move| move.command(),
            .mode => |*toggle| toggle.command(),
        };
    }

    fn advance(self: *TriggerPatchChange) void {
        switch (self.*) {
            .move => |*move| move.advance(),
            .mode => |*toggle| toggle.advance(),
        }
    }

    fn entity(self: *const TriggerPatchChange) EntityId {
        return switch (self.*) {
            .move => |move| move.entity,
            .mode => |toggle| toggle.entity,
        };
    }
};

fn runStaticTriggerChangeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try TriggerChangeCode.decode(item_count);
    const pair_count: usize = config.stored_trigger_pairs;
    var fixture = try createTriggerFixture(allocator, pair_count, false);
    defer fixture.data.deinit();
    // One solid on cell 0's triggers. Moving, it alternates with cell 1's: each move drops
    // two stored pairs and adds two. Toggling, it stays over cell 0's two triggers, two
    // stored pairs either way, and the patch walks once for the old and new pairs.
    const home = pitchCellOrigin(0, 0);
    const away = pitchCellOrigin(1, 0);
    const offset = trigger_change_solid_offset;
    const solid = try fixtures.addBody(&fixture.data, .{ .x = home.x + offset, .y = home.y + offset }, .{ .x = static_size, .y = static_size }, .static);
    var change: TriggerPatchChange = if (config.mode_only)
        .{ .mode = .{ .entity = solid } }
    else
        .{ .move = .{ .entity = solid, .positions = .{ .{ .x = home.x + offset, .y = home.y + offset }, .{ .x = away.x + offset, .y = away.y + offset } } } };
    var stats = try measureTriggerPatches(allocator, io, options, case, &fixture.data, .{ trigger_change_cells, trigger_change_cells }, &change, .{
        .static_count = 2 * pair_count + 1,
        .stored_pairs = pair_count + 2,
        // The changed solid's change.
        .query_items = 1,
    });
    stats.item_count = item_count;
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
    var change: TriggerPatchChange = .{ .move = move orelse return error.TriggerWideMissingMove };
    // The largest count's world width and one chunk row fit u32.
    var stats = try measureTriggerPatches(allocator, io, options, case, &data, .{ @intCast(trigger_wide_tiles_x), default_chunk_size_tiles }, &change, .{
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
// commits `change`'s static through the production commit seam each step; the sample is
// each seam's trigger sync. A fixed threaded case pins the patch stages; the tuned case
// warms until they settle. After the first seam and after the last measured seam, one
// collision step emits the stored pairs with no pair-bound overflow.
fn measureTriggerPatches(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, data: *DataSystem, cells: [2]u32, change: *TriggerPatchChange, shape: TriggerPatchShape) !suite.RunStats {
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var seam = try StaticSeam.init(allocator, io, data, cells[0], cells[1], TriggerPatchChange.structural_headroom, case, &threads);
    defer seam.deinit();
    if (static_colliders_test_support.liveRowCount(seam.colliders().*) != shape.static_count) return error.WrongStaticCount;
    const system = &seam.pipeline().collision;
    pinTriggerPatchStages(system, case, &threads);
    // Untimed: the first seam, with the cold store built at init.
    _ = try seam.commit(data, &.{}, &threads);
    if (system.trigger_store.pair_count != shape.stored_pairs) return error.TriggerPairCountMismatch;
    try seam.checkStoredPairsInBound(data, &threads, case);

    // At least two steps, so both directions ran.
    var warm = suite.Warmup.init(options, case, 2);
    var last_warm: ?TriggerPatch = null;
    while (warm.nextSettled(patchTunerSettle(system))) last_warm = try patchChangedStatic(&seam, data, change, &threads, case, shape);
    var samples = TriggerPatchSamples.init(shape.stored_pairs, case, system, last_warm.?);
    for (0..options.iterations) |_| try samples.record(try patchChangedStatic(&seam, data, change, &threads, case, shape));
    const stats = try samples.finish(system, 1, shape.stored_pairs);
    try seam.checkStoredPairsInBound(data, &threads, case);
    return stats;
}

// One change through the production commit seam, whose trigger sync is the sample: the sync
// changes only the changed static, and the warm patch queries the shape's items, keeps its
// pair count, stays in its work bound, and runs each stage on workers where a pinned case
// dispatches it.
fn patchChangedStatic(seam: *StaticSeam, data: *DataSystem, change: *TriggerPatchChange, threads: *ThreadSystem, case: suite.BenchmarkCase, shape: TriggerPatchShape) !TriggerPatch {
    const height_before = triggerTreeHeight(&seam.pipeline().collision.trigger_store);
    const commit = try seam.commit(data, &.{change.command()}, threads);
    if (commit.structural.components_set != 1) return error.StaticMoveNotApplied;
    const changes = seam.colliders().changesThisStep();
    if (changes.len != 1 or !changes[0].entity.eql(change.entity())) return error.StaticChangeNotSynced;
    change.advance();
    const patch = try seam.triggerPatch();
    if (patch.query_items != shape.query_items) return error.TriggerPatchMissedQuery;
    if (seam.pipeline().collision.trigger_store.pair_count != shape.stored_pairs) return error.TriggerPairCountMismatch;
    try checkPatchWorkBound(patch, height_before);
    try checkPatchDispatched(case, threads, patch, height_before);
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

    // Every rebuild is a world create's one-off on fresh tuners, as production's is (a new
    // system per create), so the tuned case is measured `fresh`; the warmup rebuilds warm
    // the caches and the allocator only.
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
        if (rewrite_tuner) |*tuner| stats.work_tuning = suite.workTuningSummary(tuner, .fresh);
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
const sync_stages = fixtures.sync_stages;

const DenseSync = struct {
    ns: u64,
    batches: [sync_stages.len]BatchStats,
    // Every stage's worker dispatch time.
    off_main_ns: u64,
};

// The collider sync's six stage tuners, by stage name.
fn syncTunerSettle(colliders: *const StaticColliderSystem) suite.TunerSettle {
    return suite.TunerSettle.ofNamed(&fixtures.sync_stage_names, &fixtures.syncTuners(colliders));
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
    while (warm.nextSettled(syncTunerSettle(fixture.seam.collidersConst()))) switch (load) {
        .sustained => _ = try fixture.changeAndSync(&threads),
        .spike => try fixture.changeOneAndSync(&threads),
    };
    // A spike is measured only from settled tuners.
    if (load == .spike and case.adaptive and !warm.settled()) return error.DenseSpikeTunersNotSettled;
    // The settled tuners' spike shape sizes the per-range scratch (the touch windows), so one
    // untimed spike each way grows it to the timed shape. A spike's record is skipped; a
    // repeated jump count reuses its judged shape (final within two iterations).
    if (load == .spike) for (0..2) |_| {
        try fixture.changeOneAndSync(&threads);
        _ = try fixture.changeAndSync(&threads);
    };

    const settle = syncTunerSettle(fixture.seam.collidersConst());
    const rewrite_start = suite.TunerStart.of(fixture.seam.collidersConst().tuners.getPtrConst(.rewrite), case);
    const sync_window = suite.TunerWindow(sync_stages.len).begin(fixtures.syncTuners(fixture.seam.collidersConst()));
    var accumulator = suite.StatsAccumulator.init(change_count);
    var main_total: u128 = 0;
    var stage_shapes = suite.StageShapes(sync_stages.len){};
    var stage_ns: [sync_stages.len]u128 = @splat(0);
    const stage_range = case.stageItemsPerRange(splice_range_alignment_items);
    const warm_grows = fixture.grows();
    for (0..options.iterations) |_| {
        if (load == .spike) {
            const before = syncTunerSettle(fixture.seam.collidersConst());
            try fixture.changeOneAndSync(&threads);
            // Every timed spike runs on tuners settled at the single-static count.
            if (case.adaptive and !before.settledSince()) return error.DenseSpikeTunersNotSettled;
        }
        const sync = try fixture.changeAndSync(&threads);
        try fixture.checkSyncWork(sync.batches);
        try suite.checkStagesDispatched(case, &threads, stage_range, &sync.batches);
        for (sync.batches, sync_stages) |batch, stage| try checkTunerSelected(case, &threads, fixture.seam.collidersConst().tuners.getPtrConst(stage), batch);
        accumulator.record(sync.ns, sync.batches[comptime std.mem.indexOfScalar(SyncStage, sync_stages, .rewrite).?]);
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
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(fixture.seam.collidersConst().tuners.getPtrConst(.rewrite), rewrite_start);
    }
    printStageDetails(&stats, sync_stages, &stage_shapes, &stage_ns);
    if (case.adaptive) sync_window.printTuning(&stats.details, fixtures.sync_stage_names, fixtures.syncTuners(fixture.seam.collidersConst()));
    stats.details.print("row_grows={} payload_grows={}\n", .{ grows[0] - warm_grows[0], grows[1] - warm_grows[1] });
    try fixture.checkEmptyingSyncWork(&threads);
    return stats;
}

// The dense-change world with checkered triggers: each step's dense commit through the
// commit seam, then the timed trigger sync. A fixed threaded case pins the patch stages; the
// tuned case warms until they settle.
fn runStaticTriggerDenseChangeCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, change_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    var fixture = try DenseChangeFixture.init(allocator, io, change_count, case, .checkered_triggers, &threads);
    defer fixture.deinit();
    const system = &fixture.seam.pipeline().collision;
    pinTriggerPatchStages(system, case, &threads);
    // Untimed: the first seam, with the cold store built at init over every row, every static
    // home, and the stored-trigger contact bound topped up by `reserveFrame`.
    _ = try fixture.seam.commit(&fixture.data, &.{}, &threads);
    const home_pairs = denseHomeTriggerPairs(.checkered_triggers);
    if (system.trigger_store.pair_count != home_pairs) return error.TriggerPairCountMismatch;
    try fixture.seam.checkStoredPairsInBound(&fixture.data, &threads, case);
    // Untimed, once: the region moved away (its seam patches the store), then a cold rebuild
    // at that revision on a separate system is the away count every away patch keeps.
    const home_height = triggerTreeHeight(&system.trigger_store);
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
    _ = try denseTriggerSync(&fixture, &threads, case, pairs, home_height);

    // At least two steps, so both directions ran.
    var warm = suite.Warmup.init(options, case, 2);
    var last_warm: ?TriggerPatch = null;
    while (warm.nextSettled(patchTunerSettle(system))) last_warm = try denseTriggerPatch(&fixture, &threads, case, pairs);
    var samples = TriggerPatchSamples.init(change_count, case, system, last_warm.?);
    for (0..options.iterations) |_| try samples.record(try denseTriggerPatch(&fixture, &threads, case, pairs));
    const stats = try samples.finish(system, change_count, system.trigger_store.pair_count);
    try fixture.seam.checkStoredPairsInBound(&fixture.data, &threads, case);
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
fn denseTriggerPatch(fixture: *DenseChangeFixture, threads: *ThreadSystem, case: suite.BenchmarkCase, pairs: [2]usize) !TriggerPatch {
    const height_before = triggerTreeHeight(&fixture.seam.pipeline().collision.trigger_store);
    _ = try fixture.changeAndSync(threads);
    return denseTriggerSync(fixture, threads, case, pairs, height_before);
}

// The seam's trigger sync after a dense collider sync: the warm patch queries exactly the
// changed statics, keeps the stored pair count of the region's side, stays in its work
// bound, and runs each stage on workers where a pinned case dispatches it.
fn denseTriggerSync(fixture: *DenseChangeFixture, threads: *const ThreadSystem, case: suite.BenchmarkCase, pairs: [2]usize, height_before: usize) !TriggerPatch {
    const patch = try fixture.seam.triggerPatch();
    if (patch.query_items != fixture.moves.len) return error.TriggerPatchMissedQuery;
    // `changeAndSync` advanced every move, so the first move's side is the region's.
    if (fixture.seam.pipeline().collision.trigger_store.pair_count != pairs[@intFromBool(fixture.moves[0].at_second)]) return error.TriggerPairCountMismatch;
    try checkPatchWorkBound(patch, height_before);
    try checkPatchDispatched(case, threads, patch, height_before);
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

    // The last seam's trigger sync (`TriggerPatch`). A seam that rebuilt records no patch
    // query or patch stage, so callers check the items for the warm patch.
    fn triggerPatch(self: *const StaticSeam) !TriggerPatch {
        const pipe = &self.seam.pipeline;
        const collision = &pipe.collision;
        const store = &collision.trigger_store;
        if (store.seen_revision != pipe.static_colliders.view().revision) return error.TriggerSyncMissedRevision;
        const stages = &store.perf.last_batches;
        const batches = [trigger_patch_stage_count]BatchStats{ collision.perf.trigger_query_batch, stages.get(.insert_place), stages.get(.insert_sort), stages.get(.leaf), stages.get(.node) };
        var off_main_ns: u64 = 0;
        for (batches) |batch| off_main_ns += offMainNs(batch);
        var edits: usize = 0;
        for (collision.trigger_edit_sources.items) |source| edits += source.drops.len + source.inserts.len;
        return .{
            .ns = pipe.perf.seam_trigger_sync_ns,
            .query_items = collision.perf.trigger_query_batch.item_count,
            .edits = edits,
            .batches = batches,
            .off_main_ns = off_main_ns,
            .slot_growth = .{ .prepare_grows = collision.trigger_patch_slots.prepare_grows, .replays = collision.trigger_patch_slots.replays },
            .store_growth = .{ .pages = store.perf.page_grows, .levels = store.perf.level_grows, .scratch = store.perf.scratch_grows },
            .height = triggerTreeHeight(store),
        };
    }

    // Two untimed collision steps on the pipeline after its trigger seams, at the world's
    // strips and the case's controls (`PipelineSeam.collisionStep`): neither counts a
    // pair-bound overflow (a wide dynamic's static query hit rows grow in their set). Every
    // step checks its stored and dynamic contacts against the contact bound init's reserve
    // and the seams declared, so that bound covers the stored pairs.
    fn checkStoredPairsInBound(self: *StaticSeam, data: *const DataSystem, thread_system: *ThreadSystem, case: suite.BenchmarkCase) !void {
        const collision = &self.seam.pipeline.collision;
        const before = collision.perf.pair_bound_overflows;
        for (0..2) |_| _ = try self.seam.collisionStep(data, &self.world, thread_system, case);
        if (collision.perf.pair_bound_overflows != before) return error.TriggerSeamPairBoundOverflowed;
    }
};

// One static moved through the production commit seam each step, alternating between its
// pitch cell's static tile and a free tile one chunk and one tile back on both axes, so every
// move leaves one chunk for another; it overlaps nothing at either.
const StaticMover = struct {
    seam: StaticSeam,
    move: fixtures.StaticMove,
    // The last seam's nav reaction.
    nav_stats: NavUpdateStats = .{},

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
        self.nav_stats = commit.nav_update;
        const colliders = self.seam.colliders();
        const changes = colliders.changesThisStep();
        if (changes.len != 1) return error.StaticChangeNotSynced;
        const chunk_tiles = colliders.geometry.?.grid.chunk_tiles;
        const old_cells = (changes[0].old orelse return error.StaticMoverUnplaced).cells;
        const new_cells = (changes[0].new orelse return error.StaticMoverUnplaced).cells;
        if (old_cells.min_x / chunk_tiles == new_cells.min_x / chunk_tiles or old_cells.min_y / chunk_tiles == new_cells.min_y / chunk_tiles) return error.StaticMoverStayedInChunk;
        self.move.advance();
    }

    // The last seam's collider sync, trigger patch, and nav reaction worker time.
    fn seamOffMainNs(self: *const StaticMover) u64 {
        return fixtures.seamOffMainNs(&self.seam.seam.pipeline, self.nav_stats);
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
    // The fixture's dynamic-by-static contacts, with no dynamic-dynamic contact: every step's
    // static sort covers exactly them, and with `toggle` the emission the stored pairs and
    // them.
    static_contacts: ?usize = null,
};

// A collision step's dynamic-side stages, in `dynamicStageBatches` order.
const dynamic_stage_names = [_][]const u8{ "fill", "sort", "broad", "narrow", "emit_count", "emit" };

fn dynamicStageBatches(perf: CollisionStats.Perf) [dynamic_stage_names.len]BatchStats {
    return .{ perf.fill_batch, perf.sort_batch, perf.broadphase_batch, perf.narrowphase_batch, perf.trigger_emit_count_batch, perf.trigger_emit_batch };
}

// A collision step's stage tuners, in `step_tuner_names` order.
const step_tuner_names = [_][]const u8{ "fill", "sort", "broad", "narrow", "static_pairs", "static_rect", "static_place", "static_sort", "refresh", "emit" };

fn stepTuners(system: *const CollisionSystem) [step_tuner_names.len]*const AdaptiveWorkTuner {
    return .{
        &system.fill_tuner,
        &system.sort_tuner,
        &system.broadphase_tuner,
        &system.narrowphase_tuner,
        &system.static_pair_tuner,
        &system.static_rect_tuner,
        &system.static_place_tuner,
        &system.static_sort_tuner,
        system.trigger_store.tuners.getPtrConst(.refresh),
        &system.emit_tuner,
    };
}

// Warms up, settles the stage tuners, and times one step per iteration on the case's
// `thread_ptr`: the inputs' static move or tier flip, then the collision update over `data`.
fn measureCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, data: *DataSystem, thread_ptr: *ThreadSystem, inputs: StepInputs) !suite.RunStats {
    var own_system = CollisionSystem.init(allocator);
    defer own_system.deinit();
    // A mover's steps run on its pipeline's collision system, which its seams synced.
    const system = if (inputs.mover) |static_mover| static_mover.collision() else &own_system;
    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    defer contacts.deinit();

    if (inputs.reserved_cold_growth) {
        try system.reserve(data.movementBodySliceConst().entities.len);
        const cold = try runOnce(system, data, inputs, &contacts, thread_ptr, case);
        if (cold.candidate_pair_count > system.reserved_pair_bound) return error.CollisionColdBroadphaseOutgrewBound;
        // The wide dynamic's static query outgrows its slot's hit rows: one replay in the
        // static set, inside the pair bound.
        if (system.static_slots.replays != 1 or system.static_sizing.hit_rows == 0) return error.CollisionColdSlotGrowthNotCounted;
        if (cold.perf.pair_bound_exceeded or system.perf.pair_bound_overflows != 0) return error.CollisionColdSlotGrowthFlaggedPairBound;
    }
    try checkTunerLists(system);
    var warm = suite.Warmup.init(options, case, 0);
    // The last step's range slot shapes, which a measured step's slot growth must differ from.
    var slot_shapes: ?[slot_set_count]SlotShape = null;
    while (warm.nextSettled(caseTunerSettle(system, inputs))) {
        const warm_stats = try runOnce(system, data, inputs, &contacts, thread_ptr, case);
        slot_shapes = slotShapes(system, warm_stats);
    }
    const step_settle = caseTunerSettle(system, inputs);
    const fill_start = suite.TunerStart.of(&system.fill_tuner, case);
    const sort_start = suite.TunerStart.of(&system.sort_tuner, case);
    // The row's tuners: the stored-trigger refresh and emission for the refresh workload
    // (`toggle`), the stage its pass shape names; the broadphase and narrowphase otherwise.
    const refreshes = inputs.toggle != null;
    const headline_tuner = if (refreshes) system.trigger_store.tuners.getPtrConst(.refresh) else &system.broadphase_tuner;
    const secondary_tuner = if (refreshes) &system.emit_tuner else &system.narrowphase_tuner;
    const headline_start = suite.TunerStart.of(headline_tuner, case);
    const secondary_start = suite.TunerStart.of(secondary_tuner, case);

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_collision_stats = CollisionStats{};
    var main_total: u128 = 0;
    // A warm system grows no bound past its reserve again.
    const warm_overflows = .{ system.perf.entry_bound_overflows, system.perf.pair_bound_overflows };
    // A warm mover's sync rewrites its two chunks in place: no row or payload growth.
    const warm_collider_grows = if (inputs.mover) |static_mover| static_mover.grows() else .{ 0, 0 };
    // Static query, Debug rect compare, static place, static sort, and stored-trigger
    // refresh; the mover's seam stages.
    var static_stages = suite.StageShapes(static_stage_names.len){};
    var seam_stages = suite.StageShapes(fixtures.seam_stage_names.len){};
    var dynamic_stages = suite.StageShapes(dynamic_stage_names.len){};
    const retunes = suite.TunerWindow(step_tuner_names.len).begin(stepTuners(system));
    const stage_range = case.stageItemsPerRange(collision_range_alignment_items);
    for (0..options.iterations) |_| {
        const step_slot_growth = slotGrowth(system);
        const start_ns = suite.nowNs(io);
        last_collision_stats = try runOnce(system, data, inputs, &contacts, thread_ptr, case);
        const end_ns = suite.nowNs(io);
        const step_slot_shapes = slotShapes(system, last_collision_stats);
        try checkSlotGrowthAtRetune(step_slot_growth, slotGrowth(system), slot_shapes, step_slot_shapes);
        slot_shapes = step_slot_shapes;
        if (inputs.swept_bodies) |bodies| std.debug.assert(last_collision_stats.body_count == bodies);
        if (inputs.one_strip_per_body) std.debug.assert(last_collision_stats.entry_count == last_collision_stats.body_count);
        const perf = last_collision_stats.perf;
        // Every flip moves the allow epoch, so every measured step refreshes the stored pairs.
        if (inputs.toggle) |toggle| if (perf.trigger_refresh_batch.item_count != toggle.stored_pairs) return error.CollisionTriggerRefreshMissed;
        if (inputs.static_contacts) |static_contacts| {
            if (perf.static_sort_batch.item_count != static_contacts) return error.CollisionStaticSortPastStaticContacts;
            if (inputs.toggle) |toggle| if (perf.trigger_emit_batch.item_count != toggle.stored_pairs + static_contacts) return error.CollisionTriggerEmitMissedItems;
        }
        try suite.checkStagesDispatched(case, thread_ptr, stage_range, &.{ perf.fill_batch, perf.sort_batch, perf.broadphase_batch, perf.narrowphase_batch, perf.static_pairs_batch, perf.static_rect_batch, perf.static_place_batch, perf.static_sort_batch, perf.trigger_refresh_batch, perf.trigger_emit_count_batch, perf.trigger_emit_batch });
        try checkSweepWork(case, thread_ptr, stage_range, last_collision_stats);
        const elapsed_ns = suite.elapsedNs(start_ns, end_ns);
        accumulator.record(elapsed_ns, if (refreshes) perf.trigger_refresh_batch else perf.broadphase_batch);
        const seam_off_main_ns = if (inputs.mover) |static_mover| static_mover.seamOffMainNs() else 0;
        const off_main_ns = offMainNs(perf.fill_batch) + offMainNs(perf.sort_batch) +
            offMainNs(last_collision_stats.perf.broadphase_batch) + offMainNs(last_collision_stats.perf.narrowphase_batch) +
            offMainNs(perf.static_pairs_batch) + offMainNs(perf.static_rect_batch) +
            offMainNs(perf.static_place_batch) + offMainNs(perf.static_sort_batch) + offMainNs(perf.trigger_refresh_batch) +
            offMainNs(perf.trigger_emit_count_batch) + offMainNs(perf.trigger_emit_batch);
        main_total += elapsed_ns -| off_main_ns -| seam_off_main_ns;
        static_stages.add(.{ perf.static_pairs_batch, perf.static_rect_batch, perf.static_place_batch, perf.static_sort_batch, perf.trigger_refresh_batch });
        dynamic_stages.add(dynamicStageBatches(perf));
        if (inputs.mover) |static_mover| seam_stages.add(fixtures.seamBatches(&static_mover.seam.seam.pipeline));
    }

    if (system.perf.entry_bound_overflows != warm_overflows[0] or system.perf.pair_bound_overflows != warm_overflows[1]) return error.CollisionWarmStepOverflowed;
    if (inputs.mover) |static_mover| {
        const grows = static_mover.grows();
        if (grows[0] != warm_collider_grows[0] or grows[1] != warm_collider_grows[1]) return error.CollisionWarmSyncGrewColliders;
    }
    var stats = accumulator.finish();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    stats.collision_stages = .{
        .fill = suite.batchSummaryFromShapes(&dynamic_stages, 0),
        .sort = suite.batchSummaryFromShapes(&dynamic_stages, 1),
        .fill_tuning = if (case.adaptive) suite.workTuningSummary(&system.fill_tuner, fill_start) else null,
        .sort_tuning = if (case.adaptive) suite.workTuningSummary(&system.sort_tuner, sort_start) else null,
        .entries = last_collision_stats.entry_count,
        .visits = last_collision_stats.perf.broadphase_visits,
        .simd_groups = last_collision_stats.broadphase_simd_groups,
    };
    dynamic_stages.print(&stats.details, "steps", dynamic_stage_names);
    static_stages.print(&stats.details, "static", static_stage_names);
    if (case.adaptive) retunes.printTuning(&stats.details, step_tuner_names, stepTuners(system));
    try checkSlotRecords(&stats.details, system, last_collision_stats.entry_count);
    writeSlotGrowth(&stats.details, slotGrowth(system));
    if (inputs.mover) |static_mover| {
        seam_stages.print(&stats.details, "seam", fixtures.seam_stage_names);
        const grows = static_mover.grows();
        stats.details.print("row_grows={} payload_grows={}\n", .{ grows[0], grows[1] });
    }
    stats.sample_count = item_count;
    stats.candidate_pairs = last_collision_stats.candidate_pair_count;
    stats.output_count = last_collision_stats.contact_count;
    // The secondary is the row's secondary tuner's stage: the emission (`emit`) for the
    // refresh workload, the narrowphase (`narrow`) otherwise.
    stats.secondary_batch = suite.batchSummaryFromShapes(&dynamic_stages, if (refreshes) 5 else 3);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(headline_tuner, headline_start);
        stats.secondary_work_tuning = suite.workTuningSummary(secondary_tuner, secondary_start);
        stats.tuner_settle = step_settle.measured();
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

// The broadphase and static query range slots' held pairs over their items' pair bound
// (`slot_records=`), and the most ranges each set prepared. A slot that only `prepare`
// sized holds at most its largest prepared range's bound with geometric slack, and range r
// of any shape covers at most 1/(r + 1) of the items: each ratio is at most 2 * H(ranges).
// A replay grows a slot to its range's counted need instead, past that bound by design, so
// a set that replayed prints `replayed` and is not asserted. On a reserved system slot 0
// is the seam's, sized to the population capacity, so the ratio counts the other slots.
// Then the static query slots' hit rows (`static_hit_rows=`): each slot holds at most the
// widest query's grown rows (`static_sizing.hit_rows`) or the rows `reserve` gives one
// query, one alignment window's pairs.
fn checkSlotRecords(details: *suite.DetailLines, system: *const CollisionSystem, entry_count: usize) !void {
    const sets = .{
        .{ "broad", &system.broadphase_slots, entry_count },
        .{ "static", &system.static_slots, system.proxies.len },
    };
    details.print("slot_records=", .{});
    inline for (sets) |set| {
        const slots = set[1];
        const seam_slot: u64 = if (system.reserved_pair_bound != 0 and slots.list.items.len != 0) slots.list.items[0].value.held() else 0;
        const held: f64 = @floatFromInt(slots.held_records - seam_slot);
        const bound: f64 = @floatFromInt(CollisionSystem.estimateContactCapacity(@max(set[2], 1)));
        const ratio = held / bound;
        const ranges = slots.list.items.len;
        const limit = 2 * harmonic(ranges);
        details.print("{s}:{d:.2}/{d:.2}(ranges={}{s}) ", .{ set[0], ratio, limit, ranges, if (slots.replays != 0) ",replayed" else "" });
        if (slots.replays == 0 and set[2] != 0 and ratio > limit) return error.CollisionSlotRecordsPastBound;
    }
    details.print("\n", .{});
    const query_rows = @max(system.static_sizing.hit_rows, CollisionSystem.estimateContactCapacity(collision_range_alignment_items));
    var rows: usize = 0;
    var bytes: usize = 0;
    var widest: usize = 0;
    for (system.static_slots.list.items) |*slot| {
        const hits = &slot.value.hits;
        if (hits.capacity > query_rows) return error.CollisionStaticHitRowsPastWidestQuery;
        rows += hits.capacity;
        bytes += @TypeOf(hits.*).capacityInBytes(hits.capacity);
        widest = @max(widest, hits.capacity);
    }
    const pair_bytes = system.static_slots.held_records * @sizeOf(std.meta.Child(@TypeOf(system.static_pairs.items)));
    details.print("static_hit_rows={} bytes={} slot_max={} grown_rows={} (pairs held={} bytes={})\n", .{ rows, bytes, widest, system.static_sizing.hit_rows, system.static_slots.held_records, pair_bytes });
}

// Collision's range slot sets: spill, broadphase, static query, trigger patch and rebuild.
const slot_set_count = 5;
const slot_set_names = [slot_set_count][]const u8{ "spill", "broad", "static", "trigger_patch", "trigger_rebuild" };

// One set's prepares that allocated and its replays.
const SlotGrowth = struct { prepare_grows: u64, replays: u64 };

// The ranges a set's stage last dispatched.
const SlotShape = struct { range_count: usize, items_per_range: usize };

fn slotGrowth(system: *const CollisionSystem) [slot_set_count]SlotGrowth {
    return .{
        .{ .prepare_grows = system.spill_slots.prepare_grows, .replays = system.spill_slots.replays },
        .{ .prepare_grows = system.broadphase_slots.prepare_grows, .replays = system.broadphase_slots.replays },
        .{ .prepare_grows = system.static_slots.prepare_grows, .replays = system.static_slots.replays },
        .{ .prepare_grows = system.trigger_patch_slots.prepare_grows, .replays = system.trigger_patch_slots.replays },
        .{ .prepare_grows = system.trigger_rebuild_slots.prepare_grows, .replays = system.trigger_rebuild_slots.replays },
    };
}

// The shape each set's stage dispatched in the step `stats` reports (the trigger queries'
// from the system's last seam records).
fn slotShapes(system: *const CollisionSystem, stats: CollisionStats) [slot_set_count]SlotShape {
    const batches = [slot_set_count]BatchStats{
        stats.perf.fill_batch,
        stats.perf.broadphase_batch,
        stats.perf.static_pairs_batch,
        system.perf.trigger_query_batch,
        system.perf.trigger_rebuild_query_batch,
    };
    var shapes: [slot_set_count]SlotShape = undefined;
    for (batches, &shapes) |batch, *shape| shape.* = .{ .range_count = batch.range_count, .items_per_range = batch.items_per_range };
    return shapes;
}

// A measured step's range slots grow or replay only at a retune: a set whose stage kept the
// last step's shape held every range's need already. A warm system's first measured step
// with no warm step before it has no shape to keep.
fn checkSlotGrowthAtRetune(before: [slot_set_count]SlotGrowth, after: [slot_set_count]SlotGrowth, last_shapes: ?[slot_set_count]SlotShape, shapes: [slot_set_count]SlotShape) !void {
    const last = last_shapes orelse return;
    for (before, after, last, shapes) |old, new, last_shape, shape| try checkSlotSetGrowthAtRetune(old, new, last_shape, shape);
}

// One set's form of `checkSlotGrowthAtRetune`.
fn checkSlotSetGrowthAtRetune(before: SlotGrowth, after: SlotGrowth, last_shape: SlotShape, shape: SlotShape) !void {
    if (!std.meta.eql(before, after) and std.meta.eql(last_shape, shape)) return error.CollisionSlotsGrewAtAKeptShape;
}

fn writeSlotGrowth(details: *suite.DetailLines, growth: [slot_set_count]SlotGrowth) void {
    details.print("slot_growth=", .{});
    for (slot_set_names, growth) |name, set| details.print("{s}:{}/{} ", .{ name, set.prepare_grows, set.replays });
    details.print("(prepare_grows/replays)\n", .{});
}

// The harmonic number H(n), 0 at n = 0.
fn harmonic(n: usize) f64 {
    var sum: f64 = 0;
    for (1..n + 1) |k| sum += 1 / @as(f64, @floatFromInt(k));
    return sum;
}

// A collision step's static-side stages, in the order the measured steps add them.
const static_stage_names = [_][]const u8{ "static_pairs", "static_rect", "static_place", "static_sort", "trigger_refresh" };

// Every tuner the step can run: with a mover, the step's stage tuners and every tuner of the
// systems its commit seam runs (`fixtures.addSeamTuners`, whose collision system is the
// step's); without one, every tuner of the step's system (`collisionTunerSettle`).
fn caseTunerSettle(system: *const CollisionSystem, inputs: StepInputs) suite.TunerSettle {
    const static_mover = inputs.mover orelse return collisionTunerSettle(system);
    std.debug.assert(system == &static_mover.seam.seam.pipeline.collision);
    var census = suite.TunerSettle.ofNamed(&step_tuner_names, &stepTuners(system));
    fixtures.addSeamTuners(&census, &static_mover.seam.seam.pipeline);
    return census;
}

// Every tuner of `system`, by name: the step stages' (`stepTuners`, the store's refresh among
// them), the trigger patch stages' (`triggerPatchTuners`), and the trigger rebuild's.
fn collisionTunerSettle(system: *const CollisionSystem) suite.TunerSettle {
    var census = suite.TunerSettle.ofNamed(&step_tuner_names, &stepTuners(system));
    census.addNamed(&trigger_patch_stage_names, &triggerPatchTuners(system));
    fixtures.addTriggerRebuildTuners(&census, "", system);
    return census;
}

// Fails when `CollisionSystem` holds a tuner its named census misses (`collisionTunerSettle`).
fn checkTunerLists(system: *const CollisionSystem) error{CollisionTunerListStale}!void {
    if (collisionTunerSettle(system).len != suite.tunerCount(CollisionSystem, system)) return error.CollisionTunerListStale;
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
    try writeCollisionDetails(writer, stats, sweep_stage_labels);
}

fn writeTriggerWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("candidate_pairs={} contacts={}", .{ stats.candidate_pairs, stats.output_count });
    // `sample_count` holds the stored pair count.
    if (stats.sample_count != 0) try writer.print(" per_pair={f}", .{suite.formatDuration(stats.mean_ns / stats.sample_count)});
    if (view == .summary) return;
    // The row's batch is the stored-trigger refresh and its secondary the emission.
    try writeCollisionDetails(writer, stats, .{ .batch = "refresh", .secondary = "emit" });
}

fn writeStaticWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("candidate_pairs={} contacts={}", .{ stats.candidate_pairs, stats.output_count });
    // `sample_count` holds the dynamic count.
    if (stats.sample_count != 0) try writer.print(" per_dynamic={f}", .{suite.formatDuration(stats.mean_ns / stats.sample_count)});
    if (view == .summary) return;
    try writeCollisionDetails(writer, stats, sweep_stage_labels);
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

// The labels of a row's batch and secondary batch, the stages its tuning cell and
// `secondary_tuning:` line tune.
const RowStageLabels = struct {
    batch: []const u8,
    secondary: []const u8,
};

// A sweep row's batch is the broadphase and its secondary the narrowphase.
const sweep_stage_labels = RowStageLabels{ .batch = "broad", .secondary = "narrow" };

fn writeCollisionDetails(writer: *std.Io.Writer, stats: suite.RunStats, labels: RowStageLabels) std.Io.Writer.Error!void {
    const stages = stats.collision_stages orelse return;
    try writeStage(writer, "fill", stages.fill, stages.fill_tuning);
    try writeStage(writer, "sort", stages.sort, stages.sort_tuning);
    // The row's batch, its tuner the primary tuning cell.
    try writeStage(writer, labels.batch, stats.batch, null);
    // The secondary stage's tuner prints once, on the suite's secondary tuning line.
    if (stats.secondary_batch) |secondary| try writeStage(writer, labels.secondary, secondary, null);
    // `sample_count` holds the body (or dynamic) count.
    const bodies = @max(stats.sample_count, 1);
    try writer.print(" entries={} visits_per_body={d:.2}", .{ stages.entries, @as(f64, @floatFromInt(stages.visits)) / @as(f64, @floatFromInt(bodies)) });
    try suite.writeMainShare(writer, stats, bodies);
}
