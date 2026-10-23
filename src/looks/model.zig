//! What a fitted look does to a frame. It takes over from Develop after the film base and density
//! stages, at the point where the Neutral look would invert:
//!
//! 1. The input is density per channel, 0..1: density above the film base, scaled by the density
//!    range and balanced by Develop, before any inversion curve. Develop gives exactly this with
//!    the Log tone, which stores it sRGB-encoded in its linear output.
//! 2. A 3 × 3 matrix in density handles crosstalk between the channels. Its rows add up to 1, so
//!    a grey stays grey; the curves take care of the tone.
//! 3. A monotone curve per channel takes density to sRGB-encoded output.
//! 4. Optionally, a 33³ LUT on the curves' output does what the matrix and curves can't.
//!
//! The output is linear sRGB 0..1, the same as Develop's other looks give.

const std = @import("std");
const curve = @import("curve.zig");
const colour = @import("colour.zig");

pub const Curve = curve.Curve;

pub const Matrix = [3][3]f32;
pub const identity_matrix: Matrix = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };

/// The number of grid points along each side of the LUT.
pub const lut_size = 33;
pub const lut_entries = lut_size * lut_size * lut_size;

/// A 3D LUT over encoded RGB 0..1, looked up with trilinear interpolation.
pub const Lut = struct {
    /// The output at each grid point, with red changing fastest, then green, then blue: the same
    /// order a .cube file uses.
    values: [lut_entries][3]f32,

    pub fn index(r: usize, g: usize, b: usize) usize {
        return (b * lut_size + g) * lut_size + r;
    }

    /// Returns the input colour at grid point `i`.
    pub fn input(i: usize) [3]f32 {
        const step = 1.0 / @as(f32, lut_size - 1);
        return .{
            @as(f32, @floatFromInt(i % lut_size)) * step,
            @as(f32, @floatFromInt(i / lut_size % lut_size)) * step,
            @as(f32, @floatFromInt(i / (lut_size * lut_size))) * step,
        };
    }

    /// Sets every grid point to its own input, so the LUT changes nothing.
    pub fn setIdentity(lut: *Lut) void {
        for (&lut.values, 0..) |*v, i| v.* = input(i);
    }

    pub fn lookup(lut: *const Lut, rgb: [3]f32) [3]f32 {
        var out: [3]f32 = @splat(0);
        for (corners(rgb)) |corner| {
            if (corner.weight == 0) continue;
            for (&out, lut.values[corner.index]) |*o, x| o.* += corner.weight * x;
        }
        return out;
    }

    /// One of the eight grid points around a colour, and how much it counts.
    pub const Corner = struct { index: usize, weight: f32 };

    /// The eight grid points around `rgb` and their trilinear weights, which add up to 1.
    pub fn corners(rgb: [3]f32) [8]Corner {
        var base: [3]usize = undefined;
        var frac: [3]f32 = undefined;
        for (&base, &frac, rgb) |*b, *f, v| {
            const t = std.math.clamp(v, 0, 1) * (lut_size - 1);
            b.* = @min(@as(usize, @intFromFloat(t)), lut_size - 2);
            f.* = t - @as(f32, @floatFromInt(b.*));
        }
        var out: [8]Corner = undefined;
        for (&out, 0..) |*c, corner| {
            const dr = corner & 1;
            const dg = corner >> 1 & 1;
            const db = corner >> 2 & 1;
            c.* = .{
                .index = index(base[0] + dr, base[1] + dg, base[2] + db),
                .weight = (if (dr == 1) frac[0] else 1 - frac[0]) *
                    (if (dg == 1) frac[1] else 1 - frac[1]) *
                    (if (db == 1) frac[2] else 1 - frac[2]),
            };
        }
        return out;
    }
};

pub const Model = struct {
    matrix: Matrix = identity_matrix,
    curves: [3]Curve = .{ curve.identity, curve.identity, curve.identity },
    /// Applied to the curves' output, if there is one. Whoever made the model owns it.
    lut: ?*const Lut = null,

    /// Returns the density after the matrix, plus the frame's balance offsets.
    pub fn mixed(model: *const Model, density: [3]f32, balance: [3]f32) [3]f32 {
        var out: [3]f32 = undefined;
        for (&out, model.matrix, balance) |*o, row, b| o.* = row[0] * density[0] + row[1] * density[1] + row[2] * density[2] + b;
        return out;
    }

    /// Returns the curves' output, encoded, before the LUT.
    pub fn curved(model: *const Model, density: [3]f32, balance: [3]f32) [3]f32 {
        const m = model.mixed(density, balance);
        var out: [3]f32 = undefined;
        for (&out, &model.curves, m) |*o, *c, v| o.* = curve.eval(c, v);
        return out;
    }

    /// Returns the look's output for `density`, sRGB-encoded 0..1. `balance` holds the frame's
    /// offsets in density, which are 0 outside a fit.
    pub fn encoded(model: *const Model, density: [3]f32, balance: [3]f32) [3]f32 {
        const out = model.curved(density, balance);
        const lut = model.lut orelse return out;
        var looked = lut.lookup(out);
        for (&looked) |*v| v.* = std.math.clamp(v.*, 0, 1);
        return looked;
    }

    /// Applies the look in place to `pixels`, which hold Develop's linear output with the Log tone
    /// (density, sRGB-encoded). Afterwards they're linear sRGB 0..1.
    pub fn apply(model: *const Model, pixels: [][3]f32) void {
        for (pixels) |*p| {
            const out = model.encoded(densityOf(p.*), @splat(0));
            for (p, out) |*v, e| v.* = colour.decode(e);
        }
    }
};

/// Returns the density that Develop's Log tone stores in a linear pixel, which is the pixel's
/// sRGB encoding.
pub fn densityOf(log_linear: [3]f32) [3]f32 {
    var d: [3]f32 = undefined;
    for (&d, log_linear) |*out, v| out.* = colour.encode(v);
    return d;
}

test "the identity LUT gives back its input" {
    const gpa = std.testing.allocator;
    const lut = try gpa.create(Lut);
    defer gpa.destroy(lut);
    lut.setIdentity();
    const out = lut.lookup(.{ 0.2, 0.55, 0.91 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.2), out[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.55), out[1], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.91), out[2], 1e-5);
}

test "the identity look turns Log output into its density, decoded" {
    const model: Model = .{};
    var pixels = [_][3]f32{.{ colour.decode(0.25), colour.decode(0.5), colour.decode(0.75) }};
    model.apply(&pixels);
    try std.testing.expectApproxEqAbs(colour.decode(0.25), pixels[0][0], 1e-4);
    try std.testing.expectApproxEqAbs(colour.decode(0.75), pixels[0][2], 1e-4);
}
