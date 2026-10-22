//! The look of the interface: a neutral dark grey, so that it doesn't tint how an image is judged,
//! with one amber accent for selection and focus. Values follow the design canvas.

const std = @import("std");
const c = @import("c");

pub const Color = c.ImVec4;

fn hex(value: u24) Color {
    return .{
        .x = @as(f32, @floatFromInt(value >> 16)) / 255,
        .y = @as(f32, @floatFromInt((value >> 8) & 0xff)) / 255,
        .z = @as(f32, @floatFromInt(value & 0xff)) / 255,
        .w = 1,
    };
}

pub const page = hex(0x1D1D1F);
pub const header = hex(0x161617);
pub const panel = hex(0x232325);
pub const control = hex(0x2D2D30);
pub const control_hover = hex(0x36363A);
pub const border = hex(0x3B3B3F);
pub const divider = hex(0x303033);
pub const viewer = hex(0x262626);
pub const text = hex(0xECECEE);
pub const text_secondary = hex(0xB4B4B8);
pub const text_tertiary = hex(0x8F8F95);
pub const accent = hex(0xE8A33D);
pub const accent_fill = hex(0x3A3127);
pub const on_accent = hex(0x1A1206);
pub const ready = hex(0x7FB77E);
pub const histogram_ground = hex(0x1A1A1B);
/// A selected card or row, a step above the panel.
pub const raised = hex(0x2A2A2D);
pub const sprocket = hex(0x4A4A4E);
/// The track of a slider to the right of its thumb.
pub const track = hex(0x5A5A5F);
/// Behind labels drawn over an image.
pub const overlay: Color = .{ .x = 22.0 / 255.0, .y = 22.0 / 255.0, .z = 23.0 / 255.0, .w = 0.8 };
pub const red = hex(0xD9534F);
pub const green = hex(0x5CB85C);
pub const blue = hex(0x4A90D9);

/// `color` with its alpha set to `alpha`.
pub fn withAlpha(color: Color, alpha: f32) Color {
    return .{ .x = color.x, .y = color.y, .z = color.z, .w = alpha };
}

/// `color` as 8-bit RGBA, for pixels.
pub fn rgba8(color: Color) [4]u8 {
    return .{ channel8(color.x), channel8(color.y), channel8(color.z), channel8(color.w) };
}

fn channel8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

pub fn imU32(color: Color) u32 {
    return c.ImGui_ColorConvertFloat4ToU32(color);
}

/// Sets ImGui's style to the design, at `scale` (the display's content scale).
pub fn apply(scale: f32) void {
    const style = c.ImGui_GetStyle();
    style.*.WindowPadding = .{ .x = 12, .y = 12 };
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

    const colors = &style.*.Colors;
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
