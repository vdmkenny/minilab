//! Reduces images by area, to any size. Each output pixel is the mean of the input it covers, and
//! an input pixel cut by an output pixel's edge counts by the share of it that's inside. That's
//! what a scanner at the lower resolution would have seen, without the aliasing you get from
//! picking every nth pixel, and without `image.downscale`'s limit to whole factors.
//!
//! The work is done in two passes, across and then down, in `f32`.

const std = @import("std");
const image = @import("image.zig");

pub const Size = struct {
    width: usize,
    height: usize,
};

/// The size of a `width` × `height` image reduced so that its longer side is `long_edge`, keeping
/// its proportions as closely as whole pixels allow. An image that's already no longer than that
/// keeps its size: this only ever reduces.
pub fn fitted(width: usize, height: usize, long_edge: usize) Size {
    const longest = @max(width, height);
    if (longest <= long_edge or longest == 0) return .{ .width = width, .height = height };
    const scale = @as(f64, @floatFromInt(long_edge)) / @as(f64, @floatFromInt(longest));
    return .{
        .width = if (width == longest) long_edge else side(width, scale),
        .height = if (height == longest) long_edge else side(height, scale),
    };
}

fn side(length: usize, scale: f64) usize {
    return @max(1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(length)) * scale))));
}

/// How each output pixel along one axis draws on the input: the first input pixel it covers, and
/// weights for that one and each of the next `taps - 1`, adding up to 1.
const Axis = struct {
    first: []usize,
    weights: []f32,
    taps: usize,

    fn init(gpa: std.mem.Allocator, from: usize, to: usize) !Axis {
        std.debug.assert(to > 0 and to <= from);
        const step = @as(f64, @floatFromInt(from)) / @as(f64, @floatFromInt(to));
        // An output pixel `step` wide can touch one more input pixel than it covers whole.
        const taps: usize = @as(usize, @intFromFloat(@ceil(step))) + 1;
        const first = try gpa.alloc(usize, to);
        errdefer gpa.free(first);
        const weights = try gpa.alloc(f32, to * taps);
        errdefer gpa.free(weights);
        for (first, 0..) |*start, i| {
            const left = @as(f64, @floatFromInt(i)) * step;
            const right = if (i + 1 == to) @as(f64, @floatFromInt(from)) else left + step;
            start.* = @min(@as(usize, @intFromFloat(@floor(left))), from - 1);
            for (weights[i * taps ..][0..taps], 0..) |*w, k| {
                const j = start.* + k;
                const pixel_left = @as(f64, @floatFromInt(j));
                if (j >= from or pixel_left >= right) {
                    w.* = 0;
                    continue;
                }
                const overlap = @min(right, pixel_left + 1) - @max(left, pixel_left);
                w.* = @floatCast(@max(overlap, 0) / (right - left));
            }
        }
        return .{ .first = first, .weights = weights, .taps = taps };
    }

    fn deinit(axis: *Axis, gpa: std.mem.Allocator) void {
        gpa.free(axis.first);
        gpa.free(axis.weights);
        axis.* = undefined;
    }

    fn of(axis: Axis, i: usize) []const f32 {
        return axis.weights[i * axis.taps ..][0..axis.taps];
    }
};

const channels = image.channel_count;

/// Reduces `source` to `size` by area. Neither side may grow. Integer samples are rounded to the
/// nearest value, and float samples are kept as they come out.
pub fn reduce(comptime Sample: type, gpa: std.mem.Allocator, source: image.Image([channels]Sample), size: Size) !image.Image([channels]Sample) {
    std.debug.assert(size.width <= source.width and size.height <= source.height);
    var across: Axis = try .init(gpa, source.width, size.width);
    defer across.deinit(gpa);
    var down: Axis = try .init(gpa, source.height, size.height);
    defer down.deinit(gpa);

    // Across: squeeze every input row to the output's width.
    var narrow: image.Image([channels]f32) = try .init(gpa, size.width, source.height);
    defer narrow.deinit(gpa);
    for (0..source.height) |y| {
        const in = source.row(y);
        for (narrow.row(y), 0..) |*out, x| {
            var sum: [channels]f32 = @splat(0);
            const start = across.first[x];
            for (across.of(x), 0..) |w, k| {
                if (w == 0) continue;
                for (&sum, in[start + k]) |*s, v| s.* += w * float(Sample, v);
            }
            out.* = sum;
        }
    }

    // Down: squeeze every column to the output's height.
    var result: image.Image([channels]Sample) = try .init(gpa, size.width, size.height);
    errdefer result.deinit(gpa);
    const sums = try gpa.alloc([channels]f32, size.width);
    defer gpa.free(sums);
    for (0..size.height) |y| {
        @memset(sums, @splat(0));
        const start = down.first[y];
        for (down.of(y), 0..) |w, k| {
            if (w == 0) continue;
            for (sums, narrow.row(start + k)) |*s, in| {
                for (s, in) |*total, v| total.* += w * v;
            }
        }
        for (result.row(y), sums) |*out, s| {
            for (out, s) |*o, v| o.* = sample(Sample, v);
        }
    }
    return result;
}

fn float(comptime Sample: type, v: Sample) f32 {
    return switch (@typeInfo(Sample)) {
        .int => @floatFromInt(v),
        .float => v,
        else => @compileError("samples are integers or floats"),
    };
}

fn sample(comptime Sample: type, v: f32) Sample {
    return switch (@typeInfo(Sample)) {
        .int => @intFromFloat(std.math.clamp(@round(v), 0, @as(f32, @floatFromInt(std.math.maxInt(Sample))))),
        .float => v,
        else => @compileError("samples are integers or floats"),
    };
}

test "the fitted size keeps the long edge exact and the proportions close" {
    try std.testing.expectEqual(Size{ .width = 4000, .height = 2667 }, fitted(6000, 4000, 4000));
    try std.testing.expectEqual(Size{ .width = 1606, .height = 2048 }, fitted(3112, 3968, 2048));
    // Never larger.
    try std.testing.expectEqual(Size{ .width = 3112, .height = 3968 }, fitted(3112, 3968, 4000));
}

test "a third of a pixel at each edge counts by its share" {
    const gpa = std.testing.allocator;
    var source: image.Image([3]f32) = try .init(gpa, 3, 1);
    defer source.deinit(gpa);
    for (source.pixels, [_]f32{ 0, 30, 60 }) |*p, v| p.* = @splat(v);
    var reduced = try reduce(f32, gpa, source, .{ .width = 2, .height = 1 });
    defer reduced.deinit(gpa);
    // Each output pixel covers one and a half input pixels: 0 and half of 30, then the other
    // half of 30 and 60.
    try std.testing.expectApproxEqAbs(@as(f32, 10), reduced.pixels[0][0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 50), reduced.pixels[1][0], 1e-4);
}

test "by a whole factor it averages blocks, as downscale does" {
    const gpa = std.testing.allocator;
    var scan: image.Scan = try .init(gpa, 8, 6);
    defer scan.deinit(gpa);
    for (scan.pixels, 0..) |*p, i| p.* = .{ @intCast(i * 1000), @intCast(i * 7), @intCast(65535 - i * 300) };
    var blocks = try image.downscale(gpa, scan, 4);
    defer blocks.deinit(gpa);
    var reduced = try reduce(u16, gpa, scan, .{ .width = blocks.width, .height = blocks.height });
    defer reduced.deinit(gpa);
    for (blocks.pixels, reduced.pixels) |b, r| {
        // downscale truncates where this rounds.
        for (b, r) |expected, actual| try std.testing.expect(@abs(@as(i32, expected) - @as(i32, actual)) <= 1);
    }
}

test "the mean of the image is kept at any size" {
    const gpa = std.testing.allocator;
    var scan: image.Scan = try .init(gpa, 97, 61);
    defer scan.deinit(gpa);
    var prng: std.Random.DefaultPrng = .init(1);
    const random = prng.random();
    var total: f64 = 0;
    for (scan.pixels) |*p| {
        p.* = .{ random.int(u16), random.int(u16), random.int(u16) };
        total += @floatFromInt(p[0]);
    }
    const size = fitted(scan.width, scan.height, 40);
    var reduced = try reduce(u16, gpa, scan, size);
    defer reduced.deinit(gpa);
    var reduced_total: f64 = 0;
    for (reduced.pixels) |p| reduced_total += @floatFromInt(p[0]);
    const mean = total / @as(f64, @floatFromInt(scan.pixels.len));
    const reduced_mean = reduced_total / @as(f64, @floatFromInt(reduced.pixels.len));
    try std.testing.expectApproxEqRel(mean, reduced_mean, 0.01);
}
