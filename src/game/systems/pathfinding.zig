// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Frame-delayed, Z-aware grid pathfinding with two coordinated solver modes per
//! request kind:
//!   * individual: goal-keyed budget-bounded local A*; long-range/cross-level queries
//!     route through an abstract chunk-portal + link graph and stitch a full
//!     obstacle-aware (level,cell) path the per-agent query walks cell by cell.
//!   * group: demand-driven reverse-Dijkstra flow field toward a shared declared goal,
//!     lazily built and budgeted across frames (zero cost when unused).
//! Owns transient request queues, result caches, per-level nav-grid state, the
//! abstract chunk-portal/link graph, and per-worker scratch. The fixed-step update is
//! allocation-free after reserve/rebuild.
//!
//! This file is a thin facade over the `pathfinding/` package: it re-exports the
//! public surface so external importers keep resolving unchanged, while the
//! implementation lives in the package modules.

pub const PathfindingSystem = @import("pathfinding/system.zig").PathfindingSystem;
pub const PathfindingCapacity = @import("pathfinding/types.zig").PathfindingCapacity;
pub const PathfindingStats = @import("pathfinding/types.zig").PathfindingStats;
pub const PathView = @import("pathfinding/types.zig").PathView;
pub const PathStatus = @import("pathfinding/types.zig").PathStatus;
pub const NavCellEdit = @import("pathfinding/types.zig").NavCellEdit;
pub const NavUpdateStats = @import("pathfinding/types.zig").NavUpdateStats;
pub const PathfindingConfig = @import("pathfinding/types.zig").PathfindingConfig;
pub const NavGridError = @import("pathfinding/types.zig").NavGridError;
pub const pathfinding_range_alignment_items = @import("pathfinding/types.zig").pathfinding_range_alignment_items;
pub const default_max_fallback_requests_per_step = @import("pathfinding/types.zig").default_max_fallback_requests_per_step;
pub const default_max_solves_per_frame = @import("pathfinding/types.zig").default_max_solves_per_frame;
pub const default_nav_chunk_tiles = @import("pathfinding/types.zig").default_nav_chunk_tiles;
pub const autoSizedMaxNavMemoryBytes = @import("pathfinding/nav_memory.zig").autoSizedMaxNavMemoryBytes;

test {
    _ = @import("pathfinding/types.zig");
    _ = @import("pathfinding/nav_memory.zig");
    _ = @import("pathfinding/nav_grid.zig");
    _ = @import("pathfinding/scratch.zig");
    _ = @import("pathfinding/group_field.zig");
    _ = @import("pathfinding/nav_graph.zig");
    _ = @import("pathfinding/caches.zig");
    _ = @import("pathfinding/solve.zig");
    _ = @import("pathfinding/system.zig");
    _ = @import("pathfinding/test_support.zig");
}
