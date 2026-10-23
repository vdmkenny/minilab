//! Golden tests on our own V200 scans in `vendor/`, when they're there. We develop frames of the
//! colour strip with automatic settings, on the film base in their gaps, and check that they keep
//! the mean colours they had when the test was written, in Neutral and in Frontier emulation. A
//! change to the pipeline that moves them shows up here, and the numbers only get updated on
//! purpose. The scans are private and large, so the test is skipped without them.

const std = @import("std");
const image = @import("image.zig");
const develop = @import("develop.zig");
const framing = @import("framing.zig");
const look = @import("look.zig");
const encode = @import("encode.zig");
const pnm = @import("../io/pnm.zig");
const formats = @import("../frames/formats.zig");

/// Where `vendor/` is, seen from the project root and from `minilab/`.
const vendor_dirs = [_][]const u8{ "vendor", "../vendor" };
const strip_dir = "hw-scans/2026-10-22-colour";
const max_file_bytes = 256 << 20;
/// The size we develop frames at. The means don't need more.
const developed_longest = 400;
/// How far a mean may move, in steps of 255, before the test fails.
const tolerance = 2;

const Golden = struct {
    file: []const u8,
    /// The frame's mean sRGB colour over its middle half, in Neutral and then in Frontier
    /// emulation.
    neutral: [3]u8,
    frontier: [3]u8,
};

const goldens = [_]Golden{
    // A woodland track, a field with a barn under grey sky, and grass by a road.
    .{ .file = "frame-2.pnm", .neutral = .{ 89, 96, 62 }, .frontier = .{ 88, 96, 65 } },
    .{ .file = "frame-3.pnm", .neutral = .{ 137, 143, 138 }, .frontier = .{ 136, 143, 141 } },
    .{ .file = "frame-4.pnm", .neutral = .{ 117, 138, 82 }, .frontier = .{ 116, 138, 88 } },
};

test "the colour strip develops as it did" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var catalog: look.Catalog = try .init(gpa, null);
    defer catalog.deinit(gpa);
    var any = false;
    for (goldens) |golden| {
        const bytes = read(gpa, io, golden.file) orelse continue;
        defer gpa.free(bytes);
        any = true;
        var full = try pnm.read(gpa, bytes);
        defer full.deinit(gpa);
        var reduced = try image.downscale(gpa, full, framing.detection_longest);
        defer reduced.deinit(gpa);
        const found = try framing.findWithGaps(gpa, reduced, full.width, full.height, null, formats.Standard.default.format(), .colour_negative);
        const base = (try framing.measureBase(gpa, full, found.gaps)) orelse return error.NoFilmBase;
        var small = try image.downscale(gpa, full, developed_longest * full.width / found.frame.width);
        defer small.deinit(gpa);
        var frame = try small.crop(gpa, found.frame.rescale(full.width, small.width, small.width, small.height));
        defer frame.deinit(gpa);
        const whole: image.Area = .whole(frame.width, frame.height);
        for ([_]look.Id{ .neutral, .frontier }, [_][3]u8{ golden.neutral, golden.frontier }) |id, expected| {
            var developed = try look.developFrame(gpa, frame, whole, .colour_negative, try catalog.resolve(gpa, io, id), base, .{});
            defer developed.deinit(gpa);
            const mean = meanColour(developed, whole.centre(0.5));
            for (mean, expected) |m, e| try std.testing.expect(@abs(@as(i32, m) - e) <= tolerance);
        }
    }
    if (!any) return error.SkipZigTest;
}

fn read(gpa: std.mem.Allocator, io: std.Io, file: []const u8) ?[]u8 {
    return readVendor(gpa, io, &.{ strip_dir, file });
}

/// Reads the file at `parts` in `vendor/`, or returns null when it isn't there.
pub fn readVendor(gpa: std.mem.Allocator, io: std.Io, parts: []const []const u8) ?[]u8 {
    for (vendor_dirs) |dir| {
        const inside = std.fs.path.join(gpa, parts) catch return null;
        defer gpa.free(inside);
        const path = std.fs.path.join(gpa, &.{ dir, inside }) catch return null;
        defer gpa.free(path);
        return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes)) catch continue;
    }
    return null;
}

fn meanColour(rendered: image.Rendered, area: image.Area) [3]u8 {
    var sum: [3]f64 = @splat(0);
    for (area.y..area.y + area.height) |y| {
        for (rendered.row(y)[area.x..][0..area.width]) |p| {
            for (&sum, p) |*s, v| s.* += encode.srgb(v);
        }
    }
    const count: f64 = @floatFromInt(area.width * area.height);
    var mean: [3]u8 = undefined;
    for (&mean, sum) |*m, s| m.* = encode.quantise(u8, @floatCast(s / count));
    return mean;
}
