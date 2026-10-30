//! Looks for an update on a thread of its own when the app starts, and downloads and installs one
//! when asked. The window never waits on it, and without internet it quietly finds nothing.

const std = @import("std");
const minilab = @import("minilab");
const build_options = @import("build_options");
const version = @import("../version.zig");

const update = minilab.update;

pub const Phase = enum(u8) {
    /// Asking GitHub for the latest release.
    checking,
    /// Nothing newer, or GitHub couldn't be asked.
    none,
    /// A newer release is waiting to be installed.
    available,
    downloading,
    installing,
    /// The new release is in place, for the app to restart into.
    installed,
    failed,
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    thread: ?std.Thread = null,
    phase: std.atomic.Value(Phase) = .init(.checking),
    /// Bytes of the archive downloaded so far.
    downloaded: std.atomic.Value(u64) = .init(0),
    cancel: std.atomic.Value(bool) = .init(false),
    /// Set when the thread has ended, so `stop` knows it can join it.
    finished: std.atomic.Value(bool) = .init(false),

    // The thread sets these before it moves `phase` on, and the window reads them after.
    release: ?update.Release = null,
    /// The program's folder, which an update goes into.
    folder: []u8 = &.{},
    /// Whether the program's folder can take an update.
    writable: bool = false,
    /// Whether the program carries a Developer ID signature, so macOS opens it without complaint.
    signed: bool = true,
    failure: ?anyerror = null,

    /// Starts looking for an update, for a release build on a system the releases are built for.
    /// Returns null for any other build, or if the thread can't start.
    pub fn start(gpa: std.mem.Allocator, io: std.Io) ?*Worker {
        if (!build_options.updates or update.platform == null) return null;
        const worker = gpa.create(Worker) catch return null;
        worker.* = .{ .gpa = gpa, .io = io };
        worker.thread = std.Thread.spawn(.{}, check, .{worker}) catch {
            gpa.destroy(worker);
            return null;
        };
        return worker;
    }

    fn check(worker: *Worker) void {
        defer worker.finished.store(true, .release);
        const gpa = worker.gpa;
        // The folder is found now, before an update moves the running program aside: on Linux,
        // the program's path follows it.
        const program_folder = std.process.executableDirPathAlloc(worker.io, gpa) catch return worker.phase.store(.none, .release);
        defer gpa.free(program_folder);
        const folder = update.installFolder(program_folder) orelse return worker.phase.store(.none, .release);
        worker.folder = gpa.dupe(u8, folder) catch return worker.phase.store(.none, .release);
        update.cleanUp(worker.io, worker.folder);
        var client: std.http.Client = .{ .allocator = gpa, .io = worker.io };
        defer client.deinit();
        const found = update.newerRelease(gpa, &client, version.string) catch |err| {
            std.log.info("couldn't look for an update: {t}", .{err});
            return worker.phase.store(.none, .release);
        };
        worker.release = found orelse return worker.phase.store(.none, .release);
        worker.writable = update.writable(worker.io, worker.folder);
        worker.signed = update.developerIdSigned(gpa, worker.io, worker.folder);
        worker.phase.store(.available, .release);
    }

    /// Downloads, checks and installs the release that was found, on the thread. The window
    /// follows along through `phase` and `downloaded`.
    pub fn install(worker: *Worker) void {
        switch (worker.phase.load(.acquire)) {
            .available, .failed => {},
            else => return,
        }
        if (worker.thread) |thread| thread.join();
        worker.thread = null;
        worker.finished.store(false, .release);
        worker.downloaded.store(0, .release);
        worker.failure = null;
        worker.phase.store(.downloading, .release);
        worker.thread = std.Thread.spawn(.{}, installing, .{worker}) catch |err| {
            worker.finished.store(true, .release);
            return worker.fail(err);
        };
    }

    fn installing(worker: *Worker) void {
        defer worker.finished.store(true, .release);
        const gpa = worker.gpa;
        var client: std.http.Client = .{ .allocator = gpa, .io = worker.io };
        defer client.deinit();
        const archive = update.download(gpa, &client, &worker.release.?, &worker.downloaded, &worker.cancel) catch |err| return worker.fail(err);
        defer gpa.free(archive);
        worker.phase.store(.installing, .release);
        update.install(gpa, worker.io, archive, worker.folder) catch |err| return worker.fail(err);
        worker.phase.store(.installed, .release);
    }

    fn fail(worker: *Worker, err: anyerror) void {
        std.log.err("couldn't update: {t}", .{err});
        worker.failure = err;
        worker.phase.store(.failed, .release);
    }

    /// Stops the thread and frees everything. An install that's swapping files is finished first.
    /// A check or download that's still waiting on the network is cancelled and left to end with
    /// the process, and then the worker isn't freed.
    pub fn stop(worker: *Worker) void {
        worker.cancel.store(true, .release);
        if (worker.thread) |thread| {
            if (!worker.finished.load(.acquire) and worker.phase.load(.acquire) != .installing) {
                thread.detach();
                return;
            }
            thread.join();
        }
        if (worker.release) |*release| release.deinit();
        worker.gpa.free(worker.folder);
        worker.gpa.destroy(worker);
    }
};
