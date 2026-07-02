// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Visual and drawable-reference component storage: facing direction, the
//! data-only primitive-visual payload (size/color/depth/marker), and the
//! stable sprite-asset reference. Plus their payload validators.

const std = @import("std");
const types = @import("types.zig");
const EntityId = types.EntityId;
const Facing = types.Facing;
const FacingData = types.FacingData;
const FacingSlice = types.FacingSlice;
const ConstFacingSlice = types.ConstFacingSlice;
const PrimitiveVisual = types.PrimitiveVisual;
const ConstPrimitiveVisualSlice = types.ConstPrimitiveVisualSlice;
const AssetReference = types.AssetReference;
const ConstAssetReferenceSlice = types.ConstAssetReferenceSlice;
const config = @import("../../config.zig");
const render_depth = @import("../render_depth.zig");
const SpriteAssetId = @import("../../assets/manifest.zig").SpriteAssetId;

pub fn validatePrimitiveVisual(visual: PrimitiveVisual) !void {
    if (!std.math.isFinite(visual.size.x) or !std.math.isFinite(visual.size.y)) return error.InvalidPrimitiveVisual;
    if (visual.size.x <= 0 or visual.size.y <= 0) return error.InvalidPrimitiveVisual;
    try validatePrimitiveColor(visual.color);
    try validatePrimitiveColor(visual.marker_color);
    if (!std.math.isFinite(visual.marker_length) or visual.marker_length < 0) return error.InvalidPrimitiveVisual;
    if (!std.math.isFinite(visual.marker_depth) or visual.marker_depth < 0) return error.InvalidPrimitiveVisual;
    if (!std.math.isFinite(visual.marker_margin) or visual.marker_margin < 0) return error.InvalidPrimitiveVisual;
}

fn validatePrimitiveColor(color: config.Color) !void {
    if (!std.math.isFinite(color.r) or !std.math.isFinite(color.g) or
        !std.math.isFinite(color.b) or !std.math.isFinite(color.a))
    {
        return error.InvalidPrimitiveVisual;
    }
}

const FacingRow = struct {
    entity: EntityId,
    direction: Facing,
};

const PrimitiveVisualRow = struct {
    entity: EntityId,
    size_x: f32,
    size_y: f32,
    color_r: f32,
    color_g: f32,
    color_b: f32,
    color_a: f32,
    depth_value: i32,
    marker_color_r: f32,
    marker_color_g: f32,
    marker_color_b: f32,
    marker_color_a: f32,
    marker_depth_value: i32,
    marker_length: f32,
    marker_depth: f32,
    marker_margin: f32,
};

const AssetReferenceRow = struct {
    entity: EntityId,
    sprite: SpriteAssetId,
    atlas_entry_id: u16,
};

pub const FacingStore = struct {
    rows: std.MultiArrayList(FacingRow) = .{},

    pub fn len(self: *const FacingStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *FacingStore, allocator: std.mem.Allocator, entity: EntityId, facing: FacingData) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyFacingRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .direction = facing.direction,
        });
        return index;
    }

    pub fn setDirection(self: *FacingStore, index: usize, direction: Facing) void {
        self.rows.slice().items(.direction)[index] = direction;
    }

    pub fn directionPtr(self: *FacingStore, index: usize) *Facing {
        return &self.rows.slice().items(.direction)[index];
    }

    pub fn directionAt(self: *const FacingStore, index: usize) Facing {
        return self.rows.slice().items(.direction)[index];
    }

    pub fn removeAt(self: *FacingStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn slice(self: *FacingStore) FacingSlice {
        const s = self.rows.slice();
        return .{ .entities = s.items(.entity), .directions = s.items(.direction) };
    }

    pub fn sliceConst(self: *const FacingStore) ConstFacingSlice {
        const s = self.rows.slice();
        return .{ .entities = s.items(.entity), .directions = s.items(.direction) };
    }

    pub fn clearRetainingCapacity(self: *FacingStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *FacingStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    pub fn ensureCapacity(self: *FacingStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, capacity);
    }

    fn ensureCapacityForOne(self: *FacingStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }
};

pub const PrimitiveVisualStore = struct {
    rows: std.MultiArrayList(PrimitiveVisualRow) = .{},

    pub fn len(self: *const PrimitiveVisualStore) usize {
        return self.rows.len;
    }

    fn visualToRow(entity: EntityId, visual: PrimitiveVisual) PrimitiveVisualRow {
        return .{
            .entity = entity,
            .size_x = visual.size.x,
            .size_y = visual.size.y,
            .color_r = visual.color.r,
            .color_g = visual.color.g,
            .color_b = visual.color.b,
            .color_a = visual.color.a,
            .depth_value = render_depth.worldZ(visual.depth),
            .marker_color_r = visual.marker_color.r,
            .marker_color_g = visual.marker_color.g,
            .marker_color_b = visual.marker_color.b,
            .marker_color_a = visual.marker_color.a,
            .marker_depth_value = render_depth.worldZ(visual.marker_depth_band),
            .marker_length = visual.marker_length,
            .marker_depth = visual.marker_depth,
            .marker_margin = visual.marker_margin,
        };
    }

    pub fn append(self: *PrimitiveVisualStore, allocator: std.mem.Allocator, entity: EntityId, visual: PrimitiveVisual) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyPrimitiveVisualRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(visualToRow(entity, visual));
        return index;
    }

    pub fn set(self: *PrimitiveVisualStore, index: usize, visual: PrimitiveVisual) void {
        const row = visualToRow(.invalid, visual);
        const s = self.rows.slice();
        s.items(.size_x)[index] = row.size_x;
        s.items(.size_y)[index] = row.size_y;
        s.items(.color_r)[index] = row.color_r;
        s.items(.color_g)[index] = row.color_g;
        s.items(.color_b)[index] = row.color_b;
        s.items(.color_a)[index] = row.color_a;
        s.items(.depth_value)[index] = row.depth_value;
        s.items(.marker_color_r)[index] = row.marker_color_r;
        s.items(.marker_color_g)[index] = row.marker_color_g;
        s.items(.marker_color_b)[index] = row.marker_color_b;
        s.items(.marker_color_a)[index] = row.marker_color_a;
        s.items(.marker_depth_value)[index] = row.marker_depth_value;
        s.items(.marker_length)[index] = row.marker_length;
        s.items(.marker_depth)[index] = row.marker_depth;
        s.items(.marker_margin)[index] = row.marker_margin;
    }

    pub fn get(self: *const PrimitiveVisualStore, index: usize) PrimitiveVisual {
        const s = self.rows.slice();
        return .{
            .size = .{ .x = s.items(.size_x)[index], .y = s.items(.size_y)[index] },
            .color = .{
                .r = s.items(.color_r)[index],
                .g = s.items(.color_g)[index],
                .b = s.items(.color_b)[index],
                .a = s.items(.color_a)[index],
            },
            .depth = @enumFromInt(s.items(.depth_value)[index]),
            .marker_color = .{
                .r = s.items(.marker_color_r)[index],
                .g = s.items(.marker_color_g)[index],
                .b = s.items(.marker_color_b)[index],
                .a = s.items(.marker_color_a)[index],
            },
            .marker_depth_band = @enumFromInt(s.items(.marker_depth_value)[index]),
            .marker_length = s.items(.marker_length)[index],
            .marker_depth = s.items(.marker_depth)[index],
            .marker_margin = s.items(.marker_margin)[index],
        };
    }

    pub fn removeAt(self: *PrimitiveVisualStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const PrimitiveVisualStore) ConstPrimitiveVisualSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .size_x = s.items(.size_x),
            .size_y = s.items(.size_y),
            .color_r = s.items(.color_r),
            .color_g = s.items(.color_g),
            .color_b = s.items(.color_b),
            .color_a = s.items(.color_a),
            .depth_values = s.items(.depth_value),
            .marker_color_r = s.items(.marker_color_r),
            .marker_color_g = s.items(.marker_color_g),
            .marker_color_b = s.items(.marker_color_b),
            .marker_color_a = s.items(.marker_color_a),
            .marker_depth_values = s.items(.marker_depth_value),
            .marker_lengths = s.items(.marker_length),
            .marker_depths = s.items(.marker_depth),
            .marker_margins = s.items(.marker_margin),
        };
    }

    pub fn clearRetainingCapacity(self: *PrimitiveVisualStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *PrimitiveVisualStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *PrimitiveVisualStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *PrimitiveVisualStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, capacity);
    }
};

pub const AssetReferenceStore = struct {
    rows: std.MultiArrayList(AssetReferenceRow) = .{},

    pub fn len(self: *const AssetReferenceStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *AssetReferenceStore, allocator: std.mem.Allocator, entity: EntityId, asset_ref: AssetReference) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyAssetReferenceRows;
        try self.ensureCapacity(allocator, self.rows.len + 1);
        const index: u32 = @intCast(self.rows.len);
        try self.rows.append(allocator, .{
            .entity = entity,
            .sprite = asset_ref.sprite,
            .atlas_entry_id = asset_ref.atlas_entry_id,
        });
        return index;
    }

    pub fn set(self: *AssetReferenceStore, index: usize, asset_ref: AssetReference) void {
        const s = self.rows.slice();
        s.items(.sprite)[index] = asset_ref.sprite;
        s.items(.atlas_entry_id)[index] = asset_ref.atlas_entry_id;
    }

    pub fn get(self: *const AssetReferenceStore, index: usize) AssetReference {
        const s = self.rows.slice();
        return .{
            .sprite = s.items(.sprite)[index],
            .atlas_entry_id = s.items(.atlas_entry_id)[index],
        };
    }

    pub fn removeAt(self: *AssetReferenceStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const AssetReferenceStore) ConstAssetReferenceSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .sprite_ids = s.items(.sprite),
            .atlas_entry_ids = s.items(.atlas_entry_id),
        };
    }

    pub fn clearRetainingCapacity(self: *AssetReferenceStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *AssetReferenceStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    pub fn ensureCapacity(self: *AssetReferenceStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, capacity);
    }
};
