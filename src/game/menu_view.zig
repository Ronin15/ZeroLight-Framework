// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Small shared helpers for simple vertical text-based menus used by game states.
//! Deliberately lean: no allocation after setup, no widget tree, just common
//! draw loop and selection math to reduce duplication between specific menu
//! states (e.g. main menu and settings).

const std = @import("std");
const config = @import("../config.zig");
const Renderer = @import("../render/renderer.zig").Renderer;
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
    overlay_layer: i32,
    panel_layer: i32,
    highlight_layer: i32,
    text_layer: i32,
) !void {
    try drawScreenRect(renderer, .{ .x = 0, .y = 0, .w = width, .h = height }, overlay_color, overlay_layer);

    const panel_x = (width - panel_width) * 0.5;
    const panel_y = (height - panel_height) * 0.5;
    try drawScreenRect(renderer, .{
        .x = panel_x,
        .y = panel_y,
        .w = panel_width,
        .h = panel_height,
    }, panel_color, panel_layer);

    try text.drawPreparedText(renderer, title, .{
        .x = width * 0.5,
        .y = title_y,
        .anchor = .top_center,
        .layer = text_layer,
    });

    var y = first_item_y;
    for (items, 0..) |item, i| {
        const is_sel = (i == selected);
        if (is_sel) {
            const hx = (width - panel_width) * 0.5 + 10;
            const hw = panel_width - 20;
            try drawScreenRect(renderer, .{
                .x = hx,
                .y = y - 4,
                .w = hw,
                .h = 28,
            }, highlight_color, highlight_layer);
        }

        try text.drawPreparedText(renderer, item, .{
            .x = width * 0.5,
            .y = y,
            .anchor = .top_center,
            .layer = text_layer,
        });

        y += item_spacing;
    }
}

fn drawScreenRect(renderer: *Renderer, rect: @import("../render/renderer.zig").Rect, color: config.Color, layer: i32) !void {
    try renderer.drawRectInSpace(rect, color, layer, .logical);
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
