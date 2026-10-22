//! A check of frame detection on the V200 scans in `vendor/`, where they are present. It is not
//! part of the test suite, because the scans are private and large; it prints what detection
//! finds rather than asserting it. Zig only lets this file reach `../core/` from a root in
//! `src/`, so run it through one, from the project root or from `negscan/`: a file in `src/`
//! holding `test { _ = @import("frames/check_scans.zig"); }`, run with `zig test -O ReleaseFast`.
//!
//! The scans are a B&W negative strip and a colour negative frame:
//!
//! - `10-preview-negative`: the Epson stack's 300 dpi preview of the whole B&W strip, 8-bit at
//!   gamma 1.8, six frames.
//! - `60-tpu-pos-c16-300`: 16-bit at gamma 1.8, 300 dpi, 40 mm around frame 2.
//! - `hw-scans/2026-10-22`: 2400 dpi scans of one frame each with the holder's edges, the gaps
//!   and part of the neighbouring frames. Each is checked at full resolution and reduced to 300
//!   dpi, as a preview would be.

const std = @import("std");
const image = @import("../core/image.zig");
const pnm = @import("../io/pnm.zig");
const formats = @import("formats.zig");
const detect = @import("detect.zig");

const Source = struct {
    path: []const u8,
    dpi: f32,
    /// The scanner's gamma: 1 for linear data.
    gamma: f32,
};

const preview_dpi = 300;
const frame_dpi = 2400;
/// The Epson stack's default gamma table.
const epson_gamma = 1.8;

const sources = [_]Source{
    .{ .path = "recordings/10-preview-negative/output", .dpi = preview_dpi, .gamma = epson_gamma },
    .{ .path = "recordings/60-tpu-pos-c16-300/output", .dpi = preview_dpi, .gamma = epson_gamma },
    .{ .path = "hw-scans/2026-10-22/mac-colour-negative-c16-2400-gamma10-negative-film.pnm", .dpi = frame_dpi, .gamma = 1 },
    .{ .path = "hw-scans/2026-10-22/mac-colour-negative-c16-2400-gamma10-positive-film.pnm", .dpi = frame_dpi, .gamma = 1 },
    .{ .path = "hw-scans/2026-10-22/mac-positive-c16-2400-gamma10-a.pnm", .dpi = frame_dpi, .gamma = 1 },
    .{ .path = "hw-scans/2026-10-22/mac-negative-c8-2400-warm.pnm", .dpi = frame_dpi, .gamma = epson_gamma },
};

/// Where `vendor/` is, seen from the project root and from `negscan/`.
const vendor_dirs = [_][]const u8{ "vendor", "../vendor" };
const max_file_bytes = 256 << 20;

test "V200 scans" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const format = formats.Standard.@"135_full_frame".format();
    for (sources) |source| {
        const bytes = read(gpa, io, source.path) orelse {
            std.debug.print("{s}: not present\n", .{source.path});
            continue;
        };
        defer gpa.free(bytes);
        var scan = try decode(gpa, bytes, source.gamma);
        defer scan.deinit(gpa);
        try report(gpa, io, source.path, scan, source.dpi, format);
        if (source.dpi > preview_dpi) {
            const factor: usize = @intFromFloat(source.dpi / preview_dpi);
            var small = try image.downscale(gpa, scan, @max(scan.width, scan.height) / factor);
            defer small.deinit(gpa);
            try report(gpa, io, "  reduced to 300 dpi", small, preview_dpi, format);
        }
    }
}

fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ?[]u8 {
    for (vendor_dirs) |dir| {
        const full = std.fs.path.join(gpa, &.{ dir, path }) catch return null;
        defer gpa.free(full);
        return std.Io.Dir.cwd().readFileAlloc(io, full, gpa, .limited(max_file_bytes)) catch continue;
    }
    return null;
}

fn report(gpa: std.mem.Allocator, io: std.Io, name: []const u8, scan: image.Scan, dpi: f32, format: formats.Format) !void {
    const px_per_mm = dpi / formats.mm_per_inch;
    const start = std.Io.Clock.awake.now(io);
    var detection = detect.detect(gpa, scan, dpi, format, .negative, .{}) catch |err| {
        std.debug.print("{s}: {s}\n", .{ name, @errorName(err) });
        return;
    };
    defer detection.deinit(gpa);
    const ms = @divTrunc(start.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds(), std.time.ns_per_ms);
    std.debug.print("{s}: {d} × {d} px in {d} ms, along {s}, skew {d:.2}°, opening {d:.2} mm, {d} frames\n", .{
        name,                     scan.width,                 scan.height,          ms,
        @tagName(detection.axis), detection.rotation_degrees, detection.opening_mm, detection.frames.len,
    });
    for (detection.frames) |f| {
        const mm = struct {
            fn of(px: usize, scale: f32) f32 {
                return @as(f32, @floatFromInt(px)) / scale;
            }
        }.of;
        std.debug.print("    {d}: x {d:.1} y {d:.1} mm, {d:.1} × {d:.1} mm, {s}\n", .{
            f.index,                     mm(f.area.x, px_per_mm),      mm(f.area.y, px_per_mm),
            mm(f.area.width, px_per_mm), mm(f.area.height, px_per_mm), @tagName(f.confidence),
        });
    }
}

/// A PNM as a linear scan, with the scanner's gamma undone.
fn decode(gpa: std.mem.Allocator, bytes: []const u8, gamma: f32) !image.Scan {
    const scan = try pnm.read(gpa, bytes);
    var table: [image.full_scale + 1]u16 = undefined;
    for (&table, 0..) |*entry, v| {
        const fraction = @as(f32, @floatFromInt(v)) / image.full_scale;
        entry.* = @intFromFloat(@round(std.math.pow(f32, fraction, gamma) * image.full_scale));
    }
    for (scan.pixels) |*p| {
        for (p) |*c| c.* = table[c.*];
    }
    return scan;
}
