//! Colour profiles through LittleCMS 2: the output spaces minilab offers, built from their
//! definitions, each one's ICC profile as bytes to embed in a TIFF or a JPEG, and the transform
//! from minilab's working space, linear Rec. 2020, to any of them.
//!
//! The profiles are ICC version 2.4 matrix-shaper profiles, which every colour-managed program
//! reads; LittleCMS stores their curves as tables where version 2 has no parametric form.

const std = @import("std");
const c = @import("codecs");
const image = @import("../../core/image.zig");

/// The colour spaces minilab writes.
pub const Space = enum {
    srgb,
    display_p3,
    adobe_rgb,
    prophoto,
    rec2020_linear,
};

/// The rendering intents, as LittleCMS numbers them. Between matrix-shaper profiles, perceptual
/// and saturation fall back to relative colorimetric.
pub const Intent = enum(u32) {
    perceptual = c.INTENT_PERCEPTUAL,
    relative_colorimetric = c.INTENT_RELATIVE_COLORIMETRIC,
    saturation = c.INTENT_SATURATION,
    absolute_colorimetric = c.INTENT_ABSOLUTE_COLORIMETRIC,
};

pub const Error = error{
    /// LittleCMS failed to build a profile or a transform, which happens when it runs out of memory.
    ColourManagementFailed,
    OutOfMemory,
};

/// The ICC version the profiles declare.
const icc_version = 2.4;
/// The luminance of a primary or of white in its chromaticity, which LittleCMS takes as 1.
const unit_luminance = 1.0;

/// How a space encodes linear light.
const Transfer = union(enum) {
    linear,
    /// A pure power: encoded ^ gamma = linear.
    gamma: f64,
    /// LittleCMS's parametric curve 4: linear = (a * encoded + b) ^ g above d, c * encoded below.
    /// The parameters are in its order: g, a, b, c, d.
    parametric: [5]f64,
};

/// LittleCMS's number for the parametric curve with a linear toe.
const parametric_with_toe = 4;

/// IEC 61966-2-1's sRGB curve, which Display P3 shares.
const srgb_transfer: Transfer = .{ .parametric = .{ 2.4, 1.0 / 1.055, 0.055 / 1.055, 1.0 / 12.92, 0.04045 } };

/// The white points, CIE 1931 xy.
const d65: c.cmsCIExyY = .{ .x = 0.3127, .y = 0.3290, .Y = unit_luminance };
const d50: c.cmsCIExyY = .{ .x = 0.3457, .y = 0.3585, .Y = unit_luminance };

/// A space's description, white, primaries and transfer function.
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

fn definition(space: Space) Definition {
    return switch (space) {
        // IEC 61966-2-1.
        .srgb => .{
            .description = "sRGB",
            .white = d65,
            .primaries = primaries(.{ 0.64, 0.33 }, .{ 0.30, 0.60 }, .{ 0.15, 0.06 }),
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
        // because Adobe's own profile carries Adobe's name.
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
    };
}

/// A colour profile, open in LittleCMS.
pub const Profile = struct {
    handle: *anyopaque,

    /// The profile of `space`.
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
        return .{ .handle = handle };
    }

    pub fn deinit(profile: *Profile) void {
        _ = c.cmsCloseProfile(profile.handle);
        profile.* = undefined;
    }

    /// The profile as an ICC file, to embed. The caller owns the bytes.
    pub fn bytes(profile: Profile, gpa: std.mem.Allocator) Error![]u8 {
        var size: c.cmsUInt32Number = 0;
        if (c.cmsSaveProfileToMem(profile.handle, null, &size) == 0) return error.ColourManagementFailed;
        const file = try gpa.alloc(u8, size);
        errdefer gpa.free(file);
        if (c.cmsSaveProfileToMem(profile.handle, file.ptr, &size) == 0) return error.ColourManagementFailed;
        return file;
    }
};

/// The ICC profile of `space` as bytes, to embed in a file. The caller owns them.
pub fn profileBytes(gpa: std.mem.Allocator, space: Space) Error![]u8 {
    var profile: Profile = try .init(space);
    defer profile.deinit();
    return profile.bytes(gpa);
}

/// The most pixels LittleCMS converts in one call, as it counts them in 32 bits.
const max_pixels_per_call = std.math.maxInt(c.cmsUInt32Number);

/// A transform from linear Rec. 2020, minilab's working space, to a space's encoding, for pixels
/// of `Sample`s: `f32`, where 0 to 1 is the space's range and values beyond it are kept, or `u16`
/// or `u8`, which clip. It holds no cache, so threads can share it.
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

        /// Converts `input`, linear Rec. 2020, into `output`, which is as long. Should one be
        /// shorter, only that many pixels are converted: the C library writes without bounds.
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

/// The offsets in an ICC profile's header of its size, its version and its signature.
const header_size_offset = 0;
const header_version_offset = 8;
const header_signature_offset = 36;
const header_signature = "acsp";
/// Version 2.4 as the header encodes it: major, then minor and bug-fix in a nibble each.
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
        _ = c.cmsCloseProfile(reopened);
    }
}

test "linear Rec. 2020 middle grey and white become sRGB's" {
    var transform: Transform(u8) = try .init(.srgb, .relative_colorimetric);
    defer transform.deinit();
    const middle_grey = 0.18;
    // The sRGB curve gives 0.4614 for 0.18 of linear light: 118 of 255.
    const srgb_middle_grey = 118;
    const input = [_][image.channel_count]f32{ @splat(middle_grey), @splat(1.0), @splat(0.0) };
    var output: [input.len][image.channel_count]u8 = undefined;
    transform.apply(&input, &output);
    for (output[0]) |sample| try std.testing.expectApproxEqAbs(srgb_middle_grey, @as(f32, @floatFromInt(sample)), 1);
    try std.testing.expectEqual([image.channel_count]u8{ 255, 255, 255 }, output[1]);
    try std.testing.expectEqual([image.channel_count]u8{ 0, 0, 0 }, output[2]);
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
