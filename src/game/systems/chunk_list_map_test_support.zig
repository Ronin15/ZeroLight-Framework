// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Directory, registration-payload, and inverse-pool byte counts for tests and benches,
//! built from the structures' layouts. Test-only: no production path imports it.

const std = @import("std");
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const RegChunk = @import("pathfinding/publish.zig").RegChunk;
const InversePool = @import("pathfinding/publish.zig").InversePool;
const RegistryDirectory = @import("pathfinding/publish.zig").RegistryDirectory;

/// The element type of `T.field`: a std list's, a `MultiArrayList`'s row, or a slice's.
pub fn FieldElem(comptime T: type, comptime field: []const u8) type {
    const List = @FieldType(T, field);
    if (@typeInfo(List) == .pointer) return @typeInfo(List).pointer.child;
    if (@hasField(List, "items")) return @typeInfo(@FieldType(List, "items")).pointer.child;
    return @typeInfo(@TypeOf(List.get)).@"fn".return_type.?;
}

const padded_slot_bytes = @sizeOf(PaddedSlot(struct { block: u32 = 0, pending: u32 = 0 }));
const reg_stride = 3 * @sizeOf(u32);

/// Bytes of one level directory: its slot array, the block pool, and each block's payload.
pub fn directoryResidentBytes(directory: *const RegistryDirectory) usize {
    var bytes: usize = directoryLevelBytes(directory.levelCount());
    var level: u32 = 0;
    while (level < directory.levelCount()) : (level += 1) {
        bytes += directory.slotCount(level) * padded_slot_bytes;
        var slot: usize = 0;
        while (slot < directory.slotCount(level)) : (slot += 1) {
            const block = directory.slot(level, slot);
            if (block == std.math.maxInt(u32)) continue;
            bytes += directory.blockBytes(block).len;
        }
    }
    return bytes;
}

fn directoryLevelBytes(levels: usize) usize {
    // The level list and the block pool, each grown by std past the live count. One block
    // header per occupied slot is charged by the caller through the payload bytes; the pool's
    // id storage is one u32 per block plus the block record.
    return std.ArrayList(usize).growCapacity(levels) * @sizeOf(usize);
}

/// Bytes of one inverse pool: its node columns, free ids, and owner heads, including a
/// prepared or retired truncation.
pub fn inversePoolResidentBytes(pool: *const InversePool) usize {
    var bytes = std.MultiArrayList(InverseNode).capacityInBytes(pool.nodes.capacity) +
        pool.node_free.capacity * @sizeOf(u32) +
        pool.owner_heads.capacity * @sizeOf(OwnerHead) +
        pool.retired.capacity * @sizeOf(OwnerHead);
    if (pool.replacement) |replacement| bytes += replacement.capacity * @sizeOf(OwnerHead);
    return bytes;
}

const InverseNode = struct {
    next: u32 = 0,
    chunk: u64 = 0,
    index: u32 = 0,
};
const OwnerHead = struct {
    node: u32 = 0,
    len: u32 = 0,
};

/// An over-estimate of one registry: `chunks` padded directory slots, a geometric payload
/// for `entries` registrations, and `shards` inverse pools whose nodes sum to `entries`
/// and whose owner heads hold `owners` ids. Saturates.
pub fn pooledStorageBytesBound(shards: usize, chunks: usize, entries: usize, owners: usize) usize {
    const Nodes = std.MultiArrayList(InverseNode);
    const Ids = std.ArrayList(u32);
    const Heads = std.ArrayList(OwnerHead);
    const payload = (entries *| 2) *| reg_stride;
    const slots = chunks *| padded_slot_bytes;
    const node_pool = Nodes.capacityInBytes(Nodes.growCapacity(entries *| 2)) +| shards *| Nodes.capacityInBytes(Nodes.growCapacity(0));
    const free_ids = Ids.growCapacity(entries *| 2) *| @sizeOf(u32) +| shards *| Ids.growCapacity(0) *| @sizeOf(u32);
    const heads = shards *| Heads.growCapacity(owners) *| @sizeOf(OwnerHead);
    // Count windows: one aligned record per registration, growth and compact.
    const windows = 2 *| std.mem.alignForward(usize, entries, thread_shared_record_alignment / 8) *| 8;
    // Retire plan, once: two ids per op and one chain start per op, two ops per owner,
    // and one head per owner the log can name.
    const plan = Ids.growCapacity(owners *| 4) *| @sizeOf(u32) +| Ids.growCapacity(shards *| owners *| 2) *| @sizeOf(u32) +| Heads.growCapacity(owners) *| @sizeOf(OwnerHead);
    return slots +| payload +| node_pool +| free_ids +| heads +| windows +| plan +| directoryLevelBytes(chunks);
}

comptime {
    std.debug.assert(@sizeOf(InverseNode) == 24 or @sizeOf(InverseNode) == 16);
    _ = RegChunk;
}
