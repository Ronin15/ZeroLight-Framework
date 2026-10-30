// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Chunk-owned terrain scaling: one fixed-size terrain change per timed iteration on worlds
//! along two scale axes, each at three sizes with the other fixed: level side 256, 1024, and
//! 2048 at 8 levels, and 8, 32, and 128 levels at side 256. Changes sit at the level center on
//! the deepest levels, terrain changes go through the production writes, and
//! each iteration ends at its start state, its reset untimed. Fixtures and write lists build
//! outside the timed loop. Item codes (`suite.ItemCode`) hold `level side * 1000 + levels` at
//! the bottom and the group's own fields above it.
//!   - `chunk-scale-dig`: 64 digs through the production dig controller
//!     (`DigController.reserveWorldEdit` and `commitWorldEdit`), each its own step with the
//!     player facing one cell per chunk of an 8x8 chunk square on the deepest level, tunnelling
//!     it; only the digs are timed. The reset refills the cells as one batched edit. Flat.
//!   - `chunk-scale-ramp`: the same 64 cells dug as ramps, each linked to the level above with
//!     its exit there cleared walkable. Links are append-only, so the reset builds a fresh
//!     world and every iteration adds its 64 links. Flat.
//!   - `chunk-scale-cave-in`: a chunk-aligned tunnel region of 4, 64, or 256 chunks (64 on the
//!     scale axes), a quarter on each of four stacked levels, collapses to solid and is carved
//!     back, each one batched edit (`applyDenseCellWrites`). Linear in region chunks.
//!   - `chunk-scale-explosion-fill`: a disk inscribed in a 4-, 64-, or 256-chunk square on the
//!     deepest level is blown open and filled back, each one batched edit. Linear in region
//!     chunks. Its sparse-props case (64 chunks at 256², 8 levels) first places 32 blocking
//!     sparse props in every chunk, so each changed cell's blocked bit also reads them.
//!   - `chunk-scale-gpu-sync-dig`: the dig workload with a GPU tile sync after the digs and
//!     after the refills. Flat in level size. Two more axes at 256² (`GpuSyncDigCode`): variant
//!     0 digs the 4 cells of the center 2x2 chunks under a 2-, 6-, or 14-chunk window at 8
//!     levels (linear in window chunks); variant 1 times the syncs after an untimed batched
//!     explosion and fill on every one of 2, 8, or 32 resident layers at 128 levels (linear in
//!     resident layers). Bytes scale with the changed chunks and layers; main is the span
//!     commit. A fixed case whose output exceeds one aligned range runs on workers. The tuned
//!     case settles before it is read. `serial-direct` is this job inline.
//!   - `chunk-scale-gpu-sync-level-enter`: the render window steps one level down and back,
//!     each step one level entering (its window directory and 64 mixed blocks) and one
//!     leaving. Flat.
//!   - `chunk-scale-gpu-sync-pan`: a square window of 2, 6, or 14 chunks (6 on the scale axes)
//!     over the two deepest levels, all mixed chunks, pans one chunk across and back with a
//!     visibility update and a sync per step. A step scans O(layers x e²) window chunks and
//!     uploads the entering column, O(layers x e). Passes when flat in level size and depth
//!     and the edge and resident-layer axes match those orders.
//! Pan and level-enter also run 8 and 32 resident layers at 256² and 128 levels; every other
//! case renders 2. The GPU sync and batched groups render a fixed 8x8-chunk window over the
//! dig cells (pan its own), so GPU work follows the window, never the level. The batched
//! groups run serial, fixed-thread, and adaptive with the two deepest levels resident, so the
//! merge's render flags are timed, and report each stage's time and the main thread's share;
//! `--details` adds both edits' plan and write shapes over the measured steps
//! (`edit_stages:`) and, for the tuned case, each edit tuner's state (`tuners:`). A fixed
//! threaded case runs both edits' stages of more than one range on workers.
//! Single-cell digs and the level-enter and pan GPU syncs are main-thread work and run serial
//! only. `chunk-scale-gpu-sync-dig` runs the value-fill stage on its serial, fixed, and tuned
//! cases. The GPU sync groups drive `syncDenseTileStore` against a headless renderer whose
//! tile store has no GPU buffer: they time planning, the span commit, and the value fill, and
//! drop the upload batch after each sync.
//!
//! The `chunk-scale-nav-*` groups add the nav reaction, with nav over every level of the same
//! fixture (no render window), built and owned by a `SimulationPipeline`: each change's writer
//! records its nav marks and the post-commit reaction applies them as one batch. A config whose
//! nav storage exceeds the nav-size limit fails with its figure. Each runs serial and threaded,
//! with single-cell world writes on the main thread; `--details` prints the main thread's
//! share, the reaction's stage shapes over the measured reactions (`[threaded/non-empty]`),
//! its connectivity and closure block, and its main-thread split; the batched groups add the
//! revert reaction's and both edits' stage shapes. Every measured reaction, forward and
//! revert, runs each nav stage of more than one range on workers in a fixed threaded case
//! (`suite.checkNavReactionDispatched`). The tuned case settles every tuner both nav stage
//! sets and both edits hold before measuring (`step_tuners:`); level-add's settle on its
//! in-band cycles (below).
//!   - `chunk-scale-nav-dig`: the dig workload through the pipeline's production dig
//!     (`reserveDigWorldEdit` and `commitDigWorldEdit`, the nav record included), then one
//!     post-commit reaction to the 64 cells' marks. The reset refills the cells as one batched
//!     edit with its nav record and reaction, on the revert stage tuners. Flat.
//!   - `chunk-scale-nav-ramp`: the ramp workload through the pipeline's dig, then the reaction,
//!     which also adds the 64 links. The reset builds a fresh world and its nav. Flat.
//!   - `chunk-scale-nav-cave-in`, `chunk-scale-nav-explosion-fill`: the batched edits, each
//!     followed by its tile events' nav record (published untimed) and
//!     `reactToPostCommitNavEvents`. Linear in region chunks, flat in level size and depth.
//!   - `chunk-scale-nav-enclose`: one batched edit fills the one-chunk doorways walling
//!     pockets off one open surface component and the next carves them back. Variant 0: P
//!     pockets of 4x4 chunks on a 2048² level (linear in P); variant 1: one pocket of edge E
//!     chunks (linear in its area) and variant 2: a one-chunk tunnel of L chunks closed at its
//!     mouth (linear in L), each on a 1024² level.
//!   - `chunk-scale-nav-level-add`: one level added with a solid floor band, then nav updated.
//!     The replace case (`LevelAddCode`) first adds a walkable level and updates nav untimed,
//!     then times a blocking band on it and the update. A level add is a one-off jump amid
//!     ordinary nav work, so the case runs the spike shape: the stage tuners settle on
//!     in-band cycles (the nav-dig workload's dig and reaction, then its refill and reaction
//!     on the revert set, which return terrain and nav to their start state), then warmup
//!     level adds each grow the per-range scratch (the fresh build set's full-pool first
//!     selections), and each measured step runs one in-band cycle untimed before the timed
//!     level add. Every case runs at least two in-band cycles and then one per level add, so
//!     the world is the same in every case. Depth grows by one per level add, warmup included, so A/B runs use the
//!     same `--warmup` and `--iterations`. Each reaction builds one level, its remask batch
//!     over that level's chunks and the step's dirty chunks.

const std = @import("std");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const inlineBatch = @import("../app/thread_system.zig").inlineBatch;
const offMainNs = @import("../app/thread_system.zig").offMainNs;
const runtime_perf_log = @import("../app/runtime_perf_log.zig");
const GpuTileCopyThreads = @import("../game/world/gpu_tiles.zig").GpuTileCopyThreads;
const gpu_tile_copy_range_alignment_items = @import("../game/world/gpu_tiles.zig").gpu_tile_copy_range_alignment_items;
const DigConfig = @import("../game/dig_controller.zig").DigConfig;
const DigController = @import("../game/dig_controller.zig").DigController;
const Player = @import("../game/player.zig").Player;
const SimulationPipeline = @import("../game/simulation_pipeline.zig").SimulationPipeline;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const CellCoord = @import("../game/world/system.zig").CellCoord;
const DenseCellWrite = @import("../game/world/edit.zig").DenseCellWrite;
const DenseChunkWrites = @import("../game/world/edit.zig").DenseChunkWrites;
const TerrainEditThreads = @import("../game/world/edit.zig").TerrainEditThreads;
const WorldTileChangedEvent = @import("../game/simulation.zig").WorldTileChangedEvent;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const DigIntent = @import("../game/simulation.zig").DigIntent;
const stimulus_live_capacity = @import("../game/simulation.zig").stimulus_live_capacity;
const TileId = @import("../game/world/system.zig").TileId;
const invalid_tile_id = @import("../game/world/system.zig").invalid_tile_id;
const level_z_step = @import("../game/world/system.zig").level_z_step;
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;
const Renderer = @import("../render/renderer.zig").Renderer;
const TilemapParams = @import("../render/renderer.zig").TilemapParams;
const tile_store_max_elements = @import("../render/renderer.zig").tile_store_max_elements;
const tileStoreBlockElements = @import("../render/renderer.zig").tileStoreBlockElements;
const SpriteBatch = @import("../render/sprite_batch.zig").SpriteBatch;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const PathfindingSystem = @import("../game/systems/pathfinding.zig").PathfindingSystem;
const PathfindingCapacity = @import("../game/systems/pathfinding.zig").PathfindingCapacity;
const NavUpdateStats = @import("../game/systems/pathfinding.zig").NavUpdateStats;
const min_capacity_floor = @import("../game/systems/pathfinding/types.zig").min_capacity_floor;
const default_max_group_fields = @import("../game/systems/pathfinding/types.zig").default_max_group_fields;
const pathfinding_test_support = @import("../game/systems/pathfinding/test_support.zig");
const fixtures = @import("fixtures.zig");
const nav_size = @import("nav_size.zig");
const suite = @import("suite.zig");

// Item codes: the level side and count at the bottom, each group's fields above them.
const ScaleCode = suite.ItemCode(struct { level_side: u16, levels: u16 }, &.{3});
const RegionCode = suite.ItemCode(struct { sparse_props: bool, region_chunks: usize, level_side: u16, levels: u16 }, &.{ 3, 4, 3 });
const GpuSyncDigCode = suite.ItemCode(struct { variant: GpuSyncDigVariant, resident_layers: u16, window_edge: u16, level_side: u16, levels: u16 }, &.{ 2, 2, 4, 3 });
// Pan and level-enter configs; 0 resident layers is the default two, and level-enter's window
// edge is 0 (the fixed dig window).
const WindowCode = suite.ItemCode(struct { resident_layers: u16, window_edge: u16, level_side: u16, levels: u16 }, &.{ 2, 4, 3 });
const LevelAddCode = suite.ItemCode(struct { replace: bool, level_side: u16, levels: u16 }, &.{ 4, 3 });
const EncloseCode = suite.ItemCode(struct { variant: EncloseVariant, count: u16, level_side: u16, levels: u16 }, &.{ 3, 4, 3 });

// The scale axes: level side at the shallowest depth, then depth at the smallest side.
const level_sides = [_]u16{ 256, 1024, 2048 };
const level_counts = [_]u16{ 8, 32, 128 };
const scale_axes_len = level_sides.len + level_counts.len - 1;

const scale_axes: [scale_axes_len][2]u16 = blk: {
    var axes: [scale_axes_len][2]u16 = undefined;
    for (level_sides, 0..) |side, index| axes[index] = .{ side, level_counts[0] };
    for (level_counts[1..], level_sides.len..) |levels, index| axes[index] = .{ level_sides[0], levels };
    break :blk axes;
};

const scale_item_counts = blk: {
    var counts: [scale_axes_len]usize = undefined;
    for (scale_axes, &counts) |axis, *count| count.* = ScaleCode.of(.{ .level_side = axis[0], .levels = axis[1] });
    break :blk counts;
};

// Region sizes of the batched groups, in chunks touched by one edit: the region axis at the
// smallest scale, then the scale axes at the middle region.
const region_chunk_counts = [_]usize{ 4, 64, 256 };
const scale_axis_region: usize = 64;

const region_item_counts = blk: {
    var counts: [region_chunk_counts.len + scale_axes_len - 1]usize = undefined;
    for (region_chunk_counts, 0..) |region, index| {
        counts[index] = RegionCode.of(.{ .sparse_props = false, .region_chunks = region, .level_side = level_sides[0], .levels = level_counts[0] });
    }
    for (scale_axes[1..], region_chunk_counts.len..) |axis, index| {
        counts[index] = RegionCode.of(.{ .sparse_props = false, .region_chunks = scale_axis_region, .level_side = axis[0], .levels = axis[1] });
    }
    break :blk counts;
};

// Blocking sparse props per chunk of the sparse-props case: every cell whose
// (3 * x + 5 * y) % 8 is zero, 32 of a 16x16 chunk's cells.
const sparse_props_stride: u16 = 8;

const explosion_item_counts = blk: {
    var counts: [region_item_counts.len + 1]usize = undefined;
    @memcpy(counts[0..region_item_counts.len], &region_item_counts);
    // The sparse-props case's one config: the middle region at the smallest scale.
    counts[region_item_counts.len] = RegionCode.of(.{ .sparse_props = true, .region_chunks = scale_axis_region, .level_side = level_sides[0], .levels = level_counts[0] });
    break :blk counts;
};

// Pan group window edges, in chunks; each window and the column it pans into fit
// the smallest level.
const pan_window_edges = [_]u16{ 2, 6, 14 };
// The edge the scale and resident-layer axes pan at.
const pan_axis_edge: u16 = 6;

// The pan region's columns: the window and the column it pans into.
fn panRegionColumns(window_edge: u16) u16 {
    return window_edge + 1;
}

// The GPU sync groups' resident layers by default: `active_level` and the one below.
const default_resident_layers: u16 = 2;
// The pan and level-enter groups' resident-layer axis past the default, at the smallest side
// and deepest depth, which holds them.
const resident_layer_axis = [_]u16{ 8, 32 };

const pan_item_counts = blk: {
    var counts: [pan_window_edges.len + scale_axes_len - 1 + resident_layer_axis.len]usize = undefined;
    for (pan_window_edges, 0..) |edge, index| {
        std.debug.assert(panRegionColumns(edge) <= level_sides[0] / default_chunk_size_tiles);
        counts[index] = WindowCode.of(.{ .resident_layers = 0, .window_edge = edge, .level_side = level_sides[0], .levels = level_counts[0] });
    }
    for (scale_axes[1..], pan_window_edges.len..) |axis, index| {
        counts[index] = WindowCode.of(.{ .resident_layers = 0, .window_edge = pan_axis_edge, .level_side = axis[0], .levels = axis[1] });
    }
    for (resident_layer_axis, pan_window_edges.len + scale_axes_len - 1..) |layers, index| {
        counts[index] = WindowCode.of(.{ .resident_layers = layers, .window_edge = pan_axis_edge, .level_side = level_sides[0], .levels = level_counts[level_counts.len - 1] });
    }
    break :blk counts;
};

const level_enter_item_counts = blk: {
    var counts: [scale_axes_len + resident_layer_axis.len]usize = undefined;
    @memcpy(counts[0..scale_axes_len], &scale_item_counts);
    for (resident_layer_axis, scale_axes_len..) |layers, index| {
        counts[index] = WindowCode.of(.{ .resident_layers = layers, .window_edge = 0, .level_side = level_sides[0], .levels = level_counts[level_counts.len - 1] });
    }
    break :blk counts;
};

// Elements one pan iteration (a step across and back) uploads: per resident layer
// and step, the entering column's `window_edge` mixed chunks, each a directory word
// and a whole block.
fn expectedPanUploads(window_edge: u16, resident_layers: u16) usize {
    const steps = 2;
    return @as(usize, resident_layers) * steps * window_edge * (1 + tileStoreBlockElements(default_chunk_size_tiles));
}

const dig_cell_count: u16 = 64;
const cave_in_levels: u16 = 4;
// Batched edits are independent chunks: ranges need no alignment, and the fixed
// controls' range modes scale from one chunk per range.
const edit_range_alignment_items: usize = 1;
// The edit-only batched groups' one fixed-control shape: the plan and write stages.
const edit_fixed_range_shape: suite.FixedRangeShape = .{
    .partition_items = suite.chunk_partition_items,
    .range_alignment_items = edit_range_alignment_items,
};
// The fixed render window of the dig, level-enter, and batched groups, in chunks: the
// dig workload's 8x8 chunk square at the level center.
const dig_window_chunks: u16 = 8;

pub const dig_group = suite.BenchmarkGroup{
    .name = "chunk-scale-dig",
    .item_label = ScaleCode.label,
    .describe_item = ScaleCode.describe,
    .item_counts = &scale_item_counts,
    .runCase = runDigCase,
    .write_workload = writeCellsWorkload,
    .cases = &suite.serial_cases,
};

pub const ramp_group = suite.BenchmarkGroup{
    .name = "chunk-scale-ramp",
    .item_label = ScaleCode.label,
    .describe_item = ScaleCode.describe,
    .item_counts = &scale_item_counts,
    .runCase = runRampCase,
    .write_workload = writeCellsWorkload,
    .cases = &suite.serial_cases,
};

pub const cave_in_group = suite.BenchmarkGroup{
    .name = "chunk-scale-cave-in",
    .item_label = RegionCode.label,
    .describe_item = RegionCode.describe,
    .item_counts = &region_item_counts,
    .runCase = runCaveInCase,
    .write_workload = writeBatchWorkload,
    .fixed_range_shape = edit_fixed_range_shape,
};

pub const explosion_fill_group = suite.BenchmarkGroup{
    .name = "chunk-scale-explosion-fill",
    .item_label = RegionCode.label,
    .describe_item = RegionCode.describe,
    .item_counts = &explosion_item_counts,
    .runCase = runExplosionFillCase,
    .write_workload = writeBatchWorkload,
    .fixed_range_shape = edit_fixed_range_shape,
};

pub const gpu_sync_dig_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-dig",
    .item_label = GpuSyncDigCode.label,
    .describe_item = GpuSyncDigCode.describe,
    .item_counts = &gpu_sync_dig_item_counts,
    .runCase = runGpuSyncDigCase,
    .write_workload = writeUploadsWorkload,
};

pub const gpu_sync_level_enter_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-level-enter",
    .item_label = WindowCode.label,
    .describe_item = WindowCode.describe,
    .item_counts = &level_enter_item_counts,
    .runCase = runGpuSyncLevelEnterCase,
    .write_workload = writeUploadsWorkload,
    .cases = &suite.serial_cases,
};

pub const gpu_sync_pan_group = suite.BenchmarkGroup{
    .name = "chunk-scale-gpu-sync-pan",
    .item_label = WindowCode.label,
    .describe_item = WindowCode.describe,
    .item_counts = &pan_item_counts,
    .runCase = runGpuSyncPanCase,
    .write_workload = writeUploadsWorkload,
    .cases = &suite.serial_cases,
};

pub const nav_dig_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-dig",
    .item_label = ScaleCode.label,
    .describe_item = ScaleCode.describe,
    .item_counts = &scale_item_counts,
    .runCase = runNavDigCase,
    .write_workload = writeNavCellsWorkload,
};

pub const nav_ramp_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-ramp",
    .item_label = ScaleCode.label,
    .describe_item = ScaleCode.describe,
    .item_counts = &scale_item_counts,
    .runCase = runNavRampCase,
    .write_workload = writeNavCellsWorkload,
};

pub const nav_cave_in_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-cave-in",
    .item_label = RegionCode.label,
    .describe_item = RegionCode.describe,
    .item_counts = &region_item_counts,
    .runCase = runNavCaveInCase,
    .write_workload = writeNavBatchWorkload,
};

pub const nav_explosion_fill_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-explosion-fill",
    .item_label = RegionCode.label,
    .describe_item = RegionCode.describe,
    .item_counts = &region_item_counts,
    .runCase = runNavExplosionFillCase,
    .write_workload = writeNavBatchWorkload,
};

pub const nav_enclose_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-enclose",
    .item_label = EncloseCode.label,
    .describe_item = EncloseCode.describe,
    .item_counts = &enclose_item_counts,
    .runCase = runNavEncloseCase,
    .write_workload = writeNavBatchWorkload,
};

pub const nav_level_add_group = suite.BenchmarkGroup{
    .name = "chunk-scale-nav-level-add",
    .item_label = LevelAddCode.label,
    .describe_item = LevelAddCode.describe,
    .item_counts = &level_add_item_counts,
    .runCase = runNavLevelAddCase,
    .write_workload = writeLevelAddWorkload,
};

// The cells a single-cell group wrote.
fn writeCellsWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("cells={}", .{stats.output_count});
}

// The elements a GPU sync group uploaded.
fn writeUploadsWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("uploaded={}", .{stats.output_count});
    try suite.writeMainShare(writer, stats, stats.output_count);
}

// A batched edit's cells and chunks; under --details its plan and write stages, their
// times, and the main thread's share.
fn writeBatchWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("cells={} chunks={}", .{ stats.output_count, stats.batch.item_count });
    if (view == .summary) return;
    const phases = stats.terrain_edit_phases orelse suite.TerrainEditPhaseSummary{};
    try writer.writeAll(" plan=");
    try suite.writeStageShape(writer, stats.secondary_batch orelse .{});
    try writer.writeAll(" write=");
    try suite.writeStageShape(writer, stats.batch);
    try writer.print(" plan_t={f} write_t={f}", .{ suite.formatDuration(phases.plan_ns), suite.formatDuration(phases.write_ns) });
    try suite.writeShare(writer, "main", phases.main_ns, stats.mean_ns);
}

// A nav group's cells changed; under --details the main thread's share (per cell) and its
// nav reaction's stages.
fn writeNavCellsWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("cells={}", .{stats.output_count});
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, stats.output_count);
    try writer.writeByte(' ');
    try suite.writeNavStages(writer, stats);
}

// A batched nav group's cells; under --details its nav stages, the terrain and nav
// reaction times, and the main thread's share.
fn writeNavBatchWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("cells={}", .{stats.output_count});
    if (view == .summary) return;
    try writer.writeByte(' ');
    try suite.writeNavStages(writer, stats);
    const phases = stats.terrain_edit_phases orelse suite.TerrainEditPhaseSummary{};
    try writer.print(" plan_t={f} write_t={f} nav_t={f}", .{ suite.formatDuration(phases.plan_ns), suite.formatDuration(phases.write_ns), suite.formatDuration(phases.nav_ns) });
    try suite.writeShare(writer, "main", phases.main_ns, stats.mean_ns);
}

// The levels after the run; under --details the main thread's share (per level added) and
// the reaction's stages.
fn writeLevelAddWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("levels={}", .{stats.output_count});
    if (view == .summary) return;
    try suite.writeMainShare(writer, stats, 1);
    try writer.writeByte(' ');
    try suite.writeNavStages(writer, stats);
}

const level_add_item_counts = blk: {
    var counts: [2 * scale_axes_len]usize = undefined;
    for (scale_axes, 0..) |axis, index| {
        counts[index] = LevelAddCode.of(.{ .replace = false, .level_side = axis[0], .levels = axis[1] });
        counts[scale_axes_len + index] = LevelAddCode.of(.{ .replace = true, .level_side = axis[0], .levels = axis[1] });
    }
    break :blk counts;
};

const enclose_pocket_edge: u16 = 4;
const enclose_tunnel_row: u16 = 8;
const enclose_item_counts = [_]usize{
    // Every pocket count on one level side, so only the pockets vary.
    EncloseCode.of(.{ .variant = .pockets, .count = 16, .level_side = 2048, .levels = 1 }),
    EncloseCode.of(.{ .variant = .pockets, .count = 64, .level_side = 2048, .levels = 1 }),
    EncloseCode.of(.{ .variant = .pockets, .count = 196, .level_side = 2048, .levels = 1 }),
    EncloseCode.of(.{ .variant = .pocket_edge, .count = 8, .level_side = 1024, .levels = 1 }),
    EncloseCode.of(.{ .variant = .pocket_edge, .count = 16, .level_side = 1024, .levels = 1 }),
    EncloseCode.of(.{ .variant = .pocket_edge, .count = 32, .level_side = 1024, .levels = 1 }),
    EncloseCode.of(.{ .variant = .tunnel, .count = 8, .level_side = 1024, .levels = 1 }),
    EncloseCode.of(.{ .variant = .tunnel, .count = 32, .level_side = 1024, .levels = 1 }),
    EncloseCode.of(.{ .variant = .tunnel, .count = 62, .level_side = 1024, .levels = 1 }),
};

const Workload = enum { gpu_sync_dig, gpu_sync_level_enter, gpu_sync_pan };

// The dig and ramp groups' workloads (plain and nav): tunnel digs or ramp digs.
const DigWorkload = enum {
    dig,
    ramp,

    fn intent(self: DigWorkload) DigIntent {
        return switch (self) {
            .dig => .hole,
            .ramp => .ramp,
        };
    }

    // The events one dig publishes: its cell's change, and a ramp's exit.
    fn eventsPerDig(self: DigWorkload) usize {
        return switch (self) {
            .dig => 1,
            .ramp => 2,
        };
    }
};

const BatchWorkload = enum { cave_in, explosion_fill };

const NavBatchWorkload = enum { cave_in, explosion_fill, enclose };

fn runDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runControllerDigCase(allocator, io, options, case, item_count, .dig);
}

fn runRampCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runControllerDigCase(allocator, io, options, case, item_count, .ramp);
}

fn runCaveInCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runBatchCase(allocator, io, options, case, item_count, .cave_in);
}

fn runExplosionFillCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runBatchCase(allocator, io, options, case, item_count, .explosion_fill);
}

fn runGpuSyncDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    const config = try GpuSyncDigConfig.decode(item_count);
    return switch (config.variant) {
        .digs => runCase(allocator, io, options, case, item_count, .gpu_sync_dig, .{
            .side = config.side,
            .levels = config.levels,
            .window_edge = config.window_edge,
        }),
        .batched => runGpuSyncBatchCase(allocator, io, options, case, item_count, config),
    };
}

fn runGpuSyncLevelEnterCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .gpu_sync_level_enter, try CaseShape.decodeWindow(item_count, false));
}

fn runGpuSyncPanCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCase(allocator, io, options, case, item_count, .gpu_sync_pan, try CaseShape.decodeWindow(item_count, true));
}

// A GPU sync case's world and render window.
const CaseShape = struct {
    side: u16,
    levels: u16,
    resident_layers: u16 = default_resident_layers,
    // The pan group's window edge; for the gpu-sync-dig group, its window edge, or 0 for
    // the fixed dig window.
    window_edge: u16 = 0,

    // The pan group's codes (`pan`: a window edge) and level-enter's (no edge).
    fn decodeWindow(item_count: usize, pan: bool) !CaseShape {
        const code = try WindowCode.decode(item_count);
        if (pan != (code.window_edge != 0)) return error.ChunkScaleWindowEdgeMismatch;
        return .{
            .side = code.level_side,
            .levels = code.levels,
            .resident_layers = if (code.resident_layers == 0) default_resident_layers else code.resident_layers,
            .window_edge = code.window_edge,
        };
    }
};

// The gpu-sync-dig group's variants: the dig workload with a sync after the digs and after
// the refills, or one batched change over every resident layer with a sync after it and
// after its reversal.
const GpuSyncDigVariant = enum(u8) { digs, batched };
// The dig variant's window-edge axis: the window edges of the pan group over the digs of
// the fixed dig square's center 2x2 chunks, the same edits at every edge, at the smallest
// scale.
const gpu_sync_edge_dig_square: u16 = 2;
// The batched variant's written resident layers, at the smallest side and deepest depth,
// which holds them.
const gpu_sync_batch_layers = [_]u16{ 2, 8, 32 };

const GpuSyncDigConfig = struct {
    variant: GpuSyncDigVariant,
    side: u16,
    levels: u16,
    resident_layers: u16,
    // The dig variant's window edge; 0 is the fixed dig window over the 64-cell dig square.
    window_edge: u16,

    // Each config has one code: the dig variant leaves the layers field 0 (it renders the
    // default two) and the batched variant the edge field 0 (it renders the fixed dig window).
    fn decode(item_count: usize) !GpuSyncDigConfig {
        const code = try GpuSyncDigCode.decode(item_count);
        if (std.mem.indexOfScalar(u16, &level_sides, code.level_side) == null) return error.GpuSyncDigBadLevelSide;
        if (std.mem.indexOfScalar(u16, &level_counts, code.levels) == null) return error.GpuSyncDigBadLevelCount;
        var config = GpuSyncDigConfig{
            .variant = code.variant,
            .side = code.level_side,
            .levels = code.levels,
            .resident_layers = default_resident_layers,
            .window_edge = 0,
        };
        switch (code.variant) {
            .digs => {
                if (code.resident_layers != 0) return error.GpuSyncDigLayersOnDigs;
                if (code.window_edge != 0) {
                    if (std.mem.indexOfScalar(u16, &pan_window_edges, code.window_edge) == null) return error.GpuSyncDigBadWindowEdge;
                    if (code.level_side != level_sides[0] or code.levels != level_counts[0]) return error.GpuSyncDigBadEdgeAxisScale;
                    config.window_edge = code.window_edge;
                }
            },
            .batched => {
                if (code.window_edge != 0) return error.GpuSyncDigEdgeOnBatched;
                if (std.mem.indexOfScalar(u16, &gpu_sync_batch_layers, code.resident_layers) == null) return error.GpuSyncDigBadBatchLayers;
                if (code.level_side != level_sides[0] or code.levels != level_counts[level_counts.len - 1]) return error.GpuSyncDigBadBatchScale;
                config.resident_layers = code.resident_layers;
            },
        }
        return config;
    }
};

const gpu_sync_dig_item_counts = blk: {
    var counts: [scale_axes_len + pan_window_edges.len + gpu_sync_batch_layers.len]usize = undefined;
    for (scale_axes, 0..) |axis, index| {
        counts[index] = GpuSyncDigCode.of(.{ .variant = .digs, .resident_layers = 0, .window_edge = 0, .level_side = axis[0], .levels = axis[1] });
    }
    for (pan_window_edges, scale_axes_len..) |edge, index| {
        counts[index] = GpuSyncDigCode.of(.{ .variant = .digs, .resident_layers = 0, .window_edge = edge, .level_side = level_sides[0], .levels = level_counts[0] });
    }
    for (gpu_sync_batch_layers, scale_axes_len + pan_window_edges.len..) |layers, index| {
        counts[index] = GpuSyncDigCode.of(.{ .variant = .batched, .resident_layers = layers, .window_edge = 0, .level_side = level_sides[0], .levels = level_counts[level_counts.len - 1] });
    }
    break :blk counts;
};

const Fixture = struct {
    world: WorldSystem,
    dirt: TileId,
    tunnel: TileId,
    ramp: TileId,
    dig: DigConfig,
    // A blocking sparse prop.
    prop: TileId,
    side: u16,
    levels: u16,
    // GPU sync groups only: a headless renderer holding the world's tile store.
    renderer: ?Renderer = null,
    // Pan group only: the window edge and its start chunk.
    pan_window_edge: u16 = 0,
    // GPU sync groups: levels below the active level in the render window.
    gpu_levels_below: u16 = default_resident_layers - 1,
    pan_origin_chunk_x: u16 = 0,
    pan_origin_chunk_y: u16 = 0,
    // GPU sync dig group: the dig square's edge in chunks, one dug cell per chunk.
    gpu_dig_square: u16 = dig_window_chunks,

    fn deinit(self: *Fixture) void {
        if (self.renderer) |*renderer| {
            for (renderer.tile_stores.items) |*store| {
                store.pending_spans.deinit(renderer.allocator);
                store.pending_values.deinit(renderer.allocator);
            }
            renderer.tile_stores.deinit(renderer.allocator);
            renderer.tile_merge_spans.deinit(renderer.allocator);
            renderer.tile_merge_values.deinit(renderer.allocator);
            renderer.tile_merge_ops.deinit(renderer.allocator);
            renderer.batch.deinit();
        }
        self.world.deinit();
        self.* = undefined;
    }

    // Gives the world a tile store with no GPU buffer, large enough that no sync
    // grows it (growth would create a GPU buffer), laid out for the render window
    // already set, so no sync creates a store either.
    fn attachHeadlessTileStore(self: *Fixture, allocator: std.mem.Allocator) !void {
        std.debug.assert(self.world.visible != null);
        self.renderer = Renderer{
            .allocator = allocator,
            .device = undefined,
            .window = undefined,
            .pipeline = undefined,
            .tilemap_pipeline = undefined,
            .sampler = undefined,
            .vertex_streams = undefined,
            .batch_capacity_vertices = 0,
            .batch = SpriteBatch.init(allocator),
        };
        const renderer = &self.renderer.?;
        try renderer.tile_stores.append(allocator, .{
            // Never dereferenced: syncs only validate and queue.
            .buffer = @ptrFromInt(0x1000),
            .element_capacity = tile_store_max_elements,
            .params = std.mem.zeroes(TilemapParams),
        });
        self.world.gpu_tiles.store = .{ .index = 0, .generation = 1 };
        self.world.gpu_tiles.store_side = self.world.render_side;
    }

    // One GPU tile sync; returns the elements it uploads and drops the batch.
    // Null `threads` runs the value fill inline.
    fn syncGpuTiles(self: *Fixture, active_level: u16, threads: ?GpuTileCopyThreads) !usize {
        const renderer = &self.renderer.?;
        try self.world.syncDenseTileStore(renderer, active_level, threads);
        const store = &renderer.tile_stores.items[0];
        const uploaded = store.pending_values.items.len;
        store.pending_spans.clearRetainingCapacity();
        store.pending_values.clearRetainingCapacity();
        return uploaded;
    }

    // The window's top level for the GPU sync groups: the deepest level is resident.
    fn gpuActiveLevel(self: *const Fixture) u16 {
        return self.levels - 1 - self.gpu_levels_below;
    }

    // Sets the pan window `step_chunks` right of its start, around the GPU active
    // level, with no overscan.
    fn setPanWindow(self: *Fixture, step_chunks: u16) !void {
        try self.setChunkWindow(self.pan_origin_chunk_x + step_chunks, self.pan_origin_chunk_y, self.pan_window_edge);
    }

    // Sets the fixed render window over the dig cells' chunk square, with the resident
    // levels in the level window.
    fn setDigWindow(self: *Fixture) !void {
        try self.setCenteredWindow(dig_window_chunks);
    }

    // Sets an `edge` x `edge` chunk render window at the level center, with the resident
    // levels in the level window.
    fn setCenteredWindow(self: *Fixture, edge: u16) !void {
        self.world.render_window = .{ .levels_below = self.gpu_levels_below };
        const origin_chunk = self.side / default_chunk_size_tiles / 2 - edge / 2;
        try self.setChunkWindow(origin_chunk, origin_chunk, edge);
    }

    // A rect exactly covering `edge` x `edge` chunks from (min_chunk_x, min_chunk_y).
    fn setChunkWindow(self: *Fixture, min_chunk_x: u16, min_chunk_y: u16, edge: u16) !void {
        const chunk_px = @as(f32, @floatFromInt(default_chunk_size_tiles)) * self.world.tile_size;
        const extent = @as(f32, @floatFromInt(edge)) * chunk_px;
        try self.world.setVisibleChunksForWorldRect(.{
            .x = @as(f32, @floatFromInt(min_chunk_x)) * chunk_px,
            .y = @as(f32, @floatFromInt(min_chunk_y)) * chunk_px,
            .w = extent,
            .h = extent,
        }, 0, self.gpuActiveLevel());
        const region = self.world.visibleChunkRegion().?;
        std.debug.assert(region.min.x == min_chunk_x and region.min.y == min_chunk_y);
        std.debug.assert(region.max_exclusive.x == min_chunk_x + edge and region.max_exclusive.y == min_chunk_y + edge);
    }

    // Floor layer of `level`; level `i` owns layer `i`.
    fn floor(self: *const Fixture, level: u16) usize {
        _ = self;
        return level;
    }
};

// A walkable surface over `levels - 1` solid levels, each one uniform dense band.
fn buildFixture(allocator: std.mem.Allocator, io: std.Io, side: u16, levels: u16) !Fixture {
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const meta = &tileset;
    var world = try fixtures.buildBandedWorld(allocator, meta, side, levels, "grass", "dirt");
    errdefer world.deinit();
    const dirt = try world.requireTileByName(meta, "dirt");
    const tunnel = try world.requireTileByName(meta, "cave_0");
    const dig = try DigConfig.fromMeta(meta);
    const prop = try world.requireTileByName(meta, "deco_0");
    return .{ .world = world, .dirt = dirt, .tunnel = tunnel, .ramp = dig.ramp_tile, .dig = dig, .prop = prop, .side = side, .levels = levels };
}

fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: Workload, shape: CaseShape) !suite.RunStats {
    if (workload == .gpu_sync_dig) {
        if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    } else std.debug.assert(!case.usesThreadSystem());
    var threads: ?ThreadSystem = if (workload == .gpu_sync_dig) try fixtures.initCaseThreads(allocator, io, case) else null;
    defer if (threads) |*thread_system| thread_system.deinit();
    const resident_layers = shape.resident_layers;
    const window_edge = shape.window_edge;
    const side = shape.side;
    const levels = shape.levels;
    std.debug.assert(levels >= cave_in_levels + 1 and side >= 256);
    std.debug.assert(resident_layers + 1 <= levels);
    var fixture = try buildFixture(allocator, io, side, levels);
    defer fixture.deinit();
    fixture.gpu_levels_below = resident_layers - 1;
    switch (workload) {
        .gpu_sync_dig => {
            if (window_edge == 0) {
                try fixture.setDigWindow();
            } else {
                fixture.gpu_dig_square = gpu_sync_edge_dig_square;
                try fixture.setCenteredWindow(window_edge);
            }
            try fixture.attachHeadlessTileStore(allocator);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
        },
        .gpu_sync_level_enter => {
            try fixture.setDigWindow();
            try fixture.attachHeadlessTileStore(allocator);
            // 64 mixed chunks on each level the window crosses.
            for (fixture.gpuActiveLevel() - 1..fixture.levels) |level| {
                var dig = try buildDigSquareEdit(allocator, &fixture, @intCast(level), dig_window_chunks);
                defer dig.deinit(allocator);
                try applyDigSquare(&fixture.world, dig.forward_chunks.items, &dig);
            }
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel() - 1, null);
        },
        .gpu_sync_pan => {
            fixture.world.render_window = .{ .levels_below = fixture.gpu_levels_below };
            const columns = panRegionColumns(window_edge);
            const chunks_per_side = side / default_chunk_size_tiles;
            std.debug.assert(columns <= chunks_per_side);
            fixture.pan_window_edge = window_edge;
            fixture.pan_origin_chunk_x = (chunks_per_side - columns) / 2;
            fixture.pan_origin_chunk_y = (chunks_per_side - window_edge) / 2;
            for (fixture.gpuActiveLevel()..fixture.levels) |level| {
                try mixRegion(&fixture, @intCast(level), columns, window_edge);
            }
            try fixture.setPanWindow(0);
            try fixture.attachHeadlessTileStore(allocator);
            _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
        },
    }

    // The dig's batched edit and its refill, built outside the timed loop.
    var dig: BatchEdit = if (workload == .gpu_sync_dig) try buildDigSquareEdit(allocator, &fixture, fixture.levels - 1, fixture.gpu_dig_square) else .{};
    defer dig.deinit(allocator);
    if (workload == .gpu_sync_dig) return measureGpuSyncDig(io, options, case, item_count, &fixture, &dig, if (threads) |*thread_system| thread_system else null);
    for (0..options.warmup_iterations) |_| _ = try runIteration(io, &fixture, workload, &dig, null, null);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var uploaded: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        uploaded = try runIteration(io, &fixture, workload, &dig, null, null);
        accumulator.record(suite.elapsedNs(start_ns, suite.nowNs(io)), inlineBatch(uploaded, 1));
    }
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the elements uploaded.
    stats.output_count = uploaded;
    stats.items_per_second = suite.itemsPerSecond(uploaded, stats.mean_ns);
    return stats;
}

// The two syncs of one dig iteration. The headline is the busier fill.
const CopySample = struct {
    batches: [2]BatchStats = .{ .{}, .{} },
    count: usize = 0,
    off_main_ns: u64 = 0,

    fn add(self: *CopySample, batch: BatchStats) void {
        std.debug.assert(self.count < self.batches.len);
        self.batches[self.count] = batch;
        self.count += 1;
        self.off_main_ns += offMainNs(batch);
    }

    fn headline(self: CopySample) BatchStats {
        var best: BatchStats = .{};
        for (self.batches[0..self.count]) |batch| {
            const on_workers = !batch.ran_inline and batch.active_worker_threads != 0;
            const best_on_workers = !best.ran_inline and best.active_worker_threads != 0;
            if (batch.item_count > best.item_count or (batch.item_count == best.item_count and on_workers and !best_on_workers)) best = batch;
        }
        return best;
    }
};

fn lastGpuTileCopyBatch(world: *const WorldSystem) BatchStats {
    if (comptime runtime_perf_log.enabled) return world.perf.last_gpu_tile_copy_batch;
    return .{};
}

fn gpuCopyThreads(thread_system: ?*ThreadSystem, world: *WorldSystem, case: suite.BenchmarkCase) ?GpuTileCopyThreads {
    const threads = thread_system orelse return null;
    return .{
        .thread_system = threads,
        .tuner = &world.gpu_tile_copy_tuner,
        .controls = .{
            .adaptive = case.adaptive,
            .batches_per_participant = case.stageBatchesPerParticipant(),
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = case.stageItemsPerRangeForPartition(gpu_tile_copy_range_alignment_items, gpu_tile_copy_range_alignment_items),
        },
    };
}

fn gpuCopySettle(world: *const WorldSystem) suite.TunerSettle {
    var census = suite.TunerSettle{};
    census.add("gpu_tile_copy", &world.gpu_tile_copy_tuner);
    return census;
}

fn checkGpuTileCopy(case: suite.BenchmarkCase, threads: ?*const ThreadSystem, batch: BatchStats) !void {
    try suite.checkStageDispatched(case, threads, case.stageItemsPerRangeForPartition(gpu_tile_copy_range_alignment_items, gpu_tile_copy_range_alignment_items), batch);
}

fn noteGpuTileCopy(world: *const WorldSystem, sample: ?*CopySample) void {
    const recorded = sample orelse return;
    recorded.add(lastGpuTileCopyBatch(world));
}

// One fresh copy tuner, settled before the timed syncs. The digs sit outside that
// window. `main_ns` is the two syncs minus the fills that ran on workers.
fn measureGpuSyncDig(
    io: std.Io,
    options: suite.Options,
    case: suite.BenchmarkCase,
    item_count: usize,
    fixture: *Fixture,
    dig: *BatchEdit,
    thread_system: ?*ThreadSystem,
) !suite.RunStats {
    fixture.world.gpu_tile_copy_tuner = AdaptiveWorkTuner.init(.{});
    const copy = gpuCopyThreads(thread_system, &fixture.world, case);
    var warm = suite.Warmup.init(options, case, 1);
    while (warm.nextSettled(gpuCopySettle(&fixture.world))) {
        _ = try runGpuSyncDigIteration(io, fixture, dig, copy, null);
    }
    const settle = gpuCopySettle(&fixture.world);
    const tuner_start = suite.TunerStart.of(&fixture.world.gpu_tile_copy_tuner, case);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var uploaded: usize = 0;
    var main_total: u128 = 0;
    const thread_ptr: ?*const ThreadSystem = thread_system;
    for (0..options.iterations) |_| {
        var sample = CopySample{};
        const timed = try runGpuSyncDigIteration(io, fixture, dig, copy, &sample);
        uploaded = timed.uploaded;
        for (sample.batches[0..sample.count]) |batch| try checkGpuTileCopy(case, thread_ptr, batch);
        accumulator.record(timed.sync_ns, sample.headline());
        main_total += timed.sync_ns -| sample.off_main_ns;
    }
    var stats = accumulator.finish();
    stats.output_count = uploaded;
    stats.items_per_second = suite.itemsPerSecond(uploaded, stats.mean_ns);
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(&fixture.world.gpu_tile_copy_tuner, tuner_start);
    }
    return stats;
}

// One dig and its refill, each followed by a GPU sync. Returns the elements the two
// syncs uploaded and their time; the digs are outside that time. A sample records each fill.
fn runGpuSyncDigIteration(io: std.Io, fixture: *Fixture, dig: *BatchEdit, threads: ?GpuTileCopyThreads, sample: ?*CopySample) !struct { uploaded: usize, sync_ns: u64 } {
    const square = fixture.gpu_dig_square;
    var sync_ns: u64 = 0;
    var uploaded: usize = 0;
    for ([_][]const DenseChunkWrites{ dig.forward_chunks.items, dig.back_chunks.items }) |chunks| {
        try applyDigSquare(&fixture.world, chunks, dig);
        const start_ns = suite.nowNs(io);
        uploaded += try fixture.syncGpuTiles(fixture.gpuActiveLevel(), threads);
        noteGpuTileCopy(&fixture.world, sample);
        sync_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
    }
    // Each dug cell splits its uniform chunk (its word and a whole block) and the
    // refill merges it back (its word).
    if (uploaded != @as(usize, square) * square * (2 + tileStoreBlockElements(default_chunk_size_tiles))) return error.GpuSyncDigUploadCountMismatch;
    return .{ .uploaded = uploaded, .sync_ns = sync_ns };
}

// One change and its reversal; returns the elements uploaded. `dig` is the dig
// workload's batched edit (empty for the other workloads). Level-enter and pan pass null
// threads: those syncs stay inline. A dig sample records each fill; its time is the syncs.
fn runIteration(io: std.Io, fixture: *Fixture, workload: Workload, dig: *BatchEdit, threads: ?GpuTileCopyThreads, sample: ?*CopySample) !usize {
    return switch (workload) {
        .gpu_sync_dig => (try runGpuSyncDigIteration(io, fixture, dig, threads, sample)).uploaded,
        .gpu_sync_level_enter => blk: {
            const entered = try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
            break :blk entered + try fixture.syncGpuTiles(fixture.gpuActiveLevel() - 1, null);
        },
        .gpu_sync_pan => blk: {
            try fixture.setPanWindow(1);
            const panned = try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
            try fixture.setPanWindow(0);
            const uploaded = panned + try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
            if (uploaded != expectedPanUploads(fixture.pan_window_edge, fixture.gpu_levels_below + 1)) return error.PanUploadCountMismatch;
            break :blk uploaded;
        },
    };
}

// The dig and ramp groups: the workload through the dig controller's production reserve and
// commit, timed per dig; each iteration then resets untimed (`resetDigWorld`).
fn runControllerDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: DigWorkload) !suite.RunStats {
    std.debug.assert(!case.usesThreadSystem());
    const code = try ScaleCode.decode(item_count);
    std.debug.assert(code.levels >= cave_in_levels + 1 and code.level_side >= 256);
    var fixture = try buildFixture(allocator, io, code.level_side, code.levels);
    defer fixture.deinit();
    var controller = DigController.init(fixture.dig);
    defer controller.deinit();
    var driver = try DigDriver.init(allocator, fixture.levels - 1);
    defer driver.deinit();
    var refill = try buildDigRefillEdit(allocator, &fixture);
    defer refill.deinit(allocator);
    const entry = DigEntry{ .controller = &controller };

    for (0..options.warmup_iterations) |_| {
        _ = try digWorkloadCells(io, &fixture, &driver, entry, workload);
        try resetDigWorld(allocator, io, &fixture, &refill, workload);
    }
    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        accumulator.record(try digWorkloadCells(io, &fixture, &driver, entry, workload), inlineBatch(dig_cell_count, 1));
        try resetDigWorld(allocator, io, &fixture, &refill, workload);
    }
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the cells dug.
    stats.output_count = dig_cell_count;
    stats.items_per_second = suite.itemsPerSecond(dig_cell_count, stats.mean_ns);
    return stats;
}

// The dig and ramp workloads' cell `cell_index`: one per chunk of an 8x8 chunk square at the
// level center.
fn digCell(fixture: *const Fixture, cell_index: u16) CellCoord {
    const chunk = default_chunk_size_tiles;
    const origin = fixture.side / 2 - 4 * chunk;
    return .{ .x = origin + (cell_index % 8) * chunk + 5, .y = origin + (cell_index / 8) * chunk + 7 };
}

// The player the production dig plans from, on the deepest level facing east, and the step
// frame each dig publishes into.
const DigDriver = struct {
    data: DataSystem,
    player: Player,
    frame: SimulationFrame,

    fn init(allocator: std.mem.Allocator, level: u16) !DigDriver {
        var data = DataSystem.init(allocator);
        errdefer data.deinit();
        var player = try Player.spawn(&data);
        player.current_level = level;
        try data.setWorldLevel(player.entity, level);
        try data.setFacing(player.entity, .{ .direction = .right });
        var frame = SimulationFrame.init(allocator);
        errdefer frame.deinit();
        // A dig emits one stimulus into the live bus, warmed as the gameplay state warms it.
        try frame.stimuli.reserve(stimulus_live_capacity, stimulus_live_capacity);
        return .{ .data = data, .player = player, .frame = frame };
    }

    fn deinit(self: *DigDriver) void {
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    // Opens a fresh step with the player facing `cell` from its west neighbour.
    fn faceCell(self: *DigDriver, world: *const WorldSystem, cell: CellCoord) !void {
        const visual = self.data.primitiveVisualConst(self.player.entity) orelse return error.DigPlayerIncomplete;
        const body = self.data.movementBodyPtr(self.player.entity) orelse return error.DigPlayerIncomplete;
        body.position_x.* = (@as(f32, @floatFromInt(cell.x)) - 0.5) * world.tile_size - visual.size.x * 0.5;
        body.position_y.* = (@as(f32, @floatFromInt(cell.y)) + 0.5) * world.tile_size - visual.size.y * 0.5;
        self.frame.beginStep();
    }
};

// The production dig entry a workload digs through: the dig controller's world edit, or the
// pipeline's dig, which also reserves and records the edit's nav marks.
const DigEntry = union(enum) {
    controller: *const DigController,
    pipeline: *SimulationPipeline,

    // One dig of `intent` at the cell the player faces; fails unless it planned an edit.
    fn dig(self: DigEntry, world: *WorldSystem, driver: *DigDriver, intent: DigIntent) !void {
        switch (self) {
            .controller => |controller| {
                const edit = (try controller.reserveWorldEdit(world, &driver.data, driver.player, intent)) orelse return error.DigPlannedNothing;
                try DigController.commitWorldEdit(world, edit, &driver.frame);
            },
            .pipeline => |pipeline| {
                const edit = (try pipeline.reserveDigWorldEdit(world, &driver.data, driver.player, intent)) orelse return error.DigPlannedNothing;
                try pipeline.commitDigWorldEdit(world, edit, &driver.frame);
            },
        }
    }
};

// Digs the workload's 64 cells through `entry`, each its own step; returns the digs' time.
// Fails unless every dig changed its cell (and a ramp its exit).
fn digWorkloadCells(io: std.Io, fixture: *Fixture, driver: *DigDriver, entry: DigEntry, workload: DigWorkload) !u64 {
    var elapsed_ns: u64 = 0;
    var cell_index: u16 = 0;
    while (cell_index < dig_cell_count) : (cell_index += 1) {
        try driver.faceCell(&fixture.world, digCell(fixture, cell_index));
        const start_ns = suite.nowNs(io);
        try entry.dig(&fixture.world, driver, workload.intent());
        elapsed_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
        if (driver.frame.events.mergedItems().len != workload.eventsPerDig()) return error.DigCellUnchanged;
    }
    return elapsed_ns;
}

// The dig workload's refill: each dug cell back to dirt, one chunk each. Only its forward
// half is applied.
fn buildDigRefillEdit(allocator: std.mem.Allocator, fixture: *const Fixture) !BatchEdit {
    var edit: BatchEdit = .{};
    errdefer edit.deinit(allocator);
    const level = fixture.levels - 1;
    const layer = fixture.floor(level);
    var cell_index: u16 = 0;
    while (cell_index < dig_cell_count) : (cell_index += 1) {
        const cell = digCell(fixture, cell_index);
        try edit.beginChunk(allocator, level, cell.x / default_chunk_size_tiles, cell.y / default_chunk_size_tiles);
        try edit.add(allocator, layer, cell.x, cell.y, fixture.dirt, fixture.tunnel);
    }
    try edit.finish(allocator);
    return edit;
}

// Refills the dig workload's cells as one batched edit; fails unless every cell changed.
fn applyDigRefill(world: *WorldSystem, refill: *BatchEdit) !void {
    try applyBatch(world, refill.forward_chunks.items, &refill.events, null);
    if (refill.events.items.len != dig_cell_count) return error.DigRefillUnchanged;
}

// The ramp workload's reset: links are append-only and a cell with one plans no ramp, so the
// world is rebuilt fresh. Fails unless the workload linked every cell.
fn rebuildRampWorld(allocator: std.mem.Allocator, io: std.Io, fixture: *Fixture) !void {
    std.debug.assert(fixture.renderer == null);
    if (fixture.world.levelLinks().len != dig_cell_count) return error.RampLinkCountMismatch;
    const fresh = try buildFixture(allocator, io, fixture.side, fixture.levels);
    fixture.world.deinit();
    fixture.world = fresh.world;
}

// Returns the plain dig or ramp workload's world to its start state, untimed.
fn resetDigWorld(allocator: std.mem.Allocator, io: std.Io, fixture: *Fixture, refill: *BatchEdit, workload: DigWorkload) !void {
    switch (workload) {
        .dig => try applyDigRefill(&fixture.world, refill),
        .ramp => try rebuildRampWorld(allocator, io, fixture),
    }
}

// The dig workload's cells on `level` as one batched edit, tunnel forward and dirt back:
// one cell per chunk of the `square` x `square` chunk square at the level center (the 64
// cells at `dig_window_chunks`), in chunk-major order.
fn buildDigSquareEdit(allocator: std.mem.Allocator, fixture: *const Fixture, level: u16, square: u16) !BatchEdit {
    var edit: BatchEdit = .{};
    errdefer edit.deinit(allocator);
    const layer = fixture.floor(level);
    const chunk = default_chunk_size_tiles;
    const origin = fixture.side / 2 - square / 2 * chunk;
    const cell_count = square * square;
    var cell_index: u16 = 0;
    while (cell_index < cell_count) : (cell_index += 1) {
        const x = origin + (cell_index % square) * chunk + 5;
        const y = origin + (cell_index / square) * chunk + 7;
        try edit.beginChunk(allocator, level, x / chunk, y / chunk);
        try edit.add(allocator, layer, x, y, fixture.tunnel, fixture.dirt);
    }
    try edit.finish(allocator);
    return edit;
}

// Applies one half of a dig square edit through the production batched write; fails unless
// every cell changed.
fn applyDigSquare(world: *WorldSystem, chunks: []const DenseChunkWrites, dig: *BatchEdit) !void {
    try applyBatch(world, chunks, &dig.events, null);
    if (dig.events.items.len != dig.forward.items.len) return error.DigSquareUnchanged;
}

// Makes every chunk of the pan region on `level` mixed: one tunnel cell per chunk
// in `columns` x `rows` chunks from the pan origin, in one step.
fn mixRegion(fixture: *Fixture, level: u16, columns: u16, rows: u16) !void {
    const world = &fixture.world;
    const layer = fixture.floor(level);
    const chunk = default_chunk_size_tiles;
    world.beginDenseCellWriteReserve();
    for (0..2) |pass| {
        for (0..rows) |row| for (0..columns) |col| {
            const x = (fixture.pan_origin_chunk_x + @as(u16, @intCast(col))) * chunk + 5;
            const y = (fixture.pan_origin_chunk_y + @as(u16, @intCast(row))) * chunk + 7;
            if (pass == 0) {
                try world.reserveDenseCellWrite(layer, x, y, fixture.tunnel);
            } else if (try world.setDenseTile(layer, x, y, fixture.tunnel) == null) {
                return error.PanRegionCellUnchanged;
            }
        };
    }
}

// The two batched edits of one iteration, each the other's reversal, built once in
// chunk-major order: `forward_chunks[i]` and `back_chunks[i]` cover the same cells.
const BatchEdit = struct {
    forward: std.ArrayList(DenseCellWrite) = .empty,
    back: std.ArrayList(DenseCellWrite) = .empty,
    spans: std.ArrayList(ChunkSpan) = .empty,
    forward_chunks: std.ArrayList(DenseChunkWrites) = .empty,
    back_chunks: std.ArrayList(DenseChunkWrites) = .empty,
    events: std.ArrayList(WorldTileChangedEvent) = .empty,

    const ChunkSpan = struct {
        level: u16,
        chunk_x: u16,
        chunk_y: u16,
        start: usize,
        end: usize,
    };

    fn deinit(self: *BatchEdit, allocator: std.mem.Allocator) void {
        self.forward.deinit(allocator);
        self.back.deinit(allocator);
        self.spans.deinit(allocator);
        self.forward_chunks.deinit(allocator);
        self.back_chunks.deinit(allocator);
        self.events.deinit(allocator);
    }

    // Opens the next chunk; chunks open in (level, chunk_y, chunk_x) order.
    fn beginChunk(self: *BatchEdit, allocator: std.mem.Allocator, level: u16, chunk_x: u16, chunk_y: u16) !void {
        const start = self.forward.items.len;
        try self.spans.append(allocator, .{ .level = level, .chunk_x = chunk_x, .chunk_y = chunk_y, .start = start, .end = start });
    }

    fn add(self: *BatchEdit, allocator: std.mem.Allocator, layer: usize, x: u16, y: u16, forward_tile: TileId, back_tile: TileId) !void {
        try self.forward.append(allocator, .{ .layer = @intCast(layer), .x = x, .y = y, .tile = forward_tile });
        try self.back.append(allocator, .{ .layer = @intCast(layer), .x = x, .y = y, .tile = back_tile });
        self.spans.items[self.spans.items.len - 1].end = self.forward.items.len;
    }

    // Builds the chunk lists once every write is in, dropping chunks no cell landed in.
    fn finish(self: *BatchEdit, allocator: std.mem.Allocator) !void {
        for (self.spans.items) |span| {
            if (span.end == span.start) continue;
            try self.forward_chunks.append(allocator, .{ .level = span.level, .chunk_x = span.chunk_x, .chunk_y = span.chunk_y, .writes = self.forward.items[span.start..span.end] });
            try self.back_chunks.append(allocator, .{ .level = span.level, .chunk_x = span.chunk_x, .chunk_y = span.chunk_y, .writes = self.back.items[span.start..span.end] });
        }
        try self.events.ensureTotalCapacity(allocator, self.forward.items.len);
    }
};

// Cave-in: `region_chunks / 4` chunks in a chunk-aligned square at the center of each
// of the four deepest levels, tunnel to be collapsed to dirt and carved back.
fn buildCaveInEdit(allocator: std.mem.Allocator, fixture: *const Fixture, region_chunks: usize) !BatchEdit {
    var edit: BatchEdit = .{};
    errdefer edit.deinit(allocator);
    const square_chunks = std.math.sqrt(region_chunks / cave_in_levels);
    std.debug.assert(square_chunks * square_chunks * cave_in_levels == region_chunks);
    const chunk_edge = default_chunk_size_tiles;
    const origin_chunk: u16 = fixture.side / 2 / chunk_edge - @as(u16, @intCast(square_chunks / 2));
    for (fixture.levels - cave_in_levels..fixture.levels) |level_index| {
        const level: u16 = @intCast(level_index);
        const layer = fixture.floor(level);
        for (0..square_chunks) |row| for (0..square_chunks) |col| {
            const chunk_x = origin_chunk + @as(u16, @intCast(col));
            const chunk_y = origin_chunk + @as(u16, @intCast(row));
            try edit.beginChunk(allocator, level, chunk_x, chunk_y);
            for (0..chunk_edge) |dy| for (0..chunk_edge) |dx| {
                const x = chunk_x * chunk_edge + @as(u16, @intCast(dx));
                const y = chunk_y * chunk_edge + @as(u16, @intCast(dy));
                try edit.add(allocator, layer, x, y, fixture.dirt, fixture.tunnel);
            };
        };
    }
    try edit.finish(allocator);
    return edit;
}

// Explosion: the cells of the `deep_levels` deepest levels whose centers lie in the disk
// inscribed in a chunk-aligned `sqrt(region_chunks)` square at the level center, blown
// open to empty and filled back with dirt. The square's corner chunks the disk misses
// are not part of the edit.
fn buildExplosionEdit(allocator: std.mem.Allocator, fixture: *const Fixture, region_chunks: usize, deep_levels: u16) !BatchEdit {
    var edit: BatchEdit = .{};
    errdefer edit.deinit(allocator);
    const square_chunks = std.math.sqrt(region_chunks);
    std.debug.assert(square_chunks * square_chunks == region_chunks);
    std.debug.assert(deep_levels >= 1 and deep_levels <= fixture.levels);
    const chunk_edge = default_chunk_size_tiles;
    const radius: i32 = @intCast(square_chunks * chunk_edge / 2);
    const center: i32 = fixture.side / 2;
    const origin_chunk: u16 = fixture.side / 2 / chunk_edge - @as(u16, @intCast(square_chunks / 2));
    for (fixture.levels - deep_levels..fixture.levels) |level_index| {
        const level: u16 = @intCast(level_index);
        try addExplosionLevel(allocator, &edit, fixture, level, square_chunks, origin_chunk, center, radius);
    }
    try edit.finish(allocator);
    return edit;
}

// One level's share of an explosion edit, in chunk-major order.
fn addExplosionLevel(allocator: std.mem.Allocator, edit: *BatchEdit, fixture: *const Fixture, level: u16, square_chunks: usize, origin_chunk: u16, center: i32, radius: i32) !void {
    const chunk_edge = default_chunk_size_tiles;
    const layer = fixture.floor(level);
    for (0..square_chunks) |row| for (0..square_chunks) |col| {
        const chunk_x = origin_chunk + @as(u16, @intCast(col));
        const chunk_y = origin_chunk + @as(u16, @intCast(row));
        try edit.beginChunk(allocator, level, chunk_x, chunk_y);
        for (0..chunk_edge) |dy| for (0..chunk_edge) |dx| {
            const x = chunk_x * chunk_edge + @as(u16, @intCast(dx));
            const y = chunk_y * chunk_edge + @as(u16, @intCast(dy));
            const offset_x = @as(i32, x) - center;
            const offset_y = @as(i32, y) - center;
            if ((2 * offset_x + 1) * (2 * offset_x + 1) + (2 * offset_y + 1) * (2 * offset_y + 1) > 4 * radius * radius) continue;
            try edit.add(allocator, layer, x, y, invalid_tile_id, fixture.dirt);
        };
    };
}

// Places blocking sparse props on the explosion level over its whole region square,
// `sparse_props_stride` cells apart in a skewed pattern.
fn addExplosionProps(fixture: *Fixture, region_chunks: usize) !void {
    const world = &fixture.world;
    const square_chunks = std.math.sqrt(region_chunks);
    std.debug.assert(square_chunks * square_chunks == region_chunks);
    const chunk_edge = default_chunk_size_tiles;
    const origin: u16 = (fixture.side / 2 / chunk_edge - @as(u16, @intCast(square_chunks / 2))) * chunk_edge;
    const square_cells: u16 = @intCast(square_chunks * chunk_edge);
    for (origin..origin + square_cells) |y| for (origin..origin + square_cells) |x| {
        if ((3 * x + 5 * y) % sparse_props_stride != 0) continue;
        // Only a blocking tile reports an obstacle change.
        if (try world.addSparseTile(fixture.levels - 1, @intCast(x), @intCast(y), fixture.prop, 0, .obstacle) == null) return error.SparsePropNotBlocking;
    };
}

// Per-stage time of one iteration's two batched edits.
const BatchTiming = struct {
    plan_ns: u64 = 0,
    write_ns: u64 = 0,
    // Stage time spent on workers: a stage that ran inline reports its duration but
    // ran on the main thread.
    off_main_ns: u64 = 0,
    // The forward and revert edits' batches: forward plan and write, then revert plan and
    // write (`edit_stage_names`).
    stages: [edit_stage_names.len]BatchStats = @splat(.{}),

    fn add(self: *BatchTiming, world: *const WorldSystem) void {
        for ([_]BatchStats{ world.perf.last_terrain_edit_plan_batch, world.perf.last_terrain_edit_write_batch }) |batch| self.off_main_ns += offMainNs(batch);
        self.plan_ns += world.perf.last_terrain_edit_plan_batch.batch_duration_ns;
        self.write_ns += world.perf.last_terrain_edit_write_batch.batch_duration_ns;
    }

    // The last edit's plan and write as the forward or the revert edit's.
    fn capture(self: *BatchTiming, world: *const WorldSystem, reverting: bool) void {
        const first: usize = if (reverting) 2 else 0;
        self.stages[first] = world.perf.last_terrain_edit_plan_batch;
        self.stages[first + 1] = world.perf.last_terrain_edit_write_batch;
    }

    fn forwardWrite(self: *const BatchTiming) BatchStats {
        return self.stages[1];
    }
};

// A batched change and its reversal's edit stages, in `BatchTiming.stages` order.
const edit_stage_names = [_][]const u8{ "plan", "write", "revert_plan", "revert_write" };

fn applyBatch(world: *WorldSystem, chunks: []const DenseChunkWrites, events: *std.ArrayList(WorldTileChangedEvent), threads: ?TerrainEditThreads) !void {
    events.clearRetainingCapacity();
    try world.applyDenseCellWrites(chunks, threads, events);
}

// The reversal's terrain-edit tuners: a sample that runs a batched change and then its
// reversal runs the reversal on these, so each pair learns one workload with one sample
// per step, as production's one batched edit per step does.
const RevertEditTuners = struct {
    plan: AdaptiveWorkTuner,
    write: AdaptiveWorkTuner,

    fn init() RevertEditTuners {
        return .{ .plan = AdaptiveWorkTuner.init(.{}), .write = AdaptiveWorkTuner.init(.{}) };
    }

    // `forward` with its tuners replaced by these; null when it is.
    fn threads(self: *RevertEditTuners, forward: ?TerrainEditThreads) ?TerrainEditThreads {
        var revert = forward orelse return null;
        revert.plan_tuner = &self.plan;
        revert.write_tuner = &self.write;
        return revert;
    }
};

// One timed batched change and its reversal, the reversal on `revert`'s tuners; returns the
// cells written.
fn runBatchIteration(fixture: *Fixture, edit: *BatchEdit, threads: ?TerrainEditThreads, revert: *RevertEditTuners, timing: *BatchTiming) !usize {
    try applyBatch(&fixture.world, edit.forward_chunks.items, &edit.events, threads);
    timing.add(&fixture.world);
    timing.capture(&fixture.world, false);
    try applyBatch(&fixture.world, edit.back_chunks.items, &edit.events, revert.threads(threads));
    timing.add(&fixture.world);
    timing.capture(&fixture.world, true);
    return edit.forward.items.len + edit.back.items.len;
}

// The forward edit's tuners (the world's) and the revert edit's, in `edit_stage_names` order.
fn editTuners(world: *const WorldSystem, revert: *const RevertEditTuners) [edit_stage_names.len]*const AdaptiveWorkTuner {
    return .{ &world.terrain_edit_plan_tuner, &world.terrain_edit_write_tuner, &revert.plan, &revert.write };
}

// Adds the forward and revert edits' tuners to `census`.
fn addEditTuners(census: *suite.TunerSettle, world: *const WorldSystem, revert: *const RevertEditTuners) void {
    census.addNamed(&edit_stage_names, &editTuners(world, revert));
}

fn editTunerSettle(world: *const WorldSystem, revert: *const RevertEditTuners) suite.TunerSettle {
    var census = suite.TunerSettle{};
    addEditTuners(&census, world, revert);
    return census;
}

fn runBatchCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: BatchWorkload) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try RegionCode.decode(item_count);
    const sparse_props = code.sparse_props;
    if (sparse_props and workload != .explosion_fill) return error.ChunkScaleSparsePropsOffExplosion;
    const region_chunks = code.region_chunks;
    const side = code.level_side;
    const levels = code.levels;
    if (levels < cave_in_levels + 1 or side < 256) return error.ChunkScaleWorldTooSmall;

    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();

    var fixture = try buildFixture(allocator, io, side, levels);
    defer fixture.deinit();
    if (sparse_props) try addExplosionProps(&fixture, region_chunks);
    // The two deepest levels are GPU resident over the fixed window, so edits there
    // flag their layers; each iteration's sync uploads them outside the timed region.
    try fixture.setDigWindow();
    try fixture.attachHeadlessTileStore(allocator);
    _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
    var edit = switch (workload) {
        .cave_in => try buildCaveInEdit(allocator, &fixture, region_chunks),
        .explosion_fill => try buildExplosionEdit(allocator, &fixture, region_chunks, 1),
    };
    defer edit.deinit(allocator);
    // The cave-in region starts carved, so each iteration collapses then re-carves it.
    if (workload == .cave_in) {
        try applyBatch(&fixture.world, edit.back_chunks.items, &edit.events, null);
        _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
    }

    const world = &fixture.world;
    world.terrain_edit_plan_tuner = AdaptiveWorkTuner.init(.{});
    world.terrain_edit_write_tuner = AdaptiveWorkTuner.init(.{});
    var revert_tuners = RevertEditTuners.init();
    const edit_threads: ?TerrainEditThreads = if (threads) |*thread_system| .{
        .thread_system = thread_system,
        .plan_tuner = &world.terrain_edit_plan_tuner,
        .write_tuner = &world.terrain_edit_write_tuner,
        .controls = .{ .adaptive = case.adaptive, .batches_per_participant = case.stageBatchesPerParticipant(), .max_worker_threads = case.maxWorkerThreads(), .items_per_range = case.stageItemsPerRangeForPartition(suite.chunk_partition_items, edit_range_alignment_items) },
    } else null;

    var unused_timing: BatchTiming = .{};
    var warm = suite.Warmup.init(options, case, 1);
    while (warm.nextSettled(editTunerSettle(world, &revert_tuners))) {
        _ = try runBatchIteration(&fixture, &edit, edit_threads, &revert_tuners, &unused_timing);
        _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
    }
    const settle = editTunerSettle(world, &revert_tuners);
    const terrain_edit_write_tuner_start = suite.TunerStart.of(&world.terrain_edit_write_tuner, case);
    const terrain_edit_plan_tuner_start = suite.TunerStart.of(&world.terrain_edit_plan_tuner, case);
    const tuner_window = suite.TunerWindow(edit_stage_names.len).begin(editTuners(world, &revert_tuners));

    var accumulator = suite.StatsAccumulator.init(item_count);
    var plan_total: u128 = 0;
    var write_total: u128 = 0;
    var main_total: u128 = 0;
    var cells_changed: usize = 0;
    var edit_shapes = suite.StageShapes(edit_stage_names.len){};
    for (0..options.iterations) |_| {
        var timing: BatchTiming = .{};
        const start_ns = suite.nowNs(io);
        cells_changed = try runBatchIteration(&fixture, &edit, edit_threads, &revert_tuners, &timing);
        const elapsed_ns = suite.elapsedNs(start_ns, suite.nowNs(io));
        edit_shapes.add(timing.stages);
        accumulator.record(elapsed_ns, timing.forwardWrite());
        if (threads) |*thread_system| try suite.checkStagesDispatched(case, thread_system, case.stageItemsPerRangeForPartition(suite.chunk_partition_items, edit_range_alignment_items), &timing.stages);
        plan_total += timing.plan_ns;
        write_total += timing.write_ns;
        // Main is everything but the stages that ran on workers.
        main_total += elapsed_ns -| timing.off_main_ns;
        _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
    }
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the cells written; the
    // batches' item count is the chunks one edit touched.
    stats.output_count = cells_changed;
    stats.items_per_second = suite.itemsPerSecond(cells_changed, stats.mean_ns);
    // The forward edit's write is the headline (the accumulator's); every edit stage's shape
    // and tuner over the measured steps prints under the row.
    stats.secondary_batch = suite.batchSummaryFromShapes(&edit_shapes, 0);
    edit_shapes.print(&stats.details, "edit_stages", edit_stage_names);
    if (stats.iterations > 0) {
        const iterations: u128 = stats.iterations;
        stats.terrain_edit_phases = .{
            .plan_ns = @intCast(plan_total / iterations),
            .write_ns = @intCast(write_total / iterations),
            .main_ns = @intCast(main_total / iterations),
        };
    }
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(&world.terrain_edit_write_tuner, terrain_edit_write_tuner_start);
        stats.secondary_work_tuning = suite.workTuningSummary(&world.terrain_edit_plan_tuner, terrain_edit_plan_tuner_start);
        tuner_window.printTuning(&stats.details, edit_stage_names, editTuners(world, &revert_tuners));
    }
    return stats;
}

// Elements the two syncs of one batched-sync iteration upload: per edited chunk, a chunk
// the edit covers whole changes its uniform word there and back; a chunk it covers in part
// splits (its word and a whole block) and merges back (its word).
fn expectedBatchSyncUploads(edit: *const BatchEdit) usize {
    const chunk_cells = @as(usize, default_chunk_size_tiles) * default_chunk_size_tiles;
    var uploads: usize = 0;
    for (edit.forward_chunks.items) |chunk| {
        uploads += if (chunk.writes.len == chunk_cells) 2 else 2 + tileStoreBlockElements(default_chunk_size_tiles);
    }
    return uploads;
}

// gpu-sync-dig's batched variant: an explosion disk inscribed in the fixed dig window on
// every resident layer, blown open as one batched edit and filled back as another (both
// untimed), each followed by the timed GPU sync. Every resident layer is flagged.
fn runGpuSyncBatchCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, config: GpuSyncDigConfig) !suite.RunStats {
    std.debug.assert(config.variant == .batched);
    std.debug.assert(config.resident_layers + 1 <= config.levels);
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    var threads = try fixtures.initCaseThreads(allocator, io, case);
    defer if (threads) |*thread_system| thread_system.deinit();
    var fixture = try buildFixture(allocator, io, config.side, config.levels);
    defer fixture.deinit();
    fixture.gpu_levels_below = config.resident_layers - 1;
    try fixture.setDigWindow();
    try fixture.attachHeadlessTileStore(allocator);
    _ = try fixture.syncGpuTiles(fixture.gpuActiveLevel(), null);
    var edit = try buildExplosionEdit(allocator, &fixture, @as(usize, dig_window_chunks) * dig_window_chunks, config.resident_layers);
    defer edit.deinit(allocator);
    const expected_uploads = expectedBatchSyncUploads(&edit);

    fixture.world.gpu_tile_copy_tuner = AdaptiveWorkTuner.init(.{});
    const copy = gpuCopyThreads(if (threads) |*thread_system| thread_system else null, &fixture.world, case);
    var warm = suite.Warmup.init(options, case, 1);
    while (warm.nextSettled(gpuCopySettle(&fixture.world))) {
        _ = try runGpuSyncBatchIteration(io, &fixture, &edit, expected_uploads, copy, null);
    }
    const settle = gpuCopySettle(&fixture.world);
    const tuner_start = suite.TunerStart.of(&fixture.world.gpu_tile_copy_tuner, case);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var main_total: u128 = 0;
    const thread_ptr: ?*const ThreadSystem = if (threads) |*thread_system| thread_system else null;
    for (0..options.iterations) |_| {
        var sample = CopySample{};
        const sync_ns = try runGpuSyncBatchIteration(io, &fixture, &edit, expected_uploads, copy, &sample);
        for (sample.batches[0..sample.count]) |batch| try checkGpuTileCopy(case, thread_ptr, batch);
        accumulator.record(sync_ns, sample.headline());
        main_total += sync_ns -| sample.off_main_ns;
    }
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the elements uploaded.
    stats.output_count = expected_uploads;
    stats.items_per_second = suite.itemsPerSecond(expected_uploads, stats.mean_ns);
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(&fixture.world.gpu_tile_copy_tuner, tuner_start);
    }
    return stats;
}

// One batched change and its reversal, each followed by a GPU sync; returns the two syncs'
// time and fails unless they uploaded `expected_uploads` elements. A sample records each fill.
fn runGpuSyncBatchIteration(io: std.Io, fixture: *Fixture, edit: *BatchEdit, expected_uploads: usize, threads: ?GpuTileCopyThreads, sample: ?*CopySample) !u64 {
    var sync_ns: u64 = 0;
    var uploaded: usize = 0;
    for ([_][]const DenseChunkWrites{ edit.forward_chunks.items, edit.back_chunks.items }) |chunks| {
        try applyBatch(&fixture.world, chunks, &edit.events, null);
        const start_ns = suite.nowNs(io);
        uploaded += try fixture.syncGpuTiles(fixture.gpuActiveLevel(), threads);
        noteGpuTileCopy(&fixture.world, sample);
        sync_ns += suite.elapsedNs(start_ns, suite.nowNs(io));
    }
    if (uploaded != expected_uploads) return error.GpuSyncBatchUploadCountMismatch;
    return sync_ns;
}

// The nav groups' fixture: the chunk-scale world with nav built over every level by a
// `SimulationPipeline`, the production owner of nav and its static colliders, and no
// entities, so the static colliders hold no row.
const NavFixture = struct {
    base: Fixture,
    pipeline: SimulationPipeline,
    io: std.Io,
    // The case's thread system for the dig and ramp reactions.
    threads: *ThreadSystem,
    // The most recent reaction's stats and wall time.
    last_stats: NavUpdateStats = .{},
    last_reaction_ns: u64 = 0,
    // The revert reaction's stage tuners (`fixtures.NavTuners`), set with the forward set.
    revert_tuners: fixtures.NavTuners = .{},

    fn deinit(self: *NavFixture) void {
        self.pipeline.deinit();
        self.base.deinit();
        self.* = undefined;
    }

    // Gives the forward and revert stage tuner sets the same fresh tuners for `case`.
    fn setTuners(self: *NavFixture, case: suite.BenchmarkCase) void {
        fixtures.setNavTuners(&self.pipeline.pathfinding, case);
        self.revert_tuners = self.pipeline.pathfinding.tuners;
    }

    // Swaps the revert stage tuners in or back out (untimed).
    fn swapRevertTuners(self: *NavFixture) void {
        fixtures.swapNavTuners(&self.pipeline.pathfinding, &self.revert_tuners);
    }

    // Adds both stage tuner sets to `census`: the forward set (the system's) and the revert
    // set, every tuner of each (`fixtures.addNavTuners`). A set or stage the workload never
    // runs is idle.
    fn addStageTuners(self: *const NavFixture, census: *suite.TunerSettle) void {
        fixtures.addNavTuners(census, "", &self.pipeline.pathfinding.tuners);
        fixtures.addNavTuners(census, "revert.", &self.revert_tuners);
    }

    fn stageTunerSettle(self: *const NavFixture) suite.TunerSettle {
        var census = suite.TunerSettle{};
        self.addStageTuners(&census);
        return census;
    }

    // The post-commit nav reaction to the marks the step's writers recorded; fails unless it
    // applied one incremental update and drained every mark. Its wall time includes the
    // writers' mark stage, which ran inside their writes.
    fn react(self: *NavFixture, frame: *SimulationFrame) !NavUpdateStats {
        const pathfinding = &self.pipeline.pathfinding;
        const mark_ns = pathfinding.perf.mark_off_main_ns + pathfinding.perf.mark_inline_ns + pathfinding.perf.mark_main_ns;
        const start_ns = suite.nowNs(self.io);
        const stats = try pathfinding.reactToPostCommitNavEvents(frame, &self.pipeline.static_colliders, &self.base.world, self.threads);
        self.last_reaction_ns = mark_ns + suite.elapsedNs(start_ns, suite.nowNs(self.io));
        if (stats.incremental_rebuilds != 1) return error.NavReactionUnchanged;
        if (pathfinding.hasPendingNavUpdates(&self.base.world)) return error.NavMarksPending;
        self.last_stats = stats;
        return stats;
    }

    // Adds the most recent reaction's main-thread split (its wall time outside worker
    // dispatches) to `summary` as one sample.
    fn addLastNavMain(self: *const NavFixture, summary: *suite.NavMainSummary) void {
        summary.add(self.last_reaction_ns -| self.last_stats.perf.off_main_stage_ns, self.last_stats);
        summary.endSample();
    }

    // The writer's nav record of the step's published tile events (reserved before the
    // write), then the post-commit nav reaction; fails unless it applied one incremental
    // update, drained every mark, and signaled the invalidation once.
    fn reactToFrame(self: *NavFixture, frame: *SimulationFrame, thread_system: *ThreadSystem) !NavUpdateStats {
        const pathfinding = &self.pipeline.pathfinding;
        pathfinding.recordTerrainNavEvents(frame.events.mergedItems(), &self.base.world, thread_system);
        const stats = try pathfinding.reactToPostCommitNavEvents(frame, &self.pipeline.static_colliders, &self.base.world, thread_system);
        if (stats.incremental_rebuilds != 1) return error.NavReactionUnchanged;
        if (pathfinding.hasPendingNavUpdates(&self.base.world)) return error.NavMarksPending;
        if (frame.events.stats.nav_region_invalidated != 1) return error.NavInvalidationMissing;
        self.last_stats = stats;
        return stats;
    }

    // The ramp workload's reset (`rebuildRampWorld`) with its nav rebuilt over the fresh
    // world. A nav rebuild resets the stage tuners, so the case's carry over.
    fn resetRamps(self: *NavFixture, allocator: std.mem.Allocator) !void {
        try rebuildRampWorld(allocator, self.io, &self.base);
        const pathfinding = &self.pipeline.pathfinding;
        const tuners = pathfinding.tuners;
        try pathfinding.rebuildNavFromColliders(&self.pipeline.static_colliders, PathfindingSystem.worldNavExtent(&self.base.world), self.threads);
        pathfinding.tuners = tuners;
    }
};

// Opens a fresh step in `frame` holding a batched edit's tile changes, published as the
// structural commit publishes them.
fn publishBatchEvents(frame: *SimulationFrame, events: []const WorldTileChangedEvent) !void {
    frame.beginStep();
    try frame.events.ensureEventAppendCapacity(events.len);
    frame.publishWorldTileChangesAssumeCapacity(events);
    if (frame.events.stats.world_tile_changed != events.len) return error.BatchEventsUnpublished;
}

// No path requests: the agent budget stays at its floor. `batch`: the workload's largest
// marks batch.
fn navSizeConfig(side: u16, levels: usize, participant_count: usize, batch: nav_size.NavBatch) nav_size.NavSizeConfig {
    return .{
        .side = side,
        .levels = levels,
        .participant_count = participant_count,
        .agent_budget = min_capacity_floor,
        .group_fields = default_max_group_fields,
        .batch = batch,
    };
}

// Builds the pipeline, and with it the nav, over `fixture`'s world, taking ownership of it.
fn navFixtureOver(allocator: std.mem.Allocator, io: std.Io, fixture: Fixture, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !NavFixture {
    var base = fixture;
    errdefer base.deinit();
    // No entities; the pipeline reads the rows only at init.
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const pipeline = try SimulationPipeline.init(allocator, &data, base.world.worldWidthPixels(), base.world.worldHeightPixels(), .{
        .pathfinding = capacity,
        .navigation_world = &base.world,
        .build_thread_system = thread_system,
        .dig = base.dig,
    });
    return .{ .base = base, .pipeline = pipeline, .io = io, .threads = thread_system };
}

fn runNavDigCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runNavCase(allocator, io, options, case, item_count, .dig);
}

fn runNavRampCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runNavCase(allocator, io, options, case, item_count, .ramp);
}

fn runNavCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: DigWorkload) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try ScaleCode.decode(item_count);
    const side = code.level_side;
    const levels = code.levels;
    if (levels < cave_in_levels + 1 or side < 256) return error.ChunkScaleWorldTooSmall;
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    // The dig square's cells on the deepest level; the ramps' too, with their exits' obstacle
    // rects on the level above and their links.
    const batch: nav_size.NavBatch = switch (workload) {
        .dig => .{ .mark_chunks = dig_cell_count, .links = 0, .keys = nav_size.squareBatchKeys(dig_window_chunks) },
        .ramp => .{ .mark_chunks = 2 * dig_cell_count, .links = dig_cell_count, .keys = 2 * nav_size.squareBatchKeys(dig_window_chunks) },
    };
    // The world first: its content sizes the nav.
    var world_fixture = try buildFixture(allocator, io, side, levels);
    var world_owned = true;
    defer if (world_owned) world_fixture.deinit();
    var size_config = navSizeConfig(side, levels, participant_count, batch);
    size_config.content = pathfinding_test_support.navStorageContentOf(&world_fixture.world);
    const group_name = switch (workload) {
        .dig => nav_dig_group.name,
        .ramp => nav_ramp_group.name,
    };
    try nav_size.checkNavSize(group_name, item_count, case, size_config);

    world_owned = false;
    var nav = try navFixtureOver(allocator, io, world_fixture, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer nav.deinit();
    try nav_size.checkNavBytes(group_name, item_count, size_config, &nav.pipeline.pathfinding);
    nav.threads = thread_ptr;
    nav.setTuners(case);
    var driver = try DigDriver.init(allocator, levels - 1);
    defer driver.deinit();
    var refill = try buildDigRefillEdit(allocator, &nav.base);
    defer refill.deinit(allocator);

    // The dig's reset reacts on the revert set; the ramps' never runs it, so it stays idle.
    var warm = suite.Warmup.init(options, case, 0);
    while (warm.nextSettled(nav.stageTunerSettle())) {
        _ = try runNavIteration(io, &nav, &driver, workload);
        try resetNavWorkload(allocator, &nav, &driver, &refill, workload);
    }
    const settle = nav.stageTunerSettle();
    const tuners = &nav.pipeline.pathfinding.tuners;
    const remask_tuner_start = suite.TunerStart.of(tuners.nav.getPtrConst(.remask), case);
    const patch_tuner_start = suite.TunerStart.of(tuners.nav.getPtrConst(.patch), case);
    var accumulator = suite.StatsAccumulator.init(item_count);
    // The timed reactions, each read before the reset's reaction replaces it.
    var reactions = suite.NavReactionShapes{};
    var nav_main = suite.NavMainSummary{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        const elapsed_ns = try runNavIteration(io, &nav, &driver, workload);
        const mark = nav.pipeline.pathfinding.perf.last_mark_batch;
        accumulator.record(elapsed_ns, nav.last_stats.perf.remask_batch);
        try suite.checkNavReactionDispatched(case, thread_ptr, mark, nav.last_stats);
        reactions.add(mark, nav.last_stats);
        nav.addLastNavMain(&nav_main);
        // The digs and their marks are main-thread work; the reaction's stages (the marks'
        // folded in) on workers are not.
        main_total += elapsed_ns -| nav.last_stats.perf.off_main_stage_ns;
        try resetNavWorkload(allocator, &nav, &driver, &refill, workload);
    }
    try nav_size.checkNavBytes(group_name, item_count, size_config, &nav.pipeline.pathfinding);
    var stats = accumulator.finish();
    stats.output_count = dig_cell_count;
    stats.items_per_second = suite.itemsPerSecond(dig_cell_count, stats.mean_ns);
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    reactions.summarize(&stats, fixtures.floodTunerWorkersOf(tuners, case));
    stats.nav_main = nav_main;
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(tuners.nav.getPtrConst(.remask), remask_tuner_start);
        stats.secondary_work_tuning = suite.workTuningSummary(tuners.nav.getPtrConst(.patch), patch_tuner_start);
    }
    return stats;
}

// One timed nav iteration: the workload's 64 digs through the pipeline's production dig, each
// recording its nav marks, then one post-commit reaction to them on the forward stage tuners.
// Returns the digs' and the reaction's time.
fn runNavIteration(io: std.Io, nav: *NavFixture, driver: *DigDriver, workload: DigWorkload) !u64 {
    const dig_ns = try digWorkloadCells(io, &nav.base, driver, .{ .pipeline = &nav.pipeline }, workload);
    const start_ns = suite.nowNs(io);
    _ = try nav.react(&driver.frame);
    return dig_ns + suite.elapsedNs(start_ns, suite.nowNs(io));
}

// Returns the dig or ramp workload's world and nav to their start state, untimed. The dig's
// cells refill as one batched edit, recorded and reacted to on the revert stage tuners; the
// ramps get a fresh world and nav (`NavFixture.resetRamps`).
fn resetNavWorkload(allocator: std.mem.Allocator, nav: *NavFixture, driver: *DigDriver, refill: *BatchEdit, workload: DigWorkload) !void {
    switch (workload) {
        .dig => {
            nav.swapRevertTuners();
            defer nav.swapRevertTuners();
            try nav.pipeline.pathfinding.reserveTerrainNavRecord(refill.forward.items.len);
            try applyDigRefill(&nav.base.world, refill);
            try publishBatchEvents(&driver.frame, refill.events.items);
            _ = try nav.reactToFrame(&driver.frame, nav.threads);
        },
        .ramp => try nav.resetRamps(allocator),
    }
}

fn runNavCaveInCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runNavBatchCase(allocator, io, options, case, item_count, .cave_in);
}

fn runNavExplosionFillCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runNavBatchCase(allocator, io, options, case, item_count, .explosion_fill);
}

// Per-stage time of one iteration's two batched edits and their nav reactions, and the
// reactions' fallbacks.
const NavBatchTiming = struct {
    terrain: BatchTiming = .{},
    // The timed edits and reactions; publishing each edit's events is not timed.
    elapsed_ns: u64 = 0,
    nav_ns: u64 = 0,
    // Nav reaction stage time spent on workers.
    nav_off_main_ns: u64 = 0,
    // The forward and the revert edit's reactions and their mark dispatches.
    forward: NavUpdateStats = .{},
    forward_mark: BatchStats = .{},
    revert: NavUpdateStats = .{},
    revert_mark: BatchStats = .{},
    // Both reactions' main-thread split, summed.
    nav_main: suite.NavMainSummary = .{},
};

// Every tuner a batched nav iteration runs: both edits' and both reactions' stage sets.
fn navBatchTunerSettle(nav: *const NavFixture, revert: *const RevertEditTuners) suite.TunerSettle {
    var census = editTunerSettle(&nav.base.world, revert);
    nav.addStageTuners(&census);
    return census;
}

// One batched change and its reversal, each followed by the writer's nav record of its
// published tile events and the post-commit nav reaction (interpretation, marking, and
// apply, timed as the nav stage); returns the cells written. The record is reserved from
// the cells written before each write, as a terrain writer reserves from its event budget.
// Publishing the events is untimed setup. The reversal runs on `revert`'s edit tuners and
// the fixture's revert stage tuners (swapped in and out untimed).
fn runNavBatchIteration(io: std.Io, nav: *NavFixture, edit: *BatchEdit, frame: *SimulationFrame, edit_threads: ?TerrainEditThreads, revert: *RevertEditTuners, thread_system: *ThreadSystem, timing: *NavBatchTiming) !usize {
    for ([_][]const DenseChunkWrites{ edit.forward_chunks.items, edit.back_chunks.items }, [_]usize{ edit.forward.items.len, edit.back.items.len }) |chunks, cell_count| {
        const reverting = chunks.ptr == edit.back_chunks.items.ptr;
        if (reverting) nav.swapRevertTuners();
        defer if (reverting) nav.swapRevertTuners();
        try nav.pipeline.pathfinding.reserveTerrainNavRecord(cell_count);
        const edit_start_ns = suite.nowNs(io);
        try applyBatch(&nav.base.world, chunks, &edit.events, if (reverting) revert.threads(edit_threads) else edit_threads);
        timing.elapsed_ns += suite.elapsedNs(edit_start_ns, suite.nowNs(io));
        timing.terrain.add(&nav.base.world);
        timing.terrain.capture(&nav.base.world, reverting);
        try publishBatchEvents(frame, edit.events.items);
        const nav_start_ns = suite.nowNs(io);
        const nav_stats = try nav.reactToFrame(frame, thread_system);
        const nav_elapsed_ns = suite.elapsedNs(nav_start_ns, suite.nowNs(io));
        const mark = nav.pipeline.pathfinding.perf.last_mark_batch;
        if (reverting) {
            timing.revert = nav_stats;
            timing.revert_mark = mark;
        } else {
            timing.forward = nav_stats;
            timing.forward_mark = mark;
        }
        timing.nav_ns += nav_elapsed_ns;
        timing.elapsed_ns += nav_elapsed_ns;
        const nav_off_main_ns = nav_stats.perf.off_main_stage_ns;
        timing.nav_off_main_ns += nav_off_main_ns;
        timing.nav_main.add(nav_elapsed_ns -| nav_off_main_ns, nav_stats);
    }
    return edit.forward.items.len + edit.back.items.len;
}

fn runNavEncloseCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runNavBatchCase(allocator, io, options, case, item_count, .enclose);
}

const EncloseVariant = enum(u8) {
    // `count` pockets of `enclose_pocket_edge` chunks in a square grid.
    pockets,
    // One pocket of edge `count`.
    pocket_edge,
    // One tunnel of `count` chunks running east from its mouth chunk (1, `enclose_tunnel_row`).
    tunnel,
};

// The enclose group's pockets (`EncloseCode`).
const EncloseConfig = struct {
    variant: EncloseVariant,
    count: u16,

    fn decode(item_count: usize) !EncloseConfig {
        const code = try EncloseCode.decode(item_count);
        if (code.count == 0) return error.NavEncloseBadCount;
        return .{ .variant = code.variant, .count = code.count };
    }

    fn pocketEdge(self: EncloseConfig) u16 {
        return if (self.variant == .pockets) enclose_pocket_edge else self.count;
    }

    fn pockets(self: EncloseConfig) u16 {
        return if (self.variant == .pockets) self.count else 1;
    }

    // Pocket `index`'s wall-ring corner chunk: rings in a square grid, one chunk apart.
    fn corner(self: EncloseConfig, index: u16) [2]u16 {
        const grid: u16 = std.math.sqrt(self.pockets());
        const stride = self.pocketEdge() + 3;
        return .{ 1 + (index % grid) * stride, 1 + (index / grid) * stride };
    }

    // Pocket `index`'s doorway chunk, on its ring's east side; the tunnel's mouth.
    fn doorway(self: EncloseConfig, index: u16) [2]u16 {
        if (self.variant == .tunnel) return .{ 1, enclose_tunnel_row };
        const ring = self.corner(index);
        const edge = self.pocketEdge();
        return .{ ring[0] + edge + 1, ring[1] + 1 + edge / 2 };
    }
};

// A walkable surface with every pocket's one-chunk wall ring written solid but its doorway.
fn buildEncloseFixture(allocator: std.mem.Allocator, io: std.Io, side: u16, config: EncloseConfig) !Fixture {
    var fixture = try buildFixture(allocator, io, side, 1);
    errdefer fixture.deinit();
    const side_chunks = side / default_chunk_size_tiles;
    if (config.variant == .tunnel) {
        // The tunnel: wall rows above and below it from its mouth to one past its far end,
        // which is capped.
        const length = config.count;
        if (length + 2 > side_chunks or enclose_tunnel_row + 2 > side_chunks) return error.NavEncloseTunnelTooLong;
        for (1..length + 2) |chunk_x| {
            try fillEncloseChunk(&fixture, @intCast(chunk_x), enclose_tunnel_row - 1);
            try fillEncloseChunk(&fixture, @intCast(chunk_x), enclose_tunnel_row + 1);
        }
        try fillEncloseChunk(&fixture, length + 1, enclose_tunnel_row);
        return fixture;
    }
    // Widened first: `std.math.sqrt` of a `u16` is a `u8`.
    const root: usize = std.math.sqrt(config.pockets());
    if (config.pockets() != root * root) return error.NavEnclosePocketsNotSquare;
    const last = config.corner(config.pockets() - 1);
    if (last[0] + config.pocketEdge() + 2 > side_chunks or last[1] + config.pocketEdge() + 2 > side_chunks) return error.NavEnclosePocketsTooLarge;
    const edge = config.pocketEdge();
    for (0..config.pockets()) |index| {
        const ring = config.corner(@intCast(index));
        const door = config.doorway(@intCast(index));
        for (0..edge + 2) |dy| for (0..edge + 2) |dx| {
            const chunk_x = ring[0] + @as(u16, @intCast(dx));
            const chunk_y = ring[1] + @as(u16, @intCast(dy));
            const on_ring = dx == 0 or dy == 0 or dx == edge + 1 or dy == edge + 1;
            if (!on_ring or (chunk_x == door[0] and chunk_y == door[1])) continue;
            try fillEncloseChunk(&fixture, chunk_x, chunk_y);
        };
    }
    return fixture;
}

// Writes chunk (`chunk_x`, `chunk_y`) of the surface solid.
fn fillEncloseChunk(fixture: *Fixture, chunk_x: u16, chunk_y: u16) !void {
    const chunk_edge = default_chunk_size_tiles;
    for (0..chunk_edge) |cy| for (0..chunk_edge) |cx| {
        _ = try fixture.world.setDenseTile(fixture.floor(0), chunk_x * chunk_edge + @as(u16, @intCast(cx)), chunk_y * chunk_edge + @as(u16, @intCast(cy)), fixture.dirt);
    };
}

// Enclose: every doorway filled solid, then carved back to the surface floor.
fn buildEncloseEdit(allocator: std.mem.Allocator, fixture: *const Fixture, config: EncloseConfig) !BatchEdit {
    var edit: BatchEdit = .{};
    errdefer edit.deinit(allocator);
    const chunk_edge = default_chunk_size_tiles;
    const layer = fixture.floor(0);
    for (0..config.pockets()) |index| {
        const door = config.doorway(@intCast(index));
        try edit.beginChunk(allocator, 0, door[0], door[1]);
        for (0..chunk_edge) |dy| for (0..chunk_edge) |dx| {
            const x = door[0] * chunk_edge + @as(u16, @intCast(dx));
            const y = door[1] * chunk_edge + @as(u16, @intCast(dy));
            try edit.add(allocator, layer, x, y, fixture.dirt, fixture.world.denseTile(layer, x, y));
        };
    }
    try edit.finish(allocator);
    return edit;
}

fn runNavBatchCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, workload: NavBatchWorkload) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const enclose: ?EncloseConfig = if (workload == .enclose) try EncloseConfig.decode(item_count) else null;
    const scale: [2]u16, const region_chunks: usize = if (enclose != null) blk: {
        const code = try EncloseCode.decode(item_count);
        break :blk .{ .{ code.level_side, code.levels }, 0 };
    } else blk: {
        const code = try RegionCode.decode(item_count);
        if (code.sparse_props) return error.ChunkScaleSparsePropsOffExplosion;
        break :blk .{ .{ code.level_side, code.levels }, code.region_chunks };
    };
    const side = scale[0];
    const levels = scale[1];
    if (side < 256 or (if (workload == .enclose) levels != 1 else levels < cave_in_levels + 1)) return error.ChunkScaleWorldTooSmall;

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    // Every cell of the edit's chunks as a mark; its keys: a cave-in's square on each of its
    // levels, an explosion disk's bounding square, or each doorway chunk with its neighbours.
    const edit_chunks: usize = if (enclose) |config| config.pockets() else region_chunks;
    const batch_keys: usize = switch (workload) {
        .cave_in => cave_in_levels * nav_size.squareBatchKeys(std.math.sqrt(region_chunks / cave_in_levels)),
        .explosion_fill => nav_size.squareBatchKeys(std.math.sqrt(region_chunks)),
        .enclose => edit_chunks * nav_size.squareBatchKeys(1),
    };
    const chunk_cells = @as(usize, default_chunk_size_tiles) * default_chunk_size_tiles;
    // The world first: its content sizes the nav.
    var world_fixture = if (enclose) |config| try buildEncloseFixture(allocator, io, side, config) else try buildFixture(allocator, io, side, levels);
    var world_owned = true;
    defer if (world_owned) world_fixture.deinit();
    var size_config = navSizeConfig(side, levels, participant_count, .{ .mark_chunks = edit_chunks * chunk_cells, .links = 0, .keys = batch_keys });
    size_config.content = pathfinding_test_support.navStorageContentOf(&world_fixture.world);
    const group_name = switch (workload) {
        .cave_in => nav_cave_in_group.name,
        .explosion_fill => nav_explosion_fill_group.name,
        .enclose => nav_enclose_group.name,
    };
    try nav_size.checkNavSize(group_name, item_count, case, size_config);

    world_owned = false;
    var nav = try navFixtureOver(allocator, io, world_fixture, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer nav.deinit();
    try nav_size.checkNavBytes(group_name, item_count, size_config, &nav.pipeline.pathfinding);
    var edit = switch (workload) {
        .cave_in => try buildCaveInEdit(allocator, &nav.base, region_chunks),
        .explosion_fill => try buildExplosionEdit(allocator, &nav.base, region_chunks, 1),
        .enclose => try buildEncloseEdit(allocator, &nav.base, enclose.?),
    };
    defer edit.deinit(allocator);
    var frame = SimulationFrame.init(allocator);
    defer frame.deinit();
    // The cave-in region starts carved, so each iteration collapses then re-carves it.
    if (workload == .cave_in) {
        try nav.pipeline.pathfinding.reserveTerrainNavRecord(edit.back.items.len);
        try applyBatch(&nav.base.world, edit.back_chunks.items, &edit.events, null);
        try publishBatchEvents(&frame, edit.events.items);
        _ = try nav.reactToFrame(&frame, nav.threads);
    }

    const world = &nav.base.world;
    const system = &nav.pipeline.pathfinding;
    world.terrain_edit_plan_tuner = AdaptiveWorkTuner.init(.{});
    world.terrain_edit_write_tuner = AdaptiveWorkTuner.init(.{});
    var revert_tuners = RevertEditTuners.init();
    nav.setTuners(case);
    const edit_threads = TerrainEditThreads{
        .thread_system = thread_ptr,
        .plan_tuner = &world.terrain_edit_plan_tuner,
        .write_tuner = &world.terrain_edit_write_tuner,
        .controls = .{ .adaptive = case.adaptive, .batches_per_participant = case.stageBatchesPerParticipant(), .max_worker_threads = case.maxWorkerThreads(), .items_per_range = case.stageItemsPerRangeForPartition(suite.chunk_partition_items, edit_range_alignment_items) },
    };

    var unused_timing: NavBatchTiming = .{};
    var warm = suite.Warmup.init(options, case, 1);
    while (warm.nextSettled(navBatchTunerSettle(&nav, &revert_tuners))) {
        _ = try runNavBatchIteration(io, &nav, &edit, &frame, edit_threads, &revert_tuners, thread_ptr, &unused_timing);
    }
    const settle = navBatchTunerSettle(&nav, &revert_tuners);
    const remask_tuner_start = suite.TunerStart.of(system.tuners.nav.getPtrConst(.remask), case);
    const patch_tuner_start = suite.TunerStart.of(system.tuners.nav.getPtrConst(.patch), case);
    const edit_window = suite.TunerWindow(edit_stage_names.len).begin(editTuners(world, &revert_tuners));

    var accumulator = suite.StatsAccumulator.init(item_count);
    var plan_total: u128 = 0;
    var write_total: u128 = 0;
    var nav_total: u128 = 0;
    var main_total: u128 = 0;
    var cells_changed: usize = 0;
    var forward_reactions = suite.NavReactionShapes{};
    var revert_reactions = suite.NavReactionShapes{};
    var edit_shapes = suite.StageShapes(edit_stage_names.len){};
    var nav_main = suite.NavMainSummary{};
    for (0..options.iterations) |_| {
        var timing: NavBatchTiming = .{};
        cells_changed = try runNavBatchIteration(io, &nav, &edit, &frame, edit_threads, &revert_tuners, thread_ptr, &timing);
        const forward = timing.forward;
        nav_main.merge(timing.nav_main);
        nav_main.endSample();
        if (enclose) |config| {
            if (forward.perf.conn_splits != config.pockets()) return error.NavEnclosePocketsNotSplit;
        }
        const elapsed_ns = timing.elapsed_ns;
        accumulator.record(elapsed_ns, forward.perf.remask_batch);
        forward_reactions.add(timing.forward_mark, forward);
        revert_reactions.add(timing.revert_mark, timing.revert);
        edit_shapes.add(timing.terrain.stages);
        try suite.checkNavReactionDispatched(case, thread_ptr, timing.forward_mark, forward);
        try suite.checkNavReactionDispatched(case, thread_ptr, timing.revert_mark, timing.revert);
        try suite.checkStagesDispatched(case, thread_ptr, case.stageItemsPerRangeForPartition(suite.chunk_partition_items, edit_range_alignment_items), &timing.terrain.stages);
        plan_total += timing.terrain.plan_ns;
        write_total += timing.terrain.write_ns;
        nav_total += timing.nav_ns;
        // Main is everything but the terrain and nav reaction stages that ran on workers.
        main_total += elapsed_ns -| (timing.terrain.off_main_ns + timing.nav_off_main_ns);
    }
    try nav_size.checkNavBytes(group_name, item_count, size_config, &nav.pipeline.pathfinding);
    var stats = accumulator.finish();
    // The item count is a case code, so report throughput over the cells written.
    stats.output_count = cells_changed;
    stats.items_per_second = suite.itemsPerSecond(cells_changed, stats.mean_ns);
    // The forward reaction's stages in the workload column; the revert reaction's and both
    // edits' stages under the row.
    forward_reactions.summarize(&stats, fixtures.floodTunerWorkers(&nav.pipeline.pathfinding, case));
    stats.nav_main = nav_main;
    revert_reactions.print(&stats.details, "revert_reaction");
    edit_shapes.print(&stats.details, "edit_stages", edit_stage_names);
    if (stats.iterations > 0) {
        const iterations: u128 = stats.iterations;
        stats.terrain_edit_phases = .{
            .plan_ns = @intCast(plan_total / iterations),
            .write_ns = @intCast(write_total / iterations),
            .nav_ns = @intCast(nav_total / iterations),
            .main_ns = @intCast(main_total / iterations),
        };
    }
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(system.tuners.nav.getPtrConst(.remask), remask_tuner_start);
        stats.secondary_work_tuning = suite.workTuningSummary(system.tuners.nav.getPtrConst(.patch), patch_tuner_start);
        edit_window.printTuning(&stats.details, edit_stage_names, editTuners(world, &revert_tuners));
    }
    return stats;
}

fn runNavLevelAddCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const code = try LevelAddCode.decode(item_count);
    const replace = code.replace;
    const side = code.level_side;
    const levels = code.levels;
    if (levels < cave_in_levels + 1 or side < 256) return error.ChunkScaleWorldTooSmall;
    // Every iteration (warmup included) adds a level, so the size check holds at the
    // deepest the run gets.
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    // The in-band cycles' dig square is the largest marks batch; level builds add none. The
    // world first: its content, and the levels the run adds, size the nav. Added levels are
    // solid, except the replace case's newest level, which is walkable until its band blocks
    // it, so at most one added level is open at a time.
    var world_fixture = try buildFixture(allocator, io, side, levels);
    var world_owned = true;
    defer if (world_owned) world_fixture.deinit();
    const added_levels = options.warmup_iterations + options.iterations;
    const dig_batch: nav_size.NavBatch = .{ .mark_chunks = dig_cell_count, .links = 0, .keys = nav_size.squareBatchKeys(dig_window_chunks) };
    var size_config = navSizeConfig(side, levels + added_levels, participant_count, dig_batch);
    var content = pathfinding_test_support.navStorageContentOf(&world_fixture.world);
    if (replace) {
        const chunks = world_fixture.world.chunkCountPerLevel();
        content.open_chunks += chunks;
        content.max_level_open = chunks;
    }
    size_config.content = content;
    try nav_size.checkNavSize(nav_level_add_group.name, item_count, case, size_config);

    world_owned = false;
    var nav = try navFixtureOver(allocator, io, world_fixture, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer nav.deinit();
    try nav_size.checkNavBytes(nav_level_add_group.name, item_count, size_config, &nav.pipeline.pathfinding);
    nav.threads = thread_ptr;
    nav.setTuners(case);
    var frame = SimulationFrame.init(allocator);
    defer frame.deinit();
    var driver = try DigDriver.init(allocator, levels - 1);
    defer driver.deinit();
    var refill = try buildDigRefillEdit(allocator, &nav.base);
    defer refill.deinit(allocator);

    // The stage tuners train in play on ordinary nav reactions, so the tuned case settles them
    // on in-band cycles; the level count stays fixed meanwhile, so the settle length never
    // changes the measured world. At least two cycles in every case.
    var warm = suite.Warmup.custom(case, 2, suite.adaptiveSettleIterationLimit(options));
    while (warm.nextSettled(nav.stageTunerSettle())) try levelAddInBandCycle(allocator, io, &nav, &driver, &refill);
    // Each untimed level add after an in-band cycle grows the per-range scratch to the shape
    // of the fresh build set every timed level build starts from: each build stage selects
    // once per one-level build, so it takes its full-pool first selection, never a jump shape.
    for (0..options.warmup_iterations) |_| {
        try levelAddInBandCycle(allocator, io, &nav, &driver, &refill);
        _ = try levelAddIteration(io, &nav, &frame, replace);
    }
    const settle = nav.stageTunerSettle();
    // The headline is the level build's remask, on the build set every nav build starts fresh.
    const remask_tuner = nav.pipeline.pathfinding.tuners.nav_build.getPtrConst(.remask);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var reactions = suite.NavReactionShapes{};
    var nav_main = suite.NavMainSummary{};
    var main_total: u128 = 0;
    for (0..options.iterations) |_| {
        try levelAddInBandCycle(allocator, io, &nav, &driver, &refill);
        const elapsed_ns = try levelAddIteration(io, &nav, &frame, replace);
        accumulator.record(elapsed_ns, nav.last_stats.perf.remask_batch);
        try suite.checkNavReactionDispatched(case, thread_ptr, .{}, nav.last_stats);
        reactions.add(.{}, nav.last_stats);
        nav.addLastNavMain(&nav_main);
        main_total += elapsed_ns -| nav.last_stats.perf.off_main_stage_ns;
    }
    try nav_size.checkNavBytes(nav_level_add_group.name, item_count, size_config, &nav.pipeline.pathfinding);
    if (nav.base.world.levelCount() != levels + added_levels) return error.LevelAddDepthMismatch;
    var stats = accumulator.finish();
    stats.output_count = nav.base.world.levelCount();
    if (stats.iterations > 0) stats.main_ns = @intCast(main_total / stats.iterations);
    reactions.summarize(&stats, fixtures.floodTunerWorkers(&nav.pipeline.pathfinding, case));
    stats.nav_main = nav_main;
    // One level (or band) added per iteration.
    stats.items_per_second = suite.itemsPerSecond(1, stats.mean_ns);
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(remask_tuner, .fresh);
    }
    return stats;
}

// The level-add case's in-band nav work, untimed: the nav-dig workload's digs and reaction on
// the forward stage tuners, then its refill and reaction on the revert set, which return
// terrain and nav to their start state.
fn levelAddInBandCycle(allocator: std.mem.Allocator, io: std.Io, nav: *NavFixture, driver: *DigDriver, refill: *BatchEdit) !void {
    _ = try runNavIteration(io, nav, driver, .dig);
    try resetNavWorkload(allocator, nav, driver, refill, .dig);
}

// One level-add iteration; returns its timed span. The main case adds a level with a
// solid floor band, then runs the nav reaction on a step with no events (it builds the
// added level). The replace case first adds a level with a walkable floor and reacts
// (untimed, on the revert stage tuners), then adds a blocking band to that newest level and
// reacts (it rebuilds that level), so each level gains at most one band.
fn levelAddIteration(io: std.Io, nav: *NavFixture, frame: *SimulationFrame, replace: bool) !u64 {
    const world = &nav.base.world;
    const new_level_z = -@as(i32, @intCast(world.levelCount())) * level_z_step;
    if (replace) {
        const level = try world.addLevel(new_level_z);
        _ = try world.addDenseLayer(level, 0, .floor, nav.base.tunnel);
        {
            nav.swapRevertTuners();
            defer nav.swapRevertTuners();
            try reactToLevelChange(nav, frame);
        }
        const start_ns = suite.nowNs(io);
        _ = try world.addDenseLayer(level, 0, .obstacle, nav.base.dirt);
        try reactToLevelChange(nav, frame);
        return suite.elapsedNs(start_ns, suite.nowNs(io));
    }
    const start_ns = suite.nowNs(io);
    const level = try world.addLevel(new_level_z);
    _ = try world.addDenseLayer(level, 0, .floor, nav.base.dirt);
    try reactToLevelChange(nav, frame);
    return suite.elapsedNs(start_ns, suite.nowNs(io));
}

// The nav reaction to a step whose only nav change is a level added or a level's content
// revision; fails unless it built exactly one level, its remask batch folding every chunk of
// that level with the step's marks batch.
fn reactToLevelChange(nav: *NavFixture, frame: *SimulationFrame) !void {
    frame.beginStep();
    const start_ns = suite.nowNs(nav.io);
    const stats = try nav.pipeline.pathfinding.reactToPostCommitNavEvents(frame, &nav.pipeline.static_colliders, &nav.base.world, nav.threads);
    nav.last_reaction_ns = suite.elapsedNs(start_ns, suite.nowNs(nav.io));
    if (stats.levels_built != 1) return error.NavLevelNotBuilt;
    if (stats.perf.remask_batch.item_count != nav.pipeline.pathfinding.graph.chunkCount() + stats.dirty_chunks) return error.NavLevelRemaskMissedChunks;
    nav.last_stats = stats;
}
