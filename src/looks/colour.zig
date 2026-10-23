//! Colour arithmetic for checking a fit: sRGB to CIELAB, and the CIEDE2000 colour difference.
//!
//! Values are sRGB-encoded 0..1 unless the name says they're linear. Lab is relative to D65,
//! sRGB's white point.

const std = @import("std");
const srgb = @import("../core/encode.zig");

/// The sRGB transfer curve, and back.
pub const encode = srgb.srgb;
pub const decode = srgb.linearFromSrgb;
pub const luminance = srgb.luminance;

/// sRGB's D65 white point, in XYZ.
const white: [3]f64 = .{ 0.95047, 1.0, 1.08883 };

/// Converts encoded sRGB to CIELAB.
pub fn lab(encoded: [3]f32) [3]f32 {
    var rgb: [3]f64 = undefined;
    for (&rgb, encoded) |*l, e| l.* = decode(e);
    var xyz: [3]f64 = undefined;
    for (&xyz, srgb.srgb_to_xyz) |*v, row| v.* = row[0] * rgb[0] + row[1] * rgb[1] + row[2] * rgb[2];
    var f: [3]f64 = undefined;
    for (&f, xyz, white) |*out, v, n| out.* = labCurve(v / n);
    return .{ @floatCast(116 * f[1] - 16), @floatCast(500 * (f[0] - f[1])), @floatCast(200 * (f[1] - f[2])) };
}

fn labCurve(t: f64) f64 {
    const delta = 6.0 / 29.0;
    return if (t > delta * delta * delta) std.math.cbrt(t) else t / (3 * delta * delta) + 4.0 / 29.0;
}

fn degrees(angle: f64) f64 {
    return angle * 180 / std.math.pi;
}

fn radians(deg: f64) f64 {
    return deg * std.math.pi / 180;
}

/// Returns the CIEDE2000 difference between two Lab colours, following Sharma, Wu and Dalal
/// (2005), with kL = kC = kH = 1. A difference of about 1 is the smallest most people can see.
pub fn deltaE2000(first: [3]f32, second: [3]f32) f32 {
    const l1: f64 = first[0];
    const a1: f64 = first[1];
    const b1: f64 = first[2];
    const l2: f64 = second[0];
    const a2: f64 = second[1];
    const b2: f64 = second[2];
    const pow25_7 = 6103515625.0; // 25^7

    const c_mean = (@sqrt(a1 * a1 + b1 * b1) + @sqrt(a2 * a2 + b2 * b2)) / 2;
    const c_mean7 = std.math.pow(f64, c_mean, 7);
    const g = 0.5 * (1 - @sqrt(c_mean7 / (c_mean7 + pow25_7)));
    const a1p = (1 + g) * a1;
    const a2p = (1 + g) * a2;
    const c1p = @sqrt(a1p * a1p + b1 * b1);
    const c2p = @sqrt(a2p * a2p + b2 * b2);
    const h1p = hue(b1, a1p);
    const h2p = hue(b2, a2p);

    const dl = l2 - l1;
    const dc = c2p - c1p;
    var dh: f64 = 0;
    if (c1p * c2p != 0) {
        dh = h2p - h1p;
        if (dh > 180) dh -= 360 else if (dh < -180) dh += 360;
    }
    const dh_big = 2 * @sqrt(c1p * c2p) * @sin(radians(dh / 2));

    const l_mean = (l1 + l2) / 2;
    const cp_mean = (c1p + c2p) / 2;
    var h_mean = h1p + h2p;
    if (c1p * c2p != 0) {
        if (@abs(h1p - h2p) <= 180) {
            h_mean /= 2;
        } else if (h1p + h2p < 360) {
            h_mean = (h_mean + 360) / 2;
        } else {
            h_mean = (h_mean - 360) / 2;
        }
    }
    const t = 1 - 0.17 * @cos(radians(h_mean - 30)) + 0.24 * @cos(radians(2 * h_mean)) +
        0.32 * @cos(radians(3 * h_mean + 6)) - 0.20 * @cos(radians(4 * h_mean - 63));
    const d_theta = 30 * @exp(-std.math.pow(f64, (h_mean - 275) / 25, 2));
    const cp_mean7 = std.math.pow(f64, cp_mean, 7);
    const rc = 2 * @sqrt(cp_mean7 / (cp_mean7 + pow25_7));
    const l50 = (l_mean - 50) * (l_mean - 50);
    const sl = 1 + 0.015 * l50 / @sqrt(20 + l50);
    const sc = 1 + 0.045 * cp_mean;
    const sh = 1 + 0.015 * cp_mean * t;
    const rt = -@sin(radians(2 * d_theta)) * rc;
    const ql = dl / sl;
    const qc = dc / sc;
    const qh = dh_big / sh;
    return @floatCast(@sqrt(@max(0, ql * ql + qc * qc + qh * qh + rt * qc * qh)));
}

/// Returns the hue angle in degrees, 0..360, or 0 for a neutral colour.
fn hue(b: f64, a: f64) f64 {
    if (a == 0 and b == 0) return 0;
    const h = degrees(std.math.atan2(b, a));
    return if (h < 0) h + 360 else h;
}

/// Returns the value that `share` of `values` fall below. It sorts `values` in place, and returns
/// 0 when there are none.
pub fn percentile(values: []f32, share: f32) f32 {
    if (values.len == 0) return 0;
    std.mem.sort(f32, values, {}, std.sort.asc(f32));
    const rank: usize = @intFromFloat(@round(share * @as(f32, @floatFromInt(values.len - 1))));
    return values[@min(rank, values.len - 1)];
}

test "CIEDE2000 matches Sharma's test data" {
    // Pairs 1, 2, 7, 17, 25 and 34 from the table in Sharma, Wu and Dalal.
    const cases = [_]struct { [3]f32, [3]f32, f32 }{
        .{ .{ 50, 2.6772, -79.7751 }, .{ 50, 0, -82.7485 }, 2.0425 },
        .{ .{ 50, 3.1571, -77.2803 }, .{ 50, 0, -82.7485 }, 2.8615 },
        .{ .{ 50, 0, 0 }, .{ 50, -1, 2 }, 2.3669 },
        .{ .{ 50, 2.5, 0 }, .{ 73, 25, -18 }, 27.1492 },
        .{ .{ 60.2574, -34.0099, 36.2677 }, .{ 60.4626, -34.1751, 39.4387 }, 1.2644 },
        .{ .{ 22.7233, 20.0904, -46.694 }, .{ 23.0331, 14.973, -42.5619 }, 2.0373 },
    };
    for (cases) |case| {
        try std.testing.expectApproxEqAbs(case[2], deltaE2000(case[0], case[1]), 1e-3);
        try std.testing.expectApproxEqAbs(case[2], deltaE2000(case[1], case[0]), 1e-3);
    }
}

test "sRGB white is L 100 and neutral" {
    const w = lab(.{ 1, 1, 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 100), w[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0), w[1], 1e-2);
    try std.testing.expectApproxEqAbs(@as(f32, 0), w[2], 1e-2);
    const black = lab(.{ 0, 0, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), black[0], 1e-3);
}

test "percentiles of a list" {
    var values = [_]f32{ 5, 1, 4, 2, 3 };
    try std.testing.expectEqual(@as(f32, 3), percentile(&values, 0.5));
    try std.testing.expectEqual(@as(f32, 5), percentile(&values, 1));
}
