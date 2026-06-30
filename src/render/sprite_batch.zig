// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Ordered sprite command stream and CPU-side vertex preparation.
//! This module is not a broad sorter: callers submit in nondecreasing
//! RenderOrder, then SpriteBatch snapshots texture metadata before any worker
//! stage expands vertices.

const std = @import("std");
const builtin = @import("builtin");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const Camera2D = @import("camera.zig").Camera2D;
const config = @import("../config.zig");
const math = @import("../core/math.zig");
const ParallelRange = @import("../app/thread_system.zig").ParallelRange;
const resources = @import("resources.zig");
const simd = @import("../core/simd.zig");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../app/thread_system.zig").WorkerId;

pub const TextureId = resources.TextureId;

pub const Rect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const CoordinateSpace = enum {
    world,
    logical,
    drawable,
};

pub const RenderDomain = enum(u8) {
    world,
    ui,
    debug,
};

pub const UiDepth = enum(i32) {
    background,
    panel,
    highlight,
    text,
};

const ui_depth_stride: i32 = @intCast(std.meta.fields(UiDepth).len);

pub const UiStackOrder = struct {
    index: u16 = 0,

    pub const base: UiStackOrder = .{ .index = 0 };

    pub fn fromRenderOffset(offset: usize) UiStackOrder {
        return .{ .index = @intCast(@min(offset, std.math.maxInt(u16))) };
    }

    fn depthOffset(self: UiStackOrder) i32 {
        return @as(i32, @intCast(self.index)) * ui_depth_stride;
    }
};

pub const DebugDepth = enum(i32) {
    overlay,
};

pub const RenderOrder = struct {
    domain: RenderDomain = .world,
    depth: i32 = 0,

    pub fn world(z: i32) RenderOrder {
        return .{ .domain = .world, .depth = z };
    }

    pub fn ui(depth: UiDepth) RenderOrder {
        return uiInStack(.base, depth);
    }

    pub fn uiInStack(stack_order: UiStackOrder, depth: UiDepth) RenderOrder {
        return .{ .domain = .ui, .depth = stack_order.depthOffset() + @intFromEnum(depth) };
    }

    pub fn debug(depth: DebugDepth) RenderOrder {
        return .{ .domain = .debug, .depth = @intFromEnum(depth) };
    }

    pub fn lessOrEqual(lhs: RenderOrder, rhs: RenderOrder) bool {
        const lhs_domain = @intFromEnum(lhs.domain);
        const rhs_domain = @intFromEnum(rhs.domain);
        if (lhs_domain != rhs_domain) return lhs_domain < rhs_domain;
        return lhs.depth <= rhs.depth;
    }
};

pub const Sprite = struct {
    texture: TextureId,
    source: ?Rect = null,
    dest: Rect,
    tint: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    origin: math.Vec2 = .{},
    rotation: f32 = 0,
    order: RenderOrder = .{},
    coordinate_space: CoordinateSpace = .world,
};

pub const CoordinatePresentation = enum {
    // World geometry is emitted in world space; the renderer bakes the camera
    // into the vertex uniform at draw time. Logical/drawable keep their prior
    // viewport-relative meaning.
    world,
    logical,
    drawable,
};

// SoA vertex layout: three dense per-attribute columns, each its own GPU vertex
// buffer bound at a fixed slot. `[N]f32` arrays are tightly packed, so no extern.
// Mapping is fixed across every site: Position slot 0/loc 0/FLOAT2/pitch 8,
// Uv slot 1/loc 1/FLOAT2/pitch 8, VertexColor slot 2/loc 2/FLOAT4/pitch 16.
pub const Position = [2]f32;
pub const Uv = [2]f32;
pub const VertexColor = [4]f32;

// Mutable column views threaded into vertex emission (workers write disjoint
// ranges; the world builds 6-corner static spans).
pub const VertexColumns = struct {
    positions: []Position,
    uvs: []Uv,
    colors: []VertexColor,
};

// Read-only column views for upload/append paths.
pub const VertexColumnsConst = struct {
    positions: []const Position,
    uvs: []const Uv,
    colors: []const VertexColor,
};

// Which renderer-owned vertex buffer a draw group indexes. Dynamic groups index
// the per-frame streamed buffer; static groups index the renderer's retained
// slab. The renderer merges both into one order-sorted draw list.
pub const DrawSource = enum {
    dynamic,
    static,
};

// Which pipeline draws a group. `sprite` samples a texture per vertex UV (the
// default path). `tilemap` draws one world-space quad per dense layer and the
// fragment shader reads tile ids from a storage buffer, so a whole layer is one
// draw independent of world size.
pub const Material = enum {
    sprite,
    tilemap,
};

/// Fragment uniform (set 3) for a tilemap draw — world-constant grid + atlas
/// geometry. extern for a stable GPU layout matching `tilemap.frag.glsl`. Kept off
/// `DrawGroup` (looked up in the renderer by `tile_data`) so the per-frame draw-group
/// sort/coalesce/merge does not drag this payload through every sprite group.
pub const TilemapParams = extern struct {
    // x=tile_size, y=grid_width, z=grid_height, w=invalid_tile_id
    grid: [4]f32,
    // x=atlas_columns, y=atlas_width_px, z=atlas_height_px, w=atlas_tile_px
    atlas: [4]f32,
};

pub const DrawGroup = struct {
    source: DrawSource = .dynamic,
    material: Material = .sprite,
    texture: TextureId,
    presentation: CoordinatePresentation,
    order: RenderOrder = .{},
    first_vertex: u32,
    vertex_count: u32,
    // Tilemap-material groups only: the layer's storage-buffer handle. The grid/atlas
    // uniform lives in the renderer keyed by this id.
    tile_data: resources.TileDataId = .invalid,
};

pub const TextureResolver = struct {
    context: *const anyopaque,
    resolve: *const fn (*const anyopaque, TextureId) ?resources.TextureDesc,

    fn textureDesc(self: TextureResolver, id: TextureId) ?resources.TextureDesc {
        return self.resolve(self.context, id);
    }
};

pub const SpritePrepConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
};

pub const SpritePrepStats = struct {
    command_count: usize = 0,
    valid_sprite_count: usize = 0,
    skipped_invalid_count: usize = 0,
    vertex_count: usize = 0,
    draw_group_count: usize = 0,
    batch: BatchStats = .{},
};

pub const SpriteBatch = struct {
    pub const CommandList = std.ArrayList(SpriteCommand);

    allocator: std.mem.Allocator,
    commands: CommandList = .empty,
    prepared_commands: std.ArrayList(PreparedSpriteCommand) = .empty,
    positions: std.ArrayList(Position) = .empty,
    uvs: std.ArrayList(Uv) = .empty,
    colors: std.ArrayList(VertexColor) = .empty,
    draw_groups: std.ArrayList(DrawGroup) = .empty,
    frame_reserved: bool = false,
    camera: Camera2D = .{},
    last_order: ?RenderOrder = null,
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    last_prep_stats: SpritePrepStats = .{},

    pub fn init(allocator: std.mem.Allocator) SpriteBatch {
        return .{
            .allocator = allocator,
            .adaptive_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *SpriteBatch) void {
        self.commands.deinit(self.allocator);
        self.prepared_commands.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.uvs.deinit(self.allocator);
        self.colors.deinit(self.allocator);
        self.draw_groups.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn beginFrame(self: *SpriteBatch) void {
        self.commands.clearRetainingCapacity();
        self.positions.clearRetainingCapacity();
        self.uvs.clearRetainingCapacity();
        self.colors.clearRetainingCapacity();
        self.draw_groups.clearRetainingCapacity();
        self.prepared_commands.clearRetainingCapacity();
        self.frame_reserved = false;
        self.last_order = null;
        self.last_prep_stats = .{};
    }

    pub fn drawSprite(self: *SpriteBatch, sprite: Sprite) !void {
        if (self.last_order) |previous| {
            std.debug.assert(previous.lessOrEqual(sprite.order));
        }
        // Ordered submission keeps the renderer cheap: grouping can preserve
        // stream order instead of sorting every frame.
        if (self.frame_reserved) {
            if (self.commands.items.len >= self.commands.capacity) return error.SpriteCommandOverflow;
            self.commands.appendAssumeCapacity(.{ .sprite = sprite });
        } else {
            try self.commands.append(self.allocator, .{ .sprite = sprite });
        }
        self.last_order = sprite.order;
    }

    pub fn setCamera(self: *SpriteBatch, camera: Camera2D) void {
        self.camera = camera;
    }

    pub fn reserveStorage(
        self: *SpriteBatch,
        command_capacity: usize,
        vertex_capacity: usize,
        draw_group_capacity: usize,
    ) !void {
        errdefer self.deinit();
        try self.commands.ensureTotalCapacity(self.allocator, command_capacity);
        try self.prepared_commands.ensureTotalCapacity(self.allocator, command_capacity);
        try self.positions.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.uvs.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.colors.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.draw_groups.ensureTotalCapacity(self.allocator, draw_group_capacity);
    }

    pub fn ensureFrameStorage(self: *SpriteBatch) !void {
        const needed_vertices = try std.math.mul(usize, self.commands.items.len, 6);
        if (needed_vertices == 0) return;

        try self.prepared_commands.ensureTotalCapacity(self.allocator, self.commands.items.len);
        try self.positions.ensureTotalCapacity(self.allocator, needed_vertices);
        try self.uvs.ensureTotalCapacity(self.allocator, needed_vertices);
        try self.colors.ensureTotalCapacity(self.allocator, needed_vertices);
        try self.draw_groups.ensureTotalCapacity(self.allocator, self.commands.items.len);
    }

    pub fn buildSerial(self: *SpriteBatch, texture_resolver: TextureResolver) void {
        _ = self.build(texture_resolver, null, .{ .adaptive = false }) catch unreachable;
    }

    pub fn build(
        self: *SpriteBatch,
        texture_resolver: TextureResolver,
        thread_system: ?*ThreadSystem,
        prep_config: SpritePrepConfig,
    ) !SpritePrepStats {
        try self.ensureFrameStorage();
        return self.buildAssumeCapacity(texture_resolver, thread_system, prep_config);
    }

    /// Builds prepared vertices and draw groups without allocating. Callers must
    /// reserve storage for the current command count before entering this path.
    pub fn buildAssumeCapacity(
        self: *SpriteBatch,
        texture_resolver: TextureResolver,
        thread_system: ?*ThreadSystem,
        prep_config: SpritePrepConfig,
    ) SpritePrepStats {
        _ = self.snapshotCommandsAssumeCapacity(texture_resolver);
        const batch = self.emitVerticesAssumeCapacity(thread_system, prep_config);
        self.buildDrawGroupsAssumeCapacity();
        return self.finishPrepStats(batch);
    }

    /// Snapshots immutable texture metadata for worker-safe CPU prep without
    /// changing submission order. Callers must reserve for the current command count.
    pub fn snapshotCommandsAssumeCapacity(self: *SpriteBatch, texture_resolver: TextureResolver) usize {
        self.positions.clearRetainingCapacity();
        self.uvs.clearRetainingCapacity();
        self.colors.clearRetainingCapacity();
        self.draw_groups.clearRetainingCapacity();
        self.prepared_commands.clearRetainingCapacity();

        std.debug.assert(self.positions.capacity >= self.commands.items.len * 6);
        std.debug.assert(self.uvs.capacity >= self.commands.items.len * 6);
        std.debug.assert(self.colors.capacity >= self.commands.items.len * 6);
        std.debug.assert(self.draw_groups.capacity >= self.commands.items.len);
        std.debug.assert(self.prepared_commands.capacity >= self.commands.items.len);

        for (self.commands.items) |command| {
            const texture = texture_resolver.textureDesc(command.sprite.texture) orelse continue;
            self.prepared_commands.appendAssumeCapacity(.{
                .sprite = command.sprite,
                .texture_desc = texture,
            });
        }
        return self.prepared_commands.items.len;
    }

    /// Emits vertices for the prepared command snapshot. This is the only
    /// currently thread-schedulable render-prep phase.
    pub fn emitVerticesAssumeCapacity(
        self: *SpriteBatch,
        thread_system: ?*ThreadSystem,
        prep_config: SpritePrepConfig,
    ) BatchStats {
        const valid_count = self.prepared_commands.items.len;
        const vertex_count = valid_count * 6;
        setVertexCountAssumeCapacity(Position, &self.positions, vertex_count);
        setVertexCountAssumeCapacity(Uv, &self.uvs, vertex_count);
        setVertexCountAssumeCapacity(VertexColor, &self.colors, vertex_count);

        var batch: BatchStats = .{};
        if (valid_count > 0) {
            const columns = VertexColumns{
                .positions = self.positions.items,
                .uvs = self.uvs.items,
                .colors = self.colors.items,
            };
            // Worker jobs write disjoint vertex ranges derived from prepared
            // command indices. Draw groups remain serial because they depend on
            // ordered texture/presentation transitions.
            if (thread_system) |threads| {
                var system_config = prep_config;
                if (system_config.adaptive and system_config.adaptive_tuner == null and system_config.items_per_range == null) {
                    system_config.adaptive_tuner = &self.adaptive_tuner;
                }
                var context = SpritePrepJobContext{
                    .commands = self.prepared_commands.items,
                    .columns = columns,
                };
                // Align range boundaries to 4 commands (192/192/384 B per column,
                // all divisible by 64) so no worker range straddles a cache line in
                // any of the three columns — avoids false sharing on the seams.
                batch = threads.parallelForWithOptions(valid_count, &context, writePreparedSpritesJob, .{
                    .items_per_range = system_config.items_per_range,
                    .max_worker_threads = system_config.max_worker_threads,
                    .range_alignment_items = 4,
                    .adaptive = system_config.adaptive,
                    .adaptive_tuner = system_config.adaptive_tuner,
                });
            } else {
                fillPreparedRange(self.prepared_commands.items, columns, .{
                    .start = 0,
                    .end = valid_count,
                });
                batch = .{
                    .item_count = valid_count,
                    .range_count = 1,
                    .items_per_range = valid_count,
                    .main_thread_ranges = 1,
                    .ran_inline = true,
                };
            }
        }
        return batch;
    }

    pub fn buildDrawGroupsAssumeCapacity(self: *SpriteBatch) void {
        self.buildDrawGroups();
    }

    pub fn finishPrepStats(self: *SpriteBatch, batch: BatchStats) SpritePrepStats {
        self.last_prep_stats = .{
            .command_count = self.commands.items.len,
            .valid_sprite_count = self.prepared_commands.items.len,
            .skipped_invalid_count = self.commands.items.len - self.prepared_commands.items.len,
            .vertex_count = self.positions.items.len,
            .draw_group_count = self.draw_groups.items.len,
            .batch = batch,
        };
        return self.last_prep_stats;
    }

    pub fn lastPrepStats(self: *const SpriteBatch) SpritePrepStats {
        return self.last_prep_stats;
    }

    fn buildDrawGroups(self: *SpriteBatch) void {
        self.draw_groups.clearRetainingCapacity();

        var active_texture: ?TextureId = null;
        var active_presentation: CoordinatePresentation = .logical;
        var active_order: RenderOrder = .{};
        var active_first_vertex: u32 = 0;
        var active_vertex_count: u32 = 0;

        for (self.prepared_commands.items, 0..) |command, prepared_index| {
            const first_vertex: u32 = @intCast(prepared_index * 6);
            const group_presentation = presentationForCoordinateSpace(command.sprite.coordinate_space);

            // Break on order change as well as texture/presentation so every group
            // is order-homogeneous. A same-texture run spanning multiple depths must
            // not collapse into one group keyed at its lowest depth, or a static
            // (dense tilemap) span whose order lands inside that range could no
            // longer interleave between the run's depths in the merged draw list.
            // Contiguous same-order groups re-coalesce in the renderer when nothing
            // interleaves, so this does not inflate the steady-state draw count.
            if (active_texture == null or
                !textureIdsEqual(active_texture.?, command.sprite.texture) or
                active_presentation != group_presentation or
                !renderOrdersEqual(active_order, command.sprite.order))
            {
                if (active_texture) |texture| {
                    self.draw_groups.appendAssumeCapacity(.{
                        .source = .dynamic,
                        .texture = texture,
                        .presentation = active_presentation,
                        .order = active_order,
                        .first_vertex = active_first_vertex,
                        .vertex_count = active_vertex_count,
                    });
                }
                active_texture = command.sprite.texture;
                active_presentation = group_presentation;
                active_order = command.sprite.order;
                active_first_vertex = first_vertex;
                active_vertex_count = 6;
            } else {
                active_vertex_count += 6;
            }
        }

        if (active_texture) |texture| {
            self.draw_groups.appendAssumeCapacity(.{
                .source = .dynamic,
                .texture = texture,
                .presentation = active_presentation,
                .order = active_order,
                .first_vertex = active_first_vertex,
                .vertex_count = active_vertex_count,
            });
        }
    }
};

const SpriteCommand = struct {
    sprite: Sprite,
};

const PreparedSpriteCommand = struct {
    sprite: Sprite,
    texture_desc: resources.TextureDesc,
};

const SpritePrepJobContext = struct {
    commands: []const PreparedSpriteCommand,
    columns: VertexColumns,
};

fn writePreparedSpritesJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SpritePrepJobContext = @ptrCast(@alignCast(context));
    fillPreparedRange(job.commands, job.columns, range);
}

fn fillPreparedRange(
    commands: []const PreparedSpriteCommand,
    columns: VertexColumns,
    range: ParallelRange,
) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= commands.len);
    for (range.start..range.end) |index| {
        writePreparedSpriteVertices(commands[index], columns, index * 6);
    }
}

fn writePreparedSpriteVertices(
    prepared: PreparedSpriteCommand,
    out: VertexColumns,
    base: usize,
) void {
    // All spaces emit world/identity-space geometry; the renderer applies the
    // camera via its vertex uniform, never on the CPU.
    writeSpriteQuad(prepared.sprite, prepared.texture_desc, out, base);
}

/// Writes one world-space sprite quad with identity transform. The world builds
/// static tile vertices through this so they are byte-identical to dynamic
/// sprite vertices, without importing gpu/* or the internal PositionTransform.
pub fn writeWorldSpriteQuad(
    sprite: Sprite,
    texture: resources.TextureDesc,
    out: VertexColumns,
) void {
    writeSpriteQuad(sprite, texture, out, 0);
}

// Pure six-vertex quad emission shared by dynamic sprite prep and static tile
// vertex builds, keeping their vertex layout byte-identical. Writes the 6 quad
// verts into each column at `out.*[base .. base + 6]`.
fn writeSpriteQuad(
    sprite: Sprite,
    texture: resources.TextureDesc,
    out: VertexColumns,
    base: usize,
) void {
    std.debug.assert(base + 6 <= out.positions.len);
    std.debug.assert(base + 6 <= out.uvs.len);
    std.debug.assert(base + 6 <= out.colors.len);
    const source = sprite.source orelse Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(texture.width),
        .h = @floatFromInt(texture.height),
    };

    const tex_u0 = source.x / @as(f32, @floatFromInt(texture.width));
    const tex_v0 = source.y / @as(f32, @floatFromInt(texture.height));
    const tex_u1 = (source.x + source.w) / @as(f32, @floatFromInt(texture.width));
    const tex_v1 = (source.y + source.h) / @as(f32, @floatFromInt(texture.height));

    const local = [_]math.Vec2{
        .{ .x = -sprite.origin.x, .y = -sprite.origin.y },
        .{ .x = sprite.dest.w - sprite.origin.x, .y = -sprite.origin.y },
        .{ .x = -sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
        .{ .x = sprite.dest.w - sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
    };
    const uv = [_][2]f32{
        .{ tex_u0, tex_v0 },
        .{ tex_u1, tex_v0 },
        .{ tex_u0, tex_v1 },
        .{ tex_u1, tex_v1 },
    };
    const indices = [_]usize{ 0, 1, 2, 1, 3, 2 };

    const rotation = math.sinCos(sprite.rotation);

    // The quad's four corners are exactly one SIMD lane group: rotate by the shared
    // sin/cos and offset into world space, all four corners at once. Emission is
    // always world/identity space, so there is no post-transform. Lane order
    // matches `local`/`uv`/`indices` above.
    const cos = simd.splatFloat4(rotation.cos);
    const sin = simd.splatFloat4(rotation.sin);
    const local_x = simd.float4(local[0].x, local[1].x, local[2].x, local[3].x);
    const local_y = simd.float4(local[0].y, local[1].y, local[2].y, local[3].y);
    const rotated_x = simd.subFloat4(simd.mulFloat4(local_x, cos), simd.mulFloat4(local_y, sin));
    const rotated_y = simd.addFloat4(simd.mulFloat4(local_x, sin), simd.mulFloat4(local_y, cos));
    const world_x = simd.addFloat4(rotated_x, simd.splatFloat4(sprite.dest.x + sprite.origin.x));
    const world_y = simd.addFloat4(rotated_y, simd.splatFloat4(sprite.dest.y + sprite.origin.y));
    const px = simd.toFloatArray(world_x);
    const py = simd.toFloatArray(world_y);
    var positions: [4]math.Vec2 = undefined;
    inline for (0..4) |index| positions[index] = .{ .x = px[index], .y = py[index] };

    // All six verts share the sprite tint — fill the color column in one splat.
    @memset(out.colors[base..][0..6], VertexColor{ sprite.tint.r, sprite.tint.g, sprite.tint.b, sprite.tint.a });
    for (indices, 0..) |source_index, out_index| {
        const position = positions[source_index];
        out.positions[base + out_index] = .{ position.x, position.y };
        out.uvs[base + out_index] = uv[source_index];
    }
}

fn setVertexCountAssumeCapacity(comptime T: type, column: *std.ArrayList(T), count: usize) void {
    column.clearRetainingCapacity();
    std.debug.assert(column.capacity >= count);
    column.items.len = count;
}

pub fn presentationForCoordinateSpace(coordinate_space: CoordinateSpace) CoordinatePresentation {
    return switch (coordinate_space) {
        .world => .world,
        .logical => .logical,
        .drawable => .drawable,
    };
}

fn textureIdsEqual(lhs: TextureId, rhs: TextureId) bool {
    return lhs.index == rhs.index and lhs.generation == rhs.generation;
}

fn renderOrdersEqual(lhs: RenderOrder, rhs: RenderOrder) bool {
    return lhs.domain == rhs.domain and lhs.depth == rhs.depth;
}

fn testTextureId(index: u32, generation: u32) TextureId {
    return TextureId.init(index, generation) catch unreachable;
}

const TestTextureSlot = struct {
    id: TextureId,
    desc: resources.TextureDesc,
    alive: bool = true,
};

const TestTextureTable = struct {
    slots: []const TestTextureSlot,

    fn resolver(self: *const TestTextureTable) TextureResolver {
        return .{
            .context = self,
            .resolve = resolve,
        };
    }

    fn resolve(context: *const anyopaque, id: TextureId) ?resources.TextureDesc {
        const self: *const TestTextureTable = @ptrCast(@alignCast(context));
        if (!id.isValid()) return null;
        for (self.slots) |slot| {
            if (slot.alive and slot.id.matches(id.index, id.generation)) return slot.desc;
        }
        return null;
    }
};

fn initBatchTest(allocator: std.mem.Allocator, table: *const TestTextureTable) !SpriteBatch {
    var batch = SpriteBatch.init(allocator);
    errdefer batch.deinit();
    try batch.reserveStorage(8, 8 * 6, 8);
    _ = table;
    return batch;
}

test "batch builder skips invalid stale and destroyed texture ids" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 1, .height = 1 } },
        .{ .id = testTextureId(1, 2), .desc = .{ .width = 1, .height = 1 }, .alive = false },
        .{ .id = testTextureId(2, 4), .desc = .{ .width = 1, .height = 1 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(42, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    try batch.drawSprite(.{
        .texture = testTextureId(1, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    try batch.drawSprite(.{
        .texture = testTextureId(2, 3),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });

    batch.buildSerial(table.resolver());

    try std.testing.expectEqual(@as(usize, 6), batch.positions.items.len);
    try std.testing.expectEqual(@as(usize, 1), batch.draw_groups.items.len);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].texture.index);
    try std.testing.expectEqual(CoordinatePresentation.world, batch.draw_groups.items[0].presentation);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[0].vertex_count);
}

test "batch builder groups by texture and coordinate presentation" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 2, .y = 0, .w = 1, .h = 1 },
        .coordinate_space = .logical,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 4, .y = 0, .w = 1, .h = 1 },
        .coordinate_space = .drawable,
    });

    batch.buildSerial(table.resolver());

    try std.testing.expectEqual(@as(usize, 18), batch.positions.items.len);
    try std.testing.expectEqual(@as(usize, 3), batch.draw_groups.items.len);
    try std.testing.expectEqual(CoordinatePresentation.world, batch.draw_groups.items[0].presentation);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[0].vertex_count);
    try std.testing.expectEqual(CoordinatePresentation.logical, batch.draw_groups.items[1].presentation);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[1].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[1].vertex_count);
    try std.testing.expectEqual(CoordinatePresentation.drawable, batch.draw_groups.items[2].presentation);
    try std.testing.expectEqual(@as(u32, 12), batch.draw_groups.items[2].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[2].vertex_count);
}

test "world vertices ignore camera now that the transform is baked on the GPU" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();
    batch.setCamera(.{
        .position = .{ .x = 5, .y = 10 },
        .zoom = 2,
    });

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .logical,
    });

    batch.buildSerial(table.resolver());

    // All spaces emit world/identity-space geometry; the camera is applied by
    // the renderer's vertex uniform, never on the CPU.
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[0][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[0][1]);
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[6][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[6][1]);
    try std.testing.expectEqual(CoordinatePresentation.world, batch.draw_groups.items[0].presentation);
    try std.testing.expectEqual(CoordinatePresentation.logical, batch.draw_groups.items[1].presentation);
}

test "batch builder preserves ordered submission stream" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();
    const OrderedStreamDepth = enum(i32) {
        near,
        far,
    };

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 10, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(@intFromEnum(OrderedStreamDepth.near)),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(@intFromEnum(OrderedStreamDepth.far)),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 30, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(@intFromEnum(OrderedStreamDepth.far)),
    });

    batch.buildSerial(table.resolver());

    try std.testing.expectEqual(@as(f32, 10), batch.positions.items[0][0]);
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[6][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[12][0]);
}

test "batch builder splits a same-texture run on render order change" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    // One texture, two depths. Without an order break these collapse into a single
    // group keyed at the lower depth, so a static span at the depth between them
    // could not interleave in the merged draw list.
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(-2),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 2, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(1),
    });

    batch.buildSerial(table.resolver());

    try std.testing.expectEqual(@as(usize, 2), batch.draw_groups.items.len);
    try std.testing.expectEqual(@as(i32, -2), batch.draw_groups.items[0].order.depth);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[0].vertex_count);
    try std.testing.expectEqual(@as(i32, 1), batch.draw_groups.items[1].order.depth);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[1].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[1].vertex_count);
}

test "world and logical vertices stay independent of drawable presentation" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .logical,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .drawable,
    });

    batch.buildSerial(table.resolver());

    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[0][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[0][1]);
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[6][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[6][1]);
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[12][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[12][1]);
}

test "safe sprite batch build reserves missing frame storage" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 1, .height = 1 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    const stats = try batch.build(table.resolver(), null, .{ .adaptive = false });

    try std.testing.expectEqual(@as(usize, 1), stats.command_count);
    try std.testing.expectEqual(@as(usize, 6), batch.positions.items.len);
    try std.testing.expectEqual(@as(usize, 1), batch.draw_groups.items.len);
}

test "warmed sprite batch prep does not allocate" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 1, .height = 1 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(1, 6, 1);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    batch.allocator = failing_allocator.allocator();
    defer batch.allocator = allocator;

    batch.beginFrame();
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    _ = batch.buildAssumeCapacity(table.resolver(), null, .{ .adaptive = false });

    try std.testing.expectEqual(@as(usize, 1), batch.commands.items.len);
    try std.testing.expectEqual(@as(usize, 6), batch.positions.items.len);
    try std.testing.expectEqual(@as(usize, 1), batch.draw_groups.items.len);
}

test "render order compares domain before depth" {
    const ComparisonDepth = enum(i32) {
        below_ground = -1,
        ground = 0,
        above_ground = 1,
    };
    const high_world = RenderOrder.world(@intFromEnum(ComparisonDepth.above_ground));
    const ui_background = RenderOrder.ui(.background);
    const ui_text = RenderOrder.ui(.text);
    const debug_overlay = RenderOrder.debug(.overlay);
    const below_ground = RenderOrder.world(@intFromEnum(ComparisonDepth.below_ground));
    const ground = RenderOrder.world(@intFromEnum(ComparisonDepth.ground));

    try std.testing.expect(high_world.lessOrEqual(ui_background));
    try std.testing.expect(ui_text.lessOrEqual(debug_overlay));
    try std.testing.expect(below_ground.lessOrEqual(ground));
    try std.testing.expect(!debug_overlay.lessOrEqual(ground));
    try std.testing.expect(!ground.lessOrEqual(below_ground));
}

test "ui stack order keeps upper state background above lower state text" {
    const lower_text = RenderOrder.uiInStack(UiStackOrder.fromRenderOffset(0), .text);
    const upper_background = RenderOrder.uiInStack(UiStackOrder.fromRenderOffset(1), .background);

    try std.testing.expect(lower_text.lessOrEqual(upper_background));
}

test "parallel sprite prep matches serial vertices and draw groups" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 64, .height = 32 } },
        .{ .id = testTextureId(1, 1), .desc = .{ .width = 16, .height = 16 } },
        .{ .id = testTextureId(2, 1), .desc = .{ .width = 8, .height = 8 }, .alive = false },
    };
    const table = TestTextureTable{ .slots = &slots };
    var serial = try initBatchTest(allocator, &table);
    defer serial.deinit();
    var threaded = try initBatchTest(allocator, &table);
    defer threaded.deinit();
    try serial.reserveStorage(16, 16 * 6, 16);
    try threaded.reserveStorage(16, 16 * 6, 16);

    try addParallelParityCommands(&serial);
    try addParallelParityCommands(&threaded);

    serial.buildSerial(table.resolver());

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();
    const stats = try threaded.build(table.resolver(), &threads, .{
        .items_per_range = 1,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    try std.testing.expect(stats.batch.active_worker_threads > 0);
    // The emit path requests 4-command range alignment so worker range seams stay
    // cache-line-aligned across all three columns; guard the knob so a regression
    // back to 1 is caught here, not only by a false-sharing slowdown.
    try std.testing.expectEqual(@as(usize, 4), stats.batch.range_alignment_items);
    try expectEqualVertices(batchColumns(&serial), batchColumns(&threaded));
    try expectEqualDrawGroups(serial.draw_groups.items, threaded.draw_groups.items);
    try std.testing.expectEqual(serial.lastPrepStats().valid_sprite_count, threaded.lastPrepStats().valid_sprite_count);
    try std.testing.expectEqual(@as(usize, 2), threaded.lastPrepStats().skipped_invalid_count);
}

test "sprite prep uses batch owned adaptive tuner instead of thread system fallback" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 16, .height = 16 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(64, 64 * 6, 64);
    for (0..64) |index| {
        try batch.drawSprite(.{
            .texture = testTextureId(0, 1),
            .dest = .{
                .x = @floatFromInt(index),
                .y = @floatFromInt(index % 7),
                .w = 8,
                .h = 8,
            },
        });
    }

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();
    _ = try batch.build(table.resolver(), &threads, .{});

    try std.testing.expect(batch.adaptive_tuner.report().sample_count > 0);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_tuner.report().baseline_mean_batch_duration_ns);
    try std.testing.expectEqual(@as(usize, 0), threads.adaptive_tuner.report().sample_count);
}

fn addParallelParityCommands(batch: *SpriteBatch) !void {
    batch.setCamera(.{ .position = .{ .x = 4, .y = 2 }, .zoom = 1.5 });
    const ParityDepth = enum(i32) {
        invalid_background = -5,
        world_sprite = 1,
        logical_sprite = 2,
        foreground = 3,
    };
    try batch.drawSprite(.{
        .texture = testTextureId(2, 1),
        .dest = .{ .x = -10, .y = 0, .w = 12, .h = 12 },
        .order = RenderOrder.world(@intFromEnum(ParityDepth.invalid_background)),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .source = .{ .x = 4, .y = 6, .w = 12, .h = 10 },
        .dest = .{ .x = 20, .y = 30, .w = 16, .h = 18 },
        .origin = .{ .x = 8, .y = 9 },
        .rotation = 0.25,
        .tint = .{ .r = 0.2, .g = 0.5, .b = 0.8, .a = 0.9 },
        .order = RenderOrder.world(@intFromEnum(ParityDepth.world_sprite)),
        .coordinate_space = .world,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(1, 1),
        .dest = .{ .x = 12, .y = 14, .w = 8, .h = 8 },
        .order = RenderOrder.world(@intFromEnum(ParityDepth.logical_sprite)),
        .coordinate_space = .logical,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 60, .y = 12, .w = 10, .h = 10 },
        .order = RenderOrder.world(@intFromEnum(ParityDepth.logical_sprite)),
        .coordinate_space = .drawable,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(99, 1),
        .dest = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .order = RenderOrder.world(@intFromEnum(ParityDepth.foreground)),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(1, 1),
        .dest = .{ .x = 2, .y = 6, .w = 7, .h = 9 },
        .origin = .{ .x = 3, .y = 4 },
        .rotation = -0.5,
        .order = RenderOrder.world(@intFromEnum(ParityDepth.foreground)),
        .coordinate_space = .world,
    });
    // Extra valid sprites so the 4-command range alignment yields more than one
    // range (>=8 valid -> >=2 aligned ranges), keeping the threaded path from
    // collapsing to a single inline range and actually recruiting a worker.
    for (0..5) |index| {
        try batch.drawSprite(.{
            .texture = testTextureId(0, 1),
            .dest = .{
                .x = @floatFromInt(40 + index),
                .y = @floatFromInt(index % 3),
                .w = 6,
                .h = 6,
            },
            .origin = .{ .x = 1, .y = 2 },
            .rotation = @as(f32, @floatFromInt(index)) * 0.1,
            .tint = .{ .r = 0.3, .g = 0.4, .b = 0.5, .a = 1 },
            .order = RenderOrder.world(@intFromEnum(ParityDepth.foreground)),
            .coordinate_space = .world,
        });
    }
}

fn batchColumns(batch: *const SpriteBatch) VertexColumnsConst {
    return .{
        .positions = batch.positions.items,
        .uvs = batch.uvs.items,
        .colors = batch.colors.items,
    };
}

fn expectEqualVertices(expected: VertexColumnsConst, actual: VertexColumnsConst) !void {
    try std.testing.expectEqual(expected.positions.len, actual.positions.len);
    try std.testing.expectEqual(expected.uvs.len, actual.uvs.len);
    try std.testing.expectEqual(expected.colors.len, actual.colors.len);
    for (expected.positions, actual.positions) |lhs, rhs| {
        try std.testing.expectEqual(lhs[0], rhs[0]);
        try std.testing.expectEqual(lhs[1], rhs[1]);
    }
    for (expected.uvs, actual.uvs) |lhs, rhs| {
        try std.testing.expectEqual(lhs[0], rhs[0]);
        try std.testing.expectEqual(lhs[1], rhs[1]);
    }
    for (expected.colors, actual.colors) |lhs, rhs| {
        try std.testing.expectEqual(lhs[0], rhs[0]);
        try std.testing.expectEqual(lhs[1], rhs[1]);
        try std.testing.expectEqual(lhs[2], rhs[2]);
        try std.testing.expectEqual(lhs[3], rhs[3]);
    }
}

// AoS oracle: the original interleaved emission arithmetic, kept verbatim so the
// SoA columns are proven bit-exact against it (same simd/math ops -> last-ULP
// identical, no approx). Guards column desync and lane/attribute transposition.
const AosVertex = struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

fn aosOracleQuad(sprite: Sprite, texture: resources.TextureDesc, out: *[6]AosVertex) void {
    const source = sprite.source orelse Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(texture.width),
        .h = @floatFromInt(texture.height),
    };

    const tex_u0 = source.x / @as(f32, @floatFromInt(texture.width));
    const tex_v0 = source.y / @as(f32, @floatFromInt(texture.height));
    const tex_u1 = (source.x + source.w) / @as(f32, @floatFromInt(texture.width));
    const tex_v1 = (source.y + source.h) / @as(f32, @floatFromInt(texture.height));

    const local = [_]math.Vec2{
        .{ .x = -sprite.origin.x, .y = -sprite.origin.y },
        .{ .x = sprite.dest.w - sprite.origin.x, .y = -sprite.origin.y },
        .{ .x = -sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
        .{ .x = sprite.dest.w - sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
    };
    const uv = [_][2]f32{
        .{ tex_u0, tex_v0 },
        .{ tex_u1, tex_v0 },
        .{ tex_u0, tex_v1 },
        .{ tex_u1, tex_v1 },
    };
    const indices = [_]usize{ 0, 1, 2, 1, 3, 2 };

    const rotation = math.sinCos(sprite.rotation);
    const cos = simd.splatFloat4(rotation.cos);
    const sin = simd.splatFloat4(rotation.sin);
    const local_x = simd.float4(local[0].x, local[1].x, local[2].x, local[3].x);
    const local_y = simd.float4(local[0].y, local[1].y, local[2].y, local[3].y);
    const rotated_x = simd.subFloat4(simd.mulFloat4(local_x, cos), simd.mulFloat4(local_y, sin));
    const rotated_y = simd.addFloat4(simd.mulFloat4(local_x, sin), simd.mulFloat4(local_y, cos));
    const world_x = simd.addFloat4(rotated_x, simd.splatFloat4(sprite.dest.x + sprite.origin.x));
    const world_y = simd.addFloat4(rotated_y, simd.splatFloat4(sprite.dest.y + sprite.origin.y));
    // Identity emit transform (scale=1, offset=0), applied with the same ops as
    // writeSpriteQuad so the oracle is bit-exact.
    const final_x = simd.addFloat4(simd.mulFloat4(world_x, simd.splatFloat4(1)), simd.splatFloat4(0));
    const final_y = simd.addFloat4(simd.mulFloat4(world_y, simd.splatFloat4(1)), simd.splatFloat4(0));
    const px = simd.toFloatArray(final_x);
    const py = simd.toFloatArray(final_y);
    var positions: [4]math.Vec2 = undefined;
    inline for (0..4) |index| positions[index] = .{ .x = px[index], .y = py[index] };

    for (indices, 0..) |source_index, out_index| {
        const position = positions[source_index];
        out[out_index] = .{
            .position = .{ position.x, position.y },
            .uv = uv[source_index],
            .color = .{ sprite.tint.r, sprite.tint.g, sprite.tint.b, sprite.tint.a },
        };
    }
}

test "soa columns reconstruct the AoS oracle vertex layout" {
    const texture = resources.TextureDesc{ .width = 64, .height = 32 };
    const sprites = [_]Sprite{
        .{ .texture = testTextureId(0, 1), .dest = .{ .x = 20, .y = 30, .w = 16, .h = 18 } },
        .{
            .texture = testTextureId(0, 1),
            .source = .{ .x = 4, .y = 6, .w = 12, .h = 10 },
            .dest = .{ .x = -10, .y = 5, .w = 14, .h = 9 },
            .origin = .{ .x = 8, .y = 9 },
            .rotation = 0.37,
            .tint = .{ .r = 0.2, .g = 0.5, .b = 0.8, .a = 0.9 },
        },
        .{
            .texture = testTextureId(0, 1),
            .dest = .{ .x = 3, .y = 7, .w = 5, .h = 11 },
            .origin = .{ .x = 2, .y = 1 },
            .rotation = -1.2,
            .tint = .{ .r = 1, .g = 0, .b = 0.25, .a = 0.5 },
        },
    };

    for (sprites) |sprite| {
        var positions: [6]Position = undefined;
        var uvs: [6]Uv = undefined;
        var colors: [6]VertexColor = undefined;
        writeWorldSpriteQuad(sprite, texture, .{
            .positions = &positions,
            .uvs = &uvs,
            .colors = &colors,
        });

        var oracle: [6]AosVertex = undefined;
        aosOracleQuad(sprite, texture, &oracle);

        for (0..6) |i| {
            try std.testing.expectEqual(oracle[i].position[0], positions[i][0]);
            try std.testing.expectEqual(oracle[i].position[1], positions[i][1]);
            try std.testing.expectEqual(oracle[i].uv[0], uvs[i][0]);
            try std.testing.expectEqual(oracle[i].uv[1], uvs[i][1]);
            try std.testing.expectEqual(oracle[i].color[0], colors[i][0]);
            try std.testing.expectEqual(oracle[i].color[1], colors[i][1]);
            try std.testing.expectEqual(oracle[i].color[2], colors[i][2]);
            try std.testing.expectEqual(oracle[i].color[3], colors[i][3]);
        }
    }
}

fn expectEqualDrawGroups(expected: []const DrawGroup, actual: []const DrawGroup) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |lhs, rhs| {
        try std.testing.expectEqual(lhs.texture.index, rhs.texture.index);
        try std.testing.expectEqual(lhs.texture.generation, rhs.texture.generation);
        try std.testing.expectEqual(lhs.presentation, rhs.presentation);
        try std.testing.expectEqual(lhs.first_vertex, rhs.first_vertex);
        try std.testing.expectEqual(lhs.vertex_count, rhs.vertex_count);
    }
}

test "draw sprite stays allocation-free after reserve" {
    const allocator = std.testing.allocator;
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();

    const command_capacity: usize = 8;
    try batch.reserveStorage(command_capacity, command_capacity * 6, command_capacity);
    batch.frame_reserved = true;
    const capacity_before = batch.commands.capacity;

    const texture = TextureId.init(0, 1) catch unreachable;
    for (0..command_capacity) |i| {
        try batch.drawSprite(.{
            .texture = texture,
            .dest = .{ .x = @floatFromInt(i), .y = 0, .w = 1, .h = 1 },
            .order = RenderOrder.world(@intCast(i)),
        });
    }

    try std.testing.expectEqual(capacity_before, batch.commands.capacity);
    try std.testing.expectEqual(command_capacity, batch.commands.items.len);
}
