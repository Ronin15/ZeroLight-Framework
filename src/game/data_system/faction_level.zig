// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Faction and world-level component storage: dense faction-tag rows and
//! dense per-entity world/level index rows. Named faction_level (not
//! faction.zig) to avoid colliding with the existing top-level
//! src/game/faction.zig, which owns the Faction enum itself.

const std = @import("std");
const types = @import("types.zig");
const EntityId = types.EntityId;
const Faction = @import("../faction.zig").Faction;
const ConstFactionSlice = types.ConstFactionSlice;
const ConstWorldLevelSlice = types.ConstWorldLevelSlice;

const FactionRow = struct {
    entity: EntityId,
    faction: Faction,
};

const WorldLevelRow = struct {
    entity: EntityId,
    level: u16,
};

pub const FactionStore = struct {
    rows: std.MultiArrayList(FactionRow) = .{},

    pub fn len(self: *const FactionStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *FactionStore, allocator: std.mem.Allocator, entity: EntityId, entity_faction: Faction) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyFactionRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .faction = entity_faction,
        });
        return index;
    }

    pub fn setFaction(self: *FactionStore, index: usize, entity_faction: Faction) void {
        self.rows.slice().items(.faction)[index] = entity_faction;
    }

    pub fn factionPtr(self: *FactionStore, index: usize) *Faction {
        return &self.rows.slice().items(.faction)[index];
    }

    pub fn factionAt(self: *const FactionStore, index: usize) Faction {
        return self.rows.slice().items(.faction)[index];
    }

    pub fn removeAt(self: *FactionStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const FactionStore) ConstFactionSlice {
        const s = self.rows.slice();
        return .{ .entities = s.items(.entity), .factions = s.items(.faction) };
    }

    pub fn clearRetainingCapacity(self: *FactionStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *FactionStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    pub fn ensureCapacity(self: *FactionStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, capacity);
    }

    fn ensureCapacityForOne(self: *FactionStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }
};

pub const WorldLevelStore = struct {
    rows: std.MultiArrayList(WorldLevelRow) = .{},

    pub fn len(self: *const WorldLevelStore) usize {
        return self.rows.len;
    }

    pub fn append(self: *WorldLevelStore, allocator: std.mem.Allocator, entity: EntityId, level: u16) !u32 {
        if (self.rows.len >= std.math.maxInt(u32)) return error.TooManyWorldLevelRows;
        try self.ensureCapacityForOne(allocator);
        const index: u32 = @intCast(self.rows.len);
        self.rows.appendAssumeCapacity(.{
            .entity = entity,
            .level = level,
        });
        return index;
    }

    pub fn set(self: *WorldLevelStore, index: usize, level: u16) void {
        self.rows.slice().items(.level)[index] = level;
    }

    pub fn get(self: *const WorldLevelStore, index: usize) u16 {
        return self.rows.slice().items(.level)[index];
    }

    pub fn levelPtr(self: *WorldLevelStore, index: usize) *u16 {
        return &self.rows.slice().items(.level)[index];
    }

    pub fn removeAt(self: *WorldLevelStore, index: usize) ?EntityId {
        const s = self.rows.slice();
        const last = self.rows.len - 1;
        const moved_entity = if (index != last) s.items(.entity)[last] else null;
        self.rows.swapRemove(index);
        return moved_entity;
    }

    pub fn sliceConst(self: *const WorldLevelStore) ConstWorldLevelSlice {
        const s = self.rows.slice();
        return .{
            .entities = s.items(.entity),
            .levels = s.items(.level),
        };
    }

    pub fn clearRetainingCapacity(self: *WorldLevelStore) void {
        self.rows.clearRetainingCapacity();
    }

    pub fn deinit(self: *WorldLevelStore, allocator: std.mem.Allocator) void {
        self.rows.deinit(allocator);
        self.* = .{};
    }

    fn ensureCapacityForOne(self: *WorldLevelStore, allocator: std.mem.Allocator) !void {
        try self.ensureCapacity(allocator, self.rows.len + 1);
    }

    pub fn ensureCapacity(self: *WorldLevelStore, allocator: std.mem.Allocator, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(allocator, capacity);
    }
};
