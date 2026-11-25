//! The user's account on this computer.

const std = @import("std");
const builtin = @import("builtin");

/// The account's full name, like "Ada Lovelace", in `buffer`, or null when the system doesn't
/// have one: the name in the account's user record on macOS and Linux, and its display name on
/// Windows.
pub fn fullName(buffer: []u8) ?[]const u8 {
    return switch (builtin.os.tag) {
        .windows => windowsName(buffer),
        .macos, .linux, .freebsd, .openbsd, .netbsd, .dragonfly => unixName(buffer),
        else => null,
    };
}

fn unixName(buffer: []u8) ?[]const u8 {
    const record = std.c.getpwuid(std.c.getuid()) orelse return null;
    const name = nameFromGecos(std.mem.span(record.gecos orelse return null)) orelse return null;
    if (name.len > buffer.len) return null;
    @memcpy(buffer[0..name.len], name);
    return buffer[0..name.len];
}

/// The full name from a user record's GECOS field: the part before its first comma, which is
/// where the rest of the old contact details go on Linux.
fn nameFromGecos(gecos: []const u8) ?[]const u8 {
    const end = std.mem.indexOfScalar(u8, gecos, ',') orelse gecos.len;
    const name = std.mem.trim(u8, gecos[0..end], " ");
    return if (name.len == 0) null else name;
}

/// What GetUserNameExW calls an account's display name.
const name_display = 3;
/// The longest display name we read, in UTF-16 units.
const max_windows_name = 256;

extern "secur32" fn GetUserNameExW(format: c_int, name: [*]u16, size: *u32) callconv(.winapi) u8;

fn windowsName(buffer: []u8) ?[]const u8 {
    var wide: [max_windows_name]u16 = undefined;
    var size: u32 = wide.len;
    if (GetUserNameExW(name_display, &wide, &size) == 0 or size == 0) return null;
    const len = std.unicode.utf16LeToUtf8(buffer, wide[0..size]) catch return null;
    const name = std.mem.trim(u8, buffer[0..len], " ");
    return if (name.len == 0) null else name;
}

test "the full name is the first part of the GECOS field" {
    try std.testing.expectEqualStrings("Ada Lovelace", nameFromGecos("Ada Lovelace,,,").?);
    try std.testing.expectEqualStrings("Ada Lovelace", nameFromGecos("Ada Lovelace").?);
    try std.testing.expectEqual(@as(?[]const u8, null), nameFromGecos(",,,"));
    try std.testing.expectEqual(@as(?[]const u8, null), nameFromGecos(""));
}
