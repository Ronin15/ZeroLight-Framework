// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const Color = @import("../config.zig").Color;
const math = @import("../core/math.zig");
const DataSystem = @import("data_system.zig").DataSystem;
const ConstAssetReferenceSlice = @import("data_system.zig").ConstAssetReferenceSlice;
const ConstMovementBodySlice = @import("data_system.zig").ConstMovementBodySlice;
const ConstScopeColumnsSlice = @import("data_system.zig").ConstScopeColumnsSlice;
const ConstPrimitiveVisualSlice = @import("data_system.zig").ConstPrimitiveVisualSlice;
const EntityId = @import("data_system.zig").EntityId;
const Facing = @import("data_system.zig").Facing;
const AssetReference = @import("data_system.zig").AssetReference;
const Rect = @import("../render/renderer.zig").Rect;
const RenderOrder = @import("../render/renderer.zig").RenderOrder;
const Renderer = @import("../render/renderer.zig").Renderer;
const Sprite = @import("../render/renderer.zig").Sprite;
const TextureId = @import("../render/resources.zig").TextureId;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const AssetStore = @import("../assets/assets.zig").AssetStore;
const sprite_atlas_meta = @import("../assets/sprite_atlas_meta.zig");
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");
const WorldTilesetMeta = @import("../assets/world_tileset_meta.zig").WorldTilesetMeta;
const manifest = @import("../assets/manifest.zig");
const WorldDepth = @import("render_depth.zig").WorldDepth;
const render_depth = @import("render_depth.zig");
const WorldSystem = @import("world_system.zig").WorldSystem;
const level_z_step = @import("world_system.zig").level_z_step;
const k_max_dense_submit_stack_cap = @import("world_system.zig").k_max_dense_submit_stack_cap;
// Test-only: constructs a headless CPU-only SpriteBatch/DrawGroup fixture for a
// Renderer built without a live GPU device. Mirrors world_system.zig's existing
// direct sprite_batch.zig import for the same CPU-only-parity reason.
const sprite_batch = @import("../render/sprite_batch.zig");
const mergeDrawList = @import("../render/renderer.zig").mergeDrawList;
const SimulationTier = @import("simulation_scope.zig").SimulationTier;
const ActiveRegion = @import("simulation_scope.zig").ActiveRegion;
const ParticleSystem = @import("systems/particle.zig").ParticleSystem;
const ConstParticleSlice = @import("systems/particle.zig").ConstParticleSlice;

pub const PreparedDraw = union(enum) {
    sprite: Sprite,
    rect: RectDraw,

    pub fn depth(self: PreparedDraw) i32 {
        return switch (self) {
            .sprite => |sprite| sprite.order.depth,
            .rect => |rect| rect.order.depth,
        };
    }

    pub fn renderOrder(self: PreparedDraw) RenderOrder {
        return switch (self) {
            .sprite => |sprite| sprite.order,
            .rect => |rect| rect.order,
        };
    }
};

pub const RectDraw = struct {
    rect: Rect,
    color: Color,
    order: RenderOrder,
};

/// Half-open world-space rectangle used for camera visibility culling. Matches
/// the chunk overscan applied by `WorldSystem.setVisibleChunksForWorldRect`.
pub const VisibleWorldRect = struct {
    min_x: f32,
    min_y: f32,
    max_x: f32,
    max_y: f32,

    pub fn fromCameraRect(camera_rect: Rect, overscan_chunks: u16, chunk_size_tiles: u16, tile_size: f32) VisibleWorldRect {
        const overscan_pixels = @as(f32, @floatFromInt(@as(u32, overscan_chunks) * @as(u32, chunk_size_tiles))) * tile_size;
        return .{
            .min_x = camera_rect.x - overscan_pixels,
            .min_y = camera_rect.y - overscan_pixels,
            .max_x = camera_rect.x + camera_rect.w + overscan_pixels,
            .max_y = camera_rect.y + camera_rect.h + overscan_pixels,
        };
    }

    pub fn containsPoint(self: VisibleWorldRect, position: math.Vec2) bool {
        return position.x >= self.min_x and position.x < self.max_x and
            position.y >= self.min_y and position.y < self.max_y;
    }

    pub fn overlapsAabb(self: VisibleWorldRect, x: f32, y: f32, width: f32, height: f32) bool {
        return self.min_x < x + width and self.max_x > x and
            self.min_y < y + height and self.max_y > y;
    }
};

pub fn submitPreparedDraw(renderer: *Renderer, draw: PreparedDraw) !void {
    switch (draw) {
        .sprite => |sprite| try renderer.submitOrderedSprite(sprite),
        .rect => |rect| try renderer.submitOrderedRectInSpace(rect.rect, rect.color, rect.order, .world),
    }
}

fn assetReferenceAt(assets: ConstAssetReferenceSlice, index: usize) AssetReference {
    return .{
        .sprite = assets.sprite_ids[index],
        .atlas_entry_id = assets.atlas_entry_ids[index],
    };
}

fn preparePrimitiveVisualRectSoA(
    visuals: ConstPrimitiveVisualSlice,
    visual_index: usize,
    render_x: f32,
    render_y: f32,
    record_depth: i32,
) PreparedDraw {
    return .{ .rect = .{
        .rect = .{
            .x = render_x,
            .y = render_y,
            .w = visuals.size_x[visual_index],
            .h = visuals.size_y[visual_index],
        },
        .color = .{
            .r = visuals.color_r[visual_index],
            .g = visuals.color_g[visual_index],
            .b = visuals.color_b[visual_index],
            .a = visuals.color_a[visual_index],
        },
        .order = RenderOrder.world(record_depth),
    } };
}

fn preparePrimitiveVisualSoA(
    movement: ConstMovementBodySlice,
    visuals: ConstPrimitiveVisualSlice,
    movement_index: usize,
    visual_index: usize,
    render_x: f32,
    render_y: f32,
    asset_ref: AssetReference,
    runtime_assets: *const RuntimeAssets,
) PreparedDraw {
    const dest = Rect{
        .x = render_x,
        .y = render_y,
        .w = visuals.size_x[visual_index],
        .h = visuals.size_y[visual_index],
    };
    const depth_band: WorldDepth = @enumFromInt(visuals.depth_values[visual_index]);
    const order = worldOrder(movement.position_z[movement_index], depth_band);
    const color = Color{
        .r = visuals.color_r[visual_index],
        .g = visuals.color_g[visual_index],
        .b = visuals.color_b[visual_index],
        .a = visuals.color_a[visual_index],
    };

    if (runtime_assets.sprite(asset_ref.sprite)) |sprite| {
        const source = sourceRectForAsset(runtime_assets, asset_ref, sprite.source_rect) orelse if (asset_ref.hasAtlasEntry())
            null
        else
            sprite.source_rect;
        if (!asset_ref.hasAtlasEntry() or source != null) {
            return .{ .sprite = .{
                .texture = sprite.texture,
                .source = source,
                .dest = dest,
                .tint = color,
                .order = order,
            } };
        }
    }

    return .{ .rect = .{ .rect = dest, .color = color, .order = order } };
}

pub fn sourceRectForAsset(
    runtime_assets: *const RuntimeAssets,
    asset_ref: AssetReference,
    sprite_source: ?Rect,
) ?Rect {
    if (!asset_ref.hasAtlasEntry()) return sprite_source;
    const meta = runtime_assets.spriteAtlasMeta(asset_ref.sprite) orelse return null;
    const source = meta.sourceRectForId(asset_ref.atlas_entry_id) orelse return null;
    return rectFromManifest(source);
}

fn rectFromManifest(source: manifest.SourceRect) Rect {
    return .{
        .x = source.x,
        .y = source.y,
        .w = source.w,
        .h = source.h,
    };
}

// Init-time hard-error sibling of `sourceRectForAsset`'s render-time soft
// fallback: every atlas-backed asset reference must resolve, or init fails loud.
pub fn validateAtlasReferences(data: *const DataSystem, runtime_assets: *const RuntimeAssets) !void {
    const asset_refs = data.assetReferenceSliceConst();
    for (asset_refs.sprite_ids, asset_refs.atlas_entry_ids) |sprite_id, atlas_entry_id| {
        try validateAtlasReference(.{ .sprite = sprite_id, .atlas_entry_id = atlas_entry_id }, runtime_assets);
    }
}

fn validateAtlasReference(asset_ref: AssetReference, runtime_assets: *const RuntimeAssets) !void {
    if (!asset_ref.hasAtlasEntry()) return;
    const meta = runtime_assets.spriteAtlasMeta(asset_ref.sprite) orelse return error.SpriteAtlasMetadataUnavailable;
    if (meta.sourceRectForId(asset_ref.atlas_entry_id) == null) return error.InvalidSpriteAtlasEntry;
}

pub fn worldOrder(base_z: i32, depth: WorldDepth) RenderOrder {
    return RenderOrder.world(render_depth.worldZWithOffset(base_z, depth));
}

/// Read-only gameplay inputs for one layered world render frame.
pub const GameplayScene = struct {
    data: *const DataSystem,
    world: *WorldSystem,
    player_entity: EntityId,
    player_level: u16,
    particles: *const ParticleSystem,
    overscan_chunks: u16,
};

/// Reusable dynamic-record storage for a gameplay scene. Owned by the state
/// instance for grow-only capacity; all algorithms live in this module.
pub const DynamicScenePrep = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(DynamicRenderRecord) = .empty,
    sort_indices: std.ArrayList(usize) = .empty,
    depth_spans: std.ArrayList(DynamicDepthRange) = .empty,
    next_sequence: usize = 0,

    pub fn init(allocator: std.mem.Allocator) DynamicScenePrep {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DynamicScenePrep) void {
        self.records.deinit(self.allocator);
        self.sort_indices.deinit(self.allocator);
        self.depth_spans.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn ensureCapacity(self: *DynamicScenePrep, record_capacity: usize) !void {
        try self.records.ensureTotalCapacity(self.allocator, record_capacity);
        try self.sort_indices.ensureTotalCapacity(self.allocator, record_capacity);
        try self.depth_spans.ensureTotalCapacity(self.allocator, record_capacity);
    }

    pub fn orderedRecords(self: *const DynamicScenePrep) []const DynamicRenderRecord {
        return self.records.items;
    }

    pub fn sortedRecordIndices(self: *const DynamicScenePrep) []const usize {
        return self.sort_indices.items;
    }

    pub fn depthSpans(self: *const DynamicScenePrep) []const DynamicDepthRange {
        return self.depth_spans.items;
    }

    fn clearRetainingCapacity(self: *DynamicScenePrep) void {
        self.records.clearRetainingCapacity();
        self.sort_indices.clearRetainingCapacity();
        self.depth_spans.clearRetainingCapacity();
        self.next_sequence = 0;
    }

    fn appendAssumeCapacity(self: *DynamicScenePrep, record: DynamicRenderRecord) void {
        var sequenced = record;
        sequenced.sequence = self.next_sequence;
        self.next_sequence += 1;
        self.records.appendAssumeCapacity(sequenced);
    }

    fn finalizeDepthBuckets(self: *DynamicScenePrep) void {
        self.depth_spans.clearRetainingCapacity();
        self.sort_indices.clearRetainingCapacity();
        const record_count = self.records.items.len;
        if (record_count == 0) return;

        for (0..record_count) |index| {
            self.sort_indices.appendAssumeCapacity(index);
        }

        const records = self.records.items;
        std.mem.sort(usize, self.sort_indices.items, records, sortRecordIndexLessThan);

        var span_start: usize = 0;
        var current_depth = records[self.sort_indices.items[0]].depth;
        for (self.sort_indices.items, 0..) |record_index, sorted_index| {
            const depth = records[record_index].depth;
            if (depth != current_depth) {
                self.depth_spans.appendAssumeCapacity(.{
                    .start = span_start,
                    .end = sorted_index,
                    .depth = current_depth,
                });
                span_start = sorted_index;
                current_depth = depth;
            }
        }
        self.depth_spans.appendAssumeCapacity(.{
            .start = span_start,
            .end = record_count,
            .depth = current_depth,
        });
    }
};

pub const DynamicRenderRecord = struct {
    depth: i32,
    sequence: usize = 0,
    draw: PreparedDraw,
};

pub const DynamicDepthRange = struct {
    start: usize,
    end: usize,
    depth: i32 = 0,
};

pub fn dynamicRecordCapacity(scene: GameplayScene) usize {
    const visual_count = scene.data.primitiveVisualSliceConst().entities.len;
    const player_marker_count: usize = 1;
    return visual_count + player_marker_count + scene.particles.activeCount();
}

/// Peak gameplay sprite commands for the demo state. Stacked UI headroom covers
/// pause/menu rects submitted after gameplay enqueue; `Engine` adds
/// `Renderer.kOverlayCommandHeadroom` for the debug overlay afterward.
pub fn spriteCommandCapacity(scene: GameplayScene) usize {
    const visual_count = scene.data.primitiveVisualSliceConst().entities.len;
    const player_marker_count: usize = 1;
    return scene.world.reserveRenderRecords() +
        visual_count +
        player_marker_count +
        scene.particles.activeCount() +
        Renderer.kStackedStateUiHeadroom;
}

pub fn ensureScenePrepCapacity(prep: *DynamicScenePrep, scene: GameplayScene) !void {
    try prep.ensureCapacity(dynamicRecordCapacity(scene));
}

/// Peak retained static tilemap geometry for the world's dense render window.
/// Grow-only; safe to call each gameplay frame before dense layer submit.
/// Sourced from `maxDenseSubmitDrawCount()` — the worst-case composite-draw
/// bound (`Renderer.k_max_dense_composite_draws`), not the raw in-window layer
/// count — since `submitStaticDenseGeometry` now issues at most one
/// `appendStaticTilemapSpan` per interleave-partitioned bucket rather than one
/// per dense layer.
pub fn staticGeometryCapacity(scene: GameplayScene) struct { vertex_capacity: usize, span_capacity: usize } {
    const span_capacity = scene.world.maxDenseSubmitDrawCount();
    return .{
        .vertex_capacity = span_capacity * 6,
        .span_capacity = span_capacity,
    };
}

pub fn ensureStaticGeometryCapacity(scene: GameplayScene, renderer: *Renderer) !void {
    const capacity = staticGeometryCapacity(scene);
    try renderer.reserveStaticGeometry(capacity.vertex_capacity, capacity.span_capacity);
}

/// Collects visible dynamic draws, then merges sparse world layers and dynamic
/// spans by world z before submitting ordered commands to `Renderer`.
pub fn submitGameplayFrame(
    prep: *DynamicScenePrep,
    scene: GameplayScene,
    renderer: *Renderer,
    runtime_assets: *const RuntimeAssets,
    interpolation_alpha: f32,
    camera_rect: Rect,
) !void {
    try ensureStaticGeometryCapacity(scene, renderer);
    const visible = VisibleWorldRect.fromCameraRect(
        camera_rect,
        scene.overscan_chunks,
        scene.world.chunk_size_tiles,
        scene.world.tile_size,
    );
    try collectDynamicRecords(prep, scene, visible, runtime_assets, interpolation_alpha);
    try submitLayeredWorld(scene, prep, renderer, runtime_assets);
}

pub fn collectDynamicRecords(
    prep: *DynamicScenePrep,
    scene: GameplayScene,
    visible: VisibleWorldRect,
    runtime_assets: *const RuntimeAssets,
    interpolation_alpha: f32,
) !void {
    try ensureScenePrepCapacity(prep, scene);
    prep.clearRetainingCapacity();

    const movement = scene.data.movementBodySliceConst();
    const scope = scene.data.scopeColumnsSliceConst();
    const visuals = scene.data.primitiveVisualSliceConst();
    const assets = scene.data.assetReferenceSliceConst();
    const facings = scene.data.facingSliceConst();
    const visible_chunks = scene.world.visibleChunkRegion();
    const player_entity = scene.player_entity;
    const player_entity_index = player_entity.index;
    const player_entity_generation = player_entity.generation;
    const max_world_level: u16 = scene.world.maxLevelIndex();
    // Movement-body dense rows are the collect anchor: scope columns (tier/chunk)
    // align with movement_index; has_primitive_visual skips movement-only rows
    // before the deferred slot resolve in renderCollectIndicesForMovement.
    for (movement.entities, 0..) |entity, movement_index| {
        const is_player = entity.index == player_entity_index and entity.generation == player_entity_generation;
        if (!is_player) {
            const entity_level = scene.data.worldLevelConst(entity) orelse 0;
            // Window membership (not exact equality) so an entity that fell to a
            // deeper in-window level (e.g. through a dug hole) still renders, at
            // its own real depth — matches the dense-layer window this frame
            // already composites via WorldSystem.collectDenseSubmitLayers.
            if (!scene.world.render_window.levelInWindow(scene.player_level, entity_level, max_world_level)) continue;
        }
        if (!entityVisibleForRenderCollect(movement_index, scope, visible_chunks)) continue;
        if (!movement.has_primitive_visual[movement_index]) continue;

        const collect_indices = scene.data.renderCollectIndicesForMovement(movement_index) orelse continue;
        const visual_index = collect_indices.visual_index;

        const render_x = math.lerp(
            movement.previous_x[movement_index],
            movement.position_x[movement_index],
            interpolation_alpha,
        );
        const render_y = math.lerp(
            movement.previous_y[movement_index],
            movement.position_y[movement_index],
            interpolation_alpha,
        );
        const size_x = visuals.size_x[visual_index];
        const size_y = visuals.size_y[visual_index];
        if (!visible.overlapsAabb(render_x, render_y, size_x, size_y)) continue;

        if (collect_indices.asset_ref_index) |asset_index| {
            const asset_ref = assetReferenceAt(assets, asset_index);
            const prepared = preparePrimitiveVisualSoA(
                movement,
                visuals,
                movement_index,
                visual_index,
                render_x,
                render_y,
                asset_ref,
                runtime_assets,
            );
            prep.appendAssumeCapacity(.{ .depth = prepared.depth(), .draw = prepared });
        } else {
            const depth_band: WorldDepth = @enumFromInt(visuals.depth_values[visual_index]);
            const record_depth = render_depth.worldZWithOffset(movement.position_z[movement_index], depth_band);
            prep.appendAssumeCapacity(.{
                .depth = record_depth,
                .draw = preparePrimitiveVisualRectSoA(
                    visuals,
                    visual_index,
                    render_x,
                    render_y,
                    record_depth,
                ),
            });
        }
        if (is_player) {
            if (collect_indices.facing_index) |facing_index| {
                if (preparePlayerMarkerSoA(
                    movement,
                    visuals,
                    movement_index,
                    visual_index,
                    facings.directions[facing_index],
                    render_x,
                    render_y,
                )) |marker| {
                    prep.appendAssumeCapacity(.{ .depth = marker.depth(), .draw = marker });
                }
            }
        }
    }

    const particles = scene.particles.sliceConst();
    for (0..particles.len()) |index| {
        if (!particles.renderable(index)) continue;
        const render_x = math.lerp(particles.previous_x[index], particles.position_x[index], interpolation_alpha);
        const render_y = math.lerp(particles.previous_y[index], particles.position_y[index], interpolation_alpha);
        const particle_size = particles.size[index];
        const half_size = particle_size * 0.5;
        if (!visible.overlapsAabb(render_x - half_size, render_y - half_size, particle_size, particle_size)) continue;
        const draw = prepareParticleAt(particles, index, render_x, render_y) orelse continue;
        prep.appendAssumeCapacity(.{ .depth = draw.depth(), .draw = draw });
    }
    prep.finalizeDepthBuckets();
}

/// Which stream the layered-world merge walk should drain next. Sparse tiles and
/// dynamic records are each already ascending by depth; this decides the single
/// next step so the merged output stays nondecreasing.
const MergeSource = enum { sparse, dynamic };

/// Pure tie-break for the sparse/dynamic depth merge: sparse wins ties (`depth <=
/// dynamic_depth`), so tile floors composite under same-depth dynamic draws.
/// Shared by `submitLayeredWorld` and covered directly by unit tests below since
/// the caller needs a live `*Renderer` and can't run headlessly.
fn mergeNextSource(sparse_depth: ?i32, dynamic_depth: ?i32) ?MergeSource {
    if (sparse_depth) |depth| {
        if (dynamic_depth == null or depth <= dynamic_depth.?) return .sparse;
        return .dynamic;
    }
    if (dynamic_depth != null) return .dynamic;
    return null;
}

fn submitLayeredWorld(
    scene: GameplayScene,
    prep: *DynamicScenePrep,
    renderer: *Renderer,
    runtime_assets: *const RuntimeAssets,
) !void {
    try scene.world.ensureRenderDepthIndex();

    var interleave_scratch: [k_max_dense_submit_stack_cap]i32 = undefined;
    const interleave_depths = try collectDenseInterleaveDepths(scene, prep, &interleave_scratch);

    try scene.world.submitStaticDenseGeometry(renderer, runtime_assets, scene.player_level, interleave_depths);
    try scene.world.flushDenseTileEdits(renderer);

    var sparse_index: usize = 0;
    var sparse_depth = nextSparseDepth(scene, &sparse_index);
    var dynamic_span_index: usize = 0;
    var dynamic_depth = nextDynamicDepth(prep, &dynamic_span_index);
    while (mergeNextSource(sparse_depth, dynamic_depth)) |source| {
        switch (source) {
            .sparse => {
                const depth = sparse_depth.?;
                try scene.world.submitVisibleSparseAtDepth(renderer, runtime_assets, depth);
                sparse_depth = nextSparseDepth(scene, &sparse_index);
            },
            .dynamic => {
                const dynamic_range = prep.depth_spans.items[dynamic_span_index - 1];
                const sorted_indices = prep.sort_indices.items;
                const records = prep.records.items;
                for (sorted_indices[dynamic_range.start..dynamic_range.end]) |record_index| {
                    try submitPreparedDraw(renderer, records[record_index].draw);
                }
                dynamic_depth = nextDynamicDepth(prep, &dynamic_span_index);
            },
        }
    }
}

/// Gathers this frame's dense-composite-draw cut points: `active_level`'s own
/// actor depth (always included — this is what makes the common case behave
/// exactly like before the dense stack was collapsed to composite draws),
/// every distinct dynamic depth this frame (`prep.depthSpans()`, NOT bounded to
/// `k_max_dense_submit_stack_cap` candidates), and every registered sparse-tile
/// depth anywhere in the world (walked by index via
/// `sparseDepthRangeCount`/`sparseDepthRangeAt`, closing the gap a sparse tile
/// at any in-window level could otherwise fall through — `submitLayeredWorld`
/// walks the same indexed sequence again for the actual merge/submit pass, so
/// this only ever reads the already-computed `sparse_depth_ranges`, never
/// rescans it) — also not bounded, since `WorldSystem.addSparseTile` takes an
/// arbitrary caller-supplied depth.
///
/// `WorldSystem.partitionDenseCompositeBuckets` never needs more than one
/// candidate per **gap** between two adjacent submitted dense layers to place
/// a cut there, and the number of gaps is `submit_count - 1`, hard-bounded by
/// `k_max_dense_submit_stack_cap - 1` regardless of how many raw candidate
/// depths this frame's dynamic/sparse content produces. So candidates are
/// deduplicated by which gap they would cut (`interleaveGapIndex`, matching
/// the partition function's own boundary rule), not by raw depth value —
/// dropping same-gap duplicates costs nothing since only the first
/// representative per gap is ever consulted. Filters to the dense window's own
/// depth span first (a depth outside it, or at/below the deepest submitted
/// layer, cannot cut anything; the span itself is `denseWindowDepthSpan`'s
/// cached value, recomputed only on a real structural/level/window change).
/// `scratch` is a fixed stack buffer sized to the submit-stack cap, so this
/// stays allocation-free every frame; the gap bound proves it can never
/// overflow. Returns the sorted, deduplicated slice
/// `submitStaticDenseGeometry` partitions on.
fn collectDenseInterleaveDepths(
    scene: GameplayScene,
    prep: *const DynamicScenePrep,
    scratch: *[k_max_dense_submit_stack_cap]i32,
) error{TooManyDenseLayers}![]const i32 {
    const span = (try scene.world.denseWindowDepthSpan(scene.player_level)) orelse return scratch[0..0];
    const layer_depths = scene.world.denseWindowLayerDepths();
    var gap_filled: [k_max_dense_interleave_gaps]bool = [_]bool{false} ** k_max_dense_interleave_gaps;
    var count: usize = 0;

    appendInterleaveDepth(scratch, &count, &gap_filled, layer_depths, scene.world.activeLevelActorDepth(scene.player_level), span);
    for (prep.depthSpans()) |range| {
        appendInterleaveDepth(scratch, &count, &gap_filled, layer_depths, range.depth, span);
    }
    for (0..scene.world.sparseDepthRangeCount()) |index| {
        appendInterleaveDepth(scratch, &count, &gap_filled, layer_depths, scene.world.sparseDepthRangeAt(index), span);
    }

    const collected = scratch[0..count];
    std.mem.sort(i32, collected, {}, std.sort.asc(i32));
    return collected;
}

/// Max gaps between adjacent submitted dense layers this frame: one fewer than
/// the submit-stack cap, since a gap sits between two layers.
const k_max_dense_interleave_gaps = k_max_dense_submit_stack_cap - 1;

/// Finds which gap between two adjacent entries of `layer_depths` (ascending,
/// `WorldSystem.denseWindowLayerDepths`) `depth` would cut, mirroring
/// `WorldSystem.partitionDenseCompositeBuckets`'s own boundary rule
/// (`layer_depths[i - 1] < depth <= layer_depths[i]`). Returns null when
/// `depth` cannot cut any boundary — at or below the deepest submitted layer,
/// nothing sits beneath it in-window to sandwich against.
fn interleaveGapIndex(layer_depths: []const i32, depth: i32) ?usize {
    var i: usize = 1;
    while (i < layer_depths.len) : (i += 1) {
        if (depth > layer_depths[i - 1] and depth <= layer_depths[i]) return i - 1;
    }
    return null;
}

/// Advances the sparse-tile merge cursor by index into `sparse_depth_ranges`
/// (ascending, already deduplicated by `ensureRenderDepthIndex`), shared with
/// `collectDenseInterleaveDepths`'s own indexed walk over the same list so
/// neither pass needs `nextVisibleSparseDepthAfter`'s rescan-from-start cursor.
fn nextSparseDepth(scene: GameplayScene, index: *usize) ?i32 {
    if (index.* >= scene.world.sparseDepthRangeCount()) return null;
    const depth = scene.world.sparseDepthRangeAt(index.*);
    index.* += 1;
    return depth;
}

/// Appends `depth` to `scratch[0..count]` once per gap it could cut between
/// two adjacent submitted dense layers (`interleaveGapIndex`). Silently drops
/// `depth` when it falls outside `span` or cannot cut any gap (at/below the
/// deepest submitted layer) — genuinely benign, since neither case can ever
/// place a bucket boundary. Also silently drops a second (or later) candidate
/// for a gap that already has a representative — redundant, not a capacity
/// loss, since `partitionDenseCompositeBuckets` only consults one candidate
/// per gap. `scratch` overflowing is unreachable here: gaps are bounded by
/// `k_max_dense_interleave_gaps`, which is always `<= scratch.len`, so the
/// assert documents a build invariant rather than a runtime condition to
/// degrade around.
fn appendInterleaveDepth(
    scratch: *[k_max_dense_submit_stack_cap]i32,
    count: *usize,
    gap_filled: *[k_max_dense_interleave_gaps]bool,
    layer_depths: []const i32,
    depth: i32,
    span: WorldSystem.DenseWindowDepthSpan,
) void {
    if (depth < span.min or depth > span.max) return;
    const gap_index = interleaveGapIndex(layer_depths, depth) orelse return;
    if (gap_filled[gap_index]) return;
    gap_filled[gap_index] = true;
    std.debug.assert(count.* < scratch.len);
    scratch[count.*] = depth;
    count.* += 1;
}

fn nextDynamicDepth(prep: *const DynamicScenePrep, span_index: *usize) ?i32 {
    if (span_index.* >= prep.depth_spans.items.len) return null;
    const depth = prep.depth_spans.items[span_index.*].depth;
    span_index.* += 1;
    return depth;
}

fn preparePlayerMarkerSoA(
    movement: ConstMovementBodySlice,
    visuals: ConstPrimitiveVisualSlice,
    movement_index: usize,
    visual_index: usize,
    facing: Facing,
    render_x: f32,
    render_y: f32,
) ?PreparedDraw {
    const marker_depth_band: WorldDepth = @enumFromInt(visuals.marker_depth_values[visual_index]);
    const marker_order = worldOrder(movement.position_z[movement_index], marker_depth_band);
    return .{ .rect = .{
        .rect = markerRectAt(
            render_x,
            render_y,
            facing,
            visuals.size_x[visual_index],
            visuals.size_y[visual_index],
            visuals.marker_lengths[visual_index],
            visuals.marker_depths[visual_index],
            visuals.marker_margins[visual_index],
        ),
        .color = .{
            .r = visuals.marker_color_r[visual_index],
            .g = visuals.marker_color_g[visual_index],
            .b = visuals.marker_color_b[visual_index],
            .a = visuals.marker_color_a[visual_index],
        },
        .order = marker_order,
    } };
}

fn prepareParticleAt(particles: ConstParticleSlice, index: usize, render_x: f32, render_y: f32) ?PreparedDraw {
    if (index >= particles.len() or !particles.renderable(index)) return null;
    const size = particles.size[index];
    const half_size = size * 0.5;
    return .{ .rect = .{
        .rect = .{
            .x = render_x - half_size,
            .y = render_y - half_size,
            .w = size,
            .h = size,
        },
        .color = .{
            .r = particles.color_r[index],
            .g = particles.color_g[index],
            .b = particles.color_b[index],
            .a = particles.color_a[index],
        },
        .order = RenderOrder.world(particles.z[index]),
    } };
}

fn markerRectAt(
    position_x: f32,
    position_y: f32,
    facing: Facing,
    size_x: f32,
    size_y: f32,
    marker_length: f32,
    marker_depth: f32,
    marker_margin: f32,
) Rect {
    const centered_x = (size_x - marker_length) * 0.5;
    const centered_y = (size_y - marker_length) * 0.5;

    return switch (facing) {
        .up => .{
            .x = position_x + centered_x,
            .y = position_y + marker_margin,
            .w = marker_length,
            .h = marker_depth,
        },
        .down => .{
            .x = position_x + centered_x,
            .y = position_y + size_y - marker_margin - marker_depth,
            .w = marker_length,
            .h = marker_depth,
        },
        .left => .{
            .x = position_x + marker_margin,
            .y = position_y + centered_y,
            .w = marker_depth,
            .h = marker_length,
        },
        .right => .{
            .x = position_x + size_x - marker_margin - marker_depth,
            .y = position_y + centered_y,
            .w = marker_depth,
            .h = marker_length,
        },
    };
}

/// Camera chunk gate before interpolation and draw prep. Uses the world's render
/// visibility window (same source as sparse tiles). Simulation tier is not consulted
/// here — render visibility is camera policy only; sim LOD lives in the pipeline.
/// Callers must set world visibility before collect; when the window is unset,
/// every entity is skipped. Pixel AABB overlap is applied afterward in the caller.
fn entityVisibleForRenderCollect(
    movement_index: usize,
    scope: ConstScopeColumnsSlice,
    visible_chunks: ?ActiveRegion,
) bool {
    const region = visible_chunks orelse return false;
    return region.containsChunk(.{
        .x = scope.chunk_x[movement_index],
        .y = scope.chunk_y[movement_index],
    });
}

fn sortRecordIndexLessThan(records: []const DynamicRenderRecord, lhs_index: usize, rhs_index: usize) bool {
    const lhs = records[lhs_index];
    const rhs = records[rhs_index];
    if (lhs.depth != rhs.depth) return lhs.depth < rhs.depth;
    return lhs.sequence < rhs.sequence;
}

fn testScopeColumns(chunk_x: []const i32, chunk_y: []const i32, tier: []const SimulationTier) ConstScopeColumnsSlice {
    return .{
        .entities = &.{},
        .tier = tier,
        .chunk_x = chunk_x,
        .chunk_y = chunk_y,
        .level = &.{},
        .stagger_phase = &.{},
        .always_active = &.{},
    };
}

test "render collect chunk gate rejects rows when visibility window is unset" {
    var chunk_x = [_]i32{0};
    var chunk_y = [_]i32{0};
    var tier = [_]SimulationTier{.cognition};
    const scope = testScopeColumns(&chunk_x, &chunk_y, &tier);
    try std.testing.expect(!entityVisibleForRenderCollect(0, scope, null));
}

test "render collect chunk gate uses scope chunk columns only" {
    var chunk_x = [_]i32{ 0, 4 };
    var chunk_y = [_]i32{ 0, 4 };
    var tier = [_]SimulationTier{ .dormant, .cognition };
    const scope = testScopeColumns(&chunk_x, &chunk_y, &tier);
    const region = ActiveRegion{
        .min = .{ .x = 0, .y = 0 },
        .max_exclusive = .{ .x = 1, .y = 1 },
    };
    try std.testing.expect(entityVisibleForRenderCollect(0, scope, region));
    try std.testing.expect(!entityVisibleForRenderCollect(1, scope, region));
}

test "render collect chunk gate ignores simulation tier" {
    var chunk_x = [_]i32{ 0, 0 };
    var chunk_y = [_]i32{ 0, 0 };
    var dormant = [_]SimulationTier{.dormant};
    var cognition = [_]SimulationTier{.cognition};
    const dormant_scope = testScopeColumns(&chunk_x, &chunk_y, &dormant);
    const cognition_scope = testScopeColumns(&chunk_x, &chunk_y, &cognition);
    const region = ActiveRegion{
        .min = .{ .x = 0, .y = 0 },
        .max_exclusive = .{ .x = 1, .y = 1 },
    };
    try std.testing.expect(entityVisibleForRenderCollect(0, dormant_scope, region));
    try std.testing.expect(entityVisibleForRenderCollect(0, cognition_scope, region));
}

test "render collect record sort orders depth then sequence" {
    const unit_rect = Rect{ .x = 0, .y = 0, .w = 1, .h = 1 };
    const unit_color = Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const records = [_]DynamicRenderRecord{
        .{ .depth = 10, .sequence = 2, .draw = .{ .rect = .{ .rect = unit_rect, .color = unit_color, .order = .world(10) } } },
        .{ .depth = 5, .sequence = 9, .draw = .{ .rect = .{ .rect = unit_rect, .color = unit_color, .order = .world(5) } } },
        .{ .depth = 10, .sequence = 1, .draw = .{ .rect = .{ .rect = unit_rect, .color = unit_color, .order = .world(10) } } },
    };
    try std.testing.expect(sortRecordIndexLessThan(&records, 1, 0));
    try std.testing.expect(sortRecordIndexLessThan(&records, 2, 0));
    try std.testing.expect(!sortRecordIndexLessThan(&records, 2, 1));
}

test "layered world merge picks sparse on tie and exhausts either stream" {
    try std.testing.expectEqual(MergeSource.sparse, mergeNextSource(5, 5).?);
    try std.testing.expectEqual(MergeSource.dynamic, mergeNextSource(6, 5).?);
    try std.testing.expectEqual(MergeSource.sparse, mergeNextSource(5, null).?);
    try std.testing.expectEqual(MergeSource.dynamic, mergeNextSource(null, 5).?);
    try std.testing.expect(mergeNextSource(null, null) == null);
}

test "layered world merge interleaves a dynamic span between differing sparse depths and breaks ties toward sparse" {
    // Sparse depths 0 and 10 bracket one dynamic span at depth 5 (interleave), and
    // depth 5 also collides with a second dynamic span (tie: sparse must win).
    const sparse_depths = [_]i32{ 0, 5, 10 };
    const dynamic_depths = [_]i32{5};

    var sparse_index: usize = 0;
    var dynamic_index: usize = 0;
    var sparse_depth: ?i32 = sparse_depths[0];
    var dynamic_depth: ?i32 = dynamic_depths[0];

    var emitted: [4]struct { source: MergeSource, depth: i32 } = undefined;
    var emitted_count: usize = 0;

    while (mergeNextSource(sparse_depth, dynamic_depth)) |source| {
        emitted[emitted_count] = .{ .source = source, .depth = (if (source == .sparse) sparse_depth else dynamic_depth).? };
        emitted_count += 1;
        switch (source) {
            .sparse => {
                sparse_index += 1;
                sparse_depth = if (sparse_index < sparse_depths.len) sparse_depths[sparse_index] else null;
            },
            .dynamic => {
                dynamic_index += 1;
                dynamic_depth = if (dynamic_index < dynamic_depths.len) dynamic_depths[dynamic_index] else null;
            },
        }
    }

    try std.testing.expectEqual(@as(usize, 4), emitted_count);
    try std.testing.expectEqual(MergeSource.sparse, emitted[0].source);
    try std.testing.expectEqual(@as(i32, 0), emitted[0].depth);
    // Tie at depth 5: sparse must be drained before the dynamic span at the same depth.
    try std.testing.expectEqual(MergeSource.sparse, emitted[1].source);
    try std.testing.expectEqual(@as(i32, 5), emitted[1].depth);
    try std.testing.expectEqual(MergeSource.dynamic, emitted[2].source);
    try std.testing.expectEqual(@as(i32, 5), emitted[2].depth);
    try std.testing.expectEqual(MergeSource.sparse, emitted[3].source);
    try std.testing.expectEqual(@as(i32, 10), emitted[3].depth);
}

test "dynamic record capacity counts visuals player marker and particles" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });

    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 4 });
    defer particles.deinit();
    try std.testing.expect(particles.emit(.{ .start_size = 4 }));

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    const player_entity = try EntityId.init(0, 1);

    try std.testing.expectEqual(
        @as(usize, 3),
        dynamicRecordCapacity(.{
            .data = &data,
            .world = &world,
            .player_entity = player_entity,
            .player_level = 0,
            .particles = &particles,
            .overscan_chunks = 0,
        }),
    );
}

test "sprite command capacity sums sparse reserve visuals player and ui headroom" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });

    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 4 });
    defer particles.deinit();
    try std.testing.expect(particles.emit(.{ .start_size = 4 }));

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 8,
        .visible_sparse_count = 3,
    };
    defer world.deinit();
    const player_entity = try EntityId.init(0, 1);

    try std.testing.expectEqual(
        @as(usize, 3) + 1 + 1 + 1 + Renderer.kStackedStateUiHeadroom,
        spriteCommandCapacity(.{
            .data = &data,
            .world = &world,
            .player_entity = player_entity,
            .player_level = 0,
            .particles = &particles,
            .overscan_chunks = 0,
        }),
    );
}

test "static geometry capacity tracks maxDenseSubmitDrawCount and stays flat across levels_below" {
    var world_shallow = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 8,
        .render_window = .{ .levels_below = 0 },
    };
    defer world_shallow.deinit();

    var world_deep = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 8,
        .render_window = .{ .levels_below = 40 },
    };
    defer world_deep.deinit();

    // maxDenseSubmitLayerCount (the old, over-provisioned reservation source)
    // grows with window depth...
    try std.testing.expect(world_deep.maxDenseSubmitLayerCount() > world_shallow.maxDenseSubmitLayerCount());

    const scene_shallow = GameplayScene{
        .data = undefined,
        .world = &world_shallow,
        .player_entity = try EntityId.init(0, 1),
        .player_level = 0,
        .particles = undefined,
        .overscan_chunks = 0,
    };
    const scene_deep = GameplayScene{
        .data = undefined,
        .world = &world_deep,
        .player_entity = try EntityId.init(0, 1),
        .player_level = 0,
        .particles = undefined,
        .overscan_chunks = 0,
    };

    const capacity_shallow = staticGeometryCapacity(scene_shallow);
    const capacity_deep = staticGeometryCapacity(scene_deep);

    // ...but staticGeometryCapacity now sources its span/vertex count from
    // maxDenseSubmitDrawCount(), the fixed composite-draw bound, so it stays
    // identical regardless of levels_below.
    try std.testing.expectEqual(Renderer.k_max_dense_composite_draws, capacity_shallow.span_capacity);
    try std.testing.expectEqual(capacity_shallow.span_capacity, capacity_deep.span_capacity);
    try std.testing.expectEqual(capacity_shallow.span_capacity * 6, capacity_shallow.vertex_capacity);
    try std.testing.expectEqual(capacity_deep.span_capacity * 6, capacity_deep.vertex_capacity);
}

test "collect dynamic records after structural growth stays within reserve and allocates only on warmup" {
    const created_visual_count = 528;
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    // One entity is the player (exercises the player-marker append path); the
    // rest are plain background visuals grown well past initial capacity.
    const player_entity = try data.createEntity();
    try data.setMovementBody(player_entity, .{ .position = .{}, .previous_position = .{} });
    try data.setFacing(player_entity, .{ .direction = .down });
    try data.setPrimitiveVisual(player_entity, .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_length = 1,
        .marker_depth = 1,
        .marker_margin = 0,
    });

    for (1..created_visual_count) |index| {
        const x: f32 = @floatFromInt(index % 64);
        const y: f32 = @floatFromInt(index / 64);
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{
            .position = .{ .x = x, .y = y },
            .previous_position = .{ .x = x, .y = y },
        });
        try data.setPrimitiveVisual(entity, .{
            .size = .{ .x = 1, .y = 1 },
            .color = .{ .r = 0.5, .g = 0.6, .b = 0.7, .a = 1 },
            .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        });
    }

    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 4 });
    defer particles.deinit();
    try std.testing.expect(particles.emit(.{ .position = .{ .x = 10, .y = 10 }, .start_size = 4 }));

    // A minimal world with real chunk geometry (via addLevel), not the demo
    // tileset-backed init, so the render-collect chunk gate sees a live region
    // without pulling in asset loading.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 64,
        .height = 64,
        .tile_size = 32,
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 2048, .h = 2048 }, 0);

    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    const scene = GameplayScene{
        .data = &data,
        .world = &world,
        .player_entity = player_entity,
        .player_level = 0,
        .particles = &particles,
        .overscan_chunks = 0,
    };
    const visible = VisibleWorldRect{ .min_x = 0, .min_y = 0, .max_x = 2048, .max_y = 2048 };

    // The capacity formulas track the live grown population, not a stale snapshot.
    try std.testing.expectEqual(
        data.primitiveVisualSliceConst().entities.len + 1 + particles.activeCount(),
        dynamicRecordCapacity(scene),
    );
    try std.testing.expectEqual(
        world.reserveRenderRecords() + data.primitiveVisualSliceConst().entities.len + 1 +
            particles.activeCount() + Renderer.kStackedStateUiHeadroom,
        spriteCommandCapacity(scene),
    );

    var prep = DynamicScenePrep.init(std.testing.allocator);
    defer prep.deinit();

    // Warmup with the real allocator: grows records/sort_indices/depth_spans to
    // dynamicRecordCapacity once, exercising every entity, the player marker, and
    // the particle through collectDynamicRecords' appendAssumeCapacity calls.
    try collectDynamicRecords(&prep, scene, visible, &runtime_assets, 1.0);
    const expected_record_count: usize = created_visual_count + 1 + 1; // visuals + player marker + particle
    try std.testing.expectEqual(expected_record_count, prep.orderedRecords().len);

    const original_allocator = prep.allocator;
    // Block resize_fail_index too, not just fail_index: ArrayList.ensureTotalCapacityPrecise
    // tries allocator.remap() before falling back to a fresh alloc, and a successful remap
    // (e.g. mremap on Linux) bumps resize_index without incrementing .allocations — leaving
    // fail_index-only blocking unable to catch a regression that needs to grow via remap.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    prep.allocator = failing.allocator();
    defer prep.allocator = original_allocator;

    // Re-running at the same grown population must not allocate: ensureScenePrepCapacity's
    // reserve is already sized to match, so every append below is assumeCapacity-only.
    try collectDynamicRecords(&prep, scene, visible, &runtime_assets, 1.0);
    try std.testing.expectEqual(expected_record_count, prep.orderedRecords().len);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
}

test "collect dynamic records includes an entity that fell to a level within the render window" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const player_entity = try data.createEntity();
    try data.setMovementBody(player_entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(player_entity, .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });

    // Entity fell through a dug hole: DigController's applyEntityPlaneTraversal
    // moves it to level 1 via setWorldLevel while the player stays at level 0.
    const fallen_entity = try data.createEntity();
    try data.setMovementBody(fallen_entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(fallen_entity, .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    try data.setWorldLevel(fallen_entity, 1);

    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 1 });
    defer particles.deinit();

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = 32,
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    _ = try world.addLevel(-level_z_step);
    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 256, .h = 256 }, 0);

    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    const scene = GameplayScene{
        .data = &data,
        .world = &world,
        .player_entity = player_entity,
        .player_level = 0,
        .particles = &particles,
        .overscan_chunks = 0,
    };
    const visible = VisibleWorldRect{ .min_x = -1, .min_y = -1, .max_x = 256, .max_y = 256 };

    var prep = DynamicScenePrep.init(std.testing.allocator);
    defer prep.deinit();
    try collectDynamicRecords(&prep, scene, visible, &runtime_assets, 1.0);

    try std.testing.expectEqual(@as(usize, 2), prep.orderedRecords().len);
}

test "collect dynamic records excludes an entity beyond the render window depth" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const player_entity = try data.createEntity();
    try data.setMovementBody(player_entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(player_entity, .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });

    // In-window boundary: default DenseLayerRenderWindow.levels_below is 6, so a
    // level-6 fall is the deepest still-visible level from player_level 0.
    const in_window_entity = try data.createEntity();
    try data.setMovementBody(in_window_entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(in_window_entity, .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    try data.setWorldLevel(in_window_entity, 6);

    // One level deeper (7) falls outside the window and must stay excluded —
    // this is not a blanket "render every level" regression of the original
    // teleport-bug this gate was guarding against.
    const out_of_window_entity = try data.createEntity();
    try data.setMovementBody(out_of_window_entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(out_of_window_entity, .{
        .size = .{ .x = 1, .y = 1 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    try data.setWorldLevel(out_of_window_entity, 7);

    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 1 });
    defer particles.deinit();

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = 32,
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    for (0..8) |_| _ = try world.addLevel(0);
    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 256, .h = 256 }, 0);

    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    const scene = GameplayScene{
        .data = &data,
        .world = &world,
        .player_entity = player_entity,
        .player_level = 0,
        .particles = &particles,
        .overscan_chunks = 0,
    };
    const visible = VisibleWorldRect{ .min_x = -1, .min_y = -1, .max_x = 256, .max_y = 256 };

    var prep = DynamicScenePrep.init(std.testing.allocator);
    defer prep.deinit();
    try collectDynamicRecords(&prep, scene, visible, &runtime_assets, 1.0);

    // Player + the level-6 entity only; the level-7 entity is dropped.
    try std.testing.expectEqual(@as(usize, 2), prep.orderedRecords().len);
}

fn setSpriteAvailableForTest(runtime_assets: *RuntimeAssets, id: manifest.SpriteAssetId, texture: TextureId) void {
    runtime_assets.sprite_slots[manifest.spriteIndex(id)] = .{
        .status = .available,
        .lease = .{ .id = texture },
    };
}

fn setSpriteAtlasMetadataForTest(runtime_assets: *RuntimeAssets, id: manifest.SpriteAssetId) !void {
    const spec = manifest.spriteSpec(id);
    const metadata_path = spec.metadata_path orelse return error.MissingMetadataPath;
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    runtime_assets.atlas_meta[manifest.spriteIndex(id)] = .{
        .sprite_atlas = try sprite_atlas_meta.load(std.testing.allocator, asset_store, id, metadata_path),
    };
}

fn deinitAtlasMetadataForTest(runtime_assets: *RuntimeAssets, id: manifest.SpriteAssetId) void {
    const index = manifest.spriteIndex(id);
    if (runtime_assets.atlas_meta[index]) |*slot| {
        switch (slot.*) {
            .sprite_atlas => |*meta| meta.deinit(),
            .world_tileset => |*meta| meta.deinit(),
        }
    }
    runtime_assets.atlas_meta[index] = null;
}

test "atlas-backed asset reference falls back to null source rect without metadata" {
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    setSpriteAvailableForTest(&runtime_assets, .grim_characters, try TextureId.init(1, 1));
    const asset_ref = AssetReference{ .sprite = .grim_characters, .atlas_entry_id = 0 };
    const sprite = runtime_assets.sprite(asset_ref.sprite).?;

    try std.testing.expect(sourceRectForAsset(&runtime_assets, asset_ref, sprite.source_rect) == null);
}

test "atlas-backed asset reference uses metadata source rect when available" {
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    setSpriteAvailableForTest(&runtime_assets, .grim_characters, try TextureId.init(1, 1));
    try setSpriteAtlasMetadataForTest(&runtime_assets, .grim_characters);
    defer deinitAtlasMetadataForTest(&runtime_assets, .grim_characters);
    const asset_ref = AssetReference{ .sprite = .grim_characters, .atlas_entry_id = 0 };
    const sprite = runtime_assets.sprite(asset_ref.sprite).?;

    const source = sourceRectForAsset(&runtime_assets, asset_ref, sprite.source_rect) orelse return error.TestExpectedEqual;
    const expected = runtime_assets.spriteAtlasMeta(.grim_characters).?.sourceRectForId(0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(expected.x, source.x);
    try std.testing.expectEqual(expected.y, source.y);
    try std.testing.expectEqual(expected.w, source.w);
    try std.testing.expectEqual(expected.h, source.h);
}

test "atlas reference validation rejects invalid character entry ids" {
    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    try setSpriteAtlasMetadataForTest(&runtime_assets, .grim_characters);
    defer deinitAtlasMetadataForTest(&runtime_assets, .grim_characters);
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setAssetReference(entity, .{ .sprite = .grim_characters, .atlas_entry_id = 4096 });

    try std.testing.expectError(
        error.InvalidSpriteAtlasEntry,
        validateAtlasReferences(&data, &runtime_assets),
    );
}

test "world render order combines entity z with depth band" {
    const below_actor = worldOrder(-2, .actor);
    const obstacle = worldOrder(0, .obstacle);
    const actor = worldOrder(0, .actor);

    try std.testing.expect(below_actor.lessOrEqual(obstacle));
    try std.testing.expect(obstacle.lessOrEqual(actor));
}

test "world render order saturates extreme entity z" {
    try std.testing.expectEqual(std.math.maxInt(i32), worldOrder(std.math.maxInt(i32), .marker).depth);
    try std.testing.expectEqual(std.math.minInt(i32), worldOrder(std.math.minInt(i32), .floor).depth);
}

test "visible world rect matches world chunk overscan in pixel space" {
    const camera_rect = Rect{ .x = 100, .y = 200, .w = 800, .h = 450 };
    const overscan_chunks: u16 = 2;
    const chunk_size_tiles: u16 = 8;
    const tile_size: f32 = 32;
    const visible = VisibleWorldRect.fromCameraRect(camera_rect, overscan_chunks, chunk_size_tiles, tile_size);
    const overscan_pixels = @as(f32, @floatFromInt(@as(u32, overscan_chunks) * @as(u32, chunk_size_tiles))) * tile_size;
    try std.testing.expectEqual(camera_rect.x - overscan_pixels, visible.min_x);
    try std.testing.expectEqual(camera_rect.y - overscan_pixels, visible.min_y);
    try std.testing.expectEqual(camera_rect.x + camera_rect.w + overscan_pixels, visible.max_x);
    try std.testing.expectEqual(camera_rect.y + camera_rect.h + overscan_pixels, visible.max_y);
}

test "visible world rect culls entity aabb outside camera overscan" {
    const visible = VisibleWorldRect.fromCameraRect(.{
        .x = 0,
        .y = 0,
        .w = 800,
        .h = 450,
    }, 1, 8, 32);
    // Overscan is 256px; entity fully inside the expanded window is kept.
    try std.testing.expect(visible.overlapsAabb(700, 400, 32, 32));
    // Entity wholly past the right edge of the overscanned window is dropped.
    try std.testing.expect(!visible.overlapsAabb(1100, 200, 32, 32));
    // Touching max edge is half-open: aabb starting at max_x is out.
    try std.testing.expect(!visible.overlapsAabb(visible.max_x, 200, 32, 32));
}

test "visible world rect expands camera rect by chunk overscan" {
    const rect = VisibleWorldRect.fromCameraRect(.{
        .x = 100,
        .y = 200,
        .w = 800,
        .h = 450,
    }, 2, 16, 32);
    try std.testing.expectEqual(@as(f32, 100 - 1024), rect.min_x);
    try std.testing.expectEqual(@as(f32, 200 - 1024), rect.min_y);
    try std.testing.expectEqual(@as(f32, 900 + 1024), rect.max_x);
    try std.testing.expectEqual(@as(f32, 650 + 1024), rect.max_y);
}

test "visible world rect uses half-open aabb overlap" {
    const rect = VisibleWorldRect{
        .min_x = 10,
        .min_y = 20,
        .max_x = 110,
        .max_y = 120,
    };
    try std.testing.expect(rect.overlapsAabb(50, 50, 32, 32));
    try std.testing.expect(!rect.overlapsAabb(200, 200, 32, 32));
    try std.testing.expect(rect.overlapsAabb(105, 50, 32, 32));
    try std.testing.expect(!rect.overlapsAabb(110, 50, 32, 32));
}

test "visible world rect uses half-open point containment" {
    const rect = VisibleWorldRect{
        .min_x = 10,
        .min_y = 20,
        .max_x = 110,
        .max_y = 120,
    };
    try std.testing.expect(rect.containsPoint(.{ .x = 10, .y = 20 }));
    try std.testing.expect(rect.containsPoint(.{ .x = 109.9, .y = 119.9 }));
    try std.testing.expect(!rect.containsPoint(.{ .x = 9.9, .y = 20 }));
    try std.testing.expect(!rect.containsPoint(.{ .x = 10, .y = 19.9 }));
    try std.testing.expect(!rect.containsPoint(.{ .x = 110, .y = 20 }));
    try std.testing.expect(!rect.containsPoint(.{ .x = 10, .y = 120 }));
}

fn testWorldTilesetMeta() !WorldTilesetMeta {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    return try world_tileset_meta.load(std.testing.allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
}

test "a visible sparse tile at a deeper in-window level produces a second dense composite draw group" {
    const allocator = std.testing.allocator;
    var meta = try testWorldTilesetMeta();
    defer meta.deinit();

    // `initDemoFromMeta` is the smallest public constructor that builds a real
    // catalog (`buildCatalog` itself is private); it creates level 0 with its
    // own grass floor and a couple of surface obstacle tiles, which this test
    // extends with a second, deeper level below it.
    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, 64, 64);
    defer world.deinit();

    const grass = try world.requireTileByName(&meta, "grass");
    const tree = try world.requireTileByName(&meta, "tree_0");
    const level1 = try world.addLevel(-level_z_step);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);
    // A sparse tile on the deeper, non-active level: the gap this slice closes.
    // Neither `active_level` special-casing nor the old per-layer-draw design
    // needed this; the general interleave-point rule is what must catch it.
    _ = try world.addSparseTile(level1, 0, 0, tree, 0, .effect);
    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 128, .h = 128 }, 0);
    // Fake the combined GPU tile-data buffer so submitStaticDenseGeometry skips
    // the real GPU upload (unavailable headless), mirroring world_system.zig's
    // "setDenseTile queues a GPU cell edit only once the combined buffer exists".
    world.dense_tile_data_buffer = @enumFromInt(0);

    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));

    // Headless Renderer: device/pipeline/sampler are never dereferenced by the
    // CPU-only static-geometry path this test exercises. Mirrors renderer.zig's
    // own headless test fixtures.
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.batch.deinit();
    defer renderer.static_positions.deinit(allocator);
    defer renderer.static_uvs.deinit(allocator);
    defer renderer.static_colors.deinit(allocator);
    defer renderer.static_groups.deinit(allocator);
    defer renderer.draw_list.deinit(allocator);

    var prep = DynamicScenePrep.init(allocator);
    defer prep.deinit();

    const scene = GameplayScene{
        .data = undefined,
        .world = &world,
        .player_entity = try EntityId.init(0, 1),
        .player_level = 0,
        .particles = undefined,
        .overscan_chunks = 0,
    };

    try submitLayeredWorld(scene, &prep, &renderer, &runtime_assets);

    try std.testing.expectEqual(@as(usize, 2), renderer.static_groups.items.len);
    try std.testing.expectEqual(sprite_batch.Material.tilemap, renderer.static_groups.items[0].material);
    try std.testing.expectEqual(sprite_batch.Material.tilemap, renderer.static_groups.items[1].material);
    // The deeper level (holding the sparse tile) composites first (further
    // back); the shallower level composites last (in front) — the sparse tile's
    // own dynamic draw sits between them in the merged list.
    try std.testing.expect(renderer.static_groups.items[0].order.depth < renderer.static_groups.items[1].order.depth);

    var merged: std.ArrayList(sprite_batch.DrawGroup) = .empty;
    defer merged.deinit(allocator);
    try mergeDrawList(&merged, allocator, renderer.static_groups.items, &.{});
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
}

test "dense composite bucketing keeps every needed cut regardless of how many redundant interleave candidates exist" {
    const allocator = std.testing.allocator;
    var meta = try testWorldTilesetMeta();
    defer meta.deinit();

    // Surface level (0) plus `k_max_dense_submit_stack_cap - 1` deeper levels:
    // exactly the worst-case submitted-layer count, giving
    // `k_max_dense_submit_stack_cap - 1` gaps between adjacent submitted layers.
    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, 64, 64);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    var extra_level_index: u16 = 1;
    while (extra_level_index < k_max_dense_submit_stack_cap) : (extra_level_index += 1) {
        const level = try world.addLevel(-@as(i32, @intCast(extra_level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }
    world.render_window = .{ .levels_below = k_max_dense_submit_stack_cap };

    const num_gaps = k_max_dense_submit_stack_cap - 1;
    // Feed 3 candidates per gap (2 dynamic, 1 sparse) — 3x this frame's real
    // gap count and, summed across gaps, far more raw distinct depths than the
    // fixed 32-slot scratch buffer could ever hold under a value-keyed dedup.
    var prep = DynamicScenePrep.init(allocator);
    defer prep.deinit();
    try prep.depth_spans.ensureTotalCapacity(allocator, 2 * num_gaps);
    for (0..num_gaps) |gap_index| {
        // Gap `gap_index` sits between the submitted layer at level
        // `k_max_dense_submit_stack_cap - 1 - gap_index` and the next
        // shallower one; its own depth is `level_base_z - 2` (.floor band).
        const deeper_level_index: i32 = @intCast(k_max_dense_submit_stack_cap - 1 - gap_index);
        const gap_start_depth = -deeper_level_index * level_z_step - 2;
        prep.depth_spans.appendAssumeCapacity(.{ .start = 0, .end = 0, .depth = gap_start_depth + 4 });
        prep.depth_spans.appendAssumeCapacity(.{ .start = 0, .end = 0, .depth = gap_start_depth + 10 });
        _ = try world.addSparseTile(0, 0, 0, grass, gap_start_depth + 13, .effect);
    }
    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 64, .h = 64 }, 0);
    world.dense_tile_data_buffer = @enumFromInt(0);

    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));

    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.batch.deinit();
    defer renderer.static_positions.deinit(allocator);
    defer renderer.static_uvs.deinit(allocator);
    defer renderer.static_colors.deinit(allocator);
    defer renderer.static_groups.deinit(allocator);
    defer renderer.draw_list.deinit(allocator);

    const scene = GameplayScene{
        .data = undefined,
        .world = &world,
        .player_entity = try EntityId.init(0, 1),
        .player_level = 0,
        .particles = undefined,
        .overscan_chunks = 0,
    };

    // Must not error (TooManyDenseLayers would mean a needed gap overflowed
    // the fixed scratch buffer) and must produce one composite draw per
    // submitted layer, proving every one of the `num_gaps` cuts survived
    // despite 3x as many raw candidate depths feeding the collector.
    try submitLayeredWorld(scene, &prep, &renderer, &runtime_assets);
    try std.testing.expectEqual(k_max_dense_submit_stack_cap, renderer.static_groups.items.len);
}
