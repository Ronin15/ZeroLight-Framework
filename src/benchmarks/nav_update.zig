// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Measures the cost of an incremental nav abstract-graph update on a large multi-level world.
//! Each case toggles a dirty footprint of `item_count` tiles open then blocked; with the
//! dirty-bounded rebuild only the chunks the footprint touches (plus their border neighbors)
//! are patched, so cost tracks the dirty region, not the level size. The serial case runs the
//! full footprint range (prod-scale digs up through a dig-storm); the threaded cases run the
//! dig-storm tier through the system's threaded chunk patch so the report shows serial-vs-
//! threaded scaling. The fixture is built once outside the timed region; each timed toggle
//! returns the world to its start state so the dirty set stays bounded.

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
// largest footprint plus a few chunks of margin — NOT a full game world. A small world keeps
// the per-case fixture rebuild (O(world^2), the dominant bench cost) cheap so the Debug bench
// completes quickly; 128 tiles = 8x8 abstract chunks, room for the 64x64 dig-storm footprint.
const world_tiles: u16 = 128;
const tile_size: f32 = 32.0;
const world_bounds: f32 = @as(f32, @floatFromInt(world_tiles)) * tile_size;

// Dirty cells fed to one `applyNavUpdates` batch (the footprint). The small end {1,2,16,32}
// is the production batch range (a single-tile dig up to the dirty-edit cap, doubled for
// headroom) and measures realistic per-dig cost. The large end {256,1024,4096} is a dig-storm
// tier (many actors digging at once) that touches enough chunks for the threaded remask/patch
// stages to engage and show serial-vs-threaded scaling. Counts are kept small enough that the
// Debug bench (the default) completes quickly with performant code; the adaptive tuner scales
// the threaded stages in Debug, and scales them further in release. Cost tracks the dirty-chunk
// footprint, not the level size.
const update_counts = [_]usize{ 1, 2, 16, 32, 256, 1024, 4096 };

// The threaded chunk patch only pays off once a batch spans many chunks. Below this footprint
// the adaptive tuner keeps the patch inline anyway, so the threaded cases skip the small end
// (the serial rows already report that cost) and only run the dig-storm tier.
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

const Variant = enum { interior, multichunk };

pub const group = suite.BenchmarkGroup{
    .name = "nav-update-interior",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runInteriorCase,
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

pub fn runInteriorCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .interior);
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

// Regenerates the current count's dirty footprint on level 1. The interior anchor keeps small
// batches inside one 16-tile abstract chunk; the multichunk anchor centers the block on the chunk
// borders at x=32/y=32 so it straddles four chunks (worst-case orthogonal-neighbor fan-out). The
// world is not mutated here — the toggle establishes the open/blocked state.
fn setFootprint(fixture: *Fixture, allocator: std.mem.Allocator, variant: Variant, cells: usize) !void {
    fixture.edits.clearRetainingCapacity();
    const side = squareSide(cells);
    const anchor: struct { x: u16, y: u16 } = switch (variant) {
        .interior => .{ .x = 40, .y = 40 },
        .multichunk => .{ .x = @as(u16, 32) -| side / 2, .y = @as(u16, 32) -| side / 2 },
    };
    var placed: usize = 0;
    var dy: u16 = 0;
    outer: while (placed < cells) : (dy += 1) {
        var dx: u16 = 0;
        while (dx < side) : (dx += 1) {
            if (placed >= cells) break :outer;
            try fixture.edits.append(allocator, .{ .level = 1, .x = anchor.x + dx, .y = anchor.y + dy });
            placed += 1;
        }
    }
}

// One open/blocked toggle of the edited tiles, returning the world to its start state. Each
// half is one nav update, so a toggle is two incremental updates. Only the nav-update call is
// timed (the world tile writes and the dirty-cell marking that set up each half are excluded),
// so the measurement reflects the abstract-graph patch cost the task targets. A non-null
// thread_system routes through the threaded buffered path (markNavDirty + applyBufferedNavUpdates);
// null runs the serial slice path.
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
    // Threaded cases only run the dig-storm tier; below it the patch stays inline anyway and the
    // serial rows already report that cost, so skip to keep the matrix cheap.
    if (case.usesThreadSystem() and item_count < threaded_min_cells) {
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

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        // One toggle is two timed nav updates over the full footprint; report the per-update
        // batch cost (items_per_second then reads as dirty cells per second).
        const elapsed = try runToggle(fixture, io, thread_ptr);
        accumulator.record(elapsed / 2, suite.serialBatch(item_count, 1));
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
    try setFootprint(&fixture, std.testing.allocator, .interior, 1);

    // Block the single interior cell to force a real patch.
    for (fixture.edits.items) |edit| _ = try fixture.world.setDenseTile(fixture.obstacle_layer, edit.x, edit.y, fixture.tree);
    const stats = try fixture.system.applyNavUpdates(&fixture.data, &fixture.world, fixture.edits.items);
    // One interior chunk plus its four orthogonal neighbors, with no full-rebuild fallback.
    try std.testing.expectEqual(@as(usize, 5), stats.chunks_patched);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.edge_cap_fallback);
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
