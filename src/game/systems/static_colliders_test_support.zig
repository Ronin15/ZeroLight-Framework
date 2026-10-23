// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Static collider reads for tests and benches. Test-only: no production path imports it.

const std = @import("std");
const offMainNs = @import("../../app/thread_system.zig").offMainNs;
const ColliderStage = @import("static_colliders.zig").ColliderStage;

/// Live rows of a `StaticColliderSystem` (or a pointer to one): its rows less freed ones.
pub fn liveRowCount(colliders: anytype) usize {
    return colliders.rows.len - colliders.row_free.items.len;
}

/// The last `rebuild` or `sync`'s worker dispatch time over every stage (`offMainNs` of each
/// `Perf.last_batches` entry): its elapsed time less this is its main-thread time.
pub fn lastOffMainNs(colliders: anytype) u64 {
    var total: u64 = 0;
    for (std.meta.tags(ColliderStage)) |stage| total += offMainNs(colliders.perf.last_batches.get(stage));
    return total;
}

/// The `ColliderStage` a rebuild or sync stage (`RebuildStage`, `SyncStage`) records its
/// `Perf.last_batches` entry under: the stage of the same name.
pub fn colliderStage(stage: anytype) ColliderStage {
    return switch (stage) {
        inline else => |tag| @field(ColliderStage, @tagName(tag)),
    };
}
