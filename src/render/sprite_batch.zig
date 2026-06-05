// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const Camera2D = @import("camera.zig").Camera2D;
const config = @import("../config.zig");
const math = @import("../core/math.zig");
const resources = @import("resources.zig");
const resolution = @import("../app/resolution.zig");

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

pub const Sprite = struct {
    texture: TextureId,
    source: ?Rect = null,
    dest: Rect,
    tint: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    origin: math.Vec2 = .{},
    rotation: f32 = 0,
    layer: i32 = 0,
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

pub const SpriteBatch = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(SpriteCommand) = .empty,
    vertices: std.ArrayList(Vertex) = .empty,
    draw_groups: std.ArrayList(DrawGroup) = .empty,
    camera: Camera2D = .{},
    command_sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) SpriteBatch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SpriteBatch) void {
        self.commands.deinit(self.allocator);
        self.vertices.deinit(self.allocator);
        self.draw_groups.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn beginFrame(self: *SpriteBatch) void {
        self.commands.clearRetainingCapacity();
        self.vertices.clearRetainingCapacity();
        self.draw_groups.clearRetainingCapacity();
        self.command_sequence = 0;
    }

    pub fn drawSprite(self: *SpriteBatch, sprite: Sprite) !void {
        try self.commands.append(self.allocator, .{
            .sprite = sprite,
            .sequence = self.command_sequence,
        });
        self.command_sequence += 1;
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
        try self.vertices.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.draw_groups.ensureTotalCapacity(self.allocator, draw_group_capacity);
    }

    pub fn ensureFrameStorage(self: *SpriteBatch) !void {
        const needed_vertices = try std.math.mul(usize, self.commands.items.len, 6);
        if (needed_vertices == 0) return;

        try self.vertices.ensureTotalCapacity(self.allocator, needed_vertices);
        try self.draw_groups.ensureTotalCapacity(self.allocator, self.commands.items.len);
    }

    pub fn buildSerial(self: *SpriteBatch, texture_resolver: TextureResolver, frame_presentation: resolution.Presentation) void {
        self.vertices.clearRetainingCapacity();
        self.draw_groups.clearRetainingCapacity();

        std.mem.sort(SpriteCommand, self.commands.items, {}, spriteCommandLessThan);
        std.debug.assert(self.vertices.capacity >= self.commands.items.len * 6);
        std.debug.assert(self.draw_groups.capacity >= self.commands.items.len);

        var active_texture: ?TextureId = null;
        var active_presentation: CoordinatePresentation = .logical;
        var active_first_vertex: u32 = 0;
        var active_vertex_count: u32 = 0;

        for (self.commands.items) |command| {
            const first_vertex: u32 = @intCast(self.vertices.items.len);
            if (!self.appendSpriteVertices(command.sprite, texture_resolver, frame_presentation)) continue;
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

    fn appendSpriteVertices(
        self: *SpriteBatch,
        sprite: Sprite,
        texture_resolver: TextureResolver,
        presentation: resolution.Presentation,
    ) bool {
        const texture = texture_resolver.textureDesc(sprite.texture) orelse return false;

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
                .world => self.camera.worldToScreen(world),
                .logical, .drawable => world,
            };
            positions[index] = switch (sprite.coordinate_space) {
                .world, .logical => logicalToDrawable(screen, presentation),
                .drawable => screen,
            };
        }

        for (indices) |index| {
            const position = positions[index];
            self.vertices.appendAssumeCapacity(.{
                .position = .{ position.x, position.y },
                .uv = uv[index],
                .color = .{ sprite.tint.r, sprite.tint.g, sprite.tint.b, sprite.tint.a },
            });
        }
        return true;
    }
};

const SpriteCommand = struct {
    sprite: Sprite,
    sequence: u64,
};

pub fn presentationForCoordinateSpace(coordinate_space: CoordinateSpace) CoordinatePresentation {
    return switch (coordinate_space) {
        .world, .logical => .logical,
        .drawable => .drawable,
    };
}

fn logicalToDrawable(point: math.Vec2, presentation: resolution.Presentation) math.Vec2 {
    const viewport = presentation.viewport;
    return .{
        .x = @as(f32, @floatFromInt(viewport.x)) + point.x * viewport.scale_x,
        .y = @as(f32, @floatFromInt(viewport.y)) + point.y * viewport.scale_y,
    };
}

fn spriteCommandLessThan(_: void, lhs: SpriteCommand, rhs: SpriteCommand) bool {
    if (lhs.sprite.layer != rhs.sprite.layer) return lhs.sprite.layer < rhs.sprite.layer;
    return lhs.sequence < rhs.sequence;
}

fn textureIdsEqual(lhs: TextureId, rhs: TextureId) bool {
    return lhs.index == rhs.index and lhs.generation == rhs.generation;
}

fn batchTestPresentation() !resolution.Presentation {
    return resolution.computePresentation(
        .{},
        .{ .width = 1280, .height = 720 },
        .{ .width = 1280, .height = 720 },
    );
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

    batch.buildSerial(table.resolver(), try batchTestPresentation());

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

    batch.buildSerial(table.resolver(), try batchTestPresentation());

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

    batch.buildSerial(table.resolver(), try batchTestPresentation());

    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 40), batch.vertices.items[0].position[1]);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[6].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[6].position[1]);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[12].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[12].position[1]);
    try std.testing.expectEqual(CoordinatePresentation.drawable, batch.draw_groups.items[1].presentation);
}

test "batch builder orders layers before submission sequence" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 0, .w = 1, .h = 1 },
        .layer = 5,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 10, .y = 0, .w = 1, .h = 1 },
        .layer = 1,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 30, .y = 0, .w = 1, .h = 1 },
        .layer = 5,
    });

    batch.buildSerial(table.resolver(), try batchTestPresentation());

    try std.testing.expectEqual(@as(f32, 10), batch.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[6].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[12].position[0]);
}

test "world and logical vertices are submitted in drawable pixels" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    const presentation = try resolution.computePresentation(
        .{},
        .{ .width = 1280, .height = 720 },
        .{ .width = 2560, .height = 1440 },
    );

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

    batch.buildSerial(table.resolver(), presentation);

    try std.testing.expectEqual(@as(f32, 40), batch.vertices.items[0].position[0]);
    try std.testing.expectEqual(@as(f32, 60), batch.vertices.items[0].position[1]);
    try std.testing.expectEqual(@as(f32, 40), batch.vertices.items[6].position[0]);
    try std.testing.expectEqual(@as(f32, 60), batch.vertices.items[6].position[1]);
    try std.testing.expectEqual(@as(f32, 20), batch.vertices.items[12].position[0]);
    try std.testing.expectEqual(@as(f32, 30), batch.vertices.items[12].position[1]);
}

test "world vertices include camera then letterbox viewport offset" {
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

    const presentation = try resolution.computePresentation(
        .{},
        .{ .width = 1800, .height = 1130 },
        .{ .width = 3600, .height = 2260 },
    );

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });

    batch.buildSerial(table.resolver(), presentation);

    try std.testing.expectApproxEqAbs(@as(f32, 84.375), batch.vertices.items[0].position[0], 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 229.5), batch.vertices.items[0].position[1], 0.001);
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
    batch.buildSerial(table.resolver(), try batchTestPresentation());

    try std.testing.expectEqual(@as(usize, 1), batch.commands.items.len);
    try std.testing.expectEqual(@as(usize, 6), batch.vertices.items.len);
    try std.testing.expectEqual(@as(usize, 1), batch.draw_groups.items.len);
}

test "sprite sorting preserves submission order within each layer" {
    const first = SpriteCommand{
        .sprite = .{
            .texture = testTextureId(10, 1),
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .layer = 0,
        },
        .sequence = 0,
    };
    const second = SpriteCommand{
        .sprite = .{
            .texture = testTextureId(3, 1),
            .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            .layer = 0,
        },
        .sequence = 1,
    };

    try std.testing.expect(spriteCommandLessThan({}, first, second));
    try std.testing.expect(!spriteCommandLessThan({}, second, first));
}
