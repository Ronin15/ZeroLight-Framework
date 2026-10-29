// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Collision system reads for tests. Test-only: no production path imports it.

const CollisionSystem = @import("collision.zig").CollisionSystem;

/// The capacity of every list `CollisionSystem` holds directly, in field order: the stores
/// `reserve` sizes for every partition. The range slot sets hold theirs behind `list`.
pub fn storeCapacities(system: *const CollisionSystem) [store_count]usize {
    var capacities: [store_count]usize = undefined;
    var index: usize = 0;
    inline for (@typeInfo(CollisionSystem).@"struct".field_names) |name| {
        if (comptime isStoreList(@FieldType(CollisionSystem, name))) {
            capacities[index] = @field(system, name).capacity;
            index += 1;
        }
    }
    return capacities;
}

const store_count = count: {
    var count: usize = 0;
    for (@typeInfo(CollisionSystem).@"struct".field_names) |name| count += @intFromBool(isStoreList(@FieldType(CollisionSystem, name)));
    break :count count;
};

fn isStoreList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasField(T, "capacity");
}
