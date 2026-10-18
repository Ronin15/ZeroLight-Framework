// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! State-stack test helpers: install test states through the production queue and apply.

const state = @import("state.zig");
const StateStack = state.StateStack;
const StateTransitions = state.StateTransitions;
const StateHandle = state.StateHandle;
const StatePolicy = state.StatePolicy;

/// Pushes `value` onto `stack` under `policy` through a queued push and its apply; returns
/// its handle.
pub fn pushState(stack: *StateStack, comptime T: type, value: T, policy: StatePolicy) !StateHandle {
    var transitions = StateTransitions.init(stack.allocator);
    defer transitions.deinit();
    try transitions.push(T, value, policy);
    _ = try stack.applyTransitions(&transitions);
    return topHandle(stack);
}

/// Replaces `stack` with `value` under `policy` through a queued replace and its apply;
/// returns its handle.
pub fn replaceState(stack: *StateStack, comptime T: type, value: T, policy: StatePolicy) !StateHandle {
    var transitions = StateTransitions.init(stack.allocator);
    defer transitions.deinit();
    try transitions.replace(T, value, policy);
    _ = try stack.applyTransitions(&transitions);
    return topHandle(stack);
}

fn topHandle(stack: *const StateStack) StateHandle {
    return stack.states.items[stack.states.items.len - 1].handle;
}
