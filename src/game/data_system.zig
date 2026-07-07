// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned persistent gameplay data.
//! Hot system data is stored as scalar SoA columns so processors can load lanes
//! directly with core/simd.zig and split contiguous ranges through ThreadSystem.
//!
//! This file is a thin facade over the `data_system/` package: it re-exports the
//! public surface so external importers keep resolving unchanged, while the
//! implementation lives in the package modules (mirrors `systems/pathfinding.zig`
//! over `systems/pathfinding/`).

pub const Faction = @import("data_system/types.zig").Faction;
pub const hot_soa_column_alignment = @import("data_system/types.zig").hot_soa_column_alignment;
pub const movement_range_alignment_items = @import("data_system/types.zig").movement_range_alignment_items;
pub const HotF32Slice = @import("data_system/types.zig").HotF32Slice;
pub const ConstHotF32Slice = @import("data_system/types.zig").ConstHotF32Slice;
pub const HotI32Slice = @import("data_system/types.zig").HotI32Slice;
pub const ConstHotI32Slice = @import("data_system/types.zig").ConstHotI32Slice;
pub const EntityId = @import("data_system/types.zig").EntityId;
pub const Component = @import("data_system/types.zig").Component;
pub const ComponentMask = @import("data_system/types.zig").ComponentMask;
pub const component_masks = @import("data_system/types.zig").component_masks;
pub const componentMask = @import("data_system/types.zig").componentMask;
pub const Facing = @import("data_system/types.zig").Facing;
pub const MovementBody = @import("data_system/types.zig").MovementBody;
pub const MovementBodyPtr = @import("data_system/types.zig").MovementBodyPtr;
pub const MovementBodySlice = @import("data_system/types.zig").MovementBodySlice;
pub const ConstMovementBodySlice = @import("data_system/types.zig").ConstMovementBodySlice;
pub const ScopeColumnsSlice = @import("data_system/types.zig").ScopeColumnsSlice;
pub const ConstScopeColumnsSlice = @import("data_system/types.zig").ConstScopeColumnsSlice;
pub const FacingData = @import("data_system/types.zig").FacingData;
pub const FacingSlice = @import("data_system/types.zig").FacingSlice;
pub const ConstFacingSlice = @import("data_system/types.zig").ConstFacingSlice;
pub const ConstFactionSlice = @import("data_system/types.zig").ConstFactionSlice;
pub const PrimitiveVisual = @import("data_system/types.zig").PrimitiveVisual;
pub const ConstPrimitiveVisualSlice = @import("data_system/types.zig").ConstPrimitiveVisualSlice;
pub const AssetReference = @import("data_system/types.zig").AssetReference;
pub const ConstAssetReferenceSlice = @import("data_system/types.zig").ConstAssetReferenceSlice;
pub const RenderEntityComponentIndices = @import("data_system/types.zig").RenderEntityComponentIndices;
pub const RenderCollectIndices = @import("data_system/types.zig").RenderCollectIndices;
pub const CollisionBounds = @import("data_system/types.zig").CollisionBounds;
pub const CollisionBoundsCommand = @import("data_system/types.zig").CollisionBoundsCommand;
pub const ConstCollisionBoundsSlice = @import("data_system/types.zig").ConstCollisionBoundsSlice;
pub const CollisionResponseMode = @import("data_system/types.zig").CollisionResponseMode;
pub const CollisionResponseMobility = @import("data_system/types.zig").CollisionResponseMobility;
pub const CollisionResponse = @import("data_system/types.zig").CollisionResponse;
pub const CollisionResponseCommand = @import("data_system/types.zig").CollisionResponseCommand;
pub const ConstCollisionResponseSlice = @import("data_system/types.zig").ConstCollisionResponseSlice;
pub const AiBehavior = @import("data_system/types.zig").AiBehavior;
pub const AiAgent = @import("data_system/types.zig").AiAgent;
pub const max_ai_wander_amplitude = @import("data_system/types.zig").max_ai_wander_amplitude;
pub const max_ai_seek_weight = @import("data_system/types.zig").max_ai_seek_weight;
pub const AiAgentCommand = @import("data_system/types.zig").AiAgentCommand;
pub const ConstAiAgentSlice = @import("data_system/types.zig").ConstAiAgentSlice;
pub const SteeringAgent = @import("data_system/types.zig").SteeringAgent;
pub const max_steering_radius = @import("data_system/types.zig").max_steering_radius;
pub const max_steering_weight = @import("data_system/types.zig").max_steering_weight;
pub const max_steering_neighbor_samples = @import("data_system/types.zig").max_steering_neighbor_samples;
pub const max_steering_cooldown_steps = @import("data_system/types.zig").max_steering_cooldown_steps;
pub const SteeringAgentCommand = @import("data_system/types.zig").SteeringAgentCommand;
pub const ConstSteeringAgentSlice = @import("data_system/types.zig").ConstSteeringAgentSlice;
pub const WorldLevelCommand = @import("data_system/types.zig").WorldLevelCommand;
pub const ConstWorldLevelSlice = @import("data_system/types.zig").ConstWorldLevelSlice;
pub const EntityTemplate = @import("data_system/types.zig").EntityTemplate;
pub const MovementBodyCommand = @import("data_system/types.zig").MovementBodyCommand;
pub const FacingCommand = @import("data_system/types.zig").FacingCommand;
pub const PrimitiveVisualCommand = @import("data_system/types.zig").PrimitiveVisualCommand;
pub const AssetReferenceCommand = @import("data_system/types.zig").AssetReferenceCommand;
pub const SimulationTierCommand = @import("data_system/types.zig").SimulationTierCommand;
pub const FactionCommand = @import("data_system/types.zig").FactionCommand;
pub const StructuralCommand = @import("data_system/types.zig").StructuralCommand;
pub const StructuralCommitStats = @import("data_system/types.zig").StructuralCommitStats;
pub const ObstacleWorldRect = @import("data_system/types.zig").ObstacleWorldRect;
pub const StructuralEntityDestroyedChange = @import("data_system/types.zig").StructuralEntityDestroyedChange;
pub const StructuralComponentChangedChange = @import("data_system/types.zig").StructuralComponentChangedChange;
pub const StructuralChange = @import("data_system/types.zig").StructuralChange;
pub const StructuralPlanScratch = @import("data_system/structural.zig").StructuralPlanScratch;
pub const DataSystem = @import("data_system/system.zig").DataSystem;

test {
    _ = @import("data_system/types.zig");
    _ = @import("data_system/movement.zig");
    _ = @import("data_system/visual.zig");
    _ = @import("data_system/collision.zig");
    _ = @import("data_system/agents.zig");
    _ = @import("data_system/faction_level.zig");
    _ = @import("data_system/structural.zig");
    _ = @import("data_system/system.zig");
}
