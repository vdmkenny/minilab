//! minilab's entry point. With no arguments it opens the app; with a command, it runs that
//! command on the command line.

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
    \\  minilab import <roll name> <scan or folder>...
    \\      [--library <folder>] [--stock <name>] [--film colour|bw|slide]
    \\      [--flat <file>] [--move]     add scans to a roll, and make the roll if it doesn't exist
    \\                                   yet. Takes PPM or PGM, 16-bit linear TIFF, camera RAW, or
    \\                                   JPEG for finished pictures such as a lab's scans, which
    \\                                   the roll keeps as they are. A folder adds the scans in it.
    \\                                   --move moves finished pictures into the roll instead of
    \\                                   copying them. A strip scan becomes one frame per frame
    \\                                   found on it.
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

/// Prints the usage and exits, for a command line minilab doesn't understand.
fn exitWithUsage() noreturn {
    std.debug.print("{s}", .{usage});
    std.process.exit(usage_status);
}

/// The film kinds `--film` takes.
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

/// The film kinds `develop` and `develop-roll` accept.
const negative_films: std.EnumSet(FilmName) = .initMany(&.{ .colour, .bw });

/// Returns the film kind `--film <value>` names, as long as it's one the command `takes`.
/// A command's arguments, read one at a time: flags, the values that follow them, and the rest. A
/// mistake in them, such as a flag with no value or one the command doesn't know, is
/// `error.Usage`, which prints the usage.
const Args = struct {
    list: []const [:0]const u8,
    at: usize = 0,

    fn next(args: *Args) ?[:0]const u8 {
        if (args.at == args.list.len) return null;
        const arg = args.list[args.at];
        args.at += 1;
        return arg;
    }

    /// The value after the flag just read.
    fn value(args: *Args) error{Usage}![:0]const u8 {
        return args.next() orelse error.Usage;
    }

    /// Whether `arg` is a flag, such as `--dpi`, rather than a path or a name.
    fn isFlag(arg: []const u8) bool {
        return std.mem.startsWith(u8, arg, "--");
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseFilm(value: []const u8, takes: std.EnumSet(FilmName)) error{Usage}!minilab.develop.FilmKind {
    const name = std.meta.stringToEnum(FilmName, value) orelse return error.Usage;
    if (!takes.contains(name)) return error.Usage;
    return name.kind();
}

/// Parses exactly `count` finite numbers, separated by commas, such as `--base r,g,b`.
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
const Depth = minilab.image.Depth;

const Options = struct {
    input: []const u8,
    output: []const u8,
    /// "neutral", "frontier", a film look's id from `minilab looks`, or the path to a .cube file.
    look: []const u8 = "neutral",
    kind: minilab.develop.FilmKind = .colour_negative,
    depth: Depth = .sixteen,
    /// Develop the whole scan instead of the frame found on it.
    whole: bool = false,
    /// The film base's transmission per channel, 0..1, when known from elsewhere on the roll.
    base: ?[3]f32 = null,
    /// The stock's curves, from `--stock`.
    curves: ?minilab.stock_curves.Curves = null,
};

/// Returns the curves of the stock called `name`, for film `kind`, in Status M, since the command
/// line has no scanner calibration. A stock of another kind of film is refused, as in the app:
/// a B&W stock's curves would be wrong on a colour negative.
fn stockNamed(name: []const u8, kind: minilab.develop.FilmKind) minilab.stock_curves.Curves {
    for (minilab.stocks.stocks) |stock| {
        if (!std.ascii.eqlIgnoreCase(stock.name, name)) continue;
        if (stock.kind != kind) {
            std.log.err("{s} is {t} film, not {t}: give --film to match", .{ stock.name, stock.kind, kind });
            std.process.exit(usage_status);
        }
        const curves = minilab.stock_curves.of(stock, @splat(1)) orelse {
            std.log.err("{s} has no curves for {t}", .{ stock.name, kind });
            std.process.exit(usage_status);
        };
        return curves;
    }
    std.log.err("no stock preset is called {s}", .{name});
    std.process.exit(usage_status);
}

/// Resolves the look a command names: "neutral", "frontier", a film look's id, or the path to a
/// .cube file. `catalog` holds what it reads.
fn lookNamed(gpa: std.mem.Allocator, io: std.Io, catalog: *minilab.look.Catalog, name: []const u8) !minilab.look.Resolved {
    if (std.mem.eql(u8, name, "neutral")) return .neutral;
    if (std.mem.eql(u8, name, "frontier")) return try catalog.resolve(gpa, io, .frontier);
    if (minilab.bundled_looks.find(name)) |index| return try catalog.resolve(gpa, io, .ofBundled(index));
    if (!isCubeFile(name)) {
        std.log.err("no look is called {s}: `minilab looks` lists them", .{name});
        std.process.exit(usage_status);
    }
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(64 << 20));
    defer gpa.free(bytes);
    const lut = try gpa.create(minilab.cube_lut.Lut);
    errdefer gpa.destroy(lut);
    lut.* = try minilab.cube_lut.Lut.parse(gpa, bytes);
    return .{ .lut = lut };
}

/// Frees a look that `lookNamed` read from a .cube file. The catalog keeps the others.
fn freeLook(gpa: std.mem.Allocator, look: minilab.look.Resolved, name: []const u8) void {
    if (look != .lut or !isCubeFile(name)) return;
    const lut: *minilab.cube_lut.Lut = @constCast(look.lut);
    lut.deinit(gpa);
    gpa.destroy(lut);
}

fn isCubeFile(name: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(name, minilab.look.cube_extension);
}

/// `minilab looks`: lists the looks `--look` takes by name, each with its human-readable name.
fn listLooks(io: std.Io) !void {
    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), io, &buffer);
    const out = &stdout.interface;
    const look = minilab.look;
    for ([_]look.Id{ .neutral, .frontier }) |id| try out.print("{s:<40} {s}\n", .{ id.text(), id.label() });
    for (minilab.bundled_looks.looks) |b| try out.print("{s:<40} {s}\n", .{ b.id, b.label });
    try out.flush();
}

/// `minilab scan`: lists the scanners, or makes one scan into a 16-bit PPM. The scan is raw when
/// the scanner has a profile.
fn scanCommand(gpa: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    const scan = minilab.scan;
    var list = false;
    var output: ?[]const u8 = null;
    var wanted: ?[]const u8 = null;
    var dpi: u32 = default_scan_dpi;
    var area: ?scan.Area = null;
    var film: scan.Film = .positive;
    var flatbed = false;
    var each: Args = .{ .list = args };
    while (each.next()) |arg| {
        if (eql(arg, "--list")) {
            list = true;
        } else if (eql(arg, "--flatbed")) {
            flatbed = true;
        } else if (eql(arg, "--device")) {
            wanted = try each.value();
        } else if (eql(arg, "--dpi")) {
            dpi = std.fmt.parseInt(u32, try each.value(), 10) catch return error.Usage;
        } else if (eql(arg, "--film")) {
            film = std.meta.stringToEnum(scan.Film, try each.value()) orelse return error.Usage;
        } else if (eql(arg, "--area")) {
            const x, const y, const width, const height = try parseNumbers(4, try each.value());
            area = .{ .x = x, .y = y, .width = width, .height = height };
        } else if (output == null and !Args.isFlag(arg)) {
            output = arg;
        } else return error.Usage;
    }
    if (!list and output == null) return error.Usage;

    var library = scan.Library.load(gpa, io) catch |err| {
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
    defer scanner.close();
    var capabilities = try scanner.capabilities(gpa, if (flatbed) .flatbed else .transparency);
    defer capabilities.deinit(gpa);
    const resolution = capabilities.resolutionFrom(dpi) orelse return error.NoResolutions;
    var raw_buffer: [96]u8 = undefined;
    const setup = if (capabilities.profile) |p| p.summary else if (capabilities.options) |o| scan.rawSetup(o.items, &.{}).report.label(&raw_buffer) else "no profile: the data may not be linear";
    std.log.info("{s} {s}: {t}, {d} dpi, {s}", .{ device.vendor, device.model, capabilities.source, resolution, setup });
    var progress: scan.Progress = .{};
    var image = try scanner.scan(gpa, .{ .source = capabilities.source, .film = film, .dpi = resolution, .area = area }, &progress);
    defer image.deinit(gpa);
    const ppm = try minilab.pnm.write(gpa, u16, image.scan);
    defer gpa.free(ppm);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = output.?, .data = ppm });
    std.log.info("{s}: {d} × {d} px, {d}-bit, {d:.2} × {d:.2} mm at {d:.2}, {d:.2} mm", .{ output.?, image.scan.width, image.scan.height, image.depth.bits(), image.area.width, image.area.height, image.area.x, image.area.y });
}

/// The resolution `minilab scan` uses when none is given, good for a quick preview.
const default_scan_dpi = 300;

pub const std_options: std.Options = .{ .log_level = .debug, .logFn = log };

/// Whether to show debug messages. `--verbose` anywhere on the command line turns them on.
var verbose = false;

fn log(comptime level: std.log.Level, comptime scope: @EnumLiteral(), comptime format: []const u8, args: anytype) void {
    if (level == .debug and !verbose) return;
    std.log.defaultLog(level, scope, format, args);
}

/// Runs the app, and after it installs an update, starts the new version with the same `argv`.
fn runApp(gpa: std.mem.Allocator, io: std.Io, options: app.Options, argv: []const [:0]const u8) !void {
    const folder = try app.run(gpa, io, options) orelse return;
    defer gpa.free(folder);
    const plain = try gpa.alloc([]const u8, argv.len);
    defer gpa.free(plain);
    for (plain, argv) |*p, arg| p.* = arg;
    try minilab.update.restart(io, folder, plain);
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
    if (args.len < 2) return runApp(gpa, init.io, .{ .library = library, .home = home }, all_args);
    if (std.mem.eql(u8, args[1], "open")) return runApp(gpa, init.io, parseOpen(arena, library, home, args[2..]) catch exitWithUsage(), all_args);
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

/// The library folder to use when none is given: Pictures/Rolls in the user's home folder.
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
    var each: Args = .{ .list = args };
    while (each.next()) |arg| {
        if (eql(arg, "--shortcuts")) {
            options.shortcuts = true;
        } else if (eql(arg, "--screenshot")) {
            options.screenshot = try each.value();
        } else if (eql(arg, "--library")) {
            options.library = try each.value();
        } else if (eql(arg, "--roll")) {
            options.roll = try each.value();
            options.workspace = .develop;
        } else if (eql(arg, "--workspace")) {
            options.workspace = std.meta.stringToEnum(app.Workspace, try each.value()) orelse return error.Usage;
        } else if (Args.isFlag(arg)) {
            return error.Usage;
        } else try paths.append(arena, arg);
    }
    options.open = paths.items;
    if (paths.items.len > 0 and options.roll == null) options.workspace = .develop;
    return options;
}

/// Develops scans of one roll together into `out folder`, as `<scan name>-<look>.tif`. Each scan
/// is cut to the frame found on it, and they all use one film base for the roll (the median of the
/// frames' gaps). A strip gives one file per frame, as `<scan name>-<n>-<look>.tif`.
fn developRoll(gpa: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    var paths: std.ArrayList([]const u8) = .empty;
    defer paths.deinit(gpa);
    var look_name: []const u8 = "neutral";
    var kind: minilab.develop.FilmKind = .colour_negative;
    var given_base: ?[3]f32 = null;
    var stock_name: ?[]const u8 = null;
    var each: Args = .{ .list = args };
    while (each.next()) |arg| {
        if (eql(arg, "--look")) {
            look_name = try each.value();
        } else if (eql(arg, "--stock")) {
            stock_name = try each.value();
        } else if (eql(arg, "--film")) {
            kind = try parseFilm(try each.value(), negative_films);
        } else if (eql(arg, "--base")) {
            given_base = try parseNumbers(minilab.image.channel_count, try each.value());
        } else if (Args.isFlag(arg)) {
            return error.Usage;
        } else try paths.append(gpa, arg);
    }
    if (paths.items.len < 2) return error.Usage;
    const out_dir = paths.items[0];
    const inputs = paths.items[1..];
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    // Each frame, cut to its crop, and the base measured in its gaps.
    var frames: std.ArrayList(RollFrame) = .empty;
    defer {
        for (frames.items) |*f| f.deinit(gpa);
        frames.deinit(gpa);
    }
    var bases: std.ArrayList([3]f32) = .empty;
    defer bases.deinit(gpa);
    for (inputs) |path| {
        var full = (try minilab.input.read(gpa, io, path)).scan;
        defer full.deinit(gpa);
        const stem = std.fs.path.stem(path);
        const found = try framesOn(gpa, full, kind, path);
        defer gpa.free(found);
        if (found.len == 0) {
            try frames.ensureUnusedCapacity(gpa, 1);
            frames.appendAssumeCapacity(try .of(gpa, full, .whole(full.width, full.height), try gpa.dupe(u8, stem)));
            continue;
        }
        for (found, 1..) |f, number| {
            if (try minilab.framing.measureBase(gpa, full, f.gaps)) |b| try bases.append(gpa, b);
            const name = if (found.len == 1) try gpa.dupe(u8, stem) else try std.fmt.allocPrint(gpa, "{s}-{d}", .{ stem, number });
            try frames.ensureUnusedCapacity(gpa, 1);
            frames.appendAssumeCapacity(try .of(gpa, full, f.frame, name));
        }
    }
    const base: [3]f32 = given_base orelse base: {
        const scratch = try gpa.alloc(f32, bases.items.len);
        defer gpa.free(scratch);
        break :base minilab.stats.channelMedian(bases.items, scratch) orelse return error.NoFilmBase;
    };
    std.log.info("roll film base: {d:.4} {d:.4} {d:.4}", .{ base[0], base[1], base[2] });

    var catalog: minilab.look.Catalog = try .init(gpa, null);
    defer catalog.deinit(gpa);
    const look = try lookNamed(gpa, io, &catalog, look_name);
    defer freeLook(gpa, look, look_name);
    const suffix = std.fs.path.stem(look_name);
    const curves = if (stock_name) |name| stockNamed(name, kind) else null;
    for (frames.items) |frame| {
        var developed = try minilab.look.developFrame(gpa, frame.scan, .whole(frame.scan.width, frame.scan.height), kind, look, base, .{ .curves = if (curves) |*cv| cv else null });
        defer developed.deinit(gpa);
        var encoded = try minilab.encode.toSrgb16(gpa, developed);
        defer encoded.deinit(gpa);
        try writeFrame(gpa, io, out_dir, frame.stem, suffix, u16, encoded);
    }
}

/// A frame that `develop-roll` develops: its part of the scan, and the start of its file name,
/// before the look's name.
const RollFrame = struct {
    scan: minilab.image.Scan,
    stem: []const u8,

    /// Cuts `area` out of `full` as the frame `stem`. It takes ownership of `stem`, and frees it if
    /// it fails.
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

/// Prints each frame that frame detection finds on a strip scan: its number, its box in mm from
/// the scan's top left, and whether detection is sure of it. Scanners take their scan areas in mm.
fn detectFrames(gpa: std.mem.Allocator, io: std.Io, args: []const [:0]const u8) !void {
    var path: ?[]const u8 = null;
    var dpi: ?f32 = null;
    var kind: minilab.develop.FilmKind = .colour_negative;
    var each: Args = .{ .list = args };
    while (each.next()) |arg| {
        if (eql(arg, "--dpi")) {
            dpi = std.fmt.parseFloat(f32, try each.value()) catch return error.Usage;
        } else if (eql(arg, "--film")) {
            kind = try parseFilm(try each.value(), .full);
        } else if (path == null and !Args.isFlag(arg)) {
            path = arg;
        } else return error.Usage;
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
    /// Whether finished pictures move into the roll rather than being copied.
    transfer: minilab.roll.Transfer = .copy,
};

fn parseImport(arena: std.mem.Allocator, library: []const u8, args: []const [:0]const u8) !ImportOptions {
    var options: ImportOptions = .{ .library = library, .roll = undefined, .scans = undefined };
    var positional: std.ArrayList([]const u8) = .empty;
    var each: Args = .{ .list = args };
    while (each.next()) |arg| {
        if (eql(arg, "--library")) {
            options.library = try each.value();
        } else if (eql(arg, "--stock")) {
            options.stock = try each.value();
        } else if (eql(arg, "--flat")) {
            options.flat = try each.value();
        } else if (eql(arg, "--film")) {
            options.kind = try parseFilm(try each.value(), .full);
        } else if (eql(arg, "--move")) {
            options.transfer = .move;
        } else if (Args.isFlag(arg)) {
            return error.Usage;
        } else try positional.append(arena, arg);
    }
    if (positional.items.len < 2) return error.Usage;
    options.roll = positional.items[0];
    options.scans = positional.items[1..];
    return options;
}

/// Adds scans to the roll with that name in the library, creating the roll if it doesn't exist.
/// Each scan becomes a frame, or a strip becomes one frame per frame on it. Given a flat field,
/// the roll keeps it. Every scan is divided by the roll's flat field, whether that's this one or
/// one it already had.
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
    const scans = try minilab.input.expand(gpa, io, options.scans);
    defer minilab.input.freeExpanded(gpa, scans);
    for (scans) |scan| {
        const added = try roll.importFile(gpa, io, scan, if (flat) |*f| f else null, options.transfer);
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
    var each: Args = .{ .list = args };
    while (each.next()) |arg| {
        if (eql(arg, "--look")) {
            options.look = try each.value();
        } else if (eql(arg, "--film")) {
            options.kind = try parseFilm(try each.value(), negative_films);
        } else if (eql(arg, "--whole")) {
            options.whole = true;
        } else if (eql(arg, "--stock")) {
            stock_name = try each.value();
        } else if (eql(arg, "--base")) {
            options.base = try parseNumbers(minilab.image.channel_count, try each.value());
        } else if (eql(arg, "--depth")) {
            const bits = std.fmt.parseInt(u8, try each.value(), 10) catch return error.Usage;
            options.depth = std.enums.fromInt(Depth, bits) orelse return error.Usage;
        } else if (Args.isFlag(arg) or count == positional.len) {
            return error.Usage;
        } else {
            positional[count] = arg;
            count += 1;
        }
    }
    if (count != positional.len) return error.Usage;
    options.input = positional[0];
    options.output = positional[1];
    if (stock_name) |name| options.curves = stockNamed(name, options.kind);
    return options;
}

fn formatOf(path: []const u8) !Format {
    const extension = std.fs.path.extension(path);
    if (std.ascii.eqlIgnoreCase(extension, ".tif") or std.ascii.eqlIgnoreCase(extension, ".tiff")) return .tiff;
    if (std.ascii.eqlIgnoreCase(extension, ".ppm")) return .ppm;
    return error.UnknownOutputFormat;
}

/// Develops the scan `options.input` into `options.output`: the frame found on it, or each frame
/// of a strip as `<out>-1.tif`, `<out>-2.tif` and so on.
/// The frames on `full`, the scan at `path`, found the way the app finds them. None means use all
/// of the scan. The caller frees the list.
fn framesOn(gpa: std.mem.Allocator, full: minilab.image.Scan, kind: minilab.develop.FilmKind, path: []const u8) ![]const minilab.framing.Found {
    var reduced = try minilab.image.downscale(gpa, full, minilab.framing.detection_longest);
    defer reduced.deinit(gpa);
    return minilab.framing.findAll(gpa, reduced, full.width, full.height, null, minilab.formats.Standard.default.format(), kind) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            std.log.warn("{s}: no frame found ({t}); using all of the scan", .{ path, err });
            return &.{};
        },
    };
}

fn developFile(gpa: std.mem.Allocator, io: std.Io, options: Options) !void {
    var full = (try minilab.input.read(gpa, io, options.input)).scan;
    defer full.deinit(gpa);
    const format = try formatOf(options.output);

    // Find the frames on the scan the way the app does, unless the whole scan was asked for.
    const found: []const minilab.framing.Found = if (options.whole) &.{} else try framesOn(gpa, full, options.kind, options.input);
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

/// Returns `path` with `-<number>` before its extension, so out.tif becomes out-2.tif.
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

/// Encodes `encoded`, which is sRGB, as a TIFF with sRGB's ICC profile.
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
    try std.testing.expect(minilab.codecs.icc.sameProfile(profile, decoded.icc_profile.?));
}

test {
    _ = @import("app/develop_view.zig");
    _ = @import("app/frame.zig");
    _ = @import("platform/trash.zig");
    _ = @import("app/scan_view.zig");
    _ = @import("app/scan_worker.zig");
    _ = @import("app/update_view.zig");
    _ = @import("app/update_worker.zig");
    _ = @import("app/looks_view.zig");
    _ = @import("app/export_view.zig");
    _ = @import("app/rolls_view.zig");
    _ = @import("app/library.zig");
    _ = @import("app/labels.zig");
    _ = @import("app/shortcuts.zig");
    _ = @import("ui/gui.zig");
    _ = @import("ui/theme.zig");
    _ = @import("platform/window.zig");
}

test {
    _ = version;
    _ = @import("platform/icon.zig");
}

test "a command's flags take the value after them, and a mistake is a usage error" {
    const parsed = try parse(&.{ "in.ppm", "out.tif", "--film", "bw", "--depth", "8", "--whole" });
    try std.testing.expectEqual(minilab.develop.FilmKind.bw_negative, parsed.kind);
    try std.testing.expectEqual(Depth.eight, parsed.depth);
    try std.testing.expect(parsed.whole);
    try std.testing.expectError(error.Usage, parse(&.{ "in.ppm", "out.tif", "--look" }));
    try std.testing.expectError(error.Usage, parse(&.{ "in.ppm", "out.tif", "--bogus" }));
    try std.testing.expectError(error.Usage, parse(&.{ "in.ppm", "out.tif", "third.tif" }));
}
