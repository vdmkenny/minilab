//! The fonts built into the app: IBM Plex Sans in two weights for the interface, JetBrains Mono
//! for values, and Lucide's icon font (see icons.zig). Japanese comes from the system's font.

const std = @import("std");
const c = @import("c");
const system_fonts = @import("../platform/system_fonts.zig");

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
var icon_face: ?*c.ImFont = null;
/// Whether the system's Japanese font was found and merged into the faces.
var japanese = false;
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
        faces.set(face, add(atlas, data.get(face)));
        // Japanese comes from the system's own font, merged into each face for the glyphs ours
        // don't have.
        var path: [japanese_path]u8 = undefined;
        if (system_fonts.japanese(&path, if (face == .semibold) .bold else .regular)) |found| {
            japanese = merge(atlas, found) or japanese;
        }
    }
    icon_face = add(atlas, icon_data);
}

/// How big Japanese is drawn next to Latin text of the same size. A Japanese font fills its whole
/// em square, so at full size its characters look a size bigger than IBM Plex's.
const japanese_scale = 0.9;

/// The longest path to a system font we read.
const japanese_path = 1024;

/// Merges `face`, a system font, into the face added last. Returns whether it could be read.
fn merge(atlas: *c.ImFontAtlas, face: system_fonts.Face) bool {
    var config: c.ImFontConfig = .{
        .MergeMode = true,
        .FontNo = face.index,
        .GlyphMaxAdvanceX = std.math.floatMax(f32),
        .RasterizerMultiply = 1,
        .RasterizerDensity = 1,
        .ExtraSizeScale = japanese_scale,
    };
    return c.ImFontAtlas_AddFontFromFileTTF(atlas, face.path.ptr, ui_size * scale, &config, null) != null;
}

/// Whether the faces have Japanese, from the system's font.
pub fn hasJapanese() bool {
    return japanese;
}

fn add(atlas: *c.ImFontAtlas, bytes: []const u8) ?*c.ImFont {
    var config: c.ImFontConfig = .{
        // ImGui only reads the data; it stays embedded in the program.
        .FontDataOwnedByAtlas = false,
        .GlyphMaxAdvanceX = std.math.floatMax(f32),
        .RasterizerMultiply = 1,
        .RasterizerDensity = 1,
        .ExtraSizeScale = 1,
    };
    return c.ImFontAtlas_AddFontFromMemoryTTF(atlas, @constCast(bytes.ptr), @intCast(bytes.len), ui_size * scale, &config, null);
}

const icon_data = @embedFile("lucide.ttf");

/// The icon font, for icons.zig.
pub fn icons() ?*c.ImFont {
    return icon_face;
}

/// Draws text in `face`, at the current size, until `pop`.
pub fn push(face: Face) void {
    c.ImGui_PushFontFloat(faces.get(face), 0);
}

/// Draws text in `face` at `size` (in the design's pixels), until `pop`.
pub fn pushSized(face: Face, size: f32) void {
    c.ImGui_PushFontFloat(faces.get(face), size * scale);
}

/// Draws text in `face` at `size` screen pixels, until `pop`. For text that follows something
/// drawn to scale, like a strip of film.
pub fn pushPixels(face: Face, size: f32) void {
    c.ImGui_PushFontFloat(faces.get(face), size);
}

pub fn pop() void {
    c.ImGui_PopFont();
}
