//! Binary PNM files, the format SANE's scanimage writes. We read colour (PPM) and greyscale
//! (PGM) files at 8 or 16 bits, and write colour files at 8 or 16 bits.

const std = @import("std");
const image = @import("../core/image.zig");

/// The magic numbers of a binary PPM and a binary PGM.
const magic = "P6";
const grey_magic = "P5";

pub const Error = error{ NotAPpm, UnsupportedDepth, Truncated, InvalidHeader };

/// Bits per sample in the file.
/// A PNM file after reading it into a scan.
pub const Decoded = struct {
    /// The pixels. 8-bit samples are scaled up to 16 bits, and a greyscale file gets its value
    /// copied into all three channels.
    scan: image.Scan,
    depth: image.Depth,
};

/// Reads a colour or greyscale PNM into a scan; see `decode`.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!image.Scan {
    return (try decode(gpa, bytes)).scan;
}

/// Reads a colour or greyscale PNM into a scan, and says what depth the file had.
pub fn decode(gpa: std.mem.Allocator, bytes: []const u8) (Error || std.mem.Allocator.Error)!Decoded {
    var reader: Header = .{ .bytes = bytes };
    const kind = try reader.field();
    const channels: usize = if (std.mem.eql(u8, kind, magic))
        image.channel_count
    else if (std.mem.eql(u8, kind, grey_magic))
        1
    else
        return error.NotAPpm;
    const width = std.fmt.parseInt(usize, try reader.field(), 10) catch return error.InvalidHeader;
    const height = std.fmt.parseInt(usize, try reader.field(), 10) catch return error.InvalidHeader;
    const max_value = std.fmt.parseInt(u16, try reader.field(), 10) catch return error.InvalidHeader;
    if (width == 0 or height == 0) return error.InvalidHeader;
    // The header ends with a single whitespace character, and the samples start right after it.
    if (reader.position >= bytes.len) return error.Truncated;
    const data = bytes[reader.position + 1 ..];

    const depth: image.Depth = switch (max_value) {
        std.math.maxInt(u8) => .eight,
        std.math.maxInt(u16) => .sixteen,
        else => return error.UnsupportedDepth,
    };
    const pixels = std.math.mul(usize, width, height) catch return error.InvalidHeader;
    const needed = std.math.mul(usize, pixels, channels * depth.bytes()) catch return error.InvalidHeader;
    if (data.len < needed) return error.Truncated;

    const scan: image.Scan = try .init(gpa, width, height);
    for (scan.pixels, 0..) |*p, i| {
        for (p, 0..) |*c, channel| c.* = image.sampleAt(data, i * channels + @min(channel, channels - 1), depth, .big);
    }
    return .{ .scan = scan, .depth = depth };
}

const Header = struct {
    bytes: []const u8,
    position: usize = 0,

    /// Returns the next field (fields are separated by whitespace), skipping comments.
    fn field(header: *Header) Error![]const u8 {
        const b = header.bytes;
        while (header.position < b.len) {
            if (std.ascii.isWhitespace(b[header.position])) {
                header.position += 1;
            } else if (b[header.position] == '#') {
                while (header.position < b.len and b[header.position] != '\n') header.position += 1;
            } else break;
        }
        const start = header.position;
        while (header.position < b.len and !std.ascii.isWhitespace(b[header.position])) header.position += 1;
        if (start == header.position) return error.Truncated;
        return b[start..header.position];
    }
};

/// Writes an encoded image as a binary PPM, with 8 or 16 bits per sample.
pub fn write(gpa: std.mem.Allocator, comptime Sample: type, encoded: image.Image([image.channel_count]Sample)) ![]u8 {
    const header = try std.fmt.allocPrint(gpa, "{s}\n{d} {d}\n{d}\n", .{ magic, encoded.width, encoded.height, std.math.maxInt(Sample) });
    defer gpa.free(header);
    const out = try gpa.alloc(u8, header.len + encoded.pixels.len * image.channel_count * @sizeOf(Sample));
    @memcpy(out[0..header.len], header);
    var at = header.len;
    for (encoded.pixels) |p| {
        for (p) |c| {
            std.mem.writeInt(Sample, out[at..][0..@sizeOf(Sample)], c, .big);
            at += @sizeOf(Sample);
        }
    }
    return out;
}

test "16-bit round trip, with a comment in the header" {
    const gpa = std.testing.allocator;
    const bytes = "P6\n# SANE data follows\n2 1\n65535\n" ++ [_]u8{ 0, 1, 0, 2, 0, 3, 0xff, 0xff, 0, 0, 1, 0 };
    var scan = try read(gpa, bytes);
    defer scan.deinit(gpa);
    try std.testing.expectEqual([3]u16{ 1, 2, 3 }, scan.at(0, 0));
    try std.testing.expectEqual([3]u16{ 65535, 0, 256 }, scan.at(1, 0));
    const written = try write(gpa, u16, scan);
    defer gpa.free(written);
    var again = try read(gpa, written);
    defer again.deinit(gpa);
    try std.testing.expectEqualSlices([3]u16, scan.pixels, again.pixels);
}

test "8-bit samples scale to 16 bits" {
    const gpa = std.testing.allocator;
    var decoded = try decode(gpa, "P6 1 1 255\n" ++ [_]u8{ 0, 128, 255 });
    defer decoded.scan.deinit(gpa);
    try std.testing.expectEqual(image.Depth.eight, decoded.depth);
    try std.testing.expectEqual([3]u16{ 0, 128 * image.widen_8_to_16, image.full_scale }, decoded.scan.at(0, 0));
}

test "a greyscale PGM has its value in every channel" {
    const gpa = std.testing.allocator;
    var decoded = try decode(gpa, "P5 2 1 65535\n" ++ [_]u8{ 0x12, 0x34, 0xff, 0xff });
    defer decoded.scan.deinit(gpa);
    try std.testing.expectEqual(image.Depth.sixteen, decoded.depth);
    try std.testing.expectEqual([3]u16{ 0x1234, 0x1234, 0x1234 }, decoded.scan.at(0, 0));
    try std.testing.expectEqual([3]u16{ 65535, 65535, 65535 }, decoded.scan.at(1, 0));
}

test "headers that lie are refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.Truncated, read(gpa, "P6 1 1 255"));
    try std.testing.expectError(error.InvalidHeader, read(gpa, "P6 9223372036854775808 2 255\n"));
    try std.testing.expectError(error.InvalidHeader, read(gpa, "P6 0 5 255\n"));
    try std.testing.expectError(error.Truncated, read(gpa, "P6 2 2 255\n\x00\x00\x00"));
}
