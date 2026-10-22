//! The Develop workspace: the frames of the open roll, the viewer, and the develop settings.
//! Settings are saved to the roll as they change. Without a roll open, it develops scans opened
//! on their own, and saves nothing.

const std = @import("std");
const c = @import("c");
const negscan = @import("negscan");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const labels = @import("labels.zig");
const Texture = @import("../platform/texture.zig").Texture;
const Frame = @import("frame.zig").Frame;
const Library = @import("library.zig").Library;
const shortcuts = @import("shortcuts.zig");
const file_dialog = @import("../platform/file_dialog.zig");
const Dialog = file_dialog.Dialog;

/// What "Import .cube…" opens.
const develop = negscan.develop;
const look = negscan.look;
const roll = negscan.roll;

/// Sizes in the design's pixels.
const frames_width = 210;
const settings_width = 340;
const histogram_height = 80;
const frame_columns = 2;
const frame_gap = 8;
const thumb_height = 58;
const bottom_bar_height = 36;

/// What the viewer shows.
const Compare = enum { split, negative, positive };
/// How big the viewer shows the frame.
const Zoom = enum { fit, actual };
/// What a click on the frame does.
const Picking = enum { none, base, neutral };

/// A frame's look and settings at one time: what undo goes back to, and what copying copies.
const Snapshot = struct {
    look: look.Id,
    settings: develop.Settings,

    fn of(frame: *const Frame) Snapshot {
        return .{ .look = frame.look, .settings = frame.settings };
    }
};

/// A crop being drawn: the box, in the pixels of the frame's whole reduced scan.
const CropEdit = struct {
    min: [2]f32,
    max: [2]f32,
    /// The crop the frame had, for Cancel, and the turns and mirroring to apply after.
    before: ?negscan.image.Area,
    turns: u2,
    mirrored: bool,
    /// What a drag moves, and the box's width over height while a corner moves.
    grip: ?Grip = null,
    aspect: f32 = 1,

    const Grip = enum { box, top_left, top_right, bottom_right, bottom_left };
};

/// The most changes undo goes back through.
const history_depth = 100;

/// Snapshots, newest last; the oldest drops out when it's full.
const History = struct {
    items: [history_depth]Snapshot = undefined,
    len: usize = 0,

    fn push(history: *History, snapshot: Snapshot) void {
        if (history.len == history_depth) {
            std.mem.copyForwards(Snapshot, history.items[0 .. history_depth - 1], history.items[1..]);
            history.len -= 1;
        }
        history.items[history.len] = snapshot;
        history.len += 1;
    }

    fn pop(history: *History) ?Snapshot {
        if (history.len == 0) return null;
        history.len -= 1;
        return history.items[history.len];
    }
};

pub const State = struct {
    /// The folder of the roll being developed, or null for loose scans.
    roll_path: ?[]u8 = null,
    /// Scans opened on their own, outside any roll, while no roll is open.
    loose: std.ArrayList([]u8) = .empty,
    selected: ?usize = null,
    /// The selected frame, loaded, or null until it is.
    frame: ?Frame = null,
    /// The frame that failed to load, so that it isn't tried again every frame.
    failed: ?usize = null,
    /// The positive as shown, with clipping marked if asked, and on the GPU.
    shown: std.ArrayList([4]u8) = .empty,
    positive: ?Texture = null,
    negative: ?Texture = null,
    /// Whether `shown` and the textures are out of date.
    shown_stale: bool = true,
    negative_stale: bool = true,
    /// Whether the frame's settings changed since the last finished change.
    dirty: bool = false,
    /// The settings after the last finished change, and the ones before it, for undo.
    committed: ?Snapshot = null,
    undo: History = .{},
    redo: History = .{},
    /// Settings copied to paste on other frames.
    clipboard: ?Snapshot = null,
    /// The Sync confirmation asked for from the keyboard.
    ask_sync: bool = false,
    /// What Sync copies.
    sync: SyncGroups = .{},
    /// Whether the crop tool starts once the selected frame has loaded.
    crop_on_open: bool = false,
    /// Whether the settings had a scrollbar last time: the histogram over them keeps their width.
    settings_scroll: bool = false,
    /// What the last calibration found, for the line under its button.
    calibration_note: gui.Line(160) = .{},
    /// The crop being drawn, while the crop tool is on.
    cropping: ?CropEdit = null,

    compare: Compare = .split,
    /// Where the split is, as a share of the frame's width.
    split: f32 = 0.5,
    zoom: Zoom = .fit,
    /// How far the frame is moved at 100%, in screen pixels from centred.
    pan: gui.Vec2 = .{ .x = 0, .y = 0 },
    clipping: bool = true,
    picking: Picking = .none,
    range: develop.Range = .midtones,
    /// The looks the drop-down lists, read when it opens.
    look_choices: std.ArrayList(look.Catalog.Choice) = .empty,
    /// The dialog for importing a .cube file as a look.
    cube_dialog: Dialog = .{ .filters = &file_dialog.cube_files },
    /// Why the last .cube didn't import, until another look is chosen.
    import_failed: ?anyerror = null,

    pub fn deinit(state: *State, gpa: std.mem.Allocator, gpu: *c.SDL_GPUDevice) void {
        state.look_choices.deinit(gpa);
        state.cube_dialog.deinit(gpa);
        state.closeFrame(gpa);
        state.clearLoose(gpa);
        state.loose.deinit(gpa);
        state.shown.deinit(gpa);
        if (state.roll_path) |p| gpa.free(p);
        if (state.positive) |*t| t.release(gpu);
        if (state.negative) |*t| t.release(gpu);
    }

    /// The open roll's index in `library`, or null for loose scans.
    pub fn rollIndex(state: *const State, library: *const Library) ?usize {
        return library.find(state.roll_path orelse return null);
    }

    /// Opens the roll at `path`, after saving the frame open now, and selects its first frame.
    pub fn openRoll(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, path: []const u8) !void {
        state.save(io, library);
        state.closeFrame(gpa);
        state.clearLoose(gpa);
        const copy = try gpa.dupe(u8, path);
        if (state.roll_path) |p| gpa.free(p);
        state.roll_path = copy;
        const index = library.find(path) orelse return error.RollNotFound;
        state.selected = if (library.rolls.items[index].frames.items.len > 0) 0 else null;
    }

    /// Opens the scan at `path` on its own, closing the open roll, if any.
    pub fn openLoose(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, path: []const u8) !void {
        if (state.roll_path) |p| {
            state.save(io, library);
            gpa.free(p);
            state.roll_path = null;
        }
        state.closeFrame(gpa);
        try state.loose.append(gpa, try gpa.dupe(u8, path));
        state.selected = state.loose.items.len - 1;
    }

    /// Selects frame `index`, after saving the frame open now.
    /// Selects frame `index` and starts the crop tool on it once it has loaded.
    pub fn openForCrop(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, index: usize) void {
        state.select(gpa, io, library, index);
        state.crop_on_open = true;
    }

    pub fn select(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, index: usize) void {
        if (state.selected == index and state.frame != null) return;
        // Another frame ends the crop tool, keeping its crop, before this frame's settings go.
        if (state.cropping != null) state.endCrop(gpa, io, library, true) catch |err| std.log.err("crop failed: {t}", .{err});
        state.save(io, library);
        state.closeFrame(gpa);
        state.selected = index;
    }

    /// How many frames there are to choose from.
    fn count(state: *const State, library: *const Library) usize {
        if (state.rollIndex(library)) |r| return library.rolls.items[r].frames.items.len;
        return state.loose.items.len;
    }

    fn closeFrame(state: *State, gpa: std.mem.Allocator) void {
        if (state.frame) |*f| f.close(gpa);
        state.frame = null;
        state.failed = null;
        state.dirty = false;
        state.committed = null;
        state.undo = .{};
        state.redo = .{};
        state.picking = .none;
        state.cropping = null;
        state.pan = .{ .x = 0, .y = 0 };
    }

    fn clearLoose(state: *State, gpa: std.mem.Allocator) void {
        for (state.loose.items) |p| gpa.free(p);
        state.loose.clearRetainingCapacity();
    }

    /// Finishes the change under way: undo can go back over it, and the roll keeps it.
    pub fn save(state: *State, io: std.Io, library: *Library) void {
        if (!state.dirty) return;
        state.dirty = false;
        const frame = state.frame orelse return;
        if (state.committed) |before| state.undo.push(before);
        state.redo = .{};
        state.committed = .of(&frame);
        state.write(io, library);
    }

    /// Goes back to the settings before the last change, or forward again after undoing.
    fn step(state: *State, io: std.Io, library: *Library, direction: enum { back, forward }) void {
        state.save(io, library);
        const frame = if (state.frame) |*f| f else return;
        const from, const to = if (direction == .back) .{ &state.undo, &state.redo } else .{ &state.redo, &state.undo };
        const snapshot = from.pop() orelse return;
        to.push(.of(frame));
        frame.look = snapshot.look;
        frame.settings = snapshot.settings;
        frame.stale = true;
        state.committed = snapshot;
        state.write(io, library);
    }

    /// Gives the frame `snapshot`'s settings, as its own: its own film base unless the copied
    /// one was picked, and the automatic balances worked out again for this frame.
    fn paste(state: *State, snapshot: Snapshot) void {
        const frame = if (state.frame) |*f| f else return;
        var settings = snapshot.settings;
        // The film base is this frame's own, unless it was picked by hand.
        switch (settings.base_source) {
            .measured => settings.base = frame.whole.thinnest,
            .gaps => settings.base = frame.gap_base orelse frame.whole.thinnest,
            .picked => {},
        }
        frame.settings = settings;
        frame.look = snapshot.look;
        switch (settings.white_balance) {
            .auto_neutral, .auto_warm, .auto_cool, .average => |mode| frame.rebalance(mode, null),
            .stock => if (frame.stock_slopes != null) frame.rebalance(.stock, null),
            .picked => {},
        }
        state.changed();
    }

    /// Writes the frame's settings to its roll, and marks it developed.
    fn write(state: *State, io: std.Io, library: *Library) void {
        const frame = state.frame orelse return;
        const r = state.rollIndex(library) orelse return;
        const index = state.selected orelse return;
        const saved = &library.rolls.items[r].frames.items[index];
        saved.look = frame.look;
        saved.settings = frame.settings;
        saved.developed = true;
        // The crop tool shows the whole scan; the frame's crop is still the one it started with.
        if (state.cropping) |edit| {
            saved.crop = edit.before;
            saved.quarter_turns = edit.turns;
            saved.mirrored = edit.mirrored;
        } else {
            saved.crop = frame.crop;
            saved.quarter_turns = frame.quarter_turns;
            saved.mirrored = frame.mirrored;
        }
        library.rolls.items[r].saveFrame(io, index) catch |err| std.log.err("can't save frame {d}: {t}", .{ index + 1, err });
        library.invalidate(.{ .roll = r, .frame = index });
    }

    /// Writes the frame's crop and turns to its roll, without marking it developed.
    fn writeGeometry(state: *State, io: std.Io, library: *Library) void {
        const frame = state.frame orelse return;
        const r = state.rollIndex(library) orelse return;
        const index = state.selected orelse return;
        const saved = &library.rolls.items[r].frames.items[index];
        // The crop tool shows the whole scan; the frame's crop is still the one it started with.
        if (state.cropping) |edit| {
            saved.crop = edit.before;
            saved.quarter_turns = edit.turns;
            saved.mirrored = edit.mirrored;
        } else {
            saved.crop = frame.crop;
            saved.quarter_turns = frame.quarter_turns;
            saved.mirrored = frame.mirrored;
        }
        library.rolls.items[r].saveFrame(io, index) catch |err| std.log.err("can't save frame {d}: {t}", .{ index + 1, err });
        library.invalidate(.{ .roll = r, .frame = index });
    }

    /// The roll's format, or 135 full frame for a scan opened on its own.
    fn format(state: *const State, library: *const Library) negscan.formats.Format {
        const r = state.rollIndex(library) orelse return negscan.formats.Standard.default.format();
        return library.rolls.items[r].info.format.format();
    }

    /// The resolution the frame was scanned at, when known.
    fn dpi(state: *const State, library: *const Library) ?f32 {
        const r = state.rollIndex(library) orelse return null;
        const index = state.selected orelse return null;
        const rl = library.rolls.items[r];
        return rl.frames.items[index].dpi orelse rl.info.dpi;
    }

    /// Starts the crop tool: the whole scan shows, with the crop on it, or the detected frame
    /// when there's no crop yet.
    fn startCrop(state: *State, gpa: std.mem.Allocator, library: *const Library) !void {
        const frame = if (state.frame) |*f| f else return;
        const area = frame.crop orelse frame.detect(gpa, state.format(library), state.dpi(library)) catch fallbackCrop(frame, state.format(library));
        const turns = frame.quarter_turns;
        const mirrored = frame.mirrored;
        const before = frame.crop;
        try frame.setGeometry(gpa, null, 0, false);
        state.shown_stale = true;
        state.negative_stale = true;
        const scale: f32 = @floatCast(frame.scale());
        state.cropping = .{
            .min = .{ @as(f32, @floatFromInt(area.x)) / scale, @as(f32, @floatFromInt(area.y)) / scale },
            .max = .{ @as(f32, @floatFromInt(area.x + area.width)) / scale, @as(f32, @floatFromInt(area.y + area.height)) / scale },
            .before = before,
            .turns = turns,
            .mirrored = mirrored,
        };
        state.picking = .none;
    }

    /// Ends the crop tool, keeping the crop when `keep`, else going back to the one before.
    fn endCrop(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, keep: bool) !void {
        const edit = state.cropping orelse return;
        state.cropping = null;
        const frame = if (state.frame) |*f| f else return;
        state.shown_stale = true;
        state.negative_stale = true;
        if (!keep) return frame.setGeometry(gpa, edit.before, edit.turns, edit.mirrored);
        const scale: f32 = @floatCast(frame.scale());
        const x: usize = @intFromFloat(@max(0, @round(edit.min[0] * scale)));
        const y: usize = @intFromFloat(@max(0, @round(edit.min[1] * scale)));
        const area: negscan.image.Area = .{
            .x = @min(x, frame.scan_width - 1),
            .y = @min(y, frame.scan_height - 1),
            .width = @max(1, @min(frame.scan_width - @min(x, frame.scan_width - 1), @as(usize, @intFromFloat(@round((edit.max[0] - edit.min[0]) * scale))))),
            .height = @max(1, @min(frame.scan_height - @min(y, frame.scan_height - 1), @as(usize, @intFromFloat(@round((edit.max[1] - edit.min[1]) * scale))))),
        };
        try frame.setGeometry(gpa, area, edit.turns, edit.mirrored);
        state.afterGeometry(io, library);
    }

    /// Turns the frame a quarter turn: 1 clockwise, 3 anticlockwise.
    fn turn(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, quarter_turns: u2) !void {
        if (state.cropping) |*edit| {
            edit.turns +%= quarter_turns;
            return;
        }
        const frame = if (state.frame) |*f| f else return;
        try frame.setGeometry(gpa, frame.crop, frame.quarter_turns +% quarter_turns, frame.mirrored);
        state.shown_stale = true;
        state.negative_stale = true;
        state.afterGeometry(io, library);
    }

    /// Mirrors the frame left to right.
    fn mirror(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library) !void {
        // Mirroring comes before the turns, and mirroring a turned picture equals turning the
        // mirrored one the other way: so an odd number of turns flips to its opposite, and the
        // frame mirrors left to right as the user sees it.
        if (state.cropping) |*edit| {
            edit.mirrored = !edit.mirrored;
            edit.turns = oppositeTurns(edit.turns);
            return;
        }
        const frame = if (state.frame) |*f| f else return;
        const turns = oppositeTurns(frame.quarter_turns);
        try frame.setGeometry(gpa, frame.crop, turns, !frame.mirrored);
        state.shown_stale = true;
        state.negative_stale = true;
        state.afterGeometry(io, library);
    }

    /// After the crop or turns changed: an undeveloped frame's automatic settings are measured
    /// on its new area; then the roll keeps the geometry.
    fn afterGeometry(state: *State, io: std.Io, library: *Library) void {
        const frame = if (state.frame) |*f| f else return;
        const developed = if (state.rollIndex(library)) |r| library.rolls.items[r].frames.items[state.selected.?].developed else false;
        if (!developed) {
            frame.measure(frame.settings.kind);
            // Measured afresh for the new crop: undo goes back from here, not to the old values.
            state.committed = .of(frame);
        }
        state.writeGeometry(io, library);
    }

    /// Loads the selected frame if it isn't yet: with its saved settings when it was developed,
    /// or automatic ones.
    fn load(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library) !void {
        if (state.frame != null) return;
        const index = state.selected orelse return;
        if (state.failed == index) return;
        errdefer state.failed = index;
        var frame: Frame = if (state.rollIndex(library)) |r| frame: {
            const rl = &library.rolls.items[r];
            if (index >= rl.frames.items.len) {
                state.selected = null;
                return;
            }
            const saved = rl.frames.items[index];
            const scan_path = try rl.scanPath(gpa, index);
            defer gpa.free(scan_path);
            var frame: Frame = try .load(gpa, io, scan_path, gui.print("Frame {d}", .{index + 1}), saved.crop, saved.quarter_turns, saved.mirrored);
            if (saved.width == 0) {
                // Rolls from before the size was recorded: the thumbnails need it for crops.
                rl.frames.items[index].width = frame.scan_width;
                rl.frames.items[index].height = frame.scan_height;
                rl.saveFrame(io, index) catch |err| std.log.err("can't save frame {d}: {t}", .{ index + 1, err });
            }
            if (saved.crop == null) {
                // A frame not cropped yet gets the detected one, when detection is sure of it.
                if (frame.detect(gpa, rl.info.format.format(), saved.dpi orelse rl.info.dpi)) |area| {
                    try frame.setGeometry(gpa, area, saved.quarter_turns, saved.mirrored);
                    rl.frames.items[index].crop = area;
                    rl.saveFrame(io, index) catch |err| std.log.err("can't save frame {d}: {t}", .{ index + 1, err });
                    library.invalidate(.{ .roll = r, .frame = index });
                } else |_| {}
            }
            frame.stock_slopes = stockSlopes(library, rl);
            frame.gap_base = rl.baseFor(index);
            frame.base_from_roll = frame.gap_base != null and (saved.film_base == null or !std.meta.eql(frame.gap_base.?, saved.film_base.?));
            frame.fillNegative();
            // The look holds for undeveloped frames too, as Export takes it.
            frame.look = saved.look;
            if (saved.developed) frame.settings = saved.settings else frame.measure(saved.settings.kind);
            break :frame frame;
        } else frame: {
            const path = state.loose.items[index];
            var frame: Frame = try .load(gpa, io, path, std.fs.path.basename(path), null, 0, false);
            frame.measure(.colour_negative);
            break :frame frame;
        };
        errdefer frame.close(gpa);
        try state.shown.resize(gpa, frame.rendered.len);
        state.committed = .of(&frame);
        state.frame = frame;
        state.shown_stale = true;
        state.negative_stale = true;
    }

    /// Re-renders the frame if its settings changed, and puts what the viewer shows on the GPU.
    fn refresh(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, gpu: *c.SDL_GPUDevice) !void {
        const frame = if (state.frame) |*f| f else return;
        if (frame.stale) {
            try frame.render(gpa, io, &library.looks);
            state.shown_stale = true;
        }
        const width: u32 = @intCast(frame.preview.width);
        const height: u32 = @intCast(frame.preview.height);
        if (state.shown_stale) {
            // The crop tool shows the whole scan, so the rendering changes size with it.
            try state.shown.resize(gpa, frame.rendered.len);
            for (state.shown.items, frame.rendered) |*out, p| {
                out.* = p;
                if (!state.clipping) continue;
                if (@max(p[0], p[1], p[2]) == 255) out.* = theme.rgba8(theme.red) else if (@min(p[0], p[1], p[2]) == 0) out.* = theme.rgba8(theme.blue);
            }
            try upload(&state.positive, gpu, width, height, state.shown.items);
            state.shown_stale = false;
        }
        if (state.negative_stale) {
            try upload(&state.negative, gpu, width, height, frame.negative);
            state.negative_stale = false;
        }
    }

    /// Whether the selected frame is loaded and drawn, or failed to load: for a screenshot,
    /// which waits for it.
    pub fn settled(state: *const State) bool {
        if (state.selected == null or state.failed != null) return true;
        const frame = state.frame orelse return false;
        return !frame.stale and !state.shown_stale;
    }

    /// The settings changed: render again, and save once the control is let go.
    /// The look drop-down: the built-in looks, then imported LUTs and fitted looks, and a way to
    /// import another .cube.
    fn drawLook(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library) void {
        const frame = &state.frame.?;
        c.ImGui_SetNextItemWidth(-std.math.floatMin(f32));
        c.ImGui_SetNextWindowSizeConstraints(gui.vec2(0, 0), gui.vec2(std.math.floatMax(f32), gui.px(360)), null, null);
        const open = c.ImGui_BeginCombo("##look", gui.print("{s}", .{frame.look.label()}).ptr, c.ImGuiComboFlags_NoArrowButton | c.ImGuiComboFlags_HeightLargest);
        gui.chevron();
        if (!open) return;
        defer c.ImGui_EndCombo();
        if (c.ImGui_IsWindowAppearing()) {
            state.look_choices.deinit(gpa);
            state.look_choices = library.looks.choices(gpa, io) catch .empty;
        }
        var group: look.Catalog.Choice.Group = .builtin;
        for (state.look_choices.items, 0..) |*choice, i| {
            if (choice.group != group) {
                group = choice.group;
                c.ImGui_SeparatorText(switch (group) {
                    .builtin => "Built in",
                    .imported => "Imported LUTs",
                    .fitted => "Fitted looks",
                });
            }
            c.ImGui_PushIDInt(@intCast(i));
            if (c.ImGui_SelectableEx(gui.print("{s}", .{choice.id.label()}).ptr, choice.id.eql(&frame.look), 0, gui.vec2(0, 0))) {
                frame.look = choice.id;
                state.import_failed = null;
                state.changed();
            }
            c.ImGui_PopID();
        }
        c.ImGui_Separator();
        if (c.ImGui_SelectableEx("Import .cube…", false, 0, gui.vec2(0, 0))) state.cube_dialog.show(gpa, io);
        if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("A 3D or 1D LUT that expects sRGB or Rec. 709 input. It's copied into the library's Looks folder.");
    }

    /// The calibration of the roll's scanner for Stock balance: how far along it is, and a button
    /// that measures this roll. Only for colour negatives of a stock with a preset.
    fn drawCalibration(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, r: usize) void {
        const rl = &library.rolls.items[r];
        if (rl.info.kind != .colour_negative or labels.stockGamma(rl.info.stock) == null) return;
        gui.rowLabel("");
        const scanner = scannerOf(rl.info) orelse {
            gui.paragraph(theme.text_tertiary, "Stock balance needs to know the roll's scanner, and this roll doesn't say.");
            return;
        };
        const measured = library.calibrations.rolls(scanner);
        var included = false;
        for (measured) |m| included = included or std.mem.eql(u8, m.roll, rl.info.name);
        const status = if (measured.len == 0)
            gui.print("Stock balance needs the {s} calibrated once, from a roll of a stock with a preset and {d} frames or more.", .{ scanner, negscan.calibration.min_frames })
        else
            gui.print("The {s} is calibrated from {d} {s}{s}.", .{ scanner, measured.len, if (measured.len == 1) "roll" else "rolls", if (included) ", this one among them" else "" });
        gui.paragraph(theme.text_tertiary, status);
        gui.rowLabel("");
        c.ImGui_BeginDisabled(rl.frames.items.len < negscan.calibration.min_frames);
        const label: [:0]const u8 = if (measured.len == 0) "Calibrate from this roll" else if (included) "Measure this roll again" else "Add this roll";
        if (gui.button(label)) state.calibrate(gpa, io, library, r, scanner);
        c.ImGui_EndDisabled();
        if (c.ImGui_IsItemHovered(c.ImGuiHoveredFlags_AllowWhenDisabled)) c.ImGui_SetTooltip("Measures every frame's neutral balance; their median against the stock's datasheet is the scanner's. Any stock with a preset calibrates it for all stocks.");
        if (state.calibration_note.len > 0) {
            gui.rowLabel("");
            gui.paragraph(theme.text_tertiary, state.calibration_note.text());
        }
    }

    /// Measures roll `r`'s frames and adds them to the calibration of `scanner`.
    fn calibrate(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, r: usize, scanner: []const u8) void {
        const rl = &library.rolls.items[r];
        const gamma = labels.stockGamma(rl.info.stock) orelse return;
        var slopes: std.ArrayList([3]f32) = .empty;
        defer slopes.deinit(gpa);
        for (0..rl.frames.items.len) |i| {
            var thumbnail = rl.frameThumbnail(gpa, io, i) catch continue;
            defer thumbnail.deinit(gpa);
            const stats = develop.FrameStatistics.measure(gpa, thumbnail) catch continue;
            const base = rl.baseFor(i) orelse stats.whole.thinnest;
            const s = develop.neutralSlopes(.colour_negative, base, stats.centre) orelse continue;
            slopes.append(gpa, s) catch return;
        }
        const factors = negscan.calibration.measure(slopes.items, gamma) orelse {
            state.calibration_note.set("Only {d} frames could be measured; it takes {d}.", .{ slopes.items.len, negscan.calibration.min_frames });
            return;
        };
        library.calibrations.add(io, scanner, .{ .roll = rl.info.name, .stock = rl.info.stock.?, .frames = @intCast(slopes.items.len), .factors = factors }) catch |err| {
            state.calibration_note.set("The calibration couldn't be saved: {t}.", .{err});
            return;
        };
        state.calibration_note.set("Measured {d} frames: against the datasheet, this scanner's red is ×{d:.2} and its blue ×{d:.2}.", .{ slopes.items.len, factors[0], factors[2] });
        const frame = if (state.frame) |*f| f else return;
        frame.stock_slopes = stockSlopes(library, rl);
        if (frame.settings.white_balance == .stock) {
            frame.rebalance(.stock, null);
            state.changed();
        }
    }

    /// Imports the .cube files chosen in the dialog, and gives the frame the last one.
    fn importCubes(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library) void {
        const chosen = state.cube_dialog.take(gpa, io);
        defer Dialog.free(gpa, chosen);
        for (chosen) |path| {
            const id = library.looks.import(gpa, io, path) catch |err| {
                std.log.err("can't import {s}: {t}", .{ path, err });
                state.import_failed = err;
                continue;
            };
            state.import_failed = null;
            if (state.frame) |*f| {
                f.look = id;
                state.changed();
            }
        }
    }

    fn changed(state: *State) void {
        if (state.frame) |*f| f.stale = true;
        state.dirty = true;
    }

    /// Back to the automatic settings; in a roll, the frame counts as undeveloped again.
    fn reset(state: *State, io: std.Io, library: *Library) void {
        state.save(io, library);
        const frame = if (state.frame) |*f| f else return;
        if (state.committed) |before| state.undo.push(before);
        state.redo = .{};
        const kind = frame.settings.kind;
        frame.settings = .{};
        frame.look = .neutral;
        frame.measure(kind);
        state.committed = .of(frame);
        const r = state.rollIndex(library) orelse return;
        const index = state.selected.?;
        const rl = &library.rolls.items[r];
        rl.frames.items[index].look = .neutral;
        rl.frames.items[index].settings = frame.settings;
        rl.frames.items[index].developed = false;
        rl.saveFrame(io, index) catch |err| std.log.err("can't save frame {d}: {t}", .{ index + 1, err });
        library.invalidate(.{ .roll = r, .frame = index });
    }

    /// Does what the keyboard asked. Returns a message for the header, when there's one.
    pub fn handle(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, keys: std.EnumSet(shortcuts.Command)) ?[]const u8 {
        const total = state.count(library);
        if (state.selected) |current| {
            if (keys.contains(.next) and current + 1 < total) state.select(gpa, io, library, current + 1);
            if (keys.contains(.previous) and current > 0) state.select(gpa, io, library, current - 1);
        }
        if (total > 0) {
            if (keys.contains(.first)) state.select(gpa, io, library, 0);
            if (keys.contains(.last)) state.select(gpa, io, library, total - 1);
        }
        if (keys.contains(.zoom_toggle)) state.zoom = if (state.zoom == .fit) .actual else .fit;
        if (keys.contains(.zoom_in)) state.zoom = .actual;
        if (keys.contains(.zoom_out)) state.zoom = .fit;
        if (state.zoom == .fit) state.pan = .{ .x = 0, .y = 0 };
        if (keys.contains(.clipping)) {
            state.clipping = !state.clipping;
            state.shown_stale = true;
        }
        if (keys.contains(.before)) state.compare = if (state.compare == .negative) .positive else .negative;
        if (keys.contains(.split)) state.compare = if (state.compare == .split) .positive else .split;
        if (keys.contains(.cancel)) state.picking = .none;
        if (keys.contains(.crop)) {
            if (state.cropping != null) state.endCrop(gpa, io, library, true) catch |err| std.log.err("crop failed: {t}", .{err}) else state.startCrop(gpa, library) catch |err| std.log.err("crop failed: {t}", .{err});
        }
        if (keys.contains(.confirm) and state.cropping != null) state.endCrop(gpa, io, library, true) catch |err| std.log.err("crop failed: {t}", .{err});
        if (keys.contains(.cancel) and state.cropping != null) state.endCrop(gpa, io, library, false) catch |err| std.log.err("crop failed: {t}", .{err});
        if (keys.contains(.turn_right)) state.turn(gpa, io, library, 1) catch |err| std.log.err("turn failed: {t}", .{err});
        if (keys.contains(.turn_left)) state.turn(gpa, io, library, 3) catch |err| std.log.err("turn failed: {t}", .{err});
        if (keys.contains(.mirror)) state.mirror(gpa, io, library) catch |err| std.log.err("mirror failed: {t}", .{err});

        const frame = if (state.frame) |*f| f else return null;
        // The crop tool has the frame: its settings wait until the crop is done.
        if (state.cropping != null) return null;
        if (keys.contains(.white_balance)) state.picking = if (state.picking == .neutral) .none else .neutral;
        if (keys.contains(.base)) state.picking = if (state.picking == .base) .none else .base;
        if (keys.contains(.undo)) state.step(io, library, .back);
        if (keys.contains(.redo)) state.step(io, library, .forward);
        if (keys.contains(.automatic)) {
            frame.measure(frame.settings.kind);
            state.changed();
        }
        if (keys.contains(.reset)) state.reset(io, library);
        if (keys.contains(.sync) and state.rollIndex(library) != null) state.ask_sync = true;
        if (keys.contains(.copy_settings)) {
            state.clipboard = .of(frame);
            return gui.print("Copied the settings of {s}.", .{frame.name});
        }
        if (keys.contains(.paste_settings)) {
            const copied = state.clipboard orelse return "Nothing copied yet: copy a frame's settings first.";
            state.paste(copied);
        }
        if (keys.contains(.paste_previous)) {
            const r = state.rollIndex(library) orelse return null;
            const index = state.selected orelse return null;
            if (index == 0) return "There is no frame before this one.";
            const previous = library.rolls.items[r].frames.items[index - 1];
            if (!previous.developed) return "The frame before this one isn't developed.";
            state.paste(.{ .look = previous.look, .settings = previous.settings });
        }
        return null;
    }
};

/// The same turns the other way round: 1 and 3 swap, 0 and 2 stay.
fn oppositeTurns(quarter_turns: u2) u2 {
    return 0 -% quarter_turns;
}

/// The crop when detection finds no frame: the format's shape at the full extent across the
/// film, which runs along the scan's longer side, in the middle.
fn fallbackCrop(frame: *const Frame, format: negscan.formats.Format) negscan.image.Area {
    const w = frame.scan_width;
    const h = frame.scan_height;
    const ratio = format.ratio();
    if (w >= h) {
        const width = @min(w, @as(usize, @intFromFloat(@as(f32, @floatFromInt(h)) * ratio)));
        return .{ .x = (w - width) / 2, .y = 0, .width = width, .height = h };
    }
    const height = @min(h, @as(usize, @intFromFloat(@as(f32, @floatFromInt(w)) * ratio)));
    return .{ .x = 0, .y = (h - height) / 2, .width = w, .height = height };
}

fn upload(texture: *?Texture, gpu: *c.SDL_GPUDevice, width: u32, height: u32, pixels: []const [4]u8) !void {
    if (texture.*) |*t| {
        if (t.width == width and t.height == height) return t.replace(gpu, pixels);
        t.release(gpu);
        texture.* = null;
    }
    texture.* = try .upload(gpu, width, height, pixels);
}

/// Draws the workspace; without `sides`, the viewer alone.
pub fn draw(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, gpu: *c.SDL_GPUDevice, sides: bool) void {
    state.load(gpa, io, library) catch |err| std.log.err("can't load frame {d}: {t}", .{ (state.selected orelse 0) + 1, err });
    if (state.crop_on_open and state.frame != null) {
        state.crop_on_open = false;
        if (state.cropping == null) state.startCrop(gpa, library) catch |err| std.log.err("crop failed: {t}", .{err});
    }
    state.importCubes(gpa, io, library);
    state.refresh(gpa, io, library, gpu) catch |err| std.log.err("rendering failed: {t}", .{err});
    const roll_index = state.rollIndex(library);

    const top = c.ImGui_GetCursorScreenPos();
    const available = c.ImGui_GetContentRegionAvail();
    const left = if (sides) gui.px(frames_width) else 0;
    const viewer_width = available.x - if (sides) gui.px(frames_width + settings_width) else 0;

    if (sides) {
        c.ImGui_SetCursorScreenPos(top);
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(12), gui.px(12)));
        _ = c.ImGui_BeginChild("frames", gui.vec2(gui.px(frames_width), available.y), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_None);
        c.ImGui_PopStyleVar();
        if (drawFrames(state, gpa, library, roll_index)) |index| state.select(gpa, io, library, index);
        gui.edge(.right);
        c.ImGui_EndChild();
    }

    c.ImGui_SetCursorScreenPos(gui.vec2(top.x + left, top.y));
    c.ImGui_PushStyleColorImVec4(c.ImGuiCol_ChildBg, theme.viewer);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(0, 0));
    _ = c.ImGui_BeginChild("viewer", gui.vec2(viewer_width, available.y), c.ImGuiChildFlags_None, c.ImGuiWindowFlags_NoScrollbar | c.ImGuiWindowFlags_NoScrollWithMouse);
    c.ImGui_PopStyleVar();
    drawViewer(state, gpa, io, library, roll_index);
    c.ImGui_EndChild();
    c.ImGui_PopStyleColor();

    if (sides) {
        c.ImGui_SetCursorScreenPos(gui.vec2(top.x + left + viewer_width, top.y));
        drawSettingsColumn(state, gpa, io, library, roll_index, available.y);
    }

    // Save once a slider is let go, not on every step of a drag.
    if (state.dirty and !c.ImGui_IsAnyItemActive()) state.save(io, library);
}

/// The frames to choose from. Returns the one clicked.
fn drawFrames(state: *State, gpa: std.mem.Allocator, library: *Library, roll_index: ?usize) ?usize {
    var clicked: ?usize = null;
    const total = state.count(library);
    const header_y = c.ImGui_GetCursorPosY();
    gui.heading("FRAMES");
    if (roll_index) |r| {
        const counted = gui.print("{d} of {d}", .{ library.rolls.items[r].developedCount(), total });
        c.ImGui_SameLineEx(c.ImGui_GetContentRegionAvail().x + c.ImGui_GetCursorPosX() - c.ImGui_CalcTextSize(counted).x, 0);
        c.ImGui_SetCursorPosY(header_y);
        gui.textColored(theme.text_tertiary, counted);
        if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("Developed of all frames");
    }
    c.ImGui_Dummy(gui.vec2(0, gui.px(10) - c.ImGui_GetStyle().*.ItemSpacing.y * 2));

    if (roll_index == null) {
        if (total == 0) gui.paragraph(theme.text_tertiary, "Drop a scan on the window to open it.");
        for (state.loose.items, 0..) |path, i| {
            c.ImGui_PushIDInt(@intCast(i));
            if (c.ImGui_SelectableEx(gui.print("{s}", .{std.fs.path.basename(path)}), state.selected == i, 0, gui.vec2(0, 0))) clicked = i;
            c.ImGui_PopID();
        }
    } else if (total == 0) {
        gui.paragraph(theme.text_tertiary, "Drop scans on the window to add them to this roll.");
    } else {
        const r = roll_index.?;
        const list = c.ImGui_GetWindowDrawList();
        const gap = gui.px(frame_gap);
        const cell_width = (c.ImGui_GetContentRegionAvail().x - gap * (frame_columns - 1)) / frame_columns;
        const height = gui.px(thumb_height);
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gap, gap));
        defer c.ImGui_PopStyleVar();
        for (0..total) |i| {
            if (i % frame_columns != 0) c.ImGui_SameLine();
            c.ImGui_PushIDInt(@intCast(i));
            defer c.ImGui_PopID();
            const corner = c.ImGui_GetCursorScreenPos();
            if (c.ImGui_InvisibleButton("frame", gui.vec2(cell_width, height), 0)) clicked = i;
            const far = gui.vec2(corner.x + cell_width, corner.y + height);
            if (library.thumbnail(gpa, .{ .roll = r, .frame = i })) |t| {
                gui.imageCover(list, t.ref(), t.width, t.height, corner, far, gui.px(3));
            } else {
                c.ImDrawList_AddRectFilledEx(list, corner, far, theme.imU32(theme.control), gui.px(3), 0);
            }
            const selected = state.selected == i;
            gui.outline(corner, far, if (selected) theme.accent else theme.border, gui.px(3), if (selected) gui.px(2) else 1);
            fonts.pushSized(.mono, 10);
            const number = gui.print("{d:0>2}", .{i + 1});
            const size = c.ImGui_CalcTextSize(number);
            const label_min = gui.vec2(corner.x + gui.px(4), far.y - gui.px(3) - size.y);
            c.ImDrawList_AddRectFilledEx(list, label_min, gui.vec2(label_min.x + size.x + gui.px(6), far.y - gui.px(3)), theme.imU32(theme.withAlpha(theme.header, 0.75)), gui.px(2), 0);
            c.ImDrawList_AddText(list, gui.vec2(label_min.x + gui.px(3), label_min.y), theme.imU32(theme.text), number);
            fonts.pop();
        }
    }

    // Notes about the roll at the bottom of the column.
    const notes_height = c.ImGui_GetTextLineHeight() * 2 + gui.px(6) + gui.px(12);
    const bottom = c.ImGui_GetWindowHeight() - notes_height;
    if (c.ImGui_GetCursorPosY() < bottom) c.ImGui_SetCursorPosY(bottom);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gui.px(8), gui.px(6)));
    defer c.ImGui_PopStyleVar();
    if (roll_index) |r| {
        gui.paragraph(theme.text_tertiary, labels.rollFormatNote(library.rolls.items[r].info.format));
        const base = if (state.frame) |f| f.settings.base_source else .measured;
        gui.paragraph(theme.text_tertiary, switch (base) {
            .measured => "Base measured on each frame.",
            .gaps => "Base from the gaps between frames.",
            .picked => "Base picked on this frame.",
        });
    } else {
        gui.paragraph(theme.text_tertiary, "Scans opened on their own aren't saved.");
    }
    return clicked;
}

fn drawViewer(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, roll_index: ?usize) void {
    const origin = c.ImGui_GetCursorScreenPos();
    const size = c.ImGui_GetContentRegionAvail();
    const list = c.ImGui_GetWindowDrawList();
    // The tallest thing on the toolbar is the Split / Negative / Positive box.
    const toolbar_height = gui.px(26 + 6 + 16) + 1;
    const info_height = gui.px(12 * 1.4 + 16) + 1;

    // The toolbar.
    c.ImDrawList_AddRectFilled(list, origin, gui.vec2(origin.x + size.x, origin.y + toolbar_height), theme.imU32(theme.page));
    c.ImDrawList_AddLine(list, gui.vec2(origin.x, origin.y + toolbar_height - 1), gui.vec2(origin.x + size.x, origin.y + toolbar_height - 1), theme.imU32(theme.divider));
    c.ImGui_SetCursorScreenPos(gui.vec2(origin.x + gui.px(12), origin.y + gui.px(8)));
    if (gui.segmented("compare", &.{ "Split", "Negative", "Positive" }, @backingInt(state.compare))) |picked| state.compare = @fromBackingInt(@intCast(picked));
    const controls_y = origin.y + (toolbar_height - 1 - c.ImGui_GetFrameHeight()) / 2;
    c.ImGui_SameLineEx(0, gui.px(12));
    c.ImGui_SetCursorScreenPos(gui.vec2(c.ImGui_GetCursorScreenPos().x, controls_y));
    if (gui.button("Fit")) {
        state.zoom = .fit;
        state.pan = .{ .x = 0, .y = 0 };
    }
    shortcuts.tooltip("The whole frame in the viewer", .zoom_out);
    c.ImGui_SameLineEx(0, gui.px(8));
    if (gui.button("100%")) state.zoom = .actual;
    shortcuts.tooltip("One pixel of the preview to one of the screen; drag to move", .zoom_in);
    c.ImGui_SameLineEx(0, gui.px(12));
    if (gui.checkbox("Clipping", &state.clipping)) state.shown_stale = true;
    shortcuts.tooltip("Marks clipped highlights red and clipped shadows blue", .clipping);
    c.ImGui_SameLineEx(0, gui.px(12));
    c.ImGui_BeginDisabled(state.frame == null);
    const crop_corner = c.ImGui_GetCursorScreenPos();
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(10 + 14 + 6) / 2 + gui.px(5), c.ImGui_GetStyle().*.FramePadding.y));
    const crop_clicked = gui.buttonOf(if (state.cropping != null) .selected else .normal, "  Crop", gui.vec2(0, 0));
    c.ImGui_PopStyleVar();
    drawCropIcon(list, gui.vec2(crop_corner.x + gui.px(10), crop_corner.y + (c.ImGui_GetFrameHeight() - gui.px(14)) / 2));
    c.ImGui_EndDisabled();
    shortcuts.tooltip("Crop and turn the frame; the box keeps the roll's format", .crop);
    if (crop_clicked) {
        if (state.cropping != null) state.endCrop(gpa, io, library, true) catch |err| std.log.err("crop failed: {t}", .{err}) else state.startCrop(gpa, library) catch |err| std.log.err("crop failed: {t}", .{err});
    }
    if (state.cropping == null) {
        // Turning is quicker here than through the crop tool.
        c.ImGui_BeginDisabled(state.frame == null);
        c.ImGui_SameLineEx(0, gui.px(8));
        if (turnButton(list, "turn left", false)) state.turn(gpa, io, library, 3) catch |err| std.log.err("turn failed: {t}", .{err});
        shortcuts.tooltip("A quarter turn anticlockwise", .turn_left);
        c.ImGui_SameLineEx(0, gui.px(4));
        if (turnButton(list, "turn right", true)) state.turn(gpa, io, library, 1) catch |err| std.log.err("turn failed: {t}", .{err});
        shortcuts.tooltip("A quarter turn clockwise", .turn_right);
        c.ImGui_EndDisabled();
    }
    if (state.cropping != null) {
        c.ImGui_SameLineEx(0, gui.px(8));
        if (gui.button("Auto")) {
            const frame = &state.frame.?;
            if (frame.detect(gpa, state.format(library), state.dpi(library))) |area| {
                const scale: f32 = @floatCast(frame.scale());
                state.cropping.?.min = .{ @as(f32, @floatFromInt(area.x)) / scale, @as(f32, @floatFromInt(area.y)) / scale };
                state.cropping.?.max = .{ @as(f32, @floatFromInt(area.x + area.width)) / scale, @as(f32, @floatFromInt(area.y + area.height)) / scale };
            } else |_| {}
        }
        if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("Finds the frame on the scan.");
        c.ImGui_SameLineEx(0, gui.px(8));
        if (gui.button("Turn left")) state.turn(gpa, io, library, 3) catch |err| std.log.err("turn failed: {t}", .{err});
        shortcuts.tooltip("A quarter turn anticlockwise, applied after the crop", .turn_left);
        c.ImGui_SameLineEx(0, gui.px(8));
        if (gui.button("Turn right")) state.turn(gpa, io, library, 1) catch |err| std.log.err("turn failed: {t}", .{err});
        shortcuts.tooltip("A quarter turn clockwise, applied after the crop", .turn_right);
        c.ImGui_SameLineEx(0, gui.px(8));
        if (gui.buttonOf(if (state.cropping.?.mirrored) .selected else .normal, "Mirror", gui.vec2(0, 0))) state.mirror(gpa, io, library) catch |err| std.log.err("mirror failed: {t}", .{err});
        shortcuts.tooltip("Left to right, for a scan made from the wrong side of the film", .mirror);
        c.ImGui_SameLineEx(0, gui.px(8));
        if (gui.buttonOf(.primary, "Done", gui.vec2(0, 0))) state.endCrop(gpa, io, library, true) catch |err| std.log.err("crop failed: {t}", .{err});
        shortcuts.tooltip("Keeps the crop", .confirm);
    }
    const pipeline = if (state.frame) |*f| (if (f.look.isNeutral()) "Scanner RGB, linear → sRGB" else gui.print("Scanner RGB, linear → {s} → sRGB", .{f.look.label()})) else "";
    // The toolbar's last control: the pipeline shows only where it doesn't run under the controls,
    // which the crop tool's buttons often do.
    const controls_end = c.ImGui_GetItemRectMax().x;
    fonts.pushSized(.mono, 12);
    const pipeline_size = c.ImGui_CalcTextSize(pipeline);
    const pipeline_x = origin.x + size.x - gui.px(12) - pipeline_size.x;
    if (pipeline_x > controls_end + gui.px(16)) c.ImDrawList_AddText(list, gui.vec2(pipeline_x, origin.y + (toolbar_height - pipeline_size.y) / 2), theme.imU32(theme.text_tertiary), pipeline);
    fonts.pop();

    // The info line along the bottom.
    const info_top = origin.y + size.y - info_height;
    c.ImDrawList_AddRectFilled(list, gui.vec2(origin.x, info_top), gui.vec2(origin.x + size.x, origin.y + size.y), theme.imU32(theme.page));
    c.ImDrawList_AddLine(list, gui.vec2(origin.x, info_top), gui.vec2(origin.x + size.x, info_top), theme.imU32(theme.divider));
    if (state.frame) |frame| {
        fonts.pushSized(.mono, 12);
        var x = origin.x + gui.px(12);
        const y = info_top + (info_height - c.ImGui_GetTextLineHeight()) / 2;
        var items: [4][:0]const u8 = undefined;
        var n: usize = 0;
        items[n] = gui.print("{s}", .{frame.name});
        n += 1;
        if (roll_index) |r| {
            items[n] = labels.sizeAndRatio(library.rolls.items[r].info.format);
            n += 1;
        }
        items[n] = gui.print("scan {d} × {d} px, 48-bit linear", .{ frame.scan_width, frame.scan_height });
        n += 1;
        if (frame.crop) |area| {
            const turned = if (frame.quarter_turns == 0) "" else gui.print(", turned {d}°", .{@as(u16, frame.quarter_turns) * 90});
            items[n] = gui.print("crop {d} × {d} px{s}{s}", .{ area.width, area.height, turned, if (frame.mirrored) ", mirrored" else "" });
            n += 1;
        }
        for (items[0..n]) |item| {
            c.ImDrawList_AddText(list, gui.vec2(x, y), theme.imU32(theme.text_tertiary), item);
            x += c.ImGui_CalcTextSize(item).x + gui.px(20);
        }
        fonts.pop();
    }

    // The frame.
    const area_min = gui.vec2(origin.x, origin.y + toolbar_height);
    const area_max = gui.vec2(origin.x + size.x, info_top);
    drawPicture(state, library, area_min, area_max);
}

fn drawPicture(state: *State, library: *const Library, area_min: gui.Vec2, area_max: gui.Vec2) void {
    const frame = if (state.frame) |*f| f else {
        if (state.failed) |index| {
            c.ImGui_SetCursorScreenPos(gui.vec2(area_min.x + gui.px(24), area_min.y + gui.px(24)));
            gui.textColored(theme.text_tertiary, gui.print("Frame {d} couldn't be loaded; the log says why.", .{index + 1}));
        }
        return;
    };
    const positive = state.positive orelse return;
    const negative = state.negative orelse return;
    const list = c.ImGui_GetWindowDrawList();
    const width: f32 = @floatFromInt(positive.width);
    const height: f32 = @floatFromInt(positive.height);
    const room = gui.vec2(area_max.x - area_min.x - gui.px(48), area_max.y - area_min.y - gui.px(64));
    if (room.x <= 0 or room.y <= 0) return;
    const scale = switch (state.zoom) {
        .fit => @min(room.x / width, room.y / height),
        .actual => 1,
    };
    const shown = gui.vec2(width * scale, height * scale);
    const centre = gui.vec2((area_min.x + area_max.x) / 2 + state.pan.x, (area_min.y + area_max.y) / 2 + state.pan.y);
    const min = gui.vec2(centre.x - shown.x / 2, centre.y - shown.y / 2);
    const max = gui.vec2(min.x + shown.x, min.y + shown.y);

    // Hit area: the whole viewer between the bars, for panning, picking and moving the split.
    c.ImGui_SetCursorScreenPos(area_min);
    _ = c.ImGui_InvisibleButton("picture", gui.vec2(area_max.x - area_min.x, area_max.y - area_min.y), 0);
    const hovered = c.ImGui_IsItemHovered(0);
    const active = c.ImGui_IsItemActive();
    const mouse = c.ImGui_GetMousePos();
    const inside = mouse.x >= min.x and mouse.x < max.x and mouse.y >= min.y and mouse.y < max.y;
    const split_x = min.x + shown.x * state.split;
    const near_split = state.compare == .split and @abs(mouse.x - split_x) < gui.px(8) and inside;
    if (state.cropping) |*edit| {
        c.ImDrawList_PushClipRect(list, area_min, area_max, true);
        defer c.ImDrawList_PopClipRect(list);
        c.ImDrawList_AddImage(list, positive.ref(), min, max);
        cropTool(edit, list, min, scale, .{ width, height }, hovered, active, state.format(library).ratio());
        return;
    }
    if (state.picking != .none and hovered and inside) {
        c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_Hand);
        if (c.ImGui_IsMouseClicked(0)) {
            const x: usize = @intFromFloat(std.math.clamp((mouse.x - min.x) / scale, 0, width - 1));
            const y: usize = @intFromFloat(std.math.clamp((mouse.y - min.y) / scale, 0, height - 1));
            switch (state.picking) {
                .base => frame.pickBase(x, y),
                .neutral => frame.pickNeutral(x, y),
                .none => {},
            }
            state.picking = .none;
            state.dirty = true;
        }
    } else if (active and c.ImGui_IsMouseDragging(0, 0)) {
        const delta = c.ImGui_GetIO().*.MouseDelta;
        if (state.compare == .split and (near_split or state.zoom == .fit)) {
            state.split = std.math.clamp((mouse.x - min.x) / shown.x, 0, 1);
        } else if (state.zoom == .actual) {
            state.pan.x += delta.x;
            state.pan.y += delta.y;
        }
    }
    if (near_split and state.picking == .none) c.ImGui_SetMouseCursor(c.ImGuiMouseCursor_ResizeEW);

    c.ImDrawList_PushClipRect(list, area_min, area_max, true);
    defer c.ImDrawList_PopClipRect(list);
    switch (state.compare) {
        .positive => c.ImDrawList_AddImage(list, positive.ref(), min, max),
        .negative => c.ImDrawList_AddImage(list, negative.ref(), min, max),
        .split => {
            c.ImDrawList_AddImageEx(list, negative.ref(), min, gui.vec2(split_x, max.y), gui.vec2(0, 0), gui.vec2(state.split, 1), 0xFFFFFFFF);
            c.ImDrawList_AddImageEx(list, positive.ref(), gui.vec2(split_x, min.y), max, gui.vec2(state.split, 0), gui.vec2(1, 1), 0xFFFFFFFF);
        },
    }
    gui.outline(gui.vec2(min.x - 1, min.y - 1), gui.vec2(max.x + 1, max.y + 1), theme.border, 0, 1);
    if (state.compare == .split) {
        const amber = theme.imU32(theme.accent);
        c.ImDrawList_AddRectFilled(list, gui.vec2(split_x - gui.px(1), min.y), gui.vec2(split_x + gui.px(1), max.y), amber);
        c.ImDrawList_AddCircleFilled(list, gui.vec2(split_x, (min.y + max.y) / 2), gui.px(11), amber, 24);
        tag(list, gui.vec2(min.x + gui.px(10), min.y + gui.px(10)), "Negative", .left);
        tag(list, gui.vec2(max.x - gui.px(10), min.y + gui.px(10)), "Positive", .right);
    }
    if (state.picking != .none) {
        const what = if (state.picking == .base) "Click the film base: the rebate, or between frames. Esc cancels." else "Click something that should be neutral grey. Esc cancels.";
        const size = c.ImGui_CalcTextSize(what);
        tag(list, gui.vec2((min.x + max.x) / 2 + size.x / 2 + gui.px(8), max.y - gui.px(10) - size.y - gui.px(4)), what, .right);
    }
}

/// The crop box over the frame drawn at `origin`, `scale` screen pixels to the image's: darkened
/// outside, in thirds inside, with handles at the corners. A drag inside moves it; a drag at a
/// corner sizes it, keeping the format's shape (`ratio`) the way up it already is.
/// The smallest crop box, in preview pixels.
const min_crop = 16;

fn cropTool(edit: *CropEdit, list: *c.ImDrawList, origin: gui.Vec2, scale: f32, size: [2]f32, hovered: bool, active: bool, ratio: f32) void {
    const mouse = c.ImGui_GetMousePos();
    const p = [2]f32{ (mouse.x - origin.x) / scale, (mouse.y - origin.y) / scale };
    const reach = gui.px(12) / scale;
    const grips = [_]CropEdit.Grip{ .top_left, .top_right, .bottom_right, .bottom_left };
    const corners = [_][2]f32{ .{ edit.min[0], edit.min[1] }, .{ edit.max[0], edit.min[1] }, .{ edit.max[0], edit.max[1] }, .{ edit.min[0], edit.max[1] } };
    var under: ?CropEdit.Grip = null;
    for (grips, corners) |grip, corner| {
        if (@abs(p[0] - corner[0]) < reach and @abs(p[1] - corner[1]) < reach) under = grip;
    }
    if (under == null and p[0] > edit.min[0] and p[0] < edit.max[0] and p[1] > edit.min[1] and p[1] < edit.max[1]) under = .box;
    if (hovered and c.ImGui_IsMouseClicked(0)) {
        edit.grip = under;
        edit.aspect = (edit.max[0] - edit.min[0]) / @max(1, edit.max[1] - edit.min[1]);
    }
    if (!active) edit.grip = null;
    const shown = edit.grip orelse under;
    if (shown) |grip| c.ImGui_SetMouseCursor(switch (grip) {
        .box => c.ImGuiMouseCursor_ResizeAll,
        .top_left, .bottom_right => c.ImGuiMouseCursor_ResizeNWSE,
        .top_right, .bottom_left => c.ImGuiMouseCursor_ResizeNESW,
    });

    if (edit.grip) |grip| if (c.ImGui_IsMouseDragging(0, 0)) switch (grip) {
        .box => {
            const delta = c.ImGui_GetIO().*.MouseDelta;
            for (0..2) |axis| {
                const d = (if (axis == 0) delta.x else delta.y) / scale;
                const moved = std.math.clamp(d, -edit.min[axis], size[axis] - edit.max[axis]);
                edit.min[axis] += moved;
                edit.max[axis] += moved;
            }
        },
        else => {
            // The opposite corner stays; the dragged one follows the mouse within the shape.
            const index = std.mem.indexOfScalar(CropEdit.Grip, &grips, grip).?;
            const fixed = corners[(index + 2) % 4];
            const to = [2]f32{ std.math.clamp(p[0], 0, size[0]), std.math.clamp(p[1], 0, size[1]) };
            const aspect = if (edit.aspect >= 1) @max(ratio, 1 / ratio) else @min(ratio, 1 / ratio);
            var w = @max(@abs(to[0] - fixed[0]), min_crop);
            var h = @max(@abs(to[1] - fixed[1]), min_crop);
            if (w / h > aspect) w = h * aspect else h = w / aspect;
            // Toward the mouse, unless the fixed corner is against that edge of the image: then
            // the box grows the other way, so that it never shrinks to nothing.
            const right = if (to[0] >= fixed[0]) size[0] - fixed[0] >= min_crop else fixed[0] < min_crop;
            const down = if (to[1] >= fixed[1]) size[1] - fixed[1] >= min_crop else fixed[1] < min_crop;
            // Keep the box on the image.
            w = @max(@min(w, if (right) size[0] - fixed[0] else fixed[0]), @min(min_crop, size[0]));
            h = @max(@min(h, if (down) size[1] - fixed[1] else fixed[1]), @min(min_crop, size[1]));
            if (w / h > aspect) w = h * aspect else h = w / aspect;
            edit.min = .{ if (right) fixed[0] else fixed[0] - w, if (down) fixed[1] else fixed[1] - h };
            edit.max = .{ edit.min[0] + w, edit.min[1] + h };
        },
    };

    const box_min = gui.vec2(origin.x + edit.min[0] * scale, origin.y + edit.min[1] * scale);
    const box_max = gui.vec2(origin.x + edit.max[0] * scale, origin.y + edit.max[1] * scale);
    const image_max = gui.vec2(origin.x + size[0] * scale, origin.y + size[1] * scale);
    const shade = theme.imU32(theme.withAlpha(theme.header, 0.7));
    c.ImDrawList_AddRectFilled(list, origin, gui.vec2(image_max.x, box_min.y), shade);
    c.ImDrawList_AddRectFilled(list, gui.vec2(origin.x, box_max.y), image_max, shade);
    c.ImDrawList_AddRectFilled(list, gui.vec2(origin.x, box_min.y), gui.vec2(box_min.x, box_max.y), shade);
    c.ImDrawList_AddRectFilled(list, gui.vec2(box_max.x, box_min.y), gui.vec2(image_max.x, box_max.y), shade);
    const thirds = theme.imU32(theme.withAlpha(theme.text, 0.35));
    for ([_]f32{ 1.0 / 3.0, 2.0 / 3.0 }) |t| {
        const x = box_min.x + (box_max.x - box_min.x) * t;
        const y = box_min.y + (box_max.y - box_min.y) * t;
        c.ImDrawList_AddLine(list, gui.vec2(x, box_min.y), gui.vec2(x, box_max.y), thirds);
        c.ImDrawList_AddLine(list, gui.vec2(box_min.x, y), gui.vec2(box_max.x, y), thirds);
    }
    const amber = theme.imU32(theme.accent);
    c.ImDrawList_AddRectEx(list, box_min, box_max, amber, 0, gui.px(1.5), 0);
    const arm = gui.px(14);
    const thick = gui.px(3);
    for ([_]gui.Vec2{ box_min, gui.vec2(box_max.x, box_min.y), box_max, gui.vec2(box_min.x, box_max.y) }, 0..) |corner, i| {
        const sx: f32 = if (i == 1 or i == 2) -1 else 1;
        const sy: f32 = if (i >= 2) -1 else 1;
        c.ImDrawList_AddLineEx(list, corner, gui.vec2(corner.x + sx * arm, corner.y), amber, thick);
        c.ImDrawList_AddLineEx(list, corner, gui.vec2(corner.x, corner.y + sy * arm), amber, thick);
    }
    if (edit.turns != 0 or edit.mirrored) {
        const note = if (edit.turns == 0) "Mirrored after cropping" else if (edit.mirrored) gui.print("Mirrored and turned {d}° after cropping", .{@as(u16, edit.turns) * 90}) else gui.print("Turned {d}° after cropping", .{@as(u16, edit.turns) * 90});
        tag(list, gui.vec2(box_min.x + gui.px(8), box_min.y + gui.px(8)), note, .left);
    }
}

/// The crop tool's icon, 14 pixels square at `corner`: two overlapping corners.
fn drawCropIcon(list: *c.ImDrawList, corner: gui.Vec2) void {
    const ink = theme.imU32(theme.text_tertiary);
    const t = gui.px(1.4);
    const p = struct {
        fn at(o: gui.Vec2, x: f32, y: f32) gui.Vec2 {
            return gui.vec2(o.x + gui.px(x), o.y + gui.px(y));
        }
    }.at;
    c.ImDrawList_AddLineEx(list, p(corner, 3, 1), p(corner, 3, 11), ink, t);
    c.ImDrawList_AddLineEx(list, p(corner, 3, 11), p(corner, 13, 11), ink, t);
    c.ImDrawList_AddLineEx(list, p(corner, 1, 3), p(corner, 11, 3), ink, t);
    c.ImDrawList_AddLineEx(list, p(corner, 11, 3), p(corner, 11, 13), ink, t);
}

/// A square button with a turn arrow on it. True when clicked.
fn turnButton(list: *c.ImDrawList, id: [:0]const u8, clockwise: bool) bool {
    const side = c.ImGui_GetFrameHeight();
    const corner = c.ImGui_GetCursorScreenPos();
    const clicked = gui.buttonOf(.normal, gui.print("##{s}", .{id}), gui.vec2(side / gui.scale, side / gui.scale));
    drawTurnIcon(list, gui.vec2(corner.x + side / 2, corner.y + side / 2), clockwise);
    return clicked;
}

/// Three quarters of a circle with an arrowhead at the top, pointing the way of the turn.
fn drawTurnIcon(list: *c.ImDrawList, centre: gui.Vec2, clockwise: bool) void {
    const ink = theme.imU32(theme.text_secondary);
    const radius = gui.px(5.5);
    const thickness = gui.px(1.4);
    const top = -std.math.pi / 2.0;
    const sweep = 1.5 * std.math.pi;
    // Screen angles grow clockwise, as y grows downwards.
    if (clockwise) c.ImDrawList_PathArcTo(list, centre, radius, top - sweep, top, 16) else c.ImDrawList_PathArcTo(list, centre, radius, top, top + sweep, 16);
    c.ImDrawList_PathStroke(list, ink, thickness, 0);
    const tip = gui.vec2(centre.x, centre.y - radius);
    const along: f32 = if (clockwise) 1 else -1;
    const head = gui.px(3);
    c.ImDrawList_AddLineEx(list, tip, gui.vec2(tip.x - along * head, tip.y - head), ink, thickness);
    c.ImDrawList_AddLineEx(list, tip, gui.vec2(tip.x - along * head, tip.y + head), ink, thickness);
}

/// A label over the picture, on a dark ground, from `at` to its `side`.
fn tag(list: *c.ImDrawList, at: gui.Vec2, label: [:0]const u8, side: enum { left, right }) void {
    const size = c.ImGui_CalcTextSize(label);
    const box = gui.vec2(size.x + gui.px(12), size.y + gui.px(4));
    const min = if (side == .left) at else gui.vec2(at.x - box.x, at.y);
    c.ImDrawList_AddRectFilledEx(list, min, gui.vec2(min.x + box.x, min.y + box.y), theme.imU32(theme.overlay), gui.px(3), 0);
    c.ImDrawList_AddText(list, gui.vec2(min.x + gui.px(6), min.y + gui.px(2)), theme.imU32(theme.text), label);
}

fn drawSettingsColumn(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, roll_index: ?usize, height: f32) void {
    const bar = gui.px(bottom_bar_height + 24) + 1;
    const top_left = c.ImGui_GetCursorScreenPos();
    // The histogram stays at the top while the settings under it scroll.
    var pinned: f32 = 0;
    if (state.frame) |*frame| {
        const scrollbar = if (state.settings_scroll) c.ImGui_GetStyle().*.ScrollbarSize else 0;
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(12), 0));
        _ = c.ImGui_BeginChild("histogram", gui.vec2(gui.px(settings_width) - scrollbar, 0), c.ImGuiChildFlags_AlwaysUseWindowPadding | c.ImGuiChildFlags_AutoResizeY, c.ImGuiWindowFlags_NoScrollbar);
        c.ImGui_PopStyleVar();
        gui.edge(.left);
        drawHistogramSection(frame);
        c.ImGui_EndChild();
        pinned = c.ImGui_GetItemRectSize().y;
    }
    c.ImGui_SetCursorScreenPos(gui.vec2(top_left.x, top_left.y + pinned));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(12), 0));
    _ = c.ImGui_BeginChild("settings", gui.vec2(gui.px(settings_width), @max(height - bar - pinned, 0)), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_None);
    c.ImGui_PopStyleVar();
    gui.edge(.left);
    c.ImGui_BeginDisabled(state.cropping != null);
    if (state.frame != null) drawSettings(state, gpa, io, library, roll_index);
    c.ImGui_EndDisabled();
    state.settings_scroll = c.ImGui_GetScrollMaxY() > 0;
    c.ImGui_EndChild();

    // The bar along the bottom.
    const corner = gui.vec2(top_left.x, top_left.y + height - bar);
    c.ImGui_SetCursorScreenPos(corner);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(12), gui.px(12)));
    _ = c.ImGui_BeginChild("settings bar", gui.vec2(gui.px(settings_width), bar), c.ImGuiChildFlags_AlwaysUseWindowPadding, c.ImGuiWindowFlags_NoScrollbar);
    c.ImGui_PopStyleVar();
    gui.edge(.left);
    c.ImDrawList_AddLine(c.ImGui_GetWindowDrawList(), corner, gui.vec2(corner.x + gui.px(settings_width), corner.y), theme.imU32(theme.divider));
    c.ImGui_BeginDisabled(state.cropping != null);
    if (state.frame != null) drawBottomBar(state, gpa, io, library, roll_index);
    c.ImGui_EndDisabled();
    c.ImGui_EndChild();
}

fn drawSettings(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, roll_index: ?usize) void {
    const frame = &state.frame.?;
    const s = &frame.settings;
    // A fitted look makes its own tones from the density, so the tone and inversion don't apply.
    const fitted = frame.look.kind() == .fitted;

    gui.beginSection("preset");
    gui.heading("PRESET");
    {
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gui.px(10), gui.px(8)));
        defer c.ImGui_PopStyleVar();
        gui.rowLabel("Film type");
        const kind_index = std.mem.indexOfScalar(develop.FilmKind, &labels.film_kinds, s.kind) orelse 0;
        if (gui.combo("film type", &labels.film_kind_labels, kind_index, 0)) |picked| {
            frame.measure(labels.film_kinds[picked]);
            state.changed();
        }
        gui.rowLabel("Stock");
        drawStock(state, io, library, roll_index);
        gui.rowLabel("Look");
        state.drawLook(gpa, io, library);
        if (state.import_failed) |err| {
            gui.rowLabel("");
            gui.paragraph(theme.text_tertiary, gui.print("That LUT didn't import: {s}.", .{importError(err)}));
        }
        gui.rowLabel("Tone");
        c.ImGui_BeginDisabled(fitted);
        const tones = comptime std.enums.values(develop.Tone);
        var tone_names: [tones.len][]const u8 = undefined;
        for (&tone_names, tones) |*n, t| n.* = t.label();
        if (gui.combo("tone", &tone_names, @backingInt(s.tone), 0)) |picked| {
            s.tone = tones[picked];
            state.changed();
        }
        c.ImGui_EndDisabled();
        gui.rowLabel("White balance");
        const modes = comptime std.enums.values(develop.WhiteBalance);
        var mode_names: [modes.len][]const u8 = undefined;
        const maker = if (roll_index) |r| (if (labels.findStock(library.rolls.items[r].info.stock orelse "")) |choice| (if (choice.preset) |p| p.maker else null) else null) else null;
        for (&mode_names, modes) |*n, m| n.* = if (m != .stock) m.label() else if (maker == null) "Stock (no preset)" else if (frame.stock_slopes == null) "Stock (calibrate first)" else gui.print("Stock ({s})", .{maker.?});
        if (gui.combo("white balance", &mode_names, @backingInt(s.white_balance), 0)) |picked| {
            switch (modes[picked]) {
                .picked => state.picking = .neutral,
                .stock => if (frame.stock_slopes != null) frame.rebalance(.stock, null),
                else => |mode| frame.rebalance(mode, null),
            }
            state.changed();
        }
        if (roll_index) |r| state.drawCalibration(gpa, io, library, r);
    }
    if (fitted) gui.paragraph(theme.text_tertiary, "A fitted look makes its own tones from the density, so Tone and Inversion don't apply.");
    gui.endSection(true);

    drawBase(state, library);

    gui.beginSection("density");
    gui.heading("DENSITY");
    {
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gui.px(10), gui.px(6)));
        defer c.ImGui_PopStyleVar();
        if (gui.sliderRow("D max", &s.density_range, 0.1, 6, "{d:.2}")) state.changed();
        if (gui.sliderRow("Offset", &s.offset, -1, 1, "{d:.2}")) state.changed();
        drawMatrix(state);
        c.ImGui_Dummy(gui.vec2(0, gui.px(2)));
        gui.heading("INVERSION");
        c.ImGui_BeginDisabled(fitted);
        defer c.ImGui_EndDisabled();
        if (gui.sliderRow("Contrast", &s.contrast, 1, 8, "{d:.2}")) state.changed();
        if (gui.sliderRow("Black", &s.black, -0.5, 0.5, "{d:.3}")) state.changed();
        if (gui.sliderRow("Highlight roll-off", &s.roll_off, 0.01, 0.99, "{d:.2}")) state.changed();
        if (gui.sliderRow("Exposure", &s.exposure, 0.5, 2, "{d:.2}")) state.changed();
    }
    gui.endSection(true);

    gui.beginSection("balance");
    gui.heading("COLOR BALANCE");
    {
        c.ImGui_BeginDisabled(s.kind.isMonochrome());
        defer c.ImGui_EndDisabled();
        {
            c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gui.px(10), gui.px(8)));
            defer c.ImGui_PopStyleVar();
            if (gui.sliderRow("Saturation", &s.saturation, 0, 2, "{d:.2}")) state.changed();
            if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("After the look, for the whole frame: 0 is grey, 1 leaves the colour as it is");
        }
        const gap = gui.px(4);
        const third = (c.ImGui_GetContentRegionAvail().x - 2 * gap) / 3;
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(10), gui.px(7.5)));
        for (comptime std.enums.values(develop.Range), 0..) |range, i| {
            if (i > 0) c.ImGui_SameLineEx(0, gap);
            if (gui.buttonOf(if (state.range == range) .selected else .unselected, gui.print("{s}", .{range.label()}), gui.vec2(third / gui.scale, 0))) state.range = range;
        }
        c.ImGui_PopStyleVar();
        c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_ItemSpacing, gui.vec2(gui.px(10), gui.px(6)));
        defer c.ImGui_PopStyleVar();
        const which = @backingInt(state.range);
        if (gui.sliderRow("Temperature", &s.temperature[which], -100, 100, "{d:.0}")) state.changed();
        if (gui.sliderRow("Tint", &s.tint[which], -100, 100, "{d:.0}")) state.changed();
    }
    gui.endSection(false);
}

/// The stock: the roll's, for the whole roll, from the stocks of the frame's film type.
fn drawStock(state: *State, io: std.Io, library: *Library, roll_index: ?usize) void {
    const r = roll_index orelse {
        c.ImGui_BeginDisabled(true);
        _ = gui.combo("stock", &.{"None"}, 0, 0);
        c.ImGui_EndDisabled();
        return;
    };
    const info = &library.rolls.items[r].info;
    const frame = &state.frame.?;
    var buffer: [labels.stock_choices.len + 1][]const u8 = undefined;
    const names = labels.stockNames(frame.settings.kind, "None", &buffer);
    var chosen: usize = names.len - 1;
    if (info.stock) |stock| {
        for (names[0 .. names.len - 1], 0..) |name, i| if (std.mem.eql(u8, name, stock)) {
            chosen = i;
        };
    }
    if (gui.searchCombo("stock", names, chosen, 0, "Search stocks")) |picked| {
        info.stock = if (picked < names.len - 1) names[picked] else null;
        library.rolls.items[r].saveInfo(io) catch |err| std.log.err("can't save the roll: {t}", .{err});
        frame.stock_slopes = stockSlopes(library, &library.rolls.items[r]);
        if (frame.settings.white_balance == .stock) {
            frame.rebalance(.stock, null);
            state.changed();
        }
    }
    if (labels.findStock(info.stock orelse "")) |choice| {
        if (choice.preset) |preset| {
            if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("%s", gui.print("{s}", .{preset.source}).ptr);
        } else if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("No preset: the maker publishes no numbers for this stock.");
    }
}

/// The film base: its colour, where it comes from, and picking it.
fn drawBase(state: *State, library: *Library) void {
    const frame = &state.frame.?;
    gui.beginSection("base");
    const list = c.ImGui_GetWindowDrawList();
    const row_height = c.ImGui_GetTextLineHeight() * 2.8;
    const corner = c.ImGui_GetCursorScreenPos();
    const swatch = gui.px(28);
    const swatch_min = gui.vec2(corner.x, corner.y + (row_height - swatch) / 2);
    var colour: [3]u8 = undefined;
    for (&colour, frame.settings.base) |*out, t| out.* = @intFromFloat(@round(negscan.encode.srgb(t) * 255));
    c.ImDrawList_AddRectFilledEx(list, swatch_min, gui.vec2(swatch_min.x + swatch, swatch_min.y + swatch), @as(u32, colour[0]) | @as(u32, colour[1]) << 8 | @as(u32, colour[2]) << 16 | 0xFF000000, gui.px(4), 0);
    gui.outline(swatch_min, gui.vec2(swatch_min.x + swatch, swatch_min.y + swatch), theme.withAlpha(theme.text, 0.15), gui.px(4), 1);
    const text_x = corner.x + swatch + gui.px(10);
    fonts.push(.semibold);
    c.ImDrawList_AddText(list, gui.vec2(text_x, corner.y + row_height / 2 - c.ImGui_GetTextLineHeight() * 1.2), theme.imU32(theme.text), "Film base");
    fonts.pop();
    const source = switch (frame.settings.base_source) {
        .measured => "The thinnest film in this frame",
        .gaps => if (frame.base_from_roll) "From the gaps between the roll's frames" else "From the gaps beside this frame",
        .picked => "Picked on this frame",
    };
    c.ImDrawList_AddText(list, gui.vec2(text_x, corner.y + row_height / 2 + gui.px(1)), theme.imU32(theme.text_tertiary), source);
    const pick_label = if (state.picking == .base) "Cancel" else "Pick";
    const pick_width = c.ImGui_CalcTextSize(pick_label).x + gui.px(20);
    c.ImGui_SetCursorScreenPos(gui.vec2(corner.x + c.ImGui_GetContentRegionAvail().x - pick_width, corner.y + (row_height - c.ImGui_GetFrameHeight()) / 2));
    if (gui.buttonOf(if (state.picking == .base) .selected else .normal, pick_label, gui.vec2(0, 0))) {
        state.picking = if (state.picking == .base) .none else .base;
    }
    shortcuts.tooltip("Click the film base in the frame: the rebate, or between frames", .base);
    c.ImGui_SetCursorScreenPos(gui.vec2(corner.x, corner.y + row_height));
    c.ImGui_Dummy(gui.vec2(0, 0));
    _ = library;
    gui.endSection(true);
}

/// The density matrix row, and its editor.
fn drawMatrix(state: *State) void {
    const s = &state.frame.?.settings;
    gui.rowLabel("Matrix");
    const is_identity = std.meta.eql(s.matrix, develop.identity);
    const edit_width = gui.px(gui.value_column);
    gui.textColored(theme.text_tertiary, if (is_identity) "Identity" else "Custom");
    c.ImGui_SameLineEx(c.ImGui_GetContentRegionAvail().x + c.ImGui_GetCursorPosX() - edit_width, 0);
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_FramePadding, gui.vec2(gui.px(6), gui.px(7.5)));
    if (gui.buttonOf(.normal, "Edit", gui.vec2(gui.value_column, 0))) _ = c.ImGui_OpenPopup("matrix", 0);
    c.ImGui_PopStyleVar();
    if (!c.ImGui_BeginPopup("matrix", 0)) return;
    defer c.ImGui_EndPopup();
    gui.heading("DENSITY MATRIX");
    gui.paragraph(theme.text_tertiary, "Each output channel's density from the scan's three, for crosstalk between the dyes.");
    for (&s.matrix, [_][]const u8{ "R", "G", "B" }) |*row, name| {
        c.ImGui_AlignTextToFramePadding();
        gui.textColored(theme.text_secondary, name);
        for (row, 0..) |*v, i| {
            c.ImGui_SameLine();
            c.ImGui_SetNextItemWidth(gui.px(70));
            if (c.ImGui_DragFloatEx(gui.print("##{s}{d}", .{ name, i }), v, 0.002, -2, 3, "%.3f", 0)) state.changed();
        }
    }
    if (gui.button("Identity")) {
        s.matrix = develop.identity;
        state.changed();
    }
}

fn drawBottomBar(state: *State, gpa: std.mem.Allocator, io: std.Io, library: *Library, roll_index: ?usize) void {
    const frame = &state.frame.?;
    const reset_width = c.ImGui_CalcTextSize("Reset").x + gui.px(28);
    const sync_width = c.ImGui_GetContentRegionAvail().x - reset_width - gui.px(8);
    c.ImGui_BeginDisabled(roll_index == null);
    if (gui.buttonOf(.primary, "Sync to roll…", gui.vec2(sync_width / gui.scale, bottom_bar_height)) or state.ask_sync) _ = c.ImGui_OpenPopup("sync", 0);
    state.ask_sync = false;
    c.ImGui_EndDisabled();
    shortcuts.tooltip("Gives the roll's other frames this frame's look, balance or more", .sync);
    c.ImGui_SameLineEx(0, gui.px(8));
    if (gui.buttonOf(.outline, "Reset", gui.vec2(reset_width / gui.scale, bottom_bar_height))) state.reset(io, library);
    shortcuts.tooltip("Back to the automatic settings; the frame counts as undeveloped again", .reset);

    const r = roll_index orelse return;
    if (!c.ImGui_BeginPopup("sync", 0)) return;
    defer c.ImGui_EndPopup();
    const rl = &library.rolls.items[r];
    gui.heading("SYNC TO ROLL");
    const others = rl.frames.items.len -| 1;
    gui.text(gui.print("Give the {d} other {s} of {s} this frame's", .{ others, if (others == 1) "frame" else "frames", rl.info.name }));
    const groups = [_]struct { *bool, [:0]const u8 }{
        .{ &state.sync.look, "Look, tone and saturation" },
        .{ &state.sync.balance, "White balance" },
        .{ &state.sync.density, "Density: D max and offset" },
        .{ &state.sync.base, "Film base" },
        .{ &state.sync.geometry, "Crop, turns and mirror" },
    };
    for (groups) |group| _ = gui.checkbox(group[1], group[0]);
    gui.textColored(theme.text_tertiary, "The rest each frame keeps, or measures for itself. An automatic white balance is worked out on each frame.");
    if (gui.buttonOf(.primary, "Sync", gui.vec2(0, 0))) {
        var failed: usize = 0;
        for (0..rl.frames.items.len) |i| {
            if (i == state.selected) continue;
            rl.frames.items[i] = synced(gpa, io, rl, i, frame, rl.frames.items[state.selected.?].scan, state.sync) catch |err| {
                std.log.err("can't sync frame {d}: {t}", .{ i + 1, err });
                failed += 1;
                continue;
            };
            rl.saveFrame(io, i) catch |err| std.log.err("can't save frame {d}: {t}", .{ i + 1, err });
            library.invalidate(.{ .roll = r, .frame = i });
        }
        state.write(io, library);
        if (failed > 0) std.log.warn("{d} frames weren't synced", .{failed});
        c.ImGui_CloseCurrentPopup();
    }
    c.ImGui_SameLine();
    if (gui.button("Cancel")) c.ImGui_CloseCurrentPopup();
}

/// What Sync copies to the other frames.
const SyncGroups = struct {
    look: bool = true,
    balance: bool = true,
    density: bool = false,
    base: bool = false,
    geometry: bool = false,
};

/// Frame `index` of `rl` with the groups of `source`'s settings in `groups`; `source_scan` is
/// `source`'s scan file. What isn't synced the frame keeps: its saved settings, or automatic ones
/// measured on its thumbnail when it was never developed. An automatic white balance is the
/// frame's own, worked out again.
fn synced(gpa: std.mem.Allocator, io: std.Io, rl: *roll.Roll, index: usize, source: *const Frame, source_scan: []const u8, groups: SyncGroups) !roll.FrameSettings {
    var target = rl.frames.items[index];
    if (groups.geometry) {
        // A crop is in its scan's pixels, so it only carries to another scan of the same size:
        // frames of one strip share a scan, and each has its own place on it.
        const shared = std.mem.eql(u8, target.scan, source_scan);
        if (!shared and target.width == source.scan_width and target.height == source.scan_height) target.crop = source.crop;
        target.quarter_turns = source.quarter_turns;
        target.mirrored = source.mirrored;
    }
    // Measured on its thumbnail, as the frame will be cut and turned: close enough to the scan's.
    var thumbnail = try rl.thumbnailAs(gpa, io, index, target);
    defer thumbnail.deinit(gpa);
    const stats = try develop.FrameStatistics.measure(gpa, thumbnail);
    const s = source.settings;
    var own = if (target.developed) target.settings else own: {
        const base = rl.baseFor(index);
        var automatic = develop.automatic(s.kind, base orelse stats.whole.thinnest, stats.centre);
        if (base != null) automatic.base_source = .gaps;
        break :own automatic;
    };
    own.kind = s.kind;
    own.monochrome_channel = s.monochrome_channel;
    if (groups.look) {
        target.look = source.look;
        own.tone = s.tone;
        own.matrix = s.matrix;
        own.contrast = s.contrast;
        own.black = s.black;
        own.roll_off = s.roll_off;
        own.exposure = s.exposure;
        own.saturation = s.saturation;
    }
    if (groups.density) {
        own.density_range = s.density_range;
        own.offset = s.offset;
    }
    if (groups.base) {
        own.base = s.base;
        own.base_source = s.base_source;
    }
    if (groups.balance) {
        own.white_balance = s.white_balance;
        own.temperature = s.temperature;
        own.tint = s.tint;
        own.highlight_balance = s.highlight_balance;
        own.shadow_balance = s.shadow_balance;
    }
    switch (own.white_balance) {
        .picked => {},
        else => |mode| own = develop.balanced(own, mode, stats.centre, null, source.stock_slopes),
    }
    target.settings = own;
    target.developed = true;
    return target;
}

/// The histogram and how much is clipped, over the settings.
fn drawHistogramSection(frame: *Frame) void {
    gui.beginSection("histogram");
    drawHistogram(frame);
    fonts.pushSized(.regular, 12);
    const shadows = gui.print("Shadows clipped {d:.1}%", .{frame.clipped_shadows * 100});
    const highlights = gui.print("Highlights clipped {d:.1}%", .{frame.clipped_highlights * 100});
    c.ImGui_SetCursorPosY(c.ImGui_GetCursorPosY() - gui.px(2));
    gui.textColored(theme.text_tertiary, shadows);
    c.ImGui_SameLineEx(c.ImGui_GetContentRegionAvail().x + c.ImGui_GetCursorPosX() - c.ImGui_CalcTextSize(highlights).x, 0);
    gui.textColored(theme.text_tertiary, highlights);
    fonts.pop();
    gui.endSection(true);
}

/// The histogram of the rendering: each channel as a filled area.
fn drawHistogram(frame: *Frame) void {
    const width = c.ImGui_GetContentRegionAvail().x;
    const height = gui.px(histogram_height);
    const origin = c.ImGui_GetCursorScreenPos();
    const list = c.ImGui_GetWindowDrawList();
    c.ImDrawList_AddRectFilledEx(list, origin, gui.vec2(origin.x + width, origin.y + height), theme.imU32(theme.histogram_ground), gui.px(4), 0);
    var peak: u32 = 1;
    // The ends hold clipped pixels; they would flatten everything else.
    for (frame.histogram[1 .. frame.histogram.len - 1]) |bin| {
        for (bin) |v| peak = @max(peak, v);
    }
    const colours = [_]theme.Color{ theme.red, theme.green, theme.blue };
    const bins: f32 = @floatFromInt(frame.histogram.len);
    for (colours, 0..) |colour, channel| {
        const fill = theme.imU32(theme.withAlpha(colour, 0.35));
        for (frame.histogram, 0..) |bin, i| {
            const share = @min(1, @as(f32, @floatFromInt(bin[channel])) / @as(f32, @floatFromInt(peak)));
            if (share <= 0) continue;
            const x0 = origin.x + width * @as(f32, @floatFromInt(i)) / bins;
            const x1 = origin.x + width * @as(f32, @floatFromInt(i + 1)) / bins;
            c.ImDrawList_AddRectFilled(list, gui.vec2(x0, origin.y + height * (1 - share)), gui.vec2(x1, origin.y + height), fill);
        }
    }
    c.ImGui_Dummy(gui.vec2(width, height));
}

/// Why a .cube file didn't import, for people.
fn importError(err: anyerror) []const u8 {
    return switch (err) {
        error.NotACube => "it isn't a .cube LUT",
        error.BadSize => "its size isn't one negscan reads (2 to 129 points a side)",
        error.Truncated => "it ends early",
        error.TooMuchData => "it has more values than its size says",
        error.InvalidNumber => "a value in it isn't a number",
        error.FileTooBig => "it's larger than 64 MB",
        error.NoLibrary => "there's no library to keep it in",
        else => @errorName(err),
    };
}

test "Sync gives the chosen groups and leaves each frame its own density" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);
    var rl = try roll.Roll.create(gpa, io, folder, .{ .name = "Sync test" });
    defer rl.close();
    // Two negatives, one of them much thinner than the other.
    for ([_]f32{ 0.15, 0.35 }) |lowest| {
        var scan: negscan.image.Scan = try .init(gpa, 96, 64);
        defer scan.deinit(gpa);
        for (scan.pixels, 0..) |*p, i| {
            const t = lowest + (0.85 - lowest) * @as(f32, @floatFromInt(i % 96)) / 95;
            p.* = .{ @intFromFloat(t * 60000), @intFromFloat(t * 30000), @intFromFloat(t * 20000) };
        }
        const ppm = try negscan.pnm.write(gpa, u16, scan);
        defer gpa.free(ppm);
        _ = try rl.addScan(gpa, io, ppm);
    }
    const scan_path = try rl.scanPath(gpa, 0);
    defer gpa.free(scan_path);
    var source: Frame = try .load(gpa, io, scan_path, "Frame 1", null, 0, false);
    defer source.close(gpa);
    source.measure(.colour_negative);
    source.look = .frontier;
    source.settings.tone = .hard;
    source.settings.saturation = 1.3;

    const other = try synced(gpa, io, &rl, 1, &source, rl.frames.items[0].scan, .{});
    try std.testing.expect(other.developed);
    try std.testing.expect(other.look.eql(&look.Id.frontier));
    try std.testing.expectEqual(develop.Tone.hard, other.settings.tone);
    try std.testing.expectEqual(@as(f32, 1.3), other.settings.saturation);
    // Its own density range: its negative is thinner.
    try std.testing.expect(@abs(other.settings.density_range - source.settings.density_range) > 0.05);

    const all = try synced(gpa, io, &rl, 1, &source, rl.frames.items[0].scan, .{ .density = true, .base = true });
    try std.testing.expectEqual(source.settings.density_range, all.settings.density_range);
    try std.testing.expectEqual(source.settings.base, all.settings.base);
}

/// The name a roll's calibration goes by: its scanner's, or for camera scans its camera's.
fn scannerOf(info: roll.Info) ?[]const u8 {
    return info.scanner orelse info.camera;
}

/// The roll's stock's layer slopes on its scanner, for Stock balance: when the stock has a preset
/// with gammas and the scanner is calibrated.
fn stockSlopes(library: *const Library, rl: *const roll.Roll) ?[3]f32 {
    if (rl.info.kind != .colour_negative) return null;
    const gamma = labels.stockGamma(rl.info.stock) orelse return null;
    const factors = library.calibrations.factors(scannerOf(rl.info) orelse return null) orelse return null;
    return negscan.calibration.stockSlopes(factors, gamma);
}
