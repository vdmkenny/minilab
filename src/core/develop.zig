//! The neutral look: from a scan's transmission to a positive, in density.
//!
//! 1. Density above the film base, per channel: d = log10(T / T_base), 0 at the base and negative
//!    for denser film.
//! 2. A 3×3 matrix in density, for channel crosstalk, then, with a stock's datasheet curves, each
//!    layer's density straightened (`stock_curves`).
//! 3. The inversion curve: density scaled by the density range and balanced per channel, then
//!    y = max(exposure · (1 + black − 10^c), 0)^contrast, with a soft roll-off of the highlights.
//! 4. The tone: the curve as it is, softer or harder, or a flat linear or log image for grading.
//!
//! The model and its default values are darktable's negative inversion, written here from its
//! published equations; no darktable code is used. Output is linear, 0..1.
//!
//! The balance has two layers: the automatic per-channel balance of highlights and shadows, which
//! the white balance mode sets, and on top the colour of the light, as a temperature in K and a
//! tint per tonal range. Light of another colour shifts each layer's exposure by a fixed amount,
//! which the inversion undoes as a fixed shift per channel, the way a colour printing filter does.

const std = @import("std");
const image = @import("image.zig");
const encode = @import("encode.zig");
const stock_curves = @import("stock_curves.zig");

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

/// How much warmer or cooler the warm and cool balances are: a twelfth of a stop on red and blue.
const warmth = 25;

/// The light the balance as set counts as, K: daylight, which daylight film is balanced for.
pub const reference_kelvin = 5500;
/// The temperatures the light can be set to, K: from candlelight to open shade.
pub const min_kelvin = 2000;
pub const max_kelvin = 12000;
/// A colour negative's contrast, density per log exposure, for how far a change in the light
/// moves the inversion: the presets' straight parts are 0.5 to 0.7.
const light_gamma = 0.6;

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
    /// The colour of the light per range, on top of the balance: its temperature in K, where
    /// `reference_kelvin` leaves the balance and lower is warmer light, which the picture is made
    /// cooler for; and its tint, −100..100, positive more magenta.
    temperature: [3]f32 = @splat(reference_kelvin),
    tint: [3]f32 = @splat(0),
    tone: Tone = .standard,
    /// Colour after the look, 0..2: 0 grey, 1 as it is. Applied by `saturate`.
    saturation: f32 = 1,
    /// The roll's stock's curves, straightening each layer's density; null for no stock, or one
    /// without curves.
    stock_curves: ?stock_curves.Curves = null,

    /// The curves, for `automatic`.
    pub fn curves(settings: *const Settings) ?*const stock_curves.Curves {
        return if (settings.stock_curves) |*c| c else null;
    }
};

/// Per-channel slope gains for the warm and cool balances: `shift` of ±100 is half a stop on red
/// and blue.
fn warmthGains(shift: f32) [3]f32 {
    const t = shift / 200;
    return .{ std.math.exp2(t), 1, std.math.exp2(-t) };
}

/// The exposure each layer needs, against green, to make a grey lit by light of `kelvin` and `tint`
/// come out as one lit at `reference_kelvin`: the black body's colour at the reference over its
/// colour at `kelvin`, and ±100 tint half a stop on green.
pub fn lightGains(kelvin: f32, tint: f32) [3]f32 {
    const reference = blackBody(reference_kelvin);
    const light = blackBody(std.math.clamp(kelvin, min_kelvin, max_kelvin));
    const m = tint / 200;
    return .{ reference[0] / light[0] * std.math.exp2(m / 2), std.math.exp2(-m), reference[2] / light[2] * std.math.exp2(m / 2) };
}

/// A black body's colour at `kelvin` (1667 to 25000), in linear sRGB with green 1: its
/// chromaticity by Kim et al.'s cubic fit to the Planckian locus, then sRGB's primaries.
fn blackBody(kelvin: f32) [3]f32 {
    const t: f64 = kelvin;
    const x = if (t <= 4000)
        -0.2661239e9 / (t * t * t) - 0.2343589e6 / (t * t) + 0.8776956e3 / t + 0.179910
    else
        -3.0258469e9 / (t * t * t) + 2.1070379e6 / (t * t) + 0.2226347e3 / t + 0.240390;
    const y = if (t <= 2222)
        -1.1063814 * x * x * x - 1.34811020 * x * x + 2.18555832 * x - 0.20219683
    else if (t <= 4000)
        -0.9549476 * x * x * x - 1.37418593 * x * x + 2.09137015 * x - 0.16748867
    else
        3.0817580 * x * x * x - 5.87338670 * x * x + 3.75112997 * x - 0.37001483;
    const xyz = [3]f64{ x / y, 1, (1 - x - y) / y };
    const to_srgb = [3][3]f64{
        .{ 3.2404542, -1.5371385, -0.4985314 },
        .{ -0.9692660, 1.8760108, 0.0415560 },
        .{ 0.0556434, -0.2040259, 1.0572252 },
    };
    var rgb: [3]f64 = undefined;
    for (&rgb, to_srgb) |*v, row| v.* = row[0] * xyz[0] + row[1] * xyz[1] + row[2] * xyz[2];
    // A very warm light's blue is all but nothing: kept above it, so that it divides.
    return .{ @floatCast(@max(rgb[0], 1e-4) / rgb[1]), 1, @floatCast(@max(rgb[2], 1e-4) / rgb[1]) };
}

/// A temperature on the scale before kelvin, −100..100, as K: ±100 moved red and blue half a
/// stop each, about 73 mired, the same as from 5500 K to 9200 K.
pub fn kelvinFromShift(shift: f32) f32 {
    const mired_per_step = 0.726;
    const mired = 1e6 / @as(f32, reference_kelvin) - shift * mired_per_step;
    return std.math.clamp(1e6 / mired, min_kelvin, max_kelvin);
}

/// Values that depend only on the settings, worked out once per render.
pub const Prepared = struct {
    settings: Settings,
    slope: [3]f32,
    shift: [3]f32,
    contrast: f32,
    roll_off: f32,
    lift: f32,
    /// 1 for B&W, which has no colour to change.
    saturation: f32,
    /// Per range, per channel, the shift that undoes the light's colour; 0 for B&W.
    light: [3][3]f32,

    pub fn init(settings: Settings) Prepared {
        var prepared: Prepared = .{
            .settings = settings,
            .slope = undefined,
            .shift = undefined,
            .contrast = switch (settings.tone) {
                .standard, .log => settings.contrast,
                .soft => settings.contrast * soft_contrast,
                .hard => settings.contrast * hard_contrast,
                .linear => 1,
            },
            .roll_off = if (settings.tone == .linear) 1 else settings.roll_off,
            .lift = -settings.exposure * (1 + settings.black),
            .saturation = if (settings.kind.isMonochrome()) 1 else settings.saturation,
            .light = @splat(@splat(0)),
        };
        for (0..3) |i| {
            const high = settings.highlight_balance[i];
            prepared.slope[i] = high / settings.density_range;
            prepared.shift[i] = high * settings.offset * settings.shadow_balance[i];
        }
        if (!settings.kind.isMonochrome()) {
            // More exposure in a layer is more density, which comes out brighter: log10 of the gain
            // in exposure, times the film's contrast, over the density range.
            for (&prepared.light, settings.temperature, settings.tint) |*range, kelvin, tint| {
                for (range, lightGains(kelvin, tint)) |*l, gain| l.* = -light_gamma * std.math.log10(gain) / settings.density_range;
            }
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
    const curves = s.curves() orelse return mixed;
    // The curves take density above the base, which is `d` turned round.
    for (&mixed, 0..) |*v, c| v.* = -curves.layer(c, -v.*);
    return mixed;
}

/// Density above `base` of film that transmits `t`, for channel `c`: straightened by `curves` where
/// there are some.
fn densityAbove(curves: ?*const stock_curves.Curves, c: usize, base: f32, t: f32) f32 {
    const d = std.math.log10(base / t);
    return if (curves) |cv| cv.layer(c, d) else d;
}

/// How much each range's light counts at the tone `c`, green's place on the curve: 0 at the base,
/// in the deepest shadows, to −1 at the density range, in the highlights. They sum to 1, so the
/// same light in every range is the same shift at every tone.
fn rangeWeights(c: f32) [3]f32 {
    const t = std.math.clamp(-c, 0, 1);
    var w: [3]f32 = undefined;
    w[@backingInt(Range.highlights)] = t * t;
    w[@backingInt(Range.midtones)] = 2 * t * (1 - t);
    w[@backingInt(Range.shadows)] = (1 - t) * (1 - t);
    return w;
}

fn invert(prepared: Prepared, d: [3]f32) [3]f32 {
    const s = prepared.settings;
    const roll_off = prepared.roll_off;
    const contrast = prepared.contrast;
    var curve: [3]f32 = undefined;
    for (&curve, d, prepared.slope, prepared.shift) |*c, v, slope, shift| c.* = slope * v + shift;
    const weights = rangeWeights(curve[1]);
    for (&curve, 0..) |*c, channel| {
        for (weights, prepared.light) |w, range| c.* += w * range[channel];
    }
    var y: [3]f32 = undefined;
    for (&y, curve) |*out, c| {
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
pub fn automatic(kind: FilmKind, measured_base: [3]f32, stats: Statistics, curves: ?*const stock_curves.Curves) Settings {
    // A base picked where a channel reads nothing would put infinities everywhere below.
    var base = measured_base;
    for (&base) |*b| b.* = @max(b.*, smallest_transmission);
    var settings: Settings = .{ .kind = kind, .base = base };
    var range: f32 = 0;
    for (base, stats.densest, 0..) |b, densest, c| range = @max(range, densityAbove(curves, c, b, densest));
    // A frame with next to no density in it (blank film, or bare light) keeps the defaults.
    if (!(range > min_range)) return settings;
    settings.density_range = range;

    var shadow: [3]f32 = undefined;
    var lowest: f32 = std.math.inf(f32);
    for (&shadow, base, stats.shadows, 0..) |*s, b, t, c| {
        // A channel whose shadows read as the base itself, as when a channel is at full scale in
        // both, would divide by zero below; it counts as barely above the base instead.
        s.* = @max(densityAbove(curves, c, b, t) / range, min_shadow);
        lowest = @min(lowest, s.*);
    }
    settings.offset = lowest;
    if (kind.isMonochrome()) return settings;

    var smallest_shadow: f32 = std.math.inf(f32);
    for (shadow) |s| smallest_shadow = @min(smallest_shadow, s);
    for (&settings.shadow_balance, shadow) |*balance, s| balance.* = smallest_shadow / s;

    var highlight: [3]f32 = undefined;
    var smallest_highlight: f32 = std.math.inf(f32);
    for (&highlight, base, stats.densest, settings.shadow_balance, 0..) |*h, b, t, low, c| {
        const span = settings.offset * low - densityAbove(curves, c, b, t) / range;
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
    // The scanner's own slopes, in its own density: without a stock's curves.
    const auto = automatic(kind, base, stats, null);
    const h = auto.highlight_balance;
    if (!(h[1] > 0) or !std.math.isFinite(h[0]) or !std.math.isFinite(h[1]) or !std.math.isFinite(h[2])) return null;
    // Without density to measure, `automatic` keeps the default balance, which says nothing.
    if (std.meta.eql(h, (Settings{}).highlight_balance)) return null;
    return .{ h[0] / h[1], 1, h[2] / h[1] };
}

/// `settings` with the roll's stock `curves`, and what `automatic` measures (the density range,
/// offset and balance) measured again on `stats` with them; the user's other choices stay. On a
/// scanner with `stock_slopes` an Auto neutral balance becomes the stock's, and without them a
/// stock balance becomes Auto neutral.
pub fn restocked(settings: Settings, stats: Statistics, curves: ?stock_curves.Curves, stock_slopes: ?[3]f32) Settings {
    var s = settings;
    s.stock_curves = curves;
    if (!s.kind.isNegative()) return s;
    const auto = automatic(s.kind, s.base, stats, s.curves());
    s.density_range = auto.density_range;
    s.offset = auto.offset;
    const mode: WhiteBalance = switch (s.white_balance) {
        .auto_neutral, .stock => if (stock_slopes != null) .stock else .auto_neutral,
        .auto_warm, .auto_cool, .average, .picked => s.white_balance,
    };
    // A picked balance can't be picked again without its point: its highlight slopes stay.
    if (mode == .picked) {
        s.shadow_balance = auto.shadow_balance;
        return s;
    }
    return balanced(s, mode, stats, null, stock_slopes);
}

/// `settings` with its balance set by `mode`: from `stats` of the frame; for `.picked`, making the
/// transmission `picked` neutral; for `.stock`, with `stock_slopes`, the stock's layer slopes on
/// this scanner relative to green (`calibration.stockSlopes`). Without them `.stock` keeps the
/// balance.
pub fn balanced(settings: Settings, mode: WhiteBalance, stats: Statistics, picked: ?[3]f32, stock_slopes: ?[3]f32) Settings {
    var s = settings;
    s.white_balance = mode;
    if (s.kind.isMonochrome() or !s.kind.isNegative()) return s;
    const neutral = automatic(s.kind, s.base, stats, s.curves());
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
                const g = warmthGains(if (mode == .auto_warm) warmth else -warmth);
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
                const above = densityAbove(s.curves(), i, b, std.math.pow(f32, 10, log_t));
                out.* = @min(-above, -min_reference_density);
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
    const settings = automatic(.colour_negative, base, stats, null);
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

test "warm light makes the picture cooler, and the reference changes nothing" {
    var settings: Settings = .{ .base = .{ 0.8, 0.5, 0.3 }, .offset = 0 };
    const raw: [3]u16 = .{ 3000, 1500, 800 };
    const before = pixel(.init(settings), raw);
    settings.temperature = @splat(3200);
    const tungsten = pixel(.init(settings), raw);
    try std.testing.expect(tungsten[0] < before[0] and tungsten[2] > before[2]);
    settings.temperature = @splat(8000);
    const shade = pixel(.init(settings), raw);
    try std.testing.expect(shade[0] > before[0] and shade[2] < before[2]);
    for (lightGains(reference_kelvin, 0)) |g| try std.testing.expectApproxEqAbs(@as(f32, 1), g, 1e-5);
    // A black body near 6500 K is near sRGB's white.
    for (blackBody(6500)) |v| try std.testing.expectApproxEqAbs(@as(f32, 1), v, 0.1);
}

test "the same light in every range shifts every tone alike" {
    for ([_]f32{ 0, -0.2, -0.5, -0.8, -1 }) |c| {
        var sum: f32 = 0;
        for (rangeWeights(c)) |w| sum += w;
        try std.testing.expectApproxEqAbs(@as(f32, 1), sum, 1e-6);
    }
    // Highlights count in the highlights, shadows in the shadows.
    try std.testing.expectEqual(@as(f32, 1), rangeWeights(-1)[@backingInt(Range.highlights)]);
    try std.testing.expectEqual(@as(f32, 1), rangeWeights(0)[@backingInt(Range.shadows)]);
}

test "temperatures saved before K convert" {
    try std.testing.expectApproxEqAbs(@as(f32, reference_kelvin), kelvinFromShift(0), 1e-3);
    try std.testing.expect(kelvinFromShift(100) > 9000 and kelvinFromShift(100) < 9400);
    try std.testing.expect(kelvinFromShift(-100) < reference_kelvin);
}

test "the stock balance takes the stock's slopes, and the frame's own shadows" {
    const settings: Settings = .{ .base = .{ 0.8, 0.5, 0.3 } };
    const stats: Statistics = .{ .thinnest = settings.base, .densest = .{ 0.008, 0.004, 0.0035 }, .shadows = .{ 0.6, 0.35, 0.2 }, .mean_log = @splat(-1) };
    const out = balanced(settings, .stock, stats, null, .{ 1.3, 1, 0.88 });
    try std.testing.expectEqual([3]f32{ 1.3, 1, 0.88 }, out.highlight_balance);
    try std.testing.expectEqual(automatic(.colour_negative, settings.base, stats, null).shadow_balance, out.shadow_balance);
    // Without slopes, the balance stays.
    try std.testing.expectEqual(settings.highlight_balance, balanced(settings, .stock, stats, null, null).highlight_balance);
}

test "neutral slopes are the automatic balance against green, and none for a blank frame" {
    const base: [3]f32 = .{ 0.8, 0.5, 0.3 };
    const stats: Statistics = .{ .thinnest = base, .densest = .{ 0.008, 0.004, 0.0035 }, .shadows = .{ 0.6, 0.35, 0.2 }, .mean_log = @splat(-1) };
    const slopes = neutralSlopes(.colour_negative, base, stats).?;
    const auto = automatic(.colour_negative, base, stats, null);
    try std.testing.expectApproxEqAbs(auto.highlight_balance[0] / auto.highlight_balance[1], slopes[0], 1e-6);
    try std.testing.expectEqual(@as(f32, 1), slopes[1]);
    try std.testing.expectEqual(@as(?[3]f32, null), neutralSlopes(.colour_negative, base, .{ .thinnest = base, .densest = base, .shadows = base, .mean_log = @splat(0) }));
    try std.testing.expectEqual(@as(?[3]f32, null), neutralSlopes(.bw_negative, base, stats));
}

test "a base with a channel at zero, and an empty area, still give finite settings" {
    const gpa = std.testing.allocator;
    const stats: Statistics = .{ .thinnest = .{ 0.5, 0.4, 0 }, .densest = .{ 0.01, 0.02, 0.03 }, .shadows = .{ 0.4, 0.3, 0.1 }, .mean_log = @splat(-1) };
    const settings = automatic(.colour_negative, .{ 0.5, 0.4, 0 }, stats, null);
    for (settings.highlight_balance ++ settings.shadow_balance ++ settings.base) |v| try std.testing.expect(std.math.isFinite(v));
    for (pixel(.init(settings), .{ 1000, 1000, 1000 })) |v| try std.testing.expect(std.math.isFinite(v));

    var scan: image.Scan = try .init(gpa, 1, 4);
    defer scan.deinit(gpa);
    @memset(scan.pixels, .{ 100, 100, 100 });
    const empty = try Statistics.measure(gpa, scan, (image.Area.whole(1, 4)).centre(0.5));
    const blank = automatic(.colour_negative, .{ 0.5, 0.4, 0.3 }, empty, null);
    try std.testing.expectEqual((Settings{}).density_range, blank.density_range);
}

test "automatic settings stay finite when a channel's shadows read as the base" {
    const base: [3]f32 = .{ 0.8, 1, 1 };
    const stats: Statistics = .{ .thinnest = base, .densest = .{ 0.01, 0.02, 0.03 }, .shadows = .{ 0.6, 1, 1 }, .mean_log = @splat(-1) };
    const settings = automatic(.colour_negative, base, stats, null);
    for (settings.highlight_balance ++ settings.shadow_balance) |v| try std.testing.expect(std.math.isFinite(v));
    const blank = automatic(.colour_negative, base, .{ .thinnest = base, .densest = base, .shadows = base, .mean_log = @splat(0) }, null);
    try std.testing.expect(std.math.isFinite(blank.density_range));
}

test "a stock's curves open up the shadows its toe crushed" {
    const stocks = @import("../presets/stocks.zig");
    const superia = for (stocks.stocks) |s| {
        if (std.mem.eql(u8, s.name, "Fujifilm Superia X-TRA 400")) break s;
    } else unreachable;
    const curves = stock_curves.of(superia, @splat(1)).?;
    const base = [3]f32{ 0.4, 0.2, 0.12 };
    // Shadows 0.08 D above the base, highlights 1.6 D.
    var stats: Statistics = .{ .thinnest = base, .densest = undefined, .shadows = undefined, .mean_log = undefined };
    for (&stats.densest, &stats.shadows, &stats.mean_log, base) |*dense, *shadow, *mean, b| {
        dense.* = b / std.math.pow(f32, 10, 1.6);
        shadow.* = b / std.math.pow(f32, 10, 0.08);
        mean.* = std.math.log10(b) - 0.8;
    }
    var plain = automatic(.colour_negative, base, stats, null);
    var corrected = automatic(.colour_negative, base, stats, &curves);
    corrected.stock_curves = curves;
    // Two deep shadows, 0.12 and 0.2 D above the base, in green: further apart once straightened.
    var spread: [2]f32 = undefined;
    for ([_]*Settings{ &plain, &corrected }, &spread) |s, *out| {
        const prepared: Prepared = .init(s.*);
        var raw: [2][3]u16 = undefined;
        for (&raw, [_]f32{ 0.12, 0.2 }) |*r, d| {
            for (r, base) |*v, b| v.* = @intFromFloat(b / std.math.pow(f32, 10, d) * image.full_scale);
        }
        out.* = pixel(prepared, raw[1])[1] - pixel(prepared, raw[0])[1];
    }
    try std.testing.expect(spread[1] > spread[0]);
    // The highlights stay where they were, a little higher up the straightened range.
    try std.testing.expect(corrected.density_range >= plain.density_range);
    // Nothing is clipped that wasn't: the shadows are measured where the curves put them.
    try std.testing.expect(corrected.offset > 0);
}

test "a new stock measures the frame again and keeps the user's choices" {
    const stocks = @import("../presets/stocks.zig");
    const superia = for (stocks.stocks) |s| {
        if (std.mem.eql(u8, s.name, "Fujifilm Superia X-TRA 400")) break s;
    } else unreachable;
    const curves = stock_curves.of(superia, @splat(1)).?;
    const base = [3]f32{ 0.4, 0.2, 0.12 };
    var stats: Statistics = .{ .thinnest = base, .densest = undefined, .shadows = undefined, .mean_log = undefined };
    for (&stats.densest, &stats.shadows, &stats.mean_log, base) |*dense, *shadow, *mean, b| {
        dense.* = b / std.math.pow(f32, 10, 1.5);
        shadow.* = b / std.math.pow(f32, 10, 0.1);
        mean.* = std.math.log10(b) - 0.8;
    }
    var settings = automatic(.colour_negative, base, stats, null);
    settings.contrast = 5;
    settings.saturation = 1.3;
    settings.temperature[1] = 6000;
    const slopes = [3]f32{ 1.3, 1, 0.9 };
    const restocked_settings = restocked(settings, stats, curves, slopes);
    try std.testing.expect(restocked_settings.stock_curves != null);
    try std.testing.expectEqual(automatic(.colour_negative, base, stats, &curves).offset, restocked_settings.offset);
    // On a calibrated scanner, Auto neutral becomes the stock's balance.
    try std.testing.expectEqual(WhiteBalance.stock, restocked_settings.white_balance);
    try std.testing.expectEqual(slopes, restocked_settings.highlight_balance);
    // The user's choices stay.
    try std.testing.expectEqual(@as(f32, 5), restocked_settings.contrast);
    try std.testing.expectEqual(@as(f32, 1.3), restocked_settings.saturation);
    try std.testing.expectEqual(@as(f32, 6000), restocked_settings.temperature[1]);
    // No stock: no curves, and a stock balance goes back to Auto neutral.
    const none = restocked(restocked_settings, stats, null, null);
    try std.testing.expectEqual(null, none.stock_curves);
    try std.testing.expectEqual(WhiteBalance.auto_neutral, none.white_balance);
}
