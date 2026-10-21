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
const SimulationEvent = @import("../../simulation.zig").SimulationEvent;
const WorldTileChangedEvent = @import("../../simulation.zig").WorldTileChangedEvent;
const NavUpdateStats = @import("types.zig").NavUpdateStats;
const PathfindingSystem = @import("system.zig").PathfindingSystem;
const SearchScratch = @import("scratch.zig").SearchScratch;
const Tier1Scratch = @import("scratch.zig").Tier1Scratch;
const CorridorScratch = @import("scratch.zig").CorridorScratch;
const ResultCache = @import("caches.zig").ResultCache;
const KeySet = @import("caches.zig").KeySet;
const GroupKeyMap = @import("caches.zig").GroupKeyMap;
const GoalTable = @import("goal_table.zig").GoalTable;
const GroupField = @import("group_field.zig").GroupField;
const IntakeRecordList = @import("intake.zig").IntakeRecordList;
const GroupKeyCountList = @import("intake.zig").GroupKeyCountList;
const IntakeTallyList = @import("intake.zig").IntakeTallyList;
const RegRecordList = @import("publish.zig").RegRecordList;
const PublishBandList = @import("publish.zig").PublishBandList;
const PublishBand = @import("publish.zig").PublishBand;
const NavMarkList = @import("nav_reaction.zig").NavMarkList;
const NavMarkTallyList = @import("nav_reaction.zig").NavMarkTallyList;
const NavMarkTally = @import("nav_reaction.zig").NavMarkTally;
const nav_mark_range_alignment_items = @import("nav_reaction.zig").nav_mark_range_alignment_items;
const EvictItemList = @import("eviction.zig").EvictItemList;
const HitList = @import("eviction.zig").HitList;
const caches = @import("caches.zig");
const ResizeMove = caches.ResizeMove;
const CrossingScratch = @import("scratch.zig").CrossingScratch;
const AbstractScratch = @import("scratch.zig").AbstractScratch;
const CrossingBoxSlot = @import("scratch.zig").CrossingBoxSlot;
const CrossingLevelSlot = @import("scratch.zig").CrossingLevelSlot;
const AbstractSlot = @import("scratch.zig").AbstractSlot;
const SearchSlot = @import("scratch.zig").SearchSlot;
const OpenNode = types.OpenNode;
const StitchedCell = types.StitchedCell;
const OwnerOp = types.OwnerOp;
const default_nav_chunk_tiles = types.default_nav_chunk_tiles;
const hashTableSlots = @import("../../stamped_table.zig").hashTableSlots;
const scan_range_alignment_items = @import("goal_table.zig").scan_range_alignment_items;
const cell_block_bytes = @import("nav_grid.zig").cell_block_bytes;
const NavLevelGraph = @import("nav_graph.zig").NavLevelGraph;
const NavPortal = @import("nav_graph.zig").NavPortal;
const NavLink = @import("nav_graph.zig").NavLink;
const PatchInfo = @import("nav_graph.zig").PatchInfo;
const borderPortalBound = @import("nav_graph.zig").borderPortalBound;
const record_row_bytes = @import("nav_graph.zig").record_row_bytes;
const key_window_alignment = @import("nav_graph.zig").key_window_alignment;
const plan_streams = @import("nav_graph.zig").plan_streams;
const LevelCrossings = @import("link_bounds.zig").LevelCrossings;
const NodeRow = @import("connectivity.zig").NodeRow;
const default_flood_window = @import("connectivity.zig").default_flood_window;
const default_flood_budget_cap = @import("connectivity.zig").default_flood_budget_cap;
const span_words = @import("connectivity_closure.zig").span_words;
const bitSetBytesFor = @import("../chunk_list_map.zig").bitSetBytesFor;
const OrderedIndexSet = @import("../chunk_list_map.zig").OrderedIndexSet;
const assertFieldsClassified = @import("../chunk_list_map.zig").assertFieldsClassified;
const maxRangeCount = @import("../../../app/thread_system.zig").maxRangeCount;
const thread_shared_record_alignment = @import("../../../app/thread_system.zig").thread_shared_record_alignment;
const RegRecord = types.RegRecord;
const PathSolveResult = types.PathSolveResult;
const GroupRequestTally = types.GroupRequestTally;
const PendingRequest = types.PendingRequest;
const NavMark = types.NavMark;
const EvictItem = types.EvictItem;
const IntakeRecord = types.IntakeRecord;
const GroupKeyCount = types.GroupKeyCount;
const IntakeTally = types.IntakeTally;
const registry_shard_count = types.registry_shard_count;
const reg_window_alignment_items = types.reg_window_alignment_items;
const hit_window_alignment_items = types.hit_window_alignment_items;
const intake_range_alignment_items = types.intake_range_alignment_items;
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
const PathStatus = @import("types.zig").PathStatus;
const PathfindingConfig = @import("types.zig").PathfindingConfig;
const registryShard = @import("types.zig").registryShard;
const chunkKey = @import("../chunk_list_map.zig").chunkKey;
const no_entry = @import("../chunk_list_map.zig").no_entry;
const empty_block = @import("../chunk_list_map.zig").empty_block;

/// `OrderedIndexSet.residentBytes` of a set reserved for indices below `bits`: its tiers as
/// `reserve` builds them.
fn orderedIndexSetStorageBytesBound(bits: usize) usize {
    var bytes: usize = 0;
    var tier_bits = bits;
    while (true) {
        bytes +|= bitSetBytesFor(tier_bits);
        if (tier_bits <= @bitSizeOf(OrderedIndexSet.Word)) break;
        tier_bits = OrderedIndexSet.maskCount(tier_bits);
    }
    return bytes;
}

/// `NavStorageContent` of `world` from its composed chunk forms and link endpoint counts,
/// for a nav whose chunks are the world's: O(levels x chunks). Static colliders are not
/// counted; a nav over static bodies needs their chunks counted mixed.
pub fn navStorageContentOf(world: *const WorldSystem) NavStorageContent {
    var content = NavStorageContent{};
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
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
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
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    try recordTileChange(system, world, change);
    return system.applyBufferedNavUpdates(colliders, world, &serial_threads);
}

/// `recordTileEdits`, then applies every pending nav change serially.
pub fn applyTileEdits(system: *PathfindingSystem, colliders: *const StaticColliderSystem, world: *const WorldSystem, edits: []const TileEdit) !NavUpdateStats {
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
    try recordTileEdits(system, world, edits);
    return system.applyBufferedNavUpdates(colliders, world, &serial_threads);
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
fn expectClosureConsistent(graph: *const NavGraph, world: *const WorldSystem) !void {
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
    var serial_threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer serial_threads.deinit();
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
    const result = system.applyBufferedNavUpdates(&no_colliders, &fixture.world, &serial_threads);
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
    _ = try system.applyBufferedNavUpdates(&no_colliders, &fixture.world, &serial_threads);
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
    try stageTestPath(system, key, path, step, stats);
    _ = try publish.flushRegistry(system, null, null);
}

/// `publishTestPath` without its flush: the path is claimed and stored, and its runs wait
/// in one publish range for the caller's flush.
pub fn stageTestPath(system: *PathfindingSystem, key: PathQueryKey, path: []const u32, step: u32, stats: *PathfindingStats) !void {
    system.completed.core.beginPublish();
    const claimed = system.completed.claim(key, path.len, 0, 0, .{ .level = 0, .cell = path[path.len - 1] }, path[path.len - 1], step, stats);
    @memcpy(system.completed.destination(claimed)[0..path.len], path);
    const starts = try std.testing.allocator.alloc(u16, path.len);
    defer std.testing.allocator.free(starts);
    var counts: [registry_shard_count]u32 = @splat(0);
    const geometry = system.graph.chunkGeometry();
    const run_count = solve.splitRuns(geometry, path, null, 0, starts, &counts);
    var records: std.ArrayList(RegRecord) = .empty;
    defer records.deinit(std.testing.allocator);
    for (starts[0..run_count]) |start| {
        try records.append(std.testing.allocator, .{
            .key = chunkKey(0, geometry.chunkOfCell(path[start])),
            .owner = claimed.owner,
            .order = start,
        });
    }
    try stageRegistryRuns(system, records.items);
}

/// One publish range of `records`, shard-ordered the way `publish_copy` writes them, with
/// each shard's inverse pool reserved for the adds. The caller flushes.
pub fn stageRegistryRuns(system: *PathfindingSystem, records: []const RegRecord) !void {
    var counts: [registry_shard_count]u32 = @splat(0);
    for (records) |record| counts[registryShard(record.key)] += 1;
    if (system.publish_bands.capacity < 1) try system.publish_bands.ensureTotalCapacity(system.allocator, 1);
    if (system.publish_range_bases.capacity < 1) try system.publish_range_bases.ensureTotalCapacity(system.allocator, 1);
    if (system.reg_buckets.capacity < records.len) try system.reg_buckets.ensureTotalCapacity(system.allocator, @max(records.len, 1));
    system.publish_bands.items.len = 1;
    system.publish_range_bases.items.len = 1;
    system.publish_range_bases.items[0] = 0;
    system.reg_buckets.items.len = records.len;
    var cursors: [registry_shard_count]usize = undefined;
    var next: usize = 0;
    for (&cursors, counts) |*cursor, count| {
        cursor.* = next;
        next += count;
    }
    for (records) |record| {
        const shard = registryShard(record.key);
        system.reg_buckets.items[cursors[shard]] = record;
        cursors[shard] += 1;
    }
    system.publish_bands.items[0] = .{ .counts = counts };
    system.publish_ranges = 1;
    var shard_registrations: [registry_shard_count]usize = undefined;
    for (&shard_registrations, counts) |*total, count| total.* = count;
    _ = try publish.reserveRegistryRuns(system, shard_registrations);
}

/// Solves `goals` from cellWorld(1, 2) in one serial step with the default budgets.
pub fn solveIndividualGoals(system: *PathfindingSystem, requester: EntityId, goals: []const math.Vec2, agent_count: usize) !PathfindingStats {
    var stream = RangeOutputStream(PathRequest).init(std.testing.allocator);
    defer stream.deinit();
    for (goals) |goal| try appendIndividual(&stream, requester, goal);
    return updatePathfindingInline(system, &stream, agent_count, .{});
}

/// Ages every cached result past the cache TTL: the next request of its goal removes it at
/// intake and solves it again in the same step, so that step's flush retires and re-adds
/// its registrations together and a chunk holding them keeps its block. The second such
/// step of the same requests finds every payload grown for both.
pub fn expireCachedResults(system: *PathfindingSystem) void {
    for (system.completed.core.records.items) |*record| {
        if (record.live) record.stamp -%= types.default_cache_ttl_steps + 1;
    }
}

/// Ages `key`'s cached result past the cache TTL (`expireCachedResults`).
pub fn expireCachedResult(system: *PathfindingSystem, key: PathQueryKey) void {
    const owner = cacheOwnerOf(system.completed.core, key).?;
    system.completed.core.records.items[owner].stamp -%= types.default_cache_ttl_steps + 1;
}

/// The last update published every goal's level-0 result, and each reads available from
/// cellWorld(1, 2), the start `solveIndividualGoals` requests from.
pub fn expectGoalsSolved(system: *const PathfindingSystem, goals: []const math.Vec2) !void {
    for (goals) |goal| {
        try std.testing.expect(solvedLastStep(system, goal));
        try std.testing.expectEqual(PathStatus.available, statusOf(system, cellWorld(1, 2), goal));
    }
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

/// Level-0 `start`'s path status toward level-0 `goal` for the default agent class.
pub fn statusOf(system: *const PathfindingSystem, start: math.Vec2, goal: math.Vec2) PathStatus {
    return system.statusForWorld(0, start, 0, goal, .default, null).status;
}

/// The step `key`'s cached result was stored at (its solve's publish); null when none is
/// cached. A cache hit leaves it as it was.
pub fn cachedStep(system: *const PathfindingSystem, key: PathQueryKey) ?u32 {
    const slot = system.completed.slotIndex(key) orelse return null;
    return system.completed.core.records.items[system.completed.core.slots.items[slot].payload_index].stamp;
}

/// Whether the last update's publish stored the result for `goal`'s level-0 default-class
/// key: a solve, never a cache hit.
pub fn solvedLastStep(system: *const PathfindingSystem, goal: math.Vec2) bool {
    const key = system.graph.keyForWorld(0, goal, .default) orelse return false;
    const stored_step = cachedStep(system, key) orelse return false;
    return stored_step == system.step_counter;
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
    const directory = &system.path_index.directory;
    var level: u32 = 0;
    while (level < directory.levelCount()) : (level += 1) {
        var slot: usize = 0;
        while (slot < directory.slotCount(level)) : (slot += 1) {
            const key = chunkKey(@intCast(level), @intCast(slot));
            const run = publish.registrationRun(directory, key);
            if (run.len == 0) continue;
            for (run.owner[0..run.len], run.order[0..run.len], run.inverse[0..run.len], 0..) |owner, start, node, index| {
                try actual.append(allocator, .{ .key = key, .owner = owner, .start = start });
                const pool = &system.path_index.pools[registryShard(key)];
                try std.testing.expectEqual(key, pool.node_chunk[node]);
                try std.testing.expectEqual(@as(u32, @intCast(index)), pool.node_index[node]);
            }
        }
    }
    for (&system.path_index.pools) |*pool| {
        try std.testing.expect(pool.owner_heads.items.len >= system.completed.logicalCapacity());
        for (pool.owner_heads.items, 0..) |head, owner| {
            var node = head.node;
            var seen: u32 = 0;
            while (node != no_entry) : (node = pool.node_next[node]) {
                seen += 1;
                const key = pool.node_chunk[node];
                const run = publish.registrationRun(directory, key);
                try std.testing.expectEqual(@as(u32, @intCast(owner)), run.owner[pool.node_index[node]]);
                try std.testing.expect(system.completed.core.records.items[owner].live);
            }
            try std.testing.expectEqual(head.len, seen);
        }
    }
    std.mem.sort(Registration, expected.items, {}, Registration.lessThan);
    std.mem.sort(Registration, actual.items, {}, Registration.lessThan);
    try std.testing.expectEqualSlices(Registration, expected.items, actual.items);
}

/// Two systems' registries hold the same keys in the same slots and the same lists in the
/// same order.
pub fn expectSameRegistry(a: *const PathfindingSystem, b: *const PathfindingSystem) !void {
    const directory_a = &a.path_index.directory;
    const directory_b = &b.path_index.directory;
    try std.testing.expectEqual(directory_a.levelCount(), directory_b.levelCount());
    var level: u32 = 0;
    while (level < directory_a.levelCount()) : (level += 1) {
        try std.testing.expectEqual(directory_a.slotCount(level), directory_b.slotCount(level));
        var slot: usize = 0;
        while (slot < directory_a.slotCount(level)) : (slot += 1) {
            const key = chunkKey(@intCast(level), @intCast(slot));
            try std.testing.expectEqual(directory_a.slot(level, slot) == empty_block, directory_b.slot(level, slot) == empty_block);
            const run_a = publish.registrationRun(directory_a, key);
            const run_b = publish.registrationRun(directory_b, key);
            try std.testing.expectEqualSlices(u32, run_a.owner[0..run_a.len], run_b.owner[0..run_b.len]);
            try std.testing.expectEqualSlices(u32, run_a.order[0..run_a.len], run_b.order[0..run_b.len]);
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

/// Points every allocator `system` uses (its own and its graph's) at `allocator`. The
/// registry's directory and inverse pools allocate through the system allocator.
pub fn setSystemAllocators(system: *PathfindingSystem, allocator: std.mem.Allocator) void {
    system.allocator = allocator;
    system.graph.allocator = allocator;
}

/// A fixed-range threaded control: one item per range, so every stage with two or more items
/// runs on workers.
pub const fixed_threads_config = PathfindingConfig{ .adaptive = false, .items_per_range = 1 };

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

// ---- Request-side byte accounting -------------------------------------------------------

/// The request side's storage by part: per-participant search scratch, the tier-1
/// corridor pool, the result cache with the solve slots' path stripes and records, the
/// path registry with its registration windows, the goal table, the request queues and
/// per-step lists (pending queue and keys, intake staging, solve slots, group tallies and
/// field headers, publish windows, resize snapshots), and the nav change scratch (marks
/// and their staging, the eviction scratch). With the graph and the group fields' pools,
/// every allocation the system owns.
pub const RequestStorage = struct {
    search: usize = 0,
    tier1: usize = 0,
    results: usize = 0,
    registry: usize = 0,
    goals: usize = 0,
    queues: usize = 0,
    change_scratch: usize = 0,
};

/// What sizes the request side for `requestStorageBytesBound`, beyond its capacity.
pub const RequestShape = struct {
    /// The most cached results whose path outgrows the inline stripe at once.
    long_results: usize = std.math.maxInt(usize),
    /// The most registry runs (chunk-local stretches of a stored path) one result holds;
    /// null is one per stored cell, the most a plain or stitched path holds.
    runs_per_result: ?usize = null,
    /// Chunks over every level. The registry directory opens one slot per chunk when
    /// the nav levels open, and a registry key is a chunk, so keys never pass it.
    chunks: usize = std.math.maxInt(usize),
    /// Open nav levels.
    levels: usize,
    /// The most nav marks recorded between two nav batches (a terrain record's events or
    /// two per static change), and the most chunk keys one batch changes.
    marks: usize = 0,
    batch_keys: usize = 0,
};

/// `RequestStorage` held now (allocated capacity). O(participants + shards + the result
/// cache's pages).
pub fn requestResidentBytes(system: *const PathfindingSystem) RequestStorage {
    var storage = RequestStorage{
        .search = system.scratch_slots.capacity * @sizeOf(SearchScratch),
        .tier1 = system.tier1_scratch.capacity * @sizeOf(Tier1Scratch),
        .results = resultCacheResidentBytes(&system.completed) + system.worker_path_pool.capacity * @sizeOf(u32) +
            system.worker_run_starts.capacity * @sizeOf(u16) + system.solved_paths.capacity * @sizeOf(PathfindingSystem.SolvedPath) +
            system.publish_records.capacity * @sizeOf(?ResultCache.Claimed),
        .registry = system.reg_buckets.capacity * @sizeOf(RegRecord),
        .goals = goalTableResidentBytes(&system.goals),
        .queues = system.pending.buffer.len * @sizeOf(PendingRequest) + keySetResidentBytes(&system.pending_keys) +
            system.intake_records.capacity * @sizeOf(IntakeRecord) + system.intake_group_counts.capacity * @sizeOf(GroupKeyCount) +
            system.intake_tallies.capacity * @sizeOf(IntakeTally) + system.solve_results.capacity * @sizeOf(PathSolveResult) +
            system.solve_indices.capacity * @sizeOf(usize) + system.solve_tier1_slot.capacity * @sizeOf(u32) +
            system.group_fields.capacity * @sizeOf(GroupField) + groupKeyMapResidentBytes(&system.group_field_keys) +
            system.group_field_slots.capacity * @sizeOf(usize) + system.group_requests.capacity * @sizeOf(GroupRequestTally) +
            groupKeyMapResidentBytes(&system.group_key_map) + system.publish_range_bases.capacity * @sizeOf(usize) +
            system.publish_bands.capacity * @sizeOf(PublishBand) + system.rotate_back_scratch.capacity * @sizeOf(PendingRequest) +
            system.resize_pending_snapshot.capacity * @sizeOf(PendingRequest) + system.resize_group_snapshot.capacity * @sizeOf(GroupRequestTally),
        .change_scratch = system.nav_marks.capacity * @sizeOf(NavMark) + system.nav_mark_staging.capacity * @sizeOf(NavMark) +
            system.nav_mark_tallies.capacity * @sizeOf(NavMarkTally) + system.evict_items.capacity * @sizeOf(EvictItem) +
            system.evict_hits.capacity * @sizeOf(u32),
    };
    for (system.scratch_slots.items) |*scratch| storage.search += searchScratchResidentBytes(scratch);
    for (system.tier1_scratch.items) |*entry| storage.tier1 += corridorScratchResidentBytes(&entry.corridor);
    storage.registry += registryResidentBytes(&system.path_index);
    return storage;
}

fn registryResidentBytes(index: *const publish.PathIndex) usize {
    comptime assertFieldsClassified(publish.PathIndex, &.{
        "directory", "pools", "growth", "compact", "fresh", "plan", "plan_replacement", "shard_ops", "emptied",
    }, &.{ "growth_base", "compact_base", "counts", "shard_op_base", "shard_op_count", "retire_node_count", "emptied_step" });
    var bytes = directoryResidentBytes(&index.directory);
    bytes += index.growth.capacity * @sizeOf(FieldElem(publish.PathIndex, "growth")) + index.compact.capacity * @sizeOf(FieldElem(publish.PathIndex, "compact"));
    bytes += index.fresh.capacity * @sizeOf(FieldElem(publish.PathIndex, "fresh")) + index.emptied.capacity * @sizeOf(FieldElem(publish.PathIndex, "emptied"));
    bytes += retirePlanResidentBytes(&index.plan) + index.shard_ops.capacity * @sizeOf(FieldElem(publish.PathIndex, "shard_ops"));
    if (index.plan_replacement) |*replacement| bytes += retirePlanResidentBytes(replacement);
    for (&index.pools) |*pool| bytes += inversePoolResidentBytes(pool);
    return bytes;
}

// Bytes of the owner log's plan: its owner-id columns and its per-op plans.
fn retirePlanResidentBytes(plan: *const publish.RetirePlan) usize {
    const Plan = publish.RetirePlan;
    comptime assertFieldsClassified(Plan, &.{ "ids", "at", "origin", "shards", "rename_to", "ops" }, &.{});
    return plan.ids.capacity * @sizeOf(FieldElem(Plan, "ids")) + plan.at.capacity * @sizeOf(FieldElem(Plan, "at")) +
        plan.origin.capacity * @sizeOf(FieldElem(Plan, "origin")) + plan.shards.capacity * @sizeOf(FieldElem(Plan, "shards")) +
        plan.rename_to.capacity * @sizeOf(FieldElem(Plan, "rename_to")) + plan.ops.capacity * @sizeOf(FieldElem(Plan, "ops"));
}

/// Payload bytes plus inverse-pool bytes. Directory slots opened with the nav level are
/// not included: a publish grows the payloads and the node pools.
pub fn registryContentBytes(index: *const publish.PathIndex) usize {
    var bytes: usize = 0;
    for (index.directory.blocks.items) |block| bytes += block.bytes.len;
    for (&index.pools) |*pool| bytes += inversePoolResidentBytes(pool);
    return bytes;
}

// ---- Path registry byte counts ------------------------------------------------------------
// Built from the registry's own types: the directory's `Level` and `Block` records and
// slot columns, the inverse pools' node and head rows, and a payload's row bytes.

const RegistryDirectory = publish.RegistryDirectory;
const InversePool = publish.InversePool;
const DirectoryLevel = RegistryDirectory.Level;
const DirectoryBlock = RegistryDirectory.Block;
const InverseNodes = @FieldType(InversePool, "nodes");
const OwnerHead = FieldElem(InversePool, "owner_heads");
// Bytes of one chunk's directory columns: its block id and its pending count.
const directory_chunk_bytes = @sizeOf(@typeInfo(@FieldType(DirectoryLevel, "slots")).pointer.child) +
    @sizeOf(@typeInfo(@FieldType(DirectoryLevel, "pending")).pointer.child);

/// The element type of `T.field`: a std list's, a `MultiArrayList`'s row, or a slice's.
fn FieldElem(comptime T: type, comptime field: []const u8) type {
    const List = @FieldType(T, field);
    if (@typeInfo(List) == .pointer) return @typeInfo(List).pointer.child;
    if (@hasField(List, "items")) return @typeInfo(@FieldType(List, "items")).pointer.child;
    return @typeInfo(@TypeOf(List.get)).@"fn".return_type.?;
}

/// Bytes of a registry directory: its level list, each open level's slot and pending
/// columns, the block pool and its free ids, and every block's payload.
fn directoryResidentBytes(directory: *const RegistryDirectory) usize {
    comptime assertFieldsClassified(RegistryDirectory, &.{ "levels", "blocks", "block_free" }, &.{});
    var bytes = directory.levels.capacity * @sizeOf(DirectoryLevel) +
        directory.blocks.capacity * @sizeOf(DirectoryBlock) +
        directory.block_free.capacity * @sizeOf(FieldElem(RegistryDirectory, "block_free"));
    var level: u32 = 0;
    while (level < directory.levelCount()) : (level += 1) bytes += directory.slotCount(level) * directory_chunk_bytes;
    for (directory.blocks.items) |block| bytes += block.bytes.len;
    return bytes;
}

/// Bytes of one inverse pool: its node columns, free ids, and owner heads, including a
/// prepared or retired truncation.
fn inversePoolResidentBytes(pool: *const InversePool) usize {
    comptime assertFieldsClassified(InversePool, &.{ "nodes", "node_free", "owner_heads", "replacement", "retired" }, &.{ "node_next", "node_chunk", "node_index" });
    var bytes = InverseNodes.capacityInBytes(pool.nodes.capacity) +
        pool.node_free.capacity * @sizeOf(FieldElem(InversePool, "node_free")) +
        pool.owner_heads.capacity * @sizeOf(OwnerHead) +
        pool.retired.capacity * @sizeOf(OwnerHead);
    if (pool.replacement) |replacement| bytes += replacement.capacity * @sizeOf(OwnerHead);
    return bytes;
}

/// An over-estimate of one registry: `levels` level records and `chunks` chunks of
/// directory columns, a block per chunk holding registrations or held a step after they
/// retired (at most min(chunks, entries)) in a pool doubled ahead of need, a geometric payload for `entries`
/// registrations, and `shards` inverse pools whose nodes sum to `entries` and whose owner
/// heads hold `owners` ids. Saturates.
fn pooledStorageBytesBound(shards: usize, levels: usize, chunks: usize, entries: usize, owners: usize) usize {
    const blocks = @min(chunks, entries);
    // A payload's cap is a power of two at most twice the most registrations it held.
    const payload = (entries *| 2) *| publish.reg_row_bytes;
    const directory = listBytesBound(DirectoryLevel, levels) +| chunks *| directory_chunk_bytes +|
        listBytesBound(DirectoryBlock, blocks *| 2) +| listBytesBound(FieldElem(RegistryDirectory, "block_free"), blocks *| 2);
    const node_pool = InverseNodes.capacityInBytes(InverseNodes.growCapacity(entries *| 2)) +| shards *| InverseNodes.capacityInBytes(InverseNodes.growCapacity(0));
    const free_ids = pooledFreeIds(shards, entries);
    const heads = shards *| listBytesBound(OwnerHead, owners);
    // Count windows, growth and compact: one record per registration a flush adds or
    // retires, each shard's window starting on a cache line.
    const ChunkRef = FieldElem(publish.PathIndex, "compact");
    const windows = 2 *| listBytesBound(ChunkRef, entries *| 2 +| shards *| @divExact(thread_shared_record_alignment, @sizeOf(ChunkRef)));
    // Held emptied chunks: room for one per block of the pool.
    const emptied = listBytesBound(FieldElem(publish.PathIndex, "emptied"), blocks *| 2);
    // The owner log's plan: its owner-id columns, a plan per op of a log of
    // `ops_per_entry` ops per owner id, and the log bucketed by shard: an op's entries are
    // the shards its chain has nodes in, and each chain takes at most `ops_per_entry` ops,
    // so at most that many entries per inverse node and per owner id in each shard.
    const Plan = publish.RetirePlan;
    const plan = listBytesBound(FieldElem(Plan, "ids"), owners) +| listBytesBound(FieldElem(Plan, "at"), owners) +|
        listBytesBound(FieldElem(Plan, "origin"), owners) +| listBytesBound(FieldElem(Plan, "shards"), owners) +|
        listBytesBound(FieldElem(Plan, "rename_to"), owners) +| listBytesBound(FieldElem(Plan, "ops"), caches.ops_per_entry *| owners) +|
        listBytesBound(FieldElem(publish.PathIndex, "shard_ops"), @min(caches.ops_per_entry *| entries *| 2, shards *| caches.ops_per_entry *| owners));
    return directory +| payload +| node_pool +| free_ids +| heads +| windows +| emptied +| plan;
}

fn pooledFreeIds(shards: usize, entries: usize) usize {
    const Ids = std.ArrayList(u32);
    return Ids.growCapacity(entries *| 2) *| @sizeOf(u32) +| shards *| Ids.growCapacity(0) *| @sizeOf(u32);
}

/// An over-estimate of `requestResidentBytes` for a system never reserved past
/// `capacity` (its pools at the limits of `max_agent_budget` agents), whose results and
/// nav changes fit `shape`, and whose goal table grew from one intent per agent. Search
/// scratch and the tier-1 pool follow the node budgets, never level cells. The registry
/// is charged its shards' summed peaks at their pooled share: one key hash spreads any
/// workload's runs over the shards alike, so the shards peak together. Saturates.
pub fn requestStorageBytesBound(capacity: PathfindingCapacity, shape: RequestShape) RequestStorage {
    const limits = PathfindingSystem.deriveLimits(capacity, capacity.max_agent_budget);
    const participants = @max(@as(usize, 1), capacity.worker_participant_count);
    const tier0_abstract_nodes = @min(capacity.tier0_abstract_node_cap, capacity.max_abstract_nodes);
    const tier0_stitched_cells = @min(capacity.tier0_stitched_cell_cap, capacity.max_stitched_path_cells);
    const stripe_words = types.resultBlockWords(capacity.max_explored_nodes, capacity.max_stitched_path_cells);
    const solves = limits.solves_per_step;
    const frames = limits.frame_requests;
    const pool_words = solves *| stripe_words;
    // A stored path holds at most one run per cell, plain or stitched.
    const runs_per_result = shape.runs_per_result orelse @max(capacity.max_stored_path_cells, capacity.max_stitched_path_cells);
    // A step registers at most its solves' runs, on top of the live results' runs; a
    // shard reserves table room for each, its live keys aside.
    const step_runs = solves *| runs_per_result;
    const live_runs = limits.cached_results *| runs_per_result +| step_runs;
    const windows = step_runs +| (reg_window_alignment_items - 1) *| maxRangeCount(solves, 1);
    const marks = @max(frames, shape.marks);
    // Per changed key, its halos' registrations (each halo owned by one key) and a slot per
    // group field, each range's window on a line.
    const hits = live_runs +| shape.batch_keys *| (capacity.max_group_fields +| hit_window_alignment_items);
    return .{
        .search = listBytesBound(SearchScratch, participants) +|
            participants *| searchScratchStorageBytesBound(capacity.max_explored_nodes, tier0_abstract_nodes, tier0_stitched_cells),
        .tier1 = listBytesBound(Tier1Scratch, capacity.max_escalated_solves_per_step) +|
            capacity.max_escalated_solves_per_step *| corridorScratchStorageBytesBound(capacity.max_abstract_nodes, capacity.max_stitched_path_cells),
        .results = resultCacheStorageBytesBound(limits.cached_results, capacity.max_stored_path_cells, stripe_words, shape.long_results) +|
            listBytesBound(u32, pool_words) +| listBytesBound(u16, pool_words) +| listBytesBound(PathfindingSystem.SolvedPath, solves) +|
            listBytesBound(?ResultCache.Claimed, solves),
        // One directory slot per chunk of the open levels (`openRegistryLevels`), whether
        // or not a run is stored there. The run charge stays the stored paths' runs.
        .registry = pooledStorageBytesBound(registry_shard_count, @min(shape.levels, shape.chunks), shape.chunks, live_runs, limits.cached_results) +|
            RegRecordList.growCapacity(windows) *| @sizeOf(RegRecord),
        // A resolve past the limit doubles it, so one intent per agent reserves at most twice that.
        .goals = goalTableStorageBytesBound(2 *| limits.pending_requests),
        .queues = limits.pending_requests *| @sizeOf(PendingRequest) +| keySetStorageBytesBound(limits.pending_requests) +|
            IntakeRecordList.growCapacity(frames) *| @sizeOf(IntakeRecord) +| GroupKeyCountList.growCapacity(frames) *| @sizeOf(GroupKeyCount) +|
            IntakeTallyList.growCapacity(maxRangeCount(frames, intake_range_alignment_items)) *| @sizeOf(IntakeTally) +|
            listBytesBound(PathSolveResult, solves) +| listBytesBound(usize, solves) +| listBytesBound(u32, solves) +|
            listBytesBound(GroupField, capacity.max_group_fields) +| groupKeyMapStorageBytesBound(capacity.max_group_fields) +|
            listBytesBound(usize, capacity.max_group_fields) +| listBytesBound(GroupRequestTally, solves) +|
            groupKeyMapStorageBytesBound(solves) +| listBytesBound(usize, maxRangeCount(solves, 1)) +|
            PublishBandList.growCapacity(maxRangeCount(solves, 1)) *| @sizeOf(PublishBand) +| listBytesBound(PendingRequest, solves) +|
            listBytesBound(PendingRequest, limits.pending_requests) +| listBytesBound(GroupRequestTally, solves),
        .change_scratch = listBytesBound(NavMark, marks) +| NavMarkList.growCapacity(marks) *| @sizeOf(NavMark) +|
            NavMarkTallyList.growCapacity(maxRangeCount(marks, nav_mark_range_alignment_items)) *| @sizeOf(NavMarkTally) +|
            EvictItemList.growCapacity(shape.batch_keys) *| @sizeOf(EvictItem) +| HitList.growCapacity(hits) *| @sizeOf(u32),
    };
}

// ---- Byte counts and bounds --------------------------------------------------------------
// The live byte counts production does not report, and the over-estimates the nav-size
// bench and the bound tests check them against, built from each structure's layout.

/// Bytes of a std list of `T` that `ensureTotalCapacity` grew to hold `need`: std's growth
/// past it, first slots included. Storage bounds charge each list with it.
fn listBytesBound(comptime T: type, need: usize) usize {
    return std.ArrayList(T).growCapacity(need) *| @sizeOf(T);
}

/// `listBytesBound` for a `std.MultiArrayList(Row)`, at the padded row size the resident
/// counts charge.
fn rowsBytesBound(comptime Row: type, need: usize) usize {
    return std.MultiArrayList(Row).growCapacity(need) *| @sizeOf(Row);
}

// Bytes of `pools` std lists of `T`, each grown by std to its own need, whose needs sum to
// `need`.
fn pooledList(comptime T: type, pools: usize, need: usize) usize {
    return (need +| need / 2 +| pools *| std.ArrayList(T).growCapacity(0)) *| @sizeOf(T);
}

/// What sizes a nav for `navStorageBytesBound`. Counts past what the nav can hold clamp.
pub const NavStorageShape = struct {
    /// Chunks per level.
    chunks: usize,
    levels: usize,
    chunk_tiles: u16 = default_nav_chunk_tiles,
    links: usize = 0,
    /// One-way links among `links`.
    oneway_links: usize = std.math.maxInt(usize),
    /// The most terminals one one-way system (H-component) holds.
    oneway_system_terminals: usize = std.math.maxInt(usize),
    participants: usize = 1,
    /// The largest marks batch: the chunks its marks span (each mark counted, at most one
    /// per changed cell or obstacle rect), its new links, and its distinct patch keys.
    batch_mark_chunks: usize = std.math.maxInt(usize),
    batch_links: usize = std.math.maxInt(usize),
    batch_keys: usize = std.math.maxInt(usize),
    /// The world's chunk forms and link endpoints before the build;
    /// null charges every chunk mixed and `2 * links` endpoints wherever they fit.
    content: ?NavStorageContent = null,
};

/// What a world holds that sizes its nav, counted before a build: its open and mixed
/// chunks over every level and on the level holding the most, and the chunks holding
/// link endpoints and the most one holds. A batch may turn its own chunks mixed; the
/// bound adds them.
pub const NavStorageContent = struct {
    open_chunks: usize = 0,
    mixed_chunks: usize = 0,
    max_level_open: usize = 0,
    max_level_mixed: usize = 0,
    endpoint_chunks: usize = 0,
    max_chunk_endpoints: usize = 0,
};

/// An over-estimate of `NavGraph.residentBytes` for `shape`: the grids' blocks for the
/// mixed chunks; a record per open or mixed chunk and per chunk holding a link endpoint,
/// each with a full border window; a node per open chunk, a border window's worth per
/// mixed chunk, and one per link endpoint; the batch buffers of one level build or the
/// largest marks batch, whose chunks may turn mixed (the same ones every batch); the plan
/// sets; and reachability (`connectivityStorageBytesBound`). Pools are charged at their
/// doubling and lists at std's growth past their need.
pub fn navStorageBytesBound(shape: NavStorageShape) usize {
    const levels = @max(1, shape.levels);
    const chunks = shape.chunks;
    const all_chunks = levels *| chunks;
    const chunk_cells = @as(usize, shape.chunk_tiles) * shape.chunk_tiles;
    const border_stride = borderPortalBound(shape.chunk_tiles);
    const endpoints = 2 *| shape.links;
    const mark_chunks = @min(shape.batch_mark_chunks, all_chunks *| chunk_cells);
    const batch_links = @min(shape.batch_links, shape.links);
    const batch_keys = @min(shape.batch_keys, @min(all_chunks, 5 *| mark_chunks +| 2 *| batch_links));
    const content: NavStorageContent = shape.content orelse .{
        .mixed_chunks = all_chunks,
        .max_level_mixed = chunks,
        .endpoint_chunks = @min(all_chunks, endpoints),
        .max_chunk_endpoints = @min(endpoints, chunk_cells),
    };
    const chunk_endpoints = content.max_chunk_endpoints;
    // Chunks a batch changes may turn mixed; its keys bound them.
    const mixed = @min(all_chunks, content.mixed_chunks +| batch_keys);
    const level_mixed = @min(chunks, content.max_level_mixed +| batch_keys);
    const nonblocked = @min(all_chunks, content.open_chunks +| mixed);
    const live_nodes = content.open_chunks +| mixed *| border_stride +| endpoints;
    const batch_nodes = batch_keys *| border_stride +| @min(batch_keys *| chunk_endpoints, endpoints);
    const records = nonblocked +| content.endpoint_chunks +| batch_keys;
    const slot_need = content.endpoint_chunks +| @min(batch_keys, content.endpoint_chunks);
    const graphs = navLevelGraphsStorageBytesBound(levels, chunks, border_stride, records, live_nodes +| batch_nodes, slot_need, chunk_endpoints);
    const grids = navGridStorageBytesBound(levels, chunks, mixed +| @min(mark_chunks, batch_keys));
    const level_nodes = @min(chunks, content.max_level_open +| level_mixed) +| level_mixed *| border_stride +|
        @min(chunks *| chunk_endpoints, endpoints);
    return grids +| graphs +| listBytesBound(LevelCrossings, levels) +|
        navBatchBytesBound(chunks, mark_chunks, batch_links, batch_keys) +|
        orderedIndexSetStorageBytesBound(2 *| levels) +|
        connectivityStorageBytesBound(.{
            .nodes = live_nodes,
            .level_chunks = chunks,
            .level_nodes = level_nodes,
            .batch_keys = batch_keys,
            .batch_links = batch_links,
            .border_stride = border_stride,
            .chunk_endpoints = chunk_endpoints,
            .links = shape.links,
            .oneway_links = @min(shape.oneway_links, shape.links),
            .system_terminals = shape.oneway_system_terminals,
            .participants = @max(1, shape.participants),
        });
}

// An over-estimate of `NavLevelGraph.residentBytes` summed over `levels` levels of `chunks`
// chunks each, whose record, node row, and link slot needs (live plus what a batch claims
// before it frees the old) sum to `record_need`, `node_need`, and `slot_need` over the
// levels, each slot's lists at most `chunk_endpoints` long. Each pool is charged at its
// doubling past its need, each list at std's growth; both are linear past their first
// slots, so the needs sum across levels.
fn navLevelGraphsStorageBytesBound(levels: usize, chunks: usize, border_stride: usize, record_need: usize, node_need: usize, slot_need: usize, chunk_endpoints: usize) usize {
    // `growPool` grows each pool to at most twice its own need, its free list exactly.
    const records = 2 *| record_need;
    const nodes = 2 *| node_need;
    const slots = 2 *| slot_need;
    const slot_lists = listBytesBound(NavPortal, chunk_endpoints) +| listBytesBound(NavLink, chunk_endpoints);
    // A level's plan sets: its patch order and changed and dirty bits over its chunks.
    const plan_sets = orderedIndexSetStorageBytesBound(chunks) +| 2 *| bitSetBytesFor(chunks);
    return levels *| (listBytesBound(u32, chunks) +| plan_sets) +|
        records *| (record_row_bytes +| @sizeOf(u32)) +| pooledList(NavPortal, levels, records *| border_stride) +|
        nodes *| (@sizeOf(NodeRow) +| @sizeOf(u32)) +|
        slots *| (@sizeOf(FieldElem(NavLevelGraph, "link_slots")) +| slot_lists +| @sizeOf(u32));
}

// The batch buffers' share of `navStorageBytesBound`: a level build over `chunks` keys, or a
// marks batch whose `mark_chunks` and `batch_links` stage at most five and two keys each
// per stream before dedupe, at most one plan range per item, each range's windows padded
// to a cache line.
// A key list may swap with a staging list, so every one is charged the larger.
fn navBatchBytesBound(chunks: usize, mark_chunks: usize, batch_links: usize, batch_keys: usize) usize {
    const KeyList = @FieldType(NavGraph, "changed_keys");
    const PlanTallyList = @FieldType(NavGraph, "plan_tallies");
    const ranges = @max(1, mark_chunks +| batch_links);
    const staged = 5 *| mark_chunks +| 2 *| batch_links +| ranges *| (key_window_alignment - 1);
    const keys = @max(chunks, staged);
    const changed = @max(chunks, mark_chunks);
    return 2 *| plan_streams *| KeyList.growCapacity(keys) *| @sizeOf(u64) +|
        listBytesBound(ChunkBits, changed) +| listBytesBound(u32, changed) +| listBytesBound(i32, changed) +|
        listBytesBound(PatchInfo, @max(chunks, batch_keys)) +|
        listBytesBound(FieldElem(NavGraph, "plan_windows"), ranges) +|
        PlanTallyList.growCapacity(ranges) *| @sizeOf(FieldElem(NavGraph, "plan_tallies"));
}

/// An over-estimate of `NavGrid.residentBytes` summed over `levels` levels of `chunks`
/// chunks each, whose block needs (mixed chunks, plus the fresh blocks a batch takes before
/// it frees the old) sum to `block_need`: the directories, and each level's block pool and
/// free list at their worst growth (`growPool`: the pool at most twice its need, the free
/// list exactly the pool).
pub fn navGridStorageBytesBound(levels: usize, chunks: usize, block_need: usize) usize {
    const blocks = 2 *| block_need;
    return levels *| listBytesBound(u32, chunks) +| blocks *| (cell_block_bytes +| @sizeOf(u32));
}

/// What sizes a world's reachability for `connectivityStorageBytesBound`.
pub const ConnectivityStorageShape = struct {
    /// The most live node rows over every level.
    nodes: usize,
    /// The chunks one level build patches and the most nodes it gathers.
    level_chunks: usize,
    level_nodes: usize,
    /// The patch keys and new links of the largest marks batch.
    batch_keys: usize,
    batch_links: usize,
    border_stride: usize,
    /// The most link endpoints one chunk holds.
    chunk_endpoints: usize,
    links: usize,
    oneway_links: usize,
    /// The most terminals one H-component holds, clamped to every terminal.
    system_terminals: usize = std.math.maxInt(usize),
    participants: usize,
};

/// An over-estimate of `Connectivity.residentBytes` for `shape`.
/// Every list is charged at std's growth past the most it is reserved for, every pool at its
/// doubling past its need. Staging is the larger of one level build and the largest marks
/// batch, per list: a key holds at most `border_stride + chunk_endpoints` nodes. Comps and
/// roots cover the live nodes plus a batch's fresh ids; the closure covers two terminals per
/// one-way link, H-components of at most `system_terminals` each, its blocks and a batch's
/// tail at three times the live blocks plus a span per piece, and a batch's closure staging at
/// its worst.
pub fn connectivityStorageBytesBound(shape: ConnectivityStorageShape) usize {
    const C = Connectivity;
    const node_bound = shape.border_stride + shape.chunk_endpoints;
    const marks_keys = shape.batch_keys;
    const build_keys = shape.level_chunks;
    const keys = @max(marks_keys, build_keys);
    const items = @max(marks_keys +| shape.batch_links, build_keys);
    // Every key's border window, and the link endpoints its chunks hold: at most
    // `chunk_endpoints` each and every endpoint of the world in all.
    const endpoints = 2 *| shape.links;
    const marks_nodes = marks_keys *| shape.border_stride +| @min(marks_keys *| shape.chunk_endpoints, endpoints);
    const build_endpoints = @min(build_keys *| shape.chunk_endpoints, endpoints);
    // A build gathers a row per label (at most its nodes) and an edge per border run and
    // endpoint of every chunk.
    const build_labels = @min(shape.level_nodes, build_keys *| shape.border_stride +| build_endpoints);
    const build_edges = build_keys *| shape.border_stride +| build_endpoints;
    // A marks key gathers its old labels and new nodes as rows, an edge per node, and seeds
    // each node.
    const seeds = @max(marks_nodes, build_endpoints);
    const rows = @max(2 *| marks_nodes, build_labels);
    const edges = @max(marks_nodes +| shape.batch_links, build_edges);
    const marks_elements = 5 *| marks_nodes +| shape.batch_links;
    const build_elements = build_labels +| 2 *| build_endpoints +| 1;
    const elements = @max(marks_elements, build_elements);
    // Elements plus the roots of kept elements share the map.
    const map_slots = MergeMap.slotCount(2 *| elements) catch std.math.maxInt(usize);
    const EdgeEntry = FieldElem(C, "seed_edges");
    const staging = listBytesBound(usize, keys +| 1) +| listBytesBound(u32, keys) +| listBytesBound(EdgeEntry, seeds) +|
        listBytesBound(bool, keys) +|
        2 *| (listBytesBound(usize, items +| 1) +| listBytesBound(u32, items)) +|
        listBytesBound(FieldElem(C, "gather_rows"), rows) +| listBytesBound(EdgeEntry, edges) +|
        rowsBytesBound(FieldElem(C, "elements"), elements) +| rowsBytesBound(FieldElem(C, "units"), elements) +|
        rowsBytesBound(FieldElem(C, "sets"), elements) +|
        rowsBytesBound(FieldElem(C, "families"), elements) +| rowsBytesBound(FieldElem(C, "groups"), elements) +|
        5 *| listBytesBound(u32, elements) +|
        map_slots *| (@sizeOf(u64) + 2 * @sizeOf(u32));
    // A pool doubles past its need and its free list covers it exactly.
    const ids = 2 *| (shape.nodes +| elements);
    const pools = ids *| (@sizeOf(FieldElem(C, "comps")) + @sizeOf(u32) + @sizeOf(FieldElem(C, "roots")) + @sizeOf(u32));
    const flood_window = @max(default_flood_window, default_flood_budget_cap) + node_bound;
    // A round's items shrink as a node's slack grows: charged at the least slack.
    const flood_items = flood_window / (1 + shape.border_stride);
    const table_slots = std.math.ceilPowerOfTwo(usize, 2 * (default_flood_budget_cap + node_bound)) catch std.math.maxInt(usize);
    const flood = listBytesBound(FieldElem(C, "flood_items"), flood_items) +| listBytesBound(FieldElem(C, "flood_outs"), flood_items) +|
        listBytesBound(FieldElem(C, "proposals"), flood_window) +| listBytesBound(FieldElem(C, "flood_scratch"), shape.participants) +|
        shape.participants *| table_slots *| (@sizeOf(u64) + @sizeOf(u32));
    // Every world link holds a registry entry, one-way or not.
    const registry = listBytesBound(u32, shape.links);
    const key_nodes = keys *| shape.border_stride +| @min(keys *| shape.chunk_endpoints, endpoints);
    return staging +| pools +| flood +| registry +| closureStorageBytesBound(shape, keys, key_nodes);
}

// The closure's share of `connectivityStorageBytesBound`: its one-way rows, terminal and
// H-component pools, blocks and tail, and a batch's staging over `keys` keys holding at most
// `key_nodes` nodes. A batch holds at most every terminal as an old or popped one, every
// one-way link live or loose, and blocks whose caps sum to twice the terminals.
fn closureStorageBytesBound(shape: ConnectivityStorageShape, keys: usize, key_nodes: usize) usize {
    const Closure = @FieldType(Connectivity, "closure");
    if (shape.oneway_links == 0) return 0;
    const terminals = 2 *| shape.oneway_links;
    const system = @max(1, @min(shape.system_terminals, terminals));
    // A block's cap is a power of two below twice its component's terminals.
    const cap_max = std.math.ceilPowerOfTwo(usize, 2 *| system) catch std.math.maxInt(usize);
    const row_words = @max(1, cap_max / 32);
    const spans = @divCeil(row_words, span_words);
    const live_words = 2 *| terminals *| (row_words +| 2) +| span_words *| terminals;
    const blocks = (3 *| live_words +| span_words *| terminals) *| @sizeOf(u32);
    const registry = rowsBytesBound(FieldElem(Closure, "oneway"), shape.oneway_links);
    // Terminals pop up to twice the live ones; H-components split into a piece per link.
    const pools = 2 *| 3 *| terminals *| (@sizeOf(FieldElem(Closure, "terms")) + @sizeOf(u32)) +|
        2 *| 2 *| terminals *| (@sizeOf(FieldElem(Closure, "hcomps")) + @sizeOf(u32));
    const staging = 2 *| listBytesBound(usize, keys +| 1) +| 2 *| listBytesBound(u32, keys) +| listBytesBound(FieldElem(Closure, "cand_tallies"), keys) +|
        listBytesBound(u32, 3 *| key_nodes) +|
        listBytesBound(FieldElem(Closure, "ow_entries"), @min(keys *| shape.chunk_endpoints, 2 *| shape.links)) +|
        listBytesBound(u32, terminals) +| rowsBytesBound(FieldElem(Closure, "touched"), terminals) +|
        listBytesBound(u32, terminals / 16 +| terminals) +| listBytesBound(u32, 2 *| terminals) +|
        3 *| listBytesBound(u32, terminals) +| listBytesBound(FieldElem(Closure, "resolve_out"), terminals) +|
        rowsBytesBound(FieldElem(Closure, "slots"), 2 *| terminals) +| rowsBytesBound(FieldElem(Closure, "pieces"), terminals) +|
        2 *| listBytesBound(u32, terminals) +| listBytesBound(FieldElem(Closure, "freed_indices"), terminals) +|
        listBytesBound(FieldElem(Closure, "mask_items"), terminals) +|
        rowsBytesBound(FieldElem(Closure, "apos"), 2 *| terminals) +|
        listBytesBound(FieldElem(Closure, "copy_items"), 6 *| terminals *| spans) +| listBytesBound(FieldElem(Closure, "round_items"), 3 *| terminals *| spans) +|
        listBytesBound(usize, 2 *| terminals +| 2) +| listBytesBound(FieldElem(Closure, "residents"), terminals);
    return registry +| pools +| blocks +| staging;
}

/// Bytes a connectivity element map's slots hold (allocated capacity).
fn elementMapResidentBytes(map: anytype) usize {
    return map.keys.capacity * @sizeOf(u64) + map.values.capacity * @sizeOf(u32) + map.stamps.capacity * @sizeOf(u32);
}

/// `elementMapResidentBytes` of a `Map` once reserved for at most `limit` keys. Saturates.
fn elementMapStorageBytesBound(comptime Map: type, limit: usize) usize {
    const slots = Map.slotCount(limit) catch return std.math.maxInt(usize);
    return slots *| (@sizeOf(u64) + 2 * @sizeOf(u32));
}

// Bytes a cache probe table's slots hold (allocated capacity).
fn probeTableResidentBytes(table: anytype) usize {
    return table.slots.capacity * @sizeOf(FieldElem(@TypeOf(table.*), "slots"));
}

// `probeTableResidentBytes` of a `Table` once reserved for at most `capacity` keys: two slots
// each, exact.
fn probeTableStorageBytesBound(comptime Table: type, capacity: usize) usize {
    return capacity *| 2 *| @sizeOf(FieldElem(Table, "slots"));
}

/// Bytes `set` holds (allocated capacity).
fn keySetResidentBytes(set: *const KeySet) usize {
    return probeTableResidentBytes(&set.table);
}

/// `keySetResidentBytes` once reserved for at most `capacity` keys.
fn keySetStorageBytesBound(capacity: usize) usize {
    return probeTableStorageBytesBound(@FieldType(KeySet, "table"), capacity);
}

/// Bytes `map` holds (allocated capacity).
fn groupKeyMapResidentBytes(map: *const GroupKeyMap) usize {
    return probeTableResidentBytes(&map.table);
}

/// `groupKeyMapResidentBytes` once reserved for at most `capacity` keys.
fn groupKeyMapStorageBytesBound(capacity: usize) usize {
    return probeTableStorageBytesBound(@FieldType(GroupKeyMap, "table"), capacity);
}

/// Bytes `cache`'s probe table, records, keys, free lists, owner logs, stripe and
/// long-block pages, and pending moves hold (allocated capacity).
pub fn resultCacheResidentBytes(cache: *const ResultCache) usize {
    const Core = @FieldType(ResultCache, "core");
    const core = &cache.core;
    var bytes = core.slots.capacity * @sizeOf(FieldElem(Core, "slots")) + core.records.capacity * @sizeOf(FieldElem(Core, "records")) +
        core.keys.capacity * @sizeOf(PathQueryKey) + core.free.capacity * @sizeOf(u32) + core.owner_log.capacity * @sizeOf(OwnerOp) +
        cache.inline_pages.capacity * @sizeOf([]u32) + cache.long_pages.capacity * @sizeOf([]u32) +
        cache.free_long_blocks.capacity * @sizeOf(u32) + cache.resize_moves.capacity * @sizeOf(ResizeMove);
    if (core.owner_log_replacement) |replacement| bytes += replacement.capacity * @sizeOf(OwnerOp);
    for (cache.inline_pages.items) |page| bytes += page.len * @sizeOf(u32);
    for (cache.long_pages.items) |page| bytes += page.len * @sizeOf(u32);
    return bytes;
}

/// `resultCacheResidentBytes` between resizes for a cache never reserved past `capacity`
/// entries of `inline_words`-word stripes, holding at most `long_blocks` live long blocks of
/// `long_block_words` words. Saturates.
pub fn resultCacheStorageBytesBound(capacity: usize, inline_words: usize, long_block_words: usize, long_blocks: usize) usize {
    const Core = @FieldType(ResultCache, "core");
    const inline_shift = caches.pageShift(inline_words);
    const inline_pages = caches.pageCount(capacity, inline_shift);
    const long_shift = caches.pageShift(long_block_words);
    const long_pages = caches.pageCount(@min(long_blocks, capacity), long_shift);
    const core = capacity *| 2 *| @sizeOf(FieldElem(Core, "slots")) +| listBytesBound(FieldElem(Core, "records"), capacity) +|
        listBytesBound(PathQueryKey, capacity) +| listBytesBound(u32, capacity) +| listBytesBound(OwnerOp, caches.ops_per_entry *| capacity);
    const stripes = inline_pages *| (@as(usize, 1) << inline_shift) *| inline_words *| @sizeOf(u32) +| listBytesBound([]u32, inline_pages);
    const long_pool = long_pages *| (@as(usize, 1) << long_shift) *| long_block_words *| @sizeOf(u32) +| listBytesBound([]u32, long_pages) +|
        listBytesBound(u32, long_pages *| (@as(usize, 1) << long_shift));
    return core +| stripes +| long_pool;
}

// Bytes a crossing scratch's tables and heap hold (allocated capacity).
fn crossingScratchResidentBytes(scratch: *const CrossingScratch) usize {
    return scratch.box_slots.len * @sizeOf(CrossingBoxSlot) + scratch.level_slots.len * @sizeOf(CrossingLevelSlot) + scratch.open.capacity * @sizeOf(OpenNode);
}

// `crossingScratchResidentBytes` once reserved for at most `box_limit` boxes. Saturates.
fn crossingScratchStorageBytesBound(box_limit: usize) usize {
    const slots = hashTableSlots(box_limit) catch std.math.maxInt(usize);
    return slots *| (@sizeOf(CrossingBoxSlot) + @sizeOf(CrossingLevelSlot)) +| listBytesBound(OpenNode, types.openHeapLimit(box_limit));
}

// Bytes an abstract scratch's table, heap, corridor lists, and crossing scratch hold
// (allocated capacity).
fn abstractScratchResidentBytes(scratch: *const AbstractScratch) usize {
    return scratch.slots.len * @sizeOf(AbstractSlot) + scratch.open.capacity * @sizeOf(OpenNode) +
        scratch.corridor.capacity * @sizeOf(usize) + scratch.corridor_link.capacity * @sizeOf(bool) + crossingScratchResidentBytes(&scratch.crossing);
}

// `abstractScratchResidentBytes` once reserved for at most `max_abstract_nodes`. Saturates.
fn abstractScratchStorageBytesBound(max_abstract_nodes: usize) usize {
    const slots = hashTableSlots(max_abstract_nodes) catch std.math.maxInt(usize);
    return slots *| @sizeOf(AbstractSlot) +| listBytesBound(OpenNode, types.openHeapLimit(max_abstract_nodes)) +|
        listBytesBound(usize, max_abstract_nodes) +| listBytesBound(bool, max_abstract_nodes) +|
        crossingScratchStorageBytesBound(types.crossingBoxBudget(max_abstract_nodes));
}

/// Bytes `scratch`'s abstract search and stitched path hold (allocated capacity).
pub fn corridorScratchResidentBytes(scratch: *const CorridorScratch) usize {
    return abstractScratchResidentBytes(&scratch.abstract) + scratch.stitched.capacity * @sizeOf(StitchedCell);
}

/// `corridorScratchResidentBytes` once reserved at caps no larger than `max_abstract_nodes`
/// and `max_stitched_path_cells`. Saturates.
pub fn corridorScratchStorageBytesBound(max_abstract_nodes: usize, max_stitched_path_cells: usize) usize {
    return abstractScratchStorageBytesBound(max_abstract_nodes) +| listBytesBound(StitchedCell, max_stitched_path_cells +| 1);
}

/// Bytes `scratch`'s search table, heap, path scratch, and corridor scratch hold (allocated
/// capacity).
pub fn searchScratchResidentBytes(scratch: *const SearchScratch) usize {
    return scratch.slots.len * @sizeOf(SearchSlot) + scratch.open.capacity * @sizeOf(OpenNode) +
        scratch.path_scratch.capacity * @sizeOf(u32) + corridorScratchResidentBytes(&scratch.corridor);
}

/// `searchScratchResidentBytes` once reserved at budgets no larger than these. Saturates.
pub fn searchScratchStorageBytesBound(max_explored_nodes: usize, max_abstract_nodes: usize, max_stitched_path_cells: usize) usize {
    const slots = hashTableSlots(max_explored_nodes) catch std.math.maxInt(usize);
    return slots *| @sizeOf(SearchSlot) +| listBytesBound(OpenNode, types.openHeapLimit(max_explored_nodes)) +|
        listBytesBound(u32, @max(@as(usize, 1), max_explored_nodes)) +|
        corridorScratchStorageBytesBound(max_abstract_nodes, max_stitched_path_cells);
}

/// Bytes `table`'s map, entries, and scan staging hold (allocated capacity).
pub fn goalTableResidentBytes(table: *const GoalTable) usize {
    return elementMapResidentBytes(&table.map) + table.refs.capacity * @sizeOf(u64) + table.live.capacity * @sizeOf(u32) +
        table.scan_refs.capacity * @sizeOf(u64) + table.scan_tallies.capacity * @sizeOf(FieldElem(GoalTable, "scan_tallies"));
}

/// `goalTableResidentBytes` once reserved for at most `limit` intents. Saturates.
pub fn goalTableStorageBytesBound(limit: usize) usize {
    const ScanTally = FieldElem(GoalTable, "scan_tallies");
    return elementMapStorageBytesBound(@FieldType(GoalTable, "map"), limit) +| @FieldType(GoalTable, "refs").growCapacity(limit) *| @sizeOf(u64) +|
        @FieldType(GoalTable, "live").growCapacity(limit) *| @sizeOf(u32) +| @FieldType(GoalTable, "scan_refs").growCapacity(limit) *| @sizeOf(u64) +|
        @FieldType(GoalTable, "scan_tallies").growCapacity(maxRangeCount(limit, scan_range_alignment_items)) *| @sizeOf(ScanTally);
}

/// Bytes `field`'s pool and directory hold (allocated capacity).
pub fn groupFieldResidentBytes(field: *const GroupField) usize {
    return @FieldType(GroupField, "blocks").capacityInBytes(field.blocks.capacity) + field.directory.len * @sizeOf(FieldElem(GroupField, "directory"));
}

/// An over-estimate of `groupFieldResidentBytes` for a field capped at `max_cells` cells on
/// a level of `level_chunks` chunks: the pool never grows past what a build can claim, and
/// its directory is sized to the pool. A directory too wide to build saturates.
pub fn groupFieldStorageBytesBound(max_cells: usize, level_chunks: usize) usize {
    const blocks = @min(@max(1, max_cells), level_chunks);
    const rows = hashTableSlots(blocks) catch return std.math.maxInt(usize);
    return blocks *| @FieldType(GroupField, "blocks").capacityInBytes(1) +| rows *| @sizeOf(FieldElem(GroupField, "directory"));
}
