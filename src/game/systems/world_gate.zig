// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Bounds clamp and solid-tile gate for one settled movement step, on each body's
//! collision box (`position + offset`, `size`). One lane pass over the movement rows
//! clamps and gates every AI body with collision bounds on a moving tier, dispatched
//! under the system's tuner; the player row then runs on the main thread in a fixed
//! order. Each row reads only itself and the world's terrain. Level 0 (the surface) is
//! a pass-through: it is fully walkable.

const std = @import("std");
const builtin = @import("builtin");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const CollisionBounds = @import("../data_system.zig").CollisionBounds;
const DataSystem = @import("../data_system.zig").DataSystem;
const MovementBodyPtr = @import("../data_system.zig").MovementBodyPtr;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const Player = @import("../player.zig").Player;
const SimulationTier = @import("../simulation_scope.zig").SimulationTier;
const WorldSystem = @import("../world/system.zig").WorldSystem;

/// Range alignment of the gate pass: it writes f32 position and velocity columns.
pub const world_gate_range_alignment_items: usize = movement_range_alignment_items;

/// The gate pass's range controls: null `items_per_range` with `adaptive` trains the
/// system's tuner; an explicit `items_per_range` pins the range size.
pub const WorldGateConfig = struct {
    items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

// The far corners sample this far inside the box, so a box flush with a tile edge does
// not touch the next tile.
const edge_inset: f32 = 0.5;

// A row index no movement row has.
const no_row: usize = std.math.maxInt(usize);

pub const WorldGateSystem = struct {
    tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // The pass's last batch, kept only with `runtime_perf_log.enabled`.
    perf: Perf = .{},

    pub const Perf = if (runtime_perf_log.enabled) struct {
        last_batch: BatchStats = .{},
    } else struct {};

    /// Clamps every AI body with collision bounds on a moving tier into
    /// `[0, bounds_width] x [0, bounds_height]` and gates it off solid tiles on its scope
    /// level, as one pass over the movement rows dispatched per `config` under the
    /// system's tuner (inline below its gate). Then, on the calling thread: the AI clamp
    /// when the player is such a body, `Player.clampToBounds`, the player's gate on
    /// `player.current_level`, and the AI gate when the player is such a body. Writes only
    /// position and velocity; allocates nothing. Fails only when the player has no
    /// movement body.
    pub fn apply(
        self: *WorldGateSystem,
        world: *const WorldSystem,
        data: *DataSystem,
        player: *const Player,
        bounds_width: f32,
        bounds_height: f32,
        thread_system: *ThreadSystem,
        config: WorldGateConfig,
    ) !void {
        if (comptime runtime_perf_log.enabled) self.perf.last_batch = .{};
        const player_row = data.movementBodyDenseIndex(player.entity);
        var job = GateJob{
            .input = GateInput.of(world, data, bounds_width, bounds_height),
            .excluded_row = player_row orelse no_row,
            .range_count = 0,
        };
        const row_count = job.input.position_x.len;
        if (row_count > 0) {
            const gate = Dispatch.init(thread_system, &self.tuner, .{
                .items_per_range = config.items_per_range,
                .batches_per_participant = config.batches_per_participant,
                .max_worker_threads = config.max_worker_threads,
                .adaptive = config.adaptive,
            });
            const selection = gate.select(row_count, world_gate_range_alignment_items);
            job.range_count = selection.range_count;
            const batch = gate.run(selection, row_count, world_gate_range_alignment_items, &job, gateJob);
            if (comptime runtime_perf_log.enabled) self.perf.last_batch = batch;
        }

        // The player row, O(1) on the calling thread.
        const ai_row: ?usize = if (player_row) |row| (if (job.input.gatedBody(row)) row else null) else null;
        if (ai_row) |row| gateRange(&job.input, row, row + 1, no_row, .clamp);
        try player.clampToBounds(data, bounds_width, bounds_height);
        gatePlayerToWalkableTiles(world, data, player.*);
        if (ai_row) |row| gateRange(&job.input, row, row + 1, no_row, .gate);
    }
};

/// Gates the player's collision box on `player.current_level`; a player without a
/// movement body or collision bounds is left as is.
pub fn gatePlayerToWalkableTiles(world: *const WorldSystem, data: *DataSystem, player: Player) void {
    const body = data.movementBodyPtr(player.entity) orelse return;
    const bounds = data.collisionBoundsConst(player.entity) orelse return;
    gateBodyToWalkableTiles(world, player.current_level, body, bounds);
}

// Scalar gate of one body on `level`: x first at the previous y, then y at the resolved
// x; an axis whose box overlaps a solid or off-world cell keeps its previous coordinate
// and loses its velocity when that moved it.
fn gateBodyToWalkableTiles(world: *const WorldSystem, level: u16, body: MovementBodyPtr, bounds: CollisionBounds) void {
    if (level == 0) return;
    const w = bounds.size.x;
    const h = bounds.size.y;
    const pre_x = body.previous_x.*;
    const pre_y = body.previous_y.*;
    const post_x = body.position_x.*;
    const post_y = body.position_y.*;

    var resolved_x = post_x;
    if (rectOverlapsSolidTile(world, level, post_x + bounds.offset.x, pre_y + bounds.offset.y, w, h)) resolved_x = pre_x;
    var resolved_y = post_y;
    if (rectOverlapsSolidTile(world, level, resolved_x + bounds.offset.x, post_y + bounds.offset.y, w, h)) resolved_y = pre_y;

    if (resolved_x != post_x) body.velocity_x.* = 0;
    if (resolved_y != post_y) body.velocity_y.* = 0;
    body.position_x.* = resolved_x;
    body.position_y.* = resolved_y;
}

/// Whether the box at (`x`, `y`) of size `w` x `h` touches a solid or off-world cell on
/// `level`, sampled at its four corners with the far ones inset half a pixel.
pub fn rectOverlapsSolidTile(world: *const WorldSystem, level: u16, x: f32, y: f32, w: f32, h: f32) bool {
    const sample_xs = [_]f32{ x, x + w - edge_inset };
    const sample_ys = [_]f32{ y, y + h - edge_inset };
    for (sample_ys) |sy| {
        for (sample_xs) |sx| {
            const cell = world.cellContaining(sx, sy) orelse return true;
            if (world.levelBlocksMovement(level, cell.x, cell.y)) return true;
        }
    }
    return false;
}

// The columns one pass reads and writes, sliced once.
const GateInput = struct {
    world: *const WorldSystem,
    bounds_width: f32,
    bounds_height: f32,
    position_x: []f32,
    position_y: []f32,
    velocity_x: []f32,
    velocity_y: []f32,
    previous_x: []const f32,
    previous_y: []const f32,
    offset_x: []const f32,
    offset_y: []const f32,
    size_x: []const f32,
    size_y: []const f32,
    has_collision_bounds: []const bool,
    has_ai_agent: []const bool,
    tier: []const SimulationTier,
    level: []const u16,

    fn of(world: *const WorldSystem, data: *DataSystem, bounds_width: f32, bounds_height: f32) GateInput {
        const movement = data.movementBodySlice();
        const scope = data.scopeColumnsSliceConst();
        return .{
            .world = world,
            .bounds_width = bounds_width,
            .bounds_height = bounds_height,
            .position_x = movement.position_x,
            .position_y = movement.position_y,
            .velocity_x = movement.velocity_x,
            .velocity_y = movement.velocity_y,
            .previous_x = movement.previous_x,
            .previous_y = movement.previous_y,
            .offset_x = movement.bounds_offset_x,
            .offset_y = movement.bounds_offset_y,
            .size_x = movement.bounds_size_x,
            .size_y = movement.bounds_size_y,
            .has_collision_bounds = movement.has_collision_bounds,
            .has_ai_agent = movement.has_ai_agent,
            .tier = scope.tier,
            .level = scope.level,
        };
    }

    // An AI body with collision bounds on a moving tier: the rows the pass clamps.
    fn gatedBody(self: *const GateInput, row: usize) bool {
        return self.has_ai_agent[row] and self.has_collision_bounds[row] and self.tier[row].allowsMovement();
    }
};

const GateJob = struct {
    input: GateInput,
    // The player's row, which the main thread runs after the pass.
    excluded_row: usize,
    range_count: usize,
};

fn gateJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *GateJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    gateRange(&job.input, range.start, range.end, job.excluded_row, .clamp_and_gate);
}

// Which halves of the kernel a call runs: the pass runs both per row; the player row
// runs them apart around its own clamp and gate.
const GateSteps = enum {
    clamp_and_gate,
    clamp,
    gate,

    fn clamps(self: GateSteps) bool {
        return self != .gate;
    }

    fn gates(self: GateSteps) bool {
        return self != .clamp;
    }
};

// One level's blocked bits, re-resolved only when a lane's level differs from the last.
const LevelViews = struct {
    level: u16 = 0,
    view: ?WorldSystem.LevelBlockedView = null,
    resolved: bool = false,

    fn get(self: *LevelViews, world: *const WorldSystem, level: u16) ?WorldSystem.LevelBlockedView {
        if (!self.resolved or self.level != level) {
            self.level = level;
            self.view = world.levelBlockedView(level);
            self.resolved = true;
        }
        return self.view;
    }
};

// Clamps and gates rows `[start, end)` other than `excluded_row` in lane batches; the
// last batch is the same kernel masked to the rows left. Lanes outside the mask store
// their loaded values back unchanged.
fn gateRange(input: *const GateInput, start: usize, end: usize, excluded_row: usize, comptime steps: GateSteps) void {
    std.debug.assert(start <= end);
    std.debug.assert(end <= input.position_x.len);
    const zero = simd.splatFloat4(0);
    const bounds_width = simd.splatFloat4(input.bounds_width);
    const bounds_height = simd.splatFloat4(input.bounds_height);
    var levels: LevelViews = .{};
    var row = start;
    while (row < end) : (row += simd.lane_count) {
        const count = end - row;
        var bodies: simd.Mask4 = @splat(false);
        var gated: simd.Mask4 = @splat(false);
        // Scalar per lane: the membership columns are bool, enum, and u16, which have no
        // lane load in `simd.zig`.
        inline for (0..simd.lane_count) |lane| {
            if (lane < count and row + lane != excluded_row and input.gatedBody(row + lane)) {
                bodies[lane] = true;
                gated[lane] = input.level[row + lane] != 0;
            }
        }
        if (simd.maskBits(bodies) == 0) continue;

        var position_x = simd.loadFloat4Lanes(input.position_x[row..], count);
        var position_y = simd.loadFloat4Lanes(input.position_y[row..], count);
        var velocity_x = simd.loadFloat4Lanes(input.velocity_x[row..], count);
        var velocity_y = simd.loadFloat4Lanes(input.velocity_y[row..], count);
        const offset_x = simd.loadFloat4Lanes(input.offset_x[row..], count);
        const offset_y = simd.loadFloat4Lanes(input.offset_y[row..], count);
        const size_x = simd.loadFloat4Lanes(input.size_x[row..], count);
        const size_y = simd.loadFloat4Lanes(input.size_y[row..], count);

        if (comptime steps.clamps()) {
            // The box stays in [0, bounds]: position in [-offset, bounds - offset - size].
            const clamped_x = simd.clampFloat4(position_x, simd.subFloat4(zero, offset_x), simd.subFloat4(simd.subFloat4(bounds_width, offset_x), size_x));
            const clamped_y = simd.clampFloat4(position_y, simd.subFloat4(zero, offset_y), simd.subFloat4(simd.subFloat4(bounds_height, offset_y), size_y));
            velocity_x = simd.selectFloat4(bodies & (clamped_x != position_x), zero, velocity_x);
            velocity_y = simd.selectFloat4(bodies & (clamped_y != position_y), zero, velocity_y);
            position_x = simd.selectFloat4(bodies, clamped_x, position_x);
            position_y = simd.selectFloat4(bodies, clamped_y, position_y);
        }

        if (comptime steps.gates()) {
            if (simd.maskBits(gated) != 0) {
                const previous_x = simd.loadFloat4Lanes(input.previous_x[row..], count);
                const previous_y = simd.loadFloat4Lanes(input.previous_y[row..], count);
                // x first at the previous y, then y at the resolved x.
                const blocked_x = blockedLanes(input, &levels, row, gated, simd.addFloat4(position_x, offset_x), simd.addFloat4(previous_y, offset_y), size_x, size_y);
                const resolved_x = simd.selectFloat4(blocked_x, previous_x, position_x);
                const blocked_y = blockedLanes(input, &levels, row, gated, simd.addFloat4(resolved_x, offset_x), simd.addFloat4(position_y, offset_y), size_x, size_y);
                const resolved_y = simd.selectFloat4(blocked_y, previous_y, position_y);
                velocity_x = simd.selectFloat4(gated & (resolved_x != position_x), zero, velocity_x);
                velocity_y = simd.selectFloat4(gated & (resolved_y != position_y), zero, velocity_y);
                position_x = resolved_x;
                position_y = resolved_y;
            }
        }

        simd.storeFloat4Lanes(input.position_x[row..], position_x, count);
        simd.storeFloat4Lanes(input.position_y[row..], position_y, count);
        simd.storeFloat4Lanes(input.velocity_x[row..], velocity_x, count);
        simd.storeFloat4Lanes(input.velocity_y[row..], velocity_y, count);
    }
}

// The `lanes` whose box at (`box_x`, `box_y`) touches a solid or off-world cell on their
// row's level (`rectOverlapsSolidTile` per lane). The near and far corner cells come in
// lanes: every corner is in the world exactly when those two are, since each corner pairs
// one of their columns with one of their rows. Each active lane's blocked bits are read
// scalar, since each sits at a data-dependent chunk address.
fn blockedLanes(
    input: *const GateInput,
    levels: *LevelViews,
    row: usize,
    lanes: simd.Mask4,
    box_x: simd.Float4,
    box_y: simd.Float4,
    size_x: simd.Float4,
    size_y: simd.Float4,
) simd.Mask4 {
    const inset = simd.splatFloat4(edge_inset);
    const world = input.world;
    const near = world.cellContaining4(box_x, box_y);
    const far = world.cellContaining4(simd.subFloat4(simd.addFloat4(box_x, size_x), inset), simd.subFloat4(simd.addFloat4(box_y, size_y), inset));
    const inside = near.inside & far.inside;
    var blocked: simd.Mask4 = @splat(false);
    inline for (0..simd.lane_count) |lane| {
        if (lanes[lane]) {
            const view = levels.get(world, input.level[row + lane]);
            blocked[lane] = !inside[lane] or boxCellsBlocked(view, near.x[lane], near.y[lane], far.x[lane], far.y[lane]);
        }
    }
    return blocked;
}

// Whether any cell of the in-world box spanning cells (`x0`, `y0`) to (`x1`, `y1`) is
// blocked, each distinct corner cell read once; an invalid level blocks, as
// `levelBlocksMovement` does.
fn boxCellsBlocked(view: ?WorldSystem.LevelBlockedView, x0: i32, y0: i32, x1: i32, y1: i32) bool {
    const terrain = view orelse return true;
    if (cellBlocked(terrain, x0, y0)) return true;
    if (x1 != x0 and cellBlocked(terrain, x1, y0)) return true;
    if (y1 == y0) return false;
    if (cellBlocked(terrain, x0, y1)) return true;
    return x1 != x0 and cellBlocked(terrain, x1, y1);
}

fn cellBlocked(terrain: WorldSystem.LevelBlockedView, x: i32, y: i32) bool {
    // In the world, so both are non-negative and below the level's side.
    const column: usize = @intCast(x);
    const row: usize = @intCast(y);
    return terrain.blocked.get(terrain.geom.chunkOf(column, row), terrain.geom.localOf(column, row));
}

const AssetStore = @import("../../assets/assets.zig").AssetStore;
const manifest = @import("../../assets/manifest.zig");
const world_tileset_meta = @import("../../assets/world_tileset_meta.zig");
const component_masks = @import("../data_system.zig").component_masks;
const EntityId = @import("../data_system.zig").EntityId;

const test_tile: f32 = 32;
const test_side: u16 = 8;
const test_bounds: f32 = test_tile * test_side;

// A world whose level 1 floor is solid where `(3x + y) % 4 == 0`, whose level 2 floor is
// solid where `(x + 2y) % 5 == 0`, and walkable elsewhere.
const TestWorld = struct {
    meta: world_tileset_meta.WorldTilesetMeta,
    world: WorldSystem,

    // Built in place: the world borrows `&self.meta`.
    fn init(self: *TestWorld) !void {
        const allocator = std.testing.allocator;
        const asset_store = AssetStore.init(allocator, std.testing.io, "assets");
        self.meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
        errdefer self.meta.deinit();
        self.world = try WorldSystem.initDemoFromMetaWithUnderground(allocator, &self.meta, test_bounds, test_bounds);
        errdefer self.world.deinit();
        const solid = try self.world.requireTileByName(&self.meta, "dirt");
        const walkable = try self.world.requireTileByName(&self.meta, "cave_0");
        const floor_1 = self.world.denseFloorLayerForLevel(1).?;
        const floor_2 = self.world.denseFloorLayerForLevel(2).?;
        for (0..test_side) |y| for (0..test_side) |x| {
            _ = try self.world.setDenseTile(floor_1, @intCast(x), @intCast(y), if ((3 * x + y) % 4 == 0) solid else walkable);
            _ = try self.world.setDenseTile(floor_2, @intCast(x), @intCast(y), if ((x + 2 * y) % 5 == 0) solid else walkable);
        };
        std.debug.assert(self.world.levelBlocksMovement(1, 0, 0));
        std.debug.assert(!self.world.levelBlocksMovement(1, 1, 0));
        std.debug.assert(self.world.levelBlocksMovement(2, 1, 2));
        std.debug.assert(!self.world.levelBlocksMovement(2, 1, 1));
    }

    fn deinit(self: *TestWorld) void {
        self.world.deinit();
        self.meta.deinit();
    }
};

// One body of the parity population: every gate case by `index`, deterministic.
fn addParityBody(data: *DataSystem, index: usize) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .speed = 40 });
    if (index % 9 != 5) try data.setAiAgent(entity, .{});
    if (index % 13 != 6) {
        const offset: f32 = @floatFromInt(@as(i32, @intCast(index % 3)) - 1);
        // Sizes include a whole tile, so a far corner sits on the inset edge.
        const size: f32 = if (index % 5 == 1) test_tile else 10 + @as(f32, @floatFromInt(index % 4)) * 6;
        try data.setCollisionBounds(entity, .{ .offset = .{ .x = offset * 2, .y = -offset }, .size = .{ .x = size, .y = size - 2 } });
    }
    // Level 0 passes through; level 9 is past the world's levels and blocks.
    const level: u16 = if (index % 5 == 0) 0 else if (index % 11 == 3) 9 else 1;
    const tier: SimulationTier = switch (index % 7) {
        2 => .dormant,
        4 => .kinematic,
        else => .locomotion,
    };
    // Set before the positions: a non-moving tier snaps previous to current.
    try data.setSimulationMetadata(entity, .{ .tier = tier, .chunk = .{ .x = 0, .y = 0 }, .level = level });
    // Previous points span off-world on both sides; every sixth sits on a tile corner.
    const previous_x: f32 = if (index % 6 == 0) test_tile * @as(f32, @floatFromInt(index % test_side)) else @as(f32, @floatFromInt(index * 37 % 320)) - 32;
    const previous_y: f32 = if (index % 6 == 0) test_tile * @as(f32, @floatFromInt(index / 6 % test_side)) else @as(f32, @floatFromInt(index * 53 % 320)) - 32;
    const step_x = (@as(f32, @floatFromInt(index * 7 % 21)) - 10) * 1.5;
    const step_y = (@as(f32, @floatFromInt(index * 11 % 17)) - 8) * 2.25;
    const body = data.movementBodyPtr(entity).?;
    body.previous_x.* = previous_x;
    body.previous_y.* = previous_y;
    body.position_x.* = previous_x + step_x;
    body.position_y.* = previous_y + step_y;
    body.velocity_x.* = step_x * 60;
    body.velocity_y.* = step_y * 60;
    return entity;
}

fn buildParityData(population: usize) !DataSystem {
    var data = DataSystem.init(std.testing.allocator);
    errdefer data.deinit();
    for (0..population) |index| _ = try addParityBody(&data, index);
    return data;
}

fn expectColumnsEqual(want: *const DataSystem, got: *const DataSystem) !void {
    const want_rows = want.movementBodySliceConst();
    const got_rows = got.movementBodySliceConst();
    try std.testing.expectEqualSlices(f32, want_rows.position_x, got_rows.position_x);
    try std.testing.expectEqualSlices(f32, want_rows.position_y, got_rows.position_y);
    try std.testing.expectEqualSlices(f32, want_rows.velocity_x, got_rows.velocity_x);
    try std.testing.expectEqualSlices(f32, want_rows.velocity_y, got_rows.velocity_y);
}

test "world gate lanes match the scalar body gate on every case" {
    var fixture: TestWorld = undefined;
    try fixture.init();
    defer fixture.deinit();
    const world = &fixture.world;
    // Two lane batches per case cycle plus a masked tail.
    const population = 2 * 9 * 13 + 3;
    var lanes = try buildParityData(population);
    defer lanes.deinit();
    var scalar = try buildParityData(population);
    defer scalar.deinit();

    const input = GateInput.of(world, &lanes, test_bounds, test_bounds);
    gateRange(&input, 0, population, no_row, .clamp_and_gate);

    // Scalar reference per row: the clamp's scalar twin, then the body gate.
    const scope = scalar.scopeColumnsSliceConst();
    var gated_rows: usize = 0;
    var moved_rows: usize = 0;
    for (scope.entities, 0..) |entity, row| {
        const bounds = scalar.collisionBoundsConst(entity) orelse continue;
        if (!scalar.hasComponents(entity, component_masks.ai_agent) or !scope.tier[row].allowsMovement()) continue;
        const body = scalar.movementBodyPtr(entity).?;
        const clamped_x = math.clampMinMax(body.position_x.*, 0 - bounds.offset.x, test_bounds - bounds.offset.x - bounds.size.x);
        const clamped_y = math.clampMinMax(body.position_y.*, 0 - bounds.offset.y, test_bounds - bounds.offset.y - bounds.size.y);
        if (clamped_x != body.position_x.*) body.velocity_x.* = 0;
        if (clamped_y != body.position_y.*) body.velocity_y.* = 0;
        body.position_x.* = clamped_x;
        body.position_y.* = clamped_y;
        const settled_x = body.position_x.*;
        const settled_y = body.position_y.*;
        gateBodyToWalkableTiles(world, scope.level[row], body, bounds);
        gated_rows += 1;
        moved_rows += @intFromBool(settled_x != body.position_x.* or settled_y != body.position_y.*);
    }
    // The population reaches both outcomes of the gate.
    try std.testing.expect(gated_rows > population / 2);
    try std.testing.expect(moved_rows > 0 and moved_rows < gated_rows);
    try expectColumnsEqual(&scalar, &lanes);
}

test "world gate serial and threaded passes write identical columns" {
    if (builtin.single_threaded) return;
    var fixture: TestWorld = undefined;
    try fixture.init();
    defer fixture.deinit();
    const population = world_gate_range_alignment_items * 5 + 7;

    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var serial = try buildParityData(population);
    defer serial.deinit();
    var serial_player = try Player.spawn(&serial);
    serial_player.current_level = 1;
    var serial_gate: WorldGateSystem = .{};
    try serial_gate.apply(&fixture.world, &serial, &serial_player, test_bounds, test_bounds, &serial_threads, .{});

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    for ([_]usize{ world_gate_range_alignment_items, 2 * world_gate_range_alignment_items }) |items_per_range| {
        var threaded = try buildParityData(population);
        defer threaded.deinit();
        var threaded_player = try Player.spawn(&threaded);
        threaded_player.current_level = 1;
        var threaded_gate: WorldGateSystem = .{};
        try threaded_gate.apply(&fixture.world, &threaded, &threaded_player, test_bounds, test_bounds, &threads, .{
            .items_per_range = items_per_range,
            .max_worker_threads = 2,
            .adaptive = false,
        });
        try expectColumnsEqual(&serial, &threaded);
    }
}

test "a player that is also an AI agent gets the AI clamp, player clamp, player gate, then AI gate, once each" {
    var fixture: TestWorld = undefined;
    try fixture.init();
    defer fixture.deinit();
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var player = try Player.spawn(&data);
    try data.setAiAgent(player.entity, .{});
    try data.setCollisionBounds(player.entity, .{ .offset = .{ .x = 2, .y = 2 }, .size = .{ .x = 20, .y = 20 } });
    // The player stands on the surface; its world level, and so its scope row, says level
    // 1, where the AI gate runs.
    try data.setWorldLevel(player.entity, 1);
    const body = data.movementBodyPtr(player.entity).?;
    var gate: WorldGateSystem = .{};

    // Past the world's right edge in open row 0: the clamp holds the box at the edge
    // (x = 256 - 2 - 20), zeroing x velocity, and the AI gate keeps both axes in open
    // cell (7, 0).
    body.previous_x.* = 200;
    body.previous_y.* = 4;
    body.position_x.* = 300;
    body.position_y.* = 8;
    body.velocity_x.* = 90;
    body.velocity_y.* = 30;
    try gate.apply(&fixture.world, &data, &player, test_bounds, test_bounds, &serial_threads, .{});
    try std.testing.expectEqual(@as(f32, 234), body.position_x.*);
    try std.testing.expectEqual(@as(f32, 0), body.velocity_x.*);
    try std.testing.expectEqual(@as(f32, 8), body.position_y.*);
    try std.testing.expectEqual(@as(f32, 30), body.velocity_y.*);

    // From open cell (1, 0) into solid cell (0, 0): the player's own gate is a no-op on
    // the surface, and the AI gate on the scope level reverts x and zeroes its velocity.
    body.previous_x.* = 34;
    body.previous_y.* = 2;
    body.position_x.* = 20;
    body.position_y.* = 2;
    body.velocity_x.* = -60;
    body.velocity_y.* = 0;
    try gate.apply(&fixture.world, &data, &player, test_bounds, test_bounds, &serial_threads, .{});
    try std.testing.expectEqual(@as(f32, 34), body.position_x.*);
    try std.testing.expectEqual(@as(f32, 0), body.velocity_x.*);

    // The same move with the levels swapped: the player's gate on its current level
    // reverts it, and the AI gate passes through on the surface.
    player.current_level = 1;
    try data.setWorldLevel(player.entity, 0);
    body.position_x.* = 20;
    body.velocity_x.* = -60;
    try gate.apply(&fixture.world, &data, &player, test_bounds, test_bounds, &serial_threads, .{});
    try std.testing.expectEqual(@as(f32, 34), body.position_x.*);
    try std.testing.expectEqual(@as(f32, 0), body.velocity_x.*);

    // Two underground levels, from (0, 1) toward (1, 2): the player's level 2 keeps x in
    // open (1, 1) and blocks y at the new x in (1, 2); the AI gate's level 1 then blocks x
    // in (1, 1), so both axes end at the previous position. An AI gate run before the
    // player's would revert x first and let y into (0, 2), open on both levels.
    try data.setCollisionBounds(player.entity, .{ .size = .{ .x = 20, .y = 20 } });
    try data.setWorldLevel(player.entity, 1);
    player.current_level = 2;
    body.previous_x.* = 4;
    body.previous_y.* = 36;
    body.position_x.* = 36;
    body.position_y.* = 68;
    body.velocity_x.* = 60;
    body.velocity_y.* = 60;
    try gate.apply(&fixture.world, &data, &player, test_bounds, test_bounds, &serial_threads, .{});
    try std.testing.expectEqual(@as(f32, 4), body.position_x.*);
    try std.testing.expectEqual(@as(f32, 36), body.position_y.*);
    try std.testing.expectEqual(@as(f32, 0), body.velocity_x.*);
    try std.testing.expectEqual(@as(f32, 0), body.velocity_y.*);
}

test "a warmed world gate step allocates nothing, serial and on real workers" {
    var fixture: TestWorld = undefined;
    try fixture.init();
    defer fixture.deinit();
    const population = world_gate_range_alignment_items * 6;
    var data = try buildParityData(population);
    defer data.deinit();
    var player = try Player.spawn(&data);

    for ([_]usize{ 0, 2 }) |workers| {
        if (workers > 0 and builtin.single_threaded) continue;
        var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = workers });
        defer threads.deinit();
        var gate: WorldGateSystem = .{};
        const config = WorldGateConfig{ .items_per_range = world_gate_range_alignment_items, .max_worker_threads = workers, .adaptive = false };
        try gate.apply(&fixture.world, &data, &player, test_bounds, test_bounds, &threads, config);

        const original_data_allocator = data.allocator;
        const original_thread_allocator = threads.allocator;
        var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        data.allocator = failing_allocator.allocator();
        threads.allocator = failing_allocator.allocator();
        defer {
            data.allocator = original_data_allocator;
            threads.allocator = original_thread_allocator;
        }
        try gate.apply(&fixture.world, &data, &player, test_bounds, test_bounds, &threads, config);
        try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
    }
}
