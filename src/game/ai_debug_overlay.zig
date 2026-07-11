// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Render-only AI introspection overlay: draws each cognition-tier agent's
//! vision cone, drive bars, memory markers, and active-behavior label, plus a
//! scope/tier HUD block. Gathering reads simulation state exclusively through
//! `*const DataSystem` const views, so it can never mutate serial checksums,
//! RNG, or intent streams — the overlay's presence is invisible to the sim.
//!
//! Fixed budgets (never scaled to world/agent/cell count): at most
//! `kMaxAnnotatedAgents` agents are annotated (overflow past the cap is simply
//! not drawn), and every vision ring uses `ring_segments` segments. The gather
//! is a pure function of `*const DataSystem` + camera rect into a caller-owned
//! fixed buffer, so it is unit-testable headlessly and allocation-free.

const std = @import("std");
const config = @import("../config.zig");
const Color = config.Color;
const math = @import("../core/math.zig");
const Vec2 = math.Vec2;
const data_system = @import("data_system.zig");
const DataSystem = data_system.DataSystem;
const EntityId = data_system.EntityId;
const AiBehavior = data_system.AiBehavior;
const AiAffectDrive = data_system.AiAffectDrive;
const ai_memory_ring_capacity = data_system.ai_memory_ring_capacity;
const max_ai_memory_staleness = data_system.max_ai_memory_staleness;
const renderer_mod = @import("../render/renderer.zig");
const Renderer = renderer_mod.Renderer;
const Rect = renderer_mod.Rect;
const RenderOrder = renderer_mod.RenderOrder;
const text = @import("../render/text.zig");
const TextService = text.TextService;
const PreparedText = text.PreparedText;
const fpsOverlayFontSize = @import("../render/fps_counter.zig").overlayFontSize;
// Test-only: constructs a headless CPU-only `Renderer` fixture (GPU handles
// undefined, never dereferenced by the submission-only draw path). Mirrors
// render_prep.zig's same-reason direct sprite_batch import.
const sprite_batch = @import("../render/sprite_batch.zig");

/// Maximum agents annotated in a single frame. A fixed constant, deliberately
/// independent of agent/world/cell count: overflow past the cap is not drawn,
/// so overlay cost stays bounded regardless of how many agents exist.
pub const kMaxAnnotatedAgents: usize = 16;

/// Segments approximating each vision ring arc. Fixed regardless of world size.
const ring_segments: usize = 24;

const drive_count = @typeInfo(AiAffectDrive).@"enum".fields.len;
const behavior_count = @typeInfo(AiBehavior).@"enum".fields.len;

// All overlay draws share the debug/overlay order so they sort above world and
// UI; equal orders are legal in the ordered stream (stream order layers them).
const overlay_order = RenderOrder.debug(.overlay);

// Cosmetic constants (world pixels / linear RGBA). Cones are translucent so the
// agent stays visible; above-threshold drive bars use the brighter fill.
const spoke_thickness: f32 = 2;
const ring_thickness: f32 = 2;
const cone_alpha: f32 = 0.28;
const ring_alpha: f32 = 0.5;

// Distinct, well-separated hue per `AiBehavior` (indexed by `@intFromEnum`), so
// an agent's active behavior reads from its cone/ring tint and colored label
// alone. Order matches the enum: wander, pursue, flee, investigate, cohere.
const behavior_colors = [behavior_count]Color{
    .{ .r = 0.85, .g = 0.85, .b = 0.85, .a = 1 }, // wander: light gray
    .{ .r = 0.95, .g = 0.25, .b = 0.2, .a = 1 }, // pursue: red
    .{ .r = 0.2, .g = 0.85, .b = 0.95, .a = 1 }, // flee: cyan
    .{ .r = 1, .g = 0.85, .b = 0.15, .a = 1 }, // investigate: yellow
    .{ .r = 0.3, .g = 0.85, .b = 0.35, .a = 1 }, // cohere: green
};

const bar_max_width: f32 = 24;
const bar_height: f32 = 3;
const bar_gap: f32 = 1;
const bar_stack_offset: f32 = 22;
const bar_track_color = Color{ .r = 0.1, .g = 0.1, .b = 0.1, .a = 0.55 };
const bar_fill_color = Color{ .r = 0.35, .g = 0.55, .b = 0.9, .a = 0.7 };
const bar_hot_color = Color{ .r = 1, .g = 0.4, .b = 0.25, .a = 0.9 };
const marker_size: f32 = 4;
const marker_color = Color{ .r = 0.2, .g = 0.9, .b = 0.9, .a = 1 };

/// One remembered contact selected for the overlay: where it was and how stale.
pub const ContactMarker = struct {
    position: Vec2 = .{},
    age: f32 = 0,
};

/// Per-agent viz data, produced by `gatherAnnotations` and consumed by `draw`.
/// The optional sub-components are gated by `has_*`; a missing component just
/// skips that agent's corresponding sub-viz.
pub const AgentAnnotation = struct {
    position: Vec2 = .{},
    behavior: AiBehavior = .wander,
    has_perception: bool = false,
    facing: Vec2 = .{ .x = 1, .y = 0 },
    vision_range: f32 = 0,
    fov_half_angle: f32 = 0,
    has_affect: bool = false,
    drives: [drive_count]f32 = [_]f32{0} ** drive_count,
    above_threshold_mask: u8 = 0,
    memory_contact_count: usize = 0,
    contacts: [ai_memory_ring_capacity]ContactMarker = [_]ContactMarker{.{}} ** ai_memory_ring_capacity,
};

fn rectContains(rect: Rect, p: Vec2) bool {
    return p.x >= rect.x and p.x <= rect.x + rect.w and p.y >= rect.y and p.y <= rect.y + rect.h;
}

/// Sprite rotation angles (radians) for the two vision-cone edge spokes:
/// `facing_angle ± fov_half_angle`. Pure geometry, no GPU — the draw path feeds
/// these straight into `Sprite.rotation`.
pub fn coneSpokeAngles(facing: Vec2, fov_half_angle: f32) [2]f32 {
    const facing_angle = math.atan2(facing.y, facing.x);
    return .{ facing_angle - fov_half_angle, facing_angle + fov_half_angle };
}

/// Selects up to `out.len` (`kMaxAnnotatedAgents`) cognition-tier agents inside
/// `camera_rect`, first-N in stable AI-agent store order, and fills `out` with
/// their viz data. Returns the count written. Reads only `*const DataSystem`
/// const views: it cannot perturb sim state, RNG, or intents. Allocation-free —
/// `out` is a caller-owned fixed buffer.
pub fn gatherAnnotations(data: *const DataSystem, camera_rect: Rect, out: []AgentAnnotation) usize {
    const agents = data.aiAgentSliceConst();
    const bodies = data.movementBodySliceConst();
    const scope = data.scopeColumnsSliceConst();
    const perception = data.aiPerceptionSliceConst();
    const affect = data.aiAffectSliceConst();
    const memory = data.aiMemorySliceConst();

    var count: usize = 0;
    for (agents.entities, agents.behaviors) |entity, behavior| {
        if (count >= out.len) break;
        const mdi = data.movementBodyDenseIndex(entity) orelse continue;
        if (scope.tier[mdi] != .cognition) continue;
        const pos = Vec2{ .x = bodies.position_x[mdi], .y = bodies.position_y[mdi] };
        if (!rectContains(camera_rect, pos)) continue;

        var ann = AgentAnnotation{ .position = pos, .behavior = behavior };

        if (data.aiPerceptionDenseIndex(entity)) |pi| {
            ann.has_perception = true;
            ann.facing = .{ .x = perception.facing_x[pi], .y = perception.facing_y[pi] };
            ann.vision_range = perception.vision_range[pi];
            ann.fov_half_angle = perception.fov_half_angle_radians[pi];
        }

        if (data.aiAffectDenseIndex(entity)) |ai| {
            ann.has_affect = true;
            ann.drives[@intFromEnum(AiAffectDrive.fear)] = affect.fear[ai];
            ann.drives[@intFromEnum(AiAffectDrive.curiosity)] = affect.curiosity[ai];
            ann.drives[@intFromEnum(AiAffectDrive.aggression)] = affect.aggression[ai];
            ann.drives[@intFromEnum(AiAffectDrive.fatigue)] = affect.fatigue[ai];
            ann.above_threshold_mask = affect.above_threshold_mask[ai];
        }

        if (data.aiMemoryDenseIndex(entity)) |mi| {
            var n: usize = 0;
            for (0..ai_memory_ring_capacity) |slot| {
                if (!memory.ring_entity[mi][slot].isValid()) continue;
                ann.contacts[n] = .{
                    .position = .{ .x = memory.ring_x[mi][slot], .y = memory.ring_y[mi][slot] },
                    .age = memory.ring_age[mi][slot],
                };
                n += 1;
            }
            ann.memory_contact_count = n;
        }

        out[count] = ann;
        count += 1;
    }
    return count;
}

// Per-agent worst-case submitted sprite commands: 2 cone spokes + the ring +
// (track + fill) per drive + one marker per memory ring slot + 1 label.
const per_agent_commands = 2 + ring_segments + 2 * drive_count + ai_memory_ring_capacity + 1;
// HUD: two fixed blocks, one label + up to `max_hud_digits` composed digits per
// line. The tier block is `hud_lines` lines; the global per-behavior tally is
// `behavior_count` lines. Fixed constants — neither scales with agent count.
const hud_lines = 5;
const max_hud_digits = 10;
const hud_commands = (hud_lines + behavior_count) * (1 + max_hud_digits);

/// Game-owned AI viz. Caches one behavior label plus a HUD glyph set (labels +
/// digits) as `TextService`-owned handles (like `FpsCounter`), so no per-frame
/// string→texture work happens. `draw` is render-only and allocation-free after
/// the caches warm.
pub const AiDebugOverlay = struct {
    behavior_labels: [behavior_count]PreparedText = [_]PreparedText{PreparedText.invalid} ** behavior_count,
    tier_labels: [hud_lines]PreparedText = [_]PreparedText{PreparedText.invalid} ** hud_lines,
    digits: [10]PreparedText = [_]PreparedText{PreparedText.invalid} ** 10,
    labels_ready: bool = false,

    const hud_color = Color{ .r = 1, .g = 0.902, .b = 0.157, .a = 1 };
    const tier_names = [hud_lines][]const u8{ "total ", "cognition ", "locomotion ", "kinematic ", "dormant " };

    pub fn init() AiDebugOverlay {
        return .{};
    }

    /// Fixed upper bound on sprite commands the overlay submits in one frame.
    /// Callers reserve this once up front so the first F2 toggle draws
    /// allocation-free.
    pub fn commandCapacity() usize {
        return kMaxAnnotatedAgents * per_agent_commands + hud_commands;
    }

    /// Prepared labels are `TextService`-owned cache handles freed when the
    /// service deinits (mirrors `FpsCounter`); nothing to release here.
    pub fn deinit(self: *AiDebugOverlay) void {
        _ = self;
    }

    /// Gathers annotations and submits all AI viz. Render-only: reads sim state
    /// through const views only. Command headroom must already be reserved (see
    /// `commandCapacity`).
    pub fn draw(
        self: *AiDebugOverlay,
        data: *const DataSystem,
        camera_rect: Rect,
        renderer: *Renderer,
        text_service: *TextService,
    ) !void {
        try self.ensureLabels(text_service, renderer);

        var scratch: [kMaxAnnotatedAgents]AgentAnnotation = undefined;
        const n = gatherAnnotations(data, camera_rect, &scratch);
        for (scratch[0..n]) |ann| {
            try drawAgent(renderer, ann, self.behavior_labels);
        }
        try self.drawHud(renderer, data);
    }

    fn ensureLabels(self: *AiDebugOverlay, text_service: *TextService, renderer: *Renderer) !void {
        if (self.labels_ready) return;
        // Each behavior label is prepared in its own behavior color, so both the
        // per-agent world-space label and the HUD tally line read as that hue.
        inline for (std.meta.tags(AiBehavior)) |behavior| {
            self.behavior_labels[@intFromEnum(behavior)] =
                try text_service.prepareDefaultText(renderer, @tagName(behavior), behavior_colors[@intFromEnum(behavior)]);
        }
        for (&self.tier_labels, tier_names) |*slot, name| {
            slot.* = try text_service.prepareDefaultText(renderer, name, hud_color);
        }
        for (&self.digits, 0..) |*slot, index| {
            const digit = [_]u8{@intCast('0' + index)};
            slot.* = try text_service.prepareDefaultText(renderer, &digit, hud_color);
        }
        self.labels_ready = true;
    }

    // Two screen-space (drawable) HUD blocks composed from cached glyphs so no
    // per-frame string→texture work occurs (only a stack `bufPrint`): the scope
    // tier counts, then the global per-behavior tally across all cognition
    // agents. Read-only const-slice reads throughout.
    fn drawHud(self: *AiDebugOverlay, renderer: *Renderer, data: *const DataSystem) !void {
        const line_height: f32 = 18;
        const block_gap: f32 = 10;
        // Start below the engine FPS line (drawable x=12, y=10), leaving a gap
        // that tracks the FPS line's DPI-scaled height so the two never overlap.
        const hud_top_pad: f32 = 6;
        var y: f32 = 10 + fpsOverlayFontSize(renderer.drawablePixelScale()) + hud_top_pad;

        const stats = data.simulationScopeStatsFullActive();
        const tier_counts = [hud_lines]usize{
            stats.total_entities,
            stats.cognition_entities,
            stats.locomotion_entities,
            stats.kinematic_entities,
            stats.dormant_entities,
        };
        for (self.tier_labels, tier_counts) |label, value| {
            try self.drawHudLine(renderer, label, value, y);
            y += line_height;
        }

        y += block_gap;
        const behavior_counts = tallyBehaviorsByCognition(data);
        for (self.behavior_labels, behavior_counts) |label, value| {
            try self.drawHudLine(renderer, label, value, y);
            y += line_height;
        }
    }

    // One HUD line: the (already-colored) label followed by `value` composed
    // from the cached yellow digit glyphs. `bufPrint` writes a fixed stack
    // buffer, so no allocation.
    fn drawHudLine(self: *AiDebugOverlay, renderer: *Renderer, label: PreparedText, value: usize, y: f32) !void {
        var x: f32 = 12;
        try drawHudText(renderer, label, x, y);
        x += @floatFromInt(label.width);
        var buffer: [max_hud_digits]u8 = undefined;
        const digits = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch "0";
        for (digits) |ch| {
            const glyph = self.digits[ch - '0'];
            try drawHudText(renderer, glyph, x, y);
            x += @floatFromInt(glyph.width);
        }
    }
};

// Live count of active behaviors across every cognition-tier AI agent (not just
// the annotated set), so the HUD shows the true global distribution regardless
// of which agents are on-camera. A single read-only O(agents) pass, no alloc.
fn tallyBehaviorsByCognition(data: *const DataSystem) [behavior_count]usize {
    var counts = [_]usize{0} ** behavior_count;
    const agents = data.aiAgentSliceConst();
    const scope = data.scopeColumnsSliceConst();
    for (agents.entities, agents.behaviors) |entity, behavior| {
        const mdi = data.movementBodyDenseIndex(entity) orelse continue;
        if (scope.tier[mdi] != .cognition) continue;
        counts[@intFromEnum(behavior)] += 1;
    }
    return counts;
}

fn drawHudText(renderer: *Renderer, prepared: PreparedText, x: f32, y: f32) !void {
    try text.drawPreparedText(renderer, prepared, .{
        .x = x,
        .y = y,
        .order = overlay_order,
        .coordinate_space = .drawable,
    });
}

fn drawAgent(renderer: *Renderer, ann: AgentAnnotation, labels: [behavior_count]PreparedText) !void {
    const behavior_color = behavior_colors[@intFromEnum(ann.behavior)];
    if (ann.has_perception and ann.vision_range > 0) {
        try drawVisionCone(renderer, ann.position, ann.facing, ann.vision_range, ann.fov_half_angle, behavior_color);
    }
    if (ann.has_affect) {
        try drawDriveBars(renderer, ann.position, ann.drives, ann.above_threshold_mask);
    }
    for (ann.contacts[0..ann.memory_contact_count]) |contact| {
        try drawMemoryMarker(renderer, contact);
    }
    try drawBehaviorLabel(renderer, ann.position, labels[@intFromEnum(ann.behavior)]);
}

fn drawVisionCone(renderer: *Renderer, origin: Vec2, facing: Vec2, range: f32, fov_half_angle: f32, color: Color) !void {
    // Tint the cone with the agent's behavior color at reduced alpha, so the
    // active behavior reads from the cone alone.
    var cone_tint = color;
    cone_tint.a = cone_alpha;
    var ring_tint = color;
    ring_tint.a = ring_alpha;

    const angles = coneSpokeAngles(facing, fov_half_angle);
    for (angles) |angle| {
        try submitWhiteQuad(renderer, origin, angle, range, spoke_thickness, cone_tint);
    }

    // Arc polyline: consecutive chord quads. A chord spanning [a, a+step] runs
    // at angle a + step/2 + pi/2 (tangent) with length 2*R*sin(step/2), so the
    // ring needs no per-segment atan2.
    const start = angles[0];
    const step = (2.0 * fov_half_angle) / @as(f32, @floatFromInt(ring_segments));
    const chord_len = 2.0 * range * @sin(step * 0.5);
    const chord_angle_bias = step * 0.5 + std.math.pi / 2.0;
    for (0..ring_segments) |i| {
        const a = start + step * @as(f32, @floatFromInt(i));
        const dir = math.sinCos(a);
        const p = Vec2{ .x = origin.x + range * dir.cos, .y = origin.y + range * dir.sin };
        try submitWhiteQuad(renderer, p, a + chord_angle_bias, chord_len, ring_thickness, ring_tint);
    }
}

// A thin rotated quad whose rotation pivots on `origin`, extending `length`
// along the rotated +x axis (origin at the quad's left-center — see the
// sprite quad emitter: world pivot = dest + origin).
fn submitWhiteQuad(renderer: *Renderer, origin: Vec2, angle: f32, length: f32, thickness: f32, color: Color) !void {
    try renderer.submitOrderedSprite(.{
        .texture = renderer.whiteTexture(),
        .dest = .{ .x = origin.x, .y = origin.y - thickness * 0.5, .w = length, .h = thickness },
        .origin = .{ .x = 0, .y = thickness * 0.5 },
        .rotation = angle,
        .tint = color,
        .order = overlay_order,
        .coordinate_space = .world,
    });
}

fn drawDriveBars(renderer: *Renderer, origin: Vec2, drives: [drive_count]f32, mask: u8) !void {
    const left = origin.x - bar_max_width * 0.5;
    for (drives, 0..) |value, i| {
        const y = origin.y - bar_stack_offset - @as(f32, @floatFromInt(i)) * (bar_height + bar_gap);
        try renderer.submitOrderedRectInSpace(
            .{ .x = left, .y = y, .w = bar_max_width, .h = bar_height },
            bar_track_color,
            overlay_order,
            .world,
        );
        const fill = bar_max_width * math.clamp(value, 0, 1);
        const above = (mask & (@as(u8, 1) << @intCast(i))) != 0;
        try renderer.submitOrderedRectInSpace(
            .{ .x = left, .y = y, .w = fill, .h = bar_height },
            if (above) bar_hot_color else bar_fill_color,
            overlay_order,
            .world,
        );
    }
}

fn drawMemoryMarker(renderer: *Renderer, contact: ContactMarker) !void {
    const fade = 1.0 - math.clamp(contact.age / max_ai_memory_staleness, 0, 1);
    var color = marker_color;
    color.a *= fade;
    try renderer.submitOrderedRectInSpace(
        .{
            .x = contact.position.x - marker_size * 0.5,
            .y = contact.position.y - marker_size * 0.5,
            .w = marker_size,
            .h = marker_size,
        },
        color,
        overlay_order,
        .world,
    );
}

fn drawBehaviorLabel(renderer: *Renderer, origin: Vec2, label: PreparedText) !void {
    const y = origin.y - bar_stack_offset - @as(f32, @floatFromInt(drive_count)) * (bar_height + bar_gap) - @as(f32, @floatFromInt(label.height));
    try text.drawPreparedText(renderer, label, .{
        .x = origin.x,
        .y = y,
        .anchor = .top_center,
        .order = overlay_order,
        .coordinate_space = .world,
    });
}

// --- Tests ---

const testing = std.testing;

fn addCognitionAgent(data: *DataSystem, x: f32, y: f32) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = y } });
    try data.setAiAgent(entity, .{});
    return entity;
}

test "tallyBehaviorsByCognition counts the whole cognition set independent of camera and excludes other tiers" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // Behaviors spread across the map — far off any camera. The tally is global.
    const specs = [_]struct { x: f32, behavior: AiBehavior }{
        .{ .x = -9000, .behavior = .pursue },
        .{ .x = 9000, .behavior = .pursue },
        .{ .x = 12345, .behavior = .flee },
        .{ .x = -1, .behavior = .wander },
    };
    for (specs) |spec| {
        const entity = try data.createEntity();
        try data.setMovementBody(entity, .{ .position = .{ .x = spec.x, .y = 0 } });
        // active_behavior is a hot column preserved across upserts, so it must be
        // set at first append (a later setAiAgent retune would not change it).
        try data.setAiAgent(entity, .{ .active_behavior = spec.behavior });
    }
    // A cohere agent demoted out of cognition must not be tallied.
    const demoted = try data.createEntity();
    try data.setMovementBody(demoted, .{ .position = .{ .x = 5, .y = 5 } });
    try data.setAiAgent(demoted, .{ .active_behavior = .cohere });
    try data.setSimulationTier(demoted, .locomotion);

    const counts = tallyBehaviorsByCognition(&data);
    try testing.expectEqual(@as(usize, 1), counts[@intFromEnum(AiBehavior.wander)]);
    try testing.expectEqual(@as(usize, 2), counts[@intFromEnum(AiBehavior.pursue)]);
    try testing.expectEqual(@as(usize, 1), counts[@intFromEnum(AiBehavior.flee)]);
    try testing.expectEqual(@as(usize, 0), counts[@intFromEnum(AiBehavior.investigate)]);
    try testing.expectEqual(@as(usize, 0), counts[@intFromEnum(AiBehavior.cohere)]);
}

test "gatherAnnotations caps at kMaxAnnotatedAgents regardless of agent count or camera size" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // 40 cognition agents, all inside a wide camera rect.
    const camera = Rect{ .x = 0, .y = 0, .w = 4000, .h = 4000 };
    for (0..40) |i| {
        _ = try addCognitionAgent(&data, @floatFromInt(10 * i), @floatFromInt(10 * i));
    }

    var out: [kMaxAnnotatedAgents]AgentAnnotation = undefined;
    try testing.expectEqual(kMaxAnnotatedAgents, gatherAnnotations(&data, camera, &out));

    // A far larger camera rect (same agents) yields the identical cap: the bound
    // is a fixed constant, independent of world/camera size.
    const bigger = Rect{ .x = -10000, .y = -10000, .w = 100000, .h = 100000 };
    try testing.expectEqual(kMaxAnnotatedAgents, gatherAnnotations(&data, bigger, &out));
}

test "gatherAnnotations excludes agents outside the camera rect and non-cognition tiers" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const camera = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };

    const inside = try addCognitionAgent(&data, 50, 50);
    _ = try addCognitionAgent(&data, 500, 500); // outside the rect
    const demoted = try addCognitionAgent(&data, 25, 25); // inside but not cognition
    try data.setSimulationTier(demoted, .locomotion);
    _ = inside;

    var out: [kMaxAnnotatedAgents]AgentAnnotation = undefined;
    const count = gatherAnnotations(&data, camera, &out);
    try testing.expectEqual(@as(usize, 1), count);
    try testing.expectEqual(@as(f32, 50), out[0].position.x);
}

test "gatherAnnotations populates sub-component viz and skips missing components" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const camera = Rect{ .x = 0, .y = 0, .w = 1000, .h = 1000 };

    const entity = try addCognitionAgent(&data, 100, 200);
    try data.setAiPerception(entity, .{ .vision_range = 150, .fov_half_angle_radians = 0.6 });
    try data.setAiAffect(entity, .{ .fear = 0.4, .curiosity = 0.7 });
    var memory = data_system.AiMemory{};
    memory.ring[0] = .{ .entity = entity, .x = 12, .y = 34, .age = 5 };
    memory.ring[2] = .{ .entity = entity, .x = 56, .y = 78, .age = 10 };
    try data.setAiMemory(entity, memory);

    // A bare agent (no perception/affect/memory) must still annotate.
    _ = try addCognitionAgent(&data, 300, 300);

    var out: [kMaxAnnotatedAgents]AgentAnnotation = undefined;
    const count = gatherAnnotations(&data, camera, &out);
    try testing.expectEqual(@as(usize, 2), count);

    const equipped = out[0];
    try testing.expect(equipped.has_perception);
    try testing.expectEqual(@as(f32, 150), equipped.vision_range);
    try testing.expectEqual(@as(f32, 0.6), equipped.fov_half_angle);
    try testing.expect(equipped.has_affect);
    try testing.expectEqual(@as(f32, 0.4), equipped.drives[@intFromEnum(AiAffectDrive.fear)]);
    try testing.expectEqual(@as(f32, 0.7), equipped.drives[@intFromEnum(AiAffectDrive.curiosity)]);
    try testing.expectEqual(@as(usize, 2), equipped.memory_contact_count);
    try testing.expectEqual(@as(f32, 12), equipped.contacts[0].position.x);
    try testing.expectEqual(@as(f32, 56), equipped.contacts[1].position.x);

    const bare = out[1];
    try testing.expect(!bare.has_perception);
    try testing.expect(!bare.has_affect);
    try testing.expectEqual(@as(usize, 0), bare.memory_contact_count);
}

test "gatherAnnotations does not perturb AI state (read-only const-view proof)" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const camera = Rect{ .x = 0, .y = 0, .w = 1000, .h = 1000 };

    for (0..4) |i| {
        const entity = try addCognitionAgent(&data, @floatFromInt(50 * i), 50);
        try data.setAiPerception(entity, .{ .vision_range = 120, .fov_half_angle_radians = 0.5 });
        try data.setAiAffect(entity, .{ .fear = 0.3, .aggression = 0.6 });
        try data.setAiMemory(entity, .{});
    }

    const before = aiStateHash(&data);
    var out: [kMaxAnnotatedAgents]AgentAnnotation = undefined;
    _ = gatherAnnotations(&data, camera, &out);
    try testing.expectEqual(before, aiStateHash(&data));
}

test "coneSpokeAngles returns facing_angle +/- fov" {
    {
        const spokes = coneSpokeAngles(.{ .x = 1, .y = 0 }, 0.5);
        try testing.expectApproxEqAbs(@as(f32, -0.5), spokes[0], 1.0e-6);
        try testing.expectApproxEqAbs(@as(f32, 0.5), spokes[1], 1.0e-6);
    }
    {
        const spokes = coneSpokeAngles(.{ .x = 0, .y = 1 }, 0.5);
        try testing.expectApproxEqAbs(std.math.pi / 2.0 - 0.5, spokes[0], 1.0e-6);
        try testing.expectApproxEqAbs(std.math.pi / 2.0 + 0.5, spokes[1], 1.0e-6);
    }
}

test "behavior label cache covers every AiBehavior tag" {
    try testing.expectEqual(behavior_count, @typeInfo(@TypeOf((AiDebugOverlay{}).behavior_labels)).array.len);
}

test "command capacity is a fixed bound from the fixed budgets" {
    try testing.expectEqual(kMaxAnnotatedAgents * per_agent_commands + hud_commands, AiDebugOverlay.commandCapacity());
}

test "draw never exceeds commandCapacity for a worst-case frame (FailingAllocator proof)" {
    const allocator = testing.allocator;
    var data = DataSystem.init(allocator);
    defer data.deinit();
    const camera = Rect{ .x = 0, .y = 0, .w = 100000, .h = 100000 };

    // Worst case: kMaxAnnotatedAgents fully-equipped cognition agents inside the
    // rect, each carrying perception (2 spokes + ring), affect (drive bars), and
    // a fully-populated memory ring (max markers).
    var full_ring = data_system.AiMemory{};
    for (0..ai_memory_ring_capacity) |slot| {
        full_ring.ring[slot] = .{ .entity = try EntityId.init(1, 1), .x = 1, .y = 1, .age = 1 };
    }
    for (0..kMaxAnnotatedAgents) |i| {
        const entity = try addCognitionAgent(&data, @floatFromInt(10 * i), 10);
        try data.setAiPerception(entity, .{ .vision_range = 120, .fov_half_angle_radians = 0.5 });
        try data.setAiAffect(entity, .{ .fear = 0.5, .curiosity = 0.5, .aggression = 0.5, .fatigue = 0.5 });
        try data.setAiMemory(entity, full_ring);
    }

    // Headless CPU-only renderer (mirrors render_prep.zig's fixtures): the GPU
    // handles are never dereferenced by the submission-only draw path.
    var renderer = Renderer{
        .allocator = allocator,
        .device = undefined,
        .window = undefined,
        .pipeline = undefined,
        .tilemap_pipeline = undefined,
        .sampler = undefined,
        .vertex_streams = undefined,
        .batch_capacity_vertices = 0,
        .batch = sprite_batch.SpriteBatch.init(allocator),
    };
    defer renderer.batch.deinit();
    defer renderer.static_positions.deinit(allocator);
    defer renderer.static_uvs.deinit(allocator);
    defer renderer.static_colors.deinit(allocator);
    defer renderer.static_groups.deinit(allocator);
    defer renderer.draw_list.deinit(allocator);

    var overlay = AiDebugOverlay.init();
    defer overlay.deinit();
    // Hand-craft valid label handles so `drawPreparedText` actually submits the
    // label + HUD commands (display-free: a `Sprite` submission never touches the
    // GPU). `labels_ready` short-circuits `ensureLabels`, so the dummy
    // `text_service` pointer passed to `draw` below is never dereferenced.
    const dummy_label = PreparedText{ .texture = try sprite_batch.TextureId.init(1, 1), .width = 8, .height = 8 };
    overlay.behavior_labels = [_]PreparedText{dummy_label} ** behavior_count;
    overlay.tier_labels = [_]PreparedText{dummy_label} ** hud_lines;
    overlay.digits = [_]PreparedText{dummy_label} ** 10;
    overlay.labels_ready = true;

    renderer.beginFrame(.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    // Reserve exactly the overlay's fixed budget (warmup on the real allocator),
    // then forbid any further growth. With the frame reserved every submit is
    // assumeCapacity-only, so a future sub-viz element added past
    // per_agent_commands would overflow the reservation instead of silently
    // writing past it in ReleaseFast (where the assumeCapacity assert is stripped).
    try renderer.reserveSpriteCommands(AiDebugOverlay.commandCapacity());

    var failing = testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    renderer.allocator = failing.allocator();
    renderer.batch.allocator = failing.allocator();
    defer {
        renderer.allocator = allocator;
        renderer.batch.allocator = allocator;
    }

    var dummy_text: TextService = undefined;
    try overlay.draw(&data, camera, &renderer, &dummy_text);

    try testing.expect(renderer.spriteCommandCount() <= AiDebugOverlay.commandCapacity());
    try testing.expectEqual(@as(usize, 0), failing.allocations);
    try testing.expect(!failing.has_induced_failure);
}

// Folds the AI-relevant DataSystem columns into a hash so the read-only proof
// can assert the gather left every column byte-identical. Test-local, not a
// production checksum.
fn aiStateHash(data: *const DataSystem) u64 {
    var hasher = std.hash.Wyhash.init(0);
    const agents = data.aiAgentSliceConst();
    for (agents.behaviors) |b| hasher.update(std.mem.asBytes(&b));
    const bodies = data.movementBodySliceConst();
    hasher.update(std.mem.sliceAsBytes(bodies.position_x));
    hasher.update(std.mem.sliceAsBytes(bodies.position_y));
    const perception = data.aiPerceptionSliceConst();
    hasher.update(std.mem.sliceAsBytes(perception.facing_x));
    hasher.update(std.mem.sliceAsBytes(perception.facing_y));
    hasher.update(std.mem.sliceAsBytes(perception.vision_range));
    const affect = data.aiAffectSliceConst();
    hasher.update(std.mem.sliceAsBytes(affect.fear));
    hasher.update(std.mem.sliceAsBytes(affect.curiosity));
    hasher.update(std.mem.sliceAsBytes(affect.aggression));
    hasher.update(std.mem.sliceAsBytes(affect.fatigue));
    hasher.update(affect.above_threshold_mask);
    const memory = data.aiMemorySliceConst();
    hasher.update(std.mem.sliceAsBytes(memory.ring_x));
    hasher.update(std.mem.sliceAsBytes(memory.ring_y));
    hasher.update(std.mem.sliceAsBytes(memory.ring_age));
    return hasher.final();
}
