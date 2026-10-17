// Copyright (c) 2026 Hammer Forged Games
// All rights reserved.
// Licensed under the MIT License - see LICENSE file for details

//! The banded sort's shared pieces: splitters chosen from a fixed sample cut the key space
//! into `band_count` bands; each fill range places its elements into its staging window by
//! band; each sort range owns the bands starting in it and gathers every window's segment
//! of them, so a band has one owner and the ranges' work follows their element counts.

const std = @import("std");
const pdqSort = @import("../../core/sort.zig").pdq;
const PaddedSlot = @import("../../app/thread_system.zig").PaddedSlot;
const thread_shared_record_alignment = @import("../../app/thread_system.zig").thread_shared_record_alignment;

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

comptime {
    std.debug.assert(@sizeOf(PaddedSlot(BandOffsets)) % thread_shared_record_alignment == 0);
}

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
        /// band, and returns the band offsets. Scalar: a counting scatter, the band search
        /// run twice per element rather than stored (a six-step binary search).
        pub fn placeByBand(splitters: *const Splitters, elements: []const Element, window: []Element) BandOffsets {
            std.debug.assert(window.len >= elements.len);
            var offsets: [band_count + 1]u32 = @splat(0);
            for (elements) |element| offsets[bandOfKey(splitters, keyOf(element)) + 1] += 1;
            for (1..band_count + 1) |band| offsets[band] += offsets[band - 1];
            var cursor = offsets;
            for (elements) |element| {
                const band = bandOfKey(splitters, keyOf(element));
                window[cursor[band]] = element;
                cursor[band] += 1;
            }
            return .{ .offsets = offsets };
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
