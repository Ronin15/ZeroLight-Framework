// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI perception substrate (Slice 29) throughput bench: gather -> shared
//! spatial-index neighbor query -> squared-form FOV filter -> bounded
//! line-of-sight raycast -> transition emit, at the same population scale
//! `ai.zig`/`spatial_index.zig` already use (`suite.eventScaleCounts`).
//!
//! Two groups isolate one variable: `perception` builds its world with
//! `WorldSystem.initDemoFromMeta`'s ordinary demo sparse-tile density (two
//! deco props); `perception-los-dense` uses the identical population and the
//! identical per-pair blocked-candidate pattern, but adds a large block of
//! additional sparse tiles far outside the populated region (see
//! `los_dense_extra_sparse_tiles`). Those extra tiles never coincide with a
//! real LOS sample cell, so `sensed_count`/`los_checks`/`los_blocked`/
//! `nearest_threat_found_count` come out IDENTICAL between the two groups --
//! only wall-clock cost differs. This originally isolated a real hazard:
//! `WorldSystem.levelBlocksMovement` (once called directly per LOS sample by
//! `hasLineOfSight` in `systems/perception.zig`) is a linear scan over every
//! sparse tile in the world, so every sample paid for the whole sparse set
//! regardless of locality (10,000 agents: 33.60ms -> 217.58ms serial, a 6.5x
//! regression, identical counters).
//!
//! `PerceptionSystem.level_blocked` (an O(1) per-level blocked-tile bitmap
//! cache, brought current for a distinct observer level at most once per step)
//! fixed this: `hasLineOfSight` now reads that cache instead of calling
//! `levelBlocksMovement` per sample. Post-fix at 10,000 agents, serial-direct:
//! `perception` 21.98ms, `perception-los-dense` 25.74ms (1.17x); best
//! threaded: `perception` ~6.39ms, `perception-los-dense` 9.64ms (was
//! 25.81ms, over the 16.67ms/60Hz budget). A fixed, non-scaling ~3ms gap
//! remained between the two groups at every population this bench measures
//! (not proportional to agent count or `los_checks`) -- the once-per-step
//! cache-rebuild cost paid against this fixture's deliberately unrealistic
//! 20,000-tile density, not a per-sample regression. See
//! `docs/framework-implementation-slices.md`'s Slice 29 section for the full
//! before/after tables of this original fix.
//!
//! That residual was closed by giving `level_blocked` incremental
//! dirty-tracking (`LevelBlockedSlot.pending_dirty`,
//! `PerceptionSystem.reactToPostCommitPerceptionEvents`/
//! `ensureLevelBlockedCache`): a level with no world/obstacle edits since its
//! last build now SKIPS the rescan entirely instead of rebuilding every
//! touched step regardless of change, and a bounded edit PATCHES only the
//! affected rect instead of rescanning the whole level. `perception-cache-full-
//! rebuild`/`perception-cache-patch` isolate exactly this cache-maintenance
//! cost from the rest of the pipeline: both reuse `perception`'s own
//! representative-density fixture and report one synthetic structural-commit
//! event per iteration before the timed call (a whole-level rect, forcing the
//! same full-rebuild code path this system used unconditionally before this
//! fix existed, vs. a single-cell rect, forcing the new scoped patch), so
//! `sensed_count`/`los_checks`/`nearest_threat_found_count` stay identical
//! between the two groups at every item count and only the LOS-cache
//! maintenance cost differs -- the same delta method as the
//! `perception`/`perception-los-dense` split above. Measured (`--profile
//! quick`), serial-direct: 1,024 agents 3.58ms (full-rebuild) vs 2.25ms
//! (patch), a 1.33ms gap; 4,096 agents 11.74ms vs 10.75ms, a 0.99ms gap;
//! 10,000 agents 29.10ms vs 26.61ms, a 2.49ms gap. Best-threaded: 1,024
//! agents 1.97ms vs 0.65ms, a 1.32ms gap; 4,096 agents 3.85ms vs 2.41ms, a
//! 1.44ms gap; 10,000 agents 7.58ms vs 6.10ms, a 1.48ms gap. The gap stays
//! roughly flat (~1.3-1.5ms) across a ~10x population range rather than
//! scaling with agent count, the same signature the original fix's residual
//! showed -- confirming this really is the once-per-step cache-maintenance
//! cost (now a bounded single-rect patch instead of a full O(world cells)
//! rescan) and not a per-agent cost.
//!
//! This also re-closes the `perception`/`perception-los-dense` residual
//! itself, directly: neither group's fixture ever calls
//! `reactToPostCommitPerceptionEvents` (positions never change across
//! iterations -- see the module-level fixture note below), so `pending_dirty`
//! stays empty and every measured step after the first now takes the skip
//! branch instead of the old unconditional full rebuild. Re-measured
//! (`--profile quick`, same 10,000-agent case the numbers above were recorded
//! at): `perception` 26.92ms serial-direct / 6.09ms best-threaded,
//! `perception-los-dense` 27.31ms serial-direct / 6.11ms best-threaded -- a
//! ~0.4ms/~0.02ms gap, down from the 1.67ms/1.85ms gap recorded above right
//! after the shared-index fix and the original 3.76ms/3.25ms gap before it.
//! The remaining sub-millisecond difference is the one real full rebuild each
//! fixture still pays on its first touched step (warmup absorbs this before
//! measurement, so it does not show up above at all -- the residual that
//! remains here is run-to-run noise, not a first-build cost). This is the
//! same fix as the `perception-cache-full-rebuild`/`-patch` split above, seen
//! from the other side: a STATIC world (no edits, ever) now costs the same
//! whether or not it happens to carry 20,000 extra sparse tiles, because
//! after the first step neither fixture ever rescans again.
//!
//! A third group, `perception-scattered-dense-index`, isolates a different
//! variable: `computeOneAgent` (`systems/perception.zig`) scatters its 5
//! output fields into `job.perception_slice` at `perception_dense_index[i]`,
//! which is disjoint but not contiguous/correlated with worker-range
//! boundaries over `i` (see that function's doc comment and
//! `createDecorrelatedFixture` below). `perception`/`perception-los-dense`
//! both build their fixture with `setAiPerception` called immediately after
//! each pair's creation, which keeps `perception_dense_index` near-monotonic
//! in `i` -- so any cross-worker cache-line contention from that scatter
//! would never surface in those two groups even if real.
//! `perception-scattered-dense-index` uses the identical population and
//! blocked-candidate pattern as `perception`, but assigns
//! `perception_dense_index` in a shuffled order (`createDecorrelatedFixture`'s
//! fixed `(step * dense_index_shuffle_stride) % pair_count` permutation) --
//! a provable non-identity scatter, so worker ranges genuinely write
//! interleaved (same-cache-line) slots at full observer-population scale,
//! not merely a scenario that could theoretically decorrelate. Measured at
//! this bench's largest tier (50,000 agents, `--items 50000`), two runs
//! each: `perception` threaded-vs-serial best case 4.34x/4.49x;
//! `perception-scattered-dense-index` 4.42x/4.54x -- the decorrelated case is
//! not slower (if anything marginally faster, within run-to-run noise),
//! against a 20% regression threshold (any case's threaded-vs-serial ratio
//! coming out worse than its correlated counterpart by more than 20% would
//! count as confirmed). `sensed_count`/`los_checks`/`los_blocked`/
//! `nearest_threat_found_count` came out IDENTICAL between the two groups at
//! every case, confirming the shuffle only changed store-write locality, not
//! fixture population or outcomes. Conclusion: measured, no regression -- the
//! false-sharing opportunity is real and exercised, but the per-agent
//! spatial-query/FOV/LOS cost dwarfs the 5 scattered writes, so
//! `computeOneAgent`'s direct scatter is left as-is; the
//! `computeFacingDense`-style dense-pass-then-serial-scatter rewrite was not
//! applied.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const Faction = @import("../game/data_system.zig").Faction;
const SimulationEvents = @import("../game/simulation.zig").SimulationEvents;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const spatial_index_mod = @import("../game/systems/spatial_index.zig");
const SpatialIndexSystem = spatial_index_mod.SpatialIndexSystem;
const SpatialIndexView = spatial_index_mod.SpatialIndexView;
const perception_mod = @import("../game/systems/perception.zig");
const PerceptionStats = perception_mod.PerceptionStats;
const PerceptionSystem = perception_mod.PerceptionSystem;
const perception_range_alignment_items = perception_mod.perception_range_alignment_items;
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const TileId = @import("../game/world_system.zig").TileId;
const suite = @import("suite.zig");

pub const group = suite.BenchmarkGroup{
    .name = "perception",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

pub const los_dense_group = suite.BenchmarkGroup{
    .name = "perception-los-dense",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runLosDenseCase,
};

pub const scattered_dense_index_group = suite.BenchmarkGroup{
    .name = "perception-scattered-dense-index",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runScatteredDenseIndexCase,
};

// Isolates the LOS-blocked cache's per-step maintenance cost from the rest of
// the pipeline, the same "identical population/counters, only wall-clock
// differs" delta method the module doc's `perception`/`perception-los-dense`
// split uses. Both groups reuse `perception`'s own representative-density
// fixture (`buildDefaultFixture`, `world_tiles_side` — already this file's
// largest level) and inject ONE structural-commit event per iteration via
// `PerceptionSystem.reactToPostCommitPerceptionEvents` before the timed
// `update`/`updateSerial` call: `perception-cache-full-rebuild` reports a
// whole-level rect every iteration, forcing `ensureLevelBlockedCache`'s
// over-threshold fallback (the same full-rebuild code path this system used
// unconditionally, every touched step, before the incremental patch/skip
// design existed -- see the module doc); `perception-cache-patch` reports one
// single-cell rect every iteration, forcing the scoped patch path instead.
// Neither variant mutates the world's actual tiles (the injected event is
// synthetic — only the dirty-tracking bookkeeping is under test), so both
// groups' `sensed_count`/`los_checks`/`nearest_threat_found_count` stay
// identical to `perception`'s own at every item count; only the LOS-cache
// maintenance cost differs. See the module doc for the measured before/after.
pub const cache_full_rebuild_group = suite.BenchmarkGroup{
    .name = "perception-cache-full-rebuild",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCacheFullRebuildCase,
};

pub const cache_patch_group = suite.BenchmarkGroup{
    .name = "perception-cache-patch",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCachePatchCase,
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

// Grid spacing for observer/candidate pairs is tile-aligned (see
// `createFixture`): each pair's candidate lands in its own distinct tile
// cell, one column/row apart from its neighbors, so a per-pair blocking tile
// (`blocked_pair_period` below) never collaterally blocks a neighboring
// pair's candidate cell too -- world tiles are typically much larger than a
// tight world-space grid step, so an unaligned spacing would let several
// pairs share one cell and turn "block every 4th pair" into "block nearly
// every pair in the shared cell's cluster".
const pair_grid_columns: usize = 128;
// Fraction of one tile the observer sits ahead of its own candidate (so
// facing derived from its velocity points straight at it, well inside the
// default 60-degree half-angle FOV) without leaving the candidate's tile
// cell -- keeps the pair's own LOS geometry simple (single-sample raycast).
const observer_offset_tile_fraction: f32 = 0.3;
const observer_facing_velocity_x: f32 = -10.0;

// Deliberately short vision_range (2 tiles at the default spatial-index
// cell_size 32, vs. `AiPerception`'s 240/7.5-tile default). This fixture
// places one pair per tile cell -- much denser than a real scene -- so a
// full-range scan window can fill `max_perception_candidates` (16) purely
// from rows *above* an observer before `queryNeighbors`'s cell_y-then-cell_x
// traversal ever reaches its own row (order is not nearest-first). A short
// range keeps the scan window small enough that every observer's own row is
// always reached, so `los_blocked` reflects real obstacle blocking, not
// candidate-cap starvation. Verified stable (100% found with no obstacles)
// from a single populated row through this bench's largest multi-row count.
const observer_vision_range: f32 = 64.0;

// Every 4th pair's own candidate sits on a blocking tile, so a realistic
// fraction of observers pay for a blocked nearest candidate before falling
// through to a farther clear one (or finding none) -- exercising
// `los_blocked` at both densities identically, the same way the module's own
// "LOS gating skips a blocked nearer candidate" test does at unit scale.
const blocked_pair_period: usize = 4;

// Sparse tiles added far outside the populated grid, purely to inflate
// `WorldSystem`'s total sparse tile count (see module doc). This is well
// beyond this project's other benchmark fixtures' sparse-tile density
// (`render_game_prep.zig` caps at 12_288 even at its largest population) --
// deliberately so, since this fixture exists to stress exactly the scan cost
// those fixtures never approach.
const los_dense_extra_sparse_tiles: usize = 20_000;
// Reserved rows/columns comfortably clear of the largest populated grid this
// bench ever builds (the `stress` profile's 50_000-item count needs at most
// 196 pair rows at `pair_grid_columns` columns), so the extra bulk tiles
// never coincide with a real agent's tile.
const los_dense_region_row_start: u16 = 210;
const los_dense_region_width: u16 = 200;
const world_tiles_side: u16 = 340;

fn requireTile(meta: *const world_tileset_meta.WorldTilesetMeta, name: []const u8) !TileId {
    return (meta.tileByName(name) orelse return error.TileNotFound).id;
}

const Fixture = struct {
    data: DataSystem,
    world: WorldSystem,

    fn deinit(self: *Fixture) void {
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

fn addAgent(data: *DataSystem, pos_x: f32, pos_y: f32, velocity_x: f32, velocity_y: f32, faction: Faction) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = pos_x, .y = pos_y },
        .previous_position = .{ .x = pos_x, .y = pos_y },
        .velocity = .{ .x = velocity_x, .y = velocity_y },
        .speed = 40,
    });
    try data.setAiAgent(entity, .{ .behavior = .wander });
    try data.setFaction(entity, faction);
    return entity;
}

fn addObserver(data: *DataSystem, pos_x: f32, pos_y: f32, velocity_x: f32, velocity_y: f32) !EntityId {
    const entity = try addAgent(data, pos_x, pos_y, velocity_x, velocity_y, .player);
    try data.setAiPerception(entity, .{ .vision_range = observer_vision_range });
    return entity;
}

// `meta` is only needed to resolve tile ids and build the catalog/dense
// ground layer; once `WorldSystem.initDemoFromMeta` returns, this bench never
// calls anything that reads `WorldSystem.tilesetMeta()` back (no rendering),
// so `meta` is freed at the end of this function -- same shape as
// `nav_update.zig`'s `buildSharedFixture`.
fn createFixture(allocator: std.mem.Allocator, io: std.Io, count: usize, extra_sparse_tiles: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const tree = try requireTile(&meta, "tree_0");
    const deco = try requireTile(&meta, "deco_0");

    const tile_size = meta.tileSize();
    const bounds = @as(f32, @floatFromInt(world_tiles_side)) * tile_size;
    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, bounds, bounds);
    errdefer world.deinit();

    const observer_offset_x = tile_size * observer_offset_tile_fraction;
    const pair_count = count / 2;
    var pair_index: usize = 0;
    while (pair_index < pair_count) : (pair_index += 1) {
        const gx = @as(f32, @floatFromInt(pair_index % pair_grid_columns)) * tile_size;
        const gy = @as(f32, @floatFromInt(pair_index / pair_grid_columns)) * tile_size;
        _ = try addAgent(&data, gx, gy, 0, 0, .hostile);
        _ = try addObserver(&data, gx + observer_offset_x, gy, observer_facing_velocity_x, 0);

        if (pair_index % blocked_pair_period == blocked_pair_period - 1) {
            const cell = world.cellContaining(gx, gy) orelse continue;
            _ = try world.addSparseTile(0, cell.x, cell.y, tree, 0, .obstacle);
        }
    }

    var extra_index: usize = 0;
    while (extra_index < extra_sparse_tiles) : (extra_index += 1) {
        const x: u16 = @intCast(extra_index % los_dense_region_width);
        const y: u16 = los_dense_region_row_start + @as(u16, @intCast(extra_index / los_dense_region_width));
        _ = try world.addSparseTile(0, x, y, deco, 0, .obstacle);
    }

    return .{ .data = data, .world = world };
}

// Preferred stride for `createDecorrelatedFixture`'s observer-creation-order
// shuffle. Prime, odd, and not a multiple of 5, so it stays coprime with
// every pair count this bench's default `eventScaleCounts` tiers produce
// (each is `2^a * 5^b`). `shuffleStrideFor` below falls back to searching
// upward from this value for a pair count supplied via `--items`, so the
// shuffle stays a bijection (visits every observer exactly once) regardless
// of item count.
const dense_index_shuffle_stride: usize = 97;

// Smallest stride >= `dense_index_shuffle_stride` that is coprime with
// `pair_count`, so `(step * stride) % pair_count` is a bijection over
// `0..pair_count` for any positive `pair_count` (not just ones coprime with
// the preferred stride). Search is bounded: `pair_count` consecutive integers
// always contain one coprime with `pair_count` (residue 1 alone guarantees
// this), so the loop below always terminates within `pair_count` steps. Runs
// once at fixture-build time, not on a measured path.
fn shuffleStrideFor(pair_count: usize) usize {
    if (pair_count <= 1) return 1;
    var stride = dense_index_shuffle_stride;
    while (std.math.gcd(stride, pair_count) != 1) : (stride += 1) {}
    return stride;
}

// Same population, geometry, and blocked-tile pattern as `createFixture`
// (isolating one variable, same as `perception-los-dense`'s own module-doc
// convention), but built in two phases so `perception_dense_index` (the
// `PerceptionStore` row an observer lands in, assigned in `setAiPerception`
// call order -- see `data_system/system.zig`'s `setAiPerception`) is
// decorrelated from the gather row order `i` (which follows entity/pair
// creation order -- see `gatherPerceptionData`'s doc comment). Phase 1
// creates every pair exactly as `createFixture` does but withholds
// `setAiPerception`; phase 2 calls it for every observer in a fixed
// reversible permutation (`(step * shuffleStrideFor(pair_count)) %
// pair_count`) instead of creation order. This lets two entities whose gather
// rows fall in *different* worker ranges land in numerically close (same-cache-line)
// `perception_dense_index` slots, so `computeOneAgent`'s unconditional
// scatter into `job.perception_slice` (see that function) can be compared
// threaded-vs-serial against `createFixture`'s today-correlated order. See
// this module's doc comment for the measured result.
fn createDecorrelatedFixture(allocator: std.mem.Allocator, io: std.Io, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const tree = try requireTile(&meta, "tree_0");

    const tile_size = meta.tileSize();
    const bounds = @as(f32, @floatFromInt(world_tiles_side)) * tile_size;
    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, bounds, bounds);
    errdefer world.deinit();

    const observer_offset_x = tile_size * observer_offset_tile_fraction;
    const pair_count = count / 2;
    const shuffle_stride = shuffleStrideFor(pair_count);
    std.debug.assert(pair_count == 0 or std.math.gcd(shuffle_stride, pair_count) == 1);

    var observers = std.ArrayList(EntityId).empty;
    defer observers.deinit(allocator);
    try observers.ensureTotalCapacity(allocator, pair_count);

    var pair_index: usize = 0;
    while (pair_index < pair_count) : (pair_index += 1) {
        const gx = @as(f32, @floatFromInt(pair_index % pair_grid_columns)) * tile_size;
        const gy = @as(f32, @floatFromInt(pair_index / pair_grid_columns)) * tile_size;
        _ = try addAgent(&data, gx, gy, 0, 0, .hostile);
        // Same shape as `addObserver` but withholds `setAiPerception` until
        // phase 2's shuffled pass below.
        const observer = try addAgent(&data, gx + observer_offset_x, gy, observer_facing_velocity_x, 0, .player);
        observers.appendAssumeCapacity(observer);

        if (pair_index % blocked_pair_period == blocked_pair_period - 1) {
            const cell = world.cellContaining(gx, gy) orelse continue;
            _ = try world.addSparseTile(0, cell.x, cell.y, tree, 0, .obstacle);
        }
    }

    var step: usize = 0;
    while (step < pair_count) : (step += 1) {
        const source = (step * shuffle_stride) % pair_count;
        try data.setAiPerception(observers.items[source], .{ .vision_range = observer_vision_range });
    }

    return .{ .data = data, .world = world };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseImpl(allocator, io, options, case, item_count, buildDefaultFixture);
}

pub fn runLosDenseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseImpl(allocator, io, options, case, item_count, buildLosDenseFixture);
}

pub fn runScatteredDenseIndexCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseImpl(allocator, io, options, case, item_count, buildScatteredDenseIndexFixture);
}

fn buildDefaultFixture(allocator: std.mem.Allocator, io: std.Io, item_count: usize) !Fixture {
    return createFixture(allocator, io, item_count, 0);
}

fn buildLosDenseFixture(allocator: std.mem.Allocator, io: std.Io, item_count: usize) !Fixture {
    return createFixture(allocator, io, item_count, los_dense_extra_sparse_tiles);
}

fn buildScatteredDenseIndexFixture(allocator: std.mem.Allocator, io: std.Io, item_count: usize) !Fixture {
    return createDecorrelatedFixture(allocator, io, item_count);
}

fn runCaseImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: suite.Options,
    case: suite.BenchmarkCase,
    item_count: usize,
    buildFixture: *const fn (std.mem.Allocator, std.Io, usize) anyerror!Fixture,
) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try buildFixture(allocator, io, item_count);
    defer fixture.deinit();

    var system = PerceptionSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, perception_range_alignment_items)) |tuner| {
        system.compute_tuner = tuner;
    }

    var events = SimulationEvents.init(allocator);
    defer events.deinit();

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    // Positions never change across iterations (this bench measures the
    // steady-state gather/FOV/LOS cost, not movement), so the shared spatial
    // index is built once, outside every timed/warmup/settle call -- mirrors
    // `ai.zig`'s own bench, which times only `system.update`/`updateSerial`.
    var spatial_sys = SpatialIndexSystem.init(allocator);
    defer spatial_sys.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();
    _ = try spatial_sys.buildSerial(ai_slice, movement_slice, &fixture.data, .{});
    const spatial_view = spatial_sys.view();

    for (0..options.warmup_iterations) |_| {
        _ = try runOnce(&system, &fixture, spatial_view, &events, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.compute_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&system, &fixture, spatial_view, &events, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.compute_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    // Only the first measured call ever produces invalid->valid transitions
    // (nothing moves between iterations after that, so later calls settle to
    // zero perceived/lost -- see the module doc); `last_stats` is still the
    // right per-iteration steady-state snapshot for `sensed_count`/
    // `los_checks`/`los_blocked`/`nearest_threat_found_count`, which are
    // recomputed identically every step regardless of transition state.
    var last_stats = PerceptionStats{};
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, spatial_view, &events, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.batch);
    }

    var stats = accumulator.finish();
    stats.output_count = last_stats.nearest_threat_found_count;
    stats.candidate_pairs = last_stats.los_checks;
    stats.sample_count = last_stats.sensed_count;
    stats.deferred_count = last_stats.los_blocked;
    stats.fallback_deferred_count = last_stats.perceived_events + last_stats.lost_events;
    stats.cache_evictions = last_stats.dropped_events;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.compute_tuner.report(), settled_before_measurement);
    }
    return stats;
}

fn runOnce(
    system: *PerceptionSystem,
    fixture: *Fixture,
    spatial_view: SpatialIndexView,
    events: *SimulationEvents,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) !PerceptionStats {
    events.clearRetainingCapacity();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();
    if (!case.usesThreadSystem()) {
        return try system.updateSerial(ai_slice, movement_slice, spatial_view, &fixture.world, &fixture.data, events, .{});
    }

    return try system.update(ai_slice, movement_slice, spatial_view, &fixture.world, &fixture.data, events, thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(perception_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, perception_range_alignment_items);
}

// Which dirty footprint `runCacheEditCaseImpl` reports to
// `PerceptionSystem.reactToPostCommitPerceptionEvents` before every measured
// iteration -- see `cache_full_rebuild_group`/`cache_patch_group`'s doc
// comment for what each forces `ensureLevelBlockedCache` to do.
const CacheEditKind = enum { full_rebuild_forced, single_tile_patch };

pub fn runCacheFullRebuildCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCacheEditCaseImpl(allocator, io, options, case, item_count, .full_rebuild_forced);
}

pub fn runCachePatchCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCacheEditCaseImpl(allocator, io, options, case, item_count, .single_tile_patch);
}

// Reports one synthetic `world_obstacle_changed` event to `system` for
// `world`'s level 0 -- a whole-level rect (forces the over-threshold
// full-rebuild fallback) or a single cell (forces a scoped patch), per
// `edit_kind`. The event is synthetic (never backed by an actual world tile
// edit): only the dirty-tracking bookkeeping and its downstream
// skip/patch/rebuild decision are under test here, not tile-edit correctness
// (that is the parity tests' job, in `systems/perception.zig`).
fn markCacheEdit(system: *PerceptionSystem, frame: *SimulationFrame, world: *const WorldSystem, edit_kind: CacheEditKind) !void {
    frame.events.clearRetainingCapacity();
    const max_x_exclusive: u16 = switch (edit_kind) {
        .full_rebuild_forced => world.width,
        .single_tile_patch => 1,
    };
    const max_y_exclusive: u16 = switch (edit_kind) {
        .full_rebuild_forced => world.height,
        .single_tile_patch => 1,
    };
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{
        .level = 0,
        .min_x = 0,
        .min_y = 0,
        .max_x_exclusive = max_x_exclusive,
        .max_y_exclusive = max_y_exclusive,
    } } });
    try system.reactToPostCommitPerceptionEvents(frame, world);
}

fn runCacheEditCaseImpl(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: suite.Options,
    case: suite.BenchmarkCase,
    item_count: usize,
    edit_kind: CacheEditKind,
) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try buildDefaultFixture(allocator, io, item_count);
    defer fixture.deinit();

    var system = PerceptionSystem.init(allocator);
    defer system.deinit();
    if (suite.adaptiveTunerForCase(case, perception_range_alignment_items)) |tuner| {
        system.compute_tuner = tuner;
    }

    var events = SimulationEvents.init(allocator);
    defer events.deinit();
    var frame = SimulationFrame.init(allocator);
    defer frame.deinit();

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    var spatial_sys = SpatialIndexSystem.init(allocator);
    defer spatial_sys.deinit();
    const ai_slice = fixture.data.aiAgentSliceConst();
    const movement_slice = fixture.data.movementBodySliceConst();
    _ = try spatial_sys.buildSerial(ai_slice, movement_slice, &fixture.data, .{});
    const spatial_view = spatial_sys.view();

    for (0..options.warmup_iterations) |_| {
        try markCacheEdit(&system, &frame, &fixture.world, edit_kind);
        _ = try runOnce(&system, &fixture, spatial_view, &events, if (threads) |*thread_system| thread_system else null, case);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!system.compute_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            try markCacheEdit(&system, &frame, &fixture.world, edit_kind);
            _ = try runOnce(&system, &fixture, spatial_view, &events, if (threads) |*thread_system| thread_system else null, case);
        }
    }
    const settled_before_measurement = if (case.adaptive) system.compute_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var last_stats = PerceptionStats{};
    for (0..options.iterations) |_| {
        try markCacheEdit(&system, &frame, &fixture.world, edit_kind);
        const start_ns = suite.nowNs(io);
        last_stats = try runOnce(&system, &fixture, spatial_view, &events, if (threads) |*thread_system| thread_system else null, case);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), last_stats.batch);
    }

    var stats = accumulator.finish();
    stats.output_count = last_stats.nearest_threat_found_count;
    stats.candidate_pairs = last_stats.los_checks;
    stats.sample_count = last_stats.sensed_count;
    stats.deferred_count = last_stats.los_blocked;
    stats.fallback_deferred_count = last_stats.perceived_events + last_stats.lost_events;
    stats.cache_evictions = last_stats.dropped_events;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(system.compute_tuner.report(), settled_before_measurement);
    }
    return stats;
}
