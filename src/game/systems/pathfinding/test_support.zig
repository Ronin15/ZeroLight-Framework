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
const ChunkGeometry = @import("../../world/terrain.zig").ChunkGeometry;
const assets = @import("../../../assets/assets.zig");
const manifest = @import("../../../assets/manifest.zig");
const world_tileset_meta = @import("../../../assets/world_tileset_meta.zig");
const WorldTilesetMeta = @import("../../../assets/world_tileset_meta.zig").WorldTilesetMeta;
const TileId = @import("../../world/system.zig").TileId;
const WorldSystem = @import("../../world/system.zig").WorldSystem;
const StaticColliderSystem = @import("../static_colliders.zig").StaticColliderSystem;
const NavExtent = @import("nav_graph.zig").NavExtent;
const NavGrid = @import("nav_grid.zig").NavGrid;
const ChunkForm = @import("../../world/terrain.zig").ChunkForm;
const ChunkBits = @import("../../world/terrain.zig").ChunkBits;
const SimulationFrame = @import("../../simulation.zig").SimulationFrame;
const SimulationEvent = @import("../../simulation.zig").SimulationEvent;
const WorldTileChangedEvent = @import("../../simulation.zig").WorldTileChangedEvent;
const NavUpdateStats = @import("types.zig").NavUpdateStats;
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const NavGraph = @import("nav_graph.zig").NavGraph;
const ChunkPortals = @import("nav_graph.zig").ChunkPortals;
const LabelSet = @import("nav_graph.zig").LabelSet;
const LinkPairs = @import("link_bounds.zig").LinkPairs;
const LinkBox = @import("link_bounds.zig").LinkBox;
const no_node = @import("connectivity.zig").no_node;
const no_comp = @import("connectivity.zig").no_comp;
const no_term = @import("connectivity.zig").no_term;
const no_hcomp = @import("connectivity_closure.zig").no_hcomp;
const no_oneway = @import("connectivity.zig").no_oneway;
const no_index = @import("connectivity_closure.zig").no_index;
const CellCoord = @import("../../world/system.zig").CellCoord;
const StructuralCommand = @import("../../data_system.zig").StructuralCommand;
const types = @import("types.zig");
const ThreadSystem = @import("../../../app/thread_system.zig").ThreadSystem;
const NavUpdateThreads = @import("nav_graph.zig").NavUpdateThreads;
const Connectivity = @import("connectivity.zig").Connectivity;
const StagingSizes = @import("connectivity.zig").StagingSizes;
const MergeMap = @import("connectivity.zig").MergeMap;
const rowWords = @import("connectivity_closure.zig").rowWords;
const indexMap = @import("connectivity_closure.zig").indexMap;
const publish = @import("publish.zig");
const solve = @import("solve.zig");
const PathQueryKey = @import("types.zig").PathQueryKey;
const PathfindingStats = @import("types.zig").PathfindingStats;
const PathfindingConfig = @import("types.zig").PathfindingConfig;
const registry_shard_count = @import("types.zig").registry_shard_count;
const registryShard = @import("types.zig").registryShard;
const chunkKey = @import("../chunk_list_map.zig").chunkKey;
const no_entry = @import("../chunk_list_map.zig").no_entry;

/// `NavGraph.StorageContent` of `world` from its composed chunk forms and link endpoint counts,
/// for a nav whose chunks are the world's: O(levels x chunks). Static colliders are not
/// counted; a nav over static bodies needs their chunks counted mixed.
pub fn navStorageContentOf(world: *const WorldSystem) NavGraph.StorageContent {
    var content = NavGraph.StorageContent{};
    const chunks = world.chunkCountPerLevel();
    for (0..world.levelCount()) |level_index| {
        const level: u16 = @intCast(level_index);
        var open: usize = 0;
        var mixed: usize = 0;
        for (0..chunks) |chunk_index| {
            const chunk: u32 = @intCast(chunk_index);
            switch (world.levelChunkBlockedForm(level, chunk)) {
                .open => open += 1,
                .mixed => mixed += 1,
                .blocked => {},
            }
            const endpoints = world.levelChunkLinkEndpointCount(level, chunk);
            content.endpoint_chunks += @intFromBool(endpoints != 0);
            content.max_chunk_endpoints = @max(content.max_chunk_endpoints, endpoints);
        }
        content.open_chunks += open;
        content.mixed_chunks += mixed;
        content.max_level_open = @max(content.max_level_open, open);
        content.max_level_mixed = @max(content.max_level_mixed, mixed);
    }
    return content;
}

/// The owner id of `key`'s entry in a cache core (a core or a pointer to one), or null.
pub fn cacheOwnerOf(core: anytype, key: PathQueryKey) ?u32 {
    const index = core.slotIndex(key) orelse return null;
    return core.slots.items[index].payload_index;
}

/// Live terminals of a connectivity closure (a `Closure` or a pointer to one).
pub fn closureTermCount(closure: anytype) usize {
    return closure.terms.len - closure.term_free.items.len;
}

/// Live H-components of a connectivity closure (a `Closure` or a pointer to one).
pub fn closureHcompCount(closure: anytype) usize {
    return closure.hcomps.len - closure.hcomp_free.items.len;
}

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

/// `PathfindingSystem.update` inline as one range: a thread system with no workers.
pub fn updatePathfindingInline(system: *PathfindingSystem, requests: *const RangeOutputStream(PathRequest), agent_count: usize, config: PathfindingConfig) !PathfindingStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0, .items_per_range = std.math.maxInt(u32) });
    defer threads.deinit();
    return system.update(requests, agent_count, &threads, config);
}

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
        .max_group_fields = 2,
        .worker_participant_count = 1,
        .nav_chunk_tiles = 4,
        .max_stitched_path_cells = 256,
        .min_group_field_agents = 1,
        .group_field_max_cells = test_group_field_max_cells,
    };
}

// Demo-painted world whose chunk edge is `abstractCapacity`'s nav chunk, so a world-backed
// abstract test and a world-less one share the same small multi-chunk geometry.
pub fn abstractTestWorld(meta: *const WorldTilesetMeta, bounds_width: f32, bounds_height: f32) !WorldSystem {
    return WorldSystem.initDemoFromMetaWithChunkSize(std.testing.allocator, meta, bounds_width, bounds_height, abstractCapacity().nav_chunk_tiles);
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

/// One world tile a test changed, for a test that kept no writer event.
pub const TileEdit = struct {
    level: u16,
    x: u16,
    y: u16,
};

/// Records tile write `change` (a writer's event) through the production terrain record.
pub fn recordTileChange(system: *PathfindingSystem, world: *const WorldSystem, change: WorldTileChangedEvent) !void {
    try recordTerrainEvents(system, &.{.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = change } }}, world);
}

/// Records `edits` through the production terrain record as tile events whose blocking
/// flipped: nav re-derives each touched chunk from the world, so only the tile matters.
pub fn recordTileEdits(system: *PathfindingSystem, world: *const WorldSystem, edits: []const TileEdit) !void {
    const events = try std.testing.allocator.alloc(SimulationEvent, edits.len);
    defer std.testing.allocator.free(events);
    for (events, edits) |*event, edit| event.* = .{ .stage = .structural_commit, .payload = .{ .world_tile_changed = .{
        .level = edit.level,
        .x = edit.x,
        .y = edit.y,
        .old_tile_id = 0,
        .new_tile_id = 0,
        .old_blocks_movement = false,
        .new_blocks_movement = true,
    } } };
    try recordTerrainEvents(system, events, world);
}

/// `recordTileChange`, then applies every pending nav change serially.
pub fn applyTileChange(system: *PathfindingSystem, colliders: *const StaticColliderSystem, world: *const WorldSystem, change: WorldTileChangedEvent) !NavUpdateStats {
    try recordTileChange(system, world, change);
    return system.applyBufferedNavUpdates(colliders, world, null);
}

/// `recordTileEdits`, then applies every pending nav change serially.
pub fn applyTileEdits(system: *PathfindingSystem, colliders: *const StaticColliderSystem, world: *const WorldSystem, edits: []const TileEdit) !NavUpdateStats {
    try recordTileEdits(system, world, edits);
    return system.applyBufferedNavUpdates(colliders, world, null);
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
            const local = (cell[1] - bounds.y0) * grid.geometry.chunk_tiles + (cell[0] - bounds.x0);
            bits[local / 64] |= @as(u64, 1) << @intCast(local % 64);
        }
        try grid.ensureFreeBlocks(allocator, 1, &pool_grows);
        const slot = grid.claimBlock();
        grid.blocked_count += grid.writeChunk(chunk, slot, bits);
        if (grid.chunkBlock(chunk) != slot) grid.releaseBlock(slot);
    }
}

/// The chunk-local index of in-level cell index `cell` under `geometry`.
pub fn localOfCell(geometry: ChunkGeometry, cell: usize) u8 {
    const y = cell / geometry.width;
    return geometry.localOf(cell - y * geometry.width, y);
}

/// The in-level cell index of chunk-local index `local` of `chunk` under `geometry`.
pub fn cellOfLocal(geometry: ChunkGeometry, chunk: u32, local: u8) u32 {
    const bounds = geometry.chunkBounds(chunk);
    const mask: usize = geometry.chunk_tiles - 1;
    // Cells of a validated grid are below 2^32.
    return @intCast((bounds.y0 + (@as(usize, local) >> geometry.shift)) * geometry.width + bounds.x0 + (local & mask));
}

/// `grid`'s form at `chunk`: mixed when it holds a cell block, else open or blocked by its
/// blocked count.
pub fn navChunkForm(grid: *const NavGrid, chunk: u32) ChunkForm {
    if (grid.chunkBlock(chunk) != null) return .mixed;
    return if (grid.chunkBlockedCount(chunk) == 0) .open else .blocked;
}

/// Mixed chunks of `grid` holding a cell block.
pub fn liveBlockCount(grid: *const NavGrid) usize {
    return grid.blocks.len - grid.block_free.items.len;
}

/// Portals across every record of every level of `graph`.
pub fn totalPortals(graph: *const NavGraph) usize {
    var count: usize = 0;
    for (0..graph.levelCount()) |level| count += levelLivePortalCount(graph, @intCast(level));
    return count;
}

/// Portals across every record of `level` of `graph`.
pub fn levelLivePortalCount(graph: *const NavGraph, level: u16) usize {
    var count: usize = 0;
    for (0..graph.chunkCount()) |chunk| {
        const portals = graph.chunkPortals(level, @intCast(chunk));
        count += portals.border.len + portals.extra.len;
    }
    return count;
}

// Connectivity checks: node keys (level, chunk, label) and a reference union over the records.

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
    const row = graph.levelGraph(level).?.nodeOf(grid.geometry.chunkOfCell(cell), grid.labelAt(cell));
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
    const mask: usize = grid.geometry.chunk_tiles - 1;
    const from = index.of(level, row);
    for (portals.border) |portal| {
        if (portal.label != label) continue;
        const x = bounds.x0 + (portal.local & mask);
        const y = bounds.y0 + (@as(usize, portal.local) >> grid.geometry.shift);
        const mirrors = [_]struct { on: bool, cell: usize }{
            .{ .on = portal.flags.west, .cell = y * grid.geometry.width + x -% 1 },
            .{ .on = portal.flags.east, .cell = y * grid.geometry.width + x + 1 },
            .{ .on = portal.flags.north, .cell = (y -% 1) *% grid.geometry.width +% x },
            .{ .on = portal.flags.south, .cell = (y + 1) * grid.geometry.width + x },
        };
        for (mirrors) |mirror| {
            if (mirror.on) connUnite(parents, from, index.of(level, connNodeAt(graph, level, mirror.cell)));
        }
    }
    for (portals.links) |link| {
        if (grid.labelAtLocal(chunk, link.local) != label) continue;
        const target = graph.grid(link.to_level) orelse continue;
        if (target.isBlockedIndex(link.to_cell)) continue;
        const target_chunk = target.geometry.chunkOfCell(link.to_cell);
        const x = link.to_cell % target.geometry.width;
        const y = link.to_cell / target.geometry.width;
        const local = target.geometry.localOf(x, y);
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
            var labels: LabelSet = .empty;
            const portals = level_graph.chunkPortals(chunk);
            for (portals.border) |portal| labels.set(portal.label);
            for (portals.extra) |portal| labels.set(portal.label);
            const record = level_graph.recordOf(chunk) orelse {
                try t.expectEqual(@as(usize, 0), labels.count());
                continue;
            };
            try t.expectEqual(labels.count(), @as(usize, level_graph.record_label_count[record]));
            var seen: LabelSet = .empty;
            var row = level_graph.record_node_head[record];
            while (row != no_node) : (row = level_graph.node_sibling[row]) {
                const label = level_graph.node_label[row];
                try t.expect(labels.isSet(label) and !seen.isSet(label));
                seen.set(label);
                try t.expect(!listed[index.of(level, row)]);
                listed[index.of(level, row)] = true;
                const comp = level_graph.node_comp[row];
                try t.expect(comp < conn.comps.len);
                comp_sizes[comp] += 1;
            }
            try t.expect(std.mem.eql(u64, &labels.masks, &seen.masks));
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

// One-way closure checks: a reference over the world's links and terminal pairs.

// The root of the node at `cell` of `level` when the level is built and the cell open.
fn closureRootAt(graph: *const NavGraph, level: u16, cell: CellCoord) ?u32 {
    const grid = graph.grid(level) orelse return null;
    const index = @as(usize, cell.y) * grid.geometry.width + cell.x;
    if (grid.isBlockedIndex(index)) return null;
    const row = graph.levelGraph(level).?.nodeOf(grid.geometry.chunkOfCell(index), grid.labelAt(index));
    std.debug.assert(row != no_node);
    return graph.connectivity.comp_root[graph.levelGraph(level).?.node_comp[row]];
}

/// Asserts `graph`'s one-way closure against `world`: every world link registered (one-way
/// ones with a row), live one-way links on their component's list with their roots'
/// terminals and dead ones on none; exactly the roots holding a live endpoint have
/// terminals; every terminal at its index in its component's map; free indices (the free
/// list from `index_free` to `no_index`) with zero rows and columns, every other handed-out
/// entry a terminal pointing back to it, and rows past the handed-out indices zero; every
/// live block exactly its words and every free id blockless; every block at least a quarter
/// full from 64 indices up; live words summing the live blocks; and each terminal's row equal
/// to a search over live links between roots.
pub fn expectClosureConsistent(graph: *const NavGraph, world: *const WorldSystem) !void {
    const t = std.testing;
    const allocator = t.allocator;
    const conn = &graph.connectivity;
    const closure = &conn.closure;
    const links = world.levelLinks();
    try t.expectEqual(links.len, closure.oneway_cursor);
    try t.expectEqual(links.len, closure.oneway_of_link.items.len);
    const oneway = closure.oneway.slice();
    const roots = conn.roots.len;
    const holds = try allocator.alloc(bool, roots);
    defer allocator.free(holds);
    @memset(holds, false);
    // Live links as root pairs, for the reference search.
    var edges: std.ArrayList([2]u32) = .empty;
    defer edges.deinit(allocator);
    var live_links: usize = 0;
    for (links, 0..) |link, index| {
        const row = closure.oneway_of_link.items[index];
        if (link.bidirectional) {
            try t.expectEqual(no_oneway, row);
            continue;
        }
        try t.expect(row != no_oneway and oneway.items(.link)[row] == index);
        const src = closureRootAt(graph, link.level_a, link.cell_a);
        const dst = closureRootAt(graph, link.level_b, link.cell_b);
        if (src == null or dst == null) {
            try t.expectEqual(no_hcomp, oneway.items(.hcomp)[row]);
            continue;
        }
        live_links += 1;
        holds[src.?] = true;
        holds[dst.?] = true;
        try edges.append(allocator, .{ src.?, dst.? });
        try t.expect(oneway.items(.hcomp)[row] != no_hcomp);
        try t.expectEqual(conn.root_term[src.?], oneway.items(.src_term)[row]);
        try t.expectEqual(conn.root_term[dst.?], oneway.items(.dst_term)[row]);
    }
    const free_root = try allocator.alloc(bool, roots);
    defer allocator.free(free_root);
    @memset(free_root, false);
    for (conn.root_free.items) |root| free_root[root] = true;
    var terminals: std.ArrayList(u32) = .empty;
    defer terminals.deinit(allocator);
    for (0..roots) |root| {
        const term = conn.root_term[root];
        if (free_root[root]) {
            try t.expectEqual(no_term, term);
            continue;
        }
        try t.expectEqual(holds[root], term != no_term);
        if (term == no_term) continue;
        try t.expectEqual(@as(u32, @intCast(root)), closure.term.root[term]);
        try terminals.append(allocator, @intCast(root));
    }
    try t.expectEqual(terminals.items.len, closureTermCount(closure));
    // Components: maps, free lists, zero rows and columns, links, words.
    var live_words: usize = 0;
    var listed_links: usize = 0;
    var live_terms: usize = 0;
    var free_index: std.DynamicBitSetUnmanaged = .{};
    defer free_index.deinit(allocator);
    for (0..closure.hcomps.len) |id| {
        const k_cap = closure.hcomp.k_cap[id];
        const block = closure.hcomp.block[id];
        if (k_cap == 0) {
            try t.expectEqual(@as(usize, 0), block.len);
            continue;
        }
        const row_words: usize = @max(1, k_cap / 32);
        const block_words = std.mem.alignForward(usize, @as(usize, k_cap) * (row_words + 1), 16);
        try t.expectEqual(block_words, block.len);
        const map = block[@as(usize, k_cap) * row_words ..][0..k_cap];
        const k_high = closure.hcomp.k_high[id];
        live_words += block_words;
        // The free list, from its head to `no_index`, each index once.
        try free_index.resize(allocator, k_high, false);
        free_index.unsetAll();
        var free: u32 = 0;
        var cursor = closure.hcomp.index_free[id];
        while (cursor != no_index) : (cursor = map[cursor]) {
            try t.expect(cursor < k_high and !free_index.isSet(cursor));
            free_index.set(cursor);
            free += 1;
        }
        var live: u32 = 0;
        for (map[0..k_high], 0..) |entry, index| {
            if (free_index.isSet(index)) {
                for (block[index * row_words ..][0..row_words]) |word| try t.expectEqual(@as(u32, 0), word);
                for (0..k_high) |other| {
                    const word = block[other * row_words + index / 32];
                    try t.expectEqual(@as(u32, 0), (word >> @intCast(index % 32)) & 1);
                }
                continue;
            }
            live += 1;
            try t.expect(entry < closure.terms.len);
            try t.expectEqual(@as(u32, @intCast(id)), closure.term.hcomp[entry]);
            try t.expectEqual(@as(u32, @intCast(index)), closure.term.index[entry]);
        }
        for (k_high..k_cap) |index| {
            for (block[index * row_words ..][0..row_words]) |word| try t.expectEqual(@as(u32, 0), word);
        }
        try t.expectEqual(live, closure.hcomp.k_live[id]);
        // Blocks follow their live terminals: under a quarter full only below 64 indices.
        try t.expect(k_high <= k_cap);
        try t.expect(k_cap < 64 or 4 * live >= k_cap);
        live_terms += live;
        var link_count: u32 = 0;
        var link = closure.hcomp.link_head[id];
        while (link != no_oneway) : (link = oneway.items(.next)[link]) {
            try t.expectEqual(@as(u32, @intCast(id)), oneway.items(.hcomp)[link]);
            link_count += 1;
        }
        try t.expectEqual(closure.hcomp.link_count[id], link_count);
        listed_links += link_count;
    }
    try t.expectEqual(live_words, closure.live_words);
    try t.expectEqual(live_links, listed_links);
    try t.expectEqual(terminals.items.len, live_terms);
    // Reference: per terminal root, a search over live links between roots.
    const seen = try allocator.alloc(bool, roots);
    defer allocator.free(seen);
    var queue: std.ArrayList(u32) = .empty;
    defer queue.deinit(allocator);
    for (terminals.items) |from| {
        @memset(seen, false);
        queue.clearRetainingCapacity();
        seen[from] = true;
        try queue.append(allocator, from);
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const at = queue.items[head];
            for (edges.items) |edge| {
                if (edge[0] != at or seen[edge[1]]) continue;
                seen[edge[1]] = true;
                try queue.append(allocator, edge[1]);
            }
        }
        for (terminals.items) |to| {
            try t.expectEqual(seen[to], closure.termReaches(conn.root_term[from], conn.root_term[to]));
        }
    }
}

/// Every live one-way closure block's rows and handed-out map entries, in H-component order,
/// for a before-and-after compare. The caller frees the slice.
pub fn dupeClosureBlocks(allocator: std.mem.Allocator, graph: *const NavGraph) ![]u32 {
    const closure = &graph.connectivity.closure;
    var words: std.ArrayList(u32) = .empty;
    errdefer words.deinit(allocator);
    for (closure.hcomp.k_cap, closure.hcomp.k_high, closure.hcomp.block) |k_cap, k_high, block| {
        if (k_cap == 0) continue;
        const rows = @as(usize, k_cap) * @max(1, k_cap / 32);
        try words.appendSlice(allocator, block[0..rows]);
        try words.appendSlice(allocator, block[rows..][0..k_high]);
    }
    return words.toOwnedSlice(allocator);
}

/// Asserts `a` and `b` hold the same terminals, keyed by a node of their root, with the same
/// closure reach between every pair (ids, indices, and blocks may differ).
pub fn expectSameClosure(a: *const NavGraph, b: *const NavGraph) !void {
    const t = std.testing;
    const allocator = t.allocator;
    try t.expectEqual(closureTermCount(a.connectivity.closure), closureTermCount(b.connectivity.closure));
    // Per terminal of `a`: the terminal of `b` at one of its root's nodes.
    var pairs: std.ArrayList([2]u32) = .empty;
    defer pairs.deinit(allocator);
    const mapped = try allocator.alloc(bool, a.connectivity.roots.len);
    defer allocator.free(mapped);
    @memset(mapped, false);
    for (a.level_graphs.items, b.level_graphs.items) |*graph_a, *graph_b| {
        for (0..graph_a.record_dir.items.len) |chunk_usize| {
            const chunk: u32 = @intCast(chunk_usize);
            const record = graph_a.recordOf(chunk) orelse continue;
            var row = graph_a.record_node_head[record];
            while (row != no_node) : (row = graph_a.node_sibling[row]) {
                const root = a.connectivity.comp_root[graph_a.node_comp[row]];
                if (mapped[root] or a.connectivity.root_term[root] == no_term) continue;
                mapped[root] = true;
                const other = graph_b.nodeOf(chunk, graph_a.node_label[row]);
                try t.expect(other != no_node);
                const other_term = b.connectivity.root_term[b.connectivity.comp_root[graph_b.node_comp[other]]];
                try t.expect(other_term != no_term);
                try pairs.append(allocator, .{ a.connectivity.root_term[root], other_term });
            }
        }
    }
    for (pairs.items) |from| {
        for (pairs.items) |to| {
            try t.expectEqual(a.connectivity.closure.termReaches(from[0], to[0]), b.connectivity.closure.termReaches(from[1], to[1]));
        }
    }
}

/// Expects pair `index` of `pairs` to be the point pair from `from` to `to` (x, y, level) at `cost`.
pub fn expectLinkPair(pairs: *const LinkPairs, index: usize, from: [3]i32, to: [3]i32, cost: i32) !void {
    try std.testing.expectEqual(LinkBox.point(from[0], from[1], from[2]), pairs.entrances.boxAt(index));
    try std.testing.expectEqual(LinkBox.point(to[0], to[1], to[2]), pairs.exits.boxAt(index));
    try std.testing.expectEqual(cost, pairs.cost[index]);
}

/// Chunk edge of the test worlds, in cells.
pub const test_chunk: u16 = 4;

/// A world of `chunks` x `chunks` walkable 4-cell chunks on `levels` levels, each level with
/// an obstacle layer to draw walls on.
pub const TestWorld = struct {
    meta: WorldTilesetMeta,
    world: @import("../../world/system.zig").WorldSystem,
    data: DataSystem,
    obstacle: [4]usize = @splat(0),
    grass: TileId,
    tree: TileId,

    pub fn init(chunks: u16, levels: u16) !TestWorld {
        var meta = try loadTestWorldMeta(std.testing.allocator);
        errdefer meta.deinit();
        const grass = try requireTestTile(&meta, "grass");
        const tree = try requireTestTile(&meta, "tree_0");
        const extent = @as(f32, @floatFromInt(@as(u32, chunks) * test_chunk)) * meta.tileSize();
        var world = try abstractTestWorld(&meta, extent, extent);
        errdefer world.deinit();
        var fixture = TestWorld{ .meta = meta, .world = world, .data = DataSystem.init(std.testing.allocator), .grass = grass, .tree = tree };
        fixture.obstacle[0] = try fixture.world.addDenseLayer(0, 0, .obstacle, grass);
        for (1..levels) |level| {
            _ = try fixture.world.addLevel(-16 * @as(i32, @intCast(level)));
            _ = try fixture.world.addDenseLayer(@intCast(level), 0, .floor, grass);
            fixture.obstacle[level] = try fixture.world.addDenseLayer(@intCast(level), 0, .obstacle, grass);
        }
        return fixture;
    }

    pub fn deinit(self: *TestWorld) void {
        self.data.deinit();
        self.world.deinit();
        self.meta.deinit();
    }

    /// Writes `tile` over every cell of chunk (cx, cy) on `level`, marking `system` dirty.
    pub fn setChunk(self: *TestWorld, system: ?*PathfindingSystem, level: u16, cx: u16, cy: u16, tile: TileId) !void {
        for (0..test_chunk) |dy| for (0..test_chunk) |dx| {
            try self.setCell(system, level, @intCast(cx * test_chunk + dx), @intCast(cy * test_chunk + dy), tile);
        };
    }

    pub fn setCell(self: *TestWorld, system: ?*PathfindingSystem, level: u16, x: u16, y: u16, tile: TileId) !void {
        const changed = (try self.world.setDenseTile(self.obstacle[level], x, y, tile)) orelse return;
        if (system) |nav| try recordTileChange(nav, &self.world, changed);
    }

    pub fn build(self: *TestWorld, capacity: types.PathfindingCapacity) !PathfindingSystem {
        var system = PathfindingSystem.init(std.testing.allocator);
        errdefer system.deinit();
        try system.reserve(capacity);
        try system.rebuildStaticNavGridWithWorld(&self.data, &self.world, null);
        return system;
    }

    /// Asserts `system`'s connectivity and one-way closure are consistent with the world and
    /// partition and reach as a full rebuild's do.
    pub fn expectMatchesRebuild(self: *TestWorld, system: *const PathfindingSystem) !void {
        var rebuilt = try self.build(abstractCapacity());
        defer rebuilt.deinit();
        try expectConnectivityConsistent(&system.graph);
        try expectConnectivityConsistent(&rebuilt.graph);
        try expectSameConnectivityPartition(&system.graph, &rebuilt.graph);
        try expectClosureConsistent(&system.graph, &self.world);
        try expectClosureConsistent(&rebuilt.graph, &self.world);
        try expectSameClosure(&system.graph, &rebuilt.graph);
    }

    pub fn cell(self: *const TestWorld, x: usize, y: usize) usize {
        return y * self.world.width + x;
    }
};

/// A 10 x 10 chunk level halved by a solid chunk column, each half holding a walled 2 x 2 chunk
/// room opened by one gap chunk ((2, 1) and (7, 1)): enclosing both rooms splits two separate
/// components, each flooding as its own family.
pub fn twoRooms(fixture: *TestWorld) !void {
    for (0..10) |cy| try fixture.setChunk(null, 0, 5, @intCast(cy), fixture.tree);
    for (0..3) |cy| {
        if (cy != 1) try fixture.setChunk(null, 0, 2, @intCast(cy), fixture.tree);
        if (cy != 1) try fixture.setChunk(null, 0, 7, @intCast(cy), fixture.tree);
    }
    for (0..2) |cx| try fixture.setChunk(null, 0, @intCast(cx), 2, fixture.tree);
    for (8..10) |cx| try fixture.setChunk(null, 0, @intCast(cx), 2, fixture.tree);
}

pub fn toggleRooms(fixture: *TestWorld, system: ?*PathfindingSystem, tile: TileId) !void {
    try fixture.setChunk(system, 0, 2, 1, tile);
    try fixture.setChunk(system, 0, 7, 1, tile);
}

/// Asserts `a` and `b` hold bitwise equal connectivity and one-way closure columns.
pub fn expectSameColumns(a: *const NavGraph, b: *const NavGraph) !void {
    const t = std.testing;
    for (a.level_graphs.items, b.level_graphs.items) |*level_a, *level_b| {
        try t.expectEqualSlices(u8, level_a.node_label, level_b.node_label);
        try t.expectEqualSlices(u32, level_a.node_comp, level_b.node_comp);
        try t.expectEqualSlices(u32, level_a.node_sibling, level_b.node_sibling);
        try t.expectEqualSlices(u32, level_a.node_free.items, level_b.node_free.items);
        try t.expectEqualSlices(u32, level_a.record_node_head, level_b.record_node_head);
        try t.expectEqualSlices(u8, level_a.record_label_count, level_b.record_label_count);
    }
    const conn_a = &a.connectivity;
    const conn_b = &b.connectivity;
    try t.expectEqualSlices(u32, conn_a.comp_root, conn_b.comp_root);
    try t.expectEqualSlices(u32, conn_a.comp_size, conn_b.comp_size);
    try t.expectEqualSlices(u32, conn_a.comp_prev, conn_b.comp_prev);
    try t.expectEqualSlices(u32, conn_a.comp_next, conn_b.comp_next);
    try t.expectEqualSlices(u32, conn_a.comp_set, conn_b.comp_set);
    try t.expectEqualSlices(u32, conn_a.root_head, conn_b.root_head);
    try t.expectEqualSlices(u32, conn_a.root_members, conn_b.root_members);
    try t.expectEqualSlices(u32, conn_a.comp_free.items, conn_b.comp_free.items);
    try t.expectEqualSlices(u32, conn_a.root_free.items, conn_b.root_free.items);
    try t.expectEqualSlices(u32, conn_a.root_term, conn_b.root_term);
    const closure_a = &conn_a.closure;
    const closure_b = &conn_b.closure;
    try t.expectEqual(closure_a.live_words, closure_b.live_words);
    try t.expectEqualSlices(u32, closure_a.oneway_of_link.items, closure_b.oneway_of_link.items);
    inline for (.{ .root, .hcomp, .index, .slot }) |field| try t.expectEqualSlices(u32, @field(closure_a.term, @tagName(field)), @field(closure_b.term, @tagName(field)));
    inline for (.{ .k_cap, .k_high, .k_live, .index_free, .link_head, .link_tail, .link_count }) |field| try t.expectEqualSlices(u32, @field(closure_a.hcomp, @tagName(field)), @field(closure_b.hcomp, @tagName(field)));
    // Block addresses differ; each H-component's rows and handed-out map entries match (its
    // padding and unused map entries are never read).
    for (closure_a.hcomp.k_cap, closure_a.hcomp.k_high, 0..) |k_cap, k_high, id_usize| {
        const id: u32 = @intCast(id_usize);
        try t.expectEqual(closure_a.hcomp.block[id].len, closure_b.hcomp.block[id].len);
        if (k_cap == 0) continue;
        const rows = @as(usize, k_cap) * rowWords(k_cap);
        try t.expectEqualSlices(u32, closure_a.hcomp.block[id][0..rows], closure_b.hcomp.block[id][0..rows]);
        try t.expectEqualSlices(u32, indexMap(closure_a.hcomp, id)[0..k_high], indexMap(closure_b.hcomp, id)[0..k_high]);
    }
    inline for (.{ .link, .hcomp, .next, .src_term, .dst_term }) |field| try t.expectEqualSlices(u32, closure_a.oneway.items(field), closure_b.oneway.items(field));
    try t.expectEqualSlices(u32, closure_a.term_free.items, closure_b.term_free.items);
    try t.expectEqualSlices(u32, closure_a.hcomp_free.items, closure_b.hcomp_free.items);
}

pub fn markAll(run: *TestWorld, systems: []const *PathfindingSystem, level: u16, x: u16, y: u16, tile: TileId) !void {
    const changed = (try run.world.setDenseTile(run.obstacle[level], x, y, tile)) orelse return;
    for (systems) |system| try recordTileChange(system, &run.world, changed);
}

/// The system's nav threads pinned to one item per range on `threads`.
pub fn forcedNavThreads(system: *PathfindingSystem, threads: *ThreadSystem) NavUpdateThreads {
    return .{
        .thread_system = threads,
        .tuners = &system.tuners.nav,
        .controls = .{ .adaptive = false, .items_per_range = 1 },
    };
}

/// Asserts every staging list of `conn` is held for its size in `keep` (`types.stagingHeld`),
/// as a release to `keep` leaves it.
pub fn expectStagingWithin(conn: *const Connectivity, keep: StagingSizes) !void {
    const t = std.testing;
    // A starts list and its counts keep the same size.
    try t.expect(types.stagingHeld(&conn.seed_starts, keep.changed_keys + 1) and types.stagingHeld(&conn.seed_counts, keep.changed_keys + 1));
    try t.expect(types.stagingHeld(&conn.seed_edges, keep.seeds));
    try t.expect(types.stagingHeld(&conn.patch_changed, keep.patch_keys + 1));
    try t.expect(types.stagingHeld(&conn.row_starts, keep.items + 1) and types.stagingHeld(&conn.edge_starts, keep.items + 1));
    try t.expect(types.stagingHeld(&conn.row_counts, keep.items + 1) and types.stagingHeld(&conn.edge_counts, keep.items + 1));
    try t.expect(types.stagingHeld(&conn.gather_rows, keep.rows) and types.stagingHeld(&conn.gather_edges, keep.edges));
    try t.expect(!types.shouldShrinkCapacity(conn.element_map.keys.capacity, try MergeMap.slotCount(2 * keep.elements)));
    try t.expect(types.stagingHeld(&conn.elements, keep.elements) and types.stagingHeld(&conn.units, keep.elements));
    try t.expect(types.stagingHeld(&conn.sets, keep.elements) and types.stagingHeld(&conn.families, keep.elements) and types.stagingHeld(&conn.groups, keep.elements));
    inline for (.{ &conn.unit_elements, &conn.group_roots, &conn.group_sets, &conn.root_first, &conn.round_sets }) |list| {
        try t.expect(types.stagingHeld(list, keep.elements));
    }
}

/// Asserts every batch list of `graph` is held for what its release keeps: its group's window
/// high, the most a one-chunk batch needed, and the graph's static one-chunk floor (1 changed,
/// 1 dirty, 5 patch keys; one plan range).
pub fn expectGraphStagingWithin(graph: *const NavGraph) !void {
    const t = std.testing;
    const window = &graph.staging_window;
    const changed = window.kept(.changed, 1);
    const dirty = window.kept(.dirty, 1);
    const patch = window.kept(.patch, 5);
    try t.expect(types.stagingHeld(&graph.changed_keys, changed) and types.stagingHeld(&graph.plan_staging[0], changed));
    try t.expect(types.stagingHeld(&graph.dirty_keys, dirty) and types.stagingHeld(&graph.plan_staging[1], dirty));
    try t.expect(types.stagingHeld(&graph.patch_keys, patch) and types.stagingHeld(&graph.plan_staging[2], patch));
    try t.expect(types.stagingHeld(&graph.changed_masks, changed) and types.stagingHeld(&graph.remask_slots, changed) and types.stagingHeld(&graph.remask_deltas, changed));
    try t.expect(types.stagingHeld(&graph.patch_info, patch));
    try t.expect(types.stagingHeld(&graph.plan_windows, window.kept(.ranges, 1)) and types.stagingHeld(&graph.plan_tallies, window.kept(.ranges, 1)));
}

/// `capacity` with a release window of `steps` steps, so a test closes windows quickly.
pub fn windowCapacity(steps: u32) types.PathfindingCapacity {
    var capacity = abstractCapacity();
    capacity.capacity_shrink_window = steps;
    return capacity;
}

/// A comb on `fixture`'s level of `2 * tunnels` chunks: an open corridor along chunk row 0 and
/// below it `tunnels` one-chunk dead-end tunnels on the even chunk columns, walled apart by the
/// odd ones. Filling the corridor in one batch makes every tunnel mouth a set of one family.
/// With `joined`, each odd tunnel meets the next at the level's bottom row, so their sets meet
/// mid-flood: a set served in a round reaches the one the family's pass resumes at.
pub fn hubTunnels(fixture: *TestWorld, tunnels: u16, joined: bool) !void {
    const side = 2 * tunnels;
    for (1..side) |cy| {
        var cx: u16 = 1;
        while (cx < side) : (cx += 2) {
            const bottom_link = joined and cy == side - 1 and cx % 4 == 3 and cx + 1 < side - 1;
            if (!bottom_link) try fixture.setChunk(null, 0, cx, @intCast(cy), fixture.tree);
        }
    }
}

/// Writes `tile` over the comb's corridor, marking `system` dirty.
pub fn setHubCorridor(fixture: *TestWorld, system: ?*PathfindingSystem, tunnels: u16, tile: TileId) !void {
    for (0..2 * tunnels) |cx| try fixture.setChunk(system, 0, @intCast(cx), 0, tile);
}

/// The id pool a batch test exhausts.
pub const ExhaustedPool = enum { comps, terms };

/// Applies `system`'s pending change with `pool` reading one row short of its id sentinel and
/// holding no free id: growth checks only the pool's length, so no row memory backs the count,
/// and both are restored before any reader walks the rows. The batch fails as OutOfMemory;
/// with `arm`, on an allocator failing every request, so the id check, not an allocation, is
/// what failed (a warmed batch asks nothing before its id growth). The graph stays as
/// `before` with the change pending, and the retry with the rows freed equals a rebuild.
pub fn expectExhaustedPoolBatch(fixture: *TestWorld, system: *PathfindingSystem, before: *const PathfindingSystem, pool: ExhaustedPool, arm: bool) !void {
    const conn = &system.graph.connectivity;
    const closure = &conn.closure;
    const len = switch (pool) {
        .comps => &conn.comps.len,
        .terms => &closure.terms.len,
    };
    const free = switch (pool) {
        .comps => &conn.comp_free,
        .terms => &closure.term_free,
    };
    const sentinel: usize = switch (pool) {
        .comps => no_comp,
        .terms => no_term,
    };
    const live_rows = len.*;
    const free_ids = try std.testing.allocator.dupe(u32, free.items);
    defer std.testing.allocator.free(free_ids);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    if (arm) {
        system.allocator = failing.allocator();
        system.graph.allocator = failing.allocator();
    }
    len.* = sentinel - 1;
    free.items.len = 0;
    const result = system.applyBufferedNavUpdates(&no_colliders, &fixture.world, null);
    system.allocator = std.testing.allocator;
    system.graph.allocator = std.testing.allocator;
    len.* = live_rows;
    free.items.len = free_ids.len;
    conn.refreshColumns();
    closure.refreshColumns();
    try std.testing.expectError(error.OutOfMemory, result);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqualSlices(u32, free_ids, free.items);
    try expectConnectivityConsistent(&system.graph);
    try expectSameConnectivityPartition(&system.graph, &before.graph);
    try expectSameClosure(&system.graph, &before.graph);
    try std.testing.expect(system.hasPendingNavUpdates(&fixture.world));
    _ = try system.applyBufferedNavUpdates(&no_colliders, &fixture.world, null);
    try fixture.expectMatchesRebuild(system);
}

/// A long release window, so a warmed batch's staging stays held.
pub const exhausted_pool_window: u32 = 1 << 16;

/// World center (px) of tile cell (cx, cy) at the demo 32px tile size, used to seed
/// requests/queries at a known nav cell.
pub fn tileCenter(cx: u16, cy: u16) math.Vec2 {
    return .{ .x = @as(f32, @floatFromInt(cx)) * 32 + 16, .y = @as(f32, @floatFromInt(cy)) * 32 + 16 };
}

pub fn cellWorld(x: i32, y: i32) math.Vec2 {
    return .{ .x = @as(f32, @floatFromInt(x)) * 32.0 + 16.0, .y = @as(f32, @floatFromInt(y)) * 32.0 + 16.0 };
}

pub fn appendIndividual(stream: *RangeOutputStream(PathRequest), entity: EntityId, goal: math.Vec2) !void {
    try appendPathRequest(stream, .{ .entity = entity, .start = cellWorld(1, 2), .goal = goal });
}

/// Stores the level-0 plain `path` for `key` at `step` as one publish would, its registry
/// runs included, and flushes the registry.
pub fn publishTestPath(system: *PathfindingSystem, key: PathQueryKey, path: []const u32, step: u32, stats: *PathfindingStats) !void {
    system.completed.core.beginPublish();
    const claimed = system.completed.claim(key, path.len, 0, 0, .{ .level = 0, .cell = path[path.len - 1] }, path[path.len - 1], step, stats);
    @memcpy(system.completed.destination(claimed)[0..path.len], path);
    _ = publish.flushRegistry(system, null, null);
    const starts = try std.testing.allocator.alloc(u16, path.len);
    defer std.testing.allocator.free(starts);
    var counts: [registry_shard_count]u32 = @splat(0);
    const geometry = system.graph.chunkGeometry();
    const run_count = solve.splitRuns(geometry, path, null, 0, starts, &counts);
    for (starts[0..run_count]) |start| {
        const run_key = chunkKey(0, geometry.chunkOfCell(path[start]));
        const shard = &system.path_index[registryShard(run_key)];
        try shard.reserve(1, 1, system.completed.logicalCapacity());
        shard.add(claimed.owner, run_key, start);
    }
}

/// Solves `goals` from cellWorld(1, 2) in one serial step with the default budgets.
pub fn solveIndividualGoals(system: *PathfindingSystem, requester: EntityId, goals: []const math.Vec2, agent_count: usize) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (goals) |goal| try appendIndividual(&stream, requester, goal);
    return updatePathfindingInline(system, &stream, agent_count, .{});
}

/// The stored cells of `goal`'s cached plain path, copied out.
pub fn cachedPathCells(system: *const PathfindingSystem, goal: math.Vec2) !std.ArrayList(u32) {
    const key = system.graph.keyForWorld(0, goal, .default).?;
    const slot = system.completed.slotIndex(key) orelse return error.TestExpectedCachedPath;
    var cells: std.ArrayList(u32) = .empty;
    errdefer cells.deinit(std.testing.allocator);
    try cells.appendSlice(std.testing.allocator, system.completed.pathSlice(slot, system.completed.resultAt(slot).path_len));
    return cells;
}

/// A world `side` tiles a side in 4-tile chunks, open grass, with an obstacle layer to flip.
pub const RegistryWorld = struct {
    world: WorldSystem,
    obstacle: usize,
    grass: TileId,
    tree: TileId,
};

pub fn registryWorld(meta: *const WorldTilesetMeta, side: u16) !RegistryWorld {
    const grass = try requireTestTile(meta, "grass");
    const tree = try requireTestTile(meta, "tree_0");
    var world = try abstractTestWorld(meta, @as(f32, @floatFromInt(side)) * 32, @as(f32, @floatFromInt(side)) * 32);
    errdefer world.deinit();
    const obstacle = try world.addDenseLayer(0, 0, .obstacle, grass);
    return .{ .world = world, .obstacle = obstacle, .grass = grass, .tree = tree };
}

/// A system over `world` at the abstract capacity (4-tile chunks, a two-step shrink
/// window), grown to `agent_count` agents.
pub fn registrySystem(data: *const DataSystem, world: *const WorldSystem, agent_count: usize) !PathfindingSystem {
    return registrySystemWith(data, world, agent_count, .{});
}

const RegistrySystemOptions = struct {
    // Inline stripe cells; a path past it is stored in a long block.
    stored_path_cells: ?usize = null,
    participants: usize = 1,
};

pub fn registrySystemWith(data: *const DataSystem, world: *const WorldSystem, agent_count: usize, options: RegistrySystemOptions) !PathfindingSystem {
    var system = PathfindingSystem.init(std.testing.allocator);
    errdefer system.deinit();
    var capacity = abstractCapacity();
    capacity.capacity_shrink_window = 2;
    capacity.worker_participant_count = options.participants;
    if (options.stored_path_cells) |cells| capacity.max_stored_path_cells = cells;
    try system.reserve(capacity);
    try system.rebuildStaticNavGridWithWorld(data, world, null);
    try system.growForAgentCount(agent_count);
    return system;
}

/// Route `index` across a registry world `side` tiles a side: distinct goals, each start
/// mirrored through the center, so routes cross many chunks.
pub fn registryRoute(index: usize, side: u16) [2]math.Vec2 {
    const span: usize = side - 4;
    const goal_x: u16 = @intCast(2 + index % span);
    const goal_y: u16 = @intCast(2 + (index / span * 3 + index % 3) % span);
    var start_x = side - 1 - goal_x;
    const start_y = side - 1 - goal_y;
    // The test world's two blocking decorations are no start.
    if ((start_x == side / 4 and start_y == side / 3) or (start_x == side * 3 / 4 and start_y == side * 2 / 3)) start_x += 1;
    return .{ tileCenter(start_x, start_y), tileCenter(goal_x, goal_y) };
}

pub fn registryRouteKey(system: *const PathfindingSystem, index: usize, side: u16) PathQueryKey {
    return system.graph.keyForWorld(0, registryRoute(index, side)[1], .default).?;
}

/// Requests routes [first, first + count) and updates (on `threads` when given) until
/// nothing is pending.
pub fn solveRegistryRoutes(system: *PathfindingSystem, requester: EntityId, side: u16, first: usize, count: usize, agent_count: usize, threads: ?*ThreadSystem, config: PathfindingConfig) !void {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (first..first + count) |index| {
        const route = registryRoute(index, side);
        try appendPathRequest(&stream, .{ .entity = requester, .start = route[0], .goal = route[1] });
    }
    var empty = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer empty.deinit();
    var requests = &stream;
    for (0..16) |_| {
        if (threads) |thread_system| {
            _ = try system.update(requests, agent_count, thread_system, config);
        } else {
            _ = try updatePathfindingInline(system, requests, agent_count, config);
        }
        requests = &empty;
        if (system.pending.len == 0) return;
    }
    return error.TestRoutesStalled;
}

// A cached path's stored cells: its cells, and its levels (null: all on `level`).
const StoredPath = struct {
    cells: []const u32,
    levels: ?[]const u16,
    level: u16,

    pub fn levelAt(self: StoredPath, index: usize) u16 {
        return if (self.levels) |column| column[index] else self.level;
    }
};

pub fn storedPath(system: *const PathfindingSystem, owner: u32) StoredPath {
    const payload = system.completed.core.records.items[owner].extra;
    const words = system.completed.storedWords(owner);
    if (payload.stitched_len != 0) {
        const view = types.stitchedView(words, payload.stitched_len);
        return .{ .cells = view.cells, .levels = view.levels, .level = 0 };
    }
    return .{ .cells = words[0..payload.path_len], .levels = null, .level = payload.path_level };
}

const Registration = struct {
    key: u64,
    owner: u32,
    start: u32,

    fn lessThan(_: void, a: Registration, b: Registration) bool {
        if (a.key != b.key) return a.key < b.key;
        if (a.owner != b.owner) return a.owner < b.owner;
        return a.start < b.start;
    }
};

/// The registry holds exactly the runs of every live cached path, each in its key's shard,
/// with every key's count its list's length and every owner chain naming its own live
/// owner; the owner log is empty.
pub fn expectRegistryMatchesCache(system: *const PathfindingSystem) !void {
    try std.testing.expectEqual(@as(usize, 0), system.completed.core.ownerLog().len);
    const allocator = std.testing.allocator;
    var expected: std.ArrayList(Registration) = .empty;
    defer expected.deinit(allocator);
    var actual: std.ArrayList(Registration) = .empty;
    defer actual.deinit(allocator);
    const geometry = system.graph.chunkGeometry();
    for (system.completed.core.records.items, 0..) |record, owner_index| {
        if (!record.live) continue;
        const owner: u32 = @intCast(owner_index);
        const path = storedPath(system, owner);
        const starts = try allocator.alloc(u16, @max(path.cells.len, 1));
        defer allocator.free(starts);
        var counts: [registry_shard_count]u32 = @splat(0);
        const run_count = solve.splitRuns(geometry, path.cells, path.levels, path.level, starts, &counts);
        for (starts[0..run_count]) |start| try expected.append(allocator, .{ .key = chunkKey(path.levelAt(start), geometry.chunkOfCell(path.cells[start])), .owner = owner, .start = start });
    }
    for (&system.path_index, 0..) |*shard, shard_index| {
        for (shard.slot_keys, 0..) |key, slot| {
            if (key == std.math.maxInt(u64)) continue;
            try std.testing.expectEqual(shard_index, registryShard(key));
            var length: u32 = 0;
            var entry = shard.slot_heads[slot];
            while (entry != no_entry) : (entry = shard.entry_next[entry]) {
                length += 1;
                try actual.append(allocator, .{ .key = key, .owner = shard.entry_owner[entry], .start = shard.entry_order[entry] });
            }
            try std.testing.expect(length != 0);
            try std.testing.expectEqual(length, shard.slot_counts[slot]);
        }
        try std.testing.expect(shard.owner_heads.items.len >= system.completed.logicalCapacity());
        for (shard.owner_heads.items, 0..) |owner_head, owner| {
            var entry = owner_head;
            while (entry != no_entry) : (entry = shard.entry_owner_next[entry]) {
                try std.testing.expectEqual(@as(u32, @intCast(owner)), shard.entry_owner[entry]);
                try std.testing.expect(system.completed.core.records.items[owner].live);
            }
        }
    }
    std.mem.sort(Registration, expected.items, {}, Registration.lessThan);
    std.mem.sort(Registration, actual.items, {}, Registration.lessThan);
    try std.testing.expectEqualSlices(Registration, expected.items, actual.items);
}

/// Two systems' registries hold the same keys in the same slots and the same lists in the
/// same order.
pub fn expectSameRegistry(a: *const PathfindingSystem, b: *const PathfindingSystem) !void {
    for (&a.path_index, &b.path_index) |*shard_a, *shard_b| {
        try std.testing.expectEqualSlices(u64, shard_a.slot_keys, shard_b.slot_keys);
        for (shard_a.slot_keys, 0..) |key, slot| {
            if (key == std.math.maxInt(u64)) continue;
            var entry_a = shard_a.slot_heads[slot];
            var entry_b = shard_b.slot_heads[slot];
            while (entry_a != no_entry or entry_b != no_entry) {
                try std.testing.expect(entry_a != no_entry and entry_b != no_entry);
                try std.testing.expectEqual(shard_a.entry_owner[entry_a], shard_b.entry_owner[entry_b]);
                try std.testing.expectEqual(shard_a.entry_order[entry_a], shard_b.entry_order[entry_b]);
                entry_a = shard_a.entry_next[entry_a];
                entry_b = shard_b.entry_next[entry_b];
            }
        }
    }
}

/// Two systems' caches hold the same entries under the same owner ids and probe slots,
/// with the same stored cells.
pub fn expectSameCache(a: *const PathfindingSystem, b: *const PathfindingSystem) !void {
    try std.testing.expectEqual(a.completed.count(), b.completed.count());
    try std.testing.expectEqual(a.completed.logicalCapacity(), b.completed.logicalCapacity());
    for (a.completed.core.slots.items, b.completed.core.slots.items) |slot_a, slot_b| {
        try std.testing.expectEqual(slot_a.occupied, slot_b.occupied);
        if (slot_a.occupied) try std.testing.expectEqual(slot_a.payload_index, slot_b.payload_index);
    }
    for (a.completed.core.records.items, b.completed.core.records.items, 0..) |record_a, record_b, owner| {
        try std.testing.expectEqual(record_a.live, record_b.live);
        if (!record_a.live) continue;
        try std.testing.expect(std.meta.eql(a.completed.core.keyOf(@intCast(owner)), b.completed.core.keyOf(@intCast(owner))));
        try std.testing.expectEqual(record_a.stamp, record_b.stamp);
        try std.testing.expectEqualDeep(record_a.extra, record_b.extra);
        const words = types.storedPathWords(record_a.extra.path_len, record_a.extra.stitched_len);
        try std.testing.expectEqualSlices(u32, a.completed.storedWords(owner)[0..words], b.completed.storedWords(owner)[0..words]);
    }
}

/// Sets each (x, y) of `cells` on the obstacle layer to `tile` and records it for nav.
pub fn setRegistryCells(system: *PathfindingSystem, fixture: *RegistryWorld, cells: []const [2]u16, tile: TileId) !void {
    for (cells) |cell| {
        const changed = (try fixture.world.setDenseTile(fixture.obstacle, cell[0], cell[1], tile)) orelse continue;
        try recordTileChange(system, &fixture.world, changed);
    }
}

/// Points every allocator `system` uses (its own, its graph's, and each registry shard's) at
/// `allocator`.
pub fn setSystemAllocators(system: *PathfindingSystem, allocator: std.mem.Allocator) void {
    system.allocator = allocator;
    system.graph.allocator = allocator;
    for (&system.path_index) |*shard| shard.allocator = allocator;
}

/// A fixed-range threaded control: one item per range, so every stage with two or more items
/// runs on workers.
pub const fixed_threads_config = PathfindingConfig{ .adaptive = false, .items_per_range = 1 };

/// Work units of a registry flush over `ops` logged ops and `adds` pending registrations:
/// every pair weighs the whole log, its adds, and one.
pub fn flushUnits(ops: usize, adds: usize) usize {
    return registry_shard_count * (ops + 1) + adds;
}

/// Two registry systems filled alike with long and inline results, for a shrink to the
/// floor's 32 entries.
pub fn shrinkFixture(data: *const DataSystem, fixture: *const RegistryWorld, requester: EntityId, participants: usize) !PathfindingSystem {
    var system = try registrySystemWith(data, &fixture.world, 16, .{ .stored_path_cells = 8, .participants = participants });
    errdefer system.deinit();
    for (0..4) |batch| try solveRegistryRoutes(&system, requester, 24, batch * 16, 16, 16, null, .{});
    try std.testing.expectEqual(@as(usize, 64), system.completed.count());
    return system;
}

/// The agent count the request-side stage tests pass to `update`.
pub const intake_test_agents: usize = 40;

/// Two updates' request-side stats match, field by field.
pub fn expectRequestStatsEqual(expected: PathfindingStats, actual: PathfindingStats) !void {
    inline for (.{
        "accepted_requests", "duplicate_requests",  "pending_requests",    "dropped_requests",
        "cache_hits",        "available_results",   "unavailable_results", "group_field_samples",
        "goal_projected",    "group_fields_built",  "group_field_reuses",  "group_field_rebuild_throttled",
        "cache_evictions",   "distinct_group_keys", "goal_fallbacks",      "group_field_evictions",
    }) |name| {
        try std.testing.expectEqual(@field(expected, name), @field(actual, name));
    }
}

/// Same pending queue, group tallies, and cached result slots.
pub fn expectRequestStateEqual(expected: *const PathfindingSystem, actual: *const PathfindingSystem) !void {
    try expectQueuesEqual(expected, actual);
    try std.testing.expectEqual(expected.completed.core.slots.items.len, actual.completed.core.slots.items.len);
    for (expected.completed.core.slots.items, actual.completed.core.slots.items) |expected_slot, actual_slot| {
        try std.testing.expectEqualDeep(expected_slot, actual_slot);
    }
}

/// Same pending queue in order (each key registered) and group tallies in order.
pub fn expectQueuesEqual(expected: *const PathfindingSystem, actual: *const PathfindingSystem) !void {
    try std.testing.expectEqual(expected.pending.len, actual.pending.len);
    for (0..expected.pending.len) |index| {
        try std.testing.expectEqualDeep(expected.pending.at(index), actual.pending.at(index));
        try std.testing.expect(actual.pending_keys.contains(expected.pending.at(index).key));
    }
    try std.testing.expectEqual(expected.group_requests.items.len, actual.group_requests.items.len);
    for (expected.group_requests.items, actual.group_requests.items) |expected_tally, actual_tally| {
        try std.testing.expectEqualDeep(expected_tally, actual_tally);
    }
}

/// Each goal requested by three agents; the schedule's step `step` uses `goals[step]`.
pub fn writeGroupGoals(stream: *RangeOutputStream(PathRequest), entity: EntityId, goals: []const math.Vec2) !void {
    stream.clearRetainingCapacity();
    for (goals) |goal| {
        for (0..3) |member| {
            try appendPathRequest(stream, .{ .entity = entity, .kind = .group, .start = cellWorld(@intCast(member), 2), .goal = goal });
        }
    }
}

/// Two systems' group fields match slot by slot: state, key, build progress, and every
/// cell's entry, with each non-empty field in its field key map slot.
pub fn expectGroupFieldsEqual(expected: *const PathfindingSystem, actual: *const PathfindingSystem) !void {
    for (expected.group_fields.items, actual.group_fields.items, 0..) |*expected_field, *actual_field, slot| {
        if (expected_field.state != .empty) try std.testing.expectEqual(@as(?usize, slot), actual.group_field_keys.find(actual_field.key));
        try std.testing.expectEqual(expected_field.state, actual_field.state);
        try std.testing.expectEqualDeep(expected_field.key, actual_field.key);
        try std.testing.expectEqual(expected_field.goal_index, actual_field.goal_index);
        try std.testing.expectEqual(expected_field.generation, actual_field.generation);
        try std.testing.expectEqual(expected_field.current_distance, actual_field.current_distance);
        try std.testing.expectEqual(expected_field.pushed_count, actual_field.pushed_count);
        try std.testing.expectEqual(expected_field.fresh_this_step, actual_field.fresh_this_step);
        try std.testing.expectEqual(expected_field.last_build_step, actual_field.last_build_step);
        try std.testing.expectEqual(expected_field.used_blocks, actual_field.used_blocks);
        const grid = expected.graph.grid(expected_field.key.goal_level) orelse continue;
        for (0..grid.cellCount()) |cell| {
            try std.testing.expectEqualDeep(expected_field.lookup(grid, cell), actual_field.lookup(grid, cell));
        }
    }
}

/// A 64x64-cell system in 4-cell nav chunks whose fields cross many chunks, so cold field
/// pools stall and grow while they build.
pub fn stallingFieldCapacity(participant_count: usize) PathfindingCapacity {
    var capacity = baselineCapacity();
    capacity.max_agent_budget = 64;
    capacity.max_group_fields = 4;
    capacity.group_field_build_budget = 64;
    capacity.group_field_rebuild_min_steps = 1;
    capacity.nav_chunk_tiles = 4;
    capacity.worker_participant_count = participant_count;
    return capacity;
}

/// Four far-apart goals on the stalling-field world, one per field slot.
pub const stalling_field_goals = [_]math.Vec2{ cellWorld(5, 58), cellWorld(58, 58), cellWorld(58, 5), cellWorld(30, 30) };

/// A dense multi-chunk edit's terrain events: runs of tile flips that straddle range
/// boundaries, obstacle rects, and terrain events nav ignores (tile changes that keep their
/// blocking, and a non-commit-stage rect).
pub fn navMarkTestEvents(allocator: std.mem.Allocator, world: *const WorldSystem) !std.ArrayList(SimulationEvent) {
    var events: std.ArrayList(SimulationEvent) = .empty;
    errdefer events.deinit(allocator);
    for (0..world.height) |y| for (0..world.width) |x| {
        if ((x + y) % 3 == 0) continue;
        try events.append(allocator, .{ .stage = .structural_commit, .payload = .{ .world_tile_changed = .{
            .level = @intCast((x / 6) % 2),
            .x = @intCast(x),
            .y = @intCast(y),
            .old_tile_id = 0,
            .new_tile_id = 1,
            .old_blocks_movement = false,
            .new_blocks_movement = (x + y) % 5 != 0,
        } } });
        if (x == 5 and y % 4 == 0) {
            try events.append(allocator, .{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{ .level = 0, .min_x = 1, .min_y = @intCast(y), .max_x_exclusive = 9, .max_y_exclusive = @intCast(y + 2) } } });
            try events.append(allocator, .{ .stage = .domain_reaction, .payload = .{ .world_obstacle_changed = .{ .level = 1, .min_x = 0, .min_y = 0, .max_x_exclusive = 12, .max_y_exclusive = 12 } } });
        }
    };
    return events;
}

/// Side, in tiles, of the pocket test world.
pub const pocket_world_side: u16 = 32;
/// Side, in tiles, of the pocket sealed at its origin.
pub const pocket_cells: u16 = 10;

/// A registry world `side` tiles a side with a `pocket`-tile pocket at the origin, closed by
/// a wall column x = `pocket` (rows 0 to `pocket`) and a wall row y = `pocket`.
pub fn pocketWorld(meta: *const WorldTilesetMeta, side: u16, pocket: u16) !RegistryWorld {
    var fixture = try registryWorld(meta, side);
    errdefer fixture.world.deinit();
    for (0..pocket + 1) |y| _ = try fixture.world.setDenseTile(fixture.obstacle, pocket, @intCast(y), fixture.tree);
    for (0..pocket) |x| _ = try fixture.world.setDenseTile(fixture.obstacle, @intCast(x), pocket, fixture.tree);
    return fixture;
}

/// Cell `index` of the pocket, row by row, as a world position.
pub fn pocketGoal(index: usize) math.Vec2 {
    return tileCenter(@intCast(index % pocket_cells), @intCast(index / pocket_cells));
}

/// One serial update requesting a path from `start` to `goal`.
pub fn solveFrom(system: *PathfindingSystem, requester: EntityId, start: math.Vec2, goal: math.Vec2, config: PathfindingConfig) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
    return updatePathfindingInline(system, &stream, 16, config);
}

/// Builds a 12x12-tile single-level world with a vertical tree wall at column 5 that
/// leaves open gaps at the given rows. The base floor is open grass, so the only way
/// across the wall is through a gap. Returns the world plus the obstacle layer index
/// so a test can flip the gap cells.
pub fn buildCorridorWorld(meta: *const WorldTilesetMeta, open_rows: []const u16) !struct { world: WorldSystem, wall_layer: usize } {
    const grass = try requireTestTile(meta, "grass");
    const tree = try requireTestTile(meta, "tree_0");
    var world = try abstractTestWorld(meta, 384, 384);
    errdefer world.deinit();
    const wall_layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    var y: u16 = 0;
    while (y < 12) : (y += 1) {
        var open = false;
        for (open_rows) |row| {
            if (row == y) open = true;
        }
        if (open) continue;
        _ = try world.setDenseTile(wall_layer, 5, y, tree);
    }
    return .{ .world = world, .wall_layer = wall_layer };
}

/// One serial update with `requester`'s single individual request from `start` to `goal`.
pub fn solveStep(system: *PathfindingSystem, requester: EntityId, start: math.Vec2, goal: math.Vec2) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    try appendPathRequest(&stream, .{ .entity = requester, .start = start, .goal = goal });
    return updatePathfindingInline(system, &stream, 8, .{});
}
