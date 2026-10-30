//! Writes minilab's icon as a Windows .ico file or a macOS .icns file, by the name's extension.
//! The build puts the first into the Windows program and the second into the macOS app.
//!
//! usage: make_icon <out.ico | out.icns>

const std = @import("std");
const icon = @import("platform/icon.zig");

/// The exit status for a command line it doesn't understand, as minilab's own.
const usage_status = 2;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const extension = if (args.len == 2) std.fs.path.extension(args[1]) else "";
    const file = if (std.mem.eql(u8, extension, ".ico"))
        try icon.windowsIcon(init.gpa)
    else if (std.mem.eql(u8, extension, ".icns"))
        try icon.macIcon(init.gpa)
    else {
        std.log.err("usage: make_icon <out.ico | out.icns>", .{});
        std.process.exit(usage_status);
    };
    defer init.gpa.free(file);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[1], .data = file });
}
