//! Calibrating a scanner, or a camera, against the film makers' datasheets, so that a stock's
//! published contrasts can set the balance of its layers.
//!
//! A datasheet gives each layer's contrast (gamma) in Status M density, the filters labs read film
//! through. A scanner's channels see the dyes through other filters, so its densities differ: on our
//! V200 a colour negative's red needs 1.3 to 1.7 times blue's slope where Status M says 1.14. The
//! difference belongs to the scanner, not the film, as long as each channel reads mainly one dye.
//! So it is measured once per scanner and holds for every stock:
//!
//! 1. On a roll of a stock with a preset, each frame's automatic balance gives the slopes that
//!    make that frame's neutrals neutral, relative to green.
//! 2. Their median over the roll leaves out what the scenes' own colours put in.
//! 3. Divided by what the datasheet says those slopes are, it gives the scanner's factors.
//!
//! A stock's balance on that scanner is then its datasheet slopes times the factors. More rolls,
//! of any stocks, refine the factors: the calibration is the median over them. They are kept per
//! scanner, by the name the roll records, in the library's calibration.json.

const std = @import("std");
const Io = std.Io;

pub const file_name = "calibration.json";
/// The fewest frames a roll needs to calibrate from: the median of fewer still follows the scenes.
pub const min_frames = 4;

/// What one roll gave.
pub const Measurement = struct {
    roll: []const u8,
    stock: []const u8,
    frames: u32,
    /// The scanner's slope against the datasheet's, per layer, green 1.
    factors: [3]f32,
};

pub const Scanner = struct {
    name: []const u8,
    rolls: []const Measurement,
};

/// calibration.json as it is written.
const File = struct {
    scanners: []const Scanner = &.{},
};

/// The library's calibrations. Its strings and lists live in its arena, and are copied on change.
pub const Calibrations = struct {
    arena: std.heap.ArenaAllocator,
    scanners: []const Scanner = &.{},
    /// Where calibration.json is; null for none, as in the tests.
    path: ?[]const u8 = null,

    /// Reads the calibrations in `library`; a library without any has none.
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
            std.log.warn("{s} can't be read ({t}); starting without calibrations", .{ calibrations.path.?, err });
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

    /// The rolls `scanner` is calibrated from.
    pub fn rolls(calibrations: *const Calibrations, scanner: []const u8) []const Measurement {
        const s = calibrations.find(scanner) orelse return &.{};
        return s.rolls;
    }

    /// `scanner`'s factors: the median over its rolls, per layer. Null before any roll.
    pub fn factors(calibrations: *const Calibrations, scanner: []const u8) ?[3]f32 {
        const measured = calibrations.rolls(scanner);
        if (measured.len == 0) return null;
        var values: [3][max_rolls]f32 = undefined;
        const count = @min(measured.len, max_rolls);
        for (measured[0..count], 0..) |m, i| {
            for (&values, m.factors) |*channel, f| channel[i] = f;
        }
        var result: [3]f32 = undefined;
        for (&result, &values) |*r, *channel| r.* = median(channel[0..count]);
        return result;
    }

    /// Records `measurement` for `scanner`, in place of an earlier one from the same roll, and
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

/// A scanner's factors from one roll of a stock with datasheet gammas `gamma`, R, G, B: `slopes`
/// are its frames' neutral slopes, relative to green. Null with fewer than `min_frames`.
pub fn measure(slopes: []const [3]f32, gamma: [3]f32) ?[3]f32 {
    if (slopes.len < min_frames) return null;
    var values: [3][max_frames]f32 = undefined;
    const count = @min(slopes.len, max_frames);
    for (slopes[0..count], 0..) |s, i| {
        for (&values, s) |*channel, v| channel[i] = v;
    }
    const sheet = datasheetSlopes(gamma);
    var result: [3]f32 = undefined;
    for (&result, &values, sheet) |*r, *channel, d| r.* = median(channel[0..count]) / d;
    return result;
}

/// A stock's layer slopes on a scanner with `scanner_factors`, relative to green: what its
/// datasheet gammas say, times the scanner's factors.
pub fn stockSlopes(scanner_factors: [3]f32, gamma: [3]f32) [3]f32 {
    var result: [3]f32 = undefined;
    for (&result, scanner_factors, datasheetSlopes(gamma)) |*r, f, d| r.* = f * d;
    return result;
}

/// The slopes that bring each layer to green's contrast, by the datasheet: green's gamma over the
/// layer's.
fn datasheetSlopes(gamma: [3]f32) [3]f32 {
    return .{ gamma[1] / gamma[0], 1, gamma[1] / gamma[2] };
}

fn median(values: []f32) f32 {
    std.mem.sort(f32, values, {}, std.sort.asc(f32));
    const n = values.len;
    return if (n % 2 == 1) values[n / 2] else (values[n / 2 - 1] + values[n / 2]) / 2;
}

/// More frames than a roll has, and more rolls than anyone calibrates from.
const max_frames = 512;
const max_rolls = 256;
const max_bytes = 1 << 20;

test "one roll calibrates the scanner, and the factors carry to another stock" {
    // Superia X-TRA 400's gammas, and slopes like our V200's frames of it.
    const superia = [3]f32{ 0.610, 0.665, 0.696 };
    const slopes = [_][3]f32{
        .{ 1.12, 1, 0.79 }, .{ 1.30, 1, 0.90 }, .{ 1.47, 1, 0.88 },
        .{ 1.29, 1, 0.99 }, .{ 1.34, 1, 0.89 }, .{ 1.40, 1, 0.86 },
    };
    const f = measure(&slopes, superia).?;
    try std.testing.expectApproxEqAbs(@as(f32, 1), f[1], 1e-6);
    // The roll's own stock gets back the roll's median slopes.
    const back = stockSlopes(f, superia);
    try std.testing.expectApproxEqAbs(@as(f32, 1.32), back[0], 1e-3);
    try std.testing.expectApproxEqAbs(@as(f32, 0.885), back[2], 1e-3);
    // Another stock: its own datasheet ratios, scaled the same way.
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
