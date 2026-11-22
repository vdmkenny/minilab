//! Editable metadata fields and a shared manager for their saved suggestions.
const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const details = minilab.saved_details;

const field_gap = 4;
const popup_width = 440;
const popup_height = 280;
const popup_padding = 16;
const list_gap = 8;

pub const State = struct {
    requested: bool = false,
    kind: details.Kind = .camera,
    filter: [gui.text_capacity:0]u8 = @splat(0),
    value: [details.value_capacity:0]u8 = @splat(0),
    problem: ?anyerror = null,

    pub fn manage(state: *State, kind: details.Kind) void {
        state.kind = kind;
        state.requested = true;
        state.problem = null;
        state.filter = @splat(0);
    }
};

pub const Edit = struct { changed: bool, committed: bool, active: bool };

/// Type freely or choose a previous value. Capture text-item state before drawing
/// the arrow, so existing roll editors save typed values at the right time.
pub fn field(state: *State, settings: *const details.Settings, kind: details.Kind, id: [:0]const u8, buffer: anytype, hint: [:0]const u8, width: f32) Edit {
    c.ImGui_PushID(id.ptr);
    defer c.ImGui_PopID();
    const room = if (width == 0) c.ImGui_GetContentRegionAvail().x else gui.px(width);
    const arrow = c.ImGui_GetFrameHeight();
    const changed = gui.textField("value", buffer, hint, @max(1, room - arrow - gui.px(field_gap)) / gui.scale);
    const committed = c.ImGui_IsItemDeactivatedAfterEdit();
    const active = c.ImGui_IsItemActive();
    var edit: Edit = .{ .changed = changed, .committed = committed, .active = active };
    c.ImGui_SameLineEx(0, gui.px(field_gap));
    c.ImGui_SetNextItemWidth(arrow);
    c.ImGui_SetNextWindowSizeConstraints(gui.vec2(@max(room, gui.px(220)), 0), gui.vec2(gui.px(600), gui.px(380)), null, null);
    if (c.ImGui_BeginCombo("##saved", "", c.ImGuiComboFlags_NoPreview | c.ImGuiComboFlags_HeightLarge)) {
        defer c.ImGui_EndCombo();
        if (c.ImGui_IsWindowAppearing()) {
            state.filter = @splat(0);
            c.ImGui_SetKeyboardFocusHere();
        }
        _ = gui.textField("filter", &state.filter, "Search saved entries", 0);
        const query = std.mem.trim(u8, std.mem.sliceTo(&state.filter, 0), " \t");
        var count: usize = 0;
        for (settings.entries, 0..) |entry, i| {
            if (entry.kind != kind or entry.removed) continue;
            if (std.ascii.findIgnoreCase(entry.value, query) == null) continue;
            count += 1;
            c.ImGui_PushIDInt(@intCast(i));
            defer c.ImGui_PopID();
            const fits = entry.value.len <= buffer.len;
            c.ImGui_BeginDisabled(!fits);
            const selected = std.mem.eql(u8, std.mem.sliceTo(buffer, 0), entry.value);
            if (c.ImGui_SelectableEx(gui.print("{s}", .{entry.value}).ptr, selected, 0, gui.vec2(0, 0))) {
                gui.setText(buffer, entry.value) catch unreachable;
                edit.changed = true;
                edit.committed = true;
            }
            c.ImGui_EndDisabled();
        }
        if (count == 0) gui.textColored(theme.text_tertiary, "No saved entries");
        c.ImGui_Separator();
        if (c.ImGui_SelectableEx("Manage saved entries...", false, 0, gui.vec2(0, 0))) state.manage(kind);
    }
    return edit;
}

/// Draw once outside a field's ID scope. Removing a suggestion never edits a roll.
pub fn manager(state: *State, settings: *details.Settings, io: std.Io) void {
    if (state.requested) {
        _ = c.ImGui_OpenPopup("Saved roll details", 0);
        state.requested = false;
    }
    c.ImGui_SetNextWindowSizeConstraints(gui.vec2(gui.px(popup_width), 0), gui.vec2(gui.px(600), gui.px(700)), null, null);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(popup_padding), gui.px(popup_padding)));
    defer c.ImGui_PopStyleVar();
    var open = true;
    if (!c.ImGui_BeginPopupModal("Saved roll details", &open, c.ImGuiWindowFlags_AlwaysAutoResize)) return;
    defer c.ImGui_EndPopup();
    if (gui.comboOf(details.Kind, "kind", std.enums.values(details.Kind), state.kind, details.Kind.label, 0)) |kind| {
        state.kind = kind;
        state.value = @splat(0);
        state.filter = @splat(0);
        state.problem = null;
    }
    gui.paragraph(theme.text_tertiary, "Remove entries from suggestions. Existing roll metadata is kept.");
    if (!settings.readable) gui.paragraph(theme.text_secondary, "Saved entries could not be read. The file has been kept unchanged.");
    c.ImGui_Dummy(gui.vec2(0, gui.px(list_gap)));
    _ = gui.textField("find entries", &state.filter, "Find saved entries", 0);
    const query = std.mem.trim(u8, std.mem.sliceTo(&state.filter, 0), " \t");
    var shown: usize = 0;
    var remove: ?[]const u8 = null;
    _ = c.ImGui_BeginChild("entries", gui.vec2(0, gui.px(popup_height)), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_None);
    for (settings.entries, 0..) |entry, i| {
        if (entry.kind != state.kind or entry.removed) continue;
        if (std.ascii.findIgnoreCase(entry.value, query) == null) continue;
        shown += 1;
        c.ImGui_PushIDInt(@intCast(i));
        defer c.ImGui_PopID();
        const left = c.ImGui_GetCursorPosX();
        const room = c.ImGui_GetContentRegionAvail().x;
        const remove_width = gui.fittedWidth("Remove", list_gap);
        c.ImGui_AlignTextToFramePadding();
        gui.text(gui.elideEnd(entry.value, @max(1, room - remove_width - gui.px(list_gap))));
        gui.tooltip(gui.print("{s}", .{entry.value}));
        c.ImGui_SameLineEx(left + room - remove_width, 0);
        c.ImGui_BeginDisabled(!settings.readable);
        if (gui.buttonOf(.quiet, "Remove", gui.vec2(remove_width / gui.scale, 0))) remove = entry.value;
        c.ImGui_EndDisabled();
    }
    if (shown == 0) gui.textColored(theme.text_tertiary, if (query.len == 0) "No saved entries" else "No matching entries");
    c.ImGui_EndChild();
    if (remove) |value| {
        if (settings.forget(io, state.kind, value)) |_| {
            state.problem = null;
        } else |err| state.problem = err;
    }
    c.ImGui_Dummy(gui.vec2(0, gui.px(list_gap)));
    c.ImGui_BeginDisabled(!settings.readable);
    _ = gui.textField("new value", &state.value, "New entry", 0);
    c.ImGui_BeginDisabled(std.mem.trim(u8, std.mem.sliceTo(&state.value, 0), " \t\r\n").len == 0);
    if (gui.buttonOf(.normal, "Save entry", gui.vec2(0, 0))) {
        if (settings.remember(io, state.kind, std.mem.sliceTo(&state.value, 0))) |_| {
            state.value = @splat(0);
            state.filter = @splat(0);
            state.problem = null;
        } else |err| state.problem = err;
    }
    c.ImGui_EndDisabled();
    c.ImGui_EndDisabled();
    c.ImGui_SameLineEx(0, gui.px(list_gap));
    if (gui.buttonOf(.normal, "Close", gui.vec2(0, 0))) c.ImGui_CloseCurrentPopup();
    if (state.problem != null) gui.paragraph(theme.text_secondary, "Saved entries could not be updated. Check the library's write access.");
}
