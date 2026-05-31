// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

const std = @import("std");
const InputState = @import("input.zig").InputState;
const Renderer = @import("renderer.zig").Renderer;
const c = @import("sdl.zig").c;

pub const Scene = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (*anyopaque) void,
        handle_event: *const fn (*anyopaque, *const c.SDL_Event) void,
        update: *const fn (*anyopaque, *const InputState, f32) void,
        render: *const fn (*anyopaque, *Renderer, f32) anyerror!void,
    };

    /// Adapts a borrowed scene value. The caller owns the pointed-to scene and
    /// must keep it alive until the SceneStack removes or deinitializes it.
    pub fn from(comptime T: type, ptr: *T) Scene {
        const Adapter = struct {
            fn adapterDeinit(scene_ptr: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(scene_ptr));
                self.deinit();
            }

            fn adapterHandleEvent(scene_ptr: *anyopaque, event: *const c.SDL_Event) void {
                const self: *T = @ptrCast(@alignCast(scene_ptr));
                self.handleEvent(event);
            }

            fn adapterUpdate(scene_ptr: *anyopaque, input: *const InputState, delta_seconds: f32) void {
                const self: *T = @ptrCast(@alignCast(scene_ptr));
                self.update(input, delta_seconds);
            }

            fn adapterRender(scene_ptr: *anyopaque, renderer: *Renderer, interpolation_alpha: f32) anyerror!void {
                const self: *T = @ptrCast(@alignCast(scene_ptr));
                try self.render(renderer, interpolation_alpha);
            }

            const vtable = VTable{
                .deinit = adapterDeinit,
                .handle_event = adapterHandleEvent,
                .update = adapterUpdate,
                .render = adapterRender,
            };
        };

        return .{
            .ptr = ptr,
            .vtable = &Adapter.vtable,
        };
    }

    pub fn deinit(self: Scene) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn handleEvent(self: Scene, event: *const c.SDL_Event) void {
        self.vtable.handle_event(self.ptr, event);
    }

    pub fn update(self: Scene, input: *const InputState, delta_seconds: f32) void {
        self.vtable.update(self.ptr, input, delta_seconds);
    }

    pub fn render(self: Scene, renderer: *Renderer, interpolation_alpha: f32) !void {
        try self.vtable.render(self.ptr, renderer, interpolation_alpha);
    }
};

pub const SceneStack = struct {
    allocator: std.mem.Allocator,
    scenes: std.ArrayList(Scene) = .empty,

    pub fn init(allocator: std.mem.Allocator) SceneStack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SceneStack) void {
        while (self.scenes.pop()) |scene| {
            scene.deinit();
        }
        self.scenes.deinit(self.allocator);
    }

    pub fn push(self: *SceneStack, scene: Scene) !void {
        try self.scenes.append(self.allocator, scene);
    }

    pub fn pop(self: *SceneStack) void {
        if (self.scenes.pop()) |scene| {
            scene.deinit();
        }
    }

    pub fn replace(self: *SceneStack, scene: Scene) !void {
        try self.scenes.ensureTotalCapacity(self.allocator, 1);
        self.clear();
        self.scenes.appendAssumeCapacity(scene);
    }

    pub fn active(self: *SceneStack) ?Scene {
        if (self.scenes.items.len == 0) return null;
        return self.scenes.items[self.scenes.items.len - 1];
    }

    fn clear(self: *SceneStack) void {
        while (self.scenes.pop()) |scene| {
            scene.deinit();
        }
    }

    pub fn handleEvent(self: *SceneStack, event: *const c.SDL_Event) void {
        if (self.active()) |scene| {
            scene.handleEvent(event);
        }
    }

    pub fn update(self: *SceneStack, input: *const InputState, delta_seconds: f32) void {
        if (self.active()) |scene| {
            scene.update(input, delta_seconds);
        }
    }

    pub fn render(self: *SceneStack, renderer: *Renderer, interpolation_alpha: f32) !void {
        for (self.scenes.items) |scene| {
            try scene.render(renderer, interpolation_alpha);
        }
    }
};

test "scene stack push pop and replace maintain active scene" {
    const TestingScene = struct {
        id: u32,
        deinit_count: *u32,

        fn deinit(self: *@This()) void {
            self.deinit_count.* += 1;
        }

        fn handleEvent(self: *@This(), event: *const c.SDL_Event) void {
            _ = self;
            _ = event;
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
    };

    var deinit_count: u32 = 0;
    var first = TestingScene{ .id = 1, .deinit_count = &deinit_count };
    var second = TestingScene{ .id = 2, .deinit_count = &deinit_count };

    var stack = SceneStack.init(std.testing.allocator);
    defer stack.deinit();

    try stack.push(Scene.from(TestingScene, &first));
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&first)));

    try stack.push(Scene.from(TestingScene, &second));
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&second)));

    stack.pop();
    try std.testing.expectEqual(@as(u32, 1), deinit_count);
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&first)));

    try stack.replace(Scene.from(TestingScene, &second));
    try std.testing.expectEqual(@as(u32, 2), deinit_count);
    try std.testing.expect(stack.active().?.ptr == @as(*anyopaque, @ptrCast(&second)));
}
