// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private test fixtures for the pathfinding package. These are test-only
//! helpers (no production contract exposes them); each test-bearing module imports
//! what it needs. Single-module helpers are co-located in their module instead.

const std = @import("std");
const math = @import("../../../core/math.zig");
const DataSystem = @import("../../data_system.zig").DataSystem;
const EntityId = @import("../../data_system.zig").EntityId;
const RangeOutputStream = @import("../../simulation.zig").RangeOutputStream;
const PathRequest = @import("../../simulation.zig").PathRequest;
const PathfindingCapacity = @import("types.zig").PathfindingCapacity;
const assets = @import("../../../assets/assets.zig");
const manifest = @import("../../../assets/manifest.zig");
const world_tileset_meta = @import("../../../assets/world_tileset_meta.zig");
const WorldTilesetMeta = world_tileset_meta.WorldTilesetMeta;
const TileId = @import("../../world_system.zig").TileId;
const WorldSystem = @import("../../world_system.zig").WorldSystem;
const demoWorldWithChunkSize = @import("../../world_test_support.zig").demoWorldWithChunkSize;
const StaticColliderSystem = @import("../static_colliders.zig").StaticColliderSystem;
const NavExtent = @import("nav_graph.zig").NavExtent;
const NavGrid = @import("nav_grid.zig").NavGrid;
const ChunkBits = @import("../../world_terrain.zig").ChunkBits;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const SimulationEvent = @import("../../simulation.zig").SimulationEvent;
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const NavGraph = @import("nav_graph.zig").NavGraph;
const ChunkPortals = @import("nav_graph.zig").ChunkPortals;
const no_node = @import("connectivity.zig").no_node;
const no_comp = @import("connectivity.zig").no_comp;
const StructuralCommand = @import("../../data_system.zig").StructuralCommand;

pub fn addNavBody(data: *DataSystem, position: math.Vec2, size: math.Vec2, static: bool) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = position, .previous_position = position });
    try data.setCollisionBounds(entity, .{ .size = size });
    try data.setCollisionResponse(entity, .{ .mobility = if (static) .static else .dynamic });
    return entity;
}

pub fn appendPathRequest(stream: *RangeOutputStream(PathRequest), request: PathRequest) !void {
    const range_base = try stream.appendRangeCounts(1);
    stream.addCount(range_base, 1);
    try stream.prefixAppendedRanges(range_base);
    var writer = stream.rangeWriter(range_base);
    writer.write(request);
    writer.finish();
    stream.finishWrite();
}

// Field cell cap for the small test worlds; keeps each field's table small.
const test_group_field_max_cells: usize = 4096;

pub fn baselineCapacity() PathfindingCapacity {
    // Per-step request/cache caps are derived elastically from the agent count
    // (floored at min_capacity_floor = 8), so only the non-derived knobs are set
    // here. An explicit min_group_field_agents pins the group-field threshold so
    // these tests exercise the field mechanics with a handful of agents instead of the
    // fixed default threshold (which would otherwise require hundreds of sharers).
    return .{
        .max_group_fields = 2,
        .worker_participant_count = 1,
        .min_group_field_agents = 1,
        .group_field_max_cells = test_group_field_max_cells,
    };
}

// Loads the world tileset metadata used by the demo. Cross-level/abstract tests
// build real `WorldSystem` worlds from it (no test-only production hooks).
pub fn loadTestWorldMeta(allocator: std.mem.Allocator) !WorldTilesetMeta {
    const asset_store = assets.AssetStore.init(allocator, std.testing.io, "assets");
    return world_tileset_meta.load(
        allocator,
        asset_store,
        manifest.spriteSpec(.world_tileset).metadata_path.?,
    );
}

pub fn requireTestTile(meta: *const WorldTilesetMeta, name: []const u8) !TileId {
    return (meta.tileByName(name) orelse return error.UnknownTestTile).id;
}

// Capacity tuned for the abstract tier: small chunks so a modest world spans
// several chunks (real portals), plus headroom for cross-level corridor storage.
pub fn abstractCapacity() PathfindingCapacity {
    return .{
        .max_frame_requests = 8,
        .max_pending_requests = 8,
        .max_cached_results = 16,
        .max_group_fields = 2,
        .worker_participant_count = 1,
        .max_solved_requests_per_step = 8,
        .max_fallback_requests_per_step = 8,
        .nav_chunk_tiles = 4,
        .max_stitched_path_cells = 256,
        .min_group_field_agents = 1,
        .group_field_max_cells = test_group_field_max_cells,
    };
}

// Demo-painted world whose chunk edge is `abstractCapacity`'s nav chunk, so a world-backed
// abstract test and a world-less one share the same small multi-chunk geometry.
pub fn abstractTestWorld(meta: *const WorldTilesetMeta, bounds_width: f32, bounds_height: f32) !WorldSystem {
    return demoWorldWithChunkSize(std.testing.allocator, meta, bounds_width, bounds_height, abstractCapacity().nav_chunk_tiles);
}

/// No static colliders: for applies on a nav whose levels hold no static body.
pub const no_colliders = StaticColliderSystem.init(std.testing.failing_allocator);

/// Static colliders built from `data` on `world`'s cell grid.
pub fn worldColliders(data: *const DataSystem, world: *const WorldSystem) !StaticColliderSystem {
    var colliders = StaticColliderSystem.init(std.testing.allocator);
    errdefer colliders.deinit();
    try colliders.rebuild(data, try (NavExtent{ .world = world }).colliderGeometry());
    return colliders;
}

/// The commit seam for statics: reserves the colliders and `system`'s static marks,
/// commits `commands`, captures and syncs the colliders, then records the sync's changes in
/// `system` for the nav reaction.
pub fn commitWithColliders(frame: *SimulationFrame, data: *DataSystem, colliders: *StaticColliderSystem, system: *PathfindingSystem, commands: []const StructuralCommand) !void {
    frame.beginStep();
    try colliders.reserveForCommit(data, commands.len);
    try system.reserveStaticColliderMarks(colliders.pendingChangeCount() + commands.len);
    try frame.structural_commands.prepareRangeCounts(1);
    frame.structural_commands.addCount(0, commands.len);
    try frame.structural_commands.prefix();
    var writer = frame.structural_commands.rangeWriter(0);
    for (commands) |command| writer.write(command);
    writer.finish();
    frame.structural_commands.finishWrite();
    _ = try frame.applyStructuralCommands(data);
    colliders.capture(frame);
    try colliders.sync(data, null);
    system.recordStaticColliderChanges(colliders.changesThisStep());
}

/// A terrain writer's nav record over `events` (terrain events only): its reserve, then the
/// serial record.
pub fn recordTerrainEvents(system: *PathfindingSystem, events: []const SimulationEvent, world: *const WorldSystem) !void {
    try system.reserveTerrainNavRecord(events.len);
    system.recordTerrainNavEvents(events, world, null);
}

/// Sets `cells` ((x, y) pairs) of an all-open prepared `grid` blocked, through the same
/// chunk writes a remask makes.
pub fn setBlockedCells(allocator: std.mem.Allocator, grid: *NavGrid, cells: []const [2]usize) !void {
    var pool_grows: u64 = 0;
    for (0..grid.dir.items.len) |chunk_index| {
        const chunk: u32 = @intCast(chunk_index);
        const bounds = grid.chunkBounds(chunk);
        var bits: ChunkBits = @splat(0);
        for (cells) |cell| {
            if (cell[0] < bounds.x0 or cell[0] >= bounds.x1 or cell[1] < bounds.y0 or cell[1] >= bounds.y1) continue;
            const local = (cell[1] - bounds.y0) * grid.chunk_tiles + (cell[0] - bounds.x0);
            bits[local / 64] |= @as(u64, 1) << @intCast(local % 64);
        }
        try grid.ensureFreeBlocks(allocator, 1, &pool_grows);
        const slot = grid.claimBlock();
        grid.blocked_count += grid.writeChunk(chunk, slot, bits);
        if (grid.chunkBlock(chunk) != slot) grid.releaseBlock(slot);
    }
}

// Connectivity checks: node keys (level, chunk, label) and a reference union over the records.

const ConnLabels = [4]u64;

fn connLabelAdd(set: *ConnLabels, label: u8) void {
    set[label >> 6] |= @as(u64, 1) << @intCast(label & 63);
}

fn connLabelHas(set: *const ConnLabels, label: u8) bool {
    return (set[label >> 6] >> @intCast(label & 63)) & 1 != 0;
}

// One flat index per pooled node row of every level.
const ConnNodeIndex = struct {
    bases: std.ArrayList(usize) = .empty,
    total: usize = 0,

    fn init(graph: *const NavGraph) !ConnNodeIndex {
        var index = ConnNodeIndex{};
        errdefer index.bases.deinit(std.testing.allocator);
        for (graph.level_graphs.items) |*level_graph| {
            try index.bases.append(std.testing.allocator, index.total);
            index.total += level_graph.nodes.len;
        }
        return index;
    }

    fn deinit(self: *ConnNodeIndex) void {
        self.bases.deinit(std.testing.allocator);
    }

    fn of(self: *const ConnNodeIndex, level: u16, row: u32) u32 {
        return @intCast(self.bases.items[level] + row);
    }
};

fn connFind(parents: []u32, index: u32) u32 {
    var current = index;
    while (parents[current] != current) {
        parents[current] = parents[parents[current]];
        current = parents[current];
    }
    return current;
}

fn connUnite(parents: []u32, a: u32, b: u32) void {
    const root_a = connFind(parents, a);
    const root_b = connFind(parents, b);
    if (root_a != root_b) parents[@max(root_a, root_b)] = @min(root_a, root_b);
}

fn connListsLink(portals: ChunkPortals, local: u8, link: u32) bool {
    for (portals.linksAt(local)) |entry| {
        if (entry.link == link) return true;
    }
    return false;
}

// The node row at `cell` of `level`, which must be a node.
fn connNodeAt(graph: *const NavGraph, level: u16, cell: usize) u32 {
    const grid = graph.grid(level).?;
    const row = graph.levelGraph(level).?.nodeOf(grid.chunkOfCell(cell), grid.labelAt(cell));
    std.debug.assert(row != no_node);
    return row;
}

// Unites node (`level`, `row`) of `chunk` with every node a record says it reaches: the mirror
// cell across each border flag of its label's portals, and the far end of each link its record
// lists whose far cell is open on a built level and whose far record lists the link back.
fn connUniteRecordEdges(graph: *const NavGraph, index: *const ConnNodeIndex, parents: []u32, level: u16, chunk: u32, row: u32) void {
    const grid = graph.grid(level).?;
    const label = graph.levelGraph(level).?.node_label[row];
    const portals = graph.chunkPortals(level, chunk);
    const bounds = grid.chunkBounds(chunk);
    const mask: usize = grid.chunk_tiles - 1;
    const from = index.of(level, row);
    for (portals.border) |portal| {
        if (portal.label != label) continue;
        const x = bounds.x0 + (portal.local & mask);
        const y = bounds.y0 + (@as(usize, portal.local) >> grid.chunk_shift);
        const mirrors = [_]struct { on: bool, cell: usize }{
            .{ .on = portal.flags.west, .cell = y * grid.width + x -% 1 },
            .{ .on = portal.flags.east, .cell = y * grid.width + x + 1 },
            .{ .on = portal.flags.north, .cell = (y -% 1) *% grid.width +% x },
            .{ .on = portal.flags.south, .cell = (y + 1) * grid.width + x },
        };
        for (mirrors) |mirror| {
            if (mirror.on) connUnite(parents, from, index.of(level, connNodeAt(graph, level, mirror.cell)));
        }
    }
    for (portals.links) |link| {
        if (grid.labelAtLocal(chunk, link.local) != label) continue;
        const target = graph.grid(link.to_level) orelse continue;
        if (target.isBlockedIndex(link.to_cell)) continue;
        const target_chunk = target.chunkOfCell(link.to_cell);
        const x = link.to_cell % target.width;
        const y = link.to_cell / target.width;
        const local: u8 = @intCast(((y & mask) << target.chunk_shift) | (x & mask));
        if (!connListsLink(graph.chunkPortals(link.to_level, target_chunk), local, link.link)) continue;
        connUnite(parents, from, index.of(link.to_level, connNodeAt(graph, link.to_level, link.to_cell)));
    }
}

/// Asserts `graph`'s connectivity invariants: every record lists exactly one live node per
/// portal-bearing label (its label count matching) and every live node is listed once; every
/// comp's size counts its nodes and every root's members count its comps, none live and
/// empty, no comp left in a flood set; and two nodes share a root exactly when a union over
/// the records' mirrors and two-way links joins them.
pub fn expectConnectivityConsistent(graph: *const NavGraph) !void {
    const t = std.testing;
    const allocator = t.allocator;
    const conn = &graph.connectivity;
    var index = try ConnNodeIndex.init(graph);
    defer index.deinit();
    const listed = try allocator.alloc(bool, index.total);
    defer allocator.free(listed);
    @memset(listed, false);
    const comp_sizes = try allocator.alloc(u32, conn.comps.len);
    defer allocator.free(comp_sizes);
    @memset(comp_sizes, 0);
    for (graph.level_graphs.items, 0..) |*level_graph, level_usize| {
        const level: u16 = @intCast(level_usize);
        for (0..level_graph.record_dir.items.len) |chunk_usize| {
            const chunk: u32 = @intCast(chunk_usize);
            var labels: ConnLabels = @splat(0);
            const portals = level_graph.chunkPortals(chunk);
            for (portals.border) |portal| connLabelAdd(&labels, portal.label);
            for (portals.extra) |portal| connLabelAdd(&labels, portal.label);
            const record = level_graph.recordOf(chunk) orelse {
                try t.expect(std.mem.allEqual(u64, &labels, 0));
                continue;
            };
            var label_count: usize = 0;
            for (labels) |word| label_count += @popCount(word);
            try t.expectEqual(label_count, @as(usize, level_graph.record_label_count[record]));
            var seen: ConnLabels = @splat(0);
            var row = level_graph.record_node_head[record];
            while (row != no_node) : (row = level_graph.node_sibling[row]) {
                const label = level_graph.node_label[row];
                try t.expect(connLabelHas(&labels, label) and !connLabelHas(&seen, label));
                connLabelAdd(&seen, label);
                try t.expect(!listed[index.of(level, row)]);
                listed[index.of(level, row)] = true;
                const comp = level_graph.node_comp[row];
                try t.expect(comp < conn.comps.len);
                comp_sizes[comp] += 1;
            }
            try t.expect(std.mem.eql(u64, &labels, &seen));
        }
        var live: usize = 0;
        for (level_graph.node_comp) |comp| {
            if (comp != no_comp) live += 1;
        }
        try t.expectEqual(level_graph.nodeCount(), live);
    }
    const free_comps = try allocator.alloc(bool, conn.comps.len);
    defer allocator.free(free_comps);
    @memset(free_comps, false);
    for (conn.comp_free.items) |comp| free_comps[comp] = true;
    const root_members = try allocator.alloc(u32, conn.roots.len);
    defer allocator.free(root_members);
    @memset(root_members, 0);
    for (0..conn.comps.len) |comp| {
        if (free_comps[comp]) {
            try t.expectEqual(@as(u32, 0), comp_sizes[comp]);
            continue;
        }
        try t.expect(comp_sizes[comp] > 0);
        try t.expectEqual(comp_sizes[comp], conn.comp_size[comp]);
        try t.expectEqual(std.math.maxInt(u32), conn.comp_set[comp]);
        root_members[conn.comp_root[comp]] += 1;
    }
    const free_roots = try allocator.alloc(bool, conn.roots.len);
    defer allocator.free(free_roots);
    @memset(free_roots, false);
    for (conn.root_free.items) |root| {
        try t.expect(!free_roots[root]);
        free_roots[root] = true;
    }
    for (0..conn.roots.len) |root| {
        if (free_roots[root]) {
            try t.expectEqual(@as(u32, 0), root_members[root]);
            continue;
        }
        try t.expect(root_members[root] > 0);
        try t.expectEqual(root_members[root], conn.root_members[root]);
        var walked: u32 = 0;
        var comp = conn.root_head[root];
        var prev: u32 = no_comp;
        while (comp != no_comp) : (comp = conn.comp_next[comp]) {
            try t.expectEqual(@as(u32, @intCast(root)), conn.comp_root[comp]);
            try t.expectEqual(prev, conn.comp_prev[comp]);
            prev = comp;
            walked += 1;
        }
        try t.expectEqual(root_members[root], walked);
    }
    const parents = try allocator.alloc(u32, index.total);
    defer allocator.free(parents);
    for (parents, 0..) |*parent, node| parent.* = @intCast(node);
    for (graph.level_graphs.items, 0..) |*level_graph, level_usize| {
        const level: u16 = @intCast(level_usize);
        for (0..level_graph.record_dir.items.len) |chunk_usize| {
            const chunk: u32 = @intCast(chunk_usize);
            const record = level_graph.recordOf(chunk) orelse continue;
            var row = level_graph.record_node_head[record];
            while (row != no_node) : (row = level_graph.node_sibling[row]) connUniteRecordEdges(graph, &index, parents, level, chunk, row);
        }
    }
    var class_root = std.AutoHashMap(u32, u32).init(allocator);
    defer class_root.deinit();
    var root_class = std.AutoHashMap(u32, u32).init(allocator);
    defer root_class.deinit();
    for (graph.level_graphs.items, 0..) |*level_graph, level_usize| {
        const level: u16 = @intCast(level_usize);
        for (level_graph.node_comp, 0..) |comp, row| {
            if (comp == no_comp) continue;
            const class = connFind(parents, index.of(level, @intCast(row)));
            const root = conn.comp_root[comp];
            try t.expectEqual((try class_root.getOrPutValue(class, root)).value_ptr.*, root);
            try t.expectEqual((try root_class.getOrPutValue(root, class)).value_ptr.*, class);
        }
    }
}

/// Asserts `a` and `b` hold the same nodes, keyed by (level, chunk, label), in the same
/// connectivity partition (ids may differ).
pub fn expectSameConnectivityPartition(a: *const NavGraph, b: *const NavGraph) !void {
    const t = std.testing;
    try t.expectEqual(a.level_graphs.items.len, b.level_graphs.items.len);
    var a_to_b = std.AutoHashMap(u32, u32).init(t.allocator);
    defer a_to_b.deinit();
    var b_to_a = std.AutoHashMap(u32, u32).init(t.allocator);
    defer b_to_a.deinit();
    for (a.level_graphs.items, b.level_graphs.items) |*graph_a, *graph_b| {
        try t.expectEqual(graph_a.nodeCount(), graph_b.nodeCount());
        for (0..graph_a.record_dir.items.len) |chunk_usize| {
            const chunk: u32 = @intCast(chunk_usize);
            const record = graph_a.recordOf(chunk) orelse continue;
            var row = graph_a.record_node_head[record];
            while (row != no_node) : (row = graph_a.node_sibling[row]) {
                const other = graph_b.nodeOf(chunk, graph_a.node_label[row]);
                try t.expect(other != no_node);
                const root_a = a.connectivity.comp_root[graph_a.node_comp[row]];
                const root_b = b.connectivity.comp_root[graph_b.node_comp[other]];
                try t.expectEqual((try a_to_b.getOrPutValue(root_a, root_b)).value_ptr.*, root_b);
                try t.expectEqual((try b_to_a.getOrPutValue(root_b, root_a)).value_ptr.*, root_a);
            }
        }
    }
}
