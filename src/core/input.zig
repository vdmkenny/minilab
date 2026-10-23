//! Reads scans from files (design section 5). Four kinds of file can hold a scan: binary PNM, as
//! SANE's scanimage writes it; TIFF from other scanning software, such as VueScan's or
//! SilverFast's raw output; camera RAW, through LibRaw; and JPEG, for finished pictures such as a
//! lab's scans. They all come out the same way: linear 16-bit values, with full scale at 65535.
//!
//! - PNM and TIFF are taken as they are. They should be 16-bit and linear. We read 8-bit files
//!   too, widened to 16 bits, but with a warning: they're probably gamma-encoded, and nothing
//!   undoes that yet.
//! - Camera RAW is demosaiced with no white balance, no colour matrix and no gamma (`raw.read`),
//!   and scaled so that the sensor's white level is full scale. Its white balance and matrix come
//!   along with it, for slides (`develop.SlideColour`).
//! - JPEG is a finished picture, encoded in sRGB. We undo the sRGB curve, so the pipeline's
//!   output, encoded again, matches the file. An embedded profile other than sRGB isn't used.

const std = @import("std");
const image = @import("image.zig");
const pnm = @import("../io/pnm.zig");
const tiff = @import("../io/codecs/tiff.zig");
const raw = @import("../io/codecs/raw.zig");
const develop = @import("develop.zig");
const jpeg = @import("../io/codecs/jpeg.zig");
const encode = @import("encode.zig");

const log = std.log.scoped(.input);

/// The largest file we read: 2 GiB.
pub const max_file_bytes = 2 << 30;

pub const Kind = enum {
    pnm,
    tiff,
    camera_raw,
    /// A finished picture, such as a lab's scan or one from a scanner that inverts by itself.
    jpeg,

    /// Works out the kind of file at `path` from its extension. Anything that isn't PNM, TIFF or
    /// JPEG is taken to be a camera RAW file, which LibRaw then reads or refuses. Many RAW formats
    /// are TIFF inside, so the contents can't tell them apart.
    pub fn of(path: []const u8) Kind {
        const extension = std.fs.path.extension(path);
        for (pnm_extensions) |e| if (std.ascii.eqlIgnoreCase(extension, e)) return .pnm;
        for (tiff_extensions) |e| if (std.ascii.eqlIgnoreCase(extension, e)) return .tiff;
        for (jpeg_extensions) |e| if (std.ascii.eqlIgnoreCase(extension, e)) return .jpeg;
        return .camera_raw;
    }

    /// Whether files of this kind are finished pictures rather than raw scans.
    pub fn finished(kind: Kind) bool {
        return kind == .jpeg;
    }
};

const pnm_extensions = [_][]const u8{ ".ppm", ".pnm", ".pgm" };
const tiff_extensions = [_][]const u8{ ".tif", ".tiff" };
const jpeg_extensions = [_][]const u8{ ".jpg", ".jpeg" };

/// `list`'s extensions without their dots, each followed by ';'.
fn dialogList(comptime list: []const []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (list) |extension| out = out ++ extension[1..] ++ ";";
        return out;
    }
}

/// Whether `path` has the extension of a file we read scans from.
pub fn readable(path: []const u8) bool {
    const extension = std.fs.path.extension(path);
    if (extension.len < 2) return false;
    var names = std.mem.splitScalar(u8, extensions, ';');
    while (names.next()) |name| {
        if (std.ascii.eqlIgnoreCase(extension[1..], name)) return true;
    }
    return false;
}

/// The scans at `paths`, with each folder among them replaced by the files in it that `readable`
/// takes, in natural order (2 before 10). Folders inside folders aren't opened, and hidden files
/// are left out. Free the result with `freeExpanded`.
pub fn expand(gpa: std.mem.Allocator, io: std.Io, paths: []const []const u8) ![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |p| gpa.free(p);
        out.deinit(gpa);
    }
    for (paths) |path| {
        var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
            error.NotDir => {
                try out.append(gpa, try gpa.dupe(u8, path));
                continue;
            },
            else => return err,
        };
        defer dir.close(io);
        const start = out.items.len;
        var each = dir.iterate();
        while (try each.next(io)) |entry| {
            if (entry.kind != .file or entry.name[0] == '.' or !readable(entry.name)) continue;
            try out.append(gpa, try std.fs.path.join(gpa, &.{ path, entry.name }));
        }
        std.mem.sort([]u8, out.items[start..], {}, naturalLess);
    }
    return out.toOwnedSlice(gpa);
}

/// Frees what `expand` returned.
pub fn freeExpanded(gpa: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |p| gpa.free(p);
    gpa.free(paths);
}

/// Whether `a` comes before `b` with runs of digits compared as numbers, so IMG_2 comes before
/// IMG_10.
pub fn naturalLess(_: void, a: []const u8, b: []const u8) bool {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const a_end = digitsEnd(a, i);
            const b_end = digitsEnd(b, j);
            const x = std.mem.trimStart(u8, a[i..a_end], "0");
            const y = std.mem.trimStart(u8, b[j..b_end], "0");
            if (x.len != y.len) return x.len < y.len;
            switch (std.mem.order(u8, x, y)) {
                .lt => return true,
                .gt => return false,
                .eq => {},
            }
            i = a_end;
            j = b_end;
            continue;
        }
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[j]);
        if (x != y) return x < y;
        i += 1;
        j += 1;
    }
    return a.len - i < b.len - j;
}

fn digitsEnd(text: []const u8, start: usize) usize {
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return end;
}

/// The extensions of the files we read scans from, without their dots, the way SDL's file
/// dialogs take them: PNM, TIFF, JPEG, and the camera RAW formats of the makers LibRaw reads.
pub const extensions = dialogList(&(pnm_extensions ++ tiff_extensions ++ jpeg_extensions)) ++ raw_extensions;
pub const raw_extensions = "dng;nef;nrw;cr2;cr3;crw;arw;srf;sr2;raf;orf;rw2;rwl;pef;srw;3fr;fff;iiq;erf;kdc;dcr;mos;mrw;x3f";

/// Bits per sample in the file. Camera RAW counts as 16, since it's linear whatever the sensor's
/// depth.
pub const Depth = image.Depth;

/// A file read into a scan.
pub const Read = struct {
    scan: image.Scan,
    kind: Kind,
    depth: Depth,
    /// A camera RAW file's colour: its white balance as shot, for the light behind the film (or
    /// its daylight balance if it has none), and its matrix to sRGB. Null for scans.
    camera: ?develop.SlideColour = null,

    pub fn deinit(read_scan: *Read, gpa: std.mem.Allocator) void {
        read_scan.scan.deinit(gpa);
        read_scan.* = undefined;
    }

    /// Whether we can take the samples as linear. An 8-bit file almost never is: 8 bits are too
    /// few for linear data, so software that writes them applies a gamma. A JPEG's sRGB curve is
    /// undone on reading, so it counts as linear.
    pub fn linear(read_scan: Read) bool {
        return read_scan.depth == .sixteen or read_scan.kind == .jpeg;
    }
};

/// Reads the scan in the file at `path`, as the kind of file its extension says.
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
            return .{ .scan = decoded.scan, .kind = kind, .depth = decoded.depth };
        },
        .tiff => {
            const decoded = try tiff.read(gpa, bytes);
            // A profile says how to show the file's colours, but the density stage works in the
            // scanner's own channels, so we don't use it.
            if (decoded.icc_profile) |profile| gpa.free(profile);
            return .{ .scan = decoded.scan, .kind = kind, .depth = decoded.depth };
        },
        .jpeg => {
            var decoded = try jpeg.read(gpa, bytes);
            defer decoded.deinit(gpa);
            return .{ .scan = try linearFromSrgb8(gpa, decoded.image), .kind = kind, .depth = .eight };
        },
        .camera_raw => {
            const decoded = try raw.read(gpa, bytes, .{});
            toFullScale(decoded.scan, decoded.white);
            const balance = decoded.as_shot_multipliers orelse decoded.daylight_multipliers;
            return .{
                .scan = decoded.scan,
                .kind = kind,
                .depth = .sixteen,
                .camera = if (balance) |b| .{ .balance = b, .to_srgb = decoded.camera_to_srgb } else null,
            };
        },
    }
}

/// `picture`, encoded in sRGB, as linear 16-bit values.
fn linearFromSrgb8(gpa: std.mem.Allocator, picture: image.Encoded8) !image.Scan {
    var table: [256]u16 = undefined;
    for (&table, 0..) |*entry, v| {
        entry.* = @intFromFloat(@round(encode.linearFromSrgb(@as(f32, @floatFromInt(v)) / 255) * image.full_scale));
    }
    const scan: image.Scan = try .init(gpa, picture.width, picture.height);
    for (scan.pixels, picture.pixels) |*out, p| {
        for (out, p) |*o, v| o.* = table[v];
    }
    return scan;
}

/// Scales `scan`, whose samples run from 0 to `white`, so that `white` is full scale.
/// Demosaicing overshoots the white level a little at sharp edges, and those samples clip.
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
    try std.testing.expectEqual(Kind.jpeg, Kind.of("IMG_0001.JPG"));
    try std.testing.expect(readable("lab/scan.jpeg"));
    try std.testing.expect(readable("DSC_0044.NEF"));
    try std.testing.expect(!readable("notes.txt"));
    try std.testing.expect(!readable("folder"));
}

test "names sort with their numbers as numbers" {
    try std.testing.expect(naturalLess({}, "IMG_2.jpg", "IMG_10.jpg"));
    try std.testing.expect(!naturalLess({}, "IMG_10.jpg", "IMG_2.jpg"));
    try std.testing.expect(naturalLess({}, "img_0009.JPG", "IMG_0010.jpg"));
    try std.testing.expect(naturalLess({}, "scan", "scan 2"));
}

test "a folder expands to the scans in it, in order, and a file stays itself" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "IMG_10.jpg", "IMG_2.JPG", "notes.txt", ".hidden.jpg" }) |name| try tmp.dir.writeFile(io, .{ .sub_path = name, .data = "" });
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);
    const lone = try std.fs.path.join(gpa, &.{ folder, "IMG_10.jpg" });
    defer gpa.free(lone);
    const found = try expand(gpa, io, &.{ folder, lone });
    defer freeExpanded(gpa, found);
    try std.testing.expectEqual(@as(usize, 3), found.len);
    try std.testing.expectEqualStrings("IMG_2.JPG", std.fs.path.basename(found[0]));
    try std.testing.expectEqualStrings("IMG_10.jpg", std.fs.path.basename(found[1]));
    try std.testing.expectEqualStrings(lone, found[2]);
}

test "a JPEG reads as linear, and encodes back to what it was" {
    const gpa = std.testing.allocator;
    var picture: image.Encoded8 = try .init(gpa, 8, 8);
    defer picture.deinit(gpa);
    for (picture.pixels, 0..) |*p, i| p.* = @splat(@intCast(i * 4));
    const file = try jpeg.write(gpa, picture, .{ .quality = 100 });
    defer gpa.free(file);
    var read_back = try decode(gpa, .jpeg, file);
    defer read_back.deinit(gpa);
    try std.testing.expect(read_back.linear());
    // Mid grey in sRGB is about a fifth of full scale in linear light.
    const middle: f32 = @floatFromInt(read_back.scan.pixels[32][0]);
    try std.testing.expectApproxEqAbs(encode.linearFromSrgb(128.0 / 255.0), middle / image.full_scale, 0.02);
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

/// The environment variable that names a camera RAW file for the test below, which is skipped
/// without it. It's the same one `raw.zig`'s test reads.
const raw_sample_variable = "MINILAB_RAW_SAMPLE";

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

test "the file dialogs get every extension we read" {
    try std.testing.expect(std.mem.startsWith(u8, extensions, "ppm;pnm;pgm;tif;tiff;jpg;jpeg;dng;"));
}
