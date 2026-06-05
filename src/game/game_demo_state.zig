// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const config = @import("../config.zig");
const math = @import("../core/math.zig");
const std = @import("std");
const data_mod = @import("data_system.zig");
const DataSystem = data_mod.DataSystem;
const EntityId = data_mod.EntityId;
const Player = @import("player.zig").Player;
const movement_system = @import("systems/movement.zig");
const ParticleSystem = @import("systems/particle.zig").ParticleSystem;
const state_mod = @import("../app/state.zig");
const RenderContext = state_mod.RenderContext;
const StateTransitions = state_mod.StateTransitions;
const UpdateContext = state_mod.UpdateContext;
const c = @import("../platform/sdl.zig").c;

const test_square_count = 4;

pub const GameDemoState = struct {
    data: DataSystem,
    player: Player,
    movement: movement_system.Runtime,
    particles: ParticleSystem,
    test_squares: [test_square_count]EntityId,
    bounds_width: f32 = 800,
    bounds_height: f32 = 450,

    pub fn init(allocator: std.mem.Allocator, bounds_width: f32, bounds_height: f32) !GameDemoState {
        var data = DataSystem.init(allocator);
        errdefer data.deinit();
        const player = try Player.spawn(&data);
        const test_squares = try spawnTestSquares(&data);
        var particles = try ParticleSystem.init(allocator, .{ .capacity = 512 });
        errdefer particles.deinit();

        return .{
            .data = data,
            .player = player,
            .movement = movement_system.Runtime.init(),
            .particles = particles,
            .test_squares = test_squares,
            .bounds_width = bounds_width,
            .bounds_height = bounds_height,
        };
    }

    pub fn deinit(self: *GameDemoState) void {
        self.particles.deinit();
        self.data.deinit();
    }

    pub fn handleEvent(self: *GameDemoState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        _ = self;
        _ = event;
        _ = transitions;
        return false;
    }

    pub fn update(self: *GameDemoState, context: UpdateContext) !void {
        _ = context.transitions;
        try self.player.applyInput(&self.data, context.input);
        _ = self.movement.update(&self.data, context.thread_system, context.delta_seconds, .{});
        try self.player.clampToBounds(&self.data, self.bounds_width, self.bounds_height);
        self.emitPlayerTrail();
        _ = self.particles.update(context.thread_system, context.delta_seconds, .{});
    }

    pub fn render(self: *GameDemoState, context: RenderContext) !void {
        _ = context.thread_system;
        for (self.test_squares) |entity| {
            try renderPrimitiveEntity(&self.data, entity, context.renderer, context.interpolation_alpha);
        }
        try self.particles.render(context.renderer, context.interpolation_alpha);
        try self.player.render(&self.data, context.renderer, context.interpolation_alpha);
        try context.renderer.drawRect(.{
            .x = 0,
            .y = self.bounds_height - 4,
            .w = self.bounds_width,
            .h = 4,
        }, config.Color{ .r = 0.16, .g = 0.24, .b = 0.29, .a = 1.0 }, -1);
    }

    pub fn onPause(self: *GameDemoState) void {
        self.movement.syncPreviousPositions(&self.data);
        self.particles.syncPreviousPositions();
    }

    fn emitPlayerTrail(self: *GameDemoState) void {
        const body = self.data.movementBodyConst(self.player.entity) orelse return;
        const position = body.position;
        _ = self.particles.emitBurst(.{
            .count = 2,
            .position = .{ .x = position.x + 16, .y = position.y + 16 },
            .base_velocity = .{ .x = -24, .y = -36 },
            .velocity_step = .{ .x = 48, .y = -4 },
            .acceleration = .{ .x = 0, .y = 80 },
            .lifetime = 0.55,
            .lifetime_step = 0.04,
            .start_size = 7,
            .end_size = 1,
            .start_color = .{ .r = 1.0, .g = 0.78, .b = 0.28, .a = 0.85 },
            .end_color = .{ .r = 0.95, .g = 0.24, .b = 0.18, .a = 0.0 },
            .layer = 0,
        });
    }
};

fn spawnTestSquares(data: *DataSystem) ![test_square_count]EntityId {
    const specs = [_]TestSquareSpec{
        .{
            .position = .{ .x = 120, .y = 120 },
            .velocity = .{ .x = 18, .y = 0 },
            .size = .{ .x = 24, .y = 24 },
            .color = .{ .r = 0.34, .g = 0.69, .b = 1.0, .a = 1.0 },
            .layer = 0,
        },
        .{
            .position = .{ .x = 220, .y = 160 },
            .velocity = .{ .x = 0, .y = 14 },
            .size = .{ .x = 28, .y = 28 },
            .color = .{ .r = 0.46, .g = 0.86, .b = 0.38, .a = 1.0 },
            .layer = 0,
        },
        .{
            .position = .{ .x = 320, .y = 220 },
            .velocity = .{ .x = -16, .y = 10 },
            .size = .{ .x = 20, .y = 20 },
            .color = .{ .r = 0.95, .g = 0.42, .b = 0.59, .a = 1.0 },
            .layer = 0,
        },
        .{
            .position = .{ .x = 470, .y = 130 },
            .velocity = .{ .x = 12, .y = -8 },
            .size = .{ .x = 26, .y = 26 },
            .color = .{ .r = 0.7, .g = 0.54, .b = 1.0, .a = 1.0 },
            .layer = 0,
        },
    };
    var entities: [test_square_count]EntityId = undefined;
    for (specs, 0..) |spec, index| {
        const entity = try data.createEntity();
        errdefer _ = data.destroyEntity(entity);
        try data.setMovementBody(entity, .{
            .position = spec.position,
            .previous_position = spec.position,
            .velocity = spec.velocity,
            .speed = 0,
        });
        try data.setPrimitiveVisual(entity, .{
            .size = spec.size,
            .color = spec.color,
            .layer = spec.layer,
            .marker_color = .{ .r = 0, .g = 0, .b = 0, .a = 0 },
            .marker_layer = spec.layer,
            .marker_length = 0,
            .marker_depth = 0,
            .marker_margin = 0,
        });
        entities[index] = entity;
    }
    return entities;
}

fn renderPrimitiveEntity(
    data: *const DataSystem,
    entity: EntityId,
    renderer: *@import("../render/renderer.zig").Renderer,
    interpolation_alpha: f32,
) !void {
    const body = data.movementBodyConst(entity) orelse return;
    const visual = data.primitiveVisualConst(entity) orelse return;
    const render_position = math.lerpVec2(body.previous_position, body.position, interpolation_alpha);
    try renderer.drawRect(.{
        .x = render_position.x,
        .y = render_position.y,
        .w = visual.size.x,
        .h = visual.size.y,
    }, visual.color, visual.layer);
}

const TestSquareSpec = struct {
    position: math.Vec2,
    velocity: math.Vec2,
    size: math.Vec2,
    color: config.Color,
    layer: i32,
};

test "demo spawns colored moving test squares" {
    var demo = try GameDemoState.init(std.testing.allocator, 800, 450);
    defer demo.deinit();

    try std.testing.expectEqual(@as(usize, test_square_count + 1), demo.data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 0), demo.particles.activeCount());
    for (demo.test_squares) |entity| {
        try std.testing.expect(demo.data.hasComponents(entity, data_mod.component_masks.movement_body | data_mod.component_masks.primitive_visual));
        const body = demo.data.movementBodyConst(entity).?;
        try std.testing.expect(body.velocity.x != 0 or body.velocity.y != 0);
        const visual = demo.data.primitiveVisualConst(entity).?;
        try std.testing.expect(visual.color.a > 0);
    }
}
