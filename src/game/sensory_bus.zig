// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pipeline-owned sensory bus.
//! Holds deferred impacts, sticky dig/impact linger, and the hearing scratch
//! the perception stage reads. Fixed arrays, no heap. The pipeline calls
//! promote and footstep from `dig_world_edit`, the hearing slice and sticky
//! advance from `perception_update`, and impact enqueue from `collision_respond`.

const std = @import("std");
const contact_query = @import("contact_query.zig");
const DataSystem = @import("data_system.zig").DataSystem;
const EntityId = @import("data_system.zig").EntityId;
const Player = @import("player.zig").Player;
const SimulationFrame = @import("simulation.zig").SimulationFrame;
const CollisionContact = @import("simulation.zig").CollisionContact;
const WorldStimulus = @import("simulation.zig").WorldStimulus;
const defaultStimulusIntensity = @import("simulation.zig").defaultStimulusIntensity;
const stimulus_deferred_capacity = @import("simulation.zig").stimulus_deferred_capacity;
const stimulus_live_capacity = @import("simulation.zig").stimulus_live_capacity;
const stimulus_max_impacts_per_step = @import("simulation.zig").stimulus_max_impacts_per_step;
const stimulus_sticky_capacity = @import("simulation.zig").stimulus_sticky_capacity;
const cognition_stagger_n = @import("simulation_scope.zig").cognition_stagger_n;

const hearing_stimuli_scratch_capacity: usize = stimulus_live_capacity + stimulus_sticky_capacity;

pub const StimulusConfig = struct {
    footstep_min_speed_sq: f32 = 1.0,
    impact_min_approach_speed_sq: f32 = 1.0,
    impact_min_penetration: f32 = 1.0,
};

comptime {
    // sticky_remaining stores the per-entry linger count in a u8.
    std.debug.assert(cognition_stagger_n - 1 <= std.math.maxInt(u8));
    // One dig plus the per-step impact cap, held for every stagger cohort but
    // the one that heard the live bus. A deferred-buffer backlog can still drop;
    // that drop is counted, not a reason to grow this with world size.
    std.debug.assert(stimulus_sticky_capacity == (stimulus_max_impacts_per_step + 1) * (@as(usize, cognition_stagger_n) - 1));
}

pub const SensoryBus = struct {
    config: StimulusConfig = .{},
    /// Deferred impacts survive `beginStep` until promoted before perception.
    deferred_stimuli: [stimulus_deferred_capacity]WorldStimulus = undefined,
    deferred_stimulus_count: usize = 0,
    /// One-shot dig/impact linger for cognition stagger. Not cleared on `beginStep`.
    sticky_stimuli: [stimulus_sticky_capacity]WorldStimulus = undefined,
    sticky_remaining: [stimulus_sticky_capacity]u8 = undefined,
    sticky_count: usize = 0,
    hearing_stimuli_scratch: [hearing_stimuli_scratch_capacity]WorldStimulus = undefined,

    pub fn init(config: StimulusConfig) SensoryBus {
        return .{ .config = config };
    }

    /// Moves deferred impacts onto the live bus. Returns how many were promoted.
    pub fn promote(self: *SensoryBus, frame: *SimulationFrame, live_dropped: *usize) usize {
        const pending = self.deferred_stimulus_count;
        var promoted: usize = 0;
        var retained: usize = 0;
        for (self.deferred_stimuli[0..pending]) |stimulus| {
            if (frame.tryAppendStimulus(stimulus, stimulus_live_capacity)) {
                promoted += 1;
            } else {
                self.deferred_stimuli[retained] = stimulus;
                retained += 1;
                live_dropped.* += 1;
            }
        }
        self.deferred_stimulus_count = retained;
        return promoted;
    }

    /// At most one footstep when the player's movement body carries non-trivial velocity.
    pub fn appendFootstep(
        self: *const SensoryBus,
        frame: *SimulationFrame,
        data: *const DataSystem,
        player: Player,
        live_dropped: *usize,
    ) void {
        const body = data.movementBodyConst(player.entity) orelse return;
        const vel_sq = body.velocity.x * body.velocity.x + body.velocity.y * body.velocity.y;
        if (vel_sq < self.config.footstep_min_speed_sq) return;
        const appended = frame.tryAppendStimulus(.{
            .position = body.position,
            .intensity = defaultStimulusIntensity(.footstep),
            .kind = .footstep,
            .level = player.current_level,
        }, stimulus_live_capacity);
        if (!appended) live_dropped.* += 1;
    }

    /// Live bus plus still-lingering sticky stimuli, in that order.
    pub fn hearingSlice(self: *SensoryBus, frame: *const SimulationFrame) []const WorldStimulus {
        const live = frame.stimuli.mergedItems();
        var len: usize = 0;
        for (live) |stimulus| {
            std.debug.assert(len < hearing_stimuli_scratch_capacity);
            self.hearing_stimuli_scratch[len] = stimulus;
            len += 1;
        }
        for (0..self.sticky_count) |i| {
            if (self.sticky_remaining[i] == 0) continue;
            std.debug.assert(len < hearing_stimuli_scratch_capacity);
            self.hearing_stimuli_scratch[len] = self.sticky_stimuli[i];
            len += 1;
        }
        return self.hearing_stimuli_scratch[0..len];
    }

    /// Ages one-shot sticky stimuli one stagger step, then captures this step's
    /// dig/impact stimuli. Age-before-capture cannot be reordered by a caller.
    /// Captures past the fixed sticky capacity are counted and dropped.
    pub fn advanceSticky(self: *SensoryBus, frame: *const SimulationFrame, sticky_dropped: *usize) void {
        var write: usize = 0;
        for (0..self.sticky_count) |i| {
            const remaining = self.sticky_remaining[i];
            if (remaining <= 1) continue;
            self.sticky_stimuli[write] = self.sticky_stimuli[i];
            self.sticky_remaining[write] = remaining - 1;
            write += 1;
        }
        self.sticky_count = write;

        const linger: u8 = cognition_stagger_n - 1;
        if (linger == 0) return;
        for (frame.stimuli.mergedItems()) |stimulus| {
            switch (stimulus.kind) {
                .dig, .impact => {},
                .footstep => continue,
            }
            if (self.sticky_count >= stimulus_sticky_capacity) {
                sticky_dropped.* += 1;
                continue;
            }
            self.sticky_stimuli[self.sticky_count] = stimulus;
            self.sticky_remaining[self.sticky_count] = linger;
            self.sticky_count += 1;
        }
    }

    /// Enqueues player-involving collision contacts as next-step impact stimuli.
    pub fn enqueuePlayerImpacts(
        self: *SensoryBus,
        frame: *const SimulationFrame,
        data: *const DataSystem,
        player_entity: EntityId,
        player_level: u16,
        deferred_dropped: *usize,
    ) void {
        var enqueued: usize = 0;
        for (frame.contacts.mergedItems()) |contact| {
            if (!contact_query.involvesEntity(contact, player_entity)) continue;
            if (!self.contactEligibleForImpact(contact)) continue;
            if (enqueued >= stimulus_max_impacts_per_step) {
                deferred_dropped.* += 1;
                continue;
            }
            const position = contact_query.midpoint(data, contact) orelse continue;
            if (self.deferred_stimulus_count >= stimulus_deferred_capacity) {
                deferred_dropped.* += 1;
                continue;
            }
            self.deferred_stimuli[self.deferred_stimulus_count] = .{
                .position = position,
                .intensity = defaultStimulusIntensity(.impact) * contact_query.penetrationScale(contact.penetration),
                .kind = .impact,
                .level = player_level,
            };
            self.deferred_stimulus_count += 1;
            enqueued += 1;
        }
    }

    /// Velocity comes from the contact's pre-response snapshot. Reading live
    /// movement columns here would see the approach axis already zeroed.
    fn contactEligibleForImpact(self: *const SensoryBus, contact: CollisionContact) bool {
        if (contact.pre_response_max_speed_sq >= self.config.impact_min_approach_speed_sq) return true;
        if (contact.penetration < self.config.impact_min_penetration) return false;
        return contact.pre_response_relative_speed_sq >= self.config.impact_min_approach_speed_sq;
    }
};
