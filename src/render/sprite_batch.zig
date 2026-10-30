// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Ordered sprite command stream and CPU-side vertex preparation.
//! This module is not a broad sorter: callers submit in nondecreasing
//! RenderOrder, then SpriteBatch snapshots texture metadata before any worker
//! stage expands vertices.

const std = @import("std");
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const AdaptiveWorkTunerConfig = @import("../app/thread_system.zig").AdaptiveWorkTunerConfig;

// Range alignment only; batch time gate comes from AdaptiveWorkTunerConfig defaults.
const sprite_prep_adaptive_tuner_config = AdaptiveWorkTunerConfig{
    .initial_range_items = 64,
    .smallest_range_items = 16,
};
const BatchStats = @import("../app/thread_system.zig").BatchStats;
const Dispatch = @import("../app/thread_system.zig").Dispatch;
const Camera2D = @import("camera.zig").Camera2D;
const config = @import("../config.zig");
const logging = @import("../core/logging.zig");
const math = @import("../core/math.zig");
const ParallelRange = @import("../app/thread_system.zig").ParallelRange;
const resources = @import("resources.zig");
const perf_diagnostics_enabled = @import("../app/runtime_perf_log.zig").enabled;
const setRowCount = @import("../app/thread_system.zig").setRowCount;
const simd = @import("../core/simd.zig");
const ThreadSystem = @import("../app/thread_system.zig").ThreadSystem;
const WorkerId = @import("../app/thread_system.zig").WorkerId;

pub const TextureId = resources.TextureId;

pub const Rect = extern struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
};

pub const CoordinateSpace = enum {
    world,
    logical,
    drawable,
};

pub const RenderDomain = enum(u8) {
    world,
    ui,
    debug,
};

pub const UiDepth = enum(i32) {
    background,
    panel,
    highlight,
    text,
};

const ui_depth_stride: i32 = @intCast(@typeInfo(UiDepth).@"enum".field_names.len);

pub const UiStackOrder = struct {
    index: u16 = 0,

    pub const base: UiStackOrder = .{ .index = 0 };

    pub fn fromRenderOffset(offset: usize) UiStackOrder {
        return .{ .index = @intCast(@min(offset, std.math.maxInt(u16))) };
    }

    fn depthOffset(self: UiStackOrder) i32 {
        return @as(i32, @intCast(self.index)) * ui_depth_stride;
    }
};

pub const DebugDepth = enum(i32) {
    overlay,
};

pub const RenderOrder = struct {
    domain: RenderDomain = .world,
    depth: i32 = 0,

    pub fn world(z: i32) RenderOrder {
        return .{ .domain = .world, .depth = z };
    }

    pub fn ui(depth: UiDepth) RenderOrder {
        return uiInStack(.base, depth);
    }

    pub fn uiInStack(stack_order: UiStackOrder, depth: UiDepth) RenderOrder {
        return .{ .domain = .ui, .depth = stack_order.depthOffset() + @backingInt(depth) };
    }

    pub fn debug(depth: DebugDepth) RenderOrder {
        return .{ .domain = .debug, .depth = @backingInt(depth) };
    }

    pub fn lessOrEqual(lhs: RenderOrder, rhs: RenderOrder) bool {
        const lhs_domain = @backingInt(lhs.domain);
        const rhs_domain = @backingInt(rhs.domain);
        if (lhs_domain != rhs_domain) return lhs_domain < rhs_domain;
        return lhs.depth <= rhs.depth;
    }
};

pub const Sprite = struct {
    texture: TextureId,
    source: ?Rect = null,
    dest: Rect,
    tint: config.Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
    origin: math.Vec2 = .{},
    rotation: f32 = 0,
    order: RenderOrder = .{},
    coordinate_space: CoordinateSpace = .world,
};

pub const CoordinatePresentation = enum {
    // World geometry is emitted in world space; the renderer bakes the camera
    // into the vertex uniform at draw time. Logical/drawable keep their prior
    // viewport-relative meaning.
    world,
    logical,
    drawable,
};

// SoA vertex layout: three dense per-attribute columns, each its own GPU vertex
// buffer bound at a fixed slot. `[N]f32` arrays are tightly packed, so no extern.
// Mapping is fixed across every site: Position slot 0/loc 0/FLOAT2/pitch 8,
// Uv slot 1/loc 1/FLOAT2/pitch 8, VertexColor slot 2/loc 2/FLOAT4/pitch 16.
pub const Position = [2]f32;
pub const Uv = [2]f32;
pub const VertexColor = [4]f32;

/// Vertex emission's range alignment in prepared sprites: each range spans whole cache lines
/// of bytes in every vertex column, so neighbouring ranges share at most their boundary line.
pub const sprite_prep_range_alignment_items: usize = 4;

comptime {
    for ([_]usize{ @sizeOf(Position), @sizeOf(Uv), @sizeOf(VertexColor) }) |vertex_bytes| {
        std.debug.assert(sprite_prep_range_alignment_items * 6 * vertex_bytes % 64 == 0);
    }
}

// Mutable column views threaded into vertex emission (workers write disjoint
// ranges; the world builds 6-corner static spans).
pub const VertexColumns = struct {
    positions: []Position,
    uvs: []Uv,
    colors: []VertexColor,
};

// Read-only column views for upload/append paths.
pub const VertexColumnsConst = struct {
    positions: []const Position,
    uvs: []const Uv,
    colors: []const VertexColor,
};

// Which renderer-owned vertex buffer a draw group indexes. Dynamic groups index
// the per-frame streamed buffer; static groups index the renderer's retained
// slab. The renderer merges both into one order-sorted draw list.
pub const DrawSource = enum {
    dynamic,
    static,
};

// Which pipeline draws a group. `sprite` samples a texture per vertex UV (the
// default path). `tilemap` draws one world-space quad per composite bucket and
// the fragment shader reads tile ids from a shared storage buffer, so a bucket
// of layers is one draw independent of world size.
pub const Material = enum {
    sprite,
    tilemap,
};

/// Fragment uniform (set 3) for a tilemap draw: world-constant grid and atlas
/// geometry, the store's chunk geometry and resident window, and this draw's layer
/// chain. extern, in `tilemap.frag.glsl`'s `TilemapUniform` field order and std140
/// layout. Kept off `DrawGroup` (looked up in the renderer by `tile_data`) so the
/// per-frame draw-group sort/coalesce/merge does not drag this payload through every
/// sprite group.
pub const TilemapParams = extern struct {
    // x=tile_size, y=grid_width, z=grid_height, w=invalid_tile_id
    grid: [4]f32,
    // x=atlas_columns, y=atlas_width_px, z=atlas_height_px, w=atlas_tile_px
    atlas: [4]f32,
    // x=this draw's chained layer count, y=shallowest-bucket flag (both per draw,
    // `Renderer.applyWindowLayers`); z=chunk shift (log2 of the chunk edge),
    // w=directory side in chunks (a power of two), both per store.
    layer_meta: [4]i32 = .{ 0, 0, 0, 0 },
    // The resident chunk window the draw reads: min chunk x, min chunk y,
    // max-exclusive chunk x, max-exclusive chunk y. Chunks outside it draw nothing.
    window: [4]u32 = .{ 0, 0, 0, 0 },
    // x=this draw's topmost directory start (absolute element offset); deeper
    // layers follow each directory's link word. y/z/w unused.
    chain: [4]u32 = .{ 0, 0, 0, 0 },
};

// std140 places every vec4/ivec4/uvec4 member at a 16-byte-aligned offset with no
// padding between them, which is exactly this struct's five 16-byte fields back to
// back.
comptime {
    std.debug.assert(@sizeOf(TilemapParams) == 80);
    std.debug.assert(@offsetOf(TilemapParams, "grid") == 0);
    std.debug.assert(@offsetOf(TilemapParams, "atlas") == 16);
    std.debug.assert(@offsetOf(TilemapParams, "layer_meta") == 32);
    std.debug.assert(@offsetOf(TilemapParams, "window") == 48);
    std.debug.assert(@offsetOf(TilemapParams, "chain") == 64);
}

pub const DrawGroup = struct {
    source: DrawSource = .dynamic,
    material: Material = .sprite,
    texture: TextureId,
    presentation: CoordinatePresentation,
    order: RenderOrder = .{},
    first_vertex: u32,
    vertex_count: u32,
    // Tilemap-material groups only: the world's non-owning tile store id. The
    // grid/atlas uniform lives in the renderer keyed by this id; a stale id (store
    // retired) skips the draw.
    tile_data: resources.TileDataId = .invalid,
    // Tilemap-material groups only: indexes the renderer's per-frame
    // TilemapWindowLayers side table (populated by appendStaticTilemapSpan),
    // giving this draw's topmost directory and chained layer count. Zero (and
    // unused) for non-tilemap groups.
    window_slot: u32 = 0,
};

pub const TextureResolver = struct {
    context: *const anyopaque,
    resolve: *const fn (*const anyopaque, TextureId) ?resources.TextureDesc,

    fn textureDesc(self: TextureResolver, id: TextureId) ?resources.TextureDesc {
        return self.resolve(self.context, id);
    }
};

pub const SpritePrepConfig = struct {
    items_per_range: ?usize = null,
    batches_per_participant: ?f64 = null,
    max_worker_threads: ?usize = null,
    adaptive: bool = true,
};

pub const SpritePrepStats = struct {
    command_count: usize = 0,
    valid_sprite_count: usize = 0,
    skipped_invalid_count: usize = 0,
    vertex_count: usize = 0,
    draw_group_count: usize = 0,
    /// 1 when this reserved frame's submits exceeded its command reservation
    /// (reservation drift), else 0. Always 0 in shipping builds (`ReservationDrift`).
    command_overflow_grows: usize = 0,
    perf: Perf = .{},

    /// The emit batch, kept only with `runtime_perf_log.enabled`.
    pub const Perf = if (perf_diagnostics_enabled) struct { batch: BatchStats = .{} } else struct {};
};

/// Sprite-command reservation drift: a reserved frame whose submits exceed its command
/// reservation (`Renderer.command_high_water`; not the list's physical capacity, which
/// `ensureTotalCapacity` rounds past it). Drift makes `Renderer.ensureFrameBatchCapacity`
/// grow prepared/vertex/group storage (and possibly the GPU streams, a GPU-idle stall)
/// even when the command list itself had slack. Diagnostics only: capacity growth never
/// reads it. Like the runtime perf log, it exists only where `runtime_perf_log.enabled`
/// (Debug/ReleaseSafe); in ReleaseFast/ReleaseSmall it is zero-sized and every call is an
/// empty inline no-op, so no draw-path compare, counter, or warn ships.
const ReservationDrift = if (perf_diagnostics_enabled) struct {
    /// This frame's command reservation, set by `markReserved` and cleared by
    /// `beginFrame`; null in an unreserved frame.
    frame_reservation: ?usize = null,
    /// Lifetime count of drifting reserved frames; zero under a correct reservation.
    lifetime_grows: u64 = 0,
    /// This frame's share of `lifetime_grows` (0 or 1), reported by `finishPrepStats`.
    frame_grows: usize = 0,

    inline fn beginFrame(self: *@This()) void {
        self.frame_reservation = null;
        self.frame_grows = 0;
    }

    /// `len_before` is the command count before the submit that just succeeded; counts
    /// at the one submit that crosses the reservation.
    inline fn noteSubmit(self: *@This(), len_before: usize) void {
        if (self.frame_reservation) |reservation| {
            if (len_before == reservation) self.exceeded(len_before + 1, reservation);
        }
    }

    inline fn markReserved(self: *@This(), reservation: usize, len: usize) void {
        self.frame_reservation = reservation;
        if (len > reservation) self.exceeded(len, reservation);
    }

    inline fn frameGrows(self: *const @This()) usize {
        return self.frame_grows;
    }

    /// Counts one drifting reserved frame (at most once per frame). Warns on the 1st,
    /// 2nd, 4th, 8th, ... drifting frame so a chronically short reservation stays visible
    /// without logging every frame.
    fn exceeded(self: *@This(), count: usize, reservation: usize) void {
        @branchHint(.cold);
        if (self.frame_grows != 0) return;
        self.frame_grows = 1;
        self.lifetime_grows += 1;
        if (comptime logging.enabled(.warn)) {
            if (std.math.isPowerOfTwo(self.lifetime_grows))
                logging.render.warn("sprite commands exceeded the frame reservation ({d} > {d}; {d} frames so far); reserveSpriteCommands bound is short", .{ count, reservation, self.lifetime_grows });
        }
    }
} else struct {
    inline fn beginFrame(_: *@This()) void {}
    inline fn noteSubmit(_: *@This(), _: usize) void {}
    inline fn markReserved(_: *@This(), _: usize, _: usize) void {}
    inline fn frameGrows(_: *const @This()) usize {
        return 0;
    }
};

pub const SpriteBatch = struct {
    pub const CommandList = std.ArrayList(SpriteCommand);

    allocator: std.mem.Allocator,
    commands: CommandList = .empty,
    prepared_sprites: std.MultiArrayList(PreparedSprite) = .empty,
    prepared_groups: std.MultiArrayList(PreparedSpriteGroup) = .empty,
    positions: std.ArrayList(Position) = .empty,
    uvs: std.ArrayList(Uv) = .empty,
    colors: std.ArrayList(VertexColor) = .empty,
    draw_groups: std.ArrayList(DrawGroup) = .empty,
    /// Reservation-drift diagnostics (see `ReservationDrift`); zero-sized in shipping
    /// builds.
    reservation_drift: ReservationDrift = .{},
    camera: Camera2D = .{},
    last_order: ?RenderOrder = null,
    adaptive_tuner: AdaptiveWorkTuner = AdaptiveWorkTuner.init(sprite_prep_adaptive_tuner_config),
    last_prep_stats: SpritePrepStats = .{},

    pub fn init(allocator: std.mem.Allocator) SpriteBatch {
        return .{
            .allocator = allocator,
            .adaptive_tuner = AdaptiveWorkTuner.init(sprite_prep_adaptive_tuner_config),
        };
    }

    pub fn deinit(self: *SpriteBatch) void {
        self.commands.deinit(self.allocator);
        self.prepared_sprites.deinit(self.allocator);
        self.prepared_groups.deinit(self.allocator);
        self.positions.deinit(self.allocator);
        self.uvs.deinit(self.allocator);
        self.colors.deinit(self.allocator);
        self.draw_groups.deinit(self.allocator);
        self.* = init(self.allocator);
    }

    pub fn beginFrame(self: *SpriteBatch) void {
        self.commands.clearRetainingCapacity();
        self.positions.clearRetainingCapacity();
        self.uvs.clearRetainingCapacity();
        self.colors.clearRetainingCapacity();
        self.draw_groups.clearRetainingCapacity();
        self.prepared_sprites.clearRetainingCapacity();
        self.prepared_groups.clearRetainingCapacity();
        self.reservation_drift.beginFrame();
        self.last_order = null;
        self.last_prep_stats = .{};
    }

    pub fn drawSprite(self: *SpriteBatch, sprite: Sprite) !void {
        if (self.last_order) |previous| {
            std.debug.assert(previous.lessOrEqual(sprite.order));
        }
        // Ordered submission keeps the renderer cheap: grouping can preserve
        // stream order instead of sorting every frame.
        const len = self.commands.items.len;
        if (len == self.commands.capacity) try self.growCommands();
        self.commands.appendAssumeCapacity(.{ .sprite = sprite });
        self.last_order = sprite.order;
        // Counted only after the append succeeded (an OOM leaves the stream and the
        // counters unchanged). Compiles out in shipping builds.
        self.reservation_drift.noteSubmit(len);
    }

    /// Marks this frame reserved for `command_reservation` commands. Called by
    /// `Renderer.reserveSpriteCommands` with its grow-only high water, possibly more than
    /// once per frame (the engine's overlay top-up); a frame already past the new
    /// reservation counts as drift now. Diagnostics only (a no-op in shipping builds):
    /// capacity growth never depends on it.
    pub fn markFrameReserved(self: *SpriteBatch, command_reservation: usize) void {
        self.reservation_drift.markReserved(command_reservation, self.commands.items.len);
    }

    /// Cold geometric growth of the command list for one more submit (the same policy
    /// as a growing `append`), so the outcome never depends on growth history. Whether
    /// the growth is drift is decided against the reservation in `drawSprite`.
    fn growCommands(self: *SpriteBatch) !void {
        @branchHint(.cold);
        try self.commands.ensureTotalCapacity(self.allocator, self.commands.items.len + 1);
    }

    pub fn setCamera(self: *SpriteBatch, camera: Camera2D) void {
        self.camera = camera;
    }

    /// Grows CPU batch storage to at least the requested capacities. Grow-only and
    /// non-destructive: a mid-grow `OutOfMemory` leaves prior capacity intact so a
    /// previously reserved frame path stays usable. Does not free on failure.
    pub fn reserveStorage(
        self: *SpriteBatch,
        command_capacity: usize,
        vertex_capacity: usize,
        draw_group_capacity: usize,
    ) !void {
        // `ensureTotalCapacity` is non-destructive on failure; do not `errdefer
        // deinit` here — that would wipe a successful prior reserve when a later
        // grow attempt OOMs.
        const row_capacity = std.mem.alignForward(usize, command_capacity, simd.lane_count);
        try self.commands.ensureTotalCapacity(self.allocator, command_capacity);
        try self.prepared_sprites.ensureTotalCapacity(self.allocator, row_capacity);
        try self.prepared_groups.ensureTotalCapacity(self.allocator, row_capacity);
        try self.positions.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.uvs.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.colors.ensureTotalCapacity(self.allocator, vertex_capacity);
        try self.draw_groups.ensureTotalCapacity(self.allocator, draw_group_capacity);
        std.debug.assert(self.prepared_sprites.capacity >= row_capacity);
        std.debug.assert(self.prepared_groups.capacity >= row_capacity);
    }

    pub fn ensureFrameStorage(self: *SpriteBatch) !void {
        const command_count = self.commands.items.len;
        const needed_vertices = try std.math.mul(usize, command_count, 6);
        if (needed_vertices == 0) return;

        const row_capacity = std.mem.alignForward(usize, command_count, simd.lane_count);
        try self.prepared_sprites.ensureTotalCapacity(self.allocator, row_capacity);
        try self.prepared_groups.ensureTotalCapacity(self.allocator, row_capacity);
        try self.positions.ensureTotalCapacity(self.allocator, needed_vertices);
        try self.uvs.ensureTotalCapacity(self.allocator, needed_vertices);
        try self.colors.ensureTotalCapacity(self.allocator, needed_vertices);
        try self.draw_groups.ensureTotalCapacity(self.allocator, command_count);
        std.debug.assert(self.prepared_sprites.capacity >= row_capacity);
        std.debug.assert(self.prepared_groups.capacity >= row_capacity);
    }

    /// Builds prepared vertices and draw groups without allocating. Callers must
    /// reserve storage for the current command count before entering this path.
    pub fn buildAssumeCapacity(
        self: *SpriteBatch,
        texture_resolver: TextureResolver,
        thread_system: *ThreadSystem,
        prep_config: SpritePrepConfig,
    ) SpritePrepStats {
        _ = self.snapshotCommandsAssumeCapacity(texture_resolver);
        const batch = self.emitVerticesAssumeCapacity(thread_system, prep_config);
        self.buildDrawGroupsAssumeCapacity();
        return self.finishPrepStats(batch);
    }

    /// Snapshots immutable texture metadata for worker-safe CPU prep without
    /// changing submission order. Callers must reserve for the current command count.
    pub fn snapshotCommandsAssumeCapacity(self: *SpriteBatch, texture_resolver: TextureResolver) usize {
        self.positions.clearRetainingCapacity();
        self.uvs.clearRetainingCapacity();
        self.colors.clearRetainingCapacity();
        self.draw_groups.clearRetainingCapacity();
        self.prepared_sprites.clearRetainingCapacity();
        self.prepared_groups.clearRetainingCapacity();

        const command_count = self.commands.items.len;
        std.debug.assert(self.positions.capacity >= command_count * 6);
        std.debug.assert(self.uvs.capacity >= command_count * 6);
        std.debug.assert(self.colors.capacity >= command_count * 6);
        std.debug.assert(self.draw_groups.capacity >= command_count);
        std.debug.assert(self.prepared_sprites.capacity >= command_count);
        std.debug.assert(self.prepared_groups.capacity >= command_count);

        setRowCount(PreparedSprite, &self.prepared_sprites, command_count);
        setRowCount(PreparedSpriteGroup, &self.prepared_groups, command_count);
        const sprites = self.prepared_sprites.slice();
        const groups = self.prepared_groups.slice();
        const rotation = sprites.items(.rotation);
        const origin_x = sprites.items(.origin_x);
        const origin_y = sprites.items(.origin_y);
        const dest_w = sprites.items(.dest_w);
        const dest_h = sprites.items(.dest_h);
        const dest_x = sprites.items(.dest_x);
        const dest_y = sprites.items(.dest_y);
        const source_x = sprites.items(.source_x);
        const source_y = sprites.items(.source_y);
        const source_w = sprites.items(.source_w);
        const source_h = sprites.items(.source_h);
        const tex_w = sprites.items(.tex_w);
        const tex_h = sprites.items(.tex_h);
        const tint_r = sprites.items(.tint_r);
        const tint_g = sprites.items(.tint_g);
        const tint_b = sprites.items(.tint_b);
        const tint_a = sprites.items(.tint_a);
        const texture = groups.items(.texture);
        const coordinate_space = groups.items(.coordinate_space);
        const order = groups.items(.order);

        var prepared: usize = 0;
        for (self.commands.items) |command| {
            const desc = texture_resolver.textureDesc(command.sprite.texture) orelse continue;
            const source = command.sprite.source orelse Rect{
                .x = 0,
                .y = 0,
                .w = @floatFromInt(desc.width),
                .h = @floatFromInt(desc.height),
            };
            const sprite = command.sprite;
            rotation[prepared] = sprite.rotation;
            origin_x[prepared] = sprite.origin.x;
            origin_y[prepared] = sprite.origin.y;
            dest_w[prepared] = sprite.dest.w;
            dest_h[prepared] = sprite.dest.h;
            dest_x[prepared] = sprite.dest.x;
            dest_y[prepared] = sprite.dest.y;
            source_x[prepared] = source.x;
            source_y[prepared] = source.y;
            source_w[prepared] = source.w;
            source_h[prepared] = source.h;
            tex_w[prepared] = @floatFromInt(desc.width);
            tex_h[prepared] = @floatFromInt(desc.height);
            tint_r[prepared] = sprite.tint.r;
            tint_g[prepared] = sprite.tint.g;
            tint_b[prepared] = sprite.tint.b;
            tint_a[prepared] = sprite.tint.a;
            texture[prepared] = sprite.texture;
            coordinate_space[prepared] = sprite.coordinate_space;
            order[prepared] = sprite.order;
            prepared += 1;
        }
        setRowCount(PreparedSprite, &self.prepared_sprites, prepared);
        setRowCount(PreparedSpriteGroup, &self.prepared_groups, prepared);
        return prepared;
    }

    /// Emits vertices for the prepared sprite rows. This is the only
    /// currently thread-schedulable render-prep phase.
    pub fn emitVerticesAssumeCapacity(
        self: *SpriteBatch,
        thread_system: *ThreadSystem,
        prep_config: SpritePrepConfig,
    ) BatchStats {
        const valid_count = self.prepared_sprites.len;
        std.debug.assert(self.prepared_groups.len == valid_count);
        const vertex_count = valid_count * 6;
        setVertexCountAssumeCapacity(Position, &self.positions, vertex_count);
        setVertexCountAssumeCapacity(Uv, &self.uvs, vertex_count);
        setVertexCountAssumeCapacity(VertexColor, &self.colors, vertex_count);

        var batch: BatchStats = .{};
        if (valid_count > 0) {
            const columns = VertexColumns{
                .positions = self.positions.items,
                .uvs = self.uvs.items,
                .colors = self.colors.items,
            };
            // Disjoint vertex ranges from prepared sprite rows. Inline runs
            // this same job. Draw groups stay serial: they depend on ordered
            // texture and presentation transitions.
            const prep = Dispatch.init(thread_system, &self.adaptive_tuner, .{
                .items_per_range = prep_config.items_per_range,
                .batches_per_participant = prep_config.batches_per_participant,
                .max_worker_threads = prep_config.max_worker_threads,
                .adaptive = prep_config.adaptive,
            });
            // Pre-select so the job context can dual-assert range.index against
            // the dispatched range count.
            const selection = prep.select(valid_count, sprite_prep_range_alignment_items);
            var context = SpritePrepJobContext{
                .sprites = self.prepared_sprites.slice(),
                .columns = columns,
                .range_count = selection.range_count,
            };
            batch = prep.run(selection, valid_count, sprite_prep_range_alignment_items, &context, writePreparedSpritesJob);
        }
        return batch;
    }

    pub fn buildDrawGroupsAssumeCapacity(self: *SpriteBatch) void {
        self.buildDrawGroups();
    }

    pub fn finishPrepStats(self: *SpriteBatch, batch: BatchStats) SpritePrepStats {
        self.last_prep_stats = .{
            .command_count = self.commands.items.len,
            .valid_sprite_count = self.prepared_sprites.len,
            .skipped_invalid_count = self.commands.items.len - self.prepared_sprites.len,
            .vertex_count = self.positions.items.len,
            .draw_group_count = self.draw_groups.items.len,
            .command_overflow_grows = self.reservation_drift.frameGrows(),
            .perf = if (comptime perf_diagnostics_enabled) .{ .batch = batch } else .{},
        };
        return self.last_prep_stats;
    }

    pub fn lastPrepStats(self: *const SpriteBatch) SpritePrepStats {
        return self.last_prep_stats;
    }

    fn buildDrawGroups(self: *SpriteBatch) void {
        self.draw_groups.clearRetainingCapacity();

        const groups = self.prepared_groups.slice();
        const textures = groups.items(.texture);
        const spaces = groups.items(.coordinate_space);
        const orders = groups.items(.order);

        var active_texture: ?TextureId = null;
        var active_presentation: CoordinatePresentation = .logical;
        var active_order: RenderOrder = .{};
        var active_first_vertex: u32 = 0;
        var active_vertex_count: u32 = 0;

        for (0..groups.len) |prepared_index| {
            const first_vertex: u32 = @intCast(prepared_index * 6);
            const group_texture = textures[prepared_index];
            const group_order = orders[prepared_index];
            const group_presentation = presentationForCoordinateSpace(spaces[prepared_index]);

            // Break on order change as well as texture/presentation so every group
            // is order-homogeneous. A same-texture run spanning multiple depths must
            // not collapse into one group keyed at its lowest depth, or a static
            // (dense tilemap) span whose order lands inside that range could no
            // longer interleave between the run's depths in the merged draw list.
            // Contiguous same-order groups re-coalesce in the renderer when nothing
            // interleaves, so this does not inflate the steady-state draw count.
            if (active_texture == null or
                !textureIdsEqual(active_texture.?, group_texture) or
                active_presentation != group_presentation or
                !renderOrdersEqual(active_order, group_order))
            {
                if (active_texture) |texture| {
                    self.draw_groups.appendAssumeCapacity(.{
                        .source = .dynamic,
                        .texture = texture,
                        .presentation = active_presentation,
                        .order = active_order,
                        .first_vertex = active_first_vertex,
                        .vertex_count = active_vertex_count,
                    });
                }
                active_texture = group_texture;
                active_presentation = group_presentation;
                active_order = group_order;
                active_first_vertex = first_vertex;
                active_vertex_count = 6;
            } else {
                active_vertex_count += 6;
            }
        }

        if (active_texture) |texture| {
            self.draw_groups.appendAssumeCapacity(.{
                .source = .dynamic,
                .texture = texture,
                .presentation = active_presentation,
                .order = active_order,
                .first_vertex = active_first_vertex,
                .vertex_count = active_vertex_count,
            });
        }
    }
};

const SpriteCommand = struct {
    sprite: Sprite,
};

// SoA rows for the vertex kernel. Field order is that kernel's read order.
const PreparedSprite = struct {
    rotation: f32,
    origin_x: f32,
    origin_y: f32,
    dest_w: f32,
    dest_h: f32,
    dest_x: f32,
    dest_y: f32,
    source_x: f32,
    source_y: f32,
    source_w: f32,
    source_h: f32,
    tex_w: f32,
    tex_h: f32,
    tint_r: f32,
    tint_g: f32,
    tint_b: f32,
    tint_a: f32,
};

// Draw-group keys only. The vertex pass does not read these.
const PreparedSpriteGroup = struct {
    texture: TextureId,
    coordinate_space: CoordinateSpace,
    order: RenderOrder,
};

const PreparedSpriteColumns = struct {
    rotation: []const f32,
    origin_x: []const f32,
    origin_y: []const f32,
    dest_w: []const f32,
    dest_h: []const f32,
    dest_x: []const f32,
    dest_y: []const f32,
    source_x: []const f32,
    source_y: []const f32,
    source_w: []const f32,
    source_h: []const f32,
    tex_w: []const f32,
    tex_h: []const f32,
    tint_r: []const f32,
    tint_g: []const f32,
    tint_b: []const f32,
    tint_a: []const f32,

    fn capture(sprites: std.MultiArrayList(PreparedSprite).Slice) PreparedSpriteColumns {
        return .{
            .rotation = sprites.items(.rotation),
            .origin_x = sprites.items(.origin_x),
            .origin_y = sprites.items(.origin_y),
            .dest_w = sprites.items(.dest_w),
            .dest_h = sprites.items(.dest_h),
            .dest_x = sprites.items(.dest_x),
            .dest_y = sprites.items(.dest_y),
            .source_x = sprites.items(.source_x),
            .source_y = sprites.items(.source_y),
            .source_w = sprites.items(.source_w),
            .source_h = sprites.items(.source_h),
            .tex_w = sprites.items(.tex_w),
            .tex_h = sprites.items(.tex_h),
            .tint_r = sprites.items(.tint_r),
            .tint_g = sprites.items(.tint_g),
            .tint_b = sprites.items(.tint_b),
            .tint_a = sprites.items(.tint_a),
        };
    }
};

const SpritePrepJobContext = struct {
    sprites: std.MultiArrayList(PreparedSprite).Slice,
    columns: VertexColumns,
    /// Dispatched range count; dual-asserted against `range.index` at job entry.
    range_count: usize,
};

fn writePreparedSpritesJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
    const job: *SpritePrepJobContext = @ptrCast(@alignCast(context));
    // Dual worker asserts (mirror affect.zig / particle.zig). Write-span bounds
    // also live in fillPreparedRange.
    std.debug.assert(range.index < job.range_count);
    fillPreparedRange(job.sprites, job.columns, range);
}

fn fillPreparedRange(
    sprites: std.MultiArrayList(PreparedSprite).Slice,
    vertices: VertexColumns,
    range: ParallelRange,
) void {
    // Dual write-range bounds: the sprite rows and the vertex columns the
    // worker writes. Vertex columns are sized to `sprites.len * 6` before
    // dispatch (`emitVerticesAssumeCapacity`).
    std.debug.assert(range.start <= range.end);
    std.debug.assert(range.end <= sprites.len);
    std.debug.assert(range.end * 6 <= vertices.positions.len);
    std.debug.assert(range.end * 6 <= vertices.uvs.len);
    std.debug.assert(range.end * 6 <= vertices.colors.len);
    std.debug.assert(vertices.positions.len == vertices.uvs.len);
    std.debug.assert(vertices.positions.len == vertices.colors.len);
    const columns = PreparedSpriteColumns.capture(sprites);
    var index = range.start;
    while (index + simd.lane_count <= range.end) : (index += simd.lane_count) {
        writeSpriteLanes(&columns, index, simd.lane_count, vertices);
    }
    if (index == range.end) return;
    writeSpriteLanes(&columns, index, range.end - index, vertices);
}

// One lane group of sprites: `count` is `simd.lane_count`, or the short tail.
// Corner x/y/u/v stay in lanes until the six-vert store.
fn writeSpriteLanes(columns: *const PreparedSpriteColumns, base: usize, count: usize, out: VertexColumns) void {
    std.debug.assert(count > 0 and count <= simd.lane_count);
    std.debug.assert(base + count <= columns.rotation.len);
    std.debug.assert((base + count) * 6 <= out.positions.len);

    // simd.zig has no sin/cos, and each sprite has its own angle, so only live
    // lanes are evaluated and then packed. A dead lane is not sined.
    var sine_lanes = [_]f32{ 0, 0, 0, 0 };
    var cosine_lanes = [_]f32{ 0, 0, 0, 0 };
    for (0..count) |lane| {
        const angle = math.sinCos(columns.rotation[base + lane]);
        sine_lanes[lane] = angle.sin;
        cosine_lanes[lane] = angle.cos;
    }
    const sine = simd.loadFloat4Lanes(&sine_lanes, count);
    const cosine = simd.loadFloat4Lanes(&cosine_lanes, count);

    const origin_x = simd.loadFloat4Lanes(columns.origin_x[base..], count);
    const origin_y = simd.loadFloat4Lanes(columns.origin_y[base..], count);
    const dest_w = simd.loadFloat4Lanes(columns.dest_w[base..], count);
    const dest_h = simd.loadFloat4Lanes(columns.dest_h[base..], count);
    const dest_x = simd.loadFloat4Lanes(columns.dest_x[base..], count);
    const dest_y = simd.loadFloat4Lanes(columns.dest_y[base..], count);
    const source_x = simd.loadFloat4Lanes(columns.source_x[base..], count);
    const source_y = simd.loadFloat4Lanes(columns.source_y[base..], count);
    const source_w = simd.loadFloat4Lanes(columns.source_w[base..], count);
    const source_h = simd.loadFloat4Lanes(columns.source_h[base..], count);
    const tex_w = simd.loadFloat4Lanes(columns.tex_w[base..], count);
    const tex_h = simd.loadFloat4Lanes(columns.tex_h[base..], count);
    const tint_r = simd.loadFloat4Lanes(columns.tint_r[base..], count);
    const tint_g = simd.loadFloat4Lanes(columns.tint_g[base..], count);
    const tint_b = simd.loadFloat4Lanes(columns.tint_b[base..], count);
    const tint_a = simd.loadFloat4Lanes(columns.tint_a[base..], count);

    const tex_u0 = simd.divFloat4(source_x, tex_w);
    const tex_u1 = simd.divFloat4(simd.addFloat4(source_x, source_w), tex_w);
    const tex_v0 = simd.divFloat4(source_y, tex_h);
    const tex_v1 = simd.divFloat4(simd.addFloat4(source_y, source_h), tex_h);

    const zero = simd.splatFloat4(0);
    const neg_origin_x = simd.subFloat4(zero, origin_x);
    const neg_origin_y = simd.subFloat4(zero, origin_y);
    const far_x = simd.subFloat4(dest_w, origin_x);
    const far_y = simd.subFloat4(dest_h, origin_y);
    const translate_x = simd.addFloat4(dest_x, origin_x);
    const translate_y = simd.addFloat4(dest_y, origin_y);

    const x0 = simd.addFloat4(simd.subFloat4(simd.mulFloat4(neg_origin_x, cosine), simd.mulFloat4(neg_origin_y, sine)), translate_x);
    const y0 = simd.addFloat4(simd.addFloat4(simd.mulFloat4(neg_origin_x, sine), simd.mulFloat4(neg_origin_y, cosine)), translate_y);
    const x1 = simd.addFloat4(simd.subFloat4(simd.mulFloat4(far_x, cosine), simd.mulFloat4(neg_origin_y, sine)), translate_x);
    const y1 = simd.addFloat4(simd.addFloat4(simd.mulFloat4(far_x, sine), simd.mulFloat4(neg_origin_y, cosine)), translate_y);
    const x2 = simd.addFloat4(simd.subFloat4(simd.mulFloat4(neg_origin_x, cosine), simd.mulFloat4(far_y, sine)), translate_x);
    const y2 = simd.addFloat4(simd.addFloat4(simd.mulFloat4(neg_origin_x, sine), simd.mulFloat4(far_y, cosine)), translate_y);
    const x3 = simd.addFloat4(simd.subFloat4(simd.mulFloat4(far_x, cosine), simd.mulFloat4(far_y, sine)), translate_x);
    const y3 = simd.addFloat4(simd.addFloat4(simd.mulFloat4(far_x, sine), simd.mulFloat4(far_y, cosine)), translate_y);

    const corner_x = [_]simd.Float4{ x0, x1, x2, x3 };
    const corner_y = [_]simd.Float4{ y0, y1, y2, y3 };
    const corner_u = [_]simd.Float4{ tex_u0, tex_u1, tex_u0, tex_u1 };
    const corner_v = [_]simd.Float4{ tex_v0, tex_v0, tex_v1, tex_v1 };
    // Six verts duplicate the four corners. That is not the lane layout, and the
    // GPU columns stay, so the Float4 is indexed here.
    const slots = [_]usize{ 0, 1, 2, 1, 3, 2 };

    inline for (0..simd.lane_count) |lane| {
        if (lane < count) {
            const vert = (base + lane) * 6;
            @memset(out.colors[vert..][0..6], VertexColor{ tint_r[lane], tint_g[lane], tint_b[lane], tint_a[lane] });
            inline for (slots, 0..) |corner, slot| {
                out.positions[vert + slot] = .{ corner_x[corner][lane], corner_y[corner][lane] };
                out.uvs[vert + slot] = .{ corner_u[corner][lane], corner_v[corner][lane] };
            }
        }
    }
}

/// Writes one world-space sprite quad with identity transform. The world builds
/// static tile vertices through this so they are byte-identical to dynamic
/// sprite vertices, without importing gpu/* or the internal PositionTransform.
pub fn writeWorldSpriteQuad(
    sprite: Sprite,
    texture: resources.TextureDesc,
    out: VertexColumns,
) void {
    writeSpriteQuad(sprite, texture, out, 0);
}

// Pure six-vertex quad emission shared by dynamic sprite prep and static tile
// vertex builds, keeping their vertex layout byte-identical. Writes the 6 quad
// verts into each column at `out.*[base .. base + 6]`.
fn writeSpriteQuad(
    sprite: Sprite,
    texture: resources.TextureDesc,
    out: VertexColumns,
    base: usize,
) void {
    std.debug.assert(base + 6 <= out.positions.len);
    std.debug.assert(base + 6 <= out.uvs.len);
    std.debug.assert(base + 6 <= out.colors.len);
    const source = sprite.source orelse Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(texture.width),
        .h = @floatFromInt(texture.height),
    };

    const tex_u0 = source.x / @as(f32, @floatFromInt(texture.width));
    const tex_v0 = source.y / @as(f32, @floatFromInt(texture.height));
    const tex_u1 = (source.x + source.w) / @as(f32, @floatFromInt(texture.width));
    const tex_v1 = (source.y + source.h) / @as(f32, @floatFromInt(texture.height));

    const local = [_]math.Vec2{
        .{ .x = -sprite.origin.x, .y = -sprite.origin.y },
        .{ .x = sprite.dest.w - sprite.origin.x, .y = -sprite.origin.y },
        .{ .x = -sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
        .{ .x = sprite.dest.w - sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
    };
    const uv = [_][2]f32{
        .{ tex_u0, tex_v0 },
        .{ tex_u1, tex_v0 },
        .{ tex_u0, tex_v1 },
        .{ tex_u1, tex_v1 },
    };
    const indices = [_]usize{ 0, 1, 2, 1, 3, 2 };

    const rotation = math.sinCos(sprite.rotation);

    // The quad's four corners are exactly one SIMD lane group: rotate by the shared
    // sin/cos and offset into world space, all four corners at once. Emission is
    // always world/identity space, so there is no post-transform. Lane order
    // matches `local`/`uv`/`indices` above.
    const cos = simd.splatFloat4(rotation.cos);
    const sin = simd.splatFloat4(rotation.sin);
    const local_x = simd.float4(local[0].x, local[1].x, local[2].x, local[3].x);
    const local_y = simd.float4(local[0].y, local[1].y, local[2].y, local[3].y);
    const rotated_x = simd.subFloat4(simd.mulFloat4(local_x, cos), simd.mulFloat4(local_y, sin));
    const rotated_y = simd.addFloat4(simd.mulFloat4(local_x, sin), simd.mulFloat4(local_y, cos));
    const world_x = simd.addFloat4(rotated_x, simd.splatFloat4(sprite.dest.x + sprite.origin.x));
    const world_y = simd.addFloat4(rotated_y, simd.splatFloat4(sprite.dest.y + sprite.origin.y));
    const px = simd.toFloatArray(world_x);
    const py = simd.toFloatArray(world_y);
    var positions: [4]math.Vec2 = undefined;
    inline for (0..4) |index| positions[index] = .{ .x = px[index], .y = py[index] };

    // All six verts share the sprite tint — fill the color column in one splat.
    @memset(out.colors[base..][0..6], VertexColor{ sprite.tint.r, sprite.tint.g, sprite.tint.b, sprite.tint.a });
    for (indices, 0..) |source_index, out_index| {
        const position = positions[source_index];
        out.positions[base + out_index] = .{ position.x, position.y };
        out.uvs[base + out_index] = uv[source_index];
    }
}

fn setVertexCountAssumeCapacity(comptime T: type, column: *std.ArrayList(T), count: usize) void {
    column.clearRetainingCapacity();
    std.debug.assert(column.capacity >= count);
    column.items.len = count;
}

pub fn presentationForCoordinateSpace(coordinate_space: CoordinateSpace) CoordinatePresentation {
    return switch (coordinate_space) {
        .world => .world,
        .logical => .logical,
        .drawable => .drawable,
    };
}

fn textureIdsEqual(lhs: TextureId, rhs: TextureId) bool {
    return lhs.index == rhs.index and lhs.generation == rhs.generation;
}

fn renderOrdersEqual(lhs: RenderOrder, rhs: RenderOrder) bool {
    return lhs.domain == rhs.domain and lhs.depth == rhs.depth;
}

fn spriteCommandsEqual(lhs: []const SpriteCommand, rhs: []const SpriteCommand) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |left, right| {
        const a = left.sprite;
        const b = right.sprite;
        if (a.order.domain != b.order.domain or a.order.depth != b.order.depth) return false;
        if (!a.texture.matches(b.texture.index, b.texture.generation)) return false;
        if (!rectEqualForTest(a.dest, b.dest)) return false;
        if (!optionalRectEqualForTest(a.source, b.source)) return false;
        if (!colorEqualForTest(a.tint, b.tint)) return false;
        if (a.origin.x != b.origin.x or a.origin.y != b.origin.y) return false;
        if (a.rotation != b.rotation) return false;
        if (a.coordinate_space != b.coordinate_space) return false;
    }
    return true;
}

fn rectEqualForTest(a: Rect, b: Rect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

fn optionalRectEqualForTest(a: ?Rect, b: ?Rect) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return rectEqualForTest(a.?, b.?);
}

fn colorEqualForTest(a: config.Color, b: config.Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b and a.a == b.a;
}

fn testTextureId(index: u32, generation: u32) TextureId {
    return TextureId.init(index, generation) catch unreachable;
}

const TestTextureSlot = struct {
    id: TextureId,
    desc: resources.TextureDesc,
    alive: bool = true,
};

const TestTextureTable = struct {
    slots: []const TestTextureSlot,

    fn resolver(self: *const TestTextureTable) TextureResolver {
        return .{
            .context = self,
            .resolve = resolve,
        };
    }

    fn resolve(context: *const anyopaque, id: TextureId) ?resources.TextureDesc {
        const self: *const TestTextureTable = @ptrCast(@alignCast(context));
        if (!id.isValid()) return null;
        for (self.slots) |slot| {
            if (slot.alive and slot.id.matches(id.index, id.generation)) return slot.desc;
        }
        return null;
    }
};

fn initBatchTest(allocator: std.mem.Allocator, table: *const TestTextureTable) !SpriteBatch {
    var batch = SpriteBatch.init(allocator);
    errdefer batch.deinit();
    try batch.reserveStorage(8, 8 * 6, 8);
    _ = table;
    return batch;
}

// The renderer's frame prep: reserve the frame's storage, then build without allocating.
fn prepare(batch: *SpriteBatch, texture_resolver: TextureResolver, thread_system: *ThreadSystem, prep_config: SpritePrepConfig) !SpritePrepStats {
    try batch.ensureFrameStorage();
    return batch.buildAssumeCapacity(texture_resolver, thread_system, prep_config);
}

// Zero-worker system, so this prep dispatches inline.
fn prepareInline(batch: *SpriteBatch, texture_resolver: TextureResolver, prep_config: SpritePrepConfig) !SpritePrepStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    return prepare(batch, texture_resolver, &threads, prep_config);
}

fn buildInline(batch: *SpriteBatch, texture_resolver: TextureResolver, prep_config: SpritePrepConfig) !SpritePrepStats {
    var threads = try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer threads.deinit();
    return batch.buildAssumeCapacity(texture_resolver, &threads, prep_config);
}

test "batch builder skips invalid stale and destroyed texture ids" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 1, .height = 1 } },
        .{ .id = testTextureId(1, 2), .desc = .{ .width = 1, .height = 1 }, .alive = false },
        .{ .id = testTextureId(2, 4), .desc = .{ .width = 1, .height = 1 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(42, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    try batch.drawSprite(.{
        .texture = testTextureId(1, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    try batch.drawSprite(.{
        .texture = testTextureId(2, 3),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });

    _ = try prepareInline(&batch, table.resolver(), .{});

    try std.testing.expectEqual(@as(usize, 6), batch.positions.items.len);
    try std.testing.expectEqual(@as(usize, 1), batch.draw_groups.items.len);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].texture.index);
    try std.testing.expectEqual(CoordinatePresentation.world, batch.draw_groups.items[0].presentation);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[0].vertex_count);
}

test "batch builder groups by texture and coordinate presentation" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 2, .y = 0, .w = 1, .h = 1 },
        .coordinate_space = .logical,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 4, .y = 0, .w = 1, .h = 1 },
        .coordinate_space = .drawable,
    });

    _ = try prepareInline(&batch, table.resolver(), .{});

    try std.testing.expectEqual(@as(usize, 18), batch.positions.items.len);
    try std.testing.expectEqual(@as(usize, 3), batch.draw_groups.items.len);
    try std.testing.expectEqual(CoordinatePresentation.world, batch.draw_groups.items[0].presentation);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[0].vertex_count);
    try std.testing.expectEqual(CoordinatePresentation.logical, batch.draw_groups.items[1].presentation);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[1].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[1].vertex_count);
    try std.testing.expectEqual(CoordinatePresentation.drawable, batch.draw_groups.items[2].presentation);
    try std.testing.expectEqual(@as(u32, 12), batch.draw_groups.items[2].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[2].vertex_count);
}

test "world vertices ignore camera now that the transform is baked on the GPU" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();
    batch.setCamera(.{
        .position = .{ .x = 5, .y = 10 },
        .zoom = 2,
    });

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .logical,
    });

    _ = try prepareInline(&batch, table.resolver(), .{});

    // All spaces emit world/identity-space geometry; the camera is applied by
    // the renderer's vertex uniform, never on the CPU.
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[0][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[0][1]);
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[6][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[6][1]);
    try std.testing.expectEqual(CoordinatePresentation.world, batch.draw_groups.items[0].presentation);
    try std.testing.expectEqual(CoordinatePresentation.logical, batch.draw_groups.items[1].presentation);
}

test "batch builder preserves ordered submission stream" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();
    const OrderedStreamDepth = enum(i32) {
        near,
        far,
    };

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 10, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(@backingInt(OrderedStreamDepth.near)),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(@backingInt(OrderedStreamDepth.far)),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 30, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(@backingInt(OrderedStreamDepth.far)),
    });

    _ = try prepareInline(&batch, table.resolver(), .{});

    try std.testing.expectEqual(@as(f32, 10), batch.positions.items[0][0]);
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[6][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[12][0]);
}

test "sprite batch build consumes the ordered command stream read-only" {
    // SpriteBatch consumes an already-ordered submission stream; it is not a
    // compatibility sorter and must never rewrite any geometry/material field of
    // the commands it just read while building vertices/draw groups from them.
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 64, .height = 64 } },
        .{ .id = testTextureId(1, 1), .desc = .{ .width = 128, .height = 32 } },
        .{ .id = testTextureId(2, 1), .desc = .{ .width = 32, .height = 128 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 1, .y = 2, .w = 3, .h = 4 },
        .source = .{ .x = 5, .y = 6, .w = 7, .h = 8 },
        .tint = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 0.4 },
        .origin = .{ .x = 0.5, .y = 0.5 },
        .rotation = 1.25,
        .order = RenderOrder.world(0),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(1, 1),
        .dest = .{ .x = 10, .y = 20, .w = 30, .h = 40 },
        .order = RenderOrder.world(1),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(2, 1),
        .dest = .{ .x = 100, .y = 200, .w = 300, .h = 400 },
        .order = RenderOrder.world(1),
    });

    var snapshot = SpriteBatch.CommandList.empty;
    defer snapshot.deinit(allocator);
    try snapshot.appendSlice(allocator, batch.commands.items);

    _ = try buildInline(&batch, table.resolver(), .{ .adaptive = false });

    try std.testing.expect(spriteCommandsEqual(snapshot.items, batch.commands.items));
}

test "batch builder splits a same-texture run on render order change" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    // One texture, two depths. Without an order break these collapse into a single
    // group keyed at the lower depth, so a static span at the depth between them
    // could not interleave in the merged draw list.
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(-2),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 2, .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(1),
    });

    _ = try prepareInline(&batch, table.resolver(), .{});

    try std.testing.expectEqual(@as(usize, 2), batch.draw_groups.items.len);
    try std.testing.expectEqual(@as(i32, -2), batch.draw_groups.items[0].order.depth);
    try std.testing.expectEqual(@as(u32, 0), batch.draw_groups.items[0].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[0].vertex_count);
    try std.testing.expectEqual(@as(i32, 1), batch.draw_groups.items[1].order.depth);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[1].first_vertex);
    try std.testing.expectEqual(@as(u32, 6), batch.draw_groups.items[1].vertex_count);
}

test "world and logical vertices stay independent of drawable presentation" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 8, .height = 8 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .world,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .logical,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 20, .y = 30, .w = 1, .h = 1 },
        .coordinate_space = .drawable,
    });

    _ = try prepareInline(&batch, table.resolver(), .{});

    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[0][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[0][1]);
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[6][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[6][1]);
    try std.testing.expectEqual(@as(f32, 20), batch.positions.items[12][0]);
    try std.testing.expectEqual(@as(f32, 30), batch.positions.items[12][1]);
}

test "safe sprite batch build reserves missing frame storage" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 1, .height = 1 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();

    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    const stats = try prepareInline(&batch, table.resolver(), .{ .adaptive = false });

    try std.testing.expectEqual(@as(usize, 1), stats.command_count);
    try std.testing.expectEqual(@as(usize, 6), batch.positions.items.len);
    try std.testing.expectEqual(@as(usize, 1), batch.draw_groups.items.len);
}

test "warmed sprite batch prep does not allocate" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 1, .height = 1 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(1, 6, 1);

    var failing_allocator = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    batch.allocator = failing_allocator.allocator();
    defer batch.allocator = allocator;

    batch.beginFrame();
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    _ = try buildInline(&batch, table.resolver(), .{ .adaptive = false });

    try std.testing.expectEqual(@as(usize, 1), batch.commands.items.len);
    try std.testing.expectEqual(@as(usize, 6), batch.positions.items.len);
    try std.testing.expectEqual(@as(usize, 1), batch.draw_groups.items.len);
}

test "reserveStorage grow failure preserves prior capacity" {
    const allocator = std.testing.allocator;
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();

    try batch.reserveStorage(8, 48, 8);
    const commands_capacity = batch.commands.capacity;
    const positions_capacity = batch.positions.capacity;
    const draw_groups_capacity = batch.draw_groups.capacity;

    const texture = testTextureId(0, 1);
    try batch.drawSprite(.{
        .texture = texture,
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    try std.testing.expectEqual(@as(usize, 1), batch.commands.items.len);

    // Fail the first allocation of a larger reserve. Prior capacity must remain
    // usable — a blanket errdefer deinit would free the successful reserve.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    batch.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, batch.reserveStorage(4096, 4096 * 6, 4096));
    batch.allocator = allocator;

    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expectEqual(commands_capacity, batch.commands.capacity);
    try std.testing.expectEqual(positions_capacity, batch.positions.capacity);
    try std.testing.expectEqual(draw_groups_capacity, batch.draw_groups.capacity);
    try std.testing.expectEqual(@as(usize, 1), batch.commands.items.len);

    // Prior reserved capacity is still usable for submit + prep.
    batch.markFrameReserved(commands_capacity);
    try batch.drawSprite(.{
        .texture = texture,
        .dest = .{ .x = 1, .y = 0, .w = 1, .h = 1 },
    });
    try std.testing.expectEqual(@as(usize, 2), batch.commands.items.len);
    try std.testing.expectEqual(commands_capacity, batch.commands.capacity);
}

test "reserveStorage mid-list grow failure preserves prior data and capacity" {
    const allocator = std.testing.allocator;
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();

    try batch.reserveStorage(8, 48, 8);
    const commands_capacity = batch.commands.capacity;
    const sprites_capacity = batch.prepared_sprites.capacity;
    const groups_capacity = batch.prepared_groups.capacity;
    const positions_capacity = batch.positions.capacity;
    const uvs_capacity = batch.uvs.capacity;
    const colors_capacity = batch.colors.capacity;
    const draw_groups_capacity = batch.draw_groups.capacity;

    const texture = testTextureId(0, 1);
    try batch.drawSprite(.{
        .texture = texture,
        .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
    });
    try std.testing.expectEqual(@as(usize, 1), batch.commands.items.len);

    // reserveStorage grows commands → sprites → groups → positions → …;
    // fail_index=3 lets the first three ensureTotalCapacity calls succeed (and
    // possibly enlarge those lists) then OOMs on positions. Prior data and the
    // later columns' capacity must remain intact — no blanket errdefer deinit.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 3 });
    batch.allocator = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, batch.reserveStorage(4096, 4096 * 6, 4096));
    batch.allocator = allocator;

    try std.testing.expect(failing.has_induced_failure);
    // Early columns may have grown; later ones must still match the prior reserve.
    try std.testing.expect(batch.commands.capacity >= commands_capacity);
    try std.testing.expect(batch.prepared_sprites.capacity >= sprites_capacity);
    try std.testing.expect(batch.prepared_groups.capacity >= groups_capacity);
    try std.testing.expectEqual(positions_capacity, batch.positions.capacity);
    try std.testing.expectEqual(uvs_capacity, batch.uvs.capacity);
    try std.testing.expectEqual(colors_capacity, batch.colors.capacity);
    try std.testing.expectEqual(draw_groups_capacity, batch.draw_groups.capacity);
    try std.testing.expectEqual(@as(usize, 1), batch.commands.items.len);

    batch.markFrameReserved(commands_capacity);
    try batch.drawSprite(.{
        .texture = texture,
        .dest = .{ .x = 1, .y = 0, .w = 1, .h = 1 },
    });
    try std.testing.expectEqual(@as(usize, 2), batch.commands.items.len);
}

test "render order compares domain before depth" {
    const ComparisonDepth = enum(i32) {
        below_ground = -1,
        ground = 0,
        above_ground = 1,
    };
    const high_world = RenderOrder.world(@backingInt(ComparisonDepth.above_ground));
    const ui_background = RenderOrder.ui(.background);
    const ui_text = RenderOrder.ui(.text);
    const debug_overlay = RenderOrder.debug(.overlay);
    const below_ground = RenderOrder.world(@backingInt(ComparisonDepth.below_ground));
    const ground = RenderOrder.world(@backingInt(ComparisonDepth.ground));

    try std.testing.expect(high_world.lessOrEqual(ui_background));
    try std.testing.expect(ui_text.lessOrEqual(debug_overlay));
    try std.testing.expect(below_ground.lessOrEqual(ground));
    try std.testing.expect(!debug_overlay.lessOrEqual(ground));
    try std.testing.expect(!ground.lessOrEqual(below_ground));
}

test "ui stack order keeps upper state background above lower state text" {
    const lower_text = RenderOrder.uiInStack(UiStackOrder.fromRenderOffset(0), .text);
    const upper_background = RenderOrder.uiInStack(UiStackOrder.fromRenderOffset(1), .background);

    try std.testing.expect(lower_text.lessOrEqual(upper_background));
}

test "parallel sprite prep matches serial vertices and draw groups" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 64, .height = 32 } },
        .{ .id = testTextureId(1, 1), .desc = .{ .width = 16, .height = 16 } },
        .{ .id = testTextureId(2, 1), .desc = .{ .width = 8, .height = 8 }, .alive = false },
    };
    const table = TestTextureTable{ .slots = &slots };
    var serial = try initBatchTest(allocator, &table);
    defer serial.deinit();
    var threaded = try initBatchTest(allocator, &table);
    defer threaded.deinit();
    try serial.reserveStorage(16, 16 * 6, 16);
    try threaded.reserveStorage(16, 16 * 6, 16);

    try addParallelParityCommands(&serial);
    try addParallelParityCommands(&threaded);

    var inline_threads = try ThreadSystem.init(allocator, std.testing.io, .{ .max_worker_threads = 0 });
    defer inline_threads.deinit();
    _ = try prepare(&serial, table.resolver(), &inline_threads, .{});

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();
    _ = try prepare(&threaded, table.resolver(), &threads, .{
        .items_per_range = 1,
        .max_worker_threads = 2,
        .adaptive = false,
    });

    try expectEqualVertices(batchColumns(&serial), batchColumns(&threaded));
    try expectEqualDrawGroups(serial.draw_groups.items, threaded.draw_groups.items);
    try std.testing.expectEqual(serial.lastPrepStats().valid_sprite_count, threaded.lastPrepStats().valid_sprite_count);
    try std.testing.expectEqual(@as(usize, 2), threaded.lastPrepStats().skipped_invalid_count);
}

test "sprite prep records one sample into its own tuner" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 16, .height = 16 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(64, 64 * 6, 64);
    for (0..64) |index| {
        try batch.drawSprite(.{
            .texture = testTextureId(0, 1),
            .dest = .{
                .x = @floatFromInt(index),
                .y = @floatFromInt(index % 7),
                .w = 8,
                .h = 8,
            },
        });
    }

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();
    _ = try prepare(&batch, table.resolver(), &threads, .{});

    try std.testing.expectEqual(@as(usize, 1), batch.adaptive_tuner.sample_count);
    try std.testing.expect(batch.adaptive_tuner.last_request != null);
}

test "sprite prep adaptive gate keeps cheap batches inline" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 16, .height = 16 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();
    try batch.reserveStorage(90, 90 * 6, 90);
    for (0..90) |index| {
        try batch.drawSprite(.{
            .texture = testTextureId(0, 1),
            .dest = .{
                .x = @floatFromInt(index),
                .y = @floatFromInt(index % 11),
                .w = 8,
                .h = 8,
            },
        });
    }

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{
        .max_worker_threads = 9,
        .items_per_range = 1,
    });
    defer threads.deinit();

    // Production prep uses the central gate. The run below pins a gate no batch
    // reaches, so the inline decision holds on any host and build mode.
    try std.testing.expectEqual((AdaptiveWorkTunerConfig{}).threaded_batch_ns, batch.adaptive_tuner.config.threaded_batch_ns);
    batch.adaptive_tuner.config.threaded_batch_ns = std.math.maxInt(u64);

    const warmup_windows = batch.adaptive_tuner.config.sample_window * 4;
    var window: usize = 0;
    while (window < warmup_windows) : (window += 1) {
        _ = try prepare(&batch, table.resolver(), &threads, .{});
    }

    try std.testing.expect(batch.adaptive_tuner.last_request != null);
    try std.testing.expect(!batch.adaptive_tuner.has_threaded_profile);
}

test "warmed multi-worker sprite prep does not allocate" {
    const allocator = std.testing.allocator;
    const slots = [_]TestTextureSlot{
        .{ .id = testTextureId(0, 1), .desc = .{ .width = 16, .height = 16 } },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();

    // Enough commands that 4-command range alignment yields multiple ranges and
    // the thread system actually recruits a worker (not only the serial slot-0 path).
    const command_capacity: usize = 32;
    try batch.reserveStorage(command_capacity, command_capacity * 6, command_capacity);
    for (0..command_capacity) |index| {
        try batch.drawSprite(.{
            .texture = testTextureId(0, 1),
            .dest = .{
                .x = @floatFromInt(index),
                .y = @floatFromInt(index % 5),
                .w = 4,
                .h = 4,
            },
        });
    }

    var threads = try ThreadSystem.init(allocator, std.testing.io, .{
        .max_worker_threads = 2,
        .items_per_range = 1,
    });
    defer threads.deinit();

    // Reserved-then-build SUCCESS branch under a hard-failing allocator: proves
    // the multi-worker emit path is allocation-free after reserve (not only the
    // serial inline branch). Snapshot, emit, and draw groups are `buildAssumeCapacity`;
    // the emit batch is the fixed-shape dispatch. An inline emit has no worker ranges.
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    batch.allocator = failing.allocator();
    defer batch.allocator = allocator;

    _ = batch.snapshotCommandsAssumeCapacity(table.resolver());
    const emit = batch.emitVerticesAssumeCapacity(&threads, .{
        .items_per_range = 1,
        .max_worker_threads = 2,
        .adaptive = false,
    });
    batch.buildDrawGroupsAssumeCapacity();
    const stats = batch.finishPrepStats(emit);

    try std.testing.expectEqual(command_capacity, stats.valid_sprite_count);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(command_capacity, batch.commands.items.len);
    try std.testing.expectEqual(command_capacity * 6, batch.positions.items.len);
    try std.testing.expect(!emit.ran_inline);
    try std.testing.expect(emit.active_worker_threads > 0);
    try std.testing.expect(emit.worker_thread_ranges > 0);
}

test "sprite prep lanes match one-quad vertices" {
    const allocator = std.testing.allocator;
    const desc = resources.TextureDesc{ .width = 64, .height = 32 };
    const texture = testTextureId(0, 1);
    const slots = [_]TestTextureSlot{
        .{ .id = texture, .desc = desc },
    };
    const table = TestTextureTable{ .slots = &slots };
    var batch = try initBatchTest(allocator, &table);
    defer batch.deinit();

    // One full lane group plus a prefix. The unresolved texture sits between
    // the valid sprites and must not leave a vertex hole.
    const valid = [_]Sprite{
        .{
            .texture = texture,
            .dest = .{ .x = 1, .y = 2, .w = 8, .h = 9 },
        },
        .{
            .texture = texture,
            .source = .{ .x = 2, .y = 3, .w = 4, .h = 5 },
            .dest = .{ .x = 11, .y = 13, .w = 15, .h = 17 },
            .origin = .{ .x = 1.5, .y = 2.5 },
            .rotation = 0.35,
            .tint = .{ .r = 0.25, .g = 0.5, .b = 0.75, .a = 1 },
        },
        .{
            .texture = texture,
            .dest = .{ .x = 3, .y = 4, .w = 5, .h = 6 },
            .rotation = -0.2,
        },
        .{
            .texture = texture,
            .dest = .{ .x = 7, .y = 8, .w = 9, .h = 10 },
            .origin = .{ .x = 0.5, .y = 0.25 },
        },
        .{
            .texture = texture,
            .source = .{ .x = 1, .y = 1, .w = 6, .h = 7 },
            .dest = .{ .x = -4, .y = 6, .w = 12, .h = 14 },
            .origin = .{ .x = 2, .y = 3 },
            .rotation = 1.1,
            .tint = .{ .r = 1, .g = 0, .b = 0.5, .a = 0.25 },
        },
    };
    try std.testing.expectEqual(simd.lane_count + 1, valid.len);
    for (valid, 0..) |sprite, index| {
        if (index == 2) {
            try batch.drawSprite(.{
                .texture = testTextureId(9, 1),
                .dest = .{ .x = 0, .y = 0, .w = 1, .h = 1 },
            });
        }
        try batch.drawSprite(sprite);
    }

    const stats = try prepareInline(&batch, table.resolver(), .{});
    try std.testing.expectEqual(simd.lane_count + 1, stats.valid_sprite_count);
    try std.testing.expectEqual(@as(usize, 1), stats.skipped_invalid_count);
    try std.testing.expectEqual((simd.lane_count + 1) * 6, stats.vertex_count);

    for (valid, 0..) |sprite, prepared| {
        var positions: [6]Position = undefined;
        var uvs: [6]Uv = undefined;
        var colors: [6]VertexColor = undefined;
        writeWorldSpriteQuad(sprite, desc, .{
            .positions = &positions,
            .uvs = &uvs,
            .colors = &colors,
        });
        const base = prepared * 6;
        try expectEqualVertices(.{
            .positions = &positions,
            .uvs = &uvs,
            .colors = &colors,
        }, .{
            .positions = batch.positions.items[base..][0..6],
            .uvs = batch.uvs.items[base..][0..6],
            .colors = batch.colors.items[base..][0..6],
        });
    }
}

fn addParallelParityCommands(batch: *SpriteBatch) !void {
    batch.setCamera(.{ .position = .{ .x = 4, .y = 2 }, .zoom = 1.5 });
    const ParityDepth = enum(i32) {
        invalid_background = -5,
        world_sprite = 1,
        logical_sprite = 2,
        foreground = 3,
    };
    try batch.drawSprite(.{
        .texture = testTextureId(2, 1),
        .dest = .{ .x = -10, .y = 0, .w = 12, .h = 12 },
        .order = RenderOrder.world(@backingInt(ParityDepth.invalid_background)),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .source = .{ .x = 4, .y = 6, .w = 12, .h = 10 },
        .dest = .{ .x = 20, .y = 30, .w = 16, .h = 18 },
        .origin = .{ .x = 8, .y = 9 },
        .rotation = 0.25,
        .tint = .{ .r = 0.2, .g = 0.5, .b = 0.8, .a = 0.9 },
        .order = RenderOrder.world(@backingInt(ParityDepth.world_sprite)),
        .coordinate_space = .world,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(1, 1),
        .dest = .{ .x = 12, .y = 14, .w = 8, .h = 8 },
        .order = RenderOrder.world(@backingInt(ParityDepth.logical_sprite)),
        .coordinate_space = .logical,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(0, 1),
        .dest = .{ .x = 60, .y = 12, .w = 10, .h = 10 },
        .order = RenderOrder.world(@backingInt(ParityDepth.logical_sprite)),
        .coordinate_space = .drawable,
    });
    try batch.drawSprite(.{
        .texture = testTextureId(99, 1),
        .dest = .{ .x = 0, .y = 0, .w = 4, .h = 4 },
        .order = RenderOrder.world(@backingInt(ParityDepth.foreground)),
    });
    try batch.drawSprite(.{
        .texture = testTextureId(1, 1),
        .dest = .{ .x = 2, .y = 6, .w = 7, .h = 9 },
        .origin = .{ .x = 3, .y = 4 },
        .rotation = -0.5,
        .order = RenderOrder.world(@backingInt(ParityDepth.foreground)),
        .coordinate_space = .world,
    });
    // Extra valid sprites so the 4-command range alignment yields more than one
    // range (>=8 valid -> >=2 aligned ranges), keeping the threaded path from
    // collapsing to a single inline range and actually recruiting a worker.
    for (0..5) |index| {
        try batch.drawSprite(.{
            .texture = testTextureId(0, 1),
            .dest = .{
                .x = @floatFromInt(40 + index),
                .y = @floatFromInt(index % 3),
                .w = 6,
                .h = 6,
            },
            .origin = .{ .x = 1, .y = 2 },
            .rotation = @as(f32, @floatFromInt(index)) * 0.1,
            .tint = .{ .r = 0.3, .g = 0.4, .b = 0.5, .a = 1 },
            .order = RenderOrder.world(@backingInt(ParityDepth.foreground)),
            .coordinate_space = .world,
        });
    }
}

fn batchColumns(batch: *const SpriteBatch) VertexColumnsConst {
    return .{
        .positions = batch.positions.items,
        .uvs = batch.uvs.items,
        .colors = batch.colors.items,
    };
}

fn expectEqualVertices(expected: VertexColumnsConst, actual: VertexColumnsConst) !void {
    try std.testing.expectEqual(expected.positions.len, actual.positions.len);
    try std.testing.expectEqual(expected.uvs.len, actual.uvs.len);
    try std.testing.expectEqual(expected.colors.len, actual.colors.len);
    for (expected.positions, actual.positions) |lhs, rhs| {
        try std.testing.expectEqual(lhs[0], rhs[0]);
        try std.testing.expectEqual(lhs[1], rhs[1]);
    }
    for (expected.uvs, actual.uvs) |lhs, rhs| {
        try std.testing.expectEqual(lhs[0], rhs[0]);
        try std.testing.expectEqual(lhs[1], rhs[1]);
    }
    for (expected.colors, actual.colors) |lhs, rhs| {
        try std.testing.expectEqual(lhs[0], rhs[0]);
        try std.testing.expectEqual(lhs[1], rhs[1]);
        try std.testing.expectEqual(lhs[2], rhs[2]);
        try std.testing.expectEqual(lhs[3], rhs[3]);
    }
}

// AoS oracle: the original interleaved emission arithmetic, kept verbatim so the
// SoA columns are proven bit-exact against it (same simd/math ops -> last-ULP
// identical, no approx). Guards column desync and lane/attribute transposition.
const AosVertex = struct {
    position: [2]f32,
    uv: [2]f32,
    color: [4]f32,
};

fn aosOracleQuad(sprite: Sprite, texture: resources.TextureDesc, out: *[6]AosVertex) void {
    const source = sprite.source orelse Rect{
        .x = 0,
        .y = 0,
        .w = @floatFromInt(texture.width),
        .h = @floatFromInt(texture.height),
    };

    const tex_u0 = source.x / @as(f32, @floatFromInt(texture.width));
    const tex_v0 = source.y / @as(f32, @floatFromInt(texture.height));
    const tex_u1 = (source.x + source.w) / @as(f32, @floatFromInt(texture.width));
    const tex_v1 = (source.y + source.h) / @as(f32, @floatFromInt(texture.height));

    const local = [_]math.Vec2{
        .{ .x = -sprite.origin.x, .y = -sprite.origin.y },
        .{ .x = sprite.dest.w - sprite.origin.x, .y = -sprite.origin.y },
        .{ .x = -sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
        .{ .x = sprite.dest.w - sprite.origin.x, .y = sprite.dest.h - sprite.origin.y },
    };
    const uv = [_][2]f32{
        .{ tex_u0, tex_v0 },
        .{ tex_u1, tex_v0 },
        .{ tex_u0, tex_v1 },
        .{ tex_u1, tex_v1 },
    };
    const indices = [_]usize{ 0, 1, 2, 1, 3, 2 };

    const rotation = math.sinCos(sprite.rotation);
    const cos = simd.splatFloat4(rotation.cos);
    const sin = simd.splatFloat4(rotation.sin);
    const local_x = simd.float4(local[0].x, local[1].x, local[2].x, local[3].x);
    const local_y = simd.float4(local[0].y, local[1].y, local[2].y, local[3].y);
    const rotated_x = simd.subFloat4(simd.mulFloat4(local_x, cos), simd.mulFloat4(local_y, sin));
    const rotated_y = simd.addFloat4(simd.mulFloat4(local_x, sin), simd.mulFloat4(local_y, cos));
    const world_x = simd.addFloat4(rotated_x, simd.splatFloat4(sprite.dest.x + sprite.origin.x));
    const world_y = simd.addFloat4(rotated_y, simd.splatFloat4(sprite.dest.y + sprite.origin.y));
    // Identity emit transform (scale=1, offset=0), applied with the same ops as
    // writeSpriteQuad so the oracle is bit-exact.
    const final_x = simd.addFloat4(simd.mulFloat4(world_x, simd.splatFloat4(1)), simd.splatFloat4(0));
    const final_y = simd.addFloat4(simd.mulFloat4(world_y, simd.splatFloat4(1)), simd.splatFloat4(0));
    const px = simd.toFloatArray(final_x);
    const py = simd.toFloatArray(final_y);
    var positions: [4]math.Vec2 = undefined;
    inline for (0..4) |index| positions[index] = .{ .x = px[index], .y = py[index] };

    for (indices, 0..) |source_index, out_index| {
        const position = positions[source_index];
        out[out_index] = .{
            .position = .{ position.x, position.y },
            .uv = uv[source_index],
            .color = .{ sprite.tint.r, sprite.tint.g, sprite.tint.b, sprite.tint.a },
        };
    }
}

test "soa columns reconstruct the AoS oracle vertex layout" {
    const texture = resources.TextureDesc{ .width = 64, .height = 32 };
    const sprites = [_]Sprite{
        .{ .texture = testTextureId(0, 1), .dest = .{ .x = 20, .y = 30, .w = 16, .h = 18 } },
        .{
            .texture = testTextureId(0, 1),
            .source = .{ .x = 4, .y = 6, .w = 12, .h = 10 },
            .dest = .{ .x = -10, .y = 5, .w = 14, .h = 9 },
            .origin = .{ .x = 8, .y = 9 },
            .rotation = 0.37,
            .tint = .{ .r = 0.2, .g = 0.5, .b = 0.8, .a = 0.9 },
        },
        .{
            .texture = testTextureId(0, 1),
            .dest = .{ .x = 3, .y = 7, .w = 5, .h = 11 },
            .origin = .{ .x = 2, .y = 1 },
            .rotation = -1.2,
            .tint = .{ .r = 1, .g = 0, .b = 0.25, .a = 0.5 },
        },
    };

    for (sprites) |sprite| {
        var positions: [6]Position = undefined;
        var uvs: [6]Uv = undefined;
        var colors: [6]VertexColor = undefined;
        writeWorldSpriteQuad(sprite, texture, .{
            .positions = &positions,
            .uvs = &uvs,
            .colors = &colors,
        });

        var oracle: [6]AosVertex = undefined;
        aosOracleQuad(sprite, texture, &oracle);

        for (0..6) |i| {
            try std.testing.expectEqual(oracle[i].position[0], positions[i][0]);
            try std.testing.expectEqual(oracle[i].position[1], positions[i][1]);
            try std.testing.expectEqual(oracle[i].uv[0], uvs[i][0]);
            try std.testing.expectEqual(oracle[i].uv[1], uvs[i][1]);
            try std.testing.expectEqual(oracle[i].color[0], colors[i][0]);
            try std.testing.expectEqual(oracle[i].color[1], colors[i][1]);
            try std.testing.expectEqual(oracle[i].color[2], colors[i][2]);
            try std.testing.expectEqual(oracle[i].color[3], colors[i][3]);
        }
    }
}

fn expectEqualDrawGroups(expected: []const DrawGroup, actual: []const DrawGroup) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |lhs, rhs| {
        try std.testing.expectEqual(lhs.texture.index, rhs.texture.index);
        try std.testing.expectEqual(lhs.texture.generation, rhs.texture.generation);
        try std.testing.expectEqual(lhs.presentation, rhs.presentation);
        try std.testing.expectEqual(lhs.first_vertex, rhs.first_vertex);
        try std.testing.expectEqual(lhs.vertex_count, rhs.vertex_count);
    }
}

test "draw sprite stays allocation-free after reserve" {
    const allocator = std.testing.allocator;
    var batch = SpriteBatch.init(allocator);
    defer batch.deinit();

    const command_capacity: usize = 8;
    try batch.reserveStorage(command_capacity, command_capacity * 6, command_capacity);
    batch.markFrameReserved(command_capacity);
    const capacity_before = batch.commands.capacity;

    const texture = TextureId.init(0, 1) catch unreachable;
    for (0..command_capacity) |i| {
        try batch.drawSprite(.{
            .texture = texture,
            .dest = .{ .x = @floatFromInt(i), .y = 0, .w = 1, .h = 1 },
            .order = RenderOrder.world(@intCast(i)),
        });
    }

    try std.testing.expectEqual(capacity_before, batch.commands.capacity);
    try std.testing.expectEqual(command_capacity, batch.commands.items.len);
}

/// Reserves 8 commands, marks the frame reserved at the list's physical capacity (which
/// `ensureTotalCapacity` may round past 8), and fills it to that capacity. Returns it.
fn fillReservedCommandsToCapacity(batch: *SpriteBatch) !usize {
    const command_capacity: usize = 8;
    try batch.reserveStorage(command_capacity, command_capacity * 6, command_capacity);
    batch.markFrameReserved(batch.commands.capacity);
    const capacity = batch.commands.capacity;
    for (0..capacity) |i| try batch.drawSprite(try testOrderedSprite(i));
    try std.testing.expectEqual(capacity, batch.commands.items.len);
    try std.testing.expectEqual(capacity, batch.commands.capacity);
    return capacity;
}

fn testOrderedSprite(i: usize) !Sprite {
    const texture = try TextureId.init(0, 1);
    return .{
        .texture = texture,
        .dest = .{ .x = @floatFromInt(i), .y = 0, .w = 1, .h = 1 },
        .order = RenderOrder.world(@intCast(i)),
    };
}

test "draw sprite past a reserved frame's capacity grows in order" {
    var batch = SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    const capacity = try fillReservedCommandsToCapacity(&batch);

    try batch.drawSprite(try testOrderedSprite(capacity));

    try std.testing.expectEqual(capacity + 1, batch.commands.items.len);
    try std.testing.expect(batch.commands.capacity > capacity);
    for (batch.commands.items, 0..) |command, i| {
        try std.testing.expectEqual(@as(f32, @floatFromInt(i)), command.sprite.dest.x);
    }
}

test "submits past the reservation inside the physical slack never grow the command list" {
    var batch = SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    try batch.reserveStorage(16, 16 * 6, 16);
    const capacity = batch.commands.capacity;
    const reservation: usize = 4;

    batch.markFrameReserved(reservation);
    for (0..reservation + 3) |i| try batch.drawSprite(try testOrderedSprite(i));
    // Re-marking the frame at the same reservation (the engine's top-up) keeps the list.
    batch.markFrameReserved(reservation);
    try std.testing.expectEqual(capacity, batch.commands.capacity);
    try std.testing.expectEqual(reservation + 3, batch.commands.items.len);
}

test "draw sprite growth OOM leaves the reserved stream unchanged" {
    var batch = SpriteBatch.init(std.testing.allocator);
    defer batch.deinit();
    const capacity = try fillReservedCommandsToCapacity(&batch);

    const original = batch.allocator;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
    batch.allocator = failing.allocator();
    defer batch.allocator = original;

    try std.testing.expectError(error.OutOfMemory, batch.drawSprite(try testOrderedSprite(capacity)));
    try std.testing.expectEqual(capacity, batch.commands.items.len);
    try std.testing.expectEqual(capacity, batch.commands.capacity);
}
