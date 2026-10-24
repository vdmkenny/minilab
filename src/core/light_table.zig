//! Shows film on the screen the way it looks on a light table: the scan's own colours, made
//! brighter so that the clearest film (the base of a negative) shows nearly white through its
//! mask. All three channels get the same gain, so a colour negative's orange stays orange. We need
//! this because raw scans are linear, and the base of a colour negative lets through less than
//! half the light even in its brightest channel, so shown as they are, they look dim and brown.

const std = @import("std");
const image = @import("image.zig");
const encode = @import("encode.zig");
const stats = @import("stats.zig");

/// How bright the clearest film shows, as a share of full brightness.
pub const clearest = 0.92;
/// Anything brighter than this is light through a hole in the holder, not film.
pub const open_light = 0.95;
/// The percentile we take as the clearest film, in parts per thousand. The 0.5% of the film that's
/// clearer still is dust holes and scratches.
const clearest_per_mille = 995;
/// Below this transmission the gain stops growing, so an empty or black scan isn't blown up into
/// noise.
const min_transmission = 0.02;
const histogram_bins = 1024;
/// How many index bits the screen table has: fine enough for 8-bit output.
const table_bits = 12;
const table_entries = 1 << table_bits;

/// The gain for film whose clearest part transmits `base`, 0..1 per channel.
pub fn gainForBase(base: [3]f32) f32 {
    return clearest / @max(@max(base[0], base[1]), @max(base[2], min_transmission));
}

/// How far below the clearest film's brightest channel a pixel can be and still count as base,
/// when we measure the base's colour.
const base_band = 0.04;

/// Works out the gain for a scan from its own clearest film, which on a strip is the base between
/// the frames. Light through holes in the holder is left out.
pub fn gainForScan(scan: image.Scan) f32 {
    const level = clearestLevel(scan) orelse return 1;
    return gainForBase(@splat(level));
}

/// Returns the colour of a scan's clearest film, 0..1 per channel (on a strip, that's its base).
/// It's the mean of the pixels whose brightest channel is near the clearest level. Returns null
/// for a scan with no film.
pub fn baseOfScan(scan: image.Scan) ?[3]f32 {
    const level = clearestLevel(scan) orelse return null;
    const top = level + 1.0 / @as(f32, histogram_bins - 1);
    var sum: [3]f64 = @splat(0);
    var count: u64 = 0;
    for (scan.pixels) |p| {
        const brightest = @as(f32, @floatFromInt(@max(@max(p[0], p[1]), p[2]))) / image.full_scale;
        if (brightest >= open_light or brightest > top or brightest < level * (1 - base_band)) continue;
        for (&sum, p) |*s, v| s.* += @floatFromInt(v);
        count += 1;
    }
    if (count == 0) return null;
    var base: [3]f32 = undefined;
    for (&base, sum) |*b, s| b.* = @floatCast(s / @as(f64, @floatFromInt(count)) / image.full_scale);
    return base;
}

/// Returns the brightest channel of a scan's clearest film, 0..1: the level that everything but a
/// few dust holes is darker than. Returns null for a scan with no film.
fn clearestLevel(scan: image.Scan) ?f32 {
    var bins: [histogram_bins]u32 = @splat(0);
    var counted: u64 = 0;
    for (scan.pixels) |p| {
        const brightest = @as(f32, @floatFromInt(@max(@max(p[0], p[1]), p[2]))) / image.full_scale;
        if (brightest >= open_light) continue;
        bins[@intFromFloat(brightest * (histogram_bins - 1))] += 1;
        counted += 1;
    }
    if (counted == 0) return null;
    const Bins = struct {
        counts: *const [histogram_bins]u32,
        pub fn at(b: @This(), i: usize) u64 {
            return b.counts[i];
        }
    };
    const bin = stats.binAtRank(Bins{ .counts = &bins }, histogram_bins, stats.rankAt(counted, clearest_per_mille)) orelse return null;
    return @as(f32, @floatFromInt(bin)) / (histogram_bins - 1);
}

/// Converts `pixels` for the screen into RGBA in `out`, brightened by `gain` and sRGB-encoded.
pub fn toScreen(pixels: []const [3]u16, gain: f32, out: [][4]u8) void {
    std.debug.assert(pixels.len == out.len);
    var table: [table_entries]u8 = undefined;
    for (&table, 0..) |*t, i| {
        const linear = @as(f32, @floatFromInt(i)) / (table_entries - 1) * gain;
        t.* = encode.quantise(u8, encode.srgb(linear));
    }
    const shift = @bitSizeOf(u16) - table_bits;
    for (out, pixels) |*o, p| o.* = .{ table[p[0] >> shift], table[p[1] >> shift], table[p[2] >> shift], std.math.maxInt(u8) };
}

test "a strip's base shows nearly white, and holes in the holder don't count" {
    const gpa = std.testing.allocator;
    var scan: image.Scan = try .init(gpa, 100, 100);
    defer scan.deinit(gpa);
    // Mostly dense frames, a band of base, and a few holes letting the lamp through.
    for (scan.pixels, 0..) |*p, i| {
        const row = i / 100;
        p.* = if (row < 2) .{ 65535, 65535, 65535 } else if (row < 10) .{ 27000, 13000, 8500 } else .{ 9000, 4000, 2500 };
    }
    const gain = gainForScan(scan);
    try std.testing.expectApproxEqRel(clearest * 65535.0 / 27000.0, gain, 0.01);
    var out: [3][4]u8 = undefined;
    toScreen(scan.pixels[500..503], gain, &out);
    // The base's brightest channel ends up near the top, and its orange is kept.
    try std.testing.expect(out[0][0] > 240 and out[0][1] < out[0][0] and out[0][2] < out[0][1]);
    // Its colour comes from the band of base alone.
    const base = baseOfScan(scan).?;
    for (base, [3]f32{ 27000, 13000, 8500 }) |b, expected| try std.testing.expectApproxEqAbs(expected / 65535, b, 1e-4);
}

test "the gain for a known base" {
    try std.testing.expectApproxEqAbs(@as(f32, clearest / 0.4), gainForBase(.{ 0.4, 0.2, 0.13 }), 1e-6);
    try std.testing.expectEqual(clearest / min_transmission, gainForBase(.{ 0, 0, 0 }));
}
