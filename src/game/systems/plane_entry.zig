// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Plane traversal's per-agent cell-entry gather. One pass over the AI rows finds each
//! agent that entered a new cell this step and either stands where it could change
//! plane (a ramp-link cell, or a hole with a level below) or lacks `world_level`, and
//! classifies that cell on the worker: the ramp's other level or the fall's target, the
//! landing floor layer, and whether the landing needs a carve. The player is never an
//! entry, even when it is also an AI agent: the dig controller classifies it on its own
//! path. The dig controller's reserve and commit then visit only those entries, at O(1)
//! each. Each range writes at most one entry per row into its own window of one
//! item-capacity buffer; the main thread compacts the windows in range order, which is
//! AI row order.

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../../core/logging.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const StageThreads = @import("../../app/thread_system.zig").StageThreads;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const compactSliceWindows = @import("../../app/thread_system.zig").compactSliceWindows;
const inlineBatch = @import("../../app/thread_system.zig").inlineBatch;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const SimulationTier = @import("../simulation_scope.zig").SimulationTier;
const WorldSystem = @import("../world/system.zig").WorldSystem;
const CellCoord = @import("../world/system.zig").CellCoord;
const TileId = @import("../world/system.zig").TileId;

/// Range alignment of the gather: every range's window starts on a cache line.
pub const plane_entry_range_alignment_items: usize = movement_range_alignment_items;

/// What entering a cell does to an agent's plane, judged against the step's pre-commit
/// world: nothing (`attach`: only a missing `world_level` is attached), follow a ramp
/// link, or fall one level through a hole.
pub const PlaneAction = enum(u8) { attach, ramp, fall };

/// `PlaneTarget.landing_layer` of a fall whose target level has no floor band.
pub const no_landing_layer: u32 = std.math.maxInt(u32);

/// One entered cell's plane traversal against the pre-commit world (`planeTarget`).
pub const PlaneTarget = struct {
    action: PlaneAction,
    /// The ramp's other level, the fall's level below, or the entry's own level.
    target_level: u16,
    /// A fall's landing floor layer, or `no_landing_layer`.
    landing_layer: u32 = no_landing_layer,
    /// A fall whose landing cell is not yet the walkable tunnel tile.
    carve: bool = false,
};

/// What entering `cell` on `level` does: follow the oldest ramp link there, else fall one
/// level through a hole when a level lies below, carving the landing when it is not
/// already `tunnel_tile`, else nothing. Reads only; O(link endpoints in the cell's chunk).
pub fn planeTarget(world: *const WorldSystem, level: u16, cell: CellCoord, tunnel_tile: TileId) PlaneTarget {
    if (world.rampLinkOtherLevel(level, cell)) |other| return .{ .action = .ramp, .target_level = other };
    const below = @as(usize, level) + 1;
    if (below >= world.levelCount() or !world.denseFloorIsEmpty(level, cell.x, cell.y)) {
        return .{ .action = .attach, .target_level = level };
    }
    // Below the level count, which fits u16.
    const below_level: u16 = @intCast(below);
    const layer = world.denseFloorLayerForLevel(below_level) orelse return .{ .action = .fall, .target_level = below_level };
    return .{
        .action = .fall,
        .target_level = below_level,
        // Layer indices fit u32 (`addDenseLayer`).
        .landing_layer = @intCast(layer),
        .carve = world.denseTile(layer, cell.x, cell.y) != tunnel_tile,
    };
}

/// One AI agent that entered `cell` this step on `level` (its `world_level`, or its
/// scope level when it has none) where plane traversal may act, with that cell's
/// traversal against the pre-commit world.
pub const PlaneEntry = struct {
    entity: EntityId,
    target: PlaneTarget,
    cell: CellCoord,
    level: u16,
    needs_world_level: bool,
};

comptime {
    std.debug.assert(@sizeOf(PlaneEntry) == 24);
    std.debug.assert((plane_entry_range_alignment_items * @sizeOf(PlaneEntry)) % thread_shared_record_alignment == 0);
    std.debug.assert(plane_entry_range_alignment_items % simd.lane_count == 0);
}

/// The gather's stage-threads value: null `items_per_range` with `adaptive` trains the
/// system's tuner; an explicit `items_per_range` pins the range size.
pub const PlaneEntryConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

// One range's entry count, written once by its job into its padded slot.
const PlaneEntryTally = struct { kept: usize = 0 };

const EntryList = std.array_list.Aligned(PlaneEntry, .fromByteUnits(thread_shared_record_alignment));
const TallyList = SlotList(PlaneEntryTally);

pub const PlaneEntrySystem = struct {
    allocator: std.mem.Allocator,
    /// Window buffer, compacted in place to this step's entries.
    entries: EntryList = .empty,
    tallies: TallyList = .empty,
    /// Rows the windows and tallies are reserved for; the grow gate compares against it.
    reserved_items: usize = 0,
    config: PlaneEntryConfig = .{},
    tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    last_batch: BatchStats = .{},
    /// Telemetry: gathers whose AI rows exceeded the reservation and grew the windows
    /// on the main thread before dispatch. Nonzero means the population seam's reserve
    /// is short of the live AI rows; the first warns once.
    windows_grown: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) PlaneEntrySystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PlaneEntrySystem) void {
        self.tallies.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// Sizes the windows to `capacity` AI rows and the tallies to every partition of
    /// them, so a gather within it allocates nothing. Grow-only; the pipeline's
    /// population seam re-runs it.
    pub fn reserve(self: *PlaneEntrySystem, capacity: usize) error{OutOfMemory}!void {
        try self.entries.ensureTotalCapacity(self.allocator, capacity);
        try self.tallies.ensureTotalCapacityPrecise(self.allocator, maxRangeCount(capacity, plane_entry_range_alignment_items));
        self.reserved_items = @max(self.reserved_items, capacity);
        std.debug.assert(self.entries.capacity >= self.reserved_items);
    }

    /// This step's entries in AI row order, read from `data` and `world` without
    /// writing either, each classified by `planeTarget` with `tunnel_tile` as the
    /// landing floor; `player` is never an entry. Serial when `thread_system` is null;
    /// otherwise dispatched per `config` with the system's tuner. Valid until the next
    /// `gather`. An AI row count past the reservation grows the windows first
    /// (counted); an OOM there returns before anything is written.
    pub fn gather(
        self: *PlaneEntrySystem,
        data: *const DataSystem,
        world: *const WorldSystem,
        player: EntityId,
        tunnel_tile: TileId,
        thread_system: ?*ThreadSystem,
    ) error{OutOfMemory}![]const PlaneEntry {
        self.last_batch = .{};
        self.entries.clearRetainingCapacity();
        const ai = data.aiAgentSliceConst();
        const item_count = ai.entities.len;
        if (item_count == 0) return self.entries.items;
        if (item_count > self.reserved_items) try self.growWindows(item_count);
        std.debug.assert(self.entries.capacity >= item_count);

        const movement = data.movementBodySliceConst();
        const visuals = data.primitiveVisualSliceConst();
        const scope = data.scopeColumnsSliceConst();
        var job = PlaneEntryJob{
            .input = .{
                .data = data,
                .world = world,
                .player = player,
                .entities = ai.entities,
                .previous_x = movement.previous_x,
                .previous_y = movement.previous_y,
                .position_x = movement.position_x,
                .position_y = movement.position_y,
                .size_x = visuals.size_x,
                .size_y = visuals.size_y,
                .tier = scope.tier,
                .scope_level = scope.level,
                .grid = CellGrid.of(world),
                .tunnel_tile = tunnel_tile,
            },
            .entries = undefined,
            .tallies = undefined,
            .items_per_range = item_count,
        };

        const ts = thread_system orelse {
            self.entries.items.len = item_count;
            self.entries.items.len = gatherRange(&job.input, 0, item_count, self.entries.items);
            self.last_batch = inlineBatch(item_count, plane_entry_range_alignment_items);
            return self.entries.items;
        };
        const stage = (StageThreads(PlaneEntryConfig){ .thread_system = ts, .config = self.config }).stage(&self.tuner);
        const selection = stage.select(item_count, plane_entry_range_alignment_items);
        std.debug.assert(self.tallies.capacity >= selection.range_count);
        self.entries.items.len = item_count;
        self.tallies.items.len = selection.range_count;
        @memset(self.tallies.items, .{});
        job.entries = self.entries.items;
        job.tallies = self.tallies.items;
        job.items_per_range = selection.items_per_range;
        self.last_batch = stage.run(selection, item_count, plane_entry_range_alignment_items, &job, planeEntryJob);
        self.entries.items.len = compactSliceWindows(PlaneEntry, PlaneEntryTally, self.entries.items, self.tallies.items, selection.items_per_range);
        return self.entries.items;
    }

    // Main thread, before any dispatch: grows the windows and tallies 1.5x past
    // `needed` rows and counts the shortfall. The first warns once (release-visible,
    // compiled out of tests).
    fn growWindows(self: *PlaneEntrySystem, needed: usize) error{OutOfMemory}!void {
        @branchHint(.cold);
        const target = needed + needed / 2;
        try self.entries.ensureTotalCapacity(self.allocator, target);
        try self.tallies.ensureTotalCapacityPrecise(self.allocator, maxRangeCount(target, plane_entry_range_alignment_items));
        self.reserved_items = target;
        std.debug.assert(self.entries.capacity >= self.reserved_items);
        std.debug.assert(self.tallies.capacity >= maxRangeCount(self.reserved_items, plane_entry_range_alignment_items));
        self.windows_grown += 1;
        if (comptime logging.enabled(.warn)) {
            if (self.windows_grown == 1) logging.game.warn(
                "plane entry gather: {d} AI rows exceeded the reserved windows; grew to {d} (reservation short of the live population)",
                .{ needed, target },
            );
        }
    }
};

// The world's cell grid as the lane cell test reads it.
const CellGrid = struct {
    tile_size: f32,
    width: i32,
    height: i32,

    fn of(world: *const WorldSystem) CellGrid {
        return .{ .tile_size = world.tile_size, .width = world.width, .height = world.height };
    }
};

// The columns one gather reads, captured once per gather.
const GatherInput = struct {
    data: *const DataSystem,
    world: *const WorldSystem,
    player: EntityId,
    entities: []const EntityId,
    previous_x: []const f32,
    previous_y: []const f32,
    position_x: []const f32,
    position_y: []const f32,
    size_x: []const f32,
    size_y: []const f32,
    tier: []const SimulationTier,
    scope_level: []const u16,
    grid: CellGrid,
    tunnel_tile: TileId,
};

const PlaneEntryJob = struct {
    input: GatherInput,
    entries: []PlaneEntry,
    tallies: []PaddedSlot(PlaneEntryTally),
    items_per_range: usize,
};

fn planeEntryJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PlaneEntryJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= job.entries.len);
    std.debug.assert(range.end <= job.input.entities.len);
    job.tallies[range.index].value.kept = gatherRange(&job.input, range.start, range.end, job.entries[range.start..range.end]);
}

// Lane cells of one block: each lane's current body-center cell, and whether its
// previous and current centers both lie in the world in different cells.
const LaneCellEntries = struct {
    entered: simd.Mask4,
    cell_x: simd.Int4,
    cell_y: simd.Int4,
};

const LaneCells = struct {
    x: simd.Int4,
    y: simd.Int4,
    inside: simd.Mask4,
};

// `WorldSystem.cellContaining` per lane: a negative center is outside, otherwise the
// floored tile index must be inside the grid.
fn laneCells(center_x: simd.Float4, center_y: simd.Float4, grid: CellGrid) LaneCells {
    const zero = simd.splatFloat4(0);
    const tile = simd.splatFloat4(grid.tile_size);
    const x = simd.floorToI4(simd.divFloat4(center_x, tile));
    const y = simd.floorToI4(simd.divFloat4(center_y, tile));
    const non_negative = (center_x >= zero) & (center_y >= zero);
    const below_extent = simd.lessThanInt4(x, simd.splatInt4(grid.width)) & simd.lessThanInt4(y, simd.splatInt4(grid.height));
    return .{ .x = x, .y = y, .inside = non_negative & below_extent };
}

// SIMD twin of `cellEntryScalar`, same operation order.
fn laneCellEntries(
    previous_x: simd.Float4,
    previous_y: simd.Float4,
    position_x: simd.Float4,
    position_y: simd.Float4,
    size_x: simd.Float4,
    size_y: simd.Float4,
    grid: CellGrid,
) LaneCellEntries {
    const half = simd.splatFloat4(0.5);
    const half_x = simd.mulFloat4(size_x, half);
    const half_y = simd.mulFloat4(size_y, half);
    const previous = laneCells(simd.addFloat4(previous_x, half_x), simd.addFloat4(previous_y, half_y), grid);
    const current = laneCells(simd.addFloat4(position_x, half_x), simd.addFloat4(position_y, half_y), grid);
    const moved = (current.x != previous.x) | (current.y != previous.y);
    return .{ .entered = previous.inside & current.inside & moved, .cell_x = current.x, .cell_y = current.y };
}

// The cell a body entered this step, or null when either center is off-world or both
// lie in one cell.
fn cellEntryScalar(
    world: *const WorldSystem,
    previous_x: f32,
    previous_y: f32,
    position_x: f32,
    position_y: f32,
    size_x: f32,
    size_y: f32,
) ?CellCoord {
    const half_x = size_x * 0.5;
    const half_y = size_y * 0.5;
    const previous = world.cellContaining(previous_x + half_x, previous_y + half_y) orelse return null;
    const current = world.cellContaining(position_x + half_x, position_y + half_y) orelse return null;
    if (previous.x == current.x and previous.y == current.y) return null;
    return .{ .x = current.x, .y = current.y };
}

// Rows `[start, end)` into `window` (at most one entry per row); returns the count.
// Blocks of `lane_count` rows resolve their dense rows per lane, gather the columns,
// and run the cell test in lanes; only entered lanes reach the scalar `classify`. The
// tail runs `gatherRangeScalar`.
fn gatherRange(input: *const GatherInput, start: usize, end: usize, window: []PlaneEntry) usize {
    std.debug.assert(window.len >= end - start);
    var count: usize = 0;
    var row = start;
    const vector_end = start + simd.vectorizedEnd(end - start);
    while (row < vector_end) : (row += simd.lane_count) {
        var movement_rows: [simd.lane_count]usize = @splat(0);
        var visual_rows: [simd.lane_count]usize = @splat(0);
        var active: [simd.lane_count]bool = @splat(false);
        var any_active = false;
        inline for (0..simd.lane_count) |lane| {
            if (input.data.movementVisualDenseIndices(input.entities[row + lane])) |rows| {
                if (input.tier[rows.movement].allowsMovement()) {
                    movement_rows[lane] = rows.movement;
                    visual_rows[lane] = rows.visual;
                    active[lane] = true;
                    any_active = true;
                }
            }
        }
        // An active lane implies non-empty columns, so inactive lanes' row 0 is valid.
        if (!any_active) continue;
        const lanes = laneCellEntries(
            simd.gatherFloat4(input.previous_x, movement_rows),
            simd.gatherFloat4(input.previous_y, movement_rows),
            simd.gatherFloat4(input.position_x, movement_rows),
            simd.gatherFloat4(input.position_y, movement_rows),
            simd.gatherFloat4(input.size_x, visual_rows),
            simd.gatherFloat4(input.size_y, visual_rows),
            input.grid,
        );
        inline for (0..simd.lane_count) |lane| {
            if (active[lane] and lanes.entered[lane]) {
                // Inside the grid, so each lane cell fits `u16`.
                const cell = CellCoord{ .x = @intCast(lanes.cell_x[lane]), .y = @intCast(lanes.cell_y[lane]) };
                if (classify(input, input.entities[row + lane], movement_rows[lane], cell)) |entry| {
                    window[count] = entry;
                    count += 1;
                }
            }
        }
    }
    return count + gatherRangeScalar(input, row, end, window[count..]);
}

// Scalar twin of `gatherRange`: the per-row cell test through `cellEntryScalar`.
fn gatherRangeScalar(input: *const GatherInput, start: usize, end: usize, window: []PlaneEntry) usize {
    std.debug.assert(window.len >= end - start);
    var count: usize = 0;
    for (input.entities[start..end]) |entity| {
        const rows = input.data.movementVisualDenseIndices(entity) orelse continue;
        if (!input.tier[rows.movement].allowsMovement()) continue;
        const cell = cellEntryScalar(
            input.world,
            input.previous_x[rows.movement],
            input.previous_y[rows.movement],
            input.position_x[rows.movement],
            input.position_y[rows.movement],
            input.size_x[rows.visual],
            input.size_y[rows.visual],
        ) orelse continue;
        if (classify(input, entity, rows.movement, cell)) |entry| {
            window[count] = entry;
            count += 1;
        }
    }
    return count;
}

// An entered cell becomes an entry when plane traversal could act there (a ramp link,
// or a hole with a level below) or the agent lacks `world_level`; other cells are exact
// no-ops in the commit. Judged against the step's pre-commit world: the commit adds no
// links and never empties a floor, so this is a superset of its traversals, and the
// commit re-judges only an entry whose cell or landing an earlier carve this step
// touched. The player traverses on its own path, so it is never an entry.
fn classify(input: *const GatherInput, entity: EntityId, movement_row: usize, cell: CellCoord) ?PlaneEntry {
    if (entity.eql(input.player)) return null;
    const world_level = input.data.worldLevelConst(entity);
    const level = world_level orelse input.scope_level[movement_row];
    const target = planeTarget(input.world, level, cell, input.tunnel_tile);
    if (target.action == .attach and world_level != null) return null;
    return .{ .entity = entity, .target = target, .cell = cell, .level = level, .needs_world_level = world_level == null };
}

// ---- Tests ------------------------------------------------------------------

const AssetStore = @import("../../assets/assets.zig").AssetStore;
const manifest = @import("../../assets/manifest.zig");
const world_tileset_meta = @import("../../assets/world_tileset_meta.zig");
const DigConfig = @import("../dig_controller.zig").DigConfig;
const DigController = @import("../dig_controller.zig").DigController;
const Player = @import("../player.zig").Player;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;

const test_tile: f32 = 32;

// The walkable floor a fall carves, from the world's own tileset meta.
fn testTunnelTile(world: *const WorldSystem) !TileId {
    return (try DigConfig.fromMeta(world.tilesetMeta().?)).tunnel_tile;
}
const test_side: u16 = 8;
const test_levels: usize = 3;

// One agent of the parity population. `world_level` null leaves the component off;
// `visual` false leaves the visual off.
const TestAgent = struct {
    from: [2]f32,
    to: [2]f32,
    world_level: ?u16 = 0,
    tier: SimulationTier = .locomotion,
    visual: bool = true,
};

// Agent kinds of the parity population, by `index % agent_kind_count`, on row
// `index / agent_kind_count % 8`. Level-0 holes fill column 4, level-2 holes column
// 5, and ramps link column 6 between levels 1 and 0.
const agent_kind_count: usize = 11;

fn cellPos(x: i32) f32 {
    return @as(f32, @floatFromInt(x)) * test_tile;
}

fn parityAgent(index: usize) TestAgent {
    const row = cellPos(@intCast(index / agent_kind_count % test_side));
    return switch (index % agent_kind_count) {
        // Plain crossing: no entry.
        0 => .{ .from = .{ cellPos(1), row }, .to = .{ cellPos(2), row } },
        // Moves inside one cell: no entry.
        1 => .{ .from = .{ cellPos(2), row }, .to = .{ cellPos(2) + 3, row + 2 } },
        // Enters a level-0 hole: entry, falls.
        2 => .{ .from = .{ cellPos(3), row }, .to = .{ cellPos(4), row } },
        // Enters a hole on the bottom level: no entry.
        3 => .{ .from = .{ cellPos(4), row }, .to = .{ cellPos(5), row }, .world_level = 2 },
        // Enters a ramp-link cell on level 1: entry, climbs.
        4 => .{ .from = .{ cellPos(5), row }, .to = .{ cellPos(6), row }, .world_level = 1 },
        // Dormant over a hole: no entry.
        5 => .{ .from = .{ cellPos(3), row }, .to = .{ cellPos(4), row }, .tier = .dormant },
        // No visual over a hole: no entry.
        6 => .{ .from = .{ cellPos(3), row }, .to = .{ cellPos(4), row }, .visual = false },
        // Plain crossing without world_level: entry, attaches only.
        7 => .{ .from = .{ cellPos(1), row }, .to = .{ cellPos(2), row }, .world_level = null },
        // Hole entry without world_level: entry, attaches and falls.
        8 => .{ .from = .{ cellPos(3), row }, .to = .{ cellPos(4), row }, .world_level = null },
        // Enters from off the west edge: no entry.
        9 => .{ .from = .{ -40, row }, .to = .{ cellPos(0), row } },
        // Leaves off the east edge: no entry.
        else => .{ .from = .{ cellPos(7), row }, .to = .{ cellPos(test_side), row } },
    };
}

// Entries the parity population yields per full set of kinds (kinds 2, 4, 7, 8).
const entries_per_kind_set: usize = 4;

const TestFixture = struct {
    meta: world_tileset_meta.WorldTilesetMeta,
    world: WorldSystem,
    data: DataSystem,
    player: Player,
    agents: std.ArrayList(EntityId) = .empty,

    // Built in place: the world borrows `&self.meta`, so the fixture never moves after.
    fn init(self: *TestFixture, population: usize) !void {
        const allocator = std.testing.allocator;
        const asset_store = AssetStore.init(allocator, std.testing.io, "assets");
        self.meta = try world_tileset_meta.load(allocator, asset_store, manifest.spriteSpec(.world_tileset).metadata_path.?);
        errdefer self.meta.deinit();
        self.world = try WorldSystem.initDemoFromMetaWithUnderground(allocator, &self.meta, test_tile * test_side, test_tile * test_side);
        errdefer self.world.deinit();
        std.debug.assert(self.world.levelCount() == test_levels);
        const floor0 = self.world.denseFloorLayerForLevel(0).?;
        const floor2 = self.world.denseFloorLayerForLevel(2).?;
        for (0..test_side) |y| {
            const row: u16 = @intCast(y);
            _ = try self.world.clearDenseTile(floor0, 4, row);
            _ = try self.world.clearDenseTile(floor2, 5, row);
            try self.world.addLevelLink(.{ .kind = .ramp, .level_a = 1, .cell_a = .{ .x = 6, .y = row }, .level_b = 0, .cell_b = .{ .x = 6, .y = row }, .traversal_cost = 1, .bidirectional = true });
        }
        self.data = DataSystem.init(allocator);
        errdefer self.data.deinit();
        self.agents = .empty;
        errdefer self.agents.deinit(allocator);
        self.player = try Player.spawn(&self.data);
        for (0..population) |index| try self.addAgent(parityAgent(index));
    }

    fn deinit(self: *TestFixture) void {
        self.agents.deinit(std.testing.allocator);
        self.data.deinit();
        self.world.deinit();
        self.meta.deinit();
    }

    fn addAgent(self: *TestFixture, agent: TestAgent) !void {
        const data = &self.data;
        const npc = try data.createEntity();
        try data.setMovementBody(npc, .{});
        if (agent.visual) try data.setPrimitiveVisual(npc, .{
            .size = .{ .x = test_tile, .y = test_tile },
            .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
            .marker_color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
        });
        try data.setAiAgent(npc, .{ .active_behavior = .wander, .gain_pursue = 0 });
        if (agent.world_level) |level| try data.setWorldLevel(npc, level);
        // Set before the positions: a non-moving tier snaps previous to current.
        try data.setSimulationTier(npc, agent.tier);
        const body = data.movementBodyPtr(npc).?;
        body.previous_x.* = agent.from[0];
        body.previous_y.* = agent.from[1];
        body.position_x.* = agent.to[0];
        body.position_y.* = agent.to[1];
        try self.agents.append(std.testing.allocator, npc);
    }

    fn digController(self: *const TestFixture) !DigController {
        var dig = DigController.init(try DigConfig.fromMeta(&self.meta));
        errdefer dig.deinit();
        try dig.reservePlaneScratch(std.testing.allocator, self.agents.items.len + 1);
        return dig;
    }
};

// What one plane stage left behind, for comparing runs.
const StageOutcome = struct {
    tiles: [test_levels][test_side * test_side]TileId,
    levels: []?u16,
    positions: [][2]f32,
    carves: usize,
    published: usize,

    fn capture(fixture: *const TestFixture, frame: *const SimulationFrame, carves: usize) !StageOutcome {
        var outcome: StageOutcome = .{
            .tiles = undefined,
            .levels = try std.testing.allocator.alloc(?u16, fixture.agents.items.len),
            .positions = undefined,
            .carves = carves,
            .published = frame.events.stats.world_tile_changed,
        };
        errdefer std.testing.allocator.free(outcome.levels);
        outcome.positions = try std.testing.allocator.alloc([2]f32, fixture.agents.items.len);
        for (0..test_levels) |level| {
            const floor = fixture.world.denseFloorLayerForLevel(@intCast(level)).?;
            for (0..test_side) |y| for (0..test_side) |x| {
                outcome.tiles[level][y * test_side + x] = fixture.world.denseTile(floor, @intCast(x), @intCast(y));
            };
        }
        for (fixture.agents.items, outcome.levels, outcome.positions) |npc, *level, *position| {
            level.* = fixture.data.worldLevelConst(npc);
            const body = fixture.data.movementBodyConst(npc).?;
            position.* = .{ body.position.x, body.position.y };
        }
        return outcome;
    }

    fn deinit(self: *StageOutcome) void {
        std.testing.allocator.free(self.positions);
        std.testing.allocator.free(self.levels);
    }

    fn expectEqual(want: StageOutcome, got: StageOutcome) !void {
        for (want.tiles, got.tiles) |want_level, got_level| try std.testing.expectEqualSlices(TileId, &want_level, &got_level);
        try std.testing.expectEqualSlices(?u16, want.levels, got.levels);
        try std.testing.expectEqualSlices([2]f32, want.positions, got.positions);
        try std.testing.expectEqual(want.carves, got.carves);
        try std.testing.expectEqual(want.published, got.published);
    }
};

// Gathers with `thread_system` and `config`, checks the entries against `want` when
// given, then runs the plane stage's reserve and commit (its carve batch on
// `thread_system` too) on them.
fn runParityStage(population: usize, thread_system: ?*ThreadSystem, config: PlaneEntryConfig, want: ?[]const PlaneEntry) !StageOutcome {
    var fixture: TestFixture = undefined;
    try fixture.init(population);
    defer fixture.deinit();
    var system = PlaneEntrySystem.init(std.testing.allocator);
    defer system.deinit();
    system.config = config;
    try system.reserve(population);
    const entries = try system.gather(&fixture.data, &fixture.world, fixture.player.entity, try testTunnelTile(&fixture.world), thread_system);
    if (want) |expected| try std.testing.expectEqualSlices(PlaneEntry, expected, entries);

    var dig = try fixture.digController();
    defer dig.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, population + 1, 0, 0, 0, 0);
    frame.beginStep();
    const reservation = try dig.reservePlaneTraversalStage(&fixture.world, &fixture.data, &fixture.player, &frame, entries, thread_system);
    try dig.commitPlaneTraversalStage(&fixture.world, &fixture.data, &fixture.player, &frame, reservation, thread_system);
    return StageOutcome.capture(&fixture, &frame, reservation.carves);
}

test "plane entry gather: serial, inline, and threaded entries and stage results match across range sizes and worker counts" {
    const allocator = std.testing.allocator;
    // Not a multiple of the lane count, so every block shape and a scalar tail run.
    const population: usize = agent_kind_count * 7;
    try std.testing.expect(population % simd.lane_count != 0);

    var serial_fixture: TestFixture = undefined;
    try serial_fixture.init(population);
    defer serial_fixture.deinit();
    var serial_system = PlaneEntrySystem.init(allocator);
    defer serial_system.deinit();
    const serial_entries = try serial_system.gather(&serial_fixture.data, &serial_fixture.world, serial_fixture.player.entity, try testTunnelTile(&serial_fixture.world), null);
    try std.testing.expectEqual(entries_per_kind_set * (population / agent_kind_count), serial_entries.len);
    for (serial_entries, 0..) |entry, index| {
        // AI row order: kinds 2, 4, 7, 8 of each set.
        const agent_index = index / entries_per_kind_set * agent_kind_count + switch (index % entries_per_kind_set) {
            0 => @as(usize, 2),
            1 => 4,
            2 => 7,
            else => 8,
        };
        try std.testing.expect(entry.entity.eql(serial_fixture.agents.items[agent_index]));
        try std.testing.expectEqual(agent_index % agent_kind_count >= 7, entry.needs_world_level);
    }
    const want = try allocator.dupe(PlaneEntry, serial_entries);
    defer allocator.free(want);

    var serial_outcome = try runParityStage(population, null, .{}, want);
    defer serial_outcome.deinit();
    // Falls: kind 2 and 8 per set carve one landing between them; kind 4 climbs.
    try std.testing.expectEqual(population / agent_kind_count, serial_outcome.published);

    var inline_threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer inline_threads.deinit();
    inline for (.{ PlaneEntryConfig{}, PlaneEntryConfig{ .items_per_range = 16, .adaptive = false } }) |config| {
        var outcome = try runParityStage(population, &inline_threads, config, want);
        defer outcome.deinit();
        try serial_outcome.expectEqual(outcome);
    }

    if (builtin.single_threaded) return;
    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return;
    for ([_]usize{ 16, 32, 64 }) |items_per_range| {
        var outcome = try runParityStage(population, &threads, .{ .items_per_range = items_per_range, .max_worker_threads = 2, .adaptive = false }, want);
        defer outcome.deinit();
        try serial_outcome.expectEqual(outcome);
    }
}

test "plane entry SIMD blocks match the scalar entry test" {
    // Lane test against `cellContaining` on exact boundary centers (a -0.0 size keeps
    // each center equal to its position, -0.0 included):
    // the origin, -0.0, inside (-tile, 0), exact tile multiples, the far edge, and
    // crossings in x only, y only, and both.
    var world = WorldSystem{ .allocator = std.testing.allocator, .width = test_side, .height = test_side, .tile_size = test_tile, .chunk_size_tiles = test_side };
    defer world.deinit();
    const edge = test_tile * test_side;
    const Case = struct { previous: [2]f32, current: [2]f32, size: f32 };
    const cases = [_]Case{
        .{ .previous = .{ 40, 40 }, .current = .{ 0, 40 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ -0.0, 40 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ 40, -0.0 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ -1, 40 }, .size = -0.0 },
        .{ .previous = .{ -31.5, 40 }, .current = .{ 40, 40 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ 64, 40 }, .size = -0.0 },
        .{ .previous = .{ 63.75, 40 }, .current = .{ 64, 40 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ edge, 40 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ edge - 0.25, 40 }, .size = -0.0 },
        .{ .previous = .{ 40, edge }, .current = .{ 40, 40 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ 72, 40 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ 40, 72 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ 72, 72 }, .size = -0.0 },
        .{ .previous = .{ 40, 40 }, .current = .{ 41, 42 }, .size = -0.0 },
        .{ .previous = .{ 15, 15 }, .current = .{ 16, 16 }, .size = 32 },
        .{ .previous = .{ -16, 0 }, .current = .{ 16, 0 }, .size = 32 },
    };
    comptime std.debug.assert(cases.len % simd.lane_count == 0);
    const grid = CellGrid.of(&world);
    var block: usize = 0;
    while (block < cases.len) : (block += simd.lane_count) {
        var columns: [6][simd.lane_count]f32 = undefined;
        for (cases[block..][0..simd.lane_count], 0..) |case, lane| {
            columns[0][lane] = case.previous[0];
            columns[1][lane] = case.previous[1];
            columns[2][lane] = case.current[0];
            columns[3][lane] = case.current[1];
            columns[4][lane] = case.size;
            columns[5][lane] = case.size;
        }
        const lanes = laneCellEntries(
            simd.loadFloat4(&columns[0]),
            simd.loadFloat4(&columns[1]),
            simd.loadFloat4(&columns[2]),
            simd.loadFloat4(&columns[3]),
            simd.loadFloat4(&columns[4]),
            simd.loadFloat4(&columns[5]),
            grid,
        );
        const entered: [simd.lane_count]bool = lanes.entered;
        const cell_x = simd.toIntArray(lanes.cell_x);
        const cell_y = simd.toIntArray(lanes.cell_y);
        for (cases[block..][0..simd.lane_count], 0..) |case, lane| {
            const want = cellEntryScalar(&world, case.previous[0], case.previous[1], case.current[0], case.current[1], case.size, case.size);
            try std.testing.expectEqual(want != null, entered[lane]);
            if (want) |cell| {
                try std.testing.expectEqual(@as(i32, cell.x), cell_x[lane]);
                try std.testing.expectEqual(@as(i32, cell.y), cell_y[lane]);
            }
        }
    }

    // Whole rows: the SIMD range against the scalar range over the parity population.
    const population = agent_kind_count * simd.lane_count * 2;
    var fixture: TestFixture = undefined;
    try fixture.init(population);
    defer fixture.deinit();
    const movement = fixture.data.movementBodySliceConst();
    const visuals = fixture.data.primitiveVisualSliceConst();
    const scope = fixture.data.scopeColumnsSliceConst();
    const input = GatherInput{
        .data = &fixture.data,
        .world = &fixture.world,
        .player = fixture.player.entity,
        .entities = fixture.data.aiAgentSliceConst().entities,
        .previous_x = movement.previous_x,
        .previous_y = movement.previous_y,
        .position_x = movement.position_x,
        .position_y = movement.position_y,
        .size_x = visuals.size_x,
        .size_y = visuals.size_y,
        .tier = scope.tier,
        .scope_level = scope.level,
        .grid = CellGrid.of(&fixture.world),
        .tunnel_tile = try testTunnelTile(&fixture.world),
    };
    var simd_window: [population]PlaneEntry = undefined;
    var scalar_window: [population]PlaneEntry = undefined;
    const simd_count = gatherRange(&input, 0, population, &simd_window);
    const scalar_count = gatherRangeScalar(&input, 0, population, &scalar_window);
    try std.testing.expect(simd_count > 0);
    try std.testing.expectEqualSlices(PlaneEntry, scalar_window[0..scalar_count], simd_window[0..simd_count]);
}

test "plane entry test fixture's world reads the fixture's own tileset meta" {
    var fixture: TestFixture = undefined;
    try fixture.init(0);
    defer fixture.deinit();
    try std.testing.expect(fixture.world.tilesetMeta().? == &fixture.meta);
}

test "plane entry gather never yields the player, even as an AI agent; the stage traverses it once on its own path" {
    var fixture: TestFixture = undefined;
    try fixture.init(0);
    defer fixture.deinit();
    const data = &fixture.data;
    const player = fixture.player.entity;
    // The first AI row, so it sits in a SIMD block with three NPCs; the fourth NPC is
    // the scalar tail.
    try data.setAiAgent(player, .{ .active_behavior = .wander, .gain_pursue = 0 });
    try data.setSimulationTier(player, .locomotion);
    const player_size = data.primitiveVisualConst(player).?.size;
    try std.testing.expect(player_size.x <= test_tile and player_size.y <= test_tile);
    // Enters the level-0 hole at (4,1).
    const body = data.movementBodyPtr(player).?;
    body.previous_x.* = cellPos(3);
    body.previous_y.* = cellPos(1);
    body.position_x.* = cellPos(4);
    body.position_y.* = cellPos(1);
    // Four NPCs enter the level-0 hole at (4,0).
    for (0..simd.lane_count) |_| try fixture.addAgent(parityAgent(2));
    try std.testing.expectEqual(simd.lane_count + 1, data.aiAgentSliceConst().entities.len);
    try std.testing.expect(data.aiAgentSliceConst().entities[0].eql(player));

    var system = PlaneEntrySystem.init(std.testing.allocator);
    defer system.deinit();
    const entries = try system.gather(data, &fixture.world, player, try testTunnelTile(&fixture.world), null);
    try std.testing.expectEqual(fixture.agents.items.len, entries.len);
    for (entries, fixture.agents.items) |entry, npc| try std.testing.expect(entry.entity.eql(npc));

    var dig = try fixture.digController();
    defer dig.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(4, entries.len + 1, 0, 0, 0, 0);
    frame.beginStep();
    const reservation = try dig.reservePlaneTraversalStage(&fixture.world, data, &fixture.player, &frame, entries, null);
    try dig.commitPlaneTraversalStage(&fixture.world, data, &fixture.player, &frame, reservation, null);
    // One fall each: the player's landing at (4,1) and the NPCs' shared one at (4,0).
    try std.testing.expectEqual(@as(?u16, 1), data.worldLevelConst(player));
    try std.testing.expectEqual(@as(u16, 1), fixture.player.current_level);
    for (fixture.agents.items) |npc| try std.testing.expectEqual(@as(?u16, 1), data.worldLevelConst(npc));
    try std.testing.expectEqual(@as(usize, 2), frame.events.stats.world_tile_changed);
}

test "warmed plane entry gather allocates nothing on real workers (FailingAllocator)" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    // Not a range multiple, so the last range is a short tail.
    const population = plane_entry_range_alignment_items * 8 + 3;
    var fixture: TestFixture = undefined;
    try fixture.init(population);
    defer fixture.deinit();

    var serial = PlaneEntrySystem.init(allocator);
    defer serial.deinit();
    const want = try allocator.dupe(PlaneEntry, try serial.gather(&fixture.data, &fixture.world, fixture.player.entity, try testTunnelTile(&fixture.world), null));
    defer allocator.free(want);
    try std.testing.expect(want.len > 0);

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;
    var system = PlaneEntrySystem.init(allocator);
    defer system.deinit();
    try system.reserve(population);

    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    const original_thread_allocator = threads.allocator;
    system.allocator = failing.allocator();
    threads.allocator = failing.allocator();
    defer {
        system.allocator = allocator;
        threads.allocator = original_thread_allocator;
    }
    for ([_]usize{ 32, 16 }) |items_per_range| {
        system.config = .{ .items_per_range = items_per_range, .max_worker_threads = 2, .adaptive = false };
        const entries = try system.gather(&fixture.data, &fixture.world, fixture.player.entity, try testTunnelTile(&fixture.world), &threads);
        try std.testing.expect(!system.last_batch.ran_inline);
        try std.testing.expectEqual(@divCeil(population, items_per_range), system.last_batch.range_count);
        try std.testing.expectEqualSlices(PlaneEntry, want, entries);
    }
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(u64, 0), system.windows_grown);
}

test "plane entry gather past its reservation grows once before dispatch; OOM returns before any write" {
    const allocator = std.testing.allocator;
    const population = agent_kind_count * 4;
    var fixture: TestFixture = undefined;
    try fixture.init(population);
    defer fixture.deinit();
    var serial = PlaneEntrySystem.init(allocator);
    defer serial.deinit();
    const want = try allocator.dupe(PlaneEntry, try serial.gather(&fixture.data, &fixture.world, fixture.player.entity, try testTunnelTile(&fixture.world), null));
    defer allocator.free(want);
    try std.testing.expect(want.len > 0);

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    var system = PlaneEntrySystem.init(allocator);
    defer system.deinit();
    system.config = .{ .items_per_range = plane_entry_range_alignment_items, .adaptive = false };
    try system.reserve(plane_entry_range_alignment_items);
    try std.testing.expect(population > system.reserved_items);

    const floor1 = fixture.world.denseFloorLayerForLevel(1).?;
    const landing_before = fixture.world.denseTile(floor1, 4, 0);
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, system.gather(&fixture.data, &fixture.world, fixture.player.entity, try testTunnelTile(&fixture.world), &threads));
    system.allocator = allocator;
    try std.testing.expectEqual(@as(u64, 0), system.windows_grown);
    try std.testing.expectEqual(@as(usize, 0), system.entries.items.len);
    try std.testing.expectEqual(landing_before, fixture.world.denseTile(floor1, 4, 0));
    for (fixture.agents.items, 0..) |npc, index| {
        try std.testing.expectEqual(parityAgent(index).world_level, fixture.data.worldLevelConst(npc));
    }

    const entries = try system.gather(&fixture.data, &fixture.world, fixture.player.entity, try testTunnelTile(&fixture.world), &threads);
    try std.testing.expectEqual(@as(u64, 1), system.windows_grown);
    try std.testing.expect(system.reserved_items >= population);
    try std.testing.expectEqualSlices(PlaneEntry, want, entries);
    // A second gather of the same rows fits the grown windows.
    _ = try system.gather(&fixture.data, &fixture.world, fixture.player.entity, try testTunnelTile(&fixture.world), &threads);
    try std.testing.expectEqual(@as(u64, 1), system.windows_grown);
}
