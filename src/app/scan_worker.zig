//! The scan thread. It owns the scanner library and the open scanner, and runs the Scan
//! workspace's jobs one at a time, because every scanner call blocks: listing devices takes
//! seconds, and a frame at 2400 dpi takes minutes. The window stays responsive in the meantime.
//!
//! The workspace hands jobs over with `submit` and collects the results with `take`. Each scanned
//! frame is also finished here: we find its edges again on the full-resolution scan to refine the
//! crop, and turn it into the PPM bytes the roll stores. The only thing left for the window's
//! thread is adding the frame to the roll, since that thread owns the library of rolls.
//!
//! A scan always runs to the end. Cancelling skips the frames after the current one, and throws
//! the current one away once it's been read, because interrupting the V200 mid-scan leaves it
//! stuck.

const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
/// The scanner interface, which lives in the core as `minilab.scan`. The rest of the app gets it
/// from here.
pub const scan = minilab.scan;

const image = minilab.image;
const frames = minilab.frames;

/// Full-resolution scans are reduced to about this resolution before we look for the frame's
/// edges again.
const refine_dpi = 300;
/// A detected frame only refines the crop when its centre is close to where the preview put it:
/// within this share of the frame's length.
const refine_reach = 0.25;

/// How long `stop` waits for a thread that isn't reading a scan, and how often it checks.
const stop_wait_ms = 5000;
const stop_poll_ms = 50;

/// What the thread is doing.
pub const Phase = enum(u8) {
    /// Loading the scanner library.
    loading,
    listing,
    opening,
    idle,
    previewing,
    scanning,
    /// Reading the rest of a cancelled frame.
    finishing,
    /// There's no scanner library on this machine.
    unavailable,
};

/// One frame to scan at full resolution.
pub const FrameJob = struct {
    /// The frame's place in the workspace's queue.
    index: usize,
    request: scan.Request,
    /// Where the crop should go, in mm on the scanner, from the frame's box on the preview.
    crop: scan.Area,
    /// When this is set, the frame's edges are found again on the scan and the crop follows them.
    /// Hand edits are kept as they are.
    refine: ?Refine,

    pub const Refine = struct {
        format: frames.Format,
        kind: frames.Kind,
        axis: frames.Axis,
        holder: frames.Holder = .strip,
        /// How the crop fits the frame's picture.
        fit: frames.Fit = .format,
        /// How much to take off each side of the detected frame, as a share of its size.
        inset: f32,
    };
};

pub const Job = union(enum) {
    /// List the scanners again.
    list,
    /// Open a device from the last list, and read what its transparency source can do.
    open: usize,
    preview: scan.Request,
    /// Scan these, in order. The thread owns the slice once it's submitted.
    frames: []FrameJob,
    /// Use these changes to raw setup from now on, from the scanner settings. The thread owns
    /// them once they're submitted.
    raw: scan.Owned(scan.RawSetting),
};

pub const Stage = enum { list, open, preview, scan };

pub const Event = union(enum) {
    /// The thread's list of devices. Whoever receives the event owns it now.
    devices: []scan.Device,
    opened: struct { device: usize, capabilities: scan.Capabilities },
    /// The scanner was opened again after a scan failed, from a new list of devices, which the
    /// receiver owns now.
    reopened: struct { devices: []scan.Device, device: usize, capabilities: scan.Capabilities },
    failed: struct { stage: Stage, err: anyerror },
    preview: Preview,
    frame_started: usize,
    /// The frame has been read, and is being checked and converted.
    frame_checking: usize,
    frame_done: Scanned,
    frame_failed: struct { index: usize, err: anyerror },
    frame_cancelled: usize,
    queue_done: struct { cancelled: bool },

    /// Frees what the event owns, for events that get dropped.
    pub fn deinit(event: *Event, gpa: std.mem.Allocator) void {
        switch (event.*) {
            .devices => |d| scan.freeDevices(gpa, d),
            .opened => |*o| o.capabilities.deinit(gpa),
            .reopened => |*r| {
                scan.freeDevices(gpa, r.devices);
                r.capabilities.deinit(gpa);
            },
            .preview => |*p| p.scan.deinit(gpa),
            .frame_done => |d| gpa.free(d.ppm),
            else => {},
        }
        event.* = undefined;
    }
};

/// A preview, as the scanner delivered it.
pub const Preview = struct {
    scan: image.Scan,
    /// Pixels per inch, across and down.
    dpi: [2]f32,
    /// The area it covers on the scanner, in mm.
    area: scan.Area,
};

/// A frame that's been scanned and is ready for the roll.
pub const Scanned = struct {
    index: usize,
    /// The scan as a 16-bit binary PPM.
    ppm: []u8,
    dpi: f32,
    /// The frame within the scan.
    crop: image.Area,
    /// Whether the crop was found again on this scan, rather than carried over from the preview.
    refined: bool,
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    thread: std.Thread,
    mutex: std.Io.Mutex = .init,
    wake: std.Io.Condition = .init,
    jobs: std.ArrayList(Job) = .empty,
    events: std.ArrayList(Event) = .empty,
    stopping: bool = false,
    /// Skip the rest of the queue, and drop the frame being read.
    cancel: std.atomic.Value(bool) = .init(false),
    phase: std.atomic.Value(Phase) = .init(.loading),
    progress: scan.Progress = .{},
    /// Whether the thread has taken a job and is running it. It changes under the mutex, together
    /// with the job list, so `pending` never sees the moment between taking a job and starting it
    /// as idle.
    running: bool = false,
    /// Set when the thread has ended, so `stop` knows it can join it.
    finished: std.atomic.Value(bool) = .init(false),

    // These belong to the thread.
    library: ?scan.Library = null,
    devices: []scan.Device = &.{},
    scanner: ?scan.Scanner = null,
    /// The device in `devices` the scanner was opened from. It stays when a failed scan closes
    /// the scanner, so the next one can open it again.
    device: ?usize = null,
    /// The scanner settings' changes, which every scan gets.
    raw: ?scan.Owned(scan.RawSetting) = null,

    /// Starts the thread, which loads the scanner library and lists the devices.
    pub fn start(gpa: std.mem.Allocator, io: std.Io) !*Worker {
        const worker = try gpa.create(Worker);
        errdefer gpa.destroy(worker);
        worker.* = .{ .gpa = gpa, .io = io, .thread = undefined };
        try worker.jobs.append(gpa, .list);
        errdefer worker.jobs.deinit(gpa);
        worker.thread = try std.Thread.spawn(.{}, run, .{worker});
        return worker;
    }

    /// Stops the thread and frees everything. A scan that's under way is read to the end first,
    /// which can take a minute or two at full resolution, because stopping mid-frame leaves the
    /// V200 stuck. Otherwise the thread gets a few seconds. If a SANE call doesn't return in that
    /// time (say, a backend probing a device that doesn't answer), it's left to end with the
    /// process, and the worker isn't freed.
    pub fn stop(worker: *Worker) void {
        const gpa = worker.gpa;
        worker.cancel.store(true, .release);
        worker.mutex.lockUncancelable(worker.io);
        worker.stopping = true;
        worker.wake.signal(worker.io);
        worker.mutex.unlock(worker.io);
        var waited_ms: i64 = 0;
        while (!worker.finished.load(.acquire)) {
            const reading = switch (worker.phase.load(.acquire)) {
                .previewing, .scanning, .finishing => true,
                else => false,
            };
            if (!reading and waited_ms >= stop_wait_ms) {
                std.log.warn("the scan thread didn't end in {d} s; leaving it to the process's end", .{@divTrunc(stop_wait_ms, 1000)});
                worker.thread.detach();
                return;
            }
            std.Io.sleep(worker.io, .fromMilliseconds(stop_poll_ms), .awake) catch {};
            waited_ms += stop_poll_ms;
        }
        worker.thread.join();
        for (worker.jobs.items) |job| freeJob(gpa, job);
        worker.jobs.deinit(gpa);
        for (worker.events.items) |*event| event.deinit(gpa);
        worker.events.deinit(gpa);
        gpa.destroy(worker);
    }

    pub fn submit(worker: *Worker, job: Job) !void {
        worker.mutex.lockUncancelable(worker.io);
        defer worker.mutex.unlock(worker.io);
        if (job == .frames) worker.cancel.store(false, .release);
        try worker.jobs.append(worker.gpa, job);
        worker.wake.signal(worker.io);
    }

    /// Returns the next thing that happened, oldest first. The caller owns it.
    pub fn take(worker: *Worker) ?Event {
        worker.mutex.lockUncancelable(worker.io);
        defer worker.mutex.unlock(worker.io);
        if (worker.events.items.len == 0) return null;
        return worker.events.orderedRemove(0);
    }

    /// Whether any jobs are waiting or running, or any events are waiting to be taken.
    pub fn pending(worker: *Worker) bool {
        worker.mutex.lockUncancelable(worker.io);
        defer worker.mutex.unlock(worker.io);
        return worker.jobs.items.len > 0 or worker.events.items.len > 0 or worker.running or switch (worker.phase.load(.acquire)) {
            .idle, .unavailable => false,
            else => true,
        };
    }

    /// Asks the thread to stop after the frame it's reading, and to drop that frame.
    pub fn cancelQueue(worker: *Worker) void {
        worker.cancel.store(true, .release);
        // Do this in one step. With a separate check and store, the thread could go idle in
        // between, and then `.finishing` would stay for good.
        _ = worker.phase.cmpxchgStrong(.scanning, .finishing, .acq_rel, .acquire);
    }

    fn post(worker: *Worker, event: Event) void {
        worker.mutex.lockUncancelable(worker.io);
        defer worker.mutex.unlock(worker.io);
        worker.events.append(worker.gpa, event) catch {
            var dropped = event;
            dropped.deinit(worker.gpa);
            return;
        };
        // Wake the window, which may be waiting for input.
        var wake: c.SDL_Event = std.mem.zeroes(c.SDL_Event);
        wake.type = c.SDL_EVENT_USER;
        _ = c.SDL_PushEvent(&wake);
    }

    fn run(worker: *Worker) void {
        worker.library = scan.Library.load(worker.gpa, worker.io) catch null;
        if (worker.library == null) worker.phase.store(.unavailable, .release);
        while (true) {
            worker.mutex.lockUncancelable(worker.io);
            while (worker.jobs.items.len == 0 and !worker.stopping) worker.wake.waitUncancelable(worker.io, &worker.mutex);
            if (worker.stopping) {
                worker.mutex.unlock(worker.io);
                break;
            }
            const job = worker.jobs.orderedRemove(0);
            worker.running = true;
            worker.mutex.unlock(worker.io);
            worker.handle(job);
            if (worker.library != null) worker.phase.store(.idle, .release);
            worker.mutex.lockUncancelable(worker.io);
            worker.running = false;
            worker.mutex.unlock(worker.io);
        }
        if (worker.scanner) |*s| s.close();
        if (worker.raw) |*r| r.deinit();
        scan.freeDevices(worker.gpa, worker.devices);
        if (worker.library) |*l| l.unload();
        worker.finished.store(true, .release);
    }

    fn handle(worker: *Worker, job: Job) void {
        const gpa = worker.gpa;
        if (job == .raw) {
            if (worker.raw) |*r| r.deinit();
            worker.raw = job.raw;
            return;
        }
        // Looking for scanners tries the scanner library again, so it's found once it's installed.
        if (worker.library == null and job == .list) worker.library = scan.Library.load(gpa, worker.io) catch null;
        const library = if (worker.library) |*l| l else {
            freeJob(gpa, job);
            worker.post(.{ .failed = .{ .stage = switch (job) {
                .list => .list,
                .open => .open,
                .preview => .preview,
                .frames => .scan,
                .raw => unreachable,
            }, .err = error.Unavailable } });
            return;
        };
        switch (job) {
            .list => {
                worker.phase.store(.listing, .release);
                if (worker.scanner) |*s| s.close();
                worker.scanner = null;
                worker.device = null;
                const found = library.devices(gpa) catch |err| return worker.post(.{ .failed = .{ .stage = .list, .err = err } });
                scan.freeDevices(gpa, worker.devices);
                worker.devices = found;
                const copy = scan.cloneDevices(gpa, found) catch |err| return worker.post(.{ .failed = .{ .stage = .list, .err = err } });
                worker.post(.{ .devices = copy });
            },
            .open => |index| {
                worker.phase.store(.opening, .release);
                if (worker.scanner) |*s| s.close();
                worker.scanner = null;
                worker.device = null;
                if (index >= worker.devices.len) return worker.post(.{ .failed = .{ .stage = .open, .err = error.NotFound } });
                worker.scanner = library.open(gpa, worker.devices[index]) catch |err| return worker.post(.{ .failed = .{ .stage = .open, .err = err } });
                const capabilities = filmCapabilities(gpa, &worker.scanner.?) catch |err| {
                    worker.closeScanner();
                    return worker.post(.{ .failed = .{ .stage = .open, .err = err } });
                };
                worker.device = index;
                worker.post(.{ .opened = .{ .device = index, .capabilities = capabilities } });
            },
            .preview => |request| {
                const scanner = worker.connected(library) catch |err| return worker.post(.{ .failed = .{ .stage = .preview, .err = err } });
                worker.phase.store(.previewing, .release);
                const picture = scanner.scan(gpa, worker.withRaw(request), &worker.progress) catch |err| {
                    worker.closeScanner();
                    return worker.post(.{ .failed = .{ .stage = .preview, .err = err } });
                };
                worker.post(.{ .preview = .{
                    .scan = picture.scan,
                    .dpi = picture.dpi,
                    .area = picture.area,
                } });
            },
            .frames => |list| {
                defer gpa.free(list);
                worker.scanQueue(library, list);
            },
            .raw => unreachable,
        }
    }

    /// The open scanner. After a failed scan it's opened again first, since the scanner may have
    /// been switched off and on, which leaves the old connection dead.
    fn connected(worker: *Worker, library: *scan.Library) scan.Error!*scan.Scanner {
        if (worker.scanner) |*s| return s;
        const index = worker.device orelse return error.NotFound;
        worker.phase.store(.opening, .release);
        return worker.reopen(library, worker.devices[index]);
    }

    /// Lists the devices again and opens `old` among them, and tells the window. A scanner that's
    /// been switched off and on can get a new device name, so if its name has gone, it's found by
    /// its maker and model.
    fn reopen(worker: *Worker, library: *scan.Library, old: scan.Device) scan.Error!*scan.Scanner {
        const gpa = worker.gpa;
        const found = try library.devices(gpa);
        var keep = false;
        defer if (!keep) scan.freeDevices(gpa, found);
        const index = sameDevice(found, old) orelse return error.NotFound;
        var scanner = try library.open(gpa, found[index]);
        errdefer scanner.close();
        var capabilities = try filmCapabilities(gpa, &scanner);
        errdefer capabilities.deinit(gpa);
        const copy = try scan.cloneDevices(gpa, found);
        scan.freeDevices(gpa, worker.devices);
        worker.devices = found;
        keep = true;
        worker.device = index;
        worker.scanner = scanner;
        std.log.info("opened {s} again as {s}", .{ old.model, found[index].id });
        worker.post(.{ .reopened = .{ .devices = copy, .device = index, .capabilities = capabilities } });
        return &worker.scanner.?;
    }

    /// Closes the scanner after a failed scan. `device` stays, so the next scan opens it again.
    fn closeScanner(worker: *Worker) void {
        if (worker.scanner) |*s| s.close();
        worker.scanner = null;
    }

    /// `request` with the scanner settings' changes.
    fn withRaw(worker: *const Worker, request: scan.Request) scan.Request {
        var with = request;
        with.raw = if (worker.raw) |r| r.items else &.{};
        return with;
    }

    fn scanQueue(worker: *Worker, library: *scan.Library, list: []FrameJob) void {
        const gpa = worker.gpa;
        for (list) |job| {
            if (worker.cancel.load(.acquire)) {
                worker.post(.{ .frame_cancelled = job.index });
                continue;
            }
            worker.post(.{ .frame_started = job.index });
            const scanner = worker.connected(library) catch |err| {
                worker.post(.{ .frame_failed = .{ .index = job.index, .err = err } });
                continue;
            };
            if (worker.cancel.load(.acquire)) {
                worker.post(.{ .frame_cancelled = job.index });
                continue;
            }
            worker.phase.store(.scanning, .release);
            var picture = scanner.scan(gpa, worker.withRaw(job.request), &worker.progress) catch |err| {
                worker.closeScanner();
                worker.post(.{ .frame_failed = .{ .index = job.index, .err = err } });
                continue;
            };
            defer picture.deinit(gpa);
            if (worker.cancel.load(.acquire)) {
                worker.post(.{ .frame_cancelled = job.index });
                continue;
            }
            worker.post(.{ .frame_checking = job.index });
            const scanned = finish(gpa, job, picture) catch |err| {
                worker.post(.{ .frame_failed = .{ .index = job.index, .err = err } });
                continue;
            };
            worker.post(.{ .frame_done = scanned });
        }
        worker.post(.{ .queue_done = .{ .cancelled = worker.cancel.load(.acquire) } });
    }
};

/// What `scanner` can do with film, which needs the transparency source. A scanner without one
/// falls back to its default source.
fn filmCapabilities(gpa: std.mem.Allocator, scanner: *scan.Scanner) scan.Error!scan.Capabilities {
    return scanner.capabilities(gpa, .transparency) catch scanner.capabilities(gpa, null);
}

/// Where `old` is in `devices`: by its device name, or else by its driver, maker and model.
fn sameDevice(devices: []const scan.Device, old: scan.Device) ?usize {
    for (devices, 0..) |d, i| if (std.mem.eql(u8, d.id, old.id)) return i;
    for (devices, 0..) |d, i| {
        if (std.mem.eql(u8, d.driver, old.driver) and std.mem.eql(u8, d.vendor, old.vendor) and std.mem.eql(u8, d.model, old.model)) return i;
    }
    return null;
}

/// Turns a frame's scan into what the roll keeps: its PPM bytes and the crop. If the frame was
/// detected rather than placed by hand, the crop is found again on this scan.
fn finish(gpa: std.mem.Allocator, job: FrameJob, picture: scan.Image) !Scanned {
    const whole = picture.scan;
    const px_per_mm = [2]f32{ picture.dpi[0] / minilab.formats.mm_per_inch, picture.dpi[1] / minilab.formats.mm_per_inch };
    // Where the preview says the crop is, in this scan's pixels.
    const planned = toPixels(job.crop, picture.area, px_per_mm, whole.width, whole.height);
    var crop = planned;
    var refined = false;
    if (job.refine) |refine| {
        if (refineCrop(gpa, whole, picture.dpi[0], planned, refine)) |found| {
            crop = found;
            refined = true;
        }
    }
    return .{
        .index = job.index,
        .ppm = try minilab.pnm.write(gpa, u16, whole),
        .dpi = picture.dpi[0],
        .crop = crop,
        .refined = refined,
    };
}

/// Converts `area` on the scanner to pixels of a scan that covers `scanned`, clipped to the scan.
fn toPixels(area: scan.Area, scanned: scan.Area, px_per_mm: [2]f32, width: usize, height: usize) image.Area {
    const x0 = std.math.clamp((area.x - scanned.x) * px_per_mm[0], 0, @as(f32, @floatFromInt(width)));
    const y0 = std.math.clamp((area.y - scanned.y) * px_per_mm[1], 0, @as(f32, @floatFromInt(height)));
    const x1 = std.math.clamp((area.right() - scanned.x) * px_per_mm[0], x0, @as(f32, @floatFromInt(width)));
    const y1 = std.math.clamp((area.bottom() - scanned.y) * px_per_mm[1], y0, @as(f32, @floatFromInt(height)));
    return .{
        .x = @intFromFloat(@round(x0)),
        .y = @intFromFloat(@round(y0)),
        .width = @intFromFloat(@round(x1 - x0)),
        .height = @intFromFloat(@round(y1 - y0)),
    };
}

/// Returns the frame detected on `whole` that's nearest to `planned`, with the inset taken off.
/// Returns null when detection finds none close enough, or isn't sure of the one it finds.
fn refineCrop(gpa: std.mem.Allocator, whole: image.Scan, dpi: f32, planned: image.Area, refine: FrameJob.Refine) ?image.Area {
    const factor: usize = @max(1, @as(usize, @intFromFloat(@round(dpi / refine_dpi))));
    const longest = @max(whole.width, whole.height) / factor;
    var reduced = image.downscale(gpa, whole, longest) catch return null;
    defer reduced.deinit(gpa);
    // The whole-number factor `downscale` actually reduced by, which may be more than `factor`.
    const scale: f32 = @floatFromInt(image.reductionFactor(whole.width, whole.height, longest));
    var detection = frames.detect.detect(gpa, reduced, dpi / scale, refine.format, refine.kind, .{ .axis = refine.axis, .holder = refine.holder }) catch return null;
    defer detection.deinit(gpa);

    const planned_centre = centreOf(planned);
    const length: f32 = @floatFromInt(if (refine.axis == .y) planned.height else planned.width);
    var best: ?image.Area = null;
    var best_distance = refine_reach * length;
    for (detection.frames) |frame| {
        if (frame.confidence != .confident) continue;
        const crop = refine.fit.crop(frame, refine.axis, refine.format.ratio());
        const area: image.Area = .{
            .x = @intFromFloat(@as(f32, @floatFromInt(crop.x)) * scale),
            .y = @intFromFloat(@as(f32, @floatFromInt(crop.y)) * scale),
            .width = @intFromFloat(@as(f32, @floatFromInt(crop.width)) * scale),
            .height = @intFromFloat(@as(f32, @floatFromInt(crop.height)) * scale),
        };
        const centre = centreOf(area);
        // A frame on a strip beside the planned one, in a holder with several openings, isn't it.
        const across = if (refine.axis == .y) centre[0] else centre[1];
        const near: f32 = @floatFromInt(if (refine.axis == .y) planned.x else planned.y);
        const far = near + @as(f32, @floatFromInt(if (refine.axis == .y) planned.width else planned.height));
        if (across < near or across > far) continue;
        const distance = @abs(if (refine.axis == .y) centre[1] - planned_centre[1] else centre[0] - planned_centre[0]);
        if (distance < best_distance) {
            best_distance = distance;
            best = area;
        }
    }
    const found = best orelse return null;
    return inset(found, refine.inset, whole.width, whole.height);
}

fn centreOf(area: image.Area) [2]f32 {
    return .{ @as(f32, @floatFromInt(area.x)) + @as(f32, @floatFromInt(area.width)) / 2, @as(f32, @floatFromInt(area.y)) + @as(f32, @floatFromInt(area.height)) / 2 };
}

/// Returns `area` with `share` of its size taken off each side, clipped to the scan.
pub fn inset(area: image.Area, share: f32, width: usize, height: usize) image.Area {
    const dx: usize = @intFromFloat(@as(f32, @floatFromInt(area.width)) * share);
    const dy: usize = @intFromFloat(@as(f32, @floatFromInt(area.height)) * share);
    const x = @min(area.x + dx, width);
    const y = @min(area.y + dy, height);
    return .{
        .x = x,
        .y = y,
        .width = @min(area.width -| 2 * dx, width - x),
        .height = @min(area.height -| 2 * dy, height - y),
    };
}

fn freeJob(gpa: std.mem.Allocator, job: Job) void {
    switch (job) {
        .frames => |list| gpa.free(list),
        .raw => |owned| {
            var dropped = owned;
            dropped.deinit();
        },
        .list, .open, .preview => {},
    }
}

test "areas on the scanner become pixels of the scan" {
    const scanned: scan.Area = .{ .x = 0, .y = 100, .width = 33, .height = 40 };
    const crop = toPixels(.{ .x = 4, .y = 102, .width = 24, .height = 36 }, scanned, .{ 10, 10 }, 330, 400);
    try std.testing.expectEqual(image.Area{ .x = 40, .y = 20, .width = 240, .height = 360 }, crop);
    const clipped = toPixels(.{ .x = -5, .y = 130, .width = 50, .height = 20 }, scanned, .{ 10, 10 }, 330, 400);
    try std.testing.expectEqual(image.Area{ .x = 0, .y = 300, .width = 330, .height = 100 }, clipped);
}

test "an inset takes a share off each side" {
    try std.testing.expectEqual(image.Area{ .x = 15, .y = 10, .width = 270, .height = 180 }, inset(.{ .x = 0, .y = 0, .width = 300, .height = 200 }, 0.05, 300, 200));
}

test "the scan thread's jobs preview and scan frames on SANE's test backend" {
    if (scan.native != .sane) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    // The jobs run here, on this thread, so the test needs no scheduling.
    var worker: Worker = .{ .gpa = gpa, .io = std.testing.io, .thread = undefined };
    defer {
        for (worker.events.items) |*event| event.deinit(gpa);
        worker.events.deinit(gpa);
    }
    worker.library = scan.Library.load(gpa, std.testing.io) catch return error.SkipZigTest;
    defer worker.library.?.unload();
    const test_device: scan.Device = .{ .id = "test", .vendor = "Noname", .model = "frontend-tester", .driver = "test", .kind = .sane };
    worker.devices = try gpa.alloc(scan.Device, 1);
    worker.devices[0] = try test_device.clone(gpa);
    defer {
        if (worker.scanner) |*s| s.close();
        scan.freeDevices(gpa, worker.devices);
    }

    worker.handle(.{ .open = 0 });
    var opened = worker.take().?;
    defer opened.deinit(gpa);
    if (opened == .failed) return error.SkipZigTest;
    const caps = opened.opened.capabilities;

    worker.handle(.{ .preview = .{ .source = caps.source, .dpi = 50, .area = .{ .x = 0, .y = 0, .width = 40, .height = 80 } } });
    var preview = worker.take().?;
    defer preview.deinit(gpa);
    try std.testing.expect(preview == .preview);
    try std.testing.expect(preview.preview.scan.width > 0 and preview.preview.scan.height > preview.preview.scan.width);

    const list = try gpa.alloc(FrameJob, 2);
    for (list, 0..) |*job, i| {
        const y: f32 = 10 + 40 * @as(f32, @floatFromInt(i));
        job.* = .{
            .index = i,
            .request = .{ .source = caps.source, .dpi = 50, .area = .{ .x = 0, .y = y - 1, .width = 30, .height = 38 } },
            .crop = .{ .x = 3, .y = y, .width = 24, .height = 36 },
            .refine = .{ .format = formats_for_test.format(), .kind = .negative, .axis = .y, .inset = 0 },
        };
    }
    worker.handle(.{ .frames = list });
    var done: usize = 0;
    while (worker.take()) |taken| {
        var event = taken;
        defer event.deinit(gpa);
        switch (event) {
            .frame_done => |scanned| {
                done += 1;
                var back = try minilab.pnm.read(gpa, scanned.ppm);
                defer back.deinit(gpa);
                // The test backend's picture is blank, so the crop stays where the preview put it.
                try std.testing.expect(!scanned.refined);
                try std.testing.expect(scanned.crop.x + scanned.crop.width <= back.width);
                try std.testing.expect(scanned.crop.y + scanned.crop.height <= back.height);
                try std.testing.expectApproxEqAbs(@as(f32, 50), scanned.dpi, 0.5);
            },
            .frame_failed => |failed| return failed.err,
            .queue_done => |q| try std.testing.expect(!q.cancelled),
            else => {},
        }
    }
    try std.testing.expectEqual(@as(usize, 2), done);
}

test "after a failed preview, the next one opens the scanner again" {
    if (scan.native != .sane) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var worker: Worker = .{ .gpa = gpa, .io = std.testing.io, .thread = undefined };
    defer {
        for (worker.events.items) |*event| event.deinit(gpa);
        worker.events.deinit(gpa);
    }
    worker.library = scan.Library.load(gpa, std.testing.io) catch return error.SkipZigTest;
    defer worker.library.?.unload();
    const test_device: scan.Device = .{ .id = "test", .vendor = "Noname", .model = "frontend-tester", .driver = "test", .kind = .sane };
    // Opening it again needs SANE to list the test backend's devices.
    const listed = worker.library.?.devices(gpa) catch return error.SkipZigTest;
    defer scan.freeDevices(gpa, listed);
    if (sameDevice(listed, test_device) == null) return error.SkipZigTest;
    worker.devices = try gpa.alloc(scan.Device, 1);
    worker.devices[0] = try test_device.clone(gpa);
    defer {
        if (worker.scanner) |*s| s.close();
        scan.freeDevices(gpa, worker.devices);
    }

    worker.handle(.{ .open = 0 });
    var opened = worker.take().?;
    defer opened.deinit(gpa);
    if (opened == .failed) return error.SkipZigTest;
    const source = opened.opened.capabilities.source;

    // An area off the scanner fails, and the scanner is closed.
    worker.handle(.{ .preview = .{ .source = source, .dpi = 50, .area = .{ .x = 5000, .y = 5000, .width = 10, .height = 10 } } });
    var failed = worker.take().?;
    defer failed.deinit(gpa);
    try std.testing.expect(failed == .failed);
    try std.testing.expect(worker.scanner == null);

    worker.handle(.{ .preview = .{ .source = source, .dpi = 50, .area = .{ .x = 0, .y = 0, .width = 40, .height = 80 } } });
    var reopened = worker.take().?;
    defer reopened.deinit(gpa);
    try std.testing.expect(reopened == .reopened);
    try std.testing.expectEqualStrings(test_device.model, reopened.reopened.devices[reopened.reopened.device].model);
    var preview = worker.take().?;
    defer preview.deinit(gpa);
    try std.testing.expect(preview == .preview);
}

test "a scanner switched off and on is found again, under a new name if it has one" {
    const old: scan.Device = .{ .id = "epkowa:interpreter:001:004", .vendor = "Epson", .model = "Perfection V200", .driver = "epkowa", .kind = .sane };
    var devices = [_]scan.Device{
        .{ .id = "epson2:libusb:001:009", .vendor = "Epson", .model = "GT-X980", .driver = "epson2", .kind = .sane },
        .{ .id = "epkowa:interpreter:001:005", .vendor = "Epson", .model = "Perfection V200", .driver = "epkowa", .kind = .sane },
    };
    try std.testing.expectEqual(@as(?usize, 1), sameDevice(&devices, old));
    devices[0].id = old.id;
    try std.testing.expectEqual(@as(?usize, 0), sameDevice(&devices, old));
    try std.testing.expectEqual(@as(?usize, null), sameDevice(devices[0..0], old));
}

const formats_for_test = minilab.formats.Standard.@"135_full_frame";
