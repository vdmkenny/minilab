const std = @import("std");
const Translator = @import("translate_c").Translator;
const bundled = @import("src/presets/looks/bundled.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Leave the debug information out of the executable, as the releases do") orelse false;
    const updates = b.option(bool, "updates", "Look for new releases at start and offer to install them, as the releases do") orelse false;

    // The codecs: libjpeg-turbo, libtiff, LibRaw and Little CMS, with their licences.
    const codecs = b.dependency("codecs", .{ .target = target, .optimize = optimize });
    for (@import("codecs").licences) |name| b.getInstallStep().dependOn(&b.addInstallFile(codecs.namedLazyPath(name), name).step);

    // The core: everything that works without a window.
    const core = b.addModule("minilab", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "codecs", .module = codecs.module("codecs") },
        },
    });
    const looks = bakeLooks(b);
    core.addAnonymousImport("bundled_looks", .{ .root_source_file = looks.baked });

    // When building for a Mac other than the host, SDL and the app need the SDK's paths, which we
    // get from xcrun.
    const macos_sdk: ?[]const u8 = if (target.result.os.tag == .macos and !target.query.isNative())
        std.mem.trimEnd(u8, b.run(&.{ "xcrun", "--sdk", "macosx", "--show-sdk-path" }), "\n")
    else
        null;
    const sdl_library = sdlLibrary(b, target, optimize, macos_sdk);

    // Dear ImGui's docking branch draws the interface. It's C++, so Dear Bindings' C API wraps it,
    // and ImGui's own backends drive it with SDL3 and SDL_GPU.
    const interface = interfaceLibrary(b, target, sdl_library);
    if (macos_sdk) |sdk| addMacosSdk(b, interface.root_module, sdk);

    const c = cModule(b, target, optimize, interface, sdl_library);

    // The version Release Please keeps in build.zig.zon, and how far the checkout is past the last
    // release, for `--version` (see `src/version.zig`).
    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", @import("build.zig.zon").version);
    build_options.addOption([]const u8, "describe", describe(b));
    build_options.addOption(bool, "updates", updates);

    const app = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "minilab", .module = core },
            .{ .name = "c", .module = c },
        },
    });
    app.addOptions("build_options", build_options);
    if (macos_sdk) |sdk| addMacosSdk(b, app, sdk);
    addFonts(b, app);

    // The Windows program gets the same icon the window shows.
    if (target.result.os.tag == .windows) app.addWin32ResourceFile(.{ .file = windowsIcon(b) });
    // Moving rolls to the Trash goes through Foundation's file manager (`platform/trash.zig`).
    if (target.result.os.tag == .macos) app.linkFramework("Foundation", .{});
    const exe = b.addExecutable(.{ .name = "minilab", .root_module = app });
    b.installArtifact(exe);

    addSteps(b, exe, &.{ core, app, looks.tool });
    addApp(b, exe, target);
}

/// SDL3, built for `target`. Building for a Mac other than the host needs the SDK at `macos_sdk`.
fn sdlLibrary(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, macos_sdk: ?[]const u8) *std.Build.Step.Compile {
    const dependency = if (macos_sdk) |sdk| b.dependency("sdl", .{
        .target = target,
        .optimize = optimize,
        .system_include_path = b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/include" })),
        .system_framework_path = b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "System/Library/Frameworks" })),
        .library_path = b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/lib" })),
    }) else b.dependency("sdl", .{ .target = target, .optimize = optimize });
    return dependency.artifact("SDL3");
}

/// The `c` module: one translated header that holds both SDL and Dear ImGui, so the types they
/// share come out as the same types.
fn cModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, interface: *std.Build.Step.Compile, sdl: *std.Build.Step.Compile) *std.Build.Module {
    const translator: Translator = .init(b.dependency("translate_c", .{}), .{
        .c_source_file = b.path("src/platform/c.h"),
        .target = target,
        .optimize = optimize,
        .default_init = true,
    });
    translator.linkLibrary(interface);
    translator.linkLibrary(sdl);
    for (interfaceIncludes(b)) |include| translator.addIncludePath(include);
    return translator.mod;
}

/// Adds `zig build run`, which runs `exe`, and `zig build test` and `zig build check` for the
/// modules with tests.
fn addSteps(b: *std.Build, exe: *std.Build.Step.Compile, tested: []const *std.Build.Module) void {
    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run minilab").dependOn(&run.step);

    const tests = b.step("test", "Run tests");
    // `zig build check` compiles the program and the tests without linking them, so
    // `zig build check -fincremental --watch` reports errors moments after you save.
    const check = b.step("check", "Check that the program and the tests compile, without writing binaries");
    for (tested) |module| {
        tests.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
        check.dependOn(&b.addTest(.{ .root_module = module }).step);
    }
    check.dependOn(&b.addExecutable(.{ .name = "minilab", .root_module = exe.root_module }).step);
}

/// Runs `git describe` on the checkout against the release tags, giving something like
/// `v0.0.1-12-gabc1234-dirty`, or nothing when there's no git or no tag, as in a source archive.
/// The build can't track what the answer depends on, so asking makes it rerun build.zig every
/// time.
fn describe(b: *std.Build) []const u8 {
    b.graph.poisonCache();
    const root = b.root.toString(b.allocator) catch @panic("out of memory");
    return switch (b.runFallible(&.{ "git", "-C", root, "describe", "--tags", "--match", "v*", "--long", "--dirty", "--abbrev=7" }, .{ .stderr_behavior = .ignore })) {
        .success => |out| std.mem.trimEnd(u8, out, "\n"),
        else => "",
    };
}

/// Gives `module` the macOS SDK's headers, frameworks and libraries at `sdk`.
fn addMacosSdk(b: *std.Build, module: *std.Build.Module, sdk: []const u8) void {
    module.addSystemIncludePath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/include" })));
    module.addSystemFrameworkPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "System/Library/Frameworks" })));
    module.addLibraryPath(b.graph.cwdRelativePath(b.pathJoin(&.{ sdk, "usr/lib" })));
}

/// Builds Dear ImGui's docking branch, Dear Bindings' C API on top of it, and its SDL3 and SDL_GPU
/// backends as one static library. It's always built optimised, whatever the app's mode.
fn interfaceLibrary(b: *std.Build, target: std.Build.ResolvedTarget, sdl_library: *std.Build.Step.Compile) *std.Build.Step.Compile {
    const imgui = b.dependency("imgui", .{});
    const bindings = b.dependency("dear_bindings", .{});
    const library = b.addLibrary(.{
        .name = "interface",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = .fast, .link_libcpp = true }),
    });
    library.root_module.linkLibrary(sdl_library);
    for (interfaceIncludes(b)) |include| library.root_module.addIncludePath(include);
    const flags: []const []const u8 = &.{ "-std=c++17", "-fno-sanitize=undefined" };
    library.root_module.addCSourceFiles(.{
        .root = imgui.path("."),
        .files = &.{ "imgui.cpp", "imgui_draw.cpp", "imgui_tables.cpp", "imgui_widgets.cpp", "imgui_demo.cpp", "backends/imgui_impl_sdl3.cpp", "backends/imgui_impl_sdlgpu3.cpp" },
        .flags = flags,
    });
    library.root_module.addCSourceFiles(.{
        .root = bindings.path("."),
        .files = &.{ "dcimgui.cpp", "backends/dcimgui_impl_sdl3.cpp", "backends/dcimgui_impl_sdlgpu3.cpp" },
        .flags = flags,
    });
    for ([_]struct { std.Build.LazyPath, []const u8 }{
        .{ imgui.path("LICENSE.txt"), "LICENSE-imgui.txt" },
        .{ bindings.path("LICENSE.txt"), "LICENSE-dear-bindings.txt" },
    }) |notice| b.getInstallStep().dependOn(&b.addInstallFile(notice[0], notice[1]).step);
    return library;
}

fn interfaceIncludes(b: *std.Build) [4]std.Build.LazyPath {
    const imgui = b.dependency("imgui", .{});
    const bindings = b.dependency("dear_bindings", .{});
    return .{ imgui.path("."), imgui.path("backends"), bindings.path("."), bindings.path("backends") };
}

/// minilab's icon in a file called `name`, an .ico or an .icns, which `src/make_icon.zig` draws.
fn iconFile(b: *std.Build, name: []const u8) std.Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "make_icon",
        .root_module = b.createModule(.{ .root_source_file = b.path("src/make_icon.zig"), .target = b.graph.host, .optimize = .ReleaseFast }),
    });
    return b.addRunArtifact(tool).addOutputFileArg(name);
}

/// minilab's icon as a Windows resource: an .ico file, and a resource script that points to it.
fn windowsIcon(b: *std.Build) std.Build.LazyPath {
    const files = b.addWriteFiles();
    _ = files.addCopyFile(iconFile(b, "minilab.ico"), "minilab.ico");
    return files.add("minilab.rc", "1 ICON \"minilab.ico\"\n");
}

/// Adds `zig build app`, which makes minilab a macOS app in `zig-out/minilab.app`: the program,
/// its icon, and an Info.plist that says what they are. The release workflow adds SANE and the
/// licences to its Resources.
fn addApp(b: *std.Build, exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget) void {
    const step = b.step("app", "Make minilab a macOS app, zig-out/minilab.app");
    if (target.result.os.tag != .macos) {
        step.dependOn(&b.addFail("minilab.app is for macOS: build it with -Dtarget=aarch64-macos or x86_64-macos").step);
        return;
    }
    const contents = "minilab.app/Contents";
    step.dependOn(&b.addInstallArtifact(exe, .{ .dest_dir = .{ .override = .{ .custom = contents ++ "/MacOS" } } }).step);
    step.dependOn(&b.addInstallFile(iconFile(b, "minilab.icns"), contents ++ "/Resources/minilab.icns").step);
    const version = @import("build.zig.zon").version;
    const oldest = target.result.os.version_range.semver.min;
    const plist = b.addWriteFiles().add("Info.plist", b.fmt(info_plist, .{ version, version, oldest.major, oldest.minor }));
    step.dependOn(&b.addInstallFile(plist, contents ++ "/Info.plist").step);
}

/// The macOS app's Info.plist: its name and identifier, its program and icon, its version (twice:
/// as people read it and as macOS compares it), and the oldest macOS the build runs on.
const info_plist =
    \\<?xml version="1.0" encoding="UTF-8"?>
    \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    \\<plist version="1.0">
    \\<dict>
    \\  <key>CFBundleName</key>
    \\  <string>minilab</string>
    \\  <key>CFBundleDisplayName</key>
    \\  <string>minilab</string>
    \\  <key>CFBundleIdentifier</key>
    \\  <string>io.github.vdmkenny.minilab</string>
    \\  <key>CFBundlePackageType</key>
    \\  <string>APPL</string>
    \\  <key>CFBundleExecutable</key>
    \\  <string>minilab</string>
    \\  <key>CFBundleIconFile</key>
    \\  <string>minilab</string>
    \\  <key>CFBundleShortVersionString</key>
    \\  <string>{s}</string>
    \\  <key>CFBundleVersion</key>
    \\  <string>{s}</string>
    \\  <key>CFBundleInfoDictionaryVersion</key>
    \\  <string>6.0</string>
    \\  <key>LSMinimumSystemVersion</key>
    \\  <string>{d}.{d}</string>
    \\  <key>LSApplicationCategoryType</key>
    \\  <string>public.app-category.photography</string>
    \\  <key>NSHighResolutionCapable</key>
    \\  <true/>
    \\</dict>
    \\</plist>
    \\
;

/// Sets up the looks from other people's collections (`src/presets/looks/bundled.zig`): fetches
/// each collection, bakes its looks into one file for the core to embed, and installs its licence
/// and credit.
fn bakeLooks(b: *std.Build) struct { baked: std.Build.LazyPath, tool: *std.Build.Module } {
    // The tool runs on this machine as part of the build, so it's always optimised.
    const tool = b.createModule(.{
        .root_source_file = b.path("src/bake_looks.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseFast,
    });
    const run = b.addRunArtifact(b.addExecutable(.{ .name = "bake_looks", .root_module = tool }));
    const baked = run.addOutputFileArg("looks.bin");
    var credits: std.ArrayList([]const u8) = .empty;
    credits.append(b.allocator, "The film looks minilab carries come from these collections. Each one's licence is\ninstalled beside this file, as LICENSE-<collection>.txt.\n") catch @panic("out of memory");
    for (std.enums.values(bundled.Pack)) |pack| {
        const info = pack.info();
        credits.append(b.allocator, b.fmt("\n{s}, by {s}\n  {s}\n  Licence: {s}\n  Source: {s}\n  Changes: {s}\n", .{
            info.name, info.author, info.credit, info.licence, info.url, info.changes,
        })) catch @panic("out of memory");
        const collection = b.dependency(@tagName(pack), .{});
        run.addDirectoryArg(collection.path("."));
        const licence: []const u8, const installed: []const u8 = switch (pack) {
            .glassmeter => .{ "LICENSE", "LICENSE-glassmeter.txt" },
            .t3mujinpack => .{ "LICENSE.txt", "LICENSE-t3mujinpack.txt" },
            .street_monochrome => .{ "LICENSE", "LICENSE-street-monochrome.txt" },
        };
        b.getInstallStep().dependOn(&b.addInstallFile(collection.path(licence), installed).step);
    }
    const credits_file = b.addWriteFiles().add("CREDITS-looks.txt", std.mem.concat(b.allocator, u8, credits.items) catch @panic("out of memory"));
    b.getInstallStep().dependOn(&b.addInstallFile(credits_file, "CREDITS-looks.txt").step);
    return .{ .baked = baked, .tool = tool };
}

/// Adds the fonts built into the app: IBM Plex Sans for the interface and JetBrains Mono for
/// values.
fn addFonts(b: *std.Build, module: *std.Build.Module) void {
    const plex = b.dependency("plex_sans", .{});
    const mono = b.dependency("jetbrains_mono", .{});
    for ([_]struct { []const u8, std.Build.LazyPath }{
        .{ "IBMPlexSans-Regular.ttf", plex.path("fonts/complete/ttf/IBMPlexSans-Regular.ttf") },
        .{ "IBMPlexSans-SemiBold.ttf", plex.path("fonts/complete/ttf/IBMPlexSans-SemiBold.ttf") },
        .{ "JetBrainsMono-Regular.ttf", mono.path("fonts/ttf/JetBrainsMono-Regular.ttf") },
    }) |font| module.addAnonymousImport(font[0], .{ .root_source_file = font[1] });
    for ([_]struct { std.Build.LazyPath, []const u8 }{
        .{ plex.path("LICENSE.txt"), "LICENSE-ibm-plex.txt" },
        .{ mono.path("OFL.txt"), "LICENSE-jetbrains-mono.txt" },
    }) |notice| b.getInstallStep().dependOn(&b.addInstallFile(notice[0], notice[1]).step);
}
