//! Reusable roll metadata, kept separately from the rolls themselves. Removed
//! entries stay hidden when old rolls are read again. Explicitly using or adding
//! a value restores it. Changing these suggestions never changes a roll.
const std = @import("std");
const roll = @import("roll.zig");

pub const file_name = "roll-details.json";
pub const value_capacity = 1024;
const max_file_bytes = 4 * 1024 * 1024;
const file_version = 1;

pub const Kind = enum {
    camera,
    lens,
    copyright,

    pub fn label(kind: Kind) []const u8 {
        return switch (kind) {
            .camera => "Cameras",
            .lens => "Lenses",
            .copyright => "Copyright names",
        };
    }

    pub fn fromDetail(detail: roll.Detail) ?Kind {
        return switch (detail) {
            .camera => .camera,
            .lens => .lens,
            .copyright => .copyright,
            else => null,
        };
    }
};

pub const Entry = struct {
    kind: Kind,
    value: []const u8,
    removed: bool = false,
};

const File = struct { version: u32 = file_version, entries: []const Entry = &.{} };
const Use = enum { observed, explicit };

pub const Settings = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry = &.{},
    path: ?[]const u8 = null,
    /// An unreadable preferences file is kept intact. Roll editing still works.
    readable: bool = true,

    pub fn load(gpa: std.mem.Allocator, io: std.Io, library: []const u8) !Settings {
        var settings: Settings = .{ .arena = .init(gpa) };
        errdefer settings.deinit();
        const a = settings.arena.allocator();
        settings.path = try std.fs.path.join(a, &.{ library, file_name });
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, settings.path.?, gpa, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return settings,
            else => {
                settings.readable = false;
                return settings;
            },
        };
        defer gpa.free(bytes);
        const file = std.json.parseFromSliceLeaky(File, a, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
            settings.readable = false;
            return settings;
        };
        if (file.version != file_version) {
            settings.readable = false;
            return settings;
        }
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        for (file.entries) |entry| {
            const value = normalised(entry.value);
            if (!valid(value)) {
                settings.readable = false;
                return settings;
            }
            if (find(entries.items, entry.kind, value)) |i| {
                entries.items[i].removed = entries.items[i].removed or entry.removed;
            } else try entries.append(gpa, .{ .kind = entry.kind, .value = value, .removed = entry.removed });
        }
        sort(entries.items);
        settings.entries = try a.dupe(Entry, entries.items);
        return settings;
    }

    pub fn deinit(settings: *Settings) void {
        settings.arena.deinit();
        settings.* = undefined;
    }

    pub fn count(settings: *const Settings, kind: Kind) usize {
        var n: usize = 0;
        for (settings.entries) |entry| if (entry.kind == kind and !entry.removed) {
            n += 1;
        };
        return n;
    }

    /// Learns existing rolls without bringing deleted suggestions back.
    pub fn observe(settings: *Settings, io: std.Io, infos: []const roll.Info) !void {
        try settings.updateInfos(io, infos, .observed);
    }

    /// Remembers values the user explicitly used when making a roll.
    pub fn rememberInfo(settings: *Settings, io: std.Io, info: roll.Info) !void {
        try settings.updateInfos(io, &.{info}, .explicit);
    }

    fn updateInfos(settings: *Settings, io: std.Io, infos: []const roll.Info, use: Use) !void {
        const gpa = settings.arena.child_allocator;
        var values: std.ArrayList(Entry) = .empty;
        defer values.deinit(gpa);
        for (infos) |info| inline for (std.enums.values(Kind)) |kind| {
            if (@field(info, @tagName(kind))) |value| try values.append(gpa, .{ .kind = kind, .value = value });
        };
        try settings.update(io, values.items, use);
    }

    pub fn remember(settings: *Settings, io: std.Io, kind: Kind, value: []const u8) !void {
        try settings.update(io, &.{.{ .kind = kind, .value = value }}, .explicit);
    }

    fn update(settings: *Settings, io: std.Io, values: []const Entry, use: Use) !void {
        if (!settings.readable) return error.SavedDetailsUnreadable;
        const gpa = settings.arena.child_allocator;
        const a = settings.arena.allocator();
        var entries: std.ArrayList(Entry) = .empty;
        defer entries.deinit(gpa);
        try entries.appendSlice(gpa, settings.entries);
        var changed = false;
        for (values) |entry| {
            const value = normalised(entry.value);
            if (value.len == 0) continue;
            if (!valid(value)) {
                if (use == .observed) continue;
                return error.InvalidSavedDetail;
            }
            if (find(entries.items, entry.kind, value)) |i| {
                if (use == .observed) continue;
                const old = entries.items[i];
                if (!old.removed and std.mem.eql(u8, old.value, value)) continue;
                entries.items[i] = .{ .kind = entry.kind, .value = try a.dupe(u8, value) };
            } else try entries.append(gpa, .{ .kind = entry.kind, .value = try a.dupe(u8, value) });
            changed = true;
        }
        if (changed) try settings.commit(io, entries.items);
    }

    pub fn forget(settings: *Settings, io: std.Io, kind: Kind, value: []const u8) !void {
        if (!settings.readable) return error.SavedDetailsUnreadable;
        const i = find(settings.entries, kind, normalised(value)) orelse return;
        if (settings.entries[i].removed) return;
        const gpa = settings.arena.child_allocator;
        const entries = try gpa.dupe(Entry, settings.entries);
        defer gpa.free(entries);
        entries[i].removed = true;
        try settings.commit(io, entries);
    }

    fn commit(settings: *Settings, io: std.Io, entries: []Entry) !void {
        sort(entries);
        const owned = try settings.arena.allocator().dupe(Entry, entries);
        if (settings.path) |path| {
            const gpa = settings.arena.child_allocator;
            const bytes = try std.json.Stringify.valueAlloc(gpa, File{ .entries = owned }, .{ .whitespace = .indent_2 });
            defer gpa.free(bytes);
            if (bytes.len > max_file_bytes) return error.SavedDetailsFull;
            const temporary = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
            defer gpa.free(temporary);
            const cwd = std.Io.Dir.cwd();
            errdefer cwd.deleteFile(io, temporary) catch {};
            try cwd.writeFile(io, .{ .sub_path = temporary, .data = bytes });
            try cwd.rename(temporary, cwd, path, io);
        }
        settings.entries = owned;
    }
};

fn normalised(value: []const u8) []const u8 {
    return std.mem.trim(u8, value, " \t\r\n");
}
fn valid(value: []const u8) bool {
    return value.len > 0 and value.len <= value_capacity and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
}
fn find(entries: []const Entry, kind: Kind, value: []const u8) ?usize {
    for (entries, 0..) |entry, i| if (entry.kind == kind and std.ascii.eqlIgnoreCase(entry.value, value)) return i;
    return null;
}
fn sort(entries: []Entry) void {
    std.mem.sort(Entry, entries, {}, struct {
        fn less(_: void, left: Entry, right: Entry) bool {
            if (left.kind != right.kind) return @backingInt(left.kind) < @backingInt(right.kind);
            return std.ascii.lessThanIgnoreCase(left.value, right.value);
        }
    }.less);
}

test "roll history is trimmed, distinct by field and does not restore removed entries" {
    var settings: Settings = .{ .arena = .init(std.testing.allocator) };
    defer settings.deinit();
    const io = std.testing.io;
    const infos = [_]roll.Info{
        .{ .name = "First", .camera = " Nikon F3 ", .lens = "50 mm", .copyright = "Chrisi" },
        .{ .name = "Second", .camera = "nikon f3", .lens = "35 mm", .copyright = "  " },
    };
    try settings.observe(io, &infos);
    try std.testing.expectEqual(@as(usize, 1), settings.count(.camera));
    try std.testing.expectEqual(@as(usize, 2), settings.count(.lens));
    try settings.forget(io, .camera, "Nikon F3");
    try settings.observe(io, &infos);
    try std.testing.expectEqual(@as(usize, 0), settings.count(.camera));
    try std.testing.expectEqualStrings(" Nikon F3 ", infos[0].camera.?);
    try settings.remember(io, .camera, "Nikon F3");
    try std.testing.expectEqual(@as(usize, 1), settings.count(.camera));
    try settings.remember(io, .lens, "Nikon F3");
    try std.testing.expectEqual(@as(usize, 3), settings.count(.lens));
}

test "saved values and removals survive reopening and explicit reuse restores them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);
    {
        var settings = try Settings.load(gpa, io, folder);
        defer settings.deinit();
        try settings.rememberInfo(io, .{ .name = "Roll", .camera = "Pentax MX", .copyright = "Jörg ©" });
        try settings.forget(io, .camera, "Pentax MX");
    }
    var settings = try Settings.load(gpa, io, folder);
    defer settings.deinit();
    try std.testing.expectEqual(@as(usize, 0), settings.count(.camera));
    try std.testing.expectEqual(@as(usize, 1), settings.count(.copyright));
    try settings.observe(io, &.{.{ .name = "Old roll", .camera = "Pentax MX" }});
    try std.testing.expectEqual(@as(usize, 0), settings.count(.camera));
    try settings.rememberInfo(io, .{ .name = "New roll", .camera = "Pentax MX" });
    try std.testing.expectEqual(@as(usize, 1), settings.count(.camera));
}

test "an unreadable file and a failed save leave the file and current choices intact" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "{broken" });
    var settings = try Settings.load(gpa, io, folder);
    defer settings.deinit();
    try std.testing.expect(!settings.readable);
    try std.testing.expectError(error.SavedDetailsUnreadable, settings.remember(io, .camera, "Camera"));
    const bytes = try tmp.dir.readFileAlloc(io, file_name, gpa, .limited(max_file_bytes));
    defer gpa.free(bytes);
    try std.testing.expectEqualStrings("{broken", bytes);
    var memory: Settings = .{ .arena = .init(gpa) };
    defer memory.deinit();
    try memory.remember(io, .lens, "50 mm");
    memory.path = try std.fs.path.join(memory.arena.allocator(), &.{ folder, "missing", file_name });
    try std.testing.expectError(error.FileNotFound, memory.forget(io, .lens, "50 mm"));
    try std.testing.expectEqual(@as(usize, 1), memory.count(.lens));
}
