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
