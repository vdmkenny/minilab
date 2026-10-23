//! Builds LibTIFF as the static library `tiff`, in plain C, with the codecs that don't need any
//! library beyond zlib and libjpeg-turbo: none, PackBits, LZW, Deflate (zlib), PixarLog (zlib),
//! JPEG and old-style JPEG (libjpeg-turbo, 8-bit and 12-bit), CCITT fax, ThunderScan, NeXT and
//! LogLuv. LERC, LZMA, ZSTD, WebP and JBIG are left out. The options are the upstream's CMake
//! defaults (`cmake/LibraryFeatures.cmake`).
//!
//! File input and output go through `tif_unix.c` on every system, Windows included, instead of
//! `tif_win32.c`. That way `tiffio.h` doesn't need `windows.h`, and minilab opens TIFFs from
//! memory through `TIFFClientOpen` anyway. LibTIFF is covered by its own BSD-like licence (see the
//! upstream's `LICENSE.md`), which the package exposes as a named lazy path.

const std = @import("std");

const version: std.SemanticVersion = .{ .major = 4, .minor = 7, .patch = 2 };
const version_string = std.fmt.comptimePrint("{f}", .{version});
/// The release date, from the upstream's `RELEASE-DATE`. `tiffvers.h` gives it as the version.
const release_date = 20260627;
/// The upstream's default size of a strip, in bytes, when strip chopping is on.
const strip_size_default = 8192;
/// The upstream's default limit on how many directories a file can have.
const max_directory_count = 1048576;

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("upstream", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const windows = target.result.os.tag == .windows;
    const big_endian = target.result.cpu.arch.endian() == .big;

    const zlib = b.dependency("zlib", .{ .target = target, .optimize = optimize }).artifact("z");
    const jpeg = b.dependency("libjpeg_turbo", .{ .target = target, .optimize = optimize }).artifact("jpeg");

    // Each template's comments mention a placeholder `@VAR@`, which CMake replaces with nothing.
    const tiffconf = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("libtiff/tiffconf.h.cmake.in") }, .include_path = "tiffconf.h" }, .{
        .VAR = "",
        .TIFF_INT8_T = "int8_t",
        .TIFF_INT16_T = "int16_t",
        .TIFF_INT32_T = "int32_t",
        .TIFF_INT64_T = "int64_t",
        .TIFF_UINT8_T = "uint8_t",
        .TIFF_UINT16_T = "uint16_t",
        .TIFF_UINT32_T = "uint32_t",
        .TIFF_UINT64_T = "uint64_t",
        .TIFF_SSIZE_T = if (target.result.ptrBitWidth() == 64) "int64_t" else "int32_t",
        .HAVE_IEEEFP = true,
        .HOST_BIG_ENDIAN = @intFromBool(big_endian),
        .CCITT_SUPPORT = true,
        .JPEG_SUPPORT = true,
        .JBIG_SUPPORT = null,
        .LERC_SUPPORT = null,
        .LOGLUV_SUPPORT = true,
        .LZW_SUPPORT = true,
        .NEXT_SUPPORT = true,
        .OJPEG_SUPPORT = true,
        .PACKBITS_SUPPORT = true,
        .PIXARLOG_SUPPORT = true,
        .THUNDER_SUPPORT = true,
        .ZIP_SUPPORT = true,
        .LIBDEFLATE_SUPPORT = null,
        .STRIPCHOP_DEFAULT = true,
        .SUBIFD_SUPPORT = true,
        .DEFAULT_EXTRASAMPLE_AS_ALPHA = true,
        .CHECK_JPEG_YCBCR_SUBSAMPLING = true,
        .MDI_SUPPORT = true,
    });
    const tif_config = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("libtiff/tif_config.h.cmake.in") }, .include_path = "tif_config.h" }, .{
        .VAR = "",
        .CCITT_SUPPORT = true,
        .CHECK_JPEG_YCBCR_SUBSAMPLING = true,
        .CHUNKY_STRIP_READ_SUPPORT = null,
        .CXX_SUPPORT = null,
        .DEFER_STRILE_LOAD = null,
        .HAVE_ASSERT_H = true,
        .HAVE_DECL_OPTARG = false,
        .HAVE_FCNTL_H = true,
        .HAVE_FSEEKO = !windows,
        .HAVE_GETOPT = !windows,
        .HAVE_IO_H = windows,
        .HAVE_MMAP = !windows,
        .HAVE_SETMODE = windows,
        .HAVE_STRINGS_H = true,
        .HAVE_SYS_TYPES_H = true,
        .HAVE_UNISTD_H = true,
        // libjpeg-turbo 3 has the 12-bit codec alongside the 8-bit one, so both JPEG modes come
        // from the one library.
        .JPEG_DUAL_MODE_8_12 = true,
        .HAVE_JPEGTURBO_DUAL_MODE_8_12 = true,
        .LERC_SUPPORT = null,
        .LERC_STATIC = null,
        .LIBJPEG_12_PATH = "",
        .LZMA_SUPPORT = null,
        .PACKAGE_NAME = "LibTIFF Software",
        .PACKAGE_BUGREPORT = "tiff@lists.osgeo.org",
        .PACKAGE_TARNAME = "tiff",
        .PACKAGE_URL = "",
        .SIZEOF_SIZE_T = target.result.ptrBitWidth() / 8,
        .STRIP_SIZE_DEFAULT = strip_size_default,
        .TIFF_MAX_DIR_COUNT = max_directory_count,
        .USE_WIN32_FILEIO = null,
        .WEBP_SUPPORT = null,
        .ZSTD_SUPPORT = null,
        .WORDS_BIGENDIAN = big_endian,
    });
    const tiffvers = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("libtiff/tiffvers.h.cmake.in") }, .include_path = "tiffvers.h" }, .{
        .VAR = "",
        .LIBTIFF_VERSION = version_string,
        .LIBTIFF_RELEASE_DATE = release_date,
        .LIBTIFF_MAJOR_VERSION = @as(i64, version.major),
        .LIBTIFF_MINOR_VERSION = @as(i64, version.minor),
        .LIBTIFF_MICRO_VERSION = @as(i64, version.patch),
    });

    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    module.linkLibrary(zlib);
    module.linkLibrary(jpeg);
    module.addConfigHeader(tiffconf);
    module.addConfigHeader(tif_config);
    module.addConfigHeader(tiffvers);
    module.addIncludePath(upstream.path("libtiff"));
    // As in the upstream's build, the library allocates through the `_TIFF*Ext` functions, which
    // respect a file's limits, except where the plain ones are defined.
    module.addCSourceFiles(.{
        .root = upstream.path("libtiff"),
        .files = &sources,
        .flags = &.{ "-DTIFF_DO_NOT_USE_NON_EXT_ALLOC_FUNCTIONS", "-fno-sanitize=undefined" },
    });
    module.addCSourceFiles(.{
        .root = upstream.path("libtiff"),
        .files = &.{ "tif_open.c", "tif_unix.c" },
        .flags = &.{ "-DTIFF_DO_NOT_USE_NON_EXT_ALLOC_FUNCTIONS", "-DALLOW_TIFF_NON_EXT_ALLOC_FUNCTIONS", "-fno-sanitize=undefined" },
    });

    const lib = b.addLibrary(.{ .linkage = .static, .name = "tiff", .root_module = module });
    lib.installHeader(upstream.path("libtiff/tiff.h"), "tiff.h");
    lib.installHeader(upstream.path("libtiff/tiffio.h"), "tiffio.h");
    lib.installConfigHeader(tiffconf);
    lib.installConfigHeader(tiffvers);
    b.installArtifact(lib);

    b.addNamedLazyPath("LICENSE-libtiff.md", upstream.path("LICENSE.md"));
}

/// The upstream's library sources (`libtiff/CMakeLists.txt`), except for `tif_open.c` and
/// `tif_unix.c`, which allocate differently. The files for the codecs we leave out compile to
/// nothing.
const sources = [_][]const u8{
    "tif_aux.c",
    "tif_close.c",
    "tif_codec.c",
    "tif_color.c",
    "tif_compress.c",
    "tif_dir.c",
    "tif_dirinfo.c",
    "tif_dirread.c",
    "tif_dirwrite.c",
    "tif_dumpmode.c",
    "tif_error.c",
    "tif_extension.c",
    "tif_fax3.c",
    "tif_fax3sm.c",
    "tif_flush.c",
    "tif_getimage.c",
    "tif_hash_set.c",
    "tif_jbig.c",
    "tif_jpeg.c",
    "tif_jpeg_12.c",
    "tif_lerc.c",
    "tif_luv.c",
    "tif_lzma.c",
    "tif_lzw.c",
    "tif_next.c",
    "tif_ojpeg.c",
    "tif_packbits.c",
    "tif_pixarlog.c",
    "tif_predict.c",
    "tif_print.c",
    "tif_read.c",
    "tif_strip.c",
    "tif_swab.c",
    "tif_thunder.c",
    "tif_tile.c",
    "tif_version.c",
    "tif_warning.c",
    "tif_webp.c",
    "tif_write.c",
    "tif_zip.c",
    "tif_zstd.c",
};
