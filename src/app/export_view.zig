//! The Export workspace. You pick frames from the open roll, and on the right you choose how to
//! write them: format, colour space, size, file names, folder and metadata. The export runs on its
//! own thread, with its progress at the bottom of the page, so the window stays responsive. The
//! export itself is in `minilab.export`.

const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const context = @import("context.zig");
const shortcuts = @import("shortcuts.zig");
const labels = @import("labels.zig");
const Library = @import("library.zig").Library;
const Dialog = @import("../platform/file_dialog.zig").Dialog;

const exporting = minilab.@"export";
const icc = minilab.codecs.icc;
const roll = minilab.roll;

/// Sizes in the design's pixels.
const settings_width = 360;
const page_padding_x = 20;
const page_padding_y = 16;
const panel_padding = 16;
/// The space between blocks, on the page and in the panel.
const block_gap = 14;
const cell_min_width = 150;
const cell_gap = 10;
const cell_padding = 6;
const check_size = 16;
const pill_height = 30;
const pill_gap = 4;
const control_height = 32;
const label_width = 110;
const grid_gap = 10;
/// A Metadata row, tall enough for a text field, and the gap between rows.
const detail_row = 28;
const metadata_gap = 6;
/// The longest a detail or a field's value can be, in bytes, and a field's name. A detail holds
/// more than New roll's notes box, so notes typed there fit. A longer one, say from a roll.json
/// edited by hand, is shown cut short and can't be edited here (`showCut`).
const detail_capacity = 1024;
const field_name_capacity = 64;
const metadata_check = 13;
/// A Metadata row's columns: the check box, its name and the gaps between them.
const metadata_check_width = 22;
const metadata_check_inset = 4;
const metadata_name_width = 100;
const metadata_spacing = 6;
/// The space a detail's value has before it in its box.
const value_inset = 10;
/// The x that removes a field.
const remove_arm = 4;
const remove_thickness = 1.5;
const export_height = 40;
const section_padding = 12;
const section_rounding = 6;
/// The grid of frames: the least height it gets, and the gaps in the bar above it.
const grid_min_height = 40;
const toolbar_gap = 10;
/// A frame's card: the corner of its picture, the inset of its number and check box, and its
/// stars.
const picture_rounding = 2;
const card_inset = 2;
const rating_gap = 8;
const star_radius = 5;
const star_gap = 2;
/// The running export's progress bar, and the room the status lines leave for the button on
/// their right.
const progress_height = 4;
const progress_room = 80;
const summary_room = 120;
/// The line under a link.
const link_underline = 1;
/// Padding either side of the text in a choice, a drop-down and a text field.
const pill_padding = 10;
const combo_padding = 8;
const field_padding = 10;
/// The box for a custom long edge, the gap before its unit, and the space above a problem with
/// the file names.
const edge_field_width = 90;
const unit_gap = 8;
const problem_gap = 4;
/// The gap between a text field and the button beside it.
const field_gap = 6;
/// Line heights, in the design's pixels, for 13-pixel text and headings.
const line = fonts.ui_size * gui.line_spacing;
const small_line = gui.heading_size * gui.line_spacing;

const path_field = 1024;

/// The file choices, in the order the panel lists them.
const FileChoice = enum {
    tiff16,
    tiff8,
    jpeg,
    /// Shown, but the codecs can't write it yet.
    heic,

    fn label(choice: FileChoice) [:0]const u8 {
        return switch (choice) {
            .tiff16 => "TIFF 16-bit",
            .tiff8 => "TIFF 8-bit",
            .jpeg => "JPEG",
            .heic => "HEIC HDR",
        };
    }
};

fn spaceLabel(space: icc.Space) []const u8 {
    return switch (space) {
        .display_p3 => "Display P3",
        .srgb => "sRGB",
        .adobe_rgb => "Adobe RGB",
        .prophoto => "ProPhoto RGB",
        .rec2020_linear => "Rec. 2020 linear",
    };
}

/// The sizes Size offers.
const SizeChoice = enum {
    full,
    long_edge_4000,
    long_edge_2048,
    /// Takes its long edge from `State.custom_edge`.
    custom,

    fn label(choice: SizeChoice) []const u8 {
        return switch (choice) {
            .full => "Full resolution",
            .long_edge_4000 => "Long edge 4000 px",
            .long_edge_2048 => "Long edge 2048 px",
            .custom => "Custom long edge",
        };
    }
};
/// The range a custom long edge can take, in pixels.
const min_custom_edge = 64;
const max_custom_edge = 65535;
/// The star filter's choices: any rating, then at least 1 to 5 stars.
const star_filters = [_][]const u8{ "Any rating", "1+ stars", "2+ stars", "3+ stars", "4+ stars", "5 stars" };
const star_filter_width = 120;
const default_pattern = "{roll}_{frame:02}";

/// A field you can type in on Metadata: one of the roll's details, or the name or value of one of
/// its own fields.
const Editing = union(enum) {
    detail: roll.Detail,
    field_name: usize,
    field_value: usize,
};

/// The boxes for one of the roll's own fields.
const FieldBoxes = struct {
    name: [field_name_capacity:0]u8 = @splat(0),
    value: [detail_capacity:0]u8 = @splat(0),
    /// Whether the field fits its boxes. One that doesn't is shown cut short, can't be edited,
    /// and is saved from the roll as it is.
    fits: bool = true,
};

/// An export that's running on its own thread.
const Running = struct {
    batch: *exporting.Batch,
    future: std.Io.Future(void),
    /// What it's writing, in the words the summary will use.
    what: gui.Line(64) = .{},
};

/// What the last export did, for the bottom of the page.
const Summary = struct {
    line: gui.Line(256) = .{},
    files: gui.Line(512) = .{},
    /// The folder, for Show in folder.
    folder: gui.Line(path_field) = .{},
};

pub const State = struct {
    /// The roll the selection belongs to, by folder. The selection starts over for another roll.
    roll_path: ?[]u8 = null,
    selected: std.ArrayList(bool) = .empty,
    /// Each frame's rating when the selection last took it into account, to spot ratings changed
    /// in Develop since.
    seen: std.ArrayList(roll.Rating) = .empty,
    /// The star filter: the fewest stars a frame needs to be chosen, 0 for any.
    min_stars: usize = 0,
    /// The frame clicked last, which is where a shift-click's range starts.
    anchor: ?usize = null,
    file: FileChoice = .tiff16,
    quality: f32 = 92,
    space: icc.Space = .display_p3,
    size: SizeChoice = .full,
    /// The long edge for Custom, in pixels, as typed.
    custom_edge: [8:0]u8 = gui.initText(8, "3000"),
    pattern: [gui.text_capacity:0]u8 = gui.initText(gui.text_capacity, default_pattern),
    /// Where the files go: a path relative to the library's folder, or an absolute one.
    folder: [path_field:0]u8 = @splat(0),
    include: exporting.Include = .{},
    /// What's in each detail's field. It follows the roll, except while you're typing in it.
    details: std.EnumArray(roll.Detail, [detail_capacity:0]u8) = .initFill(@splat(0)),
    /// The boxes for the roll's own fields, filled from the roll.
    custom: std.ArrayList(FieldBoxes) = .empty,
    /// The field being typed in, if any.
    editing: ?Editing = null,
    /// Put the keyboard in the newest field's name, after Add field.
    focus_new_field: bool = false,
    dialog: Dialog = .{ .kind = .folder },
    running: ?Running = null,
    last: ?Summary = null,
    /// The Io the export runs on, kept for `deinit`, which doesn't get one passed in.
    io_for_deinit: ?std.Io = null,

    pub fn deinit(state: *State, gpa: std.mem.Allocator) void {
        if (state.running) |*running| {
            running.batch.cancel.store(true, .release);
            // Waits for the frame being exported to reach its next check.
            running.future.await(state.io_for_deinit orelse return);
            running.batch.destroy(gpa);
        }
        state.selected.deinit(gpa);
        state.seen.deinit(gpa);
        state.custom.deinit(gpa);
        state.dialog.deinit(gpa);
        if (state.roll_path) |p| gpa.free(p);
    }

    /// Whether everything on the page has loaded. A screenshot waits for this.
    pub fn settled(state: *const State) bool {
        return state.running == null;
    }

    fn options(state: *const State) exporting.Options {
        return .{
            .format = switch (state.file) {
                .jpeg => .jpeg,
                // HEIC can't be written yet, and Export is off while it's chosen.
                .tiff16, .tiff8, .heic => .tiff,
            },
            .depth = switch (state.file) {
                .tiff8, .jpeg => .eight,
                .tiff16, .heic => .sixteen,
            },
            .quality = @intFromFloat(std.math.clamp(@round(state.quality), 1, 100)),
            .space = state.space,
            .long_edge = switch (state.size) {
                .full => null,
                .long_edge_4000 => 4000,
                .long_edge_2048 => 2048,
                .custom => state.customEdge(),
            },
        };
    }

    /// The custom long edge typed in, kept within range. Null when there's no number, which
    /// exports at full resolution.
    fn customEdge(state: *const State) ?usize {
        const typed = std.mem.trim(u8, std.mem.sliceTo(&state.custom_edge, 0), " ");
        const edge = std.fmt.parseInt(usize, typed, 10) catch return null;
        return std.math.clamp(edge, min_custom_edge, max_custom_edge);
    }

    fn isEditing(state: *const State, which: Editing) bool {
        const editing = state.editing orelse return false;
        return std.meta.eql(editing, which);
    }

    /// Whether a frame with `rating` passes the star filter. Rejected frames never do.
    fn passes(state: *const State, rating: roll.Rating) bool {
        return !rating.rejected and rating.stars >= state.min_stars;
    }

    /// Chooses exactly the frames of `r` that pass the star filter.
    fn applyFilter(state: *State, r: *const roll.Roll) void {
        for (state.selected.items, r.frames.items) |*on, frame| on.* = state.passes(frame.rating);
        state.anchor = null;
    }

    fn selectedCount(state: *const State) usize {
        var count: usize = 0;
        for (state.selected.items) |on| count += @intFromBool(on);
        return count;
    }

    fn selectAll(state: *State, on: bool) void {
        @memset(state.selected.items, on);
        state.anchor = null;
    }

    /// Starts the selection over if `r` is a different roll, and keeps it in step with the roll's
    /// frames. A new frame, or one whose rating changed in Develop, is chosen if it passes the star
    /// filter, so rejected frames start out unchosen. Frames picked by hand otherwise stay as they
    /// are.
    fn follow(state: *State, gpa: std.mem.Allocator, library: *const Library, r: *const roll.Roll) void {
        const same = if (state.roll_path) |p| std.mem.eql(u8, p, r.path) else false;
        if (!same) {
            const copy = gpa.dupe(u8, r.path) catch return;
            if (state.roll_path) |p| gpa.free(p);
            state.roll_path = copy;
            state.selected.clearRetainingCapacity();
            state.seen.clearRetainingCapacity();
            state.anchor = null;
            state.last = null;
            state.setFolder(defaultFolder(library, r));
            // The boxes held the last roll's details.
            state.details = .initFill(@splat(0));
            state.custom.clearRetainingCapacity();
            state.editing = null;
        }
        const count = r.frames.items.len;
        const known = @min(state.seen.items.len, count);
        state.selected.resize(gpa, count) catch return;
        state.seen.resize(gpa, count) catch {
            state.selected.shrinkRetainingCapacity(known);
            return;
        };
        for (r.frames.items, 0..) |frame, i| {
            if (i < known and std.meta.eql(state.seen.items[i], frame.rating)) continue;
            state.seen.items[i] = frame.rating;
            state.selected.items[i] = state.passes(frame.rating);
        }
    }

    fn setFolder(state: *State, value: []const u8) void {
        gui.setText(&state.folder, value) catch std.log.err("the folder's path is too long: {s}", .{value});
    }

    /// Picks up whatever finished since the last frame (the export and the folder dialog) and
    /// reports it. The app calls this every frame, so an export finishing shows up on any page.
    pub fn poll(state: *State, ctx: context.Context) void {
        if (state.running) |*running| if (running.batch.done.load(.acquire)) {
            running.future.await(ctx.io);
            state.last = summarise(running);
            const batch = running.batch;
            if (batch.failure) |failure| {
                if (failure.number == 0)
                    ctx.notice.set("Export failed · can't create folder ({t})", .{failure.err})
                else
                    ctx.notice.set("Exported {d} of {d} files · frame {d} failed ({t})", .{ batch.written.load(.acquire), batch.jobs.len, failure.number, failure.err });
            } else if (batch.written.load(.acquire) < batch.jobs.len) {
                ctx.notice.set("Export canceled · {d} of {d} files", .{ batch.written.load(.acquire), batch.jobs.len });
            } else {
                const written = batch.written.load(.acquire);
                ctx.notice.set("Exported {d} {s} to {s}", .{ written, if (written == 1) "file" else "files", relativeToLibrary(ctx.library.path, batch.folder) });
            }
            batch.destroy(ctx.gpa);
            state.running = null;
        };
        const chosen = state.dialog.take(ctx.gpa, ctx.io);
        defer Dialog.free(ctx.gpa, chosen);
        if (chosen.len > 0) state.setFolder(relativeToLibrary(ctx.library.path, chosen[chosen.len - 1]));
    }
};

/// The roll's exports folder, relative to the library's folder.
fn defaultFolder(library: *const Library, r: *const roll.Roll) []const u8 {
    return gui.print("{s}/{s}", .{ relativeToLibrary(library.path, r.path), roll.exports_dir });
}

/// Returns `path` relative to the library's folder when it's inside it, or else unchanged.
fn relativeToLibrary(library: []const u8, path: []const u8) []const u8 {
    const base = std.mem.trimEnd(u8, library, std.fs.path.sep_str);
    if (path.len > base.len and std.mem.startsWith(u8, path, base) and path[base.len] == std.fs.path.sep) return path[base.len + 1 ..];
    return path;
}

/// The folder the files go to, as a full path. A relative `folder` is taken from the library's
/// folder.
fn resolvedFolder(gpa: std.mem.Allocator, library: *const Library, folder: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(folder)) return gpa.dupe(u8, folder);
    return std.fs.path.join(gpa, &.{ library.path, folder });
}

fn summarise(running: *const Running) Summary {
    const batch = running.batch;
    var summary: Summary = .{};
    const written = batch.written.load(.acquire);
    const total = batch.jobs.len;
    if (batch.failure) |failure| {
        if (failure.number == 0)
            summary.line.set("Export failed · can't create folder ({t})", .{failure.err})
        else
            summary.line.set("Last export · {d} of {d} files · {s} · frame {d} failed ({t})", .{ written, total, running.what.text(), failure.number, failure.err });
    } else if (written < total) {
        summary.line.set("Export canceled · {d} of {d} files · {s}", .{ written, total, running.what.text() });
    } else {
        summary.line.set("Last export · {d} {s} · {s}", .{ written, if (written == 1) "file" else "files", running.what.text() });
    }
    const shown = std.fs.path.basename(batch.folder);
    const extension = batch.options.format.extension();
    const done = batch.finished.load(.acquire);
    if (written == 0) {
        summary.files.set("{s}", .{shown});
    } else if (done == 1) {
        summary.files.set("{s}/{s}.{s}", .{ shown, batch.jobs[0].stem, extension });
    } else {
        summary.files.set("{s}/{s}.{s} … {s}.{s}", .{ shown, batch.jobs[0].stem, extension, batch.jobs[done - 1].stem, extension });
    }
    summary.folder.set("{s}", .{batch.folder});
    return summary;
}

/// Draws the workspace. Returns a workspace to go to, when the page asks for one.
pub fn draw(state: *State, ctx: context.Context) ?context.Workspace {
    state.io_for_deinit = ctx.io;
    const roll_index = ctx.develop.rollIndex(ctx.library) orelse return drawNoRoll();
    const r = &ctx.library.rolls.items[roll_index];
    state.follow(ctx.gpa, ctx.library, r);
    if (ctx.keys.contains(.select_all)) state.selectAll(true);
    if (ctx.keys.contains(.select_none)) state.selectAll(false);
    if (ctx.keys.contains(.cancel)) if (state.running) |running| running.batch.cancel.store(true, .release);

    const origin = c.ImGui_GetCursorScreenPos();
    const available = c.ImGui_GetContentRegionAvail();
    const panel = gui.px(settings_width);

    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.page);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(0, 0));
    _ = c.ImGui_BeginChild("frames", gui.vec2(available.x - panel, available.y), c.ImGuiChildFlags_None, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse);
    drawPage(state, ctx, roll_index);
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x + available.x - panel, origin.y));
    _ = c.ImGui_BeginChild("settings", gui.vec2(panel, available.y), c.ImGuiChildFlags_None, c.ImGuiWindowFlags_None);
    c.ImGui_PopStyleVar();
    const window = c.ImGui_GetWindowPos();
    drawSettings(state, ctx, roll_index);
    c.ImDrawList_AddLine(c.ImGui_GetWindowDrawList(), window, gui.vec2(window.x, window.y + available.y), theme.imU32(theme.divider));
    c.ImGui_EndChild();
    return null;
}

/// Without a roll open there's nothing to export: the page says so and offers Rolls.
fn drawNoRoll() ?context.Workspace {
    const origin = c.ImGui_GetCursorScreenPos();
    const list = c.ImGui_GetWindowDrawList();
    var at = gui.vec2(origin.x + gui.px(page_padding_x), origin.y + gui.px(page_padding_y));
    fonts.pushSized(.semibold, fonts.page_title_size);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.text), "Export");
    fonts.pop();
    at.y += gui.lineFor(fonts.page_title_size) + gui.px(block_gap);
    const go = gui.noRoll(at);
    shortcuts.tooltip("Rolls", .rolls);
    return if (go) .rolls else null;
}

// The page ---------------------------------------------------------------------------------------

fn drawPage(state: *State, ctx: context.Context, roll_index: usize) void {
    const r = &ctx.library.rolls.items[roll_index];
    const window = c.ImGui_GetWindowPos();
    const size = c.ImGui_GetWindowSize();
    const left = window.x + gui.px(page_padding_x);
    const right = window.x + size.x - gui.px(page_padding_x);
    const top = window.y + gui.px(page_padding_y);
    const bottom = window.y + size.y - gui.px(page_padding_y);

    drawTitleRow(state, r, left, right, top);

    const section_height = gui.px(section_padding * 2 + line + 6 + small_line);
    const grid_top = top + gui.px(control_height + block_gap);
    const grid_bottom = bottom - section_height - gui.px(block_gap);
    c.ImGui_SetCursorScreenPos(gui.vec2(left, grid_top));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.withAlpha(theme.page, 0));
    _ = c.ImGui_BeginChild("grid", gui.vec2(right - left, @max(grid_bottom - grid_top, gui.px(grid_min_height))), c.ImGuiChildFlags_None, c.ImGuiWindowFlags_None);
    drawGrid(state, ctx, roll_index);
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    drawSection(state, gui.vec2(left, bottom - section_height), gui.vec2(right, bottom));
}

/// Draws the title row: "Export Roll 014", how many frames are chosen, and on the right the star
/// filter, Select all and Select none.
fn drawTitleRow(state: *State, r: *const roll.Roll, left: f32, right: f32, top: f32) void {
    const list = c.ImGui_GetWindowDrawList();
    const height = gui.px(control_height);

    fonts.pushSized(.semibold, fonts.page_title_size);
    const title = gui.print("Export {s}", .{r.info.name});
    const title_width = c.ImGui_CalcTextSize(title).x;
    c.ImDrawList_AddText(list, gui.vec2(left, top + (height - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text), title);
    fonts.pop();
    const count = gui.print("{d} of {d} frames selected", .{ state.selectedCount(), r.frames.items.len });
    c.ImDrawList_AddText(list, gui.vec2(left + title_width + gui.px(toolbar_gap), top + (height - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_tertiary), count);

    const none_width = gui.fittedWidth("Select none", gui.button_padding);
    const all_width = gui.fittedWidth("Select all", gui.button_padding);
    const all_x = right - none_width - gui.px(toolbar_gap) - all_width;
    c.ImGui_SetCursorScreenPos(gui.vec2(all_x - gui.px(toolbar_gap + star_filter_width), top));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(combo_padding), (height - c.ImGui_GetFontSize()) / 2));
    if (gui.combo("stars", &star_filters, state.min_stars, star_filter_width)) |picked| {
        state.min_stars = picked;
        state.applyFilter(r);
    }
    c.ImGui_PopStyleVar();
    if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("Rejected left out");
    c.ImGui_SetCursorScreenPos(gui.vec2(all_x, top));
    if (gui.buttonOf(.normal, "Select all", gui.vec2(all_width / gui.scale, control_height))) state.selectAll(true);
    shortcuts.tooltip("Select all", .select_all);
    c.ImGui_SetCursorScreenPos(gui.vec2(right - none_width, top));
    if (gui.buttonOf(.secondary, "Select none", gui.vec2(none_width / gui.scale, height / gui.scale))) state.selectAll(false);
    shortcuts.tooltip("Select none", .select_none);
}

/// Draws the frames as cards, in as many columns of at least 150 pixels as fit. A click picks or
/// unpicks a frame, and a shift-click does the same for every frame from the one clicked before.
fn drawGrid(state: *State, ctx: context.Context, roll_index: usize) void {
    const r = &ctx.library.rolls.items[roll_index];
    const total = r.frames.items.len;
    const list = c.ImGui_GetWindowDrawList();
    const origin = c.ImGui_GetCursorScreenPos();
    if (total == 0) {
        c.ImDrawList_AddText(list, origin, theme.imU32(theme.text_tertiary), "No frames yet");
        return;
    }
    const width = c.ImGui_GetContentRegionAvail().x;
    const gap = gui.px(cell_gap);
    const columns: usize = @max(1, @as(usize, @intFromFloat(@floor((width + gap) / (gui.px(cell_min_width) + gap)))));
    const cell_width = (width - gap * @as(f32, @floatFromInt(columns - 1))) / @as(f32, @floatFromInt(columns));
    const inset = 1 + gui.px(cell_padding);
    const picture_height = (cell_width - 2 * inset) * 2 / 3;
    const cell_height = 2 * inset + picture_height + gui.px(cell_padding + small_line);
    const shift = c.ImGui_GetIO().*.KeyShift;

    for (0..total) |i| {
        const column = i % columns;
        const row = i / columns;
        const corner = gui.vec2(origin.x + @as(f32, @floatFromInt(column)) * (cell_width + gap), origin.y + @as(f32, @floatFromInt(row)) * (cell_height + gap));
        const far = gui.vec2(corner.x + cell_width, corner.y + cell_height);
        c.ImGui_SetCursorScreenPos(corner);
        c.ImGui_PushIDInt(@intCast(i));
        const clicked = c.ImGui_InvisibleButton("frame", gui.vec2(cell_width, cell_height), 0);
        c.ImGui_PopID();
        const hovered = c.ImGui_IsItemHovered(0);
        const frame = r.frames.items[i];
        if (hovered) {
            c.ImGui_SetTooltip("%s", gui.print("Frame {d} · {s}", .{ i + 1, if (!frame.developed) "not developed · automatic settings" else frame.look.label() }).ptr);
        }
        if (clicked) {
            if (shift and state.anchor != null) {
                const from = @min(state.anchor.?, i);
                const to = @max(state.anchor.?, i);
                for (state.selected.items[from .. to + 1]) |*on| on.* = true;
            } else state.selected.items[i] = !state.selected.items[i];
            state.anchor = i;
        }
        const on = state.selected.items[i];

        // The card.
        const radius = gui.px(gui.control_rounding);
        if (on) c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.control), radius, 0);
        c.ImDrawList_AddRectEx(list, corner, far, theme.imU32(if (on) theme.accent else if (hovered) theme.border else theme.divider), radius, 1, 0);
        const picture_min = gui.vec2(corner.x + inset, corner.y + inset);
        const picture_max = gui.vec2(far.x - inset, picture_min.y + picture_height);
        if (ctx.library.thumbnail(ctx.gpa, .{ .roll = roll_index, .frame = i })) |t| {
            gui.imageCover(list, t.ref(), t.width, t.height, picture_min, picture_max, gui.px(picture_rounding));
        } else {
            c.ImDrawList_AddRectFilledEx(list, picture_min, picture_max, theme.imU32(theme.control_hover), gui.px(picture_rounding), 0);
        }

        // The number and the check box under the picture.
        const label_top = picture_max.y + gui.px(cell_padding);
        fonts.pushSized(.mono, fonts.small_size);
        const number = labels.frameNumber(i);
        const number_end = picture_min.x + gui.px(card_inset) + c.ImGui_CalcTextSize(number).x;
        c.ImDrawList_AddText(list, gui.vec2(picture_min.x + gui.px(card_inset), label_top + (gui.px(small_line) - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_secondary), number);
        fonts.pop();
        // The frame's stars, or that it's rejected.
        const label_middle = label_top + gui.px(small_line) / 2;
        if (frame.rating.rejected) {
            c.ImDrawList_AddText(list, gui.vec2(number_end + gui.px(rating_gap), label_middle - c.ImGui_GetFontSize() / 2), theme.imU32(theme.red), "Rejected");
        } else for (0..frame.rating.stars) |k| {
            const star = gui.px(star_radius);
            gui.star(list, gui.vec2(number_end + gui.px(rating_gap) + star + @as(f32, @floatFromInt(k)) * (2 * star + gui.px(star_gap)), label_middle), star, true, theme.accent);
        }
        const box_min = gui.vec2(picture_max.x - gui.px(card_inset + check_size), label_top + (gui.px(small_line) - gui.px(check_size)) / 2);
        drawCheck(list, box_min, gui.px(check_size), on);

        // Frames left out are dimmed by drawing the page colour over them, standing in for the
        // design's opacity.
        if (!on) c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.withAlpha(theme.page, 0.45)), radius, 0);
    }
    const rows = (total + columns - 1) / columns;
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, origin.y + @as(f32, @floatFromInt(rows)) * (cell_height + gap) - gap));
    c.ImGui_Dummy(gui.vec2(0, 0));
}

/// Draws a check box, `size` pixels square, at `min`: amber with a tick when `on`, just an
/// outline when not.
fn drawCheck(list: *c.ImDrawList, min: gui.Vec2, size: f32, on: bool) void {
    if (on) return gui.tickedBox(list, min, size);
    c.ImDrawList_AddRectEx(list, min, gui.vec2(min.x + size, min.y + size), theme.imU32(theme.track), gui.px(gui.box_rounding), 1, 0);
}

/// Draws the bottom of the page: the running export with its progress and Cancel, or what the
/// last one wrote, with Show in folder.
fn drawSection(state: *State, min: gui.Vec2, max: gui.Vec2) void {
    const list = c.ImGui_GetWindowDrawList();
    c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(theme.panel), gui.px(section_rounding), 0);
    const x = min.x + gui.px(section_padding);
    const right = max.x - gui.px(section_padding);
    const first_top = min.y + gui.px(section_padding);
    const first_y = first_top + (gui.px(line) - c.ImGui_GetFontSize()) / 2;
    const second_top = first_top + gui.px(line + 6);

    if (state.running) |running| {
        const batch = running.batch;
        const current = @min(batch.current.load(.acquire), batch.jobs.len - 1);
        const job = batch.jobs[current];
        const cancelling = batch.cancel.load(.acquire);
        const status = if (cancelling)
            gui.print("Canceling after frame {d}…", .{job.number})
        else
            gui.print("Exporting {d} of {d} · {s}.{s} · {s}", .{ current + 1, batch.jobs.len, job.stem, batch.options.format.extension(), batch.stage.load(.acquire).label() });
        if (!cancelling) {
            if (link(gui.vec2(right, first_top), "Cancel")) batch.cancel.store(true, .release);
            shortcuts.tooltip("Cancel", .cancel);
        }
        c.ImDrawList_AddText(list, gui.vec2(x, first_y), theme.imU32(theme.text), gui.elideEnd(status, right - x - gui.px(progress_room)));
        // The progress bar, on the second line.
        const bar_y = second_top + (gui.px(small_line) - gui.px(progress_height)) / 2;
        gui.progressBar(list, gui.vec2(x, bar_y), gui.vec2(right, bar_y + gui.px(progress_height)), batch.progress());
        return;
    }

    const summary = if (state.last) |*s| s else {
        c.ImDrawList_AddText(list, gui.vec2(x, first_y), theme.imU32(theme.text_secondary), "Nothing exported yet");
        fonts.pushSized(.mono, fonts.small_size);
        c.ImDrawList_AddText(list, gui.vec2(x, second_top + (gui.px(small_line) - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_tertiary), gui.elideStart(std.mem.sliceTo(&state.folder, 0), right - x));
        fonts.pop();
        return;
    };
    if (link(gui.vec2(right, first_top), "Show in folder")) showFolder(summary.folder.text());
    c.ImDrawList_AddText(list, gui.vec2(x, first_y), theme.imU32(theme.text), gui.elideEnd(summary.line.text(), right - x - gui.px(summary_room)));
    fonts.pushSized(.mono, fonts.small_size);
    c.ImDrawList_AddText(list, gui.vec2(x, second_top + (gui.px(small_line) - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_tertiary), gui.elideStart(summary.files.text(), right - x));
    fonts.pop();
}

/// An underlined link, styled like the design's links, whose text ends at `top_right`. Returns
/// true when it's clicked.
fn link(top_right: gui.Vec2, label: [:0]const u8) bool {
    const size = c.ImGui_CalcTextSize(label);
    const corner = gui.vec2(top_right.x - size.x, top_right.y);
    c.ImGui_SetCursorScreenPos(corner);
    const clicked = c.ImGui_InvisibleButton(label, gui.vec2(size.x, gui.px(line)), 0);
    const hovered = c.ImGui_IsItemHovered(0);
    if (hovered) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
    const list = c.ImGui_GetWindowDrawList();
    const ink = theme.imU32(if (hovered) theme.text else theme.text_secondary);
    const y = corner.y + (gui.px(line) - size.y) / 2;
    c.ImDrawList_AddText(list, gui.vec2(corner.x, y), ink, label);
    const underline = y + size.y + gui.px(link_underline);
    c.ImDrawList_AddLine(list, gui.vec2(corner.x, underline), gui.vec2(corner.x + size.x, underline), ink);
    return clicked;
}

/// Opens `folder` in the system's file manager.
fn showFolder(folder: []const u8) void {
    var url: std.ArrayList(u8) = .empty;
    defer url.deinit(std.heap.page_allocator);
    url.appendSlice(std.heap.page_allocator, "file://") catch return;
    for (folder) |ch| {
        const plain = std.ascii.isAlphanumeric(ch) or std.mem.indexOfScalar(u8, "/-_.~", ch) != null;
        if (plain) {
            url.append(std.heap.page_allocator, ch) catch return;
        } else {
            url.print(std.heap.page_allocator, "%{X:0>2}", .{ch}) catch return;
        }
    }
    gui.openUrl(url.items);
}

// The settings panel ----------------------------------------------------------------------------

fn drawSettings(state: *State, ctx: context.Context, roll_index: usize) void {
    const r = &ctx.library.rolls.items[roll_index];
    const list = c.ImGui_GetWindowDrawList();
    const window = c.ImGui_GetWindowPos();
    const height = c.ImGui_GetWindowHeight();
    // The panel's top-left corner, moved by its scrolling.
    const origin = gui.vec2(window.x, window.y - c.ImGui_GetScrollY());
    const x = origin.x + gui.px(panel_padding);
    const width = gui.px(settings_width - 2 * panel_padding);
    var y = origin.y + gui.px(panel_padding);
    const running = state.running != null;

    // FILE.
    _ = gui.headingAt(list, x, y, "FILE");
    y += gui.px(small_line + block_gap);
    y = drawFileChoices(state, x, y, width);
    y += gui.px(block_gap);
    y += gui.paragraphAt(list, x, y, width, theme.text_tertiary, formatNote(state));
    y += gui.px(block_gap);

    c.ImGui_BeginDisabled(running);
    y = drawFileGrid(state, ctx, x, y, width);
    c.ImGui_EndDisabled();

    // METADATA.
    y += gui.px(block_gap + 6);
    _ = gui.headingAt(list, x, y, "METADATA");
    y += gui.px(small_line + block_gap);
    y = drawMetadata(state, ctx, roll_index, x, y, width);
    y += gui.px(block_gap);
    y += gui.paragraphAt(list, x, y, width, theme.text_tertiary, "EXIF and XMP · sidecar per file");

    // Export, at the bottom.
    const button_y = @max(y + gui.px(block_gap), origin.y + height - gui.px(panel_padding + export_height));
    c.ImGui_SetCursorScreenPos(gui.vec2(x, button_y));
    const count = state.selectedCount();
    const pattern_ok = if (exporting.checkPattern(std.mem.sliceTo(&state.pattern, 0))) true else |_| false;
    const folder_ok = std.mem.sliceTo(&state.folder, 0).len > 0;
    const label = if (running) "Exporting…" else if (count == 1) "Export 1 frame" else gui.print("Export {d} frames", .{count});
    c.ImGui_BeginDisabled(running or count == 0 or !pattern_ok or !folder_ok or state.file == .heic);
    if (gui.buttonOf(.primary, gui.print("{s}##export", .{label}), gui.vec2(width / gui.scale, export_height))) start(state, ctx, r);
    c.ImGui_EndDisabled();
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) {
        const why: ?[]const u8 = if (running) "Export under way" else if (count == 0) "No frames selected" else if (!pattern_ok) "Invalid file name pattern" else if (!folder_ok) "No folder chosen" else null;
        if (why) |text| c.ImGui_SetTooltip("%s", gui.print("{s}", .{text}).ptr);
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(x, button_y + gui.px(export_height + panel_padding)));
    c.ImGui_Dummy(gui.vec2(0, 0));
}

/// Draws the file choices (TIFF 16-bit, TIFF 8-bit, JPEG and HEIC HDR) as pills that wrap.
/// Returns the y below them.
fn drawFileChoices(state: *State, x: f32, top: f32, width: f32) f32 {
    var at = gui.vec2(x, top);
    const height = gui.px(pill_height);
    c.ImGui_BeginDisabled(state.running != null);
    defer c.ImGui_EndDisabled();
    for (std.enums.values(FileChoice)) |choice| {
        const label = choice.label();
        const pill_width = gui.fittedWidth(label, pill_padding);
        if (at.x > x and at.x + pill_width > x + width) {
            at = gui.vec2(x, at.y + height + gui.px(pill_gap));
        }
        c.ImGui_SetCursorScreenPos(at);
        if (choice == .heic) {
            drawUnavailable(label, gui.vec2(pill_width, height));
            if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) c.ImGui_SetTooltip("Not available yet");
        } else {
            if (gui.buttonOf(if (state.file == choice) .selected else .unselected, label, gui.vec2(pill_width / gui.scale, pill_height))) state.file = choice;
        }
        at.x += pill_width + gui.px(pill_gap);
    }
    return at.y + height;
}

/// Draws a choice you can't pick: no fill, a dashed border and tertiary text.
fn drawUnavailable(label: [:0]const u8, size: gui.Vec2) void {
    const corner = c.ImGui_GetCursorScreenPos();
    _ = c.ImGui_InvisibleButton(label, size, 0);
    const list = c.ImGui_GetWindowDrawList();
    const far = gui.vec2(corner.x + size.x, corner.y + size.y);
    gui.dashedRoundedRect(list, corner, far, theme.imU32(theme.border), gui.px(gui.choice_rounding));
    const text_size = c.ImGui_CalcTextSize(label);
    c.ImDrawList_AddText(list, gui.vec2(corner.x + (size.x - text_size.x) / 2, corner.y + (size.y - text_size.y) / 2), theme.imU32(theme.text_tertiary), label);
}

/// A note on the chosen file type, and anything worth knowing about it for these frames.
fn formatNote(state: *const State) []const u8 {
    const options = state.options();
    const base = switch (state.file) {
        .tiff16 => "16-bit · ZIP · ICC profile",
        .tiff8 => "8-bit · ZIP · ICC profile",
        .jpeg => gui.print("8-bit · quality {d} · ICC profile", .{options.quality}),
        .heic => "HDR with gain map · not available yet",
    };
    const banding = if (options.space == .prophoto and options.bits() == .eight) " · banding risk in 8-bit" else "";
    return gui.print("{s}{s}", .{ base, banding });
}

/// Draws colour space, size, file names and folder as the design's grid of rows: a label column,
/// then the control. JPEG adds its quality first. Returns the y below the last row.
fn drawFileGrid(state: *State, ctx: context.Context, x: f32, top: f32, width: f32) f32 {
    const grid: FileGrid = .{
        .list = c.ImGui_GetWindowDrawList(),
        .x = x,
        .control_x = x + gui.px(label_width + grid_gap),
        .control_width = width - gui.px(label_width + grid_gap),
        .row = gui.px(control_height),
    };
    const list = grid.list;
    const control_x = grid.control_x;
    const control_width = grid.control_width;
    const row = grid.row;
    var y = top;
    if (state.file == .jpeg) y = qualityRow(state, grid, y);

    rowLabel(list, x, y, "Color space");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(combo_padding), (row - c.ImGui_GetFontSize()) / 2));
    if (gui.comboOf(icc.Space, "space", &exporting.spaces, state.space, spaceLabel, control_width / gui.scale)) |picked| state.space = picked;
    y += row + gui.px(grid_gap);

    rowLabel(list, x, y, "Size");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y));
    if (gui.comboOf(SizeChoice, "size", std.enums.values(SizeChoice), state.size, SizeChoice.label, control_width / gui.scale)) |picked| state.size = picked;
    c.ImGui_PopStyleVar();
    y += row + gui.px(grid_gap);

    if (state.size == .custom) y = longEdgeRow(state, grid, y);
    y = namesRow(state, grid, y);
    return folderRow(state, ctx, grid, y);
}

/// Where the File panel's rows go: their labels at `x`, their controls at `control_x`.
const FileGrid = struct {
    list: *c.ImDrawList,
    x: f32,
    control_x: f32,
    control_width: f32,
    row: f32,
};

/// Draws the JPEG quality slider at `y`. Returns the y of the next row.
fn qualityRow(state: *State, grid: FileGrid, top: f32) f32 {
    const list = grid.list;
    const x = grid.x;
    const control_x = grid.control_x;
    const control_width = grid.control_width;
    const row = grid.row;
    var y = top;
    rowLabel(list, x, y, "Quality");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y + (row - c.ImGui_GetFrameHeight()) / 2));
    _ = gui.slider("quality", &state.quality, 1, 100, control_width / gui.scale - gui.value_column - gui.label_gap - gui.reset_space);
    state.quality = @round(state.quality);
    const shown = gui.print("{d:.0}", .{state.quality});
    gui.valueText(shown);
    c.ImGui_SameLineEx(0, gui.px(gui.reset_space - gui.reset_size));
    const at = c.ImGui_GetCursorScreenPos();
    const default_quality = (State{}).quality;
    if (gui.resetButton("reset quality", gui.vec2(at.x, at.y + (c.ImGui_GetFrameHeight() - gui.px(gui.reset_size)) / 2), shown, gui.print("{d:.0}", .{default_quality}))) state.quality = default_quality;
    y += row + gui.px(grid_gap);
    return y;
}

/// Draws the custom long edge's field at `y`. Returns the y of the next row.
fn longEdgeRow(state: *State, grid: FileGrid, top: f32) f32 {
    const list = grid.list;
    const x = grid.x;
    const control_x = grid.control_x;
    const row = grid.row;
    var y = top;
    rowLabel(list, x, y, "Long edge");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y));
    fonts.pushSized(.mono, fonts.small_size);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(field_padding), (row - c.ImGui_GetFontSize()) / 2));
    c.ImGui_SetNextItemWidth(gui.px(edge_field_width));
    _ = c.ImGui_InputTextWithHint("##long edge", "3000", &state.custom_edge, state.custom_edge.len + 1, c.ImGuiInputTextFlags_CharsDecimal);
    c.ImGui_PopStyleVar();
    fonts.pop();
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) c.ImGui_SetTooltip("%s", gui.print("{d} to {d} px", .{ min_custom_edge, max_custom_edge }).ptr);
    const unit_y = y + (row - c.ImGui_GetFontSize()) / 2;
    c.ImDrawList_AddText(list, gui.vec2(control_x + gui.px(edge_field_width + unit_gap), unit_y), theme.imU32(theme.text_tertiary), "px");
    y += row + gui.px(grid_gap);
    return y;
}

/// Draws the file name pattern at `y`, with what's wrong with it. Returns the y of the next row.
fn namesRow(state: *State, grid: FileGrid, top: f32) f32 {
    const list = grid.list;
    const x = grid.x;
    const control_x = grid.control_x;
    const control_width = grid.control_width;
    const row = grid.row;
    var y = top;
    rowLabel(list, x, y, "File names");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y));
    fonts.pushSized(.mono, fonts.small_size);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(field_padding), (row - c.ImGui_GetFontSize()) / 2));
    _ = gui.textField("names", &state.pattern, default_pattern, control_width / gui.scale);
    c.ImGui_PopStyleVar();
    fonts.pop();
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) {
        c.ImGui_SetTooltip("{roll}  roll name, lowercase\n{name}  roll name\n{frame}  frame number\n{frame:02}  two digits\n{stock}  film stock\n{date}  date shot");
    }
    y += row;
    if (exporting.checkPattern(std.mem.sliceTo(&state.pattern, 0))) |_| {} else |err| {
        y += gui.px(problem_gap);
        const problem = switch (err) {
            error.NoFrameNumber => "{frame} missing",
            error.UnknownField => "Unknown field",
            error.UnclosedBrace => "Unclosed brace",
        };
        y += gui.paragraphAt(list, control_x, y, control_width, theme.accent, problem);
        y -= gui.px(line) - c.ImGui_GetFontSize();
    }
    y += gui.px(grid_gap);
    return y;
}

/// Draws the folder the files go to at `y`, with Choose. Returns the y below it.
fn folderRow(state: *State, ctx: context.Context, grid: FileGrid, y: f32) f32 {
    const list = grid.list;
    const x = grid.x;
    const control_x = grid.control_x;
    const control_width = grid.control_width;
    const row = grid.row;
    rowLabel(list, x, y, "Folder");
    const choose_width = gui.fittedWidth("Choose", pill_padding);
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(field_padding), (row - c.ImGui_GetFontSize()) / 2));
    _ = gui.textField("folder", &state.folder, "Roll/exports", (control_width - choose_width - gui.px(field_gap)) / gui.scale);
    c.ImGui_PopStyleVar();
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) c.ImGui_SetTooltip("Relative to the library");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x + control_width - choose_width, y));
    c.ImGui_BeginDisabled(state.dialog.isShowing());
    if (gui.buttonOf(.normal, "Choose", gui.vec2(choose_width / gui.scale, control_height))) chooseFolder(state, ctx);
    c.ImGui_EndDisabled();
    return y + row;
}

/// Draws a grid row's label, centred in the row's height.
fn rowLabel(list: *c.ImDrawList, x: f32, y: f32, label: [:0]const u8) void {
    gui.textIn(list, x, y, gui.px(control_height), theme.text_secondary, label);
}

/// Opens the system's folder dialog, starting at the folder that's chosen now.
fn chooseFolder(state: *State, ctx: context.Context) void {
    const folder = resolvedFolder(ctx.gpa, ctx.library, std.mem.sliceTo(&state.folder, 0)) catch return;
    defer ctx.gpa.free(folder);
    // Start at the chosen folder if it exists, or else at the library.
    std.Io.Dir.cwd().access(ctx.io, folder, .{}) catch {
        state.dialog.showAt(ctx.gpa, ctx.io, gui.print("{s}", .{ctx.library.path}));
        return;
    };
    state.dialog.showAt(ctx.gpa, ctx.io, gui.print("{s}", .{folder}));
}

/// Draws the roll details you can include, each with what it holds. Returns the y below them.
fn drawMetadata(state: *State, ctx: context.Context, roll_index: usize, x: f32, top: f32, width: f32) f32 {
    const r = &ctx.library.rolls.items[roll_index];
    const list = c.ImGui_GetWindowDrawList();
    const value_x = x + gui.px(metadata_check_width + metadata_spacing + metadata_name_width + metadata_spacing);
    const value_width = x + width - value_x;
    const row = gui.px(detail_row);
    var y = top;

    const rows = [_]MetadataRow{
        .{ .label = "Camera", .flag = &state.include.camera, .value = .{ .detail = .camera } },
        .{ .label = "Lens", .flag = &state.include.lens, .value = .{ .detail = .lens } },
        .{ .label = "Film stock", .flag = &state.include.stock, .value = .{ .fixed = .{ .text = r.info.stock, .why = "Set in Develop" } } },
        .{ .label = "Date shot", .flag = &state.include.shot, .value = .{ .detail = .shot } },
        .{ .label = "Copyright", .flag = &state.include.copyright, .value = .{ .detail = .copyright } },
        .{ .label = "Notes", .flag = &state.include.notes, .value = .{ .detail = .notes } },
        .{ .label = "Settings", .flag = &state.include.settings, .value = .{ .fixed = .{ .text = "Look, base, scanner", .quiet = true } } },
        .{ .label = "Rating", .flag = &state.include.rating, .value = .{ .fixed = .{ .text = "Stars, rejected", .quiet = true } } },
    };
    for (rows) |each| {
        metadataCheck(list, x, y, each.label, each.flag);
        switch (each.value) {
            .detail => |which| detailField(state, ctx, r, which, gui.vec2(value_x, y), value_width),
            .fixed => |fixed| fixedValue(list, each.label, fixed, gui.vec2(value_x, y), value_width),
        }
        y += row + gui.px(metadata_gap);
    }

    return drawOwnFields(state, ctx, r, list, gui.vec2(x, y), width, value_x) - gui.px(metadata_gap);
}

/// Draws a Metadata value that's set somewhere else, at `at`, with why as its tooltip.
fn fixedValue(list: *c.ImDrawList, label: [:0]const u8, fixed: FixedValue, at: gui.Vec2, width: f32) void {
    const row = gui.px(detail_row);
    const text_y = at.y + (row - c.ImGui_GetFontSize()) / 2;
    const quiet = fixed.quiet or fixed.text == null;
    c.ImDrawList_AddText(list, gui.vec2(at.x + gui.px(value_inset), text_y), theme.imU32(if (quiet) theme.text_tertiary else theme.text), gui.elideEnd(fixed.text orelse "Not set", width - gui.px(value_inset)));
    if (fixed.why) |why| {
        c.ImGui_SetCursorScreenPos(at);
        _ = c.ImGui_InvisibleButton(label, gui.vec2(width, row), 0);
        if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("%s", gui.print("{s}", .{why}).ptr);
    }
}

/// Draws the roll's own fields at `at`, `width` wide with their values from `value_x`: a name and
/// a value each, with Add and Remove. Returns the y below them.
fn drawOwnFields(state: *State, ctx: context.Context, r: *roll.Roll, list: *c.ImDrawList, at: gui.Vec2, width: f32, value_x: f32) f32 {
    const x = at.x;
    var y = at.y;
    const row = gui.px(detail_row);
    const value_width = x + width - value_x;
    metadataCheck(list, x, y, "Own fields", &state.include.fields);
    const add_width = gui.fittedWidth("Add field", pill_padding);
    c.ImGui_SetCursorScreenPos(gui.vec2(x + width - add_width, y));
    const add = gui.buttonOf(.normal, "Add field", gui.vec2(add_width / gui.scale, detail_row));
    if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("Written to XMP");
    y += row + gui.px(metadata_gap);
    syncFields(state, ctx.gpa, r);
    var remove: ?usize = null;
    var edited = false;
    const name_width = gui.px(metadata_name_width);
    const value_left = value_x;
    const remove_size = row;
    for (state.custom.items, 0..) |*field, i| {
        c.ImGui_PushIDInt(@intCast(i));
        defer c.ImGui_PopID();
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(field_padding), (row - c.ImGui_GetFontSize()) / 2));
        c.ImGui_SetCursorScreenPos(gui.vec2(x + gui.px(metadata_check_width + metadata_spacing), y));
        if (state.focus_new_field and i + 1 == state.custom.items.len) {
            c.ImGui_SetKeyboardFocusHere();
            state.focus_new_field = false;
        }
        c.ImGui_BeginDisabled(!field.fits);
        _ = gui.textField("name", &field.name, "Name", (name_width - gui.px(metadata_spacing)) / gui.scale);
        edited = trackEdit(state, .{ .field_name = i }) or edited;
        c.ImGui_SetCursorScreenPos(gui.vec2(value_left, y));
        _ = gui.textField("value", &field.value, "Value", (value_width - remove_size - gui.px(metadata_spacing)) / gui.scale);
        edited = trackEdit(state, .{ .field_value = i }) or edited;
        c.ImGui_EndDisabled();
        c.ImGui_PopStyleVar();
        c.ImGui_SetCursorScreenPos(gui.vec2(x + width - remove_size, y));
        if (c.ImGui_InvisibleButton("remove", gui.vec2(remove_size, remove_size), 0)) remove = i;
        const hovered = c.ImGui_IsItemHovered(0);
        if (hovered) c.ImGui_SetTooltip("Remove");
        const centre = gui.vec2(x + width - remove_size / 2, y + row / 2);
        gui.cross(list, centre, gui.px(remove_arm), gui.px(remove_thickness), if (hovered) theme.text else theme.text_tertiary);
        y += row + gui.px(metadata_gap);
    }
    if (add) state.focus_new_field = true;
    if (edited or add or remove != null) saveFields(state, ctx, r, remove, add);
    return y;
}

/// One row of Metadata: a check box for whether it goes into the files, its label, and either a
/// detail you can edit here or a value you can't.
/// A Metadata value that's set somewhere else: its text, or null when it isn't set, whether it's
/// shown quietly, and where it's set, for its tooltip.
const FixedValue = struct { text: ?[]const u8, quiet: bool = false, why: ?[]const u8 = null };

const MetadataRow = struct {
    label: [:0]const u8,
    flag: *bool,
    value: union(enum) {
        detail: roll.Detail,
        fixed: FixedValue,
    },
};

/// Draws a Metadata row's check box and label at `y`. Clicking either flips `flag`.
fn metadataCheck(list: *c.ImDrawList, x: f32, y: f32, label: [:0]const u8, flag: *bool) void {
    const row = gui.px(detail_row);
    c.ImGui_SetCursorScreenPos(gui.vec2(x, y));
    if (c.ImGui_InvisibleButton(gui.print("{s}##check", .{label}), gui.vec2(gui.px(metadata_check_width + metadata_spacing + metadata_name_width), row), 0)) flag.* = !flag.*;
    const hovered = c.ImGui_IsItemHovered(0);
    const box = gui.vec2(x + gui.px(metadata_check_inset), y + (row - gui.px(metadata_check)) / 2);
    gui.checkBox(list, box, gui.px(metadata_check), flag.*, hovered);
    c.ImDrawList_AddText(list, gui.vec2(x + gui.px(metadata_check_width + metadata_spacing), y + (row - c.ImGui_GetFontSize()) / 2), theme.imU32(if (hovered) theme.text else theme.text_secondary), label);
}

/// Draws the field for one of the roll's details. It shows the roll's value except while you're
/// typing in it, and saves the roll when you leave it.
fn detailField(state: *State, ctx: context.Context, r: *roll.Roll, which: roll.Detail, at: gui.Vec2, width: f32) void {
    const buffer = state.details.getPtr(which);
    const value = r.detail(which) orelse "";
    // A value too long for the box can't be edited here, so a shortened copy never gets saved
    // over it.
    const fits = value.len <= buffer.len;
    if (!state.isEditing(.{ .detail = which })) showCut(buffer, value);
    c.ImGui_SetCursorScreenPos(at);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(field_padding), (gui.px(detail_row) - c.ImGui_GetFontSize()) / 2));
    c.ImGui_BeginDisabled(!fits);
    _ = gui.textField(@tagName(which), buffer, "Not set", width / gui.scale);
    c.ImGui_EndDisabled();
    c.ImGui_PopStyleVar();
    if (which == .shot and c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("YYYY, YYYY-MM or YYYY-MM-DD");
    if (trackEdit(state, .{ .detail = which }) and fits) {
        r.setDetail(ctx.io, which, std.mem.sliceTo(buffer, 0)) catch |err| std.log.err("can't save {s}'s {t}: {t}", .{ r.info.name, which, err });
    }
}

/// Notes which field is being typed in, from the item just drawn. Returns true when you've just
/// left it after changing it, which is when it's saved.
fn trackEdit(state: *State, which: Editing) bool {
    if (c.ImGui_IsItemActive()) {
        state.editing = which;
    } else if (state.isEditing(which)) {
        state.editing = null;
    }
    return c.ImGui_IsItemDeactivatedAfterEdit();
}

/// Fills the fields' boxes from the roll, unless one of them is being typed in.
fn syncFields(state: *State, gpa: std.mem.Allocator, r: *const roll.Roll) void {
    if (state.editing) |e| if (e == .field_name or e == .field_value) return;
    state.custom.resize(gpa, r.info.fields.len) catch return;
    for (state.custom.items, r.info.fields) |*boxes, field| {
        boxes.fits = field.name.len <= boxes.name.len and field.value.len <= boxes.value.len;
        showCut(&boxes.name, field.name);
        showCut(&boxes.value, field.value);
    }
}

/// Puts `value` into a text box, cut short at a whole character if it doesn't fit. Only for
/// showing: a box holding a cut value mustn't be saved.
fn showCut(buffer: [:0]u8, value: []const u8) void {
    var end = @min(value.len, buffer.len);
    // Back off to the start of a character, so the cut doesn't split one.
    while (end < value.len and end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    @memcpy(buffer[0..end], value[0..end]);
    buffer[end] = 0;
}

/// Saves the fields as they're typed, leaving out `remove` and adding an empty one for `add`.
fn saveFields(state: *const State, ctx: context.Context, r: *roll.Roll, remove: ?usize, add: bool) void {
    var fields: std.ArrayList(roll.Field) = .empty;
    defer fields.deinit(ctx.gpa);
    for (state.custom.items, 0..) |*boxes, i| {
        if (remove == i) continue;
        // A field that didn't fit its boxes is kept as the roll has it.
        const field: roll.Field = if (boxes.fits or i >= r.info.fields.len) .{ .name = std.mem.sliceTo(&boxes.name, 0), .value = std.mem.sliceTo(&boxes.value, 0) } else r.info.fields[i];
        fields.append(ctx.gpa, field) catch return;
    }
    if (add) fields.append(ctx.gpa, .{ .name = "", .value = "" }) catch return;
    r.setFields(ctx.io, fields.items) catch |err| std.log.err("can't save {s}'s fields: {t}", .{ r.info.name, err });
}

/// Starts exporting the chosen frames of `r` on a separate thread.
fn start(state: *State, ctx: context.Context, r: *const roll.Roll) void {
    var indices: std.ArrayList(usize) = .empty;
    defer indices.deinit(ctx.gpa);
    for (state.selected.items, 0..) |on, i| {
        if (on) indices.append(ctx.gpa, i) catch return;
    }
    const folder = resolvedFolder(ctx.gpa, ctx.library, std.mem.sliceTo(&state.folder, 0)) catch return;
    defer ctx.gpa.free(folder);
    const options = state.options();
    const batch = exporting.Batch.create(ctx.gpa, ctx.io, &ctx.library.looks, r, indices.items, .{
        .options = options,
        .include = state.include,
        .pattern = std.mem.sliceTo(&state.pattern, 0),
        .folder = folder,
        .stock_curves = ctx.library.stockCurves(r, r.info.kind),
    }) catch |err| {
        ctx.notice.set("Can't export · {t}", .{err});
        return;
    };
    const future = ctx.io.concurrent(exporting.Batch.run, .{ batch, ctx.gpa, ctx.io }) catch |err| {
        batch.destroy(ctx.gpa);
        ctx.notice.set("Can't start export · {t}", .{err});
        return;
    };
    var running: Running = .{ .batch = batch, .future = future };
    running.what.set("{s}, {s}", .{ state.file.label(), spaceLabel(state.space) });
    state.running = running;
}

test "a value cut short for showing keeps whole characters" {
    var box: [6:0]u8 = @splat(0);
    showCut(&box, "Gent");
    try std.testing.expectEqualStrings("Gent", std.mem.sliceTo(&box, 0));
    // "è" is two bytes, the sixth and seventh, so a cut after six would split it.
    showCut(&box, "Gentsè, Belgium");
    try std.testing.expectEqualStrings("Gents", std.mem.sliceTo(&box, 0));
    showCut(&box, "Ghent, Belgium");
    try std.testing.expectEqualStrings("Ghent,", std.mem.sliceTo(&box, 0));
}

test "a custom long edge is a number within range, or nothing" {
    var state: State = .{};
    try std.testing.expectEqual(@as(?usize, 3000), state.customEdge());
    try gui.setText(&state.custom_edge, " 20 ");
    try std.testing.expectEqual(@as(?usize, min_custom_edge), state.customEdge());
    try gui.setText(&state.custom_edge, "9999999");
    try std.testing.expectEqual(@as(?usize, max_custom_edge), state.customEdge());
    try gui.setText(&state.custom_edge, "");
    try std.testing.expectEqual(@as(?usize, null), state.customEdge());
}

test "a folder in the library is shown from the library" {
    const sep = std.fs.path.sep_str;
    const library = sep ++ "photos" ++ sep ++ "Rolls";
    try std.testing.expectEqualStrings("Roll 014" ++ sep ++ "exports", relativeToLibrary(library, library ++ sep ++ "Roll 014" ++ sep ++ "exports"));
    try std.testing.expectEqualStrings("Roll 014", relativeToLibrary(library ++ sep, library ++ sep ++ "Roll 014"));
    try std.testing.expectEqualStrings(sep ++ "photos" ++ sep ++ "Rolls 2", relativeToLibrary(library, sep ++ "photos" ++ sep ++ "Rolls 2"));
}
