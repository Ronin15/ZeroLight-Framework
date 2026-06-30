// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const config = @import("../../config.zig");
const log = @import("../../core/logging.zig").render;
const sdl = @import("../../platform/sdl.zig");
const c = sdl.c;

/// Creates an SDL_GPU device. Caller owns the returned handle and must release it
/// with `SDL_DestroyGPUDevice` after releasing all dependent GPU resources.
pub fn createDevice(shader_formats: c.SDL_GPUShaderFormat, gpu_debug: bool) !*c.SDL_GPUDevice {
    const device = c.SDL_CreateGPUDevice(shader_formats, gpu_debug, null) orelse {
        return sdlError("SDL_CreateGPUDevice");
    };

    if (c.SDL_GetGPUDeviceDriver(device)) |driver| {
        log.debug("SDL_GPU driver: {s}", .{driver});
    } else {
        log.debug("SDL_GPU driver: unknown", .{});
    }

    return device;
}

/// Claims `window` for `device`. Pair with `SDL_ReleaseWindowFromGPUDevice` before
/// destroying the device.
pub fn claimWindow(device: *c.SDL_GPUDevice, window: *c.SDL_Window) !void {
    if (!c.SDL_ClaimWindowForGPUDevice(device, window)) {
        return sdlError("SDL_ClaimWindowForGPUDevice");
    }
}

/// Configures swapchain parameters on a claimed window. Call after `claimWindow`.
pub fn configureSwapchain(device: *c.SDL_GPUDevice, window: *c.SDL_Window, app_config: config.AppConfig) !void {
    const selected_present_mode = selectPresentMode(device, window, app_config.present_mode);

    if (!c.SDL_SetGPUAllowedFramesInFlight(device, app_config.frames_in_flight)) {
        return sdlError("SDL_SetGPUAllowedFramesInFlight");
    }

    if (!c.SDL_SetGPUSwapchainParameters(
        device,
        window,
        c.SDL_GPU_SWAPCHAINCOMPOSITION_SDR,
        selected_present_mode,
    )) {
        return sdlError("SDL_SetGPUSwapchainParameters");
    }
}

/// Creates the shared nearest-filtered clamp sampler. Caller owns the handle and
/// must release it with `SDL_ReleaseGPUSampler` before destroying the device.
pub fn createSampler(device: *c.SDL_GPUDevice) !*c.SDL_GPUSampler {
    var sampler_info = @import("std").mem.zeroes(c.SDL_GPUSamplerCreateInfo);
    sampler_info.min_filter = c.SDL_GPU_FILTER_NEAREST;
    sampler_info.mag_filter = c.SDL_GPU_FILTER_NEAREST;
    sampler_info.mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST;
    sampler_info.address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    sampler_info.address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;
    sampler_info.address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE;

    return c.SDL_CreateGPUSampler(device, &sampler_info) orelse {
        return sdlError("SDL_CreateGPUSampler");
    };
}

pub fn presentMode(mode: config.PresentMode) c.SDL_GPUPresentMode {
    return switch (mode) {
        .vsync => c.SDL_GPU_PRESENTMODE_VSYNC,
        .immediate => c.SDL_GPU_PRESENTMODE_IMMEDIATE,
        .mailbox => c.SDL_GPU_PRESENTMODE_MAILBOX,
    };
}

pub fn selectPresentMode(
    device: *c.SDL_GPUDevice,
    window: *c.SDL_Window,
    requested_mode: config.PresentMode,
) c.SDL_GPUPresentMode {
    const requested_sdl_mode = presentMode(requested_mode);
    if (requested_mode == .vsync or c.SDL_WindowSupportsGPUPresentMode(device, window, requested_sdl_mode)) {
        return requested_sdl_mode;
    }

    const fallbacks = [_]c.SDL_GPUPresentMode{
        c.SDL_GPU_PRESENTMODE_VSYNC,
        c.SDL_GPU_PRESENTMODE_MAILBOX,
        c.SDL_GPU_PRESENTMODE_IMMEDIATE,
    };
    for (fallbacks) |fallback| {
        if (c.SDL_WindowSupportsGPUPresentMode(device, window, fallback)) {
            log.warn("requested SDL_GPU present mode is unsupported; falling back", .{});
            return fallback;
        }
    }

    log.err("no supported SDL_GPU present mode found; using vsync", .{});
    return c.SDL_GPU_PRESENTMODE_VSYNC;
}

fn sdlError(comptime operation: []const u8) error{SdlError} {
    return sdl.sdlError(operation);
}

test "present mode maps config enum to SDL_GPU present mode" {
    const PresentMode = @TypeOf(presentMode(.vsync));
    try std.testing.expectEqual(@as(PresentMode, @intCast(c.SDL_GPU_PRESENTMODE_VSYNC)), presentMode(.vsync));
    try std.testing.expectEqual(@as(PresentMode, @intCast(c.SDL_GPU_PRESENTMODE_IMMEDIATE)), presentMode(.immediate));
    try std.testing.expectEqual(@as(PresentMode, @intCast(c.SDL_GPU_PRESENTMODE_MAILBOX)), presentMode(.mailbox));
}
