// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The nav scaling groups' memory estimate: a config's nav storage charged from the
//! production byte bounds, checked against the bench nav-size limit before a run and against
//! the built nav's resident bytes after it.

const std = @import("std");
const BenchmarkCase = @import("suite.zig").BenchmarkCase;
const PathfindingCapacity = @import("../game/systems/pathfinding/types.zig").PathfindingCapacity;
const PathfindingSystem = @import("../game/systems/pathfinding/system.zig").PathfindingSystem;
const pathfinding_test_support = @import("../game/systems/pathfinding/test_support.zig");
const default_chunk_size_tiles = @import("../game/world/system.zig").default_chunk_size_tiles;

const mib: usize = 1024 * 1024;

// The nav scaling groups' size limit: a listed config whose `navStorageBytes` exceeds it
// fails, so a storage change that outgrows it is a failure, never a dropped size point.
const nav_size_limit_bytes: usize = 512 * mib;

/// What sizes the nav a nav scaling config builds: a square world of `side` cells per
/// level in default chunks, its level links, the nav's threaded participants, and its
/// path-request capacity (agent budget and group fields; library defaults elsewhere).
pub const NavSizeConfig = struct {
    side: usize,
    levels: usize,
    links: usize = 0,
    participant_count: usize,
    agent_budget: usize,
    group_fields: usize,
    /// Cached results whose path can outgrow the inline stripe, each holding one long
    /// block; the default charges every cached result. A fixture whose paths all fit inline
    /// passes 0 and checks that no long block was taken.
    long_results: usize = std.math.maxInt(usize),
    /// The most registry runs (chunk-local stretches) one cached path holds; null charges
    /// one per stored cell, the most any path holds. A fixture whose paths are shorter passes
    /// its bound; `checkNavBytes` tests it after the run.
    runs_per_result: ?usize = null,
    /// One-way links among `links`, clamped to it: the one-way closure is charged for these
    /// only, since a bidirectional link joins its endpoints both ways and holds no closure
    /// row; every link keeps its one-way registry entry. The default charges every link as
    /// one-way.
    oneway_links: usize = std.math.maxInt(usize),
    /// The most terminals one one-way system holds. The default charges one system holding
    /// every terminal.
    oneway_system_terminals: usize = std.math.maxInt(usize),
    /// The largest marks batch the workload runs; the default charges the worst.
    batch: NavBatch = .{},
    /// The escalated search's abstract node cap (`PathfindingCapacity.max_abstract_nodes`),
    /// which sizes each tier-1 corridor scratch; the library default unless a probe raises it.
    tier1_abstract_nodes: usize = (PathfindingCapacity{}).max_abstract_nodes,
    /// The built world's chunk forms and link endpoints (`navStorageContentOf` in the pathfinding test support), plus
    /// what the workload adds; null charges every chunk mixed.
    content: ?pathfinding_test_support.NavStorageContent = null,

    fn levelChunks(self: NavSizeConfig) usize {
        const per_side = std.math.divCeil(usize, self.side, default_chunk_size_tiles) catch unreachable; // lint:allow catch-unreachable: the chunk edge is a nonzero constant
        return per_side * per_side;
    }
};

/// The largest marks batch of a nav scaling workload: the chunks its marks span (each mark
/// counted, at most one per changed cell or obstacle rect), its new links, and its distinct
/// chunk keys (its changed chunks with their four neighbours and both endpoint chunks of
/// each new link, over every level it touches). A batch reserves the graph's and
/// connectivity's staging per key, and the staging keeps the largest batch's size. The
/// defaults charge a mark per cell, every link, and every chunk.
pub const NavBatch = struct {
    mark_chunks: usize = std.math.maxInt(usize),
    links: usize = std.math.maxInt(usize),
    keys: usize = std.math.maxInt(usize),

    /// A nav that runs no marks batch after its build.
    pub const none: NavBatch = .{ .mark_chunks = 0, .links = 0, .keys = 0 };
};

/// The chunk keys a marks batch changing an `edge` x `edge` chunk square patches: the square
/// and the ring of neighbours around it (`NavBatch.keys`).
pub fn squareBatchKeys(edge: usize) usize {
    return edge * edge + 4 * edge;
}

/// The capacity a nav scaling config's nav reserves; library defaults elsewhere.
/// `navStorageBytes` charges what it sizes.
pub fn navSizeCapacity(config: NavSizeConfig) PathfindingCapacity {
    return .{
        .worker_participant_count = config.participant_count,
        .max_agent_budget = config.agent_budget,
        .max_group_fields = config.group_fields,
        .max_abstract_nodes = config.tier1_abstract_nodes,
    };
}

// `navStorageBytes` by what holds it at run time: the graph (`NavGraph.residentBytes`),
// the group fields (`groupFieldResidentBytes`), and the request side's parts
// (`requestResidentBytes`).
const NavStorageParts = struct {
    graph: usize,
    group_fields: usize,
    request: pathfinding_test_support.RequestStorage,

    fn total(self: NavStorageParts) usize {
        var bytes = self.graph +| self.group_fields;
        inline for (@typeInfo(pathfinding_test_support.RequestStorage).@"struct".field_names) |name| bytes +|= @field(self.request, name);
        return bytes;
    }
};

// An over-estimate of the bytes the per-chunk nav takes for `config` at its agent-budget
// ceiling, from the pathfinding test support's bounds: the graph (`navStorageBytesBound`),
// group fields (`groupFieldStorageBytesBound`), and the request side
// (`requestStorageBytesBound`). Search scratch and group fields are sized
// by their node and cell budgets, never by level cells.
fn navStorageBytes(config: NavSizeConfig) usize {
    return navStorageParts(config).total();
}

// `navStorageBytes` split by what reports it at run time.
fn navStorageParts(config: NavSizeConfig) NavStorageParts {
    const capacity = navSizeCapacity(config);
    const chunks = config.levelChunks();
    const levels: usize = @max(1, config.levels);
    const graph = pathfinding_test_support.navStorageBytesBound(.{
        .chunks = chunks,
        .levels = levels,
        .links = config.links,
        .oneway_links = config.oneway_links,
        .oneway_system_terminals = config.oneway_system_terminals,
        .participants = @max(1, config.participant_count),
        .batch_mark_chunks = config.batch.mark_chunks,
        .batch_links = config.batch.links,
        .batch_keys = config.batch.keys,
        .content = config.content,
    });
    return .{
        .graph = graph,
        .group_fields = config.group_fields *| pathfinding_test_support.groupFieldStorageBytesBound(capacity.group_field_max_cells, chunks),
        .request = pathfinding_test_support.requestStorageBytesBound(capacity, .{
            .long_results = config.long_results,
            .runs_per_result = config.runs_per_result,
            .chunks = chunks *| levels,
            // A marks batch holds at most a mark per cell and a key per chunk.
            .marks = @min(config.batch.mark_chunks, chunks *| levels *| default_chunk_size_tiles *| default_chunk_size_tiles),
            .batch_keys = @min(config.batch.keys, chunks *| levels),
        }),
    };
}

/// Fails when a built nav holds more bytes in any part than `navStorageParts(config)`
/// charges it, printing that part's figures.
pub fn checkNavBytes(group_name: []const u8, item_count: usize, config: NavSizeConfig, system: *const PathfindingSystem) !void {
    const parts = navStorageParts(config);
    var field_bytes: usize = 0;
    for (system.group_fields.items) |*field| field_bytes += pathfinding_test_support.groupFieldResidentBytes(field);
    const resident = pathfinding_test_support.requestResidentBytes(system);
    var past = false;
    past = reportPart(group_name, item_count, "graph", system.graph.residentBytes(), parts.graph) or past;
    past = reportPart(group_name, item_count, "group fields", field_bytes, parts.group_fields) or past;
    inline for (@typeInfo(pathfinding_test_support.RequestStorage).@"struct".field_names) |name| {
        past = reportPart(group_name, item_count, name, @field(resident, name), @field(parts.request, name)) or past;
    }
    if (past) return error.NavBytesPastEstimate;
}

// Prints a part holding more than charged; returns whether it does.
fn reportPart(group_name: []const u8, item_count: usize, part: []const u8, resident: usize, charged: usize) bool {
    if (resident <= charged) return false;
    std.debug.print("  {s} {}: nav {s} holds {} B against {} B charged\n", .{ group_name, item_count, part, resident, charged });
    return true;
}

/// Fails for a config whose `navStorageBytes` exceeds the bench nav-size limit, printing
/// its figure: the lists hold only configs that fit.
pub fn checkNavSize(group_name: []const u8, item_count: usize, case: BenchmarkCase, config: NavSizeConfig) !void {
    const bytes = navStorageBytes(config);
    if (bytes <= nav_size_limit_bytes) return;
    std.debug.print("  {s} {} {s}: nav needs {} MiB against the {} MiB bench nav-size limit\n", .{
        group_name,
        item_count,
        case.name,
        std.math.divCeil(usize, bytes, mib) catch unreachable, // lint:allow catch-unreachable: mib is a nonzero constant
        nav_size_limit_bytes / mib,
    });
    return error.NavPastSizeLimit;
}

test "nav storage charges the one-way closure for one-way links only, every link by default" {
    const base = NavSizeConfig{ .side = 256, .levels = 2, .links = 4096, .participant_count = 1, .agent_budget = 8, .group_fields = 1, .batch = .{ .mark_chunks = 1, .links = 0, .keys = 5 } };
    var two_way = base;
    two_way.oneway_links = 0;
    var all_oneway = base;
    all_oneway.oneway_links = base.links;
    var past_all = base;
    past_all.oneway_links = 2 * base.links;
    try std.testing.expectEqual(navStorageBytes(base), navStorageBytes(all_oneway));
    try std.testing.expectEqual(navStorageBytes(base), navStorageBytes(past_all));
    try std.testing.expect(navStorageBytes(two_way) < navStorageBytes(base));
    // Systems of a few terminals each hold narrower blocks than one holding every terminal.
    var small_systems = base;
    small_systems.oneway_system_terminals = 8;
    try std.testing.expect(navStorageBytes(small_systems) < navStorageBytes(base));
    try std.testing.expect(navStorageBytes(two_way) < navStorageBytes(small_systems));
}

test "nav storage parts pass the config's shape to the graph and field bounds, and a batch moves only the graph and the change scratch" {
    const base = NavSizeConfig{ .side = 256, .levels = 2, .links = 64, .oneway_links = 0, .participant_count = 3, .agent_budget = 8, .group_fields = 2, .batch = NavBatch.none };
    var batch = base;
    batch.batch = .{ .mark_chunks = 300, .links = 10, .keys = 400 };
    for ([_]NavSizeConfig{ base, batch }) |config| {
        try std.testing.expectEqual(pathfinding_test_support.navStorageBytesBound(.{
            .chunks = 256,
            .levels = 2,
            .links = 64,
            .oneway_links = 0,
            .participants = 3,
            .batch_mark_chunks = config.batch.mark_chunks,
            .batch_links = config.batch.links,
            .batch_keys = config.batch.keys,
        }), navStorageParts(config).graph);
        try std.testing.expectEqual(2 * pathfinding_test_support.groupFieldStorageBytesBound((PathfindingCapacity{}).group_field_max_cells, 256), navStorageParts(config).group_fields);
    }
    const base_parts = navStorageParts(base);
    const batch_parts = navStorageParts(batch);
    try std.testing.expect(batch_parts.graph > base_parts.graph);
    try std.testing.expect(batch_parts.request.change_scratch > base_parts.request.change_scratch);
    var unmoved = batch_parts.request;
    unmoved.change_scratch = base_parts.request.change_scratch;
    try std.testing.expectEqual(base_parts.request, unmoved);
    try std.testing.expectEqual(
        navStorageBytes(batch) - navStorageBytes(base),
        (batch_parts.graph - base_parts.graph) + (batch_parts.request.change_scratch - base_parts.request.change_scratch),
    );
}

test "nav storage charges the request side's production bound at the config's shape, long blocks for its long results only" {
    const base = NavSizeConfig{ .side = 256, .levels = 1, .participant_count = 1, .agent_budget = 100, .group_fields = 1 };
    var inline_only = base;
    inline_only.long_results = 0;
    var one_long = base;
    one_long.long_results = 1;
    var past_all = base;
    past_all.long_results = 1000;
    for ([_]NavSizeConfig{ base, inline_only, one_long, past_all }) |config| {
        const expected = pathfinding_test_support.requestStorageBytesBound(navSizeCapacity(config), .{
            .long_results = config.long_results,
            .runs_per_result = config.runs_per_result,
            .chunks = 256,
            .marks = 256 * @as(usize, default_chunk_size_tiles) * default_chunk_size_tiles,
            .batch_keys = 256,
        });
        try std.testing.expectEqual(expected, navStorageParts(config).request);
    }
    // Long blocks are charged for the long results alone, at most one per cached result.
    try std.testing.expect(navStorageBytes(inline_only) < navStorageBytes(one_long));
    try std.testing.expect(navStorageBytes(one_long) < navStorageBytes(base));
    try std.testing.expectEqual(navStorageBytes(base), navStorageBytes(past_all));
    // Short routes charge fewer registry runs than one per stored cell.
    var short_routes = base;
    short_routes.runs_per_result = 3;
    try std.testing.expect(navStorageParts(short_routes).request.registry < navStorageParts(base).request.registry);
}
