//! Rolls on disk. A roll is a folder like this:
//!
//!     roll.json          what the roll is: film, format, camera, dates, notes
//!     scans/01.tif …     the raw scans, never changed
//!     frames/01.json …   each frame's crop and develop settings
//!     thumbs/01.ppm …    reduced copies of the raw scans for quick previews, named like the scans
//!     exports/           developed files
//!     preview.ppm        the last preview of the film holder, from Scan
//!     preview.json       the frames' boxes on it, hand edits included
//!     flat.ppm           camera rolls only: the flat field, if the roll has one
//!
//! Raw scans are kept as 16-bit TIFF with Deflate, which loses nothing, whatever they were
//! imported from (`input.zig`): linear transmission in the scanner's or the camera's channels.
//! Other apps, such as Lightroom, Capture One and Apple Photos, open them too. Rolls made before
//! that keep their raw scans as 16-bit binary PPM (scans/01.ppm), and those read just the same,
//! since a scan is read by its extension. A scan usually holds one frame. A strip holds several,
//! which share the scan and each have their own crop. Finished pictures, such as a lab's scans,
//! are kept as the files they came in (scans/01.jpg …), unchanged.
//!
//! A library is a folder of rolls.

const std = @import("std");
const Io = std.Io;
const image = @import("image.zig");
const stats = @import("stats.zig");
const develop = @import("develop.zig");
const look = @import("look.zig");
const pnm = @import("../io/pnm.zig");
const tiff = @import("../io/codecs/tiff.zig");
const icc = @import("../io/codecs/icc.zig");
const formats = @import("../frames/formats.zig");
const framing = @import("framing.zig");
const file_input = @import("input.zig");
const FlatField = @import("flat_field.zig").FlatField;
pub const Field = @import("export_metadata.zig").Field;

pub const info_file = "roll.json";
pub const scans_dir = "scans";
pub const frames_dir = "frames";
pub const exports_dir = "exports";
pub const thumbs_dir = "thumbs";
pub const flat_file = "flat.ppm";
/// The extension of the raw scans a roll writes (`encodeRaw`).
pub const raw_extension = ".tif";
/// The colour space a raw scan's file says it's in: linear light, so other apps show the negative
/// at the right brightness. minilab reads the samples as they are and doesn't use it (`input.zig`).
pub const raw_space: icc.Space = .srgb_linear;
/// A thumbnail's longer side, in pixels.
pub const thumbnail_longest = 256;
/// A strip's thumbnail is larger, so that each of its frames gets about `thumbnail_longest`. This
/// is the most it can have along its longer side.
pub const strip_thumbnail_longest = 2048;
const json_options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };

/// Where a roll's scans come from.
pub const Input = enum {
    scanner,
    camera_raw,
    tiff_files,
    /// Finished pictures: a lab's scans, or a scanner's that inverts by itself.
    finished,

    pub fn label(input: Input) []const u8 {
        return switch (input) {
            .scanner => "Scanner",
            .camera_raw => "Camera RAW",
            .tiff_files => "TIFF files",
            .finished => "Finished scans",
        };
    }

    /// Returns where a file of `kind` comes from.
    pub fn of(kind: file_input.Kind) Input {
        return switch (kind) {
            .pnm => .scanner,
            .camera_raw => .camera_raw,
            .tiff => .tiff_files,
            .jpeg => .finished,
        };
    }
};

/// What importing does with a finished picture's file: copy it into the roll, or move it there. A
/// raw scan is always converted into the roll's own file, so its original stays where it is
/// either way.
pub const Transfer = enum { copy, move };

/// The frames one scan added to a roll: `count` of them, starting at index `first`.
pub const Added = struct {
    first: usize,
    count: usize,
};

/// What a roll is. Anything the user types is free text.
pub const Info = struct {
    name: []const u8,
    kind: develop.FilmKind = .colour_negative,
    stock: ?[]const u8 = null,
    /// Whether the stock's datasheet corrects the frames: its curves, and its balance on a
    /// calibrated scanner. When it's off, the stock is just metadata for the roll.
    stock_corrections: bool = true,
    /// One format for the whole roll.
    format: formats.Standard = .default,
    /// The day the roll was created in the library, YYYY-MM-DD.
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
    /// Metadata fields of your own, written into exported files.
    fields: []const Field = &.{},
};

/// The roll's details you can edit after making it, by their names in `Info`.
pub const Detail = enum { camera, lens, shot, copyright, notes };

/// One frame: which scan it comes from, its crop, and how it's developed.
pub const FrameSettings = struct {
    /// The scan's file in the roll's scans folder, or null for a frame whose own file can't be
    /// read.
    scan: ?[]const u8,
    /// The scan's size in pixels, or 0 if it hasn't been recorded yet.
    width: usize = 0,
    height: usize = 0,
    /// The scan's resolution in pixels per inch, if the scanner gave one.
    dpi: ?f32 = null,
    /// The frame within the scan, in the scan's pixels. Null means the whole scan.
    crop: ?image.Area = null,
    /// Quarter turns clockwise after cropping, 0 to 3.
    quarter_turns: u2 = 0,
    /// Whether to mirror left to right after cropping, before the turns. It's for a scan made from
    /// the wrong side of the film.
    mirrored: bool = false,
    /// The film base's transmission per channel, 0..1, measured in the clear film beside the
    /// frame. Null when the gaps aren't on the scan.
    film_base: ?[3]f32 = null,
    look: look.Id = .neutral,
    settings: develop.Settings = .{},
    developed: bool = false,
    /// The stars and the reject flag you give the frame in Develop. Export starts with rejected
    /// frames unchecked.
    rating: Rating = .{},
};

/// A frame's rating: up to five stars, and whether it's rejected. Rejecting a frame keeps its
/// stars, as Lightroom does, so they come back if you take the reject back.
pub const Rating = struct {
    /// 0 for none, up to `max_stars`.
    stars: u8 = 0,
    rejected: bool = false,

    pub const max_stars = 5;

    /// The rating with its stars brought into range, for one read from a file.
    pub fn valid(rating: Rating) Rating {
        return .{ .stars = @min(rating.stars, max_stars), .rejected = rating.rejected };
    }

    /// The rating as XMP's `xmp:Rating` gives it: -1 for rejected, otherwise the stars, with 0
    /// for none.
    pub fn xmp(rating: Rating) i8 {
        return if (rating.rejected) -1 else @intCast(@min(rating.stars, max_stars));
    }
};

pub const Roll = struct {
    arena: std.heap.ArenaAllocator,
    path: []const u8,
    info: Info,
    frames: std.ArrayList(FrameSettings) = .empty,
    /// Each frame's number, which names its file in frames/: 01.json is 1. They run from 1 to the
    /// count unless a frame's file was removed by hand, so they're kept as they were read rather
    /// than worked out from a frame's place. Otherwise the frame after a gap would be saved over
    /// the gap's number, and show up twice.
    numbers: std.ArrayList(usize) = .empty,

    /// Creates a roll folder named after `info.name` in `library`. Fails with `error.RollExists`
    /// if the library already has a roll with that name, and with `error.BadRollName` if the name
    /// can't be a single folder.
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
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
            if (frameNumber(entry.name) == null) {
                std.log.warn("{s}/{s}/{s} isn't a frame's file; leaving it alone", .{ path, frames_dir, entry.name });
                continue;
            }
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
        // Sort by number, the way `saveFrame` names them. As text, 100.json would come before
        // 11.json.
        std.mem.sort([]const u8, names.items, {}, byNumber);
        for (names.items) |name| {
            const bytes = try dir.readFileAlloc(io, name, arena, .limited(max_json_bytes));
            var frame = std.json.parseFromSliceLeaky(FrameSettings, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| frame: {
                // An unreadable frame keeps its place, so the others keep their files and the rest
                // of the roll still opens.
                std.log.err("{s}/{s}/{s} can't be read ({t}); the frame is left out of Develop", .{ path, frames_dir, name, err });
                break :frame FrameSettings{ .scan = null };
            };
            upgrade(&frame.settings);
            frame.rating = frame.rating.valid();
            try roll.frames.append(arena, frame);
            try roll.numbers.append(arena, frameNumber(name).?);
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

    /// One of the roll's editable details, or null when it isn't set.
    pub fn detail(roll: *const Roll, which: Detail) ?[]const u8 {
        return switch (which) {
            inline else => |d| @field(roll.info, @tagName(d)),
        };
    }

    /// Sets one of the roll's details to `value`, or clears it when `value` is blank, and saves
    /// the roll.
    pub fn setDetail(roll: *Roll, io: Io, which: Detail, value: []const u8) !void {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        const kept: ?[]const u8 = if (trimmed.len == 0) null else try roll.arena.allocator().dupe(u8, trimmed);
        switch (which) {
            inline else => |d| @field(roll.info, @tagName(d)) = kept,
        }
        try roll.saveInfo(io);
    }

    /// Replaces the roll's own metadata fields with `fields` and saves the roll. A field with no
    /// name yet is kept, so a new one can be filled in, but it doesn't go into exported files.
    pub fn setFields(roll: *Roll, io: Io, fields: []const Field) !void {
        const arena = roll.arena.allocator();
        const kept = try arena.alloc(Field, fields.len);
        for (kept, fields) |*k, f| k.* = .{
            .name = try arena.dupe(u8, std.mem.trim(u8, f.name, " \t\r\n")),
            .value = try arena.dupe(u8, std.mem.trim(u8, f.value, " \t\r\n")),
        };
        roll.info.fields = kept;
        try roll.saveInfo(io);
    }

    /// An arena for things a call only needs while it runs, so the roll's own arena, which lives
    /// as long as the roll, doesn't grow with every save.
    fn scratch(roll: *Roll) std.heap.ArenaAllocator {
        return .init(roll.arena.child_allocator);
    }

    /// Returns the path of frame `index`'s scan file. The caller frees it.
    pub fn scanPath(roll: *const Roll, gpa: std.mem.Allocator, index: usize) ![]u8 {
        const scan = roll.frames.items[index].scan orelse return error.UnreadableFrame;
        return std.fs.path.join(gpa, &.{ roll.path, scans_dir, scan });
    }

    /// Returns frame `index`'s thumbnail the way Develop shows the frame: cut to its crop and
    /// turned. The caller frees it.
    pub fn frameThumbnail(roll: *Roll, gpa: std.mem.Allocator, io: Io, index: usize) !image.Scan {
        return roll.thumbnailAs(gpa, io, index, roll.frames.items[index]);
    }

    /// Returns frame `index`'s thumbnail, cut and turned the way `frame` says, which may not match
    /// what the roll has saved for it yet.
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

    /// Returns the path of the thumbnail of frame `index`'s scan. Frames from one strip share it.
    /// The caller frees it.
    pub fn thumbnailPath(roll: *const Roll, gpa: std.mem.Allocator, index: usize) ![]u8 {
        var name: [std.fs.max_name_bytes]u8 = undefined;
        const scan = roll.frames.items[index].scan orelse return error.UnreadableFrame;
        return std.fs.path.join(gpa, &.{ roll.path, thumbs_dir, try thumbnailName(&name, scan) });
    }

    /// Adds the scan in `bytes` (a binary PNM) the way `addImage` does, and returns the index of
    /// its first frame.
    pub fn addScan(roll: *Roll, gpa: std.mem.Allocator, io: Io, bytes: []const u8) !usize {
        return roll.addScanAt(gpa, io, bytes, null);
    }

    /// Like `addScan`, for a scan made at `dpi` pixels per inch, which frame detection needs.
    pub fn addScanAt(roll: *Roll, gpa: std.mem.Allocator, io: Io, bytes: []const u8, dpi: ?f32) !usize {
        var scan = try pnm.read(gpa, bytes);
        defer scan.deinit(gpa);
        return (try roll.addImage(gpa, io, scan, dpi)).first;
    }

    /// Imports the file at `path`, of any kind `input.zig` reads, the way `addImage` does. If
    /// there's a flat field `flat` (the roll's, from `flatField`), a camera frame is divided by it
    /// first. A roll that's still empty and has no flat field takes its input from the file's
    /// kind. A camera RAW file's colour goes with its frames, for slides. With a flat field, which
    /// has already made the light behind the film white, only its matrix goes with them.
    pub fn importFile(roll: *Roll, gpa: std.mem.Allocator, io: Io, path: []const u8, flat: ?*const FlatField, transfer: Transfer) !Added {
        var read = try file_input.read(gpa, io, path);
        defer read.deinit(gpa);
        if (flat == null and roll.frames.items.len == 0 and roll.info.input != Input.of(read.kind)) {
            roll.info.input = .of(read.kind);
            try roll.saveInfo(io);
        }
        if (read.kind.finished()) return roll.addFinished(gpa, io, path, read.scan, transfer);
        if (flat) |f| try f.apply(read.scan);
        var slide = read.camera;
        if (flat != null) {
            if (slide) |*s| s.balance = @splat(1);
        }
        return roll.addImageWith(gpa, io, read.scan, null, slide);
    }

    /// Saves `scan` as the roll's next scan file, with its thumbnail, and adds a frame for each
    /// frame on it. Each one is cropped, with the film base measured in the gaps beside it, so
    /// thumbnails and Develop start out cropped. A scan of one frame adds one frame, and a strip
    /// adds one per whole frame on it, all sharing the scan. If detection finds no frame, the scan
    /// adds one uncropped frame. `dpi` is the scan's resolution, if known.
    pub fn addImage(roll: *Roll, gpa: std.mem.Allocator, io: Io, scan: image.Scan, dpi: ?f32) !Added {
        return roll.addImageWith(gpa, io, scan, dpi, null);
    }

    /// Adds the finished picture in the file at `path` as one frame that shows it as it is. The
    /// file goes into the roll unchanged, copied or moved, so the roll keeps the lab's own bytes.
    /// `picture` is the file read into linear values, for the thumbnail.
    fn addFinished(roll: *Roll, gpa: std.mem.Allocator, io: Io, path: []const u8, picture: image.Scan, transfer: Transfer) !Added {
        const first = roll.frames.items.len;
        errdefer roll.dropFramesFrom(first);
        var lower: [max_extension]u8 = undefined;
        const extension = std.fs.path.extension(path);
        const name = try roll.nextScanName(std.ascii.lowerString(&lower, extension[0..@min(extension.len, max_extension)]));

        var thumbnail = try image.downscale(gpa, picture, thumbnail_longest);
        defer thumbnail.deinit(gpa);
        const thumbnail_bytes = try pnm.write(gpa, u16, thumbnail);
        defer gpa.free(thumbnail_bytes);
        {
            var temporary = roll.scratch();
            defer temporary.deinit();
            const a = temporary.allocator();
            var thumbnail_name: [std.fs.max_name_bytes]u8 = undefined;
            try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ roll.path, thumbs_dir, try thumbnailName(&thumbnail_name, name) }), .data = thumbnail_bytes });
            try placeFile(gpa, io, path, try std.fs.path.join(a, &.{ roll.path, scans_dir, name }), transfer);
        }
        try roll.appendFrame(.{
            .scan = name,
            .width = picture.width,
            .height = picture.height,
            .settings = .finishedPicture(),
            .developed = true,
        });
        try roll.saveFrame(io, first);
        return .{ .first = first, .count = 1 };
    }

    /// Like `addImage`, for a scan with a camera's colour, `slide`, which its frames use when
    /// they're slides.
    fn addImageWith(roll: *Roll, gpa: std.mem.Allocator, io: Io, scan: image.Scan, dpi: ?f32, slide: ?develop.SlideColour) !Added {
        const first = roll.frames.items.len;
        // Frames added before a failure would have no file, so they're removed again.
        errdefer roll.dropFramesFrom(first);
        const name = try roll.nextScanName(raw_extension);

        var reduced = try image.downscale(gpa, scan, framing.detection_longest);
        defer reduced.deinit(gpa);
        const found: []const framing.Found = framing.findAll(gpa, reduced, scan.width, scan.height, dpi orelse roll.info.dpi, roll.info.format.format(), roll.info.kind) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            // No frames found: the scan goes in as one frame, uncropped.
            else => none: {
                std.log.info("no frames found on {s} ({t}); it goes in whole", .{ name, err });
                break :none &.{};
            },
        };
        defer gpa.free(found);

        const scan_bytes = try encodeRaw(gpa, scan, dpi);
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
            var thumbnail_name: [std.fs.max_name_bytes]u8 = undefined;
            try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ roll.path, thumbs_dir, try thumbnailName(&thumbnail_name, name) }), .data = thumbnail_bytes });
        }

        const frame: FrameSettings = .{
            .scan = name,
            .width = scan.width,
            .height = scan.height,
            .dpi = dpi,
            .settings = .{ .kind = roll.info.kind, .slide_colour = slide },
        };
        if (found.len == 0) try roll.appendFrame(frame);
        for (found) |f| {
            var cropped = frame;
            cropped.crop = f.frame;
            cropped.film_base = try framing.measureBase(gpa, scan, f.gaps);
            try roll.appendFrame(cropped);
        }
        for (first..roll.frames.items.len) |index| try roll.saveFrame(io, index);
        return .{ .first = first, .count = roll.frames.items.len - first };
    }

    /// Picks a name for the next scan file, with `extension`: numbered like the next frame, unless
    /// a frame's scan already has that number, whatever its extension, since thumbnails are named
    /// by the number alone.
    fn nextScanName(roll: *Roll, extension: []const u8) ![]const u8 {
        const arena = roll.arena.allocator();
        var number = roll.frames.items.len + 1;
        while (true) : (number += 1) {
            var digits: [24]u8 = undefined;
            const stem = try std.fmt.bufPrint(&digits, "{d:0>2}", .{number});
            for (roll.frames.items) |f| {
                const scan = f.scan orelse continue;
                if (std.mem.eql(u8, std.fs.path.stem(scan), stem)) break;
            } else return std.fmt.allocPrint(arena, "{s}{s}", .{ stem, extension });
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

    /// Keeps `shot`, a photo of the light source with no film, as the roll's flat field. That
    /// makes the roll a camera roll. Frames imported from now on are divided by it, and the frames
    /// already in the roll stay as they are.
    pub fn setFlatField(roll: *Roll, gpa: std.mem.Allocator, io: Io, shot: image.Scan) !void {
        // Refuse a shot that can't work as a flat field before it replaces one that can.
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

    /// Removes the frames from `first` on, which haven't been saved.
    fn dropFramesFrom(roll: *Roll, first: usize) void {
        roll.frames.shrinkRetainingCapacity(first);
        roll.numbers.shrinkRetainingCapacity(@min(first, roll.numbers.items.len));
    }

    /// Adds `frame` after the others, numbered after the last one.
    fn appendFrame(roll: *Roll, frame: FrameSettings) !void {
        const a = roll.arena.allocator();
        const last = if (roll.numbers.items.len > 0) roll.numbers.items[roll.numbers.items.len - 1] else roll.frames.items.len;
        try roll.frames.ensureUnusedCapacity(a, 1);
        try roll.numbers.append(a, last + 1);
        roll.frames.appendAssumeCapacity(frame);
    }

    pub fn saveFrame(roll: *Roll, io: Io, index: usize) !void {
        var temporary = roll.scratch();
        defer temporary.deinit();
        const a = temporary.allocator();
        // JSON has no infinity or NaN, and a file with one couldn't be read back.
        var frame = roll.frames.items[index];
        finite(develop.Settings, &frame.settings, .{});
        const bytes = try std.json.Stringify.valueAlloc(a, frame, json_options);
        const number = if (index < roll.numbers.items.len) roll.numbers.items[index] else index + 1;
        const name = try std.fmt.allocPrint(a, "{d:0>2}.json", .{number});
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ roll.path, frames_dir, name }), .data = bytes });
    }

    pub fn developedCount(roll: Roll) usize {
        var count: usize = 0;
        for (roll.frames.items) |f| count += @intFromBool(f.developed);
        return count;
    }

    /// Returns the roll's film base: per channel, the median of the bases measured in the frames'
    /// gaps. Returns null when no frame has one.
    pub fn filmBase(roll: *const Roll) ?[3]f32 {
        return medianBase(roll.frames.items);
    }

    /// Returns the film base for frame `index`. That's the one measured in the gaps beside it,
    /// unless it's further than `base_tolerance` from the roll's base in some channel, say because
    /// a gap fell on the leader, a light leak or the holder. Then it's the roll's base.
    pub fn baseFor(roll: *const Roll, index: usize) ?[3]f32 {
        const roll_base = roll.filmBase() orelse return null;
        const own = roll.frames.items[index].film_base orelse return roll_base;
        for (own, roll_base) |a, b| {
            if (@abs(a / b - 1) > base_tolerance) return roll_base;
        }
        return own;
    }
};

/// How far a frame's film base can be from the roll's, as a share. The frames of one roll agree to
/// within a few percent, and a gap that fell on something else is off by a third or more.
pub const base_tolerance = 0.15;

fn medianBase(frames: []const FrameSettings) ?[3]f32 {
    var bases: [max_median_frames][3]f32 = undefined;
    var count: usize = 0;
    for (frames) |f| {
        const b = f.film_base orelse continue;
        if (count == max_median_frames) break;
        bases[count] = b;
        count += 1;
    }
    var scratch: [max_median_frames]f32 = undefined;
    return stats.channelMedian(bases[0..count], &scratch);
}

/// The most frames the roll's base is worked out from. That's more than any roll has.
const max_median_frames = 256;

/// The longest extension a finished picture's file keeps, dot included.
const max_extension = 8;

/// Puts the file at `from` at `to`: a copy, or the file itself for a move. A move that can't
/// rename, say from another disk, copies the file and deletes the original once the copy is
/// written.
fn placeFile(gpa: std.mem.Allocator, io: Io, from: []const u8, to: []const u8, transfer: Transfer) !void {
    const cwd = Io.Dir.cwd();
    if (transfer == .move) {
        if (cwd.rename(from, cwd, to, io)) |_| return else |_| {}
    }
    const bytes = try cwd.readFileAlloc(io, from, gpa, .limited(file_input.max_file_bytes));
    defer gpa.free(bytes);
    try cwd.writeFile(io, .{ .sub_path = to, .data = bytes });
    if (transfer == .move) try cwd.deleteFile(io, from);
}

/// Encodes `scan`, made at `dpi` if that's known, the way a roll keeps a raw scan: a 16-bit TIFF
/// with Deflate, which loses nothing and which other apps open, with `raw_space`'s profile. The
/// caller owns the bytes.
pub fn encodeRaw(gpa: std.mem.Allocator, scan: image.Scan, dpi: ?f32) ![]u8 {
    const profile = try icc.profileBytes(gpa, raw_space);
    defer gpa.free(profile);
    return tiff.write(gpa, u16, scan, .{ .icc_profile = profile, .dpi = dpi });
}

/// Works out the longer side of the thumbnail for `scan`, given the frames detection `found` on
/// it.
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

/// Sorts frame files by number, so `7.json` comes before `10.json`. Names without a number go last.
/// The file name of the thumbnail of the scan called `scan`, in `buffer`: the scan's own name with
/// .ppm, which a finished picture's JPEG scan gets too.
fn thumbnailName(buffer: []u8, scan: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}.ppm", .{std.fs.path.stem(scan)});
}

/// The number in a frame's file name, such as 3 for 03.json, or null when it isn't a frame's.
fn frameNumber(name: []const u8) ?usize {
    const number = std.fmt.parseInt(usize, std.fs.path.stem(name), 10) catch return null;
    return if (number > 0) number else null;
}

fn byNumber(_: void, a: []const u8, b: []const u8) bool {
    const x = std.fmt.parseInt(usize, std.fs.path.stem(a), 10) catch return false;
    const y = std.fmt.parseInt(usize, std.fs.path.stem(b), 10) catch return true;
    return x < y;
}

/// Whether `name` works as a roll's folder in the library: a single folder, not a path.
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
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, Member| finite(Member, &@field(value, name), @field(default, name)),
        // An optional with anything that isn't finite in it is dropped, since there's no default
        // to use inside it.
        .optional => |o| if (value.*) |inner| {
            if (!allFinite(o.child, inner)) value.* = null;
        },
        else => {},
    }
}

/// Brings settings saved by an earlier minilab up to date. Temperatures from before they were in
/// K (when they ran from −100 to 100) are converted to K.
fn upgrade(settings: *develop.Settings) void {
    for (&settings.temperature) |*t| {
        if (t.* < develop.min_kelvin) t.* = develop.kelvinFromShift(t.*);
    }
}

fn allFinite(comptime T: type, value: T) bool {
    return switch (@typeInfo(T)) {
        .float => std.math.isFinite(value),
        .array => for (value) |v| {
            if (!allFinite(@TypeOf(v), v)) break false;
        } else true,
        .@"struct" => |s| inline for (s.field_names, s.field_types) |name, Member| {
            if (!allFinite(Member, @field(value, name))) break false;
        } else true,
        else => true,
    };
}

const max_json_bytes = 1 << 20;
/// The largest thumbnail we read: far more than any thumbnail, even a long strip's at
/// `strip_thumbnail_longest`.
const max_thumbnail_bytes = 64 << 20;

/// Opens the rolls in `library`. Folders without a roll.json are skipped.
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
            // A folder without a roll.json isn't a roll, so we stay quiet about it. A roll that
            // won't open gets an error.
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

/// Sorts rolls with the newest first (by the day they were created), then by name, from Z to A.
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
    roll.frames.items[index].rating = .{ .stars = 4, .rejected = true };
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
    try std.testing.expectEqual(Rating{ .stars = 4, .rejected = true }, again.frames.items[0].rating);
    try std.testing.expectEqual(@as(usize, "2026-10-22".len), again.info.created.?.len);
}

test "a roll's details and fields can change after it's made, and blank ones clear" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);

    var roll = try Roll.create(gpa, io, library, .{ .name = "Roll 1", .camera = "Nikon F3" });
    try roll.setDetail(io, .camera, "  Pentax MX ");
    try roll.setDetail(io, .lens, "");
    try roll.setDetail(io, .notes, "Rainy day");
    try roll.setFields(io, &.{ .{ .name = " Developer ", .value = "Cinestill Cs41" }, .{ .name = "", .value = "" } });
    roll.close();

    var rolls = try listRolls(gpa, io, library);
    defer {
        for (rolls.items) |*r| r.close();
        rolls.deinit(gpa);
    }
    const again = rolls.items[0];
    try std.testing.expectEqualStrings("Pentax MX", again.detail(.camera).?);
    try std.testing.expectEqual(@as(?[]const u8, null), again.detail(.lens));
    try std.testing.expectEqualStrings("Rainy day", again.detail(.notes).?);
    try std.testing.expectEqual(@as(usize, 2), again.info.fields.len);
    try std.testing.expectEqualStrings("Developer", again.info.fields[0].name);
    try std.testing.expectEqualStrings("Cinestill Cs41", again.info.fields[0].value);
}

test "a frame saved before ratings and dust removal has neither, and too many stars come down to five" {
    const gpa = std.testing.allocator;
    const old = try std.json.parseFromSlice(FrameSettings, gpa, "{\"scan\":\"01.ppm\",\"developed\":true,\"settings\":{\"tone\":\"soft\"}}", .{ .ignore_unknown_fields = true });
    defer old.deinit();
    try std.testing.expectEqual(Rating{}, old.value.rating);
    try std.testing.expectEqual(develop.Tone.soft, old.value.settings.tone);
    try std.testing.expect(!old.value.settings.dust.remove);
    try std.testing.expectEqual(Rating{ .stars = 5 }, (Rating{ .stars = 9 }).valid());
    try std.testing.expectEqual(@as(i8, -1), (Rating{ .stars = 3, .rejected = true }).xmp());
    try std.testing.expectEqual(@as(i8, 3), (Rating{ .stars = 3 }).xmp());
}

const synthetic = @import("../frames/synthetic.zig");
const codecs_jpeg = @import("../io/codecs/jpeg.zig");

/// Makes a roll in a new folder of `tmp` for a test, along with the folder's path.
fn testRoll(tmp: *std.testing.TmpDir, info: Info) !Roll {
    const gpa = std.testing.allocator;
    const library = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(library);
    return Roll.create(gpa, std.testing.io, library, info);
}

/// The scan the roll keeps for frame `index`, read by its extension the way the app reads it.
fn keptScan(roll: *Roll, index: usize) !image.Scan {
    const gpa = std.testing.allocator;
    const path = try roll.scanPath(gpa, index);
    defer gpa.free(path);
    return (try file_input.read(gpa, std.testing.io, path)).scan;
}

test "a 16-bit TIFF imports as the same pixels, kept as a TIFF" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var roll = try testRoll(&tmp, .{ .name = "From VueScan" });
    defer roll.close();

    var encoded: image.Encoded16 = try .init(gpa, 37, 23);
    defer encoded.deinit(gpa);
    for (encoded.pixels, 0..) |*p, i| p.* = .{ @intCast(i * 41), @intCast(i * 29 + 7), @intCast(65535 - i * 31) };
    const file = try tiff.write(gpa, u16, encoded, .{});
    defer gpa.free(file);
    const path = try std.fs.path.join(gpa, &.{ roll.path, "strip.tif" });
    defer gpa.free(path);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file });

    const added = try roll.importFile(gpa, io, path, null, .copy);
    try std.testing.expectEqual(Added{ .first = 0, .count = 1 }, added);
    try std.testing.expectEqual(Input.tiff_files, roll.info.input);
    try std.testing.expectEqualStrings("01.tif", roll.frames.items[0].scan.?);
    var kept = try keptScan(&roll, 0);
    defer kept.deinit(gpa);
    try std.testing.expectEqualSlices([image.channel_count]u16, encoded.pixels, kept.pixels);

    // It says it's linear, so other apps show it at the right brightness.
    const kept_path = try roll.scanPath(gpa, 0);
    defer gpa.free(kept_path);
    const kept_file = try Io.Dir.cwd().readFileAlloc(io, kept_path, gpa, .limited(file_input.max_file_bytes));
    defer gpa.free(kept_file);
    var decoded = try tiff.read(gpa, kept_file);
    defer decoded.deinit(gpa);
    const linear = try icc.profileBytes(gpa, raw_space);
    defer gpa.free(linear);
    try std.testing.expect(icc.sameProfile(linear, decoded.icc_profile.?));
}

test "a roll from before keeps reading its PPM scans, and new scans go in next to them as TIFFs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var roll = try testRoll(&tmp, .{ .name = "Roll from 0.5" });
    defer roll.close();

    // An old roll's frame: its scan and its thumbnail as PPMs, the way minilab 0.5 wrote them.
    var old: image.Scan = try .init(gpa, 48, 32);
    defer old.deinit(gpa);
    for (old.pixels, 0..) |*p, i| p.* = .{ @intCast(i * 13), @intCast(i * 7 + 3), @intCast(60000 - i * 11) };
    const ppm = try pnm.write(gpa, u16, old);
    defer gpa.free(ppm);
    try tmp.dir.writeFile(io, .{ .sub_path = "Roll from 0.5/scans/01.ppm", .data = ppm });
    try tmp.dir.writeFile(io, .{ .sub_path = "Roll from 0.5/thumbs/01.ppm", .data = ppm });
    try tmp.dir.writeFile(io, .{ .sub_path = "Roll from 0.5/frames/01.json", .data = "{\"scan\":\"01.ppm\",\"width\":48,\"height\":32}" });

    var again: Roll = try .open(gpa, io, roll.path);
    defer again.close();
    var new: image.Scan = try .init(gpa, 40, 30);
    defer new.deinit(gpa);
    for (new.pixels, 0..) |*p, i| p.* = .{ @intCast(65535 - i * 17), @intCast(i * 5), @intCast(i * 23 + 9) };
    try std.testing.expectEqual(Added{ .first = 1, .count = 1 }, try again.addImage(gpa, io, new, null));
    try std.testing.expectEqualStrings("02.tif", again.frames.items[1].scan.?);

    for ([_]image.Scan{ old, new }, 0..) |written, index| {
        var kept = try keptScan(&again, index);
        defer kept.deinit(gpa);
        try std.testing.expectEqualSlices([image.channel_count]u16, written.pixels, kept.pixels);
        // Both scans are smaller than a thumbnail, so it shows the frame at full size.
        var thumbnail = try again.frameThumbnail(gpa, io, index);
        defer thumbnail.deinit(gpa);
        const crop = again.frames.items[index].crop orelse image.Area.whole(written.width, written.height);
        try std.testing.expectEqual(crop.width, thumbnail.width);
    }
    // The old scan stays a PPM: nothing rewrites a raw scan.
    try tmp.dir.access(io, "Roll from 0.5/scans/01.ppm", .{});
}

test "a finished picture goes into the roll as it is, copied or moved, and develops unchanged" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var roll = try testRoll(&tmp, .{ .name = "Lab scans", .stock = "Kodak Portra 400" });
    defer roll.close();

    var picture: image.Encoded8 = try .init(gpa, 30, 20);
    defer picture.deinit(gpa);
    for (picture.pixels, 0..) |*p, i| p.* = .{ @intCast(i % 256), 128, @intCast(255 - i % 256) };
    const file = try codecs_jpeg.write(gpa, picture, .{ .quality = 95 });
    defer gpa.free(file);
    const copied = try std.fs.path.join(gpa, &.{ roll.path, "IMG_0001.JPG" });
    defer gpa.free(copied);
    const moved = try std.fs.path.join(gpa, &.{ roll.path, "IMG_0002.jpg" });
    defer gpa.free(moved);
    for ([_][]const u8{ copied, moved }) |p| try Io.Dir.cwd().writeFile(io, .{ .sub_path = p, .data = file });

    try std.testing.expectEqual(Added{ .first = 0, .count = 1 }, try roll.importFile(gpa, io, copied, null, .copy));
    try std.testing.expectEqual(Added{ .first = 1, .count = 1 }, try roll.importFile(gpa, io, moved, null, .move));
    try std.testing.expectEqual(Input.finished, roll.info.input);
    // The roll keeps the files' own bytes, under the frames' numbers.
    try std.testing.expectEqualStrings("01.jpg", roll.frames.items[0].scan.?);
    try std.testing.expectEqualStrings("02.jpg", roll.frames.items[1].scan.?);
    for (0..2) |i| {
        const kept = try roll.scanPath(gpa, i);
        defer gpa.free(kept);
        const bytes = try Io.Dir.cwd().readFileAlloc(io, kept, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        try std.testing.expectEqualSlices(u8, file, bytes);
        const frame = roll.frames.items[i];
        try std.testing.expect(frame.developed and frame.settings.finished);
        try std.testing.expectEqual(@as(usize, 30), frame.width);
    }
    // A copy leaves the original, and a move takes it.
    try Io.Dir.cwd().access(io, copied, .{});
    try std.testing.expectError(error.FileNotFound, Io.Dir.cwd().access(io, moved, .{}));
    // The thumbnail is there for the Rolls page.
    var thumbnail = try roll.frameThumbnail(gpa, io, 1);
    defer thumbnail.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 30), thumbnail.width);
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

    // First the first frame scanned on its own, with a bit of the next one, then the whole strip.
    const px_per_mm = strip.dpi / formats.mm_per_inch;
    const one_frame: image.Area = .{ .x = 0, .y = 0, .width = scan.width, .height = @intFromFloat((synthetic.pitch_135_mm + 2 * synthetic.leader_135_mm) * px_per_mm) };
    var single = try scan.crop(gpa, one_frame);
    defer single.deinit(gpa);
    try std.testing.expectEqual(Added{ .first = 0, .count = 1 }, try roll.addImage(gpa, io, single, strip.dpi));
    const added = try roll.addImage(gpa, io, scan, strip.dpi);
    try std.testing.expectEqual(Added{ .first = 1, .count = on_film.len }, added);

    try std.testing.expectEqualStrings("01.tif", roll.frames.items[0].scan.?);
    var previous_end: usize = 0;
    for (roll.frames.items[added.first..], on_film) |f, expected| {
        try std.testing.expectEqualStrings("02.tif", f.scan.?);
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
    try std.testing.expectEqualStrings("02.tif", again.frames.items[on_film.len].scan.?);
}

test "a camera roll's frames are divided by its flat field on import" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var roll = try testRoll(&tmp, .{ .name = "Camera" });
    defer roll.close();
    try std.testing.expectEqual(null, try roll.flatField(gpa, io));

    // Light twice as bright on the left as on the right, and film that passes a quarter of it.
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
    _ = try roll.importFile(gpa, io, path, &flat, .copy);
    var kept = try keptScan(&roll, 0);
    defer kept.deinit(gpa);
    // Even all the way across, at the film's share of the brightest light.
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

test "a roll saved before the stock's corrections could be turned off has them on" {
    const gpa = std.testing.allocator;
    const old = try std.json.parseFromSlice(Info, gpa, "{\"name\":\"Roll 1\",\"stock\":\"Kodak Portra 400\"}", .{ .ignore_unknown_fields = true });
    defer old.deinit();
    try std.testing.expect(old.value.stock_corrections);
    const off = try std.json.parseFromSlice(Info, gpa, "{\"name\":\"Roll 1\",\"stock_corrections\":false}", .{ .ignore_unknown_fields = true });
    defer off.deinit();
    try std.testing.expect(!off.value.stock_corrections);
}

test "a frame after a gap in the files keeps its own file" {
    // The warning about notes.json is expected.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);
    var roll = try Roll.create(gpa, io, library, .{ .name = "Gaps" });
    for (0..3) |_| _ = try roll.addScan(gpa, io, "P6 1 1 255\n\x00\x00\x00");
    roll.close();
    // Frame 2's file removed by hand, and a file that isn't a frame's.
    try tmp.dir.deleteFile(io, "Gaps/frames/02.json");
    try tmp.dir.writeFile(io, .{ .sub_path = "Gaps/frames/notes.json", .data = "{}" });

    var rolls = try listRolls(gpa, io, library);
    defer {
        for (rolls.items) |*r| r.close();
        rolls.deinit(gpa);
    }
    const again = &rolls.items[0];
    try std.testing.expectEqual(@as(usize, 2), again.frames.items.len);
    again.frames.items[1].settings.contrast = 2;
    try again.saveFrame(io, 1);
    _ = try again.addScan(gpa, io, "P6 1 1 255\n\x00\x00\x00");
    // Frame 3 saved to its own file, not over the gap's, and the new frame after it.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "Gaps/frames/02.json", .{}));
    try tmp.dir.access(io, "Gaps/frames/03.json", .{});
    try tmp.dir.access(io, "Gaps/frames/04.json", .{});
}
