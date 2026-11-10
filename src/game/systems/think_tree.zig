// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! One B+ tree per think group. Leaves hold sorted `u128` keys, 64 per leaf, and
//! link to the next leaf. Branches hold 16 children. A node stays at least half
//! full except a group's root. Workers edit a group only through a private node grant.

const std = @import("std");
const band_residue_n = @import("../simulation_scope.zig").band_residue_n;

pub const leaf_width: u8 = 64;
pub const leaf_min: u8 = leaf_width / 2;
pub const branch_width: u8 = 16;
pub const branch_min: u8 = branch_width / 2;
pub const node_absent: u32 = std.math.maxInt(u32);

pub const ThinkLeaf = struct {
    keys: [leaf_width]u128 = undefined,
    len: u8 = 0,
    next: u32 = node_absent,
    parent: u32 = node_absent,
    parent_slot: u8 = 0,
    live: bool = false,
    touch: u32 = 0,
};

pub const ThinkBranch = struct {
    /// `sep[i]` is the first key of `child[i + 1]`.
    sep: [branch_width - 1]u128 = undefined,
    child: [branch_width]u32 = undefined,
    len: u8 = 0,
    leaf_children: bool = true,
    parent: u32 = node_absent,
    parent_slot: u8 = 0,
    live: bool = false,
};

pub const ThinkGroup = struct {
    root: u32 = node_absent,
    root_is_leaf: bool = true,
    head: u32 = node_absent,
    count: u32 = 0,
};

pub const TreePools = struct {
    leaves: []ThinkLeaf,
    branches: []ThinkBranch,
};

/// Fresh node ids this range may bump, and the ids it frees or touches. Cursors are this range's.
pub const NodeGrant = struct {
    leaf_ids: []const u32,
    branch_ids: []const u32,
    leaf_cursor: *u32,
    branch_cursor: *u32,
    freed_leaves: []u32,
    freed_leaf_count: *u32,
    freed_branches: []u32,
    freed_branch_count: *u32,
    touched: []u32,
    touched_count: *u32,
    touch_epoch: u32,

    fn allocLeaf(self: *NodeGrant, pools: *TreePools) u32 {
        std.debug.assert(self.leaf_cursor.* < self.leaf_ids.len);
        const id = self.leaf_ids[self.leaf_cursor.*];
        self.leaf_cursor.* += 1;
        pools.leaves[id] = .{ .live = true };
        return id;
    }

    fn allocBranch(self: *NodeGrant, pools: *TreePools) u32 {
        std.debug.assert(self.branch_cursor.* < self.branch_ids.len);
        const id = self.branch_ids[self.branch_cursor.*];
        self.branch_cursor.* += 1;
        pools.branches[id] = .{ .live = true };
        return id;
    }

    fn freeLeaf(self: *NodeGrant, pools: *TreePools, id: u32) void {
        pools.leaves[id].live = false;
        std.debug.assert(self.freed_leaf_count.* < self.freed_leaves.len);
        self.freed_leaves[self.freed_leaf_count.*] = id;
        self.freed_leaf_count.* += 1;
    }

    fn freeBranch(self: *NodeGrant, pools: *TreePools, id: u32) void {
        pools.branches[id].live = false;
        std.debug.assert(self.freed_branch_count.* < self.freed_branches.len);
        self.freed_branches[self.freed_branch_count.*] = id;
        self.freed_branch_count.* += 1;
    }

    fn touchLeaf(self: *NodeGrant, pools: *TreePools, id: u32) void {
        const leaf = &pools.leaves[id];
        if (leaf.touch == self.touch_epoch) return;
        leaf.touch = self.touch_epoch;
        std.debug.assert(self.touched_count.* < self.touched.len);
        self.touched[self.touched_count.*] = id;
        self.touched_count.* += 1;
    }
};

pub fn groupOf(key: u128) u16 {
    if ((key >> 127) == 0) return 0;
    const band: u16 = @intCast((key >> 124) & 0x7);
    const residue: u16 = @intCast((key >> 118) & 0x3f);
    return 1 + band * @as(u16, band_residue_n) + residue;
}

pub fn entityOf(key: u128) u32 {
    return @truncate(key);
}

pub fn insertKey(pools: *TreePools, group: *ThinkGroup, key: u128, grant: *NodeGrant) void {
    if (group.root == node_absent) {
        const id = grant.allocLeaf(pools);
        pools.leaves[id].keys[0] = key;
        pools.leaves[id].len = 1;
        grant.touchLeaf(pools, id);
        group.root = id;
        group.root_is_leaf = true;
        group.head = id;
        group.count = 1;
        return;
    }
    const leaf = findLeaf(pools, group, key);
    std.debug.assert(leafSlot(pools, leaf, key) == null);
    leafInsert(pools, group, leaf, key, grant);
    group.count += 1;
}

pub fn deleteKey(pools: *TreePools, group: *ThinkGroup, key: u128, grant: *NodeGrant) void {
    std.debug.assert(group.root != node_absent);
    const leaf = findLeaf(pools, group, key);
    const slot = leafSlot(pools, leaf, key) orelse unreachable; // lint:allow catch-unreachable: the edit's old key was read from this leaf
    leafRemove(pools, group, leaf, slot, grant);
    group.count -= 1;
}

fn findLeaf(pools: *const TreePools, group: *const ThinkGroup, key: u128) u32 {
    if (group.root_is_leaf) return group.root;
    var node = group.root;
    while (true) {
        const branch = &pools.branches[node];
        var child: usize = 0;
        while (child + 1 < branch.len and key >= branch.sep[child]) child += 1;
        if (branch.leaf_children) return branch.child[child];
        node = branch.child[child];
    }
}

fn leafSlot(pools: *const TreePools, leaf: u32, key: u128) ?u8 {
    const node = &pools.leaves[leaf];
    var slot: usize = 0;
    while (slot < node.len and node.keys[slot] < key) slot += 1;
    if (slot < node.len and node.keys[slot] == key) return @intCast(slot);
    return null;
}

fn leafInsert(pools: *TreePools, group: *ThinkGroup, leaf: u32, key: u128, grant: *NodeGrant) void {
    const node = &pools.leaves[leaf];
    if (node.len < leaf_width) {
        var slot: usize = 0;
        while (slot < node.len and node.keys[slot] < key) slot += 1;
        var index = node.len;
        while (index > slot) : (index -= 1) node.keys[index] = node.keys[index - 1];
        node.keys[slot] = key;
        node.len += 1;
        grant.touchLeaf(pools, leaf);
        if (slot == 0) fixMin(pools, node.parent, node.parent_slot, key);
        return;
    }
    const old_first = node.keys[0];
    var merged: [leaf_width + 1]u128 = undefined;
    var placed = false;
    var from: usize = 0;
    for (merged[0..]) |*dest| {
        if (!placed and (from == node.len or key < node.keys[from])) {
            dest.* = key;
            placed = true;
        } else {
            dest.* = node.keys[from];
            from += 1;
        }
    }
    const right = grant.allocLeaf(pools);
    const left_len: u8 = leaf_min;
    node.len = left_len;
    @memcpy(node.keys[0..left_len], merged[0..left_len]);
    const right_len: u8 = leaf_width + 1 - left_len;
    pools.leaves[right].len = right_len;
    @memcpy(pools.leaves[right].keys[0..right_len], merged[left_len..]);
    pools.leaves[right].next = node.next;
    node.next = right;
    grant.touchLeaf(pools, leaf);
    grant.touchLeaf(pools, right);
    if (node.keys[0] != old_first) fixMin(pools, node.parent, node.parent_slot, node.keys[0]);
    const parent = node.parent;
    const slot = node.parent_slot;
    const right_min = pools.leaves[right].keys[0];
    insertChild(pools, group, parent, slot, right_min, right, true, grant);
}

fn leafRemove(pools: *TreePools, group: *ThinkGroup, leaf: u32, slot: u8, grant: *NodeGrant) void {
    const node = &pools.leaves[leaf];
    const removed_first = slot == 0;
    var index: usize = slot;
    while (index + 1 < node.len) : (index += 1) node.keys[index] = node.keys[index + 1];
    node.len -= 1;
    grant.touchLeaf(pools, leaf);
    if (group.root_is_leaf) {
        if (node.len == 0) {
            grant.freeLeaf(pools, leaf);
            group.root = node_absent;
            group.head = node_absent;
            group.root_is_leaf = true;
        }
        return;
    }
    if (removed_first and node.len > 0) fixMin(pools, node.parent, node.parent_slot, node.keys[0]);
    if (node.len >= leaf_min) return;
    rebalanceLeaf(pools, group, leaf, grant);
}

fn rebalanceLeaf(pools: *TreePools, group: *ThinkGroup, leaf: u32, grant: *NodeGrant) void {
    const parent = pools.leaves[leaf].parent;
    if (parent == node_absent) return;
    const slot = pools.leaves[leaf].parent_slot;
    const branch = &pools.branches[parent];
    if (slot > 0) {
        const left = branch.child[slot - 1];
        if (pools.leaves[left].len > leaf_min) {
            borrowLeafLeft(pools, parent, slot, grant);
            return;
        }
    }
    if (slot + 1 < branch.len) {
        const right = branch.child[slot + 1];
        if (pools.leaves[right].len > leaf_min) {
            borrowLeafRight(pools, parent, slot, grant);
            return;
        }
    }
    if (slot > 0) {
        mergeLeaves(pools, group, parent, slot - 1, grant);
    } else {
        mergeLeaves(pools, group, parent, slot, grant);
    }
}

fn borrowLeafLeft(pools: *TreePools, parent: u32, slot: u8, grant: *NodeGrant) void {
    const branch = &pools.branches[parent];
    const left = branch.child[slot - 1];
    const leaf = branch.child[slot];
    const moved = pools.leaves[left].keys[pools.leaves[left].len - 1];
    pools.leaves[left].len -= 1;
    var index: usize = pools.leaves[leaf].len;
    while (index > 0) : (index -= 1) pools.leaves[leaf].keys[index] = pools.leaves[leaf].keys[index - 1];
    pools.leaves[leaf].keys[0] = moved;
    pools.leaves[leaf].len += 1;
    grant.touchLeaf(pools, left);
    grant.touchLeaf(pools, leaf);
    fixMin(pools, parent, slot, moved);
}

fn borrowLeafRight(pools: *TreePools, parent: u32, slot: u8, grant: *NodeGrant) void {
    const branch = &pools.branches[parent];
    const leaf = branch.child[slot];
    const right = branch.child[slot + 1];
    const moved = pools.leaves[right].keys[0];
    var index: usize = 0;
    while (index + 1 < pools.leaves[right].len) : (index += 1) pools.leaves[right].keys[index] = pools.leaves[right].keys[index + 1];
    pools.leaves[right].len -= 1;
    const dest = &pools.leaves[leaf];
    dest.keys[dest.len] = moved;
    dest.len += 1;
    grant.touchLeaf(pools, leaf);
    grant.touchLeaf(pools, right);
    fixMin(pools, parent, slot + 1, pools.leaves[right].keys[0]);
}

fn mergeLeaves(pools: *TreePools, group: *ThinkGroup, parent: u32, left_slot: u8, grant: *NodeGrant) void {
    const left = pools.branches[parent].child[left_slot];
    const right = pools.branches[parent].child[left_slot + 1];
    const right_len = pools.leaves[right].len;
    const right_next = pools.leaves[right].next;
    const left_len = pools.leaves[left].len;
    @memcpy(pools.leaves[left].keys[left_len..][0..right_len], pools.leaves[right].keys[0..right_len]);
    pools.leaves[left].len = left_len + right_len;
    pools.leaves[left].next = right_next;
    grant.touchLeaf(pools, left);
    grant.freeLeaf(pools, right);
    removeChild(pools, group, parent, left_slot + 1, grant);
}

fn insertChild(
    pools: *TreePools,
    group: *ThinkGroup,
    parent: u32,
    left_slot: u8,
    sep: u128,
    child: u32,
    child_is_leaf: bool,
    grant: *NodeGrant,
) void {
    if (parent == node_absent) {
        const root = grant.allocBranch(pools);
        const old = group.root;
        pools.branches[root].len = 2;
        pools.branches[root].leaf_children = child_is_leaf;
        pools.branches[root].sep[0] = sep;
        setChild(pools, root, 0, old, child_is_leaf);
        setChild(pools, root, 1, child, child_is_leaf);
        group.root = root;
        group.root_is_leaf = false;
        return;
    }
    const branch = &pools.branches[parent];
    if (branch.len < branch_width) {
        var index: usize = branch.len;
        while (index > left_slot + 1) : (index -= 1) branch.child[index] = branch.child[index - 1];
        var sep_index: usize = branch.len - 1;
        while (sep_index > left_slot) : (sep_index -= 1) branch.sep[sep_index] = branch.sep[sep_index - 1];
        branch.len += 1;
        branch.sep[left_slot] = sep;
        branch.child[left_slot + 1] = child;
        var slot: usize = 0;
        while (slot < branch.len) : (slot += 1) setChild(pools, parent, @intCast(slot), branch.child[slot], branch.leaf_children);
        return;
    }
    var children: [branch_width + 1]u32 = undefined;
    var seps: [branch_width]u128 = undefined;
    var placed = false;
    var from_child: usize = 0;
    for (children[0..]) |*dest| {
        const at = @as(u8, @intCast(from_child));
        if (!placed and at == left_slot + 1) {
            dest.* = child;
            placed = true;
        } else {
            dest.* = branch.child[from_child];
            from_child += 1;
        }
    }
    placed = false;
    var from_sep: usize = 0;
    for (seps[0..]) |*dest| {
        if (!placed and from_sep == left_slot) {
            dest.* = sep;
            placed = true;
        } else {
            dest.* = branch.sep[from_sep];
            from_sep += 1;
        }
    }
    const right = grant.allocBranch(pools);
    const left_children: u8 = branch_min;
    branch.len = left_children;
    branch.leaf_children = child_is_leaf;
    @memcpy(branch.child[0..left_children], children[0..left_children]);
    @memcpy(branch.sep[0 .. left_children - 1], seps[0 .. left_children - 1]);
    const right_children: u8 = branch_width + 1 - left_children;
    const right_node = &pools.branches[right];
    right_node.len = right_children;
    right_node.leaf_children = child_is_leaf;
    @memcpy(right_node.child[0..right_children], children[left_children..]);
    @memcpy(right_node.sep[0 .. right_children - 1], seps[left_children..][0 .. right_children - 1]);
    var slot: usize = 0;
    while (slot < left_children) : (slot += 1) setChild(pools, parent, @intCast(slot), branch.child[slot], child_is_leaf);
    slot = 0;
    while (slot < right_children) : (slot += 1) setChild(pools, right, @intCast(slot), right_node.child[slot], child_is_leaf);
    const promoted = seps[left_children - 1];
    const up = branch.parent;
    const up_slot = branch.parent_slot;
    insertChild(pools, group, up, up_slot, promoted, right, false, grant);
}

fn removeChild(pools: *TreePools, group: *ThinkGroup, branch_id: u32, slot: u8, grant: *NodeGrant) void {
    const is_leaf = pools.branches[branch_id].leaf_children;
    var index: usize = slot;
    while (index + 1 < pools.branches[branch_id].len) : (index += 1) {
        pools.branches[branch_id].child[index] = pools.branches[branch_id].child[index + 1];
    }
    if (pools.branches[branch_id].len > 1) {
        const sep_at: usize = if (slot == 0) 0 else slot - 1;
        var sep_index = sep_at;
        const sep_len = pools.branches[branch_id].len - 1;
        while (sep_index + 1 < sep_len) : (sep_index += 1) {
            pools.branches[branch_id].sep[sep_index] = pools.branches[branch_id].sep[sep_index + 1];
        }
    }
    pools.branches[branch_id].len -= 1;
    var child: usize = 0;
    while (child < pools.branches[branch_id].len) : (child += 1) {
        setChild(pools, branch_id, @intCast(child), pools.branches[branch_id].child[child], is_leaf);
    }
    if (group.root == branch_id and pools.branches[branch_id].len == 1) {
        const only = pools.branches[branch_id].child[0];
        grant.freeBranch(pools, branch_id);
        group.root = only;
        group.root_is_leaf = is_leaf;
        if (is_leaf) pools.leaves[only].parent = node_absent else pools.branches[only].parent = node_absent;
        return;
    }
    if (group.root != branch_id and pools.branches[branch_id].len < branch_min) rebalanceBranch(pools, group, branch_id, grant);
}

fn rebalanceBranch(pools: *TreePools, group: *ThinkGroup, branch_id: u32, grant: *NodeGrant) void {
    const parent = pools.branches[branch_id].parent;
    if (parent == node_absent) return;
    const slot = pools.branches[branch_id].parent_slot;
    const up = &pools.branches[parent];
    if (slot > 0 and pools.branches[up.child[slot - 1]].len > branch_min) {
        borrowBranchLeft(pools, parent, slot);
        return;
    }
    if (slot + 1 < up.len and pools.branches[up.child[slot + 1]].len > branch_min) {
        borrowBranchRight(pools, parent, slot);
        return;
    }
    if (slot > 0) {
        mergeBranches(pools, group, parent, slot - 1, grant);
    } else {
        mergeBranches(pools, group, parent, slot, grant);
    }
}

fn borrowBranchLeft(pools: *TreePools, parent: u32, slot: u8) void {
    const left = pools.branches[parent].child[slot - 1];
    const branch = pools.branches[parent].child[slot];
    const is_leaf = pools.branches[branch].leaf_children;
    const moved = pools.branches[left].child[pools.branches[left].len - 1];
    const moved_min = pools.branches[left].sep[pools.branches[left].len - 2];
    pools.branches[left].len -= 1;
    const old_min = pools.branches[parent].sep[slot - 1];
    var index: usize = pools.branches[branch].len;
    while (index > 0) : (index -= 1) pools.branches[branch].child[index] = pools.branches[branch].child[index - 1];
    var sep_index: usize = pools.branches[branch].len - 1;
    while (sep_index > 0) : (sep_index -= 1) pools.branches[branch].sep[sep_index] = pools.branches[branch].sep[sep_index - 1];
    pools.branches[branch].child[0] = moved;
    pools.branches[branch].sep[0] = old_min;
    pools.branches[branch].len += 1;
    pools.branches[parent].sep[slot - 1] = moved_min;
    var child: usize = 0;
    while (child < pools.branches[branch].len) : (child += 1) {
        setChild(pools, branch, @intCast(child), pools.branches[branch].child[child], is_leaf);
    }
}

fn borrowBranchRight(pools: *TreePools, parent: u32, slot: u8) void {
    const branch = pools.branches[parent].child[slot];
    const right = pools.branches[parent].child[slot + 1];
    const is_leaf = pools.branches[branch].leaf_children;
    const moved = pools.branches[right].child[0];
    const moved_min = pools.branches[parent].sep[slot];
    const new_right_min = pools.branches[right].sep[0];
    var index: usize = 0;
    while (index + 1 < pools.branches[right].len) : (index += 1) pools.branches[right].child[index] = pools.branches[right].child[index + 1];
    index = 0;
    while (index + 1 < pools.branches[right].len - 1) : (index += 1) pools.branches[right].sep[index] = pools.branches[right].sep[index + 1];
    pools.branches[right].len -= 1;
    const dest = &pools.branches[branch];
    dest.sep[dest.len - 1] = moved_min;
    dest.child[dest.len] = moved;
    dest.len += 1;
    pools.branches[parent].sep[slot] = new_right_min;
    setChild(pools, branch, dest.len - 1, moved, is_leaf);
    var child: usize = 0;
    while (child < pools.branches[right].len) : (child += 1) {
        setChild(pools, right, @intCast(child), pools.branches[right].child[child], is_leaf);
    }
}

fn mergeBranches(pools: *TreePools, group: *ThinkGroup, parent: u32, left_slot: u8, grant: *NodeGrant) void {
    const left = pools.branches[parent].child[left_slot];
    const right = pools.branches[parent].child[left_slot + 1];
    const is_leaf = pools.branches[left].leaf_children;
    const mid = pools.branches[parent].sep[left_slot];
    const left_len = pools.branches[left].len;
    const right_len = pools.branches[right].len;
    pools.branches[left].sep[left_len - 1] = mid;
    @memcpy(pools.branches[left].sep[left_len..][0 .. right_len - 1], pools.branches[right].sep[0 .. right_len - 1]);
    @memcpy(pools.branches[left].child[left_len..][0..right_len], pools.branches[right].child[0..right_len]);
    pools.branches[left].len = left_len + right_len;
    var child: usize = 0;
    while (child < pools.branches[left].len) : (child += 1) {
        setChild(pools, left, @intCast(child), pools.branches[left].child[child], is_leaf);
    }
    grant.freeBranch(pools, right);
    removeChild(pools, group, parent, left_slot + 1, grant);
}

fn setChild(pools: *TreePools, parent: u32, slot: u8, child: u32, is_leaf: bool) void {
    pools.branches[parent].child[slot] = child;
    if (is_leaf) {
        pools.leaves[child].parent = parent;
        pools.leaves[child].parent_slot = slot;
    } else {
        pools.branches[child].parent = parent;
        pools.branches[child].parent_slot = slot;
    }
}

// A subtree's minimum lives in the separator of the ancestor that is not its leftmost child.
fn fixMin(pools: *TreePools, parent: u32, slot: u8, minimum: u128) void {
    var up = parent;
    var at = slot;
    while (up != node_absent) {
        if (at > 0) {
            pools.branches[up].sep[at - 1] = minimum;
            return;
        }
        at = pools.branches[up].parent_slot;
        up = pools.branches[up].parent;
    }
}
