// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned transient particle effects.
//! This system intentionally owns its own fixed-capacity SoA pool because
//! particles are visual effect state, not persistent DataSystem entities.

const builtin = @import("builtin");
const std = @import("std");
const config = @import("../../config.zig");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const render_depth = @import("../render_depth.zig");
const WorldDepth = render_depth.WorldDepth;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const alignItemCount = @import("../../app/thread_system.zig").alignItemCount;

pub const hot_particle_column_alignment: usize = 64;
pub const particle_range_alignment_items: usize = hot_particle_column_alignment / @sizeOf(f32);

pub const HotF32Slice = []f32;
pub const ConstHotF32Slice = []const f32;

fn hotStoreCapacity(min_len: usize) usize {
    return alignItemCount(min_len, particle_range_alignment_items);
}

pub const ParticleSystemConfig = struct {
    capacity: usize = 512,
};

pub const ParticleUpdateConfig = struct {
    items_per_range: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
    adaptive_tuner: ?*AdaptiveWorkTuner = null,
};

pub const ParticleUpdateStats = struct {
    active_before: usize = 0,
    active_after: usize = 0,
    removed_count: usize = 0,
    batch: BatchStats = .{},
};

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
        var context = ParticleJobContext{
            .particles = particles,
            .delta_seconds = delta_seconds,
        };
        const adaptive_tuner = if (update_config.adaptive and update_config.items_per_range == null)
            update_config.adaptive_tuner orelse &self.adaptive_tuner
        else
            null;
        const batch = thread_system.parallelForWithOptions(active_before, &context, particleJob, .{
            .items_per_range = update_config.items_per_range,
            .max_worker_threads = update_config.max_worker_threads,
            .range_alignment_items = particle_range_alignment_items,
            .adaptive = update_config.adaptive,
            .adaptive_tuner = adaptive_tuner,
        });
        const removed = self.removeExpiredSwap();
        return .{
            .active_before = active_before,
            .active_after = self.activeCount(),
            .removed_count = removed,
            .batch = batch,
        };
    }

    pub fn updateSerial(self: *ParticleSystem, delta_seconds: f32) ParticleUpdateStats {
        const active_before = self.activeCount();
        if (active_before == 0) return .{};

        var particles = self.slice();
        processRange(&particles, .{ .start = 0, .end = active_before }, delta_seconds);
        const removed = self.removeExpiredSwap();
        return .{
            .active_before = active_before,
            .active_after = self.activeCount(),
            .removed_count = removed,
            .batch = .{
                .item_count = active_before,
                .range_count = if (active_before > 0) 1 else 0,
                .items_per_range = active_before,
                .range_alignment_items = particle_range_alignment_items,
                .main_thread_ranges = if (active_before > 0) 1 else 0,
                .ran_inline = true,
            },
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
    processRange(&job.particles, range, job.delta_seconds);
}

fn processRange(particles: *ParticleSlice, range: ParallelRange, delta_seconds: f32) void {
    // SIMD handles full lane groups, then scalar tail code preserves exact
    // behavior for counts that are not lane-aligned.
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= particles.len());

    var index = range.start;
    const dt = simd.splatFloat4(delta_seconds);
    const zero = simd.splatFloat4(0);
    const one = simd.splatFloat4(1);

    while (index + simd.lane_count <= range.end) : (index += simd.lane_count) {
        const position_x = simd.loadFloat4(particles.position_x[index..]);
        const position_y = simd.loadFloat4(particles.position_y[index..]);
        const velocity_x = simd.loadFloat4(particles.velocity_x[index..]);
        const velocity_y = simd.loadFloat4(particles.velocity_y[index..]);
        const acceleration_x = simd.loadFloat4(particles.acceleration_x[index..]);
        const acceleration_y = simd.loadFloat4(particles.acceleration_y[index..]);

        const next_velocity_x = simd.addFloat4(velocity_x, simd.mulFloat4(acceleration_x, dt));
        const next_velocity_y = simd.addFloat4(velocity_y, simd.mulFloat4(acceleration_y, dt));
        const next_position_x = simd.addFloat4(position_x, simd.mulFloat4(next_velocity_x, dt));
        const next_position_y = simd.addFloat4(position_y, simd.mulFloat4(next_velocity_y, dt));
        const next_age = simd.addFloat4(simd.loadFloat4(particles.age[index..]), dt);
        const normalized_age = simd.clampFloat4(simd.divFloat4(next_age, simd.loadFloat4(particles.lifetime[index..])), zero, one);

        simd.storeFloat4Slice(particles.previous_x[index..], position_x);
        simd.storeFloat4Slice(particles.previous_y[index..], position_y);
        simd.storeFloat4Slice(particles.velocity_x[index..], next_velocity_x);
        simd.storeFloat4Slice(particles.velocity_y[index..], next_velocity_y);
        simd.storeFloat4Slice(particles.position_x[index..], next_position_x);
        simd.storeFloat4Slice(particles.position_y[index..], next_position_y);
        simd.storeFloat4Slice(particles.age[index..], next_age);
        simd.storeFloat4Slice(particles.size[index..], simd.lerpFloat4(
            simd.loadFloat4(particles.start_size[index..]),
            simd.loadFloat4(particles.end_size[index..]),
            normalized_age,
        ));
        simd.storeFloat4Slice(particles.color_r[index..], simd.lerpFloat4(
            simd.loadFloat4(particles.start_color_r[index..]),
            simd.loadFloat4(particles.end_color_r[index..]),
            normalized_age,
        ));
        simd.storeFloat4Slice(particles.color_g[index..], simd.lerpFloat4(
            simd.loadFloat4(particles.start_color_g[index..]),
            simd.loadFloat4(particles.end_color_g[index..]),
            normalized_age,
        ));
        simd.storeFloat4Slice(particles.color_b[index..], simd.lerpFloat4(
            simd.loadFloat4(particles.start_color_b[index..]),
            simd.loadFloat4(particles.end_color_b[index..]),
            normalized_age,
        ));
        simd.storeFloat4Slice(particles.color_a[index..], simd.lerpFloat4(
            simd.loadFloat4(particles.start_color_a[index..]),
            simd.loadFloat4(particles.end_color_a[index..]),
            normalized_age,
        ));
    }

    while (index < range.end) : (index += 1) {
        processParticleScalar(particles, index, delta_seconds);
    }
}

fn processRangeScalar(particles: *ParticleSlice, range: ParallelRange, delta_seconds: f32) void {
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= particles.len());

    for (range.start..range.end) |index| {
        processParticleScalar(particles, index, delta_seconds);
    }
}

fn processParticleScalar(particles: *ParticleSlice, index: usize, delta_seconds: f32) void {
    // Scalar update mirrors the SIMD path for tests and lane tails.
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
};

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
        .batch = .{
            .item_count = active_before,
            .range_count = if (active_before > 0) 1 else 0,
            .items_per_range = active_before,
            .range_alignment_items = particle_range_alignment_items,
            .main_thread_ranges = if (active_before > 0) 1 else 0,
            .ran_inline = true,
        },
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

fn expectParticlesApproxEqual(actual: *const ParticleSystem, expected: *const ParticleSystem) !void {
    const actual_particles = actual.sliceConst();
    const expected_particles = expected.sliceConst();
    try std.testing.expectEqual(expected_particles.len(), actual_particles.len());
    for (0..actual_particles.len()) |index| {
        try std.testing.expectApproxEqAbs(expected_particles.position_x[index], actual_particles.position_x[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.position_y[index], actual_particles.position_y[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.previous_x[index], actual_particles.previous_x[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.previous_y[index], actual_particles.previous_y[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.velocity_x[index], actual_particles.velocity_x[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.velocity_y[index], actual_particles.velocity_y[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.age[index], actual_particles.age[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.size[index], actual_particles.size[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.color_r[index], actual_particles.color_r[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.color_g[index], actual_particles.color_g[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.color_b[index], actual_particles.color_b[index], 0.001);
        try std.testing.expectApproxEqAbs(expected_particles.color_a[index], actual_particles.color_a[index], 0.001);
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

    const stats = particles.updateSerial(0.2);

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

test "serial particle simd path matches scalar path" {
    inline for (.{ 0, 3, 4, 9 }) |count| {
        var simd_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = count });
        defer simd_particles.deinit();
        var scalar_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = count });
        defer scalar_particles.deinit();
        fillParticles(&simd_particles, count);
        fillParticles(&scalar_particles, count);

        _ = simd_particles.updateSerial(0.25);
        _ = updateSerialScalarForTest(&scalar_particles, 0.25);

        try expectParticlesApproxEqual(&simd_particles, &scalar_particles);
    }
}

test "threaded particle update matches serial update" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var threaded_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_range_alignment_items * 8 });
    defer threaded_particles.deinit();
    var serial_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_range_alignment_items * 8 });
    defer serial_particles.deinit();
    fillParticles(&threaded_particles, particle_range_alignment_items * 8);
    fillParticles(&serial_particles, particle_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    const stats = threaded_particles.update(&threads, 0.25, .{
        .items_per_range = particle_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    _ = serial_particles.updateSerial(0.25);

    try std.testing.expect(!stats.batch.ran_inline);
    try std.testing.expectEqual(particle_range_alignment_items, stats.batch.items_per_range);
    try expectParticlesApproxEqual(&threaded_particles, &serial_particles);
}

test "particle explicit items_per_range bypasses tuner" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_range_alignment_items * 8 });
    defer particles.deinit();
    fillParticles(&particles, particle_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{
        .initial_range_items = particle_range_alignment_items * 2,
        .smallest_range_items = particle_range_alignment_items,
        .largest_range_items = particle_range_alignment_items * 4,
    });
    const stats = particles.update(&threads, 0.25, .{
        .items_per_range = particle_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive_tuner = &adaptive_tuner,
    });

    try std.testing.expectEqual(particle_range_alignment_items, stats.batch.items_per_range);
    try std.testing.expectEqual(@as(usize, 0), adaptive_tuner.report().sample_count);
    try std.testing.expectEqual(@as(u64, 0), adaptive_tuner.report().best_mean_batch_duration_ns);
    try std.testing.expectEqual(@as(usize, 0), particles.adaptive_tuner.report().sample_count);
}

test "particle system owns adaptive tuner for default update" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_range_alignment_items * 8 });
    defer particles.deinit();
    fillParticles(&particles, particle_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    var stats = ParticleUpdateStats{};
    for (0..particles.adaptive_tuner.report().sample_window) |_| {
        stats = particles.update(&threads, 0.25, .{
            .max_worker_threads = 2,
        });
    }

    try std.testing.expectEqual(particle_range_alignment_items * 8, stats.active_before);
    try std.testing.expect(particles.adaptive_tuner.report().baseline_mean_batch_duration_ns > 0);
    try std.testing.expect(!particles.adaptive_tuner.report().has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_tuner.report().best_mean_batch_duration_ns);
}

test "particle update uses provided adaptive tuner" {
    if (builtin.single_threaded) return error.SkipZigTest;

    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_range_alignment_items * 8 });
    defer particles.deinit();
    fillParticles(&particles, particle_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = particle_range_alignment_items,
    });
    defer threads.deinit();

    var adaptive_tuner = AdaptiveWorkTuner.init(.{ .sample_window = 1 });
    const stats = particles.update(&threads, 0.25, .{
        .max_worker_threads = 2,
        .adaptive_tuner = &adaptive_tuner,
    });

    try std.testing.expectEqual(particle_range_alignment_items * 8, stats.active_before);
    try std.testing.expect(adaptive_tuner.report().baseline_mean_batch_duration_ns > 0);
    try std.testing.expect(!adaptive_tuner.report().has_threaded_profile);
    try std.testing.expectEqual(@as(u64, 0), threads.adaptive_tuner.report().best_mean_batch_duration_ns);
}

test "particle range only writes assigned rows" {
    var particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = 8 });
    defer particles.deinit();
    fillParticles(&particles, 8);

    var particle_slice = particles.slice();
    processRange(&particle_slice, .{ .start = 2, .end = 6 }, 1.0);

    const data = particles.sliceConst();
    for (0..data.len()) |index| {
        const base: f32 = @floatFromInt(index);
        if (index >= 2 and index < 6) {
            try std.testing.expectEqual(base * 2, data.previous_x[index]);
            try std.testing.expectEqual(base * -3, data.previous_y[index]);
            try std.testing.expect(data.position_x[index] != base * 2);
            try std.testing.expect(data.position_y[index] != base * -3);
        } else {
            try std.testing.expectEqual(base * 2, data.position_x[index]);
            try std.testing.expectEqual(base * -3, data.position_y[index]);
            try std.testing.expectEqual(base * 2, data.previous_x[index]);
            try std.testing.expectEqual(base * -3, data.previous_y[index]);
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
    try std.testing.expect(stats.batch.ran_inline);
}
