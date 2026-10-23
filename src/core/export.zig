//! Exports frames. For each frame we crop and turn its scan, reduce it if asked, and develop it
//! with its saved settings (or automatic ones if it hasn't been developed yet). Then we convert it
//! to the chosen colour space, encode it as TIFF or JPEG with that space's ICC profile and the
//! roll's metadata, and write an XMP sidecar next to it. A `Batch` exports a roll's frames on a
//! thread of its own, with progress and cancel.
//!
//! On colour: every look develops to linear light in the scanner's RGB, which we take as having
//! Rec. 709's primaries. `icc.Transform` wants linear Rec. 2020, so the pixels go through
//! BT.2087's matrix first.

const std = @import("std");
const image = @import("image.zig");
const develop = @import("develop.zig");
const encode = @import("encode.zig");
const look = @import("look.zig");
const roll = @import("roll.zig");
const stock_curves = @import("stock_curves.zig");
/// Reduces pictures by area, to any size.
pub const resample = @import("resample.zig");
const pnm = @import("../io/pnm.zig");
const tiff = @import("../io/codecs/tiff.zig");
const input = @import("input.zig");
const jpeg = @import("../io/codecs/jpeg.zig");
const icc = @import("../io/codecs/icc.zig");
pub const metadata = @import("export_metadata.zig");

pub const Format = enum {
    tiff,
    jpeg,

    pub fn extension(format: Format) []const u8 {
        return switch (format) {
            .tiff => "tif",
            .jpeg => "jpg",
        };
    }
};

pub const Depth = image.Depth;

/// The colour spaces offered, in the order the interface lists them.
pub const spaces = [_]icc.Space{ .display_p3, .srgb, .adobe_rgb, .prophoto };

pub const Options = struct {
    format: Format = .tiff,
    /// A TIFF's bits per sample. A JPEG always has 8.
    depth: Depth = .sixteen,
    /// A JPEG's quality, on libjpeg's scale of 1 to 100. From 90 up, the colour is kept at full
    /// resolution (4:4:4). Below that, it's kept at half (4:2:0).
    quality: jpeg.Quality = 92,
    space: icc.Space = .display_p3,
    /// Reduce so that the longer side is this many pixels, or null to keep full resolution.
    /// Frames that are already smaller keep their size.
    long_edge: ?usize = null,

    /// The bits per sample of the file.
    pub fn bits(options: Options) Depth {
        return if (options.format == .jpeg) .eight else options.depth;
    }
};

/// Which of the roll's details go into the files. The colour space, the resolution and the size
/// always do.
pub const Include = struct {
    camera: bool = true,
    lens: bool = true,
    stock: bool = true,
    shot: bool = true,
    copyright: bool = true,
    /// The look, the develop settings, the film base, the crop and the scanner.
    settings: bool = true,
    /// The frame's stars, or that it's rejected.
    rating: bool = true,
    /// The roll's notes, as the caption.
    notes: bool = true,
    /// The roll's own fields.
    fields: bool = true,
};

/// Set from another thread to stop an export at its next check.
pub const Cancel = std.atomic.Value(bool);

fn check(cancel: ?*const Cancel) error{Canceled}!void {
    if (cancel) |flag| if (flag.load(.acquire)) return error.Canceled;
}

/// How many rows we convert between checks for cancel.
const band_rows = 64;

/// A developed frame in the output space, before it becomes a file.
pub const Picture = struct {
    pixels: Pixels,
    /// Output pixels per scan pixel: 1 at full resolution, less once reduced.
    scale: f64,

    pub const Pixels = union(enum) {
        eight: image.Encoded8,
        sixteen: image.Encoded16,
    };

    pub fn deinit(picture: *Picture, gpa: std.mem.Allocator) void {
        switch (picture.pixels) {
            inline else => |*p| p.deinit(gpa),
        }
        picture.* = undefined;
    }

    pub fn width(picture: Picture) usize {
        return switch (picture.pixels) {
            inline else => |p| p.width,
        };
    }

    pub fn height(picture: Picture) usize {
        return switch (picture.pixels) {
            inline else => |p| p.height,
        };
    }
};

/// The errors converting a developed frame can give. Developing can fail in more ways (anything
/// `look.developFrame` can return), so `developPicture` lets the compiler infer its error set.
pub const ConvertError = error{
    OutOfMemory,
    Canceled,
} || icc.Error;

/// Prepares `scan` the way `frame` says. It's cropped, turned and reduced to `options.long_edge`,
/// then developed in `frame_look` (the look `frame` names), with its saved settings if it's been
/// developed, or automatic ones for its film if not. Finally it's converted to `options.space` at
/// the file's depth. Develop's preview and the thumbnails take the same steps, so the file looks
/// like the screen.
pub fn developPicture(gpa: std.mem.Allocator, scan: image.Scan, frame: roll.FrameSettings, frame_look: look.Resolved, options: Options, cancel: ?*const Cancel) !Picture {
    // Each step makes a copy. We hold on to the latest one here and free the one before.
    var owned: ?image.Scan = null;
    defer if (owned) |*s| s.deinit(gpa);
    var current = scan;

    if (frame.crop) |area| {
        // The frame's crop reaches outside its scan.
        if (!area.fitsIn(scan.width, scan.height)) return error.CropOutsideScan;
        owned = try scan.crop(gpa, area);
        current = owned.?;
    }
    if (frame.quarter_turns != 0 or frame.mirrored) {
        const turned = try current.orient(gpa, frame.quarter_turns, frame.mirrored);
        if (owned) |*s| s.deinit(gpa);
        owned = turned;
        current = turned;
    }
    try check(cancel);
    const full_width = current.width;
    if (options.long_edge) |edge| {
        const size = resample.fitted(current.width, current.height, edge);
        if (size.width != current.width or size.height != current.height) {
            const reduced = try resample.reduce(u16, gpa, current, size);
            if (owned) |*s| s.deinit(gpa);
            owned = reduced;
            current = reduced;
        }
    }
    try check(cancel);
    const scale = @as(f64, @floatFromInt(current.width)) / @as(f64, @floatFromInt(full_width));

    var developed = if (frame.developed)
        try look.renderBanded(gpa, current, frame.settings, frame_look, cancel)
    else
        try look.developFrame(gpa, current, .whole(current.width, current.height), frame.settings.kind, frame_look, frame.film_base, .{ .curves = frame.settings.curves(), .slide = frame.settings.slide_colour });
    defer developed.deinit(gpa);
    if (owned) |*s| {
        s.deinit(gpa);
        owned = null;
    }
    try check(cancel);
    return .{ .pixels = try convert(gpa, &developed, options, cancel), .scale = scale };
}

fn convert(gpa: std.mem.Allocator, linear: *image.Rendered, options: Options, cancel: ?*const Cancel) ConvertError!Picture.Pixels {
    return switch (options.bits()) {
        .eight => .{ .eight = try transformed(u8, gpa, linear, options.space, cancel) },
        .sixteen => .{ .sixteen = try transformed(u16, gpa, linear, options.space, cancel) },
    };
}

/// ITU-R BT.2087's matrix from Rec. 709's primaries to Rec. 2020's, both linear with a D65 white.
pub const rec709_to_rec2020 = [3][3]f32{
    .{ 0.6274040, 0.3292820, 0.0433136 },
    .{ 0.0690970, 0.9195400, 0.0113612 },
    .{ 0.0163916, 0.0880132, 0.8955950 },
};

fn toRec2020(p: [3]f32) [3]f32 {
    var out: [3]f32 = undefined;
    for (&out, rec709_to_rec2020) |*o, row| o.* = row[0] * p[0] + row[1] * p[1] + row[2] * p[2];
    return out;
}

/// Encodes `linear`, which is in Rec. 709's primaries, in `space` as `Sample`s. Afterwards
/// `linear` itself is left in Rec. 2020's primaries.
fn transformed(comptime Sample: type, gpa: std.mem.Allocator, linear: *image.Rendered, space: icc.Space, cancel: ?*const Cancel) ConvertError!image.Image([3]Sample) {
    var transform: icc.Transform(Sample) = try .init(space, .relative_colorimetric);
    defer transform.deinit();
    var out: image.Image([3]Sample) = try .init(gpa, linear.width, linear.height);
    errdefer out.deinit(gpa);
    const band = @max(1, band_rows * linear.width);
    var at: usize = 0;
    while (at < linear.pixels.len) : (at += band) {
        try check(cancel);
        const n = @min(band, linear.pixels.len - at);
        const pixels = linear.pixels[at..][0..n];
        for (pixels) |*p| p.* = toRec2020(p.*);
        transform.apply(pixels, out.pixels[at..][0..n]);
    }
    return out;
}

/// What goes into a file besides its pixels: its metadata, and the same again as an XMP packet.
pub const Embedded = struct {
    metadata: metadata.Metadata,
    xmp: []const u8,
};

pub const EncodeError = tiff.WriteError || jpeg.WriteError || icc.Error || error{
    /// A JPEG only holds 8 bits per sample.
    JpegIsEightBit,
};

/// Encodes `picture` as a file of `options.format`, with its space's ICC profile, and `embedded`
/// as EXIF and XMP if given. The caller owns the bytes.
pub fn encodeFile(gpa: std.mem.Allocator, picture: Picture, options: Options, embedded: ?Embedded) EncodeError![]u8 {
    const profile = try icc.profileBytes(gpa, options.space);
    defer gpa.free(profile);
    const plain = switch (options.format) {
        .tiff => switch (picture.pixels) {
            .eight => |p| try tiff.write(gpa, u8, p, .{ .icc_profile = profile }),
            .sixteen => |p| try tiff.write(gpa, u16, p, .{ .icc_profile = profile }),
        },
        .jpeg => switch (picture.pixels) {
            .eight => |p| try jpeg.write(gpa, p, .{
                .quality = options.quality,
                .subsampling = if (options.quality >= 90) .@"4:4:4" else .@"4:2:0",
                .icc_profile = profile,
            }),
            .sixteen => return error.JpegIsEightBit,
        },
    };
    const extra = embedded orelse return plain;
    const tagged = switch (options.format) {
        .tiff => metadata.intoTiff(gpa, plain, extra.metadata, extra.xmp),
        .jpeg => metadata.intoJpeg(gpa, plain, extra.metadata, extra.xmp),
    } catch |err| switch (err) {
        error.OutOfMemory => {
            gpa.free(plain);
            return error.OutOfMemory;
        },
        // A TIFF too big for classic TIFF's offsets is a BigTIFF, and we don't add metadata to
        // those. The sidecar still has all of it.
        error.UnexpectedFile, error.TooLarge => {
            std.log.warn("metadata not embedded: {t}; the sidecar has it", .{err});
            return plain;
        },
    };
    gpa.free(plain);
    return tagged;
}

/// Builds the metadata a file of `frame` carries, for the roll that `info` describes.
pub fn describe(info: roll.Info, frame: roll.FrameSettings, include: Include, options: Options, picture: Picture) metadata.Metadata {
    const dpi = frame.dpi orelse info.dpi;
    return .{
        .camera = if (include.camera) info.camera else null,
        .lens = if (include.lens) info.lens else null,
        .stock = if (include.stock) info.stock else null,
        .shot = if (include.shot) info.shot else null,
        .copyright = if (include.copyright) info.copyright else null,
        .develop = if (include.settings) .{
            .look = frame.look,
            .kind = frame.settings.kind,
            .settings = if (frame.developed) frame.settings else null,
            .scanner = info.scanner,
            .crop = frame.crop,
            .quarter_turns = frame.quarter_turns,
        } else null,
        .dpi = if (dpi) |d| @floatCast(@as(f64, d) * picture.scale) else null,
        .space = options.space,
        .width = picture.width(),
        .height = picture.height(),
        .rating = if (include.rating and (frame.rating.rejected or frame.rating.stars > 0)) frame.rating.xmp() else null,
        .notes = if (include.notes) info.notes else null,
        .fields = if (include.fields) info.fields else &.{},
    };
}

/// Reads the scan at `path`, of any kind `input.zig` reads.
pub fn readScan(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !image.Scan {
    return (try input.read(gpa, io, path)).scan;
}

/// The scan of the last exported frame, kept while the next frame comes from the same strip.
const Kept = struct {
    path: []const u8 = "",
    scan: ?image.Scan = null,

    /// Returns the scan at `path`, reading it unless it's the one we kept. `path` must outlive the
    /// next call.
    fn get(kept: *Kept, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !image.Scan {
        if (kept.scan) |scan| if (std.mem.eql(u8, kept.path, path)) return scan;
        kept.drop(gpa);
        kept.scan = try readScan(gpa, io, path);
        kept.path = path;
        return kept.scan.?;
    }

    fn drop(kept: *Kept, gpa: std.mem.Allocator) void {
        if (kept.scan) |*scan| scan.deinit(gpa);
        kept.* = .{};
    }
};

// File names -----------------------------------------------------------------------------------

/// The fields a file-name pattern can hold, in braces:
///
///     {roll}       the roll's name for a file: lower case, without spaces ("Roll 014" → roll014)
///     {name}       the roll's name as it is
///     {frame}      the frame's number; {frame:02} pads it with zeros to two digits
///     {stock}      the film stock, written the same way as {roll}
///     {date}       when the roll was shot, or when it was made if that's not set
///
/// Characters that can't be in a file name, such as / and :, become -.
pub const fields = [_][]const u8{ "{roll}", "{name}", "{frame}", "{frame:02}", "{stock}", "{date}" };

pub const NameError = error{
    /// A field in braces that isn't one of `fields`.
    UnknownField,
    /// A brace that's opened but never closed.
    UnclosedBrace,
    /// There's no {frame}, so every frame would write to the same file.
    NoFrameNumber,
};

/// What fills a pattern's fields for one frame.
pub const NameValues = struct {
    roll: []const u8,
    /// The frame's number in the roll, from 1.
    frame: usize,
    stock: ?[]const u8 = null,
    date: ?[]const u8 = null,
};

/// Returns the file name, without its extension, that `pattern` gives a frame. The caller owns it.
pub fn fileStem(gpa: std.mem.Allocator, pattern: []const u8, values: NameValues) (NameError || error{OutOfMemory})![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    expand(&out.writer, pattern, values) catch |err| return switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |e| e,
    };
    return out.toOwnedSlice();
}

/// Checks that `pattern` works for file names: every field known, every brace closed, and a
/// {frame} in it.
pub fn checkPattern(pattern: []const u8) NameError!void {
    var buffer: [64]u8 = undefined;
    var discard: std.Io.Writer.Discarding = .init(&buffer);
    expand(&discard.writer, pattern, .{ .roll = "roll", .frame = 1 }) catch |err| return switch (err) {
        error.WriteFailed => unreachable,
        else => |e| e,
    };
}

fn expand(w: *std.Io.Writer, pattern: []const u8, values: NameValues) (NameError || std.Io.Writer.Error)!void {
    var numbered = false;
    var rest = pattern;
    while (rest.len > 0) {
        const open = std.mem.indexOfScalar(u8, rest, '{') orelse {
            try safe(w, rest);
            break;
        };
        try safe(w, rest[0..open]);
        const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse return error.UnclosedBrace;
        const field = rest[open + 1 .. close];
        rest = rest[close + 1 ..];
        if (std.mem.eql(u8, field, "roll")) {
            try slug(w, values.roll);
        } else if (std.mem.eql(u8, field, "name")) {
            try safe(w, values.roll);
        } else if (std.mem.eql(u8, field, "stock")) {
            try slug(w, values.stock orelse "");
        } else if (std.mem.eql(u8, field, "date")) {
            try safe(w, values.date orelse "");
        } else if (std.mem.startsWith(u8, field, "frame")) {
            const padding = padding: {
                if (field.len == "frame".len) break :padding 0;
                if (field["frame".len] != ':') return error.UnknownField;
                break :padding std.fmt.parseInt(u4, field["frame:".len..], 10) catch return error.UnknownField;
            };
            var digits: [20]u8 = undefined;
            const number = std.fmt.bufPrint(&digits, "{d}", .{values.frame}) catch unreachable;
            for (0..@as(usize, padding) -| number.len) |_| try w.writeByte('0');
            try w.writeAll(number);
            numbered = true;
        } else return error.UnknownField;
    }
    if (!numbered) return error.NoFrameNumber;
}

/// Writes `text`, with anything a file name can't hold turned into -.
fn safe(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |ch| try w.writeByte(switch (ch) {
        '/', '\\', ':', '*', '?', '"', '<', '>', '|', 0...31, 127 => '-',
        else => ch,
    });
}

/// Writes `text` for a file name, in lower case. Letters, digits, - _ . and anything beyond ASCII
/// stay, and spaces and other signs are left out.
fn slug(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |ch| switch (ch) {
        'A'...'Z' => try w.writeByte(std.ascii.toLower(ch)),
        'a'...'z', '0'...'9', '-', '_', '.', 128...255 => try w.writeByte(ch),
        else => {},
    };
}

// Batches --------------------------------------------------------------------------------------

/// How far along a frame's export is.
pub const Stage = enum(u8) {
    reading,
    developing,
    encoding,
    writing,

    /// The share of a frame's work done when the stage starts.
    fn start(stage: Stage) f32 {
        return switch (stage) {
            .reading => 0,
            .developing => 0.1,
            .encoding => 0.6,
            .writing => 0.9,
        };
    }

    pub fn label(stage: Stage) []const u8 {
        return switch (stage) {
            .reading => "reading the scan",
            .developing => "developing",
            .encoding => "encoding",
            .writing => "writing",
        };
    }
};

/// A set of a roll's frames to export, and how far the export has got. It copies what it needs
/// from the roll, so the roll can change while it runs. `run` does the work, on any thread, and
/// other threads can read the progress fields in the meantime.
pub const Batch = struct {
    arena_state: std.heap.ArenaAllocator,
    options: Options,
    include: Include,
    info: roll.Info,
    /// The folder the files go to.
    folder: []const u8,
    jobs: []Job,

    /// How many frames are done, whether written or failed.
    finished: std.atomic.Value(usize) = .init(0),
    /// How many files were written.
    written: std.atomic.Value(usize) = .init(0),
    /// The frame being exported (an index in `jobs`), and its stage.
    current: std.atomic.Value(usize) = .init(0),
    stage: std.atomic.Value(Stage) = .init(.reading),
    cancel: Cancel = .init(false),
    /// Set once `run` returns.
    done: std.atomic.Value(bool) = .init(false),
    /// Read these once `done` is set: how many frames failed, and the first failure.
    failed: usize = 0,
    failure: ?Failure = null,

    pub const Job = struct {
        /// The frame's number in the roll, from 1.
        number: usize,
        scan_path: []const u8,
        frame: roll.FrameSettings,
        /// The look `frame` names, as the batch's own copy.
        look: look.Resolved,
        /// The file's name without its extension.
        stem: []const u8,
    };

    pub const Failure = struct {
        /// The frame's number, or 0 when the folder couldn't be made.
        number: usize,
        err: anyerror,
    };

    /// What to export the frames as, and where.
    pub const Request = struct {
        options: Options,
        include: Include = .{},
        /// The file names' pattern, as `fileStem` takes it.
        pattern: []const u8,
        folder: []const u8,
        /// The curves of the roll's stock, for frames that haven't been developed yet and so get
        /// automatic settings.
        stock_curves: ?stock_curves.Curves = null,
    };

    /// Makes a batch of the frames `indices` of `r`, in the looks `catalog` has for them. Free it
    /// with `destroy`.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, catalog: *look.Catalog, r: *const roll.Roll, indices: []const usize, request: Request) !*Batch {
        try checkPattern(request.pattern);
        const batch = try gpa.create(Batch);
        errdefer gpa.destroy(batch);
        batch.* = .{
            .arena_state = .init(gpa),
            .options = request.options,
            .include = request.include,
            .info = undefined,
            .folder = undefined,
            .jobs = undefined,
        };
        errdefer batch.arena_state.deinit();
        const arena = batch.arena_state.allocator();
        batch.info = try copyInfo(arena, r.info);
        batch.folder = try arena.dupe(u8, request.folder);
        batch.jobs = try arena.alloc(Job, indices.len);
        for (batch.jobs, indices) |*job, index| {
            var frame = r.frames.items[index];
            frame.scan = try arena.dupe(u8, frame.scan);
            frame.film_base = r.baseFor(index);
            if (!frame.developed) frame.settings.stock_curves = request.stock_curves;
            job.* = .{
                .number = index + 1,
                .scan_path = try std.fs.path.join(arena, &.{ r.path, roll.scans_dir, frame.scan }),
                .frame = frame,
                .look = try (try catalog.resolve(gpa, io, frame.look)).copy(arena),
                .stem = try fileStem(arena, request.pattern, .{
                    .roll = batch.info.name,
                    .frame = index + 1,
                    .stock = batch.info.stock,
                    .date = batch.info.shot orelse batch.info.created,
                }),
            };
        }
        return batch;
    }

    pub fn destroy(batch: *Batch, gpa: std.mem.Allocator) void {
        batch.arena_state.deinit();
        gpa.destroy(batch);
    }

    /// Returns the file name for `job`, as `{stem}.{extension}`. The caller owns it.
    pub fn fileName(batch: *const Batch, gpa: std.mem.Allocator, job: Job) error{OutOfMemory}![]u8 {
        return std.fmt.allocPrint(gpa, "{s}.{s}", .{ job.stem, batch.options.format.extension() });
    }

    /// The share of the work done, 0 to 1.
    pub fn progress(batch: *const Batch) f32 {
        if (batch.jobs.len == 0) return 1;
        const finished = batch.finished.load(.acquire);
        const under_way: f32 = if (finished < batch.jobs.len) batch.stage.load(.acquire).start() else 0;
        return (@as(f32, @floatFromInt(finished)) + under_way) / @as(f32, @floatFromInt(batch.jobs.len));
    }

    /// Exports the frames one at a time, until they're all done or the export is cancelled. A
    /// frame that fails is counted and skipped.
    pub fn run(batch: *Batch, gpa: std.mem.Allocator, io: std.Io) void {
        defer batch.done.store(true, .release);
        std.Io.Dir.cwd().createDirPath(io, batch.folder) catch |err| {
            batch.failed = batch.jobs.len;
            batch.failure = .{ .number = 0, .err = err };
            return;
        };
        var kept: Kept = .{};
        defer kept.drop(gpa);
        for (batch.jobs, 0..) |job, i| {
            if (batch.cancel.load(.acquire)) break;
            batch.current.store(i, .release);
            batch.exportJob(gpa, io, job, &kept) catch |err| switch (err) {
                error.Canceled => break,
                else => {
                    std.log.err("export of frame {d} failed: {t}", .{ job.number, err });
                    batch.failed += 1;
                    if (batch.failure == null) batch.failure = .{ .number = job.number, .err = err };
                },
            };
            batch.finished.store(i + 1, .release);
        }
    }

    fn exportJob(batch: *Batch, gpa: std.mem.Allocator, io: std.Io, job: Job, kept: *Kept) !void {
        batch.stage.store(.reading, .release);
        var picture = picture: {
            const scan = try kept.get(gpa, io, job.scan_path);
            try check(&batch.cancel);
            batch.stage.store(.developing, .release);
            break :picture try developPicture(gpa, scan, job.frame, job.look, batch.options, &batch.cancel);
        };
        defer picture.deinit(gpa);

        batch.stage.store(.encoding, .release);
        const described = describe(batch.info, job.frame, batch.include, batch.options, picture);
        const packet = try metadata.xmp(gpa, described);
        defer gpa.free(packet);
        const file = try encodeFile(gpa, picture, batch.options, .{ .metadata = described, .xmp = packet });
        defer gpa.free(file);
        try check(&batch.cancel);

        batch.stage.store(.writing, .release);
        const cwd = std.Io.Dir.cwd();
        const name = try batch.fileName(gpa, job);
        defer gpa.free(name);
        const path = try std.fs.path.join(gpa, &.{ batch.folder, name });
        defer gpa.free(path);
        try cwd.writeFile(io, .{ .sub_path = path, .data = file });
        const sidecar_name = try std.fmt.allocPrint(gpa, "{s}.xmp", .{job.stem});
        defer gpa.free(sidecar_name);
        const sidecar = try std.fs.path.join(gpa, &.{ batch.folder, sidecar_name });
        defer gpa.free(sidecar);
        try cwd.writeFile(io, .{ .sub_path = sidecar, .data = packet });
        _ = batch.written.fetchAdd(1, .acq_rel);
    }
};

/// Copies `info` and all the text in it into `arena`.
fn copyInfo(arena: std.mem.Allocator, info: roll.Info) !roll.Info {
    var copy = info;
    const info_type = @typeInfo(roll.Info).@"struct";
    inline for (info_type.field_names, info_type.field_types) |name, Field| {
        const value = @field(info, name);
        @field(copy, name) = switch (Field) {
            []const u8 => try arena.dupe(u8, value),
            ?[]const u8 => if (value) |text| try arena.dupe(u8, text) else null,
            []const roll.Field => fields: {
                const own = try arena.alloc(roll.Field, value.len);
                for (own, value) |*copied, f| copied.* = .{ .name = try arena.dupe(u8, f.name), .value = try arena.dupe(u8, f.value) };
                break :fields own;
            },
            else => value,
        };
    }
    return copy;
}

// Tests ----------------------------------------------------------------------------------------

test {
    _ = metadata;
    _ = resample;
}

test "file names follow the pattern" {
    const gpa = std.testing.allocator;
    const name = try fileStem(gpa, "{roll}_{frame:02}", .{ .roll = "Roll 014", .frame = 3 });
    defer gpa.free(name);
    try std.testing.expectEqualStrings("roll014_03", name);
    const other = try fileStem(gpa, "{name}/{stock} {frame}", .{ .roll = "Roll: 2", .frame = 12, .stock = "Kodak Portra 400" });
    defer gpa.free(other);
    try std.testing.expectEqualStrings("Roll- 2-kodakportra400 12", other);
    try std.testing.expectError(error.NoFrameNumber, checkPattern("{roll}"));
    try std.testing.expectError(error.UnknownField, checkPattern("{roll}_{frmae}"));
    try std.testing.expectError(error.UnclosedBrace, checkPattern("{frame"));
    try checkPattern("{date}-{frame:3}");
}

test "sRGB out of the colour pipeline matches the sRGB curve" {
    const gpa = std.testing.allocator;
    var rendered: image.Rendered = try .init(gpa, 4, 1);
    defer rendered.deinit(gpa);
    for (rendered.pixels, [_][3]f32{ .{ 0.18, 0.18, 0.18 }, .{ 0.9, 0.3, 0.05 }, .{ 0, 0, 0 }, .{ 1, 1, 1 } }) |*p, v| p.* = v;
    var expected = try encode.toSrgb8(gpa, rendered);
    defer expected.deinit(gpa);
    var pixels = try convert(gpa, &rendered, .{ .format = .jpeg, .space = .srgb }, null);
    defer pixels.eight.deinit(gpa);
    for (expected.pixels, pixels.eight.pixels) |e, a| {
        for (e, a) |x, y| try std.testing.expect(@abs(@as(i16, x) - @as(i16, y)) <= 1);
    }
}

test "sRGB red is inside Display P3, less saturated there" {
    const gpa = std.testing.allocator;
    var rendered: image.Rendered = try .init(gpa, 1, 1);
    defer rendered.deinit(gpa);
    rendered.pixels[0] = .{ 1, 0, 0 };
    var pixels = try convert(gpa, &rendered, .{ .format = .tiff, .depth = .eight, .space = .display_p3 }, null);
    defer pixels.eight.deinit(gpa);
    // sRGB's red in Display P3 is (0.9175, 0.2003, 0.1386), encoded.
    const red = pixels.eight.pixels[0];
    try std.testing.expectApproxEqAbs(@as(f32, 234), @as(f32, @floatFromInt(red[0])), 2);
    try std.testing.expectApproxEqAbs(@as(f32, 51), @as(f32, @floatFromInt(red[1])), 2);
    try std.testing.expectApproxEqAbs(@as(f32, 35), @as(f32, @floatFromInt(red[2])), 2);
}

/// A smooth negative-looking scan for the tests.
fn testScan(gpa: std.mem.Allocator, width: usize, height: usize) !image.Scan {
    const scan: image.Scan = try .init(gpa, width, height);
    for (scan.pixels, 0..) |*p, i| p.* = .{ @intCast(20000 + i * 7 % 30000), @intCast(12000 + i * 5 % 20000), @intCast(8000 + i * 3 % 10000) };
    return scan;
}

test "a frame is cropped, turned, then reduced, and its TIFF holds its profile" {
    const gpa = std.testing.allocator;
    var scan = try testScan(gpa, 40, 30);
    defer scan.deinit(gpa);
    const frame: roll.FrameSettings = .{ .scan = "01.ppm", .crop = .{ .x = 5, .y = 5, .width = 20, .height = 10 }, .quarter_turns = 1 };
    const options: Options = .{ .format = .tiff, .depth = .sixteen, .space = .adobe_rgb, .long_edge = 8 };
    var picture = try developPicture(gpa, scan, frame, .neutral, options, null);
    defer picture.deinit(gpa);
    // 20 × 10, turned to 10 × 20, reduced to 4 × 8.
    try std.testing.expectEqual(@as(usize, 4), picture.width());
    try std.testing.expectEqual(@as(usize, 8), picture.height());
    try std.testing.expectEqual(@as(f64, 0.4), picture.scale);

    const info: roll.Info = .{ .name = "Roll 001", .camera = "Pentax MX", .dpi = 2400 };
    const described = describe(info, frame, .{}, options, picture);
    try std.testing.expectEqual(@as(?f32, 960), described.dpi);
    // An unrated frame has no rating to give, a rated one gives its stars, and a rejected one -1,
    // unless the rating is left out.
    try std.testing.expectEqual(@as(?i8, null), described.rating);
    var rated = frame;
    rated.rating = .{ .stars = 3 };
    try std.testing.expectEqual(@as(?i8, 3), describe(info, rated, .{}, options, picture).rating);
    rated.rating.rejected = true;
    try std.testing.expectEqual(@as(?i8, -1), describe(info, rated, .{}, options, picture).rating);
    try std.testing.expectEqual(@as(?i8, null), describe(info, rated, .{ .rating = false }, options, picture).rating);
    const packet = try metadata.xmp(gpa, described);
    defer gpa.free(packet);
    const file = try encodeFile(gpa, picture, options, .{ .metadata = described, .xmp = packet });
    defer gpa.free(file);
    var decoded = try tiff.read(gpa, file);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(image.Depth.sixteen, decoded.depth);
    const profile = try icc.profileBytes(gpa, .adobe_rgb);
    defer gpa.free(profile);
    try std.testing.expect(icc.sameProfile(profile, decoded.icc_profile.?));
}

test "a crop outside the scan is refused" {
    const gpa = std.testing.allocator;
    var scan = try testScan(gpa, 10, 10);
    defer scan.deinit(gpa);
    try std.testing.expectError(error.CropOutsideScan, developPicture(gpa, scan, .{ .scan = "01.ppm", .crop = .{ .x = 5, .y = 0, .width = 6, .height = 2 } }, .neutral, .{}, null));
}

test "a batch writes each frame's file and sidecar, and stops when cancelled" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);

    var r = try roll.Roll.create(gpa, io, library, .{ .name = "Roll 014", .stock = "Kodak Portra 400", .copyright = "A. Person" });
    defer r.close();
    var scan = try testScan(gpa, 24, 16);
    defer scan.deinit(gpa);
    const ppm = try pnm.write(gpa, u16, scan);
    defer gpa.free(ppm);
    for (0..3) |_| _ = try r.addScan(gpa, io, ppm);

    const folder = try std.fs.path.join(gpa, &.{ r.path, roll.exports_dir });
    defer gpa.free(folder);
    var catalog: look.Catalog = try .init(gpa, library);
    defer catalog.deinit(gpa);
    const batch = try Batch.create(gpa, io, &catalog, &r, &.{ 0, 2 }, .{
        .options = .{ .format = .jpeg, .space = .srgb },
        .pattern = "{roll}_{frame:02}",
        .folder = folder,
    });
    defer batch.destroy(gpa);
    batch.run(gpa, io);
    try std.testing.expect(batch.done.load(.acquire));
    try std.testing.expectEqual(@as(usize, 2), batch.written.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), batch.failed);
    try std.testing.expectEqual(@as(f32, 1), batch.progress());

    const cwd = std.Io.Dir.cwd();
    for ([_][]const u8{ "roll014_01.jpg", "roll014_03.jpg", "roll014_03.xmp" }) |name| {
        const path = try std.fs.path.join(gpa, &.{ folder, name });
        defer gpa.free(path);
        const bytes = try cwd.readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        if (std.mem.endsWith(u8, name, ".xmp")) {
            try std.testing.expect(std.mem.indexOf(u8, bytes, "A. Person") != null);
        } else {
            var decoded = try jpeg.read(gpa, bytes);
            defer decoded.deinit(gpa);
            try std.testing.expectEqual(@as(usize, 24), decoded.image.width);
        }
    }

    const stopped = try Batch.create(gpa, io, &catalog, &r, &.{ 0, 1, 2 }, .{ .options = .{}, .pattern = "again_{frame}", .folder = folder });
    defer stopped.destroy(gpa);
    stopped.cancel.store(true, .release);
    stopped.run(gpa, io);
    try std.testing.expectEqual(@as(usize, 0), stopped.written.load(.acquire));
}

test "frames of one strip export from the scan they share, each to its crop" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);
    var r = try roll.Roll.create(gpa, io, library, .{ .name = "Strip" });
    defer r.close();

    const synthetic = @import("../frames/synthetic.zig");
    var on_film: [4]synthetic.Frame = undefined;
    const strip = synthetic.strip135(&on_film);
    var scan = try strip.render(gpa);
    defer scan.deinit(gpa);
    const added = try r.addImage(gpa, io, scan, strip.dpi);
    try std.testing.expectEqual(on_film.len, added.count);

    const folder = try std.fs.path.join(gpa, &.{ r.path, roll.exports_dir });
    defer gpa.free(folder);
    var catalog: look.Catalog = try .init(gpa, library);
    defer catalog.deinit(gpa);
    const batch = try Batch.create(gpa, io, &catalog, &r, &.{ 0, 3 }, .{
        .options = .{ .format = .tiff, .depth = .eight, .space = .srgb },
        .pattern = "strip_{frame}",
        .folder = folder,
    });
    defer batch.destroy(gpa);
    batch.run(gpa, io);
    try std.testing.expectEqual(@as(usize, 2), batch.written.load(.acquire));
    for ([_][]const u8{ "strip_1.tif", "strip_4.tif" }, [_]usize{ 0, 3 }) |name, index| {
        const path = try std.fs.path.join(gpa, &.{ folder, name });
        defer gpa.free(path);
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20));
        defer gpa.free(bytes);
        var decoded = try tiff.read(gpa, bytes);
        defer decoded.deinit(gpa);
        const crop = r.frames.items[index].crop.?;
        try std.testing.expectEqual(crop.width, decoded.scan.width);
        try std.testing.expectEqual(crop.height, decoded.scan.height);
    }
}
