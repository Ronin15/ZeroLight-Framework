// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private test fixtures for collision-response consumers across modules.
//! Test-only: no production path imports it.

const EntityId = @import("../data_system.zig").EntityId;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const contact_query = @import("../contact_query.zig");

/// Writes the indices of `frame`'s contacts naming `entity` into `buffer`, in contact
/// order, as the collision response lists its observer contacts, and returns them.
/// `buffer` holds every such contact.
pub fn contactsNaming(frame: *const SimulationFrame, entity: EntityId, buffer: []u32) []const u32 {
    var count: usize = 0;
    for (frame.contacts.mergedItems(), 0..) |contact, index| {
        if (!contact_query.involvesEntity(contact, entity)) continue;
        // Test frames hold far fewer than 2^32 contacts.
        buffer[count] = @intCast(index);
        count += 1;
    }
    return buffer[0..count];
}
