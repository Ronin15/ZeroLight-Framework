// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const InputState = @import("input.zig").InputState;
const Renderer = @import("renderer.zig").Renderer;
const c = @import("sdl.zig").c;

pub const StateHandle = struct {
    id: u64,
};

pub const StatePolicy = struct {
    update_below: bool = false,
    events_below: bool = false,
    render_below: bool = true,
};

pub const state_policy = struct {
    pub const gameplay = StatePolicy{};
    pub const modal_overlay = StatePolicy{};
    pub const pass_through_overlay = StatePolicy{
        .update_below = true,
        .events_below = true,
        .render_below = true,
    };
    pub const opaque_screen = StatePolicy{
        .render_below = false,
    };
};

pub const State = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        handle_event: *const fn (*anyopaque, *const c.SDL_Event) bool,
        update: *const fn (*anyopaque, *const InputState, f32) void,
        render: *const fn (*anyopaque, *Renderer, f32) anyerror!void,
        on_pause: *const fn (*anyopaque) void,
    };

    /// Adapts a borrowed state value. The caller owns the pointed-to state and
    /// must keep it alive until the StateStack removes it.
    pub fn from(comptime T: type, ptr: *T) State {
        const Adapter = struct {
            fn adapterHandleEvent(state_ptr: *anyopaque, event: *const c.SDL_Event) bool {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                return self.handleEvent(event);
            }

            fn adapterUpdate(state_ptr: *anyopaque, input: *const InputState, delta_seconds: f32) void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                self.update(input, delta_seconds);
            }

            fn adapterRender(state_ptr: *anyopaque, renderer: *Renderer, interpolation_alpha: f32) anyerror!void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                try self.render(renderer, interpolation_alpha);
            }

            fn adapterOnPause(state_ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(state_ptr));
                self.onPause();
            }

            const vtable = VTable{
                .handle_event = adapterHandleEvent,
                .update = adapterUpdate,
                .render = adapterRender,
                .on_pause = adapterOnPause,
            };
        };

        return .{
            .ptr = ptr,
            .vtable = &Adapter.vtable,
        };
    }

    pub fn handleEvent(self: State, event: *const c.SDL_Event) bool {
        return self.vtable.handle_event(self.ptr, event);
    }

    pub fn update(self: State, input: *const InputState, delta_seconds: f32) void {
        self.vtable.update(self.ptr, input, delta_seconds);
    }

    pub fn render(self: State, renderer: *Renderer, interpolation_alpha: f32) !void {
        try self.vtable.render(self.ptr, renderer, interpolation_alpha);
    }

    pub fn onPause(self: State) void {
        self.vtable.on_pause(self.ptr);
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
        self.states.deinit(self.allocator);
    }

    pub fn push(self: *StateStack, state: State, policy: StatePolicy) !StateHandle {
        const handle = self.nextHandle();
        try self.states.append(self.allocator, .{
            .handle = handle,
            .state = state,
            .policy = policy,
        });
        return handle;
    }

    pub fn pushModal(self: *StateStack, state: State) !StateHandle {
        return self.push(state, state_policy.modal_overlay);
    }

    pub fn pushOverlay(self: *StateStack, state: State) !StateHandle {
        return self.push(state, state_policy.pass_through_overlay);
    }

    pub fn pushOpaque(self: *StateStack, state: State) !StateHandle {
        return self.push(state, state_policy.opaque_screen);
    }

    pub fn replace(self: *StateStack, state: State, policy: StatePolicy) !StateHandle {
        try self.states.ensureTotalCapacity(self.allocator, 1);
        self.states.clearRetainingCapacity();
        const handle = self.nextHandle();
        self.states.appendAssumeCapacity(.{
            .handle = handle,
            .state = state,
            .policy = policy,
        });
        return handle;
    }

    pub fn replaceGameplay(self: *StateStack, state: State) !StateHandle {
        return self.replace(state, state_policy.gameplay);
    }

    pub fn remove(self: *StateStack, handle: StateHandle) bool {
        for (self.states.items, 0..) |entry, index| {
            if (entry.handle.id == handle.id) {
                _ = self.states.orderedRemove(index);
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

    pub fn pauseActive(self: *StateStack) void {
        if (self.active()) |state| {
            state.onPause();
        }
    }

    pub fn handleEvent(self: *StateStack, event: *const c.SDL_Event) void {
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.states.items[index];
            if (entry.state.handleEvent(event)) return;
            if (!entry.policy.events_below) return;
        }
    }

    pub fn update(self: *StateStack, input: *const InputState, delta_seconds: f32) void {
        if (self.states.items.len == 0) return;

        var first_updated: usize = self.states.items.len - 1;
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            first_updated = index;
            if (!self.states.items[index].policy.update_below) break;
        }

        for (self.states.items[first_updated..]) |entry| {
            entry.state.update(input, delta_seconds);
        }
    }

    pub fn render(self: *StateStack, renderer: *Renderer, interpolation_alpha: f32) !void {
        if (self.states.items.len == 0) return;

        var first_rendered: usize = 0;
        var index = self.states.items.len;
        while (index > 0) {
            index -= 1;
            first_rendered = index;
            if (!self.states.items[index].policy.render_below) break;
        }

        for (self.states.items[first_rendered..]) |entry| {
            try entry.state.render(renderer, interpolation_alpha);
        }
    }

    fn nextHandle(self: *StateStack) StateHandle {
        const handle = StateHandle{ .id = self.next_handle_id };
        self.next_handle_id += 1;
        return handle;
    }
};

test "state stack keeps borrowed state ownership with handles" {
    const TestingState = struct {
        id: u32,
        update_count: u32 = 0,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event) bool {
            _ = self;
            _ = event;
            return false;
        }

        fn update(self: *@This(), input: *const InputState, delta_seconds: f32) void {
            _ = input;
            _ = delta_seconds;
            self.update_count += 1;
        }

        fn render(self: *@This(), renderer: *Renderer, interpolation_alpha: f32) !void {
            _ = self;
            _ = renderer;
            _ = interpolation_alpha;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }
    };

    var first = TestingState{ .id = 1 };
    var second = TestingState{ .id = 2 };

    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    const first_handle = try stack.replaceGameplay(State.from(TestingState, &first));
    try std.testing.expectEqual(@as(usize, 1), stack.len());
    try std.testing.expectEqual(first_handle, stack.activeHandle().?);
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&first)));
    try std.testing.expect(stack.contains(first_handle));

    const second_handle = try stack.pushModal(State.from(TestingState, &second));
    try std.testing.expectEqual(@as(usize, 2), stack.len());
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&second)));

    try std.testing.expect(stack.remove(second_handle));
    try std.testing.expect(!stack.contains(second_handle));
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&first)));

    _ = try stack.replaceGameplay(State.from(TestingState, &second));
    try std.testing.expect(!stack.contains(first_handle));
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&second)));
}

test "state stack removeIfPresent clears live handles and leaves stale handles alone" {
    const TestingState = struct {
        fn handleEvent(self: *@This(), event: *const c.SDL_Event) bool {
            _ = self;
            _ = event;
            return false;
        }

        fn update(self: *@This(), input: *const InputState, delta_seconds: f32) void {
            _ = self;
            _ = input;
            _ = delta_seconds;
        }

        fn render(self: *@This(), renderer: *Renderer, interpolation_alpha: f32) !void {
            _ = self;
            _ = renderer;
            _ = interpolation_alpha;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }
    };

    var state = TestingState{};
    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    var handle: ?StateHandle = try stack.pushModal(State.from(TestingState, &state));
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

        fn handleEvent(self: *@This(), event: *const c.SDL_Event) bool {
            _ = self;
            _ = event;
            return false;
        }

        fn update(self: *@This(), input: *const InputState, delta_seconds: f32) void {
            _ = input;
            _ = delta_seconds;
            self.update_count.* += 1;
        }

        fn render(self: *@This(), renderer: *Renderer, interpolation_alpha: f32) !void {
            _ = self;
            _ = renderer;
            _ = interpolation_alpha;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }
    };

    var bottom_updates: u32 = 0;
    var top_updates: u32 = 0;
    var bottom = TestingState{ .update_count = &bottom_updates };
    var top = TestingState{ .update_count = &top_updates };

    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(State.from(TestingState, &bottom));
    const modal_handle = try stack.pushModal(State.from(TestingState, &top));
    stack.update(&InputState{}, 0.0);
    try std.testing.expectEqual(@as(u32, 0), bottom_updates);
    try std.testing.expectEqual(@as(u32, 1), top_updates);

    try std.testing.expect(stack.remove(modal_handle));
    _ = try stack.pushOverlay(State.from(TestingState, &top));
    stack.update(&InputState{}, 0.0);
    try std.testing.expectEqual(@as(u32, 1), bottom_updates);
    try std.testing.expectEqual(@as(u32, 2), top_updates);
}

test "state event handling stops at consumed or modal state" {
    const TestingState = struct {
        handled_count: *u32,
        consume: bool = false,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event) bool {
            _ = event;
            self.handled_count.* += 1;
            return self.consume;
        }

        fn update(self: *@This(), input: *const InputState, delta_seconds: f32) void {
            _ = self;
            _ = input;
            _ = delta_seconds;
        }

        fn render(self: *@This(), renderer: *Renderer, interpolation_alpha: f32) !void {
            _ = self;
            _ = renderer;
            _ = interpolation_alpha;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }
    };

    var bottom_count: u32 = 0;
    var middle_count: u32 = 0;
    var top_count: u32 = 0;
    var bottom = TestingState{ .handled_count = &bottom_count };
    var middle = TestingState{ .handled_count = &middle_count };
    var top = TestingState{ .handled_count = &top_count, .consume = true };

    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(State.from(TestingState, &bottom));
    _ = try stack.pushOverlay(State.from(TestingState, &middle));
    _ = try stack.pushOverlay(State.from(TestingState, &top));

    const event = c.SDL_Event{ .type = c.SDL_EVENT_QUIT };
    stack.handleEvent(&event);

    try std.testing.expectEqual(@as(u32, 0), bottom_count);
    try std.testing.expectEqual(@as(u32, 0), middle_count);
    try std.testing.expectEqual(@as(u32, 1), top_count);
}

test "opaque state render policy hides states below it" {
    const TestingState = struct {
        render_count: *u32,

        fn handleEvent(self: *@This(), event: *const c.SDL_Event) bool {
            _ = self;
            _ = event;
            return false;
        }

        fn update(self: *@This(), input: *const InputState, delta_seconds: f32) void {
            _ = self;
            _ = input;
            _ = delta_seconds;
        }

        fn render(self: *@This(), renderer: *Renderer, interpolation_alpha: f32) !void {
            _ = renderer;
            _ = interpolation_alpha;
            self.render_count.* += 1;
        }

        fn onPause(self: *@This()) void {
            _ = self;
        }
    };

    var bottom_count: u32 = 0;
    var opaque_count: u32 = 0;
    var overlay_count: u32 = 0;
    var bottom = TestingState{ .render_count = &bottom_count };
    var opaque_state = TestingState{ .render_count = &opaque_count };
    var overlay = TestingState{ .render_count = &overlay_count };

    var stack = StateStack.init(std.testing.allocator);
    defer stack.deinit();

    _ = try stack.replaceGameplay(State.from(TestingState, &bottom));
    _ = try stack.pushOpaque(State.from(TestingState, &opaque_state));
    _ = try stack.pushOverlay(State.from(TestingState, &overlay));

    var renderer: Renderer = undefined;
    try stack.render(&renderer, 0.0);

    try std.testing.expectEqual(@as(u32, 0), bottom_count);
    try std.testing.expectEqual(@as(u32, 1), opaque_count);
    try std.testing.expectEqual(@as(u32, 1), overlay_count);
}
