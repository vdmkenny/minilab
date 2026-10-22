//! Rendered linear values to encoded output, with the sRGB transfer curve.

const std = @import("std");
const image = @import("image.zig");

/// The sRGB transfer curve: linear 0..1 to encoded 0..1.
pub fn srgb(linear: f32) f32 {
    const v = std.math.clamp(linear, 0, 1);
    return if (v <= 0.0031308) 12.92 * v else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

/// The sRGB transfer curve backwards: encoded 0..1 to linear 0..1.
pub fn linearFromSrgb(encoded: f32) f32 {
    const v = std.math.clamp(encoded, 0, 1);
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn quantise(comptime T: type, v: f32) T {
    const top: f32 = @floatFromInt(std.math.maxInt(T));
    return @intFromFloat(@round(v * top));
}

/// Entries of the table `toSrgb8` encodes through: fine enough that the deepest shadows, where
/// the curve is steepest, are off by at most one step of 255.
const table_entries = 1 << 14;

pub fn toSrgb8(gpa: std.mem.Allocator, rendered: image.Rendered) !image.Encoded8 {
    const out: image.Encoded8 = try .init(gpa, rendered.width, rendered.height);
    // A table is a few times faster than the power function, and 8 bits don't need more.
    var table: [table_entries + 1]u8 = undefined;
    for (&table, 0..) |*t, i| t.* = quantise(u8, srgb(@as(f32, @floatFromInt(i)) / table_entries));
    for (out.pixels, rendered.pixels) |*o, p| {
        for (o, p) |*c, v| c.* = table[@intFromFloat(@round(std.math.clamp(v, 0, 1) * table_entries))];
    }
    return out;
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
