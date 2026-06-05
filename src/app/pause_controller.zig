// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const FramePolicy = @import("frame_pacer.zig").FramePolicy;
const InputState = @import("input.zig").InputState;
const PauseState = @import("../game/pause_state.zig").PauseState;
const state_mod = @import("state.zig");
const RenderContext = state_mod.RenderContext;
const StateHandle = @import("state.zig").StateHandle;
const StateStack = @import("state.zig").StateStack;
const StateTransitions = state_mod.StateTransitions;
const UpdateContext = state_mod.UpdateContext;
const TimeLoop = @import("time_loop.zig").TimeLoop;

pub const PauseController = struct {
    handle: ?StateHandle = null,
    width: f32,
    height: f32,

    pub fn init(width: f32, height: f32) PauseController {
        return .{
            .width = width,
            .height = height,
        };
    }

    pub fn isPaused(self: *const PauseController) bool {
        return self.handle != null;
    }

    pub fn reconcileWithStateStack(self: *PauseController, states: *const StateStack) void {
        const handle = self.handle orelse return;
        if (!states.contains(handle)) {
            self.handle = null;
        }
    }

    pub fn enter(
        self: *PauseController,
        states: *StateStack,
        input: *InputState,
        time_loop: *TimeLoop,
        now_ns: u64,
    ) !void {
        if (self.isPaused()) return;

        states.pauseActive();
        input.releaseMovement();
        self.handle = try states.pushModal(PauseState, PauseState.init(self.width, self.height));
        time_loop.reset(now_ns);
    }

    pub fn exit(
        self: *PauseController,
        states: *StateStack,
        input: *InputState,
        time_loop: *TimeLoop,
        now_ns: u64,
    ) void {
        if (states.removeIfPresent(&self.handle)) {
            input.releaseMovement();
            states.pauseActive();
            time_loop.reset(now_ns);
        }
    }

    pub fn applyWindowPolicy(
        self: *PauseController,
        policy: FramePolicy,
        states: *StateStack,
        input: *InputState,
        time_loop: *TimeLoop,
        now_ns: u64,
    ) !void {
        if (policy.should_pause_gameplay) {
            try self.enter(states, input, time_loop, now_ns);
        }
    }
};

test "pause controller enter and exit are idempotent" {
    const std = @import("std");

    const TestingState = struct {
        pause_count: *u32,

        pub fn handleEvent(self: *@This(), event: *const @import("../platform/sdl.zig").c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        pub fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        pub fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        pub fn onPause(self: *@This()) void {
            self.pause_count.* += 1;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var pause_count: u32 = 0;
    var input = InputState{};
    input.setHeld(.moveRight, true);
    var time_loop = TimeLoop.init(0);
    time_loop.accumulator_ns = TimeLoop.fixed_delta_ns * 2;
    var states = StateStack.init(std.testing.allocator);
    defer states.deinit();
    _ = try states.replaceGameplay(TestingState, .{ .pause_count = &pause_count });
    var pause = PauseController.init(800, 450);

    try pause.enter(&states, &input, &time_loop, 10);
    try pause.enter(&states, &input, &time_loop, 20);

    try std.testing.expect(pause.isPaused());
    try std.testing.expectEqual(@as(usize, 2), states.len());
    try std.testing.expectEqual(@as(u32, 1), pause_count);
    try std.testing.expect(!input.isHeld(.moveRight));
    try std.testing.expectEqual(@as(u64, 10), time_loop.last_time_ns);
    try std.testing.expectEqual(@as(u64, 0), time_loop.accumulator_ns);

    pause.exit(&states, &input, &time_loop, 30);
    pause.exit(&states, &input, &time_loop, 40);

    try std.testing.expect(!pause.isPaused());
    try std.testing.expectEqual(@as(usize, 1), states.len());
    try std.testing.expectEqual(@as(u32, 2), pause_count);
    try std.testing.expectEqual(@as(u64, 30), time_loop.last_time_ns);
}

test "pause controller applies forced pause policy once" {
    const std = @import("std");

    const TestingState = struct {
        pub fn handleEvent(self: *@This(), event: *const @import("../platform/sdl.zig").c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        pub fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        pub fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        pub fn onPause(self: *@This()) void {
            _ = self;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var input = InputState{};
    var time_loop = TimeLoop.init(0);
    var states = StateStack.init(std.testing.allocator);
    defer states.deinit();
    _ = try states.replaceGameplay(TestingState, .{});
    var pause = PauseController.init(800, 450);
    const policy = FramePolicy{
        .can_render = false,
        .target_frame_ns = TimeLoop.fixed_delta_ns,
        .should_pause_gameplay = true,
    };

    try pause.applyWindowPolicy(policy, &states, &input, &time_loop, 10);
    try pause.applyWindowPolicy(policy, &states, &input, &time_loop, 20);

    try std.testing.expect(pause.isPaused());
    try std.testing.expectEqual(@as(usize, 2), states.len());
    try std.testing.expectEqual(@as(u64, 10), time_loop.last_time_ns);
}

test "pause controller clears stale handle after stack replacement" {
    const std = @import("std");

    const TestingState = struct {
        pub fn handleEvent(self: *@This(), event: *const @import("../platform/sdl.zig").c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        pub fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        pub fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        pub fn onPause(self: *@This()) void {
            _ = self;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var input = InputState{};
    var time_loop = TimeLoop.init(0);
    var states = StateStack.init(std.testing.allocator);
    defer states.deinit();
    _ = try states.replaceGameplay(TestingState, .{});
    var pause = PauseController.init(800, 450);

    try pause.enter(&states, &input, &time_loop, 10);
    try std.testing.expect(pause.isPaused());

    _ = try states.replaceGameplay(TestingState, .{});
    pause.reconcileWithStateStack(&states);

    try std.testing.expect(!pause.isPaused());
    try std.testing.expectEqual(@as(usize, 1), states.len());
}
