//! Dust removal from an infrared plane. The dyes in colour film let near infrared through, but
//! dust, hairs and scratches block it, so a scan taken in infrared is a map of the defects: where
//! they are and how much light they take. It doesn't work on silver black and white film, whose
//! silver blocks infrared too, and Kodachrome's cyan dye shows in it more than other films'.
//! docs/infrared.md has the reasoning and the sources.
//!
//! The steps, on a frame's scan and its plane, lined up and the same size:
//!
//! 1. Work in density, like `dust.zig`: −log10 of the transmission.
//! 2. Take out the picture. The IR plane carries a faint copy of the picture, mostly from the
//!    cyan dye. How much is fitted from the fine detail of the red channel and the plane, away
//!    from the defects, and that much of the red's density is taken off the plane's. A film whose
//!    plane follows the picture closely isn't one infrared works on, and is refused.
//! 3. Measure each pixel against the clear film around it: the plane's opening (the minimum over
//!    a square, then the maximum) is the film without the defects, and what stands up from it is
//!    how much infrared a defect blocks.
//! 4. A defect that leaves some light through dimmed the picture under it by about as much as it
//!    dimmed the infrared, so dividing by that brings the picture back. One that blocks nearly all
//!    of it leaves nothing to bring back, and is filled from the film nearby (`dust.fillMask`).
//!
//! A plane where too much of the frame stands out isn't a map of defects either, and is refused.

const std = @import("std");
const image = @import("image.zig");
const dust = @import("dust.zig");

const Code = dust.Code;
const steps_per_density = dust.steps_per_density;

/// How well a film suits infrared dust removal.
pub const Fit = enum {
    /// Colour film, and chromogenic black and white like XP2: its dyes let infrared through.
    suits,
    /// Kodachrome: its cyan dye shows in the plane, so fine detail can soften.
    poor,
    /// Silver black and white: the silver blocks infrared, so the picture looks like dust.
    unsuitable,
};

/// A frame's infrared dust removal, saved with its dust settings.
pub const Settings = struct {
    /// How much infrared a defect has to block to count, in D. Lower finds fainter dust, and
    /// more of the film's own unevenness by mistake.
    threshold: f32 = default_threshold,
    /// How far round each filled defect the fill reaches, in percent of the frame's longer side,
    /// for its soft edge and the plane being a little out of line with the scan.
    grow: f32 = default_grow,

    /// 0.03 D is about 7% of the light. Below that, the plane's own noise comes in.
    pub const default_threshold = 0.05;
    pub const min_threshold = 0.03;
    pub const max_threshold = 0.3;
    /// 0.05% is about 3 pixels on a 35mm frame at 4000 dpi.
    pub const default_grow = 0.05;
    pub const min_grow = 0;
    pub const max_grow = 0.3;

    comptime {
        for ([_][3]f32{
            .{ min_threshold, default_threshold, max_threshold },
            .{ min_grow, default_grow, max_grow },
        }) |range| if (!(range[0] <= range[1] and range[1] <= range[2])) @compileError("an infrared default is outside its range");
    }
};

pub const Error = error{
    /// The plane isn't a map of defects: it follows the picture too closely, or too much of it
    /// stands out. Silver black and white film does that, and so can Kodachrome.
    InfraredNotUsable,
};

/// The widest defect the opening flattens, in percent of the frame's longer side. Hairs and
/// scratches can be longer, but they're thin, and it's the width that counts.
const widest_defect = 1.2;
/// A defect blocking more than this, in D, leaves too little light to bring the picture back
/// from, and is filled instead. 0.5 D lets about a third through.
const opaque_density = 0.5;
/// More than this share of the frame standing out means the plane isn't a map of defects.
const max_defect_share = 0.05;
/// The plane following the red channel by more than this means the film isn't one infrared
/// works on: on colour film it's a few percent.
const max_leak = 0.5;
/// How far round a defect is left out when fitting the picture's copy in the plane, in pixels.
const leak_guard = 2;
/// The furthest `alignment` looks for the plane's shift, in pixels each way.
pub const max_shift = 4;
/// The most of the scan's middle `alignment` looks at, along each side.
const alignment_window = 1024;
/// Frames smaller than this along their longer side are left alone, as in `dust.zig`.
pub const min_frame = dust.min_frame;

/// Returns a copy of `scan` with the defects in `plane` taken out, or null when the frame is too
/// small to have any worth removing. `plane` is lined up with `scan` and the same size.
/// `frame_longest` is the frame's longer side at `scan`'s resolution. The caller frees the copy.
pub fn cleaned(gpa: std.mem.Allocator, scan: image.Scan, plane: image.Plane, settings: Settings, frame_longest: usize) (Error || error{OutOfMemory})!?image.Scan {
    std.debug.assert(plane.width == scan.width and plane.height == scan.height);
    const n = scan.pixels.len;
    if (n == 0 or frame_longest < min_frame) return null;
    const table = try dust.densityTable(gpa);
    defer gpa.free(table);
    const reach = dust.squareReach(frame_longest, widest_defect);

    // The plane's density, and how far each pixel stands up from the film around it.
    const infrared = try gpa.alloc(Code, n);
    defer gpa.free(infrared);
    for (infrared, plane.pixels) |*d, p| d.* = table[p[0]];
    const red = try gpa.alloc(Code, n);
    defer gpa.free(red);
    for (red, scan.pixels) |*d, p| d.* = table[p[0]];
    const excess = try gpa.alloc(Code, n);
    defer gpa.free(excess);
    const threshold: Code = @intFromFloat(settings.threshold * steps_per_density);

    // A first look at the defects, so the picture's copy is fitted away from them.
    try topHat(gpa, infrared, plane.width, plane.height, reach, excess);
    const guard = try gpa.alloc(u8, n);
    defer gpa.free(guard);
    for (guard, excess) |*g, e| g.* = @intFromBool(e > threshold);
    try dust.filter(u8, .max, gpa, guard, plane.width, plane.height, leak_guard);
    const leak = leakOf(infrared, red, guard, plane.width);
    if (leak > max_leak) return error.InfraredNotUsable;

    // Take the picture's copy out, and measure the defects again.
    if (leak > 0) {
        const offset = leak * @as(f32, @floatFromInt(std.mem.max(Code, red)));
        for (infrared, red) |*d, r| {
            const corrected = @as(f32, @floatFromInt(d.*)) - leak * @as(f32, @floatFromInt(r)) + offset;
            d.* = @intFromFloat(std.math.clamp(@round(corrected), 0, std.math.maxInt(Code)));
        }
        try topHat(gpa, infrared, plane.width, plane.height, reach, excess);
    }
    var defects: usize = 0;
    for (excess) |e| defects += @intFromBool(e > threshold);
    if (@as(f32, @floatFromInt(defects)) > max_defect_share * @as(f32, @floatFromInt(n))) return error.InfraredNotUsable;

    var result: image.Scan = .{ .width = scan.width, .height = scan.height, .pixels = try gpa.dupe([image.channel_count]u16, scan.pixels) };
    errdefer result.deinit(gpa);
    if (defects == 0) return result;

    // Thin defects are divided out; opaque ones are filled.
    const opaque_code: Code = @intFromFloat(opaque_density * steps_per_density);
    const fill = try gpa.alloc(bool, n);
    defer gpa.free(fill);
    var any_opaque = false;
    for (result.pixels, excess, fill) |*p, e, *f| {
        f.* = e >= opaque_code;
        any_opaque = any_opaque or f.*;
        if (e <= threshold or f.*) continue;
        const gain = std.math.pow(f32, 10, @as(f32, @floatFromInt(e)) / steps_per_density);
        for (p) |*v| v.* = @intFromFloat(@min(@round(@as(f32, @floatFromInt(v.*)) * gain), image.full_scale));
    }
    if (any_opaque) _ = try dust.fillMask(gpa, result, fill, dust.squareReach(frame_longest, settings.grow) * @intFromBool(settings.grow > 0));
    return result;
}

/// Fills `out` with how far each of `values` stands up from its opening over squares reaching
/// `reach`: the defects, with the film's own slow changes taken away.
fn topHat(gpa: std.mem.Allocator, values: []const Code, width: usize, height: usize, reach: usize, out: []Code) !void {
    const background = try gpa.dupe(Code, values);
    defer gpa.free(background);
    try dust.opening(gpa, background, width, height, reach);
    for (out, values, background) |*o, v, b| o.* = v - b;
}

/// How much of the red channel's fine detail shows in the plane: the least-squares slope of the
/// plane's density steps from one pixel to the next against the red's, left of the pixels
/// `guard` marks. Steps are taken along each row, so the film's slow changes don't count.
fn leakOf(infrared: []const Code, red: []const Code, guard: []const u8, width: usize) f32 {
    var cross: f64 = 0;
    var squares: f64 = 0;
    for (1..infrared.len) |i| {
        if (i % width == 0 or guard[i] != 0 or guard[i - 1] != 0) continue;
        const di = @as(f64, @floatFromInt(infrared[i])) - @as(f64, @floatFromInt(infrared[i - 1]));
        const dr = @as(f64, @floatFromInt(red[i])) - @as(f64, @floatFromInt(red[i - 1]));
        cross += di * dr;
        squares += dr * dr;
    }
    if (squares == 0) return 0;
    return @floatCast(@max(0, cross / squares));
}

/// How far `plane` is out of line with `scan`, in whole pixels: the shift, up to `max_shift` each
/// way, that lines the plane's fine detail up best with the red channel's. Both show the dust,
/// and the plane shows a little of the picture too. `aligned` with the shift lines the plane up.
pub fn alignment(gpa: std.mem.Allocator, scan: image.Scan, plane: image.Plane) ![2]i32 {
    std.debug.assert(plane.width == scan.width and plane.height == scan.height);
    const margin = max_shift + 1;
    if (scan.width <= 2 * margin or scan.height <= 2 * margin) return .{ 0, 0 };
    const table = try dust.densityTable(gpa);
    defer gpa.free(table);
    // The middle of the scan, at most `alignment_window` on a side.
    const width = @min(scan.width - 2 * margin, alignment_window);
    const height = @min(scan.height - 2 * margin, alignment_window);
    const x0 = (scan.width - width) / 2;
    const y0 = (scan.height - height) / 2;
    const red = try detail(gpa, table, scan, x0, y0, width, height, 0, .{ 0, 0 });
    defer gpa.free(red);
    // No shift wins unless another lines up better, so a plane with nothing to line up stays put.
    var best: [2]i32 = .{ 0, 0 };
    var best_score = try match(gpa, table, red, plane, x0, y0, width, height, best);
    var dy: i32 = -max_shift;
    while (dy <= max_shift) : (dy += 1) {
        var dx: i32 = -max_shift;
        while (dx <= max_shift) : (dx += 1) {
            const score = try match(gpa, table, red, plane, x0, y0, width, height, .{ dx, dy });
            if (score > best_score) {
                best_score = score;
                best = .{ dx, dy };
            }
        }
    }
    return best;
}

/// How well the plane's fine detail, moved by `shift`, lines up with `red`'s: their correlation.
fn match(gpa: std.mem.Allocator, table: []const Code, red: []const f32, plane: image.Plane, x0: usize, y0: usize, width: usize, height: usize, shift: [2]i32) !f64 {
    const infrared = try detail(gpa, table, plane, x0, y0, width, height, 0, shift);
    defer gpa.free(infrared);
    var score: f64 = 0;
    for (red, infrared) |r, i| score += r * i;
    return score;
}

/// The fine detail of channel `channel` of `picture` in the `width` × `height` area at `x0`,
/// `y0`, moved by `shift`: each pixel's density less its right and lower neighbours' mean. The
/// caller frees it.
fn detail(gpa: std.mem.Allocator, table: []const Code, picture: anytype, x0: usize, y0: usize, width: usize, height: usize, channel: usize, shift: [2]i32) ![]f32 {
    const out = try gpa.alloc(f32, width * height);
    for (0..height) |y| for (0..width) |x| {
        const px: usize = @intCast(@as(i64, @intCast(x0 + x)) + shift[0]);
        const py: usize = @intCast(@as(i64, @intCast(y0 + y)) + shift[1]);
        const here: f32 = @floatFromInt(table[picture.at(px, py)[channel]]);
        const right: f32 = @floatFromInt(table[picture.at(px + 1, py)[channel]]);
        const below: f32 = @floatFromInt(table[picture.at(px, py + 1)[channel]]);
        out[y * width + x] = here - (right + below) / 2;
    };
    return out;
}

/// Returns a copy of `plane` with each pixel taken from `shift` away (`alignment`), so it lines
/// up with its scan. The edges it moves away from repeat the nearest row or column. The caller frees it.
pub fn aligned(gpa: std.mem.Allocator, plane: image.Plane, shift: [2]i32) !image.Plane {
    var result: image.Plane = try .init(gpa, plane.width, plane.height);
    const last_x: i64 = @intCast(plane.width - 1);
    const last_y: i64 = @intCast(plane.height - 1);
    for (0..plane.height) |y| for (0..plane.width) |x| {
        const sx: usize = @intCast(std.math.clamp(@as(i64, @intCast(x)) + shift[0], 0, last_x));
        const sy: usize = @intCast(std.math.clamp(@as(i64, @intCast(y)) + shift[1], 0, last_y));
        result.pixels[y * plane.width + x] = plane.at(sx, sy);
    };
    return result;
}

// Tests -------------------------------------------------------------------------------------------

/// A test frame: colour film with grain, and its plane, clear but for the film's own faint copy of
/// the red channel (`leak`).
const TestFrame = struct {
    scan: image.Scan,
    plane: image.Plane,

    const clear = 50000;

    fn init(gpa: std.mem.Allocator, leak: f32) !TestFrame {
        const scan = try dust.testFilm(gpa, 800, 600, .{ .density = 0.02 });
        errdefer gpa.free(scan.pixels);
        const plane: image.Plane = try .init(gpa, scan.width, scan.height);
        for (plane.pixels, scan.pixels) |*ir, p| {
            const red_density = -std.math.log10(@as(f32, @floatFromInt(@max(p[0], 1))) / image.full_scale);
            ir.* = .{@intFromFloat(clear * std.math.pow(f32, 10, -leak * red_density))};
        }
        return .{ .scan = scan, .plane = plane };
    }

    fn deinit(frame: *TestFrame, gpa: std.mem.Allocator) void {
        frame.scan.deinit(gpa);
        frame.plane.deinit(gpa);
    }

    /// A round defect blocking `density` of the light, visible and infrared alike.
    fn defect(frame: TestFrame, cx: usize, cy: usize, radius: usize, density: f32) void {
        dust.addDisc(frame.scan, cx, cy, radius, density);
        dust.addDisc(frame.plane, cx, cy, radius, density);
    }
};

test "a faint defect is divided out and an opaque one filled, and the rest is left alone" {
    const gpa = std.testing.allocator;
    var film = try TestFrame.init(gpa, 0.03);
    defer film.deinit(gpa);
    var dirty = try TestFrame.init(gpa, 0.03);
    defer dirty.deinit(gpa);
    dirty.defect(200, 200, 3, 0.2);
    dirty.defect(500, 300, 4, 1.5);
    var clean = (try cleaned(gpa, dirty.scan, dirty.plane, .{}, dirty.scan.width)).?;
    defer clean.deinit(gpa);
    // The faint one comes back to the film under it, to within rounding.
    try std.testing.expectApproxEqAbs(dust.densityAround(film.scan, 200, 200, 3), dust.densityAround(clean, 200, 200, 3), 0.01);
    // The opaque one is filled from the film round it, to within the grain.
    try std.testing.expectApproxEqAbs(dust.densityAround(film.scan, 500, 300, 4), dust.densityAround(clean, 500, 300, 4), 0.05);
    // Away from both, nothing changed.
    var changed: usize = 0;
    for (clean.pixels, dirty.scan.pixels) |after, before| changed += @intFromBool(!std.meta.eql(after, before));
    try std.testing.expect(changed < 200);
}

test "a plane that follows the picture, like silver film's, is refused" {
    const gpa = std.testing.allocator;
    var silver = try TestFrame.init(gpa, 1);
    defer silver.deinit(gpa);
    try std.testing.expectError(error.InfraredNotUsable, cleaned(gpa, silver.scan, silver.plane, .{}, silver.scan.width));
}

test "a clean plane leaves the scan as it is, and a small frame is left alone" {
    const gpa = std.testing.allocator;
    var film = try TestFrame.init(gpa, 0.03);
    defer film.deinit(gpa);
    var clean = (try cleaned(gpa, film.scan, film.plane, .{}, film.scan.width)).?;
    defer clean.deinit(gpa);
    try std.testing.expectEqualSlices([image.channel_count]u16, film.scan.pixels, clean.pixels);
    try std.testing.expectEqual(null, try cleaned(gpa, film.scan, film.plane, .{}, min_frame - 1));
}

test "a plane out of line with its scan is found and moved back" {
    const gpa = std.testing.allocator;
    var frame = try TestFrame.init(gpa, 0.03);
    defer frame.deinit(gpa);
    for ([_][2]usize{ .{ 100, 100 }, .{ 300, 450 }, .{ 650, 200 }, .{ 420, 330 } }) |at| frame.defect(at[0], at[1], 3, 0.8);
    // The plane, taken two pixels right and one down of the scan.
    const shift: [2]i32 = .{ 2, -1 };
    var off = try aligned(gpa, frame.plane, .{ -shift[0], -shift[1] });
    defer off.deinit(gpa);
    try std.testing.expectEqual(shift, try alignment(gpa, frame.scan, off));
    var back = try aligned(gpa, off, shift);
    defer back.deinit(gpa);
    // Away from the edges, it's the plane it was.
    try std.testing.expectEqual(frame.plane.at(400, 300), back.at(400, 300));
}
