//! Frame detection on a strip preview. Design section 6 walks through the steps: classify the
//! scan, fit the opening, find the gaps, snap each frame to the format, and fill in weak frames
//! from the pitch. Positives turn the gap test around, and mounted slides are found by their
//! apertures (`Holder.mounted`).
//!
//! The scan is reduced to one value per pixel (the geometric mean of its channels) and read in
//! strip coordinates: `u` counts lines along the strip and `v` counts samples across it, whichever
//! image axis the strip runs along. Positions are continuous, so sample `i` covers `[i, i + 1)`.

const std = @import("std");
const image = @import("../core/image.zig");
const stats = @import("../core/stats.zig");
const formats = @import("formats.zig");

/// Which way round the gap test works.
pub const Kind = enum {
    /// The gaps between frames are clear film base, the most transparent part of the film.
    negative,
    /// The gaps between frames are unexposed, so they're opaque.
    positive,

    /// How far a line's density can be from the gap level and still count as gap. Positives get
    /// more room, because their gap level is down in the scanner's noise.
    pub fn defaultGapTolerance(kind: Kind) f32 {
        return switch (kind) {
            .negative => 0.08,
            .positive => 0.25,
        };
    }

    /// Whether a line whose quartiles are `spread` apart in density is flat enough to be a gap.
    /// On a negative the clear base is flat, while even a thin picture shows some texture. On a
    /// positive the gap is down in the scanner's noise, where the spread tells us nothing.
    fn isFlat(kind: Kind, spread: f32) bool {
        return switch (kind) {
            .negative => spread < flat_spread,
            .positive => true,
        };
    }
};

pub const Holder = enum {
    /// A strip of film in a holder. The holder's long edges are the edges of the opening.
    strip,
    /// Mounted slides. Each mount is opaque, and its aperture is the frame.
    mounted,

    pub fn label(holder: Holder) [:0]const u8 {
        return switch (holder) {
            .strip => "Strip",
            .mounted => "Mounted",
        };
    }
};

/// The image axis the strip runs along.
pub const Axis = enum { x, y };

pub const Confidence = enum {
    confident,
    /// The frame was filled in from the pitch, measured far from the format's size, or cut off,
    /// so the user should take a look.
    check,
};

pub const Frame = struct {
    /// The frame's place in the order of the holder's openings, then along each one, counting
    /// from 0.
    index: usize,
    /// The opening it's in, in `Detection.openings`.
    opening: usize = 0,
    /// The frame's box before rotation: centred on the frame, the size of the frame, and clipped
    /// to the scan.
    area: image.Area,
    /// The frame is `area` rotated by this many degrees about its centre. Positive is clockwise
    /// as displayed, with y pointing down.
    rotation_degrees: f32,
    confidence: Confidence,
};

pub const Options = struct {
    /// The image axis the strip runs along, or null to detect it.
    axis: ?Axis = null,
    holder: Holder = .strip,
    /// A frame whose measured length is off from the format's by more than this fraction is
    /// marked for checking.
    length_tolerance: f32 = 0.12,
    /// In density. Null uses the kind's default.
    gap_tolerance: ?f32 = null,
    /// The largest skew of the strip we search for.
    max_skew_degrees: f32 = 3,
};

/// One of the holder's openings, which a strip of film lies in. A flatbed's film holder can have
/// several side by side, like four rows of 35mm.
pub const Opening = struct {
    /// Its middle across the strip, halfway along, in scan pixels.
    middle_px: f32,
    /// Its height across the strip.
    height_mm: f32,
    /// Its skew, with the same sign as `Frame.rotation_degrees`.
    rotation_degrees: f32,
    /// Whether there's film in it. An empty opening shows bare light, and has no frames.
    film: bool,
};

pub const Detection = struct {
    axis: Axis,
    /// The skew and height of the first opening with film in it, or of the first opening when
    /// none has film.
    rotation_degrees: f32,
    opening_mm: f32,
    /// The holder's openings, in order across the scan.
    openings: []Opening,
    frames: []Frame,

    pub fn deinit(detection: *Detection, gpa: std.mem.Allocator) void {
        gpa.free(detection.openings);
        gpa.free(detection.frames);
        detection.* = undefined;
    }
};

pub const Error = error{ NoOpening, BadResolution } || std.mem.Allocator.Error;

/// Scans smaller than this have nothing to detect.
const min_scan_px = 16;

/// Levels go into the histogram by their top bits.
const level_bits = 12;
const level_shift = @bitSizeOf(u16) - level_bits;
const level_bins = 1 << level_bits;
/// The holder's level is the one that this fraction of the scan is darker than.
const dark_quantile = 0.01;
/// The lightest level (film base or bare light) is the one that this fraction of the scan is
/// darker than.
const bright_quantile = 0.99;
/// Where the holder threshold sits between the dark and bright levels, on a log scale, and the
/// same for the threshold we use to find the holder's edges.
const holder_split = 0.3;
const edge_split = 0.5;
/// If bright over dark is below this ratio, the scan doesn't show the holder.
const min_holder_contrast = 4;
/// Levels are kept at least this high, so their logarithms stay finite.
const level_floor = 8;
/// If a scan's lightest level is below this (1% of full scale), it shows no film.
const min_light = image.full_scale / 100;

/// When the two axes' plateaus differ by less than this, the band's width decides between them.
const axis_tie = 0.1;
/// The plateau of a light-fraction profile is the value that this fraction of positions are below.
const plateau_quantile = 0.9;
/// A position across the strip is in the band when it's light at least this fraction as often as
/// the lightest position.
const band_fraction = 0.5;
/// Dips in the band narrower than this are bridged.
const band_bridge_mm = 1.0;
/// A light band narrower than this share of the format's height isn't an opening, but something
/// like a hole in the holder.
const min_opening_share = 0.5;
/// When a holder has several openings, one counts as having film when at least this share of its
/// lit lines show texture. Bare light is flat.
const min_film_lines = 0.05;

/// This many light samples in a row make an edge.
const edge_run = 3;
/// How much to blur either side of an edge, and how far past the holder threshold to look for the
/// edge.
const edge_blur_mm = 0.1;
const edge_search_mm = 1.0;
/// How far beyond the coarse edge we search for the edge.
const edge_guard_mm = 1.0;
/// Robust line fitting: the number of rounds, the outlier limit in standard deviations, the factor
/// that turns a median absolute deviation into a standard deviation, and the smallest limit in
/// pixels.
const fit_rounds = 4;
const fit_sigma = 3.0;
const mad_to_sigma = 1.4826;
const min_fit_residual = 0.5;
const min_edge_points = 8;
/// Edges whose slopes differ by less than this count as parallel and get averaged.
const parallel_slope = 0.01;
/// A fitted slope bigger than this multiple of the largest one searched for means the fit failed.
const skew_slack = 1.5;

/// We look for perforations when the band is this much taller than the format.
const perforation_band_ratio = 1.25;
/// The fraction of the band at each side that's searched for perforations.
const perforation_reach = 0.35;
/// The periodicity score a column with perforations reaches: the autocorrelation at the pitch
/// minus the autocorrelation at half the pitch.
const perforation_score = 0.8;
const min_perforation_columns = 2;

/// The fraction of the opening's height left out at each side when sampling a line.
const band_margin = 0.05;
const max_line_samples = 256;
/// A line is flat when its quartiles are closer than this in density.
const flat_spread = 0.05;
/// The gap level comes from the lightest line medians (negatives) or the darkest (positives), at
/// this quantile.
const gap_quantile = 0.98;
/// The shortest stretch of flat lines, in mm, that's enough to give a gap level of its own.
const min_flat_mm = 0.5;
/// A strip shorter than the holder's opening lets bare light through past its ends. That light
/// is at least this much lighter than the film, in density, and the holder's edge beyond it can
/// be this soft.
const min_base_density = 0.1;
const soft_edge_mm = 1.0;

/// Runs shorter than this are noise, and merge into their neighbours.
const min_run_mm = 0.3;
/// Content between gaps that's shorter than this fraction of a frame is just noise in a gap.
const short_content = 0.3;
/// A frame cut off at an end of the strip has to show at least this fraction of its length.
const min_partial = 0.5;
/// A gap wider than both of these isn't a gap between neighbouring frames. The first is a
/// multiple of the format's gap, the second a fraction of the frame length.
const wide_gap_factor = 3;
const wide_gap_fraction = 0.15;
/// How far into the content we judge its edge, and how big a density step (as a multiple of the
/// gap tolerance) makes that edge sharp.
const edge_depth_mm = 0.5;
const sharp_factor = 3;
/// A frame placed from the pitch beyond the outermost frames needs at least this fraction of its
/// length to be content.
const slot_content = 0.25;
/// Sharp edges more than this many pitches apart aren't used to measure the pitch.
const max_pitch_span = 3;

/// For mounted slides: dark runs shorter than this fraction of a frame are inside an aperture, and
/// apertures shorter than this fraction aren't slides.
const mount_bridge = 0.2;
const min_aperture = 0.4;
/// A line is inside an aperture when at least this fraction of it is light.
const aperture_light = 0.5;

/// Finds the frames on `scan`, a strip preview at `dpi` holding film of `format` and `kind`.
pub fn detect(
    gpa: std.mem.Allocator,
    scan: image.Scan,
    dpi: f32,
    format: formats.Format,
    kind: Kind,
    options: Options,
) Error!Detection {
    // The resolution comes from a roll's file or the command line, and a missing one would make
    // every length 0.
    if (!(dpi > 0) or !std.math.isFinite(dpi)) return error.BadResolution;
    if (scan.width < min_scan_px or scan.height < min_scan_px) return error.NoOpening;
    const px_per_mm = dpi / formats.mm_per_inch;

    const plane = try luminance(gpa, scan);
    defer gpa.free(plane);
    const levels = try classify(gpa, plane) orelse return error.NoOpening;
    const nominal_height = format.height_mm * px_per_mm;
    const axis = options.axis orelse try detectAxis(gpa, plane, scan.width, scan.height, levels, nominal_height);
    const view: View = .init(plane, scan.width, scan.height, axis);
    const all_lines: Range = .{ .start = 0, .end = view.along };

    const all_bands = try coarseBands(gpa, view, levels.threshold, all_lines, px_per_mm, nominal_height);
    defer gpa.free(all_bands);
    if (all_bands.len == 0) return error.NoOpening;
    // Mounted slides are found in one opening, the widest.
    const bands = if (options.holder == .mounted) widest(all_bands) else all_bands;
    const middle = @as(f32, @floatFromInt(view.along)) / 2;

    var openings: std.ArrayList(Opening) = try .initCapacity(gpa, bands.len);
    errdefer openings.deinit(gpa);
    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(gpa);
    for (bands, 0..) |band, index| {
        var edges = try fitOpening(gpa, view, levels.edge, all_lines, band, px_per_mm, options.max_skew_degrees);
        if (format.size.perforationPitchMm()) |pitch| {
            if (edges.height(middle) > perforation_band_ratio * nominal_height) {
                try leaveOutPerforations(gpa, view, &edges, all_lines, pitch * px_per_mm);
            }
        }

        var profile: Profile = try .measure(gpa, view, edges, levels.threshold);
        defer profile.deinit(gpa);
        // With one opening, film or not is for placing the frames to find out.
        const film = bands.len == 1 or profile.showsFilm();
        openings.appendAssumeCapacity(.{
            .middle_px = edges.centre(middle),
            .height_mm = edges.height(middle) / px_per_mm,
            .rotation_degrees = rotationDegrees(axis, edges.slope()),
            .film = film,
        });
        if (!film) continue;

        const frame_height = @max(edges.height(middle), 1);
        const context: Context = .{
            .view = view,
            .opening = edges,
            .threshold = levels.threshold,
            .edge_threshold = levels.edge,
            .kind = kind,
            .gap_tolerance = options.gap_tolerance orelse kind.defaultGapTolerance(),
            .length_tolerance = options.length_tolerance,
            .frame_height = frame_height,
            .frame_length = frame_height * format.ratio(),
            .nominal_length = format.width_mm * px_per_mm,
            .nominal_height = nominal_height,
            .nominal_pitch = if (format.pitch_mm) |pitch| pitch * px_per_mm else null,
            .nominal_gap = format.gapMm() * px_per_mm,
            .px_per_mm = px_per_mm,
        };
        const before = placed.items.len;
        switch (options.holder) {
            .strip => try placeStrip(gpa, &placed, profile, context),
            .mounted => try placeMounted(gpa, &placed, profile, band, context, options.max_skew_degrees),
        }
        for (placed.items[before..]) |*p| p.opening = index;
    }
    std.mem.sortUnstable(Placed, placed.items, {}, Placed.before);

    const frames = try gpa.alloc(Frame, placed.items.len);
    errdefer gpa.free(frames);
    for (frames, placed.items, 0..) |*frame, p, i| {
        frame.* = p.toFrame(axis, scan.width, scan.height);
        frame.index = i;
    }
    const first = for (openings.items) |o| {
        if (o.film) break o;
    } else openings.items[0];
    return .{
        .axis = axis,
        .rotation_degrees = first.rotation_degrees,
        .opening_mm = first.height_mm,
        .openings = try openings.toOwnedSlice(gpa),
        .frames = frames,
    };
}

/// Reduces each pixel to one value, the geometric mean of its channels. That way each channel's
/// density counts the same, however dense the film base is in that channel (as with a colour
/// negative's orange mask).
fn luminance(gpa: std.mem.Allocator, scan: image.Scan) ![]u16 {
    const logs = try gpa.alloc(f32, image.full_scale + 1);
    defer gpa.free(logs);
    for (logs, 0..) |*l, v| l.* = @log2(@as(f32, @floatFromInt(@max(v, 1))));
    const plane = try gpa.alloc(u16, scan.pixels.len);
    for (plane, scan.pixels) |*out, p| {
        var sum: f32 = 0;
        for (p) |c| sum += logs[c];
        out.* = @intFromFloat(@min(@round(@exp2(sum / image.channel_count)), image.full_scale));
    }
    return plane;
}

const Levels = struct {
    /// Film is above this level, and the holder is at or below it.
    threshold: u16,
    /// Halfway between the holder and the film on a log scale. It's above the flare around the
    /// holder's edges, so we use it to find them.
    edge: u16,
};

/// Step 1: finds the level that separates the holder from the film. Returns null when nothing in
/// the scan is light.
fn classify(gpa: std.mem.Allocator, plane: []const u16) !?Levels {
    const histogram = try gpa.alloc(u32, level_bins);
    defer gpa.free(histogram);
    @memset(histogram, 0);
    for (plane) |value| histogram[value >> level_shift] += 1;
    const dark = @max(histogramQuantile(histogram, plane.len, dark_quantile), level_floor);
    const bright = @max(histogramQuantile(histogram, plane.len, bright_quantile), dark);
    if (bright < min_light) return null;
    if (bright / dark < min_holder_contrast) return .{ .threshold = 0, .edge = 0 };
    return .{
        .threshold = @intFromFloat(dark * std.math.pow(f32, bright / dark, holder_split)),
        .edge = @intFromFloat(dark * std.math.pow(f32, bright / dark, edge_split)),
    };
}

/// Returns the level that `fraction` of the `count` values fall below, taken at the middle of its
/// bin.
fn histogramQuantile(histogram: []const u32, count: usize, fraction: f32) f32 {
    const rank: usize = @intFromFloat(fraction * @as(f32, @floatFromInt(count - 1)));
    var seen: usize = 0;
    for (histogram, 0..) |n, bin| {
        seen += n;
        if (seen > rank) return @floatFromInt((bin << level_shift) + (1 << level_shift) / 2);
    }
    return std.math.maxInt(u16);
}

/// Works out which axis the strip runs along. Looking along the strip, the positions across the
/// opening are light on nearly every line. Looking the other way, no line is light for much more
/// than the opening's share of the scan's width.
fn detectAxis(gpa: std.mem.Allocator, plane: []const u16, width: usize, height: usize, levels: Levels, nominal_height: f32) !Axis {
    const longer: Axis = if (height >= width) .y else .x;
    if (levels.threshold == 0) return longer;
    const columns = try gpa.alloc(u32, width);
    defer gpa.free(columns);
    const rows = try gpa.alloc(u32, height);
    defer gpa.free(rows);
    @memset(columns, 0);
    @memset(rows, 0);
    for (0..height) |y| {
        for (plane[y * width ..][0..width], columns) |value, *column| {
            if (value > levels.threshold) {
                column.* += 1;
                rows[y] += 1;
            }
        }
    }
    const along_y = try plateau(gpa, columns, height);
    const along_x = try plateau(gpa, rows, width);
    if (along_y > along_x + axis_tie) return .y;
    if (along_x > along_y + axis_tie) return .x;
    const miss_y = @abs(@log(bandWidth(columns, height) / nominal_height));
    const miss_x = @abs(@log(bandWidth(rows, width) / nominal_height));
    if (miss_y < miss_x) return .y;
    if (miss_x < miss_y) return .x;
    return longer;
}

/// Returns the high end of the fractions `counts[i] / lines`.
fn plateau(gpa: std.mem.Allocator, counts: []const u32, lines: usize) !f32 {
    const sorted = try gpa.dupe(u32, counts);
    defer gpa.free(sorted);
    std.mem.sortUnstable(u32, sorted, {}, std.sort.asc(u32));
    return @as(f32, @floatFromInt(quantile(u32, sorted, plateau_quantile))) / @as(f32, @floatFromInt(lines));
}

/// Counts the positions that are light on at least half the lines. Returns at least 1.
fn bandWidth(counts: []const u32, lines: usize) f32 {
    var n: usize = 0;
    for (counts) |c| {
        if (2 * c >= lines) n += 1;
    }
    return @floatFromInt(@max(n, 1));
}

const quantile = stats.quantile;

/// The luminance plane, read in strip coordinates.
const View = struct {
    values: []const u16,
    /// The number of lines along the strip, and of samples per line.
    along: usize,
    across: usize,
    along_stride: usize,
    across_stride: usize,

    fn init(plane: []const u16, width: usize, height: usize, axis: Axis) View {
        return switch (axis) {
            .y => .{ .values = plane, .along = height, .across = width, .along_stride = width, .across_stride = 1 },
            .x => .{ .values = plane, .along = width, .across = height, .along_stride = 1, .across_stride = width },
        };
    }

    fn at(view: View, u: usize, v: usize) u16 {
        return view.values[u * view.along_stride + v * view.across_stride];
    }

    /// Returns the sample nearest to a continuous position, or null outside the view.
    fn sample(view: View, u: f32, v: f32) ?u16 {
        if (u < 0 or v < 0) return null;
        const ui: usize = @intFromFloat(u);
        const vi: usize = @intFromFloat(v);
        if (ui >= view.along or vi >= view.across) return null;
        return view.at(ui, vi);
    }
};

const Range = struct {
    start: usize,
    end: usize,

    fn len(range: Range) usize {
        return range.end - range.start;
    }
};

/// The light band across the strip, found from how often each position is light. `near` is its
/// first position and `far` is one past its last.
const Band = struct { near: usize, far: usize };

/// Finds the light bands across the strip: the holder's openings, in order across the scan. Bands
/// much narrower than the format's height are left out. If that leaves none, the widest band is
/// the opening.
fn coarseBands(gpa: std.mem.Allocator, view: View, threshold: u16, lines: Range, px_per_mm: f32, nominal_height: f32) ![]Band {
    const counts = try gpa.alloc(u32, view.across);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (lines.start..lines.end) |u| {
        for (counts, 0..) |*count, v| {
            if (view.at(u, v) > threshold) count.* += 1;
        }
    }
    var bands: std.ArrayList(Band) = .empty;
    errdefer bands.deinit(gpa);
    const most = std.mem.max(u32, counts);
    if (most == 0) return bands.toOwnedSlice(gpa);
    const bridge: usize = @intFromFloat(band_bridge_mm * px_per_mm);
    var current: ?Band = null;
    for (counts, 0..) |count, v| {
        if (@as(f32, @floatFromInt(count)) < band_fraction * @as(f32, @floatFromInt(most))) continue;
        if (current) |*c| {
            if (v - c.far <= bridge) {
                c.far = v + 1;
                continue;
            }
            try bands.append(gpa, c.*);
        }
        current = .{ .near = v, .far = v + 1 };
    }
    if (current) |c| try bands.append(gpa, c);

    const narrowest: f32 = min_opening_share * nominal_height;
    var kept: usize = 0;
    var widest_band: Band = bands.items[0];
    for (bands.items) |band| {
        if (band.far - band.near > widest_band.far - widest_band.near) widest_band = band;
        if (@as(f32, @floatFromInt(band.far - band.near)) < narrowest) continue;
        bands.items[kept] = band;
        kept += 1;
    }
    if (kept == 0) {
        bands.items[0] = widest_band;
        kept = 1;
    }
    bands.shrinkRetainingCapacity(kept);
    return bands.toOwnedSlice(gpa);
}

/// The widest of `bands`, as a slice of one.
fn widest(bands: []const Band) []const Band {
    var best: usize = 0;
    for (bands, 0..) |band, i| {
        if (band.far - band.near > bands[best].far - bands[best].near) best = i;
    }
    return bands[best..][0..1];
}

/// A straight edge in strip coordinates: `v = offset + slope · u`.
const Line = struct {
    offset: f32,
    slope: f32,

    fn at(line: Line, u: f32) f32 {
        return line.offset + line.slope * u;
    }
};

/// An opening's long edges: the holder on either side of the film.
const Edges = struct {
    near: Line,
    far: Line,

    fn slope(opening: Edges) f32 {
        return (opening.near.slope + opening.far.slope) / 2;
    }

    fn centre(opening: Edges, u: f32) f32 {
        return (opening.near.at(u) + opening.far.at(u)) / 2;
    }

    /// The height at right angles to the strip, in pixels.
    fn height(opening: Edges, u: f32) f32 {
        const s = opening.slope();
        return (opening.far.at(u) - opening.near.at(u)) / @sqrt(1 + s * s);
    }

    /// The distance along the strip, in pixels, that one line covers.
    fn alongScale(opening: Edges) f32 {
        const s = opening.slope();
        return @sqrt(1 + s * s);
    }
};

const Point = struct { u: f32, v: f32 };

/// Step 2: fits lines to the long edges of the band, over `lines`.
fn fitOpening(gpa: std.mem.Allocator, view: View, edge_threshold: u16, lines: Range, band: Band, px_per_mm: f32, max_skew_degrees: f32) !Edges {
    const max_slope = @tan(std.math.degreesToRadians(max_skew_degrees));
    const span: f32 = @floatFromInt(lines.len());
    const window: usize = @intFromFloat(@ceil(max_slope * span / 2 + edge_guard_mm * px_per_mm));
    const blur: usize = @intFromFloat(@max(@round(edge_blur_mm * px_per_mm), 1));
    const search: usize = @intFromFloat(@round(edge_search_mm * px_per_mm));
    const middle = (band.near + band.far) / 2;
    const near: Range = .{ .start = band.near -| window, .end = @min(band.near + window, middle) };
    const far: Range = .{ .start = @max(band.far -| window, middle), .end = @min(band.far + window, view.across) };

    const buffer = try gpa.alloc(u16, @max(near.len(), far.len()));
    defer gpa.free(buffer);
    var near_points: std.ArrayList(Point) = try .initCapacity(gpa, lines.len());
    defer near_points.deinit(gpa);
    var far_points: std.ArrayList(Point) = try .initCapacity(gpa, lines.len());
    defer far_points.deinit(gpa);

    for (lines.start..lines.end) |u| {
        const at_u = @as(f32, @floatFromInt(u)) + 0.5;
        if (near.len() > 0) {
            const outward = buffer[0..near.len()];
            for (outward, 0..) |*b, j| b.* = view.at(u, near.start + j);
            if (edgeFromOutside(outward, edge_threshold, blur, search)) |p| {
                near_points.appendAssumeCapacity(.{ .u = at_u, .v = @as(f32, @floatFromInt(near.start)) + p });
            }
        }
        if (far.len() > 0) {
            const outward = buffer[0..far.len()];
            for (outward, 0..) |*b, j| b.* = view.at(u, far.end - 1 - j);
            if (edgeFromOutside(outward, edge_threshold, blur, search)) |p| {
                far_points.appendAssumeCapacity(.{ .u = at_u, .v = @as(f32, @floatFromInt(far.end)) - p });
            }
        }
    }

    const scratch = try gpa.alloc(f32, lines.len());
    defer gpa.free(scratch);
    const near_fit = robustFit(near_points.items, scratch, max_slope * skew_slack);
    const far_fit = robustFit(far_points.items, scratch, max_slope * skew_slack);
    const middle_u = @as(f32, @floatFromInt(lines.start + lines.end)) / 2;

    const slope: f32 = if (near_fit != null and far_fit != null) blk: {
        const a = near_fit.?;
        const b = far_fit.?;
        if (@abs(a.line.slope - b.line.slope) <= parallel_slope) {
            const wa: f32 = @floatFromInt(a.inliers);
            const wb: f32 = @floatFromInt(b.inliers);
            break :blk (a.line.slope * wa + b.line.slope * wb) / (wa + wb);
        }
        break :blk if (a.inliers >= b.inliers) a.line.slope else b.line.slope;
    } else if (near_fit) |a| a.line.slope else if (far_fit) |b| b.line.slope else 0;

    return .{
        .near = if (near_fit) |fit|
            .{ .offset = offsetWithSlope(near_points.items[0..fit.inliers], slope, scratch), .slope = slope }
        else
            .{ .offset = @as(f32, @floatFromInt(band.near)) - slope * middle_u, .slope = slope },
        .far = if (far_fit) |fit|
            .{ .offset = offsetWithSlope(far_points.items[0..fit.inliers], slope, scratch), .slope = slope }
        else
            .{ .offset = @as(f32, @floatFromInt(band.far)) - slope * middle_u, .slope = slope },
    };
}

/// Finds the edge in `samples`, which run from outside the band inwards, and returns it in samples
/// from the outer end. The first run of film above the holder threshold gives a rough position.
/// But flare outside the holder can lift the level over the threshold too early, so the edge is
/// the steepest rise in log level from there on, placed where the level crosses halfway between
/// the two sides. Returns null when the outer end isn't holder, or no film follows.
fn edgeFromOutside(samples: []const u16, threshold: u16, blur: usize, search: usize) ?f32 {
    if (samples.len < edge_run + 2 * blur + 1 or samples[0] > threshold) return null;
    var run: usize = 0;
    const first = for (samples, 0..) |value, i| {
        if (value > threshold) {
            run += 1;
            if (run == edge_run) break i + 1 - edge_run;
        } else run = 0;
    } else return null;

    const lo = @max(first -| blur, blur);
    const hi = @min(first + search, samples.len - blur);
    if (lo >= hi) return @floatFromInt(first);
    var steepest = lo;
    var rise = -std.math.inf(f32);
    for (lo..hi) |i| {
        const r = logLevel(samples[i + blur]) - logLevel(samples[i - blur]);
        if (r > rise) {
            rise = r;
            steepest = i;
        }
    }
    const dark = meanLevel(samples[steepest -| 2 * blur .. steepest - blur + 1]);
    const light = meanLevel(samples[steepest + blur .. @min(steepest + 2 * blur + 1, samples.len)]);
    const half = (dark + light) / 2;
    for (steepest - blur + 1..@min(steepest + blur + 1, samples.len)) |i| {
        const after: f32 = @floatFromInt(samples[i]);
        const before: f32 = @floatFromInt(samples[i - 1]);
        if (after >= half and before < half) return @as(f32, @floatFromInt(i)) - 0.5 + (half - before) / (after - before);
    }
    return @as(f32, @floatFromInt(steepest)) + 0.5;
}

fn logLevel(value: u16) f32 {
    return @log(@as(f32, @floatFromInt(@max(value, level_floor))));
}

fn meanLevel(samples: []const u16) f32 {
    var sum: f32 = 0;
    for (samples) |v| sum += @floatFromInt(v);
    return sum / @as(f32, @floatFromInt(samples.len));
}

const Fit = struct { line: Line, inliers: usize };

/// Fits a least-squares line through `points`, dropping outliers round by round. The inliers end
/// up at the front of `points`. Returns null if there are too few points, or the slope is steeper
/// than `max_slope`.
fn robustFit(points: []Point, scratch: []f32, max_slope: f32) ?Fit {
    var active = points.len;
    var line = leastSquares(points[0..active]) orelse return null;
    for (0..fit_rounds) |_| {
        for (points[0..active], scratch[0..active]) |p, *r| r.* = @abs(p.v - line.at(p.u));
        std.mem.sortUnstable(f32, scratch[0..active], {}, std.sort.asc(f32));
        const mad = scratch[active / 2];
        const limit = @max(fit_sigma * mad_to_sigma * mad, min_fit_residual);
        var kept: usize = 0;
        for (0..active) |i| {
            if (@abs(points[i].v - line.at(points[i].u)) <= limit) {
                std.mem.swap(Point, &points[kept], &points[i]);
                kept += 1;
            }
        }
        if (kept < min_edge_points) return null;
        const done = kept == active;
        active = kept;
        line = leastSquares(points[0..active]) orelse return null;
        if (done) break;
    }
    if (@abs(line.slope) > max_slope) return null;
    return .{ .line = line, .inliers = active };
}

fn leastSquares(points: []const Point) ?Line {
    if (points.len < min_edge_points) return null;
    var mean_u: f32 = 0;
    var mean_v: f32 = 0;
    for (points) |p| {
        mean_u += p.u;
        mean_v += p.v;
    }
    const n: f32 = @floatFromInt(points.len);
    mean_u /= n;
    mean_v /= n;
    var uu: f32 = 0;
    var uv: f32 = 0;
    for (points) |p| {
        uu += (p.u - mean_u) * (p.u - mean_u);
        uv += (p.u - mean_u) * (p.v - mean_v);
    }
    const slope = if (uu > 0) uv / uu else 0;
    return .{ .offset = mean_v - slope * mean_u, .slope = slope };
}

/// Returns the median offset of `points` for lines with slope `slope`.
fn offsetWithSlope(points: []const Point, slope: f32, scratch: []f32) f32 {
    const offsets = scratch[0..points.len];
    for (points, offsets) |p, *o| o.* = p.v - slope * p.u;
    std.mem.sortUnstable(f32, offsets, {}, std.sort.asc(f32));
    return offsets[offsets.len / 2];
}

/// Where the film's edges show, 135's perforations repeat along the strip at their pitch. Columns
/// that repeat like that are left out of the opening, along with everything outside them.
fn leaveOutPerforations(gpa: std.mem.Allocator, view: View, opening: *Edges, lines: Range, pitch_px: f32) !void {
    const lag: usize = @intFromFloat(@round(pitch_px / opening.alongScale()));
    const half_lag = lag / 2;
    if (half_lag < 2 or lines.len() < 4 * lag) return;
    const middle = @as(f32, @floatFromInt(lines.start + lines.end)) / 2;
    const width = opening.far.at(middle) - opening.near.at(middle);
    if (width < 1) return;
    const columns: usize = @intFromFloat(width);
    const reach: usize = @intFromFloat(@as(f32, @floatFromInt(columns)) * perforation_reach);

    const samples = try gpa.alloc(f32, lines.len());
    defer gpa.free(samples);
    var near_cut: usize = 0;
    var near_hits: usize = 0;
    var far_cut: ?usize = null;
    var far_hits: usize = 0;
    for (0..columns) |d| {
        if (d >= reach and d + reach < columns) continue;
        for (samples, lines.start..lines.end) |*s, u| {
            const at_u = @as(f32, @floatFromInt(u)) + 0.5;
            const v = opening.near.at(at_u) + @as(f32, @floatFromInt(d)) + 0.5;
            s.* = @floatFromInt(view.sample(at_u, v) orelse 0);
        }
        if (periodicity(samples, lag, half_lag) < perforation_score) continue;
        if (d < reach) {
            near_cut = d + 1;
            near_hits += 1;
        } else {
            if (far_cut == null) far_cut = d;
            far_hits += 1;
        }
    }
    if (far_hits >= min_perforation_columns) opening.far.offset -= width - @as(f32, @floatFromInt(far_cut.?));
    if (near_hits >= min_perforation_columns) opening.near.offset += @floatFromInt(near_cut);
}

/// The autocorrelation at `lag` minus the autocorrelation at `half_lag`. It's near 2 for a square
/// wave with period `lag`, and near 0 for smooth picture content.
fn periodicity(samples: []const f32, lag: usize, half_lag: usize) f32 {
    var mean: f32 = 0;
    for (samples) |s| mean += s;
    mean /= @floatFromInt(samples.len);
    var variance: f32 = 0;
    for (samples) |s| variance += (s - mean) * (s - mean);
    variance /= @floatFromInt(samples.len);
    if (variance <= 1) return 0;
    return autocorrelation(samples, mean, variance, lag) - autocorrelation(samples, mean, variance, half_lag);
}

fn autocorrelation(samples: []const f32, mean: f32, variance: f32, lag: usize) f32 {
    var sum: f32 = 0;
    for (samples[0 .. samples.len - lag], samples[lag..]) |a, b| sum += (a - mean) * (b - mean);
    return sum / (@as(f32, @floatFromInt(samples.len - lag)) * variance);
}

/// Measurements of each line across the opening, sampled at right angles to the strip.
const Profile = struct {
    /// The median level of each line.
    median: []f32,
    /// The distance between each line's quartiles, in density.
    spread: []f32,
    /// The fraction of each line above the holder threshold.
    light: []f32,

    fn measure(gpa: std.mem.Allocator, view: View, opening: Edges, threshold: u16) !Profile {
        const median = try gpa.alloc(f32, view.along);
        errdefer gpa.free(median);
        const spread = try gpa.alloc(f32, view.along);
        errdefer gpa.free(spread);
        const light = try gpa.alloc(f32, view.along);
        errdefer gpa.free(light);

        var samples: [max_line_samples]u16 = undefined;
        const slope = opening.slope();
        for (median, spread, light, 0..) |*m, *s, *l, line| {
            const u = @as(f32, @floatFromInt(line)) + 0.5;
            const centre = opening.centre(u);
            const half = (opening.far.at(u) - opening.near.at(u)) * (0.5 - band_margin);
            const count: usize = @min(max_line_samples, @as(usize, @intFromFloat(@max(2 * half, 0))) + 1);
            var taken: usize = 0;
            var lit: usize = 0;
            for (0..count) |k| {
                const v = centre - half + 2 * half * (@as(f32, @floatFromInt(k)) + 0.5) / @as(f32, @floatFromInt(count));
                const value = view.sample(u - slope * (v - centre), v) orelse continue;
                samples[taken] = value;
                taken += 1;
                if (value > threshold) lit += 1;
            }
            if (taken == 0) {
                m.* = 0;
                s.* = 0;
                l.* = 0;
                continue;
            }
            const sorted = samples[0..taken];
            std.mem.sortUnstable(u16, sorted, {}, std.sort.asc(u16));
            m.* = @floatFromInt(sorted[taken / 2]);
            const low: f32 = @floatFromInt(@max(sorted[taken / 4], level_floor));
            const high: f32 = @floatFromInt(@max(sorted[taken * 3 / 4], level_floor));
            s.* = std.math.log10(high / low);
            l.* = @as(f32, @floatFromInt(lit)) / @as(f32, @floatFromInt(taken));
        }
        return .{ .median = median, .spread = spread, .light = light };
    }

    /// Whether the opening shows film: enough of its lit lines have texture. Bare light, and
    /// film with no pictures on it, are flat.
    fn showsFilm(profile: Profile) bool {
        var lit: usize = 0;
        var textured: usize = 0;
        for (profile.light, profile.spread) |light, spread| {
            if (light < band_fraction) continue;
            lit += 1;
            if (spread >= flat_spread) textured += 1;
        }
        return @as(f32, @floatFromInt(textured)) >= min_film_lines * @as(f32, @floatFromInt(lit)) and textured > 0;
    }

    fn deinit(profile: *Profile, gpa: std.mem.Allocator) void {
        gpa.free(profile.median);
        gpa.free(profile.spread);
        gpa.free(profile.light);
        profile.* = undefined;
    }
};

/// What placing frames needs to know, in pixels.
const Context = struct {
    view: View,
    opening: Edges,
    threshold: u16,
    edge_threshold: u16,
    kind: Kind,
    gap_tolerance: f32,
    length_tolerance: f32,
    /// The frame's size. The height is the opening's height, and the length comes from the
    /// format's ratio.
    frame_height: f32,
    frame_length: f32,
    /// The format's size.
    nominal_length: f32,
    nominal_height: f32,
    /// The format's fixed pitch, if it has one, and its gap.
    nominal_pitch: ?f32,
    nominal_gap: f32,
    px_per_mm: f32,
};

/// A frame in strip coordinates.
const Placed = struct {
    /// The frame's centre: along the strip in lines, and across it in samples.
    along: f32,
    across: f32,
    /// The size along and across the strip, in pixels.
    length: f32,
    height: f32,
    /// The strip's slope, dv/du, at this frame.
    slope: f32,
    confidence: Confidence,
    /// The opening it's in.
    opening: usize = 0,

    fn before(_: void, a: Placed, b: Placed) bool {
        if (a.opening != b.opening) return a.opening < b.opening;
        return a.along < b.along;
    }

    fn toFrame(placed: Placed, axis: Axis, width: usize, height: usize) Frame {
        const x_centre, const y_centre, const x_size, const y_size = switch (axis) {
            .y => .{ placed.across, placed.along, placed.height, placed.length },
            .x => .{ placed.along, placed.across, placed.length, placed.height },
        };
        const x = clippedSpan(x_centre, x_size, width);
        const y = clippedSpan(y_centre, y_size, height);
        return .{
            .index = 0,
            .opening = placed.opening,
            .area = .{ .x = x.start, .y = y.start, .width = x.len(), .height = y.len() },
            .rotation_degrees = rotationDegrees(axis, placed.slope),
            .confidence = placed.confidence,
        };
    }
};

fn clippedSpan(centre: f32, size: f32, limit: usize) Range {
    const top: f32 = @floatFromInt(limit);
    const start = std.math.clamp(@round(centre - size / 2), 0, top);
    const end = std.math.clamp(@round(centre + size / 2), start, top);
    return .{ .start = @intFromFloat(start), .end = @intFromFloat(end) };
}

/// Turns the strip's skew into an image rotation. For a strip along y, a positive slope leans the
/// strip's axis anticlockwise from straight down. For a strip along x, it leans it clockwise from
/// straight right.
fn rotationDegrees(axis: Axis, slope: f32) f32 {
    const angle = std.math.radiansToDegrees(std.math.atan(slope));
    return switch (axis) {
        .x => angle,
        .y => -angle,
    };
}

/// A run of lines that are all gap or all content.
const Run = struct {
    start: usize,
    end: usize,
    gap: bool,

    fn len(run: Run) f32 {
        return @floatFromInt(run.end - run.start);
    }

    fn middle(run: Run) f32 {
        return @as(f32, @floatFromInt(run.start + run.end)) / 2;
    }
};

/// What one end of a run of content looks like.
const Side = enum {
    /// The density steps up from the gap level within a short distance, so the frame's edge
    /// shows.
    sharp,
    /// The picture stays close to the gap level near the end, the way a dark scene does. The
    /// frame's edge doesn't show, and it may be further out.
    soft,
    /// The film or the scan ends inside the content.
    cut,
};

const End = enum { start, end };

/// A run of content, and what each of its ends looks like.
const Content = struct {
    run: Run,
    before: Side,
    after: Side,

    fn sharpEnds(content: Content) usize {
        return @as(usize, @intFromBool(content.before == .sharp)) + @intFromBool(content.after == .sharp);
    }
};

/// Runs steps 3 to 5 for a strip.
fn placeStrip(gpa: std.mem.Allocator, out: *std.ArrayList(Placed), profile: Profile, c: Context) !void {
    const extent = try leaveOutBareLight(gpa, profile, filmExtent(profile.median, c.threshold) orelse return, c);
    const level = try gapLevel(gpa, profile, extent, c);
    const scale = c.opening.alongScale();

    const density = try gpa.alloc(f32, profile.median.len);
    defer gpa.free(density);
    const gaps = try gpa.alloc(bool, profile.median.len);
    defer gpa.free(gaps);
    for (density, gaps, profile.median, profile.spread) |*d, *gap, m, spread| {
        d.* = densityFromGap(c.kind, level, m);
        gap.* = d.* < c.gap_tolerance and c.kind.isFlat(spread);
    }

    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    for (extent.start..extent.end) |line| {
        const gap = gaps[line];
        if (runs.items.len > 0 and runs.items[runs.items.len - 1].gap == gap) {
            runs.items[runs.items.len - 1].end = line + 1;
        } else {
            try runs.append(gpa, .{ .start = line, .end = line + 1, .gap = gap });
        }
    }
    cleanRuns(&runs, @max(min_run_mm * c.px_per_mm / scale, 1), c.nominal_length / scale, c.length_tolerance);

    var contents: std.ArrayList(Content) = .empty;
    defer contents.deinit(gpa);
    const depth: usize = @intFromFloat(@max(@round(edge_depth_mm * c.px_per_mm / scale), 1));
    const sharp_step = sharp_factor * c.gap_tolerance;
    for (runs.items) |run| {
        if (run.gap) continue;
        try contents.append(gpa, .{
            .run = run,
            .before = sideAt(density, run, .start, extent, depth, sharp_step),
            .after = sideAt(density, run, .end, extent, depth, sharp_step),
        });
    }

    const strip: Strip = try .measure(gpa, contents.items, c, scale);
    var frames: std.ArrayList(Placed) = .empty;
    defer frames.deinit(gpa);
    for (contents.items) |content| try strip.place(gpa, &frames, content);
    std.mem.sortUnstable(Placed, frames.items, {}, Placed.before);
    strip.dropDuplicates(&frames);
    try strip.fillByPitch(gpa, &frames, gaps, extent);

    // Content that has no sharp edge to anchor it, and that the pitch doesn't reach either, keeps
    // its measured box.
    for (contents.items) |content| {
        if (content.sharpEnds() > 0) continue;
        const covered = for (frames.items) |f| {
            if (@abs(f.along - content.run.middle()) < strip.film_length / 2) break true;
        } else false;
        if (!covered) try frames.append(gpa, strip.frame(content.run.middle(), content.run.len(), .check));
    }
    try out.appendSlice(gpa, frames.items);
}

/// Works out whether the content's `end` shows a frame edge, from the highest density within
/// `depth` lines of it.
fn sideAt(density: []const f32, run: Run, end: End, extent: Range, depth: usize, sharp_step: f32) Side {
    const window = switch (end) {
        .start => blk: {
            if (run.start == extent.start) return .cut;
            break :blk density[run.start..@min(run.start + depth, run.end)];
        },
        .end => blk: {
            if (run.end == extent.end) return .cut;
            break :blk density[@max(run.end -| depth, run.start)..run.end];
        },
    };
    return if (std.mem.max(f32, window) >= sharp_step) .sharp else .soft;
}

/// Leaves out the bare light at either end of `extent`, where the strip is shorter than the
/// holder's opening: flat lines as light as the lightest one, up to the holder's soft edge. Bare
/// light always has the holder past it, so film that runs to the edge of the scan, like the gaps
/// in a frame scan's margins, stays. So does light that isn't clearly lighter than the film,
/// which is the film's own clear base.
fn leaveOutBareLight(gpa: std.mem.Allocator, profile: Profile, extent: Range, c: Context) !Range {
    const medians = profile.median[extent.start..extent.end];
    const spreads = profile.spread[extent.start..extent.end];
    var lamp: f32 = 0;
    for (medians, spreads) |m, spread| {
        if (spread < flat_spread) lamp = @max(lamp, m);
    }
    if (lamp == 0) return extent;
    const bare = struct {
        fn at(m: f32, spread: f32, light: f32, tolerance: f32) bool {
            return spread < flat_spread and std.math.log10(light / @max(m, level_floor)) < tolerance;
        }
    }.at;
    const scale = c.opening.alongScale();
    const soft: usize = @intFromFloat(@round(soft_edge_mm * c.px_per_mm / scale));
    const shortest: usize = @intFromFloat(@max(@round(min_flat_mm * c.px_per_mm / scale), 1));

    // From each end with the holder past it, past the holder's soft edge, then through the bare
    // light.
    var start: usize = 0;
    if (extent.start > 0) {
        const first = for (0..@min(soft, medians.len)) |i| {
            if (bare(medians[i], spreads[i], lamp, c.gap_tolerance)) break i;
        } else medians.len;
        var i = first;
        while (i < medians.len and bare(medians[i], spreads[i], lamp, c.gap_tolerance)) i += 1;
        if (i - first >= shortest) start = i;
    }
    var end = medians.len;
    if (extent.end < profile.median.len) {
        const last = for (0..@min(soft, medians.len)) |k| {
            const j = medians.len - 1 - k;
            if (bare(medians[j], spreads[j], lamp, c.gap_tolerance)) break j + 1;
        } else 0;
        var j = last;
        while (j > start and bare(medians[j - 1], spreads[j - 1], lamp, c.gap_tolerance)) j -= 1;
        if (last >= j and last - j >= shortest) end = j;
    }
    if (start == 0 and end == medians.len) return extent;
    if (end <= start) return extent;

    // The film's lightest lines.
    const sorted = try gpa.dupe(f32, medians[start..end]);
    defer gpa.free(sorted);
    std.mem.sortUnstable(f32, sorted, {}, std.sort.asc(f32));
    const lightest = @max(quantile(f32, sorted, gap_quantile), level_floor);
    if (std.math.log10(lamp / lightest) < min_base_density) return extent;
    return .{ .start = extent.start + start, .end = extent.start + end };
}

/// The lines from the first to the last one that shows film rather than holder.
fn filmExtent(median: []const f32, threshold: u16) ?Range {
    const limit: f32 = @floatFromInt(threshold);
    var start: usize = 0;
    while (start < median.len and median[start] <= limit) start += 1;
    var end = median.len;
    while (end > start and median[end - 1] <= limit) end -= 1;
    if (end == start) return null;
    return .{ .start = start, .end = end };
}

/// Finds the level of the gaps between frames. For negatives that's the film base, from the
/// lightest line medians. Bare light past the end of a short strip is lighter still, so when light
/// runs reach the ends, the base comes from the stretches of flat lines between them, the way gaps
/// look. A picture's odd flat line doesn't count. For positives it's the darkest lines.
fn gapLevel(gpa: std.mem.Allocator, profile: Profile, extent: Range, c: Context) !f32 {
    const medians = profile.median[extent.start..extent.end];
    const sorted = try gpa.alloc(f32, medians.len);
    defer gpa.free(sorted);
    @memcpy(sorted, medians);
    std.mem.sortUnstable(f32, sorted, {}, std.sort.asc(f32));
    switch (c.kind) {
        .positive => return @max(quantile(f32, sorted, 1 - gap_quantile), level_floor),
        .negative => {
            const lightest = @max(quantile(f32, sorted, gap_quantile), level_floor);
            const limit = lightest * std.math.pow(f32, 10, -c.gap_tolerance);
            var start: usize = 0;
            while (start < medians.len and medians[start] >= limit) start += 1;
            var end = medians.len;
            while (end > start and medians[end - 1] >= limit) end -= 1;
            if (start == 0 and end == medians.len) return lightest;

            const shortest: usize = @intFromFloat(@max(@round(min_flat_mm * c.px_per_mm), 1));
            const spreads = profile.spread[extent.start..extent.end];
            var flat: usize = 0;
            var stretch = start;
            for (start..end + 1) |line| {
                if (line < end and spreads[line] < flat_spread) continue;
                if (line - stretch >= shortest) {
                    @memcpy(sorted[flat..][0 .. line - stretch], medians[stretch..line]);
                    flat += line - stretch;
                }
                stretch = line + 1;
            }
            if (flat == 0) return lightest;
            std.mem.sortUnstable(f32, sorted[0..flat], {}, std.sort.asc(f32));
            return @max(quantile(f32, sorted[0..flat], gap_quantile), level_floor);
        },
    }
}

/// How far a level is from the gap level, in density, towards the picture: denser for negatives
/// and lighter for positives. Zero or less means it's at the gap level.
fn densityFromGap(kind: Kind, gap_level: f32, value: f32) f32 {
    const v = @max(value, level_floor);
    return switch (kind) {
        .negative => std.math.log10(gap_level / v),
        .positive => std.math.log10(v / gap_level),
    };
}

/// Merges noise into what's around it: runs too short to mean anything, content between gaps
/// that's too short to be a frame, and gaps that split one frame into two short runs of content.
/// Content at an end that shows too little of a frame becomes part of the gap.
fn cleanRuns(runs: *std.ArrayList(Run), min_run: f32, length: f32, tolerance: f32) void {
    while (runs.items.len > 1) {
        var shortest: ?usize = null;
        for (runs.items, 0..) |run, i| {
            if (run.len() < min_run and (shortest == null or run.len() < runs.items[shortest.?].len())) shortest = i;
        }
        flip(runs, shortest orelse break);
    }
    var i: usize = 1;
    while (i + 1 < runs.items.len) {
        if (!runs.items[i].gap and runs.items[i].len() < short_content * length) {
            flip(runs, i);
            i = 1;
        } else i += 1;
    }
    const short = (1 - tolerance) * length;
    i = 1;
    while (i + 3 < runs.items.len) {
        const a = runs.items[i];
        const b = runs.items[i + 2];
        if (!a.gap and a.len() < short and b.len() < short and @as(f32, @floatFromInt(b.end - a.start)) <= (1 + tolerance) * length) {
            flip(runs, i + 1);
        } else i += 1;
    }
    if (runs.items.len > 1) {
        const last = runs.items.len - 1;
        if (!runs.items[last].gap and runs.items[last].len() < min_partial * length) flip(runs, last);
        if (!runs.items[0].gap and runs.items[0].len() < min_partial * length) flip(runs, 0);
    }
}

/// Turns a gap into content, or content into a gap, and merges it with its neighbours.
fn flip(runs: *std.ArrayList(Run), index: usize) void {
    runs.items[index].gap = !runs.items[index].gap;
    var kept: usize = 0;
    for (runs.items) |run| {
        if (kept > 0 and runs.items[kept - 1].gap == run.gap) {
            runs.items[kept - 1].end = run.end;
        } else {
            runs.items[kept] = run;
            kept += 1;
        }
    }
    runs.shrinkRetainingCapacity(kept);
}

/// Places frames along a strip, working in lines.
const Strip = struct {
    context: Context,
    /// The distance along the strip, in pixels, that one line covers.
    scale: f32,
    /// The length of the snapped box, the frame's length on the film, the gap and the pitch.
    length: f32,
    film_length: f32,
    gap: f32,
    pitch: f32,

    /// Works out the frame length, gap and pitch. They're measured where the edges show, and
    /// taken from the format where they don't.
    fn measure(gpa: std.mem.Allocator, contents: []const Content, c: Context, scale: f32) !Strip {
        const length = c.frame_length / scale;
        const nominal_gap = c.nominal_gap / scale;
        var values: std.ArrayList(f32) = .empty;
        defer values.deinit(gpa);

        for (contents) |content| {
            const measured = content.run.len();
            if (content.sharpEnds() == 2 and @abs(measured - length) <= c.length_tolerance * length) try values.append(gpa, measured);
        }
        const film_length = medianOf(values.items) orelse c.nominal_length / scale;

        values.clearRetainingCapacity();
        const max_gap = @max(wide_gap_factor * nominal_gap, wide_gap_fraction * film_length);
        for (contents[0..contents.len -| 1], contents[@min(1, contents.len)..]) |a, b| {
            const width: f32 = @floatFromInt(b.run.start - a.run.end);
            if (a.after == .sharp and b.before == .sharp and width <= max_gap) try values.append(gpa, width);
        }
        const gap = medianOf(values.items) orelse nominal_gap;

        // Sharp edges of the same kind (both starts or both ends) are a whole number of pitches
        // apart.
        values.clearRetainingCapacity();
        const guess = if (c.nominal_pitch) |p| p / scale else film_length + gap;
        var last_start: ?f32 = null;
        var last_end: ?f32 = null;
        for (contents) |content| {
            if (content.before == .sharp) {
                const at: f32 = @floatFromInt(content.run.start);
                if (last_start) |previous| try addPitch(gpa, &values, at - previous, guess, c.length_tolerance);
                last_start = at;
            }
            if (content.after == .sharp) {
                const at: f32 = @floatFromInt(content.run.end);
                if (last_end) |previous| try addPitch(gpa, &values, at - previous, guess, c.length_tolerance);
                last_end = at;
            }
        }
        return .{
            .context = c,
            .scale = scale,
            .length = length,
            .film_length = film_length,
            .gap = gap,
            .pitch = medianOf(values.items) orelse guess,
        };
    }

    /// Runs steps 4 and 5 for a run of content with at least one sharp end. Content without a
    /// sharp end is left to the pitch.
    fn place(strip: Strip, gpa: std.mem.Allocator, frames: *std.ArrayList(Placed), content: Content) !void {
        if (content.sharpEnds() == 0) return;
        const run = content.run;
        const measured = run.len();
        const count: usize = @intFromFloat(@max(1, @round((measured + strip.gap) / strip.pitch)));
        if (count > 1) return strip.fillRun(gpa, frames, content, count);

        if (@abs(measured - strip.length) <= strip.context.length_tolerance * strip.length) {
            return frames.append(gpa, strip.frame(run.middle(), strip.length, .confident));
        }
        if (measured < strip.length) {
            // One edge doesn't show, so the frame runs on from the edge that does.
            const start: f32 = @floatFromInt(run.start);
            const end: f32 = @floatFromInt(run.end);
            if (content.before == .sharp and content.after == .soft) return frames.append(gpa, strip.frame(start + strip.film_length / 2, strip.length, .check));
            if (content.after == .sharp and content.before == .soft) return frames.append(gpa, strip.frame(end - strip.film_length / 2, strip.length, .check));
        }
        return frames.append(gpa, strip.frame(run.middle(), measured, .check));
    }

    /// Places several frames in one run of content, where the boundaries between them don't
    /// show. They're spread evenly between two sharp ends, or placed at the pitch out from a
    /// single one.
    fn fillRun(strip: Strip, gpa: std.mem.Allocator, frames: *std.ArrayList(Placed), content: Content, count: usize) !void {
        const start: f32 = @floatFromInt(content.run.start);
        const end: f32 = @floatFromInt(content.run.end);
        const n: f32 = @floatFromInt(count);
        const spread = (content.run.len() + strip.gap) / n;
        for (0..count) |j| {
            const k: f32 = @floatFromInt(j);
            const middle = if (content.sharpEnds() == 2)
                start + (spread - strip.gap) / 2 + k * spread
            else if (content.before == .sharp)
                start + strip.film_length / 2 + k * strip.pitch
            else
                end - strip.film_length / 2 - (n - 1 - k) * strip.pitch;
            try frames.append(gpa, strip.frame(middle, strip.length, .check));
        }
    }

    /// When two frames are less than half a pitch apart, keeps the confident one, or else the
    /// first.
    fn dropDuplicates(strip: Strip, frames: *std.ArrayList(Placed)) void {
        var kept: usize = 0;
        for (frames.items) |f| {
            if (kept > 0 and f.along - frames.items[kept - 1].along < strip.pitch / 2) {
                if (f.confidence == .confident and frames.items[kept - 1].confidence == .check) frames.items[kept - 1] = f;
                continue;
            }
            frames.items[kept] = f;
            kept += 1;
        }
        frames.shrinkRetainingCapacity(kept);
    }

    /// Step 5: fills in frames, spread evenly, between two placed frames that are more than a
    /// pitch apart. Then adds frames beyond the outermost ones for as long as the film shows
    /// content at the pitch.
    fn fillByPitch(strip: Strip, gpa: std.mem.Allocator, frames: *std.ArrayList(Placed), gaps: []const bool, extent: Range) !void {
        if (frames.items.len == 0) return;
        var i: usize = 0;
        while (i + 1 < frames.items.len) : (i += 1) {
            const a = frames.items[i].along;
            const b = frames.items[i + 1].along;
            const count = @round((b - a) / strip.pitch);
            if (count < 2) continue;
            const step = (b - a) / count;
            var j: f32 = count - 1;
            while (j >= 1) : (j -= 1) try frames.insert(gpa, i + 1, strip.frame(a + j * step, strip.length, .check));
            i += @intFromFloat(count - 1);
        }
        var along = frames.items[0].along - strip.pitch;
        while (strip.slotShowsFilm(along, gaps, extent)) : (along -= strip.pitch) {
            try frames.insert(gpa, 0, strip.frame(along, strip.length, .check));
        }
        along = frames.items[frames.items.len - 1].along + strip.pitch;
        while (strip.slotShowsFilm(along, gaps, extent)) : (along += strip.pitch) {
            try frames.append(gpa, strip.frame(along, strip.length, .check));
        }
    }

    /// Whether a frame centred at `along` is mostly on the film and has some content in it.
    fn slotShowsFilm(strip: Strip, along: f32, gaps: []const bool, extent: Range) bool {
        const first = @max(along - strip.film_length / 2, @as(f32, @floatFromInt(extent.start)));
        const last = @min(along + strip.film_length / 2, @as(f32, @floatFromInt(extent.end)));
        if (last - first < min_partial * strip.film_length) return false;
        var content: f32 = 0;
        for (gaps[@intFromFloat(first)..@intFromFloat(last)]) |gap| {
            if (!gap) content += 1;
        }
        return content >= slot_content * strip.film_length;
    }

    /// Makes a frame centred at `along` on the opening's centre line, `length` lines long.
    fn frame(strip: Strip, along: f32, length: f32, confidence: Confidence) Placed {
        const c = strip.context;
        return .{
            .along = along,
            .across = c.opening.centre(along),
            .length = length * strip.scale,
            .height = c.frame_height,
            .slope = c.opening.slope(),
            .confidence = confidence,
        };
    }
};

/// Adds `distance` to the pitch samples if it's close to a whole number of pitches.
fn addPitch(gpa: std.mem.Allocator, pitches: *std.ArrayList(f32), distance: f32, guess: f32, tolerance: f32) !void {
    const count = @round(distance / guess);
    if (count < 1 or count > max_pitch_span) return;
    const pitch = distance / count;
    if (@abs(pitch - guess) <= tolerance * guess) try pitches.append(gpa, pitch);
}

/// Returns the median of `values`, sorting them on the way, or null when there are none.
/// The median by nearest rank, which is the upper of the two middle values when there's an even
/// number of them.
fn medianOf(values: []f32) ?f32 {
    return stats.percentile(values, 0.5);
}

/// Places mounted slides. Each aperture is a run of mostly light lines between opaque mounts, and
/// it's measured with its own edges and angle.
fn placeMounted(gpa: std.mem.Allocator, out: *std.ArrayList(Placed), profile: Profile, band: Band, c: Context, max_skew_degrees: f32) !void {
    var runs: std.ArrayList(Run) = .empty;
    defer runs.deinit(gpa);
    for (profile.light, 0..) |fraction, line| {
        const gap = fraction < aperture_light;
        if (runs.items.len > 0 and runs.items[runs.items.len - 1].gap == gap) {
            runs.items[runs.items.len - 1].end = line + 1;
        } else {
            try runs.append(gpa, .{ .start = line, .end = line + 1, .gap = gap });
        }
    }
    var i: usize = 1;
    while (i + 1 < runs.items.len) {
        if (runs.items[i].gap and runs.items[i].len() < mount_bridge * c.nominal_length) {
            flip(&runs, i);
            i = 1;
        } else i += 1;
    }

    for (runs.items) |run| {
        if (run.gap or run.len() < min_aperture * c.nominal_length) continue;
        const lines: Range = .{ .start = run.start, .end = run.end };
        const local = try fitOpening(gpa, c.view, c.edge_threshold, lines, band, c.px_per_mm, max_skew_degrees);
        const middle = run.middle();
        const length = run.len() * local.alongScale();
        const height = @max(local.height(middle), 1);
        const off_length = @abs(length - c.nominal_length) > c.length_tolerance * c.nominal_length;
        const off_height = @abs(height - c.nominal_height) > c.length_tolerance * c.nominal_height;
        try out.append(gpa, .{
            .along = middle,
            .across = local.centre(middle),
            .length = length,
            .height = height,
            .slope = local.slope(),
            .confidence = if (off_length or off_height) .check else .confident,
        });
    }
}

const synthetic = @import("synthetic.zig");

const testing_gpa = std.testing.allocator;
/// The number of frames on a 135 test strip.
const strip_135_frames = 6;

fn detectSynthetic(strip: synthetic.Strip, format: formats.Format, options: Options) !Detection {
    var scan = try strip.render(testing_gpa);
    defer scan.deinit(testing_gpa);
    return detect(testing_gpa, scan, strip.dpi, format, strip.kind, options);
}

fn areaCentre(area: image.Area) [2]f32 {
    return .{
        @as(f32, @floatFromInt(area.x)) + @as(f32, @floatFromInt(area.width)) / 2,
        @as(f32, @floatFromInt(area.y)) + @as(f32, @floatFromInt(area.height)) / 2,
    };
}

/// Checks that `detection` holds the frames of `strip` in order, each one centred within
/// `tolerance_mm` and with the given confidence.
fn expectFrames(detection: Detection, strip: synthetic.Strip, confidences: []const Confidence, tolerance_mm: f32) !void {
    try std.testing.expectEqual(strip.frames.len, detection.frames.len);
    const tolerance = tolerance_mm * strip.dpi / formats.mm_per_inch;
    for (detection.frames, strip.frames, confidences, 0..) |found, expected, confidence, i| {
        try std.testing.expectEqual(i, found.index);
        try std.testing.expectEqual(confidence, found.confidence);
        const want = strip.centre(expected);
        const got = areaCentre(found.area);
        try std.testing.expectApproxEqAbs(want[0], got[0], tolerance);
        try std.testing.expectApproxEqAbs(want[1], got[1], tolerance);
    }
}

const all_confident: [strip_135_frames]Confidence = @splat(.confident);

test "a 135 strip of six frames with clear gaps" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    const strip = synthetic.strip135(&frames);
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    try std.testing.expectEqual(Axis.y, detection.axis);
    try std.testing.expectApproxEqAbs(strip.opening_mm, detection.opening_mm, 0.2);
    try std.testing.expectApproxEqAbs(0, detection.rotation_degrees, 0.05);
    try expectFrames(detection, strip, &all_confident, 0.3);
    // The full opening height across, and the length from the 3:2 ratio.
    const px_per_mm = strip.dpi / formats.mm_per_inch;
    for (detection.frames) |f| {
        try std.testing.expectApproxEqAbs(strip.opening_mm * px_per_mm, @as(f32, @floatFromInt(f.area.width)), 1.5);
        try std.testing.expectApproxEqAbs(1.5 * strip.opening_mm * px_per_mm, @as(f32, @floatFromInt(f.area.height)), 2);
    }
}

test "a dark frame whose edges barely show is filled in from the pitch" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    const strip = synthetic.strip135(&frames);
    // Nearly as clear as the film base.
    frames[2].density = 0.03;
    frames[2].texture = 0.02;
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    try expectFrames(detection, strip, &.{ .confident, .confident, .check, .confident, .confident, .confident }, 0.5);
}

test "a slightly rotated strip" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    var strip = synthetic.strip135(&frames);
    strip.rotation_degrees = 1.5;
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    try std.testing.expectApproxEqAbs(strip.rotation_degrees, detection.rotation_degrees, 0.1);
    try std.testing.expectApproxEqAbs(strip.opening_mm, detection.opening_mm, 0.2);
    try expectFrames(detection, strip, &all_confident, 0.4);
    for (detection.frames) |f| try std.testing.expectApproxEqAbs(strip.rotation_degrees, f.rotation_degrees, 0.1);
}

test "a 120 6×6 strip with irregular gaps" {
    // Gaps of 3, 7 and 4.5 mm, the kind a camera without a fixed pitch leaves.
    const frames = [_]synthetic.Frame{
        .{ .start_mm = 5, .length_mm = 56 },
        .{ .start_mm = 64, .length_mm = 56, .density = 0.5 },
        .{ .start_mm = 127, .length_mm = 56, .density = 0.9 },
        .{ .start_mm = 187.5, .length_mm = 56 },
    };
    const strip: synthetic.Strip = .{
        .axis = .x,
        .across_mm = 70,
        .along_mm = 250,
        .opening_mm = 58,
        .image_mm = 56,
        .film_start_mm = 1,
        .film_end_mm = 249,
        .frames = &frames,
    };
    var detection = try detectSynthetic(strip, formats.Standard.@"120_6x6".format(), .{});
    defer detection.deinit(testing_gpa);
    try std.testing.expectEqual(Axis.x, detection.axis);
    try expectFrames(detection, strip, &.{ .confident, .confident, .confident, .confident }, 0.3);
}

test "a positive strip: opaque gaps" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    var strip = synthetic.strip135(&frames);
    strip.kind = .positive;
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    try expectFrames(detection, strip, &all_confident, 0.3);
}

test "the strip running horizontally and vertically" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    var along_y = synthetic.strip135(&frames);
    along_y.axis = .y;
    var along_x = along_y;
    along_x.axis = .x;
    var vertical = try detectSynthetic(along_y, formats.Standard.@"135_full_frame".format(), .{});
    defer vertical.deinit(testing_gpa);
    var horizontal = try detectSynthetic(along_x, formats.Standard.@"135_full_frame".format(), .{});
    defer horizontal.deinit(testing_gpa);
    try std.testing.expectEqual(Axis.y, vertical.axis);
    try std.testing.expectEqual(Axis.x, horizontal.axis);
    try expectFrames(vertical, along_y, &all_confident, 0.3);
    try expectFrames(horizontal, along_x, &all_confident, 0.3);
    // The same frames, with the axes swapped.
    for (vertical.frames, horizontal.frames) |v, h| {
        try std.testing.expect(@max(v.area.x, h.area.y) - @min(v.area.x, h.area.y) <= 1);
        try std.testing.expect(@max(v.area.y, h.area.x) - @min(v.area.y, h.area.x) <= 1);
        try std.testing.expect(@max(v.area.width, h.area.height) - @min(v.area.width, h.area.height) <= 1);
        try std.testing.expect(@max(v.area.height, h.area.width) - @min(v.area.height, h.area.width) <= 1);
    }
}

test "mounted slides: each aperture is a frame" {
    // 50 mm mounts with 35 × 23 mm apertures, not quite lined up.
    const frames = [_]synthetic.Frame{
        .{ .start_mm = 7.5, .length_mm = 35, .offset_mm = -0.5 },
        .{ .start_mm = 57.5, .length_mm = 35, .offset_mm = 0.4 },
        .{ .start_mm = 107.5, .length_mm = 35, .density = 1.2 },
    };
    const strip: synthetic.Strip = .{ .kind = .positive, .mounted = true, .along_mm = 160, .image_mm = 23, .frames = &frames };
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{ .holder = .mounted });
    defer detection.deinit(testing_gpa);
    try expectFrames(detection, strip, &.{ .confident, .confident, .confident }, 0.3);
    const px_per_mm = strip.dpi / formats.mm_per_inch;
    for (detection.frames) |f| {
        try std.testing.expectApproxEqAbs(strip.image_mm * px_per_mm, @as(f32, @floatFromInt(f.area.width)), 2);
        try std.testing.expectApproxEqAbs(35 * px_per_mm, @as(f32, @floatFromInt(f.area.height)), 2);
    }
}

test "perforations outside the holder's cover are left out of the opening" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    var strip = synthetic.strip135(&frames);
    strip.perforated = true;
    strip.across_mm = 40;
    strip.opening_mm = 37;
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    // The space between the perforations: 35 mm film minus two rows that start 2.0 mm in and are
    // 2.8 mm wide.
    try std.testing.expectApproxEqAbs(25.4, detection.opening_mm, 0.5);
    try expectFrames(detection, strip, &all_confident, 0.3);
}

test "a frame far from the format's length keeps its measured box" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    const strip = synthetic.strip135(&frames);
    frames[3].length_mm = 28;
    frames[3].start_mm += 4;
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    try expectFrames(detection, strip, &.{ .confident, .confident, .confident, .check, .confident, .confident }, 0.3);
    const px_per_mm = strip.dpi / formats.mm_per_inch;
    try std.testing.expectApproxEqAbs(28 * px_per_mm, @as(f32, @floatFromInt(detection.frames[3].area.height)), 2);
}

test "a frame cut off by the end of the scan is marked for checking" {
    // The scan stops 20 mm into the third frame, the way a frame scan with a margin does.
    const frames = [_]synthetic.Frame{
        .{ .start_mm = synthetic.leader_135_mm, .length_mm = synthetic.frame_135_mm },
        .{ .start_mm = synthetic.leader_135_mm + synthetic.pitch_135_mm, .length_mm = synthetic.frame_135_mm },
        .{ .start_mm = synthetic.leader_135_mm + 2 * synthetic.pitch_135_mm, .length_mm = 20 },
    };
    const strip: synthetic.Strip = .{ .along_mm = synthetic.leader_135_mm + 2 * synthetic.pitch_135_mm + 20, .film_start_mm = 1, .frames = &frames };
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    try expectFrames(detection, strip, &.{ .confident, .confident, .check }, 0.3);
}

test "bare light past the end of a strip shorter than the opening" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    var strip = synthetic.strip135(&frames);
    // The film ends 1 mm after the last frame, then 40 mm of light before the holder.
    strip.film_end_mm = strip.along_mm - synthetic.leader_135_mm + 1;
    strip.bare_mm = 40;
    strip.along_mm = strip.film_end_mm.? + strip.bare_mm + 5;
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    try expectFrames(detection, strip, &all_confident, 0.3);
}

test "a frame scan's gaps at its ends aren't bare light" {
    // One frame and a little of the gaps on either side, the way a frame is scanned with a
    // margin: the film runs to both ends of the scan.
    const frames = [_]synthetic.Frame{.{ .start_mm = 1.5, .length_mm = synthetic.frame_135_mm }};
    const strip: synthetic.Strip = .{ .along_mm = synthetic.frame_135_mm + 3, .frames = &frames };
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    try expectFrames(detection, strip, &.{.confident}, 0.3);
}

test "a clear leader isn't bare light" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    var strip = synthetic.strip135(&frames);
    // 20 mm of unexposed film after the last frame.
    strip.along_mm += 20;
    strip.film_end_mm = strip.along_mm - 1;
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{});
    defer detection.deinit(testing_gpa);
    try expectFrames(detection, strip, &all_confident, 0.3);
}

/// Renders `strips`, all running along y and as long as each other, side by side, the way a
/// flatbed's holder lays out several openings. Returns the scan and each strip's left edge.
fn sideBySide(strips: []const synthetic.Strip, lefts: []usize) !image.Scan {
    var width: usize = 0;
    for (strips, lefts) |strip, *left| {
        left.* = width;
        width += strip.size()[0];
    }
    const height = strips[0].size()[1];
    var scan: image.Scan = try .init(testing_gpa, width, height);
    errdefer scan.deinit(testing_gpa);
    for (strips, lefts) |strip, left| {
        var part = try strip.render(testing_gpa);
        defer part.deinit(testing_gpa);
        for (0..height) |y| @memcpy(scan.row(y)[left..][0..part.width], part.row(y));
    }
    return scan;
}

test "a holder with several openings: frames in each one with film" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    const film = synthetic.strip135(&frames);
    var short_frames: [4]synthetic.Frame = undefined;
    var short = synthetic.strip135(&short_frames);
    short.along_mm = film.along_mm;
    short.film_end_mm = film.film_end_mm;
    short.seed = 2;
    // An opening with nothing in it shows bare light.
    var empty = film;
    empty.frames = &.{};
    empty.base = empty.lamp;
    empty.film_start_mm = 0;
    empty.film_end_mm = null;
    const strips = [_]synthetic.Strip{ film, empty, short, empty };
    var lefts: [strips.len]usize = undefined;
    var scan = try sideBySide(&strips, &lefts);
    defer scan.deinit(testing_gpa);

    var detection = try detect(testing_gpa, scan, film.dpi, formats.Standard.@"135_full_frame".format(), .negative, .{});
    defer detection.deinit(testing_gpa);
    try std.testing.expectEqual(Axis.y, detection.axis);
    try std.testing.expectEqual(strips.len, detection.openings.len);
    for (detection.openings, strips, lefts) |opening, strip, left| {
        try std.testing.expectEqual(strip.frames.len > 0, opening.film);
        try std.testing.expectApproxEqAbs(strip.opening_mm, opening.height_mm, 0.3);
        const middle = @as(f32, @floatFromInt(left)) + @as(f32, @floatFromInt(strip.size()[0])) / 2;
        try std.testing.expectApproxEqAbs(middle, opening.middle_px, 1.5);
    }
    // The first opening's frames, then the third's.
    try std.testing.expectEqual(frames.len + short_frames.len, detection.frames.len);
    const tolerance = 0.3 * film.dpi / formats.mm_per_inch;
    for (detection.frames, 0..) |found, i| {
        const in_first = i < frames.len;
        const opening: usize = if (in_first) 0 else 2;
        const expected = if (in_first) frames[i] else short_frames[i - frames.len];
        try std.testing.expectEqual(i, found.index);
        try std.testing.expectEqual(opening, found.opening);
        try std.testing.expectEqual(Confidence.confident, found.confidence);
        const want = strips[opening].centre(expected);
        const got = areaCentre(found.area);
        try std.testing.expectApproxEqAbs(want[0] + @as(f32, @floatFromInt(lefts[opening])), got[0], tolerance);
        try std.testing.expectApproxEqAbs(want[1], got[1], tolerance);
    }
}

test "a holder hole narrower than the film isn't an opening" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    const film = synthetic.strip135(&frames);
    var hole = film;
    hole.frames = &.{};
    hole.base = hole.lamp;
    hole.opening_mm = 5;
    hole.across_mm = 10;
    const strips = [_]synthetic.Strip{ hole, film };
    var lefts: [strips.len]usize = undefined;
    var scan = try sideBySide(&strips, &lefts);
    defer scan.deinit(testing_gpa);
    var detection = try detect(testing_gpa, scan, film.dpi, formats.Standard.@"135_full_frame".format(), .negative, .{});
    defer detection.deinit(testing_gpa);
    try std.testing.expectEqual(1, detection.openings.len);
    try std.testing.expectEqual(frames.len, detection.frames.len);
    for (detection.frames) |f| try std.testing.expectEqual(0, f.opening);
}

test "a scan with no light band has no opening" {
    var scan: image.Scan = try .init(testing_gpa, 64, 256);
    defer scan.deinit(testing_gpa);
    @memset(scan.pixels, @splat(40));
    try std.testing.expectError(error.NoOpening, detect(testing_gpa, scan, 100, formats.Standard.default.format(), .negative, .{}));
}
