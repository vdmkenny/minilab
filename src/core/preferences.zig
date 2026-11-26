//! The app's preferences: how it looks and which language it speaks. Unlike a library's
//! settings, they belong to the user's account and hold for every library, so they're kept in
//! preferences.json in the account's configuration folder.

const std = @import("std");
const Io = std.Io;
const json_file = @import("json_file.zig");

pub const file_name = "preferences.json";
/// The app's folder inside the account's configuration folder.
const folder_name = "minilab";

/// Light or dark interface, or whichever the system uses.
pub const Appearance = enum {
    system,
    dark,
    light,

    pub fn label(appearance: Appearance) [:0]const u8 {
        return switch (appearance) {
            .system => "System",
            .dark => "Dark",
            .light => "Light",
        };
    }
};

/// The languages the interface comes in. English is the one the others fall back to, for any
/// message they don't have.
pub const Language = enum {
    en,
    nl,
    fr,
    de,
    it,
    es,
    ja,

    /// The language's name in itself, as a list of languages shows it.
    pub fn autonym(language: Language) [:0]const u8 {
        return switch (language) {
            .en => "English",
            .nl => "Nederlands",
            .fr => "Français",
            .de => "Deutsch",
            .it => "Italiano",
            .es => "Español",
            .ja => "日本語",
        };
    }

    /// The language with ISO 639-1 code `code`, like "nl" in the locale nl_BE, if there's one.
    pub fn ofCode(code: []const u8) ?Language {
        inline for (comptime std.enums.values(Language)) |language| {
            if (std.ascii.eqlIgnoreCase(code, @tagName(language))) return language;
        }
        return null;
    }

    /// Whether its script needs a font beyond the interface's own, which covers Latin.
    pub fn needsCjkFont(language: Language) bool {
        return language == .ja;
    }
};

/// The preferences, as preferences.json keeps them. The defaults are for a first start.
pub const Preferences = struct {
    /// Dark by default: a light interface around a photo makes it look darker and flatter than
    /// it is (see docs/settings.md).
    appearance: Appearance = .dark,
    /// Keep the viewer's background dark even when the interface is light.
    always_dark_viewer: bool = true,
    /// The interface's language, or null for the system's.
    language: ?Language = null,
    /// The scanner picked last, to open again when several are connected.
    scanner: ?Scanner = null,
    /// The resolution previews are scanned at, or the scanner's next one up. Enough to find the
    /// frames, and quick.
    preview_dpi: u32 = 300,
    /// The resolution scans start at, or the scanner's closest one. Enough for a 35mm frame to
    /// print at about 30 by 20 cm.
    scan_dpi: u32 = 2400,

    /// A scanner, by its maker and model and its driver. Not by its device name, which can change
    /// when it's plugged into another port.
    pub const Scanner = struct {
        /// The vendor and model, such as "Epson Perfection V600".
        name: []const u8,
        /// The driver: a SANE backend such as "epkowa", or "TWAIN".
        driver: []const u8,

        pub fn eql(a: Scanner, b: Scanner) bool {
            return std.mem.eql(u8, a.name, b.name) and std.mem.eql(u8, a.driver, b.driver);
        }

        fn clone(scanner: Scanner, gpa: std.mem.Allocator) !Scanner {
            const name = try gpa.dupe(u8, scanner.name);
            errdefer gpa.free(name);
            return .{ .name = name, .driver = try gpa.dupe(u8, scanner.driver) };
        }

        fn free(scanner: Scanner, gpa: std.mem.Allocator) void {
            gpa.free(scanner.name);
            gpa.free(scanner.driver);
        }
    };

    /// Whether `a` and `b` are the same preferences, comparing the scanner's text.
    pub fn eql(a: Preferences, b: Preferences) bool {
        var plain_a = a;
        var plain_b = b;
        plain_a.scanner = null;
        plain_b.scanner = null;
        if (!std.meta.eql(plain_a, plain_b)) return false;
        const sa = a.scanner orelse return b.scanner == null;
        const sb = b.scanner orelse return false;
        return sa.eql(sb);
    }
};

/// What the configuration folder depends on, from the environment.
pub const Environment = struct {
    home: ?[]const u8 = null,
    /// XDG_CONFIG_HOME, on Linux and the BSDs.
    config_home: ?[]const u8 = null,
    /// APPDATA, on Windows.
    app_data: ?[]const u8 = null,
};

/// Where preferences.json goes on `os`: the folder the system keeps apps' settings in, or null
/// when the environment doesn't say where that is.
pub fn path(gpa: std.mem.Allocator, os: std.Target.Os.Tag, environment: Environment) !?[]u8 {
    var parts: [5][]const u8 = undefined;
    const base: usize = switch (os) {
        .windows => base: {
            parts[0] = environment.app_data orelse return null;
            break :base 1;
        },
        .macos => base: {
            parts[0..3].* = .{ environment.home orelse return null, "Library", "Application Support" };
            break :base 3;
        },
        else => if (xdgConfigHome(environment)) |config| base: {
            parts[0] = config;
            break :base 1;
        } else base: {
            parts[0..2].* = .{ environment.home orelse return null, ".config" };
            break :base 2;
        },
    };
    parts[base..][0..2].* = .{ folder_name, file_name };
    return try std.fs.path.join(gpa, parts[0 .. base + 2]);
}

/// XDG_CONFIG_HOME, unless it's relative: XDG says to ignore it then.
fn xdgConfigHome(environment: Environment) ?[]const u8 {
    const config = environment.config_home orelse return null;
    return if (std.fs.path.isAbsolute(config)) config else null;
}

/// The preferences and the file they're kept in. The scanner's text belongs to it: call `deinit`.
pub const Saved = struct {
    values: Preferences = .{},
    /// Where preferences.json is, or null when they aren't kept (as in screenshots and tests).
    path: ?[]const u8 = null,

    /// Reads the preferences at `file`. Without a file, or with one that can't be read, they're the
    /// defaults. `file` has to outlive the result.
    pub fn load(gpa: std.mem.Allocator, io: Io, file: ?[]const u8) !Saved {
        var saved: Saved = .{ .path = file };
        const at = file orelse return saved;
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        switch (try json_file.read(Preferences, arena.allocator(), io, at)) {
            .read => |values| {
                saved.values = values;
                // The arena goes, so the scanner's text is copied out of it.
                saved.values.scanner = if (values.scanner) |s| try s.clone(gpa) else null;
            },
            .missing, .moved_aside => {},
            .stuck => saved.path = null,
        }
        return saved;
    }

    /// Changes the preferences to `values` and writes them. They hold for this session even if
    /// writing fails.
    pub fn set(saved: *Saved, gpa: std.mem.Allocator, io: Io, values: Preferences) !void {
        if (saved.values.eql(values)) return;
        // Copied before the old one goes, since `values` may share it.
        const scanner = if (values.scanner) |s| try s.clone(gpa) else null;
        if (saved.values.scanner) |old| old.free(gpa);
        saved.values = values;
        saved.values.scanner = scanner;
        const at = saved.path orelse return;
        try json_file.write(gpa, io, at, saved.values);
    }

    pub fn deinit(saved: *Saved, gpa: std.mem.Allocator) void {
        if (saved.values.scanner) |s| s.free(gpa);
        saved.* = undefined;
    }
};

test "preferences survive a restart" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);
    const at = try std.fs.path.join(gpa, &.{ folder, folder_name, file_name });
    defer gpa.free(at);

    var first: Saved = try .load(gpa, io, at);
    defer first.deinit(gpa);
    try std.testing.expect(first.values.eql(.{}));
    const v600: Preferences.Scanner = .{ .name = "Epson Perfection V600", .driver = "epkowa" };
    try first.set(gpa, io, .{ .appearance = .light, .always_dark_viewer = false, .scanner = v600 });
    var second: Saved = try .load(gpa, io, at);
    defer second.deinit(gpa);
    try std.testing.expect(second.values.eql(.{ .appearance = .light, .always_dark_viewer = false, .scanner = v600 }));
}

test "picking another scanner keeps its own copy of the name" {
    const gpa = std.testing.allocator;
    var saved: Saved = try .load(gpa, std.testing.io, null);
    defer saved.deinit(gpa);
    var name = "Epson Perfection V600".*;
    try saved.set(gpa, std.testing.io, .{ .scanner = .{ .name = &name, .driver = "epkowa" } });
    // The device list the name came from goes away.
    @memset(&name, 0);
    try std.testing.expectEqualStrings("Epson Perfection V600", saved.values.scanner.?.name);
    // Setting the same values again, sharing the saved text, keeps it.
    try saved.set(gpa, std.testing.io, saved.values);
    try saved.set(gpa, std.testing.io, .{ .appearance = .light, .scanner = saved.values.scanner });
    try std.testing.expectEqualStrings("epkowa", saved.values.scanner.?.driver);
}

test "without a file to keep them in, preferences still change for the session" {
    var saved: Saved = try .load(std.testing.allocator, std.testing.io, null);
    defer saved.deinit(std.testing.allocator);
    try saved.set(std.testing.allocator, std.testing.io, .{ .appearance = .system });
    try std.testing.expectEqual(Appearance.system, saved.values.appearance);
}

test "a locale's language code picks the language" {
    try std.testing.expectEqual(Language.nl, Language.ofCode("nl").?);
    try std.testing.expectEqual(Language.ja, Language.ofCode("JA").?);
    try std.testing.expectEqual(@as(?Language, null), Language.ofCode("pt"));
}

test "the configuration folder follows the system" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { std.Target.Os.Tag, Environment, ?[]const []const u8 }{
        .{ .linux, .{ .home = "/home/ada" }, &.{ "/home/ada", ".config" } },
        .{ .linux, .{ .home = "/home/ada", .config_home = "/xdg" }, &.{"/xdg"} },
        .{ .linux, .{ .home = "/home/ada", .config_home = "relative" }, &.{ "/home/ada", ".config" } },
        .{ .macos, .{ .home = "/Users/ada" }, &.{ "/Users/ada", "Library", "Application Support" } },
        .{ .windows, .{ .app_data = "C:\\Users\\ada\\AppData\\Roaming" }, &.{"C:\\Users\\ada\\AppData\\Roaming"} },
        .{ .windows, .{ .home = "C:\\Users\\ada" }, null },
        .{ .linux, .{}, null },
    };
    for (cases) |case| {
        const found = try path(gpa, case[0], case[1]);
        defer if (found) |f| gpa.free(f);
        const base = case[2] orelse {
            try std.testing.expectEqual(@as(?[]u8, null), found);
            continue;
        };
        var parts: std.ArrayList([]const u8) = .empty;
        defer parts.deinit(gpa);
        try parts.appendSlice(gpa, base);
        try parts.appendSlice(gpa, &.{ folder_name, file_name });
        const expected = try std.fs.path.join(gpa, parts.items);
        defer gpa.free(expected);
        try std.testing.expectEqualStrings(expected, found.?);
    }
}
