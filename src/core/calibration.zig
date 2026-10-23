//! Calibrates a scanner (or a camera) against the film makers' datasheets, so that a stock's
//! published contrasts can set the balance of its layers.
//!
//! A datasheet gives each layer's contrast (gamma) in Status M density, which is density read
//! through the standard filters labs use. A scanner's channels see the dyes through different
//! filters, so its densities come out different: on our V200, a colour negative's red needs 1.3 to
//! 1.7 times blue's slope, where Status M says 1.14. That difference comes from the scanner, not
//! the film, as long as each channel mostly reads one dye. So we measure it once per scanner, and
//! it holds for every stock:
//!
//! 1. On a roll of a stock with a preset, each frame's automatic balance gives the slopes that
//!    make that frame's neutrals neutral, relative to green.
//! 2. Taking the median over the roll cancels out the colours of the scenes themselves.
//! 3. Divide that by the slopes the datasheet predicts, and you get the scanner's factors.
//!
//! A stock's balance on that scanner is then its datasheet slopes times the factors. More rolls,
//! of any stock, refine the factors: the calibration is the median over all of them. They're kept
//! per scanner, under the name the roll records, in the library's calibration.json.

const std = @import("std");
const Io = std.Io;
const stats = @import("stats.zig");

pub const file_name = "calibration.json";
/// Added to the name of a calibration.json that can't be read, when it's moved aside.
pub const unreadable_suffix = ".bad";
/// The fewest frames a roll needs for a calibration. With fewer, the median still follows the
/// scenes.
pub const min_frames = 4;

/// What one roll measured.
pub const Measurement = struct {
    roll: []const u8,
    stock: []const u8,
    frames: u32,
    /// The scanner's slope over the datasheet's, per layer, with green at 1.
    factors: [3]f32,
};

pub const Scanner = struct {
    name: []const u8,
    rolls: []const Measurement,
};

/// The layout of calibration.json.
const File = struct {
    scanners: []const Scanner = &.{},
};

/// The library's calibrations. The strings and lists live in the arena, and get copied when
/// something changes.
pub const Calibrations = struct {
    arena: std.heap.ArenaAllocator,
    scanners: []const Scanner = &.{},
    /// Where calibration.json is, or null if there's no file (as in the tests).
    path: ?[]const u8 = null,

    /// Reads the calibrations in `library`. A library without the file just has none.
    pub fn load(gpa: std.mem.Allocator, io: Io, library: []const u8) !Calibrations {
        var calibrations: Calibrations = .{ .arena = .init(gpa) };
        errdefer calibrations.arena.deinit();
        const a = calibrations.arena.allocator();
        calibrations.path = try std.fs.path.join(a, &.{ library, file_name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, calibrations.path.?, a, .limited(max_bytes)) catch |err| switch (err) {
            error.FileNotFound => return calibrations,
            else => return err,
        };
        const file = std.json.parseFromSliceLeaky(File, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            // Move it aside rather than write over it with the next roll's measurement, so the
            // measurements in it aren't lost.
            const aside = try std.fmt.allocPrint(a, "{s}{s}", .{ calibrations.path.?, unreadable_suffix });
            Io.Dir.cwd().rename(calibrations.path.?, Io.Dir.cwd(), aside, io) catch |rename_err| {
                std.log.warn("{s} can't be read ({t}) or moved aside ({t}); calibrations won't be saved", .{ calibrations.path.?, err, rename_err });
                calibrations.path = null;
                return calibrations;
            };
            std.log.warn("{s} can't be read ({t}); moved it to {s} and starting without calibrations", .{ calibrations.path.?, err, aside });
            return calibrations;
        };
        calibrations.scanners = file.scanners;
        return calibrations;
    }

    pub fn deinit(calibrations: *Calibrations) void {
        calibrations.arena.deinit();
        calibrations.* = undefined;
    }

    fn find(calibrations: *const Calibrations, scanner: []const u8) ?*const Scanner {
        for (calibrations.scanners) |*s| if (std.mem.eql(u8, s.name, scanner)) return s;
        return null;
    }

    /// Returns the rolls `scanner` is calibrated from.
    pub fn rolls(calibrations: *const Calibrations, scanner: []const u8) []const Measurement {
        const s = calibrations.find(scanner) orelse return &.{};
        return s.rolls;
    }

    /// Returns `scanner`'s factors: the median over its rolls, per layer. Returns null until it
    /// has a roll.
    pub fn factors(calibrations: *const Calibrations, scanner: []const u8) ?[3]f32 {
        const measured = calibrations.rolls(scanner);
        var colours: [max_rolls][3]f32 = undefined;
        const count = @min(measured.len, max_rolls);
        for (colours[0..count], measured[0..count]) |*c, m| c.* = m.factors;
        var scratch: [max_rolls]f32 = undefined;
        return stats.channelMedian(colours[0..count], &scratch);
    }

    /// Records `measurement` for `scanner`, replacing any earlier one from the same roll, and
    /// writes the file.
    pub fn add(calibrations: *Calibrations, io: Io, scanner: []const u8, measurement: Measurement) !void {
        const a = calibrations.arena.allocator();
        const copy: Measurement = .{
            .roll = try a.dupe(u8, measurement.roll),
            .stock = try a.dupe(u8, measurement.stock),
            .frames = measurement.frames,
            .factors = measurement.factors,
        };
        var scanners: std.ArrayList(Scanner) = .empty;
        var found = false;
        for (calibrations.scanners) |s| {
            if (!std.mem.eql(u8, s.name, scanner)) {
                try scanners.append(a, s);
                continue;
            }
            found = true;
            var measured: std.ArrayList(Measurement) = .empty;
            for (s.rolls) |m| if (!std.mem.eql(u8, m.roll, measurement.roll)) try measured.append(a, m);
            try measured.append(a, copy);
            try scanners.append(a, .{ .name = s.name, .rolls = measured.items });
        }
        if (!found) try scanners.append(a, .{ .name = try a.dupe(u8, scanner), .rolls = try a.dupe(Measurement, &.{copy}) });
        calibrations.scanners = scanners.items;
        try calibrations.save(io);
    }

    fn save(calibrations: *Calibrations, io: Io) !void {
        const path = calibrations.path orelse return;
        const a = calibrations.arena.allocator();
        const bytes = try std.json.Stringify.valueAlloc(a, File{ .scanners = calibrations.scanners }, .{ .whitespace = .indent_2 });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }
};

/// Works out a scanner's factors from one roll of a stock whose datasheet gammas are `gamma` (R,
/// G, B). `slopes` are the frames' neutral slopes, relative to green. Returns null with fewer than
/// `min_frames` frames.
pub fn measure(slopes: []const [3]f32, gamma: [3]f32) ?[3]f32 {
    if (slopes.len < min_frames) return null;
    var scratch: [max_frames]f32 = undefined;
    const medians = stats.channelMedian(slopes, &scratch).?;
    var result: [3]f32 = undefined;
    for (&result, medians, datasheetSlopes(gamma)) |*r, m, d| r.* = m / d;
    return result;
}

/// Returns a stock's layer slopes, relative to green, on a scanner with `scanner_factors`: what its
/// datasheet gammas say, times the scanner's factors.
pub fn stockSlopes(scanner_factors: [3]f32, gamma: [3]f32) [3]f32 {
    var result: [3]f32 = undefined;
    for (&result, scanner_factors, datasheetSlopes(gamma)) |*r, f, d| r.* = f * d;
    return result;
}

/// The slopes that bring each layer to green's contrast, going by the datasheet: green's gamma
/// over the layer's.
fn datasheetSlopes(gamma: [3]f32) [3]f32 {
    return .{ gamma[1] / gamma[0], 1, gamma[1] / gamma[2] };
}

/// More frames than any roll has, and more rolls than anyone calibrates from.
const max_frames = 512;
const max_rolls = 256;
const max_bytes = 1 << 20;

test "one roll calibrates the scanner, and the factors carry to another stock" {
    // Superia X-TRA 400's gammas, and slopes like the ones our V200 gets from it.
    const superia = [3]f32{ 0.610, 0.665, 0.696 };
    const slopes = [_][3]f32{
        .{ 1.12, 1, 0.79 }, .{ 1.30, 1, 0.90 }, .{ 1.47, 1, 0.88 },
        .{ 1.29, 1, 0.99 }, .{ 1.34, 1, 0.89 }, .{ 1.40, 1, 0.86 },
    };
    const f = measure(&slopes, superia).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), f[1], 1e-6);
    // The roll's own stock gets the roll's median slopes back.
    const back = stockSlopes(f, superia);
    try std.testing.expectApproxEqAbs(@as(f32, 1.32), back[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.885), back[2], 1e-3);
    // Another stock gets its own datasheet ratios, scaled the same way.
    const portra = [3]f32{ 0.547, 0.549, 0.635 };
    const other = stockSlopes(f, portra);
    try std.testing.expectApproxEqAbs(back[0] * (0.549 / 0.547) / (0.665 / 0.610), other[0], 1e-4);
    try std.testing.expectEqual(@as(?[3]f32, null), measure(slopes[0..3], superia));
}

test "calibrations keep one measurement per roll, and the median over rolls" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);

    var calibrations: Calibrations = try .load(gpa, io, library);
    try std.testing.expectEqual(@as(?[3]f32, null), calibrations.factors("Epson Perfection V200"));
    try calibrations.add(io, "Epson Perfection V200", .{ .roll = "Roll 002", .stock = "Fujifilm Superia X-TRA 400", .frames = 6, .factors = .{ 1.2, 1, 0.9 } });
    try calibrations.add(io, "Epson Perfection V200", .{ .roll = "Roll 003", .stock = "Kodak Portra 400", .frames = 36, .factors = .{ 1.4, 1, 0.8 } });
    try calibrations.add(io, "Epson Perfection V200", .{ .roll = "Roll 002", .stock = "Fujifilm Superia X-TRA 400", .frames = 6, .factors = .{ 1.3, 1, 1.0 } });
    try calibrations.add(io, "Epson Perfection V750", .{ .roll = "School 1", .stock = "Kodak Gold 200", .frames = 24, .factors = .{ 1.1, 1, 0.95 } });
    calibrations.deinit();

    var again: Calibrations = try .load(gpa, io, library);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 2), again.rolls("Epson Perfection V200").len);
    const v200 = again.factors("Epson Perfection V200").?;
    try std.testing.expectApproxEqAbs(@as(f32, 1.35), v200[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.9), v200[2], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1.1), again.factors("Epson Perfection V750").?[0], 1e-6);
}

test "an unreadable calibration.json is moved aside, not written over" {
    // The warning about the file is expected.
    std.testing.log_level = .err;
    defer std.testing.log_level = .warn;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "{ not json" });
    var calibrations: Calibrations = try .load(gpa, io, library);
    defer calibrations.deinit();
    try calibrations.add(io, "EPSON Perfection V200", .{ .roll = "Roll 1", .stock = "Kodak Gold 200", .frames = 36, .factors = .{ 1.4, 1, 0.9 } });
    const kept = try tmp.dir.readFileAlloc(io, file_name ++ unreadable_suffix, gpa, .limited(max_bytes));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("{ not json", kept);
}
