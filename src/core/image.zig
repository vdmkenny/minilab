//! Images in memory: scans as the scanner delivers them (linear, 16-bit), and rendered images.

const std = @import("std");

pub const Channel = enum { r, g, b };
pub const channel_count = @typeInfo(Channel).@"enum".field_names.len;

/// The largest 16-bit sample. In a scan it means full transmission.
pub const full_scale = std.math.maxInt(u16);
/// Multiply an 8-bit sample by this to get the 16-bit sample at the same fraction of full scale:
/// 255 becomes 65535.
pub const widen_8_to_16 = full_scale / std.math.maxInt(u8);

/// An image of `Pixel`s, row by row.
pub fn Image(comptime Pixel: type) type {
    return struct {
        const Self = @This();

        width: usize,
        height: usize,
        pixels: []Pixel,

        pub fn init(gpa: std.mem.Allocator, width: usize, height: usize) !Self {
            return .{ .width = width, .height = height, .pixels = try gpa.alloc(Pixel, width * height) };
        }

        pub fn deinit(image: *Self, gpa: std.mem.Allocator) void {
            gpa.free(image.pixels);
            image.* = undefined;
        }

        pub fn at(image: Self, x: usize, y: usize) Pixel {
            return image.pixels[y * image.width + x];
        }

        pub fn row(image: Self, y: usize) []Pixel {
            return image.pixels[y * image.width ..][0..image.width];
        }

        /// Returns a copy of the image, mirrored left to right.
        pub fn mirror(image: Self, gpa: std.mem.Allocator) !Self {
            var result: Self = try .init(gpa, image.width, image.height);
            for (0..image.height) |y| {
                const from = image.row(y);
                for (result.row(y), 0..) |*p, x| p.* = from[image.width - 1 - x];
            }
            return result;
        }

        /// Returns a copy of the image, mirrored if `mirrored` is set, then turned
        /// `quarter_turns`. That's how a frame is shown after its crop. It always makes a copy.
        pub fn orient(image: Self, gpa: std.mem.Allocator, quarter_turns: u2, mirrored: bool) !Self {
            if (!mirrored) return image.rotate(gpa, quarter_turns);
            var flipped = try image.mirror(gpa);
            defer flipped.deinit(gpa);
            return flipped.rotate(gpa, quarter_turns);
        }

        /// Returns a copy of the image, turned clockwise by `quarter_turns` quarter turns (0 to 3).
        pub fn rotate(image: Self, gpa: std.mem.Allocator, quarter_turns: u2) !Self {
            const turned = quarter_turns % 2 == 1;
            var result: Self = try .init(gpa, if (turned) image.height else image.width, if (turned) image.width else image.height);
            for (0..image.height) |y| {
                for (image.row(y), 0..) |p, x| {
                    const to: [2]usize = switch (quarter_turns) {
                        0 => .{ x, y },
                        1 => .{ image.height - 1 - y, x },
                        2 => .{ image.width - 1 - x, image.height - 1 - y },
                        3 => .{ y, image.width - 1 - x },
                    };
                    result.pixels[to[1] * result.width + to[0]] = p;
                }
            }
            return result;
        }

        /// Returns a copy of the part of the image inside `area`.
        pub fn crop(image: Self, gpa: std.mem.Allocator, area: Area) !Self {
            std.debug.assert(area.x + area.width <= image.width and area.y + area.height <= image.height);
            var result: Self = try .init(gpa, area.width, area.height);
            for (0..area.height) |y| {
                @memcpy(result.row(y), image.row(area.y + y)[area.x..][0..area.width]);
            }
            return result;
        }
    };
}

/// A rectangle in pixels.
pub const Area = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,

    pub fn whole(width: usize, height: usize) Area {
        return .{ .x = 0, .y = 0, .width = width, .height = height };
    }

    /// Moves `area`, measured on an image `from` pixels wide, onto a copy of the same picture
    /// that's `to` pixels wide, clipped to `to_width` × `to_height`.
    pub fn rescale(area: Area, from: usize, to: usize, to_width: usize, to_height: usize) Area {
        const f = @as(f64, @floatFromInt(to)) / @as(f64, @floatFromInt(from));
        const x = @min(to_width -| 1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(area.x)) * f))));
        const y = @min(to_height -| 1, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(area.y)) * f))));
        const w = @max(1, @min(to_width - x, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(area.width)) * f)))));
        const h = @max(1, @min(to_height - y, @as(usize, @intFromFloat(@round(@as(f64, @floatFromInt(area.height)) * f)))));
        return .{ .x = x, .y = y, .width = w, .height = h };
    }

    /// Returns the middle of `area`, `fraction` of its width and height.
    pub fn centre(area: Area, fraction: f32) Area {
        const w: usize = @intFromFloat(@as(f32, @floatFromInt(area.width)) * fraction);
        const h: usize = @intFromFloat(@as(f32, @floatFromInt(area.height)) * fraction);
        return .{ .x = area.x + (area.width - w) / 2, .y = area.y + (area.height - h) / 2, .width = w, .height = h };
    }
};

/// The whole-number factor that brings an image's longer side down to `longest` or less.
pub fn reductionFactor(width: usize, height: usize, longest: usize) usize {
    return @max(1, (@max(width, height) + longest - 1) / longest);
}

/// Reduces `scan` by a whole-number factor so that its longer side is at most `longest`. Each
/// pixel is the mean of the block it covers.
pub fn downscale(gpa: std.mem.Allocator, scan: Scan, longest: usize) !Scan {
    const factor = reductionFactor(scan.width, scan.height, longest);
    var result: Scan = try .init(gpa, scan.width / factor, scan.height / factor);
    const block: u64 = factor * factor;
    for (0..result.height) |y| {
        for (result.row(y), 0..) |*p, x| {
            var sum: [channel_count]u64 = @splat(0);
            for (0..factor) |dy| {
                for (scan.row(y * factor + dy)[x * factor ..][0..factor]) |s| {
                    for (&sum, s) |*total, v| total.* += v;
                }
            }
            for (p, sum) |*out, total| out.* = @intCast(total / block);
        }
    }
    return result;
}

/// A scan: linear transmission, 16 bits per channel.
pub const Scan = Image([channel_count]u16);
/// A rendered image in 0..1, before encoding.
pub const Rendered = Image([channel_count]f32);
/// An encoded image, 8 bits per channel.
pub const Encoded8 = Image([channel_count]u8);
/// An encoded image, 16 bits per channel.
pub const Encoded16 = Image([channel_count]u16);

test "cropping copies the area" {
    const gpa = std.testing.allocator;
    var scan: Scan = try .init(gpa, 4, 3);
    defer scan.deinit(gpa);
    for (scan.pixels, 0..) |*p, i| p.* = @splat(@intCast(i));
    var part = try scan.crop(gpa, .{ .x = 1, .y = 1, .width = 2, .height = 2 });
    defer part.deinit(gpa);
    try std.testing.expectEqual([3]u16{ 5, 5, 5 }, part.at(0, 0));
    try std.testing.expectEqual([3]u16{ 10, 10, 10 }, part.at(1, 1));
}

test "the centre of an area" {
    const middle = Area.whole(100, 50).centre(0.5);
    try std.testing.expectEqual(Area{ .x = 25, .y = 12, .width = 50, .height = 25 }, middle);
}

test "downscaling averages blocks" {
    const gpa = std.testing.allocator;
    var scan: Scan = try .init(gpa, 4, 2);
    defer scan.deinit(gpa);
    for (scan.pixels, 0..) |*p, i| p.* = @splat(@intCast(i * 10));
    var small = try downscale(gpa, scan, 2);
    defer small.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), small.width);
    try std.testing.expectEqual(@as(usize, 1), small.height);
    try std.testing.expectEqual([3]u16{ 25, 25, 25 }, small.at(0, 0));
}

test "a quarter turn clockwise moves the top left corner to the top right" {
    const gpa = std.testing.allocator;
    var scan: Scan = try .init(gpa, 3, 2);
    defer scan.deinit(gpa);
    for (scan.pixels, 0..) |*p, i| p.* = @splat(@intCast(i));
    var turned = try scan.rotate(gpa, 1);
    defer turned.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), turned.width);
    try std.testing.expectEqual(@as(usize, 3), turned.height);
    // Row 0 of the original (0 1 2) becomes the right column, top to bottom.
    try std.testing.expectEqual(@as(u16, 0), turned.at(1, 0)[0]);
    try std.testing.expectEqual(@as(u16, 2), turned.at(1, 2)[0]);
    try std.testing.expectEqual(@as(u16, 3), turned.at(0, 0)[0]);
    var back = try turned.rotate(gpa, 3);
    defer back.deinit(gpa);
    try std.testing.expectEqualSlices([channel_count]u16, scan.pixels, back.pixels);
}

test "mirroring then a half turn turns the image upside down" {
    const gpa = std.testing.allocator;
    var scan: Scan = try .init(gpa, 3, 2);
    defer scan.deinit(gpa);
    for (scan.pixels, 0..) |*p, i| p.* = @splat(@intCast(i));
    var flipped = try scan.orient(gpa, 2, true);
    defer flipped.deinit(gpa);
    // Upside down, not mirrored: row 1 (3 4 5) comes first, in its own order.
    try std.testing.expectEqual(@as(u16, 3), flipped.at(0, 0)[0]);
    try std.testing.expectEqual(@as(u16, 5), flipped.at(2, 0)[0]);
    try std.testing.expectEqual(@as(u16, 0), flipped.at(0, 1)[0]);
}
