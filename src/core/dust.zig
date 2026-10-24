//! Dust removal. A speck of dust on the film blocks light, so on a raw scan it's a small spot that's
//! denser than the film around it. That holds for negatives and slides alike: once developed, it's
//! light on a negative and dark on a slide. A finished picture, such as a lab's scan, is already a
//! positive. Most of those are of negatives, so there we look for spots lighter than around them.
//!
//! The idea comes from Tea and Tech Time's automatic sensor dust removal: find small spots that
//! stand out from what's around them, keep the ones that are on their own (texture has lots of them
//! close together), and fill them in from around them. This is our own version of it, for film:
//!
//! 1. Work in density, the log of the light that gets through, averaged over the channels. A speck
//!    adds about the same density wherever it lands, on thin film or dense.
//! 2. Take the background away. A grey opening (the minimum over a square as wide as `max_size`,
//!    then the maximum over the same square) flattens every bump narrower than the square and keeps
//!    everything wider, edges included. The scan minus its opening (the top hat) is just the small
//!    bumps.
//! 3. Measure the top hat's mean and spread around each pixel. The spread is the grain and the
//!    scanner's noise there, or the picture's own fine detail. A bump that stands `threshold` times
//!    the spread above the mean is a speck. Its fainter edge, down to half that, goes with it.
//! 4. Group specks that are close together. A group bigger than `max_size` is texture, not dust,
//!    and stays as it is (a fibre can be twice as long, if it's thin). So does a speck denser than
//!    `max_density`, a speck on an edge, with the background on one side of it much denser than on
//!    another, and one that's the peak of a bigger clump, like a lamp's bulb in its glow: those are
//!    the picture's highlights.
//! 5. Fill each speck, and a little round it, the way a healing brush does: with the patch of
//!    film nearby whose ring of pixels best matches the ring round the speck, evened out to its
//!    level. So the grain, fine or coarse, and the picture's own texture, such as fur, carry on
//!    through the speck from real film. Where there's no patch to take, the speck is filled
//!    smoothly from its edge inwards instead.
//!
//! Pixels away from the specks are never changed, and grain on its own never stands out enough
//! to count, even a fast film's: `min_threshold` is set so that it doesn't. Small lights in the
//! picture, such as fairy lights, stars or confetti, can look just like dust. Most of them stand
//! further above the film than dust does, so a lower `max_density` keeps them; otherwise leave
//! dust removal off for those frames.
//!
//! The sizes are shares of the frame's longer side, so the same specks go at any resolution: in
//! Develop's reduced copy, in the loupe and in a full-size export, from any scanner or camera.

const std = @import("std");
const image = @import("image.zig");

/// A frame's dust removal, saved with its develop settings. The three limits are there to keep
/// the picture's own small highlights from being taken for dust.
pub const Settings = struct {
    remove: bool = false,
    /// How many times the grain around it a spot has to stand out by to count as dust. Lower finds
    /// fainter specks, and more of the picture's own detail by mistake.
    threshold: f32 = default_threshold,
    /// The widest speck, in percent of the frame's longer side. Anything wider is the picture.
    max_size: f32 = default_max_size,
    /// The most a speck can stand above the film around it, in D. A lamp's bulb or a star stands
    /// further above it than most dust does. At `max_max_density` there's no limit.
    max_density: f32 = default_max_density,

    pub const default_threshold = 8;
    /// Below this, the clumps of a fast film's coarse grain start to stand out like dust. Above
    /// the top, only a few of the most obvious specks are left to find.
    pub const min_threshold = 6;
    pub const max_threshold = 20;
    /// 0.5% is about 0.2 mm on 35mm film. Past 1.2%, hardly any more specks come in.
    pub const default_max_size = 0.5;
    pub const min_max_size = 0.2;
    pub const max_max_size = 1.2;
    /// At 0.2 D only faint specks go. Past 1.5 D, little but a light in the picture is that much
    /// denser than the film around it, so the top means no limit.
    pub const default_max_density = max_max_density;
    pub const min_max_density = 0.2;
    pub const max_max_density = 1.5;

    comptime {
        for ([_][3]f32{
            .{ min_threshold, default_threshold, max_threshold },
            .{ min_max_size, default_max_size, max_max_size },
            .{ min_max_density, default_max_density, max_max_density },
        }) |range| if (!(range[0] <= range[1] and range[1] <= range[2])) @compileError("a dust default is outside its range");
        if (!(min_max_size <= tuned_size and tuned_size <= max_max_size)) @compileError("the tuned size is outside Max size's range");
    }

    /// The densest a speck can be, as a `Code`, or null for no limit.
    fn densest(settings: Settings) ?Code {
        if (settings.max_density >= max_max_density) return null;
        return @intFromFloat(@max(0, settings.max_density) * steps_per_density);
    }
};

/// Which way dust shows on the scan.
pub const Polarity = enum {
    /// Denser than around it: any raw scan of film.
    dense,
    /// Lighter than around it: a finished picture of a negative.
    light,
};

/// The size, in percent of the frame's longer side, that measuring the grain and grouping specks
/// are set for. The opening is never narrower than this, so a `max_size` below it only leaves
/// more alone.
const tuned_size = 0.8;
/// A fibre can be this many times longer than the largest speck is wide, if it's on average this
/// many times thinner.
const fibre_length = 2;
const fibre_width = 4;
/// How far around a speck the grain is measured, in specks.
const grain_reach = 4;
/// The ring filled round a speck as well, as a share of the frame's longer side, for its soft edge.
const edge_share = 0.0005;
/// Frames smaller than this along their longer side are left alone. A speck there is less than a
/// pixel, and the picture's own small details are only a few.
pub const min_frame = 512;
/// The faintest speck, in D, so a picture with no grain at all doesn't turn up specks of nothing.
const faintest = 0.03;
/// A speck's fainter edge counts down to this share of its threshold.
const edge_threshold = 0.5;
/// The most the background beside a speck can change from one side to another, as a share of how
/// far the speck stands out. More than that and it's on an edge, where a highlight in the picture
/// looks just like dust.
const flat_sides = 0.5;

/// Density is kept as a whole number of these steps per D, much finer than any scan's noise. The
/// densest a 16-bit scan can be is log10(65535), about 4.8 D, which still fits in a `Code`.
const steps_per_density = 10000;
const Code = u16;
const max_code = std.math.maxInt(Code);
comptime {
    if (@log10(@as(f64, image.full_scale)) * steps_per_density > max_code) @compileError("densities don't fit in a Code");
}

/// The sizes the steps work at, in pixels, for a frame `frame_longest` pixels along its longer side
/// and specks up to `max_size` percent of that. Below `tuned_size`, finding the specks works just
/// as at `tuned_size`, and only what fits as a speck shrinks, so a smaller `max_size` only ever
/// leaves more alone. Above it, the opening grows to let bigger specks stand out.
const Sizes = struct {
    /// The opening's square reaches this far from its centre, so it's `2 * speck + 1` across. A
    /// speck has to be narrower than that to stand out from the opening.
    speck: usize,
    /// The widest speck that fits.
    widest: usize,
    /// `speck` at `tuned_size`: how close specks are to group, and how far round a speck the film
    /// it sits on is measured.
    near: usize,
    /// How far round a pixel its grain is measured.
    grain: usize,
    /// The ring filled round a speck as well, for its soft edge.
    edge: usize,

    fn of(frame_longest: usize, max_size: f32) Sizes {
        const longest: f32 = @floatFromInt(frame_longest);
        const fitting = reach(longest, std.math.clamp(max_size, Settings.min_max_size, Settings.max_max_size));
        const near = reach(longest, tuned_size);
        const speck = @max(near, fitting);
        return .{
            .speck = speck,
            .widest = 2 * fitting + 1,
            .near = near,
            // The grain's ring reaches past the guard square by `near` at least.
            .grain = @max(grain_reach * near, 2 * speck + 1 + near),
            .edge = @max(1, @as(usize, @intFromFloat(@round(longest * edge_share)))),
        };
    }

    /// How far from its centre a square `size` percent of `longest` reaches.
    fn reach(longest: f32, size: f32) usize {
        return @max(1, @as(usize, @intFromFloat(@round(longest * size / percent / 2))));
    }

    const percent = 100;

    /// The opening's square, from side to side.
    fn across(sizes: Sizes) usize {
        return 2 * sizes.speck + 1;
    }

    /// Whether a speck of `count` pixels in `box` is small enough to be dust: no bigger than the
    /// widest speck, or a fibre up to `fibre_length` times as long and on average `fibre_width`
    /// times thinner.
    fn fits(sizes: Sizes, box: image.Area, count: usize) bool {
        const long = @max(box.width, box.height);
        return long <= sizes.widest or (long <= fibre_length * sizes.widest and count * fibre_width <= long * sizes.widest);
    }
};

/// How far from a pixel dust removal with `settings` looks, in pixels, on a frame `frame_longest`
/// pixels along its longer side. Removing the dust from part of a frame, cut this much bigger,
/// finds nearly the same specks in the part as removing it from the whole frame.
pub fn margin(frame_longest: usize, settings: Settings) usize {
    const sizes: Sizes = .of(frame_longest, settings.max_size);
    // The opening's minimum and maximum, the grain around the top hat, the longest fibre, and the
    // film round it that its clump is measured against.
    return 2 * sizes.speck + sizes.grain + fibre_length * sizes.across() + clump_ring_out * sizes.near + sizes.edge;
}

/// Returns a copy of `scan` with its dust removed as `settings` ask, or null when they leave it
/// alone or the frame is too small to have any worth removing. `frame_longest` is the frame's
/// longer side at `scan`'s resolution: `scan` may be just part of the frame, as in the loupe. The
/// caller frees the copy.
pub fn cleaned(gpa: std.mem.Allocator, scan: image.Scan, settings: Settings, polarity: Polarity, frame_longest: usize) !?image.Scan {
    if (!settings.remove or frame_longest < min_frame) return null;
    const copy: image.Scan = .{ .width = scan.width, .height = scan.height, .pixels = try gpa.dupe([image.channel_count]u16, scan.pixels) };
    errdefer gpa.free(copy.pixels);
    _ = try remove(gpa, copy, settings, polarity, frame_longest);
    return copy;
}

/// Removes the dust from `scan` in place with `settings`' limits, whether or not they say to
/// remove it, and returns how many specks it found. `frame_longest` is as in `cleaned`.
pub fn remove(gpa: std.mem.Allocator, scan: image.Scan, settings: Settings, polarity: Polarity, frame_longest: usize) !usize {
    const n = scan.pixels.len;
    if (n == 0 or frame_longest < min_frame) return 0;
    const sizes: Sizes = .of(frame_longest, settings.max_size);

    // The background is the density's opening, and the top hat is what stands up from it. The
    // density itself isn't needed after that, so the top hat takes its place.
    const top_hat = try gpa.alloc(Code, n);
    defer gpa.free(top_hat);
    try densities(gpa, scan.pixels, polarity, top_hat);
    const background = try gpa.alloc(Code, n);
    defer gpa.free(background);
    @memcpy(background, top_hat);
    try filter(Code, .min, gpa, background, scan.width, scan.height, sizes.speck);
    try filter(Code, .max, gpa, background, scan.width, scan.height, sizes.speck);
    for (top_hat, background) |*t, b| t.* -= b;

    const marks = try gpa.alloc(Mark, n);
    defer gpa.free(marks);
    try mark(gpa, top_hat, scan.width, scan.height, sizes, settings.threshold, marks);

    var found: Specks = .{};
    defer found.deinit(gpa);
    const planes: Planes = .{ .marks = marks, .top_hat = top_hat, .background = background, .width = scan.width, .height = scan.height };
    try findSpecks(gpa, planes, sizes, settings.densest(), &found);
    try fill(gpa, scan, planes, found, sizes.edge);
    return found.boxes.items.len;
}

/// Fills `out` with each pixel's density as a `Code`: −log10 of its transmission, averaged over
/// the channels. For `.light` it's turned upside down, so light specks stand up as dense ones do.
fn densities(gpa: std.mem.Allocator, pixels: []const [image.channel_count]u16, polarity: Polarity, out: []Code) !void {
    const table = try gpa.alloc(Code, image.full_scale + 1);
    defer gpa.free(table);
    for (table, 0..) |*t, v| {
        const transmission = @as(f64, @floatFromInt(@max(v, 1))) / image.full_scale;
        t.* = @intFromFloat(@round(-std.math.log10(transmission) * steps_per_density));
    }
    for (out, pixels) |*d, p| {
        var sum: u32 = 0;
        for (p) |v| sum += table[v];
        const mean: Code = @intCast(sum / image.channel_count);
        d.* = switch (polarity) {
            .dense => mean,
            .light => max_code - mean,
        };
    }
}

const Op = enum { min, max };

fn pick(comptime T: type, comptime op: Op, a: T, b: T) T {
    return switch (op) {
        .min => @min(a, b),
        .max => @max(a, b),
    };
}

/// How many columns `filter` copies out at a time, so its reads down the columns stay in the
/// cache.
const column_tile = 32;

/// Replaces each value of the `width` × `height` image `values` with the minimum (or maximum) over
/// the square reaching `radius` from it. Past the edges counts as nothing.
fn filter(comptime T: type, comptime op: Op, gpa: std.mem.Allocator, values: []T, width: usize, height: usize, radius: usize) !void {
    const padded = @max(width, height) + 2 * radius;
    const forward = try gpa.alloc(T, padded);
    defer gpa.free(forward);
    const backward = try gpa.alloc(T, padded);
    defer gpa.free(backward);
    for (0..height) |y| runLine(T, op, values[y * width ..][0..width], radius, forward, backward);

    const columns = try gpa.alloc(T, column_tile * height);
    defer gpa.free(columns);
    var x0: usize = 0;
    while (x0 < width) : (x0 += column_tile) {
        const count = @min(column_tile, width - x0);
        for (0..height) |y| {
            for (values[y * width + x0 ..][0..count], 0..) |v, k| columns[k * height + y] = v;
        }
        for (0..count) |k| runLine(T, op, columns[k * height ..][0..height], radius, forward, backward);
        for (0..height) |y| {
            for (values[y * width + x0 ..][0..count], 0..) |*v, k| v.* = columns[k * height + y];
        }
    }
}

/// Replaces each value in `line` with the minimum (or maximum) of the values within `radius` of
/// it. It's van Herk and Gil and Werman's way, a few steps per value however wide the window:
/// split the line into blocks a window wide, run the minimum forwards and backwards within each
/// block, and each window is then the backward run at its start and the forward run at its end.
/// `forward` and `backward` are scratch, at least `line.len + 2 * radius` long.
fn runLine(comptime T: type, comptime op: Op, line: []T, radius: usize, forward: []T, backward: []T) void {
    const window = 2 * radius + 1;
    const padded = line.len + 2 * radius;
    const outside: T = switch (op) {
        .min => std.math.maxInt(T),
        .max => 0,
    };
    for (0..padded) |i| {
        const v = if (i >= radius and i < radius + line.len) line[i - radius] else outside;
        forward[i] = if (i % window == 0) v else pick(T, op, forward[i - 1], v);
    }
    var i = padded;
    while (i > 0) {
        i -= 1;
        const v = if (i >= radius and i < radius + line.len) line[i - radius] else outside;
        backward[i] = if (i % window == window - 1 or i == padded - 1) v else pick(T, op, backward[i + 1], v);
    }
    for (line, 0..) |*out, at| out.* = pick(T, op, backward[at], forward[at + window - 1]);
}

/// Marks the specks in `top_hat`, a `width` × `height` image. The grain around each pixel is the
/// top hat's mean and spread in the ring between the square reaching `sizes.grain` from it and the
/// one reaching `sizes.across()`, which is left out so that a speck doesn't count towards its own
/// grain. A pixel that stands `threshold` times the spread above the mean is strong, and one that
/// stands half as far is faint. The squares are cut off at the edges.
fn mark(gpa: std.mem.Allocator, top_hat: []const Code, width: usize, height: usize, sizes: Sizes, threshold: f32, marks: []Mark) !void {
    var outer: Window = try .init(gpa, top_hat, width, sizes.grain);
    defer outer.deinit(gpa);
    var inner: Window = try .init(gpa, top_hat, width, sizes.across());
    defer inner.deinit(gpa);
    const floor = faintest * steps_per_density;
    for (0..height) |y| {
        outer.moveTo(y, height);
        inner.moveTo(y, height);
        for (marks[y * width ..][0..width], top_hat[y * width ..][0..width], 0..) |*m, t, x| {
            var ring = outer.sumAt(x);
            const centre = inner.sumAt(x);
            // Only on a picture smaller than the guard is there no ring; then the whole square
            // will do.
            if (ring.count > centre.count) ring = ring.minus(centre);
            const count: f64 = @floatFromInt(ring.count);
            const mean = @as(f64, @floatFromInt(ring.plain)) / count;
            const square = @as(f64, @floatFromInt(ring.squared)) / count;
            const spread = @sqrt(@max(square - mean * mean, least_variance));
            const above = @as(f64, @floatFromInt(t)) - mean;
            const strong = @max(threshold * spread, floor);
            m.* = if (above > strong) .strong else if (above > strong * edge_threshold) .faint else .none;
        }
    }
}

/// The least the grain's variance counts as, in `Code`s squared, so film with no grain at all
/// doesn't make every bump a speck.
const least_variance = 1;

/// Sums of `values` and their squares over the square reaching `radius` from each pixel of a row,
/// a row at a time from the top: down each column over the square's rows, then along the row.
const Window = struct {
    values: []const Code,
    width: usize,
    radius: usize,
    columns: []Sums,
    /// `running[x]` is the sum of `columns[0..x]`.
    running: []Sums,
    /// The rows in the columns' sums are `top..bottom`.
    top: usize = 0,
    bottom: usize = 0,

    const Sums = struct {
        plain: u64 = 0,
        squared: u64 = 0,
        count: u64 = 0,

        fn of(v: Code) Sums {
            return .{ .plain = v, .squared = @as(u64, v) * v, .count = 1 };
        }

        fn plus(a: Sums, b: Sums) Sums {
            return .{ .plain = a.plain + b.plain, .squared = a.squared + b.squared, .count = a.count + b.count };
        }

        fn minus(a: Sums, b: Sums) Sums {
            return .{ .plain = a.plain - b.plain, .squared = a.squared - b.squared, .count = a.count - b.count };
        }
    };

    fn init(gpa: std.mem.Allocator, values: []const Code, width: usize, radius: usize) !Window {
        const columns = try gpa.alloc(Sums, width);
        errdefer gpa.free(columns);
        @memset(columns, .{});
        return .{ .values = values, .width = width, .radius = radius, .columns = columns, .running = try gpa.alloc(Sums, width + 1) };
    }

    fn deinit(window: *Window, gpa: std.mem.Allocator) void {
        gpa.free(window.columns);
        gpa.free(window.running);
    }

    /// Moves the square's rows to the ones around row `y` of `height`.
    fn moveTo(window: *Window, y: usize, height: usize) void {
        const w = window.width;
        while (window.bottom < @min(height, y + window.radius + 1)) : (window.bottom += 1) {
            for (window.columns, window.values[window.bottom * w ..][0..w]) |*s, v| s.* = s.plus(.of(v));
        }
        while (window.top < y -| window.radius) : (window.top += 1) {
            for (window.columns, window.values[window.top * w ..][0..w]) |*s, v| s.* = s.minus(.of(v));
        }
        window.running[0] = .{};
        for (window.columns, 0..) |s, x| window.running[x + 1] = window.running[x].plus(s);
    }

    /// The sums over the square around column `x` of the current row.
    fn sumAt(window: *const Window, x: usize) Sums {
        return window.running[@min(window.width, x + window.radius + 1)].minus(window.running[x -| window.radius]);
    }
};

const Mark = enum(u8) { none, faint, strong };

/// The specks found: each one's pixels, as indices into the scan, and the box around them.
const Specks = struct {
    pixels: std.ArrayList(u32) = .empty,
    /// Each speck's pixels are `pixels[start..end]`.
    boxes: std.ArrayList(Box) = .empty,

    const Box = struct { start: u32, end: u32, area: image.Area };

    fn deinit(specks: *Specks, gpa: std.mem.Allocator) void {
        specks.pixels.deinit(gpa);
        specks.boxes.deinit(gpa);
    }
};

/// What `findSpecks` knows about each pixel.
const Seen = packed struct(u8) {
    /// Part of a spot: a strong mark, or a faint one joined to a strong one.
    spot: bool = false,
    /// Within reach of a spot, so in its group.
    near: bool = false,
    /// Already taken into a group.
    taken: bool = false,
    _: u5 = 0,
};

/// What `findSpecks` looks at, per pixel of a `width` × `height` scan.
const Planes = struct {
    marks: []const Mark,
    /// How far the pixel stands up from the background, and the background, both in `Code`s.
    top_hat: []const Code,
    background: []const Code,
    width: usize,
    height: usize,
};

/// Finds the specks among `planes.marks`: spots of strong marks with the faint ones joined to
/// them, in groups no bigger than the largest speck and no denser than `densest`, on a background
/// that's flat compared with the speck, and not the bright heart of a bigger clump. Spots closer
/// together than a speck's reach form one group.
fn findSpecks(gpa: std.mem.Allocator, planes: Planes, sizes: Sizes, densest: ?Code, found: *Specks) !void {
    const marks = planes.marks;
    const width = planes.width;
    const height = planes.height;
    const seen = try gpa.alloc(Seen, marks.len);
    defer gpa.free(seen);
    @memset(seen, .{});
    var stack: std.ArrayList(u32) = .empty;
    defer stack.deinit(gpa);
    var clump: Clump = .{};
    defer clump.deinit(gpa);

    // The spots: flood out from each strong mark through the marks next to it.
    const Spot = struct {
        marks: []const Mark,
        seen: []Seen,

        fn enter(spot: @This(), at: u32) bool {
            if (spot.marks[at] == .none or spot.seen[at].spot) return false;
            spot.seen[at].spot = true;
            return true;
        }

        fn reach(_: @This(), _: u32) !bool {
            return true;
        }
    };
    const spot: Spot = .{ .marks = marks, .seen = seen };
    for (marks, 0..) |m, start| {
        if (m != .strong or !spot.enter(@intCast(start))) continue;
        try stack.append(gpa, @intCast(start));
        _ = try flood(gpa, &stack, width, height, spot);
    }

    // Each spot reaches out `near`, so spots that close end up in one group.
    const nearby = try gpa.alloc(u8, marks.len);
    defer gpa.free(nearby);
    for (nearby, seen) |*n, s| n.* = @intFromBool(s.spot);
    try filter(u8, .max, gpa, nearby, width, height, sizes.near);
    for (seen, nearby) |*s, n| s.near = n != 0;

    // The groups: flood through the pixels near a spot, keeping the spots' pixels.
    const Group = struct {
        gpa: std.mem.Allocator,
        seen: []Seen,
        width: usize,
        found: *Specks,
        area: Bounds = .{},

        fn enter(group: *@This(), at: u32) bool {
            if (!group.seen[at].near or group.seen[at].taken) return false;
            group.seen[at].taken = true;
            return true;
        }

        fn reach(group: *@This(), at: u32) !bool {
            if (!group.seen[at].spot) return true;
            try group.found.pixels.append(group.gpa, at);
            group.area.add(at % group.width, at / group.width);
            return true;
        }
    };
    for (seen, 0..) |s, start| {
        if (!s.spot) continue;
        var group: Group = .{ .gpa = gpa, .seen = seen, .width = width, .found = found };
        if (!group.enter(@intCast(start))) continue;
        const first = found.pixels.items.len;
        try stack.append(gpa, @intCast(start));
        _ = try flood(gpa, &stack, width, height, &group);
        const box = group.area.toArea();
        const pixels = found.pixels.items[first..];
        var peak: Code = 0;
        for (pixels) |at| peak = @max(peak, planes.top_hat[at]);
        const dense_enough = if (densest) |limit| peak <= limit else true;
        if (!dense_enough or !sizes.fits(box, pixels.len) or !onFlat(planes, peak, box, sizes) or !try onItsOwn(gpa, planes, pixels, box, sizes, &clump)) {
            // Too dense or too big for dust, a highlight on an edge, or the heart of something
            // bigger: it's the picture.
            found.pixels.shrinkRetainingCapacity(first);
            continue;
        }
        try found.boxes.append(gpa, .{ .start = @intCast(first), .end = @intCast(found.pixels.items.len), .area = box });
    }
}

/// Whether the speck in `box`, standing `peak` above the background, sits on a background that's
/// flat compared with that. The background is averaged along each side of the speck, a speck's
/// reach out, so the grain evens out; on an edge, one side is much lighter than another.
fn onFlat(planes: Planes, peak: Code, box: image.Area, sizes: Sizes) bool {
    const reach = sizes.near;
    const w = planes.width;
    const h = planes.height;
    const left = box.x -| reach;
    const top = box.y -| reach;
    const right = @min(w, box.x + box.width + reach);
    const bottom = @min(h, box.y + box.height + reach);
    const sides = [_]image.Area{
        .{ .x = left, .y = box.y, .width = box.x - left, .height = box.height },
        .{ .x = box.x + box.width, .y = box.y, .width = right - box.x - box.width, .height = box.height },
        .{ .x = box.x, .y = top, .width = box.width, .height = box.y - top },
        .{ .x = box.x, .y = box.y + box.height, .width = box.width, .height = bottom - box.y - box.height },
    };
    var lowest: f32 = std.math.inf(f32);
    var highest: f32 = 0;
    for (sides) |side| {
        if (side.width == 0 or side.height == 0) continue;
        const m = meanOver(planes, .background, side, null);
        lowest = @min(lowest, m);
        highest = @max(highest, m);
    }
    return (highest - lowest) / @as(f32, @floatFromInt(@max(peak, 1))) <= flat_sides;
}

/// Scratch for `onItsOwn`.
const Clump = struct {
    taken: std.ArrayList(bool) = .empty,
    stack: std.ArrayList(u32) = .empty,

    fn deinit(clump: *Clump, gpa: std.mem.Allocator) void {
        clump.taken.deinit(gpa);
        clump.stack.deinit(gpa);
    }
};

/// Whether the speck made of `pixels`, in `box`, is a thing of its own rather than the brightest
/// part of something bigger, like a lamp's bulb in its glow. Its clump is everything joined to
/// it that stands at least half as far above the film around it as it does; the clump has to
/// fit as a speck. The film around it is a ring a few specks out.
fn onItsOwn(gpa: std.mem.Allocator, planes: Planes, pixels: []const u32, box: image.Area, sizes: Sizes, clump: *Clump) !bool {
    const w = planes.width;
    const h = planes.height;
    var peak: u32 = 0;
    for (pixels) |at| peak = @max(peak, densityAt(planes, at));
    const film = meanOver(planes, .density, box.grown(clump_ring_out * sizes.near, .whole(w, h)), box.grown(clump_ring_in * sizes.near, .whole(w, h)));
    // A clump that reaches the edge of this window is too big to fit anyway. The picture's own
    // edge doesn't count.
    const window = box.grown(fibre_length * sizes.across(), .whole(w, h));
    try clump.taken.resize(gpa, window.width * window.height);
    @memset(clump.taken.items, false);
    clump.stack.clearRetainingCapacity();
    const Grow = struct {
        planes: Planes,
        window: image.Area,
        level: f32,
        taken: []bool,
        bounds: Bounds = .{},
        count: usize = 0,

        fn local(grow: *const @This(), at: u32) usize {
            const x = at % grow.planes.width;
            const y = at / grow.planes.width;
            return (y - grow.window.y) * grow.window.width + x - grow.window.x;
        }

        fn enter(grow: *@This(), at: u32) bool {
            const i = grow.local(at);
            if (grow.taken[i] or @as(f32, @floatFromInt(densityAt(grow.planes, at))) < grow.level) return false;
            grow.taken[i] = true;
            return true;
        }

        fn reach(grow: *@This(), at: u32) !bool {
            const x = at % grow.planes.width;
            const y = at / grow.planes.width;
            const at_left = x == grow.window.x and grow.window.x > 0;
            const at_top = y == grow.window.y and grow.window.y > 0;
            const at_right = x + 1 == grow.window.x + grow.window.width and x + 1 < grow.planes.width;
            const at_bottom = y + 1 == grow.window.y + grow.window.height and y + 1 < grow.planes.height;
            if (at_left or at_top or at_right or at_bottom) return false;
            grow.bounds.add(x, y);
            grow.count += 1;
            return true;
        }
    };
    var grow: Grow = .{ .planes = planes, .window = window, .level = film + clump_height * (@as(f32, @floatFromInt(peak)) - film), .taken = clump.taken.items };
    // The speck itself is in its clump, however faint its edge.
    for (pixels) |at| {
        const i = grow.local(at);
        if (grow.taken[i]) continue;
        grow.taken[i] = true;
        try clump.stack.append(gpa, at);
    }
    if (!try flood(gpa, &clump.stack, w, h, &grow)) return false;
    return sizes.fits(grow.bounds.toArea(), grow.count);
}

/// The clump's edge, as a share of the way from the film around a speck up to its peak.
const clump_height = 0.5;
/// The ring of film around a speck that its clump is measured against, in specks out from it.
const clump_ring_in = 3;
const clump_ring_out = 4;

fn densityAt(planes: Planes, at: usize) u32 {
    return @as(u32, planes.background[at]) + planes.top_hat[at];
}

/// The mean of the background, or the density, over the pixels of `area` that aren't in
/// `inner`, if it's given.
fn meanOver(planes: Planes, comptime what: enum { background, density }, area: image.Area, inner: ?image.Area) f32 {
    var sum: u64 = 0;
    var count: u64 = 0;
    for (area.y..area.y + area.height) |y| for (area.x..area.x + area.width) |x| {
        if (inner) |in| if (x >= in.x and x < in.x + in.width and y >= in.y and y < in.y + in.height) continue;
        const at = y * planes.width + x;
        sum += switch (what) {
            .background => planes.background[at],
            .density => densityAt(planes, at),
        };
        count += 1;
    };
    return @as(f32, @floatFromInt(sum)) / @as(f32, @floatFromInt(@max(count, 1)));
}

/// Floods out from the pixels on `stack` to their 8 neighbours, as far as `way.enter` lets it,
/// and gives each pixel it reaches to `way.reach`. `enter` marks a pixel as it lets it in, so
/// each is reached once. Returns false, stopping there, as soon as `reach` does.
fn flood(gpa: std.mem.Allocator, stack: *std.ArrayList(u32), width: usize, height: usize, way: anytype) !bool {
    while (stack.pop()) |at| {
        if (!try way.reach(at)) return false;
        var each = neighbours(at, width, height, 1);
        while (each.next()) |next| if (way.enter(next)) try stack.append(gpa, next);
    }
    return true;
}

/// The box around some pixels.
const Bounds = struct {
    min: [2]usize = .{ std.math.maxInt(usize), std.math.maxInt(usize) },
    max: [2]usize = .{ 0, 0 },

    fn add(bounds: *Bounds, x: usize, y: usize) void {
        bounds.min = .{ @min(bounds.min[0], x), @min(bounds.min[1], y) };
        bounds.max = .{ @max(bounds.max[0], x), @max(bounds.max[1], y) };
    }

    fn toArea(bounds: Bounds) image.Area {
        return .{ .x = bounds.min[0], .y = bounds.min[1], .width = bounds.max[0] - bounds.min[0] + 1, .height = bounds.max[1] - bounds.min[1] + 1 };
    }
};

/// The pixels within `radius` of a pixel (its 8 neighbours for 1), as indices, without itself and
/// without going off the image.
const Neighbours = struct {
    centre: [2]usize,
    width: usize,
    x0: usize,
    x1: usize,
    y1: usize,
    x: usize,
    y: usize,

    fn next(it: *Neighbours) ?u32 {
        while (it.y <= it.y1) {
            const x = it.x;
            const y = it.y;
            if (it.x == it.x1) {
                it.x = it.x0;
                it.y += 1;
            } else it.x += 1;
            if (x == it.centre[0] and y == it.centre[1]) continue;
            return @intCast(y * it.width + x);
        }
        return null;
    }
};

fn neighbours(at: u32, width: usize, height: usize, radius: usize) Neighbours {
    const x = at % width;
    const y = at / width;
    const x0 = x -| radius;
    return .{ .centre = .{ x, y }, .width = width, .x0 = x0, .x1 = @min(width - 1, x + radius), .y1 = @min(height - 1, y + radius), .x = x0, .y = y -| radius };
}

/// The weight of a side neighbour, and of a corner one, in the mean a pixel gets in `smooth`.
/// Corners are further away, so they count for less.
const side_weight = 2;
const corner_weight = 1;
/// The ring round a speck that a patch has to match is at least this many pixels wide.
const min_ring = 2;
/// How far away a patch is looked for, in the speck's widths.
const patch_reach = 2;
/// The first look for a patch tries places this many times fewer than the speck is wide apart,
/// then every place around the best of them.
const patch_steps = 4;

/// Fills each speck in `found`, and `edge` pixels round it, the way a healing brush does: with the
/// patch of film nearby whose ring of pixels best matches the ring round the speck, its level
/// evened out to the speck's ring. So the grain, and the picture's own texture such as fur or
/// leaves, carry on through the speck from real film. Where there's no patch to take, at the
/// picture's edge or among other specks, the speck is filled smoothly from its edge inwards.
fn fill(gpa: std.mem.Allocator, scan: image.Scan, planes: Planes, found: Specks, edge: usize) !void {
    const w = scan.width;
    const h = scan.height;
    // Every pixel to fill, so a patch is never taken from another speck.
    const holes = try gpa.alloc(bool, scan.pixels.len);
    defer gpa.free(holes);
    @memset(holes, false);
    for (found.pixels.items) |at| {
        const x = at % w;
        const y = at / w;
        for (y -| edge..@min(h, y + edge + 1)) |hy| {
            @memset(holes[hy * w ..][x -| edge..@min(w, x + edge + 1)], true);
        }
    }
    var shape: std.ArrayList(bool) = .empty;
    defer shape.deinit(gpa);
    var ring: std.ArrayList([2]isize) = .empty;
    defer ring.deinit(gpa);
    var inside: std.ArrayList([2]isize) = .empty;
    defer inside.deinit(gpa);
    for (found.boxes.items) |speck| {
        const box = speck.area.grown(edge, .whole(w, h));
        try shape.resize(gpa, box.width * box.height);
        for (0..box.height) |y| @memcpy(shape.items[y * box.width ..][0..box.width], holes[(box.y + y) * w + box.x ..][0..box.width]);
        // The speck's pixels and the film round it, as places from the box's corner.
        ring.clearRetainingCapacity();
        inside.clearRetainingCapacity();
        const around = box.grown(@max(min_ring, edge + 1), .whole(w, h));
        for (around.y..around.y + around.height) |y| for (around.x..around.x + around.width) |x| {
            const place: [2]isize = .{ @as(isize, @intCast(x)) - @as(isize, @intCast(box.x)), @as(isize, @intCast(y)) - @as(isize, @intCast(box.y)) };
            const in_box = x >= box.x and x < box.x + box.width and y >= box.y and y < box.y + box.height;
            if (!holes[y * w + x]) {
                try ring.append(gpa, place);
            } else if (in_box) try inside.append(gpa, place);
        };
        const patch: Patch = .{ .planes = planes, .holes = holes, .box = box, .ring = ring.items, .inside = inside.items };
        if (patch.best()) |offset| {
            patch.copy(scan, offset);
        } else try smooth(gpa, scan, box, shape.items);
    }
}

/// Looking for a patch of film to fill a speck with, by how well the ring round it matches the
/// speck's ring in density, after taking away any difference in their mean.
const Patch = struct {
    planes: Planes,
    holes: []const bool,
    /// The speck and its edge, and the pixels in it to fill and the ring of film round them, as
    /// places from `box`'s corner.
    box: image.Area,
    inside: []const [2]isize,
    ring: []const [2]isize,

    const Match = struct { offset: [2]isize, cost: f64 };

    /// The offset from the speck to the best patch, or null when no patch is clear of the specks
    /// and on the picture.
    fn best(patch: Patch) ?[2]isize {
        const widest = @max(patch.box.width, patch.box.height);
        const reach: isize = @intCast(patch_reach * widest + min_ring);
        const step: isize = @intCast(@max(1, widest / patch_steps));
        var found: ?Match = null;
        patch.search(.{ 0, 0 }, reach, step, &found);
        const coarse = found orelse return null;
        patch.search(coarse.offset, step - 1, 1, &found);
        return found.?.offset;
    }

    /// Considers the offsets within `reach` of `centre`, `step` apart.
    fn search(patch: Patch, centre: [2]isize, reach: isize, step: isize, found: *?Match) void {
        var dy = -reach;
        while (dy <= reach) : (dy += step) {
            var dx = -reach;
            while (dx <= reach) : (dx += step) patch.consider(.{ centre[0] + dx, centre[1] + dy }, found);
        }
    }

    /// Weighs up the patch at `offset` from the speck, and keeps it in `found` if it's the best so
    /// far.
    fn consider(patch: Patch, offset: [2]isize, found: *?Match) void {
        var sum: f64 = 0;
        var squares: f64 = 0;
        for (patch.ring) |place| {
            const to = patch.at(place, offset) orelse return;
            if (patch.holes[to]) return;
            const d = @as(f64, @floatFromInt(densityAt(patch.planes, patch.at(place, .{ 0, 0 }).?))) - @as(f64, @floatFromInt(densityAt(patch.planes, to)));
            sum += d;
            squares += d * d;
        }
        for (patch.inside) |place| {
            const to = patch.at(place, offset) orelse return;
            if (patch.holes[to]) return;
        }
        const n: f64 = @floatFromInt(@max(patch.ring.len, 1));
        const cost = squares - sum * sum / n;
        if (found.* == null or cost < found.*.?.cost) found.* = .{ .offset = offset, .cost = cost };
    }

    /// The pixel at `place` from the box's corner, moved by `offset`, or null off the picture.
    fn at(patch: Patch, place: [2]isize, offset: [2]isize) ?usize {
        const x = @as(isize, @intCast(patch.box.x)) + place[0] + offset[0];
        const y = @as(isize, @intCast(patch.box.y)) + place[1] + offset[1];
        if (x < 0 or y < 0 or x >= patch.planes.width or y >= patch.planes.height) return null;
        return @as(usize, @intCast(y)) * patch.planes.width + @as(usize, @intCast(x));
    }

    /// Copies the patch at `offset` into the speck. Each channel's density is evened out to the
    /// speck's ring with the plane through the difference between the two rings, so a patch a
    /// little lighter, or lighter on one side, fits in.
    fn copy(patch: Patch, scan: image.Scan, offset: [2]isize) void {
        var sums: [image.channel_count]PlaneSums = @splat(.{});
        for (patch.ring) |place| {
            const here = densitiesOf(scan.pixels[patch.at(place, .{ 0, 0 }).?]);
            const there = densitiesOf(scan.pixels[patch.at(place, offset).?]);
            for (&sums, here, there) |*sum, a, b| sum.add(place, a - b);
        }
        var difference: [image.channel_count]PlaneSums.Fitted = undefined;
        for (&difference, sums) |*d, sum| d.* = sum.fit();
        for (patch.inside) |place| {
            const from = scan.pixels[patch.at(place, offset).?];
            for (&scan.pixels[patch.at(place, .{ 0, 0 }).?], from, difference) |*v, f, d| {
                const gain = std.math.pow(f32, 10, -d.at(place));
                v.* = @intFromFloat(@round(@min(@as(f32, @floatFromInt(f)) * gain, image.full_scale)));
            }
        }
    }
};

/// Sums for the plane `a + b·x + c·y` through some values by least squares.
const PlaneSums = struct {
    n: f64 = 0,
    x: f64 = 0,
    y: f64 = 0,
    xx: f64 = 0,
    xy: f64 = 0,
    yy: f64 = 0,
    v: f64 = 0,
    xv: f64 = 0,
    yv: f64 = 0,

    const Fitted = struct {
        a: f32,
        b: f32,
        c: f32,

        fn at(plane: Fitted, place: [2]isize) f32 {
            return plane.a + plane.b * @as(f32, @floatFromInt(place[0])) + plane.c * @as(f32, @floatFromInt(place[1]));
        }
    };

    /// Below this, the places are as good as in a line, and only their mean counts.
    const flat = 1e-6;

    fn add(sums: *PlaneSums, place: [2]isize, value: f32) void {
        const x: f64 = @floatFromInt(place[0]);
        const y: f64 = @floatFromInt(place[1]);
        const v: f64 = value;
        sums.n += 1;
        sums.x += x;
        sums.y += y;
        sums.xx += x * x;
        sums.xy += x * y;
        sums.yy += y * y;
        sums.v += v;
        sums.xv += x * v;
        sums.yv += y * v;
    }

    fn fit(sums: PlaneSums) Fitted {
        if (sums.n == 0) return .{ .a = 0, .b = 0, .c = 0 };
        // Centred on the places' mean, the slopes come from a 2 × 2 system.
        const mx = sums.x / sums.n;
        const my = sums.y / sums.n;
        const mv = sums.v / sums.n;
        const cxx = sums.xx - sums.x * mx;
        const cxy = sums.xy - sums.x * my;
        const cyy = sums.yy - sums.y * my;
        const cxv = sums.xv - sums.x * mv;
        const cyv = sums.yv - sums.y * mv;
        const det = cxx * cyy - cxy * cxy;
        const b = if (det > flat) (cyy * cxv - cxy * cyv) / det else 0;
        const c = if (det > flat) (cxx * cyv - cxy * cxv) / det else 0;
        return .{ .a = @floatCast(mv - b * mx - c * my), .b = @floatCast(b), .c = @floatCast(c) };
    }
};

/// Each channel's density, −log10 of its transmission.
fn densitiesOf(p: [image.channel_count]u16) [image.channel_count]f32 {
    var d: [image.channel_count]f32 = undefined;
    for (&d, p) |*out, v| out.* = -std.math.log10(@as(f32, @floatFromInt(@max(v, 1))) / image.full_scale);
    return d;
}

/// Fills the pixels `holes` marks in `box` of `scan`, from the edge inwards: each pass gives the
/// pixels next to the filled part the weighted mean of their filled neighbours. `holes` is
/// `box`'s size, and is cleared as it goes.
fn smooth(gpa: std.mem.Allocator, scan: image.Scan, box: image.Area, holes: []bool) !void {
    var ring: std.ArrayList(struct { at: usize, value: [image.channel_count]u16 }) = .empty;
    defer ring.deinit(gpa);
    var left = std.mem.count(bool, holes, &.{true});
    while (left > 0) {
        ring.clearRetainingCapacity();
        for (0..box.height) |y| for (0..box.width) |x| {
            if (!holes[y * box.width + x]) continue;
            var sum: [image.channel_count]u32 = @splat(0);
            var weights: u32 = 0;
            const at: u32 = @intCast((box.y + y) * scan.width + box.x + x);
            var each = neighbours(at, scan.width, scan.height, 1);
            while (each.next()) |next| {
                const nx = next % scan.width;
                const ny = next / scan.width;
                const inside = nx >= box.x and nx < box.x + box.width and ny >= box.y and ny < box.y + box.height;
                if (inside and holes[(ny - box.y) * box.width + nx - box.x]) continue;
                const weight: u32 = if (nx == box.x + x or ny == box.y + y) side_weight else corner_weight;
                for (&sum, scan.pixels[next]) |*s, v| s.* += weight * v;
                weights += weight;
            }
            if (weights == 0) continue;
            var value: [image.channel_count]u16 = undefined;
            for (&value, sum) |*v, s| v.* = @intCast((s + weights / 2) / weights);
            try ring.append(gpa, .{ .at = at, .value = value });
        };
        // A box with nothing filled round it would never finish; that can't happen on a picture
        // bigger than a speck, but stop rather than loop.
        if (ring.items.len == 0) break;
        for (ring.items) |r| {
            scan.pixels[r.at] = r.value;
            holes[(r.at / scan.width - box.y) * box.width + r.at % scan.width - box.x] = false;
        }
        left -= ring.items.len;
    }
}

/// How rough the film is in `area` of `scan`, for the tests, leaving out the pixels `holes` marks: the mean
/// difference in density between pixels side by side and one above the other. Null when there's
/// no pair to measure, or the film is perfectly smooth.
fn roughness(scan: image.Scan, holes: []const bool, area: image.Area) ?f32 {
    var sum: f32 = 0;
    var pairs: usize = 0;
    for (area.y..area.y + area.height) |y| for (area.x..area.x + area.width) |x| {
        const at = y * scan.width + x;
        if (holes[at]) continue;
        for ([_]?usize{ if (x + 1 < area.x + area.width) at + 1 else null, if (y + 1 < area.y + area.height) at + scan.width else null }) |other| {
            const next = other orelse continue;
            if (holes[next]) continue;
            sum += @abs(meanDensity(scan.pixels[at]) - meanDensity(scan.pixels[next]));
            pairs += 1;
        }
    };
    if (pairs == 0 or sum == 0) return null;
    return sum / @as(f32, @floatFromInt(pairs));
}

fn meanDensity(p: [image.channel_count]u16) f32 {
    var sum: f32 = 0;
    for (densitiesOf(p)) |d| sum += d;
    return sum / image.channel_count;
}

/// A filled speck's grain should be at most this many times as rough as the film's round it, or
/// as smooth.
const grain_match = 1.5;

/// Grain for a test scan: noise of `density` D, in clumps that reach `clump` pixels.
const TestGrain = struct { density: f32, clump: usize = 0 };
/// Fine grain, and coarse grain like a fast B&W film's.
const fine_grain: TestGrain = .{ .density = 0.006 };
const coarse_grain: TestGrain = .{ .density = 0.08, .clump = 2 };

/// A test scan: thin film with a gentle slope across it and `grain` on top.
fn testFilm(gpa: std.mem.Allocator, width: usize, height: usize, grain: TestGrain) !image.Scan {
    const noise = try gpa.alloc(f32, width * height);
    defer gpa.free(noise);
    var random: std.Random.DefaultPrng = .init(0x5eed);
    for (noise) |*v| v.* = random.random().floatNorm(f32);
    // Clump it: the mean over the square reaching `clump`, across then down.
    const line = try gpa.alloc(f32, @max(width, height));
    defer gpa.free(line);
    for (0..2) |pass| {
        const lines, const length, const stride, const step = if (pass == 0) .{ height, width, width, 1 } else .{ width, height, 1, width };
        for (0..lines) |l| {
            for (0..length) |i| {
                var sum: f32 = 0;
                for (i -| grain.clump..@min(length, i + grain.clump + 1)) |j| sum += noise[l * stride + j * step];
                line[i] = sum;
            }
            for (0..length) |i| noise[l * stride + i * step] = line[i];
        }
    }
    var spread: f32 = 0;
    for (noise) |v| spread += v * v;
    spread = @sqrt(spread / @as(f32, @floatFromInt(noise.len)));
    const scan: image.Scan = try .init(gpa, width, height);
    for (scan.pixels, noise, 0..) |*p, n, i| {
        const x: f32 = @floatFromInt(i % width);
        const d = 0.5 + 0.3 * x / @as(f32, @floatFromInt(width)) + grain.density * n / spread;
        for (p, [_]f32{ 0.8, 0.5, 0.3 }) |*v, base| v.* = @intFromFloat(base * std.math.pow(f32, 10, -d) * image.full_scale);
    }
    return scan;
}

/// Adds `density` D to the disc of `radius` around (`cx`, `cy`). Negative makes it lighter.
fn addDisc(scan: image.Scan, cx: usize, cy: usize, radius: usize, density: f32) void {
    const r: isize = @intCast(radius);
    var dy: isize = -r;
    while (dy <= r) : (dy += 1) {
        var dx: isize = -r;
        while (dx <= r) : (dx += 1) {
            if (dx * dx + dy * dy > r * r) continue;
            const x: usize = @intCast(@as(isize, @intCast(cx)) + dx);
            const y: usize = @intCast(@as(isize, @intCast(cy)) + dy);
            for (&scan.pixels[y * scan.width + x]) |*v| v.* = @intFromFloat(@min(image.full_scale, @as(f32, @floatFromInt(v.*)) * std.math.pow(f32, 10, -density)));
        }
    }
}

/// The mean density of the square reaching `radius` from (`cx`, `cy`).
fn densityAround(scan: image.Scan, cx: usize, cy: usize, radius: usize) f32 {
    var sum: f32 = 0;
    for (cy - radius..cy + radius + 1) |y| {
        for (scan.row(y)[cx - radius .. cx + radius + 1]) |p| sum += meanDensity(p);
    }
    const side: f32 = @floatFromInt(2 * radius + 1);
    return sum / (side * side);
}

const test_speck = 0.5;
/// Dust removal on, with specks up to the size the steps are tuned for, which the tests' specks
/// are drawn to.
const on: Settings = .{ .remove = true, .max_size = tuned_size };

test "specks on grainy film are filled in, and nothing else changes" {
    const gpa = std.testing.allocator;
    var scan = try testFilm(gpa, 800, 600, fine_grain);
    defer scan.deinit(gpa);
    const before = try gpa.dupe([image.channel_count]u16, scan.pixels);
    defer gpa.free(before);
    const specks = [_][3]usize{ .{ 100, 100, 1 }, .{ 300, 450, 2 }, .{ 650, 200, 3 }, .{ 500, 520, 0 } };
    for (specks) |s| addDisc(scan, s[0], s[1], s[2], test_speck);
    var dusty = try scan.crop(gpa, .whole(scan.width, scan.height));
    defer dusty.deinit(gpa);

    try std.testing.expectEqual(specks.len, try remove(gpa, scan, on, .dense, scan.width));
    const film: image.Scan = .{ .width = scan.width, .height = scan.height, .pixels = before };
    for (specks) |s| {
        // The speck's place is back to about the film around it.
        try std.testing.expect(densityAround(dusty, s[0], s[1], 0) - densityAround(film, s[0], s[1], 0) > test_speck - 0.05);
        try std.testing.expectApproxEqAbs(densityAround(film, s[0], s[1], s[2] + 1), densityAround(scan, s[0], s[1], s[2] + 1), 3 * fine_grain.density);
    }
    // Away from the specks, every pixel is as it was.
    const sizes: Sizes = .of(scan.width, tuned_size);
    for (scan.pixels, dusty.pixels, 0..) |after, was, i| {
        const x = i % scan.width;
        const y = i / scan.width;
        var near = false;
        for (specks) |s| near = near or (@max(x, s[0]) - @min(x, s[0]) <= s[2] + sizes.edge + 2 and @max(y, s[1]) - @min(y, s[1]) <= s[2] + sizes.edge + 2);
        if (!near) try std.testing.expectEqual(was, after);
    }
}

test "spots too big for dust, texture, lines and edges are the picture" {
    const gpa = std.testing.allocator;
    var scan = try testFilm(gpa, 800, 600, fine_grain);
    defer scan.deinit(gpa);
    // A spot five times the largest speck.
    addDisc(scan, 150, 150, 5 * Sizes.of(scan.width, tuned_size).speck, test_speck);
    // Texture: specks close together all over a patch.
    var y: usize = 300;
    while (y < 380) : (y += 5) {
        var x: usize = 100;
        while (x < 180) : (x += 5) addDisc(scan, x, y, 1, test_speck);
    }
    // A thin line across most of the picture, like a hair in the scene.
    for (50..750) |x| addDisc(scan, x, 500, 0, test_speck);
    // A speck on the edge of something much denser.
    for (0..scan.height) |row| {
        for (scan.row(row)[600..]) |*p| {
            for (p) |*v| v.* /= 10;
        }
    }
    addDisc(scan, 598, 200, 1, test_speck);
    const before = try gpa.dupe([image.channel_count]u16, scan.pixels);
    defer gpa.free(before);
    try std.testing.expectEqual(@as(usize, 0), try remove(gpa, scan, on, .dense, scan.width));
    try std.testing.expectEqualSlices([image.channel_count]u16, before, scan.pixels);
}

test "a thin fibre comes out, and a thick one is the picture" {
    const gpa = std.testing.allocator;
    for ([_]usize{ 0, 2 }) |radius| {
        var scan = try testFilm(gpa, 1600, 1200, fine_grain);
        defer scan.deinit(gpa);
        // Half as long again as the largest speck is wide.
        const length = Sizes.of(scan.width, tuned_size).across() * 3 / 2;
        for (0..length) |i| addDisc(scan, 600 + i, 600 + i / 4, radius, test_speck);
        try std.testing.expectEqual(@as(usize, if (radius == 0) 1 else 0), try remove(gpa, scan, on, .dense, scan.width));
    }
}

test "the same specks go at any resolution" {
    const gpa = std.testing.allocator;
    var counts: [2]usize = undefined;
    for (&counts, [_]usize{ 1, 2 }) |*count, times| {
        var scan = try testFilm(gpa, 600 * times, 400 * times, fine_grain);
        defer scan.deinit(gpa);
        for ([_][2]usize{ .{ 100, 100 }, .{ 450, 120 }, .{ 300, 300 } }) |at| addDisc(scan, at[0] * times, at[1] * times, times, test_speck);
        count.* = try remove(gpa, scan, on, .dense, scan.width);
    }
    try std.testing.expectEqual(@as(usize, 3), counts[0]);
    try std.testing.expectEqual(counts[0], counts[1]);
}

test "a finished picture loses light specks, and raw film keeps them" {
    const gpa = std.testing.allocator;
    for ([_]Polarity{ .light, .dense }) |polarity| {
        var scan = try testFilm(gpa, 800, 600, fine_grain);
        defer scan.deinit(gpa);
        addDisc(scan, 200, 200, 2, -test_speck);
        addDisc(scan, 500, 400, 2, -test_speck);
        const found = try remove(gpa, scan, on, polarity, scan.width);
        try std.testing.expectEqual(@as(usize, if (polarity == .light) 2 else 0), found);
    }
}

test "dust left alone gives no copy, and so does a frame too small for dust" {
    const gpa = std.testing.allocator;
    var scan = try testFilm(gpa, 300, 200, fine_grain);
    defer scan.deinit(gpa);
    try std.testing.expectEqual(null, try cleaned(gpa, scan, .{}, .dense, min_frame));
    try std.testing.expectEqual(null, try cleaned(gpa, scan, .{ .remove = true }, .dense, min_frame - 1));
    var copy = (try cleaned(gpa, scan, .{ .remove = true }, .dense, min_frame)).?;
    defer copy.deinit(gpa);
    try std.testing.expectEqual(scan.width, copy.width);
}

test "part of a frame, cut with the margin, loses the same specks as the whole frame" {
    const gpa = std.testing.allocator;
    var scan = try testFilm(gpa, 800, 600, fine_grain);
    defer scan.deinit(gpa);
    for ([_][2]usize{ .{ 380, 290 }, .{ 420, 330 }, .{ 120, 80 } }) |at| addDisc(scan, at[0], at[1], 2, test_speck);
    const part: image.Area = .{ .x = 350, .y = 260, .width = 100, .height = 100 };
    const reach = margin(scan.width, on);
    const around: image.Area = .{ .x = part.x - reach, .y = part.y - reach, .width = part.width + 2 * reach, .height = part.height + 2 * reach };
    var piece = try scan.crop(gpa, around);
    defer piece.deinit(gpa);
    _ = try remove(gpa, scan, on, .dense, scan.width);
    _ = try remove(gpa, piece, on, .dense, scan.width);
    for (0..part.height) |y| {
        try std.testing.expectEqualSlices([image.channel_count]u16, scan.row(part.y + y)[part.x..][0..part.width], piece.row(reach + y)[reach..][0..part.width]);
    }
}

test "the running minimum and maximum match the plain ones" {
    const gpa = std.testing.allocator;
    var random: std.Random.DefaultPrng = .init(7);
    const width = 23;
    const height = 9;
    for ([_]usize{ 0, 1, 3, 12 }) |radius| {
        var values: [width * height]Code = undefined;
        for (&values) |*v| v.* = random.random().int(Code);
        const original = values;
        try filter(Code, .min, gpa, &values, width, height, radius);
        for (0..height) |y| for (0..width) |x| {
            var lowest: Code = max_code;
            for (y -| radius..@min(height, y + radius + 1)) |wy| {
                for (x -| radius..@min(width, x + radius + 1)) |wx| lowest = @min(lowest, original[wy * width + wx]);
            }
            try std.testing.expectEqual(lowest, values[y * width + x]);
        };
    }
}

test "grain alone is left alone, fine or coarse" {
    const gpa = std.testing.allocator;
    for ([_]TestGrain{ fine_grain, coarse_grain }) |grain| {
        var scan = try testFilm(gpa, 1200, 800, grain);
        defer scan.deinit(gpa);
        const before = try gpa.dupe([image.channel_count]u16, scan.pixels);
        defer gpa.free(before);
        try std.testing.expectEqual(@as(usize, 0), try remove(gpa, scan, on, .dense, scan.width));
        try std.testing.expectEqualSlices([image.channel_count]u16, before, scan.pixels);
    }
}

test "a filled speck keeps the film's grain" {
    const gpa = std.testing.allocator;
    for ([_]TestGrain{ fine_grain, coarse_grain }) |grain| {
        var scan = try testFilm(gpa, 800, 600, grain);
        defer scan.deinit(gpa);
        addDisc(scan, 400, 300, 3, 4 * test_speck);
        try std.testing.expectEqual(@as(usize, 1), try remove(gpa, scan, on, .dense, scan.width));
        // The speck's place is as rough as the film around it, not smooth.
        const holes = try gpa.alloc(bool, scan.pixels.len);
        defer gpa.free(holes);
        @memset(holes, false);
        const speck: image.Area = .{ .x = 397, .y = 297, .width = 7, .height = 7 };
        for (speck.y..speck.y + speck.height) |y| @memset(holes[y * scan.width + speck.x ..][0..speck.width], true);
        const around = roughness(scan, holes, speck.grown(2 * speck.width, .whole(scan.width, scan.height))).?;
        @memset(holes, false);
        const ratio = roughness(scan, holes, speck).? / around;
        try std.testing.expect(ratio * grain_match > 1 and ratio < grain_match);
    }
}

test "a smaller max size and a lower max density only ever leave more alone" {
    const gpa = std.testing.allocator;
    var film = try testFilm(gpa, 1200, 800, fine_grain);
    defer film.deinit(gpa);
    // Specks from one pixel to nearly the widest, faint and dense.
    const widest = Sizes.of(film.width, tuned_size).widest;
    for (0..widest / 2, 0..) |radius, i| {
        addDisc(film, 100 + 150 * i, 200, radius, test_speck);
        addDisc(film, 100 + 150 * i, 500, radius, 3 * test_speck);
    }
    var last: usize = std.math.maxInt(usize);
    for ([_]f32{ Settings.max_max_size, tuned_size, Settings.default_max_size, 0.3, Settings.min_max_size }) |size| {
        var scan = try film.crop(gpa, .whole(film.width, film.height));
        defer scan.deinit(gpa);
        const found = try remove(gpa, scan, .{ .remove = true, .max_size = size }, .dense, scan.width);
        try std.testing.expect(found <= last);
        last = found;
    }
    try std.testing.expect(last > 0);
    // The dense specks stand 1.5 D above the film; a limit under that keeps them.
    var scan = try film.crop(gpa, .whole(film.width, film.height));
    defer scan.deinit(gpa);
    var all = try film.crop(gpa, .whole(film.width, film.height));
    defer all.deinit(gpa);
    const everything = try remove(gpa, all, on, .dense, scan.width);
    try std.testing.expectEqual(everything / 2, try remove(gpa, scan, .{ .remove = true, .max_size = tuned_size, .max_density = 1 }, .dense, scan.width));
}

test "a bulb in a lamp's glow is the picture" {
    const gpa = std.testing.allocator;
    var scan = try testFilm(gpa, 800, 600, fine_grain);
    defer scan.deinit(gpa);
    // A soft glow, wider than the largest speck, and the bulb at its heart.
    const glow = 3 * Sizes.of(scan.width, tuned_size).speck;
    for (0..2 * glow + 1) |dy| for (0..2 * glow + 1) |dx| {
        const r2: f32 = @floatFromInt((dx -| glow) * (dx -| glow) + (glow -| dx) * (glow -| dx) + (dy -| glow) * (dy -| glow) + (glow -| dy) * (glow -| dy));
        const d = 2 * test_speck * @exp(-r2 / @as(f32, @floatFromInt(glow * glow)));
        addDisc(scan, 400 - glow + dx, 300 - glow + dy, 0, d);
    };
    addDisc(scan, 400, 300, 1, 2 * test_speck);
    try std.testing.expectEqual(@as(usize, 0), try remove(gpa, scan, on, .dense, scan.width));
}

test "a speck in texture is filled with the texture round it" {
    const gpa = std.testing.allocator;
    // Fine stripes across the film, like fur, with grain on top.
    var scan = try testFilm(gpa, 600, 400, fine_grain);
    defer scan.deinit(gpa);
    const period = 8;
    const stripes = 0.15;
    for (scan.pixels, 0..) |*p, i| {
        const phase = @as(f32, @floatFromInt((i % scan.width + i / scan.width) % period)) / period;
        const d = stripes * @sin(2 * std.math.pi * phase);
        for (p) |*v| v.* = @intFromFloat(@as(f32, @floatFromInt(v.*)) * std.math.pow(f32, 10, -d));
    }
    var film = try scan.crop(gpa, .whole(scan.width, scan.height));
    defer film.deinit(gpa);
    // Fill a speck's place, without any dust on it, and see how close it comes to the stripes.
    const speck: image.Area = .{ .x = 300, .y = 200, .width = 5, .height = 5 };
    var found: Specks = .{};
    defer found.deinit(gpa);
    for (speck.y..speck.y + speck.height) |y| for (speck.x..speck.x + speck.width) |x| {
        try found.pixels.append(gpa, @intCast(y * scan.width + x));
    };
    try found.boxes.append(gpa, .{ .start = 0, .end = @intCast(found.pixels.items.len), .area = speck });
    const density = try gpa.alloc(Code, scan.pixels.len);
    defer gpa.free(density);
    try densities(gpa, scan.pixels, .dense, density);
    const flat = try gpa.alloc(Code, scan.pixels.len);
    defer gpa.free(flat);
    @memset(flat, 0);
    const planes: Planes = .{ .marks = &.{}, .top_hat = flat, .background = density, .width = scan.width, .height = scan.height };
    try fill(gpa, scan, planes, found, 1);
    var squares: f32 = 0;
    for (found.pixels.items) |at| {
        const d = meanDensity(scan.pixels[at]) - meanDensity(film.pixels[at]);
        squares += d * d;
    }
    // A flat fill would be off by the stripes' spread, about 0.1 D; the stripes' own patch is
    // off by little more than the grain.
    try std.testing.expect(@sqrt(squares / @as(f32, @floatFromInt(found.pixels.items.len))) < 3 * fine_grain.density);
}
