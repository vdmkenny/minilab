//! Synthetic strip scans with known frames, for the detection tests. A strip lies in a holder
//! whose opening is a little taller than the image, as in the V200's 35 mm holder, and the whole
//! scan can be turned and laid along either axis.

const std = @import("std");
const image = @import("../core/image.zig");
const detect = @import("detect.zig");
const formats = @import("formats.zig");

/// 135 perforations: pitch, size along and across, and distance from the film's edge.
const perforation_pitch_mm = formats.FilmSize.@"135".perforationPitchMm().?;
const perforation_length_mm = 1.98;
const perforation_height_mm = 2.8;
const perforation_inset_mm = 2.0;
const film_135_mm = formats.FilmSize.@"135".filmWidthMm().?;

/// Periods of the image texture along and across, in mm.
const texture_along_mm = 7.3;
const texture_across_mm = 5.1;

/// 135 frames as a camera lays them: full frames, 36 mm long on the 38 mm pitch, after a short
/// leader, on film that fills the holder but for 1 mm at each end.
const full_frame = formats.Standard.@"135_full_frame".format();
pub const frame_135_mm = full_frame.width_mm;
pub const pitch_135_mm = full_frame.pitch_mm.?;
pub const leader_135_mm = 4;
const film_margin_mm = 1;

/// Lays `frames` out as 135 frames, and gives the strip that holds just them.
pub fn strip135(frames: []Frame) Strip {
    for (frames, 0..) |*f, i| f.* = .{ .start_mm = leader_135_mm + pitch_135_mm * @as(f32, @floatFromInt(i)), .length_mm = frame_135_mm };
    const along = 2 * leader_135_mm + pitch_135_mm * @as(f32, @floatFromInt(frames.len));
    return .{ .along_mm = along, .film_start_mm = film_margin_mm, .film_end_mm = along - film_margin_mm, .frames = frames };
}

pub const Frame = struct {
    start_mm: f32,
    length_mm: f32,
    /// Mean density of the image: above the base for negatives, absolute for positives.
    density: f32 = 0.7,
    /// The texture's amplitude in density.
    texture: f32 = 0.4,
    /// Mounted slides: this aperture's shift across from the opening's centre line.
    offset_mm: f32 = 0,
};

pub const Strip = struct {
    dpi: f32 = 100,
    kind: detect.Kind = .negative,
    axis: detect.Axis = .y,
    /// The scan's size across and along the strip.
    across_mm: f32 = 33.02,
    along_mm: f32,
    /// The holder opening across the strip, centred in the scan.
    opening_mm: f32 = 25,
    /// The image's height across the strip.
    image_mm: f32 = 24,
    /// Film lies between these positions along; the holder beyond.
    film_start_mm: f32 = 0,
    film_end_mm: ?f32 = null,
    frames: []const Frame,
    /// Turned about the scan's centre, clockwise as displayed.
    rotation_degrees: f32 = 0,
    /// 135 film narrower than the opening, its perforations showing and bare light beside it.
    perforated: bool = false,
    /// Mounted slides: everything outside the apertures is opaque.
    mounted: bool = false,
    /// Transmissions: film base, holder, unexposed positive film, and bare light.
    base: f32 = 0.6,
    holder: f32 = 0.0012,
    dmax: f32 = 0.002,
    lamp: f32 = 0.9,
    /// Relative noise on every pixel.
    noise: f32 = 0.01,
    seed: u64 = 1,

    fn pxPerMm(strip: Strip) f32 {
        return strip.dpi / formats.mm_per_inch;
    }

    /// The scan's size in pixels, width then height.
    pub fn size(strip: Strip) [2]usize {
        const across: usize = @intFromFloat(@round(strip.across_mm * strip.pxPerMm()));
        const along: usize = @intFromFloat(@round(strip.along_mm * strip.pxPerMm()));
        return switch (strip.axis) {
            .y => .{ across, along },
            .x => .{ along, across },
        };
    }

    /// Where the centre of `frame` lands in the scan, in pixels.
    pub fn centre(strip: Strip, frame: Frame) [2]f32 {
        const along = frame.start_mm + frame.length_mm / 2;
        const across = if (strip.mounted) frame.offset_mm else 0;
        const middle = strip.middleMm();
        const flat: [2]f32 = switch (strip.axis) {
            .y => .{ middle[0] + across, along },
            .x => .{ along, middle[1] + across },
        };
        const angle = std.math.degreesToRadians(strip.rotation_degrees);
        const dx = flat[0] - middle[0];
        const dy = flat[1] - middle[1];
        const ppm = strip.pxPerMm();
        return .{
            (middle[0] + dx * @cos(angle) - dy * @sin(angle)) * ppm,
            (middle[1] + dx * @sin(angle) + dy * @cos(angle)) * ppm,
        };
    }

    fn middleMm(strip: Strip) [2]f32 {
        const dims = strip.size();
        const ppm = strip.pxPerMm();
        return .{ @as(f32, @floatFromInt(dims[0])) / ppm / 2, @as(f32, @floatFromInt(dims[1])) / ppm / 2 };
    }

    /// Transmission at a point of the unturned strip, `across` measured from its centre line.
    fn transmission(strip: Strip, along: f32, across: f32) f32 {
        const distance = @abs(across);
        if (distance > strip.opening_mm / 2) return strip.holder;
        if (along < strip.film_start_mm or along >= (strip.film_end_mm orelse strip.along_mm)) return strip.holder;
        if (strip.mounted) {
            for (strip.frames) |f| {
                if (along >= f.start_mm and along < f.start_mm + f.length_mm and @abs(across - f.offset_mm) < strip.image_mm / 2) {
                    return strip.picture(f, along, across);
                }
            }
            return strip.holder;
        }
        const unexposed = switch (strip.kind) {
            .negative => strip.base,
            .positive => strip.dmax,
        };
        if (strip.perforated) {
            const edge = film_135_mm / 2 - distance;
            if (edge < 0) return strip.lamp;
            const in_row = edge >= perforation_inset_mm and edge < perforation_inset_mm + perforation_height_mm;
            if (in_row and @mod(along, perforation_pitch_mm) < perforation_length_mm) return strip.lamp;
        }
        if (distance > strip.image_mm / 2) return unexposed;
        for (strip.frames) |f| {
            if (along >= f.start_mm and along < f.start_mm + f.length_mm) return strip.picture(f, along, across);
        }
        return unexposed;
    }

    /// The image of `frame`: its density with a texture running both ways.
    fn picture(strip: Strip, frame: Frame, along: f32, across: f32) f32 {
        const pattern = @sin(along * std.math.tau / texture_along_mm) * @cos(across * std.math.tau / texture_across_mm);
        const density = @max(frame.density + frame.texture * pattern, 0);
        const fraction = std.math.pow(f32, 10, -density);
        return switch (strip.kind) {
            .negative => strip.base * fraction,
            .positive => strip.lamp * fraction,
        };
    }

    pub fn render(strip: Strip, gpa: std.mem.Allocator) !image.Scan {
        const dims = strip.size();
        var scan: image.Scan = try .init(gpa, dims[0], dims[1]);
        var prng: std.Random.DefaultPrng = .init(strip.seed);
        const random = prng.random();
        const ppm = strip.pxPerMm();
        const middle = strip.middleMm();
        const angle = std.math.degreesToRadians(strip.rotation_degrees);
        const cos = @cos(angle);
        const sin = @sin(angle);
        for (0..dims[1]) |y| {
            for (scan.row(y), 0..) |*pixel, x| {
                const dx = (@as(f32, @floatFromInt(x)) + 0.5) / ppm - middle[0];
                const dy = (@as(f32, @floatFromInt(y)) + 0.5) / ppm - middle[1];
                // Undo the turn to find the point on the flat strip.
                const fx = dx * cos + dy * sin;
                const fy = -dx * sin + dy * cos;
                const along, const across = switch (strip.axis) {
                    .y => .{ fy + middle[1], fx },
                    .x => .{ fx + middle[0], fy },
                };
                const t = strip.transmission(along, across) * (1 + strip.noise * (2 * random.float(f32) - 1));
                pixel.* = @splat(@intFromFloat(std.math.clamp(t, 0, 1) * image.full_scale));
            }
        }
        return scan;
    }
};
