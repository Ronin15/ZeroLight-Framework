// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const AudioCommandBuffer = @import("audio.zig").AudioCommandBuffer;
const FrameCommands = @import("input.zig").FrameCommands;
const InputState = @import("input.zig").InputState;
const RuntimeAssets = @import("../assets/runtime_assets.zig").RuntimeAssets;
const runtime_perf_log = @import("runtime_perf_log.zig");
const inputRouter = @import("input_router.zig");
const InputRoutingPolicy = @import("input_router.zig").InputRoutingPolicy;
const renderer_file = @import("../render/renderer.zig");
const Renderer = renderer_file.Renderer;
const UiStackOrder = renderer_file.UiStackOrder;
const TextService = @import("../render/text.zig").TextService;
const ThreadSystem = @import("thread_system.zig").ThreadSystem;
const c = @import("../platform/sdl.zig").c;

pub const StateHandle = struct {
    id: u64,
};

pub const StatePolicy = struct {
    update_below: bool = false,
    events_below: bool = false,
    render_below: bool = true,
    input_routing: InputRoutingPolicy = InputRoutingPolicy.gameplay(),
    blocks_held_gameplay_input: bool = false,
    gameplay: bool = false,
};

pub const state_policy = struct {
    pub const gameplay = StatePolicy{ .gameplay = true };
    pub const modal_overlay = StatePolicy{
        .input_routing = InputRoutingPolicy.modalUi(),
        .blocks_held_gameplay_input = true,
    };
    pub const pass_through_overlay = StatePolicy{
        .update_below = true,
        .events_below = true,
        .render_below = true,
        .input_routing = InputRoutingPolicy.passThroughOverlay(),
    };
    pub const opaque_screen = StatePolicy{
        .render_below = false,
        .input_routing = InputRoutingPolicy.opaqueScreen(),
        .blocks_held_gameplay_input = true,
    };
};

pub const TransitionApplyResult = struct {
    quit_requested: bool = false,
};

pub const UpdateContext = struct {
    input: *const InputState,
    audio: *AudioCommandBuffer,
    delta_seconds: f32,
    transitions: *StateTransitions,
    thread_system: *ThreadSystem,
    perf: runtime_perf_log.Context = .{},
};

pub const RenderContext = struct {
    renderer: *Renderer,
    runtime_assets: *RuntimeAssets,
    text_service: ?*TextService,
    interpolation_alpha: f32,
    thread_system: *ThreadSystem,
    ui_stack_order: UiStackOrder = .base,
    perf: runtime_perf_log.Context = .{},
};

pub const State = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle_event: *const fn (*anyopaque, *const c.SDL_Event, *StateTransitions) anyerror!bool,
        update: *const fn (*anyopaque, UpdateContext) anyerror!void,
        render: *const fn (*anyopaque, RenderContext) anyerror!void,
        on_pause: *const fn (*anyopaque) void,
        on_resume: *const fn (*anyopaque) void,
        destroy: *const fn (*anyopaque, std.mem.Allocator) void,
    };

    pub fn create(comptime T: type, allocator: std.mem.Allocator, value: T) !State {
        const ptr = try allocator.create(T);
        ptr.* = value;
        return fromOwnedPtr(T, ptr);
    }

    pub fn fromOwnedPtr(comptime T: type, ptr: *T) State {
        const Adapter = struct {
            fn adapterHandleEvent(state_ptr: *anyopaque, event: *const c.SDL_Event, transitions: *StateTransitions) anyerror!bool {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                return try self.handleEvent(event, transitions);
            }

            fn adapterUpdate(state_ptr: *anyopaque, context: UpdateContext) anyerror!void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                try self.update(context);
            }

            fn adapterRender(state_ptr: *anyopaque, context: RenderContext) anyerror!void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                try self.render(context);
            }

            fn adapterOnPause(state_ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                self.onPause();
            }

            fn adapterOnResume(state_ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                if (@hasDecl(T, "onResume")) {
                    self.onResume();
                }
            }

            fn adapterDestroy(state_ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                self.deinit();
                allocator.destroy(self);
            }

            const vtable = VTable{
                .handle_event = adapterHandleEvent,
                .update = adapterUpdate,
                .render = adapterRender,
                .on_pause = adapterOnPause,
                .on_resume = adapterOnResume,
                .destroy = adapterDestroy,
            };
        };

        return .{
            .ptr = ptr,
            .vtable = &Adapter.vtable,
        };
    }

    pub fn handleEvent(self: State, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        return try self.vtable.handle_event(self.ptr, event, transitions);
    }

    pub fn update(self: State, context: UpdateContext) !void {
        try self.vtable.update(self.ptr, context);
    }

    pub fn render(self: State, context: RenderContext) !void {
        try self.vtable.render(self.ptr, context);
    }

    pub fn onPause(self: State) void {
        self.vtable.on_pause(self.ptr);
    }

    pub fn onResume(self: State) void {
        self.vtable.on_resume(self.ptr);
    }

    pub fn destroy(self: State, allocator: std.mem.Allocator) void {
        self.vtable.destroy(self.ptr, allocator);
    }
};

pub const StateTransitions = struct {
    allocator: std.mem.Allocator,
    requests: std.ArrayList(Request) = .empty,

    const Request = union(enum) {
        none,
        replace: StateRequest,
        push: StateRequest,
        remove: StateHandle,
        pop,
        quit,
    };

    const StateRequest = struct {
        state: State,
        policy: StatePolicy,
    };

    pub fn init(allocator: std.mem.Allocator) StateTransitions {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StateTransitions) void {
        self.destroyPendingStates();
        self.requests.deinit(self.allocator);
    }

    pub fn clear(self: *StateTransitions) void {
        self.destroyPendingStates();
        self.requests.clearRetainingCapacity();
    }

    pub fn replace(self: *StateTransitions, comptime T: type, value: T, policy: StatePolicy) !void {
        const state = try State.create(T, self.allocator, value);
        try self.replaceOwnedState(state, policy);
    }

    pub fn replaceGameplay(self: *StateTransitions, comptime T: type, value: T) !void {
        try self.replace(T, value, state_policy.gameplay);
    }

    pub fn replaceOwnedState(self: *StateTransitions, state: State, policy: StatePolicy) !void {
        errdefer state.destroy(self.allocator);
        try self.requests.append(self.allocator, .{ .replace = .{ .state = state, .policy = policy } });
    }

    pub fn replaceOwnedGameplay(self: *StateTransitions, state: State) !void {
        try self.replaceOwnedState(state, state_policy.gameplay);
    }

    pub fn push(self: *StateTransitions, comptime T: type, value: T, policy: StatePolicy) !void {
        const state = try State.create(T, self.allocator, value);
        errdefer state.destroy(self.allocator);
        try self.requests.append(self.allocator, .{ .push = .{ .state = state, .policy = policy } });
    }

    pub fn pushModal(self: *StateTransitions, comptime T: type, value: T) !void {
        try self.push(T, value, state_policy.modal_overlay);
    }

    pub fn pushOverlay(self: *StateTransitions, comptime T: type, value: T) !void {
        try self.push(T, value, state_policy.pass_through_overlay);
    }

    pub fn pushOpaque(self: *StateTransitions, comptime T: type, value: T) !void {
        try self.push(T, value, state_policy.opaque_screen);
    }

    pub fn remove(self: *StateTransitions, handle: StateHandle) !void {
        try self.requests.append(self.allocator, .{ .remove = handle });
    }

    pub fn quit(self: *StateTransitions) !void {
        try self.requests.append(self.allocator, .quit);
    }

    pub fn pop(self: *StateTransitions) !void {
        try self.requests.append(self.allocator, .pop);
    }

    fn destroyPendingStates(self: *StateTransitions) void {
        for (self.requests.items) |request| {
            switch (request) {
                .replace, .push => |state_request| state_request.state.destroy(self.allocator),
                else => {},
            }
        }
    }
};

pub const StateStack = struct {
    allocator: std.mem.Allocator,
    states: std.ArrayList(Entry) = .empty,
    next_handle_id: u64 = 1,

    const Entry = struct {
        handle: StateHandle,
        state: State,
        policy: StatePolicy,
    };

    pub fn init(allocator: std.mem.Allocator) StateStack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *StateStack) void {
        self.destroyAllStates();
        self.states.deinit(self.allocator);
    }

    pub fn push(self: *StateStack, comptime T: type, value: T, policy: StatePolicy) !StateHandle {
        const state = try State.create(T, self.allocator, value);
        errdefer state.destroy(self.allocator);
        return try self.pushOwned(state, policy);
    }

    pub fn pushModal(self: *StateStack, comptime T: type, value: T) !StateHandle {
        return self.push(T, value, state_policy.modal_overlay);
    }

    pub fn pushOverlay(self: *StateStack, comptime T: type, value: T) !StateHandle {
        return self.push(T, value, state_policy.pass_through_overlay);
    }

    pub fn pushOpaque(self: *StateStack, comptime T: type, value: T) !StateHandle {
        return self.push(T, value, state_policy.opaque_screen);
    }

    pub fn replace(self: *StateStack, comptime T: type, value: T, policy: StatePolicy) !StateHandle {
        const state = try State.create(T, self.allocator, value);
        errdefer state.destroy(self.allocator);
        return try self.replaceOwned(state, policy);
    }

    pub fn replaceGameplay(self: *StateStack, comptime T: type, value: T) !StateHandle {
        return self.replace(T, value, state_policy.gameplay);
    }

    pub fn replaceOwnedState(self: *StateStack, state: State, policy: StatePolicy) !StateHandle {
        errdefer state.destroy(self.allocator);
        return try self.replaceOwned(state, policy);
    }

    pub fn replaceOwnedGameplay(self: *StateStack, state: State) !StateHandle {
        return self.replaceOwnedState(state, state_policy.gameplay);
    }

    pub fn remove(self: *StateStack, handle: StateHandle) bool {
        for (self.states.items, 0..) |entry, index| {
            if (entry.handle.id == handle.id) {
                const removed = self.states.orderedRemove(index);
                removed.state.destroy(self.allocator);
                return true;
            }
        }
        return false;
    }

    pub fn removeIfPresent(self: *StateStack, handle: *?StateHandle) bool {
        const value = handle.* orelse return false;
        if (!self.remove(value)) return false;
        handle.* = null;
        return true;
    }

    pub fn pop(self: *StateStack) bool {
        if (self.states.items.len == 0) return false;
        const removed = self.states.pop() orelse return false;
        removed.state.destroy(self.allocator);
        return true;
    }

    pub fn contains(self: *const StateStack, handle: StateHandle) bool {
        for (self.states.items) |entry| {
            if (entry.handle.id == handle.id) return true;
        }
        return false;
    }

    pub fn len(self: *const StateStack) usize {
        return self.states.items.len;
    }

    pub fn activeHandle(self: *const StateStack) ?StateHandle {
        if (self.states.items.len == 0) return null;
        return self.states.items[self.states.items.len - 1].handle;
    }

    pub fn active(self: *const StateStack) ?State {
        if (self.states.items.len == 0) return null;
        return self.states.items[self.states.items.len - 1].state;
    }

    pub fn inputRoutingPolicy(self: *const StateStack) InputRoutingPolicy {
        if (self.states.items.len == 0) return state_policy.gameplay.input_routing;

        var index = self.states.items.len - 1;
        var routing = self.states.items[index].policy.input_routing;
        while (true) {
            const policy = self.states.items[index].policy;
            if (policy.blocks_held_gameplay_input) {
                routing = routing.withContext(.gameplay, false);
            }
            if (!policy.events_below or index == 0) break;
            index -= 1;
        }
        return routing;
    }

    pub fn isGameplayActive(self: *const StateStack) bool {
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.states.items[index];
            if (entry.policy.gameplay) return true;
            if (!entry.policy.events_below) return false;
        }
        return false;
    }

    fn pauseRecipient(self: *StateStack) ?State {
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.states.items[index];
            if (entry.policy.gameplay) return entry.state;
            if (!entry.policy.events_below) return null;
        }
        return null;
    }

    pub fn pauseActive(self: *StateStack) void {
        if (self.pauseRecipient()) |state| {
            state.onPause();
        }
    }

    pub fn resumeActive(self: *StateStack) void {
        if (self.pauseRecipient()) |state| {
            state.onResume();
        }
    }

    pub fn handleEvent(self: *StateStack, event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.states.items[index];
            if (try entry.state.handleEvent(event, transitions)) return true;
            if (!entry.policy.events_below) return false;
        }
        return false;
    }

    pub fn update(self: *StateStack, context: UpdateContext) !void {
        if (self.states.items.len == 0) return;

        var first_updated: usize = self.states.items.len - 1;
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            first_updated = index;
            if (!self.states.items[index].policy.update_below) break;
        }

        for (self.states.items[first_updated..]) |entry| {
            try entry.state.update(context);
            if (comptime runtime_perf_log.enabled) {
                context.perf.recordMetric(.state_updates, 1);
            }
        }
    }

    pub fn render(self: *StateStack, context: RenderContext) !void {
        if (self.states.items.len == 0) return;

        var first_rendered: usize = 0;
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            first_rendered = index;
            if (!self.states.items[index].policy.render_below) break;
        }

        for (self.states.items[first_rendered..], 0..) |entry, render_offset| {
            var state_context = context;
            state_context.ui_stack_order = UiStackOrder.fromRenderOffset(render_offset);
            try entry.state.render(state_context);
            if (comptime runtime_perf_log.enabled) {
                context.perf.recordMetric(.state_renders, 1);
            }
        }
    }

    pub fn applyTransitions(self: *StateStack, transitions: *StateTransitions) !TransitionApplyResult {
        var result = TransitionApplyResult{};
        for (transitions.requests.items) |*request| {
            switch (request.*) {
                .none => {},
                .replace => |state_request| {
                    _ = try self.replaceOwned(state_request.state, state_request.policy);
                    request.* = .none;
                },
                .push => |state_request| {
                    _ = try self.pushOwned(state_request.state, state_request.policy);
                    request.* = .none;
                },
                .remove => |handle| {
                    _ = self.remove(handle);
                },
                .pop => {
                    _ = self.pop();
                    request.* = .none;
                },
                .quit => {
                    result.quit_requested = true;
                },
            }
        }
        transitions.clear();
        return result;
    }

    fn pushOwned(self: *StateStack, state: State, policy: StatePolicy) !StateHandle {
        const handle = self.nextHandle();
        try self.states.append(self.allocator, .{
            .handle = handle,
            .state = state,
            .policy = policy,
        });
        return handle;
    }

    fn replaceOwned(self: *StateStack, state: State, policy: StatePolicy) !StateHandle {
        try self.states.ensureTotalCapacity(self.allocator, 1);
        self.destroyAllStates();
        self.states.clearRetainingCapacity();
        const handle = self.nextHandle();
        self.states.appendAssumeCapacity(.{
            .handle = handle,
            .state = state,
            .policy = policy,
        });
        return handle;
    }

    fn destroyAllStates(self: *StateStack) void {
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            self.states.items[index].state.destroy(self.allocator);
        }
    }

    fn nextHandle(self: *StateStack) StateHandle {
        const handle = StateHandle{ .id = self.next_handle_id };
        self.next_handle_id += 1;
        return handle;
    }
};

fn initTestThreadSystem() !ThreadSystem {
    return try ThreadSystem.init(std.testing.allocator, std.testing.io, .{ .max_worker_threads = 0 });
}

fn testUpdateContext(
    input: *const InputState,
    audio: *AudioCommandBuffer,
    delta_seconds: f32,
    transitions: *StateTransitions,
    thread_system: *ThreadSystem,
) UpdateContext {
    return .{
        .input = input,
        .audio = audio,
        .delta_seconds = delta_seconds,
        .transitions = transitions,
        .thread_system = thread_system,
    };
}

fn testRenderContext(
    renderer: *Renderer,
    runtime_assets: *RuntimeAssets,
    interpolation_alpha: f32,
    thread_system: *ThreadSystem,
) RenderContext {
    return .{
        .renderer = renderer,
        .runtime_assets = runtime_assets,
        .text_service = null,
        .interpolation_alpha = interpolation_alpha,
        .thread_system = thread_system,
    };
}

fn testKeyEvent(event_type: u32, key: c.SDL_Keycode, repeat: bool) c.SDL_Event {
    return c.SDL_Event{ .key = .{
        .type = event_type,
        .reserved = 0,
        .timestamp = 0,
        .windowID = 0,
        .which = 0,
        .scancode = 0,
        .key = key,
        .mod = 0,
        .raw = 0,
        .down = event_type == c.SDL_EVENT_KEY_DOWN,
        .repeat = repeat,
    } };
}

test "state stack owns pushed states and destroys removed states" {
    const TestingState = struct {
        id: u32,
        deinit_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };

    var deinit_count: u32 = 0;
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    const first_handle = try stack.replaceGameplay(TestingState, .{ .id = 1, .deinit_count = &deinit_count });
    try std.testing.expectEqual(@as(usize, 1), stack.len());
    try std.testing.expectEqual(first_handle, stack.activeHandle().?);
    try std.testing.expect(stack.contains(first_handle));

    const second_handle = try stack.pushModal(TestingState, .{ .id = 2, .deinit_count = &deinit_count });
    try std.testing.expectEqual(@as(usize, 2), stack.len());

    try std.testing.expect(stack.remove(second_handle));
    try std.testing.expect(!stack.contains(second_handle));
    try std.testing.expectEqual(@as(u32, 1), deinit_count);

    _ = try stack.replaceGameplay(TestingState, .{ .id = 3, .deinit_count = &deinit_count });
    try std.testing.expect(!stack.contains(first_handle));
    try std.testing.expectEqual(@as(u32, 2), deinit_count);
}

test "state stack deinit destroys remaining states from top to bottom" {
    const TestingState = struct {
        id: u32,
        deinit_order: *std.ArrayList(u32),

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            self.deinit_order.append(std.testing.allocator, self.id) catch unreachable;
        }
    };

    var deinit_order: std.ArrayList(u32) = .empty;
    defer deinit_order.deinit(std.testing.allocator);
    {
        var stack = StateStack.init(std.testing.allocator);
        defer stack.deinit();
        _ = try stack.replaceGameplay(TestingState, .{ .id = 1, .deinit_order = &deinit_order });
        _ = try stack.pushModal(TestingState, .{ .id = 2, .deinit_order = &deinit_order });
        _ = try stack.pushOverlay(TestingState, .{ .id = 3, .deinit_order = &deinit_order });
    }

    try std.testing.expectEqualSlices(u32, &.{ 3, 2, 1 }, deinit_order.items);
}

test "state stack replace destroys existing states from top to bottom" {
    const TestingState = struct {
        id: u32,
        deinit_order: *std.ArrayList(u32),

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            self.deinit_order.append(std.testing.allocator, self.id) catch unreachable;
        }
    };

    var deinit_order: std.ArrayList(u32) = .empty;
    defer deinit_order.deinit(std.testing.allocator);
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(TestingState, .{ .id = 1, .deinit_order = &deinit_order });
    _ = try stack.pushModal(TestingState, .{ .id = 2, .deinit_order = &deinit_order });
    _ = try stack.pushOverlay(TestingState, .{ .id = 3, .deinit_order = &deinit_order });

    _ = try stack.replaceGameplay(TestingState, .{ .id = 4, .deinit_order = &deinit_order });

    try std.testing.expectEqualSlices(u32, &.{ 3, 2, 1 }, deinit_order.items);
    try std.testing.expectEqual(@as(usize, 1), stack.len());
}

test "state stack removeIfPresent clears live handles and leaves stale handles alone" {
    const TestingState = struct {
        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    var handle: ?StateHandle = try stack.pushModal(TestingState, .{});
    try std.testing.expect(stack.removeIfPresent(&handle));
    try std.testing.expect(handle == null);
    try std.testing.expectEqual(@as(usize, 0), stack.len());

    var stale_handle: ?StateHandle = .{ .id = 999 };
    try std.testing.expect(!stack.removeIfPresent(&stale_handle));
    try std.testing.expect(stale_handle != null);
}

test "modal state blocks updates below and pass-through state allows them" {
    const TestingState = struct {
        update_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = context;
            self.update_count.* += 1;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var bottom_updates: u32 = 0;
    var top_updates: u32 = 0;
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var threads = try initTestThreadSystem();
    defer threads.deinit();
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(TestingState, .{ .update_count = &bottom_updates });
    const modal_handle = try stack.pushModal(TestingState, .{ .update_count = &top_updates });
    try stack.update(testUpdateContext(&InputState{}, &audio, 0.0, &transitions, &threads));
    try std.testing.expectEqual(@as(u32, 0), bottom_updates);
    try std.testing.expectEqual(@as(u32, 1), top_updates);

    try std.testing.expect(stack.remove(modal_handle));
    _ = try stack.pushOverlay(TestingState, .{ .update_count = &top_updates });
    try stack.update(testUpdateContext(&InputState{}, &audio, 0.0, &transitions, &threads));
    try std.testing.expectEqual(@as(u32, 1), bottom_updates);
    try std.testing.expectEqual(@as(u32, 2), top_updates);
}

test "state event handling stops at consumed state" {
    const TestingState = struct {
        handled_count: *u32,
        consume: bool = false,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = event;
            _ = transitions;
            self.handled_count.* += 1;
            return self.consume;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var bottom_count: u32 = 0;
    var middle_count: u32 = 0;
    var top_count: u32 = 0;
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(TestingState, .{ .handled_count = &bottom_count });
    _ = try stack.pushOverlay(TestingState, .{ .handled_count = &middle_count });
    _ = try stack.pushOverlay(TestingState, .{ .handled_count = &top_count, .consume = true });

    const event = c.SDL_Event{ .type = c.SDL_EVENT_QUIT };
    const consumed = try stack.handleEvent(&event, &transitions);

    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(u32, 0), bottom_count);
    try std.testing.expectEqual(@as(u32, 0), middle_count);
    try std.testing.expectEqual(@as(u32, 1), top_count);
}

test "modal state blocks event handling below it" {
    const TestingState = struct {
        handled_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = event;
            _ = transitions;
            self.handled_count.* += 1;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var bottom_count: u32 = 0;
    var modal_count: u32 = 0;
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(TestingState, .{ .handled_count = &bottom_count });
    _ = try stack.pushModal(TestingState, .{ .handled_count = &modal_count });

    const event = c.SDL_Event{ .type = c.SDL_EVENT_QUIT };
    const consumed = try stack.handleEvent(&event, &transitions);

    try std.testing.expect(!consumed);
    try std.testing.expectEqual(@as(u32, 0), bottom_count);
    try std.testing.expectEqual(@as(u32, 1), modal_count);
}

test "consumed modal event suppresses routed frame command" {
    const ConsumingState = struct {
        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return true;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.pushModal(ConsumingState, .{});
    var input = InputState{};
    var commands = FrameCommands{};
    var event = testKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_ESCAPE, false);
    const routing_policy = stack.inputRoutingPolicy();
    const consumed = try stack.handleEvent(&event, &transitions);
    if (!consumed) inputRouter.routeEvent(routing_policy, &event, &input, &commands);

    try std.testing.expect(consumed);
    try std.testing.expect(!commands.wasPressed(.quit));
}

test "state stack input routing follows active state policy" {
    const TestingState = struct {
        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    // StatePolicy.gameplay flag is the source of truth for "active game state" (replaceGameplay users).
    // The other three policies never carry it.
    try std.testing.expect(state_policy.gameplay.gameplay);
    try std.testing.expect(!state_policy.modal_overlay.gameplay);
    try std.testing.expect(!state_policy.pass_through_overlay.gameplay);
    try std.testing.expect(!state_policy.opaque_screen.gameplay);

    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.moveLeft));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.pause));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.toggleDebugOverlay));
    try std.testing.expect(!stack.inputRoutingPolicy().allowsContext(.ui));

    _ = try stack.replaceGameplay(TestingState, .{});
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.moveLeft));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.pause));

    const modal_handle = try stack.pushModal(TestingState, .{});
    try std.testing.expect(!stack.inputRoutingPolicy().allowsAction(.moveLeft));
    try std.testing.expect(stack.inputRoutingPolicy().allowsContext(.ui));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.pause));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.toggleDebugOverlay));

    _ = try stack.pushOverlay(TestingState, .{});
    try std.testing.expect(!stack.inputRoutingPolicy().allowsAction(.moveLeft));
    try std.testing.expect(stack.inputRoutingPolicy().allowsContext(.ui));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.pause));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.quit));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.toggleDebugOverlay));

    var input = InputState{};
    var commands = FrameCommands{};
    var move_down = testKeyEvent(c.SDL_EVENT_KEY_DOWN, c.SDLK_A, false);
    inputRouter.routeEvent(stack.inputRoutingPolicy(), &move_down, &input, &commands);
    try std.testing.expect(!input.isHeld(.moveLeft));

    try std.testing.expect(stack.remove(modal_handle));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.moveLeft));
    try std.testing.expect(stack.inputRoutingPolicy().allowsContext(.ui));
    inputRouter.routeEvent(stack.inputRoutingPolicy(), &move_down, &input, &commands);
    try std.testing.expect(input.isHeld(.moveLeft));

    _ = try stack.pushOpaque(TestingState, .{});
    try std.testing.expect(!stack.inputRoutingPolicy().allowsAction(.moveLeft));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.pause));
    try std.testing.expect(stack.inputRoutingPolicy().allowsAction(.toggleDebugOverlay));
}

test "opaque state render policy hides states below it" {
    const TestingState = struct {
        render_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = context;
            self.render_count.* += 1;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var bottom_count: u32 = 0;
    var opaque_count: u32 = 0;
    var overlay_count: u32 = 0;
    var threads = try initTestThreadSystem();
    defer threads.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();
    var runtime_assets = RuntimeAssets.init();

    _ = try stack.replaceGameplay(TestingState, .{ .render_count = &bottom_count });
    _ = try stack.pushOpaque(TestingState, .{ .render_count = &opaque_count });
    _ = try stack.pushOverlay(TestingState, .{ .render_count = &overlay_count });

    var renderer: Renderer = undefined;
    try stack.render(testRenderContext(&renderer, &runtime_assets, 0.0, &threads));

    try std.testing.expectEqual(@as(u32, 0), bottom_count);
    try std.testing.expectEqual(@as(u32, 1), opaque_count);
    try std.testing.expectEqual(@as(u32, 1), overlay_count);
}

test "transition requests apply after dispatch and preserve FIFO order" {
    const TestingState = struct {
        id: u32,
        render_order: *std.ArrayList(u32),

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = context;
            self.render_order.append(std.testing.allocator, self.id) catch unreachable;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var render_order: std.ArrayList(u32) = .empty;
    defer render_order.deinit(std.testing.allocator);
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var threads = try initTestThreadSystem();
    defer threads.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();
    var runtime_assets = RuntimeAssets.init();

    _ = try stack.replaceGameplay(TestingState, .{ .id = 1, .render_order = &render_order });
    try transitions.pushModal(TestingState, .{ .id = 2, .render_order = &render_order });
    try transitions.pushOverlay(TestingState, .{ .id = 3, .render_order = &render_order });
    const result = try stack.applyTransitions(&transitions);

    try std.testing.expect(!result.quit_requested);
    try std.testing.expectEqual(@as(usize, 3), stack.len());
    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);

    var renderer: Renderer = undefined;
    try stack.render(testRenderContext(&renderer, &runtime_assets, 0.0, &threads));
    try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, render_order.items);
}

test "queued transition from update waits until applyTransitions" {
    const QueuingState = struct {
        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            try context.transitions.pushModal(@This(), .{});
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var threads = try initTestThreadSystem();
    defer threads.deinit();
    var audio = AudioCommandBuffer.init(std.testing.allocator, 8);
    defer audio.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(QueuingState, .{});
    try stack.update(testUpdateContext(&InputState{}, &audio, 0.0, &transitions, &threads));

    try std.testing.expectEqual(@as(usize, 1), stack.len());
    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);

    _ = try stack.applyTransitions(&transitions);

    try std.testing.expectEqual(@as(usize, 2), stack.len());
    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);
}

test "queued transition from handleEvent waits until applyTransitions" {
    const QueuingState = struct {
        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            try transitions.pushModal(@This(), .{});
            return true;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(QueuingState, .{});
    const event = c.SDL_Event{ .type = c.SDL_EVENT_QUIT };
    const consumed = try stack.handleEvent(&event, &transitions);

    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(usize, 1), stack.len());
    try std.testing.expectEqual(@as(usize, 1), transitions.requests.items.len);

    _ = try stack.applyTransitions(&transitions);

    try std.testing.expectEqual(@as(usize, 2), stack.len());
    try std.testing.expectEqual(@as(usize, 0), transitions.requests.items.len);
}

test "stale duplicate and remove after replace transitions are no-ops" {
    const TestingState = struct {
        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    const stale_handle = StateHandle{ .id = 999 };
    const live_handle = try stack.replaceGameplay(TestingState, .{});

    try transitions.remove(stale_handle);
    try transitions.remove(stale_handle);
    try transitions.replaceGameplay(TestingState, .{});
    try transitions.remove(live_handle);
    const result = try stack.applyTransitions(&transitions);

    try std.testing.expect(!result.quit_requested);
    try std.testing.expectEqual(@as(usize, 1), stack.len());
    try std.testing.expect(!stack.contains(live_handle));
}

test "transition queue destroys unapplied owned states" {
    const TestingState = struct {
        deinit_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };

    var deinit_count: u32 = 0;
    {
        var transitions = StateTransitions.init(std.testing.allocator);
        defer transitions.deinit();
        try transitions.pushModal(TestingState, .{ .deinit_count = &deinit_count });
        try transitions.replaceGameplay(TestingState, .{ .deinit_count = &deinit_count });
    }

    try std.testing.expectEqual(@as(u32, 2), deinit_count);
}

test "owned gameplay transition destroys state when enqueue fails" {
    const TestingState = struct {
        deinit_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    const allocator = failing.allocator();
    var transitions = StateTransitions.init(allocator);
    defer transitions.deinit();

    var deinit_count: u32 = 0;
    const state = try State.create(TestingState, allocator, .{ .deinit_count = &deinit_count });
    try std.testing.expectError(error.OutOfMemory, transitions.replaceOwnedGameplay(state));
    try std.testing.expectEqual(@as(u32, 1), deinit_count);
}

test "quit transition reports through apply result" {
    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    try transitions.quit();
    const result = try stack.applyTransitions(&transitions);

    try std.testing.expect(result.quit_requested);
}

test "pop transition removes and destroys the current top state" {
    const TestingState = struct {
        id: u32,
        deinit_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }
    };

    var deinit_count: u32 = 0;
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(TestingState, .{ .id = 1, .deinit_count = &deinit_count });
    _ = try stack.pushModal(TestingState, .{ .id = 2, .deinit_count = &deinit_count });
    try std.testing.expectEqual(@as(usize, 2), stack.len());

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    try transitions.pop();
    const result = try stack.applyTransitions(&transitions);

    try std.testing.expect(!result.quit_requested);
    try std.testing.expectEqual(@as(usize, 1), stack.len());
    try std.testing.expectEqual(@as(u32, 1), deinit_count);
}

test "pop on empty stack is safe and no-op" {
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    var transitions = StateTransitions.init(std.testing.allocator);
    defer transitions.deinit();

    try transitions.pop();
    const result = try stack.applyTransitions(&transitions);

    try std.testing.expect(!result.quit_requested);
    try std.testing.expectEqual(@as(usize, 0), stack.len());
}

test "isGameplayActive and pauseActive/resumeActive target the gameplay policy entry (not literal top) even with pass-through overlay above" {
    const TestingState = struct {
        pause_count: *u32,
        resume_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            self.pause_count.* += 1;
        }

        fn onResume(self: *@This()) void {
            self.resume_count.* += 1;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var game_pause: u32 = 0;
    var game_resume: u32 = 0;
    var overlay_pause: u32 = 0;
    var overlay_resume: u32 = 0;
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(TestingState, .{ .pause_count = &game_pause, .resume_count = &game_resume });
    _ = try stack.pushOverlay(TestingState, .{ .pause_count = &overlay_pause, .resume_count = &overlay_resume });

    try std.testing.expect(stack.isGameplayActive());
    try std.testing.expectEqual(@as(usize, 2), stack.len());
    // Literal top is the pass-through overlay (which has gameplay=false), but recipient is the lower gameplay entry.
    stack.pauseActive();
    try std.testing.expectEqual(@as(u32, 1), game_pause);
    try std.testing.expectEqual(@as(u32, 0), overlay_pause);

    stack.resumeActive();
    try std.testing.expectEqual(@as(u32, 1), game_resume);
    try std.testing.expectEqual(@as(u32, 0), overlay_resume);
}

test "opaque non-gameplay top yields isGameplayActive false and pauseActive delivers no notification" {
    const TestingState = struct {
        pause_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            self.pause_count.* += 1;
        }

        fn onResume(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var menu_pause: u32 = 0;
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    // Simulate non-gameplay opaque top (e.g. MainMenu bootstrap via opaque_screen policy, or replaceOpaque).
    // No replaceGameplay entry exists, so isGameplayActive is false and pauseActive is a no-op (no onPause delivered to menu).
    _ = try stack.pushOpaque(TestingState, .{ .pause_count = &menu_pause });

    try std.testing.expect(!stack.isGameplayActive());
    try std.testing.expectEqual(@as(usize, 1), stack.len());

    stack.pauseActive();
    try std.testing.expectEqual(@as(u32, 0), menu_pause);

    stack.resumeActive();
    // (resume also no-op, no crash)
}

test "opaque non-gameplay state above gameplay blocks pause recipient" {
    const TestingState = struct {
        pause_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event, transitions: *StateTransitions) !bool {
            _ = self;
            _ = event;
            _ = transitions;
            return false;
        }

        fn update(self: *@This(), context: UpdateContext) !void {
            _ = self;
            _ = context;
        }

        fn render(self: *@This(), context: RenderContext) !void {
            _ = self;
            _ = context;
        }

        fn onPause(self: *@This()) void {
            self.pause_count.* += 1;
        }

        fn onResume(self: *@This()) void {
            _ = self;
        }

        fn deinit(self: *@This()) void {
            _ = self;
        }
    };

    var game_pause: u32 = 0;
    var opaque_pause: u32 = 0;
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(TestingState, .{ .pause_count = &game_pause });
    _ = try stack.pushOpaque(TestingState, .{ .pause_count = &opaque_pause });

    try std.testing.expect(!stack.isGameplayActive());
    stack.pauseActive();
    try std.testing.expectEqual(@as(u32, 0), game_pause);
    try std.testing.expectEqual(@as(u32, 0), opaque_pause);
}
