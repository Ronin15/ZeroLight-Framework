// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pipeline-owned domain controller: first Slice 40 `action_intents` consumer.
//! Resolves interact/attack intents against `Destructible` entities, applies
//! same-step multi-hit damage in a fixed scratch, and queues deferred
//! structural commands + a `destructible_destroyed` domain event. Never mutates
//! DataSystem entity stores mid-step; no renderer/audio/SDL handles.

const std = @import("std");
const math = @import("../core/math.zig");
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const Destructible = @import("data_system.zig").Destructible;
const StructuralCommand = @import("data_system.zig").StructuralCommand;
const component_masks = @import("data_system.zig").component_masks;
const WorldSystem = @import("world_system.zig").WorldSystem;
const simulation = @import("simulation.zig");
const SimulationFrame = simulation.SimulationFrame;
const ActionIntent = simulation.ActionIntent;
const ActionKind = simulation.ActionKind;
const action_intent_live_capacity = simulation.action_intent_live_capacity;
const SimulationEvent = simulation.SimulationEvent;
const StructuralCommandStream = simulation.RangeOutputStream(StructuralCommand);
const ParticleSystem = @import("systems/particle.zig").ParticleSystem;

/// Fixed damage applied per accepted interact/attack intent (demo one-shot with hp=1).
const damage_per_hit: u8 = 1;

/// Max dense destructible rows examined per cell resolve. Fixed constant, independent of
/// world/map size and destructible population. Intent count is already capped at
/// `action_intent_live_capacity`; without this, each intent would scan every destructible
/// (O(intents × rows)). When the store is larger, later dense rows are not considered —
/// deterministic prefix drop: no hit among unscanned rows rather than unbounded work.
const destructible_cell_scan_budget: usize = 256;

/// Cell stamp when body→cell resolution fails for a target-only intent. Prefer this over
/// (0,0): tile (0,0) is a real world cell and would falsely attribute the destroy event.
const invalid_intent_cell: u16 = std.math.maxInt(u16);

/// Small soft-drop particle burst at body center on destroy.
const destroy_burst_count: usize = 6;
const destroy_burst_lifetime: f32 = 0.35;
const destroy_burst_start_size: f32 = 5;
const destroy_burst_velocity: f32 = 40;

pub const DestructibleProcessStats = struct {
    /// Merged action-intent count observed this step (stub-compatible).
    intents_consumed: usize = 0,
    /// Entities that will be destroyed by queued commands this step.
    destroyed: usize = 0,
    /// Entities that took damage but remain alive after net same-step hits.
    hits: usize = 0,
};

const PendingDamage = struct {
    entity: EntityId,
    remaining_hp: u8,
    flags: Destructible,
    cause: ActionKind,
    level: u16,
    cell_x: u16,
    cell_y: u16,
};

pub const DestructibleController = struct {
    pub fn init() DestructibleController {
        return .{};
    }

    /// Consumes merged `action_intents` and queues structural + domain outputs.
    /// Soft-drops particle burst when the pool is full. Structural/event capacity
    /// is preflighted before any queue write (dig pattern).
    pub fn process(
        self: *const DestructibleController,
        frame: *SimulationFrame,
        data: *const DataSystem,
        world: *const WorldSystem,
        particles: ?*ParticleSystem,
    ) !DestructibleProcessStats {
        _ = self;
        const intents = frame.action_intents.mergedItems();
        var stats = DestructibleProcessStats{ .intents_consumed = intents.len };
        if (intents.len == 0) return stats;

        var pending: [action_intent_live_capacity]PendingDamage = undefined;
        var pending_count: usize = 0;

        for (intents) |intent| {
            applyIntentDamage(data, world, intent, &pending, &pending_count);
        }
        if (pending_count == 0) return stats;

        var commands: [action_intent_live_capacity]StructuralCommand = undefined;
        var command_count: usize = 0;
        var events: [action_intent_live_capacity]SimulationEvent = undefined;
        var event_count: usize = 0;

        for (pending[0..pending_count]) |entry| {
            if (entry.remaining_hp == 0) {
                events[event_count] = .{
                    .stage = .domain_reaction,
                    .payload = .{ .destructible_destroyed = .{
                        .entity = entry.entity,
                        .level = entry.level,
                        .cell_x = entry.cell_x,
                        .cell_y = entry.cell_y,
                        .cause = entry.cause,
                    } },
                };
                event_count += 1;
                commands[command_count] = .{ .destroy_entity = entry.entity };
                command_count += 1;
                stats.destroyed += 1;
            } else {
                commands[command_count] = .{ .set_destructible = .{
                    .entity = entry.entity,
                    .destructible = .{
                        .hit_points = entry.remaining_hp,
                        .destroy_on_interact = entry.flags.destroy_on_interact,
                        .destroy_on_attack = entry.flags.destroy_on_attack,
                    },
                } };
                command_count += 1;
                stats.hits += 1;
            }
        }

        // Preflight event + structural capacity before queuing so a full budget
        // cannot leave partial outputs (dig pattern).
        if (event_count > 0) {
            try frame.events.ensureEventAppendCapacity(event_count);
        }
        if (command_count > 0) {
            try ensureStructuralAppendCapacity(&frame.structural_commands, 1, command_count);
        }

        if (command_count > 0) {
            const range_base = try frame.structural_commands.appendRangeCounts(1);
            frame.structural_commands.addCount(range_base, command_count);
            try frame.structural_commands.prefixAppendedRanges(range_base);
            var writer = frame.structural_commands.rangeWriter(range_base);
            for (commands[0..command_count]) |command| writer.write(command);
            writer.finish();
            frame.structural_commands.finishWrite();
        }

        if (event_count > 0) {
            // Batched domain events: single finishWrite (O(ranges) rebuild).
            const first_range = try frame.events.appendRangeCounts(1);
            frame.events.addCount(first_range, event_count);
            try frame.events.prefixAppendedRanges(first_range);
            var event_writer = frame.events.rangeWriter(first_range);
            for (events[0..event_count]) |event| event_writer.write(event);
            event_writer.finish();
            frame.events.finishWrite();
        }

        if (particles) |particle_system| {
            for (pending[0..pending_count]) |entry| {
                if (entry.remaining_hp != 0) continue;
                emitDestroyBurst(particle_system, data, entry.entity);
            }
        }

        return stats;
    }
};

fn ensureStructuralAppendCapacity(
    stream: *StructuralCommandStream,
    range_count: usize,
    value_count: usize,
) !void {
    const alloc = stream.allocator;
    const new_range_count = stream.counts.items.len + range_count;
    try stream.counts.ensureTotalCapacity(alloc, new_range_count);
    try stream.offsets.ensureTotalCapacity(alloc, new_range_count);
    try stream.write_offsets.ensureTotalCapacity(alloc, new_range_count);
    const new_value_count = if (stream.prefix_ready)
        stream.mergedItems().len + value_count
    else blk: {
        var pending_values: usize = 0;
        for (stream.counts.items) |count| pending_values += count;
        break :blk pending_values + value_count;
    };
    try stream.values.ensureTotalCapacity(alloc, new_value_count);
}

fn applyIntentDamage(
    data: *const DataSystem,
    world: *const WorldSystem,
    intent: ActionIntent,
    pending: *[action_intent_live_capacity]PendingDamage,
    pending_count: *usize,
) void {
    const kind = intent.kind;
    if (kind != .interact and kind != .attack) return;

    const target = resolveTarget(data, world, intent) orelse return;
    const flags = data.destructibleConst(target) orelse return;
    if (kind == .interact and !flags.destroy_on_interact) return;
    if (kind == .attack and !flags.destroy_on_attack) return;

    const cell = intentCell(intent, data, target, world);

    // Same-step multi-hit: accumulate in fixed scratch by entity.
    if (findPending(pending, pending_count.*, target)) |index| {
        const entry = &pending[index];
        entry.remaining_hp = saturatingSub(entry.remaining_hp, damage_per_hit);
        // First cause wins for the domain event (deterministic intent order).
        return;
    }

    if (pending_count.* >= action_intent_live_capacity) return;
    const base_hp = flags.hit_points;
    pending[pending_count.*] = .{
        .entity = target,
        .remaining_hp = saturatingSub(base_hp, damage_per_hit),
        .flags = flags,
        .cause = kind,
        .level = cell.level,
        .cell_x = cell.x,
        .cell_y = cell.y,
    };
    pending_count.* += 1;
}

const IntentCell = struct { level: u16, x: u16, y: u16 };

fn intentCell(intent: ActionIntent, data: *const DataSystem, target: EntityId, world: *const WorldSystem) IntentCell {
    if (intent.has_cell) {
        return .{ .level = intent.level, .x = intent.cell_x, .y = intent.cell_y };
    }
    // Target-only intents: stamp body center cell when available.
    if (data.movementBodyConst(target)) |body| {
        if (world.cellContaining(body.position.x, body.position.y)) |cell| {
            const level = data.worldLevelConst(target) orelse 0;
            return .{ .level = level, .x = cell.x, .y = cell.y };
        }
    }
    // No resolvable body cell: invalid sentinel, not intent defaults (0,0) or a fake tile.
    const level = data.worldLevelConst(target) orelse intent.level;
    return .{ .level = level, .x = invalid_intent_cell, .y = invalid_intent_cell };
}

fn findPending(pending: *const [action_intent_live_capacity]PendingDamage, count: usize, entity: EntityId) ?usize {
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (pending[i].entity.eql(entity)) return i;
    }
    return null;
}

fn saturatingSub(value: u8, amount: u8) u8 {
    if (amount >= value) return 0;
    return value - amount;
}

fn resolveTarget(data: *const DataSystem, world: *const WorldSystem, intent: ActionIntent) ?EntityId {
    // Explicit target never falls through to cell scan: a living non-destructible
    // (or stale) target is a no-op even when has_cell is set. Cell resolve only
    // when the producer left target invalid (player interact stamps cell only).
    if (intent.target.isValid()) {
        if (!data.isAlive(intent.target)) return null;
        if (data.destructibleConst(intent.target) == null) return null;
        return intent.target;
    }
    if (!intent.has_cell) return null;
    return findDestructibleAtCell(data, world, intent.level, intent.cell_x, intent.cell_y);
}

/// Lowest entity.index, then generation, among destructibles whose collision
/// AABB contains the cell center on the intent level (missing world_level → 0).
/// Scans at most `destructible_cell_scan_budget` dense rows (fixed, not map-scaled).
fn findDestructibleAtCell(
    data: *const DataSystem,
    world: *const WorldSystem,
    level: u16,
    cell_x: u16,
    cell_y: u16,
) ?EntityId {
    const center_x = (@as(f32, @floatFromInt(cell_x)) + 0.5) * world.tile_size;
    const center_y = (@as(f32, @floatFromInt(cell_y)) + 0.5) * world.tile_size;
    const cell_min_x = @as(f32, @floatFromInt(cell_x)) * world.tile_size;
    const cell_min_y = @as(f32, @floatFromInt(cell_y)) * world.tile_size;
    const cell_max_x = cell_min_x + world.tile_size;
    const cell_max_y = cell_min_y + world.tile_size;

    const slice = data.destructibleSliceConst();
    const scan_limit = @min(slice.entities.len, destructible_cell_scan_budget);
    var best: ?EntityId = null;
    var i: usize = 0;
    while (i < scan_limit) : (i += 1) {
        const entity = slice.entities[i];
        if (!data.isAlive(entity)) continue;
        const entity_level = data.worldLevelConst(entity) orelse 0;
        if (entity_level != level) continue;
        if ((data.componentMaskFor(entity) & component_masks.collision_bounds) == 0) continue;
        if ((data.componentMaskFor(entity) & component_masks.movement_body) == 0) continue;
        const body = data.movementBodyConst(entity) orelse continue;
        const bounds = data.collisionBoundsConst(entity) orelse continue;
        const aabb = math.aabbFromOffsetSize(body.position, bounds.offset, bounds.size);
        const contains_center = center_x >= aabb.min_x and center_x < aabb.max_x and
            center_y >= aabb.min_y and center_y < aabb.max_y;
        const overlaps_cell = aabb.min_x < cell_max_x and aabb.max_x > cell_min_x and
            aabb.min_y < cell_max_y and aabb.max_y > cell_min_y;
        if (!contains_center and !overlaps_cell) continue;
        if (best) |current| {
            if (entity.index < current.index or
                (entity.index == current.index and entity.generation < current.generation))
            {
                best = entity;
            }
        } else {
            best = entity;
        }
    }
    return best;
}

fn emitDestroyBurst(particles: *ParticleSystem, data: *const DataSystem, entity: EntityId) void {
    const body = data.movementBodyConst(entity) orelse return;
    const visual = data.primitiveVisualConst(entity);
    const cx = body.position.x + if (visual) |v| v.size.x * 0.5 else 0;
    const cy = body.position.y + if (visual) |v| v.size.y * 0.5 else 0;
    _ = particles.emitBurst(.{
        .count = destroy_burst_count,
        .position = .{ .x = cx, .y = cy },
        .base_z = body.position_z,
        .base_velocity = .{ .x = -destroy_burst_velocity, .y = -destroy_burst_velocity },
        .velocity_step = .{ .x = destroy_burst_velocity * 0.4, .y = destroy_burst_velocity * 0.35 },
        .lifetime = destroy_burst_lifetime,
        .lifetime_step = 0.02,
        .start_size = destroy_burst_start_size,
        .end_size = 0,
        .start_color = .{ .r = 0.85, .g = 0.55, .b = 0.25, .a = 1 },
        .end_color = .{ .r = 0.4, .g = 0.25, .b = 0.1, .a = 0 },
        .depth = .effect,
    });
}

// ---- Tests ------------------------------------------------------------------

fn makeMinimalWorld() WorldSystem {
    return .{
        .allocator = std.testing.allocator,
        .width = 8,
        .height = 8,
        .tile_size = 32,
        .chunk_size_tiles = 4,
    };
}

fn spawnCrate(data: *DataSystem, x: f32, y: f32, size: f32, hp: u8) !EntityId {
    const entity = try data.createEntity();
    errdefer _ = data.destroyEntity(entity);
    try data.setMovementBody(entity, .{
        .position = .{ .x = x, .y = y },
        .previous_position = .{ .x = x, .y = y },
    });
    try data.setCollisionBounds(entity, .{ .size = .{ .x = size, .y = size } });
    try data.setCollisionResponse(entity, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    try data.setDestructible(entity, .{ .hit_points = hp });
    return entity;
}

test "DestructibleController no intents leaves world unchanged" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    const crate = try spawnCrate(&data, 32, 32, 32, 1);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 0, 0, 0, 4);
    frame.beginStep();

    const controller = DestructibleController.init();
    const stats = try controller.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 0), stats.intents_consumed);
    try std.testing.expectEqual(@as(usize, 0), stats.destroyed);
    try std.testing.expect(data.isAlive(crate));
    try std.testing.expectEqual(@as(usize, 0), frame.structural_commands.mergedItems().len);
}

test "DestructibleController interact on faced cell destroys crate via deferred commands" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    // Crate covers cell (1,1) center at (48,48) with size 32 at (32,32).
    const crate = try spawnCrate(&data, 32, 32, 32, 1);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 0, 0, 0, 4);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .interact,
        .cell_x = 1,
        .cell_y = 1,
        .level = 0,
        .has_cell = true,
    });

    const controller = DestructibleController.init();
    const stats = try controller.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.intents_consumed);
    try std.testing.expectEqual(@as(usize, 1), stats.destroyed);

    // Entity still alive until structural commit.
    try std.testing.expect(data.isAlive(crate));
    const commands = frame.structural_commands.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqual(crate.index, commands[0].destroy_entity.index);

    var domain_events: usize = 0;
    for (frame.events.mergedItems()) |event| {
        if (event.payload == .destructible_destroyed) {
            domain_events += 1;
            try std.testing.expectEqual(crate.index, event.payload.destructible_destroyed.entity.index);
            try std.testing.expectEqual(ActionKind.interact, event.payload.destructible_destroyed.cause);
            try std.testing.expectEqual(@import("simulation.zig").SimulationEventStage.domain_reaction, event.stage);
            try std.testing.expectEqual(@as(u16, 1), event.payload.destructible_destroyed.cell_x);
            try std.testing.expectEqual(@as(u16, 1), event.payload.destructible_destroyed.cell_y);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), domain_events);

    _ = try data.applyStructuralCommands(commands);
    try std.testing.expect(!data.isAlive(crate));
}

test "DestructibleController multi-hit same step nets one destroy" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    const crate = try spawnCrate(&data, 32, 32, 32, 2);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 0, 0, 0, 4);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .attack,
        .target = crate,
    });
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .attack,
        .target = crate,
    });

    const controller = DestructibleController.init();
    const stats = try controller.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 2), stats.intents_consumed);
    try std.testing.expectEqual(@as(usize, 1), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 0), stats.hits);
    try std.testing.expectEqual(@as(usize, 1), frame.structural_commands.mergedItems().len);
}

test "DestructibleController target-only destroy stamps body cell not (0,0)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    // Body at (32,32) → cell (1,1) with tile_size 32.
    const crate = try spawnCrate(&data, 32, 32, 32, 1);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 0, 0, 0, 4);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .attack,
        .target = crate,
        // has_cell false: cell_x/y default 0 — must not stamp (0,0).
    });

    const controller = DestructibleController.init();
    _ = try controller.process(&frame, &data, &world, null);

    var saw = false;
    for (frame.events.mergedItems()) |event| {
        if (event.payload != .destructible_destroyed) continue;
        const destroyed = event.payload.destructible_destroyed;
        try std.testing.expectEqual(@as(u16, 1), destroyed.cell_x);
        try std.testing.expectEqual(@as(u16, 1), destroyed.cell_y);
        saw = true;
    }
    try std.testing.expect(saw);
}

test "DestructibleController off-world target stamps invalid cell sentinel" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    // Far outside the 8×8 / tile_size 32 world so cellContaining fails.
    const crate = try spawnCrate(&data, -1000, -1000, 32, 1);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 0, 0, 0, 4);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .attack,
        .target = crate,
    });

    const controller = DestructibleController.init();
    _ = try controller.process(&frame, &data, &world, null);

    var saw = false;
    for (frame.events.mergedItems()) |event| {
        if (event.payload != .destructible_destroyed) continue;
        const destroyed = event.payload.destructible_destroyed;
        try std.testing.expectEqual(invalid_intent_cell, destroyed.cell_x);
        try std.testing.expectEqual(invalid_intent_cell, destroyed.cell_y);
        saw = true;
    }
    try std.testing.expect(saw);
}

test "DestructibleController multi-hit partial set_destructible when hp remains" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    const crate = try spawnCrate(&data, 32, 32, 32, 3);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 0, 0, 0, 4);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .attack,
        .target = crate,
    });

    const controller = DestructibleController.init();
    const stats = try controller.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.hits);
    try std.testing.expectEqual(@as(usize, 0), stats.destroyed);
    const commands = frame.structural_commands.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqual(@as(u8, 2), commands[0].set_destructible.destructible.hit_points);

    // Commit path must apply set_destructible (not only queue the payload).
    _ = try frame.applyStructuralCommands(&data);
    try std.testing.expect(data.isAlive(crate));
    try std.testing.expectEqual(@as(u8, 2), data.destructibleConst(crate).?.hit_points);
}

test "DestructibleController ignores use/signal and respects destroy_on flags" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    const crate = try spawnCrate(&data, 32, 32, 32, 1);
    try data.setDestructible(crate, .{
        .hit_points = 1,
        .destroy_on_interact = false,
        .destroy_on_attack = true,
    });

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 0, 0, 0, 4);
    frame.beginStep();
    try frame.appendActionIntent(.{ .entity = EntityId.invalid, .kind = .use, .target = crate });
    try frame.appendActionIntent(.{ .entity = EntityId.invalid, .kind = .signal, .target = crate });
    try frame.appendActionIntent(.{ .entity = EntityId.invalid, .kind = .interact, .target = crate });

    const controller = DestructibleController.init();
    const stats = try controller.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 3), stats.intents_consumed);
    try std.testing.expectEqual(@as(usize, 0), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 0), frame.structural_commands.mergedItems().len);
}

test "DestructibleController deterministic multi-candidate lowest entity index" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    // Two overlapping crates; lower index must win.
    const first = try spawnCrate(&data, 32, 32, 32, 1);
    const second = try spawnCrate(&data, 32, 32, 32, 1);
    try std.testing.expect(first.index < second.index);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 0, 0, 0, 4);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .interact,
        .cell_x = 1,
        .cell_y = 1,
        .level = 0,
        .has_cell = true,
    });

    const controller = DestructibleController.init();
    _ = try controller.process(&frame, &data, &world, null);
    const commands = frame.structural_commands.mergedItems();
    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqual(first.index, commands[0].destroy_entity.index);
}

test "destructible_destroyed event payload is scalar-only" {
    // Payload purity: every field is a scalar or enum (no pointers/handles/slices).
    comptime {
        const Payload = simulation.DestructibleDestroyedEvent;
        for (@typeInfo(Payload).@"struct".fields) |field| {
            const T = field.type;
            switch (@typeInfo(T)) {
                .int, .float, .bool, .@"enum", .@"struct" => {},
                else => @compileError("destructible_destroyed field not scalar/enum: " ++ field.name),
            }
        }
    }
}

test "DestructibleController does not dual-write navigation or movement intents" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    _ = try spawnCrate(&data, 32, 32, 32, 1);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 4, 0, 0, 4);
    try frame.reserveNavigationIntents(1, 1);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .interact,
        .cell_x = 1,
        .cell_y = 1,
        .level = 0,
        .has_cell = true,
    });

    const controller = DestructibleController.init();
    _ = try controller.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 0), frame.intents.mergedItems().len);
    try std.testing.expectEqual(@as(usize, 0), frame.navigation_intents.mergedItems().len);
}

test "DestructibleController process is allocation-free after stream reserve (FailingAllocator)" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    // Two crates: one destroyed (events + destroy cmd), one multi-hit partial (set cmd).
    const smash = try spawnCrate(&data, 32, 32, 32, 1);
    const dent = try spawnCrate(&data, 96, 32, 32, 3);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(8, 16, 0, 0, 0, 16);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .interact,
        .cell_x = 1,
        .cell_y = 1,
        .level = 0,
        .has_cell = true,
    });
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .attack,
        .target = dent,
    });

    // Prove the reserved-then-push queue path: structural + event stream growth
    // must not allocate after dual-axis reserve (ReleaseFast strips assumeCapacity).
    var failing_struct = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    var failing_events = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    const orig_struct = frame.structural_commands.allocator;
    const orig_events = frame.events.stream.allocator;
    frame.structural_commands.allocator = failing_struct.allocator();
    frame.events.stream.allocator = failing_events.allocator();
    defer {
        frame.structural_commands.allocator = orig_struct;
        frame.events.stream.allocator = orig_events;
    }

    const controller = DestructibleController.init();
    const stats = try controller.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 2), stats.intents_consumed);
    try std.testing.expectEqual(@as(usize, 1), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 1), stats.hits);
    try std.testing.expectEqual(@as(usize, 2), frame.structural_commands.mergedItems().len);
    try std.testing.expect(data.isAlive(smash));
    try std.testing.expect(data.isAlive(dent));
}

test "DestructibleController explicit non-destructible target does not fall through to cell" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    // Crate sits on cell (1,1); a living non-destructible is the explicit target.
    const crate = try spawnCrate(&data, 32, 32, 32, 1);
    const decoy = try data.createEntity();
    try data.setMovementBody(decoy, .{
        .position = .{ .x = 0, .y = 0 },
        .previous_position = .{ .x = 0, .y = 0 },
    });
    try std.testing.expect(data.destructibleConst(decoy) == null);

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(4, 4, 0, 0, 0, 4);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .interact,
        .target = decoy,
        .cell_x = 1,
        .cell_y = 1,
        .level = 0,
        .has_cell = true,
    });

    const controller = DestructibleController.init();
    const stats = try controller.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.intents_consumed);
    try std.testing.expectEqual(@as(usize, 0), stats.destroyed);
    try std.testing.expectEqual(@as(usize, 0), frame.structural_commands.mergedItems().len);
    try std.testing.expect(data.isAlive(crate));
    try std.testing.expect(data.isAlive(decoy));
}

test "DestructibleController destroy emits static-nav entity_destroyed with obstacle rect" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var world = makeMinimalWorld();
    defer world.deinit();
    // spawnCrate attaches static solid collision → isStaticNavigationObstacle.
    const crate = try spawnCrate(&data, 32, 32, 32, 1);
    try data.setWorldLevel(crate, 0);
    try std.testing.expect(data.isStaticNavigationObstacle(crate));

    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveActionIntents(action_intent_live_capacity, action_intent_live_capacity);
    try frame.reserveStreams(8, 16, 0, 0, 0, 8);
    frame.beginStep();
    try frame.appendActionIntent(.{
        .entity = EntityId.invalid,
        .kind = .interact,
        .cell_x = 1,
        .cell_y = 1,
        .level = 0,
        .has_cell = true,
    });

    const controller = DestructibleController.init();
    const stats = try controller.process(&frame, &data, &world, null);
    try std.testing.expectEqual(@as(usize, 1), stats.destroyed);

    _ = try frame.applyStructuralCommands(&data);
    try std.testing.expect(!data.isAlive(crate));

    var saw_nav_destroy = false;
    for (frame.events.mergedItems()) |event| {
        if (event.payload != .entity_destroyed) continue;
        const destroyed = event.payload.entity_destroyed;
        if (destroyed.entity.index != crate.index) continue;
        try std.testing.expect(destroyed.was_static_navigation_obstacle);
        try std.testing.expect(destroyed.obstacle_world_rect != null);
        const rect = destroyed.obstacle_world_rect.?;
        try std.testing.expect(rect.max_x > rect.min_x);
        try std.testing.expect(rect.max_y > rect.min_y);
        try std.testing.expectEqual(@as(u16, 0), destroyed.level);
        saw_nav_destroy = true;
    }
    try std.testing.expect(saw_nav_destroy);
}
