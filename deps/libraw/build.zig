//! Builds LibRaw as the static library `raw`, in C++17 on libc++, for its C API
//! (`libraw/libraw.h`). It compiles the upstream's library sources (`Makefile.am`), with zlib for
//! floating-point DNG (`USE_ZLIB`) and libjpeg-turbo for lossy DNG (`USE_JPEG`). LittleCMS,
//! OpenMP, RawSpeed and the DNG SDK are left out. The library catches its own C++ exceptions, so
//! none of them reach a C caller.
//!
//! LibRaw is offered under the LGPL 2.1 or the CDDL 1.0 (see the upstream's `COPYRIGHT`,
//! `LICENSE.LGPL` and `LICENSE.CDDL`), and the package exposes those files as named lazy paths. A
//! program that links it statically under the LGPL has to let its users relink it with a changed
//! LibRaw. Publishing the program's source and build does that.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("upstream", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zlib = b.dependency("zlib", .{ .target = target, .optimize = optimize }).artifact("z");
    const jpeg = b.dependency("libjpeg_turbo", .{ .target = target, .optimize = optimize }).artifact("jpeg");

    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    module.linkLibrary(zlib);
    module.linkLibrary(jpeg);
    module.addIncludePath(upstream.path(""));
    module.addCMacro("USE_ZLIB", "1");
    module.addCMacro("USE_JPEG", "1");
    // LibRaw's byte-order helpers, `ntohs` and the like, come from Winsock on Windows.
    if (target.result.os.tag == .windows) module.linkSystemLibrary("ws2_32", .{});
    module.addCSourceFiles(.{
        .root = upstream.path(""),
        .files = &sources,
        // The GNU dialect, which the upstream's own build gets by default: MinGW's `math.h` hides
        // `M_PI` in strict ISO mode. dcraw's decoders shift negative numbers and overflow on
        // purpose, which the undefined behaviour sanitiser would trap.
        .flags = &.{ "-std=gnu++17", "-fno-sanitize=undefined" },
    });

    const lib = b.addLibrary(.{ .linkage = .static, .name = "raw", .root_module = module });
    lib.installHeadersDirectory(upstream.path("libraw"), "libraw", .{});
    b.installArtifact(lib);

    b.addNamedLazyPath("COPYRIGHT-libraw.txt", upstream.path("COPYRIGHT"));
    b.addNamedLazyPath("LICENSE-libraw-lgpl.txt", upstream.path("LICENSE.LGPL"));
    b.addNamedLazyPath("LICENSE-libraw-cddl.txt", upstream.path("LICENSE.CDDL"));
}

/// The upstream's `lib_libraw_a_SOURCES` (`Makefile.am`).
const sources = [_][]const u8{
    "src/libraw_c_api.cpp",
    "src/libraw_datastream.cpp",
    "src/decoders/canon_600.cpp",
    "src/decoders/crx.cpp",
    "src/decoders/pana8.cpp",
    "src/decoders/decoders_dcraw.cpp",
    "src/decoders/sonycc.cpp",
    "src/decompressors/losslessjpeg.cpp",
    "src/decoders/decoders_libraw_dcrdefs.cpp",
    "src/decoders/olympus14.cpp",
    "src/decoders/decoders_libraw.cpp",
    "src/decoders/dng.cpp",
    "src/decoders/fp_dng.cpp",
    "src/decoders/fuji_compressed.cpp",
    "src/decoders/generic.cpp",
    "src/decoders/kodak_decoders.cpp",
    "src/decoders/load_mfbacks.cpp",
    "src/decoders/smal.cpp",
    "src/decoders/unpack_thumb.cpp",
    "src/decoders/unpack.cpp",
    "src/demosaic/aahd_demosaic.cpp",
    "src/demosaic/ahd_demosaic.cpp",
    "src/demosaic/dcb_demosaic.cpp",
    "src/demosaic/dht_demosaic.cpp",
    "src/demosaic/misc_demosaic.cpp",
    "src/demosaic/xtrans_demosaic.cpp",
    "src/integration/dngsdk_glue.cpp",
    "src/integration/rawspeed_glue.cpp",
    "src/metadata/adobepano.cpp",
    "src/metadata/canon.cpp",
    "src/metadata/ciff.cpp",
    "src/metadata/cr3_parser.cpp",
    "src/metadata/epson.cpp",
    "src/metadata/exif_gps.cpp",
    "src/metadata/fuji.cpp",
    "src/metadata/identify_tools.cpp",
    "src/metadata/identify.cpp",
    "src/metadata/kodak.cpp",
    "src/metadata/leica.cpp",
    "src/metadata/makernotes.cpp",
    "src/metadata/mediumformat.cpp",
    "src/metadata/minolta.cpp",
    "src/metadata/misc_parsers.cpp",
    "src/metadata/nikon.cpp",
    "src/metadata/normalize_model.cpp",
    "src/metadata/olympus.cpp",
    "src/metadata/hasselblad_model.cpp",
    "src/metadata/p1.cpp",
    "src/metadata/pentax.cpp",
    "src/metadata/samsung.cpp",
    "src/metadata/sony.cpp",
    "src/metadata/tiff.cpp",
    "src/postprocessing/aspect_ratio.cpp",
    "src/postprocessing/dcraw_process.cpp",
    "src/postprocessing/mem_image.cpp",
    "src/postprocessing/postprocessing_aux.cpp",
    "src/postprocessing/postprocessing_utils_dcrdefs.cpp",
    "src/postprocessing/postprocessing_utils.cpp",
    "src/preprocessing/ext_preprocess.cpp",
    "src/preprocessing/raw2image.cpp",
    "src/preprocessing/subtract_black.cpp",
    "src/tables/cameralist.cpp",
    "src/tables/colorconst.cpp",
    "src/tables/colordata.cpp",
    "src/tables/wblists.cpp",
    "src/utils/curves.cpp",
    "src/utils/decoder_info.cpp",
    "src/utils/init_close_utils.cpp",
    "src/utils/open.cpp",
    "src/utils/phaseone_processing.cpp",
    "src/utils/read_utils.cpp",
    "src/utils/thumb_utils.cpp",
    "src/utils/utils_dcraw.cpp",
    "src/utils/utils_libraw.cpp",
    "src/write/apply_profile.cpp",
    "src/write/file_write.cpp",
    "src/write/tiff_writer.cpp",
    "src/x3f/x3f_parse_process.cpp",
    "src/x3f/x3f_utils_patched.cpp",
};
