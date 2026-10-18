// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! AI short-term memory: each step decays every gathered agent's `AiMemory` row (staleness
//! climbs, familiarity relaxes toward zero, ring contacts age out), refreshes it from
//! perception's `entity_perceived`/`entity_lost` events, then tracks still-visible targets
//! from perception's `last_seen_*`.
//!
//! The gathered set is the think set's (or every AI agent's) rows carrying both
//! `AiPerception` and `AiMemory`, in ascending memory-row order for any think order: workers
//! translate think rows to memory and perception rows, main marks them in a hierarchical
//! member bitmap, workers extract each range's set bits in order, and main compacts the
//! windows. Decay gathers four rows per lane group.
//!
//! Order within one `update`:
//! 1. Decay over the gathered set.
//! 2. Event refresh, after decay so a same-step acquire or loss lands at `staleness == 0`. It
//!    reads every `domain_reaction` event, not only the gathered set's; perception emits only
//!    for its own scoped observers. On `entity_lost`, perception's frozen `last_seen_*`
//!    becomes `last_known_*` and staleness resets to 0; an identity swap's `entity_perceived`
//!    follows its loss and retargets `last_known_target`.
//! 3. Visibility over the gathered set: while perception's visible `nearest_threat` is
//!    `last_known_target`, `last_known_*` follows `last_seen_*`, staleness stays 0, and
//!    familiarity rises by `ai_memory_familiarity_gain_rate` (clamped).

const std = @import("std");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const logging = @import("../../core/logging.zig");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const StageThreads = @import("../../app/thread_system.zig").StageThreads;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const compactSliceWindows = @import("../../app/thread_system.zig").compactSliceWindows;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const runShaped = @import("../../app/thread_system.zig").runShaped;
const runStage = @import("../../app/thread_system.zig").runStage;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
const stageShape = @import("../../app/thread_system.zig").stageShape;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const ConstAiAgentSlice = @import("../data_system.zig").ConstAiAgentSlice;
const ConstPerceptionSlice = @import("../data_system.zig").ConstPerceptionSlice;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const AiMemorySlice = @import("../data_system.zig").AiMemorySlice;
const ai_memory_ring_capacity = @import("../data_system.zig").ai_memory_ring_capacity;
const max_ai_memory_staleness = @import("../data_system.zig").max_ai_memory_staleness;
const max_ai_memory_familiarity = @import("../data_system.zig").max_ai_memory_familiarity;
const ai_memory_familiarity_decay_rate = @import("../data_system.zig").ai_memory_familiarity_decay_rate;
const ai_memory_familiarity_gain_rate = @import("../data_system.zig").ai_memory_familiarity_gain_rate;
const movement_range_alignment_items = @import("../data_system.zig").movement_range_alignment_items;
const EntityPerceivedEvent = @import("../simulation.zig").EntityPerceivedEvent;
const EntityLostEvent = @import("../simulation.zig").EntityLostEvent;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;

/// Range alignment of the translate stage: each range's `u32` windows are whole cache
/// lines of their aligned lists.
pub const ai_memory_range_alignment_items: usize = movement_range_alignment_items;

/// Range alignment of the order stage: one item (a touched row word) already writes whole
/// cache lines of each window list.
pub const ai_memory_order_range_alignment_items: usize = 1;

comptime {
    std.debug.assert(ai_memory_range_alignment_items * @sizeOf(u32) % thread_shared_record_alignment == 0);
    std.debug.assert(ai_memory_order_range_alignment_items * word_bits * @sizeOf(u32) % thread_shared_record_alignment == 0);
    // Each order range's tally owns whole lines, at any range count.
    std.debug.assert(@sizeOf(PaddedSlot(OrderTally)) % thread_shared_record_alignment == 0);
}

fn hotStoreCapacity(min_len: usize) usize {
    return std.mem.alignForwardAnyAlign(usize, min_len, ai_memory_range_alignment_items);
}

// A think slot without both perception and memory. Unreachable as a row: an append past
// `maxInt(u32) - 1` memory rows fails as `OutOfMemory`.
const no_memory_row: u32 = std.math.maxInt(u32);

/// Memory rows per member word; the order stage's item is one word.
pub const word_bits = @bitSizeOf(std.bit_set.Dynamic.MaskInt);
const WordSet = std.bit_set.Integer(word_bits);

// Summary levels above the row bits: enough that one top word covers every `u32` memory
// row, so the walk starts at one word for any store size.
const summary_level_count: usize = blk: {
    var levels: usize = 0;
    var top_word_rows: u64 = word_bits;
    while (top_word_rows <= std.math.maxInt(u32)) : (levels += 1) top_word_rows *= word_bits;
    break :blk levels;
};
const RowList = std.array_list.Aligned(u32, .fromByteUnits(thread_shared_record_alignment));
const MemoryThreads = StageThreads(AiMemoryConfig);

// One order range's member count, written once by its job.
const OrderTally = struct { kept: usize = 0 };

pub const AiMemoryConfig = struct {
    /// When non-null, only these dense ai-store indices participate this step
    /// (the scope system's think set: halo ∩ stagger), in any order. Null = all agents.
    /// Mirrors `AiConfig.scope_dense_indices` /
    /// `PerceptionConfig.scope_dense_indices` exactly.
    scope_dense_indices: ?[]const u32 = null,
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

pub const AiMemoryStats = struct {
    perf: Perf = .{},

    /// Kept only with `runtime_perf_log.enabled`: the decay stage, and the think-row to
    /// memory-row translate, the member order, and the visibility pass.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        batch: BatchStats = .{},
        gather_batch: BatchStats = .{},
        order_batch: BatchStats = .{},
        visible_batch: BatchStats = .{},
    } else struct {};
};

pub const AiMemorySystem = struct {
    allocator: std.mem.Allocator,
    // Per think slot, its memory row or `no_memory_row`, and its perception row (read only
    // beside a memory row): the translate's windows.
    think_rows: RowList = .empty,
    think_perception_rows: RowList = .empty,
    // Per memory row, the perception row its mark filed this step; read only at marked rows.
    perception_by_memory_row: RowList = .empty,
    // One bit per memory row; summary level `k` holds one bit per nonzero word of level
    // `k - 1` (level 0: `member_words`). All are zero between steps: the step that marks
    // them clears them.
    member_words: std.bit_set.Dynamic = .{},
    summary_levels: [summary_level_count]std.bit_set.Dynamic = @splat(.{}),
    // This step's nonzero `member_words` word indices ascending: the order stage's items.
    touched_words: RowList = .empty,
    // The order stage's windows (`word_bits` slots per touched word), then this step's
    // member memory rows ascending: a subset of the memory store's own rows, which decay
    // and the visibility pass walk. `perception_dense_indices` holds each one's perception
    // row at the same position.
    memory_dense_indices: RowList = .empty,
    perception_dense_indices: RowList = .empty,
    order_tallies: SlotList(OrderTally) = .empty,
    // Think rows and memory rows the scratch is reserved for; the grow gate compares
    // against them.
    reserved_think_rows: usize = 0,
    reserved_memory_rows: usize = 0,
    /// Telemetry: steps whose think or memory rows exceeded the reservation and grew the
    /// scratch on the main thread before dispatch. Nonzero means the population seam's
    /// reserve is short; the first warns once.
    scratch_grown: u64 = 0,
    gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    order_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    decay_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    visible_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

    /// Sizes the scratch for `pop` think rows and `pop` memory rows under every partition
    /// the tuners can pick. Grow-only; the pipeline calls it at its population seam.
    pub fn reserve(self: *AiMemorySystem, pop: usize) !void {
        if (pop == 0) return;
        try self.growScratch(hotStoreCapacity(pop), hotStoreCapacity(pop));
    }

    pub fn init(allocator: std.mem.Allocator) AiMemorySystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *AiMemorySystem) void {
        self.order_tallies.deinit(self.allocator);
        self.perception_dense_indices.deinit(self.allocator);
        self.memory_dense_indices.deinit(self.allocator);
        self.touched_words.deinit(self.allocator);
        for (&self.summary_levels) |*level| level.deinit(self.allocator);
        self.member_words.deinit(self.allocator);
        self.perception_by_memory_row.deinit(self.allocator);
        self.think_perception_rows.deinit(self.allocator);
        self.think_rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn update(
        self: *AiMemorySystem,
        ai_agents: ConstAiAgentSlice,
        data: *DataSystem,
        frame: *SimulationFrame,
        thread_system: *ThreadSystem,
        config: AiMemoryConfig,
    ) !AiMemoryStats {
        return self.step(ai_agents, data, frame, .{ .thread_system = thread_system, .config = config }, config.scope_dense_indices);
    }

    // Each stage runs under its own tuner on `threads`.
    fn step(
        self: *AiMemorySystem,
        ai_agents: ConstAiAgentSlice,
        data: *DataSystem,
        frame: *SimulationFrame,
        threads: MemoryThreads,
        think: ?[]const u32,
    ) !AiMemoryStats {
        self.memory_dense_indices.clearRetainingCapacity();
        self.perception_dense_indices.clearRetainingCapacity();
        var stats = AiMemoryStats{};
        var memory_slice = data.aiMemorySlice();
        const perception_slice = data.aiPerceptionSliceConst();
        const think_count = if (think) |rows| rows.len else ai_agents.entities.len;
        const row_count = memory_slice.entities.len;

        if (think_count != 0 and row_count != 0) {
            if (think_count > self.reserved_think_rows or row_count > self.reserved_memory_rows) try self.growPastReserve(think_count, row_count);
            std.debug.assert(self.think_rows.capacity >= think_count and self.think_perception_rows.capacity >= think_count);
            self.think_rows.items.len = think_count;
            self.think_perception_rows.items.len = think_count;
            var translate = TranslateJob{ .think = think, .entities = ai_agents.entities, .data = data, .out = self.think_rows.items, .out_perception = self.think_perception_rows.items };
            const gather_batch = runStage(threads.stage(&self.gather_tuner), think_count, ai_memory_range_alignment_items, &translate, &translate.range_count, translateJob);
            if (comptime runtime_perf_log.enabled) stats.perf.gather_batch = gather_batch;

            const members = self.mark(row_count);
            if (members != 0) {
                self.collectTouchedWords(row_count);
                const order_batch = self.orderMembers(row_count, threads.stage(&self.order_tuner));
                if (comptime runtime_perf_log.enabled) stats.perf.order_batch = order_batch;
                std.debug.assert(self.memory_dense_indices.items.len == members and self.perception_dense_indices.items.len == members);
                self.unmark();
            }

            var decay = AiMemoryDecayContext{ .slice = memory_slice, .indices = self.memory_dense_indices.items };
            // Range alignment 1: the indexed gather/scatter path processes each row
            // independently of any contiguous-range shape.
            const decay_batch = runStage(threads.stage(&self.decay_tuner), members, 1, &decay, &decay.range_count, aiMemoryDecayJob);
            if (comptime runtime_perf_log.enabled) stats.perf.batch = decay_batch;
        }

        refreshFromEvents(data, &memory_slice, perception_slice, frame);

        var visible = VisibleJob{ .memory = memory_slice, .perception = perception_slice, .rows = self.memory_dense_indices.items, .perception_rows = self.perception_dense_indices.items };
        const visible_batch = runStage(threads.stage(&self.visible_tuner), visible.rows.len, 1, &visible, &visible.range_count, visibleJob);
        if (comptime runtime_perf_log.enabled) stats.perf.visible_batch = visible_batch;
        return stats;
    }

    // Main thread: sets each member memory row's bit, files its perception row under it,
    // and, on its word's first member, sets that word's bit at each summary level up to the
    // first level whose word was already nonzero. Returns the member count. O(1) per row
    // plus O(1) per newly nonzero word at each level. Scalar: scattered bit sets and index
    // writes.
    fn mark(self: *AiMemorySystem, row_count: usize) usize {
        std.debug.assert(self.perception_by_memory_row.capacity >= row_count);
        self.perception_by_memory_row.items.len = row_count;
        const perception_by_row = self.perception_by_memory_row.items;
        var members: usize = 0;
        for (self.think_rows.items, self.think_perception_rows.items) |row, perception_row| {
            if (row == no_memory_row) continue;
            std.debug.assert(row < row_count);
            const word = row / word_bits;
            const first_in_word = self.member_words.masks[word] == 0;
            // Think rows are distinct entities, so each memory row is marked once.
            std.debug.assert(!self.member_words.isSet(row));
            self.member_words.set(row);
            perception_by_row[row] = perception_row;
            members += 1;
            if (first_in_word) self.markSummaries(word);
        }
        return members;
    }

    // Sets `row_word`'s bit at summary level 0, and each nonzero-word bit above it, stopping
    // at the first level whose word already held a bit.
    fn markSummaries(self: *AiMemorySystem, row_word: usize) void {
        var below = row_word;
        for (&self.summary_levels) |*level| {
            const word = below / word_bits;
            const first_in_word = level.masks[word] == 0;
            level.set(below);
            if (!first_in_word) return;
            below = word;
        }
    }

    // Main thread: the nonzero row words ascending into `touched_words`, descending the
    // summary levels from their one top word and zeroing each summary word it reads. O(1)
    // per nonzero word at each level, with no term in the store's rows. Scalar: bit
    // iteration in ascending order.
    fn collectTouchedWords(self: *AiMemorySystem, row_count: usize) void {
        // One top word covers every `u32` row (`summary_level_count`).
        std.debug.assert(row_count <= std.math.maxInt(u32));
        std.debug.assert(self.touched_words.capacity >= @divCeil(row_count, word_bits));
        self.touched_words.clearRetainingCapacity();
        self.collectBelow(summary_level_count - 1, 0);
    }

    // Appends, ascending, every nonzero row word under `word` of summary level `level`, and
    // zeroes that summary word. Recursion depth is `summary_level_count`.
    fn collectBelow(self: *AiMemorySystem, level: usize, word: usize) void {
        const masks = self.summary_levels[level].masks;
        const nonzero = WordSet{ .mask = masks[word] };
        masks[word] = 0;
        var below_bits = nonzero.iterator(.{});
        while (below_bits.next()) |bit| {
            const below = word * word_bits + bit;
            if (level == 0) {
                // Below `maxInt(u32)`: a row word index of a `u32`-row store.
                self.touched_words.appendAssumeCapacity(@intCast(below));
            } else self.collectBelow(level - 1, below);
        }
    }

    // The marked rows ascending in `memory_dense_indices`, each one's filed perception row
    // beside it in `perception_dense_indices`: the stage's items are the touched row words;
    // each range extracts its words' set bits into its windows, then main compacts the
    // windows in range order.
    fn orderMembers(self: *AiMemorySystem, row_count: usize, dispatch: Dispatch) BatchStats {
        const touched_count = self.touched_words.items.len;
        const window_len = touched_count * word_bits;
        std.debug.assert(self.memory_dense_indices.capacity >= window_len and self.perception_dense_indices.capacity >= window_len);
        self.memory_dense_indices.items.len = window_len;
        self.perception_dense_indices.items.len = window_len;
        const shape = stageShape(dispatch, touched_count, ai_memory_order_range_alignment_items);
        std.debug.assert(self.order_tallies.capacity >= shape.range_count);
        setSlotCount(OrderTally, &self.order_tallies, shape.range_count);
        var job = OrderJob{
            .touched = self.touched_words.items,
            .words = self.member_words.masks[0..@divCeil(row_count, word_bits)],
            .perception_by_row = self.perception_by_memory_row.items,
            .out = self.memory_dense_indices.items,
            .out_perception = self.perception_dense_indices.items,
            .tallies = self.order_tallies.items,
            .items_per_range = shape.items_per_range,
        };
        const batch = runShaped(dispatch, shape, touched_count, ai_memory_order_range_alignment_items, &job, orderJob);
        const window_items = shape.items_per_range * word_bits;
        const members = compactSliceWindows(u32, OrderTally, self.memory_dense_indices.items, self.order_tallies.items, window_items);
        const perception_members = compactSliceWindows(u32, OrderTally, self.perception_dense_indices.items, self.order_tallies.items, window_items);
        std.debug.assert(perception_members == members);
        self.memory_dense_indices.items.len = members;
        self.perception_dense_indices.items.len = members;
        return batch;
    }

    // Main thread: zeroes each touched row word; the walk already zeroed the summary levels.
    fn unmark(self: *AiMemorySystem) void {
        for (self.touched_words.items) |word| self.member_words.masks[word] = 0;
    }

    // Main thread, before any dispatch: grows each scratch list short of its count 1.5x
    // ahead of need, counted. The first warns once (release-visible, compiled out of
    // tests).
    fn growPastReserve(self: *AiMemorySystem, think_count: usize, row_count: usize) error{OutOfMemory}!void {
        @branchHint(.cold);
        const think_target = if (think_count > self.reserved_think_rows) hotStoreCapacity(think_count + think_count / 2) else 0;
        const row_target = if (row_count > self.reserved_memory_rows) hotStoreCapacity(row_count + row_count / 2) else 0;
        try self.growScratch(think_target, row_target);
        self.scratch_grown += 1;
        if (comptime logging.enabled(.warn)) {
            if (self.scratch_grown == 1) logging.game.warn(
                "ai memory: {d} think rows / {d} memory rows exceeded the reserved scratch; grew to {d} / {d} (reservation short of the live population)",
                .{ think_count, row_count, self.reserved_think_rows, self.reserved_memory_rows },
            );
        }
    }

    // Grows the scratch to at least `think_target` think rows and `row_target` memory rows,
    // never shrinking. The limits move only after every reserve succeeds, so an OOM leaves
    // them, and the all-zero masks, intact for a retry.
    fn growScratch(self: *AiMemorySystem, think_target: usize, row_target: usize) error{OutOfMemory}!void {
        const think_limit = @max(self.reserved_think_rows, think_target);
        const row_limit = @max(self.reserved_memory_rows, row_target);
        const word_count = @divCeil(row_limit, word_bits);
        try self.think_rows.ensureTotalCapacity(self.allocator, think_limit);
        try self.think_perception_rows.ensureTotalCapacity(self.allocator, think_limit);
        try self.perception_by_memory_row.ensureTotalCapacity(self.allocator, row_limit);
        // Every row word's window, which also holds every row.
        try self.memory_dense_indices.ensureTotalCapacity(self.allocator, word_count * word_bits);
        try self.perception_dense_indices.ensureTotalCapacity(self.allocator, word_count * word_bits);
        try self.touched_words.ensureTotalCapacity(self.allocator, word_count);
        // Touched words, the order stage's items, are at most the think rows and the row words.
        try self.order_tallies.ensureTotalCapacityPrecise(self.allocator, maxRangeCount(@min(think_limit, word_count), ai_memory_order_range_alignment_items));
        if (row_limit > self.member_words.bit_length) try self.member_words.resize(self.allocator, row_limit, false);
        var level_bits = word_count;
        for (&self.summary_levels) |*level| {
            if (level_bits > level.bit_length) try level.resize(self.allocator, level_bits, false);
            level_bits = @divCeil(level_bits, word_bits);
        }
        self.reserved_think_rows = think_limit;
        self.reserved_memory_rows = row_limit;
        const reserved_words = @divCeil(self.reserved_memory_rows, word_bits);
        std.debug.assert(self.think_rows.capacity >= self.reserved_think_rows);
        std.debug.assert(self.think_perception_rows.capacity >= self.reserved_think_rows);
        std.debug.assert(self.perception_by_memory_row.capacity >= self.reserved_memory_rows);
        std.debug.assert(self.memory_dense_indices.capacity >= reserved_words * word_bits);
        std.debug.assert(self.perception_dense_indices.capacity >= reserved_words * word_bits);
        std.debug.assert(self.touched_words.capacity >= reserved_words);
        std.debug.assert(self.order_tallies.capacity >= maxRangeCount(@min(self.reserved_think_rows, reserved_words), ai_memory_order_range_alignment_items));
        std.debug.assert(self.member_words.bit_length >= self.reserved_memory_rows);
        var reserved_level_bits = reserved_words;
        for (&self.summary_levels) |*level| {
            std.debug.assert(level.bit_length >= reserved_level_bits);
            reserved_level_bits = @divCeil(reserved_level_bits, word_bits);
        }
    }
};

const TranslateJob = struct {
    think: ?[]const u32,
    entities: []const EntityId,
    data: *const DataSystem,
    out: []u32,
    out_perception: []u32,
    /// Dispatched range count; asserted against `range.index` at job entry.
    range_count: usize = 0,
};

// Each think slot's memory row and perception row, or `no_memory_row` in both without both
// stores. Scalar: per-row slot-record lookups with skips.
fn translateJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *TranslateJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.out.len and range.end <= job.out_perception.len);
    for (range.start..range.end) |k| {
        const i: usize = if (job.think) |think| think[k] else k;
        const ent = job.entities[i];
        job.out[k] = no_memory_row;
        job.out_perception[k] = no_memory_row;
        const perception_row = job.data.aiPerceptionDenseIndex(ent) orelse continue;
        const memory_row = job.data.aiMemoryDenseIndex(ent) orelse continue;
        // Both below `maxInt(u32)`: each store fails an append past that many rows.
        job.out[k] = @intCast(memory_row);
        job.out_perception[k] = @intCast(perception_row);
    }
}

const OrderJob = struct {
    touched: []const u32,
    words: []const usize,
    perception_by_row: []const u32,
    out: []u32,
    out_perception: []u32,
    tallies: []PaddedSlot(OrderTally),
    items_per_range: usize,
};

// Range `[start, end)` of the ascending touched row words: each word's member rows,
// ascending, into the range's window of `word_bits` slots per word, and each one's filed
// perception row at the same slot of its perception window. Reads the touched list, the
// row bits, and the filed rows within each word; writes only its windows and tally.
// Scalar: bit iteration and compaction.
fn orderJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *OrderJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.tallies.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start < range.end and range.end <= job.touched.len);
    std.debug.assert(range.end * word_bits <= job.out.len and job.out_perception.len == job.out.len);
    const window = job.out[range.start * word_bits .. range.end * word_bits];
    const perception_window = job.out_perception[range.start * word_bits .. range.end * word_bits];
    var kept: usize = 0;
    for (job.touched[range.start..range.end]) |word| {
        const row_base = @as(usize, word) * word_bits;
        const members = WordSet{ .mask = job.words[word] };
        var member_rows = members.iterator(.{});
        while (member_rows.next()) |row_bit| {
            const row = row_base + row_bit;
            // Below the memory store length, itself below `maxInt(u32)`.
            window[kept] = @intCast(row);
            perception_window[kept] = job.perception_by_row[row];
            kept += 1;
        }
    }
    job.tallies[range.index].value.kept = kept;
}

const AiMemoryDecayContext = struct {
    slice: AiMemorySlice,
    indices: []const u32,
    /// Dispatched range count; dual-asserted against `range.index` at job entry.
    range_count: usize = 0,
};

fn aiMemoryDecayJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *AiMemoryDecayContext = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig). Bounds on the
    // indices buffer live in processDecayRange (shared with the serial path).
    std.debug.assert(range.index < job.range_count);
    processDecayRange(&job.slice, job.indices, range);
}

/// Decays the rows named by `indices[range.start..range.end]`: staleness
/// climbs by one step clamped to `max_ai_memory_staleness`, familiarity
/// relaxes toward zero by `ai_memory_familiarity_decay_rate`. The indices are
/// scattered (a subset of the memory store's own row order), so four rows at
/// a time gather into lanes, decay as `Float4`, and scatter back — a
/// SIMD-gather/scatter shape over its own scoped subset. A scalar tail covers
/// the remainder. Ring aging
/// (`ageRingForRow`) is a separate per-row step, run once per row regardless
/// of whether that row was reached via the vector or scalar path here; its
/// own age+clamp math is itself vectorized as one `Float4` per row, with only
/// the entity-invalidation check staying scalar.
fn processDecayRange(slice: *AiMemorySlice, indices: []const u32, range: ParallelRange) void {
    // Shared serial/threaded buffer bounds (range.index is asserted at the job entry).
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= indices.len);

    const one = simd.splatFloat4(1.0);
    const zero = simd.splatFloat4(0.0);
    const max_staleness = simd.splatFloat4(max_ai_memory_staleness);
    const decay_rate = simd.splatFloat4(ai_memory_familiarity_decay_rate);

    var k = range.start;
    while (k + simd.lane_count <= range.end) : (k += simd.lane_count) {
        const lanes = [simd.lane_count]usize{
            indices[k], indices[k + 1], indices[k + 2], indices[k + 3],
        };

        const staleness = simd.gatherFloat4(slice.staleness, lanes);
        const next_staleness = simd.clampFloat4(simd.addFloat4(staleness, one), zero, max_staleness);
        simd.scatterFloat4(slice.staleness, lanes, next_staleness);

        const familiarity = simd.gatherFloat4(slice.familiarity, lanes);
        const next_familiarity = simd.lerpFloat4(familiarity, zero, decay_rate);
        simd.scatterFloat4(slice.familiarity, lanes, next_familiarity);

        inline for (0..simd.lane_count) |lane| {
            ageRingForRow(slice, lanes[lane]);
        }
    }

    while (k < range.end) : (k += 1) {
        const index: usize = indices[k];
        slice.staleness[index] = math.clamp(slice.staleness[index] + 1.0, 0, max_ai_memory_staleness);
        slice.familiarity[index] = math.lerp(slice.familiarity[index], 0.0, ai_memory_familiarity_decay_rate);
        ageRingForRow(slice, index);
    }
}

comptime {
    // The dense age+clamp step below loads/stores the whole ring as one
    // `Float4`, so the ring width must match the SIMD lane count exactly.
    if (ai_memory_ring_capacity != simd.lane_count) @compileError("ai_memory_ring_capacity must equal simd.lane_count for ageRingForRow's vectorized aging");
}

/// Ages one row's ring contacts by one step: age + 1 clamped to
/// `max_ai_memory_staleness` is dense uniform float math over the row's fixed
/// `ai_memory_ring_capacity`-wide array (== `simd.lane_count`), so it runs as
/// one `Float4` op covering all slots, aged or not — harmless for an
/// already-empty slot since `upsertRingContact` always resets a reused slot's
/// age to 0 anyway. The remaining branchy part, clearing a slot's entity to
/// `EntityId.invalid` once its aged value reaches `max_ai_memory_staleness`
/// (an expired contact stays a slot the ring can reuse; expiry is purely
/// columnar, no event is emitted), stays a scalar pass over the resulting ages.
fn ageRingForRow(slice: *AiMemorySlice, index: usize) void {
    const ring_entity = &slice.ring_entity[index];
    const ring_age = &slice.ring_age[index];

    const aged = simd.clampFloat4(
        simd.addFloat4(simd.loadFloat4(ring_age), simd.splatFloat4(1.0)),
        simd.splatFloat4(0.0),
        simd.splatFloat4(max_ai_memory_staleness),
    );
    simd.storeFloat4(ring_age, aged);

    for (0..ai_memory_ring_capacity) |slot| {
        if (!ring_entity[slot].isValid()) continue;
        if (ring_age[slot] >= max_ai_memory_staleness) ring_entity[slot] = EntityId.invalid;
    }
}

/// Serial scan over this step's `domain_reaction` events for perception
/// acquisitions and losses, run AFTER decay so a same-step reacquisition or
/// loss lands at `staleness == 0` rather than `1`.
fn refreshFromEvents(
    data: *const DataSystem,
    memory_slice: *AiMemorySlice,
    perception_slice: ConstPerceptionSlice,
    frame: *SimulationFrame,
) void {
    for (frame.events.mergedItems()) |event| {
        if (event.stage != .domain_reaction) continue;
        switch (event.payload) {
            .entity_perceived => |perceived| {
                applyPerceivedEvent(data, memory_slice, perception_slice, perceived);
            },
            .entity_lost => |lost| {
                applyLostEvent(data, memory_slice, perception_slice, lost);
            },
            else => {},
        }
    }
}

fn applyPerceivedEvent(
    data: *const DataSystem,
    memory_slice: *AiMemorySlice,
    perception_slice: ConstPerceptionSlice,
    perceived: EntityPerceivedEvent,
) void {
    const memory_index = data.aiMemoryDenseIndex(perceived.observer) orelse return;
    const perception_index = data.aiPerceptionDenseIndex(perceived.observer) orelse return;
    const last_seen_x = perception_slice.last_seen_x[perception_index];
    const last_seen_y = perception_slice.last_seen_y[perception_index];

    memory_slice.last_known_target[memory_index] = perceived.target;
    memory_slice.last_known_x[memory_index] = last_seen_x;
    memory_slice.last_known_y[memory_index] = last_seen_y;
    memory_slice.staleness[memory_index] = 0;
    upsertRingContact(memory_slice, memory_index, perceived.target, last_seen_x, last_seen_y);
}

/// On loss: snapshot perception's frozen `last_seen_*` into `last_known_*` and
/// reset `staleness` to 0 so it climbs from the loss step (not from first
/// sight). Perception freezes `last_seen_*` when `target_visible` becomes
/// false; identity-swap pairs this with a following `entity_perceived` that
/// retargets `last_known_target` in the same event pass.
fn applyLostEvent(
    data: *const DataSystem,
    memory_slice: *AiMemorySlice,
    perception_slice: ConstPerceptionSlice,
    lost: EntityLostEvent,
) void {
    const memory_index = data.aiMemoryDenseIndex(lost.observer) orelse return;
    const perception_index = data.aiPerceptionDenseIndex(lost.observer) orelse return;
    // Only snapshot when the lost identity is (or becomes) the remembered one;
    // skip if memory already tracks a different target.
    const remembered = memory_slice.last_known_target[memory_index];
    if (remembered.isValid() and !remembered.matches(lost.target.index, lost.target.generation)) return;

    const last_seen_x = perception_slice.last_seen_x[perception_index];
    const last_seen_y = perception_slice.last_seen_y[perception_index];
    memory_slice.last_known_target[memory_index] = lost.target;
    memory_slice.last_known_x[memory_index] = last_seen_x;
    memory_slice.last_known_y[memory_index] = last_seen_y;
    memory_slice.staleness[memory_index] = 0;
}

const VisibleJob = struct {
    memory: AiMemorySlice,
    perception: ConstPerceptionSlice,
    rows: []const u32,
    perception_rows: []const u32,
    /// Dispatched range count; asserted against `range.index` at job entry.
    range_count: usize = 0,
};

// The visibility pass over one range of the ascending member rows: each row reads the
// post-event state and writes only itself. Scalar: a branchy ring upsert.
fn visibleJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *VisibleJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.rows.len and job.perception_rows.len == job.rows.len);
    refreshVisibleTargets(&job.memory, job.perception, job.rows[range.start..range.end], job.perception_rows[range.start..range.end]);
}

/// For each gathered memory row still reporting the same visible identity as
/// `last_known_target`: keep `last_known_x/y` in lockstep with perception
/// `last_seen_*`, hold `staleness` at 0, raise familiarity, and refresh the
/// matching ring contact. Runs after event refresh so a same-step acquire
/// already has `last_known_target` set before this pass. `perception_rows[k]` is
/// the perception row of `memory_dense_indices[k]`'s entity.
fn refreshVisibleTargets(
    memory_slice: *AiMemorySlice,
    perception_slice: ConstPerceptionSlice,
    memory_dense_indices: []const u32,
    perception_rows: []const u32,
) void {
    for (memory_dense_indices, perception_rows) |memory_index_u32, perception_index_u32| {
        const memory_index: usize = memory_index_u32;
        const perception_index: usize = perception_index_u32;
        if (!perception_slice.target_visible[perception_index]) continue;
        const threat = perception_slice.nearest_threat[perception_index];
        if (!threat.isValid()) continue;
        const last = memory_slice.last_known_target[memory_index];
        if (!last.matches(threat.index, threat.generation)) continue;

        const last_seen_x = perception_slice.last_seen_x[perception_index];
        const last_seen_y = perception_slice.last_seen_y[perception_index];
        memory_slice.last_known_x[memory_index] = last_seen_x;
        memory_slice.last_known_y[memory_index] = last_seen_y;
        memory_slice.staleness[memory_index] = 0;
        memory_slice.familiarity[memory_index] = math.clamp(
            memory_slice.familiarity[memory_index] + ai_memory_familiarity_gain_rate,
            0,
            max_ai_memory_familiarity,
        );
        upsertRingContact(memory_slice, memory_index, threat, last_seen_x, last_seen_y);
    }
}

/// Dedup-scans the ring for `target`: an existing contact updates in place
/// (position + `age = 0`, write cursor untouched); otherwise the contact is
/// written at `ring_next_slot` and the cursor advances mod capacity —
/// oldest-first overwrite once the ring is full.
fn upsertRingContact(memory_slice: *AiMemorySlice, index: usize, target: EntityId, x: f32, y: f32) void {
    const ring_entity = &memory_slice.ring_entity[index];
    const ring_x = &memory_slice.ring_x[index];
    const ring_y = &memory_slice.ring_y[index];
    const ring_age = &memory_slice.ring_age[index];

    for (0..ai_memory_ring_capacity) |slot| {
        if (!ring_entity[slot].matches(target.index, target.generation)) continue;
        ring_x[slot] = x;
        ring_y[slot] = y;
        ring_age[slot] = 0;
        return;
    }

    const cursor: usize = memory_slice.ring_next_slot[index];
    ring_entity[cursor] = target;
    ring_x[cursor] = x;
    ring_y[cursor] = y;
    ring_age[cursor] = 0;
    memory_slice.ring_next_slot[index] = @intCast((cursor + 1) % ai_memory_ring_capacity);
}

const testing = std.testing;

fn addAgentWithPerceptionAndMemory(
    data: *DataSystem,
    x: f32,
    y: f32,
    perception: @import("../data_system.zig").AiPerception,
    memory: @import("../data_system.zig").AiMemory,
) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{ .position = .{ .x = x, .y = y }, .previous_position = .{ .x = x, .y = y } });
    try data.setAiAgent(entity, .{});
    try data.setAiPerception(entity, perception);
    try data.setAiMemory(entity, memory);
    return entity;
}

fn appendPerceivedEvent(frame: *SimulationFrame, observer: EntityId, target: EntityId) !void {
    try frame.events.appendRequired(.{ .stage = .domain_reaction, .payload = .{ .entity_perceived = .{ .observer = observer, .target = target } } });
}

fn appendLostEvent(frame: *SimulationFrame, observer: EntityId, target: EntityId) !void {
    try frame.events.appendRequired(.{ .stage = .domain_reaction, .payload = .{ .entity_lost = .{ .observer = observer, .target = target } } });
}

// `AiMemorySystem.update` inline as one range: a thread system with no workers.
fn updateInline(system: *AiMemorySystem, ai_agents: ConstAiAgentSlice, data: *DataSystem, frame: *SimulationFrame, config: AiMemoryConfig) !AiMemoryStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0, .items_per_range = std.math.maxInt(u32) });
    defer threads.deinit();
    return system.update(ai_agents, data, frame, &threads, config);
}

const data_test_support = @import("../data_system/test_support.zig");

test "AiMemorySystem refreshes from a perception-acquired event and snapshots on lost" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const observer = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{ .last_seen_x = 42, .last_seen_y = 7 }, .{});
    const target = try data.createEntity();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);
    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, target);

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();

    _ = try sys.update(data.aiAgentSliceConst(), &data, &frame, &threads, .{});

    const memory = data_test_support.aiMemory(&data, observer).?;
    try testing.expectEqual(target, memory.last_known_target);
    try testing.expectEqual(@as(f32, 42), memory.last_known_x);
    try testing.expectEqual(@as(f32, 7), memory.last_known_y);
    try testing.expectEqual(@as(f32, 0), memory.staleness);
    try testing.expectEqual(target, memory.ring[0].entity);

    // Lost event snapshots perception last_seen and resets staleness to 0.
    const observer2 = try addAgentWithPerceptionAndMemory(
        &data,
        10,
        10,
        .{ .last_seen_x = 99, .last_seen_y = 11 },
        .{ .last_known_target = target, .last_known_x = 1, .last_known_y = 2, .staleness = 5 },
    );
    frame.beginStep();
    try appendLostEvent(&frame, observer2, target);
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    const lost_memory = data_test_support.aiMemory(&data, observer2).?;
    try testing.expectEqual(target, lost_memory.last_known_target);
    try testing.expectEqual(@as(f32, 99), lost_memory.last_known_x);
    try testing.expectEqual(@as(f32, 11), lost_memory.last_known_y);
    try testing.expectEqual(@as(f32, 0), lost_memory.staleness);
}

test "AiMemorySystem continuous visibility refreshes last_known to latest last_seen, not first sight" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const target = try data.createEntity();
    const observer = try addAgentWithPerceptionAndMemory(
        &data,
        0,
        0,
        .{ .target_visible = true, .nearest_threat = target, .last_seen_x = 10, .last_seen_y = 0 },
        .{},
    );

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    // Acquire at first-seen position.
    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, target);
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expectEqual(@as(f32, 10), data_test_support.aiMemory(&data, observer).?.last_known_x);
    try testing.expectEqual(@as(f32, 0), data_test_support.aiMemory(&data, observer).?.staleness);

    // Moving hostile under continuous LOS: last_seen advances; memory must track it.
    const positions = [_]f32{ 20, 35, 50 };
    for (positions) |x| {
        const pidx = data.aiPerceptionDenseIndex(observer).?;
        var perception = data.perceptionSlice();
        perception.target_visible[pidx] = true;
        perception.nearest_threat[pidx] = target;
        perception.last_seen_x[pidx] = x;
        perception.last_seen_y[pidx] = x * 0.5;
        frame.beginStep();
        // No transition events while still visible with the same identity.
        _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
        const memory = data_test_support.aiMemory(&data, observer).?;
        try testing.expectEqual(target, memory.last_known_target);
        try testing.expectEqual(x, memory.last_known_x);
        try testing.expectEqual(x * 0.5, memory.last_known_y);
        try testing.expectEqual(@as(f32, 0), memory.staleness);
    }

    // Drop LOS: snapshot last_seen into last_known, staleness climbs from 0.
    const final_x: f32 = 50;
    const final_y: f32 = 25;
    {
        const pidx = data.aiPerceptionDenseIndex(observer).?;
        var perception = data.perceptionSlice();
        perception.target_visible[pidx] = false;
        perception.nearest_threat[pidx] = EntityId.invalid;
        perception.last_seen_x[pidx] = final_x;
        perception.last_seen_y[pidx] = final_y;
    }
    frame.beginStep();
    try appendLostEvent(&frame, observer, target);
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    var memory = data_test_support.aiMemory(&data, observer).?;
    try testing.expectEqual(target, memory.last_known_target);
    try testing.expectEqual(final_x, memory.last_known_x);
    try testing.expectEqual(final_y, memory.last_known_y);
    try testing.expectEqual(@as(f32, 0), memory.staleness);

    frame.beginStep();
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    memory = data_test_support.aiMemory(&data, observer).?;
    try testing.expectEqual(final_x, memory.last_known_x);
    try testing.expectEqual(final_y, memory.last_known_y);
    try testing.expectEqual(@as(f32, 1), memory.staleness);
}

test "AiMemorySystem familiarity rises under sustained same-identity visibility" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const target = try data.createEntity();
    const observer = try addAgentWithPerceptionAndMemory(
        &data,
        0,
        0,
        .{ .target_visible = true, .nearest_threat = target, .last_seen_x = 5, .last_seen_y = 5 },
        .{ .familiarity = 0 },
    );

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, target);
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    const after_acquire = data_test_support.aiMemory(&data, observer).?.familiarity;
    try testing.expect(after_acquire > 0);

    var prev = after_acquire;
    var step: usize = 0;
    while (step < 8) : (step += 1) {
        frame.beginStep();
        _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
        const familiarity = data_test_support.aiMemory(&data, observer).?.familiarity;
        try testing.expect(familiarity > prev);
        prev = familiarity;
    }
    try testing.expect(prev > after_acquire);
    try testing.expect(prev <= max_ai_memory_familiarity);

    // Idle memory (no visibility) must not hold novelty constant: familiarity decays.
    const idle = try addAgentWithPerceptionAndMemory(&data, 20, 20, .{}, .{ .familiarity = 0.5 });
    const idle_before = data_test_support.aiMemory(&data, idle).?.familiarity;
    frame.beginStep();
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expect(data_test_support.aiMemory(&data, idle).?.familiarity < idle_before);
}

test "AiMemorySystem decay is byte-identical between threaded and serial paths" {
    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var data_a = DataSystem.init(testing.allocator);
    defer data_a.deinit();
    var data_b = DataSystem.init(testing.allocator);
    defer data_b.deinit();
    _ = try addAgentWithPerceptionAndMemory(&data_a, 0, 0, .{}, .{ .staleness = 10, .familiarity = 0.5 });
    _ = try addAgentWithPerceptionAndMemory(&data_a, 5, 5, .{}, .{ .staleness = 20, .familiarity = 0.9 });
    _ = try addAgentWithPerceptionAndMemory(&data_b, 0, 0, .{}, .{ .staleness = 10, .familiarity = 0.5 });
    _ = try addAgentWithPerceptionAndMemory(&data_b, 5, 5, .{}, .{ .staleness = 20, .familiarity = 0.9 });

    var frame_a = SimulationFrame.init(testing.allocator);
    defer frame_a.deinit();
    try frame_a.reserveStreams(1, 0, 0, 0, 0, 0);
    var frame_b = SimulationFrame.init(testing.allocator);
    defer frame_b.deinit();
    try frame_b.reserveStreams(1, 0, 0, 0, 0, 0);

    var sys_a = AiMemorySystem.init(testing.allocator);
    defer sys_a.deinit();
    var sys_b = AiMemorySystem.init(testing.allocator);
    defer sys_b.deinit();

    for (0..5) |_| {
        frame_a.beginStep();
        _ = try updateInline(&sys_a, data_a.aiAgentSliceConst(), &data_a, &frame_a, .{});
        frame_b.beginStep();
        _ = try sys_b.update(data_b.aiAgentSliceConst(), &data_b, &frame_b, &threads, .{});
    }

    const slice_a = data_a.aiMemorySliceConst();
    const slice_b = data_b.aiMemorySliceConst();
    try testing.expectEqualSlices(f32, slice_a.staleness, slice_b.staleness);
    try testing.expectEqualSlices(f32, slice_a.familiarity, slice_b.familiarity);
    for (slice_a.ring_entity, slice_b.ring_entity) |ring_a, ring_b| {
        try testing.expectEqualSlices(EntityId, &ring_a, &ring_b);
    }
}

test "AiMemorySystem ring eviction overwrites oldest slot and repeated target updates in place" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const observer = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{ .last_seen_x = 1, .last_seen_y = 1 }, .{});
    var targets: [5]EntityId = undefined;
    for (&targets) |*t| t.* = try data.createEntity();

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    for (targets[0..4]) |target| {
        frame.beginStep();
        try appendPerceivedEvent(&frame, observer, target);
        _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    }
    var memory = data_test_support.aiMemory(&data, observer).?;
    try testing.expectEqual(@as(u8, 0), memory.ring_next_slot);
    for (targets[0..4], 0..) |target, slot| try testing.expectEqual(target, memory.ring[slot].entity);

    // Repeated target (index 1) updates in place; cursor must not move.
    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, targets[1]);
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    memory = data_test_support.aiMemory(&data, observer).?;
    try testing.expectEqual(@as(u8, 0), memory.ring_next_slot);
    try testing.expectEqual(targets[1], memory.ring[1].entity);
    try testing.expectEqual(@as(f32, 0), memory.ring[1].age);

    // A 5th distinct target overwrites the oldest slot (0) and advances the cursor.
    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, targets[4]);
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    memory = data_test_support.aiMemory(&data, observer).?;
    try testing.expectEqual(targets[4], memory.ring[0].entity);
    try testing.expectEqual(@as(u8, 1), memory.ring_next_slot);
}

test "AiMemorySystem expires a ring contact once its age reaches max staleness" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const observer = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{}, .{});
    const target = try data.createEntity();

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    frame.beginStep();
    try appendPerceivedEvent(&frame, observer, target);
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expectEqual(target, data_test_support.aiMemory(&data, observer).?.ring[0].entity);

    var step: usize = 0;
    while (step < @as(usize, @intFromFloat(max_ai_memory_staleness))) : (step += 1) {
        frame.beginStep();
        _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    }

    try testing.expectEqual(EntityId.invalid, data_test_support.aiMemory(&data, observer).?.ring[0].entity);
}

test "AiMemorySystem freezes an out-of-scope entity's memory row and resumes without a jump on resync" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    _ = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{}, .{ .staleness = 10 });
    _ = try addAgentWithPerceptionAndMemory(&data, 10, 10, .{}, .{ .staleness = 10 });

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 0, 0, 0, 0);

    frame.beginStep();
    const both = [_]u32{ 0, 1 };
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{ .scope_dense_indices = &both });
    try testing.expectEqual(@as(f32, 11), data_test_support.aiMemory(&data, data.aiAgentSliceConst().entities[0]).?.staleness);
    try testing.expectEqual(@as(f32, 11), data_test_support.aiMemory(&data, data.aiAgentSliceConst().entities[1]).?.staleness);

    // Only entity 0 in scope: entity 1's row must stay frozen at 11.
    const only_a = [_]u32{0};
    for (0..3) |_| {
        frame.beginStep();
        _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{ .scope_dense_indices = &only_a });
    }
    try testing.expectEqual(@as(f32, 14), data_test_support.aiMemory(&data, data.aiAgentSliceConst().entities[0]).?.staleness);
    try testing.expectEqual(@as(f32, 11), data_test_support.aiMemory(&data, data.aiAgentSliceConst().entities[1]).?.staleness);

    // Back in scope: resumes from exactly the frozen value, no reset, no catch-up.
    frame.beginStep();
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{ .scope_dense_indices = &both });
    try testing.expectEqual(@as(f32, 12), data_test_support.aiMemory(&data, data.aiAgentSliceConst().entities[1]).?.staleness);
}

test "AiMemorySystem never gathers an entity with AiMemory but no AiPerception" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();

    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{});
    try data.setAiAgent(entity, .{});
    try data.setAiMemory(entity, .{ .staleness = 100 });

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 0, 0, 0, 0);
    frame.beginStep();

    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expectEqual(@as(usize, 0), sys.memory_dense_indices.items.len);
    try testing.expectEqual(@as(usize, 0), sys.memory_dense_indices.items.len);
    try testing.expectEqual(@as(f32, 100), data_test_support.aiMemory(&data, entity).?.staleness);
}

test "AiMemorySystem serial has no steady-state allocation after warmup (FailingAllocator)" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    _ = try addAgentWithPerceptionAndMemory(&data, 0, 0, .{}, .{ .staleness = 5 });

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    try sys.reserve(1);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_allocator = sys.allocator;
    sys.allocator = failing.allocator();
    defer sys.allocator = original_allocator;

    frame.beginStep();
    _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
    try testing.expectEqual(@as(usize, 1), sys.memory_dense_indices.items.len);
}

// Think row `k` of a stride shuffle over `count` rows (37 is coprime with every count the
// tests use, so the shuffle is a permutation).
fn shuffledThinkRows(rows: []u32) void {
    for (rows, 0..) |*row, k| row.* = @intCast(k * 37 % rows.len);
}

test "AiMemorySystem threaded update has no steady-state allocation after warmup (FailingAllocator)" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    // Two order ranges of touched row words, so every stage runs on workers.
    const agent_count = 2 * ai_memory_range_alignment_items * word_bits;
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..agent_count) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try addAgentWithPerceptionAndMemory(&data, fi, 0, .{}, .{ .staleness = 5 });
    }
    var think: [agent_count]u32 = undefined;
    shuffledThinkRows(&think);

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2, .items_per_range = ai_memory_range_alignment_items });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();

    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    const config = AiMemoryConfig{
        .scope_dense_indices = &think,
        .items_per_range = ai_memory_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    };

    try sys.reserve(agent_count);

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    const original_allocator = sys.allocator;
    sys.allocator = failing.allocator();
    defer sys.allocator = original_allocator;

    frame.beginStep();
    _ = try sys.update(data.aiAgentSliceConst(), &data, &frame, &threads, config);
    try testing.expectEqual(agent_count, sys.memory_dense_indices.items.len);
}

test "AiMemorySystem each stage records one sample into its own tuner and none into the shared tuner" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    for (0..64) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try addAgentWithPerceptionAndMemory(&data, fi, 0, .{}, .{ .staleness = 5 });
    }

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    if (threads.workerThreadCount() == 0) return error.SkipZigTest;

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 4, 0, 0, 0, 0);

    frame.beginStep();
    _ = try sys.update(data.aiAgentSliceConst(), &data, &frame, &threads, .{});
    try testing.expectEqual(@as(usize, 64), sys.memory_dense_indices.items.len);
    for ([_]*const AdaptiveWorkTuner{ &sys.gather_tuner, &sys.order_tuner, &sys.decay_tuner, &sys.visible_tuner }) |tuner| {
        try testing.expectEqual(@as(usize, 1), tuner.sample_count);
        try testing.expect(tuner.last_request != null);
    }
    try testing.expectEqual(@as(usize, 0), threads.adaptive_tuner.sample_count);
    try testing.expect(threads.adaptive_tuner.last_request == null);
}

const order_fixture_agents: usize = 200;
const order_fixture_steps: usize = 3;

// 200 AI agents (four mask words, not a multiple of 4 or 16) whose perception and memory
// rows are added in reverse creation order, so memory rows differ from AI rows. Every 7th
// agent lacks perception and every 11th lacks memory. State varies by row: ring contacts
// one step from expiry, visible targets matching or not the remembered one, and spread
// staleness and familiarity.
const OrderFixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    agents: [order_fixture_agents]EntityId,
    targets: [3]EntityId,

    fn init() !OrderFixture {
        var data = DataSystem.init(testing.allocator);
        errdefer data.deinit();
        var frame = SimulationFrame.init(testing.allocator);
        errdefer frame.deinit();
        try frame.reserveStreams(1, 8, 0, 0, 0, 0);

        var targets: [3]EntityId = undefined;
        for (&targets) |*target| target.* = try data.createEntity();
        var agents: [order_fixture_agents]EntityId = undefined;
        for (&agents) |*agent| {
            agent.* = try data.createEntity();
            try data.setAiAgent(agent.*, .{});
        }
        var index = order_fixture_agents;
        while (index > 0) {
            index -= 1;
            const seen = targets[index % targets.len];
            const at: f32 = @floatFromInt(index);
            if (index % 7 != 0) try data.setAiPerception(agents[index], .{
                .target_visible = index % 5 == 0,
                .nearest_threat = if (index % 5 == 0) seen else EntityId.invalid,
                .last_seen_x = at,
                .last_seen_y = at * 0.5,
            });
            if (index % 11 != 0) {
                var memory = @import("../data_system.zig").AiMemory{
                    .last_known_target = if (index % 10 == 0) seen else EntityId.invalid,
                    .staleness = @floatFromInt(index % 13),
                    .familiarity = @as(f32, @floatFromInt(index % 10)) / 10.0,
                };
                if (index % 4 == 0) {
                    memory.ring[0] = .{ .entity = seen, .x = at, .y = at, .age = max_ai_memory_staleness - 1 };
                    memory.ring[1] = .{ .entity = targets[(index + 1) % targets.len], .x = 1, .y = 2, .age = @floatFromInt(index % 50) };
                    memory.ring_next_slot = 2;
                }
                try data.setAiMemory(agents[index], memory);
            }
        }
        return .{ .data = data, .frame = frame, .agents = agents, .targets = targets };
    }

    fn deinit(self: *OrderFixture) void {
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    // Step `step`'s events: an acquisition, a loss, and an identity swap (lost, then
    // perceived) on rows that move with the step.
    fn beginStep(self: *OrderFixture, step: usize) !void {
        self.frame.beginStep();
        const n = order_fixture_agents;
        try appendPerceivedEvent(&self.frame, self.agents[(step * 17 + 3) % n], self.targets[step % 3]);
        try appendLostEvent(&self.frame, self.agents[(step * 29 + 5) % n], self.targets[(step + 1) % 3]);
        const swapped = self.agents[(step * 41 + 10) % n];
        try appendLostEvent(&self.frame, swapped, self.targets[0]);
        try appendPerceivedEvent(&self.frame, swapped, self.targets[2]);
    }

    // Steps the fixture over `think` (null: every AI row), serial without `threads`; returns
    // the summed processed counts and the last step's stats.
    fn run(self: *OrderFixture, sys: *AiMemorySystem, think: ?[]const u32, threads: ?*ThreadSystem, config: AiMemoryConfig) !OrderRun {
        var result = OrderRun{};
        var step_config = config;
        step_config.scope_dense_indices = think;
        for (0..order_fixture_steps) |step| {
            try self.beginStep(step);
            const ai = self.data.aiAgentSliceConst();
            const stats = if (threads) |ts| try sys.update(ai, &self.data, &self.frame, ts, step_config) else try updateInline(sys, ai, &self.data, &self.frame, step_config);
            result.processed += sys.memory_dense_indices.items.len;
            result.last = stats;
        }
        return result;
    }
};

const OrderRun = struct {
    processed: usize = 0,
    last: AiMemoryStats = .{},
};

// Every memory column of `a` and `b` is bitwise equal.
fn expectSameMemory(a: *const DataSystem, b: *const DataSystem) !void {
    const left = a.aiMemorySliceConst();
    const right = b.aiMemorySliceConst();
    try testing.expectEqualSlices(EntityId, left.entities, right.entities);
    try testing.expectEqualSlices(EntityId, left.last_known_target, right.last_known_target);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(left.last_known_x), std.mem.sliceAsBytes(right.last_known_x));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(left.last_known_y), std.mem.sliceAsBytes(right.last_known_y));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(left.staleness), std.mem.sliceAsBytes(right.staleness));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(left.familiarity), std.mem.sliceAsBytes(right.familiarity));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(left.ring_x), std.mem.sliceAsBytes(right.ring_x));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(left.ring_y), std.mem.sliceAsBytes(right.ring_y));
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(left.ring_age), std.mem.sliceAsBytes(right.ring_age));
    try testing.expectEqualSlices(u8, left.ring_next_slot, right.ring_next_slot);
    for (left.ring_entity, right.ring_entity) |ring_a, ring_b| try testing.expectEqualSlices(EntityId, &ring_a, &ring_b);
}

fn expectMasksClear(sys: *const AiMemorySystem) !void {
    try testing.expectEqual(@as(usize, 0), sys.member_words.count());
    for (&sys.summary_levels) |*level| try testing.expectEqual(@as(usize, 0), level.count());
}

test "AiMemorySystem results are bit-identical for any think-set order" {
    var ascending: [order_fixture_agents]u32 = undefined;
    for (&ascending, 0..) |*row, k| row.* = @intCast(k);
    var reversed: [order_fixture_agents]u32 = undefined;
    for (&reversed, 0..) |*row, k| row.* = @intCast(order_fixture_agents - 1 - k);
    var shuffled: [order_fixture_agents]u32 = undefined;
    shuffledThinkRows(&shuffled);

    var reference = try OrderFixture.init();
    defer reference.deinit();
    var reference_sys = AiMemorySystem.init(testing.allocator);
    defer reference_sys.deinit();
    const expected = try reference.run(&reference_sys, &ascending, null, .{});
    try testing.expect(expected.processed > 0);

    for ([_][]const u32{ &reversed, &shuffled }) |think| {
        var fixture = try OrderFixture.init();
        defer fixture.deinit();
        var sys = AiMemorySystem.init(testing.allocator);
        defer sys.deinit();
        const got = try fixture.run(&sys, think, null, .{});
        try testing.expectEqual(expected.processed, got.processed);
        try expectSameMemory(&reference.data, &fixture.data);
    }

    // A subset in shuffled order against the same subset ascending.
    var subset_ascending: [order_fixture_agents / 2]u32 = undefined;
    for (&subset_ascending, 0..) |*row, k| row.* = @intCast(2 * k);
    var subset_shuffled: [order_fixture_agents / 2]u32 = undefined;
    for (&subset_shuffled, 0..) |*row, k| row.* = subset_ascending[k * 37 % subset_ascending.len];

    var subset_reference = try OrderFixture.init();
    defer subset_reference.deinit();
    var subset_reference_sys = AiMemorySystem.init(testing.allocator);
    defer subset_reference_sys.deinit();
    const subset_expected = try subset_reference.run(&subset_reference_sys, &subset_ascending, null, .{});

    var subset = try OrderFixture.init();
    defer subset.deinit();
    var subset_sys = AiMemorySystem.init(testing.allocator);
    defer subset_sys.deinit();
    const subset_got = try subset.run(&subset_sys, &subset_shuffled, null, .{});
    try testing.expectEqual(subset_expected.processed, subset_got.processed);
    try expectSameMemory(&subset_reference.data, &subset.data);
}

test "AiMemorySystem serial equals threaded across range sizes and worker counts" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var think: [order_fixture_agents]u32 = undefined;
    shuffledThinkRows(&think);

    var serial = try OrderFixture.init();
    defer serial.deinit();
    var serial_sys = AiMemorySystem.init(testing.allocator);
    defer serial_sys.deinit();
    const expected = try serial.run(&serial_sys, &think, null, .{});

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 4 });
    defer threads.deinit();

    for (1..5) |workers| {
        // 1 and 2 split every stage, the order stage's few touched words included; 16 and
        // up keep the order stage in one range.
        for ([_]usize{ 1, 2, 16, 64, 256 }) |items_per_range| {
            var fixture = try OrderFixture.init();
            defer fixture.deinit();
            var sys = AiMemorySystem.init(testing.allocator);
            defer sys.deinit();
            const got = try fixture.run(&sys, &think, &threads, .{
                .items_per_range = items_per_range,
                .max_worker_threads = workers,
                .adaptive = false,
            });
            try testing.expectEqual(expected.processed, got.processed);
            try expectSameMemory(&serial.data, &fixture.data);
            try expectMasksClear(&sys);
        }
    }
}

test "AiMemorySystem decay list is the think set's memory rows ascending, and the member masks clear" {
    var fixture = try OrderFixture.init();
    defer fixture.deinit();
    var think: [order_fixture_agents]u32 = undefined;
    shuffledThinkRows(&think);

    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(testing.allocator);
    const ai = fixture.data.aiAgentSliceConst();
    for (think) |row| {
        const entity = ai.entities[row];
        if (fixture.data.aiPerceptionDenseIndex(entity) == null) continue;
        const memory_row = fixture.data.aiMemoryDenseIndex(entity) orelse continue;
        try expected.append(testing.allocator, @intCast(memory_row));
    }
    std.mem.sortUnstable(u32, expected.items, {}, std.sort.asc(u32));

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    const config = AiMemoryConfig{ .scope_dense_indices = &think, .items_per_range = ai_memory_range_alignment_items, .adaptive = false };

    try fixture.beginStep(0);
    _ = try sys.update(ai, &fixture.data, &fixture.frame, &threads, config);
    try testing.expectEqualSlices(u32, expected.items, sys.memory_dense_indices.items);
    for (sys.memory_dense_indices.items[1..], sys.memory_dense_indices.items[0 .. sys.memory_dense_indices.items.len - 1]) |row, previous| try testing.expect(row > previous);
    try expectMasksClear(&sys);

    try fixture.beginStep(1);
    _ = try updateInline(&sys, ai, &fixture.data, &fixture.frame, config);
    try testing.expectEqualSlices(u32, expected.items, sys.memory_dense_indices.items);
    try expectMasksClear(&sys);
}

test "AiMemorySystem growth past reserve orders correctly and counts once" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const agent_count: usize = 300;
    for (0..agent_count) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try addAgentWithPerceptionAndMemory(&data, fi, 0, .{}, .{ .staleness = 5 });
    }
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 0, 0, 0, 0);

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(8);
    try testing.expectEqual(@as(u64, 0), sys.scratch_grown);

    for (0..2) |_| {
        frame.beginStep();
        _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
        try testing.expectEqual(agent_count, sys.memory_dense_indices.items.len);
        try testing.expectEqual(agent_count, sys.memory_dense_indices.items.len);
        for (sys.memory_dense_indices.items, 0..) |row, rank| try testing.expectEqual(@as(u32, @intCast(rank)), row);
        try expectMasksClear(&sys);
        try testing.expectEqual(@as(u64, 1), sys.scratch_grown);
    }
}

// A memory row's stand-in perception row in the order tests: distinct from the row.
fn testPerceptionRow(memory_row: u32) u32 {
    return memory_row ^ 0x5555_5555;
}

test "AiMemorySystem scratch growth fails each allocation as OutOfMemory with state intact, and the retry orders every row" {
    var data = DataSystem.init(testing.allocator);
    defer data.deinit();
    const agent_count: usize = 300;
    for (0..agent_count) |i| {
        const fi: f32 = @floatFromInt(i);
        _ = try addAgentWithPerceptionAndMemory(&data, fi, 0, .{}, .{ .staleness = @floatFromInt(i % 7) });
    }
    var frame = SimulationFrame.init(testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 0, 0, 0, 0);

    var staleness_before: [agent_count]f32 = undefined;
    var failures: usize = 0;
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var sys = AiMemorySystem.init(testing.allocator);
        defer sys.deinit();
        try sys.reserve(8);
        const think_limit = sys.reserved_think_rows;
        const row_limit = sys.reserved_memory_rows;
        @memcpy(&staleness_before, data.aiMemorySliceConst().staleness);

        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        sys.allocator = failing.allocator();
        frame.beginStep();
        const failed = updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
        sys.allocator = testing.allocator;
        // Past the last allocation: the sweep covered every one.
        if (!failing.has_induced_failure) {
            _ = try failed;
            break;
        }
        failures += 1;
        try testing.expectError(error.OutOfMemory, failed);
        try testing.expectEqual(@as(u64, 0), sys.scratch_grown);
        try testing.expectEqual(think_limit, sys.reserved_think_rows);
        try testing.expectEqual(row_limit, sys.reserved_memory_rows);
        try expectMasksClear(&sys);
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(&staleness_before), std.mem.sliceAsBytes(data.aiMemorySliceConst().staleness));

        frame.beginStep();
        _ = try updateInline(&sys, data.aiAgentSliceConst(), &data, &frame, .{});
        try testing.expectEqual(agent_count, sys.memory_dense_indices.items.len);
        for (sys.memory_dense_indices.items, 0..) |row, rank| try testing.expectEqual(@as(u32, @intCast(rank)), row);
        try expectMasksClear(&sys);
        try testing.expectEqual(@as(u64, 1), sys.scratch_grown);
        for (staleness_before, data.aiMemorySliceConst().staleness) |before, after| try testing.expectEqual(before + 1, after);
    }
    // At least the five per-row lists, each grown far past `reserve(8)`, allocate.
    try testing.expect(failures >= 5);
}

// Marks `memory_rows` (any order) in a store of `row_count` rows, orders them, and checks the
// list is `expected` ascending over `expected_words` touched row words, each beside its
// carried perception row, then unmarks.
fn expectOrdered(sys: *AiMemorySystem, memory_rows: []const u32, row_count: usize, dispatch: Dispatch, expected: []const u32, expected_words: usize) !BatchStats {
    sys.think_rows.items.len = memory_rows.len;
    @memcpy(sys.think_rows.items, memory_rows);
    sys.think_perception_rows.items.len = memory_rows.len;
    for (sys.think_perception_rows.items, memory_rows) |*perception_row, row| perception_row.* = testPerceptionRow(row);
    try testing.expectEqual(expected.len, sys.mark(row_count));
    sys.collectTouchedWords(row_count);
    try testing.expectEqual(expected_words, sys.touched_words.items.len);
    const batch = sys.orderMembers(row_count, dispatch);
    try testing.expectEqualSlices(u32, expected, sys.memory_dense_indices.items);
    try testing.expectEqual(expected.len, sys.perception_dense_indices.items.len);
    for (sys.memory_dense_indices.items, sys.perception_dense_indices.items) |row, perception_row| try testing.expectEqual(testPerceptionRow(row), perception_row);
    sys.unmark();
    try expectMasksClear(sys);
    return batch;
}

test "AiMemorySystem order stage runs over touched row words, ascending across summary levels" {
    // Past the rows one word of summary level 1 covers, so the walk crosses a word
    // boundary at every level this store fills.
    const row_count: usize = word_bits * word_bits * word_bits + 37_856;
    var expected: std.ArrayList(u32) = .empty;
    defer expected.deinit(testing.allocator);
    // A scattered stride, one full word, and each level's word boundaries.
    var row: usize = 0;
    while (row < row_count) : (row += 97) try expected.append(testing.allocator, @intCast(row));
    for (2 * word_bits..3 * word_bits) |dense| try expected.append(testing.allocator, @intCast(dense));
    for ([_]usize{ word_bits - 1, word_bits, word_bits * word_bits - 1, word_bits * word_bits, word_bits * word_bits * word_bits - 1, word_bits * word_bits * word_bits, row_count - 1 }) |edge| {
        if (std.mem.indexOfScalar(u32, expected.items, @intCast(edge)) == null) try expected.append(testing.allocator, @intCast(edge));
    }
    std.mem.sortUnstable(u32, expected.items, {}, std.sort.asc(u32));
    var expected_words: usize = 0;
    for (expected.items, 0..) |member, rank| {
        if (rank == 0 or member / word_bits != expected.items[rank - 1] / word_bits) expected_words += 1;
    }

    // The think set in a stride shuffle of the ascending rows.
    try testing.expect(std.math.gcd(37, expected.items.len) == 1);
    const memory_rows = try testing.allocator.alloc(u32, expected.items.len);
    defer testing.allocator.free(memory_rows);
    for (memory_rows, 0..) |*think_row, k| think_row.* = expected.items[k * 37 % expected.items.len];

    var sys = AiMemorySystem.init(testing.allocator);
    defer sys.deinit();
    try sys.reserve(row_count);

    var threads = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();
    // Serial: the production stage with no worker allowed, inline on the caller.
    const inline_threads = MemoryThreads{ .thread_system = &threads, .config = .{ .max_worker_threads = 0, .adaptive = false } };
    const serial = try expectOrdered(&sys, memory_rows, row_count, inline_threads.stage(&sys.order_tuner), expected.items, expected_words);
    try testing.expectEqual(expected_words, serial.item_count);
    const stage_threads = MemoryThreads{ .thread_system = &threads, .config = .{
        .items_per_range = ai_memory_range_alignment_items,
        .max_worker_threads = 3,
        .adaptive = false,
    } };
    const threaded = try expectOrdered(&sys, memory_rows, row_count, stage_threads.stage(&sys.order_tuner), expected.items, expected_words);
    // The stage's items are the touched words, never the store's rows.
    try testing.expectEqual(expected_words, threaded.item_count);
    try testing.expect(threaded.range_count > 1);
    if (threads.workerThreadCount() > 0) try testing.expect(!threaded.ran_inline);

    // A sparse think set keeps the item count at its own words as the store grows.
    const sparse = [_]u32{ @intCast(row_count - 1), 5, 3 };
    const sparse_sorted = [_]u32{ 3, 5, @intCast(row_count - 1) };
    const sparse_batch = try expectOrdered(&sys, &sparse, row_count, stage_threads.stage(&sys.order_tuner), &sparse_sorted, 2);
    try testing.expectEqual(@as(usize, 2), sparse_batch.item_count);
}
