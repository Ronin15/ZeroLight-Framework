// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Static collider reads for tests and benches. Test-only: no production path imports it.

/// Live rows of a `StaticColliderSystem` (or a pointer to one): its rows less freed ones.
pub fn liveRowCount(colliders: anytype) usize {
    return colliders.rows.len - colliders.row_free.items.len;
}
