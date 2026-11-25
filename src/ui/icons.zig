//! The interface's icons, from Lucide (lucide.dev): one consistent set of outline icons, drawn
//! from its icon font. Only clear-cut icons stand in for words: crop, turn, mirror, pick a
//! colour, copy, delete, edit, zoom, settings, close, the appearances, the pages of Settings, the
//! links to minilab's website and its code on GitHub, and the calendar.

const std = @import("std");
const c = @import("c");
const theme = @import("theme.zig");
const fonts = @import("fonts.zig");

/// The icons we use, by their Lucide names.
pub const Icon = enum(u21) {
    crop = 0xe0af,
    rotate_ccw = 0xe14c,
    rotate_cw = 0xe14d,
    flip_horizontal = 0xe362,
    pipette = 0xe13f,
    copy = 0xe0a2,
    trash = 0xe18e,
    search = 0xe155,
    settings = 0xe158,
    monitor = 0xe121,
    moon = 0xe122,
    sun = 0xe17c,
    triangle_alert = 0xe193,
    x = 0xe1b2,
    sun_moon = 0xe2b2,
    info = 0xe0fe,
    globe = 0xe0eb,
    github = 0xe0e9,
    calendar = 0xe067,
    chevron_left = 0xe072,
    chevron_right = 0xe073,
    pencil = 0xe1f9,
    languages = 0xe103,
};

/// Draws `icon` `size` screen pixels square, centred on `centre`.
pub fn draw(list: *c.ImDrawList, icon: Icon, centre: c.ImVec2, size: f32, colour: theme.Color) void {
    const font = fonts.icons() orelse return;
    var buffer: [4:0]u8 = @splat(0);
    const len = std.unicode.utf8Encode(@backingInt(icon), &buffer) catch return;
    buffer[len] = 0;
    const box = c.ImFont_CalcTextSizeA(font, size, std.math.floatMax(f32), 0, &buffer);
    const at: c.ImVec2 = .{ .x = centre.x - box.x / 2, .y = centre.y - box.y / 2 };
    c.ImDrawList_AddTextImFontPtr(list, font, size, at, theme.imU32(colour), &buffer);
}

test "every icon is in the font" {
    const context = c.ImGui_CreateContext(null);
    defer c.ImGui_DestroyContext(context);
    fonts.load(1);
    for (std.enums.values(Icon)) |icon| {
        try std.testing.expect(c.ImFont_IsGlyphInFont(fonts.icons(), @intCast(@backingInt(icon))));
    }
}
