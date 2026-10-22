//! A stock's correction from its datasheet: each layer's characteristic curve straightened, so that
//! the inversion, which takes density to follow log exposure in a straight line, gets the density
//! the exposure would have given on the straight part of the curve.
//!
//! A negative's density rises from its base in a curve, the toe, before it follows the exposure in a
//! straight line, and some films bend again at the top, the shoulder. Read as a straight line, the
//! toe crushes the shadows, and as each layer's toe is its own, it tints them. With the datasheet's
//! curve for each layer, a density goes back to its log exposure, then on to the density the
//! straight line gives that exposure, measured from the base: the base stays at 0, the toe opens
//! up, and the straight part keeps its contrast, a little higher up. Right at the base the toe is
//! all but flat, so the stretch stops at `max_gain`.
//!
//! Datasheet curves are in Status M density and a scanner reads its own. A calibrated scanner's
//! factors (`calibration`) give each layer's scale, with green taken as reading Status M; without a
//! calibration the scale is 1.

const std = @import("std");
const stocks = @import("../presets/stocks.zig");

/// Points in each layer's table.
pub const samples = 33;
/// The most the correction stretches differences in density. Right at the base the toe is all but
/// flat: Superia X-TRA 400's would need 15 to 35 times there, which would only blow up the grain,
/// while above 0.05 D it needs less than 3.
pub const max_gain = 3;
/// The part of a curve's density range whose points place its straight line, as shares of the
/// range: above the toe and below any shoulder.
const straight_from = 0.25;
const straight_to = 0.85;
/// The most points a datasheet curve has.
const max_points = 256;

pub const Curves = struct {
    /// Each layer's table covers density above the base from 0 to `top`, in the scanner's density.
    top: [3]f32,
    /// The straightened density at each of `samples` even steps from 0 to `top`: 0 at the base.
    values: [3][samples]f32,

    /// `d`, density above the base per channel, straightened.
    pub fn apply(curves: *const Curves, d: [3]f32) [3]f32 {
        var out: [3]f32 = undefined;
        for (&out, d, 0..) |*o, v, c| o.* = curves.layer(c, v);
        return out;
    }

    /// Layer `c`'s density above the base `d`, straightened. Clearer than the base it goes on at the
    /// first step's slope, and above the table at the straight line's.
    pub fn layer(curves: *const Curves, c: usize, d: f32) f32 {
        const values = &curves.values[c];
        const step = curves.top[c] / (samples - 1);
        if (d <= 0) return values[0] + d * (values[1] - values[0]) / step;
        if (d >= curves.top[c]) return values[samples - 1] + (d - curves.top[c]);
        const t = d / step;
        const i: usize = @min(@as(usize, @intFromFloat(t)), samples - 2);
        const f = t - @as(f32, @floatFromInt(i));
        return values[i] * (1 - f) + values[i + 1] * f;
    }
};

/// `stock`'s curves in a scanner's density, `scale` times Status M per layer. Null for a stock
/// without curves, and for slides, whose density isn't inverted.
pub fn of(stock: stocks.Stock, scale: [3]f32) ?Curves {
    if (stock.kind != .colour_negative and stock.kind != .bw_negative) return null;
    const curves = stock.curves orelse return null;
    var result: Curves = undefined;
    for (0..3) |c| {
        result.top[c] = layerTable(curves[c], scale[c], &result.values[c]) orelse return null;
    }
    return result;
}

/// One layer's table from its curve `points`, at `scale`. Returns the table's top, or null for a
/// curve too short or too flat to straighten.
fn layerTable(points: []const stocks.Point, scale: f32, values: *[samples]f32) ?f32 {
    if (points.len < 2 or points.len > max_points or !(scale > 0)) return null;
    // Density above the curve's lowest, never falling: a curve read off a chart can dip by a
    // reading's error.
    var lowest = points[0].density;
    for (points) |p| lowest = @min(lowest, p.density);
    var above: [max_points]f32 = undefined;
    var running: f32 = 0;
    for (points, above[0..points.len]) |p, *a| {
        running = @max(running, p.density - lowest);
        a.* = running;
    }
    const range = running;
    if (!(range > 0)) return null;

    // The straight line, density = gamma × (log H − its foot), fitted to the straight part. Fitted
    // rather than the datasheet's gamma, so that it straightens the curve it's drawn from: the
    // colour negatives' gammas agree with their curves within a few percent, but a B&W curve has no
    // straight part to quote.
    var sum_h: f32 = 0;
    var sum_d: f32 = 0;
    var straight: f32 = 0;
    for (points, above[0..points.len]) |p, a| {
        if (a < straight_from * range or a > straight_to * range) continue;
        sum_h += p.log_exposure;
        sum_d += a;
        straight += 1;
    }
    if (straight < 2) return null;
    const mean_h = sum_h / straight;
    const mean_d = sum_d / straight;
    var covariance: f32 = 0;
    var variance: f32 = 0;
    for (points, above[0..points.len]) |p, a| {
        if (a < straight_from * range or a > straight_to * range) continue;
        covariance += (p.log_exposure - mean_h) * (a - mean_d);
        variance += (p.log_exposure - mean_h) * (p.log_exposure - mean_h);
    }
    if (!(variance > 0) or !(covariance > 0)) return null;
    const gamma = covariance / variance;
    const foot = mean_h - mean_d / gamma;

    const top = range * scale;
    const step = top / (samples - 1);
    for (values, 0..) |*v, i| {
        const d = @as(f32, @floatFromInt(i)) * step / scale;
        v.* = scale * gamma * (logExposure(points, above[0..points.len], d) - foot);
    }

    // From the middle of the straight part outwards: never falling, and stretching no more than
    // `max_gain`.
    const middle = samples / 2;
    var i: usize = middle;
    while (i > 0) {
        i -= 1;
        values[i] = std.math.clamp(values[i], values[i + 1] - max_gain * step, values[i + 1]);
    }
    for (middle + 1..samples) |j| values[j] = std.math.clamp(values[j], values[j - 1], values[j - 1] + max_gain * step);
    // From the base: the straight line reaches the base's density below where the toe does, which
    // would put the shadows under the base, and the automatic black point there.
    const at_base = values[0];
    for (values) |*v| v.* -= at_base;
    return top;
}

/// The log exposure at which the curve reaches density `d` above its lowest; below the first point,
/// on along the first segment.
fn logExposure(points: []const stocks.Point, above: []const f32, d: f32) f32 {
    for (above[1..], 1..) |a, i| {
        if (a < d) continue;
        const below = above[i - 1];
        const f = if (a > below) (d - below) / (a - below) else 0;
        return points[i - 1].log_exposure + f * (points[i].log_exposure - points[i - 1].log_exposure);
    }
    return points[points.len - 1].log_exposure;
}

fn testStock(curve: []const stocks.Point, gamma: f32) stocks.Stock {
    return .{
        .name = "Test",
        .maker = "Test",
        .kind = .colour_negative,
        .iso = 100,
        .base_density = null,
        .gamma = @splat(gamma),
        .density_range = null,
        .curves = .{ curve, curve, curve },
        .source = "",
    };
}

test "a straight curve changes nothing" {
    var line: [21]stocks.Point = undefined;
    for (&line, 0..) |*p, i| {
        const h = @as(f32, @floatFromInt(i)) * 0.15 - 3;
        p.* = .{ .log_exposure = h, .density = 0.2 + 0.6 * (h + 3) };
    }
    for ([_]f32{ 1, 0.8 }) |scale| {
        const curves = of(testStock(&line, 0.6), @splat(scale)).?;
        for ([_]f32{ 0, 0.1, 0.5, 1.2, 2.5 }) |d| {
            for (curves.apply(@splat(d))) |v| try std.testing.expectApproxEqAbs(d, v, 1e-4);
        }
    }
}

test "a toe opens up, no more than max_gain, and the straight part stays" {
    // Flat at the base, curving up into a straight line of slope 0.6 from log H −2.
    var curve: [31]stocks.Point = undefined;
    for (&curve, 0..) |*p, i| {
        const h = @as(f32, @floatFromInt(i)) * 0.1 - 3;
        const toe = 0.3 * @log(1 + @exp((h + 2) / 0.5)) * 0.5 / 0.3;
        p.* = .{ .log_exposure = h, .density = 0.1 + 0.6 * toe };
    }
    const curves = of(testStock(&curve, 0.6), @splat(1)).?;
    // The base stays at 0, and the toe's densities spread out from it.
    try std.testing.expectEqual(@as(f32, 0), curves.layer(0, 0));
    try std.testing.expect(curves.layer(0, 0.1) > 0.1);
    // The straight part keeps its contrast.
    const high = curves.layer(0, 1.4) - curves.layer(0, 1.2);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), high, 0.01);
    // Never falling, and no step stretched past max_gain.
    const step = curves.top[0] / (samples - 1);
    for (curves.values[0][1..], curves.values[0][0 .. samples - 1]) |v, before| {
        try std.testing.expect(v >= before);
        try std.testing.expect(v - before <= max_gain * step + 1e-5);
    }
}

test "the presets' colour negatives have curves, and slides none" {
    var found = false;
    for (stocks.stocks) |stock| {
        const curves = of(stock, @splat(1)) orelse continue;
        found = true;
        try std.testing.expect(stock.kind == .colour_negative or stock.kind == .bw_negative);
        // The straight part keeps its contrast, and the base its density.
        for (0..3) |c| {
            const mid = curves.top[c] / 2;
            try std.testing.expectApproxEqAbs(@as(f32, 0.2), curves.layer(c, mid + 0.1) - curves.layer(c, mid - 0.1), 0.03);
            try std.testing.expectEqual(@as(f32, 0), curves.layer(c, 0));
        }
    }
    try std.testing.expect(found);
    for (stocks.stocks) |stock| if (stock.kind == .colour_positive) try std.testing.expectEqual(null, of(stock, @splat(1)));
}
