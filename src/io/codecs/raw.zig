//! Camera raw input through LibRaw, for film scanned with a camera. The scan holds the sensor's
//! own numbers after demosaicing: linear (gamma 1/1) and unscaled, with the black level taken off,
//! no white balance (unity multipliers), no brightening, and in the camera's own colour with no
//! matrix applied (LibRaw's `output_color = 0`). The camera's colour matrix and white balance come
//! along with it, for positives.
//! The file is read from memory, so reading it from disk is up to the caller.

const std = @import("std");
const c = @import("codecs");
const image = @import("../../core/image.zig");

const log = std.log.scoped(.raw);

/// LibRaw's demosaicing methods, with the numbers it uses for `user_qual`. Fuji's X-Trans sensors
/// get LibRaw's X-Trans method whichever one is chosen.
pub const Demosaic = enum(c_int) {
    bilinear = 0,
    vng = 1,
    ppg = 2,
    ahd = 3,
    dcb = 4,
    dht = 11,
    aahd = 12,
};

pub const Options = struct {
    demosaic: Demosaic = .ahd,
    /// Takes each 2-by-2 block of the sensor as one pixel, without demosaicing. That gives half
    /// the width and height, quickly, for previews.
    half_size: bool = false,
};

/// A camera raw file after reading it into a scan.
pub const Decoded = struct {
    /// The pixels in the camera's colour, from 0 for black up to `white`.
    scan: image.Scan,
    /// The level the sensor saturates at, minus the black level. That's the scan's full scale,
    /// because the raw numbers aren't scaled to 16 bits.
    white: u16,
    /// The camera's matrix from its own (white balanced) colour to linear sRGB. Each row makes one
    /// sRGB channel from the camera's red, green and blue, and each row adds up to 1.
    camera_to_srgb: [image.channel_count][image.channel_count]f32,
    /// The multipliers that white balance the camera's colour for daylight, with green at 1.
    /// `camera_to_srgb` expects these to have been applied. Null when LibRaw has no colour data
    /// for the camera.
    daylight_multipliers: ?[image.channel_count]f32,
    /// The multipliers the camera recorded for the light it was shot in, with green at 1. For
    /// film, that's the light behind it. Null when the file doesn't have any.
    as_shot_multipliers: ?[image.channel_count]f32,

    pub fn deinit(decoded: *Decoded, gpa: std.mem.Allocator) void {
        decoded.scan.deinit(gpa);
        decoded.* = undefined;
    }
};

pub const ReadError = error{
    OutOfMemory,
    /// LibRaw doesn't know the file, or its pixels aren't RGB or monochrome.
    UnsupportedRaw,
    /// The file is cut short or damaged.
    CorruptRaw,
    /// The image is larger than LibRaw allows.
    RawTooLarge,
    /// LibRaw failed in some other way. The debug log says why.
    RawFailed,
};

/// LibRaw's result codes, with names for the errors we tell apart.
const Status = enum(c_int) {
    success = c.LIBRAW_SUCCESS,
    file_unsupported = c.LIBRAW_FILE_UNSUPPORTED,
    out_of_memory = c.LIBRAW_UNSUFFICIENT_MEMORY,
    data_error = c.LIBRAW_DATA_ERROR,
    io_error = c.LIBRAW_IO_ERROR,
    too_big = c.LIBRAW_TOO_BIG,
    _,
};

/// LibRaw's `output_color` for the camera's own colour.
const raw_colour = 0;
/// The bits per sample we ask for.
const output_bits = 16;
/// The gamma curve we ask for (LibRaw's `gamm`): power 1 and slope 1, which is linear.
const linear_power = 1.0;
const linear_slope = 1.0;
/// The white balance multiplier we ask for, for each of red, green, blue and the second green.
const unity_multiplier = 1.0;

/// Reads the camera raw file `bytes`.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8, options: Options) ReadError!Decoded {
    const handle: ?*c.libraw_data_t = c.libraw_init(0);
    const processor = handle orelse return error.OutOfMemory;
    defer c.libraw_close(processor);
    // Without a handler, LibRaw reports damaged data on stderr. It keeps decoding either way.
    c.libraw_set_dataerror_handler(processor, null, null);

    const params = &processor.params;
    params.output_color = raw_colour;
    params.user_mul = @splat(unity_multiplier);
    params.use_camera_wb = 0;
    params.use_auto_wb = 0;
    params.no_auto_scale = 1;
    params.gamm[0] = linear_power;
    params.gamm[1] = linear_slope;
    params.no_auto_bright = 1;
    params.output_bps = output_bits;
    params.user_qual = @backingInt(options.demosaic);
    params.half_size = @intFromBool(options.half_size);

    try check(c.libraw_open_buffer(processor, bytes.ptr, bytes.len));
    try check(c.libraw_unpack(processor));
    try check(c.libraw_dcraw_process(processor));
    var status: c_int = c.LIBRAW_SUCCESS;
    const processed_handle: ?*c.libraw_processed_image_t = c.libraw_dcraw_make_mem_image(processor, &status);
    const processed = processed_handle orelse {
        try check(status);
        return error.RawFailed;
    };
    defer c.libraw_dcraw_clear_mem(processed);

    if (processed.type != c.LIBRAW_IMAGE_BITMAP or processed.bits != output_bits) return error.UnsupportedRaw;
    const colours: usize = processed.colors;
    if (colours != image.channel_count and colours != 1) return error.UnsupportedRaw;
    const width: usize = processed.width;
    const height: usize = processed.height;
    if (processed.data_size < width * height * colours * @sizeOf(u16)) return error.CorruptRaw;
    // The samples come right after the header, 16 bits each, in the host's byte order.
    const samples: [*]align(1) const u16 = @ptrCast(&processed.data);

    var scan: image.Scan = try .init(gpa, width, height);
    errdefer scan.deinit(gpa);
    if (colours == 1) {
        for (scan.pixels, samples) |*pixel, sample| pixel.* = @splat(sample);
    } else {
        for (scan.pixels, 0..) |*pixel, i| pixel.* = samples[i * image.channel_count ..][0..image.channel_count].*;
    }

    const colour = &processor.color;
    var camera_to_srgb: [image.channel_count][image.channel_count]f32 = undefined;
    for (&camera_to_srgb, colour.rgb_cam) |*row, source| row.* = source[0..image.channel_count].*;
    return .{
        .scan = scan,
        .white = std.math.cast(u16, colour.maximum) orelse std.math.maxInt(u16),
        .camera_to_srgb = camera_to_srgb,
        .daylight_multipliers = relativeToGreen(colour.pre_mul),
        .as_shot_multipliers = relativeToGreen(colour.cam_mul),
    };
}

/// Turns LibRaw's multipliers for red, green, blue and the second green into red, green and blue,
/// with green at 1. Returns null when LibRaw doesn't have them (it leaves them at 0).
fn relativeToGreen(multipliers: [4]f32) ?[image.channel_count]f32 {
    const green = multipliers[1];
    if (!(green > 0) or !(multipliers[0] > 0) or !(multipliers[2] > 0)) return null;
    const result: [image.channel_count]f32 = .{ multipliers[0] / green, 1.0, multipliers[2] / green };
    for (result) |m| if (!std.math.isFinite(m)) return null;
    return result;
}

test "multipliers come relative to green, and missing ones are none" {
    try std.testing.expectEqual([image.channel_count]f32{ 2, 1, 1.5 }, relativeToGreen(.{ 1024, 512, 768, 512 }).?);
    try std.testing.expectEqual(null, relativeToGreen(.{ 0, 0, 0, 0 }));
    try std.testing.expectEqual(null, relativeToGreen(.{ 2, 1, 0, 1 }));
}

/// Turns LibRaw's `code` into an error, and logs LibRaw's description of it.
fn check(code: c_int) ReadError!void {
    const status: Status = @fromBackingInt(code);
    if (status == .success) return;
    log.debug("LibRaw: {s}", .{c.libraw_strerror(code)});
    return switch (status) {
        .success => unreachable,
        .file_unsupported => error.UnsupportedRaw,
        .out_of_memory => error.OutOfMemory,
        .data_error, .io_error => error.CorruptRaw,
        .too_big => error.RawTooLarge,
        _ => error.RawFailed,
    };
}

test "what is not a camera raw file is refused" {
    // Long enough for LibRaw to look for every format's header. With a shorter one it runs out of
    // data first.
    const not_raw: [4096]u8 = @splat('x');
    try std.testing.expectError(error.UnsupportedRaw, read(std.testing.allocator, &not_raw, .{}));
}

/// The environment variable that names a camera raw file for the test below. The test is skipped
/// without it. `zig build test -Draw-sample=<file>` in `deps/codecs` sets it.
pub const sample_variable = "MINILAB_RAW_SAMPLE";
/// The largest sample file we read.
const max_sample_bytes = 1 << 30;

test "a camera raw file reads as a linear scan with its colour matrix" {
    const gpa = std.testing.allocator;
    const path = std.testing.environ.getAlloc(gpa, sample_variable) catch |err| switch (err) {
        error.EnvironmentVariableMissing => return error.SkipZigTest,
        else => return err,
    };
    defer gpa.free(path);
    const file = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(max_sample_bytes));
    defer gpa.free(file);

    var full = try read(gpa, file, .{});
    defer full.deinit(gpa);
    try std.testing.expect(full.scan.width > 0 and full.scan.height > 0);
    try std.testing.expect(full.white > 0);
    const tolerance = 1e-3;
    for (full.camera_to_srgb) |row| try std.testing.expectApproxEqAbs(1.0, row[0] + row[1] + row[2], tolerance);
    // Every camera LibRaw knows has daylight multipliers, and most files record the light they
    // were shot in too.
    try std.testing.expect(full.daylight_multipliers != null);
    if (full.as_shot_multipliers) |m| try std.testing.expectEqual(@as(f32, 1), m[1]);
    // Since nothing is scaled, the brightest samples sit near the white level, not at the 16-bit
    // full scale. Demosaicing may overshoot it a little.
    const overshoot = 2;
    var brightest: u32 = 0;
    for (full.scan.pixels) |pixel| brightest = @max(brightest, pixel[0], pixel[1], pixel[2]);
    try std.testing.expect(brightest > 0 and brightest <= overshoot * @as(u32, full.white));

    var half = try read(gpa, file, .{ .half_size = true });
    defer half.deinit(gpa);
    try std.testing.expectEqual((full.scan.width + 1) / 2, half.scan.width);
    try std.testing.expectEqual((full.scan.height + 1) / 2, half.scan.height);
}
