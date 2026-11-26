//! Sharpening: a mild unsharp mask on a developed frame, like the capture sharpening photo editors
//! offer. Scans are a little soft, from the scanner's optics and the film itself, and this brings
//! back some crispness. docs/design.md (Sharpening) has the sources.
//!
//! 1. Work on lightness only, CIE L*, so colours don't fringe, as darktable's and RawTherapee's
//!    unsharp masks do. L* is closer to how much a change shows than linear light is.
//! 2. Blur the lightness with a Gaussian `radius` pixels wide (its sigma), measured on the full
//!    scan. On a smaller copy, like Develop's viewer, the radius shrinks with it, so the copy looks
//!    like the full size would scaled down. Below a quarter of a pixel there's nothing to see, and
//!    it's left alone.
//! 3. The detail is the lightness less its blur. Detail smaller than `threshold` is film grain or
//!    noise, and is left out, the rest is shrunk by it (darktable's soft threshold), so grain isn't
//!    sharpened into noise.
//! 4. Add `amount` of the detail back to the lightness, and scale each pixel's colour by how much
//!    its luminance changed, as RawTherapee does, so its hue and saturation stay.

const std = @import("std");
const image = @import("image.zig");
const encode = @import("encode.zig");
const parallel = @import("parallel.zig");

/// A frame's sharpening, saved with its develop settings.
pub const Settings = struct {
    on: bool = false,
    /// How much of the detail is added back: 0.5 brings edges half as far again.
    amount: f32 = default_amount,
    /// How wide the detail sharpened is: the blur's sigma, in pixels of the full scan.
    radius: f32 = default_radius,
    /// The smallest detail sharpened, in L*, 0 to 100. Below it is grain and noise.
    threshold: f32 = default_threshold,

    /// darktable's sharpen starts at 0.5. Past 1.5, halos show round edges.
    pub const default_amount = 0.5;
    pub const min_amount = 0;
    pub const max_amount = 1.5;
    /// Capture sharpening uses about a pixel, rarely more than two, on a full-resolution scan.
    pub const default_radius = 0.9;
    pub const min_radius = 0.3;
    pub const max_radius = 3;
    /// darktable's default, on the same 0 to 100 scale.
    pub const default_threshold = 0.5;
    pub const min_threshold = 0;
    pub const max_threshold = 5;

    comptime {
        for ([_][3]f32{
            .{ min_amount, default_amount, max_amount },
            .{ min_radius, default_radius, max_radius },
            .{ min_threshold, default_threshold, max_threshold },
        }) |range| if (!(range[0] <= range[1] and range[1] <= range[2])) @compileError("a sharpening default is outside its range");
    }

    /// The blur's sigma on a copy `scale` times the full scan's size, or null when that's too small
    /// to show, or sharpening is off.
    pub fn sigmaAt(settings: Settings, scale: f64) ?f32 {
        if (!settings.on or settings.amount <= 0) return null;
        const sigma: f32 = @floatCast(settings.radius * scale);
        return if (sigma < min_sigma) null else sigma;
    }
};

/// A blur narrower than this, in pixels, changes nothing that shows.
const min_sigma = 0.25;
/// The Gaussian is cut off this many sigmas out, where it's under half a percent.
const kernel_reach = 3;
/// The darkest luminance whose colour is scaled. Below it, a tiny luminance would make a huge
/// ratio out of rounding.
const darkest = 1e-5;
/// Rows a thread takes at a time, at the least.
const min_rows_per_band = 32;

/// Sharpens `picture`, linear light from 0 to 1 in the scanner's RGB, in place, as `settings` say.
/// `scale` is the picture's size over the full scan's: 1 for an export at full size, less for a
/// reduced copy.
pub fn apply(gpa: std.mem.Allocator, picture: image.Rendered, settings: Settings, scale: f64) !void {
    const sigma = settings.sigmaAt(scale) orelse return;
    const n = picture.pixels.len;
    if (n == 0) return;
    const lightness = try gpa.alloc(f32, n);
    defer gpa.free(lightness);
    for (lightness, picture.pixels) |*l, p| l.* = @floatCast(encode.lightness(std.math.clamp(encode.luminance(p), 0, 1)));
    const blurred = try gpa.alloc(f32, n);
    defer gpa.free(blurred);
    try gaussian(gpa, lightness, blurred, picture.width, picture.height, sigma);
    for (picture.pixels, lightness, blurred) |*p, l, b| {
        const y = encode.luminance(p.*);
        if (y < darkest) continue;
        const d = l - b;
        const detail = std.math.sign(d) * @max(@abs(d) - settings.threshold, 0);
        if (detail == 0) continue;
        const sharper: f32 = @floatCast(encode.luminanceOfLightness(std.math.clamp(l + settings.amount * detail, 0, 100)));
        const ratio = sharper / y;
        for (p) |*v| v.* = @max(v.* * ratio, 0);
    }
}

/// How far round each pixel `apply` reads, in the picture's pixels, for a picture `scale` times the
/// full scan's size: the part of a bigger picture to sharpen with a piece, so its edges come out as
/// they would in the whole.
pub fn margin(settings: Settings, scale: f64) usize {
    const sigma = settings.sigmaAt(scale) orelse return 0;
    return kernelRadius(sigma);
}

fn kernelRadius(sigma: f32) usize {
    return @intFromFloat(@ceil(kernel_reach * sigma));
}

/// Blurs `values`, a `width` × `height` plane, into `out` with a Gaussian of `sigma`: across, then
/// down, over the cores. Past the edges, the edge pixel carries on.
fn gaussian(gpa: std.mem.Allocator, values: []const f32, out: []f32, width: usize, height: usize, sigma: f32) !void {
    const reach = kernelRadius(sigma);
    const kernel = try gpa.alloc(f32, 2 * reach + 1);
    defer gpa.free(kernel);
    var sum: f32 = 0;
    for (kernel, 0..) |*k, i| {
        const x = @as(f32, @floatFromInt(i)) - @as(f32, @floatFromInt(reach));
        k.* = @exp(-x * x / (2 * sigma * sigma));
        sum += k.*;
    }
    for (kernel) |*k| k.* /= sum;
    const across = try gpa.alloc(f32, values.len);
    defer gpa.free(across);
    const bands = parallel.bandCount(height, min_rows_per_band);
    parallel.inBands(height, bands, Blur{ .from = values, .to = across, .width = width, .height = height, .kernel = kernel, .way = .across });
    parallel.inBands(height, bands, Blur{ .from = across, .to = out, .width = width, .height = height, .kernel = kernel, .way = .down });
}

/// One pass of `gaussian` over a band of rows.
const Blur = struct {
    from: []const f32,
    to: []f32,
    width: usize,
    height: usize,
    kernel: []const f32,
    way: enum { across, down },

    pub fn run(job: Blur, _: usize, first: usize, end: usize) void {
        const reach: isize = @intCast(job.kernel.len / 2);
        for (first..end) |y| for (0..job.width) |x| {
            var sum: f32 = 0;
            for (job.kernel, 0..) |k, i| {
                const offset = @as(isize, @intCast(i)) - reach;
                const at = switch (job.way) {
                    .across => y * job.width + clampTo(x, offset, job.width),
                    .down => clampTo(y, offset, job.height) * job.width + x,
                };
                sum += k * job.from[at];
            }
            job.to[y * job.width + x] = sum;
        };
    }

    fn clampTo(at: usize, offset: isize, length: usize) usize {
        return @intCast(std.math.clamp(@as(isize, @intCast(at)) + offset, 0, @as(isize, @intCast(length)) - 1));
    }
};

// Tests -------------------------------------------------------------------------------------------

/// A test picture: a soft step from dark grey to light grey across, in one colour, with `grain`
/// added to the lightness of every pixel.
fn testStep(gpa: std.mem.Allocator, grain: f32) !image.Rendered {
    const picture: image.Rendered = try .init(gpa, 64, 16);
    var random: std.Random.DefaultPrng = .init(1);
    for (picture.pixels, 0..) |*p, i| {
        const x: f32 = @floatFromInt(i % picture.width);
        const step = 0.1 + 0.3 * std.math.clamp((x - 30) / 4, 0, 1);
        const noise = grain * (random.random().float(f32) - 0.5);
        p.* = .{ step * 1.2 + noise, step + noise, step * 0.8 + noise };
    }
    return picture;
}

fn contrastAcross(picture: image.Rendered) f32 {
    const row = 8 * picture.width;
    return encode.luminance(picture.pixels[row + 34]) - encode.luminance(picture.pixels[row + 30]);
}

test "an edge gets crisper, its colour stays, and flat film is left alone" {
    const gpa = std.testing.allocator;
    var picture = try testStep(gpa, 0);
    defer picture.deinit(gpa);
    const before = contrastAcross(picture);
    const flat = picture.pixels[8 * picture.width + 5];
    try apply(gpa, picture, .{ .on = true, .amount = 1, .radius = 1.5 }, 1);
    try std.testing.expect(contrastAcross(picture) > before);
    // Flat film far from the edge doesn't change.
    try std.testing.expectEqual(flat, picture.pixels[8 * picture.width + 5]);
    // A sharpened pixel keeps its hue: red over green stays where it was.
    const p = picture.pixels[8 * picture.width + 33];
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), p[0] / p[1], 1e-4);
}

test "grain below the threshold isn't sharpened" {
    const gpa = std.testing.allocator;
    var picture = try testStep(gpa, 0.004);
    defer picture.deinit(gpa);
    const away = picture.pixels[8 * picture.width + 5];
    try apply(gpa, picture, .{ .on = true, .amount = 1, .radius = 1, .threshold = 2 }, 1);
    try std.testing.expectEqual(away, picture.pixels[8 * picture.width + 5]);
}

test "off, or too small to show at this size, it does nothing" {
    const gpa = std.testing.allocator;
    var picture = try testStep(gpa, 0);
    defer picture.deinit(gpa);
    const before = try gpa.dupe([3]f32, picture.pixels);
    defer gpa.free(before);
    try apply(gpa, picture, .{}, 1);
    try apply(gpa, picture, .{ .on = true, .radius = 0.9 }, 0.2);
    try std.testing.expectEqualSlices([3]f32, before, picture.pixels);
    try std.testing.expectEqual(@as(usize, 0), margin(.{ .on = true, .radius = 0.9 }, 0.2));
    try std.testing.expectEqual(@as(usize, 3), margin(.{ .on = true, .radius = 0.9 }, 1));
}
