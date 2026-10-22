//! Writes minilab's icon as a Windows .ico file. The build puts it into the Windows program.
//!
//! usage: make_icon <out.ico>

const std = @import("std");
const icon = @import("platform/icon.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) {
        std.log.err("usage: make_icon <out.ico>", .{});
        std.process.exit(2);
    }
    const file = try icon.windowsIcon(init.gpa);
    defer init.gpa.free(file);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = file });
}

test {
    _ = icon;
}
