// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Main-thread SDL3_mixer audio service.
//! Game states queue audio intent through AudioCommandBuffer; AudioService owns
//! mixer tracks, loaded audio assets, and SDL_mixer lifetime.

const std = @import("std");
const assets = @import("../assets/assets.zig");
const manifest = @import("../assets/manifest.zig");
const AudioAssetId = manifest.AudioAssetId;
const AudioAssetKind = manifest.AudioAssetKind;
const AudioConfig = @import("../config.zig").AudioConfig;
const log = @import("../core/logging.zig").audio;
const math = @import("../core/math.zig");
const sdl = @import("../platform/sdl.zig");
const c = sdl.c;

const BackendHandle = usize;
const invalid_backend_handle: BackendHandle = 0;

pub const AudioBus = enum {
    sfx,
    music,
};

pub const PlaySfxRequest = struct {
    asset: AudioAssetId,
    gain: f32 = 1.0,
    priority: u8 = 128,
    frequency_ratio: f32 = 1.0,
    position: ?math.Vec2 = null,
};

pub const MusicRequest = struct {
    asset: AudioAssetId,
    gain: f32 = 1.0,
    loop: bool = true,
    fade_in_ms: u32 = 750,
    restart: bool = false,
};

pub const LoopingSfxId = struct {
    value: u32,

    pub fn init(value: u32) !LoopingSfxId {
        if (value == 0) return error.InvalidLoopingSfxId;
        return .{ .value = value };
    }
};

const OwnedPlaySfxRequest = struct {
    asset: AudioAssetId,
    gain: f32,
    priority: u8,
    frequency_ratio: f32,
    position: ?math.Vec2,
};

const OwnedMusicRequest = struct {
    asset: AudioAssetId,
    gain: f32,
    loop: bool,
    fade_in_ms: u32,
    restart: bool,
};

pub const AudioCommand = union(enum) {
    play_sfx: OwnedPlaySfxRequest,
    start_looping_sfx: LoopingSfxCommand,
    stop_looping_sfx: LoopingSfxId,
    play_music: OwnedMusicRequest,
    stop_music: u32,
    set_listener: math.Vec2,
    set_bus_gain: BusGain,
    set_master_gain: f32,
};

pub const BusGain = struct {
    bus: AudioBus,
    gain: f32,
};

const LoopingSfxCommand = struct {
    id: LoopingSfxId,
    sfx: OwnedPlaySfxRequest,
};

pub const AudioCommandBuffer = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(AudioCommand) = .empty,
    max_commands: usize,

    pub fn init(allocator: std.mem.Allocator, max_commands: usize) AudioCommandBuffer {
        return .{
            .allocator = allocator,
            .max_commands = @max(max_commands, 1),
        };
    }

    pub fn deinit(self: *AudioCommandBuffer) void {
        self.clearRetainingCapacity();
        self.commands.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn beginStep(self: *AudioCommandBuffer) void {
        self.clearRetainingCapacity();
    }

    pub fn len(self: *const AudioCommandBuffer) usize {
        return self.commands.items.len;
    }

    pub fn items(self: *const AudioCommandBuffer) []const AudioCommand {
        return self.commands.items;
    }

    pub fn playSfx(self: *AudioCommandBuffer, request: PlaySfxRequest) !void {
        try self.append(.{ .play_sfx = copySfxRequest(request) });
    }

    pub fn startLoopingSfx(self: *AudioCommandBuffer, id: LoopingSfxId, request: PlaySfxRequest) !void {
        try self.append(.{ .start_looping_sfx = .{
            .id = id,
            .sfx = copySfxRequest(request),
        } });
    }

    pub fn stopLoopingSfx(self: *AudioCommandBuffer, id: LoopingSfxId) !void {
        try self.append(.{ .stop_looping_sfx = id });
    }

    pub fn playMusic(self: *AudioCommandBuffer, request: MusicRequest) !void {
        try self.append(.{ .play_music = .{
            .asset = request.asset,
            .gain = clampGain(request.gain),
            .loop = request.loop,
            .fade_in_ms = request.fade_in_ms,
            .restart = request.restart,
        } });
    }

    pub fn stopMusic(self: *AudioCommandBuffer, fade_out_ms: u32) !void {
        try self.append(.{ .stop_music = fade_out_ms });
    }

    pub fn setListener(self: *AudioCommandBuffer, listener: math.Vec2) !void {
        try self.append(.{ .set_listener = listener });
    }

    pub fn setBusGain(self: *AudioCommandBuffer, bus: AudioBus, gain: f32) !void {
        try self.append(.{ .set_bus_gain = .{ .bus = bus, .gain = clampGain(gain) } });
    }

    pub fn setMasterGain(self: *AudioCommandBuffer, gain: f32) !void {
        try self.append(.{ .set_master_gain = clampGain(gain) });
    }

    fn append(self: *AudioCommandBuffer, command: AudioCommand) !void {
        if (self.commands.items.len >= self.max_commands) {
            return error.AudioCommandLimitReached;
        }
        try self.commands.append(self.allocator, command);
    }

    fn copySfxRequest(request: PlaySfxRequest) OwnedPlaySfxRequest {
        return .{
            .asset = request.asset,
            .gain = clampGain(request.gain),
            .priority = request.priority,
            .frequency_ratio = clampFrequencyRatio(request.frequency_ratio),
            .position = request.position,
        };
    }

    fn clearRetainingCapacity(self: *AudioCommandBuffer) void {
        self.commands.clearRetainingCapacity();
    }
};

pub const AudioService = struct {
    allocator: std.mem.Allocator,
    assets: assets.AssetStore,
    config: AudioConfig,
    enabled: bool,
    backend: Backend,
    backend_context: *anyopaque,
    owns_backend_context: bool = false,
    entries: std.StringHashMapUnmanaged(AudioEntry) = .empty,
    failed_paths: std.StringHashMapUnmanaged(void) = .empty,
    audio_assets: [manifest.audio_asset_count]AudioAssetSlot = initAudioAssetSlots(),
    sfx_tracks: std.ArrayList(TrackSlot) = .empty,
    music_track: BackendHandle = invalid_backend_handle,
    current_music_asset: ?AudioAssetId = null,
    master_gain: f32,
    sfx_gain: f32,
    music_gain: f32,
    active_music_gain: f32 = 1.0,
    listener: math.Vec2 = .{},
    paused: bool = false,
    sequence: u64 = 1,

    pub fn init(allocator: std.mem.Allocator, assetStore: assets.AssetStore, config: AudioConfig) !AudioService {
        var service = AudioService{
            .allocator = allocator,
            .assets = assetStore,
            .config = config,
            .enabled = config.enabled,
            .backend = disabledBackend(),
            .backend_context = disabledBackendContext(),
            .master_gain = config.master_gain,
            .sfx_gain = config.sfx_gain,
            .music_gain = config.music_gain,
        };
        if (!config.enabled) return service;

        const production_context = try allocator.create(ProductionBackendContext);
        var context_initialized = false;
        errdefer if (!context_initialized) allocator.destroy(production_context);
        production_context.* = try ProductionBackendContext.init(config.master_gain);
        context_initialized = true;
        errdefer {
            production_context.deinit();
            allocator.destroy(production_context);
        }

        service.backend = productionBackend();
        service.backend_context = @ptrCast(production_context);
        service.owns_backend_context = true;
        try service.createTracks();
        log.debug("audio initialized: sfx_tracks={} master_gain={} sfx_gain={} music_gain={}", .{
            service.sfx_tracks.items.len,
            service.master_gain,
            service.sfx_gain,
            service.music_gain,
        });
        return service;
    }

    pub fn initWithBackend(
        allocator: std.mem.Allocator,
        assetStore: assets.AssetStore,
        config: AudioConfig,
        backend: Backend,
        backend_context: *anyopaque,
    ) !AudioService {
        var service = AudioService{
            .allocator = allocator,
            .assets = assetStore,
            .config = config,
            .enabled = config.enabled,
            .backend = backend,
            .backend_context = backend_context,
            .master_gain = config.master_gain,
            .sfx_gain = config.sfx_gain,
            .music_gain = config.music_gain,
        };
        if (config.enabled) try service.createTracks();
        return service;
    }

    pub fn deinit(self: *AudioService) void {
        for (self.sfx_tracks.items) |track| {
            self.backend.destroy_track(self.backend_context, track.handle);
        }
        self.sfx_tracks.deinit(self.allocator);
        if (self.music_track != invalid_backend_handle) {
            self.backend.destroy_track(self.backend_context, self.music_track);
        }

        var entries = self.entries.iterator();
        while (entries.next()) |entry| {
            self.backend.destroy_audio(self.backend_context, entry.value_ptr.handle);
            self.allocator.free(entry.value_ptr.path);
        }
        self.entries.deinit(self.allocator);

        var failed = self.failed_paths.iterator();
        while (failed.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.failed_paths.deinit(self.allocator);

        if (self.owns_backend_context) {
            const context: *ProductionBackendContext = @ptrCast(@alignCast(self.backend_context));
            context.deinit();
            self.allocator.destroy(context);
        }
        self.* = undefined;
    }

    pub fn preloadAudio(
        self: *AudioService,
        id: AudioAssetId,
        relative_path: []const u8,
        kind: AudioAssetKind,
        predecode: bool,
    ) !bool {
        try assets.validateRelativePath(relative_path);
        const index = manifest.audioIndex(id);
        self.audio_assets[index] = .{ .status = .unavailable, .kind = kind };
        if (!self.enabled) return false;

        const handle = try self.loadAudio(relative_path, predecode) orelse return false;
        self.audio_assets[index] = .{
            .status = .available,
            .kind = kind,
            .handle = handle,
        };
        return true;
    }

    pub fn drain(self: *AudioService, commands: *const AudioCommandBuffer) void {
        if (!self.enabled) return;
        for (commands.items()) |command| {
            self.applyCommand(command) catch |err| {
                log.warn("audio command ignored: {}", .{err});
            };
        }
    }

    pub fn setPaused(self: *AudioService, paused: bool) void {
        if (!self.enabled or self.paused == paused) return;
        self.paused = paused;
        if (paused) {
            self.stopAllSfx();
        }
        self.applyMusicGain();
    }

    fn createTracks(self: *AudioService) !void {
        self.music_track = try self.backend.create_track(self.backend_context);
        errdefer {
            self.destroyCreatedTracks();
        }
        try self.sfx_tracks.ensureTotalCapacity(self.allocator, self.config.max_sfx_tracks);
        for (0..self.config.max_sfx_tracks) |_| {
            const handle = try self.backend.create_track(self.backend_context);
            self.sfx_tracks.appendAssumeCapacity(.{ .handle = handle });
        }
    }

    fn destroyCreatedTracks(self: *AudioService) void {
        for (self.sfx_tracks.items) |track| {
            self.backend.destroy_track(self.backend_context, track.handle);
        }
        self.sfx_tracks.deinit(self.allocator);
        self.sfx_tracks = .empty;
        if (self.music_track != invalid_backend_handle) {
            self.backend.destroy_track(self.backend_context, self.music_track);
            self.music_track = invalid_backend_handle;
        }
    }

    fn applyCommand(self: *AudioService, command: AudioCommand) !void {
        switch (command) {
            .play_sfx => |request| try self.playSfx(request),
            .start_looping_sfx => |request| try self.startLoopingSfx(request.id, request.sfx),
            .stop_looping_sfx => |id| try self.stopLoopingSfx(id),
            .play_music => |request| try self.playMusic(request),
            .stop_music => |fade_out_ms| try self.stopMusic(fade_out_ms),
            .set_listener => |listener| self.listener = listener,
            .set_bus_gain => |bus_gain| {
                switch (bus_gain.bus) {
                    .sfx => self.sfx_gain = clampGain(bus_gain.gain),
                    .music => self.music_gain = clampGain(bus_gain.gain),
                }
                self.applyBusGains();
            },
            .set_master_gain => |gain| {
                self.master_gain = clampGain(gain);
                try self.backend.set_mixer_gain(self.backend_context, self.master_gain);
            },
        }
    }

    fn playSfx(self: *AudioService, request: OwnedPlaySfxRequest) !void {
        const audio = try self.audioHandle(request.asset, .sfx) orelse return;
        const slot_index = try self.selectSfxTrack(request.priority) orelse return;
        const slot = &self.sfx_tracks.items[slot_index];
        try self.backend.stop_track(self.backend_context, slot.handle, 0);
        try self.backend.set_track_audio(self.backend_context, slot.handle, audio);
        slot.request_gain = request.gain;
        try self.backend.set_track_gain(self.backend_context, slot.handle, request.gain * self.sfx_gain);
        try self.backend.set_track_frequency_ratio(self.backend_context, slot.handle, request.frequency_ratio);
        slot.frequency_ratio = request.frequency_ratio;
        try self.applyTrackPosition(slot, request.position);
        try self.backend.play_track(self.backend_context, slot.handle, 0, 0);
        slot.priority = request.priority;
        slot.sequence = self.sequence;
        self.sequence +%= 1;
    }

    fn startLoopingSfx(self: *AudioService, id: LoopingSfxId, request: OwnedPlaySfxRequest) !void {
        if (self.findLoopingSfxSlot(id)) |slot_index| {
            const slot = &self.sfx_tracks.items[slot_index];
            slot.priority = request.priority;
            if (!approxEqAbs(slot.request_gain, request.gain)) {
                slot.request_gain = request.gain;
                try self.backend.set_track_gain(self.backend_context, slot.handle, request.gain * self.sfx_gain);
            }
            if (!approxEqAbs(slot.frequency_ratio, request.frequency_ratio)) {
                slot.frequency_ratio = request.frequency_ratio;
                try self.backend.set_track_frequency_ratio(self.backend_context, slot.handle, request.frequency_ratio);
            }
            try self.applyTrackPosition(slot, request.position);
            if (!try self.backend.track_playing(self.backend_context, slot.handle)) {
                try self.backend.play_track(self.backend_context, slot.handle, -1, 0);
            }
            return;
        }

        const audio = try self.audioHandle(request.asset, .sfx) orelse return;
        const slot_index = try self.selectLoopingSfxTrack(request.priority) orelse return;
        const slot = &self.sfx_tracks.items[slot_index];
        try self.backend.stop_track(self.backend_context, slot.handle, 0);
        try self.backend.set_track_audio(self.backend_context, slot.handle, audio);
        slot.looping_id = id;
        slot.request_gain = request.gain;
        slot.priority = request.priority;
        try self.backend.set_track_gain(self.backend_context, slot.handle, request.gain * self.sfx_gain);
        try self.backend.set_track_frequency_ratio(self.backend_context, slot.handle, request.frequency_ratio);
        slot.frequency_ratio = request.frequency_ratio;
        try self.applyTrackPosition(slot, request.position);
        try self.backend.play_track(self.backend_context, slot.handle, -1, 0);
        slot.sequence = self.sequence;
        self.sequence +%= 1;
    }

    fn stopLoopingSfx(self: *AudioService, id: LoopingSfxId) !void {
        const slot_index = self.findLoopingSfxSlot(id) orelse return;
        const slot = &self.sfx_tracks.items[slot_index];
        try self.backend.stop_track(self.backend_context, slot.handle, 0);
        try self.clearTrackPosition(slot);
        slot.looping_id = null;
        slot.priority = 0;
        slot.request_gain = 1.0;
        slot.frequency_ratio = 1.0;
    }

    fn playMusic(self: *AudioService, request: OwnedMusicRequest) !void {
        const audio = try self.audioHandle(request.asset, .music) orelse return;
        if (!request.restart) {
            if (self.current_music_asset) |current| {
                if (current == request.asset) {
                    self.active_music_gain = request.gain;
                    self.applyMusicGain();
                    return;
                }
            }
        }

        try self.backend.stop_track(self.backend_context, self.music_track, 0);
        try self.backend.set_track_audio(self.backend_context, self.music_track, audio);
        self.active_music_gain = request.gain;
        self.current_music_asset = request.asset;
        try self.backend.set_track_gain(self.backend_context, self.music_track, self.effectiveMusicGain());
        try self.backend.play_track(self.backend_context, self.music_track, if (request.loop) -1 else 0, request.fade_in_ms);
    }

    fn stopMusic(self: *AudioService, fade_out_ms: u32) !void {
        try self.backend.stop_track(self.backend_context, self.music_track, fade_out_ms);
        self.current_music_asset = null;
    }

    fn stopAllSfx(self: *AudioService) void {
        for (self.sfx_tracks.items) |*slot| {
            self.backend.stop_track(self.backend_context, slot.handle, 0) catch {};
            self.clearTrackPosition(slot) catch {};
            slot.looping_id = null;
            slot.priority = 0;
            slot.request_gain = 1.0;
            slot.frequency_ratio = 1.0;
        }
    }

    fn applyBusGains(self: *AudioService) void {
        for (self.sfx_tracks.items) |slot| {
            self.backend.set_track_gain(self.backend_context, slot.handle, slot.request_gain * self.sfx_gain) catch {};
        }
        self.applyMusicGain();
    }

    fn applyMusicGain(self: *AudioService) void {
        self.backend.set_track_gain(self.backend_context, self.music_track, self.effectiveMusicGain()) catch {};
    }

    fn effectiveMusicGain(self: *const AudioService) f32 {
        const pause_gain = if (self.paused) self.config.paused_music_gain else 1.0;
        return self.active_music_gain * self.music_gain * pause_gain;
    }

    fn selectSfxTrack(self: *AudioService, priority: u8) !?usize {
        var steal_index: ?usize = null;
        for (self.sfx_tracks.items, 0..) |*slot, index| {
            if (slot.looping_id != null) continue;
            if (!try self.backend.track_playing(self.backend_context, slot.handle)) {
                slot.priority = 0;
                return index;
            }
            if (steal_index == null or lowerPriority(slot.*, self.sfx_tracks.items[steal_index.?])) {
                steal_index = index;
            }
        }
        const index = steal_index orelse return null;
        if (priority < self.sfx_tracks.items[index].priority) return null;
        return index;
    }

    fn selectLoopingSfxTrack(self: *AudioService, priority: u8) !?usize {
        var steal_index: ?usize = null;
        for (self.sfx_tracks.items, 0..) |*slot, index| {
            if (slot.looping_id != null) continue;
            if (!try self.backend.track_playing(self.backend_context, slot.handle)) {
                slot.priority = 0;
                return index;
            }
            if (steal_index == null or lowerPriority(slot.*, self.sfx_tracks.items[steal_index.?])) {
                steal_index = index;
            }
        }
        const index = steal_index orelse return null;
        if (priority < self.sfx_tracks.items[index].priority) return null;
        return index;
    }

    fn findLoopingSfxSlot(self: *const AudioService, id: LoopingSfxId) ?usize {
        for (self.sfx_tracks.items, 0..) |slot, index| {
            const looping_id = slot.looping_id orelse continue;
            if (looping_id.value == id.value) return index;
        }
        return null;
    }

    fn lowerPriority(a: TrackSlot, b: TrackSlot) bool {
        if (a.priority != b.priority) return a.priority < b.priority;
        return a.sequence < b.sequence;
    }

    fn applyTrackPosition(self: *AudioService, slot: *TrackSlot, position: ?math.Vec2) !void {
        const position_3d = if (position) |world_position| BackendPosition{
            .x = (world_position.x - self.listener.x) / self.config.spatial_units_per_meter,
            .y = -(world_position.y - self.listener.y) / self.config.spatial_units_per_meter,
            .z = 0,
        } else null;
        if (backendPositionsEqual(slot.position, position_3d)) return;
        try self.backend.set_track_position(self.backend_context, slot.handle, position_3d);
        slot.position = position_3d;
    }

    fn clearTrackPosition(self: *AudioService, slot: *TrackSlot) !void {
        try self.backend.set_track_position(self.backend_context, slot.handle, null);
        slot.position = null;
    }

    fn audioHandle(self: *const AudioService, id: AudioAssetId, kind: AudioAssetKind) !?BackendHandle {
        const slot = self.audio_assets[manifest.audioIndex(id)];
        if (slot.status != .available) return null;
        if (slot.kind != kind) return error.InvalidAudioAssetKind;
        return slot.handle;
    }

    fn loadAudio(self: *AudioService, relative_path: []const u8, predecode: bool) !?BackendHandle {
        try assets.validateRelativePath(relative_path);
        if (self.entries.get(relative_path)) |entry| {
            return entry.handle;
        }
        if (self.failed_paths.get(relative_path) != null) {
            return null;
        }

        const owned_path = try self.allocator.dupe(u8, relative_path);
        var owns_path = true;
        errdefer if (owns_path) self.allocator.free(owned_path);

        const load_path = if (self.backend.resolve_asset_path)
            self.assets.resolveReadablePath(relative_path) catch |err| {
                try self.rememberFailedPath(owned_path, &owns_path);
                if (self.backend.log_load_failures) {
                    log.warn("audio asset unavailable \"{s}\": {}", .{ relative_path, err });
                }
                return null;
            }
        else
            try self.allocator.dupe(u8, relative_path);
        defer self.allocator.free(load_path);

        const load_path_z = try self.allocator.dupeZ(u8, load_path);
        defer self.allocator.free(load_path_z);
        const handle = self.backend.load_audio(self.backend_context, load_path_z, predecode) catch |err| {
            try self.rememberFailedPath(owned_path, &owns_path);
            if (self.backend.log_load_failures) {
                log.warn("audio load failed \"{s}\": {}", .{ relative_path, err });
            }
            return null;
        };

        try self.entries.put(self.allocator, owned_path, .{
            .path = owned_path,
            .handle = handle,
        });
        owns_path = false;
        log.debug("loaded audio asset \"{s}\" predecode={}", .{ relative_path, predecode });
        return handle;
    }

    fn rememberFailedPath(self: *AudioService, owned_path: []const u8, owns_path: *bool) !void {
        try self.failed_paths.put(self.allocator, owned_path, {});
        owns_path.* = false;
    }
};

const AudioAssetSlot = struct {
    status: AudioAssetStatus = .not_loaded,
    kind: AudioAssetKind = .sfx,
    handle: BackendHandle = invalid_backend_handle,
};

const AudioAssetStatus = enum {
    not_loaded,
    available,
    unavailable,
};

fn initAudioAssetSlots() [manifest.audio_asset_count]AudioAssetSlot {
    return [_]AudioAssetSlot{.{}} ** manifest.audio_asset_count;
}

const AudioEntry = struct {
    path: []const u8,
    handle: BackendHandle,
};

const TrackSlot = struct {
    handle: BackendHandle,
    looping_id: ?LoopingSfxId = null,
    priority: u8 = 0,
    sequence: u64 = 0,
    request_gain: f32 = 1.0,
    frequency_ratio: f32 = 1.0,
    position: ?BackendPosition = null,
};

const BackendPosition = struct {
    x: f32,
    y: f32,
    z: f32,
};

fn backendPositionsEqual(a: ?BackendPosition, b: ?BackendPosition) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return approxEqAbs(a.?.x, b.?.x) and approxEqAbs(a.?.y, b.?.y) and approxEqAbs(a.?.z, b.?.z);
}

fn approxEqAbs(a: f32, b: f32) bool {
    return @abs(a - b) <= 0.0001;
}

pub const Backend = struct {
    context_name: []const u8,
    resolve_asset_path: bool = true,
    log_load_failures: bool = true,
    create_track: *const fn (*anyopaque) anyerror!BackendHandle,
    destroy_track: *const fn (*anyopaque, BackendHandle) void,
    load_audio: *const fn (*anyopaque, [:0]const u8, bool) anyerror!BackendHandle,
    destroy_audio: *const fn (*anyopaque, BackendHandle) void,
    set_track_audio: *const fn (*anyopaque, BackendHandle, BackendHandle) anyerror!void,
    play_track: *const fn (*anyopaque, BackendHandle, i32, u32) anyerror!void,
    stop_track: *const fn (*anyopaque, BackendHandle, u32) anyerror!void,
    track_playing: *const fn (*anyopaque, BackendHandle) anyerror!bool,
    set_track_gain: *const fn (*anyopaque, BackendHandle, f32) anyerror!void,
    set_track_frequency_ratio: *const fn (*anyopaque, BackendHandle, f32) anyerror!void,
    set_mixer_gain: *const fn (*anyopaque, f32) anyerror!void,
    set_track_position: *const fn (*anyopaque, BackendHandle, ?BackendPosition) anyerror!void,
};

const DisabledBackendContext = struct {};
var disabled_backend_context = DisabledBackendContext{};

fn disabledBackendContext() *anyopaque {
    return @ptrCast(&disabled_backend_context);
}

const ProductionBackendContext = struct {
    mixer: *c.MIX_Mixer,

    fn init(master_gain: f32) !ProductionBackendContext {
        if (!c.MIX_Init()) return audioError("MIX_Init");
        errdefer c.MIX_Quit();
        const mixer = c.MIX_CreateMixerDevice(c.SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK, null) orelse {
            return audioError("MIX_CreateMixerDevice");
        };
        errdefer c.MIX_DestroyMixer(mixer);
        if (!c.MIX_SetMixerGain(mixer, master_gain)) return audioError("MIX_SetMixerGain");
        return .{ .mixer = mixer };
    }

    fn deinit(self: *ProductionBackendContext) void {
        c.MIX_DestroyMixer(self.mixer);
        c.MIX_Quit();
    }
};

fn productionBackend() Backend {
    return .{
        .context_name = "SDL3_mixer",
        .create_track = productionCreateTrack,
        .destroy_track = productionDestroyTrack,
        .load_audio = productionLoadAudio,
        .destroy_audio = productionDestroyAudio,
        .set_track_audio = productionSetTrackAudio,
        .play_track = productionPlayTrack,
        .stop_track = productionStopTrack,
        .track_playing = productionTrackPlaying,
        .set_track_gain = productionSetTrackGain,
        .set_track_frequency_ratio = productionSetTrackFrequencyRatio,
        .set_mixer_gain = productionSetMixerGain,
        .set_track_position = productionSetTrackPosition,
    };
}

fn productionCreateTrack(context: *anyopaque) !BackendHandle {
    const production: *ProductionBackendContext = @ptrCast(@alignCast(context));
    const track = c.MIX_CreateTrack(production.mixer) orelse return audioError("MIX_CreateTrack");
    return @intFromPtr(track);
}

fn productionDestroyTrack(_: *anyopaque, handle: BackendHandle) void {
    c.MIX_DestroyTrack(trackFromHandle(handle));
}

fn productionLoadAudio(context: *anyopaque, path: [:0]const u8, predecode: bool) !BackendHandle {
    const production: *ProductionBackendContext = @ptrCast(@alignCast(context));
    const audio = c.MIX_LoadAudio(production.mixer, path.ptr, predecode) orelse return audioError("MIX_LoadAudio");
    return @intFromPtr(audio);
}

fn productionDestroyAudio(_: *anyopaque, handle: BackendHandle) void {
    c.MIX_DestroyAudio(audioFromHandle(handle));
}

fn productionSetTrackAudio(_: *anyopaque, track: BackendHandle, audio: BackendHandle) !void {
    if (!c.MIX_SetTrackAudio(trackFromHandle(track), audioFromHandle(audio))) return audioError("MIX_SetTrackAudio");
}

fn productionPlayTrack(_: *anyopaque, track: BackendHandle, loops: i32, fade_in_ms: u32) !void {
    const props = c.SDL_CreateProperties();
    if (props == 0) return audioError("SDL_CreateProperties");
    defer c.SDL_DestroyProperties(props);
    if (!c.SDL_SetNumberProperty(props, c.MIX_PROP_PLAY_LOOPS_NUMBER, loops)) return audioError("SDL_SetNumberProperty");
    if (fade_in_ms > 0) {
        if (!c.SDL_SetNumberProperty(props, c.MIX_PROP_PLAY_FADE_IN_MILLISECONDS_NUMBER, fade_in_ms)) return audioError("SDL_SetNumberProperty");
    }
    if (!c.MIX_PlayTrack(trackFromHandle(track), props)) return audioError("MIX_PlayTrack");
}

fn productionStopTrack(_: *anyopaque, track: BackendHandle, fade_out_ms: u32) !void {
    const frames = if (fade_out_ms == 0) 0 else c.MIX_TrackMSToFrames(trackFromHandle(track), fade_out_ms);
    if (!c.MIX_StopTrack(trackFromHandle(track), frames)) return audioError("MIX_StopTrack");
}

fn productionTrackPlaying(_: *anyopaque, track: BackendHandle) !bool {
    return c.MIX_TrackPlaying(trackFromHandle(track));
}

fn productionSetTrackGain(_: *anyopaque, track: BackendHandle, gain: f32) !void {
    if (!c.MIX_SetTrackGain(trackFromHandle(track), gain)) return audioError("MIX_SetTrackGain");
}

fn productionSetTrackFrequencyRatio(_: *anyopaque, track: BackendHandle, ratio: f32) !void {
    if (!c.MIX_SetTrackFrequencyRatio(trackFromHandle(track), ratio)) return audioError("MIX_SetTrackFrequencyRatio");
}

fn productionSetMixerGain(context: *anyopaque, gain: f32) !void {
    const production: *ProductionBackendContext = @ptrCast(@alignCast(context));
    if (!c.MIX_SetMixerGain(production.mixer, gain)) return audioError("MIX_SetMixerGain");
}

fn productionSetTrackPosition(_: *anyopaque, track: BackendHandle, position: ?BackendPosition) !void {
    if (position) |value| {
        const point = c.MIX_Point3D{ .x = value.x, .y = value.y, .z = value.z };
        if (!c.MIX_SetTrack3DPosition(trackFromHandle(track), &point)) return audioError("MIX_SetTrack3DPosition");
    } else {
        if (!c.MIX_SetTrack3DPosition(trackFromHandle(track), null)) return audioError("MIX_SetTrack3DPosition");
    }
}

fn audioFromHandle(handle: BackendHandle) *c.MIX_Audio {
    return @ptrFromInt(handle);
}

fn trackFromHandle(handle: BackendHandle) *c.MIX_Track {
    return @ptrFromInt(handle);
}

fn audioError(comptime operation: []const u8) error{AudioBackendFailure} {
    log.err("{s} failed: {s}", .{ operation, c.SDL_GetError() });
    return error.AudioBackendFailure;
}

fn disabledBackend() Backend {
    return .{
        .context_name = "disabled",
        .resolve_asset_path = false,
        .create_track = disabledCreateTrack,
        .destroy_track = disabledDestroyTrack,
        .load_audio = disabledLoadAudio,
        .destroy_audio = disabledDestroyAudio,
        .set_track_audio = disabledSetTrackAudio,
        .play_track = disabledPlayTrack,
        .stop_track = disabledStopTrack,
        .track_playing = disabledTrackPlaying,
        .set_track_gain = disabledSetTrackGain,
        .set_track_frequency_ratio = disabledSetTrackFrequencyRatio,
        .set_mixer_gain = disabledSetMixerGain,
        .set_track_position = disabledSetTrackPosition,
    };
}

fn disabledCreateTrack(_: *anyopaque) !BackendHandle {
    return invalid_backend_handle;
}

fn disabledDestroyTrack(_: *anyopaque, _: BackendHandle) void {}

fn disabledLoadAudio(_: *anyopaque, _: [:0]const u8, _: bool) !BackendHandle {
    return invalid_backend_handle;
}

fn disabledDestroyAudio(_: *anyopaque, _: BackendHandle) void {}

fn disabledSetTrackAudio(_: *anyopaque, _: BackendHandle, _: BackendHandle) !void {}

fn disabledPlayTrack(_: *anyopaque, _: BackendHandle, _: i32, _: u32) !void {}

fn disabledStopTrack(_: *anyopaque, _: BackendHandle, _: u32) !void {}

fn disabledTrackPlaying(_: *anyopaque, _: BackendHandle) !bool {
    return false;
}

fn disabledSetTrackGain(_: *anyopaque, _: BackendHandle, _: f32) !void {}

fn disabledSetTrackFrequencyRatio(_: *anyopaque, _: BackendHandle, _: f32) !void {}

fn disabledSetMixerGain(_: *anyopaque, _: f32) !void {}

fn disabledSetTrackPosition(_: *anyopaque, _: BackendHandle, _: ?BackendPosition) !void {}

fn clampGain(value: f32) f32 {
    if (!std.math.isFinite(value)) return 0;
    return std.math.clamp(value, 0, 1);
}

fn clampFrequencyRatio(value: f32) f32 {
    if (!std.math.isFinite(value)) return 1.0;
    return std.math.clamp(value, 0.01, 100.0);
}

const FakeBackendContext = struct {
    allocator: std.mem.Allocator,
    next_handle: BackendHandle = 1,
    tracks: std.AutoHashMapUnmanaged(BackendHandle, FakeTrack) = .empty,
    audios: std.AutoHashMapUnmanaged(BackendHandle, FakeAudio) = .empty,
    mixer_gain: f32 = 1.0,
    load_failures: std.StringHashMapUnmanaged(void) = .empty,
    load_calls: u32 = 0,
    create_track_calls: u32 = 0,
    destroy_track_calls: u32 = 0,
    play_calls: u32 = 0,
    gain_calls: u32 = 0,
    frequency_ratio_calls: u32 = 0,
    position_calls: u32 = 0,
    fail_create_after: ?u32 = null,

    fn init(allocator: std.mem.Allocator) FakeBackendContext {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *FakeBackendContext) void {
        var audios = self.audios.iterator();
        while (audios.next()) |entry| {
            self.allocator.free(entry.value_ptr.path);
        }
        self.audios.deinit(self.allocator);
        self.tracks.deinit(self.allocator);
        var failures = self.load_failures.iterator();
        while (failures.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.load_failures.deinit(self.allocator);
    }

    fn backend() Backend {
        return .{
            .context_name = "fake",
            .resolve_asset_path = false,
            .log_load_failures = false,
            .create_track = fakeCreateTrack,
            .destroy_track = fakeDestroyTrack,
            .load_audio = fakeLoadAudio,
            .destroy_audio = fakeDestroyAudio,
            .set_track_audio = fakeSetTrackAudio,
            .play_track = fakePlayTrack,
            .stop_track = fakeStopTrack,
            .track_playing = fakeTrackPlaying,
            .set_track_gain = fakeSetTrackGain,
            .set_track_frequency_ratio = fakeSetTrackFrequencyRatio,
            .set_mixer_gain = fakeSetMixerGain,
            .set_track_position = fakeSetTrackPosition,
        };
    }

    fn failPath(self: *FakeBackendContext, path: []const u8) !void {
        const owned_path = try self.allocator.dupe(u8, path);
        try self.load_failures.put(self.allocator, owned_path, {});
    }

    fn next(self: *FakeBackendContext) BackendHandle {
        const handle = self.next_handle;
        self.next_handle += 1;
        return handle;
    }
};

const FakeTrack = struct {
    audio: BackendHandle = invalid_backend_handle,
    playing: bool = false,
    gain: f32 = 1.0,
    frequency_ratio: f32 = 1.0,
    loops: i32 = 0,
    fade_ms: u32 = 0,
    position: ?BackendPosition = null,
};

const FakeAudio = struct {
    path: []const u8,
    predecode: bool,
};

fn fakeCreateTrack(context: *anyopaque) !BackendHandle {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    if (fake.fail_create_after) |limit| {
        if (fake.create_track_calls >= limit) return error.AudioBackendFailure;
    }
    fake.create_track_calls += 1;
    const handle = fake.next();
    try fake.tracks.put(fake.allocator, handle, .{});
    return handle;
}

fn fakeDestroyTrack(context: *anyopaque, handle: BackendHandle) void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    fake.destroy_track_calls += 1;
    _ = fake.tracks.remove(handle);
}

fn fakeLoadAudio(context: *anyopaque, path: [:0]const u8, predecode: bool) !BackendHandle {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    fake.load_calls += 1;
    if (fake.load_failures.get(path) != null) return error.AudioBackendFailure;
    const handle = fake.next();
    try fake.audios.put(fake.allocator, handle, .{
        .path = try fake.allocator.dupe(u8, path),
        .predecode = predecode,
    });
    return handle;
}

fn fakeDestroyAudio(context: *anyopaque, handle: BackendHandle) void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const removed = fake.audios.fetchRemove(handle) orelse return;
    fake.allocator.free(removed.value.path);
}

fn fakeSetTrackAudio(context: *anyopaque, track: BackendHandle, audio: BackendHandle) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.audio = audio;
}

fn fakePlayTrack(context: *anyopaque, track: BackendHandle, loops: i32, fade_ms: u32) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.playing = true;
    slot.loops = loops;
    slot.fade_ms = fade_ms;
    fake.play_calls += 1;
}

fn fakeStopTrack(context: *anyopaque, track: BackendHandle, _: u32) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.playing = false;
}

fn fakeTrackPlaying(context: *anyopaque, track: BackendHandle) !bool {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    return slot.playing;
}

fn fakeSetTrackGain(context: *anyopaque, track: BackendHandle, gain: f32) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.gain = gain;
    fake.gain_calls += 1;
}

fn fakeSetTrackFrequencyRatio(context: *anyopaque, track: BackendHandle, ratio: f32) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.frequency_ratio = ratio;
    fake.frequency_ratio_calls += 1;
}

fn fakeSetMixerGain(context: *anyopaque, gain: f32) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    fake.mixer_gain = gain;
}

fn fakeSetTrackPosition(context: *anyopaque, track: BackendHandle, position: ?BackendPosition) !void {
    const fake: *FakeBackendContext = @ptrCast(@alignCast(context));
    const slot = fake.tracks.getPtr(track) orelse return error.AudioBackendFailure;
    slot.position = position;
    fake.position_calls += 1;
}

test "audio command buffer stores stable ids and clamps command values" {
    var commands = AudioCommandBuffer.init(std.testing.allocator, 4);
    defer commands.deinit();

    try commands.playSfx(.{ .asset = .collision_sfx, .gain = 2.0 });

    try std.testing.expectEqual(@as(usize, 1), commands.len());
    try std.testing.expectEqual(AudioAssetId.collision_sfx, commands.items()[0].play_sfx.asset);
    try std.testing.expectEqual(@as(f32, 1.0), commands.items()[0].play_sfx.gain);
    try std.testing.expectEqual(@as(f32, 1.0), commands.items()[0].play_sfx.frequency_ratio);
}

test "audio command buffer clamps invalid sfx frequency ratios" {
    var commands = AudioCommandBuffer.init(std.testing.allocator, 4);
    defer commands.deinit();

    try commands.playSfx(.{ .asset = .collision_sfx, .frequency_ratio = 0.001 });
    try commands.playSfx(.{ .asset = .collision_sfx, .frequency_ratio = 101.0 });
    try commands.playSfx(.{ .asset = .collision_sfx, .frequency_ratio = std.math.nan(f32) });

    try std.testing.expectEqual(@as(f32, 0.01), commands.items()[0].play_sfx.frequency_ratio);
    try std.testing.expectEqual(@as(f32, 100.0), commands.items()[1].play_sfx.frequency_ratio);
    try std.testing.expectEqual(@as(f32, 1.0), commands.items()[2].play_sfx.frequency_ratio);
}

test "audio command buffer enforces per-step command cap" {
    var commands = AudioCommandBuffer.init(std.testing.allocator, 1);
    defer commands.deinit();

    try commands.playSfx(.{ .asset = .collision_sfx });
    try std.testing.expectError(error.AudioCommandLimitReached, commands.playSfx(.{ .asset = .player_jet_sfx }));
    try std.testing.expectEqual(@as(usize, 1), commands.len());
    commands.beginStep();
    try std.testing.expectEqual(@as(usize, 0), commands.len());
}

test "disabled audio backend context is stable after service move" {
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.init(std.testing.allocator, assetStore, .{ .enabled = false });
    const context_address = @intFromPtr(service.backend_context);
    try std.testing.expectEqual(@intFromPtr(disabledBackendContext()), context_address);
    try std.testing.expect(context_address != @intFromPtr(&service));

    var moved = service;
    service = undefined;
    defer moved.deinit();

    try std.testing.expectEqual(context_address, @intFromPtr(moved.backend_context));
    try std.testing.expect(context_address != @intFromPtr(&moved));

    var commands = AudioCommandBuffer.init(std.testing.allocator, 2);
    defer commands.deinit();
    try commands.playSfx(.{ .asset = .collision_sfx });
    moved.drain(&commands);
}

test "audio service init cleans up music track when first sfx track creation fails" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_create_after = 1;
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");

    try std.testing.expectError(
        error.AudioBackendFailure,
        AudioService.initWithBackend(std.testing.allocator, assetStore, .{ .max_sfx_tracks = 2 }, FakeBackendContext.backend(), @ptrCast(&fake)),
    );

    try std.testing.expectEqual(@as(u32, 1), fake.create_track_calls);
    try std.testing.expectEqual(@as(u32, 1), fake.destroy_track_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.tracks.count());
}

test "audio service init cleans up partially created sfx tracks" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    fake.fail_create_after = 3;
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");

    try std.testing.expectError(
        error.AudioBackendFailure,
        AudioService.initWithBackend(std.testing.allocator, assetStore, .{ .max_sfx_tracks = 4 }, FakeBackendContext.backend(), @ptrCast(&fake)),
    );

    try std.testing.expectEqual(@as(u32, 3), fake.create_track_calls);
    try std.testing.expectEqual(@as(u32, 3), fake.destroy_track_calls);
    try std.testing.expectEqual(@as(usize, 0), fake.tracks.count());
}

test "audio service preloads ids and memoizes failed paths" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    try fake.failPath("audio/sfx/missing.wav");
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assetStore, .{ .max_sfx_tracks = 2 }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    try std.testing.expect(try service.preloadAudio(.collision_sfx, "audio/sfx/hit.wav", .sfx, true));
    try std.testing.expect(!try service.preloadAudio(.player_jet_sfx, "audio/sfx/missing.wav", .sfx, true));
    try std.testing.expect(!try service.preloadAudio(.player_jet_sfx, "audio/sfx/missing.wav", .sfx, true));
    const load_calls_after_preload = fake.load_calls;

    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();
    try commands.playSfx(.{ .asset = .collision_sfx });
    try commands.playSfx(.{ .asset = .collision_sfx });
    try commands.playSfx(.{ .asset = .player_jet_sfx });
    service.drain(&commands);

    try std.testing.expectEqual(@as(u32, 2), fake.load_calls);
    try std.testing.expectEqual(load_calls_after_preload, fake.load_calls);
    try std.testing.expectEqual(@as(usize, 1), service.entries.count());
    try std.testing.expectEqual(@as(usize, 1), service.failed_paths.count());
}

test "audio service plays music idempotently and ducks on pause" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assetStore, .{
        .max_sfx_tracks = 1,
        .music_gain = 0.5,
        .paused_music_gain = 0.25,
    }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    try std.testing.expect(try service.preloadAudio(.demo_music, "audio/music/theme.wav", .music, false));
    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();

    try commands.playMusic(.{ .asset = .demo_music, .gain = 0.8, .fade_in_ms = 100 });
    try commands.playMusic(.{ .asset = .demo_music, .gain = 0.8, .fade_in_ms = 100 });
    service.drain(&commands);
    try std.testing.expectEqual(@as(u32, 1), fake.play_calls);
    try std.testing.expectEqual(AudioAssetId.demo_music, service.current_music_asset.?);

    commands.beginStep();
    try commands.playMusic(.{ .asset = .demo_music, .gain = 0.8, .fade_in_ms = 100 });
    service.drain(&commands);
    try std.testing.expectEqual(@as(u32, 1), fake.play_calls);

    const music = fake.tracks.get(service.music_track).?;
    try std.testing.expectEqual(@as(i32, -1), music.loops);
    try std.testing.expectEqual(@as(u32, 100), music.fade_ms);
    try std.testing.expectEqual(@as(f32, 0.4), music.gain);
    service.setPaused(true);
    try std.testing.expectEqual(@as(f32, 0.1), fake.tracks.get(service.music_track).?.gain);
    service.setPaused(false);
    try std.testing.expectEqual(@as(f32, 0.4), fake.tracks.get(service.music_track).?.gain);
}

test "audio service applies spatial position relative to listener" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assetStore, .{
        .max_sfx_tracks = 1,
        .spatial_units_per_meter = 100,
    }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    try std.testing.expect(try service.preloadAudio(.collision_sfx, "audio/sfx/hit.wav", .sfx, true));
    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();

    try commands.setListener(.{ .x = 50, .y = 50 });
    try commands.playSfx(.{ .asset = .collision_sfx, .position = .{ .x = 250, .y = 150 } });
    service.drain(&commands);

    const track = fake.tracks.get(service.sfx_tracks.items[0].handle).?;
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), track.position.?.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), track.position.?.y, 0.001);
}

test "audio service applies per-sfx frequency ratio" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assetStore, .{ .max_sfx_tracks = 1, .sfx_gain = 1.0 }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    try std.testing.expect(try service.preloadAudio(.collision_sfx, "audio/sfx/hit.wav", .sfx, true));
    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();

    try commands.playSfx(.{ .asset = .collision_sfx, .frequency_ratio = 1.08 });
    service.drain(&commands);

    const track = fake.tracks.get(service.sfx_tracks.items[0].handle).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.08), track.frequency_ratio, 0.001);
}

test "audio service starts updates and stops keyed looping sfx" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assetStore, .{ .max_sfx_tracks = 1, .sfx_gain = 1.0 }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    try std.testing.expect(try service.preloadAudio(.player_jet_sfx, "audio/sfx/jet.wav", .sfx, true));
    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();
    const loop_id = try LoopingSfxId.init(7);

    try commands.startLoopingSfx(loop_id, .{ .asset = .player_jet_sfx, .gain = 0.4, .frequency_ratio = 1.0 });
    service.drain(&commands);
    try std.testing.expectEqual(@as(u32, 1), fake.play_calls);
    try std.testing.expect(service.sfx_tracks.items[0].looping_id.?.value == loop_id.value);
    try std.testing.expect(fake.tracks.get(service.sfx_tracks.items[0].handle).?.playing);
    const gain_calls_after_start = fake.gain_calls;
    const frequency_calls_after_start = fake.frequency_ratio_calls;
    const position_calls_after_start = fake.position_calls;

    commands.beginStep();
    try commands.startLoopingSfx(loop_id, .{ .asset = .player_jet_sfx, .gain = 0.4, .frequency_ratio = 1.0 });
    service.drain(&commands);
    try std.testing.expectEqual(gain_calls_after_start, fake.gain_calls);
    try std.testing.expectEqual(frequency_calls_after_start, fake.frequency_ratio_calls);
    try std.testing.expectEqual(position_calls_after_start, fake.position_calls);

    commands.beginStep();
    try commands.startLoopingSfx(loop_id, .{ .asset = .player_jet_sfx, .gain = 0.7, .frequency_ratio = 1.12 });
    service.drain(&commands);
    try std.testing.expectEqual(@as(u32, 1), fake.play_calls);
    const updated = fake.tracks.get(service.sfx_tracks.items[0].handle).?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), updated.gain, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.12), updated.frequency_ratio, 0.001);

    commands.beginStep();
    try commands.stopLoopingSfx(loop_id);
    service.drain(&commands);
    try std.testing.expect(service.sfx_tracks.items[0].looping_id == null);
    try std.testing.expect(!fake.tracks.get(service.sfx_tracks.items[0].handle).?.playing);
}

test "audio service clears backend position when stopping looping sfx" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assetStore, .{ .max_sfx_tracks = 1, .spatial_units_per_meter = 100 }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    try std.testing.expect(try service.preloadAudio(.player_jet_sfx, "audio/sfx/jet.wav", .sfx, true));
    try std.testing.expect(try service.preloadAudio(.collision_sfx, "audio/sfx/hit.wav", .sfx, true));
    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();
    const loop_id = try LoopingSfxId.init(9);

    try commands.setListener(.{ .x = 0, .y = 0 });
    try commands.startLoopingSfx(loop_id, .{ .asset = .player_jet_sfx, .position = .{ .x = 200, .y = 100 } });
    service.drain(&commands);
    try std.testing.expect(fake.tracks.get(service.sfx_tracks.items[0].handle).?.position != null);

    commands.beginStep();
    try commands.stopLoopingSfx(loop_id);
    service.drain(&commands);
    try std.testing.expect(fake.tracks.get(service.sfx_tracks.items[0].handle).?.position == null);

    commands.beginStep();
    try commands.playSfx(.{ .asset = .collision_sfx });
    service.drain(&commands);
    try std.testing.expect(fake.tracks.get(service.sfx_tracks.items[0].handle).?.position == null);
}

test "audio service does not steal active loop track for one shot sfx" {
    var fake = FakeBackendContext.init(std.testing.allocator);
    defer fake.deinit();
    const assetStore = assets.AssetStore.init(std.testing.allocator, std.testing.io, "assets");
    var service = try AudioService.initWithBackend(std.testing.allocator, assetStore, .{ .max_sfx_tracks = 1 }, FakeBackendContext.backend(), @ptrCast(&fake));
    defer service.deinit();
    try std.testing.expect(try service.preloadAudio(.player_jet_sfx, "audio/sfx/jet.wav", .sfx, true));
    try std.testing.expect(try service.preloadAudio(.collision_sfx, "audio/sfx/hit.wav", .sfx, true));
    var commands = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer commands.deinit();
    const loop_id = try LoopingSfxId.init(11);

    try commands.startLoopingSfx(loop_id, .{ .asset = .player_jet_sfx, .priority = 10 });
    service.drain(&commands);
    commands.beginStep();
    try commands.playSfx(.{ .asset = .collision_sfx, .priority = 255 });
    service.drain(&commands);

    try std.testing.expectEqual(@as(u32, 1), fake.play_calls);
    try std.testing.expect(service.sfx_tracks.items[0].looping_id.?.value == loop_id.value);
}
