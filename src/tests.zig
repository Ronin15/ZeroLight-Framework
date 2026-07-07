// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const logging = @import("core/logging.zig");

pub const std_options = logging.std_options;

comptime {
    _ = @import("assets/assets.zig");
    _ = @import("assets/cache.zig");
    _ = @import("assets/image.zig");
    _ = @import("assets/atlas_meta_common.zig");
    _ = @import("assets/manifest.zig");
    _ = @import("assets/runtime_assets.zig");
    _ = @import("assets/world_tileset_meta.zig");
    _ = @import("assets/sprite_atlas_meta.zig");
    _ = @import("app/audio.zig");
    _ = @import("app/frame_pacer.zig");
    _ = @import("app/input.zig");
    _ = @import("app/input_router.zig");
    _ = @import("app/pause_controller.zig");
    _ = @import("app/resolution.zig");
    _ = @import("app/state.zig");
    _ = @import("app/thread_system.zig");
    _ = @import("app/time_loop.zig");
    // Benchmark workloads and production world builds run via `zig build bench` only;
    // benchmarks/pathfinding.zig and benchmarks/render_game_prep.zig are exceptions
    // because their fixtures carry correctness invariants (hard-fallback service
    // ceiling; expectedBenchCollectedRecords) that a benchmark run alone won't
    // reliably catch a regression in.
    _ = @import("benchmarks/suite.zig");
    _ = @import("benchmarks/pathfinding.zig");
    _ = @import("benchmarks/render_game_prep.zig");
    _ = @import("core/math.zig");
    _ = @import("core/logging.zig");
    _ = @import("core/rng.zig");
    _ = @import("core/simd.zig");
    _ = @import("game/audio_controller.zig");
    _ = @import("game/data_system.zig");
    _ = @import("game/dig_controller.zig");
    _ = @import("game/game_demo_state.zig");
    _ = @import("game/loading_state.zig");
    _ = @import("game/main_menu_state.zig");
    _ = @import("game/menu_view.zig");
    _ = @import("game/settings_menu_state.zig");
    _ = @import("game/player.zig");
    _ = @import("game/render_depth.zig");
    _ = @import("game/render_prep.zig");
    _ = @import("game/simulation.zig");
    _ = @import("game/simulation_pipeline.zig");
    _ = @import("game/simulation_scope.zig");
    _ = @import("game/world_system.zig");
    _ = @import("game/systems/ai.zig");
    _ = @import("game/systems/ai_memory.zig");
    _ = @import("game/systems/affect.zig");
    _ = @import("game/systems/collision.zig");
    _ = @import("game/systems/collision_response.zig");
    _ = @import("game/systems/movement.zig");
    _ = @import("game/systems/pathfinding.zig");
    _ = @import("game/systems/particle.zig");
    _ = @import("game/systems/perception.zig");
    _ = @import("game/systems/simulation_scope.zig");
    _ = @import("game/systems/spatial_index.zig");
    _ = @import("game/systems/steering.zig");
    _ = @import("main.zig");
    _ = @import("render/gpu/buffer.zig");
    _ = @import("render/gpu/device.zig");
    _ = @import("render/gpu/pipeline_common.zig");
    _ = @import("render/gpu/shader_paths.zig");
    _ = @import("render/gpu/sprite_pipeline.zig");
    _ = @import("render/gpu/tilemap_pipeline.zig");
    _ = @import("render/gpu/texture.zig");
    _ = @import("render/camera.zig");
    _ = @import("render/renderer.zig");
    _ = @import("render/resources.zig");
    _ = @import("render/sprite_batch.zig");
    _ = @import("render/text.zig");
    _ = @import("root.zig");
}
