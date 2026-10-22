//! The flat field of a camera roll (design sections 5 and 7, "Linearise"). It's a shot of the
//! light source with no film in front of it, at the same exposure as the frames. Light sources are
//! rarely even, and lenses get darker towards the corners, so the shot is brighter in the middle
//! than at the edges, and so is every frame. Once we smooth the shot and divide it by its
//! brightest value per channel, it gives a gain between 0 and 1 at each point. Dividing a frame by
//! that evens out the light, so the film base reads the same all across the frame.
//!
//! Smoothing: we average the shot over a coarse grid of cells, `grid_longest` along its longer
//! side, and blur the grid over each cell's neighbours. Past the grid's edges we extend it along
//! its own slope, so the blur doesn't pull the edges towards the middle. Gains between cell
//! centres are interpolated linearly, and extrapolated the same way in the half cell at each edge.
//! Noise and dust on the light source disappear, and the fall-off, which changes slowly, stays.

const std = @import("std");
const image = @import("image.zig");

/// How many cells go along the shot's longer side.
pub const grid_longest = 64;
/// How far the blur reaches, in cells on either side.
const blur_cells = 1;
/// The smallest gain a frame is divided by. A corner darker than this is mostly the lens hood or
/// the holder, and dividing by less would only bring up noise.
const least_gain = 0.05;

pub const Error = error{
    /// The frame and the flat field are different sizes: from another camera, or turned.
    FlatFieldSize,
    /// Some channel of the shot is black everywhere: no light reached the sensor.
    DarkFlatField,
};

pub const FlatField = struct {
    /// The shot's size. A frame has to be the same size.
    width: usize,
    height: usize,
    /// The gain per channel at each cell's centre, with 1 at the brightest.
    gains: image.Image([image.channel_count]f32),

    /// Makes the flat field from `shot`, a photo of the light source with no film.
    pub fn init(gpa: std.mem.Allocator, shot: image.Scan) (Error || std.mem.Allocator.Error)!FlatField {
        if (shot.width == 0 or shot.height == 0) return error.DarkFlatField;
        const longest = @max(shot.width, shot.height);
        const columns = cellsAlong(shot.width, longest);
        const rows = cellsAlong(shot.height, longest);
        var gains: image.Image([image.channel_count]f32) = try .init(gpa, columns, rows);
        errdefer gains.deinit(gpa);

        // The mean of each cell.
        for (0..rows) |row| {
            const y0 = row * shot.height / rows;
            const y1 = (row + 1) * shot.height / rows;
            for (0..columns) |column| {
                const x0 = column * shot.width / columns;
                const x1 = (column + 1) * shot.width / columns;
                var sum: [image.channel_count]f64 = @splat(0);
                for (y0..y1) |y| {
                    for (shot.row(y)[x0..x1]) |pixel| {
                        for (&sum, pixel) |*total, value| total.* += @floatFromInt(value);
                    }
                }
                const count: f64 = @floatFromInt((x1 - x0) * (y1 - y0));
                for (&gains.pixels[row * columns + column], sum) |*cell, total| cell.* = @floatCast(total / count);
            }
        }

        try blur(gpa, &gains);

        var brightest: [image.channel_count]f32 = @splat(0);
        for (gains.pixels) |cell| {
            for (&brightest, cell) |*b, v| b.* = @max(b.*, v);
        }
        for (brightest) |b| if (b <= 0) return error.DarkFlatField;
        for (gains.pixels) |*cell| {
            for (cell, brightest) |*v, b| v.* = @max(v.* / b, least_gain);
        }
        return .{ .width = shot.width, .height = shot.height, .gains = gains };
    }

    pub fn deinit(flat: *FlatField, gpa: std.mem.Allocator) void {
        flat.gains.deinit(gpa);
        flat.* = undefined;
    }

    /// Returns the gain per channel at the centre of pixel (`x`, `y`) of a frame.
    pub fn gainAt(flat: *const FlatField, x: usize, y: usize) [image.channel_count]f32 {
        const u: Between = .of(x, flat.width, flat.gains.width);
        const v: Between = .of(y, flat.height, flat.gains.height);
        const top = flat.gains.row(v.low);
        const bottom = flat.gains.row(v.high);
        var gain: [image.channel_count]f32 = undefined;
        for (&gain, 0..) |*g, channel| {
            const upper = lerp(top[u.low][channel], top[u.high][channel], u.t);
            const lower = lerp(bottom[u.low][channel], bottom[u.high][channel], u.t);
            g.* = @max(lerp(upper, lower, v.t), least_gain);
        }
        return gain;
    }

    /// Divides `scan`, a frame shot with the same light and exposure, by the flat field.
    pub fn apply(flat: *const FlatField, scan: image.Scan) Error!void {
        if (scan.width != flat.width or scan.height != flat.height) return error.FlatFieldSize;
        for (0..scan.height) |y| {
            for (scan.row(y), 0..) |*pixel, x| {
                const gain = flat.gainAt(x, y);
                for (pixel, gain) |*sample, g| {
                    sample.* = @intFromFloat(@min(@round(@as(f32, @floatFromInt(sample.*)) / g), image.full_scale));
                }
            }
        }
    }
};

/// Where the centre of a pixel falls between the centres of the two nearest cells along an axis:
/// the two cells, and how far it is from the lower one. That's 0 to 1 between them, and goes past
/// that range in the half cell at either edge.
const Between = struct {
    low: usize,
    high: usize,
    t: f32,

    /// Works it out for pixel `at` of `size`, along an axis of `cells` cells.
    fn of(at: usize, size: usize, cells: usize) Between {
        if (cells == 1) return .{ .low = 0, .high = 0, .t = 0 };
        const cell = @as(f32, @floatFromInt(size)) / @as(f32, @floatFromInt(cells));
        const u = (@as(f32, @floatFromInt(at)) + 0.5) / cell - 0.5;
        const low: usize = @intFromFloat(std.math.clamp(@floor(u), 0, @as(f32, @floatFromInt(cells - 2))));
        return .{ .low = low, .high = low + 1, .t = u - @as(f32, @floatFromInt(low)) };
    }
};

/// How many cells go along a side of `size` pixels when the longer side has `longest`: in
/// proportion, at least 1, and no more than there are pixels.
fn cellsAlong(size: usize, longest: usize) usize {
    const cells = @max(1, (size * grid_longest + longest / 2) / longest);
    return @min(cells, size);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Blurs `grid` over `blur_cells` on either side, one axis at a time. Past its edges, the grid
/// carries on along its own slope.
fn blur(gpa: std.mem.Allocator, grid: *image.Image([image.channel_count]f32)) !void {
    const Cell = [image.channel_count]f32;
    const line = try gpa.alloc(Cell, @max(grid.width, grid.height));
    defer gpa.free(line);
    for (0..grid.height) |y| {
        const cells = grid.row(y);
        @memcpy(line[0..cells.len], cells);
        blurLine(line[0..cells.len], cells, 1);
    }
    for (0..grid.width) |x| {
        for (0..grid.height) |y| line[y] = grid.pixels[y * grid.width + x];
        blurLine(line[0..grid.height], grid.pixels[x..], grid.width);
    }
}

/// Blurs `from` along one line, writing into every `stride`th cell of `to`.
fn blurLine(from: []const [image.channel_count]f32, to: [][image.channel_count]f32, stride: usize) void {
    const n: isize = @intCast(from.len);
    for (from, 0..) |_, i| {
        var sum: [image.channel_count]f32 = @splat(0);
        var k: isize = -blur_cells;
        while (k <= blur_cells) : (k += 1) {
            const cell = extended(from, @as(isize, @intCast(i)) + k, n);
            for (&sum, cell) |*s, v| s.* += v;
        }
        for (&to[i * stride], sum) |*out, s| out.* = s / (2 * blur_cells + 1);
    }
}

/// Returns cell `at` of `line`, which is `n` cells long. `at` can be past either end, and there
/// the line carries on straight through its last two cells.
fn extended(line: []const [image.channel_count]f32, at: isize, n: isize) [image.channel_count]f32 {
    if (at >= 0 and at < n) return line[@intCast(at)];
    if (n == 1) return line[0];
    const edge: usize = if (at < 0) 0 else @intCast(n - 1);
    const inner: usize = if (at < 0) 1 else @intCast(n - 2);
    const steps: f32 = @floatFromInt(if (at < 0) -at else at - (n - 1));
    var cell: [image.channel_count]f32 = undefined;
    for (&cell, line[edge], line[inner]) |*out, e, i| out.* = e + (e - i) * steps;
    return cell;
}

/// A light that falls off from the middle as `1 − fall_off · r²`, with `r` 1 at the corners, and
/// `peak` in each channel.
fn testLight(gpa: std.mem.Allocator, width: usize, height: usize, peak: [image.channel_count]f32, fall_off: f32) !image.Scan {
    const scan: image.Scan = try .init(gpa, width, height);
    const cx = @as(f32, @floatFromInt(width)) / 2;
    const cy = @as(f32, @floatFromInt(height)) / 2;
    const corner = cx * cx + cy * cy;
    for (0..height) |y| {
        for (scan.row(y), 0..) |*pixel, x| {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - cx;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - cy;
            const light = 1 - fall_off * (dx * dx + dy * dy) / corner;
            for (pixel, peak) |*sample, p| sample.* = @intFromFloat(@round(p * light));
        }
    }
    return scan;
}

/// The largest value of `channel` in `scan`, over the smallest.
fn spread(scan: image.Scan, channel: usize) f32 {
    var low: u16 = std.math.maxInt(u16);
    var high: u16 = 0;
    for (scan.pixels) |p| {
        low = @min(low, p[channel]);
        high = @max(high, p[channel]);
    }
    return @as(f32, @floatFromInt(high)) / @as(f32, @floatFromInt(low));
}

test "a frame of even film comes out even once divided by the flat field" {
    const gpa = std.testing.allocator;
    const width = 300;
    const height = 200;
    const fall_off = 0.4;
    const peak = [image.channel_count]f32{ 52000, 61000, 38000 };
    var shot = try testLight(gpa, width, height, peak, fall_off);
    defer shot.deinit(gpa);
    var flat: FlatField = try .init(gpa, shot);
    defer flat.deinit(gpa);

    // Film that passes 30% in each channel, under the same light.
    const film = 0.3;
    var frame = try testLight(gpa, width, height, .{ peak[0] * film, peak[1] * film, peak[2] * film }, fall_off);
    defer frame.deinit(gpa);
    try std.testing.expect(spread(frame, 0) > 1.5);
    try flat.apply(frame);
    // Even to within a per cent, with the middle at the film's share of the brightest light.
    const evenness = 1.01;
    for (0..image.channel_count) |channel| try std.testing.expect(spread(frame, channel) < evenness);
    const middle = frame.at(width / 2, height / 2);
    for (middle, peak) |value, p| try std.testing.expectApproxEqRel(p * film, @as(f32, @floatFromInt(value)), 0.01);
}

test "gains are 1 at the brightest, per channel" {
    const gpa = std.testing.allocator;
    var shot = try testLight(gpa, 96, 64, .{ 40000, 20000, 10000 }, 0.3);
    defer shot.deinit(gpa);
    var flat: FlatField = try .init(gpa, shot);
    defer flat.deinit(gpa);
    var brightest: [image.channel_count]f32 = @splat(0);
    for (flat.gains.pixels) |cell| {
        for (&brightest, cell) |*b, g| b.* = @max(b.*, g);
    }
    try std.testing.expectEqual(@as([image.channel_count]f32, @splat(1)), brightest);
    // The corners get less light than the middle, by about the fall-off.
    const corner = flat.gainAt(0, 0);
    for (corner) |g| try std.testing.expectApproxEqAbs(0.7, g, 0.03);
}

test "a speck of dust on the light leaves no mark" {
    const gpa = std.testing.allocator;
    var shot: image.Scan = try .init(gpa, 256, 192);
    defer shot.deinit(gpa);
    @memset(shot.pixels, @splat(40000));
    shot.pixels[100 * shot.width + 128] = @splat(0);
    var flat: FlatField = try .init(gpa, shot);
    defer flat.deinit(gpa);
    for (flat.gainAt(128, 100)) |g| try std.testing.expect(g > 0.99);
}

test "a frame of another size, or a black shot, is refused" {
    const gpa = std.testing.allocator;
    var shot = try testLight(gpa, 40, 30, @splat(30000), 0.2);
    defer shot.deinit(gpa);
    var flat: FlatField = try .init(gpa, shot);
    defer flat.deinit(gpa);
    var turned: image.Scan = try .init(gpa, 30, 40);
    defer turned.deinit(gpa);
    try std.testing.expectError(error.FlatFieldSize, flat.apply(turned));
    @memset(shot.pixels, .{ 1000, 0, 1000 });
    try std.testing.expectError(error.DarkFlatField, FlatField.init(gpa, shot));
}
