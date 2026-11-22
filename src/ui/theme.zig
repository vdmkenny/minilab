//! Neutral interface palettes: pastel green in light mode and amber in dark mode.
//! Photograph pixels and the film markings keep their own colours.

const std = @import("std");
const c = @import("c");
pub const Mode = @import("minilab").preferences.Theme;

pub const Color = c.ImVec4;

fn hex(value: u24) Color {
    return .{
        .x = @as(f32, @floatFromInt(value >> 16)) / std.math.maxInt(u8),
        .y = @as(f32, @floatFromInt((value >> 8) & 0xff)) / std.math.maxInt(u8),
        .z = @as(f32, @floatFromInt(value & 0xff)) / std.math.maxInt(u8),
        .w = 1,
    };
}

const Palette = struct {
    page: Color = hex(0x1D1D1F),
    header: Color = hex(0x161617),
    panel: Color = hex(0x232325),
    control: Color = hex(0x2D2D30),
    control_hover: Color = hex(0x36363A),
    border: Color = hex(0x3B3B3F),
    divider: Color = hex(0x303033),
    viewer: Color = hex(0x262626),
    text: Color = hex(0xECECEE),
    text_secondary: Color = hex(0xB4B4B8),
    text_tertiary: Color = hex(0x8F8F95),
    accent: Color = hex(0xE8A33D),
    accent_fill: Color = hex(0x3A3127),
    on_accent: Color = hex(0x1A1206),
    primary: Color = hex(0xE8A33D),
    on_primary: Color = hex(0x1A1206),
    ready: Color = hex(0x7FB77E),
    histogram_ground: Color = hex(0x1A1A1B),
    raised: Color = hex(0x2A2A2D),
    track: Color = hex(0x5A5A5F),
    overlay: Color = .{ .x = 22.0 / 255.0, .y = 22.0 / 255.0, .z = 23.0 / 255.0, .w = 0.8 },
};
const dark: Palette = .{};
const light: Palette = .{
    .page = hex(0xF6F6F8),
    .header = hex(0xFFFFFF),
    .panel = hex(0xEEEEF1),
    .control = hex(0xFFFFFF),
    .control_hover = hex(0xE2E3E8),
    .border = hex(0x838996),
    .divider = hex(0xCED0D6),
    .viewer = hex(0xDADADA),
    .text = hex(0x202124),
    .text_secondary = hex(0x51545A),
    .text_tertiary = hex(0x686C73),
    .accent = hex(0x3F735A),
    .primary = hex(0xC3E0CE),
    .on_primary = hex(0x203C2E),
    .accent_fill = hex(0xE1EEE5),
    .on_accent = hex(0xFFFFFF),
    .ready = hex(0x2E7D32),
    .histogram_ground = hex(0xE1E2E5),
    .raised = hex(0xE0E2E8),
    .track = hex(0x8A8F99),
    .overlay = .{ .x = 1, .y = 1, .z = 1, .w = 0.9 },
};
pub var mode: Mode = .dark;

/// Changes custom drawing colours. Apply ImGui's colours between frames so
/// changing themes does not rescale controls or mix palettes within a frame.
pub fn choose(next: Mode) void {
    const palette = switch (next) {
        .dark => dark,
        .light => light,
    };
    inline for (comptime std.meta.fieldNames(Palette)) |name| @field(@This(), name) = @field(palette, name);
    mode = next;
}

pub var page: Color = dark.page;
pub var header: Color = dark.header;
pub var panel: Color = dark.panel;
pub var control: Color = dark.control;
pub var control_hover: Color = dark.control_hover;
pub var border: Color = dark.border;
pub var divider: Color = dark.divider;
pub var viewer: Color = dark.viewer;
pub var text: Color = dark.text;
pub var text_secondary: Color = dark.text_secondary;
pub var text_tertiary: Color = dark.text_tertiary;
pub var accent: Color = dark.accent;
pub var accent_fill: Color = dark.accent_fill;
pub var on_accent: Color = dark.on_accent;
pub var primary: Color = dark.primary;
pub var on_primary: Color = dark.on_primary;
pub var ready: Color = dark.ready;
pub var histogram_ground: Color = dark.histogram_ground;
/// A selected card or row, one step lighter than the panel.
pub var raised: Color = dark.raised;
/// The film of the strips on Rolls.
pub const film = hex(0x0E0E0F);
/// A slide's mount, on Scan's preview of mounted slides.
pub const slide_mount = hex(0xC9C9C4);
/// The film makers' edge print as it comes out on a contact print: Kodak's yellow, Fujifilm's
/// green, and the plain light grey of the others.
pub const edge_kodak = hex(0xE8B04A);
pub const edge_fuji = hex(0x8FD08F);
pub const edge_plain = hex(0xB9B9B4);
/// The track of a slider to the right of its thumb.
pub var track: Color = dark.track;
/// The background behind labels drawn over an image.
pub var overlay: Color = dark.overlay;
pub const red = hex(0xD9534F);
pub const green = hex(0x5CB85C);
pub const blue = hex(0x4A90D9);

/// Returns `color` with its alpha set to `alpha`.
pub fn withAlpha(color: Color, alpha: f32) Color {
    return .{ .x = color.x, .y = color.y, .z = color.z, .w = alpha };
}

/// Returns `color` with its red, green and blue times `factor`, so below 1 it's darker.
pub fn scaled(color: Color, factor: f32) Color {
    return .{ .x = color.x * factor, .y = color.y * factor, .z = color.z * factor, .w = color.w };
}

/// Returns `color` as 8-bit RGBA, for pixels.
pub fn rgba8(color: Color) [4]u8 {
    return .{ channel8(color.x), channel8(color.y), channel8(color.z), channel8(color.w) };
}

/// Returns 8-bit RGBA `pixel` as a colour.
pub fn fromRgba8(pixel: [4]u8) Color {
    const max: f32 = std.math.maxInt(u8);
    return .{ .x = @as(f32, @floatFromInt(pixel[0])) / max, .y = @as(f32, @floatFromInt(pixel[1])) / max, .z = @as(f32, @floatFromInt(pixel[2])) / max, .w = @as(f32, @floatFromInt(pixel[3])) / max };
}

fn channel8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * std.math.maxInt(u8)));
}

pub fn imU32(color: Color) u32 {
    return c.ImGui_ColorConvertFloat4ToU32(color);
}

/// The padding inside windows, popups and tooltips, in the design's pixels.
pub const window_padding = 12;

/// Sets ImGui's style to the design, at `scale` (the display's content scale).
pub fn apply(scale: f32) void {
    const style = c.ImGui_GetStyle();
    style.*.WindowPadding = .{ .x = window_padding, .y = window_padding };
    // Controls 30 pixels high around 13-pixel text, as in the design.
    style.*.FramePadding = .{ .x = 10, .y = 8.5 };
    style.*.ItemSpacing = .{ .x = 8, .y = 8 };
    style.*.ItemInnerSpacing = .{ .x = 8, .y = 6 };
    style.*.WindowRounding = 0;
    style.*.ChildRounding = 0;
    style.*.ChildBorderSize = 0;
    style.*.FrameRounding = 5;
    style.*.PopupRounding = 5;
    style.*.GrabRounding = 4;
    style.*.TabRounding = 4;
    style.*.WindowBorderSize = 0;
    style.*.FrameBorderSize = 1;
    style.*.GrabMinSize = 10;
    style.*.ScrollbarSize = 12;
    c.ImGuiStyle_ScaleAllSizes(style, scale);

    applyColors();
}

/// Standard widgets, including popups and scrollbars, follow the same palette.
pub fn applyColors() void {
    switch (mode) {
        .dark => c.ImGui_StyleColorsDark(null),
        .light => c.ImGui_StyleColorsLight(null),
    }
    const colors = &c.ImGui_GetStyle().*.Colors;
    const set = struct {
        fn set(cs: anytype, which: c_int, color: Color) void {
            cs[@intCast(which)] = color;
        }
    }.set;
    set(colors, c.ImGuiCol_Text, text);
    set(colors, c.ImGuiCol_TextDisabled, text_tertiary);
    set(colors, c.ImGuiCol_WindowBg, page);
    set(colors, c.ImGuiCol_ChildBg, panel);
    set(colors, c.ImGuiCol_PopupBg, panel);
    set(colors, c.ImGuiCol_Border, border);
    set(colors, c.ImGuiCol_FrameBg, control);
    set(colors, c.ImGuiCol_FrameBgHovered, control_hover);
    set(colors, c.ImGuiCol_FrameBgActive, control_hover);
    set(colors, c.ImGuiCol_TitleBg, header);
    set(colors, c.ImGuiCol_TitleBgActive, header);
    set(colors, c.ImGuiCol_MenuBarBg, header);
    set(colors, c.ImGuiCol_CheckMark, accent);
    set(colors, c.ImGuiCol_SliderGrab, accent);
    set(colors, c.ImGuiCol_SliderGrabActive, accent);
    set(colors, c.ImGuiCol_Button, control);
    set(colors, c.ImGuiCol_ButtonHovered, control_hover);
    set(colors, c.ImGuiCol_ButtonActive, accent_fill);
    set(colors, c.ImGuiCol_Header, accent_fill);
    set(colors, c.ImGuiCol_HeaderHovered, control_hover);
    set(colors, c.ImGuiCol_HeaderActive, accent_fill);
    set(colors, c.ImGuiCol_Separator, divider);
    set(colors, c.ImGuiCol_Tab, header);
    set(colors, c.ImGuiCol_TabHovered, control_hover);
    set(colors, c.ImGuiCol_TabSelected, control);
    set(colors, c.ImGuiCol_TabSelectedOverline, accent);
    set(colors, c.ImGuiCol_DockingPreview, accent);
    set(colors, c.ImGuiCol_NavCursor, accent);
}

test "colours read from hex and back to bytes" {
    try std.testing.expectEqual([4]u8{ 0xE8, 0xA3, 0x3D, 0xFF }, rgba8(dark.accent));
    try std.testing.expectEqual([4]u8{ 0xE8, 0xA3, 0x3D, 0x80 }, rgba8(withAlpha(dark.accent, 0.5)));
    try std.testing.expectEqual([4]u8{ 0, 0xFF, 0, 0 }, rgba8(.{ .x = -1, .y = 2, .z = 0, .w = 0 }));
}

fn luminance(color: Color) f32 {
    const components = [_]f32{ color.x, color.y, color.z };
    var linear: [3]f32 = undefined;
    for (&linear, components) |*out, v| out.* = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
    return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722;
}
fn contrast(a: Color, b: Color) f32 {
    const first = luminance(a);
    const second = luminance(b);
    return (@max(first, second) + 0.05) / (@min(first, second) + 0.05);
}

test "light and dark palettes keep text and controls distinct" {
    for ([_]Palette{ light, dark }) |palette| {
        try std.testing.expect(contrast(palette.text, palette.page) >= 7);
        try std.testing.expect(contrast(palette.text_secondary, palette.panel) >= 4.5);
        try std.testing.expect(contrast(palette.text_tertiary, palette.page) >= 4.5);
        try std.testing.expect(contrast(palette.on_accent, palette.accent) >= 4.5);
        try std.testing.expect(contrast(palette.on_primary, palette.primary) >= 4.5);
    }
    try std.testing.expect(luminance(light.viewer) > luminance(dark.viewer));
}

test "changing appearance preserves UI scale and semantic image markings" {
    const previous = mode;
    defer choose(previous);
    const context = c.ImGui_CreateContext(null);
    defer c.ImGui_DestroyContext(context);
    choose(.dark);
    apply(1.5);
    const padding = c.ImGui_GetStyle().*.FramePadding;
    const scrollbar = c.ImGui_GetStyle().*.ScrollbarSize;
    const film_color = rgba8(film);
    const marker = rgba8(red);
    for ([_]Mode{ .light, .dark, .light, .dark }) |next| {
        choose(next);
        applyColors();
        try std.testing.expectEqual(padding, c.ImGui_GetStyle().*.FramePadding);
        try std.testing.expectEqual(scrollbar, c.ImGui_GetStyle().*.ScrollbarSize);
        try std.testing.expectEqual(film_color, rgba8(film));
        try std.testing.expectEqual(marker, rgba8(red));
    }
}
