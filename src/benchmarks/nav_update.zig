// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Measures the cost of an incremental nav abstract-graph update on a large multi-level world.
//! Each case toggles a dirty footprint of `item_count` tiles open then blocked; with the
//! dirty-bounded rebuild only the chunks the footprint touches (plus their border neighbors)
//! are patched, so cost tracks the dirty region, not the level size. Every count is a dig-storm
//! footprint sized to sweep an increasing dirty-chunk count, so each case traces a serial-vs-
//! threaded SCALING CURVE through the system's threaded remask/patch stages. Two variants give
//! two curves with different dig-storm SHAPES: `multichunk` is one compact excavation (cells in a
//! contiguous border-straddling block; curve over cluster size), `scattered` is one cell per
//! distinct chunk (many diggers spread across the map; curve over dirty-chunk count). The fixture is
//! built once outside the timed region; each timed toggle returns the world to its start state so
//! the dirty set stays bounded. Debug is the real test; release scales the curve even higher via
//! the same adaptive tuner.
//!
//! A third group, `nav-update-entity-obstacles`, compares the OLD whole-level-dirty reaction to
//! an entity-driven static-obstacle change (markNavLevelDirty) against the NEW localized reaction
//! (markNavObstacleRectDirty, resolving the changed entity's world-space rect to a nav-cell span)
//! at the same obstacle count. Its serial-direct row measures the OLD path (whole-level cost does
//! not depend on thread config); every other row measures the NEW path across that case's
//! threading config, so each row's vs_serial column reads directly as localized-vs-whole-level
//! speedup.
//!
//! A fourth group, `nav-update-links`, measures the runtime LevelLink reaction (Slice 64E): a
//! batch of `item_count` new ramp links (one per distinct chunk, interior cell, levels 1<->0)
//! folded in through the link cursor (fixed interior slot + both endpoint levels dirtied) and the
//! buffered incremental apply. The 8-link row is the same dirty-footprint order as the scattered
//! group's 16-chunk row (8 chunks on each of 2 levels).
//!
//! A fifth pair, `nav-update-cave-in` / `nav-update-cave-in-warm` (Slice 64F), times one step
//! that carves a 4x4-chunk lattice on `item_count` levels of a 1024x1024-tile, 32-level world:
//! cold outgrows the windows and repacks each caved level, warm reuses grown windows. Cold minus
//! warm is the repack cost.

const std = @import("std");
const math = @import("../core/math.zig");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const ObstacleWorldRect = @import("../game/data_system.zig").ObstacleWorldRect;
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const NavCellEdit = @import("../game/systems/pathfinding.zig").NavCellEdit;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const PathfindingCapacity = @import("../game/systems/pathfinding.zig").PathfindingCapacity;
const NavUpdateStats = @import("../game/systems/pathfinding.zig").NavUpdateStats;
const autoSizedMaxNavMemoryBytes = @import("../game/systems/pathfinding.zig").autoSizedMaxNavMemoryBytes;
const TileId = @import("../game/world_system.zig").TileId;
const suite = @import("suite.zig");

fn requireTile(meta: *const world_tileset_meta.WorldTilesetMeta, name: []const u8) !TileId {
    return (meta.tileByName(name) orelse return error.TileNotFound).id;
}

// World side length in nav cells/tiles. The incremental update is dirty-bounded and provably
// world-size-independent (see nav_graph tests), so the bench world only needs to hold the
// largest footprint plus a few chunks of margin — NOT a full game world. The fixture is built
// ONCE per variant and reused, so the world only has to be big enough to hold the largest
// dig-storm footprint at its anchor: 256 tiles = 16x16 abstract chunks, room for the 128x128
// (16384-cell) footprint centered at the world midpoint (tile 128) with margin.
const world_tiles: u16 = 256;
const tile_size: f32 = 32.0;
const world_bounds: f32 = @as(f32, @floatFromInt(world_tiles)) * tile_size;

// Abstract chunk side in tiles, sourced from the nav build's default so the scattered footprint
// stays one dirty cell per distinct chunk (its item_count equals the dirty-chunk count) even if
// the default changes.
const nav_chunk_tiles: u16 = @import("../game/systems/pathfinding.zig").default_nav_chunk_tiles;
const chunks_per_side: usize = @as(usize, world_tiles) / nav_chunk_tiles;
const total_chunks: usize = chunks_per_side * chunks_per_side;

// Dirty cells fed to one `applyNavUpdates` batch (the footprint). Every count is a dig-storm
// tier (many actors digging at once) sized to sweep an increasing dirty-chunk count, so the
// threaded remask/patch stages trace a full serial-vs-threaded SCALING CURVE: with 16-tile
// chunks the footprints span roughly 4 -> 9 -> 20 -> 36 -> 72 chunks, so the adaptive tuner
// engages more workers as the batch grows. Sub-256 footprints are intentionally omitted — they
// never trip the tuner into threading (it correctly keeps a single-tile dig inline) and a tiny
// footprint's cost is dominated by the fixed per-update overhead (the serial link-edge rebuild),
// not the incremental work, so they add no signal to the threading curve. Counts stay bounded so
// the Debug bench (the default) completes in reasonable time; the adaptive tuner scales the
// threaded stages in Debug, and further in release. Cost tracks the dirty-chunk footprint.
const update_counts = [_]usize{ 256, 1024, 4096, 8192, 16384 };

// The threaded stages only pay off once a batch spans many chunks; the smallest footprint is at
// this floor. Kept as an explicit guard so the threaded cases never run a footprint the tuner
// would just keep inline (which would report a no-op threaded row).
const threaded_min_cells: usize = 256;

// Nav work items are independent chunks with no SIMD-lane grouping, so a chunk-per-range is the
// natural alignment for both threaded stages.
const nav_range_alignment_items: usize = 1;

// Fixed range size for a NON-adaptive control case, so the adaptive rows can be compared against
// fixed-partition controls. Adaptive cases return null (the tuner sizes ranges). Mirrors the
// collision bench's benchmarkItemsPerRange so all benches share the same control scheme.
fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(nav_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, nav_range_alignment_items);
}

const Variant = enum { scattered, multichunk };

// Scattered counts are dirty-CHUNK counts (one cell per distinct chunk), capped at the world's
// chunk total (256). Its curve is parameterized by how many chunks the dig-storm touches — the
// "many NPCs digging all over the map" case that maximizes the threaded fan-out per cell.
const scattered_counts = [_]usize{ 16, 32, 64, 128, 256 };

pub const group = suite.BenchmarkGroup{
    .name = "nav-update-scattered",
    .defaultItemCounts = scatteredItemCounts,
    .runCase = runScatteredCase,
};

pub const multichunk_group = suite.BenchmarkGroup{
    .name = "nav-update-multichunk",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runMultichunkCase,
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    _ = profile;
    return &update_counts;
}

pub fn scatteredItemCounts(profile: suite.Profile) []const usize {
    _ = profile;
    return &scattered_counts;
}

pub fn runScatteredCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .scattered);
}

pub fn runMultichunkCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .multichunk);
}

// The world + nav system are identical for every case and count of a variant (only the dirty
// footprint's anchor/size changes), and the incremental update is provably world-size-independent,
// so the EXPENSIVE O(world^2) rebuild is done ONCE per variant and reused across every case/count
// (see sharedFixture). Only `edits` is regenerated per count; the toggle re-derives nav state.
const Fixture = struct {
    // Stored at build time (not passed again to deinit): this is a module-global fixture
    // freed once at the end of a whole bench run by deinitCaches, potentially far from
    // where it was built, so trusting a caller to re-supply the SAME allocator instance
    // is an avoidable mismatched alloc/free risk.
    allocator: std.mem.Allocator,
    data: DataSystem,
    world: WorldSystem,
    system: PathfindingSystem,
    obstacle_layer: usize,
    grass: TileId,
    tree: TileId,
    // Tiles toggled each timed iteration: the current count's footprint on level 1.
    edits: std.ArrayList(NavCellEdit),

    fn deinit(self: *Fixture) void {
        self.edits.deinit(self.allocator);
        self.system.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

// One reusable fixture per variant, built lazily on first use and freed by deinitCaches at the
// end of the run. The suite drives counts ascending and each variant's footprints are nested at a
// stable anchor, so a later (larger) count's open-half toggle clears any prior count's blocked
// cells — no per-count world reset needed.
// OWNERSHIP: this module-global owns heap fixtures across the whole run; any entry point that
// drives these cases (runner.main, or a test/harness calling runCase directly) MUST call
// deinitCaches afterward or the fixtures leak.
var shared_fixtures: [@typeInfo(Variant).@"enum".field_names.len]?Fixture = .{ null, null };

pub fn deinitCaches() void {
    for (&shared_fixtures) |*slot| {
        if (slot.*) |*fixture| fixture.deinit();
        slot.* = null;
    }
    if (entity_obstacle_fixture) |*fixture| fixture.deinit();
    entity_obstacle_fixture = null;
    if (links_fixture) |*fixture| fixture.deinit();
    links_fixture = null;
    if (cave_in_fixture) |*fixture| fixture.deinit();
    cave_in_fixture = null;
}

// Returns the variant's reusable fixture, building it once (world + nav sized for the maximum
// threaded participant count, so every case fits) on first use.
fn sharedFixture(allocator: std.mem.Allocator, io: std.Io, variant: Variant) !*Fixture {
    const slot = &shared_fixtures[@backingInt(variant)];
    if (slot.* == null) {
        var probe = try ThreadSystem.init(allocator, io, .{});
        const max_participants = probe.participantSlotCount();
        probe.deinit();
        slot.* = try buildSharedFixture(allocator, io, max_participants);
    }
    return &slot.*.?;
}

// Smallest square side that holds `cells` tiles; the footprint is filled row-major up to
// `cells` so the batch edit count matches the requested item count exactly.
fn squareSide(cells: usize) u16 {
    var side: u16 = 1;
    while (@as(usize, side) * @as(usize, side) < cells) side += 1;
    return side;
}

// Builds the reusable world + nav system (all cells open), sized for `participant_count` so any
// threaded case fits. The dig footprint is set later per count by setFootprint.
fn buildSharedFixture(allocator: std.mem.Allocator, io: std.Io, participant_count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const grass = try requireTile(&meta, "grass");
    const tree = try requireTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, world_bounds, world_bounds);
    errdefer world.deinit();
    // Three levels (surface plus two underground floors); the dig happens on level 1.
    _ = try world.addLevel(0);
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    _ = try world.addDenseLayer(2, 0, .floor, grass);
    const obstacle_layer = try world.addDenseLayer(1, 0, .obstacle, grass);

    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    // Size the per-participant nav scratch for the largest threaded case (workers + main) so the
    // threaded stages never fall back to serial for lack of scratch slots.
    try system.reserve(.{ .worker_participant_count = @max(@as(usize, 1), participant_count) });
    try system.rebuildStaticNavGridWithWorld(&data, &world, world_bounds, world_bounds, tile_size, null);

    return .{
        .allocator = allocator,
        .data = data,
        .world = world,
        .system = system,
        .obstacle_layer = obstacle_layer,
        .grass = grass,
        .tree = tree,
        .edits = .empty,
    };
}

// Regenerates the current count's dirty footprint on level 1. The two variants apply different
// dig-storm SHAPES so each traces a distinct scaling-under-load curve (cost is per-chunk, since the
// remask is whole-chunk, so shape matters more than position):
//   - scattered: one dirty cell per distinct chunk (chunk centers, row-major), so `cells` == the
//     dirty-chunk count. Maximizes chunks (and thus threaded fan-out) per cell — many diggers
//     spread across the map. Capped at the world's chunk total.
//   - multichunk: a compact square block CENTERED on a chunk border at the world midpoint, so it
//     maximally straddles chunk boundaries (worst-case neighbor fan-out). One big excavation.
// Both keep their footprints nested as the count grows (scattered shares the row-major prefix,
// multichunk shares the center), so the ascending-count toggle re-derivation needs no per-count
// world reset. The world is not mutated here — the toggle establishes the open/blocked state.
fn setFootprint(fixture: *Fixture, allocator: std.mem.Allocator, variant: Variant, cells: usize) !void {
    fixture.edits.clearRetainingCapacity();
    switch (variant) {
        .scattered => {
            const n = @min(cells, total_chunks);
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const cx = i % chunks_per_side;
                const cy = i / chunks_per_side;
                const x: u16 = @intCast(cx * nav_chunk_tiles + nav_chunk_tiles / 2);
                const y: u16 = @intCast(cy * nav_chunk_tiles + nav_chunk_tiles / 2);
                try fixture.edits.append(allocator, .{ .level = 1, .x = x, .y = y });
            }
        },
        .multichunk => {
            // Capped at the world's full tile area: a centered side-length-`side` block only
            // stays in bounds while side <= world_tiles (center sits at exactly world_tiles/2),
            // so an --items override large enough to demand a bigger square would otherwise
            // walk x/y past the world edge instead of erroring loudly at the world write.
            const max_multichunk_cells: usize = @as(usize, world_tiles) * @as(usize, world_tiles);
            const n = @min(cells, max_multichunk_cells);
            const side = squareSide(n);
            // world_tiles/2 is a multiple of chunk_tiles, i.e. a chunk boundary; centering the
            // block there keeps it border-straddling at every size.
            const center: u16 = world_tiles / 2;
            const ax: u16 = center -| side / 2;
            const ay: u16 = center -| side / 2;
            var placed: usize = 0;
            var dy: u16 = 0;
            outer: while (placed < n) : (dy += 1) {
                var dx: u16 = 0;
                while (dx < side) : (dx += 1) {
                    if (placed >= n) break :outer;
                    try fixture.edits.append(allocator, .{ .level = 1, .x = ax + dx, .y = ay + dy });
                    placed += 1;
                }
            }
        },
    }
    // Untimed: mirror production, where the pipeline reserves the dirty buffers to its
    // structural-stage event bound before any step marks them.
    try fixture.system.reserveNavDirty(fixture.edits.items.len);
}

// One open->blocked toggle of the edited tiles: the first half opens them (grass), the second
// re-blocks them (tree), so a toggle ENDS with the footprint blocked, not back at the all-open
// start state. The dirty set still stays bounded because each variant's footprints are nested at
// a stable anchor, so a later (larger) count's open half clears any prior count's blocked cells.
// Each half is one nav update, so a toggle is two incremental updates. Only the nav-update call is
// timed (the world tile writes and the dirty-cell marking that set up each half are excluded),
// so the measurement reflects the abstract-graph patch cost the task targets. A non-null
// thread_system routes through the threaded buffered path (markNavDirty + applyBufferedNavUpdates);
// null runs the serial slice path.
//
// The two halves are structurally ASYMMETRIC: the block half opens cells back to grass (drops
// obstacle edges, re-floods regions) while the unblock half re-blocks them (adds obstacles,
// prunes connectivity), so they touch different amounts of the chunk graph. The caller divides
// the returned sum by 2, so the reported per-update mean is the AVERAGE of the two — a blended
// block+unblock cost, not either half in isolation. Returns the summed elapsed of both halves.
fn runToggle(fixture: *Fixture, io: std.Io, thread_system: ?*ThreadSystem) !u64 {
    var elapsed: u64 = 0;
    for (fixture.edits.items) |edit| _ = try fixture.world.setDenseTile(fixture.obstacle_layer, edit.x, edit.y, fixture.grass);
    elapsed += try timeNavUpdate(fixture, io, thread_system);
    for (fixture.edits.items) |edit| _ = try fixture.world.setDenseTile(fixture.obstacle_layer, edit.x, edit.y, fixture.tree);
    elapsed += try timeNavUpdate(fixture, io, thread_system);
    return elapsed;
}

// Times one incremental nav update over the fixture's footprint. The marking pass (clear +
// markNavDirty) is setup, excluded from the timed region, matching how production buffers edits
// before the patch.
fn timeNavUpdate(fixture: *Fixture, io: std.Io, thread_system: ?*ThreadSystem) !u64 {
    if (thread_system) |ts| {
        fixture.system.clearNavDirty();
        for (fixture.edits.items) |edit| try fixture.system.markNavDirty(edit.level, edit.x, edit.y);
        const t0 = suite.nowNs(io);
        _ = try fixture.system.applyBufferedNavUpdates(&fixture.data, &fixture.world, ts);
        return suite.elapsedNs(t0, suite.nowNs(io));
    }
    const t0 = suite.nowNs(io);
    _ = try fixture.system.applyNavUpdates(&fixture.data, &fixture.world, fixture.edits.items);
    return suite.elapsedNs(t0, suite.nowNs(io));
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, variant: Variant) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    // Scattered footprints are one cell per chunk, so every count already spans many chunks and is
    // worth threading; compact footprints need enough cells to span several chunks first, so they
    // skip below the threaded floor (the serial rows already report that small-cluster cost).
    const min_thread_cells: usize = if (variant == .multichunk) threaded_min_cells else 0;
    if (case.usesThreadSystem() and item_count < min_thread_cells) {
        return suite.RunStats.skipped("footprint too small to thread");
    }

    // A per-case thread system caps the worker pool for this case; the tuner decides how many of
    // it to use. Cheap to spawn relative to the (now one-time) nav rebuild.
    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    // Reuse the variant's world + nav system (built once); only the footprint changes per count.
    const fixture = try sharedFixture(allocator, io, variant);
    try setFootprint(fixture, allocator, variant, item_count);
    // Reset both stage tuners per case so a prior case's training never leaks into this one (a
    // fresh system would have fresh tuners). Adaptive cases use the configured probing tuner.
    if (suite.adaptiveTunerForCase(case, nav_range_alignment_items)) |tuner| {
        fixture.system.nav_remask_tuner = tuner;
        fixture.system.nav_patch_tuner = suite.adaptiveTunerForCase(case, nav_range_alignment_items).?;
    } else {
        fixture.system.nav_remask_tuner = AdaptiveWorkTuner.init(.{});
        fixture.system.nav_patch_tuner = AdaptiveWorkTuner.init(.{});
    }
    // Drive the threaded stages with this case's control config: adaptive cases let the tuner
    // size ranges; fixed control cases pin a fixed partition so the tuner is measured against them.
    fixture.system.nav_thread_adaptive = case.adaptive;
    fixture.system.nav_thread_items_per_range = benchmarkItemsPerRange(case);

    // Warm so the abstract buffers are at high-water capacity (the steady path is
    // allocation-free) and the tuners have trained an inline baseline before timing.
    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| _ = try runToggle(fixture, io, thread_ptr);

    // Let the adaptive tuners settle on a stable profile before measuring (as collision/
    // pathfinding do), so a still-learning tuner does not flip inline<->threaded mid-run and
    // skew the mean. Both nav stages have their own tuner, so both must settle.
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while ((!fixture.system.nav_remask_tuner.isSettled() or !fixture.system.nav_patch_tuner.isSettled()) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runToggle(fixture, io, thread_ptr);
        }
    }
    const remask_settled = if (case.adaptive) fixture.system.nav_remask_tuner.isSettled() else false;
    const patch_settled = if (case.adaptive) fixture.system.nav_patch_tuner.isSettled() else false;

    // Throughput is over the cells ACTUALLY edited, not the requested count: the scattered
    // variant caps its footprint at the world chunk total, so a requested count above the cap
    // edits fewer cells and the denominator must match or cells/sec is overstated.
    const edited_cells = fixture.edits.items.len;
    var accumulator = suite.StatsAccumulator.init(edited_cells);
    for (0..options.iterations) |_| {
        // One toggle is two timed nav updates over the full footprint; record their AVERAGE as
        // the per-update batch cost (items_per_second then reads as dirty cells per second). The
        // two halves (block vs unblock) are asymmetric, so this mean blends them by design — see
        // runToggle.
        const elapsed = try runToggle(fixture, io, thread_ptr);
        accumulator.record(elapsed / 2, suite.serialBatch(edited_cells, 1));
    }
    var stats = accumulator.finish();
    // Report the worker profile each stage actually used so threaded rows are not mistaken for
    // serial ones (a tuner may keep a borderline footprint inline). Primary = the remask/re-flood
    // stage (runs first and dominates at scale); secondary = the abstract chunk patch.
    stats.batch = suite.batchSummaryFromBatch(fixture.system.graph.last_remask_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(fixture.system.graph.last_patch_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(fixture.system.nav_remask_tuner.report(), remask_settled);
        stats.secondary_work_tuning = suite.workTuningSummary(fixture.system.nav_patch_tuner.report(), patch_settled);
    }
    return stats;
}

// ----------------------------------------------------------------------------
// Entity-driven obstacle invalidation: OLD whole-level-dirty path vs NEW localized path.
// ----------------------------------------------------------------------------

// Obstacle counts share `scattered_counts`' rationale (one obstacle per distinct chunk,
// capped at the world's chunk total) so the NEW path's chunk-fan-out scales the same way
// the scattered tile-edit variant does.
const entity_obstacle_counts = scattered_counts;

pub const entity_obstacle_group = suite.BenchmarkGroup{
    .name = "nav-update-entity-obstacles",
    .defaultItemCounts = entityObstacleItemCounts,
    .runCase = runEntityObstacleCase,
};

pub fn entityObstacleItemCounts(profile: suite.Profile) []const usize {
    _ = profile;
    return &entity_obstacle_counts;
}

// One static-obstacle collision body (movement_body + collision_bounds + collision_response)
// candidate per distinct chunk. `rects` holds every candidate's precomputed stable world-space
// position; `entities` holds the ids of the obstacles CURRENTLY LIVE in `data` (a prefix of
// `rects`, grown to the requested count by `ensureLiveObstacleCount`, never shrunk — item counts
// run ascending). The live count is always exactly the obstacle count under test, since a
// whole-level static-coverage refresh costs O(cells x live bodies).
const EntityObstacleFixture = struct {
    // Stored at build time — see Fixture's matching field for why.
    allocator: std.mem.Allocator,
    data: DataSystem,
    world: WorldSystem,
    system: PathfindingSystem,
    entities: std.ArrayList(EntityId),
    rects: std.ArrayList(ObstacleWorldRect),

    fn deinit(self: *EntityObstacleFixture) void {
        self.entities.deinit(self.allocator);
        self.rects.deinit(self.allocator);
        self.system.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

// OWNERSHIP: mirrors shared_fixtures above — freed by deinitCaches, which any entry point
// driving these cases must call.
var entity_obstacle_fixture: ?EntityObstacleFixture = null;

fn sharedEntityObstacleFixture(allocator: std.mem.Allocator, io: std.Io) !*EntityObstacleFixture {
    if (entity_obstacle_fixture == null) {
        var probe = try ThreadSystem.init(allocator, io, .{});
        const max_participants = probe.participantSlotCount();
        probe.deinit();
        entity_obstacle_fixture = try buildEntityObstacleFixture(allocator, io, max_participants);
    }
    return &entity_obstacle_fixture.?;
}

fn buildEntityObstacleFixture(allocator: std.mem.Allocator, io: std.Io, participant_count: usize) !EntityObstacleFixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, world_bounds, world_bounds);
    errdefer world.deinit();

    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(.{ .worker_participant_count = @max(@as(usize, 1), participant_count) });
    // No obstacle dense layer here: every obstacle is an entity-driven static collision body,
    // so the grid starts fully open; obstacles are only ever created up to the count under
    // test (see ensureLiveObstacleCount), never a larger background population.
    try system.rebuildStaticNavGridWithWorld(&data, &world, world_bounds, world_bounds, tile_size, null);

    const max_count = entity_obstacle_counts[entity_obstacle_counts.len - 1];
    var entities: std.ArrayList(EntityId) = .empty;
    errdefer entities.deinit(allocator);
    var rects: std.ArrayList(ObstacleWorldRect) = .empty;
    errdefer rects.deinit(allocator);
    try entities.ensureTotalCapacity(allocator, max_count);
    try rects.ensureTotalCapacity(allocator, max_count);

    const obstacle_size: f32 = 8.0;
    var i: usize = 0;
    while (i < max_count) : (i += 1) {
        const cx = i % chunks_per_side;
        const cy = i / chunks_per_side;
        const x: f32 = @as(f32, @floatFromInt(cx * nav_chunk_tiles + nav_chunk_tiles / 2)) * tile_size;
        const y: f32 = @as(f32, @floatFromInt(cy * nav_chunk_tiles + nav_chunk_tiles / 2)) * tile_size;
        rects.appendAssumeCapacity(.{ .min_x = x, .min_y = y, .max_x = x + obstacle_size, .max_y = y + obstacle_size });
    }
    // Mirror production's structural-stage reservation: one obstacle event per rect.
    try system.reserveNavDirty(max_count);

    return .{ .allocator = allocator, .data = data, .world = world, .system = system, .entities = entities, .rects = rects };
}

// Grows the live obstacle population to exactly `n` (never shrinks — item counts run
// ascending), creating each new obstacle at its precomputed rect and folding it into the grid
// via the NEW localized path. Outside any timed region.
fn ensureLiveObstacleCount(fixture: *EntityObstacleFixture, n: usize) !void {
    if (n <= fixture.entities.items.len) return;
    const start = fixture.entities.items.len;
    for (fixture.rects.items[start..n]) |rect| {
        const entity = try createStaticObstacle(&fixture.data, .{ .x = rect.min_x, .y = rect.min_y }, rect.max_x - rect.min_x);
        fixture.entities.appendAssumeCapacity(entity);
        try fixture.system.markNavObstacleRectDirty(0, rect);
    }
    _ = try fixture.system.applyBufferedNavUpdates(&fixture.data, &fixture.world, null);
}

fn createStaticObstacle(data: *DataSystem, position: math.Vec2, size: f32) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = size, .y = size } });
    try data.setCollisionResponse(entity, .{ .mobility = .static });
    return entity;
}

fn destroyObstacles(fixture: *EntityObstacleFixture, n: usize) void {
    for (fixture.entities.items[0..n]) |entity| _ = fixture.data.destroyEntity(entity);
}

// Recreates the first `n` obstacles at their stable rects, rewriting `entities` with the new
// ids so the next destroy pass targets live entities again.
fn recreateObstacles(fixture: *EntityObstacleFixture, n: usize) !void {
    for (fixture.entities.items[0..n], fixture.rects.items[0..n]) |*entity, rect| {
        entity.* = try createStaticObstacle(&fixture.data, .{ .x = rect.min_x, .y = rect.min_y }, rect.max_x - rect.min_x);
    }
}

const EntityObstacleTiming = struct { ns: u64, chunks_patched: usize };

// Times destroying `n` existing obstacles via the OLD whole-level-dirty path (markNavLevelDirty
// + applyBufferedNavUpdates), then restores them via the same path so the next iteration starts
// from the identical baseline. Only the destroy-phase update is timed.
fn timeOldPathDestroy(fixture: *EntityObstacleFixture, io: std.Io, n: usize, thread_system: ?*ThreadSystem) !EntityObstacleTiming {
    destroyObstacles(fixture, n);
    try fixture.system.markNavLevelDirty(0);
    const t0 = suite.nowNs(io);
    const stats = try fixture.system.applyBufferedNavUpdates(&fixture.data, &fixture.world, thread_system);
    const ns = suite.elapsedNs(t0, suite.nowNs(io));
    try recreateObstacles(fixture, n);
    try fixture.system.markNavLevelDirty(0);
    _ = try fixture.system.applyBufferedNavUpdates(&fixture.data, &fixture.world, thread_system);
    return .{ .ns = ns, .chunks_patched = stats.chunks_patched };
}

// Times destroying `n` existing obstacles via the NEW localized path (markNavObstacleRectDirty
// per destroyed obstacle's rect + applyBufferedNavUpdates), then restores them the same way.
// Mirrors timeOldPathDestroy exactly except for the marking mechanism.
fn timeNewPathDestroy(fixture: *EntityObstacleFixture, io: std.Io, n: usize, thread_system: ?*ThreadSystem) !EntityObstacleTiming {
    destroyObstacles(fixture, n);
    for (fixture.rects.items[0..n]) |rect| try fixture.system.markNavObstacleRectDirty(0, rect);
    const t0 = suite.nowNs(io);
    const stats = try fixture.system.applyBufferedNavUpdates(&fixture.data, &fixture.world, thread_system);
    const ns = suite.elapsedNs(t0, suite.nowNs(io));
    try recreateObstacles(fixture, n);
    for (fixture.rects.items[0..n]) |rect| try fixture.system.markNavObstacleRectDirty(0, rect);
    _ = try fixture.system.applyBufferedNavUpdates(&fixture.data, &fixture.world, thread_system);
    return .{ .ns = ns, .chunks_patched = stats.chunks_patched };
}

pub fn runEntityObstacleCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    const fixture = try sharedEntityObstacleFixture(allocator, io);
    const n = @min(item_count, fixture.rects.items.len);
    try ensureLiveObstacleCount(fixture, n);

    if (suite.adaptiveTunerForCase(case, nav_range_alignment_items)) |tuner| {
        fixture.system.nav_remask_tuner = tuner;
        fixture.system.nav_patch_tuner = suite.adaptiveTunerForCase(case, nav_range_alignment_items).?;
    } else {
        fixture.system.nav_remask_tuner = AdaptiveWorkTuner.init(.{});
        fixture.system.nav_patch_tuner = AdaptiveWorkTuner.init(.{});
    }
    fixture.system.nav_thread_adaptive = case.adaptive;
    fixture.system.nav_thread_items_per_range = benchmarkItemsPerRange(case);

    // The serial-direct row measures the OLD whole-level-dirty path: its cost is dominated by
    // remasking every chunk in the level regardless of thread config, so one untuned serial row
    // is the fair baseline. Every other row measures the NEW localized path across that case's
    // threading config, so each row's vs_serial column reads directly as the localized path's
    // speedup over a full-level rebuild at the same obstacle count.
    const measure_old = case.worker_mode == .serial_direct;

    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| {
        _ = if (measure_old) try timeOldPathDestroy(fixture, io, n, thread_ptr) else try timeNewPathDestroy(fixture, io, n, thread_ptr);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while ((!fixture.system.nav_remask_tuner.isSettled() or !fixture.system.nav_patch_tuner.isSettled()) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try timeNewPathDestroy(fixture, io, n, thread_ptr);
        }
    }
    const remask_settled = if (case.adaptive) fixture.system.nav_remask_tuner.isSettled() else false;
    const patch_settled = if (case.adaptive) fixture.system.nav_patch_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(n);
    var last_chunks_patched: usize = 0;
    for (0..options.iterations) |_| {
        const result = if (measure_old) try timeOldPathDestroy(fixture, io, n, thread_ptr) else try timeNewPathDestroy(fixture, io, n, thread_ptr);
        last_chunks_patched = result.chunks_patched;
        accumulator.record(result.ns, suite.serialBatch(n, 1));
    }
    var stats = accumulator.finish();
    stats.batch = suite.batchSummaryFromBatch(fixture.system.graph.last_remask_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(fixture.system.graph.last_patch_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(fixture.system.nav_remask_tuner.report(), remask_settled);
        stats.secondary_work_tuning = suite.workTuningSummary(fixture.system.nav_patch_tuner.report(), patch_settled);
    }
    // candidate_pairs: the OLD path's chunks-patched count at this obstacle count (the
    // serial-direct row already measured it above; every other row probes it once, untimed).
    // output_count: the NEW path's chunks-patched count at this obstacle count (probed the
    // same way on the serial-direct row, which never runs the NEW path in its timed loop).
    if (measure_old) {
        stats.candidate_pairs = last_chunks_patched;
        stats.output_count = (try timeNewPathDestroy(fixture, io, n, null)).chunks_patched;
    } else {
        stats.candidate_pairs = (try timeOldPathDestroy(fixture, io, n, null)).chunks_patched;
        stats.output_count = last_chunks_patched;
    }
    return stats;
}
// ----------------------------------------------------------------------------
// Runtime LevelLink reaction (Slice 64E): link cursor + buffered incremental apply.
// ----------------------------------------------------------------------------

// Links added per batch: one (a single player ramp) and the full per-step cursor budget.
const link_counts = [_]usize{ 1, 8 };

pub const links_group = suite.BenchmarkGroup{
    .name = "nav-update-links",
    .defaultItemCounts = linkItemCounts,
    .runCase = runLinksCase,
};

pub fn linkItemCounts(profile: suite.Profile) []const usize {
    _ = profile;
    return &link_counts;
}

// The full per-step cursor budget (8, which equals the fixed interior link slots per chunk)
// landing in ONE nav chunk: distinct interior cells of chunk (1,1). Every ramp endpoint joins the
// chunk's open component, so its edges (4 + 12*11 = 136) outgrow the build-measured 32-edge
// window and the timed step crosses it: an in-place window growth (64E follow-up, 2026-10-06;
// formerly the full-graph edge-cap fallback rebuild).
const dense_link_counts = [_]usize{link_counts[link_counts.len - 1]};

pub const links_dense_group = suite.BenchmarkGroup{
    .name = "nav-update-links-dense",
    .defaultItemCounts = denseLinkItemCounts,
    .runCase = runDenseLinksCase,
};

pub fn denseLinkItemCounts(profile: suite.Profile) []const usize {
    _ = profile;
    return &dense_link_counts;
}

// Where a batch's ramp links land: one per chunk (chunk centers, row-major) or all in one chunk.
const LinkLayout = enum { spread, one_chunk };

// Same world shape as the tile-edit fixture (256x256 tiles, 32 px cells, default 16-tile nav
// chunks) with an open grass level 1 under the surface, so every ramp link joins two open levels.
// The tileset meta is loaded once; the world itself is rebuilt fresh (zero links) before every
// timed batch, see resetLinkWorld.
const LinksFixture = struct {
    // Stored at build time — see Fixture's matching field for why.
    allocator: std.mem.Allocator,
    meta: world_tileset_meta.WorldTilesetMeta,
    grass: TileId,
    data: DataSystem,
    world: WorldSystem,
    system: PathfindingSystem,

    fn deinit(self: *LinksFixture) void {
        self.system.deinit();
        self.world.deinit();
        self.data.deinit();
        self.meta.deinit();
        self.* = undefined;
    }
};

// OWNERSHIP: mirrors shared_fixtures above — freed by deinitCaches.
var links_fixture: ?LinksFixture = null;

fn sharedLinksFixture(allocator: std.mem.Allocator, io: std.Io) !*LinksFixture {
    if (links_fixture == null) {
        var probe = try ThreadSystem.init(allocator, io, .{});
        const max_participants = probe.participantSlotCount();
        probe.deinit();
        links_fixture = try buildLinksFixture(allocator, io, max_participants);
    }
    return &links_fixture.?;
}

// A fresh two-level world with ZERO links whose link storage is reserved (at load, like the
// demo) for the largest batch, so the timed loop never grows it.
fn buildLinkWorld(allocator: std.mem.Allocator, meta: *const world_tileset_meta.WorldTilesetMeta, grass: TileId) !WorldSystem {
    var world = try WorldSystem.initDemoFromMeta(allocator, meta, world_bounds, world_bounds);
    errdefer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addDenseLayer(1, 0, .floor, grass);
    try world.reserveLevelLinks(link_counts[link_counts.len - 1]);
    return world;
}

fn buildLinksFixture(allocator: std.mem.Allocator, io: std.Io, participant_count: usize) !LinksFixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    errdefer meta.deinit();
    const grass = try requireTile(&meta, "grass");

    var world = try buildLinkWorld(allocator, &meta, grass);
    errdefer world.deinit();

    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(.{ .worker_participant_count = @max(@as(usize, 1), participant_count) });
    // Mirror production: the link cursor's endpoint marks are inside every reservation.
    try system.reserveNavDirty(0);
    try system.rebuildStaticNavGridWithWorld(&data, &world, world_bounds, world_bounds, tile_size, null);

    return .{ .allocator = allocator, .meta = meta, .grass = grass, .data = data, .world = world, .system = system };
}

// Untimed per-iteration reset through the production load path: replaces the world with a
// fresh zero-link world and runs the full nav build over it (which resets the slot table and
// the link cursor exactly as a load does). Links are append-only in production, so this is the
// only honest way back to a zero-link baseline; it keeps every timed batch assigning FRESH
// interior slots and keeps rebuildLinkEdges' O(links) cost from drifting with iteration count.
// The full build also resets the adaptive stage tuners, so the case's trained tuners are carried
// across it (the same tuner hand-off runLinksCase does per case).
fn resetLinkWorld(fixture: *LinksFixture) !void {
    const fresh = try buildLinkWorld(fixture.allocator, &fixture.meta, fixture.grass);
    fixture.world.deinit();
    fixture.world = fresh;
    const remask_tuner = fixture.system.nav_remask_tuner;
    const patch_tuner = fixture.system.nav_patch_tuner;
    try fixture.system.rebuildStaticNavGridWithWorld(&fixture.data, &fixture.world, world_bounds, world_bounds, tile_size, null);
    fixture.system.nav_remask_tuner = remask_tuner;
    fixture.system.nav_patch_tuner = patch_tuner;
}

// Times one batch on a fresh zero-link world: adds `n` ramp links (chunk-center interior cells
// of the first `n` chunks, row-major, levels 1<->0; untimed), then times the link cursor
// (fresh slot assignment + both-level dirty marks) and the buffered incremental apply, exactly
// the post-commit reaction's link work.
fn timeLinkBatch(fixture: *LinksFixture, io: std.Io, n: usize, layout: LinkLayout, thread_system: ?*ThreadSystem) !u64 {
    try resetLinkWorld(fixture);
    for (0..n) |i| {
        const x: u16, const y: u16 = switch (layout) {
            .spread => .{
                @intCast((i % chunks_per_side) * nav_chunk_tiles + nav_chunk_tiles / 2),
                @intCast((i / chunks_per_side) * nav_chunk_tiles + nav_chunk_tiles / 2),
            },
            // Chunk (1,1) spans tiles 16..31; cells 18..27 step 3 stay off its perimeter.
            .one_chunk => .{ @intCast(nav_chunk_tiles + 2 + (i % 4) * 3), @intCast(nav_chunk_tiles + 2 + (i / 4) * 3) },
        };
        try fixture.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = x, .y = y }, .level_b = 0, .cell_b = .{ .x = x, .y = y }, .traversal_cost = 1, .bidirectional = true });
    }
    fixture.system.clearNavDirty();
    const t0 = suite.nowNs(io);
    _ = try fixture.system.markNewNavLinksDirty(&fixture.world);
    const stats = try fixture.system.applyBufferedNavUpdates(&fixture.data, &fixture.world, thread_system);
    const elapsed = suite.elapsedNs(t0, suite.nowNs(io));
    // The dense layout exists to time the step that outgrows a chunk's edge window.
    std.debug.assert(layout != .one_chunk or stats.edge_windows_grown != 0);
    return elapsed;
}

pub fn runLinksCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runLinksCaseWithLayout(allocator, io, options, case, item_count, .spread);
}

pub fn runDenseLinksCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runLinksCaseWithLayout(allocator, io, options, case, item_count, .one_chunk);
}

fn runLinksCaseWithLayout(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, layout: LinkLayout) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    const fixture = try sharedLinksFixture(allocator, io);
    // Within the per-step cursor budget and the world's reserved link storage.
    const n = @min(item_count, link_counts[link_counts.len - 1]);

    if (suite.adaptiveTunerForCase(case, nav_range_alignment_items)) |tuner| {
        fixture.system.nav_remask_tuner = tuner;
        fixture.system.nav_patch_tuner = suite.adaptiveTunerForCase(case, nav_range_alignment_items).?;
    } else {
        fixture.system.nav_remask_tuner = AdaptiveWorkTuner.init(.{});
        fixture.system.nav_patch_tuner = AdaptiveWorkTuner.init(.{});
    }
    fixture.system.nav_thread_adaptive = case.adaptive;
    fixture.system.nav_thread_items_per_range = benchmarkItemsPerRange(case);

    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| _ = try timeLinkBatch(fixture, io, n, layout, thread_ptr);
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while ((!fixture.system.nav_remask_tuner.isSettled() or !fixture.system.nav_patch_tuner.isSettled()) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try timeLinkBatch(fixture, io, n, layout, thread_ptr);
        }
    }
    const remask_settled = if (case.adaptive) fixture.system.nav_remask_tuner.isSettled() else false;
    const patch_settled = if (case.adaptive) fixture.system.nav_patch_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(n);
    for (0..options.iterations) |_| {
        accumulator.record(try timeLinkBatch(fixture, io, n, layout, thread_ptr), suite.serialBatch(n, 1));
    }
    var stats = accumulator.finish();
    stats.batch = suite.batchSummaryFromBatch(fixture.system.graph.last_remask_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(fixture.system.graph.last_patch_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(fixture.system.nav_remask_tuner.report(), remask_settled);
        stats.secondary_work_tuning = suite.workTuningSummary(fixture.system.nav_patch_tuner.report(), patch_settled);
    }
    return stats;
}

// ----------------------------------------------------------------------------
// Cave-in repack (Slice 64F): one step outgrows edge windows on several levels.
// ----------------------------------------------------------------------------

// A large world: 1024x1024 tiles, 32 levels, default 16-tile nav chunks (64x64 per level). A
// 4x4-chunk region of rock at the world center, on levels 1..n (n = item count), is carved into
// a 1-wide lattice in one step: its chunks and their border neighbors outgrow their build-sized
// windows, so each caved level repacks once (cold). The warm group carves into windows a prior
// carve already grew (no repack), so cold minus warm is the repack cost.
const cave_in_world_tiles: u16 = 1024;
const cave_in_world_bounds: f32 = @as(f32, @floatFromInt(cave_in_world_tiles)) * tile_size;
const cave_in_level_count: usize = 32;
const cave_in_region_tiles: u16 = 4 * nav_chunk_tiles;
// Chunk aligned (world_tiles / 2 and region_tiles / 2 are both multiples of the chunk size).
const cave_in_region_lo: u16 = cave_in_world_tiles / 2 - cave_in_region_tiles / 2;
const cave_in_counts = [_]usize{3};

pub const cave_in_group = suite.BenchmarkGroup{
    .name = "nav-update-cave-in",
    .defaultItemCounts = caveInItemCounts,
    .runCase = runCaveInColdCase,
};

pub const cave_in_warm_group = suite.BenchmarkGroup{
    .name = "nav-update-cave-in-warm",
    .defaultItemCounts = caveInItemCounts,
    .runCase = runCaveInWarmCase,
};

pub fn caveInItemCounts(profile: suite.Profile) []const usize {
    _ = profile;
    return &cave_in_counts;
}

pub fn runCaveInColdCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaveInCase(allocator, io, options, case, item_count, .cold);
}

pub fn runCaveInWarmCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaveInCase(allocator, io, options, case, item_count, .warm);
}

// cold: every timed carve starts from build-sized windows; warm: from windows already grown.
const CaveInMode = enum { cold, warm };

const CaveInFixture = struct {
    // Stored at build time — see Fixture's matching field for why.
    allocator: std.mem.Allocator,
    data: DataSystem,
    world: WorldSystem,
    system: PathfindingSystem,
    // Obstacle layer of each level (index 0 unused: the surface never caves).
    obstacle_layers: [cave_in_level_count]usize,
    grass: TileId,
    tree: TileId,
    // Levels 1..carved_levels currently hold the carved lattice.
    carved_levels: usize = 0,
    edits: std.ArrayList(NavCellEdit) = .empty,

    fn deinit(self: *CaveInFixture) void {
        self.edits.deinit(self.allocator);
        self.system.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

// OWNERSHIP: mirrors shared_fixtures above — freed by deinitCaches.
var cave_in_fixture: ?CaveInFixture = null;

fn sharedCaveInFixture(allocator: std.mem.Allocator, io: std.Io) !*CaveInFixture {
    if (cave_in_fixture == null) {
        var probe = try ThreadSystem.init(allocator, io, .{});
        const max_participants = probe.participantSlotCount();
        probe.deinit();
        cave_in_fixture = try buildCaveInFixture(allocator, io, max_participants);
    }
    return &cave_in_fixture.?;
}

fn buildCaveInFixture(allocator: std.mem.Allocator, io: std.Io, participant_count: usize) !CaveInFixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const asset_store = AssetStore.init(allocator, io, "assets");
    var meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const grass = try requireTile(&meta, "grass");
    const tree = try requireTile(&meta, "tree_0");

    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, cave_in_world_bounds, cave_in_world_bounds);
    errdefer world.deinit();
    // Underground levels: open grass with the cave-in region solid rock.
    var obstacle_layers: [cave_in_level_count]usize = undefined;
    obstacle_layers[0] = 0;
    for (1..cave_in_level_count) |level_index| {
        const level = try world.addLevel(0);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
        obstacle_layers[level_index] = try world.addDenseLayer(level, 0, .obstacle, grass);
        var y = cave_in_region_lo;
        while (y < cave_in_region_lo + cave_in_region_tiles) : (y += 1) {
            var x = cave_in_region_lo;
            while (x < cave_in_region_lo + cave_in_region_tiles) : (x += 1) {
                _ = try world.setDenseTile(obstacle_layers[level_index], x, y, tree);
            }
        }
    }

    var capacity: PathfindingCapacity = .{ .worker_participant_count = @max(@as(usize, 1), participant_count) };
    capacity.max_nav_memory_bytes = autoSizedMaxNavMemoryBytes(capacity, cave_in_level_count, cave_in_world_tiles, cave_in_world_tiles, 0);
    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(&data, &world, cave_in_world_bounds, cave_in_world_bounds, tile_size, null);

    return .{ .allocator = allocator, .data = data, .world = world, .system = system, .obstacle_layers = obstacle_layers, .grass = grass, .tree = tree };
}

// Sets the region's lattice (1-wide corridors on its odd rows and columns) to `tile` on levels
// 1..level_count (grass carves, tree fills), recording every changed cell in fixture.edits.
fn setCaveInLattice(fixture: *CaveInFixture, level_count: usize, tile: TileId) !void {
    fixture.edits.clearRetainingCapacity();
    const lo = cave_in_region_lo;
    const hi = lo + cave_in_region_tiles;
    for (1..level_count + 1) |level| {
        var corridor: u16 = lo + 1;
        while (corridor < hi) : (corridor += 2) {
            var along: u16 = lo;
            while (along < hi) : (along += 1) {
                for ([_][2]u16{ .{ along, corridor }, .{ corridor, along } }) |xy| {
                    const changed = (try fixture.world.setDenseTile(fixture.obstacle_layers[level], xy[0], xy[1], tile)) orelse continue;
                    try fixture.edits.append(fixture.allocator, .{ .level = changed.level, .x = changed.x, .y = changed.y });
                }
            }
        }
    }
    // Mirror production: the dirty buffers are reserved before any step marks them.
    try fixture.system.reserveNavDirty(fixture.edits.items.len);
}

// One nav update over fixture.edits, through the buffered path when threaded (as in
// timeNavUpdate).
fn applyCaveIn(fixture: *CaveInFixture, thread_system: ?*ThreadSystem) !NavUpdateStats {
    if (thread_system) |ts| {
        fixture.system.clearNavDirty();
        for (fixture.edits.items) |edit| try fixture.system.markNavDirty(edit.level, edit.x, edit.y);
        return fixture.system.applyBufferedNavUpdates(&fixture.data, &fixture.world, ts);
    }
    return fixture.system.applyNavUpdates(&fixture.data, &fixture.world, fixture.edits.items);
}

// Untimed reset, then the timed carve on levels 1..n. Reset: fill any carved lattice back, then
// (cold) a full build so every window is back at its build size, or (warm) an incremental fill,
// which keeps the grown windows. Fails if the carve's repack count is not the mode's.
fn timeCaveIn(fixture: *CaveInFixture, io: std.Io, n: usize, mode: CaveInMode, thread_system: ?*ThreadSystem) !u64 {
    try setCaveInLattice(fixture, @max(n, fixture.carved_levels), fixture.tree);
    fixture.carved_levels = 0;
    switch (mode) {
        .cold => {
            // A full build resets the stage tuners; carry the case's trained ones across it.
            const remask_tuner = fixture.system.nav_remask_tuner;
            const patch_tuner = fixture.system.nav_patch_tuner;
            try fixture.system.rebuildStaticNavGridWithWorld(&fixture.data, &fixture.world, cave_in_world_bounds, cave_in_world_bounds, tile_size, null);
            fixture.system.nav_remask_tuner = remask_tuner;
            fixture.system.nav_patch_tuner = patch_tuner;
        },
        .warm => _ = try applyCaveIn(fixture, thread_system),
    }
    try setCaveInLattice(fixture, n, fixture.grass);
    fixture.carved_levels = n;
    const t0 = suite.nowNs(io);
    const stats = try applyCaveIn(fixture, thread_system);
    const elapsed = suite.elapsedNs(t0, suite.nowNs(io));
    const expected_repacks: usize = if (mode == .cold) n else 0;
    if (stats.edge_repacks != expected_repacks) return error.UnexpectedCaveInRepackCount;
    return elapsed;
}

fn runCaveInCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, mode: CaveInMode) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();
    const thread_ptr: ?*ThreadSystem = if (threads) |*thread_system| thread_system else null;

    const fixture = try sharedCaveInFixture(allocator, io);
    // Underground levels only.
    const n = std.math.clamp(item_count, 1, cave_in_level_count - 1);

    if (suite.adaptiveTunerForCase(case, nav_range_alignment_items)) |tuner| {
        fixture.system.nav_remask_tuner = tuner;
        fixture.system.nav_patch_tuner = suite.adaptiveTunerForCase(case, nav_range_alignment_items).?;
    } else {
        fixture.system.nav_remask_tuner = AdaptiveWorkTuner.init(.{});
        fixture.system.nav_patch_tuner = AdaptiveWorkTuner.init(.{});
    }
    fixture.system.nav_thread_adaptive = case.adaptive;
    fixture.system.nav_thread_items_per_range = benchmarkItemsPerRange(case);

    // Warm mode needs windows a carve of these n levels already grew.
    if (mode == .warm) {
        try setCaveInLattice(fixture, @max(n, fixture.carved_levels), fixture.grass);
        _ = try applyCaveIn(fixture, thread_ptr);
        fixture.carved_levels = @max(n, fixture.carved_levels);
    }
    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| _ = try timeCaveIn(fixture, io, n, mode, thread_ptr);
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while ((!fixture.system.nav_remask_tuner.isSettled() or !fixture.system.nav_patch_tuner.isSettled()) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try timeCaveIn(fixture, io, n, mode, thread_ptr);
        }
    }
    const remask_settled = if (case.adaptive) fixture.system.nav_remask_tuner.isSettled() else false;
    const patch_settled = if (case.adaptive) fixture.system.nav_patch_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(n);
    for (0..options.iterations) |_| {
        accumulator.record(try timeCaveIn(fixture, io, n, mode, thread_ptr), suite.serialBatch(n, 1));
    }
    var stats = accumulator.finish();
    stats.batch = suite.batchSummaryFromBatch(fixture.system.graph.last_remask_batch);
    stats.secondary_batch = suite.batchSummaryFromBatch(fixture.system.graph.last_patch_batch);
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(fixture.system.nav_remask_tuner.report(), remask_settled);
        stats.secondary_work_tuning = suite.workTuningSummary(fixture.system.nav_patch_tuner.report(), patch_settled);
    }
    return stats;
}
