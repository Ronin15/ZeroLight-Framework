// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Pathfinding connectivity bench groups: component splits and the one-way closure.
//! A config whose nav storage exceeds the bench's nav-size limit fails with its
//! figure (`nav_size.checkNavSize`), and every config checks each part of the nav's
//! bytes against its charge (`nav_size.checkNavBytes`). Every toggle reaction, block and
//! reopen, runs each chunk-partitioned stage of more than one range on workers in a fixed
//! threaded case, and its flood and one-way closure rows when a round spans more than one
//! range (`suite.checkNavReactionDispatched`). The headline batch and tuner are the block
//! reaction's flood (split) or closure rows (one-way); the tuned case settles both stage tuner
//! sets (`step_tuners:`) before measuring.

const std = @import("std");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const offMainNs = @import("../../app/thread_system.zig").offMainNs;
const DataSystem = @import("../../game/data_system.zig").DataSystem;
const StaticColliderSystem = @import("../../game/systems/static_colliders.zig").StaticColliderSystem;
const PathfindingSystem = @import("../../game/systems/pathfinding.zig").PathfindingSystem;
const PathRequest = @import("../../game/simulation.zig").PathRequest;
const PathfindingCapacity = @import("../../game/systems/pathfinding.zig").PathfindingCapacity;
const NavUpdateStats = @import("../../game/systems/pathfinding/types.zig").NavUpdateStats;
const NavStage = @import("../../game/systems/pathfinding/nav_graph.zig").NavStage;
const WorldSystem = @import("../../game/world/system.zig").WorldSystem;
const CellCoord = @import("../../game/world/system.zig").CellCoord;
const TileId = @import("../../game/world/system.zig").TileId;
const default_chunk_size_tiles = @import("../../game/world/system.zig").default_chunk_size_tiles;
const connectivity_closure = @import("../../game/systems/pathfinding/connectivity_closure.zig");
const default_flood_budget_cap = @import("../../game/systems/pathfinding/connectivity.zig").default_flood_budget_cap;
const default_flood_window = @import("../../game/systems/pathfinding/connectivity.zig").default_flood_window;
const fixtures = @import("../fixtures.zig");
const nav_size = @import("../nav_size.zig");
const suite = @import("../suite.zig");
const buildOpenWorld = @import("nav_fixtures.zig").buildOpenWorld;
const writeLevelZeroCells = @import("nav_fixtures.zig").writeLevelZeroCells;
const writeLevelCells = @import("nav_fixtures.zig").writeLevelCells;
const toggle_batch_keys = @import("nav_fixtures.zig").toggle_batch_keys;
const ReactFixture = @import("nav_fixtures.zig").ReactFixture;
const Reaction = @import("nav_fixtures.zig").Reaction;
const assembleReactFixture = @import("nav_fixtures.zig").assembleReactFixture;
const pocketDigCell = @import("nav_fixtures.zig").pocketDigCell;
const ChunkCoord = @import("nav_fixtures.zig").ChunkCoord;
const chunkCells = @import("nav_fixtures.zig").chunkCells;
const toggleSizeConfig = @import("nav_fixtures.zig").toggleSizeConfig;
const toggle_batch = @import("nav_fixtures.zig").toggle_batch;

// One walkable level (`SplitCode`) holding, at its origin corner, solid chunks around one
// walkable gap chunk. Variant 0: a room of edge² chunks walled off by a one-chunk band whose
// one open chunk is the gap; blocking the gap seals the room. Variant 1: a one-chunk ring
// corridor around a solid block of edge² chunks, walled off from the rest of the level, with
// the gap one chunk of the ring; blocking it cuts the ring without splitting it. Variant 2: a
// one-chunk tunnel of edge chunks along the level's north border, walled below, whose east
// mouth chunk is the gap; blocking it seals the tunnel off the open level. Variant 3: two
// edge-2 ringed rooms, at chunk (1, 1) and at (side / chunk - 6, side / chunk - 6), both gaps
// filled in one batch. Variant 4: room A's gap, its east neighbour split by a wall written
// before the build. Variant 5: an edge-4 ring cut on its west and east chunks in one batch.
// Variants 3 to 5 keep that structure and sweep the level side at 256, 512, and 1024. Variant
// 6: one 512² comb of 16 dead-end tunnels off a north corridor, joined and unjoined. Variant
// 7: one edge-8 ringed room on a 256² level, sealed under the default flood cap and under a
// four-proposal cap. Variant 8: eight edge-2 ringed rooms on a 384² level, every gap filled
// in one batch. One timed sample blocks the variant's gap or gaps and runs the nav reaction,
// then reopens them and runs the reaction again; the tile writes are untimed. `outputs` is
// the cells each change flips and `candidates` the structure's chunks. Passes when variants
// 0 to 2 grow no faster than their room, ring, or tunnel chunks and are flat in side;
// asserted per sample, the block reaction's flood expands at most three times the room's or
// tunnel's chunks plus two nodes, or half again the ring's plus one node's slack, every
// reopen floods nothing, a far one-cell fill sealed with the room's gap adds no flood node,
// and a fixed threaded case runs every chunk-partitioned stage of more than one range on
// workers. Variant 3 seals both rooms and each room alone: the both-seal's flood nodes equal
// the two rooms' floods added, and on a side larger than 256² that sum and each room's flood
// equal the 256² seal. Variant 4's flood is at most twice room A's on that same side, and on
// a side larger than 256² the walled flood and room A's equal the 256² seal. Variant 5's flood
// is at most four times the smaller arc plus four nodes, and on a side larger than 256² it
// equals the 256² seal. Variant 6's timed sample is the unjoined comb's corridor under the
// default window; the joined comb is the same check. On both, the wide round's most searches
// equal the tunnels, and a narrow round (the flood window at one node's slack plus four
// slots) serves at most a quarter of them, takes at least four times the rounds, and visits
// at most twice the wide build. Variant 7's timed sample is the default cap; its four-proposal
// cap takes more rounds and at most two searches in a round. Variant 8's zero-worker flood and
// the case's flood expand the same nodes, the batch holds more searches than rounds, and a
// fixed threaded case runs that flood on workers when the batch is more than one range.
// `--details` prints the block and reopen
// reactions and the block reaction's plan, remask, patch, and connectivity shapes (the flood's
// rounds, searches per round, and its tuner's policy) with the reactions' main-thread split.
pub const connectivity_split_group = suite.BenchmarkGroup{
    .name = "pathfinding-connectivity-split",
    .item_label = SplitCode.label,
    .describe_item = SplitCode.describe,
    .item_counts = &connectivity_split_item_counts,
    .runCase = runConnectivitySplitCase,
    .write_workload = writeSplitWorkload,
};

// A 256² world of 2 levels (`OnewayCode`), each a lattice of one-cell walled rooms, holding
// `systems` chains of `terminals` rooms, each room joined to the next room of its chain by a
// one-way teleport. Variants 0 and 1 toggle the first chain's last room (its last link's
// target), variant 2 its first room (its first link's source), and variant 3 a far room no
// chain uses. Variant 4 closes the chain's first `terminals - 64` rooms once, untimed (its
// block narrows), then toggles its last room. Variant 5 is a fan: every room joined by a
// one-way teleport to a hub room, the hub to the last room, which toggles, so one round
// recomputes every source's row (rows narrower than a cache line below 512 terminals).
// Variants 1 to 5 hold one chain or fan. Variant 6 (dense) holds `systems` chains of
// `oneway_dense_terminals` rooms whose heads sit side by side on level 0's last room row,
// joined into one system through the open wall cells between them; the timed block reaction
// fills every such wall cell (the system splits into `systems`) and the reopen opens them (one
// dense opening merges them), its blocks resizing. Variant 7 adds to variant 0's chains a
// ballast chain on level 1 whose block holds over twice the chains' live words; before every
// sample, untimed and with the nav tuners restored after, the ballast reopens (its one block
// lands in that reaction) and then every ballast room closes (its block is freed in that
// reaction), and the nav's bytes are checked. Its timed block and reopen reactions must land,
// allocate, and free no block and leave the batch tail's capacity as it was. The toggled end's
// 8 rooms sit in one fixed chunk whose orthogonal neighbours hold no other chain room, so every
// config's toggle patches the same chunks. One timed sample blocks the cell and runs the nav
// reaction, then reopens it and runs the reaction again; the tile writes are untimed.
// `outputs` is the one-way links and `candidates` the rooms. Passes when variants 0, 3, and 4
// are flat (4 in its peak terminals), variant 2 grows at most linearly in terminals, variants 1
// and 5 at most as terminals² / 32, and variant 6 at most as its merged system's rows,
// (systems x terminals)² / 32; its block resizes and reserve ratio are reported, not checked,
// since its fill and reopen resize blocks by design. Every reaction's closure stays within the
// bound its prepare set (tail words, gross pops, and, for blocks kept in place, row words
// written at most its affected rows at the widest row), the far dig runs no closure stage past
// the candidate scan and writes no block word, and a fixed threaded case runs every
// chunk-partitioned stage of more than one range on workers. Variant 7 passes when its timed block reaction, that reaction's reserve section,
// and its closure stages are flat in systems; the ballast's own landing and free follow its
// block alone. `--details` as for `pathfinding-connectivity-split`, plus variant 7's ballast
// retire (the reopen's landing and tail use, the close's free) and the split of its timed
// block reaction (reserve, closure stages, landing, rest).
pub const connectivity_oneway_group = suite.BenchmarkGroup{
    .name = "pathfinding-connectivity-oneway",
    .item_label = OnewayCode.label,
    .describe_item = OnewayCode.describe,
    .item_counts = &connectivity_oneway_item_counts,
    .runCase = runConnectivityOnewayCase,
    .write_workload = writeOnewayWorkload,
};

const SplitCode = suite.ItemCode(struct { variant: SplitVariant, edge_chunks: u16, level_side: u16, levels: u16 }, &.{ 3, 4, 3 });
const OnewayCode = suite.ItemCode(struct { variant: OnewayVariant, terminals_per_system: usize, systems: usize }, &.{ 5, 5 });

fn splitItemCode(comptime variant: SplitVariant, comptime edge_chunks: u16, comptime level_side: u16) usize {
    return SplitCode.of(.{ .variant = variant, .edge_chunks = edge_chunks, .level_side = level_side, .levels = 1 });
}

// Room edges at one side, then the middle edge at two more sides, then ring edges, then
// tunnel lengths at one side and the shortest at two more.
const connectivity_split_item_counts = [_]usize{
    splitItemCode(.room, 2, 1024),
    splitItemCode(.room, 8, 1024),
    splitItemCode(.room, 32, 1024),
    splitItemCode(.room, 8, 256),
    splitItemCode(.room, 8, 2048),
    splitItemCode(.ring, 2, 1024),
    splitItemCode(.ring, 8, 1024),
    splitItemCode(.ring, 32, 1024),
    splitItemCode(.tunnel, 8, 1024),
    splitItemCode(.tunnel, 32, 1024),
    splitItemCode(.tunnel, 62, 1024),
    splitItemCode(.tunnel, 8, 256),
    splitItemCode(.tunnel, 8, 2048),
    // Flat in side: the structure stays at the bound's size.
    splitItemCode(.rooms, 2, 256),
    splitItemCode(.rooms, 2, 512),
    splitItemCode(.rooms, 2, 1024),
    splitItemCode(.walled, 2, 256),
    splitItemCode(.walled, 2, 512),
    splitItemCode(.walled, 2, 1024),
    splitItemCode(.ring_arcs, 4, 256),
    splitItemCode(.ring_arcs, 4, 512),
    splitItemCode(.ring_arcs, 4, 1024),
    // One fixture each: ratios and per-round bounds, not a side curve.
    splitItemCode(.hub, 16, 512),
    splitItemCode(.budget, 8, 256),
    splitItemCode(.pockets, 2, 384),
};

fn onewayItemCode(comptime variant: OnewayVariant, comptime terminals: usize, comptime systems: usize) usize {
    return OnewayCode.of(.{ .variant = variant, .terminals_per_system = terminals, .systems = systems });
}

const connectivity_oneway_item_counts = [_]usize{
    onewayItemCode(.locality, 8, 16),
    onewayItemCode(.locality, 8, 256),
    onewayItemCode(.locality, 8, 2048),
    onewayItemCode(.tail, 64, 1),
    onewayItemCode(.tail, 512, 1),
    onewayItemCode(.tail, 4096, 1),
    onewayItemCode(.head, 64, 1),
    onewayItemCode(.head, 512, 1),
    onewayItemCode(.head, 4096, 1),
    onewayItemCode(.far_dig, 64, 1),
    onewayItemCode(.far_dig, 512, 1),
    onewayItemCode(.far_dig, 4096, 1),
    onewayItemCode(.shrunk, 512, 1),
    onewayItemCode(.shrunk, 2048, 1),
    onewayItemCode(.shrunk, 4096, 1),
    onewayItemCode(.fan, 64, 1),
    onewayItemCode(.fan, 128, 1),
    onewayItemCode(.fan, 256, 1),
    onewayItemCode(.dense, oneway_dense_terminals, 2),
    onewayItemCode(.dense, oneway_dense_terminals, 8),
    onewayItemCode(.dense, oneway_dense_terminals, 32),
    onewayItemCode(.ballast, 8, 64),
    onewayItemCode(.ballast, 8, 512),
    onewayItemCode(.ballast, 8, 2048),
};

fn writeSplitWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("cells={} structure_chunks={}", .{ stats.output_count, stats.candidate_pairs });
    if (view == .details) {
        try writer.writeByte(' ');
        try suite.writeNavStages(writer, stats);
    }
}

fn writeOnewayWorkload(writer: *std.Io.Writer, stats: suite.RunStats, view: suite.WorkloadView) std.Io.Writer.Error!void {
    try writer.print("rooms={} oneway_links={}", .{ stats.candidate_pairs, stats.output_count });
    if (view == .details) {
        try writer.writeByte(' ');
        try suite.writeNavStages(writer, stats);
    }
}

// One timed toggle: a change of `cells` and its nav reaction, then the revert and its
// reaction.
const ToggleSample = struct {
    change: Reaction,
    revert: Reaction,

    fn elapsedNs(self: ToggleSample) u64 {
        return self.change.elapsed_ns + self.revert.elapsed_ns;
    }
};

// What a toggle's reactions must keep: every one-way block at its size, each closure reserve
// within its fixed ratio of the words the reaction touches (`checkOnewayReserve`), and, when
// `isolated`, no block of any other system (`checkOnewayIsolated`).
const ToggleChecks = struct {
    fixed_blocks: bool = true,
    reserve_ratio: bool = true,
    isolated: bool = false,
    // The far dig's toggle touches no one-way system (`checkOnewayUntouched`).
    untouched: bool = false,
    // The most nodes the block reaction's flood may expand (`SplitConfig.floodBound`).
    flood_bound: ?usize = null,
    // The block flood expands exactly this many nodes (a measured seal of the same gap).
    exact_flood: ?usize = null,
    // The block flood's folded batch holds more searches than rounds.
    more_searches_than_rounds: bool = false,
    // `checkStageDispatched` on the block flood's folded batch.
    flood_dispatch: bool = false,
};

// Fails when a reaction's closure passed what its prepare bounded: tail words past its
// reserved bound, new terminals past its gross pops, or, for a block kept in place, row words
// written past its affected rows (recomputed, left, and new) at the widest row. The bounds are
// the reaction's perf counters, folded per batch before the step's staging release can clear
// the live limits; the row widths are the live `hcomp.k_cap`, which no release touches.
fn checkOnewayWithinBounds(fixture: *const ReactFixture, stats: NavUpdateStats, fixed_blocks: bool) !void {
    const perf = stats.perf;
    if (perf.closure_tail_used > perf.closure_tail_bound) return error.ConnectivityOnewayTailPastReserve;
    if (perf.closure_links == 0 or stats.levels_built != 0) return;
    if (perf.closure_terms_new > perf.closure_n_gross) return error.ConnectivityOnewayTermsPastBound;
    if (!fixed_blocks) return;
    const closure = &fixture.system.graph.connectivity.closure;
    var widest: usize = 0;
    for (closure.hcomp.k_cap) |k_cap| widest = @max(widest, connectivity_closure.rowWords(k_cap));
    if (perf.closure_words_written > (perf.closure_a_rows + perf.closure_terms_left + perf.closure_terms_new) * widest) return error.ConnectivityOnewayRowsPastBound;
}

// Fails when a reaction touching no one-way system ran a closure stage past the candidate
// scan or wrote a block word.
fn checkOnewayUntouched(stats: NavUpdateStats) !void {
    const perf = stats.perf;
    if (perf.conn_closure_candidates_batch.item_count == 0) return error.ConnectivityOnewayNoCandidateScan;
    for ([_]BatchStats{ perf.conn_closure_resolve_batch, perf.conn_closure_mask_batch, perf.conn_closure_plan_batch, stats.perf.conn_closure_rows_batch, perf.conn_closure_land_batch }) |batch| {
        if (batch.item_count != 0) return error.ConnectivityOnewayFarDigRanClosure;
    }
    if (perf.closure_words_written != 0 or perf.closure_landed_words != 0) return error.ConnectivityOnewayFarDigWroteBlock;
}

// Fails when a reaction's closure reserved past its fixed ratio: a tail over twice its
// candidates' block words plus 32 words per terminal it could number (a small piece's
// 16-word block).
fn checkOnewayReserve(stats: NavUpdateStats) !void {
    const slack = 32 * stats.perf.closure_kb;
    if (stats.perf.closure_tail_bound > 2 * stats.perf.closure_candidate_words + slack) return error.ConnectivityOnewayReserveRatio;
}

// Fails when a toggle reaction relocated, landed, allocated, or freed a block, or its closure
// batches grew or shrank the batch tail (the capacity the reaction's perf counters hold after
// its last batch left `tail_capacity`, the capacity before it): a toggle in place touches only
// its own system's rows. The counter, not the live tail, so a staging release closing the
// reaction's step is not charged to the toggle.
fn checkOnewayIsolated(stats: NavUpdateStats, tail_capacity: usize) !void {
    if (stats.perf.closure_landed_words != 0 or stats.perf.closure_tail_used != 0) return error.ConnectivityOnewayBallastLanded;
    if (stats.perf.closure_block_allocs != 0 or stats.perf.closure_block_frees != 0) return error.ConnectivityOnewayBallastBlocks;
    if (stats.perf.closure_tail_capacity != tail_capacity) return error.ConnectivityOnewayBallastTail;
}

// Blocks `cells` (open before) and runs the nav reaction, then reopens them and runs it again
// on `revert_tuners` (swapped in and out untimed).
fn runToggle(io: std.Io, case: suite.BenchmarkCase, fixture: *ReactFixture, cells: []const CellCoord, thread_system: *ThreadSystem, checks: ToggleChecks, revert_tuners: *fixtures.NavTuners) !ToggleSample {
    const tail_capacity = fixture.system.graph.connectivity.closure.tail.capacity;
    const change = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_system);
    try checkOnewayWithinBounds(fixture, change.stats, checks.fixed_blocks);
    if (checks.untouched) try checkOnewayUntouched(change.stats);
    if (checks.isolated) try checkOnewayIsolated(change.stats, tail_capacity);
    const stats = change.stats;
    const perf = stats.perf;
    // Every chunk-partitioned stage runs on workers in a fixed threaded case, and the
    // round-folded flood and closure rows when a round spans more than one range.
    try suite.checkNavReactionDispatched(case, thread_system, change.mark, stats);
    if (checks.flood_bound) |bound| {
        if (perf.conn_flood_nodes == 0 or perf.conn_flood_nodes > bound) return error.ConnectivitySplitFloodPastBound;
    }
    if (checks.exact_flood) |nodes| {
        if (perf.conn_flood_nodes != nodes) return error.ConnectivitySplitFloodPastBound;
    }
    if (checks.more_searches_than_rounds and stats.perf.conn_flood_batch.item_count <= perf.conn_rounds) return error.ConnectivitySplitPocketsRounds;
    if (checks.flood_dispatch) try suite.checkStageDispatched(case, thread_system, case.stageItemsPerRangeForPartition(suite.chunk_partition_items, 1), stats.perf.conn_flood_batch);
    const revert = revert: {
        fixtures.swapNavTuners(&fixture.system, revert_tuners);
        defer fixtures.swapNavTuners(&fixture.system, revert_tuners);
        const reaction = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_system);
        try suite.checkNavReactionDispatched(case, thread_system, reaction.mark, reaction.stats);
        try checkOnewayWithinBounds(fixture, reaction.stats, checks.fixed_blocks);
        if (checks.untouched) try checkOnewayUntouched(reaction.stats);
        break :revert reaction;
    };
    if (checks.isolated) try checkOnewayIsolated(revert.stats, tail_capacity);
    // An opening floods nothing.
    if (revert.stats.perf.conn_flood_nodes != 0) return error.ConnectivityOpeningFlooded;
    // A toggle and its revert never resize a one-way block.
    if (checks.fixed_blocks and (change.stats.perf.closure_shrinks != 0 or revert.stats.perf.closure_shrinks != 0)) return error.ConnectivityOnewayShrinkFlip;
    if (checks.reserve_ratio) {
        try checkOnewayReserve(change.stats);
        try checkOnewayReserve(revert.stats);
    }
    return .{ .change = change, .revert = revert };
}

// The stage a toggle group is judged on, its headline: the split's flood or the one-way
// closure's rows.
const ToggleHeadline = enum { flood, rows };

// The timed toggles' change and revert reactions: their times and main-thread share, printed
// under --details; and, for the workload column, the change reactions' stage shapes over the
// samples (`NavReactionShapes`), their connectivity and closure summary beside the revert's
// flood nodes, and both reactions' main-thread split.
const ToggleReport = struct {
    samples: usize = 0,
    change_ns: u128 = 0,
    revert_ns: u128 = 0,
    main_ns: u128 = 0,
    shapes: suite.NavReactionShapes = .{},
    revert_flood_nodes: usize = 0,
    // Summed over both reactions of every sample.
    closure_shrinks: usize = 0,
    closure_block_allocs: usize = 0,
    closure_block_frees: usize = 0,
    closure_landed_words: usize = 0,
    // The change reactions' closure rows on workers, summed.
    closure_rows_off_main_ns: u64 = 0,
    // The sample reaction with the larger closure tail bound.
    reserve: NavUpdateStats = .{},
    nav_main: suite.NavMainSummary = .{},

    fn add(self: *ToggleReport, sample: ToggleSample) void {
        const change = sample.change.stats;
        const revert = sample.revert.stats;
        self.samples += 1;
        self.change_ns += sample.change.elapsed_ns;
        self.revert_ns += sample.revert.elapsed_ns;
        const change_off_main_ns = change.perf.off_main_stage_ns;
        const revert_off_main_ns = revert.perf.off_main_stage_ns;
        self.main_ns += (sample.change.elapsed_ns -| change_off_main_ns) + (sample.revert.elapsed_ns -| revert_off_main_ns);
        self.nav_main.add(sample.change.elapsed_ns -| change_off_main_ns, change);
        self.nav_main.add(sample.revert.elapsed_ns -| revert_off_main_ns, revert);
        self.nav_main.endSample();
        self.shapes.add(sample.change.mark, change);
        self.closure_rows_off_main_ns += offMainNs(change.perf.conn_closure_rows_batch);
        self.revert_flood_nodes = revert.perf.conn_flood_nodes;
        self.closure_shrinks += change.perf.closure_shrinks + revert.perf.closure_shrinks;
        self.closure_block_allocs += change.perf.closure_block_allocs + revert.perf.closure_block_allocs;
        self.closure_block_frees += change.perf.closure_block_frees + revert.perf.closure_block_frees;
        self.closure_landed_words += change.perf.closure_landed_words + revert.perf.closure_landed_words;
        if (self.samples == 1 or @max(change.perf.closure_tail_bound, revert.perf.closure_tail_bound) > self.reserve.perf.closure_tail_bound) {
            self.reserve = if (revert.perf.closure_tail_bound > change.perf.closure_tail_bound) revert else change;
        }
    }

    // Each stage's busiest batch with its threaded over non-empty batches across the
    // samples, the connectivity summary, and the main-thread split into `stats`.
    fn summarize(self: ToggleReport, stats: *suite.RunStats, flood_tuner_workers: ?usize) void {
        stats.nav_main = self.nav_main;
        self.shapes.summarize(stats, flood_tuner_workers);
        var conn = stats.nav_conn.?;
        conn.reopen_flood_nodes = self.revert_flood_nodes;
        conn.closure_shrinks = self.closure_shrinks;
        conn.closure_block_allocs = self.closure_block_allocs;
        conn.closure_block_frees = self.closure_block_frees;
        conn.closure_landed_words = self.closure_landed_words;
        conn.closure_rows_off_main_ns = if (self.samples == 0) 0 else self.closure_rows_off_main_ns / self.samples;
        conn.closure_tail_bound = self.reserve.perf.closure_tail_bound;
        conn.closure_tail_used = self.reserve.perf.closure_tail_used;
        conn.closure_candidate_words = self.reserve.perf.closure_candidate_words;
        conn.closure_kb = self.reserve.perf.closure_kb;
        stats.nav_conn = conn;
    }

    fn write(self: ToggleReport, details: *suite.DetailLines) void {
        if (self.samples == 0) return;
        const samples: u128 = self.samples * std.time.ns_per_us;
        const timed_ns = self.change_ns + self.revert_ns;
        details.print("block={}us reopen={}us main={}us ({}%)\n", .{
            @as(u64, @intCast(self.change_ns / samples)),
            @as(u64, @intCast(self.revert_ns / samples)),
            @as(u64, @intCast(self.main_ns / samples)),
            @as(u64, @intCast(if (timed_ns == 0) 0 else self.main_ns * 100 / timed_ns)),
        });
    }
};

// Times `options.iterations` toggles of `cells` after the warmup and, for the tuned case, the
// settle of both stage tuner sets; each toggle after an untimed retire of `ballast` when there
// is one. Items/s is the cells flipped per second; the headline batch and tuner are the change
// reaction's `headline` stage. The revert runs on its own stage tuner set, copied from the
// fixture's, so each set learns one workload; the retire's reactions keep the tuners as they
// were (`OnewayBallast.untimedReaction`).
fn runToggleSamples(io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, fixture: *ReactFixture, cells: []const CellCoord, thread_system: *ThreadSystem, checks: ToggleChecks, ballast: ?*OnewayBallast, headline: ToggleHeadline) !suite.RunStats {
    var revert_tuners = fixture.system.tuners;
    var warm = suite.Warmup.init(options, case, 0);
    while (warm.nextSettled(toggleTunerSettle(fixture, &revert_tuners))) {
        if (ballast) |chain| try chain.retire(io, fixture, thread_system);
        _ = try runToggle(io, case, fixture, cells, thread_system, checks, &revert_tuners);
    }
    const settle = toggleTunerSettle(fixture, &revert_tuners);
    const headline_stage: NavStage = switch (headline) {
        .flood => .conn_flood,
        .rows => .conn_closure_rows,
    };
    const headline_tuner = fixture.system.tuners.nav.getPtrConst(headline_stage);
    const headline_start = suite.TunerStart.of(headline_tuner, case);
    var accumulator = suite.StatsAccumulator.init(item_count);
    var report = ToggleReport{};
    for (0..options.iterations) |_| {
        if (ballast) |chain| try chain.retire(io, fixture, thread_system);
        const sample = try runToggle(io, case, fixture, cells, thread_system, checks, &revert_tuners);
        const change_perf = sample.change.stats.perf;
        accumulator.record(sample.elapsedNs(), switch (headline) {
            .flood => change_perf.conn_flood_batch,
            .rows => change_perf.conn_closure_rows_batch,
        });
        report.add(sample);
        if (ballast) |chain| chain.addSample(sample);
    }
    var stats = accumulator.finish();
    report.write(&stats.details);
    report.summarize(&stats, fixtures.floodTunerWorkers(&fixture.system, case));
    if (case.adaptive) {
        stats.tuner_settle = settle.measured();
        stats.work_tuning = suite.workTuningSummary(headline_tuner, headline_start);
    }
    stats.items_per_second = suite.itemsPerSecond(2 * cells.len, stats.mean_ns);
    return stats;
}

// Both stage tuner sets a toggle runs: the change reaction's (the fixture's) and the revert's.
fn toggleTunerSettle(fixture: *const ReactFixture, revert_tuners: *const fixtures.NavTuners) suite.TunerSettle {
    var census = fixtures.navTunerSettle("", &fixture.system.tuners);
    fixtures.addNavTuners(&census, "revert.", revert_tuners);
    return census;
}

const SplitVariant = enum(u8) {
    // A room sealed by blocking the gap chunk of its wall.
    room,
    // A ring corridor cut, not split, by blocking one of its chunks.
    ring,
    // A one-chunk tunnel sealed by blocking its mouth chunk.
    tunnel,
    // Two ringed rooms sealed in one batch.
    rooms,
    // Room A, its east neighbour split by a wall written before the build.
    walled,
    // One ring cut on its west and east chunks in one batch.
    ring_arcs,
    // A comb of dead-end tunnels off one corridor.
    hub,
    // One ringed room under the default flood cap and a four-proposal cap.
    budget,
    // Eight ringed rooms sealed in one batch.
    pockets,
};

const SplitConfig = struct {
    variant: SplitVariant,
    edge_chunks: u16,
    side: u16,

    fn decode(item_count: usize) !SplitConfig {
        const code = try SplitCode.decode(item_count);
        if (code.levels != 1) return error.ConnectivitySplitNotOneLevel;
        if (code.edge_chunks == 0) return error.ConnectivitySplitNoEdge;
        return .{ .variant = code.variant, .edge_chunks = code.edge_chunks, .side = code.level_side };
    }

    // Chunks a side of the structure's square, its outer wall band (or the tunnel's mouth
    // and the open chunk past it) included.
    fn spanChunks(self: SplitConfig) usize {
        return switch (self.variant) {
            .room => @as(usize, self.edge_chunks) + 1,
            .ring => @as(usize, self.edge_chunks) + 3,
            .tunnel => @as(usize, self.edge_chunks) + 2,
            else => unreachable,
        };
    }

    // The most nodes sealing the gap may flood, one node per open chunk: the room side plus
    // the outside side's search, at most half again the room side's claims per round, for a
    // room or a tunnel; around the ring until both sides meet, each at most half again the
    // other's claims, plus one node's `border_stride` slack, for a ring.
    fn floodBound(self: SplitConfig, border_stride: usize) usize {
        const structure = self.structureChunks();
        return switch (self.variant) {
            .room => 3 * structure + 2,
            .ring => structure * 3 / 2 + border_stride,
            .tunnel => 3 * structure,
            else => unreachable,
        };
    }

    // The room's chunks, the ring's, or the tunnel's.
    fn structureChunks(self: SplitConfig) usize {
        const edge: usize = self.edge_chunks;
        return switch (self.variant) {
            .room => edge * edge,
            .ring => 4 * edge + 4,
            .tunnel => edge,
            else => unreachable,
        };
    }

    // Whether `cell` lies in the room, in the ring (its gap chunk included), or in the tunnel
    // (its mouth excluded).
    fn inStructure(self: SplitConfig, cell: CellCoord, chunk_tiles: usize) bool {
        const chunk_x = cell.x / chunk_tiles;
        const chunk_y = cell.y / chunk_tiles;
        const edge: usize = self.edge_chunks;
        return switch (self.variant) {
            .room => chunk_x < edge and chunk_y < edge,
            .ring => chunk_x < edge + 2 and chunk_y < edge + 2 and
                (chunk_x == 0 or chunk_y == 0 or chunk_x == edge + 1 or chunk_y == edge + 1),
            .tunnel => chunk_x < edge and chunk_y == 0,
            else => unreachable,
        };
    }

    fn inGapChunk(self: SplitConfig, cell: CellCoord, chunk_tiles: usize) bool {
        const gap = self.gapChunk();
        return cell.x / chunk_tiles == gap.x and cell.y / chunk_tiles == gap.y;
    }

    fn gapChunk(self: SplitConfig) ChunkCoord {
        return switch (self.variant) {
            // Mid-height in the room's wall column.
            .room => .{ .x = self.edge_chunks, .y = self.edge_chunks / 2 },
            // Mid-height in the ring's west side.
            .ring => .{ .x = 0, .y = (self.edge_chunks + 2) / 2 },
            // The tunnel's east mouth.
            .tunnel => .{ .x = self.edge_chunks, .y = 0 },
            else => unreachable,
        };
    }

    // The solid chunks: the room's wall band but its gap, the ring's inner block and its
    // outer wall band, or the row below the tunnel and its mouth. The level border closes the
    // structure's west and north.
    fn solidChunks(self: SplitConfig, allocator: std.mem.Allocator) ![]ChunkCoord {
        var chunks: std.ArrayList(ChunkCoord) = .empty;
        errdefer chunks.deinit(allocator);
        if (self.variant == .tunnel) {
            for (0..self.edge_chunks + 1) |x| try chunks.append(allocator, .{ .x = @intCast(x), .y = 1 });
            return chunks.toOwnedSlice(allocator);
        }
        // The outer band: the column and the row just past the room or the ring.
        const band: u16 = switch (self.variant) {
            .room => self.edge_chunks,
            .ring => self.edge_chunks + 2,
            .tunnel => unreachable,
            else => unreachable,
        };
        const gap = self.gapChunk();
        for (0..band + 1) |y| {
            const chunk = ChunkCoord{ .x = band, .y = @intCast(y) };
            if (self.variant == .room and chunk.x == gap.x and chunk.y == gap.y) continue;
            try chunks.append(allocator, chunk);
        }
        for (0..band) |x| try chunks.append(allocator, .{ .x = @intCast(x), .y = band });
        if (self.variant == .ring) {
            for (1..band - 1) |y| {
                for (1..band - 1) |x| try chunks.append(allocator, .{ .x = @intCast(x), .y = @intCast(y) });
            }
        }
        return chunks.toOwnedSlice(allocator);
    }
};

// The split fixture on a walkable level: the structure's solid chunks written, no requests.
fn initSplitFixture(allocator: std.mem.Allocator, io: std.Io, config: SplitConfig, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !ReactFixture {
    var open = try buildOpenWorld(allocator, io, config.side, 1);
    errdefer open.world.deinit();
    if (config.spanChunks() * open.world.chunk_size_tiles > config.side) return error.ConnectivitySplitStructureTooLarge;
    const solid_chunks = try config.solidChunks(allocator);
    defer allocator.free(solid_chunks);
    const solid = try chunkCells(allocator, solid_chunks, open.world.chunk_size_tiles);
    defer allocator.free(solid);
    try writeLevelZeroCells(&open, solid, open.blocking);
    try checkSplitTopology(allocator, &open.world, config);
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try allocator.alloc(PathRequest, 0);
    errdefer allocator.free(requests);
    return assembleReactFixture(allocator, &open, &data, requests, capacity, thread_system);
}

// The split structure's open cells: level 0's walkable cells, the gap chunk blocked when
// `gap_blocked`; a flood stops at the first open cell outside the structure.
const SplitFloodCells = struct {
    world: *const WorldSystem,
    config: SplitConfig,
    gap_blocked: bool,

    pub fn open(self: SplitFloodCells, x: u32, y: u32) bool {
        const cell = CellCoord{ .x = @intCast(x), .y = @intCast(y) };
        if (self.world.levelBlocksMovement(0, cell.x, cell.y)) return false;
        return !(self.gap_blocked and self.config.inGapChunk(cell, self.world.chunk_size_tiles));
    }

    pub fn stop(self: SplitFloodCells, x: u32, y: u32) bool {
        return !self.config.inStructure(.{ .x = @intCast(x), .y = @intCast(y) }, self.world.chunk_size_tiles);
    }
};

// Untimed: a 4-connected flood over level 0's open cells from the level origin, which lies in
// the room or the ring. The corner rule lets a diagonal step only through two open orthogonal
// cells, so 4-connected components equal the nav's.
fn floodSplitStructure(allocator: std.mem.Allocator, world: *const WorldSystem, config: SplitConfig, gap_blocked: bool) !fixtures.Flood {
    if (world.levelBlocksMovement(0, 0, 0)) return error.ConnectivitySplitSeedBlocked;
    var reached = try std.DynamicBitSetUnmanaged.initEmpty(allocator, @as(usize, world.width) * world.height);
    defer reached.deinit(allocator);
    return fixtures.flood4(allocator, world.width, world.height, .{ 0, 0 }, SplitFloodCells{ .world = world, .config = config, .gap_blocked = gap_blocked }, &reached);
}

// Fails unless the layout has the shape its variant claims. Room: with the gap blocked the
// room's cells reach one another and nothing outside; with it open they reach outside. Ring:
// with the gap blocked every other ring cell reaches every other and nothing outside.
fn checkSplitTopology(allocator: std.mem.Allocator, world: *const WorldSystem, config: SplitConfig) !void {
    const chunk_cells = @as(usize, world.chunk_size_tiles) * world.chunk_size_tiles;
    const sealed = try floodSplitStructure(allocator, world, config, true);
    switch (config.variant) {
        .room, .tunnel => {
            if (sealed.stopped) return error.ConnectivitySplitRoomNotSealed;
            if (sealed.reached != config.structureChunks() * chunk_cells) return error.ConnectivitySplitRoomNotOneArea;
            const opened = try floodSplitStructure(allocator, world, config, false);
            if (!opened.stopped) return error.ConnectivitySplitRoomGapClosed;
        },
        .ring => {
            if (sealed.stopped) return error.ConnectivitySplitRingNotEnclosed;
            if (sealed.reached != (config.structureChunks() - 1) * chunk_cells) return error.ConnectivitySplitRingSplit;
        },
        else => unreachable,
    }
}

// Untimed, the stage tuners kept as they were: seals the room's gap together with a fill of
// one cell far off in the open level, then reverts both. Fails unless the flood expands
// exactly the room's `room_flood_nodes`: a removal's flood follows its own side, never
// another change in the batch.
fn checkFarFillAddsNothing(allocator: std.mem.Allocator, io: std.Io, fixture: *ReactFixture, config: SplitConfig, gap: []const CellCoord, room_flood_nodes: usize, thread_system: *ThreadSystem) !void {
    const chunk_tiles = fixture.open.world.chunk_size_tiles;
    const far = CellCoord{ .x = @intCast(config.side - chunk_tiles / 2), .y = @intCast(config.side - chunk_tiles / 2) };
    if (config.inStructure(far, chunk_tiles)) return error.ConnectivitySplitFarFillInRoom;
    const cells = try allocator.alloc(CellCoord, gap.len + 1);
    defer allocator.free(cells);
    @memcpy(cells[0..gap.len], gap);
    cells[gap.len] = far;
    try fixture.changed.ensureTotalCapacity(allocator, cells.len);
    const tuners = fixture.system.tuners;
    defer fixture.system.tuners = tuners;
    const sealed = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_system);
    _ = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_system);
    if (sealed.stats.perf.conn_flood_nodes != room_flood_nodes) return error.ConnectivitySplitFarFillFlooded;
}

fn runConnectivitySplitCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try SplitConfig.decode(item_count);
    switch (config.variant) {
        .room, .ring, .tunnel => {},
        else => return runSplitProofCase(allocator, io, options, case, item_count, config),
    }
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    // The gap chunk's cells.
    const size_config = toggleSizeConfig(config.side, 1, 0, participant_count, .{ .mark_chunks = default_chunk_size_tiles * default_chunk_size_tiles, .links = 0, .keys = toggle_batch_keys });
    try nav_size.checkNavSize(connectivity_split_group.name, item_count, case, size_config);

    var fixture = try initSplitFixture(allocator, io, config, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try nav_size.checkNavBytes(connectivity_split_group.name, item_count, size_config, &fixture.system);
    const gap = try chunkCells(allocator, &.{config.gapChunk()}, fixture.open.world.chunk_size_tiles);
    defer allocator.free(gap);
    try fixture.changed.ensureTotalCapacity(allocator, gap.len);
    fixtures.setNavTuners(&fixture.system, case);

    const flood_bound = config.floodBound(fixture.system.graph.levelGraph(0).?.border_stride);
    var stats = try runToggleSamples(io, options, case, item_count, &fixture, gap, thread_ptr, .{ .flood_bound = flood_bound }, null, .flood);
    if (config.variant == .room) {
        try checkFarFillAddsNothing(allocator, io, &fixture, config, gap, stats.nav_conn.?.flood_nodes, thread_ptr);
        try checkLevelBuildFloodFolds(allocator, io, thread_ptr);
    }
    try nav_size.checkNavBytes(connectivity_split_group.name, item_count, size_config, &fixture.system);
    stats.output_count = gap.len;
    stats.candidate_pairs = config.structureChunks();
    return stats;
}

// Untimed: a level build whose rebuild removes the only links between two halves of another
// level floods that level, and the build's flood folds into the reaction's
// `conn_flood_batch` (the perf log's `nav_connect`). A 32-tile two-level world: a wall
// column splits level 0, two stairs join its halves through level 1, then a dense
// obstacle layer over level 1 (a content change with no cell events) rebuilds that level.
fn checkLevelBuildFloodFolds(allocator: std.mem.Allocator, io: std.Io, thread_system: *ThreadSystem) !void {
    const side: u16 = 32;
    var open = try buildOpenWorld(allocator, io, side, 2);
    defer open.world.deinit();
    var wall: [side]CellCoord = undefined;
    for (&wall, 0..) |*cell, y| cell.* = .{ .x = side / 2, .y = @intCast(y) };
    try writeLevelZeroCells(&open, &wall, open.blocking);
    for ([_]CellCoord{ .{ .x = 2, .y = 2 }, .{ .x = side - 4, .y = side - 4 } }) |cell| {
        try open.world.addLevelLink(.{ .kind = .stair, .level_a = 0, .cell_a = cell, .level_b = 1, .cell_b = cell, .traversal_cost = 1, .bidirectional = true });
    }
    var data = DataSystem.init(allocator);
    defer data.deinit();
    var colliders = StaticColliderSystem.init(allocator);
    defer colliders.deinit();
    var system = PathfindingSystem.init(allocator);
    defer system.deinit();
    try system.reserve(nav_size.navSizeCapacity(toggleSizeConfig(side, 2, 2, fixtures.participantCount(thread_system), toggle_batch)));
    try system.rebuildStaticNavGridWithWorld(&data, &open.world, thread_system);
    _ = try open.world.addDenseLayer(1, 0, .obstacle, open.blocking);
    const stats = try system.applyBufferedNavUpdates(&colliders, &open.world, thread_system);
    if (stats.levels_built != 1) return error.ConnectivityLevelBuildMissing;
    if (stats.perf.conn_flood_batch.item_count == 0) return error.ConnectivityLevelBuildFloodNotFolded;
}

// The flat-in-side proofs compare a larger level with this one. It is the smallest side the
// new codes sweep.
const split_proof_reference_side: u16 = 256;
const no_cells: []const CellCoord = &.{};

const ProofCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    options: suite.Options,
    case: suite.BenchmarkCase,
    item_count: usize,
    threads: *ThreadSystem,
    participants: usize,
};

const ProofFixture = struct {
    fixture: ReactFixture,
    gaps: []CellCoord,
    // `gaps[0..first_gap]` is the first room when two rooms share the seal list; 0 when the
    // list is one seal.
    first_gap: usize,
    config: SplitConfig,
    batch_chunks: usize,
    allocator: std.mem.Allocator,

    fn deinit(self: *ProofFixture) void {
        self.allocator.free(self.gaps);
        self.fixture.deinit(self.allocator);
    }

    fn gapA(self: ProofFixture) []CellCoord {
        return self.gaps[0..self.first_gap];
    }

    fn gapB(self: ProofFixture) []CellCoord {
        return self.gaps[self.first_gap..];
    }
};

const RoomFloods = struct {
    a: usize,
    b: usize,
    both: usize,
};

const WalledFloods = struct {
    room_a: usize,
    walled: usize,
};

fn levelChunks(side: u16) !u16 {
    if (side < default_chunk_size_tiles or side % default_chunk_size_tiles != 0) return error.ConnectivitySplitStructureTooLarge;
    return side / default_chunk_size_tiles;
}

fn cellsBatch(chunks: usize) nav_size.NavBatch {
    const tiles: usize = default_chunk_size_tiles;
    return .{ .mark_chunks = chunks * tiles * tiles, .links = 0, .keys = chunks * toggle_batch_keys };
}

fn proofSizeConfig(ctx: *const ProofCtx, config: SplitConfig, batch_chunks: usize) nav_size.NavSizeConfig {
    return toggleSizeConfig(config.side, 1, 0, ctx.participants, cellsBatch(batch_chunks));
}

fn proofStructureChunks(config: SplitConfig) usize {
    const edge: usize = config.edge_chunks;
    return switch (config.variant) {
        .rooms => 2 * edge * edge,
        .walled, .budget => edge * edge,
        .ring_arcs => 4 * edge + 4,
        .hub => edge,
        .pockets => 8 * edge * edge,
        else => unreachable,
    };
}

fn referenceConfig(config: SplitConfig) SplitConfig {
    return .{ .variant = config.variant, .edge_chunks = config.edge_chunks, .side = split_proof_reference_side };
}

fn expectBlocks(world: *const WorldSystem, cell: CellCoord, blocks: bool) !void {
    if (world.levelBlocksMovement(0, cell.x, cell.y) != blocks) return error.ConnectivitySplitTopology;
}

// `x` and `y` are inside the level, whose chunk count fits `u16`.
fn appendChunk(chunks: *std.ArrayList(ChunkCoord), allocator: std.mem.Allocator, x: usize, y: usize, side_chunks: u16) !void {
    if (x >= side_chunks or y >= side_chunks) return error.ConnectivitySplitStructureTooLarge;
    try chunks.append(allocator, .{ .x = @intCast(x), .y = @intCast(y) });
}

fn requireChunk(chunk: ChunkCoord, side_chunks: u16) !void {
    if (chunk.x >= side_chunks or chunk.y >= side_chunks) return error.ConnectivitySplitStructureTooLarge;
}

// The test's ringed room: a one-chunk wall around an `edge` square whose only opening is the
// east gap. Appends the wall and returns the gap.
fn appendRingedRoom(chunks: *std.ArrayList(ChunkCoord), allocator: std.mem.Allocator, origin_x: usize, origin_y: usize, edge: u16, side_chunks: u16) !ChunkCoord {
    const edge_chunks: usize = edge;
    const gap_x = origin_x + edge_chunks + 1;
    const gap_y = origin_y + 1 + edge_chunks / 2;
    const span = edge_chunks + 2;
    for (0..span) |dy| {
        for (0..span) |dx| {
            const on_ring = dx == 0 or dy == 0 or dx == edge_chunks + 1 or dy == edge_chunks + 1;
            if (!on_ring or (origin_x + dx == gap_x and origin_y + dy == gap_y)) continue;
            try appendChunk(chunks, allocator, origin_x + dx, origin_y + dy, side_chunks);
        }
    }
    if (gap_x >= side_chunks or gap_y >= side_chunks) return error.ConnectivitySplitStructureTooLarge;
    return .{ .x = @intCast(gap_x), .y = @intCast(gap_y) };
}

fn roomPairOrigins(side_chunks: u16) ![2][2]usize {
    // Room B sits at the far corner with a gap of open chunks between it and room A.
    if (side_chunks < 16) return error.ConnectivitySplitStructureTooLarge;
    const chunks: usize = side_chunks;
    return .{ .{ 1, 1 }, .{ chunks - 6, chunks - 6 } };
}

// The long wall through the gap's east neighbour, plus the two cells that close its near end.
// Coordinates stay inside the level, so they fit `u16`.
fn walledNeighbourCells(allocator: std.mem.Allocator, gap: ChunkCoord, side: u16) ![]CellCoord {
    const tiles: u32 = default_chunk_size_tiles;
    const side_chunks: u32 = side / default_chunk_size_tiles;
    const left: u32 = (@as(u32, gap.x) + 1) * tiles;
    // One cell above the chunk's bottom row. A 4-tile chunk puts that on row +2, which is
    // where the wall sat, so the south label stays one cell tall.
    const wall_y: u32 = @as(u32, gap.y) * tiles + tiles - 2;
    if (side_chunks < 2 or left + 1 >= (side_chunks - 1) * tiles or wall_y + 1 >= side) return error.ConnectivitySplitStructureTooLarge;
    const end: u32 = (side_chunks - 1) * tiles;
    const span: usize = end - (left + 1);
    const cells = try allocator.alloc(CellCoord, span + 2);
    for (0..span) |index| cells[index] = .{ .x = @intCast(left + 1 + index), .y = @intCast(wall_y) };
    cells[span] = .{ .x = @intCast(left), .y = @intCast(wall_y + 1) };
    cells[span + 1] = .{ .x = @intCast(left + 1), .y = @intCast(wall_y + 1) };
    return cells;
}

fn appendRingCutSolids(chunks: *std.ArrayList(ChunkCoord), allocator: std.mem.Allocator, edge: u16, side_chunks: u16) !void {
    const span: usize = @as(usize, edge) + 2;
    for (1..span - 1) |y| {
        for (1..span - 1) |x| try appendChunk(chunks, allocator, x, y, side_chunks);
    }
    for (0..span + 1) |index| {
        try appendChunk(chunks, allocator, span, index, side_chunks);
        if (index != span) try appendChunk(chunks, allocator, index, span, side_chunks);
    }
}

fn ringCuts(edge: u16) [2]ChunkCoord {
    const span: u16 = edge + 2;
    const mid = span / 2;
    return .{ .{ .x = 0, .y = mid }, .{ .x = span - 1, .y = mid } };
}

fn appendHubSolids(chunks: *std.ArrayList(ChunkCoord), allocator: std.mem.Allocator, tunnels: u16, joined: bool) !void {
    const side: usize = @as(usize, tunnels) * 2;
    // The comb is the whole level, and a level side fits `u16`.
    if (side > @as(usize, std.math.maxInt(u16))) return error.ConnectivitySplitStructureTooLarge;
    const side_chunks: u16 = @intCast(side);
    for (1..side) |y| {
        var x: usize = 1;
        while (x < side) : (x += 2) {
            const bottom_link = joined and y == side - 1 and x % 4 == 3 and x + 1 < side - 1;
            if (!bottom_link) try appendChunk(chunks, allocator, x, y, side_chunks);
        }
    }
}

fn buildProof(
    ctx: *const ProofCtx,
    config: SplitConfig,
    solids: []const ChunkCoord,
    extra: []const CellCoord,
    gap_chunks: []const ChunkCoord,
    first_gap_chunks: usize,
    batch_chunks: usize,
) !ProofFixture {
    const size_config = proofSizeConfig(ctx, config, batch_chunks);
    try nav_size.checkNavSize(connectivity_split_group.name, ctx.item_count, ctx.case, size_config);
    var open = try buildOpenWorld(ctx.allocator, ctx.io, config.side, 1);
    errdefer open.world.deinit();
    if (solids.len != 0) {
        const solid_cells = try chunkCells(ctx.allocator, solids, open.world.chunk_size_tiles);
        defer ctx.allocator.free(solid_cells);
        try writeLevelZeroCells(&open, solid_cells, open.blocking);
        try expectBlocks(&open.world, solid_cells[0], true);
    }
    if (extra.len != 0) {
        try writeLevelZeroCells(&open, extra, open.blocking);
        try expectBlocks(&open.world, extra[0], true);
    }
    if (gap_chunks.len == 0) return error.ConnectivitySplitNoEdge;
    const gap_cells = try chunkCells(ctx.allocator, gap_chunks, open.world.chunk_size_tiles);
    errdefer ctx.allocator.free(gap_cells);
    const per_chunk = @as(usize, open.world.chunk_size_tiles) * open.world.chunk_size_tiles;
    const first = first_gap_chunks * per_chunk;
    if (gap_cells.len == 0 or first > gap_cells.len) return error.ConnectivitySplitTopology;
    try expectBlocks(&open.world, gap_cells[0], false);
    var data = DataSystem.init(ctx.allocator);
    errdefer data.deinit();
    const requests = try ctx.allocator.alloc(PathRequest, 0);
    errdefer ctx.allocator.free(requests);
    const fixture = try assembleReactFixture(ctx.allocator, &open, &data, requests, nav_size.navSizeCapacity(size_config), ctx.threads);
    return .{
        .fixture = fixture,
        .gaps = gap_cells,
        .first_gap = first,
        .config = config,
        .batch_chunks = batch_chunks,
        .allocator = ctx.allocator,
    };
}

fn prepareProof(ctx: *const ProofCtx, proof: *ProofFixture) !void {
    try proof.fixture.changed.ensureTotalCapacity(ctx.allocator, proof.gaps.len);
    fixtures.setNavTuners(&proof.fixture.system, ctx.case);
    const size_config = proofSizeConfig(ctx, proof.config, proof.batch_chunks);
    try nav_size.checkNavBytes(connectivity_split_group.name, ctx.item_count, size_config, &proof.fixture.system);
}

fn openProof(
    ctx: *const ProofCtx,
    config: SplitConfig,
    solids: []const ChunkCoord,
    extra: []const CellCoord,
    gap_chunks: []const ChunkCoord,
    first_gap_chunks: usize,
    batch_chunks: usize,
) !ProofFixture {
    var proof = try buildProof(ctx, config, solids, extra, gap_chunks, first_gap_chunks, batch_chunks);
    errdefer proof.deinit();
    try prepareProof(ctx, &proof);
    return proof;
}

fn openRooms(ctx: *const ProofCtx, config: SplitConfig) !ProofFixture {
    if (config.edge_chunks != 2) return error.ConnectivitySplitStructureTooLarge;
    const side_chunks = try levelChunks(config.side);
    const origins = try roomPairOrigins(side_chunks);
    var solids: std.ArrayList(ChunkCoord) = .empty;
    defer solids.deinit(ctx.allocator);
    var gaps: [2]ChunkCoord = undefined;
    for (origins, &gaps) |origin, *gap| gap.* = try appendRingedRoom(&solids, ctx.allocator, origin[0], origin[1], config.edge_chunks, side_chunks);
    const solid_owned = try solids.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(solid_owned);
    return openProof(ctx, config, solid_owned, no_cells, &gaps, 1, gaps.len);
}

fn openRoomA(ctx: *const ProofCtx, config: SplitConfig, wall: bool) !ProofFixture {
    const side_chunks = try levelChunks(config.side);
    var solids: std.ArrayList(ChunkCoord) = .empty;
    defer solids.deinit(ctx.allocator);
    const gap = try appendRingedRoom(&solids, ctx.allocator, 1, 1, config.edge_chunks, side_chunks);
    const solid_owned = try solids.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(solid_owned);
    const extra = if (wall) try walledNeighbourCells(ctx.allocator, gap, config.side) else try ctx.allocator.alloc(CellCoord, 0);
    defer ctx.allocator.free(extra);
    return openProof(ctx, config, solid_owned, extra, &.{gap}, 0, 1);
}

fn openRingArcs(ctx: *const ProofCtx, config: SplitConfig) !ProofFixture {
    const side_chunks = try levelChunks(config.side);
    var solids: std.ArrayList(ChunkCoord) = .empty;
    defer solids.deinit(ctx.allocator);
    try appendRingCutSolids(&solids, ctx.allocator, config.edge_chunks, side_chunks);
    const cuts = ringCuts(config.edge_chunks);
    try requireChunk(cuts[0], side_chunks);
    try requireChunk(cuts[1], side_chunks);
    const solid_owned = try solids.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(solid_owned);
    return openProof(ctx, config, solid_owned, no_cells, &cuts, 0, cuts.len);
}

fn openHub(ctx: *const ProofCtx, config: SplitConfig, joined: bool) !ProofFixture {
    const side_chunks = try levelChunks(config.side);
    if (@as(usize, side_chunks) != @as(usize, config.edge_chunks) * 2) return error.ConnectivitySplitStructureTooLarge;
    var solids: std.ArrayList(ChunkCoord) = .empty;
    defer solids.deinit(ctx.allocator);
    try appendHubSolids(&solids, ctx.allocator, config.edge_chunks, joined);
    const solid_owned = try solids.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(solid_owned);
    const corridor = try ctx.allocator.alloc(ChunkCoord, @as(usize, side_chunks));
    defer ctx.allocator.free(corridor);
    for (corridor, 0..) |*chunk, x| chunk.* = .{ .x = @intCast(x), .y = 0 };
    return openProof(ctx, config, solid_owned, no_cells, corridor, 0, corridor.len);
}

fn openPockets(ctx: *const ProofCtx, config: SplitConfig) !ProofFixture {
    // The eight-room arm: pitch 6 is the spacing of edge-2 rooms.
    if (config.edge_chunks != 2) return error.ConnectivitySplitStructureTooLarge;
    const side_chunks = try levelChunks(config.side);
    var solids: std.ArrayList(ChunkCoord) = .empty;
    defer solids.deinit(ctx.allocator);
    var gaps: [8]ChunkCoord = undefined;
    for (&gaps, 0..) |*gap, index| {
        const origin_x = 1 + 6 * (index % 4);
        const origin_y = 1 + 6 * (index / 4);
        gap.* = try appendRingedRoom(&solids, ctx.allocator, origin_x, origin_y, config.edge_chunks, side_chunks);
    }
    const solid_owned = try solids.toOwnedSlice(ctx.allocator);
    defer ctx.allocator.free(solid_owned);
    return openProof(ctx, config, solid_owned, no_cells, &gaps, 0, gaps.len);
}

// Seals `cells` and reopens them. The stage tuners are put back, so the timed samples still
// start from the case's fresh tuners.
fn untimedSeal(io: std.Io, fixture: *ReactFixture, cells: []const CellCoord, thread_system: *ThreadSystem) !NavUpdateStats {
    const tuners = fixture.system.tuners;
    defer fixture.system.tuners = tuners;
    const sealed = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_system);
    const opened = try fixture.changeAndReact(io, cells, fixture.open.walkable, thread_system);
    if (opened.stats.perf.conn_flood_nodes != 0) return error.ConnectivityOpeningFlooded;
    return sealed.stats;
}

fn untimedHubSeal(ctx: *const ProofCtx, proof: *ProofFixture, narrow: bool) !NavUpdateStats {
    const conn = &proof.fixture.system.graph.connectivity;
    const saved = conn.flood_window;
    defer conn.flood_window = saved;
    if (narrow) {
        // One node's slack plus four proposal slots.
        const level = proof.fixture.system.graph.levelGraph(0) orelse return error.ConnectivitySplitNoLevel;
        conn.flood_window = level.border_stride + conn.max_chunk_endpoints + 4;
    } else {
        conn.flood_window = default_flood_window;
    }
    return untimedSeal(ctx.io, &proof.fixture, proof.gaps, ctx.threads);
}

fn untimedBudgetSeal(ctx: *const ProofCtx, proof: *ProofFixture, cap: u32) !NavUpdateStats {
    const conn = &proof.fixture.system.graph.connectivity;
    const saved = conn.flood_budget_cap;
    defer conn.flood_budget_cap = saved;
    conn.flood_budget_cap = cap;
    return untimedSeal(ctx.io, &proof.fixture, proof.gaps, ctx.threads);
}

fn expectRooms(floods: RoomFloods, reference: ?RoomFloods) !void {
    if (floods.a == 0 or floods.b == 0) return error.ConnectivitySplitFloodPastBound;
    if (floods.both != floods.a + floods.b) return error.ConnectivitySplitRoomsNotSum;
    if (reference) |earlier| {
        if (floods.a != earlier.a or floods.b != earlier.b or floods.both != earlier.both) return error.ConnectivitySplitNotFlat;
    }
}

fn expectWalled(floods: WalledFloods, reference: ?WalledFloods) !void {
    if (floods.room_a == 0 or floods.walled == 0) return error.ConnectivitySplitFloodPastBound;
    if (floods.walled > 2 * floods.room_a) return error.ConnectivitySplitWalledPastBound;
    if (reference) |earlier| {
        if (floods.room_a != earlier.room_a or floods.walled != earlier.walled) return error.ConnectivitySplitNotFlat;
    }
}

fn expectRingArc(flood: usize, edge: u16, reference: ?usize) !void {
    // The ring's chunks but the two cuts, halved: the smaller arc.
    const arc = (4 * (@as(usize, edge) + 1) - 2) / 2;
    if (flood == 0 or flood > 4 * arc + 4) return error.ConnectivitySplitRingArcPastBound;
    if (reference) |nodes| if (flood != nodes) return error.ConnectivitySplitNotFlat;
}

fn expectHub(wide: NavUpdateStats, narrow: NavUpdateStats, tunnels: usize) !void {
    if (wide.perf.conn_round_items_max != tunnels) return error.ConnectivitySplitHubWideItems;
    if (4 * narrow.perf.conn_round_items_max > tunnels) return error.ConnectivitySplitHubNarrowItems;
    if (narrow.perf.conn_rounds < 4 * wide.perf.conn_rounds) return error.ConnectivitySplitHubRounds;
    if (narrow.perf.conn_build_visits > 2 * wide.perf.conn_build_visits) return error.ConnectivitySplitHubVisits;
}

fn expectBudget(wide: NavUpdateStats, narrow: NavUpdateStats) !void {
    if (narrow.perf.conn_rounds <= wide.perf.conn_rounds) return error.ConnectivitySplitBudgetRounds;
    if (narrow.perf.conn_round_items_max > 2) return error.ConnectivitySplitBudgetItems;
}

fn measureRooms(ctx: *const ProofCtx, proof: *ProofFixture) !RoomFloods {
    if (proof.first_gap == 0 or proof.first_gap >= proof.gaps.len) return error.ConnectivitySplitTopology;
    const room_a = try untimedSeal(ctx.io, &proof.fixture, proof.gapA(), ctx.threads);
    const room_b = try untimedSeal(ctx.io, &proof.fixture, proof.gapB(), ctx.threads);
    const both = try untimedSeal(ctx.io, &proof.fixture, proof.gaps, ctx.threads);
    return .{ .a = room_a.perf.conn_flood_nodes, .b = room_b.perf.conn_flood_nodes, .both = both.perf.conn_flood_nodes };
}

fn roomAFlood(ctx: *const ProofCtx, config: SplitConfig) !usize {
    var proof = try openRoomA(ctx, config, false);
    defer proof.deinit();
    const stats = try untimedSeal(ctx.io, &proof.fixture, proof.gaps, ctx.threads);
    return stats.perf.conn_flood_nodes;
}

fn measureWalled(ctx: *const ProofCtx, config: SplitConfig) !WalledFloods {
    const room_a = try roomAFlood(ctx, config);
    var proof = try openRoomA(ctx, config, true);
    defer proof.deinit();
    const stats = try untimedSeal(ctx.io, &proof.fixture, proof.gaps, ctx.threads);
    return .{ .room_a = room_a, .walled = stats.perf.conn_flood_nodes };
}

fn ringFlood(ctx: *const ProofCtx, config: SplitConfig) !usize {
    var proof = try openRingArcs(ctx, config);
    defer proof.deinit();
    const stats = try untimedSeal(ctx.io, &proof.fixture, proof.gaps, ctx.threads);
    return stats.perf.conn_flood_nodes;
}

fn timeProof(ctx: *const ProofCtx, proof: *ProofFixture, checks: ToggleChecks) !suite.RunStats {
    var stats = try runToggleSamples(ctx.io, ctx.options, ctx.case, ctx.item_count, &proof.fixture, proof.gaps, ctx.threads, checks, null, .flood);
    const size_config = proofSizeConfig(ctx, proof.config, proof.batch_chunks);
    try nav_size.checkNavBytes(connectivity_split_group.name, ctx.item_count, size_config, &proof.fixture.system);
    stats.output_count = proof.gaps.len;
    stats.candidate_pairs = proofStructureChunks(proof.config);
    return stats;
}

fn runRoomsProof(ctx: *const ProofCtx, config: SplitConfig) !suite.RunStats {
    var reference: ?RoomFloods = null;
    if (config.side != split_proof_reference_side) {
        var ref_proof = try openRooms(ctx, referenceConfig(config));
        defer ref_proof.deinit();
        reference = try measureRooms(ctx, &ref_proof);
    }
    var proof = try openRooms(ctx, config);
    defer proof.deinit();
    const floods = try measureRooms(ctx, &proof);
    try expectRooms(floods, reference);
    return timeProof(ctx, &proof, .{ .exact_flood = floods.both });
}

fn runWalledProof(ctx: *const ProofCtx, config: SplitConfig) !suite.RunStats {
    if (config.edge_chunks != 2) return error.ConnectivitySplitStructureTooLarge;
    var reference: ?WalledFloods = null;
    if (config.side != split_proof_reference_side) reference = try measureWalled(ctx, referenceConfig(config));
    const room_a = try roomAFlood(ctx, config);
    var proof = try openRoomA(ctx, config, true);
    defer proof.deinit();
    const sealed = try untimedSeal(ctx.io, &proof.fixture, proof.gaps, ctx.threads);
    const floods = WalledFloods{ .room_a = room_a, .walled = sealed.perf.conn_flood_nodes };
    try expectWalled(floods, reference);
    return timeProof(ctx, &proof, .{ .exact_flood = floods.walled });
}

fn runRingArcsProof(ctx: *const ProofCtx, config: SplitConfig) !suite.RunStats {
    var reference: ?usize = null;
    if (config.side != split_proof_reference_side) reference = try ringFlood(ctx, referenceConfig(config));
    var proof = try openRingArcs(ctx, config);
    defer proof.deinit();
    const sealed = try untimedSeal(ctx.io, &proof.fixture, proof.gaps, ctx.threads);
    try expectRingArc(sealed.perf.conn_flood_nodes, config.edge_chunks, reference);
    return timeProof(ctx, &proof, .{ .exact_flood = sealed.perf.conn_flood_nodes });
}

fn runHubProof(ctx: *const ProofCtx, config: SplitConfig) !suite.RunStats {
    const tunnels: usize = config.edge_chunks;
    const joined = joined: {
        var proof = try openHub(ctx, config, true);
        defer proof.deinit();
        const wide = try untimedHubSeal(ctx, &proof, false);
        const narrow = try untimedHubSeal(ctx, &proof, true);
        break :joined [2]NavUpdateStats{ wide, narrow };
    };
    try expectHub(joined[0], joined[1], tunnels);
    var proof = try openHub(ctx, config, false);
    defer proof.deinit();
    const wide = try untimedHubSeal(ctx, &proof, false);
    const narrow = try untimedHubSeal(ctx, &proof, true);
    try expectHub(wide, narrow, tunnels);
    return timeProof(ctx, &proof, .{ .exact_flood = wide.perf.conn_flood_nodes });
}

fn runBudgetProof(ctx: *const ProofCtx, config: SplitConfig) !suite.RunStats {
    var proof = try openRoomA(ctx, config, false);
    defer proof.deinit();
    const wide = try untimedBudgetSeal(ctx, &proof, default_flood_budget_cap);
    const narrow = try untimedBudgetSeal(ctx, &proof, 4);
    try expectBudget(wide, narrow);
    if (wide.perf.conn_flood_nodes == 0) return error.ConnectivitySplitFloodPastBound;
    return timeProof(ctx, &proof, .{ .exact_flood = wide.perf.conn_flood_nodes });
}

fn runPocketsProof(ctx: *const ProofCtx, config: SplitConfig) !suite.RunStats {
    var proof = try openPockets(ctx, config);
    defer proof.deinit();
    var inline_threads = try ThreadSystem.init(ctx.allocator, ctx.io, .{ .max_worker_threads = 0 });
    defer inline_threads.deinit();
    const inline_stats = try untimedSeal(ctx.io, &proof.fixture, proof.gaps, &inline_threads);
    const case_stats = try untimedSeal(ctx.io, &proof.fixture, proof.gaps, ctx.threads);
    if (inline_stats.perf.conn_flood_nodes == 0 or case_stats.perf.conn_flood_nodes != inline_stats.perf.conn_flood_nodes) return error.ConnectivitySplitPocketsNotEqual;
    if (inline_stats.perf.conn_flood_batch.item_count <= inline_stats.perf.conn_rounds) return error.ConnectivitySplitPocketsRounds;
    if (case_stats.perf.conn_flood_batch.item_count <= case_stats.perf.conn_rounds) return error.ConnectivitySplitPocketsRounds;
    try suite.checkStageDispatched(ctx.case, ctx.threads, ctx.case.stageItemsPerRangeForPartition(suite.chunk_partition_items, 1), case_stats.perf.conn_flood_batch);
    return timeProof(ctx, &proof, .{
        .exact_flood = inline_stats.perf.conn_flood_nodes,
        .more_searches_than_rounds = true,
        .flood_dispatch = true,
    });
}

fn runSplitProofCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize, config: SplitConfig) !suite.RunStats {
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const ctx = ProofCtx{
        .allocator = allocator,
        .io = io,
        .options = options,
        .case = case,
        .item_count = item_count,
        .threads = &threads,
        .participants = fixtures.participantCount(&threads),
    };
    return switch (config.variant) {
        .rooms => runRoomsProof(&ctx, config),
        .walled => runWalledProof(&ctx, config),
        .ring_arcs => runRingArcsProof(&ctx, config),
        .hub => runHubProof(&ctx, config),
        .budget => runBudgetProof(&ctx, config),
        .pockets => runPocketsProof(&ctx, config),
        else => unreachable,
    };
}

const OnewayVariant = enum(u8) {
    // Many chains; the first chain's last room toggles.
    locality,
    // One chain; its last room toggles.
    tail,
    // One chain; its first room toggles.
    head,
    // One chain; a far level-0 cell outside every room toggles.
    far_dig,
    // One chain cut once to its last `oneway_shrunk_live` rooms; its last room toggles.
    shrunk,
    // Every room links to a hub that links to the last room, which toggles.
    fan,
    // Many chains whose heads share one root through the open wall cells between them; the
    // toggle fills every such cell in one reaction (the systems part) and reopens them in
    // the next (one dense opening merges them).
    dense,
    // The locality chains plus a ballast chain on level 1, retired before every sample.
    ballast,
};

// One-way fixture: a `oneway_side`² world of `oneway_levels` levels, each level a 2-cell
// lattice of blocking cells around one-cell rooms (its even cells). The toggled chain's end
// group, its `oneway_site_rooms` rooms at the toggled end, takes the first room row of
// level 0's chunk `oneway_site_chunk`; no other room of that chunk or its orthogonal
// neighbours holds a link endpoint, so every config's toggle patches the same content. Every
// other chain room takes the next free room level by level in snaking rows, so consecutive
// rooms mostly lie 2 cells apart.
const oneway_side: u16 = 256;
const oneway_levels: u16 = 2;
const oneway_rooms_per_row: usize = oneway_side / 2;
const oneway_site_rooms: usize = 8;
const oneway_site_chunk: ChunkCoord = .{ .x = 1, .y = 1 };
// Rooms the shrunk variant's cut leaves on its chain.
const oneway_shrunk_live: usize = 64;
// Rooms per chain of the dense variant: its systems' merged terminals stay off a power of
// two, so the merged block keeps slack for the pieces a fill splits off.
const oneway_dense_terminals: usize = 96;
// The dense variant's heads: level-0 rooms side by side on the last room row.
const oneway_dense_row: u16 = oneway_side - 2;

comptime {
    // The end group fits the first room row of one chunk.
    std.debug.assert(2 * oneway_site_rooms <= default_chunk_size_tiles);
}

const OnewayRoom = struct {
    level: u16,
    cell: CellCoord,
};

// The chunk keys a marks batch changing `rooms` patches at most: each distinct chunk they
// sit in with its four neighbours.
fn roomBatchKeys(allocator: std.mem.Allocator, rooms: []const OnewayRoom) !usize {
    const chunks = try allocator.alloc(u64, rooms.len);
    defer allocator.free(chunks);
    const chunk_edge = default_chunk_size_tiles;
    for (rooms, chunks) |room, *chunk| {
        chunk.* = (@as(u64, room.level) << 32) | (@as(u64, room.cell.y / chunk_edge) << 16) | (room.cell.x / chunk_edge);
    }
    std.mem.sort(u64, chunks, {}, std.sort.asc(u64));
    var distinct: usize = 0;
    for (chunks, 0..) |chunk, index| {
        if (index == 0 or chunk != chunks[index - 1]) distinct += 1;
    }
    return distinct * toggle_batch_keys;
}

// Whether a level-0 chunk is the site chunk or one of its orthogonal neighbours.
fn inOnewaySite(level: u16, cell: CellCoord) bool {
    if (level != 0) return false;
    const chunk_x = cell.x / default_chunk_size_tiles;
    const chunk_y = cell.y / default_chunk_size_tiles;
    const dx = @abs(@as(i32, chunk_x) - oneway_site_chunk.x);
    const dy = @abs(@as(i32, chunk_y) - oneway_site_chunk.y);
    return dx + dy <= 1;
}

// Chain `index`'s head in the dense variant.
fn denseHead(index: usize) OnewayRoom {
    std.debug.assert(index < oneway_rooms_per_row);
    // In range: one room row of level 0.
    return .{ .level = 0, .cell = .{ .x = @intCast(2 * index), .y = oneway_dense_row } };
}

// The wall cells joining the dense variant's `systems` heads: between each head and the next.
fn denseWalls(allocator: std.mem.Allocator, systems: usize) ![]CellCoord {
    const walls = try allocator.alloc(CellCoord, systems - 1);
    for (walls, 0..) |*wall, index| wall.* = .{ .x = denseHead(index).cell.x + 1, .y = oneway_dense_row };
    return walls;
}

fn isDenseHead(room: OnewayRoom, systems: usize) bool {
    return room.level == 0 and room.cell.y == oneway_dense_row and room.cell.x < 2 * systems;
}

fn onewaySiteRoom(index: usize) OnewayRoom {
    std.debug.assert(index < oneway_site_rooms);
    // In range: the site chunk's first room row lies inside level 0.
    return .{ .level = 0, .cell = .{
        .x = @intCast(@as(usize, oneway_site_chunk.x) * default_chunk_size_tiles + 2 * index),
        .y = oneway_site_chunk.y * default_chunk_size_tiles,
    } };
}

// The rooms outside the site in fill order: level by level, snaking rows.
fn onewayFreeRooms(allocator: std.mem.Allocator) ![]OnewayRoom {
    var rooms: std.ArrayList(OnewayRoom) = .empty;
    errdefer rooms.deinit(allocator);
    for (0..oneway_levels) |level_index| {
        for (0..oneway_rooms_per_row) |row| {
            for (0..oneway_rooms_per_row) |step| {
                const column = if (row % 2 == 0) step else oneway_rooms_per_row - 1 - step;
                // In range: rows and columns of rooms inside the `oneway_side`² levels.
                const room = OnewayRoom{ .level = @intCast(level_index), .cell = .{ .x = @intCast(2 * column), .y = @intCast(2 * row) } };
                if (inOnewaySite(room.level, room.cell)) continue;
                try rooms.append(allocator, room);
            }
        }
    }
    return rooms.toOwnedSlice(allocator);
}

const OnewayConfig = struct {
    variant: OnewayVariant,
    terminals: usize,
    systems: usize,

    fn decode(item_count: usize) !OnewayConfig {
        const code = try OnewayCode.decode(item_count);
        const variant = code.variant;
        const terminals = code.terminals_per_system;
        const systems = code.systems;
        if (terminals < oneway_site_rooms or systems == 0) return error.ConnectivityOnewayChainTooShort;
        if (variant != .locality and variant != .dense and variant != .ballast and systems != 1) return error.ConnectivityOnewayOneChainOnly;
        if (variant == .dense and (systems < 2 or systems > oneway_rooms_per_row)) return error.ConnectivityOnewayDenseSystems;
        // The cut must leave a block at most a quarter full.
        if (variant == .shrunk and terminals <= 4 * oneway_shrunk_live) return error.ConnectivityOnewayShrunkTooSmall;
        return .{ .variant = variant, .terminals = terminals, .systems = systems };
    }

    fn rooms(self: OnewayConfig) usize {
        return self.terminals * self.systems;
    }

    fn links(self: OnewayConfig) usize {
        return (self.terminals - 1) * self.systems;
    }

    // The ballast chain's rooms (none outside the ballast variant): the smallest power of two
    // whose block holds over twice the chains' words, so its block alone outweighs every live
    // one and any cost it moved into the timed toggle would show.
    fn ballastRooms(self: OnewayConfig) !usize {
        if (self.variant != .ballast) return 0;
        const chain_words = self.systems * try onewayBlockWords(self.terminals);
        var ballast: usize = oneway_site_rooms;
        while (try onewayBlockWords(ballast) <= 2 * chain_words) ballast *= 2;
        return ballast;
    }

    // The one-way links of every chain and the ballast.
    fn allLinks(self: OnewayConfig) !usize {
        const ballast = try self.ballastRooms();
        return self.links() + if (ballast == 0) 0 else ballast - 1;
    }

    // Chain 0's room `index`: its end group in the site (the first rooms for the head
    // variant, else the last), its other rooms the next free rooms.
    fn firstChainSiteIndex(self: OnewayConfig, index: usize) ?usize {
        const site_start = if (self.variant == .head) 0 else self.terminals - oneway_site_rooms;
        if (index < site_start or index >= site_start + oneway_site_rooms) return null;
        return index - site_start;
    }

    // The toggled level-0 cell: chain 0's first room (head), its last room (locality,
    // tail), a far room in a corner chunk no chain room reaches (far dig), or the dense
    // variant's first wall (it toggles every wall).
    fn toggleCell(self: OnewayConfig) CellCoord {
        return switch (self.variant) {
            .locality, .tail, .shrunk, .fan, .ballast => onewaySiteRoom(oneway_site_rooms - 1).cell,
            .head => onewaySiteRoom(0).cell,
            .far_dig => pocketDigCell(oneway_side),
            .dense => .{ .x = denseHead(0).cell.x + 1, .y = oneway_dense_row },
        };
    }
};

// The words of the one-way block a system of `terminals` terminals holds once built or
// regrown.
fn onewayBlockWords(terminals: usize) !usize {
    return connectivity_closure.blockWords(try connectivity_closure.boundCap(terminals));
}

// The ballast variant's chain: `config.ballastRooms()` rooms on level 1 after every chain
// room, in fill order.
fn onewayBallastRooms(allocator: std.mem.Allocator, config: OnewayConfig) ![]OnewayRoom {
    const free_rooms = try onewayFreeRooms(allocator);
    defer allocator.free(free_rooms);
    // The chains took the free rooms before `start`; chain 0's end group sits in the site.
    var start = config.rooms() - oneway_site_rooms;
    while (start < free_rooms.len and free_rooms[start].level == 0) start += 1;
    const count = try config.ballastRooms();
    if (start + count > free_rooms.len) return error.ConnectivityOnewayRoomsTooFew;
    return allocator.dupe(OnewayRoom, free_rooms[start..][0..count]);
}

// The ballast chain on `ballast_level`, retired (every room closed) before each timed toggle:
// its reopen builds and lands its block, its close frees it, so the timed toggle runs right
// after a block that outweighs every live one came and went.
const OnewayBallast = struct {
    const ballast_level: u16 = 1;

    cells: []const CellCoord,
    // What `checkNavBytes` charges the nav, checked after every retire.
    size_config: nav_size.NavSizeConfig,
    item_count: usize,
    // The ballast's block words, which its reopen lands and its close frees.
    block_words: usize,
    // The last retire's reopen and close reactions.
    reopen: Reaction = .{ .elapsed_ns = 0, .stats = .{} },
    close: Reaction = .{ .elapsed_ns = 0, .stats = .{} },
    retires: usize = 0,
    // The timed block reactions' split, summed over `samples`: the reaction, its main-thread
    // reserve section, its closure stages (candidates, resolve, mask, plan, rows), and its
    // landing stage.
    samples: usize = 0,
    close_ns: u128 = 0,
    reserve_ns: u128 = 0,
    closure_stages_ns: u128 = 0,
    land_ns: u128 = 0,

    // Reopens the ballast's rooms and closes them, one untimed reaction each. Fails when the
    // reopen does not land exactly the ballast's one block or the close does not free exactly
    // it, when the block holds no more than twice the live words it left, or when the nav
    // holds more bytes than charged.
    fn retire(self: *OnewayBallast, io: std.Io, fixture: *ReactFixture, thread_system: *ThreadSystem) !void {
        self.reopen = try untimedReaction(io, fixture, self.cells, fixture.open.walkable, thread_system);
        const reopen = self.reopen.stats;
        if (reopen.perf.closure_tail_used != self.block_words or reopen.perf.closure_landed_words != self.block_words or reopen.perf.closure_block_allocs != 1) return error.ConnectivityOnewayBallastLanding;
        try self.closeAll(io, fixture, thread_system);
        self.retires += 1;
        const retired_words = reopen.perf.closure_live_words -| self.close.stats.perf.closure_live_words;
        if (self.close.stats.perf.closure_block_frees != 1 or retired_words != self.block_words) return error.ConnectivityOnewayBallastFree;
        if (retired_words <= 2 * self.close.stats.perf.closure_live_words) return error.ConnectivityOnewayBallastTooSmall;
        try nav_size.checkNavBytes(connectivity_oneway_group.name, self.item_count, self.size_config, &fixture.system);
    }

    // Closes every ballast room in one untimed reaction.
    fn closeAll(self: *OnewayBallast, io: std.Io, fixture: *ReactFixture, thread_system: *ThreadSystem) !void {
        self.close = try untimedReaction(io, fixture, self.cells, fixture.open.blocking, thread_system);
    }

    // Sets the ballast's rooms to `tile` in one reaction, leaving every tuner as it was, so
    // it never trains the timed reactions' stages.
    fn untimedReaction(io: std.Io, fixture: *ReactFixture, cells: []const CellCoord, tile: TileId, thread_system: *ThreadSystem) !Reaction {
        const tuners = fixture.system.tuners;
        defer fixture.system.tuners = tuners;
        return fixture.changeLevelAndReact(io, ballast_level, cells, tile, thread_system);
    }

    // Adds a timed sample's block reaction, which ran right after the last retire.
    fn addSample(self: *OnewayBallast, sample: ToggleSample) void {
        const change = sample.change.stats;
        self.samples += 1;
        self.close_ns += sample.change.elapsed_ns;
        self.reserve_ns += change.perf.main.reserve_ns;
        inline for (.{ change.perf.conn_closure_candidates_batch, change.perf.conn_closure_resolve_batch, change.perf.conn_closure_mask_batch, change.perf.conn_closure_plan_batch, change.perf.conn_closure_rows_batch }) |batch| {
            self.closure_stages_ns += batch.batch_duration_ns;
        }
        self.land_ns += change.perf.conn_closure_land_batch.batch_duration_ns;
    }

    // The last retire: the reopen's landing (its shape, time, and words) and its tail bound
    // and use, and the close's main-thread closure time (it holds the free) and the words it
    // freed; then the timed block reactions' split (the rest is everything outside the
    // reserve, closure, and landing). Printed under --details.
    fn write(self: OnewayBallast, details: *suite.DetailLines) void {
        if (self.retires == 0) return;
        const reopen = self.reopen.stats;
        const close = self.close.stats;
        var land_shape = suite.StageShapes(1){};
        land_shape.add(.{reopen.perf.conn_closure_land_batch});
        var land_buffer: [48]u8 = undefined;
        const land = reopen.perf.conn_closure_land_batch;
        details.print("ballast rooms={} block_words={} retires={} reopen={}us reopen_land={s} reopen_land_ns={} landed_words={} tail_bound={} tail_used={} tail_ratio={d:.2} close={}us close_closure_main={}ns freed_words={} left_live_words={}\n", .{
            self.cells.len,
            self.block_words,
            self.retires,
            self.reopen.elapsed_ns / std.time.ns_per_us,
            land_shape.label(0, &land_buffer),
            land.batch_duration_ns,
            reopen.perf.closure_landed_words,
            reopen.perf.closure_tail_bound,
            reopen.perf.closure_tail_used,
            if (reopen.perf.closure_tail_used == 0) 0.0 else @as(f64, @floatFromInt(reopen.perf.closure_tail_bound)) / @as(f64, @floatFromInt(reopen.perf.closure_tail_used)),
            self.close.elapsed_ns / std.time.ns_per_us,
            close.perf.main.closure_ns,
            reopen.perf.closure_live_words -| close.perf.closure_live_words,
            close.perf.closure_live_words,
        });
        if (self.samples == 0) return;
        const samples: u128 = self.samples;
        const parts = self.reserve_ns + self.closure_stages_ns + self.land_ns;
        details.print("timed block split total={}ns reserve={}ns closure_stages={}ns land={}ns rest={}ns\n", .{
            @as(u64, @intCast(self.close_ns / samples)),
            @as(u64, @intCast(self.reserve_ns / samples)),
            @as(u64, @intCast(self.closure_stages_ns / samples)),
            @as(u64, @intCast(self.land_ns / samples)),
            @as(u64, @intCast((self.close_ns -| parts) / samples)),
        });
    }
};

// Every cell of one level with an odd coordinate: the lattice walls.
fn onewayWallCells(allocator: std.mem.Allocator) ![]CellCoord {
    var walls: std.ArrayList(CellCoord) = .empty;
    errdefer walls.deinit(allocator);
    for (0..oneway_side) |y| {
        for (0..oneway_side) |x| {
            if (x % 2 == 0 and y % 2 == 0) continue;
            // Inside the `oneway_side`² level.
            try walls.append(allocator, .{ .x = @intCast(x), .y = @intCast(y) });
        }
    }
    return walls.toOwnedSlice(allocator);
}

// Fails when `room` lies in the far toggle's chunk or an orthogonal neighbour of it.
fn checkOnewayFarRoom(room: OnewayRoom) !void {
    if (room.level != 0) return;
    const far = pocketDigCell(oneway_side);
    const dx = @abs(@as(i32, room.cell.x / default_chunk_size_tiles) - far.x / default_chunk_size_tiles);
    const dy = @abs(@as(i32, room.cell.y / default_chunk_size_tiles) - far.y / default_chunk_size_tiles);
    if (dx + dy <= 1) return error.ConnectivityOnewayChainReachesFarRoom;
}

// Every system's rooms in order, `config.terminals` each: chain 0's end group in the site,
// every other room the next free room.
fn onewayRooms(allocator: std.mem.Allocator, config: OnewayConfig) ![]OnewayRoom {
    const free_rooms = try onewayFreeRooms(allocator);
    defer allocator.free(free_rooms);
    if (config.rooms() - oneway_site_rooms > free_rooms.len) return error.ConnectivityOnewayRoomsTooFew;
    const rooms = try allocator.alloc(OnewayRoom, config.rooms());
    errdefer allocator.free(rooms);
    var next_free: usize = 0;
    for (0..config.systems) |system_index| {
        // Chain 0's index at the toggled end: its first link's source for head, else its
        // last link's target.
        const toggle_index = if (config.variant == .head) 0 else config.terminals - 1;
        for (0..config.terminals) |index| {
            const site_index = if (system_index == 0 and config.variant != .dense) config.firstChainSiteIndex(index) else null;
            const room = if (config.variant == .dense and index == 0) denseHead(system_index) else if (site_index) |site| onewaySiteRoom(site) else free: {
                while (config.variant == .dense and isDenseHead(free_rooms[next_free], config.systems)) next_free += 1;
                defer next_free += 1;
                break :free free_rooms[next_free];
            };
            if (config.variant == .far_dig) try checkOnewayFarRoom(room);
            if (system_index == 0 and index == toggle_index and config.variant != .far_dig and config.variant != .dense) {
                const toggle_cell = config.toggleCell();
                if (room.level != 0 or room.cell.x != toggle_cell.x or room.cell.y != toggle_cell.y) return error.ConnectivityOnewayToggleNotChainEnd;
            }
            rooms[system_index * config.terminals + index] = room;
        }
    }
    return rooms;
}

// One one-way teleport from room `from` to room `to`.
fn addOnewayLink(world: *WorldSystem, from: OnewayRoom, to: OnewayRoom) !void {
    try world.addLevelLink(.{
        .kind = .teleport,
        .level_a = from.level,
        .cell_a = from.cell,
        .level_b = to.level,
        .cell_b = to.cell,
        .traversal_cost = 1,
        .bidirectional = false,
    });
}

fn initOnewayFixture(allocator: std.mem.Allocator, io: std.Io, config: OnewayConfig, rooms: []const OnewayRoom, ballast: []const OnewayRoom, capacity: PathfindingCapacity, thread_system: *ThreadSystem) !ReactFixture {
    var open = try buildOpenWorld(allocator, io, oneway_side, oneway_levels);
    errdefer open.world.deinit();
    std.debug.assert(open.world.chunk_size_tiles == default_chunk_size_tiles);
    {
        const walls = try onewayWallCells(allocator);
        defer allocator.free(walls);
        for (0..oneway_levels) |level_index| try writeLevelCells(&open, @intCast(level_index), walls, open.blocking);
    }
    if (config.variant == .dense) {
        // The heads' joining walls start open: one root, one system.
        const walls = try denseWalls(allocator, config.systems);
        defer allocator.free(walls);
        try writeLevelCells(&open, 0, walls, open.walkable);
    }
    std.debug.assert(rooms.len == config.rooms());
    for (0..config.systems) |system_index| {
        const system_rooms = rooms[system_index * config.terminals ..][0..config.terminals];
        // A chain joins each room to the next; a fan joins each room to its hub, the next to
        // last room, and the hub to the last room.
        const hub = config.terminals - 2;
        for (system_rooms[1..], 0..) |room, previous| {
            const from = system_rooms[previous];
            const to = if (config.variant == .fan and previous < hub) system_rooms[hub] else room;
            try addOnewayLink(&open.world, from, to);
        }
    }
    std.debug.assert(ballast.len == try config.ballastRooms());
    if (ballast.len != 0) {
        for (ballast[1..], 0..) |room, previous| try addOnewayLink(&open.world, ballast[previous], room);
    }
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const requests = try allocator.alloc(PathRequest, 0);
    errdefer allocator.free(requests);
    return assembleReactFixture(allocator, &open, &data, requests, capacity, thread_system);
}

// Closes `rooms` (level-0 rooms of one chain) in one untimed nav reaction.
fn cutOnewayChain(allocator: std.mem.Allocator, io: std.Io, fixture: *ReactFixture, rooms: []const OnewayRoom, thread_system: *ThreadSystem) !void {
    const cells = try allocator.alloc(CellCoord, rooms.len);
    defer allocator.free(cells);
    for (rooms, cells) |room, *cell| {
        if (room.level != 0) return error.ConnectivityOnewayCutOffFloor;
        cell.* = room.cell;
    }
    try fixture.changed.ensureTotalCapacity(allocator, cells.len);
    const cut = try fixture.changeAndReact(io, cells, fixture.open.blocking, thread_system);
    if (cut.stats.perf.closure_shrinks != 1) return error.ConnectivityOnewayCutNoShrink;
    try checkOnewayReserve(cut.stats);
    try checkOnewayWithinBounds(fixture, cut.stats, false);
}

fn runConnectivityOnewayCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    // Its pass shape reads the closure's diagnostic counters, kept only with the perf log.
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;
    const config = try OnewayConfig.decode(item_count);
    var threads = try fixtures.initRequiredCaseThreads(allocator, io, case);
    defer threads.deinit();
    const thread_ptr = &threads;
    const participant_count = fixtures.participantCount(thread_ptr);
    const rooms = try onewayRooms(allocator, config);
    defer allocator.free(rooms);
    const ballast_rooms = if (config.variant == .ballast) try onewayBallastRooms(allocator, config) else try allocator.alloc(OnewayRoom, 0);
    defer allocator.free(ballast_rooms);
    // The toggle, the dense variant's walls, the shrunk variant's cut, or the ballast's retire,
    // whichever writes the most cells and patches the most chunks.
    const cut_rooms = if (config.variant == .shrunk) config.terminals - oneway_shrunk_live else 0;
    const batch = nav_size.NavBatch{
        .mark_chunks = @max(1, @max(config.systems, cut_rooms, ballast_rooms.len)),
        .links = 0,
        .keys = @max(toggle_batch_keys, if (config.variant == .dense)
            config.systems * toggle_batch_keys
        else if (config.variant == .shrunk)
            try roomBatchKeys(allocator, rooms[0..cut_rooms])
        else if (config.variant == .ballast)
            try roomBatchKeys(allocator, ballast_rooms)
        else
            toggle_batch_keys),
    };
    var size_config = toggleSizeConfig(oneway_side, oneway_levels, try config.allLinks(), participant_count, batch);
    // A system is one chain or fan of rooms; the dense variant's opening merges every one.
    size_config.oneway_system_terminals = if (config.variant == .dense) config.rooms() else @max(config.terminals, ballast_rooms.len);
    try nav_size.checkNavSize(connectivity_oneway_group.name, item_count, case, size_config);

    var fixture = try initOnewayFixture(allocator, io, config, rooms, ballast_rooms, nav_size.navSizeCapacity(size_config), thread_ptr);
    defer fixture.deinit(allocator);
    try nav_size.checkNavBytes(connectivity_oneway_group.name, item_count, size_config, &fixture.system);
    // One toggled cell, or the dense variant's walls.
    const dense_walls: []CellCoord = if (config.variant == .dense) try denseWalls(allocator, config.systems) else &.{};
    defer allocator.free(dense_walls);
    const toggle_cell = config.toggleCell();
    const cells = if (config.variant == .dense) dense_walls else &[_]CellCoord{toggle_cell};
    const ballast_cells = try allocator.alloc(CellCoord, ballast_rooms.len);
    defer allocator.free(ballast_cells);
    for (ballast_rooms, ballast_cells) |room, *cell| {
        std.debug.assert(room.level == OnewayBallast.ballast_level);
        cell.* = room.cell;
    }
    try fixture.changed.ensureTotalCapacity(allocator, @max(cells.len, ballast_cells.len));
    if (config.variant == .shrunk) try cutOnewayChain(allocator, io, &fixture, rooms[0 .. config.terminals - oneway_shrunk_live], thread_ptr);
    // After the cut, so neither toggle tuner set starts trained on the cut's reaction.
    fixtures.setNavTuners(&fixture.system, case);
    // The ballast starts retired: every sample reopens it first.
    var ballast = OnewayBallast{ .cells = ballast_cells, .size_config = size_config, .item_count = item_count, .block_words = if (ballast_cells.len == 0) 0 else try onewayBlockWords(ballast_cells.len) };
    if (config.variant == .ballast) try ballast.closeAll(io, &fixture, thread_ptr);

    // The dense variant's fill and reopen resize blocks and reserve the merged block the
    // opening can create: its ratio is what the variant measures.
    const checks: ToggleChecks = switch (config.variant) {
        .dense => .{ .fixed_blocks = false, .reserve_ratio = false },
        .ballast => .{ .isolated = true },
        .far_dig => .{ .untouched = true },
        else => .{},
    };
    var stats = try runToggleSamples(io, options, case, item_count, &fixture, cells, thread_ptr, checks, if (config.variant == .ballast) &ballast else null, .rows);
    ballast.write(&stats.details);
    try nav_size.checkNavBytes(connectivity_oneway_group.name, item_count, size_config, &fixture.system);
    stats.output_count = config.links();
    stats.candidate_pairs = config.rooms();
    return stats;
}
