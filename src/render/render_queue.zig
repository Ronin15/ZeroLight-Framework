// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const renderer_file = @import("renderer.zig");

pub const CoordinateSpace = renderer_file.CoordinateSpace;
pub const Rect = renderer_file.Rect;
pub const RenderOrder = renderer_file.RenderOrder;
pub const Renderer = renderer_file.Renderer;
pub const Sprite = renderer_file.Sprite;
const TextureId = renderer_file.TextureId;
const Color = @import("../config.zig").Color;

pub const RenderQueue = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayList(DrawRecord) = .empty,
    sort_keys: std.ArrayList(SortKey) = .empty,
    next_sequence: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) RenderQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RenderQueue) void {
        self.records.deinit(self.allocator);
        self.sort_keys.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *RenderQueue) void {
        self.records.clearRetainingCapacity();
        self.sort_keys.clearRetainingCapacity();
        self.next_sequence = 0;
    }

    pub fn ensureTotalCapacity(self: *RenderQueue, capacity: usize) !void {
        try self.records.ensureTotalCapacity(self.allocator, capacity);
        try self.sort_keys.ensureTotalCapacity(self.allocator, capacity);
    }

    pub fn addSprite(self: *RenderQueue, sprite: Sprite) !void {
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        try self.sort_keys.ensureUnusedCapacity(self.allocator, 1);
        const record_index = self.records.items.len;
        self.records.appendAssumeCapacity(.{
            .order = sprite.order,
            .sequence = self.next_sequence,
            .payload = .{ .sprite = sprite },
        });
        self.sort_keys.appendAssumeCapacity(.{
            .order = sprite.order,
            .sequence = self.next_sequence,
            .record_index = record_index,
        });
        self.next_sequence +%= 1;
    }

    pub fn addRect(
        self: *RenderQueue,
        rect: Rect,
        color: Color,
        order: RenderOrder,
        coordinate_space: CoordinateSpace,
    ) !void {
        try self.records.ensureUnusedCapacity(self.allocator, 1);
        try self.sort_keys.ensureUnusedCapacity(self.allocator, 1);
        const record_index = self.records.items.len;
        self.records.appendAssumeCapacity(.{
            .order = order,
            .sequence = self.next_sequence,
            .payload = .{ .rect = .{
                .rect = rect,
                .color = color,
                .coordinate_space = coordinate_space,
            } },
        });
        self.sort_keys.appendAssumeCapacity(.{
            .order = order,
            .sequence = self.next_sequence,
            .record_index = record_index,
        });
        self.next_sequence +%= 1;
    }

    pub fn sortForSubmit(self: *RenderQueue) void {
        std.mem.sort(SortKey, self.sort_keys.items, {}, sortKeyLessThan);
    }

    pub fn recordCount(self: *const RenderQueue) usize {
        return self.records.items.len;
    }

    pub fn recordOrder(self: *const RenderQueue, index: usize) RenderOrder {
        return self.sort_keys.items[index].order;
    }

    pub fn sortedSprite(self: *const RenderQueue, index: usize) ?Sprite {
        const key = self.sort_keys.items[index];
        const record = self.records.items[key.record_index];
        return switch (record.payload) {
            .sprite => |sprite_record| blk: {
                var sprite = sprite_record;
                sprite.order = key.order;
                break :blk sprite;
            },
            .rect => null,
        };
    }

    pub fn submit(self: *RenderQueue, renderer: *Renderer) !void {
        self.sortForSubmit();
        for (self.sort_keys.items) |key| {
            const record = self.records.items[key.record_index];
            switch (record.payload) {
                .sprite => |sprite_record| {
                    var sprite = sprite_record;
                    sprite.order = key.order;
                    try renderer.submitOrderedSprite(sprite);
                },
                .rect => |rect| try renderer.submitOrderedRectInSpace(
                    rect.rect,
                    rect.color,
                    key.order,
                    rect.coordinate_space,
                ),
            }
        }
    }
};

const RectRecord = struct {
    rect: Rect,
    color: Color,
    coordinate_space: CoordinateSpace,
};

const DrawPayload = union(enum) {
    sprite: Sprite,
    rect: RectRecord,
};

const DrawRecord = struct {
    order: RenderOrder,
    sequence: u64,
    payload: DrawPayload,
};

const SortKey = struct {
    order: RenderOrder,
    sequence: u64,
    record_index: usize,
};

fn sortKeyLessThan(_: void, lhs: SortKey, rhs: SortKey) bool {
    const lhs_domain = @intFromEnum(lhs.order.domain);
    const rhs_domain = @intFromEnum(rhs.order.domain);
    if (lhs_domain != rhs_domain) return lhs_domain < rhs_domain;
    if (lhs.order.depth != rhs.order.depth) return lhs.order.depth < rhs.order.depth;
    return lhs.sequence < rhs.sequence;
}

test "render queue sorts by render order and preserves same-order submission" {
    const Depth = enum(i32) {
        floor = -1,
        actor = 0,
        effect = 1,
    };
    var queue = RenderQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.addRect(.{ .x = 3, .y = 0, .w = 1, .h = 1 }, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, RenderOrder.world(@intFromEnum(Depth.effect)), .world);
    try queue.addRect(.{ .x = 1, .y = 0, .w = 1, .h = 1 }, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, RenderOrder.world(@intFromEnum(Depth.floor)), .world);
    try queue.addRect(.{ .x = 2, .y = 0, .w = 1, .h = 1 }, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, RenderOrder.world(@intFromEnum(Depth.actor)), .world);
    try queue.addRect(.{ .x = 4, .y = 0, .w = 1, .h = 1 }, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, RenderOrder.ui(.panel), .logical);

    queue.sortForSubmit();

    try std.testing.expectEqual(RenderOrder.world(@intFromEnum(Depth.floor)), queue.recordOrder(0));
    try std.testing.expectEqual(RenderOrder.world(@intFromEnum(Depth.actor)), queue.recordOrder(1));
    try std.testing.expectEqual(RenderOrder.world(@intFromEnum(Depth.effect)), queue.recordOrder(2));
    try std.testing.expectEqual(RenderOrder.ui(.panel), queue.recordOrder(3));
    try std.testing.expectEqual(@as(f32, 1), queue.records.items[queue.sort_keys.items[0].record_index].payload.rect.rect.x);
    try std.testing.expectEqual(@as(f32, 2), queue.records.items[queue.sort_keys.items[1].record_index].payload.rect.rect.x);
    try std.testing.expectEqual(@as(f32, 3), queue.records.items[queue.sort_keys.items[2].record_index].payload.rect.rect.x);
    try std.testing.expectEqual(@as(f32, 4), queue.records.items[queue.sort_keys.items[3].record_index].payload.rect.rect.x);
}

test "render queue exposes sorted sprite records with queue order" {
    var queue = RenderQueue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.addSprite(.{
        .texture = TextureId.init(1, 1) catch unreachable,
        .dest = .{ .x = 2, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(2),
    });
    try queue.addSprite(.{
        .texture = TextureId.init(1, 1) catch unreachable,
        .dest = .{ .x = 1, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(1),
    });

    queue.sortForSubmit();

    const first = queue.sortedSprite(0).?;
    const second = queue.sortedSprite(1).?;
    try std.testing.expectEqual(@as(f32, 1), first.dest.x);
    try std.testing.expectEqual(RenderOrder.world(1), first.order);
    try std.testing.expectEqual(@as(f32, 2), second.dest.x);
    try std.testing.expectEqual(RenderOrder.world(2), second.order);
}
