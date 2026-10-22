//! A pair's two images, read and made ready: our raw scan developed the way a look expects it,
//! and the reference. Then what registering, fitting and the page need from them.
//!
//! Ours is developed the way the command line develops a scan: the frame found on it by frame
//! detection, the film base measured in the gaps beside it (or the thinnest film in the frame),
//! and Develop's automatic settings for the rest. The Log tone gives the density a look starts
//! from; the Standard tone, the Neutral rendering the page shows. The reference is taken as sRGB;
//! an embedded profile isn't applied.
//!
//! An alignment is kept relative to the whole raw scan, so that it holds however the frame is
//! found; the working images are of the frame alone, and `Prepared.onFrame` moves an alignment
//! onto them.

const std = @import("std");
const negscan = @import("../root.zig");
const register = @import("register.zig");
const fit = @import("fit.zig");
const colour = @import("colour.zig");
const model = @import("model.zig");
const draft = @import("draft.zig");

const image = negscan.image;
const develop = negscan.develop;

/// The working copies' longer sides, in pixels.
pub const working_longest = 768;
/// Samples taken from each pair, about.
pub const samples_per_pair = 4096;
/// The largest file read.
const max_file_bytes = 2 << 30;
/// The darkest luminance the grey images tell apart, as a floor for the log.
const darkest = 1e-3;

/// An image reduced by a whole factor, with the size it was reduced from.
pub fn Reduced(comptime Pixel: type) type {
    return struct {
        width: usize,
        height: usize,
        pixels: []Pixel,
        /// Full-size pixels per pixel here.
        factor: f32,
        full: [2]f32,

        /// Bilinear between pixel centres at (x, y) in full-size pixels; null outside.
        pub fn sample(r: *const @This(), x: f32, y: f32) ?Pixel {
            const fx = x / r.factor - 0.5;
            const fy = y / r.factor - 0.5;
            if (fx < -0.5 or fy < -0.5) return null;
            const cx = std.math.clamp(fx, 0, @as(f32, @floatFromInt(r.width - 1)));
            const cy = std.math.clamp(fy, 0, @as(f32, @floatFromInt(r.height - 1)));
            if (fx > @as(f32, @floatFromInt(r.width)) - 0.5 or fy > @as(f32, @floatFromInt(r.height)) - 0.5) return null;
            const x0: usize = @min(@as(usize, @intFromFloat(cx)), r.width - 1);
            const y0: usize = @min(@as(usize, @intFromFloat(cy)), r.height - 1);
            const x1 = @min(x0 + 1, r.width - 1);
            const y1 = @min(y0 + 1, r.height - 1);
            const tx = cx - @as(f32, @floatFromInt(x0));
            const ty = cy - @as(f32, @floatFromInt(y0));
            var out: Pixel = undefined;
            for (&out, 0..) |*o, c| {
                const a: f32 = asFloat(r.pixels[y0 * r.width + x0][c]);
                const b: f32 = asFloat(r.pixels[y0 * r.width + x1][c]);
                const d: f32 = asFloat(r.pixels[y1 * r.width + x0][c]);
                const e: f32 = asFloat(r.pixels[y1 * r.width + x1][c]);
                const top = a + (b - a) * tx;
                const bottom = d + (e - d) * tx;
                o.* = fromFloat(@TypeOf(o.*), top + (bottom - top) * ty);
            }
            return out;
        }
    };
}

fn asFloat(v: anytype) f32 {
    return switch (@TypeOf(v)) {
        f32 => v,
        else => @floatFromInt(v),
    };
}

fn fromFloat(comptime T: type, v: f32) T {
    return switch (T) {
        f32 => v,
        else => @intFromFloat(@round(v)),
    };
}

/// A pair's images, ready.
pub const Prepared = struct {
    /// Our density, 0..1 per channel.
    density: Reduced([3]f32),
    /// Our Neutral rendering, sRGB 8-bit with alpha.
    neutral: Reduced([4]u8),
    /// The reference, sRGB-encoded 0..1.
    reference: Reduced([3]f32),
    /// Grey images for registering.
    ours_gray: register.Gray,
    reference_gray: register.Gray,
    /// The frame on our raw scan, which the working images show, and the scan's size.
    frame: image.Area,
    scan_size: [2]f32,

    pub fn deinit(p: *Prepared, gpa: std.mem.Allocator) void {
        gpa.free(p.density.pixels);
        gpa.free(p.neutral.pixels);
        gpa.free(p.reference.pixels);
        p.ours_gray.deinit(gpa);
        p.reference_gray.deinit(gpa);
        p.* = undefined;
    }

    /// Where the reference lies on our raw scan.
    pub fn locate(p: *const Prepared, gpa: std.mem.Allocator) !register.Alignment {
        const on_frame = try register.register(gpa, p.ours_gray, p.reference_gray);
        // From units of the frame's width, from its corner, to the scan's.
        const width: f32 = @floatFromInt(p.frame.width);
        var a = on_frame;
        a.scale = on_frame.scale * width / p.scan_size[0];
        a.offset[0] = (on_frame.offset[0] * width + @as(f32, @floatFromInt(p.frame.x))) / p.scan_size[0];
        a.offset[1] = (on_frame.offset[1] * width + @as(f32, @floatFromInt(p.frame.y))) / p.scan_size[0];
        return a;
    }

    /// `a`, an alignment on our raw scan, on the frame the working images show.
    pub fn onFrame(p: *const Prepared, a: register.Alignment) register.Alignment {
        const width: f32 = @floatFromInt(p.frame.width);
        var out = a;
        out.scale = a.scale * p.scan_size[0] / width;
        out.offset[0] = (a.offset[0] * p.scan_size[0] - @as(f32, @floatFromInt(p.frame.x))) / width;
        out.offset[1] = (a.offset[1] * p.scan_size[0] - @as(f32, @floatFromInt(p.frame.y))) / width;
        return out;
    }
};

/// Reads our scan at `ours` (a binary PPM, as the library keeps them) and the reference at
/// `theirs` (JPEG, TIFF or PPM).
pub fn prepare(gpa: std.mem.Allocator, io: std.Io, ours: []const u8, placement: ?draft.Placement, theirs: []const u8) !Prepared {
    var developed = try developScan(gpa, io, ours, working_longest, placement);
    errdefer developed.deinit(gpa);
    const reference = try readReference(gpa, io, theirs);
    errdefer gpa.free(reference.pixels);
    var reference_gray = try grayOfEncoded(gpa, reference);
    errdefer reference_gray.deinit(gpa);
    return .{
        .density = developed.density,
        .neutral = developed.neutral,
        .reference = reference,
        .ours_gray = developed.gray,
        .reference_gray = reference_gray,
        .frame = developed.frame,
        .scan_size = developed.scan_size,
    };
}

/// Our scan developed: its density, its Neutral rendering and its grey.
pub const Developed = struct {
    density: Reduced([3]f32),
    neutral: Reduced([4]u8),
    gray: register.Gray,
    /// The frame developed, on the raw scan, and the scan's size.
    frame: image.Area,
    scan_size: [2]f32,

    pub fn deinit(d: *Developed, gpa: std.mem.Allocator) void {
        gpa.free(d.density.pixels);
        gpa.free(d.neutral.pixels);
        d.gray.deinit(gpa);
    }
};

/// Reads the raw scan at `path` and develops it reduced to `longest` pixels: the frame on it,
/// when `find_frame` and frame detection finds one, or all of it.
pub fn developScan(gpa: std.mem.Allocator, io: std.Io, path: []const u8, longest: usize, placement: ?draft.Placement) !Developed {
    var raw = (try negscan.input.read(gpa, io, path)).scan;
    defer raw.deinit(gpa);
    // A frame of a roll: where the roll has it.
    if (placement) |p| {
        var placed = try p.apply(gpa, raw);
        defer placed.deinit(gpa);
        return developPlaced(gpa, placed, longest, p.film_base);
    }

    // A scan on its own: the frame and the base, as the command line finds them.
    var frame: image.Area = .whole(raw.width, raw.height);
    var gap_base: ?[3]f32 = null;
    {
        var reduced = try image.downscale(gpa, raw, negscan.framing.detection_longest);
        defer reduced.deinit(gpa);
        if (negscan.framing.findWithGaps(gpa, reduced, raw.width, raw.height, null, negscan.formats.Standard.default.format(), .colour_negative)) |found| {
            frame = found.frame;
            gap_base = negscan.framing.measureBase(gpa, raw, found.gaps) catch null;
        } else |_| {}
    }
    const cropped = frame.width != raw.width or frame.height != raw.height;
    var scan = if (cropped) try raw.crop(gpa, frame) else raw;
    defer if (cropped) scan.deinit(gpa);
    var developed = try developPlaced(gpa, scan, longest, gap_base);
    developed.frame = frame;
    developed.scan_size = .{ @floatFromInt(raw.width), @floatFromInt(raw.height) };
    return developed;
}

/// `scan`, already the frame, developed as Develop develops an undeveloped frame, on the film base
/// `gap_base` when it's known.
fn developPlaced(gpa: std.mem.Allocator, scan: image.Scan, longest: usize, gap_base: ?[3]f32) !Developed {
    const factor = image.reductionFactor(scan.width, scan.height, longest);
    var work = try image.downscale(gpa, scan, longest);
    defer work.deinit(gpa);
    const full: [2]f32 = .{ @floatFromInt(scan.width), @floatFromInt(scan.height) };

    // The automatic settings, measured as Develop measures an undeveloped frame.
    const stats = try develop.FrameStatistics.measure(gpa, work);
    var settings = develop.automatic(.colour_negative, gap_base orelse stats.whole.thinnest, stats.centre);
    // A channel clipped at full scale in the base and the shadows has nothing to balance by.
    for (&settings.highlight_balance, &settings.shadow_balance) |*high, *low| {
        if (!std.math.isFinite(high.*) or high.* <= 0) high.* = 1;
        if (!std.math.isFinite(low.*) or low.* <= 0) low.* = 1;
    }

    var standard = try develop.render(gpa, work, settings);
    defer standard.deinit(gpa);
    settings.tone = .log;
    var log = try develop.render(gpa, work, settings);
    defer log.deinit(gpa);

    const density = try gpa.alloc([3]f32, work.pixels.len);
    errdefer gpa.free(density);
    for (density, log.pixels) |*d, p| d.* = model.densityOf(p);
    const neutral = try gpa.alloc([4]u8, work.pixels.len);
    errdefer gpa.free(neutral);
    var gray: register.Gray = try .init(gpa, work.width, work.height);
    errdefer gray.deinit(gpa);
    gray.factor = @floatFromInt(factor);
    gray.full_width = full[0];
    gray.full_height = full[1];
    for (neutral, gray.pixels, standard.pixels) |*n, *g, p| {
        for (n[0..3], p) |*o, v| o.* = @intFromFloat(@round(colour.encode(v) * 255));
        n[3] = 255;
        g.* = std.math.log10(@max(colour.luminance(p), darkest));
    }
    const f: f32 = @floatFromInt(factor);
    return .{
        .density = .{ .width = work.width, .height = work.height, .pixels = density, .factor = f, .full = full },
        .neutral = .{ .width = work.width, .height = work.height, .pixels = neutral, .factor = f, .full = full },
        .gray = gray,
        .frame = .whole(scan.width, scan.height),
        .scan_size = full,
    };
}

/// The whole factor `image.downscale` reduces by.
/// Reads a reference: JPEG, TIFF or PPM, by its extension, reduced to the working size.
pub fn readReference(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Reduced([3]f32) {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(bytes);
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".jpg") or std.ascii.eqlIgnoreCase(extension, ".jpeg")) {
        var decoded = try negscan.codecs.jpeg.read(gpa, bytes);
        defer decoded.deinit(gpa);
        return reduce(u8, gpa, decoded.image.pixels, decoded.image.width, decoded.image.height);
    }
    var scan = if (std.ascii.eqlIgnoreCase(extension, ".tif") or std.ascii.eqlIgnoreCase(extension, ".tiff")) blk: {
        const decoded = try negscan.codecs.tiff.read(gpa, bytes);
        if (decoded.icc_profile) |p| gpa.free(p);
        break :blk decoded.scan;
    } else try negscan.pnm.read(gpa, bytes);
    defer scan.deinit(gpa);
    return reduce(u16, gpa, scan.pixels, scan.width, scan.height);
}

/// `pixels` reduced by a whole factor to the working size, as encoded values 0..1.
fn reduce(comptime Sample: type, gpa: std.mem.Allocator, pixels: []const [3]Sample, width: usize, height: usize) !Reduced([3]f32) {
    const factor = image.reductionFactor(width, height, working_longest);
    const w = width / factor;
    const h = height / factor;
    // A side shorter than the factor has no whole block to average.
    if (w == 0 or h == 0) return error.ImageTooSmall;
    const out = try gpa.alloc([3]f32, w * h);
    const scale = 1.0 / @as(f32, @floatFromInt(std.math.maxInt(Sample))) / @as(f32, @floatFromInt(factor * factor));
    for (0..h) |y| {
        for (0..w) |x| {
            var sum: [3]u64 = @splat(0);
            for (0..factor) |dy| {
                for (pixels[(y * factor + dy) * width + x * factor ..][0..factor]) |p| {
                    for (&sum, p) |*s, v| s.* += v;
                }
            }
            for (&out[y * w + x], sum) |*o, s| o.* = @as(f32, @floatFromInt(s)) * scale;
        }
    }
    return .{ .width = w, .height = h, .pixels = out, .factor = @floatFromInt(factor), .full = .{ @floatFromInt(width), @floatFromInt(height) } };
}

/// The log of an encoded image's luminance, for registering.
fn grayOfEncoded(gpa: std.mem.Allocator, encoded: Reduced([3]f32)) !register.Gray {
    var gray: register.Gray = try .init(gpa, encoded.width, encoded.height);
    gray.factor = encoded.factor;
    gray.full_width = encoded.full[0];
    gray.full_height = encoded.full[1];
    for (gray.pixels, encoded.pixels) |*g, p| {
        var linear_rgb: [3]f32 = undefined;
        for (&linear_rgb, p) |*l, e| l.* = colour.decode(e);
        g.* = std.math.log10(@max(colour.luminance(linear_rgb), darkest));
    }
    return gray;
}

/// The part of ours the reference covers, in our working pixels, kept inside ours: x0, y0, x1, y1.
/// `a` is on the frame.
fn overlap(p: *const Prepared, a: register.Alignment) [4]usize {
    const box = a.extent(p.density.full[0], p.reference.full);
    const f = p.density.factor;
    const w: f32 = @floatFromInt(p.density.width);
    const h: f32 = @floatFromInt(p.density.height);
    return .{
        @intFromFloat(std.math.clamp(@ceil(box[0] / f), 0, w)),
        @intFromFloat(std.math.clamp(@ceil(box[1] / f), 0, h)),
        @intFromFloat(std.math.clamp(@floor(box[2] / f), 0, w)),
        @intFromFloat(std.math.clamp(@floor(box[3] / f), 0, h)),
    };
}

/// The reference's colour at our working pixel (x, y), or null outside it.
fn referenceAt(p: *const Prepared, a: register.Alignment, x: f32, y: f32) ?[3]f32 {
    const fx = (x + 0.5) * p.density.factor;
    const fy = (y + 0.5) * p.density.factor;
    const at = a.toReference(fx, fy, p.density.full[0], p.reference.full);
    return p.reference.sample(at[0], at[1]);
}

/// Samples of pair number `pair` for a fit, appended to `out`: blocks on an even grid over the
/// part both images show, a little in from its edges. Each holds our mean density and the
/// reference's mean colour there. Blocks with clipped values are left out, and busy ones, where a
/// small misalignment would show, count for less. `alignment` is on our raw scan.
pub fn sample(gpa: std.mem.Allocator, p: *const Prepared, alignment: register.Alignment, pair: u16, out: *std.ArrayList(fit.Sample)) !void {
    const a = p.onFrame(alignment);
    const box = overlap(p, a);
    if (box[2] <= box[0] + 8 or box[3] <= box[1] + 8) return;
    const margin_x = (box[2] - box[0]) / 30 + 2;
    const margin_y = (box[3] - box[1]) / 30 + 2;
    const x0 = box[0] + margin_x;
    const y0 = box[1] + margin_y;
    const x1 = box[2] - margin_x;
    const y1 = box[3] - margin_y;
    const area: f32 = @floatFromInt((x1 - x0) * (y1 - y0));
    const step: usize = @max(3, @as(usize, @intFromFloat(@sqrt(area / samples_per_pair))));
    const radius: usize = @max(1, step / 3);

    var y = y0 + radius;
    while (y + radius < y1) : (y += step) {
        var x = x0 + radius;
        while (x + radius < x1) : (x += step) {
            var density: [3]f32 = @splat(0);
            var target: [3]f32 = @splat(0);
            var ours_sum: f32 = 0;
            var ours_square: f32 = 0;
            var theirs_sum: f32 = 0;
            var theirs_square: f32 = 0;
            var n: f32 = 0;
            var clipped = false;
            for (y - radius..y + radius + 1) |by| {
                for (x - radius..x + radius + 1) |bx| {
                    const d = p.density.pixels[by * p.density.width + bx];
                    const t = referenceAt(p, a, @floatFromInt(bx), @floatFromInt(by)) orelse {
                        clipped = true;
                        continue;
                    };
                    for (d, t) |dv, tv| {
                        if (!(dv > 0.001 and dv < 0.999) or tv <= 0.004 or tv >= 0.996) clipped = true;
                    }
                    for (&density, d) |*s, v| s.* += v;
                    for (&target, t) |*s, v| s.* += v;
                    const g = p.ours_gray.pixels[by * p.ours_gray.width + bx];
                    var tl: [3]f32 = undefined;
                    for (&tl, t) |*l, e| l.* = colour.decode(e);
                    const tg = std.math.log10(@max(colour.luminance(tl), darkest));
                    ours_sum += g;
                    ours_square += g * g;
                    theirs_sum += tg;
                    theirs_square += tg * tg;
                    n += 1;
                }
            }
            if (clipped or n == 0) continue;
            for (&density) |*v| v.* /= n;
            for (&target) |*v| v.* /= n;
            const ours_variance = @max(0, ours_square / n - (ours_sum / n) * (ours_sum / n));
            const theirs_variance = @max(0, theirs_square / n - (theirs_sum / n) * (theirs_sum / n));
            const busy = ours_variance + theirs_variance;
            try out.append(gpa, .{ .density = density, .target = target, .weight = 1 / (1 + 200 * busy), .pair = pair });
        }
    }
}

/// The two images over the part both show, side by side at one size, for the page, and what the
/// difference map needs.
pub const View = struct {
    width: usize,
    height: usize,
    /// Our Neutral rendering there.
    neutral: [][4]u8,
    /// The reference turned, scaled and moved onto ours.
    reference: [][4]u8,
    density: [][3]f32,
    target: [][3]f32,

    pub fn deinit(v: *View, gpa: std.mem.Allocator) void {
        gpa.free(v.neutral);
        gpa.free(v.reference);
        gpa.free(v.density);
        gpa.free(v.target);
        v.* = undefined;
    }

    /// The ΔE2000 between the look and the reference at every pixel, into `out`: each image
    /// averaged over a few pixels around first, as the fit's samples are, so that the map shows
    /// the colour that differs rather than the grain and the edges a pixel's misalignment shows.
    pub fn difference(v: *const View, gpa: std.mem.Allocator, m: *const model.Model, balance: [3]f32, out: []f32) !void {
        const density = try blurred(gpa, v.density, v.width, v.height);
        defer gpa.free(density);
        const target = try blurred(gpa, v.target, v.width, v.height);
        defer gpa.free(target);
        for (out, density, target) |*e, d, t| {
            e.* = colour.deltaE2000(colour.lab(m.encoded(d, balance)), colour.lab(t));
        }
    }
};

/// `pixels` averaged over the square of 5 × 5 around each, kept inside the image.
fn blurred(gpa: std.mem.Allocator, pixels: []const [3]f32, width: usize, height: usize) ![][3]f32 {
    const radius = 2;
    const across = try gpa.alloc([3]f32, pixels.len);
    defer gpa.free(across);
    const out = try gpa.alloc([3]f32, pixels.len);
    for (0..height) |y| {
        for (0..width) |x| {
            var sum: [3]f32 = @splat(0);
            const x0 = x -| radius;
            const x1 = @min(width, x + radius + 1);
            for (pixels[y * width + x0 .. y * width + x1]) |p| {
                for (&sum, p) |*s, v| s.* += v;
            }
            for (&across[y * width + x], sum) |*o, s| o.* = s / @as(f32, @floatFromInt(x1 - x0));
        }
    }
    for (0..height) |y| {
        const y0 = y -| radius;
        const y1 = @min(height, y + radius + 1);
        for (0..width) |x| {
            var sum: [3]f32 = @splat(0);
            for (y0..y1) |row| {
                for (&sum, across[row * width + x]) |*s, v| s.* += v;
            }
            for (&out[y * width + x], sum) |*o, s| o.* = s / @as(f32, @floatFromInt(y1 - y0));
        }
    }
    return out;
}

/// The view of a pair at most `longest` pixels across: over the overlap when `on_scan`, the
/// alignment on our raw scan, is known, or over the whole of each image when it isn't.
pub fn view(gpa: std.mem.Allocator, p: *const Prepared, on_scan: ?register.Alignment, longest: usize) !View {
    const alignment = if (on_scan) |a| p.onFrame(a) else null;
    const box: [4]usize = if (alignment) |a| overlap(p, a) else .{ 0, 0, p.density.width, p.density.height };
    const bw = @max(1, box[2] -| box[0]);
    const bh = @max(1, box[3] -| box[1]);
    const step = @max(1.0, @as(f32, @floatFromInt(@max(bw, bh))) / @as(f32, @floatFromInt(longest)));
    const width: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(bw)) / step)));
    const height: usize = @max(1, @as(usize, @intFromFloat(@as(f32, @floatFromInt(bh)) / step)));
    var v: View = .{
        .width = width,
        .height = height,
        .neutral = try gpa.alloc([4]u8, width * height),
        .reference = undefined,
        .density = undefined,
        .target = undefined,
    };
    errdefer gpa.free(v.neutral);
    v.reference = try gpa.alloc([4]u8, width * height);
    errdefer gpa.free(v.reference);
    v.density = try gpa.alloc([3]f32, width * height);
    errdefer gpa.free(v.density);
    v.target = try gpa.alloc([3]f32, width * height);

    for (0..height) |j| {
        for (0..width) |i| {
            const k = j * width + i;
            // A point of ours, in working pixels, then full-size.
            const x = @as(f32, @floatFromInt(box[0])) + (@as(f32, @floatFromInt(i)) + 0.5) * step;
            const y = @as(f32, @floatFromInt(box[1])) + (@as(f32, @floatFromInt(j)) + 0.5) * step;
            const fx = x * p.density.factor;
            const fy = y * p.density.factor;
            v.neutral[k] = p.neutral.sample(fx, fy) orelse .{ 0, 0, 0, 0 };
            v.density[k] = p.density.sample(fx, fy) orelse @splat(0);
            const t: ?[3]f32 = if (alignment) |a| blk: {
                const at = a.toReference(fx, fy, p.density.full[0], p.reference.full);
                break :blk p.reference.sample(at[0], at[1]);
            } else p.reference.sample(
                (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(width)) * p.reference.full[0],
                (@as(f32, @floatFromInt(j)) + 0.5) / @as(f32, @floatFromInt(height)) * p.reference.full[1],
            );
            v.target[k] = t orelse @splat(0);
            if (t) |c| {
                for (v.reference[k][0..3], c) |*o, e| o.* = @intFromFloat(@round(std.math.clamp(e, 0, 1) * 255));
                v.reference[k][3] = 255;
            } else v.reference[k] = .{ 0, 0, 0, 0 };
        }
    }
    return v;
}

/// The grey of the raw scan at `path`, small, for finding which frame a reference shows.
pub fn thumbnailGray(gpa: std.mem.Allocator, io: std.Io, path: []const u8, placement: draft.Placement) !register.Gray {
    const developed = try developScan(gpa, io, path, 256, placement);
    gpa.free(developed.density.pixels);
    gpa.free(developed.neutral.pixels);
    return developed.gray;
}

/// The grey of the reference at `path`, for the same.
pub fn referenceGray(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !register.Gray {
    const reference = try readReference(gpa, io, path);
    defer gpa.free(reference.pixels);
    return grayOfEncoded(gpa, reference);
}

test "a reference made from our own scan lines up and samples match" {
    const gpa = std.testing.allocator;
    // A made-up scan: a gradient of densities, with a dark square off centre so that turns are
    // told apart.
    var scan: image.Scan = try .init(gpa, 300, 200);
    defer scan.deinit(gpa);
    for (0..scan.height) |y| {
        for (0..scan.width) |x| {
            const fx = @as(f32, @floatFromInt(x)) / 300;
            const fy = @as(f32, @floatFromInt(y)) / 200;
            var t = 0.05 + 0.6 * fx * (0.5 + 0.5 * fy);
            if (x > 200 and x < 260 and y > 30 and y < 90) t *= 0.3;
            if (@abs(@as(f32, @floatFromInt(x)) - 80) < 20 and @abs(@as(f32, @floatFromInt(y)) - 140) < 30) t = 0.5;
            scan.pixels[y * scan.width + x] = .{ @intFromFloat(t * 60000), @intFromFloat(t * 40000), @intFromFloat(t * 25000) };
        }
    }
    const bytes = try negscan.pnm.write(gpa, u16, scan);
    defer gpa.free(bytes);
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "ours.ppm", .data = bytes });
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    const ours_path = try std.fs.path.join(gpa, &.{ dir, "ours.ppm" });
    defer gpa.free(ours_path);

    // The reference: our Neutral rendering of the frame, as a PPM.
    var developed = try developScan(gpa, io, ours_path, working_longest, null);
    defer developed.deinit(gpa);
    var encoded: image.Encoded8 = try .init(gpa, developed.neutral.width, developed.neutral.height);
    defer encoded.deinit(gpa);
    for (encoded.pixels, developed.neutral.pixels) |*e, n| e.* = n[0..3].*;
    const reference_bytes = try negscan.pnm.write(gpa, u8, encoded);
    defer gpa.free(reference_bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "theirs.ppm", .data = reference_bytes });
    const theirs_path = try std.fs.path.join(gpa, &.{ dir, "theirs.ppm" });
    defer gpa.free(theirs_path);

    var prepared = try prepare(gpa, io, ours_path, null, theirs_path);
    defer prepared.deinit(gpa);
    const alignment = try prepared.locate(gpa);
    // It lies on the frame, wherever frame detection put it on the scan.
    const frame = developed.frame;
    try std.testing.expectEqual(register.Orientation.upright, alignment.orientation);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(frame.width)) / 300, alignment.scale, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(frame.x)) / 300, alignment.offset[0], 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(frame.y)) / 300, alignment.offset[1], 0.01);
    try std.testing.expect(alignment.quality > 0.95);

    var samples: std.ArrayList(fit.Sample) = .empty;
    defer samples.deinit(gpa);
    try sample(gpa, &prepared, alignment, 0, &samples);
    try std.testing.expect(samples.items.len > 100);

    var v = try view(gpa, &prepared, alignment, 128);
    defer v.deinit(gpa);
    try std.testing.expect(v.width <= 128 and v.height <= 128);
}
