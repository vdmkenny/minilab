//! Writes Lucide's icon codepoints as Zig, for icons.zig: `zig build` runs it on the icon font's
//! own list (font/info.json), so an icon picks up its codepoint when Lucide renumbers them, and
//! one Lucide drops fails to compile instead of showing the wrong glyph.
//!
//! usage: bake_icons <out.zig> <info.json>

const std = @import("std");

/// How the list gives an icon's codepoint: a backslash and the hex digits, like "\e0ab".
const Icon = struct { encodedCode: []const u8 };

/// The largest list we read. Lucide's is a few hundred kilobytes.
const max_list = 16 << 20;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) return error.Usage;
    const cwd = std.Io.Dir.cwd();
    const bytes = try cwd.readFileAlloc(init.io, args[2], arena, .limited(max_list));
    const list = try std.json.parseFromSliceLeaky(std.json.ArrayHashMap(Icon), arena, bytes, .{ .ignore_unknown_fields = true });

    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll("//! Lucide's icon codepoints, by the icons' names. Made by bake_icons.zig.\n\n");
    for (list.map.keys(), list.map.values()) |name, icon| {
        const hex = std.mem.trimStart(u8, icon.encodedCode, "\\");
        const codepoint = try std.fmt.parseInt(u21, hex, 16);
        try out.writer.print("pub const @\"{s}\": u21 = 0x{x};\n", .{ name, codepoint });
    }
    try cwd.writeFile(init.io, .{ .sub_path = args[1], .data = out.written() });
}
