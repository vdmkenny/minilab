//! The Settings window: the app's preferences, the same in every library. The gear in the header
//! and ⌘, open it. Under its title bar, a column on the left lists its pages, and the page picked
//! shows beside it.

const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const context = @import("context.zig");
const shortcuts = @import("shortcuts.zig");
const i18n = @import("../i18n/i18n.zig");
const version = @import("../version.zig");
const Icon = @import("../ui/icons.zig").Icon;

const preferences = minilab.preferences;
const Appearance = preferences.Appearance;
const Language = preferences.Language;

/// The pages, in the order the column lists them.
const Page = enum {
    appearance,
    language,
    about,

    fn label(page: Page) [:0]const u8 {
        return switch (page) {
            .appearance => i18n.t.settings.appearance,
            .language => i18n.t.settings.language,
            .about => i18n.t.settings.about,
        };
    }

    fn icon(page: Page) Icon {
        return switch (page) {
            .appearance => .sun_moon,
            .language => .languages,
            .about => .info,
        };
    }

    /// The page's heading, in capitals as the design writes headings, or null for a page that
    /// has its own title.
    fn heading(page: Page) ?[]const u8 {
        return switch (page) {
            .appearance => i18n.t.settings.appearance_heading,
            .language => i18n.t.settings.language_heading,
            .about => null,
        };
    }

    /// Whether the column keeps the page at its foot, under a line, apart from the settings.
    fn atFoot(page: Page) bool {
        return switch (page) {
            .appearance, .language => false,
            .about => true,
        };
    }
};

pub const State = struct {
    open: bool = false,
    page: Page = .appearance,
};

/// The window's layout, in the design's pixels: its size and corners, the title bar, the column
/// of pages and its items, and the padding around a page.
const layout = struct {
    const width = 640;
    const height = 460;
    const rounding = 8;
    const title_height = 48;
    const title_padding = 20;
    const hint_gap = 10;
    const hint_padding_x = 6;
    const hint_padding_y = 1;
    const hint_rounding = 4;
    const close_inset = 10;
    const column_width = 180;
    const column_padding = 12;
    const item_height = 34;
    const item_padding = 12;
    const item_icon_gap = 10;
    const item_gap = 2;
    const page_padding_x = 28;
    const page_padding_y = 24;
    const heading_gap = 16;
};

/// How the interface looks with `values`, when the system's appearance is light or not.
pub fn look(values: preferences.Preferences, system_light: bool) theme.Look {
    const mode: theme.Mode = switch (values.appearance) {
        .dark => .dark,
        .light => .light,
        .system => if (system_light) .light else .dark,
    };
    return .{ .mode = mode, .dark_viewer = values.always_dark_viewer };
}

/// Draws the Settings window while it's open. Changes are kept straight away, so it has no OK
/// button: the close button or Esc puts it away.
pub fn draw(state: *State, saved: *preferences.Saved, ctx: context.Context, system_language: ?Language) void {
    if (!state.open) return;
    if (!begin()) {
        state.open = false;
        return;
    }
    defer c.ImGui_EndPopup();
    var values = saved.values;

    const origin = c.ImGui_GetWindowPos();
    const list = c.ImGui_GetWindowDrawList();
    const size = gui.vec2(gui.px(layout.width), gui.px(layout.height));
    const title_bottom = origin.y + gui.px(layout.title_height);
    const column_right = origin.x + gui.px(layout.column_width);
    // The column, in the page's colour, under the title bar and down to the window's corner.
    c.ImDrawList_AddRectFilledEx(list, gui.vec2(origin.x, title_bottom), gui.vec2(column_right, origin.y + size.y), theme.imU32(theme.colors.page), gui.px(layout.rounding), c.ImDrawFlags_RoundCornersBottomLeft);
    const line = theme.imU32(theme.colors.divider);
    c.ImDrawList_AddLine(list, gui.vec2(origin.x, title_bottom), gui.vec2(origin.x + size.x, title_bottom), line);
    c.ImDrawList_AddLine(list, gui.vec2(column_right, title_bottom), gui.vec2(column_right, origin.y + size.y), line);

    if (drawTitleBar(origin, size.x)) {
        state.open = false;
        c.ImGui_CloseCurrentPopup();
    }
    drawColumn(state, gui.vec2(origin.x, title_bottom), origin.y + size.y);

    c.ImGui_SetCursorScreenPos(gui.vec2(column_right + gui.px(layout.page_padding_x), title_bottom + gui.px(layout.page_padding_y)));
    const page_size = gui.vec2(origin.x + size.x - column_right - gui.px(2 * layout.page_padding_x), origin.y + size.y - title_bottom - gui.px(2 * layout.page_padding_y));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.withAlpha(theme.colors.panel, 0));
    _ = c.ImGui_BeginChild("page", page_size, c.ImGuiChildFlags_None, 0);
    if (state.page.heading()) |heading| {
        gui.heading(heading);
        c.ImGui_Dummy(gui.vec2(0, gui.px(layout.heading_gap) - c.ImGui_GetStyle().*.ItemSpacing.y));
    }
    switch (state.page) {
        .appearance => drawAppearance(&values),
        .language => drawLanguage(&values, system_language),
        .about => drawAbout(),
    }
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    if (c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
        state.open = false;
        c.ImGui_CloseCurrentPopup();
    }
    saved.set(ctx.gpa, ctx.io, values) catch |err| {
        std.log.warn("can't save the preferences: {t}", .{err});
        ctx.notice.set("{s}", .{i18n.t.settings.not_saved});
    };
}

/// Opens the window in the middle of the app, on whole pixels so its edges stay sharp. When it
/// returns true, draw it and then call `c.ImGui_EndPopup`.
fn begin() bool {
    const id = "settings";
    gui.dimBehindDialog();
    if (!c.ImGui_IsPopupOpen(id, 0)) _ = c.ImGui_OpenPopup(id, 0);
    const size = gui.vec2(gui.px(layout.width), gui.px(layout.height));
    const centre = c.ImGuiViewport_GetCenter(c.ImGui_GetMainViewport());
    c.ImGui_SetNextWindowPos(gui.vec2(@floor(centre.x - size.x / 2), @floor(centre.y - size.y / 2)), c.ImGuiCond_Always);
    c.ImGui_SetNextWindowSize(size, c.ImGuiCond_Always);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(0, 0));
    // A modal takes the window style, not the popup one.
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowRounding, gui.px(layout.rounding));
    c.ImGui_PushStyleVar(c.ImGuiStyleVar_WindowBorderSize, 1);
    defer c.ImGui_PopStyleVarEx(3);
    const flags = c.ImGuiWindowFlags_NoTitleBar | c.ImGuiWindowFlags_NoResize | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse;
    return c.ImGui_BeginPopupModal(id, null, flags);
}

/// The title, its shortcut as a key cap, and the close button. Returns true when the close button
/// is clicked.
fn drawTitleBar(origin: gui.Vec2, width: f32) bool {
    const list = c.ImGui_GetWindowDrawList();
    const middle = origin.y + gui.px(layout.title_height) / 2;
    fonts.pushSized(.semibold, fonts.title_size);
    const title = i18n.t.settings.title;
    const title_size = c.ImGui_CalcTextSize(title);
    const title_x = origin.x + gui.px(layout.title_padding);
    c.ImDrawList_AddText(list, gui.vec2(title_x, @round(middle - title_size.y / 2)), theme.imU32(theme.colors.text), title);
    fonts.pop();

    fonts.pushSized(.mono, fonts.small_size);
    const keys = shortcuts.label(.settings);
    const keys_size = c.ImGui_CalcTextSize(keys);
    const cap_min = gui.vec2(@round(title_x + title_size.x + gui.px(layout.hint_gap)), @round(middle - keys_size.y / 2 - gui.px(layout.hint_padding_y)));
    const cap_max = gui.vec2(@round(cap_min.x + keys_size.x + gui.px(2 * layout.hint_padding_x)), @round(cap_min.y + keys_size.y + gui.px(2 * layout.hint_padding_y)));
    c.ImDrawList_AddRectEx(list, cap_min, cap_max, theme.imU32(theme.colors.border), gui.px(layout.hint_rounding), 1, 0);
    c.ImDrawList_AddText(list, gui.vec2(cap_min.x + gui.px(layout.hint_padding_x), cap_min.y + gui.px(layout.hint_padding_y)), theme.imU32(theme.colors.text_tertiary), keys);
    fonts.pop();

    const side = c.ImGui_GetFrameHeight();
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x + width - gui.px(layout.close_inset) - side, @round(middle - side / 2)));
    const closed = gui.iconButton("close", .quiet, .x);
    shortcuts.tooltip(i18n.t.common.close, .cancel);
    return closed;
}

/// The column of pages, from `top_left` down to `bottom`, with the one showing marked. The
/// settings go from the top; the pages kept at the foot, like About, go from the bottom, under a
/// line.
fn drawColumn(state: *State, top_left: gui.Vec2, bottom: f32) void {
    const x = top_left.x + gui.px(layout.column_padding);
    const width = gui.px(layout.column_width - 2 * layout.column_padding);
    const step = gui.px(layout.item_height + layout.item_gap);
    var top = top_left.y + gui.px(layout.column_padding);
    var foot = bottom - gui.px(layout.column_padding + layout.item_height);
    const pages = std.enums.values(Page);
    for (pages) |page| if (!page.atFoot()) {
        drawItem(state, page, gui.vec2(x, top), width);
        top += step;
    };
    var i = pages.len;
    while (i > 0) {
        i -= 1;
        if (!pages[i].atFoot()) continue;
        drawItem(state, pages[i], gui.vec2(x, foot), width);
        foot -= step;
    }
    const line_y = foot + step - gui.px(layout.column_padding);
    c.ImDrawList_AddLine(c.ImGui_GetWindowDrawList(), gui.vec2(x, line_y), gui.vec2(x + width, line_y), theme.imU32(theme.colors.divider));
}

/// One page in the column, `width` wide from `min`: filled while it's showing, and lighter while
/// hovered.
fn drawItem(state: *State, page: Page, min: gui.Vec2, width: f32) void {
    const list = c.ImGui_GetWindowDrawList();
    const max = gui.vec2(min.x + width, min.y + gui.px(layout.item_height));
    c.ImGui_SetCursorScreenPos(min);
    if (c.ImGui_InvisibleButton(gui.print("##{t}", .{page}), gui.vec2(width, max.y - min.y), 0)) state.page = page;
    const current = page == state.page;
    const hovered = c.ImGui_IsItemHovered(0);
    if (current or hovered) c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(if (current) theme.colors.control else theme.colors.control_hover), gui.px(gui.control_rounding), 0);
    const ink = if (current) theme.colors.text else theme.colors.text_secondary;
    const icon_x = min.x + gui.px(layout.item_padding);
    gui.drawIcon(page.icon(), gui.vec2(icon_x + gui.px(gui.icon_size) / 2, (min.y + max.y) / 2), ink);
    fonts.push(if (current) .semibold else .regular);
    const label_y = @round(min.y + (max.y - min.y - c.ImGui_GetTextLineHeight()) / 2);
    c.ImDrawList_AddText(list, gui.vec2(icon_x + gui.px(gui.icon_size + layout.item_icon_gap), label_y), theme.imU32(ink), page.label());
    fonts.pop();
}

/// The appearances in the order the page shows them, with their icons.
const appearances = [_]struct { Appearance, Icon }{
    .{ .system, .monitor },
    .{ .dark, .moon },
    .{ .light, .sun },
};

/// The languages in the order the page lists them.
const languages = std.enums.values(Language);
/// The language menu's width, in the design's pixels.
const language_width = 220;

/// The language the interface uses with `values`, when the system's is `system`: the one picked,
/// or the system's, or English. A language that needs a font the computer doesn't have, like
/// Japanese, falls back to English too.
pub fn language(values: preferences.Preferences, system: ?Language) Language {
    const wanted = values.language orelse system orelse .en;
    if (wanted.needsCjkFont() and !fonts.hasJapanese()) return .en;
    return wanted;
}

/// The Language page: System, which follows the computer, then each language by its own name.
fn drawLanguage(values: *preferences.Preferences, system: ?Language) void {
    gui.rowLabel(i18n.t.settings.language);
    var names: [languages.len + 1][]const u8 = undefined;
    const system_or_english: Language = system orelse .en;
    names[0] = gui.say(i18n.t.settings.system_language, .{system_or_english.autonym()});
    for (names[1..], languages) |*name, each| name.* = each.autonym();
    const chosen = if (values.language) |each| gui.indexIn(Language, languages, each) + 1 else 0;
    if (gui.combo("language", &names, chosen, language_width)) |picked| {
        values.language = if (picked == 0) null else languages[picked - 1];
    }
    const wanted = values.language orelse system orelse .en;
    if (language(values.*, system) != wanted) drawWarning(i18n.t.settings.no_japanese_font);
}

/// The gap after the warning's icon, in the design's pixels.
const warning_gap = 6;

fn drawAppearance(values: *preferences.Preferences) void {
    gui.rowLabel(i18n.t.settings.interface);
    var choices: [appearances.len]gui.IconChoice = undefined;
    for (&choices, appearances) |*choice, a| choice.* = .{ .icon = a[1], .name = i18n.label(i18n.t.labels.appearance, a[0]) };
    const chosen = for (appearances, 0..) |a, i| {
        if (a[0] == values.appearance) break i;
    } else unreachable;
    if (gui.iconSegmented("appearance", &choices, chosen)) |picked| values.appearance = appearances[picked][0];
    if (values.appearance != .dark) drawWarning(i18n.t.settings.light_warning);

    gui.rowLabel(i18n.t.settings.viewer);
    _ = gui.checkboxWith(i18n.t.settings.always_dark, &values.always_dark_viewer, .{ .label_color = theme.colors.text });
}

/// Where minilab lives online.
const website = "https://vdmkenny.github.io/minilab/";
const source = "https://github.com/" ++ minilab.update.repository;

/// The libraries, fonts, icons and looks built into minilab, for the credits. Their licences are
/// installed next to the program.
/// The libraries are names, so they're the same in every language.
const libraries = "Dear ImGui, SDL3, LibRaw, libtiff, libjpeg-turbo, Little CMS";
/// The licence's name, the same in every language.
const license = "Mozilla Public License 2.0";

/// The gaps on the About page, in the design's pixels.
const about_gap = 16;

fn drawAbout() void {
    gui.title("minilab", fonts.page_title_size);
    fonts.pushSized(.mono, fonts.small_size);
    gui.textColored(theme.colors.text_tertiary, version.string);
    fonts.pop();
    gui.textColored(theme.colors.text_secondary, i18n.t.settings.tagline);
    c.ImGui_Dummy(gui.vec2(0, gui.px(about_gap) - c.ImGui_GetStyle().*.ItemSpacing.y));
    if (gui.iconButton("website", .normal, .globe)) gui.openUrl(website);
    gui.tooltip(i18n.t.settings.website);
    c.ImGui_SameLineEx(0, gui.px(gui.dialog.gap));
    if (gui.iconButton("source code", .normal, .code)) gui.openUrl(source);
    gui.tooltip(i18n.t.settings.source_code);
    c.ImGui_Dummy(gui.vec2(0, gui.px(about_gap) - c.ImGui_GetStyle().*.ItemSpacing.y));
    gui.heading(i18n.t.settings.built_with);
    for ([_][]const u8{ libraries, i18n.t.settings.built_with_icons, i18n.t.settings.built_with_looks, license }) |line| {
        gui.textColored(theme.colors.text_tertiary, line);
    }
    c.ImGui_Dummy(gui.vec2(0, gui.px(about_gap) - c.ImGui_GetStyle().*.ItemSpacing.y));
    gui.heading(i18n.t.settings.ai_disclosure);
    for ([_][]const u8{ i18n.t.settings.ai_written, i18n.t.settings.ai_not_inside }) |line| gui.textColored(theme.colors.text_tertiary, line);
}

/// A warning under a row's control, lined up with it.
fn drawWarning(message: [:0]const u8) void {
    c.ImGui_SetCursorPosX(c.ImGui_GetCursorPosX() + gui.px(gui.label_column + gui.label_gap));
    const at = c.ImGui_GetCursorScreenPos();
    const icon = gui.px(gui.icon_size);
    gui.drawIcon(.triangle_alert, gui.vec2(at.x + icon / 2, at.y + c.ImGui_GetTextLineHeight() / 2), theme.colors.accent);
    c.ImGui_SetCursorScreenPos(gui.vec2(at.x + icon + gui.px(warning_gap), at.y));
    gui.textColored(theme.colors.accent, message);
}

test "the language is the one picked, or the system's, or English" {
    try std.testing.expectEqual(Language.nl, language(.{ .language = .nl }, .fr));
    try std.testing.expectEqual(Language.fr, language(.{}, .fr));
    try std.testing.expectEqual(Language.en, language(.{}, null));
}

test "the system appearance only counts when the preference follows it" {
    try std.testing.expectEqual(theme.Mode.light, look(.{ .appearance = .system }, true).mode);
    try std.testing.expectEqual(theme.Mode.dark, look(.{ .appearance = .system }, false).mode);
    try std.testing.expectEqual(theme.Mode.dark, look(.{ .appearance = .dark }, true).mode);
    try std.testing.expectEqual(theme.Mode.light, look(.{ .appearance = .light }, false).mode);
    try std.testing.expect(look(.{}, false).dark_viewer);
}
