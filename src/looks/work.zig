//! Work done away from the page, so that it keeps answering: reading and lining up pairs,
//! finding which frame a reference shows, and fitting. A job runs on its own thread; the page
//! looks at `done` each frame and takes the results once it's set.

const std = @import("std");
const pairs = @import("pairs.zig");
const draft = @import("draft.zig");
const register = @import("register.zig");
const fit = @import("fit.zig");

pub const Job = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    task: Task,
    /// Set by the job when it's finished.
    done: std.atomic.Value(bool) = .init(false),
    /// Set by the page to stop the job early.
    cancelled: std.atomic.Value(bool) = .init(false),
    /// Steps done, of `steps`, for the page to show.
    progress: std.atomic.Value(u32) = .init(0),
    steps: u32 = 1,
    future: ?std.Io.Future(void) = null,

    /// Starts `task` on its own thread, or here when there's no thread to be had. The job owns
    /// what the task holds from now on.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, task: Task) !*Job {
        // The task is the job's from here, and goes with it; a job that can't be made frees it.
        const job = gpa.create(Job) catch |err| {
            var dropped = task;
            dropped.deinit(gpa);
            return err;
        };
        job.* = .{ .gpa = gpa, .io = io, .task = task };
        job.steps = switch (task) {
            .prepare => |p| @intCast(@max(1, p.items.len)),
            .match => |m| @intCast(@max(1, m.frames.len + m.references.len)),
            .fit => 1,
        };
        job.future = io.concurrent(run, .{job}) catch null;
        if (job.future == null) run(job);
        return job;
    }

    pub fn isDone(job: *const Job) bool {
        return job.done.load(.acquire);
    }

    /// Waits for the job, stopping it early if `stop`, and frees it with whatever results the
    /// page didn't take.
    pub fn finish(job: *Job, stop: bool) void {
        if (stop) job.cancelled.store(true, .release);
        if (job.future) |*f| f.await(job.io);
        job.task.deinit(job.gpa);
        job.gpa.destroy(job);
    }

    fn stopped(job: *const Job) bool {
        return job.cancelled.load(.acquire);
    }

    fn step(job: *Job) void {
        _ = job.progress.fetchAdd(1, .release);
    }
};

pub const Task = union(enum) {
    prepare: Prepare,
    match: Match,
    fit: Fit,

    fn deinit(task: *Task, gpa: std.mem.Allocator) void {
        switch (task.*) {
            inline else => |*t| t.deinit(gpa),
        }
    }
};

/// Reads pairs, and lines up those that aren't yet.
pub const Prepare = struct {
    items: []Item,

    pub const Item = struct {
        /// The pair's place in its look.
        pair: usize,
        ours: []u8,
        theirs: []u8,
        /// Where our frame lies on its scan; null to find it.
        placement: ?draft.Placement = null,
        /// Known already, or worked out by the job.
        alignment: ?register.Alignment,
        /// The result, which the page takes.
        prepared: ?*pairs.Prepared = null,
        failure: ?anyerror = null,
    };

    /// A task for `count` pairs, their paths to be filled in with `set`.
    pub fn init(gpa: std.mem.Allocator, count: usize) !Prepare {
        const items = try gpa.alloc(Item, count);
        for (items) |*i| i.* = .{ .pair = 0, .ours = &.{}, .theirs = &.{}, .alignment = null };
        return .{ .items = items };
    }

    pub fn set(p: *Prepare, gpa: std.mem.Allocator, index: usize, pair: usize, ours: []const u8, placement: ?draft.Placement, theirs: []const u8, alignment: ?register.Alignment) !void {
        const item = &p.items[index];
        item.pair = pair;
        item.ours = try gpa.dupe(u8, ours);
        errdefer gpa.free(item.ours);
        item.theirs = try gpa.dupe(u8, theirs);
        item.placement = placement;
        item.alignment = alignment;
    }

    fn deinit(p: *Prepare, gpa: std.mem.Allocator) void {
        for (p.items) |*i| {
            gpa.free(i.ours);
            gpa.free(i.theirs);
            if (i.prepared) |prepared| {
                prepared.deinit(gpa);
                gpa.destroy(prepared);
            }
        }
        gpa.free(p.items);
    }

    fn run(p: *Prepare, job: *Job) void {
        for (p.items) |*item| {
            if (job.stopped()) return;
            defer job.step();
            if (item.ours.len == 0) continue;
            const prepared = job.gpa.create(pairs.Prepared) catch |err| {
                item.failure = err;
                continue;
            };
            prepared.* = pairs.prepare(job.gpa, job.io, item.ours, item.placement, item.theirs) catch |err| {
                job.gpa.destroy(prepared);
                item.failure = err;
                continue;
            };
            item.prepared = prepared;
            if (item.alignment == null) {
                item.alignment = prepared.locate(job.gpa) catch |err| blk: {
                    item.failure = err;
                    break :blk null;
                };
            }
        }
    }
};

/// Finds the frame each reference shows, among `frames`.
pub const Match = struct {
    references: [][]u8,
    frames: []Frame,
    /// For each reference: the frame it shows, if one matches well enough, and how well.
    found: []?usize,
    quality: []f32,

    pub const Frame = struct {
        /// The raw scan, and its thumbnail, which the matching reads.
        scan: []u8,
        thumbnail: []u8,
        label: []u8,
        stock: ?[]u8,
        /// Where the frame lies on its scan and thumbnail: frames of a strip share both.
        placement: draft.Placement = .{},
    };

    /// The correlation at the coarse level a reference needs to count as showing a frame.
    pub const least_quality = 0.6;

    pub fn init(gpa: std.mem.Allocator, references: []const []const u8, frames: usize) !Match {
        const refs = try gpa.alloc([]u8, references.len);
        for (refs, references) |*r, path| r.* = try gpa.dupe(u8, path);
        const f = try gpa.alloc(Frame, frames);
        for (f) |*frame| frame.* = .{ .scan = &.{}, .thumbnail = &.{}, .label = &.{}, .stock = null };
        const found = try gpa.alloc(?usize, references.len);
        @memset(found, null);
        const quality = try gpa.alloc(f32, references.len);
        @memset(quality, 0);
        return .{ .references = refs, .frames = f, .found = found, .quality = quality };
    }

    pub fn setFrame(m: *Match, gpa: std.mem.Allocator, index: usize, scan: []const u8, thumbnail: []const u8, label: []const u8, stock: ?[]const u8, placement: draft.Placement) !void {
        m.frames[index] = .{
            .placement = placement,
            .scan = try gpa.dupe(u8, scan),
            .thumbnail = try gpa.dupe(u8, thumbnail),
            .label = try gpa.dupe(u8, label),
            .stock = if (stock) |s| try gpa.dupe(u8, s) else null,
        };
    }

    fn deinit(m: *Match, gpa: std.mem.Allocator) void {
        for (m.references) |r| gpa.free(r);
        gpa.free(m.references);
        for (m.frames) |f| {
            gpa.free(f.scan);
            gpa.free(f.thumbnail);
            gpa.free(f.label);
            if (f.stock) |s| gpa.free(s);
        }
        gpa.free(m.frames);
        gpa.free(m.found);
        gpa.free(m.quality);
    }

    fn run(m: *Match, job: *Job) void {
        const gpa = job.gpa;
        const grays = gpa.alloc(?register.Gray, m.frames.len) catch return;
        defer gpa.free(grays);
        @memset(grays, null);
        defer for (grays) |*g| if (g.*) |*gray| gray.deinit(gpa);
        for (m.frames, grays) |frame, *g| {
            if (job.stopped()) return;
            defer job.step();
            if (frame.thumbnail.len == 0) continue;
            g.* = pairs.thumbnailGray(gpa, job.io, frame.thumbnail, frame.placement) catch null;
        }
        for (m.references, m.found, m.quality) |path, *found, *quality| {
            if (job.stopped()) return;
            defer job.step();
            var gray = pairs.referenceGray(gpa, job.io, path) catch continue;
            defer gray.deinit(gpa);
            var small = gray.reduce(gpa, 256) catch continue;
            defer small.deinit(gpa);
            var pyramid = register.Pyramid.init(gpa, small) catch continue;
            defer pyramid.deinit(gpa);
            for (grays, 0..) |g, i| {
                const ours = g orelse continue;
                const best = register.coarse(gpa, ours, &pyramid) catch continue;
                if (best[0].quality > quality.*) {
                    quality.* = best[0].quality;
                    found.* = i;
                }
            }
            if (quality.* < least_quality) found.* = null;
        }
    }
};

/// Samples every pair and fits a look to them.
pub const Fit = struct {
    /// The pairs, read; the page keeps them and doesn't change them while the job runs.
    prepared: []const *const pairs.Prepared,
    alignments: []register.Alignment,
    held_out: []bool,
    options: fit.Options,
    /// The result, which the page takes.
    result: ?fit.Result = null,
    failure: ?anyerror = null,

    fn deinit(f: *Fit, gpa: std.mem.Allocator) void {
        gpa.free(f.prepared);
        gpa.free(f.alignments);
        gpa.free(f.held_out);
        if (f.result) |*r| r.deinit(gpa);
    }

    fn run(f: *Fit, job: *Job) void {
        defer job.step();
        f.result = attempt(f, job) catch |err| blk: {
            f.failure = err;
            break :blk null;
        };
    }

    fn attempt(f: *Fit, job: *Job) !fit.Result {
        var samples: std.ArrayList(fit.Sample) = .empty;
        defer samples.deinit(job.gpa);
        for (f.prepared, f.alignments, 0..) |p, a, i| {
            if (job.stopped()) return error.Canceled;
            try pairs.sample(job.gpa, p, a, @intCast(i), &samples);
        }
        return fit.fit(job.gpa, samples.items, f.held_out, f.options);
    }
};

fn run(job: *Job) void {
    defer job.done.store(true, .release);
    switch (job.task) {
        inline else => |*t| t.run(job),
    }
}

/// A made-up negative of a scene of soft blobs, `seed` choosing them: 16-bit transmission, as a
/// scanner gives it, with a film base that's orange like a colour negative's.
fn testNegative(gpa: std.mem.Allocator, seed: u64, width: usize, height: usize) !minilab.image.Scan {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var blobs: [16][6]f32 = undefined;
    for (&blobs) |*b| {
        // A level, and a little colour about it, as a photograph has.
        const level = random.float(f32) * 0.8;
        b.* = .{ random.float(f32), random.float(f32) * 0.7, 0.03 + random.float(f32) * 0.1, level, level, level };
        for (b[3..6]) |*v| v.* += (random.float(f32) - 0.5) * 0.3;
    }
    // A gentle slope across the frame, its own way for each scene.
    const slope = [2]f32{ random.float(f32) - 0.5, random.float(f32) - 0.5 };
    var scan: minilab.image.Scan = try .init(gpa, width, height);
    const base = [3]f32{ 0.8, 0.5, 0.3 };
    for (0..height) |y| {
        for (0..width) |x| {
            const fx = (@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(width));
            const fy = (@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(width));
            var density: [3]f32 = @splat(0.4 + 0.5 * (slope[0] * fx + slope[1] * fy));
            for (blobs) |b| {
                const d = ((fx - b[0]) * (fx - b[0]) + (fy - b[1]) * (fy - b[1])) / (2 * b[2] * b[2]);
                const w = @exp(-d);
                for (&density, b[3..6]) |*v, c| v.* += w * c;
            }
            for (&scan.pixels[y * width + x], density, base) |*out, d, b| {
                out.* = @intFromFloat(std.math.clamp(b * std.math.pow(f32, 10, -d) * 65535, 0, 65535));
            }
        }
    }
    return scan;
}

const minilab = @import("../root.zig");

test "jobs read, match and fit pairs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(dir);
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // Three negatives, each with its thumbnail, and a reference of each: our Neutral rendering,
    // turned a quarter for the second, as a JPEG.
    var scans: [3][]const u8 = undefined;
    var thumbnails: [3][]const u8 = undefined;
    var references: [3][]const u8 = undefined;
    for (0..3) |i| {
        var scan = try testNegative(gpa, i + 1, 360, 240);
        defer scan.deinit(gpa);
        const bytes = try minilab.pnm.write(gpa, u16, scan);
        defer gpa.free(bytes);
        scans[i] = try std.fmt.allocPrint(a, "{s}/scan{d}.ppm", .{ dir, i });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = scans[i], .data = bytes });
        var small = try minilab.image.downscale(gpa, scan, 128);
        defer small.deinit(gpa);
        const small_bytes = try minilab.pnm.write(gpa, u16, small);
        defer gpa.free(small_bytes);
        thumbnails[i] = try std.fmt.allocPrint(a, "{s}/thumb{d}.ppm", .{ dir, i });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = thumbnails[i], .data = small_bytes });

        var developed = try pairs.developScan(gpa, io, scans[i], 300, null);
        defer developed.deinit(gpa);
        const n = developed.neutral;
        const turned = i == 1;
        var encoded: minilab.image.Encoded8 = try .init(gpa, if (turned) n.height else n.width, if (turned) n.width else n.height);
        defer encoded.deinit(gpa);
        for (0..n.height) |y| {
            for (0..n.width) |x| {
                const p = n.pixels[y * n.width + x];
                // Turned clockwise: (x, y) goes to (height − 1 − y, x).
                const at = if (turned) x * encoded.width + (n.height - 1 - y) else y * n.width + x;
                encoded.pixels[at] = p[0..3].*;
            }
        }
        const jpeg = try minilab.codecs.jpeg.write(gpa, encoded, .{ .quality = 95, .subsampling = .@"4:4:4" });
        defer gpa.free(jpeg);
        references[i] = try std.fmt.allocPrint(a, "{s}/reference{d}.jpg", .{ dir, i });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = references[i], .data = jpeg });
    }

    // Each reference finds its own frame.
    var match = try Match.init(gpa, &references, 3);
    for (0..3) |i| try match.setFrame(gpa, i, scans[i], thumbnails[i], "frame", null, .{});
    const matching = try Job.start(gpa, io, .{ .match = match });
    defer matching.finish(false);
    while (!matching.isDone()) try io.sleep(.fromMilliseconds(5), .awake);
    for (matching.task.match.found, 0..) |found, i| try std.testing.expectEqual(@as(?usize, i), found);

    // Read and line up each pair.
    var prepare = try Prepare.init(gpa, 3);
    for (0..3) |i| try prepare.set(gpa, i, i, scans[i], null, references[i], null);
    const reading = try Job.start(gpa, io, .{ .prepare = prepare });
    defer reading.finish(false);
    while (!reading.isDone()) try io.sleep(.fromMilliseconds(5), .awake);
    var prepared: [3]*const pairs.Prepared = undefined;
    var alignments: [3]register.Alignment = undefined;
    for (reading.task.prepare.items, 0..) |*item, i| {
        try std.testing.expect(item.failure == null);
        prepared[i] = item.prepared.?;
        alignments[i] = item.alignment.?;
        try std.testing.expect(alignments[i].quality > 0.9);
    }
    try std.testing.expectEqual(register.Orientation.three_quarters, alignments[1].orientation);

    // Fit to two, check on the third: the reference is our own rendering, so the look is close.
    const fitting = try Job.start(gpa, io, .{ .fit = .{
        .prepared = try gpa.dupe(*const pairs.Prepared, &prepared),
        .alignments = try gpa.dupe(register.Alignment, &alignments),
        .held_out = try gpa.dupe(bool, &.{ false, false, true }),
        .options = .{},
    } });
    defer fitting.finish(false);
    while (!fitting.isDone()) try io.sleep(.fromMilliseconds(5), .awake);
    const report = fitting.task.fit.result.?.report;
    try std.testing.expectEqual(@as(usize, 2), report.fitted_pairs);
    try std.testing.expect(report.median.? < 3);
}
