//! Corrects a stock using its datasheet by straightening each layer's characteristic curve. The
//! inversion assumes density follows log exposure in a straight line, so we hand it the density the
//! exposure would have given on the straight part of the curve.
//!
//! On a negative, density rises from the base in a curve (the toe) before it follows the exposure
//! in a straight line, and some films bend again at the top (the shoulder). Treat the toe as a
//! straight line and it crushes the shadows, and since every layer has its own toe, it tints them
//! too. With the datasheet's curve for each layer, we take a density back to its log exposure, then
//! on to the density the straight line gives for that exposure, measured from the base. The base
//! stays at 0, the toe opens up, and the straight part keeps its contrast, just a little higher up.
//! Right at the base the toe is almost flat, so the stretch stops at `max_gain`.
//!
//! Datasheet curves are in Status M density, but a scanner reads its own kind of density. A
//! calibrated scanner's factors (`calibration`) give each layer's scale, with green taken as
//! reading Status M. Without a calibration the scale is 1.

const std = @import("std");
const stocks = @import("../presets/stocks.zig");

/// How many points each layer's table has.
pub const samples = 33;
/// The most the correction stretches differences in density. Right at the base the toe is almost
/// flat: Superia X-TRA 400's would need 15 to 35 times there, which would only blow up the grain.
/// Above 0.05 D it needs less than 3.
pub const max_gain = 3;
/// The part of a curve's density range we fit its straight line to, as shares of the range. It
/// sits above the toe and below any shoulder.
const straight_from = 0.25;
const straight_to = 0.85;
/// The most points a datasheet curve can have.
const max_points = 256;

pub const Curves = struct {
    /// Each layer's table covers density above the base from 0 to `top`, in the scanner's density.
    top: [3]f32,
    /// The straightened density at `samples` even steps from 0 to `top`. It's 0 at the base.
    values: [3][samples]f32,

    /// Straightens `d`, the density above the base in each channel.
    pub fn apply(curves: *const Curves, d: [3]f32) [3]f32 {
        var out: [3]f32 = undefined;
        for (&out, d, 0..) |*o, v, c| o.* = curves.layer(c, v);
        return out;
    }

    /// Straightens density `d` (above the base) for layer `c`. Below the base it carries on at the
    /// slope of the first step, and above the table at a slope of 1, like the straight part.
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

/// Returns `stock`'s curves in a scanner's density, with each layer at `scale` times Status M.
/// Returns null for a stock without curves, and for slides, since their density isn't inverted.
pub fn of(stock: stocks.Stock, scale: [3]f32) ?Curves {
    if (stock.kind != .colour_negative and stock.kind != .bw_negative) return null;
    const curves = stock.curves orelse return null;
    var result: Curves = undefined;
    for (0..3) |c| {
        result.top[c] = layerTable(curves[c], scale[c], &result.values[c]) orelse return null;
    }
    return result;
}

/// Fills in one layer's table from its curve `points`, at `scale`. Returns the table's top, or null
/// if the curve is too short or too flat to straighten.
fn layerTable(points: []const stocks.Point, scale: f32, values: *[samples]f32) ?f32 {
    if (points.len < 2 or points.len > max_points or !(scale > 0)) return null;
    // Density above the curve's lowest point, never allowed to fall: a curve read off a chart can
    // dip by the reading error.
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

    // The straight line, density = gamma × (log H − foot), fitted to the straight part. We fit it
    // rather than use the datasheet's gamma, so that it straightens the curve it came from. The
    // colour negatives' gammas agree with their curves to within a few percent, but a B&W curve has
    // no straight part to quote a gamma from.
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

    // Work outwards from the middle of the straight part, so the table never falls and never
    // stretches by more than `max_gain`.
    const middle = samples / 2;
    var i: usize = middle;
    while (i > 0) {
        i -= 1;
        values[i] = std.math.clamp(values[i], values[i + 1] - max_gain * step, values[i + 1]);
    }
    for (middle + 1..samples) |j| values[j] = std.math.clamp(values[j], values[j - 1], values[j - 1] + max_gain * step);
    // Measure from the base. Where the toe starts, the straight line is already below the base
    // density, which would put the shadows under the base, and the automatic black point with them.
    const at_base = values[0];
    for (values) |*v| v.* -= at_base;
    return top;
}

/// Returns the log exposure at which the curve reaches density `d` above its lowest point. Below
/// the first point it carries on along the first segment.
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
    // Flat at the base, then curving up into a straight line of slope 0.6 from log H −2.
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
    // The table never falls, and no step is stretched past max_gain.
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
        // The straight part keeps its contrast, and the base stays at 0.
        for (0..3) |c| {
            const mid = curves.top[c] / 2;
            try std.testing.expectApproxEqAbs(@as(f32, 0.2), curves.layer(c, mid + 0.1) - curves.layer(c, mid - 0.1), 0.03);
            try std.testing.expectEqual(@as(f32, 0), curves.layer(c, 0));
        }
    }
    try std.testing.expect(found);
    for (stocks.stocks) |stock| if (stock.kind == .colour_positive) try std.testing.expectEqual(null, of(stock, @splat(1)));
}
