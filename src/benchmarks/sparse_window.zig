// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Sparse-tile render prep against the camera window as the world's sparse tile count (the
//! item count) grows. A 2048x2048 world of 8 levels holds exactly 256 sparse tiles inside a
//! fixed 1280x720 camera window on the active level, over four depths; every other tile sits
//! outside the window's chunks on all levels. The window's work is the same at every size.
//! Pass shape: each layout is flat in the world's sparse count, and the interleaved and
//! churned pans match the chunk-ordered pan. No timing-ratio assert.
//!   - `render-sparse-window-frame`: one frame's window update (unchanged, so O(1)), depth
//!     range walk, and sparse submit into a headless `SpriteBatch`. Today's cell placement.
//!   - `render-sparse-window-pan`: the same cells added chunk by chunk. The window pans one
//!     chunk across, a frame, back, a frame; each pan rebuilds the window's sparse list.
//!   - `render-sparse-window-pan-interleaved`: that same cell list shuffled with a fixed seed.
//!   - `render-sparse-window-pan-churned`: chunk order, then an untimed clear and re-add of
//!     every other blocking tile, so the timed pan sees the same set.
//!   - `render-sparse-window-add`: outside, one sparse tile added outside the window, then a
//!     frame. Today's cell placement. The untimed reset drops that tile from its run, and the
//!     add fails the case if the window goes dirty. In-window, one tile in a single chunk of
//!     the fixed window, then that same frame. Pass shape, asserted from the patch counters:
//!     the edited run plus the sorted-list splice, flat in the world's sparse count outside
//!     that window. The order is derived, not measured: O(edited-run rows + P log P + V).
//!     V is the dense splice, not a recount of window chunks.
//! Fixtures build once per case outside the timed loop. Sparse prep is main-thread work, so
//! the groups run serial only.

const std = @import("std");
const WorldDepth = @import("../game/render_depth.zig").WorldDepth;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const TileId = @import("../game/world/system.zig").TileId;
const level_z_step = @import("../game/world/system.zig").level_z_step;
const ChunkGeometry = @import("../game/world/terrain.zig").ChunkGeometry;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const Rect = @import("../render/renderer.zig").Rect;
const TextureId = @import("../render/resources.zig").TextureId;
const SpriteBatch = @import("../render/sprite_batch.zig").SpriteBatch;
const inlineBatch = @import("../app/thread_system.zig").inlineBatch;
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

const world_side: u16 = 2048;
const world_levels: u16 = 8;
const active_level: u16 = 0;
const overscan_chunks: u16 = 1;
const viewport_w: f32 = 1280;
const viewport_h: f32 = 720;
// Camera top-left, in tiles: chunk-aligned and clear of the world edge, so the
// one-chunk pan is never clamped.
const camera_tile_x: u16 = 256;
const camera_tile_y: u16 = 256;

// The window's tiles: a 16x16 block inside the camera's tile bounds, at least one
// chunk from its left and right edges so a one-chunk pan keeps all of them in view.
const window_block_edge: u16 = 16;
const window_tile_count: usize = @as(usize, window_block_edge) * window_block_edge;
const window_block_x: u16 = camera_tile_x + 20;
const window_block_y: u16 = camera_tile_y + 3;
const window_depths = [_]WorldDepth{ .floor, .obstacle, .effect, .marker };

// Tiles outside the window fill rows from here down, far below the window's chunks
// after any pan and overscan.
const outside_first_row: u16 = 512;
const outside_columns: usize = 256;
const outside_column_stride: u16 = world_side / outside_columns;

// The add group's tile: outside the window, on a level inside the render window.
const added_tile_level: u16 = 3;
const added_tile_x: u16 = 1000;
const added_tile_y: u16 = 1500;

const sparse_tile_counts = [_]usize{ 1_000, 16_000, 256_000 };

const AddKind = enum(u8) { outside, in_window };

// `kind` is the high digit, so an outside count stays the sparse-tile count.
const AddCode = suite.ItemCode(struct { kind: AddKind, tiles: usize }, &.{6});

const add_item_counts = blk: {
    const kinds = [_]AddKind{ .outside, .in_window };
    var counts: [kinds.len * sparse_tile_counts.len]usize = undefined;
    var index: usize = 0;
    for (kinds) |kind| {
        for (sparse_tile_counts) |tiles| {
            counts[index] = AddCode.of(.{ .kind = kind, .tiles = tiles });
            index += 1;
        }
    }
    break :blk counts;
};

comptime {
    std.debug.assert(add_item_counts[0] == sparse_tile_counts[0]);
    std.debug.assert(add_item_counts[1] == sparse_tile_counts[1]);
    std.debug.assert(add_item_counts[2] == sparse_tile_counts[2]);
}

pub const frame_group = suite.BenchmarkGroup{
    .name = "render-sparse-window-frame",
    .item_label = "sparse tiles in the world",
    .item_counts = &sparse_tile_counts,
    .runCase = runFrameCase,
    .write_workload = writeSparseWorkload,
    .cases = &suite.serial_cases,
};

pub const pan_group = suite.BenchmarkGroup{
    .name = "render-sparse-window-pan",
    .item_label = "sparse tiles in the world",
    .item_counts = &sparse_tile_counts,
    .runCase = runPanCase,
    .write_workload = writeSparseWorkload,
    .cases = &suite.serial_cases,
};

pub const pan_interleaved_group = suite.BenchmarkGroup{
    .name = "render-sparse-window-pan-interleaved",
    .item_label = "sparse tiles in the world",
    .item_counts = &sparse_tile_counts,
    .runCase = runPanInterleavedCase,
    .write_workload = writeSparseWorkload,
    .cases = &suite.serial_cases,
};

pub const pan_churned_group = suite.BenchmarkGroup{
    .name = "render-sparse-window-pan-churned",
    .item_label = "sparse tiles in the world",
    .item_counts = &sparse_tile_counts,
    .runCase = runPanChurnedCase,
    .write_workload = writeSparseWorkload,
    .cases = &suite.serial_cases,
};

pub const add_group = suite.BenchmarkGroup{
    .name = "render-sparse-window-add",
    .item_label = AddCode.label,
    .describe_item = AddCode.describe,
    .item_counts = &add_item_counts,
    .runCase = runAddCase,
    .write_workload = writeSparseWorkload,
    .cases = &suite.serial_cases,
};

const Workload = enum { frame, pan, add_outside, add_in_window };

fn runFrameCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, item_count, .frame, .insertion);
}

fn runPanCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, item_count, .pan, .chunk_ordered);
}

fn runPanInterleavedCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, item_count, .pan, .interleaved);
}

fn runPanChurnedCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, item_count, .pan, .churned);
}

fn runAddCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const add = try AddCode.decode(item_count);
    const workload: Workload = switch (add.kind) {
        .outside => .add_outside,
        .in_window => .add_in_window,
    };
    return runCase(allocator, io, options, case, item_count, add.tiles, workload, .insertion);
}

// Empty cell of the window block's top-left chunk: inside the camera, off the
// block, so the untimed clear drops only the tile this case added.
const in_window_add_x: u16 = window_block_x & ~@as(u16, default_chunk_size_tiles - 1);
const in_window_add_y: u16 = window_block_y & ~@as(u16, default_chunk_size_tiles - 1);

const Fixture = struct {
    world: WorldSystem,
    batch: SpriteBatch,
    texture: TextureId,
    window_tile: TileId,
    // Blocking, so the untimed drop goes through `clearCellBlocking`.
    added_tile: TileId,
    floor_tile: TileId,
    sparse_count: usize,

    fn deinit(self: *Fixture) void {
        self.batch.deinit();
        self.world.deinit();
        self.* = undefined;
    }

    fn cameraRect(self: *const Fixture, step_chunks: i32) Rect {
        const tile_size = self.world.tile_size;
        const chunk_px = @as(f32, @floatFromInt(default_chunk_size_tiles)) * tile_size;
        return .{
            .x = @as(f32, @floatFromInt(camera_tile_x)) * tile_size + @as(f32, @floatFromInt(step_chunks)) * chunk_px,
            .y = @as(f32, @floatFromInt(camera_tile_y)) * tile_size,
            .w = viewport_w,
            .h = viewport_h,
        };
    }

    // One frame's sparse prep for the camera `step_chunks` right of its start:
    // window update, depth range walk, and submit. Returns the sprites submitted.
    fn frame(self: *Fixture, step_chunks: i32) !usize {
        return self.frameExpect(step_chunks, window_tile_count);
    }

    fn frameExpect(self: *Fixture, step_chunks: i32, expect_tiles: usize) !usize {
        const world = &self.world;
        self.batch.beginFrame();
        try world.setVisibleChunksForWorldRect(self.cameraRect(step_chunks), overscan_chunks, active_level);
        if (world.reserveRenderRecords() != expect_tiles) return error.WindowSparseCountMismatch;
        var submitted: usize = 0;
        for (0..world.sparseDepthRangeCount()) |range_index| {
            submitted += try world.submitVisibleSparseSprites(&self.batch, self.texture, range_index);
        }
        if (submitted != expect_tiles) return error.WindowSparseSubmitMismatch;
        return submitted;
    }

    fn addOutsideTile(self: *Fixture) !void {
        const event = try self.world.addSparseTile(added_tile_level, added_tile_x, added_tile_y, self.added_tile, 0, .marker);
        if (event == null) return error.AddedTileBlocksMovement;
        // Before the frame rebuild, which clears the flag.
        if (self.world.sparse_window.dirty) return error.OutsideAddDirtiedWindow;
    }

    // One in-window tile, one queued chunk, fixed camera. The run is that chunk's
    // rows; outside tiles sit in other chunks, so the run and the list stay within
    // the window's tiles plus this one.
    fn addInWindowTile(self: *Fixture) !struct { run_rows: usize, window_rows: usize } {
        const world = &self.world;
        const event = try world.addSparseTile(active_level, in_window_add_x, in_window_add_y, self.added_tile, 0, .marker);
        if (event == null) return error.AddedTileBlocksMovement;
        const window = &world.sparse_window;
        if (!window.dirty or window.edited.items.len != 1) return error.InWindowPatchNotOneChunk;
        const edit = window.edited.items[0];
        const geom = world.chunkGeometry();
        if (edit.level != active_level or edit.chunk != geom.chunkOf(in_window_add_x, in_window_add_y)) return error.InWindowPatchNotOneChunk;
        const run_rows = world.level_terrain.items[edit.level].sparse_runs[edit.chunk].rows.len;
        const window_rows = window.rows.len;
        if (run_rows == 0 or run_rows > window_tile_count + 1) return error.PatchRunGrewWithOutsideTiles;
        if (window_rows == 0 or window_rows > window_tile_count + 1) return error.PatchSpliceGrewWithOutsideTiles;
        return .{ .run_rows = run_rows, .window_rows = window_rows };
    }

    // The patch read that one run, sorted its in-window tiles, and spliced the
    // window list. A recount of window chunks does not match the run.
    fn expectInWindowPatch(self: *const Fixture, run_rows: usize, window_rows: usize) !void {
        const perf = self.world.perf;
        if (perf.sparse_patch_run_rows != @as(u64, run_rows)) return error.PatchRunNotEditedChunk;
        if (perf.sparse_patch_tiles != @as(u64, run_rows)) return error.PatchTilesNotEditedRun;
        if (perf.sparse_patch_window_rows != @as(u64, window_rows)) return error.PatchSpliceNotWindowRows;
    }

    // Drops the tile `addOutsideTile` wrote through the production clear.
    fn dropAddedTile(self: *Fixture) !void {
        try self.dropTile(added_tile_level, added_tile_x, added_tile_y);
    }

    fn dropInWindowTile(self: *Fixture) !void {
        try self.dropTile(active_level, in_window_add_x, in_window_add_y);
    }

    fn dropTile(self: *Fixture, level: u16, x: u16, y: u16) !void {
        const cleared = try self.world.clearCellBlocking(level, x, y, self.floor_tile);
        if (cleared == null) return error.AddedTileIndexMismatch;
        if (@as(usize, self.world.sparse_live) != self.sparse_count) return error.AddedTileCountMismatch;
    }

    fn resetAdd(self: *Fixture, workload: Workload) !void {
        switch (workload) {
            .add_outside => try self.dropAddedTile(),
            .add_in_window => try self.dropInWindowTile(),
            .frame, .pan => {},
        }
    }
};

const SparseLayout = enum { insertion, chunk_ordered, interleaved, churned };

const layout_shuffle_seed: u64 = 0x87c0_a5e1;

const SparseCell = struct { level: u16, x: u16, y: u16, depth: WorldDepth };

fn sparseCellLessThan(geom: ChunkGeometry, a: SparseCell, b: SparseCell) bool {
    if (a.level != b.level) return a.level < b.level;
    const chunk_a = geom.chunkOf(a.x, a.y);
    const chunk_b = geom.chunkOf(b.x, b.y);
    if (chunk_a != chunk_b) return chunk_a < chunk_b;
    if (a.y != b.y) return a.y < b.y;
    return a.x < b.x;
}

fn assertSparseRuns(world: *const WorldSystem, sparse_count: usize) void {
    std.debug.assert(@as(usize, world.sparse_live) == sparse_count);
    const geom = world.chunkGeometry();
    var live: u32 = 0;
    for (world.level_terrain.items, 0..) |terrain, level_index| {
        for (terrain.sparse_runs, 0..) |run, chunk_index| {
            if (run.rows.len == 0) {
                std.debug.assert(run.rows.capacity == 0);
                continue;
            }
            const rows = run.rows.slice();
            const levels = rows.items(.level_index);
            const cells = rows.items(.cell_index);
            for (levels, cells) |row_level, cell| {
                std.debug.assert(row_level == @as(u16, @intCast(level_index)));
                const x: u16 = @intCast(cell % world.width);
                const y: u16 = @intCast(cell / world.width);
                std.debug.assert(geom.chunkOf(x, y) == chunk_index);
            }
            live += @intCast(run.rows.len);
        }
    }
    std.debug.assert(live == world.sparse_live);
}

// The world reads the tileset metadata only while it builds; `sourceRect` reads its catalog.
fn initFixture(fixture: *Fixture, allocator: std.mem.Allocator, io: std.Io, sparse_count: usize, layout: SparseLayout) !void {
    std.debug.assert(sparse_count >= window_tile_count);
    var meta = try fixtures.loadTilesetMeta(allocator, io);
    defer meta.deinit();
    fixture.* = .{
        .world = .{
            .allocator = allocator,
            .width = world_side,
            .height = world_side,
            .tile_size = meta.tileSize(),
            .chunk_size_tiles = default_chunk_size_tiles,
        },
        .batch = SpriteBatch.init(allocator),
        .texture = TextureId.init(1, 1) catch unreachable,
        .window_tile = undefined,
        .added_tile = undefined,
        .floor_tile = undefined,
        .sparse_count = sparse_count,
    };
    errdefer fixture.batch.deinit();
    errdefer fixture.world.deinit();
    const world = &fixture.world;
    try world.buildCatalog(&meta);
    fixture.window_tile = try world.requireTileByName(&meta, "deco_0");
    const blocking_tile = try world.requireTileByName(&meta, "tree_0");
    const floor_tile = try world.requireTileByName(&meta, "stone_floor");
    fixture.added_tile = blocking_tile;
    fixture.floor_tile = floor_tile;
    std.debug.assert(world.flagsFor(blocking_tile).blocks_movement);
    std.debug.assert(!world.flagsFor(floor_tile).blocks_movement);
    for (0..world_levels) |level_index| {
        _ = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
    }

    var cells: std.ArrayList(SparseCell) = .empty;
    defer cells.deinit(allocator);
    try cells.ensureTotalCapacity(allocator, sparse_count);
    for (0..window_tile_count) |index| {
        cells.appendAssumeCapacity(.{
            .level = active_level,
            .x = window_block_x + @as(u16, @intCast(index % window_block_edge)),
            .y = window_block_y + @as(u16, @intCast(index / window_block_edge)),
            .depth = window_depths[index % window_depths.len],
        });
    }
    // The rest spread over every level's outside rows, row-major on a fixed column
    // stride, with the row stride spreading each level's share over the rows.
    const outside_count = sparse_count - window_tile_count;
    const per_level = @divCeil(outside_count, world_levels);
    const outside_rows = @max(1, @divCeil(per_level, outside_columns));
    const row_stride: usize = (world_side - outside_first_row) / outside_rows;
    std.debug.assert(row_stride >= 1);
    for (0..outside_count) |index| {
        const level: u16 = @intCast(index % world_levels);
        const slot = index / world_levels;
        const x: u16 = @intCast((slot % outside_columns) * outside_column_stride + level);
        const y: u16 = @intCast(outside_first_row + (slot / outside_columns) * row_stride);
        std.debug.assert(y < world_side);
        cells.appendAssumeCapacity(.{
            .level = level,
            .x = x,
            .y = y,
            .depth = window_depths[index % window_depths.len],
        });
    }

    // Frame and add keep this insertion order. The pan layouts reorder the same cells.
    const tile = if (layout == .insertion) fixture.window_tile else blocking_tile;
    switch (layout) {
        .insertion => {},
        .chunk_ordered, .churned => std.mem.sort(SparseCell, cells.items, world.chunkGeometry(), sparseCellLessThan),
        .interleaved => {
            var prng = std.Random.DefaultPrng.init(layout_shuffle_seed);
            prng.random().shuffle(SparseCell, cells.items);
        },
    }
    for (cells.items) |cell| {
        _ = try world.addSparseTile(cell.level, cell.x, cell.y, tile, 0, cell.depth);
    }
    if (layout == .churned) {
        var index: usize = 0;
        while (index < cells.items.len) : (index += 2) {
            const cell = cells.items[index];
            const cleared = try world.clearCellBlocking(cell.level, cell.x, cell.y, floor_tile);
            std.debug.assert(cleared != null);
            _ = try world.addSparseTile(cell.level, cell.x, cell.y, tile, 0, cell.depth);
        }
    }
    assertSparseRuns(world, sparse_count);

    try fixture.batch.reserveStorage(window_tile_count, window_tile_count * 6, window_tile_count);
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, sparse_count: usize, workload: Workload, layout: SparseLayout) !suite.RunStats {
    std.debug.assert(!case.usesThreadSystem());
    var fixture: Fixture = undefined;
    try initFixture(&fixture, allocator, io, sparse_count, layout);
    defer fixture.deinit();
    // The first frame builds the window's sparse list.
    _ = try fixture.frame(0);

    for (0..options.warmup_iterations) |_| {
        _ = try runIteration(&fixture, workload);
        try fixture.resetAdd(workload);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    var submitted: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        submitted = try runIteration(&fixture, workload);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), inlineBatch(submitted, 1));
        try fixture.resetAdd(workload);
    }
    var stats = accumulator.finish();
    // The item count is the world's sparse tile count, so report throughput over the
    // sprites submitted.
    stats.output_count = submitted;
    stats.items_per_second = suite.itemsPerSecond(submitted, stats.mean_ns);
    return stats;
}

// One timed workload; returns the sprites submitted.
fn runIteration(fixture: *Fixture, workload: Workload) !usize {
    return switch (workload) {
        .frame => fixture.frame(0),
        .pan => (try fixture.frame(1)) + try fixture.frame(0),
        .add_outside => blk: {
            try fixture.addOutsideTile();
            break :blk fixture.frame(0);
        },
        .add_in_window => blk: {
            const patch = try fixture.addInWindowTile();
            const submitted = try fixture.frameExpect(0, window_tile_count + 1);
            try fixture.expectInWindowPatch(patch.run_rows, patch.window_rows);
            break :blk submitted;
        },
    };
}

fn writeSparseWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("submitted={}", .{stats.output_count});
}
