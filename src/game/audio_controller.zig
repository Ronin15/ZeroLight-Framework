// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pipeline-owned audio controller.
//! Turns per-step input and collision contacts into `AudioCommandBuffer` intents:
//! ambient music, a movement-gated player jet loop, and collision SFX with
//! per-pair cooldowns. Owns only audio-policy runtime state (cooldown buffer and
//! music/loop latches); the app owns the mixer, tracks, and command buffer. The
//! pipeline composes it like any other light domain controller.

const std = @import("std");
const math = @import("../core/math.zig");
const AudioCommandBuffer = @import("../app/audio.zig").AudioCommandBuffer;
const LoopingSfxId = @import("../app/audio.zig").LoopingSfxId;
const InputState = @import("../app/input.zig").InputState;
const AudioAssetId = @import("../assets/manifest.zig").AudioAssetId;
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const Player = @import("player.zig").Player;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const CollisionContact = @import("simulation.zig").CollisionContact;

const cooldown_capacity = 32;
const cooldown_seconds: f32 = 0.14;
const demo_music = AudioAssetId.demo_music;
const collision_sfx = AudioAssetId.collision_sfx;
const jet_sfx = AudioAssetId.player_jet_sfx;
const player_jet_loop_id = LoopingSfxId{ .value = 1 };

pub const AudioController = struct {
    cooldowns: [cooldown_capacity]CollisionSfxCooldown = undefined,
    cooldown_count: usize = 0,
    music_started: bool = false,
    jet_loop_active: bool = false,
    // Set when a pause interrupts an active jet loop: onPause has no audio command
    // buffer, so the stale engine-side loop is stopped on the first update after
    // resume before the movement edge can re-trigger it.
    jet_loop_stop_pending: bool = false,

    pub fn init() AudioController {
        return .{};
    }

    /// Queues one-time music startup and edge-driven jet-loop start/stop from the
    /// player's movement, plus the audio listener at the player's center.
    pub fn queueAmbient(self: *AudioController, audio: *AudioCommandBuffer, input: *const InputState, data: *const DataSystem, player: Player) void {
        if (!self.music_started) {
            audio.playMusic(.{
                .asset = demo_music,
                .gain = 1.0,
                .loop = true,
                .fade_in_ms = 750,
            }) catch return;
            self.music_started = true;
        }

        if (self.jet_loop_stop_pending) {
            audio.stopLoopingSfx(player_jet_loop_id) catch {};
            self.jet_loop_stop_pending = false;
        }

        if (data.movementBodyConst(player.entity)) |body| {
            audio.setListener(.{ .x = body.position.x + 16, .y = body.position.y + 16 }) catch {};
            const player_moving = input.movementVector().x != 0 or input.movementVector().y != 0;
            if (player_moving and !self.jet_loop_active) {
                audio.startLoopingSfx(player_jet_loop_id, .{
                    .asset = jet_sfx,
                    .gain = 0.34,
                    .priority = 220,
                    .frequency_ratio = 1.0,
                    .position = .{ .x = body.position.x + 16, .y = body.position.y + 16 },
                }) catch {};
                self.jet_loop_active = true;
            } else if (!player_moving and self.jet_loop_active) {
                audio.stopLoopingSfx(player_jet_loop_id) catch {};
                self.jet_loop_active = false;
            }
        }
    }

    /// Plays a positional collision SFX per fresh contact pair involving the
    /// player, gated by per-pair cooldowns so a persistent contact does not
    /// spam the mixer. Contacts between two non-player entities never play a
    /// sound: at high population counts, NPC-vs-NPC contacts dominate mass
    /// pileups and would otherwise overload the mixer with simultaneous
    /// collision triggers every step.
    pub fn queueCollision(self: *AudioController, audio: *AudioCommandBuffer, frame: *const SimulationFrame, data: *const DataSystem, player_entity: EntityId, delta_seconds: f32) void {
        self.tickCooldowns(delta_seconds);
        for (frame.contacts.mergedItems()) |contact| {
            if (!involvesEntity(contact, player_entity)) continue;
            if (self.pairOnCooldown(contact.a, contact.b)) continue;
            const position = contactAudioPosition(data, contact) orelse continue;
            const gain = std.math.clamp(contact.penetration / 18.0, 0.25, 1.0);
            const frequency_ratio = collisionSfxFrequencyRatio(contact);
            audio.playSfx(.{
                .asset = collision_sfx,
                .gain = gain,
                .priority = 180,
                .frequency_ratio = frequency_ratio,
                .position = position,
            }) catch |err| switch (err) {
                error.AudioCommandLimitReached => break,
                else => continue,
            };
            self.addCooldown(contact.a, contact.b);
        }
    }

    /// On gameplay pause: no command buffer is available, so flag the active loop
    /// to be stopped on the first update after resume.
    pub fn onPause(self: *AudioController) void {
        if (self.jet_loop_active) self.jet_loop_stop_pending = true;
        self.jet_loop_active = false;
    }

    fn tickCooldowns(self: *AudioController, delta_seconds: f32) void {
        var index: usize = 0;
        while (index < self.cooldown_count) {
            self.cooldowns[index].remaining_seconds -= delta_seconds;
            if (self.cooldowns[index].remaining_seconds <= 0) {
                self.cooldown_count -= 1;
                self.cooldowns[index] = self.cooldowns[self.cooldown_count];
            } else {
                index += 1;
            }
        }
    }

    fn pairOnCooldown(self: *const AudioController, a: EntityId, b: EntityId) bool {
        const key = CollisionSfxCooldown.keyFor(a, b);
        for (self.cooldowns[0..self.cooldown_count]) |cooldown| {
            if (cooldown.key == key) return true;
        }
        return false;
    }

    fn addCooldown(self: *AudioController, a: EntityId, b: EntityId) void {
        const key = CollisionSfxCooldown.keyFor(a, b);
        if (self.cooldown_count < self.cooldowns.len) {
            self.cooldowns[self.cooldown_count] = .{
                .key = key,
                .remaining_seconds = cooldown_seconds,
            };
            self.cooldown_count += 1;
            return;
        }

        // Full: evict the slot with the least remaining time (gives newest collision
        // the longest protection). Linear scan is acceptable (N<=32, cold path).
        var min_idx: usize = 0;
        var min_rem = self.cooldowns[0].remaining_seconds;
        for (1..self.cooldown_count) |i| {
            if (self.cooldowns[i].remaining_seconds < min_rem) {
                min_rem = self.cooldowns[i].remaining_seconds;
                min_idx = i;
            }
        }
        self.cooldowns[min_idx] = .{
            .key = key,
            .remaining_seconds = cooldown_seconds,
        };
    }
};

/// Whether `entity` is either side of `contact`.
fn involvesEntity(contact: CollisionContact, entity: EntityId) bool {
    return entitiesEqual(contact.a, entity) or entitiesEqual(contact.b, entity);
}

fn entitiesEqual(a: EntityId, b: EntityId) bool {
    return a.index == b.index and a.generation == b.generation;
}

fn contactAudioPosition(data: *const DataSystem, contact: CollisionContact) ?math.Vec2 {
    const a = data.movementBodyConst(contact.a) orelse return null;
    const b = data.movementBodyConst(contact.b) orelse return null;
    return .{
        .x = (a.position.x + b.position.x) * 0.5,
        .y = (a.position.y + b.position.y) * 0.5,
    };
}

fn collisionSfxFrequencyRatio(contact: CollisionContact) f32 {
    var hash = CollisionSfxCooldown.keyFor(contact.a, contact.b);
    hash ^= hashBitsFromFloat(@abs(contact.normal_x) * 31.0);
    hash ^= hashBitsFromFloat(@abs(contact.normal_y) * 47.0) << 8;
    hash ^= hashBitsFromFloat(std.math.clamp(contact.penetration, 0, 64) * 16.0) << 16;
    const bucket: f32 = @floatFromInt(hash % 9);
    return 0.92 + bucket * 0.02;
}

/// Truncates a non-negative magnitude to integer hash bits, guarding
/// `@intFromFloat` against non-finite contact normals (illegal behavior). The
/// `@min` ceiling is purely an `@intFromFloat` domain guard, not a hashing
/// concern: the bounded callers never approach it.
fn hashBitsFromFloat(value: f32) u64 {
    if (!std.math.isFinite(value) or value <= 0) return 0;
    return @intFromFloat(@min(value, 16_777_216.0));
}

const CollisionSfxCooldown = struct {
    key: u64,
    remaining_seconds: f32,

    fn keyFor(a: EntityId, b: EntityId) u64 {
        const a_id = entityAudioKey(a);
        const b_id = entityAudioKey(b);
        const low = @min(a_id, b_id);
        const high = @max(a_id, b_id);
        return low ^ std.math.rotl(u64, high, 32);
    }

    fn entityAudioKey(entity: EntityId) u64 {
        return (@as(u64, entity.generation) << 32) | entity.index;
    }
};

test "collision sfx cooldowns harden: cap<=32, full evicts min-remaining, tick compacts for re-add, keyFor pair order" {
    const mk = struct {
        fn id(index: u32, generation: u32) EntityId {
            return .{ .index = index, .generation = generation };
        }
    }.id;

    var controller = AudioController.init();

    // keyFor is symmetric in pair order.
    try std.testing.expectEqual(
        CollisionSfxCooldown.keyFor(mk(1, 10), mk(2, 20)),
        CollisionSfxCooldown.keyFor(mk(2, 20), mk(1, 10)),
    );

    controller.addCooldown(mk(1, 1), mk(2, 2));
    controller.tickCooldowns(0.01);

    var n: u32 = 0;
    while (controller.cooldown_count < cooldown_capacity) : (n += 1) {
        controller.addCooldown(mk(n, 10), mk(n + 1, 10));
    }
    try std.testing.expectEqual(@as(usize, 32), controller.cooldown_count);

    // Fill with known remaining times, then a new pair evicts the min-remaining slot.
    for (&controller.cooldowns, 0..) |*slot, j| {
        slot.* = .{
            .key = CollisionSfxCooldown.keyFor(mk(@as(u32, @intCast(j)), 99), mk(@as(u32, @intCast(j)) + 100, 99)),
            .remaining_seconds = 0.01 + @as(f32, @floatFromInt(j)) * 0.001,
        };
    }
    controller.cooldown_count = 32;
    const min_key = controller.cooldowns[0].key;
    const na = mk(500, 7);
    const nb = mk(600, 7);
    controller.addCooldown(na, nb);
    try std.testing.expectEqual(@as(usize, 32), controller.cooldown_count);
    const nk = CollisionSfxCooldown.keyFor(na, nb);
    var found_new = false;
    var found_min = false;
    for (controller.cooldowns[0..32]) |cd| {
        if (cd.key == nk) found_new = true;
        if (cd.key == min_key) found_min = true;
    }
    try std.testing.expect(found_new);
    try std.testing.expect(!found_min);

    // tick compacts an expired slot so a re-add fits.
    controller.cooldowns[0].remaining_seconds = 0.001;
    controller.cooldown_count = 2;
    controller.tickCooldowns(0.01);
    try std.testing.expectEqual(@as(usize, 1), controller.cooldown_count);
    controller.addCooldown(mk(1, 1), mk(2, 2));
    try std.testing.expectEqual(@as(usize, 2), controller.cooldown_count);
}

fn writeContacts(frame: *SimulationFrame, contacts: []const CollisionContact) !void {
    try frame.contacts.prepareRangeCounts(1);
    frame.contacts.addCount(0, contacts.len);
    try frame.contacts.prefix();
    var writer = frame.contacts.rangeWriter(0);
    for (contacts) |contact| writer.write(contact);
    writer.finish();
    frame.contacts.finishWrite();
}

fn contactFixture(a: EntityId, b: EntityId, penetration: f32) CollisionContact {
    return .{
        .a = a,
        .b = b,
        .a_movement_index = 0,
        .b_movement_index = 0,
        .normal_x = 1,
        .normal_y = 0,
        .penetration = penetration,
    };
}

test "queueCollision plays a sound for a contact involving the player" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const player_entity = try data.createEntity();
    const npc = try data.createEntity();
    try data.setMovementBody(player_entity, .{ .position = .{ .x = 0, .y = 0 } });
    try data.setMovementBody(npc, .{ .position = .{ .x = 10, .y = 0 } });

    var frame = SimulationFrame.init(allocator);
    defer frame.deinit();
    try writeContacts(&frame, &.{contactFixture(player_entity, npc, 6.0)});

    var commands = AudioCommandBuffer.init(allocator, 8);
    defer commands.deinit();
    var controller = AudioController.init();
    controller.queueCollision(&commands, &frame, &data, player_entity, 1.0 / 60.0);

    try std.testing.expectEqual(@as(usize, 1), commands.len());
    try std.testing.expectEqual(AudioAssetId.collision_sfx, commands.items()[0].play_sfx.asset);
    try std.testing.expectEqual(@as(usize, 1), controller.cooldown_count);
}

test "queueCollision plays no sound for a contact between two non-player entities" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const player_entity = try data.createEntity();
    const npc_a = try data.createEntity();
    const npc_b = try data.createEntity();
    try data.setMovementBody(player_entity, .{ .position = .{ .x = 0, .y = 0 } });
    try data.setMovementBody(npc_a, .{ .position = .{ .x = 10, .y = 0 } });
    try data.setMovementBody(npc_b, .{ .position = .{ .x = 11, .y = 0 } });

    var frame = SimulationFrame.init(allocator);
    defer frame.deinit();
    try writeContacts(&frame, &.{contactFixture(npc_a, npc_b, 6.0)});

    var commands = AudioCommandBuffer.init(allocator, 8);
    defer commands.deinit();
    var controller = AudioController.init();
    controller.queueCollision(&commands, &frame, &data, player_entity, 1.0 / 60.0);

    try std.testing.expectEqual(@as(usize, 0), commands.len());
    try std.testing.expectEqual(@as(usize, 0), controller.cooldown_count);
}

test "queueCollision skips non-player contacts and still plays player contacts in the same step" {
    const allocator = std.testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const player_entity = try data.createEntity();
    const player_partner = try data.createEntity();
    const npc_a = try data.createEntity();
    const npc_b = try data.createEntity();
    try data.setMovementBody(player_entity, .{ .position = .{ .x = 0, .y = 0 } });
    try data.setMovementBody(player_partner, .{ .position = .{ .x = 5, .y = 0 } });
    try data.setMovementBody(npc_a, .{ .position = .{ .x = 10, .y = 0 } });
    try data.setMovementBody(npc_b, .{ .position = .{ .x = 11, .y = 0 } });

    var frame = SimulationFrame.init(allocator);
    defer frame.deinit();
    try writeContacts(&frame, &.{
        contactFixture(npc_a, npc_b, 6.0),
        contactFixture(player_entity, player_partner, 4.0),
    });

    var commands = AudioCommandBuffer.init(allocator, 8);
    defer commands.deinit();
    var controller = AudioController.init();
    controller.queueCollision(&commands, &frame, &data, player_entity, 1.0 / 60.0);

    try std.testing.expectEqual(@as(usize, 1), commands.len());
    try std.testing.expect(!controller.pairOnCooldown(npc_a, npc_b));
    try std.testing.expect(controller.pairOnCooldown(player_entity, player_partner));
}
