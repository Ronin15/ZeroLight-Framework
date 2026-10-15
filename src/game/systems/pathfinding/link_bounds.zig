// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! Lower bounds on the abstract cost of a world's level links, the abstract search's
//! heuristic data: `LinkBounds` (short-link crossing rates, long-link pairs and their chain
//! closure) and the per-level `LevelCrossings`. `NavGraph` holds both and folds each link into
//! them once, where links enter the graph; queries only read them.

const std = @import("std");
const simd = @import("../../../core/simd.zig");
const LevelLink = @import("../../world/system.zig").LevelLink;
const CellCoord = @import("../../world/system.zig").CellCoord;
const types = @import("types.zig");
const unreachable_cost = types.unreachable_cost;
const inter_level_penalty = types.inter_level_penalty;
const long_link_pairs = types.long_link_pairs;
const long_lane_cap = types.long_lane_cap;
const crossing_rate_cap = types.crossing_rate_cap;
const cardinal_cost = types.cardinal_cost;
const diagonal_cost = types.diagonal_cost;
const octileU32 = types.octileU32;

/// Per-level rates the long-link term charges for a level gap: the least excess and the least
/// cost of a level-crossing short link, per level it spans, capped at `crossing_rate_cap`.
/// With no such link no level gap is crossable short-only, so both take the cap.
pub const CrossingRates = struct {
    excess: i32,
    cost: i32,
};

/// One box of a link pair's entrance or exit: a planar cell rect and a level range, inclusive.
pub const LinkBox = struct {
    x0: i32,
    y0: i32,
    x1: i32,
    y1: i32,
    l0: i32,
    l1: i32,

    pub fn point(x: i32, y: i32, level: i32) LinkBox {
        return .{ .x0 = x, .y0 = y, .x1 = x, .y1 = y, .l0 = level, .l1 = level };
    }

    fn contains(self: LinkBox, cell: CellCoord, level: u16) bool {
        return cell.x >= self.x0 and cell.x <= self.x1 and cell.y >= self.y0 and cell.y <= self.y1 and level >= self.l0 and level <= self.l1;
    }

    fn unionWith(self: LinkBox, other: LinkBox) LinkBox {
        return .{
            .x0 = @min(self.x0, other.x0),
            .y0 = @min(self.y0, other.y0),
            .x1 = @max(self.x1, other.x1),
            .y1 = @max(self.y1, other.y1),
            .l0 = @min(self.l0, other.l0),
            .l1 = @max(self.l1, other.l1),
        };
    }

    // Cells times levels covered; below 2^48 for u16 coordinates and levels.
    fn volume(self: LinkBox) i64 {
        return @as(i64, self.x1 - self.x0 + 1) * (self.y1 - self.y0 + 1) * (self.l1 - self.l0 + 1);
    }

    // Volume the union with `other` adds over the two boxes alone.
    fn mergeGrowth(self: LinkBox, other: LinkBox) i64 {
        return self.unionWith(other).volume() - self.volume() - other.volume();
    }

    // The short-link lower bound between a point of this box and a point of `other`: the
    // box term at their per-axis separations. Below 2^31.
    fn termTo(self: LinkBox, other: LinkBox, rates: CrossingRates) i64 {
        const dx: u32 = @intCast(@max(@as(i64, other.x0) - self.x1, @as(i64, self.x0) - other.x1, 0));
        const dy: u32 = @intCast(@max(@as(i64, other.y0) - self.y1, @as(i64, self.y0) - other.y1, 0));
        const gap: i64 = @max(@as(i64, other.l0) - self.l1, @as(i64, self.l0) - other.l1, 0);
        return @max(@as(i64, octileU32(0, 0, dx, dy)) + gap * rates.excess, gap * rates.cost);
    }
};

/// One side (entrances or exits) of a `LinkPairs` summary: per pair a planar cell rect and
/// level range, inclusive, in SoA i32 columns so a scan covers `simd.lane_count` pairs per step.
/// The owning summary keeps slots past its count equal to pair 0.
pub const LinkBoxes = struct {
    x0: [long_link_pairs]i32 = @splat(0),
    y0: [long_link_pairs]i32 = @splat(0),
    x1: [long_link_pairs]i32 = @splat(0),
    y1: [long_link_pairs]i32 = @splat(0),
    l0: [long_link_pairs]i32 = @splat(0),
    l1: [long_link_pairs]i32 = @splat(0),

    pub fn boxAt(self: *const LinkBoxes, index: usize) LinkBox {
        return .{ .x0 = self.x0[index], .y0 = self.y0[index], .x1 = self.x1[index], .y1 = self.y1[index], .l0 = self.l0[index], .l1 = self.l1[index] };
    }

    fn setBox(self: *LinkBoxes, index: usize, box: LinkBox) void {
        self.x0[index] = box.x0;
        self.y0[index] = box.y0;
        self.x1[index] = box.x1;
        self.y1[index] = box.y1;
        self.l0[index] = box.l0;
        self.l1[index] = box.l1;
    }

    /// Per slot, the short-link lower bound from (x, y) on `level` to a point in its box,
    /// clamped to `long_lane_cap`: max(octile to the box + gap * `rates.excess`, gap *
    /// `rates.cost`), gap being the levels between `level` and the box's range. Coordinates
    /// at most `max_link_box_coord` (a world-backed grid). Fixed work: one `simd.zig` `Int4`
    /// step per `simd.lane_count` slots.
    pub fn laneTerms(self: *const LinkBoxes, x: u32, y: u32, level: u16, rates: CrossingRates) [long_link_pairs]i32 {
        const kernel = BoxTermKernel.init(x, y, level, rates);
        var terms: [long_link_pairs]i32 = undefined;
        var index: usize = 0;
        while (index < long_link_pairs) : (index += simd.lane_count) {
            simd.storeInt4(terms[index..][0..simd.lane_count], kernel.terms(self, index));
        }
        return terms;
    }

    /// Per slot, the planar octile between a point of `query` and a point of its box when its
    /// level range covers `level`, else `long_lane_cap`: the least walk on `level` from a
    /// landing in the box to `query`. Query coordinates at most `max_link_box_coord`. Fixed
    /// work: one `simd.zig` `Int4` step per `simd.lane_count` slots.
    pub fn coveringTerms(self: *const LinkBoxes, query: LinkBox, level: u16) [long_link_pairs]i32 {
        // The rates only scale a level gap, which a covering term never charges.
        const kernel = BoxTermKernel.initBox(query, level, .{ .excess = 0, .cost = 0 });
        var terms: [long_link_pairs]i32 = undefined;
        var index: usize = 0;
        while (index < long_link_pairs) : (index += simd.lane_count) {
            simd.storeInt4(terms[index..][0..simd.lane_count], kernel.coveringTerms(self, index));
        }
        return terms;
    }

    /// The least over the first `pair_count` slots, rounded up to whole lane groups, of
    /// `offsets[slot]` plus its `laneTerms` value: one `Int4` step, one add, and one min per
    /// `simd.lane_count` slots. Offsets in [0, `long_lane_cap`].
    pub fn offsetLowerBound(self: *const LinkBoxes, offsets: *const [long_link_pairs]i32, pair_count: u32, x: u32, y: u32, level: u16, rates: CrossingRates) u32 {
        std.debug.assert(pair_count >= 1 and pair_count <= long_link_pairs);
        const kernel = BoxTermKernel.init(x, y, level, rates);
        const scanned = std.mem.alignForward(usize, pair_count, simd.lane_count);
        var nearest = simd.splatInt4(std.math.maxInt(i32));
        var index: usize = 0;
        while (index < scanned) : (index += simd.lane_count) {
            // At most 2 * long_lane_cap, inside an i32.
            nearest = simd.minInt4(nearest, simd.addInt4(simd.loadInt4(offsets[index..]), kernel.terms(self, index)));
        }
        var least = nearest[0];
        inline for (1..simd.lane_count) |lane| least = @min(least, nearest[lane]);
        // A min of non-negative lane sums.
        return @intCast(least);
    }
};

// The box term of one query box (a point is a zero-size box) against `simd.lane_count` boxes
// per step, its splats built once per scan.
const BoxTermKernel = struct {
    qx0: simd.Int4,
    qy0: simd.Int4,
    qx1: simd.Int4,
    qy1: simd.Int4,
    pl: simd.Int4,
    excess: simd.Int4,
    cost: simd.Int4,
    zero: simd.Int4,
    cardinal: simd.Int4,
    diagonal_extra: simd.Int4,
    cap: simd.Int4,

    fn init(x: u32, y: u32, level: u16, rates: CrossingRates) BoxTermKernel {
        std.debug.assert(x <= max_link_box_coord and y <= max_link_box_coord);
        // In range per the assert: x, y < 2^16.
        return initBox(LinkBox.point(@intCast(x), @intCast(y), level), level, rates);
    }

    // `query`'s level range is unused: `level` is the query's level.
    fn initBox(query: LinkBox, level: u16, rates: CrossingRates) BoxTermKernel {
        std.debug.assert(query.x0 >= 0 and query.y0 >= 0 and query.x0 <= query.x1 and query.y0 <= query.y1);
        std.debug.assert(query.x1 <= max_link_box_coord and query.y1 <= max_link_box_coord);
        std.debug.assert(rates.excess >= 0 and rates.excess <= crossing_rate_cap and rates.cost >= 0 and rates.cost <= crossing_rate_cap);
        return .{
            .qx0 = simd.splatInt4(query.x0),
            .qy0 = simd.splatInt4(query.y0),
            .qx1 = simd.splatInt4(query.x1),
            .qy1 = simd.splatInt4(query.y1),
            .pl = simd.splatInt4(level),
            .excess = simd.splatInt4(rates.excess),
            .cost = simd.splatInt4(rates.cost),
            .zero = simd.splatInt4(0),
            .cardinal = simd.splatInt4(cardinal_cost),
            .diagonal_extra = simd.splatInt4(diagonal_cost - cardinal_cost),
            .cap = simd.splatInt4(long_lane_cap),
        };
    }

    const Separation = struct {
        planar: simd.Int4,
        gap: simd.Int4,
    };

    // The planar octile between the query and boxes [index, index + lane_count) and the levels
    // between `level` and each box's range. Planar below 2^20 for u16 coordinates.
    fn separation(self: *const BoxTermKernel, boxes: *const LinkBoxes, index: usize) Separation {
        const zero = self.zero;
        // Distance between the query and a box per axis: max(box under query, query under box, 0).
        const dx = simd.maxInt4(simd.maxInt4(simd.subInt4(simd.loadInt4(boxes.x0[index..]), self.qx1), simd.subInt4(self.qx0, simd.loadInt4(boxes.x1[index..]))), zero);
        const dy = simd.maxInt4(simd.maxInt4(simd.subInt4(simd.loadInt4(boxes.y0[index..]), self.qy1), simd.subInt4(self.qy0, simd.loadInt4(boxes.y1[index..]))), zero);
        const gap = simd.maxInt4(simd.maxInt4(simd.subInt4(simd.loadInt4(boxes.l0[index..]), self.pl), simd.subInt4(self.pl, simd.loadInt4(boxes.l1[index..]))), zero);
        const planar = simd.addInt4(simd.mulInt4(simd.maxInt4(dx, dy), self.cardinal), simd.mulInt4(simd.minInt4(dx, dy), self.diagonal_extra));
        return .{ .planar = planar, .gap = gap };
    }

    // Terms of boxes [index, index + lane_count), clamped to `long_lane_cap`. Unclamped a term
    // is below 2^20 + 2^30, inside an i32.
    fn terms(self: *const BoxTermKernel, boxes: *const LinkBoxes, index: usize) simd.Int4 {
        const parts = self.separation(boxes, index);
        const term = simd.maxInt4(simd.addInt4(parts.planar, simd.mulInt4(parts.gap, self.excess)), simd.mulInt4(parts.gap, self.cost));
        return simd.minInt4(term, self.cap);
    }

    // `LinkBoxes.coveringTerms` of boxes [index, index + lane_count).
    fn coveringTerms(self: *const BoxTermKernel, boxes: *const LinkBoxes, index: usize) simd.Int4 {
        const parts = self.separation(boxes, index);
        return simd.selectInt4(simd.greaterThanInt4(parts.gap, self.zero), self.cap, simd.minInt4(parts.planar, self.cap));
    }
};

/// Largest cell coordinate a `LinkBoxes` scan accepts: a world-backed grid's (`u16` sides).
pub const max_link_box_coord: u32 = std.math.maxInt(u16);

/// Up to `long_link_pairs` link pairs covering every folded directed link of one set: a pair
/// is an entrance box, an exit box, and a cost at most that of each link it holds (from its
/// entrance box to its exit box). Exact until the cap; past it the two candidates (the pairs and
/// the new link's point pair) whose merge adds the least entrance plus exit volume merge,
/// keeping the lesser cost, so a far link opens a pair of its own. A link whose endpoints some
/// pair already holds only lowers a cost: the pairs are a pure function of insert order and
/// inserting again changes nothing; no link is ever dropped. Slots past `count` copy pair 0, so
/// a scan over every slot equals one over `count`. Costs are clamped to `long_lane_cap`.
pub const LinkPairs = struct {
    entrances: LinkBoxes = .{},
    exits: LinkBoxes = .{},
    cost: [long_link_pairs]i32 = @splat(0),
    count: u32 = 0,

    // What an insert changed: whether the pairs changed, and the exit levels no exit box
    // covered before it: the new link's own level when `covers_to`, and a merge's gap
    // `gap_lo..gap_hi` between the two merged ranges (empty while lo > hi).
    const Inserted = struct {
        changed: bool,
        covers_to: bool = false,
        gap_lo: i32 = 1,
        gap_hi: i32 = 0,
    };

    // A link some pair holds at no more than its cost changes nothing; one only pricier pairs
    // hold lowers the first of them. Merge ties take the lowest candidates (i, j). At most
    // C(long_link_pairs + 1, 2) merge checks. Returns whether the pairs changed.
    fn insert(self: *LinkPairs, from: CellCoord, from_level: u16, to: CellCoord, to_level: u16, cost: i32) bool {
        return self.insertCovering(from, from_level, to, to_level, cost).changed;
    }

    // `insert`, also returning the exit levels the change may newly cover: the new link's own
    // level, and the levels between a merge's two exit ranges.
    fn insertCovering(self: *LinkPairs, from: CellCoord, from_level: u16, to: CellCoord, to_level: u16, cost: i32) Inserted {
        std.debug.assert(cost >= 0 and cost <= long_lane_cap);
        var pricier_holder: ?usize = null;
        for (0..self.count) |index| {
            if (!self.entrances.boxAt(index).contains(from, from_level) or !self.exits.boxAt(index).contains(to, to_level)) continue;
            if (self.cost[index] <= cost) return .{ .changed = false };
            if (pricier_holder == null) pricier_holder = index;
        }
        if (pricier_holder) |index| {
            self.cost[index] = cost;
            self.padFromFirst();
            return .{ .changed = true };
        }
        var covered = Inserted{ .changed = true, .covers_to = true };
        const entrance = LinkBox.point(from.x, from.y, from_level);
        const exit = LinkBox.point(to.x, to.y, to_level);
        if (self.count < long_link_pairs) {
            self.entrances.setBox(self.count, entrance);
            self.exits.setBox(self.count, exit);
            self.cost[self.count] = cost;
            self.count += 1;
        } else {
            // Candidate `long_link_pairs` is the new link's point pair.
            var best_i: usize = 0;
            var best_j: usize = 1;
            var best_added: i64 = std.math.maxInt(i64);
            for (0..long_link_pairs) |i| {
                const entrance_i = self.entrances.boxAt(i);
                const exit_i = self.exits.boxAt(i);
                for (i + 1..long_link_pairs + 1) |j| {
                    const entrance_j = if (j == long_link_pairs) entrance else self.entrances.boxAt(j);
                    const exit_j = if (j == long_link_pairs) exit else self.exits.boxAt(j);
                    const added = entrance_i.mergeGrowth(entrance_j) + exit_i.mergeGrowth(exit_j);
                    if (added < best_added) {
                        best_i = i;
                        best_j = j;
                        best_added = added;
                    }
                }
            }
            const new_pair = best_j == long_link_pairs;
            const entrance_j = if (new_pair) entrance else self.entrances.boxAt(best_j);
            const exit_j = if (new_pair) exit else self.exits.boxAt(best_j);
            const cost_j = if (new_pair) cost else self.cost[best_j];
            const exit_i = self.exits.boxAt(best_i);
            self.entrances.setBox(best_i, self.entrances.boxAt(best_i).unionWith(entrance_j));
            self.exits.setBox(best_i, exit_i.unionWith(exit_j));
            covered.gap_lo = @min(exit_i.l1, exit_j.l1) + 1;
            covered.gap_hi = @max(exit_i.l0, exit_j.l0) - 1;
            self.cost[best_i] = @min(self.cost[best_i], cost_j);
            if (!new_pair) {
                self.entrances.setBox(best_j, entrance);
                self.exits.setBox(best_j, exit);
                self.cost[best_j] = cost;
            }
        }
        self.padFromFirst();
        return covered;
    }

    fn padFromFirst(self: *LinkPairs) void {
        for (self.count..long_link_pairs) |index| {
            self.entrances.setBox(index, self.entrances.boxAt(0));
            self.exits.setBox(index, self.exits.boxAt(0));
            self.cost[index] = self.cost[0];
        }
    }
};

/// The chain bounds of a `LinkPairs`: `to[r][p]` is a lower bound on the cost from a point of
/// pair p's exit box, along short links and the links of further pairs, to a landing point in
/// pair r's exit box (0 for r == p): the min-plus closure of exit-to-entrance box terms plus
/// pair costs, under the crossing rates of the last `close`, clamped to `long_lane_cap`. Stored
/// by r so a query takes pair-p lanes per r.
pub const PairChains = struct {
    to: [long_link_pairs][long_link_pairs]i32 = @splat(@splat(0)),

    // Rebuilds the chains from `pairs`: Floyd-Warshall over edges p -> q weighted by the box
    // term from p's exit box to q's entrance box plus q's cost, in i64, then clamped. Slots past
    // `count` take pair 0's rows and columns. Fixed work: count^3 relaxes.
    fn close(self: *PairChains, pairs: *const LinkPairs, rates: CrossingRates) void {
        const count = pairs.count;
        if (count == 0) return;
        var chain: [long_link_pairs][long_link_pairs]i64 = undefined;
        for (0..count) |from| {
            const exit = pairs.exits.boxAt(from);
            for (0..count) |to| {
                chain[from][to] = if (from == to) 0 else exit.termTo(pairs.entrances.boxAt(to), rates) + pairs.cost[to];
            }
        }
        for (0..count) |via| {
            for (0..count) |from| {
                for (0..count) |to| chain[from][to] = @min(chain[from][to], chain[from][via] + chain[via][to]);
            }
        }
        for (0..long_link_pairs) |to| {
            const to_pair = if (to < count) to else 0;
            for (0..long_link_pairs) |from| {
                const from_pair = if (from < count) from else 0;
                self.to[to][from] = @intCast(@min(chain[from_pair][to_pair], long_lane_cap));
            }
        }
    }
};

/// Lower bounds on the abstract cost of the world's links, read by every abstract query and
/// folded once per link where links enter the graph (world build, marks commit), never per
/// query. A link is short when its cost (`traversal_cost +| inter_level_penalty`, the edge
/// cost) covers the planar octile between its endpoints, else long. Same-level short links
/// never lower a path's cost below its planar octile, so they fold nothing. Every fold is a
/// min, a max, or a pair insert that ignores a covered link, and a batch that changes the
/// pairs or the crossing rates recloses the pair chains once: the bounds are a pure function
/// of link order, and folding a link again changes nothing. Fixed size; never allocates.
pub const LinkBounds = struct {
    /// Most levels one level-crossing short link spans; 0 when none exists.
    short_span: u16 = 0,
    /// Least cost of a level-crossing short link.
    short_cost: u32 = unreachable_cost,
    /// Least excess of a level-crossing short link's cost over its endpoints' planar octile.
    short_excess: u32 = unreachable_cost,
    /// Least cost of a long link.
    long_cost: u32 = unreachable_cost,
    /// Every directed long link (a to b, and b to a when bidirectional).
    pairs: LinkPairs = .{},
    /// `pairs`' chains, closed under `crossingRates()`.
    chains: PairChains = .{},

    /// Folds `links` and recloses the chains once if the pairs or the crossing rates changed.
    pub fn foldLinks(self: *LinkBounds, links: []const LevelLink) void {
        const rates = self.crossingRates();
        var pairs_changed = false;
        for (links) |link| {
            if (self.foldLink(link)) pairs_changed = true;
        }
        const folded_rates = self.crossingRates();
        if (pairs_changed or !std.meta.eql(rates, folded_rates)) self.chains.close(&self.pairs, folded_rates);
    }

    // Returns whether the pairs changed.
    fn foldLink(self: *LinkBounds, link: LevelLink) bool {
        const cost = linkEdgeCost(link);
        const planar = octileU32(link.cell_a.x, link.cell_a.y, link.cell_b.x, link.cell_b.y);
        if (planar > cost) {
            self.long_cost = @min(self.long_cost, cost);
            const lane_cost: i32 = @intCast(@min(cost, long_lane_cap));
            var changed = self.pairs.insert(link.cell_a, link.level_a, link.cell_b, link.level_b, lane_cost);
            if (link.bidirectional and self.pairs.insert(link.cell_b, link.level_b, link.cell_a, link.level_a, lane_cost)) changed = true;
            return changed;
        }
        if (link.level_a == link.level_b) return false;
        self.short_span = @max(self.short_span, @max(link.level_a, link.level_b) - @min(link.level_a, link.level_b));
        self.short_cost = @min(self.short_cost, cost);
        self.short_excess = @min(self.short_excess, cost - planar);
        return false;
    }

    /// The per-level crossing rates of the folded short links.
    pub fn crossingRates(self: *const LinkBounds) CrossingRates {
        if (self.short_span == 0) return .{ .excess = crossing_rate_cap, .cost = crossing_rate_cap };
        return .{
            .excess = @intCast(@min(self.short_excess / self.short_span, crossing_rate_cap)),
            .cost = @intCast(@min(self.short_cost / self.short_span, crossing_rate_cap)),
        };
    }
};

// A link's abstract edge cost.
fn linkEdgeCost(link: LevelLink) u32 {
    return link.traversal_cost +| inter_level_penalty;
}

/// One level's departing level-crossing short links, the cross-level heuristic's per-level
/// data: every short link (its cost covers its endpoints' planar octile) leaving this level for
/// another, both directions of a bidirectional one each at its own source, clustered into
/// `LinkPairs` boxes. Entrance boxes lie on this level; exit boxes carry level ranges.
/// `arrival_lo..arrival_hi` (inclusive; empty while lo > hi) covers every source level holding
/// an exit box whose range covers this level, and only grows. Fixed size; folded once per link
/// where links enter the graph, never per query or per terrain change.
pub const LevelCrossings = struct {
    departing: LinkPairs = .{},
    arrival_lo: u16 = std.math.maxInt(u16),
    arrival_hi: u16 = 0,
};

/// Folds `links`' level-crossing short links into their source levels' crossings, each a fixed
/// pair insert plus window updates on the exit levels it newly covers: every level an exit box
/// of the source covered already holds the source. A pure function of link order; folding a
/// link again changes nothing. Every endpoint level is below `crossings.len`.
pub fn foldLevelCrossings(crossings: []LevelCrossings, links: []const LevelLink) void {
    for (links) |link| {
        const cost = linkEdgeCost(link);
        if (link.level_a == link.level_b or octileU32(link.cell_a.x, link.cell_a.y, link.cell_b.x, link.cell_b.y) > cost) continue;
        const lane_cost: i32 = @intCast(@min(cost, long_lane_cap));
        foldCrossing(crossings, link.level_a, link.cell_a, link.level_b, link.cell_b, lane_cost);
        if (link.bidirectional) foldCrossing(crossings, link.level_b, link.cell_b, link.level_a, link.cell_a, lane_cost);
    }
}

fn foldCrossing(crossings: []LevelCrossings, from_level: u16, from: CellCoord, to_level: u16, to: CellCoord, cost: i32) void {
    std.debug.assert(from_level < crossings.len and to_level < crossings.len);
    const inserted = crossings[from_level].departing.insertCovering(from, from_level, to, to_level, cost);
    if (!inserted.changed) return;
    if (inserted.covers_to) widenArrival(&crossings[to_level], from_level);
    var level = inserted.gap_lo;
    // In range: a merge's gap lies between folded endpoint levels.
    while (level <= inserted.gap_hi) : (level += 1) widenArrival(&crossings[@intCast(level)], from_level);
}

fn widenArrival(arrival: *LevelCrossings, source: u16) void {
    arrival.arrival_lo = @min(arrival.arrival_lo, source);
    arrival.arrival_hi = @max(arrival.arrival_hi, source);
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

const expectLinkPair = @import("test_support.zig").expectLinkPair;

// A directed long link for the pair tests.
const PairLink = struct {
    from: CellCoord,
    from_level: u16,
    to: CellCoord,
    to_level: u16,
    cost: i32,

    fn insertInto(self: PairLink, pairs: *LinkPairs) bool {
        return pairs.insert(self.from, self.from_level, self.to, self.to_level, self.cost);
    }
};

// Whether some pair holds both of `link`'s endpoints at no more than its cost.
fn pairHolds(pairs: *const LinkPairs, link: PairLink) bool {
    for (0..pairs.count) |index| {
        if (pairs.entrances.boxAt(index).contains(link.from, link.from_level) and pairs.exits.boxAt(index).contains(link.to, link.to_level) and pairs.cost[index] <= link.cost) return true;
    }
    return false;
}

fn expectPadsCopyFirst(pairs: *const LinkPairs) !void {
    for (pairs.count..long_link_pairs) |pad| {
        try std.testing.expectEqual(pairs.entrances.boxAt(0), pairs.entrances.boxAt(pad));
        try std.testing.expectEqual(pairs.exits.boxAt(0), pairs.exits.boxAt(pad));
        try std.testing.expectEqual(pairs.cost[0], pairs.cost[pad]);
    }
}

test "a link pair summary holds every folded link in one pair at most its cost, is exact to its cap, ignores a covered link, and keeps far pairs, mirrored strips, and split exits apart" {
    var prng = std.Random.DefaultPrng.init(0x6e67_0000);
    const random = prng.random();
    var pairs = LinkPairs{};
    var links: [200]PairLink = undefined;
    for (&links, 0..) |*link, index| {
        link.* = .{
            .from = .{ .x = random.uintLessThan(u16, 512), .y = random.uintLessThan(u16, 512) },
            .from_level = random.uintLessThan(u16, 8),
            .to = .{ .x = random.uintLessThan(u16, 512), .y = random.uintLessThan(u16, 512) },
            .to_level = random.uintLessThan(u16, 8),
            .cost = random.intRangeAtMost(i32, 0, 200),
        };
        // Past the cap a merged pair may already hold a new link.
        const changed = link.insertInto(&pairs);
        try std.testing.expect(changed or index >= long_link_pairs);
        try std.testing.expectEqual(@min(index + 1, long_link_pairs), pairs.count);
        for (links[0 .. index + 1]) |folded| try std.testing.expect(pairHolds(&pairs, folded));
        try expectPadsCopyFirst(&pairs);
        if (index < long_link_pairs) {
            for (links[0 .. index + 1], 0..) |folded, pair| {
                try expectLinkPair(&pairs, pair, .{ folded.from.x, folded.from.y, folded.from_level }, .{ folded.to.x, folded.to.y, folded.to_level }, folded.cost);
            }
        }
        // A covered link at its cost or more changes nothing; a cheaper one lowers a cost only.
        const before = pairs;
        var again = links[random.uintLessThan(usize, index + 1)];
        try std.testing.expect(!again.insertInto(&pairs));
        try std.testing.expect(std.meta.eql(before, pairs));
        again.cost = 0;
        _ = again.insertInto(&pairs);
        try std.testing.expect(std.meta.eql(before.entrances, pairs.entrances) and std.meta.eql(before.exits, pairs.exits));
        pairs = before;
    }

    // A merged pair 0 covers a link at 50 that pair 1 holds at 5: inserting it again at 10
    // changes nothing, since a holder already bounds it.
    var shadowed = LinkPairs{ .count = 2 };
    shadowed.entrances.setBox(0, .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 0, .l0 = 0, .l1 = 0 });
    shadowed.exits.setBox(0, .{ .x0 = 100, .y0 = 0, .x1 = 110, .y1 = 0, .l0 = 0, .l1 = 0 });
    shadowed.cost[0] = 50;
    shadowed.entrances.setBox(1, LinkBox.point(5, 0, 0));
    shadowed.exits.setBox(1, LinkBox.point(105, 0, 0));
    shadowed.cost[1] = 5;
    shadowed.padFromFirst();
    const shadowed_before = shadowed;
    try std.testing.expect(!(PairLink{ .from = .{ .x = 5, .y = 0 }, .from_level = 0, .to = .{ .x = 105, .y = 0 }, .to_level = 0, .cost = 10 }).insertInto(&shadowed));
    try std.testing.expect(std.meta.eql(shadowed_before, shadowed));

    // A full row of nearby pairs, then one far away: the far link keeps a pair of its own.
    var row = LinkPairs{};
    for (0..long_link_pairs) |column| {
        const x: u16 = @intCast(column * 4);
        _ = (PairLink{ .from = .{ .x = x, .y = 0 }, .from_level = 0, .to = .{ .x = x, .y = 10 }, .to_level = 0, .cost = 5 }).insertInto(&row);
    }
    _ = (PairLink{ .from = .{ .x = 200, .y = 200 }, .from_level = 0, .to = .{ .x = 210, .y = 210 }, .to_level = 0, .cost = 5 }).insertInto(&row);
    var own_pair = false;
    for (0..long_link_pairs) |index| {
        own_pair = own_pair or (std.meta.eql(row.entrances.boxAt(index), LinkBox.point(200, 200, 0)) and std.meta.eql(row.exits.boxAt(index), LinkBox.point(210, 210, 0)));
    }
    try std.testing.expect(own_pair);

    // Bidirectional links between a west strip on level 0 and its mirror on level 7: no box
    // spans both strips, so no pair enters on one and exits beside the same strip.
    var strips = LinkPairs{};
    for (0..32) |_| {
        const west = CellCoord{ .x = random.uintLessThan(u16, 4), .y = random.uintLessThan(u16, 256) };
        const east = CellCoord{ .x = 255 - west.x, .y = 255 - west.y };
        _ = (PairLink{ .from = west, .from_level = 0, .to = east, .to_level = 7, .cost = 41 }).insertInto(&strips);
        _ = (PairLink{ .from = east, .from_level = 7, .to = west, .to_level = 0, .cost = 41 }).insertInto(&strips);
    }
    try std.testing.expectEqual(@as(u32, long_link_pairs), strips.count);
    for (0..long_link_pairs) |index| {
        for ([_]LinkBox{ strips.entrances.boxAt(index), strips.exits.boxAt(index) }) |box| try std.testing.expect(box.x1 < 128 or box.x0 >= 128);
    }

    // Adjacent entrances whose exits alternate between two far regions: merges follow the
    // exits, so no exit box spans both regions.
    var split = LinkPairs{};
    for (0..48) |index| {
        const x: u16 = @intCast(index);
        const exit_x: u16 = if (index % 2 == 0) 400 + x else x;
        _ = (PairLink{ .from = .{ .x = x, .y = 0 }, .from_level = 0, .to = .{ .x = exit_x, .y = 300 }, .to_level = 0, .cost = 5 }).insertInto(&split);
    }
    for (0..long_link_pairs) |index| {
        const box = split.exits.boxAt(index);
        try std.testing.expect(box.x1 < 200 or box.x0 >= 200);
    }
}

// Scalar reference for one box term, unclamped.
fn boxTermScalar(box: LinkBox, x: i64, y: i64, level: i64, rates: CrossingRates) i64 {
    const dx: i64 = @max(box.x0 - x, x - box.x1, 0);
    const dy: i64 = @max(box.y0 - y, y - box.y1, 0);
    const gap: i64 = @max(box.l0 - level, level - box.l1, 0);
    const planar: i64 = octileU32(0, 0, @intCast(dx), @intCast(dy));
    return @max(planar + gap * rates.excess, gap * rates.cost);
}

// Scalar reference for the box term between two boxes, unclamped.
fn boxPairTermScalar(from: LinkBox, to: LinkBox, rates: CrossingRates) i64 {
    const dx: i64 = @max(@as(i64, to.x0) - from.x1, @as(i64, from.x0) - to.x1, 0);
    const dy: i64 = @max(@as(i64, to.y0) - from.y1, @as(i64, from.y0) - to.y1, 0);
    const gap: i64 = @max(@as(i64, to.l0) - from.l1, @as(i64, from.l0) - to.l1, 0);
    return @max(octileU32(0, 0, @intCast(dx), @intCast(dy)) + gap * rates.excess, gap * rates.cost);
}

fn randomExtreme(random: std.Random) u16 {
    const extremes = [_]u16{ 0, std.math.maxInt(u16) };
    return if (random.boolean()) extremes[random.uintLessThan(usize, 2)] else random.int(u16);
}

fn randomRates(random: std.Random) CrossingRates {
    const choices = [_]i32{ 0, crossing_rate_cap, random.intRangeAtMost(i32, 0, crossing_rate_cap) };
    return .{ .excess = choices[random.uintLessThan(usize, 3)], .cost = choices[random.uintLessThan(usize, 3)] };
}

// Pairs from 1 to 24 random links with coordinates, levels, and costs at their extremes.
fn randomLinkPairs(random: std.Random) LinkPairs {
    var pairs = LinkPairs{};
    const links = 1 + random.uintLessThan(usize, long_link_pairs + 8);
    for (0..links) |_| {
        const cost_choices = [_]i32{ 0, long_lane_cap, random.intRangeAtMost(i32, 0, long_lane_cap) };
        _ = pairs.insert(.{ .x = randomExtreme(random), .y = randomExtreme(random) }, randomExtreme(random), .{ .x = randomExtreme(random), .y = randomExtreme(random) }, randomExtreme(random), cost_choices[random.uintLessThan(usize, 3)]);
    }
    return pairs;
}

test "the box lane terms and offset scan equal a scalar scan" {
    var prng = std.Random.DefaultPrng.init(0x6e68_0000);
    const random = prng.random();
    var checked: usize = 0;
    var clamped: usize = 0;
    for (0..64) |_| {
        const pairs = randomLinkPairs(random);
        for (0..32) |_| {
            const rates = randomRates(random);
            const x: u32 = randomExtreme(random);
            const y: u32 = randomExtreme(random);
            const level = randomExtreme(random);
            var offsets: [long_link_pairs]i32 = undefined;
            const offset_kind = random.uintLessThan(usize, 3);
            for (&offsets) |*offset| offset.* = switch (offset_kind) {
                0 => 0,
                1 => long_lane_cap,
                else => random.intRangeAtMost(i32, 0, long_lane_cap),
            };
            const terms = pairs.entrances.laneTerms(x, y, level, rates);
            // The scan covers the pairs' whole lane groups.
            const scanned = std.mem.alignForward(usize, pairs.count, simd.lane_count);
            var least: i64 = std.math.maxInt(i64);
            for (0..long_link_pairs) |slot| {
                const raw = boxTermScalar(pairs.entrances.boxAt(slot), x, y, level, rates);
                clamped += @intFromBool(raw > long_lane_cap);
                const term = @min(raw, long_lane_cap);
                try std.testing.expectEqual(term, terms[slot]);
                if (slot < scanned) least = @min(least, offsets[slot] + term);
            }
            try std.testing.expectEqual(least, pairs.entrances.offsetLowerBound(&offsets, pairs.count, x, y, level, rates));
            checked += 1;
        }
    }
    try std.testing.expect(checked > 1000);
    try std.testing.expect(clamped > 0);
}

// Scalar reference for one covering term: the planar octile between two boxes when `box`'s
// level range covers `level`, else the cap.
fn coveringTermScalar(box: LinkBox, query: LinkBox, level: i64) i64 {
    if (level < box.l0 or level > box.l1) return long_lane_cap;
    const dx: i64 = @max(@as(i64, box.x0) - query.x1, @as(i64, query.x0) - box.x1, 0);
    const dy: i64 = @max(@as(i64, box.y0) - query.y1, @as(i64, query.y0) - box.y1, 0);
    return @min(octileU32(0, 0, @intCast(dx), @intCast(dy)), long_lane_cap);
}

test "the covering terms equal a scalar box-to-box octile where a box's level range covers the level, and the cap elsewhere" {
    var prng = std.Random.DefaultPrng.init(0x6e6a_0000);
    const random = prng.random();
    var covered: usize = 0;
    var uncovered: usize = 0;
    for (0..64) |_| {
        const pairs = randomLinkPairs(random);
        for (0..32) |_| {
            const corner_x = randomExtreme(random);
            const corner_y = randomExtreme(random);
            const query = LinkBox{
                .x0 = corner_x,
                .y0 = corner_y,
                .x1 = corner_x + random.uintAtMost(u16, std.math.maxInt(u16) - corner_x),
                .y1 = corner_y + random.uintAtMost(u16, std.math.maxInt(u16) - corner_y),
                .l0 = 0,
                .l1 = 0,
            };
            // A level some box covers, or any level.
            const level: u16 = if (random.boolean()) @intCast(pairs.exits.l0[random.uintLessThan(usize, long_link_pairs)]) else randomExtreme(random);
            const terms = pairs.exits.coveringTerms(query, level);
            for (0..long_link_pairs) |slot| {
                const expected = coveringTermScalar(pairs.exits.boxAt(slot), query, level);
                try std.testing.expectEqual(expected, terms[slot]);
                if (expected == long_lane_cap) uncovered += 1 else covered += 1;
            }
        }
    }
    try std.testing.expect(covered > 1000);
    try std.testing.expect(uncovered > 1000);
}

// Random links over `levels` levels on a 64² level: ramps, stairs, and short teleports
// spanning many levels (all folded into crossings), and long teleports and same-level short
// ones (folded into none).
fn randomCrossingLinks(random: std.Random, levels: u16, links: []LevelLink) void {
    for (links) |*link| {
        const level_a = random.uintLessThan(u16, levels);
        const cell_a = CellCoord{ .x = random.uintLessThan(u16, 64), .y = random.uintLessThan(u16, 64) };
        const other = (level_a + 1 + random.uintLessThan(u16, levels - 1)) % levels;
        link.* = switch (random.uintLessThan(u32, 5)) {
            0, 1 => .{ .kind = .ramp, .level_a = level_a, .cell_a = cell_a, .level_b = other, .cell_b = cell_a, .traversal_cost = random.uintLessThan(u32, 8), .bidirectional = random.boolean() },
            // Planar span at most 14 under cost 41 or more: short.
            2 => .{ .kind = .stair, .level_a = level_a, .cell_a = cell_a, .level_b = other, .cell_b = .{ .x = cell_a.x ^ 1, .y = cell_a.y }, .traversal_cost = 3, .bidirectional = random.boolean() },
            // Planar span at least 640 over cost at most 43: long.
            3 => .{ .kind = .teleport, .level_a = level_a, .cell_a = cell_a, .level_b = other, .cell_b = .{ .x = cell_a.x +% 64, .y = cell_a.y +% 64 }, .traversal_cost = random.uintLessThan(u32, 4), .bidirectional = random.boolean() },
            else => .{ .kind = .teleport, .level_a = level_a, .cell_a = cell_a, .level_b = level_a, .cell_b = .{ .x = cell_a.x ^ 1, .y = cell_a.y }, .traversal_cost = 0, .bidirectional = random.boolean() },
        };
    }
}

fn isShortCrossing(link: LevelLink) bool {
    return link.level_a != link.level_b and octileU32(link.cell_a.x, link.cell_a.y, link.cell_b.x, link.cell_b.y) <= linkEdgeCost(link);
}

// Every source level's exit box range lies inside each covered level's arrival window.
fn expectWindowsCover(crossings: []const LevelCrossings) !void {
    for (crossings, 0..) |source, source_level| {
        for (0..source.departing.count) |slot| {
            const exit = source.departing.exits.boxAt(slot);
            var level = exit.l0;
            while (level <= exit.l1) : (level += 1) {
                const window = crossings[@intCast(level)];
                try std.testing.expect(window.arrival_lo <= source_level and source_level <= window.arrival_hi);
            }
        }
    }
}

test "level crossings fold each level-crossing short link into its source level, equal for any batch split, unchanged on a refold, with arrival windows that only grow and cover every exit range" {
    var prng = std.Random.DefaultPrng.init(0x6e6b_0000);
    const random = prng.random();
    const levels: u16 = 6;
    var merged_levels: usize = 0;
    for (0..24) |_| {
        var links: [160]LevelLink = undefined;
        randomCrossingLinks(random, levels, &links);
        var whole: [levels]LevelCrossings = @splat(.{});
        foldLevelCrossings(&whole, &links);
        try expectWindowsCover(&whole);
        // Every folded link sits in one of its source level's pairs at no more than its cost;
        // every source level is a crossing link's.
        var held: [levels]usize = @splat(0);
        for (links) |link| {
            if (!isShortCrossing(link)) continue;
            const cost: i32 = @intCast(linkEdgeCost(link));
            try std.testing.expect(pairHolds(&whole[link.level_a].departing, .{ .from = link.cell_a, .from_level = link.level_a, .to = link.cell_b, .to_level = link.level_b, .cost = cost }));
            held[link.level_a] += 1;
            if (link.bidirectional) {
                try std.testing.expect(pairHolds(&whole[link.level_b].departing, .{ .from = link.cell_b, .from_level = link.level_b, .to = link.cell_a, .to_level = link.level_a, .cost = cost }));
                held[link.level_b] += 1;
            }
        }
        for (whole, held) |crossings, count| {
            try std.testing.expectEqual(count == 0, crossings.departing.count == 0);
            try expectPadsCopyFirst(&crossings.departing);
            merged_levels += @intFromBool(count > long_link_pairs);
            for (0..crossings.departing.count) |slot| {
                const entrance = crossings.departing.entrances.boxAt(slot);
                try std.testing.expect(entrance.l0 == entrance.l1);
            }
        }
        // The same links in random batches: the windows only grow, and the result is the whole
        // fold's.
        var batched: [levels]LevelCrossings = @splat(.{});
        var start: usize = 0;
        while (start < links.len) {
            const end = @min(links.len, start + random.uintAtMost(usize, 40));
            const before = batched;
            foldLevelCrossings(&batched, links[start..end]);
            for (before, batched) |old, new| try std.testing.expect(new.arrival_lo <= old.arrival_lo and new.arrival_hi >= old.arrival_hi);
            try expectWindowsCover(&batched);
            start = end;
        }
        for (whole, batched) |a, b| try std.testing.expect(std.meta.eql(a, b));
        // Folding every link again changes nothing.
        foldLevelCrossings(&batched, &links);
        for (whole, batched) |a, b| try std.testing.expect(std.meta.eql(a, b));
    }
    try std.testing.expect(merged_levels > 0);

    // Long and same-level links fold no crossing.
    var links: [64]LevelLink = undefined;
    randomCrossingLinks(random, levels, &links);
    var none: [levels]LevelCrossings = @splat(.{});
    var kept: usize = 0;
    for (links) |link| {
        if (isShortCrossing(link)) continue;
        links[kept] = link;
        kept += 1;
    }
    foldLevelCrossings(&none, links[0..kept]);
    for (none) |crossings| try std.testing.expect(std.meta.eql(crossings, LevelCrossings{}));
}

test "the pair chain closure equals a scalar shortest-chain reference and keeps every triangle bound" {
    var prng = std.Random.DefaultPrng.init(0x6e69_0000);
    const random = prng.random();
    var chained: usize = 0;
    var clamped: usize = 0;
    for (0..96) |round| {
        var pairs = randomLinkPairs(random);
        // Every few rounds a small world, where chains through further pairs win.
        if (round % 3 == 0) {
            pairs = .{};
            for (0..1 + random.uintLessThan(usize, long_link_pairs + 8)) |_| {
                _ = pairs.insert(.{ .x = random.uintLessThan(u16, 64), .y = random.uintLessThan(u16, 64) }, random.uintLessThan(u16, 4), .{ .x = random.uintLessThan(u16, 64), .y = random.uintLessThan(u16, 64) }, random.uintLessThan(u16, 4), random.intRangeAtMost(i32, 0, 50));
            }
        }
        const rates = if (round % 3 == 0) CrossingRates{ .excess = 41, .cost = 41 } else randomRates(random);
        var chains = PairChains{};
        chains.close(&pairs, rates);
        const count = pairs.count;
        // Bellman-Ford from every pair over edges p -> q weighted by the exit-to-entrance box
        // term plus q's cost.
        var reference: [long_link_pairs][long_link_pairs]i64 = undefined;
        for (0..count) |from| {
            var dist: [long_link_pairs]i64 = @splat(std.math.maxInt(i64));
            dist[from] = 0;
            for (0..count) |_| {
                for (0..count) |via| {
                    if (dist[via] == std.math.maxInt(i64)) continue;
                    for (0..count) |to| {
                        if (to == via) continue;
                        dist[to] = @min(dist[to], dist[via] + boxPairTermScalar(pairs.exits.boxAt(via), pairs.entrances.boxAt(to), rates) + pairs.cost[to]);
                    }
                }
            }
            for (0..count) |to| {
                reference[from][to] = @min(dist[to], long_lane_cap);
                const direct = if (from == to) 0 else boxPairTermScalar(pairs.exits.boxAt(from), pairs.entrances.boxAt(to), rates) + pairs.cost[to];
                chained += @intFromBool(dist[to] < direct);
                clamped += @intFromBool(dist[to] > long_lane_cap);
            }
        }
        for (0..long_link_pairs) |to| {
            for (0..long_link_pairs) |from| {
                const expected = reference[if (from < count) from else 0][if (to < count) to else 0];
                try std.testing.expectEqual(expected, chains.to[to][from]);
            }
        }
        for (0..count) |from| {
            try std.testing.expectEqual(@as(i32, 0), chains.to[from][from]);
            for (0..count) |via| {
                const step = boxPairTermScalar(pairs.exits.boxAt(from), pairs.entrances.boxAt(via), rates) + pairs.cost[via];
                for (0..count) |to| try std.testing.expect(chains.to[to][from] <= step + chains.to[to][via]);
            }
        }
    }
    try std.testing.expect(chained > 0);
    try std.testing.expect(clamped > 0);
}
