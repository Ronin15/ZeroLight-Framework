// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Data-driven AI archetype catalog: personalities are authored in
//! `assets/ai/archetypes.json` and loaded once at load-time into a dense
//! enum-indexed table of prevalidated component bundles. Spawn resolves a slot
//! to a bundle by `@intFromEnum` — no strings, no hashmap, no JSON on the hot
//! path. Lives in the game layer because bundles hold game-layer component
//! types; it merely borrows `AssetStore`'s path-safe reader (direction stays
//! game -> assets).
//!
//! Parsing is strict (`ignore_unknown_fields = false`): a misspelled drive,
//! behavior, faction, or component key becomes `error.UnknownField` at parse
//! time. Each entry self-declares its `id`; array position is irrelevant.
//! Duplicate ids and any missing id are rejected. Absent numeric fields fall
//! back to the component struct defaults exactly, so a loaded bundle is
//! field-identical to the equivalent hand-written literal.
//!
//! Schema — `{ "archetypes": [ { entry }, ... ] }`, one entry per id:
//!   id: string (required)     -> AiArchetypeId
//!   faction: string (required)-> Faction
//!   agent: object (optional; absent => no AiAgent):
//!     active_behavior: string (required) -> AiBehavior
//!     gain_wander/gain_pursue/gain_flee/gain_investigate/gain_cohere: f32 (opt)
//!     wander_amplitude, sticky_bonus: f32 (opt); commitment_max_steps: u16 (opt)
//!   perception: object (optional): vision_range, hearing_range,
//!     fov_half_angle_radians: f32 (opt)
//!   memory: object (optional, presence-only) => default AiMemory
//!   affect: object (optional): baseline_/decay_rate_/threshold_ fear,
//!     curiosity, aggression, fatigue: f32 (opt)

const std = @import("std");
const AssetStore = @import("../assets/assets.zig").AssetStore;
const data_system = @import("data_system.zig");
const AiAgent = data_system.AiAgent;
const AiBehavior = data_system.AiBehavior;
const AiPerception = data_system.AiPerception;
const AiMemory = data_system.AiMemory;
const AiAffect = data_system.AiAffect;
const Faction = data_system.Faction;
const validateAiAgent = @import("data_system/agents.zig").validateAiAgent;
const validateAiPerception = @import("data_system/perception.zig").validateAiPerception;
const cosHalfFov = @import("data_system/perception.zig").cosHalfFov;
const validateAiMemory = @import("data_system/memory.zig").validateAiMemory;
const validateAiAffect = @import("data_system/affect.zig").validateAiAffect;

/// The eight demo personalities. Tag order maps 1:1 to the demo's fixed 8-slot
/// spawn cycle (slots 0..7).
pub const AiArchetypeId = enum(u16) {
    wanderer,
    pursuer,
    inert,
    timid,
    aggressive,
    curious,
    cohesive,
    pursuer_strong,
};

pub const archetype_count: usize = @typeInfo(AiArchetypeId).@"enum".fields.len;

const archetypes_path = "ai/archetypes.json";
const max_archetypes_bytes: usize = 64 * 1024;

/// Full component bundle for one archetype. `behavior == null` means no
/// `AiAgent` at all (a pure physics/collision body); `perception`/`memory`/
/// `affect` are independently optional so an entity can carry `AiAgent` without
/// full cognition (arbitration treats an absent component as zero signal).
pub const DemoArchetype = struct {
    behavior: ?AiAgent,
    perception: ?AiPerception = null,
    memory: ?AiMemory = null,
    affect: ?AiAffect = null,
    faction: Faction = .hostile,
};

/// Domain and validation errors from building the dense table out of parsed
/// JSON (the `InvalidAi*` members come from the reused component validators).
pub const BuildError = error{
    UnknownArchetypeId,
    UnknownFaction,
    UnknownBehavior,
    DuplicateArchetype,
    MissingArchetype,
    InvalidAiAgent,
    InvalidAiPerception,
    InvalidAiMemory,
    InvalidAiAffect,
};

/// Everything `load`/`buildFromSlice` can surface short of AssetStore file IO:
/// strict JSON parse errors (unknown/missing fields, bad values) plus the
/// build/validation errors above.
pub const LoadError = std.json.ParseError(std.json.Scanner) || BuildError;

/// Dense enum-indexed table of prevalidated bundles. Holds only value types —
/// the parsed JSON is freed once the table is built, so there is no `deinit`.
pub const AiArchetypeCatalog = struct {
    bundles: [archetype_count]DemoArchetype,

    pub fn bundleForId(self: *const AiArchetypeCatalog, id: AiArchetypeId) DemoArchetype {
        return self.bundles[@intFromEnum(id)];
    }
};

const AgentJson = struct {
    active_behavior: []const u8,
    gain_wander: ?f32 = null,
    gain_pursue: ?f32 = null,
    gain_flee: ?f32 = null,
    gain_investigate: ?f32 = null,
    gain_cohere: ?f32 = null,
    wander_amplitude: ?f32 = null,
    sticky_bonus: ?f32 = null,
    commitment_max_steps: ?u16 = null,
};

const PerceptionJson = struct {
    vision_range: ?f32 = null,
    hearing_range: ?f32 = null,
    fov_half_angle_radians: ?f32 = null,
};

const MemoryJson = struct {};

const AffectJson = struct {
    baseline_fear: ?f32 = null,
    baseline_curiosity: ?f32 = null,
    baseline_aggression: ?f32 = null,
    baseline_fatigue: ?f32 = null,
    decay_rate_fear: ?f32 = null,
    decay_rate_curiosity: ?f32 = null,
    decay_rate_aggression: ?f32 = null,
    decay_rate_fatigue: ?f32 = null,
    threshold_fear: ?f32 = null,
    threshold_curiosity: ?f32 = null,
    threshold_aggression: ?f32 = null,
    threshold_fatigue: ?f32 = null,
};

const ArchetypeJson = struct {
    id: []const u8,
    faction: []const u8,
    agent: ?AgentJson = null,
    perception: ?PerceptionJson = null,
    memory: ?MemoryJson = null,
    affect: ?AffectJson = null,
};

const JsonRoot = struct {
    archetypes: []ArchetypeJson,
};

/// Loads and validates the installed archetype catalog. Cold path — normal
/// allocator use is fine; the JSON bytes and parse tree are freed before
/// returning since the built bundles are plain value types.
pub fn load(asset_store: AssetStore, allocator: std.mem.Allocator) !AiArchetypeCatalog {
    const bytes = try asset_store.readAlloc(archetypes_path, max_archetypes_bytes, allocator);
    defer allocator.free(bytes);
    return buildFromSlice(allocator, bytes);
}

/// Parses `json_bytes` and builds the dense table. Strict parsing rejects any
/// unknown/misspelled key with `error.UnknownField`.
fn buildFromSlice(allocator: std.mem.Allocator, json_bytes: []const u8) LoadError!AiArchetypeCatalog {
    const parsed = try std.json.parseFromSlice(JsonRoot, allocator, json_bytes, .{});
    defer parsed.deinit();
    return buildCatalog(parsed.value);
}

fn buildCatalog(root: JsonRoot) BuildError!AiArchetypeCatalog {
    var seen = [_]bool{false} ** archetype_count;
    var bundles: [archetype_count]DemoArchetype = undefined;
    for (root.archetypes) |entry| {
        const id = std.meta.stringToEnum(AiArchetypeId, entry.id) orelse return error.UnknownArchetypeId;
        const slot = @intFromEnum(id);
        if (seen[slot]) return error.DuplicateArchetype;
        seen[slot] = true;
        bundles[slot] = try buildBundle(entry);
    }
    for (seen) |present| {
        if (!present) return error.MissingArchetype;
    }
    return .{ .bundles = bundles };
}

fn buildBundle(entry: ArchetypeJson) BuildError!DemoArchetype {
    const faction = std.meta.stringToEnum(Faction, entry.faction) orelse return error.UnknownFaction;
    var bundle = DemoArchetype{ .behavior = null, .faction = faction };

    if (entry.agent) |j| {
        var agent = AiAgent{};
        agent.active_behavior = std.meta.stringToEnum(AiBehavior, j.active_behavior) orelse return error.UnknownBehavior;
        if (j.gain_wander) |v| agent.gain_wander = v;
        if (j.gain_pursue) |v| agent.gain_pursue = v;
        if (j.gain_flee) |v| agent.gain_flee = v;
        if (j.gain_investigate) |v| agent.gain_investigate = v;
        if (j.gain_cohere) |v| agent.gain_cohere = v;
        if (j.wander_amplitude) |v| agent.wander_amplitude = v;
        if (j.sticky_bonus) |v| agent.sticky_bonus = v;
        if (j.commitment_max_steps) |v| agent.commitment_max_steps = v;
        try validateAiAgent(agent);
        bundle.behavior = agent;
    }

    if (entry.perception) |j| {
        var perception = AiPerception{};
        if (j.vision_range) |v| perception.vision_range = v;
        if (j.hearing_range) |v| perception.hearing_range = v;
        if (j.fov_half_angle_radians) |v| {
            perception.fov_half_angle_radians = v;
            perception.cos_half_fov = cosHalfFov(v);
        }
        try validateAiPerception(perception);
        bundle.perception = perception;
    }

    if (entry.memory) |_| {
        const mem = AiMemory{};
        try validateAiMemory(mem);
        bundle.memory = mem;
    }

    if (entry.affect) |j| {
        var affect = AiAffect{};
        if (j.baseline_fear) |v| affect.baseline_fear = v;
        if (j.baseline_curiosity) |v| affect.baseline_curiosity = v;
        if (j.baseline_aggression) |v| affect.baseline_aggression = v;
        if (j.baseline_fatigue) |v| affect.baseline_fatigue = v;
        if (j.decay_rate_fear) |v| affect.decay_rate_fear = v;
        if (j.decay_rate_curiosity) |v| affect.decay_rate_curiosity = v;
        if (j.decay_rate_aggression) |v| affect.decay_rate_aggression = v;
        if (j.decay_rate_fatigue) |v| affect.decay_rate_fatigue = v;
        if (j.threshold_fear) |v| affect.threshold_fear = v;
        if (j.threshold_curiosity) |v| affect.threshold_curiosity = v;
        if (j.threshold_aggression) |v| affect.threshold_aggression = v;
        if (j.threshold_fatigue) |v| affect.threshold_fatigue = v;
        try validateAiAffect(affect);
        bundle.affect = affect;
    }

    return bundle;
}

// --- Tests ---

/// The expected bundle table, mirroring the demo's hardcoded personality
/// literals (slots 0..7). The loaded catalog must equal this field-for-field.
fn expectedBundles() [archetype_count]DemoArchetype {
    return .{
        .{ .behavior = .{ .active_behavior = .wander, .wander_amplitude = 58, .gain_pursue = 0 } },
        .{ .behavior = .{ .active_behavior = .pursue, .wander_amplitude = 4, .gain_pursue = 1.2 } },
        .{ .behavior = null },
        .{
            .behavior = .{ .active_behavior = .wander, .wander_amplitude = 20, .gain_flee = 2.0, .gain_pursue = 0 },
            .perception = .{},
            .memory = .{},
            .affect = .{ .baseline_fear = 0.65 },
            .faction = .ally,
        },
        .{
            .behavior = .{ .active_behavior = .pursue, .wander_amplitude = 6, .gain_pursue = 2.0 },
            .perception = .{},
            .memory = .{},
            .affect = .{ .baseline_aggression = 0.65 },
        },
        .{
            .behavior = .{ .active_behavior = .wander, .wander_amplitude = 15, .gain_investigate = 2.0 },
            .perception = .{},
            .memory = .{},
            .affect = .{ .baseline_curiosity = 0.65 },
        },
        .{ .behavior = .{ .active_behavior = .wander, .wander_amplitude = 10, .gain_cohere = 2.0 } },
        .{ .behavior = .{ .active_behavior = .pursue, .wander_amplitude = 7, .gain_pursue = 1.55 } },
    };
}

test "installed archetypes.json loads to the full parity table" {
    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const catalog = try load(asset_store, std.testing.allocator);

    const expected = expectedBundles();
    inline for (std.meta.tags(AiArchetypeId)) |id| {
        try std.testing.expectEqual(expected[@intFromEnum(id)], catalog.bundleForId(id));
    }
}

test "every AiArchetypeId tag round-trips name<->enum and the catalog fills all slots" {
    inline for (std.meta.tags(AiArchetypeId)) |id| {
        const name = @tagName(id);
        try std.testing.expectEqual(id, std.meta.stringToEnum(AiArchetypeId, name).?);
    }

    const asset_store = AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    const catalog = try load(asset_store, std.testing.allocator);
    // Missing/duplicate rejection means a successful load populates all 8 slots;
    // inert (slot 2) is the only one with a null behavior.
    for (catalog.bundles, 0..) |bundle, slot| {
        if (slot == @intFromEnum(AiArchetypeId.inert)) {
            try std.testing.expect(bundle.behavior == null);
        } else {
            try std.testing.expect(bundle.behavior != null);
        }
    }
}

test "missing required field fails loud" {
    // No `faction` key on an entry -> strict parse rejects the missing field.
    const json =
        \\{"archetypes":[{"id":"wanderer","agent":{"active_behavior":"wander"}}]}
    ;
    try std.testing.expectError(error.MissingField, buildFromSlice(std.testing.allocator, json));

    // No `active_behavior` on a present agent block.
    const json_agent =
        \\{"archetypes":[{"id":"wanderer","faction":"hostile","agent":{"wander_amplitude":10}}]}
    ;
    try std.testing.expectError(error.MissingField, buildFromSlice(std.testing.allocator, json_agent));
}

test "unknown keys and unknown enum values fail loud" {
    // Misspelled affect drive key -> strict parse rejects the unknown field.
    const bad_key =
        \\{"archetypes":[{"id":"timid","faction":"ally","affect":{"baseline_feer":0.5}}]}
    ;
    try std.testing.expectError(error.UnknownField, buildFromSlice(std.testing.allocator, bad_key));

    const bad_id =
        \\{"archetypes":[{"id":"ghost","faction":"hostile"}]}
    ;
    try std.testing.expectError(error.UnknownArchetypeId, buildFromSlice(std.testing.allocator, bad_id));

    const bad_faction =
        \\{"archetypes":[{"id":"wanderer","faction":"enemy"}]}
    ;
    try std.testing.expectError(error.UnknownFaction, buildFromSlice(std.testing.allocator, bad_faction));

    const bad_behavior =
        \\{"archetypes":[{"id":"wanderer","faction":"hostile","agent":{"active_behavior":"sprint"}}]}
    ;
    try std.testing.expectError(error.UnknownBehavior, buildFromSlice(std.testing.allocator, bad_behavior));
}

test "out-of-range component values reuse the existing validators" {
    const bad_gain =
        \\{"archetypes":[{"id":"wanderer","faction":"hostile","agent":{"active_behavior":"wander","gain_pursue":999.0}}]}
    ;
    try std.testing.expectError(error.InvalidAiAgent, buildFromSlice(std.testing.allocator, bad_gain));

    const bad_vision =
        \\{"archetypes":[{"id":"timid","faction":"ally","perception":{"vision_range":99999.0}}]}
    ;
    try std.testing.expectError(error.InvalidAiPerception, buildFromSlice(std.testing.allocator, bad_vision));

    const bad_baseline =
        \\{"archetypes":[{"id":"aggressive","faction":"hostile","affect":{"baseline_aggression":5.0}}]}
    ;
    try std.testing.expectError(error.InvalidAiAffect, buildFromSlice(std.testing.allocator, bad_baseline));
}

test "custom fov_half_angle_radians recomputes cos_half_fov" {
    // setAiPerception stores AiPerception verbatim without re-deriving
    // cos_half_fov, so the loader is the only thing keeping the two consistent
    // for a non-default FOV. No shipped archetype exercises this branch.
    const json =
        \\{"archetypes":[{"id":"timid","faction":"ally","perception":{"fov_half_angle_radians":0.6}}]}
    ;
    const parsed = try std.json.parseFromSlice(JsonRoot, std.testing.allocator, json, .{});
    defer parsed.deinit();

    const bundle = try buildBundle(parsed.value.archetypes[0]);
    const perception = bundle.perception.?;
    try std.testing.expectEqual(@as(f32, 0.6), perception.fov_half_angle_radians);
    try std.testing.expectEqual(cosHalfFov(0.6), perception.cos_half_fov);
}

test "duplicate and missing archetype ids are rejected" {
    const dup =
        \\{"archetypes":[{"id":"wanderer","faction":"hostile"},{"id":"wanderer","faction":"hostile"}]}
    ;
    try std.testing.expectError(error.DuplicateArchetype, buildFromSlice(std.testing.allocator, dup));

    // A single valid entry parses and builds, then the completeness check fires.
    const missing =
        \\{"archetypes":[{"id":"wanderer","faction":"hostile","agent":{"active_behavior":"wander"}}]}
    ;
    try std.testing.expectError(error.MissingArchetype, buildFromSlice(std.testing.allocator, missing));
}
