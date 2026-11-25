//! The computer's clock, as its user reads it.

const std = @import("std");
const c = @import("c");
const Date = @import("minilab").date.Date;

/// Today in the computer's time zone, which is the day the user means by today. Falls back to
/// today in UTC when the system can't say.
pub fn today(io: std.Io) Date {
    var now: c.SDL_Time = 0;
    var local: c.SDL_DateTime = .{};
    if (!c.SDL_GetCurrentTime(&now) or !c.SDL_TimeToDateTime(now, &local, true)) return Date.today(io);
    return .{ .year = @intCast(local.year), .month = @intCast(local.month), .day = @intCast(local.day) };
}
