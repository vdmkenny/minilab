//! Splitting work over the cores. The work comes in pieces numbered from 0 that don't depend on
//! each other, like a render's pixels or a TIFF's strips, so it can be cut into runs of pieces in
//! a row, one run per thread.

const std = @import("std");

/// The most threads one piece of work is split over.
pub const max_threads = 16;

/// How many runs to cut `count` pieces into so that each run has at least `fewest` of them, since
/// below that starting a thread costs more than it saves: one per core, up to `max_threads`, and
/// always at least one.
pub fn bandCount(count: usize, fewest: usize) usize {
    const cores = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(max_threads, cores, count / @max(fewest, 1)));
}

/// Cuts pieces 0 up to `count` into `bands` runs in a row, and has `job.run(band, first, end)` do
/// each run, all but the last on threads of their own. `run` has to be public. A run whose thread
/// can't start is done here instead, so the work always gets done.
pub fn inBands(count: usize, bands: usize, job: anytype) void {
    std.debug.assert(bands >= 1 and bands <= max_threads);
    const share = (count + bands - 1) / bands;
    var threads: [max_threads]?std.Thread = @splat(null);
    for (threads[0 .. bands - 1], 0..) |*thread, band| {
        const first = @min(count, band * share);
        const end = @min(count, first + share);
        thread.* = std.Thread.spawn(.{}, @TypeOf(job).run, .{ job, band, first, end }) catch null;
        if (thread.* == null) job.run(band, first, end);
    }
    job.run(bands - 1, @min(count, (bands - 1) * share), count);
    for (threads[0 .. bands - 1]) |thread| if (thread) |t| t.join();
}

test "every piece is done once, by one run, however the pieces are cut" {
    const Count = struct {
        times: []u8,
        pub fn run(job: @This(), _: usize, first: usize, end: usize) void {
            for (job.times[first..end]) |*t| t.* += 1;
        }
    };
    var times: [100]u8 = undefined;
    for ([_]usize{ 0, 1, 5, 10, 100 }) |count| {
        for ([_]usize{ 1, 3, 4, max_threads }) |bands| {
            @memset(&times, 0);
            inBands(count, bands, Count{ .times = times[0..count] });
            for (times[0..count]) |t| try std.testing.expectEqual(1, t);
        }
    }
    try std.testing.expectEqual(1, bandCount(1000, 1 << 20));
    try std.testing.expect(bandCount(1000, 1) >= 1 and bandCount(1000, 1) <= max_threads);
}
