// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-owned transient particle effects.
//! This system intentionally owns its own fixed-capacity SoA pool because
//! particles are visual effect state, not persistent DataSystem entities.

const std = @import("std");
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const config = @import("../../config.zig");
const math = @import("../../core/math.zig");
const simd = @import("../../core/simd.zig");
const renderer_mod = @import("../../render/renderer.zig");
const Renderer = renderer_mod.Renderer;

pub const hot_particle_column_alignment: usize = 64;
pub const particle_range_alignment_items: usize = hot_particle_column_alignment / @sizeOf(f32);

const HotF32List = std.ArrayListAligned(f32, .fromByteUnits(hot_particle_column_alignment));
const HotF32Slice = []align(hot_particle_column_alignment) f32;
const ConstHotF32Slice = []align(hot_particle_column_alignment) const f32;

pub const ParticleSystemConfig = struct {
    capacity: usize = 512,
};

pub const ParticleUpdateConfig = struct {
    min_parallel_items: ?usize = null,
    grain_size: ?usize = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

pub const ParticleUpdateStats = struct {
    active_before: usize = 0,
    active_after: usize = 0,
    removed_count: usize = 0,
    batch: BatchStats = .{},
};

pub const ParticleSpawn = struct {
    position: math.Vec2 = .{},
    velocity: math.Vec2 = .{},
    acceleration: math.Vec2 = .{},
    lifetime: f32 = 1,
    start_size: f32 = 4,
    end_size: f32 = 0,
    start_color: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    end_color: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0 },
    layer: i32 = 10,
};

pub const ParticleEmitterConfig = struct {
    count: usize = 1,
    position: math.Vec2 = .{},
    base_velocity: math.Vec2 = .{},
    velocity_step: math.Vec2 = .{},
    acceleration: math.Vec2 = .{},
    lifetime: f32 = 1,
    lifetime_step: f32 = 0,
    start_size: f32 = 4,
    end_size: f32 = 0,
    start_color: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    end_color: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 0 },
    layer: i32 = 10,
};

pub const ParticleSlice = struct {
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
    layers: []i32,

    pub fn len(self: ParticleSlice) usize {
        return self.position_x.len;
    }
};

pub const ConstParticleSlice = struct {
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
    layers: []const i32,

    pub fn len(self: ConstParticleSlice) usize {
        return self.position_x.len;
    }
};

pub const ParticleSystem = struct {
    allocator: std.mem.Allocator,
    capacity: usize,
    position_x: HotF32List = .empty,
    position_y: HotF32List = .empty,
    previous_x: HotF32List = .empty,
    previous_y: HotF32List = .empty,
    velocity_x: HotF32List = .empty,
    velocity_y: HotF32List = .empty,
    acceleration_x: HotF32List = .empty,
    acceleration_y: HotF32List = .empty,
    age: HotF32List = .empty,
    lifetime: HotF32List = .empty,
    size: HotF32List = .empty,
    start_size: HotF32List = .empty,
    end_size: HotF32List = .empty,
    color_r: HotF32List = .empty,
    color_g: HotF32List = .empty,
    color_b: HotF32List = .empty,
    color_a: HotF32List = .empty,
    start_color_r: HotF32List = .empty,
    start_color_g: HotF32List = .empty,
    start_color_b: HotF32List = .empty,
    start_color_a: HotF32List = .empty,
    end_color_r: HotF32List = .empty,
    end_color_g: HotF32List = .empty,
    end_color_b: HotF32List = .empty,
    end_color_a: HotF32List = .empty,
    layers: std.ArrayList(i32) = .empty,

    pub fn init(allocator: std.mem.Allocator, system_config: ParticleSystemConfig) !ParticleSystem {
        var self = ParticleSystem{
            .allocator = allocator,
            .capacity = system_config.capacity,
        };
        errdefer self.deinit();
        try self.reserveStorage(system_config.capacity);
        return self;
    }

    pub fn deinit(self: *ParticleSystem) void {
        self.position_x.deinit(self.allocator);
        self.position_y.deinit(self.allocator);
        self.previous_x.deinit(self.allocator);
        self.previous_y.deinit(self.allocator);
        self.velocity_x.deinit(self.allocator);
        self.velocity_y.deinit(self.allocator);
        self.acceleration_x.deinit(self.allocator);
        self.acceleration_y.deinit(self.allocator);
        self.age.deinit(self.allocator);
        self.lifetime.deinit(self.allocator);
        self.size.deinit(self.allocator);
        self.start_size.deinit(self.allocator);
        self.end_size.deinit(self.allocator);
        self.color_r.deinit(self.allocator);
        self.color_g.deinit(self.allocator);
        self.color_b.deinit(self.allocator);
        self.color_a.deinit(self.allocator);
        self.start_color_r.deinit(self.allocator);
        self.start_color_g.deinit(self.allocator);
        self.start_color_b.deinit(self.allocator);
        self.start_color_a.deinit(self.allocator);
        self.end_color_r.deinit(self.allocator);
        self.end_color_g.deinit(self.allocator);
        self.end_color_b.deinit(self.allocator);
        self.end_color_a.deinit(self.allocator);
        self.layers.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn activeCount(self: *const ParticleSystem) usize {
        return self.position_x.items.len;
    }

    pub fn slice(self: *ParticleSystem) ParticleSlice {
        return .{
            .position_x = self.position_x.items,
            .position_y = self.position_y.items,
            .previous_x = self.previous_x.items,
            .previous_y = self.previous_y.items,
            .velocity_x = self.velocity_x.items,
            .velocity_y = self.velocity_y.items,
            .acceleration_x = self.acceleration_x.items,
            .acceleration_y = self.acceleration_y.items,
            .age = self.age.items,
            .lifetime = self.lifetime.items,
            .size = self.size.items,
            .start_size = self.start_size.items,
            .end_size = self.end_size.items,
            .color_r = self.color_r.items,
            .color_g = self.color_g.items,
            .color_b = self.color_b.items,
            .color_a = self.color_a.items,
            .start_color_r = self.start_color_r.items,
            .start_color_g = self.start_color_g.items,
            .start_color_b = self.start_color_b.items,
            .start_color_a = self.start_color_a.items,
            .end_color_r = self.end_color_r.items,
            .end_color_g = self.end_color_g.items,
            .end_color_b = self.end_color_b.items,
            .end_color_a = self.end_color_a.items,
            .layers = self.layers.items,
        };
    }

    pub fn sliceConst(self: *const ParticleSystem) ConstParticleSlice {
        return .{
            .position_x = self.position_x.items,
            .position_y = self.position_y.items,
            .previous_x = self.previous_x.items,
            .previous_y = self.previous_y.items,
            .velocity_x = self.velocity_x.items,
            .velocity_y = self.velocity_y.items,
            .acceleration_x = self.acceleration_x.items,
            .acceleration_y = self.acceleration_y.items,
            .age = self.age.items,
            .lifetime = self.lifetime.items,
            .size = self.size.items,
            .start_size = self.start_size.items,
            .end_size = self.end_size.items,
            .color_r = self.color_r.items,
            .color_g = self.color_g.items,
            .color_b = self.color_b.items,
            .color_a = self.color_a.items,
            .start_color_r = self.start_color_r.items,
            .start_color_g = self.start_color_g.items,
            .start_color_b = self.start_color_b.items,
            .start_color_a = self.start_color_a.items,
            .end_color_r = self.end_color_r.items,
            .end_color_g = self.end_color_g.items,
            .end_color_b = self.end_color_b.items,
            .end_color_a = self.end_color_a.items,
            .layers = self.layers.items,
        };
    }

    pub fn emit(self: *ParticleSystem, spawn: ParticleSpawn) bool {
        if (self.activeCount() >= self.capacity) return false;
        if (spawn.lifetime <= 0) return false;

        self.position_x.appendAssumeCapacity(spawn.position.x);
        self.position_y.appendAssumeCapacity(spawn.position.y);
        self.previous_x.appendAssumeCapacity(spawn.position.x);
        self.previous_y.appendAssumeCapacity(spawn.position.y);
        self.velocity_x.appendAssumeCapacity(spawn.velocity.x);
        self.velocity_y.appendAssumeCapacity(spawn.velocity.y);
        self.acceleration_x.appendAssumeCapacity(spawn.acceleration.x);
        self.acceleration_y.appendAssumeCapacity(spawn.acceleration.y);
        self.age.appendAssumeCapacity(0);
        self.lifetime.appendAssumeCapacity(spawn.lifetime);
        self.size.appendAssumeCapacity(spawn.start_size);
        self.start_size.appendAssumeCapacity(spawn.start_size);
        self.end_size.appendAssumeCapacity(spawn.end_size);
        self.color_r.appendAssumeCapacity(spawn.start_color.r);
        self.color_g.appendAssumeCapacity(spawn.start_color.g);
        self.color_b.appendAssumeCapacity(spawn.start_color.b);
        self.color_a.appendAssumeCapacity(spawn.start_color.a);
        self.start_color_r.appendAssumeCapacity(spawn.start_color.r);
        self.start_color_g.appendAssumeCapacity(spawn.start_color.g);
        self.start_color_b.appendAssumeCapacity(spawn.start_color.b);
        self.start_color_a.appendAssumeCapacity(spawn.start_color.a);
        self.end_color_r.appendAssumeCapacity(spawn.end_color.r);
        self.end_color_g.appendAssumeCapacity(spawn.end_color.g);
        self.end_color_b.appendAssumeCapacity(spawn.end_color.b);
        self.end_color_a.appendAssumeCapacity(spawn.end_color.a);
        self.layers.appendAssumeCapacity(spawn.layer);
        return true;
    }

    pub fn emitBurst(self: *ParticleSystem, emitter_config: ParticleEmitterConfig) usize {
        var emitted: usize = 0;
        for (0..emitter_config.count) |index| {
            const index_f: f32 = @floatFromInt(index);
            if (self.emit(.{
                .position = emitter_config.position,
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
                .layer = emitter_config.layer,
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
        const active_before = self.activeCount();
        if (active_before == 0) return .{};

        const particles = self.slice();
        var context = ParticleJobContext{
            .particles = particles,
            .delta_seconds = delta_seconds,
        };
        const batch = thread_system.parallelForWithOptions(active_before, &context, particleJob, .{
            .min_parallel_items = update_config.min_parallel_items,
            .grain_size = update_config.grain_size,
            .max_worker_threads = update_config.max_worker_threads,
            .range_alignment_items = particle_range_alignment_items,
            .adaptive = update_config.adaptive,
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
                .grain_size = active_before,
                .range_alignment_items = particle_range_alignment_items,
                .main_thread_ranges = if (active_before > 0) 1 else 0,
                .ran_inline = true,
            },
        };
    }

    pub fn render(self: *const ParticleSystem, renderer: *Renderer, interpolation_alpha: f32) !void {
        const particles = self.sliceConst();
        for (0..particles.len()) |index| {
            const size = particles.size[index];
            if (size <= 0 or particles.color_a[index] <= 0) continue;

            const position = math.lerpVec2(
                .{ .x = particles.previous_x[index], .y = particles.previous_y[index] },
                .{ .x = particles.position_x[index], .y = particles.position_y[index] },
                interpolation_alpha,
            );
            try renderer.drawRect(.{
                .x = position.x - size * 0.5,
                .y = position.y - size * 0.5,
                .w = size,
                .h = size,
            }, .{
                .r = particles.color_r[index],
                .g = particles.color_g[index],
                .b = particles.color_b[index],
                .a = particles.color_a[index],
            }, particles.layers[index]);
        }
    }

    pub fn syncPreviousPositions(self: *ParticleSystem) void {
        for (0..self.activeCount()) |index| {
            self.previous_x.items[index] = self.position_x.items[index];
            self.previous_y.items[index] = self.position_y.items[index];
        }
    }

    pub fn clearRetainingCapacity(self: *ParticleSystem) void {
        self.position_x.clearRetainingCapacity();
        self.position_y.clearRetainingCapacity();
        self.previous_x.clearRetainingCapacity();
        self.previous_y.clearRetainingCapacity();
        self.velocity_x.clearRetainingCapacity();
        self.velocity_y.clearRetainingCapacity();
        self.acceleration_x.clearRetainingCapacity();
        self.acceleration_y.clearRetainingCapacity();
        self.age.clearRetainingCapacity();
        self.lifetime.clearRetainingCapacity();
        self.size.clearRetainingCapacity();
        self.start_size.clearRetainingCapacity();
        self.end_size.clearRetainingCapacity();
        self.color_r.clearRetainingCapacity();
        self.color_g.clearRetainingCapacity();
        self.color_b.clearRetainingCapacity();
        self.color_a.clearRetainingCapacity();
        self.start_color_r.clearRetainingCapacity();
        self.start_color_g.clearRetainingCapacity();
        self.start_color_b.clearRetainingCapacity();
        self.start_color_a.clearRetainingCapacity();
        self.end_color_r.clearRetainingCapacity();
        self.end_color_g.clearRetainingCapacity();
        self.end_color_b.clearRetainingCapacity();
        self.end_color_a.clearRetainingCapacity();
        self.layers.clearRetainingCapacity();
    }

    fn reserveStorage(self: *ParticleSystem, capacity: usize) !void {
        try self.position_x.ensureTotalCapacity(self.allocator, capacity);
        try self.position_y.ensureTotalCapacity(self.allocator, capacity);
        try self.previous_x.ensureTotalCapacity(self.allocator, capacity);
        try self.previous_y.ensureTotalCapacity(self.allocator, capacity);
        try self.velocity_x.ensureTotalCapacity(self.allocator, capacity);
        try self.velocity_y.ensureTotalCapacity(self.allocator, capacity);
        try self.acceleration_x.ensureTotalCapacity(self.allocator, capacity);
        try self.acceleration_y.ensureTotalCapacity(self.allocator, capacity);
        try self.age.ensureTotalCapacity(self.allocator, capacity);
        try self.lifetime.ensureTotalCapacity(self.allocator, capacity);
        try self.size.ensureTotalCapacity(self.allocator, capacity);
        try self.start_size.ensureTotalCapacity(self.allocator, capacity);
        try self.end_size.ensureTotalCapacity(self.allocator, capacity);
        try self.color_r.ensureTotalCapacity(self.allocator, capacity);
        try self.color_g.ensureTotalCapacity(self.allocator, capacity);
        try self.color_b.ensureTotalCapacity(self.allocator, capacity);
        try self.color_a.ensureTotalCapacity(self.allocator, capacity);
        try self.start_color_r.ensureTotalCapacity(self.allocator, capacity);
        try self.start_color_g.ensureTotalCapacity(self.allocator, capacity);
        try self.start_color_b.ensureTotalCapacity(self.allocator, capacity);
        try self.start_color_a.ensureTotalCapacity(self.allocator, capacity);
        try self.end_color_r.ensureTotalCapacity(self.allocator, capacity);
        try self.end_color_g.ensureTotalCapacity(self.allocator, capacity);
        try self.end_color_b.ensureTotalCapacity(self.allocator, capacity);
        try self.end_color_a.ensureTotalCapacity(self.allocator, capacity);
        try self.layers.ensureTotalCapacity(self.allocator, capacity);
    }

    fn removeExpiredSwap(self: *ParticleSystem) usize {
        var removed: usize = 0;
        var index: usize = 0;
        while (index < self.activeCount()) {
            if (self.age.items[index] < self.lifetime.items[index]) {
                index += 1;
                continue;
            }
            self.swapRemove(index);
            removed += 1;
        }
        return removed;
    }

    fn swapRemove(self: *ParticleSystem, index: usize) void {
        const last = self.activeCount() - 1;
        if (index != last) self.copyRow(index, last);
        self.popAll();
    }

    fn copyRow(self: *ParticleSystem, dst: usize, src: usize) void {
        self.position_x.items[dst] = self.position_x.items[src];
        self.position_y.items[dst] = self.position_y.items[src];
        self.previous_x.items[dst] = self.previous_x.items[src];
        self.previous_y.items[dst] = self.previous_y.items[src];
        self.velocity_x.items[dst] = self.velocity_x.items[src];
        self.velocity_y.items[dst] = self.velocity_y.items[src];
        self.acceleration_x.items[dst] = self.acceleration_x.items[src];
        self.acceleration_y.items[dst] = self.acceleration_y.items[src];
        self.age.items[dst] = self.age.items[src];
        self.lifetime.items[dst] = self.lifetime.items[src];
        self.size.items[dst] = self.size.items[src];
        self.start_size.items[dst] = self.start_size.items[src];
        self.end_size.items[dst] = self.end_size.items[src];
        self.color_r.items[dst] = self.color_r.items[src];
        self.color_g.items[dst] = self.color_g.items[src];
        self.color_b.items[dst] = self.color_b.items[src];
        self.color_a.items[dst] = self.color_a.items[src];
        self.start_color_r.items[dst] = self.start_color_r.items[src];
        self.start_color_g.items[dst] = self.start_color_g.items[src];
        self.start_color_b.items[dst] = self.start_color_b.items[src];
        self.start_color_a.items[dst] = self.start_color_a.items[src];
        self.end_color_r.items[dst] = self.end_color_r.items[src];
        self.end_color_g.items[dst] = self.end_color_g.items[src];
        self.end_color_b.items[dst] = self.end_color_b.items[src];
        self.end_color_a.items[dst] = self.end_color_a.items[src];
        self.layers.items[dst] = self.layers.items[src];
    }

    fn popAll(self: *ParticleSystem) void {
        _ = self.position_x.pop();
        _ = self.position_y.pop();
        _ = self.previous_x.pop();
        _ = self.previous_y.pop();
        _ = self.velocity_x.pop();
        _ = self.velocity_y.pop();
        _ = self.acceleration_x.pop();
        _ = self.acceleration_y.pop();
        _ = self.age.pop();
        _ = self.lifetime.pop();
        _ = self.size.pop();
        _ = self.start_size.pop();
        _ = self.end_size.pop();
        _ = self.color_r.pop();
        _ = self.color_g.pop();
        _ = self.color_b.pop();
        _ = self.color_a.pop();
        _ = self.start_color_r.pop();
        _ = self.start_color_g.pop();
        _ = self.start_color_b.pop();
        _ = self.start_color_a.pop();
        _ = self.end_color_r.pop();
        _ = self.end_color_g.pop();
        _ = self.end_color_b.pop();
        _ = self.end_color_a.pop();
        _ = self.layers.pop();
    }
};

fn particleJob(context: *anyopaque, range: ParallelRange, _: @import("../../app/thread_system.zig").WorkerId) void {
    const job: *ParticleJobContext = @ptrCast(@alignCast(context));
    processRange(&job.particles, range, job.delta_seconds);
}

fn processRange(particles: *ParticleSlice, range: ParallelRange, delta_seconds: f32) void {
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
        simd.storeFloat4Slice(particles.size[index..], lerpFloat4(
            simd.loadFloat4(particles.start_size[index..]),
            simd.loadFloat4(particles.end_size[index..]),
            normalized_age,
        ));
        simd.storeFloat4Slice(particles.color_r[index..], lerpFloat4(
            simd.loadFloat4(particles.start_color_r[index..]),
            simd.loadFloat4(particles.end_color_r[index..]),
            normalized_age,
        ));
        simd.storeFloat4Slice(particles.color_g[index..], lerpFloat4(
            simd.loadFloat4(particles.start_color_g[index..]),
            simd.loadFloat4(particles.end_color_g[index..]),
            normalized_age,
        ));
        simd.storeFloat4Slice(particles.color_b[index..], lerpFloat4(
            simd.loadFloat4(particles.start_color_b[index..]),
            simd.loadFloat4(particles.end_color_b[index..]),
            normalized_age,
        ));
        simd.storeFloat4Slice(particles.color_a[index..], lerpFloat4(
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
    particles.size[index] = lerpScalar(particles.start_size[index], particles.end_size[index], t);
    particles.color_r[index] = lerpScalar(particles.start_color_r[index], particles.end_color_r[index], t);
    particles.color_g[index] = lerpScalar(particles.start_color_g[index], particles.end_color_g[index], t);
    particles.color_b[index] = lerpScalar(particles.start_color_b[index], particles.end_color_b[index], t);
    particles.color_a[index] = lerpScalar(particles.start_color_a[index], particles.end_color_a[index], t);
}

fn lerpFloat4(start: simd.Float4, end: simd.Float4, amount: simd.Float4) simd.Float4 {
    return simd.addFloat4(start, simd.mulFloat4(simd.subFloat4(end, start), amount));
}

fn lerpScalar(start: f32, end: f32, amount: f32) f32 {
    return start + (end - start) * amount;
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
            .grain_size = active_before,
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
            .layer = 5,
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
    try std.testing.expectEqual(count, particles.layers.len);
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
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var threaded_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_range_alignment_items * 8 });
    defer threaded_particles.deinit();
    var serial_particles = try ParticleSystem.init(std.testing.allocator, .{ .capacity = particle_range_alignment_items * 8 });
    defer serial_particles.deinit();
    fillParticles(&threaded_particles, particle_range_alignment_items * 8);
    fillParticles(&serial_particles, particle_range_alignment_items * 8);

    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .min_parallel_items = 1,
        .grain_size = particle_range_alignment_items,
    });
    defer threads.deinit();

    const stats = threaded_particles.update(&threads, 0.25, .{
        .min_parallel_items = 1,
        .grain_size = particle_range_alignment_items,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    _ = serial_particles.updateSerial(0.25);

    try std.testing.expect(!stats.batch.ran_inline);
    try expectParticlesApproxEqual(&threaded_particles, &serial_particles);
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
        .min_parallel_items = 1,
        .grain_size = particle_range_alignment_items,
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
        .min_parallel_items = 1,
        .grain_size = particle_range_alignment_items,
    });

    try std.testing.expectEqual(@as(usize, 2), emitted);
    try std.testing.expectEqual(@as(usize, 18), stats.active_before);
    try std.testing.expect(stats.batch.ran_inline);
}
