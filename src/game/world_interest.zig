// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! World-owned durable interest / affordance markers (Slice 41). Distinct from
//! ephemeral `WorldStimulus` dig/footstep/impact events.
//!
//! Storage is **fixed inline arrays** (`interest_marker_capacity` slots) —
//! allocation-free by construction after `init` (no heap growth path). Allocator
//! parameters on `init`/`deinit`/`ensureCapacity` exist only for API parity with
//! other world stores and future growth; they are unused today.
//!
//! **Kinds:** `investigate` is consumed by AI arbitration. `cover`, `resource`,
//! and `patrol` are reserved schema tags for future consumers (not AI inputs
//! yet) — do not treat them as live investigate attractors.
//!
//! **Geometry:** cognition discovery uses `dist <= query_radius` only.
//! `marker.radius` is the authored influence footprint (interaction/cover size
//! later); it is not a discovery gate. Query results are **nearest-k** by
//! distance² with ascending slot index as the tie-break (fixed max_k budget).

const std = @import("std");
const Faction = @import("faction.zig").Faction;

pub const interest_marker_capacity: usize = 128;
pub const interest_query_max_k: usize = 4;

pub const InterestMarkerKind = enum {
    /// Consumed by AI investigate scoring / goal resolution.
    investigate,
    /// Reserved — no consumer yet (future cover / flee policy).
    cover,
    /// Reserved — no consumer yet (future resource / gather).
    resource,
    /// Reserved — no consumer yet (future patrol anchors).
    patrol,
};

pub const InterestMarkerId = struct {
    index: u16,
    generation: u16,

    pub const invalid = InterestMarkerId{ .index = std.math.maxInt(u16), .generation = 0 };

    pub fn isValid(self: InterestMarkerId) bool {
        return self.index < interest_marker_capacity and self.generation != 0;
    }

    pub fn matches(self: InterestMarkerId, index: usize, generation: u16) bool {
        return self.isValid() and self.index == index and self.generation == generation;
    }
};

pub const InterestMarker = struct {
    kind: InterestMarkerKind,
    level: u16,
    x: f32,
    y: f32,
    /// Influence footprint (not cognition discovery radius). Must be finite > 0.
    radius: f32,
    faction_filter: ?Faction = null,
};

pub const InterestMarkerSpec = InterestMarker;

pub const InterestMarkerHit = struct {
    id: InterestMarkerId,
    kind: InterestMarkerKind,
    x: f32,
    y: f32,
    dist2: f32 = 0,
};

pub const InterestMarkerStore = struct {
    /// Non-zero while a marker occupies the slot (id generation for that slot).
    generations: [interest_marker_capacity]u16 = [_]u16{0} ** interest_marker_capacity,
    /// Monotonic per-slot epoch; bumped on every new allocation at the slot so
    /// removed ids stay invalid after reuse.
    retired_generations: [interest_marker_capacity]u16 = [_]u16{0} ** interest_marker_capacity,
    kinds: [interest_marker_capacity]InterestMarkerKind = undefined,
    levels: [interest_marker_capacity]u16 = undefined,
    xs: [interest_marker_capacity]f32 = undefined,
    ys: [interest_marker_capacity]f32 = undefined,
    radii: [interest_marker_capacity]f32 = undefined,
    faction_filter_present: [interest_marker_capacity]bool = [_]bool{false} ** interest_marker_capacity,
    faction_filters: [interest_marker_capacity]Faction = undefined,
    live_count: usize = 0,

    /// Fixed inline storage — allocator unused (API parity only).
    pub fn init(_: std.mem.Allocator) InterestMarkerStore {
        return .{};
    }

    /// Fixed inline storage — allocator unused (API parity only).
    pub fn deinit(self: *InterestMarkerStore, _: std.mem.Allocator) void {
        self.* = .{};
    }

    /// No-op: capacity is compile-time fixed. Present for call-site symmetry
    /// with heap-backed world stores; safe to call before add bursts.
    pub fn ensureCapacity(_: *InterestMarkerStore, _: std.mem.Allocator, _: usize) !void {}

    pub fn count(self: *const InterestMarkerStore) usize {
        return self.live_count;
    }

    pub fn clear(self: *InterestMarkerStore) void {
        @memset(&self.generations, 0);
        self.live_count = 0;
    }

    fn slotLive(self: *const InterestMarkerStore, index: usize) bool {
        return self.generations[index] != 0;
    }

    /// Restricted markers require a matching agent faction. Missing agent
    /// faction never passes a set filter (restricted unless proven).
    fn factionAccepts(self: *const InterestMarkerStore, index: usize, agent_faction: ?Faction) bool {
        if (!self.faction_filter_present[index]) return true;
        const filter = self.faction_filters[index];
        const agent = agent_faction orelse return false;
        return agent == filter;
    }

    /// Discovery geometry: agent within the query radius (marker.radius is not
    /// a discovery gate — see module docs).
    fn inQueryRange(self: *const InterestMarkerStore, index: usize, x: f32, y: f32, query_radius: f32) bool {
        const dx = self.xs[index] - x;
        const dy = self.ys[index] - y;
        const dist2 = dx * dx + dy * dy;
        return dist2 <= query_radius * query_radius;
    }

    fn dist2To(self: *const InterestMarkerStore, index: usize, x: f32, y: f32) f32 {
        const dx = self.xs[index] - x;
        const dy = self.ys[index] - y;
        return dx * dx + dy * dy;
    }

    pub fn addMarker(self: *InterestMarkerStore, spec: InterestMarkerSpec) !InterestMarkerId {
        if (!std.math.isFinite(spec.x) or !std.math.isFinite(spec.y)) return error.InvalidInterestMarkerPosition;
        if (!std.math.isFinite(spec.radius) or spec.radius <= 0) return error.InvalidInterestMarkerRadius;
        if (self.live_count >= interest_marker_capacity) return error.InterestMarkerCapacityExceeded;

        var slot: ?usize = null;
        for (0..interest_marker_capacity) |i| {
            if (!self.slotLive(i)) {
                slot = i;
                break;
            }
        }
        const index = slot orelse return error.InterestMarkerCapacityExceeded;

        var generation = self.retired_generations[index] +% 1;
        if (generation == 0) generation = 1;
        self.retired_generations[index] = generation;
        self.generations[index] = generation;
        self.kinds[index] = spec.kind;
        self.levels[index] = spec.level;
        self.xs[index] = spec.x;
        self.ys[index] = spec.y;
        self.radii[index] = spec.radius;
        if (spec.faction_filter) |faction| {
            self.faction_filter_present[index] = true;
            self.faction_filters[index] = faction;
        } else {
            self.faction_filter_present[index] = false;
        }
        self.live_count += 1;
        return .{ .index = @intCast(index), .generation = generation };
    }

    pub fn removeMarker(self: *InterestMarkerStore, id: InterestMarkerId) bool {
        if (!id.isValid()) return false;
        const index: usize = id.index;
        if (!self.slotLive(index)) return false;
        if (self.generations[index] != id.generation) return false;

        self.generations[index] = 0;
        self.faction_filter_present[index] = false;
        std.debug.assert(self.live_count > 0);
        self.live_count -= 1;
        return true;
    }

    /// Bounded **nearest-k** query: fills `out` with up to
    /// `min(out.len, max_k, interest_query_max_k)` in-range hits ordered by
    /// ascending dist² then ascending slot index. No allocation.
    pub fn queryMarkersInRadius(
        self: *const InterestMarkerStore,
        level: u16,
        x: f32,
        y: f32,
        radius: f32,
        agent_faction: ?Faction,
        out: []InterestMarkerHit,
        max_k: usize,
    ) usize {
        if (!std.math.isFinite(radius) or radius <= 0) return 0;
        const cap = @min(out.len, max_k, interest_query_max_k);
        if (cap == 0) return 0;

        var written: usize = 0;
        for (0..interest_marker_capacity) |index| {
            if (!self.slotLive(index)) continue;
            if (self.levels[index] != level) continue;
            if (!self.factionAccepts(index, agent_faction)) continue;
            if (!self.inQueryRange(index, x, y, radius)) continue;

            const d2 = self.dist2To(index, x, y);
            const candidate = InterestMarkerHit{
                .id = .{ .index = @intCast(index), .generation = self.generations[index] },
                .kind = self.kinds[index],
                .x = self.xs[index],
                .y = self.ys[index],
                .dist2 = d2,
            };
            written = insertNearestHit(out[0..cap], written, candidate);
        }
        return written;
    }

    /// Insert `candidate` into a sorted (dist2, slot) buffer of length `len`,
    /// keeping at most `buf.len` entries. Returns the new length.
    fn insertNearestHit(buf: []InterestMarkerHit, len: usize, candidate: InterestMarkerHit) usize {
        // Find insertion index: first position where candidate is strictly better
        // (smaller dist2, or equal dist2 and smaller slot index).
        var insert_at = len;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (candidateBetter(candidate, buf[i])) {
                insert_at = i;
                break;
            }
        }
        if (insert_at >= buf.len) {
            // Worse than every kept entry and buffer full.
            if (len >= buf.len) return len;
            buf[len] = candidate;
            return len + 1;
        }
        // Shift tail right, dropping last if already full.
        var j = if (len < buf.len) len else buf.len - 1;
        while (j > insert_at) : (j -= 1) {
            buf[j] = buf[j - 1];
        }
        buf[insert_at] = candidate;
        return if (len < buf.len) len + 1 else buf.len;
    }

    fn candidateBetter(a: InterestMarkerHit, b: InterestMarkerHit) bool {
        if (a.dist2 < b.dist2) return true;
        if (a.dist2 > b.dist2) return false;
        return a.id.index < b.id.index;
    }

    /// Nearest in-range `investigate` marker (dist², then ascending slot).
    pub fn findBestInvestigateMarker(
        self: *const InterestMarkerStore,
        level: u16,
        x: f32,
        y: f32,
        query_radius: f32,
        agent_faction: ?Faction,
    ) ?struct { x: f32, y: f32 } {
        if (!std.math.isFinite(query_radius) or query_radius <= 0) return null;

        var best_dist2: f32 = std.math.inf(f32);
        var best_index: ?usize = null;
        var best_x: f32 = 0;
        var best_y: f32 = 0;

        for (0..interest_marker_capacity) |index| {
            if (!self.slotLive(index)) continue;
            if (self.kinds[index] != .investigate) continue;
            if (self.levels[index] != level) continue;
            if (!self.factionAccepts(index, agent_faction)) continue;
            if (!self.inQueryRange(index, x, y, query_radius)) continue;

            const dist2 = self.dist2To(index, x, y);
            if (dist2 < best_dist2 or (dist2 == best_dist2 and (best_index == null or index < best_index.?))) {
                best_dist2 = dist2;
                best_index = index;
                best_x = self.xs[index];
                best_y = self.ys[index];
            }
        }
        if (best_index == null) return null;
        return .{ .x = best_x, .y = best_y };
    }
};

const testing = std.testing;

test "InterestMarkerStore capacity add remove and id invalidation" {
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    const id0 = try store.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = 10,
        .y = 20,
        .radius = 50,
    });
    try testing.expect(id0.isValid());
    try testing.expectEqual(@as(usize, 1), store.count());

    try testing.expect(store.removeMarker(id0));
    try testing.expectEqual(@as(usize, 0), store.count());
    try testing.expect(!store.removeMarker(id0));

    const id1 = try store.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = 11,
        .y = 21,
        .radius = 50,
    });
    try testing.expect(!id0.matches(id1.index, id1.generation));
}

test "InterestMarkerStore rejects capacity overflow" {
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    var i: usize = 0;
    while (i < interest_marker_capacity) : (i += 1) {
        _ = try store.addMarker(.{
            .kind = .investigate,
            .level = 0,
            .x = @floatFromInt(i),
            .y = 0,
            .radius = 1,
        });
    }
    try testing.expectError(error.InterestMarkerCapacityExceeded, store.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = 0,
        .y = 0,
        .radius = 1,
    }));
    try testing.expectEqual(interest_marker_capacity, store.count());
}

test "InterestMarkerStore level isolation and max_k bound" {
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    _ = try store.addMarker(.{ .kind = .investigate, .level = 0, .x = 0, .y = 0, .radius = 100 });
    _ = try store.addMarker(.{ .kind = .investigate, .level = 1, .x = 1, .y = 1, .radius = 100 });

    var hits: [8]InterestMarkerHit = undefined;
    const n = store.queryMarkersInRadius(0, 0, 0, 200, null, &hits, 8);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(u16, 0), store.levels[hits[0].id.index]);

    _ = try store.addMarker(.{ .kind = .cover, .level = 0, .x = 2, .y = 0, .radius = 100 });
    _ = try store.addMarker(.{ .kind = .resource, .level = 0, .x = 3, .y = 0, .radius = 100 });
    const capped = store.queryMarkersInRadius(0, 0, 0, 200, null, &hits, 2);
    try testing.expectEqual(@as(usize, 2), capped);
}

test "InterestMarkerStore query is nearest-k not first-slot-k" {
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    // Slot 0 is far; slot 1 is near. max_k=1 must keep the nearer marker.
    _ = try store.addMarker(.{ .kind = .investigate, .level = 0, .x = 100, .y = 0, .radius = 8 });
    _ = try store.addMarker(.{ .kind = .investigate, .level = 0, .x = 10, .y = 0, .radius = 8 });

    var hits: [4]InterestMarkerHit = undefined;
    const n = store.queryMarkersInRadius(0, 0, 0, 200, null, &hits, 1);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(f32, 10), hits[0].x);
    try testing.expectEqual(@as(u16, 1), hits[0].id.index);
}

test "InterestMarkerStore query order is ascending dist then slot" {
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    _ = try store.addMarker(.{ .kind = .investigate, .level = 0, .x = 30, .y = 0, .radius = 1 });
    _ = try store.addMarker(.{ .kind = .patrol, .level = 0, .x = 10, .y = 0, .radius = 1 });
    _ = try store.addMarker(.{ .kind = .cover, .level = 0, .x = 20, .y = 0, .radius = 1 });

    var hits: [4]InterestMarkerHit = undefined;
    const n = store.queryMarkersInRadius(0, 0, 0, 200, null, &hits, 4);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqual(@as(f32, 10), hits[0].x);
    try testing.expectEqual(@as(f32, 20), hits[1].x);
    try testing.expectEqual(@as(f32, 30), hits[2].x);
}

test "InterestMarkerStore discovery uses query radius not marker radius" {
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    // Small influence footprint; agent at dist 50 with query 100 still discovers.
    _ = try store.addMarker(.{ .kind = .investigate, .level = 0, .x = 50, .y = 0, .radius = 8 });

    var hits: [2]InterestMarkerHit = undefined;
    const n = store.queryMarkersInRadius(0, 0, 0, 100, null, &hits, 2);
    try testing.expectEqual(@as(usize, 1), n);

    const none = store.queryMarkersInRadius(0, 0, 0, 40, null, &hits, 2);
    try testing.expectEqual(@as(usize, 0), none);

    const best = store.findBestInvestigateMarker(0, 0, 0, 100, null);
    try testing.expect(best != null);
    try testing.expectEqual(@as(f32, 50), best.?.x);
}

test "InterestMarkerStore findBestInvestigateMarker nearest and equal-dist slot tie-break" {
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    _ = try store.addMarker(.{ .kind = .investigate, .level = 0, .x = 40, .y = 0, .radius = 1 });
    _ = try store.addMarker(.{ .kind = .investigate, .level = 0, .x = 20, .y = 0, .radius = 1 });
    const near = store.findBestInvestigateMarker(0, 0, 0, 100, null);
    try testing.expect(near != null);
    try testing.expectEqual(@as(f32, 20), near.?.x);

    store.clear();
    // Equal distance on opposite sides; lower slot wins.
    _ = try store.addMarker(.{ .kind = .investigate, .level = 0, .x = 10, .y = 0, .radius = 1 });
    _ = try store.addMarker(.{ .kind = .investigate, .level = 0, .x = -10, .y = 0, .radius = 1 });
    const tied = store.findBestInvestigateMarker(0, 0, 0, 100, null);
    try testing.expect(tied != null);
    try testing.expectEqual(@as(f32, 10), tied.?.x);

    // Non-investigate kinds are ignored by findBest.
    store.clear();
    _ = try store.addMarker(.{ .kind = .cover, .level = 0, .x = 5, .y = 0, .radius = 1 });
    try testing.expect(store.findBestInvestigateMarker(0, 0, 0, 100, null) == null);
}

test "InterestMarkerStore faction filter restricted unless proven" {
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    _ = try store.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = 0,
        .y = 0,
        .radius = 10,
        .faction_filter = .ally,
    });
    _ = try store.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = 5,
        .y = 0,
        .radius = 10,
        .faction_filter = null,
    });

    var hits: [4]InterestMarkerHit = undefined;
    // No agent faction: only unfiltered markers.
    const open_only = store.queryMarkersInRadius(0, 0, 0, 100, null, &hits, 4);
    try testing.expectEqual(@as(usize, 1), open_only);
    try testing.expectEqual(@as(f32, 5), hits[0].x);

    const ally_hits = store.queryMarkersInRadius(0, 0, 0, 100, .ally, &hits, 4);
    try testing.expectEqual(@as(usize, 2), ally_hits);

    const hostile_hits = store.queryMarkersInRadius(0, 0, 0, 100, .hostile, &hits, 4);
    try testing.expectEqual(@as(usize, 1), hostile_hits);
    try testing.expectEqual(@as(f32, 5), hits[0].x);

    try testing.expect(store.findBestInvestigateMarker(0, 0, 0, 100, null) != null);
    try testing.expectEqual(@as(f32, 5), store.findBestInvestigateMarker(0, 0, 0, 100, null).?.x);
    try testing.expectEqual(@as(f32, 0), store.findBestInvestigateMarker(0, 0, 0, 100, .ally).?.x);
}

test "InterestMarkerStore is allocation-free by fixed inline storage" {
    // Proof by construction: add/query take no allocator; storage is fixed arrays.
    // ensureCapacity is a documented no-op (API parity only).
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);
    try store.ensureCapacity(testing.allocator, interest_marker_capacity);

    const info = @typeInfo(@TypeOf(InterestMarkerStore.addMarker)).@"fn";
    inline for (info.params) |param| {
        try testing.expect(param.type != std.mem.Allocator);
    }
    const qinfo = @typeInfo(@TypeOf(InterestMarkerStore.queryMarkersInRadius)).@"fn";
    inline for (qinfo.params) |param| {
        try testing.expect(param.type != std.mem.Allocator);
    }

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        _ = try store.addMarker(.{
            .kind = .investigate,
            .level = 0,
            .x = @floatFromInt(i),
            .y = 0,
            .radius = 32,
        });
    }
    var hits: [4]InterestMarkerHit = undefined;
    _ = store.queryMarkersInRadius(0, 0, 0, 64, null, &hits, 4);
}

test "InterestMarkerStore rejects invalid radius and non-finite position" {
    var store = InterestMarkerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);
    try testing.expectError(error.InvalidInterestMarkerRadius, store.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = 0,
        .y = 0,
        .radius = 0,
    }));
    try testing.expectError(error.InvalidInterestMarkerPosition, store.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = std.math.nan(f32),
        .y = 0,
        .radius = 1,
    }));
    try testing.expectError(error.InvalidInterestMarkerPosition, store.addMarker(.{
        .kind = .investigate,
        .level = 0,
        .x = 0,
        .y = std.math.inf(f32),
        .radius = 1,
    }));
}
