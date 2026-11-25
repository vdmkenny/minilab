//! Fonts of the system's that the app borrows for scripts its own fonts don't cover. Japanese is
//! the one so far: every system that sells in Japan has a Japanese font, so the app uses it
//! instead of carrying one of its own, which would be several megabytes.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");

pub const Weight = enum { regular, bold };

/// A font file, and which of the fonts in it to use when it's a collection (.ttc).
pub const Face = struct { path: [:0]const u8, index: u32 = 0 };

/// The Japanese fonts we look for, in order: in which folders, and as which files.
const candidates = struct {
    const macos = std.EnumArray(Weight, []const []const u8).init(.{
        .regular = &.{"ヒラギノ角ゴシック W3.ttc"},
        .bold = &.{"ヒラギノ角ゴシック W6.ttc"},
    });
    const macos_folders = [_][]const u8{"/System/Library/Fonts/"};
    /// In Windows' Fonts folder.
    const windows = std.EnumArray(Weight, []const []const u8).init(.{
        .regular = &.{ "YuGothR.ttc", "meiryo.ttc", "msgothic.ttc" },
        .bold = &.{ "YuGothB.ttc", "meiryob.ttc", "msgothic.ttc" },
    });
    /// Noto Sans CJK, where the distributions put it. A collection's first face is Japanese.
    const linux = std.EnumArray(Weight, []const []const u8).init(.{
        .regular = &.{"NotoSansCJK-Regular.ttc"},
        .bold = &.{"NotoSansCJK-Bold.ttc"},
    });
    const linux_folders = [_][]const u8{
        "/usr/share/fonts/opentype/noto/",
        "/usr/share/fonts/noto-cjk/",
        "/usr/share/fonts/google-noto-cjk/",
        "/usr/share/fonts/google-noto-sans-cjk-fonts/",
        "/usr/share/fonts/truetype/noto/",
        "/usr/share/fonts/noto/",
    };
};

/// The longest path to a font folder we build.
const max_folder = 512;

/// A Japanese font of the system's in `weight`, with its path in `buffer`, or null when there's
/// none of the ones we know.
pub fn japanese(buffer: []u8, weight: Weight) ?Face {
    return switch (builtin.os.tag) {
        .macos => first(buffer, &candidates.macos_folders, candidates.macos.get(weight)),
        .windows => windows: {
            const windows = c.SDL_getenv("WINDIR") orelse break :windows null;
            var folder_buffer: [max_folder]u8 = undefined;
            const folder = std.fmt.bufPrint(&folder_buffer, "{s}\\Fonts\\", .{windows}) catch break :windows null;
            break :windows first(buffer, &.{folder}, candidates.windows.get(weight));
        },
        else => first(buffer, &candidates.linux_folders, candidates.linux.get(weight)),
    };
}

/// The first of `names` in any of `folders` that's there, with its path in `buffer`.
fn first(buffer: []u8, folders: []const []const u8, names: []const []const u8) ?Face {
    for (folders) |folder| for (names) |name| {
        const path = std.fmt.bufPrintSentinel(buffer, "{s}{s}", .{ folder, name }, 0) catch continue;
        if (c.SDL_GetPathInfo(path.ptr, null)) return .{ .path = path };
    };
    return null;
}
