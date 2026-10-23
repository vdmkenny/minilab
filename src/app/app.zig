//! The app: its window, the workspaces in the header, and the one loop that draws them.

const std = @import("std");
const minilab = @import("minilab");
const c = @import("c");
const Window = @import("../platform/window.zig").Window;
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const develop_view = @import("develop_view.zig");
const rolls_view = @import("rolls_view.zig");
const Library = @import("library.zig").Library;
const labels = @import("labels.zig");
const shortcuts = @import("shortcuts.zig");
const context = @import("context.zig");
const scan_view = @import("scan_view.zig");
const export_view = @import("export_view.zig");
const looks_view = @import("looks_view.zig");
const version = @import("../version.zig");

pub const Workspace = context.Workspace;

pub const Options = struct {
    /// The folder of rolls.
    library: []const u8,
    /// The user's home folder, which the interface shows as ~.
    home: ?[]const u8 = null,
    /// Scans to open at start, outside any roll.
    open: []const []const u8 = &.{},
    /// The name of a roll in the library to open at start.
    roll: ?[]const u8 = null,
    /// Draw without showing a window until everything has loaded, then save the screen here.
    screenshot: ?[:0]const u8 = null,
    workspace: Workspace = .rolls,
    /// Show the keyboard shortcuts at start.
    shortcuts: bool = false,
};

/// Which panels are showing. Tab hides the side panels, and Shift-Tab hides everything but the
/// viewer.
const Panels = enum { all, viewer_and_header, viewer };

/// The window size at start, in the design's pixels.
const start_width = 1440;
const start_height = 900;
/// The fewest frames to draw before a screenshot, so the layout settles, and the most, in case
/// something never finishes loading.
const screenshot_frames = 4;
const screenshot_frames_max = 600;
const header_height = 44;
/// How often the app looks for rolls and frames added on disk from outside it.
const library_check_ms = 2000;

const Notice = context.Notice;

pub fn run(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    var window: Window = try .open("minilab", start_width, start_height, null, options.screenshot != null);
    defer window.close();
    gui.scale = window.scale;
    fonts.load(window.scale);
    theme.apply(window.scale);

    var library: Library = try .load(gpa, io, options.library, options.home);
    defer library.deinit(gpa, window.gpu);
    var rolls: rolls_view.State = .{};
    defer rolls.deinit(gpa);
    var scan: scan_view.State = .{};
    defer scan.deinit(gpa, window.gpu);
    var exporting: export_view.State = .{};
    defer exporting.deinit(gpa, window.gpu);
    var looks: looks_view.State = .{};
    defer looks.deinit(gpa, window.gpu);
    var develop: develop_view.State = .{};
    defer develop.deinit(gpa, window.gpu);
    defer develop.save(io, &library);
    var notice: Notice = .{};
    var workspace = options.workspace;

    if (options.roll) |name| {
        for (library.rolls.items) |r| {
            if (!std.mem.eql(u8, r.info.name, name)) continue;
            try develop.openRoll(gpa, io, &library, r.path);
            break;
        } else std.log.err("no roll named {s} in {s}", .{ name, library.path });
    }
    for (options.open) |path| try develop.openLoose(gpa, io, &library, path);

    var frames_drawn: usize = 0;
    var library_checked: u64 = 0;
    var panels: Panels = .all;
    var show_help = options.shortcuts;
    while (!window.close_asked) {
        if (!window.beginFrame()) continue;
        // Pick up rolls and frames added on disk from outside the app.
        if (c.SDL_GetTicks() -% library_checked >= library_check_ms) {
            library_checked = c.SDL_GetTicks();
            _ = library.refresh(gpa, io);
        }
        gui.newFrame();
        const keys = shortcuts.poll();
        for (std.enums.values(Workspace)) |w| {
            if (keys.contains(w.command())) workspace = w;
        }
        if (keys.contains(.import)) workspace = .scan;
        if (keys.contains(.help)) show_help = !show_help;
        if (keys.contains(.quit)) window.close_asked = true;
        if (keys.contains(.full_screen)) window.toggleFullScreen();
        if (keys.contains(.hide_panels)) panels = if (panels == .all) .viewer_and_header else .all;
        if (keys.contains(.hide_all)) panels = if (panels == .viewer) .all else .viewer;
        if (keys.contains(.new_roll)) {
            workspace = .rolls;
            rolls.show_form = true;
            rolls.form = .{};
        }
        if (keys.contains(.find)) {
            workspace = .rolls;
            rolls.focus_search = true;
        }
        if (keys.contains(.cancel) and workspace == .rolls) rolls.show_form = false;
        if (workspace == .develop) {
            if (develop.handle(gpa, io, &library, keys)) |message| notice.set("{s}", .{message});
        }
        // Scanned frames go into their roll whichever workspace is showing, and the header picks
        // up the scanner's state. A screenshot run leaves the scanners alone unless it's showing
        // Scan.
        if (options.screenshot == null or workspace == .scan) {
            scan_view.update(&scan, .{ .gpa = gpa, .io = io, .gpu = window.gpu, .library = &library, .develop = &develop, .keys = keys, .notice = &notice });
        }
        const dropped = window.dropped.files();
        const drop: ?gui.Vec2 = if (dropped.len > 0) gui.vec2(window.dropped.position[0], window.dropped.position[1]) else null;
        if (dropped.len > 0 and workspace == .looks) {
            // Reference images for the look being fitted.
            looks.addFiles(.{ .gpa = gpa, .io = io, .gpu = window.gpu, .library = &library, .develop = &develop, .keys = keys, .notice = &notice }, dropped);
        } else if (dropped.len > 0 and workspace != .rolls) {
            dropScans(gpa, io, &library, &develop, dropped, &notice);
            workspace = .develop;
        }

        const viewport = c.ImGui_GetMainViewport();
        c.ImGui_SetNextWindowPos(viewport.*.WorkPos, 0);
        c.ImGui_SetNextWindowSize(viewport.*.WorkSize, 0);
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(0, 0));
        _ = c.ImGui_Begin("minilab", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoBringToFrontOnFocus);
        c.ImGui_PopStyleVar();
        if (panels != .viewer) drawHeader(&workspace, &notice, &library, &develop, scan_view.status(&scan));
        // When an export finishes, the user hears about it whichever workspace they're in.
        exporting.poll(.{ .gpa = gpa, .io = io, .gpu = window.gpu, .library = &library, .develop = &develop, .keys = keys, .notice = &notice });
        // Each workspace gets its own ID space. Develop and Export both have "settings" panels,
        // which would otherwise be the same child window, sharing one scroll position.
        c.ImGui_PushIDInt(@intCast(@backingInt(workspace)));
        switch (workspace) {
            .rolls => switch (rolls_view.draw(&rolls, &library, gpa, io, drop)) {
                .none => if (drop != null) notice.set("Drop scans on a roll's row", .{}),
                .open => |at| {
                    try develop.openRoll(gpa, io, &library, library.rolls.items[at.roll].path);
                    if (at.frame < library.rolls.items[at.roll].frames.items.len) develop.select(gpa, io, &library, at.frame);
                    workspace = .develop;
                },
                .created => |index| {
                    try develop.openRoll(gpa, io, &library, library.rolls.items[index].path);
                    workspace = if (library.rolls.items[index].info.input == .scanner) .scan else .develop;
                },
                .dropped_on => |index| {
                    try develop.openRoll(gpa, io, &library, library.rolls.items[index].path);
                    dropScans(gpa, io, &library, &develop, dropped, &notice);
                },
                .trash => |index| {
                    var name_buffer: [256]u8 = undefined;
                    const name = std.fmt.bufPrint(&name_buffer, "{s}", .{library.rolls.items[index].info.name}) catch library.rolls.items[index].info.name;
                    develop.forgetRoll(gpa, library.rolls.items[index].path);
                    if (library.trashRoll(gpa, io, index)) |_| {
                        notice.set("Moved {s} to Trash", .{name});
                    } else |err| notice.set("Can't move {s} to Trash · {t}", .{ name, err });
                },
            },
            .develop => develop_view.draw(&develop, gpa, io, &library, window.gpu, panels == .all),
            .scan, .@"export", .looks => {
                const ctx: context.Context = .{ .gpa = gpa, .io = io, .gpu = window.gpu, .library = &library, .develop = &develop, .keys = keys, .notice = &notice };
                const next = switch (workspace) {
                    .scan => scan_view.draw(&scan, ctx),
                    .@"export" => export_view.draw(&exporting, ctx),
                    .looks => looks_view.draw(&looks, ctx),
                    else => unreachable,
                };
                if (next) |w| workspace = w;
            },
        }
        c.ImGui_PopID();
        c.ImGui_End();
        if (show_help) show_help = shortcuts.drawHelp();

        // If any thumbnail was asked for while drawing and isn't made yet, this frame was missing
        // it.
        const complete = library.wanted.items.len == 0;
        // Make one thumbnail per frame, so the window stays responsive in the meantime.
        library.work(gpa, io, window.gpu);
        if (library.wanted.items.len > 0 or notice.text() != null) window.keepBusy();
        if (workspace == .looks and looks.rendering()) window.keepBusy();

        frames_drawn += 1;
        if (options.screenshot) |path| {
            const loaded = complete and switch (workspace) {
                .develop => develop.settled(),
                .scan => scan.settled(),
                .@"export" => exporting.settled(),
                .looks => looks.settled(),
                .rolls => true,
            };
            if ((frames_drawn >= screenshot_frames and loaded) or frames_drawn == screenshot_frames_max) {
                try window.capture(.{ theme.page.x, theme.page.y, theme.page.z, 1 }, path);
                return;
            }
            c.ImGui_Render();
            library.releaseRetired(window.gpu);
            continue;
        }
        window.endFrame(.{ theme.page.x, theme.page.y, theme.page.z, 1 });
        library.releaseRetired(window.gpu);
    }
}

/// Handles scans dropped on the window: adds them to the open roll, or opens them outside any roll
/// when none is open.
fn dropScans(gpa: std.mem.Allocator, io: std.Io, library: *Library, develop: *develop_view.State, dropped: []const []const u8, notice: *Notice) void {
    // A folder stands for the scans in it.
    const paths = minilab.input.expand(gpa, io, dropped) catch |err| {
        notice.set("Can't read what was dropped · {t}", .{err});
        return;
    };
    defer minilab.input.freeExpanded(gpa, paths);
    if (develop.rollIndex(library)) |r| {
        const imported = library.importScans(gpa, io, r, paths);
        const added = library.rolls.items[r].frames.items.len - imported.first;
        const name = library.rolls.items[r].info.name;
        if (added == imported.files) {
            notice.set("Added {d} of {d} scans to {s}", .{ added, paths.len, name });
        } else {
            notice.set("Added {d} frames from {d} of {d} scans to {s}", .{ added, imported.files, paths.len, name });
        }
        if (added > 0) develop.select(gpa, io, library, imported.first);
        return;
    }
    for (paths) |path| develop.openLoose(gpa, io, library, path) catch |err| std.log.err("can't open {s}: {t}", .{ path, err });
}

fn drawHeader(workspace: *Workspace, notice: *const Notice, library: *const Library, develop: *const develop_view.State, scanner: @TypeOf(scan_view.status(undefined))) void {
    const origin = c.ImGui_GetCursorScreenPos();
    const width = c.ImGui_GetContentRegionAvail().x;
    const height = gui.px(header_height);
    const list = c.ImGui_GetWindowDrawList();
    c.ImDrawList_AddRectFilled(list, origin, gui.vec2(origin.x + width, origin.y + height), theme.imU32(theme.header));
    c.ImDrawList_AddLine(list, gui.vec2(origin.x, origin.y + height - 1), gui.vec2(origin.x + width, origin.y + height - 1), theme.imU32(theme.divider));
    const middle = origin.y + height / 2;

    // The mark: a frame of film with its perforations, then the name.
    drawMark(list, gui.vec2(origin.x + gui.px(16), middle - gui.px(10)));
    fonts.pushSized(.semibold, 14);
    const name_size = c.ImGui_CalcTextSize("minilab");
    c.ImDrawList_AddText(list, gui.vec2(origin.x + gui.px(16 + 20 + 8), middle - name_size.y / 2), theme.imU32(theme.text), "minilab");
    fonts.pop();
    // The version, small, beside the name.
    fonts.pushSized(.mono, 10);
    const version_text = gui.print("{s}", .{version.string});
    const version_size = c.ImGui_CalcTextSize(version_text);
    const version_x = origin.x + gui.px(16 + 20 + 8 + 6) + name_size.x;
    c.ImDrawList_AddText(list, gui.vec2(version_x, middle - version_size.y / 2 + gui.px(1)), theme.imU32(theme.text_tertiary), version_text);
    fonts.pop();

    // The workspaces, as tabs.
    var x = version_x + version_size.x + gui.px(20);
    const tab_height = c.ImGui_GetTextLineHeight() * 1.4 + gui.px(16);
    for (std.enums.values(Workspace)) |w| {
        const label = w.label();
        const tab_width = c.ImGui_CalcTextSize(label).x + gui.px(24);
        const corner = gui.vec2(x, middle - tab_height / 2);
        c.ImGui_SetCursorScreenPos(corner);
        if (c.ImGui_InvisibleButton(label, gui.vec2(tab_width, tab_height), 0)) workspace.* = w;
        shortcuts.tooltip(label, w.command());
        const hovered = c.ImGui_IsItemHovered(0);
        const current = workspace.* == w;
        const far = gui.vec2(corner.x + tab_width, corner.y + tab_height);
        if (current) {
            c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.control), gui.px(4), 0);
            c.ImDrawList_AddRectFilledEx(list, gui.vec2(corner.x, far.y - gui.px(2)), far, theme.imU32(theme.accent), gui.px(4), c.ImDrawFlags_RoundCornersBottom);
        }
        const size = c.ImGui_CalcTextSize(label);
        c.ImDrawList_AddText(list, gui.vec2(corner.x + (tab_width - size.x) / 2, middle - size.y / 2), theme.imU32(if (current or hovered) theme.text else theme.text_secondary), label);
        x += tab_width + gui.px(2);
    }

    // On the right: what just happened, the open roll, and the scanner.
    var right = origin.x + width - gui.px(16);
    const scanner_text = gui.print("{s}", .{scanner.text});
    const scanner_size = c.ImGui_CalcTextSize(scanner_text);
    right -= scanner_size.x;
    c.ImDrawList_AddText(list, gui.vec2(right, middle - scanner_size.y / 2), theme.imU32(theme.text_secondary), scanner_text);
    c.ImDrawList_AddCircleFilled(list, gui.vec2(right - gui.px(6 + 4), middle), gui.px(4), theme.imU32(if (scanner.ready) theme.ready else theme.text_tertiary), 12);
    right -= gui.px(6 + 8 + 16);
    if (workspace.* != .rolls) {
        if (develop.rollIndex(library)) |r| {
            const info = library.rolls.items[r].info;
            const film = info.format.format().size;
            const roll_text = gui.print("{s} · {s} · {s}", .{ info.name, info.stock orelse labels.filmKind(info.kind), labels.filmSize(film) });
            const size = c.ImGui_CalcTextSize(roll_text);
            right -= size.x;
            c.ImDrawList_AddText(list, gui.vec2(right, middle - size.y / 2), theme.imU32(theme.text_secondary), roll_text);
            right -= gui.px(16);
        }
    }
    if (notice.text()) |message| {
        const shown = gui.elideStart(message, @max(0, right - x - gui.px(16)));
        const size = c.ImGui_CalcTextSize(shown);
        c.ImDrawList_AddText(list, gui.vec2(right - size.x, middle - size.y / 2), theme.imU32(theme.accent), shown);
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, origin.y + height));
}

/// Draws the app's mark, 20 pixels square, at `corner`: a frame of film with perforations above
/// and below.
fn drawMark(list: *c.ImDrawList, corner: gui.Vec2) void {
    const ink = theme.imU32(theme.accent);
    const thickness = gui.px(1.5);
    const p = struct {
        fn at(o: gui.Vec2, x: f32, y: f32) gui.Vec2 {
            return gui.vec2(o.x + gui.px(x), o.y + gui.px(y));
        }
    }.at;
    c.ImDrawList_AddRectEx(list, p(corner, 2, 4), p(corner, 18, 16), ink, gui.px(1.5), thickness, 0);
    c.ImDrawList_AddLineEx(list, p(corner, 2, 7), p(corner, 18, 7), ink, thickness);
    c.ImDrawList_AddLineEx(list, p(corner, 2, 13), p(corner, 18, 13), ink, thickness);
    for ([_]f32{ 5, 9, 13 }) |x| {
        c.ImDrawList_AddLineEx(list, p(corner, x, 4), p(corner, x, 7), ink, thickness);
        c.ImDrawList_AddLineEx(list, p(corner, x, 13), p(corner, x, 16), ink, thickness);
    }
}
