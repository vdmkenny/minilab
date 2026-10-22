//! Bakes the looks `presets/looks/bundled.zig` lists into the file the app embeds: each look's
//! 3D LUT at `bundled.size` points a side, in the list's order. The build runs it with each
//! collection's folder, which `build.zig.zon` fetches.
//!
//! usage: bake_looks <out file> <the folder of each collection, in `bundled.Pack`'s order>

const std = @import("std");
const bundled = @import("presets/looks/bundled.zig");
const cube_lut = @import("core/cube_lut.zig");
const image = @import("core/image.zig");
const png = @import("io/png.zig");

/// The largest collection file read: Street Monochrome's 64³ .cube files are 7 MB.
const max_file_bytes = 64 << 20;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const packs = comptime std.enums.values(bundled.Pack);
    if (args.len != 2 + packs.len) {
        std.log.err("usage: bake_looks <out file> <the folder of each collection: {d}>", .{packs.len});
        std.process.exit(2);
    }
    const folders = args[2..];
    const out = try gpa.alloc(u8, bundled.looks.len * bundled.lut_bytes);
    defer gpa.free(out);
    const values = try gpa.alloc([3]f32, bundled.lut_values / 3);
    defer gpa.free(values);
    for (bundled.looks, 0..) |look, i| {
        const path = try std.fs.path.join(gpa, &.{ folders[@backingInt(look.pack)], look.file });
        defer gpa.free(path);
        var lut = read(gpa, io, path) catch |err| {
            std.log.err("{s}: {t}", .{ path, err });
            return err;
        };
        defer lut.deinit(gpa);
        sample(&lut, values);
        bundled.encode(values, out[i * bundled.lut_bytes ..][0..bundled.lut_bytes]);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = out });
}

/// A collection's file as a LUT: a .cube file, or a HaldCLUT image.
fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !cube_lut.Lut {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(bytes);
    if (!std.mem.endsWith(u8, path, ".png")) return cube_lut.Lut.parse(gpa, bytes);
    var picture = try png.read(gpa, bytes);
    defer picture.deinit(gpa);
    return fromHald(gpa, picture);
}

/// A HaldCLUT image as a LUT. One of level L is L³ pixels square and holds a cube of L² points a
/// side, pixel by pixel from the top left, red changing fastest: the order of a .cube file.
fn fromHald(gpa: std.mem.Allocator, picture: image.Scan) !cube_lut.Lut {
    var level: usize = 2;
    while (level * level * level < picture.width) level += 1;
    if (level * level * level != picture.width or picture.height != picture.width) return error.NotAHaldClut;
    const values = try gpa.alloc([3]f32, picture.pixels.len);
    errdefer gpa.free(values);
    for (values, picture.pixels) |*v, p| {
        for (v, p) |*x, s| x.* = @as(f32, @floatFromInt(s)) / image.full_scale;
    }
    return .{ .title = try gpa.dupe(u8, ""), .three = .{ .size = level * level, .values = values } };
}

/// `lut` at the baked grid's points, red changing fastest.
fn sample(lut: *const cube_lut.Lut, values: [][3]f32) void {
    const top: f32 = bundled.size - 1;
    var i: usize = 0;
    for (0..bundled.size) |b| for (0..bundled.size) |g| for (0..bundled.size) |r| {
        const at = [3]f32{ @floatFromInt(r), @floatFromInt(g), @floatFromInt(b) };
        values[i] = lut.lookup(.{ at[0] / top, at[1] / top, at[2] / top });
        i += 1;
    };
}

test "an identity HaldCLUT bakes to the identity" {
    const gpa = std.testing.allocator;
    // Level 2: 8 × 8 pixels, a cube of 4 points a side.
    var picture: image.Scan = try .init(gpa, 8, 8);
    defer picture.deinit(gpa);
    for (picture.pixels, 0..) |*p, i| {
        const steps = [3]usize{ i % 4, i / 4 % 4, i / 16 };
        for (p, steps) |*s, step| s.* = @intCast(step * image.full_scale / 3);
    }
    var lut = try fromHald(gpa, picture);
    defer lut.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 4), lut.three.?.size);
    const values = try gpa.alloc([3]f32, bundled.lut_values / 3);
    defer gpa.free(values);
    sample(&lut, values);
    const top: f32 = bundled.size - 1;
    for ([_][3]usize{ .{ 0, 0, 0 }, .{ 32, 0, 0 }, .{ 0, 32, 0 }, .{ 5, 17, 29 }, .{ 32, 32, 32 } }) |point| {
        const v = values[(point[2] * bundled.size + point[1]) * bundled.size + point[0]];
        for (v, point) |x, p| try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(p)) / top, x, 1e-5);
    }
}

test "a picture that isn't a HaldCLUT is refused" {
    const gpa = std.testing.allocator;
    var picture: image.Scan = try .init(gpa, 9, 9);
    defer picture.deinit(gpa);
    try std.testing.expectError(error.NotAHaldClut, fromHald(gpa, picture));
}
