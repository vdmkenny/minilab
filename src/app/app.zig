//! The app: its window, the workspaces in the header, and the one loop that draws them.

const std = @import("std");
const minilab = @import("minilab");
const c = @import("c");
const Window = @import("../platform/window.zig").Window;
const Dropped = @import("../platform/window.zig").Dropped;
const icon = @import("../platform/icon.zig");
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
/// How many frames in a row the page has to have loaded before a screenshot. A window that has
/// just opened, like a confirmation, is only measured on its first frame and drawn on the next.
const screenshot_loaded_frames = 2;
/// The header's layout, in the design's pixels.
const header = struct {
    const height = 44;
    /// The space at each end, and between the things on the right.
    const padding = 16;
    const mark_size = 20;
    const mark_gap = 8;
    const version_gap = 6;
    /// The version is moved down this much to sit on the name's baseline.
    const version_drop = 1;
    const tabs_gap = 20;
    const tab_padding_x = 12;
    const tab_padding_y = 8;
    const tab_gap = 2;
    const tab_rounding = 4;
    /// The amber line under the current tab.
    const tab_underline = 2;
    /// The dot that shows whether the scanner is ready.
    const dot_radius = 4;
    const dot_gap = 6;
    const dot_segments = 12;
};
/// How often the app looks for rolls and frames added on disk from outside it.
const library_check_ms = 2000;

const Notice = context.Notice;

pub fn run(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    var window: Window = try .open("minilab", start_width, start_height, options.screenshot != null);
    defer window.close();
    gui.scale = window.scale;
    fonts.load(window.scale);
    theme.apply(window.scale);

    var app: App = .{
        .library = try .load(gpa, io, options.library, options.home),
        .workspace = options.workspace,
        .show_help = options.shortcuts,
    };
    defer app.deinit(gpa, io, window.gpu);
    try app.openAtStart(gpa, io, options);

    var frames_drawn: usize = 0;
    var loaded_frames: usize = 0;
    var library_checked: u64 = 0;
    while (!window.close_asked) {
        if (!window.beginFrame()) continue;
        // Pick up rolls and frames added on disk from outside the app.
        if (c.SDL_GetTicks() -% library_checked >= library_check_ms) {
            library_checked = c.SDL_GetTicks();
            app.library.refresh(gpa, io);
        }
        gui.newFrame();
        const keys = shortcuts.poll();
        const ctx: context.Context = .{ .gpa = gpa, .io = io, .gpu = window.gpu, .library = &app.library, .develop = &app.develop, .keys = keys, .notice = &app.notice };
        app.handleKeys(ctx, &window);
        // Scanned frames go into their roll whichever workspace is showing, and the header picks
        // up the scanner's state. A screenshot run leaves the scanners alone unless it's showing
        // Scan.
        if (options.screenshot == null or app.workspace == .scan) scan_view.update(&app.scan, ctx);
        try app.draw(ctx, &window.dropped);
        if (app.show_help) app.show_help = shortcuts.drawHelp();

        // If any thumbnail was asked for while drawing and isn't made yet, this frame was missing
        // it.
        const complete = app.library.wanted.items.len == 0;
        // Make one thumbnail per frame, so the window stays responsive in the meantime.
        app.library.work(gpa, io, window.gpu);
        if (app.library.wanted.items.len > 0 or app.notice.text() != null) window.keepBusy();
        if (app.workspace == .looks and app.looks.rendering()) window.keepBusy();

        frames_drawn += 1;
        const background: [4]f32 = .{ theme.page.x, theme.page.y, theme.page.z, 1 };
        if (options.screenshot) |path| {
            loaded_frames = if (complete and app.settled()) loaded_frames + 1 else 0;
            if ((frames_drawn >= screenshot_frames and loaded_frames >= screenshot_loaded_frames) or frames_drawn == screenshot_frames_max) {
                try window.capture(background, path);
                return;
            }
            c.ImGui_Render();
            app.library.releaseRetired(window.gpu);
            continue;
        }
        window.endFrame(background);
        app.library.releaseRetired(window.gpu);
    }
}

/// What the app keeps from frame to frame: the library, each workspace's state, and what's
/// showing.
const App = struct {
    library: Library,
    rolls: rolls_view.State = .{},
    scan: scan_view.State = .{},
    exporting: export_view.State = .{},
    looks: looks_view.State = .{},
    develop: develop_view.State = .{},
    notice: Notice = .{},
    workspace: Workspace,
    panels: Panels = .all,
    show_help: bool,

    fn deinit(app: *App, gpa: std.mem.Allocator, io: std.Io, gpu: *c.SDL_GPUDevice) void {
        app.develop.save(io, &app.library);
        app.develop.deinit(gpa, gpu);
        app.looks.deinit(gpa, gpu);
        app.exporting.deinit(gpa);
        app.scan.deinit(gpa, gpu);
        app.rolls.deinit(gpa);
        app.library.deinit(gpa, gpu);
    }

    /// Opens the roll and the scans the command line names.
    fn openAtStart(app: *App, gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
        if (options.roll) |name| {
            for (app.library.rolls.items) |r| {
                if (!std.mem.eql(u8, r.info.name, name)) continue;
                try app.develop.openRoll(gpa, io, &app.library, r.path);
                break;
            } else std.log.err("no roll named {s} in {s}", .{ name, app.library.path });
        }
        for (options.open) |path| try app.develop.openLoose(gpa, io, &app.library, path);
    }

    /// Acts on the shortcuts that work in every workspace, and passes Develop its own.
    fn handleKeys(app: *App, ctx: context.Context, window: *Window) void {
        const keys = ctx.keys;
        for (std.enums.values(Workspace)) |w| {
            if (keys.contains(w.command())) app.workspace = w;
        }
        if (keys.contains(.import)) app.workspace = .scan;
        if (keys.contains(.help)) app.show_help = !app.show_help;
        if (keys.contains(.quit)) window.close_asked = true;
        if (keys.contains(.full_screen)) window.toggleFullScreen();
        if (keys.contains(.hide_panels)) app.panels = if (app.panels == .all) .viewer_and_header else .all;
        if (keys.contains(.hide_all)) app.panels = if (app.panels == .viewer) .all else .viewer;
        if (keys.contains(.new_roll)) {
            app.workspace = .rolls;
            app.rolls.show_form = true;
            app.rolls.form = .{};
        }
        if (keys.contains(.find)) {
            app.workspace = .rolls;
            app.rolls.focus_search = true;
        }
        if (keys.contains(.cancel) and app.workspace == .rolls) app.rolls.show_form = false;
        if (app.workspace == .develop) {
            if (app.develop.handle(ctx.gpa, ctx.io, ctx.library, keys)) |message| app.notice.set("{s}", .{message});
        }
    }

    /// Draws the window: the header, then the workspace, which gets what was dropped on it.
    fn draw(app: *App, ctx: context.Context, dropped_files: *const Dropped) !void {
        const dropped = dropped_files.files();
        const drop: ?gui.Vec2 = if (dropped.len > 0) gui.vec2(dropped_files.position[0], dropped_files.position[1]) else null;
        if (dropped.len > 0 and app.workspace == .looks) {
            // Reference images for the look being fitted.
            app.looks.addFiles(ctx, dropped);
        } else if (dropped.len > 0 and app.workspace != .rolls) {
            dropScans(ctx.gpa, ctx.io, ctx.library, &app.develop, dropped, &app.notice);
            app.workspace = .develop;
        }

        const viewport = c.ImGui_GetMainViewport();
        c.ImGui_SetNextWindowPos(viewport.*.WorkPos, 0);
        c.ImGui_SetNextWindowSize(viewport.*.WorkSize, 0);
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(0, 0));
        _ = c.ImGui_Begin("minilab", null, c.ImGuiWindowFlags_NoDecoration | c.ImGuiWindowFlags_NoMove | c.ImGuiWindowFlags_NoBringToFrontOnFocus);
        c.ImGui_PopStyleVar();
        defer c.ImGui_End();
        if (app.panels != .viewer) drawHeader(&app.workspace, &app.notice, &app.library, &app.develop, scan_view.status(&app.scan));
        // When an export finishes, the user hears about it whichever workspace they're in.
        app.exporting.poll(ctx);
        // Each workspace gets its own ID space. Develop and Export both have "settings" panels,
        // which would otherwise be the same child window, sharing one scroll position.
        c.ImGui_PushIDInt(@intCast(@backingInt(app.workspace)));
        defer c.ImGui_PopID();
        switch (app.workspace) {
            .rolls => try app.actOnRolls(ctx, rolls_view.draw(&app.rolls, &app.library, ctx.gpa, ctx.io, drop), dropped),
            .develop => develop_view.draw(&app.develop, ctx, app.panels == .all),
            .scan, .@"export", .looks => {
                const next = switch (app.workspace) {
                    .scan => scan_view.draw(&app.scan, ctx),
                    .@"export" => export_view.draw(&app.exporting, ctx),
                    .looks => looks_view.draw(&app.looks, ctx),
                    .rolls, .develop => unreachable,
                };
                if (next) |w| app.workspace = w;
            },
        }
    }

    /// Does what was asked on the Rolls page.
    fn actOnRolls(app: *App, ctx: context.Context, action: rolls_view.Action, dropped: []const []const u8) !void {
        const gpa = ctx.gpa;
        const io = ctx.io;
        const library = &app.library;
        switch (action) {
            .none => if (dropped.len > 0) app.notice.set("Drop on a roll's row", .{}),
            .open => |at| {
                try app.develop.openRoll(gpa, io, library, library.rolls.items[at.roll].path);
                if (at.frame < library.rolls.items[at.roll].frames.items.len) app.develop.select(gpa, io, library, at.frame);
                app.workspace = .develop;
            },
            .created => |created| {
                if (created.flat_failed) app.notice.set("Flat field not set", .{});
                try app.develop.openRoll(gpa, io, library, library.rolls.items[created.roll].path);
                app.workspace = if (library.rolls.items[created.roll].info.input == .scanner) .scan else .develop;
            },
            .dropped_on => |index| {
                try app.develop.openRoll(gpa, io, library, library.rolls.items[index].path);
                dropScans(gpa, io, library, &app.develop, dropped, &app.notice);
            },
            .trash => |index| {
                var name_buffer: [256]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buffer, "{s}", .{library.rolls.items[index].info.name}) catch library.rolls.items[index].info.name;
                app.develop.forgetRoll(gpa, library.rolls.items[index].path);
                if (library.trashRoll(gpa, io, index)) |_| {
                    app.notice.set("Moved {s} to Trash", .{name});
                } else |err| app.notice.set("Can't move {s} to Trash · {t}", .{ name, err });
            },
        }
    }

    /// Whether the workspace showing has loaded everything. A screenshot waits for this.
    fn settled(app: *const App) bool {
        return switch (app.workspace) {
            .develop => app.develop.settled(),
            .scan => app.scan.settled(),
            .@"export" => app.exporting.settled(),
            .looks => app.looks.settled(),
            .rolls => true,
        };
    }
};

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
    const height = gui.px(header.height);
    const list = c.ImGui_GetWindowDrawList();
    c.ImDrawList_AddRectFilled(list, origin, gui.vec2(origin.x + width, origin.y + height), theme.imU32(theme.header));
    c.ImDrawList_AddLine(list, gui.vec2(origin.x, origin.y + height - 1), gui.vec2(origin.x + width, origin.y + height - 1), theme.imU32(theme.divider));
    const middle = origin.y + height / 2;

    // The mark: a frame of film with its perforations, then the name.
    drawMark(list, gui.vec2(origin.x + gui.px(header.padding), middle - gui.px(header.mark_size) / 2));
    fonts.pushSized(.semibold, fonts.wordmark_size);
    const name_size = c.ImGui_CalcTextSize("minilab");
    const name_x = origin.x + gui.px(header.padding + header.mark_size + header.mark_gap);
    c.ImDrawList_AddText(list, gui.vec2(name_x, middle - name_size.y / 2), theme.imU32(theme.text), "minilab");
    fonts.pop();
    // The version, small, beside the name.
    fonts.pushSized(.mono, fonts.tiny_size);
    const version_text = gui.print("{s}", .{version.string});
    const version_size = c.ImGui_CalcTextSize(version_text);
    const version_x = name_x + name_size.x + gui.px(header.version_gap);
    c.ImDrawList_AddText(list, gui.vec2(version_x, middle - version_size.y / 2 + gui.px(header.version_drop)), theme.imU32(theme.text_tertiary), version_text);
    fonts.pop();

    // The workspaces, as tabs.
    var x = version_x + version_size.x + gui.px(header.tabs_gap);
    const tab_height = gui.lineHeight() + gui.px(2 * header.tab_padding_y);
    for (std.enums.values(Workspace)) |w| {
        const label = w.label();
        const tab_width = c.ImGui_CalcTextSize(label).x + gui.px(2 * header.tab_padding_x);
        const corner = gui.vec2(x, middle - tab_height / 2);
        c.ImGui_SetCursorScreenPos(corner);
        if (c.ImGui_InvisibleButton(label, gui.vec2(tab_width, tab_height), 0)) workspace.* = w;
        shortcuts.tooltip(label, w.command());
        const hovered = c.ImGui_IsItemHovered(0);
        const current = workspace.* == w;
        const far = gui.vec2(corner.x + tab_width, corner.y + tab_height);
        if (current) {
            c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.control), gui.px(header.tab_rounding), 0);
            c.ImDrawList_AddRectFilledEx(list, gui.vec2(corner.x, far.y - gui.px(header.tab_underline)), far, theme.imU32(theme.accent), gui.px(header.tab_rounding), c.ImDrawFlags_RoundCornersBottom);
        }
        const size = c.ImGui_CalcTextSize(label);
        c.ImDrawList_AddText(list, gui.vec2(corner.x + (tab_width - size.x) / 2, middle - size.y / 2), theme.imU32(if (current or hovered) theme.text else theme.text_secondary), label);
        x += tab_width + gui.px(header.tab_gap);
    }

    // On the right: what just happened, the open roll, and the scanner.
    var right = origin.x + width - gui.px(header.padding);
    const scanner_text = gui.print("{s}", .{scanner.text});
    const scanner_size = c.ImGui_CalcTextSize(scanner_text);
    right -= scanner_size.x;
    c.ImDrawList_AddText(list, gui.vec2(right, middle - scanner_size.y / 2), theme.imU32(theme.text_secondary), scanner_text);
    c.ImDrawList_AddCircleFilled(list, gui.vec2(right - gui.px(header.dot_gap + header.dot_radius), middle), gui.px(header.dot_radius), theme.imU32(if (scanner.ready) theme.ready else theme.text_tertiary), header.dot_segments);
    right -= gui.px(header.dot_gap + 2 * header.dot_radius + header.padding);
    if (workspace.* != .rolls) {
        if (develop.rollIndex(library)) |r| {
            const info = library.rolls.items[r].info;
            const film = info.format.format().size;
            const roll_text = gui.print("{s} · {s} · {s}", .{ info.name, info.stock orelse labels.filmKind(info.kind), labels.filmSize(film) });
            const size = c.ImGui_CalcTextSize(roll_text);
            right -= size.x;
            c.ImDrawList_AddText(list, gui.vec2(right, middle - size.y / 2), theme.imU32(theme.text_secondary), roll_text);
            right -= gui.px(header.padding);
        }
    }
    if (notice.text()) |message| {
        const shown = gui.elideStart(message, @max(0, right - x - gui.px(header.padding)));
        const size = c.ImGui_CalcTextSize(shown);
        c.ImDrawList_AddText(list, gui.vec2(right - size.x, middle - size.y / 2), theme.imU32(theme.accent), shown);
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x, origin.y + height));
}

/// Draws the app's mark, the icon's film strip, 20 pixels square at `corner`.
fn drawMark(list: *c.ImDrawList, corner: gui.Vec2) void {
    const ink = theme.imU32(theme.accent);
    const thickness = gui.px(icon.stroke);
    const p = struct {
        fn at(o: gui.Vec2, point: [2]f32) gui.Vec2 {
            return gui.vec2(o.x + gui.px(point[0]), o.y + gui.px(point[1]));
        }
    }.at;
    const o = icon.outline;
    const min = p(corner, .{ o.centre[0] - o.half[0], o.centre[1] - o.half[1] });
    const max = p(corner, .{ o.centre[0] + o.half[0], o.centre[1] + o.half[1] });
    c.ImDrawList_AddRectEx(list, min, max, ink, gui.px(o.radius), thickness, 0);
    for (icon.segments) |s| c.ImDrawList_AddLineEx(list, p(corner, s[0]), p(corner, s[1]), ink, thickness);
}
