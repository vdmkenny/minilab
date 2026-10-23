//! A frame that's open for developing: a reduced copy of its scan for the viewer, its settings,
//! and the viewer's renderings of it as a negative and a positive.

const std = @import("std");
const minilab = @import("minilab");

const image = minilab.image;
const develop = minilab.develop;
const look = minilab.look;

/// The viewer's copy of a frame is at most this many pixels along its longer side.
pub const preview_longest = 1600;
/// The most pixels along the longer side of a strip's reduced copy, which its frames are cut from.
/// It's this big so that a frame on a long strip still gets most of `preview_longest`.
const strip_longest = 8192;
/// The number of bins in the rendering's histogram.
pub const histogram_bins = 256;
/// The size of the square that's averaged when you pick a point, in preview pixels.
const pick_size = 5;

pub const Histogram = [histogram_bins][image.channel_count]u32;

pub const Frame = struct {
    name: []const u8,
    /// The scan's size, for the info line and for crops (which are in the scan's pixels).
    scan_width: usize,
    scan_height: usize,
    /// A reduced copy of the whole scan, which crops are cut from.
    full: image.Scan,
    /// The frame's part of the scan: `crop` of it, mirrored if `mirrored`, then turned by
    /// `quarter_turns`. A null crop means the whole scan.
    crop: ?image.Area = null,
    quarter_turns: u2 = 0,
    mirrored: bool = false,
    /// What the viewer shows: `full` cropped and turned.
    preview: image.Scan,
    /// Statistics for the middle of the frame (`centre`) and all of it (`whole`), for the
    /// automatic settings.
    centre: develop.Statistics,
    whole: develop.Statistics,
    look: look.Id = .neutral,
    settings: develop.Settings = .{},
    /// The stock's layer slopes on this scanner, for Stock balance. Null without a preset or a
    /// calibrated scanner (`calibration`).
    stock_slopes: ?[3]f32 = null,
    /// The film base measured in the gaps beside the frame, or the roll's base when the frame's
    /// own is far off or missing (`roll.Roll.baseFor`).
    gap_base: ?[3]f32 = null,
    /// Whether `gap_base` is the roll's rather than the frame's own.
    base_from_roll: bool = false,
    /// The viewer's rendering, in RGBA, the same size as `preview`.
    rendered: [][4]u8,
    /// The scan as it is, like a negative on a light table, in RGBA. The viewer shows it for
    /// comparison.
    negative: [][4]u8,
    histogram: Histogram = std.mem.zeroes(Histogram),
    /// The share of pixels clipped to black, and to white, in at least one channel.
    clipped_shadows: f32 = 0,
    clipped_highlights: f32 = 0,
    /// Whether `rendered` is out of date with the settings.
    stale: bool = true,

    /// Loads the scan at `path` (any kind `minilab.input` can read) as the frame `name`, cut to
    /// `crop` and turned, with default settings. The caller then measures the settings or applies
    /// saved ones.
    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: []const u8, name: []const u8, crop: ?image.Area, quarter_turns: u2, mirrored: bool) !Frame {
        var scan = (try minilab.input.read(gpa, io, path)).scan;
        defer scan.deinit(gpa);
        var full = try image.downscale(gpa, scan, reducedLongest(scan, crop));
        errdefer full.deinit(gpa);
        var frame: Frame = .{
            .name = try gpa.dupe(u8, name),
            .scan_width = scan.width,
            .scan_height = scan.height,
            .full = full,
            .preview = .{ .width = 0, .height = 0, .pixels = &.{} },
            .centre = undefined,
            .whole = undefined,
            .rendered = &.{},
            .negative = &.{},
        };
        errdefer gpa.free(frame.name);
        try frame.setGeometry(gpa, crop, quarter_turns, mirrored);
        return frame;
    }

    pub fn close(frame: *Frame, gpa: std.mem.Allocator) void {
        gpa.free(frame.name);
        frame.full.deinit(gpa);
        frame.dropPreview(gpa);
        frame.* = undefined;
    }

    fn dropPreview(frame: *Frame, gpa: std.mem.Allocator) void {
        gpa.free(frame.preview.pixels);
        gpa.free(frame.rendered);
        gpa.free(frame.negative);
        frame.preview = .{ .width = 0, .height = 0, .pixels = &.{} };
        frame.rendered = &.{};
        frame.negative = &.{};
    }

    /// How many of the scan's pixels there are per pixel of `full`.
    pub fn scale(frame: *const Frame) f64 {
        return @as(f64, @floatFromInt(frame.scan_width)) / @as(f64, @floatFromInt(frame.full.width));
    }

    /// Cuts the viewer's copy to `crop` (in the scan's pixels, or null for all of it), turns it
    /// and measures it again. The settings stay as they are; the caller re-measures them if it
    /// wants.
    pub fn setGeometry(frame: *Frame, gpa: std.mem.Allocator, crop: ?image.Area, quarter_turns: u2, mirrored: bool) !void {
        const area: image.Area = if (crop) |c| c.rescale(frame.scan_width, frame.full.width, frame.full.width, frame.full.height) else .whole(frame.full.width, frame.full.height);
        var cut = try frame.full.crop(gpa, area);
        defer cut.deinit(gpa);
        var preview = try cut.orient(gpa, quarter_turns, mirrored);
        errdefer preview.deinit(gpa);
        const rendered = try gpa.alloc([4]u8, preview.pixels.len);
        errdefer gpa.free(rendered);
        const negative = try gpa.alloc([4]u8, preview.pixels.len);
        errdefer gpa.free(negative);
        const stats = try develop.FrameStatistics.measure(gpa, preview);
        frame.dropPreview(gpa);
        frame.preview = preview;
        frame.rendered = rendered;
        frame.negative = negative;
        frame.centre = stats.centre;
        frame.whole = stats.whole;
        frame.crop = crop;
        frame.quarter_turns = quarter_turns;
        frame.mirrored = mirrored;
        frame.stale = true;
        frame.fillNegative();
    }

    /// Fills `negative` with the frame as it looks on a light table, with the film base showing
    /// nearly white through the mask. The base comes from the gaps when it's known, or else from
    /// the frame's thinnest film.
    pub fn fillNegative(frame: *Frame) void {
        const gain = minilab.light_table.gainForBase(frame.gap_base orelse frame.whole.thinnest);
        minilab.light_table.toScreen(frame.preview.pixels, gain, frame.negative);
    }

    /// Runs frame detection on the scan and returns the frame it finds, in the scan's pixels.
    /// `dpi` is the scan's resolution; pass null to have it guessed.
    pub fn detect(frame: *const Frame, gpa: std.mem.Allocator, format: minilab.formats.Format, dpi: ?f32) !image.Area {
        return minilab.framing.find(gpa, frame.full, frame.scan_width, frame.scan_height, dpi, format, frame.settings.kind);
    }

    /// Works out the automatic settings for film `kind` on the measured base, and balances them
    /// the way the settings ask.
    pub fn measure(frame: *Frame, kind: develop.FilmKind) void {
        const keep = frame.settings;
        frame.settings = develop.automatic(kind, frame.gap_base orelse frame.whole.thinnest, frame.centre, keep.curves());
        if (frame.gap_base != null) frame.settings.base_source = .gaps;
        keepUserChoices(&frame.settings, keep);
        frame.rebalance(if (keep.white_balance == .picked) .auto_neutral else keep.white_balance, null);
    }

    /// The automatic settings for the frame on its current film base. Develop's sliders reset to
    /// these.
    pub fn automaticSettings(frame: *const Frame) develop.Settings {
        return develop.automatic(frame.settings.kind, frame.settings.base, frame.centre, frame.settings.curves());
    }

    /// Sets the balance with `mode`. For `.picked`, `picked` is the transmission to make neutral.
    pub fn rebalance(frame: *Frame, mode: develop.WhiteBalance, picked: ?[3]f32) void {
        frame.settings = develop.balanced(frame.settings, mode, frame.centre, picked, frame.stock_slopes);
        frame.stale = true;
    }

    /// The mean transmission (0 to 1) of the few preview pixels around (`x`, `y`).
    pub fn sample(frame: *const Frame, x: usize, y: usize) [3]f32 {
        const half = pick_size / 2;
        const x0 = x -| half;
        const y0 = y -| half;
        const x1 = @min(frame.preview.width, x + half + 1);
        const y1 = @min(frame.preview.height, y + half + 1);
        var sum: [3]f32 = @splat(0);
        for (y0..y1) |row| {
            for (frame.preview.row(row)[x0..x1]) |p| {
                for (&sum, p) |*s, v| s.* += @as(f32, @floatFromInt(v)) / image.full_scale;
            }
        }
        const count: f32 = @floatFromInt((x1 - x0) * (y1 - y0));
        for (&sum) |*s| s.* /= count;
        return sum;
    }

    /// Takes the film base from the point (`x`, `y`) on the preview, and works out the other
    /// settings again.
    pub fn pickBase(frame: *Frame, x: usize, y: usize) void {
        const keep = frame.settings;
        frame.settings = develop.automatic(keep.kind, frame.sample(x, y), frame.centre, keep.curves());
        frame.settings.base_source = .picked;
        keepUserChoices(&frame.settings, keep);
        frame.rebalance(if (keep.white_balance == .picked) .auto_neutral else keep.white_balance, null);
    }

    /// Makes the point (`x`, `y`) on the preview neutral.
    pub fn pickNeutral(frame: *Frame, x: usize, y: usize) void {
        frame.rebalance(.picked, frame.sample(x, y));
    }

    /// Renders the viewer's copy with the current settings and the frame's look, which it gets
    /// from `catalog`.
    pub fn render(frame: *Frame, gpa: std.mem.Allocator, io: std.Io, catalog: *look.Catalog) !void {
        const started = std.Io.Clock.awake.now(io);
        defer std.log.scoped(.develop).debug("rendered {d} × {d} in {d} ms", .{ frame.preview.width, frame.preview.height, @divTrunc(started.durationTo(std.Io.Clock.awake.now(io)).toNanoseconds(), std.time.ns_per_ms) });
        frame.histogram = std.mem.zeroes(Histogram);
        var linear = try look.render(gpa, frame.preview, frame.settings, catalog.resolve(gpa, io, frame.look));
        defer linear.deinit(gpa);
        var encoded = try minilab.encode.toSrgb8(gpa, linear);
        defer encoded.deinit(gpa);
        frame.store(encoded);
        frame.stale = false;
    }

    fn store(frame: *Frame, encoded: image.Encoded8) void {
        var black: usize = 0;
        var white: usize = 0;
        for (frame.rendered, encoded.pixels) |*out, p| {
            out.* = .{ p[0], p[1], p[2], std.math.maxInt(u8) };
            for (p, 0..) |v, c| frame.histogram[v][c] += 1;
            if (@min(p[0], p[1], p[2]) == 0) black += 1;
            if (@max(p[0], p[1], p[2]) == std.math.maxInt(u8)) white += 1;
        }
        const total: f32 = @floatFromInt(@max(1, frame.rendered.len));
        frame.clipped_shadows = @as(f32, @floatFromInt(black)) / total;
        frame.clipped_highlights = @as(f32, @floatFromInt(white)) / total;
    }
};

/// Keeps the user's own choices through a fresh measurement: the tone, temperature and tint. It
/// also keeps the roll's stock curves and the camera's colour, since those belong to the film and
/// the scan.
fn keepUserChoices(settings: *develop.Settings, keep: develop.Settings) void {
    settings.tone = keep.tone;
    settings.temperature = keep.temperature;
    settings.tint = keep.tint;
    settings.stock_curves = keep.stock_curves;
    settings.slide_colour = keep.slide_colour;
}

/// How long the longer side of `scan`'s reduced copy should be, when frame `crop` is cut from it.
/// For a frame of a strip, it's `preview_longest` times the whole number of times the scan is
/// longer than the frame, so the frame still gets `preview_longest` (up to `strip_longest`).
fn reducedLongest(scan: image.Scan, crop: ?image.Area) usize {
    const area = crop orelse return preview_longest;
    const times = @max(scan.width, scan.height) / @max(1, area.width, area.height);
    return @min(preview_longest * @max(1, times), strip_longest);
}
