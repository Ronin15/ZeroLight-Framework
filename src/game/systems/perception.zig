// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI perception substrate (Slice 29): gathers the cognition-scoped subset of
//! AI agents that also carry an `AiPerception` component, queries the shared
//! `SpatialIndexSystem` (Slice 28) for nearby hostile candidates, applies a
//! squared-form field-of-view test and a bounded line-of-sight raycast, and
//! writes the winning `nearest_threat`/`target_visible`/`last_seen_x/y`/
//! `facing_x/y` hot columns back onto `DataSystem`'s `PerceptionStore`.
//! Emits `entity_perceived`/`entity_lost` `SimulationEvent`s on transitions,
//! range-owned during the parallel compute pass and merged deterministically
//! afterward — same gather -> parallel compute -> per-range emit -> merge
//! shape as `ai.zig`/`collision.zig`.
//!
//! Two-index-space contract (population-domain equivalence with
//! `spatial_index.zig`, mirrors `ai.zig`'s cross-file contract): this
//! system's own gather is a FILTERED SUBSET of the scoped population (only
//! entities that also carry `AiPerception`), so it cannot reuse its own row
//! index as `SpatialIndexView.queryNeighbors`'s self-exclusion index. Instead
//! it duplicates the same scoped walk `SpatialIndexSystem`/`AiSystem` use
//! (`scope_dense_indices` + `movementBodyDenseIndex(entity) orelse continue`,
//! identical skip, identical order) to build a `candidates` side table
//! (entity/faction/level) aligned 1:1 with `spatial`'s own row order, and
//! records each observer row's position in *that* full-population walk as
//! `spatial_self_index` — the value actually passed to `queryNeighbors`.
//! `perception_dense_index` is the unrelated, separate index: the entity's
//! own row in `PerceptionStore`, used only to write results back.
//! `std.debug.assert(self.candidates.len == spatial.pos_x.len)` is the
//! population-domain guard (Debug/ReleaseSafe only, mirrors `ai.zig`).
//!
//! Sign convention: `SpatialIndexView.queryNeighbors` hands its visitor
//! `dx/dy = origin - candidate`. This system negates that once, at the single
//! choke point inside `perceptionNeighborVisit`, into `to_x/to_y = candidate -
//! observer` ("vector toward the candidate") before buffering — every
//! downstream consumer (FOV dot product, LOS endpoint, last-seen position,
//! and the player-candidate merge, which is built the same way) reads that
//! one convention with no further sign flips.
//!
//! FOV test stays in squared form (no sqrt/normalize/divide): `facing_x/y` is
//! already unit-length (derived once per step by `computeFacingDense`, a
//! dense SIMD pass over the gathered rows' velocity columns — see its doc
//! comment), so `dot(facing, to) > 0 AND dot(facing, to)^2 > cos_half_fov^2 *
//! dist_squared` is equivalent to a true angle compare given `cos_half_fov >=
//! 0`, which `AiPerception`'s `fov_half_angle_radians <= pi/2` cap guarantees
//! (see `data_system/perception.zig`). A wider-than-90-degree cone (needing a
//! sign-split) is explicitly out of scope for this slice.
//!
//! Scalar exceptions (each documented again at its call site): the spatial
//! cell-scan traversal and stance lookup (Slice 28 shared infra; branchy and a
//! 4-value enum table index, not float math), the small (<= 17) per-agent
//! nearest-candidate sort (irreducibly small/branchy, does not scale with
//! population), and the bounded LOS raycast (early-exit grid/DDA walk, one
//! scattered cell lookup per visited cell). The per-cell blocked test itself
//! is an O(1) read into `LevelBlockedSlot`'s per-level bitmap cache
//! (`level_blocked`, brought current for a distinct observer level at most
//! once per step by
//! `ensureLevelBlockedCachesForObservers`/`ensureLevelBlockedCache` — a skip,
//! a scoped patch, or a full rebuild, whichever `reactToPostCommitPerceptionEvents`'s
//! dirty tracking says is cheapest, see `LevelBlockedSlot`'s doc comment), not
//! `WorldSystem.levelBlocksMovement`'s own per-call linear scan over the
//! world's sparse tiles — see `LevelBlockedSlot`'s doc comment for why this is
//! a bespoke cache rather than a reuse of `pathfinding/nav_grid.zig`'s
//! `NavGrid`, and `src/benchmarks/perception.zig`'s `perception`/
//! `perception-los-dense` groups for the before/after cost proof.
//!
//! Threaded writes: each worker range writes only its own gather rows' hot
//! columns in `PerceptionStore` (disjoint per entity, since gather rows are
//! 1:1 with entities and ranges partition row indices) and appends events
//! only into its own reserved, exactly-sized event scratch buffer
//! (`range_len * 2` — an identity-swap transition emits at most two events per
//! row, so this can never overflow, unlike collision's broadphase estimate).
//! Serial and threaded paths share every vectorized helper
//! (`computeFacingDense`, `filterFovSurvivors`, the transition `equalInt4`
//! pass) and the same per-range compute function
//! (`computePerceptionRange`) — see the serial/threaded parity test.

const std = @import("std");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const stance = @import("../faction.zig").stance;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchSelection = @import("../../app/thread_system.zig").BatchSelection;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;
const rangeCount = @import("../../app/thread_system.zig").rangeCount;
const ConstAiAgentSlice = @import("../data_system.zig").ConstAiAgentSlice;
const ConstMovementBodySlice = @import("../data_system.zig").ConstMovementBodySlice;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const Faction = @import("../data_system.zig").Faction;
const PerceptionSlice = @import("../data_system.zig").PerceptionSlice;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const WorldSystem = @import("../world_system.zig").WorldSystem;
const SimulationEvent = @import("../simulation.zig").SimulationEvent;
const SimulationEvents = @import("../simulation.zig").SimulationEvents;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const WorldStimulus = @import("../simulation.zig").WorldStimulus;
const spatial_index_mod = @import("spatial_index.zig");
const SpatialIndexView = spatial_index_mod.SpatialIndexView;
const NeighborVisitResult = spatial_index_mod.NeighborVisitResult;

pub const perception_range_alignment_items: usize = movement_range_alignment_items;

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, perception_range_alignment_items);
}

// Mirrors ai.zig's max_separation_neighbors/max_separation_candidate_checks
// shape: a small fixed candidate buffer bounded by a scan-cost ceiling.
const max_perception_candidates: u8 = 16;
// Runtime perf logging (perception_candidate_checks) measured ~32 candidate
// visits/observer on average in a populated demo, ~94% rejected by the
// stance filter (mostly same-faction, e.g. cohere-clustered) before ever
// reaching sensed_count -- the query pays their dx/dy/dist2 cost regardless
// of rejection. 64 (mirrors ai.zig's max_cohere_candidate_checks, half of
// max_separation_candidate_checks) keeps ~2x headroom over the observed
// average while bounding the worst case a dense same-faction cluster can
// force onto one observer's query, instead of leaving it at 128 (~4x
// headroom) with no measured need for that much slack.
const max_perception_candidate_checks: u16 = 64;
const max_perception_scratch: usize = max_perception_candidates + 1; // + player

// "Moving" gate for facing derivation: 1.0 units/sec, compared against
// speed-squared so the dense pass never needs a sqrt to decide.
const facing_speed_squared_threshold: f32 = 1.0;
const facing_normalize_epsilon: f32 = 1.0e-6;

// Defensive ceiling on LOS raycast visited-cell count (the DDA grid walk in
// `hasLineOfSight` visits one cell per loop iteration, not one interpolated
// sample). AiPerception.vision_range is itself capped
// (max_ai_perception_vision_range) which already keeps the worst-case
// Manhattan cell count small (at most ~26 cells for a maximally diagonal
// 512-unit ray over 32-unit tiles); this is a second, independent bound with
// headroom above that. Reaching this cap mid-traversal fails closed (treats
// the rest of the ray as blocked) the same way an out-of-bounds cell does —
// unreachable under any valid `AiPerception` config, only a fallback for a
// pathological one.
const los_max_cells: u32 = 64;

const player_candidate_sentinel: usize = std.math.maxInt(usize);

const default_max_events_per_step: usize = 512;

const invalid_index_bits: i32 = @bitCast(EntityId.invalid.index);
const invalid_generation_bits: i32 = @bitCast(EntityId.invalid.generation);

pub const PlayerPerceptionCandidate = struct {
    entity: EntityId,
    pos_x: f32,
    pos_y: f32,
    faction: Faction,
    level: u16,
};

pub const PerceptionConfig = struct {
    /// When non-null, only these dense ai-store indices participate this step
    /// (the scope system's cognition halo + stagger selection). Null = all
    /// agents. Mirrors `AiConfig.scope_dense_indices`/
    /// `SpatialIndexConfig.scope_dense_indices` exactly (population-domain
    /// contract — see the module doc).
    scope_dense_indices: ?[]const u32 = null,
    /// Optional player entity, resolved by the caller once per step (null if
    /// no player entity exists yet).
    player_candidate: ?PlayerPerceptionCandidate = null,
    /// This step's merged world stimuli (`frame.stimuli.mergedItems()`), read
    /// by the hearing pass folded into `computeOneAgent`.
    stimuli: []const WorldStimulus = &.{},
    /// Deterministic per-step cap on emitted perception events, enforced by
    /// this system itself (see the module doc's threaded-writes note and
    /// `mergePerceptionEvents`) rather than letting `SimulationEvents`'s own
    /// capacity check throw.
    max_events_per_step: usize = default_max_events_per_step,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
};

pub const PerceptionStats = struct {
    observer_count: usize = 0,
    candidate_population_count: usize = 0,
    // FOV-surviving hostile candidates summed across every observer this step
    // (post range/FOV gate, pre-LOS) — a selectivity signal for how much the
    // spatial-index + FOV filter narrows the candidate population before the
    // LOS raycast has to run at all.
    sensed_count: usize = 0,
    // Observers whose `target_visible` resolved true this step (LOS actually
    // confirmed a nearest threat), summed across every range.
    nearest_threat_found_count: usize = 0,
    // `hasLineOfSight` call count and how many of those returned blocked,
    // summed across every range — see the per-range accumulation note on
    // `PerceptionRangeStats`. `hasLineOfSight` visits are O(1) lookups into
    // `PerceptionSystem.level_blocked`'s per-level bitmap cache (see that
    // struct's doc comment), not raw `WorldSystem.levelBlocksMovement` calls,
    // so these counters exist to make the LOS visited-cell volume visible to
    // `src/benchmarks/perception.zig` rather than let it hide inside aggregate
    // step timing.
    los_checks: usize = 0,
    los_blocked: usize = 0,
    // Total spatial-index candidates visited across every observer this step,
    // hostile-stance or not (mirrors `ai_separation_candidate_checks`) —
    // isolates the query's own traversal cost from `sensed_count`'s
    // post-FOV-filter selectivity signal, so a locally dense same-faction
    // cluster that gets visited-then-rejected by the stance check is visible
    // here even though it never reaches `sensed_count`.
    candidate_checks: usize = 0,
    perceived_events: usize = 0,
    lost_events: usize = 0,
    dropped_events: usize = 0,
    batch: BatchStats = .{},
};

// Per-range accumulator for the LOS/sensed/found counters above. Each range
// job owns one slot (indexed by `range.index`, mirrors `event_ranges`), writes
// to a local `PerceptionRangeStats` value throughout its own
// `computeOneAgent` calls, and stores it once at the end of
// `computePerceptionRange` — a single write per range, so no atomics are
// needed (unlike the event scratch buffers, nothing appends concurrently
// into a range's slot). It is 32 bytes (4 `usize` fields), so two adjacent
// slots would otherwise share one 64-byte cache line; concurrently running
// worker ranges writing their final stats into adjacent slots would then
// false-share that line, so `PerceptionRangeStatsSlot` pads it the same way
// `PerceptionEventRangeSlot` pads `PerceptionEventRangeBuffer` below.
const PerceptionRangeStats = struct {
    sensed_count: usize = 0,
    nearest_threat_found: usize = 0,
    los_checks: usize = 0,
    los_blocked: usize = 0,
    // Total spatial-index candidates visited across every observer this range
    // processed, hostile-stance or not (mirrors `ai_separation_candidate_checks`
    // in `ai.zig`) -- distinct from `sensed_count` (post-FOV survivors): this
    // counts the query's own traversal cost before any stance/FOV filtering,
    // so a locally dense same-faction cluster (e.g. cohere-formed) that gets
    // visited-then-rejected shows up here even though it never reaches
    // `sensed_count`.
    candidate_checks: usize = 0,
};

const CandidateRow = struct {
    entity: EntityId,
    faction: Faction,
    level: u16,
};

fn appendCandidateRow(
    rows: *std.MultiArrayList(CandidateRow),
    row_slice: *std.MultiArrayList(CandidateRow).Slice,
    row: CandidateRow,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

const PerceptionGatherRow = struct {
    entity: EntityId,
    pos_x: f32,
    pos_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    vision_range: f32,
    cos_half_fov: f32,
    hearing_range: f32,
    faction: Faction,
    level: u16,
    // Row index in the FULL scoped population walk (same order as
    // SpatialIndexSystem/AiSystem's own gather) — passed to
    // `queryNeighbors` as `self_index`. See the module doc's
    // two-index-space contract.
    spatial_self_index: usize,
    // This entity's own row in `PerceptionStore` — used only to write
    // results back, unrelated to `spatial_self_index`.
    perception_dense_index: usize,
    facing_x: f32,
    facing_y: f32,
    prev_nearest_threat_index: i32,
    prev_nearest_threat_generation: i32,
    final_nearest_threat_index: i32,
    final_nearest_threat_generation: i32,
};

fn appendPerceptionGatherRow(
    rows: *std.MultiArrayList(PerceptionGatherRow),
    row_slice: *std.MultiArrayList(PerceptionGatherRow).Slice,
    row: PerceptionGatherRow,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

const ConstCandidateSlice = struct {
    entities: []const EntityId,
    faction: []const Faction,
    level: []const u16,
};

const thread_shared_record_alignment: usize = 64;

const PerceptionEventRangeBuffer = struct {
    events: std.ArrayList(SimulationEvent) = .empty,

    fn clearRetainingCapacity(self: *PerceptionEventRangeBuffer) void {
        self.events.clearRetainingCapacity();
    }

    fn appendAssumeCapacity(self: *PerceptionEventRangeBuffer, event: SimulationEvent) void {
        self.events.appendAssumeCapacity(event);
    }

    fn deinit(self: *PerceptionEventRangeBuffer, allocator: std.mem.Allocator) void {
        self.events.deinit(allocator);
        self.* = undefined;
    }
};

const PerceptionEventRangeSlot = struct {
    // Each worker writes only its assigned slot. Padding keeps hot append
    // state off shared cache lines across concurrently written range records.
    buffer: PerceptionEventRangeBuffer = .{},
    padding: [paddingForCacheLine(PerceptionEventRangeBuffer)]u8 = [_]u8{0} ** paddingForCacheLine(PerceptionEventRangeBuffer),
};

const PerceptionEventRangeSlotList = std.ArrayListAligned(PerceptionEventRangeSlot, .fromByteUnits(thread_shared_record_alignment));

const PerceptionRangeStatsSlot = struct {
    // Each worker writes only its assigned slot, once, at the end of its
    // range (see `PerceptionRangeStats`'s doc comment). Padding keeps that
    // write off shared cache lines across concurrently running ranges.
    stats: PerceptionRangeStats = .{},
    padding: [paddingForCacheLine(PerceptionRangeStats)]u8 = [_]u8{0} ** paddingForCacheLine(PerceptionRangeStats),
};

const PerceptionRangeStatsSlotList = std.ArrayListAligned(PerceptionRangeStatsSlot, .fromByteUnits(thread_shared_record_alignment));

fn paddingForCacheLine(comptime T: type) usize {
    const rem = @sizeOf(T) % thread_shared_record_alignment;
    return if (rem == 0) 0 else thread_shared_record_alignment - rem;
}

fn rangeLenForIndex(item_count: usize, items_per_range: usize, range_index: usize) usize {
    const start = range_index * items_per_range;
    if (start >= item_count) return 0;
    return @min(start + items_per_range, item_count) - start;
}

fn serialBatch(count: usize) BatchStats {
    return .{ .ran_inline = true, .item_count = count, .range_count = if (count > 0) 1 else 0, .items_per_range = count };
}

// Sentinel meaning "never built" so a fresh slot (default-initialized, step 0
// never having run yet) always misses the `built_step == step_counter` check
// below and gets populated the first time its level is touched.
const invalid_build_step: u64 = std.math.maxInt(u64);

// A pending edit to one level's blocked bitmap, awaiting the next
// `ensureLevelBlockedCache` call that actually touches that level (see
// `LevelBlockedSlot.pending_dirty`). Cell-rect shape mirrors
// `WorldObstacleChangedEvent` (min inclusive, max exclusive) rather than
// `pathfinding/nav_grid.zig`'s `NavCellEdit`/chunk-grid dirty model — this
// cache works in raw world tiles, not nav cells/chunks, and reusing that
// type would couple this file to nav's chunk-grid shape for no benefit (the
// chunk grid is only consulted transiently, at patch time, to scope the
// sparse-tile rescan — see `PerceptionSystem.patchLevelBlockedCache`).
const DirtyRect = struct {
    min_x: u16,
    min_y: u16,
    max_x_exclusive: u16,
    max_y_exclusive: u16,
};

// Above this fraction of a level's total cell count, accumulated dirty area
// makes the scoped patch path (a memset + rescan per pending rect, plus a
// chunk-scoped sparse walk per rect) costlier than one dense full pass over
// the whole level, so `ensureLevelBlockedCache` falls back to a full rebuild
// instead — same spirit as `pathfinding/nav_graph.zig`'s
// `full_relabel_level_threshold` (there: a count of affected *levels*; here:
// a fraction of one level's *cells*, the finer unit this cache works in).
// `pending_dirty`'s rects are summed without deduplicating overlap, so this
// is a conservative (over-)estimate of actual dirty coverage — cheap to
// compute and safe to fall back early on.
const full_rebuild_dirty_area_numerator: u64 = 1;
const full_rebuild_dirty_area_denominator: u64 = 4; // 25%

fn dirtyAreaExceedsFullRebuildThreshold(pending_dirty: []const DirtyRect, cell_count: usize) bool {
    var area: u64 = 0;
    for (pending_dirty) |rect| {
        const width = if (rect.max_x_exclusive > rect.min_x) rect.max_x_exclusive - rect.min_x else 0;
        const height = if (rect.max_y_exclusive > rect.min_y) rect.max_y_exclusive - rect.min_y else 0;
        area += @as(u64, width) * @as(u64, height);
    }
    return area * full_rebuild_dirty_area_denominator > @as(u64, cell_count) * full_rebuild_dirty_area_numerator;
}

// One level's O(1) LOS-blocked lookup cache: a raw world-tile-granularity
// bitmap (`blocked[y * width + x]`), kept current for a distinct level at
// most once per step (see `PerceptionSystem.ensureLevelBlockedCache`) via a
// skip (nothing changed), a scoped patch (a bounded set of edits since the
// last build), or a full rebuild (first build, or an invalid/never-built
// level, or accumulated dirty area over `full_rebuild_dirty_area_numerator`/
// `_denominator`). This exists solely to answer `hasLineOfSight`'s per-sample
// question in O(1) instead of `WorldSystem.levelBlocksMovement`'s per-call
// linear scan over every sparse tile in the world (see the module doc's
// LOS-cost note and `src/benchmarks/perception.zig`'s `perception`/
// `perception-los-dense` split that proved the cost). Deliberately NOT a
// reuse of `pathfinding/nav_grid.zig`'s `NavGrid`: that grid's blocked mask is
// world obstacles OR (level 0 only) DataSystem static collision bodies — a
// different, broader set than `levelBlocksMovement`'s world-tiles-only
// contract — and its `cell_size` is only incidentally equal to
// `WorldSystem.tile_size` (two independently-set literals, not an enforced
// invariant), so reusing it would risk both a silent LOS-granularity change
// and a silent LOS-occlusion behavior change. This cache instead mirrors
// `NavGrid.markWorldObstacles`'s shape (dense-band scan + sparse-filtered-to-
// level pass) but stays at raw world-tile granularity with no rect
// rasterization, so it is a direct, provable stand-in for
// `levelBlocksMovement` — see the parity test.
const LevelBlockedSlot = struct {
    // `invalid_build_step` until the first build that finds `valid == true`;
    // thereafter the `PerceptionSystem.step_counter` value as of the last
    // build/patch. A rebuild attempt that finds the level still out of range
    // leaves this at `invalid_build_step` (see `ensureLevelBlockedCache`'s
    // self-healing note), so a level queried before it exists retries a full
    // rebuild every time it is touched until the level is actually added,
    // instead of staying stuck fail-closed forever. A step-counter mismatch
    // (a new step ran since) revisits the slot the next time its level is
    // touched — see `pending_dirty` for what that revisit actually does
    // (skip/patch/rebuild), which is no longer "always rebuild" the way a
    // bare step-counter mismatch alone would imply.
    built_step: u64 = invalid_build_step,
    // False for a level index that did not exist in `WorldSystem` at build
    // time (`level_index >= world.levelCount()`), matching
    // `levelBlocksMovement`'s fail-closed contract for an invalid level:
    // `lookupLevelBlocked` returns blocked immediately without ever reading
    // `blocked`.
    valid: bool = false,
    width: u16 = 0,
    height: u16 = 0,
    blocked: std.ArrayList(bool) = .empty,
    // Edits recorded by `PerceptionSystem.reactToPostCommitPerceptionEvents`
    // since this slot was last built/patched, awaiting the next
    // `ensureLevelBlockedCache` call that actually touches this level. Unlike
    // `PathfindingSystem.nav_dirty_edits` (drained once per step regardless of
    // whether nav ran that step), this can persist across MULTIPLE untouched
    // steps: a level with no observer this step is never asked to rebuild, so
    // edits on it simply accumulate until an observer next looks at it. Grows
    // rather than drops on append (same must-not-silently-lose-an-edit
    // contract as `nav_dirty_edits`) so a burst of edits between two observer
    // visits is never forgotten; cleared only after a build/patch actually
    // consumes it.
    pending_dirty: std.ArrayList(DirtyRect) = .empty,

    fn deinit(self: *LevelBlockedSlot, allocator: std.mem.Allocator) void {
        self.pending_dirty.deinit(allocator);
        self.blocked.deinit(allocator);
        self.* = undefined;
    }
};

// O(1) lookup mirroring `WorldSystem.levelBlocksMovement`'s exact external
// contract: an out-of-range level index or out-of-bounds x/y is fail-closed
// (blocked); everything else is the cached bit. `level_blocked` is a
// `PerceptionSystem.level_blocked` snapshot (main-thread-built, worker-read
// only) indexed directly by level.
fn lookupLevelBlocked(level_blocked: []const LevelBlockedSlot, level: u16, x: u16, y: u16) bool {
    if (@as(usize, level) >= level_blocked.len) return true;
    const slot = &level_blocked[level];
    if (!slot.valid) return true;
    if (x >= slot.width or y >= slot.height) return true;
    return slot.blocked.items[@as(usize, y) * @as(usize, slot.width) + @as(usize, x)];
}

pub const PerceptionSystem = struct {
    allocator: std.mem.Allocator,
    // Gathered work memory (main-thread only; workers read only copies in
    // job context, except their own reserved event scratch range).
    candidates: std.MultiArrayList(CandidateRow) = .{},
    rows: std.MultiArrayList(PerceptionGatherRow) = .{},
    event_ranges: PerceptionEventRangeSlotList = .empty,
    range_stats: PerceptionRangeStatsSlotList = .empty,
    range_take_counts: std.ArrayList(usize) = .empty,
    compute_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // Per-level LOS-blocked bitmap cache, indexed directly by level (see
    // `LevelBlockedSlot`). Sized/reused across steps (never deinit between
    // steps) — only the per-level `blocked` bitmap contents are refreshed,
    // at most once per distinct level actually touched by an observer this
    // step, via `ensureLevelBlockedCache`.
    level_blocked: std.ArrayList(LevelBlockedSlot) = .empty,
    // Monotonic step marker: incremented once per `update`/`updateSerial`
    // call that has at least one observer (a zero-observer step returns
    // early and does not increment it). A level's cached bitmap is reused
    // for every LOS sample within the same step; the first time a level is
    // touched in a LATER step, `ensureLevelBlockedCache` sees the step-counter
    // mismatch and decides what to do with the slot's `pending_dirty` list —
    // skip (empty: nothing changed since the last build/patch), a scoped
    // patch (a bounded set of edits), or a full rebuild (first build, or
    // dirty area over the full-rebuild threshold). A step-counter mismatch by
    // itself no longer implies "stale, must fully rescan" — only
    // `pending_dirty` being non-empty does.
    step_counter: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) PerceptionSystem {
        return .{
            .allocator = allocator,
            .compute_tuner = AdaptiveWorkTuner.init(.{}),
        };
    }

    pub fn deinit(self: *PerceptionSystem) void {
        for (self.level_blocked.items) |*slot| slot.deinit(self.allocator);
        self.level_blocked.deinit(self.allocator);
        self.range_take_counts.deinit(self.allocator);
        self.range_stats.deinit(self.allocator);
        for (self.event_ranges.items) |*slot| slot.buffer.deinit(self.allocator);
        self.event_ranges.deinit(self.allocator);
        self.rows.deinit(self.allocator);
        self.candidates.deinit(self.allocator);
        self.* = undefined;
    }

    /// Eagerly builds every existing level's `level_blocked` cache once, at
    /// world/state load time (mirrors `PathfindingSystem`'s one-time static
    /// nav-grid build — same "pay it once at an accepted init cost" shape,
    /// called from the same `SimulationPipeline.init` call site). Without
    /// this, each level's first-ever full rebuild happens lazily, triggered
    /// by whichever fixed step first has an observer on that level —
    /// scattered across the live session instead of paid once up front, and
    /// with no bound on how many distinct never-touched levels an unlucky
    /// step's observer set could span at once. Safe to call with zero
    /// levels (no-op) or to call again later (subsequent per-level calls are
    /// the normal cheap "nothing changed" reuse path, not a second rebuild).
    pub fn prebuildLevelCaches(self: *PerceptionSystem, world: *const WorldSystem) !void {
        var level: usize = 0;
        while (level < world.levelCount()) : (level += 1) {
            try self.ensureLevelBlockedCache(world, @intCast(level));
        }
    }

    pub fn update(
        self: *PerceptionSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        spatial: SpatialIndexView,
        world: *const WorldSystem,
        data: *DataSystem,
        events: *SimulationEvents,
        thread_system: *ThreadSystem,
        config: PerceptionConfig,
    ) !PerceptionStats {
        const perception_slice = data.perceptionSlice();
        try self.gatherPerceptionData(ai_agents, movement, data, perception_slice, config.scope_dense_indices);
        const observer_count = self.rows.len;
        if (observer_count == 0) return .{ .candidate_population_count = self.candidates.len };

        // Population-domain contract with spatial_index.zig (see module doc):
        // the shared index built for this step must have gathered the
        // identical row count as this system's own full-population candidate
        // walk. Debug/ReleaseSafe-only guard, compiles out in ReleaseFast.
        std.debug.assert(self.candidates.len == spatial.pos_x.len);

        self.computeFacingDense(perception_slice);
        try self.ensureLevelBlockedCachesForObservers(world);

        const active_tuner: ?*AdaptiveWorkTuner = config.adaptive_tuner orelse
            if (config.adaptive and config.items_per_range == null) &self.compute_tuner else null;
        const selection = selectStageWork(
            thread_system,
            observer_count,
            config.items_per_range,
            config.max_worker_threads,
            config.adaptive,
            active_tuner,
        );
        try self.prepareEventRangeBuffers(selection.range_count, selection.items_per_range, observer_count);
        try self.prepareRangeStats(selection.range_count);

        var job = self.buildJobContext(perception_slice, spatial, world, config.player_candidate, config.stimuli, selection.range_count);
        const batch = thread_system.parallelForWithOptions(observer_count, &job, writePerceptionRangeJob, .{
            .max_worker_threads = selection.worker_threads,
            .range_alignment_items = perception_range_alignment_items,
            .adaptive_tuner = selection.active_tuner,
            .selected_profile = selection.profile,
        });

        const merge = try self.mergePerceptionEvents(events, selection.range_count, config.max_events_per_step);
        const totals = self.sumRangeStats(selection.range_count);
        return .{
            .observer_count = observer_count,
            .candidate_population_count = self.candidates.len,
            .sensed_count = totals.sensed_count,
            .nearest_threat_found_count = totals.nearest_threat_found,
            .los_checks = totals.los_checks,
            .los_blocked = totals.los_blocked,
            .candidate_checks = totals.candidate_checks,
            .perceived_events = merge.perceived,
            .lost_events = merge.lost,
            .dropped_events = merge.dropped,
            .batch = batch,
        };
    }

    pub fn updateSerial(
        self: *PerceptionSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        spatial: SpatialIndexView,
        world: *const WorldSystem,
        data: *DataSystem,
        events: *SimulationEvents,
        config: PerceptionConfig,
    ) !PerceptionStats {
        const perception_slice = data.perceptionSlice();
        try self.gatherPerceptionData(ai_agents, movement, data, perception_slice, config.scope_dense_indices);
        const observer_count = self.rows.len;
        if (observer_count == 0) return .{ .candidate_population_count = self.candidates.len };

        std.debug.assert(self.candidates.len == spatial.pos_x.len);

        self.computeFacingDense(perception_slice);
        try self.ensureLevelBlockedCachesForObservers(world);

        const range_count: usize = 1;
        try self.prepareEventRangeBuffers(range_count, observer_count, observer_count);
        try self.prepareRangeStats(range_count);

        var job = self.buildJobContext(perception_slice, spatial, world, config.player_candidate, config.stimuli, range_count);
        computePerceptionRange(&job, .{ .index = 0, .start = 0, .end = observer_count });

        const merge = try self.mergePerceptionEvents(events, range_count, config.max_events_per_step);
        const totals = self.sumRangeStats(range_count);
        return .{
            .observer_count = observer_count,
            .candidate_population_count = self.candidates.len,
            .sensed_count = totals.sensed_count,
            .nearest_threat_found_count = totals.nearest_threat_found,
            .los_checks = totals.los_checks,
            .los_blocked = totals.los_blocked,
            .candidate_checks = totals.candidate_checks,
            .perceived_events = merge.perceived,
            .lost_events = merge.lost,
            .dropped_events = merge.dropped,
            .batch = serialBatch(observer_count),
        };
    }

    fn buildJobContext(
        self: *PerceptionSystem,
        perception_slice: PerceptionSlice,
        spatial: SpatialIndexView,
        world: *const WorldSystem,
        player_candidate: ?PlayerPerceptionCandidate,
        stimuli: []const WorldStimulus,
        range_count: usize,
    ) PerceptionJobContext {
        const candidate_slice = self.candidates.slice();
        const rows = self.rows.slice();
        return .{
            .entities = rows.items(.entity),
            .pos_x = rows.items(.pos_x),
            .pos_y = rows.items(.pos_y),
            .vision_range = rows.items(.vision_range),
            .cos_half_fov = rows.items(.cos_half_fov),
            .hearing_range = rows.items(.hearing_range),
            .stimuli = stimuli,
            .faction = rows.items(.faction),
            .level = rows.items(.level),
            .spatial_self_index = rows.items(.spatial_self_index),
            .perception_dense_index = rows.items(.perception_dense_index),
            .facing_x = rows.items(.facing_x),
            .facing_y = rows.items(.facing_y),
            .prev_nearest_threat_index = rows.items(.prev_nearest_threat_index),
            .prev_nearest_threat_generation = rows.items(.prev_nearest_threat_generation),
            .final_nearest_threat_index = rows.items(.final_nearest_threat_index),
            .final_nearest_threat_generation = rows.items(.final_nearest_threat_generation),
            .candidates = .{
                .entities = candidate_slice.items(.entity),
                .faction = candidate_slice.items(.faction),
                .level = candidate_slice.items(.level),
            },
            .perception_slice = perception_slice,
            .spatial = spatial,
            .world = world,
            .level_blocked = self.level_blocked.items,
            .player_candidate = player_candidate,
            .event_ranges = self.event_ranges.items[0..range_count],
            .range_stats = self.range_stats.items[0..range_count],
        };
    }

    // Builds (or, if already current for this step, reuses) every distinct
    // observer level's `LevelBlockedSlot` bitmap, once, on the main thread,
    // before any range job is dispatched — workers only ever read the
    // completed `level_blocked` snapshot handed to them via
    // `PerceptionJobContext`. Walking every gathered row's level (rather than
    // building a separate deduped level list) needs no extra allocation:
    // `ensureLevelBlockedCache` itself is an O(1) no-op for a level already
    // current this step, so revisiting the same level across many rows costs
    // nothing beyond the index read.
    fn ensureLevelBlockedCachesForObservers(self: *PerceptionSystem, world: *const WorldSystem) !void {
        self.step_counter +%= 1;
        const levels = self.rows.items(.level);
        for (levels) |level| try self.ensureLevelBlockedCache(world, level);
    }

    // Grows `level_blocked` on demand up to `level + 1` slots (never shrinks,
    // never drops an already-built slot), returning the slot for `level`.
    // Shared by `ensureLevelBlockedCache` (which then reads/writes the slot's
    // bitmap) and `reactToPostCommitPerceptionEvents` (which only ever
    // appends to `pending_dirty`) so a level touched only by a dirty-marking
    // event before its first observer visit still gets a slot to record
    // against.
    fn levelBlockedSlot(self: *PerceptionSystem, level: u16) !*LevelBlockedSlot {
        if (@as(usize, level) >= self.level_blocked.items.len) {
            const new_len = @as(usize, level) + 1;
            try self.level_blocked.ensureTotalCapacity(self.allocator, new_len);
            while (self.level_blocked.items.len < new_len) self.level_blocked.appendAssumeCapacity(.{});
        }
        return &self.level_blocked.items[level];
    }

    // Brings one level's LOS-blocked bitmap current for this step: a no-op
    // when the slot is already built for the current `step_counter`;
    // otherwise a skip (nothing changed since the last build/patch — the
    // headline case this incremental design exists for, see the module doc),
    // a scoped patch (`patchLevelBlockedCache`), or a full rebuild
    // (`rebuildLevelBlockedCache`) — first build, or accumulated dirty area
    // over the full-rebuild threshold. Any stale `pending_dirty` recorded
    // before a level's first-ever build is discarded rather than patched
    // against: the full rebuild below already reflects the current world
    // state directly, so replaying pre-first-build edits on top would be
    // redundant at best.
    //
    // Self-healing for a level queried before `WorldSystem.addLevel` created
    // it: a rebuild that finds the level still out of range leaves
    // `slot.valid == false` AND leaves `built_step` unstamped (still
    // `invalid_build_step`), so the next call for this level still sees
    // `first_build == true` and retries a full rebuild rather than being
    // stuck fail-closed forever once the level actually exists.
    fn ensureLevelBlockedCache(self: *PerceptionSystem, world: *const WorldSystem, level: u16) !void {
        const slot = try self.levelBlockedSlot(level);
        if (slot.built_step == self.step_counter) return;

        const first_build = slot.built_step == invalid_build_step;
        const cell_count = @as(usize, world.width) * @as(usize, world.height);
        if (first_build) {
            try self.rebuildLevelBlockedCache(world, level, slot, cell_count);
        } else if (slot.pending_dirty.items.len == 0) {
            // Nothing changed since the last build/patch: reuse it as-is.
        } else if (dirtyAreaExceedsFullRebuildThreshold(slot.pending_dirty.items, cell_count)) {
            try self.rebuildLevelBlockedCache(world, level, slot, cell_count);
        } else {
            patchLevelBlockedCache(world, level, slot);
        }

        slot.pending_dirty.clearRetainingCapacity();
        if (!slot.valid) return;
        slot.built_step = self.step_counter;
    }

    // Rebuilds one level's LOS-blocked bitmap from `world`'s dense bands and
    // sparse obstacles, mirroring `nav_grid.zig`'s `markWorldObstacles` shape
    // (uniform-fill fast path, then a per-dense-layer cell scan, then a
    // sparse-tile pass scoped to this level via `sparseTileIndicesForLevel` —
    // O(sparse tiles on this level), not O(sparse tiles in the whole world))
    // but at raw world-tile granularity — no nav-cell rect rasterization — so
    // the result is a direct, provable stand-in for
    // `WorldSystem.levelBlocksMovement` (see `LevelBlockedSlot`'s doc comment
    // and the parity test). `blocked`'s backing storage is grown once and
    // reused across steps (never deinit/re-init between steps); only its
    // contents are refreshed. Caller (`ensureLevelBlockedCache`) clears
    // `pending_dirty` afterward and stamps `built_step` only if the level
    // turned out valid (see that function's self-healing note).
    fn rebuildLevelBlockedCache(self: *PerceptionSystem, world: *const WorldSystem, level: u16, slot: *LevelBlockedSlot, cell_count: usize) !void {
        try slot.blocked.ensureTotalCapacity(self.allocator, cell_count);
        slot.blocked.items.len = cell_count;
        slot.width = world.width;
        slot.height = world.height;
        @memset(slot.blocked.items, false);

        // Fail-closed contract for an invalid level index (mirrors
        // levelBlocksMovement's own first check): leave the bitmap all-false
        // but mark the slot invalid, so `lookupLevelBlocked` returns blocked
        // without ever reading `blocked`'s (unpopulated) contents.
        slot.valid = @as(usize, level) < world.levelCount();
        if (!slot.valid) return;

        for (0..world.denseLayerCount()) |layer_index| {
            if (world.denseLayerLevel(layer_index) != level) continue;
            if (world.denseLayerUniformFillTile(layer_index) != null) {
                if (world.denseTileBlocksMovement(layer_index, 0, 0)) @memset(slot.blocked.items, true);
                continue;
            }
            for (0..world.height) |y_usize| {
                const y: u16 = @intCast(y_usize);
                for (0..world.width) |x_usize| {
                    const x: u16 = @intCast(x_usize);
                    if (!world.denseTileBlocksMovement(layer_index, x, y)) continue;
                    slot.blocked.items[y_usize * world.width + x_usize] = true;
                }
            }
        }
        for (world.sparseTileIndicesForLevel(level)) |sparse_index| {
            if (!world.sparseTileBlocksMovement(sparse_index)) continue;
            const cell = world.sparseTileCellCoord(sparse_index);
            slot.blocked.items[@as(usize, cell.y) * @as(usize, world.width) + @as(usize, cell.x)] = true;
        }
    }

    // Records one committed structural event's blocked-cache impact for the
    // next `ensureLevelBlockedCache` call on its level: this system's own
    // narrower sibling of `PathfindingSystem.reactToPostCommitNavEvents`.
    // Only `.world_tile_changed` (a single-cell rect, and only when the
    // movement-blocking flag actually flipped) and `.world_obstacle_changed`
    // (the event's own already-multi-cell rect) are localizable to this
    // cache's world-tiles-only contract (see the module doc); every other
    // structural event (entity/component changes, which this cache never
    // reads) is irrelevant and ignored. Unlike nav's `eventInvalidatesNavigation`,
    // there is no non-localizable whole-level fallback case here. Purely
    // internal bookkeeping: nothing currently reacts to "perception's cache
    // changed," so this emits no event of its own — simpler than nav's
    // reaction, which does emit `nav_region_invalidated`.
    pub fn reactToPostCommitPerceptionEvents(self: *PerceptionSystem, frame: *SimulationFrame, world: *const WorldSystem) !void {
        for (frame.events.mergedItems()) |event| {
            if (event.stage != .structural_commit) continue;
            switch (event.payload) {
                .world_tile_changed => |changed| {
                    if (changed.old_blocks_movement == changed.new_blocks_movement) continue;
                    if (changed.level >= world.levelCount()) continue;
                    try self.markLevelDirty(changed.level, .{
                        .min_x = changed.x,
                        .min_y = changed.y,
                        .max_x_exclusive = changed.x +| 1,
                        .max_y_exclusive = changed.y +| 1,
                    });
                },
                .world_obstacle_changed => |changed| {
                    if (changed.level >= world.levelCount()) continue;
                    try self.markLevelDirty(changed.level, .{
                        .min_x = changed.min_x,
                        .min_y = changed.min_y,
                        .max_x_exclusive = changed.max_x_exclusive,
                        .max_y_exclusive = changed.max_y_exclusive,
                    });
                },
                else => {},
            }
        }
    }

    fn markLevelDirty(self: *PerceptionSystem, level: u16, rect: DirtyRect) !void {
        const slot = try self.levelBlockedSlot(level);
        try slot.pending_dirty.ensureTotalCapacity(self.allocator, slot.pending_dirty.items.len + 1);
        slot.pending_dirty.appendAssumeCapacity(rect);
    }

    // Population-domain contract with spatial_index.zig/ai.zig (see module
    // doc): walks `scope_dense_indices` (or all ai agents) resolving
    // `data.movementBodyDenseIndex(entity) orelse continue`, in the exact
    // same order SpatialIndexSystem/AiSystem's own gathers do — a deliberate
    // duplicate gather, not shared code, so `candidates` row `i` and
    // `spatial`'s row `i` refer to the same agent. This walk does double
    // duty: every surviving entity (regardless of AiPerception) becomes a
    // `candidates` row (so the neighbor-visit callback can resolve
    // faction/level/entity from a spatial row index); entities that also
    // carry `AiPerception` additionally become an observer `rows` entry,
    // capturing `spatial_self_index` (this walk's row count so far) and
    // `perception_dense_index` (the unrelated `PerceptionStore` row).
    fn gatherPerceptionData(
        self: *PerceptionSystem,
        ai_agents: ConstAiAgentSlice,
        movement: ConstMovementBodySlice,
        data: *const DataSystem,
        perception_slice: PerceptionSlice,
        scope_dense_indices: ?[]const u32,
    ) !void {
        self.clearWork();
        const n = if (scope_dense_indices) |idx| idx.len else ai_agents.entities.len;
        if (n == 0) return;
        try self.candidates.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(n));

        var candidate_slice = self.candidates.slice();
        var row_slice = self.rows.slice();
        var k: usize = 0;
        var spatial_row_index: usize = 0;
        while (k < n) : (k += 1) {
            const i: usize = if (scope_dense_indices) |idx| idx[k] else k;
            const ent = ai_agents.entities[i];
            const mi = data.movementBodyDenseIndex(ent) orelse continue;

            const ent_faction = data.factionConst(ent) orelse .neutral;
            const ent_level = data.worldLevelConst(ent) orelse 0;
            appendCandidateRow(&self.candidates, &candidate_slice, .{
                .entity = ent,
                .faction = ent_faction,
                .level = ent_level,
            });

            if (data.aiPerceptionDenseIndex(ent)) |perception_index| {
                const prev_nearest = perception_slice.nearest_threat[perception_index];
                appendPerceptionGatherRow(&self.rows, &row_slice, .{
                    .entity = ent,
                    .pos_x = movement.previous_x[mi],
                    .pos_y = movement.previous_y[mi],
                    .velocity_x = movement.velocity_x[mi],
                    .velocity_y = movement.velocity_y[mi],
                    .vision_range = perception_slice.vision_range[perception_index],
                    .cos_half_fov = perception_slice.cos_half_fov[perception_index],
                    .hearing_range = perception_slice.hearing_range[perception_index],
                    .faction = ent_faction,
                    .level = ent_level,
                    .spatial_self_index = spatial_row_index,
                    .perception_dense_index = perception_index,
                    .facing_x = perception_slice.facing_x[perception_index],
                    .facing_y = perception_slice.facing_y[perception_index],
                    .prev_nearest_threat_index = @bitCast(prev_nearest.index),
                    .prev_nearest_threat_generation = @bitCast(prev_nearest.generation),
                    .final_nearest_threat_index = invalid_index_bits,
                    .final_nearest_threat_generation = invalid_generation_bits,
                });
            }

            spatial_row_index += 1;
        }
    }

    fn clearWork(self: *PerceptionSystem) void {
        self.candidates.clearRetainingCapacity();
        self.rows.clearRetainingCapacity();
    }

    /// Derives every gathered row's unit facing vector from its previous-step
    /// velocity, run once (main thread, before the compute dispatch) over the
    /// full contiguous `rows` set — same shape as spatial_index.zig's
    /// `assignCellsDense`: a dense batch pass after the scattered/branchy
    /// gather, shared verbatim by both `update` and `updateSerial` so
    /// threaded/serial facing is identical by construction (nothing left to
    /// parity-test between them). Near-stationary agents (speed^2 at or below
    /// `facing_speed_squared_threshold`) hold their previous stored facing
    /// rather than snapping to a noisy near-zero velocity direction. Facing is
    /// scattered back into `PerceptionStore` here too (`perception_dense_index`
    /// is scattered/non-contiguous, so that final step stays a scalar loop).
    fn computeFacingDense(self: *PerceptionSystem, perception_slice: PerceptionSlice) void {
        const rows = self.rows.slice();
        const n = rows.len;
        const velocity_x = rows.items(.velocity_x);
        const velocity_y = rows.items(.velocity_y);
        const facing_x = rows.items(.facing_x);
        const facing_y = rows.items(.facing_y);
        const perception_dense_index = rows.items(.perception_dense_index);

        var i: usize = 0;
        const vend = simd.vectorizedEnd(n);
        const threshold = simd.splatFloat4(facing_speed_squared_threshold);
        while (i < vend) : (i += simd.lane_count) {
            const vx = simd.loadFloat4(velocity_x[i..]);
            const vy = simd.loadFloat4(velocity_y[i..]);
            const prev_fx = simd.loadFloat4(facing_x[i..]);
            const prev_fy = simd.loadFloat4(facing_y[i..]);
            const speed2 = simd.lengthSquared2Float4(vx, vy);
            const moving = simd.greaterThanFloat4(speed2, threshold);
            const normalized = simd.normalizeOrZero2Float4(vx, vy, facing_normalize_epsilon);
            const result_x = simd.selectFloat4(moving, normalized.x, prev_fx);
            const result_y = simd.selectFloat4(moving, normalized.y, prev_fy);
            simd.storeFloat4Slice(facing_x[i..], result_x);
            simd.storeFloat4Slice(facing_y[i..], result_y);
        }
        while (i < n) : (i += 1) {
            const result = computeFacingScalar(velocity_x[i], velocity_y[i], .{ .x = facing_x[i], .y = facing_y[i] });
            facing_x[i] = result.x;
            facing_y[i] = result.y;
        }

        for (0..n) |row_index| {
            const dense = perception_dense_index[row_index];
            perception_slice.facing_x[dense] = facing_x[row_index];
            perception_slice.facing_y[dense] = facing_y[row_index];
        }
    }

    fn prepareEventRangeBuffers(self: *PerceptionSystem, range_count: usize, items_per_range: usize, item_count: usize) !void {
        try self.event_ranges.ensureTotalCapacity(self.allocator, range_count);
        while (self.event_ranges.items.len < range_count) self.event_ranges.appendAssumeCapacity(.{});
        for (self.event_ranges.items[0..range_count], 0..) |*slot, range_index| {
            slot.buffer.clearRetainingCapacity();
            const range_len = rangeLenForIndex(item_count, items_per_range, range_index);
            // Worst case: an identity swap emits two events for one row, so
            // this exact reserve can never overflow (unlike collision's
            // broadphase pair estimate) — no grow-and-replay dance needed.
            try slot.buffer.events.ensureTotalCapacity(self.allocator, range_len * 2);
        }
    }

    // Sizes/resets `range_stats` to `range_count` slots before dispatch (same
    // reserve-before-dispatch shape as `prepareEventRangeBuffers`), so every
    // range job has a pre-existing slot to write its single accumulated
    // `PerceptionRangeStats` value into.
    fn prepareRangeStats(self: *PerceptionSystem, range_count: usize) !void {
        try self.range_stats.ensureTotalCapacity(self.allocator, range_count);
        while (self.range_stats.items.len < range_count) self.range_stats.appendAssumeCapacity(.{});
        for (self.range_stats.items[0..range_count]) |*slot| slot.stats = .{};
    }

    fn sumRangeStats(self: *const PerceptionSystem, range_count: usize) PerceptionRangeStats {
        var totals = PerceptionRangeStats{};
        for (self.range_stats.items[0..range_count]) |slot| {
            totals.sensed_count += slot.stats.sensed_count;
            totals.nearest_threat_found += slot.stats.nearest_threat_found;
            totals.los_checks += slot.stats.los_checks;
            totals.los_blocked += slot.stats.los_blocked;
            totals.candidate_checks += slot.stats.candidate_checks;
        }
        return totals;
    }

    /// Serial merge after the parallel/serial compute pass: sums each range's
    /// real (not worst-case) event count, applies this system's own
    /// deterministic per-step cap in range-ascending, within-range-write-order
    /// (truncating the tail rather than letting `SimulationEvents`'s own
    /// capacity check throw — see the module doc), then re-walks each range's
    /// scratch into `events`'s shared range-output stream.
    fn mergePerceptionEvents(
        self: *PerceptionSystem,
        events: *SimulationEvents,
        range_count: usize,
        max_events_per_step: usize,
    ) !PerceptionEventMergeResult {
        try self.range_take_counts.ensureTotalCapacity(self.allocator, range_count);
        self.range_take_counts.clearRetainingCapacity();

        var total: usize = 0;
        for (self.event_ranges.items[0..range_count]) |*slot| total += slot.buffer.events.items.len;
        const capped_total = @min(total, max_events_per_step);
        const dropped = total - capped_total;

        var remaining = capped_total;
        for (self.event_ranges.items[0..range_count]) |*slot| {
            const take = @min(slot.buffer.events.items.len, remaining);
            self.range_take_counts.appendAssumeCapacity(take);
            remaining -= take;
        }

        const first_range = try events.appendRangeCounts(range_count);
        for (self.range_take_counts.items, 0..) |take, range_index| {
            events.addCount(first_range + range_index, take);
        }
        try events.prefixAppendedRanges(first_range);

        var perceived: usize = 0;
        var lost: usize = 0;
        for (self.event_ranges.items[0..range_count], self.range_take_counts.items, 0..) |*slot, take, range_index| {
            var writer = events.rangeWriter(first_range + range_index);
            for (slot.buffer.events.items[0..take]) |event| {
                writer.write(event);
                switch (event.payload) {
                    .entity_perceived => perceived += 1,
                    .entity_lost => lost += 1,
                    else => {},
                }
            }
            writer.finish();
        }
        events.finishWrite();
        events.stats.dropped += dropped;

        return .{ .perceived = perceived, .lost = lost, .dropped = dropped };
    }
};

const PerceptionEventMergeResult = struct {
    perceived: usize,
    lost: usize,
    dropped: usize,
};

fn clampRectToLevel(rect: DirtyRect, width: u16, height: u16) DirtyRect {
    return .{
        .min_x = @min(rect.min_x, width),
        .min_y = @min(rect.min_y, height),
        .max_x_exclusive = @min(rect.max_x_exclusive, width),
        .max_y_exclusive = @min(rect.max_y_exclusive, height),
    };
}

const ChunkRange = struct { min_x: u16, min_y: u16, max_x: u16, max_y: u16 };

// The level-local chunk range a (clamped) rect overlaps, clamped to
// `[0, chunks_x - 1] x [0, chunks_y - 1]` — mirrors
// `WorldSystem.localChunkIndexForCell`'s per-cell chunk math, computed once
// for the whole rect instead of per cell. Callers combine `min_y..max_y` and
// `min_x..max_x` with `chunks_x` the same way `localChunkIndexForCell` does
// (`chunk_y * chunks_x + chunk_x`) to reach `sparseTileIndicesForChunk`.
fn chunkRangeForRect(rect: DirtyRect, chunk_size_tiles: u16, chunks_x: u16, chunks_y: u16) ChunkRange {
    const chunk_size = @max(chunk_size_tiles, 1);
    const max_chunk_x = if (chunks_x == 0) 0 else chunks_x - 1;
    const max_chunk_y = if (chunks_y == 0) 0 else chunks_y - 1;
    const max_x_inclusive_cell: u16 = if (rect.max_x_exclusive == 0) 0 else rect.max_x_exclusive - 1;
    const max_y_inclusive_cell: u16 = if (rect.max_y_exclusive == 0) 0 else rect.max_y_exclusive - 1;
    return .{
        .min_x = @min(rect.min_x / chunk_size, max_chunk_x),
        .min_y = @min(rect.min_y / chunk_size, max_chunk_y),
        .max_x = @min(max_x_inclusive_cell / chunk_size, max_chunk_x),
        .max_y = @min(max_y_inclusive_cell / chunk_size, max_chunk_y),
    };
}

// Patches only the cells covered by `slot.pending_dirty`, in place, instead of
// rescanning the whole level (see `LevelBlockedSlot`'s doc comment and
// `ensureLevelBlockedCache`'s decision tree). A bit can flip either direction
// (a dig can unblock a cell, not just block one), so each rect's cell range is
// `@memset` false first, then rescanned: per relevant dense layer, bounded to
// the rect instead of the whole level; and per sparse tile, but only within
// the rect's overlapping level-local chunks (`WorldSystem.sparseTileIndicesForChunk`
// via `chunkRangeForRect`) rather than every sparse tile on the level — the
// candidate set is bounded by chunk population, not level population, which
// is the real complexity-class win on the sparse side. Takes no allocator and
// grows nothing: `slot.blocked`'s backing storage is already sized to
// `slot.width * slot.height` by an earlier full build (a slot only reaches
// this function post-first-build — see `ensureLevelBlockedCache`), and
// `slot.width`/`height` cannot have changed since (levels never resize after
// creation). An invalid slot (fail-closed, `blocked` never populated) has
// nothing to patch and is left as-is.
fn patchLevelBlockedCache(world: *const WorldSystem, level: u16, slot: *LevelBlockedSlot) void {
    if (!slot.valid) return;
    const chunks_x = world.chunksX();
    const chunks_y = world.chunksY();

    for (slot.pending_dirty.items) |raw_rect| {
        const rect = clampRectToLevel(raw_rect, slot.width, slot.height);
        if (rect.min_x >= rect.max_x_exclusive or rect.min_y >= rect.max_y_exclusive) continue;

        var y = rect.min_y;
        while (y < rect.max_y_exclusive) : (y += 1) {
            const row_offset = @as(usize, y) * @as(usize, slot.width);
            @memset(slot.blocked.items[row_offset + rect.min_x .. row_offset + rect.max_x_exclusive], false);
        }

        for (0..world.denseLayerCount()) |layer_index| {
            if (world.denseLayerLevel(layer_index) != level) continue;
            if (world.denseLayerUniformFillTile(layer_index) != null) {
                if (!world.denseTileBlocksMovement(layer_index, 0, 0)) continue;
                var yy = rect.min_y;
                while (yy < rect.max_y_exclusive) : (yy += 1) {
                    const row_offset = @as(usize, yy) * @as(usize, slot.width);
                    @memset(slot.blocked.items[row_offset + rect.min_x .. row_offset + rect.max_x_exclusive], true);
                }
                continue;
            }
            var yy = rect.min_y;
            while (yy < rect.max_y_exclusive) : (yy += 1) {
                var xx = rect.min_x;
                while (xx < rect.max_x_exclusive) : (xx += 1) {
                    if (!world.denseTileBlocksMovement(layer_index, xx, yy)) continue;
                    slot.blocked.items[@as(usize, yy) * @as(usize, slot.width) + @as(usize, xx)] = true;
                }
            }
        }

        const chunk_range = chunkRangeForRect(rect, world.chunk_size_tiles, chunks_x, chunks_y);
        var cy = chunk_range.min_y;
        while (cy <= chunk_range.max_y) : (cy += 1) {
            var cx = chunk_range.min_x;
            while (cx <= chunk_range.max_x) : (cx += 1) {
                const local_chunk_index: u32 = @as(u32, cy) * @as(u32, chunks_x) + @as(u32, cx);
                for (world.sparseTileIndicesForChunk(level, local_chunk_index)) |sparse_index| {
                    if (!world.sparseTileBlocksMovement(sparse_index)) continue;
                    const cell = world.sparseTileCellCoord(sparse_index);
                    if (cell.x < rect.min_x or cell.x >= rect.max_x_exclusive) continue;
                    if (cell.y < rect.min_y or cell.y >= rect.max_y_exclusive) continue;
                    slot.blocked.items[@as(usize, cell.y) * @as(usize, slot.width) + @as(usize, cell.x)] = true;
                }
            }
        }
    }
}

fn computeFacingScalar(vx: f32, vy: f32, prev_facing: math.Vec2) math.Vec2 {
    const speed2 = vx * vx + vy * vy;
    if (speed2 <= facing_speed_squared_threshold) return prev_facing;
    return math.normalizeOrZero(.{ .x = vx, .y = vy }, facing_normalize_epsilon);
}

const PerceptionJobContext = struct {
    entities: []const EntityId,
    pos_x: []const f32,
    pos_y: []const f32,
    vision_range: []const f32,
    cos_half_fov: []const f32,
    hearing_range: []const f32,
    stimuli: []const WorldStimulus,
    faction: []const Faction,
    level: []const u16,
    spatial_self_index: []const usize,
    perception_dense_index: []const usize,
    facing_x: []const f32,
    facing_y: []const f32,
    prev_nearest_threat_index: []const i32,
    prev_nearest_threat_generation: []const i32,
    final_nearest_threat_index: []i32,
    final_nearest_threat_generation: []i32,

    candidates: ConstCandidateSlice,

    perception_slice: PerceptionSlice,
    spatial: SpatialIndexView,
    world: *const WorldSystem,
    // O(1) LOS-blocked lookup cache, main-thread-built before dispatch (see
    // `PerceptionSystem.ensureLevelBlockedCachesForObservers`), read-only for
    // every worker range.
    level_blocked: []const LevelBlockedSlot,
    player_candidate: ?PlayerPerceptionCandidate,
    event_ranges: []PerceptionEventRangeSlot,
    range_stats: []PerceptionRangeStatsSlot,
};

fn writePerceptionRangeJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PerceptionJobContext = @ptrCast(@alignCast(context));
    // Guards the reserve-before-dispatch invariant: prepareEventRangeBuffers
    // must have sized event_ranges to at least this dispatch's range count.
    std.debug.assert(range.index < job.event_ranges.len);
    computePerceptionRange(job, range);
}

/// Shared per-range compute: scalar per-agent neighbor query/FOV/LOS/writeback
/// (`computeOneAgent`), then the dense transition-detection + scalar emit
/// pass (`emitTransitionsForRange`). Called identically by the threaded
/// dispatch and the serial single-range path — see the module doc's
/// serial/threaded parity note.
fn computePerceptionRange(job: *PerceptionJobContext, range: ParallelRange) void {
    // Local accumulator, not a pointer into job.range_stats: only one write
    // (below) ever lands per range, so concurrently running ranges never
    // touch each other's slot mid-accumulation.
    var range_stats = PerceptionRangeStats{};
    for (range.start..range.end) |i| computeOneAgent(job, i, &range_stats);
    emitTransitionsForRange(job, range);
    job.range_stats[range.index].stats = range_stats;
}

const CandidateScratch = struct {
    candidate_index: [max_perception_scratch]usize = undefined,
    to_x: [max_perception_scratch]f32 = undefined,
    to_y: [max_perception_scratch]f32 = undefined,
    dist2: [max_perception_scratch]f32 = undefined,
    count: usize = 0,

    fn append(self: *CandidateScratch, index: usize, to_x: f32, to_y: f32, dist2: f32) void {
        self.candidate_index[self.count] = index;
        self.to_x[self.count] = to_x;
        self.to_y[self.count] = to_y;
        self.dist2[self.count] = dist2;
        self.count += 1;
    }
};

const NeighborVisitContext = struct {
    observer_faction: Faction,
    candidate_faction: []const Faction,
    scratch: *CandidateScratch,
};

/// Scalar: the spatial cell-scan traversal itself (Slice 28 shared infra) and
/// the stance lookup (a 4-value enum table index, not float math) are both
/// branchy/sparse, not dense uniform work, so this callback stays scalar —
/// same shape as ai.zig's `separationNeighborVisit`. Negates
/// `queryNeighbors`'s `origin - candidate` into `candidate - observer` once,
/// here, before buffering (see the module doc's sign-convention note).
fn perceptionNeighborVisit(context: *anyopaque, candidate_index: usize, dx: f32, dy: f32, dist2: f32) NeighborVisitResult {
    const ctx: *NeighborVisitContext = @ptrCast(@alignCast(context));
    if (stance(ctx.observer_faction, ctx.candidate_faction[candidate_index]) != .hostile) return .keep_going;
    ctx.scratch.append(candidate_index, -dx, -dy, dist2);
    if (ctx.scratch.count >= max_perception_candidates) return .stop;
    return .keep_going;
}

/// Dense SIMD FOV filter (pack-then-vectorize over the already-packed
/// `scratch` arrays, per simd.zig's `gatherFloat4` doc comment), with a
/// scalar tail for the `< lane_count` remainder. `facing` is unit-length
/// (from `computeFacingDense`), so `dot(facing, to) > 0 AND dot^2 >
/// cos_half_fov^2 * dist2` is a sqrt/normalize/divide-free angle compare —
/// see the module doc for why the sign sits this way and why squaring is
/// valid here (`cos_half_fov >= 0` always).
fn filterFovSurvivors(
    scratch: *const CandidateScratch,
    facing_x: f32,
    facing_y: f32,
    cos_half_fov: f32,
    survivors: *[max_perception_scratch]usize,
) usize {
    var survivor_count: usize = 0;
    const facing_x_vec = simd.splatFloat4(facing_x);
    const facing_y_vec = simd.splatFloat4(facing_y);
    const cos2_vec = simd.splatFloat4(cos_half_fov * cos_half_fov);
    const zero = simd.splatFloat4(0);

    var i: usize = 0;
    const n = scratch.count;
    const vend = simd.vectorizedEnd(n);
    while (i < vend) : (i += simd.lane_count) {
        const to_x = simd.loadFloat4(scratch.to_x[i..]);
        const to_y = simd.loadFloat4(scratch.to_y[i..]);
        const dist2 = simd.loadFloat4(scratch.dist2[i..]);
        const dot = simd.dotFloat4(facing_x_vec, facing_y_vec, to_x, to_y);
        const positive = simd.greaterThanFloat4(dot, zero);
        const within_cone = simd.greaterThanFloat4(simd.mulFloat4(dot, dot), simd.mulFloat4(cos2_vec, dist2));
        const passed = positive & within_cone;
        inline for (0..simd.lane_count) |lane| {
            if (passed[lane]) {
                survivors[survivor_count] = i + lane;
                survivor_count += 1;
            }
        }
    }
    while (i < n) : (i += 1) {
        if (fovTestScalar(facing_x, facing_y, scratch.to_x[i], scratch.to_y[i], scratch.dist2[i], cos_half_fov)) {
            survivors[survivor_count] = i;
            survivor_count += 1;
        }
    }
    return survivor_count;
}

fn fovTestScalar(facing_x: f32, facing_y: f32, to_x: f32, to_y: f32, dist2: f32, cos_half_fov: f32) bool {
    const dot = facing_x * to_x + facing_y * to_y;
    if (dot <= 0) return false;
    return dot * dot > (cos_half_fov * cos_half_fov) * dist2;
}

const ResolvedCandidate = struct {
    entity: EntityId,
    level: u16,
};

const SurvivorSortContext = struct {
    scratch: *const CandidateScratch,
    candidates: ConstCandidateSlice,
    player_candidate: ?PlayerPerceptionCandidate,
};

fn resolveCandidate(ctx: SurvivorSortContext, slot: usize) ResolvedCandidate {
    const candidate_index = ctx.scratch.candidate_index[slot];
    if (candidate_index == player_candidate_sentinel) {
        const player = ctx.player_candidate.?;
        return .{ .entity = player.entity, .level = player.level };
    }
    return .{ .entity = ctx.candidates.entities[candidate_index], .level = ctx.candidates.level[candidate_index] };
}

// Small (<= max_perception_scratch), branchy comparator resolving an entity
// per compare: irreducibly small and does not scale with population, so this
// sort stays scalar (per-agent candidate counts are bounded by
// max_perception_candidates regardless of world size).
fn survivorLessThan(ctx: SurvivorSortContext, lhs: usize, rhs: usize) bool {
    const lhs_dist2 = ctx.scratch.dist2[lhs];
    const rhs_dist2 = ctx.scratch.dist2[rhs];
    if (lhs_dist2 != rhs_dist2) return lhs_dist2 < rhs_dist2;
    return resolveCandidate(ctx, lhs).entity.index < resolveCandidate(ctx, rhs).entity.index;
}

/// Bounded LOS raycast: an Amanatides-Woo grid/DDA walk from the observer's
/// cell to the target's cell, with an early exit on the first blocked cell
/// visited. Unlike fixed-step linear-interpolation sampling, this visits
/// every grid cell the segment's interior actually crosses — a diagonal ray
/// can no longer straddle a blocking cell's interior between two samples
/// without either one landing inside it (see the module doc's LOS test for
/// the reproduction this replaces). Each visited cell is a branchy, scattered
/// lookup (not dense/uniform), so the walk itself stays scalar; the per-cell
/// blocked test is still `lookupLevelBlocked`'s O(1) bitmap read (see
/// `LevelBlockedSlot`), not a `WorldSystem.levelBlocksMovement` call.
fn hasLineOfSight(world: *const WorldSystem, level_blocked: []const LevelBlockedSlot, level: u16, ox: f32, oy: f32, tx: f32, ty: f32) bool {
    const dx = tx - ox;
    const dy = ty - oy;
    if (dx == 0 and dy == 0) return true;

    const tile_size = world.tile_size;
    const start_cell = world.cellContaining(ox, oy) orelse return false;
    const end_cell = world.cellContaining(tx, ty) orelse return false;

    // The observer's own starting cell is never checked (mirrors the old
    // sampler, which never evaluated t == 0): a straight segment that starts
    // and ends in the same cell never leaves it, so only the shared cell
    // itself needs a blocked check.
    if (start_cell.x == end_cell.x and start_cell.y == end_cell.y) {
        return !lookupLevelBlocked(level_blocked, level, end_cell.x, end_cell.y);
    }

    var cell_x: i32 = start_cell.x;
    var cell_y: i32 = start_cell.y;
    const end_x: i32 = end_cell.x;
    const end_y: i32 = end_cell.y;
    const world_width: i32 = world.width;
    const world_height: i32 = world.height;

    const step_x: i32 = if (dx > 0) 1 else if (dx < 0) -1 else 0;
    const step_y: i32 = if (dy > 0) 1 else if (dy < 0) -1 else 0;

    // t_max_* is the distance (in the segment's own [0,1] parameterization)
    // to the next vertical/horizontal grid line; t_delta_* is that same unit
    // distance between consecutive grid lines on that axis. An axis the
    // segment never crosses (step == 0) is pinned at +inf so the `<`
    // comparison below always advances the other axis.
    var t_max_x = std.math.inf(f32);
    var t_delta_x = std.math.inf(f32);
    if (step_x != 0) {
        const next_cell_x = if (step_x > 0) cell_x + 1 else cell_x;
        const boundary_x = @as(f32, @floatFromInt(next_cell_x)) * tile_size;
        t_max_x = (boundary_x - ox) / dx;
        t_delta_x = tile_size / @abs(dx);
    }

    var t_max_y = std.math.inf(f32);
    var t_delta_y = std.math.inf(f32);
    if (step_y != 0) {
        const next_cell_y = if (step_y > 0) cell_y + 1 else cell_y;
        const boundary_y = @as(f32, @floatFromInt(next_cell_y)) * tile_size;
        t_max_y = (boundary_y - oy) / dy;
        t_delta_y = tile_size / @abs(dy);
    }

    var visited: u32 = 0;
    while (visited < los_max_cells) : (visited += 1) {
        if (t_max_x < t_max_y) {
            cell_x += step_x;
            t_max_x += t_delta_x;
        } else {
            cell_y += step_y;
            t_max_y += t_delta_y;
        }
        if (cell_x < 0 or cell_y < 0 or cell_x >= world_width or cell_y >= world_height) return false;
        const cx: u16 = @intCast(cell_x);
        const cy: u16 = @intCast(cell_y);
        if (lookupLevelBlocked(level_blocked, level, cx, cy)) return false;
        if (cell_x == end_x and cell_y == end_y) return true;
    }
    return false;
}

fn computeOneAgent(job: *PerceptionJobContext, i: usize, range_stats: *PerceptionRangeStats) void {
    const ox = job.pos_x[i];
    const oy = job.pos_y[i];
    const vision_range = job.vision_range[i];
    const cos_half_fov = job.cos_half_fov[i];
    const observer_faction = job.faction[i];
    const observer_level = job.level[i];
    const self_index = job.spatial_self_index[i];
    const facing_x = job.facing_x[i];
    const facing_y = job.facing_y[i];

    var scratch = CandidateScratch{};
    var visit_ctx = NeighborVisitContext{
        .observer_faction = observer_faction,
        .candidate_faction = job.candidates.faction,
        .scratch = &scratch,
    };
    const scan_radius = spatial_index_mod.cellScanRadius(vision_range, job.spatial.cell_size);
    const query_stats = job.spatial.queryNeighbors(
        ox,
        oy,
        self_index,
        scan_radius,
        .{ .radius = vision_range, .max_candidate_checks = max_perception_candidate_checks },
        &visit_ctx,
        perceptionNeighborVisit,
    );
    range_stats.candidate_checks += query_stats.candidate_checks;

    if (job.player_candidate) |player| {
        if (stance(observer_faction, player.faction) == .hostile) {
            const to_x = player.pos_x - ox;
            const to_y = player.pos_y - oy;
            const dist2 = to_x * to_x + to_y * to_y;
            if (dist2 < vision_range * vision_range) {
                scratch.append(player_candidate_sentinel, to_x, to_y, dist2);
            }
        }
    }

    var survivors: [max_perception_scratch]usize = undefined;
    const survivor_count = filterFovSurvivors(&scratch, facing_x, facing_y, cos_half_fov, &survivors);

    const sort_ctx = SurvivorSortContext{
        .scratch = &scratch,
        .candidates = job.candidates,
        .player_candidate = job.player_candidate,
    };
    std.mem.sort(usize, survivors[0..survivor_count], sort_ctx, survivorLessThan);
    range_stats.sensed_count += survivor_count;

    var target_visible = false;
    var nearest_threat = EntityId.invalid;
    var nearest_threat_dist: f32 = std.math.inf(f32);
    var last_seen_x: f32 = 0;
    var last_seen_y: f32 = 0;

    // Small (<= max_perception_scratch), branchy walk with a per-candidate
    // bounded LOS raycast: irreducible, does not scale with population, so
    // this stays scalar.
    for (survivors[0..survivor_count]) |slot| {
        const resolved = resolveCandidate(sort_ctx, slot);
        if (resolved.level != observer_level) continue;
        const tx = ox + scratch.to_x[slot];
        const ty = oy + scratch.to_y[slot];
        range_stats.los_checks += 1;
        if (hasLineOfSight(job.world, job.level_blocked, observer_level, ox, oy, tx, ty)) {
            target_visible = true;
            nearest_threat = resolved.entity;
            nearest_threat_dist = math.length(.{ .x = scratch.to_x[slot], .y = scratch.to_y[slot] });
            last_seen_x = tx;
            last_seen_y = ty;
            break;
        }
        range_stats.los_blocked += 1;
    }
    if (target_visible) range_stats.nearest_threat_found += 1;

    const dense_index = job.perception_dense_index[i];
    job.perception_slice.target_visible[dense_index] = target_visible;
    job.perception_slice.nearest_threat[dense_index] = nearest_threat;
    // Actual distance (not squared): nearest_threat_dist is the directly
    // consumable magnitude a future steering/urgency consumer would want
    // without paying a second sqrt.
    job.perception_slice.nearest_threat_dist[dense_index] = nearest_threat_dist;
    if (target_visible) {
        job.perception_slice.last_seen_x[dense_index] = last_seen_x;
        job.perception_slice.last_seen_y[dense_index] = last_seen_y;
    }
    // last_seen_x/y are deliberately left unchanged when target_visible is
    // false, holding the last real sighting for a future memory slice.

    const hearing_range = job.hearing_range[i];
    const hearing_range_sq = hearing_range * hearing_range;
    var heard_stimulus = false;
    var heard_x: f32 = 0;
    var heard_y: f32 = 0;
    var best_dist2 = std.math.inf(f32);
    for (job.stimuli) |stim| {
        if (stim.level != observer_level) continue;
        const dist2 = math.lengthSquared(.{ .x = stim.position.x - ox, .y = stim.position.y - oy });
        if (dist2 <= hearing_range_sq and dist2 < best_dist2) {
            heard_stimulus = true;
            best_dist2 = dist2;
            heard_x = stim.position.x;
            heard_y = stim.position.y;
        }
    }
    job.perception_slice.heard_stimulus[dense_index] = heard_stimulus;
    job.perception_slice.heard_stimulus_x[dense_index] = heard_x;
    job.perception_slice.heard_stimulus_y[dense_index] = heard_y;

    job.final_nearest_threat_index[i] = @bitCast(nearest_threat.index);
    job.final_nearest_threat_generation[i] = @bitCast(nearest_threat.generation);
}

fn reconstructEntityId(index_bits: i32, generation_bits: i32) EntityId {
    return .{ .index = @bitCast(index_bits), .generation = @bitCast(generation_bits) };
}

/// Batches the prev-vs-final `EntityId` compare 4 rows at a time via
/// `simd.equalInt4` over the row's contiguous bitcast index/generation
/// columns, feeding a scalar per-row emit — same shape as collision.zig's
/// SIMD Y-overlap filter feeding scalar contact emission. Scalar tail for the
/// `< lane_count` remainder.
fn emitTransitionsForRange(job: *PerceptionJobContext, range: ParallelRange) void {
    const buffer = &job.event_ranges[range.index].buffer;
    var i = range.start;
    while (i + simd.lane_count <= range.end) : (i += simd.lane_count) {
        const prev_idx = simd.loadInt4(job.prev_nearest_threat_index[i..]);
        const prev_gen = simd.loadInt4(job.prev_nearest_threat_generation[i..]);
        const final_idx = simd.loadInt4(job.final_nearest_threat_index[i..]);
        const final_gen = simd.loadInt4(job.final_nearest_threat_generation[i..]);
        const idx_equal = simd.equalInt4(prev_idx, final_idx);
        const gen_equal = simd.equalInt4(prev_gen, final_gen);
        const unchanged = idx_equal & gen_equal;
        inline for (0..simd.lane_count) |lane| {
            if (!unchanged[lane]) {
                emitTransition(
                    buffer,
                    job.entities[i + lane],
                    reconstructEntityId(job.prev_nearest_threat_index[i + lane], job.prev_nearest_threat_generation[i + lane]),
                    reconstructEntityId(job.final_nearest_threat_index[i + lane], job.final_nearest_threat_generation[i + lane]),
                );
            }
        }
    }
    while (i < range.end) : (i += 1) {
        if (job.prev_nearest_threat_index[i] != job.final_nearest_threat_index[i] or
            job.prev_nearest_threat_generation[i] != job.final_nearest_threat_generation[i])
        {
            emitTransition(
                buffer,
                job.entities[i],
                reconstructEntityId(job.prev_nearest_threat_index[i], job.prev_nearest_threat_generation[i]),
                reconstructEntityId(job.final_nearest_threat_index[i], job.final_nearest_threat_generation[i]),
            );
        }
    }
}

/// Transition rules (see module doc): invalid->valid emits only
/// `entity_perceived`; valid->invalid emits only `entity_lost`; a
/// valid->different-valid identity swap emits both, `entity_lost` (the
/// previous target) before `entity_perceived` (the new one), in that order.
/// `prev`/`final` equal (including both invalid) never reaches here — the
/// caller's `unchanged` check already filtered that out.
fn emitTransition(buffer: *PerceptionEventRangeBuffer, observer: EntityId, prev: EntityId, final: EntityId) void {
    if (prev.isValid()) {
        buffer.appendAssumeCapacity(.{ .stage = .domain_reaction, .payload = .{ .entity_lost = .{ .observer = observer, .target = prev } } });
    }
    if (final.isValid()) {
        buffer.appendAssumeCapacity(.{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{ .observer = observer, .target = final } } });
    }
}

const StageWorkSelection = BatchSelection;

// Mirrors ai.zig/spatial_index.zig/collision.zig's selectStageWork verbatim
// (module-local adaptive-profile resolution), keyed by
// perception_range_alignment_items.
fn selectStageWork(
    thread_system: *const ThreadSystem,
    item_count: usize,
    items_per_range_override: ?usize,
    max_worker_threads_override: ?usize,
    adaptive: bool,
    adaptive_tuner: ?*AdaptiveWorkTuner,
) StageWorkSelection {
    // Shapes work through the single tuner-owned entry point so pre-sizing and
    // dispatch (parallelForWithOptions) resolve an identical batch shape.
    return thread_system.selectBatchProfile(adaptive_tuner, .{
        .item_count = item_count,
        .items_per_range = items_per_range_override,
        .max_worker_threads = max_worker_threads_override,
        .range_alignment_items = perception_range_alignment_items,
        .adaptive = adaptive,
    });
}

// ---- Tests --------------------------------------------------------------------

const testing = std.testing;
const AiPerception = @import("../data_system.zig").AiPerception;
const SpatialIndexSystem = spatial_index_mod.SpatialIndexSystem;

fn addAgent(
    data: *DataSystem,
    pos_x: f32,
    pos_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    faction: Faction,
) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = pos_x, .y = pos_y },
        .previous_position = .{ .x = pos_x, .y = pos_y },
        .velocity = .{ .x = velocity_x, .y = velocity_y },
        .speed = 40,
    });
    try data.setAiAgent(entity, .{ .active_behavior = .wander });
    try data.setFaction(entity, faction);
    return entity;
}

fn addObserver(
    data: *DataSystem,
    pos_x: f32,
    pos_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    faction: Faction,
    perception: AiPerception,
) !EntityId {
    const entity = try addAgent(data, pos_x, pos_y, velocity_x, velocity_y, faction);
    try data.setAiPerception(entity, perception);
    return entity;
}

fn testSpatialIndex(
    ai_slice: ConstAiAgentSlice,
    movement_slice: ConstMovementBodySlice,
    data: *const DataSystem,
) !SpatialIndexSystem {
    var sys = SpatialIndexSystem.init(testing.allocator);
    errdefer sys.deinit();
    try sys.reserve(ai_slice.entities.len, .{});
    _ = try sys.buildSerial(ai_slice, movement_slice, data, .{});
    return sys;
}

fn minimalWorld(allocator: std.mem.Allocator, width: u16, height: u16, tile_size: f32) !WorldSystem {
    var world = WorldSystem{
        .allocator = allocator,
        .width = width,
        .height = height,
        .tile_size = tile_size,
        .chunk_size_tiles = width,
    };
    _ = try world.addLevel(0);
    return world;
}

test "fovTestScalar accepts squarely ahead, boundary, and rejects squarely behind" {
    // 60-degree half-angle (cos(60) == 0.5), facing +x.
    const cos_half_fov: f32 = 0.5;
    // Squarely ahead: candidate directly along +x.
    try testing.expect(fovTestScalar(1, 0, 10, 0, 100, cos_half_fov));
    // Squarely behind: candidate directly along -x (dot <= 0, rejected before squaring).
    try testing.expect(!fovTestScalar(1, 0, -10, 0, 100, cos_half_fov));
    // Just inside the cone: angle slightly less than 60 degrees.
    const inside = math.rotate2D(.{ .x = 10, .y = 0 }, math.sinCos(std.math.pi / 3.0 - 0.05));
    try testing.expect(fovTestScalar(1, 0, inside.x, inside.y, inside.x * inside.x + inside.y * inside.y, cos_half_fov));
    // Just outside the cone: angle slightly more than 60 degrees.
    const outside = math.rotate2D(.{ .x = 10, .y = 0 }, math.sinCos(std.math.pi / 3.0 + 0.05));
    try testing.expect(!fovTestScalar(1, 0, outside.x, outside.y, outside.x * outside.x + outside.y * outside.y, cos_half_fov));
}

test "filterFovSurvivors matches fovTestScalar lane-for-lane across a packed scratch, including the scalar tail" {
    var scratch = CandidateScratch{};
    // 6 candidates (not a multiple of lane_count 4): exercises the vectorized
    // block (4) and the scalar tail (2) in the same run.
    const facing_x: f32 = 0.6;
    const facing_y: f32 = 0.8;
    const cos_half_fov: f32 = 0.5;
    const cases = [_][2]f32{ .{ 10, 10 }, .{ -5, -5 }, .{ 20, 1 }, .{ 1, 20 }, .{ -8, 3 }, .{ 6, -1 } };
    for (cases, 0..) |c, idx| {
        scratch.append(idx, c[0], c[1], c[0] * c[0] + c[1] * c[1]);
    }

    var survivors: [max_perception_scratch]usize = undefined;
    const survivor_count = filterFovSurvivors(&scratch, facing_x, facing_y, cos_half_fov, &survivors);

    var expected_count: usize = 0;
    for (0..scratch.count) |i| {
        const expect = fovTestScalar(facing_x, facing_y, scratch.to_x[i], scratch.to_y[i], scratch.dist2[i], cos_half_fov);
        const found = std.mem.indexOfScalar(usize, survivors[0..survivor_count], i) != null;
        try testing.expectEqual(expect, found);
        if (expect) expected_count += 1;
    }
    try testing.expectEqual(expected_count, survivor_count);
}

test "computeFacingDense matches computeFacingScalar lane-for-lane, including the scalar tail" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // 5 rows (not a multiple of lane_count 4): exercises the vectorized block
    // and the one-row scalar tail in the same run. Mix of moving and
    // near-stationary rows so both select branches are covered.
    const velocities = [_][2]f32{ .{ 50, 0 }, .{ 0, 0 }, .{ -30, 40 }, .{ 0.01, 0 }, .{ 0, -20 } };
    const prev_facings = [_][2]f32{ .{ 1, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 } };

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();

    var entities: [velocities.len]EntityId = undefined;
    for (velocities, 0..) |v, i| {
        entities[i] = try addObserver(&data, @floatFromInt(i * 10), 0, v[0], v[1], .neutral, .{});
    }

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    // Seed prev_facing via a direct perception-slice write (simulating a prior
    // step's output) before the dense pass runs.
    {
        var perception_slice = data.perceptionSlice();
        for (entities, 0..) |ent, i| {
            const dense = data.aiPerceptionDenseIndex(ent).?;
            perception_slice.facing_x[dense] = prev_facings[i][0];
            perception_slice.facing_y[dense] = prev_facings[i][1];
        }
    }

    var world = try minimalWorld(testing.allocator, 8, 8, 32);
    defer world.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    for (entities, velocities, prev_facings) |ent, v, prev| {
        const expected = computeFacingScalar(v[0], v[1], .{ .x = prev[0], .y = prev[1] });
        const perception = data.aiPerceptionConst(ent).?;
        try testing.expectEqual(expected.x, perception.facing_x);
        try testing.expectEqual(expected.y, perception.facing_y);
    }
}

test "gather uses the full-population spatial row index for self-exclusion, not the filtered observer row index" {
    // X and Z carry AiPerception (observers); Y sits between them in
    // scope_dense_indices but has no AiPerception, so it is a candidate only.
    // If the self_index passed to queryNeighbors were wrongly the filtered
    // observer-row index (1) instead of the true spatial row index (2) for Z,
    // Z's query would self-exclude Y instead of itself, and Y (hostile, right
    // next to Z) would never be found.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const x = try addObserver(&data, 0, 0, 0, 0, .player, .{});
    const y = try addAgent(&data, 1000, 1000, 0, 0, .hostile);
    // Z moves toward Y (-x direction) so computeFacingDense derives a facing
    // pointed at Y without needing to poke internal fields directly.
    const z = try addObserver(&data, 1010, 1000, -100, 0, .player, .{});

    const scope = [_]u32{ 0, 1, 2 };
    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .scope_dense_indices = &scope,
    });

    const z_perception = data.aiPerceptionConst(z).?;
    try testing.expect(z_perception.target_visible);
    try testing.expectEqual(y.index, z_perception.nearest_threat.index);

    // X is far from everyone (out of default vision_range) and unaffected.
    const x_perception = data.aiPerceptionConst(x).?;
    try testing.expect(!x_perception.target_visible);
}

test "candidate outside vision_range is never selected" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{ .vision_range = 50 });
    _ = try addAgent(&data, 200, 0, 0, 0, .hostile); // outside vision_range

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    try testing.expect(!data.aiPerceptionConst(observer).?.target_visible);
}

test "FOV gating: candidate outside the cone is not perceived, inside is" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    // Observer moves in +x, so facing settles to (1, 0).
    const observer = try addObserver(&data, 0, 0, 100, 0, .player, .{ .fov_half_angle_radians = std.math.pi / 4.0 });
    // Directly behind the observer: outside any <= 90 degree cone.
    _ = try addAgent(&data, -50, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expect(!data.aiPerceptionConst(observer).?.target_visible);

    // Now place a candidate directly ahead instead.
    var data2 = DataSystem.init(testing.allocator);
    defer data2.deinit();
    const observer2 = try addObserver(&data2, 0, 0, 100, 0, .player, .{ .fov_half_angle_radians = std.math.pi / 4.0 });
    _ = try addAgent(&data2, 50, 0, 0, 0, .hostile);

    var spatial_sys2 = try testSpatialIndex(data2.aiAgentSliceConst(), data2.movementBodySliceConst(), &data2);
    defer spatial_sys2.deinit();
    var sys2 = PerceptionSystem.init(testing.allocator);
    defer sys2.deinit();
    var events2 = SimulationEvents.init(testing.allocator);
    defer events2.deinit();
    _ = try sys2.updateSerial(data2.aiAgentSliceConst(), data2.movementBodySliceConst(), spatial_sys2.view(), &world, &data2, &events2, .{});
    try testing.expect(data2.aiPerceptionConst(observer2).?.target_visible);
}

test "stance gating: only hostile candidates ever become nearest_threat" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .neutral);
    _ = try addAgent(&data, 12, 0, 0, 0, .ally);
    const threat = try addAgent(&data, 14, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
    try testing.expectEqual(threat.index, perception.nearest_threat.index);
}

test "candidate_checks counts every visited candidate, not just hostile-stance survivors" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .neutral);
    _ = try addAgent(&data, 12, 0, 0, 0, .ally);
    _ = try addAgent(&data, 14, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    // All 3 candidates (neutral, ally, hostile) sit within the query's scan
    // radius and get visited -- candidate_checks must see all of them, even
    // though only the hostile one survives the stance filter into sensed_count.
    try testing.expect(stats.candidate_checks >= 3);
    try testing.expectEqual(@as(usize, 1), stats.sensed_count);

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
}

test "same-level gating skips cross-level candidates even when closest" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    const near_other_level = try addAgent(&data, 5, 0, 0, 0, .hostile);
    try data.setWorldLevel(near_other_level, 1);
    const far_same_level = try addAgent(&data, 40, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    // Level filtering happens before any LOS raycast, so `near_other_level`'s
    // (nonexistent) level 1 never needs a real world level to back it.
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
    try testing.expectEqual(far_same_level.index, perception.nearest_threat.index);
}

test "hearing detects an in-range same-level stimulus" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 30, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 }};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(!perception.target_visible);
    try testing.expect(perception.heard_stimulus);
    try testing.expectEqual(@as(f32, 30), perception.heard_stimulus_x);
    try testing.expectEqual(@as(f32, 0), perception.heard_stimulus_y);
}

test "hearing ignores an out-of-range stimulus" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 100, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 }};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    try testing.expect(!data.aiPerceptionConst(observer).?.heard_stimulus);
}

test "hearing ignores a stimulus on a different level" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 30, .y = 0 }, .intensity = 1, .kind = .dig, .level = 1 }};
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    try testing.expect(!data.aiPerceptionConst(observer).?.heard_stimulus);
}

test "hearing picks the nearest of multiple in-range stimuli" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 0, 0, .player, .{ .vision_range = 1, .hearing_range = 50 });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{
        .{ .position = .{ .x = 40, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 },
        .{ .position = .{ .x = 20, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 },
    };
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.heard_stimulus);
    try testing.expectEqual(@as(f32, 20), perception.heard_stimulus_x);
}

test "LOS gating skips a blocked nearer candidate in favor of a farther clear one" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    // Real asset-backed tileset (same pattern as
    // pathfinding/nav_grid.zig's own blocked-tile test): a synthetic tile id
    // has no catalog entry, so a real "blocks movement" tile needs the real
    // tileset metadata rather than a hand-poked WorldSystem.
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    // A large bounds keeps this test's small (cells 0..3) coordinate area away
    // from `initDemoFromMeta`'s own fixed demo obstacles (sparse "deco" props
    // placed at roughly width/4, height/3 and 3*width/4, 2*height/3), so the
    // only blocking tile in play is the one this test adds below.
    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    // Wall at cell (1, 0): blocks the straight path from the observer to the
    // nearer candidate but not the diagonal path to the farther one (the
    // diagonal ray drops into row 1 before it reaches column 1).
    _ = try world.setDenseTile(layer, 1, 0, tree);

    const tile_size = world.tile_size;
    const nearer_blocked = try addAgent(&data, tile_size * 2.5, tile_size * 0.5, 0, 0, .hostile);
    const farther_clear = try addAgent(&data, tile_size * 2.5, tile_size * 2.5, 0, 0, .hostile);
    const observer = try addObserver(&data, tile_size * 0.5, tile_size * 0.5, 1, 1, .player, .{
        .fov_half_angle_radians = std.math.pi / 2.0,
        .vision_range = tile_size * 10,
    });
    _ = nearer_blocked;

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
    try testing.expectEqual(farther_clear.index, perception.nearest_threat.index);
}

test "LOS blocks a diagonal ray through a mid-segment occluder's interior, not just its corners" {
    // Regression for a grid-traversal gap: a fixed-step interpolation sampler
    // can jump from one sampled point to the next diagonally without ever
    // landing inside a cell the *continuous* segment's interior actually
    // crosses. Observer (0.7, 0.3) -> target (2.5, 2.1) in tile units is a
    // 45-degree ray (dx == dy == 1.8), but the asymmetric fractional start
    // offsets (0.7 vs 0.3) keep it off the exact grid-corner diagonal, so it
    // has a genuine interior span through cell (2, 1) for roughly
    // t in [0.72, 0.94] -- not the measure-zero corner graze the sibling
    // "skips a blocked nearer candidate" test above exercises (that one is
    // corner-exact: dx == dy with a zero start offset). A correct grid/DDA
    // walk must still visit (2, 1) even though no fixed-step sample at
    // t = 1/3, 2/3, 1 ever lands there.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    // Large bounds keep this test's small (cells 0..2) coordinate area away
    // from `initDemoFromMeta`'s own fixed demo obstacles, same as the sibling
    // LOS test above.
    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    _ = try world.setDenseTile(layer, 2, 1, tree);

    const tile_size = world.tile_size;
    const target = try addAgent(&data, tile_size * 2.5, tile_size * 2.1, 0, 0, .hostile);
    _ = target;
    const observer = try addObserver(&data, tile_size * 0.7, tile_size * 0.3, 1, 1, .player, .{
        .fov_half_angle_radians = std.math.pi / 2.0,
        .vision_range = tile_size * 10,
    });

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(!perception.target_visible);
    try testing.expectEqual(EntityId.invalid.index, perception.nearest_threat.index);
}

test "LevelBlockedSlot cache lookup matches WorldSystem.levelBlocksMovement exactly: dense-blocked, sparse-blocked, open, out-of-range level, out-of-range cell" {
    // Real asset-backed tileset (same pattern as the LOS gating test above):
    // a synthetic tile id has no catalog entry, so a real "blocks movement"
    // tile needs the real tileset metadata rather than a hand-poked
    // WorldSystem.
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    // A large bounds keeps this test's small (cells 0..4) coordinate area
    // away from `initDemoFromMeta`'s own fixed demo obstacles (see the LOS
    // gating test's comment), and its mid-cross dense path pattern (which
    // only touches the exact middle row/column), so the only blocking cells
    // in play are the two this test adds below.
    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    _ = try world.setDenseTile(layer, 1, 1, tree); // dense-blocked cell
    _ = try world.addSparseTile(0, 3, 3, tree, 0, .obstacle); // sparse-blocked cell

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.ensureLevelBlockedCache(&world, 0);
    // Also build a slot for a level that does not exist in `world` (only
    // level 0 was added), so the fail-closed check below exercises
    // `LevelBlockedSlot.valid == false` directly, not just the cheaper
    // `level >= level_blocked.len` early-out (both must fail-closed).
    try sys.ensureLevelBlockedCache(&world, 1);

    const Case = struct { level: u16, x: u16, y: u16 };
    const cases = [_]Case{
        .{ .level = 0, .x = 1, .y = 1 }, // dense-blocked
        .{ .level = 0, .x = 3, .y = 3 }, // sparse-blocked
        .{ .level = 0, .x = 4, .y = 4 }, // open
        .{ .level = 1, .x = 0, .y = 0 }, // built but invalid (world has only level 0)
        .{ .level = 2, .x = 0, .y = 0 }, // never built: out-of-range level_blocked index
        .{ .level = 0, .x = world.width, .y = 0 }, // out-of-range x
        .{ .level = 0, .x = 0, .y = world.height }, // out-of-range y
    };
    for (cases) |c| {
        const expected = world.levelBlocksMovement(c.level, c.x, c.y);
        const actual = lookupLevelBlocked(sys.level_blocked.items, c.level, c.x, c.y);
        try testing.expectEqual(expected, actual);
    }
}

test "ensureLevelBlockedCache self-heals once a level queried before it existed is actually added" {
    // No addLevel call yet: levelCount() == 0, so level 0 is out of range at
    // the moment of this first touch.
    var world = WorldSystem{
        .allocator = testing.allocator,
        .width = 4,
        .height = 4,
        .tile_size = 32,
        .chunk_size_tiles = 4,
    };
    defer world.deinit();

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();

    try sys.ensureLevelBlockedCache(&world, 0);
    try testing.expect(!sys.level_blocked.items[0].valid);
    try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, 0, 0)); // fail-closed

    // Level added post-init (a future caller calling WorldSystem.addLevel
    // after startup).
    _ = try world.addLevel(0);

    // A later step's touch must retry a full rebuild and recover, not stay
    // permanently fail-closed.
    sys.step_counter += 1;
    try sys.ensureLevelBlockedCache(&world, 0);
    try testing.expect(sys.level_blocked.items[0].valid);
    try testing.expect(!lookupLevelBlocked(sys.level_blocked.items, 0, 0, 0)); // real, open tile data
}

test "prebuildLevelCaches builds every existing level once, so a later per-step touch reuses rather than rebuilding" {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    _ = try world.addLevel(1);
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer0 = try world.addDenseLayer(0, 0, .obstacle, grass);
    const layer1 = try world.addDenseLayer(1, 0, .obstacle, grass);

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();

    try sys.prebuildLevelCaches(&world);
    try testing.expect(sys.level_blocked.items[0].valid);
    try testing.expect(sys.level_blocked.items[1].valid);
    try testing.expect(sys.level_blocked.items[0].built_step != invalid_build_step);
    try testing.expect(sys.level_blocked.items[1].built_step != invalid_build_step);
    try testing.expect(!lookupLevelBlocked(sys.level_blocked.items, 0, 2, 2));
    try testing.expect(!lookupLevelBlocked(sys.level_blocked.items, 1, 2, 2));

    // Mutate both levels' worlds directly, never reporting either edit as
    // dirty (mirrors the "never reported as dirty" trick the full-rebuild
    // fallback test above uses): if the next per-step touch silently redid a
    // full rebuild instead of reusing the prebuilt cache, it would pick this
    // up; if it correctly takes the cheap "nothing changed" path, it won't.
    _ = try world.setDenseTile(layer0, 2, 2, tree);
    _ = try world.setDenseTile(layer1, 2, 2, tree);

    sys.step_counter += 1;
    try sys.ensureLevelBlockedCache(&world, 0);
    try sys.ensureLevelBlockedCache(&world, 1);
    try testing.expect(!lookupLevelBlocked(sys.level_blocked.items, 0, 2, 2));
    try testing.expect(!lookupLevelBlocked(sys.level_blocked.items, 1, 2, 2));
}

// Shared parity check for the dirty-tracked patch/skip/fallback tests below:
// a fresh `PerceptionSystem`'s first (always full-rebuild) build against the
// same `world`/`level` state is the ground truth every patched result must
// match bit-for-bit.
fn expectLevelBlockedMatchesFreshRebuild(sys: *PerceptionSystem, world: *const WorldSystem, level: u16) !void {
    var fresh = PerceptionSystem.init(testing.allocator);
    defer fresh.deinit();
    try fresh.ensureLevelBlockedCache(world, level);

    var y: u16 = 0;
    while (y < world.height) : (y += 1) {
        var x: u16 = 0;
        while (x < world.width) : (x += 1) {
            const expected = lookupLevelBlocked(fresh.level_blocked.items, level, x, y);
            const actual = lookupLevelBlocked(sys.level_blocked.items, level, x, y);
            try testing.expectEqual(expected, actual);
        }
    }
}

test "patch: single dense-tile flip (open->blocked and blocked->open) matches a fresh full rebuild" {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.ensureLevelBlockedCache(&world, 0); // first build: obstacle layer all-open

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();

    // Open -> blocked.
    const changed = (try world.setDenseTile(layer, 2, 2, tree)) orelse return error.TestExpectedEqual;
    try testing.expect(changed.old_blocks_movement != changed.new_blocks_movement);
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
    try sys.reactToPostCommitPerceptionEvents(&frame, &world);
    sys.step_counter += 1;
    try sys.ensureLevelBlockedCache(&world, 0); // patch
    try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, 2, 2));
    try expectLevelBlockedMatchesFreshRebuild(&sys, &world, 0);

    // Blocked -> open: proves the patch memsets false first rather than only
    // ever setting bits true.
    frame.events.clearRetainingCapacity();
    const changed_back = (try world.setDenseTile(layer, 2, 2, grass)) orelse return error.TestExpectedEqual;
    try testing.expect(changed_back.old_blocks_movement != changed_back.new_blocks_movement);
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed_back } });
    try sys.reactToPostCommitPerceptionEvents(&frame, &world);
    sys.step_counter += 1;
    try sys.ensureLevelBlockedCache(&world, 0); // patch
    try testing.expect(!lookupLevelBlocked(sys.level_blocked.items, 0, 2, 2));
    try expectLevelBlockedMatchesFreshRebuild(&sys, &world, 0);
}

test "patch: single sparse-tile add matches a fresh full rebuild" {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.ensureLevelBlockedCache(&world, 0); // first build

    const changed = (try world.addSparseTile(0, 5, 5, tree, 0, .obstacle)) orelse return error.TestExpectedEqual;
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = changed } });
    try sys.reactToPostCommitPerceptionEvents(&frame, &world);
    sys.step_counter += 1;
    try sys.ensureLevelBlockedCache(&world, 0); // patch

    try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, 5, 5));
    try expectLevelBlockedMatchesFreshRebuild(&sys, &world, 0);
}

test "patch: a sparse tile's blocking removal (simulated -- WorldSystem has no removal API) matches a fresh full rebuild of the post-removal world" {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;

    // "Before": a real sparse blocking tile at (6, 6).
    var world_before = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world_before.deinit();
    _ = try world_before.addSparseTile(0, 6, 6, tree, 0, .obstacle);

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.ensureLevelBlockedCache(&world_before, 0); // first build: (6,6) blocked
    try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, 6, 6));

    // "After": sparse tiles are append-only (`addSparseTile`'s doc comment on
    // `sparse_level_tiles` -- never removed, never reassigned), so there is no
    // API call that un-blocks (6,6) on `world_before`. This builds the
    // post-removal world state directly instead, and marks the cell dirty
    // against it -- proving the patch path correctly clears a bit (not just
    // sets one) when the causing world state genuinely no longer blocks.
    var world_after = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world_after.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{
        .level = 0,
        .min_x = 6,
        .min_y = 6,
        .max_x_exclusive = 7,
        .max_y_exclusive = 7,
    } } });
    try sys.reactToPostCommitPerceptionEvents(&frame, &world_after);
    sys.step_counter += 1;
    try sys.ensureLevelBlockedCache(&world_after, 0); // patch against the post-removal world

    try testing.expect(!lookupLevelBlocked(sys.level_blocked.items, 0, 6, 6));
    try expectLevelBlockedMatchesFreshRebuild(&sys, &world_after, 0);
}

test "patch: a multi-cell world_obstacle_changed rect matches a fresh full rebuild" {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.ensureLevelBlockedCache(&world, 0); // first build: obstacle layer all-open

    const min_x: u16 = 2;
    const min_y: u16 = 2;
    const max_x_exclusive: u16 = 6;
    const max_y_exclusive: u16 = 6;
    var yy: u16 = min_y;
    while (yy < max_y_exclusive) : (yy += 1) {
        var xx: u16 = min_x;
        while (xx < max_x_exclusive) : (xx += 1) {
            _ = try world.setDenseTile(layer, xx, yy, tree);
        }
    }
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{
        .level = 0,
        .min_x = min_x,
        .min_y = min_y,
        .max_x_exclusive = max_x_exclusive,
        .max_y_exclusive = max_y_exclusive,
    } } });
    try sys.reactToPostCommitPerceptionEvents(&frame, &world);
    sys.step_counter += 1;
    try sys.ensureLevelBlockedCache(&world, 0); // patch

    yy = min_y;
    while (yy < max_y_exclusive) : (yy += 1) {
        var xx: u16 = min_x;
        while (xx < max_x_exclusive) : (xx += 1) {
            try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, xx, yy));
        }
    }
    try expectLevelBlockedMatchesFreshRebuild(&sys, &world, 0);
}

test "patch: dirty rects accumulated across several untouched steps still patch correctly once the level is finally touched" {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.ensureLevelBlockedCache(&world, 0); // first build

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();

    // Three edits, each its own reactToPostCommitPerceptionEvents call with no
    // intervening ensureLevelBlockedCache -- simulates three simulation steps
    // where no observer looked at this level in between, so pending_dirty
    // accumulates across all three rather than being drained per step (the
    // key behavioral difference from `PathfindingSystem.nav_dirty_edits`).
    const cells = [_][2]u16{ .{ 1, 1 }, .{ 2, 2 }, .{ 3, 3 } };
    for (cells) |c| {
        frame.events.clearRetainingCapacity();
        const changed = (try world.setDenseTile(layer, c[0], c[1], tree)) orelse return error.TestExpectedEqual;
        try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
        try sys.reactToPostCommitPerceptionEvents(&frame, &world);
    }
    try testing.expectEqual(@as(usize, 3), sys.level_blocked.items[0].pending_dirty.items.len);

    sys.step_counter += 1;
    try sys.ensureLevelBlockedCache(&world, 0); // one patch call applies all 3 accumulated rects

    for (cells) |c| try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, c[0], c[1]));
    try expectLevelBlockedMatchesFreshRebuild(&sys, &world, 0);
    try testing.expectEqual(@as(usize, 0), sys.level_blocked.items[0].pending_dirty.items.len);
}

test "patch: dirty rects recorded before a level's first build are discarded, not replayed as a patch" {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);
    // A second blocking cell OUTSIDE the dirty rect below, already part of the
    // world before this level's first build ever runs: only a real full scan
    // (not a naive "patch just the dirty rect on first build" shortcut) would
    // pick this up.
    _ = try world.setDenseTile(layer, 9, 9, tree) orelse return error.TestExpectedEqual;

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();

    // Mark a cell dirty BEFORE this level has ever been built -- no observer
    // has looked at level 0 yet, so `level_blocked` has no slot for it at all
    // (`markLevelDirty`/`levelBlockedSlot` grow one on demand).
    const changed = (try world.setDenseTile(layer, 4, 4, tree)) orelse return error.TestExpectedEqual;
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
    try sys.reactToPostCommitPerceptionEvents(&frame, &world);
    try testing.expectEqual(@as(usize, 1), sys.level_blocked.items[0].pending_dirty.items.len);

    try sys.ensureLevelBlockedCache(&world, 0); // first-ever build: must reflect the whole world directly

    try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, 4, 4));
    try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, 9, 9));
    try testing.expectEqual(@as(usize, 0), sys.level_blocked.items[0].pending_dirty.items.len);
    try expectLevelBlockedMatchesFreshRebuild(&sys, &world, 0);
}

test "patch: accumulated dirty area over the full-rebuild threshold falls back to a full rebuild" {
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();

    const tile_size = meta.tileSize();
    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, tile_size * 16, tile_size * 16);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    try sys.ensureLevelBlockedCache(&world, 0); // first build: obstacle layer all-open

    // A 9x9 rect (81 of 256 cells, ~31.6%) is over the 25% threshold, so the
    // next ensureLevelBlockedCache call must fall back to a full rebuild
    // rather than patch just this rect.
    var yy: u16 = 0;
    while (yy < 9) : (yy += 1) {
        var xx: u16 = 0;
        while (xx < 9) : (xx += 1) {
            _ = try world.setDenseTile(layer, xx, yy, tree);
        }
    }
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_obstacle_changed = .{
        .level = 0,
        .min_x = 0,
        .min_y = 0,
        .max_x_exclusive = 9,
        .max_y_exclusive = 9,
    } } });
    try sys.reactToPostCommitPerceptionEvents(&frame, &world);

    // An edit NEVER reported as dirty, far outside the reported rect: only a
    // genuine full rebuild (not a per-rect patch, which would never look at
    // this cell) picks this up too.
    _ = try world.setDenseTile(layer, 15, 0, tree) orelse return error.TestExpectedEqual;

    sys.step_counter += 1;
    try sys.ensureLevelBlockedCache(&world, 0);

    try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, 4, 4));
    try testing.expect(lookupLevelBlocked(sys.level_blocked.items, 0, 15, 0));
    try expectLevelBlockedMatchesFreshRebuild(&sys, &world, 0);
    try testing.expectEqual(@as(usize, 0), sys.level_blocked.items[0].pending_dirty.items.len);
}

test "player-candidate detection: hostile player within vision/FOV becomes nearest_threat" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .hostile, .{});

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const player = try data.createEntity();
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .player_candidate = .{ .entity = player, .pos_x = 20, .pos_y = 0, .faction = .player, .level = 0 },
    });

    const perception = data.aiPerceptionConst(observer).?;
    try testing.expect(perception.target_visible);
    try testing.expectEqual(player.index, perception.nearest_threat.index);
}

test "transitions: invalid to valid emits entity_perceived" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    const threat = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 1), stats.perceived_events);
    try testing.expectEqual(@as(usize, 0), stats.lost_events);
    const merged = events.mergedItems();
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(SimulationEvent{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{ .observer = observer, .target = threat } } }, merged[0]);
}

test "transitions: valid to invalid emits entity_lost" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    const threat = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 2048, 2048, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expect(data.aiPerceptionConst(observer).?.target_visible);
    events.clearRetainingCapacity();

    // Move the threat far outside vision_range and rebuild the spatial index
    // (positions are read from previous_x/y, so update the movement body).
    try data.setMovementBody(threat, .{ .position = .{ .x = 5000, .y = 0 }, .previous_position = .{ .x = 5000, .y = 0 }, .velocity = .{}, .speed = 0 });
    var spatial_sys2 = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys2.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys2.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 0), stats.perceived_events);
    try testing.expectEqual(@as(usize, 1), stats.lost_events);
    const merged = events.mergedItems();
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqual(SimulationEvent{ .stage = .domain_reaction, .payload = .{ .entity_lost = .{ .observer = observer, .target = threat } } }, merged[0]);
    try testing.expect(!data.aiPerceptionConst(observer).?.target_visible);
}

test "transitions: unchanged nearest_threat emits no event" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    events.clearRetainingCapacity();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 0), stats.perceived_events);
    try testing.expectEqual(@as(usize, 0), stats.lost_events);
    try testing.expectEqual(@as(usize, 0), events.mergedItems().len);
}

test "transitions: identity swap without passing through invalid emits lost then perceived, in that order" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const observer = try addObserver(&data, 0, 0, 10, 0, .player, .{ .vision_range = 500 });
    const first_threat = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 2048, 2048, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expectEqual(first_threat.index, data.aiPerceptionConst(observer).?.nearest_threat.index);
    events.clearRetainingCapacity();

    // Move the first threat far away and add a second, closer hostile in the
    // same step: nearest_threat swaps identity without an intervening
    // invalid step.
    try data.setMovementBody(first_threat, .{ .position = .{ .x = 5000, .y = 0 }, .previous_position = .{ .x = 5000, .y = 0 }, .velocity = .{}, .speed = 0 });
    const second_threat = try addAgent(&data, 12, 0, 0, 0, .hostile);
    var spatial_sys2 = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys2.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys2.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 1), stats.perceived_events);
    try testing.expectEqual(@as(usize, 1), stats.lost_events);
    const merged = events.mergedItems();
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqual(SimulationEvent{ .stage = .domain_reaction, .payload = .{ .entity_lost = .{ .observer = observer, .target = first_threat } } }, merged[0]);
    try testing.expectEqual(SimulationEvent{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{ .observer = observer, .target = second_threat } } }, merged[1]);
    try testing.expectEqual(second_threat.index, data.aiPerceptionConst(observer).?.nearest_threat.index);
}

test "PerceptionSystem enforces its own per-step event cap and records the drop diagnostic" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .hostile);
    _ = try addObserver(&data, 100, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 110, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 256, 256, 32);
    defer world.deinit();
    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{
        .max_events_per_step = 1,
    });
    try testing.expectEqual(@as(usize, 1), stats.perceived_events + stats.lost_events);
    try testing.expectEqual(@as(usize, 1), stats.dropped_events);
    try testing.expectEqual(@as(usize, 1), events.mergedItems().len);
    try testing.expectEqual(@as(usize, 1), events.stats.dropped);
}

test "serial and threaded PerceptionSystem updates route through identical math" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var serial_data = DataSystem.init(testing.allocator);
    defer serial_data.deinit();
    var threaded_data = DataSystem.init(testing.allocator);
    defer threaded_data.deinit();

    for (0..40) |i| {
        const fi: f32 = @floatFromInt(i);
        const faction: Faction = if (i % 3 == 0) .hostile else .player;
        _ = try addAgent(&serial_data, fi * 6, 0, 0, 0, faction);
        _ = try addAgent(&threaded_data, fi * 6, 0, 0, 0, faction);
    }
    for (0..40) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try addObserver(&serial_data, fi * 6 + 3, 4, 1, 1, .player, .{ .fov_half_angle_radians = std.math.pi / 2.0, .vision_range = 100, .hearing_range = 5 });
        _ = try addObserver(&threaded_data, fi * 6 + 3, 4, 1, 1, .player, .{ .fov_half_angle_radians = std.math.pi / 2.0, .vision_range = 100, .hearing_range = 5 });
    }

    var serial_spatial = try testSpatialIndex(serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), &serial_data);
    defer serial_spatial.deinit();
    var threaded_spatial = try testSpatialIndex(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), &threaded_data);
    defer threaded_spatial.deinit();

    var world = try minimalWorld(testing.allocator, 512, 64, 32);
    defer world.deinit();

    // Only the observer near x=63 (i=10) is within hearing_range=5 of this stimulus.
    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 63, .y = 4 }, .intensity = 1, .kind = .dig, .level = 0 }};

    var serial_sys = PerceptionSystem.init(testing.allocator);
    defer serial_sys.deinit();
    var serial_events = SimulationEvents.init(testing.allocator);
    defer serial_events.deinit();
    _ = try serial_sys.updateSerial(serial_data.aiAgentSliceConst(), serial_data.movementBodySliceConst(), serial_spatial.view(), &world, &serial_data, &serial_events, .{ .stimuli = &stimuli });

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = perception_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var threaded_sys = PerceptionSystem.init(testing.allocator);
    defer threaded_sys.deinit();
    var threaded_events = SimulationEvents.init(testing.allocator);
    defer threaded_events.deinit();
    _ = try threaded_sys.update(threaded_data.aiAgentSliceConst(), threaded_data.movementBodySliceConst(), threaded_spatial.view(), &world, &threaded_data, &threaded_events, &threads, .{
        .items_per_range = perception_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
        .stimuli = &stimuli,
    });

    const serial_ai = serial_data.aiAgentSliceConst();
    const threaded_ai = threaded_data.aiAgentSliceConst();
    try testing.expectEqual(serial_ai.entities.len, threaded_ai.entities.len);
    var any_heard = false;
    for (serial_ai.entities, threaded_ai.entities) |serial_entity, threaded_entity| {
        const serial_perception = serial_data.aiPerceptionConst(serial_entity) orelse continue;
        const threaded_perception = threaded_data.aiPerceptionConst(threaded_entity) orelse continue;
        try testing.expectEqual(serial_perception.target_visible, threaded_perception.target_visible);
        try testing.expectEqual(serial_perception.nearest_threat.index, threaded_perception.nearest_threat.index);
        try testing.expectEqual(serial_perception.facing_x, threaded_perception.facing_x);
        try testing.expectEqual(serial_perception.facing_y, threaded_perception.facing_y);
        try testing.expectEqual(serial_perception.heard_stimulus, threaded_perception.heard_stimulus);
        try testing.expectEqual(serial_perception.heard_stimulus_x, threaded_perception.heard_stimulus_x);
        try testing.expectEqual(serial_perception.heard_stimulus_y, threaded_perception.heard_stimulus_y);
        if (serial_perception.heard_stimulus) any_heard = true;
    }
    try testing.expect(any_heard);

    const serial_merged = serial_events.mergedItems();
    const threaded_merged = threaded_events.mergedItems();
    try testing.expectEqualSlices(SimulationEvent, serial_merged, threaded_merged);
}

test "PerceptionSystem has no steady-state allocation after warmup (FailingAllocator)" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addObserver(&data, 0, 0, 10, 0, .player, .{ .hearing_range = 50 });
    _ = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 64, 64, 32);
    defer world.deinit();

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 20, .y = 0 }, .intensity = 1, .kind = .dig, .level = 0 }};

    // Warm up: one full serial run sizes every scratch buffer (candidates,
    // rows, event range scratch, range_take_counts, and the per-level
    // LOS-blocked bitmap cache) to steady state.
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });
    try testing.expect(sys.level_blocked.items.len > 0);
    try testing.expect(sys.level_blocked.items[0].valid);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_system_allocator = sys.allocator;
    const original_events_allocator = events.stream.allocator;
    sys.allocator = failing.allocator();
    events.stream.allocator = failing.allocator();
    defer {
        sys.allocator = original_system_allocator;
        events.stream.allocator = original_events_allocator;
    }

    // The second run's ensureLevelBlockedCache call sees a step_counter
    // mismatch (a new step ran) but no pending dirty rects (nothing called
    // reactToPostCommitPerceptionEvents between the two runs), so it takes
    // the skip branch rather than rebuilding — proving that path allocates
    // nothing either. The dedicated patch-path FailingAllocator test below
    // covers the case where a dirty rect actually is pending. `job.stimuli` is
    // a borrowed slice, never copied, so passing it here adds no allocation.
    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{ .stimuli = &stimuli });
    try testing.expectEqual(@as(usize, 1), stats.observer_count);
    try testing.expect(data.aiPerceptionConst(data.aiAgentSliceConst().entities[0]).?.heard_stimulus);
}

test "PerceptionSystem threaded update has no steady-state allocation after warmup, multi-range (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Enough observers to force multiple ranges under items_per_range ==
    // perception_range_alignment_items, exercising prepareEventRangeBuffers's
    // and prepareRangeStats's multi-slot growth loops (only reachable when
    // range_count > 1), which the serial-only proof above never touches.
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..40) |i| {
        const fi: f32 = @floatFromInt(i);
        const faction: Faction = if (i % 3 == 0) .hostile else .player;
        _ = try addAgent(&data, fi * 6, 0, 0, 0, faction);
    }
    for (0..40) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try addObserver(&data, fi * 6 + 3, 4, 1, 1, .player, .{ .fov_half_angle_radians = std.math.pi / 2.0, .vision_range = 100, .hearing_range = 5 });
    }

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();
    var world = try minimalWorld(testing.allocator, 512, 64, 32);
    defer world.deinit();

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = perception_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();

    const stimuli = [_]WorldStimulus{.{ .position = .{ .x = 63, .y = 4 }, .intensity = 1, .kind = .dig, .level = 0 }};
    const config = PerceptionConfig{
        .items_per_range = perception_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
        .stimuli = &stimuli,
    };

    // Warm up: one full threaded run sizes every scratch buffer (candidates,
    // rows, per-range event buffers, per-range stats, range_take_counts, and
    // the per-level LOS-blocked bitmap cache) to steady state at range_count
    // > 1.
    const warmup_stats = try sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, &threads, config);
    try testing.expect(warmup_stats.batch.range_count > 1);
    try testing.expect(sys.level_blocked.items.len > 0);
    try testing.expect(sys.level_blocked.items[0].valid);

    // Mirror the real per-frame lifecycle (SimulationFrame.beginStep) that
    // resets `events` to steady-state-retained-capacity before every step;
    // without this, `events.range_stats`'s own first_range bookkeeping would
    // keep growing across steps regardless of this system's allocation
    // behavior, which is not what this proof is about.
    events.clearRetainingCapacity();

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_system_allocator = sys.allocator;
    const original_events_allocator = events.stream.allocator;
    sys.allocator = failing.allocator();
    events.stream.allocator = failing.allocator();
    defer {
        sys.allocator = original_system_allocator;
        events.stream.allocator = original_events_allocator;
    }

    const stats = try sys.update(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, &threads, config);
    try testing.expectEqual(@as(usize, 40), stats.observer_count);
    try testing.expect(stats.batch.range_count > 1);
}

test "PerceptionSystem's dirty-tracked patch path has no steady-state allocation after warmup (FailingAllocator)" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addObserver(&data, 0, 0, 10, 0, .player, .{});
    _ = try addAgent(&data, 10, 0, 0, 0, .hostile);

    var spatial_sys = try testSpatialIndex(data.aiAgentSliceConst(), data.movementBodySliceConst(), &data);
    defer spatial_sys.deinit();

    // A real asset-backed tileset (same pattern as the LOS/parity tests
    // above): the patch path's dense-layer rescan needs a real "blocks
    // movement" tile, not a hand-poked `minimalWorld`.
    const asset_store = @import("../../assets/assets.zig").AssetStore.init(testing.allocator, testing.io, "assets");
    var meta = try @import("../../assets/world_tileset_meta.zig").load(
        testing.allocator,
        asset_store,
        @import("../../assets/manifest.zig").spriteSpec(.world_tileset).metadata_path.?,
    );
    defer meta.deinit();
    var world = try WorldSystem.initDemoFromMeta(testing.allocator, &meta, 1024, 1024);
    defer world.deinit();
    const tree = (meta.tileByName("tree_0") orelse return error.TestExpectedEqual).id;
    const grass = (meta.tileByName("grass") orelse return error.TestExpectedEqual).id;
    const layer = try world.addDenseLayer(0, 0, .obstacle, grass);

    var sys = PerceptionSystem.init(testing.allocator);
    defer sys.deinit();
    var events = SimulationEvents.init(testing.allocator);
    defer events.deinit();
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();

    // Warm up: a full serial run sizes every scratch buffer (including
    // `level_blocked`'s bitmap) to steady state, then several one-cell-edit
    // patch cycles plateau `pending_dirty`'s capacity for level 0.
    _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    var cell_x: u16 = 20;
    for (0..3) |_| {
        frame.events.clearRetainingCapacity();
        const changed = (try world.setDenseTile(layer, cell_x, 20, tree)) orelse return error.TestExpectedEqual;
        try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
        try sys.reactToPostCommitPerceptionEvents(&frame, &world);
        _ = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
        cell_x += 1;
    }
    try testing.expect(sys.level_blocked.items[0].valid);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_system_allocator = sys.allocator;
    const original_events_allocator = events.stream.allocator;
    sys.allocator = failing.allocator();
    events.stream.allocator = failing.allocator();
    defer {
        sys.allocator = original_system_allocator;
        events.stream.allocator = original_events_allocator;
    }

    // One more same-shape edit (`pending_dirty`'s capacity already plateaued
    // above, and `frame.events` keeps its own real allocator, since only
    // `sys`'s dirty-tracking/cache allocations are under test here), then the
    // update whose `ensureLevelBlockedCache` call must patch (not skip, not
    // rebuild) without allocating.
    frame.events.clearRetainingCapacity();
    const changed = (try world.setDenseTile(layer, cell_x, 20, tree)) orelse return error.TestExpectedEqual;
    try frame.events.appendRequired(.{ .stage = .structural_commit, .payload = .{ .world_tile_changed = changed } });
    try sys.reactToPostCommitPerceptionEvents(&frame, &world);
    const stats = try sys.updateSerial(data.aiAgentSliceConst(), data.movementBodySliceConst(), spatial_sys.view(), &world, &data, &events, .{});
    try testing.expectEqual(@as(usize, 1), stats.observer_count);
}
