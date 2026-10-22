//! minilab: with no arguments, the app; with a command, the command line.

const std = @import("std");
const minilab = @import("minilab");
const app = @import("app/app.zig");
pub const version = @import("version.zig");

const usage =
    \\usage (every command takes --verbose, to print debug messages):
    \\  minilab                          open the app
    \\  minilab --version                print the version
    \\  minilab --help                   print this help
    \\  minilab open [<scan.ppm>...]     open the app, with these scans loaded outside any roll
    \\      [--library <folder>]         your folder of rolls (default ~/Pictures/Rolls)
    \\      [--roll <name>]              open this roll in Develop
    \\      [--workspace <name>]         start in rolls, scan, develop, export or looks
    \\      [--shortcuts]                show the keyboard shortcuts
    \\      [--screenshot <file.png>]    draw the screen without a window and save it
    \\  minilab import <roll name> <scan>...
    \\      [--library <folder>] [--stock <name>] [--film colour|bw|slide]
    \\      [--flat <file>]              add scans to a roll, and make the roll if it doesn't exist
    \\                                   yet. Takes PPM or PGM, 16-bit linear TIFF or camera RAW.
    \\                                   A strip scan becomes one frame per frame found on it.
    \\                                   --flat is a shot of the light with no film in front of
    \\                                   it: the roll keeps it as its flat field and divides each
    \\                                   frame by it, to even out the light
    \\  minilab looks                    list the looks you can give --look by name: neutral,
    \\                                   frontier and the film looks. --look also takes a .cube
    \\                                   file
    \\  minilab develop-roll <out folder> <scan>... [--look <look>]
    \\      [--film colour|bw] [--base r,g,b] [--stock <name>]
    \\                                   develop scans from one 35mm roll together, with one film
    \\                                   base for all of them
    \\  minilab scan --list              list the scanners
    \\  minilab scan <out.ppm> [--device <id or model>] [--dpi <n>] [--area x,y,w,h]
    \\      [--flatbed] [--film positive|negative]
    \\                                   make one scan of film, at 300 dpi unless you give
    \\                                   --dpi. --area is in mm from the scanner's origin.
    \\                                   --flatbed scans from the glass instead of the film
    \\                                   light. The scan is raw (the scanner's Positive Film
    \\                                   setting) unless you give --film negative, which lets
    \\                                   the scanner adjust for the orange mask itself
    \\  minilab detect <scan> --dpi <n> [--film colour|bw|slide]
    \\                                   list the 35mm frames found on a strip scan, in mm
    \\  minilab develop <scan> <out.tif|out.ppm> [--look <look>]
    \\      [--film colour|bw]
    \\      [--depth 8|16] [--whole]     develop a scan of one 35mm frame, or of a strip. A
    \\                                   strip's frames go to out-1.tif, out-2.tif and so on.
    \\                                   --whole keeps the whole scan instead of cutting out the
    \\                                   frames found on it
    \\      [--base r,g,b]               the film base's transmission, 0 to 1 per channel, so
    \\                                   it isn't measured in the gaps next to the frame
    \\      [--stock <name>]             correct each color layer with the stock's datasheet
    \\                                   curve, like Develop does on a scanner that isn't
    \\                                   calibrated. Use minilab's name for the stock, like
    \\                                   "Kodak Portra 400"
    \\
;

/// The exit status for a command line minilab doesn't understand.
const usage_status = 2;

/// Prints the usage and ends the program, for a command line minilab doesn't understand.
fn exitWithUsage() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(usage_status);
}

/// The films `--film` names.
const FilmName = enum {
    colour,
    bw,
    slide,

    fn kind(name: FilmName) minilab.develop.FilmKind {
        return switch (name) {
            .colour => .colour_negative,
            .bw => .bw_negative,
            .slide => .colour_positive,
        };
    }
};

/// The films `develop` and `develop-roll` take.
const negative_films: std.EnumSet(FilmName) = .initMany(&.{ .colour, .bw });

/// The film kind `--film <value>` names, when it is one of the films the command `takes`.
fn parseFilm(value: []const u8, takes: std.EnumSet(FilmName)) error{Usage}!minilab.develop.FilmKind {
    const name = std.meta.stringToEnum(FilmName, value) orelse return error.Usage;
    if (!takes.contains(name)) return error.Usage;
    return name.kind();
}

/// Exactly `count` finite numbers, comma-separated, such as `--base r,g,b`.
fn parseNumbers(comptime count: usize, value: []const u8) error{Usage}![count]f32 {
    var numbers: [count]f32 = undefined;
    var parts = std.mem.splitScalar(u8, value, ',');
    for (&numbers) |*n| {
        n.* = std.fmt.parseFloat(f32, parts.next() orelse return error.Usage) catch return error.Usage;
        if (!std.math.isFinite(n.*)) return error.Usage;
    }
    if (parts.next() != null) return error.Usage;
    return numbers;
}

const Format = enum { tiff, ppm };
const Depth = enum { eight, sixteen };

const Options = struct {
    input: []const u8,
    output: []const u8,
    /// "neutral", "frontier", or a .cube file's path.
    look: []const u8 = "neutral",
    kind: minilab.develop.FilmKind = .colour_negative,
    depth: Depth = .sixteen,
    /// Develop all of the scan rather than the frame found on it.
    whole: bool = false,
    /// The film base's transmission per channel, 0..1, when known from elsewhere on the roll.
    base: ?[3]f32 = null,
    /// The stock's curves, from `--stock`.
    curves: ?minilab.stock_curves.Curves = null,
};

/// The curves of the stock called `name`, for film `kind`, in Status M: the command line has no
/// scanner calibration.
fn stockNamed(name: []const u8, kind: minilab.develop.FilmKind) !?minilab.stock_curves.Curves {
    for (minilab.stocks.stocks) |stock| {
        if (!std.ascii.eqlIgnoreCase(stock.name, name)) continue;
        const curves = minilab.stock_curves.of(stock, @splat(1)) orelse {
            std.log.err("{s} has no curves for {t}", .{ stock.name, kind });
            std.process.exit(usage_status);
        };
        return curves;
    }
    std.log.err("no stock preset is called {s}", .{name});
    std.process.exit(usage_status);
}

/// The look a command names: "neutral", "frontier", or a .cube file's path. `catalog` holds
/// what it reads.
fn lookNamed(gpa: std.mem.Allocator, io: std.Io, catalog: *minilab.look.Catalog, name: []const u8) !minilab.look.Resolved {
    if (std.mem.eql(u8, name, "neutral")) return .neutral;
    if (std.mem.eql(u8, name, "frontier")) return catalog.resolve(gpa, io, .frontier);
    if (minilab.bundled_looks.find(name)) |index| return catalog.resolve(gpa, io, .ofBundled(index));
    if (!isCubeFile(name)) {
        std.log.err("no look is called {s}: `minilab looks` lists them", .{name});
        std.process.exit(usage_status);
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    const lut = try gpa.create(minilab.cube_lut.Lut);
    lut.* = try minilab.cube_lut.Lut.parse(gpa, bytes);
    return .{ .lut = lut };
}

/// Frees the look `lookNamed` read from a .cube file; the catalog keeps the others.
fn freeLook(gpa: std.mem.Allocator, look: minilab.look.Resolved, name: []const u8) void {
    if (look != .lut or !isCubeFile(name)) return;
    const lut: *minilab.cube_lut.Lut = @constCast(look.lut);
    lut.deinit(gpa);
    gpa.destroy(lut);
}

fn isCubeFile(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, ".cube");
}

/// `minilab looks`: the looks `--look` takes by name, with their names for people.
fn listLooks(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    const out = &stdout.interface;
    const look = minilab.look;
    for ([_]look.Id{ .neutral, .frontier }) |id| try out.print("{s:<40} {s}\n", .{ id.text(), id.label() });
    for (minilab.bundled_looks.looks) |b| try out.print("{s:<40} {s}\n", .{ b.id, b.label });
    try out.flush();
}

/// `minilab scan`: lists the scanners, or makes one scan into a 16-bit PPM, raw where the
/// scanner has a profile.
fn scanCommand(gpa: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    const scan = minilab.scan;
    var list = false;
    var output: ?[]const u8 = null;
    var wanted: ?[]const u8 = null;
    var dpi: u32 = default_scan_dpi;
    var area: ?scan.Area = null;
    var film: scan.Film = .positive;
    var flatbed = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const value = if (i + 1 < args.len) args[i + 1] else "";
        if (std.mem.eql(u8, arg, "--list")) {
            list = true;
        } else if (std.mem.eql(u8, arg, "--flatbed")) {
            flatbed = true;
        } else if (std.mem.eql(u8, arg, "--device") and value.len > 0) {
            wanted = value;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--dpi") and value.len > 0) {
            dpi = std.fmt.parseInt(u32, value, 10) catch return error.Usage;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--film") and value.len > 0) {
            film = std.meta.stringToEnum(scan.Film, value) orelse return error.Usage;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--area") and value.len > 0) {
            const x, const y, const width, const height = try parseNumbers(4, value);
            area = .{ .x = x, .y = y, .width = width, .height = height };
            i += 1;
        } else if (output == null and arg.len > 0 and arg[0] != '-') {
            output = arg;
        } else return error.Usage;
    }
    if (!list and output == null) return error.Usage;

    var library = scan.Library.load(gpa) catch |err| {
        std.log.err("no scanner library: {t}. On macOS and Linux minilab uses SANE, on Windows TWAIN.", .{err});
        std.process.exit(1);
    };
    defer library.unload();
    const devices = try library.devices(gpa);
    defer scan.freeDevices(gpa, devices);
    if (list) {
        for (devices) |d| std.debug.print("{s}\t{s} {s} ({s}){s}\n", .{ d.id, d.vendor, d.model, d.driver, if (scan.profileOf(d.driver, d.model) != null) ", profile: raw" else "" });
        if (devices.len == 0) std.debug.print("no scanners found\n", .{});
        return;
    }
    const device = for (devices) |d| {
        const name = wanted orelse break d;
        if (std.mem.eql(u8, d.id, name) or std.mem.indexOf(u8, d.model, name) != null) break d;
    } else {
        std.log.err("no scanner {s}; `minilab scan --list` shows them", .{wanted orelse "at all"});
        std.process.exit(1);
    };
    var scanner = try library.open(gpa, device);
    defer scanner.close(gpa);
    var capabilities = try scanner.capabilities(gpa, if (flatbed) .flatbed else .transparency);
    defer capabilities.deinit(gpa);
    const resolution = capabilities.resolutionFrom(dpi) orelse return error.NoResolutions;
    std.log.info("{s} {s}: {t}, {d} dpi, {s}", .{ device.vendor, device.model, capabilities.source, resolution, if (capabilities.profile) |p| p.summary else "no profile: the data may not be linear" });
    var progress: scan.Progress = .{};
    var image = try scanner.scan(gpa, .{ .source = capabilities.source, .film = film, .dpi = resolution, .area = area }, &progress);
    defer image.deinit(gpa);
    const ppm = try minilab.pnm.write(gpa, u16, .{ .width = image.width, .height = image.height, .pixels = image.pixels });
    defer gpa.free(ppm);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output.?, .data = ppm });
    std.log.info("{s}: {d} × {d} px, {d}-bit, {d:.2} × {d:.2} mm at {d:.2}, {d:.2} mm", .{ output.?, image.width, image.height, image.depth, image.area.width, image.area.height, image.area.x, image.area.y });
}

/// `minilab scan`'s resolution when none is given: a quick preview.
const default_scan_dpi = 300;

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = log };

/// Whether debug messages are shown: `--verbose` anywhere on the command line.
var verbose = false;

fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .debug and !verbose) return;
    std.log.defaultLog(level, scope, format, args);
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const arena = init.arena.allocator();
    const all_args = try init.minimal.args.toSlice(arena);
    var kept: std.ArrayList([:0]const u8) = .empty;
    for (all_args) |arg| {
        if (std.mem.eql(u8, arg, "--verbose")) verbose = true else try kept.append(arena, arg);
    }
    const args = kept.items;
    if (args.len == 2 and std.mem.eql(u8, args[1], "--version")) return printOut(init.io, "minilab " ++ version.string ++ "\n");
    if (args.len == 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h"))) return printOut(init.io, usage);
    if (args.len == 2 and std.mem.eql(u8, args[1], "looks")) return listLooks(init.io);
    const library = try defaultLibrary(arena, init.environ_map);
    const home = homeFolder(init.environ_map);
    if (args.len < 2) return app.run(gpa, init.io, .{ .library = library, .home = home });
    if (std.mem.eql(u8, args[1], "open")) return app.run(gpa, init.io, parseOpen(arena, library, home, args[2..]) catch exitWithUsage());
    if (std.mem.eql(u8, args[1], "develop-roll")) {
        return developRoll(gpa, init.io, args[2..]) catch |err| switch (err) {
            error.Usage => exitWithUsage(),
            else => return err,
        };
    }
    if (std.mem.eql(u8, args[1], "scan")) {
        return scanCommand(gpa, init.io, args[2..]) catch |err| switch (err) {
            error.Usage => exitWithUsage(),
            else => return err,
        };
    }
    if (std.mem.eql(u8, args[1], "detect")) {
        return detectFrames(gpa, init.io, args[2..]) catch |err| switch (err) {
            error.Usage => exitWithUsage(),
            else => return err,
        };
    }
    if (std.mem.eql(u8, args[1], "import")) return importScans(gpa, init.io, parseImport(arena, library, args[2..]) catch exitWithUsage());
    if (!std.mem.eql(u8, args[1], "develop")) exitWithUsage();
    try developFile(gpa, init.io, parse(args[2..]) catch exitWithUsage());
}

/// Writes `text` to standard output.
fn printOut(io: std.Io, text: []const u8) !void {
    var buffer: [256]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    try stdout.interface.writeAll(text);
    try stdout.interface.flush();
}

/// The library's folder when none is given: Pictures/Rolls in the user's home.
fn defaultLibrary(arena: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    const home = homeFolder(environ) orelse return "Rolls";
    return std.fs.path.join(arena, &.{ home, "Pictures", "Rolls" });
}

fn homeFolder(environ: *const std.process.Environ.Map) ?[]const u8 {
    return environ.get("HOME") orelse environ.get("USERPROFILE");
}

fn parseOpen(arena: std.mem.Allocator, library: []const u8, home: ?[]const u8, args: []const [:0]const u8) !app.Options {
    var options: app.Options = .{ .library = library, .home = home };
    var paths: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        const takes_value = for ([_][]const u8{ "--screenshot", "--library", "--roll", "--workspace" }) |flag| {
            if (std.mem.eql(u8, arg, flag)) break true;
        } else false;
        if (std.mem.eql(u8, arg, "--shortcuts")) {
            options.shortcuts = true;
            continue;
        }
        if (!takes_value) {
            try paths.append(arena, arg);
            continue;
        }
        i += 1;
        if (i == args.len) return error.MissingValue;
        const value = args[i];
        if (std.mem.eql(u8, arg, "--screenshot")) options.screenshot = value;
        if (std.mem.eql(u8, arg, "--library")) options.library = value;
        if (std.mem.eql(u8, arg, "--roll")) {
            options.roll = value;
            options.workspace = .develop;
        }
        if (std.mem.eql(u8, arg, "--workspace")) options.workspace = std.meta.stringToEnum(app.Workspace, value) orelse return error.UnknownWorkspace;
    }
    options.open = paths.items;
    if (paths.items.len > 0 and options.roll == null) options.workspace = .develop;
    return options;
}

/// Develops scans of one roll together into `out folder`, as `<scan name>-<look>.tif`: each cut to
/// the frame found on it, on one film base for the roll (the median of the frames' gaps). A strip
/// gives each of its frames, as `<scan name>-<n>-<look>.tif`.
fn developRoll(gpa: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var look_name: []const u8 = "neutral";
    var kind: minilab.develop.FilmKind = .colour_negative;
    var given_base: ?[3]f32 = null;
    var stock_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--look") and i + 1 < args.len) {
            i += 1;
            look_name = args[i];
        } else if (std.mem.eql(u8, arg, "--stock") and i + 1 < args.len) {
            i += 1;
            stock_name = args[i];
        } else if (std.mem.eql(u8, arg, "--film") and i + 1 < args.len) {
            i += 1;
            kind = try parseFilm(args[i], negative_films);
        } else if (std.mem.eql(u8, arg, "--base") and i + 1 < args.len) {
            i += 1;
            given_base = try parseNumbers(minilab.image.channel_count, args[i]);
        } else try paths.append(gpa, arg);
    }
    if (paths.items.len < 2) return error.Usage;
    const out_dir = paths.items[0];
    const inputs = paths.items[1..];
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    // Each frame, cut to its crop, and the base in its gaps.
    var frames: std.ArrayList(RollFrame) = .empty;
    defer {
        for (frames.items) |*f| f.deinit(gpa);
        frames.deinit(gpa);
    }
    var bases: [3]std.ArrayList(f32) = .{ .empty, .empty, .empty };
    defer for (&bases) |*b| b.deinit(gpa);
    const format = minilab.formats.Standard.default.format();
    for (inputs) |path| {
        var full = (try minilab.input.read(gpa, io, path)).scan;
        defer full.deinit(gpa);
        var reduced = try minilab.image.downscale(gpa, full, minilab.framing.detection_longest);
        defer reduced.deinit(gpa);
        const stem = std.fs.path.stem(path);
        const found = minilab.framing.findAll(gpa, reduced, full.width, full.height, null, format, kind) catch |err| {
            std.log.warn("{s}: no frame found ({t}); using all of the scan", .{ path, err });
            try frames.ensureUnusedCapacity(gpa, 1);
            frames.appendAssumeCapacity(try .of(gpa, full, .whole(full.width, full.height), try gpa.dupe(u8, stem)));
            continue;
        };
        defer gpa.free(found);
        for (found, 1..) |f, number| {
            if (try minilab.framing.measureBase(gpa, full, f.gaps)) |b| {
                for (&bases, b) |*list, v| try list.append(gpa, v);
            }
            const name = if (found.len == 1) try gpa.dupe(u8, stem) else try std.fmt.allocPrint(gpa, "{s}-{d}", .{ stem, number });
            try frames.ensureUnusedCapacity(gpa, 1);
            frames.appendAssumeCapacity(try .of(gpa, full, f.frame, name));
        }
    }
    var base: [3]f32 = given_base orelse base: {
        if (bases[0].items.len == 0) return error.NoFilmBase;
        var b: [3]f32 = undefined;
        for (&b, &bases) |*v, *list| {
            std.mem.sort(f32, list.items, {}, std.sort.asc(f32));
            v.* = list.items[list.items.len / 2];
        }
        break :base b;
    };
    _ = &base;
    std.log.info("roll film base: {d:.4} {d:.4} {d:.4}", .{ base[0], base[1], base[2] });

    var catalog: minilab.look.Catalog = try .init(gpa, null);
    defer catalog.deinit(gpa);
    const look = try lookNamed(gpa, io, &catalog, look_name);
    defer freeLook(gpa, look, look_name);
    const suffix = std.fs.path.stem(look_name);
    const curves = if (stock_name) |name| try stockNamed(name, kind) else null;
    for (frames.items) |frame| {
        var developed = try minilab.look.developFrame(gpa, frame.scan, .whole(frame.scan.width, frame.scan.height), kind, look, base, .{ .curves = if (curves) |*cv| cv else null });
        defer developed.deinit(gpa);
        var encoded = try minilab.encode.toSrgb16(gpa, developed);
        defer encoded.deinit(gpa);
        try writeFrame(gpa, io, out_dir, frame.stem, suffix, u16, encoded);
    }
}

/// A frame `develop-roll` develops: its part of the scan, and its file's name before the look's.
const RollFrame = struct {
    scan: minilab.image.Scan,
    stem: []const u8,

    /// `area` of `full`, as the frame `stem`, which it takes; it frees `stem` if it fails.
    fn of(gpa: std.mem.Allocator, full: minilab.image.Scan, area: minilab.image.Area, stem: []const u8) !RollFrame {
        errdefer gpa.free(stem);
        return .{ .scan = try full.crop(gpa, area), .stem = stem };
    }

    fn deinit(frame: *RollFrame, gpa: std.mem.Allocator) void {
        frame.scan.deinit(gpa);
        gpa.free(frame.stem);
    }
};

fn writeFrame(gpa: std.mem.Allocator, io: std.Io, out_dir: []const u8, stem: []const u8, suffix: []const u8, comptime Sample: type, encoded: minilab.image.Image([3]Sample)) !void {
    const name = try std.fmt.allocPrint(gpa, "{s}-{s}.tif", .{ stem, suffix });
    defer gpa.free(name);
    const path = try std.fs.path.join(gpa, &.{ out_dir, name });
    defer gpa.free(path);
    const file = try srgbTiff(gpa, Sample, encoded);
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = file });
    std.log.info("{s}", .{path});
}

/// Prints each frame frame detection finds on a strip scan: its number, its box in mm from the
/// scan's top left, and whether it's sure. Scanners take their scan areas in mm.
fn detectFrames(gpa: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    var path: ?[]const u8 = null;
    var dpi: ?f32 = null;
    var kind: minilab.develop.FilmKind = .colour_negative;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--dpi") and i + 1 < args.len) {
            i += 1;
            dpi = std.fmt.parseFloat(f32, args[i]) catch return error.Usage;
        } else if (std.mem.eql(u8, args[i], "--film") and i + 1 < args.len) {
            i += 1;
            kind = try parseFilm(args[i], .full);
        } else path = args[i];
    }
    const scan_path = path orelse return error.Usage;
    const resolution = dpi orelse return error.Usage;
    var scan = (try minilab.input.read(gpa, io, scan_path)).scan;
    defer scan.deinit(gpa);
    const format = minilab.formats.Standard.default.format();
    var found = try minilab.frames.detect.detect(gpa, scan, resolution, format, if (kind.isNegative()) .negative else .positive, .{});
    defer found.deinit(gpa);
    const mm = minilab.formats.mm_per_inch / resolution;
    std.debug.print("axis {t}, skew {d:.2}°, opening {d:.1} mm\n", .{ found.axis, found.rotation_degrees, found.opening_mm });
    for (found.frames) |f| {
        const a = f.area;
        std.debug.print("frame {d}: x {d:.2} y {d:.2} w {d:.2} h {d:.2} mm, {t}\n", .{
            f.index + 1,
            @as(f32, @floatFromInt(a.x)) * mm,
            @as(f32, @floatFromInt(a.y)) * mm,
            @as(f32, @floatFromInt(a.width)) * mm,
            @as(f32, @floatFromInt(a.height)) * mm,
            f.confidence,
        });
    }
}

const ImportOptions = struct {
    library: []const u8,
    roll: []const u8,
    scans: []const []const u8,
    stock: ?[]const u8 = null,
    kind: minilab.develop.FilmKind = .colour_negative,
    /// A shot of the light source with no film, for the roll's flat field.
    flat: ?[]const u8 = null,
};

fn parseImport(arena: std.mem.Allocator, library: []const u8, args: []const [:0]const u8) !ImportOptions {
    var options: ImportOptions = .{ .library = library, .roll = undefined, .scans = undefined };
    var positional: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--library") or std.mem.eql(u8, arg, "--stock") or std.mem.eql(u8, arg, "--film") or std.mem.eql(u8, arg, "--flat")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            const value = args[i];
            if (std.mem.eql(u8, arg, "--library")) options.library = value;
            if (std.mem.eql(u8, arg, "--stock")) options.stock = value;
            if (std.mem.eql(u8, arg, "--flat")) options.flat = value;
            if (std.mem.eql(u8, arg, "--film")) options.kind = try parseFilm(value, .full);
        } else try positional.append(arena, arg);
    }
    if (positional.items.len < 2) return error.MissingArgument;
    options.roll = positional.items[0];
    options.scans = positional.items[1..];
    return options;
}

/// Adds scans to the roll of that name in the library, making it first if there is none: a frame
/// for each, or for each frame on a strip. With a flat field, the roll keeps it, and every scan
/// is divided by the roll's flat field, this one or one it had already.
fn importScans(gpa: std.mem.Allocator, io: std.Io, options: ImportOptions) !void {
    const path = try std.fs.path.join(gpa, &.{ options.library, options.roll });
    defer gpa.free(path);
    var roll = minilab.roll.Roll.open(gpa, io, path) catch |err| switch (err) {
        error.FileNotFound => try minilab.roll.Roll.create(gpa, io, options.library, .{ .name = options.roll, .kind = options.kind, .stock = options.stock }),
        else => return err,
    };
    defer roll.close();
    if (options.flat) |flat_path| {
        var shot = try minilab.input.read(gpa, io, flat_path);
        defer shot.deinit(gpa);
        try roll.setFlatField(gpa, io, shot.scan);
        std.debug.print("{s} → {s} flat field\n", .{ flat_path, options.roll });
    }
    var flat = try roll.flatField(gpa, io);
    defer if (flat) |*f| f.deinit(gpa);
    for (options.scans) |scan| {
        const added = try roll.importFile(gpa, io, scan, if (flat) |*f| f else null);
        if (added.count == 1) {
            std.debug.print("{s} → {s} frame {d}\n", .{ scan, options.roll, added.first + 1 });
        } else {
            std.debug.print("{s} → {s} frames {d} to {d}\n", .{ scan, options.roll, added.first + 1, added.first + added.count });
        }
    }
}

fn parse(args: []const [:0]const u8) !Options {
    var positional: [2][]const u8 = undefined;
    var count: usize = 0;
    var options: Options = .{ .input = undefined, .output = undefined };
    var stock_name: ?[]const u8 = null;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--look")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            options.look = args[i];
        } else if (std.mem.eql(u8, arg, "--film")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            options.kind = try parseFilm(args[i], negative_films);
        } else if (std.mem.eql(u8, arg, "--whole")) {
            options.whole = true;
        } else if (std.mem.eql(u8, arg, "--stock")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            stock_name = args[i];
        } else if (std.mem.eql(u8, arg, "--base")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            options.base = try parseNumbers(minilab.image.channel_count, args[i]);
        } else if (std.mem.eql(u8, arg, "--depth")) {
            i += 1;
            if (i == args.len) return error.MissingValue;
            options.depth = if (std.mem.eql(u8, args[i], "8")) .eight else if (std.mem.eql(u8, args[i], "16")) .sixteen else return error.UnknownDepth;
        } else {
            if (count == positional.len) return error.TooManyArguments;
            positional[count] = arg;
            count += 1;
        }
    }
    if (count != positional.len) return error.MissingArgument;
    options.input = positional[0];
    options.output = positional[1];
    if (stock_name) |name| options.curves = try stockNamed(name, options.kind);
    return options;
}

fn formatOf(path: []const u8) !Format {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".tif") or std.ascii.eqlIgnoreCase(extension, ".tiff")) return .tiff;
    if (std.ascii.eqlIgnoreCase(extension, ".ppm")) return .ppm;
    return error.UnknownOutputFormat;
}

/// Develops the scan `options.input` into `options.output`: the frame found on it, or each frame of
/// a strip, as `<out>-1.tif`, `<out>-2.tif` and so on.
fn developFile(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    var full = (try minilab.input.read(gpa, io, options.input)).scan;
    defer full.deinit(gpa);
    const format = try formatOf(options.output);

    // The frames on the scan, as the app finds them, unless all of it is asked for.
    var reduced = try minilab.image.downscale(gpa, full, minilab.framing.detection_longest);
    defer reduced.deinit(gpa);
    const found: []const minilab.framing.Found = if (options.whole) &.{} else minilab.framing.findAll(gpa, reduced, full.width, full.height, null, minilab.formats.Standard.default.format(), options.kind) catch |err| found: {
        std.log.warn("no frame found ({t}); developing all of the scan", .{err});
        break :found &.{};
    };
    defer gpa.free(found);

    var catalog: minilab.look.Catalog = try .init(gpa, null);
    defer catalog.deinit(gpa);
    const look = try lookNamed(gpa, io, &catalog, options.look);
    defer freeLook(gpa, look, options.look);
    if (found.len == 0) return developArea(gpa, io, options, format, look, full, .whole(full.width, full.height), options.base, options.output);
    for (found, 1..) |f, number| {
        // The film base from the clear film between frames, when the gaps are on the scan.
        const base = options.base orelse try minilab.framing.measureBase(gpa, full, f.gaps);
        const output = if (found.len == 1) options.output else try numbered(gpa, options.output, number);
        defer if (found.len > 1) gpa.free(output);
        try developArea(gpa, io, options, format, look, full, f.frame, base, output);
        if (found.len > 1) std.log.info("{s}", .{output});
    }
}

/// Develops `area` of `full` on the film base `base`, and writes it to `output`.
fn developArea(gpa: std.mem.Allocator, io: std.Io, options: Options, format: Format, look: minilab.look.Resolved, full: minilab.image.Scan, area: minilab.image.Area, base: ?[3]f32, output: []const u8) !void {
    if (base) |b| std.log.info("film base: {d:.4} {d:.4} {d:.4}", .{ b[0], b[1], b[2] });
    var scan = try full.crop(gpa, area);
    defer scan.deinit(gpa);
    var developed = try minilab.look.developFrame(gpa, scan, .whole(scan.width, scan.height), options.kind, look, base, .{ .curves = if (options.curves) |*cv| cv else null });
    defer developed.deinit(gpa);

    const file = switch (options.depth) {
        .eight => blk: {
            var encoded = try minilab.encode.toSrgb8(gpa, developed);
            defer encoded.deinit(gpa);
            break :blk try write(gpa, format, u8, encoded);
        },
        .sixteen => blk: {
            var encoded = try minilab.encode.toSrgb16(gpa, developed);
            defer encoded.deinit(gpa);
            break :blk try write(gpa, format, u16, encoded);
        },
    };
    defer gpa.free(file);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output, .data = file });
}

/// `path` with `-<number>` before its extension: out.tif becomes out-2.tif.
fn numbered(gpa: std.mem.Allocator, path: []const u8, number: usize) ![]u8 {
    const extension = std.fs.path.extension(path);
    return std.fmt.allocPrint(gpa, "{s}-{d}{s}", .{ path[0 .. path.len - extension.len], number, extension });
}

fn write(gpa: std.mem.Allocator, format: Format, comptime Sample: type, encoded: minilab.image.Image([3]Sample)) ![]u8 {
    return switch (format) {
        .tiff => srgbTiff(gpa, Sample, encoded),
        .ppm => minilab.pnm.write(gpa, Sample, encoded),
    };
}

/// `encoded`, which is sRGB, as a TIFF with sRGB's ICC profile.
fn srgbTiff(gpa: std.mem.Allocator, comptime Sample: type, encoded: minilab.image.Image([3]Sample)) ![]u8 {
    const profile = try minilab.codecs.icc.profileBytes(gpa, .srgb);
    defer gpa.free(profile);
    return minilab.codecs.tiff.write(gpa, Sample, encoded, .{ .icc_profile = profile });
}

test "--film names one of the films the command takes" {
    try std.testing.expectEqual(minilab.develop.FilmKind.colour_positive, try parseFilm("slide", .full));
    try std.testing.expectEqual(minilab.develop.FilmKind.bw_negative, try parseFilm("bw", negative_films));
    try std.testing.expectError(error.Usage, parseFilm("slide", negative_films));
    try std.testing.expectError(error.Usage, parseFilm("sepia", .full));
}

test "comma-separated numbers" {
    try std.testing.expectEqual([3]f32{ 0.5, 0.25, 0.125 }, try parseNumbers(3, "0.5,0.25,0.125"));
    try std.testing.expectError(error.Usage, parseNumbers(3, "0.5,0.25"));
    try std.testing.expectError(error.Usage, parseNumbers(3, "0.5,grey,0.125"));
    try std.testing.expectError(error.Usage, parseNumbers(3, "0.5,0.25,0.125,1"));
    try std.testing.expectError(error.Usage, parseNumbers(3, "0.5,nan,0.125"));
}

test "a developed TIFF carries sRGB's profile" {
    const gpa = std.testing.allocator;
    var encoded: minilab.image.Encoded8 = try .init(gpa, 2, 1);
    defer encoded.deinit(gpa);
    @memset(encoded.pixels, .{ 10, 20, 30 });
    const file = try srgbTiff(gpa, u8, encoded);
    defer gpa.free(file);
    var decoded = try minilab.codecs.tiff.read(gpa, file);
    defer decoded.deinit(gpa);
    const profile = try minilab.codecs.icc.profileBytes(gpa, .srgb);
    defer gpa.free(profile);
    try std.testing.expectEqualSlices(u8, profile, decoded.icc_profile.?);
}

test {
    _ = @import("app/develop_view.zig");
    _ = @import("app/scan_view.zig");
    _ = @import("app/scan_worker.zig");
    _ = @import("app/looks_view.zig");
}

test {
    _ = version;
    _ = @import("platform/icon.zig");
}
