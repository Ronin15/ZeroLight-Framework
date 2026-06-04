// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const logging = @import("core/logging.zig");

pub const std_options = logging.std_options;

comptime {
    _ = @import("assets/assets.zig");
    _ = @import("assets/cache.zig");
    _ = @import("app/frame_pacer.zig");
    _ = @import("app/input.zig");
    _ = @import("app/input_router.zig");
    _ = @import("app/pause_controller.zig");
    _ = @import("app/resolution.zig");
    _ = @import("app/state.zig");
    _ = @import("app/thread_system.zig");
    _ = @import("app/time_loop.zig");
    _ = @import("core/math.zig");
    _ = @import("core/logging.zig");
    _ = @import("game/player.zig");
    _ = @import("main.zig");
    _ = @import("render/camera.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/resources.zig");
    _ = @import("render/text.zig");
    _ = @import("root.zig");
}
