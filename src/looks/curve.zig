//! A look's channel curve: 33 points evenly spaced over 0..1, joined by straight lines, never
//! falling. Fitted from samples by least squares with a little smoothing, then made monotone.

const std = @import("std");
const linear = @import("linear.zig");

pub const points = 33;
const segments = points - 1;

/// The curve's values at x = 0, 1/32, … 1.
pub const Curve = [points]f32;

pub const identity: Curve = blk: {
    var c: Curve = undefined;
    for (&c, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) / segments;
    break :blk c;
};

/// The curve at `x`, which is held to 0..1.
pub fn eval(curve: *const Curve, x: f32) f32 {
    const t = std.math.clamp(x, 0, 1) * segments;
    const i: usize = @min(@as(usize, @intFromFloat(t)), segments - 1);
    const f = t - @as(f32, @floatFromInt(i));
    return curve[i] + (curve[i + 1] - curve[i]) * f;
}

/// The curve's slope at `x`, measured over a point's spacing either side: smoother than a
/// segment's own slope, which a fit's steps prefer. 0 outside 0..1, where the curve is flat.
pub fn slope(curve: *const Curve, x: f32) f32 {
    const h = 1.0 / @as(f32, segments);
    const lo = @max(x - h, 0);
    const hi = @min(x + h, 1);
    if (hi <= lo) return 0;
    return (eval(curve, hi) - eval(curve, lo)) / (hi - lo);
}

/// Gathers samples for one curve, then solves for it.
pub const Fitter = struct {
    /// The normal equations of the least-squares fit: each sample spread over the two points
    /// either side of it, by how near it is.
    a: [points * points]f64 = @splat(0),
    b: [points]f64 = @splat(0),
    total: f64 = 0,

    pub fn add(fitter: *Fitter, x: f32, y: f32, weight: f32) void {
        if (weight <= 0) return;
        const t = std.math.clamp(x, 0, 1) * segments;
        const i: usize = @min(@as(usize, @intFromFloat(t)), segments - 1);
        const f: f64 = t - @as(f32, @floatFromInt(i));
        const w: f64 = weight;
        const lo = 1 - f;
        fitter.a[i * points + i] += w * lo * lo;
        fitter.a[i * points + i + 1] += w * lo * f;
        fitter.a[(i + 1) * points + i] += w * lo * f;
        fitter.a[(i + 1) * points + i + 1] += w * f * f;
        fitter.b[i] += w * lo * y;
        fitter.b[i + 1] += w * f * y;
        fitter.total += w;
    }

    /// The fitted curve. `smoothness` weighs the curve's bending against the samples, relative to
    /// their total weight; where there are no samples, the curve carries on straight. The result
    /// never falls and stays in 0..1.
    pub fn solve(fitter: *const Fitter, smoothness: f64) Curve {
        if (fitter.total <= 0) return identity;
        var a = fitter.a;
        var b = fitter.b;
        var data_weight: [points]f64 = undefined;
        for (&data_weight, 0..) |*w, i| w.* = fitter.a[i * points + i];

        // Bending: the second differences, squared.
        const bend = smoothness * fitter.total;
        for (1..segments) |k| {
            const row = [3]usize{ k - 1, k, k + 1 };
            const coefficient = [3]f64{ 1, -2, 1 };
            for (row, coefficient) |r, cr| {
                for (row, coefficient) |s, cs| a[r * points + s] += bend * cr * cs;
            }
        }
        // A faint pull towards the identity, so that the system is never singular.
        const pull = 1e-7 * fitter.total;
        for (0..points) |i| {
            a[i * points + i] += pull;
            b[i] += pull * identity[i];
        }
        linear.solve(points, &a, &b) catch return identity;

        for (&data_weight) |*w| w.* += pull + 1e-12;
        monotone(&b, &data_weight);
        var curve: Curve = undefined;
        for (&curve, b) |*out, v| out.* = @floatCast(std.math.clamp(v, 0, 1));
        return curve;
    }
};

/// Makes `values` non-decreasing with the least weighted change: pool adjacent violators.
fn monotone(values: *[points]f64, weights: *const [points]f64) void {
    var mean: [points]f64 = undefined;
    var weight: [points]f64 = undefined;
    var count: [points]usize = undefined;
    var blocks: usize = 0;
    for (values, weights) |v, w| {
        mean[blocks] = v;
        weight[blocks] = w;
        count[blocks] = 1;
        blocks += 1;
        while (blocks > 1 and mean[blocks - 2] > mean[blocks - 1]) {
            const total = weight[blocks - 2] + weight[blocks - 1];
            mean[blocks - 2] = (mean[blocks - 2] * weight[blocks - 2] + mean[blocks - 1] * weight[blocks - 1]) / total;
            weight[blocks - 2] = total;
            count[blocks - 2] += count[blocks - 1];
            blocks -= 1;
        }
    }
    var i: usize = 0;
    for (mean[0..blocks], count[0..blocks]) |m, n| {
        for (values[i..][0..n]) |*v| v.* = m;
        i += n;
    }
}

test "a curve comes back from samples of it" {
    var prng = std.Random.DefaultPrng.init(1);
    const random = prng.random();
    var fitter: Fitter = .{};
    for (0..20000) |_| {
        const x = random.float(f32);
        const y = std.math.pow(f32, x, 0.6) + (random.float(f32) - 0.5) * 0.02;
        fitter.add(x, y, 1);
    }
    const fitted = fitter.solve(1e-5);
    for (1..10) |i| {
        const x = @as(f32, @floatFromInt(i)) / 10;
        try std.testing.expectApproxEqAbs(std.math.pow(f32, x, 0.6), eval(&fitted, x), 0.01);
    }
}

test "a fitted curve never falls" {
    var fitter: Fitter = .{};
    for (0..100) |i| {
        const x = @as(f32, @floatFromInt(i)) / 100;
        // Rising, with a dip in the middle.
        const y = if (x > 0.4 and x < 0.5) x - 0.2 else x;
        fitter.add(x, y, 1);
    }
    const fitted = fitter.solve(1e-6);
    for (fitted[0 .. points - 1], fitted[1..]) |a, b| try std.testing.expect(b >= a);
}

test "with no samples the curve is the identity" {
    const fitter: Fitter = .{};
    try std.testing.expectEqual(identity, fitter.solve(1e-4));
    try std.testing.expectApproxEqAbs(@as(f32, 0.3), eval(&identity, 0.3), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), slope(&identity, 0.5), 1e-5);
}
