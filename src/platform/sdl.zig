//! What the SDL wrappers share: one error for a call that failed, with SDL's own message logged.

const std = @import("std");
const c = @import("c");

pub const Error = error{Sdl};

/// Logs SDL's last error against `what`, the call that failed, and returns it as an error.
pub fn fail(what: []const u8) Error {
    logError(what);
    return error.Sdl;
}

pub fn logError(what: []const u8) void {
    std.log.scoped(.sdl).err("{s}: {s}", .{ what, c.SDL_GetError() });
}
