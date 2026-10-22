//! Lining a reference up with our scan of the same negative: which way round it is, how big,
//! and where.
//!
//! The reference may be turned by quarter turns or mirrored, scaled, and cropped differently from
//! ours: a lab crops to the picture, where our raw scan has the rebate around it. Both are
//! compared as grey images that brighten together, such as the log of their luminance, by
//! normalised cross-correlation, which doesn't mind a different contrast or brightness.
//!
//! 1. Coarse: ours about 48 pixels across. Every orientation and a range of sizes, the
//!    reference resampled onto our grid and slid over it a pixel at a time.
//! 2. Fine: the best few, refined at 96, 192 and 384 pixels across by a pattern search on the
//!    position and the size.
//!
//! The quality is the correlation at the finest level: 1 when the two match exactly, above
//! about 0.8 when they line up, and low when they don't.

const std = @import("std");

/// A grey image, with its place in the full-size image it was reduced from.
pub const Gray = struct {
    width: usize,
    height: usize,
    pixels: []f32,
    /// Full-size pixels per pixel of this image.
    factor: f32 = 1,
    /// The full-size image's width and height, in its pixels.
    full_width: f32,
    full_height: f32,

    pub fn init(gpa: std.mem.Allocator, width: usize, height: usize) !Gray {
        return .{
            .width = width,
            .height = height,
            .pixels = try gpa.alloc(f32, width * height),
            .full_width = @floatFromInt(width),
            .full_height = @floatFromInt(height),
        };
    }

    pub fn deinit(gray: *Gray, gpa: std.mem.Allocator) void {
        gpa.free(gray.pixels);
        gray.* = undefined;
    }

    /// Reduced by a whole factor, each pixel the mean of its block, so that the longer side is
    /// at most `longest`. A copy when it is already that small.
    pub fn reduce(gray: Gray, gpa: std.mem.Allocator, longest: usize) !Gray {
        const side = @max(gray.width, gray.height);
        const factor = @max(1, (side + longest - 1) / longest);
        var out: Gray = .{
            .width = @max(1, gray.width / factor),
            .height = @max(1, gray.height / factor),
            .pixels = undefined,
            .factor = gray.factor * @as(f32, @floatFromInt(factor)),
            .full_width = gray.full_width,
            .full_height = gray.full_height,
        };
        out.pixels = try gpa.alloc(f32, out.width * out.height);
        const block: f32 = @floatFromInt(factor * factor);
        for (0..out.height) |y| {
            for (0..out.width) |x| {
                var sum: f32 = 0;
                for (0..factor) |dy| {
                    const row = gray.pixels[@min(y * factor + dy, gray.height - 1) * gray.width ..];
                    for (0..factor) |dx| sum += row[@min(x * factor + dx, gray.width - 1)];
                }
                out.pixels[y * out.width + x] = sum / block;
            }
        }
        return out;
    }

    /// Bilinear between pixel centres, at (x, y) in this image's pixels; null outside it.
    fn sample(gray: *const Gray, x: f32, y: f32) ?f32 {
        const fx = x - 0.5;
        const fy = y - 0.5;
        if (fx < 0 or fy < 0) return null;
        const x0: usize = @intFromFloat(fx);
        const y0: usize = @intFromFloat(fy);
        if (x0 + 1 >= gray.width or y0 + 1 >= gray.height) return null;
        const tx = fx - @as(f32, @floatFromInt(x0));
        const ty = fy - @as(f32, @floatFromInt(y0));
        const row = gray.pixels[y0 * gray.width ..];
        const next = gray.pixels[(y0 + 1) * gray.width ..];
        const top = row[x0] + (row[x0 + 1] - row[x0]) * tx;
        const bottom = next[x0] + (next[x0 + 1] - next[x0]) * tx;
        return top + (bottom - top) * ty;
    }
};

/// How the reference is turned to match ours: mirrored left to right first, if at all, then
/// turned clockwise by quarter turns.
pub const Orientation = enum(u3) {
    upright,
    quarter,
    half,
    three_quarters,
    mirrored,
    mirrored_quarter,
    mirrored_half,
    mirrored_three_quarters,

    pub fn turns(o: Orientation) u2 {
        return @truncate(@backingInt(o));
    }

    pub fn isMirrored(o: Orientation) bool {
        return @backingInt(o) >= 4;
    }

    /// Whether width and height swap.
    pub fn sideways(o: Orientation) bool {
        return o.turns() & 1 == 1;
    }

    pub fn label(o: Orientation) []const u8 {
        return switch (o) {
            .upright => "",
            .quarter => "turned 90°",
            .half => "turned 180°",
            .three_quarters => "turned 270°",
            .mirrored => "mirrored",
            .mirrored_quarter => "mirrored, turned 90°",
            .mirrored_half => "mirrored, turned 180°",
            .mirrored_three_quarters => "mirrored, turned 270°",
        };
    }

    /// A point (p, q) of the turned image back in the reference as it is, `width` × `height`.
    pub fn toOriginal(o: Orientation, p: f32, q: f32, width: f32, height: f32) [2]f32 {
        // Turning clockwise takes (u, v) to (height − v, u); undo the turns, then the mirror.
        const unturned: [2]f32 = switch (o.turns()) {
            0 => .{ p, q },
            1 => .{ q, height - p },
            2 => .{ width - p, height - q },
            3 => .{ width - q, p },
        };
        return if (o.isMirrored()) .{ width - unturned[0], unturned[1] } else unturned;
    }
};

/// Where the reference lies on ours. Positions are in units of our full width: x and y both
/// divided by it. The reference, turned, spans `scale` of that unit across, from `offset`.
pub const Alignment = struct {
    orientation: Orientation = .upright,
    scale: f32 = 1,
    offset: [2]f32 = .{ 0, 0 },
    /// The correlation where they overlap, −1..1.
    quality: f32 = 0,

    /// The point of the reference, in its own full-size pixels, at (x, y) of ours in its
    /// full-size pixels. `reference` is the reference's full width and height, as it is.
    pub fn toReference(a: Alignment, x: f32, y: f32, ours_width: f32, reference: [2]f32) [2]f32 {
        const turned_width = if (a.orientation.sideways()) reference[1] else reference[0];
        const p = (x / ours_width - a.offset[0]) / a.scale * turned_width;
        const q = (y / ours_width - a.offset[1]) / a.scale * turned_width;
        return a.orientation.toOriginal(p, q, reference[0], reference[1]);
    }

    /// The part of ours the reference covers, in our full-size pixels: x0, y0, x1, y1.
    pub fn extent(a: Alignment, ours_width: f32, reference: [2]f32) [4]f32 {
        const turned = if (a.orientation.sideways()) [2]f32{ reference[1], reference[0] } else reference;
        const width = a.scale * ours_width;
        const height = width * turned[1] / turned[0];
        const x = a.offset[0] * ours_width;
        const y = a.offset[1] * ours_width;
        return .{ x, y, x + width, y + height };
    }
};

/// The coarse level's longer side, the finer levels', and how small a reference may be against
/// ours, across, at most and at least.
const coarse_side = 48;
const fine_sides = [_]usize{ 96, 192, 384 };
const smallest_scale = 0.4;
const largest_scale = 1.15;
const scale_step = 1.05;
/// How much of the reference must lie on ours, and how much of ours it must cover.
const least_inside = 0.6;
const least_cover = 0.2;
/// Candidates from the coarse search refined at the first fine level.
pub const candidates = 4;

/// Lines `reference` up with `ours`. Both are grey images that brighten together.
pub fn register(gpa: std.mem.Allocator, ours: Gray, reference: Gray) !Alignment {
    var pyramid: Pyramid = try .init(gpa, reference);
    defer pyramid.deinit(gpa);
    const best = try coarse(gpa, ours, &pyramid);

    var result: Alignment = .{ .quality = -2 };
    for (fine_sides, 0..) |side, level| {
        var fine = try ours.reduce(gpa, side);
        defer fine.deinit(gpa);
        const source = pick(pyramid.levels(), @floatFromInt(side));
        if (level == 0) {
            for (best) |candidate| {
                if (candidate.quality < -1) continue;
                const refined = refine(fine, source, candidate);
                if (refined.quality > result.quality) result = refined;
            }
        } else {
            result = refine(fine, source, result);
        }
    }
    return result;
}

/// The reference reduced to several sizes, to resample from the one nearest in size.
pub const Pyramid = struct {
    reduced: [sides.len]Gray,
    count: usize,

    /// The longer side of each size, largest first.
    const sides = [_]usize{ 1024, 512, 256, 128, 64, 32 };

    pub fn init(gpa: std.mem.Allocator, reference: Gray) !Pyramid {
        var p: Pyramid = .{ .reduced = undefined, .count = 0 };
        errdefer p.deinit(gpa);
        for (sides) |side| {
            p.reduced[p.count] = try reference.reduce(gpa, side);
            p.count += 1;
        }
        return p;
    }

    pub fn deinit(p: *Pyramid, gpa: std.mem.Allocator) void {
        for (p.reduced[0..p.count]) |*g| g.deinit(gpa);
    }

    fn levels(p: *const Pyramid) []const Gray {
        return p.reduced[0..p.count];
    }
};

/// The coarse search alone: the best few placements, best first. Quick enough to try a
/// reference against every frame of a roll, to find the one it shows.
pub fn coarse(gpa: std.mem.Allocator, ours: Gray, pyramid: *const Pyramid) ![candidates]Alignment {
    var small = try ours.reduce(gpa, coarse_side);
    defer small.deinit(gpa);
    var best: [candidates]Alignment = @splat(.{ .quality = -2 });
    for (std.enums.values(Orientation)) |o| {
        var scale: f32 = smallest_scale;
        while (scale <= largest_scale) : (scale *= scale_step) {
            try coarseSearch(gpa, small, pyramid.levels(), o, scale, &best);
        }
    }
    std.mem.sort(Alignment, &best, {}, better);
    return best;
}

fn better(_: void, a: Alignment, b: Alignment) bool {
    return a.quality > b.quality;
}

/// The reduced reference whose pixels are nearest in size to those of ours `side` across, or a
/// little finer.
fn pick(pyramid: []const Gray, side: f32) *const Gray {
    var chosen = &pyramid[0];
    for (pyramid) |*g| {
        if (@as(f32, @floatFromInt(@max(g.width, g.height))) >= side) chosen = g;
    }
    return chosen;
}

/// Every position of the reference, turned by `o` and `scale` across, on the coarse grid of
/// ours, kept among the `best` if it beats them.
fn coarseSearch(gpa: std.mem.Allocator, ours: Gray, pyramid: []const Gray, o: Orientation, scale: f32, best: *[candidates]Alignment) !void {
    // Our coarse grid's width in its pixels, as a real number, and the reference's turned size
    // on it.
    const grid = ours.full_width / ours.factor;
    const turned_width = if (o.sideways()) pyramid[0].full_height else pyramid[0].full_width;
    const turned_height = if (o.sideways()) pyramid[0].full_width else pyramid[0].full_height;
    const w: usize = @intFromFloat(@round(scale * grid));
    const h: usize = @intFromFloat(@round(scale * grid * turned_height / turned_width));
    if (w < 4 or h < 4) return;
    if (@as(f32, @floatFromInt(h)) > largest_scale * @as(f32, @floatFromInt(ours.height)) + 1) return;

    // The reference, resampled onto our grid.
    var resampled = try gpa.alloc(f32, w * h);
    defer gpa.free(resampled);
    const source = pick(pyramid, @floatFromInt(@max(w, h)));
    const source_width = source.full_width / source.factor;
    const source_height = source.full_height / source.factor;
    const turned_source = if (o.sideways()) source_height else source_width;
    for (0..h) |j| {
        for (0..w) |i| {
            const p = (@as(f32, @floatFromInt(i)) + 0.5) / @as(f32, @floatFromInt(w)) * turned_source;
            const q = (@as(f32, @floatFromInt(j)) + 0.5) / @as(f32, @floatFromInt(w)) * turned_source;
            const at = o.toOriginal(p, q, source_width, source_height);
            resampled[j * w + i] = source.sample(at[0], at[1]) orelse nearest(source, at);
        }
    }
    var ours_sums = try Sums.init(gpa, ours.pixels, ours.width, ours.height);
    defer ours_sums.deinit(gpa);
    var ref_sums = try Sums.init(gpa, resampled, w, h);
    defer ref_sums.deinit(gpa);

    const ow: isize = @intCast(ours.width);
    const oh: isize = @intCast(ours.height);
    const iw: isize = @intCast(w);
    const ih: isize = @intCast(h);
    const area_ref: f32 = @floatFromInt(w * h);
    const area_ours: f32 = @floatFromInt(ours.width * ours.height);
    var ty: isize = -@divTrunc(ih, 2);
    while (ty < oh - @divTrunc(ih, 2)) : (ty += 1) {
        var tx: isize = -@divTrunc(iw, 2);
        while (tx < ow - @divTrunc(iw, 2)) : (tx += 1) {
            // The overlap, in ours.
            const x0 = @max(0, tx);
            const y0 = @max(0, ty);
            const x1 = @min(ow, tx + iw);
            const y1 = @min(oh, ty + ih);
            if (x1 <= x0 or y1 <= y0) continue;
            const n: f32 = @floatFromInt((x1 - x0) * (y1 - y0));
            if (n < least_inside * area_ref or n < least_cover * area_ours) continue;
            const ux0: usize = @intCast(x0);
            const uy0: usize = @intCast(y0);
            const ux1: usize = @intCast(x1);
            const uy1: usize = @intCast(y1);
            const rx0: usize = @intCast(x0 - tx);
            const ry0: usize = @intCast(y0 - ty);
            const a = ours_sums.over(ux0, uy0, ux1, uy1);
            const b = ref_sums.over(rx0, ry0, rx0 + (ux1 - ux0), ry0 + (uy1 - uy0));
            var cross: f64 = 0;
            for (uy0..uy1, ry0..) |y, ry| {
                const row_a = ours.pixels[y * ours.width + ux0 ..][0 .. ux1 - ux0];
                const row_b = resampled[ry * w + rx0 ..][0 .. ux1 - ux0];
                var line: f32 = 0;
                for (row_a, row_b) |va, vb| line += va * vb;
                cross += line;
            }
            const quality = correlation(n, a, b, cross);
            keep(best, .{
                .orientation = o,
                .scale = @as(f32, @floatFromInt(w)) / grid,
                .offset = .{ @as(f32, @floatFromInt(tx)) / grid, @as(f32, @floatFromInt(ty)) / grid },
                .quality = quality,
            });
        }
    }
}

fn nearest(gray: *const Gray, at: [2]f32) f32 {
    const x: usize = @intFromFloat(std.math.clamp(at[0], 0, @as(f32, @floatFromInt(gray.width - 1))));
    const y: usize = @intFromFloat(std.math.clamp(at[1], 0, @as(f32, @floatFromInt(gray.height - 1))));
    return gray.pixels[y * gray.width + x];
}

/// Keeps `candidate` among the best, which hold different orientations and sizes rather than
/// one match a pixel apart.
fn keep(best: *[candidates]Alignment, candidate: Alignment) void {
    for (best) |*b| {
        if (b.orientation == candidate.orientation and @abs(@log(b.scale / candidate.scale)) < 0.08) {
            if (candidate.quality > b.quality) b.* = candidate;
            return;
        }
    }
    var worst: usize = 0;
    for (best, 0..) |b, i| {
        if (b.quality < best[worst].quality) worst = i;
    }
    if (candidate.quality > best[worst].quality) best[worst] = candidate;
}

/// Sums of a value and its square over rectangles, from tables of running sums.
const Sums = struct {
    width: usize,
    value: []f64,
    square: []f64,

    fn init(gpa: std.mem.Allocator, pixels: []const f32, width: usize, height: usize) !Sums {
        const stride = width + 1;
        const value = try gpa.alloc(f64, stride * (height + 1));
        errdefer gpa.free(value);
        const square = try gpa.alloc(f64, stride * (height + 1));
        @memset(value[0..stride], 0);
        @memset(square[0..stride], 0);
        for (0..height) |y| {
            value[(y + 1) * stride] = 0;
            square[(y + 1) * stride] = 0;
            var row: f64 = 0;
            var row_square: f64 = 0;
            for (0..width) |x| {
                const v: f64 = pixels[y * width + x];
                row += v;
                row_square += v * v;
                value[(y + 1) * stride + x + 1] = value[y * stride + x + 1] + row;
                square[(y + 1) * stride + x + 1] = square[y * stride + x + 1] + row_square;
            }
        }
        return .{ .width = width, .value = value, .square = square };
    }

    fn deinit(sums: *Sums, gpa: std.mem.Allocator) void {
        gpa.free(sums.value);
        gpa.free(sums.square);
    }

    fn over(sums: *const Sums, x0: usize, y0: usize, x1: usize, y1: usize) [2]f64 {
        const s = sums.width + 1;
        return .{
            sums.value[y1 * s + x1] - sums.value[y0 * s + x1] - sums.value[y1 * s + x0] + sums.value[y0 * s + x0],
            sums.square[y1 * s + x1] - sums.square[y0 * s + x1] - sums.square[y1 * s + x0] + sums.square[y0 * s + x0],
        };
    }
};

/// Normalised cross-correlation from `n` pairs' sums of a, a², b, b² and ab.
fn correlation(n: f32, a: [2]f64, b: [2]f64, cross: f64) f32 {
    const count: f64 = n;
    const covariance = count * cross - a[0] * b[0];
    const variance_a = count * a[1] - a[0] * a[0];
    const variance_b = count * b[1] - b[0] * b[0];
    if (variance_a <= 1e-12 or variance_b <= 1e-12) return -1;
    return @floatCast(covariance / @sqrt(variance_a * variance_b));
}

/// The correlation of ours and the reference placed by `a`, over every pixel of ours it covers.
fn score(ours: *const Gray, reference: *const Gray, a: Alignment) f32 {
    const ours_width = ours.full_width;
    const full: [2]f32 = .{ reference.full_width, reference.full_height };
    var sums: [5]f64 = @splat(0);
    var n: f32 = 0;
    const box = a.extent(ours_width, full);
    const area = (box[2] - box[0]) * (box[3] - box[1]) / (ours.factor * ours.factor);
    const y_start: usize = @intFromFloat(std.math.clamp(@floor(box[1] / ours.factor), 0, @as(f32, @floatFromInt(ours.height))));
    const y_end: usize = @intFromFloat(std.math.clamp(@ceil(box[3] / ours.factor), 0, @as(f32, @floatFromInt(ours.height))));
    const x_start: usize = @intFromFloat(std.math.clamp(@floor(box[0] / ours.factor), 0, @as(f32, @floatFromInt(ours.width))));
    const x_end: usize = @intFromFloat(std.math.clamp(@ceil(box[2] / ours.factor), 0, @as(f32, @floatFromInt(ours.width))));
    for (y_start..y_end) |y| {
        for (x_start..x_end) |x| {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5) * ours.factor;
            const fy = (@as(f32, @floatFromInt(y)) + 0.5) * ours.factor;
            const at = a.toReference(fx, fy, ours_width, full);
            const vb = reference.sample(at[0] / reference.factor, at[1] / reference.factor) orelse continue;
            const va: f64 = ours.pixels[y * ours.width + x];
            sums[0] += va;
            sums[1] += va * va;
            sums[2] += vb;
            sums[3] += vb * vb;
            sums[4] += va * vb;
            n += 1;
        }
    }
    const covered: f32 = @floatFromInt(ours.width * ours.height);
    if (n < 16 or n < least_inside * area * 0.9 or n < least_cover * covered * 0.9) return -1;
    return correlation(n, .{ sums[0], sums[1] }, .{ sums[2], sums[3] }, sums[4]);
}

/// A pattern search on the position and the size from `start`: each in turn nudged either way
/// while that helps, the nudges halving down to a quarter of a pixel.
fn refine(ours: Gray, reference: *const Gray, start: Alignment) Alignment {
    var current = start;
    current.quality = score(&ours, reference, current);
    const pixel = ours.factor / ours.full_width;
    var step: f32 = 1;
    while (step >= 0.25) {
        var moved = true;
        var tries: usize = 0;
        while (moved and tries < 50) : (tries += 1) {
            moved = false;
            for (0..3) |which| {
                for ([_]f32{ -1, 1 }) |direction| {
                    var next = current;
                    switch (which) {
                        0 => next.offset[0] += direction * step * pixel,
                        1 => next.offset[1] += direction * step * pixel,
                        else => {
                            // Grow or shrink about the middle, by a step at the far edge.
                            const factor = 1 + direction * step * pixel / current.scale;
                            const box = current.extent(1, .{ reference.full_width, reference.full_height });
                            const middle = [2]f32{ (box[0] + box[2]) / 2, (box[1] + box[3]) / 2 };
                            next.scale = current.scale * factor;
                            next.offset[0] = middle[0] - (middle[0] - current.offset[0]) * factor;
                            next.offset[1] = middle[1] - (middle[1] - current.offset[1]) * factor;
                        },
                    }
                    next.quality = score(&ours, reference, next);
                    if (next.quality > current.quality + 1e-6) {
                        current = next;
                        moved = true;
                    }
                }
            }
        }
        step /= 2;
    }
    return current;
}

/// A test scene: soft blobs of different sizes and brightness, no two alike, so that no turn of
/// it looks like another.
fn scene(x: f32, y: f32) f32 {
    const blobs = [_][4]f32{
        .{ 0.2, 0.25, 0.08, 1.0 },
        .{ 0.7, 0.3, 0.12, -0.7 },
        .{ 0.45, 0.5, 0.05, 0.8 },
        .{ 0.85, 0.55, 0.06, 0.6 },
        .{ 0.3, 0.6, 0.1, -0.5 },
        .{ 0.6, 0.12, 0.04, 0.9 },
        .{ 0.1, 0.5, 0.05, 0.4 },
    };
    var v: f32 = 0.3 * x + 0.1 * y;
    for (blobs) |b| {
        const dx = x - b[0];
        const dy = y - b[1];
        v += b[3] * @exp(-(dx * dx + dy * dy) / (2 * b[2] * b[2]));
    }
    return v;
}

test "a turned, scaled and cropped reference lines up" {
    const gpa = std.testing.allocator;
    // Ours: the scene 600 × 400, in units of its width.
    var ours = try Gray.init(gpa, 600, 400);
    defer ours.deinit(gpa);
    for (0..ours.height) |y| {
        for (0..ours.width) |x| {
            ours.pixels[y * ours.width + x] = scene((@as(f32, @floatFromInt(x)) + 0.5) / 600, (@as(f32, @floatFromInt(y)) + 0.5) / 600);
        }
    }
    // The reference: a crop of 70% of the width, turned a quarter, 300 pixels across as turned,
    // with another contrast.
    const truth: Alignment = .{ .orientation = .quarter, .scale = 0.7, .offset = .{ 0.12, 0.05 } };
    const turned_width = 300;
    const turned_height = 300 * 0.55;
    // Turned a quarter, the file is taller than wide.
    var reference = try Gray.init(gpa, @intFromFloat(turned_height), turned_width);
    defer reference.deinit(gpa);
    for (0..reference.height) |v| {
        for (0..reference.width) |u| {
            // Where this pixel of the file lands once turned, then on ours.
            const fu = @as(f32, @floatFromInt(u)) + 0.5;
            const fv = @as(f32, @floatFromInt(v)) + 0.5;
            const p = @as(f32, @floatFromInt(reference.height)) - fv;
            const q = fu;
            const x = truth.offset[0] + p / turned_width * truth.scale;
            const y = truth.offset[1] + q / turned_width * truth.scale;
            reference.pixels[v * reference.width + u] = 0.5 * scene(x, y) + 0.2;
        }
    }
    const found = try register(gpa, ours, reference);
    try std.testing.expectEqual(Orientation.quarter, found.orientation);
    try std.testing.expectApproxEqAbs(truth.scale, found.scale, 0.005);
    try std.testing.expectApproxEqAbs(truth.offset[0], found.offset[0], 0.003);
    try std.testing.expectApproxEqAbs(truth.offset[1], found.offset[1], 0.003);
    try std.testing.expect(found.quality > 0.99);

    // And a point of ours maps to the right point of the file.
    const at = found.toReference(300, 150, 600, .{ reference.full_width, reference.full_height });
    const p = (300.0 / 600.0 - truth.offset[0]) / truth.scale * turned_width;
    const q = (150.0 / 600.0 - truth.offset[1]) / truth.scale * turned_width;
    try std.testing.expectApproxEqAbs(q, at[0], 1.5);
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(reference.height)) - p, at[1], 1.5);
}

test "orientations undo each other" {
    for (std.enums.values(Orientation)) |o| {
        // A point of a 40 × 30 file, turned: then back.
        const width: f32 = 40;
        const height: f32 = 30;
        const turned_width = if (o.sideways()) height else width;
        const turned_height = if (o.sideways()) width else height;
        const corners = [_][2]f32{ .{ 0, 0 }, .{ turned_width, 0 }, .{ 0, turned_height }, .{ turned_width, turned_height } };
        for (corners) |corner| {
            const back = o.toOriginal(corner[0], corner[1], width, height);
            try std.testing.expect(back[0] == 0 or back[0] == width);
            try std.testing.expect(back[1] == 0 or back[1] == height);
        }
    }
}
