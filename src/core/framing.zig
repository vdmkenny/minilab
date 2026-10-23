//! Finds the frames on a scan as the app uses them: on a scan of one frame, frame detection's best
//! box, trimmed to the format's size, and on a strip, each whole frame (`findAll`).

const std = @import("std");
const image = @import("image.zig");
const develop = @import("develop.zig");
const frames = @import("../frames/root.zig");

/// Reduced copies for detection are at most this many pixels along the longer side.
pub const detection_longest = 1600;

/// The frame on a scan, and the clear film in the gaps on either side of it along the strip, all
/// in the full scan's pixels.
pub const Found = struct {
    frame: image.Area,
    /// Bands inside the gaps before and after the frame, where there's nothing but film base. Null
    /// where the gap is off the scan.
    gaps: [2]?image.Area,
};

/// Where in a gap we read the base: from this far past the frame's edge to this far, in mm, so
/// that neither this frame's edge nor the next one's is included. 135's gaps are about 2 mm.
const gap_from_mm = 0.4;
const gap_to_mm = 1.2;
/// The share of the frame's extent across the film that we read, in the middle, away from the
/// rebate.
const gap_across_share = 0.8;

/// A frame detection finds counts as whole if it's at least this share of the format's length
/// along the strip. A shorter one is cut off by the edge of the scan.
const whole_share = 0.9;
/// A scan with at least this many whole frames on it is a strip.
const strip_least_frames = 2;

/// Finds the frame on `scan`, in the full scan's pixels. See `findWithGaps`.
pub fn find(gpa: std.mem.Allocator, scan: image.Scan, scan_width: usize, scan_height: usize, dpi: ?f32, format: frames.Format, kind: develop.FilmKind) !image.Area {
    return (try findWithGaps(gpa, scan, scan_width, scan_height, dpi, format, kind)).frame;
}

/// Finds the frame on `scan` and the gaps beside it, in the full scan's pixels (`scan_width` ×
/// `scan_height`). `scan` can be any size, such as a reduced copy of the full scan. `dpi` is the
/// full scan's resolution, and null means guess it from the film's width. Of the frames found, the
/// one nearest the middle wins, and a sure one beats one marked for checking.
pub fn findWithGaps(gpa: std.mem.Allocator, scan: image.Scan, scan_width: usize, scan_height: usize, dpi: ?f32, format: frames.Format, kind: develop.FilmKind) !Found {
    var search: Search = try .run(gpa, scan, scan_width, scan_height, dpi, format, kind);
    defer search.deinit(gpa);
    return search.place(search.nearestMiddle() orelse return error.NoFrame);
}

/// Finds every frame on `scan` (with the same arguments as `findWithGaps`), in order along the
/// film. A strip, with `strip_least_frames` or more whole frames on it, gives each of its whole
/// frames, and frames cut off by the scan's edge are left out. Any other scan gives the one frame
/// `findWithGaps` finds. The caller frees the slice.
pub fn findAll(gpa: std.mem.Allocator, scan: image.Scan, scan_width: usize, scan_height: usize, dpi: ?f32, format: frames.Format, kind: develop.FilmKind) ![]Found {
    var search: Search = try .run(gpa, scan, scan_width, scan_height, dpi, format, kind);
    defer search.deinit(gpa);
    var whole: usize = 0;
    for (search.detection.frames) |f| whole += @intFromBool(search.isWhole(f.area));
    if (whole < strip_least_frames) {
        const found = try gpa.alloc(Found, 1);
        found[0] = search.place(search.nearestMiddle() orelse {
            gpa.free(found);
            return error.NoFrame;
        });
        return found;
    }
    const found = try gpa.alloc(Found, whole);
    var n: usize = 0;
    for (search.detection.frames) |f| {
        if (!search.isWhole(f.area)) continue;
        found[n] = search.place(f);
        n += 1;
    }
    return found;
}

/// Frame detection on a reduced scan, plus what we need to map its frames onto the full scan.
const Search = struct {
    detection: frames.Detection,
    /// The reduced scan detection ran on, and the full scan's size.
    scan: image.Scan,
    scan_width: usize,
    scan_height: usize,
    format: frames.Format,
    /// The reduced scan's pixels per mm.
    px_per_mm: f32,

    fn run(gpa: std.mem.Allocator, scan: image.Scan, scan_width: usize, scan_height: usize, dpi: ?f32, format: frames.Format, kind: develop.FilmKind) !Search {
        const scale = @as(f32, @floatFromInt(scan_width)) / @as(f32, @floatFromInt(scan.width));
        const scan_dpi = dpi orelse guessDpi(scan_width, scan_height, format);
        const preview_dpi = scan_dpi / scale;
        return .{
            .detection = try frames.detect.detect(gpa, scan, preview_dpi, format, if (kind.isNegative()) .negative else .positive, .{}),
            .scan = scan,
            .scan_width = scan_width,
            .scan_height = scan_height,
            .format = format,
            .px_per_mm = preview_dpi / frames.formats.mm_per_inch,
        };
    }

    fn deinit(search: *Search, gpa: std.mem.Allocator) void {
        search.detection.deinit(gpa);
    }

    fn alongX(search: Search) bool {
        return search.detection.axis == .x;
    }

    /// Returns the frame nearest the middle of the scan, preferring a sure one over one marked
    /// for checking.
    fn nearestMiddle(search: Search) ?frames.Frame {
        var best: ?frames.Frame = null;
        var best_distance: f32 = std.math.inf(f32);
        const middle = [2]f32{ @floatFromInt(search.scan.width / 2), @floatFromInt(search.scan.height / 2) };
        for (search.detection.frames) |f| {
            const cx = @as(f32, @floatFromInt(f.area.x)) + @as(f32, @floatFromInt(f.area.width)) / 2;
            const cy = @as(f32, @floatFromInt(f.area.y)) + @as(f32, @floatFromInt(f.area.height)) / 2;
            var distance = std.math.hypot(cx - middle[0], cy - middle[1]);
            if (f.confidence == .check) distance *= 4;
            if (distance < best_distance) {
                best_distance = distance;
                best = f;
            }
        }
        return best;
    }

    /// Whether `area`, a frame detection found, is entirely on the scan.
    fn isWhole(search: Search, area: image.Area) bool {
        const along: f32 = @floatFromInt(if (search.alongX()) area.width else area.height);
        return along >= whole_share * search.format.width_mm * search.px_per_mm;
    }

    /// Trims `chosen` to the format's size and finds the gaps on either side of it, on the full
    /// scan.
    fn place(search: Search, chosen: frames.Frame) Found {
        // Detection sizes frames from the holder's opening, which shows a little rebate on every
        // side. The picture is the format's own size.
        const along_x = search.alongX();
        const format = search.format;
        const px_per_mm = search.px_per_mm;
        const scan = search.scan;
        const target_w = (if (along_x) format.width_mm else format.height_mm) * px_per_mm;
        const target_h = (if (along_x) format.height_mm else format.width_mm) * px_per_mm;
        var area = chosen.area;
        const w = @min(area.width, @as(usize, @intFromFloat(target_w)));
        const h = @min(area.height, @as(usize, @intFromFloat(target_h)));
        area.x += (area.width - w) / 2;
        area.y += (area.height - h) / 2;
        area.width = w;
        area.height = h;

        // The gaps: bands just past the frame's two ends along the strip.
        var gaps: [2]?image.Area = .{ null, null };
        const from: usize = @intFromFloat(gap_from_mm * px_per_mm);
        const to: usize = @intFromFloat(@max(gap_to_mm * px_per_mm, gap_from_mm * px_per_mm + 2));
        const along_start = if (along_x) area.x else area.y;
        const along_end = along_start + (if (along_x) area.width else area.height);
        const along_size = if (along_x) scan.width else scan.height;
        const across_start = if (along_x) area.y else area.x;
        const across_size = if (along_x) area.height else area.width;
        const margin: usize = @intFromFloat(@as(f32, @floatFromInt(across_size)) * (1 - gap_across_share) / 2);
        const bands = [2]?[2]usize{
            if (along_start >= to) .{ along_start - to, along_start - from } else null,
            if (along_end + to <= along_size) .{ along_end + from, along_end + to } else null,
        };
        for (&gaps, bands) |*gap, band| {
            const b = band orelse continue;
            const local: image.Area = if (along_x)
                .{ .x = b[0], .y = across_start + margin, .width = b[1] - b[0], .height = across_size - 2 * margin }
            else
                .{ .x = across_start + margin, .y = b[0], .width = across_size - 2 * margin, .height = b[1] - b[0] };
            gap.* = local.rescale(scan.width, search.scan_width, search.scan_width, search.scan_height);
        }
        return .{ .frame = area.rescale(scan.width, search.scan_width, search.scan_width, search.scan_height), .gaps = gaps };
    }
};

/// Measures the film base's transmission per channel, 0..1, from the gaps beside a frame on `scan`
/// (the areas are in `scan`'s pixels). It's the median of the thinner gap. At either end of a
/// strip, one "gap" is really the leader (fogged when the film was loaded) or the holder, and the
/// clear base is always the thinnest film there is. Returns null when no gap is on the scan.
pub fn measureBase(gpa: std.mem.Allocator, scan: image.Scan, gaps: [2]?image.Area) !?[3]f32 {
    var best: ?[3]f32 = null;
    for (gaps) |gap| {
        const area = gap orelse continue;
        const median = try medianOf(gpa, scan, area);
        if (best == null or median[0] + median[1] + median[2] > best.?[0] + best.?[1] + best.?[2]) best = median;
    }
    return best;
}

/// The median of each channel over `area` of `scan`, 0..1.
fn medianOf(gpa: std.mem.Allocator, scan: image.Scan, area: image.Area) ![3]f32 {
    var values: [3]std.ArrayList(u16) = .{ .empty, .empty, .empty };
    defer for (&values) |*v| v.deinit(gpa);
    for (area.y..area.y + area.height) |y| {
        for (scan.row(y)[area.x..][0..area.width]) |p| {
            for (&values, p) |*list, v| try list.append(gpa, v);
        }
    }
    var median: [3]f32 = undefined;
    for (&median, &values) |*m, *list| {
        std.mem.sort(u16, list.items, {}, std.sort.asc(u16));
        m.* = @as(f32, @floatFromInt(list.items[list.items.len / 2])) / image.full_scale;
    }
    return median;
}

/// Guesses the resolution of a scan of one frame when the scanner didn't say, assuming its
/// shorter side spans the film's width minus the holder's lips. It's good to a few per cent for a
/// frame in a holder.
pub fn guessDpi(width: usize, height: usize, format: frames.Format) f32 {
    const across_mm = (format.size.filmWidthMm() orelse format.height_mm) - 2;
    return @as(f32, @floatFromInt(@min(width, height))) / across_mm * frames.formats.mm_per_inch;
}

const synthetic = @import("../frames/synthetic.zig");
/// How far a found frame's centre can be from where it really is on the film.
const test_tolerance_mm = 2;

test "every whole frame of a strip, in order, each with the base in its gaps" {
    const gpa = std.testing.allocator;
    var on_film: [6]synthetic.Frame = undefined;
    const strip = synthetic.strip135(&on_film);
    var scan = try strip.render(gpa);
    defer scan.deinit(gpa);
    const found = try findAll(gpa, scan, scan.width, scan.height, strip.dpi, frames.Standard.@"135_full_frame".format(), .colour_negative);
    defer gpa.free(found);
    try std.testing.expectEqual(on_film.len, found.len);
    const tolerance_px = test_tolerance_mm * strip.dpi / frames.formats.mm_per_inch;
    const noise_share = 2 * strip.noise;
    for (found, on_film) |f, expected| {
        const centre = strip.centre(expected);
        try std.testing.expectApproxEqAbs(centre[1], @as(f32, @floatFromInt(f.frame.y)) + @as(f32, @floatFromInt(f.frame.height)) / 2, tolerance_px);
        const base = (try measureBase(gpa, scan, f.gaps)).?;
        for (base) |b| try std.testing.expectApproxEqAbs(strip.base, b, strip.base * noise_share);
    }
}

test "a scan of one frame with the edges of its neighbours is one frame" {
    const gpa = std.testing.allocator;
    var on_film: [3]synthetic.Frame = undefined;
    const strip = synthetic.strip135(&on_film);
    // The middle frame and 2 mm on either side, the way the scanner scans a frame with its margin.
    const margin_mm = 2;
    var one = try strip.render(gpa);
    defer one.deinit(gpa);
    const px_per_mm = strip.dpi / frames.formats.mm_per_inch;
    const start: usize = @intFromFloat((on_film[1].start_mm - margin_mm) * px_per_mm);
    const length: usize = @intFromFloat((on_film[1].length_mm + 2 * margin_mm) * px_per_mm);
    var cut = try one.crop(gpa, .{ .x = 0, .y = start, .width = one.width, .height = length });
    defer cut.deinit(gpa);
    const found = try findAll(gpa, cut, cut.width, cut.height, strip.dpi, frames.Standard.@"135_full_frame".format(), .colour_negative);
    defer gpa.free(found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    const middle = @as(f32, @floatFromInt(cut.height)) / 2;
    try std.testing.expectApproxEqAbs(middle, @as(f32, @floatFromInt(found[0].frame.y)) + @as(f32, @floatFromInt(found[0].frame.height)) / 2, test_tolerance_mm * px_per_mm);
}
