//! The curve a look uses for one channel: 33 evenly spaced points over 0..1, joined by straight
//! lines, and never falling. We fit it to samples by least squares with a little smoothing, then
//! make it monotone.

const std = @import("std");
const linear = @import("linear.zig");

pub const points = 33;
/// The weight every point has at least.
const least_weight = 1e-12;
const segments = points - 1;

/// The curve's values at x = 0, 1/32, … 1.
pub const Curve = [points]f32;

pub const identity: Curve = blk: {
    var c: Curve = undefined;
    for (&c, 0..) |*v, i| v.* = @as(f32, @floatFromInt(i)) / segments;
    break :blk c;
};

/// Returns the curve's value at `x`, with `x` clamped to 0..1.
pub fn eval(curve: *const Curve, x: f32) f32 {
    const t = std.math.clamp(x, 0, 1) * segments;
    const i: usize = @min(@as(usize, @intFromFloat(t)), segments - 1);
    const f = t - @as(f32, @floatFromInt(i));
    return curve[i] + (curve[i + 1] - curve[i]) * f;
}

/// Returns the curve's slope at `x`, measured over one point's spacing on either side. The fit's
/// steps prefer this to a single segment's slope, because it's smoother. Outside 0..1 the curve is
/// flat, so the slope there is 0.
pub fn slope(curve: *const Curve, x: f32) f32 {
    const h = 1.0 / @as(f32, segments);
    const lo = @max(x - h, 0);
    const hi = @min(x + h, 1);
    if (hi <= lo) return 0;
    return (eval(curve, hi) - eval(curve, lo)) / (hi - lo);
}

/// Collects the samples for one curve, then solves for the curve.
pub const Fitter = struct {
    /// The normal equations of the least-squares fit. Each sample is shared between the two points
    /// on either side of it, weighted by how close it is to each.
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

    /// Solves for the fitted curve. `smoothness` sets how much bending costs compared with missing
    /// the samples, relative to their total weight. Where there are no samples, the curve carries
    /// on in a straight line. The result never falls and stays within 0..1.
    pub fn solve(fitter: *const Fitter, smoothness: f64) Curve {
        if (fitter.total <= 0) return identity;
        var a = fitter.a;
        var b = fitter.b;
        var data_weight: [points]f64 = undefined;
        for (&data_weight, 0..) |*w, i| w.* = fitter.a[i * points + i];

        // Bending is measured as the squared second differences.
        const bend = smoothness * fitter.total;
        for (1..segments) |k| {
            const row = [3]usize{ k - 1, k, k + 1 };
            const coefficient = [3]f64{ 1, -2, 1 };
            for (row, coefficient) |r, cr| {
                for (row, coefficient) |s, cs| a[r * points + s] += bend * cr * cs;
            }
        }
        // A very weak pull towards the identity, so the system is never singular.
        const pull = 1e-7 * fitter.total;
        for (0..points) |i| {
            a[i * points + i] += pull;
            b[i] += pull * identity[i];
        }
        linear.solve(points, &a, &b) catch return identity;

        // Every point gets some weight, so the monotone pass never divides by zero.
        for (&data_weight) |*w| w.* += pull + least_weight;
        monotone(&b, &data_weight);
        var curve: Curve = undefined;
        for (&curve, b) |*out, v| out.* = @floatCast(std.math.clamp(v, 0, 1));
        return curve;
    }
};

/// Makes `values` non-decreasing with the smallest weighted change, using the pool adjacent
/// violators algorithm.
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
