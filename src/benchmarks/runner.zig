// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const logging = @import("../core/logging.zig");
const ai = @import("ai.zig");
const ai_memory = @import("ai_memory.zig");
const affect = @import("affect.zig");
const chunk_scale = @import("chunk_scale.zig");
const collision = @import("collision.zig");
const collision_response = @import("collision_response.zig");
const movement = @import("movement.zig");
const nav_update = @import("nav_update.zig");
const particles = @import("particles.zig");
const pathfinding_cache = @import("pathfinding/cache.zig");
const pathfinding_connectivity = @import("pathfinding/connectivity.zig");
const pathfinding_negative = @import("pathfinding/negative.zig");
const pathfinding_requests = @import("pathfinding/requests.zig");
const pathfinding_routes = @import("pathfinding/routes.zig");
const perception = @import("perception.zig");
const plane_traversal = @import("plane_traversal.zig");
const production_step = @import("production_step.zig");
const render_prep = @import("render_prep.zig");
const render_game_prep = @import("render_game_prep.zig");
const scope = @import("scope.zig");
const sparse_window = @import("sparse_window.zig");
const spatial_index = @import("spatial_index.zig");
const steering = @import("steering.zig");
const suite = @import("suite.zig");
const thread_dispatch = @import("thread_dispatch.zig");
const world_create = @import("world_create.zig");
const world_gate = @import("world_gate.zig");

pub const std_options = logging.std_options;

const benchmark_groups = [_]suite.BenchmarkGroup{
    movement.group,
    movement.apply_intents_group,
    movement.apply_intents_sorted_group,
    particles.group,
    ai.group,
    ai.cell_ordered_group,
    ai_memory.group,
    ai_memory.shuffled_group,
    ai_memory.sparse_group,
    affect.group,
    affect.shuffled_group,
    collision.group,
    collision.sparse_group,
    collision.tall_group,
    collision.stacked_group,
    collision.thin_group,
    collision.static_heavy_sap_group,
    collision.static_heavy_group,
    collision.static_index_change_group,
    collision.static_triggers_group,
    collision_response.stage_group,
    pathfinding_requests.group,
    pathfinding_requests.dedup_group,
    pathfinding_requests.drain_group,
    pathfinding_requests.fallback_group,
    pathfinding_requests.fallback_detour_group,
    pathfinding_requests.hard_fallback_group,
    pathfinding_requests.hard_fallback_budget_group,
    pathfinding_requests.escalated_detour_group,
    pathfinding_requests.group_field_detour_group,
    pathfinding_requests.group_field_detour_moving_group,
    pathfinding_requests.group_field_detour_moving_hysteresis_group,
    pathfinding_requests.group_field_packs_group,
    pathfinding_requests.group_field_tunnel_group,
    pathfinding_requests.query_group,
    pathfinding_routes.level_size_group,
    pathfinding_routes.cross_level_depth_group,
    pathfinding_routes.cross_level_teleport_group,
    pathfinding_routes.cross_level_shaft_group,
    pathfinding_routes.long_path_group,
    pathfinding_routes.link_fold_group,
    pathfinding_cache.evict_group,
    pathfinding_cache.elastic_ramp_group,
    pathfinding_cache.elastic_shrink_group,
    pathfinding_negative.negative_steady_group,
    pathfinding_negative.negative_dig_group,
    pathfinding_negative.negative_burst_group,
    pathfinding_connectivity.connectivity_split_group,
    pathfinding_connectivity.connectivity_oneway_group,
    nav_update.group,
    nav_update.entity_obstacle_group,
    nav_update.static_population_group,
    nav_update.static_dense_group,
    nav_update.static_dense_tail_group,
    chunk_scale.dig_group,
    chunk_scale.ramp_group,
    chunk_scale.cave_in_group,
    chunk_scale.explosion_fill_group,
    chunk_scale.gpu_sync_dig_group,
    chunk_scale.gpu_sync_level_enter_group,
    chunk_scale.gpu_sync_pan_group,
    chunk_scale.nav_dig_group,
    chunk_scale.nav_ramp_group,
    chunk_scale.nav_cave_in_group,
    chunk_scale.nav_explosion_fill_group,
    chunk_scale.nav_enclose_group,
    chunk_scale.nav_level_add_group,
    render_prep.group,
    render_game_prep.group,
    render_game_prep.dense_deep_group,
    render_game_prep.offview_group,
    sparse_window.frame_group,
    sparse_window.pan_group,
    sparse_window.add_group,
    scope.cognition_group,
    plane_traversal.group,
    plane_traversal.falls_group,
    plane_traversal.dense_falls_group,
    plane_traversal.banded_falls_group,
    spatial_index.group,
    spatial_index.shape_group,
    spatial_index.query_group,
    perception.group,
    perception.los_dense_group,
    perception.scattered_dense_index_group,
    perception.cell_ordered_group,
    perception.crowd_group,
    steering.group,
    steering.shuffled_group,
    steering.corridor_group,
    steering.cluster_outlier_group,
    steering.static_change_group,
    steering.static_dense_group,
    thread_dispatch.group,
    world_gate.group,
    world_create.group,
    production_step.group,
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.skip();

    var parsed_args = std.ArrayList([]const u8).empty;
    defer parsed_args.deinit(init.gpa);
    while (args.next()) |arg| {
        try parsed_args.append(init.gpa, arg);
    }

    const options = suite.parseOptions(parsed_args.items) catch |err| switch (err) {
        error.HelpRequested => {
            suite.printUsage();
            return;
        },
        else => {
            suite.printUsage();
            return err;
        },
    };

    try suite.runAll(init.gpa, init.io, &benchmark_groups, options);
}
