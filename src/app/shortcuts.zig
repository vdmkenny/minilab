//! Keyboard shortcuts. Where Lightroom Classic or Bridge has a shortcut for the same thing, we use
//! the same key, so if you know those apps you already know these.
//!
//! "Command" means ⌘ on macOS and Ctrl elsewhere. ImGui swaps the two keys on macOS, so its Ctrl
//! modifier is the Command key there, and the table doesn't need a second set of keys for the Mac.
//! Only the labels differ: ⌘⌥⇧ on macOS, Ctrl+Alt+Shift+ elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");

pub const Command = enum {
    rolls,
    scan,
    develop,
    @"export",
    looks,
    previous,
    next,
    first,
    last,
    zoom_toggle,
    zoom_in,
    zoom_out,
    clipping,
    before,
    split,
    white_balance,
    base,
    crop,
    turn_left,
    turn_right,
    mirror,
    confirm,
    undo,
    redo,
    copy_settings,
    paste_settings,
    paste_previous,
    sync,
    reset,
    automatic,
    no_stars,
    one_star,
    two_stars,
    three_stars,
    four_stars,
    five_stars,
    reject,
    unreject,
    new_roll,
    find,
    import,
    select_all,
    select_none,
    hide_panels,
    hide_all,
    full_screen,
    help,
    quit,
    cancel,

    pub fn describe(command: Command) []const u8 {
        return switch (command) {
            .rolls => "Rolls",
            .scan => "Scan",
            .develop => "Develop",
            .@"export" => "Export",
            .looks => "Looks",
            .previous => "Previous frame",
            .next => "Next frame",
            .first => "First frame",
            .last => "Last frame",
            .zoom_toggle => "Fit or 100%",
            .zoom_in => "Zoom to 100%",
            .zoom_out => "Zoom to fit",
            .clipping => "Show clipping",
            .before => "Negative or positive",
            .split => "Split view",
            .white_balance => "Pick white balance",
            .base => "Pick film base",
            .crop => "Crop",
            .turn_left => "Turn left",
            .turn_right => "Turn right",
            .mirror => "Mirror left to right",
            .confirm => "Finish the crop",
            .undo => "Undo",
            .redo => "Redo",
            .copy_settings => "Copy settings",
            .paste_settings => "Paste settings",
            .paste_previous => "Paste from previous frame",
            .sync => "Sync settings to roll",
            .reset => "Reset settings",
            .automatic => "Automatic settings",
            .no_stars => "No stars",
            .one_star => "1 star",
            .two_stars => "2 stars",
            .three_stars => "3 stars",
            .four_stars => "4 stars",
            .five_stars => "5 stars",
            .reject => "Reject",
            .unreject => "Clear reject",
            .new_roll => "New roll",
            .find => "Find rolls",
            .import => "Import (Scan)",
            .select_all => "Select all frames",
            .select_none => "Select no frames",
            .hide_panels => "Hide side panels",
            .hide_all => "Hide all panels",
            .full_screen => "Full screen",
            .help => "Keyboard shortcuts",
            .quit => "Quit",
            .cancel => "Cancel a pick, close a panel",
        };
    }

    /// The command that gives a frame `count` stars, up to five.
    pub fn stars(count: usize) Command {
        return switch (count) {
            0 => .no_stars,
            1 => .one_star,
            2 => .two_stars,
            3 => .three_stars,
            4 => .four_stars,
            else => .five_stars,
        };
    }
};

/// The Command key: ⌘ on macOS, Ctrl elsewhere.
const command_key = c.ImGuiMod_Ctrl;
const shift = c.ImGuiMod_Shift;
const alt = c.ImGuiMod_Alt;

const Binding = struct { command: Command, chord: c.ImGuiKeyChord };

fn bind(command: Command, chord: c_int) Binding {
    return .{ .command = command, .chord = chord };
}

/// Every shortcut. A command's first binding is the one its label shows.
pub const bindings = [_]Binding{
    // Workspaces: Lightroom's module keys, and its G for the grid and D for Develop.
    bind(.rolls, c.ImGuiKey_G),
    bind(.rolls, command_key | alt | c.ImGuiKey_1),
    bind(.scan, command_key | alt | c.ImGuiKey_2),
    bind(.develop, c.ImGuiKey_D),
    bind(.develop, c.ImGuiKey_E),
    bind(.develop, command_key | alt | c.ImGuiKey_3),
    bind(.@"export", command_key | shift | c.ImGuiKey_E),
    bind(.@"export", command_key | alt | c.ImGuiKey_4),
    bind(.looks, command_key | alt | c.ImGuiKey_5),
    // Frames.
    bind(.previous, c.ImGuiKey_LeftArrow),
    bind(.next, c.ImGuiKey_RightArrow),
    bind(.first, c.ImGuiKey_Home),
    bind(.last, c.ImGuiKey_End),
    // The viewer: Z and Space toggle the zoom, ⌘= and ⌘− zoom, J shows clipping, \\ shows the
    // before (here the negative), Y the before and after side by side.
    bind(.zoom_toggle, c.ImGuiKey_Z),
    bind(.zoom_toggle, c.ImGuiKey_Space),
    bind(.zoom_in, command_key | c.ImGuiKey_Equal),
    bind(.zoom_out, command_key | c.ImGuiKey_Minus),
    bind(.clipping, c.ImGuiKey_J),
    bind(.before, c.ImGuiKey_Backslash),
    bind(.split, c.ImGuiKey_Y),
    // Tools: W for the white balance picker and R for crop, as in Lightroom, and B for the film
    // base.
    bind(.white_balance, c.ImGuiKey_W),
    bind(.base, c.ImGuiKey_B),
    bind(.crop, c.ImGuiKey_R),
    // Turning: ⌘[ and ⌘], as in Lightroom and Bridge.
    bind(.turn_left, command_key | c.ImGuiKey_LeftBracket),
    bind(.turn_right, command_key | c.ImGuiKey_RightBracket),
    // Mirroring: Lightroom's Flip Horizontal has no key of its own, and ⇧⌘M is free in both apps.
    bind(.mirror, command_key | shift | c.ImGuiKey_M),
    bind(.confirm, c.ImGuiKey_Enter),
    // Settings.
    bind(.undo, command_key | c.ImGuiKey_Z),
    bind(.redo, command_key | shift | c.ImGuiKey_Z),
    bind(.redo, command_key | c.ImGuiKey_Y),
    bind(.copy_settings, command_key | shift | c.ImGuiKey_C),
    bind(.copy_settings, command_key | c.ImGuiKey_C),
    bind(.paste_settings, command_key | shift | c.ImGuiKey_V),
    bind(.paste_settings, command_key | c.ImGuiKey_V),
    bind(.paste_previous, command_key | alt | c.ImGuiKey_V),
    bind(.sync, command_key | shift | c.ImGuiKey_S),
    bind(.reset, command_key | shift | c.ImGuiKey_R),
    bind(.automatic, command_key | c.ImGuiKey_U),
    // Rating: Lightroom's 0 to 5 for stars, X to reject and U to take the reject back.
    bind(.no_stars, c.ImGuiKey_0),
    bind(.one_star, c.ImGuiKey_1),
    bind(.two_stars, c.ImGuiKey_2),
    bind(.three_stars, c.ImGuiKey_3),
    bind(.four_stars, c.ImGuiKey_4),
    bind(.five_stars, c.ImGuiKey_5),
    bind(.reject, c.ImGuiKey_X),
    bind(.unreject, c.ImGuiKey_U),
    // The library.
    bind(.new_roll, command_key | c.ImGuiKey_N),
    bind(.find, command_key | c.ImGuiKey_F),
    bind(.import, command_key | shift | c.ImGuiKey_I),
    bind(.select_all, command_key | c.ImGuiKey_A),
    bind(.select_none, command_key | c.ImGuiKey_D),
    // The window.
    bind(.hide_panels, c.ImGuiKey_Tab),
    bind(.hide_all, shift | c.ImGuiKey_Tab),
    bind(.full_screen, c.ImGuiKey_F),
    bind(.help, command_key | c.ImGuiKey_Slash),
    bind(.quit, command_key | c.ImGuiKey_Q),
    bind(.cancel, c.ImGuiKey_Escape),
};

/// Whether `command` repeats while its keys are held down.
fn repeats(command: Command) bool {
    return switch (command) {
        .previous, .next, .undo, .redo => true,
        else => false,
    };
}

const mods_mask = c.ImGuiMod_Ctrl | c.ImGuiMod_Shift | c.ImGuiMod_Alt | c.ImGuiMod_Super;

/// Returns the commands whose keys were pressed this frame. While a text field has the keyboard,
/// only Escape and shortcuts with the Command key count, so typing never triggers a tool.
pub fn poll() std.EnumSet(Command) {
    var pressed: std.EnumSet(Command) = .empty;
    const io = c.ImGui_GetIO();
    const typing = io.*.WantTextInput;
    const mods = io.*.KeyMods & mods_mask;
    for (bindings) |b| {
        const wanted = b.chord & mods_mask;
        const key: c.ImGuiKey = @intCast(b.chord & ~@as(c_int, mods_mask));
        if (typing and wanted & command_key == 0 and key != c.ImGuiKey_Escape) continue;
        // In a text field, ⌘C, ⌘V, ⌘A and ⌘Z belong to the field.
        if (typing and wanted == command_key) continue;
        if (mods != wanted) continue;
        if (c.ImGui_IsKeyPressedEx(key, repeats(b.command))) pressed.insert(b.command);
    }
    return pressed;
}

/// The keys for `command`, written the platform's way: ⌘⇧E on macOS, Ctrl+Shift+E elsewhere.
pub fn label(command: Command) [:0]const u8 {
    for (bindings) |b| {
        if (b.command == command) return chordLabel(b.chord);
    }
    return "";
}

fn chordLabel(chord: c.ImGuiKeyChord) [:0]const u8 {
    const key: c.ImGuiKey = @intCast(chord & ~@as(c_int, mods_mask));
    const name = keyName(key);
    if (builtin.os.tag == .macos) {
        // Apple's order: Control, Option, Shift, Command. ImGui's Super is the Control key here.
        return gui.print("{s}{s}{s}{s}{s}", .{
            if (chord & c.ImGuiMod_Super != 0) "⌃" else "",
            if (chord & alt != 0) "⌥" else "",
            if (chord & shift != 0) "⇧" else "",
            if (chord & command_key != 0) "⌘" else "",
            name,
        });
    }
    return gui.print("{s}{s}{s}{s}", .{
        if (chord & command_key != 0) "Ctrl+" else "",
        if (chord & alt != 0) "Alt+" else "",
        if (chord & shift != 0) "Shift+" else "",
        name,
    });
}

fn keyName(key: c.ImGuiKey) []const u8 {
    return switch (key) {
        c.ImGuiKey_LeftArrow => "←",
        c.ImGuiKey_RightArrow => "→",
        c.ImGuiKey_Backslash => "\\",
        c.ImGuiKey_Slash => "/",
        c.ImGuiKey_LeftBracket => "[",
        c.ImGuiKey_RightBracket => "]",
        c.ImGuiKey_Enter => if (builtin.os.tag == .macos) "↩" else "Enter",
        c.ImGuiKey_Equal => "=",
        c.ImGuiKey_Minus => "−",
        c.ImGuiKey_Escape => "Esc",
        c.ImGuiKey_Tab => if (builtin.os.tag == .macos) "⇥" else "Tab",
        else => std.mem.span(c.ImGui_GetKeyName(key)),
    };
}

/// Shows a tooltip for the item just drawn while it's hovered: `text`, then the shortcut for
/// `command`.
pub fn tooltip(text: []const u8, command: Command) void {
    if (!c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) return;
    if (!c.ImGui_BeginTooltip()) return;
    defer c.ImGui_EndTooltip();
    gui.text(text);
    c.ImGui_SameLineEx(0, gui.px(12));
    fonts.pushSized(.mono, 12);
    gui.textColored(theme.text_tertiary, label(command));
    fonts.pop();
}

/// Every shortcut, in groups, for the help panel.
const groups = [_]struct { []const u8, []const Command }{
    .{ "WORKSPACES", &.{ .rolls, .scan, .develop, .@"export", .looks } },
    .{ "FRAMES", &.{ .previous, .next, .first, .last, .select_all, .select_none } },
    .{ "VIEWER", &.{ .zoom_toggle, .zoom_in, .zoom_out, .clipping, .before, .split } },
    .{ "TOOLS", &.{ .white_balance, .base, .crop, .turn_left, .turn_right, .mirror, .confirm } },
    .{ "SETTINGS", &.{ .undo, .redo, .copy_settings, .paste_settings, .paste_previous, .sync, .reset, .automatic } },
    .{ "RATING", &.{ .no_stars, .one_star, .two_stars, .three_stars, .four_stars, .five_stars, .reject, .unreject } },
    .{ "LIBRARY", &.{ .new_roll, .find, .import } },
    .{ "WINDOW", &.{ .hide_panels, .hide_all, .full_screen, .help, .quit, .cancel } },
};

/// Draws the help panel over the window, listing every shortcut. Returns false once it's closed.
pub fn drawHelp() bool {
    var open = true;
    const viewport = c.ImGui_GetMainViewport();
    const size = gui.vec2(gui.px(720), @min(viewport.*.WorkSize.y - gui.px(80), gui.px(640)));
    c.ImGui_SetNextWindowPos(gui.vec2(viewport.*.WorkPos.x + (viewport.*.WorkSize.x - size.x) / 2, viewport.*.WorkPos.y + gui.px(60)), 0);
    c.ImGui_SetNextWindowSize(size, 0);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_WindowBg, theme.panel);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(20), gui.px(16)));
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 1);
    defer c.ImGui_PopStyleVarEx(2);
    defer c.ImGui_PopStyleColor();
    if (c.ImGui_Begin("Keyboard shortcuts", &open, c.ImGuiWindowFlags_NoCollapse | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoTitleBar)) {
        gui.title("Keyboard shortcuts", 15);
        gui.textColored(theme.text_tertiary, "As in Lightroom and Bridge");
        c.ImGui_Dummy(gui.vec2(0, gui.px(4)));
        const column = (c.ImGui_GetContentRegionAvail().x - gui.px(24)) / 2;
        for (groups, 0..) |group, g| {
            if (g == 4) {
                // The second column starts with the settings.
                c.ImGui_SetCursorPos(gui.vec2(gui.px(20) + column + gui.px(24), gui.px(16) + c.ImGui_GetTextLineHeight() * 2 + gui.px(28) + gui.px(4)));
            }
            const x = c.ImGui_GetCursorPosX();
            if (g >= 4) c.ImGui_SetCursorPosX(gui.px(20) + column + gui.px(24));
            gui.heading(group[0]);
            for (group[1]) |command| {
                if (g >= 4) c.ImGui_SetCursorPosX(gui.px(20) + column + gui.px(24));
                const row_x = c.ImGui_GetCursorPosX();
                gui.textColored(theme.text_secondary, command.describe());
                c.ImGui_SameLineEx(row_x + column - gui.px(110), 0);
                fonts.pushSized(.mono, 12);
                gui.text(label(command));
                fonts.pop();
            }
            c.ImGui_SetCursorPosX(x);
            c.ImGui_Dummy(gui.vec2(0, gui.px(4)));
        }
        if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape) or (c.ImGui_IsMouseClicked(0) and !c.ImGui_IsWindowHovered(0))) open = false;
    }
    c.ImGui_End();
    return open;
}
