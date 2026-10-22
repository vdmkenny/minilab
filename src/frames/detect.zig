//! Frame detection on a strip preview (design section 6).
//!
//! The scan is reduced to one value per pixel, the geometric mean of its channels, and read in
//! strip coordinates: `u` counts lines along the strip and `v` samples across it, whichever image
//! axis the strip runs along. Positions are continuous: sample `i` covers `[i, i + 1)`. For
//! negatives:
//!
//! 1. Classify. The holder transmits almost nothing, the film base between frames is the most
//!    transparent film, and the image sits in between. A level between the darkest and the
//!    lightest parts of the scan splits holder from film; the film base is measured in step 3.
//! 2. Opening. Lines fitted to the two long edges of the light band give the strip's angle and
//!    the frame height. Where 135's perforations show, their bands are left out.
//! 3. Gaps. Along the strip, each line across the band is sampled at right angles to the strip.
//!    A line is gap when its median is at base density and it is flat; a thin image still shows
//!    texture. Each run of content between gaps has two ends: sharp where the density steps up
//!    within half a millimetre, soft where it doesn't, or cut by the end of the film or scan.
//! 4. Snap. Each frame gets the opening's height less the inset, and its length from the
//!    format's ratio, centred between its gaps. A frame whose measured length is far off keeps
//!    its measured box and is marked for checking. One sharp end anchors a frame whose other
//!    end doesn't show.
//! 5. Weak frames. Frames whose edges don't show at all, as dark scenes close to base density,
//!    are filled in from the pitch: measured between sharp edges where they repeat, else the
//!    format's fixed pitch. They are marked for checking.
//!
//! Positives take the same steps with the gap test inverted: unexposed film between frames is
//! opaque. Mounted slides are found by their apertures instead, each measured on its own.

const std = @import("std");
const image = @import("../core/image.zig");
const formats = @import("formats.zig");

/// Which way the gap test goes.
pub const Kind = enum {
    /// Gaps between frames are clear film base, the most transparent film.
    negative,
    /// Gaps between frames are unexposed and so opaque.
    positive,

    /// How far in density a line may be from the gap level and still count as gap. Positives
    /// get more room, because their gap level sits in the scanner's noise.
    pub fn defaultGapTolerance(kind: Kind) f32 {
        return switch (kind) {
            .negative => 0.08,
            .positive => 0.25,
        };
    }

    /// Whether a line whose quartiles are `spread` apart in density is flat enough to be a gap.
    /// A negative's clear base is flat where a thin image still shows texture. A positive's gap
    /// sits in the scanner's noise, where the spread says nothing.
    fn isFlat(kind: Kind, spread: f32) bool {
        return switch (kind) {
            .negative => spread < flat_spread,
            .positive => true,
        };
    }
};

pub const Holder = enum {
    /// A strip of film in a holder: the holder's long edges bound the opening.
    strip,
    /// Mounted slides: each mount is opaque and its aperture is the frame.
    mounted,
};

/// The image axis the strip runs along.
pub const Axis = enum { x, y };

pub const Confidence = enum {
    confident,
    /// Filled in from the pitch, measured far from the format, or cut off: the user should look.
    check,
};

pub const Frame = struct {
    /// Order along the strip, from 0 at the start of the axis.
    index: usize,
    /// The frame before rotation: centred on the frame, with the frame's size, clipped to the
    /// scan.
    area: image.Area,
    /// The frame is `area` turned by this many degrees about its centre. Positive turns
    /// clockwise as displayed, with y pointing down.
    rotation_degrees: f32,
    confidence: Confidence,
};

pub const Options = struct {
    /// The image axis the strip runs along; null detects it.
    axis: ?Axis = null,
    holder: Holder = .strip,
    /// Taken off each long side of the opening, in mm. For an opening wider than the image, such
    /// as a mask for narrower film.
    inset_mm: f32 = 0,
    /// A frame whose measured length is further than this fraction from the format's is marked
    /// for checking.
    length_tolerance: f32 = 0.12,
    /// In density; null uses the kind's default.
    gap_tolerance: ?f32 = null,
    /// The largest skew of the strip searched for.
    max_skew_degrees: f32 = 3,
};

pub const Detection = struct {
    axis: Axis,
    /// The strip's skew, with the same sign as `Frame.rotation_degrees`.
    rotation_degrees: f32,
    /// The opening's height across the strip, before the inset.
    opening_mm: f32,
    frames: []Frame,

    pub fn deinit(detection: *Detection, gpa: std.mem.Allocator) void {
        gpa.free(detection.frames);
        detection.* = undefined;
    }
};

pub const Error = error{ NoOpening, BadResolution } || std.mem.Allocator.Error;

/// Smaller scans hold nothing to detect.
const min_scan_px = 16;

/// Levels are histogrammed on their top bits.
const level_bits = 12;
const level_shift = @bitSizeOf(u16) - level_bits;
const level_bins = 1 << level_bits;
/// The holder's level: this fraction of the scan is darker.
const dark_quantile = 0.01;
/// The lightest level, film base or bare light: this fraction of the scan is darker.
const bright_quantile = 0.99;
/// Where the holder threshold sits between the dark and bright levels, on a log scale, and where
/// the threshold for the holder's edges does.
const holder_split = 0.3;
const edge_split = 0.5;
/// Below this ratio of bright to dark the scan shows no holder.
const min_holder_contrast = 4;
/// Levels are at least this, so their logarithms stay finite.
const level_floor = 8;
/// A scan whose lightest level is below this shows no film: 1% of full scale.
const min_light = image.full_scale / 100;

/// Two axes whose plateaus differ by less than this are told apart by the band's width.
const axis_tie = 0.1;
/// The plateau of a light-fraction profile: this fraction of positions are below it.
const plateau_quantile = 0.9;
/// A position across is in the band when it is light at least this fraction as often as the
/// lightest position.
const band_fraction = 0.5;
/// Dips in the band narrower than this are bridged.
const band_bridge_mm = 1.0;

/// This many light samples in a row make an edge.
const edge_run = 3;
/// The blur either side of an edge, and how far past the holder threshold the edge is looked for.
const edge_blur_mm = 0.1;
const edge_search_mm = 1.0;
/// Room beyond the coarse edge in which an edge is searched for.
const edge_guard_mm = 1.0;
/// Robust line fitting: rounds, the outlier limit in standard deviations, the median absolute
/// deviation's scale to one, and the smallest limit in pixels.
const fit_rounds = 4;
const fit_sigma = 3.0;
const mad_to_sigma = 1.4826;
const min_fit_residual = 0.5;
const min_edge_points = 8;
/// Edges whose slopes differ by less than this are parallel and averaged.
const parallel_slope = 0.01;
/// A fitted slope beyond this multiple of the largest searched is a failed fit.
const skew_slack = 1.5;

/// Perforations are searched for when the band is this much taller than the format.
const perforation_band_ratio = 1.25;
/// The fraction of the band at each side searched for perforations.
const perforation_reach = 0.35;
/// The periodicity score a perforated column reaches: autocorrelation at the pitch less that at
/// half the pitch.
const perforation_score = 0.8;
const min_perforation_columns = 2;

/// The fraction of the opening's height left out at each side when sampling a line.
const band_margin = 0.05;
const max_line_samples = 256;
/// A line is flat when its quartiles are closer than this in density.
const flat_spread = 0.05;
/// The lightest (negatives) or darkest (positives) median lines give the gap level.
const gap_quantile = 0.98;
/// The least length of flat lines, in mm, that gives a gap level of its own.
const min_flat_mm = 0.5;

/// Runs shorter than this are noise and merge into their neighbours.
const min_run_mm = 0.3;
/// Content between gaps shorter than this fraction of a frame is noise in a gap.
const short_content = 0.3;
/// A frame cut off at an end of the strip must show this fraction of its length.
const min_partial = 0.5;
/// A gap wider than both of these is not a gap between neighbouring frames: a multiple of the
/// format's gap, and a fraction of the frame length.
const wide_gap_factor = 3;
const wide_gap_fraction = 0.15;
/// How far into content its edge is judged, and the density step, as a multiple of the gap
/// tolerance, that makes it sharp.
const edge_depth_mm = 0.5;
const sharp_factor = 3;
/// A frame placed from the pitch past the outermost frames needs this fraction of its length to
/// be content.
const slot_content = 0.25;
/// Sharp edges further apart than this many pitches don't measure it.
const max_pitch_span = 3;

/// Mounted slides: dark runs shorter than this fraction of a frame are inside an aperture, and
/// apertures shorter than this fraction are not slides.
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
    // A resolution from a roll's file or the command line: none at all would make every length 0.
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

    const band = try coarseBand(gpa, view, levels.threshold, all_lines, px_per_mm) orelse return error.NoOpening;
    var opening = try fitOpening(gpa, view, levels.edge, all_lines, band, px_per_mm, options.max_skew_degrees);
    const middle = @as(f32, @floatFromInt(view.along)) / 2;
    if (format.size.perforationPitchMm()) |pitch| {
        if (opening.height(middle) > perforation_band_ratio * nominal_height) {
            try leaveOutPerforations(gpa, view, &opening, all_lines, pitch * px_per_mm);
        }
    }

    var profile: Profile = try .measure(gpa, view, opening, levels.threshold);
    defer profile.deinit(gpa);

    const inset = options.inset_mm * px_per_mm;
    const frame_height = @max(opening.height(middle) - 2 * inset, 1);
    const context: Context = .{
        .view = view,
        .opening = opening,
        .threshold = levels.threshold,
        .edge_threshold = levels.edge,
        .kind = kind,
        .gap_tolerance = options.gap_tolerance orelse kind.defaultGapTolerance(),
        .length_tolerance = options.length_tolerance,
        .ratio_lock = format.ratio_lock,
        .frame_height = frame_height,
        .frame_length = switch (format.ratio_lock) {
            .locked => frame_height * format.ratio(),
            .free => format.width_mm * px_per_mm,
        },
        .nominal_length = format.width_mm * px_per_mm,
        .nominal_height = nominal_height,
        .nominal_pitch = if (format.pitch_mm) |pitch| pitch * px_per_mm else null,
        .nominal_gap = format.gapMm() * px_per_mm,
        .inset = inset,
        .px_per_mm = px_per_mm,
    };

    var placed: std.ArrayList(Placed) = .empty;
    defer placed.deinit(gpa);
    switch (options.holder) {
        .strip => try placeStrip(gpa, &placed, profile, context),
        .mounted => try placeMounted(gpa, &placed, profile, band, context, options.max_skew_degrees),
    }
    std.mem.sortUnstable(Placed, placed.items, {}, Placed.before);

    const frames = try gpa.alloc(Frame, placed.items.len);
    for (frames, placed.items, 0..) |*frame, p, i| {
        frame.* = p.toFrame(axis, scan.width, scan.height);
        frame.index = i;
    }
    return .{
        .axis = axis,
        .rotation_degrees = rotationDegrees(axis, opening.slope()),
        .opening_mm = opening.height(middle) / px_per_mm,
        .frames = frames,
    };
}

/// One value per pixel: the geometric mean of its channels, so that each channel's density
/// counts the same however dense the film base is in it, as in a colour negative's mask.
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
    /// Film is above this level and the holder at or below it.
    threshold: u16,
    /// Halfway between holder and film on a log scale: above the flare around the holder's
    /// edges, for finding them.
    edge: u16,
};

/// Step 1: the level that splits holder from film. Null when nothing in the scan is light.
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

/// The level below which `fraction` of the `count` values fall, at the middle of its bin.
fn histogramQuantile(histogram: []const u32, count: usize, fraction: f32) f32 {
    const rank: usize = @intFromFloat(fraction * @as(f32, @floatFromInt(count - 1)));
    var seen: usize = 0;
    for (histogram, 0..) |n, bin| {
        seen += n;
        if (seen > rank) return @floatFromInt((bin << level_shift) + (1 << level_shift) / 2);
    }
    return std.math.maxInt(u16);
}

/// Which axis the strip runs along. Seen along the strip, the positions across the opening are
/// light on nearly every line; seen the other way, no line is light much more than the opening's
/// share of the scan's width.
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

/// The high end of the fractions `counts[i] / lines`.
fn plateau(gpa: std.mem.Allocator, counts: []const u32, lines: usize) !f32 {
    const sorted = try gpa.dupe(u32, counts);
    defer gpa.free(sorted);
    std.mem.sortUnstable(u32, sorted, {}, std.sort.asc(u32));
    return @as(f32, @floatFromInt(quantile(u32, sorted, plateau_quantile))) / @as(f32, @floatFromInt(lines));
}

/// How many positions are light on at least half the lines, at least 1.
fn bandWidth(counts: []const u32, lines: usize) f32 {
    var n: usize = 0;
    for (counts) |c| {
        if (2 * c >= lines) n += 1;
    }
    return @floatFromInt(@max(n, 1));
}

fn quantile(comptime T: type, sorted: []const T, fraction: f32) T {
    const last: f32 = @floatFromInt(sorted.len - 1);
    return sorted[@intFromFloat(@round(fraction * last))];
}

/// The luminance plane read in strip coordinates.
const View = struct {
    values: []const u16,
    /// Lines along the strip, and samples per line.
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

    /// The sample nearest the continuous position, or null outside the view.
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

/// The light band across, from the light fraction of each position: `near` is its first
/// position and `far` one past its last.
const Band = struct { near: usize, far: usize };

fn coarseBand(gpa: std.mem.Allocator, view: View, threshold: u16, lines: Range, px_per_mm: f32) !?Band {
    const counts = try gpa.alloc(u32, view.across);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (lines.start..lines.end) |u| {
        for (counts, 0..) |*count, v| {
            if (view.at(u, v) > threshold) count.* += 1;
        }
    }
    const most = std.mem.max(u32, counts);
    if (most == 0) return null;
    const bridge: usize = @intFromFloat(band_bridge_mm * px_per_mm);
    var best: ?Band = null;
    var current: ?Band = null;
    for (counts, 0..) |count, v| {
        if (@as(f32, @floatFromInt(count)) < band_fraction * @as(f32, @floatFromInt(most))) continue;
        if (current) |*c| {
            if (v - c.far <= bridge) {
                c.far = v + 1;
                continue;
            }
            if (best == null or c.far - c.near > best.?.far - best.?.near) best = c.*;
        }
        current = .{ .near = v, .far = v + 1 };
    }
    if (current) |c| {
        if (best == null or c.far - c.near > best.?.far - best.?.near) best = c;
    }
    return best;
}

/// A straight edge in strip coordinates: `v = offset + slope · u`.
const Line = struct {
    offset: f32,
    slope: f32,

    fn at(line: Line, u: f32) f32 {
        return line.offset + line.slope * u;
    }
};

/// The opening between the holder's long edges.
const Opening = struct {
    near: Line,
    far: Line,

    fn slope(opening: Opening) f32 {
        return (opening.near.slope + opening.far.slope) / 2;
    }

    fn centre(opening: Opening, u: f32) f32 {
        return (opening.near.at(u) + opening.far.at(u)) / 2;
    }

    /// The height at right angles to the strip, in pixels.
    fn height(opening: Opening, u: f32) f32 {
        const s = opening.slope();
        return (opening.far.at(u) - opening.near.at(u)) / @sqrt(1 + s * s);
    }

    /// Pixels along the strip per line.
    fn alongScale(opening: Opening) f32 {
        const s = opening.slope();
        return @sqrt(1 + s * s);
    }
};

const Point = struct { u: f32, v: f32 };

/// Step 2: lines fitted to the long edges of the band, over `lines`.
fn fitOpening(gpa: std.mem.Allocator, view: View, edge_threshold: u16, lines: Range, band: Band, px_per_mm: f32, max_skew_degrees: f32) !Opening {
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

/// The edge in `samples`, which run from outside the band inwards, in samples from the outer
/// end. The first run of film above the holder threshold finds it roughly, but flare outside the
/// holder can lift the level over the threshold early, so the edge is the steepest rise in log
/// level from there on, placed where the level crosses halfway between the two sides. Null when
/// the outer end isn't holder or no film follows.
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

/// A least-squares line through `points` that drops outliers round by round. The inliers end up
/// at the front of `points`. Null with too few points or a slope steeper than `max_slope`.
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

/// The median offset of `points` for lines of `slope`.
fn offsetWithSlope(points: []const Point, slope: f32, scratch: []f32) f32 {
    const offsets = scratch[0..points.len];
    for (points, offsets) |p, *o| o.* = p.v - slope * p.u;
    std.mem.sortUnstable(f32, offsets, {}, std.sort.asc(f32));
    return offsets[offsets.len / 2];
}

/// Where the film's edges show, 135's perforations repeat along the strip at their pitch. The
/// columns that do are left out of the opening, together with everything outside them.
fn leaveOutPerforations(gpa: std.mem.Allocator, view: View, opening: *Opening, lines: Range, pitch_px: f32) !void {
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

/// Autocorrelation at `lag` less autocorrelation at `half_lag`: near 2 for a square wave of
/// period `lag`, near 0 for smooth image content.
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

/// Each line across the opening, sampled at right angles to the strip.
const Profile = struct {
    /// The median level of each line.
    median: []f32,
    /// The distance between each line's quartiles, in density.
    spread: []f32,
    /// The fraction of each line above the holder threshold.
    light: []f32,

    fn measure(gpa: std.mem.Allocator, view: View, opening: Opening, threshold: u16) !Profile {
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

    fn deinit(profile: *Profile, gpa: std.mem.Allocator) void {
        gpa.free(profile.median);
        gpa.free(profile.spread);
        gpa.free(profile.light);
        profile.* = undefined;
    }
};

/// What a frame placement needs to know, in pixels.
const Context = struct {
    view: View,
    opening: Opening,
    threshold: u16,
    edge_threshold: u16,
    kind: Kind,
    gap_tolerance: f32,
    length_tolerance: f32,
    ratio_lock: formats.RatioLock,
    /// The frame's size: the height from the opening less the inset, the length from the
    /// format's ratio, or its nominal length when the ratio is free.
    frame_height: f32,
    frame_length: f32,
    /// The format's size.
    nominal_length: f32,
    nominal_height: f32,
    /// The format's fixed pitch, if it has one, and its gap.
    nominal_pitch: ?f32,
    nominal_gap: f32,
    inset: f32,
    px_per_mm: f32,
};

/// A frame in strip coordinates.
const Placed = struct {
    /// The centre along, in lines, and across, in samples.
    along: f32,
    across: f32,
    /// The size along and across the strip, in pixels.
    length: f32,
    height: f32,
    /// The strip's slope, dv/du, at this frame.
    slope: f32,
    confidence: Confidence,

    fn before(_: void, a: Placed, b: Placed) bool {
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

/// The strip's skew as an image rotation. Along y a positive slope leans the strip's axis
/// anticlockwise from straight down; along x it leans it clockwise from straight right.
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

/// How a run of content meets what lies beyond one of its ends.
const Side = enum {
    /// The density steps up from the gap level within a short distance: the frame's edge shows.
    sharp,
    /// The image stays close to the gap level near the end, as a dark scene does: the frame's
    /// edge doesn't show and may lie further out.
    soft,
    /// The film or the scan ends inside the content.
    cut,
};

const End = enum { start, end };

/// A run of content and how each of its ends looks.
const Content = struct {
    run: Run,
    before: Side,
    after: Side,

    fn sharpEnds(content: Content) usize {
        return @as(usize, @intFromBool(content.before == .sharp)) + @intFromBool(content.after == .sharp);
    }
};

/// Steps 3 to 5 for a strip.
fn placeStrip(gpa: std.mem.Allocator, out: *std.ArrayList(Placed), profile: Profile, c: Context) !void {
    const extent = filmExtent(profile.median, c.threshold) orelse return;
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

    // Content that no edge anchors and the pitch doesn't reach keeps its measured box.
    for (contents.items) |content| {
        if (content.sharpEnds() > 0) continue;
        const covered = for (frames.items) |f| {
            if (@abs(f.along - content.run.middle()) < strip.film_length / 2) break true;
        } else false;
        if (!covered) try frames.append(gpa, strip.frame(content.run.middle(), content.run.len(), .check));
    }
    try out.appendSlice(gpa, frames.items);
}

/// Whether the content's `end` shows a frame edge: the most density within `depth` lines of it.
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

/// The lines between the first and last that show film rather than holder.
fn filmExtent(median: []const f32, threshold: u16) ?Range {
    const limit: f32 = @floatFromInt(threshold);
    var start: usize = 0;
    while (start < median.len and median[start] <= limit) start += 1;
    var end = median.len;
    while (end > start and median[end - 1] <= limit) end -= 1;
    if (end == start) return null;
    return .{ .start = start, .end = end };
}

/// The level of the gaps between frames. For negatives, the film base: the lightest median
/// lines. Bare light past the end of a short strip is lighter still, so where light runs reach
/// the ends, the base comes from the flat lines between them. For positives, the darkest lines.
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

            var flat: usize = 0;
            for (medians[start..end], profile.spread[extent.start + start .. extent.start + end]) |m, s| {
                if (s < flat_spread) {
                    sorted[flat] = m;
                    flat += 1;
                }
            }
            if (@as(f32, @floatFromInt(flat)) < min_flat_mm * c.px_per_mm) return lightest;
            std.mem.sortUnstable(f32, sorted[0..flat], {}, std.sort.asc(f32));
            return @max(quantile(f32, sorted[0..flat], gap_quantile), level_floor);
        },
    }
}

/// How far a level is from the gap level in density, towards the image: denser for negatives,
/// lighter for positives. Zero or less is at the gap level.
fn densityFromGap(kind: Kind, gap_level: f32, value: f32) f32 {
    const v = @max(value, level_floor);
    return switch (kind) {
        .negative => std.math.log10(gap_level / v),
        .positive => std.math.log10(v / gap_level),
    };
}

/// Merges noise into its surroundings: runs too short to mean anything, content too short to be
/// a frame between gaps, and pairs of short content runs between gaps, split by a gap where the
/// two together make one frame. Content at an end showing too little of a frame becomes part of
/// the gap.
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

/// Turns gap into content or content into gap, and merges it with its neighbours.
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

/// Frame placement along a strip, in lines.
const Strip = struct {
    context: Context,
    /// Pixels along the strip per line.
    scale: f32,
    /// The snapped box's length, the frame's length on the film, the gap and the pitch.
    length: f32,
    film_length: f32,
    gap: f32,
    pitch: f32,

    /// The frame length, gap and pitch, measured where the edges show and taken from the
    /// format where they don't.
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

        // Sharp edges of the same kind lie whole pitches apart.
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

    /// Steps 4 and 5 for a run of content with at least one sharp end; content without one is
    /// left to the pitch.
    fn place(strip: Strip, gpa: std.mem.Allocator, frames: *std.ArrayList(Placed), content: Content) !void {
        if (content.sharpEnds() == 0) return;
        const run = content.run;
        const measured = run.len();
        const count: usize = @intFromFloat(@max(1, @round((measured + strip.gap) / strip.pitch)));
        if (count > 1) return strip.fillRun(gpa, frames, content, count);

        if (@abs(measured - strip.length) <= strip.context.length_tolerance * strip.length) {
            const along = if (strip.context.ratio_lock == .free) measured else strip.length;
            return frames.append(gpa, strip.frame(run.middle(), along, .confident));
        }
        if (measured < strip.length) {
            // One edge doesn't show: the frame runs on from the edge that does.
            const start: f32 = @floatFromInt(run.start);
            const end: f32 = @floatFromInt(run.end);
            if (content.before == .sharp and content.after == .soft) return frames.append(gpa, strip.frame(start + strip.film_length / 2, strip.length, .check));
            if (content.after == .sharp and content.before == .soft) return frames.append(gpa, strip.frame(end - strip.film_length / 2, strip.length, .check));
        }
        return frames.append(gpa, strip.frame(run.middle(), measured, .check));
    }

    /// Several frames in one run of content, the boundaries between them not showing: spread
    /// evenly between two sharp ends, or placed at the pitch out from one.
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

    /// Of two frames less than half a pitch apart, keeps the confident one, or else the first.
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

    /// Step 5: frames between two placed frames more than a pitch apart, spread evenly, and
    /// frames past the outermost ones while the film shows content at the pitch.
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

    /// Whether a frame centred at `along` lies mostly on the film and holds some content.
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

    /// A frame centred at `along` on the opening's centre line, `length` lines long.
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

/// Adds `distance` to the pitch samples if it is close to a whole number of pitches.
fn addPitch(gpa: std.mem.Allocator, pitches: *std.ArrayList(f32), distance: f32, guess: f32, tolerance: f32) !void {
    const count = @round(distance / guess);
    if (count < 1 or count > max_pitch_span) return;
    const pitch = distance / count;
    if (@abs(pitch - guess) <= tolerance * guess) try pitches.append(gpa, pitch);
}

/// The median of `values`, sorting them; null when there are none.
fn medianOf(values: []f32) ?f32 {
    if (values.len == 0) return null;
    std.mem.sortUnstable(f32, values, {}, std.sort.asc(f32));
    return quantile(f32, values, 0.5);
}

/// Mounted slides: each aperture is a run of mostly light lines between opaque mounts, measured
/// with its own edges and angle.
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
        const height = @max(local.height(middle) - 2 * c.inset, 1);
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
/// The frames on a 135 test strip.
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

/// `detection` holds the frames of `strip` in order, each centred within `tolerance_mm` and with
/// the given confidence.
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
    // Full opening height across; the length from the 3:2 ratio.
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
    // Gaps of 3, 7 and 4.5 mm, as a camera without a fixed pitch leaves them.
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
    // 50 mm mounts with 35 × 23 mm apertures, not quite in line.
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
    // Between the perforations: 35 mm film less two rows 2.0 mm in and 2.8 mm wide.
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
    // The scan stops 20 mm into the third frame, as a frame scan with a margin does.
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

test "the inset narrows the frame and shortens it by the ratio" {
    var frames: [strip_135_frames]synthetic.Frame = undefined;
    const strip = synthetic.strip135(&frames);
    var detection = try detectSynthetic(strip, formats.Standard.@"135_full_frame".format(), .{ .inset_mm = 0.5 });
    defer detection.deinit(testing_gpa);
    const px_per_mm = strip.dpi / formats.mm_per_inch;
    const height = (strip.opening_mm - 1) * px_per_mm;
    for (detection.frames) |f| {
        try std.testing.expectApproxEqAbs(height, @as(f32, @floatFromInt(f.area.width)), 1.5);
        try std.testing.expectApproxEqAbs(1.5 * height, @as(f32, @floatFromInt(f.area.height)), 2);
    }
}

test "a scan with no light band has no opening" {
    var scan: image.Scan = try .init(testing_gpa, 64, 256);
    defer scan.deinit(testing_gpa);
    @memset(scan.pixels, @splat(40));
    try std.testing.expectError(error.NoOpening, detect(testing_gpa, scan, 100, formats.Standard.default.format(), .negative, .{}));
}
