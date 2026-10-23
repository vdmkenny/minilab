//! Film stock presets. For each stock there are the starting values the density inversion needs
//! (minimum density, contrast and density range per channel) and, where the source has them, its
//! characteristic curves. Every value comes from a published source, named in `source`. A value
//! that no source gives is null. data/stocks/README.md explains how each value was worked out.
//!
//! Densities are Status M for colour negatives and Status A for colour slides. Black-and-white
//! entries use diffuse visual density where the maker says that's what they measured, and repeat
//! one value for R, G and B. Log exposure is log10 of lux-seconds unless `source` says it's
//! relative.

const std = @import("std");

/// The kinds of film, as Develop has them.
pub const Kind = @import("../core/develop.zig").FilmKind;

/// One sample of a characteristic curve.
pub const Point = struct { log_exposure: f32, density: f32 };

pub const Stock = struct {
    /// The product name, such as "Kodak Portra 400".
    name: []const u8,
    maker: []const u8,
    kind: Kind,
    /// The box speed or, for pushed entries, the exposure index the data is for.
    iso: u16,
    /// The minimum density (base + fog, or D-min for slides), for R, G and B.
    base_density: ?[3]f32,
    /// The slope of the straight part of the characteristic curve, in density per log exposure,
    /// for R, G and B. It's positive for slides too, even though their density falls with
    /// exposure.
    gamma: ?[3]f32,
    /// How far the source's curve goes above `base_density`, in density, for R, G and B. For
    /// slides it's D-max minus D-min.
    density_range: ?[3]f32,
    /// The characteristic curves for R, G and B, in order of increasing log exposure.
    curves: ?[3][]const Point,
    /// Where the numbers come from.
    source: []const u8,
};

pub const stocks = [_]Stock{
    // Colour negative: Status M densities.
    .{
        .name = "Kodak Portra 160",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 160,
        .base_density = .{ 0.200, 0.616, 0.837 },
        .gamma = .{ 0.522, 0.539, 0.612 },
        .density_range = .{ 1.563, 1.723, 2.017 },
        .curves = curve_data.kodak_portra_160,
        .source = "Kodak E-4051 (January 2025), Status M, daylight; curves digitised for minilab from the vector drawing in the PDF (about ±0.02 D: the drawn density ticks are uneven); log H in lux-seconds",
    },
    .{
        .name = "Kodak Portra 400",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 400,
        .base_density = .{ 0.220, 0.647, 0.868 },
        .gamma = .{ 0.547, 0.549, 0.635 },
        .density_range = .{ 1.759, 1.780, 2.142 },
        .curves = curve_data.kodak_portra_400,
        .source = "Kodak E-4050 (January 2025), Status M, daylight; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak Portra 800",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 800,
        .base_density = .{ 0.308, 0.706, 1.021 },
        .gamma = .{ 0.515, 0.527, 0.602 },
        .density_range = .{ 1.599, 1.678, 1.889 },
        .curves = curve_data.kodak_portra_800,
        .source = "Kodak E-4040 (January 2025), EI 800, Status M, daylight; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak Portra 800 (push 1, EI 1600)",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 1600,
        .base_density = .{ 0.244, 0.666, 1.017 },
        .gamma = .{ 0.623, 0.630, 0.716 },
        .density_range = .{ 2.026, 1.984, 2.235 },
        .curves = curve_data.kodak_portra_800_push_1,
        .source = "Kodak E-4040 (January 2025), EI 1600, one-stop push process, Status M; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak Portra 800 (push 2, EI 3200)",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 3200,
        .base_density = .{ 0.301, 0.696, 1.053 },
        .gamma = .{ 0.680, 0.717, 0.774 },
        .density_range = .{ 2.192, 2.157, 2.396 },
        .curves = curve_data.kodak_portra_800_push_2,
        .source = "Kodak E-4040 (January 2025), EI 3200, two-stop push process, Status M; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak Ektar 100",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 100,
        .base_density = .{ 0.210, 0.635, 0.850 },
        .gamma = .{ 0.559, 0.567, 0.646 },
        .density_range = .{ 1.699, 1.750, 2.171 },
        .curves = curve_data.kodak_ektar_100,
        .source = "Kodak E-4046 (January 2025), Status M, daylight; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak Gold 200",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 200,
        .base_density = .{ 0.251, 0.657, 0.991 },
        .gamma = .{ 0.538, 0.557, 0.611 },
        .density_range = .{ 1.561, 1.627, 1.731 },
        .curves = curve_data.kodak_gold_200,
        .source = "Kodak E-7022 (June 2023), Status M, daylight; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak UltraMax 400",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 400,
        .base_density = .{ 0.285, 0.693, 0.980 },
        .gamma = .{ 0.508, 0.532, 0.597 },
        .density_range = .{ 1.625, 1.724, 1.956 },
        .curves = curve_data.kodak_ultramax_400,
        .source = "Kodak E-7023 (February 2016), Status M, daylight, C-41; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak Pro Image 100",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 100,
        .base_density = .{ 0.247, 0.704, 0.955 },
        .gamma = .{ 0.560, 0.594, 0.696 },
        .density_range = .{ 1.790, 1.885, 2.193 },
        .curves = curve_data.kodak_pro_image_100,
        .source = "Kodak E-4L (July 1997), Status M, C-41, daylight; curves read for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak Vision3 50D 5203",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 50,
        .base_density = .{ 0.170, 0.575, 0.846 },
        .gamma = .{ 0.484, 0.570, 0.549 },
        .density_range = .{ 1.708, 2.027, 1.955 },
        .curves = curve_data.kodak_vision3_50d,
        .source = "Kodak H-1-5203 (July 2015 edition), Status M, ECN-2, 5500 K daylight 1/50 s; curves read for minilab from the vector drawing in the PDF; log H relative to normal exposure, from the chart's camera-stop axis (0.30103 per stop). The March 2026 edition prints the same curves as an image (a raster reading agrees within 0.02 D)",
    },
    .{
        .name = "Kodak Vision3 250D 5207",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 250,
        .base_density = .{ 0.176, 0.577, 0.843 },
        .gamma = .{ 0.466, 0.546, 0.530 },
        .density_range = .{ 1.667, 1.976, 1.889 },
        .curves = curve_data.kodak_vision3_250d,
        .source = "Kodak H-1-5207 (July 2015 edition), Status M, ECN-2, 5500 K daylight 1/50 s; curves read for minilab from the vector drawing in the PDF; log H relative to normal exposure, from the chart's camera-stop axis (0.30103 per stop). The March 2026 edition prints the same curves as an image (a raster reading agrees within 0.002 D)",
    },
    .{
        .name = "Kodak Vision3 200T 5213",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 200,
        .base_density = .{ 0.178, 0.580, 0.847 },
        .gamma = .{ 0.469, 0.549, 0.526 },
        .density_range = .{ 1.647, 1.948, 1.861 },
        .curves = curve_data.kodak_vision3_200t,
        .source = "Kodak H-1-5213 (July 2015 edition), Status M, ECN-2, 3200 K tungsten 1/50 s; curves read for minilab from the vector drawing in the PDF; log H relative to normal exposure, from the chart's camera-stop axis (0.30103 per stop). The March 2026 edition prints the same curves as an image (a raster reading agrees within 0.004 D)",
    },
    .{
        .name = "Kodak Vision3 500T 5219",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 500,
        .base_density = .{ 0.189, 0.585, 0.840 },
        .gamma = .{ 0.465, 0.546, 0.533 },
        .density_range = .{ 1.673, 1.978, 1.905 },
        .curves = curve_data.kodak_vision3_500t,
        .source = "Kodak H-1-5219 (July 2015 edition), Status M (the chart says \"Densitometry: ECN-2\", Kodak's slip), ECN-2, 3200 K tungsten 1/50 s; curves read for minilab from the vector drawing in the PDF; log H relative to normal exposure, from the chart's camera-stop axis (0.30103 per stop). The March 2026 edition prints the same curves as an image (a raster reading agrees within 0.002 D)",
    },
    .{
        .name = "Kodak Verita 200D 5206",
        .maker = "Kodak",
        .kind = .colour_negative,
        .iso = 200,
        .base_density = .{ 0.214, 0.660, 0.916 },
        .gamma = .{ 0.488, 0.485, 0.596 },
        .density_range = .{ 1.891, 1.718, 2.170 },
        .curves = curve_data.kodak_verita_200d,
        .source = "Kodak Verita 200D brochure (K-1216, April 2026; data sheet H-1-5206), Status M, 5500 K daylight 1/50 s, ECN-2; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds from the chart's top axis (0.3 per camera stop)",
    },
    .{
        .name = "CineStill 800T",
        .maker = "CineStill",
        .kind = .colour_negative,
        .iso = 800,
        .base_density = .{ 0.189, 0.585, 0.840 },
        .gamma = .{ 0.465, 0.546, 0.533 },
        .density_range = .{ 1.673, 1.978, 1.905 },
        .curves = curve_data.kodak_vision3_500t,
        .source = "Kodak Vision3 500T 5219 reading (H-1-5219, July 2015 edition, Status M, ECN-2), as in that entry. CineStill publishes no curves; its FAQ names \"Vision 3 5219\" as the stock behind 800Tungsten. CineStill film is processed in C-41, not ECN-2, so contrast and base density differ: an approximation. Log H relative to normal exposure (camera stops × 0.30103)",
    },
    .{
        .name = "Fujifilm 200",
        .maker = "Fujifilm",
        .kind = .colour_negative,
        .iso = 200,
        .base_density = .{ 0.133, 0.373, 0.823 },
        .gamma = .{ 0.549, 0.626, 0.632 },
        .density_range = .{ 1.605, 1.862, 1.772 },
        .curves = curve_data.fujifilm_200,
        .source = "Fujifilm AF3-0261E (February 2022), Status M, daylight, CN-16; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Fujifilm 400",
        .maker = "Fujifilm",
        .kind = .colour_negative,
        .iso = 400,
        .base_density = null,
        .gamma = .{ 0.560, 0.626, 0.616 },
        .density_range = null,
        .curves = curve_data.fujifilm_400,
        .source = "Fujifilm AF3-0262E (April 2023), Status M, daylight, CN-16; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Fujifilm Superia X-TRA 400",
        .maker = "Fujifilm",
        .kind = .colour_negative,
        .iso = 400,
        .base_density = .{ 0.136, 0.453, 0.727 },
        .gamma = .{ 0.610, 0.665, 0.696 },
        .density_range = .{ 1.923, 2.033, 2.085 },
        .curves = curve_data.fujifilm_superia_xtra_400,
        .source = "Fujifilm AF3-0217E / 013AR0316A, Status M, daylight, CN-16; curves digitised for minilab from the vector drawing in the PDF (about ±0.015 D: the drawn grid is slightly uneven); log H in lux-seconds",
    },
    .{
        .name = "Fujifilm Superia 200",
        .maker = "Fujifilm",
        .kind = .colour_negative,
        .iso = 200,
        .base_density = null,
        .gamma = .{ 0.738, 0.803, 0.760 },
        .density_range = null,
        .curves = curve_data.fujifilm_superia_200,
        .source = "Fujifilm AF3-026E (October 1998), Status M, CN-16, daylight 1/125 s; curves read for minilab from the 600 ppi scanned chart image in the PDF (reads at 600 and 300 dpi agree within 0.003 D); log H in lux-seconds. The green curve still rises at 0.105 per log H where it starts, so base density is unknown",
    },
    .{
        .name = "Fujifilm Fujicolor C200",
        .maker = "Fujifilm",
        .kind = .colour_negative,
        .iso = 200,
        .base_density = .{ 0.144, 0.431, 0.732 },
        .gamma = .{ 0.607, 0.643, 0.658 },
        .density_range = .{ 1.744, 1.954, 1.941 },
        .curves = curve_data.fujifilm_c200,
        .source = "Fujifilm AF3-0249E (May 2017), Status M, CN-16, daylight 1/125 s; curves read for minilab from the 600 ppi chart image in the PDF (reads at 600 and 300 dpi agree within 0.01 D); log H in lux-seconds",
    },
    .{
        .name = "Fujifilm Pro 400H",
        .maker = "Fujifilm",
        .kind = .colour_negative,
        .iso = 400,
        .base_density = .{ 0.173, 0.687, 0.948 },
        .gamma = .{ 0.591, 0.550, 0.524 },
        .density_range = .{ 1.762, 1.683, 1.657 },
        .curves = curve_data.fujifilm_pro_400h,
        .source = "Fujifilm AF3-176E (January 2005), Status M, C-41, daylight 1/125 s; curves read for minilab from the vector drawing in the PDF (its gridlines are uneven by up to 0.013 log H); log H in lux-seconds",
    },
    .{
        .name = "Fujifilm Pro 160NS",
        .maker = "Fujifilm",
        .kind = .colour_negative,
        .iso = 160,
        .base_density = .{ 0.282, 0.817, 0.920 },
        .gamma = .{ 0.613, 0.538, 0.537 },
        .density_range = .{ 1.685, 1.474, 1.560 },
        .curves = curve_data.fujifilm_pro_160ns,
        .source = "Fujifilm 163AR109A (Japanese sheet), \"Status M equivalent\", daylight, CN-16; curves digitised for minilab from the vector drawing in the PDF (about ±0.017 D: the frame is drawn off the grid); log H in lux-seconds",
    },
    .{
        .name = "Fujifilm Fujicolor 100",
        .maker = "Fujifilm",
        .kind = .colour_negative,
        .iso = 100,
        .base_density = .{ 0.182, 0.512, 0.688 },
        .gamma = .{ 0.777, 0.731, 0.801 },
        .density_range = .{ 1.916, 1.896, 2.140 },
        .curves = curve_data.fujifilm_fujicolor_100,
        .source = "Fujifilm 013AR0317A (Japanese sheet), \"Status M equivalent\", daylight, CN-16; curves digitised for minilab from the vector drawing in the PDF (about ±0.015 D: the drawn grid is slightly uneven); log H in lux-seconds",
    },
    .{
        .name = "Harman Phoenix 200",
        .maker = "Harman",
        .kind = .colour_negative,
        .iso = 200,
        .base_density = .{ 0.500, 0.908, 0.500 },
        .gamma = .{ 1.276, 1.248, 1.426 },
        .density_range = .{ 1.741, 1.922, 2.098 },
        .curves = curve_data.harman_phoenix_200,
        .source = "HARMAN Phoenix 200 datasheet (September 2024), standard C-41 chemicals; the densitometry is not stated; curves read for minilab from the 216 ppi chart image in the PDF (reads at 600 and 300 dpi agree within 0.002 D). Blue and red are drawn over each other up to relative log H 0.9 and share one reading there; log H relative (\"relative log exposure\")",
    },
    // Colour positive (slide): Status A densities.
    .{
        .name = "Kodak Ektachrome E100",
        .maker = "Kodak",
        .kind = .colour_positive,
        .iso = 100,
        .base_density = null,
        .gamma = .{ 1.832, 2.052, 2.138 },
        .density_range = null,
        .curves = curve_data.kodak_ektachrome_e100,
        .source = "Kodak E-4000 (August 2018), Status A, daylight 1/100 s, E-6; curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds. The plotted curves stop before D-min levels off, so D-min is unknown",
    },
    .{
        .name = "Kodak Kodachrome 64",
        .maker = "Kodak",
        .kind = .colour_positive,
        .iso = 64,
        .base_density = null,
        .gamma = .{ 2.056, 1.982, 1.877 },
        .density_range = null,
        .curves = curve_data.kodak_kodachrome_64,
        .source = "Kodak E-88 (June 2009), Status A, daylight 1/50 s, K-14; curves read for minilab from the vector drawing in the PDF; log H in lux-seconds. The plotted curves level off at neither end, so D-min and D-max are unknown",
    },
    .{
        .name = "Fujifilm Provia 100F",
        .maker = "Fujifilm",
        .kind = .colour_positive,
        .iso = 100,
        .base_density = .{ 0.093, 0.093, 0.093 },
        .gamma = .{ 1.770, 1.900, 1.742 },
        .density_range = .{ 3.202, 3.333, 3.249 },
        .curves = curve_data.fujifilm_provia_100f,
        .source = "Fujifilm AF3-036E (October 2000), Fuji FAD-30S (Status A), daylight 1/50 s, E-6; curves read for minilab from the 300 ppi chart image in the PDF. Green and blue are drawn under red and take its reading where they coincide with it (reads at 600 and 300 dpi agree within 0.06 D, on the steep part where green is partly covered); log H in lux-seconds",
    },
    .{
        .name = "Fujifilm Velvia 100",
        .maker = "Fujifilm",
        .kind = .colour_positive,
        .iso = 100,
        .base_density = .{ 0.134, 0.134, 0.134 },
        .gamma = .{ 2.350, 2.660, 2.419 },
        .density_range = .{ 3.252, 3.689, 3.558 },
        .curves = curve_data.fujifilm_velvia_100,
        .source = "Fujifilm AF3-202E (February 2005), Status A, daylight, E-6; curves read for minilab from the vector drawing in the PDF (its gridlines are uneven by up to 0.008 log H); log H in lux-seconds",
    },
    .{
        .name = "Fujichrome Velvia 50",
        .maker = "Fujifilm",
        .kind = .colour_positive,
        .iso = 50,
        .base_density = .{ 0.155, 0.155, 0.155 },
        .gamma = .{ 2.206, 2.295, 2.198 },
        .density_range = .{ 3.185, 3.646, 3.543 },
        .curves = curve_data.fujichrome_velvia_50,
        .source = "Fujifilm AF3-0221E2 (March 2007), Status A, daylight, E-6/CR-56; curves read for minilab from the 600 ppi chart image in the PDF. From log H -1.6 on the three curves are drawn over each other, within about a line width, and there all three take the centre of the band they form (reads at 600 and 300 dpi agree within 0.07 D); log H in lux-seconds",
    },
    // Black-and-white negative.
    .{
        .name = "Kodak Tri-X 400",
        .maker = "Kodak",
        .kind = .bw_negative,
        .iso = 400,
        .base_density = .{ 0.316, 0.316, 0.316 },
        .gamma = .{ 0.583, 0.583, 0.583 },
        .density_range = .{ 1.762, 1.762, 1.762 },
        .curves = curve_data.kodak_tri_x_400,
        .source = "Kodak F-4017 (October 2021), 35 mm, diffuse visual; KODAK PROFESSIONAL T-MAX Developer, small tank, 6 min, 20 °C (the starting point, stated to give contrast index 0.56); curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak T-Max 100",
        .maker = "Kodak",
        .kind = .bw_negative,
        .iso = 100,
        .base_density = .{ 0.208, 0.208, 0.208 },
        .gamma = .{ 0.556, 0.556, 0.556 },
        .density_range = .{ 1.546, 1.546, 1.546 },
        .curves = curve_data.kodak_t_max_100,
        .source = "Kodak F-4016 (June 2018), diffuse visual; D-76, small tank, 6 min, 20 °C (the sheet prints curves for 6, 7.5 and 10 min; its D-76 starting point is 6½ min, which has no curve); curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak T-Max 400",
        .maker = "Kodak",
        .kind = .bw_negative,
        .iso = 400,
        .base_density = .{ 0.270, 0.270, 0.270 },
        .gamma = .{ 0.746, 0.746, 0.746 },
        .density_range = .{ 1.994, 1.994, 1.994 },
        .curves = curve_data.kodak_t_max_400,
        .source = "Kodak F-4043 (February 2016), diffuse visual; T-MAX RS Developer and Replenisher, large tank, 5 min, 24 °C (the starting point for that developer); curves digitised for minilab from the vector drawing in the PDF; log H in lux-seconds",
    },
    .{
        .name = "Kodak T-Max P3200",
        .maker = "Kodak",
        .kind = .bw_negative,
        .iso = 3200,
        .base_density = .{ 0.296, 0.296, 0.296 },
        .gamma = .{ 0.816, 0.816, 0.816 },
        .density_range = .{ 2.704, 2.704, 2.704 },
        .curves = curve_data.kodak_t_max_p3200,
        .source = "Kodak Alaris F-4001 (March 2018), diffuse visual; KODAK PROFESSIONAL T-MAX Developer, small tank, 12 min, 20 °C (the table's starting point for EI 3200); curve read for minilab from the vector drawing in the PDF; log H in lux-seconds. The curve leaves the chart at density 3.0. The July 2018 and April 2019 editions print an older set of curves (8, 9, 11 and 13 min), none at a table time",
    },
    .{
        .name = "Eastman Double-X 5222",
        .maker = "Kodak",
        .kind = .bw_negative,
        .iso = 250,
        .base_density = null,
        .gamma = .{ 0.65, 0.65, 0.65 },
        .density_range = null,
        .curves = null,
        .source = "Kodak H-1-5222 (March 2026): its exposure indexes assume development to gamma 0.65; D-96, 7 min, 21 °C. Gamma measured with Status M (blue), not visual density. No base or range stated; curves are a raster image",
    },
    .{
        .name = "Ilford Delta 400 Professional",
        .maker = "Ilford",
        .kind = .bw_negative,
        .iso = 400,
        .base_density = null,
        .gamma = .{ 0.62, 0.62, 0.62 },
        .density_range = null,
        .curves = null,
        .source = "Harman/Ilford Delta 400 datasheet (Nov 2018): the development times printed in bold give normal contrast, G-bar 0.62, e.g. ID-11 stock, 9½ min, 20 °C. G-bar is an average gradient; densitometry not stated; curves are a raster image",
    },
    .{
        .name = "Ilford Ortho Plus",
        .maker = "Ilford",
        .kind = .bw_negative,
        .iso = 80,
        .base_density = .{ 0.071, 0.071, 0.071 },
        .gamma = .{ 0.648, 0.648, 0.648 },
        .density_range = .{ 1.420, 1.420, 1.420 },
        .curves = curve_data.ilford_ortho_plus,
        .source = "Harman/Ilford Ortho Plus datasheet (October 2019), ID-11 stock, 8 min, 20 °C, intermittent agitation: the curve the chart labels G-bar 0.62, the low end of the 0.62 to 0.70 Ilford calls normal for camera use. The densitometry is not stated; curve read for minilab from the 199 ppi chart image in the PDF (reads at 600 and 300 dpi agree within 0.01 D); the 8 and 10 min curves run together in the toe and share one reading there; log H relative (\"relative log exposure\")",
    },
    .{
        .name = "Ilford HP5 Plus",
        .maker = "Ilford",
        .kind = .bw_negative,
        .iso = 400,
        .base_density = .{ 0.178, 0.178, 0.178 },
        .gamma = .{ 0.641, 0.641, 0.641 },
        .density_range = .{ 1.966, 1.966, 1.966 },
        .curves = curve_data.ilford_hp5_plus,
        .source = "Ilford HP5 Plus datasheet (April 2010 edition), 35 mm, ILFOTEC HC 1+31, 6.5 min, 20 °C, intermittent agitation; Ilford does not say how density was measured; curve read for minilab from the vector drawing in the PDF. The November 2018 edition prints the same curve as an image (a raster reading agrees within 0.005 D); log H relative (\"relative log exposure\")",
    },
    .{
        .name = "Ilford FP4 Plus",
        .maker = "Ilford",
        .kind = .bw_negative,
        .iso = 125,
        .base_density = .{ 0.095, 0.095, 0.095 },
        .gamma = .{ 0.762, 0.762, 0.762 },
        .density_range = .{ 1.767, 1.767, 1.767 },
        .curves = curve_data.ilford_fp4_plus,
        .source = "Ilford FP4 Plus datasheet (July 2010 edition), rollfilm, ILFOTEC HC 1+31, 8 min, 20 °C, intermittent agitation; Ilford does not say how density was measured; curve read for minilab from the vector drawing in the PDF; log H relative (\"relative log exposure\")",
    },
    .{
        .name = "Ilford Pan F Plus",
        .maker = "Ilford",
        .kind = .bw_negative,
        .iso = 50,
        .base_density = .{ 0.060, 0.060, 0.060 },
        .gamma = .{ 0.824, 0.824, 0.824 },
        .density_range = .{ 1.862, 1.862, 1.862 },
        .curves = curve_data.ilford_pan_f_plus,
        .source = "Ilford Pan F Plus datasheet (June 2010 edition), rollfilm, ILFOTEC HC 1+31, 4 min, 20 °C, intermittent agitation; Ilford does not say how density was measured; curve read for minilab from the vector drawing in the PDF; log H relative (\"relative log exposure\")",
    },
    .{
        .name = "Ilford Delta 100 Professional",
        .maker = "Ilford",
        .kind = .bw_negative,
        .iso = 100,
        .base_density = .{ 0.077, 0.077, 0.077 },
        .gamma = .{ 0.776, 0.776, 0.776 },
        .density_range = .{ 1.732, 1.732, 1.732 },
        .curves = curve_data.ilford_delta_100,
        .source = "Ilford Delta 100 Professional datasheet (April 2023), rollfilm, ID-11 stock, 8.5 min, 20 °C (the table's time for EI 100), intermittent agitation; Ilford does not say how density was measured; curve read for minilab from the 168 ppi chart image in the PDF (its gridlines are uneven by up to 0.016 log H; reads at 600 and 300 dpi agree within 0.01 D); log H relative (\"relative log exposure\")",
    },
    .{
        .name = "Ilford Delta 3200 Professional",
        .maker = "Ilford",
        .kind = .bw_negative,
        .iso = 3200,
        .base_density = .{ 0.277, 0.277, 0.277 },
        .gamma = .{ 0.671, 0.671, 0.671 },
        .density_range = .{ 1.848, 1.848, 1.848 },
        .curves = curve_data.ilford_delta_3200,
        .source = "Ilford Delta 3200 Professional datasheet (May 2010 edition), MICROPHEN stock, 9 min, 20 °C (the table's time for EI 3200; the chart also shows 7, 12 and 16 min), intermittent agitation; Ilford does not say how density was measured; curve read for minilab from the vector drawing in the PDF; log H relative (\"relative log exposure\")",
    },
    .{
        .name = "Ilford XP2 Super",
        .maker = "Ilford",
        .kind = .bw_negative,
        .iso = 400,
        .base_density = .{ 0.267, 0.267, 0.267 },
        .gamma = .{ 0.699, 0.699, 0.699 },
        .density_range = .{ 1.630, 1.630, 1.630 },
        .curves = curve_data.ilford_xp2_super,
        .source = "Ilford XP2 Super datasheet (June 2010 edition), chromogenic, standard C-41 chemicals; Ilford does not say how density was measured; curve read for minilab from the vector drawing in the PDF; log H relative (\"relative log exposure\")",
    },
    .{
        .name = "Ilford SFX 200",
        .maker = "Ilford",
        .kind = .bw_negative,
        .iso = 200,
        .base_density = .{ 0.286, 0.286, 0.286 },
        .gamma = .{ 0.679, 0.679, 0.679 },
        .density_range = .{ 2.012, 2.012, 2.012 },
        .curves = curve_data.ilford_sfx_200,
        .source = "Ilford SFX 200 datasheet (November 2018), ID-11 stock, 10 min, 20 °C, intermittent agitation; Ilford does not say how density was measured; curve read for minilab from the 185 ppi chart image in the PDF (reads at 600 and 300 dpi agree within 0.002 D); log H relative (\"relative log exposure\")",
    },
    .{
        .name = "Fujifilm Acros 100 II",
        .maker = "Fujifilm",
        .kind = .bw_negative,
        .iso = 100,
        .base_density = .{ 0.131, 0.131, 0.131 },
        .gamma = .{ 0.571, 0.571, 0.571 },
        .density_range = .{ 1.561, 1.561, 1.561 },
        .curves = curve_data.fujifilm_acros_100_ii,
        .source = "Fujifilm AF3-0258E (February 2020), Microfine, small tank, 10 min, 20 °C (the table's time for EI 100; the chart also shows 5, 15 and 20 min); the densitometry is not stated; curve read for minilab from the chart image in the PDF (reads at 600 and 300 dpi agree within 0.04 D); the four curves run together in the toe and share one reading there; log H in lux-seconds",
    },
    .{
        .name = "Fomapan 100 Classic",
        .maker = "Foma",
        .kind = .bw_negative,
        .iso = 100,
        .base_density = null,
        .gamma = .{ 0.66, 0.66, 0.66 },
        .density_range = null,
        .curves = curve_data.foma_fomapan_100,
        .source = "Foma FOMAPAN 100 Classic datasheet (05/22) curve: Ilford Microphen stock, 7 min, 20 °C (curve 2), digitised from the vector drawing; log H relative. Gamma: Foma catalogue (2020), Microphen stock 5 to 7 min for γ 0.60 to 0.66, upper time for upper gradient. The same drawing is printed in the 100, 200 and 400 sheets and is steeper (about 0.96) than the stated γ, so treat the curve as a shape only. No base + fog density is published",
    },
    .{
        .name = "Fomapan 200 Creative",
        .maker = "Foma",
        .kind = .bw_negative,
        .iso = 200,
        .base_density = null,
        .gamma = .{ 0.64, 0.64, 0.64 },
        .density_range = null,
        .curves = curve_data.foma_fomapan_200,
        .source = "Foma FOMAPAN 200 Creative datasheet (05/22) curve: Ilford Microphen stock, 6 min, 20 °C (curve 2), digitised from the vector drawing; log H relative. Gamma: Foma catalogue (2020), Microphen stock 5 to 6 min for γ 0.58 to 0.64, upper time for upper gradient. The same drawing is printed in the 100, 200 and 400 sheets and is steeper (about 0.96) than the stated γ, so treat the curve as a shape only. No base + fog density is published",
    },
    .{
        .name = "Fomapan 400 Action",
        .maker = "Foma",
        .kind = .bw_negative,
        .iso = 400,
        .base_density = null,
        .gamma = .{ 0.69, 0.69, 0.69 },
        .density_range = null,
        .curves = curve_data.foma_fomapan_400,
        .source = "Foma FOMAPAN 400 Action datasheet (04/23) curve: Ilford Microphen stock, 9 min, 20 °C (curve 2), digitised from the vector drawing; log H relative. Gamma: Foma catalogue (2020), Microphen stock 8 to 9 min for γ 0.66 to 0.69, upper time for upper gradient. The same drawing is printed in the 100, 200 and 400 sheets and is steeper (about 0.96) than the stated γ, so treat the curve as a shape only. No base + fog density is published",
    },
    .{
        .name = "Rollei RPX 25",
        .maker = "Rollei",
        .kind = .bw_negative,
        .iso = 25,
        .base_density = null,
        .gamma = .{ 0.65, 0.65, 0.65 },
        .density_range = null,
        .curves = null,
        .source = "Rollei RPX 25 datasheet (R210701): development times are for an average contrast γ 0.65; Rollei Supergrain 1+12, 5½ min, 20 °C. Densitometry not stated; no curves",
    },
    .{
        .name = "Rollei RPX 100",
        .maker = "Rollei",
        .kind = .bw_negative,
        .iso = 100,
        .base_density = null,
        .gamma = .{ 0.65, 0.65, 0.65 },
        .density_range = null,
        .curves = null,
        .source = "Rollei RPX 100 datasheet (R210701): development times are for an average contrast γ 0.65; Rollei Supergrain 1+12, 6½ min, 20 °C. Densitometry not stated; no curves",
    },
    .{
        .name = "Rollei RPX 400",
        .maker = "Rollei",
        .kind = .bw_negative,
        .iso = 400,
        .base_density = null,
        .gamma = .{ 0.65, 0.65, 0.65 },
        .density_range = null,
        .curves = null,
        .source = "Rollei RPX 400 datasheet (R210701): development times are for an average contrast γ 0.65; Rollei Supergrain 1+12, 7 min, 20 °C. Densitometry not stated; no curves",
    },
    .{
        .name = "Rollei Retro 80S",
        .maker = "Rollei",
        .kind = .bw_negative,
        .iso = 80,
        .base_density = null,
        .gamma = .{ 0.65, 0.65, 0.65 },
        .density_range = null,
        .curves = null,
        .source = "Rollei Retro 80S datasheet (R210701): development times are for an average contrast γ 0.65; Rollei Supergrain 1+12, 8 min, 20 °C. Densitometry not stated; no curves",
    },
    .{
        .name = "Rollei Retro 400S",
        .maker = "Rollei",
        .kind = .bw_negative,
        .iso = 400,
        .base_density = null,
        .gamma = .{ 0.65, 0.65, 0.65 },
        .density_range = null,
        .curves = null,
        .source = "Rollei Retro 400S datasheet (R210701): development times are for an average contrast γ 0.65; Rollei Supergrain 1+12, 10 min, 20 °C. Densitometry not stated; no curves",
    },
    .{
        .name = "Rollei Infrared",
        .maker = "Rollei",
        .kind = .bw_negative,
        .iso = 400,
        .base_density = null,
        .gamma = .{ 0.65, 0.65, 0.65 },
        .density_range = null,
        .curves = null,
        .source = "Rollei Infrared datasheet (2025, R210701): development times are for an average contrast γ 0.65; Rollei Supergrain 1+12, 11 min, 20 °C, at ISO 400 (nominal ISO 200 to 400). Densitometry not stated; no curves",
    },
    .{
        .name = "ADOX CHS 100 II",
        .maker = "ADOX",
        .kind = .bw_negative,
        .iso = 100,
        .base_density = null,
        .gamma = .{ 0.65, 0.65, 0.65 },
        .density_range = null,
        .curves = null,
        .source = "ADOX CHS 100 II datasheet (11 July 2024): beta (mean gradient) 0.65 for its listed developments, e.g. ADOX ADONAL 1+25, 5½ to 6 min, 20 °C. Densitometry not stated; no curves",
    },
    // Black-and-white positive.
    .{
        .name = "Fomapan R 100",
        .maker = "Foma",
        .kind = .bw_positive,
        .iso = 100,
        .base_density = null,
        .gamma = .{ 1.10, 1.10, 1.10 },
        .density_range = null,
        .curves = curve_data.foma_fomapan_r_100,
        .source = "Foma FOMAPAN R datasheet (01/25): gradation 1.1 on the straight part; process R-100 (first developer Fomadon LQR 1+10, 9 to 10 min, 20 °C). Densitometry not stated. Curve digitised from the vector drawing; log H relative. The drawn curve is steeper (about 1.6) than the stated 1.1 and levels off at neither end, so D-min and D-max are unknown",
    },
};

/// The characteristic curves, kept separate from the table so the table stays readable. Each
/// channel is a log exposure grid plus the densities on it.
const curve_data = struct {
    const kodak_portra_160: [3][]const Point = .{
        sampled(&.{
            -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100,
            -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100,
            -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100,
            0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,  0.900,
        }, &.{
            0.200, 0.201, 0.203, 0.208, 0.213, 0.217, 0.227, 0.242, 0.267, 0.302,
            0.345, 0.396, 0.444, 0.492, 0.541, 0.592, 0.644, 0.698, 0.751, 0.803,
            0.855, 0.909, 0.962, 1.015, 1.069, 1.123, 1.178, 1.234, 1.290, 1.347,
            1.398, 1.445, 1.490, 1.534, 1.576, 1.615, 1.653, 1.690, 1.727, 1.763,
        }),
        sampled(&.{
            -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100,
            -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100,
            -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100,
            0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,  0.900,
        }, &.{
            0.616, 0.616, 0.618, 0.621, 0.625, 0.628, 0.640, 0.661, 0.692, 0.735,
            0.785, 0.843, 0.898, 0.953, 1.007, 1.060, 1.114, 1.167, 1.221, 1.273,
            1.327, 1.382, 1.437, 1.492, 1.548, 1.604, 1.659, 1.715, 1.771, 1.829,
            1.882, 1.933, 1.984, 2.036, 2.088, 2.139, 2.190, 2.241, 2.291, 2.339,
        }),
        sampled(&.{
            -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100,
            -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100,
            -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100,
            0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,  0.900,
        }, &.{
            0.837, 0.847, 0.853, 0.851, 0.853, 0.861, 0.883, 0.918, 0.965, 1.023,
            1.082, 1.143, 1.203, 1.262, 1.320, 1.377, 1.434, 1.490, 1.546, 1.602,
            1.661, 1.722, 1.784, 1.847, 1.911, 1.976, 2.040, 2.106, 2.172, 2.240,
            2.303, 2.363, 2.424, 2.485, 2.546, 2.606, 2.667, 2.729, 2.792, 2.854,
        }),
    };
    const kodak_portra_400: [3][]const Point = .{
        sampled(&.{
            -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500,
            -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
            -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
            -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,
        }, &.{
            0.220, 0.223, 0.226, 0.230, 0.234, 0.238, 0.250, 0.269, 0.299, 0.340,
            0.388, 0.441, 0.493, 0.544, 0.595, 0.646, 0.698, 0.751, 0.804, 0.857,
            0.910, 0.964, 1.019, 1.073, 1.127, 1.182, 1.238, 1.294, 1.350, 1.406,
            1.462, 1.519, 1.576, 1.633, 1.690, 1.747, 1.804, 1.862, 1.920, 1.979,
        }),
        sampled(&.{
            -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500,
            -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
            -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
            -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,
        }, &.{
            0.647, 0.648, 0.651, 0.655, 0.660, 0.665, 0.679, 0.702, 0.735, 0.779,
            0.829, 0.885, 0.941, 0.997, 1.053, 1.109, 1.165, 1.220, 1.276, 1.331,
            1.386, 1.442, 1.497, 1.553, 1.608, 1.663, 1.718, 1.772, 1.827, 1.883,
            1.938, 1.992, 2.046, 2.100, 2.154, 2.209, 2.264, 2.318, 2.373, 2.427,
        }),
        sampled(&.{
            -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500,
            -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
            -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
            -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,
        }, &.{
            0.868, 0.871, 0.874, 0.878, 0.890, 0.910, 0.941, 0.986, 1.039, 1.098,
            1.159, 1.222, 1.284, 1.347, 1.410, 1.472, 1.536, 1.599, 1.662, 1.725,
            1.788, 1.852, 1.915, 1.979, 2.043, 2.107, 2.171, 2.235, 2.299, 2.363,
            2.427, 2.491, 2.556, 2.621, 2.686, 2.750, 2.814, 2.879, 2.944, 3.010,
        }),
    };
    const kodak_portra_800: [3][]const Point = .{
        sampled(&.{
            -3.700, -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800,
            -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800,
            -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800,
            -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.308, 0.308, 0.308, 0.307, 0.309, 0.317, 0.329, 0.349, 0.374, 0.406,
            0.441, 0.481, 0.525, 0.574, 0.623, 0.674, 0.725, 0.775, 0.826, 0.877,
            0.928, 0.980, 1.033, 1.086, 1.138, 1.191, 1.243, 1.294, 1.345, 1.397,
            1.449, 1.502, 1.555, 1.607, 1.659, 1.710, 1.761, 1.810, 1.859, 1.907,
        }),
        sampled(&.{
            -3.700, -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800,
            -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800,
            -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800,
            -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.706, 0.706, 0.706, 0.705, 0.709, 0.719, 0.736, 0.761, 0.792, 0.832,
            0.877, 0.928, 0.980, 1.034, 1.089, 1.145, 1.199, 1.254, 1.307, 1.360,
            1.413, 1.465, 1.517, 1.570, 1.623, 1.676, 1.729, 1.782, 1.835, 1.889,
            1.943, 1.998, 2.051, 2.104, 2.155, 2.204, 2.251, 2.297, 2.341, 2.384,
        }),
        sampled(&.{
            -3.700, -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800,
            -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800,
            -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800,
            -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            1.021, 1.021, 1.021, 1.021, 1.024, 1.031, 1.046, 1.070, 1.101, 1.139,
            1.182, 1.232, 1.284, 1.339, 1.395, 1.453, 1.512, 1.572, 1.631, 1.691,
            1.750, 1.809, 1.869, 1.930, 1.991, 2.054, 2.116, 2.177, 2.238, 2.300,
            2.362, 2.424, 2.486, 2.546, 2.606, 2.664, 2.722, 2.782, 2.844, 2.910,
        }),
    };
    const kodak_portra_800_push_1: [3][]const Point = .{
        sampled(&.{
            -3.700, -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800,
            -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800,
            -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800,
            -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.244, 0.249, 0.255, 0.262, 0.273, 0.287, 0.311, 0.344, 0.384, 0.430,
            0.483, 0.543, 0.605, 0.668, 0.732, 0.794, 0.856, 0.919, 0.983, 1.048,
            1.112, 1.174, 1.235, 1.292, 1.353, 1.415, 1.478, 1.542, 1.609, 1.679,
            1.746, 1.809, 1.871, 1.933, 1.993, 2.051, 2.108, 2.164, 2.218, 2.270,
        }),
        sampled(&.{
            -3.700, -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800,
            -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800,
            -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800,
            -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.666, 0.668, 0.671, 0.676, 0.684, 0.697, 0.720, 0.753, 0.797, 0.853,
            0.918, 0.990, 1.059, 1.126, 1.189, 1.249, 1.310, 1.377, 1.444, 1.515,
            1.584, 1.651, 1.715, 1.775, 1.838, 1.903, 1.964, 2.019, 2.074, 2.129,
            2.186, 2.243, 2.302, 2.363, 2.419, 2.467, 2.515, 2.564, 2.610, 2.650,
        }),
        sampled(&.{
            -3.700, -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800,
            -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800,
            -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800,
            -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            1.017, 1.023, 1.029, 1.036, 1.047, 1.062, 1.084, 1.117, 1.157, 1.203,
            1.259, 1.325, 1.392, 1.462, 1.533, 1.603, 1.670, 1.736, 1.805, 1.875,
            1.944, 2.013, 2.085, 2.161, 2.238, 2.315, 2.394, 2.474, 2.550, 2.622,
            2.692, 2.763, 2.833, 2.906, 2.973, 3.033, 3.090, 3.146, 3.199, 3.252,
        }),
    };
    const kodak_portra_800_push_2: [3][]const Point = .{
        sampled(&.{
            -3.700, -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800,
            -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800,
            -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800,
            -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.301, 0.309, 0.317, 0.326, 0.338, 0.353, 0.379, 0.417, 0.462, 0.513,
            0.571, 0.637, 0.704, 0.774, 0.844, 0.910, 0.978, 1.047, 1.113, 1.179,
            1.247, 1.318, 1.386, 1.451, 1.517, 1.585, 1.657, 1.736, 1.810, 1.877,
            1.947, 2.021, 2.089, 2.153, 2.213, 2.271, 2.329, 2.387, 2.441, 2.493,
        }),
        sampled(&.{
            -3.700, -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800,
            -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800,
            -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800,
            -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.696, 0.702, 0.708, 0.714, 0.723, 0.735, 0.761, 0.803, 0.855, 0.918,
            0.990, 1.074, 1.154, 1.232, 1.304, 1.369, 1.438, 1.514, 1.590, 1.670,
            1.747, 1.819, 1.889, 1.958, 2.027, 2.095, 2.160, 2.223, 2.284, 2.344,
            2.405, 2.472, 2.534, 2.593, 2.647, 2.698, 2.742, 2.780, 2.817, 2.853,
        }),
        sampled(&.{
            -3.700, -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800,
            -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800,
            -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800,
            -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            1.053, 1.063, 1.072, 1.081, 1.091, 1.105, 1.129, 1.165, 1.210, 1.260,
            1.320, 1.391, 1.465, 1.546, 1.623, 1.700, 1.777, 1.851, 1.926, 2.000,
            2.076, 2.156, 2.235, 2.313, 2.393, 2.474, 2.556, 2.642, 2.725, 2.803,
            2.881, 2.962, 3.033, 3.092, 3.152, 3.213, 3.272, 3.329, 3.387, 3.449,
        }),
    };
    const kodak_ektar_100: [3][]const Point = .{
        sampled(&.{
            -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900,
            -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900,
            -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,
            0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,  0.900,  1.000,  1.100,
        }, &.{
            0.210, 0.213, 0.216, 0.219, 0.224, 0.233, 0.246, 0.266, 0.295, 0.334,
            0.381, 0.430, 0.481, 0.534, 0.588, 0.645, 0.703, 0.765, 0.829, 0.893,
            0.953, 1.011, 1.067, 1.121, 1.175, 1.229, 1.285, 1.343, 1.396, 1.447,
            1.499, 1.551, 1.603, 1.653, 1.701, 1.747, 1.789, 1.829, 1.869, 1.909,
        }),
        sampled(&.{
            -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900,
            -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900,
            -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,
            0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,  0.900,  1.000,  1.100,
        }, &.{
            0.635, 0.637, 0.639, 0.640, 0.644, 0.653, 0.667, 0.690, 0.721, 0.761,
            0.812, 0.868, 0.927, 0.986, 1.046, 1.105, 1.164, 1.222, 1.280, 1.338,
            1.397, 1.456, 1.515, 1.574, 1.632, 1.689, 1.743, 1.796, 1.849, 1.901,
            1.953, 2.003, 2.053, 2.102, 2.150, 2.198, 2.245, 2.292, 2.339, 2.385,
        }),
        sampled(&.{
            -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900,
            -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900,
            -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,
            0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,  0.900,  1.000,  1.100,
        }, &.{
            0.850, 0.863, 0.871, 0.871, 0.877, 0.893, 0.921, 0.965, 1.017, 1.080,
            1.142, 1.197, 1.261, 1.341, 1.413, 1.478, 1.542, 1.607, 1.671, 1.736,
            1.802, 1.868, 1.936, 2.004, 2.073, 2.140, 2.208, 2.274, 2.338, 2.400,
            2.460, 2.519, 2.577, 2.635, 2.694, 2.754, 2.815, 2.879, 2.948, 3.021,
        }),
    };
    const kodak_gold_200: [3][]const Point = .{
        sampled(&.{
            -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100,
            -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100,
            -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100,
            0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,
        }, &.{
            0.251, 0.255, 0.259, 0.265, 0.274, 0.289, 0.310, 0.338, 0.373, 0.414,
            0.460, 0.511, 0.565, 0.619, 0.672, 0.726, 0.779, 0.833, 0.886, 0.941,
            0.995, 1.050, 1.105, 1.160, 1.216, 1.272, 1.327, 1.383, 1.440, 1.496,
            1.545, 1.589, 1.627, 1.661, 1.693, 1.722, 1.752, 1.782, 1.812,
        }),
        sampled(&.{
            -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100,
            -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100,
            -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100,
            0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,
        }, &.{
            0.657, 0.660, 0.666, 0.672, 0.685, 0.706, 0.734, 0.768, 0.807, 0.852,
            0.901, 0.952, 1.008, 1.064, 1.121, 1.179, 1.236, 1.293, 1.350, 1.407,
            1.464, 1.521, 1.578, 1.635, 1.691, 1.747, 1.804, 1.859, 1.915, 1.969,
            2.020, 2.065, 2.104, 2.137, 2.167, 2.195, 2.224, 2.254, 2.284,
        }),
        sampled(&.{
            -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100,
            -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100,
            -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100,
            0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,
        }, &.{
            0.991, 0.990, 0.973, 0.962, 0.966, 0.983, 1.008, 1.041, 1.081, 1.129,
            1.185, 1.246, 1.306, 1.367, 1.428, 1.490, 1.556, 1.626, 1.702, 1.763,
            1.812, 1.866, 1.923, 1.984, 2.047, 2.111, 2.174, 2.237, 2.299, 2.361,
            2.418, 2.469, 2.513, 2.551, 2.585, 2.618, 2.652, 2.687, 2.722,
        }),
    };
    const kodak_ultramax_400: [3][]const Point = .{
        sampled(&.{
            -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500,
            -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
            -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
            -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,
        }, &.{
            0.285, 0.285, 0.286, 0.290, 0.299, 0.315, 0.338, 0.365, 0.400, 0.438,
            0.480, 0.526, 0.573, 0.622, 0.673, 0.724, 0.773, 0.822, 0.873, 0.924,
            0.977, 1.029, 1.082, 1.134, 1.186, 1.238, 1.289, 1.341, 1.393, 1.446,
            1.498, 1.550, 1.601, 1.650, 1.698, 1.745, 1.792, 1.838, 1.878, 1.910,
        }),
        sampled(&.{
            -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500,
            -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
            -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
            -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,
        }, &.{
            0.693, 0.692, 0.695, 0.700, 0.713, 0.733, 0.760, 0.794, 0.834, 0.878,
            0.927, 0.978, 1.033, 1.089, 1.144, 1.200, 1.254, 1.307, 1.360, 1.413,
            1.466, 1.520, 1.574, 1.628, 1.682, 1.736, 1.790, 1.844, 1.899, 1.954,
            2.008, 2.062, 2.112, 2.160, 2.207, 2.252, 2.297, 2.340, 2.381, 2.417,
        }),
        sampled(&.{
            -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500,
            -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
            -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
            -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,
        }, &.{
            0.980, 0.979, 0.981, 0.985, 0.997, 1.018, 1.045, 1.080, 1.121, 1.167,
            1.217, 1.272, 1.327, 1.384, 1.442, 1.500, 1.558, 1.615, 1.675, 1.734,
            1.794, 1.855, 1.916, 1.977, 2.038, 2.098, 2.159, 2.219, 2.279, 2.340,
            2.399, 2.458, 2.519, 2.582, 2.644, 2.705, 2.766, 2.827, 2.885, 2.936,
        }),
    };
    const kodak_vision3_50d: [3][]const Point = .{
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.170, 0.171, 0.172, 0.171, 0.177, 0.195, 0.226, 0.274, 0.334, 0.409,
            0.490, 0.570, 0.648, 0.717, 0.785, 0.858, 0.932, 1.005, 1.078, 1.151,
            1.224, 1.298, 1.370, 1.443, 1.513, 1.581, 1.644, 1.698, 1.746, 1.787,
            1.823, 1.851, 1.877,
        }),
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.575, 0.576, 0.576, 0.576, 0.581, 0.597, 0.629, 0.685, 0.755, 0.837,
            0.924, 1.011, 1.097, 1.182, 1.267, 1.353, 1.440, 1.526, 1.613, 1.701,
            1.788, 1.875, 1.962, 2.049, 2.134, 2.216, 2.293, 2.362, 2.424, 2.478,
            2.526, 2.565, 2.600,
        }),
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.847, 0.848, 0.850, 0.852, 0.861, 0.881, 0.915, 0.970, 1.037, 1.112,
            1.192, 1.274, 1.357, 1.434, 1.511, 1.595, 1.679, 1.762, 1.844, 1.930,
            2.017, 2.103, 2.189, 2.274, 2.358, 2.439, 2.515, 2.582, 2.641, 2.691,
            2.734, 2.769, 2.799,
        }),
    };
    const kodak_vision3_250d: [3][]const Point = .{
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.177, 0.180, 0.185, 0.191, 0.208, 0.232, 0.261, 0.296, 0.341, 0.397,
            0.465, 0.536, 0.606, 0.677, 0.749, 0.820, 0.891, 0.962, 1.034, 1.105,
            1.176, 1.247, 1.318, 1.388, 1.455, 1.519, 1.579, 1.638, 1.693, 1.741,
            1.780, 1.813, 1.843,
        }),
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.577, 0.581, 0.586, 0.592, 0.610, 0.636, 0.669, 0.708, 0.759, 0.823,
            0.904, 0.986, 1.069, 1.152, 1.235, 1.319, 1.402, 1.485, 1.569, 1.652,
            1.735, 1.819, 1.903, 1.986, 2.066, 2.143, 2.217, 2.289, 2.357, 2.418,
            2.468, 2.512, 2.553,
        }),
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.843, 0.847, 0.850, 0.851, 0.868, 0.893, 0.921, 0.957, 1.005, 1.071,
            1.152, 1.237, 1.320, 1.399, 1.480, 1.560, 1.641, 1.721, 1.801, 1.881,
            1.962, 2.043, 2.125, 2.205, 2.282, 2.356, 2.426, 2.494, 2.560, 2.616,
            2.658, 2.697, 2.732,
        }),
    };
    const kodak_vision3_200t: [3][]const Point = .{
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.178, 0.180, 0.183, 0.187, 0.194, 0.202, 0.220, 0.254, 0.301, 0.361,
            0.428, 0.498, 0.571, 0.645, 0.718, 0.789, 0.860, 0.932, 1.004, 1.074,
            1.144, 1.215, 1.285, 1.356, 1.425, 1.494, 1.559, 1.618, 1.671, 1.717,
            1.759, 1.792, 1.823,
        }),
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.580, 0.582, 0.585, 0.590, 0.596, 0.603, 0.620, 0.659, 0.713, 0.781,
            0.859, 0.940, 1.025, 1.112, 1.198, 1.281, 1.363, 1.446, 1.530, 1.613,
            1.696, 1.778, 1.861, 1.944, 2.027, 2.109, 2.187, 2.259, 2.326, 2.386,
            2.440, 2.485, 2.526,
        }),
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.847, 0.849, 0.852, 0.857, 0.864, 0.874, 0.893, 0.930, 0.980, 1.045,
            1.119, 1.197, 1.278, 1.360, 1.442, 1.521, 1.600, 1.681, 1.761, 1.840,
            1.919, 1.999, 2.079, 2.159, 2.238, 2.316, 2.392, 2.461, 2.524, 2.580,
            2.629, 2.669, 2.706,
        }),
    };
    const kodak_vision3_500t: [3][]const Point = .{
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.190, 0.193, 0.198, 0.204, 0.221, 0.245, 0.275, 0.309, 0.355, 0.410,
            0.478, 0.548, 0.618, 0.688, 0.759, 0.829, 0.900, 0.972, 1.043, 1.114,
            1.186, 1.257, 1.329, 1.400, 1.468, 1.532, 1.593, 1.652, 1.707, 1.757,
            1.797, 1.831, 1.861,
        }),
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.585, 0.587, 0.591, 0.598, 0.617, 0.644, 0.677, 0.716, 0.768, 0.832,
            0.914, 0.996, 1.080, 1.163, 1.247, 1.331, 1.415, 1.498, 1.580, 1.663,
            1.746, 1.829, 1.913, 1.996, 2.076, 2.152, 2.225, 2.297, 2.364, 2.425,
            2.476, 2.520, 2.560,
        }),
        sampled(&.{
            -2.400, -2.250, -2.100, -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050,
            -0.900, -0.750, -0.600, -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,
            0.600,  0.750,  0.900,  1.050,  1.200,  1.350,  1.500,  1.650,  1.800,  1.950,
            2.100,  2.250,  2.400,
        }, &.{
            0.840, 0.843, 0.847, 0.849, 0.866, 0.891, 0.919, 0.955, 1.003, 1.070,
            1.151, 1.237, 1.321, 1.402, 1.482, 1.562, 1.642, 1.722, 1.802, 1.882,
            1.963, 2.045, 2.128, 2.209, 2.287, 2.362, 2.432, 2.501, 2.567, 2.623,
            2.665, 2.705, 2.743,
        }),
    };
    const kodak_verita_200d: [3][]const Point = .{
        sampled(&.{
            -2.915, -2.765, -2.615, -2.465, -2.315, -2.165, -2.015, -1.865, -1.715, -1.565,
            -1.415, -1.265, -1.115, -0.965, -0.815, -0.665, -0.515, -0.365, -0.215, -0.065,
            0.085,  0.235,  0.385,  0.535,  0.685,  0.835,  0.985,  1.135,  1.285,  1.435,
            1.585,  1.735,  1.885,
        }, &.{
            0.214, 0.220, 0.227, 0.243, 0.269, 0.315, 0.377, 0.456, 0.548, 0.649,
            0.740, 0.825, 0.900, 0.971, 1.041, 1.111, 1.182, 1.251, 1.320, 1.390,
            1.466, 1.546, 1.626, 1.704, 1.781, 1.853, 1.918, 1.971, 2.013, 2.049,
            2.072, 2.085, 2.105,
        }),
        sampled(&.{
            -2.915, -2.765, -2.615, -2.465, -2.315, -2.165, -2.015, -1.865, -1.715, -1.565,
            -1.415, -1.265, -1.115, -0.965, -0.815, -0.665, -0.515, -0.365, -0.215, -0.065,
            0.085,  0.235,  0.385,  0.535,  0.685,  0.835,  0.985,  1.135,  1.285,  1.435,
            1.585,  1.735,  1.885,
        }, &.{
            0.660, 0.663, 0.669, 0.680, 0.701, 0.746, 0.808, 0.885, 0.965, 1.045,
            1.125, 1.204, 1.283, 1.357, 1.426, 1.495, 1.563, 1.630, 1.698, 1.769,
            1.844, 1.922, 1.997, 2.068, 2.135, 2.196, 2.248, 2.286, 2.316, 2.340,
            2.354, 2.361, 2.378,
        }),
        sampled(&.{
            -2.915, -2.765, -2.615, -2.465, -2.315, -2.165, -2.015, -1.865, -1.715, -1.565,
            -1.415, -1.265, -1.115, -0.965, -0.815, -0.665, -0.515, -0.365, -0.215, -0.065,
            0.085,  0.235,  0.385,  0.535,  0.685,  0.835,  0.985,  1.135,  1.285,  1.435,
            1.585,  1.735,  1.885,
        }, &.{
            0.916, 0.924, 0.934, 0.950, 0.973, 1.015, 1.071, 1.145, 1.227, 1.313,
            1.399, 1.488, 1.581, 1.674, 1.763, 1.852, 1.940, 2.032, 2.124, 2.216,
            2.312, 2.407, 2.495, 2.578, 2.653, 2.728, 2.802, 2.863, 2.917, 2.967,
            3.007, 3.041, 3.087,
        }),
    };
    const fujifilm_200: [3][]const Point = .{
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.133, 0.136, 0.142, 0.149, 0.159, 0.169, 0.182, 0.197, 0.214, 0.234,
            0.257, 0.286, 0.316, 0.352, 0.392, 0.435, 0.480, 0.528, 0.576, 0.626,
            0.677, 0.728, 0.781, 0.834, 0.887, 0.941, 0.996, 1.051, 1.106, 1.162,
            1.218, 1.274, 1.331, 1.388, 1.446, 1.504, 1.562, 1.620, 1.678, 1.737,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.373, 0.373, 0.373, 0.373, 0.373, 0.375, 0.378, 0.384, 0.395, 0.415,
            0.450, 0.498, 0.551, 0.607, 0.664, 0.723, 0.782, 0.842, 0.903, 0.964,
            1.026, 1.088, 1.150, 1.213, 1.276, 1.339, 1.402, 1.466, 1.529, 1.593,
            1.657, 1.721, 1.785, 1.850, 1.914, 1.978, 2.043, 2.107, 2.171, 2.235,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.823, 0.825, 0.829, 0.835, 0.844, 0.855, 0.869, 0.894, 0.924, 0.955,
            0.988, 1.022, 1.057, 1.094, 1.133, 1.175, 1.220, 1.271, 1.325, 1.382,
            1.441, 1.502, 1.563, 1.626, 1.688, 1.751, 1.815, 1.879, 1.943, 2.007,
            2.072, 2.136, 2.201, 2.267, 2.332, 2.397, 2.463, 2.529, 2.595,
        }),
    };
    const fujifilm_400: [3][]const Point = .{
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.163, 0.166, 0.170, 0.176, 0.185, 0.197, 0.212, 0.231, 0.255, 0.285,
            0.322, 0.369, 0.424, 0.479, 0.535, 0.591, 0.647, 0.703, 0.759, 0.815,
            0.871, 0.927, 0.983, 1.040, 1.096, 1.152, 1.208, 1.264, 1.321, 1.377,
            1.433, 1.490, 1.546, 1.602, 1.658, 1.715, 1.771, 1.827, 1.884, 1.940,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.403, 0.404, 0.405, 0.408, 0.416, 0.428, 0.447, 0.474, 0.510, 0.556,
            0.617, 0.679, 0.742, 0.804, 0.867, 0.929, 0.992, 1.055, 1.118, 1.181,
            1.243, 1.306, 1.369, 1.432, 1.495, 1.558, 1.621, 1.683, 1.746, 1.809,
            1.872, 1.935, 1.997, 2.060, 2.123, 2.186, 2.248, 2.310, 2.373, 2.434,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.886, 0.893, 0.906, 0.922, 0.942, 0.965, 0.990, 1.022, 1.059, 1.097,
            1.136, 1.177, 1.219, 1.263, 1.308, 1.357, 1.409, 1.468, 1.527, 1.588,
            1.649, 1.710, 1.771, 1.833, 1.895, 1.957, 2.019, 2.082, 2.144, 2.207,
            2.269, 2.332, 2.394, 2.457, 2.520, 2.583, 2.646, 2.709, 2.772,
        }),
    };
    const fujifilm_superia_xtra_400: [3][]const Point = .{
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.136, 0.140, 0.148, 0.160, 0.175, 0.194, 0.216, 0.242, 0.271, 0.304,
            0.339, 0.376, 0.420, 0.472, 0.527, 0.585, 0.644, 0.703, 0.764, 0.825,
            0.886, 0.947, 1.008, 1.070, 1.131, 1.193, 1.254, 1.315, 1.376, 1.437,
            1.499, 1.560, 1.622, 1.684, 1.746, 1.808, 1.870, 1.933, 1.996, 2.059,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.453, 0.455, 0.459, 0.464, 0.473, 0.484, 0.500, 0.521, 0.550, 0.587,
            0.633, 0.686, 0.748, 0.811, 0.876, 0.941, 1.006, 1.071, 1.137, 1.203,
            1.269, 1.335, 1.401, 1.467, 1.534, 1.601, 1.668, 1.735, 1.802, 1.869,
            1.937, 2.005, 2.073, 2.141, 2.209, 2.278, 2.347, 2.416, 2.486,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.727, 0.729, 0.732, 0.736, 0.742, 0.750, 0.761, 0.777, 0.799, 0.831,
            0.876, 0.932, 0.995, 1.062, 1.131, 1.202, 1.273, 1.345, 1.417, 1.490,
            1.562, 1.633, 1.703, 1.773, 1.843, 1.912, 1.981, 2.050, 2.118, 2.187,
            2.255, 2.324, 2.393, 2.462, 2.531, 2.600, 2.670, 2.741, 2.813,
        }),
    };
    const fujifilm_c200: [3][]const Point = .{
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.145, 0.146, 0.150, 0.155, 0.161, 0.169, 0.180, 0.193, 0.211, 0.233,
            0.261, 0.300, 0.348, 0.390, 0.436, 0.482, 0.527, 0.577, 0.627, 0.679,
            0.732, 0.789, 0.847, 0.906, 0.968, 1.029, 1.092, 1.158, 1.223, 1.288,
            1.351, 1.412, 1.474, 1.531, 1.592, 1.650, 1.711, 1.771, 1.828, 1.886,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.432, 0.432, 0.434, 0.436, 0.439, 0.443, 0.450, 0.459, 0.475, 0.491,
            0.525, 0.573, 0.626, 0.680, 0.736, 0.793, 0.850, 0.908, 0.969, 1.029,
            1.090, 1.152, 1.216, 1.279, 1.343, 1.407, 1.472, 1.535, 1.601, 1.668,
            1.734, 1.798, 1.863, 1.930, 1.997, 2.064, 2.134, 2.202, 2.271, 2.341,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,
        }, &.{
            0.734, 0.735, 0.738, 0.743, 0.748, 0.755, 0.765, 0.778, 0.796, 0.819,
            0.851, 0.893, 0.945, 1.001, 1.058, 1.112, 1.173, 1.237, 1.304, 1.374,
            1.446, 1.517, 1.586, 1.652, 1.719, 1.783, 1.846, 1.910, 1.976, 2.041,
            2.106, 2.171, 2.236, 2.303, 2.370, 2.437, 2.505, 2.575, 2.647,
        }),
    };
    const fujifilm_pro_400h: [3][]const Point = .{
        sampled(&.{
            -3.450, -3.300, -3.150, -3.000, -2.850, -2.700, -2.550, -2.400, -2.250, -2.100,
            -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050, -0.900, -0.750, -0.600,
            -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,  0.600,
        }, &.{
            0.171, 0.171, 0.173, 0.176, 0.183, 0.192, 0.206, 0.232, 0.281, 0.346,
            0.420, 0.501, 0.586, 0.675, 0.765, 0.857, 0.950, 1.043, 1.136, 1.228,
            1.319, 1.409, 1.497, 1.583, 1.667, 1.748, 1.827, 1.902,
        }),
        sampled(&.{
            -3.450, -3.300, -3.150, -3.000, -2.850, -2.700, -2.550, -2.400, -2.250, -2.100,
            -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050, -0.900, -0.750, -0.600,
            -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,  0.600,
        }, &.{
            0.684, 0.682, 0.681, 0.682, 0.686, 0.695, 0.711, 0.748, 0.806, 0.874,
            0.949, 1.029, 1.112, 1.198, 1.287, 1.375, 1.462, 1.547, 1.632, 1.716,
            1.799, 1.880, 1.961, 2.040, 2.118, 2.195, 2.269, 2.342,
        }),
        sampled(&.{
            -3.450, -3.300, -3.150, -3.000, -2.850, -2.700, -2.550, -2.400, -2.250, -2.100,
            -1.950, -1.800, -1.650, -1.500, -1.350, -1.200, -1.050, -0.900, -0.750, -0.600,
            -0.450, -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,  0.600,
        }, &.{
            0.947, 0.947, 0.947, 0.951, 0.958, 0.970, 0.992, 1.031, 1.089, 1.157,
            1.234, 1.318, 1.400, 1.482, 1.563, 1.643, 1.722, 1.802, 1.881, 1.959,
            2.038, 2.116, 2.193, 2.271, 2.347, 2.424, 2.499, 2.573,
        }),
    };
    const fujifilm_pro_160ns: [3][]const Point = .{
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
            0.400,
        }, &.{
            0.282, 0.283, 0.285, 0.286, 0.288, 0.290, 0.293, 0.296, 0.300, 0.306,
            0.314, 0.325, 0.343, 0.376, 0.416, 0.460, 0.508, 0.559, 0.611, 0.665,
            0.720, 0.776, 0.834, 0.892, 0.951, 1.010, 1.070, 1.131, 1.193, 1.254,
            1.317, 1.380, 1.443, 1.507, 1.571, 1.636, 1.701, 1.767, 1.833, 1.900,
            1.968,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
            0.400,
        }, &.{
            0.817, 0.815, 0.813, 0.812, 0.811, 0.811, 0.811, 0.813, 0.816, 0.822,
            0.832, 0.849, 0.876, 0.909, 0.946, 0.987, 1.030, 1.076, 1.124, 1.173,
            1.224, 1.276, 1.329, 1.382, 1.437, 1.492, 1.547, 1.603, 1.659, 1.715,
            1.771, 1.827, 1.883, 1.938, 1.993, 2.047, 2.100, 2.151, 2.201, 2.248,
            2.291,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
            0.400,
        }, &.{
            0.920, 0.920, 0.920, 0.921, 0.923, 0.926, 0.930, 0.935, 0.943, 0.953,
            0.968, 0.989, 1.022, 1.066, 1.113, 1.163, 1.215, 1.268, 1.321, 1.375,
            1.430, 1.485, 1.541, 1.596, 1.651, 1.707, 1.763, 1.818, 1.873, 1.928,
            1.983, 2.037, 2.091, 2.144, 2.197, 2.248, 2.299, 2.348, 2.395, 2.440,
            2.480,
        }),
    };
    const fujifilm_fujicolor_100: [3][]const Point = .{
        sampled(&.{
            -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300,
            -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300,
            -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300,
            -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,
        }, &.{
            0.182, 0.183, 0.185, 0.188, 0.192, 0.198, 0.205, 0.215, 0.228, 0.244,
            0.264, 0.288, 0.319, 0.357, 0.405, 0.468, 0.540, 0.614, 0.690, 0.766,
            0.844, 0.921, 0.999, 1.077, 1.156, 1.234, 1.313, 1.392, 1.470, 1.549,
            1.628, 1.707, 1.786, 1.864, 1.943, 2.021, 2.098,
        }),
        sampled(&.{
            -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300,
            -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300,
            -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300,
            -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,
        }, &.{
            0.512, 0.514, 0.518, 0.523, 0.530, 0.540, 0.551, 0.566, 0.584, 0.606,
            0.634, 0.667, 0.706, 0.752, 0.815, 0.885, 0.958, 1.031, 1.105, 1.179,
            1.254, 1.329, 1.403, 1.478, 1.553, 1.627, 1.701, 1.776, 1.849, 1.923,
            1.996, 2.068, 2.139, 2.210, 2.279, 2.346, 2.408,
        }),
        sampled(&.{
            -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300,
            -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300,
            -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300,
            -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,
        }, &.{
            0.688, 0.690, 0.694, 0.699, 0.707, 0.717, 0.730, 0.747, 0.769, 0.799,
            0.837, 0.884, 0.938, 0.997, 1.068, 1.144, 1.222, 1.300, 1.376, 1.446,
            1.518, 1.593, 1.671, 1.750, 1.831, 1.914, 1.997, 2.081, 2.166, 2.251,
            2.336, 2.421, 2.505, 2.588, 2.670, 2.750, 2.827,
        }),
    };
    const kodak_ektachrome_e100: [3][]const Point = .{
        sampled(&.{
            -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900,
            -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900,
            -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,
        }, &.{
            3.241, 3.238, 3.231, 3.211, 3.172, 3.117, 3.044, 2.947, 2.813, 2.657,
            2.476, 2.281, 2.073, 1.863, 1.665, 1.474, 1.284, 1.122, 0.984, 0.855,
            0.731, 0.620, 0.522, 0.430, 0.351, 0.288, 0.233, 0.189, 0.155,
        }),
        sampled(&.{
            -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900,
            -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900,
            -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,
        }, &.{
            3.601, 3.599, 3.581, 3.549, 3.501, 3.433, 3.341, 3.216, 3.055, 2.864,
            2.651, 2.429, 2.192, 1.958, 1.739, 1.535, 1.329, 1.161, 1.013, 0.876,
            0.745, 0.629, 0.526, 0.433, 0.354, 0.289, 0.233, 0.189, 0.161,
        }),
        sampled(&.{
            -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900,
            -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900,
            -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,
        }, &.{
            3.753, 3.738, 3.715, 3.672, 3.605, 3.514, 3.392, 3.232, 3.038, 2.823,
            2.587, 2.353, 2.110, 1.873, 1.649, 1.445, 1.256, 1.094, 0.951, 0.815,
            0.690, 0.577, 0.477, 0.392, 0.319, 0.257, 0.215, 0.181, 0.150,
        }),
    };
    const kodak_kodachrome_64: [3][]const Point = .{
        sampled(&.{
            -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
            -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
            -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,
        }, &.{
            3.680, 3.665, 3.638, 3.589, 3.518, 3.426, 3.313, 3.175, 3.005, 2.800,
            2.572, 2.331, 2.090, 1.861, 1.650, 1.453, 1.269, 1.096, 0.935, 0.784,
            0.649, 0.540, 0.453, 0.382, 0.316, 0.254, 0.211, 0.189, 0.180,
        }),
        sampled(&.{
            -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
            -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
            -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,
        }, &.{
            3.450, 3.433, 3.408, 3.368, 3.302, 3.208, 3.083, 2.925, 2.740, 2.526,
            2.300, 2.072, 1.852, 1.645, 1.453, 1.265, 1.091, 0.934, 0.795, 0.673,
            0.568, 0.477, 0.401, 0.338, 0.288, 0.249, 0.221, 0.203, 0.190,
        }),
        sampled(&.{
            -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
            -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
            -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,
        }, &.{
            3.330, 3.287, 3.238, 3.179, 3.104, 3.009, 2.886, 2.730, 2.543, 2.332,
            2.118, 1.907, 1.703, 1.507, 1.323, 1.159, 1.009, 0.873, 0.750, 0.642,
            0.546, 0.462, 0.392, 0.333, 0.285, 0.249, 0.223, 0.208, 0.200,
        }),
    };
    const fujifilm_provia_100f: [3][]const Point = .{
        sampled(&.{
            -3.300, -3.150, -3.000, -2.850, -2.700, -2.550, -2.400, -2.250, -2.100, -1.950,
            -1.800, -1.650, -1.500, -1.350, -1.200, -1.050, -0.900, -0.750, -0.600, -0.450,
            -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,  0.600,  0.750,
        }, &.{
            3.295, 3.298, 3.296, 3.285, 3.259, 3.222, 3.165, 3.076, 2.951, 2.740,
            2.444, 2.149, 1.863, 1.586, 1.325, 1.075, 0.841, 0.643, 0.471, 0.320,
            0.219, 0.158, 0.119, 0.096, 0.094, 0.094, 0.093, 0.094,
        }),
        sampled(&.{
            -3.300, -3.150, -3.000, -2.850, -2.700, -2.550, -2.400, -2.250, -2.100, -1.950,
            -1.800, -1.650, -1.500, -1.350, -1.200, -1.050, -0.900, -0.750, -0.600, -0.450,
            -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,  0.600,  0.750,
        }, &.{
            3.427, 3.427, 3.427, 3.427, 3.421, 3.391, 3.331, 3.237, 3.079, 2.837,
            2.553, 2.201, 1.863, 1.586, 1.325, 1.075, 0.841, 0.643, 0.471, 0.320,
            0.219, 0.158, 0.119, 0.096, 0.094, 0.094, 0.093, 0.094,
        }),
        sampled(&.{
            -3.300, -3.150, -3.000, -2.850, -2.700, -2.550, -2.400, -2.250, -2.100, -1.950,
            -1.800, -1.650, -1.500, -1.350, -1.200, -1.050, -0.900, -0.750, -0.600, -0.450,
            -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,  0.600,  0.750,
        }, &.{
            3.340, 3.341, 3.341, 3.335, 3.313, 3.281, 3.217, 3.110, 2.938, 2.708,
            2.444, 2.149, 1.863, 1.586, 1.325, 1.075, 0.841, 0.643, 0.471, 0.320,
            0.219, 0.158, 0.119, 0.096, 0.094, 0.094, 0.093, 0.094,
        }),
    };
    const fujifilm_velvia_100: [3][]const Point = .{
        sampled(&.{
            -3.300, -3.150, -3.000, -2.850, -2.700, -2.550, -2.400, -2.250, -2.100, -1.950,
            -1.800, -1.650, -1.500, -1.350, -1.200, -1.050, -0.900, -0.750, -0.600, -0.450,
            -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,  0.600,  0.750,  0.900,
        }, &.{
            3.387, 3.388, 3.389, 3.389, 3.387, 3.381, 3.368, 3.340, 3.271, 3.139,
            2.895, 2.462, 2.052, 1.681, 1.352, 1.062, 0.813, 0.603, 0.434, 0.307,
            0.218, 0.173, 0.157, 0.150, 0.144, 0.140, 0.137, 0.136, 0.135,
        }),
        sampled(&.{
            -3.300, -3.150, -3.000, -2.850, -2.700, -2.550, -2.400, -2.250, -2.100, -1.950,
            -1.800, -1.650, -1.500, -1.350, -1.200, -1.050, -0.900, -0.750, -0.600, -0.450,
            -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,  0.600,  0.750,  0.900,
        }, &.{
            3.822, 3.822, 3.822, 3.823, 3.824, 3.821, 3.790, 3.717, 3.591, 3.397,
            3.077, 2.552, 2.095, 1.699, 1.357, 1.063, 0.814, 0.607, 0.440, 0.312,
            0.222, 0.169, 0.148, 0.139, 0.134, 0.132, 0.131, 0.132, 0.133,
        }),
        sampled(&.{
            -3.300, -3.150, -3.000, -2.850, -2.700, -2.550, -2.400, -2.250, -2.100, -1.950,
            -1.800, -1.650, -1.500, -1.350, -1.200, -1.050, -0.900, -0.750, -0.600, -0.450,
            -0.300, -0.150, 0.000,  0.150,  0.300,  0.450,  0.600,  0.750,  0.900,
        }, &.{
            3.693, 3.694, 3.694, 3.692, 3.688, 3.682, 3.659, 3.591, 3.469, 3.263,
            2.963, 2.588, 2.176, 1.766, 1.390, 1.064, 0.794, 0.577, 0.414, 0.292,
            0.215, 0.172, 0.154, 0.146, 0.142, 0.139, 0.136, 0.135, 0.134,
        }),
    };
    const kodak_tri_x_400_curve = sampled(&.{
        -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500,
        -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
        -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
        -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
    }, &.{
        0.316, 0.322, 0.328, 0.337, 0.349, 0.366, 0.389, 0.419, 0.455, 0.498,
        0.546, 0.598, 0.650, 0.704, 0.758, 0.812, 0.868, 0.925, 0.982, 1.041,
        1.103, 1.165, 1.227, 1.289, 1.351, 1.413, 1.475, 1.536, 1.595, 1.655,
        1.712, 1.769, 1.825, 1.879, 1.931, 1.982, 2.031, 2.078,
    });
    const kodak_tri_x_400: [3][]const Point = .{ kodak_tri_x_400_curve, kodak_tri_x_400_curve, kodak_tri_x_400_curve };
    const kodak_t_max_100_curve = sampled(&.{
        -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200,
        -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200,
        -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200,
        -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,
    }, &.{
        0.208, 0.209, 0.209, 0.210, 0.211, 0.213, 0.217, 0.224, 0.236, 0.254,
        0.279, 0.313, 0.354, 0.401, 0.455, 0.512, 0.570, 0.627, 0.683, 0.740,
        0.797, 0.855, 0.914, 0.971, 1.026, 1.080, 1.134, 1.187, 1.239, 1.291,
        1.345, 1.401, 1.458, 1.515, 1.573, 1.632, 1.693, 1.754,
    });
    const kodak_t_max_100: [3][]const Point = .{ kodak_t_max_100_curve, kodak_t_max_100_curve, kodak_t_max_100_curve };
    const kodak_t_max_400_curve = sampled(&.{
        -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500,
        -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500,
        -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500,
        -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
    }, &.{
        0.270, 0.272, 0.275, 0.281, 0.291, 0.305, 0.327, 0.354, 0.388, 0.426,
        0.465, 0.505, 0.549, 0.596, 0.645, 0.696, 0.750, 0.808, 0.869, 0.936,
        1.008, 1.083, 1.158, 1.236, 1.316, 1.396, 1.475, 1.554, 1.633, 1.710,
        1.783, 1.854, 1.929, 2.006, 2.072, 2.135, 2.200, 2.264,
    });
    const kodak_t_max_400: [3][]const Point = .{ kodak_t_max_400_curve, kodak_t_max_400_curve, kodak_t_max_400_curve };
    const foma_fomapan_100_curve = sampled(&.{
        -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300,
        -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300,
        -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400,
    }, &.{
        0.277, 0.319, 0.393, 0.490, 0.594, 0.700, 0.808, 0.911, 1.009, 1.105,
        1.201, 1.301, 1.399, 1.495, 1.588, 1.682, 1.774, 1.862, 1.947, 2.029,
        2.107, 2.182, 2.256, 2.327, 2.394, 2.456, 2.514, 2.569, 2.616,
    });
    const foma_fomapan_100: [3][]const Point = .{ foma_fomapan_100_curve, foma_fomapan_100_curve, foma_fomapan_100_curve };
    const foma_fomapan_200_curve = sampled(&.{
        -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300,
        -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300,
        -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400,
    }, &.{
        0.277, 0.319, 0.393, 0.490, 0.594, 0.700, 0.808, 0.911, 1.009, 1.105,
        1.201, 1.300, 1.399, 1.494, 1.588, 1.682, 1.774, 1.862, 1.947, 2.029,
        2.107, 2.182, 2.256, 2.327, 2.394, 2.456, 2.514, 2.569, 2.616,
    });
    const foma_fomapan_200: [3][]const Point = .{ foma_fomapan_200_curve, foma_fomapan_200_curve, foma_fomapan_200_curve };
    const foma_fomapan_400_curve = sampled(&.{
        -3.200, -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300,
        -2.200, -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300,
        -1.200, -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400,
    }, &.{
        0.277, 0.319, 0.394, 0.491, 0.594, 0.701, 0.808, 0.911, 1.009, 1.105,
        1.201, 1.301, 1.399, 1.495, 1.589, 1.682, 1.774, 1.862, 1.947, 2.029,
        2.107, 2.182, 2.256, 2.327, 2.394, 2.456, 2.514, 2.569, 2.616,
    });
    const foma_fomapan_400: [3][]const Point = .{ foma_fomapan_400_curve, foma_fomapan_400_curve, foma_fomapan_400_curve };
    const foma_fomapan_r_100_curve = sampled(&.{
        -0.100, 0.000, 0.100, 0.200, 0.300, 0.400, 0.500, 0.600, 0.700, 0.800,
        0.900,  1.000, 1.100, 1.200, 1.300, 1.400, 1.500, 1.600, 1.700, 1.800,
        1.900,  2.000, 2.100, 2.200, 2.300, 2.400, 2.500, 2.600, 2.700, 2.800,
        2.900,
    }, &.{
        2.708, 2.685, 2.651, 2.607, 2.553, 2.488, 2.410, 2.313, 2.187, 2.042,
        1.884, 1.716, 1.542, 1.365, 1.190, 1.021, 0.861, 0.716, 0.601, 0.509,
        0.434, 0.372, 0.321, 0.277, 0.241, 0.209, 0.181, 0.157, 0.136, 0.117,
        0.100,
    });
    const foma_fomapan_r_100: [3][]const Point = .{ foma_fomapan_r_100_curve, foma_fomapan_r_100_curve, foma_fomapan_r_100_curve };
    const fujifilm_superia_200: [3][]const Point = .{
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.208, 0.213, 0.219, 0.226, 0.236, 0.248, 0.260, 0.275, 0.291, 0.311,
            0.335, 0.366, 0.403, 0.451, 0.504, 0.562, 0.625, 0.689, 0.756, 0.824,
            0.895, 0.971, 1.045, 1.123, 1.201, 1.278, 1.352, 1.425, 1.498, 1.571,
            1.646, 1.720, 1.797, 1.872, 1.947, 2.019, 2.093, 2.167, 2.240, 2.313,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.452, 0.461, 0.470, 0.484, 0.492, 0.502, 0.514, 0.531, 0.547, 0.567,
            0.596, 0.631, 0.675, 0.725, 0.781, 0.842, 0.908, 0.975, 1.039, 1.110,
            1.183, 1.259, 1.337, 1.417, 1.499, 1.579, 1.663, 1.748, 1.834, 1.918,
            2.001, 2.083, 2.163, 2.244, 2.327, 2.408, 2.485, 2.558, 2.633, 2.708,
        }),
        sampled(&.{
            -3.600, -3.500, -3.400, -3.300, -3.200, -3.100, -3.000, -2.900, -2.800, -2.700,
            -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900, -1.800, -1.700,
            -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900, -0.800, -0.700,
            -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,  0.200,  0.300,
        }, &.{
            0.794, 0.797, 0.797, 0.803, 0.812, 0.825, 0.842, 0.867, 0.896, 0.930,
            0.972, 1.012, 1.059, 1.109, 1.161, 1.216, 1.273, 1.334, 1.397, 1.463,
            1.531, 1.604, 1.678, 1.754, 1.833, 1.914, 1.997, 2.074, 2.152, 2.231,
            2.309, 2.389, 2.470, 2.546, 2.619, 2.690, 2.762, 2.832, 2.903, 2.979,
        }),
    };
    const kodak_pro_image_100: [3][]const Point = .{
        sampled(&.{
            -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200,
            -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200,
            -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200,
            -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,
        }, &.{
            0.249, 0.252, 0.256, 0.261, 0.268, 0.280, 0.300, 0.328, 0.363, 0.404,
            0.451, 0.502, 0.556, 0.611, 0.667, 0.724, 0.781, 0.839, 0.897, 0.954,
            1.012, 1.069, 1.126, 1.182, 1.239, 1.295, 1.352, 1.408, 1.465, 1.521,
            1.577, 1.633, 1.689, 1.745, 1.799, 1.851, 1.899, 1.943, 1.982, 2.017,
        }),
        sampled(&.{
            -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200,
            -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200,
            -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200,
            -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,
        }, &.{
            0.705, 0.707, 0.710, 0.716, 0.725, 0.737, 0.756, 0.782, 0.815, 0.854,
            0.899, 0.949, 1.002, 1.058, 1.116, 1.175, 1.236, 1.297, 1.358, 1.419,
            1.481, 1.543, 1.604, 1.665, 1.726, 1.787, 1.847, 1.906, 1.966, 2.025,
            2.084, 2.143, 2.201, 2.260, 2.318, 2.374, 2.428, 2.477, 2.523, 2.565,
        }),
        sampled(&.{
            -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200,
            -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200,
            -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200,
            -0.100, 0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,
        }, &.{
            0.957, 0.960, 0.964, 0.968, 0.975, 0.986, 1.006, 1.035, 1.074, 1.120,
            1.174, 1.233, 1.296, 1.362, 1.431, 1.502, 1.573, 1.645, 1.717, 1.790,
            1.863, 1.935, 2.006, 2.077, 2.147, 2.217, 2.287, 2.357, 2.427, 2.497,
            2.566, 2.636, 2.704, 2.772, 2.840, 2.904, 2.966, 3.022, 3.073, 3.121,
        }),
    };
    const harman_phoenix_200: [3][]const Point = .{
        sampled(&.{
            0.100, 0.200, 0.300, 0.400, 0.500, 0.600, 0.700, 0.800, 0.900, 1.000,
            1.100, 1.200, 1.300, 1.400, 1.500, 1.600, 1.700, 1.800, 1.900, 2.000,
            2.100, 2.200, 2.300, 2.400, 2.500, 2.600, 2.700, 2.800, 2.900,
        }, &.{
            0.519, 0.508, 0.510, 0.513, 0.517, 0.523, 0.543, 0.574, 0.606, 0.640,
            0.701, 0.762, 0.868, 0.985, 1.102, 1.247, 1.393, 1.536, 1.667, 1.797,
            1.915, 1.981, 2.046, 2.106, 2.136, 2.166, 2.194, 2.211, 2.228,
        }),
        sampled(&.{
            0.100, 0.200, 0.300, 0.400, 0.500, 0.600, 0.700, 0.800, 0.900, 1.000,
            1.100, 1.200, 1.300, 1.400, 1.500, 1.600, 1.700, 1.800, 1.900, 2.000,
            2.100, 2.200, 2.300, 2.400, 2.500, 2.600, 2.700, 2.800, 2.900,
        }, &.{
            0.908, 0.908, 0.913, 0.916, 0.925, 0.932, 0.947, 0.973, 0.997, 1.047,
            1.111, 1.176, 1.280, 1.393, 1.507, 1.649, 1.791, 1.933, 2.066, 2.200,
            2.325, 2.413, 2.502, 2.585, 2.632, 2.679, 2.724, 2.761, 2.798,
        }),
        sampled(&.{
            0.100, 0.200, 0.300, 0.400, 0.500, 0.600, 0.700, 0.800, 0.900, 1.000,
            1.100, 1.200, 1.300, 1.400, 1.500, 1.600, 1.700, 1.800, 1.900, 2.000,
            2.100, 2.200, 2.300, 2.400, 2.500, 2.600, 2.700, 2.800, 2.900,
        }, &.{
            0.519, 0.508, 0.510, 0.513, 0.517, 0.523, 0.543, 0.574, 0.606, 0.693,
            0.785, 0.879, 1.012, 1.152, 1.294, 1.455, 1.615, 1.774, 1.921, 2.068,
            2.202, 2.281, 2.360, 2.432, 2.470, 2.506, 2.540, 2.561, 2.581,
        }),
    };
    const fujichrome_velvia_50: [3][]const Point = .{
        sampled(&.{
            -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900,
            -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900,
            -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,
            0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,  0.900,  1.000,  1.100,
        }, &.{
            3.339, 3.336, 3.334, 3.331, 3.328, 3.324, 3.319, 3.308, 3.292, 3.267,
            3.217, 3.140, 2.939, 2.737, 2.487, 2.245, 1.954, 1.727, 1.526, 1.350,
            1.188, 1.046, 0.892, 0.757, 0.633, 0.521, 0.429, 0.348, 0.283, 0.234,
            0.197, 0.171, 0.155, 0.146, 0.149, 0.148, 0.150, 0.151, 0.148, 0.156,
        }),
        sampled(&.{
            -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900,
            -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900,
            -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,
            0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,  0.900,  1.000,  1.100,
        }, &.{
            3.798, 3.794, 3.789, 3.781, 3.770, 3.754, 3.728, 3.686, 3.623, 3.534,
            3.415, 3.232, 2.961, 2.737, 2.487, 2.245, 1.954, 1.727, 1.526, 1.350,
            1.188, 1.046, 0.892, 0.757, 0.633, 0.521, 0.429, 0.348, 0.283, 0.234,
            0.197, 0.171, 0.155, 0.146, 0.149, 0.148, 0.150, 0.151, 0.148, 0.156,
        }),
        sampled(&.{
            -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100, -2.000, -1.900,
            -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100, -1.000, -0.900,
            -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100, 0.000,  0.100,
            0.200,  0.300,  0.400,  0.500,  0.600,  0.700,  0.800,  0.900,  1.000,  1.100,
        }, &.{
            3.696, 3.691, 3.686, 3.678, 3.668, 3.652, 3.625, 3.588, 3.527, 3.441,
            3.320, 3.145, 2.939, 2.737, 2.487, 2.245, 1.954, 1.727, 1.526, 1.350,
            1.188, 1.046, 0.892, 0.757, 0.633, 0.521, 0.429, 0.348, 0.283, 0.234,
            0.197, 0.171, 0.155, 0.146, 0.149, 0.148, 0.150, 0.151, 0.148, 0.156,
        }),
    };
    const kodak_t_max_p3200_curve = sampled(&.{
        -3.100, -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200,
        -2.100, -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200,
        -1.100, -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200,
        -0.100, 0.000,  0.100,  0.200,  0.300,
    }, &.{
        0.298, 0.302, 0.306, 0.312, 0.321, 0.334, 0.355, 0.384, 0.425, 0.477,
        0.540, 0.616, 0.697, 0.782, 0.871, 0.961, 1.049, 1.134, 1.215, 1.292,
        1.367, 1.441, 1.516, 1.594, 1.674, 1.761, 1.855, 1.958, 2.071, 2.193,
        2.324, 2.461, 2.601, 2.742, 2.879,
    });
    const kodak_t_max_p3200: [3][]const Point = .{ kodak_t_max_p3200_curve, kodak_t_max_p3200_curve, kodak_t_max_p3200_curve };
    const ilford_hp5_plus_curve = sampled(&.{
        0.000, 0.150, 0.300, 0.450, 0.600, 0.750, 0.900, 1.050, 1.200, 1.350,
        1.500, 1.650, 1.800, 1.950, 2.100, 2.250, 2.400, 2.550, 2.700, 2.850,
        3.000, 3.150, 3.300, 3.450, 3.600, 3.750, 3.900, 4.050,
    }, &.{
        0.178, 0.177, 0.176, 0.178, 0.185, 0.202, 0.229, 0.268, 0.320, 0.384,
        0.463, 0.553, 0.653, 0.759, 0.858, 0.954, 1.052, 1.148, 1.246, 1.341,
        1.437, 1.532, 1.627, 1.722, 1.817, 1.913, 2.008, 2.103,
    });
    const ilford_hp5_plus: [3][]const Point = .{ ilford_hp5_plus_curve, ilford_hp5_plus_curve, ilford_hp5_plus_curve };
    const ilford_fp4_plus_curve = sampled(&.{
        0.100, 0.200, 0.300, 0.400, 0.500, 0.600, 0.700, 0.800, 0.900, 1.000,
        1.100, 1.200, 1.300, 1.400, 1.500, 1.600, 1.700, 1.800, 1.900, 2.000,
        2.100, 2.200, 2.300, 2.400, 2.500, 2.600, 2.700, 2.800, 2.900, 3.000,
        3.100, 3.200, 3.300, 3.400, 3.500, 3.600, 3.700, 3.800, 3.900, 4.000,
        4.100,
    }, &.{
        0.095, 0.095, 0.095, 0.095, 0.095, 0.095, 0.095, 0.097, 0.103, 0.117,
        0.146, 0.181, 0.225, 0.271, 0.324, 0.379, 0.436, 0.496, 0.561, 0.630,
        0.704, 0.781, 0.858, 0.936, 1.013, 1.091, 1.175, 1.259, 1.344, 1.425,
        1.501, 1.570, 1.634, 1.692, 1.745, 1.787, 1.821, 1.843, 1.857, 1.862,
        1.862,
    });
    const ilford_fp4_plus: [3][]const Point = .{ ilford_fp4_plus_curve, ilford_fp4_plus_curve, ilford_fp4_plus_curve };
    const ilford_pan_f_plus_curve = sampled(&.{
        0.150, 0.300, 0.450, 0.600, 0.750, 0.900, 1.050, 1.200, 1.350, 1.500,
        1.650, 1.800, 1.950, 2.100, 2.250, 2.400, 2.550, 2.700, 2.850, 3.000,
        3.150, 3.300, 3.450, 3.600, 3.750, 3.900, 4.050, 4.200,
    }, &.{
        0.060, 0.060, 0.060, 0.060, 0.060, 0.060, 0.060, 0.060, 0.060, 0.065,
        0.081, 0.112, 0.162, 0.226, 0.309, 0.402, 0.504, 0.612, 0.727, 0.845,
        0.967, 1.095, 1.226, 1.358, 1.489, 1.617, 1.741, 1.853,
    });
    const ilford_pan_f_plus: [3][]const Point = .{ ilford_pan_f_plus_curve, ilford_pan_f_plus_curve, ilford_pan_f_plus_curve };
    const ilford_delta_100_curve = sampled(&.{
        0.100, 0.200, 0.300, 0.400, 0.500, 0.600, 0.700, 0.800, 0.900, 1.000,
        1.100, 1.200, 1.300, 1.400, 1.500, 1.600, 1.700, 1.800, 1.900, 2.000,
        2.100, 2.200, 2.300, 2.400, 2.500, 2.600, 2.700, 2.800, 2.900, 3.000,
        3.100, 3.200, 3.300, 3.400, 3.500, 3.600, 3.700, 3.800, 3.900, 4.000,
    }, &.{
        0.076, 0.076, 0.077, 0.077, 0.077, 0.077, 0.077, 0.077, 0.077, 0.077,
        0.079, 0.082, 0.088, 0.101, 0.121, 0.150, 0.189, 0.234, 0.282, 0.333,
        0.389, 0.448, 0.522, 0.573, 0.642, 0.711, 0.787, 0.865, 0.947, 1.019,
        1.097, 1.180, 1.262, 1.344, 1.425, 1.505, 1.581, 1.663, 1.743, 1.808,
    });
    const ilford_delta_100: [3][]const Point = .{ ilford_delta_100_curve, ilford_delta_100_curve, ilford_delta_100_curve };
    const ilford_delta_3200_curve = sampled(&.{
        0.150, 0.300, 0.450, 0.600, 0.750, 0.900, 1.050, 1.200, 1.350, 1.500,
        1.650, 1.800, 1.950, 2.100, 2.250, 2.400, 2.550, 2.700, 2.850, 3.000,
        3.150, 3.300, 3.450, 3.600, 3.750, 3.900, 4.050, 4.200,
    }, &.{
        0.277, 0.283, 0.306, 0.343, 0.405, 0.494, 0.596, 0.710, 0.825, 0.935,
        1.038, 1.133, 1.222, 1.308, 1.391, 1.469, 1.535, 1.602, 1.668, 1.735,
        1.796, 1.853, 1.905, 1.956, 2.005, 2.048, 2.085, 2.115,
    });
    const ilford_delta_3200: [3][]const Point = .{ ilford_delta_3200_curve, ilford_delta_3200_curve, ilford_delta_3200_curve };
    const ilford_xp2_super_curve = sampled(&.{
        0.300, 0.450, 0.600, 0.750, 0.900, 1.050, 1.200, 1.350, 1.500, 1.650,
        1.800, 1.950, 2.100, 2.250, 2.400, 2.550, 2.700, 2.850, 3.000, 3.150,
        3.300, 3.450, 3.600, 3.750, 3.900, 4.050, 4.200, 4.350,
    }, &.{
        0.267, 0.267, 0.268, 0.274, 0.289, 0.316, 0.361, 0.424, 0.513, 0.621,
        0.740, 0.855, 0.966, 1.075, 1.175, 1.272, 1.362, 1.443, 1.512, 1.574,
        1.632, 1.686, 1.737, 1.782, 1.820, 1.854, 1.878, 1.893,
    });
    const ilford_xp2_super: [3][]const Point = .{ ilford_xp2_super_curve, ilford_xp2_super_curve, ilford_xp2_super_curve };
    const ilford_sfx_200_curve = sampled(&.{
        0.150, 0.300, 0.450, 0.600, 0.750, 0.900, 1.050, 1.200, 1.350, 1.500,
        1.650, 1.800, 1.950, 2.100, 2.250, 2.400, 2.550, 2.700, 2.850, 3.000,
        3.150, 3.300, 3.450, 3.600, 3.750, 3.900, 4.050, 4.200, 4.350,
    }, &.{
        0.286, 0.285, 0.286, 0.295, 0.314, 0.354, 0.412, 0.483, 0.553, 0.641,
        0.741, 0.849, 0.957, 1.061, 1.170, 1.278, 1.383, 1.489, 1.587, 1.684,
        1.778, 1.867, 1.953, 2.032, 2.109, 2.172, 2.223, 2.266, 2.298,
    });
    const ilford_sfx_200: [3][]const Point = .{ ilford_sfx_200_curve, ilford_sfx_200_curve, ilford_sfx_200_curve };
    const fujifilm_acros_100_ii_curve = sampled(&.{
        -3.000, -2.900, -2.800, -2.700, -2.600, -2.500, -2.400, -2.300, -2.200, -2.100,
        -2.000, -1.900, -1.800, -1.700, -1.600, -1.500, -1.400, -1.300, -1.200, -1.100,
        -1.000, -0.900, -0.800, -0.700, -0.600, -0.500, -0.400, -0.300, -0.200, -0.100,
        0.000,  0.100,  0.200,  0.300,  0.400,  0.500,  0.600,
    }, &.{
        0.127, 0.128, 0.130, 0.134, 0.139, 0.147, 0.158, 0.158, 0.186, 0.216,
        0.253, 0.298, 0.347, 0.396, 0.446, 0.497, 0.548, 0.600, 0.654, 0.708,
        0.767, 0.827, 0.886, 0.944, 1.002, 1.061, 1.119, 1.177, 1.235, 1.292,
        1.349, 1.408, 1.471, 1.527, 1.586, 1.642, 1.692,
    });
    const fujifilm_acros_100_ii: [3][]const Point = .{ fujifilm_acros_100_ii_curve, fujifilm_acros_100_ii_curve, fujifilm_acros_100_ii_curve };
    const ilford_ortho_plus_curve = sampled(&.{
        0.100, 0.200, 0.300, 0.400, 0.500, 0.600, 0.700, 0.800, 0.900, 1.000,
        1.100, 1.200, 1.300, 1.400, 1.500, 1.600, 1.700, 1.800, 1.900, 2.000,
        2.100, 2.200, 2.300, 2.400, 2.500, 2.600, 2.700, 2.800, 2.900, 3.000,
        3.100, 3.200, 3.300, 3.400, 3.500, 3.600, 3.700, 3.800, 3.900,
    }, &.{
        0.072, 0.072, 0.072, 0.072, 0.071, 0.072, 0.072, 0.072, 0.075, 0.082,
        0.086, 0.094, 0.103, 0.117, 0.142, 0.178, 0.224, 0.276, 0.332, 0.387,
        0.421, 0.480, 0.538, 0.600, 0.662, 0.727, 0.792, 0.858, 0.925, 0.992,
        1.061, 1.131, 1.201, 1.274, 1.321, 1.365, 1.401, 1.432, 1.462,
    });
    const ilford_ortho_plus: [3][]const Point = .{ ilford_ortho_plus_curve, ilford_ortho_plus_curve, ilford_ortho_plus_curve };
};

/// Zips a log exposure grid and the densities on it into curve points, at compile time.
fn sampled(comptime log_exposure: []const f32, comptime density: []const f32) []const Point {
    if (log_exposure.len != density.len) @compileError("curve grid and densities differ in length");
    const points = comptime points: {
        var points: [log_exposure.len]Point = undefined;
        for (&points, log_exposure, density) |*point, x, d| point.* = .{ .log_exposure = x, .density = d };
        break :points points;
    };
    return &points;
}

/// Bounds a sane entry stays within.
const sane_gamma_min: f32 = 0.3;
const sane_gamma_max: f32 = 3.0;
const sane_density_min: f32 = 0.0;
const sane_density_max: f32 = 4.0;
const curve_points_min = 20;
const curve_points_max = 41;

// The stocks are data written by hand, so the build checks them.
comptime {
    @setEvalBranchQuota(1_000_000);
    for (stocks, 0..) |stock, i| check(stock, stocks[i + 1 ..]);
}

/// Stops the build if `stock` breaks a rule. `later` are the stocks after it in the list.
fn check(comptime stock: Stock, comptime later: []const Stock) void {
    for (later) |other| if (std.mem.eql(u8, stock.name, other.name)) fail(stock, "is in the list twice");
    if (stock.source.len == 0) fail(stock, "has no source");
    const gamma = stock.gamma orelse fail(stock, "has no contrast");
    for (gamma) |slope| if (slope < sane_gamma_min or slope > sane_gamma_max) fail(stock, "has a contrast out of range");
    if (stock.base_density) |base| for (base) |density| checkDensity(stock, density);
    if (stock.density_range) |range| for (range) |density| checkDensity(stock, density);
    if (stock.base_density) |base| if (stock.density_range) |range| {
        for (base, range) |low, span| checkDensity(stock, low + span);
    };
    if (stock.curves) |curves| for (curves) |curve| {
        if (curve.len < curve_points_min or curve.len > curve_points_max) fail(stock, "has a curve with too few or too many points");
        for (curve) |point| checkDensity(stock, point.density);
        for (curve[0 .. curve.len - 1], curve[1..]) |a, b| {
            if (a.log_exposure >= b.log_exposure) fail(stock, "has a curve that isn't in increasing log exposure");
        }
        const rising = curve[curve.len - 1].density > curve[0].density;
        const should_rise = switch (stock.kind) {
            .colour_negative, .bw_negative => true,
            .colour_positive, .bw_positive => false,
        };
        if (rising != should_rise) fail(stock, "has a curve that runs the wrong way");
    };
    switch (stock.kind) {
        .bw_negative, .bw_positive => {
            if (!same(gamma)) fail(stock, "is black and white with different contrasts per channel");
            if (stock.base_density) |base| if (!same(base)) fail(stock, "is black and white with different base densities per channel");
            if (stock.curves) |curves| if (curves[0].ptr != curves[1].ptr or curves[1].ptr != curves[2].ptr) {
                fail(stock, "is black and white with different curves per channel");
            };
        },
        .colour_negative, .colour_positive => {},
    }
}

fn checkDensity(comptime stock: Stock, density: f32) void {
    if (density < sane_density_min or density > sane_density_max) fail(stock, "has a density out of range");
}

fn same(values: [3]f32) bool {
    return values[0] == values[1] and values[1] == values[2];
}

fn fail(comptime stock: Stock, comptime problem: []const u8) noreturn {
    @compileError(stock.name ++ " " ++ problem);
}
