//! The Export workspace: the open roll's frames to choose from, and on the right how to write
//! them: format, colour space, size, file names, folder and metadata. The export runs on a thread
//! of its own with its progress at the bottom of the page, so the window keeps answering; the
//! export itself is `minilab.export`.

const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const context = @import("context.zig");
const shortcuts = @import("shortcuts.zig");
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
/// The space between the blocks of the page and of the panel.
const block_gap = 14;
const title_size = 18;
const cell_min_width = 150;
const cell_gap = 10;
const cell_padding = 6;
const check_size = 16;
const pill_height = 30;
const pill_gap = 4;
const control_height = 32;
const label_width = 110;
const grid_gap = 10;
const metadata_row = 19;
const metadata_gap = 8;
const metadata_check = 13;
const export_height = 40;
const section_padding = 12;
/// Line heights: the design's text is 1.4 times its size.
const line = 13 * 1.4;
const small_line = 12 * 1.4;

const path_field = 1024;

/// The file choices, as the panel lists them.
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

const space_names = [_][]const u8{ "Display P3", "sRGB", "Adobe RGB", "ProPhoto RGB" };
const sizes = [_]?usize{ null, 4000, 2048 };
const size_names = [_][]const u8{ "Full resolution", "Long edge 4000 px", "Long edge 2048 px" };
const default_pattern = "{roll}_{frame:02}";

/// An export under way on its own thread.
const Running = struct {
    batch: *exporting.Batch,
    future: std.Io.Future(void),
    /// What it writes, as the summary will say it.
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
    /// The roll the selection belongs to, by folder; it starts again for another roll.
    roll_path: ?[]u8 = null,
    selected: std.ArrayList(bool) = .empty,
    /// The frame clicked last, where a shift-click's range starts.
    anchor: ?usize = null,
    file: FileChoice = .tiff16,
    quality: f32 = 92,
    /// Indices in `minilab.export.spaces` and `sizes`.
    space: usize = 0,
    size: usize = 0,
    pattern: [gui.text_capacity:0]u8 = gui.initText(gui.text_capacity, default_pattern),
    /// Where the files go: from the library's folder, or absolute.
    folder: [path_field:0]u8 = @splat(0),
    include: exporting.Include = .{},
    dialog: Dialog = .{ .kind = .folder },
    running: ?Running = null,
    last: ?Summary = null,
    /// The Io the export runs on, kept for `deinit`, which isn't handed one.
    io_for_deinit: ?std.Io = null,

    pub fn deinit(state: *State, gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) void {
        _ = gpu;
        if (state.running) |*running| {
            running.batch.cancel.store(true, .release);
            // Waits for the frame under way to reach its next check.
            running.future.await(state.io_for_deinit orelse return);
            running.batch.destroy(gpa);
        }
        state.selected.deinit(gpa);
        state.dialog.deinit(gpa);
        if (state.roll_path) |p| gpa.free(p);
    }

    /// Whether everything the page shows has loaded: for a screenshot, which waits for it.
    pub fn settled(state: *const State) bool {
        return state.running == null;
    }

    fn options(state: *const State) exporting.Options {
        return .{
            .format = if (state.file == .jpeg) .jpeg else .tiff,
            .depth = if (state.file == .tiff8) .eight else .sixteen,
            .quality = @intFromFloat(std.math.clamp(@round(state.quality), 1, 100)),
            .space = exporting.spaces[state.space],
            .long_edge = sizes[state.size],
        };
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

    /// Starts the selection over for roll `r` when it's another roll, and keeps it as long as the
    /// roll's frames when frames were added.
    fn follow(state: *State, gpa: std.mem.Allocator, library: *const Library, r: *const roll.Roll) void {
        const same = if (state.roll_path) |p| std.mem.eql(u8, p, r.path) else false;
        if (!same) {
            const copy = gpa.dupe(u8, r.path) catch return;
            if (state.roll_path) |p| gpa.free(p);
            state.roll_path = copy;
            state.selected.clearRetainingCapacity();
            state.anchor = null;
            state.last = null;
            state.setFolder(defaultFolder(library, r));
        }
        const count = r.frames.items.len;
        if (state.selected.items.len > count) state.selected.shrinkRetainingCapacity(count);
        while (state.selected.items.len < count) state.selected.append(gpa, true) catch return;
    }

    fn setFolder(state: *State, value: []const u8) void {
        gui.setText(&state.folder, value) catch std.log.err("the folder's path is too long: {s}", .{value});
    }

    /// Takes in what finished since the last frame, the export and the folder dialog, and says
    /// so. The app calls it every frame, so that an export's end shows on any page.
    pub fn poll(state: *State, ctx: context.Context) void {
        if (state.running) |*running| if (running.batch.done.load(.acquire)) {
            running.future.await(ctx.io);
            state.last = summarise(running);
            const batch = running.batch;
            if (batch.failure) |failure| {
                if (failure.number == 0)
                    ctx.notice.set("Export failed: can't make the folder ({t}).", .{failure.err})
                else
                    ctx.notice.set("Exported {d} of {d} files; frame {d} failed: {t}.", .{ batch.written.load(.acquire), batch.jobs.len, failure.number, failure.err });
            } else if (batch.written.load(.acquire) < batch.jobs.len) {
                ctx.notice.set("Export cancelled after {d} of {d} files.", .{ batch.written.load(.acquire), batch.jobs.len });
            } else {
                const written = batch.written.load(.acquire);
                ctx.notice.set("Exported {d} {s} to {s}.", .{ written, if (written == 1) "file" else "files", relativeToLibrary(ctx.library, batch.folder) });
            }
            batch.destroy(ctx.gpa);
            state.running = null;
        };
        const chosen = state.dialog.take(ctx.gpa, ctx.io);
        defer Dialog.free(ctx.gpa, chosen);
        if (chosen.len > 0) state.setFolder(relativeToLibrary(ctx.library, chosen[chosen.len - 1]));
    }
};

/// The roll's exports folder, from the library's folder.
fn defaultFolder(library: *const Library, r: *const roll.Roll) []const u8 {
    return gui.print("{s}/{s}", .{ relativeToLibrary(library, r.path), roll.exports_dir });
}

/// `path` from the library's folder when it's inside it, or else as it is.
fn relativeToLibrary(library: *const Library, path: []const u8) []const u8 {
    const base = std.mem.trimEnd(u8, library.path, std.fs.path.sep_str);
    if (path.len > base.len and std.mem.startsWith(u8, path, base) and path[base.len] == std.fs.path.sep) return path[base.len + 1 ..];
    return path;
}

/// The folder the files go to, as a path: a relative one is from the library's folder.
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
            summary.line.set("Export failed: the folder couldn't be made ({t})", .{failure.err})
        else
            summary.line.set("Last export: {d} of {d} files, {s}; frame {d} failed ({t})", .{ written, total, running.what.text(), failure.number, failure.err });
    } else if (written < total) {
        summary.line.set("Export cancelled: {d} of {d} files, {s}", .{ written, total, running.what.text() });
    } else {
        summary.line.set("Last export: {d} {s}, {s}", .{ written, if (written == 1) "file" else "files", running.what.text() });
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
    fonts.pushSized(.semibold, title_size);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.text), "Export");
    fonts.pop();
    at.y += gui.px(title_size * 1.4 + block_gap);
    c.ImDrawList_AddText(list, at, theme.imU32(theme.text_secondary), "No roll is open. Open one in Rolls, then come back here to export its frames.");
    at.y += gui.px(line + block_gap);
    c.ImGui_SetCursorScreenPos(at);
    const width = c.ImGui_CalcTextSize("Go to Rolls").x / gui.scale + 24 + 2;
    const go = gui.buttonOf(.normal, "Go to Rolls", gui.vec2(width, control_height));
    shortcuts.tooltip("The library's rolls", .rolls);
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
    _ = c.ImGui_BeginChild("grid", gui.vec2(right - left, @max(grid_bottom - grid_top, gui.px(40))), c.ImGuiChildFlags_None, c.ImGuiWindowFlags_None);
    drawGrid(state, ctx, roll_index);
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    drawSection(state, gui.vec2(left, bottom - section_height), gui.vec2(right, bottom));
}

/// "Export Roll 014", how many frames are chosen, and Select all and Select none on the right.
fn drawTitleRow(state: *State, r: *const roll.Roll, left: f32, right: f32, top: f32) void {
    const list = c.ImGui_GetWindowDrawList();
    const height = gui.px(control_height);

    fonts.pushSized(.semibold, title_size);
    const title = gui.print("Export {s}", .{r.info.name});
    const title_width = c.ImGui_CalcTextSize(title).x;
    c.ImDrawList_AddText(list, gui.vec2(left, top + (height - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text), title);
    fonts.pop();
    const count = gui.print("{d} of {d} frames selected", .{ state.selectedCount(), r.frames.items.len });
    c.ImDrawList_AddText(list, gui.vec2(left + title_width + gui.px(10), top + (height - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_tertiary), count);

    const none_width = c.ImGui_CalcTextSize("Select none").x + gui.px(12 * 2 + 2);
    const all_width = c.ImGui_CalcTextSize("Select all").x + gui.px(12 * 2 + 2);
    c.ImGui_SetCursorScreenPos(gui.vec2(right - none_width - gui.px(10) - all_width, top));
    if (gui.buttonOf(.normal, "Select all", gui.vec2(all_width / gui.scale, control_height))) state.selectAll(true);
    shortcuts.tooltip("Selects every frame of the roll", .select_all);
    c.ImGui_SetCursorScreenPos(gui.vec2(right - none_width, top));
    if (outlineButton("Select none", gui.vec2(none_width, height))) state.selectAll(false);
    shortcuts.tooltip("Clears the selection", .select_none);
}

/// A button with a border and no fill, its label in the secondary colour: the design's quieter
/// button. `size` in screen pixels.
fn outlineButton(label: [:0]const u8, size: gui.Vec2) bool {
    const corner = c.ImGui_GetCursorScreenPos();
    const clicked = c.ImGui_InvisibleButton(label, size, 0);
    const hovered = c.ImGui_IsItemHovered(0);
    const list = c.ImGui_GetWindowDrawList();
    const far = gui.vec2(corner.x + size.x, corner.y + size.y);
    if (hovered) c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.control_hover), gui.px(5), 0);
    c.ImDrawList_AddRectEx(list, corner, far, theme.imU32(theme.border), gui.px(5), 1, 0);
    const text_size = c.ImGui_CalcTextSize(label);
    c.ImDrawList_AddText(list, gui.vec2(corner.x + (size.x - text_size.x) / 2, corner.y + (size.y - text_size.y) / 2), theme.imU32(if (hovered) theme.text else theme.text_secondary), label);
    return clicked;
}

/// The frames, as cards in as many columns of at least 150 pixels as fit. A click chooses or
/// leaves a frame; a shift-click every frame from the one clicked before.
fn drawGrid(state: *State, ctx: context.Context, roll_index: usize) void {
    const r = &ctx.library.rolls.items[roll_index];
    const total = r.frames.items.len;
    const list = c.ImGui_GetWindowDrawList();
    const origin = c.ImGui_GetCursorScreenPos();
    if (total == 0) {
        c.ImDrawList_AddText(list, origin, theme.imU32(theme.text_tertiary), "No frames in this roll yet: scan into it, or drop scans on it in Rolls.");
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
            c.ImGui_SetTooltip("%s", gui.print("Frame {d} · {s}", .{ i + 1, if (!frame.developed) "not developed: exports with automatic settings" else frame.look.label() }).ptr);
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
        const radius = gui.px(5);
        if (on) c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.control), radius, 0);
        c.ImDrawList_AddRectEx(list, corner, far, theme.imU32(if (on) theme.accent else if (hovered) theme.border else theme.divider), radius, 1, 0);
        const picture_min = gui.vec2(corner.x + inset, corner.y + inset);
        const picture_max = gui.vec2(far.x - inset, picture_min.y + picture_height);
        if (ctx.library.thumbnail(ctx.gpa, .{ .roll = roll_index, .frame = i })) |t| {
            gui.imageCover(list, t.ref(), t.width, t.height, picture_min, picture_max, gui.px(2));
        } else {
            c.ImDrawList_AddRectFilledEx(list, picture_min, picture_max, theme.imU32(theme.control_hover), gui.px(2), 0);
        }

        // The number and the check box under the picture.
        const label_top = picture_max.y + gui.px(cell_padding);
        fonts.pushSized(.mono, 12);
        c.ImDrawList_AddText(list, gui.vec2(picture_min.x + gui.px(2), label_top + (gui.px(small_line) - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_secondary), gui.print("{d:0>2}", .{i + 1}));
        fonts.pop();
        const box_min = gui.vec2(picture_max.x - gui.px(2 + check_size), label_top + (gui.px(small_line) - gui.px(check_size)) / 2);
        drawCheck(list, box_min, gui.px(check_size), on);

        // Frames left out are dimmed: the page's colour over them, as the design's opacity.
        if (!on) c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.withAlpha(theme.page, 0.45)), radius, 0);
    }
    const rows = (total + columns - 1) / columns;
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, origin.y + @as(f32, @floatFromInt(rows)) * (cell_height + gap) - gap));
    c.ImGui_Dummy(gui.vec2(0, 0));
}

/// A check box `size` pixels square at `min`: amber with a tick when `on`, an outline when not.
fn drawCheck(list: *c.ImDrawList, min: gui.Vec2, size: f32, on: bool) void {
    if (on) return gui.tickedBox(list, min, size);
    c.ImDrawList_AddRectEx(list, min, gui.vec2(min.x + size, min.y + size), theme.imU32(theme.track), gui.px(3), 1, 0);
}

/// The bottom of the page: the export under way with its progress and Cancel, or what the last
/// one wrote, with Show in folder.
fn drawSection(state: *State, min: gui.Vec2, max: gui.Vec2) void {
    const list = c.ImGui_GetWindowDrawList();
    c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(theme.panel), gui.px(6), 0);
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
            gui.print("Cancelling after frame {d}…", .{job.number})
        else
            gui.print("Exporting {d} of {d}: {s}.{s}, {s}", .{ current + 1, batch.jobs.len, job.stem, batch.options.format.extension(), batch.stage.load(.acquire).label() });
        if (!cancelling and link(gui.vec2(right, first_top), "Cancel")) batch.cancel.store(true, .release);
        shortcuts.tooltip("Stops after the frame under way", .cancel);
        c.ImDrawList_AddText(list, gui.vec2(x, first_y), theme.imU32(theme.text), gui.elideEnd(status, right - x - gui.px(80)));
        // The progress bar, in the second line.
        const bar_y = second_top + (gui.px(small_line) - gui.px(4)) / 2;
        c.ImDrawList_AddRectFilledEx(list, gui.vec2(x, bar_y), gui.vec2(right, bar_y + gui.px(4)), theme.imU32(theme.border), gui.px(2), 0);
        const done = (right - x) * std.math.clamp(batch.progress(), 0, 1);
        if (done > 0) c.ImDrawList_AddRectFilledEx(list, gui.vec2(x, bar_y), gui.vec2(x + done, bar_y + gui.px(4)), theme.imU32(theme.accent), gui.px(2), 0);
        return;
    }

    const summary = if (state.last) |*s| s else {
        c.ImDrawList_AddText(list, gui.vec2(x, first_y), theme.imU32(theme.text_secondary), "Nothing exported yet. Choose the frames, then Export.");
        fonts.pushSized(.mono, 12);
        c.ImDrawList_AddText(list, gui.vec2(x, second_top + (gui.px(small_line) - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_tertiary), gui.elideStart(std.mem.sliceTo(&state.folder, 0), right - x));
        fonts.pop();
        return;
    };
    if (link(gui.vec2(right, first_top), "Show in folder")) showFolder(summary.folder.text());
    c.ImDrawList_AddText(list, gui.vec2(x, first_y), theme.imU32(theme.text), gui.elideEnd(summary.line.text(), right - x - gui.px(120)));
    fonts.pushSized(.mono, 12);
    c.ImDrawList_AddText(list, gui.vec2(x, second_top + (gui.px(small_line) - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_tertiary), gui.elideStart(summary.files.text(), right - x));
    fonts.pop();
}

/// An underlined link whose text ends at `top_right`, as the design's links. True when clicked.
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
    const underline = y + size.y + gui.px(1);
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
    url.append(std.heap.page_allocator, 0) catch return;
    if (!c.SDL_OpenURL(url.items[0 .. url.items.len - 1 :0])) std.log.err("can't open {s}: {s}", .{ folder, c.SDL_GetError() });
}

// The settings panel ----------------------------------------------------------------------------

fn drawSettings(state: *State, ctx: context.Context, roll_index: usize) void {
    const r = &ctx.library.rolls.items[roll_index];
    const list = c.ImGui_GetWindowDrawList();
    const window = c.ImGui_GetWindowPos();
    const height = c.ImGui_GetWindowHeight();
    // The panel's top-left, moved with its scrolling.
    const origin = gui.vec2(window.x, window.y - c.ImGui_GetScrollY());
    const x = origin.x + gui.px(panel_padding);
    const width = gui.px(settings_width - 2 * panel_padding);
    var y = origin.y + gui.px(panel_padding);
    const running = state.running != null;

    // FILE.
    heading(list, gui.vec2(x, y), "FILE");
    y += gui.px(small_line + block_gap);
    y = drawFileChoices(state, x, y, width);
    y += gui.px(block_gap);
    y += wrapped(list, gui.vec2(x, y), width, theme.text_tertiary, formatNote(state));
    y += gui.px(block_gap);

    c.ImGui_BeginDisabled(running);
    y = drawFileGrid(state, ctx, x, y, width);
    c.ImGui_EndDisabled();

    // METADATA.
    y += gui.px(block_gap + 6);
    heading(list, gui.vec2(x, y), "METADATA");
    y += gui.px(small_line + block_gap);
    y = drawMetadata(state, r.info, x, y, width);
    y += gui.px(block_gap);
    y += wrapped(list, gui.vec2(x, y), width, theme.text_tertiary, "Written as EXIF and XMP, and as an XMP file beside each image.");

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
        const why: ?[]const u8 = if (running) "An export is under way." else if (count == 0) "Choose some frames first." else if (!pattern_ok) "The file names' pattern needs fixing." else if (!folder_ok) "Choose a folder first." else null;
        if (why) |text| c.ImGui_SetTooltip("%s", gui.print("{s}", .{text}).ptr);
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(x, button_y + gui.px(export_height + panel_padding)));
    c.ImGui_Dummy(gui.vec2(0, 0));
}

/// A section heading at `at`, in the 12-pixel line the design gives it.
fn heading(list: *c.ImDrawList, at: gui.Vec2, label: [:0]const u8) void {
    fonts.pushSized(.semibold, 12);
    c.ImDrawList_AddText(list, gui.vec2(at.x, at.y + (gui.px(small_line) - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_secondary), label);
    fonts.pop();
}

/// `text` from `at`, wrapped at `width` in the design's lines. Returns its height.
fn wrapped(list: *c.ImDrawList, at: gui.Vec2, width: f32, colour: theme.Color, text: []const u8) f32 {
    var y = at.y;
    var rest = std.mem.trim(u8, text, " ");
    const offset = (gui.px(line) - c.ImGui_GetFontSize()) / 2;
    while (rest.len > 0) {
        // The longest run of whole words that fits; a word longer than the line goes alone.
        var end: usize = rest.len;
        if (c.ImGui_CalcTextSize(gui.print("{s}", .{rest})).x > width) {
            var fits: usize = 0;
            var i: usize = 0;
            while (std.mem.indexOfScalarPos(u8, rest, i, ' ')) |space| : (i = space + 1) {
                if (c.ImGui_CalcTextSize(gui.print("{s}", .{rest[0..space]})).x > width) break;
                fits = space;
            }
            end = if (fits > 0) fits else std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        }
        c.ImDrawList_AddText(list, gui.vec2(at.x, y + offset), theme.imU32(colour), gui.print("{s}", .{rest[0..end]}));
        y += gui.px(line);
        rest = std.mem.trimStart(u8, rest[end..], " ");
    }
    return y - at.y;
}

/// TIFF 16-bit, TIFF 8-bit, JPEG and HEIC HDR, as pills that wrap. Returns the y under them.
fn drawFileChoices(state: *State, x: f32, top: f32, width: f32) f32 {
    var at = gui.vec2(x, top);
    const height = gui.px(pill_height);
    c.ImGui_BeginDisabled(state.running != null);
    defer c.ImGui_EndDisabled();
    for (std.enums.values(FileChoice)) |choice| {
        const label = choice.label();
        const pill_width = c.ImGui_CalcTextSize(label).x + gui.px(10 * 2 + 2);
        if (at.x > x and at.x + pill_width > x + width) {
            at = gui.vec2(x, at.y + height + gui.px(pill_gap));
        }
        c.ImGui_SetCursorScreenPos(at);
        if (choice == .heic) {
            drawUnavailable(label, gui.vec2(pill_width, height));
            if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) c.ImGui_SetTooltip("HDR with a gain map. Not available yet: the codecs don't write HEIC.");
        } else {
            if (gui.buttonOf(if (state.file == choice) .selected else .unselected, label, gui.vec2(pill_width / gui.scale, pill_height))) state.file = choice;
        }
        at.x += pill_width + gui.px(pill_gap);
    }
    return at.y + height;
}

/// A choice that can't be made: no fill, a dashed border, tertiary text.
fn drawUnavailable(label: [:0]const u8, size: gui.Vec2) void {
    const corner = c.ImGui_GetCursorScreenPos();
    _ = c.ImGui_InvisibleButton(label, size, 0);
    const list = c.ImGui_GetWindowDrawList();
    const far = gui.vec2(corner.x + size.x, corner.y + size.y);
    gui.dashedRoundedRect(list, corner, far, theme.imU32(theme.border), gui.px(4));
    const text_size = c.ImGui_CalcTextSize(label);
    c.ImDrawList_AddText(list, gui.vec2(corner.x + (size.x - text_size.x) / 2, corner.y + (size.y - text_size.y) / 2), theme.imU32(theme.text_tertiary), label);
}

/// What the chosen file is, and what to know about it with these frames.
fn formatNote(state: *const State) []const u8 {
    const options = state.options();
    const base = switch (state.file) {
        .tiff16 => "16-bit, ZIP compressed, ICC profile embedded.",
        .tiff8 => "8-bit, ZIP compressed, ICC profile embedded.",
        .jpeg => gui.print("8-bit, quality {d}, ICC profile embedded.", .{options.quality}),
        .heic => "HDR with a gain map. Not available yet.",
    };
    const banding = if (options.space == .prophoto and options.bits() == .eight) " ProPhoto RGB is wide for 8 bits: smooth skies may band." else "";
    return gui.print("{s}{s}", .{ base, banding });
}

/// Colour space, size, file names and folder, as the design's grid of rows: a label column, then
/// the control. JPEG adds its quality first. Returns the y under the last row.
fn drawFileGrid(state: *State, ctx: context.Context, x: f32, top: f32, width: f32) f32 {
    const list = c.ImGui_GetWindowDrawList();
    const control_x = x + gui.px(label_width + grid_gap);
    const control_width = width - gui.px(label_width + grid_gap);
    const row = gui.px(control_height);
    var y = top;

    if (state.file == .jpeg) {
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
    }

    rowLabel(list, x, y, "Color space");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(8), (row - c.ImGui_GetFontSize()) / 2));
    if (gui.combo("space", &space_names, state.space, control_width / gui.scale)) |picked| state.space = picked;
    y += row + gui.px(grid_gap);

    rowLabel(list, x, y, "Size");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y));
    if (gui.combo("size", &size_names, state.size, control_width / gui.scale)) |picked| state.size = picked;
    c.ImGui_PopStyleVar();
    y += row + gui.px(grid_gap);

    rowLabel(list, x, y, "File names");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y));
    fonts.pushSized(.mono, 12);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(10), (row - c.ImGui_GetFontSize()) / 2));
    _ = gui.textField("names", &state.pattern, default_pattern, control_width / gui.scale);
    c.ImGui_PopStyleVar();
    fonts.pop();
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) {
        c.ImGui_SetTooltip("{roll} the roll's name for a file, {name} as it is, {frame} the frame's number\n({frame:02} with two digits), {stock} the film, {date} when it was shot");
    }
    y += row;
    if (exporting.checkPattern(std.mem.sliceTo(&state.pattern, 0))) |_| {} else |err| {
        y += gui.px(4);
        const problem = switch (err) {
            error.NoFrameNumber => "Add {frame}: without it every frame writes the same file.",
            error.UnknownField => "Unknown field in braces. Hover for the ones there are.",
            error.UnclosedBrace => "A brace is opened and not closed.",
        };
        y += wrapped(list, gui.vec2(control_x, y), control_width, theme.accent, problem);
        y -= gui.px(line) - c.ImGui_GetFontSize();
    }
    y += gui.px(grid_gap);

    rowLabel(list, x, y, "Folder");
    const choose_width = c.ImGui_CalcTextSize("Choose").x + gui.px(10 * 2 + 2);
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x, y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(10), (row - c.ImGui_GetFontSize()) / 2));
    _ = gui.textField("folder", &state.folder, "Roll/exports", (control_width - choose_width - gui.px(6)) / gui.scale);
    c.ImGui_PopStyleVar();
    if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) c.ImGui_SetTooltip("From the library's folder, or a whole path");
    c.ImGui_SetCursorScreenPos(gui.vec2(control_x + control_width - choose_width, y));
    c.ImGui_BeginDisabled(state.dialog.isShowing());
    if (gui.buttonOf(.normal, "Choose", gui.vec2(choose_width / gui.scale, control_height))) chooseFolder(state, ctx);
    c.ImGui_EndDisabled();
    y += row;
    return y;
}

/// A grid row's label, in the middle of the row's height.
fn rowLabel(list: *c.ImDrawList, x: f32, y: f32, label: [:0]const u8) void {
    c.ImDrawList_AddText(list, gui.vec2(x, y + (gui.px(control_height) - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_secondary), label);
}

/// Opens the system's folder dialog, at the folder chosen now.
fn chooseFolder(state: *State, ctx: context.Context) void {
    const folder = resolvedFolder(ctx.gpa, ctx.library, std.mem.sliceTo(&state.folder, 0)) catch return;
    defer ctx.gpa.free(folder);
    // Where it starts: the folder when it's there, else the library.
    std.Io.Dir.cwd().access(ctx.io, folder, .{}) catch {
        state.dialog.showAt(ctx.gpa, ctx.io, gui.print("{s}", .{ctx.library.path}));
        return;
    };
    state.dialog.showAt(ctx.gpa, ctx.io, gui.print("{s}", .{folder}));
}

/// The roll's details to include, each with what it holds. Returns the y under them.
fn drawMetadata(state: *State, info: roll.Info, x: f32, top: f32, width: f32) f32 {
    const list = c.ImGui_GetWindowDrawList();
    const unset = "Not set";
    const Row = struct { label: [:0]const u8, flag: *bool, value: ?[]const u8, quiet: bool = false };
    const rows = [_]Row{
        .{ .label = "Camera", .flag = &state.include.camera, .value = info.camera },
        .{ .label = "Lens", .flag = &state.include.lens, .value = info.lens },
        .{ .label = "Film stock", .flag = &state.include.stock, .value = info.stock },
        .{ .label = "Date shot", .flag = &state.include.shot, .value = info.shot },
        .{ .label = "Copyright", .flag = &state.include.copyright, .value = info.copyright },
        .{ .label = "Settings", .flag = &state.include.settings, .value = "Look, base, scanner", .quiet = true },
    };
    const value_x = x + gui.px(22 + 6 + 100 + 6);
    var y = top;
    for (rows) |row| {
        c.ImGui_SetCursorScreenPos(gui.vec2(x, y));
        if (c.ImGui_InvisibleButton(row.label, gui.vec2(gui.px(22 + 6 + 100), gui.px(metadata_row)), 0)) row.flag.* = !row.flag.*;
        const hovered = c.ImGui_IsItemHovered(0);
        const box = gui.vec2(x + gui.px(4), y + gui.px((metadata_row - metadata_check) / 2.0));
        if (row.flag.*) {
            drawCheck(list, box, gui.px(metadata_check), true);
        } else {
            const far = gui.vec2(box.x + gui.px(metadata_check), box.y + gui.px(metadata_check));
            c.ImDrawList_AddRectFilledEx(list, box, far, theme.imU32(if (hovered) theme.control_hover else theme.control), gui.px(3), 0);
            c.ImDrawList_AddRectEx(list, box, far, theme.imU32(theme.track), gui.px(3), 1, 0);
        }
        const text_y = y + (gui.px(metadata_row) - c.ImGui_GetFontSize()) / 2;
        c.ImDrawList_AddText(list, gui.vec2(x + gui.px(22 + 6), text_y), theme.imU32(if (hovered) theme.text else theme.text_secondary), row.label);
        const value = row.value orelse unset;
        const quiet = row.quiet or row.value == null;
        c.ImDrawList_AddText(list, gui.vec2(value_x, text_y), theme.imU32(if (quiet) theme.text_tertiary else theme.text), gui.elideEnd(value, x + width - value_x));
        y += gui.px(metadata_row + metadata_gap);
    }
    return y - gui.px(metadata_gap);
}

/// Starts exporting the chosen frames of `r` on a thread of their own.
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
        ctx.notice.set("Can't export: {t}.", .{err});
        return;
    };
    const future = ctx.io.concurrent(exporting.Batch.run, .{ batch, ctx.gpa, ctx.io }) catch |err| {
        batch.destroy(ctx.gpa);
        ctx.notice.set("Can't start the export: {t}.", .{err});
        return;
    };
    var running: Running = .{ .batch = batch, .future = future };
    running.what.set("{s}, {s}", .{ state.file.label(), space_names[state.space] });
    state.running = running;
}
