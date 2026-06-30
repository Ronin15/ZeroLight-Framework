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
const MovementBody = @import("data_system.zig").MovementBody;
const PrimitiveVisual = @import("data_system.zig").PrimitiveVisual;
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
const ActiveRegion = @import("simulation_scope.zig").ActiveRegion;
const ParticleSystem = @import("systems/particle.zig").ParticleSystem;
const ConstParticleSlice = @import("systems/particle.zig").ConstParticleSlice;
const world_tileset_meta = @import("../assets/world_tileset_meta.zig");

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

pub fn submitEntity(
    renderer: *Renderer,
    data: *const DataSystem,
    entity: EntityId,
    runtime_assets: *const RuntimeAssets,
    interpolation_alpha: f32,
) !void {
    const draw = prepareEntity(data, entity, runtime_assets, interpolation_alpha) orelse return;
    try submitPreparedDraw(renderer, draw);
}

pub fn prepareEntity(
    data: *const DataSystem,
    entity: EntityId,
    runtime_assets: *const RuntimeAssets,
    interpolation_alpha: f32,
) ?PreparedDraw {
    const body = data.movementBodyConst(entity) orelse return null;
    const visual = data.primitiveVisualConst(entity) orelse return null;
    return preparePrimitiveVisual(
        body,
        visual,
        data.assetReferenceConst(entity),
        runtime_assets,
        interpolation_alpha,
    );
}

pub fn preparePrimitiveVisual(
    body: MovementBody,
    visual: PrimitiveVisual,
    asset_ref: ?AssetReference,
    runtime_assets: *const RuntimeAssets,
    interpolation_alpha: f32,
) ?PreparedDraw {
    const render_position = math.lerpVec2(body.previous_position, body.position, interpolation_alpha);
    const dest = Rect{
        .x = render_position.x,
        .y = render_position.y,
        .w = visual.size.x,
        .h = visual.size.y,
    };
    const order = worldOrder(body.position_z, visual.depth);

    if (asset_ref) |ref| {
        if (runtime_assets.sprite(ref.sprite)) |sprite| {
            const source = sourceRectForAsset(runtime_assets, ref, sprite.source_rect) orelse if (ref.hasAtlasEntry())
                null
            else
                sprite.source_rect;
            if (!ref.hasAtlasEntry() or source != null) {
                return .{ .sprite = .{
                    .texture = sprite.texture,
                    .source = source,
                    .dest = dest,
                    .tint = visual.color,
                    .order = order,
                } };
            }
        }
    }

    return .{ .rect = .{ .rect = dest, .color = visual.color, .order = order } };
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
    for (visuals.entities, 0..) |entity, visual_index| {
        const indices = scene.data.renderEntityComponentIndices(entity) orelse continue;
        const movement_index = indices.movement_body;
        const is_player = entity.index == player_entity_index and entity.generation == player_entity_generation;
        if (!entityChunkVisibleForCollect(is_player, movement_index, scope, visible_chunks)) continue;

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
        if (!is_player and !visible.overlapsAabb(render_x, render_y, size_x, size_y)) continue;

        if (indices.asset_ref) |asset_index| {
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
            if (indices.facing) |facing_index| {
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
        prep.appendAssumeCapacity(.{
            .depth = particles.z[index],
            .draw = .{ .rect = .{
                .rect = .{
                    .x = render_x - half_size,
                    .y = render_y - half_size,
                    .w = particle_size,
                    .h = particle_size,
                },
                .color = .{
                    .r = particles.color_r[index],
                    .g = particles.color_g[index],
                    .b = particles.color_b[index],
                    .a = particles.color_a[index],
                },
                .order = RenderOrder.world(particles.z[index]),
            } },
        });
    }
    prep.finalizeDepthBuckets();
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
    while (sparse_depth != null or dynamic_depth != null) {
        if (sparse_depth) |depth| {
            if (dynamic_depth == null or depth <= dynamic_depth.?) {
                try scene.world.submitVisibleSparseAtDepth(renderer, runtime_assets, depth);
                sparse_depth = scene.world.nextVisibleSparseDepthAfter(depth);
                continue;
            }
        }

        const dynamic_range = prep.depth_spans.items[dynamic_span_index - 1];
        const sorted_indices = prep.sort_indices.items;
        const records = prep.records.items;
        for (sorted_indices[dynamic_range.start..dynamic_range.end]) |record_index| {
            try submitPreparedDraw(renderer, records[record_index].draw);
        }
        dynamic_depth = nextDynamicDepth(prep, &dynamic_span_index);
    }
}

fn nextDynamicDepth(prep: *const DynamicScenePrep, span_index: *usize) ?i32 {
    if (span_index.* >= prep.depth_spans.items.len) return null;
    const depth = prep.depth_spans.items[span_index.*].depth;
    span_index.* += 1;
    return depth;
}

pub fn preparePlayerMarker(data: *const DataSystem, entity: EntityId, interpolation_alpha: f32) ?PreparedDraw {
    const indices = data.renderEntityComponentIndices(entity) orelse return null;
    const visual_index = data.primitiveVisualDenseIndex(entity) orelse return null;
    const facing_index = indices.facing orelse return null;
    const movement = data.movementBodySliceConst();
    const movement_index = indices.movement_body;
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
    return preparePlayerMarkerSoA(
        movement,
        data.primitiveVisualSliceConst(),
        movement_index,
        visual_index,
        data.facingSliceConst().directions[facing_index],
        render_x,
        render_y,
    );
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

pub fn prepareParticle(particles: ConstParticleSlice, index: usize, interpolation_alpha: f32) ?PreparedDraw {
    if (index >= particles.len() or !particles.renderable(index)) return null;
    const render_x = math.lerp(particles.previous_x[index], particles.position_x[index], interpolation_alpha);
    const render_y = math.lerp(particles.previous_y[index], particles.position_y[index], interpolation_alpha);
    return prepareParticleAt(particles, index, render_x, render_y);
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

/// Coarse camera-chunk gate before interpolation and draw prep. Uses the world's
/// render visibility window (same source as sparse tiles), not simulation-scope
/// tier/pathfinding policy. Callers must set world visibility before collect;
/// when the window is unset, non-player entities are skipped.
fn entityChunkVisibleForCollect(
    is_player: bool,
    movement_index: usize,
    scope: ConstScopeColumnsSlice,
    visible_chunks: ?ActiveRegion,
) bool {
    if (is_player) return true;
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

const ScenePrepFixture = struct {
    data: DataSystem,
    particles: ParticleSystem,
    world: WorldSystem,
    scene_prep: DynamicScenePrep,
    player_entity: EntityId,
    actor_entity: EntityId,
    obstacle_entity: EntityId,
    bounds_width: f32,
    bounds_height: f32,

    fn deinit(self: *ScenePrepFixture) void {
        self.scene_prep.deinit();
        self.particles.deinit();
        self.world.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    fn scene(self: *ScenePrepFixture) GameplayScene {
        return .{
            .data = &self.data,
            .world = &self.world,
            .player_entity = self.player_entity,
            .player_level = 0,
            .particles = &self.particles,
            .overscan_chunks = 0,
        };
    }

    fn fullBoundsVisible(self: *const ScenePrepFixture) VisibleWorldRect {
        return .{
            .min_x = 0,
            .min_y = 0,
            .max_x = self.bounds_width,
            .max_y = self.bounds_height,
        };
    }

    fn collect(self: *ScenePrepFixture, visible: VisibleWorldRect, interpolation_alpha: f32) !void {
        var runtime_assets = RuntimeAssets.init();
        try collectDynamicRecords(&self.scene_prep, self.scene(), visible, &runtime_assets, interpolation_alpha);
    }
};

fn initScenePrepFixture(allocator: std.mem.Allocator, bounds_width: f32, bounds_height: f32) !ScenePrepFixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();

    const player_entity = try spawnPlayerEntity(&data);
    const actor_entity = try spawnActorEntity(&data, .{ .x = 80, .y = 80 }, .actor);
    const obstacle_entity = try spawnActorEntity(&data, .{ .x = 462, .y = 215 }, .obstacle);

    var particles = try ParticleSystem.init(allocator, .{ .capacity = 512 });
    errdefer particles.deinit();

    const asset_store = AssetStore.init(allocator, std.testing.io, "assets");
    const meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
    var world = try WorldSystem.initDemoFromMetaWithUnderground(allocator, &meta, bounds_width, bounds_height);
    errdefer world.deinit();
    world.adoptTilesetMeta(meta);
    world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = bounds_width, .h = bounds_height }, 0);

    var scene_prep = DynamicScenePrep.init(allocator);
    errdefer scene_prep.deinit();
    try ensureScenePrepCapacity(&scene_prep, .{
        .data = &data,
        .world = &world,
        .player_entity = player_entity,
        .player_level = 0,
        .particles = &particles,
        .overscan_chunks = 0,
    });

    return .{
        .data = data,
        .particles = particles,
        .world = world,
        .scene_prep = scene_prep,
        .player_entity = player_entity,
        .actor_entity = actor_entity,
        .obstacle_entity = obstacle_entity,
        .bounds_width = bounds_width,
        .bounds_height = bounds_height,
    };
}

fn spawnActorEntity(data: *DataSystem, position: math.Vec2, depth: WorldDepth) !EntityId {
    const entity = try data.createEntity();
    errdefer _ = data.destroyEntity(entity);
    try data.setMovementBody(entity, .{
        .position = position,
        .previous_position = position,
        .velocity = .{},
        .speed = 0,
    });
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 24, .y = 24 },
        .color = .{ .r = 0.5, .g = 0.6, .b = 0.7, .a = 1 },
        .depth = depth,
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .marker_depth_band = .marker,
        .marker_length = 0,
        .marker_depth = 0,
        .marker_margin = 0,
    });
    return entity;
}

fn spawnPlayerEntity(data: *DataSystem) !EntityId {
    const entity = try data.createEntity();
    errdefer _ = data.destroyEntity(entity);
    try data.setMovementBody(entity, .{
        .position = .{ .x = 400, .y = 225 },
        .previous_position = .{ .x = 400, .y = 225 },
        .velocity = .{},
        .speed = 120,
    });
    try data.setFacing(entity, .{ .direction = .down });
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 32, .y = 32 },
        .color = .{ .r = 1.0, .g = 0.8, .b = 0.36, .a = 1.0 },
        .depth = .actor,
        .marker_color = .{ .r = 0.8, .g = 0.56, .b = 0.22, .a = 1.0 },
        .marker_depth_band = .actor,
        .marker_length = 12,
        .marker_depth = 6,
        .marker_margin = 4,
    });
    return entity;
}

fn drawMatchesEntityPosition(draw: PreparedDraw, x: f32, y: f32) bool {
    const dest = switch (draw) {
        .sprite => |sprite| sprite.dest,
        .rect => |rect| rect.rect,
    };
    return dest.x == x and dest.y == y;
}

fn drawMatchesPlayerMarker(draw: PreparedDraw) bool {
    return switch (draw) {
        .rect => |rect| rect.rect.w == 12 or rect.rect.h == 12,
        .sprite => false,
    };
}

fn drawMatchesParticleCenter(draw: PreparedDraw, x: f32, y: f32) bool {
    const center = switch (draw) {
        .rect => |rect| math.Vec2{
            .x = rect.rect.x + rect.rect.w * 0.5,
            .y = rect.rect.y + rect.rect.h * 0.5,
        },
        .sprite => |sprite| math.Vec2{
            .x = sprite.dest.x + sprite.dest.w * 0.5,
            .y = sprite.dest.y + sprite.dest.h * 0.5,
        },
    };
    return center.x == x and center.y == y;
}

test "dynamic scene prep preserves mixed world z order" {
    var fixture = try initScenePrepFixture(std.testing.allocator, 800, 450);
    defer fixture.deinit();

    const high_obstacle = fixture.data.movementBodyPtr(fixture.obstacle_entity).?;
    high_obstacle.position_z.* = 20;
    high_obstacle.previous_z.* = 20;
    const low_actor = fixture.data.movementBodyPtr(fixture.actor_entity).?;
    low_actor.position_z.* = -20;
    low_actor.previous_z.* = -20;

    const low_actor_order = worldOrder(-20, .actor);
    const high_obstacle_order = worldOrder(20, .obstacle);
    try fixture.collect(fixture.fullBoundsVisible(), 1.0);
    var low_actor_seen = false;
    var high_obstacle_seen = false;
    var low_actor_index: usize = 0;
    var high_obstacle_index: usize = 0;
    for (fixture.scene_prep.sortedRecordIndices(), 0..) |record_index, sorted_index| {
        const depth = fixture.scene_prep.records.items[record_index].draw.depth();
        if (depth == low_actor_order.depth and !low_actor_seen) {
            low_actor_seen = true;
            low_actor_index = sorted_index;
        }
        if (depth == high_obstacle_order.depth and !high_obstacle_seen) {
            high_obstacle_seen = true;
            high_obstacle_index = sorted_index;
        }
    }

    try std.testing.expect(low_actor_order.depth < high_obstacle_order.depth);
    try std.testing.expect(low_actor_seen);
    try std.testing.expect(high_obstacle_seen);
    try std.testing.expect(low_actor_index < high_obstacle_index);
}

test "dynamic scene prep includes particles in z order" {
    var fixture = try initScenePrepFixture(std.testing.allocator, 800, 450);
    defer fixture.deinit();

    try std.testing.expect(fixture.particles.emit(.{
        .base_z = 50,
        .depth = .effect,
        .start_size = 4,
    }));
    try std.testing.expect(fixture.particles.emit(.{
        .base_z = -50,
        .depth = .effect,
        .start_size = 4,
    }));

    try fixture.collect(fixture.fullBoundsVisible(), 1.0);
    var previous_depth: i32 = std.math.minInt(i32);
    var particle_count: usize = 0;
    for (fixture.scene_prep.depth_spans.items) |span| {
        try std.testing.expect(previous_depth <= span.depth);
        previous_depth = span.depth;
    }
    const effect_depth_50 = worldOrder(50, .effect).depth;
    const effect_depth_neg_50 = worldOrder(-50, .effect).depth;
    for (fixture.scene_prep.records.items) |record| {
        const depth = record.draw.depth();
        if (depth == effect_depth_50 or depth == effect_depth_neg_50) particle_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), particle_count);
}

test "dynamic scene prep culls entities outside the visible chunk region before draw prep" {
    var fixture = try initScenePrepFixture(std.testing.allocator, 800, 450);
    defer fixture.deinit();

    const actor_chunk: i32 = 40;
    try fixture.data.setSimulationMetadata(fixture.actor_entity, .{
        .chunk = .{ .x = actor_chunk, .y = actor_chunk },
    });
    const actor_body = fixture.data.movementBodyPtr(fixture.actor_entity).?;
    actor_body.position_x.* = 80;
    actor_body.position_y.* = 80;
    actor_body.previous_x.* = 80;
    actor_body.previous_y.* = 80;

    const obstacle_body = fixture.data.movementBodyPtr(fixture.obstacle_entity).?;
    const obstacle_x = obstacle_body.position_x.*;
    const obstacle_y = obstacle_body.position_y.*;
    try fixture.data.setSimulationMetadata(fixture.obstacle_entity, .{
        .chunk = .{ .x = 0, .y = 0 },
    });

    fixture.world.setVisibleChunksForWorldRect(.{ .x = 0, .y = 0, .w = 160, .h = 160 }, 0);

    try fixture.collect(.{
        .min_x = 0,
        .min_y = 0,
        .max_x = 800,
        .max_y = 450,
    }, 1.0);

    var offscreen_actor_seen = false;
    var onscreen_obstacle_seen = false;
    for (fixture.scene_prep.records.items) |record| {
        const draw = record.draw;
        if (drawMatchesEntityPosition(draw, 80, 80)) offscreen_actor_seen = true;
        if (drawMatchesEntityPosition(draw, obstacle_x, obstacle_y)) onscreen_obstacle_seen = true;
    }

    try std.testing.expect(!offscreen_actor_seen);
    try std.testing.expect(onscreen_obstacle_seen);
}

test "dynamic scene prep culls entities and particles outside the visible rect" {
    var fixture = try initScenePrepFixture(std.testing.allocator, 800, 450);
    defer fixture.deinit();

    const offscreen_body = fixture.data.movementBodyPtr(fixture.actor_entity).?;
    offscreen_body.position_x.* = 5000;
    offscreen_body.position_y.* = 5000;
    offscreen_body.previous_x.* = 5000;
    offscreen_body.previous_y.* = 5000;

    const onscreen_body = fixture.data.movementBodyPtr(fixture.obstacle_entity).?;
    const onscreen_x = onscreen_body.position_x.*;
    const onscreen_y = onscreen_body.position_y.*;

    const player_body = fixture.data.movementBodyPtr(fixture.player_entity).?;
    player_body.position_x.* = 9000;
    player_body.position_y.* = 9000;
    player_body.previous_x.* = 9000;
    player_body.previous_y.* = 9000;

    try std.testing.expect(fixture.particles.emit(.{
        .position = .{ .x = 5000, .y = 5000 },
        .base_z = 0,
        .depth = .effect,
        .start_size = 4,
    }));
    try std.testing.expect(fixture.particles.emit(.{
        .position = .{ .x = onscreen_x, .y = onscreen_y },
        .base_z = 0,
        .depth = .effect,
        .start_size = 4,
    }));

    const visible = VisibleWorldRect{
        .min_x = 0,
        .min_y = 0,
        .max_x = 800,
        .max_y = 450,
    };
    try fixture.collect(visible, 1.0);

    var offscreen_actor_seen = false;
    var onscreen_obstacle_seen = false;
    var player_body_seen = false;
    var player_marker_seen = false;
    var offscreen_particle_seen = false;
    var onscreen_particle_seen = false;
    for (fixture.scene_prep.records.items) |record| {
        const draw = record.draw;
        if (drawMatchesEntityPosition(draw, 5000, 5000)) offscreen_actor_seen = true;
        if (drawMatchesEntityPosition(draw, onscreen_x, onscreen_y)) onscreen_obstacle_seen = true;
        if (drawMatchesEntityPosition(draw, 9000, 9000)) player_body_seen = true;
        if (drawMatchesPlayerMarker(draw)) player_marker_seen = true;
        if (drawMatchesParticleCenter(draw, 5000, 5000)) offscreen_particle_seen = true;
        if (drawMatchesParticleCenter(draw, onscreen_x, onscreen_y)) onscreen_particle_seen = true;
    }

    try std.testing.expect(!offscreen_actor_seen);
    try std.testing.expect(onscreen_obstacle_seen);
    try std.testing.expect(player_body_seen);
    try std.testing.expect(player_marker_seen);
    try std.testing.expect(!offscreen_particle_seen);
    try std.testing.expect(onscreen_particle_seen);
}

test "sprite command capacity tracks visual entity growth" {
    const created_visual_count = 528;
    var fixture = try initScenePrepFixture(std.testing.allocator, 800, 450);
    defer fixture.deinit();

    for (0..created_visual_count) |index| {
        const x: f32 = @floatFromInt(index % 64);
        const y: f32 = @floatFromInt(index / 64);
        const entity = try fixture.data.createEntity();
        try fixture.data.setMovementBody(entity, .{
            .position = .{ .x = x, .y = y },
            .previous_position = .{ .x = x, .y = y },
        });
        try fixture.data.setPrimitiveVisual(entity, .{
            .size = .{ .x = 1, .y = 1 },
            .color = .{ .r = 0.5, .g = 0.6, .b = 0.7, .a = 1 },
            .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        });
    }

    try std.testing.expect(fixture.particles.emit(.{
        .position = .{ .x = 10, .y = 10 },
        .start_size = 4,
        .start_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    }));

    try std.testing.expectEqual(
        fixture.world.reserveRenderRecords() +
            fixture.data.primitiveVisualSliceConst().entities.len +
            1 +
            fixture.particles.activeCount() +
            Renderer.kStackedStateUiHeadroom,
        spriteCommandCapacity(fixture.scene()),
    );
}

test "layered sparse and dynamic walk preserves nondecreasing render order" {
    var fixture = try initScenePrepFixture(std.testing.allocator, 800, 450);
    defer fixture.deinit();

    try fixture.collect(fixture.fullBoundsVisible(), 0.5);

    var last_order: ?RenderOrder = null;
    var sparse_depth = fixture.world.firstVisibleSparseDepth();
    var dynamic_span_index: usize = 0;
    var dynamic_depth = nextDynamicDepth(&fixture.scene_prep, &dynamic_span_index);
    while (sparse_depth != null or dynamic_depth != null) {
        if (sparse_depth) |depth| {
            if (dynamic_depth == null or depth <= dynamic_depth.?) {
                const order = RenderOrder.world(depth);
                if (last_order) |previous| {
                    try std.testing.expect(previous.lessOrEqual(order));
                }
                last_order = order;
                sparse_depth = fixture.world.nextVisibleSparseDepthAfter(depth);
                continue;
            }
        }

        const dynamic_range = fixture.scene_prep.depth_spans.items[dynamic_span_index - 1];
        const sorted_indices = fixture.scene_prep.sort_indices.items;
        const records = fixture.scene_prep.records.items;
        for (sorted_indices[dynamic_range.start..dynamic_range.end]) |record_index| {
            const order = records[record_index].draw.renderOrder();
            if (last_order) |previous| {
                try std.testing.expect(previous.lessOrEqual(order));
            }
            last_order = order;
        }
        dynamic_depth = nextDynamicDepth(&fixture.scene_prep, &dynamic_span_index);
    }
    try std.testing.expect(last_order != null);
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

test "atlas-backed entity falls back to primitive rect without metadata" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 32, .y = 48 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    try data.setAssetReference(entity, .{ .sprite = .grim_characters, .atlas_entry_id = 0 });
    var runtime_assets = RuntimeAssets.init();
    setSpriteAvailableForTest(&runtime_assets, .grim_characters, try TextureId.init(1, 1));

    const draw = prepareEntity(&data, entity, &runtime_assets, 1.0) orelse return error.TestExpectedEqual;
    switch (draw) {
        .rect => {},
        .sprite => return error.TestExpectedEqual,
    }
}

test "atlas-backed entity uses metadata source rect when available" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{}, .previous_position = .{} });
    try data.setPrimitiveVisual(entity, .{
        .size = .{ .x = 32, .y = 48 },
        .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    });
    try data.setAssetReference(entity, .{ .sprite = .grim_characters, .atlas_entry_id = 0 });
    var runtime_assets = RuntimeAssets.init();
    runtime_assets.allocator = std.testing.allocator;
    setSpriteAvailableForTest(&runtime_assets, .grim_characters, try TextureId.init(1, 1));
    try setSpriteAtlasMetadataForTest(&runtime_assets, .grim_characters);
    defer deinitAtlasMetadataForTest(&runtime_assets, .grim_characters);

    const draw = prepareEntity(&data, entity, &runtime_assets, 1.0) orelse return error.TestExpectedEqual;
    const sprite = switch (draw) {
        .sprite => |sprite| sprite,
        .rect => return error.TestExpectedEqual,
    };
    const source = sprite.source orelse return error.TestExpectedEqual;
    const expected = runtime_assets.spriteAtlasMeta(.grim_characters).?.sourceRectForId(0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(expected.x, source.x);
    try std.testing.expectEqual(expected.y, source.y);
    try std.testing.expectEqual(expected.w, source.w);
    try std.testing.expectEqual(expected.h, source.h);
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

test "visible world rect culls entity aabb outside camera overscan but keeps player" {
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
