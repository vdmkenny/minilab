//! A PNG reader for greyscale and RGB images, with or without alpha, at 8 or 16 bits and not
//! interlaced. Some film look collections come as HaldCLUT images, and those are PNGs of this
//! kind.

const std = @import("std");
const image = @import("../core/image.zig");

const signature = "\x89PNG\r\n\x1a\n";

pub const Error = error{ NotAPng, Truncated, BadChecksum, InvalidHeader, UnsupportedFormat, BadFilter, BadData };

/// The colour types we read: grey and RGB, each with or without alpha.
const ColourType = enum(u8) {
    grey = 0,
    rgb = 2,
    grey_alpha = 4,
    rgba = 6,
    _,

    fn channels(colour: ColourType) ?usize {
        return switch (colour) {
            .grey => 1,
            .rgb => 3,
            .grey_alpha => 2,
            .rgba => 4,
            _ => null,
        };
    }
};

/// How a scanline was filtered before compression.
const Filter = enum(u8) { none = 0, sub = 1, up = 2, average = 3, paeth = 4, _ };

/// Reads a PNG into a scan. 8-bit samples are scaled up to 16 bits, grey is copied into all three
/// channels, and alpha is dropped.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!image.Scan {
    if (!std.mem.startsWith(u8, bytes, signature)) return error.NotAPng;
    var at: usize = signature.len;
    var header: ?Header = null;
    var compressed: std.ArrayList(u8) = .empty;
    defer compressed.deinit(gpa);
    while (true) {
        const chunk = try nextChunk(bytes, &at);
        if (std.mem.eql(u8, chunk.kind, "IHDR")) {
            header = try Header.parse(chunk.data);
        } else if (std.mem.eql(u8, chunk.kind, "IDAT")) {
            try compressed.appendSlice(gpa, chunk.data);
        } else if (std.mem.eql(u8, chunk.kind, "IEND")) {
            break;
        } else if (chunk.kind[0] & 0x20 == 0) {
            // An upper-case first letter marks a chunk that's needed to read the image.
            if (!std.mem.eql(u8, chunk.kind, "PLTE")) return error.UnsupportedFormat;
        }
    }
    const h = header orelse return error.InvalidHeader;

    const pixel_bytes = h.channels * h.depth.bytes();
    const row_bytes = std.math.mul(usize, h.width, pixel_bytes) catch return error.InvalidHeader;
    const raw_len = std.math.mul(usize, h.height, row_bytes + 1) catch return error.InvalidHeader;
    const raw = try gpa.alloc(u8, raw_len);
    defer gpa.free(raw);
    var input: std.Io.Reader = .fixed(compressed.items);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, &window);
    inflate.reader.readSliceAll(raw) catch return error.BadData;

    var scan: image.Scan = try .init(gpa, h.width, h.height);
    errdefer scan.deinit(gpa);
    var previous: []const u8 = &.{};
    for (0..h.height) |y| {
        const line = raw[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        const row = line[1..];
        try unfilter(@fromBackingInt(@intCast(line[0])), row, previous, pixel_bytes);
        previous = row;
        for (scan.pixels[y * h.width ..][0..h.width], 0..) |*p, x| {
            const pixel = row[x * pixel_bytes ..][0..pixel_bytes];
            var samples: [4]u16 = undefined;
            for (samples[0..h.channels], 0..) |*s, c| s.* = image.sampleAt(pixel, c, h.depth, .big);
            p.* = if (h.channels < 3) @splat(samples[0]) else samples[0..3].*;
        }
    }
    return scan;
}

const Chunk = struct { kind: []const u8, data: []const u8 };

fn nextChunk(bytes: []const u8, at: *usize) Error!Chunk {
    if (bytes.len - at.* < 12) return error.Truncated;
    const len = std.mem.readInt(u32, bytes[at.*..][0..4], .big);
    if (bytes.len - at.* - 12 < len) return error.Truncated;
    const kind_and_data = bytes[at.* + 4 ..][0 .. 4 + len];
    const crc = std.mem.readInt(u32, bytes[at.* + 8 + len ..][0..4], .big);
    if (std.hash.Crc32.hash(kind_and_data) != crc) return error.BadChecksum;
    at.* += 12 + len;
    return .{ .kind = kind_and_data[0..4], .data = kind_and_data[4..] };
}

const Header = struct {
    width: usize,
    height: usize,
    channels: usize,
    depth: image.Depth,

    fn parse(data: []const u8) Error!Header {
        if (data.len != 13) return error.InvalidHeader;
        const width = std.mem.readInt(u32, data[0..4], .big);
        const height = std.mem.readInt(u32, data[4..8], .big);
        const bits = data[8];
        const colour: ColourType = @fromBackingInt(@intCast(data[9]));
        const compression = data[10];
        const filtering = data[11];
        const interlace = data[12];
        if (width == 0 or height == 0 or compression != 0 or filtering != 0) return error.InvalidHeader;
        if (interlace != 0) return error.UnsupportedFormat;
        return .{
            .width = width,
            .height = height,
            .channels = colour.channels() orelse return error.UnsupportedFormat,
            .depth = std.enums.fromInt(image.Depth, bits) orelse return error.UnsupportedFormat,
        };
    }
};

/// Undoes the filter on a scanline, in place. `previous` is the row above, already unfiltered,
/// or empty for the first row. `pixel_bytes` is how many bytes back the pixel to the left is.
fn unfilter(filter: Filter, row: []u8, previous: []const u8, pixel_bytes: usize) Error!void {
    for (row, 0..) |*byte, i| {
        const left: u8 = if (i >= pixel_bytes) row[i - pixel_bytes] else 0;
        const up: u8 = if (previous.len > 0) previous[i] else 0;
        const up_left: u8 = if (previous.len > 0 and i >= pixel_bytes) previous[i - pixel_bytes] else 0;
        byte.* +%= switch (filter) {
            .none => 0,
            .sub => left,
            .up => up,
            .average => @intCast((@as(u16, left) + up) / 2),
            .paeth => paeth(left, up, up_left),
            _ => return error.BadFilter,
        };
    }
}

/// Returns whichever of left, up and up-left is closest to left + up - up-left.
fn paeth(left: u8, up: u8, up_left: u8) u8 {
    const estimate = @as(i16, left) + up - up_left;
    const to_left = @abs(estimate - left);
    const to_up = @abs(estimate - up);
    const to_up_left = @abs(estimate - up_left);
    if (to_left <= to_up and to_left <= to_up_left) return left;
    if (to_up <= to_up_left) return up;
    return up_left;
}

/// Makes a PNG from `rows`, stored without compression. Each row is a filter byte followed by
/// its filtered samples.
fn testPng(gpa: std.mem.Allocator, width: u32, height: u32, depth: u8, colour: ColourType, rows: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8..13].* = .{ depth, @backingInt(colour), 0, 0, 0 };
    try appendChunk(gpa, &out, "IHDR", &ihdr);
    // The zlib stream: a header, one final stored block, and the Adler-32 of the data.
    var zlib: std.ArrayList(u8) = .empty;
    defer zlib.deinit(gpa);
    try zlib.appendSlice(gpa, &.{ 0x78, 0x01, 0x01 });
    var len: [4]u8 = undefined;
    std.mem.writeInt(u16, len[0..2], @intCast(rows.len), .little);
    std.mem.writeInt(u16, len[2..4], ~@as(u16, @intCast(rows.len)), .little);
    try zlib.appendSlice(gpa, &len);
    try zlib.appendSlice(gpa, rows);
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(rows), .big);
    try zlib.appendSlice(gpa, &adler);
    try appendChunk(gpa, &out, "IDAT", zlib.items);
    try appendChunk(gpa, &out, "IEND", "");
    return out.toOwnedSlice(gpa);
}

fn appendChunk(gpa: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try out.appendSlice(gpa, &len);
    const start = out.items.len;
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, data);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, std.hash.Crc32.hash(out.items[start..]), .big);
    try out.appendSlice(gpa, &crc);
}

test "an 8-bit RGB PNG reads with every filter undone" {
    const gpa = std.testing.allocator;
    // 2×3 pixels. Row 0 is plain, row 1 is stored as differences from the left (Sub), and row 2
    // as differences from above (Up).
    const rows = [_]u8{
        0, 10, 20, 30, 40, 50, 60,
        1, 1,  2,  3,  1,  1,  1,
        2, 5,  5,  5,  0,  0,  0,
    };
    const file = try testPng(gpa, 2, 3, 8, .rgb, &rows);
    defer gpa.free(file);
    var scan = try read(gpa, file);
    defer scan.deinit(gpa);
    const w = image.widen_8_to_16;
    try std.testing.expectEqual([3]u16{ 10 * w, 20 * w, 30 * w }, scan.at(0, 0));
    try std.testing.expectEqual([3]u16{ 40 * w, 50 * w, 60 * w }, scan.at(1, 0));
    try std.testing.expectEqual([3]u16{ 1 * w, 2 * w, 3 * w }, scan.at(0, 1));
    try std.testing.expectEqual([3]u16{ 2 * w, 3 * w, 4 * w }, scan.at(1, 1));
    try std.testing.expectEqual([3]u16{ 6 * w, 7 * w, 8 * w }, scan.at(0, 2));
    try std.testing.expectEqual([3]u16{ 2 * w, 3 * w, 4 * w }, scan.at(1, 2));
}

test "Average and Paeth filters, 16-bit grey with alpha" {
    const gpa = std.testing.allocator;
    // 2×2 pixels of 16-bit grey and alpha, so 4 bytes a pixel. Row 0 is plain and row 1 uses
    // Average. Paeth gets its own checks below.
    const rows = [_]u8{
        0, 0x12, 0x34, 0xff, 0xff, 0x56, 0x78, 0xff, 0xff,
        3, 0x09, 0x1a, 0x7f, 0x7f, 0x00, 0x00, 0x00, 0x00,
    };
    const file = try testPng(gpa, 2, 2, 16, .grey_alpha, &rows);
    defer gpa.free(file);
    var scan = try read(gpa, file);
    defer scan.deinit(gpa);
    try std.testing.expectEqual([3]u16{ 0x1234, 0x1234, 0x1234 }, scan.at(0, 0));
    try std.testing.expectEqual([3]u16{ 0x5678, 0x5678, 0x5678 }, scan.at(1, 0));
    // Average of nothing on the left and the row above, so 0x12/2 + 0x09 and 0x34/2 + 0x1a.
    try std.testing.expectEqual([3]u16{ 0x1234, 0x1234, 0x1234 }, scan.at(0, 1));
    // Paeth picks whichever of left, up and up-left is closest to left + up - up-left.
    try std.testing.expectEqual(@as(u8, 5), paeth(5, 9, 9));
    try std.testing.expectEqual(@as(u8, 5), paeth(9, 5, 9));
    try std.testing.expectEqual(@as(u8, 15), paeth(10, 20, 15));
}

test "what isn't a PNG it reads is refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotAPng, read(gpa, "P6 1 1 255 abc"));
    const rows = [_]u8{ 0, 1, 2, 3 };
    const file = try testPng(gpa, 1, 1, 8, .rgb, &rows);
    defer gpa.free(file);
    // Changing one byte breaks the chunk's checksum.
    file[signature.len + 8] ^= 1;
    try std.testing.expectError(error.BadChecksum, read(gpa, file));
    file[signature.len + 8] ^= 1;
    try std.testing.expectError(error.Truncated, read(gpa, file[0 .. file.len - 4]));
    const palette = try testPng(gpa, 1, 1, 8, @fromBackingInt(@intCast(3)), &rows);
    defer gpa.free(palette);
    try std.testing.expectError(error.UnsupportedFormat, read(gpa, palette));
}
