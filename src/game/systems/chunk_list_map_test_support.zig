// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! `ChunkListMap` byte counts and bounds for tests and benches, built from the
//! structure's layout. Test-only: no production path imports it.

const std = @import("std");
const chunk_list_map = @import("chunk_list_map.zig");
const ChunkListMap = chunk_list_map.ChunkListMap;

/// The element type of `T.field`: a std list's, a `MultiArrayList`'s row, or a slice's.
pub fn FieldElem(comptime T: type, comptime field: []const u8) type {
    const List = @FieldType(T, field);
    if (@typeInfo(List) == .pointer) return @typeInfo(List).pointer.child;
    if (@hasField(List, "items")) return @typeInfo(@FieldType(List, "items")).pointer.child;
    return @typeInfo(@TypeOf(List.get)).@"fn".return_type.?;
}

// Bytes one table slot takes: an element of each `slot_*` column.
const bytes_per_key_slot: usize = blk: {
    var bytes: usize = 0;
    for (@typeInfo(ChunkListMap).@"struct".field_names) |name| {
        if (std.mem.startsWith(u8, name, "slot_")) bytes += @sizeOf(FieldElem(ChunkListMap, name));
    }
    break :blk bytes;
};

/// Bytes `map`'s table, entry pool, free ids, owner heads, and batch scratch hold
/// (allocated capacity).
pub fn residentBytes(map: *const ChunkListMap) usize {
    var bytes = map.slot_keys.len * bytes_per_key_slot + std.MultiArrayList(chunk_list_map.Entry).capacityInBytes(map.entries.capacity) +
        map.entry_free.capacity * @sizeOf(u32) + map.owner_heads.capacity * @sizeOf(u32) + map.retired_owner_heads.capacity * @sizeOf(u32) +
        map.claims.capacity * @sizeOf(FieldElem(ChunkListMap, "claims")) + map.touched.capacity * @sizeOf(FieldElem(ChunkListMap, "touched")) +
        map.splice_records.capacity * @sizeOf(FieldElem(ChunkListMap, "splice_records")) + map.emptied_keys.capacity * @sizeOf(u64);
    if (map.owner_heads_replacement) |replacement| bytes += replacement.capacity * @sizeOf(u32);
    return bytes;
}

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
    return slots *| bytes_per_key_slot +| Entries.capacityInBytes(pool) +| free_ids *| @sizeOf(u32) +|
        maps *| Ids.growCapacity(owners) *| @sizeOf(u32);
}
