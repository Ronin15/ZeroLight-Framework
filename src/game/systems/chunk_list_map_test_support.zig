// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `ChunkListMap` byte bounds for tests and benches. Test-only: no production path imports it.

const std = @import("std");
const chunk_list_map = @import("chunk_list_map.zig");
const ChunkListMap = chunk_list_map.ChunkListMap;

/// An over-estimate of `residentBytes` summed over `maps` maps grown through `reserve`
/// alone (no batch scratch, no owner-head truncate pending), each reserved for owner ids
/// below `owners`, whose own peak reserves, summed over the maps, never pass `keys` keys
/// and `entries` entries. A map's slots hold its keys at load 1/2 or more, so under four
/// slots per key; its entry pool grows to at least double past its need, and std's
/// growth past that. Saturates.
pub fn pooledStorageBytesBound(maps: usize, keys: usize, entries: usize, owners: usize) usize {
    const Entries = std.MultiArrayList(chunk_list_map.Entry);
    const Ids = std.ArrayList(u32);
    const slots = maps *| chunk_list_map.min_slot_count +| 4 *| keys;
    const pool = Entries.growCapacity(2 *| entries) +| maps *| Entries.growCapacity(0);
    const free_ids = Ids.growCapacity(pool) +| maps *| Ids.growCapacity(0);
    return slots *| ChunkListMap.bytes_per_key_slot +| Entries.capacityInBytes(pool) +| free_ids *| @sizeOf(u32) +|
        maps *| Ids.growCapacity(owners) *| @sizeOf(u32);
}
