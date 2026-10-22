// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned transient particle effects.
//! This system intentionally owns its own fixed-capacity SoA pool because
//! particles are visual effect state, not persistent DataSystem entities.

const std = @import("std");
const config = @import("../../config.zig");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const render_depth = @import("../render_depth.zig");
const WorldDepth = render_depth.WorldDepth;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");

pub const hot_particle_column_alignment: usize = 64;
pub const particle_range_alignment_items: usize = hot_particle_column_alignment / @sizeOf(f32);

const HotF32Slice = @import("../data_system.zig").HotF32Slice;
const ConstHotF32Slice = @import("../data_system.zig").ConstHotF32Slice;

const hotStoreCapacity = @import("../data_system.zig").hotStoreCapacity;

comptime {
    // Store capacities round to the shared hot-store quantum; each range's whole lane
    // batches must still fit one.
    std.debug.assert(@import("../data_system.zig").movement_range_alignment_items % particle_range_alignment_items == 0);
}

pub const ParticleSystemConfig = struct {
    capacity: usize = 512,
};

pub const ParticleUpdateConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

pub const ParticleUpdateStats = struct {
    active_before: usize = 0,
    active_after: usize = 0,
    removed_count: usize = 0,
    perf: Perf = .{},

    /// The update batch, kept only with `runtime_perf_log.enabled`.
    pub const Perf = if (runtime_perf_log.enabled) struct { batch: BatchStats = .{} } else struct {};

    pub fn recordTo(self: ParticleUpdateStats, perf: runtime_perf_log.Context) void {
        perf.recordMetric(.particle_active_before, metric(self.active_before));
        perf.recordMetric(.particle_active_after, metric(self.active_after));
        perf.recordMetric(.particle_removed, metric(self.removed_count));
        if (comptime runtime_perf_log.enabled) perf.recordBenchBatch(.particles, self.perf.batch);
    }
};

fn metric(value: usize) u64 {
    return @intCast(value);
}

pub const ParticleSpawn = struct {
    position: math.Vec2 = .{},
    base_z: i32 = 0,
    velocity: math.Vec2 = .{},
    acceleration: math.Vec2 = .{},
    lifetime: f32 = 1,
    start_size: f32 = 4,
    end_size: f32 = 0,
    start_color: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    end_color: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0 },
    depth: WorldDepth = .effect,
};

pub const ParticleEmitterConfig = struct {
    count: usize = 1,
    position: math.Vec2 = .{},
    base_z: i32 = 0,
    base_velocity: math.Vec2 = .{},
    velocity_step: math.Vec2 = .{},
    acceleration: math.Vec2 = .{},
    lifetime: f32 = 1,
    lifetime_step: f32 = 0,
    start_size: f32 = 4,
    end_size: f32 = 0,
    start_color: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    end_color: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0 },
    depth: WorldDepth = .effect,
};

pub const ParticleSlice = struct {
    // Mutable slice handed to serial or threaded update code. All columns share
    // the same active length and range ownership contract.
    position_x: HotF32Slice,
    position_y: HotF32Slice,
    previous_x: HotF32Slice,
    previous_y: HotF32Slice,
    velocity_x: HotF32Slice,
    velocity_y: HotF32Slice,
    acceleration_x: HotF32Slice,
    acceleration_y: HotF32Slice,
    age: HotF32Slice,
    lifetime: HotF32Slice,
    size: HotF32Slice,
    start_size: HotF32Slice,
    end_size: HotF32Slice,
    color_r: HotF32Slice,
    color_g: HotF32Slice,
    color_b: HotF32Slice,
    color_a: HotF32Slice,
    start_color_r: HotF32Slice,
    start_color_g: HotF32Slice,
    start_color_b: HotF32Slice,
    start_color_a: HotF32Slice,
    end_color_r: HotF32Slice,
    end_color_g: HotF32Slice,
    end_color_b: HotF32Slice,
    end_color_a: HotF32Slice,
    z: []i32,

    pub fn len(self: ParticleSlice) usize {
        return self.position_x.len;
    }
};

pub const ConstParticleSlice = struct {
    // Render code reads const slices after update/removal has completed, so it
    // never observes rows while swap-removal is compacting the pool.
    position_x: ConstHotF32Slice,
    position_y: ConstHotF32Slice,
    previous_x: ConstHotF32Slice,
    previous_y: ConstHotF32Slice,
    velocity_x: ConstHotF32Slice,
    velocity_y: ConstHotF32Slice,
    acceleration_x: ConstHotF32Slice,
    acceleration_y: ConstHotF32Slice,
    age: ConstHotF32Slice,
    lifetime: ConstHotF32Slice,
    size: ConstHotF32Slice,
    start_size: ConstHotF32Slice,
    end_size: ConstHotF32Slice,
    color_r: ConstHotF32Slice,
    color_g: ConstHotF32Slice,
    color_b: ConstHotF32Slice,
    color_a: ConstHotF32Slice,
    start_color_r: ConstHotF32Slice,
    start_color_g: ConstHotF32Slice,
    start_color_b: ConstHotF32Slice,
    start_color_a: ConstHotF32Slice,
    end_color_r: ConstHotF32Slice,
    end_color_g: ConstHotF32Slice,
    end_color_b: ConstHotF32Slice,
    end_color_a: ConstHotF32Slice,
    z: []const i32,

    pub fn len(self: ConstParticleSlice) usize {
        return self.position_x.len;
    }

    /// A row is renderable once it has positive size and non-transparent alpha;
    /// expired or invisible rows are skipped by render prep.
    pub fn renderable(self: ConstParticleSlice, index: usize) bool {
        return self.size[index] > 0 and self.color_a[index] > 0;
    }
};

const ParticleRow = struct {
    position_x: f32,
    position_y: f32,
    previous_x: f32,
    previous_y: f32,
    velocity_x: f32,
    velocity_y: f32,
    acceleration_x: f32,
    acceleration_y: f32,
    age: f32,
    lifetime: f32,
    size: f32,
    start_size: f32,
    end_size: f32,
    color_r: f32,
    color_g: f32,
    color_b: f32,
    color_a: f32,
    start_color_r: f32,
    start_color_g: f32,
    start_color_b: f32,
    start_color_a: f32,
    end_color_r: f32,
    end_color_g: f32,
    end_color_b: f32,
    end_color_a: f32,
    z: i32,
};

fn appendParticleRow(
    rows: *std.MultiArrayList(ParticleRow),
    row_slice: *std.MultiArrayList(ParticleRow).Slice,
    row: ParticleRow,
) void {
    _ = rows.addOneAssumeCapacity();
    row_slice.len = rows.len;
    row_slice.set(rows.len - 1, row);
}

fn spawnToRow(spawn: ParticleSpawn) ParticleRow {
    return .{
        .position_x = spawn.position.x,
        .position_y = spawn.position.y,
        .previous_x = spawn.position.x,
        .previous_y = spawn.position.y,
        .velocity_x = spawn.velocity.x,
        .velocity_y = spawn.velocity.y,
        .acceleration_x = spawn.acceleration.x,
        .acceleration_y = spawn.acceleration.y,
        .age = 0,
        .lifetime = spawn.lifetime,
        .size = spawn.start_size,
        .start_size = spawn.start_size,
        .end_size = spawn.end_size,
        .color_r = spawn.start_color.r,
        .color_g = spawn.start_color.g,
        .color_b = spawn.start_color.b,
        .color_a = spawn.start_color.a,
        .start_color_r = spawn.start_color.r,
        .start_color_g = spawn.start_color.g,
        .start_color_b = spawn.start_color.b,
        .start_color_a = spawn.start_color.a,
        .end_color_r = spawn.end_color.r,
        .end_color_g = spawn.end_color.g,
        .end_color_b = spawn.end_color.b,
        .end_color_a = spawn.end_color.a,
        .z = render_depth.worldZWithOffset(spawn.base_z, spawn.depth),
    };
}

pub const ParticleSystem = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    // Fixed-capacity SoA pool. Every active particle is a dense row across all
    // columns, and expired rows are removed by swap-compaction after update.
    rows: std.MultiArrayList(ParticleRow) = .{},
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(.{}),

    pub fn init(allocator: std.mem.Allocator, system_config: ParticleSystemConfig) !ParticleSystem {
        var self = ParticleSystem{
            .allocator = allocator,
            .capacity = system_config.capacity,
            .adaptive_tuner = AdaptiveWorkTuner.init(.{}),
        };
        errdefer self.deinit();
        try self.reserveStorage(system_config.capacity);
        return self;
    }

    pub fn deinit(self: *ParticleSystem) void {
        self.rows.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn activeCount(self: *const ParticleSystem) usize {
        return self.rows.len;
    }

    pub fn slice(self: *ParticleSystem) ParticleSlice {
        const s = self.rows.slice();
        return .{
            .position_x = s.items(.position_x),
            .position_y = s.items(.position_y),
            .previous_x = s.items(.previous_x),
            .previous_y = s.items(.previous_y),
            .velocity_x = s.items(.velocity_x),
            .velocity_y = s.items(.velocity_y),
            .acceleration_x = s.items(.acceleration_x),
            .acceleration_y = s.items(.acceleration_y),
            .age = s.items(.age),
            .lifetime = s.items(.lifetime),
            .size = s.items(.size),
            .start_size = s.items(.start_size),
            .end_size = s.items(.end_size),
            .color_r = s.items(.color_r),
            .color_g = s.items(.color_g),
            .color_b = s.items(.color_b),
            .color_a = s.items(.color_a),
            .start_color_r = s.items(.start_color_r),
            .start_color_g = s.items(.start_color_g),
            .start_color_b = s.items(.start_color_b),
            .start_color_a = s.items(.start_color_a),
            .end_color_r = s.items(.end_color_r),
            .end_color_g = s.items(.end_color_g),
            .end_color_b = s.items(.end_color_b),
            .end_color_a = s.items(.end_color_a),
            .z = s.items(.z),
        };
    }

    pub fn sliceConst(self: *const ParticleSystem) ConstParticleSlice {
        const s = self.rows.slice();
        return .{
            .position_x = s.items(.position_x),
            .position_y = s.items(.position_y),
            .previous_x = s.items(.previous_x),
            .previous_y = s.items(.previous_y),
            .velocity_x = s.items(.velocity_x),
            .velocity_y = s.items(.velocity_y),
            .acceleration_x = s.items(.acceleration_x),
            .acceleration_y = s.items(.acceleration_y),
            .age = s.items(.age),
            .lifetime = s.items(.lifetime),
            .size = s.items(.size),
            .start_size = s.items(.start_size),
            .end_size = s.items(.end_size),
            .color_r = s.items(.color_r),
            .color_g = s.items(.color_g),
            .color_b = s.items(.color_b),
            .color_a = s.items(.color_a),
            .start_color_r = s.items(.start_color_r),
            .start_color_g = s.items(.start_color_g),
            .start_color_b = s.items(.start_color_b),
            .start_color_a = s.items(.start_color_a),
            .end_color_r = s.items(.end_color_r),
            .end_color_g = s.items(.end_color_g),
            .end_color_b = s.items(.end_color_b),
            .end_color_a = s.items(.end_color_a),
            .z = s.items(.z),
        };
    }

    pub fn emit(self: *ParticleSystem, spawn: ParticleSpawn) bool {
        // Emission is best-effort and allocation-free after init. Full pools or
        // nonpositive lifetimes simply reject the particle.
        if (self.activeCount() >= self.capacity) return false;
        if (spawn.lifetime <= 0) return false;

        var row_slice = self.rows.slice();
        appendParticleRow(&self.rows, &row_slice, spawnToRow(spawn));
        return true;
    }

    pub fn emitBurst(self: *ParticleSystem, emitter_config: ParticleEmitterConfig) usize {
        var emitted: usize = 0;
        for (0..emitter_config.count) |index| {
            const index_f: f32 = @floatFromInt(index);
            if (self.emit(.{
                .position = emitter_config.position,
                .base_z = emitter_config.base_z,
                .velocity = .{
                    .x = emitter_config.base_velocity.x + emitter_config.velocity_step.x * index_f,
                    .y = emitter_config.base_velocity.y + emitter_config.velocity_step.y * index_f,
                },
                .acceleration = emitter_config.acceleration,
                .lifetime = emitter_config.lifetime + emitter_config.lifetime_step * index_f,
                .start_size = emitter_config.start_size,
                .end_size = emitter_config.end_size,
                .start_color = emitter_config.start_color,
                .end_color = emitter_config.end_color,
                .depth = emitter_config.depth,
            })) {
                emitted += 1;
            }
        }
        return emitted;
    }

    pub fn update(
        self: *ParticleSystem,
        thread_system: *ThreadSystem,
        delta_seconds: f32,
        update_config: ParticleUpdateConfig,
    ) ParticleUpdateStats {
        // Workers update disjoint dense rows. Expiration removal is a separate
        // main-thread compaction pass so row movement never races worker writes.
        const active_before = self.activeCount();
        if (active_before == 0) return .{};

        const particles = self.slice();
        const dispatch = Dispatch.init(thread_system, &self.adaptive_tuner, .{
            .items_per_range = update_config.items_per_range,
            .max_worker_threads = update_config.max_worker_threads,
            .adaptive = update_config.adaptive,
        });
        // Pre-select so the job context can dual-assert range.index against the
        // dispatched range count.
        const selection = dispatch.select(active_before, particle_range_alignment_items);
        var context = ParticleJobContext{
            .particles = particles,
            .delta_seconds = delta_seconds,
            .range_count = selection.range_count,
        };
        const batch = dispatch.run(selection, active_before, particle_range_alignment_items, &context, particleJob);
        const removed = self.removeExpiredSwap();
        return .{
            .active_before = active_before,
            .active_after = self.activeCount(),
            .removed_count = removed,
            .perf = if (comptime runtime_perf_log.enabled) .{ .batch = batch } else .{},
        };
    }

    pub fn syncPreviousPositions(self: *ParticleSystem) void {
        var slice_data = self.slice();
        for (0..slice_data.len()) |index| {
            slice_data.previous_x[index] = slice_data.position_x[index];
            slice_data.previous_y[index] = slice_data.position_y[index];
        }
    }

    pub fn clearRetainingCapacity(self: *ParticleSystem) void {
        self.rows.clearRetainingCapacity();
    }

    fn reserveStorage(self: *ParticleSystem, capacity: usize) !void {
        try self.rows.ensureTotalCapacity(self.allocator, hotStoreCapacity(capacity));
    }

    fn removeExpiredSwap(self: *ParticleSystem) usize {
        // Swap removal is intentionally unordered. Render ordering comes from
        // storage order for emission, while the owning state decides which
        // render phase submits particles.
        var removed: usize = 0;
        var index: usize = 0;
        const row_slice = self.rows.slice();
        const ages = row_slice.items(.age);
        const lifetimes = row_slice.items(.lifetime);
        while (index < self.rows.len) {
            if (ages[index] < lifetimes[index]) {
                index += 1;
                continue;
            }
            self.rows.swapRemove(index);
            removed += 1;
        }
        return removed;
    }
};

fn particleJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    // ThreadSystem guarantees ranges do not overlap; processRange only writes
    // columns for the assigned row interval.
    const job: *ParticleJobContext = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / collision.zig). Buffer bounds
    // also live in processRange (shared with the serial path).
    std.debug.assert(range.index < job.range_count);
    processRange(&job.particles, range, job.delta_seconds);
}

// Updates `range` in lane batches; its last batch is the same kernel masked to the rows
// left, so no lane reads or writes past the range. A masked-off lane loads `+0` and so
// divides by a zero lifetime; that lane is never stored.
fn processRange(particles: *ParticleSlice, range: ParallelRange, delta_seconds: f32) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= particles.len());

    var index = range.start;
    const dt = simd.splatFloat4(delta_seconds);
    const zero = simd.splatFloat4(0);
    const one = simd.splatFloat4(1);

    while (index < range.end) : (index += simd.lane_count) {
        const count = range.end - index;
        const position_x = simd.loadFloat4Lanes(particles.position_x[index..], count);
        const position_y = simd.loadFloat4Lanes(particles.position_y[index..], count);
        const velocity_x = simd.loadFloat4Lanes(particles.velocity_x[index..], count);
        const velocity_y = simd.loadFloat4Lanes(particles.velocity_y[index..], count);
        const acceleration_x = simd.loadFloat4Lanes(particles.acceleration_x[index..], count);
        const acceleration_y = simd.loadFloat4Lanes(particles.acceleration_y[index..], count);

        const next_velocity_x = simd.addFloat4(velocity_x, simd.mulFloat4(acceleration_x, dt));
        const next_velocity_y = simd.addFloat4(velocity_y, simd.mulFloat4(acceleration_y, dt));
        const next_position_x = simd.addFloat4(position_x, simd.mulFloat4(next_velocity_x, dt));
        const next_position_y = simd.addFloat4(position_y, simd.mulFloat4(next_velocity_y, dt));
        const next_age = simd.addFloat4(simd.loadFloat4Lanes(particles.age[index..], count), dt);
        const normalized_age = simd.clampFloat4(simd.divFloat4(next_age, simd.loadFloat4Lanes(particles.lifetime[index..], count)), zero, one);

        simd.storeFloat4Lanes(particles.previous_x[index..], position_x, count);
        simd.storeFloat4Lanes(particles.previous_y[index..], position_y, count);
        simd.storeFloat4Lanes(particles.velocity_x[index..], next_velocity_x, count);
        simd.storeFloat4Lanes(particles.velocity_y[index..], next_velocity_y, count);
        simd.storeFloat4Lanes(particles.position_x[index..], next_position_x, count);
        simd.storeFloat4Lanes(particles.position_y[index..], next_position_y, count);
        simd.storeFloat4Lanes(particles.age[index..], next_age, count);
        simd.storeFloat4Lanes(particles.size[index..], simd.lerpFloat4(
            simd.loadFloat4Lanes(particles.start_size[index..], count),
            simd.loadFloat4Lanes(particles.end_size[index..], count),
            normalized_age,
        ), count);
        simd.storeFloat4Lanes(particles.color_r[index..], simd.lerpFloat4(
            simd.loadFloat4Lanes(particles.start_color_r[index..], count),
            simd.loadFloat4Lanes(particles.end_color_r[index..], count),
            normalized_age,
        ), count);
        simd.storeFloat4Lanes(particles.color_g[index..], simd.lerpFloat4(
            simd.loadFloat4Lanes(particles.start_color_g[index..], count),
            simd.loadFloat4Lanes(particles.end_color_g[index..], count),
            normalized_age,
        ), count);
        simd.storeFloat4Lanes(particles.color_b[index..], simd.lerpFloat4(
            simd.loadFloat4Lanes(particles.start_color_b[index..], count),
            simd.loadFloat4Lanes(particles.end_color_b[index..], count),
            normalized_age,
        ), count);
        simd.storeFloat4Lanes(particles.color_a[index..], simd.lerpFloat4(
            simd.loadFloat4Lanes(particles.start_color_a[index..], count),
            simd.loadFloat4Lanes(particles.end_color_a[index..], count),
            normalized_age,
        ), count);
    }
}

fn processRangeScalar(particles: *ParticleSlice, range: ParallelRange, delta_seconds: f32) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= particles.len());

    for (range.start..range.end) |index| {
        processParticleScalar(particles, index, delta_seconds);
    }
}

// Scalar reference for the lane kernel.
fn processParticleScalar(particles: *ParticleSlice, index: usize, delta_seconds: f32) void {
    const position_x = particles.position_x[index];
    const position_y = particles.position_y[index];
    particles.previous_x[index] = position_x;
    particles.previous_y[index] = position_y;

    particles.velocity_x[index] += particles.acceleration_x[index] * delta_seconds;
    particles.velocity_y[index] += particles.acceleration_y[index] * delta_seconds;
    particles.position_x[index] = position_x + particles.velocity_x[index] * delta_seconds;
    particles.position_y[index] = position_y + particles.velocity_y[index] * delta_seconds;
    particles.age[index] += delta_seconds;

    const t = math.clamp(particles.age[index] / particles.lifetime[index], 0, 1);
    particles.size[index] = math.lerp(particles.start_size[index], particles.end_size[index], t);
    particles.color_r[index] = math.lerp(particles.start_color_r[index], particles.end_color_r[index], t);
    particles.color_g[index] = math.lerp(particles.start_color_g[index], particles.end_color_g[index], t);
    particles.color_b[index] = math.lerp(particles.start_color_b[index], particles.end_color_b[index], t);
    particles.color_a[index] = math.lerp(particles.start_color_a[index], particles.end_color_a[index], t);
}

const ParticleJobContext = struct {
    particles: ParticleSlice,
    delta_seconds: f32,
    /// Dispatched range count; dual-asserted against `range.index` at job entry.
    range_count: usize,
};

// `ParticleSystem.update` inline as one range: a thread system with no workers.
fn updateInline(system: *ParticleSystem, delta_seconds: f32) !ParticleUpdateStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    return system.update(&threads, delta_seconds, .{});
}

fn updateSerialScalarForTest(system: *ParticleSystem, delta_seconds: f32) ParticleUpdateStats {
    const active_before = system.activeCount();
    if (active_before == 0) return .{};

    var particles = system.slice();
    processRangeScalar(&particles, .{ .start = 0, .end = active_before }, delta_seconds);
    const removed = system.removeExpiredSwap();
    return .{
        .active_before = active_before,
        .active_after = system.activeCount(),
        .removed_count = removed,
    };
}

fn fillParticles(system: *ParticleSystem, count: usize) void {
    for (0..count) |index| {
        const base: f32 = @floatFromInt(index);
        _ = system.emit(.{
            .position = .{ .x = base * 2, .y = base * -3 },
            .velocity = .{ .x = base + 1, .y = -base - 2 },
            .acceleration = .{ .x = 0.5, .y = 1.25 },
            .lifetime = 10 + base * 0.01,
            .start_size = 8 + base * 0.1,
            .end_size = 2,
            .start_color = .{ .r = 1, .g = 0.5, .b = 0.25, .a = 1 },
            .end_color = .{ .r = 0.25, .g = 0.1, .b = 1, .a = 0 },
            .depth = .effect,
        });
    }
}

fn expectParticleColumnsAligned(system: *const ParticleSystem) !void {
    const particles = system.sliceConst();
    const count = particles.len();
    try std.testing.expectEqual(count, particles.position_y.len);
    try std.testing.expectEqual(count, particles.previous_x.len);
    try std.testing.expectEqual(count, particles.previous_y.len);
    try std.testing.expectEqual(count, particles.velocity_x.len);
    try std.testing.expectEqual(count, particles.velocity_y.len);
    try std.testing.expectEqual(count, particles.acceleration_x.len);
    try std.testing.expectEqual(count, particles.acceleration_y.len);
    try std.testing.expectEqual(count, particles.age.len);
    try std.testing.expectEqual(count, particles.lifetime.len);
    try std.testing.expectEqual(count, particles.size.len);
    try std.testing.expectEqual(count, particles.z.len);
}

// Every updated column of `actual` bit-identical to `expected`'s.
fn expectParticlesBitsEqual(actual: *const ParticleSystem, expected: *const ParticleSystem) !void {
    const actual_particles = actual.sliceConst();
    const expected_particles = expected.sliceConst();
    try std.testing.expectEqual(expected_particles.len(), actual_particles.len());
    inline for (.{ "position_x", "position_y", "previous_x", "previous_y", "velocity_x", "velocity_y", "age", "size", "color_r", "color_g", "color_b", "color_a" }) |column| {
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(@field(expected_particles, column)), std.mem.sliceAsBytes(@field(actual_particles, column)));
    }
}

test "particle system fixed capacity handles excess emission deterministically" {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 2 });
    defer particles.deinit();

    try std.testing.expect(particles.emit(.{}));
    try std.testing.expect(particles.emit(.{}));
    try std.testing.expect(!particles.emit(.{}));
    try std.testing.expectEqual(@as(usize, 2), particles.activeCount());
}

test "particle burst emits deterministic values" {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 8 });
    defer particles.deinit();

    const emitted = particles.emitBurst(.{
        .count = 3,
        .position = .{ .x = 10, .y = 20 },
        .base_velocity = .{ .x = 1, .y = 2 },
        .velocity_step = .{ .x = 3, .y = -1 },
        .lifetime = 0.5,
        .lifetime_step = 0.25,
    });

    try std.testing.expectEqual(@as(usize, 3), emitted);
    const slice_data = particles.sliceConst();
    try std.testing.expectEqual(@as(f32, 1), slice_data.velocity_x[0]);
    try std.testing.expectEqual(@as(f32, 4), slice_data.velocity_x[1]);
    try std.testing.expectEqual(@as(f32, 7), slice_data.velocity_x[2]);
    try std.testing.expectEqual(@as(f32, 0.5), slice_data.lifetime[0]);
    try std.testing.expectEqual(@as(f32, 1.0), slice_data.lifetime[2]);
}

test "particle columns remain aligned after expired swap removal" {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 8 });
    defer particles.deinit();
    _ = particles.emit(.{ .lifetime = 0.1, .velocity = .{ .x = 1, .y = 1 } });
    _ = particles.emit(.{ .lifetime = 4, .velocity = .{ .x = 2, .y = 2 } });
    _ = particles.emit(.{ .lifetime = 0.1, .velocity = .{ .x = 3, .y = 3 } });

    const stats = try updateInline(&particles, 0.2);

    try std.testing.expectEqual(@as(usize, 2), stats.removed_count);
    try std.testing.expectEqual(@as(usize, 1), particles.activeCount());
    try expectParticleColumnsAligned(&particles);
    const alive = particles.sliceConst();
    try std.testing.expectEqual(@as(f32, 2), alive.velocity_x[0]);
}

test "particle render z is relative to emitter base z" {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 1 });
    defer particles.deinit();

    try std.testing.expect(particles.emit(.{
        .base_z = 20,
        .depth = .effect,
        .start_size = 4,
    }));

    const slice_data = particles.sliceConst();
    try std.testing.expectEqual(render_depth.worldZWithOffset(20, .effect), slice_data.z[0]);
}

test "particle render z saturates extreme emitter base z" {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 2 });
    defer particles.deinit();

    try std.testing.expect(particles.emit(.{
        .base_z = std.math.maxInt(i32),
        .depth = .marker,
        .start_size = 4,
    }));
    try std.testing.expect(particles.emit(.{
        .base_z = std.math.minInt(i32),
        .depth = .floor,
        .start_size = 4,
    }));

    const slice_data = particles.sliceConst();
    try std.testing.expectEqual(std.math.maxInt(i32), slice_data.z[0]);
    try std.testing.expectEqual(std.math.minInt(i32), slice_data.z[1]);
}

test "inline particle lane batches, the masked tail included, match the scalar update bit for bit" {
    inline for (.{ 0, 1, 3, 4, 5, 9 }) |count| {
        var simd_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = count });
        defer simd_particles.deinit();
        var scalar_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = count });
        defer scalar_particles.deinit();
        fillParticles(&simd_particles, count);
        fillParticles(&scalar_particles, count);

        _ = try updateInline(&simd_particles, 0.25);
        _ = updateSerialScalarForTest(&scalar_particles, 0.25);

        try expectParticlesBitsEqual(&simd_particles, &scalar_particles);
    }
}

test "threaded particle update matches serial update, the last range ending in the masked tail" {
    const count = particle_range_alignment_items * 8 + 3;
    var threaded_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = count });
    defer threaded_particles.deinit();
    var serial_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = count });
    defer serial_particles.deinit();
    fillParticles(&threaded_particles, count);
    fillParticles(&serial_particles, count);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    _ = threaded_particles.update(&threads, 0.25, .{
        .items_per_range = particle_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    _ = try updateInline(&serial_particles, 0.25);

    try expectParticlesBitsEqual(&threaded_particles, &serial_particles);
}

test "threaded particle update matches serial across multiple range splits and worker counts" {
    // Every explicit partition and worker count reproduces the serial reference: the
    // split invariance the tuner's choice relies on. The last range ends in the masked tail.
    const item_count = particle_range_alignment_items * 8 + 3;
    var serial_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = item_count });
    defer serial_particles.deinit();
    fillParticles(&serial_particles, item_count);
    _ = try updateInline(&serial_particles, 0.25);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 4,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    const splits = [_]struct { items_per_range: usize, workers: usize }{
        .{ .items_per_range = particle_range_alignment_items, .workers = 2 },
        .{ .items_per_range = particle_range_alignment_items * 2, .workers = 2 },
        .{ .items_per_range = particle_range_alignment_items, .workers = 4 },
        .{ .items_per_range = particle_range_alignment_items * 3, .workers = 3 },
    };
    for (splits) |split| {
        var threaded_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = item_count });
        defer threaded_particles.deinit();
        fillParticles(&threaded_particles, item_count);
        _ = threaded_particles.update(&threads, 0.25, .{
            .items_per_range = split.items_per_range,
            .max_worker_threads = split.workers,
            .adaptive = false,
        });
        try expectParticlesBitsEqual(&threaded_particles, &serial_particles);
    }
}

test "particle explicit items_per_range bypasses tuner" {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_range_alignment_items * 8 });
    defer particles.deinit();
    fillParticles(&particles, particle_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    _ = particles.update(&threads, 0.25, .{
        .items_per_range = particle_range_alignment_items,
        .max_worker_threads = 2,
    });

    try std.testing.expectEqual(@as(usize, 0), particles.adaptive_tuner.sample_count);
    try std.testing.expect(particles.adaptive_tuner.last_request == null);
}

test "particle system owns adaptive tuner for default update" {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_range_alignment_items * 8 });
    defer particles.deinit();
    fillParticles(&particles, particle_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    const stats = particles.update(&threads, 0.25, .{ .max_worker_threads = 2 });

    try std.testing.expectEqual(particle_range_alignment_items * 8, stats.active_before);
    try std.testing.expectEqual(@as(usize, 1), particles.adaptive_tuner.sample_count);
    try std.testing.expect(particles.adaptive_tuner.last_request != null);
}

test "a particle range writes only its rows, a masked last batch included" {
    // Whole batches, a whole batch then a one-row tail, and a tail alone.
    for ([_]ParallelRange{ .{ .start = 2, .end = 6 }, .{ .start = 2, .end = 7 }, .{ .start = 5, .end = 8 } }) |range| {
        try expectParticleRangeWritesOnlyItsRows(range);
    }
}

fn expectParticleRangeWritesOnlyItsRows(range: ParallelRange) !void {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 12 });
    defer particles.deinit();
    fillParticles(&particles, 12);

    var untouched = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 12 });
    defer untouched.deinit();
    fillParticles(&untouched, 12);

    var particle_slice = particles.slice();
    processRange(&particle_slice, range, 1.0);

    const data = particles.sliceConst();
    const before = untouched.sliceConst();
    for (0..data.len()) |index| {
        const base: f32 = @floatFromInt(index);
        if (index >= range.start and index < range.end) {
            try std.testing.expectEqual(base * 2, data.previous_x[index]);
            try std.testing.expectEqual(base * -3, data.previous_y[index]);
            try std.testing.expect(data.position_x[index] != base * 2);
            try std.testing.expect(data.position_y[index] != base * -3);
        } else {
            // Every column the kernel writes keeps its bits outside the range.
            inline for (.{ "position_x", "position_y", "previous_x", "previous_y", "velocity_x", "velocity_y", "age", "size", "color_r", "color_g", "color_b", "color_a" }) |column| {
                try std.testing.expectEqual(@as(u32, @bitCast(@field(before, column)[index])), @as(u32, @bitCast(@field(data, column)[index])));
            }
        }
    }
}

test "warmed particle update and emission do not allocate" {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 32 });
    defer particles.deinit();
    fillParticles(&particles, 16);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 0,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    const original_particle_allocator = particles.allocator;
    const original_thread_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    particles.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    defer {
        particles.allocator = original_particle_allocator;
        threads.allocator = original_thread_allocator;
    }

    const emitted = particles.emitBurst(.{ .count = 2, .lifetime = 1 });
    const stats = particles.update(&threads, 0.016, .{
        .items_per_range = particle_range_alignment_items,
    });

    try std.testing.expectEqual(@as(usize, 2), emitted);
    try std.testing.expectEqual(@as(usize, 18), stats.active_before);
}

test "threaded multi-worker particle update has no steady-state allocation after warmup (FailingAllocator)" {
    const count = particle_range_alignment_items * 8;
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = count });
    defer particles.deinit();
    fillParticles(&particles, count);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    _ = particles.update(&threads, 0.016, .{
        .items_per_range = particle_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    const original_particle_allocator = particles.allocator;
    const original_thread_allocator = threads.allocator;
    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    particles.allocator = failing_allocator.allocator();
    threads.allocator = failing_allocator.allocator();
    defer {
        particles.allocator = original_particle_allocator;
        threads.allocator = original_thread_allocator;
    }

    const stats = particles.update(&threads, 0.016, .{
        .items_per_range = particle_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    try std.testing.expectEqual(count, stats.active_before);
}
