//! Application appearance, shared by all libraries on this user account.
const std = @import("std");

pub const Theme = enum {
    dark,
    light,

    pub fn label(theme: Theme) []const u8 {
        return switch (theme) {
            .dark => "Dark",
            .light => "Light",
        };
    }
};

pub const file_name = "preferences.json";
const max_bytes = 64 * 1024;
const File = struct { theme: Theme = .dark };

/// Resolves the account's configuration folder, independently of the library.
/// Callers supply environment hints so tests never touch the user's settings.
pub fn pathFor(gpa: std.mem.Allocator, os: std.Target.Os.Tag, home: ?[]const u8, config_home: ?[]const u8, app_data: ?[]const u8) !?[]u8 {
    if (os == .windows) {
        const base = app_data orelse return null;
        return try std.fs.path.join(gpa, &.{ base, "minilab", file_name });
    }
    if (os == .macos) {
        const base = home orelse return null;
        return try std.fs.path.join(gpa, &.{ base, "Library", "Application Support", "minilab", file_name });
    }
    if (config_home) |base| if (std.fs.path.isAbsolute(base)) return try std.fs.path.join(gpa, &.{ base, "minilab", file_name });
    const base = home orelse return null;
    return try std.fs.path.join(gpa, &.{ base, ".config", "minilab", file_name });
}

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    path: ?[]const u8 = null,
    theme: Theme = .dark,
    readable: bool = true,

    pub fn load(gpa: std.mem.Allocator, io: std.Io, path: ?[]const u8) !Settings {
        var settings: Settings = .{ .arena = .init(gpa) };
        errdefer settings.deinit();
        const name = path orelse return settings;
        settings.path = try settings.arena.allocator().dupe(u8, name);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, name, gpa, .limited(max_bytes)) catch |err| switch (err) {
            error.FileNotFound => return settings,
            else => {
                settings.readable = false;
                return settings;
            },
        };
        defer gpa.free(bytes);
        const file = std.json.parseFromSliceLeaky(File, settings.arena.allocator(), bytes, .{ .ignore_unknown_fields = true }) catch {
            settings.readable = false;
            return settings;
        };
        settings.theme = file.theme;
        return settings;
    }

    pub fn deinit(settings: *Settings) void {
        settings.arena.deinit();
        settings.* = undefined;
    }

    /// Apply for this session even if the preference cannot be written. The UI
    /// reports that failure, while an unreadable file remains untouched.
    pub fn setTheme(settings: *Settings, io: std.Io, theme: Theme) !void {
        settings.theme = theme;
        if (!settings.readable) return error.PreferencesUnreadable;
        const path = settings.path orelse return;
        const gpa = settings.arena.child_allocator;
        const bytes = try std.json.Stringify.valueAlloc(gpa, File{ .theme = theme }, .{ .whitespace = .indent_2 });
        defer gpa.free(bytes);
        const temporary = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
        defer gpa.free(temporary);
        const cwd = std.Io.Dir.cwd();
        if (std.fs.path.dirname(path)) |folder| try cwd.createDirPath(io, folder);
        errdefer cwd.deleteFile(io, temporary) catch {};
        try cwd.writeFile(io, .{ .sub_path = temporary, .data = bytes });
        try cwd.rename(temporary, cwd, path, io);
    }
};

test "appearance survives restart and can be switched back" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);
    const path = try std.fs.path.join(gpa, &.{ folder, "config", file_name });
    defer gpa.free(path);
    {
        var settings = try Settings.load(gpa, io, path);
        defer settings.deinit();
        try std.testing.expectEqual(Theme.dark, settings.theme);
        try settings.setTheme(io, .light);
    }
    {
        var settings = try Settings.load(gpa, io, path);
        defer settings.deinit();
        try std.testing.expectEqual(Theme.light, settings.theme);
        try settings.setTheme(io, .dark);
    }
    var settings = try Settings.load(gpa, io, path);
    defer settings.deinit();
    try std.testing.expectEqual(Theme.dark, settings.theme);
}

test "an unreadable preference still allows a session theme without replacing the file" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "{broken" });
    const path = try tmp.dir.realPathFileAlloc(io, file_name, gpa);
    defer gpa.free(path);
    var settings = try Settings.load(gpa, io, path);
    defer settings.deinit();
    try std.testing.expectError(error.PreferencesUnreadable, settings.setTheme(io, .light));
    try std.testing.expectEqual(Theme.light, settings.theme);
    const bytes = try tmp.dir.readFileAlloc(io, file_name, gpa, .limited(max_bytes));
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("{broken", bytes);
}

test "configuration paths follow the account rather than a roll library" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const path = (try pathFor(gpa, .linux, null, base, null)).?;
    defer gpa.free(path);
    const expected = try std.fs.path.join(gpa, &.{ base, "minilab", file_name });
    defer gpa.free(expected);
    try std.testing.expectEqualStrings(expected, path);
    try std.testing.expectEqual(@as(?[]u8, null), try pathFor(gpa, .linux, null, "relative", null));
    try std.testing.expectEqual(@as(?[]u8, null), try pathFor(gpa, .windows, base, null, null));
}
