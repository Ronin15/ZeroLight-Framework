// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Collision response over the step's merged contact stream. `gather` (over contacts)
//! classifies each contact, resolves the movement row of each response intent, writes
//! its range's windows of intents, triggers, and observer contacts, and runs the intent
//! math. When the gather runs on workers, each range groups its placed intents into
//! 16-row movement blocks on that worker's direct block table, and one place range
//! merges those runs; `apply` then writes each occupied block on one worker. When the
//! gather runs inline, including no worker threads, each range applies its own window
//! before it returns. Either way each movement row receives its intents in contact
//! order, so the result is independent of the partition. The main thread streams the
//! trigger windows and compacts the observer windows in range order.

const std = @import("std");
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const AdaptiveWorkProfile = @import("../../app/thread_system.zig").AdaptiveWorkProfile;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const inlineBatch = @import("../../app/thread_system.zig").inlineBatch;
const maxRangeCount = @import("../../app/thread_system.zig").maxRangeCount;
const setRowCount = @import("../../app/thread_system.zig").setRowCount;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;
const contact_query = @import("../contact_query.zig");
const CollisionResponse = @import("../data_system.zig").CollisionResponse;
const DataSystem = @import("../data_system.zig").DataSystem;
const EntityId = @import("../data_system.zig").EntityId;
const MovementBodySlice = @import("../data_system.zig").MovementBodySlice;
const hot_soa_column_alignment = @import("../data_system.zig").hot_soa_column_alignment;
const CollisionContact = @import("../simulation.zig").CollisionContact;
const CollisionTriggerEvent = @import("../simulation.zig").CollisionTriggerEvent;
const SimulationFrame = @import("../simulation.zig").SimulationFrame;
const math = @import("../../core/math.zig");
const pdq = @import("../../core/sort.zig").pdq;
const simd = @import("../../core/simd.zig");

const collision_response_range_alignment_items: usize = hot_soa_column_alignment / @sizeOf(f32);

// An intent whose entity has no movement body; the apply skips it.
const no_row: u32 = std.math.maxInt(u32);
// Contact and intent indices are u32: a step's contacts must leave room for two intents
// each. Exhausting them needs 2^31 live contacts in one step, so `beginStep` fails it as the
// allocator does.
const max_step_intents: usize = std.math.maxInt(u32);
/// Movement rows one apply item owns. A block is never split across workers.
pub const block_rows: usize = collision_response_range_alignment_items;
const block_row_shift: u6 = 4;
// `BlockSlot` is 16 bytes so a worker region can start on a cache line.
const block_slots_per_line: usize = thread_shared_record_alignment / 16;

fn hotStoreCapacity(min_len: usize) usize {
    return std.mem.alignForwardAnyAlign(usize, min_len, collision_response_range_alignment_items);
}

fn blockId(movement_row: u32) u32 {
    return movement_row >> block_row_shift;
}

fn blockCount(movement_rows: usize) usize {
    // `block_rows >= 1`, so the result fits `usize`.
    return @intCast((@as(u128, movement_rows) + (block_rows - 1)) / block_rows);
}

// Slots per worker so the next worker's first slot does not share a cache line.
fn tableStride(blocks: usize) usize {
    return std.mem.alignForward(usize, blocks, block_slots_per_line);
}

// Main plus one worker per extra cpu: the most participants a pool sized to this
// machine has. A step whose pool is larger grows the table before it dispatches.
fn participantCeiling() usize {
    const cpu = std.Thread.getCpuCount() catch 1;
    return @max(cpu, 1);
}

comptime {
    std.debug.assert(block_rows == 16 and std.math.isPowerOfTwo(block_rows));
    std.debug.assert((1 << block_row_shift) == block_rows);
}

const ResponseIntentKind = enum(u32) {
    solid,
    bounce,
};

const bounce_kind: u32 = @backingInt(ResponseIntentKind.bounce);

// One response intent: the movement row it writes (`no_row` when none) and its inputs;
// `correction_*` and `velocity_scale` come from the intent math.
const IntentRow = struct {
    movement_row: u32,
    normal_x: f32,
    normal_y: f32,
    penetration: f32,
    restitution: f32,
    correction_x: f32,
    correction_y: f32,
    velocity_scale: f32,
    kind: ResponseIntentKind,
};

comptime {
    // A gather range's intent window starts at twice its first contact, a multiple of
    // the alignment, so every window size is whole cache lines in every column.
    for (@typeInfo(IntentRow).@"struct".field_types) |T| {
        std.debug.assert((2 * collision_response_range_alignment_items * @sizeOf(T)) % thread_shared_record_alignment == 0);
    }
    std.debug.assert((collision_response_range_alignment_items * @sizeOf(CollisionTriggerEvent)) % thread_shared_record_alignment == 0);
    std.debug.assert((collision_response_range_alignment_items * @sizeOf(u32)) % thread_shared_record_alignment == 0);
}

const IntentColumns = struct {
    movement_row: []u32,
    normal_x: []f32,
    normal_y: []f32,
    penetration: []f32,
    restitution: []f32,
    correction_x: []f32,
    correction_y: []f32,
    velocity_scale: []f32,
    kind: []ResponseIntentKind,

    fn of(rows: std.MultiArrayList(IntentRow).Slice) IntentColumns {
        return .{
            .movement_row = rows.items(.movement_row),
            .normal_x = rows.items(.normal_x),
            .normal_y = rows.items(.normal_y),
            .penetration = rows.items(.penetration),
            .restitution = rows.items(.restitution),
            .correction_x = rows.items(.correction_x),
            .correction_y = rows.items(.correction_y),
            .velocity_scale = rows.items(.velocity_scale),
            .kind = rows.items(.kind),
        };
    }
};

// The movement columns the apply writes.
const ApplyColumns = struct {
    position_x: []f32,
    position_y: []f32,
    velocity_x: []f32,
    velocity_y: []f32,

    fn of(movement: MovementBodySlice) ApplyColumns {
        return .{
            .position_x = movement.position_x,
            .position_y = movement.position_y,
            .velocity_x = movement.velocity_x,
            .velocity_y = movement.velocity_y,
        };
    }
};

/// The response's stage-threads value: null `items_per_range` with `adaptive` trains each
/// stage's own tuner; an explicit `items_per_range` pins both stages' range size. Apply
/// items are whole blocks, so a range size never splits one.
pub const CollisionResponseConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

// Threading for one update's stages: the thread system and the caller's control config.
const ResponseThreads = @import("../../app/thread_system.zig").StageThreads(CollisionResponseConfig);

pub const CollisionResponseStats = struct {
    contact_count: usize = 0,
    intent_count: usize = 0,
    trigger_count: usize = 0,
    /// Contacts naming the observer this step.
    observer_contact_count: usize = 0,
    perf: Perf = .{},

    /// The gather, place, and apply batches, kept only with `runtime_perf_log.enabled`.
    pub const Perf = if (runtime_perf_log.enabled) struct {
        gather_batch: BatchStats = .{},
        place_batch: BatchStats = .{},
        apply_batch: BatchStats = .{},
    } else struct {};
};

/// Worst-case `collision_triggers` stream capacity for a given `contact_capacity` — this
/// module's own domain knowledge (a trigger event requires an underlying contact, so
/// trigger count can never exceed contact count), not a ratio a caller sizing
/// `SimulationFrame.reserveStreams` should independently guess.
pub fn estimateTriggerCapacity(contact_capacity: usize) usize {
    return contact_capacity;
}

const IndexList = std.array_list.Aligned(u32, .fromByteUnits(thread_shared_record_alignment));
// One index per intent. A gather range records the block ids it claimed; place reuses
// the front as one cursor per gather range.
const ClaimedList = std.array_list.Aligned(usize, .fromByteUnits(thread_shared_record_alignment));
const TriggerList = std.array_list.Aligned(CollisionTriggerEvent, .fromByteUnits(thread_shared_record_alignment));
const BlockSlotList = std.array_list.Aligned(BlockSlot, .fromByteUnits(thread_shared_record_alignment));

// One gather range's counts. When the gather ran on workers, `run_count` is the occupied
// blocks in that range; their `{block_id, begin, count}` runs sit at the range's intent
// window in `range_runs`.
const GatherRow = struct {
    run_count: u32 = 0,
    intents: u32 = 0,
    triggers: u32 = 0,
    observer: u32 = 0,
};

// One gather range's placed intents for one movement block. `begin` is absolute into
// `intent_order`; the `count` indices are that block's intents in contact order.
const Run = struct {
    block_id: u32,
    begin: u32,
    count: u32,
};

const RunList = std.array_list.Aligned(Run, .fromByteUnits(thread_shared_record_alignment));

// One worker's generation, padded so adjacent workers do not share a cache line.
const WorkerGeneration = struct { value: u32 = 0 };

// One occupied block: the grouped runs `[run_begin, run_begin + run_count)` are its
// gather ranges in range order.
const BlockItem = struct {
    block_id: u32,
    run_begin: u32,
    run_count: u32,
};

// One direct block slot, indexed by `block_id`. `stamp` equal to the range generation
// means this range already claimed it. The next range on the same worker uses the next
// generation, so it does not clear the table. `std.HashMap` is not used: it allocates,
// and gather runs on a worker. `pad` keeps the slot 16 bytes so worker regions can
// start on a cache line.
const BlockSlot = struct {
    count: u32 = 0,
    cursor: u32 = 0,
    stamp: u32 = 0,
    pad: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(BlockSlot) == 16);
    std.debug.assert(thread_shared_record_alignment % @sizeOf(BlockSlot) == 0);
    std.debug.assert(block_slots_per_line == thread_shared_record_alignment / @sizeOf(BlockSlot));
}

comptime {
    std.debug.assert(@sizeOf(PaddedSlot(GatherRow)) % thread_shared_record_alignment == 0);
    // A gather range's claim window starts at twice its first contact. Range starts are
    // multiples of the contact alignment, so adjacent windows do not share a cache line.
    std.debug.assert((2 * collision_response_range_alignment_items * @sizeOf(usize)) % thread_shared_record_alignment == 0);
}

fn setListCount(list: anytype, count: usize) void {
    std.debug.assert(list.capacity >= count);
    list.items.len = count;
}

pub const CollisionResponseSystem = struct {
    allocator: std.mem.Allocator,
    // Gather range r's intents start at `2 * r * items_per_range`; its trigger and observer
    // windows at `r * items_per_range`.
    intent_rows: std.MultiArrayList(IntentRow) = .{},
    // Block-grouped absolute intent indices, in the intent windows; written only when the
    // gather ran on workers.
    intent_order: IndexList = .empty,
    // Per-range runs at the intent-window base, then those runs grouped by block.
    range_runs: RunList = .empty,
    grouped_runs: std.ArrayList(Run) = .empty,
    block_items: std.ArrayList(BlockItem) = .empty,
    // `table_participants` regions of `table_stride` slots. A region is that worker's
    // direct block table; `table_blocks` is how many leading slots are real blocks.
    block_slots: BlockSlotList = .empty,
    worker_generation: SlotList(WorkerGeneration) = .empty,
    // Cached by the first reserve. Later steps do not call getCpuCount.
    participant_ceiling: usize = 0,
    table_participants: usize = 0,
    table_blocks: usize = 0,
    table_stride: usize = 0,
    // Block ids a gather range claimed, in its intent window. Place reuses the front
    // as cursors after the gather joins.
    claimed_slots: ClaimedList = .empty,
    trigger_staging: TriggerList = .empty,
    // Observer windows; compacted after the gather into this step's observer contacts.
    observer_staging: IndexList = .empty,
    gather_rows: SlotList(GatherRow) = .empty,
    gather_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    apply_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),
    // The observer and the contact count of the stream the observer contacts index.
    observer: EntityId = EntityId.invalid,
    observer_source_contacts: usize = 0,

    pub fn init(allocator: std.mem.Allocator) CollisionResponseSystem {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CollisionResponseSystem) void {
        self.gather_rows.deinit(self.allocator);
        self.observer_staging.deinit(self.allocator);
        self.trigger_staging.deinit(self.allocator);
        self.claimed_slots.deinit(self.allocator);
        self.worker_generation.deinit(self.allocator);
        self.block_slots.deinit(self.allocator);
        self.block_items.deinit(self.allocator);
        self.grouped_runs.deinit(self.allocator);
        self.range_runs.deinit(self.allocator);
        self.intent_order.deinit(self.allocator);
        self.intent_rows.deinit(self.allocator);
        self.* = undefined;
    }

    /// Consumes the completed same-step contact stream after CollisionSystem contact
    /// generation has finished, on `thread_system` as each stage's tuner selects. Writes
    /// movement positions and velocities, the `collision_triggers` stream, and this
    /// step's observer contacts. Dense movement indices in the contacts are hints; the
    /// gather revalidates them. Grows its reserves on the calling thread before any
    /// dispatch when the contacts exceed them; an allocation failure leaves movement
    /// untouched.
    pub fn update(
        self: *CollisionResponseSystem,
        data: *DataSystem,
        frame: *SimulationFrame,
        observer: EntityId,
        thread_system: *ThreadSystem,
        config: CollisionResponseConfig,
    ) error{OutOfMemory}!CollisionResponseStats {
        return self.run(data, frame, observer, .{ .thread_system = thread_system, .config = config });
    }

    /// Indices into `frame.contacts` of the last update's contacts naming `observer`, in
    /// contact order. Valid until the next update or until the contact stream changes;
    /// the caller passes the frame and observer that update saw.
    pub fn observerContacts(self: *const CollisionResponseSystem, frame: *const SimulationFrame, observer: EntityId) []const u32 {
        std.debug.assert(self.observer_source_contacts == frame.contacts.mergedItems().len);
        std.debug.assert(self.observer.eql(observer));
        return self.observer_staging.items;
    }

    pub fn reserveForContacts(self: *CollisionResponseSystem, max_contacts: usize) !void {
        try self.ensureContactCapacity(max_contacts);
    }

    fn run(self: *CollisionResponseSystem, data: *DataSystem, frame: *SimulationFrame, observer: EntityId, threads: ResponseThreads) !CollisionResponseStats {
        const step = (try self.beginStep(data, frame, observer)) orelse return .{};
        const input = step.input;
        const columns = step.columns;
        const contact_count = input.contacts.len;

        var stats = CollisionResponseStats{ .contact_count = contact_count };
        // Zero workers and a tuner that stays inline take this same select. One range
        // then applies inside the gather, so there is no second walk of the contacts.
        const gather_stage = threads.stage(&self.gather_tuner);
        const selection = gather_stage.select(contact_count, collision_response_range_alignment_items);
        setSlotCount(GatherRow, &self.gather_rows, selection.range_count);
        const inline_apply = selection.worker_threads == 0;
        const blocks = blockCount(input.movement_entities.len);
        if (!inline_apply and blocks != 0) {
            try self.ensureDirectTables(threads.thread_system.participantSlotCount(), blocks);
        }
        var gather = GatherJob{
            .input = input,
            .order = self.intent_order.items,
            .runs = self.range_runs.items,
            .block_slots = self.block_slots.items,
            .table_blocks = if (inline_apply) 0 else blocks,
            .table_stride = self.table_stride,
            .generations = self.worker_generation.items,
            .claimed = self.claimed_slots.items,
            .apply = if (inline_apply) columns else null,
            .items_per_range = selection.items_per_range,
            .gather_rows = self.gather_rows.items,
        };
        const gather_batch = gather_stage.run(selection, contact_count, collision_response_range_alignment_items, &gather, gatherJob);
        if (comptime runtime_perf_log.enabled) stats.perf.gather_batch = gather_batch;

        if (!inline_apply) {
            const run_count = runTotal(self.gather_rows.items);
            if (run_count > 0) {
                // One range for every run. A one-item batch is the caller's; the merge is
                // not split across workers. Worker 0's table is free after the gather join.
                std.debug.assert(self.table_blocks > 0 and self.worker_generation.items.len > 0);
                std.debug.assert(self.table_stride <= self.block_slots.items.len);
                const region = self.block_slots.items[0..self.table_stride];
                const generation = bumpGeneration(&self.worker_generation.items[0].value.value, region);
                var place = PlaceJob{
                    .gather_rows = self.gather_rows.items,
                    .range_runs = self.range_runs.items,
                    .grouped = self.grouped_runs.items,
                    .block_slots = region[0..self.table_blocks],
                    .claimed = self.claimed_slots.items,
                    .generation = generation,
                    .gather_items_per_range = selection.items_per_range,
                    .run_count = run_count,
                };
                const place_batch = threads.thread_system.parallelForWithOptions(1, &place, placeJob, .{
                    .items_per_range = 1,
                    .max_worker_threads = selection.worker_threads,
                    .range_alignment_items = 1,
                    .adaptive = false,
                });
                if (comptime runtime_perf_log.enabled) stats.perf.place_batch = place_batch;

                const block_count = scanBlockItems(self.grouped_runs.items[0..run_count], self.block_items.items);
                var apply_stage = threads.stage(&self.apply_tuner);
                const apply_selection = apply_stage.select(block_count, 1);
                var apply = ApplyBlockJob{
                    .intents = input.intents,
                    .columns = columns,
                    .order = self.intent_order.items,
                    .runs = self.grouped_runs.items,
                    .blocks = self.block_items.items[0..block_count],
                    .range_count = apply_selection.range_count,
                };
                const apply_batch = apply_stage.run(apply_selection, block_count, 1, &apply, applyBlockJob);
                if (comptime runtime_perf_log.enabled) stats.perf.apply_batch = apply_batch;
            }
        }

        for (self.gather_rows.items) |slot| {
            stats.intent_count += slot.value.intents;
            stats.trigger_count += slot.value.triggers;
            stats.observer_contact_count += slot.value.observer;
        }
        // The apply's time is absorbed by the gather's inline range.
        if (comptime runtime_perf_log.enabled) {
            if (inline_apply) stats.perf.apply_batch = inlineBatch(stats.intent_count, 1);
        }
        self.streamTriggers(frame, stats.trigger_count, selection.items_per_range);
        self.compactObserverWindows(selection.items_per_range);
        std.debug.assert(self.observer_staging.items.len == stats.observer_contact_count);
        return stats;
    }

    // Clears the step's outputs, then, for a nonempty contact stream, reserves and sizes
    // every buffer the stages write and returns their inputs. Null for no contacts.
    fn beginStep(self: *CollisionResponseSystem, data: *DataSystem, frame: *SimulationFrame, observer: EntityId) !?ResponseStep {
        const contacts = frame.contacts.mergedItems();
        const contact_count = contacts.len;
        // Checked before any output clears, so this failure leaves them as they were; a
        // reserve's OOM below clears them first.
        if (contact_count > max_step_intents / 2) return error.OutOfMemory;
        frame.collision_triggers.clearRetainingCapacity();
        self.observer_staging.clearRetainingCapacity();
        self.observer = observer;
        self.observer_source_contacts = contact_count;
        if (contact_count == 0) return null;

        // Every reserve, sized from this step's contacts, lands before any dispatch.
        try self.ensureContactCapacity(contact_count);
        try frame.collision_triggers.reserve(1, contact_count);
        const intent_capacity = 2 * contact_count;
        setRowCount(IntentRow, &self.intent_rows, intent_capacity);
        setListCount(&self.intent_order, intent_capacity);
        setListCount(&self.claimed_slots, intent_capacity);
        setListCount(&self.range_runs, intent_capacity);
        setListCount(&self.grouped_runs, intent_capacity);
        setListCount(&self.block_items, intent_capacity);
        setListCount(&self.trigger_staging, contact_count);
        setListCount(&self.observer_staging, contact_count);

        const movement = data.movementBodySlice();
        return .{
            .input = .{
                .data = data,
                .contacts = contacts,
                .observer = observer,
                .movement_entities = movement.entities,
                .intents = IntentColumns.of(self.intent_rows.slice()),
                .triggers = self.trigger_staging.items,
                .observers = self.observer_staging.items,
            },
            .columns = ApplyColumns.of(movement),
        };
    }

    // The trigger windows in range order as one stream range, into the capacity reserved
    // before the dispatch.
    fn streamTriggers(self: *const CollisionResponseSystem, frame: *SimulationFrame, trigger_count: usize, items_per_range: usize) void {
        if (trigger_count == 0) return;
        const stream = &frame.collision_triggers;
        _ = stream.appendRangeCountsAssumeCapacity(1);
        stream.addCount(0, trigger_count);
        stream.prefixAssumeCapacity();
        var writer = stream.rangeWriter(0);
        for (self.gather_rows.items, 0..) |slot, range_index| {
            const window = self.trigger_staging.items[range_index * items_per_range ..][0..slot.value.triggers];
            for (window) |trigger| writer.write(trigger);
        }
        writer.finish();
        stream.finishWrite();
    }

    // Compacts range r's observer contacts at `r * items_per_range` into one prefix in range
    // order. Each window starts at or after the running total, so a forward copy is safe.
    fn compactObserverWindows(self: *CollisionResponseSystem, items_per_range: usize) void {
        const entries = self.observer_staging.items;
        var dst: usize = 0;
        for (self.gather_rows.items, 0..) |slot, range_index| {
            const src = range_index * items_per_range;
            const count = slot.value.observer;
            std.debug.assert(dst <= src);
            if (dst != src and count != 0) {
                @memmove(entries[dst..][0..count], entries[src..][0..count]);
            }
            dst += count;
        }
        self.observer_staging.items.len = dst;
    }

    fn ensureContactCapacity(self: *CollisionResponseSystem, contact_capacity: usize) !void {
        const intent_capacity = 2 * contact_capacity;
        try self.intent_rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(intent_capacity));
        try self.intent_order.ensureTotalCapacity(self.allocator, intent_capacity);
        try self.claimed_slots.ensureTotalCapacity(self.allocator, intent_capacity);
        try self.range_runs.ensureTotalCapacity(self.allocator, intent_capacity);
        try self.grouped_runs.ensureTotalCapacity(self.allocator, intent_capacity);
        try self.block_items.ensureTotalCapacity(self.allocator, intent_capacity);
        try self.ensureDirectTableReserve(contact_capacity);
        try self.trigger_staging.ensureTotalCapacity(self.allocator, contact_capacity);
        try self.observer_staging.ensureTotalCapacity(self.allocator, contact_capacity);
        try self.gather_rows.ensureTotalCapacity(self.allocator, @max(maxRangeCount(contact_capacity, collision_response_range_alignment_items), 1));
    }

    // Capacity for one direct table per machine participant, long enough for a block
    // per `block_rows` contacts. The step commits the live length from its movement
    // rows and its thread system's participants; this keeps that commit from allocating
    // when the contact bound covers the bodies.
    fn ensureDirectTableReserve(self: *CollisionResponseSystem, contact_capacity: usize) !void {
        if (contact_capacity == 0) return;
        const blocks = blockCount(contact_capacity);
        const participants = self.participantCeilingCached();
        const slots = std.math.mul(usize, participants, tableStride(blocks)) catch return error.OutOfMemory;
        try self.ensureBlockSlotCapacity(slots);
        try self.worker_generation.ensureTotalCapacity(self.allocator, participants);
    }

    // The machine's participant count, read once. A step whose pool is already
    // reserved does not call getCpuCount.
    fn participantCeilingCached(self: *CollisionResponseSystem) usize {
        if (self.participant_ceiling == 0) self.participant_ceiling = participantCeiling();
        return self.participant_ceiling;
    }

    // New slots are zero, so a stamp of zero stays empty. A grow copies the old stamps.
    fn ensureBlockSlotCapacity(self: *CollisionResponseSystem, slot_count: usize) !void {
        const old_capacity = self.block_slots.capacity;
        try self.block_slots.ensureTotalCapacity(self.allocator, slot_count);
        if (self.block_slots.capacity != old_capacity) {
            @memset(self.block_slots.allocatedSlice()[old_capacity..], .{});
        }
    }

    // One region per participant, `blocks` long, stride-padded to a cache line. A
    // larger layout clears the slots. Generations already stored stay, and new
    // workers start at zero. A layout that already fits does not change. Failure
    // leaves the committed layout unchanged.
    fn ensureDirectTables(self: *CollisionResponseSystem, participants: usize, blocks: usize) !void {
        std.debug.assert(participants > 0 and blocks > 0);
        if (participants <= self.table_participants and blocks <= self.table_blocks) return;
        const new_participants = @max(self.table_participants, participants);
        const new_blocks = @max(self.table_blocks, blocks);
        const stride = tableStride(new_blocks);
        const slot_count = std.math.mul(usize, new_participants, stride) catch return error.OutOfMemory;
        const old_slot_capacity = self.block_slots.capacity;
        try self.block_slots.ensureTotalCapacity(self.allocator, slot_count);
        try self.worker_generation.ensureTotalCapacity(self.allocator, new_participants);
        if (self.block_slots.capacity != old_slot_capacity) {
            @memset(self.block_slots.allocatedSlice()[old_slot_capacity..], .{});
        }
        self.block_slots.items.len = slot_count;
        @memset(self.block_slots.items, .{});
        // Keep generations already stored. Resetting one to 0 makes the next
        // bump (1) match a stamp left in a region this clear did not cover.
        const old_generations = self.worker_generation.items.len;
        self.worker_generation.items.len = new_participants;
        if (new_participants > old_generations) {
            @memset(self.worker_generation.items[old_generations..], .{});
        }
        self.table_participants = new_participants;
        self.table_blocks = new_blocks;
        self.table_stride = stride;
    }
};

fn runTotal(gather_rows: []const PaddedSlot(GatherRow)) usize {
    var total: usize = 0;
    for (gather_rows) |slot| total += slot.value.run_count;
    return total;
}

// One nonempty step's gather inputs and the movement columns its apply writes.
const ResponseStep = struct {
    input: GatherInput,
    columns: ApplyColumns,
};

// What one gather reads, and the buffers its ranges write their windows of.
const GatherInput = struct {
    data: *const DataSystem,
    contacts: []const CollisionContact,
    observer: EntityId,
    movement_entities: []const EntityId,
    intents: IntentColumns,
    triggers: []CollisionTriggerEvent,
    observers: []u32,
};

// Contacts `[start, end)`: observer contacts, triggers, and response intents written
// compactly from their window starts, then the window's intent math.
// Scalar. Each contact is two slot resolves and a compact tail that is missing, a
// trigger, a static pair, one dynamic, or both. `computeIntentMath` already consumes
// that tail in lanes; masking the classify would drain the lanes back into it.
fn gatherRange(input: *const GatherInput, start: usize, end: usize) GatherRow {
    const intent_start = 2 * start;
    var intent_count: usize = 0;
    var trigger_count: usize = 0;
    var observer_count: usize = 0;
    for (input.contacts[start..end], start..) |contact, contact_index| {
        if (contact_query.involvesEntity(contact, input.observer)) {
            // Contact indices fit u32 (`max_step_intents`).
            input.observers[start + observer_count] = @intCast(contact_index);
            observer_count += 1;
        }
        const a_response = input.data.collisionResponseConst(contact.a) orelse continue;
        const b_response = input.data.collisionResponseConst(contact.b) orelse continue;
        if (a_response.mode == .trigger or b_response.mode == .trigger) {
            input.triggers[start + trigger_count] = .{ .a = contact.a, .b = contact.b };
            trigger_count += 1;
            continue;
        }
        intent_count += writePhysicalIntents(input, intent_start + intent_count, contact, a_response, b_response);
    }
    computeIntentMath(input.intents, intent_start, intent_start + intent_count);
    // Each count is at most the range's contacts or twice them, below `max_step_intents`.
    return .{
        .intents = @intCast(intent_count),
        .triggers = @intCast(trigger_count),
        .observer = @intCast(observer_count),
    };
}

// The contact's 0, 1, or 2 intents from `index`; returns how many.
fn writePhysicalIntents(
    input: *const GatherInput,
    index: usize,
    contact: CollisionContact,
    a_response: CollisionResponse,
    b_response: CollisionResponse,
) usize {
    const a_dynamic = a_response.mobility == .dynamic;
    const b_dynamic = b_response.mobility == .dynamic;
    if (!a_dynamic and !b_dynamic) return 0;

    if (a_dynamic and !b_dynamic) {
        writeIntent(input, index, contact.a, contact.a_movement_index, contact.normal_x, contact.normal_y, contact.penetration, a_response);
        return 1;
    }
    if (!a_dynamic and b_dynamic) {
        writeIntent(input, index, contact.b, contact.b_movement_index, -contact.normal_x, -contact.normal_y, contact.penetration, b_response);
        return 1;
    }

    if (a_response.mode == .bounce and b_response.mode != .bounce) {
        writeIntent(input, index, contact.a, contact.a_movement_index, contact.normal_x, contact.normal_y, contact.penetration, a_response);
        return 1;
    }
    if (b_response.mode == .bounce and a_response.mode != .bounce) {
        writeIntent(input, index, contact.b, contact.b_movement_index, -contact.normal_x, -contact.normal_y, contact.penetration, b_response);
        return 1;
    }

    const split_penetration = contact.penetration * 0.5;
    writeIntent(input, index, contact.a, contact.a_movement_index, contact.normal_x, contact.normal_y, split_penetration, a_response);
    writeIntent(input, index + 1, contact.b, contact.b_movement_index, -contact.normal_x, -contact.normal_y, split_penetration, b_response);
    return 2;
}

fn writeIntent(
    input: *const GatherInput,
    index: usize,
    entity: EntityId,
    movement_hint: usize,
    normal_x: f32,
    normal_y: f32,
    penetration: f32,
    response: CollisionResponse,
) void {
    const intents = input.intents;
    intents.movement_row[index] = movementRowFor(input.data, input.movement_entities, entity, movement_hint);
    intents.normal_x[index] = normal_x;
    intents.normal_y[index] = normal_y;
    intents.penetration[index] = penetration;
    intents.restitution[index] = response.restitution;
    intents.kind[index] = if (response.mode == .bounce) .bounce else .solid;
}

// The entity's movement row: the contact's hint when it still names the entity, else a
// slot resolve; `no_row` when the entity has no movement body.
fn movementRowFor(data: *const DataSystem, movement_entities: []const EntityId, entity: EntityId, hint: usize) u32 {
    const row = if (hint < movement_entities.len and movement_entities[hint].eql(entity))
        hint
    else
        data.movementBodyDenseIndex(entity) orelse return no_row;
    // Movement rows are u32 slot indices, below `no_row`.
    std.debug.assert(row < no_row);
    return @intCast(row);
}

// Correction and velocity scale of intents `[start, end)`, in lanes with a scalar tail.
fn computeIntentMath(intents: IntentColumns, start: usize, end: usize) void {
    var index = start;
    const negative_one = simd.splatFloat4(-1);
    while (index + simd.lane_count <= end) : (index += simd.lane_count) {
        const normal_x_lanes = simd.loadFloat4(intents.normal_x[index..]);
        const normal_y_lanes = simd.loadFloat4(intents.normal_y[index..]);
        const penetration_lanes = simd.loadFloat4(intents.penetration[index..]);
        const restitution_lanes = simd.loadFloat4(intents.restitution[index..]);
        simd.storeFloat4Slice(intents.correction_x[index..], simd.mulFloat4(normal_x_lanes, penetration_lanes));
        simd.storeFloat4Slice(intents.correction_y[index..], simd.mulFloat4(normal_y_lanes, penetration_lanes));
        simd.storeFloat4Slice(intents.velocity_scale[index..], simd.mulFloat4(restitution_lanes, negative_one));
    }

    while (index < end) : (index += 1) {
        intents.correction_x[index] = intents.normal_x[index] * intents.penetration[index];
        intents.correction_y[index] = intents.normal_y[index] * intents.penetration[index];
        intents.velocity_scale[index] = -intents.restitution[index];
    }
}

// `gather`: one range of contacts.
const GatherJob = struct {
    input: GatherInput,
    // Range r's order and run windows start at `2 * r * items_per_range`.
    order: []u32,
    runs: []Run,
    // Worker `w`'s table is `block_slots[w * table_stride ..][0 .. table_blocks]`.
    // `table_blocks == 0` skips the table (no movement rows, or the gather applies inline).
    block_slots: []BlockSlot,
    table_blocks: usize,
    table_stride: usize,
    generations: []PaddedSlot(WorkerGeneration),
    // Block ids, one slot per intent. Range r writes `[2 * range.start, 2 * range.start + intents)`.
    claimed: []usize,
    // Set when the gather runs inline: each range applies its own window.
    apply: ?ApplyColumns,
    items_per_range: usize,
    gather_rows: []PaddedSlot(GatherRow),
};

// The next generation for this worker. The wrap clears that worker's region so generation
// 1 cannot match a slot stamped in the previous cycle. Any other value leaves the
// region as the previous range wrote it.
fn bumpGeneration(generation: *u32, region: []BlockSlot) u32 {
    if (generation.* == std.math.maxInt(u32)) {
        @memset(region, .{});
        generation.* = 1;
    } else {
        generation.* += 1;
    }
    return generation.*;
}

// Gathers the range's contacts. Inline, then applies the range's window. On workers,
// groups the resolved intents by 16-row block: one direct load per intent, a prefix of
// the claimed blocks, one scatter in intent order. No digit passes and no sort of the
// intent indexes.
fn gatherJob(context: *anyopaque, range: ParallelRange, worker: WorkerId) void {
    const job: *GatherJob = @ptrCast(@alignCast(context));
    const input = &job.input;
    std.debug.assert(range.index < job.gather_rows.len);
    std.debug.assert(range.start == range.index * job.items_per_range);
    std.debug.assert(range.start <= range.end and range.end <= input.contacts.len);
    std.debug.assert(2 * range.end <= input.intents.movement_row.len and 2 * range.end <= job.order.len);
    std.debug.assert(2 * range.end <= job.runs.len);
    std.debug.assert(range.end <= input.triggers.len and range.end <= input.observers.len);
    if (job.apply) |columns| {
        // Inline ranges run in range order on the calling thread, so each window's apply
        // keeps every movement row's intents in contact order.
        std.debug.assert(worker.index == WorkerId.main.index);
        const row_count = input.movement_entities.len;
        std.debug.assert(columns.position_x.len == row_count and columns.position_y.len == row_count);
        std.debug.assert(columns.velocity_x.len == row_count and columns.velocity_y.len == row_count);
        job.gather_rows[range.index].value = gatherApplyRange(input, columns, range.start, range.end);
        return;
    }
    var row = gatherRange(input, range.start, range.end);
    const span = range.end - range.start;
    std.debug.assert(row.intents <= 2 * span);
    const window_start = 2 * range.start;
    std.debug.assert(window_start + row.intents <= job.claimed.len);
    // The window is this range's alone, and it starts on a cache line.
    if (row.intents != 0) std.debug.assert(@intFromPtr(&job.claimed[window_start]) % thread_shared_record_alignment == 0);
    if (job.table_blocks == 0) {
        if (row.intents != 0) {
            for (input.intents.movement_row[window_start..][0..row.intents]) |movement_row| {
                std.debug.assert(movement_row == no_row);
            }
        }
        row.run_count = 0;
        job.gather_rows[range.index].value = row;
        return;
    }
    std.debug.assert(worker.index < job.generations.len);
    std.debug.assert(job.table_stride >= job.table_blocks);
    const base = worker.index * job.table_stride;
    std.debug.assert(base + job.table_stride <= job.block_slots.len);
    const region = job.block_slots[base..][0..job.table_stride];
    const generation = bumpGeneration(&job.generations[worker.index].value.value, region);
    row.run_count = groupRangeIntents(
        input.intents.movement_row[window_start..][0..row.intents],
        window_start,
        job.order,
        job.runs[window_start..],
        region[0..job.table_blocks],
        job.claimed[window_start..][0..row.intents],
        generation,
    );
    job.gather_rows[range.index].value = row;
}

fn runBlockLess(_: void, lhs: Run, rhs: Run) bool {
    return lhs.block_id < rhs.block_id;
}

// The window's placed intents. One load of `table[block_id]` claims the block; the
// claimed ids become the runs, ordered by block id. The bin is the block id. Empty
// slots are not visited. Returns the run count.
fn groupRangeIntents(
    movement_rows: []const u32,
    window_start: usize,
    order: []u32,
    runs: []Run,
    table: []BlockSlot,
    claimed: []usize,
    generation: u32,
) u32 {
    if (movement_rows.len == 0) return 0;
    std.debug.assert(generation != 0);
    std.debug.assert(runs.len >= movement_rows.len);
    // One claim per intent, not one entry per block in the population.
    std.debug.assert(claimed.len == movement_rows.len);
    std.debug.assert(window_start + movement_rows.len <= order.len);
    var distinct: usize = 0;
    for (movement_rows) |movement_row| {
        if (movement_row == no_row) continue;
        const block_id = blockId(movement_row);
        std.debug.assert(block_id < table.len);
        const slot = &table[block_id];
        if (slot.stamp != generation) {
            std.debug.assert(distinct < claimed.len);
            claimed[distinct] = block_id;
            distinct += 1;
            slot.* = .{ .stamp = generation };
        }
        slot.count += 1;
    }
    if (distinct == 0) return 0;

    for (claimed[0..distinct], 0..) |block_index, index| {
        const slot = &table[block_index];
        std.debug.assert(slot.stamp == generation and slot.count != 0);
        runs[index] = .{
            .block_id = @intCast(block_index),
            .begin = 0,
            .count = slot.count,
        };
    }
    // One run per claimed block. Not a sort of the intents.
    pdq(Run, runs[0..distinct], {}, runBlockLess);
    var local: u32 = 0;
    const window_base: u32 = @intCast(window_start);
    for (runs[0..distinct], 0..) |*run, index| {
        if (index > 0) std.debug.assert(runs[index - 1].block_id < run.block_id);
        run.begin = window_base + local;
        table[run.block_id].cursor = run.begin;
        local += run.count;
    }

    var scattered: u32 = 0;
    for (movement_rows, 0..) |movement_row, offset| {
        if (movement_row == no_row) continue;
        const slot = &table[blockId(movement_row)];
        std.debug.assert(slot.stamp == generation);
        // Intent indices fit u32 (`max_step_intents`).
        order[slot.cursor] = @intCast(window_start + offset);
        slot.cursor += 1;
        scattered += 1;
    }
    std.debug.assert(scattered == local);
    return @intCast(distinct);
}

// `place`: one range, on the caller. One load of `table[block_id]` per run, then a
// prefix of the blocks claimed here and a scatter in range order, so the earlier
// range stays first. The runs are already in block-id order. No probe.
const PlaceJob = struct {
    gather_rows: []const PaddedSlot(GatherRow),
    range_runs: []const Run,
    grouped: []Run,
    block_slots: []BlockSlot,
    // Block ids claimed here, one slot per run. Place writes `[0, run_count)`.
    claimed: []usize,
    generation: u32,
    gather_items_per_range: usize,
    run_count: usize,
};

fn placeJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *PlaceJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index == 0 and range.start == 0 and range.end == 1);
    std.debug.assert(job.run_count <= job.grouped.len);
    std.debug.assert(job.run_count <= job.claimed.len);
    std.debug.assert(job.generation != 0);
    const table = job.block_slots;
    const claimed = job.claimed[0..job.run_count];
    var distinct: usize = 0;
    var seen: usize = 0;
    for (job.gather_rows, 0..) |slot, range_index| {
        const run_count = slot.value.run_count;
        if (run_count == 0) continue;
        const window_start = 2 * range_index * job.gather_items_per_range;
        std.debug.assert(window_start + run_count <= job.range_runs.len);
        var previous: u32 = 0;
        for (job.range_runs[window_start..][0..run_count], 0..) |run, index| {
            if (index > 0) std.debug.assert(previous < run.block_id);
            previous = run.block_id;
            std.debug.assert(run.block_id < table.len);
            const block_slot = &table[run.block_id];
            if (block_slot.stamp != job.generation) {
                std.debug.assert(distinct < claimed.len);
                claimed[distinct] = run.block_id;
                distinct += 1;
                block_slot.* = .{ .stamp = job.generation };
            }
            block_slot.count += 1;
            seen += 1;
        }
    }
    std.debug.assert(seen == job.run_count);
    var cursor: u32 = 0;
    for (claimed[0..distinct]) |block_index| {
        const block_slot = &table[block_index];
        std.debug.assert(block_slot.stamp == job.generation and block_slot.count != 0);
        block_slot.cursor = cursor;
        cursor += block_slot.count;
    }
    std.debug.assert(@as(usize, cursor) == job.run_count);
    for (job.gather_rows, 0..) |slot, range_index| {
        const run_count = slot.value.run_count;
        if (run_count == 0) continue;
        const window_start = 2 * range_index * job.gather_items_per_range;
        for (job.range_runs[window_start..][0..run_count]) |run| {
            const block_slot = &table[run.block_id];
            std.debug.assert(block_slot.stamp == job.generation);
            job.grouped[block_slot.cursor] = run;
            block_slot.cursor += 1;
        }
    }
}

// One block item per occupied block. Runs of one block are already contiguous.
fn scanBlockItems(runs: []const Run, items: []BlockItem) usize {
    std.debug.assert(items.len >= runs.len);
    var index: usize = 0;
    var count: usize = 0;
    while (index < runs.len) {
        const block_id = runs[index].block_id;
        const begin = index;
        index += 1;
        while (index < runs.len and runs[index].block_id == block_id) : (index += 1) {}
        items[count] = .{
            .block_id = block_id,
            .run_begin = @intCast(begin),
            .run_count = @intCast(index - begin),
        };
        count += 1;
    }
    return count;
}

// `apply`: one range of occupied blocks. A block is one item, so it is never split.
const ApplyBlockJob = struct {
    intents: IntentColumns,
    columns: ApplyColumns,
    order: []const u32,
    runs: []const Run,
    blocks: []const BlockItem,
    range_count: usize,
};

fn applyBlockJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *ApplyBlockJob = @ptrCast(@alignCast(context));
    std.debug.assert(range.index < job.range_count);
    std.debug.assert(range.start <= range.end and range.end <= job.blocks.len);
    const row_count = job.columns.position_x.len;
    std.debug.assert(job.columns.position_y.len == row_count);
    std.debug.assert(job.columns.velocity_x.len == row_count and job.columns.velocity_y.len == row_count);
    var lanes = ApplyLanes{};
    for (job.blocks[range.start..range.end]) |block| {
        const first_row = @as(usize, block.block_id) * block_rows;
        std.debug.assert(block.run_begin + block.run_count <= job.runs.len);
        for (job.runs[block.run_begin..][0..block.run_count]) |run| {
            std.debug.assert(run.block_id == block.block_id);
            std.debug.assert(@as(usize, run.begin) + run.count <= job.order.len);
            for (job.order[run.begin..][0..run.count]) |intent_index| {
                const movement_row_u = job.intents.movement_row[intent_index];
                const movement_row: usize = movement_row_u;
                std.debug.assert(movement_row_u != no_row and blockId(movement_row_u) == block.block_id);
                std.debug.assert(movement_row >= first_row and movement_row < row_count);
                lanes.push(job.columns, job.intents, intent_index, movement_row);
            }
        }
    }
    lanes.flush(job.columns);
}

// Contacts `[start, end)` gathered, then their intent window applied in order.
fn gatherApplyRange(input: *const GatherInput, columns: ApplyColumns, start: usize, end: usize) GatherRow {
    const row = gatherRange(input, start, end);
    var lanes = ApplyLanes{};
    applyWindow(&lanes, columns, input.intents, 2 * start, row.intents);
    lanes.flush(columns);
    return row;
}

// The `count` intents from `window_start` in order, skipping those with no movement row.
fn applyWindow(lanes: *ApplyLanes, columns: ApplyColumns, intents: IntentColumns, window_start: usize, count: usize) void {
    for (window_start..window_start + count) |intent_index| {
        const movement_row = intents.movement_row[intent_index];
        if (movement_row == no_row) continue;
        std.debug.assert(movement_row < columns.position_x.len);
        lanes.push(columns, intents, intent_index, movement_row);
    }
}

// Up to one lane block of intents on distinct movement rows awaiting their apply. An
// intent whose row is already pending flushes the block first, so each row still takes
// its intents in order.
const ApplyLanes = struct {
    rows: [simd.lane_count]usize = undefined,
    correction_x: [simd.lane_count]f32 = undefined,
    correction_y: [simd.lane_count]f32 = undefined,
    normal_x: [simd.lane_count]f32 = undefined,
    normal_y: [simd.lane_count]f32 = undefined,
    velocity_scale: [simd.lane_count]f32 = undefined,
    kinds: [simd.lane_count]u32 = undefined,
    count: usize = 0,

    fn push(self: *ApplyLanes, columns: ApplyColumns, intents: IntentColumns, intent_index: usize, row: usize) void {
        for (self.rows[0..self.count]) |pending_row| {
            if (pending_row == row) {
                self.flush(columns);
                break;
            }
        }
        const lane = self.count;
        self.rows[lane] = row;
        self.correction_x[lane] = intents.correction_x[intent_index];
        self.correction_y[lane] = intents.correction_y[intent_index];
        self.normal_x[lane] = intents.normal_x[intent_index];
        self.normal_y[lane] = intents.normal_y[intent_index];
        self.velocity_scale[lane] = intents.velocity_scale[intent_index];
        self.kinds[lane] = @backingInt(intents.kind[intent_index]);
        self.count += 1;
        if (self.count == simd.lane_count) self.flush(columns);
    }

    // A full block in lanes, a partial block per intent. Both add, multiply, and compare
    // once per value; with a zero normal `velocity * normal` is never negative, so the
    // lane test matches the scalar one bit for bit.
    fn flush(self: *ApplyLanes, columns: ApplyColumns) void {
        if (self.count == simd.lane_count) {
            const zero = simd.splatFloat4(0);
            const position_x = simd.gatherFloat4(columns.position_x, self.rows);
            const position_y = simd.gatherFloat4(columns.position_y, self.rows);
            simd.scatterFloat4(columns.position_x, self.rows, simd.addFloat4(position_x, simd.loadFloat4(&self.correction_x)));
            simd.scatterFloat4(columns.position_y, self.rows, simd.addFloat4(position_y, simd.loadFloat4(&self.correction_y)));
            const bounce = simd.equalUint4(simd.loadUint4(&self.kinds), simd.splatUint4(bounce_kind));
            const scale = simd.loadFloat4(&self.velocity_scale);
            const velocity_x = simd.gatherFloat4(columns.velocity_x, self.rows);
            const velocity_y = simd.gatherFloat4(columns.velocity_y, self.rows);
            const approach_x = simd.lessThanFloat4(simd.mulFloat4(velocity_x, simd.loadFloat4(&self.normal_x)), zero);
            const approach_y = simd.lessThanFloat4(simd.mulFloat4(velocity_y, simd.loadFloat4(&self.normal_y)), zero);
            const response_x = simd.selectFloat4(bounce, simd.mulFloat4(velocity_x, scale), zero);
            const response_y = simd.selectFloat4(bounce, simd.mulFloat4(velocity_y, scale), zero);
            simd.scatterFloat4(columns.velocity_x, self.rows, simd.selectFloat4(approach_x, response_x, velocity_x));
            simd.scatterFloat4(columns.velocity_y, self.rows, simd.selectFloat4(approach_y, response_y, velocity_y));
        } else {
            for (0..self.count) |lane| {
                applyIntentScalar(columns, self.rows[lane], self.correction_x[lane], self.correction_y[lane], self.normal_x[lane], self.normal_y[lane], self.velocity_scale[lane], self.kinds[lane]);
            }
        }
        self.count = 0;
    }
};

fn applyIntentScalar(
    columns: ApplyColumns,
    row: usize,
    correction_x: f32,
    correction_y: f32,
    normal_x: f32,
    normal_y: f32,
    velocity_scale: f32,
    kind: u32,
) void {
    columns.position_x[row] += correction_x;
    columns.position_y[row] += correction_y;
    if (shouldApplyNormalVelocityResponse(columns.velocity_x[row], normal_x)) {
        columns.velocity_x[row] = if (kind == bounce_kind) columns.velocity_x[row] * velocity_scale else 0;
    }
    if (shouldApplyNormalVelocityResponse(columns.velocity_y[row], normal_y)) {
        columns.velocity_y[row] = if (kind == bounce_kind) columns.velocity_y[row] * velocity_scale else 0;
    }
}

fn shouldApplyNormalVelocityResponse(velocity: f32, normal: f32) bool {
    return normal != 0 and velocity * normal < 0;
}
fn addEntity(
    data: *DataSystem,
    position_x: f32,
    position_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    response: CollisionResponse,
) !EntityId {
    const entity = try data.createEntity();
    try data.setMovementBody(entity, .{
        .position = .{ .x = position_x, .y = position_y },
        .previous_position = .{ .x = position_x, .y = position_y },
        .velocity = .{ .x = velocity_x, .y = velocity_y },
        .speed = 0,
    });
    try data.setCollisionResponse(entity, response);
    return entity;
}

fn makeContact(a: EntityId, b: EntityId, a_index: usize, b_index: usize, normal_x: f32, normal_y: f32, penetration: f32) CollisionContact {
    return .{
        .a = a,
        .b = b,
        .a_movement_index = a_index,
        .b_movement_index = b_index,
        .normal_x = normal_x,
        .normal_y = normal_y,
        .penetration = penetration,
    };
}

fn writeContacts(frame: *SimulationFrame, contacts: []const CollisionContact) !void {
    try frame.contacts.prepareRangeCounts(1);
    frame.contacts.addCount(0, contacts.len);
    try frame.contacts.prefix();
    var writer = frame.contacts.rangeWriter(0);
    for (contacts) |contact| writer.write(contact);
    writer.finish();
    frame.contacts.finishWrite();
}

// `CollisionResponseSystem.update` inline as one range: a thread system with no workers.
fn updateInline(system: *CollisionResponseSystem, data: *DataSystem, frame: *SimulationFrame, observer: EntityId) !CollisionResponseStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    return system.update(data, frame, observer, &threads, .{});
}

test "solid dynamic response separates from static and stops normal velocity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, 50, 7, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(dynamic, static, data.movementBodyDenseIndex(dynamic).?, data.movementBodyDenseIndex(static).?, -1, 0, 3)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    const stats = try updateInline(&system, &data, &frame, EntityId.invalid);

    try std.testing.expectEqual(@as(usize, 1), stats.intent_count);
    const body = data.movementBodyConst(dynamic).?;
    try std.testing.expectEqual(@as(f32, 7), body.velocity.y);
    try std.testing.expectEqual(@as(f32, 0), body.velocity.x);
    try std.testing.expectApproxEqAbs(@as(f32, 7), body.position.x, 0.001);
}

test "bounce dynamic response reflects normal velocity by restitution" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, 20, 0, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 0.5 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(dynamic, static, data.movementBodyDenseIndex(dynamic).?, data.movementBodyDenseIndex(static).?, -1, 0, 4)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try updateInline(&system, &data, &frame, EntityId.invalid);

    const body = data.movementBodyConst(dynamic).?;
    try std.testing.expectApproxEqAbs(@as(f32, 6), body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -10), body.velocity.x, 0.001);
}

test "bounce response preserves separating normal velocity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, -20, 0, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 0.5 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(dynamic, static, data.movementBodyDenseIndex(dynamic).?, data.movementBodyDenseIndex(static).?, -1, 0, 4)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try updateInline(&system, &data, &frame, EntityId.invalid);

    const body = data.movementBodyConst(dynamic).?;
    try std.testing.expectApproxEqAbs(@as(f32, 6), body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -20), body.velocity.x, 0.001);
}

test "solid response preserves separating normal velocity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, -15, 3, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(dynamic, static, data.movementBodyDenseIndex(dynamic).?, data.movementBodyDenseIndex(static).?, -1, 0, 3)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try updateInline(&system, &data, &frame, EntityId.invalid);

    const body = data.movementBodyConst(dynamic).?;
    try std.testing.expectApproxEqAbs(@as(f32, 7), body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -15), body.velocity.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 3), body.velocity.y, 0.001);
}

test "solid versus bounce dynamic pair gives response to bounce entity" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const solid = try addEntity(&data, 10, 20, 0, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const bounce = try addEntity(&data, 14, 20, -12, 0, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(solid, bounce, data.movementBodyDenseIndex(solid).?, data.movementBodyDenseIndex(bounce).?, -1, 0, 2)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try updateInline(&system, &data, &frame, EntityId.invalid);

    const solid_body = data.movementBodyConst(solid).?;
    const bounce_body = data.movementBodyConst(bounce).?;
    try std.testing.expectApproxEqAbs(@as(f32, 10), solid_body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 16), bounce_body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 12), bounce_body.velocity.x, 0.001);
}

test "trigger response emits event without physical correction" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const trigger = try addEntity(&data, 10, 20, 5, 0, .{ .mode = .trigger, .mobility = .static, .restitution = 0 });
    const dynamic = try addEntity(&data, 14, 20, 5, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(trigger, dynamic, data.movementBodyDenseIndex(trigger).?, data.movementBodyDenseIndex(dynamic).?, -1, 0, 2)};
    try writeContacts(&frame, &contacts);
    try frame.events.prepareRangeCounts(1);
    frame.events.addCount(0, 1);
    try frame.events.prefix();
    var event_writer = frame.events.rangeWriter(0);
    event_writer.write(.{ .stage = .structural_commit, .payload = .{ .entity_created = trigger } });
    event_writer.finish();
    frame.events.finishWrite();

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    const stats = try updateInline(&system, &data, &frame, EntityId.invalid);

    try std.testing.expectEqual(@as(usize, 0), stats.intent_count);
    try std.testing.expectEqual(@as(usize, 1), stats.trigger_count);
    try std.testing.expectEqual(@as(usize, 1), frame.events.mergedItems().len);
    try std.testing.expect(trigger.eql(frame.events.mergedItems()[0].payload.entity_created));
    try std.testing.expectEqual(@as(usize, 1), frame.collision_triggers.mergedItems().len);
    try std.testing.expect(trigger.eql(frame.collision_triggers.mergedItems()[0].a));
    try std.testing.expect(dynamic.eql(frame.collision_triggers.mergedItems()[0].b));
    try std.testing.expectEqual(@as(f32, 14), data.movementBodyConst(dynamic).?.position.x);
}

test "response remaps stale cached movement index before writing" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const target = try addEntity(&data, 10, 20, 10, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const wrong = try addEntity(&data, 50, 20, 0, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    const wrong_before = data.movementBodyConst(wrong).?;
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const contacts = [_]CollisionContact{makeContact(target, static, data.movementBodyDenseIndex(wrong).?, data.movementBodyDenseIndex(static).?, -1, 0, 2)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    _ = try updateInline(&system, &data, &frame, EntityId.invalid);

    const target_after = data.movementBodyConst(target).?;
    const wrong_after = data.movementBodyConst(wrong).?;
    try std.testing.expectApproxEqAbs(@as(f32, 8), target_after.position.x, 0.001);
    try std.testing.expectApproxEqAbs(wrong_before.position.x, wrong_after.position.x, 0.001);
    try std.testing.expectApproxEqAbs(wrong_before.velocity.x, wrong_after.velocity.x, 0.001);
}

test "warmed response update does not allocate" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const trigger = try addEntity(&data, 10, 20, 0, 0, .{ .mode = .trigger, .mobility = .static, .restitution = 0 });
    const dynamic = try addEntity(&data, 14, 20, 5, 0, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 0, 1, 1, 0);
    const contacts = [_]CollisionContact{makeContact(trigger, dynamic, data.movementBodyDenseIndex(trigger).?, data.movementBodyDenseIndex(dynamic).?, -1, 0, 2)};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserveForContacts(1);

    const original_system_allocator = system.allocator;
    const original_trigger_allocator = frame.collision_triggers.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    const fail = failing_allocator.allocator();
    system.allocator = fail;
    frame.collision_triggers.allocator = fail;
    defer {
        system.allocator = original_system_allocator;
        frame.collision_triggers.allocator = original_trigger_allocator;
    }

    const stats = try updateInline(&system, &data, &frame, EntityId.invalid);

    try std.testing.expectEqual(@as(usize, 1), stats.trigger_count);
    try std.testing.expectEqual(@as(usize, 1), frame.collision_triggers.mergedItems().len);
}

test "warmed solid response update does not allocate" {
    // FA proof for the physical-intent path: reserveForContacts then a solid
    // dynamic-vs-static contact must emit one intent with zero allocations.
    // The trigger-only FA test above never exercises intent_rows growth.
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, 50, 7, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const static = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try frame.reserveStreams(1, 0, 0, 1, 0, 0);
    const contacts = [_]CollisionContact{makeContact(
        dynamic,
        static,
        data.movementBodyDenseIndex(dynamic).?,
        data.movementBodyDenseIndex(static).?,
        -1,
        0,
        3,
    )};
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    try system.reserveForContacts(1);

    const original_system_allocator = system.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_allocator.allocator();
    defer system.allocator = original_system_allocator;

    const stats = try updateInline(&system, &data, &frame, EntityId.invalid);

    try std.testing.expectEqual(@as(usize, 1), stats.intent_count);
    try std.testing.expectEqual(@as(usize, 0), stats.trigger_count);
    const body = data.movementBodyConst(dynamic).?;
    try std.testing.expectEqual(@as(f32, 0), body.velocity.x);
    try std.testing.expectApproxEqAbs(@as(f32, 7), body.position.x, 0.001);
}

test "serial response math uses simd chunks and scalar tails" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const static = try addEntity(&data, 100, 0, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var dynamics: [simd.lane_count + 1]EntityId = undefined;
    var contacts: [simd.lane_count + 1]CollisionContact = undefined;
    for (&dynamics, 0..) |*entity, index| {
        entity.* = try addEntity(&data, @floatFromInt(index * 10), 0, 10, 0, .{ .mode = .bounce, .mobility = .dynamic, .restitution = 1 });
        contacts[index] = makeContact(entity.*, static, data.movementBodyDenseIndex(entity.*).?, data.movementBodyDenseIndex(static).?, -1, 0, @floatFromInt(index + 1));
    }
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    const stats = try updateInline(&system, &data, &frame, EntityId.invalid);

    try std.testing.expectEqual(@as(usize, simd.lane_count + 1), stats.intent_count);
    try std.testing.expectEqual(@as(usize, simd.lane_count), simd.vectorizedEnd(stats.intent_count));
    for (dynamics, 0..) |entity, index| {
        const body = data.movementBodyConst(entity).?;
        try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(index * 10)) - @as(f32, @floatFromInt(index + 1)), body.position.x, 0.001);
        try std.testing.expectApproxEqAbs(@as(f32, -10), body.velocity.x, 0.001);
    }
}

test "multi-contact stacking applies ordered solid corrections to one dynamic" {
    // Two statics + one dynamic: ordered contacts push the dynamic on X then Y.
    // Final pose is the sum of sequential corrections (not a single merged resolve).
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    const dynamic = try addEntity(&data, 10, 20, 15, 12, .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 });
    const static_a = try addEntity(&data, 40, 20, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    const static_b = try addEntity(&data, 10, 50, 0, 0, .{ .mode = .solid, .mobility = .static, .restitution = 0 });
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    const dyn_index = data.movementBodyDenseIndex(dynamic).?;
    const a_index = data.movementBodyDenseIndex(static_a).?;
    const b_index = data.movementBodyDenseIndex(static_b).?;
    const contacts = [_]CollisionContact{
        makeContact(dynamic, static_a, dyn_index, a_index, -1, 0, 3),
        makeContact(dynamic, static_b, dyn_index, b_index, 0, -1, 2),
    };
    try writeContacts(&frame, &contacts);

    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    const stats = try updateInline(&system, &data, &frame, EntityId.invalid);

    try std.testing.expectEqual(@as(usize, 2), stats.contact_count);
    try std.testing.expectEqual(@as(usize, 2), stats.intent_count);
    const body = data.movementBodyConst(dynamic).?;
    // (10,20) + (-1,0)*3 + (0,-1)*2 = (7, 18); both approaching velocities zeroed.
    try std.testing.expectApproxEqAbs(@as(f32, 7), body.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 18), body.position.y, 0.001);
    try std.testing.expectEqual(@as(f32, 0), body.velocity.x);
    try std.testing.expectEqual(@as(f32, 0), body.velocity.y);
    // Statics stay put.
    try std.testing.expectApproxEqAbs(@as(f32, 40), data.movementBodyConst(static_a).?.position.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 50), data.movementBodyConst(static_b).?.position.y, 0.001);
}

// A ring of `movement_rows + 1` entities where entity j contacts j+1, j+2 and j+3, so
// each sits in six contacts, three as `a` and three as `b`. Modes by index: solid
// dynamic, bounce dynamic, solid static, trigger. Entity `ring_no_response_entity` has no
// response, entity `ring_no_body_entity` no movement body; every 11th contact carries a
// stale `a` hint. Contacts are written in a scattered order; velocities are nonzero with
// mixed signs.
const ring_no_response_entity: usize = 5;
const ring_no_body_entity: usize = 7;
const ring_observer_entity: usize = 9;
const ring_contacts_per_entity: usize = 3;

const RingFixture = struct {
    data: DataSystem,
    frame: SimulationFrame,
    observer: EntityId,
    // Movement columns as built, restored before each run.
    initial: MovementSnapshot,

    fn deinit(self: *RingFixture, allocator: std.mem.Allocator) void {
        self.initial.deinit(allocator);
        self.frame.deinit();
        self.data.deinit();
        self.* = undefined;
    }

    fn restore(self: *RingFixture) void {
        const movement = self.data.movementBodySlice();
        @memcpy(movement.position_x, self.initial.position_x);
        @memcpy(movement.position_y, self.initial.position_y);
        @memcpy(movement.velocity_x, self.initial.velocity_x);
        @memcpy(movement.velocity_y, self.initial.velocity_y);
    }
};

const MovementSnapshot = struct {
    position_x: []f32,
    position_y: []f32,
    velocity_x: []f32,
    velocity_y: []f32,

    fn capture(allocator: std.mem.Allocator, data: *const DataSystem) !MovementSnapshot {
        const movement = data.movementBodySliceConst();
        const position_x = try allocator.dupe(f32, movement.position_x);
        errdefer allocator.free(position_x);
        const position_y = try allocator.dupe(f32, movement.position_y);
        errdefer allocator.free(position_y);
        const velocity_x = try allocator.dupe(f32, movement.velocity_x);
        errdefer allocator.free(velocity_x);
        const velocity_y = try allocator.dupe(f32, movement.velocity_y);
        return .{ .position_x = position_x, .position_y = position_y, .velocity_x = velocity_x, .velocity_y = velocity_y };
    }

    fn deinit(self: *MovementSnapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.velocity_y);
        allocator.free(self.velocity_x);
        allocator.free(self.position_y);
        allocator.free(self.position_x);
        self.* = undefined;
    }
};

fn ringResponse(entity_index: usize) CollisionResponse {
    return switch (entity_index % 4) {
        0 => .{ .mode = .solid, .mobility = .dynamic, .restitution = 0 },
        1 => .{ .mode = .bounce, .mobility = .dynamic, .restitution = 0.5 },
        2 => .{ .mode = .solid, .mobility = .static, .restitution = 0 },
        else => .{ .mode = .trigger, .mobility = .static, .restitution = 0 },
    };
}

fn ringNormal(contact_index: usize) [2]f32 {
    return switch (contact_index % 5) {
        0 => .{ 1, 0 },
        1 => .{ -1, 0 },
        2 => .{ 0, 1 },
        3 => .{ 0, -1 },
        else => .{ 0.6, -0.8 },
    };
}

fn buildRingFixture(allocator: std.mem.Allocator, movement_rows: usize) !RingFixture {
    const entity_count = movement_rows + 1;
    std.debug.assert(entity_count > ring_observer_entity);
    var data = DataSystem.init(allocator);
    errdefer data.deinit();
    const entities = try allocator.alloc(EntityId, entity_count);
    defer allocator.free(entities);
    for (entities, 0..) |*entity, index| {
        entity.* = try data.createEntity();
        if (index != ring_no_body_entity) {
            const position = math.Vec2{ .x = @floatFromInt(index * 3), .y = @floatFromInt(index % 7) };
            const speed_x: f32 = 5 + @as(f32, @floatFromInt(index % 7));
            const speed_y: f32 = 4 + @as(f32, @floatFromInt(index % 5));
            try data.setMovementBody(entity.*, .{
                .position = position,
                .previous_position = position,
                .velocity = .{
                    .x = if (index % 2 == 0) speed_x else -speed_x,
                    .y = if (index % 3 == 0) -speed_y else speed_y,
                },
                .speed = 0,
            });
        }
        if (index != ring_no_response_entity) try data.setCollisionResponse(entity.*, ringResponse(index));
    }
    std.debug.assert(data.movementBodySliceConst().entities.len == movement_rows);

    const contact_count = entity_count * ring_contacts_per_entity;
    const contacts = try allocator.alloc(CollisionContact, contact_count);
    defer allocator.free(contacts);
    var stride: usize = 7_919;
    while (std.math.gcd(stride, contact_count) != 1) stride += 2;
    for (contacts, 0..) |*contact, order| {
        const index = order * stride % contact_count;
        const a_index = index / ring_contacts_per_entity;
        const b_index = (a_index + index % ring_contacts_per_entity + 1) % entity_count;
        const a = entities[a_index];
        const b = entities[b_index];
        var a_hint = data.movementBodyDenseIndex(a) orelse 0;
        if (index % 11 == 0) a_hint = (a_hint + 1) % movement_rows;
        const b_hint = data.movementBodyDenseIndex(b) orelse movement_rows;
        const normal = ringNormal(index);
        const penetration = @as(f32, @floatFromInt(index % 5 + 1)) * 0.3;
        contact.* = makeContact(a, b, a_hint, b_hint, normal[0], normal[1], penetration);
    }

    var frame = SimulationFrame.init(allocator);
    errdefer frame.deinit();
    try writeContacts(&frame, contacts);
    var initial = try MovementSnapshot.capture(allocator, &data);
    errdefer initial.deinit(allocator);
    return .{ .data = data, .frame = frame, .observer = entities[ring_observer_entity], .initial = initial };
}

const RingResult = struct {
    stats: CollisionResponseStats,
    movement: MovementSnapshot,
    triggers: []CollisionTriggerEvent,
    observer_contacts: []u32,

    fn deinit(self: *RingResult, allocator: std.mem.Allocator) void {
        allocator.free(self.observer_contacts);
        allocator.free(self.triggers);
        self.movement.deinit(allocator);
        self.* = undefined;
    }
};

// One response step from the fixture's initial movement state; inline with no threads.
fn runRing(
    allocator: std.mem.Allocator,
    system: *CollisionResponseSystem,
    fixture: *RingFixture,
    threads: ?*ThreadSystem,
    config: CollisionResponseConfig,
) !RingResult {
    fixture.restore();
    const stats = if (threads) |thread_system|
        try system.update(&fixture.data, &fixture.frame, fixture.observer, thread_system, config)
    else
        try updateInline(system, &fixture.data, &fixture.frame, fixture.observer);
    var movement = try MovementSnapshot.capture(allocator, &fixture.data);
    errdefer movement.deinit(allocator);
    const triggers = try allocator.dupe(CollisionTriggerEvent, fixture.frame.collision_triggers.mergedItems());
    errdefer allocator.free(triggers);
    const observer_contacts = try allocator.dupe(u32, system.observerContacts(&fixture.frame, fixture.observer));
    return .{ .stats = stats, .movement = movement, .triggers = triggers, .observer_contacts = observer_contacts };
}

fn expectRingResultsEqual(expected: RingResult, actual: RingResult) !void {
    try std.testing.expectEqual(expected.stats.contact_count, actual.stats.contact_count);
    try std.testing.expectEqual(expected.stats.intent_count, actual.stats.intent_count);
    try std.testing.expectEqual(expected.stats.trigger_count, actual.stats.trigger_count);
    try std.testing.expectEqual(expected.stats.observer_contact_count, actual.stats.observer_contact_count);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.movement.position_x), std.mem.sliceAsBytes(actual.movement.position_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.movement.position_y), std.mem.sliceAsBytes(actual.movement.position_y));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.movement.velocity_x), std.mem.sliceAsBytes(actual.movement.velocity_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.movement.velocity_y), std.mem.sliceAsBytes(actual.movement.velocity_y));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected.triggers), std.mem.sliceAsBytes(actual.triggers));
    try std.testing.expectEqualSlices(u32, expected.observer_contacts, actual.observer_contacts);
}

const contactsNaming = @import("collision_response_test_support.zig").contactsNaming;

test "threaded response matches serial bit for bit across range sizes, worker counts and block counts" {
    const allocator = std.testing.allocator;
    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 3 });
    defer threads.deinit();

    // 40 and 1,100 movement rows are 3 and 69 blocks of 16. Matching serial means a block
    // is never split and contact order does not follow the partition.
    for ([_]usize{ 40, 1100 }) |movement_rows| {
        var fixture = try buildRingFixture(allocator, movement_rows);
        defer fixture.deinit(allocator);
        var serial_system = CollisionResponseSystem.init(allocator);
        defer serial_system.deinit();
        var serial = try runRing(allocator, &serial_system, &fixture, null, .{});
        defer serial.deinit(allocator);
        try std.testing.expect(serial.stats.intent_count > 0);
        try std.testing.expect(serial.stats.trigger_count > 0);
        try std.testing.expectEqual(2 * ring_contacts_per_entity, serial.stats.observer_contact_count);

        for ([_]usize{ 16, 32, 48 }) |items_per_range| {
            for ([_]usize{ 1, 2, 3 }) |workers| {
                var system = CollisionResponseSystem.init(allocator);
                defer system.deinit();
                var threaded = try runRing(allocator, &system, &fixture, &threads, .{
                    .items_per_range = items_per_range,
                    .max_worker_threads = workers,
                    .adaptive = false,
                });
                defer threaded.deinit(allocator);
                try expectRingResultsEqual(serial, threaded);
            }
        }

        // Tuner-driven apply shapes: several blocks per range, and the block apply inline.
        for ([_]usize{ 1, 2, 3 }) |workers| {
            for ([_]AdaptiveWorkProfile{
                .{ .worker_threads = workers, .items_per_range = 4 },
                .{ .worker_threads = 0, .items_per_range = 1 },
            }) |apply_profile| {
                var system = CollisionResponseSystem.init(allocator);
                defer system.deinit();
                pinTunerProfile(&system.gather_tuner, .{ .worker_threads = workers, .items_per_range = 16 });
                pinTunerProfile(&system.apply_tuner, apply_profile);
                var threaded = try runRing(allocator, &system, &fixture, &threads, .{ .max_worker_threads = workers });
                defer threaded.deinit(allocator);
                try expectRingResultsEqual(serial, threaded);
            }
        }

        // The gather settled inline: each range applies its own window, timed by the
        // gather, and the block apply never runs or learns.
        for ([_]usize{ 1, 2, 3 }) |workers| {
            var system = CollisionResponseSystem.init(allocator);
            defer system.deinit();
            pinTunerProfile(&system.gather_tuner, .{ .worker_threads = 0, .items_per_range = 1 });
            var inline_gather = try runRing(allocator, &system, &fixture, &threads, .{ .max_worker_threads = workers });
            defer inline_gather.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 0), system.apply_tuner.sample_count);
            try std.testing.expectEqual(@as(u64, 0), system.apply_tuner.baseline_mean_batch_duration_ns);
            try std.testing.expectEqual(@as(usize, 1), system.gather_tuner.sample_count);
            try expectRingResultsEqual(serial, inline_gather);
        }
    }
}

test "an inline gather job applies its window before it returns" {
    const allocator = std.testing.allocator;
    var fixture = try buildRingFixture(allocator, 40);
    defer fixture.deinit(allocator);
    var serial_system = CollisionResponseSystem.init(allocator);
    defer serial_system.deinit();
    var serial = try runRing(allocator, &serial_system, &fixture, null, .{});
    defer serial.deinit(allocator);

    fixture.restore();
    var system = CollisionResponseSystem.init(allocator);
    defer system.deinit();
    const step = (try system.beginStep(&fixture.data, &fixture.frame, fixture.observer)).?;
    setSlotCount(GatherRow, &system.gather_rows, 1);
    var job = GatherJob{
        .input = step.input,
        .order = system.intent_order.items,
        .runs = system.range_runs.items,
        .block_slots = &.{},
        .table_blocks = 0,
        .table_stride = 0,
        .generations = &.{},
        .claimed = system.claimed_slots.items,
        .apply = step.columns,
        .items_per_range = step.input.contacts.len,
        .gather_rows = system.gather_rows.items,
    };
    gatherJob(&job, .{ .index = 0, .start = 0, .end = step.input.contacts.len }, WorkerId.main);

    var movement = try MovementSnapshot.capture(allocator, &fixture.data);
    defer movement.deinit(allocator);
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(serial.movement.position_x), std.mem.sliceAsBytes(movement.position_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(serial.movement.position_y), std.mem.sliceAsBytes(movement.position_y));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(serial.movement.velocity_x), std.mem.sliceAsBytes(movement.velocity_x));
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(serial.movement.velocity_y), std.mem.sliceAsBytes(movement.velocity_y));
    try std.testing.expectEqual(serial.stats.intent_count, system.gather_rows.items[0].value.intents);
}

test "a gather range groups placed intents by block in contact order, and place keeps the earlier range first" {
    const generation: u32 = 1;
    // Blocks 0, skip, 1, 0, 1, 1, 2. Slot 3 is stamped and not claimed; a table scan would emit it.
    const rows = [_]u32{ 0, no_row, 16, 1, 31, 16, 32 };
    var order: [rows.len]u32 = undefined;
    var runs: [rows.len]Run = undefined;
    var claimed: [rows.len]usize = undefined;
    var slots: [4]BlockSlot = @splat(.{});
    slots[3] = .{ .count = 5, .stamp = generation };
    const run_count = groupRangeIntents(&rows, 0, &order, &runs, &slots, &claimed, generation);
    try std.testing.expectEqual(@as(u32, 3), run_count);
    try std.testing.expectEqual(@as(u32, 0), runs[0].block_id);
    try std.testing.expectEqual(@as(u32, 2), runs[0].count);
    try std.testing.expectEqual(@as(u32, 1), runs[1].block_id);
    try std.testing.expectEqual(@as(u32, 3), runs[1].count);
    try std.testing.expectEqual(@as(u32, 2), runs[2].block_id);
    try std.testing.expectEqual(@as(u32, 1), runs[2].count);
    try std.testing.expectEqual(@as(u32, 0), order[runs[0].begin]);
    try std.testing.expectEqual(@as(u32, 3), order[runs[0].begin + 1]);
    try std.testing.expectEqual(@as(u32, 2), order[runs[1].begin]);
    try std.testing.expectEqual(@as(u32, 4), order[runs[1].begin + 1]);
    try std.testing.expectEqual(@as(u32, 5), order[runs[1].begin + 2]);
    try std.testing.expectEqual(@as(u32, 6), order[runs[2].begin]);
    for (runs[0..run_count]) |run| try std.testing.expect(run.block_id != 3);
    try std.testing.expectEqual(@as(u32, 5), slots[3].count);

    // Range windows sit at `2 * range_index * items_per_range` with items_per_range 2.
    var range_runs: [8]Run = undefined;
    range_runs[0] = .{ .block_id = 0, .begin = 0, .count = 1 };
    range_runs[1] = .{ .block_id = 4, .begin = 1, .count = 1 };
    range_runs[4] = .{ .block_id = 0, .begin = 4, .count = 2 };
    var gather_rows = [_]PaddedSlot(GatherRow){
        .{ .value = .{ .run_count = 2 } },
        .{ .value = .{ .run_count = 1 } },
    };
    var grouped: [3]Run = undefined;
    var place_claimed: [3]usize = undefined;
    var place_slots: [5]BlockSlot = @splat(.{});
    // Stamped this generation and not claimed. A table scan would add its count.
    place_slots[2] = .{ .count = 5, .stamp = generation };
    var place = PlaceJob{
        .gather_rows = &gather_rows,
        .range_runs = &range_runs,
        .grouped = &grouped,
        .block_slots = &place_slots,
        .claimed = &place_claimed,
        .generation = generation,
        .gather_items_per_range = 2,
        .run_count = 3,
    };
    placeJob(&place, .{ .index = 0, .start = 0, .end = 1 }, WorkerId.main);
    var items: [3]BlockItem = undefined;
    const blocks = scanBlockItems(grouped[0..3], &items);
    try std.testing.expectEqual(@as(usize, 2), blocks);
    var found_block = false;
    for (items[0..blocks]) |block| {
        if (block.block_id != 0) continue;
        found_block = true;
        try std.testing.expectEqual(@as(u32, 2), block.run_count);
        const block_runs = grouped[block.run_begin..][0..block.run_count];
        try std.testing.expectEqual(@as(u32, 0), block_runs[0].begin);
        try std.testing.expectEqual(@as(u32, 1), block_runs[0].count);
        try std.testing.expectEqual(@as(u32, 4), block_runs[1].begin);
        try std.testing.expectEqual(@as(u32, 2), block_runs[1].count);
    }
    try std.testing.expect(found_block);
    try std.testing.expectEqual(@as(u32, 4), grouped[2].block_id);
}

test "the next range on a worker table does not see the previous range and does not clear it" {
    var slots: [4]BlockSlot = @splat(.{});
    const first_rows = [_]u32{ 0, 16 };
    const second_rows = [_]u32{0};
    var order: [2]u32 = undefined;
    var runs: [2]Run = undefined;
    var claimed: [2]usize = undefined;
    const first = groupRangeIntents(&first_rows, 0, &order, &runs, &slots, &claimed, 1);
    try std.testing.expectEqual(@as(u32, 2), first);
    try std.testing.expectEqual(@as(u32, 1), slots[0].stamp);
    try std.testing.expectEqual(@as(u32, 1), slots[1].stamp);
    const second = groupRangeIntents(&second_rows, 0, order[0..1], runs[0..1], &slots, claimed[0..1], 2);
    try std.testing.expectEqual(@as(u32, 1), second);
    try std.testing.expectEqual(@as(u32, 0), runs[0].block_id);
    try std.testing.expectEqual(@as(u32, 1), runs[0].count);
    // Generation 2 rewrote block 0. Block 1 still holds generation 1.
    try std.testing.expectEqual(@as(u32, 2), slots[0].stamp);
    try std.testing.expectEqual(@as(u32, 1), slots[0].count);
    try std.testing.expectEqual(@as(u32, 1), slots[1].stamp);
    try std.testing.expectEqual(@as(u32, 1), slots[1].count);

    var generation: u32 = 4;
    const bumped = bumpGeneration(&generation, &slots);
    try std.testing.expectEqual(@as(u32, 5), bumped);
    try std.testing.expectEqual(@as(u32, 2), slots[0].stamp);
    generation = std.math.maxInt(u32);
    const wrapped = bumpGeneration(&generation, &slots);
    try std.testing.expectEqual(@as(u32, 1), wrapped);
    try std.testing.expectEqual(@as(u32, 0), slots[0].stamp);
    try std.testing.expectEqual(@as(u32, 0), slots[1].stamp);
}

// Pins `tuner` settled on `profile` (inline when it has no workers) with no reprobe,
// retune, or item-count reset.
fn pinTunerProfile(tuner: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile) void {
    tuner.config.threaded_batch_ns = if (profile.worker_threads == 0) std.math.maxInt(u64) else 0;
    tuner.config.retune_after_settled_windows = std.math.maxInt(usize);
    tuner.config.item_count_reset_percent = std.math.maxInt(u8);
    tuner.phase = .settled;
    tuner.has_threaded_profile = profile.worker_threads > 0;
    tuner.current_profile = profile;
    tuner.best_profile = profile;
    tuner.candidate_profile = null;
    tuner.learned_item_count = 0;
}

// Today's per-intent apply, kept as the reference for the lane blocks.
fn applyIntentsReference(columns: ApplyColumns, rows: []const usize, intents: IntentColumns) void {
    for (rows, 0..) |row, index| {
        columns.position_x[row] += intents.correction_x[index];
        columns.position_y[row] += intents.correction_y[index];
        if (shouldApplyNormalVelocityResponse(columns.velocity_x[row], intents.normal_x[index])) {
            switch (intents.kind[index]) {
                .solid => columns.velocity_x[row] = 0,
                .bounce => columns.velocity_x[row] *= intents.velocity_scale[index],
            }
        }
        if (shouldApplyNormalVelocityResponse(columns.velocity_y[row], intents.normal_y[index])) {
            switch (intents.kind[index]) {
                .solid => columns.velocity_y[row] = 0,
                .bounce => columns.velocity_y[row] *= intents.velocity_scale[index],
            }
        }
    }
}

test "apply lanes match the scalar apply bit for bit" {
    const max_intents = 17;
    const row_count = 6;
    const normals = [_]f32{ 1, -1, 0, -0.0, 0.6 };
    for ([_]usize{ 0, 3, 4, 9, 17 }) |count| {
        var rows: [max_intents]usize = undefined;
        var movement_row: [max_intents]u32 = undefined;
        var normal_x: [max_intents]f32 = undefined;
        var normal_y: [max_intents]f32 = undefined;
        var penetration: [max_intents]f32 = undefined;
        var restitution: [max_intents]f32 = undefined;
        var correction_x: [max_intents]f32 = undefined;
        var correction_y: [max_intents]f32 = undefined;
        var velocity_scale: [max_intents]f32 = undefined;
        var kind: [max_intents]ResponseIntentKind = undefined;
        for (0..count) |index| {
            // Full lane blocks, with a row repeated inside a block every 7th intent so the
            // conflict flush runs.
            rows[index] = if (index % 7 == 6) rows[index - 1] else (index + index / 9) % row_count;
            movement_row[index] = @intCast(rows[index]);
            normal_x[index] = normals[index % normals.len];
            normal_y[index] = normals[(index + 2) % normals.len];
            penetration[index] = 0.25 * @as(f32, @floatFromInt(index % 4 + 1));
            restitution[index] = 0.5;
            kind[index] = if (index % 3 == 0) .bounce else .solid;
        }
        const intents = IntentColumns{
            .movement_row = &movement_row,
            .normal_x = &normal_x,
            .normal_y = &normal_y,
            .penetration = &penetration,
            .restitution = &restitution,
            .correction_x = &correction_x,
            .correction_y = &correction_y,
            .velocity_scale = &velocity_scale,
            .kind = &kind,
        };
        computeIntentMath(intents, 0, count);

        var reference_columns: [4][row_count]f32 = undefined;
        for (0..row_count) |row| {
            const sign: f32 = if (row % 2 == 0) 1 else -1;
            reference_columns[0][row] = @floatFromInt(row);
            reference_columns[1][row] = @as(f32, @floatFromInt(row)) * 2;
            reference_columns[2][row] = sign * (3 + @as(f32, @floatFromInt(row)));
            reference_columns[3][row] = if (row == 4) 0 else -sign * (2 + @as(f32, @floatFromInt(row)));
        }
        var lane_columns = reference_columns;
        const reference = ApplyColumns{ .position_x = &reference_columns[0], .position_y = &reference_columns[1], .velocity_x = &reference_columns[2], .velocity_y = &reference_columns[3] };
        const lanes_out = ApplyColumns{ .position_x = &lane_columns[0], .position_y = &lane_columns[1], .velocity_x = &lane_columns[2], .velocity_y = &lane_columns[3] };

        applyIntentsReference(reference, rows[0..count], intents);
        var lanes = ApplyLanes{};
        for (rows[0..count], 0..) |row, index| lanes.push(lanes_out, intents, index, row);
        lanes.flush(lanes_out);

        try std.testing.expectEqualSlices(u8, std.mem.asBytes(&reference_columns), std.mem.asBytes(&lane_columns));
    }
}

test "threaded multi-worker response allocates nothing after reserveForContacts" {
    const allocator = std.testing.allocator;
    var fixture = try buildRingFixture(allocator, 40);
    defer fixture.deinit(allocator);
    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    const contact_count = fixture.frame.contacts.mergedItems().len;

    var system = CollisionResponseSystem.init(allocator);
    defer system.deinit();
    try system.reserveForContacts(contact_count);
    try system.ensureDirectTables(threads.participantSlotCount(), blockCount(fixture.data.movementBodySliceConst().entities.len));
    try fixture.frame.collision_triggers.reserve(1, estimateTriggerCapacity(contact_count));

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing_allocator.allocator();
    fixture.frame.collision_triggers.allocator = failing_allocator.allocator();
    const result = system.update(&fixture.data, &fixture.frame, fixture.observer, &threads, .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false });
    system.allocator = allocator;
    fixture.frame.collision_triggers.allocator = allocator;
    const stats = try result;

    try std.testing.expectEqual(@as(usize, 0), failing_allocator.allocations);
    try std.testing.expect(stats.intent_count > 0);
    try std.testing.expect(stats.trigger_count > 0);
    try std.testing.expectEqual(stats.trigger_count, fixture.frame.collision_triggers.mergedItems().len);
}

test "response stages record into their own tuners" {
    const allocator = std.testing.allocator;
    var fixture = try buildRingFixture(allocator, 40);
    defer fixture.deinit(allocator);
    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var system = CollisionResponseSystem.init(allocator);
    defer system.deinit();
    const window = system.gather_tuner.config.sample_window;
    for (0..window) |_| {
        fixture.restore();
        _ = try system.update(&fixture.data, &fixture.frame, fixture.observer, &threads, .{ .max_worker_threads = 2 });
    }
    try std.testing.expect(system.gather_tuner.baseline_mean_batch_duration_ns > 0);
    // A gather that learns inline applies its own windows; the apply tuner hears nothing.
    try std.testing.expect(!system.gather_tuner.has_threaded_profile);
    try std.testing.expectEqual(@as(usize, 0), system.apply_tuner.sample_count);
    try std.testing.expectEqual(@as(u64, 0), system.apply_tuner.baseline_mean_batch_duration_ns);

    // The apply runs only after a gather on workers: pin the gather to a threaded profile.
    pinTunerProfile(&system.gather_tuner, .{ .worker_threads = 2, .items_per_range = 16 });
    for (0..window) |_| {
        fixture.restore();
        _ = try system.update(&fixture.data, &fixture.frame, fixture.observer, &threads, .{ .max_worker_threads = 2 });
    }

    try std.testing.expect(system.apply_tuner.baseline_mean_batch_duration_ns > 0);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_tuner.baseline_mean_batch_duration_ns);
}

test "an empty contact stream records no batch and leaves no triggers or observer contacts" {
    const allocator = std.testing.allocator;
    var fixture = try buildRingFixture(allocator, 40);
    defer fixture.deinit(allocator);
    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var system = CollisionResponseSystem.init(allocator);
    defer system.deinit();
    const full = try system.update(&fixture.data, &fixture.frame, fixture.observer, &threads, .{ .max_worker_threads = 2 });
    try std.testing.expect(full.trigger_count > 0);
    try std.testing.expect(system.observerContacts(&fixture.frame, fixture.observer).len > 0);
    const samples_before = system.gather_tuner.sample_count;

    fixture.frame.contacts.clearRetainingCapacity();
    const empty = try system.update(&fixture.data, &fixture.frame, fixture.observer, &threads, .{ .max_worker_threads = 2 });

    try std.testing.expectEqual(@as(usize, 0), empty.contact_count);
    try std.testing.expectEqual(@as(usize, 0), empty.intent_count);
    try std.testing.expectEqual(@as(usize, 0), empty.trigger_count);
    try std.testing.expectEqual(samples_before, system.gather_tuner.sample_count);
    try std.testing.expectEqual(@as(usize, 0), fixture.frame.collision_triggers.mergedItems().len);
    // Consumers read the observer contacts through this accessor.
    try std.testing.expectEqual(@as(usize, 0), system.observerContacts(&fixture.frame, fixture.observer).len);
}

test "observer contacts list every contact naming the observer in contact order" {
    const allocator = std.testing.allocator;
    var fixture = try buildRingFixture(allocator, 40);
    defer fixture.deinit(allocator);
    const expected_buffer = try allocator.alloc(u32, fixture.frame.contacts.mergedItems().len);
    defer allocator.free(expected_buffer);
    const expected = contactsNaming(&fixture.frame, fixture.observer, expected_buffer);
    try std.testing.expectEqual(2 * ring_contacts_per_entity, expected.len);
    // The observer appears as `a` and as `b`, in contacts spread over several ranges.
    var as_a: usize = 0;
    for (expected) |index| {
        if (fixture.frame.contacts.mergedItems()[index].a.eql(fixture.observer)) as_a += 1;
    }
    try std.testing.expectEqual(ring_contacts_per_entity, as_a);
    try std.testing.expect(expected[expected.len - 1] / 16 > expected[0] / 16);

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();
    var serial_system = CollisionResponseSystem.init(allocator);
    defer serial_system.deinit();
    var serial = try runRing(allocator, &serial_system, &fixture, null, .{});
    defer serial.deinit(allocator);
    try std.testing.expectEqualSlices(u32, expected, serial.observer_contacts);

    var system = CollisionResponseSystem.init(allocator);
    defer system.deinit();
    var threaded = try runRing(allocator, &system, &fixture, &threads, .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false });
    defer threaded.deinit(allocator);
    try std.testing.expectEqualSlices(u32, expected, threaded.observer_contacts);
    try std.testing.expectEqual(expected.len, threaded.stats.observer_contact_count);
}

test "contacts past the reserve grow on main before dispatch and match serial" {
    const allocator = std.testing.allocator;
    var fixture = try buildRingFixture(allocator, 66);
    defer fixture.deinit(allocator);
    try std.testing.expect(fixture.frame.contacts.mergedItems().len >= 200);
    var threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 2 });
    defer threads.deinit();

    var serial_system = CollisionResponseSystem.init(allocator);
    defer serial_system.deinit();
    var serial = try runRing(allocator, &serial_system, &fixture, null, .{});
    defer serial.deinit(allocator);

    var system = CollisionResponseSystem.init(allocator);
    defer system.deinit();
    try system.reserveForContacts(4);
    var threaded = try runRing(allocator, &system, &fixture, &threads, .{ .items_per_range = 16, .max_worker_threads = 2, .adaptive = false });
    defer threaded.deinit(allocator);
    try expectRingResultsEqual(serial, threaded);
}

test "a step of over 2^31 - 1 contacts fails as OutOfMemory before clearing outputs or asking the allocator; 2^31 - 1 reaches the allocator" {
    var data = DataSystem.init(std.testing.allocator);
    defer data.deinit();
    var frame = SimulationFrame.init(std.testing.allocator);
    defer frame.deinit();
    var system = CollisionResponseSystem.init(std.testing.allocator);
    defer system.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    system.allocator = failing.allocator();
    defer system.allocator = std.testing.allocator;
    // The merged stream reads `count` contacts: the step checks only the count before its
    // reserves, so no contact memory backs it. Restored before deinit.
    var spare: [1]CollisionContact = undefined;
    const real_values = frame.contacts.values;
    defer {
        frame.contacts.values = real_values;
        frame.contacts.merged_len = 0;
        frame.contacts.prefix_ready = false;
    }
    const limit = max_step_intents / 2;
    for ([_]usize{ limit + 1, limit }) |count| {
        frame.contacts.values.items = (&spare).ptr[0..count];
        frame.contacts.merged_len = count;
        frame.contacts.prefix_ready = true;
        system.observer_source_contacts = 7;
        try std.testing.expectError(error.OutOfMemory, updateInline(&system, &data, &frame, EntityId.invalid));
        if (count > limit) {
            try std.testing.expect(!failing.has_induced_failure);
            try std.testing.expectEqual(@as(usize, 7), system.observer_source_contacts);
        } else {
            try std.testing.expect(failing.has_induced_failure);
        }
    }
}
