//! Calendar dates as rolls keep them: ISO 8601 at one of three precisions, a year (2026), a
//! month (2026-10) or a day (2026-10-22). A roll's shot date can be any of the three, since you
//! don't always know the day a roll was shot.

const std = @import("std");
const Io = std.Io;
const epoch = std.time.epoch;

pub const Date = struct {
    year: u16,
    month: ?u8 = null,
    day: ?u8 = null,

    /// Reads `text` as a year, a month or a day, or returns null when it isn't one of them.
    pub fn parse(text: []const u8) ?Date {
        if (text.len != 4 and text.len != 7 and text.len != 10) return null;
        var date: Date = .{ .year = std.fmt.parseInt(u16, text[0..4], 10) catch return null };
        if (text.len >= 7) {
            if (text[4] != '-') return null;
            const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
            if (month < 1 or month > months_in_year) return null;
            date.month = month;
        }
        if (text.len == 10) {
            if (text[7] != '-') return null;
            const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
            if (day < 1 or day > daysIn(date.year, date.month.?)) return null;
            date.day = day;
        }
        return date;
    }

    /// Writes the date in `buffer` as ISO 8601, at its own precision.
    pub fn format(date: Date, buffer: []u8) []const u8 {
        const month = date.month orelse return std.fmt.bufPrint(buffer, "{d:0>4}", .{date.year}) catch "";
        const day = date.day orelse return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}", .{ date.year, month }) catch "";
        return std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2}", .{ date.year, month, day }) catch "";
    }

    /// Today, in UTC.
    pub fn today(io: Io) Date {
        const seconds = Io.Clock.real.now(io).toSeconds();
        const day = (epoch.EpochSeconds{ .secs = @intCast(@max(seconds, 0)) }).getEpochDay();
        const year_day = day.calculateYearDay();
        const month_day = year_day.calculateMonthDay();
        return .{ .year = year_day.year, .month = month_day.month.numeric(), .day = month_day.day_index + 1 };
    }
};

/// The longest text a date takes: YYYY-MM-DD.
pub const max_text = "YYYY-MM-DD".len;
pub const months_in_year = 12;
pub const days_in_week = 7;

/// How many days `month` (1 to 12) of `year` has.
pub fn daysIn(year: u16, month: u8) u8 {
    return epoch.getDaysInMonth(year, @fromBackingInt(@intCast(month)));
}

/// The weekday of the first of `month` (1 to 12) in `year`: 0 for Monday, up to 6 for Sunday, as
/// ISO 8601 counts the week.
pub fn firstWeekday(year: u16, month: u8) u8 {
    var days: u32 = 0;
    var y: u16 = epoch.epoch_year;
    while (y < year) : (y += 1) days += epoch.getDaysInYear(y);
    var m: u8 = 1;
    while (m < month) : (m += 1) days += daysIn(year, m);
    // 1 January 1970 was a Thursday.
    const thursday = 3;
    return @intCast((days + thursday) % days_in_week);
}

/// The month after `month` of `year`, or before it when `step` is -1.
pub fn stepMonth(year: u16, month: u8, step: i2) struct { u16, u8 } {
    if (step > 0) return if (month == months_in_year) .{ year + 1, 1 } else .{ year, month + 1 };
    return if (month == 1) .{ year - 1, months_in_year } else .{ year, month - 1 };
}

test "only ISO dates count as dates" {
    try std.testing.expectEqual(Date{ .year = 2026, .month = 10 }, Date.parse("2026-10").?);
    try std.testing.expectEqual(Date{ .year = 2026, .month = 2, .day = 28 }, Date.parse("2026-02-28").?);
    try std.testing.expectEqual(@as(?Date, null), Date.parse("2026-02-30"));
    try std.testing.expectEqual(@as(?Date, null), Date.parse("2026-13"));
    try std.testing.expectEqual(@as(?Date, null), Date.parse("Oct 2026"));
}

test "a date writes back at its own precision" {
    var buffer: [max_text]u8 = undefined;
    for ([_][]const u8{ "2026", "2026-10", "2026-10-22" }) |text| {
        try std.testing.expectEqualStrings(text, Date.parse(text).?.format(&buffer));
    }
}

test "the calendar knows its weekdays and months" {
    // 1 November 2026 is a Sunday, and 1 January 2024 a Monday.
    try std.testing.expectEqual(@as(u8, 6), firstWeekday(2026, 11));
    try std.testing.expectEqual(@as(u8, 0), firstWeekday(2024, 1));
    try std.testing.expectEqual(@as(u8, 29), daysIn(2024, 2));
    try std.testing.expectEqual(.{ @as(u16, 2027), @as(u8, 1) }, stepMonth(2026, 12, 1));
    try std.testing.expectEqual(.{ @as(u16, 2025), @as(u8, 12) }, stepMonth(2026, 1, -1));
}
