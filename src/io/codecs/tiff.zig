//! TIFF input and output through LibTIFF. Reading takes the first image in a file and puts it in
//! a `Scan`: 8-bit or 16-bit RGB or greyscale, in strips or tiles, chunky or planar, in any
//! compression LibTIFF decodes. Writing stores 8-bit or 16-bit RGB with Deflate and the horizontal
//! predictor, plus an ICC profile if there is one. Both work on files in memory, so reading and
//! writing the actual files is up to the caller.

const std = @import("std");
const native_endian = @import("builtin").cpu.arch.endian();
const c = @import("codecs");
const image = @import("../../core/image.zig");

/// A TIFF after reading it into a scan.
pub const Decoded = struct {
    /// The pixels. An 8-bit file's samples are widened to 16 bits (255 becomes 65535). No transfer
    /// function is undone, so the scan is only linear if the file was.
    scan: image.Scan,
    /// The file's bits per sample.
    depth: image.Depth,
    /// The file's embedded ICC profile, if it has one.
    icc_profile: ?[]u8,

    pub fn deinit(decoded: *Decoded, gpa: std.mem.Allocator) void {
        decoded.scan.deinit(gpa);
        if (decoded.icc_profile) |profile| gpa.free(profile);
        decoded.* = undefined;
    }
};

pub const ReadError = error{
    OutOfMemory,
    /// LibTIFF found no TIFF image, or one whose tags contradict each other.
    InvalidTiff,
    /// The image isn't 8-bit or 16-bit unsigned RGB or greyscale.
    UnsupportedTiff,
    /// LibTIFF failed to decode a strip or a tile.
    CorruptTiff,
};

pub const WriteError = error{
    OutOfMemory,
    /// LibTIFF refused a tag or failed to encode a strip.
    TiffWriteFailed,
    /// The image is wider or taller than a TIFF can hold.
    ImageTooLarge,
};

pub const WriteOptions = struct {
    /// An ICC profile to embed, like the ones `icc.profileBytes` returns.
    icc_profile: ?[]const u8 = null,
};

/// The photometric interpretations we read, numbered the way TIFF numbers them.
const Photometric = enum(u16) {
    min_is_black = c.PHOTOMETRIC_MINISBLACK,
    rgb = c.PHOTOMETRIC_RGB,
    ycbcr = c.PHOTOMETRIC_YCBCR,
    _,
};

const PlanarConfig = enum(u16) {
    contiguous = c.PLANARCONFIG_CONTIG,
    separate = c.PLANARCONFIG_SEPARATE,
    _,
};

const SampleFormat = enum(u16) {
    unsigned = c.SAMPLEFORMAT_UINT,
    _,
};

const Compression = enum(u16) {
    adobe_deflate = c.COMPRESSION_ADOBE_DEFLATE,
    jpeg = c.COMPRESSION_JPEG,
    _,
};

/// What we write in the software tag.
const software = "minilab";
/// The size we aim for when writing strips, before compression.
const strip_bytes_target = 1 << 20;
/// Above this many bytes of pixels, the file is written as BigTIFF, because we can't count on
/// Deflate to get it under classic TIFF's 4 GiB limit.
const bigtiff_threshold = 1 << 31;
/// The modes we pass to `TIFFClientOpen`: reading without mapping the file into memory, and
/// writing a classic or a BigTIFF file, little-endian.
const read_mode = "rm";
const write_mode = "wl";
const write_mode_big = "w8l";
/// The value that tells LibTIFF a seek failed: `(toff_t)-1`.
const seek_failed = std.math.maxInt(c.toff_t);

/// Reads the first image in the TIFF file `bytes`.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8) ReadError!Decoded {
    var source: Source = .{ .bytes = bytes };
    const tif = open(&source, read_mode, Source) orelse return error.InvalidTiff;
    defer c.TIFFClose(tif);
    const header = try readHeader(tif);

    var scan: image.Scan = try .init(gpa, header.width, header.height);
    errdefer scan.deinit(gpa);
    switch (header.depth) {
        inline else => |known| try readPixels(switch (known) {
            .eight => u8,
            .sixteen => u16,
        }, gpa, tif, header.layout, &scan),
    }
    return .{ .scan = scan, .depth = header.depth, .icc_profile = try iccProfile(gpa, tif) };
}

/// What `readHeader` finds out about an image before reading its pixels.
const Header = struct {
    width: u32,
    height: u32,
    depth: image.Depth,
    layout: Layout,
};

/// Reads the image's size, depth and layout, and checks that we can read it.
fn readHeader(tif: *c.TIFF) ReadError!Header {
    var width: u32 = 0;
    var height: u32 = 0;
    var bits: u16 = 0;
    var samples: u16 = 0;
    var photometric_number: u16 = 0;
    var planar_number: u16 = 0;
    var format_number: u16 = 0;
    var compression_number: u16 = 0;
    if (c.TIFFGetField(tif, c.TIFFTAG_IMAGEWIDTH, &width) == 0 or
        c.TIFFGetField(tif, c.TIFFTAG_IMAGELENGTH, &height) == 0 or
        c.TIFFGetField(tif, c.TIFFTAG_PHOTOMETRIC, &photometric_number) == 0 or
        c.TIFFGetFieldDefaulted(tif, c.TIFFTAG_BITSPERSAMPLE, &bits) == 0 or
        c.TIFFGetFieldDefaulted(tif, c.TIFFTAG_SAMPLESPERPIXEL, &samples) == 0 or
        c.TIFFGetFieldDefaulted(tif, c.TIFFTAG_PLANARCONFIG, &planar_number) == 0 or
        c.TIFFGetFieldDefaulted(tif, c.TIFFTAG_SAMPLEFORMAT, &format_number) == 0 or
        c.TIFFGetFieldDefaulted(tif, c.TIFFTAG_COMPRESSION, &compression_number) == 0)
        return error.InvalidTiff;
    if (width == 0 or height == 0) return error.InvalidTiff;

    const depth = std.enums.fromInt(image.Depth, bits) orelse return error.UnsupportedTiff;
    const sample_format: SampleFormat = @fromBackingInt(format_number);
    if (sample_format != .unsigned) return error.UnsupportedTiff;
    const planar_config: PlanarConfig = @fromBackingInt(planar_number);
    const planar = switch (planar_config) {
        .contiguous => false,
        .separate => true,
        _ => return error.InvalidTiff,
    };
    const photometric: Photometric = @fromBackingInt(photometric_number);
    const colour: Colour = switch (photometric) {
        .rgb => .rgb,
        .min_is_black => .grey,
        // LibTIFF converts JPEG's YCbCr to RGB when asked.
        .ycbcr => if (@as(Compression, @fromBackingInt(compression_number)) == .jpeg and
            c.TIFFSetField(tif, c.TIFFTAG_JPEGCOLORMODE, @as(c_int, c.JPEGCOLORMODE_RGB)) != 0)
            .rgb
        else
            return error.UnsupportedTiff,
        _ => return error.UnsupportedTiff,
    };
    if (samples < colour.channels()) return error.InvalidTiff;

    const tiled = c.TIFFIsTiled(tif) != 0;
    var block_width: u32 = width;
    var block_height: u32 = 0;
    if (tiled) {
        if (c.TIFFGetField(tif, c.TIFFTAG_TILEWIDTH, &block_width) == 0 or
            c.TIFFGetField(tif, c.TIFFTAG_TILELENGTH, &block_height) == 0) return error.InvalidTiff;
    } else if (c.TIFFGetFieldDefaulted(tif, c.TIFFTAG_ROWSPERSTRIP, &block_height) == 0) return error.InvalidTiff;
    if (block_width == 0 or block_height == 0) return error.InvalidTiff;
    return .{ .width = width, .height = height, .depth = depth, .layout = .{
        .colour = colour,
        .planar = planar,
        .samples_per_pixel = if (planar) 1 else samples,
        .tiled = tiled,
        .block_width = block_width,
        .block_height = @min(block_height, height),
    } };
}

/// The image's ICC profile, a copy the caller owns, or null when it has none.
fn iccProfile(gpa: std.mem.Allocator, tif: *c.TIFF) error{OutOfMemory}!?[]u8 {
    var profile_size: u32 = 0;
    var profile_data: ?*anyopaque = null;
    if (c.TIFFGetField(tif, c.TIFFTAG_ICCPROFILE, &profile_size, &profile_data) == 0 or profile_size == 0) return null;
    const data: [*]const u8 = @ptrCast(profile_data orelse return null);
    return try gpa.dupe(u8, data[0..profile_size]);
}

/// The colour types we read.
const Colour = enum {
    rgb,
    grey,

    /// How many samples a pixel needs.
    fn channels(colour: Colour) usize {
        return switch (colour) {
            .rgb => image.channel_count,
            .grey => 1,
        };
    }
};

/// How the samples are laid out in the file's strips or tiles. `readPixels` calls both of them
/// blocks: a strip is just a block as wide as the image.
const Layout = struct {
    colour: Colour,
    planar: bool,
    /// How many samples each pixel has in a block: all of the file's samples when it's chunky, and
    /// one when it's planar.
    samples_per_pixel: usize,
    tiled: bool,
    block_width: u32,
    block_height: u32,
};

/// Decodes every block and copies its pixels into `scan`, reading `Sample`s of 8 or 16 bits.
/// Planar files are read plane by plane, and planes beyond the colour ones (such as alpha) are
/// skipped.
fn readPixels(comptime Sample: type, gpa: std.mem.Allocator, tif: *c.TIFF, layout: Layout, scan: *image.Scan) ReadError!void {
    const block_bytes = if (layout.tiled) c.TIFFTileSize(tif) else c.TIFFStripSize(tif);
    if (block_bytes <= 0) return error.InvalidTiff;
    const block = try gpa.alloc(u8, @intCast(block_bytes));
    defer gpa.free(block);

    const width: u32 = @intCast(scan.width);
    const height: u32 = @intCast(scan.height);
    const row_samples = layout.block_width * layout.samples_per_pixel;
    const planes: usize = if (layout.planar) layout.colour.channels() else 1;
    for (0..planes) |plane| {
        var y: u32 = 0;
        while (y < height) : (y += layout.block_height) {
            var x: u32 = 0;
            while (x < width) : (x += layout.block_width) {
                const decoded = if (layout.tiled)
                    c.TIFFReadEncodedTile(tif, c.TIFFComputeTile(tif, x, y, 0, @intCast(plane)), block.ptr, block_bytes)
                else
                    c.TIFFReadEncodedStrip(tif, c.TIFFComputeStrip(tif, y, @intCast(plane)), block.ptr, block_bytes);
                const rows = @min(layout.block_height, height - y);
                const columns = @min(layout.block_width, width - x);
                const needed = ((rows - 1) * row_samples + columns * layout.samples_per_pixel) * @sizeOf(Sample);
                if (decoded < 0 or @as(usize, @intCast(decoded)) < needed) return error.CorruptTiff;

                for (0..rows) |r| {
                    const source = block[r * row_samples * @sizeOf(Sample) ..];
                    const target = scan.row(y + r)[x..][0..columns];
                    switch (layout.colour) {
                        .rgb => if (layout.planar) {
                            for (target, 0..) |*pixel, column| pixel[plane] = sampleAt(Sample, source, column);
                        } else {
                            for (target, 0..) |*pixel, column| {
                                for (pixel, 0..) |*channel, index| channel.* = sampleAt(Sample, source, column * layout.samples_per_pixel + index);
                            }
                        },
                        .grey => for (target, 0..) |*pixel, column| {
                            pixel.* = @splat(sampleAt(Sample, source, column * layout.samples_per_pixel));
                        },
                    }
                }
            }
        }
    }
}

/// LibTIFF's read callback, for files held in memory: copies up to `size` bytes of `bytes` from
/// `position` into `buffer`, and moves `position` on.
fn copyOut(bytes: []const u8, position: *u64, buffer: ?*anyopaque, size: c.tmsize_t) c.tmsize_t {
    if (size < 0) return -1;
    const start: usize = @intCast(@min(position.*, bytes.len));
    const count = @min(@as(usize, @intCast(size)), bytes.len - start);
    const target: [*]u8 = @ptrCast(buffer orelse return -1);
    @memcpy(target[0..count], bytes[start..][0..count]);
    position.* = start + count;
    return @intCast(count);
}

/// Returns sample number `index` in `bytes`, as 16 bits. LibTIFF has already put the samples in
/// the host's byte order.
fn sampleAt(comptime Sample: type, bytes: []const u8, index: usize) u16 {
    return image.sampleAt(bytes, index, depthOf(Sample), native_endian);
}

/// The depth of samples of type `Sample`.
fn depthOf(comptime Sample: type) image.Depth {
    return switch (Sample) {
        u8 => .eight,
        u16 => .sixteen,
        else => @compileError("TIFF samples are 8 or 16 bits"),
    };
}

/// Writes `encoded` (RGB, with 8-bit or 16-bit `Sample`s) as a TIFF file with Deflate. The caller
/// owns the bytes.
pub fn write(gpa: std.mem.Allocator, comptime Sample: type, encoded: image.Image([image.channel_count]Sample), options: WriteOptions) WriteError![]u8 {
    const depth = depthOf(Sample);
    const width = std.math.cast(u32, encoded.width) orelse return error.ImageTooLarge;
    const height = std.math.cast(u32, encoded.height) orelse return error.ImageTooLarge;
    const row_bytes = encoded.width * @sizeOf([image.channel_count]Sample);
    const pixel_bytes = std.mem.sliceAsBytes(encoded.pixels);

    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    const mode = if (pixel_bytes.len > bigtiff_threshold) write_mode_big else write_mode;
    const tif = open(&sink, mode, Sink) orelse return sink.failure();
    var closed = false;
    defer if (!closed) c.TIFFClose(tif);

    const rows_per_strip: u32 = @intCast(std.math.clamp(strip_bytes_target / @max(row_bytes, 1), 1, height));
    if (c.TIFFSetField(tif, c.TIFFTAG_IMAGEWIDTH, width) == 0 or
        c.TIFFSetField(tif, c.TIFFTAG_IMAGELENGTH, height) == 0 or
        c.TIFFSetField(tif, c.TIFFTAG_BITSPERSAMPLE, @as(c_int, @backingInt(depth))) == 0 or
        c.TIFFSetField(tif, c.TIFFTAG_SAMPLESPERPIXEL, @as(c_int, image.channel_count)) == 0 or
        c.TIFFSetField(tif, c.TIFFTAG_PHOTOMETRIC, @as(c_int, @backingInt(Photometric.rgb))) == 0 or
        c.TIFFSetField(tif, c.TIFFTAG_PLANARCONFIG, @as(c_int, @backingInt(PlanarConfig.contiguous))) == 0 or
        c.TIFFSetField(tif, c.TIFFTAG_COMPRESSION, @as(c_int, @backingInt(Compression.adobe_deflate))) == 0 or
        c.TIFFSetField(tif, c.TIFFTAG_PREDICTOR, @as(c_int, c.PREDICTOR_HORIZONTAL)) == 0 or
        c.TIFFSetField(tif, c.TIFFTAG_ROWSPERSTRIP, rows_per_strip) == 0 or
        c.TIFFSetField(tif, c.TIFFTAG_SOFTWARE, software.ptr) == 0)
        return sink.failure();
    if (options.icc_profile) |profile| {
        const size = std.math.cast(u32, profile.len) orelse return error.TiffWriteFailed;
        if (c.TIFFSetField(tif, c.TIFFTAG_ICCPROFILE, size, profile.ptr) == 0) return sink.failure();
    }

    // LibTIFF may change the data it encodes, so each strip is copied first.
    const strip = try gpa.alloc(u8, rows_per_strip * row_bytes);
    defer gpa.free(strip);
    var y: u32 = 0;
    var index: u32 = 0;
    while (y < height) : ({
        y += rows_per_strip;
        index += 1;
    }) {
        const rows = @min(rows_per_strip, height - y);
        const data = strip[0 .. rows * row_bytes];
        @memcpy(data, pixel_bytes[y * row_bytes ..][0..data.len]);
        if (c.TIFFWriteEncodedStrip(tif, index, data.ptr, @intCast(data.len)) < 0) return sink.failure();
    }
    if (c.TIFFWriteDirectory(tif) == 0) return sink.failure();
    closed = true;
    c.TIFFClose(tif);
    if (sink.out_of_memory) return error.OutOfMemory;
    return sink.bytes.toOwnedSlice(gpa);
}

/// Opens a TIFF through `Stream`'s callbacks, keeping LibTIFF's messages quiet. The errors that
/// matter come back as results.
fn open(stream: *anyopaque, mode: [:0]const u8, comptime Stream: type) ?*c.TIFF {
    const options = c.TIFFOpenOptionsAlloc() orelse return null;
    defer c.TIFFOpenOptionsFree(options);
    c.TIFFOpenOptionsSetErrorHandlerExtR(options, ignoreMessage, null);
    c.TIFFOpenOptionsSetWarningHandlerExtR(options, ignoreMessage, null);
    return c.TIFFClientOpenExt(
        "minilab",
        mode.ptr,
        stream,
        Stream.readProc,
        Stream.writeProc,
        Stream.seekProc,
        closeProc,
        Stream.sizeProc,
        mapProc,
        unmapProc,
        options,
    );
}

/// LibTIFF's message handler. Its last parameter is a `va_list`, which has a different type on
/// each target.
const MessageHandler = @typeInfo(@typeInfo(c.TIFFErrorHandlerExtR).optional.child).pointer.child;
const VaList = @typeInfo(MessageHandler).@"fn".param_types[4].?;

fn ignoreMessage(_: ?*c.TIFF, _: ?*anyopaque, _: [*c]const u8, _: [*c]const u8, _: VaList) callconv(.c) c_int {
    return 1;
}

fn closeProc(_: c.thandle_t) callconv(.c) c_int {
    return 0;
}

/// We never map a file. LibTIFF reads through `readProc` instead.
fn mapProc(_: c.thandle_t, _: [*c]?*anyopaque, _: [*c]c.toff_t) callconv(.c) c_int {
    return 0;
}

fn unmapProc(_: c.thandle_t, _: ?*anyopaque, _: c.toff_t) callconv(.c) void {}

/// Works out where a seek lands: `offset` from `whence` (`SEEK_SET`, `SEEK_CUR` or `SEEK_END`), in
/// a file of `size` bytes that's currently at `position`. Returns null if it lands before the
/// start.
fn seekTarget(position: u64, size: u64, offset: c.toff_t, whence: c_int) ?u64 {
    const base: u64 = switch (whence) {
        c.SEEK_SET => return offset,
        c.SEEK_CUR => position,
        c.SEEK_END => size,
        else => return null,
    };
    // LibTIFF passes a backward step as a negative number in an unsigned type.
    const step: i64 = @bitCast(offset);
    return if (step < 0) std.math.sub(u64, base, @abs(step)) catch null else std.math.add(u64, base, @intCast(step)) catch null;
}

/// A TIFF file being read from memory.
const Source = struct {
    bytes: []const u8,
    position: u64 = 0,

    fn from(handle: c.thandle_t) *Source {
        return @ptrCast(@alignCast(handle.?));
    }

    fn readProc(handle: c.thandle_t, buffer: ?*anyopaque, size: c.tmsize_t) callconv(.c) c.tmsize_t {
        const source = from(handle);
        return copyOut(source.bytes, &source.position, buffer, size);
    }

    fn writeProc(_: c.thandle_t, _: ?*anyopaque, _: c.tmsize_t) callconv(.c) c.tmsize_t {
        return -1;
    }

    fn seekProc(handle: c.thandle_t, offset: c.toff_t, whence: c_int) callconv(.c) c.toff_t {
        const source = from(handle);
        source.position = seekTarget(source.position, source.bytes.len, offset, whence) orelse return seek_failed;
        return source.position;
    }

    fn sizeProc(handle: c.thandle_t) callconv(.c) c.toff_t {
        return from(handle).bytes.len;
    }
};

/// A TIFF file being written to memory. LibTIFF seeks back to fill in offsets, so each write goes
/// at the current position, and a write past the end fills the gap with zeros.
const Sink = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    position: u64 = 0,
    out_of_memory: bool = false,

    fn from(handle: c.thandle_t) *Sink {
        return @ptrCast(@alignCast(handle.?));
    }

    /// The error to return when a LibTIFF call failed: out of memory if a write ran out of it, and
    /// otherwise a write failure.
    fn failure(sink: Sink) WriteError {
        return if (sink.out_of_memory) error.OutOfMemory else error.TiffWriteFailed;
    }

    fn readProc(handle: c.thandle_t, buffer: ?*anyopaque, size: c.tmsize_t) callconv(.c) c.tmsize_t {
        const sink = from(handle);
        return copyOut(sink.bytes.items, &sink.position, buffer, size);
    }

    fn writeProc(handle: c.thandle_t, buffer: ?*anyopaque, size: c.tmsize_t) callconv(.c) c.tmsize_t {
        const sink = from(handle);
        if (size < 0) return -1;
        const count: usize = @intCast(size);
        const source: [*]const u8 = @ptrCast(buffer orelse return -1);
        const start: usize = @intCast(sink.position);
        const end = start + count;
        if (end > sink.bytes.items.len) {
            const old_length = sink.bytes.items.len;
            sink.bytes.resize(sink.gpa, end) catch {
                sink.out_of_memory = true;
                return -1;
            };
            if (start > old_length) @memset(sink.bytes.items[old_length..start], 0);
        }
        @memcpy(sink.bytes.items[start..end], source[0..count]);
        sink.position = end;
        return size;
    }

    fn seekProc(handle: c.thandle_t, offset: c.toff_t, whence: c_int) callconv(.c) c.toff_t {
        const sink = from(handle);
        sink.position = seekTarget(sink.position, sink.bytes.items.len, offset, whence) orelse return seek_failed;
        return sink.position;
    }

    fn sizeProc(handle: c.thandle_t) callconv(.c) c.toff_t {
        return from(handle).bytes.items.len;
    }
};

/// A test image of `width` by `height` in which every sample differs from its neighbours.
fn testImage(gpa: std.mem.Allocator, comptime Sample: type, width: usize, height: usize) !image.Image([image.channel_count]Sample) {
    const result: image.Image([image.channel_count]Sample) = try .init(gpa, width, height);
    const step = std.math.maxInt(Sample) / (width * height * image.channel_count);
    for (result.pixels, 0..) |*pixel, i| {
        for (pixel, 0..) |*sample, channel| sample.* = @intCast((i * image.channel_count + channel) * step);
    }
    return result;
}

test "16-bit RGB comes back as written, with its ICC profile" {
    const gpa = std.testing.allocator;
    var encoded = try testImage(gpa, u16, 37, 23);
    defer encoded.deinit(gpa);
    const profile = "not really a profile, but LibTIFF keeps what it is given";
    const file = try write(gpa, u16, encoded, .{ .icc_profile = profile });
    defer gpa.free(file);

    var decoded = try read(gpa, file);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(image.Depth.sixteen, decoded.depth);
    try std.testing.expectEqual(encoded.width, decoded.scan.width);
    try std.testing.expectEqual(encoded.height, decoded.scan.height);
    try std.testing.expectEqualSlices([image.channel_count]u16, encoded.pixels, decoded.scan.pixels);
    try std.testing.expectEqualStrings(profile, decoded.icc_profile.?);
}

test "8-bit RGB comes back widened to 16 bits, without a profile" {
    const gpa = std.testing.allocator;
    var encoded = try testImage(gpa, u8, 5, 9);
    defer encoded.deinit(gpa);
    encoded.pixels[0] = .{ 0, 128, 255 };
    const file = try write(gpa, u8, encoded, .{});
    defer gpa.free(file);

    var decoded = try read(gpa, file);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(image.Depth.eight, decoded.depth);
    try std.testing.expectEqual(null, decoded.icc_profile);
    for (encoded.pixels, decoded.scan.pixels) |written, read_back| {
        for (written, read_back) |w, r| try std.testing.expectEqual(@as(u16, w) * image.widen_8_to_16, r);
    }
    try std.testing.expectEqual([image.channel_count]u16{ 0, 128 * image.widen_8_to_16, image.full_scale }, decoded.scan.pixels[0]);
}

/// How `writeLayout` lays a test file out.
const TestLayout = struct {
    planar: bool,
    tile: ?u32,
    compression: c_int,
    mode: [:0]const u8,
    grey: bool = false,
};

/// Writes 16-bit `encoded` with LibTIFF directly, in a `layout` that `write` doesn't offer, so
/// `read` has something to be tested on. Greyscale uses the red channel.
fn writeLayout(gpa: std.mem.Allocator, encoded: image.Encoded16, layout: TestLayout) ![]u8 {
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    const tif = open(&sink, layout.mode, Sink) orelse return error.TestUnexpectedResult;
    var closed = false;
    defer if (!closed) c.TIFFClose(tif);
    const width: u32 = @intCast(encoded.width);
    const height: u32 = @intCast(encoded.height);
    const channels: u16 = if (layout.grey) 1 else image.channel_count;
    _ = c.TIFFSetField(tif, c.TIFFTAG_IMAGEWIDTH, width);
    _ = c.TIFFSetField(tif, c.TIFFTAG_IMAGELENGTH, height);
    _ = c.TIFFSetField(tif, c.TIFFTAG_BITSPERSAMPLE, @as(c_int, 16));
    _ = c.TIFFSetField(tif, c.TIFFTAG_SAMPLESPERPIXEL, @as(c_int, channels));
    _ = c.TIFFSetField(tif, c.TIFFTAG_PHOTOMETRIC, @as(c_int, if (layout.grey) c.PHOTOMETRIC_MINISBLACK else c.PHOTOMETRIC_RGB));
    _ = c.TIFFSetField(tif, c.TIFFTAG_PLANARCONFIG, @as(c_int, if (layout.planar) c.PLANARCONFIG_SEPARATE else c.PLANARCONFIG_CONTIG));
    _ = c.TIFFSetField(tif, c.TIFFTAG_COMPRESSION, layout.compression);
    const block_width: u32, const block_height: u32 = if (layout.tile) |tile| .{ tile, tile } else .{ width, 3 };
    if (layout.tile) |tile| {
        _ = c.TIFFSetField(tif, c.TIFFTAG_TILEWIDTH, tile);
        _ = c.TIFFSetField(tif, c.TIFFTAG_TILELENGTH, tile);
    } else _ = c.TIFFSetField(tif, c.TIFFTAG_ROWSPERSTRIP, block_height);

    const samples_per_pixel: usize = if (layout.planar) 1 else channels;
    const block = try gpa.alloc(u16, block_width * block_height * samples_per_pixel);
    defer gpa.free(block);
    const planes: u16 = if (layout.planar) channels else 1;
    for (0..planes) |plane| {
        var y: u32 = 0;
        while (y < height) : (y += block_height) {
            var x: u32 = 0;
            while (x < width) : (x += block_width) {
                @memset(block, 0);
                for (0..block_height) |r| {
                    for (0..block_width) |column| {
                        if (y + r >= height or x + column >= width) continue;
                        const pixel = encoded.at(x + column, y + r);
                        const at = (r * block_width + column) * samples_per_pixel;
                        if (layout.planar) block[at] = pixel[plane] else @memcpy(block[at..][0..channels], pixel[0..channels]);
                    }
                }
                const bytes = std.mem.sliceAsBytes(block);
                const written = if (layout.tile != null)
                    c.TIFFWriteEncodedTile(tif, c.TIFFComputeTile(tif, x, y, 0, @intCast(plane)), bytes.ptr, @intCast(bytes.len))
                else
                    c.TIFFWriteEncodedStrip(tif, c.TIFFComputeStrip(tif, y, @intCast(plane)), bytes.ptr, @intCast(@min(block_height, height - y) * block_width * samples_per_pixel * @sizeOf(u16)));
                if (written < 0) return error.TestUnexpectedResult;
            }
        }
    }
    if (c.TIFFWriteDirectory(tif) == 0) return error.TestUnexpectedResult;
    closed = true;
    c.TIFFClose(tif);
    return sink.bytes.toOwnedSlice(gpa);
}

test "planar, tiled, LZW, big-endian 16-bit RGB reads as written" {
    const gpa = std.testing.allocator;
    var encoded = try testImage(gpa, u16, 41, 19);
    defer encoded.deinit(gpa);
    const file = try writeLayout(gpa, encoded, .{ .planar = true, .tile = 16, .compression = c.COMPRESSION_LZW, .mode = "wb" });
    defer gpa.free(file);
    var decoded = try read(gpa, file);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices([image.channel_count]u16, encoded.pixels, decoded.scan.pixels);
}

test "chunky PackBits strips and planar greyscale read as written" {
    const gpa = std.testing.allocator;
    var encoded = try testImage(gpa, u16, 13, 11);
    defer encoded.deinit(gpa);

    const chunky = try writeLayout(gpa, encoded, .{ .planar = false, .tile = null, .compression = c.COMPRESSION_PACKBITS, .mode = "wl" });
    defer gpa.free(chunky);
    var decoded = try read(gpa, chunky);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualSlices([image.channel_count]u16, encoded.pixels, decoded.scan.pixels);

    const grey = try writeLayout(gpa, encoded, .{ .planar = true, .tile = null, .compression = c.COMPRESSION_ADOBE_DEFLATE, .mode = "wl", .grey = true });
    defer gpa.free(grey);
    var decoded_grey = try read(gpa, grey);
    defer decoded_grey.deinit(gpa);
    for (encoded.pixels, decoded_grey.scan.pixels) |written, read_back| try std.testing.expectEqual(@as([image.channel_count]u16, @splat(written[0])), read_back);
}

test "JPEG-compressed YCbCr reads as RGB" {
    const gpa = std.testing.allocator;
    const width = 32;
    // A strip of JPEG with 2-by-2 subsampled colour is a whole number of 16-row blocks.
    const height = 16;
    const colour = [image.channel_count]u8{ 200, 100, 50 };
    const quality = 95;
    var sink: Sink = .{ .gpa = gpa };
    defer sink.bytes.deinit(gpa);
    const tif = open(&sink, write_mode, Sink) orelse return error.TestUnexpectedResult;
    var closed = false;
    defer if (!closed) c.TIFFClose(tif);
    _ = c.TIFFSetField(tif, c.TIFFTAG_IMAGEWIDTH, @as(u32, width));
    _ = c.TIFFSetField(tif, c.TIFFTAG_IMAGELENGTH, @as(u32, height));
    _ = c.TIFFSetField(tif, c.TIFFTAG_BITSPERSAMPLE, @as(c_int, 8));
    _ = c.TIFFSetField(tif, c.TIFFTAG_SAMPLESPERPIXEL, @as(c_int, image.channel_count));
    _ = c.TIFFSetField(tif, c.TIFFTAG_PHOTOMETRIC, @as(c_int, @backingInt(Photometric.ycbcr)));
    _ = c.TIFFSetField(tif, c.TIFFTAG_COMPRESSION, @as(c_int, @backingInt(Compression.jpeg)));
    _ = c.TIFFSetField(tif, c.TIFFTAG_ROWSPERSTRIP, @as(u32, height));
    _ = c.TIFFSetField(tif, c.TIFFTAG_JPEGCOLORMODE, @as(c_int, c.JPEGCOLORMODE_RGB));
    _ = c.TIFFSetField(tif, c.TIFFTAG_JPEGQUALITY, @as(c_int, quality));
    var pixels: [width * height][image.channel_count]u8 = @splat(colour);
    const bytes = std.mem.sliceAsBytes(&pixels);
    if (c.TIFFWriteEncodedStrip(tif, 0, bytes.ptr, @intCast(bytes.len)) < 0) return error.TestUnexpectedResult;
    if (c.TIFFWriteDirectory(tif) == 0) return error.TestUnexpectedResult;
    closed = true;
    c.TIFFClose(tif);

    var decoded = try read(gpa, sink.bytes.items);
    defer decoded.deinit(gpa);
    const tolerance = 3 * image.widen_8_to_16;
    for (decoded.scan.pixels) |pixel| {
        for (colour, pixel) |expected, actual| {
            try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(expected)) * image.widen_8_to_16, @as(f32, @floatFromInt(actual)), tolerance);
        }
    }
}

test "what is not a TIFF is refused" {
    try std.testing.expectError(error.InvalidTiff, read(std.testing.allocator, "P6 1 1 255 abc"));
}
