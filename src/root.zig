//! minilab's core: everything that works without a window. The app and the CLI both use it.

const std = @import("std");

pub const image = @import("core/image.zig");
pub const develop = @import("core/develop.zig");
pub const encode = @import("core/encode.zig");
/// Showing film on screen the way it looks on a light table.
pub const light_table = @import("core/light_table.zig");
pub const look = @import("core/look.zig");
/// Calibrating scanners against the film makers' datasheets.
pub const calibration = @import("core/calibration.zig");
/// Changes to how a scanner is set up for raw scans, per scanner.
pub const scanner_settings = @import("core/scanner_settings.zig");
/// Medians, percentiles and histogram ranks.
pub const stats = @import("core/stats.zig");
/// Straightening each layer's density by its stock's datasheet curve.
pub const stock_curves = @import("core/stock_curves.zig");
/// .cube LUTs, for looks.
pub const cube_lut = @import("core/cube_lut.zig");
/// The film looks minilab ships from free collections.
pub const bundled_looks = @import("presets/looks/bundled.zig");
/// Fitting looks to pairs of scans, and the user's saved looks.
pub const looks = @import("looks/root.zig");
pub const roll = @import("core/roll.zig");
/// Reading scans from PNM, TIFF and camera RAW files.
pub const input = @import("core/input.zig");
/// Evening out a camera roll's light with its flat field.
pub const flat_field = @import("core/flat_field.zig");
/// Film formats and finding the frames on a scan.
pub const frames = @import("frames/root.zig");
pub const formats = frames.formats;
pub const framing = @import("core/framing.zig");
/// Scanners: SANE on macOS and Linux, TWAIN on Windows, both loaded at run time.
pub const scan = @import("scan/root.zig");
/// Finding, checking and installing new releases.
pub const update = @import("update/root.zig");
/// Film stock presets from the makers' datasheets.
pub const stocks = @import("presets/stocks.zig");
pub const @"export" = @import("core/export.zig");
pub const pnm = @import("io/pnm.zig");
/// PNG, for HaldCLUT images.
pub const png = @import("io/png.zig");
/// JPEG, TIFF with compression and profiles, camera RAW, and ICC colour spaces.
pub const codecs = struct {
    pub const jpeg = @import("io/codecs/jpeg.zig");
    pub const tiff = @import("io/codecs/tiff.zig");
    pub const raw = @import("io/codecs/raw.zig");
    pub const icc = @import("io/codecs/icc.zig");
};

test {
    std.testing.refAllDecls(@This());
    _ = @import("core/scans_test.zig");
    _ = @import("frames/check_scans.zig");
}
