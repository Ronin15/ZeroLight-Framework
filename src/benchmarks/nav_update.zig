// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Measures the cost of an incremental nav abstract-graph update (`applyNavUpdates`) on a
//! large multi-level world. Each case toggles a dirty footprint of `item_count` tiles open
//! then blocked; with the dirty-bounded rebuild only the chunks the footprint touches (plus
//! their border neighbors) are patched, so cost tracks the dirty region, not the level size.
//! Footprints span the production batch range (1 cell up to the nav_dirty_edit_capacity cap,
//! doubled for headroom). The fixture is built once outside the timed region; each timed
//! toggle returns the world to its start state so the dirty set stays bounded.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const WorldSystem = @import("../game/world_system.zig").WorldSystem;
const NavCellEdit = @import("../game/systems/pathfinding.zig").NavCellEdit;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const TileId = @import("../game/world_system.zig").TileId;
const suite = @import("suite.zig");

fn requireTile(meta: *const world_tileset_meta.WorldTilesetMeta, name: []const u8) !TileId {
    return (meta.tileByName(name) orelse return error.TileNotFound).id;
}

// World side length in nav cells/tiles. 512 with 32px tiles spans 32x32 abstract chunks per
// level — the scale where a non-incremental rebuild crossed a millisecond.
const world_tiles: u16 = 512;
const tile_size: f32 = 32.0;
const world_bounds: f32 = @as(f32, @floatFromInt(world_tiles)) * tile_size;

// Dirty cells fed to one `applyNavUpdates` batch. Production buffers nav edits at
// `nav_dirty_edit_capacity` (16) and drops the overflow, so a real batch ranges from a
// single-tile dig (1) up to that cap (16). These counts walk that prod range and double the
// ends for stress headroom. Batch cost tracks the dirty-chunk footprint, not the level size,
// so the timed loop runs one toggle per iteration (no inner repeat) and stays well under a
// second per group.
const update_counts = [_]usize{ 1, 2, 16, 32 };

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

const Fixture = struct {
    data: DataSystem,
    world: WorldSystem,
    system: PathfindingSystem,
    obstacle_layer: usize,
    // Underground tiles toggled each iteration (one for interior, a straddling block for
    // multichunk). These are blocked at the start state and returned to it after a toggle.
    edits: std.ArrayList(NavCellEdit),

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.edits.deinit(allocator);
        self.system.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

// Smallest square side that holds `cells` tiles; the footprint is filled row-major up to
// `cells` so the batch edit count matches the requested item count exactly.
fn squareSide(cells: usize) u16 {
    var side: u16 = 1;
    while (@as(usize, side) * @as(usize, side) < cells) side += 1;
    return side;
}

fn buildFixture(allocator: std.mem.Allocator, io: std.Io, variant: Variant, cells: usize) !Fixture {
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

    var edits = std.ArrayList(NavCellEdit).empty;
    errdefer edits.deinit(allocator);
    // Lay `cells` dirty tiles row-major in a square-ish footprint on level 1. The interior
    // anchor keeps small batches inside one 16-tile abstract chunk; the multichunk anchor
    // centers the block on the chunk borders at x=32/y=32 so the footprint straddles four
    // chunks (the worst-case orthogonal-neighbor fan-out).
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
            try edits.append(allocator, .{ .level = 1, .x = anchor.x + dx, .y = anchor.y + dy });
            placed += 1;
        }
    }
    // Start state: the edited tiles are blocked.
    for (edits.items) |edit| _ = try world.setDenseTile(obstacle_layer, edit.x, edit.y, tree);

    var system = PathfindingSystem.init(allocator);
    errdefer system.deinit();
    try system.reserve(.{ .worker_participant_count = 1 });
    try system.rebuildStaticNavGridWithWorld(&data, &world, world_bounds, world_bounds, tile_size);

    return .{
        .data = data,
        .world = world,
        .system = system,
        .obstacle_layer = obstacle_layer,
        .edits = edits,
    };
}

// One open/blocked toggle of the edited tiles, returning the world to its start state. Each
// half is one `applyNavUpdates`, so a toggle is two incremental updates. Only the
// `applyNavUpdates` calls are timed (the world tile writes that set up each half are
// excluded), so the measurement reflects the abstract-graph update cost the task targets.
fn runToggle(fixture: *Fixture, io: std.Io, open_tile: u16, blocked_tile: u16) !u64 {
    var elapsed: u64 = 0;
    for (fixture.edits.items) |edit| _ = try fixture.world.setDenseTile(fixture.obstacle_layer, edit.x, edit.y, open_tile);
    var t0 = suite.nowNs(io);
    _ = try fixture.system.applyNavUpdates(&fixture.data, &fixture.world, fixture.edits.items);
    elapsed += suite.elapsedNs(t0, suite.nowNs(io));
    for (fixture.edits.items) |edit| _ = try fixture.world.setDenseTile(fixture.obstacle_layer, edit.x, edit.y, blocked_tile);
    t0 = suite.nowNs(io);
    _ = try fixture.system.applyNavUpdates(&fixture.data, &fixture.world, fixture.edits.items);
    elapsed += suite.elapsedNs(t0, suite.nowNs(io));
    return elapsed;
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, variant: Variant) !suite.RunStats {
    // The update is a serial main-thread reaction; the threaded cases would measure the same
    // work, so report only the serial case.
    if (case.worker_mode != .serial_direct) return suite.RunStats.skipped("nav update is serial");

    var fixture = try buildFixture(allocator, io, variant, item_count);
    defer fixture.deinit(allocator);

    var meta = try world_tileset_meta.load(allocator, AssetStore.init(allocator, io, "assets"), manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const grass = try requireTile(&meta, "grass");
    const tree = try requireTile(&meta, "tree_0");

    // Warm one toggle so the abstract buffers are at high-water capacity (the steady path is
    // allocation-free) before timing.
    for (0..@max(@as(usize, 1), options.warmup_iterations)) |_| _ = try runToggle(&fixture, io, grass, tree);

    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        // One toggle is two timed `applyNavUpdates` over the full footprint; report the
        // per-update batch cost (items_per_second then reads as dirty cells per second).
        const elapsed = try runToggle(&fixture, io, grass, tree);
        accumulator.record(elapsed / 2, suite.serialBatch(item_count, 1));
    }
    return accumulator.finish();
}

test "nav update benchmark single-chunk fixture patches a bounded chunk set" {
    var fixture = try buildFixture(std.testing.allocator, std.testing.io, .interior, 1);
    defer fixture.deinit(std.testing.allocator);

    var meta = try world_tileset_meta.load(std.testing.allocator, AssetStore.init(std.testing.allocator, std.testing.io, "assets"), manifest.spriteSpec(.world_tileset).metadata_path.?);
    defer meta.deinit();
    const grass = try requireTile(&meta, "grass");

    for (fixture.edits.items) |edit| _ = try fixture.world.setDenseTile(fixture.obstacle_layer, edit.x, edit.y, grass);
    const stats = try fixture.system.applyNavUpdates(&fixture.data, &fixture.world, fixture.edits.items);
    // One interior chunk plus its four orthogonal neighbors, with no full-rebuild fallback.
    try std.testing.expectEqual(@as(usize, 5), stats.chunks_patched);
    try std.testing.expectEqual(@as(usize, 1), stats.incremental_rebuilds);
    try std.testing.expectEqual(@as(usize, 0), stats.edge_cap_fallback);
}
