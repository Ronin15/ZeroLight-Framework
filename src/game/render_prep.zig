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
const renderer_mod = @import("../render/renderer.zig");
const Rect = renderer_mod.Rect;
const RenderOrder = renderer_mod.RenderOrder;
const Renderer = renderer_mod.Renderer;
const Sprite = renderer_mod.Sprite;
const TextureId = renderer_mod.TextureId;
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
    const depth_band: WorldDepth = @fromBackingInt(@intCast(visuals.depth_values[visual_index]));
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
/// `Renderer.k_overlay_command_headroom` for the debug overlay afterward.
pub fn spriteCommandCapacity(scene: GameplayScene) usize {
    const visual_count = scene.data.primitiveVisualSliceConst().entities.len;
    const player_marker_count: usize = 1;
    return scene.world.reserveRenderRecords() +
        visual_count +
        player_marker_count +
        scene.particles.activeCount() +
        Renderer.k_stacked_state_ui_headroom;
}

pub fn ensureScenePrepCapacity(prep: *DynamicScenePrep, scene: GameplayScene) !void {
    try prep.ensureCapacity(dynamicRecordCapacity(scene));
}

/// Retained static tilemap geometry for the world's resident dense layers: one
/// span per resident layer (`maxDenseSubmitDrawCount`), the most composite draws
/// `submitStaticDenseGeometry` can cut. Grow-only; call after
/// `syncDenseTileStore` sets the resident layers.
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

        const collect_indices = scene.data.renderCollectIndicesForMovement(movement, movement_index, visuals.entities.len) orelse continue;
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
            const depth_band: WorldDepth = @fromBackingInt(@intCast(visuals.depth_values[visual_index]));
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
    try scene.world.syncDenseTileStore(renderer, scene.player_level);
    try ensureStaticGeometryCapacity(scene, renderer);
    const interleave_depths = collectDenseInterleaveDepths(scene, prep);
    try scene.world.submitStaticDenseGeometry(renderer, runtime_assets, scene.player_level, interleave_depths);

    var sparse_range: usize = 0;
    var sparse_depth = sparseRangeDepth(scene, sparse_range);
    var dynamic_span_index: usize = 0;
    var dynamic_depth = nextDynamicDepth(prep, &dynamic_span_index);
    while (mergeNextSource(sparse_depth, dynamic_depth)) |source| {
        switch (source) {
            .sparse => {
                try scene.world.submitVisibleSparseRange(renderer, runtime_assets, sparse_range);
                sparse_range += 1;
                sparse_depth = sparseRangeDepth(scene, sparse_range);
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
/// actor depth (always included, so the common case with no sandwiched content
/// still splits exactly where an actor stands), every distinct dynamic depth this
/// frame (`prep.depthSpans()`), and every depth of the render window's sparse
/// tiles (`sparseDepthRangeCount`/`sparseDepthRangeAt`, the same ranges
/// `submitLayeredWorld` walks for the merge), since a sparse tile at any
/// in-window level needs its own sandwich point.
///
/// `WorldSystem.partitionDenseCompositeBuckets` needs at most one candidate per
/// gap between two adjacent resident dense layers to cut there, so candidates
/// dedupe by the gap they would cut (`interleaveGapIndex`, the partition's own
/// boundary rule), not by depth value, and a depth outside the resident layers'
/// span (`denseWindowDepthSpan`) cannot cut anything. The result fits the world's
/// interleave scratch (one slot per gap), sized when the resident set was planned,
/// so this allocates nothing. Returns the sorted, deduplicated cut points
/// `submitStaticDenseGeometry` partitions on. Requires `syncDenseTileStore` first.
fn collectDenseInterleaveDepths(scene: GameplayScene, prep: *const DynamicScenePrep) []const i32 {
    const span = scene.world.denseWindowDepthSpan() orelse return &.{};
    const layer_depths = scene.world.denseWindowLayerDepths();
    const scratch = scene.world.denseInterleaveScratch();
    var count: usize = 0;

    appendInterleaveDepth(scratch.depths, &count, scratch.gap_filled, layer_depths, scene.world.activeLevelActorDepth(scene.player_level), span);
    for (prep.depthSpans()) |range| {
        appendInterleaveDepth(scratch.depths, &count, scratch.gap_filled, layer_depths, range.depth, span);
    }
    for (0..scene.world.sparseDepthRangeCount()) |index| {
        appendInterleaveDepth(scratch.depths, &count, scratch.gap_filled, layer_depths, scene.world.sparseDepthRangeAt(index), span);
    }

    const collected = scratch.depths[0..count];
    std.mem.sort(i32, collected, {}, std.sort.asc(i32));
    return collected;
}

/// Finds which gap between two adjacent entries of `layer_depths` (ascending,
/// `WorldSystem.denseWindowLayerDepths`) `depth` would cut, mirroring
/// `WorldSystem.partitionDenseCompositeBuckets`'s own boundary rule
/// (`layer_depths[i - 1] < depth <= layer_depths[i]`). Returns null when
/// `depth` cannot cut any boundary — at or below the deepest resident layer,
/// nothing sits beneath it to sandwich against.
fn interleaveGapIndex(layer_depths: []const i32, depth: i32) ?usize {
    var i: usize = 1;
    while (i < layer_depths.len) : (i += 1) {
        if (depth > layer_depths[i - 1] and depth <= layer_depths[i]) return i - 1;
    }
    return null;
}

/// The depth of the window's sparse range `range_index` (ascending, one range
/// per distinct depth), or null past the last range.
fn sparseRangeDepth(scene: GameplayScene, range_index: usize) ?i32 {
    if (range_index >= scene.world.sparseDepthRangeCount()) return null;
    return scene.world.sparseDepthRangeAt(range_index);
}

/// Appends `depth` to `depths[0..count]` once per gap it could cut between two
/// adjacent resident dense layers (`interleaveGapIndex`). Drops `depth` when it
/// falls outside `span`, cannot cut any gap, or its gap already has a
/// representative: `partitionDenseCompositeBuckets` consults one candidate per
/// gap, so none of these can move a bucket boundary. `depths` holds one slot per
/// gap, so it never overflows.
fn appendInterleaveDepth(
    depths: []i32,
    count: *usize,
    gap_filled: []bool,
    layer_depths: []const i32,
    depth: i32,
    span: WorldSystem.DenseWindowDepthSpan,
) void {
    if (depth < span.min or depth > span.max) return;
    const gap_index = interleaveGapIndex(layer_depths, depth) orelse return;
    if (gap_filled[gap_index]) return;
    gap_filled[gap_index] = true;
    std.debug.assert(count.* < depths.len);
    depths[count.*] = depth;
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
    const marker_depth_band: WorldDepth = @fromBackingInt(@intCast(visuals.marker_depth_values[visual_index]));
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

test "sprite command capacity sums the window's sparse tiles, visuals, player, and ui headroom" {
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

    var meta = try testWorldTilesetMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 256, 256);
    defer world.deinit();
    const deco = try world.requireTileByName(&meta, "deco_0");
    // Three tiles in the window's top row of three tiles and one outside it.
    for ([_]u16{ 0, 1, 2 }) |x| _ = try world.addSparseTile(0, x, 0, deco, 0, .effect);
    _ = try world.addSparseTile(0, 7, 7, deco, 0, .effect);
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 3 * meta.tileSize(), .h = meta.tileSize() }, 0, 0);
    try std.testing.expectEqual(@as(usize, 3), world.reserveRenderRecords());
    const player_entity = try EntityId.init(0, 1);

    try std.testing.expectEqual(
        @as(usize, 3) + 1 + 1 + 1 + Renderer.k_stacked_state_ui_headroom,
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

test "static geometry capacity covers one span per resident layer" {
    var meta = try testWorldTilesetMeta();
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(std.testing.allocator, &meta, 64, 64);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    for (1..5) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }
    world.render_window = .{ .levels_below = 3 };
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 64, .h = 64 }, 0, 0);
    const scene = GameplayScene{
        .data = undefined,
        .world = &world,
        .player_entity = try EntityId.init(0, 1),
        .player_level = 0,
        .particles = undefined,
        .overscan_chunks = 0,
    };
    var renderer = headlessRendererForTest(std.testing.allocator);
    defer deinitHeadlessRendererForTest(&renderer);
    try fakeTileStoreForTest(&renderer, &world);

    // Nothing resident before the first sync.
    try std.testing.expectEqual(@as(usize, 0), staticGeometryCapacity(scene).span_capacity);
    try world.syncDenseTileStore(&renderer, 0);
    const capacity = staticGeometryCapacity(scene);
    try std.testing.expectEqual(@as(usize, 4), capacity.span_capacity);
    try std.testing.expectEqual(capacity.span_capacity * 6, capacity.vertex_capacity);
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
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 2048, .h = 2048 }, 0, 0);

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
            particles.activeCount() + Renderer.k_stacked_state_ui_headroom,
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
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 256, .h = 256 }, 0, 0);

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
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 256, .h = 256 }, 0, 0);

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

// Registers a store with no GPU buffer in a headless renderer and hands it to
// `world`, laid out for its render window (set first), so `syncDenseTileStore`
// validates and queues uploads without touching SDL. The capacity covers any test
// world, so no sync grows it.
fn fakeTileStoreForTest(renderer: *Renderer, world: *WorldSystem) !void {
    std.debug.assert(world.visible_window_set);
    try renderer.tile_stores.append(renderer.allocator, .{
        .buffer = @ptrFromInt(0x1000),
        .element_capacity = 1 << 20,
        .params = std.mem.zeroes(renderer_mod.TilemapParams),
    });
    // A test renderer holds a handful of fresh slots, all at generation 1.
    world.gpu_tiles.store = .{ .index = @intCast(renderer.tile_stores.items.len - 1), .generation = 1 };
    world.gpu_tiles.store_side = world.render_side;
}

// Headless Renderer: device/pipeline/sampler are never dereferenced by the CPU-only
// static-geometry and tile-store queue paths.
fn headlessRendererForTest(allocator: std.mem.Allocator) Renderer {
    return .{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = @import("../render/sprite_batch.zig").SpriteBatch.init(allocator),
    };
}

fn deinitHeadlessRendererForTest(renderer: *Renderer) void {
    const allocator = renderer.allocator;
    renderer.batch.deinit();
    renderer.static_positions.deinit(allocator);
    renderer.static_uvs.deinit(allocator);
    renderer.static_colors.deinit(allocator);
    renderer.static_groups.deinit(allocator);
    renderer.tilemap_window_layers.deinit(allocator);
    renderer.draw_list.deinit(allocator);
    for (renderer.tile_stores.items) |*store| {
        store.pending_spans.deinit(allocator);
        store.pending_values.deinit(allocator);
    }
    renderer.tile_stores.deinit(allocator);
    renderer.tile_merge_spans.deinit(allocator);
    renderer.tile_merge_values.deinit(allocator);
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
    // A sparse tile on the deeper, non-active level.
    // Neither `active_level` special-casing nor the old per-layer-draw design
    // needed this; the general interleave-point rule is what must catch it.
    _ = try world.addSparseTile(level1, 0, 0, tree, 0, .effect);
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 128, .h = 128 }, 0, 0);

    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));

    const Material = renderer_mod.Material;
    const DrawGroup = renderer_mod.DrawGroup;
    const mergeDrawList = renderer_mod.mergeDrawList;

    var renderer = headlessRendererForTest(allocator);
    defer deinitHeadlessRendererForTest(&renderer);
    try fakeTileStoreForTest(&renderer, &world);

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
    try std.testing.expectEqual(Material.tilemap, renderer.static_groups.items[0].material);
    try std.testing.expectEqual(Material.tilemap, renderer.static_groups.items[1].material);
    // The deeper level (holding the sparse tile) composites first (further
    // back); the shallower level composites last (in front) — the sparse tile's
    // own dynamic draw sits between them in the merged list.
    try std.testing.expect(renderer.static_groups.items[0].order.depth < renderer.static_groups.items[1].order.depth);

    var merged: std.ArrayList(DrawGroup) = .empty;
    defer merged.deinit(allocator);
    try mergeDrawList(&merged, allocator, renderer.static_groups.items, &.{});
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
}

test "window sparse depths cut dense composites at any in-window level; a sparse tile outside the window cuts none" {
    const allocator = std.testing.allocator;
    var meta = try testWorldTilesetMeta();
    defer meta.deinit();
    // 64x64 tiles in 16-cell chunks; a deeper level under the surface.
    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, 64 * 32, 64 * 32);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    const tree = try world.requireTileByName(&meta, "tree_0");
    const level1 = try world.addLevel(-level_z_step);
    _ = try world.addDenseLayer(level1, 0, .floor, grass);
    // On the deeper level, in the far corner chunk.
    _ = try world.addSparseTile(level1, 60, 60, tree, 0, .effect);
    const near = Rect{ .x = 0, .y = 0, .w = 128, .h = 128 };
    const far = Rect{ .x = 58 * 32, .y = 58 * 32, .w = 128, .h = 128 };
    try world.setVisibleChunksForWorldRect(near, 0, 0);

    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));
    var renderer = headlessRendererForTest(allocator);
    defer deinitHeadlessRendererForTest(&renderer);
    try fakeTileStoreForTest(&renderer, &world);
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

    // Outside the window: one composite draw for both levels.
    try submitLayeredWorld(scene, &prep, &renderer, &runtime_assets);
    try std.testing.expectEqual(@as(usize, 2), world.maxDenseSubmitDrawCount());
    try std.testing.expectEqual(@as(usize, 1), renderer.static_groups.items.len);

    // In the window: its depth cuts the two levels apart.
    renderer.batch.beginFrame();
    renderer.tile_stores.items[0].pending_spans.clearRetainingCapacity();
    renderer.tile_stores.items[0].pending_values.clearRetainingCapacity();
    try world.setVisibleChunksForWorldRect(far, 0, 0);
    try submitLayeredWorld(scene, &prep, &renderer, &runtime_assets);
    try std.testing.expectEqual(@as(usize, 2), renderer.static_groups.items.len);
}

test "dense composite bucketing keeps every needed cut regardless of how many redundant interleave candidates exist" {
    const allocator = std.testing.allocator;
    var meta = try testWorldTilesetMeta();
    defer meta.deinit();

    // Surface level (0) plus 39 deeper levels: 40 resident layers and 39 gaps.
    const level_count = 40;
    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, 64, 64);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    var extra_level_index: u16 = 1;
    while (extra_level_index < level_count) : (extra_level_index += 1) {
        const level = try world.addLevel(-@as(i32, @intCast(extra_level_index)) * level_z_step);
        _ = try world.addDenseLayer(level, 0, .floor, grass);
    }
    world.render_window = .{ .levels_below = level_count };

    const num_gaps = level_count - 1;
    // Feed 3 candidates per gap (2 dynamic, 1 sparse): far more raw distinct depths
    // than gaps, which a value-keyed dedup into one slot per gap could not hold.
    var prep = DynamicScenePrep.init(allocator);
    defer prep.deinit();
    try prep.depth_spans.ensureTotalCapacity(allocator, 2 * num_gaps);
    for (0..num_gaps) |gap_index| {
        // Gap `gap_index` sits between the layer at level `level_count - 1 -
        // gap_index` and the next shallower one; its own depth is `level_base_z -
        // 2` (.floor band).
        const deeper_level_index: i32 = @intCast(level_count - 1 - gap_index);
        const gap_start_depth = -deeper_level_index * level_z_step - 2;
        prep.depth_spans.appendAssumeCapacity(.{ .start = 0, .end = 0, .depth = gap_start_depth + 4 });
        prep.depth_spans.appendAssumeCapacity(.{ .start = 0, .end = 0, .depth = gap_start_depth + 10 });
        _ = try world.addSparseTile(0, 0, 0, grass, gap_start_depth + 13, .effect);
    }
    try world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 64, .h = 64 }, 0, 0);

    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));
    var renderer = headlessRendererForTest(allocator);
    defer deinitHeadlessRendererForTest(&renderer);
    try fakeTileStoreForTest(&renderer, &world);

    const scene = GameplayScene{
        .data = undefined,
        .world = &world,
        .player_entity = try EntityId.init(0, 1),
        .player_level = 0,
        .particles = undefined,
        .overscan_chunks = 0,
    };

    // One composite draw per resident layer: every one of the `num_gaps` cuts
    // survived despite 3x as many raw candidate depths feeding the collector.
    try submitLayeredWorld(scene, &prep, &renderer, &runtime_assets);
    try std.testing.expectEqual(@as(usize, level_count), renderer.static_groups.items.len);
}

test "a warmed layered-world frame allocates nothing across a pan and a level change (FailingAllocator)" {
    const allocator = std.testing.allocator;
    var meta = try testWorldTilesetMeta();
    defer meta.deinit();
    // 64x64 tiles in 16-cell chunks (a 4x4 grid) on four levels, every chunk mixed.
    var world = try WorldSystem.initDemoFromMeta(allocator, &meta, 64 * 32, 64 * 32);
    defer world.deinit();
    const grass = try world.requireTileByName(&meta, "grass");
    const tree = try world.requireTileByName(&meta, "tree_0");
    for (1..4) |level_index| {
        const level = try world.addLevel(-@as(i32, @intCast(level_index)) * level_z_step);
        const layer = try world.addDenseLayer(level, 0, .floor, grass);
        for (0..4) |chunk_y| for (0..4) |chunk_x| {
            _ = try world.clearDenseTile(layer, @intCast(chunk_x * 16 + 3), @intCast(chunk_y * 16 + 5));
        };
    }
    // A sparse tile between levels 2 and 3, in the chunk both windows share, cuts
    // the stack into two draws.
    _ = try world.addSparseTile(3, 17, 1, tree, level_z_step - 1, .effect);
    world.render_window = .{ .levels_below = 3 };
    const chunk_px: f32 = 16 * 32;
    const left = Rect{ .x = 0, .y = 0, .w = 2 * chunk_px, .h = 2 * chunk_px };
    const right = Rect{ .x = chunk_px, .y = 0, .w = 2 * chunk_px, .h = 2 * chunk_px };
    try world.setVisibleChunksForWorldRect(left, 0, 0);

    var runtime_assets = RuntimeAssets.init(allocator);
    setSpriteAvailableForTest(&runtime_assets, .world_tileset, try TextureId.init(1, 1));
    var renderer = headlessRendererForTest(allocator);
    defer deinitHeadlessRendererForTest(&renderer);
    try fakeTileStoreForTest(&renderer, &world);
    var prep = DynamicScenePrep.init(allocator);
    defer prep.deinit();

    const frames = [_]struct { rect: Rect, level: u16 }{
        .{ .rect = left, .level = 0 },
        .{ .rect = right, .level = 0 },
        .{ .rect = right, .level = 1 },
        .{ .rect = left, .level = 0 },
        .{ .rect = right, .level = 1 },
    };
    for (frames, 0..) |frame, index| {
        // The last frame pans and changes level under a failing allocator.
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        const last = index + 1 == frames.len;
        if (last) {
            world.allocator = failing.allocator();
            renderer.allocator = failing.allocator();
        }
        defer {
            world.allocator = allocator;
            renderer.allocator = allocator;
        }
        renderer.batch.beginFrame();
        try world.setVisibleChunksForWorldRect(frame.rect, 0, frame.level);
        const scene = GameplayScene{
            .data = undefined,
            .world = &world,
            .player_entity = try EntityId.init(0, 1),
            .player_level = frame.level,
            .particles = undefined,
            .overscan_chunks = 0,
        };
        try submitLayeredWorld(scene, &prep, &renderer, &runtime_assets);
        // The frame copy pass drains the store's queued uploads.
        renderer.tile_stores.items[0].pending_spans.clearRetainingCapacity();
        renderer.tile_stores.items[0].pending_values.clearRetainingCapacity();
        if (last) {
            try std.testing.expectEqual(@as(usize, 0), failing.allocations);
            try std.testing.expect(!failing.has_induced_failure);
        }
    }
    // Level 1 and below are resident and the sparse tile splits them.
    try std.testing.expectEqual(@as(usize, 3), world.maxDenseSubmitDrawCount());
    try std.testing.expectEqual(@as(usize, 2), renderer.static_groups.items.len);
}
