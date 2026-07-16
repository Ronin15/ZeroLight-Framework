// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../core/logging.zig");
const sdl = @import("../platform/sdl.zig").c;
const BatchStats = @import("thread_system.zig").BatchStats;
const SpritePrepStats = @import("../render/renderer.zig").SpritePrepStats;

const log = logging.perf;

// Instrumented in Debug and ReleaseSafe; fully compiled out of
// ReleaseFast/ReleaseSmall (zero-sized types, no StageTimer, no counters).
//
// Debug (`dev` / `run`): fix cycles — iterate code and behavior. Perf lines may
// appear but are not the soak authority (Debug is heavily pessimistic).
// ReleaseSafe: intentional soaks for ranking and absolute scale numbers (slow
// compile — not every edit). Emit uses `log.debug`; both modes' `auto` log
// level includes debug.
pub const enabled = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};
pub const interval_ns: u64 = 60 * std.time.ns_per_s;

pub const FrameResult = enum {
    submitted,
    skipped_no_swapchain,
    no_render,
};

pub const Metric = enum {
    sdl_events,
    sdl_presentation_events,
    sdl_window_resize_events,
    sdl_window_fullscreen_events,
    sdl_window_display_events,
    sdl_window_focus_events,
    sdl_window_visibility_events,
    sdl_window_move_events,
    state_updates,
    state_renders,
    fixed_updates,
    update_cap_hits,
    submitted_frames,
    skipped_no_swapchain_frames,
    no_render_frames,
    sprite_commands,
    sprite_valid,
    sprite_skipped_invalid,
    sprite_vertices,
    sprite_draw_groups,
    ai_entities,
    ai_intents,
    ai_navigation_intents,
    ai_separation_candidate_checks,
    ai_separation_neighbor_samples,
    perception_observers,
    perception_sensed,
    perception_los_checks,
    perception_los_blocked,
    perception_nearest_threat_found,
    perception_candidate_checks,
    steering_navigation_intents,
    steering_selected_intents,
    steering_movement_intents,
    steering_path_requests,
    steering_paths_available,
    steering_paths_pending,
    steering_paths_unavailable,
    steering_replan_cooldowns,
    steering_unavailable_backoffs,
    steering_stuck_replans,
    steering_agent_neighbor_samples,
    steering_obstacle_samples,
    steering_agent_candidate_checks,
    steering_obstacle_candidate_checks,
    path_accepted_requests,
    path_duplicate_requests,
    path_pending_requests,
    path_solved_requests,
    path_fallback_requests,
    path_available_results,
    path_unavailable_results,
    path_dropped_requests,
    path_deferred_requests,
    path_fallback_deferred_requests,
    path_cache_hits,
    path_cache_evictions,
    path_budget_exhausted,
    path_escalated_solves,
    path_escalated_deferred,
    path_goal_projected,
    path_group_fields_built,
    path_group_field_reuses,
    path_group_field_rebuild_throttled,
    path_group_field_samples,
    path_max_stitch_segments,
    path_max_distinct_group_keys,
    nav_dirty_chunks,
    nav_incremental_rebuilds,
    nav_full_relabel,
    nav_version_bumps,
    nav_chunks_patched,
    nav_edge_cap_fallback,
    movement_bodies,
    collision_bodies,
    collision_candidate_pairs,
    collision_contacts,
    collision_broadphase_simd_groups,
    collision_full_sorts,
    collision_response_contacts,
    collision_response_intents,
    collision_response_triggers,
    stimuli_live_dropped,
    stimuli_deferred_dropped,
    stimuli_promoted,
    action_intents_consumed,
    action_intents_dropped,
    particle_active_before,
    particle_active_after,
    particle_removed,
    structural_created,
    structural_destroyed,
    structural_components_set,
    structural_stale_skipped,
    scope_total_entities,
    scope_dormant_entities,
    scope_kinematic_entities,
    scope_locomotion_entities,
    scope_cognition_entities,
    scope_movement_stage_entities,
    scope_collision_stage_entities,
    scope_collision_response_stage_entities,
    scope_ai_stage_entities,
    scope_steering_stage_entities,
    scope_stagger_skips,
    scope_chunk_filtered_entities,
    simulation_events_total,
    simulation_events_dropped,
    simulation_events_entity_created,
    simulation_events_entity_destroyed,
    simulation_events_component_changed,
    simulation_events_world_tile_changed,
    simulation_events_world_obstacle_changed,
    simulation_events_nav_region_invalidated,
    simulation_events_entity_perceived,
    simulation_events_entity_lost,
    simulation_events_affect_threshold_crossed,
    simulation_events_structural_commit_stage,
    simulation_events_domain_reaction_stage,
};

pub const Timing = enum {
    frame_interval,
    events,
    frame_controls,
    app_tick,
    state_update,
    gameplay_update,
    // Fine-grained gameplay-tick stages. Each pipeline_* timer covers one
    // system's whole call (its serial prep plus its threaded dispatch and
    // join), so comparing it against the matching batch_* avg_ms isolates the
    // serial/dispatch overhead that the batch counters never see. The
    // gameplay_* timers cover state-owned glue outside the pipeline.
    pipeline_spatial_index,
    pipeline_perception,
    pipeline_ai_memory,
    pipeline_ai_affect,
    pipeline_ai,
    pipeline_steering,
    pipeline_pathfinding,
    pipeline_apply_intents,
    pipeline_movement,
    pipeline_clamp_bounds,
    pipeline_collision,
    pipeline_collision_response,
    pipeline_chunk_derive,
    gameplay_input,
    gameplay_audio,
    gameplay_particles,
    gameplay_camera,
    gameplay_structural,
    // Pathfinding sub-stages: a breakdown of pipeline_pathfinding into request
    // accept/dedup, group-field service/build, individual+abstract solve+stitch,
    // and result publish/compact, so the dominant phase is visible.
    pathfinding_accept,
    pathfinding_group_service,
    pathfinding_solve,
    pathfinding_publish,
    // Steering prepareUpdate breakdown (main-thread setup before the avoidance
    // batch). Compare against batch steering avg_ms to isolate serial overhead.
    steering_select,
    steering_snapshot,
    steering_directions,
    // Collision update breakdown before/around the broadphase batch.
    collision_gather,
    collision_sort,
    state_transitions,
    audio_drain,
    loading_build,
    render_total,
    render_enqueue,
    render_overlay,
    render_end_frame,
};

pub const BatchStage = enum {
    spatial_index_build,
    perception,
    ai_separation,
    ai_intent,
    steering,
    path_fallback,
    movement,
    chunk_derive,
    collision_broadphase,
    collision_narrowphase,
    particles,
    sprite_prep,
};

pub const FrameSample = struct {
    frame_delta_ns: u64 = 0,
    fixed_updates: u32 = 0,
    hit_update_cap: bool = false,
    result: FrameResult = .no_render,
    sprite_prep: SpritePrepStats = .{},
};

const metric_count = std.meta.fields(Metric).len;
const timing_count = std.meta.fields(Timing).len;
const batch_stage_count = std.meta.fields(BatchStage).len;

pub const RuntimePerfLog = if (enabled) EnabledRuntimePerfLog else DisabledRuntimePerfLog;

pub const Context = if (enabled) struct {
    logger: ?*RuntimePerfLog = null,

    pub fn bind(logger: *RuntimePerfLog) Context {
        return .{ .logger = logger };
    }

    pub fn recordMetric(self: Context, metric: Metric, value: u64) void {
        if (self.logger) |logger| logger.recordMetric(metric, value);
    }

    // High-water-mark variant: keeps the max value recorded within the interval
    // instead of summing every call, for metrics that are already a per-step peak
    // (e.g. max_stitch_segments_observed) where summing across steps would conflate
    // magnitude with frequency.
    pub fn recordMetricMax(self: Context, metric: Metric, value: u64) void {
        if (self.logger) |logger| logger.recordMetricMax(metric, value);
    }

    pub fn recordTiming(self: Context, timing: Timing, duration_ns: u64) void {
        if (self.logger) |logger| logger.recordTiming(timing, duration_ns);
    }

    pub fn recordBatch(self: Context, stage: BatchStage, stats: BatchStats) void {
        if (self.logger) |logger| logger.recordBatch(stage, stats);
    }
} else struct {
    pub fn bind(_: *RuntimePerfLog) Context {
        return .{};
    }

    pub fn recordMetric(_: Context, _: Metric, _: u64) void {}
    pub fn recordMetricMax(_: Context, _: Metric, _: u64) void {}
    pub fn recordTiming(_: Context, _: Timing, _: u64) void {}
    pub fn recordBatch(_: Context, _: BatchStage, _: BatchStats) void {}
};

comptime {
    if (!enabled) {
        std.debug.assert(@sizeOf(RuntimePerfLog) == 0);
        std.debug.assert(@sizeOf(Context) == 0);
    }
}

// Comptime-gated wall-clock timer for one fixed-step stage/phase. Zero-field,
// zero-cost no-op when perf logging is disabled; otherwise samples the SDL
// monotonic clock. `stop` is the direct-to-context convenience for a stage bound
// to one Timing id; `lap` returns the raw duration for a caller that folds it into
// its own stats struct first (e.g. PathfindingStats' per-phase ns fields) before it
// reaches the perf log.
pub const StageTimer = if (enabled) struct {
    start_ns: u64,

    pub fn start() StageTimer {
        return .{ .start_ns = sdl.SDL_GetTicksNS() };
    }

    pub const begin = start;

    pub fn lap(self: *const StageTimer) u64 {
        const now = sdl.SDL_GetTicksNS();
        return if (now > self.start_ns) now - self.start_ns else 0;
    }

    pub fn stop(self: StageTimer, perf: Context, timing: Timing) void {
        perf.recordTiming(timing, self.lap());
    }
} else struct {
    pub fn start() StageTimer {
        return .{};
    }
    pub const begin = start;
    pub fn lap(_: *const StageTimer) u64 {
        return 0;
    }
    pub fn stop(_: StageTimer, _: Context, _: Timing) void {}
};

const DisabledRuntimePerfLog = struct {
    pub fn init(_: u64) DisabledRuntimePerfLog {
        return .{};
    }

    pub fn recordMetric(_: *DisabledRuntimePerfLog, _: Metric, _: u64) void {}
    pub fn recordMetricMax(_: *DisabledRuntimePerfLog, _: Metric, _: u64) void {}
    pub fn recordTiming(_: *DisabledRuntimePerfLog, _: Timing, _: u64) void {}
    pub fn recordBatch(_: *DisabledRuntimePerfLog, _: BatchStage, _: BatchStats) void {}
    pub fn recordFrame(_: *DisabledRuntimePerfLog, _: u64, _: FrameSample) void {}
};

const EnabledRuntimePerfLog = struct {
    interval_start_ns: u64,
    frames: u64 = 0,
    metrics: [metric_count]u64 = [_]u64{0} ** metric_count,
    timings: [timing_count]TimingAggregate = [_]TimingAggregate{.{}} ** timing_count,
    batches: [batch_stage_count]BatchAggregate = [_]BatchAggregate{.{}} ** batch_stage_count,

    pub fn init(now_ns: u64) EnabledRuntimePerfLog {
        return .{ .interval_start_ns = now_ns };
    }

    pub fn recordMetric(self: *EnabledRuntimePerfLog, metric_id: Metric, value: u64) void {
        self.metrics[@intFromEnum(metric_id)] += value;
    }

    pub fn recordMetricMax(self: *EnabledRuntimePerfLog, metric_id: Metric, value: u64) void {
        const slot = &self.metrics[@intFromEnum(metric_id)];
        slot.* = @max(slot.*, value);
    }

    pub fn recordTiming(self: *EnabledRuntimePerfLog, timing_id: Timing, duration_ns: u64) void {
        self.timings[@intFromEnum(timing_id)].record(duration_ns);
    }

    pub fn recordBatch(self: *EnabledRuntimePerfLog, stage: BatchStage, stats: BatchStats) void {
        if (stats.item_count == 0 and stats.range_count == 0 and stats.batch_duration_ns == 0) return;
        self.batches[@intFromEnum(stage)].record(stats);
    }

    pub fn recordFrame(self: *EnabledRuntimePerfLog, now_ns: u64, sample: FrameSample) void {
        self.frames += 1;
        self.recordTiming(.frame_interval, sample.frame_delta_ns);
        self.recordMetric(.fixed_updates, sample.fixed_updates);
        if (sample.hit_update_cap) self.recordMetric(.update_cap_hits, 1);
        switch (sample.result) {
            .submitted => self.recordMetric(.submitted_frames, 1),
            .skipped_no_swapchain => self.recordMetric(.skipped_no_swapchain_frames, 1),
            .no_render => self.recordMetric(.no_render_frames, 1),
        }
        self.recordSpritePrep(sample.sprite_prep);

        if (now_ns - self.interval_start_ns >= interval_ns) {
            self.emit(now_ns - self.interval_start_ns);
            self.reset(now_ns);
        }
    }

    fn recordSpritePrep(self: *EnabledRuntimePerfLog, stats: SpritePrepStats) void {
        self.recordMetric(.sprite_commands, stats.command_count);
        self.recordMetric(.sprite_valid, stats.valid_sprite_count);
        self.recordMetric(.sprite_skipped_invalid, stats.skipped_invalid_count);
        self.recordMetric(.sprite_vertices, stats.vertex_count);
        self.recordMetric(.sprite_draw_groups, stats.draw_group_count);
        self.recordBatch(.sprite_prep, stats.batch);
    }

    fn reset(self: *EnabledRuntimePerfLog, now_ns: u64) void {
        self.interval_start_ns = now_ns;
        self.frames = 0;
        self.metrics = [_]u64{0} ** metric_count;
        self.timings = [_]TimingAggregate{.{}} ** timing_count;
        self.batches = [_]BatchAggregate{.{}} ** batch_stage_count;
    }

    fn emit(self: *const EnabledRuntimePerfLog, elapsed_ns: u64) void {
        const frame_interval_timing = self.timingValue(.frame_interval);
        const events_timing = self.timingValue(.events);
        const frame_controls_timing = self.timingValue(.frame_controls);
        const app_tick_timing = self.timingValue(.app_tick);
        const state_update_timing = self.timingValue(.state_update);
        const gameplay_update_timing = self.timingValue(.gameplay_update);
        const transition_timing = self.timingValue(.state_transitions);
        const audio_drain_timing = self.timingValue(.audio_drain);
        const loading_build_timing = self.timingValue(.loading_build);
        const render_total_timing = self.timingValue(.render_total);
        const render_enqueue_timing = self.timingValue(.render_enqueue);
        const render_overlay_timing = self.timingValue(.render_overlay);
        const render_end_frame_timing = self.timingValue(.render_end_frame);
        const elapsed_s = seconds(elapsed_ns);
        const update_count = self.metricValue(.fixed_updates);
        const rendered_frame_count = self.metricValue(.submitted_frames) +
            self.metricValue(.skipped_no_swapchain_frames);

        log.debug(
            "perf {d:.1}s frames={} submitted={} no_swapchain={} no_render={} updates={} cap_hits={} frame_interval_avg_ms={d:.3} frame_interval_max_ms={d:.3} events_avg_ms={d:.3} events_max_ms={d:.3} controls_avg_ms={d:.3} controls_max_ms={d:.3} app_tick_avg_ms={d:.3} app_tick_max_ms={d:.3} render_total_avg_ms={d:.3} render_total_max_ms={d:.3} event_count={} presentation_events={} resize={} fullscreen={} display={} focus={} visibility={} move={}",
            .{
                elapsed_s,
                self.frames,
                self.metricValue(.submitted_frames),
                self.metricValue(.skipped_no_swapchain_frames),
                self.metricValue(.no_render_frames),
                self.metricValue(.fixed_updates),
                self.metricValue(.update_cap_hits),
                millis(frame_interval_timing.averageNs()),
                millis(frame_interval_timing.max_ns),
                millis(events_timing.averageNs()),
                millis(events_timing.max_ns),
                millis(frame_controls_timing.averageNs()),
                millis(frame_controls_timing.max_ns),
                millis(app_tick_timing.averageNs()),
                millis(app_tick_timing.max_ns),
                millis(render_total_timing.averageNs()),
                millis(render_total_timing.max_ns),
                self.metricValue(.sdl_events),
                self.metricValue(.sdl_presentation_events),
                self.metricValue(.sdl_window_resize_events),
                self.metricValue(.sdl_window_fullscreen_events),
                self.metricValue(.sdl_window_display_events),
                self.metricValue(.sdl_window_focus_events),
                self.metricValue(.sdl_window_visibility_events),
                self.metricValue(.sdl_window_move_events),
            },
        );
        log.debug(
            "perf {d:.1}s update state_avg_ms={d:.3} state_max_ms={d:.3} gameplay_avg_ms={d:.3} gameplay_max_ms={d:.3} transitions_avg_ms={d:.3} transitions_max_ms={d:.3} audio_drain_avg_ms={d:.3} audio_drain_max_ms={d:.3} loading_build_avg_ms={d:.3} loading_build_max_ms={d:.3}",
            .{
                elapsed_s,
                millis(state_update_timing.averageNs()),
                millis(state_update_timing.max_ns),
                millis(gameplay_update_timing.averageNs()),
                millis(gameplay_update_timing.max_ns),
                millis(transition_timing.averageNs()),
                millis(transition_timing.max_ns),
                millis(audio_drain_timing.averageNs()),
                millis(audio_drain_timing.max_ns),
                millis(loading_build_timing.averageNs()),
                millis(loading_build_timing.max_ns),
            },
        );
        const pipeline_spatial_index_timing = self.timingValue(.pipeline_spatial_index);
        const pipeline_perception_timing = self.timingValue(.pipeline_perception);
        const pipeline_ai_memory_timing = self.timingValue(.pipeline_ai_memory);
        const pipeline_ai_affect_timing = self.timingValue(.pipeline_ai_affect);
        const pipeline_ai_timing = self.timingValue(.pipeline_ai);
        const pipeline_steering_timing = self.timingValue(.pipeline_steering);
        const pipeline_pathfinding_timing = self.timingValue(.pipeline_pathfinding);
        const pipeline_apply_intents_timing = self.timingValue(.pipeline_apply_intents);
        const pipeline_movement_timing = self.timingValue(.pipeline_movement);
        const pipeline_clamp_timing = self.timingValue(.pipeline_clamp_bounds);
        const pipeline_collision_timing = self.timingValue(.pipeline_collision);
        const pipeline_collision_response_timing = self.timingValue(.pipeline_collision_response);
        const pipeline_chunk_derive_timing = self.timingValue(.pipeline_chunk_derive);
        log.debug(
            "perf {d:.1}s pipeline spatial_index_avg_ms={d:.3} spatial_index_max_ms={d:.3} perception_avg_ms={d:.3} perception_max_ms={d:.3} ai_memory_avg_ms={d:.3} ai_memory_max_ms={d:.3} ai_affect_avg_ms={d:.3} ai_affect_max_ms={d:.3} ai_avg_ms={d:.3} ai_max_ms={d:.3} steering_avg_ms={d:.3} steering_max_ms={d:.3} pathfinding_avg_ms={d:.3} pathfinding_max_ms={d:.3} apply_intents_avg_ms={d:.3} apply_intents_max_ms={d:.3} movement_avg_ms={d:.3} movement_max_ms={d:.3} clamp_avg_ms={d:.3} clamp_max_ms={d:.3} collision_avg_ms={d:.3} collision_max_ms={d:.3} response_avg_ms={d:.3} response_max_ms={d:.3} chunk_derive_avg_ms={d:.3} chunk_derive_max_ms={d:.3}",
            .{
                elapsed_s,
                millis(pipeline_spatial_index_timing.averageNs()),
                millis(pipeline_spatial_index_timing.max_ns),
                millis(pipeline_perception_timing.averageNs()),
                millis(pipeline_perception_timing.max_ns),
                millis(pipeline_ai_memory_timing.averageNs()),
                millis(pipeline_ai_memory_timing.max_ns),
                millis(pipeline_ai_affect_timing.averageNs()),
                millis(pipeline_ai_affect_timing.max_ns),
                millis(pipeline_ai_timing.averageNs()),
                millis(pipeline_ai_timing.max_ns),
                millis(pipeline_steering_timing.averageNs()),
                millis(pipeline_steering_timing.max_ns),
                millis(pipeline_pathfinding_timing.averageNs()),
                millis(pipeline_pathfinding_timing.max_ns),
                millis(pipeline_apply_intents_timing.averageNs()),
                millis(pipeline_apply_intents_timing.max_ns),
                millis(pipeline_movement_timing.averageNs()),
                millis(pipeline_movement_timing.max_ns),
                millis(pipeline_clamp_timing.averageNs()),
                millis(pipeline_clamp_timing.max_ns),
                millis(pipeline_collision_timing.averageNs()),
                millis(pipeline_collision_timing.max_ns),
                millis(pipeline_collision_response_timing.averageNs()),
                millis(pipeline_collision_response_timing.max_ns),
                millis(pipeline_chunk_derive_timing.averageNs()),
                millis(pipeline_chunk_derive_timing.max_ns),
            },
        );
        const gameplay_input_timing = self.timingValue(.gameplay_input);
        const gameplay_audio_timing = self.timingValue(.gameplay_audio);
        const gameplay_particles_timing = self.timingValue(.gameplay_particles);
        const gameplay_camera_timing = self.timingValue(.gameplay_camera);
        const gameplay_structural_timing = self.timingValue(.gameplay_structural);
        log.debug(
            "perf {d:.1}s gameplay_stage input_avg_ms={d:.3} input_max_ms={d:.3} audio_avg_ms={d:.3} audio_max_ms={d:.3} particles_avg_ms={d:.3} particles_max_ms={d:.3} camera_avg_ms={d:.3} camera_max_ms={d:.3} structural_avg_ms={d:.3} structural_max_ms={d:.3}",
            .{
                elapsed_s,
                millis(gameplay_input_timing.averageNs()),
                millis(gameplay_input_timing.max_ns),
                millis(gameplay_audio_timing.averageNs()),
                millis(gameplay_audio_timing.max_ns),
                millis(gameplay_particles_timing.averageNs()),
                millis(gameplay_particles_timing.max_ns),
                millis(gameplay_camera_timing.averageNs()),
                millis(gameplay_camera_timing.max_ns),
                millis(gameplay_structural_timing.averageNs()),
                millis(gameplay_structural_timing.max_ns),
            },
        );
        const pathfinding_accept_timing = self.timingValue(.pathfinding_accept);
        const pathfinding_group_timing = self.timingValue(.pathfinding_group_service);
        const pathfinding_solve_timing = self.timingValue(.pathfinding_solve);
        const pathfinding_publish_timing = self.timingValue(.pathfinding_publish);
        log.debug(
            "perf {d:.1}s pathfinding accept_avg_ms={d:.3} accept_max_ms={d:.3} group_avg_ms={d:.3} group_max_ms={d:.3} solve_avg_ms={d:.3} solve_max_ms={d:.3} publish_avg_ms={d:.3} publish_max_ms={d:.3} max_stitch_segments={} group_built={} group_reuses={} group_throttled={} group_samples={} max_distinct_group_keys={}",
            .{
                elapsed_s,
                millis(pathfinding_accept_timing.averageNs()),
                millis(pathfinding_accept_timing.max_ns),
                millis(pathfinding_group_timing.averageNs()),
                millis(pathfinding_group_timing.max_ns),
                millis(pathfinding_solve_timing.averageNs()),
                millis(pathfinding_solve_timing.max_ns),
                millis(pathfinding_publish_timing.averageNs()),
                millis(pathfinding_publish_timing.max_ns),
                self.metricValue(.path_max_stitch_segments),
                self.metricValue(.path_group_fields_built),
                self.metricValue(.path_group_field_reuses),
                self.metricValue(.path_group_field_rebuild_throttled),
                self.metricValue(.path_group_field_samples),
                self.metricValue(.path_max_distinct_group_keys),
            },
        );
        const steering_select_timing = self.timingValue(.steering_select);
        const steering_snapshot_timing = self.timingValue(.steering_snapshot);
        const steering_directions_timing = self.timingValue(.steering_directions);
        log.debug(
            "perf {d:.1}s steering_setup select_avg_ms={d:.3} select_max_ms={d:.3} snapshot_avg_ms={d:.3} snapshot_max_ms={d:.3} directions_avg_ms={d:.3} directions_max_ms={d:.3}",
            .{
                elapsed_s,
                millis(steering_select_timing.averageNs()),
                millis(steering_select_timing.max_ns),
                millis(steering_snapshot_timing.averageNs()),
                millis(steering_snapshot_timing.max_ns),
                millis(steering_directions_timing.averageNs()),
                millis(steering_directions_timing.max_ns),
            },
        );
        const collision_gather_timing = self.timingValue(.collision_gather);
        const collision_sort_timing = self.timingValue(.collision_sort);
        log.debug(
            "perf {d:.1}s collision_setup gather_avg_ms={d:.3} gather_max_ms={d:.3} sort_avg_ms={d:.3} sort_max_ms={d:.3} full_sorts={}",
            .{
                elapsed_s,
                millis(collision_gather_timing.averageNs()),
                millis(collision_gather_timing.max_ns),
                millis(collision_sort_timing.averageNs()),
                millis(collision_sort_timing.max_ns),
                self.metricValue(.collision_full_sorts),
            },
        );
        log.debug(
            "perf {d:.1}s dispatch state_updates={} state_renders={} render_enqueue_avg_ms={d:.3} render_enqueue_max_ms={d:.3} overlay_avg_ms={d:.3} overlay_max_ms={d:.3} end_frame_avg_ms={d:.3} end_frame_max_ms={d:.3} sprites commands={} valid={} skipped={} sprites_per_frame={d:.1} vertices={} groups={}",
            .{
                elapsed_s,
                self.metricValue(.state_updates),
                self.metricValue(.state_renders),
                millis(render_enqueue_timing.averageNs()),
                millis(render_enqueue_timing.max_ns),
                millis(render_overlay_timing.averageNs()),
                millis(render_overlay_timing.max_ns),
                millis(render_end_frame_timing.averageNs()),
                millis(render_end_frame_timing.max_ns),
                self.metricValue(.sprite_commands),
                self.metricValue(.sprite_valid),
                self.metricValue(.sprite_skipped_invalid),
                averagePer(self.metricValue(.sprite_commands), rendered_frame_count),
                self.metricValue(.sprite_vertices),
                self.metricValue(.sprite_draw_groups),
            },
        );
        log.debug(
            "perf {d:.1}s scope total={} dormant={} kinematic={} locomotion={} cognition={} stage movement={} collision={} response={} ai={} steering={} stagger_skips={} chunk_filtered={}",
            .{
                elapsed_s,
                self.metricValue(.scope_total_entities),
                self.metricValue(.scope_dormant_entities),
                self.metricValue(.scope_kinematic_entities),
                self.metricValue(.scope_locomotion_entities),
                self.metricValue(.scope_cognition_entities),
                self.metricValue(.scope_movement_stage_entities),
                self.metricValue(.scope_collision_stage_entities),
                self.metricValue(.scope_collision_response_stage_entities),
                self.metricValue(.scope_ai_stage_entities),
                self.metricValue(.scope_steering_stage_entities),
                self.metricValue(.scope_stagger_skips),
                self.metricValue(.scope_chunk_filtered_entities),
            },
        );
        log.debug(
            "perf {d:.1}s gameplay ai_entities={} ai_avg={d:.1} ai_intents={} ai_nav={} steering_selected={} steering_move={} movement_bodies={} movement_avg={d:.1} collision_bodies={} collision_avg={d:.1} collision_pairs={} collision_contacts={} response_intents={} response_triggers={} stimuli_live_dropped={} stimuli_deferred_dropped={} stimuli_promoted={} particles_before={} particles_avg={d:.1} particles_after={} particles_removed={} structural created={} destroyed={} components={} stale={}",
            .{
                elapsed_s,
                self.metricValue(.ai_entities),
                averagePer(self.metricValue(.ai_entities), update_count),
                self.metricValue(.ai_intents),
                self.metricValue(.ai_navigation_intents),
                self.metricValue(.steering_selected_intents),
                self.metricValue(.steering_movement_intents),
                self.metricValue(.movement_bodies),
                averagePer(self.metricValue(.movement_bodies), update_count),
                self.metricValue(.collision_bodies),
                averagePer(self.metricValue(.collision_bodies), update_count),
                self.metricValue(.collision_candidate_pairs),
                self.metricValue(.collision_contacts),
                self.metricValue(.collision_response_intents),
                self.metricValue(.collision_response_triggers),
                self.metricValue(.stimuli_live_dropped),
                self.metricValue(.stimuli_deferred_dropped),
                self.metricValue(.stimuli_promoted),
                self.metricValue(.particle_active_before),
                averagePer(self.metricValue(.particle_active_before), update_count),
                self.metricValue(.particle_active_after),
                self.metricValue(.particle_removed),
                self.metricValue(.structural_created),
                self.metricValue(.structural_destroyed),
                self.metricValue(.structural_components_set),
                self.metricValue(.structural_stale_skipped),
            },
        );
        log.debug(
            "perf {d:.1}s perception observers={} observers_avg={d:.1} sensed={} los_checks={} los_blocked={} nearest_found={} candidate_checks={}",
            .{
                elapsed_s,
                self.metricValue(.perception_observers),
                averagePer(self.metricValue(.perception_observers), update_count),
                self.metricValue(.perception_sensed),
                self.metricValue(.perception_los_checks),
                self.metricValue(.perception_los_blocked),
                self.metricValue(.perception_nearest_threat_found),
                self.metricValue(.perception_candidate_checks),
            },
        );
        log.debug(
            "perf {d:.1}s events total={} dropped={} created={} destroyed={} component_changed={} world_tile_changed={} world_obstacle_changed={} nav_invalidated={} entity_perceived={} entity_lost={} affect_crossed={} structural_stage={} domain_stage={}",
            .{
                elapsed_s,
                self.metricValue(.simulation_events_total),
                self.metricValue(.simulation_events_dropped),
                self.metricValue(.simulation_events_entity_created),
                self.metricValue(.simulation_events_entity_destroyed),
                self.metricValue(.simulation_events_component_changed),
                self.metricValue(.simulation_events_world_tile_changed),
                self.metricValue(.simulation_events_world_obstacle_changed),
                self.metricValue(.simulation_events_nav_region_invalidated),
                self.metricValue(.simulation_events_entity_perceived),
                self.metricValue(.simulation_events_entity_lost),
                self.metricValue(.simulation_events_affect_threshold_crossed),
                self.metricValue(.simulation_events_structural_commit_stage),
                self.metricValue(.simulation_events_domain_reaction_stage),
            },
        );
        log.debug(
            "perf {d:.1}s path accepted={} duplicate={} pending={} solved={} fallback={} available={} unavailable={} dropped={} deferred={} fallback_deferred={} cache_hits={} evictions={} budget_exhausted={} escalated={} escalated_deferred={} goal_projected={} group_built={} group_reuses={} group_throttled={} group_samples={}",
            .{
                elapsed_s,
                self.metricValue(.path_accepted_requests),
                self.metricValue(.path_duplicate_requests),
                self.metricValue(.path_pending_requests),
                self.metricValue(.path_solved_requests),
                self.metricValue(.path_fallback_requests),
                self.metricValue(.path_available_results),
                self.metricValue(.path_unavailable_results),
                self.metricValue(.path_dropped_requests),
                self.metricValue(.path_deferred_requests),
                self.metricValue(.path_fallback_deferred_requests),
                self.metricValue(.path_cache_hits),
                self.metricValue(.path_cache_evictions),
                self.metricValue(.path_budget_exhausted),
                self.metricValue(.path_escalated_solves),
                self.metricValue(.path_escalated_deferred),
                self.metricValue(.path_goal_projected),
                self.metricValue(.path_group_fields_built),
                self.metricValue(.path_group_field_reuses),
                self.metricValue(.path_group_field_rebuild_throttled),
                self.metricValue(.path_group_field_samples),
            },
        );
        log.debug(
            "perf {d:.1}s nav dirty_chunks={} incremental_rebuilds={} full_relabel={} version_bumps={} chunks_patched={} edge_cap_fallback={} region_invalidated={}",
            .{
                elapsed_s,
                self.metricValue(.nav_dirty_chunks),
                self.metricValue(.nav_incremental_rebuilds),
                self.metricValue(.nav_full_relabel),
                self.metricValue(.nav_version_bumps),
                self.metricValue(.nav_chunks_patched),
                self.metricValue(.nav_edge_cap_fallback),
                self.metricValue(.simulation_events_nav_region_invalidated),
            },
        );
        log.debug(
            "perf {d:.1}s steering path_requests={} available={} pending={} unavailable={} replans={} unavailable_backoff={} stuck={} agent_samples={} obstacle_samples={} agent_checks={} obstacle_checks={} ai_sep_checks={} ai_sep_samples={} collision_simd_groups={} full_sorts={}",
            .{
                elapsed_s,
                self.metricValue(.steering_path_requests),
                self.metricValue(.steering_paths_available),
                self.metricValue(.steering_paths_pending),
                self.metricValue(.steering_paths_unavailable),
                self.metricValue(.steering_replan_cooldowns),
                self.metricValue(.steering_unavailable_backoffs),
                self.metricValue(.steering_stuck_replans),
                self.metricValue(.steering_agent_neighbor_samples),
                self.metricValue(.steering_obstacle_samples),
                self.metricValue(.steering_agent_candidate_checks),
                self.metricValue(.steering_obstacle_candidate_checks),
                self.metricValue(.ai_separation_candidate_checks),
                self.metricValue(.ai_separation_neighbor_samples),
                self.metricValue(.collision_broadphase_simd_groups),
                self.metricValue(.collision_full_sorts),
            },
        );

        inline for (std.meta.fields(BatchStage)) |field| {
            const stage: BatchStage = @enumFromInt(field.value);
            const batch_stats = self.batchValue(stage);
            if (batch_stats.calls != 0) {
                log.debug(
                    "perf {d:.1}s batch {s} calls={} items={} ranges={} inline={} threaded={} max_workers={} avg_ms={d:.3} max_ms={d:.3} wait_avg_ms={d:.3} wait_on_max_ms={d:.3} worker_util_avg={d:.1}%",
                    .{
                        elapsed_s,
                        field.name,
                        batch_stats.calls,
                        batch_stats.items,
                        batch_stats.ranges,
                        batch_stats.inline_calls,
                        batch_stats.threaded_calls,
                        batch_stats.max_active_worker_threads,
                        millis(batch_stats.averageNs()),
                        millis(batch_stats.max_duration_ns),
                        millis(batch_stats.averageWaitNs()),
                        millis(batch_stats.wait_ns_on_max_duration),
                        batch_stats.averageWorkerUtilization() * 100.0,
                    },
                );
            }
        }
    }

    fn metricValue(self: *const EnabledRuntimePerfLog, value: Metric) u64 {
        return self.metrics[@intFromEnum(value)];
    }

    fn timingValue(self: *const EnabledRuntimePerfLog, value: Timing) TimingAggregate {
        return self.timings[@intFromEnum(value)];
    }

    fn batchValue(self: *const EnabledRuntimePerfLog, value: BatchStage) BatchAggregate {
        return self.batches[@intFromEnum(value)];
    }
};

const TimingAggregate = struct {
    count: u64 = 0,
    total_ns: u64 = 0,
    max_ns: u64 = 0,

    fn record(self: *TimingAggregate, duration_ns: u64) void {
        self.count += 1;
        self.total_ns += duration_ns;
        self.max_ns = @max(self.max_ns, duration_ns);
    }

    fn averageNs(self: TimingAggregate) u64 {
        if (self.count == 0) return 0;
        return self.total_ns / self.count;
    }
};

const BatchAggregate = struct {
    calls: u64 = 0,
    items: u64 = 0,
    ranges: u64 = 0,
    inline_calls: u64 = 0,
    threaded_calls: u64 = 0,
    total_duration_ns: u64 = 0,
    max_duration_ns: u64 = 0,
    total_wait_ns: u64 = 0,
    // Main-thread wait time on the single call whose *duration* was the
    // worst seen (not an independent max across all calls) -- lets a caller
    // tell apart "one worker got an unlucky range while siblings idled"
    // (wait_ns_on_max_duration close to max_duration_ns) from "every worker
    // was equally busy that step, just on a globally harder population"
    // (wait_ns_on_max_duration small relative to max_duration_ns).
    wait_ns_on_max_duration: u64 = 0,
    total_worker_utilization: f64 = 0,
    max_active_worker_threads: usize = 0,

    fn record(self: *BatchAggregate, stats: BatchStats) void {
        self.calls += 1;
        self.items += stats.item_count;
        self.ranges += stats.range_count;
        if (stats.ran_inline or stats.active_worker_threads == 0) {
            self.inline_calls += 1;
        } else {
            self.threaded_calls += 1;
        }
        self.total_duration_ns += stats.batch_duration_ns;
        if (stats.batch_duration_ns >= self.max_duration_ns) {
            self.max_duration_ns = stats.batch_duration_ns;
            self.wait_ns_on_max_duration = stats.main_thread_wait_ns;
        }
        self.total_wait_ns += stats.main_thread_wait_ns;
        self.total_worker_utilization += stats.worker_utilization;
        self.max_active_worker_threads = @max(self.max_active_worker_threads, stats.active_worker_threads);
    }

    fn averageNs(self: BatchAggregate) u64 {
        if (self.calls == 0) return 0;
        return self.total_duration_ns / self.calls;
    }

    fn averageWaitNs(self: BatchAggregate) u64 {
        if (self.calls == 0) return 0;
        return self.total_wait_ns / self.calls;
    }

    fn averageWorkerUtilization(self: BatchAggregate) f64 {
        if (self.calls == 0) return 0;
        return self.total_worker_utilization / @as(f64, @floatFromInt(self.calls));
    }
};

fn millis(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_ms));
}

fn seconds(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
}

fn averagePer(total: u64, count: u64) f64 {
    if (count == 0) return 0;
    return @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(count));
}

test "runtime performance log accumulates frame samples until interval" {
    if (!enabled) return error.SkipZigTest;

    var perf = RuntimePerfLog.init(0);
    perf.recordFrame(interval_ns / 2, .{
        .frame_delta_ns = 16 * std.time.ns_per_ms,
        .fixed_updates = 1,
        .hit_update_cap = false,
        .result = .submitted,
    });

    try std.testing.expectEqual(@as(u64, 1), perf.frames);
    try std.testing.expectEqual(@as(u64, 1), perf.metricValue(.submitted_frames));
    try std.testing.expectEqual(@as(u64, 1), perf.metricValue(.fixed_updates));
    try std.testing.expectEqual(@as(u64, 16 * std.time.ns_per_ms), perf.timingValue(.frame_interval).max_ns);
}

test "runtime performance log reset clears accumulators" {
    if (!enabled) return error.SkipZigTest;

    var perf = RuntimePerfLog.init(0);
    perf.recordMetric(.sdl_events, 3);
    perf.recordTiming(.app_tick, 12);
    perf.recordTiming(.gameplay_update, 8);
    perf.recordBatch(.movement, .{
        .item_count = 16,
        .range_count = 1,
        .batch_duration_ns = 100,
        .ran_inline = true,
    });
    perf.recordFrame(interval_ns / 2, .{
        .frame_delta_ns = 16 * std.time.ns_per_ms,
        .fixed_updates = 1,
        .hit_update_cap = true,
        .result = .submitted,
    });

    perf.reset(interval_ns);

    try std.testing.expectEqual(@as(u64, 0), perf.frames);
    try std.testing.expectEqual(@as(u64, 0), perf.metricValue(.sdl_events));
    try std.testing.expectEqual(@as(u64, 0), perf.timingValue(.app_tick).count);
    try std.testing.expectEqual(@as(u64, 0), perf.timingValue(.gameplay_update).count);
    try std.testing.expectEqual(@as(u64, 0), perf.batchValue(.movement).calls);
}
