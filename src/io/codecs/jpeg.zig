//! JPEG output through libjpeg-turbo: 8-bit RGB at a chosen quality, with an ICC profile when
//! given, and JPEG input, which checks what was written. Both work on files in memory. libjpeg
//! runs inside negscan's C shim (`deps/codecs/jpeg_shim.c`), which turns its fatal errors into
//! results.

const std = @import("std");
const c = @import("codecs");
const image = @import("../../core/image.zig");

const log = std.log.scoped(.jpeg);

/// libjpeg's quality scale.
pub const min_quality = 1;
pub const max_quality = 100;
pub const Quality = std.math.IntFittingRange(min_quality, max_quality);

/// How finely the colour is stored against the luminance.
pub const Subsampling = enum {
    /// Colour at half the resolution both ways: smaller files, the usual choice.
    @"4:2:0",
    /// Colour at full resolution: for fine coloured detail.
    @"4:4:4",
};

pub const WriteOptions = struct {
    quality: Quality = 90,
    subsampling: Subsampling = .@"4:2:0",
    /// An ICC profile to embed, such as `icc.profileBytes` gives.
    icc_profile: ?[]const u8 = null,
};

pub const WriteError = error{
    OutOfMemory,
    /// libjpeg refused the image; the debug log says why.
    JpegWriteFailed,
    /// The image is wider or taller than a JPEG can hold.
    ImageTooLarge,
};

/// Writes `encoded`, 8-bit RGB, as a JPEG file. The caller owns the bytes.
pub fn write(gpa: std.mem.Allocator, encoded: image.Encoded8, options: WriteOptions) WriteError![]u8 {
    std.debug.assert(min_quality <= options.quality and options.quality <= max_quality);
    const icc_profile_size: c_uint = if (options.icc_profile) |profile|
        std.math.cast(c_uint, profile.len) orelse return error.JpegWriteFailed
    else
        0;
    const compression: c.negscan_jpeg_compression = .{
        .pixels = std.mem.sliceAsBytes(encoded.pixels).ptr,
        .width = std.math.cast(c_uint, encoded.width) orelse return error.ImageTooLarge,
        .height = std.math.cast(c_uint, encoded.height) orelse return error.ImageTooLarge,
        .row_bytes = encoded.width * @sizeOf([image.channel_count]u8),
        .quality = options.quality,
        .subsample_chroma = @intFromBool(options.subsampling == .@"4:2:0"),
        .icc_profile = if (options.icc_profile) |profile| profile.ptr else null,
        .icc_profile_size = icc_profile_size,
    };
    var file: [*c]u8 = null;
    var file_size: c_ulong = 0;
    var message: [c.NEGSCAN_JPEG_MESSAGE_LENGTH]u8 = undefined;
    try check(c.negscan_jpeg_compress(&compression, &file, &file_size, &message), &message, error.JpegWriteFailed);
    defer c.negscan_jpeg_free(file);
    return gpa.dupe(u8, file[0..file_size]);
}

/// A JPEG read back as 8-bit RGB.
pub const Decoded = struct {
    image: image.Encoded8,
    /// The file's embedded ICC profile, if it has one.
    icc_profile: ?[]u8,

    pub fn deinit(decoded: *Decoded, gpa: std.mem.Allocator) void {
        decoded.image.deinit(gpa);
        if (decoded.icc_profile) |profile| gpa.free(profile);
        decoded.* = undefined;
    }
};

pub const ReadError = error{
    OutOfMemory,
    /// libjpeg could not decode the file; the debug log says why.
    InvalidJpeg,
};

/// Reads the JPEG file `bytes` as 8-bit RGB.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) ReadError!Decoded {
    var decompressed: c.negscan_jpeg_image = .{};
    var message: [c.NEGSCAN_JPEG_MESSAGE_LENGTH]u8 = undefined;
    const size = std.math.cast(c_ulong, bytes.len) orelse return error.InvalidJpeg;
    try check(c.negscan_jpeg_decompress(bytes.ptr, size, &decompressed, &message), &message, error.InvalidJpeg);
    defer c.negscan_jpeg_free(decompressed.pixels);
    defer c.negscan_jpeg_free(decompressed.icc_profile);

    var decoded: image.Encoded8 = try .init(gpa, decompressed.width, decompressed.height);
    errdefer decoded.deinit(gpa);
    const pixel_bytes = std.mem.sliceAsBytes(decoded.pixels);
    @memcpy(pixel_bytes, decompressed.pixels[0..pixel_bytes.len]);
    const icc_profile: ?[]u8 = if (decompressed.icc_profile != null)
        try gpa.dupe(u8, decompressed.icc_profile[0..decompressed.icc_profile_size])
    else
        null;
    return .{ .image = decoded, .icc_profile = icc_profile };
}

/// The shim's results, by name.
const Result = enum(c.negscan_jpeg_result) {
    ok = c.NEGSCAN_JPEG_OK,
    failed = c.NEGSCAN_JPEG_FAILED,
    out_of_memory = c.NEGSCAN_JPEG_OUT_OF_MEMORY,
};

/// Turns the shim's `result` into `failure` or out of memory, logging libjpeg's `message`.
fn check(result: c.negscan_jpeg_result, message: *const [c.NEGSCAN_JPEG_MESSAGE_LENGTH]u8, comptime failure: anytype) !void {
    switch (std.enums.fromInt(Result, result) orelse .failed) {
        .ok => {},
        .out_of_memory => return error.OutOfMemory,
        .failed => {
            log.debug("libjpeg: {s}", .{std.mem.sliceTo(message, 0)});
            return failure;
        },
    }
}

/// A smooth test image, which JPEG keeps close.
fn testImage(gpa: std.mem.Allocator, width: usize, height: usize) !image.Encoded8 {
    const result: image.Encoded8 = try .init(gpa, width, height);
    for (0..height) |y| {
        for (result.row(y), 0..) |*pixel, x| {
            pixel.* = .{
                @intCast(x * std.math.maxInt(u8) / width),
                @intCast(y * std.math.maxInt(u8) / height),
                @intCast((x + y) * std.math.maxInt(u8) / (width + height)),
            };
        }
    }
    return result;
}

test "a JPEG decodes to what was written, with its ICC profile" {
    const gpa = std.testing.allocator;
    var encoded = try testImage(gpa, 64, 48);
    defer encoded.deinit(gpa);
    const profile = "an ICC profile travels in APP2 markers, whatever its bytes";
    const file = try write(gpa, encoded, .{ .quality = 95, .subsampling = .@"4:4:4", .icc_profile = profile });
    defer gpa.free(file);
    // A JPEG file starts with the start-of-image marker.
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, 0xD8 }, file[0..2]);

    var decoded = try read(gpa, file);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(encoded.width, decoded.image.width);
    try std.testing.expectEqual(encoded.height, decoded.image.height);
    try std.testing.expectEqualStrings(profile, decoded.icc_profile.?);
    // At quality 95 without subsampling, a smooth image comes back within a few levels.
    const tolerance = 6;
    for (encoded.pixels, decoded.image.pixels) |written, read_back| {
        for (written, read_back) |w, r| try std.testing.expect(@abs(@as(i16, w) - @as(i16, r)) <= tolerance);
    }
}

test "lower quality makes a smaller file, without a profile by default" {
    const gpa = std.testing.allocator;
    var encoded = try testImage(gpa, 96, 64);
    defer encoded.deinit(gpa);
    const best = try write(gpa, encoded, .{ .quality = max_quality });
    defer gpa.free(best);
    const small = try write(gpa, encoded, .{ .quality = 20 });
    defer gpa.free(small);
    try std.testing.expect(small.len < best.len);

    var decoded = try read(gpa, small);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(null, decoded.icc_profile);
}

test "what is not a JPEG is refused" {
    try std.testing.expectError(error.InvalidJpeg, read(std.testing.allocator, "GIF89a, not a JPEG"));
}
