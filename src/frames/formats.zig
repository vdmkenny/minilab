//! The film formats a roll can have, with the nominal picture size of each one (design section
//! 6). A roll has one format, and frames of different formats never share a roll. Real frame sizes
//! vary from camera to camera, so detection measures them and only uses these sizes as a guide.
//!
//! Sizes are in millimetres. `width_mm` is the frame's length along the film and `height_mm` is
//! its size across the film, so a 135 full frame is 36 × 24 and a 120 6×4.5 is 41.5 × 56. Sheet
//! film has no direction, so its width is the longer side.

const std = @import("std");

/// Millimetres per inch. Scanners give their resolution per inch, but we measure film in mm.
pub const mm_per_inch = 25.4;

pub const FilmSize = enum {
    @"135",
    /// 120 and 220, which have the same film width and frame sizes.
    @"120",
    @"127",
    @"110",
    @"126",
    aps,
    minox,
    sheet,
    custom,

    pub fn label(size: FilmSize) []const u8 {
        return switch (size) {
            .@"135" => "135",
            .@"120" => "120/220",
            .@"127" => "127",
            .@"110" => "110",
            .@"126" => "126",
            .aps => "APS",
            .minox => "Minox",
            .sheet => "Sheet film",
            .custom => "Custom",
        };
    }

    /// The film's width in mm, or null when there's no single width.
    pub fn filmWidthMm(size: FilmSize) ?f32 {
        return switch (size) {
            .@"135", .@"126" => 35,
            .@"120" => 61,
            .@"127" => 46,
            .@"110" => 16,
            .aps => 24,
            .minox => 9.2,
            .sheet, .custom => null,
        };
    }

    /// The pitch of the perforations along both edges of the film, for film that has them (only
    /// 135, with its KS perforations). Detection uses it to leave the perforation bands out of the
    /// opening when the holder doesn't cover them.
    pub fn perforationPitchMm(size: FilmSize) ?f32 {
        return if (size.perforations()) |p| p.pitch_mm else null;
    }

    /// Returns the holes the film has: rows along both edges, a few holes per frame along one
    /// edge, or none at all (paper-backed roll film and sheet film have none).
    pub fn holes(size: FilmSize) Holes {
        return switch (size) {
            .@"135" => .{ .rows = size.perforations().? },
            // 126 has one registration hole per frame, 110 has one between frames, and APS
            // (IX240) has two close together. They're all along one edge.
            .@"126", .@"110" => .{ .per_frame = 1 },
            .aps => .{ .per_frame = 2 },
            .@"120", .@"127", .minox, .sheet, .custom => .none,
        };
    }

    /// The rows of holes along both edges of the film, for film that has them (135, with its KS
    /// perforations).
    pub fn perforations(size: FilmSize) ?Perforations {
        return switch (size) {
            .@"135" => .{ .pitch_mm = 4.75, .length_mm = 1.98, .height_mm = 2.8, .inset_mm = 2.0 },
            .@"120", .@"127", .@"110", .@"126", .aps, .minox, .sheet, .custom => null,
        };
    }

    /// A typical gap between frames, in mm. It's only used when a scan shows no gap to measure and
    /// the format has no fixed pitch. Cameras differ, so this is a rough figure.
    pub fn typicalGapMm(size: FilmSize) f32 {
        return switch (size) {
            .@"135", .aps, .custom => 2,
            .@"120", .@"126" => 4,
            .@"127", .@"110" => 3,
            .minox => 1,
            .sheet => 0,
        };
    }
};

/// The holes a film has, as `FilmSize.holes` returns them.
pub const Holes = union(enum) {
    none,
    /// A row of holes along both edges, at a fixed pitch.
    rows: Perforations,
    /// This many holes for each frame, along one edge.
    per_frame: u8,
};

/// A row of perforations: the pitch, the size of each hole along and across the film, and how far
/// in from the edge of the film the holes start, all in mm.
pub const Perforations = struct {
    pitch_mm: f32,
    length_mm: f32,
    height_mm: f32,
    inset_mm: f32,
};

/// Whether a frame's length follows from its height.
pub const RatioLock = enum {
    /// The length follows from the height and the format's ratio.
    locked,
    /// The length is whatever detection measures.
    free,
};

pub const Format = struct {
    size: FilmSize,
    name: []const u8,
    /// The size along the film, in mm.
    width_mm: f32,
    /// The size across the film, in mm.
    height_mm: f32,
    /// How far the film advances from one frame to the next, in mm, when the camera sets this by
    /// counting perforations. Null when it varies from camera to camera.
    pitch_mm: ?f32 = null,
    ratio_lock: RatioLock = .locked,

    /// The frame's length divided by its height.
    pub fn ratio(format: Format) f32 {
        return format.width_mm / format.height_mm;
    }

    /// The gap between frames, in mm. It comes from the pitch when that's fixed, and otherwise
    /// it's the film's typical gap.
    pub fn gapMm(format: Format) f32 {
        if (format.pitch_mm) |pitch| return pitch - format.width_mm;
        return format.size.typicalGapMm();
    }
};

/// Makes a format of the user's own: any size, with the ratio locked or free.
pub fn custom(width_mm: f32, height_mm: f32, ratio_lock: RatioLock) Format {
    return .{ .size = .custom, .name = "custom", .width_mm = width_mm, .height_mm = height_mm, .ratio_lock = ratio_lock };
}

/// A 135 camera advances the film 8 perforations per frame.
const full_frame_pitch_mm = 8 * FilmSize.@"135".perforationPitchMm().?;
/// A half-frame camera advances 4 perforations.
const half_frame_pitch_mm = 4 * FilmSize.@"135".perforationPitchMm().?;

/// Every standard format, as listed in design section 6.
pub const Standard = enum {
    @"135_full_frame",
    @"135_half_frame",
    @"135_panorama",
    @"135_square",
    @"120_6x4.5",
    @"120_6x6",
    @"120_6x7",
    @"120_6x8",
    @"120_6x9",
    @"120_6x12",
    @"120_6x17",
    @"127_4x4",
    @"127_4x6.5",
    @"127_3x4",
    @"110",
    @"126",
    aps_h,
    aps_c,
    aps_p,
    minox,
    sheet_4x5in,
    sheet_5x7in,
    sheet_8x10in,
    sheet_9x12cm,
    sheet_13x18cm,

    /// The default format of a new roll.
    pub const default: Standard = .@"135_full_frame";

    pub fn format(id: Standard) Format {
        return switch (id) {
            .@"135_full_frame" => .{ .size = .@"135", .name = "full frame", .width_mm = 36, .height_mm = 24, .pitch_mm = full_frame_pitch_mm },
            .@"135_half_frame" => .{ .size = .@"135", .name = "half frame", .width_mm = 18, .height_mm = 24, .pitch_mm = half_frame_pitch_mm },
            .@"135_panorama" => .{ .size = .@"135", .name = "panorama", .width_mm = 65, .height_mm = 24 },
            .@"135_square" => .{ .size = .@"135", .name = "square", .width_mm = 24, .height_mm = 24 },
            .@"120_6x4.5" => .{ .size = .@"120", .name = "6×4.5", .width_mm = 41.5, .height_mm = 56 },
            .@"120_6x6" => .{ .size = .@"120", .name = "6×6", .width_mm = 56, .height_mm = 56 },
            .@"120_6x7" => .{ .size = .@"120", .name = "6×7", .width_mm = 69.5, .height_mm = 56 },
            .@"120_6x8" => .{ .size = .@"120", .name = "6×8", .width_mm = 76, .height_mm = 56 },
            .@"120_6x9" => .{ .size = .@"120", .name = "6×9", .width_mm = 84, .height_mm = 56 },
            .@"120_6x12" => .{ .size = .@"120", .name = "6×12", .width_mm = 112, .height_mm = 56 },
            .@"120_6x17" => .{ .size = .@"120", .name = "6×17", .width_mm = 168, .height_mm = 56 },
            .@"127_4x4" => .{ .size = .@"127", .name = "4×4", .width_mm = 40, .height_mm = 40 },
            .@"127_4x6.5" => .{ .size = .@"127", .name = "4×6.5", .width_mm = 65, .height_mm = 40 },
            .@"127_3x4" => .{ .size = .@"127", .name = "3×4", .width_mm = 30, .height_mm = 40 },
            .@"110" => .{ .size = .@"110", .name = "110", .width_mm = 17, .height_mm = 13 },
            .@"126" => .{ .size = .@"126", .name = "126", .width_mm = 28, .height_mm = 28 },
            .aps_h => .{ .size = .aps, .name = "H", .width_mm = 30.2, .height_mm = 16.7 },
            .aps_c => .{ .size = .aps, .name = "C", .width_mm = 25.1, .height_mm = 16.7 },
            .aps_p => .{ .size = .aps, .name = "P", .width_mm = 30.2, .height_mm = 9.5 },
            .minox => .{ .size = .minox, .name = "Minox", .width_mm = 11, .height_mm = 8 },
            .sheet_4x5in => .{ .size = .sheet, .name = "4×5 in", .width_mm = 5 * mm_per_inch, .height_mm = 4 * mm_per_inch },
            .sheet_5x7in => .{ .size = .sheet, .name = "5×7 in", .width_mm = 7 * mm_per_inch, .height_mm = 5 * mm_per_inch },
            .sheet_8x10in => .{ .size = .sheet, .name = "8×10 in", .width_mm = 10 * mm_per_inch, .height_mm = 8 * mm_per_inch },
            .sheet_9x12cm => .{ .size = .sheet, .name = "9×12 cm", .width_mm = 120, .height_mm = 90 },
            .sheet_13x18cm => .{ .size = .sheet, .name = "13×18 cm", .width_mm = 180, .height_mm = 130 },
        };
    }
};

test "every standard format has a positive size and belongs to a film size" {
    for (std.enums.values(Standard)) |id| {
        const f = id.format();
        try std.testing.expect(f.width_mm > 0 and f.height_mm > 0);
        try std.testing.expect(f.size != .custom);
        try std.testing.expectEqual(RatioLock.locked, f.ratio_lock);
        if (f.size.filmWidthMm()) |film| try std.testing.expect(f.height_mm < film);
        if (f.pitch_mm) |pitch| try std.testing.expect(pitch > f.width_mm);
    }
}

test "135 full frame is the default, 36 × 24 on a 38 mm pitch" {
    const f = Standard.default.format();
    try std.testing.expectEqual(FilmSize.@"135", f.size);
    try std.testing.expectApproxEqAbs(1.5, f.ratio(), 1e-6);
    try std.testing.expectApproxEqAbs(38, f.pitch_mm.?, 1e-4);
    try std.testing.expectApproxEqAbs(2, f.gapMm(), 1e-4);
}

test "120 has no fixed pitch and falls back to the film's typical gap" {
    const f = Standard.@"120_6x6".format();
    try std.testing.expectEqual(null, f.pitch_mm);
    try std.testing.expectEqual(FilmSize.@"120".typicalGapMm(), f.gapMm());
}
