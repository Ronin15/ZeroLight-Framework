// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

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
    const prompt_text = "Enter / Space / P to resume    Esc to quit";

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
    const text_service = context.text_service orelse return;
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
