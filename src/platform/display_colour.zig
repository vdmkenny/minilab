//! Pictures in the display's own colours. minilab renders everything in sRGB, but a wide-gamut
//! display, like any recent Mac's (Display P3), shows sRGB values as they are, more saturated than
//! they are meant to be. So pictures are converted to the display's ICC profile on their way to the
//! GPU (`Texture.replace`).
//!
//! macOS converts the window itself: SDL tags its Metal layer as sRGB, and the system converts
//! that to each display. Converting here too would do it twice, so on macOS nothing changes here.
//! Windows and Linux composite what they're given as it is, so there minilab converts. SDL gives
//! the profile of the display the window is on (`SDL_GetWindowICCProfile`), and says when it
//! changes, like when the window moves to another display.
//!
//! The interface's own colours are greys, and stay as they are.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const icc = @import("minilab").codecs.icc;
const encode = @import("minilab").encode;
const image = @import("minilab").image;

/// Whether the system converts the window to the display's profile itself.
pub const system_converts = builtin.os.tag == .macos;

/// The transform to the display's profile, or null to show sRGB as it is: on macOS, without a
/// profile, or with one that can't be read.
var transform: ?icc.DisplayTransform = null;
/// A hash of the profile `transform` was made from, so the same profile isn't taken again.
var profile_hash: ?u64 = null;
/// Goes up each time the transform changes, so pictures already on the GPU can be made again
/// (`Watch`).
var generation: u32 = 0;

/// Takes the profile of the display `window` is on. Call it when the window opens and when SDL
/// says the profile changed.
pub fn update(window: *c.SDL_Window) void {
    if (system_converts) return;
    var size: usize = 0;
    const data: ?[*]const u8 = @ptrCast(c.SDL_GetWindowICCProfile(window, &size));
    defer if (data) |d| c.SDL_free(@constCast(d));
    const profile = if (data) |d| d[0..size] else null;
    const hash = if (profile) |p| std.hash.Wyhash.hash(0, p) else null;
    if (hash == profile_hash) return;
    const next: ?icc.DisplayTransform = if (profile) |p| icc.DisplayTransform.init(p) catch |err| none: {
        std.log.warn("the display's colour profile can't be used ({t}), so pictures show as sRGB", .{err});
        break :none null;
    } else null;
    if (transform) |*t| t.deinit();
    transform = next;
    profile_hash = hash;
    generation +%= 1;
}

/// Converts `pixels`, sRGB, into `out` in the display's colours, or copies them when there's
/// nothing to convert.
pub fn convert(pixels: []const [4]u8, out: [][4]u8) void {
    if (transform) |t| t.apply(pixels, out) else @memcpy(out, pixels);
}

/// How many pixels `fromLinear` converts at a time.
const chunk = 4096;
/// A 4 × 4 ordered dither: where in a step each place rounds up.
const bayer = [4][4]u8{ .{ 0, 8, 2, 10 }, .{ 12, 4, 14, 6 }, .{ 3, 11, 1, 9 }, .{ 15, 7, 13, 5 } };
const bayer_levels = 16;

/// Whether pictures are converted to the display's colours here: there's a display profile, and
/// the system doesn't do it itself.
pub fn active() bool {
    return transform != null;
}

/// Encodes `linear`, a rendered picture in linear light with sRGB's primaries, into `out` as
/// opaque 8-bit RGBA in the display's colours, ready to upload as `.display`. With a display
/// profile it converts from float in one step and dithers from 16 bits to 8, so a gradient on a
/// wide-gamut display doesn't band (GIMP and darktable do the same); without one it's sRGB.
pub fn fromLinear(linear: image.Rendered, out: [][4]u8) void {
    const t = transform orelse return encode.toRgba8(linear, out);
    std.debug.assert(linear.pixels.len == out.len);
    var wide: [chunk][3]u16 = undefined;
    var at: usize = 0;
    while (at < out.len) : (at += chunk) {
        const n = @min(chunk, out.len - at);
        t.applyLinear(linear.pixels[at..][0..n], wide[0..n]);
        for (out[at..][0..n], wide[0..n], at..) |*o, w, i| o.* = dithered(w, i % linear.width, i / linear.width);
    }
}

/// A 16-bit pixel at (`x`, `y`) rounded to 8 bits, up or down by where it sits in the dither's
/// pattern, so the levels between two 8-bit steps come out as a fine mix of the two.
fn dithered(wide: [3]u16, x: usize, y: usize) [4]u8 {
    const threshold = (@as(f32, @floatFromInt(bayer[y % bayer.len][x % bayer.len])) + 0.5) / bayer_levels;
    var out: [4]u8 = .{ 0, 0, 0, std.math.maxInt(u8) };
    for (out[0..3], wide) |*v, s| {
        const level = @as(f32, @floatFromInt(s)) / steps_8_to_16;
        const below = @floor(level);
        v.* = @intFromFloat(@min(std.math.maxInt(u8), below + @as(f32, if (level - below > threshold) 1 else 0)));
    }
    return out;
}

/// One 8-bit step in 16 bits: 65535 / 255.
const steps_8_to_16 = 257;

test "dithering keeps a level between two steps on average, and whole steps exactly" {
    var sum: u32 = 0;
    // Halfway between 100 and 101.
    const half: u16 = 100 * steps_8_to_16 + steps_8_to_16 / 2;
    for (0..bayer.len) |y| for (0..bayer.len) |x| {
        const v = dithered(.{ half, 100 * steps_8_to_16, std.math.maxInt(u16) }, x, y);
        try std.testing.expect(v[0] == 100 or v[0] == 101);
        try std.testing.expectEqual(@as(u8, 100), v[1]);
        try std.testing.expectEqual(@as(u8, 255), v[2]);
        sum += v[0];
    };
    try std.testing.expectEqual(@as(u32, 100 * 16 + 8), sum);
}

/// Frees the transform, when the app closes.
pub fn deinit() void {
    if (transform) |*t| t.deinit();
    transform = null;
    profile_hash = null;
}

/// For a place that keeps pictures on the GPU: says once each time the display's colours change,
/// so it can make them again.
pub const Watch = struct {
    seen: u32 = 0,

    pub fn changed(watch: *Watch) bool {
        if (watch.seen == generation) return false;
        watch.seen = generation;
        return true;
    }
};
