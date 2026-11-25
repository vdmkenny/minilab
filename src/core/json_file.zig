//! A small JSON file of settings, read and written whole: a library's calibration.json and
//! scanners.json, and the account's preferences.json.
//!
//! A file that can't be read is moved aside rather than written over by the next change, so
//! nothing in it is lost. Writes go to a file next to it first and then replace it, so a crash
//! mid-write never leaves half a file.

const std = @import("std");
const Io = std.Io;

/// Added to the name of a file that can't be read, when it's moved aside.
pub const unreadable_suffix = ".bad";
/// Added to the name of the file being written, until it replaces the old one.
const partial_suffix = ".partial";
/// The largest file we read. Settings files are a few kilobytes.
pub const max_bytes = 1 << 20;

/// What `read` found.
pub fn Read(comptime T: type) type {
    return union(enum) {
        /// The file's contents.
        read: T,
        /// There's no file yet.
        missing,
        /// The file couldn't be parsed and is now at `path` ++ `unreadable_suffix`.
        moved_aside,
        /// The file couldn't be parsed or moved aside. Don't write over it.
        stuck,
    };
}

/// Reads `path` as a `T`, ignoring fields it doesn't know. `write` drops those fields again
/// (https://github.com/vdmkenny/minilab/issues/77). Strings and lists live in `arena`.
/// Errors reading the file (other than its not being there) are returned.
pub fn read(comptime T: type, arena: std.mem.Allocator, io: Io, path: []const u8) !Read(T) {
    const cwd = Io.Dir.cwd();
    const bytes = cwd.readFileAlloc(io, path, arena, .limited(max_bytes)) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    const value = std.json.parseFromSliceLeaky(T, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch |err| {
        const aside = try std.fmt.allocPrint(arena, "{s}{s}", .{ path, unreadable_suffix });
        cwd.rename(path, cwd, aside, io) catch |rename_err| {
            std.log.warn("{s} can't be read ({t}) or moved aside ({t}), so it won't be written over", .{ path, err, rename_err });
            return .stuck;
        };
        std.log.warn("{s} can't be read ({t}); moved it to {s}", .{ path, err, aside });
        return .moved_aside;
    };
    return .{ .read = value };
}

/// Writes `value` to `path` as indented JSON, making its folder if it isn't there yet. The new
/// file isn't synced to disk before it replaces the old one
/// (https://github.com/vdmkenny/minilab/issues/78).
pub fn write(gpa: std.mem.Allocator, io: Io, path: []const u8, value: anytype) !void {
    const bytes = try std.json.Stringify.valueAlloc(gpa, value, .{ .whitespace = .indent_2 });
    defer gpa.free(bytes);
    const partial = try std.fmt.allocPrint(gpa, "{s}{s}", .{ path, partial_suffix });
    defer gpa.free(partial);
    const cwd = Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |folder| try cwd.createDirPath(io, folder);
    errdefer cwd.deleteFile(io, partial) catch {};
    try cwd.writeFile(io, .{ .sub_path = partial, .data = bytes });
    try cwd.rename(partial, cwd, path, io);
}

const Example = struct { count: u32 = 0, name: []const u8 = "" };

test "a file written is read back, and a missing one is just missing" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", a);
    // The folder it goes in is made too.
    const path = try std.fs.path.join(a, &.{ folder, "new", "settings.json" });
    try std.testing.expectEqual(Read(Example).missing, try read(Example, a, io, path));
    try write(gpa, io, path, Example{ .count = 3, .name = "three" });
    const back = (try read(Example, a, io, path)).read;
    try std.testing.expectEqual(@as(u32, 3), back.count);
    try std.testing.expectEqualStrings("three", back.name);
}

test "a file that can't be read is moved aside, not lost" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = "{broken" });
    const path = try tmp.dir.realPathFileAlloc(io, "settings.json", a);
    try std.testing.expectEqual(Read(Example).moved_aside, try read(Example, a, io, path));
    try std.testing.expectEqualStrings("{broken", try tmp.dir.readFileAlloc(io, "settings.json" ++ unreadable_suffix, a, .limited(max_bytes)));
    try std.testing.expectEqual(Read(Example).missing, try read(Example, a, io, path));
}
