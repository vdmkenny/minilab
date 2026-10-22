//! The image libraries minilab reads and writes with, as one Zig module, "codecs": the C APIs of
//! LibTIFF, libjpeg-turbo, LittleCMS 2 and LibRaw, which translate-c makes of `c.h`, with the
//! libraries linked, so a module that imports it links them too. It also holds minilab's JPEG
//! shim (`jpeg_shim.c`), which keeps libjpeg's `longjmp` error handling inside C.
//!
//! The libraries' licences are named lazy paths of this package, listed in `licences`, so that
//! minilab's build can install them beside the program.
//!
//! `zig build test` here runs the tests of minilab's bindings (`src/io/codecs/*.zig`) against the
//! module, and `zig build` compiles them for the target without running them. The RAW binding's
//! test reads a camera file only when given one: `zig build test -Draw-sample=<file>`.

const std = @import("std");
const Translator = @import("translate_c").Translator;

/// The bindings in minilab's `src/io/codecs`, which the tests here compile.
const bindings = [_][]const u8{ "tiff.zig", "jpeg.zig", "icc.zig", "raw.zig" };

/// The licence files this package names, each also the name to install it under.
pub const licences = [_][]const u8{
    "LICENSE-libtiff.md",
    "LICENSE-libjpeg-turbo.md",
    "README-libjpeg-turbo.ijg",
    "LICENSE-lcms2.txt",
    "COPYRIGHT-libraw.txt",
    "LICENSE-libraw-lgpl.txt",
    "LICENSE-libraw-cddl.txt",
    "LICENSE-zlib.txt",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The C libraries are built optimised whatever the mode, as OpenReliant's are, so that a debug
    // build still decodes a camera file in moments. They all ask for zlib and libjpeg-turbo with
    // these options, so the program links one copy of each.
    const libraries: std.lang.Optimize = .fast;

    const libtiff = b.dependency("libtiff", .{ .target = target, .optimize = libraries });
    const libjpeg_turbo = b.dependency("libjpeg_turbo", .{ .target = target, .optimize = libraries });
    const libraw = b.dependency("libraw", .{ .target = target, .optimize = libraries });
    const lcms2 = b.dependency("lcms2", .{ .target = target, .optimize = libraries });
    const zlib = b.dependency("zlib", .{ .target = target, .optimize = libraries });
    const jpeg = libjpeg_turbo.artifact("jpeg");

    const shim = b.addLibrary(.{
        .linkage = .static,
        .name = "jpeg_shim",
        .root_module = b.createModule(.{ .target = target, .optimize = libraries, .link_libc = true }),
    });
    shim.root_module.linkLibrary(jpeg);
    shim.root_module.addCSourceFile(.{ .file = b.path("jpeg_shim.c"), .flags = &.{"-std=c99"} });
    shim.installHeader(b.path("jpeg_shim.h"), "jpeg_shim.h");

    // Structs' fields default to zero, as C's do in a partial initialiser, so that the bindings
    // name only the fields they set.
    const translator: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("c.h"),
        .target = target,
        .optimize = optimize,
        .default_init = true,
    });
    for ([_]*std.Build.Step.Compile{ libtiff.artifact("tiff"), jpeg, lcms2.artifact("lcms2"), libraw.artifact("raw"), shim }) |library| {
        translator.linkLibrary(library);
    }
    b.modules.put(b.graph.arena, "codecs", translator.mod) catch @panic("OOM");

    b.addNamedLazyPath("LICENSE-libtiff.md", libtiff.namedLazyPath("LICENSE-libtiff.md"));
    b.addNamedLazyPath("LICENSE-libjpeg-turbo.md", libjpeg_turbo.namedLazyPath("LICENSE-libjpeg-turbo.md"));
    b.addNamedLazyPath("README-libjpeg-turbo.ijg", libjpeg_turbo.namedLazyPath("README-libjpeg-turbo.ijg"));
    b.addNamedLazyPath("COPYRIGHT-libraw.txt", libraw.namedLazyPath("COPYRIGHT-libraw.txt"));
    b.addNamedLazyPath("LICENSE-libraw-lgpl.txt", libraw.namedLazyPath("LICENSE-libraw-lgpl.txt"));
    b.addNamedLazyPath("LICENSE-libraw-cddl.txt", libraw.namedLazyPath("LICENSE-libraw-cddl.txt"));
    // allyourcodebase's packages name no licence of their own: the upstreams' files serve.
    b.addNamedLazyPath("LICENSE-lcms2.txt", lcms2.builder.dependency("lcms2_c", .{}).path("LICENSE"));
    b.addNamedLazyPath("LICENSE-zlib.txt", zlib.builder.dependency("zlib", .{}).path("LICENSE"));

    // The bindings import `../../core/image.zig`, and a module's files must lie under its root
    // file's folder, so the tests compile copies laid out as they are in minilab's `src`.
    const tree = b.addWriteFiles();
    _ = tree.addCopyFile(b.path("../../src/core/image.zig"), "core/image.zig");
    for (bindings) |name| _ = tree.addCopyFile(b.path(b.fmt("../../src/io/codecs/{s}", .{name})), b.fmt("io/codecs/{s}", .{name}));
    const tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = tree.add("tests.zig", tests_root),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "codecs", .module = translator.mod }},
    }) });
    b.getInstallStep().dependOn(&tests.step);
    const run = b.addRunArtifact(tests);
    // The RAW binding's test reads a camera file only when given one.
    if (b.option([]const u8, "raw-sample", "A camera raw file for the RAW binding's test to read")) |sample| {
        run.setEnvironmentVariable("MINILAB_RAW_SAMPLE", sample);
        run.addFileInput(b.graph.cwdRelativePath(sample));
    }
    b.step("test", "Run the bindings' tests").dependOn(&run.step);
}

/// The tests' root, which takes in each binding's tests.
const tests_root = root: {
    var text: []const u8 = "test {\n";
    for (bindings) |name| text = text ++ "    _ = @import(\"io/codecs/" ++ name ++ "\");\n";
    break :root text ++ "}\n";
};
