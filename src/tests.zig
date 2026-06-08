// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const logging = @import("core/logging.zig");

pub const std_options = logging.std_options;

comptime {
    _ = @import("assets/assets.zig");
    _ = @import("assets/cache.zig");
    _ = @import("assets/image.zig");
    _ = @import("app/audio.zig");
    _ = @import("app/frame_pacer.zig");
    _ = @import("app/input.zig");
    _ = @import("app/input_router.zig");
    _ = @import("app/pause_controller.zig");
    _ = @import("app/resolution.zig");
    _ = @import("app/state.zig");
    _ = @import("app/thread_system.zig");
    _ = @import("app/time_loop.zig");
    _ = @import("benchmarks/collision.zig");
    _ = @import("benchmarks/collision_response.zig");
    _ = @import("benchmarks/suite.zig");
    _ = @import("benchmarks/movement.zig");
    _ = @import("benchmarks/particles.zig");
    _ = @import("core/math.zig");
    _ = @import("core/logging.zig");
    _ = @import("core/simd.zig");
    _ = @import("game/data_system.zig");
    _ = @import("game/game_demo_state.zig");
    _ = @import("game/player.zig");
    _ = @import("game/simulation.zig");
    _ = @import("game/systems/collision.zig");
    _ = @import("game/systems/collision_response.zig");
    _ = @import("game/systems/movement.zig");
    _ = @import("game/systems/particle.zig");
    _ = @import("main.zig");
    _ = @import("render/gpu/buffer.zig");
    _ = @import("render/gpu/device.zig");
    _ = @import("render/gpu/sprite_pipeline.zig");
    _ = @import("render/gpu/texture.zig");
    _ = @import("render/camera.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/resources.zig");
    _ = @import("render/sprite_batch.zig");
    _ = @import("render/text.zig");
    _ = @import("root.zig");
}
