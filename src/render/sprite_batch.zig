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
    logical,
    drawable,
};

pub const Vertex = extern struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

pub const DrawGroup = struct {
    texture: TextureId,
    presentation: CoordinatePresentation,
    first_vertex: u32,
    vertex_count: u32,
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
    allocator: std.mem.Allocator,
    commands: std.ArrayList(SpriteCommand) = .empty,
    prepared_commands: std.ArrayList(PreparedSpriteCommand) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    draw_groups: std.ArrayList(DrawGroup) = .empty,
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
        self.vertices.deinit(self.allocator);
        self.draw_groups.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn beginFrame(self: *SpriteBatch) void {
        self.commands.clearRetainingCapacity();
        self.vertices.clearRetainingCapacity();
        self.draw_groups.clearRetainingCapacity();
        self.prepared_commands.clearRetainingCapacity();
        self.last_order = null;
        self.last_prep_stats = .{};
    }

    pub fn drawSprite(self: *SpriteBatch, sprite: Sprite) !void {
        if (self.last_order) |previous| {
            std.debug.assert(previous.lessOrEqual(sprite.order));
        }
        // Ordered submission keeps the renderer cheap: grouping can preserve
        // stream order instead of sorting every frame.
        try self.commands.append(self.allocator, .{ .sprite = sprite });
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
        try self.vertices.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.draw_groups.ensureTotalCapacity(self.allocator, draw_group_capacity);
    }

    pub fn ensureFrameStorage(self: *SpriteBatch) !void {
        const needed_vertices = try std.math.mul(usize, self.commands.items.len, 6);
        if (needed_vertices == 0) return;

        try self.prepared_commands.ensureTotalCapacity(self.allocator, self.commands.items.len);
        try self.vertices.ensureTotalCapacity(self.allocator, needed_vertices);
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
        self.vertices.clearRetainingCapacity();
        self.draw_groups.clearRetainingCapacity();
        self.prepared_commands.clearRetainingCapacity();

        std.debug.assert(self.vertices.capacity >= self.commands.items.len * 6);
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
        setVertexCountAssumeCapacity(&self.vertices, valid_count * 6);

        var batch: BatchStats = .{};
        if (valid_count > 0) {
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
                    .vertices = self.vertices.items,
                    .camera = self.camera,
                };
                batch = threads.parallelForWithOptions(valid_count, &context, writePreparedSpritesJob, .{
                    .items_per_range = system_config.items_per_range,
                    .max_worker_threads = system_config.max_worker_threads,
                    .adaptive = system_config.adaptive,
                    .adaptive_tuner = system_config.adaptive_tuner,
                });
            } else {
                fillPreparedRange(self.prepared_commands.items, self.vertices.items, .{
                    .start = 0,
                    .end = valid_count,
                }, self.camera);
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
            .vertex_count = self.vertices.items.len,
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
        var active_first_vertex: u32 = 0;
        var active_vertex_count: u32 = 0;

        for (self.prepared_commands.items, 0..) |command, prepared_index| {
            const first_vertex: u32 = @intCast(prepared_index * 6);
            const group_presentation = presentationForCoordinateSpace(command.sprite.coordinate_space);

            if (active_texture == null or !textureIdsEqual(active_texture.?, command.sprite.texture) or active_presentation != group_presentation) {
                if (active_texture) |texture| {
                    self.draw_groups.appendAssumeCapacity(.{
                        .texture = texture,
                        .presentation = active_presentation,
                        .first_vertex = active_first_vertex,
                        .vertex_count = active_vertex_count,
                    });
                }
                active_texture = command.sprite.texture;
                active_presentation = group_presentation;
                active_first_vertex = first_vertex;
                active_vertex_count = 6;
            } else {
                active_vertex_count += 6;
            }
        }

        if (active_texture) |texture| {
            self.draw_groups.appendAssumeCapacity(.{
                .texture = texture,
                .presentation = active_presentation,
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
    vertices: []Vertex,
    camera: Camera2D,
};

fn writePreparedSpritesJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SpritePrepJobContext = @ptrCast(@alignCast(context));
    fillPreparedRange(job.commands, job.vertices, range, job.camera);
}

fn fillPreparedRange(
    commands: []const PreparedSpriteCommand,
    vertices: []Vertex,
    range: ParallelRange,
    camera: Camera2D,
) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= commands.len);
    for (range.start..range.end) |index| {
        writePreparedSpriteVertices(
            commands[index],
            vertices[index * 6 ..][0..6],
            camera,
        );
    }
}

fn writePreparedSpriteVertices(
    prepared: PreparedSpriteCommand,
    out: []Vertex,
    camera: Camera2D,
) void {
    const sprite = prepared.sprite;
    std.debug.assert(out.len == 6);
    const texture = prepared.texture_desc;
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

    const rotation_cos = @cos(sprite.rotation);
    const rotation_sin = @sin(sprite.rotation);

    var positions: [4]math.Vec2 = undefined;
    for (local, 0..) |point, index| {
        const rotated = math.Vec2{
            .x = point.x * rotation_cos - point.y * rotation_sin,
            .y = point.x * rotation_sin + point.y * rotation_cos,
        };
        const world = math.Vec2{
            .x = sprite.dest.x + sprite.origin.x + rotated.x,
            .y = sprite.dest.y + sprite.origin.y + rotated.y,
        };
        const screen = switch (sprite.coordinate_space) {
            .world => camera.worldToScreen(world),
            .logical, .drawable => world,
        };
        positions[index] = screen;
    }

    for (indices, 0..) |source_index, out_index| {
        const position = positions[source_index];
        out[out_index] = .{
            .position = .{ position.x, position.y },
            .uv = uv[source_index],
            .color = .{ sprite.tint.r, sprite.tint.g, sprite.tint.b, sprite.tint.a },
        };
    }
}

fn setVertexCountAssumeCapacity(vertices: *std.ArrayList(Vertex), count: usize) void {
    vertices.clearRetainingCapacity();
    std.debug.assert(vertices.capacity >= count);
    vertices.items.len = count;
}

pub fn presentationForCoordinateSpace(coordinate_space: CoordinateSpace) CoordinatePresentation {
    return switch (coordinate_space) {
        .world, .logical => .logical,
        .drawable => .drawable,
    };
}

fn textureIdsEqual(lhs: TextureId, rhs: TextureId) bool {
    return lhs.index == rhs.index and lhs.generation == rhs.generation;
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

    try std.testing.expectEqual(@as(usize, 6), batch.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), batch.draw_groups.items.len);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].texture.index);
    try std.testing.expectEqual(CoordinatePresentation.logical, batch.draw_groups.items[0].presentation);
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

    try std.testing.expectEqual(@as(usize, 18), batch.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 2), batch.draw_groups.items.len);
    try std.testing.expectEqual(CoordinatePresentation.logical, batch.draw_groups.items[0].presentation);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 12), batch.draw_groups.items[0].vertex_count);
    try std.testing.expectEqual(CoordinatePresentation.drawable, batch.draw_groups.items[1].presentation);
    try std.testing.expectEqual(@as(u32, 12), batch.draw_groups.items[1].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[1].vertex_count);
}

test "world sprites apply camera while logical and drawable sprites ignore camera" {
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
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .drawable,
    });

    batch.buildSerial(table.resolver());

    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 40), batch.vertices.items[0].position[1]);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[6].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[6].position[1]);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[12].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[12].position[1]);
    try std.testing.expectEqual(CoordinatePresentation.drawable, batch.draw_groups.items[1].presentation);
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

    try std.testing.expectEqual(@as(f32, 10), batch.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[6].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[12].position[0]);
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

    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[0].position[1]);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[6].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[6].position[1]);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[12].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[12].position[1]);
}

test "world vertices include camera without presentation offset" {
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

    batch.buildSerial(table.resolver());

    try std.testing.expectApproxEqAbs(@as(f32, 30), batch.vertices.items[0].position[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 40), batch.vertices.items[0].position[1], 0.001);
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
    try std.testing.expectEqual(@as(usize, 6), batch.vertices.items.len);
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
    try std.testing.expectEqual(@as(usize, 6), batch.vertices.items.len);
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
    try expectEqualVertices(serial.vertices.items, threaded.vertices.items);
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
}

fn expectEqualVertices(expected: []const Vertex, actual: []const Vertex) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |lhs, rhs| {
        try std.testing.expectEqual(lhs.position[0], rhs.position[0]);
        try std.testing.expectEqual(lhs.position[1], rhs.position[1]);
        try std.testing.expectEqual(lhs.uv[0], rhs.uv[0]);
        try std.testing.expectEqual(lhs.uv[1], rhs.uv[1]);
        try std.testing.expectEqual(lhs.color[0], rhs.color[0]);
        try std.testing.expectEqual(lhs.color[1], rhs.color[1]);
        try std.testing.expectEqual(lhs.color[2], rhs.color[2]);
        try std.testing.expectEqual(lhs.color[3], rhs.color[3]);
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
