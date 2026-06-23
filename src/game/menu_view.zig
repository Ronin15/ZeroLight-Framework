// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Small shared helpers for simple vertical text-based menus used by game states.
//! Deliberately lean: no allocation after setup, no widget tree, just common
//! draw loop and selection math to reduce duplication between specific menu
//! states (e.g. main menu and settings).

const std = @import("std");
const config = @import("../config.zig");
const renderer_file = @import("../render/renderer.zig");
const RenderOrder = renderer_file.RenderOrder;
const Renderer = renderer_file.Renderer;
const Rect = renderer_file.Rect;
const UiDepth = renderer_file.UiDepth;
const UiStackOrder = renderer_file.UiStackOrder;
const text = @import("../render/text.zig");
const PreparedText = text.PreparedText;

pub fn changeSelection(selected: *usize, delta: i32, item_count: usize) void {
    const n: i32 = @intCast(item_count);
    var s: i32 = @as(i32, @intCast(selected.*)) + delta;
    if (s < 0) s += n;
    if (s >= n) s -= n;
    selected.* = @intCast(s);
}

/// Renders a simple centered menu panel with title and selectable items.
pub fn renderList(
    renderer: *Renderer,
    width: f32,
    height: f32,
    title: PreparedText,
    items: []const PreparedText,
    selected: usize,
    title_y: f32,
    first_item_y: f32,
    item_spacing: f32,
    panel_width: f32,
    panel_height: f32,
    overlay_color: config.Color,
    panel_color: config.Color,
    highlight_color: config.Color,
    ui_stack_order: UiStackOrder,
    overlay_depth: UiDepth,
    panel_depth: UiDepth,
    highlight_depth: UiDepth,
    text_depth: UiDepth,
) !void {
    try drawScreenRect(renderer, .{ .x = 0, .y = 0, .w = width, .h = height }, overlay_color, ui_stack_order, overlay_depth);

    const panel_x = (width - panel_width) * 0.5;
    const panel_y = (height - panel_height) * 0.5;
    try drawScreenRect(renderer, .{
        .x = panel_x,
        .y = panel_y,
        .w = panel_width,
        .h = panel_height,
    }, panel_color, ui_stack_order, panel_depth);

    var y = first_item_y;
    for (items, 0..) |_, i| {
        const is_sel = (i == selected);
        if (is_sel) {
            const hx = (width - panel_width) * 0.5 + 10;
            const hw = panel_width - 20;
            try drawScreenRect(renderer, .{
                .x = hx,
                .y = y - 4,
                .w = hw,
                .h = 28,
            }, highlight_color, ui_stack_order, highlight_depth);
        }
        y += item_spacing;
    }

    try text.drawPreparedText(renderer, title, .{
        .x = width * 0.5,
        .y = title_y,
        .anchor = .top_center,
        .order = uiOrder(ui_stack_order, text_depth),
    });

    y = first_item_y;
    for (items) |item| {
        try text.drawPreparedText(renderer, item, .{
            .x = width * 0.5,
            .y = y,
            .anchor = .top_center,
            .order = uiOrder(ui_stack_order, text_depth),
        });

        y += item_spacing;
    }
}

fn drawScreenRect(renderer: *Renderer, rect: Rect, color: config.Color, ui_stack_order: UiStackOrder, depth: UiDepth) !void {
    try renderer.submitOrderedRectInSpace(rect, color, uiOrder(ui_stack_order, depth), .logical);
}

fn uiOrder(ui_stack_order: UiStackOrder, depth: UiDepth) RenderOrder {
    return RenderOrder.uiInStack(ui_stack_order, depth);
}

test "menu_view changeSelection wraps" {
    var sel: usize = 0;
    changeSelection(&sel, -1, 3);
    try std.testing.expectEqual(@as(usize, 2), sel);
    changeSelection(&sel, 1, 3);
    try std.testing.expectEqual(@as(usize, 0), sel);
    changeSelection(&sel, 1, 3);
    try std.testing.expectEqual(@as(usize, 1), sel);
}
