// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The banded sort's shared pieces: splitters chosen from a fixed sample cut the key space
//! into `band_count` bands; each fill range places its elements into its staging window by
//! band; each sort range owns the bands starting in it and gathers every window's segment
//! of them, so a band has one owner and the ranges' work follows their element counts.

const std = @import("std");
const pdqSort = @import("../../core/sort.zig").pdq;
const BatchStats = @import("../../app/thread_system.zig").BatchStats;
const runtime_perf_log = @import("../../app/runtime_perf_log.zig");
const Dispatch = @import("../../app/thread_system.zig").Dispatch;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const ParallelRange = @import("../../app/thread_system.zig").ParallelRange;
const SlotList = @import("../../app/thread_system.zig").SlotList;
const WorkerId = @import("../../app/thread_system.zig").WorkerId;
const runShaped = @import("../../app/thread_system.zig").runShaped;
const setSlotCount = @import("../../app/thread_system.zig").setSlotCount;
const StageShape = @import("../../app/thread_system.zig").StageShape;

/// Partition width of a banded sort, not a capacity: the sorted result is the same for any
/// band count and splitters, and a range's band histogram stays on the worker stack.
pub const band_count: usize = 64;
/// Elements sampled per sort for the band splitters: four per band, a fixed count. Balance
/// only.
pub const splitter_sample_count: usize = 4 * band_count;
// The golden ratio's fractional part in 0.64 fixed point.
const sample_fraction_step: u64 = 0x9E3779B97F4A7C15;

/// One fill range's elements before each band: band b's are `[offsets[b], offsets[b + 1])`
/// of its staging window.
pub const BandOffsets = struct {
    offsets: [band_count + 1]u32 = @splat(0),
};

/// Sampled elements for `slot_count` slots: every slot when they fit the sample.
pub fn sampleCount(slot_count: usize) usize {
    return @min(splitter_sample_count, slot_count);
}

/// The slot sample `sample` (below `sampleCount(slot_count)`) reads: the sample itself when
/// every slot fits, else the slot at the sample's golden-ratio fraction of the slot count,
/// which shares no period with a periodic slot order.
pub fn sampleSlot(sample: usize, slot_count: usize) usize {
    std.debug.assert(sample < sampleCount(slot_count));
    if (slot_count <= splitter_sample_count) return sample;
    const fraction = @as(u64, @intCast(sample + 1)) *% sample_fraction_step;
    // The high word of fraction * slot_count is below slot_count.
    return @intCast(std.math.mulWide(u64, fraction, slot_count) >> 64);
}

/// Ownership of nonempty bands by the ranges of a partition of `[0, starts[band_count])`:
/// a range owns every nonempty band whose start lies in it, so each band has exactly one
/// owner for any range split.
pub const OwnedBands = struct {
    starts: *const [band_count + 1]u32,
    band: usize,
    range_end: usize,

    /// `starts` nondecreasing: band b covers `[starts[b], starts[b + 1])`.
    pub fn init(starts: *const [band_count + 1]u32, range_start: usize, range_end: usize) OwnedBands {
        std.debug.assert(range_start <= range_end and range_end <= starts[band_count]);
        return .{
            .starts = starts,
            .band = std.sort.partitionPoint(u32, starts[0..band_count], range_start, startsBefore),
            .range_end = range_end,
        };
    }

    pub fn next(self: *OwnedBands) ?usize {
        while (self.band < band_count and self.starts[self.band] < self.range_end) {
            const band = self.band;
            self.band += 1;
            if (self.starts[band] != self.starts[band + 1]) return band;
        }
        return null;
    }
};

fn startsBefore(range_start: usize, band_start: u32) bool {
    return band_start < range_start;
}

/// The batches of one banded sort's place and sort stages, kept only with
/// `runtime_perf_log.enabled` (zero-sized otherwise); empty for a stage that did not run.
pub const SortBatches = if (runtime_perf_log.enabled) struct {
    place: BatchStats = .{},
    sort: BatchStats = .{},
} else struct {};

// Each band's start in the sorted order: band b's elements over every fill range precede
// band b + 1's. O(ranges × bands).
fn sumBandOffsets(offsets: []const PaddedSlot(BandOffsets)) [band_count + 1]u32 {
    var starts: [band_count + 1]u32 = @splat(0);
    for (offsets) |slot| {
        for (&starts, slot.value.offsets) |*start, offset| start.* += offset;
    }
    return starts;
}

// The segment of a concatenation holding `position`: the last whose start is at or
// before it. `segment_starts` is nondecreasing, one start per segment.
fn segmentAt(segment_starts: []const usize, position: usize) usize {
    std.debug.assert(segment_starts.len != 0 and segment_starts[0] <= position);
    return std.sort.partitionPoint(usize, segment_starts, position, startAtOrBefore) - 1;
}

fn startAtOrBefore(position: usize, segment_start: usize) bool {
    return segment_start <= position;
}

/// The banded sort over `Element`s keyed by `keyOf`, an unsigned integer.
pub fn BandedSort(comptime Element: type, comptime keyOf: anytype) type {
    const Key = @typeInfo(@TypeOf(keyOf)).@"fn".return_type.?;
    comptime std.debug.assert(@typeInfo(Key).int.signedness == .unsigned);
    return struct {
        pub const Splitters = [band_count - 1]Key;
        /// A splitter past every key: its band and every later one stay empty.
        pub const max_key: Key = std.math.maxInt(Key);

        /// `key`'s band among nondecreasing `splitters`: the count at or below it.
        pub fn bandOfKey(splitters: *const Splitters, key: Key) usize {
            return std.sort.partitionPoint(Key, splitters, key, splitterAtOrBelow);
        }

        fn splitterAtOrBelow(key: Key, splitter: Key) bool {
            return splitter <= key;
        }

        /// The band quantiles of `samples` (sorted in place): every splitter `max_key` when
        /// there are none.
        pub fn splittersFromSamples(samples: []Key) Splitters {
            var splitters: Splitters = @splat(max_key);
            if (samples.len == 0) return splitters;
            pdqSort(Key, samples, {}, keyLessThan);
            for (&splitters, 1..) |*splitter, band| splitter.* = samples[band * samples.len / band_count];
            return splitters;
        }

        fn keyLessThan(_: void, lhs: Key, rhs: Key) bool {
            return lhs < rhs;
        }

        /// Places `elements` into `window` by band of `splitters`, in input order within a
        /// band, and returns the band offsets.
        pub fn placeByBand(splitters: *const Splitters, elements: []const Element, window: []Element) BandOffsets {
            return placeSegmentsByBand(splitters, &.{elements}, &.{0}, 0, elements.len, window);
        }

        // Places elements `[start, end)` of the concatenation of `segments` into `window`
        // by band of `splitters`, in concatenation order within a band, and returns the
        // band offsets. `segment_starts[s]` is the element count before segment s. Scalar:
        // a counting scatter, the band search run twice per element rather than stored (a
        // six-step binary search).
        fn placeSegmentsByBand(splitters: *const Splitters, segments: []const []const Element, segment_starts: []const usize, start: usize, end: usize, window: []Element) BandOffsets {
            std.debug.assert(segments.len == segment_starts.len);
            std.debug.assert(start <= end and window.len >= end - start);
            var offsets: [band_count + 1]u32 = @splat(0);
            if (start == end) return .{ .offsets = offsets };
            const first = segmentAt(segment_starts, start);
            var pieces = SegmentPieces{ .segments = segments, .segment_starts = segment_starts, .segment = first, .position = start, .end = end };
            while (pieces.next()) |piece| {
                for (piece) |element| offsets[bandOfKey(splitters, keyOf(element)) + 1] += 1;
            }
            for (1..band_count + 1) |band| offsets[band] += offsets[band - 1];
            var cursor = offsets;
            pieces = .{ .segments = segments, .segment_starts = segment_starts, .segment = first, .position = start, .end = end };
            while (pieces.next()) |piece| {
                for (piece) |element| {
                    const band = bandOfKey(splitters, keyOf(element));
                    window[cursor[band]] = element;
                    cursor[band] += 1;
                }
            }
            return .{ .offsets = offsets };
        }

        // The concatenation's elements `[position, end)`, one segment's share per `next`.
        const SegmentPieces = struct {
            segments: []const []const Element,
            segment_starts: []const usize,
            segment: usize,
            position: usize,
            end: usize,

            fn next(self: *SegmentPieces) ?[]const Element {
                while (self.position < self.end) {
                    std.debug.assert(self.segment < self.segments.len);
                    const segment = self.segments[self.segment];
                    const base = self.segment_starts[self.segment];
                    const piece_end = @min(self.end, base + segment.len);
                    self.segment += 1;
                    if (piece_end <= self.position) continue;
                    const piece = segment[self.position - base .. piece_end - base];
                    self.position = piece_end;
                    return piece;
                }
                return null;
            }
        };

        // Band splitters sampled from the concatenation of `segments` (`total` elements;
        // `segment_starts` as in `placeSegmentsByBand`).
        fn segmentSplitters(segments: []const []const Element, segment_starts: []const usize, total: usize) Splitters {
            var samples: [splitter_sample_count]Key = undefined;
            const count = sampleCount(total);
            for (samples[0..count], 0..) |*sample, index| {
                const position = sampleSlot(index, total);
                const segment = segmentAt(segment_starts, position);
                sample.* = keyOf(segments[segment][position - segment_starts[segment]]);
            }
            return splittersFromSamples(samples[0..count]);
        }

        /// Sorts the concatenation of `segments` by key into `dest` (its length): the place
        /// stage under `place_dispatch` band-places each range's elements into `staging` and
        /// its offsets into `offsets`, then the sort stage under `sort_dispatch` gathers and
        /// sorts each band. Each stage selects and records through its own dispatch's tuner.
        /// `dest` may alias a segment: the place copies every element into `staging` first.
        /// Allocates only to grow `staging` and `offsets`, on the calling thread before each
        /// dispatch; at most one element runs no stage.
        pub fn sortSegments(
            allocator: std.mem.Allocator,
            place_dispatch: Dispatch,
            sort_dispatch: Dispatch,
            segments: []const []const Element,
            segment_starts: []const usize,
            range_alignment_items: usize,
            staging: *std.ArrayList(Element),
            offsets: *SlotList(BandOffsets),
            dest: []Element,
        ) error{OutOfMemory}!SortBatches {
            const total = dest.len;
            std.debug.assert(segment_starts.len == segments.len);
            std.debug.assert(summedLength(segments) == total);
            if (total <= 1) {
                // Assigned, not copied: `dest` may be the one segment.
                for (segments) |segment| {
                    if (segment.len != 0) dest[0] = segment[0];
                }
                return .{};
            }
            try staging.ensureTotalCapacity(allocator, total);
            staging.items.len = total;
            const place = StageShape.select(place_dispatch, total, range_alignment_items);
            try offsets.ensureTotalCapacity(allocator, place.range_count);
            setSlotCount(BandOffsets, offsets, place.range_count);
            var place_job = PlaceJob{
                .splitters = segmentSplitters(segments, segment_starts, total),
                .segments = segments,
                .segment_starts = segment_starts,
                .staging = staging.items,
                .items_per_range = place.items_per_range,
                .offsets = offsets.items,
            };
            const place_batch = runShaped(place_dispatch, place, total, range_alignment_items, &place_job, placeJob);
            const sort = StageShape.select(sort_dispatch, total, range_alignment_items);
            var sort_job = SortJob{
                .source = .{ .staging = staging.items, .band_offsets = offsets.items, .window_stride = place.items_per_range },
                .dest = dest,
                .starts = sumBandOffsets(offsets.items),
                .range_count = sort.range_count,
            };
            const sort_batch = runShaped(sort_dispatch, sort, total, range_alignment_items, &sort_job, sortJob);
            return if (comptime runtime_perf_log.enabled) .{ .place = place_batch, .sort = sort_batch } else .{};
        }

        // One fill range of a banded sort: places its elements of the concatenation of
        // `segments` into its `staging` window by band and writes its band offsets.
        const PlaceJob = struct {
            splitters: Splitters,
            segments: []const []const Element,
            segment_starts: []const usize,
            staging: []Element,
            items_per_range: usize,
            offsets: []PaddedSlot(BandOffsets),
        };

        fn placeJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
            const job: *PlaceJob = @ptrCast(@alignCast(context));
            std.debug.assert(range.index < job.offsets.len);
            std.debug.assert(range.start == range.index * job.items_per_range);
            std.debug.assert(range.end <= job.staging.len);
            job.offsets[range.index].value = placeSegmentsByBand(&job.splitters, job.segments, job.segment_starts, range.start, range.end, job.staging[range.start..range.end]);
        }

        // One sort range of a banded sort: gathers each band it owns from `source` into
        // `dest` at the band's start and sorts it by key. Keys are distinct, so the order is
        // the same for any partition.
        const SortJob = struct {
            source: WindowSource,
            dest: []Element,
            starts: [band_count + 1]u32,
            range_count: usize,
        };

        fn sortJob(context: *anyopaque, range: ParallelRange, _: WorkerId) void {
            const job: *SortJob = @ptrCast(@alignCast(context));
            const total = job.starts[band_count];
            std.debug.assert(range.index < job.range_count);
            std.debug.assert(range.end <= total and total <= job.dest.len);
            var owned = OwnedBands.init(&job.starts, range.start, range.end);
            while (owned.next()) |band| {
                const start = job.starts[band];
                const end = job.starts[band + 1];
                const gathered = gatherBand(job.dest[start..end], band, .{job.source});
                std.debug.assert(gathered == end - start);
                pdqSort(Element, job.dest[start..end], {}, elementKeyLess);
            }
        }

        fn summedLength(segments: []const []const Element) usize {
            var total: usize = 0;
            for (segments) |segment| total += segment.len;
            return total;
        }

        fn elementKeyLess(_: void, lhs: Element, rhs: Element) bool {
            return keyOf(lhs) < keyOf(rhs);
        }

        /// Fill ranges' band-placed windows: range r's window starts at
        /// `r * window_stride` of `staging`, its offsets at `band_offsets[r]`.
        pub const WindowSource = struct {
            staging: []const Element,
            band_offsets: []const PaddedSlot(BandOffsets),
            window_stride: usize,

            pub fn rangeCount(self: WindowSource) usize {
                return self.band_offsets.len;
            }

            /// Range `range_index`'s elements of `band`.
            pub fn segment(self: WindowSource, range_index: usize, band: usize) []const Element {
                const offsets = &self.band_offsets[range_index].value.offsets;
                const window = self.staging[range_index * self.window_stride ..];
                return window[offsets[band]..offsets[band + 1]];
            }
        };

        /// Copies `band`'s segment of every range of each source in `sources` (a tuple of
        /// values with `rangeCount()` and `segment(range, band)`), source by source in range
        /// order, into `dest`; returns the count. Scalar: segment copies.
        pub fn gatherBand(dest: []Element, band: usize, sources: anytype) usize {
            var cursor: usize = 0;
            inline for (sources) |source| {
                for (0..source.rangeCount()) |range_index| {
                    const piece = source.segment(range_index, band);
                    @memcpy(dest[cursor..][0..piece.len], piece);
                    cursor += piece.len;
                }
            }
            return cursor;
        }
    };
}

// ---- Tests --------------------------------------------------------------------

const testing = std.testing;
const AdaptiveWorkTuner = @import("../../app/thread_system.zig").AdaptiveWorkTuner;
const StageControls = @import("../../app/thread_system.zig").StageControls;
const ThreadSystem = @import("../../app/thread_system.zig").ThreadSystem;

const TestElement = struct { key: u64, tag: u32 };

fn testKeyOf(element: TestElement) u64 {
    return element.key;
}

const TestSort = BandedSort(TestElement, testKeyOf);

// Nondecreasing splitters over [0, key_limit), the last `tail_max` of them past every key.
fn testSplitters(random: std.Random, key_limit: u64, tail_max: usize) TestSort.Splitters {
    var splitters: TestSort.Splitters = undefined;
    for (&splitters) |*splitter| splitter.* = random.uintLessThan(u64, key_limit);
    std.sort.pdq(u64, &splitters, {}, std.sort.asc(u64));
    for (splitters[splitters.len - tail_max ..]) |*splitter| splitter.* = TestSort.max_key;
    return splitters;
}

fn bandLessThan(splitters: *const TestSort.Splitters, lhs: TestElement, rhs: TestElement) bool {
    return TestSort.bandOfKey(splitters, lhs.key) < TestSort.bandOfKey(splitters, rhs.key);
}

test "band placement equals a stable sort by band, with each band's offsets" {
    var prng = std.Random.DefaultPrng.init(0x62_61_6e_64);
    const random = prng.random();
    for ([_]usize{ 0, 1, 7, 64, 300 }) |count| {
        for ([_]u64{ 4, 1000, std.math.maxInt(u64) }) |key_limit| {
            const splitters = testSplitters(random, key_limit, count % 9);
            const elements = try testing.allocator.alloc(TestElement, count);
            defer testing.allocator.free(elements);
            for (elements, 0..) |*element, index| element.* = .{ .key = random.uintLessThan(u64, key_limit), .tag = @intCast(index) };
            const window = try testing.allocator.alloc(TestElement, count);
            defer testing.allocator.free(window);
            const placed = TestSort.placeByBand(&splitters, elements, window);

            const expected = try testing.allocator.dupe(TestElement, elements);
            defer testing.allocator.free(expected);
            std.sort.insertion(TestElement, expected, &splitters, bandLessThan);
            try testing.expectEqualSlices(TestElement, expected, window);
            try testing.expectEqual(@as(u32, 0), placed.offsets[0]);
            try testing.expectEqual(@as(u32, @intCast(count)), placed.offsets[band_count]);
            for (0..band_count) |band| {
                for (window[placed.offsets[band]..placed.offsets[band + 1]]) |element| {
                    try testing.expectEqual(band, TestSort.bandOfKey(&splitters, element.key));
                }
            }
        }
    }
}

test "placing several segments by band matches placing their concatenation" {
    var prng = std.Random.DefaultPrng.init(0x73_65_67);
    const random = prng.random();
    const splitters = testSplitters(random, 300, 5);
    var elements: [120]TestElement = undefined;
    for (&elements, 0..) |*element, index| element.* = .{ .key = random.uintLessThan(u64, 300), .tag = @intCast(index) };
    // Segment lengths 0, 17, 0, 40, 1, 62: empty segments at the front and inside.
    const lengths = [_]usize{ 0, 17, 0, 40, 1, 62 };
    var segments: [lengths.len][]const TestElement = undefined;
    var segment_starts: [lengths.len]usize = undefined;
    var at: usize = 0;
    for (lengths, 0..) |len, index| {
        segments[index] = elements[at..][0..len];
        segment_starts[index] = at;
        at += len;
    }
    // Every window of the concatenation, including ones that start or end inside a segment
    // or on a segment boundary, places like the same elements as one slice.
    for ([_][2]usize{ .{ 0, 120 }, .{ 0, 0 }, .{ 5, 17 }, .{ 17, 57 }, .{ 16, 58 }, .{ 57, 58 }, .{ 30, 120 }, .{ 119, 120 } }) |window_bounds| {
        const start = window_bounds[0];
        const end = window_bounds[1];
        var expected: [120]TestElement = undefined;
        var actual: [120]TestElement = undefined;
        const want = TestSort.placeByBand(&splitters, elements[start..end], expected[0 .. end - start]);
        const got = TestSort.placeSegmentsByBand(&splitters, &segments, &segment_starts, start, end, actual[0 .. end - start]);
        try testing.expectEqual(want.offsets, got.offsets);
        try testing.expectEqualSlices(TestElement, expected[0 .. end - start], actual[0 .. end - start]);
    }
    // Splitters sampled from the segments are the ones sampled from the concatenation.
    var keys: [120]u64 = undefined;
    for (&keys, elements) |*key, element| key.* = element.key;
    var samples: [splitter_sample_count]u64 = undefined;
    for (0..sampleCount(120)) |sample| samples[sample] = keys[sampleSlot(sample, 120)];
    try testing.expectEqual(TestSort.splittersFromSamples(samples[0..sampleCount(120)]), TestSort.segmentSplitters(&segments, &segment_starts, 120));
}

test "every nonempty band has exactly one owner for any range split" {
    var prng = std.Random.DefaultPrng.init(0x6f_77_6e);
    const random = prng.random();
    for (0..32) |_| {
        // Random band sizes, many of them empty, the first and last bands included.
        var starts: [band_count + 1]u32 = undefined;
        starts[0] = 0;
        for (1..band_count + 1) |band| starts[band] = starts[band - 1] + if (random.boolean()) 0 else random.uintLessThan(u32, 40);
        const total: usize = starts[band_count];
        for ([_]usize{ 1, 3, 16, 64, 1000 }) |items_per_range| {
            var owners: [band_count]u32 = @splat(0);
            var range_start: usize = 0;
            while (true) {
                const range_end = @min(total, range_start + items_per_range);
                var owned = OwnedBands.init(&starts, range_start, range_end);
                while (owned.next()) |band| {
                    try testing.expect(starts[band] >= range_start and starts[band] < range_end);
                    owners[band] += 1;
                }
                if (range_end == total) break;
                range_start = range_end;
            }
            for (0..band_count) |band| {
                const expected: u32 = if (starts[band] != starts[band + 1]) 1 else 0;
                try testing.expectEqual(expected, owners[band]);
            }
        }
    }
}

test "a band's gather takes every source's ranges in order" {
    var prng = std.Random.DefaultPrng.init(0x67_61_74);
    const random = prng.random();
    const splitters = testSplitters(random, 500, 3);
    const range_count = 5;
    const stride = 40;
    var elements: [range_count * stride]TestElement = undefined;
    for (&elements, 0..) |*element, index| element.* = .{ .key = random.uintLessThan(u64, 500), .tag = @intCast(index) };
    // Two sources over the same ranges: strided windows, each range filled to a varying length.
    var windows: [2][range_count * stride]TestElement = undefined;
    var offsets: [2][range_count]PaddedSlot(BandOffsets) = undefined;
    var lengths: [2][range_count]usize = undefined;
    for (0..2) |source| for (0..range_count) |range_index| {
        const len = random.uintAtMost(usize, stride);
        lengths[source][range_index] = len;
        const filled = elements[range_index * stride ..][0..len];
        offsets[source][range_index] = .{ .value = TestSort.placeByBand(&splitters, filled, windows[source][range_index * stride ..][0..stride]) };
    };
    const sources = .{
        TestSort.WindowSource{ .staging = &windows[0], .band_offsets = &offsets[0], .window_stride = stride },
        TestSort.WindowSource{ .staging = &windows[1], .band_offsets = &offsets[1], .window_stride = stride },
    };
    var gathered_total: usize = 0;
    for (0..band_count) |band| {
        var dest: [2 * range_count * stride]TestElement = undefined;
        const count = TestSort.gatherBand(&dest, band, sources);
        gathered_total += count;
        // The expected order: source by source, range by range, input order within a range.
        var expected: [2 * range_count * stride]TestElement = undefined;
        var expected_count: usize = 0;
        for (0..2) |source| for (0..range_count) |range_index| {
            for (elements[range_index * stride ..][0..lengths[source][range_index]]) |element| {
                if (TestSort.bandOfKey(&splitters, element.key) != band) continue;
                expected[expected_count] = element;
                expected_count += 1;
            }
        };
        try testing.expectEqualSlices(TestElement, expected[0..expected_count], dest[0..count]);
    }
    var filled_total: usize = 0;
    for (lengths) |source| for (source) |len| {
        filled_total += len;
    };
    try testing.expectEqual(filled_total, gathered_total);
}

test "splitters are the sorted samples' band quantiles, all past every key with no sample" {
    try testing.expectEqual(@as(TestSort.Splitters, @splat(TestSort.max_key)), TestSort.splittersFromSamples(&.{}));
    var samples: [splitter_sample_count]u64 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = @intCast((index * 7919) % splitter_sample_count);
    const splitters = TestSort.splittersFromSamples(&samples);
    for (splitters[0 .. band_count - 2], splitters[1..]) |lower, upper| try testing.expect(lower <= upper);
    for (splitters, 1..) |splitter, band| try testing.expectEqual(@as(u64, @intCast(band * splitter_sample_count / band_count)), splitter);
}

test "sample slots past the sample follow the golden-ratio sequence from its first step" {
    // floor(frac((sample + 1) * phi) * slot_count), from the accumulated 0.64 fixed point.
    const expected = [_]struct { slot_count: usize, sample: usize, slot: usize }{
        .{ .slot_count = 1000, .sample = 0, .slot = 618 },
        .{ .slot_count = 1000, .sample = 1, .slot = 236 },
        .{ .slot_count = 1000, .sample = 2, .slot = 854 },
        .{ .slot_count = 1000, .sample = 3, .slot = 472 },
        .{ .slot_count = 1000, .sample = 255, .slot = 216 },
        .{ .slot_count = 1 << 20, .sample = 0, .slot = 648055 },
        .{ .slot_count = 1 << 20, .sample = 255, .slot = 227227 },
    };
    for (expected) |pinned| try testing.expectEqual(pinned.slot, sampleSlot(pinned.sample, pinned.slot_count));
}

test "sample slots cover every slot when they fit and stay below the slot count past it" {
    for ([_]usize{ 1, 5, splitter_sample_count }) |slot_count| {
        try testing.expectEqual(slot_count, sampleCount(slot_count));
        for (0..slot_count) |sample| try testing.expectEqual(sample, sampleSlot(sample, slot_count));
    }
    for ([_]usize{ splitter_sample_count + 1, 10_000, 1 << 40 }) |slot_count| {
        try testing.expectEqual(splitter_sample_count, sampleCount(slot_count));
        for (0..splitter_sample_count) |sample| try testing.expect(sampleSlot(sample, slot_count) < slot_count);
    }
}

// Sorts `segments` through both stages on `thread_system` at fixed 8-item ranges.
fn sortTestSegments(thread_system: *ThreadSystem, allocator: std.mem.Allocator, tuners: *[2]AdaptiveWorkTuner, segments: []const []const TestElement, segment_starts: []const usize, staging: *std.ArrayList(TestElement), offsets: *SlotList(BandOffsets), dest: []TestElement) !void {
    const controls = StageControls{ .items_per_range = 8, .max_worker_threads = thread_system.workerThreadCount(), .adaptive = false };
    _ = try TestSort.sortSegments(allocator, Dispatch.init(thread_system, &tuners[0], controls), Dispatch.init(thread_system, &tuners[1], controls), segments, segment_starts, 8, staging, offsets, dest);
}

test "segments sorted through the place and sort stages match a sort of their concatenation, inline and on 2 workers, and allocate nothing warm" {
    var prng = std.Random.DefaultPrng.init(0x73_6f_72_74);
    const random = prng.random();
    var elements: [150]TestElement = undefined;
    // Distinct keys in random order.
    for (&elements, 0..) |*element, index| element.* = .{ .key = @as(u64, index) * 7919 % 1000, .tag = @intCast(index) };
    random.shuffle(TestElement, &elements);
    var expected = elements;
    std.sort.pdq(TestElement, &expected, {}, struct {
        fn less(_: void, lhs: TestElement, rhs: TestElement) bool {
            return lhs.key < rhs.key;
        }
    }.less);
    const segments = [_][]const TestElement{ elements[0..0], elements[0..70], elements[70..71], elements[71..] };
    const segment_starts = [_]usize{ 0, 0, 70, 71 };
    for ([_]usize{ 0, 2 }) |workers| {
        var thread_system = try ThreadSystem.init(testing.allocator, testing.io, .{ .max_worker_threads = workers });
        defer thread_system.deinit();
        var tuners: [2]AdaptiveWorkTuner = @splat(AdaptiveWorkTuner.init(.{}));
        var staging: std.ArrayList(TestElement) = .empty;
        defer staging.deinit(testing.allocator);
        var offsets: SlotList(BandOffsets) = .empty;
        defer offsets.deinit(testing.allocator);
        var dest: [150]TestElement = undefined;
        try sortTestSegments(&thread_system, testing.allocator, &tuners, &segments, &segment_starts, &staging, &offsets, &dest);
        try testing.expectEqualSlices(TestElement, &expected, &dest);
        // Warm: the same sort grows nothing.
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0, .resize_fail_index = 0 });
        dest = undefined;
        try sortTestSegments(&thread_system, failing.allocator(), &tuners, &segments, &segment_starts, &staging, &offsets, &dest);
        try testing.expectEqual(@as(usize, 0), failing.allocations);
        try testing.expectEqualSlices(TestElement, &expected, &dest);
        // One element runs no stage, so the staging and band offsets keep the last sort's;
        // none leaves `dest` empty.
        const staged = staging.items.len;
        const ranges = offsets.items.len;
        var one: [1]TestElement = undefined;
        try sortTestSegments(&thread_system, failing.allocator(), &tuners, &.{ elements[0..0], elements[5..6] }, &.{ 0, 0 }, &staging, &offsets, &one);
        try testing.expectEqual(elements[5], one[0]);
        try testing.expectEqual(staged, staging.items.len);
        try testing.expectEqual(ranges, offsets.items.len);
    }
}
