// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const Color = @import("../config.zig").Color;
const math = @import("../core/math.zig");
const simd = @import("../core/simd.zig");
const DataSystem = @import("data_system.zig").DataSystem;
const ConstAssetReferenceSlice = @import("data_system.zig").ConstAssetReferenceSlice;
const ConstMovementBodySlice = @import("data_system.zig").ConstMovementBodySlice;
const ConstScopeColumnsSlice = @import("data_system.zig").ConstScopeColumnsSlice;
const ConstPrimitiveVisualSlice = @import("data_system.zig").ConstPrimitiveVisualSlice;
const ConstFacingSlice = @import("data_system.zig").ConstFacingSlice;
const RenderCollectIndices = @import("data_system.zig").RenderCollectIndices;
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
const manifest = @import("../assets/manifest.zig");
const WorldDepth = @import("render_depth.zig").WorldDepth;
const render_depth = @import("render_depth.zig");
const WorldSystem = @import("world_system.zig").WorldSystem;
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
pub fn staticGeometryCapacity(scene: GameplayScene) struct { vertex_capacity: usize, span_capacity: usize } {
    const span_capacity = scene.world.maxDenseSubmitLayerCount();
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

/// One scalar-filtered entity awaiting batched interpolation. Buffered by
/// `collectDynamicRecords` up to `simd.lane_count` at a time before the lerp
/// is vectorized; see the packed-SoA-scratch idiom on `simd.gatherFloat4`.
const EntityLerpCandidate = struct {
    movement_index: usize,
    collect_indices: RenderCollectIndices,
    is_player: bool,
};

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

    // Packed-SoA-scratch idiom (see simd.gatherFloat4 doc): buffer scalar-filtered
    // candidates, then batch-lerp lane_count at a time once the buffer fills.
    var entity_candidates: [simd.lane_count]EntityLerpCandidate = undefined;
    var entity_candidate_count: usize = 0;

    // Movement-body dense rows are the collect anchor: scope columns (tier/chunk)
    // align with movement_index; has_primitive_visual skips movement-only rows
    // before the deferred slot resolve in renderCollectIndicesForMovement.
    for (movement.entities, 0..) |entity, movement_index| {
        const is_player = entity.index == player_entity_index and entity.generation == player_entity_generation;
        if (!is_player) {
            const entity_level = scene.data.worldLevelConst(entity) orelse 0;
            if (entity_level != scene.player_level) continue;
        }
        if (!entityVisibleForRenderCollect(movement_index, scope, visible_chunks)) continue;
        if (!movement.has_primitive_visual[movement_index]) continue;

        const collect_indices = scene.data.renderCollectIndicesForMovement(movement_index) orelse continue;

        entity_candidates[entity_candidate_count] = .{
            .movement_index = movement_index,
            .collect_indices = collect_indices,
            .is_player = is_player,
        };
        entity_candidate_count += 1;
        if (entity_candidate_count == simd.lane_count) {
            flushEntityLerpBatch(
                prep,
                movement,
                visuals,
                assets,
                facings,
                visible,
                runtime_assets,
                entity_candidates,
                interpolation_alpha,
            );
            entity_candidate_count = 0;
        }
    }
    // Tail: fewer than lane_count buffered candidates remain; finish them with
    // the plain scalar lerp rather than padding a partial group into a vector call.
    for (entity_candidates[0..entity_candidate_count]) |candidate| {
        const render_x = math.lerp(
            movement.previous_x[candidate.movement_index],
            movement.position_x[candidate.movement_index],
            interpolation_alpha,
        );
        const render_y = math.lerp(
            movement.previous_y[candidate.movement_index],
            movement.position_y[candidate.movement_index],
            interpolation_alpha,
        );
        finishEntityRecord(prep, movement, visuals, assets, facings, visible, runtime_assets, candidate, render_x, render_y);
    }

    const particles = scene.particles.sliceConst();
    var particle_candidates: [simd.lane_count]usize = undefined;
    var particle_candidate_count: usize = 0;
    for (0..particles.len()) |index| {
        if (!particles.renderable(index)) continue;

        particle_candidates[particle_candidate_count] = index;
        particle_candidate_count += 1;
        if (particle_candidate_count == simd.lane_count) {
            flushParticleLerpBatch(prep, particles, visible, particle_candidates, interpolation_alpha);
            particle_candidate_count = 0;
        }
    }
    for (particle_candidates[0..particle_candidate_count]) |index| {
        const render_x = math.lerp(particles.previous_x[index], particles.position_x[index], interpolation_alpha);
        const render_y = math.lerp(particles.previous_y[index], particles.position_y[index], interpolation_alpha);
        finishParticleRecord(prep, particles, visible, index, render_x, render_y);
    }
    prep.finalizeDepthBuckets();
}

/// Gathers the buffered candidates' previous/current positions, batch-lerps
/// via `simd.lerpVec2Float4`, then finishes each lane through the same
/// `finishEntityRecord` body the scalar tail uses.
fn flushEntityLerpBatch(
    prep: *DynamicScenePrep,
    movement: ConstMovementBodySlice,
    visuals: ConstPrimitiveVisualSlice,
    assets: ConstAssetReferenceSlice,
    facings: ConstFacingSlice,
    visible: VisibleWorldRect,
    runtime_assets: *const RuntimeAssets,
    candidates: [simd.lane_count]EntityLerpCandidate,
    interpolation_alpha: f32,
) void {
    var movement_indices: [simd.lane_count]usize = undefined;
    inline for (0..simd.lane_count) |lane| {
        movement_indices[lane] = candidates[lane].movement_index;
    }

    const previous_x = simd.gatherFloat4(movement.previous_x, movement_indices);
    const position_x = simd.gatherFloat4(movement.position_x, movement_indices);
    const previous_y = simd.gatherFloat4(movement.previous_y, movement_indices);
    const position_y = simd.gatherFloat4(movement.position_y, movement_indices);
    const lerped = simd.lerpVec2Float4(
        .{ .x = previous_x, .y = previous_y },
        .{ .x = position_x, .y = position_y },
        simd.splatFloat4(interpolation_alpha),
    );
    const render_x = simd.toFloatArray(lerped.x);
    const render_y = simd.toFloatArray(lerped.y);

    inline for (0..simd.lane_count) |lane| {
        finishEntityRecord(
            prep,
            movement,
            visuals,
            assets,
            facings,
            visible,
            runtime_assets,
            candidates[lane],
            render_x[lane],
            render_y[lane],
        );
    }
}

/// AABB cull + build + append (+ optional player marker) for one already-lerped
/// entity candidate. Shared by the batched-lane path and the scalar tail so the
/// two paths cannot diverge.
fn finishEntityRecord(
    prep: *DynamicScenePrep,
    movement: ConstMovementBodySlice,
    visuals: ConstPrimitiveVisualSlice,
    assets: ConstAssetReferenceSlice,
    facings: ConstFacingSlice,
    visible: VisibleWorldRect,
    runtime_assets: *const RuntimeAssets,
    candidate: EntityLerpCandidate,
    render_x: f32,
    render_y: f32,
) void {
    const movement_index = candidate.movement_index;
    const collect_indices = candidate.collect_indices;
    const visual_index = collect_indices.visual_index;
    const size_x = visuals.size_x[visual_index];
    const size_y = visuals.size_y[visual_index];
    if (!visible.overlapsAabb(render_x, render_y, size_x, size_y)) return;

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
    if (candidate.is_player) {
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

/// Gathers the buffered particle indices' previous/current positions,
/// batch-lerps via `simd.lerpVec2Float4`, then finishes each lane through the
/// same `finishParticleRecord` body the scalar tail uses.
fn flushParticleLerpBatch(
    prep: *DynamicScenePrep,
    particles: ConstParticleSlice,
    visible: VisibleWorldRect,
    indices: [simd.lane_count]usize,
    interpolation_alpha: f32,
) void {
    const previous_x = simd.gatherFloat4(particles.previous_x, indices);
    const position_x = simd.gatherFloat4(particles.position_x, indices);
    const previous_y = simd.gatherFloat4(particles.previous_y, indices);
    const position_y = simd.gatherFloat4(particles.position_y, indices);
    const lerped = simd.lerpVec2Float4(
        .{ .x = previous_x, .y = previous_y },
        .{ .x = position_x, .y = position_y },
        simd.splatFloat4(interpolation_alpha),
    );
    const render_x = simd.toFloatArray(lerped.x);
    const render_y = simd.toFloatArray(lerped.y);

    inline for (0..simd.lane_count) |lane| {
        finishParticleRecord(prep, particles, visible, indices[lane], render_x[lane], render_y[lane]);
    }
}

/// AABB cull + build + append for one already-lerped particle. Shared by the
/// batched-lane path and the scalar tail so the two paths cannot diverge.
fn finishParticleRecord(
    prep: *DynamicScenePrep,
    particles: ConstParticleSlice,
    visible: VisibleWorldRect,
    index: usize,
    render_x: f32,
    render_y: f32,
) void {
    const particle_size = particles.size[index];
    const half_size = particle_size * 0.5;
    if (!visible.overlapsAabb(render_x - half_size, render_y - half_size, particle_size, particle_size)) return;
    const draw = prepareParticleAt(particles, index, render_x, render_y) orelse return;
    prep.appendAssumeCapacity(.{ .depth = draw.depth(), .draw = draw });
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
    try scene.world.submitStaticDenseGeometry(renderer, runtime_assets, scene.player_level);
    try scene.world.flushDenseTileEdits(renderer);

    var sparse_depth = scene.world.firstVisibleSparseDepth();
    var dynamic_span_index: usize = 0;
    var dynamic_depth = nextDynamicDepth(prep, &dynamic_span_index);
    while (mergeNextSource(sparse_depth, dynamic_depth)) |source| {
        switch (source) {
            .sparse => {
                const depth = sparse_depth.?;
                try scene.world.submitVisibleSparseAtDepth(renderer, runtime_assets, depth);
                sparse_depth = scene.world.nextVisibleSparseDepthAfter(depth);
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

fn renderPrepTestPosition(movement_index: usize) math.Vec2 {
    const index_f: f32 = @floatFromInt(movement_index);
    return .{ .x = 10 * index_f + 3, .y = 7 * index_f + 11 };
}

fn renderPrepTestPreviousPosition(movement_index: usize) math.Vec2 {
    const index_f: f32 = @floatFromInt(movement_index);
    return .{ .x = 10 * index_f, .y = 7 * index_f };
}

test "collectDynamicRecords batches entity lerp in lane groups and preserves scalar discovery order" {
    // Eleven movement rows, in creation (== dense) order:
    //   0 background (pass), 1 wrong level (fail), 2 chunk-culled (fail),
    //   3 background (pass), 4 no primitive visual (fail, natural),
    //   5 player (pass, mid-stream), 6 background (pass)  -> completes a
    //   full lane_count(4) batch: [0, 3, 5, 6],
    //   7 has_primitive_visual forced true with no visual row (fail: slot
    //   resolve returns null from renderCollectIndicesForMovement),
    //   8, 9, 10 background (pass) -> scalar tail of 3.
    // Total passing candidates = 7, not a multiple of simd.lane_count, so both
    // a full batched group and the scalar tail execute.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const background_visual = @import("data_system.zig").PrimitiveVisual{
        .size = .{ .x = 4, .y = 4 },
        .color = .{ .r = 0.2, .g = 0.3, .b = 0.4, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };

    const entity0 = try data.createEntity();
    try data.setMovementBody(entity0, .{
        .position = renderPrepTestPosition(0),
        .previous_position = renderPrepTestPreviousPosition(0),
    });
    try data.setPrimitiveVisual(entity0, background_visual);

    const entity1_wrong_level = try data.createEntity();
    try data.setMovementBody(entity1_wrong_level, .{
        .position = renderPrepTestPosition(1),
        .previous_position = renderPrepTestPreviousPosition(1),
    });
    try data.setPrimitiveVisual(entity1_wrong_level, background_visual);
    try data.setWorldLevel(entity1_wrong_level, 5);

    const entity2_chunk_culled = try data.createEntity();
    try data.setMovementBody(entity2_chunk_culled, .{
        .position = renderPrepTestPosition(2),
        .previous_position = renderPrepTestPreviousPosition(2),
    });
    try data.setPrimitiveVisual(entity2_chunk_culled, background_visual);

    const entity3 = try data.createEntity();
    try data.setMovementBody(entity3, .{
        .position = renderPrepTestPosition(3),
        .previous_position = renderPrepTestPreviousPosition(3),
    });
    try data.setPrimitiveVisual(entity3, background_visual);

    const entity4_no_visual = try data.createEntity();
    try data.setMovementBody(entity4_no_visual, .{
        .position = renderPrepTestPosition(4),
        .previous_position = renderPrepTestPreviousPosition(4),
    });
    // Intentionally no setPrimitiveVisual: has_primitive_visual stays false.

    const player_entity = try data.createEntity();
    try data.setMovementBody(player_entity, .{
        .position = renderPrepTestPosition(5),
        .previous_position = renderPrepTestPreviousPosition(5),
    });
    try data.setFacing(player_entity, .{ .direction = .down });
    try data.setPrimitiveVisual(player_entity, .{
        .size = .{ .x = 4, .y = 4 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_length = 1,
        .marker_depth = 1,
        .marker_margin = 0,
    });

    const entity6 = try data.createEntity();
    try data.setMovementBody(entity6, .{
        .position = renderPrepTestPosition(6),
        .previous_position = renderPrepTestPreviousPosition(6),
    });
    try data.setPrimitiveVisual(entity6, background_visual);

    const entity7_null_indices = try data.createEntity();
    try data.setMovementBody(entity7_null_indices, .{
        .position = renderPrepTestPosition(7),
        .previous_position = renderPrepTestPreviousPosition(7),
    });
    // Intentionally no setPrimitiveVisual, then desync the dense flag: exercises
    // the `renderCollectIndicesForMovement(...) orelse continue` defensive path.
    data.movementBodySlice().has_primitive_visual[7] = true;

    const entity8 = try data.createEntity();
    try data.setMovementBody(entity8, .{
        .position = renderPrepTestPosition(8),
        .previous_position = renderPrepTestPreviousPosition(8),
    });
    try data.setPrimitiveVisual(entity8, background_visual);

    const entity9 = try data.createEntity();
    try data.setMovementBody(entity9, .{
        .position = renderPrepTestPosition(9),
        .previous_position = renderPrepTestPreviousPosition(9),
    });
    try data.setPrimitiveVisual(entity9, background_visual);

    const entity10 = try data.createEntity();
    try data.setMovementBody(entity10, .{
        .position = renderPrepTestPosition(10),
        .previous_position = renderPrepTestPreviousPosition(10),
    });
    try data.setPrimitiveVisual(entity10, background_visual);

    // Chunk-cull row 2 only: everything else defaults to chunk (0, 0), which is
    // inside the visible region set up below.
    var scope = data.scopeColumnsSlice();
    scope.chunk_x[2] = 100;
    scope.chunk_y[2] = 100;

    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 1 });
    defer particles.deinit();

    // Smallest possible world: 1x1 tiles still yields exactly one chunk
    // (chunksX/Y is ceilDiv(width, chunk_size_tiles)), which is all the chunk
    // gate needs — no reason to build out a larger tile grid for this test.
    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    _ = try world.addLevel(0);
    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 32, .h = 32 }, 0);

    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    const scene = GameplayScene{
        .data = &data,
        .world = &world,
        .player_entity = player_entity,
        .player_level = 0,
        .particles = &particles,
        .overscan_chunks = 0,
    };
    const visible = VisibleWorldRect{ .min_x = 0, .min_y = 0, .max_x = 256, .max_y = 256 };
    const interpolation_alpha: f32 = 0.37;

    var prep = DynamicScenePrep.init(std.testing.allocator);
    defer prep.deinit();
    try collectDynamicRecords(&prep, scene, visible, &runtime_assets, interpolation_alpha);

    const records = prep.orderedRecords();
    // 7 passing background/player rows + 1 player marker; the 4 filtered rows
    // (wrong level, chunk-culled, no visual, desynced-null-indices) contribute
    // nothing and must not have consumed a lane slot.
    try std.testing.expectEqual(@as(usize, 8), records.len);

    // Discovery order must be reproduced exactly: [0, 3, player, player-marker,
    // 6, 8, 9, 10]. Sequence equals append order (== array index) here since
    // nothing before this point in the run has appended any record.
    const expected_movement_index = [_]usize{ 0, 3, 5, 5, 6, 8, 9, 10 };
    for (records, 0..) |record, slot| {
        try std.testing.expectEqual(slot, record.sequence);
        const is_marker = slot == 3;
        try std.testing.expectEqual(@as(i32, if (is_marker) 2 else 0), record.depth);

        const movement_index = expected_movement_index[slot];
        const expected_render_x = math.lerp(
            renderPrepTestPreviousPosition(movement_index).x,
            renderPrepTestPosition(movement_index).x,
            interpolation_alpha,
        );
        const expected_render_y = math.lerp(
            renderPrepTestPreviousPosition(movement_index).y,
            renderPrepTestPosition(movement_index).y,
            interpolation_alpha,
        );

        if (is_marker) {
            const expected_marker_rect = markerRectAt(expected_render_x, expected_render_y, .down, 4, 4, 1, 1, 0);
            const marker_rect = record.draw.rect.rect;
            try std.testing.expectEqual(expected_marker_rect.x, marker_rect.x);
            try std.testing.expectEqual(expected_marker_rect.y, marker_rect.y);
        } else {
            const rect = record.draw.rect.rect;
            try std.testing.expectEqual(expected_render_x, rect.x);
            try std.testing.expectEqual(expected_render_y, rect.y);
        }
    }
}

test "collectDynamicRecords batches particle lerp in lane groups and preserves discovery order" {
    // No entities: the movement loop is a no-op, so this isolates the particle
    // batch/tail flush path with the smallest possible fixture (1x1 world, no
    // levels/chunks needed since nothing consults them).
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();

    const particle_count = 6; // one full lane_count(4) batch + a 2-item tail
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_count });
    defer particles.deinit();
    for (0..particle_count) |i| {
        const position = renderPrepTestPosition(i);
        try std.testing.expect(particles.emit(.{ .position = position, .start_size = 4 }));
    }
    // Spawn sets previous == position; desync them so the batch/tail lerp is
    // non-trivial and a lane mixup would show up as a wrong rendered position.
    var mutable_particles = particles.slice();
    for (0..particle_count) |i| {
        const previous = renderPrepTestPreviousPosition(i);
        mutable_particles.previous_x[i] = previous.x;
        mutable_particles.previous_y[i] = previous.y;
    }

    var world = WorldSystem{
        .allocator = std.testing.allocator,
        .width = 1,
        .height = 1,
        .tile_size = 32,
        .chunk_size_tiles = 8,
    };
    defer world.deinit();
    const player_entity = try EntityId.init(0, 1);

    var runtime_assets = RuntimeAssets.init(std.testing.allocator);
    const scene = GameplayScene{
        .data = &data,
        .world = &world,
        .player_entity = player_entity,
        .player_level = 0,
        .particles = &particles,
        .overscan_chunks = 0,
    };
    const visible = VisibleWorldRect{ .min_x = 0, .min_y = 0, .max_x = 256, .max_y = 256 };
    const interpolation_alpha: f32 = 0.6;

    var prep = DynamicScenePrep.init(std.testing.allocator);
    defer prep.deinit();
    try collectDynamicRecords(&prep, scene, visible, &runtime_assets, interpolation_alpha);

    const records = prep.orderedRecords();
    try std.testing.expectEqual(@as(usize, particle_count), records.len);

    const half_size: f32 = 4 * 0.5;
    for (records, 0..) |record, index| {
        try std.testing.expectEqual(index, record.sequence);
        const expected_render_x = math.lerp(
            renderPrepTestPreviousPosition(index).x,
            renderPrepTestPosition(index).x,
            interpolation_alpha,
        );
        const expected_render_y = math.lerp(
            renderPrepTestPreviousPosition(index).y,
            renderPrepTestPosition(index).y,
            interpolation_alpha,
        );
        const rect = record.draw.rect.rect;
        try std.testing.expectEqual(expected_render_x - half_size, rect.x);
        try std.testing.expectEqual(expected_render_y - half_size, rect.y);
    }
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
