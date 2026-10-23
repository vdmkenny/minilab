//! Medians, percentiles and histogram ranks, which calibration, film base measurement, frame
//! detection and look fitting all take of their measurements.

const std = @import("std");

/// Per mille: thousandths, as the histogram ranks are given.
pub const per_mille = 1000;

/// The median of `values`, sorting them: the middle value, or the mean of the two middle values
/// when there's an even number. Null when there are none.
pub fn median(values: []f32) ?f32 {
    const n = values.len;
    if (n == 0) return null;
    std.mem.sort(f32, values, {}, std.sort.asc(f32));
    return if (n % 2 == 1) values[n / 2] else (values[n / 2 - 1] + values[n / 2]) / 2;
}

/// The value `fraction` (0 to 1) of the way through `sorted`, by nearest rank. `sorted` mustn't be
/// empty.
pub fn quantile(comptime T: type, sorted: []const T, fraction: f32) T {
    const last: f32 = @floatFromInt(sorted.len - 1);
    return sorted[@intFromFloat(@round(std.math.clamp(fraction, 0, 1) * last))];
}

/// The value `fraction` (0 to 1) of the way through `values` by nearest rank, sorting them. Null
/// when there are none.
pub fn percentile(values: []f32, fraction: f32) ?f32 {
    if (values.len == 0) return null;
    std.mem.sort(f32, values, {}, std.sort.asc(f32));
    return quantile(f32, values, fraction);
}

/// The median of each channel of `colours` on its own. `scratch` has room for one value per
/// colour, and only that many colours are used. Null when there are none.
pub fn channelMedian(colours: []const [3]f32, scratch: []f32) ?[3]f32 {
    const count = @min(colours.len, scratch.len);
    if (count == 0) return null;
    var result: [3]f32 = undefined;
    for (&result, 0..) |*r, channel| {
        for (scratch[0..count], colours[0..count]) |*s, colour| s.* = colour[channel];
        r.* = median(scratch[0..count]).?;
    }
    return result;
}

/// The rank, from 0, of the value `thousandths` per mille of the way through `count` values.
pub fn rankAt(count: u64, thousandths: u64) u64 {
    return @min(count -| 1, count * thousandths / per_mille);
}

/// The bin of a histogram that holds the value at `rank` (from 0) of the values it counts, or null
/// when it counts fewer. `histogram.at(i)` gives bin `i`'s count, for `i` below `bins`.
pub fn binAtRank(histogram: anytype, bins: usize, rank: u64) ?usize {
    var seen: u64 = 0;
    for (0..bins) |i| {
        seen += histogram.at(i);
        if (seen > rank) return i;
    }
    return null;
}

test "medians take the middle, or the mean of the two middle values" {
    var odd = [_]f32{ 3, 1, 2 };
    try std.testing.expectEqual(@as(?f32, 2), median(&odd));
    var even = [_]f32{ 4, 1, 3, 2 };
    try std.testing.expectEqual(@as(?f32, 2.5), median(&even));
    try std.testing.expectEqual(@as(?f32, null), median(&.{}));
}

test "percentiles take the nearest rank" {
    var values = [_]f32{ 5, 1, 4, 2, 3 };
    try std.testing.expectEqual(@as(?f32, 3), percentile(&values, 0.5));
    try std.testing.expectEqual(@as(?f32, 5), percentile(&values, 1));
    try std.testing.expectEqual(@as(?f32, 1), percentile(&values, 0));
}

test "each channel has its own median" {
    const colours = [_][3]f32{ .{ 1, 30, 200 }, .{ 3, 10, 100 }, .{ 2, 20, 300 } };
    var scratch: [colours.len]f32 = undefined;
    try std.testing.expectEqual([3]f32{ 2, 20, 200 }, channelMedian(&colours, &scratch).?);
}

test "a histogram's rank falls in the bin that holds it" {
    const Bins = struct {
        counts: []const u32,
        pub fn at(bins: @This(), i: usize) u64 {
            return bins.counts[i];
        }
    };
    const histogram: Bins = .{ .counts = &.{ 2, 0, 3, 5 } };
    try std.testing.expectEqual(@as(?usize, 0), binAtRank(histogram, 4, 1));
    try std.testing.expectEqual(@as(?usize, 2), binAtRank(histogram, 4, 2));
    try std.testing.expectEqual(@as(?usize, 3), binAtRank(histogram, 4, 9));
    try std.testing.expectEqual(@as(?usize, null), binAtRank(histogram, 4, 10));
    try std.testing.expectEqual(@as(u64, 5), rankAt(10, 500));
    try std.testing.expectEqual(@as(u64, 9), rankAt(10, 1000));
}
