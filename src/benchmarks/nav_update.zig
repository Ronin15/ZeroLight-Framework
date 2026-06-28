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

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const NavCellEdit = @import("../game/systems/pathfinding.zig").NavCellEdit;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
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
    data: DataSystem,
    world: WorldSystem,
    system: PathfindingSystem,
    obstacle_layer: usize,
    grass: TileId,
    tree: TileId,
    // Tiles toggled each timed iteration: the current count's footprint on level 1.
    edits: std.ArrayList(NavCellEdit),

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.edits.deinit(allocator);
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
var shared_fixtures: [@typeInfo(Variant).@"enum".fields.len]?Fixture = .{ null, null };

pub fn deinitCaches(allocator: std.mem.Allocator) void {
    for (&shared_fixtures) |*slot| {
        if (slot.*) |*fixture| fixture.deinit(allocator);
        slot.* = null;
    }
}

// Returns the variant's reusable fixture, building it once (world + nav sized for the maximum
// threaded participant count, so every case fits) on first use.
fn sharedFixture(allocator: std.mem.Allocator, io: std.Io, variant: Variant) !*Fixture {
    const slot = &shared_fixtures[@intFromEnum(variant)];
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
    try system.rebuildStaticNavGridWithWorld(&data, &world, world_bounds, world_bounds, tile_size);

    return .{
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
            const side = squareSide(cells);
            // world_tiles/2 is a multiple of chunk_tiles, i.e. a chunk boundary; centering the
            // block there keeps it border-straddling at every size.
            const center: u16 = world_tiles / 2;
            const ax: u16 = center -| side / 2;
            const ay: u16 = center -| side / 2;
            var placed: usize = 0;
            var dy: u16 = 0;
            outer: while (placed < cells) : (dy += 1) {
                var dx: u16 = 0;
                while (dx < side) : (dx += 1) {
                    if (placed >= cells) break :outer;
                    try fixture.edits.append(allocator, .{ .level = 1, .x = ax + dx, .y = ay + dy });
                    placed += 1;
                }
            }
        },
    }
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

test "nav update benchmark single-chunk fixture patches a bounded chunk set" {
    var fixture = try buildSharedFixture(std.testing.allocator, std.testing.io, 1);
    defer fixture.deinit(std.testing.allocator);
    // A single mid-chunk cell (compact footprint at the world-center chunk) -> its chunk plus its
    // four orthogonal neighbors, no full-rebuild fallback.
    try setFootprint(&fixture, std.testing.allocator, .multichunk, 1);

    // Block the single cell to force a real patch.
    for (fixture.edits.items) |edit| _ = try fixture.world.setDenseTile(fixture.obstacle_layer, edit.x, edit.y, fixture.tree);
    const stats = try fixture.system.applyNavUpdates(&fixture.data, &fixture.world, fixture.edits.items);
    // One interior chunk plus its four orthogonal neighbors, with no full-rebuild fallback.
    try std.testing.expectEqual(@as(usize, 5), stats.chunks_patched);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.edge_cap_fallback);
}

test "nav update benchmark scattered footprint is one dirty cell per distinct chunk" {
    // Guards the scattered variant's premise (and the nav_chunk_tiles coupling): each edit must
    // land in its own chunk so item_count == dirty-chunk count, capped at the world chunk total.
    var fixture = try buildSharedFixture(std.testing.allocator, std.testing.io, 1);
    defer fixture.deinit(std.testing.allocator);

    // Below the cap: every requested cell becomes a distinct-chunk edit.
    try setFootprint(&fixture, std.testing.allocator, .scattered, 64);
    try std.testing.expectEqual(@as(usize, 64), fixture.edits.items.len);
    var seen = [_]bool{false} ** total_chunks;
    for (fixture.edits.items) |edit| {
        const chunk = (edit.x / nav_chunk_tiles) + (edit.y / nav_chunk_tiles) * chunks_per_side;
        try std.testing.expect(!seen[chunk]);
        seen[chunk] = true;
    }

    // Above the cap: edit count saturates at the world chunk total, still all distinct.
    try setFootprint(&fixture, std.testing.allocator, .scattered, total_chunks + 100);
    try std.testing.expectEqual(total_chunks, fixture.edits.items.len);
}

test "nav update benchmark dig-storm tier stays incremental (no full rebuild)" {
    // Guards the bench's premise: the largest footprint must still take the incremental path.
    // A regression that pushed the dig-storm tier into a full relabel / edge-cap fallback would
    // make the numbers world-size-dependent and no longer measure an incremental update.
    var fixture = try buildSharedFixture(std.testing.allocator, std.testing.io, 1);
    defer fixture.deinit(std.testing.allocator);
    const top_tier = update_counts[update_counts.len - 1];
    try setFootprint(&fixture, std.testing.allocator, .multichunk, top_tier);

    for (fixture.edits.items) |edit| _ = try fixture.world.setDenseTile(fixture.obstacle_layer, edit.x, edit.y, fixture.tree);
    const stats = try fixture.system.applyNavUpdates(&fixture.data, &fixture.world, fixture.edits.items);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.full_relabel);
    try std.testing.expectEqual(@as(usize, 0), stats.edge_cap_fallback);
    try std.testing.expectEqual(@as(usize, 0), stats.version_bumps);
}
