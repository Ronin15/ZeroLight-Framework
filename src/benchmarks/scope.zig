// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Scoped simulation-processing throughput. This is the Slice 24 evidence bench:
//! it runs the real per-step processing stages — AI cognition, collision, and
//! movement (with in-pass chunk derivation) — but gated by the scope system, so
//! the measured cost reflects the ACTIVE work, not the full entity count.
//!
//! The fixture spreads N entities across the chunk grid and assigns each its
//! simulation-LOD tier via the cube `lodDistance` (`tierForChunkDistance`). The x/y
//! spread stays inside the cognition halo, so the bands here come from the per-level
//! depth penalty (`level = index % 5`): levels 0-1 cognition, 2 locomotion, 3
//! kinematic, 4 dormant. So this measures a realistic MIXED-TIER population, not
//! all-cognition:
//!   - movement runs on all non-dormant rows (tier gather drops dormant).
//!   - collision runs on locomotion+cognition (drops dormant+kinematic).
//!   - AI runs on the cognition subset, further gated by camera halo + stagger.
//!   - movement derives each integrated body's chunk in-pass (chunk_grid).
//!
//! `output_count` reports how many entities actually ran cognition this step, so the
//! gap between that and N is the scope reduction. Note the timed window covers the
//! whole scoped step (AI + collision + movement + gathers + tier policy), so it is
//! not directly comparable to the AI-only `ai` group.

const std = @import("std");
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const math = @import("../core/math.zig");
const DataSystem = @import("../game/data_system.zig").DataSystem;
const movement_range_alignment_items = @import("../game/data_system.zig").movement_range_alignment_items;
const movement = @import("../game/systems/movement.zig");
const MovementSystem = @import("../game/systems/movement.zig").MovementSystem;
const AiSystem = @import("../game/systems/ai.zig").AiSystem;
const ai_range_alignment_items = @import("../game/systems/ai.zig").ai_range_alignment_items;
const CollisionSystem = @import("../game/systems/collision.zig").CollisionSystem;
const collision_range_alignment_items = @import("../game/systems/collision.zig").collision_range_alignment_items;
const SimulationScopeSystem = @import("../game/systems/simulation_scope.zig").SimulationScopeSystem;
const ScopeConfig = @import("../game/systems/simulation_scope.zig").ScopeConfig;
const scope_range_alignment_items = @import("../game/systems/simulation_scope.zig").scope_range_alignment_items;
const ActiveRegion = @import("../game/simulation_scope.zig").ActiveRegion;
const SimulationTier = @import("../game/simulation_scope.zig").SimulationTier;
const tierForChunkDistance = @import("../game/simulation_scope.zig").tierForChunkDistance;
const cognition_halo_chunks = @import("../game/simulation_scope.zig").cognition_halo_chunks;
const cognition_stagger_n = @import("../game/simulation_scope.zig").cognition_stagger_n;
const StructuralCommand = @import("../game/data_system.zig").StructuralCommand;
const SimulationFrame = @import("../game/simulation.zig").SimulationFrame;
const RangeOutputStream = @import("../game/simulation.zig").RangeOutputStream;
const CollisionContact = @import("../game/simulation.zig").CollisionContact;
const suite = @import("suite.zig");

const delta_seconds: f32 = 1.0 / 60.0;
const intent_seed: u64 = 0x5c0_9ed5;

// Grid: 32px tiles, 8-tile (256px) chunks, 16 chunks across. Entities spread over
// the 16 x-chunks and are banded into all four LOD tiers by distance from the
// visible window (see visibleRegion); the cognition subset is then stagger-gated.
const tile_size: f32 = 32;
const chunk_size_tiles: u16 = 8;
const grid_chunks: u16 = 16;
const grid_tiles: u16 = grid_chunks * chunk_size_tiles;
const chunk_px: f32 = tile_size * @as(f32, @floatFromInt(chunk_size_tiles));

// Camera-visible chunk window: left two x-chunks, full height. The LOD bands fan
// out from here, so over the 16 x-chunks the population lands roughly: cognition
// x0-5, locomotion x6-9, kinematic x10-13, dormant x14-15 — a real four-tier mix.
fn visibleRegion() ActiveRegion {
    return .{ .min = .{ .x = 0, .y = 0 }, .max_exclusive = .{ .x = 2, .y = grid_chunks } };
}

// Cognition halo = visible window expanded by cognition_halo_chunks; the AI gather
// gates on it. Matches the cognition band so cognition-tier entities are in-halo.
fn cognitionHaloRegion() ActiveRegion {
    const v = visibleRegion();
    const h: i32 = cognition_halo_chunks;
    return .{
        .min = .{ .x = v.min.x - h, .y = v.min.y - h },
        .max_exclusive = .{ .x = v.max_exclusive.x + h, .y = v.max_exclusive.y + h },
    };
}

pub const group = suite.BenchmarkGroup{
    .name = "scope",
    .defaultItemCounts = defaultItemCounts,
    .runCase = runCase,
};

const Fixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    contacts: RangeOutputStream(CollisionContact),

    fn deinit(self: *Fixture) void {
        self.contacts.deinit();
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }
};

pub fn defaultItemCounts(profile: suite.Profile) []const usize {
    return suite.eventScaleCounts(profile);
}

pub fn createFixture(allocator: std.mem.Allocator, count: usize) !Fixture {
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    // Reserve a structural-command range/value budget for the tier policy pass so
    // a band crossing mid-measurement never allocates on the hot path.
    try frame.reserveStreams(suite.rangeCount(count, ai_range_alignment_items), 0, count, 0, 0, count);
    var contacts = RangeOutputStream(CollisionContact).init(allocator);
    errdefer contacts.deinit();

    for (0..count) |index| {
        const entity = try data.createEntity();
        // Spread across the 16 x-chunks; rows step in y so bodies do not all pile
        // into one broadphase column. Small velocity keeps the chunk derivation live.
        const chunk_col: f32 = @floatFromInt(index % grid_chunks);
        const row: f32 = @floatFromInt(index / grid_chunks);
        const position = math.Vec2{
            .x = chunk_col * chunk_px + 8.0 + @mod(row, 200.0),
            .y = 32.0 + @mod(row * 13.0, @as(f32, grid_tiles) * tile_size - 64.0),
        };
        try data.setMovementBody(entity, .{
            .position = position,
            .previous_position = position,
            .velocity = .{ .x = 1.0, .y = 0.5 },
            .speed = 35.0 + @as(f32, @floatFromInt(index % 17)),
        });
        try data.setCollisionBounds(entity, .{ .size = .{ .x = 12, .y = 12 } });
        try data.setAiAgent(entity, .{
            .behavior = if (index % 3 == 0) .wander else .seek,
            .wander_amplitude = 6.0 + @as(f32, @floatFromInt(index % 29)),
            .seek_weight = if (index % 3 == 0) 0.0 else 0.5,
        });
        // Spread the population across depth/levels too (forward-looking: NPCs are
        // level 0 today). The cube LOD distance weights one level as a full band, so
        // levels 0–4 fan the population into all four tiers regardless of x/y, and the
        // off-level entities are excluded from cognition by the cube — a real mixed
        // workload the gathers and tier policy actually scan.
        const chunk_x: i32 = @intCast(index % grid_chunks);
        const level: u16 = @intCast(index % 5);
        const tier = tierForChunkDistance(visibleRegion().lodDistance(.{ .x = chunk_x, .y = 0 }, level));
        try data.setSimulationMetadata(entity, .{
            .tier = tier,
            .chunk = .{ .x = chunk_x, .y = 0 },
            .level = level,
            .stagger_phase = @intCast(index % cognition_stagger_n),
        });
    }

    return .{ .data = data, .frame = frame, .contacts = contacts };
}

pub fn runCase(allocator: std.mem.Allocator, io: std.Io, options: suite.Options, case: suite.BenchmarkCase, item_count: usize) !suite.RunStats {
    if (suite.skipIfWorkersUnavailable(case)) |skip| return skip;

    var fixture = try createFixture(allocator, item_count);
    defer fixture.deinit();
    var scope = SimulationScopeSystem.init(allocator);
    defer scope.deinit();
    var ai = AiSystem.init(allocator);
    defer ai.deinit();
    var collision = CollisionSystem.init(allocator);
    defer collision.deinit();
    var move = MovementSystem.init();
    // Each stage trains its own adaptive tuner(s) from the case, exactly as that
    // stage's own benchmark does (one tuner per independently-timed threaded stage).
    if (suite.adaptiveTunerForCase(case, ai_range_alignment_items)) |tuner| {
        ai.separation_tuner = tuner;
        ai.intent_tuner = suite.adaptiveTunerForCase(case, ai_range_alignment_items).?;
    }
    if (suite.adaptiveTunerForCase(case, collision_range_alignment_items)) |tuner| {
        collision.broadphase_tuner = tuner;
        collision.narrowphase_tuner = suite.adaptiveTunerForCase(case, collision_range_alignment_items).?;
    }
    // The reported primary batch is the movement stage; settle its tuner like the
    // movement bench so the measured profile is the trained one.
    if (suite.adaptiveTunerForCase(case, movement_range_alignment_items)) |tuner| {
        move.adaptive_tuner = tuner;
    }

    var threads: ?ThreadSystem = null;
    if (case.usesThreadSystem()) {
        threads = try ThreadSystem.init(allocator, io, .{
            .max_worker_threads = case.maxWorkerThreads(),
            .items_per_range = suite.default_items_per_range,
        });
    }
    defer if (threads) |*thread_system| thread_system.deinit();

    var ctx = RunContext{ .scope = &scope, .ai = &ai, .collision = &collision, .move = &move, .fixture = &fixture, .case = case };

    for (0..options.warmup_iterations) |_| {
        _ = try runOnce(&ctx, if (threads) |*thread_system| thread_system else null);
    }
    if (case.adaptive) {
        var settle_guard: usize = 0;
        const settle_limit = suite.adaptiveSettleIterationLimit(options);
        // Every stage adapts inside the measured window, so gate on all of their
        // tuners — including the scope stage's own gather/tier-policy tuners — before
        // measuring, or the early iterations would time still-adapting dispatch.
        while (!allTunersSettled(&ai, &collision, &move, &scope) and settle_guard < settle_limit) : (settle_guard += 1) {
            _ = try runOnce(&ctx, if (threads) |*thread_system| thread_system else null);
        }
    }
    const settled_before_measurement = if (case.adaptive) allTunersSettled(&ai, &collision, &move, &scope) else false;

    var accumulator = suite.StatsAccumulator.init(item_count);
    var active_cognition: usize = 0;
    for (0..options.iterations) |_| {
        const start_ns = suite.nowNs(io);
        const result = try runOnce(&ctx, if (threads) |*thread_system| thread_system else null);
        const end_ns = suite.nowNs(io);
        accumulator.record(suite.elapsedNs(start_ns, end_ns), result.batch);
        active_cognition = result.active_cognition;
    }

    var stats = accumulator.finish();
    // output_count = entities that actually ran cognition this step; the gap to
    // item_count is the scope reduction.
    stats.output_count = active_cognition;
    if (case.adaptive) {
        stats.work_tuning = suite.workTuningSummary(move.adaptive_tuner.report(), settled_before_measurement);
    }
    return stats;
}

/// True once every stage's adaptive tuner has settled. The measured window times
/// the scope gathers + tier policy alongside AI + collision + movement, so all of
/// their tuners must settle first.
fn allTunersSettled(ai: *const AiSystem, collision: *const CollisionSystem, move: *const MovementSystem, scope: *const SimulationScopeSystem) bool {
    return move.adaptive_tuner.isSettled() and
        ai.separation_tuner.isSettled() and ai.intent_tuner.isSettled() and
        collision.broadphase_tuner.isSettled() and collision.narrowphase_tuner.isSettled() and
        scope.movement_gather_tuner.isSettled() and scope.collision_gather_tuner.isSettled() and
        scope.ai_gather_tuner.isSettled() and scope.tier_policy_tuner.isSettled();
}

const RunContext = struct {
    scope: *SimulationScopeSystem,
    ai: *AiSystem,
    collision: *CollisionSystem,
    move: *MovementSystem,
    fixture: *Fixture,
    case: suite.BenchmarkCase,
};

const RunResult = struct {
    batch: BatchStats,
    active_cognition: usize,
};

fn runOnce(ctx: *RunContext, thread_system: ?*ThreadSystem) !RunResult {
    const fixture = ctx.fixture;
    fixture.frame.beginStep();
    ctx.scope.advanceStep();

    // AI gates on the cognition halo (the same window the fixture banded tiers
    // from) plus stagger; the cognition-tier subset all falls inside it.
    const region = cognitionHaloRegion();
    const scope_config = scopeConfig(ctx.case);

    // Scope passes thread the same way as the downstream systems: serial cases run
    // the *Serial variants, threaded cases the adaptive threaded gathers so the
    // scope stage's own tuners train inside the measured window.
    var move_indices: ?[]const u32 = undefined;
    var collision_indices: ?[]const u32 = undefined;
    var ai_indices: []const u32 = undefined;
    if (thread_system) |ts| {
        move_indices = (try ctx.scope.gatherMovementBodyIndices(&fixture.data, ts, scope_config)).indices;
        collision_indices = (try ctx.scope.gatherCollisionBoundsIndices(&fixture.data, ts, scope_config)).indices;
        ai_indices = (try ctx.scope.gatherAiAgentIndices(&fixture.data, region, ctx.scope.staggerStep(), ts, scope_config)).indices;
    } else {
        move_indices = try ctx.scope.gatherMovementBodyIndicesSerial(&fixture.data);
        collision_indices = try ctx.scope.gatherCollisionBoundsIndicesSerial(&fixture.data);
        ai_indices = try ctx.scope.gatherAiAgentIndicesSerial(&fixture.data, region, ctx.scope.staggerStep());
    }

    const ai_slice = fixture.data.aiAgentSliceConst();
    const move_slice_const = fixture.data.movementBodySliceConst();

    const scope_columns = fixture.data.scopeColumnsSlice();
    const chunk_grid = movement.ChunkGridParams{
        .chunk_x = scope_columns.chunk_x,
        .chunk_y = scope_columns.chunk_y,
        .tile_size = tile_size,
        .chunk_size_tiles = chunk_size_tiles,
        .width = grid_tiles,
        .height = grid_tiles,
    };

    if (!ctx.case.usesThreadSystem()) {
        _ = try ctx.ai.updateSerial(ai_slice, move_slice_const, &fixture.data, &fixture.frame, delta_seconds, .{
            .intent_seed = intent_seed,
            .seek_target = .{ .x = 480, .y = 270 },
            .scope_dense_indices = ai_indices,
        });
        _ = try ctx.collision.updateSerialScoped(&fixture.data, &fixture.contacts, collision_indices);
        var slice = fixture.data.movementBodySlice();
        movement.updateSerialScoped(&slice, delta_seconds, move_indices, chunk_grid);
        // Tier policy reads the chunk movement just derived; serial path emits one range.
        try ctx.scope.queueTierChangesSerial(&fixture.data, visibleRegion(), &fixture.frame.structural_commands);
        return .{ .batch = suite.serialBatch(move_slice_const.entities.len, movement_range_alignment_items), .active_cognition = ai_indices.len };
    }

    _ = try ctx.ai.update(ai_slice, move_slice_const, &fixture.data, &fixture.frame, thread_system.?, delta_seconds, .{
        .items_per_range = itemsPerRange(ctx.case, ai_range_alignment_items),
        .max_worker_threads = ctx.case.maxWorkerThreads(),
        .adaptive = ctx.case.adaptive,
        .intent_seed = intent_seed,
        .seek_target = .{ .x = 480, .y = 270 },
        .scope_dense_indices = ai_indices,
    });
    _ = try ctx.collision.update(&fixture.data, &fixture.contacts, thread_system.?, .{
        .items_per_range = itemsPerRange(ctx.case, collision_range_alignment_items),
        .max_worker_threads = ctx.case.maxWorkerThreads(),
        .adaptive = ctx.case.adaptive,
        .scope_dense_indices = collision_indices,
    });
    var slice = fixture.data.movementBodySlice();
    const move_stats = ctx.move.update(&slice, thread_system.?, delta_seconds, .{
        .items_per_range = itemsPerRange(ctx.case, movement_range_alignment_items),
        .max_worker_threads = ctx.case.maxWorkerThreads(),
        .adaptive = ctx.case.adaptive,
        .scope_dense_indices = move_indices,
        .chunk_grid = chunk_grid,
    });
    // Threaded tier policy trains its own tuner inside the measured window.
    _ = try ctx.scope.queueTierChanges(&fixture.data, visibleRegion(), &fixture.frame.structural_commands, thread_system.?, scope_config);
    return .{ .batch = move_stats.batch, .active_cognition = ai_indices.len };
}

/// Scope-pass threading config for a case: adaptive cases let the scope tuners
/// train (null range); fixed cases pin the same range size as the other stages.
fn scopeConfig(case: suite.BenchmarkCase) ScopeConfig {
    return .{
        .items_per_range = itemsPerRange(case, scope_range_alignment_items),
        .max_worker_threads = case.maxWorkerThreads(),
        .adaptive = case.adaptive,
    };
}

/// Fixed (non-adaptive) cases pin an explicit range size like every other bench;
/// adaptive cases return null so each stage's tuner trains its own profile.
fn itemsPerRange(case: suite.BenchmarkCase, alignment: usize) ?usize {
    if (case.adaptive) return null;
    return case.itemsPerRange(alignment) orelse
        suite.alignItemCount(suite.default_items_per_range, alignment);
}

test "scope benchmark fixture creates simulated entities with movement, bounds, and ai" {
    var fixture = try createFixture(std.testing.allocator, 64);
    defer fixture.deinit();
    try std.testing.expectEqual(@as(usize, 64), fixture.data.movementBodySliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 64), fixture.data.collisionBoundsSliceConst().entities.len);
    try std.testing.expectEqual(@as(usize, 64), fixture.data.aiAgentSliceConst().entities.len);
}

test "scope benchmark tiny serial case runs the scoped sim stages without display" {
    var options = suite.Options{
        .warmup_iterations = 1,
        .iterations = 1,
    };
    options.profile = .quick;
    const stats = try runCase(std.testing.allocator, std.testing.io, options, suite.default_cases[0], 1_024);
    try std.testing.expectEqual(suite.RunStatus.measured, stats.status);
    // Cognition ran on a strict subset (halo covers half the grid, stagger keeps
    // ~1/4 of those), proving the scope actually reduced the cognition workload.
    try std.testing.expect(stats.output_count > 0);
    try std.testing.expect(stats.output_count < 1_024);
}
