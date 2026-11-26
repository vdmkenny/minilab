//! Small helpers on top of Dear ImGui's C API: text from slices, strings that last for one frame,
//! sizes in the design's pixels, and the design's own controls built out of ImGui's.

const std = @import("std");
const c = @import("c");
const theme = @import("theme.zig");
const icons = @import("icons.zig");
const i18n = @import("../i18n/i18n.zig");
const date = @import("minilab").date;
const Date = date.Date;
const fonts = @import("fonts.zig");

pub const Vec2 = c.ImVec2;

/// The display's scale, which converts the design's pixels into ImGui's.
pub var scale: f32 = 1;

var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

/// Frees the strings made during the last frame.
pub fn newFrame() void {
    _ = frame_arena.reset(.retain_capacity);
}

/// Memory that lasts for this frame, for things worked out to draw it.
pub fn frameAllocator() std.mem.Allocator {
    return frame_arena.allocator();
}

pub fn px(value: f32) f32 {
    return value * scale;
}

pub fn vec2(x: f32, y: f32) Vec2 {
    return .{ .x = x, .y = y };
}

/// Which way `turnSince` turns what was drawn: to read upwards, or downwards.
pub const Turn = enum { up, down };

/// Turns everything drawn into `list` since its vertex `first` a quarter turn about `pivot`. Text
/// is drawn level first, then turned, since ImGui only draws it level.
pub fn turnSince(list: *c.ImDrawList, first: c_int, pivot: Vec2, turn: Turn) void {
    const vertices = list.*.VtxBuffer.Data;
    var i = first;
    while (i < list.*.VtxBuffer.Size) : (i += 1) {
        const v = &vertices[@intCast(i)];
        const dx = v.pos.x - pivot.x;
        const dy = v.pos.y - pivot.y;
        v.pos = switch (turn) {
            .up => vec2(pivot.x + dy, pivot.y - dx),
            .down => vec2(pivot.x - dy, pivot.y + dx),
        };
    }
}

/// A line of text that's kept between frames, and cut short when it doesn't fit.
pub fn Line(comptime capacity: usize) type {
    return struct {
        buffer: [capacity]u8 = undefined,
        len: usize = 0,

        pub fn set(l: *@This(), comptime format: []const u8, args: anytype) void {
            l.len = (std.fmt.bufPrint(&l.buffer, format, args) catch @as([]u8, &l.buffer)).len;
        }

        pub fn text(l: *const @This()) []const u8 {
            return l.buffer[0..l.len];
        }
    };
}

/// A translated message, `template`, with its `{0}`-style placeholders filled from `values`, for
/// this frame (see i18n.zig).
pub fn say(template: [:0]const u8, values: anytype) [:0]const u8 {
    return i18n.format(frame_arena.allocator(), template, values) catch template;
}

/// Formats a string that lasts for this frame, ending in a NUL for ImGui.
pub fn print(comptime format: []const u8, args: anytype) [:0]const u8 {
    return std.fmt.allocPrintSentinel(frame_arena.allocator(), format, args, 0) catch "";
}

/// Shortens `value` from the start with an ellipsis until it fits in `width`. Good for paths,
/// where the end says the most.
pub fn elideStart(value: []const u8, width: f32) [:0]const u8 {
    return elide(.start, value, width, textWidth);
}

/// Shortens `value` at the end with an ellipsis until it fits in `width`.
pub fn elideEnd(value: []const u8, width: f32) [:0]const u8 {
    return elide(.end, value, width, textWidth);
}

fn textWidth(value: [:0]const u8) f32 {
    return c.ImGui_CalcTextSize(value).x;
}

/// Shortens `value` with an ellipsis at `side` until `measure` says it fits in `width`, without
/// cutting a UTF-8 sequence.
fn elide(side: enum { start, end }, value: []const u8, width: f32, comptime measure: fn ([:0]const u8) f32) [:0]const u8 {
    var start: usize = 0;
    var end = value.len;
    var shown = print("{s}", .{value});
    while (start < end and measure(shown) > width) {
        switch (side) {
            .start => {
                start += 1;
                while (start < end and isContinuation(value[start])) start += 1;
                shown = print("…{s}", .{value[start..]});
            },
            .end => {
                end -= 1;
                while (end > start and isContinuation(value[end])) end -= 1;
                shown = print("{s}…", .{value[0..end]});
            },
        }
    }
    return shown;
}

/// Whether `byte` continues a UTF-8 sequence rather than starting one.
fn isContinuation(byte: u8) bool {
    return byte & 0xc0 == 0x80;
}

pub fn text(value: []const u8) void {
    c.ImGui_TextUnformattedEx(value.ptr, value.ptr + value.len);
}

pub fn textColored(color: theme.Color, value: []const u8) void {
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Text, color);
    text(value);
    c.ImGui_PopStyleColor();
}

/// Text that wraps at the edge of the panel.
pub fn paragraph(color: theme.Color, value: []const u8) void {
    c.ImGui_PushTextWrapPos(0);
    textColored(color, value);
    c.ImGui_PopTextWrapPos();
}

/// A section heading, as in the design: 12 pixels, semibold, in the secondary colour. The design
/// writes headings in capitals, and so do the callers.
/// The gap after a section heading's icon, in the design's pixels.
const heading_icon_gap = 8;

/// A section's heading that opens and closes it: its `icon` and `name`, with a chevron at the
/// right of its line, pointing down while it's open. The whole line opens and closes it. `id`
/// names it for ImGui.
pub fn foldingHeading(id: [:0]const u8, icon: icons.Icon, name: []const u8, open: *bool) void {
    const start = c.ImGui_GetCursorScreenPos();
    const width = c.ImGui_GetContentRegionAvail().x;
    const height = c.ImGui_GetFrameHeight();
    if (c.ImGui_InvisibleButton(id, vec2(width, height), 0)) open.* = !open.*;
    const lit = c.ImGui_IsItemHovered(0);
    const ink = if (lit) theme.colors.text else theme.colors.text_secondary;
    drawIcon(icon, vec2(start.x + px(icon_size) / 2, start.y + height / 2), ink);
    fonts.pushSized(.semibold, fonts.small_size);
    textIn(c.ImGui_GetWindowDrawList(), start.x + px(icon_size + heading_icon_gap), start.y, height, ink, name);
    fonts.pop();
    drawFold(open.*, vec2(start.x + width - px(icon_size) / 2, start.y + height / 2), lit);
}

/// A section's heading that's a check box, turning the section's work on and off, with its `icon`
/// before it and the chevron that opens and closes it at the right. Returns true when the box
/// was clicked.
pub fn checkboxHeading(icon: icons.Icon, label: [:0]const u8, checked: *bool, open: *bool) bool {
    const x = c.ImGui_GetCursorPosX();
    c.ImGui_SetCursorPosX(x + px(icon_size + heading_icon_gap));
    fonts.pushSized(.semibold, fonts.small_size);
    const toggled = checkbox(label, checked);
    fonts.pop();
    const min = c.ImGui_GetItemRectMin();
    const max = c.ImGui_GetItemRectMax();
    drawIcon(icon, vec2(min.x - px(heading_icon_gap) - px(icon_size) / 2, (min.y + max.y) / 2), theme.colors.text_secondary);
    foldButton("##fold", open, min.y, max.y - min.y);
    return toggled;
}

/// The chevron that opens and closes a section, on its own, for a heading that's something else,
/// like a check box: at the right of the line that runs from `top` (on screen) and is `height`
/// high. The cursor goes back to where it was.
pub fn foldButton(id: [:0]const u8, open: *bool, top: f32, height: f32) void {
    const was = c.ImGui_GetCursorScreenPos();
    defer c.ImGui_SetCursorScreenPos(was);
    const side = c.ImGui_GetFrameHeight();
    const right = was.x + c.ImGui_GetContentRegionAvail().x;
    c.ImGui_SetCursorScreenPos(vec2(right - side, top + (height - side) / 2));
    if (c.ImGui_InvisibleButton(id, vec2(side, side), 0)) open.* = !open.*;
    drawFold(open.*, vec2(right - px(icon_size) / 2, top + height / 2), c.ImGui_IsItemHovered(0));
}

/// The room `foldButton` takes at the right of a line, for what goes before it.
pub fn foldSpace() f32 {
    return c.ImGui_GetFrameHeight() + px(label_gap);
}

fn drawFold(open: bool, centre: Vec2, lit: bool) void {
    drawIcon(if (open) .chevron_down else .chevron_right, centre, if (lit) theme.colors.text else theme.colors.text_tertiary);
}

pub fn heading(value: []const u8) void {
    fonts.pushSized(.semibold, fonts.small_size);
    textColored(theme.colors.text_secondary, value);
    fonts.pop();
}

// Text on a draw list, for panels laid out by hand.

/// The design's line height, as a multiple of the text size.
pub const line_spacing = 1.4;
/// A section heading's text size, in the design's pixels.
pub const heading_size = fonts.small_size;

/// The height of a line of text `size` design pixels high.
pub fn lineFor(size: f32) f32 {
    return px(size * line_spacing);
}

/// The height of a line in the current font.
pub fn lineHeight() f32 {
    return c.ImGui_GetFontSize() * line_spacing;
}

/// Draws `text` in the current font, centred in a line box `height` high with its top left at
/// `x`, `y`.
pub fn textIn(list: *c.ImDrawList, x: f32, y: f32, height: f32, color: theme.Color, value: []const u8) void {
    c.ImDrawList_AddText(list, vec2(x, y + (height - c.ImGui_GetFontSize()) / 2), theme.imU32(color), print("{s}", .{value}));
}

/// Draws `text` on one line in the current font, at the design's line height. Returns the line's
/// height.
pub fn lineAt(list: *c.ImDrawList, x: f32, y: f32, color: theme.Color, value: []const u8) f32 {
    textIn(list, x, y, lineHeight(), color, value);
    return lineHeight();
}

/// A section heading on a draw list, like `heading`. Returns its height.
pub fn headingAt(list: *c.ImDrawList, x: f32, y: f32, value: []const u8) f32 {
    fonts.pushSized(.semibold, heading_size);
    defer fonts.pop();
    return lineAt(list, x, y, theme.colors.text_secondary, value);
}

/// The most lines a paragraph wraps to.
const max_lines = 16;

/// Splits `value` into the lines it wraps to at `width` in the current font, as ImGui wraps
/// words.
pub fn wrapLines(value: []const u8, width: f32, buffer: [][]const u8) [][]const u8 {
    const font = c.ImGui_GetFont();
    const size = c.ImGui_GetFontSize();
    var n: usize = 0;
    var rest = std.mem.trim(u8, value, " ");
    while (rest.len > 0 and n < buffer.len) {
        const start: [*]const u8 = rest.ptr;
        const end = c.ImFont_CalcWordWrapPosition(font, size, start, start + rest.len, width);
        var cut: usize = @intFromPtr(end) - @intFromPtr(start);
        if (cut == 0) cut = rest.len;
        buffer[n] = std.mem.trimEnd(u8, rest[0..cut], " ");
        n += 1;
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    return buffer[0..n];
}

/// The height of `value` wrapped at `width`, at the design's line height.
pub fn paragraphHeight(value: []const u8, width: f32) f32 {
    var buffer: [max_lines][]const u8 = undefined;
    return @as(f32, @floatFromInt(wrapLines(value, width, &buffer).len)) * lineHeight();
}

/// Draws `value` wrapped at `width`, at the design's line height. Returns its height.
pub fn paragraphAt(list: *c.ImDrawList, x: f32, y: f32, width: f32, color: theme.Color, value: []const u8) f32 {
    var buffer: [max_lines][]const u8 = undefined;
    const lines = wrapLines(value, width, &buffer);
    for (lines, 0..) |l, i| _ = lineAt(list, x, y + @as(f32, @floatFromInt(i)) * lineHeight(), color, l);
    return @as(f32, @floatFromInt(lines.len)) * lineHeight();
}

/// A page or panel title: `size` pixels, semibold.
pub fn title(value: []const u8, size: f32) void {
    fonts.pushSized(.semibold, size);
    text(value);
    fonts.pop();
}

/// How a button looks.
pub const Kind = enum {
    /// Grey, with a border. Most buttons are this kind.
    normal,
    /// Amber, for the one main action on a page.
    primary,
    /// A border only.
    outline,
    /// A border only, with secondary text, for the less important actions.
    secondary,
    /// The chosen one in a set of choices: an amber border on a dark amber fill.
    selected,
    /// An unchosen one in a set of choices: grey, with secondary text.
    unselected,
    /// No fill or border until it's hovered, for icons and grouped choices.
    quiet,
};

/// A button of `kind`. `size` is in the design's pixels, and 0 means fit the label (or, for the
/// height, use a control's usual height).
pub fn buttonOf(kind: Kind, label: [:0]const u8, size: Vec2) bool {
    const colours: struct { fill: theme.Color, hover: theme.Color, line: theme.Color, ink: theme.Color } = switch (kind) {
        .normal => .{ .fill = theme.colors.control, .hover = theme.colors.control_hover, .line = theme.colors.border, .ink = theme.colors.text },
        .primary => .{ .fill = theme.colors.accent, .hover = theme.colors.accent, .line = theme.withAlpha(theme.colors.accent, 0), .ink = theme.colors.on_accent },
        .outline => .{ .fill = theme.withAlpha(theme.colors.page, 0), .hover = theme.colors.control_hover, .line = theme.colors.border, .ink = theme.colors.text },
        .secondary => .{ .fill = theme.withAlpha(theme.colors.page, 0), .hover = theme.colors.control_hover, .line = theme.colors.border, .ink = theme.colors.text_secondary },
        .selected => .{ .fill = theme.colors.accent_fill, .hover = theme.colors.accent_fill, .line = theme.colors.accent, .ink = theme.colors.text },
        .unselected => .{ .fill = theme.colors.control, .hover = theme.colors.control_hover, .line = theme.colors.border, .ink = theme.colors.text_secondary },
        .quiet => .{ .fill = theme.withAlpha(theme.colors.page, 0), .hover = theme.colors.control_hover, .line = theme.withAlpha(theme.colors.page, 0), .ink = theme.colors.text_secondary },
    };
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, colours.fill);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, colours.hover);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, colours.hover);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Border, colours.line);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Text, colours.ink);
    defer c.ImGui_PopStyleColorEx(5);
    if (kind == .primary) fonts.push(.semibold);
    defer if (kind == .primary) fonts.pop();
    return c.ImGui_ButtonEx(label.ptr, vec2(px(size.x), px(size.y)));
}

pub fn button(label: [:0]const u8) bool {
    return buttonOf(.normal, label, vec2(0, 0));
}

/// A dialog's padding, and the gap between its parts, in the design's pixels.
pub const dialog = struct {
    pub const padding_x = 20;
    pub const padding_y = 16;
    pub const gap = 8;
};

/// Opens the modal dialog `id` in the middle of the window, sized to what it holds. When it
/// returns true, draw the dialog and then call `c.ImGui_EndPopup`. It returns false once the
/// dialog has closed.
pub fn beginDialog(id: [:0]const u8) bool {
    dimBehindDialog();
    if (!c.ImGui_IsPopupOpen(id, 0)) _ = c.ImGui_OpenPopup(id, 0);
    // Centred every frame: a dialog sizes itself to what it shows, which can change while it's
    // open, and on its first frame its size isn't known yet.
    c.ImGui_SetNextWindowPosEx(c.ImGuiViewport_GetCenter(c.ImGui_GetMainViewport()), c.ImGuiCond_Always, vec2(0.5, 0.5));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, vec2(px(dialog.padding_x), px(dialog.padding_y)));
    defer c.ImGui_PopStyleVar();
    return c.ImGui_BeginPopupModal(id, null, c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoTitleBar);
}

/// Dims the app behind a dialog, fully from the dialog's first frame. It's a window of its own
/// over the app: dialogs always draw above it, and it takes no clicks. Call it each frame the
/// dialog is open, before the dialog.
pub fn dimBehindDialog() void {
    const viewport = c.ImGui_GetMainViewport();
    c.ImGui_SetNextWindowPos(viewport.*.Pos, c.ImGuiCond_Always);
    c.ImGui_SetNextWindowSize(viewport.*.Size, c.ImGuiCond_Always);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_WindowBg, theme.dialog_dim);
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 0);
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowRounding, 0);
    defer c.ImGui_PopStyleVarEx(2);
    defer c.ImGui_PopStyleColor();
    const flags = c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoInputs | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoSavedSettings | c.ImGuiWindowFlags_NoFocusOnAppearing | c.ImGuiWindowFlags_NoNav;
    _ = c.ImGui_Begin("##dim", null, flags);
    c.ImGui_End();
}

/// Opens `url` in the browser, or for a `file://` URL, in the file manager.
pub fn openUrl(url: []const u8) void {
    if (!c.SDL_OpenURL(print("{s}", .{url}))) std.log.err("can't open {s}: {s}", .{ url, c.SDL_GetError() });
}

/// The gap between "No roll open" and its button, in the design's pixels.
const no_roll_gap = 14;
/// The height of a button that fits its label, and of a dialog's buttons, in the design's pixels.
pub const button_height = 32;
/// The padding either side of a button's label, in the design's pixels.
pub const button_padding = 12;
/// A control's border, in the design's pixels.
const border = 1;

/// The width of a button that fits `label`, with `padding` either side of it (in the design's
/// pixels) and its border, in screen pixels.
pub fn fittedWidth(label: [:0]const u8, padding: f32) f32 {
    return c.ImGui_CalcTextSize(label).x + px(2 * padding + 2 * border);
}

/// Draws "No roll open" at `at` with a Go to Rolls button under it, for a page that needs a roll.
/// Returns true when the button is clicked.
pub fn noRoll(at: Vec2) bool {
    const list = c.ImGui_GetWindowDrawList();
    const text_y = at.y + emptySpool(list, at);
    const height = lineAt(list, at.x, text_y, theme.colors.text_secondary, i18n.t.gui.no_roll_open);
    c.ImGui_SetCursorScreenPos(vec2(at.x, text_y + height + px(no_roll_gap)));
    const label = i18n.t.gui.go_to_rolls;
    return buttonOf(.normal, label, vec2(fittedWidth(label, button_padding) / scale, button_height));
}

/// Corner radii, in the design's pixels: controls and cards, the choices inside a box of them,
/// check boxes and small marks, and slider tracks and bars.
pub const control_rounding = 5;
pub const choice_rounding = 4;
pub const box_rounding = 3;
pub const track_rounding = 2;

/// A segmented box: the space around its choices, their height, and the padding either side of
/// each label.
const segmented_padding = 2;
const segmented_height = 26;
const segmented_label_padding = 10;
/// A segmented box's height, with its border.
pub const segmented_box_height = segmented_height + 2 * segmented_padding + 2 * border;

/// A set of choices in one grey box with the chosen one marked, like the viewer's Split /
/// Negative / Positive. Returns the one that was clicked.
pub fn segmented(id: [:0]const u8, labels: []const [:0]const u8, chosen: usize) ?usize {
    const Labels = struct {
        labels: []const [:0]const u8,
        fn width(l: @This(), i: usize) f32 {
            return c.ImGui_CalcTextSize(l.labels[i].ptr).x + px(2 * segmented_label_padding);
        }
        fn button(l: @This(), i: usize, kind: Kind, size: Vec2) bool {
            return buttonOf(kind, l.labels[i], size);
        }
    };
    return segmentedBox(id, labels.len, chosen, Labels{ .labels = labels });
}

/// A choice in `iconSegmented`: its icon, and its name for the tooltip.
pub const IconChoice = struct { icon: icons.Icon, name: [:0]const u8 };

/// A square button with `icon` on it, for actions with a well-known icon. `id` is also its name
/// for screen readers. The icon is lit while the button is hovered or `kind` is `.selected`, and
/// dimmed with the button when it's disabled.
pub fn iconButton(id: [:0]const u8, kind: Kind, icon: icons.Icon) bool {
    const side = c.ImGui_GetFrameHeight();
    const corner = c.ImGui_GetCursorScreenPos();
    const clicked = buttonOf(kind, print("##{s}", .{id}), vec2(side / scale, side / scale));
    const lit = kind == .selected or c.ImGui_IsItemHovered(0);
    drawIcon(icon, vec2(corner.x + side / 2, corner.y + side / 2), if (lit) theme.colors.text else theme.colors.text_secondary);
    return clicked;
}

/// The size of an icon on a button, in the design's pixels.
pub const icon_size = 16;

/// Draws `icon` at the size buttons use, centred on `centre`, faded with the item when it's
/// disabled: ImGui fades disabled items through the style's alpha, which a draw list doesn't use.
/// The spool over an empty page, in the design's pixels: its size and the gap under it.
const spool_size = 32;
const spool_gap = 12;

/// Draws a spool with its top left at `at`, over the message on a page with no roll or no rolls.
/// Returns the height it takes, with the gap under it.
pub fn emptySpool(list: *c.ImDrawList, at: Vec2) f32 {
    const size = px(spool_size);
    icons.draw(list, .spool, vec2(at.x + size / 2, at.y + size / 2), size, theme.colors.text_tertiary);
    return size + px(spool_gap);
}

/// The gap between a filter's funnel and its drop-down, in the design's pixels.
pub const filter_icon_gap = 6;
/// How much room a funnel before a filter takes, with its gap, in the design's pixels.
pub const filter_icon_space = icon_size + filter_icon_gap;

/// Draws a funnel before a filter's drop-down, at the cursor, and leaves the cursor after it on
/// the same line. `height` is the drop-down's height.
pub fn filterIcon(height: f32) void {
    const at = c.ImGui_GetCursorScreenPos();
    drawIcon(.funnel, vec2(at.x + px(icon_size) / 2, at.y + height / 2), theme.colors.text_tertiary);
    c.ImGui_SetCursorScreenPos(vec2(at.x + px(filter_icon_space), at.y));
}

pub fn drawIcon(icon: icons.Icon, centre: Vec2, colour: theme.Color) void {
    icons.draw(c.ImGui_GetWindowDrawList(), icon, centre, px(icon_size), theme.withAlpha(colour, colour.w * c.ImGui_GetStyle().*.Alpha));
}

/// The width of a choice in `iconSegmented`, in the design's pixels.
const icon_choice_width = 36;

/// `segmented` with an icon for each choice instead of a label, and its name as a tooltip.
pub fn iconSegmented(id: [:0]const u8, choices: []const IconChoice, chosen: usize) ?usize {
    const Icons = struct {
        choices: []const IconChoice,
        chosen: usize,
        fn width(_: @This(), _: usize) f32 {
            return px(icon_choice_width);
        }
        fn button(set: @This(), i: usize, kind: Kind, size: Vec2) bool {
            const choice = set.choices[i];
            const clicked = buttonOf(kind, print("##{s}", .{choice.name}), size);
            tooltip(choice.name);
            const min = c.ImGui_GetItemRectMin();
            const max = c.ImGui_GetItemRectMax();
            const ink = if (i == set.chosen) theme.colors.accent else if (c.ImGui_IsItemHovered(0)) theme.colors.text else theme.colors.text_secondary;
            drawIcon(choice.icon, vec2((min.x + max.x) / 2, (min.y + max.y) / 2), ink);
            return clicked;
        }
    };
    return segmentedBox(id, choices.len, chosen, Icons{ .choices = choices, .chosen = chosen });
}

/// The box `segmented` and `iconSegmented` share: `count` choices, sized and drawn by `content`'s
/// `width` and `button`.
fn segmentedBox(id: [:0]const u8, count: usize, chosen: usize, content: anytype) ?usize {
    c.ImGui_PushID(id.ptr);
    defer c.ImGui_PopID();
    // The box's border, one screen pixel, then its padding, on every side.
    const line = 1;
    const inset = line + px(segmented_padding);
    const pill_height = px(segmented_height);
    var width: f32 = 2 * inset;
    for (0..count) |i| width += content.width(i);
    const origin = c.ImGui_GetCursorScreenPos();
    const list = c.ImGui_GetWindowDrawList();
    const box_height = pill_height + 2 * inset;
    c.ImDrawList_AddRectFilledEx(list, origin, vec2(origin.x + width, origin.y + box_height), theme.imU32(theme.colors.control), px(control_rounding), 0);
    c.ImDrawList_AddRectEx(list, origin, vec2(origin.x + width, origin.y + box_height), theme.imU32(theme.colors.border), px(control_rounding), line, 0);
    var clicked: ?usize = null;
    var x = origin.x + inset;
    for (0..count) |i| {
        const w = content.width(i);
        c.ImGui_SetCursorScreenPos(vec2(x, origin.y + inset));
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, vec2(px(segmented_label_padding), (pill_height - c.ImGui_GetFontSize()) / 2));
        c.ImGui_PushStyleVar(c.ImGuiStyleVar_FrameRounding, px(choice_rounding));
        if (content.button(i, if (i == chosen) .selected else .quiet, vec2(w / scale, segmented_height))) clicked = i;
        c.ImGui_PopStyleVarEx(2);
        x += w;
    }
    c.ImGui_SetCursorScreenPos(origin);
    c.ImGui_Dummy(vec2(width, box_height));
    return clicked;
}

/// Where the controls of a labelled row start: after a 96-pixel label column and a 10-pixel gap.
pub const label_column = 96;
pub const label_gap = 10;
/// The width of the value column after a slider.
pub const value_column = 52;
/// The reset button after a slider's value: its size, and the room it takes up including its gap.
pub const reset_size = 14;
pub const reset_space = reset_size + 6;
/// The size of the reset button's icon.
const reset_icon_size = 12;

/// Starts a row of a settings grid: draws `label` in the label column, then moves the cursor to
/// where the control goes.
/// The gap after a warning's icon, in the design's pixels.
const warning_gap = 6;

/// A warning under a row's control, lined up with it: an amber triangle and a short message.
pub fn warning(message: [:0]const u8) void {
    c.ImGui_SetCursorPosX(c.ImGui_GetCursorPosX() + px(label_column + label_gap));
    const at = c.ImGui_GetCursorScreenPos();
    const icon = px(icon_size);
    drawIcon(.triangle_alert, vec2(at.x + icon / 2, at.y + c.ImGui_GetTextLineHeight() / 2), theme.colors.accent);
    c.ImGui_SetCursorScreenPos(vec2(at.x + icon + px(warning_gap), at.y));
    textColored(theme.colors.accent, message);
}

pub fn rowLabel(label: []const u8) void {
    const x = c.ImGui_GetCursorPosX();
    c.ImGui_AlignTextToFramePadding();
    textColored(theme.colors.text_secondary, label);
    c.ImGui_SameLineEx(x + px(label_column + label_gap), 0);
}

/// How long a drop-down's list gets before it scrolls.
pub const ListHeight = enum {
    /// `regular_list_rows` rows.
    regular,
    /// As tall as the screen allows, up to `tall_list_height`.
    tall,
};

/// The tallest a tall drop-down list gets, in the design's pixels.
const tall_list_height = 360;
/// How many rows a regular drop-down list shows before it scrolls, as ImGui's own lists do.
const regular_list_rows = 8;

/// A drop-down list's padding, and the space between its rows, in the design's pixels. The list
/// keeps these wherever the drop-down sits, whatever spacing the layout around it uses.
const list_padding_x = 10;
const list_padding_y = 6;
const list_row_gap = 10;

/// Opens a drop-down `width` wide in the design's pixels (0 fills the row), showing `preview`. It
/// has a small chevron, like a native drop-down, instead of ImGui's arrow button. When it returns
/// true, add the list's items and then call `endCombo`.
pub fn beginCombo(id: []const u8, preview: []const u8, width: f32, height: ListHeight) bool {
    c.ImGui_SetNextItemWidth(if (width == 0) -std.math.floatMin(f32) else px(width));
    // Where the drop-down goes, for its chevron. Once the list is open, ImGui's last item is the
    // list's window instead.
    const list = c.ImGui_GetWindowDrawList();
    const min = c.ImGui_GetCursorScreenPos();
    const max = vec2(min.x + c.ImGui_CalcItemWidth(), min.y + c.ImGui_GetFrameHeight());
    // ImGui would size the list from the spacing around the drop-down, not the list's own.
    const row = c.ImGui_GetFontSize() + px(list_row_gap);
    const tallest = switch (height) {
        .regular => regular_list_rows * row - px(list_row_gap) + 2 * px(list_padding_y),
        .tall => px(tall_list_height),
    };
    c.ImGui_SetNextWindowSizeConstraints(vec2(0, 0), vec2(std.math.floatMax(f32), tallest), null, null);
    const flags: c.ImGuiComboFlags = c.ImGuiComboFlags_NoArrowButton;
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, vec2(px(list_padding_x), px(list_padding_y)));
    const open = c.ImGui_BeginCombo(print("##{s}", .{id}).ptr, print("{s}", .{preview}).ptr, flags);
    chevron(list, min, max);
    if (!open) {
        c.ImGui_PopStyleVar();
        return false;
    }
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, vec2(px(list_row_gap), px(list_row_gap)));
    return true;
}

/// Closes the list of a drop-down that `beginCombo` opened.
pub fn endCombo() void {
    c.ImGui_EndCombo();
    c.ImGui_PopStyleVarEx(2);
}

/// A drop-down of `items`, `width` wide in the design's pixels (0 fills the row). Returns the
/// chosen index when it changes.
pub fn combo(id: [:0]const u8, items: []const []const u8, chosen: usize, width: f32) ?usize {
    if (!beginCombo(id, if (chosen < items.len) items[chosen] else "", width, .regular)) return null;
    defer endCombo();
    var picked: ?usize = null;
    for (items, 0..) |item, i| {
        c.ImGui_PushIDInt(@intCast(i));
        if (c.ImGui_SelectableEx(print("{s}", .{item}).ptr, i == chosen, 0, vec2(0, 0))) picked = i;
        // The list opens scrolled to the choice.
        if (i == chosen) c.ImGui_SetItemDefaultFocus();
        c.ImGui_PopID();
    }
    return picked;
}

/// The most choices `comboOf` and `segmentedOf` take.
const max_choices = 64;

/// A drop-down of `choices`, each labelled by `labelOf`, showing `chosen`. Returns the choice
/// picked.
pub fn comboOf(comptime T: type, id: [:0]const u8, choices: []const T, chosen: T, comptime labelOf: fn (T) []const u8, width: f32) ?T {
    var labels: [max_choices][]const u8 = undefined;
    for (labels[0..choices.len], choices) |*label, choice| label.* = labelOf(choice);
    const picked = combo(id, labels[0..choices.len], indexIn(T, choices, chosen), width) orelse return null;
    return choices[picked];
}

/// A `segmented` set of `choices`, each labelled by `labelOf`, with `chosen` marked. Returns the
/// choice clicked.
pub fn segmentedOf(comptime T: type, id: [:0]const u8, choices: []const T, chosen: T, comptime labelOf: fn (T) [:0]const u8) ?T {
    var labels: [max_choices][:0]const u8 = undefined;
    for (labels[0..choices.len], choices) |*label, choice| label.* = labelOf(choice);
    const picked = segmented(id, labels[0..choices.len], indexIn(T, choices, chosen)) orelse return null;
    return choices[picked];
}

/// Where `value` is in `choices`, or past the end when it isn't there, so nothing shows as chosen.
pub fn indexIn(comptime T: type, choices: []const T, value: T) usize {
    std.debug.assert(choices.len <= max_choices);
    return std.mem.indexOfScalar(T, choices, value) orelse choices.len;
}

/// What's typed into the open searchable drop-down. Only one can be open at a time.
var search_buffer: [64:0]u8 = @splat(0);

/// A drop-down of `items` with a search field at the top, for long lists such as film stocks.
/// An item matches when it contains every word typed, ignoring case. Enter picks the first match.
/// Returns the chosen index when it changes.
pub fn searchCombo(id: [:0]const u8, items: []const []const u8, chosen: usize, width: f32, hint: [:0]const u8) ?usize {
    if (!beginCombo(id, if (chosen < items.len) items[chosen] else "", width, .tall)) return null;
    defer endCombo();
    if (c.ImGui_IsWindowAppearing()) {
        search_buffer = @splat(0);
        c.ImGui_SetKeyboardFocusHere();
    }
    c.ImGui_SetNextItemWidth(-std.math.floatMin(f32));
    const entered = c.ImGui_InputTextWithHint("##search", hint.ptr, &search_buffer, search_buffer.len + 1, c.ImGuiInputTextFlags_EnterReturnsTrue);
    const query = std.mem.sliceTo(&search_buffer, 0);
    var picked: ?usize = null;
    var first: ?usize = null;
    for (items, 0..) |item, i| {
        if (!matchesWords(item, query)) continue;
        if (first == null) first = i;
        c.ImGui_PushIDInt(@intCast(i));
        if (c.ImGui_SelectableEx(print("{s}", .{item}).ptr, i == chosen, 0, vec2(0, 0))) picked = i;
        c.ImGui_PopID();
    }
    if (first == null) textColored(theme.colors.text_tertiary, i18n.t.gui.no_matches);
    if (entered and picked == null) {
        if (first) |i| {
            picked = i;
            c.ImGui_CloseCurrentPopup();
        }
    }
    return picked;
}

test "Tab completes to the first suggestion that starts with what's typed" {
    const suggestions = [_][]const u8{ "Pentax MX", "Pentax 67", "Nikon F3" };
    try std.testing.expectEqualStrings("Pentax MX", completionOf(&suggestions, "pen").?);
    try std.testing.expectEqualStrings("Pentax 67", completionOf(&suggestions, "Pentax 6").?);
    try std.testing.expectEqual(@as(?[]const u8, null), completionOf(&suggestions, "Nikon F3"));
    try std.testing.expectEqual(@as(?[]const u8, null), completionOf(&suggestions, "Leica"));
}

/// Whether every space-separated word of `query` appears in `item`, ignoring case.
fn matchesWords(item: []const u8, query: []const u8) bool {
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |word| {
        if (!containsIgnoreCase(item, word)) return false;
    }
    return true;
}

pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

/// A drop-down's chevron: where its tip is, in from the right and down from the middle, how far
/// its arms reach each way, and their thickness.
const chevron_inset = 14;
const chevron_drop = 2.5;
const chevron_arm = 4;
const chevron_thickness = 1.5;

/// Draws a drop-down's small chevron at the right of the drop-down from `min` to `max`, into
/// `list`.
fn chevron(list: *c.ImDrawList, min: Vec2, max: Vec2) void {
    const middle = (min.y + max.y) / 2;
    const tip = vec2(max.x - px(chevron_inset), middle + px(chevron_drop));
    const ink = theme.imU32(theme.colors.text_secondary);
    const arm = px(chevron_arm);
    c.ImDrawList_AddLineEx(list, vec2(tip.x - arm, tip.y - arm), tip, ink, px(chevron_thickness), 0);
    c.ImDrawList_AddLineEx(list, tip, vec2(tip.x + arm, tip.y - arm), ink, px(chevron_thickness), 0);
}

/// Draws a ticked check box, `size` pixels square, at `min`: amber, with the design's tick.
pub fn tickedBox(list: *c.ImDrawList, min: Vec2, size: f32) void {
    // The design draws its 12-pixel tick in a 16-pixel box: M2.5 6.5 l2.5 2.5 4.5 −5.5.
    const design_box = 16;
    const max = vec2(min.x + size, min.y + size);
    c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(theme.colors.accent), px(box_rounding), 0);
    const unit = size / design_box;
    const o = vec2(min.x + 2 * unit, min.y + 2 * unit);
    const points = [_]Vec2{
        vec2(o.x + 2.5 * unit, o.y + 6.5 * unit),
        vec2(o.x + 5 * unit, o.y + 9 * unit),
        vec2(o.x + 9.5 * unit, o.y + 3.5 * unit),
    };
    c.ImDrawList_AddPolyline(list, &points, points.len, theme.imU32(theme.colors.on_accent), 1.8 * unit, 0);
}

/// Draws a check box `size` square at `min`: ticked, or empty and lighter while `hovered`.
pub fn checkBox(list: *c.ImDrawList, min: Vec2, size: f32, checked: bool, hovered: bool) void {
    if (checked) return tickedBox(list, min, size);
    const max = vec2(min.x + size, min.y + size);
    c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(if (hovered) theme.colors.control_hover else theme.colors.control), px(box_rounding), 0);
    c.ImDrawList_AddRectEx(list, min, max, theme.imU32(theme.colors.border), px(box_rounding), 1, 0);
}

/// How a check box with a label is laid out.
pub const CheckboxOptions = struct {
    /// The gap between the box and the label, in the design's pixels.
    gap: f32 = 6,
    /// The row's height, or null for a control's height.
    height: ?f32 = null,
    /// The label's colour, or null for the secondary text colour.
    label_color: ?theme.Color = null,
};

/// The size of a check box with a label, in the design's pixels.
const checkbox_size = 14;

/// A small check box with its label, drawn the way the design draws one. Returns true when it was
/// clicked.
pub fn checkbox(label: [:0]const u8, checked: *bool) bool {
    return checkboxWith(label, checked, .{});
}

pub fn checkboxWith(label: [:0]const u8, checked: *bool, options: CheckboxOptions) bool {
    const box = px(checkbox_size);
    const label_size = c.ImGui_CalcTextSize(label.ptr);
    const height = options.height orelse c.ImGui_GetFrameHeight();
    const origin = c.ImGui_GetCursorScreenPos();
    const clicked = c.ImGui_InvisibleButton(label.ptr, vec2(box + px(options.gap) + label_size.x, height), 0);
    if (clicked) checked.* = !checked.*;
    const list = c.ImGui_GetWindowDrawList();
    const min = vec2(origin.x, origin.y + (height - box) / 2);
    checkBox(list, min, box, checked.*, c.ImGui_IsItemHovered(0));
    c.ImDrawList_AddText(list, vec2(min.x + box + px(options.gap), origin.y + (height - label_size.y) / 2), theme.imU32(options.label_color orelse theme.colors.text_secondary), label.ptr);
    return clicked;
}

/// How many bytes a one-line text field holds.
pub const text_capacity = 128;

/// Makes a text field's buffer, holding `value` to start with.
pub fn initText(comptime capacity: usize, comptime value: []const u8) [capacity:0]u8 {
    var buffer: [capacity:0]u8 = @splat(0);
    @memcpy(buffer[0..value.len], value);
    return buffer;
}

/// Puts `value` into a text field's buffer. If it doesn't fit, the buffer stays as it was, because
/// a path or name that's cut short would be wrong.
pub fn setText(buffer: [:0]u8, value: []const u8) error{TooLong}!void {
    if (value.len > buffer.len) return error.TooLong;
    @memcpy(buffer[0..value.len], value);
    buffer[value.len] = 0;
}

/// A text field `width` wide in the design's pixels (0 fills the row), with `hint` shown while
/// it's empty.
pub fn textField(id: [:0]const u8, buffer: anytype, hint: [:0]const u8, width: f32) bool {
    c.ImGui_SetNextItemWidth(if (width == 0) -std.math.floatMin(f32) else px(width));
    return c.ImGui_InputTextWithHint(print("##{s}", .{id}).ptr, hint.ptr, buffer, buffer.len + 1, 0);
}

/// How a text field was used this frame.
pub const TextEdit = struct {
    /// Being typed in.
    active: bool,
    /// Just left after a change, or a suggestion was picked: the time to keep what's in it.
    done: bool,

    /// How the text field just drawn was used.
    pub fn ofLastItem() TextEdit {
        return .{ .active = c.ImGui_IsItemActive(), .done = c.ImGui_IsItemDeactivatedAfterEdit() };
    }
};

/// A text field that suggests `suggestions` (most likely first), like an editable drop-down. You
/// can type anything. Tab completes what's typed to the first suggestion that starts with it, and
/// the rest of that suggestion shows faintly while you type. A chevron lists them all to pick
/// from; it's left out when there are none. `width` is in the design's pixels, and 0 fills the
/// row.
pub fn suggestField(id: [:0]const u8, buffer: anytype, hint: [:0]const u8, width: f32, suggestions: []const []const u8) TextEdit {
    c.ImGui_PushID(id.ptr);
    defer c.ImGui_PopID();
    c.ImGui_SetNextItemWidth(if (width == 0) -std.math.floatMin(f32) else px(width));
    // The chevron goes over the field's right end.
    if (suggestions.len > 0) c.ImGui_SetNextItemAllowOverlap();
    var list = suggestions;
    _ = c.ImGui_InputTextWithHintEx("##value", hint.ptr, buffer, buffer.len + 1, c.ImGuiInputTextFlags_CallbackCompletion, complete, @ptrCast(&list));
    var edit: TextEdit = .ofLastItem();
    const min = c.ImGui_GetItemRectMin();
    const max = c.ImGui_GetItemRectMax();
    if (suggestions.len == 0) return edit;
    const draw = c.ImGui_GetWindowDrawList();
    const padding = c.ImGui_GetStyle().*.FramePadding;
    const chevron_room = max.y - min.y;
    const typed = std.mem.sliceTo(buffer, 0);
    if (edit.active and typed.len > 0) if (completionOf(suggestions, typed)) |whole| {
        // The rest of the completion, after the typed text, while it fits before the chevron.
        const rest = print("{s}", .{whole[typed.len..]});
        const at = min.x + padding.x + c.ImGui_CalcTextSize(print("{s}", .{typed})).x;
        if (at + c.ImGui_CalcTextSize(rest).x < max.x - chevron_room) c.ImDrawList_AddText(draw, vec2(at, min.y + padding.y), theme.imU32(theme.colors.text_tertiary), rest);
    };
    if (endButton("##suggestions", min, max)) _ = c.ImGui_OpenPopup("suggestions", 0);
    chevron(draw, min, max);
    c.ImGui_SetNextWindowPos(vec2(min.x, max.y + px(field_popup_gap)), c.ImGuiCond_Always);
    c.ImGui_SetNextWindowSizeConstraints(vec2(max.x - min.x, 0), vec2(max.x - min.x, px(tall_list_height)), null, null);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, vec2(px(list_padding_x), px(list_padding_y)));
    defer c.ImGui_PopStyleVar();
    if (!c.ImGui_BeginPopup("suggestions", c.ImGuiWindowFlags_NoMove)) return edit;
    defer c.ImGui_EndPopup();
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, vec2(px(list_row_gap), px(list_row_gap)));
    defer c.ImGui_PopStyleVar();
    for (suggestions, 0..) |suggestion, i| {
        c.ImGui_PushIDInt(@intCast(i));
        defer c.ImGui_PopID();
        const fits = suggestion.len <= buffer.len;
        c.ImGui_BeginDisabled(!fits);
        defer c.ImGui_EndDisabled();
        if (c.ImGui_SelectableEx(print("{s}", .{suggestion}).ptr, std.ascii.eqlIgnoreCase(typed, suggestion), 0, vec2(0, 0)) and fits) {
            setText(buffer, suggestion) catch unreachable;
            edit.done = true;
        }
    }
    return edit;
}

/// The gap between a field and the list or calendar it opens, in the design's pixels.
const field_popup_gap = 2;

/// A square button over the right end of the field drawn from `min` to `max`, which has to be
/// drawn after `c.ImGui_SetNextItemAllowOverlap`. Returns true when it's clicked. The cursor stays
/// where the field left it.
fn endButton(id: [:0]const u8, min: Vec2, max: Vec2) bool {
    const side = max.y - min.y;
    const after = c.ImGui_GetCursorScreenPos();
    defer c.ImGui_SetCursorScreenPos(after);
    c.ImGui_SetCursorScreenPos(vec2(max.x - side, min.y));
    return c.ImGui_InvisibleButton(id, vec2(side, side), 0);
}

/// A date field: type a year, a month or a day (YYYY, YYYY-MM or YYYY-MM-DD), or pick a day on
/// the calendar the button at its end opens. The calendar marks `today`, and opens on it when
/// the field has no date. `width` is in the design's pixels, and 0 fills the row.
pub fn dateField(id: [:0]const u8, buffer: anytype, hint: [:0]const u8, width: f32, today: Date) TextEdit {
    c.ImGui_PushID(id.ptr);
    defer c.ImGui_PopID();
    c.ImGui_SetNextItemWidth(if (width == 0) -std.math.floatMin(f32) else px(width));
    c.ImGui_SetNextItemAllowOverlap();
    _ = c.ImGui_InputTextWithHint("##value", hint.ptr, buffer, buffer.len + 1, 0);
    var edit: TextEdit = .ofLastItem();
    const min = c.ImGui_GetItemRectMin();
    const max = c.ImGui_GetItemRectMax();
    const side = max.y - min.y;
    const shown = Date.parse(std.mem.sliceTo(buffer, 0));
    if (endButton("##calendar", min, max)) {
        _ = c.ImGui_OpenPopup("calendar", 0);
        const start = if (shown) |d| d else today;
        calendar_month = .{ start.year, start.month orelse today.month.? };
    }
    drawIcon(.calendar, vec2(max.x - side / 2, (min.y + max.y) / 2), if (c.ImGui_IsItemHovered(0)) theme.colors.text else theme.colors.text_secondary);
    c.ImGui_SetNextWindowPosEx(vec2(max.x, max.y + px(field_popup_gap)), c.ImGuiCond_Always, vec2(1, 0));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, vec2(px(calendar.padding), px(calendar.padding)));
    defer c.ImGui_PopStyleVar();
    if (!c.ImGui_BeginPopup("calendar", c.ImGuiWindowFlags_NoMove)) return edit;
    defer c.ImGui_EndPopup();
    if (drawCalendar(shown, today)) |picked| {
        var written: [date.max_text]u8 = undefined;
        setText(buffer, picked.format(&written)) catch {};
        edit.done = true;
        c.ImGui_CloseCurrentPopup();
    }
    return edit;
}

/// The month the open calendar shows. Only one can be open at a time.
var calendar_month: struct { u16, u8 } = .{ std.time.epoch.epoch_year, 1 };

/// A calendar's layout, in the design's pixels: its padding, a day's cell, the header's height,
/// and the gap under the header and above the Today button.
const calendar = struct {
    const padding = 10;
    const cell = 32;
    const header = 30;
    const gap = 6;
    /// The most weeks a month spans.
    const weeks = 6;
};

/// The months, for their names in `i18n.t.gui.month`.
const Month = enum { january, february, march, april, may, june, july, august, september, october, november, december };
/// The days of the week, Monday first as ISO 8601 counts the week, for their initials in
/// `i18n.t.gui.weekday`.
const Weekday = enum { monday, tuesday, wednesday, thursday, friday, saturday, sunday };
comptime {
    std.debug.assert(std.enums.values(Month).len == date.months_in_year);
    std.debug.assert(std.enums.values(Weekday).len == date.days_in_week);
}

/// The name of `month`, 1 to 12, in the interface's language.
fn monthName(month: u8) [:0]const u8 {
    return i18n.label(i18n.t.gui.month, @as(Month, @fromBackingInt(@intCast(month - 1))));
}

/// Draws the month in `calendar_month`, with arrows to the months either side, `selected` filled
/// and `today` outlined. Returns the day picked, or today when Today is clicked.
fn drawCalendar(selected: ?Date, today: Date) ?Date {
    const list = c.ImGui_GetWindowDrawList();
    const origin = c.ImGui_GetCursorScreenPos();
    const cell = px(calendar.cell);
    const width = cell * date.days_in_week;
    const year, const month = calendar_month;

    // The month's name, and the arrows to move a month.
    fonts.push(.semibold);
    const heading_text = say(i18n.t.gui.month_heading, .{ monthName(month), year });
    c.ImDrawList_AddText(list, vec2(origin.x + px(calendar.gap), @round(origin.y + (px(calendar.header) - c.ImGui_GetTextLineHeight()) / 2)), theme.imU32(theme.colors.text), heading_text);
    fonts.pop();
    const arrow = c.ImGui_GetFrameHeight();
    c.ImGui_SetCursorScreenPos(vec2(origin.x + width - 2 * arrow, origin.y + (px(calendar.header) - arrow) / 2));
    if (iconButton("previous month", .quiet, .chevron_left)) calendar_month = date.stepMonth(year, month, -1);
    c.ImGui_SameLineEx(0, 0);
    if (iconButton("next month", .quiet, .chevron_right)) calendar_month = date.stepMonth(year, month, 1);

    var y = origin.y + px(calendar.header + calendar.gap);
    fonts.pushSized(.regular, fonts.small_size);
    for (std.enums.values(Weekday), 0..) |day, i| {
        const name = i18n.label(i18n.t.gui.weekday, day);
        const size = c.ImGui_CalcTextSize(name);
        c.ImDrawList_AddText(list, vec2(@round(origin.x + cell * @as(f32, @floatFromInt(i)) + (cell - size.x) / 2), y), theme.imU32(theme.colors.text_tertiary), name);
    }
    y += c.ImGui_GetTextLineHeight() + px(calendar.gap);
    fonts.pop();

    var picked: ?Date = null;
    const first = date.firstWeekday(year, month);
    for (0..date.daysIn(year, month)) |i| {
        const day: u8 = @intCast(i + 1);
        const slot = first + i;
        const min = vec2(origin.x + cell * @as(f32, @floatFromInt(slot % date.days_in_week)), y + cell * @as(f32, @floatFromInt(slot / date.days_in_week)));
        const max = vec2(min.x + cell, min.y + cell);
        c.ImGui_SetCursorScreenPos(min);
        c.ImGui_PushIDInt(day);
        if (c.ImGui_InvisibleButton("##day", vec2(cell, cell), 0)) picked = .{ .year = year, .month = month, .day = day };
        c.ImGui_PopID();
        const this: Date = .{ .year = year, .month = month, .day = day };
        const is_selected = if (selected) |s| std.meta.eql(s, this) else false;
        const inset = px(choice_inset);
        const box_min = vec2(min.x + inset, min.y + inset);
        const box_max = vec2(max.x - inset, max.y - inset);
        if (is_selected) {
            c.ImDrawList_AddRectFilledEx(list, box_min, box_max, theme.imU32(theme.colors.accent), px(control_rounding), 0);
        } else if (c.ImGui_IsItemHovered(0)) {
            c.ImDrawList_AddRectFilledEx(list, box_min, box_max, theme.imU32(theme.colors.control_hover), px(control_rounding), 0);
        }
        if (std.meta.eql(this, today) and !is_selected) c.ImDrawList_AddRectEx(list, box_min, box_max, theme.imU32(theme.colors.accent), px(control_rounding), 1, 0);
        const label = print("{d}", .{day});
        const size = c.ImGui_CalcTextSize(label);
        c.ImDrawList_AddText(list, vec2(@round(min.x + (cell - size.x) / 2), @round(min.y + (cell - size.y) / 2)), theme.imU32(if (is_selected) theme.colors.on_accent else theme.colors.text), label);
    }
    y += cell * calendar.weeks + px(calendar.gap);
    c.ImGui_SetCursorScreenPos(vec2(origin.x, y));
    if (buttonOf(.normal, i18n.t.gui.today, vec2(0, 0))) picked = today;
    c.ImGui_SetCursorScreenPos(vec2(origin.x, c.ImGui_GetCursorScreenPos().y));
    c.ImGui_Dummy(vec2(width, 0));
    return picked;
}

/// How far a day's fill sits inside its cell, in the design's pixels.
const choice_inset = 2;

/// The first of `suggestions` that starts with `typed`, ignoring case, and is longer than it.
fn completionOf(suggestions: []const []const u8, typed: []const u8) ?[]const u8 {
    for (suggestions) |suggestion| {
        if (suggestion.len > typed.len and std.ascii.startsWithIgnoreCase(suggestion, typed)) return suggestion;
    }
    return null;
}

/// ImGui's Tab callback for `suggestField`: swaps what's typed for its completion, in the
/// completion's own case. Its user data is the suggestions.
fn complete(data: [*c]c.ImGuiInputTextCallbackData) callconv(.c) c_int {
    const suggestions: *const []const []const u8 = @ptrCast(@alignCast(data.*.UserData));
    const typed = data.*.Buf[0..@intCast(data.*.BufTextLen)];
    const whole = completionOf(suggestions.*, typed) orelse return 0;
    c.ImGuiInputTextCallbackData_DeleteChars(data, 0, data.*.BufTextLen);
    c.ImGuiInputTextCallbackData_InsertChars(data, 0, whole.ptr, whole.ptr + whole.len);
    return 0;
}

/// A slider's thumb radius and how much it grows while it's held or hovered, the track's
/// thickness, and how many sides the thumb is drawn with.
const slider_thumb = 7;
const slider_thumb_grow = 1;
const slider_track = 4;
const slider_thumb_segments = 16;

/// A range slider drawn the way the design draws one: a thin track, amber up to the value, and a
/// round thumb. `width` is in the design's pixels, and 0 fills up to the value column. Returns true
/// when it moved.
///
/// Esc or a right-click while dragging cancels the drag: the value goes back to where it was, and
/// the slider ignores the mouse until it's let go. ImGui's own sliders do the same since 1.93.
pub fn slider(id: [:0]const u8, value: *f32, min: f32, max: f32, width: f32) bool {
    const room = c.ImGui_GetContentRegionAvail().x;
    const w = if (width == 0) room - px(value_column + label_gap + reset_space) else px(width);
    const height = c.ImGui_GetFrameHeight();
    const origin = c.ImGui_GetCursorScreenPos();
    const thumb = px(slider_thumb);
    _ = c.ImGui_InvisibleButton(print("##{s}", .{id}).ptr, vec2(w, height), 0);
    const active = c.ImGui_IsItemActive();
    const hovered = c.ImGui_IsItemHovered(0);
    var changed = false;
    if (dragCancelled(value)) changed = true;
    const left = origin.x + thumb;
    const span = w - 2 * thumb;
    if (active and !c.ImGuiStorage_GetBool(c.ImGui_GetStateStorage(), cancelKey(), false) and span > 0) {
        const at = std.math.clamp((c.ImGui_GetMousePos().x - left) / span, 0, 1);
        const next = min + at * (max - min);
        if (next != value.*) {
            value.* = next;
            changed = true;
        }
    }
    const share = std.math.clamp((value.* - min) / (max - min), 0, 1);
    const list = c.ImGui_GetWindowDrawList();
    const middle = origin.y + height / 2;
    const disabled = c.ImGui_GetStyle().*.Alpha < 1 or (c.ImGui_GetItemFlags() & c.ImGuiItemFlags_Disabled) != 0;
    const amber = if (disabled) theme.colors.text_tertiary else theme.colors.accent;
    const track = px(slider_track) / 2;
    c.ImDrawList_AddRectFilledEx(list, vec2(left, middle - track), vec2(left + span, middle + track), theme.imU32(theme.colors.track), px(track_rounding), 0);
    c.ImDrawList_AddRectFilledEx(list, vec2(left, middle - track), vec2(left + span * share, middle + track), theme.imU32(amber), px(track_rounding), 0);
    c.ImDrawList_AddCircleFilled(list, vec2(left + span * share, middle), if (hovered or active) thumb + px(slider_thumb_grow) else thumb, theme.imU32(amber), slider_thumb_segments);
    return changed;
}

/// Where the last item, a slider, keeps whether its drag was cancelled: next to its value at the
/// start of the drag, which is kept under its own ID.
fn cancelKey() c.ImGuiID {
    return c.ImGui_GetItemID() +% 1;
}

/// Keeps the last item's value at the start of a drag, and puts `value` back to it when the drag
/// is cancelled with Esc or a right-click. Returns true when it did.
fn dragCancelled(value: *f32) bool {
    const storage = c.ImGui_GetStateStorage();
    const item = c.ImGui_GetItemID();
    if (c.ImGui_IsItemActivated()) {
        c.ImGuiStorage_SetFloat(storage, item, value.*);
        c.ImGuiStorage_SetBool(storage, cancelKey(), false);
        return false;
    }
    if (!c.ImGui_IsItemActive() or c.ImGuiStorage_GetBool(storage, cancelKey(), false)) return false;
    if (!c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) and !c.ImGui_IsMouseClicked(c.ImGuiMouseButton_Right)) return false;
    c.ImGuiStorage_SetBool(storage, cancelKey(), true);
    const start = c.ImGuiStorage_GetFloat(storage, item, value.*);
    if (start == value.*) return false;
    value.* = start;
    return true;
}

/// Draws a value in the value column after a slider, monospaced and right-aligned.
pub fn valueText(shown: []const u8) void {
    c.ImGui_SameLineEx(0, px(label_gap));
    const end = c.ImGui_GetCursorPosX() + px(value_column);
    fonts.push(.mono);
    const width = c.ImGui_CalcTextSize(print("{s}", .{shown}).ptr).x;
    c.ImGui_SetCursorPosX(end - width);
    c.ImGui_AlignTextToFramePadding();
    text(shown);
    fonts.pop();
}

/// Shows `value` as a tooltip while the last item is hovered.
pub fn tooltip(value: []const u8) void {
    if (c.ImGui_IsItemHovered(0)) showTooltip(value);
}

/// Shows `value` as a tooltip now, for a caller that knows when it should show.
pub fn showTooltip(value: []const u8) void {
    if (!beginTooltip()) return;
    defer c.ImGui_EndTooltip();
    text(value);
}

/// Starts a tooltip with the design's padding, whatever padding the window it's over has set.
/// Returns false when there's nothing to draw; otherwise end it with `c.ImGui_EndTooltip`.
pub fn beginTooltip() bool {
    // The tooltip takes its padding when it starts, so it can go back straight away.
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, vec2(px(theme.window_padding), px(theme.window_padding)));
    defer c.ImGui_PopStyleVar();
    return c.ImGui_BeginTooltip();
}

/// A labelled slider row with its value, the most common row in a settings grid. Returns true when
/// it moved.
pub fn sliderRow(label: []const u8, v: *f32, min: f32, max: f32, comptime format: []const u8, options: SliderOptions) bool {
    c.ImGui_PushID(print("{s}", .{label}).ptr);
    defer c.ImGui_PopID();
    rowLabel(label);
    var changed = slider("slider", v, min, max, 0);
    if (options.help) |help| tooltip(help);
    if (valueAndReset(options.shown(format, v.*, max), options.shown(format, options.default, max))) {
        v.* = options.default;
        changed = true;
    }
    return changed;
}

/// The end of a slider row: the value as `shown`, and a reset button that's disabled while it
/// reads as `default_shown`. Returns true when the reset button was clicked.
pub fn valueAndReset(shown: []const u8, default_shown: []const u8) bool {
    valueText(shown);
    c.ImGui_SameLineEx(0, px(reset_space - reset_size));
    const at = c.ImGui_GetCursorScreenPos();
    return resetButton("reset", vec2(at.x, at.y + (c.ImGui_GetFrameHeight() - px(reset_size)) / 2), shown, default_shown);
}

/// What a slider row needs besides its value.
pub const SliderOptions = struct {
    /// What the reset button puts the value back to.
    default: f32,
    /// Shown while the slider is hovered.
    help: ?[:0]const u8 = null,
    /// Shown in place of the value at the top of the range, such as Any for no limit.
    at_max: ?[]const u8 = null,

    fn shown(options: SliderOptions, comptime format: []const u8, v: f32, max: f32) []const u8 {
        if (options.at_max) |label| if (v >= max) return label;
        return formatSigned(format, v);
    }
};

/// A small button at `at` that puts a value back to its default. It's disabled while the value as
/// shown (`shown`) reads the same as the default (`default_shown`). Returns true when clicked.
pub fn resetButton(id: [:0]const u8, at: Vec2, shown: []const u8, default_shown: []const u8) bool {
    const at_default = std.mem.eql(u8, shown, default_shown);
    const disabled = at_default or c.ImGui_GetStyle().*.Alpha < 1 or (c.ImGui_GetItemFlags() & c.ImGuiItemFlags_Disabled) != 0;
    const size = px(reset_size);
    c.ImGui_SetCursorScreenPos(at);
    c.ImGui_BeginDisabled(at_default);
    const clicked = c.ImGui_InvisibleButton(id, vec2(size, size), 0);
    c.ImGui_EndDisabled();
    const hovered = !disabled and c.ImGui_IsItemHovered(0);
    if (hovered) showTooltip(say(i18n.t.gui.reset_to, .{default_shown}));
    const ink = if (disabled) theme.colors.text_tertiary else if (hovered) theme.colors.text else theme.colors.text_secondary;
    icons.draw(c.ImGui_GetWindowDrawList(), .rotate_ccw, vec2(at.x + size / 2, at.y + size / 2), px(reset_icon_size), ink);
    return clicked and !at_default;
}

/// Draws a five-pointed star centred on `centre`, with its points `radius` from the centre: filled,
/// or just its outline.
pub fn star(list: *c.ImDrawList, centre: Vec2, radius: f32, filled: bool, colour: theme.Color) void {
    var points: [10]Vec2 = undefined;
    for (&points, 0..) |*p, i| {
        // The points and the notches between them take turns, starting with the top point.
        const r = if (i % 2 == 0) radius else radius * star_notch;
        const angle = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * std.math.pi / 5.0;
        p.* = vec2(centre.x + r * @cos(angle), centre.y + r * @sin(angle));
    }
    const ink = theme.imU32(colour);
    if (filled) {
        c.ImDrawList_AddConcavePolyFilled(list, &points, points.len, ink);
    } else {
        c.ImDrawList_AddPolyline(list, &points, points.len, ink, @max(1, radius / 6), c.ImDrawFlags_Closed);
    }
}

/// How far in a star's notches are, as a share of its radius. A regular star's are at 0.38, and a
/// little more fills out a small one.
const star_notch = 0.45;

/// Draws an x centred on `centre`, its strokes reaching `arm` out along each axis.
pub fn cross(list: *c.ImDrawList, centre: Vec2, arm: f32, thickness: f32, colour: theme.Color) void {
    const ink = theme.imU32(colour);
    c.ImDrawList_AddLineEx(list, vec2(centre.x - arm, centre.y - arm), vec2(centre.x + arm, centre.y + arm), ink, thickness, 0);
    c.ImDrawList_AddLineEx(list, vec2(centre.x + arm, centre.y - arm), vec2(centre.x - arm, centre.y + arm), ink, thickness, 0);
}

/// Draws a plus sign centred on `centre`, its strokes reaching `arm` out each way.
pub fn plus(list: *c.ImDrawList, centre: Vec2, arm: f32, thickness: f32, colour: theme.Color) void {
    const ink = theme.imU32(colour);
    c.ImDrawList_AddLineEx(list, vec2(centre.x - arm, centre.y), vec2(centre.x + arm, centre.y), ink, thickness, 0);
    c.ImDrawList_AddLineEx(list, vec2(centre.x, centre.y - arm), vec2(centre.x, centre.y + arm), ink, thickness, 0);
}

/// Draws a progress bar filling `min` to `max`: a grey track, with `fraction` (0 to 1) of it in
/// amber from the left.
pub fn progressBar(list: *c.ImDrawList, min: Vec2, max: Vec2, fraction: f32) void {
    const rounding = (max.y - min.y) / 2;
    c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(theme.colors.border), rounding, 0);
    const done = (max.x - min.x) * std.math.clamp(fraction, 0, 1);
    if (done > 0) c.ImDrawList_AddRectFilledEx(list, min, vec2(min.x + done, max.y), theme.imU32(theme.colors.accent), rounding, 0);
}

/// Prints `v` with `format`, using a real minus sign as the design does.
pub fn formatSigned(comptime format: []const u8, v: f32) [:0]const u8 {
    const shown = print(format, .{@abs(v)});
    // −0.00 looks like a mistake, so a value that prints as zero gets no sign.
    const zero = for (shown) |ch| {
        if (ch >= '1' and ch <= '9') break false;
    } else true;
    if (v < 0 and !zero) return print("−{s}", .{shown});
    return shown;
}

/// Draws a horizontal line across the window at the cursor, in the divider colour.
pub fn divider() void {
    const origin = c.ImGui_GetCursorScreenPos();
    const window = c.ImGui_GetWindowPos();
    const width = c.ImGui_GetWindowWidth();
    c.ImDrawList_AddLineH(c.ImGui_GetWindowDrawList(), window.x, window.x + width, origin.y, theme.imU32(theme.colors.divider));
}

/// The space above and below a section of a side panel, in the design's pixels.
const section_padding = 12;

/// Starts a section of a side panel: `section_padding` of space above and below, and a divider
/// under it.
/// The panel's own padding takes care of the sides. Call `endSection` afterwards.
pub fn beginSection(id: [:0]const u8) void {
    c.ImGui_PushID(id.ptr);
    const y = c.ImGui_GetCursorPosY();
    // After an earlier section, the cursor sits one line's spacing below that section's divider.
    const at_top = y <= c.ImGui_GetCursorStartPos().y;
    c.ImGui_SetCursorPosY(y + px(section_padding) - if (at_top) 0 else c.ImGui_GetStyle().*.ItemSpacing.y);
}

pub fn endSection(line: bool) void {
    const bottom = c.ImGui_GetCursorPosY() - c.ImGui_GetStyle().*.ItemSpacing.y + px(section_padding);
    c.ImGui_SetCursorPosY(bottom);
    if (line) divider();
    c.ImGui_Dummy(vec2(0, 1));
    c.ImGui_PopID();
}

/// Draws a `width` × `height` image filling the box from `min` to `max`, cropped from the middle
/// to the box's shape.
pub fn imageCover(list: *c.ImDrawList, texture: c.ImTextureRef, width: u32, height: u32, min: Vec2, max: Vec2, rounding: f32) void {
    const box = (max.x - min.x) / (max.y - min.y);
    const picture = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
    var uv_min = vec2(0, 0);
    var uv_max = vec2(1, 1);
    if (picture > box) {
        uv_min.x = (1 - box / picture) / 2;
        uv_max.x = 1 - uv_min.x;
    } else {
        uv_min.y = (1 - picture / box) / 2;
        uv_max.y = 1 - uv_min.y;
    }
    c.ImDrawList_AddImageRounded(list, texture, min, max, uv_min, uv_max, 0xFFFFFFFF, rounding, 0);
}

/// Draws a rectangle outline.
pub fn outline(min: Vec2, max: Vec2, color: theme.Color, rounding: f32, thickness: f32) void {
    c.ImDrawList_AddRectEx(c.ImGui_GetWindowDrawList(), min, max, theme.imU32(color), rounding, thickness, 0);
}

/// Draws a divider along one side of the current child window.
pub fn edge(side: enum { left, right }) void {
    const pos = c.ImGui_GetWindowPos();
    const size = c.ImGui_GetWindowSize();
    const x = if (side == .left) pos.x else pos.x + size.x - 1;
    c.ImDrawList_AddLineV(c.ImGui_GetWindowDrawList(), x, pos.y, pos.y + size.y, theme.imU32(theme.colors.divider));
}

/// Draws a dashed line from `from` to `to`, with dashes `dash` long and `gap` between them, in
/// screen pixels.
pub fn dashedLine(list: *c.ImDrawList, from: Vec2, to: Vec2, colour: u32, thickness: f32, dash: f32, gap: f32) void {
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const length = @sqrt(dx * dx + dy * dy);
    if (length == 0) return;
    var at: f32 = 0;
    while (at < length) : (at += dash + gap) {
        const end = @min(at + dash, length);
        c.ImDrawList_AddLineEx(list, vec2(from.x + dx * at / length, from.y + dy * at / length), vec2(from.x + dx * end / length, from.y + dy * end / length), colour, thickness, 0);
    }
}

/// Draws a dashed outline of the rectangle from `min` to `max`, with the lines on the inside.
pub fn dashedRect(list: *c.ImDrawList, min: Vec2, max: Vec2, colour: u32, thickness: f32, dash: f32, gap: f32) void {
    const inset = thickness / 2;
    const a = vec2(min.x + inset, min.y + inset);
    const b = vec2(max.x - inset, min.y + inset);
    const d = vec2(max.x - inset, max.y - inset);
    const e = vec2(min.x + inset, max.y - inset);
    for ([_][2]Vec2{ .{ a, b }, .{ b, d }, .{ e, d }, .{ a, e } }) |side| dashedLine(list, side[0], side[1], colour, thickness, dash, gap);
}

/// The dashes of the design's dashed box, and the gaps between them.
const dashed_box_dash = 3;
const dashed_box_gap = 3;

/// Draws the design's dashed box, for something you can add or that isn't available yet: a
/// one-pixel dashed outline with rounded corners of `radius`.
pub fn dashedRoundedRect(list: *c.ImDrawList, min: Vec2, max: Vec2, colour: u32, radius: f32) void {
    const dash = px(dashed_box_dash);
    const gap = px(dashed_box_gap);
    dashedLine(list, vec2(min.x + radius, min.y + 0.5), vec2(max.x - radius, min.y + 0.5), colour, 1, dash, gap);
    dashedLine(list, vec2(min.x + radius, max.y - 0.5), vec2(max.x - radius, max.y - 0.5), colour, 1, dash, gap);
    dashedLine(list, vec2(min.x + 0.5, min.y + radius), vec2(min.x + 0.5, max.y - radius), colour, 1, dash, gap);
    dashedLine(list, vec2(max.x - 0.5, min.y + radius), vec2(max.x - 0.5, max.y - radius), colour, 1, dash, gap);
    // The corners, drawn whole.
    const corners = [_]struct { Vec2, f32 }{
        .{ vec2(min.x + radius, min.y + radius), std.math.pi },
        .{ vec2(max.x - radius, min.y + radius), 1.5 * std.math.pi },
        .{ vec2(max.x - radius, max.y - radius), 0 },
        .{ vec2(min.x + radius, max.y - radius), 0.5 * std.math.pi },
    };
    for (corners) |corner| {
        c.ImDrawList_PathArcTo(list, corner[0], radius - 0.5, corner[1], corner[1] + 0.5 * std.math.pi, 6);
        c.ImDrawList_PathStroke(list, colour, 1, 0);
    }
}

test "text is cut short with an ellipsis, never through a character" {
    const characters = struct {
        fn count(value: [:0]const u8) f32 {
            return @floatFromInt(std.unicode.utf8CountCodepoints(value) catch unreachable);
        }
    }.count;
    try std.testing.expectEqualStrings("…/Roll 014", elide(.start, "~/Pictures/Roll 014", 10, characters));
    try std.testing.expectEqualStrings("Kodak…", elide(.end, "Kodak Portra 400", 6, characters));
    try std.testing.expectEqualStrings("Ré…", elide(.end, "Réglage", 3, characters));
    try std.testing.expectEqualStrings("short", elide(.end, "short", 10, characters));
}

test "a search matches every word, in any case" {
    try std.testing.expect(matchesWords("Kodak Portra 400", "portra 4"));
    try std.testing.expect(matchesWords("Kodak Portra 400", ""));
    try std.testing.expect(!matchesWords("Kodak Portra 400", "portra fuji"));
    try std.testing.expect(containsIgnoreCase("Ilford HP5 Plus", "hp5"));
}

test "signed numbers get a real minus, and none when they print as zero" {
    try std.testing.expectEqualStrings("−1.50", formatSigned("{d:.2}", -1.5));
    try std.testing.expectEqualStrings("0.00", formatSigned("{d:.2}", -0.004));
    try std.testing.expectEqualStrings("2.00", formatSigned("{d:.2}", 2));
}

test "text that doesn't fit leaves a field as it was" {
    var buffer = initText(4, "ab");
    try std.testing.expectEqualStrings("ab", std.mem.sliceTo(&buffer, 0));
    try setText(&buffer, "abcd");
    try std.testing.expectEqualStrings("abcd", std.mem.sliceTo(&buffer, 0));
    try std.testing.expectError(error.TooLong, setText(&buffer, "abcde"));
    try std.testing.expectEqualStrings("abcd", std.mem.sliceTo(&buffer, 0));
}

test "a choice's index is where it is in the list, or past the end" {
    const choices = [_]u8{ 3, 1, 2 };
    try std.testing.expectEqual(@as(usize, 1), indexIn(u8, &choices, 1));
    try std.testing.expectEqual(@as(usize, 3), indexIn(u8, &choices, 9));
}
