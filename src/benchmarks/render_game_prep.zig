// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Extended game render-prep benchmark (R29/R32): dynamic record collection,
//! depth-bucket sparse/dynamic emit, sprite-batch snapshot/vertex prep, and
//! realistic static+dynamic `mergeDrawList` group counts. CPU-only; no SDL_GPU.

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const manifest = @import("../assets/manifest.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const config = @import("../config.zig");
const math = @import("../core/math.zig");
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const DataSystem = @import("../game/data_system.zig").DataSystem;
const EntityId = @import("../game/data_system.zig").EntityId;
const ParticleSystem = @import("../game/systems/particle.zig").ParticleSystem;
const render_depth = @import("../game/render_depth.zig");
const render_prep = @import("../game/render_prep.zig");
const WorldDepth = render_depth.WorldDepth;
const world_system = @import("../game/world_system.zig");
const WorldSystem = world_system.WorldSystem;
const TileId = world_system.TileId;
const Renderer = @import("../render/renderer.zig");
const mergeDrawList = Renderer.mergeDrawList;
const resources = @import("../render/resources.zig");
const sprite_batch = @import("../render/sprite_batch.zig");
const suite = @import("suite.zig");

const render_game_prep_range_alignment_items: usize = 1;
const world_overscan_chunks: u16 = 1;
/// Viewport used for world chunk visibility during sparse-layer emit only.
const bench_viewport_w: f32 = 800;
const bench_viewport_h: f32 = 450;
const static_sprite_group_count: usize = 1;
/// Slice 36 collapsed `submitStaticDenseGeometry`'s per-layer draws into at
/// most `Renderer.k_max_dense_composite_draws` interleave-partitioned
/// composite draws; this fixture has no sparse/entity content at non-active
/// levels, so it always hits the common single-bucket case, i.e. exactly one
/// retained `.tilemap` group regardless of dense window depth.
const tilemap_group_count: usize = 1;
const max_static_group_count: usize = tilemap_group_count + static_sprite_group_count;
/// Mid-depth play level for dense render-window bench variants (Slice 23B).
const bench_mid_player_level: u16 = 40;

const FixtureConfig = struct {
    player_level: u16 = 0,

    fn staticGroupCount(self: FixtureConfig) usize {
        _ = self;
        return tilemap_group_count + static_sprite_group_count;
    }
};

const default_fixture_config = FixtureConfig{};

pub const group = suite.BenchmarkGroup{
    .name = "render-game-prep",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

pub const dense_surface_group = suite.BenchmarkGroup{
    .name = "render-game-prep-dense-surface",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runDenseSurfaceCase,
};

pub const dense_deep_group = suite.BenchmarkGroup{
    .name = "render-game-prep-dense-deep",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runDenseDeepCase,
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

const TextureSlot = struct {
    id: sprite_batch.TextureId,
    desc: resources.TextureDesc,
    alive: bool = true,
};

const TextureTable = struct {
    slots: []const TextureSlot,

    fn resolver(self: *const TextureTable) sprite_batch.TextureResolver {
        return .{
            .context = self,
            .resolve = resolve,
        };
    }

    fn resolve(context: *const anyopaque, id: sprite_batch.TextureId) ?resources.TextureDesc {
        const self: *const TextureTable = @ptrCast(@alignCast(context));
        if (!id.isValid()) return null;
        for (self.slots) |slot| {
            if (slot.alive and slot.id.matches(id.index, id.generation)) return slot.desc;
        }
        return null;
    }
};

const Fixture = struct {
    data: DataSystem,
    particles: ParticleSystem,
    tileset_meta: world_tileset_meta.WorldTilesetMeta,
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
        self.tileset_meta.deinit();
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

pub fn runDenseSurfaceCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    return runCaseWithConfig(allocator, io, options, case, item_count, .{ .player_level = 0 });
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

    const slots = [_]TextureSlot{
        .{ .id = textureId(0, 1), .desc = .{ .width = 64, .height = 64 } },
        .{ .id = textureId(1, 1), .desc = .{ .width = 128, .height = 32 } },
        .{ .id = textureId(2, 1), .desc = .{ .width = 32, .height = 128 } },
        .{ .id = textureId(3, 1), .desc = .{ .width = 16, .height = 16 } },
        .{ .id = textureId(4, 1), .desc = .{ .width = 8, .height = 8 }, .alive = false },
    };
    const table = TextureTable{ .slots = &slots };

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

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    if (suite.adaptiveTunerForCase(case, render_game_prep_range_alignment_items)) |tuner| {
        batch.adaptive_tuner = tuner;
    }

    for (0..options.warmup_iterations) |_| {
        _ = try runMeasuredOnce(
            io,
            fixture,
            &batch,
            &draw_list,
            table.resolver(),
            if (threads) |*thread_system| thread_system else null,
            case,
            allocator,
        );
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        while (!batch.adaptive_tuner.isSettled() and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runMeasuredOnce(
                io,
                fixture,
                &batch,
                &draw_list,
                table.resolver(),
                if (threads) |*thread_system| thread_system else null,
                case,
                allocator,
            );
        }
    }
    const settled_before_measurement = if (case.adaptive) batch.adaptive_tuner.isSettled() else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var phase_accumulator = PhaseAccumulator{};
    var last_prep = sprite_batch.SpritePrepStats{};
    var last_sparse_submitted: usize = 0;
    var last_merged_groups: usize = 0;
    var last_merged_tilemap_groups: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const measured = try runMeasuredOnce(
            io,
            fixture,
            &batch,
            &draw_list,
            table.resolver(),
            if (threads) |*thread_system| thread_system else null,
            case,
            allocator,
        );
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), measured.stats.batch);
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
        stats.work_tuning = suite.workTuningSummary(batch.adaptive_tuner.report(), settled_before_measurement);
    }
    return stats;
}

const MeasuredGamePrep = struct {
    stats: sprite_batch.SpritePrepStats,
    phases: suite.RenderGamePrepPhaseSummary,
    sparse_submitted: usize,
    merged_group_count: usize,
    merged_tilemap_group_count: usize,
};

const PhaseAccumulator = struct {
    entity_collect_ns: u128 = 0,
    merge_ns: u128 = 0,
    snapshot_ns: u128 = 0,
    vertex_emit_ns: u128 = 0,

    fn record(self: *PhaseAccumulator, phases: suite.RenderGamePrepPhaseSummary) void {
        self.entity_collect_ns += phases.entity_collect_ns;
        self.merge_ns += phases.merge_ns;
        self.snapshot_ns += phases.snapshot_ns;
        self.vertex_emit_ns += phases.vertex_emit_ns;
    }

    fn finish(self: PhaseAccumulator, iterations: usize) suite.RenderGamePrepPhaseSummary {
        if (iterations == 0) return .{};
        const count: u128 = iterations;
        return .{
            .entity_collect_ns = u128ToU64Saturated(self.entity_collect_ns / count),
            .merge_ns = u128ToU64Saturated(self.merge_ns / count),
            .snapshot_ns = u128ToU64Saturated(self.snapshot_ns / count),
            .vertex_emit_ns = u128ToU64Saturated(self.vertex_emit_ns / count),
        };
    }
};

fn runMeasuredOnce(
    io: std.Io,
    fixture: *Fixture,
    batch: *sprite_batch.SpriteBatch,
    draw_list: *std.ArrayList(sprite_batch.DrawGroup),
    resolver: sprite_batch.TextureResolver,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
    allocator: std.mem.Allocator,
) !MeasuredGamePrep {
    batch.beginFrame();

    const collect_start_ns = suite.nowNs(io);
    try collectProductionDynamicRecords(fixture);
    setBenchSparseEmitChunkVisibility(fixture);
    const sparse_submitted = try emitLayeredCommands(fixture, batch);
    const collect_end_ns = suite.nowNs(io);

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

    return .{
        .stats = stats,
        .sparse_submitted = sparse_submitted,
        .merged_group_count = merged_group_count,
        .merged_tilemap_group_count = merged_tilemap_group_count,
        .phases = .{
            .entity_collect_ns = suite.elapsedNs(collect_start_ns, collect_end_ns),
            .merge_ns = suite.elapsedNs(merge_start_ns, merge_end_ns),
            .snapshot_ns = suite.elapsedNs(snapshot_start_ns, snapshot_end_ns),
            .vertex_emit_ns = suite.elapsedNs(vertex_start_ns, vertex_end_ns),
        },
    };
}

fn emitVertices(
    batch: *sprite_batch.SpriteBatch,
    thread_system: ?*ThreadSystem,
    case: suite.BenchmarkCase,
) BatchStats {
    if (!case.usesThreadSystem()) {
        return batch.emitVerticesAssumeCapacity(null, .{ .adaptive = false });
    }

    return batch.emitVerticesAssumeCapacity(thread_system.?, .{
        .items_per_range = benchmarkItemsPerRange(case),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    });
}

fn benchmarkItemsPerRange(case: suite.BenchmarkCase) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(render_game_prep_range_alignment_items) orelse
        suite.alignItemCount(suite.default_items_per_range, render_game_prep_range_alignment_items);
}

fn collectProductionDynamicRecords(fixture: *Fixture) !void {
    // Full-world visibility is an upper-bound ceiling for entity_collect_ns, not
    // the production camera/chunk/AABB cull path.
    setBenchCollectChunkVisibility(fixture);
    const visible = benchCollectVisibleRect(fixture.world_width_px, fixture.world_height_px);
    try render_prep.collectDynamicRecords(
        &fixture.scene_prep,
        fixture.gameplayScene(),
        visible,
        &fixture.runtime_assets,
        1.0,
    );
    fixture.last_collected_records = fixture.scene_prep.orderedRecords().len;
    std.debug.assert(fixture.last_collected_records == expectedBenchCollectedRecords(fixture.item_count));
}

fn setBenchCollectChunkVisibility(fixture: *Fixture) void {
    fixture.world.setVisibleChunksForWorldRect(.{
        .x = 0,
        .y = 0,
        .w = fixture.world_width_px,
        .h = fixture.world_height_px,
    }, 0);
}

fn setBenchSparseEmitChunkVisibility(fixture: *Fixture) void {
    const camera_rect = cameraWorldRect(fixture.world_width_px, fixture.world_height_px);
    fixture.world.setVisibleChunksForWorldRect(camera_rect, world_overscan_chunks);
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
    try fixture.world.ensureRenderDepthIndex();
    var sparse_submitted: usize = 0;
    var sparse_depth = fixture.world.firstVisibleSparseDepth();
    var dynamic_span_index: usize = 0;
    var dynamic_depth = nextDynamicDepthSpan(&fixture.scene_prep, &dynamic_span_index);
    while (sparse_depth != null or dynamic_depth != null) {
        if (sparse_depth) |depth| {
            if (dynamic_depth == null or depth <= dynamic_depth.?) {
                sparse_submitted += try fixture.world.submitVisibleSparseSprites(batch, fixture.tile_texture, depth);
                sparse_depth = fixture.world.nextVisibleSparseDepthAfter(depth);
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
    const sorted_indices = prep.sortedRecordIndices();
    const records = prep.orderedRecords();
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

/// How far `initFixture` got building `Fixture`'s heap-owning fields, in
/// construction order. Backs the single consolidated `errdefer` in
/// `initFixture` that unwinds everything built so far on any later failure.
const InitStage = enum(u8) { scene_prep, tileset_meta, world };

fn initFixture(
    fixture: *Fixture,
    allocator: std.mem.Allocator,
    io: std.Io,
    item_count: usize,
    fixture_config: FixtureConfig,
) !void {
    const sparse_tile_count = sparseTileCount(item_count);
    const particle_capacity = particleCapacity(item_count);
    const tile_texture = textureId(1, 1);

    fixture.* = .{
        .item_count = item_count,
        .data = DataSystem.init(allocator),
        .particles = try ParticleSystem.init(allocator, .{ .capacity = particle_capacity }),
        .tileset_meta = undefined,
        .world = undefined,
        .scene_prep = render_prep.DynamicScenePrep.init(allocator),
        .player_entity = undefined,
        .runtime_assets = RuntimeAssets.init(allocator),
        .static_groups = undefined,
        .static_group_count = 0,
        .player_level = fixture_config.player_level,
        .tile_texture = tile_texture,
        .white_texture = textureId(0, 1),
        .dynamic_record_capacity = 0,
        .sparse_tile_count = sparse_tile_count,
    };
    // `tileset_meta`/`world` must be built directly at their final `fixture.*`
    // address rather than a temporary local, because `WorldSystem` retains the
    // `*const WorldTilesetMeta` pointer it's given (`buildCatalog`) for its own
    // lifetime; moving `tileset_meta` after the fact would dangle that pointer.
    // `stage` tracks how far construction got so this single `errdefer` is the
    // one place responsible for unwinding everything built so far, in reverse
    // init order — adding a future heap-owning field only needs one new
    // `InitStage` variant, one line here, and one `stage = .field;` below,
    // instead of a fresh standalone `errdefer` that must be placed exactly right.
    // `data`/`particles`/`scene_prep` are all validly constructed the instant
    // the literal above finishes (a failing `try` inside it never reaches this
    // point), so `stage` starts past all three.
    var stage: InitStage = .scene_prep;
    errdefer {
        if (@intFromEnum(stage) >= @intFromEnum(InitStage.world)) fixture.world.deinit();
        if (@intFromEnum(stage) >= @intFromEnum(InitStage.tileset_meta)) fixture.tileset_meta.deinit();
        fixture.scene_prep.deinit();
        fixture.particles.deinit();
        fixture.data.deinit();
    }

    fixture.static_group_count = benchStaticGroups(tile_texture, fixture_config, &fixture.static_groups);

    const asset_store = AssetStore.init(allocator, io, "assets");
    fixture.tileset_meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    stage = .tileset_meta;

    const tile_size_px = fixture.tileset_meta.tileSize();
    const entity_layout = entitySpawnLayout(item_count);
    const sparse_grid_side = ceilSqrt(sparse_tile_count);
    const sparse_world_tiles = @max(@as(u16, @intCast(sparse_grid_side * 2 + 8)), 64);
    const sparse_world_px = @as(f32, @floatFromInt(sparse_world_tiles)) * tile_size_px;
    const world_width_px = @max(sparse_world_px, entity_layout.width);
    const world_height_px = @max(sparse_world_px, entity_layout.height);
    fixture.world = try WorldSystem.initDemoFromMeta(allocator, &fixture.tileset_meta, world_width_px, world_height_px);
    stage = .world;

    // Render-prep's dense-window entity cull bounds the deep submit limit by
    // the world's real level count (WorldSystem.levelInWindow), so a deep
    // fixture_config.player_level needs that many real (dense-layer-empty)
    // levels to exist, or every entity placed at that level would be culled
    // as beyond the window even though it matches player_level exactly.
    var level_index: u16 = 1;
    while (level_index <= fixture_config.player_level) : (level_index += 1) {
        _ = try fixture.world.addLevel(-@as(i32, @intCast(level_index)) * world_system.level_z_step);
    }

    const deco = try requireTile(&fixture.tileset_meta, "deco_0");
    const level: u16 = 0;

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
            .color = tintFor(index),
            .depth = benchmarkEntityDepth(index),
            .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        });
        // Slice 25E render-prep culls non-player entities to their own world
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

/// Builds the static draw groups `submitStaticDenseGeometry` produces post
/// Slice 36: one retained `.tilemap` composite draw ordered at the window's
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
        .tile_data = @enumFromInt(0),
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
    const render_window = world_system.DenseLayerRenderWindow{};
    if (player_level > 0 and render_window.ceiling_when_underground) {
        return player_level - 1;
    }
    return player_level;
}

fn benchDenseFloorDepth(world_level: u16) i32 {
    const base_z: i32 = -@as(i32, @intCast(world_level)) * world_system.level_z_step;
    return render_depth.worldZWithOffset(base_z, .floor);
}

fn benchAccentSpriteDepth(fixture_config: FixtureConfig) i32 {
    const top_level = benchWindowStartLevel(fixture_config.player_level);
    return benchDenseFloorDepth(top_level) + render_depth.worldZ(.actor) - render_depth.worldZ(.floor);
}

fn requireTile(meta: *const world_tileset_meta.WorldTilesetMeta, name: []const u8) !TileId {
    return (meta.tileByName(name) orelse return error.TileNotFound).id;
}

fn sparseTileCount(item_count: usize) usize {
    return @max(@min(item_count / 4, 12_288), 64);
}

fn particleCapacity(item_count: usize) usize {
    return @max(item_count / 8, 64);
}

fn ceilSqrt(value: usize) usize {
    var side: usize = 1;
    while (side * side < value) side += 1;
    return side;
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
    const rows = (item_count + cols - 1) / cols;
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

fn tintFor(index: usize) config.Color {
    return .{
        .r = 0.45 + @as(f32, @floatFromInt(index % 5)) * 0.08,
        .g = 0.55 + @as(f32, @floatFromInt(index % 7)) * 0.05,
        .b = 0.65 + @as(f32, @floatFromInt(index % 3)) * 0.09,
        .a = 1,
    };
}

fn textureId(index: u32, generation: u32) sprite_batch.TextureId {
    return sprite_batch.TextureId.init(index, generation) catch unreachable;
}

fn u128ToU64Saturated(value: u128) u64 {
    return if (value > std.math.maxInt(u64)) std.math.maxInt(u64) else @intCast(value);
}
