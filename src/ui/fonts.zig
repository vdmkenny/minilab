//! The fonts built into the app: IBM Plex Sans in two weights for the interface, and JetBrains
//! Mono for values.

const std = @import("std");
const c = @import("c");

pub const Face = enum { regular, semibold, mono };

/// The design's type sizes, in its pixels. Most text is `ui_size`.
pub const ui_size: f32 = 13;
/// Secondary lines, section headings, file names and values.
pub const small_size: f32 = 12;
/// The frame numbers under a strip.
pub const caption_size: f32 = 11;
/// Labels on pictures, and the version in the header.
pub const tiny_size: f32 = 10;
/// The app's name in the header.
pub const wordmark_size: f32 = 14;
/// A panel's or a card's title.
pub const title_size: f32 = 15;
/// A page's title.
pub const page_title_size: f32 = 18;

var faces: std.EnumArray(Face, ?*c.ImFont) = .initFill(null);
var scale: f32 = 1;

const data: std.EnumArray(Face, []const u8) = .init(.{
    .regular = @embedFile("IBMPlexSans-Regular.ttf"),
    .semibold = @embedFile("IBMPlexSans-SemiBold.ttf"),
    .mono = @embedFile("JetBrainsMono-Regular.ttf"),
});

/// Adds the fonts to ImGui's atlas, scaled by `display_scale`. The first one becomes the default.
pub fn load(display_scale: f32) void {
    scale = display_scale;
    const atlas = c.ImGui_GetIO().*.Fonts;
    for (std.enums.values(Face)) |face| {
        var config: c.ImFontConfig = .{
            // ImGui only reads the data; it stays embedded in the program.
            .FontDataOwnedByAtlas = false,
            .GlyphMaxAdvanceX = std.math.floatMax(f32),
            .RasterizerMultiply = 1,
            .RasterizerDensity = 1,
            .ExtraSizeScale = 1,
        };
        const bytes = data.get(face);
        faces.set(face, c.ImFontAtlas_AddFontFromMemoryTTF(atlas, @constCast(bytes.ptr), @intCast(bytes.len), ui_size * scale, &config, null));
    }
}

/// Draws text in `face`, at the current size, until `pop`.
pub fn push(face: Face) void {
    c.ImGui_PushFontFloat(faces.get(face), 0);
}

/// Draws text in `face` at `size` (in the design's pixels), until `pop`.
pub fn pushSized(face: Face, size: f32) void {
    c.ImGui_PushFontFloat(faces.get(face), size * scale);
}

pub fn pop() void {
    c.ImGui_PopFont();
}
