//! Work done off the page's thread, so the page stays responsive: reading and lining up pairs,
//! finding which frame a reference shows, and fitting. A job runs on its own thread. The page
//! checks `done` every frame and takes the results once it's set.

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
    /// How many of the `steps` are done, for the page to show.
    progress: std.atomic.Value(u32) = .init(0),
    steps: u32 = 1,
    future: ?std.Io.Future(void) = null,

    /// Starts `task` on its own thread, or runs it right here when no thread is available. From
    /// now on the job owns whatever the task holds.
    pub fn start(gpa: std.mem.Allocator, io: std.Io, task: Task) !*Job {
        // The task belongs to the job from here on, and is freed with it. If we can't make the
        // job, we free the task right away.
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

    /// Waits for the job, stopping it early if `stop` is set, then frees it along with any
    /// results the page didn't take.
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

/// Reads pairs, and lines up the ones that aren't lined up yet.
pub const Prepare = struct {
    items: []Item,

    pub const Item = struct {
        /// The pair's index in its look.
        pair: usize,
        ours: []u8,
        theirs: []u8,
        /// Where our frame sits on its scan, or null to find it.
        placement: ?draft.Placement = null,
        /// Either known already, or worked out by the job.
        alignment: ?register.Alignment,
        /// The result, which the page takes.
        prepared: ?*pairs.Prepared = null,
        failure: ?anyerror = null,
    };

    /// Makes a task for `count` pairs. Fill in their paths with `set`.
    pub fn init(gpa: std.mem.Allocator, count: usize) !Prepare {
        const items = try gpa.alloc(Item, count);
        for (items) |*i| i.* = .{ .pair = 0, .ours = &.{}, .theirs = &.{}, .alignment = null };
        return .{ .items = items };
    }

    pub fn set(p: *Prepare, gpa: std.mem.Allocator, index: usize, pair: usize, ours: []const u8, placement: ?draft.Placement, theirs: []const u8, alignment: ?register.Alignment) !void {
        // Copy both first, so a failed copy leaves the item as it was.
        const owned_ours = try gpa.dupe(u8, ours);
        errdefer gpa.free(owned_ours);
        const owned_theirs = try gpa.dupe(u8, theirs);
        const item = &p.items[index];
        gpa.free(item.ours);
        gpa.free(item.theirs);
        item.* = .{ .pair = pair, .ours = owned_ours, .theirs = owned_theirs, .placement = placement, .alignment = alignment };
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
    /// For each reference, the frame it shows if one matches well enough, and how well it matches.
    found: []?usize,
    quality: []f32,
    /// Why matching stopped, when it didn't finish.
    failure: ?anyerror = null,

    pub const Frame = struct {
        /// The raw scan and its thumbnail, which the matching reads.
        scan: []u8,
        thumbnail: []u8,
        label: []u8,
        stock: ?[]u8,
        /// Where the frame sits on its scan and thumbnail. The frames of a strip share both.
        placement: draft.Placement = .{},
    };

    /// The correlation a reference needs at the coarse level to count as showing a frame.
    pub const least_quality = 0.6;
    /// The size a lab scan is reduced to before it's compared with the frames' thumbnails.
    const reference_size = 256;

    pub fn init(gpa: std.mem.Allocator, references: []const []const u8, frames: usize) !Match {
        const refs = try gpa.alloc([]u8, references.len);
        var copied: usize = 0;
        errdefer {
            for (refs[0..copied]) |r| gpa.free(r);
            gpa.free(refs);
        }
        for (refs, references) |*r, path| {
            r.* = try gpa.dupe(u8, path);
            copied += 1;
        }
        const f = try gpa.alloc(Frame, frames);
        errdefer gpa.free(f);
        for (f) |*frame| frame.* = .{ .scan = &.{}, .thumbnail = &.{}, .label = &.{}, .stock = null };
        const found = try gpa.alloc(?usize, references.len);
        errdefer gpa.free(found);
        @memset(found, null);
        const quality = try gpa.alloc(f32, references.len);
        @memset(quality, 0);
        return .{ .references = refs, .frames = f, .found = found, .quality = quality };
    }

    pub fn setFrame(m: *Match, gpa: std.mem.Allocator, index: usize, scan: []const u8, thumbnail: []const u8, label: []const u8, stock: ?[]const u8, placement: draft.Placement) !void {
        // Copy everything first, so a failed copy leaves the frame as it was.
        const owned_scan = try gpa.dupe(u8, scan);
        errdefer gpa.free(owned_scan);
        const owned_thumbnail = try gpa.dupe(u8, thumbnail);
        errdefer gpa.free(owned_thumbnail);
        const owned_label = try gpa.dupe(u8, label);
        errdefer gpa.free(owned_label);
        const owned_stock = if (stock) |s| try gpa.dupe(u8, s) else null;
        const frame = &m.frames[index];
        gpa.free(frame.scan);
        gpa.free(frame.thumbnail);
        gpa.free(frame.label);
        if (frame.stock) |s| gpa.free(s);
        frame.* = .{ .placement = placement, .scan = owned_scan, .thumbnail = owned_thumbnail, .label = owned_label, .stock = owned_stock };
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
        m.attempt(job) catch |err| {
            m.failure = err;
        };
    }

    /// Matches each reference against every frame. A thumbnail or a reference that can't be read
    /// just matches nothing; running out of memory stops the job.
    fn attempt(m: *Match, job: *Job) !void {
        const gpa = job.gpa;
        const grays = try gpa.alloc(?register.Gray, m.frames.len);
        defer gpa.free(grays);
        @memset(grays, null);
        defer for (grays) |*g| if (g.*) |*gray| gray.deinit(gpa);
        for (m.frames, grays) |frame, *g| {
            if (job.stopped()) return;
            defer job.step();
            if (frame.thumbnail.len == 0) continue;
            g.* = pairs.thumbnailGray(gpa, job.io, frame.thumbnail, frame.placement) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => null,
            };
        }
        for (m.references, m.found, m.quality) |path, *found, *quality| {
            if (job.stopped()) return;
            defer job.step();
            var gray = pairs.referenceGray(gpa, job.io, path) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    std.log.warn("{s} can't be read: {t}", .{ path, err });
                    continue;
                },
            };
            defer gray.deinit(gpa);
            var small = try gray.reduce(gpa, reference_size);
            defer small.deinit(gpa);
            var pyramid = try register.Pyramid.init(gpa, small);
            defer pyramid.deinit(gpa);
            for (grays, 0..) |g, i| {
                const ours = g orelse continue;
                const best = try register.coarse(gpa, ours, &pyramid);
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
    /// The pairs, already read. The page keeps them and doesn't change them while the job runs.
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

/// Makes up a negative of a scene of soft blobs, with `seed` choosing the blobs. It's 16-bit
/// transmission, the way a scanner gives it, with an orange film base like a colour negative's.
fn testNegative(gpa: std.mem.Allocator, seed: u64, width: usize, height: usize) !minilab.image.Scan {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var blobs: [16][6]f32 = undefined;
    for (&blobs) |*b| {
        // A level with a little colour around it, like a photograph has.
        const level = random.float(f32) * 0.8;
        b.* = .{ random.float(f32), random.float(f32) * 0.7, 0.03 + random.float(f32) * 0.1, level, level, level };
        for (b[3..6]) |*v| v.* += (random.float(f32) - 0.5) * 0.3;
    }
    // A gentle slope across the frame, in a different direction for each scene.
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

    // Three negatives, each with a thumbnail, and a reference for each: our Neutral rendering as a
    // JPEG, turned a quarter for the second one.
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

    // Fit to two and check on the third. The reference is our own rendering, so the look comes
    // out close.
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

fn setUpJobs(gpa: std.mem.Allocator) !void {
    var prepare: Prepare = try .init(gpa, 2);
    defer prepare.deinit(gpa);
    try prepare.set(gpa, 0, 0, "ours.ppm", null, "theirs.jpg", null);
    try prepare.set(gpa, 0, 1, "ours again.ppm", null, "theirs again.jpg", null);
    var match: Match = try .init(gpa, &.{ "a.jpg", "b.jpg" }, 1);
    defer match.deinit(gpa);
    try match.setFrame(gpa, 0, "scan.ppm", "thumb.ppm", "Frame 1", "Kodak Portra 400", .{});
    try match.setFrame(gpa, 0, "scan.ppm", "thumb.ppm", "Frame 1", null, .{});
}

test "setting up the Looks jobs frees what it made when memory runs out" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, setUpJobs, .{});
}
