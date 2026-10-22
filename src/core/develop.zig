//! The neutral look: from a scan's transmission to a positive, in density.
//!
//! 1. Density above the film base, per channel: d = log10(T / T_base), 0 at the base and negative
//!    for denser film.
//! 2. A 3×3 matrix in density, for channel crosstalk.
//! 3. The inversion curve: density scaled by the density range and balanced per channel, then
//!    y = max(exposure · (1 + black − 10^c), 0)^contrast, with a soft roll-off of the highlights.
//! 4. The tone: the curve as it is, softer or harder, or a flat linear or log image for grading.
//!
//! The model and its default values are darktable's negative inversion, written here from its
//! published equations; no darktable code is used. Output is linear, 0..1.
//!
//! The balance has two layers: the automatic per-channel balance of highlights and shadows, which
//! the white balance mode sets, and the user's temperature and tint per tonal range on top.

const std = @import("std");
const image = @import("image.zig");
const encode = @import("encode.zig");

pub const FilmKind = enum {
    colour_negative,
    bw_negative,
    colour_positive,
    bw_positive,

    pub fn isNegative(kind: FilmKind) bool {
        return switch (kind) {
            .colour_negative, .bw_negative => true,
            .colour_positive, .bw_positive => false,
        };
    }

    pub fn isMonochrome(kind: FilmKind) bool {
        return switch (kind) {
            .bw_negative, .bw_positive => true,
            .colour_negative, .colour_positive => false,
        };
    }
};

/// Transmission below this counts as this, about −32 EV.
const smallest_transmission = 2.3283064365386963e-10;

pub const Matrix = [3][3]f32;
pub const identity: Matrix = .{ .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 } };

/// How the curve is shaped after the inversion.
pub const Tone = enum {
    standard,
    soft,
    hard,
    /// No contrast curve and no roll-off: linear in the film's exposure, for grading elsewhere.
    linear,
    /// Density above the curve's start, 0..1, stored as is in the file: for grading elsewhere.
    log,

    pub fn label(tone: Tone) []const u8 {
        return switch (tone) {
            .standard => "Standard",
            .soft => "Soft",
            .hard => "Hard",
            .linear => "Linear",
            .log => "Log",
        };
    }
};

/// Contrast of the soft and hard tones relative to the standard one.
const soft_contrast = 0.8;
const hard_contrast = 1.25;

/// Where the automatic balance comes from.
pub const WhiteBalance = enum {
    /// Highlights and shadows neutral.
    auto_neutral,
    /// Neutral, then a little warmer.
    auto_warm,
    /// Neutral, then a little cooler.
    auto_cool,
    /// The frame's average neutral.
    average,
    /// The stock preset's balance.
    stock,
    /// A point the user picked made neutral.
    picked,

    pub fn label(balance: WhiteBalance) []const u8 {
        return switch (balance) {
            .auto_neutral => "Auto neutral",
            .auto_warm => "Auto warm",
            .auto_cool => "Auto cool",
            .average => "Average",
            .stock => "Stock",
            .picked => "Picked",
        };
    }
};

/// How much warmer or cooler the warm and cool balances are, as temperature.
const warmth = 25;

/// The tonal ranges temperature and tint apply to.
pub const Range = enum {
    highlights,
    midtones,
    shadows,

    pub fn label(range: Range) []const u8 {
        return switch (range) {
            .highlights => "Highlights",
            .midtones => "Midtones",
            .shadows => "Shadows",
        };
    }
};

/// Where the film base comes from.
pub const BaseSource = enum {
    /// The thinnest film in the frame.
    measured,
    /// The clear film in the gaps beside the frame, found by frame detection.
    gaps,
    /// A point the user picked, in the rebate or between frames.
    picked,
};

pub const Settings = struct {
    kind: FilmKind = .colour_negative,
    /// Film-base transmission per channel, as a fraction of full scale.
    base: [3]f32 = @splat(1),
    base_source: BaseSource = .measured,
    /// For B&W, the channel whose density is used.
    monochrome_channel: image.Channel = .g,
    matrix: Matrix = identity,
    /// The density range the curve spans, in D.
    density_range: f32 = 1.6,
    /// Where the curve starts, as a fraction of the density range.
    offset: f32 = -0.05,
    black: f32 = 0.0755,
    contrast: f32 = 4.0,
    /// Above this the highlights roll off instead of clipping, 0..1.
    roll_off: f32 = 0.75,
    exposure: f32 = 0.9245,
    /// Per-channel balance of the highlights (slope) and the shadows (offset), set by the white
    /// balance mode.
    highlight_balance: [3]f32 = @splat(1),
    shadow_balance: [3]f32 = @splat(1),
    white_balance: WhiteBalance = .auto_neutral,
    /// The user's temperature and tint per range, −100..100, on top of the balance. Positive
    /// temperature is warmer, positive tint more magenta.
    temperature: [3]f32 = @splat(0),
    tint: [3]f32 = @splat(0),
    tone: Tone = .standard,
    /// Colour after the look, 0..2: 0 grey, 1 as it is. Applied by `saturate`.
    saturation: f32 = 1,
};

/// Per-channel gains for `temperature` and `tint` (−100..100): ±100 is half a stop on red and
/// blue for temperature, and on green for tint.
pub fn gains(temperature: f32, tint: f32) [3]f32 {
    const t = temperature / 200;
    const m = tint / 200;
    return .{ std.math.exp2(t + m / 2), std.math.exp2(-m), std.math.exp2(-t + m / 2) };
}

/// How strongly midtone gains bend each channel's curve.
const midtone_strength = 0.5;

/// Values that depend only on the settings, worked out once per render.
pub const Prepared = struct {
    settings: Settings,
    slope: [3]f32,
    shift: [3]f32,
    contrast: [3]f32,
    roll_off: f32,
    lift: f32,
    /// 1 for B&W, which has no colour to change.
    saturation: f32,

    pub fn init(settings: Settings) Prepared {
        var prepared: Prepared = .{
            .settings = settings,
            .slope = undefined,
            .shift = undefined,
            .contrast = undefined,
            .roll_off = if (settings.tone == .linear) 1 else settings.roll_off,
            .lift = -settings.exposure * (1 + settings.black),
            .saturation = if (settings.kind.isMonochrome()) 1 else settings.saturation,
        };
        const contrast: f32 = switch (settings.tone) {
            .standard, .log => settings.contrast,
            .soft => settings.contrast * soft_contrast,
            .hard => settings.contrast * hard_contrast,
            .linear => 1,
        };
        const highlights = gains(settings.temperature[@backingInt(Range.highlights)], settings.tint[@backingInt(Range.highlights)]);
        const midtones = gains(settings.temperature[@backingInt(Range.midtones)], settings.tint[@backingInt(Range.midtones)]);
        const shadows = gains(settings.temperature[@backingInt(Range.shadows)], settings.tint[@backingInt(Range.shadows)]);
        for (0..3) |i| {
            const high = settings.highlight_balance[i] * highlights[i];
            const low = settings.shadow_balance[i] / shadows[i];
            prepared.slope[i] = high / settings.density_range;
            prepared.shift[i] = high * settings.offset * low;
            prepared.contrast[i] = contrast * std.math.pow(f32, midtones[i], -midtone_strength);
        }
        return prepared;
    }
};

fn density(prepared: Prepared, transmission: [3]f32) [3]f32 {
    const s = prepared.settings;
    var d: [3]f32 = undefined;
    for (&d, transmission, s.base) |*out, t, base| out.* = std.math.log10(@max(t, smallest_transmission) / @max(base, smallest_transmission));
    if (s.kind.isMonochrome()) d = @splat(d[@backingInt(s.monochrome_channel)]);
    var mixed: [3]f32 = undefined;
    for (&mixed, s.matrix) |*out, row| out.* = row[0] * d[0] + row[1] * d[1] + row[2] * d[2];
    return mixed;
}

fn invert(prepared: Prepared, d: [3]f32) [3]f32 {
    const s = prepared.settings;
    const roll_off = prepared.roll_off;
    var y: [3]f32 = undefined;
    for (&y, d, prepared.slope, prepared.shift, prepared.contrast) |*out, v, slope, shift, contrast| {
        const c = slope * v + shift;
        if (s.tone == .log) {
            // The file holds the density itself; undo the encoding's curve in advance.
            out.* = encode.linearFromSrgb(std.math.clamp(-c, 0, 1));
            continue;
        }
        const linear = @max(-(s.exposure * std.math.pow(f32, 10, c) + prepared.lift), 0);
        const curved = std.math.pow(f32, linear, contrast);
        out.* = if (curved > roll_off and roll_off < 1)
            roll_off + (1 - @exp(-(curved - roll_off) / (1 - roll_off))) * (1 - roll_off)
        else
            curved;
    }
    return y;
}

/// Rec. 709's luminance weights, for linear sRGB.
const luminance_weights = [3]f32{ 0.2126, 0.7152, 0.0722 };

/// Changes the saturation of linear `pixels` in place: each is mixed with its own luminance in
/// linear light, which keeps its hue and its luminance. Colours pushed past what sRGB holds are
/// cut at 0.
pub fn saturate(prepared: Prepared, pixels: [][3]f32) void {
    const s = prepared.saturation;
    if (s == 1) return;
    for (pixels) |*p| {
        const y = luminance_weights[0] * p[0] + luminance_weights[1] * p[1] + luminance_weights[2] * p[2];
        for (p) |*v| v.* = @max(0, y + s * (v.* - y));
    }
}

/// One pixel: 16-bit linear transmission to linear output, 0..1.
pub fn pixel(prepared: Prepared, raw: [3]u16) [3]f32 {
    var t: [3]f32 = undefined;
    for (&t, raw) |*out, v| out.* = @as(f32, @floatFromInt(v)) / image.full_scale;
    if (!prepared.settings.kind.isNegative()) {
        if (prepared.settings.kind.isMonochrome()) t = @splat(t[@backingInt(prepared.settings.monochrome_channel)]);
        for (&t) |*v| v.* = std.math.clamp(v.* * prepared.settings.exposure, 0, 1);
        return t;
    }
    return invert(prepared, density(prepared, t));
}

/// The whole scan.
pub fn render(gpa: std.mem.Allocator, scan: image.Scan, settings: Settings) !image.Rendered {
    const rendered: image.Rendered = try .init(gpa, scan.width, scan.height);
    const prepared: Prepared = .init(settings);
    for (rendered.pixels, scan.pixels) |*out, raw| out.* = pixel(prepared, raw);
    return rendered;
}

/// The smallest density range, in D, the automatic settings work from.
const min_range = 0.02;
/// The smallest shadow level, as a share of the density range, the automatic balance works with.
const min_shadow = 1e-3;
/// The smallest span, as a share of the density range, a channel's highlights are balanced over.
const min_span = 1e-3;
/// The least density above the base a reference point counts with, in D, so that one at the base
/// itself doesn't divide by zero.
const min_reference_density = 1e-3;

/// The part of a frame the automatic settings are measured on: the middle, away from the holder.
pub const measured_fraction = 0.5;

/// A frame's statistics: of its middle, which the automatic settings use, and of all of it.
pub const FrameStatistics = struct {
    centre: Statistics,
    whole: Statistics,

    pub fn measure(gpa: std.mem.Allocator, scan: image.Scan) !FrameStatistics {
        const whole: image.Area = .whole(scan.width, scan.height);
        return .{
            .centre = try Statistics.measure(gpa, scan, whole.centre(measured_fraction)),
            .whole = try Statistics.measure(gpa, scan, whole),
        };
    }
};

/// Percentiles the automatic settings measure, in parts per thousand of the pixels.
pub const base_per_mille = 998;
pub const densest_per_mille = 2;
pub const thinnest_per_mille = 995;

/// Transmission statistics of a frame, per channel.
pub const Statistics = struct {
    /// The thinnest film: the base, when the area includes rebate, or else close to it.
    thinnest: [3]f32,
    /// The densest part of the image: the brightest highlights.
    densest: [3]f32,
    /// The thinnest part of the image: the deepest shadows.
    shadows: [3]f32,
    /// The mean of log10 of the transmission: the frame's average density, negated.
    mean_log: [3]f32,

    /// Measures `area` of `scan`.
    pub fn measure(gpa: std.mem.Allocator, scan: image.Scan, area: image.Area) !Statistics {
        // An empty area, as of a crop collapsed to nothing, is blank film: the automatic
        // settings keep their defaults for it.
        if (area.width == 0 or area.height == 0) return .{ .thinnest = @splat(1), .densest = @splat(1), .shadows = @splat(1), .mean_log = @splat(0) };
        const histogram = try gpa.alloc([image.channel_count]u32, histogram_bins);
        defer gpa.free(histogram);
        @memset(histogram, @splat(0));
        for (area.y..area.y + area.height) |y| {
            for (scan.row(y)[area.x..][0..area.width]) |p| {
                for (p, 0..) |v, c| histogram[v][c] += 1;
            }
        }
        const count = area.width * area.height;
        var stats: Statistics = undefined;
        for (0..image.channel_count) |c| {
            stats.thinnest[c] = percentile(histogram, c, count, base_per_mille);
            stats.densest[c] = percentile(histogram, c, count, densest_per_mille);
            stats.shadows[c] = percentile(histogram, c, count, thinnest_per_mille);
            var sum: f64 = 0;
            for (histogram, 0..) |bins, v| {
                if (bins[c] == 0) continue;
                const t = @max(@as(f64, @floatFromInt(v)) / image.full_scale, smallest_transmission);
                sum += @as(f64, @floatFromInt(bins[c])) * std.math.log10(t);
            }
            stats.mean_log[c] = @floatCast(sum / @as(f64, @floatFromInt(count)));
        }
        return stats;
    }
};

const histogram_bins = std.math.maxInt(u16) + 1;

/// The value below which `per_mille` of the `count` pixels fall, as a fraction of full scale.
fn percentile(histogram: []const [image.channel_count]u32, channel: usize, count: usize, per_mille: usize) f32 {
    const rank = @min(count - 1, count * per_mille / 1000);
    var seen: usize = 0;
    for (histogram, 0..) |bins, v| {
        seen += bins[channel];
        if (seen > rank) return @max(@as(f32, @floatFromInt(v)) / image.full_scale, smallest_transmission);
    }
    return 1;
}

/// Automatic settings for a negative: the base from `base`, the density range from the densest
/// highlights, the offset from the shadows, and each channel balanced so the highlights and the
/// shadows come out neutral.
pub fn automatic(kind: FilmKind, measured_base: [3]f32, stats: Statistics) Settings {
    // A base picked where a channel reads nothing would put infinities everywhere below.
    var base = measured_base;
    for (&base) |*b| b.* = @max(b.*, smallest_transmission);
    var settings: Settings = .{ .kind = kind, .base = base };
    var range: f32 = 0;
    for (base, stats.densest) |b, densest| range = @max(range, std.math.log10(b / densest));
    // A frame with next to no density in it (blank film, or bare light) keeps the defaults.
    if (!(range > min_range)) return settings;
    settings.density_range = range;

    var shadow: [3]f32 = undefined;
    var lowest: f32 = std.math.inf(f32);
    for (&shadow, base, stats.shadows) |*s, b, t| {
        // A channel whose shadows read as the base itself, as when a channel is at full scale in
        // both, would divide by zero below; it counts as barely above the base instead.
        s.* = @max(std.math.log10(b / t) / range, min_shadow);
        lowest = @min(lowest, s.*);
    }
    settings.offset = lowest;
    if (kind.isMonochrome()) return settings;

    var smallest_shadow: f32 = std.math.inf(f32);
    for (shadow) |s| smallest_shadow = @min(smallest_shadow, s);
    for (&settings.shadow_balance, shadow) |*balance, s| balance.* = smallest_shadow / s;

    var highlight: [3]f32 = undefined;
    var smallest_highlight: f32 = std.math.inf(f32);
    for (&highlight, base, stats.densest, settings.shadow_balance) |*h, b, t, low| {
        const span = settings.offset * low - std.math.log10(b / t) / range;
        h.* = if (@abs(span) > min_span) @abs(-1 / span) else 1;
        smallest_highlight = @min(smallest_highlight, h.*);
    }
    // A balance that can't be a number leaves the default one.
    if (!(smallest_highlight > 0) or !std.math.isFinite(smallest_highlight)) return settings;
    for (&settings.highlight_balance, highlight) |*balance, h| balance.* = h / smallest_highlight;
    return settings;
}

/// The slopes, relative to green, that bring a frame's neutrals out neutral: its automatic
/// highlight balance. Null when the frame has too little in it to tell, or for B&W and slides.
pub fn neutralSlopes(kind: FilmKind, base: [3]f32, stats: Statistics) ?[3]f32 {
    if (kind != .colour_negative) return null;
    const auto = automatic(kind, base, stats);
    const h = auto.highlight_balance;
    if (!(h[1] > 0) or !std.math.isFinite(h[0]) or !std.math.isFinite(h[1]) or !std.math.isFinite(h[2])) return null;
    // Without density to measure, `automatic` keeps the default balance, which says nothing.
    if (std.meta.eql(h, (Settings{}).highlight_balance)) return null;
    return .{ h[0] / h[1], 1, h[2] / h[1] };
}

/// `settings` with its balance set by `mode`: from `stats` of the frame; for `.picked`, making the
/// transmission `picked` neutral; for `.stock`, with `stock_slopes`, the stock's layer slopes on
/// this scanner relative to green (`calibration.stockSlopes`). Without them `.stock` keeps the
/// balance.
pub fn balanced(settings: Settings, mode: WhiteBalance, stats: Statistics, picked: ?[3]f32, stock_slopes: ?[3]f32) Settings {
    var s = settings;
    s.white_balance = mode;
    if (s.kind.isMonochrome() or !s.kind.isNegative()) return s;
    const neutral = automatic(s.kind, s.base, stats);
    switch (mode) {
        .stock => {
            const slopes = stock_slopes orelse return s;
            // The automatic shadows, and the stock's slopes in the highlights.
            s.shadow_balance = neutral.shadow_balance;
            s.highlight_balance = slopes;
        },
        .auto_neutral, .auto_warm, .auto_cool => {
            s.highlight_balance = neutral.highlight_balance;
            s.shadow_balance = neutral.shadow_balance;
            if (mode != .auto_neutral) {
                const g = gains(if (mode == .auto_warm) warmth else -warmth, 0);
                for (&s.highlight_balance, &s.shadow_balance, g) |*high, *low, gain| {
                    high.* *= gain;
                    low.* /= gain;
                }
            }
        },
        .average, .picked => {
            // Equal density above the base in every channel at the reference point, relative to
            // green, keeping the automatic shadows.
            var d: [3]f32 = undefined;
            for (&d, s.base, 0..) |*out, b, i| {
                const log_t = if (picked) |p| std.math.log10(@max(p[i], smallest_transmission)) else stats.mean_log[i];
                out.* = @min(log_t - std.math.log10(b), -min_reference_density);
            }
            s.shadow_balance = neutral.shadow_balance;
            for (&s.highlight_balance, d) |*high, v| high.* = d[1] / v;
        },
    }
    return s;
}

test "the film base comes out black and dense film white" {
    const settings: Settings = .{ .base = .{ 0.8, 0.5, 0.3 }, .offset = 0 };
    const prepared: Prepared = .init(settings);
    const base = pixel(prepared, .{ 52428, 32768, 19661 });
    for (base) |v| try std.testing.expect(v < 0.01);
    const dense = pixel(prepared, .{ 52, 32, 19 });
    for (dense) |v| try std.testing.expect(v > 0.7);
}

test "automatic settings balance highlights and shadows" {
    const base: [3]f32 = .{ 0.8, 0.5, 0.3 };
    const stats: Statistics = .{
        .thinnest = base,
        .densest = .{ 0.008, 0.004, 0.0035 },
        .shadows = .{ 0.6, 0.35, 0.2 },
        .mean_log = @splat(-1),
    };
    const settings = automatic(.colour_negative, base, stats);
    const prepared: Prepared = .init(settings);
    var shadows: [3]u16 = undefined;
    var highlights: [3]u16 = undefined;
    for (&shadows, &highlights, stats.shadows, stats.densest) |*s, *h, ts, td| {
        s.* = @intFromFloat(ts * image.full_scale);
        h.* = @intFromFloat(td * image.full_scale);
    }
    const dark = pixel(prepared, shadows);
    const light = pixel(prepared, highlights);
    try std.testing.expectApproxEqAbs(dark[0], dark[2], 0.01);
    try std.testing.expectApproxEqAbs(light[0], light[2], 0.02);
    try std.testing.expect(light[1] > dark[1] + 0.5);
}

test "B&W uses one channel's density" {
    const settings: Settings = .{ .kind = .bw_negative, .base = @splat(0.8) };
    const out = pixel(.init(settings), .{ 1000, 20000, 60000 });
    try std.testing.expectEqual(out[0], out[2]);
}

test "tones order their contrast and log stores the density" {
    const base: Settings = .{ .base = .{ 0.8, 0.5, 0.3 }, .offset = 0 };
    var soft = base;
    soft.tone = .soft;
    var hard = base;
    hard.tone = .hard;
    const raw: [3]u16 = .{ 6000, 3000, 1500 };
    const standard_out = pixel(.init(base), raw);
    const soft_out = pixel(.init(soft), raw);
    const hard_out = pixel(.init(hard), raw);
    try std.testing.expect(soft_out[1] > standard_out[1] and standard_out[1] > hard_out[1]);

    var log = base;
    log.tone = .log;
    const log_out = pixel(.init(log), raw);
    const d = std.math.log10(3000.0 / 65535.0 / 0.5);
    try std.testing.expectApproxEqAbs(-d / base.density_range, encode.srgb(log_out[1]), 1e-3);
}

test "a picked grey comes out neutral" {
    const settings: Settings = .{ .base = .{ 0.8, 0.5, 0.3 }, .offset = 0 };
    const grey: [3]f32 = .{ 0.1, 0.04, 0.015 };
    const stats: Statistics = .{ .thinnest = settings.base, .densest = .{ 0.008, 0.004, 0.0035 }, .shadows = .{ 0.6, 0.35, 0.2 }, .mean_log = @splat(-1) };
    var picked = balanced(settings, .picked, stats, grey, null);
    picked.shadow_balance = @splat(1);
    picked.offset = 0;
    var raw: [3]u16 = undefined;
    for (&raw, grey) |*r, g| r.* = @intFromFloat(g * image.full_scale);
    const out = pixel(.init(picked), raw);
    try std.testing.expectApproxEqAbs(out[1], out[0], 0.01);
    try std.testing.expectApproxEqAbs(out[1], out[2], 0.01);
}

test "saturation keeps luminance and hue, and 0 is grey" {
    var grey: Settings = .{ .saturation = 0 };
    var pixels = [_][3]f32{.{ 0.6, 0.3, 0.1 }};
    saturate(.init(grey), &pixels);
    try std.testing.expectApproxEqAbs(pixels[0][0], pixels[0][1], 1e-6);
    try std.testing.expectApproxEqAbs(0.2126 * 0.6 + 0.7152 * 0.3 + 0.0722 * 0.1, pixels[0][1], 1e-6);
    grey.saturation = 1.5;
    var more = [_][3]f32{.{ 0.6, 0.3, 0.1 }};
    saturate(.init(grey), &more);
    // Further from grey along the same line: the channels' ratios of differences stay.
    const y = 0.2126 * 0.6 + 0.7152 * 0.3 + 0.0722 * 0.1;
    try std.testing.expectApproxEqAbs((0.6 - y) * 1.5 + y, more[0][0], 1e-6);
    try std.testing.expectApproxEqAbs((0.3 - y) * 1.5 + y, more[0][1], 1e-6);
    // B&W stays as it is.
    var bw = [_][3]f32{.{ 0.4, 0.4, 0.4 }};
    saturate(.init(.{ .kind = .bw_negative, .saturation = 2 }), &bw);
    try std.testing.expectEqual([3]f32{ 0.4, 0.4, 0.4 }, bw[0]);
}

test "positive temperature warms the highlights" {
    var settings: Settings = .{ .base = .{ 0.8, 0.5, 0.3 }, .offset = 0 };
    const raw: [3]u16 = .{ 3000, 1500, 800 };
    const before = pixel(.init(settings), raw);
    settings.temperature[@backingInt(Range.highlights)] = 50;
    const after = pixel(.init(settings), raw);
    try std.testing.expect(after[0] > before[0] and after[2] < before[2]);
}

test "the stock balance takes the stock's slopes, and the frame's own shadows" {
    const settings: Settings = .{ .base = .{ 0.8, 0.5, 0.3 } };
    const stats: Statistics = .{ .thinnest = settings.base, .densest = .{ 0.008, 0.004, 0.0035 }, .shadows = .{ 0.6, 0.35, 0.2 }, .mean_log = @splat(-1) };
    const out = balanced(settings, .stock, stats, null, .{ 1.3, 1, 0.88 });
    try std.testing.expectEqual([3]f32{ 1.3, 1, 0.88 }, out.highlight_balance);
    try std.testing.expectEqual(automatic(.colour_negative, settings.base, stats).shadow_balance, out.shadow_balance);
    // Without slopes, the balance stays.
    try std.testing.expectEqual(settings.highlight_balance, balanced(settings, .stock, stats, null, null).highlight_balance);
}

test "neutral slopes are the automatic balance against green, and none for a blank frame" {
    const base: [3]f32 = .{ 0.8, 0.5, 0.3 };
    const stats: Statistics = .{ .thinnest = base, .densest = .{ 0.008, 0.004, 0.0035 }, .shadows = .{ 0.6, 0.35, 0.2 }, .mean_log = @splat(-1) };
    const slopes = neutralSlopes(.colour_negative, base, stats).?;
    const auto = automatic(.colour_negative, base, stats);
    try std.testing.expectApproxEqAbs(auto.highlight_balance[0] / auto.highlight_balance[1], slopes[0], 1e-6);
    try std.testing.expectEqual(@as(f32, 1), slopes[1]);
    try std.testing.expectEqual(@as(?[3]f32, null), neutralSlopes(.colour_negative, base, .{ .thinnest = base, .densest = base, .shadows = base, .mean_log = @splat(0) }));
    try std.testing.expectEqual(@as(?[3]f32, null), neutralSlopes(.bw_negative, base, stats));
}

test "a base with a channel at zero, and an empty area, still give finite settings" {
    const gpa = std.testing.allocator;
    const stats: Statistics = .{ .thinnest = .{ 0.5, 0.4, 0 }, .densest = .{ 0.01, 0.02, 0.03 }, .shadows = .{ 0.4, 0.3, 0.1 }, .mean_log = @splat(-1) };
    const settings = automatic(.colour_negative, .{ 0.5, 0.4, 0 }, stats);
    for (settings.highlight_balance ++ settings.shadow_balance ++ settings.base) |v| try std.testing.expect(std.math.isFinite(v));
    for (pixel(.init(settings), .{ 1000, 1000, 1000 })) |v| try std.testing.expect(std.math.isFinite(v));

    var scan: image.Scan = try .init(gpa, 1, 4);
    defer scan.deinit(gpa);
    @memset(scan.pixels, .{ 100, 100, 100 });
    const empty = try Statistics.measure(gpa, scan, (image.Area.whole(1, 4)).centre(0.5));
    const blank = automatic(.colour_negative, .{ 0.5, 0.4, 0.3 }, empty);
    try std.testing.expectEqual((Settings{}).density_range, blank.density_range);
}

test "automatic settings stay finite when a channel's shadows read as the base" {
    const base: [3]f32 = .{ 0.8, 1, 1 };
    const stats: Statistics = .{ .thinnest = base, .densest = .{ 0.01, 0.02, 0.03 }, .shadows = .{ 0.6, 1, 1 }, .mean_log = @splat(-1) };
    const settings = automatic(.colour_negative, base, stats);
    for (settings.highlight_balance ++ settings.shadow_balance) |v| try std.testing.expect(std.math.isFinite(v));
    const blank = automatic(.colour_negative, base, .{ .thinnest = base, .densest = base, .shadows = base, .mean_log = @splat(0) });
    try std.testing.expect(std.math.isFinite(blank.density_range));
}
