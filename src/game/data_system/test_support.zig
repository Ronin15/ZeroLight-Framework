// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Per-entity component reads for tests, through `DataSystem`'s slot resolve and its
//! stores' row reads. Test-only: no production path imports it.

const types = @import("types.zig");
const DataSystem = @import("system.zig").DataSystem;
const EntityId = types.EntityId;
const AiAgent = types.AiAgent;
const AiAffect = types.AiAffect;
const AiMemory = types.AiMemory;
const AiPerception = types.AiPerception;
const AssetReference = types.AssetReference;
const EntitySimulationMetadata = @import("../simulation_scope.zig").EntitySimulationMetadata;

// The dense row of `id` in the store whose slot index field is `field`, or null when the
// entity is dead or lacks the component.
fn rowOf(data: *const DataSystem, id: EntityId, comptime field: []const u8) ?usize {
    const slot = data.resolveSlotConst(id) orelse return null;
    const row = @field(slot.*, field) orelse return null;
    return row;
}

pub fn simulationMetadata(data: *const DataSystem, id: EntityId) ?EntitySimulationMetadata {
    return data.movement_bodies.scopeMetadataAt(rowOf(data, id, "movement_body_index") orelse return null);
}

pub fn assetReference(data: *const DataSystem, id: EntityId) ?AssetReference {
    return data.asset_refs.get(rowOf(data, id, "asset_ref_index") orelse return null);
}

pub fn aiAgent(data: *const DataSystem, id: EntityId) ?AiAgent {
    return data.ai_agents.get(rowOf(data, id, "ai_agent_index") orelse return null);
}

pub fn aiPerception(data: *const DataSystem, id: EntityId) ?AiPerception {
    return data.ai_perceptions.get(rowOf(data, id, "ai_perception_index") orelse return null);
}

pub fn aiMemory(data: *const DataSystem, id: EntityId) ?AiMemory {
    return data.ai_memories.get(rowOf(data, id, "ai_memory_index") orelse return null);
}

pub fn aiAffect(data: *const DataSystem, id: EntityId) ?AiAffect {
    return data.ai_affects.get(rowOf(data, id, "ai_affect_index") orelse return null);
}
