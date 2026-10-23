//! The scanner settings: changes the user made to raw setup, per scanner, kept in the library's
//! scanners.json. Raw setup works out how to get raw data from a scanner we have no profile for
//! (`scan.rawControls`). When it guesses wrong, the Scan screen's settings can set an option
//! another way, and that change is kept here. A scanner without changes just gets raw setup.
//!
//! Option names differ between drivers, even for the same scanner (epson2 and epkowa both drive
//! Epsons), so the changes are kept per scanner and driver.

const std = @import("std");
const Io = std.Io;
const scan = @import("../scan/root.zig");

pub const file_name = "scanners.json";
/// Added to the name of a scanners.json that can't be read, when it's moved aside.
pub const unreadable_suffix = ".bad";
const max_bytes = 1 << 20;

pub const Scanner = struct {
    /// The scanner's vendor and model, as rolls record it.
    name: []const u8,
    /// The driver: a SANE backend such as "epson2".
    driver: []const u8,
    /// The changes, one per option.
    raw: []const scan.RawSetting = &.{},
};

/// The layout of scanners.json.
const File = struct {
    scanners: []const Scanner = &.{},
};

/// The library's scanner settings. The strings and lists live in the arena, and get copied when
/// something changes.
pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    scanners: []const Scanner = &.{},
    /// Where scanners.json is, or null if there's no file (as in the tests).
    path: ?[]const u8 = null,

    /// Reads the settings in `library`. A library without the file just has none.
    pub fn load(gpa: std.mem.Allocator, io: Io, library: []const u8) !Settings {
        var settings: Settings = .{ .arena = .init(gpa) };
        errdefer settings.arena.deinit();
        const a = settings.arena.allocator();
        settings.path = try std.fs.path.join(a, &.{ library, file_name });
        const bytes = Io.Dir.cwd().readFileAlloc(io, settings.path.?, a, .limited(max_bytes)) catch |err| switch (err) {
            error.FileNotFound => return settings,
            else => return err,
        };
        const file = std.json.parseFromSliceLeaky(File, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
            // Move it aside rather than write over it with the next change, so nothing in it is
            // lost.
            const aside = try std.fmt.allocPrint(a, "{s}{s}", .{ settings.path.?, unreadable_suffix });
            Io.Dir.cwd().rename(settings.path.?, Io.Dir.cwd(), aside, io) catch |rename_err| {
                std.log.warn("{s} can't be read ({t}) or moved aside ({t}); scanner settings won't be saved", .{ settings.path.?, err, rename_err });
                settings.path = null;
                return settings;
            };
            std.log.warn("{s} can't be read ({t}); moved it to {s} and starting without scanner settings", .{ settings.path.?, err, aside });
            return settings;
        };
        settings.scanners = file.scanners;
        return settings;
    }

    pub fn deinit(settings: *Settings) void {
        settings.arena.deinit();
        settings.* = undefined;
    }

    /// The changes for `name` on `driver`.
    pub fn raw(settings: *const Settings, name: []const u8, driver: []const u8) []const scan.RawSetting {
        const s = settings.find(name, driver) orelse return &.{};
        return s.raw;
    }

    /// Sets `option` on `name`'s scanner to `value`, or back to raw setup's own choice when it's
    /// null, and writes the file.
    pub fn set(settings: *Settings, io: Io, name: []const u8, driver: []const u8, option: []const u8, value: ?scan.RawValue) !void {
        const a = settings.arena.allocator();
        var changes: std.ArrayList(scan.RawSetting) = .empty;
        for (settings.raw(name, driver)) |change| {
            if (!std.mem.eql(u8, change.name, option)) try changes.append(a, change);
        }
        if (value) |v| try changes.append(a, .{ .name = try a.dupe(u8, option), .value = switch (v) {
            .choose => |choice| .{ .choose = try a.dupe(u8, choice) },
            else => v,
        } });
        try settings.replace(io, name, driver, changes.items);
    }

    /// Puts `name`'s scanner back to raw setup's own choices, and writes the file.
    pub fn reset(settings: *Settings, io: Io, name: []const u8, driver: []const u8) !void {
        try settings.replace(io, name, driver, &.{});
    }

    fn find(settings: *const Settings, name: []const u8, driver: []const u8) ?*const Scanner {
        for (settings.scanners) |*s| {
            if (std.mem.eql(u8, s.name, name) and std.mem.eql(u8, s.driver, driver)) return s;
        }
        return null;
    }

    /// Gives `name`'s scanner the changes `raw` (living in the arena), dropping it from the file
    /// when there are none, and writes the file.
    fn replace(settings: *Settings, io: Io, name: []const u8, driver: []const u8, raw_changes: []const scan.RawSetting) !void {
        const a = settings.arena.allocator();
        var scanners: std.ArrayList(Scanner) = .empty;
        for (settings.scanners) |s| {
            if (!std.mem.eql(u8, s.name, name) or !std.mem.eql(u8, s.driver, driver)) try scanners.append(a, s);
        }
        if (raw_changes.len > 0) try scanners.append(a, .{ .name = try a.dupe(u8, name), .driver = try a.dupe(u8, driver), .raw = raw_changes });
        settings.scanners = scanners.items;
        try settings.save(io);
    }

    fn save(settings: *Settings, io: Io) !void {
        const path = settings.path orelse return;
        const a = settings.arena.allocator();
        const bytes = try std.json.Stringify.valueAlloc(a, File{ .scanners = settings.scanners }, .{ .whitespace = .indent_2 });
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    }
};

test "a change replaces the one before it, and null takes it away" {
    var settings: Settings = .{ .arena = .init(std.testing.allocator) };
    defer settings.deinit();
    const io = std.testing.io;
    try settings.set(io, "EPSON V750", "epson2", "gamma-correction", .{ .choose = "Default" });
    try settings.set(io, "EPSON V750", "epson2", "gamma-correction", .{ .choose = "User defined (Gamma=1.8)" });
    try settings.set(io, "EPSON V750", "epson2", "color-correction", .leave);
    // The same scanner on another driver has its own.
    try std.testing.expectEqual(@as(usize, 0), settings.raw("EPSON V750", "epkowa").len);
    const raw = settings.raw("EPSON V750", "epson2");
    try std.testing.expectEqual(@as(usize, 2), raw.len);
    try std.testing.expectEqualStrings("User defined (Gamma=1.8)", scan.valueOf(raw, "gamma-correction").?.choose);
    try settings.set(io, "EPSON V750", "epson2", "gamma-correction", null);
    try std.testing.expectEqual(@as(?scan.RawValue, null), scan.valueOf(settings.raw("EPSON V750", "epson2"), "gamma-correction"));
    try settings.reset(io, "EPSON V750", "epson2");
    try std.testing.expectEqual(@as(usize, 0), settings.scanners.len);
}

test "an unreadable file is moved aside, not written over" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "{ not json" });
    var settings: Settings = try .load(gpa, io, library);
    defer settings.deinit();
    try settings.set(io, "EPSON V750", "epson2", "gamma-correction", .leave);
    const kept = try tmp.dir.readFileAlloc(io, file_name ++ unreadable_suffix, gpa, .limited(max_bytes));
    defer gpa.free(kept);
    try std.testing.expectEqualStrings("{ not json", kept);
}

test "scanner settings survive the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);
    {
        var settings: Settings = try .load(gpa, io, library);
        defer settings.deinit();
        try settings.set(io, "Canon CanoScan 9000F", "pixma", "custom-gamma", .{ .number = 0 });
        try settings.set(io, "Canon CanoScan 9000F", "pixma", "gamma-table", .straight);
        try settings.set(io, "Canon CanoScan 9000F", "pixma", "film-type", .leave);
        try settings.set(io, "Canon CanoScan 9000F", "pixma", "source", .{ .choose = "Transparency Unit" });
    }
    var settings: Settings = try .load(gpa, io, library);
    defer settings.deinit();
    const raw = settings.raw("Canon CanoScan 9000F", "pixma");
    try std.testing.expectEqual(@as(f64, 0), scan.valueOf(raw, "custom-gamma").?.number);
    try std.testing.expectEqual(scan.RawValue.straight, scan.valueOf(raw, "gamma-table").?);
    try std.testing.expectEqual(scan.RawValue.leave, scan.valueOf(raw, "film-type").?);
    try std.testing.expectEqualStrings("Transparency Unit", scan.valueOf(raw, "source").?.choose);
}
