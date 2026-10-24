// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Game render prep, CPU only, no SDL_GPU: the production-shaped frame's dynamic record
//! collection, depth-bucket emit with sparse visible-tile submission through `WorldSystem`,
//! sprite-batch snapshot and vertex emit, and a `mergeDrawList` against the static groups.
//!
//! `render-game-prep` (play level 0) and `render-game-prep-dense-deep` (play level
//! `bench_mid_player_level`): N render entities.
//! Timed: the bench's own phase timers, `entity_collect` (collect plus emit), `merge`,
//! `snapshot`, and `vertex_emit` (the threaded stage); the render window sets stay untimed.
//! Prints `vertices=`, `sprites=`, `skipped=`, `merged_groups=`, `sparse=` (sparse tiles
//! submitted), `dynamic_records=`, `static_groups=`, `merged_tilemap_groups=`, and the phases.
//! Pass shape: one merged `.tilemap` group at every count and play level, so draw groups never
//! grow with dense window depth. Asserts check that group count, that the collect returns
//! every entity and active particle, and that a fixed threaded case dispatches the vertex
//! emit to workers.
//!
//! `render-game-prep-offview` times `collectDynamicRecords` alone under the production
//! camera window: a fixed set of rows inside it and a growing count of rows outside it on
//! one fixed level. Pass shape: collect time and the record and command capacities flat
//! in the off-view count. Asserts check only that the collect returns the in-view rows and
//! active particles.

const std = @import("std");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const ParticleSystem = @import("../game/systems/particle.zig").ParticleSystem;
const render_depth = @import("../game/render_depth.zig");
const render_prep = @import("../game/render_prep.zig");
const WorldDepth = render_depth.WorldDepth;
const WorldSystem = @import("../game/world/system.zig").WorldSystem;
const DenseLayerRenderWindow = @import("../game/world/render.zig").DenseLayerRenderWindow;
const level_z_step = @import("../game/world/system.zig").level_z_step;
const Renderer = @import("../render/renderer.zig");
const mergeDrawList = Renderer.mergeDrawList;
const sprite_batch = @import("../render/sprite_batch.zig");
const fixtures = @import("fixtures.zig");
const suite = @import("suite.zig");

const sprite_prep_range_alignment_items = sprite_batch.sprite_prep_range_alignment_items;
const world_overscan_chunks: u16 = 1;
/// Viewport used for world chunk visibility during sparse-layer emit only.
const bench_viewport_w: f32 = 800;
const bench_viewport_h: f32 = 450;
const static_sprite_group_count: usize = 1;
/// `submitStaticDenseGeometry` emits at most one interleave-partitioned
/// composite draw per resident layer; this fixture has no sparse/entity content
/// at non-active levels, so it always hits the common single-bucket case, i.e.
/// exactly one retained `.tilemap` group regardless of dense window depth.
const tilemap_group_count: usize = 1;
const max_static_group_count: usize = tilemap_group_count + static_sprite_group_count;
/// Mid-depth play level for dense render-window bench variants.
const bench_mid_player_level: u16 = 40;

const FixtureConfig = struct {
    player_level: u16 = 0,

    fn staticGroupCount(self: FixtureConfig) usize {
        _ = self;
        return tilemap_group_count + static_sprite_group_count;
    }
};

const default_fixture_config = FixtureConfig{};

pub const offview_group = suite.BenchmarkGroup{
    .name = "render-game-prep-offview",
    .item_label = "off-view render rows",
    .item_counts = &offview_item_counts,
    .runCase = runOffviewCase,
    .write_workload = writeOffviewWorkload,
    // Collect runs on the main thread: the serial case is its only path.
    .cases = &suite.serial_cases,
};

pub const group = suite.BenchmarkGroup{
    .name = "render-game-prep",
    .item_label = "render entities",
    .item_counts = &suite.event_scale_counts,
    .runCase = runCase,
    .write_workload = writeRenderGamePrepWorkload,
};

pub const dense_deep_group = suite.BenchmarkGroup{
    .name = "render-game-prep-dense-deep",
    .item_label = "render entities",
    .item_counts = &suite.event_scale_counts,
    .runCase = runDenseDeepCase,
    .write_workload = writeRenderGamePrepWorkload,
};

const Fixture = struct {
    data: DataSystem,
    particles: ParticleSystem,
    world: WorldSystem,
    scene_prep: render_prep.DynamicScenePrep,
    player_entity: EntityId,
    runtime_assets: RuntimeAssets,
    static_groups: [max_static_group_count]sprite_batch.DrawGroup,
    static_group_count: usize,
    player_level: u16,
    tile_texture: sprite_batch.TextureId,
    white_texture: sprite_batch.TextureId,
    item_count: usize = 0,
    dynamic_record_capacity: usize,
    last_collected_records: usize = 0,
    sparse_tile_count: usize,
    world_width_px: f32 = 0,
    world_height_px: f32 = 0,

    fn deinit(self: *Fixture) void {
        self.scene_prep.deinit();
        self.particles.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    fn gameplayScene(self: *Fixture) render_prep.GameplayScene {
        return .{
            .data = &self.data,
            .world = &self.world,
            .player_entity = self.player_entity,
            .player_level = self.player_level,
            .particles = &self.particles,
            .overscan_chunks = world_overscan_chunks,
        };
    }
};

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithConfig(allocator, io, options, case, item_count, default_fixture_config);
}

pub fn runDenseDeepCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithConfig(allocator, io, options, case, item_count, .{ .player_level = bench_mid_player_level });
}

fn runCaseWithConfig(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: suite.Options,
    case: suite.BenchmarkCase,
    item_count: usize,
    fixture_config: FixtureConfig,
) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    const table = &fixtures.TextureTable.bench;

    const fixture = try allocator.create(Fixture);
    errdefer allocator.destroy(fixture);
    try initFixture(fixture, allocator, io, item_count, fixture_config);
    defer {
        fixture.deinit();
        allocator.destroy(fixture);
    }

    const command_capacity = fixture.world.reserveRenderRecords() + fixture.dynamic_record_capacity;
    const vertex_capacity = command_capacity * 6;

    var batch = sprite_batch.SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(command_capacity, vertex_capacity, command_capacity);

    var draw_list: std.ArrayList(sprite_batch.DrawGroup) = .empty;
    defer draw_list.deinit(allocator);
    try draw_list.ensureTotalCapacity(allocator, fixture.static_group_count + command_capacity);

    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();

    var warm = suite.Warmup.init(options, case, 0);
    while (warm.next(suite.tunerSettled(&batch.adaptive_tuner))) {
        _ = try runMeasuredOnce(
            io,
            fixture,
            &batch,
            &draw_list,
            table.resolver(),
            &threads,
            case,
            allocator,
        );
    }
    const settled_before_measurement = if (case.adaptive) suite.tunerSettled(&batch.adaptive_tuner) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var phase_accumulator = fixtures.PhaseAccumulator(suite.RenderGamePrepPhaseSummary){};
    var last_prep = sprite_batch.SpritePrepStats{};
    var last_sparse_submitted: usize = 0;
    var last_merged_groups: usize = 0;
    var last_merged_tilemap_groups: usize = 0;
    for (0..options.iterations) |_| {
        const measured = try runMeasuredOnce(
            io,
            fixture,
            &batch,
            &draw_list,
            table.resolver(),
            &threads,
            case,
            allocator,
        );
        accumulator.record(measured.timed_ns, measured.stats.perf.batch);
        try suite.checkStageDispatched(case, &threads, case.stageItemsPerRange(sprite_prep_range_alignment_items), measured.stats.perf.batch);
        phase_accumulator.record(measured.phases);
        last_prep = measured.stats;
        last_sparse_submitted = measured.sparse_submitted;
        last_merged_groups = measured.merged_group_count;
        last_merged_tilemap_groups = measured.merged_tilemap_group_count;
        // This fixture has no sparse/entity content at non-active levels, so it
        // always hits `partitionDenseCompositeBuckets`'s common single-bucket
        // case: exactly one merged `.tilemap` group regardless of player_level
        // (surface/deep). Proves draw/bind count no longer scales with dense
        // window depth.
        std.debug.assert(last_merged_tilemap_groups == tilemap_group_count);
    }

    var stats = accumulator.finish();
    stats.candidate_pairs = last_prep.vertex_count;
    stats.output_count = last_prep.valid_sprite_count;
    stats.deferred_count = last_prep.skipped_invalid_count;
    stats.sample_count = last_merged_groups;
    stats.render_game_prep_phases = phase_accumulator.finish(options.iterations);
    stats.render_game_prep_sparse_submitted = last_sparse_submitted;
    stats.render_game_prep_dynamic_records = fixture.last_collected_records;
    stats.render_game_prep_static_groups = fixture.static_group_count;
    stats.render_game_prep_merged_tilemap_groups = last_merged_tilemap_groups;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(suite.tunerReport(&batch.adaptive_tuner), settled_before_measurement);
    }
    return stats;
}

const MeasuredGamePrep = struct {
    // The frame's timed phases summed; excludes the untimed render window sets.
    timed_ns: u64,
    stats: sprite_batch.SpritePrepStats,
    phases: suite.RenderGamePrepPhaseSummary,
    sparse_submitted: usize,
    merged_group_count: usize,
    merged_tilemap_group_count: usize,
};

fn runMeasuredOnce(
    io: std.Io,
    fixture: *Fixture,
    batch: *sprite_batch.SpriteBatch,
    draw_list: *std.ArrayList(sprite_batch.DrawGroup),
    resolver: sprite_batch.TextureResolver,
    thread_system: *ThreadSystem,
    case: suite.BenchmarkCase,
    allocator: std.mem.Allocator,
) !MeasuredGamePrep {
    batch.beginFrame();

    // The fixture moves the render window twice a frame (whole world for collect,
    // camera for the sparse emit), which production never does, so the window sets
    // stay out of every timed span; production's one window update per frame is
    // measured by the `render-sparse-window-*` groups.
    try setBenchCollectChunkVisibility(fixture);
    const collect_start_ns = suite.nowNs(io);
    try collectProductionDynamicRecords(fixture);
    const collect_end_ns = suite.nowNs(io);
    try setBenchSparseEmitChunkVisibility(fixture);
    const emit_start_ns = suite.nowNs(io);
    const sparse_submitted = try emitLayeredCommands(fixture, batch);
    const emit_end_ns = suite.nowNs(io);

    const snapshot_start_ns = suite.nowNs(io);
    _ = batch.snapshotCommandsAssumeCapacity(resolver);
    const snapshot_end_ns = suite.nowNs(io);

    const vertex_start_ns = suite.nowNs(io);
    const vertex_batch = emitVertices(batch, thread_system, case);
    batch.buildDrawGroupsAssumeCapacity();
    const stats = batch.finishPrepStats(vertex_batch);
    const vertex_end_ns = suite.nowNs(io);

    const merge_start_ns = suite.nowNs(io);
    try mergeDrawList(draw_list, allocator, fixture.static_groups[0..fixture.static_group_count], batch.draw_groups.items);
    const merged_group_count = draw_list.items.len;
    var merged_tilemap_group_count: usize = 0;
    for (draw_list.items) |merged_group| {
        if (merged_group.material == .tilemap) merged_tilemap_group_count += 1;
    }
    const merge_end_ns = suite.nowNs(io);

    const phases = suite.RenderGamePrepPhaseSummary{
        .entity_collect_ns = suite.elapsedNs(collect_start_ns, collect_end_ns) + suite.elapsedNs(emit_start_ns, emit_end_ns),
        .merge_ns = suite.elapsedNs(merge_start_ns, merge_end_ns),
        .snapshot_ns = suite.elapsedNs(snapshot_start_ns, snapshot_end_ns),
        .vertex_emit_ns = suite.elapsedNs(vertex_start_ns, vertex_end_ns),
    };
    return .{
        .timed_ns = phases.entity_collect_ns + phases.merge_ns + phases.snapshot_ns + phases.vertex_emit_ns,
        .stats = stats,
        .sparse_submitted = sparse_submitted,
        .merged_group_count = merged_group_count,
        .merged_tilemap_group_count = merged_tilemap_group_count,
        .phases = phases,
    };
}

fn emitVertices(
    batch: *sprite_batch.SpriteBatch,
    thread_system: *ThreadSystem,
    case: suite.BenchmarkCase,
) BatchStats {
    return batch.emitVerticesAssumeCapacity(thread_system, .{
        .items_per_range = case.stageItemsPerRange(sprite_prep_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

// Requires `setBenchCollectChunkVisibility` first: full-world visibility is an
// upper-bound ceiling for entity_collect_ns, not the production camera/chunk/AABB
// cull path.
fn collectProductionDynamicRecords(fixture: *Fixture) !void {
    const visible = benchCollectVisibleRect(fixture.world_width_px, fixture.world_height_px);
    try render_prep.collectDynamicRecords(
        &fixture.scene_prep,
        fixture.gameplayScene(),
        visible,
        &fixture.runtime_assets,
        1.0,
    );
    fixture.last_collected_records = fixture.scene_prep.records.items.len;
    std.debug.assert(fixture.last_collected_records == expectedBenchCollectedRecords(fixture.item_count));
}

fn setBenchCollectChunkVisibility(fixture: *Fixture) !void {
    try fixture.world.setVisibleChunksForWorldRect(.{
        .x = 0,
        .y = 0,
        .w = fixture.world_width_px,
        .h = fixture.world_height_px,
    }, 0, fixture.player_level);
}

fn setBenchSparseEmitChunkVisibility(fixture: *Fixture) !void {
    const camera_rect = cameraWorldRect(fixture.world_width_px, fixture.world_height_px);
    try fixture.world.setVisibleChunksForWorldRect(camera_rect, world_overscan_chunks, fixture.player_level);
}

/// Full-world pixel bounds for entity collect. Perf benches target the requested
/// entity count; camera culling is production behavior and is not measured here.
fn benchCollectVisibleRect(world_width_px: f32, world_height_px: f32) render_prep.VisibleWorldRect {
    return .{
        .min_x = 0,
        .min_y = 0,
        .max_x = world_width_px,
        .max_y = world_height_px,
    };
}

fn emitLayeredCommands(fixture: *Fixture, batch: *sprite_batch.SpriteBatch) !usize {
    const world = &fixture.world;
    var sparse_submitted: usize = 0;
    var sparse_range: usize = 0;
    var dynamic_span_index: usize = 0;
    var dynamic_depth = nextDynamicDepthSpan(&fixture.scene_prep, &dynamic_span_index);
    while (sparse_range < world.sparseDepthRangeCount() or dynamic_depth != null) {
        if (sparse_range < world.sparseDepthRangeCount()) {
            if (dynamic_depth == null or world.sparseDepthRangeAt(sparse_range) <= dynamic_depth.?) {
                sparse_submitted += try world.submitVisibleSparseSprites(batch, fixture.tile_texture, sparse_range);
                sparse_range += 1;
                continue;
            }
        }

        const dynamic_span = fixture.scene_prep.depthSpans()[dynamic_span_index - 1];
        try emitPreparedDrawSpan(&fixture.scene_prep, batch, dynamic_span, fixture.white_texture);
        dynamic_depth = nextDynamicDepthSpan(&fixture.scene_prep, &dynamic_span_index);
    }
    return sparse_submitted;
}

fn nextDynamicDepthSpan(prep: *const render_prep.DynamicScenePrep, span_index: *usize) ?i32 {
    if (span_index.* >= prep.depthSpans().len) return null;
    const depth = prep.depthSpans()[span_index.*].depth;
    span_index.* += 1;
    return depth;
}

fn emitPreparedDrawSpan(
    prep: *const render_prep.DynamicScenePrep,
    batch: *sprite_batch.SpriteBatch,
    span: render_prep.DynamicDepthRange,
    fallback_texture: sprite_batch.TextureId,
) !void {
    const sorted_indices = prep.sort_indices.items;
    const records = prep.records.items;
    for (sorted_indices[span.start..span.end]) |record_index| {
        try emitPreparedDraw(batch, records[record_index].draw, fallback_texture);
    }
}

fn emitPreparedDraw(
    batch: *sprite_batch.SpriteBatch,
    draw: render_prep.PreparedDraw,
    fallback_texture: sprite_batch.TextureId,
) !void {
    switch (draw) {
        .sprite => |sprite| try batch.drawSprite(sprite),
        .rect => |rect| try batch.drawSprite(.{
            .texture = fallback_texture,
            .dest = rect.rect,
            .tint = rect.color,
            .order = rect.order,
        }),
    }
}

fn initFixture(
    fixture: *Fixture,
    allocator: std.mem.Allocator,
    io: std.Io,
    item_count: usize,
    fixture_config: FixtureConfig,
) !void {
    const sparse_tile_count = sparseTileCount(item_count);
    const particle_capacity = particleCapacity(item_count);
    const tile_texture = fixtures.textureId(1, 1);

    // A square walkable level holding the sparse grid and the entity layout.
    const tile_size_px = world_tileset_meta.required_tile_size;
    const entity_layout = entitySpawnLayout(item_count);
    const sparse_grid_side = suite.ceilSqrt(sparse_tile_count);
    const sparse_world_tiles = @max(@as(u16, @intCast(sparse_grid_side * 2 + 8)), 64);
    const entity_tiles: u16 = @intFromFloat(@ceil(@max(entity_layout.width, entity_layout.height) / tile_size_px));
    const world_tiles = @max(sparse_world_tiles, entity_tiles);
    fixture.* = .{
        .item_count = item_count,
        .data = DataSystem.init(allocator),
        .particles = try ParticleSystem.init(allocator, .{ .capacity = particle_capacity }),
        .world = undefined,
        .scene_prep = render_prep.DynamicScenePrep.init(allocator),
        .player_entity = undefined,
        .runtime_assets = RuntimeAssets.init(allocator),
        .static_groups = undefined,
        .static_group_count = 0,
        .player_level = fixture_config.player_level,
        .tile_texture = tile_texture,
        .white_texture = fixtures.textureId(0, 1),
        .dynamic_record_capacity = 0,
        .sparse_tile_count = sparse_tile_count,
    };
    errdefer {
        fixture.scene_prep.deinit();
        fixture.particles.deinit();
        fixture.data.deinit();
    }
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    fixture.world = try fixtures.buildBandedWorld(allocator, &tileset, world_tiles, 1, "grass", "grass");
    errdefer fixture.world.deinit();

    fixture.static_group_count = benchStaticGroups(tile_texture, fixture_config, &fixture.static_groups);
    const world_px = @as(f32, @floatFromInt(world_tiles)) * tile_size_px;
    const world_width_px = world_px;
    const world_height_px = world_px;

    // Render-prep's dense-window entity cull bounds the deep submit limit by
    // the world's real level count (WorldSystem.levelInWindow), so a deep
    // fixture_config.player_level needs that many real (dense-layer-empty)
    // levels to exist, or every entity placed at that level would be culled
    // as beyond the window even though it matches player_level exactly.
    var level_index: u16 = 1;
    while (level_index <= fixture_config.player_level) : (level_index += 1) {
        _ = try fixture.world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
    }

    const deco = try fixture.world.requireTileByName(&tileset, "deco_0");
    // Sparse tiles sit on the player's level so both variants draw them: sparse
    // tiles draw only on the render window's levels.
    const level: u16 = fixture_config.player_level;

    for (0..sparse_tile_count) |index| {
        const x: u16 = @intCast((index % sparse_grid_side) * 2 + 4);
        const y: u16 = @intCast((index / sparse_grid_side) * 2 + 4);
        std.debug.assert(x < fixture.world.width and y < fixture.world.height);
        const band = benchmarkSparseDepth(index);
        _ = try fixture.world.addSparseTile(level, x, y, deco, @intCast(index % 3), band);
    }

    fixture.world_width_px = world_width_px;
    fixture.world_height_px = world_height_px;

    var player_entity: EntityId = undefined;
    for (0..item_count) |index| {
        const entity = try fixture.data.createEntity();
        if (index == 0) player_entity = entity;
        const position = entity_layout.positionFor(index);
        try fixture.data.setMovementBody(entity, .{
            .position = position,
            .previous_position = position,
            .position_z = @intCast(@as(i32, @intCast(index % 17)) - 8),
        });
        syncEntityScopeChunk(&fixture.data, entity, &fixture.world, position);
        try fixture.data.setPrimitiveVisual(entity, .{
            .size = .{ .x = 14 + @as(f32, @floatFromInt(index % 5)), .y = 14 + @as(f32, @floatFromInt(index % 7)) },
            .color = fixtures.tintFor(index),
            .depth = benchmarkEntityDepth(index),
            .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        });
        // Render-prep culls non-player entities to their own world
        // level; deep-window fixtures (player_level > 0) must place entities
        // on that same level or collectDynamicRecords drops them all.
        if (fixture_config.player_level != 0) {
            try fixture.data.setWorldLevel(entity, fixture_config.player_level);
        }
    }

    const active_particles = @min(particle_capacity, @max(item_count / 16, 1));
    for (0..active_particles) |index| {
        const emitted = fixture.particles.emit(.{
            .position = entity_layout.positionFor(index),
            .base_z = @intCast(@as(i32, @intCast(index % 13)) - 6),
            .depth = benchmarkParticleDepth(index),
            .start_size = 4 + @as(f32, @floatFromInt(index % 4)),
            .lifetime = 1_000_000,
        });
        std.debug.assert(emitted);
    }

    fixture.player_entity = player_entity;
    const scene = fixture.gameplayScene();
    try render_prep.ensureScenePrepCapacity(&fixture.scene_prep, scene);
    fixture.dynamic_record_capacity = render_prep.dynamicRecordCapacity(scene);
}

/// Builds the static draw groups `submitStaticDenseGeometry` produces: one retained `.tilemap` composite draw ordered at the window's
/// own shallowest submitted layer (`start_level`, the common single-bucket
/// case this fixture always hits) plus one static sprite accent group.
fn benchStaticGroups(
    tile_texture: sprite_batch.TextureId,
    fixture_config: FixtureConfig,
    out: *[max_static_group_count]sprite_batch.DrawGroup,
) usize {
    const start_level = benchWindowStartLevel(fixture_config.player_level);
    out[0] = .{
        .source = .static,
        .material = .tilemap,
        .texture = tile_texture,
        .presentation = .world,
        .order = sprite_batch.RenderOrder.world(benchDenseFloorDepth(start_level)),
        .first_vertex = 0,
        .vertex_count = 6,
        .tile_data = .{ .index = 0, .generation = 1 },
    };
    const sprite_index = tilemap_group_count;
    out[sprite_index] = .{
        .source = .static,
        .material = .sprite,
        .texture = tile_texture,
        .presentation = .world,
        .order = sprite_batch.RenderOrder.world(benchAccentSpriteDepth(fixture_config)),
        .first_vertex = @intCast(sprite_index * 6),
        .vertex_count = 12,
    };
    return fixture_config.staticGroupCount();
}

fn benchWindowStartLevel(player_level: u16) u16 {
    const render_window = DenseLayerRenderWindow{};
    if (player_level > 0 and render_window.ceiling_when_underground) {
        return player_level - 1;
    }
    return player_level;
}

fn benchDenseFloorDepth(world_level: u16) i32 {
    const base_z: i32 = -@as(i32, @intCast(world_level)) * level_z_step;
    return render_depth.worldZWithOffset(base_z, .floor);
}

fn benchAccentSpriteDepth(fixture_config: FixtureConfig) i32 {
    const top_level = benchWindowStartLevel(fixture_config.player_level);
    return benchDenseFloorDepth(top_level) + render_depth.worldZ(.actor) - render_depth.worldZ(.floor);
}

fn sparseTileCount(item_count: usize) usize {
    return @max(@min(item_count / 4, 12_288), 64);
}

fn particleCapacity(item_count: usize) usize {
    return @max(item_count / 8, 64);
}

const EntitySpawnLayout = struct {
    cols: usize,
    stride: f32,
    origin: math.Vec2,
    width: f32,
    height: f32,

    fn positionFor(self: EntitySpawnLayout, index: usize) math.Vec2 {
        const col: usize = index % self.cols;
        const row: usize = index / self.cols;
        return .{
            .x = self.origin.x + @as(f32, @floatFromInt(col)) * self.stride,
            .y = self.origin.y + @as(f32, @floatFromInt(row)) * self.stride,
        };
    }
};

fn expectedBenchCollectedRecords(item_count: usize) usize {
    const active_particles = @min(particleCapacity(item_count), @max(item_count / 16, 1));
    return item_count + active_particles;
}

fn syncEntityScopeChunk(data: *DataSystem, entity: EntityId, world: *const WorldSystem, position: math.Vec2) void {
    const movement_index = data.movementBodyDenseIndex(entity) orelse return;
    var scope = data.scopeColumnsSlice();
    const tx = math.worldPosToCell(position.x, world.tile_size, world.width);
    const ty = math.worldPosToCell(position.y, world.tile_size, world.height);
    scope.chunk_x[movement_index] = @intCast(tx / world.chunk_size_tiles);
    scope.chunk_y[movement_index] = @intCast(ty / world.chunk_size_tiles);
}

fn entitySpawnLayout(item_count: usize) EntitySpawnLayout {
    const cols: usize = 64;
    const stride: f32 = 20;
    const max_entity_extent: f32 = 20;
    const margin: f32 = stride;
    const rows = @divCeil(item_count, cols);
    const width = @as(f32, @floatFromInt(cols)) * stride + max_entity_extent + margin;
    const height = @as(f32, @floatFromInt(rows)) * stride + max_entity_extent + margin;
    return .{
        .cols = cols,
        .stride = stride,
        .origin = .{ .x = margin, .y = margin },
        .width = width,
        .height = height,
    };
}

fn cameraWorldRect(world_width_px: f32, world_height_px: f32) sprite_batch.Rect {
    return .{
        .x = (world_width_px - bench_viewport_w) * 0.5,
        .y = (world_height_px - bench_viewport_h) * 0.5,
        .w = bench_viewport_w,
        .h = bench_viewport_h,
    };
}

fn benchmarkEntityDepth(index: usize) WorldDepth {
    const depths = [_]WorldDepth{ .actor, .obstacle, .effect, .marker, .floor };
    return depths[index % depths.len];
}

fn benchmarkSparseDepth(index: usize) WorldDepth {
    const depths = [_]WorldDepth{ .obstacle, .effect, .marker, .floor };
    return depths[index % depths.len];
}

fn benchmarkParticleDepth(index: usize) WorldDepth {
    const depths = [_]WorldDepth{ .effect, .marker, .actor };
    return depths[index % depths.len];
}

fn writeRenderGamePrepWorkload(writer: *std.Io.Writer, stats: suite.RunStats, _: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("vertices={} sprites={} skipped={} merged_groups={} sparse={} dynamic_records={} static_groups={} merged_tilemap_groups={}", .{
        stats.candidate_pairs,
        stats.output_count,
        stats.deferred_count,
        stats.sample_count,
        stats.render_game_prep_sparse_submitted,
        stats.render_game_prep_dynamic_records,
        stats.render_game_prep_static_groups,
        stats.render_game_prep_merged_tilemap_groups,
    });
    const phases = stats.render_game_prep_phases orelse return;
    try writer.print(" phases entity_collect={f} merge={f} snapshot={f} vertex_emit={f}", .{ suite.formatDuration(phases.entity_collect_ns), suite.formatDuration(phases.merge_ns), suite.formatDuration(phases.snapshot_ns), suite.formatDuration(phases.vertex_emit_ns) });
}

// The off-view group's fixed level side in tiles, in-view rows (a 32 x 32 grid over the
// camera rect), and particles inside the camera rect.
const offview_level_side: u16 = 1024;
const offview_grid_side: usize = 32;
const offview_visible_rows: usize = offview_grid_side * offview_grid_side;
const offview_particles: usize = 64;
const offview_body_size: f32 = 14;

const offview_item_counts = [_]usize{ 4_096, 32_768, 262_144 };

const OffviewFixture = struct {
    data: DataSystem,
    particles: ParticleSystem,
    world: WorldSystem,
    scene_prep: render_prep.DynamicScenePrep,
    runtime_assets: RuntimeAssets,
    player_entity: EntityId = undefined,

    fn deinit(self: *OffviewFixture) void {
        self.scene_prep.deinit();
        self.world.deinit();
        self.particles.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    fn scene(self: *OffviewFixture) render_prep.GameplayScene {
        return .{
            .data = &self.data,
            .world = &self.world,
            .player_entity = self.player_entity,
            .player_level = 0,
            .particles = &self.particles,
            .overscan_chunks = world_overscan_chunks,
        };
    }
};

fn addOffviewRow(fixture: *OffviewFixture, position: math.Vec2) !EntityId {
    const entity = try fixture.data.createEntity();
    try fixture.data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try fixture.data.setPrimitiveVisual(entity, .{
        .size = .{ .x = offview_body_size, .y = offview_body_size },
        .color = fixtures.tintFor(entity.index),
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    });
    try fixture.data.setSimulationMetadata(entity, .{ .chunk = fixture.world.chunkCoordForWorldPos(position.x, position.y) });
    return entity;
}

// The empty fixture: one walkable level of `offview_level_side`, no rows yet.
fn initOffviewFixture(allocator: std.mem.Allocator, io: std.Io) !OffviewFixture {
    var particles = try ParticleSystem.init(allocator, .{ .capacity = offview_particles });
    errdefer particles.deinit();
    var tileset = try fixtures.loadTilesetMeta(allocator, io);
    defer tileset.deinit();
    const world = try fixtures.buildBandedWorld(allocator, &tileset, offview_level_side, 1, "grass", "grass");
    return .{
        .data = DataSystem.init(allocator),
        .particles = particles,
        .world = world,
        .scene_prep = render_prep.DynamicScenePrep.init(allocator),
        .runtime_assets = RuntimeAssets.init(allocator),
    };
}

// Whether `position` lies in the visible chunk region.
fn inVisibleChunks(world: *const WorldSystem, position: math.Vec2) bool {
    const region = world.visibleChunkRegion() orelse return false;
    return region.containsChunk(world.chunkCoordForWorldPos(position.x, position.y));
}

fn runOffviewCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    std.debug.assert(!case.usesThreadSystem());
    var fixture = try initOffviewFixture(allocator, io);
    defer fixture.deinit();

    const world_px = fixture.world.worldWidthPixels();
    const camera_rect = cameraWorldRect(world_px, world_px);
    try fixture.world.setVisibleChunksForWorldRect(camera_rect, world_overscan_chunks, 0);
    const visible = render_prep.VisibleWorldRect.fromCameraRect(camera_rect, world_overscan_chunks, fixture.world.chunk_size_tiles, fixture.world.tile_size);

    // In view: a grid over the camera rect; the first row is the player.
    const pitch_x = camera_rect.w / @as(f32, @floatFromInt(offview_grid_side));
    const pitch_y = camera_rect.h / @as(f32, @floatFromInt(offview_grid_side));
    for (0..offview_visible_rows) |index| {
        const entity = try addOffviewRow(&fixture, .{
            .x = camera_rect.x + @as(f32, @floatFromInt(index % offview_grid_side)) * pitch_x,
            .y = camera_rect.y + @as(f32, @floatFromInt(index / offview_grid_side)) * pitch_y,
        });
        if (index == 0) fixture.player_entity = entity;
    }
    // Off view: a uniform grid over the level, cells in the visible chunks left out,
    // widened until it holds `item_count` rows.
    var side = suite.ceilSqrt(item_count);
    const offview_cells = while (true) : (side += 1) {
        const pitch = world_px / @as(f32, @floatFromInt(side));
        var outside: usize = 0;
        for (0..side * side) |cell| {
            const position = math.Vec2{ .x = (@as(f32, @floatFromInt(cell % side)) + 0.5) * pitch, .y = (@as(f32, @floatFromInt(cell / side)) + 0.5) * pitch };
            if (!inVisibleChunks(&fixture.world, position)) outside += 1;
        }
        if (outside >= item_count) break side;
    };
    const offview_pitch = world_px / @as(f32, @floatFromInt(offview_cells));
    var placed: usize = 0;
    for (0..offview_cells * offview_cells) |cell| {
        if (placed == item_count) break;
        const position = math.Vec2{ .x = (@as(f32, @floatFromInt(cell % offview_cells)) + 0.5) * offview_pitch, .y = (@as(f32, @floatFromInt(cell / offview_cells)) + 0.5) * offview_pitch };
        if (inVisibleChunks(&fixture.world, position)) continue;
        _ = try addOffviewRow(&fixture, position);
        placed += 1;
    }
    std.debug.assert(placed == item_count);
    for (0..offview_particles) |index| {
        const emitted = fixture.particles.emit(.{
            .position = .{ .x = camera_rect.x + @as(f32, @floatFromInt(index)) * pitch_x * 0.5, .y = camera_rect.y + camera_rect.h * 0.5 },
            .start_size = 4,
            .lifetime = 1_000_000,
        });
        std.debug.assert(emitted);
    }
    try render_prep.ensureScenePrepCapacity(&fixture.scene_prep, fixture.scene());
    const expected_records = offview_visible_rows + fixture.particles.activeCount();

    for (0..options.warmup_iterations) |_| try collectOffview(&fixture, visible, expected_records);
    var accumulator = suite.StatsAccumulator.init(item_count);
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        try collectOffview(&fixture, visible, expected_records);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), .{});
    }
    var stats = accumulator.finish();
    stats.output_count = fixture.scene_prep.records.items.len;
    stats.sample_count = offview_visible_rows;
    stats.render_capacities = .{
        .record_capacity = render_prep.dynamicRecordCapacity(fixture.scene()),
        .command_capacity = render_prep.spriteCommandCapacity(fixture.scene()),
    };
    return stats;
}

fn collectOffview(fixture: *OffviewFixture, visible: render_prep.VisibleWorldRect, expected_records: usize) !void {
    try render_prep.collectDynamicRecords(&fixture.scene_prep, fixture.scene(), visible, &fixture.runtime_assets, 1.0);
    std.debug.assert(fixture.scene_prep.records.items.len == expected_records);
}

fn writeOffviewWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("in_view={} collected={}", .{ stats.sample_count, stats.output_count });
    if (view == .summary) return;
    const capacities = stats.render_capacities orelse return;
    try writer.print(" record_capacity={} command_capacity={}", .{ capacities.record_capacity, capacities.command_capacity });
}
