// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const FramePolicy = @import("frame_pacer.zig").FramePolicy;
const InputState = @import("input.zig").InputState;
const PauseState = @import("../game/pause_state.zig").PauseState;
const RenderContext = @import("state.zig").RenderContext;
const StateHandle = @import("state.zig").StateHandle;
const StateStack = @import("state.zig").StateStack;
const StateTransitions = @import("state.zig").StateTransitions;
const UpdateContext = @import("state.zig").UpdateContext;
const TimeLoop = @import("time_loop.zig").TimeLoop;
const c = @import("../platform/sdl.zig").c;

/// PauseController owns user-initiated (.pause / P) and window-policy (hidden/minimized,
/// swapchain-blocked) pause entry/exit + source tracking.
///
/// Only enters (user or policy) and notifies via pauseActive when states.isGameplayActive().
/// This restricts PauseState overlay + onPause (e.g. GameDemoState interp sync for movement/particles)
/// exclusively to active game states installed via replaceGameplay / state_policy.gameplay.
/// Non-gameplay states (MainMenu opaque_screen, Settings modal_overlay, any future HUD pass-through)
/// never receive onPause from the pause flow, and PauseState is never pushed over them.
///
/// Commands can still be generated for app-owned pause/resume paths; the
/// gameplay-active gate here turns non-gameplay attempts into safe no-ops.
pub const PauseController = struct {
    handle: ?StateHandle = null,
    source: PauseSource = .none,
    width: f32,
    height: f32,

    const PauseSource = enum {
        none,
        user,
        window_policy,
    };

    pub fn init(width: f32, height: f32) PauseController {
        return .{
            .width = width,
            .height = height,
        };
    }

    pub fn isPaused(self: *const PauseController) bool {
        return self.handle != null;
    }

    pub fn isPolicyPaused(self: *const PauseController) bool {
        return self.handle != null and self.source == .window_policy;
    }

    pub fn reconcileWithStateStack(self: *PauseController, states: *const StateStack) void {
        const handle = self.handle orelse return;
        if (!states.contains(handle)) {
            self.handle = null;
            self.source = .none;
        }
    }

    pub fn enterUser(
        self: *PauseController,
        states: *StateStack,
        input: *InputState,
        time_loop: *TimeLoop,
        now_ns: u64,
    ) !void {
        try self.enter(.user, states, input, time_loop, now_ns);
    }

    pub fn enterPolicy(
        self: *PauseController,
        states: *StateStack,
        input: *InputState,
        time_loop: *TimeLoop,
        now_ns: u64,
    ) !void {
        try self.enter(.window_policy, states, input, time_loop, now_ns);
    }

    /// Only enters (and calls pauseActive + pushModal(PauseState)) when !isPaused() and
    /// states.isGameplayActive(). Non-gameplay tops (menus) cause early return: no notification,
    /// no overlay, no time reset, no audio duck side-effect from this path.
    fn enter(
        self: *PauseController,
        source: PauseSource,
        states: *StateStack,
        input: *InputState,
        time_loop: *TimeLoop,
        now_ns: u64,
    ) !void {
        if (self.isPaused()) return;
        if (!states.isGameplayActive()) return;

        states.pauseActive();
        input.releaseMovement();
        self.handle = try states.pushModal(PauseState, PauseState.init(self.width, self.height));
        self.source = source;
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
            self.source = .none;
            input.releaseMovement();
            states.resumeActive();
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
        if (policy.should_pause_gameplay and (states.isGameplayActive() or self.isPolicyPaused())) {
            try self.enterPolicy(states, input, time_loop, now_ns);
        } else if (self.isPolicyPaused()) {
            self.exit(states, input, time_loop, now_ns);
        }
    }
};

test "pause controller enter and exit are idempotent" {
    const std = @import("std");

    const TestingState = struct {
        pause_count: *u32,
        resume_count: *u32,

        pub fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
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

        pub fn onResume(self: *@This()) void {
            self.resume_count.* += 1;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var pause_count: u32 = 0;
    var resume_count: u32 = 0;
    var input = InputState{};
    input.setHeld(.moveRight, true);
    var time_loop = TimeLoop.init(0);
    time_loop.accumulator_ns = TimeLoop.fixed_delta_ns * 2;
    var states = StateStack.init(std.testing.allocator);
    defer states.deinit();
    _ = try states.replaceGameplay(TestingState, .{ .pause_count = &pause_count, .resume_count = &resume_count });
    var pause = PauseController.init(800, 450);

    try pause.enterUser(&states, &input, &time_loop, 10);
    try pause.enterUser(&states, &input, &time_loop, 20);

    try std.testing.expect(pause.isPaused());
    try std.testing.expect(!pause.isPolicyPaused());
    try std.testing.expectEqual(@as(usize, 2), states.len());
    try std.testing.expectEqual(@as(u32, 1), pause_count);
    try std.testing.expect(!input.isHeld(.moveRight));
    try std.testing.expectEqual(@as(u64, 10), time_loop.last_time_ns);
    try std.testing.expectEqual(@as(u64, 0), time_loop.accumulator_ns);

    pause.exit(&states, &input, &time_loop, 30);
    pause.exit(&states, &input, &time_loop, 40);

    try std.testing.expect(!pause.isPaused());
    try std.testing.expectEqual(@as(usize, 1), states.len());
    try std.testing.expectEqual(@as(u32, 1), pause_count);
    try std.testing.expectEqual(@as(u32, 1), resume_count);
    try std.testing.expectEqual(@as(u64, 30), time_loop.last_time_ns);
}

test "pause controller applies forced pause policy once" {
    const std = @import("std");

    const TestingState = struct {
        pub fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
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
    try std.testing.expect(pause.isPolicyPaused());
    try std.testing.expectEqual(@as(usize, 2), states.len());
    try std.testing.expectEqual(@as(u64, 10), time_loop.last_time_ns);
}

test "pause controller exits only policy-owned pause when window restores" {
    const std = @import("std");

    const TestingState = struct {
        pause_count: *u32,
        resume_count: *u32,

        pub fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
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

        pub fn onResume(self: *@This()) void {
            self.resume_count.* += 1;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var pause_count: u32 = 0;
    var resume_count: u32 = 0;
    var input = InputState{};
    var time_loop = TimeLoop.init(0);
    var states = StateStack.init(std.testing.allocator);
    defer states.deinit();
    _ = try states.replaceGameplay(TestingState, .{ .pause_count = &pause_count, .resume_count = &resume_count });
    var pause = PauseController.init(800, 450);

    try pause.applyWindowPolicy(.{
        .can_render = false,
        .target_frame_ns = TimeLoop.fixed_delta_ns,
        .should_pause_gameplay = true,
    }, &states, &input, &time_loop, 10);
    try std.testing.expect(pause.isPolicyPaused());

    try pause.applyWindowPolicy(.{
        .can_render = true,
        .target_frame_ns = null,
        .should_pause_gameplay = false,
    }, &states, &input, &time_loop, 20);
    try std.testing.expect(!pause.isPaused());
    try std.testing.expectEqual(@as(usize, 1), states.len());
    try std.testing.expectEqual(@as(u32, 1), pause_count);
    try std.testing.expectEqual(@as(u32, 1), resume_count);

    try pause.enterUser(&states, &input, &time_loop, 30);
    try pause.applyWindowPolicy(.{
        .can_render = true,
        .target_frame_ns = null,
        .should_pause_gameplay = false,
    }, &states, &input, &time_loop, 40);
    try std.testing.expect(pause.isPaused());
    try std.testing.expect(!pause.isPolicyPaused());
    try std.testing.expectEqual(@as(usize, 2), states.len());
}

test "pause controller clears stale handle after stack replacement" {
    const std = @import("std");

    const TestingState = struct {
        pub fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
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

    try pause.enterUser(&states, &input, &time_loop, 10);
    try std.testing.expect(pause.isPaused());

    _ = try states.replaceGameplay(TestingState, .{});
    pause.reconcileWithStateStack(&states);

    try std.testing.expect(!pause.isPaused());
    try std.testing.expectEqual(@as(usize, 1), states.len());
}

test "enterUser from opaque non-gameplay is no-op (no push, no count++, !isPaused)" {
    const std = @import("std");

    const TestingState = struct {
        pause_count: *u32,
        resume_count: *u32,

        pub fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
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

        pub fn onResume(self: *@This()) void {
            self.resume_count.* += 1;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var pause_count: u32 = 0;
    var resume_count: u32 = 0;
    var input = InputState{};
    var time_loop = TimeLoop.init(0);
    var states = StateStack.init(std.testing.allocator);
    defer states.deinit();
    // Non-gameplay top (opaque_screen policy, as used for MainMenu bootstrap).
    _ = try states.pushOpaque(TestingState, .{ .pause_count = &pause_count, .resume_count = &resume_count });
    var pause = PauseController.init(800, 450);

    try pause.enterUser(&states, &input, &time_loop, 10);
    try pause.enterUser(&states, &input, &time_loop, 20); // idempotent no-op still

    try std.testing.expect(!pause.isPaused());
    try std.testing.expect(!pause.isPolicyPaused());
    try std.testing.expectEqual(@as(usize, 1), states.len()); // no PauseState pushed
    try std.testing.expectEqual(@as(u32, 0), pause_count);
    try std.testing.expectEqual(@as(u32, 0), resume_count);
}

test "policy enter (applyWindowPolicy) is also gated by isGameplayActive (no-op from non-gameplay)" {
    const std = @import("std");

    const TestingState = struct {
        pause_count: *u32,

        pub fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
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

        pub fn onResume(self: *@This()) void {
            _ = self;
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var pause_count: u32 = 0;
    var input = InputState{};
    var time_loop = TimeLoop.init(0);
    var states = StateStack.init(std.testing.allocator);
    defer states.deinit();
    // Start as menu-like opaque non-gameplay.
    _ = try states.pushOpaque(TestingState, .{ .pause_count = &pause_count });
    var pause = PauseController.init(800, 450);

    const policy_pause = FramePolicy{
        .can_render = false,
        .target_frame_ns = TimeLoop.fixed_delta_ns,
        .should_pause_gameplay = true,
    };
    try pause.applyWindowPolicy(policy_pause, &states, &input, &time_loop, 10);
    try pause.applyWindowPolicy(policy_pause, &states, &input, &time_loop, 20);

    try std.testing.expect(!pause.isPaused());
    try std.testing.expect(!pause.isPolicyPaused());
    try std.testing.expectEqual(@as(usize, 1), states.len());
    try std.testing.expectEqual(@as(u32, 0), pause_count);

    // Now launch gameplay (replace), policy pause should take effect.
    _ = try states.replaceGameplay(TestingState, .{ .pause_count = &pause_count });
    try pause.applyWindowPolicy(policy_pause, &states, &input, &time_loop, 30);
    try std.testing.expect(pause.isPaused());
    try std.testing.expect(pause.isPolicyPaused());
    try std.testing.expectEqual(@as(usize, 2), states.len());
    try std.testing.expectEqual(@as(u32, 1), pause_count);
}
