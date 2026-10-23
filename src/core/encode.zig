//! Encodes rendered linear values for output, using the sRGB transfer curve.

const std = @import("std");
const image = @import("image.zig");

/// The sRGB transfer curve's numbers (IEC 61966-2-1): a power curve with a straight toe.
pub const srgb_curve = struct {
    pub const gamma = 2.4;
    /// Above the toe, encoded = scale × linear^(1 / gamma) − offset.
    pub const scale = 1.055;
    pub const offset = 0.055;
    /// Below the toe, encoded = toe_slope × linear. The toe ends at `toe_linear`, which encodes
    /// to `toe_encoded`.
    pub const toe_slope = 12.92;
    pub const toe_linear = 0.0031308;
    pub const toe_encoded = 0.04045;
};

/// Linear sRGB to CIE XYZ, for D65 white, row by row.
pub const srgb_to_xyz = [3][3]f64{
    .{ 0.4124564, 0.3575761, 0.1804375 },
    .{ 0.2126729, 0.7151522, 0.0721750 },
    .{ 0.0193339, 0.1191920, 0.9503041 },
};

/// How much each linear sRGB channel adds to luminance: the Y row of `srgb_to_xyz`.
pub const luminance_weights: [3]f32 = .{ @floatCast(srgb_to_xyz[1][0]), @floatCast(srgb_to_xyz[1][1]), @floatCast(srgb_to_xyz[1][2]) };

/// The relative luminance of a linear sRGB colour.
pub fn luminance(linear: [3]f32) f32 {
    return luminance_weights[0] * linear[0] + luminance_weights[1] * linear[1] + luminance_weights[2] * linear[2];
}

/// The sRGB transfer curve: linear 0..1 to encoded 0..1.
pub fn srgb(linear: f32) f32 {
    const k = srgb_curve;
    const v = std.math.clamp(linear, 0, 1);
    return if (v <= k.toe_linear) k.toe_slope * v else k.scale * std.math.pow(f32, v, 1.0 / k.gamma) - k.offset;
}

/// The sRGB transfer curve in reverse: encoded 0..1 to linear 0..1.
pub fn linearFromSrgb(encoded: f32) f32 {
    const k = srgb_curve;
    const v = std.math.clamp(encoded, 0, 1);
    return if (v <= k.toe_encoded) v / k.toe_slope else std.math.pow(f32, (v + k.offset) / k.scale, k.gamma);
}

fn quantise(comptime T: type, v: f32) T {
    const top: f32 = @floatFromInt(std.math.maxInt(T));
    return @intFromFloat(@round(v * top));
}

/// How many entries the table behind `toSrgb8` has. It's fine enough that even the deepest
/// shadows, where the curve is steepest, are off by at most one step in 255.
const table_entries = 1 << 14;

/// 8-bit sRGB from linear values, by table: a few times faster than the power function, and 8
/// bits don't need more.
const Srgb8 = struct {
    table: [table_entries + 1]u8,

    fn init() Srgb8 {
        var t: Srgb8 = undefined;
        for (&t.table, 0..) |*entry, i| entry.* = quantise(u8, srgb(@as(f32, @floatFromInt(i)) / table_entries));
        return t;
    }

    fn of(t: *const Srgb8, linear: f32) u8 {
        return t.table[@intFromFloat(@round(std.math.clamp(linear, 0, 1) * table_entries))];
    }
};

pub fn toSrgb8(gpa: std.mem.Allocator, rendered: image.Rendered) !image.Encoded8 {
    const out: image.Encoded8 = try .init(gpa, rendered.width, rendered.height);
    const table: Srgb8 = .init();
    for (out.pixels, rendered.pixels) |*o, p| {
        for (o, p) |*c, v| c.* = table.of(v);
    }
    return out;
}

/// sRGB-encodes `rendered` into `out` as opaque 8-bit RGBA, the way textures are uploaded.
pub fn toRgba8(rendered: image.Rendered, out: [][4]u8) void {
    std.debug.assert(out.len == rendered.pixels.len);
    const table: Srgb8 = .init();
    for (out, rendered.pixels) |*o, p| o.* = .{ table.of(p[0]), table.of(p[1]), table.of(p[2]), std.math.maxInt(u8) };
}

pub fn toSrgb16(gpa: std.mem.Allocator, rendered: image.Rendered) !image.Encoded16 {
    const out: image.Encoded16 = try .init(gpa, rendered.width, rendered.height);
    for (out.pixels, rendered.pixels) |*o, p| {
        for (o, p) |*c, v| c.* = quantise(u16, srgb(v));
    }
    return out;
}

test "8-bit encoding through the table is within a step of the curve" {
    const gpa = std.testing.allocator;
    var rendered: image.Rendered = try .init(gpa, 1000, 1);
    defer rendered.deinit(gpa);
    for (rendered.pixels, 0..) |*p, i| {
        const v = std.math.pow(f32, @as(f32, @floatFromInt(i)) / 999, 3);
        p.* = .{ v, v, v };
    }
    var encoded = try toSrgb8(gpa, rendered);
    defer encoded.deinit(gpa);
    for (encoded.pixels, rendered.pixels) |e, p| {
        const exact: i32 = quantise(u8, srgb(p[0]));
        try std.testing.expect(@abs(@as(i32, e[0]) - exact) <= 1);
    }
}

test "the sRGB curve meets its ends and its knee" {
    try std.testing.expectEqual(@as(f32, 0), srgb(0));
    try std.testing.expectApproxEqAbs(@as(f32, 1), srgb(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.04045), srgb(0.0031308), 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), linearFromSrgb(srgb(0.2)), 1e-5);
}
