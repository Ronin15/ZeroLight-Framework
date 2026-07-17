// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const config = @import("../config.zig");
const renderer_file = @import("../render/renderer.zig");
const RenderOrder = renderer_file.RenderOrder;
const Renderer = renderer_file.Renderer;
const UiDepth = renderer_file.UiDepth;
const UiStackOrder = renderer_file.UiStackOrder;
const text = @import("../render/text.zig");
const PreparedText = text.PreparedText;
const RenderContext = @import("../app/state.zig").RenderContext;
const StateTransitions = @import("../app/state.zig").StateTransitions;
const UpdateContext = @import("../app/state.zig").UpdateContext;
const inputFile = @import("../app/input.zig");
const c = @import("../platform/sdl.zig").c;

pub const PauseState = struct {
    width: f32,
    height: f32,
    prompt: PreparedText = .invalid,

    const panel_width: f32 = 220;
    const panel_height: f32 = 132;
    const prompt_gap_below_panel: f32 = 18;
    const prompt_screen_margin: f32 = 16;
    const overlay_color = config.Color{ .r = 0.02, .g = 0.025, .b = 0.03, .a = 0.68 };
    const panel_color = config.Color{ .r = 0.12, .g = 0.15, .b = 0.18, .a = 0.9 };
    const accent_color = config.Color{ .r = 1.0, .g = 0.86, .b = 0.2, .a = 1.0 };
    const prompt_color = config.Color{ .r = 0.92, .g = 0.95, .b = 0.96, .a = 1.0 };
    const prompt_text = "Enter / Space / P / A / Start to resume    Esc / B to quit";

    pub fn init(width: f32, height: f32) PauseState {
        return .{ .width = width, .height = height };
    }

    pub fn deinit(self: *PauseState) void {
        _ = self;
    }

    pub fn handleEvent(self: *PauseState, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        _ = self;
        _ = event;
        _ = transitions;
        return false;
    }

    pub fn update(self: *PauseState, context: UpdateContext) !void {
        _ = self;
        _ = context;
    }

    pub fn render(self: *PauseState, context: RenderContext) !void {
        _ = context.interpolation_alpha;
        _ = context.thread_system;

        try drawScreenRect(context.renderer, .{ .x = 0, .y = 0, .w = self.width, .h = self.height }, overlay_color, context.ui_stack_order, .background);

        const panel_x = (self.width - panel_width) * 0.5;
        const panel_y = (self.height - panel_height) * 0.5;
        try drawScreenRect(context.renderer, .{
            .x = panel_x,
            .y = panel_y,
            .w = panel_width,
            .h = panel_height,
        }, panel_color, context.ui_stack_order, .panel);

        const bar_width: f32 = 28;
        const bar_height: f32 = 72;
        const gap: f32 = 24;
        const left_x = (self.width - gap) * 0.5 - bar_width;
        const right_x = (self.width + gap) * 0.5;
        const bar_y = (self.height - bar_height) * 0.5;

        try drawScreenRect(context.renderer, .{ .x = left_x, .y = bar_y, .w = bar_width, .h = bar_height }, accent_color, context.ui_stack_order, .highlight);
        try drawScreenRect(context.renderer, .{ .x = right_x, .y = bar_y, .w = bar_width, .h = bar_height }, accent_color, context.ui_stack_order, .highlight);

        try drawPrompt(self, context);
    }

    pub fn onPause(self: *PauseState) void {
        _ = self;
    }
};

fn drawScreenRect(renderer: *Renderer, rect: @import("../render/renderer.zig").Rect, color: config.Color, ui_stack_order: UiStackOrder, depth: UiDepth) !void {
    try renderer.submitOrderedRectInSpace(rect, color, uiOrder(ui_stack_order, depth), .logical);
}

fn drawPrompt(self: *PauseState, context: RenderContext) !void {
    const text_service = context.text_service;
    if (!self.prompt.isValid()) {
        self.prompt = try text_service.prepareDefaultText(context.renderer, PauseState.prompt_text, PauseState.prompt_color);
    }
    const prompt_height: f32 = @floatFromInt(self.prompt.height);
    const panel_bottom = (self.height + PauseState.panel_height) * 0.5;
    const prompt_y = @min(
        panel_bottom + PauseState.prompt_gap_below_panel,
        self.height - prompt_height - PauseState.prompt_screen_margin,
    );
    try text.drawPreparedText(context.renderer, self.prompt, .{
        .x = self.width * 0.5,
        .y = prompt_y,
        .anchor = .top_center,
        .order = uiOrder(context.ui_stack_order, .text),
    });
}

fn uiOrder(ui_stack_order: UiStackOrder, depth: UiDepth) RenderOrder {
    return RenderOrder.uiInStack(ui_stack_order, depth);
}

// PauseState intentionally does not consume quit/resume in handleEvent: those
// one-frame commands flow through FrameCommands so Engine/PauseController own
// the transition. Direct contract tests pin that non-consuming behavior.
test "pause handleEvent returns false for quit key so FrameCommands can observe it" {
    var pause = PauseState.init(800, 450);
    defer pause.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    const quit_event = keyEventForAction(.quit);
    try std.testing.expect(!(try pause.handleEvent(&quit_event, &transitions)));
    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);
}

test "pause handleEvent returns false for quit gamepad East so FrameCommands can observe it" {
    var pause = PauseState.init(800, 450);
    defer pause.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    const quit_event = gamepadButtonEventForAction(.quit);
    try std.testing.expect(!(try pause.handleEvent(&quit_event, &transitions)));
    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);
}

test "pause handleEvent returns false for resume shapes so FrameCommands can observe them" {
    var pause = PauseState.init(800, 450);
    defer pause.deinit();
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    const resume_key = keyEventForAction(.resume_game);
    try std.testing.expect(!(try pause.handleEvent(&resume_key, &transitions)));
    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);

    const resume_gamepad = gamepadButtonEventForAction(.resume_game);
    try std.testing.expect(!(try pause.handleEvent(&resume_gamepad, &transitions)));
    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);
}

fn keyEventForAction(action: inputFile.Action) c.SDL_Event {
    for (inputFile.default_key_bindings) |binding| {
        if (binding.action == action) {
            return c.SDL_Event{ .key = .{
                .type = c.SDL_EVENT_KEY_DOWN,
                .reserved = 0,
                .timestamp = 0,
                .windowID = 0,
                .which = 0,
                .scancode = 0,
                .key = binding.key,
                .mod = 0,
                .raw = 0,
                .down = true,
                .repeat = false,
            } };
        }
    }
    unreachable;
}

fn gamepadButtonEventForAction(action: inputFile.Action) c.SDL_Event {
    for (inputFile.default_gamepad_bindings) |binding| {
        if (binding.action == action) {
            return c.SDL_Event{ .gbutton = .{
                .type = c.SDL_EVENT_GAMEPAD_BUTTON_DOWN,
                .reserved = 0,
                .timestamp = 0,
                .which = 0,
                .button = @intCast(binding.button),
                .down = true,
                .padding1 = 0,
                .padding2 = 0,
            } };
        }
    }
    unreachable;
}
