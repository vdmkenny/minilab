//! The Scan workspace (the design's Scan.dc.html): the scanner and its settings on the left, the
//! preview with the frames found on it and the selected frame in the middle, and the queue of
//! full-resolution scans on the right.
//!
//! The flow, as in design section 4:
//!
//! 1. Pick the scanner and the settings: the film type, which sets the scanner's own film mode,
//!    and the resolution. We use the transparency unit whenever the scanner has one.
//! 2. Preview: scan the scanner's whole film area at its lowest resolution of 300 dpi or more.
//! 3. Detect frames on the preview (`minilab.frames.detect`) for the open roll's format. By
//!    default a frame takes the full height of the holder's opening, since holders hide the
//!    film's edges.
//! 4. Adjust the boxes: drag them along the strip, resize them in the frame view, and add, split
//!    or delete them. Frames edited by hand are kept when frames are detected again.
//! 5. Scan each frame at full resolution with a margin around it, on the scan thread
//!    (`scan_worker.zig`). Each scan's frame is found again for its crop, and the scan is added to
//!    the open roll with `addScanAt`.
//!
//! The preview and the boxes are kept in the roll's folder as `preview.ppm` and `preview.json`, so
//! they come back when you open the roll again.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const context = @import("context.zig");
const shortcuts = @import("shortcuts.zig");
const labels = @import("labels.zig");
const Texture = @import("../platform/texture.zig").Texture;
const scan_worker = @import("scan_worker.zig");
const scan = scan_worker.scan;
const Worker = scan_worker.Worker;

const image = minilab.image;
const frames = minilab.frames;
const formats = minilab.formats;
const roll = minilab.roll;

/// Sizes in the design's pixels.
const scanner_width = 300;
/// The scanner's film mode, for every kind of film: Positive Film, so the scan is raw. A scanner's
/// Negative Film mode takes the orange mask out and inverts, so the film base can't be measured any
/// more (and on the V200 it also clips blue on B&W film). minilab does the inverting itself.
const scanner_film: scan.Film = .positive;

const queue_width = 280;
const panel_padding = 14;
const scanner_gap = 12;
const queue_gap = 10;
const group_gap = 6;
const pill_gap = 4;
const pill_height = 30;
const main_padding_x = 20;
const main_padding_y = 16;
const main_gap = 20;
const section_gap = 14;
const device_height = 32;
const margin_field_width = 80;
const action_height = 36;
const scan_button_height = 38;
const queue_row_padding_y = 8;
const queue_row_padding_x = 10;
const progress_height = 6;
const cancel_height = 34;
const number_column = 20;
const preview_note_width = 120;
const frame_view_height = 200;
const frame_view_padding = 20;
const handle_size = 10;
const slider_label_column = 110;
const slider_value_column = 56;
const button_height = 32;
const slider_row_height = 20;
/// How much film base to draw beside the frames of film with no set width, in mm.
const plain_film_margin_mm = 2;
/// The smallest a drag can make a box, in preview pixels.
const min_box_px = 8;
/// The design's line height, as a multiple of the font size.
const line_spacing = 1.4;

const mm_per_inch = formats.mm_per_inch;
/// The resolution previews are scanned at, or the scanner's next one up.
const preview_dpi = 300;
/// The resolution picked to start with, if the scanner has it.
const default_dpi = 2400;
/// The most resolutions to offer.
const max_resolution_choices = 4;
/// The frame view shows this share of the frame's length past each end, as in the design.
const view_overhang = 0.068;
/// The largest margin, inset and rotation the controls allow.
const max_margin_mm = 10;
const max_inset = 5;
const max_rotation = 5;
/// A detected frame follows the roll's format if its length is within this share of its height
/// times the roll's ratio. Otherwise it keeps its measured box.
const ratio_tolerance = 0.03;
/// Two boxes that overlap by more than this share of the shorter one's length are the same frame.
const same_frame_overlap = 0.3;

const preview_file = "preview.ppm";
const preview_settings_file = "preview.json";
const max_preview_bytes = 256 << 20;

/// The film types the design offers, and what each means for the scanner and for detection.
const FilmType = enum {
    colour_negative,
    bw_negative,
    positive,

    fn label(film: FilmType) [:0]const u8 {
        return switch (film) {
            .colour_negative => "Color negative",
            .bw_negative => "B&W negative",
            .positive => "Positive",
        };
    }

    fn why(film: FilmType) []const u8 {
        return switch (film) {
            .colour_negative => "raw, orange mask kept",
            .bw_negative => "raw, inverted in minilab",
            .positive => "no inversion",
        };
    }

    fn detectKind(film: FilmType) frames.Kind {
        return switch (film) {
            .colour_negative, .bw_negative => .negative,
            .positive => .positive,
        };
    }

    fn of(kind: minilab.develop.FilmKind) FilmType {
        return switch (kind) {
            .colour_negative => .colour_negative,
            .bw_negative => .bw_negative,
            .colour_positive, .bw_positive => .positive,
        };
    }
};

/// How a frame's length follows from its height.
const Shape = enum {
    /// The roll format's ratio.
    roll,
    /// Length and height set separately.
    free,
    /// A ratio the user sets.
    custom,
};

/// Why a frame is marked for checking.
const Check = enum {
    none,
    /// Its own edges hardly show, so it was placed from the pitch of its neighbours.
    pitch,
    /// It measured far from the format's length, so it keeps its measured box.
    length,
    /// Cut off by the end of the preview.
    cut,
};

/// A frame on the preview, in strip coordinates: `along` the strip and `across` it, in the
/// preview's pixels.
const Box = struct {
    /// The centre.
    along: f32,
    across: f32,
    /// The size, before the inset.
    length: f32,
    height: f32,
    /// In degrees, clockwise as shown.
    rotation: f32 = 0,
    /// The rotation detection found, which is what Rotation resets to.
    detected_rotation: f32 = 0,
    shape: Shape = .roll,
    /// Length over height, for `Shape.custom`.
    ratio: f32 = 1.5,
    /// Percent of the frame taken off each side.
    inset: f32 = 0,
    full_height: bool = true,
    check: Check = .none,
    /// Edited by hand. It's kept when frames are detected again, and its crop isn't refined.
    hand: bool = false,

    fn start(box: Box) f32 {
        return box.along - box.length / 2;
    }

    fn end(box: Box) f32 {
        return box.along + box.length / 2;
    }

    /// The crop: the box minus the inset.
    fn crop(box: Box) Box {
        var out = box;
        const share = 1 - 2 * box.inset / 100;
        out.length *= share;
        out.height *= share;
        return out;
    }
};

/// The preview, and what detection found on it.
const Preview = struct {
    scan: image.Scan,
    dpi: [2]f32,
    /// The area it covers on the scanner, in mm.
    area: scan.Area,
    axis: frames.Axis,
    /// The holder opening's size across the strip, and its middle, in preview pixels. Null until
    /// detection has found it.
    opening: ?f32 = null,
    opening_middle: ?f32 = null,
    /// Whether frames have been detected on it, so a preview saved earlier only gets detected
    /// once.
    detected: bool = false,
    texture: ?Texture = null,
    /// The film base colour as the texture shows it, for the strip between the frames. Null when
    /// there's no base.
    base_colour: ?[4]u8 = null,

    fn deinit(preview: *Preview, gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) void {
        preview.scan.deinit(gpa);
        if (preview.texture) |*t| t.release(gpu);
        preview.* = undefined;
    }

    /// Preview pixels per mm along the image's x and y.
    fn pxPerMm(preview: Preview) [2]f32 {
        return .{ preview.dpi[0] / mm_per_inch, preview.dpi[1] / mm_per_inch };
    }

    /// The strip's length in preview pixels. `acrossSize` below gives its width.
    fn alongSize(preview: Preview) f32 {
        return @floatFromInt(if (preview.axis == .y) preview.scan.height else preview.scan.width);
    }

    fn acrossSize(preview: Preview) f32 {
        return @floatFromInt(if (preview.axis == .y) preview.scan.width else preview.scan.height);
    }

    /// Preview pixels per mm along the strip.
    fn alongPerMm(preview: Preview) f32 {
        return preview.pxPerMm()[if (preview.axis == .y) 1 else 0];
    }

    /// Converts a box in strip coordinates to an image rectangle: x0, y0, x1, y1.
    fn rect(preview: Preview, box: Box) [4]f32 {
        const a0 = box.along - box.length / 2;
        const a1 = box.along + box.length / 2;
        const c0 = box.across - box.height / 2;
        const c1 = box.across + box.height / 2;
        return if (preview.axis == .y) .{ c0, a0, c1, a1 } else .{ a0, c0, a1, c1 };
    }

    /// Converts an image rectangle to mm on the scanner.
    fn toScanner(preview: Preview, r: [4]f32) scan.Area {
        const ppm = preview.pxPerMm();
        return .{
            .x = preview.area.x + r[0] / ppm[0],
            .y = preview.area.y + r[1] / ppm[1],
            .width = (r[2] - r[0]) / ppm[0],
            .height = (r[3] - r[1]) / ppm[1],
        };
    }
};

/// What's happened to a frame in the queue.
const Progress = enum { waiting, scanning, checking, done, check_crop, failed, cancelled };

const QueueItem = struct {
    status: Progress = .waiting,
    /// The frame it became in the roll, once it's there.
    frame: ?usize = null,
    /// When its scan started, in SDL's milliseconds.
    started: u64 = 0,
    err: ?anyerror = null,
};

/// What the preview's settings file holds.
const Saved = struct {
    dpi: [2]f32,
    area: scan.Area,
    axis: frames.Axis,
    opening: ?f32 = null,
    opening_middle: ?f32 = null,
    detected: bool = false,
    boxes: []const Box = &.{},
};

/// What a drag in the workspace moves.
const Drag = union(enum) {
    none,
    /// A box along the strip, from the preview or the frame view.
    move: usize,
    /// One corner of a box in the frame view: 0 is top left, then clockwise, as shown.
    corner: struct { box: usize, corner: u2 },
};

pub const State = struct {
    worker: ?*Worker = null,
    devices: []scan.Device = &.{},
    /// The device that's open or being opened.
    device: ?usize = null,
    capabilities: ?scan.Capabilities = null,
    /// Whether the device list has come back at least once.
    listed: bool = false,
    /// The last failure, for the panel. It's a static string.
    problem: ?[]const u8 = null,

    film: FilmType = .colour_negative,
    dpi: u32 = default_dpi,
    margin_mm: f32 = 1.0,
    margin_text: [16:0]u8 = @splat(0),
    editing_margin: bool = false,

    /// The roll whose preview this is, as a path.
    roll_path: ?[]u8 = null,
    preview: ?Preview = null,
    boxes: std.ArrayList(Box) = .empty,
    selected: ?usize = null,
    /// Why the last detection found nothing. It's a static string.
    detect_note: ?[]const u8 = null,
    /// Whether the boxes have changed since they were saved.
    boxes_dirty: bool = false,
    drag: Drag = .none,

    queue: std.ArrayList(QueueItem) = .empty,
    /// The roll the queue scans into, as a path.
    queue_roll: ?[]u8 = null,
    /// How far the queue's frames turn to stand upright: a quarter turn for a strip that runs down
    /// the scanner.
    queue_turns: u2 = 0,
    scanning: bool = false,

    pub fn deinit(state: *State, gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) void {
        if (state.worker) |w| w.stop();
        scan.freeDevices(gpa, state.devices);
        if (state.capabilities) |*caps| caps.deinit(gpa);
        if (state.preview) |*p| p.deinit(gpa, gpu);
        state.boxes.deinit(gpa);
        state.queue.deinit(gpa);
        if (state.roll_path) |p| gpa.free(p);
        if (state.queue_roll) |p| gpa.free(p);
        state.* = undefined;
    }

    /// Whether everything on the page has loaded. A screenshot waits for this. It includes the
    /// scanner list, which takes a few seconds.
    pub fn settled(state: *const State) bool {
        const worker = state.worker orelse return false;
        if (worker.pending()) return false;
        if (state.preview) |p| if (p.texture == null) return false;
        return true;
    }

    /// Starts the scan thread, which finds the scanners. `draw` does this too, but calling it at
    /// start lets the header show the scanner before Scan is opened.
    pub fn start(state: *State, gpa: std.mem.Allocator, io: std.Io) void {
        if (state.worker != null) return;
        state.worker = Worker.start(gpa, io) catch |err| {
            std.log.err("can't start the scan thread: {t}", .{err});
            state.problem = "Scan thread failed to start";
            return;
        };
    }

    fn deviceName(state: *const State) ?[]const u8 {
        const index = state.device orelse return null;
        if (index >= state.devices.len) return null;
        return state.devices[index].model;
    }
};

var status_buffer: [128]u8 = undefined;

/// The header's scanner line: "Perfection V200 · ready", or "No scanner". `ready` is true when a
/// scanner is open and idle.
pub fn status(state: *const State) struct { text: []const u8, ready: bool } {
    const worker = state.worker orelse return .{ .text = "No scanner", .ready = false };
    const name = state.deviceName() orelse return switch (worker.phase.load(.acquire)) {
        .loading, .listing => .{ .text = "Looking for scanners", .ready = false },
        else => .{ .text = "No scanner", .ready = false },
    };
    const doing: []const u8 = switch (worker.phase.load(.acquire)) {
        .loading, .listing, .opening => "opening",
        .idle => if (state.capabilities == null) "not ready" else "ready",
        .previewing => "previewing",
        .scanning => "scanning",
        .finishing => "finishing",
        .unavailable => "not ready",
    };
    const text = std.fmt.bufPrint(&status_buffer, "{s} · {s}", .{ name, doing }) catch name;
    return .{ .text = text, .ready = std.mem.eql(u8, doing, "ready") };
}

/// Picks up what the scan thread has done, and adds scanned frames to their roll. `draw` does
/// this, and the app also calls it every frame, so scans keep going into the roll while another
/// workspace is showing.
pub fn update(state: *State, ctx: context.Context) void {
    state.start(ctx.gpa, ctx.io);
    const worker = state.worker orelse return;
    while (worker.take()) |taken| {
        var event = taken;
        handleEvent(state, ctx, worker, &event);
    }
}

fn handleEvent(state: *State, ctx: context.Context, worker: *Worker, event: *scan_worker.Event) void {
    const gpa = ctx.gpa;
    switch (event.*) {
        .devices => |list| {
            scan.freeDevices(gpa, state.devices);
            state.devices = list;
            state.listed = true;
            state.device = null;
            if (state.capabilities) |*caps| caps.deinit(gpa);
            state.capabilities = null;
            // Open the first scanner straight away, since there's usually only one.
            if (list.len > 0) {
                state.device = 0;
                worker.submit(.{ .open = 0 }) catch {};
            }
            return;
        },
        .opened => |opened| {
            if (state.capabilities) |*caps| caps.deinit(gpa);
            state.capabilities = opened.capabilities;
            state.device = opened.device;
            state.problem = null;
            state.dpi = chooseDpi(opened.capabilities, state.dpi);
            return;
        },
        .failed => |failed| {
            std.log.err("scanner {t}: {t}", .{ failed.stage, failed.err });
            // Without drivers, the scanner panel already says what to install.
            if (failed.err == error.Unavailable) return;
            state.problem = switch (failed.stage) {
                .list => "Scanner search failed",
                .open => "Can't open scanner · busy or in use elsewhere",
                .preview => "Preview failed",
                .scan => "Scan failed",
            };
            ctx.notice.set("{s}", .{state.problem.?});
            if (failed.stage == .open) state.device = null;
        },
        .preview => |*picture| {
            setPreview(state, ctx, picture.*);
            return;
        },
        .frame_started => |index| if (queueItem(state, index)) |item| {
            item.status = .scanning;
            item.started = c.SDL_GetTicks();
        },
        .frame_checking => |index| if (queueItem(state, index)) |item| {
            item.status = .checking;
        },
        .frame_done => |done| {
            defer gpa.free(done.ppm);
            const item = queueItem(state, done.index);
            const frame = addToRoll(state, ctx, done) catch |err| {
                std.log.err("can't add frame {d} to the roll: {t}", .{ done.index + 1, err });
                if (item) |i| {
                    i.status = .failed;
                    i.err = err;
                }
                return;
            };
            if (item) |i| {
                i.status = if (done.refined) .done else .check_crop;
                i.frame = frame;
            }
            return;
        },
        .frame_failed => |failed| if (queueItem(state, failed.index)) |item| {
            item.status = .failed;
            item.err = failed.err;
        },
        .frame_cancelled => |index| if (queueItem(state, index)) |item| {
            item.status = .cancelled;
        },
        .queue_done => |done| {
            state.scanning = false;
            if (done.cancelled) {
                ctx.notice.set("Scanning canceled", .{});
            } else {
                var added: usize = 0;
                for (state.queue.items) |item| added += @intFromBool(item.status == .done or item.status == .check_crop);
                ctx.notice.set("Scanned {d} of {d} frames", .{ added, state.queue.items.len });
            }
        },
    }
    event.deinit(gpa);
}

fn queueItem(state: *State, index: usize) ?*QueueItem {
    if (index >= state.queue.items.len) return null;
    return &state.queue.items[index];
}

/// The resolution to use after the scanner changes: the chosen one if the scanner has it, or else
/// the default, or else the nearest one above.
fn chooseDpi(capabilities: scan.Capabilities, current: u32) u32 {
    if (std.mem.indexOfScalar(u32, capabilities.resolutions, current) != null) return current;
    return capabilities.resolutionFrom(default_dpi) orelse current;
}

/// Adds a scanned frame to the queue's roll. Returns its index there.
fn addToRoll(state: *State, ctx: context.Context, done: scan_worker.Scanned) !usize {
    const path = state.queue_roll orelse return error.NoRoll;
    const index = ctx.library.find(path) orelse return error.RollNotFound;
    const r = &ctx.library.rolls.items[index];
    const frame = try r.addScanAt(ctx.gpa, ctx.io, done.ppm, done.dpi);
    const saved = &r.frames.items[frame];
    saved.crop = done.crop;
    saved.quarter_turns = state.queue_turns;
    try r.saveFrame(ctx.io, frame);
    if (r.info.dpi == null or r.info.scanner == null) {
        r.info.dpi = done.dpi;
        if (r.info.scanner == null) if (state.device) |d| if (d < state.devices.len) {
            const device = state.devices[d];
            r.info.scanner = try std.fmt.allocPrint(r.arena.allocator(), "{s} {s}", .{ device.vendor, device.model });
        };
        r.saveInfo(ctx.io) catch |err| std.log.err("can't save the roll: {t}", .{err});
    }
    return frame;
}

/// Draws the workspace. Returns a workspace to go to, when the page asks for one.
pub fn draw(state: *State, ctx: context.Context) ?context.Workspace {
    update(state, ctx);
    const roll_index = ctx.develop.rollIndex(ctx.library);
    followRoll(state, ctx, roll_index);
    handleKeys(state, ctx);
    // Clear the results of an earlier run once the frames have changed.
    if (!state.scanning and state.queue.items.len > 0 and state.queue.items.len != state.boxes.items.len) state.queue.clearRetainingCapacity();

    const top = c.ImGui_GetCursorScreenPos();
    const available = c.ImGui_GetContentRegionAvail();
    const left = gui.px(scanner_width);
    const right = gui.px(queue_width);
    var next: ?context.Workspace = null;

    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(0, 0));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gui.px(8), 0));
    defer c.ImGui_PopStyleVarEx(2);

    c.ImGui_SetCursorScreenPos(top);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.panel);
    _ = c.ImGui_BeginChild("scanner", gui.vec2(left, available.y), c.ImGuiChildFlags_None, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse);
    drawScanner(state, ctx, roll_index);
    gui.edge(.right);
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    c.ImGui_SetCursorScreenPos(gui.vec2(top.x + left, top.y));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.viewer);
    _ = c.ImGui_BeginChild("strip", gui.vec2(available.x - left - right, available.y), c.ImGuiChildFlags_None, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse);
    if (roll_index == null) {
        if (drawNoRoll()) next = .rolls;
    } else drawMain(state, ctx, roll_index.?);
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    c.ImGui_SetCursorScreenPos(gui.vec2(top.x + available.x - right, top.y));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.panel);
    _ = c.ImGui_BeginChild("queue", gui.vec2(right, available.y), c.ImGuiChildFlags_None, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse);
    if (drawQueue(state, ctx)) |w| next = w;
    gui.edge(.left);
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    if (state.boxes_dirty and !c.ImGui_IsAnyItemActive()) savePreviewSettings(state, ctx);
    return next;
}

/// Follows the open roll: when another roll opens, its saved preview and boxes are loaded.
fn followRoll(state: *State, ctx: context.Context, roll_index: ?usize) void {
    const path = if (roll_index) |r| ctx.library.rolls.items[r].path else null;
    if (state.roll_path) |current| {
        if (path != null and std.mem.eql(u8, current, path.?)) return;
    } else if (path == null) return;

    clearPreview(state, ctx);
    if (state.roll_path) |p| ctx.gpa.free(p);
    state.roll_path = null;
    const r = roll_index orelse return;
    state.roll_path = ctx.gpa.dupe(u8, path.?) catch return;
    state.film = .of(ctx.library.rolls.items[r].info.kind);
    loadPreview(state, ctx, r) catch |err| switch (err) {
        error.FileNotFound => {},
        else => std.log.warn("can't load the roll's preview: {t}", .{err}),
    };
}

fn clearPreview(state: *State, ctx: context.Context) void {
    if (state.preview) |*p| p.deinit(ctx.gpa, ctx.gpu);
    state.preview = null;
    state.boxes.clearRetainingCapacity();
    state.selected = null;
    state.detect_note = null;
    state.drag = .none;
    if (!state.scanning) state.queue.clearRetainingCapacity();
}

fn handleKeys(state: *State, ctx: context.Context) void {
    const count = state.boxes.items.len;
    if (count == 0) return;
    const current = state.selected orelse 0;
    if (ctx.keys.contains(.next)) state.selected = @min(current + 1, count - 1);
    if (ctx.keys.contains(.previous)) state.selected = current -| 1;
    if (ctx.keys.contains(.first)) state.selected = 0;
    if (ctx.keys.contains(.last)) state.selected = count - 1;
}

// The scanner panel.

fn drawScanner(state: *State, ctx: context.Context, roll_index: ?usize) void {
    const origin = c.ImGui_GetWindowPos();
    const size = c.ImGui_GetWindowSize();
    const list = c.ImGui_GetWindowDrawList();
    const x = origin.x + gui.px(panel_padding);
    // The right edge is the panel's divider.
    const width = size.x - gui.px(2 * panel_padding) - 1;
    var y = origin.y + gui.px(panel_padding);
    const worker = state.worker;
    const phase: scan_worker.Phase = if (worker) |w| w.phase.load(.acquire) else .loading;
    const busy = switch (phase) {
        .idle, .unavailable => false,
        else => true,
    };

    y += headingAt(list, x, y, "SCANNER") + gui.px(scanner_gap);

    // The device.
    c.ImGui_SetCursorScreenPos(gui.vec2(x, y));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(8), (gui.px(device_height) - c.ImGui_GetFontSize()) / 2));
    c.ImGui_BeginDisabled(busy or state.devices.len == 0);
    var names: [8][]const u8 = undefined;
    const shown = @min(state.devices.len, names.len);
    for (state.devices[0..shown], 0..) |d, i| names[i] = gui.print("{s} {s} ({s}, {s})", .{ d.vendor, d.model, d.kind.label(), d.driver });
    const placeholder: []const []const u8 = &.{switch (phase) {
        .loading, .listing => "Looking for scanners…",
        .unavailable => "No scanner drivers",
        else => "No scanner found",
    }};
    const items = if (shown > 0) names[0..shown] else placeholder;
    c.ImGui_SetNextItemWidth(width);
    if (gui.combo("device", items, state.device orelse 0, width / gui.scale)) |picked| {
        if (shown > 0 and picked != state.device) {
            state.device = picked;
            if (state.capabilities) |*caps| caps.deinit(ctx.gpa);
            state.capabilities = null;
            if (worker) |w| w.submit(.{ .open = picked }) catch {};
        }
    }
    c.ImGui_EndDisabled();
    c.ImGui_PopStyleVar();
    y += gui.px(device_height) + gui.px(scanner_gap);

    // What the scanner is set up for, or why there isn't one.
    if (state.capabilities) |caps| {
        y += drawProfile(list, x, y, width, caps) + gui.px(scanner_gap);
        y += paragraphAt(list, x, y, width, theme.text_tertiary, filmAreaNote(caps, ctx, roll_index)) + gui.px(scanner_gap);
    } else if (!busy) {
        if (phase == .unavailable) {
            y = drawDriverSetup(ctx, list, x, y, width);
        } else if (state.problem) |problem| {
            y += paragraphAt(list, x, y, width, theme.text_tertiary, problem) + gui.px(scanner_gap);
        } else if (state.devices.len == 0) {
            // The device list says no scanner was found.
            y += paragraphAt(list, x, y, width, theme.text_tertiary, "Check the USB cable and power") + gui.px(scanner_gap);
        }
        // Looking again also loads the drivers again, once they're installed.
        c.ImGui_SetCursorScreenPos(gui.vec2(x, y));
        if (gui.buttonOf(.normal, "Refresh", gui.vec2(0, pill_height))) {
            state.problem = null;
            if (worker) |w| w.submit(.list) catch {};
        }
        y += gui.px(pill_height) + gui.px(scanner_gap);
    }

    // Film type.
    y += lineAt(list, x, y, theme.text_secondary, "Film type") + gui.px(group_gap);
    c.ImGui_PushID("film");
    {
        var labels_: [3][:0]const u8 = undefined;
        for (std.enums.values(FilmType), 0..) |f, i| labels_[i] = f.label();
        if (pills(&labels_, @backingInt(state.film), x, &y, width, false)) |picked| state.film = @fromBackingInt(@intCast(picked));
    }
    c.ImGui_PopID();
    y += gui.px(group_gap);
    const film_note = if (state.capabilities) |caps| blk: {
        if (!caps.film_setting) break :blk gui.print("No film mode on this scanner", .{});
        const mode = if (caps.profile) |p| p.positive else "Positive";
        break :blk gui.print("Scanner mode: {s} · {s}", .{ mode, state.film.why() });
    } else gui.print("Scanner mode: Positive Film · {s}", .{state.film.why()});
    y += paragraphAt(list, x, y, width, theme.text_tertiary, film_note) + gui.px(scanner_gap);

    // Resolution.
    y += lineAt(list, x, y, theme.text_secondary, "Resolution") + gui.px(group_gap);
    var choices: [max_resolution_choices]u32 = undefined;
    const resolutions = resolutionChoices(state, &choices);
    if (resolutions.len > 0) {
        var labels_: [max_resolution_choices][:0]const u8 = undefined;
        var chosen: usize = resolutions.len;
        for (resolutions, 0..) |r, i| {
            labels_[i] = gui.print("{d} dpi", .{r});
            if (r == state.dpi) chosen = i;
        }
        c.ImGui_PushID("resolution");
        c.ImGui_BeginDisabled(state.scanning);
        if (pills(labels_[0..resolutions.len], chosen, x, &y, width, true)) |picked| state.dpi = resolutions[picked];
        c.ImGui_EndDisabled();
        c.ImGui_PopID();
        y += gui.px(group_gap);
    }
    y += paragraphAt(list, x, y, width, theme.text_tertiary, sizeNote(state, ctx, roll_index)) + gui.px(scanner_gap);

    // Margin.
    const field_height = gui.px(pill_height);
    const label_y = y + (field_height - lineHeight()) / 2;
    _ = lineAt(list, x, label_y, theme.text_secondary, "Margin around frames");
    drawMarginField(state, gui.vec2(x + width - gui.px(margin_field_width), y));
    y += field_height + gui.px(scanner_gap);
    y += paragraphAt(list, x, y, width, theme.text_tertiary, "Covers the gaps, for the film base");

    // The actions, at the bottom.
    const bottom = origin.y + size.y - gui.px(panel_padding);
    const scan_y = @max(bottom - gui.px(scan_button_height), y + gui.px(scanner_gap + action_height + 8));
    const actions_y = scan_y - gui.px(8 + action_height);
    const half = (width - gui.px(8)) / 2;
    const ready = state.capabilities != null and !busy and roll_index != null;
    c.ImGui_SetCursorScreenPos(gui.vec2(x, actions_y));
    c.ImGui_BeginDisabled(!ready);
    const preview_label: [:0]const u8 = if (phase == .previewing) gui.print("Previewing {d}%##preview", .{percent(worker)}) else "Preview";
    if (gui.buttonOf(.normal, preview_label, gui.vec2(half / gui.scale, action_height))) startPreview(state);
    c.ImGui_EndDisabled();
    c.ImGui_SetCursorScreenPos(gui.vec2(x + half + gui.px(8), actions_y));
    c.ImGui_BeginDisabled(state.preview == null or state.scanning);
    if (gui.buttonOf(.normal, "Detect frames", gui.vec2(half / gui.scale, action_height))) detect(state, ctx, roll_index);
    c.ImGui_EndDisabled();
    c.ImGui_SetCursorScreenPos(gui.vec2(x, scan_y));
    const count = state.boxes.items.len;
    c.ImGui_BeginDisabled(!ready or count == 0 or state.preview == null);
    const scan_label: [:0]const u8 = if (state.scanning) "Scanning…" else if (count == 0) "Scan" else if (count == 1) "Scan 1 frame" else gui.print("Scan {d} frames", .{count});
    if (gui.buttonOf(.primary, scan_label, gui.vec2(width / gui.scale, scan_button_height))) startScan(state, ctx, roll_index);
    c.ImGui_EndDisabled();
}

/// What a Mac needs for scanning: Homebrew, then SANE from it.
const homebrew_url = "https://brew.sh";
const sane_install = "brew install sane-backends";
/// Where Homebrew puts itself: on Apple silicon, and on Intel Macs.
const homebrew_paths = [_][]const u8{ "/opt/homebrew/bin/brew", "/usr/local/bin/brew" };

/// Draws the steps to get scanner drivers when minilab can't find any: on a Mac, Homebrew and then
/// SANE, with a button for each step; on Linux, the distribution's SANE package; on Windows, the
/// scanner maker's TWAIN driver. Refresh, drawn after this, picks them up. Returns the y below.
fn drawDriverSetup(ctx: context.Context, list: *c.ImDrawList, x: f32, top: f32, width: f32) f32 {
    var y = top;
    switch (builtin.os.tag) {
        .windows => {
            y += lineAt(list, x, y, theme.text, "Scanner driver needed") + gui.px(group_gap);
            y += paragraphAt(list, x, y, width, theme.text_tertiary, "Install the scanner maker's TWAIN driver") + gui.px(scanner_gap);
            return y;
        },
        .macos => {
            y += lineAt(list, x, y, theme.text, "Scanner drivers needed: SANE") + gui.px(group_gap);
            y += paragraphAt(list, x, y, width, theme.text_tertiary, "Free drivers for most scanners · installed once with Homebrew") + gui.px(scanner_gap);

            // 1. Homebrew, unless it's there already.
            var has_homebrew = false;
            for (homebrew_paths) |path| {
                if (std.Io.Dir.cwd().access(ctx.io, path, .{})) |_| has_homebrew = true else |_| {}
            }
            y = setupStep(list, x, y, width, "1", "Homebrew", if (has_homebrew) "Installed" else "brew.sh");
            if (!has_homebrew) {
                c.ImGui_SetCursorScreenPos(gui.vec2(x + gui.px(step_indent), y));
                if (gui.buttonOf(.normal, "Get Homebrew", gui.vec2(0, pill_height))) _ = c.SDL_OpenURL(homebrew_url);
                if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("Opens brew.sh · its install command goes in Terminal");
                y += gui.px(pill_height) + gui.px(scanner_gap);
            }

            // 2. SANE, from a command to paste into Terminal.
            y = setupStep(list, x, y, width, "2", "SANE", sane_install);
            c.ImGui_SetCursorScreenPos(gui.vec2(x + gui.px(step_indent), y));
            if (gui.buttonOf(.normal, "Copy command", gui.vec2(0, pill_height))) {
                _ = c.SDL_SetClipboardText(sane_install);
                ctx.notice.set("Command copied · paste it in Terminal", .{});
            }
            y += gui.px(pill_height) + gui.px(scanner_gap);

            // 3. Refresh, which the caller draws.
            y = setupStep(list, x, y, width, "3", "Refresh", "after the install finishes");
            return y;
        },
        else => {
            y += lineAt(list, x, y, theme.text, "Scanner drivers needed: SANE") + gui.px(group_gap);
            y += paragraphAt(list, x, y, width, theme.text_tertiary, "Install your distribution's SANE package (libsane, sane-backends) · then Refresh") + gui.px(scanner_gap);
            return y;
        },
    }
}

/// How far a setup step's details sit in from its number.
const step_indent = 22;

/// Draws a numbered setup step: its number, its name, and a detail under the name. Returns the y
/// below it.
fn setupStep(list: *c.ImDrawList, x: f32, top: f32, width: f32, number: [:0]const u8, name: []const u8, detail: []const u8) f32 {
    const radius = gui.px(9);
    const middle = top + lineHeight() / 2;
    c.ImDrawList_AddCircleFilled(list, gui.vec2(x + radius, middle), radius, theme.imU32(theme.control), 16);
    fonts.pushSized(.mono, 11);
    const size = c.ImGui_CalcTextSize(number);
    c.ImDrawList_AddText(list, gui.vec2(x + radius - size.x / 2, middle - size.y / 2), theme.imU32(theme.text), number);
    fonts.pop();
    var y = top;
    y += lineAt(list, x + gui.px(step_indent), y, theme.text_secondary, name);
    fonts.pushSized(.mono, 12);
    y += paragraphAt(list, x + gui.px(step_indent), y, width - gui.px(step_indent), theme.text_tertiary, detail);
    fonts.pop();
    return y + gui.px(group_gap);
}

/// Draws "Profile: …" with a tick, or a note that the scanner doesn't have one.
fn drawProfile(list: *c.ImDrawList, x: f32, y: f32, width: f32, caps: scan.Capabilities) f32 {
    const pad_x = gui.px(10);
    const pad_y = gui.px(8);
    const icon = gui.px(14);
    const text_x = x + pad_x + icon + gui.px(8);
    const text_width = width - (text_x - x) - pad_x;
    const message = if (caps.profile) |p| gui.print("Profile: {s}", .{p.summary}) else gui.print("No profile · data may not be linear", .{});
    const text_height = paragraphHeight(message, text_width);
    const height = text_height + 2 * pad_y;
    c.ImDrawList_AddRectFilledEx(list, gui.vec2(x, y), gui.vec2(x + width, y + height), theme.imU32(theme.raised), gui.px(5), 0);
    const icon_at = gui.vec2(x + pad_x, y + (height - icon) / 2);
    if (caps.profile != null) drawTick(list, icon_at, theme.ready) else drawInfo(list, icon_at, gui.px(14), theme.text_secondary);
    _ = paragraphAt(list, text_x, y + pad_y, text_width, theme.text_secondary, message);
    return height;
}

/// A note on what fits on the scanner's film area. A frame fits when its size across the film
/// does. The film itself can be wider, with its edges under the holder.
fn filmAreaNote(caps: scan.Capabilities, ctx: context.Context, roll_index: ?usize) []const u8 {
    const width = caps.area.width;
    if (roll_index) |r| {
        const format = ctx.library.rolls.items[r].info.format.format();
        if (format.height_mm > width) {
            return gui.print("Film area {d:.2} mm · too narrow for {s} ({d:.0} mm)", .{ width, format.size.label(), format.height_mm });
        }
        if (format.size.filmWidthMm()) |film| if (film > width) {
            return gui.print("Film area {d:.2} mm · {d:.0} mm frames fit, edges under the holder", .{ width, format.height_mm });
        };
    }
    const across_120 = formats.Standard.@"120_6x4.5".format().height_mm;
    if (width < across_120) return gui.print("Film area {d:.2} mm · 135 and narrower", .{width});
    return gui.print("Film area {d:.2} × {d:.2} mm", .{ width, caps.area.height });
}

/// The resolutions to offer: all of the scanner's when there are only a few, or else a spread of
/// them.
fn resolutionChoices(state: *const State, buffer: *[max_resolution_choices]u32) []const u32 {
    const caps = state.capabilities orelse return buffer[0..0];
    const all = caps.resolutions;
    if (all.len <= max_resolution_choices) {
        @memcpy(buffer[0..all.len], all);
        return buffer[0..all.len];
    }
    // The preview's resolution, then the highest three.
    buffer[0] = caps.resolutionFrom(preview_dpi) orelse all[0];
    var n: usize = 1;
    var i = all.len;
    while (i > 0 and n < max_resolution_choices) {
        i -= 1;
        if (all[i] == buffer[0]) break;
        buffer[n] = all[i];
        n += 1;
    }
    std.mem.sortUnstable(u32, buffer[0..n], {}, std.sort.asc(u32));
    return buffer[0..n];
}

/// How big each frame's scan will be at the chosen resolution.
fn sizeNote(state: *const State, ctx: context.Context, roll_index: ?usize) []const u8 {
    const dpi: f32 = @floatFromInt(state.dpi);
    // Across the film it's the whole film area, and along it the frame plus its margins.
    const across_mm = if (state.capabilities) |caps| caps.area.width else if (state.preview) |p| p.area.width else 33.02;
    var estimate = true;
    var along_mm: f32 = formats.Standard.default.format().width_mm;
    if (roll_index) |r| along_mm = ctx.library.rolls.items[r].info.format.format().width_mm;
    if (state.preview) |p| if (selectedBox(state)) |box| {
        along_mm = box.crop().length / p.alongPerMm();
        estimate = false;
    };
    along_mm += 2 * state.margin_mm;
    const width: u64 = @intFromFloat(@round(across_mm * dpi / mm_per_inch));
    const height: u64 = @intFromFloat(@round(along_mm * dpi / mm_per_inch));
    const deep = if (state.capabilities) |caps| caps.deep else true;
    const megabytes = width * height * @as(u64, if (deep) 6 else 3) / 1_000_000;
    const about: []const u8 = if (estimate) "About " else "";
    if (megabytes < 10) return gui.print("{s}{d} × {d} px per frame", .{ about, width, height });
    return gui.print("{s}{d} × {d} px · {d} MB per frame", .{ about, width, height, megabytes });
}

/// The margin field, in mm. It shows "1.0 mm" and edits as a plain number.
fn drawMarginField(state: *State, corner: gui.Vec2) void {
    const width = gui.px(margin_field_width);
    const height = gui.px(pill_height);
    const list = c.ImGui_GetWindowDrawList();
    c.ImGui_SetCursorScreenPos(corner);
    fonts.pushSized(.mono, 12);
    defer fonts.pop();
    if (state.editing_margin) {
        c.ImGui_SetNextItemWidth(width);
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(8), (height - c.ImGui_GetFontSize()) / 2));
        if (!c.ImGui_IsAnyItemActive()) c.ImGui_SetKeyboardFocusHere();
        _ = c.ImGui_InputText("##margin", &state.margin_text, state.margin_text.len, c.ImGuiInputTextFlags_CharsDecimal | c.ImGuiInputTextFlags_AutoSelectAll);
        c.ImGui_PopStyleVar();
        if (c.ImGui_IsItemDeactivated()) {
            const typed = std.mem.trim(u8, std.mem.sliceTo(&state.margin_text, 0), " ");
            if (std.fmt.parseFloat(f32, typed)) |v| state.margin_mm = std.math.clamp(v, 0, max_margin_mm) else |_| {}
            state.editing_margin = false;
        }
        return;
    }
    if (c.ImGui_InvisibleButton("##margin field", gui.vec2(width, height), 0)) {
        state.editing_margin = true;
        _ = std.fmt.bufPrintSentinel(&state.margin_text, "{d:.1}", .{state.margin_mm}, 0) catch {};
    }
    const hovered = c.ImGui_IsItemHovered(0);
    const far = gui.vec2(corner.x + width, corner.y + height);
    c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(if (hovered) theme.control_hover else theme.control), gui.px(5), 0);
    c.ImDrawList_AddRectEx(list, corner, far, theme.imU32(theme.border), gui.px(5), 1, 0);
    const shown = gui.print("{d:.1} mm", .{state.margin_mm});
    const size = c.ImGui_CalcTextSize(shown);
    c.ImDrawList_AddText(list, gui.vec2(far.x - gui.px(8) - size.x, corner.y + (height - size.y) / 2), theme.imU32(theme.text), shown);
}

fn percent(worker: ?*Worker) u32 {
    const w = worker orelse return 0;
    return @intFromFloat(@round(w.progress.fraction() * 100));
}

fn startPreview(state: *State) void {
    const worker = state.worker orelse return;
    const caps = state.capabilities orelse return;
    const dpi = caps.resolutionFrom(preview_dpi) orelse return;
    worker.submit(.{ .preview = .{
        .source = caps.source,
        .film = scanner_film,
        .dpi = dpi,
        .deep = caps.deep,
    } }) catch {};
}

// The preview and frames, in the middle.

fn drawNoRoll() bool {
    const origin = c.ImGui_GetWindowPos();
    const list = c.ImGui_GetWindowDrawList();
    const x = origin.x + gui.px(main_padding_x);
    var y = origin.y + gui.px(main_padding_y);
    fonts.pushSized(.semibold, 18);
    c.ImDrawList_AddText(list, gui.vec2(x, y), theme.imU32(theme.text), "No roll open");
    y += c.ImGui_GetFontSize() * line_spacing;
    fonts.pop();
    y += gui.px(section_gap);
    y += paragraphAt(list, x, y, gui.px(420), theme.text_secondary, "Scans go into a roll · open or make one in Rolls");
    y += gui.px(section_gap);
    c.ImGui_SetCursorScreenPos(gui.vec2(x, y));
    const go = gui.buttonOf(.primary, "Go to Rolls", gui.vec2(0, button_height));
    shortcuts.tooltip("The library of rolls", .rolls);
    return go;
}

fn drawMain(state: *State, ctx: context.Context, roll_index: usize) void {
    const origin = c.ImGui_GetWindowPos();
    const size = c.ImGui_GetWindowSize();
    const list = c.ImGui_GetWindowDrawList();
    const x = origin.x + gui.px(main_padding_x);
    const y = origin.y + gui.px(main_padding_y);
    const height = size.y - gui.px(2 * main_padding_y);
    const strip_width = drawPreviewColumn(state, list, x, y, height, ctx.library.rolls.items[roll_index].info.format.format().size);
    const section_x = x + strip_width + gui.px(main_gap);
    const section_width = origin.x + size.x - gui.px(main_padding_x) - section_x;
    drawFrameSection(state, ctx, roll_index, list, section_x, y, section_width);
}

/// Draws the preview with the frames on it. Returns the column's width.
fn drawPreviewColumn(state: *State, list: *c.ImDrawList, x: f32, top: f32, height: f32, film: formats.FilmSize) f32 {
    var y = top;
    const dpi_shown: u32 = if (state.preview) |p| @intFromFloat(@round(p.dpi[0])) else if (state.capabilities) |caps| caps.resolutionFrom(preview_dpi) orelse preview_dpi else preview_dpi;
    const label = gui.print("Preview · {d} dpi", .{dpi_shown});
    y += lineAt(list, x, y, theme.text_secondary, label) + gui.px(8);

    // The film area scaled to fill the column's height, with its width following.
    const area: scan.Area = if (state.preview) |p| p.area else if (state.capabilities) |caps| caps.area else .{ .x = 0, .y = 0, .width = 33.02, .height = 244.348 };
    const mono_line = gui.px(12) * line_spacing;
    const below = gui.px(8) + mono_line + gui.px(8) + 2 * lineHeight();
    const room = top + height - y - below;
    // Once there are frames, the strip is drawn as straight film, as in the design: the film's
    // own width, and the length the preview covers. Before that, we draw the scan as it lies.
    const as_film = if (state.preview) |p| state.boxes.items.len > 0 and p.texture != null else false;
    const film_mm = if (as_film) gui.vec2(filmWidthMm(state, &state.preview.?, film), state.preview.?.alongSize() / state.preview.?.alongPerMm()) else gui.vec2(area.width, area.height);
    const shown = gui.vec2(@round(room * film_mm.x / film_mm.y), @round(room));
    const corner = gui.vec2(x, y);
    const far = gui.vec2(x + shown.x, y + shown.y);

    if (state.preview) |*p| {
        if (as_film) {
            const map: StripMap = .film(p, corner, shown, film_mm.x);
            drawFilm(state, p, map, film, list);
            drawBoxesOnStrip(state, p, map, list);
        } else if (p.texture) |t| c.ImDrawList_AddImage(list, t.ref(), corner, far) else c.ImDrawList_AddRectFilled(list, corner, far, theme.imU32(theme.header));
    } else {
        c.ImDrawList_AddRectFilled(list, corner, far, theme.imU32(theme.header));
        gui.dashedRect(list, corner, far, theme.imU32(theme.border), 1, gui.px(dash), gui.px(dash_gap));
        const busy = if (state.worker) |w| w.phase.load(.acquire) == .previewing else false;
        if (busy) {
            const done = if (state.worker) |w| w.progress.fraction() else 0;
            c.ImDrawList_AddRectFilled(list, corner, gui.vec2(far.x, corner.y + shown.y * done), theme.imU32(theme.control));
        }
    }
    y += shown.y + gui.px(8);

    fonts.pushSized(.mono, 12);
    const mm = gui.print("{d:.2} × {d:.2} mm", .{ area.width, area.height });
    const mm_width = c.ImGui_CalcTextSize(mm).x;
    c.ImDrawList_AddText(list, gui.vec2(x, y + (mono_line - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text_tertiary), mm);
    fonts.pop();
    y += mono_line + gui.px(8);
    const note_width = @max(shown.x, gui.px(preview_note_width));
    if (state.preview != null and !as_film) _ = paragraphAt(list, x, y, gui.px(preview_note_width), theme.text_tertiary, "Film edges under the holder");
    return @max(@max(shown.x, mm_width), note_width);
}

/// Where a frame on the preview goes when the strip is drawn as film. Along the strip maps to
/// along the column, and across the strip is centred, at the film's own scale.
const StripMap = struct {
    corner: gui.Vec2,
    shown: gui.Vec2,
    /// Screen pixels per preview pixel, along and across the strip.
    along: f32,
    across: f32,

    fn film(preview: *const Preview, corner: gui.Vec2, shown: gui.Vec2, film_width_mm: f32) StripMap {
        const across_per_mm = shown.x / film_width_mm;
        return .{
            .corner = corner,
            .shown = shown,
            .along = shown.y / preview.alongSize(),
            .across = across_per_mm / preview.pxPerMm()[if (preview.axis == .y) 0 else 1],
        };
    }

    /// The box's rectangle on the screen, as its top-left and bottom-right corners.
    fn rect(map: StripMap, box: Box) [2]gui.Vec2 {
        const middle = map.corner.x + map.shown.x / 2;
        const half = box.height * map.across / 2;
        const top = map.corner.y + (box.along - box.length / 2) * map.along;
        return .{ gui.vec2(middle - half, top), gui.vec2(middle + half, top + box.length * map.along) };
    }
};

/// The film's width in mm: the format's film width, or for film with no set width, the frames'
/// width plus a little base on each side.
fn filmWidthMm(state: *const State, preview: *const Preview, film: formats.FilmSize) f32 {
    if (film.filmWidthMm()) |w| return w;
    var widest: f32 = 0;
    for (state.boxes.items) |box| widest = @max(widest, box.height);
    return widest / preview.pxPerMm()[if (preview.axis == .y) 0 else 1] + 2 * plain_film_margin_mm;
}

/// Draws the film as it looks on a light table: the base in its own colour, the film's holes if it
/// has any (rows along both edges, or a few per frame), and each frame's picture straight and
/// centred.
fn drawFilm(state: *const State, preview: *const Preview, map: StripMap, film: formats.FilmSize, list: *c.ImDrawList) void {
    const far = gui.vec2(map.corner.x + map.shown.x, map.corner.y + map.shown.y);
    const base = preview.base_colour orelse theme.rgba8(theme.raised);
    c.ImDrawList_AddRectFilled(list, map.corner, far, c.IM_COL32(base[0], base[1], base[2], base[3]));

    const per_mm = map.along * preview.alongPerMm();
    const across_per_mm = map.shown.x / filmWidthMm(state, preview, film);
    const hole_ink = theme.imU32(theme.viewer);
    switch (film.holes()) {
        .none => {},
        .rows => |holes| drawRows(state, map, holes, per_mm, across_per_mm, list),
        .per_frame => |count| for (state.boxes.items) |box| {
            // At the start of each frame, along one edge. The sizes are our own drawing sizes,
            // since we don't have the formats' real ones to hand.
            const side = formats.registration_hole.size_mm * across_per_mm;
            const x = map.corner.x + formats.registration_hole.inset_mm * across_per_mm;
            const start = map.corner.y + (box.along - box.length / 2) * map.along;
            for (0..count) |k| {
                const offset = (@as(f32, @floatFromInt(k)) - @as(f32, @floatFromInt(count - 1)) / 2) * formats.registration_hole.spacing_mm * per_mm;
                const top = std.math.clamp(start + offset - side / 2, map.corner.y, far.y);
                const bottom = std.math.clamp(start + offset + side / 2, map.corner.y, far.y);
                if (bottom > top) c.ImDrawList_AddRectFilledEx(list, gui.vec2(x, top), gui.vec2(x + side, bottom), hole_ink, side / 4, 0);
            }
        },
    }
    drawPictures(state, preview, map, list);
}

/// Draws 135's perforations along both edges, at the film's pitch and in step with the first
/// frame, the way a camera advances the film.
fn drawRows(state: *const State, map: StripMap, holes: formats.Perforations, per_mm: f32, across_per_mm: f32, list: *c.ImDrawList) void {
    const far = gui.vec2(map.corner.x + map.shown.x, map.corner.y + map.shown.y);
    const first = if (state.boxes.items.len > 0) state.boxes.items[0] else return;
    const pitch = holes.pitch_mm * per_mm;
    const length = holes.length_mm * per_mm;
    const start = map.corner.y + (first.along - first.length / 2) * map.along;
    var at = start - @ceil((start - map.corner.y) / pitch) * pitch;
    const inset = holes.inset_mm * across_per_mm;
    const height = holes.height_mm * across_per_mm;
    const ink = theme.imU32(theme.viewer);
    const radius = @min(length, height) / 4;
    while (at < far.y) : (at += pitch) {
        const top = @max(at, map.corner.y);
        const bottom = @min(at + length, far.y);
        if (bottom <= top) continue;
        c.ImDrawList_AddRectFilledEx(list, gui.vec2(map.corner.x + inset, top), gui.vec2(map.corner.x + inset + height, bottom), ink, radius, 0);
        c.ImDrawList_AddRectFilledEx(list, gui.vec2(far.x - inset - height, top), gui.vec2(far.x - inset, bottom), ink, radius, 0);
    }
}

/// Draws each frame's picture, straight and centred in its box.
fn drawPictures(state: *const State, preview: *const Preview, map: StripMap, list: *c.ImDrawList) void {
    const texture = preview.texture orelse return;
    const size = gui.vec2(@floatFromInt(preview.scan.width), @floatFromInt(preview.scan.height));
    for (state.boxes.items) |box| {
        const r = preview.rect(box.crop());
        const left = std.math.clamp(r[0] / size.x, 0, 1);
        const upper = std.math.clamp(r[1] / size.y, 0, 1);
        const right = std.math.clamp(r[2] / size.x, 0, 1);
        const lower = std.math.clamp(r[3] / size.y, 0, 1);
        const corners = map.rect(box.crop());
        const min = corners[0];
        const max = corners[1];
        // Along the strip means down the column, so for a strip lying along x the picture is
        // turned.
        if (preview.axis == .y) {
            c.ImDrawList_AddImageQuadEx(list, texture.ref(), min, gui.vec2(max.x, min.y), max, gui.vec2(min.x, max.y), gui.vec2(left, upper), gui.vec2(right, upper), gui.vec2(right, lower), gui.vec2(left, lower), c.IM_COL32_WHITE);
        } else {
            c.ImDrawList_AddImageQuadEx(list, texture.ref(), min, gui.vec2(max.x, min.y), max, gui.vec2(min.x, max.y), gui.vec2(left, lower), gui.vec2(left, upper), gui.vec2(right, upper), gui.vec2(right, lower), c.IM_COL32_WHITE);
        }
    }
}

/// Draws the boxes over the preview: amber, dashed white where they need checking, and a ring
/// around the selected one. Click a box to select it, and drag it to move it along the strip.
fn drawBoxesOnStrip(state: *State, preview: *Preview, map: StripMap, list: *c.ImDrawList) void {
    for (state.boxes.items, 0..) |box, i| {
        const corners = map.rect(box.crop());
        const min = corners[0];
        const max = corners[1];
        c.ImGui_PushIDInt(@intCast(i));
        c.ImGui_SetCursorScreenPos(min);
        _ = c.ImGui_InvisibleButton("box", gui.vec2(@max(max.x - min.x, 1), @max(max.y - min.y, 1)), 0);
        if (c.ImGui_IsItemActivated()) {
            state.selected = i;
            state.drag = .{ .move = i };
        }
        // A click only selects. The box moves once the mouse has gone past the drag threshold.
        if (c.ImGui_IsItemActive() and c.ImGui_IsMouseDragging(0, -1) and state.drag == .move and state.drag.move == i) {
            const moved = c.ImGui_GetIO().*.MouseDelta.y / map.along;
            if (moved != 0) moveBox(state, preview, i, moved, 0);
        }
        if (c.ImGui_IsItemHovered(0)) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_ResizeNS);
        c.ImGui_PopID();

        const weak = box.check != .none;
        const ink = theme.imU32(if (weak) theme.text else theme.accent);
        const inner_min = gui.vec2(min.x + gui.px(1), min.y + gui.px(1));
        const inner_max = gui.vec2(max.x - gui.px(1), max.y - gui.px(1));
        if (weak) gui.dashedRect(list, inner_min, inner_max, ink, gui.px(2), gui.px(dash), gui.px(dash_gap)) else c.ImDrawList_AddRectEx(list, inner_min, inner_max, ink, 0, gui.px(2), 0);
        if (state.selected == i) c.ImDrawList_AddRectEx(list, gui.vec2(min.x - gui.px(1.5), min.y - gui.px(1.5)), gui.vec2(max.x + gui.px(1.5), max.y + gui.px(1.5)), theme.imU32(theme.text), 0, gui.px(3), 0);

        // The number chip.
        fonts.pushSized(.mono, 10);
        const chip = if (weak) gui.print("{d} ?", .{i + 1}) else gui.print("{d}", .{i + 1});
        const size = c.ImGui_CalcTextSize(chip);
        const chip_min = gui.vec2(min.x + gui.px(3), min.y + gui.px(3));
        const chip_max = gui.vec2(chip_min.x + size.x + gui.px(6), chip_min.y + gui.px(10) * line_spacing);
        c.ImDrawList_AddRectFilledEx(list, chip_min, chip_max, theme.imU32(if (weak) theme.text else theme.accent), gui.px(2), 0);
        c.ImDrawList_AddText(list, gui.vec2(chip_min.x + gui.px(3), chip_min.y + (chip_max.y - chip_min.y - size.y) / 2), theme.imU32(theme.on_accent), chip);
        fonts.pop();
    }
    if (state.drag != .none and !c.ImGui_IsMouseDown(0)) {
        state.drag = .none;
    }
}

/// Moves box `index` by `along` and `across` preview pixels, keeping it on the strip.
fn moveBox(state: *State, preview: *const Preview, index: usize, along: f32, across: f32) void {
    const box = &state.boxes.items[index];
    box.along = std.math.clamp(box.along + along, 0, preview.alongSize());
    if (!box.full_height) box.across = std.math.clamp(box.across + across, 0, preview.acrossSize());
    box.hand = true;
    box.check = .none;
    state.boxes_dirty = true;
}

fn selectedBox(state: *const State) ?Box {
    const i = state.selected orelse return null;
    if (i >= state.boxes.items.len) return null;
    return state.boxes.items[i];
}

/// Draws the selected frame, its crop and the frame tools.
fn drawFrameSection(state: *State, ctx: context.Context, roll_index: usize, list: *c.ImDrawList, x: f32, top: f32, width: f32) void {
    var y = top;
    const info = ctx.library.rolls.items[roll_index].info;
    const format = info.format.format();
    const preview = if (state.preview) |*p| p else {
        y += titleAt(list, x, y, "No preview yet", null) + gui.px(section_gap);
        _ = paragraphAt(list, x, y, @min(width, gui.px(520)), theme.text_secondary, "Strip in the holder, then Preview");
        return;
    };
    const index = state.selected orelse {
        y += titleAt(list, x, y, "No frames", null) + gui.px(section_gap);
        const why = state.detect_note orelse "Detect frames, or add them by hand";
        y += paragraphAt(list, x, y, @min(width, gui.px(520)), theme.text_secondary, why) + gui.px(section_gap);
        c.ImGui_SetCursorScreenPos(gui.vec2(x, y));
        if (gui.buttonOf(.normal, "Add frame", gui.vec2(0, button_height))) addFrame(state, ctx.gpa, preview, format);
        return;
    };
    const box = &state.boxes.items[index];

    // The title: which frame, and its format.
    const film = labels.filmSize(format.size);
    const shape_text = switch (box.shape) {
        .roll => ratioLabel(format.ratio()),
        .free => "measured",
        .custom => ratioLabel(box.ratio),
    };
    const rotated: []const u8 = if (preview.axis == .y) ", shown rotated" else "";
    y += titleAt(list, x, y, gui.print("Frame {d}", .{index + 1}), gui.print("{s} {s} · {s}{s}", .{ film, format.name, shape_text, rotated })) + gui.px(section_gap);

    y += drawFrameView(state, preview, index, list, x, y, width) + gui.px(section_gap);

    if (box.check != .none) {
        y += drawCheckNote(state, preview, index, list, x, y, width) + gui.px(section_gap);
    }

    // Shape.
    y += lineAt(list, x, y, theme.text_secondary, "Shape") + gui.px(group_gap);
    c.ImGui_PushID("shape");
    const shape_labels = [_][:0]const u8{ gui.print("Roll format, {s}", .{ratioLabel(format.ratio())}), "Free", "Custom ratio" };
    if (pills(&shape_labels, @backingInt(box.shape), x, &y, width, false)) |picked| {
        box.shape = @fromBackingInt(@intCast(picked));
        if (box.shape == .custom) box.ratio = box.length / box.height;
        reshape(box, preview, format);
        box.hand = true;
        state.boxes_dirty = true;
    }
    c.ImGui_PopID();
    y += gui.px(section_gap);

    // Inset, rotation, and the custom ratio.
    c.ImGui_PushID("sliders");
    if (sliderRowAt(x, &y, width, "Inset", &box.inset, 0, max_inset, "{d:.1}%", 0)) {
        box.hand = true;
        state.boxes_dirty = true;
    }
    y += gui.px(8);
    if (sliderRowAt(x, &y, width, "Rotation", &box.rotation, -max_rotation, max_rotation, "{d:.1}°", box.detected_rotation)) {
        box.hand = true;
        state.boxes_dirty = true;
    }
    if (box.shape == .custom) {
        y += gui.px(8);
        if (sliderRowAt(x, &y, width, "Ratio", &box.ratio, 0.5, 3, "{d:.2}", format.ratio())) {
            reshape(box, preview, format);
            box.hand = true;
            state.boxes_dirty = true;
        }
    }
    c.ImGui_PopID();
    y += gui.px(section_gap);

    c.ImGui_SetCursorScreenPos(gui.vec2(x, y));
    if (checkbox("Full height of the opening", &box.full_height)) {
        if (!box.full_height) box.height = @min(box.height, format.height_mm * preview.pxPerMm()[if (preview.axis == .y) 0 else 1]);
        reshape(box, preview, format);
        box.hand = true;
        state.boxes_dirty = true;
    }
    y += lineHeight() + gui.px(section_gap);

    // The frame tools.
    c.ImGui_SetCursorScreenPos(gui.vec2(x, y));
    c.ImGui_BeginDisabled(state.scanning);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(12), (gui.px(button_height) - c.ImGui_GetFontSize()) / 2));
    if (gui.buttonOf(.normal, "Add frame", gui.vec2(0, button_height))) addFrame(state, ctx.gpa, preview, format);
    c.ImGui_SameLineEx(0, gui.px(8));
    if (gui.buttonOf(.normal, "Split", gui.vec2(0, button_height))) splitFrame(state, ctx.gpa, index);
    c.ImGui_SameLineEx(0, gui.px(8));
    if (gui.buttonOf(.normal, "Delete", gui.vec2(0, button_height))) deleteFrame(state, index);
    c.ImGui_SameLineEx(0, gui.px(8));
    if (quietButton("Detect again", gui.vec2(0, button_height))) detect(state, ctx, roll_index);
    c.ImGui_PopStyleVar();
    c.ImGui_EndDisabled();
    y += gui.px(button_height) + gui.px(section_gap);
    _ = paragraphAt(list, x, y, width, theme.text_tertiary, "Hand edits kept on Detect again");
}

/// Draws the selected frame and the film around it, turned so its long side runs across, with the
/// crop and its corner handles. Drag the crop to move it, or a corner to resize it. Returns the
/// height.
fn drawFrameView(state: *State, preview: *Preview, index: usize, list: *c.ImDrawList, x: f32, y: f32, width: f32) f32 {
    const box = state.boxes.items[index];
    const pad = gui.px(frame_view_padding);
    const view_height = gui.px(frame_view_height);
    const total = view_height + 2 * pad;
    c.ImDrawList_AddRectFilledEx(list, gui.vec2(x, y), gui.vec2(x + width, y + total), theme.imU32(theme.page), gui.px(6), 0);

    // The region to show: the frame plus a little past each end, and the whole opening across.
    const across = @max(box.height, preview.opening orelse box.height);
    const along = box.length * (1 + 2 * view_overhang);
    const scale = @min(view_height / across, (width - 2 * pad) / along);
    const shown = gui.vec2(along * scale, across * scale);
    const origin = gui.vec2(x + (width - shown.x) / 2, y + pad + (view_height - shown.y) / 2);
    const region: Box = .{ .along = box.along, .across = box.across, .length = along, .height = across };
    drawRegion(list, preview, region, origin, shown);

    // The crop, in the view's coordinates. Across runs top to bottom. Along runs left to right,
    // or right to left on a strip turned clockwise, since its start is on the right.
    const crop = box.crop();
    const flip = preview.axis == .y;
    const crop_left = if (flip) region.end() - crop.end() else crop.start() - region.start();
    const crop_min = gui.vec2(origin.x + crop_left * scale, origin.y + (crop.across - crop.height / 2 - (region.across - region.height / 2)) * scale);
    const crop_max = gui.vec2(crop_min.x + crop.length * scale, crop_min.y + crop.height * scale);
    const corners = rotatedCorners(crop_min, crop_max, box.rotation);
    const ink = theme.imU32(if (box.check != .none) theme.text else theme.accent);
    if (box.check != .none) {
        drawDashedQuad(list, corners, ink, gui.px(2));
    } else {
        c.ImDrawList_AddQuadEx(list, corners[0], corners[1], corners[2], corners[3], ink, gui.px(2));
    }

    // Dragging the crop moves the frame along the strip, and dragging a corner resizes it.
    const handle = gui.px(handle_size);
    c.ImGui_PushID("frame view");
    defer c.ImGui_PopID();
    for (corners, 0..) |p, k| {
        c.ImDrawList_AddRectFilled(list, gui.vec2(p.x - handle / 2, p.y - handle / 2), gui.vec2(p.x + handle / 2, p.y + handle / 2), theme.imU32(theme.accent));
        c.ImGui_SetCursorScreenPos(gui.vec2(p.x - handle, p.y - handle));
        c.ImGui_PushIDInt(@intCast(k));
        _ = c.ImGui_InvisibleButton("corner", gui.vec2(2 * handle, 2 * handle), 0);
        if (c.ImGui_IsItemHovered(0) or c.ImGui_IsItemActive()) c.ImGui_SetMouseCursor(if (k % 2 == 0) c.ImGuiMouseCursor_ResizeNWSE else c.ImGuiMouseCursor_ResizeNESW);
        if (c.ImGui_IsItemActivated()) state.drag = .{ .corner = .{ .box = index, .corner = @intCast(k) } };
        if (c.ImGui_IsItemActive() and c.ImGui_IsMouseDragging(0, -1)) {
            const delta = c.ImGui_GetIO().*.MouseDelta;
            if (delta.x != 0 or delta.y != 0) resizeBox(state, preview, index, @intCast(k), delta.x / scale, delta.y / scale);
        }
        c.ImGui_PopID();
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(crop_min.x + handle, crop_min.y + handle));
    _ = c.ImGui_InvisibleButton("crop", gui.vec2(@max(crop_max.x - crop_min.x - 2 * handle, 1), @max(crop_max.y - crop_min.y - 2 * handle, 1)), 0);
    if (c.ImGui_IsItemHovered(0)) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_ResizeAll);
    if (c.ImGui_IsItemActive() and c.ImGui_IsMouseDragging(0, -1)) {
        const delta = c.ImGui_GetIO().*.MouseDelta;
        if (delta.x != 0 or delta.y != 0) moveBox(state, preview, index, (if (flip) -delta.x else delta.x) / scale, delta.y / scale);
    }
    return total;
}

/// Draws `region` of the preview into `shown` at `origin`, with the strip running left to right.
/// A strip that runs down the scanner is turned a quarter turn clockwise.
fn drawRegion(list: *c.ImDrawList, preview: *const Preview, region: Box, origin: gui.Vec2, shown: gui.Vec2) void {
    const texture = preview.texture orelse return;
    const r = preview.rect(region);
    const w: f32 = @floatFromInt(preview.scan.width);
    const h: f32 = @floatFromInt(preview.scan.height);
    const left = r[0] / w;
    const top = r[1] / h;
    const right = r[2] / w;
    const bottom = r[3] / h;
    const p1 = origin;
    const p2 = gui.vec2(origin.x + shown.x, origin.y);
    const p3 = gui.vec2(origin.x + shown.x, origin.y + shown.y);
    const p4 = gui.vec2(origin.x, origin.y + shown.y);
    // The film past the edge of the scan, where the region runs off it.
    c.ImDrawList_AddRectFilled(list, p1, p3, theme.imU32(theme.header));
    if (preview.axis == .y) {
        // Turned clockwise, so the top left as shown is the image's bottom left.
        c.ImDrawList_AddImageQuadEx(list, texture.ref(), p1, p2, p3, p4, gui.vec2(left, bottom), gui.vec2(left, top), gui.vec2(right, top), gui.vec2(right, bottom), 0xFFFFFFFF);
    } else {
        c.ImDrawList_AddImageQuadEx(list, texture.ref(), p1, p2, p3, p4, gui.vec2(left, top), gui.vec2(right, top), gui.vec2(right, bottom), gui.vec2(left, bottom), 0xFFFFFFFF);
    }
}

/// The corners of the rectangle from `min` to `max`, turned `degrees` clockwise around its
/// centre: top left, top right, bottom right, bottom left.
fn rotatedCorners(min: gui.Vec2, max: gui.Vec2, degrees: f32) [4]gui.Vec2 {
    const centre = gui.vec2((min.x + max.x) / 2, (min.y + max.y) / 2);
    const angle = std.math.degreesToRadians(degrees);
    const cos = @cos(angle);
    const sin = @sin(angle);
    var out: [4]gui.Vec2 = .{ min, gui.vec2(max.x, min.y), max, gui.vec2(min.x, max.y) };
    for (&out) |*p| {
        const dx = p.x - centre.x;
        const dy = p.y - centre.y;
        p.* = gui.vec2(centre.x + dx * cos - dy * sin, centre.y + dx * sin + dy * cos);
    }
    return out;
}

/// Resizes box `index` by dragging corner `corner` of the frame view (0 is top left, then
/// clockwise) by `dx`, `dy` view pixels in preview units. The opposite corner stays put. A box
/// with a fixed ratio and the full height can only move.
fn resizeBox(state: *State, preview: *const Preview, index: usize, corner: u2, dx: f32, dy: f32) void {
    const box = &state.boxes.items[index];
    // The view runs along the strip right to left when the strip is turned.
    const flip = preview.axis == .y;
    const locked = box.shape != .free;
    if (locked and box.full_height) return moveBox(state, preview, index, if (flip) -dx else dx, 0);
    const share = 1 - 2 * box.inset / 100;
    const right = corner == 1 or corner == 2;
    const bottom = corner == 2 or corner == 3;
    const length = @max(box.length + (if (right) dx else -dx) / share, min_box_px);
    // The centre moves with the dragged side, by half the change.
    const shift = (length - box.length) / 2 * @as(f32, if (right) 1 else -1);
    box.along += if (flip) -shift else shift;
    if (locked) {
        box.height *= length / box.length;
    } else if (!box.full_height) {
        const height = @max(box.height + (if (bottom) dy else -dy) / share, min_box_px);
        box.across += (height - box.height) / 2 * @as(f32, if (bottom) 1 else -1);
        box.height = height;
    }
    box.length = length;
    box.hand = true;
    box.check = .none;
    state.boxes_dirty = true;
}

/// Makes a box match its shape: the opening's height if it's full height, and the length from the
/// ratio.
fn reshape(box: *Box, preview: *const Preview, format: formats.Format) void {
    if (box.full_height) {
        if (preview.opening) |opening| box.height = opening;
        if (preview.opening_middle) |middle| box.across = middle;
    }
    switch (box.shape) {
        .roll => box.length = box.height * format.ratio(),
        .custom => box.length = box.height * box.ratio,
        .free => {},
    }
}

/// Draws the note on a frame marked for checking, in a dashed box. Returns its height.
fn drawCheckNote(state: *const State, preview: *const Preview, index: usize, list: *c.ImDrawList, x: f32, y: f32, width: f32) f32 {
    const box = state.boxes.items[index];
    const message: []const u8 = switch (box.check) {
        .none => return 0,
        .cut => "Check · runs off the preview",
        .length => "Check · length far from the format, measured box kept",
        .pitch => pitchNote(state, preview, index),
    };
    const pad_x = gui.px(12);
    const pad_y = gui.px(10);
    const icon = gui.px(16);
    const text_x = x + pad_x + icon + gui.px(10);
    const text_width = x + width - pad_x - text_x;
    const height = paragraphHeight(message, text_width) + 2 * pad_y;
    gui.dashedRect(list, gui.vec2(x, y), gui.vec2(x + width, y + height), theme.imU32(theme.text_secondary), 1, gui.px(dash), gui.px(dash_gap));
    drawInfo(list, gui.vec2(x + pad_x, y + pad_y + (lineHeight() - icon) / 2), icon, theme.text);
    _ = paragraphAt(list, text_x, y + pad_y, text_width, theme.text, message);
    return height;
}

/// Explains why a weak frame sits where it does: the pitch of the confident frames around it.
fn pitchNote(state: *const State, preview: *const Preview, index: usize) []const u8 {
    const boxes = state.boxes.items;
    var before: ?usize = null;
    var i = index;
    while (i > 0) {
        i -= 1;
        if (boxes[i].check == .none) {
            before = i;
            break;
        }
    }
    var after: ?usize = null;
    for (boxes[index + 1 ..], index + 1..) |b, j| if (b.check == .none) {
        after = j;
        break;
    };
    if (before == null and after == null) return "Check · faint edges, placed from the format's pitch";
    const a = before orelse return "Check · faint edges, placed from the next frames' pitch";
    const b = after orelse return "Check · faint edges, placed from the previous frames' pitch";
    const pitch = (boxes[b].along - boxes[a].along) / @as(f32, @floatFromInt(b - a)) / preview.alongPerMm();
    return gui.print("Check · faint edges, placed from the {d:.0} mm pitch of frames {d} and {d}", .{ pitch, a + 1, b + 1 });
}

fn addFrame(state: *State, gpa: std.mem.Allocator, preview: *const Preview, format: formats.Format) void {
    const per_mm = preview.alongPerMm();
    const across_per_mm = preview.pxPerMm()[if (preview.axis == .y) 0 else 1];
    const height = preview.opening orelse format.height_mm * across_per_mm;
    var box: Box = .{
        .along = preview.alongSize() / 2,
        .across = preview.opening_middle orelse preview.acrossSize() / 2,
        .length = height * format.ratio(),
        .height = height,
        .hand = true,
    };
    const pitch = (format.pitch_mm orelse format.width_mm + format.gapMm()) * per_mm;
    if (selectedBox(state)) |selected| {
        box = selected;
        box.check = .none;
        box.hand = true;
        box.along = selected.along + pitch;
        if (box.end() > preview.alongSize()) box.along = selected.along - pitch;
    }
    box.along = std.math.clamp(box.along, 0, preview.alongSize());
    insertBox(state, gpa, box);
}

fn splitFrame(state: *State, gpa: std.mem.Allocator, index: usize) void {
    const box = state.boxes.items[index];
    var first = box;
    first.shape = .free;
    first.length = box.length / 2;
    first.along = box.along - box.length / 4;
    first.hand = true;
    first.check = .none;
    var second = first;
    second.along = box.along + box.length / 4;
    state.boxes.items[index] = first;
    insertBox(state, gpa, second);
    state.selected = index;
}

fn deleteFrame(state: *State, index: usize) void {
    _ = state.boxes.orderedRemove(index);
    const count = state.boxes.items.len;
    state.selected = if (count == 0) null else @min(index, count - 1);
    state.boxes_dirty = true;
}

/// Adds `box` in its place along the strip, and selects it.
fn insertBox(state: *State, gpa: std.mem.Allocator, box: Box) void {
    var at: usize = 0;
    while (at < state.boxes.items.len and state.boxes.items[at].along < box.along) at += 1;
    state.boxes.insert(gpa, at, box) catch return;
    state.selected = at;
    state.boxes_dirty = true;
}

/// Finds the frames on the preview. Frames edited by hand stay, and detected frames that overlap
/// them are dropped.
fn detect(state: *State, ctx: context.Context, roll_index: ?usize) void {
    const preview = if (state.preview) |*p| p else return;
    const r = roll_index orelse return;
    const format = ctx.library.rolls.items[r].info.format.format();
    var detection = frames.detect.detect(ctx.gpa, preview.scan, preview.dpi[0], format, state.film.detectKind(), .{}) catch |err| {
        state.detect_note = switch (err) {
            error.NoOpening => "No film on the preview · check the strip and holder",
            error.BadResolution => "Preview resolution unknown · preview again",
            error.OutOfMemory => "Detection out of memory",
        };
        keepHandBoxes(state);
        return;
    };
    defer detection.deinit(ctx.gpa);
    preview.axis = detection.axis;
    preview.detected = true;
    const across_per_mm = preview.pxPerMm()[if (detection.axis == .y) 0 else 1];
    preview.opening = detection.opening_mm * across_per_mm;

    keepHandBoxes(state);
    var middle_sum: f32 = 0;
    var added: usize = 0;
    for (detection.frames) |frame| {
        var box = boxOf(frame, preview.*, format);
        middle_sum += box.across;
        for (state.boxes.items) |hand| {
            const overlap = @min(hand.end(), box.end()) - @max(hand.start(), box.start());
            if (overlap > same_frame_overlap * @min(hand.length, box.length)) break;
        } else {
            box.full_height = true;
            insertBox(state, ctx.gpa, box);
            added += 1;
        }
    }
    if (detection.frames.len > 0) preview.opening_middle = middle_sum / @as(f32, @floatFromInt(detection.frames.len));
    state.detect_note = if (detection.frames.len == 0) "No frames found · add them by hand" else null;
    state.selected = if (state.boxes.items.len > 0) 0 else null;
    state.boxes_dirty = true;
    std.log.debug("detected {d} frames, {d} kept from hand edits; strip along {t}, opening {d:.1} mm", .{ detection.frames.len, state.boxes.items.len - added, detection.axis, detection.opening_mm });
}

fn keepHandBoxes(state: *State) void {
    var kept: usize = 0;
    for (state.boxes.items) |box| {
        if (!box.hand) continue;
        state.boxes.items[kept] = box;
        kept += 1;
    }
    state.boxes.shrinkRetainingCapacity(kept);
    state.selected = if (kept > 0) 0 else null;
}

/// Turns a detected frame into a box.
fn boxOf(frame: frames.Frame, preview: Preview, format: formats.Format) Box {
    const x: f32 = @floatFromInt(frame.area.x);
    const y: f32 = @floatFromInt(frame.area.y);
    const w: f32 = @floatFromInt(frame.area.width);
    const h: f32 = @floatFromInt(frame.area.height);
    const vertical = preview.axis == .y;
    var box: Box = .{
        .along = if (vertical) y + h / 2 else x + w / 2,
        .across = if (vertical) x + w / 2 else y + h / 2,
        .length = if (vertical) h else w,
        .height = if (vertical) w else h,
        .rotation = frame.rotation_degrees,
        .detected_rotation = frame.rotation_degrees,
    };
    if (@abs(box.length - box.height * format.ratio()) > ratio_tolerance * box.length) box.shape = .free;
    if (frame.confidence == .check) {
        const cut = box.start() <= 1 or box.end() >= preview.alongSize() - 1;
        box.check = if (cut) .cut else if (box.shape == .free) .length else .pitch;
    }
    return box;
}

/// Scans every frame at full resolution into the open roll.
fn startScan(state: *State, ctx: context.Context, roll_index: ?usize) void {
    const worker = state.worker orelse return;
    const caps = state.capabilities orelse return;
    const preview = state.preview orelse return;
    const r = roll_index orelse return;
    const gpa = ctx.gpa;
    const info = ctx.library.rolls.items[r].info;
    const jobs = gpa.alloc(scan_worker.FrameJob, state.boxes.items.len) catch return;
    for (state.boxes.items, jobs, 0..) |box, *job, i| {
        const crop = preview.toScanner(preview.rect(box.crop()));
        // Along the strip, scan the crop plus the margin on each side. Across it, scan the whole
        // film area, so the holder's edges show up for finding the frame again.
        const margin = state.margin_mm;
        var area: scan.Area = if (preview.axis == .y)
            .{ .x = caps.area.x, .y = crop.y - margin, .width = caps.area.width, .height = crop.height + 2 * margin }
        else
            .{ .x = crop.x - margin, .y = caps.area.y, .width = crop.width + 2 * margin, .height = caps.area.height };
        area = area.clip(caps.area) orelse caps.area;
        job.* = .{
            .index = i,
            .request = .{ .source = caps.source, .film = scanner_film, .dpi = state.dpi, .deep = caps.deep, .area = area },
            .crop = crop,
            .refine = if (box.hand) null else .{ .format = info.format.format(), .kind = state.film.detectKind(), .axis = preview.axis, .inset = box.inset / 100 },
        };
    }
    state.queue.clearRetainingCapacity();
    state.queue.appendNTimes(gpa, .{}, jobs.len) catch {
        gpa.free(jobs);
        return;
    };
    if (state.queue_roll) |p| gpa.free(p);
    state.queue_roll = gpa.dupe(u8, ctx.library.rolls.items[r].path) catch null;
    // A strip that runs down the scanner has its frames on their side, so they get turned the way
    // the frame view shows them.
    state.queue_turns = if (preview.axis == .y) 1 else 0;
    worker.submit(.{ .frames = jobs }) catch {
        gpa.free(jobs);
        return;
    };
    state.scanning = true;
}

// The queue, on the right.

/// Draws the queue panel. Returns Develop when a frame's crop is opened there.
fn drawQueue(state: *State, ctx: context.Context) ?context.Workspace {
    var next: ?context.Workspace = null;
    const origin = c.ImGui_GetWindowPos();
    const size = c.ImGui_GetWindowSize();
    const list = c.ImGui_GetWindowDrawList();
    // The left edge is the panel's divider.
    const x = origin.x + 1 + gui.px(panel_padding);
    const width = size.x - 1 - gui.px(2 * panel_padding);
    var y = origin.y + gui.px(panel_padding);

    y += headingAt(list, x, y, "QUEUE") + gui.px(queue_gap);
    if (targetRoll(state, ctx)) |r| {
        const info = ctx.library.rolls.items[r].info;
        y += lineAt(list, x, y, theme.text, gui.print("Into {s} · {s}", .{ info.name, info.stock orelse labels.filmKind(info.kind) })) + gui.px(group_gap);
    }
    const count = if (state.scanning or state.queue.items.len > 0) state.queue.items.len else state.boxes.items.len;
    const deep = if (state.capabilities) |caps| caps.deep else true;
    const summary = gui.print("{d} {s} · {d} dpi · {d}-bit", .{ count, if (count == 1) "frame" else "frames", state.dpi, @as(u32, if (deep) 48 else 24) });
    y += lineAt(list, x, y, theme.text_secondary, summary) + gui.px(queue_gap);

    const worker = state.worker;
    for (0..count) |i| {
        const item: QueueItem = if (i < state.queue.items.len) state.queue.items[i] else .{};
        c.ImGui_PushIDInt(@intCast(i));
        const row = drawQueueRow(list, x, y, width, i, item, worker);
        c.ImGui_PopID();
        y += row.height + gui.px(group_gap);
        if (row.check) if (state.queue_roll) |path| {
            // The frame is in the queue's roll, which Develop may not have open.
            const open = ctx.develop.roll_path;
            const same = open != null and std.mem.eql(u8, open.?, path);
            if (!same) ctx.develop.openRoll(ctx.gpa, ctx.io, ctx.library, path) catch |err| std.log.err("can't open the roll: {t}", .{err});
            ctx.develop.openForCrop(ctx.gpa, ctx.io, ctx.library, item.frame.?);
            next = .develop;
        };
    }
    if (count > 0) y += gui.px(queue_gap - group_gap);

    c.ImGui_SetCursorScreenPos(gui.vec2(x, y));
    const finishing = if (worker) |w| w.phase.load(.acquire) == .finishing else false;
    c.ImGui_BeginDisabled(!state.scanning or finishing);
    if (gui.buttonOf(.outline, if (finishing) "Finishing frame…" else "Cancel", gui.vec2(width / gui.scale, cancel_height))) {
        if (worker) |w| w.cancelQueue();
    }
    c.ImGui_EndDisabled();
    y += gui.px(cancel_height) + gui.px(queue_gap);
    _ = paragraphAt(list, x, y, width, theme.text_tertiary, "Finishes the current frame first");

    // Notes at the bottom, over a divider.
    const notes = [_][]const u8{ "Edges and base rechecked per scan", "Raw scans in scans/, never changed" };
    var notes_height: f32 = gui.px(10);
    for (notes, 0..) |n, i| notes_height += paragraphHeight(n, width) + if (i > 0) gui.px(4) else 0;
    const notes_top = origin.y + size.y - gui.px(panel_padding) - notes_height;
    c.ImDrawList_AddLine(list, gui.vec2(x, notes_top), gui.vec2(x + width, notes_top), theme.imU32(theme.divider));
    var ny = notes_top + gui.px(10);
    for (notes) |n| ny += paragraphAt(list, x, ny, width, theme.text_tertiary, n) + gui.px(4);
    return next;
}

/// The roll the scans go into: the queue's while it's scanning, or else the roll open in Develop.
fn targetRoll(state: *const State, ctx: context.Context) ?usize {
    if (state.scanning) if (state.queue_roll) |path| {
        for (ctx.library.rolls.items, 0..) |r, i| if (std.mem.eql(u8, r.path, path)) return i;
    };
    return ctx.develop.rollIndex(ctx.library);
}

/// Draws one frame in the queue. Returns its height, and whether its Check link was clicked.
fn drawQueueRow(list: *c.ImDrawList, x: f32, y: f32, width: f32, index: usize, item: QueueItem, worker: ?*Worker) struct { height: f32, check: bool } {
    const pad_x = gui.px(queue_row_padding_x);
    const pad_y = gui.px(queue_row_padding_y);
    const line = lineHeight();
    const running = item.status == .scanning;
    const height = 2 * pad_y + line + if (running) gui.px(group_gap + progress_height) else 0;
    const filled = item.status != .waiting and item.status != .cancelled;
    if (filled) c.ImDrawList_AddRectFilledEx(list, gui.vec2(x, y), gui.vec2(x + width, y + height), theme.imU32(theme.raised), gui.px(5), 0);
    if (running) c.ImDrawList_AddRectFilledEx(list, gui.vec2(x, y), gui.vec2(x + gui.px(2), y + height), theme.imU32(theme.accent), gui.px(5), c.ImDrawFlags_RoundCornersLeft);

    const ink = if (filled) theme.text else theme.text_secondary;
    const text_y = y + pad_y + (line - c.ImGui_GetFontSize()) / 2;
    fonts.push(.mono);
    c.ImDrawList_AddText(list, gui.vec2(x + pad_x, text_y), theme.imU32(ink), gui.print("{d}", .{index + 1}));
    fonts.pop();
    const finishing = if (worker) |w| w.phase.load(.acquire) == .finishing else false;
    const label: []const u8 = switch (item.status) {
        .waiting => "Waiting",
        .scanning => if (finishing) "Finishing" else if (worker != null and worker.?.progress.total.load(.acquire) == 0) "Starting" else "Scanning",
        .checking => "Checking edges",
        .done => "Scanned, base measured",
        .check_crop => "Scanned · crop to check",
        .failed => gui.print("Failed: {s}", .{errorText(item.err)}),
        .cancelled => "Cancelled",
    };
    const text_x = x + pad_x + gui.px(number_column + 10);
    c.ImDrawList_AddText(list, gui.vec2(text_x, text_y), theme.imU32(ink), gui.elideEnd(label, x + width - pad_x - text_x - gui.px(48)));
    const right = x + width - pad_x;
    var check = false;
    switch (item.status) {
        .done => drawTick(list, gui.vec2(right - gui.px(14), y + pad_y + (line - gui.px(14)) / 2), theme.ready),
        // Its edges weren't found again on the scan, so show a link to the frame's crop in
        // Develop. The link works while the rest of the queue scans, since the frame is already in
        // the roll.
        .check_crop => if (item.frame != null) {
            const link = "Check";
            const link_width = c.ImGui_CalcTextSize(link).x;
            const link_at = gui.vec2(right - link_width, text_y);
            c.ImGui_SetCursorScreenPos(gui.vec2(link_at.x - gui.px(4), y));
            check = c.ImGui_InvisibleButton("check", gui.vec2(link_width + gui.px(8), height), 0);
            const hovered = c.ImGui_IsItemHovered(0);
            if (hovered) {
                c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
                c.ImGui_SetTooltip("Edges not found · opens in Develop to crop");
            }
            c.ImDrawList_AddText(list, link_at, theme.imU32(if (hovered) theme.text else theme.accent), link);
        },
        .scanning => {
            const seconds = (c.SDL_GetTicks() -| item.started) / 1000;
            fonts.push(.mono);
            const time = gui.print("{d}:{d:0>2}", .{ seconds / 60, seconds % 60 });
            c.ImDrawList_AddText(list, gui.vec2(right - c.ImGui_CalcTextSize(time).x, text_y), theme.imU32(theme.text_secondary), time);
            fonts.pop();
            const bar_y = y + pad_y + line + gui.px(group_gap);
            const bar_far = gui.vec2(right, bar_y + gui.px(progress_height));
            c.ImDrawList_AddRectFilledEx(list, gui.vec2(x + pad_x, bar_y), bar_far, theme.imU32(theme.border), gui.px(3), 0);
            const done = if (worker) |w| w.progress.fraction() else 0;
            if (done > 0) c.ImDrawList_AddRectFilledEx(list, gui.vec2(x + pad_x, bar_y), gui.vec2(x + pad_x + (right - x - pad_x) * done, bar_far.y), theme.imU32(theme.accent), gui.px(3), 0);
        },
        else => {},
    }
    return .{ .height = height, .check = check };
}

fn errorText(err: ?anyerror) []const u8 {
    const e = err orelse return "unknown";
    return switch (e) {
        error.Busy => "scanner busy",
        error.Jammed => "jammed",
        error.CoverOpen => "cover open",
        error.Unsupported => "not supported",
        error.OutOfMemory => "out of memory",
        error.NotFound => "scanner gone",
        else => @errorName(e),
    };
}

// Receiving the preview, and keeping it with the roll.

fn setPreview(state: *State, ctx: context.Context, picture: scan_worker.Preview) void {
    if (state.preview) |*p| p.deinit(ctx.gpa, ctx.gpu);
    state.preview = .{
        .scan = picture.scan,
        .dpi = picture.dpi,
        .area = picture.area,
        .axis = if (picture.scan.height >= picture.scan.width) .y else .x,
    };
    uploadPreview(state, ctx);
    savePreview(state, ctx);
    const roll_index = ctx.develop.rollIndex(ctx.library);
    detect(state, ctx, roll_index);
    savePreviewSettings(state, ctx);
}

/// Puts the preview on the GPU the way the strip looks on a light table, with its base nearly
/// white through the mask.
fn uploadPreview(state: *State, ctx: context.Context) void {
    const preview = if (state.preview) |*p| p else return;
    if (preview.texture != null) return;
    const pixels = ctx.gpa.alloc([4]u8, preview.scan.pixels.len) catch return;
    defer ctx.gpa.free(pixels);
    const gain = minilab.light_table.gainForScan(preview.scan);
    minilab.light_table.toScreen(preview.scan.pixels, gain, pixels);
    preview.texture = Texture.upload(ctx.gpu, @intCast(preview.scan.width), @intCast(preview.scan.height), pixels) catch null;
    preview.base_colour = if (minilab.light_table.baseOfScan(preview.scan)) |base| colour: {
        var raw: [1][3]u16 = undefined;
        for (&raw[0], base) |*r, b| r.* = @intFromFloat(@round(b * image.full_scale));
        var shown: [1][4]u8 = undefined;
        minilab.light_table.toScreen(&raw, gain, &shown);
        break :colour shown[0];
    } else null;
}

fn rollFile(state: *const State, ctx: context.Context, name: []const u8) ?[]u8 {
    const path = state.roll_path orelse return null;
    return std.fs.path.join(ctx.gpa, &.{ path, name }) catch null;
}

fn savePreview(state: *State, ctx: context.Context) void {
    const preview = state.preview orelse return;
    const path = rollFile(state, ctx, preview_file) orelse return;
    defer ctx.gpa.free(path);
    const bytes = minilab.pnm.write(ctx.gpa, u16, preview.scan) catch return;
    defer ctx.gpa.free(bytes);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = bytes }) catch |err| std.log.err("can't save the preview: {t}", .{err});
}

fn savePreviewSettings(state: *State, ctx: context.Context) void {
    state.boxes_dirty = false;
    const preview = state.preview orelse return;
    const path = rollFile(state, ctx, preview_settings_file) orelse return;
    defer ctx.gpa.free(path);
    const saved: Saved = .{
        .dpi = preview.dpi,
        .area = preview.area,
        .axis = preview.axis,
        .opening = preview.opening,
        .opening_middle = preview.opening_middle,
        .detected = preview.detected,
        .boxes = state.boxes.items,
    };
    const bytes = std.json.Stringify.valueAlloc(ctx.gpa, saved, .{ .whitespace = .indent_2 }) catch return;
    defer ctx.gpa.free(bytes);
    std.Io.Dir.cwd().writeFile(ctx.io, .{ .sub_path = path, .data = bytes }) catch |err| std.log.err("can't save the frames: {t}", .{err});
}

fn loadPreview(state: *State, ctx: context.Context, roll_index: usize) !void {
    const gpa = ctx.gpa;
    const settings_path = rollFile(state, ctx, preview_settings_file) orelse return;
    defer gpa.free(settings_path);
    const image_path = rollFile(state, ctx, preview_file) orelse return;
    defer gpa.free(image_path);
    const cwd = std.Io.Dir.cwd();
    const json = try cwd.readFileAlloc(ctx.io, settings_path, gpa, .limited(1 << 20));
    defer gpa.free(json);
    const parsed = try std.json.parseFromSlice(Saved, gpa, json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const bytes = try cwd.readFileAlloc(ctx.io, image_path, gpa, .limited(max_preview_bytes));
    defer gpa.free(bytes);
    const picture = try minilab.pnm.read(gpa, bytes);
    const saved = parsed.value;
    state.preview = .{
        .scan = picture,
        .dpi = saved.dpi,
        .area = saved.area,
        .axis = saved.axis,
        .opening = saved.opening,
        .opening_middle = saved.opening_middle,
        .detected = saved.detected,
    };
    try state.boxes.appendSlice(gpa, saved.boxes);
    state.selected = if (state.boxes.items.len > 0) 0 else null;
    uploadPreview(state, ctx);
    if (!saved.detected) {
        detect(state, ctx, roll_index);
        savePreviewSettings(state, ctx);
    }
}

// Drawing helpers.

/// The height of one line of text, at the design's line height.
fn lineHeight() f32 {
    return c.ImGui_GetFontSize() * line_spacing;
}

/// Draws `text` on one line at `x`, `y`, centred in the design's line height. Returns the line
/// height.
fn lineAt(list: *c.ImDrawList, x: f32, y: f32, color: theme.Color, text: []const u8) f32 {
    const shown = gui.print("{s}", .{text});
    c.ImDrawList_AddText(list, gui.vec2(x, y + (lineHeight() - c.ImGui_GetFontSize()) / 2), theme.imU32(color), shown);
    return lineHeight();
}

/// Draws a panel heading: 12 pixels, semibold, in the secondary colour. Returns its height.
fn headingAt(list: *c.ImDrawList, x: f32, y: f32, text: [:0]const u8) f32 {
    fonts.pushSized(.semibold, 12);
    defer fonts.pop();
    return lineAt(list, x, y, theme.text_secondary, text);
}

/// Draws a title like "Frame 4" at 18 pixels, then `detail` in the secondary colour on the same
/// baseline. Returns the row's height.
fn titleAt(list: *c.ImDrawList, x: f32, y: f32, title: [:0]const u8, detail: ?[:0]const u8) f32 {
    fonts.pushSized(.semibold, 18);
    const title_size = c.ImGui_CalcTextSize(title);
    const height = c.ImGui_GetFontSize() * line_spacing;
    const title_top = y + (height - c.ImGui_GetFontSize()) / 2;
    c.ImDrawList_AddText(list, gui.vec2(x, title_top), theme.imU32(theme.text), title);
    const baseline = title_top + c.ImGui_GetFontSize() * 0.8;
    fonts.pop();
    if (detail) |d| c.ImDrawList_AddText(list, gui.vec2(x + title_size.x + gui.px(10), baseline - c.ImGui_GetFontSize() * 0.8), theme.imU32(theme.text_secondary), d);
    return height;
}

/// Splits `text` into the lines it wraps to at `width`.
fn wrapLines(text: []const u8, width: f32, buffer: [][]const u8) [][]const u8 {
    const font = c.ImGui_GetFont();
    const size = c.ImGui_GetFontSize();
    var n: usize = 0;
    var rest = text;
    while (rest.len > 0 and n < buffer.len) {
        const start: [*]const u8 = rest.ptr;
        const end_ptr = c.ImFont_CalcWordWrapPosition(font, size, start, start + rest.len, width);
        var cut: usize = @intFromPtr(end_ptr) - @intFromPtr(start);
        if (cut == 0) cut = rest.len;
        buffer[n] = std.mem.trimEnd(u8, rest[0..cut], " ");
        n += 1;
        rest = std.mem.trimStart(u8, rest[cut..], " ");
    }
    return buffer[0..n];
}

fn paragraphHeight(text: []const u8, width: f32) f32 {
    var buffer: [16][]const u8 = undefined;
    return @as(f32, @floatFromInt(wrapLines(text, width, &buffer).len)) * lineHeight();
}

/// Draws `text` wrapped at `width`, with the design's line height. Returns its height.
fn paragraphAt(list: *c.ImDrawList, x: f32, y: f32, width: f32, color: theme.Color, text: []const u8) f32 {
    var buffer: [16][]const u8 = undefined;
    const lines = wrapLines(text, width, &buffer);
    for (lines, 0..) |l, i| _ = lineAt(list, x, y + @as(f32, @floatFromInt(i)) * lineHeight(), color, l);
    return @as(f32, @floatFromInt(lines.len)) * lineHeight();
}

/// Draws a row of choices that wraps at `width`, or with `fill`, a single row whose choices share
/// the width. Moves `y` past it and returns the choice that was clicked.
fn pills(labels_: []const [:0]const u8, chosen: usize, x: f32, y: *f32, width: f32, fill: bool) ?usize {
    var clicked: ?usize = null;
    const gap = gui.px(pill_gap);
    const height = gui.px(pill_height);
    const even = (width - gap * @as(f32, @floatFromInt(labels_.len - 1))) / @as(f32, @floatFromInt(labels_.len));
    var at = x;
    var row_y = y.*;
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(10), (height - c.ImGui_GetFontSize()) / 2));
    defer c.ImGui_PopStyleVar();
    for (labels_, 0..) |label, i| {
        const w = if (fill) even else c.ImGui_CalcTextSize(label).x + gui.px(20) + 2;
        if (!fill and at > x and at + w > x + width) {
            at = x;
            row_y += height + gap;
        }
        c.ImGui_SetCursorScreenPos(gui.vec2(at, row_y));
        c.ImGui_PushIDInt(@intCast(i));
        if (gui.buttonOf(if (i == chosen) .selected else .unselected, label, gui.vec2(w / gui.scale, pill_height))) clicked = i;
        c.ImGui_PopID();
        at += w + gap;
    }
    y.* = row_y + height;
    return clicked;
}

/// Draws a slider row for the frame tools: a 110-pixel label, the slider, the value in a 56-pixel
/// column, and a button that resets it to `default`. Moves `y` past it. Returns true when the
/// value changed.
fn sliderRowAt(x: f32, y: *f32, width: f32, label: []const u8, value: *f32, min: f32, max: f32, comptime format: []const u8, default: f32) bool {
    // A range input is 20 pixels high in the design, and the slider fills the row.
    const height = gui.px(slider_row_height);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(10), (height - c.ImGui_GetFontSize()) / 2));
    defer c.ImGui_PopStyleVar();
    const list = c.ImGui_GetWindowDrawList();
    _ = lineAt(list, x, y.* + (height - lineHeight()) / 2, theme.text_secondary, label);
    const slider_x = x + gui.px(slider_label_column + 10);
    const slider_width = width - gui.px(slider_label_column + 10 + 10 + slider_value_column + gui.reset_space);
    c.ImGui_SetCursorScreenPos(gui.vec2(slider_x, y.*));
    var changed = gui.slider(gui.print("{s}", .{label}), value, min, max, slider_width / gui.scale);
    fonts.push(.mono);
    const shown = signed(format, value.*);
    const shown_width = c.ImGui_CalcTextSize(shown).x;
    const value_right = x + width - gui.px(gui.reset_space);
    c.ImDrawList_AddText(list, gui.vec2(value_right - shown_width, y.* + (height - c.ImGui_GetFontSize()) / 2), theme.imU32(theme.text), shown);
    fonts.pop();
    const reset_at = gui.vec2(x + width - gui.px(gui.reset_size), y.* + (height - gui.px(gui.reset_size)) / 2);
    if (gui.resetButton(gui.print("reset {s}", .{label}), reset_at, shown, signed(format, default))) {
        value.* = default;
        changed = true;
    }
    y.* += height;
    return changed;
}

/// Formats `v` with `format`, without a minus sign on values that round to zero.
fn signed(comptime format: []const u8, v: f32) [:0]const u8 {
    return if (v < -0.05) gui.print("−" ++ format, .{-v}) else gui.print(format, .{@abs(v)});
}

/// A check box drawn the way the design has it here: the label in the text colour, 8 pixels after
/// the box.
fn checkbox(label: [:0]const u8, checked: *bool) bool {
    const box = gui.px(14);
    const label_size = c.ImGui_CalcTextSize(label);
    const height = lineHeight();
    const origin = c.ImGui_GetCursorScreenPos();
    const clicked = c.ImGui_InvisibleButton(label, gui.vec2(box + gui.px(8) + label_size.x, height), 0);
    if (clicked) checked.* = !checked.*;
    const hovered = c.ImGui_IsItemHovered(0);
    const list = c.ImGui_GetWindowDrawList();
    const min = gui.vec2(origin.x, origin.y + (height - box) / 2);
    const max = gui.vec2(min.x + box, min.y + box);
    if (checked.*) {
        c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(theme.accent), gui.px(3), 0);
        const ink = theme.imU32(theme.on_accent);
        c.ImDrawList_AddLineEx(list, gui.vec2(min.x + gui.px(3), min.y + gui.px(7)), gui.vec2(min.x + gui.px(6), min.y + gui.px(10)), ink, gui.px(1.8));
        c.ImDrawList_AddLineEx(list, gui.vec2(min.x + gui.px(6), min.y + gui.px(10)), gui.vec2(min.x + gui.px(11), min.y + gui.px(4)), ink, gui.px(1.8));
    } else {
        c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(if (hovered) theme.control_hover else theme.control), gui.px(3), 0);
        c.ImDrawList_AddRectEx(list, min, max, theme.imU32(theme.border), gui.px(3), 1, 0);
    }
    c.ImDrawList_AddText(list, gui.vec2(max.x + gui.px(8), origin.y + (height - label_size.y) / 2), theme.imU32(theme.text), label.ptr);
    return clicked;
}

/// A button with a border, secondary text and no fill, for the design's less important actions.
fn quietButton(label: [:0]const u8, size: gui.Vec2) bool {
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Button, theme.withAlpha(theme.page, 0));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonHovered, theme.control_hover);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ButtonActive, theme.control_hover);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Border, theme.border);
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_Text, theme.text_secondary);
    defer c.ImGui_PopStyleColorEx(5);
    return c.ImGui_ButtonEx(label.ptr, gui.vec2(gui.px(size.x), gui.px(size.y)));
}

/// Draws a tick, 14 pixels square, at `corner`.
fn drawTick(list: *c.ImDrawList, corner: gui.Vec2, color: theme.Color) void {
    const ink = theme.imU32(color);
    const t = gui.px(1.6);
    c.ImDrawList_AddLineEx(list, gui.vec2(corner.x + gui.px(2), corner.y + gui.px(7.5)), gui.vec2(corner.x + gui.px(5), corner.y + gui.px(10.5)), ink, t);
    c.ImDrawList_AddLineEx(list, gui.vec2(corner.x + gui.px(5), corner.y + gui.px(10.5)), gui.vec2(corner.x + gui.px(12), corner.y + gui.px(3.5)), ink, t);
}

/// Draws an "i" in a circle, `size` square, at `corner`.
fn drawInfo(list: *c.ImDrawList, corner: gui.Vec2, size: f32, color: theme.Color) void {
    const ink = theme.imU32(color);
    const unit = size / 16;
    const centre = gui.vec2(corner.x + 8 * unit, corner.y + 8 * unit);
    c.ImDrawList_AddCircleEx(list, centre, 6.5 * unit, ink, 24, 1.5 * unit);
    c.ImDrawList_AddLineEx(list, gui.vec2(centre.x, corner.y + 4.5 * unit), gui.vec2(centre.x, corner.y + 9 * unit), ink, 1.5 * unit);
    c.ImDrawList_AddLineEx(list, gui.vec2(centre.x, corner.y + 11 * unit), gui.vec2(centre.x, corner.y + 11.5 * unit), ink, 1.5 * unit);
}

const dash = 5;
const dash_gap = 3;

fn drawDashedQuad(list: *c.ImDrawList, corners: [4]gui.Vec2, color: u32, thickness: f32) void {
    for (0..4) |i| gui.dashedLine(list, corners[i], corners[(i + 1) % 4], color, thickness, gui.px(dash), gui.px(dash_gap));
}

/// A ratio the way people say it (3:2, 4:3, 1:1), or else just the number.
fn ratioLabel(r: f32) []const u8 {
    const known = [_]struct { f32, []const u8 }{ .{ 1.5, "3:2" }, .{ 1.0, "1:1" }, .{ 4.0 / 3.0, "4:3" }, .{ 0.75, "3:4" }, .{ 2.0 / 3.0, "2:3" }, .{ 1.25, "5:4" }, .{ 0.8, "4:5" }, .{ 2.0, "2:1" }, .{ 3.0, "3:1" } };
    for (known) |k| if (@abs(r - k[0]) < 0.02) return k[1];
    return gui.print("{d:.2}:1", .{r});
}

test "boxes crop by their inset" {
    const box: Box = .{ .along = 100, .across = 50, .length = 100, .height = 60, .inset = 5 };
    const crop = box.crop();
    try std.testing.expectApproxEqAbs(@as(f32, 90), crop.length, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 54), crop.height, 1e-4);
    try std.testing.expectEqual(@as(f32, 100), crop.along);
}

test "a vertical strip's boxes map to the scanner" {
    const preview: Preview = .{
        .scan = .{ .width = 390, .height = 2886, .pixels = &.{} },
        .dpi = .{ 300, 300 },
        .area = .{ .x = 0, .y = 0, .width = 33.02, .height = 244.348 },
        .axis = .y,
    };
    const px_per_mm: f32 = 300.0 / mm_per_inch;
    const box: Box = .{ .along = 50 * px_per_mm, .across = 16 * px_per_mm, .length = 36 * px_per_mm, .height = 24 * px_per_mm };
    const area = preview.toScanner(preview.rect(box));
    try std.testing.expectApproxEqAbs(@as(f32, 4), area.x, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 32), area.y, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 24), area.width, 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 36), area.height, 1e-3);
}
