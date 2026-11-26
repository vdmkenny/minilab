//! Prints every message in English as a language file, ready to translate: `zig build
//! translation-template > src/i18n/xx.zon`. docs/translating.md has the rest.

const std = @import("std");
const Messages = @import("messages.zig").Messages;

pub fn main(init: std.process.Init) !void {
    // Writing hundreds of messages out takes more compile-time steps than Zig allows by default.
    @setEvalBranchQuota(1_000_000);
    var buffer: [4096]u8 = undefined;
    var stdout: std.Io.File.Writer = .initStreaming(.stdout(), init.io, &buffer);
    try std.zon.stringify.serialize(Messages{}, .{}, &stdout.interface);
    try stdout.interface.writeAll("\n");
    try stdout.interface.flush();
}
