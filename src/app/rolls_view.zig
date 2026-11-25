//! The Rolls workspace: a contact sheet for each roll, with its card and filmstrip, and the panel
//! for making a new roll.

const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const labels = @import("labels.zig");
const Library = @import("library.zig").Library;
const shortcuts = @import("shortcuts.zig");
const holes = @import("holes.zig");
const Dialog = @import("../platform/file_dialog.zig").Dialog;
const account = @import("../platform/account.zig");
const clock = @import("../platform/clock.zig");
const roll_details = @import("roll_details.zig");
const icons = @import("../ui/icons.zig");
const i18n = @import("../i18n/i18n.zig");

const roll = minilab.roll;
const develop = minilab.develop;
const formats = minilab.formats;

/// Sizes in the design's pixels.
const page_padding_x = 20;
const page_padding_y = 16;
const card_width = 210;
const card_padding_x = 14;
const card_padding_y = 12;
const thumb_gap = 4;
/// The film before the first frame and after the last, in mm.
const leader_mm: f32 = 3;
/// The narrowest gap between frames on the strip, in mm, for film whose frames have none.
const min_frame_gap_mm: f32 = 1;
/// The border around each sheet of sheet film, in mm.
const sheet_border_mm: f32 = 1.5;
const row_gap = 12;
const form_width = 340;
const search_width = 240;
/// The title row: the size filter, the gaps between its parts, and the New roll button's plus sign
/// and the gap after it.
const filter_width = 130;
const title_row_gap = 10;
const count_gap = 20;
const new_icon = 14;
const new_icon_gap = 6;
const new_plus_arm = 5;
const new_plus_thickness = 1.8;
/// The space under the title row.
const title_gap = 14;
/// A roll card's rows: the name's and the date's line heights, the gap between rows, the gap
/// above the progress line, and the bar.
const card_title_line = 21;
const card_date_line = 17;
const card_row_gap = 3;
const card_bar_gap = 6;
const card_bar = 3;
const card_rounding = 6;
/// The Edit and Delete buttons' distance from the card's corner, and the gap between them.
const card_button_inset = 6;
const card_button_gap = 2;
/// The filmstrip: its gap from the card, the frame numbers under it, the corners of the film and
/// the pictures, and the "+N more" box.
const strip_gap = 12;
const number_gap = 3;
const number_height = 15;
const film_rounding = 2;
const thumb_rounding = 1;
const more_padding = 14;
const more_dash = 4;
const more_dash_gap = 3;
/// The new-roll panel: its padding, the space between its rows, the notes box, its close button's
/// x, and the Create button.
const form_padding = 16;
const form_spacing = 10;
const notes_lines = 3;
const notes_padding = 12;
const close_arm = 4;
const close_thickness = 1.6;
const create_height = 38;
/// The longest path the form can hold.
const path_field = 1024;

/// The file types the flat field's button lets you pick.
const flat_files = [_]c.SDL_DialogFileFilter{
    .{ .name = "Camera RAW and TIFF", .pattern = minilab.input.extensions },
};

pub const State = struct {
    search: [gui.text_capacity:0]u8 = @splat(0),
    /// The film size shown, or null for all of them.
    size_filter: ?formats.FilmSize = null,
    /// What the panel on the right shows, if anything.
    panel: Panel = .closed,
    form: Form = .{},
    /// The boxes for the details of the roll in the details panel.
    details: roll_details.Boxes = .{},
    /// Move the keyboard focus to the search field on the next frame.
    focus_search: bool = false,
    /// The dialog for the new roll's flat field.
    flat_dialog: Dialog = .{ .filters = &flat_files },
    /// The folder of the roll whose Delete was clicked, waiting for the confirmation. It's kept
    /// by path, not by place in the list, because the list changes when rolls are added on disk.
    deleting: ?[]u8 = null,

    pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
        state.flat_dialog.deinit(gpa);
        state.stopDeleting(gpa);
        state.closePanel(gpa);
    }

    /// Opens the New roll panel with a fresh form, or closes it when it's already open.
    pub fn toggleNewRoll(state: *State, gpa: std.mem.Allocator) void {
        const was_open = state.panel == .new_roll;
        state.closePanel(gpa);
        if (!was_open) state.openNewRoll(gpa);
    }

    /// Opens the New roll panel with a fresh form.
    pub fn openNewRoll(state: *State, gpa: std.mem.Allocator) void {
        state.closePanel(gpa);
        state.form = .{};
        state.panel = .new_roll;
    }

    /// Opens the details panel for the roll in folder `path`.
    fn showDetails(state: *State, gpa: std.mem.Allocator, path: []const u8) void {
        const copy = gpa.dupe(u8, path) catch return;
        state.closePanel(gpa);
        state.details = .{};
        state.panel = .{ .details = copy };
    }

    fn isShowingDetails(state: *const State, path: []const u8) bool {
        return switch (state.panel) {
            .details => |showing| std.mem.eql(u8, showing, path),
            else => false,
        };
    }

    pub fn closePanel(state: *State, gpa: std.mem.Allocator) void {
        if (state.panel == .details) gpa.free(state.panel.details);
        state.panel = .closed;
    }

    fn startDeleting(state: *State, gpa: std.mem.Allocator, path: []const u8) void {
        const copy = gpa.dupe(u8, path) catch return;
        state.stopDeleting(gpa);
        state.deleting = copy;
    }

    fn stopDeleting(state: *State, gpa: std.mem.Allocator) void {
        if (state.deleting) |p| gpa.free(p);
        state.deleting = null;
    }

    fn isDeleting(state: *const State, path: []const u8) bool {
        const deleting = state.deleting orelse return false;
        return std.mem.eql(u8, deleting, path);
    }
};

/// What the panel on the right of the Rolls page shows.
const Panel = union(enum) {
    closed,
    new_roll,
    /// The details of the roll in this folder, to edit. It's kept by path, as Delete's roll is.
    details: []u8,
};

/// The fields for the new roll.
const Form = struct {
    name: [gui.text_capacity:0]u8 = @splat(0),
    kind: develop.FilmKind = .colour_negative,
    /// Indices in the lists of stocks and formats, which depend on the film type and size.
    stock: usize = 0,
    size: formats.FilmSize = .@"135",
    format: usize = 0,
    camera: [gui.text_capacity:0]u8 = @splat(0),
    lens: [gui.text_capacity:0]u8 = @splat(0),
    /// The day the roll was shot, as Export takes it: YYYY, YYYY-MM or YYYY-MM-DD.
    shot: [gui.text_capacity:0]u8 = @splat(0),
    copyright: [gui.text_capacity:0]u8 = @splat(0),
    notes: [gui.text_capacity * 4:0]u8 = @splat(0),
    input: roll.Input = .scanner,
    /// The flat field for a camera roll: a file with a shot of the light source and no film.
    flat: [path_field:0]u8 = @splat(0),
    /// Whether the defaults (the next roll's name, today's date and the copyright) have been
    /// filled in since the form was last opened.
    filled: bool = false,
    /// Why the last click on Create didn't make the roll.
    problem: ?[]const u8 = null,
};

/// What the user did on the sheet.
pub const Action = union(enum) {
    none,
    /// Open the roll in Develop, at this frame.
    open: struct { roll: usize, frame: usize = 0 },
    created: Created,
    /// Files were dropped on this roll's row.
    dropped_on: usize,
    /// Move this roll to the Trash, after it was confirmed.
    trash: usize,
};

/// A roll New roll made.
pub const Created = struct {
    roll: usize,
    /// Set when the flat field given couldn't be used, so the roll has none.
    flat_failed: bool = false,
};

const film_sizes = std.enums.values(formats.FilmSize);
/// The inputs the form offers.
const form_inputs = [_]roll.Input{ .scanner, .camera_raw, .tiff_files };

/// The standard formats for film size `size`.
fn formatsOf(size: formats.FilmSize, buffer: []formats.Standard) []formats.Standard {
    var n: usize = 0;
    for (std.enums.values(formats.Standard)) |id| {
        if (id.format().size != size) continue;
        buffer[n] = id;
        n += 1;
    }
    return buffer[0..n];
}

/// Draws the sheet. `drop` is where files were dropped this frame, if any were.
pub fn draw(state: *State, library: *Library, gpa: std.mem.Allocator, io: std.Io, drop: ?gui.Vec2) Action {
    var action: Action = .none;
    const available = c.ImGui_GetContentRegionAvail();
    const top = c.ImGui_GetCursorScreenPos();
    const form = if (state.panel == .closed) 0 else gui.px(form_width);

    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.colors.page);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(page_padding_x), gui.px(page_padding_y)));
    _ = c.ImGui_BeginChild("sheet", gui.vec2(available.x - form, available.y), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_None);
    c.ImGui_PopStyleVar();
    drawTitleRow(state, library, gpa);
    c.ImGui_Dummy(gui.vec2(0, gui.px(title_gap) - c.ImGui_GetStyle().*.ItemSpacing.y * 2));

    var shown: usize = 0;
    for (library.rolls.items, 0..) |*r, i| {
        if (!matches(state, r.info)) continue;
        shown += 1;
        c.ImGui_PushIDInt(@intCast(i));
        if (drawRow(state, library, gpa, r, i, drop)) |row_action| action = row_action;
        c.ImGui_PopID();
        c.ImGui_Dummy(gui.vec2(0, gui.px(row_gap) - c.ImGui_GetStyle().*.ItemSpacing.y * 2));
    }
    if (library.rolls.items.len == 0) {
        gui.paragraph(theme.colors.text_tertiary, i18n.t.rolls.no_rolls);
    } else if (shown == 0) {
        gui.paragraph(theme.colors.text_tertiary, i18n.t.rolls.no_matching_rolls);
    }
    if (drawDeleteConfirmation(state, library, gpa)) |index| action = .{ .trash = index };
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    if (state.panel != .closed) {
        c.ImGui_SetCursorScreenPos(gui.vec2(top.x + available.x - form, top.y));
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(form_padding), gui.px(form_padding)));
        _ = c.ImGui_BeginChild("panel", gui.vec2(form, available.y), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_None);
        c.ImGui_PopStyleVar();
        const window = c.ImGui_GetWindowPos();
        c.ImDrawList_AddLine(c.ImGui_GetWindowDrawList(), window, gui.vec2(window.x, window.y + available.y), theme.imU32(theme.colors.divider));
        switch (state.panel) {
            .closed => {},
            .new_roll => if (drawForm(state, library, gpa, io)) |created| {
                action = .{ .created = created };
            },
            .details => |path| drawDetails(state, library, gpa, io, path),
        }
        c.ImGui_EndChild();
    }
    return action;
}

fn matches(state: *const State, info: roll.Info) bool {
    if (state.size_filter) |size| if (info.format.format().size != size) return false;
    const query = std.mem.sliceTo(&state.search, 0);
    if (query.len == 0) return true;
    for ([_]?[]const u8{ info.name, info.stock, info.camera }) |field| {
        if (field) |f| if (gui.containsIgnoreCase(f, query)) return true;
    }
    return false;
}

/// Draws the title row: "Rolls" and where the library is, then search, the film-size filter and
/// New roll on the right.
fn drawTitleRow(state: *State, library: *Library, gpa: std.mem.Allocator) void {
    const row_top = c.ImGui_GetCursorPosY();
    const height = c.ImGui_GetFrameHeight();
    const right = c.ImGui_GetContentRegionAvail().x + c.ImGui_GetCursorPosX();
    const new_label = i18n.t.rolls.new_roll;
    fonts.push(.semibold);
    const new_width = c.ImGui_CalcTextSize(new_label).x + gui.px(2 * gui.button_padding + new_icon + new_icon_gap);
    fonts.pop();
    const controls = gui.px(search_width + filter_width + 2 * title_row_gap) + new_width;

    fonts.pushSized(.semibold, fonts.page_title_size);
    const title_height = c.ImGui_GetFontSize();
    c.ImGui_SetCursorPosY(row_top + (height - title_height) / 2);
    gui.text(i18n.t.rolls.title);
    fonts.pop();
    c.ImGui_SameLineEx(0, gui.px(title_row_gap));
    c.ImGui_SetCursorPosY(row_top);
    c.ImGui_AlignTextToFramePadding();
    const rolls = library.rolls.items.len;
    const count = gui.print(" · {s}", .{gui.say(if (rolls == 1) i18n.t.rolls.roll_count_one else i18n.t.rolls.roll_count_many, .{rolls})});
    const room = right - c.ImGui_GetCursorPosX() - controls - gui.px(count_gap) - c.ImGui_CalcTextSize(count).x;
    gui.textColored(theme.colors.text_tertiary, gui.print("{s}{s}", .{ gui.elideStart(library.label, room), count }));

    c.ImGui_SameLineEx(right - controls, 0);
    if (state.focus_search) c.ImGui_SetKeyboardFocusHere();
    state.focus_search = false;
    _ = gui.textField("search", &state.search, i18n.t.rolls.search_hint, search_width);
    shortcuts.tooltip(i18n.t.rolls.search_tooltip, .find);
    c.ImGui_SameLineEx(0, gui.px(title_row_gap));
    // All film sizes, then each size.
    var filter_names: [film_sizes.len + 1][]const u8 = undefined;
    filter_names[0] = i18n.t.rolls.all_film_sizes;
    for (filter_names[1..], film_sizes) |*name, size| name.* = size.label();
    const filter_index = if (state.size_filter) |size| gui.indexIn(formats.FilmSize, film_sizes, size) + 1 else 0;
    if (gui.combo("film size", &filter_names, filter_index, filter_width)) |picked| {
        state.size_filter = if (picked == 0) null else film_sizes[picked - 1];
    }
    c.ImGui_SameLineEx(0, gui.px(title_row_gap));
    const corner = c.ImGui_GetCursorScreenPos();
    if (gui.buttonOf(.primary, "##new roll", gui.vec2(new_width / gui.scale, height / gui.scale))) {
        state.toggleNewRoll(gpa);
    }
    shortcuts.tooltip(new_label, .new_roll);
    // The plus sign, then the label: the button's padding in, the icon, then a gap.
    const list = c.ImGui_GetWindowDrawList();
    gui.plus(list, gui.vec2(corner.x + gui.px(gui.button_padding + new_icon / 2), corner.y + height / 2), gui.px(new_plus_arm), gui.px(new_plus_thickness), theme.colors.on_accent);
    fonts.push(.semibold);
    c.ImDrawList_AddText(list, gui.vec2(corner.x + gui.px(gui.button_padding + new_icon + new_icon_gap), corner.y + (height - c.ImGui_GetTextLineHeight()) / 2), theme.imU32(theme.colors.on_accent), new_label);
    fonts.pop();
}

/// Asks whether to delete the roll whose Delete was clicked. Returns its index once confirmed.
fn drawDeleteConfirmation(state: *State, library: *const Library, gpa: std.mem.Allocator) ?usize {
    const path = state.deleting orelse return null;
    // The roll went in the meantime.
    const index = library.find(path) orelse {
        state.stopDeleting(gpa);
        return null;
    };
    const r = library.rolls.items[index];
    if (!gui.beginDialog("delete roll")) {
        state.stopDeleting(gpa);
        return null;
    }
    defer c.ImGui_EndPopup();
    gui.title(gui.say(i18n.t.rolls.delete_title, .{r.info.name}), fonts.title_size);
    const frames = r.frames.items.len;
    gui.textColored(theme.colors.text_tertiary, gui.say(if (frames == 1) i18n.t.rolls.frame_count_one else i18n.t.rolls.frame_count_many, .{frames}));
    c.ImGui_Dummy(gui.vec2(0, gui.px(gui.dialog.gap)));
    var confirmed: ?usize = null;
    if (gui.buttonOf(.primary, i18n.t.rolls.move_to_trash, gui.vec2(0, gui.button_height))) confirmed = index;
    c.ImGui_SameLineEx(0, gui.px(gui.dialog.gap));
    const cancelled = gui.buttonOf(.normal, i18n.t.common.cancel, gui.vec2(0, gui.button_height)) or c.ImGui_IsKeyPressed(c.ImGuiKey_Escape);
    if (confirmed != null or cancelled) {
        state.stopDeleting(gpa);
        c.ImGui_CloseCurrentPopup();
    }
    return confirmed;
}

/// The Edit and Delete buttons on a roll's card, shown while the card is hovered.
const card_button_size = 22;

/// Draws one roll: its card, then its filmstrip.
fn drawRow(state: *State, library: *Library, gpa: std.mem.Allocator, r: *roll.Roll, index: usize, drop: ?gui.Vec2) ?Action {
    const origin = c.ImGui_GetCursorScreenPos();
    const list = c.ImGui_GetWindowDrawList();
    const card_height = gui.px(card_padding_y * 2 + card_title_line + card_date_line + 4 * card_row_gap + card_bar_gap + card_bar) + gui.lineHeight() * 3;
    const right = c.ImGui_GetWindowPos().x + c.ImGui_GetWindowWidth() - gui.px(page_padding_x);
    // The frame numbers go under the filmstrip, below the card.
    const row_height = card_height + gui.px(number_gap + number_height);
    var action = drawCard(state, gpa, r, index, list, origin, card_height);
    if (drawStrip(library, gpa, r, index, list, origin, card_height, right)) |clicked| action = clicked;

    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, origin.y + row_height));
    c.ImGui_Dummy(gui.vec2(0, 0));
    if (action == null) {
        if (drop) |p| {
            if (p.y >= origin.y and p.y < origin.y + row_height and p.x >= origin.x and p.x < right) action = .{ .dropped_on = index };
        }
    }
    return action;
}

/// Draws roll `index`'s card at `origin`, `card_height` high: its name, date, stock, format and
/// how much of it is developed, with Delete over it while the mouse is on it. Returns Open when
/// it's clicked.
fn drawCard(state: *State, gpa: std.mem.Allocator, r: *roll.Roll, index: usize, list: *c.ImDrawList, origin: gui.Vec2, card_height: f32) ?Action {
    var action: ?Action = null;
    const line = gui.lineHeight();
    // Its Delete button sits on top of it.
    c.ImGui_SetNextItemAllowOverlap();
    if (c.ImGui_InvisibleButton("card", gui.vec2(gui.px(card_width), card_height), 0)) action = .{ .open = .{ .roll = index } };
    const hovered = c.ImGui_IsItemHovered(0);
    c.ImDrawList_AddRectFilledEx(list, origin, gui.vec2(origin.x + gui.px(card_width), origin.y + card_height), theme.imU32(if (hovered) theme.colors.control else theme.colors.panel), gui.px(card_rounding), 0);
    var at = gui.vec2(origin.x + gui.px(card_padding_x), origin.y + gui.px(card_padding_y));
    const inner = gui.px(card_width - 2 * card_padding_x);
    fonts.pushSized(.semibold, fonts.title_size);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.colors.text), gui.elideEnd(r.info.name, inner));
    fonts.pop();
    at.y += gui.px(card_title_line + card_row_gap);
    fonts.pushSized(.mono, fonts.small_size);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.colors.accent), gui.print("{s}", .{r.info.shot orelse r.info.created orelse ""}));
    fonts.pop();
    at.y += gui.px(card_date_line + card_row_gap);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.colors.text_secondary), gui.elideEnd(r.info.stock orelse labels.filmKind(r.info.kind), inner));
    at.y += line + gui.px(card_row_gap);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.colors.text_tertiary), gui.elideEnd(labels.filmAndFormat(r.info.format), inner));

    const total = r.frames.items.len;
    const developed = r.developedCount();
    const bar_y = origin.y + card_height - gui.px(card_padding_y + card_bar);
    c.ImDrawList_AddText(list, gui.vec2(at.x, bar_y - gui.px(card_row_gap) - line + (line - c.ImGui_GetTextLineHeight()) / 2), theme.imU32(theme.colors.text_secondary), gui.say(i18n.t.rolls.developed, .{ developed, total }));
    const bar_width = gui.px(card_width - 2 * card_padding_x);
    const share = if (total == 0) 0 else @as(f32, @floatFromInt(developed)) / @as(f32, @floatFromInt(total));
    gui.progressBar(list, gui.vec2(at.x, bar_y), gui.vec2(at.x + bar_width, bar_y + gui.px(card_bar)), share);

    // Edit and Delete, in the card's top right corner while the mouse is over the card.
    const mouse = c.ImGui_GetMousePos();
    const over_card = mouse.x >= origin.x and mouse.x < origin.x + gui.px(card_width) and mouse.y >= origin.y and mouse.y < origin.y + card_height;
    if (over_card or state.isDeleting(r.path) or state.isShowingDetails(r.path)) {
        const size = gui.px(card_button_size);
        const delete_corner = gui.vec2(origin.x + gui.px(card_width - card_button_inset) - size, origin.y + gui.px(card_button_inset));
        if (cardButton(list, "delete", i18n.t.rolls.delete_roll, .trash, delete_corner, theme.red)) state.startDeleting(gpa, r.path);
        const edit_corner = gui.vec2(delete_corner.x - size - gui.px(card_button_gap), delete_corner.y);
        if (cardButton(list, "edit", i18n.t.rolls.edit_details, .pencil, edit_corner, theme.colors.text)) state.showDetails(gpa, r.path);
    }
    return action;
}

/// One of the small buttons on a card, at `corner`: `icon`, in `hover` while it's hovered.
/// Returns true when it's clicked.
fn cardButton(list: *c.ImDrawList, id: [:0]const u8, name: []const u8, icon: icons.Icon, corner: gui.Vec2, hover: theme.Color) bool {
    const size = gui.px(card_button_size);
    c.ImGui_SetCursorScreenPos(corner);
    const clicked = c.ImGui_InvisibleButton(id, gui.vec2(size, size), 0);
    const on_button = c.ImGui_IsItemHovered(0);
    if (on_button) {
        gui.showTooltip(name);
        c.ImDrawList_AddRectFilledEx(list, corner, gui.vec2(corner.x + size, corner.y + size), theme.imU32(theme.colors.control_hover), gui.px(gui.choice_rounding), 0);
    }
    gui.drawIcon(icon, gui.vec2(corner.x + size / 2, corner.y + size / 2), if (on_button) hover else theme.colors.text_tertiary);
    return clicked;
}

/// Draws roll `index`'s filmstrip beside its card, up to `right`, with "+N more" when the frames
/// don't all fit. Returns Open when a frame is clicked.
fn drawStrip(library: *Library, gpa: std.mem.Allocator, r: *roll.Roll, index: usize, list: *c.ImDrawList, origin: gui.Vec2, card_height: f32, right: f32) ?Action {
    var action: ?Action = null;
    const format = r.info.format.format();
    const total = r.frames.items.len;
    // The film as high as the card and drawn to its own proportions, with the frame numbers
    // under it.
    const film_mm = format.size.filmWidthMm();
    const sheets = film_mm == null;
    const band = @round(card_height);
    const per_mm = band / (film_mm orelse format.height_mm + 2 * sheet_border_mm);
    const height = @round(format.height_mm * per_mm);
    const gap = @max(format.size.typicalGapMm(), min_frame_gap_mm) * per_mm;
    const leader = (if (sheets) sheet_border_mm else leader_mm) * per_mm;
    const strip_x = origin.x + gui.px(card_width + strip_gap);
    const strip_top = @round(origin.y);
    const thumbs_top = strip_top + @round((band - height) / 2);
    const width = @round(height * format.ratio());
    const more_width = gui.px(2 * more_padding) + c.ImGui_CalcTextSize(gui.say(i18n.t.rolls.more_frames, .{"00"})).x;
    // Each frame takes its width and the gap after it; sheets each have their own border.
    const step = width + if (sheets) 2 * leader + gap else gap;
    const room = right - strip_x + gap - if (sheets) 0 else 2 * leader;
    var fit = @max(1, @as(usize, @intFromFloat(@floor(room / step))));
    if (fit < total) fit = @max(1, @as(usize, @intFromFloat(@floor((room - more_width - gui.px(thumb_gap)) / step))));
    const shown = @min(total, fit);
    const strip_end = strip_x + @as(f32, @floatFromInt(shown)) * step - gap + if (sheets) 0 else 2 * leader;
    const film_ink = theme.imU32(theme.film);
    const strip: holes.Strip = .{ .axis = .x, .start = strip_x, .end = strip_end, .near = strip_top, .far = strip_top + band, .along_per_mm = per_mm, .across_per_mm = per_mm };
    if (shown > 0 and !sheets) {
        c.ImDrawList_AddRectFilledEx(list, gui.vec2(strip_x, strip_top), gui.vec2(strip_end, strip_top + band), film_ink, gui.px(film_rounding), 0);
        // Punched in the page's colour, so they look cut out.
        switch (format.size.holes()) {
            .none => {},
            .rows => |p| holes.rows(list, strip, p, strip_x + (p.pitch_mm - p.length_mm) * per_mm / 2, theme.colors.page),
            .per_frame => |count| for (0..shown) |i| holes.atFrame(list, strip, count, strip_x + leader + @as(f32, @floatFromInt(i)) * step, theme.colors.page),
        }
    }

    // The maker's edge print, as it comes out on a contact print. Sheet film has none.
    const edge = holes.edgeMm(format.size, format.height_mm);
    const print: holes.EdgePrint = .of(r.info.stock);
    var x = strip_x + if (sheets) 0 else leader;
    for (0..shown) |frame| {
        const picture_x = x + if (sheets) leader else 0;
        if (sheets) c.ImDrawList_AddRectFilledEx(list, gui.vec2(x, strip_top), gui.vec2(x + width + 2 * leader, strip_top + band), film_ink, gui.px(film_rounding), 0);
        if (edge) |e| holes.edgePrint(list, strip, &print, x, step, frame + 1, e, print.ink);
        const corner = gui.vec2(picture_x, thumbs_top);
        const far = gui.vec2(picture_x + width, thumbs_top + height);
        const numbers_y = strip_top + band + gui.px(number_gap);
        c.ImGui_SetCursorScreenPos(corner);
        c.ImGui_PushIDInt(@intCast(frame));
        if (c.ImGui_InvisibleButton("frame", gui.vec2(width, numbers_y + number_height - thumbs_top), 0)) action = .{ .open = .{ .roll = index, .frame = frame } };
        c.ImGui_PopID();
        if (library.thumbnail(gpa, .{ .roll = index, .frame = frame })) |t| {
            gui.imageCover(list, t.ref(), t.width, t.height, corner, far, gui.px(thumb_rounding));
        } else {
            c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.colors.control), gui.px(thumb_rounding), 0);
        }
        fonts.pushSized(.mono, fonts.caption_size);
        const number = labels.frameNumber(frame);
        const number_width = c.ImGui_CalcTextSize(number).x;
        c.ImDrawList_AddText(list, gui.vec2(picture_x + (width - number_width) / 2, numbers_y), theme.imU32(theme.colors.text_tertiary), number);
        fonts.pop();
        x += step;
    }
    if (total > shown) {
        const corner = gui.vec2(strip_end + gui.px(thumb_gap), thumbs_top);
        c.ImGui_SetCursorScreenPos(corner);
        if (c.ImGui_InvisibleButton("more", gui.vec2(more_width, height), 0)) action = .{ .open = .{ .roll = index, .frame = shown } };
        gui.dashedRect(list, corner, gui.vec2(corner.x + more_width, corner.y + height), theme.imU32(theme.colors.border), 1, gui.px(more_dash), gui.px(more_dash_gap));
        const more = gui.say(i18n.t.rolls.more_frames, .{total - shown});
        const size = c.ImGui_CalcTextSize(more);
        c.ImDrawList_AddText(list, gui.vec2(corner.x + (more_width - size.x) / 2, corner.y + (height - size.y) / 2), theme.imU32(theme.colors.text_secondary), more);
    }
    if (total == 0) {
        c.ImDrawList_AddText(list, gui.vec2(strip_x, thumbs_top + (height - c.ImGui_GetTextLineHeight()) / 2), theme.imU32(theme.colors.text_tertiary), i18n.t.rolls.no_frames);
    }
    return action;
}

/// Draws the new-roll panel. Returns the new roll's index once it's made.
fn drawForm(state: *State, library: *Library, gpa: std.mem.Allocator, io: std.Io) ?Created {
    const form = &state.form;
    if (!form.filled) {
        gui.setText(&form.name, gui.say(i18n.t.rolls.default_name, .{gui.print("{d:0>3}", .{library.rolls.items.len + 1})})) catch {};
        var today: [minilab.date.max_text]u8 = undefined;
        gui.setText(&form.shot, clock.today(io).format(&today)) catch {};
        fillCopyright(form, library);
        form.filled = true;
    }

    drawPanelTitle(state, gpa, i18n.t.rolls.new_roll);

    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gui.px(form_spacing), gui.px(form_spacing)));
    defer c.ImGui_PopStyleVar();
    gui.rowLabel(i18n.t.rolls.name);
    if (gui.textField("name", &form.name, "", 0)) form.problem = null;
    if (form.problem) |problem| {
        gui.rowLabel("");
        gui.paragraph(theme.colors.text_tertiary, problem);
    }
    gui.rowLabel(i18n.t.rolls.film_type);
    if (gui.comboOf(develop.FilmKind, "film type", &labels.film_kinds, form.kind, labels.filmKind, 0)) |picked| {
        form.kind = picked;
        form.stock = 0;
    }
    gui.rowLabel(i18n.t.rolls.stock);
    var stock_buffer: [labels.stock_choices.len + 1][]const u8 = undefined;
    const stock_names = labels.stockNames(form.kind, "Other", &stock_buffer);
    if (form.stock >= stock_names.len) form.stock = 0;
    if (gui.searchCombo("stock", stock_names, form.stock, 0, i18n.t.rolls.search_stocks)) |picked| form.stock = picked;
    gui.rowLabel(i18n.t.rolls.film_size);
    if (gui.comboOf(formats.FilmSize, "film size", film_sizes, form.size, labels.filmSizeChoice, 0)) |picked| {
        form.size = picked;
        form.format = 0;
    }
    var buffer: [std.enums.values(formats.Standard).len]formats.Standard = undefined;
    const choices = formatsOf(form.size, &buffer);
    var names: [buffer.len][]const u8 = undefined;
    for (choices, 0..) |id, i| names[i] = labels.format(id);
    gui.rowLabel(i18n.t.rolls.format);
    if (gui.combo("format", names[0..choices.len], form.format, 0)) |picked| form.format = picked;
    for ([_]struct { roll.Detail, [:0]u8, [:0]const u8 }{
        .{ .camera, &form.camera, i18n.t.rolls.camera_hint },
        .{ .lens, &form.lens, i18n.t.rolls.lens_hint },
        .{ .shot, &form.shot, i18n.t.rolls.date_hint },
        .{ .copyright, &form.copyright, i18n.t.rolls.copyright_hint },
    }) |row| {
        gui.rowLabel(roll_details.label(row[0]));
        _ = roll_details.field(row[0], row[1], row[2], 0, library, io);
    }
    const notes_x = c.ImGui_GetCursorPosX();
    gui.textColored(theme.colors.text_secondary, roll_details.label(.notes));
    c.ImGui_SameLineEx(notes_x + gui.px(gui.label_column + gui.label_gap), 0);
    _ = c.ImGui_InputTextMultilineEx("##notes", &form.notes, form.notes.len + 1, gui.vec2(-std.math.floatMin(f32), gui.lineHeight() * notes_lines + gui.px(notes_padding)), 0, null, null);
    gui.rowLabel(i18n.t.rolls.input);
    if (gui.comboOf(roll.Input, "input", &form_inputs, form.input, roll.Input.label, 0)) |picked| form.input = picked;
    if (form.input == .camera_raw) drawFlatField(state, gpa, io);

    // The button sits at the bottom of the panel.
    const bottom = c.ImGui_GetWindowHeight() - gui.px(form_padding + create_height);
    if (c.ImGui_GetCursorPosY() < bottom) c.ImGui_SetCursorPosY(bottom);
    const name = std.mem.sliceTo(&form.name, 0);
    c.ImGui_BeginDisabled(name.len == 0 or choices.len == 0);
    defer c.ImGui_EndDisabled();
    if (!gui.buttonOf(.primary, switch (form.input) {
        .scanner => i18n.t.rolls.create_and_scan,
        .camera_raw, .tiff_files, .finished => i18n.t.rolls.create,
    }, gui.vec2(c.ImGui_GetContentRegionAvail().x / gui.scale, create_height))) return null;
    return createRoll(state, library, gpa, io, stock_names, choices);
}

/// Draws the panel's title, `title`, with its close button.
fn drawPanelTitle(state: *State, gpa: std.mem.Allocator, title: []const u8) void {
    const close_size = c.ImGui_GetFrameHeight();
    c.ImGui_AlignTextToFramePadding();
    gui.title(title, fonts.title_size);
    c.ImGui_SameLineEx(c.ImGui_GetContentRegionAvail().x + c.ImGui_GetCursorPosX() - close_size - c.ImGui_GetStyle().*.ItemSpacing.x, 0);
    const corner = c.ImGui_GetCursorScreenPos();
    if (gui.buttonOf(.quiet, "##close", gui.vec2(close_size / gui.scale, close_size / gui.scale))) state.closePanel(gpa);
    const centre = gui.vec2(corner.x + close_size / 2, corner.y + close_size / 2);
    gui.cross(c.ImGui_GetWindowDrawList(), centre, gui.px(close_arm), gui.px(close_thickness), theme.colors.text_secondary);
}

/// Draws the flat field row, for a camera roll: a button that picks the shot, which is optional.
fn drawFlatField(state: *State, gpa: std.mem.Allocator, io: std.Io) void {
    const form = &state.form;
    const chosen = state.flat_dialog.take(gpa, io);
    defer Dialog.free(gpa, chosen);
    if (chosen.len > 0) {
        const path = chosen[chosen.len - 1];
        gui.setText(&form.flat, path) catch std.log.err("the flat field's path is too long: {s}", .{path});
    }
    gui.rowLabel(i18n.t.rolls.flat_field);
    const flat = std.mem.sliceTo(&form.flat, 0);
    const width = c.ImGui_GetContentRegionAvail().x;
    const label = if (flat.len == 0) i18n.t.rolls.choose_shot else gui.elideStart(std.fs.path.basename(flat), width - c.ImGui_GetStyle().*.FramePadding.x * 2);
    c.ImGui_PushID("flat field");
    if (gui.buttonOf(.normal, label, gui.vec2(width / gui.scale, 0))) state.flat_dialog.show(gpa, io);
    c.ImGui_PopID();
    c.ImGui_SetCursorPosX(c.ImGui_GetCursorPosX() + gui.px(gui.label_column + gui.label_gap));
    gui.paragraph(theme.colors.text_tertiary, i18n.t.rolls.optional);
}

/// Makes the roll the form describes, with `stock_names` and `choices` as the form listed them.
/// Returns it once it's in the library, or null if it can't be made; the form then says why.
fn createRoll(state: *State, library: *Library, gpa: std.mem.Allocator, io: std.Io, stock_names: []const []const u8, choices: []const formats.Standard) ?Created {
    const form = &state.form;
    const name = std.mem.sliceTo(&form.name, 0);
    const stock_count = stock_names.len - 1;
    var made = roll.Roll.create(gpa, io, library.path, .{
        .name = name,
        .kind = form.kind,
        .stock = if (form.stock < stock_count) stock_names[form.stock] else null,
        .format = choices[form.format],
        .input = form.input,
        .camera = optional(&form.camera),
        .lens = optional(&form.lens),
        .shot = optional(&form.shot),
        .copyright = optional(&form.copyright),
        .notes = optional(&form.notes),
    }) catch |err| {
        std.log.err("can't make the roll: {t}", .{err});
        form.problem = switch (err) {
            error.RollExists => i18n.t.rolls.name_used,
            error.BadRollName => i18n.t.rolls.invalid_name,
            else => i18n.t.rolls.not_created,
        };
        return null;
    };
    const flat = std.mem.sliceTo(&form.flat, 0);
    var flat_failed = false;
    if (form.input == .camera_raw and flat.len > 0) setFlatField(gpa, io, &made, flat) catch |err| {
        std.log.err("can't use {s} as the flat field: {t}", .{ flat, err });
        flat_failed = true;
    };
    const path = gpa.dupe(u8, made.path) catch return null;
    defer gpa.free(path);
    made.close();
    // The roll is made either way, so the form is done: leaving it open would only say the name
    // is taken next time.
    state.closePanel(gpa);
    state.form = .{};
    // If the library can't be read now, the roll shows up when it's next read.
    library.reload(gpa, io) catch |err| {
        std.log.err("can't read the library again: {t}", .{err});
        return null;
    };
    return .{ .roll = library.find(path) orelse return null, .flat_failed = flat_failed };
}

/// Starts the copyright as the newest roll's, or before any roll has one, as the account's full
/// name. It's usually the same on every roll.
fn fillCopyright(form: *Form, library: *const Library) void {
    var name_buffer: [gui.text_capacity]u8 = undefined;
    const used = library.suggestions(.copyright);
    const copyright = if (used.len > 0) used[0] else account.fullName(&name_buffer) orelse return;
    gui.setText(&form.copyright, copyright) catch {};
}

/// Draws the details panel for the roll in folder `path`: its details, each saved when you leave
/// its box. It closes if the roll has gone.
fn drawDetails(state: *State, library: *Library, gpa: std.mem.Allocator, io: std.Io, path: []const u8) void {
    const index = library.find(path) orelse return state.closePanel(gpa);
    const r = &library.rolls.items[index];
    drawPanelTitle(state, gpa, r.info.name);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gui.px(form_spacing), gui.px(form_spacing)));
    defer c.ImGui_PopStyleVar();
    for (std.enums.values(roll.Detail)) |which| {
        gui.rowLabel(roll_details.label(which));
        state.details.draw(which, r, library, io, i18n.t.common.not_set, 0);
    }
}

/// Sets the shot in the file at `path` as the flat field of roll `r`.
fn setFlatField(gpa: std.mem.Allocator, io: std.Io, r: *roll.Roll, path: []const u8) !void {
    var shot = try minilab.input.read(gpa, io, path);
    defer shot.deinit(gpa);
    try r.setFlatField(gpa, io, shot.scan);
}

fn optional(buffer: anytype) ?[]const u8 {
    const text = std.mem.sliceTo(buffer, 0);
    return if (text.len == 0) null else text;
}
