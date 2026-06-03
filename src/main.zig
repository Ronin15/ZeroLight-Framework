// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const build_options = @import("build_options");
const config = @import("config.zig");
const Engine = @import("app/engine.zig").Engine;
const TimeLoop = @import("app/time_loop.zig").TimeLoop;

pub fn main(init: std.process.Init) !void {
    const app_config = config.AppConfig{
        .app_name = build_options.app_name,
        .window_title = build_options.window_title,
        .asset_root = build_options.asset_root,
        .gpu_debug = build_options.gpu_debug,
    };

    var engine = try Engine.init(init, app_config);
    defer engine.deinit();

    var time_loop = TimeLoop.init(engine.nowNs());
    while (engine.isRunning()) {
        const frame_start_ns = engine.beginFrame();
        try engine.handleEvents();
        if (!engine.isRunning()) break;

        const frame_policy = engine.framePolicy();
        try engine.applyFrameControls(frame_policy, &time_loop);

        const frame_time_ns = engine.nowNs();
        const frame_delta_ns = if (frame_time_ns > time_loop.last_time_ns) frame_time_ns - time_loop.last_time_ns else 0;
        time_loop.beginFrame(frame_time_ns);

        while (time_loop.shouldUpdate()) {
            try engine.update(TimeLoop.fixed_delta_seconds);
            time_loop.finishUpdate();
            if (!engine.isRunning()) break;
        }
        if (!engine.isRunning()) break;

        try engine.renderFrame(frame_policy, time_loop.interpolationAlpha(), frame_start_ns, frame_delta_ns, &time_loop);
    }
}
