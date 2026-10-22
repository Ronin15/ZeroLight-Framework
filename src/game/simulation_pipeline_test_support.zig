// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Shared private fixtures that pin a step's batch tuners, for the pipeline's tests and the
//! `production-step` bench's dispatch check. Test-only: no production path imports it.

const std = @import("std");
const AdaptiveWorkProfile = @import("../app/thread_system.zig").AdaptiveWorkProfile;
const AdaptiveWorkTuner = @import("../app/thread_system.zig").AdaptiveWorkTuner;
const SimulationPipeline = @import("simulation_pipeline.zig").SimulationPipeline;

/// Pins every pipeline batch tuner to one settled threaded `profile` that never
/// re-probes, demotes, or resets on item-count drift, so the multi-worker path runs a
/// deterministic multi-range partition. The tuners would otherwise pick the shape from
/// timing (inline below `threaded_batch_ns`). The tuners are found by walking the
/// pipeline's fields at comptime, so a tuner a system adds is pinned with it.
pub fn pinPipelineThreadedProfiles(pipeline: *SimulationPipeline, profile: AdaptiveWorkProfile) void {
    pinTunersIn(SimulationPipeline, pipeline, profile);
}

/// Pins every `AdaptiveWorkTuner` `value` holds by value: itself, or in a struct field, an
/// array element, or a set optional, at any depth. A single pointer is not owned, so it is
/// not walked.
pub fn pinTunersIn(comptime T: type, value: *T, profile: AdaptiveWorkProfile) void {
    if (T == AdaptiveWorkTuner) return pinThreadedProfile(value, profile);
    switch (@typeInfo(T)) {
        .@"struct" => |info| inline for (info.field_names, info.field_types) |name, Field| {
            if (comptime holdsTuner(Field)) pinTunersIn(Field, &@field(value, name), profile);
        },
        .array => |info| for (value) |*element| pinTunersIn(info.child, element, profile),
        .optional => |info| if (value.*) |*payload| pinTunersIn(info.child, payload, profile),
        else => {},
    }
}

// Whether a `T` holds an `AdaptiveWorkTuner` where `pinTunersIn` walks. A tuner the walk
// cannot reach fails the build: in a union (which variant is live), behind a slice or
// many-item pointer (owned heap rows), or in an error-union payload.
fn holdsTuner(comptime T: type) bool {
    @setEvalBranchQuota(100_000);
    if (T == AdaptiveWorkTuner) return true;
    return switch (@typeInfo(T)) {
        .@"struct" => |info| for (info.field_types) |Field| {
            if (holdsTuner(Field)) break true;
        } else false,
        .array => |info| holdsTuner(info.child),
        .optional => |info| holdsTuner(info.child),
        .@"union" => |info| for (info.field_types) |Field| {
            if (holdsTuner(Field)) @compileError("pinTunersIn cannot walk a tuner in union " ++ @typeName(T));
        } else false,
        .pointer => |info| switch (info.size) {
            .one => false,
            .slice, .many, .c => if (holdsTuner(info.child)) @compileError("pinTunersIn cannot walk a tuner behind " ++ @typeName(T)) else false,
        },
        .error_union => |info| if (holdsTuner(info.payload)) @compileError("pinTunersIn cannot walk a tuner in error union " ++ @typeName(T)) else false,
        else => false,
    };
}

/// Pins one tuner as `pinTunersIn` does.
pub fn pinThreadedProfile(tuner: *AdaptiveWorkTuner, profile: AdaptiveWorkProfile) void {
    tuner.config.threaded_batch_ns = 0;
    tuner.config.retune_after_settled_windows = std.math.maxInt(usize);
    tuner.config.item_count_reset_percent = std.math.maxInt(u8);
    tuner.phase = .settled;
    tuner.has_threaded_profile = true;
    tuner.current_profile = profile;
    tuner.best_profile = profile;
    tuner.candidate_profile = null;
    // Forget the pre-pin item count so the first pinned batch does not reset.
    tuner.learned_item_count = 0;
}
