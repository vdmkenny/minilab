//! A small JSON file of settings, read and written whole: a library's calibration.json and
//! scanners.json, and the account's preferences.json.
//!
//! A file that can't be read is moved aside rather than written over by the next change, so
//! nothing in it is lost. Writes go to a file next to it first, synced to disk, and then replace
//! it, so a crash or a power cut mid-write never leaves half a file. They keep the keys a newer
//! minilab added, so going back a version doesn't lose its settings.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

/// Added to the name of a file that can't be read, when it's moved aside.
pub const unreadable_suffix = ".bad";
/// Added to the name of the file being written, until it replaces the old one.
pub const partial_suffix = ".partial";
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

/// Reads `path` as a `T`, ignoring fields it doesn't know (`write` keeps them in the file).
/// Strings and lists live in `arena`.
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

/// Writes `value` to `path` as indented JSON, making its folder if it isn't there yet. Keys in
/// the old file that `value`'s type doesn't know are kept (`keepUnknown`), so settings a newer
/// minilab saved survive this one changing something. The new file is synced to disk before it
/// replaces the old one, so a power cut leaves the old file or the new one, never an empty one.
pub fn write(gpa: std.mem.Allocator, io: Io, path: []const u8, value: anytype) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    // Through std.json.Value, so the old file's keys can go in. Numbers stay as they're written.
    const number_text: std.json.ParseOptions = .{ .parse_numbers = false };
    var merged = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.json.Stringify.valueAlloc(a, value, .{}), number_text);
    if (old(a, io, path, number_text)) |was| try keepUnknown(@TypeOf(value), a, &merged, was);
    const bytes = try std.json.Stringify.valueAlloc(a, merged, .{ .whitespace = .indent_2 });

    try replace(a, io, path, bytes);
}

/// Puts `bytes` at `path`, making its folder if it isn't there yet. They go to a file next to it
/// first, synced to disk, which then takes its place. So a full disk, a crash or a power cut
/// leaves the old file or the new one, never half of one. `arena` holds the other file's name.
pub fn replace(arena: std.mem.Allocator, io: Io, path: []const u8, bytes: []const u8) !void {
    const partial = try std.fmt.allocPrint(arena, "{s}{s}", .{ path, partial_suffix });
    const cwd = Io.Dir.cwd();
    const folder = std.fs.path.dirname(path) orelse ".";
    try cwd.createDirPath(io, folder);
    errdefer cwd.deleteFile(io, partial) catch {};
    {
        const file = try cwd.createFile(io, partial, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, bytes);
        try file.sync(io);
    }
    try cwd.rename(partial, cwd, path, io);
    // The rename is only safe on disk once the folder is too. If that fails the file is still
    // written, so it's only worth a warning.
    syncFolder(io, folder) catch |err| std.log.warn("can't sync {s} after writing {s}: {t}", .{ folder, path, err });
}

/// The file at `path` as JSON, or null if there's none or it isn't JSON.
fn old(arena: std.mem.Allocator, io: Io, path: []const u8, options: std.json.ParseOptions) ?std.json.Value {
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_bytes)) catch return null;
    return std.json.parseFromSliceLeaky(std.json.Value, arena, bytes, options) catch null;
}

/// Syncs `folder`, so a file renamed into it stays renamed after a power cut. Windows can't
/// open a folder to sync it, and NTFS journals renames anyway.
fn syncFolder(io: Io, folder: []const u8) !void {
    if (builtin.os.tag == .windows) return;
    // Linux opens a folder that won't be listed with O_PATH, which can't be synced, so ask for
    // one that can be listed.
    const dir = try Io.Dir.cwd().openDir(io, folder, .{ .iterate = true });
    defer dir.close(io);
    const as_file: Io.File = .{ .handle = dir.handle, .flags = .{ .nonblocking = false } };
    try as_file.sync(io);
}

/// Copies into `new` the keys of `was` that `T` has no field for. Fields that are structs are
/// merged the same way. So are the entries of a list, when its entry type names the fields that
/// tell entries apart in `json_identity` (like `.{"name"}`): an entry keeps the unknown keys of
/// the old entry with the same identity. A list entry that's gone stays gone.
fn keepUnknown(comptime T: type, arena: std.mem.Allocator, new: *std.json.Value, was: std.json.Value) !void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (new.* != .object or was != .object) return;
            var keys = was.object.iterator();
            while (keys.next()) |entry| {
                if (isField(s.field_names, entry.key_ptr.*)) continue;
                if (!new.object.contains(entry.key_ptr.*)) try new.object.put(arena, entry.key_ptr.*, entry.value_ptr.*);
            }
            inline for (s.field_names, s.field_types) |name, Field| {
                if (new.object.getPtr(name)) |inner| {
                    if (was.object.get(name)) |inner_was| try keepUnknown(Field, arena, inner, inner_was);
                }
            }
        },
        .optional => |o| try keepUnknown(o.child, arena, new, was),
        .pointer => |p| if (p.size == .slice and @typeInfo(p.child) == .@"struct" and @hasDecl(p.child, "json_identity")) {
            if (new.* != .array or was != .array) return;
            for (new.array.items) |*entry| {
                for (was.array.items) |entry_was| {
                    if (!sameEntry(p.child, entry.*, entry_was)) continue;
                    try keepUnknown(p.child, arena, entry, entry_was);
                    break;
                }
            }
        },
        else => {},
    }
}

fn isField(comptime names: []const []const u8, key: []const u8) bool {
    inline for (names) |name| if (std.mem.eql(u8, name, key)) return true;
    return false;
}

/// Whether two list entries have the same identity: the same values in `Entry.json_identity`.
fn sameEntry(comptime Entry: type, a: std.json.Value, b: std.json.Value) bool {
    if (a != .object or b != .object) return false;
    inline for (Entry.json_identity) |name| {
        comptime std.debug.assert(@hasField(Entry, name));
        const x = a.object.get(name) orelse return false;
        const y = b.object.get(name) orelse return false;
        if (!sameScalar(x, y)) return false;
    }
    return true;
}

fn sameScalar(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array, .object => false,
    };
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

const Listed = struct {
    pub const json_identity = .{"name"};
    name: []const u8,
    size: u32 = 0,
};
const WithList = struct { entries: []const Listed = &.{} };

test "writing keeps the keys a newer version added" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const newer =
        \\{ "entries": [
        \\    { "name": "kept", "size": 1, "colour": "red" },
        \\    { "name": "gone", "size": 2, "colour": "blue" } ],
        \\  "newer": { "deep": [1, 2.50] } }
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "settings.json", .data = newer });
    const path = try tmp.dir.realPathFileAlloc(io, "settings.json", a);
    try write(gpa, io, path, WithList{ .entries = &.{ .{ .name = "kept", .size = 3 }, .{ .name = "added" } } });

    const back = try std.json.parseFromSliceLeaky(std.json.Value, a, try tmp.dir.readFileAlloc(io, "settings.json", a, .limited(max_bytes)), .{ .parse_numbers = false });
    // The newer version's own key, as it was.
    try std.testing.expectEqualStrings("2.50", back.object.get("newer").?.object.get("deep").?.array.items[1].number_string);
    const entries = back.object.get("entries").?.array.items;
    try std.testing.expectEqual(2, entries.len);
    // The entry that's still there keeps its unknown key, with our new size.
    try std.testing.expectEqualStrings("3", entries[0].object.get("size").?.number_string);
    try std.testing.expectEqualStrings("red", entries[0].object.get("colour").?.string);
    // A new entry gets nothing from the removed one.
    try std.testing.expectEqualStrings("added", entries[1].object.get("name").?.string);
    try std.testing.expect(!entries[1].object.contains("colour"));
    // No partial file is left behind.
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "settings.json" ++ partial_suffix, .{}));
}
