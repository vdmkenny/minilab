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

const roll = minilab.roll;
const develop = minilab.develop;
const formats = minilab.formats;

/// Sizes in the design's pixels.
const page_padding_x = 20;
const page_padding_y = 16;
const card_width = 210;
const card_padding_x = 14;
const card_padding_y = 12;
const thumb_height = 64;
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
/// The longest path the form can hold.
const path_field = 1024;

/// The file types the flat field's button lets you pick.
const flat_files = [_]c.SDL_DialogFileFilter{
    .{ .name = "Camera RAW and TIFF", .pattern = minilab.input.extensions },
};

pub const State = struct {
    search: [gui.text_capacity:0]u8 = @splat(0),
    /// 0 for all film sizes, otherwise the size's index in `film_sizes` plus one.
    size_filter: usize = 0,
    show_form: bool = false,
    form: Form = .{},
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

/// The fields for the new roll.
const Form = struct {
    name: [gui.text_capacity:0]u8 = @splat(0),
    kind: usize = 0,
    stock: usize = 0,
    size: usize = 0,
    format: usize = 0,
    camera: [gui.text_capacity:0]u8 = @splat(0),
    lens: [gui.text_capacity:0]u8 = @splat(0),
    copyright: [gui.text_capacity:0]u8 = @splat(0),
    notes: [gui.text_capacity * 4:0]u8 = @splat(0),
    input: usize = 0,
    /// The flat field for a camera roll: a file with a shot of the light source and no film.
    flat: [path_field:0]u8 = @splat(0),
    /// Whether the default name has been filled in since the form was last opened.
    named: bool = false,
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

/// The film sizes a roll can have, in the order the form lists them.
const film_sizes = [_]formats.FilmSize{ .@"135", .@"120", .@"127", .@"110", .@"126", .aps, .minox, .sheet };
const film_size_names = [_][]const u8{ "135 (35mm)", "120 / 220", "127", "110", "126", "APS", "Minox", "Sheet film" };
const filter_names = [_][]const u8{ "All film sizes", "135", "120 / 220", "127", "110", "126", "APS", "Minox", "Sheet film" };
const inputs = [_]roll.Input{ .scanner, .camera_raw, .tiff_files };
const input_names = [_][]const u8{ "Scanner", "Camera RAW", "TIFF files" };

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
    const form = if (state.show_form) gui.px(form_width) else 0;

    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.page);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(page_padding_x), gui.px(page_padding_y)));
    _ = c.ImGui_BeginChild("sheet", gui.vec2(available.x - form, available.y), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_None);
    c.ImGui_PopStyleVar();
    drawTitleRow(state, library);
    c.ImGui_Dummy(gui.vec2(0, gui.px(14) - c.ImGui_GetStyle().*.ItemSpacing.y * 2));

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
        gui.paragraph(theme.text_tertiary, "No rolls yet");
    } else if (shown == 0) {
        gui.paragraph(theme.text_tertiary, "No matching rolls");
    }
    if (drawDeleteConfirmation(state, library, gpa)) |index| action = .{ .trash = index };
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    if (state.show_form) {
        c.ImGui_SetCursorScreenPos(gui.vec2(top.x + available.x - form, top.y));
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(16), gui.px(16)));
        _ = c.ImGui_BeginChild("new roll", gui.vec2(form, available.y), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_None);
        c.ImGui_PopStyleVar();
        const window = c.ImGui_GetWindowPos();
        c.ImDrawList_AddLine(c.ImGui_GetWindowDrawList(), window, gui.vec2(window.x, window.y + available.y), theme.imU32(theme.divider));
        if (drawForm(state, library, gpa, io)) |created| action = .{ .created = created };
        c.ImGui_EndChild();
    }
    return action;
}

fn matches(state: *const State, info: roll.Info) bool {
    if (state.size_filter > 0 and info.format.format().size != film_sizes[state.size_filter - 1]) return false;
    const query = std.mem.sliceTo(&state.search, 0);
    if (query.len == 0) return true;
    for ([_]?[]const u8{ info.name, info.stock, info.camera }) |field| {
        if (field) |f| if (gui.containsIgnoreCase(f, query)) return true;
    }
    return false;
}

/// Draws the title row: "Rolls" and where the library is, then search, the film-size filter and
/// New roll on the right.
fn drawTitleRow(state: *State, library: *Library) void {
    const row_top = c.ImGui_GetCursorPosY();
    const height = c.ImGui_GetFrameHeight();
    const right = c.ImGui_GetContentRegionAvail().x + c.ImGui_GetCursorPosX();
    const new_label = "New roll";
    fonts.push(.semibold);
    const new_width = c.ImGui_CalcTextSize(new_label).x + gui.px(12 * 2 + 14 + 6);
    fonts.pop();
    const filter_width = gui.px(130);
    const controls = gui.px(search_width) + filter_width + new_width + gui.px(10 * 2);

    fonts.pushSized(.semibold, 18);
    const title_height = c.ImGui_GetFontSize();
    c.ImGui_SetCursorPosY(row_top + (height - title_height) / 2);
    gui.text("Rolls");
    fonts.pop();
    c.ImGui_SameLineEx(0, gui.px(10));
    c.ImGui_SetCursorPosY(row_top);
    c.ImGui_AlignTextToFramePadding();
    const count = gui.print(" · {d} {s}", .{ library.rolls.items.len, if (library.rolls.items.len == 1) "roll" else "rolls" });
    const room = right - c.ImGui_GetCursorPosX() - controls - gui.px(20) - c.ImGui_CalcTextSize(count).x;
    gui.textColored(theme.text_tertiary, gui.print("{s}{s}", .{ gui.elideStart(library.label, room), count }));

    c.ImGui_SameLineEx(right - controls, 0);
    if (state.focus_search) c.ImGui_SetKeyboardFocusHere();
    state.focus_search = false;
    _ = gui.textField("search", &state.search, "Search name, stock, camera", search_width);
    shortcuts.tooltip("Search rolls", .find);
    c.ImGui_SameLineEx(0, gui.px(10));
    if (gui.combo("film size", &filter_names, state.size_filter, filter_width / gui.scale)) |picked| state.size_filter = picked;
    c.ImGui_SameLineEx(0, gui.px(10));
    const corner = c.ImGui_GetCursorScreenPos();
    if (gui.buttonOf(.primary, "##new roll", gui.vec2(new_width / gui.scale, height / gui.scale))) {
        state.show_form = !state.show_form;
        state.form = .{};
    }
    shortcuts.tooltip("New roll", .new_roll);
    // The plus sign, then the label, laid out as in the design: 12 pixels in, a 14-pixel icon,
    // then a 6-pixel gap.
    const list = c.ImGui_GetWindowDrawList();
    gui.plus(list, gui.vec2(corner.x + gui.px(12 + 7), corner.y + height / 2), gui.px(5), gui.px(1.8), theme.on_accent);
    fonts.push(.semibold);
    c.ImDrawList_AddText(list, gui.vec2(corner.x + gui.px(12 + 14 + 6), corner.y + (height - c.ImGui_GetTextLineHeight()) / 2), theme.imU32(theme.on_accent), new_label);
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
    if (!c.ImGui_IsPopupOpen("delete roll", 0)) _ = c.ImGui_OpenPopup("delete roll", 0);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(20), gui.px(16)));
    defer c.ImGui_PopStyleVar();
    if (!c.ImGui_BeginPopupModal("delete roll", null, c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoTitleBar)) {
        state.stopDeleting(gpa);
        return null;
    }
    defer c.ImGui_EndPopup();
    gui.title(gui.print("Delete {s}?", .{r.info.name}), 15);
    const frames = r.frames.items.len;
    gui.textColored(theme.text_tertiary, gui.print("{d} {s}", .{ frames, if (frames == 1) "frame" else "frames" }));
    c.ImGui_Dummy(gui.vec2(0, gui.px(8)));
    var confirmed: ?usize = null;
    if (gui.buttonOf(.primary, "Move to Trash", gui.vec2(0, 32))) confirmed = index;
    c.ImGui_SameLineEx(0, gui.px(8));
    const cancelled = gui.buttonOf(.normal, "Cancel", gui.vec2(0, 32)) or c.ImGui_IsKeyPressed(c.ImGuiKey_Escape);
    if (confirmed != null or cancelled) {
        state.stopDeleting(gpa);
        c.ImGui_CloseCurrentPopup();
    }
    return confirmed;
}

/// The Delete button on a roll's card: a small bin, shown while the card is hovered.
const delete_size = 22;

/// Draws one roll: its card, then its filmstrip.
fn drawRow(state: *State, library: *Library, gpa: std.mem.Allocator, r: *roll.Roll, index: usize, drop: ?gui.Vec2) ?Action {
    var action: ?Action = null;
    const origin = c.ImGui_GetCursorScreenPos();
    const list = c.ImGui_GetWindowDrawList();
    const line = gui.lineHeight();
    const card_height = gui.px(card_padding_y * 2 + 21 + 17 + 3 * 3 + 6 + 3 + 3) + line * 3;
    const format = r.info.format.format();

    // The card. Its Delete button sits on top of it.
    c.ImGui_SetNextItemAllowOverlap();
    if (c.ImGui_InvisibleButton("card", gui.vec2(gui.px(card_width), card_height), 0)) action = .{ .open = .{ .roll = index } };
    const hovered = c.ImGui_IsItemHovered(0);
    c.ImDrawList_AddRectFilledEx(list, origin, gui.vec2(origin.x + gui.px(card_width), origin.y + card_height), theme.imU32(if (hovered) theme.control else theme.panel), gui.px(6), 0);
    var at = gui.vec2(origin.x + gui.px(card_padding_x), origin.y + gui.px(card_padding_y));
    const inner = gui.px(card_width - 2 * card_padding_x);
    fonts.pushSized(.semibold, 15);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.text), gui.elideEnd(r.info.name, inner));
    fonts.pop();
    at.y += gui.px(21 + 3);
    fonts.pushSized(.mono, 12);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.accent), gui.print("{s}", .{r.info.shot orelse r.info.created orelse ""}));
    fonts.pop();
    at.y += gui.px(17 + 3);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.text_secondary), gui.elideEnd(r.info.stock orelse labels.filmKind(r.info.kind), inner));
    at.y += line + gui.px(3);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.text_tertiary), gui.elideEnd(labels.filmAndFormat(r.info.format), inner));

    const total = r.frames.items.len;
    const developed = r.developedCount();
    const bar_y = origin.y + card_height - gui.px(card_padding_y + 3);
    c.ImDrawList_AddText(list, gui.vec2(at.x, bar_y - gui.px(3) - line + (line - c.ImGui_GetTextLineHeight()) / 2), theme.imU32(theme.text_secondary), gui.print("{d} of {d} developed", .{ developed, total }));
    const bar_width = gui.px(card_width - 2 * card_padding_x);
    const share = if (total == 0) 0 else @as(f32, @floatFromInt(developed)) / @as(f32, @floatFromInt(total));
    gui.progressBar(list, gui.vec2(at.x, bar_y), gui.vec2(at.x + bar_width, bar_y + gui.px(3)), share);

    // Delete, in the card's top right corner while the mouse is over the card.
    const mouse = c.ImGui_GetMousePos();
    const over_card = mouse.x >= origin.x and mouse.x < origin.x + gui.px(card_width) and mouse.y >= origin.y and mouse.y < origin.y + card_height;
    if (over_card or state.isDeleting(r.path)) {
        const size = gui.px(delete_size);
        const corner = gui.vec2(origin.x + gui.px(card_width) - size - gui.px(6), origin.y + gui.px(6));
        c.ImGui_SetCursorScreenPos(corner);
        if (c.ImGui_InvisibleButton("delete", gui.vec2(size, size), 0)) state.startDeleting(gpa, r.path);
        const on_button = c.ImGui_IsItemHovered(0);
        if (on_button) {
            c.ImGui_SetTooltip("Delete roll");
            c.ImDrawList_AddRectFilledEx(list, corner, gui.vec2(corner.x + size, corner.y + size), theme.imU32(theme.control_hover), gui.px(4), 0);
        }
        drawBin(list, gui.vec2(corner.x + size / 2, corner.y + size / 2), gui.px(7), if (on_button) theme.red else theme.text_tertiary);
    }

    // The filmstrip: the film drawn to its own proportions, centred in the row's height, with the
    // frame numbers under it.
    const height = gui.px(thumb_height);
    const per_mm = height / format.height_mm;
    const film_mm = format.size.filmWidthMm();
    const sheets = film_mm == null;
    const band = @round((film_mm orelse format.height_mm + 2 * sheet_border_mm) * per_mm);
    const gap = @max(format.size.typicalGapMm(), min_frame_gap_mm) * per_mm;
    const leader = (if (sheets) sheet_border_mm else leader_mm) * per_mm;
    const number_height = gui.px(15);
    const strip_x = origin.x + gui.px(card_width + 12);
    const strip_top = @round(origin.y + (card_height - band - gui.px(3) - number_height) / 2);
    const thumbs_top = strip_top + @round((band - height) / 2);
    const width = @round(height * format.ratio());
    const right = c.ImGui_GetWindowPos().x + c.ImGui_GetWindowWidth() - gui.px(page_padding_x);
    const more_width = gui.px(14 * 2) + c.ImGui_CalcTextSize("+00 more").x;
    // Each frame takes its width and the gap after it; sheets each have their own border.
    const step = width + if (sheets) 2 * leader + gap else gap;
    const room = right - strip_x + gap - if (sheets) 0 else 2 * leader;
    var fit = @max(1, @as(usize, @intFromFloat(@floor(room / step))));
    if (fit < total) fit = @max(1, @as(usize, @intFromFloat(@floor((room - more_width - gui.px(thumb_gap)) / step))));
    const shown = @min(total, fit);
    const strip_end = strip_x + @as(f32, @floatFromInt(shown)) * step - gap + if (sheets) 0 else 2 * leader;
    const film_ink = theme.imU32(theme.film);
    if (shown > 0 and !sheets) {
        c.ImDrawList_AddRectFilledEx(list, gui.vec2(strip_x, strip_top), gui.vec2(strip_end, strip_top + band), film_ink, gui.px(2), 0);
        // Punched in the page's colour, so they look cut out.
        const strip: holes.Strip = .{ .axis = .x, .start = strip_x, .end = strip_end, .near = strip_top, .far = strip_top + band, .along_per_mm = per_mm, .across_per_mm = per_mm };
        switch (format.size.holes()) {
            .none => {},
            .rows => |p| holes.rows(list, strip, p, strip_x + (p.pitch_mm - p.length_mm) * per_mm / 2, theme.page),
            .per_frame => |count| for (0..shown) |i| holes.atFrame(list, strip, count, strip_x + leader + @as(f32, @floatFromInt(i)) * step, theme.page),
        }
    }

    var x = strip_x + if (sheets) 0 else leader;
    for (0..shown) |frame| {
        const picture_x = x + if (sheets) leader else 0;
        if (sheets) c.ImDrawList_AddRectFilledEx(list, gui.vec2(x, strip_top), gui.vec2(x + width + 2 * leader, strip_top + band), film_ink, gui.px(2), 0);
        const corner = gui.vec2(picture_x, thumbs_top);
        const far = gui.vec2(picture_x + width, thumbs_top + height);
        const numbers_y = strip_top + band + gui.px(3);
        c.ImGui_SetCursorScreenPos(corner);
        c.ImGui_PushIDInt(@intCast(frame));
        if (c.ImGui_InvisibleButton("frame", gui.vec2(width, numbers_y + number_height - thumbs_top), 0)) action = .{ .open = .{ .roll = index, .frame = frame } };
        c.ImGui_PopID();
        if (library.thumbnail(gpa, .{ .roll = index, .frame = frame })) |t| {
            gui.imageCover(list, t.ref(), t.width, t.height, corner, far, gui.px(1));
        } else {
            c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.control), gui.px(1), 0);
        }
        fonts.pushSized(.mono, 11);
        const number = gui.print("{d:0>2}", .{frame + 1});
        const number_width = c.ImGui_CalcTextSize(number).x;
        c.ImDrawList_AddText(list, gui.vec2(picture_x + (width - number_width) / 2, numbers_y), theme.imU32(theme.text_tertiary), number);
        fonts.pop();
        x += step;
    }
    if (total > shown) {
        const corner = gui.vec2(strip_end + gui.px(thumb_gap), thumbs_top);
        c.ImGui_SetCursorScreenPos(corner);
        if (c.ImGui_InvisibleButton("more", gui.vec2(more_width, height), 0)) action = .{ .open = .{ .roll = index, .frame = shown } };
        gui.dashedRect(list, corner, gui.vec2(corner.x + more_width, corner.y + height), theme.imU32(theme.border), 1, gui.px(4), gui.px(3));
        const more = gui.print("+{d} more", .{total - shown});
        const size = c.ImGui_CalcTextSize(more);
        c.ImDrawList_AddText(list, gui.vec2(corner.x + (more_width - size.x) / 2, corner.y + (height - size.y) / 2), theme.imU32(theme.text_secondary), more);
    }
    if (total == 0) {
        c.ImDrawList_AddText(list, gui.vec2(strip_x, thumbs_top + (height - c.ImGui_GetTextLineHeight()) / 2), theme.imU32(theme.text_tertiary), "No frames yet");
    }

    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, origin.y + card_height));
    c.ImGui_Dummy(gui.vec2(0, 0));
    if (action == null) {
        if (drop) |p| {
            if (p.y >= origin.y and p.y < origin.y + card_height and p.x >= origin.x and p.x < right) action = .{ .dropped_on = index };
        }
    }
    return action;
}

/// Draws a waste bin about `half` × 2 high, centred on `centre`: a lid with a handle, and a body
/// with two lines down it.
fn drawBin(list: *c.ImDrawList, centre: gui.Vec2, half: f32, colour: theme.Color) void {
    const ink = theme.imU32(colour);
    const thickness = gui.px(1.4);
    const top = centre.y - half;
    const lid = top + half * 0.35;
    c.ImDrawList_AddLineEx(list, gui.vec2(centre.x - half, lid), gui.vec2(centre.x + half, lid), ink, thickness);
    c.ImDrawList_AddRectEx(list, gui.vec2(centre.x - half * 0.3, top), gui.vec2(centre.x + half * 0.3, lid), ink, gui.px(1), thickness, 0);
    const body_left = centre.x - half * 0.75;
    const body_right = centre.x + half * 0.75;
    const bottom = centre.y + half;
    c.ImDrawList_AddRectEx(list, gui.vec2(body_left, lid), gui.vec2(body_right, bottom), ink, gui.px(1.5), thickness, 0);
    for ([_]f32{ -0.28, 0.28 }) |at| {
        const x = centre.x + half * at;
        c.ImDrawList_AddLineEx(list, gui.vec2(x, lid + half * 0.35), gui.vec2(x, bottom - half * 0.3), ink, thickness);
    }
}

/// Draws the new-roll panel. Returns the new roll's index once it's made.
fn drawForm(state: *State, library: *Library, gpa: std.mem.Allocator, io: std.Io) ?Created {
    const form = &state.form;
    if (!form.named) {
        _ = std.fmt.bufPrintSentinel(&form.name, "Roll {d:0>3}", .{library.rolls.items.len + 1}, 0) catch {};
        form.named = true;
    }

    const close_size = c.ImGui_GetFrameHeight();
    c.ImGui_AlignTextToFramePadding();
    gui.title("New roll", 15);
    c.ImGui_SameLineEx(c.ImGui_GetContentRegionAvail().x + c.ImGui_GetCursorPosX() - close_size - c.ImGui_GetStyle().*.ItemSpacing.x, 0);
    const corner = c.ImGui_GetCursorScreenPos();
    if (gui.buttonOf(.quiet, "##close", gui.vec2(close_size / gui.scale, close_size / gui.scale))) state.show_form = false;
    const centre = gui.vec2(corner.x + close_size / 2, corner.y + close_size / 2);
    const list = c.ImGui_GetWindowDrawList();
    gui.cross(list, centre, gui.px(4), gui.px(1.6), theme.text_secondary);

    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gui.px(10), gui.px(10)));
    defer c.ImGui_PopStyleVar();
    gui.rowLabel("Name");
    if (gui.textField("name", &form.name, "", 0)) form.problem = null;
    if (form.problem) |problem| {
        gui.rowLabel("");
        gui.paragraph(theme.text_tertiary, problem);
    }
    gui.rowLabel("Film type");
    if (gui.combo("film type", &labels.film_kind_labels, form.kind, 0)) |picked| {
        form.kind = picked;
        form.stock = 0;
    }
    gui.rowLabel("Stock");
    var stock_buffer: [labels.stock_choices.len + 1][]const u8 = undefined;
    const stock_names = labels.stockNames(labels.film_kinds[form.kind], "Other", &stock_buffer);
    if (form.stock >= stock_names.len) form.stock = 0;
    if (gui.searchCombo("stock", stock_names, form.stock, 0, "Search stocks")) |picked| form.stock = picked;
    gui.rowLabel("Film size");
    if (gui.combo("film size", &film_size_names, form.size, 0)) |picked| {
        form.size = picked;
        form.format = 0;
    }
    var buffer: [std.enums.values(formats.Standard).len]formats.Standard = undefined;
    const choices = formatsOf(film_sizes[form.size], &buffer);
    var names: [buffer.len][]const u8 = undefined;
    for (choices, 0..) |id, i| names[i] = labels.format(id);
    gui.rowLabel("Format");
    if (gui.combo("format", names[0..choices.len], form.format, 0)) |picked| form.format = picked;
    gui.rowLabel("Camera");
    _ = gui.textField("camera", &form.camera, "[Camera]", 0);
    gui.rowLabel("Lens");
    _ = gui.textField("lens", &form.lens, "[Lens]", 0);
    gui.rowLabel("Copyright");
    _ = gui.textField("copyright", &form.copyright, "[Your name]", 0);
    const notes_x = c.ImGui_GetCursorPosX();
    gui.textColored(theme.text_secondary, "Notes");
    c.ImGui_SameLineEx(notes_x + gui.px(gui.label_column + gui.label_gap), 0);
    _ = c.ImGui_InputTextMultilineEx("##notes", &form.notes, form.notes.len + 1, gui.vec2(-std.math.floatMin(f32), gui.lineHeight() * 3 + gui.px(12)), 0, null, null);
    gui.rowLabel("Input");
    if (gui.combo("input", &input_names, form.input, 0)) |picked| form.input = picked;
    const chosen = state.flat_dialog.take(gpa, io);
    defer Dialog.free(gpa, chosen);
    if (chosen.len > 0) {
        const path = chosen[chosen.len - 1];
        gui.setText(&form.flat, path) catch std.log.err("the flat field's path is too long: {s}", .{path});
    }
    const camera = inputs[form.input] == .camera_raw;
    if (camera) {
        gui.rowLabel("Flat field");
        const flat = std.mem.sliceTo(&form.flat, 0);
        const width = c.ImGui_GetContentRegionAvail().x;
        const label = if (flat.len == 0) "Choose a shot…" else gui.elideStart(std.fs.path.basename(flat), width - c.ImGui_GetStyle().*.FramePadding.x * 2);
        c.ImGui_PushID("flat field");
        if (gui.buttonOf(.normal, label, gui.vec2(width / gui.scale, 0))) state.flat_dialog.show(gpa, io);
        c.ImGui_PopID();
        c.ImGui_SetCursorPosX(c.ImGui_GetCursorPosX() + gui.px(gui.label_column + gui.label_gap));
        gui.paragraph(theme.text_tertiary, "Optional");
    }

    // The button sits at the bottom of the panel.
    const button_height = 38;
    const bottom = c.ImGui_GetWindowHeight() - gui.px(16 + button_height);
    if (c.ImGui_GetCursorPosY() < bottom) c.ImGui_SetCursorPosY(bottom);
    const name = std.mem.sliceTo(&form.name, 0);
    c.ImGui_BeginDisabled(name.len == 0 or choices.len == 0);
    defer c.ImGui_EndDisabled();
    if (!gui.buttonOf(.primary, if (inputs[form.input] == .scanner) "Create roll and scan" else "Create roll", gui.vec2(c.ImGui_GetContentRegionAvail().x / gui.scale, button_height))) return null;

    const stock_count = stock_names.len - 1;
    var made = roll.Roll.create(gpa, io, library.path, .{
        .name = name,
        .kind = labels.film_kinds[form.kind],
        .stock = if (form.stock < stock_count) stock_names[form.stock] else null,
        .format = choices[form.format],
        .input = inputs[form.input],
        .camera = optional(&form.camera),
        .lens = optional(&form.lens),
        .copyright = optional(&form.copyright),
        .notes = optional(&form.notes),
    }) catch |err| {
        std.log.err("can't make the roll: {t}", .{err});
        form.problem = switch (err) {
            error.RollExists => "Name already used",
            error.BadRollName => "Invalid name",
            else => "Roll not created",
        };
        return null;
    };
    const flat = std.mem.sliceTo(&form.flat, 0);
    var flat_failed = false;
    if (camera and flat.len > 0) setFlatField(gpa, io, &made, flat) catch |err| {
        std.log.err("can't use {s} as the flat field: {t}", .{ flat, err });
        flat_failed = true;
    };
    const path = gpa.dupe(u8, made.path) catch return null;
    defer gpa.free(path);
    made.close();
    // The roll is made either way, so the form is done: leaving it open would only say the name
    // is taken next time.
    state.show_form = false;
    state.form = .{};
    // If the library can't be read now, the roll shows up when it's next read.
    library.reload(gpa, io) catch |err| {
        std.log.err("can't read the library again: {t}", .{err});
        return null;
    };
    return .{ .roll = library.find(path) orelse return null, .flat_failed = flat_failed };
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
