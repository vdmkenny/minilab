//! Rolls on disk. A roll is a folder:
//!
//!     roll.json          what the roll is: film, format, camera, dates, notes
//!     scans/01.ppm …     the raw scans, never changed
//!     frames/01.json …   each frame's crop and develop settings
//!     thumbs/01.ppm …    the raw scans reduced, for quick previews, named as the scans
//!     exports/           developed files
//!     preview.ppm        the last preview of the film holder, from Scan
//!     preview.json       the frames' boxes on it, hand edits included
//!     flat.ppm           camera rolls: the flat field, if the roll has one
//!
//! Scans are kept as 16-bit binary PPM, whatever they were imported from (`input.zig`): linear
//! transmission in the scanner's or the camera's channels. A scan usually holds one frame. A strip
//! holds several, which share the scan, each with its own crop.
//!
//! A library is a folder of rolls.

const std = @import("std");
const Io = std.Io;
const image = @import("image.zig");
const develop = @import("develop.zig");
const look = @import("look.zig");
const pnm = @import("../io/pnm.zig");
const formats = @import("../frames/formats.zig");
const framing = @import("framing.zig");
const file_input = @import("input.zig");
const FlatField = @import("flat_field.zig").FlatField;

pub const info_file = "roll.json";
pub const scans_dir = "scans";
pub const frames_dir = "frames";
pub const exports_dir = "exports";
pub const thumbs_dir = "thumbs";
pub const flat_file = "flat.ppm";
/// A thumbnail's longer side, in pixels.
pub const thumbnail_longest = 256;
/// A strip's thumbnail is larger, so that each of its frames gets about `thumbnail_longest`, up to
/// this along its longer side.
pub const strip_thumbnail_longest = 2048;
const json_options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

/// Where a roll's scans come from.
pub const Input = enum {
    scanner,
    camera_raw,
    tiff_files,

    pub fn label(input: Input) []const u8 {
        return switch (input) {
            .scanner => "Scanner",
            .camera_raw => "Camera RAW",
            .tiff_files => "TIFF files",
        };
    }

    /// Where a file of `kind` comes from.
    pub fn of(kind: file_input.Kind) Input {
        return switch (kind) {
            .pnm => .scanner,
            .camera_raw => .camera_raw,
            .tiff => .tiff_files,
        };
    }
};

/// The frames one scan added to a roll: `count` of them from index `first`.
pub const Added = struct {
    first: usize,
    count: usize,
};

/// What a roll is. Free text where the user types it.
pub const Info = struct {
    name: []const u8,
    kind: develop.FilmKind = .colour_negative,
    stock: ?[]const u8 = null,
    /// One format for the whole roll.
    format: formats.Standard = .default,
    /// The day the roll was made here, YYYY-MM-DD.
    created: ?[]const u8 = null,
    input: Input = .scanner,
    /// The resolution the roll is scanned at, in pixels per inch, when known.
    dpi: ?f32 = null,
    camera: ?[]const u8 = null,
    lens: ?[]const u8 = null,
    shot: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    notes: ?[]const u8 = null,
    scanner: ?[]const u8 = null,
};

/// One frame: which scan it comes from, its crop, and how it's developed.
pub const FrameSettings = struct {
    scan: []const u8,
    /// The scan's size in pixels; 0 when not recorded yet.
    width: usize = 0,
    height: usize = 0,
    /// The scan's resolution in pixels per inch, when the scanner said.
    dpi: ?f32 = null,
    /// The frame within the scan, in the scan's pixels; null is the whole scan.
    crop: ?image.Area = null,
    /// Quarter turns clockwise after cropping, 0 to 3.
    quarter_turns: u2 = 0,
    /// Mirrored left to right after cropping, before the turns: for a scan made from the wrong
    /// side of the film.
    mirrored: bool = false,
    /// The film base's transmission per channel, 0..1, measured in the clear film beside the
    /// frame; null where the gaps aren't on the scan.
    film_base: ?[3]f32 = null,
    look: look.Id = .neutral,
    settings: develop.Settings = .{},
    developed: bool = false,
};

pub const Roll = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    info: Info,
    frames: std.ArrayList(FrameSettings) = .empty,

    /// Creates a roll folder named after `info.name` in `library`.
    /// Fails with `error.RollExists` when the library has a roll of that name, and with
    /// `error.BadRollName` for a name that can't be one folder.
    pub fn create(gpa: std.mem.Allocator, io: Io, library: []const u8, info: Info) !Roll {
        if (!validName(info.name)) return error.BadRollName;
        var roll: Roll = .{ .arena = .init(gpa), .path = undefined, .info = undefined };
        errdefer roll.arena.deinit();
        const arena = roll.arena.allocator();
        roll.path = try std.fs.path.join(arena, &.{ library, info.name });
        if (Io.Dir.cwd().access(io, try std.fs.path.join(arena, &.{ roll.path, info_file }), .{})) |_| {
            return error.RollExists;
        } else |_| {}
        roll.info = info;
        roll.info.name = try arena.dupe(u8, info.name);
        if (roll.info.created == null) roll.info.created = try today(arena, io);
        const cwd = Io.Dir.cwd();
        for ([_][]const u8{ scans_dir, frames_dir, thumbs_dir, exports_dir }) |sub| {
            try cwd.createDirPath(io, try std.fs.path.join(arena, &.{ roll.path, sub }));
        }
        try roll.saveInfo(io);
        return roll;
    }

    /// Opens the roll folder at `path`.
    pub fn open(gpa: std.mem.Allocator, io: Io, path: []const u8) !Roll {
        var roll: Roll = .{ .arena = .init(gpa), .path = undefined, .info = undefined };
        errdefer roll.arena.deinit();
        const arena = roll.arena.allocator();
        roll.path = try arena.dupe(u8, path);
        const cwd = Io.Dir.cwd();
        const info_bytes = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ path, info_file }), arena, .limited(max_json_bytes));
        roll.info = try std.json.parseFromSliceLeaky(Info, arena, info_bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });

        var dir = try cwd.openDir(io, try std.fs.path.join(arena, &.{ path, frames_dir }), .{ .iterate = true });
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var each = dir.iterate();
        while (try each.next(io)) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) try names.append(arena, try arena.dupe(u8, entry.name));
        }
        // By number, as `saveFrame` names them: as text, 100.json would come before 11.json.
        std.mem.sort([]const u8, names.items, {}, byNumber);
        for (names.items) |name| {
            const bytes = try dir.readFileAlloc(io, name, arena, .limited(max_json_bytes));
            const frame = std.json.parseFromSliceLeaky(FrameSettings, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| frame: {
                // One unreadable frame keeps its place, so the others keep their files, and the
                // rest of the roll still opens.
                std.log.err("{s}/{s}/{s} can't be read ({t}); the frame is left out of Develop", .{ path, frames_dir, name, err });
                break :frame FrameSettings{ .scan = "" };
            };
            try roll.frames.append(arena, frame);
        }
        return roll;
    }

    pub fn close(roll: *Roll) void {
        roll.arena.deinit();
        roll.* = undefined;
    }

    pub fn saveInfo(roll: *Roll, io: Io) !void {
        var temporary = roll.scratch();
        defer temporary.deinit();
        const a = temporary.allocator();
        const bytes = try std.json.Stringify.valueAlloc(a, roll.info, json_options);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ roll.path, info_file }), .data = bytes });
    }

    /// An arena for what a call needs only while it runs, so that the roll's own arena, which
    /// lives as long as the roll, doesn't grow with every save.
    fn scratch(roll: *Roll) std.heap.ArenaAllocator {
        return .init(roll.arena.child_allocator);
    }

    /// The scan file of frame `index`, as a path. The caller frees it.
    pub fn scanPath(roll: *const Roll, gpa: std.mem.Allocator, index: usize) ![]u8 {
        return std.fs.path.join(gpa, &.{ roll.path, scans_dir, roll.frames.items[index].scan });
    }

    /// Frame `index`'s thumbnail as Develop shows the frame: cut to its crop and turned. The
    /// caller frees it.
    pub fn frameThumbnail(roll: *Roll, gpa: std.mem.Allocator, io: Io, index: usize) !image.Scan {
        return roll.thumbnailAs(gpa, io, index, roll.frames.items[index]);
    }

    /// Frame `index`'s thumbnail cut and turned as `frame` says, which may differ from what the
    /// roll has for it yet.
    pub fn thumbnailAs(roll: *Roll, gpa: std.mem.Allocator, io: Io, index: usize, frame: FrameSettings) !image.Scan {
        const path = try roll.thumbnailPath(gpa, index);
        defer gpa.free(path);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_thumbnail_bytes));
        defer gpa.free(bytes);
        var full = try pnm.read(gpa, bytes);
        defer full.deinit(gpa);
        const area: image.Area = if (frame.crop != null and frame.width > 0) frame.crop.?.rescale(frame.width, full.width, full.width, full.height) else .whole(full.width, full.height);
        var cut = try full.crop(gpa, area);
        defer cut.deinit(gpa);
        return cut.orient(gpa, frame.quarter_turns, frame.mirrored);
    }

    /// The thumbnail of frame `index`'s scan, as a path; frames of one strip share it. The caller
    /// frees it.
    pub fn thumbnailPath(roll: *const Roll, gpa: std.mem.Allocator, index: usize) ![]u8 {
        var name: [std.fs.max_name_bytes]u8 = undefined;
        const file = try std.fmt.bufPrint(&name, "{s}.ppm", .{std.fs.path.stem(roll.frames.items[index].scan)});
        return std.fs.path.join(gpa, &.{ roll.path, thumbs_dir, file });
    }

    /// Adds the scan in `bytes` (a binary PNM) as `addImage` does, and returns the index of its
    /// first frame.
    pub fn addScan(roll: *Roll, gpa: std.mem.Allocator, io: Io, bytes: []const u8) !usize {
        return roll.addScanAt(gpa, io, bytes, null);
    }

    /// `addScan` for a scan made at `dpi` pixels per inch, which frame detection needs.
    pub fn addScanAt(roll: *Roll, gpa: std.mem.Allocator, io: Io, bytes: []const u8, dpi: ?f32) !usize {
        var scan = try pnm.read(gpa, bytes);
        defer scan.deinit(gpa);
        return (try roll.addImage(gpa, io, scan, dpi)).first;
    }

    /// Imports the file at `path`, of any kind `input.zig` reads, as `addImage` does. A camera
    /// frame is divided by `flat` first, the roll's flat field (`flatField`), when there is one.
    /// A roll still empty and without a flat field takes its input from the file's kind.
    pub fn importFile(roll: *Roll, gpa: std.mem.Allocator, io: Io, path: []const u8, flat: ?*const FlatField) !Added {
        var read = try file_input.read(gpa, io, path);
        defer read.deinit(gpa);
        if (flat) |f| try f.apply(read.scan);
        if (flat == null and roll.frames.items.len == 0 and roll.info.input != Input.of(read.kind)) {
            roll.info.input = .of(read.kind);
            try roll.saveInfo(io);
        }
        return roll.addImage(gpa, io, read.scan, null);
    }

    /// Saves `scan` as the roll's next scan file, with its thumbnail, and adds a frame for each
    /// frame on it, cropped and with the film base measured in the gaps beside it, so that
    /// thumbnails and Develop start cropped. A scan of one frame adds one; a strip adds one per
    /// whole frame on it, all sharing the scan. A scan where detection finds no frame adds one,
    /// uncropped. `dpi` is the scan's resolution, when known.
    pub fn addImage(roll: *Roll, gpa: std.mem.Allocator, io: Io, scan: image.Scan, dpi: ?f32) !Added {
        const arena = roll.arena.allocator();
        const first = roll.frames.items.len;
        // Frames added before a failure would have no file; they go again.
        errdefer roll.frames.shrinkRetainingCapacity(first);
        const name = try roll.nextScanName();

        var reduced = try image.downscale(gpa, scan, framing.detection_longest);
        defer reduced.deinit(gpa);
        const found: []const framing.Found = framing.findAll(gpa, reduced, scan.width, scan.height, dpi orelse roll.info.dpi, roll.info.format.format(), roll.info.kind) catch &.{};
        defer gpa.free(found);

        const scan_bytes = try pnm.write(gpa, u16, scan);
        defer gpa.free(scan_bytes);
        var thumbnail = try image.downscale(gpa, scan, thumbnailLongest(scan, found));
        defer thumbnail.deinit(gpa);
        const thumbnail_bytes = try pnm.write(gpa, u16, thumbnail);
        defer gpa.free(thumbnail_bytes);
        const cwd = Io.Dir.cwd();
        {
            var temporary = roll.scratch();
            defer temporary.deinit();
            const a = temporary.allocator();
            try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ roll.path, scans_dir, name }), .data = scan_bytes });
            try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ roll.path, thumbs_dir, name }), .data = thumbnail_bytes });
        }

        const frame: FrameSettings = .{
            .scan = name,
            .width = scan.width,
            .height = scan.height,
            .dpi = dpi,
            .settings = .{ .kind = roll.info.kind },
        };
        if (found.len == 0) try roll.frames.append(arena, frame);
        for (found) |f| {
            var cropped = frame;
            cropped.crop = f.frame;
            cropped.film_base = try framing.measureBase(gpa, scan, f.gaps);
            try roll.frames.append(arena, cropped);
        }
        for (first..roll.frames.items.len) |index| try roll.saveFrame(io, index);
        return .{ .first = first, .count = roll.frames.items.len - first };
    }

    /// A name for the next scan file, numbered as the next frame unless a frame already has it.
    fn nextScanName(roll: *Roll) ![]const u8 {
        const arena = roll.arena.allocator();
        var number = roll.frames.items.len + 1;
        while (true) : (number += 1) {
            const name = try std.fmt.allocPrint(arena, "{d:0>2}.ppm", .{number});
            for (roll.frames.items) |f| {
                if (std.mem.eql(u8, f.scan, name)) break;
            } else return name;
        }
    }

    /// The roll's flat field, ready to divide frames by, or null when it has none.
    pub fn flatField(roll: *Roll, gpa: std.mem.Allocator, io: Io) !?FlatField {
        const path = try std.fs.path.join(gpa, &.{ roll.path, flat_file });
        defer gpa.free(path);
        const bytes = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(file_input.max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer gpa.free(bytes);
        var shot = try pnm.read(gpa, bytes);
        defer shot.deinit(gpa);
        return try FlatField.init(gpa, shot);
    }

    /// Keeps `shot`, the light source photographed with no film, as the roll's flat field, which
    /// makes the roll a camera roll. Frames imported from now on are divided by it; the frames
    /// already in the roll stay as they are.
    pub fn setFlatField(roll: *Roll, gpa: std.mem.Allocator, io: Io, shot: image.Scan) !void {
        // A shot that can't be a flat field is refused before it replaces one that could.
        var check: FlatField = try .init(gpa, shot);
        check.deinit(gpa);
        const bytes = try pnm.write(gpa, u16, shot);
        defer gpa.free(bytes);
        const path = try std.fs.path.join(gpa, &.{ roll.path, flat_file });
        defer gpa.free(path);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
        roll.info.input = .camera_raw;
        try roll.saveInfo(io);
    }

    pub fn saveFrame(roll: *Roll, io: Io, index: usize) !void {
        var temporary = roll.scratch();
        defer temporary.deinit();
        const a = temporary.allocator();
        // JSON has no infinity or NaN, and a file with one couldn't be read back.
        var frame = roll.frames.items[index];
        finite(develop.Settings, &frame.settings, .{});
        const bytes = try std.json.Stringify.valueAlloc(a, frame, json_options);
        const name = try std.fmt.allocPrint(a, "{d:0>2}.json", .{index + 1});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ roll.path, frames_dir, name }), .data = bytes });
    }

    pub fn developedCount(roll: Roll) usize {
        var count: usize = 0;
        for (roll.frames.items) |f| count += @intFromBool(f.developed);
        return count;
    }

    /// The roll's film base: per channel, the median of the bases measured in the frames' gaps.
    /// Null when no frame has one.
    pub fn filmBase(roll: *const Roll) ?[3]f32 {
        return medianBase(roll.frames.items);
    }

    /// The film base for frame `index`: the one measured in the gaps beside it, unless that is
    /// further than `base_tolerance` from the roll's in some channel, as when a gap fell on the
    /// leader, a light leak or the holder. Then the roll's.
    pub fn baseFor(roll: *const Roll, index: usize) ?[3]f32 {
        const roll_base = roll.filmBase() orelse return null;
        const own = roll.frames.items[index].film_base orelse return roll_base;
        for (own, roll_base) |a, b| {
            if (@abs(a / b - 1) > base_tolerance) return roll_base;
        }
        return own;
    }
};

/// How far a frame's film base may be from the roll's, as a share. The frames of one roll agree
/// within a few percent; a gap that fell on something else is off by a third or more.
pub const base_tolerance = 0.15;

fn medianBase(frames: []const FrameSettings) ?[3]f32 {
    var values: [3][max_median_frames]f32 = undefined;
    var count: usize = 0;
    for (frames) |f| {
        const b = f.film_base orelse continue;
        if (count == max_median_frames) break;
        for (&values, b) |*channel, v| channel[count] = v;
        count += 1;
    }
    if (count == 0) return null;
    var base: [3]f32 = undefined;
    for (&base, &values) |*out, *channel| {
        std.mem.sort(f32, channel[0..count], {}, std.sort.asc(f32));
        out.* = if (count % 2 == 1) channel[count / 2] else (channel[count / 2 - 1] + channel[count / 2]) / 2;
    }
    return base;
}

/// The most frames the roll's base is worked out from; more than any roll has.
const max_median_frames = 256;

/// The longer side of the thumbnail of `scan`, on which detection found `found`.
fn thumbnailLongest(scan: image.Scan, found: []const framing.Found) usize {
    if (found.len < 2) return thumbnail_longest;
    var shortest: usize = std.math.maxInt(usize);
    for (found) |f| shortest = @min(shortest, @max(f.frame.width, f.frame.height));
    const longest = thumbnail_longest * @max(scan.width, scan.height) / @max(shortest, 1);
    return std.math.clamp(longest, thumbnail_longest, strip_thumbnail_longest);
}

test "a frame whose gap fell on something else takes the roll's base" {
    const gpa = std.testing.allocator;
    var roll: Roll = .{ .arena = .init(gpa), .path = "", .info = .{ .name = "Test" } };
    defer roll.arena.deinit();
    for ([_][3]f32{ .{ 0.31, 0.126, 0.095 }, .{ 0.41, 0.19, 0.12 }, .{ 0.42, 0.2, 0.13 }, .{ 0.415, 0.205, 0.13 } }) |b| {
        try roll.frames.append(roll.arena.allocator(), .{ .scan = "x.ppm", .film_base = b });
    }
    try roll.frames.append(roll.arena.allocator(), .{ .scan = "x.ppm" });
    const median = roll.filmBase().?;
    try std.testing.expectApproxEqAbs(@as(f32, 0.4125), median[0], 1e-6);
    try std.testing.expectEqual(median, roll.baseFor(0).?);
    try std.testing.expectEqual([3]f32{ 0.42, 0.2, 0.13 }, roll.baseFor(2).?);
    try std.testing.expectEqual(median, roll.baseFor(4).?);
}

/// Today's date in UTC, YYYY-MM-DD.
fn today(arena: std.mem.Allocator, io: Io) ![]const u8 {
    const seconds = Io.Clock.real.now(io).toSeconds();
    const day = (std.time.epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) }).getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year_day.year, month_day.month.numeric(), month_day.day_index + 1 });
}

/// Frame files by their number, `7.json` before `10.json`; names without one last, as text.
fn byNumber(_: void, a: []const u8, b: []const u8) bool {
    const x = std.fmt.parseInt(usize, std.fs.path.stem(a), 10) catch return false;
    const y = std.fmt.parseInt(usize, std.fs.path.stem(b), 10) catch return true;
    return x < y;
}

/// Whether `name` can be a roll's folder in the library: one folder, not a path.
fn validName(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\:") == null;
}

/// Replaces every number in `value` that isn't finite with its counterpart in `default`.
fn finite(comptime T: type, value: *T, default: T) void {
    switch (@typeInfo(T)) {
        .float => if (!std.math.isFinite(value.*)) {
            value.* = default;
        },
        .array => for (value, default) |*v, d| finite(@TypeOf(d), v, d),
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, Field| finite(Field, &@field(value, name), @field(default, name)),
        else => {},
    }
}

const max_json_bytes = 1 << 20;
/// The largest thumbnail read: far more than a 256-pixel thumbnail of even a long strip.
const max_thumbnail_bytes = 64 << 20;

/// The rolls in `library`, opened; folders without a roll.json are skipped.
pub fn listRolls(gpa: std.mem.Allocator, io: Io, library: []const u8) !std.ArrayList(Roll) {
    var rolls: std.ArrayList(Roll) = .empty;
    errdefer {
        for (rolls.items) |*r| r.close();
        rolls.deinit(gpa);
    }
    var dir = Io.Dir.cwd().openDir(io, library, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return rolls,
        else => return err,
    };
    defer dir.close(io);
    var each = dir.iterate();
    while (try each.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const path = try std.fs.path.join(gpa, &.{ library, entry.name });
        defer gpa.free(path);
        var roll = Roll.open(gpa, io, path) catch |err| {
            // A folder without a roll.json isn't a roll, and says nothing; a roll that won't open
            // should.
            if (err != error.FileNotFound) std.log.err("the roll in {s} can't be opened: {t}", .{ path, err });
            continue;
        };
        rolls.append(gpa, roll) catch |err| {
            roll.close();
            return err;
        };
    }
    std.mem.sort(Roll, rolls.items, {}, newerFirst);
    return rolls;
}

/// Newest made first, then by name, last first.
fn newerFirst(_: void, a: Roll, b: Roll) bool {
    const a_date = a.info.created orelse "";
    const b_date = b.info.created orelse "";
    if (!std.mem.eql(u8, a_date, b_date)) return std.mem.lessThan(u8, b_date, a_date);
    return std.mem.lessThan(u8, b.info.name, a.info.name);
}

test "a roll round-trips through its folder" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);

    var roll = try Roll.create(gpa, io, library, .{ .name = "2026-10-22 Portra 400", .stock = "Kodak Portra 400" });
    const index = try roll.addScan(gpa, io, "P6 1 1 255\n\x00\x00\x00");
    roll.frames.items[index].settings.contrast = 3.5;
    roll.frames.items[index].developed = true;
    try roll.saveFrame(io, index);
    roll.close();

    var rolls = try listRolls(gpa, io, library);
    defer {
        for (rolls.items) |*r| r.close();
        rolls.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), rolls.items.len);
    const again = rolls.items[0];
    try std.testing.expectEqualStrings("Kodak Portra 400", again.info.stock.?);
    try std.testing.expectEqual(@as(usize, 1), again.frames.items.len);
    try std.testing.expectEqual(@as(f32, 3.5), again.frames.items[0].settings.contrast);
    try std.testing.expectEqual(@as(usize, 1), again.developedCount());
    try std.testing.expectEqual(@as(usize, "2026-10-22".len), again.info.created.?.len);
}

const synthetic = @import("../frames/synthetic.zig");
const codecs_tiff = @import("../io/codecs/tiff.zig");

/// A roll made in a new folder of `tmp` for a test, with the folder's path.
fn testRoll(tmp: *std.testing.TmpDir, info: Info) !Roll {
    const gpa = std.testing.allocator;
    const library = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(library);
    return Roll.create(gpa, std.testing.io, library, info);
}

/// The scan the roll keeps for frame `index`.
fn keptScan(roll: *Roll, index: usize) !image.Scan {
    const gpa = std.testing.allocator;
    const path = try roll.scanPath(gpa, index);
    defer gpa.free(path);
    const bytes = try Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, .limited(file_input.max_file_bytes));
    defer gpa.free(bytes);
    return pnm.read(gpa, bytes);
}

test "a 16-bit TIFF imports as the same pixels, kept as a PPM" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var roll = try testRoll(&tmp, .{ .name = "From VueScan" });
    defer roll.close();

    var encoded: image.Encoded16 = try .init(gpa, 37, 23);
    defer encoded.deinit(gpa);
    for (encoded.pixels, 0..) |*p, i| p.* = .{ @intCast(i * 41), @intCast(i * 29 + 7), @intCast(65535 - i * 31) };
    const file = try codecs_tiff.write(gpa, u16, encoded, .{});
    defer gpa.free(file);
    const path = try std.fs.path.join(gpa, &.{ roll.path, "strip.tif" });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file });

    const added = try roll.importFile(gpa, io, path, null);
    try std.testing.expectEqual(Added{ .first = 0, .count = 1 }, added);
    try std.testing.expectEqual(Input.tiff_files, roll.info.input);
    try std.testing.expectEqualStrings("01.ppm", roll.frames.items[0].scan);
    var kept = try keptScan(&roll, 0);
    defer kept.deinit(gpa);
    try std.testing.expectEqualSlices([image.channel_count]u16, encoded.pixels, kept.pixels);
}

test "a strip imports as one frame per frame on it, sharing the scan" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var roll = try testRoll(&tmp, .{ .name = "Strips" });
    defer roll.close();

    var on_film: [6]synthetic.Frame = undefined;
    const strip = synthetic.strip135(&on_film);
    var scan = try strip.render(gpa);
    defer scan.deinit(gpa);

    // The first frame scanned on its own with a bit of the next, then the whole strip.
    const px_per_mm = strip.dpi / formats.mm_per_inch;
    const one_frame: image.Area = .{ .x = 0, .y = 0, .width = scan.width, .height = @intFromFloat((synthetic.pitch_135_mm + 2 * synthetic.leader_135_mm) * px_per_mm) };
    var single = try scan.crop(gpa, one_frame);
    defer single.deinit(gpa);
    try std.testing.expectEqual(Added{ .first = 0, .count = 1 }, try roll.addImage(gpa, io, single, strip.dpi));
    const added = try roll.addImage(gpa, io, scan, strip.dpi);
    try std.testing.expectEqual(Added{ .first = 1, .count = on_film.len }, added);

    try std.testing.expectEqualStrings("01.ppm", roll.frames.items[0].scan);
    var previous_end: usize = 0;
    for (roll.frames.items[added.first..], on_film) |f, expected| {
        try std.testing.expectEqualStrings("02.ppm", f.scan);
        try std.testing.expectEqual(scan.width, f.width);
        const crop = f.crop.?;
        const centre = strip.centre(expected);
        try std.testing.expectApproxEqAbs(centre[1], @as(f32, @floatFromInt(crop.y)) + @as(f32, @floatFromInt(crop.height)) / 2, 2 * px_per_mm);
        try std.testing.expect(crop.y >= previous_end);
        previous_end = crop.y + crop.height;
        for (f.film_base.?) |b| try std.testing.expectApproxEqRel(strip.base, b, 2 * strip.noise);
    }
    // The strip's frames share its thumbnail, which is large enough for each to show.
    const first_path = try roll.thumbnailPath(gpa, added.first);
    defer gpa.free(first_path);
    const last_path = try roll.thumbnailPath(gpa, added.first + on_film.len - 1);
    defer gpa.free(last_path);
    try std.testing.expectEqualStrings(first_path, last_path);
    const thumbnail = try Io.Dir.cwd().readFileAlloc(io, first_path, gpa, .limited(file_input.max_file_bytes));
    defer gpa.free(thumbnail);
    var small = try pnm.read(gpa, thumbnail);
    defer small.deinit(gpa);
    try std.testing.expectEqual(@max(scan.width, scan.height), @max(small.width, small.height));

    var again: Roll = try .open(gpa, io, roll.path);
    defer again.close();
    try std.testing.expectEqual(1 + on_film.len, again.frames.items.len);
    try std.testing.expectEqualStrings("02.ppm", again.frames.items[on_film.len].scan);
}

test "a camera roll's frames are divided by its flat field on import" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var roll = try testRoll(&tmp, .{ .name = "Camera" });
    defer roll.close();
    try std.testing.expectEqual(null, try roll.flatField(gpa, io));

    // Light twice as bright on the left as on the right, and film passing a quarter of it.
    const width = 64;
    const height = 48;
    const bright = 60000;
    const film = 0.25;
    var shot: image.Scan = try .init(gpa, width, height);
    defer shot.deinit(gpa);
    var frame: image.Scan = try .init(gpa, width, height);
    defer frame.deinit(gpa);
    for (0..height) |y| {
        for (shot.row(y), frame.row(y), 0..) |*light, *through, x| {
            const level = bright * (1 - 0.5 * (@as(f32, @floatFromInt(x)) + 0.5) / width);
            light.* = @splat(@intFromFloat(@round(level)));
            through.* = @splat(@intFromFloat(@round(level * film)));
        }
    }
    try roll.setFlatField(gpa, io, shot);
    try std.testing.expectEqual(Input.camera_raw, roll.info.input);
    var flat = (try roll.flatField(gpa, io)).?;
    defer flat.deinit(gpa);

    const ppm = try pnm.write(gpa, u16, frame);
    defer gpa.free(ppm);
    const path = try std.fs.path.join(gpa, &.{ roll.path, "frame.ppm" });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = ppm });
    _ = try roll.importFile(gpa, io, path, &flat);
    var kept = try keptScan(&roll, 0);
    defer kept.deinit(gpa);
    // Even across, at what the film passes of the brightest light.
    for (kept.pixels) |p| try std.testing.expectApproxEqRel(@as(f32, bright * film), @as(f32, @floatFromInt(p[0])), 0.01);
}

test "a roll's name can't take an existing roll or leave the library" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);
    var first = try Roll.create(gpa, io, library, .{ .name = "Roll 1", .stock = "Kodak Gold 200" });
    first.close();
    try std.testing.expectError(error.RollExists, Roll.create(gpa, io, library, .{ .name = "Roll 1" }));
    try std.testing.expectError(error.BadRollName, Roll.create(gpa, io, library, .{ .name = "../elsewhere" }));
    try std.testing.expectError(error.BadRollName, Roll.create(gpa, io, library, .{ .name = "" }));
    const path = try tmp.dir.realPathFileAlloc(io, "Roll 1", gpa);
    defer gpa.free(path);
    var again = try Roll.open(gpa, io, path);
    defer again.close();
    try std.testing.expectEqualStrings("Kodak Gold 200", again.info.stock.?);
}

test "frames keep their files past 99, and numbers that aren't finite aren't saved" {
    var names = [_][]const u8{ "100.json", "09.json", "11.json", "10.json", "notes.json" };
    std.mem.sort([]const u8, &names, {}, byNumber);
    try std.testing.expectEqualStrings("09.json", names[0]);
    try std.testing.expectEqualStrings("100.json", names[3]);
    try std.testing.expectEqualStrings("notes.json", names[4]);

    var settings: develop.Settings = .{};
    settings.highlight_balance = .{ std.math.inf(f32), 1, std.math.nan(f32) };
    settings.contrast = -std.math.inf(f32);
    finite(develop.Settings, &settings, .{});
    try std.testing.expectEqual((develop.Settings{}).highlight_balance, settings.highlight_balance);
    try std.testing.expectEqual((develop.Settings{}).contrast, settings.contrast);
}
