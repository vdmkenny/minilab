//! The interface's icons, from Lucide (lucide.dev): one consistent set of outline icons, drawn
//! from its icon font. Only clear-cut icons stand in for words: crop, turn, mirror, pick a
//! colour, copy, delete, edit, zoom, settings, close, the appearances, the pages of Settings, the
//! links to minilab's website and its source code, and the calendar.

const std = @import("std");
const c = @import("c");
const theme = @import("theme.zig");
const fonts = @import("fonts.zig");
const lucide = @import("lucide_codepoints");

/// The icons we use, by their Lucide names, with the codepoints the font gives them.
pub const Icon = enum(u21) {
    crop = lucide.crop,
    rotate_ccw = lucide.@"rotate-ccw",
    rotate_cw = lucide.@"rotate-cw",
    flip_horizontal = lucide.@"flip-horizontal-2",
    pipette = lucide.pipette,
    copy = lucide.copy,
    trash = lucide.@"trash-2",
    search = lucide.search,
    settings = lucide.settings,
    monitor = lucide.monitor,
    moon = lucide.moon,
    sun = lucide.sun,
    triangle_alert = lucide.@"triangle-alert",
    x = lucide.x,
    sun_moon = lucide.@"sun-moon",
    info = lucide.info,
    globe = lucide.globe,
    code = lucide.code,
    calendar = lucide.calendar,
    chevron_left = lucide.@"chevron-left",
    chevron_right = lucide.@"chevron-right",
    pencil = lucide.pencil,
    languages = lucide.languages,
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
