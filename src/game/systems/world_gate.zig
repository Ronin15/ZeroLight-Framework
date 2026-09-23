// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Bounds clamp and solid-tile gate for one settled movement step.
//! Scalar. Threading and SIMD are a separate benched follow-up.
//! Level 0 (the surface) is a pass-through: it is fully walkable.

const math = @import("../../core/math.zig");
const DataSystem = @import("../data_system.zig").DataSystem;
const MovementBodyPtr = @import("../data_system.zig").MovementBodyPtr;
const MovementBodySlice = @import("../data_system.zig").MovementBodySlice;
const PrimitiveVisual = @import("../data_system.zig").PrimitiveVisual;
const Player = @import("../player.zig").Player;
const WorldSystem = @import("../world_system.zig").WorldSystem;

pub fn apply(
    world: *const WorldSystem,
    data: *DataSystem,
    player: *Player,
    bounds_width: f32,
    bounds_height: f32,
) !void {
    clampAiEntitiesToBounds(data, bounds_width, bounds_height);
    try player.clampToBounds(data, bounds_width, bounds_height);
    gatePlayerToWalkableTiles(world, data, player.*);
    gateNpcEntitiesToWalkableTiles(world, data);
}

pub fn gatePlayerToWalkableTiles(world: *const WorldSystem, data: *DataSystem, player: Player) void {
    const body = data.movementBodyPtr(player.entity) orelse return;
    const visual = data.primitiveVisualConst(player.entity) orelse return;
    gateBodyToWalkableTiles(world, player.current_level, body, visual);
}

fn gateNpcEntitiesToWalkableTiles(world: *const WorldSystem, data: *DataSystem) void {
    const ai_slice = data.aiAgentSliceConst();
    const scope_columns = data.scopeColumnsSliceConst();
    const visuals = data.primitiveVisualSliceConst();
    var movement = data.movementBodySlice();
    for (ai_slice.entities) |entity| {
        const indices = data.movementVisualDenseIndices(entity) orelse continue;
        const mi = indices.movement;
        if (!scope_columns.tier[mi].allowsMovement()) continue;
        gateBodyColumnsToWalkableTiles(
            world,
            scope_columns.level[mi],
            &movement,
            mi,
            visuals.size_x[indices.visual],
            visuals.size_y[indices.visual],
        );
    }
}

fn gateBodyColumnsToWalkableTiles(
    world: *const WorldSystem,
    level: u16,
    movement: *MovementBodySlice,
    movement_index: usize,
    size_x: f32,
    size_y: f32,
) void {
    if (level == 0) return;
    const pre_x = movement.previous_x[movement_index];
    const pre_y = movement.previous_y[movement_index];
    const post_x = movement.position_x[movement_index];
    const post_y = movement.position_y[movement_index];

    var resolved_x = post_x;
    if (rectOverlapsSolidTile(world, level, post_x, pre_y, size_x, size_y)) resolved_x = pre_x;
    var resolved_y = post_y;
    if (rectOverlapsSolidTile(world, level, resolved_x, post_y, size_x, size_y)) resolved_y = pre_y;

    if (resolved_x != post_x) movement.velocity_x[movement_index] = 0;
    if (resolved_y != post_y) movement.velocity_y[movement_index] = 0;
    movement.position_x[movement_index] = resolved_x;
    movement.position_y[movement_index] = resolved_y;
}

fn gateBodyToWalkableTiles(world: *const WorldSystem, level: u16, body: MovementBodyPtr, visual: PrimitiveVisual) void {
    if (level == 0) return;
    const w = visual.size.x;
    const h = visual.size.y;
    const pre_x = body.previous_x.*;
    const pre_y = body.previous_y.*;
    const post_x = body.position_x.*;
    const post_y = body.position_y.*;

    var resolved_x = post_x;
    if (rectOverlapsSolidTile(world, level, post_x, pre_y, w, h)) resolved_x = pre_x;
    var resolved_y = post_y;
    if (rectOverlapsSolidTile(world, level, resolved_x, post_y, w, h)) resolved_y = pre_y;

    if (resolved_x != post_x) body.velocity_x.* = 0;
    if (resolved_y != post_y) body.velocity_y.* = 0;
    body.position_x.* = resolved_x;
    body.position_y.* = resolved_y;
}

pub fn rectOverlapsSolidTile(world: *const WorldSystem, level: u16, x: f32, y: f32, w: f32, h: f32) bool {
    const edge_epsilon: f32 = 0.5;
    const sample_xs = [_]f32{ x, x + w - edge_epsilon };
    const sample_ys = [_]f32{ y, y + h - edge_epsilon };
    for (sample_ys) |sy| {
        for (sample_xs) |sx| {
            const cell = world.cellContaining(sx, sy) orelse return true;
            if (world.levelBlocksMovement(level, cell.x, cell.y)) return true;
        }
    }
    return false;
}

fn clampAiEntitiesToBounds(data: *DataSystem, bounds_width: f32, bounds_height: f32) void {
    const ai_slice = data.aiAgentSliceConst();
    const scope_columns = data.scopeColumnsSliceConst();
    const visuals = data.primitiveVisualSliceConst();
    var movement = data.movementBodySlice();
    for (ai_slice.entities) |entity| {
        const indices = data.movementVisualDenseIndices(entity) orelse continue;
        const mi = indices.movement;
        if (!scope_columns.tier[mi].allowsMovement()) continue;

        const max_x = bounds_width - visuals.size_x[indices.visual];
        const new_x = math.clamp(movement.position_x[mi], 0, max_x);
        if (new_x != movement.position_x[mi]) movement.velocity_x[mi] = 0;
        movement.position_x[mi] = new_x;

        const max_y = bounds_height - visuals.size_y[indices.visual];
        const new_y = math.clamp(movement.position_y[mi], 0, max_y);
        if (new_y != movement.position_y[mi]) movement.velocity_y[mi] = 0;
        movement.position_y[mi] = new_y;
    }
}
