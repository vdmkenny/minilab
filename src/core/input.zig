//! Reading scans from files (design section 5). Three kinds of file give a scan: binary PNM, as
//! SANE's scanimage writes it; TIFF from other scanning software, such as VueScan's or
//! SilverFast's raw output; and camera RAW, through LibRaw. Each comes out the same way: linear
//! 16-bit transmission in the scanner's or the camera's own channels, full scale at 65535.
//!
//! - PNM and TIFF are taken as they are. They should be 16-bit and linear. An 8-bit file is read
//!   too, widened to 16 bits, with a warning: it's probably gamma-encoded, and nothing undoes that
//!   yet.
//! - Camera RAW is demosaiced with no white balance, no colour matrix and no gamma (`raw.read`),
//!   and scaled so that the sensor's white level is full scale.

const std = @import("std");
const image = @import("image.zig");
const pnm = @import("../io/pnm.zig");
const tiff = @import("../io/codecs/tiff.zig");
const raw = @import("../io/codecs/raw.zig");

const log = std.log.scoped(.input);

/// The largest file read, 2 GiB.
pub const max_file_bytes = 2 << 30;

pub const Kind = enum {
    pnm,
    tiff,
    camera_raw,

    /// The kind of the file at `path`, by its extension. Anything that is neither PNM nor TIFF is
    /// taken for a camera RAW file, which LibRaw then reads or refuses: many RAW formats are TIFF
    /// inside, so the contents don't tell them apart.
    pub fn of(path: []const u8) Kind {
        const extension = std.fs.path.extension(path);
        for (pnm_extensions) |e| if (std.ascii.eqlIgnoreCase(extension, e)) return .pnm;
        for (tiff_extensions) |e| if (std.ascii.eqlIgnoreCase(extension, e)) return .tiff;
        return .camera_raw;
    }
};

const pnm_extensions = [_][]const u8{ ".ppm", ".pnm", ".pgm" };
const tiff_extensions = [_][]const u8{ ".tif", ".tiff" };

/// The extensions of the files a scan is read from, without their dots, as SDL's file dialogs
/// take them: PNM, TIFF, and the camera RAW formats of the makers LibRaw reads.
pub const extensions = "ppm;pnm;pgm;tif;tiff;" ++ raw_extensions;
pub const raw_extensions = "dng;nef;nrw;cr2;cr3;crw;arw;srf;sr2;raf;orf;rw2;rwl;pef;srw;3fr;fff;iiq;erf;kdc;dcr;mos;mrw;x3f";

/// Bits per sample in the file. Camera RAW counts as 16: it's linear whatever the sensor's depth.
pub const Depth = enum { eight, sixteen };

/// A file read into a scan.
pub const Read = struct {
    scan: image.Scan,
    kind: Kind,
    depth: Depth,

    pub fn deinit(read_scan: *Read, gpa: std.mem.Allocator) void {
        read_scan.scan.deinit(gpa);
        read_scan.* = undefined;
    }

    /// Whether the samples can be taken as linear. An 8-bit file almost never is: 8 bits are too
    /// few for linear data, so software that writes them applies a gamma.
    pub fn linear(read_scan: Read) bool {
        return read_scan.depth == .sixteen;
    }
};

/// Reads the scan in the file at `path`, of the kind its extension says.
pub fn read(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Read {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_file_bytes));
    defer gpa.free(bytes);
    const result = try decode(gpa, Kind.of(path), bytes);
    if (!result.linear()) log.warn("{s} has 8 bits per sample: it's probably not linear, and will develop with the wrong contrast", .{path});
    return result;
}

/// Decodes `bytes`, a file of `kind`.
pub fn decode(gpa: std.mem.Allocator, kind: Kind, bytes: []const u8) !Read {
    switch (kind) {
        .pnm => {
            const decoded = try pnm.decode(gpa, bytes);
            return .{ .scan = decoded.scan, .kind = kind, .depth = switch (decoded.depth) {
                .eight => .eight,
                .sixteen => .sixteen,
            } };
        },
        .tiff => {
            const decoded = try tiff.read(gpa, bytes);
            // A profile says how to show the file's colours; the density stage works in the
            // scanner's own channels, so it isn't used.
            if (decoded.icc_profile) |profile| gpa.free(profile);
            return .{ .scan = decoded.scan, .kind = kind, .depth = switch (decoded.depth) {
                .eight => .eight,
                .sixteen => .sixteen,
            } };
        },
        .camera_raw => {
            const decoded = try raw.read(gpa, bytes, .{});
            toFullScale(decoded.scan, decoded.white);
            return .{ .scan = decoded.scan, .kind = kind, .depth = .sixteen };
        },
    }
}

/// Scales `scan`, whose samples run from 0 to `white`, so that `white` is full scale. Demosaicing
/// overshoots the white level a little at sharp edges; those samples clip.
fn toFullScale(scan: image.Scan, white: u16) void {
    if (white == 0 or white == image.full_scale) return;
    const gain = @as(f32, image.full_scale) / @as(f32, @floatFromInt(white));
    for (scan.pixels) |*pixel| {
        for (pixel) |*sample| sample.* = @intFromFloat(@min(@round(@as(f32, @floatFromInt(sample.*)) * gain), image.full_scale));
    }
}

test "the kind comes from the extension, in any case" {
    try std.testing.expectEqual(Kind.pnm, Kind.of("scans/01.ppm"));
    try std.testing.expectEqual(Kind.pnm, Kind.of("frame.PGM"));
    try std.testing.expectEqual(Kind.tiff, Kind.of("strip.TIF"));
    try std.testing.expectEqual(Kind.tiff, Kind.of("strip.tiff"));
    try std.testing.expectEqual(Kind.camera_raw, Kind.of("DSC_0044.NEF"));
    try std.testing.expectEqual(Kind.camera_raw, Kind.of("frame.dng"));
}

test "a 16-bit TIFF is linear and an 8-bit one isn't" {
    const gpa = std.testing.allocator;
    var encoded: image.Encoded16 = try .init(gpa, 3, 2);
    defer encoded.deinit(gpa);
    for (encoded.pixels, 0..) |*p, i| p.* = .{ @intCast(i * 1000), @intCast(i * 2000), @intCast(i * 3000) };
    const file = try tiff.write(gpa, u16, encoded, .{});
    defer gpa.free(file);
    var wide = try decode(gpa, .tiff, file);
    defer wide.deinit(gpa);
    try std.testing.expect(wide.linear());
    try std.testing.expectEqualSlices([image.channel_count]u16, encoded.pixels, wide.scan.pixels);

    var narrow_pixels: image.Encoded8 = try .init(gpa, 1, 1);
    defer narrow_pixels.deinit(gpa);
    narrow_pixels.pixels[0] = .{ 10, 20, 30 };
    const narrow_file = try tiff.write(gpa, u8, narrow_pixels, .{});
    defer gpa.free(narrow_file);
    var narrow = try decode(gpa, .tiff, narrow_file);
    defer narrow.deinit(gpa);
    try std.testing.expect(!narrow.linear());
}

test "a camera's white level becomes full scale" {
    const gpa = std.testing.allocator;
    var scan: image.Scan = try .init(gpa, 3, 1);
    defer scan.deinit(gpa);
    const white = 16383;
    scan.pixels[0] = .{ 0, white / 2, white };
    scan.pixels[1] = @splat(white);
    // Demosaicing's overshoot past the white level clips.
    scan.pixels[2] = @splat(white + white / 4);
    toFullScale(scan, white);
    try std.testing.expectEqual(@as(u16, 0), scan.pixels[0][0]);
    try std.testing.expectApproxEqAbs(@as(f32, image.full_scale) / 2, @as(f32, @floatFromInt(scan.pixels[0][1])), 4);
    try std.testing.expectEqual(@as(u16, image.full_scale), scan.pixels[0][2]);
    try std.testing.expectEqual(@as([3]u16, @splat(image.full_scale)), scan.pixels[2]);
}

/// The environment variable naming a camera RAW file for the test below, which skips without it:
/// the same one `raw.zig`'s test reads.
const raw_sample_variable = "NEGSCAN_RAW_SAMPLE";

test "a camera RAW file reads as a linear scan up to full scale" {
    const gpa = std.testing.allocator;
    const path = std.testing.environ.getAlloc(gpa, raw_sample_variable) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
    defer gpa.free(path);
    var scan = try read(gpa, std.testing.io, path);
    defer scan.deinit(gpa);
    try std.testing.expectEqual(Kind.camera_raw, scan.kind);
    try std.testing.expect(scan.linear());
    var brightest: u16 = 0;
    for (scan.scan.pixels) |pixel| brightest = @max(brightest, pixel[0], pixel[1], pixel[2]);
    try std.testing.expect(brightest > 0);
}
