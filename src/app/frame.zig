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
    /// The scan's file, for the loupe, which reads it at full resolution.
    path: []const u8,
    /// The scan at full resolution, read the first time the loupe needs it.
    full_scan: ?image.Scan = null,
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
    /// `preview` with its dust removed, and the settings it was removed with, so moving another
    /// slider doesn't look for the dust again.
    cleaned: ?Cleaned = null,
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
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        var frame: Frame = .{
            .name = try gpa.dupe(u8, name),
            .path = owned_path,
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
        gpa.free(frame.path);
        if (frame.full_scan) |*s| s.deinit(gpa);
        frame.full.deinit(gpa);
        frame.dropPreview(gpa);
        frame.* = undefined;
    }

    const Cleaned = struct { scan: image.Scan, with: minilab.dust.Settings, finished: bool };

    fn dropPreview(frame: *Frame, gpa: std.mem.Allocator) void {
        frame.dropCleaned(gpa);
        gpa.free(frame.preview.pixels);
        gpa.free(frame.rendered);
        gpa.free(frame.negative);
        frame.preview = .{ .width = 0, .height = 0, .pixels = &.{} };
        frame.rendered = &.{};
        frame.negative = &.{};
    }

    fn dropCleaned(frame: *Frame, gpa: std.mem.Allocator) void {
        if (frame.cleaned) |*c| c.scan.deinit(gpa);
        frame.cleaned = null;
    }

    /// The viewer's copy with its dust removed as the settings ask. It's worked out again only
    /// when the dust settings or the crop change.
    fn withoutDust(frame: *Frame, gpa: std.mem.Allocator) !image.Scan {
        const s = frame.settings;
        if (frame.cleaned) |c| {
            if (std.meta.eql(c.with, s.dust) and c.finished == s.finished) return c.scan;
            frame.dropCleaned(gpa);
        }
        const cleaned = try s.withoutDust(gpa, frame.preview, @max(frame.preview.width, frame.preview.height)) orelse return frame.preview;
        frame.cleaned = .{ .scan = cleaned, .with = s.dust, .finished = s.finished };
        return cleaned;
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
        // A finished picture has nothing to work out: it stays as it is.
        if (keep.finished) {
            frame.settings = .finishedPicture();
            frame.stale = true;
            return;
        }
        frame.settings = develop.automatic(kind, frame.gap_base orelse frame.whole.thinnest, frame.centre, keep.curves());
        if (frame.gap_base != null) frame.settings.base_source = .gaps;
        keepUserChoices(&frame.settings, keep);
        frame.rebalance(if (keep.white_balance == .picked) .auto_neutral else keep.white_balance, null);
    }

    /// The automatic settings for the frame on its current film base. Develop's sliders reset to
    /// these.
    pub fn automaticSettings(frame: *const Frame) develop.Settings {
        if (frame.settings.finished) return .finishedPicture();
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
        var linear = try look.render(gpa, try frame.withoutDust(gpa), frame.settings, try catalog.resolve(gpa, io, frame.look));
        defer linear.deinit(gpa);
        var encoded = try minilab.encode.toSrgb8(gpa, linear);
        defer encoded.deinit(gpa);
        frame.store(encoded);
        frame.stale = false;
    }

    /// Where the point `at` on the preview (in its pixels, after the crop and the turns) falls on
    /// the scan, in the scan's pixels. The preview is the crop of `full`, mirrored, then turned, so
    /// this undoes the turn, then the mirror, then the crop and the reduction.
    pub fn scanPoint(frame: *const Frame, at: [2]f32) [2]f32 {
        const turned = frame.quarter_turns % 2 == 1;
        // The size of the crop before it was turned.
        const w: f32 = @floatFromInt(if (turned) frame.preview.height else frame.preview.width);
        const h: f32 = @floatFromInt(if (turned) frame.preview.width else frame.preview.height);
        var p: [2]f32 = switch (frame.quarter_turns) {
            0 => at,
            1 => .{ at[1], h - at[0] },
            2 => .{ w - at[0], h - at[1] },
            3 => .{ w - at[1], at[0] },
        };
        if (frame.mirrored) p[0] = w - p[0];
        const area: image.Area = if (frame.crop) |c| c.rescale(frame.scan_width, frame.full.width, frame.full.width, frame.full.height) else .whole(frame.full.width, frame.full.height);
        const s: f32 = @floatCast(frame.scale());
        return .{ (@as(f32, @floatFromInt(area.x)) + p[0]) * s, (@as(f32, @floatFromInt(area.y)) + p[1]) * s };
    }

    /// What the loupe shows: RGBA pixels, row by row.
    pub const Patch = struct {
        pixels: [][4]u8,
        width: usize,
        height: usize,
    };

    /// Renders the square of the scan at full resolution, `side` pixels a side, around the point
    /// `at` on the preview, cut and turned like the frame. It's developed with the frame's
    /// settings and look, or shown as the negative when `negative`. The square stays inside the
    /// crop, and is smaller if the crop is. The full scan is read the first time. Free the pixels
    /// with `gpa`. Dust is looked for on a bigger square around it, so the specks found near its
    /// edge are the ones an export finds.
    pub fn loupe(frame: *Frame, gpa: std.mem.Allocator, io: std.Io, catalog: *look.Catalog, at: [2]f32, side: usize, negative: bool) !Patch {
        if (frame.full_scan == null) frame.full_scan = (try minilab.input.read(gpa, io, frame.path)).scan;
        const scan = frame.full_scan.?;
        const bounds: image.Area = frame.crop orelse .whole(scan.width, scan.height);
        const centre = frame.scanPoint(at);
        const width = @min(side, bounds.width);
        const height = @min(side, bounds.height);
        const area: image.Area = .{
            .x = squareStart(centre[0], width, bounds.x, bounds.width),
            .y = squareStart(centre[1], height, bounds.y, bounds.height),
            .width = width,
            .height = height,
        };
        var square = try scan.crop(gpa, area);
        defer square.deinit(gpa);
        if (!negative and frame.settings.dust.remove) {
            const longest = @max(bounds.width, bounds.height);
            const around = area.grown(minilab.dust.margin(longest, frame.settings.dust), bounds);
            var context = try scan.crop(gpa, around);
            defer context.deinit(gpa);
            if (try frame.settings.withoutDust(gpa, context, longest)) |cleaned| {
                var clean = cleaned;
                defer clean.deinit(gpa);
                for (0..square.height) |y| @memcpy(square.row(y), clean.row(area.y - around.y + y)[area.x - around.x ..][0..square.width]);
            }
        }
        var turned = try square.orient(gpa, frame.quarter_turns, frame.mirrored);
        defer turned.deinit(gpa);
        const pixels = try gpa.alloc([4]u8, turned.pixels.len);
        errdefer gpa.free(pixels);
        if (negative) {
            minilab.light_table.toScreen(turned.pixels, minilab.light_table.gainForBase(frame.gap_base orelse frame.whole.thinnest), pixels);
        } else {
            var linear = try look.render(gpa, turned, frame.settings, try catalog.resolve(gpa, io, frame.look));
            defer linear.deinit(gpa);
            minilab.encode.toRgba8(linear, pixels);
        }
        return .{ .pixels = pixels, .width = turned.width, .height = turned.height };
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

/// Keeps the user's own choices through a fresh measurement: the tone, temperature, tint and dust
/// removal. It also keeps the roll's stock curves and the camera's colour, since those belong to
/// the film and the scan.
fn keepUserChoices(settings: *develop.Settings, keep: develop.Settings) void {
    settings.tone = keep.tone;
    settings.temperature = keep.temperature;
    settings.tint = keep.tint;
    settings.stock_curves = keep.stock_curves;
    settings.slide_colour = keep.slide_colour;
    settings.finished = keep.finished;
    settings.dust = keep.dust;
}

/// Where a run `length` long, centred on `centre`, starts so that it stays inside the run from
/// `start` that's `room` long.
fn squareStart(centre: f32, length: usize, start: usize, room: usize) usize {
    const wanted = @round(centre - @as(f32, @floatFromInt(length)) / 2);
    const lowest: f32 = @floatFromInt(start);
    const highest: f32 = @floatFromInt(start + room - length);
    return @intFromFloat(std.math.clamp(wanted, lowest, highest));
}

/// How long the longer side of `scan`'s reduced copy should be, when frame `crop` is cut from it.
/// For a frame of a strip, it's `preview_longest` times the whole number of times the scan is
/// longer than the frame, so the frame still gets `preview_longest` (up to `strip_longest`).
fn reducedLongest(scan: image.Scan, crop: ?image.Area) usize {
    const area = crop orelse return preview_longest;
    const times = @max(scan.width, scan.height) / @max(1, area.width, area.height);
    return @min(preview_longest * @max(1, times), strip_longest);
}

test "a point on the preview finds its pixel on the scan, however the frame is turned" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Every pixel different: x in red, y in green.
    var scan: image.Scan = try .init(gpa, 40, 20);
    defer scan.deinit(gpa);
    for (scan.pixels, 0..) |*px, i| px.* = .{ @intCast(i % 40), @intCast(i / 40), 0 };
    const bytes = try minilab.pnm.write(gpa, u16, scan);
    defer gpa.free(bytes);
    try tmp.dir.writeFile(io, .{ .sub_path = "scan.ppm", .data = bytes });
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);
    const path = try std.fs.path.join(gpa, &.{ folder, "scan.ppm" });
    defer gpa.free(path);

    const crop: image.Area = .{ .x = 10, .y = 4, .width = 20, .height = 10 };
    for ([_]bool{ false, true }) |mirrored| {
        for (0..4) |turns| {
            var frame: Frame = try .load(gpa, io, path, "test", crop, @intCast(turns), mirrored);
            defer frame.close(gpa);
            for (0..frame.preview.height) |y| for (0..frame.preview.width) |x| {
                const at = frame.scanPoint(.{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 });
                const expected = frame.preview.pixels[y * frame.preview.width + x];
                try std.testing.expectEqual(expected[0], @as(u16, @intFromFloat(@floor(at[0]))));
                try std.testing.expectEqual(expected[1], @as(u16, @intFromFloat(@floor(at[1]))));
            };
        }
    }
}

test "the loupe's square stays inside the crop" {
    try std.testing.expectEqual(@as(usize, 10), squareStart(5, 10, 10, 100));
    try std.testing.expectEqual(@as(usize, 45), squareStart(50, 10, 10, 100));
    try std.testing.expectEqual(@as(usize, 100), squareStart(200, 10, 10, 100));
}
