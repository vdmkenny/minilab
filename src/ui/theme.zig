//! The look of the interface: neutral greys, so they don't skew how you judge an image's colour,
//! with one accent for selection and focus. Dark by default; a light palette is there for those
//! who prefer it. The values come from the design canvas.
//!
//! The interface's colours are in `colors` and change with the appearance. Colours that stand for
//! something in the picture, or are drawn over it, are constants: they stay the same in both.

const std = @import("std");
const c = @import("c");

pub const Color = c.ImVec4;

fn hex(value: u24) Color {
    return .{
        .x = @as(f32, @floatFromInt(value >> 16)) / std.math.maxInt(u8),
        .y = @as(f32, @floatFromInt((value >> 8) & 0xff)) / std.math.maxInt(u8),
        .z = @as(f32, @floatFromInt(value & 0xff)) / std.math.maxInt(u8),
        .w = 1,
    };
}

/// The interface's colours in one appearance.
pub const Palette = struct {
    page: Color,
    header: Color,
    panel: Color,
    control: Color,
    control_hover: Color,
    border: Color,
    divider: Color,
    /// Around the picture in the viewer.
    viewer: Color,
    text: Color,
    text_secondary: Color,
    text_tertiary: Color,
    /// Selection, focus, the one main action on a page, and warnings.
    accent: Color,
    accent_fill: Color,
    on_accent: Color,
    /// The scanner's ready dot.
    ready: Color,
    histogram_ground: Color,
    /// A selected card or row, one step off the panel.
    raised: Color,
    /// The track of a slider to the right of its thumb.
    track: Color,
};

/// The dark palette keeps to exact greys too. Its borders and slider tracks stand out from the
/// panels enough to see (3:1, as WCAG asks of controls).
pub const dark: Palette = .{
    .page = hex(0x1E1E1E),
    .header = hex(0x171717),
    .panel = hex(0x242424),
    .control = hex(0x2E2E2E),
    .control_hover = hex(0x383838),
    .border = hex(0x707070),
    .divider = hex(0x313131),
    .viewer = hex(0x262626),
    .text = hex(0xEDEDED),
    .text_secondary = hex(0xB5B5B5),
    .text_tertiary = hex(0x969696),
    .accent = hex(0xE8A33D),
    .accent_fill = hex(0x3A3127),
    .on_accent = hex(0x1A1206),
    .ready = hex(0x7FB77E),
    .histogram_ground = hex(0x1A1A1A),
    .raised = hex(0x2B2B2B),
    .track = hex(0x737373),
};

/// The light palette keeps to exact greys, so nothing tints the picture beside it, and none of
/// it is pure white, which would glare. The amber is darker, to read on the light greys.
pub const light: Palette = .{
    .page = hex(0xF2F2F2),
    .header = hex(0xF7F7F7),
    .panel = hex(0xEBEBEB),
    .control = hex(0xFAFAFA),
    .control_hover = hex(0xE0E0E0),
    .border = hex(0x868686),
    .divider = hex(0xD0D0D0),
    .viewer = hex(0xE4E4E4),
    .text = hex(0x1F1F1F),
    .text_secondary = hex(0x555555),
    .text_tertiary = hex(0x666666),
    .accent = hex(0x8A5300),
    .accent_fill = hex(0xF1E3CB),
    .on_accent = hex(0xFFFFFF),
    .ready = hex(0x2E7D32),
    .histogram_ground = hex(0xE0E0E0),
    .raised = hex(0xE2E2E2),
    .track = hex(0x858585),
};

/// Which palette the interface uses.
pub const Mode = enum { dark, light };

/// How the interface looks: its palette, and whether the viewer stays dark in the light one.
pub const Look = struct {
    mode: Mode = .dark,
    dark_viewer: bool = true,

    fn palette(look: Look) Palette {
        var chosen = switch (look.mode) {
            .dark => dark,
            .light => light,
        };
        if (look.dark_viewer) chosen.viewer = dark.viewer;
        return chosen;
    }
};

/// The interface's colours now. Change them with `use`.
pub var colors: Palette = dark;
/// The look `colors` is from.
pub var current: Look = .{};

/// What's drawn on the viewer's background, between `beginViewer` and `endViewer`.
pub const OnViewer = struct { saved: Palette };

/// Starts drawing on the viewer: when it stays dark in the light appearance, its labels and
/// controls take the dark palette, so they read on it. ImGui's own text follows too.
pub fn beginViewer() OnViewer {
    const on: OnViewer = .{ .saved = colors };
    if (current.mode == .light and current.dark_viewer) colors = dark;
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Text, colors.text);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_TextDisabled, colors.text_tertiary);
    return on;
}

/// Goes back to the interface's colours after `beginViewer`.
pub fn endViewer(on: OnViewer) void {
    c.ImGui_PopStyleColorEx(2);
    colors = on.saved;
}

/// The film of the strips on Rolls.
pub const film = hex(0x0E0E0F);
/// A slide's mount, on Scan's preview of mounted slides.
pub const slide_mount = hex(0xC9C9C4);
/// The film makers' edge print as it comes out on a contact print: Kodak's yellow, Fujifilm's
/// green, and the plain light grey of the others.
pub const edge_kodak = hex(0xE8B04A);
pub const edge_fuji = hex(0x8FD08F);
pub const edge_plain = hex(0xB9B9B4);
/// The shade behind labels drawn over a picture, and over the parts of it a crop leaves out, and
/// the ink drawn on it. A picture can be anything, so these don't change with the appearance.
pub const overlay = withAlpha(hex(0x171717), 0.8);
pub const on_overlay = hex(0xEDEDED);
/// Clipped highlights and shadows, and the colour channels.
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

/// Sets ImGui's style to the design, at `scale` (the display's content scale), in `initial`.
pub fn apply(scale: f32, initial: Look) void {
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

    use(initial);
}

/// Changes the interface to `next`: the colours drawn by hand, and ImGui's own widgets, which
/// start from ImGui's matching style for the parts we don't set. Call it between frames, so a
/// frame never mixes the two.
pub fn use(next: Look) void {
    current = next;
    colors = next.palette();
    switch (next.mode) {
        .dark => c.ImGui_StyleColorsDark(null),
        .light => c.ImGui_StyleColorsLight(null),
    }
    const slots = &c.ImGui_GetStyle().*.Colors;
    const p = colors;
    const set = struct {
        fn set(cs: anytype, which: c_int, color: Color) void {
            cs[@intCast(which)] = color;
        }
    }.set;
    set(slots, c.ImGuiCol_Text, p.text);
    set(slots, c.ImGuiCol_TextDisabled, p.text_tertiary);
    set(slots, c.ImGuiCol_WindowBg, p.page);
    set(slots, c.ImGuiCol_ChildBg, p.panel);
    set(slots, c.ImGuiCol_PopupBg, p.panel);
    set(slots, c.ImGuiCol_Border, p.border);
    set(slots, c.ImGuiCol_FrameBg, p.control);
    set(slots, c.ImGuiCol_FrameBgHovered, p.control_hover);
    set(slots, c.ImGuiCol_FrameBgActive, p.control_hover);
    set(slots, c.ImGuiCol_TitleBg, p.header);
    set(slots, c.ImGuiCol_TitleBgActive, p.header);
    set(slots, c.ImGuiCol_MenuBarBg, p.header);
    set(slots, c.ImGuiCol_CheckMark, p.accent);
    set(slots, c.ImGuiCol_SliderGrab, p.accent);
    set(slots, c.ImGuiCol_SliderGrabActive, p.accent);
    set(slots, c.ImGuiCol_Button, p.control);
    set(slots, c.ImGuiCol_ButtonHovered, p.control_hover);
    set(slots, c.ImGuiCol_ButtonActive, p.accent_fill);
    set(slots, c.ImGuiCol_Header, p.accent_fill);
    set(slots, c.ImGuiCol_HeaderHovered, p.control_hover);
    set(slots, c.ImGuiCol_HeaderActive, p.accent_fill);
    set(slots, c.ImGuiCol_Separator, p.divider);
    set(slots, c.ImGuiCol_Tab, p.header);
    set(slots, c.ImGuiCol_TabHovered, p.control_hover);
    set(slots, c.ImGuiCol_TabSelected, p.control);
    set(slots, c.ImGuiCol_TabSelectedOverline, p.accent);
    set(slots, c.ImGuiCol_DockingPreview, p.accent);
    set(slots, c.ImGuiCol_NavCursor, p.accent);
    // ImGui fades its dim in after the dialog has appeared, which jars. `gui.dimBehindDialog`
    // dims at once instead.
    set(slots, c.ImGuiCol_ModalWindowDimBg, withAlpha(overlay, 0));
}

/// What a dialog lays over the app behind it.
pub const dialog_dim = withAlpha(overlay, 0.5);

test "colours read from hex and back to bytes" {
    try std.testing.expectEqual([4]u8{ 0xE8, 0xA3, 0x3D, 0xFF }, rgba8(dark.accent));
    try std.testing.expectEqual([4]u8{ 0xE8, 0xA3, 0x3D, 0x80 }, rgba8(withAlpha(dark.accent, 0.5)));
    try std.testing.expectEqual([4]u8{ 0, 0xFF, 0, 0 }, rgba8(.{ .x = -1, .y = 2, .z = 0, .w = 0 }));
}

/// WCAG's relative luminance of `color`.
fn luminance(color: Color) f32 {
    var sum: f32 = 0;
    for ([_]f32{ color.x, color.y, color.z }, [_]f32{ 0.2126, 0.7152, 0.0722 }) |v, weight| {
        const linear = if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
        sum += weight * linear;
    }
    return sum;
}

/// WCAG's contrast ratio between `a` and `b`, from 1 to 21.
fn contrast(a: Color, b: Color) f32 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

test "both palettes keep text readable and controls visible" {
    // WCAG AA: 4.5 for text, 3 for the parts of a control you need to see.
    const text_contrast = 4.5;
    const control_contrast = 3;
    for ([_]Palette{ dark, light }) |p| {
        for ([_]Color{ p.page, p.panel, p.control }) |ground| {
            try std.testing.expect(contrast(p.text, ground) >= text_contrast);
            try std.testing.expect(contrast(p.text_secondary, ground) >= text_contrast);
            // Notices in the header are in the accent.
            try std.testing.expect(contrast(p.accent, ground) >= text_contrast);
        }
        try std.testing.expect(contrast(p.text_tertiary, p.page) >= text_contrast);
        try std.testing.expect(contrast(p.on_accent, p.accent) >= text_contrast);
        try std.testing.expect(contrast(p.text, p.accent_fill) >= text_contrast);
        try std.testing.expect(contrast(p.text_tertiary, p.control) >= text_contrast);
        for ([_]Color{ p.page, p.panel, p.header }) |ground| {
            try std.testing.expect(contrast(p.border, ground) >= control_contrast);
        }
        try std.testing.expect(contrast(p.track, p.panel) >= control_contrast);
    }
    try std.testing.expect(contrast(on_overlay, withAlpha(overlay, 1)) >= text_contrast);
}

test "a dark viewer stays dark in the light palette" {
    try std.testing.expectEqual(dark.viewer, (Look{ .mode = .light, .dark_viewer = true }).palette().viewer);
    try std.testing.expectEqual(light.viewer, (Look{ .mode = .light, .dark_viewer = false }).palette().viewer);
}

test "changing the look keeps the interface's sizes" {
    const context = c.ImGui_CreateContext(null);
    defer c.ImGui_DestroyContext(context);
    const before = current;
    defer use(before);
    apply(1.5, .{});
    const style = c.ImGui_GetStyle();
    const padding = style.*.FramePadding;
    for ([_]Mode{ .light, .dark, .light }) |mode| {
        use(.{ .mode = mode });
        try std.testing.expectEqual(padding, style.*.FramePadding);
        try std.testing.expectEqual(colors.text, style.*.Colors[c.ImGuiCol_Text]);
    }
}

test "what's on a dark viewer takes the dark palette, and the interface gets its own back" {
    const context = c.ImGui_CreateContext(null);
    defer c.ImGui_DestroyContext(context);
    const before = current;
    defer use(before);
    apply(1, .{ .mode = .light, .dark_viewer = true });
    const on = beginViewer();
    try std.testing.expectEqual(dark.text, colors.text);
    endViewer(on);
    try std.testing.expectEqual(light.text, colors.text);
    use(.{ .mode = .light, .dark_viewer = false });
    const plain = beginViewer();
    try std.testing.expectEqual(light.text, colors.text);
    endViewer(plain);
}
