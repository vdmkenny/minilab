//! Colour profiles through LittleCMS 2. This builds the output spaces minilab offers from their
//! definitions, gives each space's ICC profile as bytes to embed in a TIFF or a JPEG, and makes
//! the transform from linear Rec. 2020 to any of them. (Export converts the developed pixels to
//! linear Rec. 2020 before it uses the transform.) It also builds linear sRGB, the profile a
//! roll's raw scans carry.
//!
//! The profiles are ICC version 2.4 matrix-shaper profiles, which every colour-managed program
//! can read. Where version 2 can't describe a curve with a formula, LittleCMS stores it as a
//! table.

const std = @import("std");
const c = @import("codecs");
const image = @import("../../core/image.zig");
const encode = @import("../../core/encode.zig");

/// The colour spaces minilab writes.
pub const Space = enum {
    srgb,
    display_p3,
    adobe_rgb,
    prophoto,
    rec2020_linear,
    /// What a roll's raw scans say they're in (`roll.encodeRaw`). They hold linear light in the
    /// scanner's own channels, which aren't quite sRGB's, but on a negative it's the brightness
    /// that matters: with this, other apps show it at the right brightness rather than too dark.
    srgb_linear,
};

/// The rendering intents, numbered the way LittleCMS numbers them. Between two matrix-shaper
/// profiles, perceptual and saturation fall back to relative colorimetric.
pub const Intent = enum(u32) {
    perceptual = c.INTENT_PERCEPTUAL,
    relative_colorimetric = c.INTENT_RELATIVE_COLORIMETRIC,
    saturation = c.INTENT_SATURATION,
    absolute_colorimetric = c.INTENT_ABSOLUTE_COLORIMETRIC,
};

pub const Error = error{
    /// LittleCMS failed to build a profile or a transform, which happens when it runs out of
    /// memory.
    ColourManagementFailed,
    OutOfMemory,
};

/// The ICC version the profiles declare.
const icc_version = 2.4;
/// The luminance (Y) we give a primary or the white point in its chromaticity. LittleCMS takes it
/// as 1.
const unit_luminance = 1.0;

/// How a space encodes linear light.
const Transfer = union(enum) {
    linear,
    /// A pure power: encoded ^ gamma = linear.
    gamma: f64,
    /// LittleCMS's parametric curve 4: linear = (a * encoded + b) ^ g above d, c * encoded below.
    /// The parameters are in LittleCMS's order: g, a, b, c, d.
    parametric: [5]f64,
};

/// LittleCMS's number for the parametric curve with a linear toe.
const parametric_with_toe = 4;

/// The sRGB curve from IEC 61966-2-1. Display P3 uses it too.
const srgb_transfer: Transfer = transfer: {
    const k = encode.srgb_curve;
    break :transfer .{ .parametric = .{ k.gamma, 1.0 / k.scale, k.offset / k.scale, 1.0 / k.toe_slope, k.toe_encoded } };
};

/// The white points, in CIE 1931 xy.
const d65: c.cmsCIExyY = .{ .x = 0.3127, .y = 0.3290, .Y = unit_luminance };
const d50: c.cmsCIExyY = .{ .x = 0.3457, .y = 0.3585, .Y = unit_luminance };

/// What defines a space: its description, white point, primaries and transfer function.
const Definition = struct {
    description: [:0]const u8,
    white: c.cmsCIExyY,
    primaries: c.cmsCIExyYTRIPLE,
    transfer: Transfer,
};

fn primaries(red: [2]f64, green: [2]f64, blue: [2]f64) c.cmsCIExyYTRIPLE {
    return .{
        .Red = .{ .x = red[0], .y = red[1], .Y = unit_luminance },
        .Green = .{ .x = green[0], .y = green[1], .Y = unit_luminance },
        .Blue = .{ .x = blue[0], .y = blue[1], .Y = unit_luminance },
    };
}

/// sRGB's primaries, from IEC 61966-2-1, which Rec. 709 shares.
const srgb_primaries = primaries(.{ 0.64, 0.33 }, .{ 0.30, 0.60 }, .{ 0.15, 0.06 });

/// The name the space's profile gives it.
pub fn nameOf(space: Space) [:0]const u8 {
    return definition(space).description;
}

fn definition(space: Space) Definition {
    return switch (space) {
        // IEC 61966-2-1.
        .srgb => .{
            .description = "sRGB",
            .white = d65,
            .primaries = srgb_primaries,
            .transfer = srgb_transfer,
        },
        // DCI-P3's primaries with D65 and the sRGB curve, as Apple defines it.
        .display_p3 => .{
            .description = "Display P3",
            .white = d65,
            .primaries = primaries(.{ 0.680, 0.320 }, .{ 0.265, 0.690 }, .{ 0.150, 0.060 }),
            .transfer = srgb_transfer,
        },
        // Adobe RGB (1998): its primaries and its gamma of 563/256. The name says "compatible"
        // because only Adobe's own profile carries Adobe's name.
        .adobe_rgb => .{
            .description = "Adobe RGB (compatible)",
            .white = d65,
            .primaries = primaries(.{ 0.64, 0.33 }, .{ 0.21, 0.71 }, .{ 0.15, 0.06 }),
            .transfer = .{ .gamma = 563.0 / 256.0 },
        },
        // ROMM RGB, ISO 22028-2: gamma 1.8 with a linear toe below 1/512 of linear light.
        .prophoto => .{
            .description = "ProPhoto RGB",
            .white = d50,
            .primaries = primaries(.{ 0.7347, 0.2653 }, .{ 0.1596, 0.8404 }, .{ 0.0366, 0.0001 }),
            .transfer = .{ .parametric = .{ 1.8, 1.0, 0.0, 1.0 / 16.0, 1.0 / 32.0 } },
        },
        // ITU-R BT.2020's primaries with D65, linear.
        .rec2020_linear => .{
            .description = "Rec. 2020 linear",
            .white = d65,
            .primaries = primaries(.{ 0.708, 0.292 }, .{ 0.170, 0.797 }, .{ 0.131, 0.046 }),
            .transfer = .linear,
        },
        .srgb_linear => .{
            .description = "sRGB linear",
            .white = d65,
            .primaries = srgb_primaries,
            .transfer = .linear,
        },
    };
}

/// A colour profile, opened in LittleCMS.
pub const Profile = struct {
    handle: *anyopaque,

    /// Builds the profile of `space`.
    pub fn init(space: Space) Error!Profile {
        const space_definition = definition(space);
        const curve = switch (space_definition.transfer) {
            .linear => c.cmsBuildGamma(null, 1.0),
            .gamma => |gamma| c.cmsBuildGamma(null, gamma),
            .parametric => |parameters| c.cmsBuildParametricToneCurve(null, parametric_with_toe, &parameters),
        } orelse return error.ColourManagementFailed;
        defer c.cmsFreeToneCurve(curve);
        const curves: [image.channel_count]?*c.cmsToneCurve = @splat(curve);
        const handle = c.cmsCreateRGBProfile(&space_definition.white, &space_definition.primaries, &curves) orelse
            return error.ColourManagementFailed;
        errdefer _ = c.cmsCloseProfile(handle);

        const description = c.cmsMLUalloc(null, 1) orelse return error.ColourManagementFailed;
        defer c.cmsMLUfree(description);
        if (c.cmsMLUsetASCII(description, "en", "US", space_definition.description) == 0) return error.ColourManagementFailed;
        if (c.cmsWriteTag(handle, c.cmsSigProfileDescriptionTag, description) == 0) return error.ColourManagementFailed;
        c.cmsSetProfileVersion(handle, icc_version);
        // LittleCMS builds a v4 profile: D50 as the media white, and the real white in a chromatic
        // adaptation tag. v2 left the media white open, and the v2 profiles in wide use (HP's
        // and Apple's sRGB, Adobe's Adobe RGB) give the real white there, with no adaptation tag,
        // so v2 readers take it that way. The colorants stay adapted to D50 with Bradford, as
        // theirs are. (ICC White Paper 6; Adobe RGB (1998) spec, annex A.)
        var white: c.cmsCIEXYZ = undefined;
        c.cmsxyY2XYZ(&white, &space_definition.white);
        if (c.cmsWriteTag(handle, c.cmsSigMediaWhitePointTag, &white) == 0) return error.ColourManagementFailed;
        if (c.cmsWriteTag(handle, c.cmsSigChromaticAdaptationTag, null) == 0) return error.ColourManagementFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(profile: *Profile) void {
        _ = c.cmsCloseProfile(profile.handle);
        profile.* = undefined;
    }

    /// Returns the profile as an ICC file, ready to embed. The caller owns the bytes.
    pub fn bytes(profile: Profile, gpa: std.mem.Allocator) Error![]u8 {
        var size: c.cmsUInt32Number = 0;
        if (c.cmsSaveProfileToMem(profile.handle, null, &size) == 0) return error.ColourManagementFailed;
        const file = try gpa.alloc(u8, size);
        errdefer gpa.free(file);
        if (c.cmsSaveProfileToMem(profile.handle, file.ptr, &size) == 0) return error.ColourManagementFailed;
        return file;
    }
};

/// Where an ICC profile's header holds when it was made: 12 bytes from byte 24. LittleCMS sets it
/// to the time the profile was made, so two copies of one profile differ there.
const created_at = 24;
const created_len = 12;

/// Whether two profiles are the same apart from when they were made.
pub fn sameProfile(a: []const u8, b: []const u8) bool {
    if (a.len != b.len or a.len < created_at + created_len) return std.mem.eql(u8, a, b);
    return std.mem.eql(u8, a[0..created_at], b[0..created_at]) and
        std.mem.eql(u8, a[created_at + created_len ..], b[created_at + created_len ..]);
}

/// Returns the ICC profile of `space` as bytes, ready to embed in a file. The caller owns them.
pub fn profileBytes(gpa: std.mem.Allocator, space: Space) Error![]u8 {
    var profile: Profile = try .init(space);
    defer profile.deinit();
    return profile.bytes(gpa);
}

/// The most pixels LittleCMS can convert in one call, because it counts them in 32 bits.
const max_pixels_per_call = std.math.maxInt(c.cmsUInt32Number);

/// A transform from linear Rec. 2020 to a space's encoding, writing pixels of `Sample`. With
/// `f32`, 0 to 1 is the space's range and values outside it are kept. `u16` and `u8` clip. It has
/// no cache, so threads can share it.
pub fn Transform(comptime Sample: type) type {
    const output_format: c.cmsUInt32Number = switch (Sample) {
        f32 => c.TYPE_RGB_FLT,
        u16 => c.TYPE_RGB_16,
        u8 => c.TYPE_RGB_8,
        else => @compileError("a transform writes f32, u16 or u8 samples, not " ++ @typeName(Sample)),
    };
    return struct {
        const Self = @This();

        handle: *anyopaque,

        pub fn init(to: Space, intent: Intent) Error!Self {
            var source: Profile = try .init(.rec2020_linear);
            defer source.deinit();
            var destination: Profile = try .init(to);
            defer destination.deinit();
            const handle = c.cmsCreateTransform(
                source.handle,
                c.TYPE_RGB_FLT,
                destination.handle,
                output_format,
                @backingInt(intent),
                c.cmsFLAGS_NOCACHE,
            ) orelse return error.ColourManagementFailed;
            return .{ .handle = handle };
        }

        pub fn deinit(transform: *Self) void {
            c.cmsDeleteTransform(transform.handle);
            transform.* = undefined;
        }

        /// Converts `input` (linear Rec. 2020) into `output`, which should be the same length. If
        /// one is shorter, only that many pixels are converted, because the C library writes
        /// without checking bounds.
        pub fn apply(transform: Self, input: []const [image.channel_count]f32, output: [][image.channel_count]Sample) void {
            std.debug.assert(input.len == output.len);
            const total = @min(input.len, output.len);
            var done: usize = 0;
            while (done < total) {
                const count = @min(total - done, max_pixels_per_call);
                c.cmsDoTransform(transform.handle, input[done..].ptr, output[done..].ptr, @intCast(count));
                done += count;
            }
        }
    };
}

/// From 8-bit RGB in the colours of a picture's own profile (an ICC file, like a JPEG's embedded
/// one) to linear light in sRGB's primaries, 0 to `image.full_scale`. Colours outside sRGB clip.
/// It's relative colorimetric, with black point compensation, as GIMP and darktable import by
/// default, and isn't squeezed into a precomputed table, which would posterise the linear output
/// (LittleCMS's tutorial, "linear spaces"). It keeps no cache, so threads can share it.
pub const ImportTransform = struct {
    handle: *anyopaque,

    /// A profile that isn't RGB, or that LittleCMS can't read, gives
    /// `error.ColourManagementFailed`.
    pub fn init(profile: []const u8) Error!ImportTransform {
        const source = c.cmsOpenProfileFromMem(profile.ptr, @intCast(profile.len)) orelse return error.ColourManagementFailed;
        defer _ = c.cmsCloseProfile(source);
        if (c.cmsGetColorSpace(source) != c.cmsSigRgbData) return error.ColourManagementFailed;
        var linear: Profile = try .init(.srgb_linear);
        defer linear.deinit();
        const handle = c.cmsCreateTransform(
            source,
            c.TYPE_RGB_8,
            linear.handle,
            c.TYPE_RGB_16,
            @backingInt(Intent.relative_colorimetric),
            c.cmsFLAGS_BLACKPOINTCOMPENSATION | c.cmsFLAGS_NOOPTIMIZE | c.cmsFLAGS_NOCACHE,
        ) orelse return error.ColourManagementFailed;
        return .{ .handle = handle };
    }

    pub fn deinit(transform: *ImportTransform) void {
        c.cmsDeleteTransform(transform.handle);
        transform.* = undefined;
    }

    /// Converts `input` into `output`, which should be the same length.
    pub fn apply(transform: ImportTransform, input: []const [image.channel_count]u8, output: [][image.channel_count]u16) void {
        std.debug.assert(input.len == output.len);
        const total = @min(input.len, output.len);
        var done: usize = 0;
        while (done < total) {
            const count = @min(total - done, max_pixels_per_call);
            c.cmsDoTransform(transform.handle, input[done..].ptr, output[done..].ptr, @intCast(count));
            done += count;
        }
    }
};

/// A transform from sRGB to a display's own profile, for showing pictures on it: 8-bit RGBA in and
/// out, the alpha kept. Relative colorimetric with black point compensation, as screens are
/// usually matched: colours inside the display's gamut stay as they are, and black is the
/// display's black.
pub const DisplayTransform = struct {
    /// From 8-bit sRGB RGBA, for pictures that only come that way.
    handle: *anyopaque,
    /// From linear sRGB in floats to 16-bit RGB, for rendered pictures (`applyLinear`): rounding
    /// once rather than twice, as GIMP and darktable convert to the display from float.
    linear: *anyopaque,

    /// Builds the transforms to `display_profile`, an ICC file. A profile that isn't RGB, or that
    /// LittleCMS can't read, gives `error.ColourManagementFailed`.
    pub fn init(display_profile: []const u8) Error!DisplayTransform {
        var source: Profile = try .init(.srgb);
        defer source.deinit();
        var linear_source: Profile = try .init(.srgb_linear);
        defer linear_source.deinit();
        const display = c.cmsOpenProfileFromMem(display_profile.ptr, @intCast(display_profile.len)) orelse return error.ColourManagementFailed;
        defer _ = c.cmsCloseProfile(display);
        const intent = @backingInt(Intent.relative_colorimetric);
        const handle = c.cmsCreateTransform(source.handle, c.TYPE_RGBA_8, display, c.TYPE_RGBA_8, intent, c.cmsFLAGS_BLACKPOINTCOMPENSATION | c.cmsFLAGS_COPY_ALPHA) orelse
            return error.ColourManagementFailed;
        errdefer c.cmsDeleteTransform(handle);
        // A float transform isn't squeezed into a precomputed table, which would posterise linear
        // input (LittleCMS's tutorial, "linear spaces").
        const linear = c.cmsCreateTransform(linear_source.handle, c.TYPE_RGB_FLT, display, c.TYPE_RGB_16, intent, c.cmsFLAGS_BLACKPOINTCOMPENSATION | c.cmsFLAGS_NOOPTIMIZE) orelse
            return error.ColourManagementFailed;
        return .{ .handle = handle, .linear = linear };
    }

    pub fn deinit(transform: *DisplayTransform) void {
        c.cmsDeleteTransform(transform.handle);
        c.cmsDeleteTransform(transform.linear);
        transform.* = undefined;
    }

    /// Converts `input`, linear light in sRGB's primaries, into `output` in the display's
    /// colours at 16 bits, which should be the same length.
    pub fn applyLinear(transform: DisplayTransform, input: []const [image.channel_count]f32, output: [][image.channel_count]u16) void {
        std.debug.assert(input.len == output.len);
        const total = @min(input.len, output.len);
        var done: usize = 0;
        while (done < total) {
            const count = @min(total - done, max_pixels_per_call);
            c.cmsDoTransform(transform.linear, input[done..].ptr, output[done..].ptr, @intCast(count));
            done += count;
        }
    }

    /// Converts `input` into `output`, which should be the same length (`Transform.apply`).
    pub fn apply(transform: DisplayTransform, input: []const [4]u8, output: [][4]u8) void {
        std.debug.assert(input.len == output.len);
        const total = @min(input.len, output.len);
        var done: usize = 0;
        while (done < total) {
            const count = @min(total - done, max_pixels_per_call);
            c.cmsDoTransform(transform.handle, input[done..].ptr, output[done..].ptr, @intCast(count));
            done += count;
        }
    }
};

/// Where the size, the version and the signature are in an ICC profile's header.
const header_size_offset = 0;
const header_version_offset = 8;
const header_signature_offset = 36;
const header_signature = "acsp";
/// Version 2.4 the way the header encodes it: the major version, then the minor version and the
/// bug-fix level in a nibble each.
const encoded_version_2_4 = 0x02400000;

test "every space's profile is a whole ICC file, version 2.4, that LittleCMS reads back" {
    const gpa = std.testing.allocator;
    for (std.enums.values(Space)) |space| {
        const file = try profileBytes(gpa, space);
        defer gpa.free(file);
        try std.testing.expect(file.len > header_signature_offset + header_signature.len);
        try std.testing.expectEqual(file.len, std.mem.readInt(u32, file[header_size_offset..][0..4], .big));
        try std.testing.expectEqual(encoded_version_2_4, std.mem.readInt(u32, file[header_version_offset..][0..4], .big));
        try std.testing.expectEqualStrings(header_signature, file[header_signature_offset..][0..header_signature.len]);
        const reopened = c.cmsOpenProfileFromMem(file.ptr, @intCast(file.len)) orelse return error.TestUnexpectedResult;
        defer _ = c.cmsCloseProfile(reopened);
        // A v2 profile: the media white is the space's own, and there's no adaptation tag.
        const white: *const c.cmsCIEXYZ = @ptrCast(@alignCast(c.cmsReadTag(reopened, c.cmsSigMediaWhitePointTag) orelse return error.TestUnexpectedResult));
        var expected: c.cmsCIEXYZ = undefined;
        c.cmsxyY2XYZ(&expected, &definition(space).white);
        try std.testing.expectApproxEqAbs(expected.X, white.X, 1e-3);
        try std.testing.expectApproxEqAbs(@as(f64, 1), white.Y, 1e-3);
        try std.testing.expectApproxEqAbs(expected.Z, white.Z, 1e-3);
        try std.testing.expectEqual(@as(c.cmsBool, 0), c.cmsIsTag(reopened, c.cmsSigChromaticAdaptationTag));
    }
}

test "sRGB's profile gives D65 as its white, as HP's and Apple's v2 sRGB profiles do" {
    const gpa = std.testing.allocator;
    const file = try profileBytes(gpa, .srgb);
    defer gpa.free(file);
    const reopened = c.cmsOpenProfileFromMem(file.ptr, @intCast(file.len)) orelse return error.TestUnexpectedResult;
    defer _ = c.cmsCloseProfile(reopened);
    const white: *const c.cmsCIEXYZ = @ptrCast(@alignCast(c.cmsReadTag(reopened, c.cmsSigMediaWhitePointTag) orelse return error.TestUnexpectedResult));
    // HP's sRGB IEC61966-2.1 has 0.9505, 1, 1.0891.
    try std.testing.expectApproxEqAbs(@as(f64, 0.9505), white.X, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0891), white.Z, 1e-3);
}

test "linear Rec. 2020 middle grey and white become sRGB's" {
    var transform: Transform(u8) = try .init(.srgb, .relative_colorimetric);
    defer transform.deinit();
    const middle_grey = 0.18;
    // The sRGB curve turns 0.18 of linear light into 0.4614, which is 118 out of 255.
    const srgb_middle_grey = 118;
    const input = [_][image.channel_count]f32{ @splat(middle_grey), @splat(1.0), @splat(0.0) };
    var output: [input.len][image.channel_count]u8 = undefined;
    transform.apply(&input, &output);
    for (output[0]) |sample| try std.testing.expectApproxEqAbs(srgb_middle_grey, @as(f32, @floatFromInt(sample)), 1);
    try std.testing.expectEqual([image.channel_count]u8{ 255, 255, 255 }, output[1]);
    try std.testing.expectEqual([image.channel_count]u8{ 0, 0, 0 }, output[2]);
}

test "a raw scan's profile is linear: grey keeps its share of the light" {
    var transform: Transform(f32) = try .init(.srgb_linear, .relative_colorimetric);
    defer transform.deinit();
    const input = [_][image.channel_count]f32{ @splat(0.18), @splat(0.5) };
    var output: [input.len][image.channel_count]f32 = undefined;
    transform.apply(&input, &output);
    const tolerance = 1e-3;
    for (input, output) |expected, actual| {
        for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, tolerance);
    }
}

test "a float transform to linear Rec. 2020 changes nothing and keeps values above 1" {
    var transform: Transform(f32) = try .init(.rec2020_linear, .relative_colorimetric);
    defer transform.deinit();
    const input = [_][image.channel_count]f32{ .{ 0.25, 0.5, 0.75 }, @splat(1.5) };
    var output: [input.len][image.channel_count]f32 = undefined;
    transform.apply(&input, &output);
    const tolerance = 1e-4;
    for (input, output) |expected, actual| {
        for (expected, actual) |e, a| try std.testing.expectApproxEqAbs(e, a, tolerance);
    }
}

test "Rec. 2020's red lies outside sRGB and clips in 16 bits" {
    var transform: Transform(u16) = try .init(.srgb, .relative_colorimetric);
    defer transform.deinit();
    const input = [_][image.channel_count]f32{.{ 1.0, 0.0, 0.0 }};
    var output: [input.len][image.channel_count]u16 = undefined;
    transform.apply(&input, &output);
    try std.testing.expectEqual(std.math.maxInt(u16), output[0][0]);
    try std.testing.expectEqual(0, output[0][1]);
    try std.testing.expectEqual(0, output[0][2]);
}

test "two copies of a profile are the same apart from when they were made" {
    const gpa = std.testing.allocator;
    const first = try profileBytes(gpa, .srgb);
    defer gpa.free(first);
    const second = try gpa.dupe(u8, first);
    defer gpa.free(second);
    // As if it were made a second later.
    second[created_at + created_len - 1] +%= 1;
    try std.testing.expect(sameProfile(first, second));
    second[0] +%= 1;
    try std.testing.expect(!sameProfile(first, second));
}

test "a display transform to sRGB leaves pictures as they are, and one to a wider display tones them down" {
    const gpa = std.testing.allocator;
    const pixels = [_][4]u8{ .{ 255, 0, 0, 255 }, .{ 128, 128, 128, 40 }, .{ 0, 0, 0, 0 } };
    var out: [pixels.len][4]u8 = undefined;

    const srgb = try profileBytes(gpa, .srgb);
    defer gpa.free(srgb);
    var same = try DisplayTransform.init(srgb);
    defer same.deinit();
    same.apply(&pixels, &out);
    for (pixels, out) |p, o| for (p, o) |a, b| try std.testing.expect(@abs(@as(i16, a) - b) <= 1);

    // sRGB's red is less saturated than Display P3's, so on a P3 display it needs some green and
    // blue. Grey stays grey, and the alpha stays.
    const p3 = try profileBytes(gpa, .display_p3);
    defer gpa.free(p3);
    var wide = try DisplayTransform.init(p3);
    defer wide.deinit();
    wide.apply(&pixels, &out);
    try std.testing.expect(out[0][0] < 255 and out[0][1] > 0);
    try std.testing.expect(@abs(@as(i16, out[1][0]) - out[1][2]) <= 1);
    try std.testing.expectEqual(@as(u8, 40), out[1][3]);

    try std.testing.expectError(error.ColourManagementFailed, DisplayTransform.init("not a profile"));
}

test "from linear floats to the display, a dark gradient keeps every 16-bit step an 8-bit one would lose" {
    const gpa = std.testing.allocator;
    const p3 = try profileBytes(gpa, .display_p3);
    defer gpa.free(p3);
    var wide = try DisplayTransform.init(p3);
    defer wide.deinit();
    // Display P3 has sRGB's tone curve, so linear grey 0.214 (sRGB 128) comes out at 128 there too.
    var grey = [_][3]f32{.{ 0.2140, 0.2140, 0.2140 }};
    var out: [1][3]u16 = undefined;
    wide.applyLinear(&grey, &out);
    for (out[0]) |v| try std.testing.expectApproxEqAbs(@as(f32, 128 * 257), @as(f32, @floatFromInt(v)), 257);
    // A smooth ramp in the shadows: 64 levels a little apart give more distinct 16-bit values than
    // 8 bits have room for there.
    var ramp: [64][3]f32 = undefined;
    for (&ramp, 0..) |*p, i| p.* = @splat(0.002 + 0.00005 * @as(f32, @floatFromInt(i)));
    var ramp_out: [ramp.len][3]u16 = undefined;
    wide.applyLinear(&ramp, &ramp_out);
    var distinct: usize = 1;
    for (ramp_out[1..], ramp_out[0 .. ramp.len - 1]) |a, b| {
        try std.testing.expect(a[1] >= b[1]);
        if (a[1] != b[1]) distinct += 1;
    }
    const first_8: u16 = ramp_out[0][1] / 257;
    const last_8: u16 = ramp_out[ramp.len - 1][1] / 257;
    try std.testing.expect(distinct > last_8 - first_8 + 1);
}

/// How far a 16-bit value can land from the formula after going through a profile's curve table.
const table_rounding = 4;

test "a picture in its own profile comes in as linear sRGB: sRGB's own as the curve says, Adobe RGB's red toned down" {
    const gpa = std.testing.allocator;
    const pixels = [_][3]u8{ .{ 128, 128, 128 }, .{ 255, 0, 0 }, .{ 0, 0, 0 } };
    var out: [pixels.len][3]u16 = undefined;

    const srgb = try profileBytes(gpa, .srgb);
    defer gpa.free(srgb);
    var from_srgb: ImportTransform = try .init(srgb);
    defer from_srgb.deinit();
    from_srgb.apply(&pixels, &out);
    const grey: f32 = encode.linearFromSrgb(128.0 / 255.0) * image.full_scale;
    for (out[0]) |v| try std.testing.expectApproxEqAbs(grey, @as(f32, @floatFromInt(v)), 0.002 * image.full_scale);
    // sRGB's curve is a table in a version 2 profile, so allow a step or two.
    for ([_][3]u16{ .{ image.full_scale, 0, 0 }, .{ 0, 0, 0 } }, out[1..]) |expected, got| {
        for (expected, got) |e, g| try std.testing.expect(@abs(@as(i32, e) - g) <= table_rounding);
    }

    // Adobe RGB's red is more saturated than sRGB's: it clips at full red, and grey stays grey.
    const adobe = try profileBytes(gpa, .adobe_rgb);
    defer gpa.free(adobe);
    var from_adobe: ImportTransform = try .init(adobe);
    defer from_adobe.deinit();
    from_adobe.apply(&pixels, &out);
    try std.testing.expectEqual(@as(u16, image.full_scale), out[1][0]);
    try std.testing.expect(@abs(@as(i32, out[0][0]) - out[0][2]) <= 2);

    try std.testing.expectError(error.ColourManagementFailed, ImportTransform.init("not a profile"));
}
