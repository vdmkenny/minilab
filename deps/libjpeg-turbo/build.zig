//! Builds libjpeg-turbo's libjpeg API as the static library `jpeg`, in plain C. We leave out the
//! SIMD extensions, so you don't need NASM or any other assembler, and the same code builds for
//! every target. The library reads and writes 8-bit and 12-bit lossy JPEG and 2- to 16-bit
//! lossless JPEG, with arithmetic coding, and emulates the libjpeg v6b API, like libjpeg-turbo's
//! own default build does. The TurboJPEG API and the command-line tools are left out.
//!
//! The sources and the generated headers follow the upstream's `CMakeLists.txt` for a build with
//! `WITH_SIMD=0`. libjpeg-turbo is covered by the IJG licence, the Modified BSD licence and the
//! zlib licence (see the upstream's `LICENSE.md` and `README.ijg`). The package exposes them as
//! named lazy paths so a program can install them.

const std = @import("std");

const version: std.SemanticVersion = .{ .major = 3, .minor = 2, .patch = 0 };
const version_string = std.fmt.comptimePrint("{f}", .{version});
/// The upstream's own version number: the major version, then three digits each for the minor
/// version and the patch.
const version_number = std.fmt.comptimePrint("{d}{d:0>3}{d:0>3}", .{ version.major, version.minor, version.patch });
/// The release date, which the upstream's build stamps into `jconfigint.h` as its build string.
const release_date = "20260630";
/// The libjpeg API and ABI the library emulates: v6b, the upstream's default.
const jpeg_lib_version = 62;

pub fn build(b: *std.Build) void {
    const upstream = b.dependency("upstream", .{});
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const windows = target.result.os.tag == .windows;
    // The Huffman encoder can use `__builtin_ctzl` when `unsigned long` is as wide as `size_t`. On
    // 64-bit Windows it isn't.
    const long_is_size_t = target.result.cTypeBitSize(.ulong) == target.result.ptrBitWidth();

    const jconfig = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("src/jconfig.h.in") }, .include_path = "jconfig.h" }, .{
        .JPEG_LIB_VERSION = jpeg_lib_version,
        .VERSION = version_string,
        .LIBJPEG_TURBO_VERSION_NUMBER = version_number,
        .C_ARITH_CODING_SUPPORTED = true,
        .D_ARITH_CODING_SUPPORTED = true,
        .WITH_SIMD = null,
        .RIGHT_SHIFT_IS_UNSIGNED = null,
    });
    const jconfigint = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("src/jconfigint.h.in") }, .include_path = "jconfigint.h" }, .{
        .BUILD = release_date,
        // Hide the symbols the library's files share with each other, so they stay out of its
        // interface. Windows static libraries don't have hidden symbols, so skip it there.
        .HIDDEN = if (windows) "" else "__attribute__((visibility(\"hidden\")))",
        .INLINE = "__inline__ __attribute__((always_inline))",
        .THREAD_LOCAL = "__thread",
        .CMAKE_PROJECT_NAME = "libjpeg-turbo",
        .VERSION = version_string,
        .SIZE_T = target.result.ptrBitWidth() / 8,
        .HAVE_BUILTIN_CTZL = long_is_size_t,
        .HAVE_INTRIN_H = null,
        .C_ARITH_CODING_SUPPORTED = true,
        .D_ARITH_CODING_SUPPORTED = true,
        .WITH_SIMD = null,
        .SIMD_ARCHITECTURE = "NONE",
        .WITH_PROFILE = null,
    });
    const jversion = b.addConfigHeader(.{ .style = .{ .cmake = upstream.path("src/jversion.h.in") }, .include_path = "jversion.h" }, .{
        .COPYRIGHT_YEAR = "1991-2026",
    });

    const module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true });
    module.addConfigHeader(jconfig);
    module.addConfigHeader(jconfigint);
    module.addConfigHeader(jversion);
    module.addIncludePath(upstream.path("src"));
    module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = &sources,
        // The codec shifts negative numbers, which C compilers have always handled as expected,
        // but the undefined behaviour sanitiser would trap it.
        .flags = &.{"-fno-sanitize=undefined"},
    });

    const lib = b.addLibrary(.{ .linkage = .static, .name = "jpeg", .root_module = module });
    lib.installHeader(upstream.path("src/jpeglib.h"), "jpeglib.h");
    lib.installHeader(upstream.path("src/jmorecfg.h"), "jmorecfg.h");
    lib.installHeader(upstream.path("src/jerror.h"), "jerror.h");
    lib.installConfigHeader(jconfig);
    b.installArtifact(lib);

    b.addNamedLazyPath("LICENSE-libjpeg-turbo.md", upstream.path("LICENSE.md"));
    b.addNamedLazyPath("README-libjpeg-turbo.ijg", upstream.path("README.ijg"));
}

/// The upstream's `JPEG_SOURCES`, with arithmetic coding. Each file under `wrapper/` compiles one
/// of the codec's files for one sample precision.
const sources = [_][]const u8{
    "jcapimin.c",
    "wrapper/jcapistd-8.c",
    "wrapper/jcapistd-12.c",
    "wrapper/jcapistd-16.c",
    "wrapper/jccoefct-8.c",
    "wrapper/jccoefct-12.c",
    "wrapper/jccolor-8.c",
    "wrapper/jccolor-12.c",
    "wrapper/jccolor-16.c",
    "wrapper/jcdctmgr-8.c",
    "wrapper/jcdctmgr-12.c",
    "wrapper/jcdiffct-8.c",
    "wrapper/jcdiffct-12.c",
    "wrapper/jcdiffct-16.c",
    "jchuff.c",
    "jcicc.c",
    "jcinit.c",
    "jclhuff.c",
    "wrapper/jclossls-8.c",
    "wrapper/jclossls-12.c",
    "wrapper/jclossls-16.c",
    "wrapper/jcmainct-8.c",
    "wrapper/jcmainct-12.c",
    "wrapper/jcmainct-16.c",
    "jcmarker.c",
    "jcmaster.c",
    "jcomapi.c",
    "jcparam.c",
    "jcphuff.c",
    "wrapper/jcprepct-8.c",
    "wrapper/jcprepct-12.c",
    "wrapper/jcprepct-16.c",
    "wrapper/jcsample-8.c",
    "wrapper/jcsample-12.c",
    "wrapper/jcsample-16.c",
    "jctrans.c",
    "jdapimin.c",
    "wrapper/jdapistd-8.c",
    "wrapper/jdapistd-12.c",
    "wrapper/jdapistd-16.c",
    "jdatadst.c",
    "jdatasrc.c",
    "wrapper/jdcoefct-8.c",
    "wrapper/jdcoefct-12.c",
    "wrapper/jdcolor-8.c",
    "wrapper/jdcolor-12.c",
    "wrapper/jdcolor-16.c",
    "wrapper/jddctmgr-8.c",
    "wrapper/jddctmgr-12.c",
    "wrapper/jddiffct-8.c",
    "wrapper/jddiffct-12.c",
    "wrapper/jddiffct-16.c",
    "jdhuff.c",
    "jdicc.c",
    "jdinput.c",
    "jdlhuff.c",
    "wrapper/jdlossls-8.c",
    "wrapper/jdlossls-12.c",
    "wrapper/jdlossls-16.c",
    "wrapper/jdmainct-8.c",
    "wrapper/jdmainct-12.c",
    "wrapper/jdmainct-16.c",
    "jdmarker.c",
    "jdmaster.c",
    "wrapper/jdmerge-8.c",
    "wrapper/jdmerge-12.c",
    "jdphuff.c",
    "wrapper/jdpostct-8.c",
    "wrapper/jdpostct-12.c",
    "wrapper/jdpostct-16.c",
    "wrapper/jdsample-8.c",
    "wrapper/jdsample-12.c",
    "wrapper/jdsample-16.c",
    "jdtrans.c",
    "jerror.c",
    "jfdctflt.c",
    "wrapper/jfdctfst-8.c",
    "wrapper/jfdctfst-12.c",
    "wrapper/jfdctint-8.c",
    "wrapper/jfdctint-12.c",
    "wrapper/jidctflt-8.c",
    "wrapper/jidctflt-12.c",
    "wrapper/jidctfst-8.c",
    "wrapper/jidctfst-12.c",
    "wrapper/jidctint-8.c",
    "wrapper/jidctint-12.c",
    "wrapper/jidctred-8.c",
    "wrapper/jidctred-12.c",
    "jmemmgr.c",
    "jmemnobs.c",
    "jpeg_nbits.c",
    "wrapper/jquant1-8.c",
    "wrapper/jquant1-12.c",
    "wrapper/jquant2-8.c",
    "wrapper/jquant2-12.c",
    "wrapper/jutils-8.c",
    "wrapper/jutils-12.c",
    "wrapper/jutils-16.c",
    "jaricom.c",
    "jcarith.c",
    "jdarith.c",
};
