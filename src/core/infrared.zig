//! Dust correction from a separate infrared transmission plane. This is our
//! own conservative mask and interpolation, not Epson's Digital ICE algorithm.
//! Only masked RGB pixels change; the caller keeps the original capture.
const std = @import("std");
const image = @import("image.zig");
const dust = @import("dust.zig");

pub const Result = struct { scan: image.Scan, pixels: usize };
const minimum_drop = 3 * image.widen_8_to_16;
const relative_drop = 0.07;
const max_mask_share = 0.05;
const relaxations = 24;

pub fn clean(gpa: std.mem.Allocator, rgb: image.Scan, ir: image.Gray, dpi: f32) !Result {
    if (ir.width != rgb.width or ir.height != rgb.height or rgb.pixels.len == 0 or
        ir.pixels.len != rgb.pixels.len or !std.math.isFinite(dpi) or dpi <= 0 or dpi > 100_000) return error.InvalidInfrared;
    const background = try gpa.dupe(u16, ir.pixels);
    defer gpa.free(background);
    // A physical radius of about 0.13 mm finds small specks and narrow fibres.
    const radius: usize = @max(2, @as(usize, @intFromFloat(@round(dpi / 200))));
    try dust.filter(u16, .max, gpa, background, ir.width, ir.height, radius);
    try dust.filter(u16, .min, gpa, background, ir.width, ir.height, radius);
    const mask = try gpa.alloc(u8, ir.pixels.len);
    defer gpa.free(mask);
    for (mask, ir.pixels, background) |*marked, value, around| {
        const drop = @as(u32, around) -| value;
        const threshold = @max(minimum_drop, @as(u32, @intFromFloat(@as(f32, @floatFromInt(around)) * relative_drop)));
        marked.* = @intFromBool(drop > threshold);
    }
    // Cover the edge of the dust and small mechanical registration differences.
    const fringe: usize = @max(1, @as(usize, @intFromFloat(@round(dpi / 1600))));
    try dust.filter(u8, .max, gpa, mask, ir.width, ir.height, fringe);
    const count = std.mem.countScalar(u8, mask, 1);
    if (@as(f64, @floatFromInt(count)) > @as(f64, @floatFromInt(mask.len)) * max_mask_share) return error.UnreliableInfrared;
    var result = try image.Scan.init(gpa, rgb.width, rgb.height);
    errdefer result.deinit(gpa);
    @memcpy(result.pixels, rgb.pixels);
    if (count == 0) return .{ .scan = result, .pixels = 0 };
    var queue: std.ArrayList(usize) = .empty;
    defer queue.deinit(gpa);
    try queue.ensureTotalCapacityPrecise(gpa, count);
    // 0 is untouched, 1 unknown, 2 queued, 3 filled. Each pixel enters once.
    for (mask, 0..) |marked, i| if (marked == 1) {
        const x = i % rgb.width;
        const y = i / rgb.width;
        if ((x > 0 and mask[i - 1] == 0) or (x + 1 < rgb.width and mask[i + 1] == 0) or
            (y > 0 and mask[i - rgb.width] == 0) or (y + 1 < rgb.height and mask[i + rgb.width] == 0))
        {
            mask[i] = 2;
            queue.appendAssumeCapacity(i);
        }
    };
    var cursor: usize = 0;
    while (cursor < queue.items.len) : (cursor += 1) {
        const i = queue.items[cursor];
        const x = i % rgb.width;
        const y = i / rgb.width;
        var neighbours: [4]usize = undefined;
        const ns = adjacent(x, y, rgb.width, rgb.height, &neighbours);
        var sums: [3]u32 = @splat(0);
        var n: u32 = 0;
        for (ns) |near| if (mask[near] == 0 or mask[near] == 3) {
            for (&sums, result.pixels[near]) |*sum, sample| sum.* += sample;
            n += 1;
        };
        if (n == 0) return error.UnreliableInfrared;
        for (&result.pixels[i], sums) |*sample, sum| sample.* = @intCast((sum + n / 2) / n);
        mask[i] = 3;
        for (ns) |near| if (mask[near] == 1) {
            mask[near] = 2;
            queue.appendAssumeCapacity(near);
        };
    }
    if (queue.items.len != count) return error.UnreliableInfrared;
    // Relax the filled region against the unchanged colour boundary. This
    // reduces directional streaks from filling a long fibre from one end.
    const next = try gpa.alloc([3]u16, count);
    defer gpa.free(next);
    for (0..relaxations) |_| {
        for (queue.items, next) |i, *pixel| {
            var neighbours: [4]usize = undefined;
            const ns = adjacent(i % rgb.width, i / rgb.width, rgb.width, rgb.height, &neighbours);
            var sums: [3]u32 = @splat(0);
            for (ns) |near| for (&sums, result.pixels[near]) |*sum, sample| {
                sum.* += sample;
            };
            for (pixel, sums) |*sample, sum| sample.* = @intCast((sum + ns.len / 2) / ns.len);
        }
        for (queue.items, next) |i, pixel| result.pixels[i] = pixel;
    }
    return .{ .scan = result, .pixels = count };
}

fn adjacent(x: usize, y: usize, width: usize, height: usize, buffer: *[4]usize) []const usize {
    const i = y * width + x;
    var n: usize = 0;
    if (x > 0) {
        buffer[n] = i - 1;
        n += 1;
    }
    if (x + 1 < width) {
        buffer[n] = i + 1;
        n += 1;
    }
    if (y > 0) {
        buffer[n] = i - width;
        n += 1;
    }
    if (y + 1 < height) {
        buffer[n] = i + width;
        n += 1;
    }
    return buffer[0..n];
}

test "infrared marks a speck without changing real colour detail or the source" {
    const gpa = std.testing.allocator;
    var rgb = try image.Scan.init(gpa, 64, 64);
    defer rgb.deinit(gpa);
    var ir = try image.Gray.init(gpa, 64, 64);
    defer ir.deinit(gpa);
    @memset(ir.pixels, 55000);
    for (rgb.pixels, 0..) |*p, i| p.* = if (i % 64 < 20) .{ 6000, 17000, 31000 } else .{ 31000, 42000, 53000 };
    const speck = 32 * 64 + 40;
    rgb.pixels[speck] = @splat(1000);
    ir.pixels[speck] = 15000;
    var corrected = try clean(gpa, rgb, ir, 800);
    defer corrected.scan.deinit(gpa);
    try std.testing.expectEqual([3]u16{ 31000, 42000, 53000 }, corrected.scan.pixels[speck]);
    try std.testing.expectEqual([3]u16{ 1000, 1000, 1000 }, rgb.pixels[speck]);
    try std.testing.expectEqual(@as(usize, 9), corrected.pixels);
    for (rgb.pixels, corrected.scan.pixels, 0..) |before, after, i| {
        if (@abs(@as(isize, @intCast(i % 64)) - 40) > 1 or @abs(@as(isize, @intCast(i / 64)) - 32) > 1)
            try std.testing.expectEqual(before, after);
    }
}

test "a clear infrared image preserves colour highlights and mismatched images fail" {
    const gpa = std.testing.allocator;
    var rgb = try image.Scan.init(gpa, 32, 32);
    defer rgb.deinit(gpa);
    var ir = try image.Gray.init(gpa, 32, 32);
    defer ir.deinit(gpa);
    @memset(rgb.pixels, .{ 12000, 24000, 36000 });
    @memset(ir.pixels, 50000);
    rgb.pixels[500] = @splat(65000);
    var corrected = try clean(gpa, rgb, ir, 1600);
    defer corrected.scan.deinit(gpa);
    try std.testing.expectEqualSlices([3]u16, rgb.pixels, corrected.scan.pixels);
    ir.width = 16;
    try std.testing.expectError(error.InvalidInfrared, clean(gpa, rgb, ir, 800));
}

test "an infrared plane full of apparent defects is refused" {
    const gpa = std.testing.allocator;
    var rgb = try image.Scan.init(gpa, 32, 32);
    defer rgb.deinit(gpa);
    var ir = try image.Gray.init(gpa, 32, 32);
    defer ir.deinit(gpa);
    @memset(rgb.pixels, .{ 12000, 24000, 36000 });
    for (ir.pixels, 0..) |*p, i| p.* = if (i % 2 == 0) 10000 else 50000;
    try std.testing.expectError(error.UnreliableInfrared, clean(gpa, rgb, ir, 800));
}
