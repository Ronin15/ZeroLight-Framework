// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Build-time nav memory budget gate. Estimates resident nav memory from world
//! dimensions and reserve config and fails loud (NavGridError.NavWorldTooLarge)
//! before a rebuild can allocate past the configured ceiling.

const std = @import("std");
const types = @import("types.zig");
const NavGridError = types.NavGridError;
const StitchedCell = types.StitchedCell;
const OpenNode = types.OpenNode;
const PortalNode = types.PortalNode;
const AbstractEdge = types.AbstractEdge;
const chunk_edge_floor = types.chunk_edge_floor;
const default_edge_slack = types.default_edge_slack;

pub const NavMemoryBudget = struct {
    max_bytes: usize,
    level_count: usize,
    group_field_bytes_per_cell: usize,
    max_group_fields: usize,
    // Capacity terms for the allocations that scale with reserve config rather
    // than cell count.
    max_explored_nodes: usize,
    max_stored_path_cells: usize,
    worker_participant_count: usize,
    max_cached_results: usize,
    max_solved_requests_per_step: usize,
    max_stitched_path_cells: usize,
    // Abstract chunk-portal graph sizing. Per-slot buffers are geometrically sized to the
    // chunk-stable slot space (4*ct slots per chunk plus interior link tails); the edge
    // arena grows to a measured, slack-padded size at the init build. The gate uses a
    // structural estimate so large SPARSE worlds pass while a genuinely oversized world
    // still fails loud.
    chunk_tiles: usize,
    link_count: usize,
    // Realistic upper bound on the abstract degree of a portal node (intra-chunk
    // peers + cross-border + link edges). Used to estimate the CSR edge buffers
    // without the pathological per-chunk pairwise (O(cells)) term.
    const abstract_degree: usize = 8;

    // Per SearchScratch direct per-cell entry: slot_g/slot_parent/slot_stamp
    // (3 x u32) plus slot_closed (bool). The direct array is indexed by cell_index,
    // so there is no separate slot_cell column.
    const scratch_slot_bytes: usize = 3 * @sizeOf(u32) + 1;
    // EdgeScratch (u32 from + AbstractEdge) and the compacted CSR edge entry
    // (AbstractEdge). Both buffers are reserved to the edge worst case.
    const edge_scratch_bytes: usize = @sizeOf(u32) + @sizeOf(AbstractEdge);
    const portal_edge_bytes: usize = @sizeOf(AbstractEdge);
    // PortalNode (u16 level + u32 cell_index + u32 chunk), including alignment padding.
    const portal_node_bytes: usize = @sizeOf(PortalNode);

    // Saturating estimate of total nav memory. An overflowing term clamps to
    // maxInt so the gate rejects rather than wrapping to a small value.
    pub fn requiredBytes(self: NavMemoryBudget, width: usize, height: usize) usize {
        const cell_count = width *| height;
        const levels = @max(@as(usize, 1), self.level_count);
        // Per-level static nav state: components (u32) + the blocked and static-body masks
        // (two byte-per-cell bool columns, NOT a packed bitset) + flood queue, one set of
        // arrays per level. Counting both bool columns on every level slightly over-counts
        // the non-zero levels (static-body coverage is level-0 only), which keeps the gate
        // conservative.
        const per_level_bytes = (cell_count *| @sizeOf(u32)) +| (2 *| cell_count) +| (cell_count *| @sizeOf(usize));
        const static_bytes = per_level_bytes *| levels;
        // Group-field registry: max_group_fields x cells x per-cell field bytes.
        const group_registry_bytes = self.max_group_fields *| cell_count *| self.group_field_bytes_per_cell;
        // Per-participant A* scratch. The direct per-cell state arrays are O(cells); on top
        // of those each participant also reserves the open heap (node budget) and the path
        // reconstruction buffer (node budget vs. stored-path cells), which scale with the
        // reserve config rather than the cell count. Counting both keeps the gate honest
        // about real resident scratch so a large world fails loud here, not at query time.
        const per_participant_scratch_bytes = (cell_count *| scratch_slot_bytes) +|
            (self.max_explored_nodes *| @sizeOf(OpenNode)) +|
            (@max(self.max_explored_nodes, self.max_stored_path_cells) *| @sizeOf(u32));
        const scratch_bytes = self.worker_participant_count *| per_participant_scratch_bytes;
        // Goal-keyed completed-path cache pool.
        const result_path_bytes = self.max_cached_results *| self.max_stored_path_cells *| @sizeOf(u32);
        // Per-request worker path stripes.
        const worker_path_bytes = self.max_solved_requests_per_step *| self.max_stored_path_cells *| @sizeOf(u32);
        // Goal-keyed stitched-corridor cache plus per-request worker stitched stripes
        // (config-scaled, independent of cell count).
        const stitched_bytes = (self.max_cached_results +| self.max_solved_requests_per_step) *|
            self.max_stitched_path_cells *| @sizeOf(StitchedCell);
        // Realistic abstract chunk-portal graph buffers (cell_to_portal is exact;
        // portals/edges are estimated from border structure, not a per-cell worst case).
        const abstract_bytes = self.abstractGraphBytes(width, height, levels);
        return static_bytes +| group_registry_bytes +|
            scratch_bytes +| result_path_bytes +| worker_path_bytes +| stitched_bytes +|
            abstract_bytes;
    }

    // Structural bytes for the abstract-graph buffers under the geometric slot layout. The
    // cell_to_portal lookup is genuinely levels * cell_count every build (O(cells)). The
    // per-slot buffers scale with the geometric slot count (4*ct per chunk plus link tails,
    // ~4*cells/ct) rather than cells, and the edge arena with the slot count times a small
    // abstract degree plus a per-chunk floor, padded by the slack multiplier. This stays
    // well below the pathological per-chunk pairwise term while still failing oversized
    // worlds loud.
    pub fn abstractGraphBytes(self: NavMemoryBudget, width: usize, height: usize, levels: usize) usize {
        const cell_count = width *| height;
        const ct = @max(@as(usize, 1), self.chunk_tiles);
        const cx = (width + ct - 1) / ct;
        const cy = (height + ct - 1) / ct;
        const chunk_count = cx *| cy;
        // Geometric node slots: 4*ct per chunk plus up to two interior tails per link.
        const slots = levels *| (4 *| ct *| chunk_count +| 2 *| self.link_count);
        // Each level owns a cell_count-sized cell_to_portal, summing to levels*cells.
        const cell_to_portal_bytes = levels *| cell_count *| @sizeOf(u32);
        // Per-slot buffers (summed across levels): portals + portal_edge_start +
        // portal_edge_count + portal_order + chunk_label_keys + chunk_label_starts.
        const slot_buffers = slots *| (portal_node_bytes +| 5 *| @sizeOf(u32));
        // Per-chunk lens (chunk_order_len + chunk_label_len) and NavGraph geometry arrays.
        const chunk_aux = levels *| chunk_count *| 2 *| @sizeOf(u32) +|
            chunk_count *| 8 *| @sizeOf(u32);
        // Edge arena: slots * abstract degree plus a per-chunk floor, padded by slack; plus
        // the per-level edge_scratch staging buffer sized to the level's edge count.
        const edge_slot_count = (slots *| abstract_degree +| levels *| chunk_count *| @as(usize, chunk_edge_floor)) *| @as(usize, default_edge_slack);
        const edge_buffers = edge_slot_count *| portal_edge_bytes +|
            slots *| abstract_degree *| edge_scratch_bytes;
        return cell_to_portal_bytes +| slot_buffers +| chunk_aux +| edge_buffers;
    }

    // Pure validation helper: returns the error and stays log-free. A lifecycle
    // diagnostic for an oversized world belongs at the app-layer caller that
    // handles the error, not in this helper.
    pub fn check(self: NavMemoryBudget, width: usize, height: usize) NavGridError!void {
        if (self.requiredBytes(width, height) > self.max_bytes) return NavGridError.NavWorldTooLarge;
    }
};

// group field per-cell: cost(u32) + flow(u8) + stamp(u32) + the Dial's
// bucket-queue links bucket_next/bucket_prev(u32) + queued_stamp(u32).
pub const default_group_field_bytes_per_cell: usize = @sizeOf(u32) + 1 + 4 * @sizeOf(u32);

// Auto-sizes max_nav_memory_bytes to the next power of two above the required
// bytes for the given capacity/world dimensions, so callers get a working
// ceiling without hand-tuning it.
pub fn autoSizedMaxNavMemoryBytes(capacity: types.PathfindingCapacity, level_count: usize, width: usize, height: usize) usize {
    const budget = NavMemoryBudget{
        .max_bytes = std.math.maxInt(usize),
        .level_count = level_count,
        .group_field_bytes_per_cell = default_group_field_bytes_per_cell,
        .max_group_fields = capacity.max_group_fields,
        .max_explored_nodes = capacity.max_explored_nodes,
        .max_stored_path_cells = capacity.max_stored_path_cells,
        .worker_participant_count = @max(@as(usize, 1), capacity.worker_participant_count),
        .max_cached_results = capacity.max_cached_results,
        .max_solved_requests_per_step = capacity.max_solved_requests_per_step,
        .max_stitched_path_cells = capacity.max_stitched_path_cells,
        .chunk_tiles = capacity.nav_chunk_tiles,
        .link_count = 0,
    };
    const required = budget.requiredBytes(width, height);
    return std.math.ceilPowerOfTwo(usize, required) catch required;
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const DataSystem = @import("../../data_system.zig").DataSystem;
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const test_support = @import("test_support.zig");
const addNavBody = test_support.addNavBody;
const baselineCapacity = test_support.baselineCapacity;

test "pathfinding rebuild fails loud on oversized nav world" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    _ = try addNavBody(&data, .{ .x = 0, .y = 0 }, .{ .x = 8, .y = 8 }, false);

    var system = PathfindingSystem.init(std.testing.allocator);
    defer system.deinit();
    var capacity = baselineCapacity();
    capacity.max_nav_memory_bytes = 1024;
    try system.reserve(capacity);
    // 512x512 cells far exceed a 1 KiB nav-memory ceiling.
    try std.testing.expectError(NavGridError.NavWorldTooLarge, system.rebuildStaticNavGrid(&data, 512, 512, 32));
}

fn testBudget(max_bytes: usize) NavMemoryBudget {
    return .{
        .max_bytes = max_bytes,
        .level_count = 1,
        .group_field_bytes_per_cell = default_group_field_bytes_per_cell,
        .max_group_fields = 8,
        .max_explored_nodes = 4096,
        .max_stored_path_cells = 256,
        .worker_participant_count = 1,
        .max_cached_results = 256,
        .max_solved_requests_per_step = 512,
        .max_stitched_path_cells = 256,
        .chunk_tiles = 16,
        .link_count = 0,
    };
}

test "nav memory budget saturates on overflowing dimensions instead of wrapping" {
    // width * height overflows usize. Saturating arithmetic clamps requiredBytes to maxInt so
    // check rejects; a wrapping (* instead of *|) regression would fold the cell term to a small
    // value (e.g. (1<<33)*(1<<33) wraps to 4) and could slip under the ceiling. A 1 GiB ceiling
    // makes the contrast stark: only a saturated estimate exceeds it.
    const budget = testBudget(1 << 30);
    const huge: usize = 1 << 33;
    try std.testing.expect(budget.requiredBytes(huge, huge) == std.math.maxInt(usize));
    try std.testing.expectError(NavGridError.NavWorldTooLarge, budget.check(huge, huge));
}

test "nav memory budget passes a large but sparse world" {
    // A real 1024x1024 single-level world fits comfortably under a 1 GiB ceiling, so the gate is
    // not merely always-failing — it admits large sparse worlds while rejecting overflowed ones.
    const budget = testBudget(1 << 30);
    try budget.check(1024, 1024);
}
