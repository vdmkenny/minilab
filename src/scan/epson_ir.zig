//! Optional, isolated Epson V600 infrared acquisition. SANE releases the USB
//! handle before this starts, and opens it again for the next ordinary scan.
const std = @import("std");
const builtin = @import("builtin");
const scan = @import("root.zig");
const pnm = @import("../io/pnm.zig");
const mm_per_inch = @import("../frames/root.zig").formats.mm_per_inch;

pub const resolutions = [_]u32{ 800, 1600, 3200 };
const max_file_bytes = 512 * 1024 * 1024 + 1024;
const helper_variable = "MINILAB_EPSON_IR_HELPER";
const library_variable = "MINILAB_EPSON_COMMAND_LIBRARY";

pub fn isV600(device: scan.Device) bool {
    return std.mem.eql(u8, device.driver, "epkowa") and
        (std.ascii.findIgnoreCase(device.model, "V600") != null or std.ascii.findIgnoreCase(device.model, "GT-X820") != null);
}

/// Both paths are explicit: a missing optional component leaves ordinary SANE
/// scanning available. The helper is built from minilab's own source.
pub fn available(io: std.Io, device: scan.Device) bool {
    if (comptime builtin.os.tag != .linux) return false;
    if (!isV600(device)) return false;
    const helper = std.c.getenv(helper_variable) orelse return false;
    const library = std.c.getenv(library_variable) orelse return false;
    std.Io.Dir.cwd().access(io, std.mem.span(helper), .{}) catch return false;
    std.Io.Dir.cwd().access(io, std.mem.span(library), .{}) catch return false;
    return true;
}

pub fn validate(request: scan.Request) scan.Error!void {
    if (request.source != .transparency or
        std.mem.indexOfScalar(u32, &resolutions, request.dpi) == null) return error.Unsupported;
    const area = request.area orelse return error.Unsupported;
    for ([_]f32{ area.x, area.y, area.width, area.height }) |n| if (!std.math.isFinite(n)) return error.Unsupported;
    if (area.x < 0 or area.y < 0 or area.width <= 0 or area.height <= 0 or
        area.right() > 68.58 or area.bottom() > 254) return error.Unsupported;
}

const Poller = struct {
    io: std.Io,
    path: []const u8,
    progress: *scan.Progress,
    stopped: std.atomic.Value(bool) = .init(false),

    fn run(poller: *Poller) void {
        while (!poller.stopped.load(.acquire)) {
            var buffer: [64]u8 = undefined;
            if (std.Io.Dir.cwd().readFile(poller.io, poller.path, &buffer)) |contents| {
                var values = std.mem.tokenizeAny(u8, contents, " \n");
                const lines = std.fmt.parseInt(u32, values.next() orelse "", 10) catch 0;
                const total = std.fmt.parseInt(u32, values.next() orelse "", 10) catch 0;
                if (total > 0 and lines <= total) {
                    poller.progress.total.store(total, .release);
                    poller.progress.lines.store(lines, .release);
                }
            } else |_| {}
            std.Io.sleep(poller.io, .fromMilliseconds(250), .awake) catch {};
        }
    }
};

pub fn acquire(gpa: std.mem.Allocator, io: std.Io, device: scan.Device, request: scan.Request, progress: *scan.Progress) scan.Error!scan.Image {
    try validate(request);
    if (!available(io, device)) return error.Unavailable;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var random: [16]u8 = undefined;
    io.random(&random);
    const folder = std.fmt.allocPrint(a, "/tmp/minilab-ir-{x}", .{random}) catch return error.OutOfMemory;
    std.Io.Dir.cwd().createDir(io, folder, if (comptime builtin.os.tag == .linux) .fromMode(0o700) else .default_dir) catch return error.Failed;
    defer std.Io.Dir.cwd().deleteTree(io, folder) catch {};
    const area = request.area.?;
    const scale = @as(f32, @floatFromInt(request.dpi)) / mm_per_inch;
    const pixels: [4]u32 = .{
        @intFromFloat(@round(area.x * scale)),                        @intFromFloat(@round(area.y * scale)),
        @max(1, @as(u32, @intFromFloat(@round(area.width * scale)))), @max(1, @as(u32, @intFromFloat(@round(area.height * scale)))),
    };
    var number_args: [7][]const u8 = undefined;
    const numbers = [_]u32{ request.dpi, if (request.deep) 16 else 8, if (request.film == .positive) 0 else 1 } ++ pixels;
    for (&number_args, numbers) |*arg, n| arg.* = std.fmt.allocPrint(a, "{d}", .{n}) catch return error.OutOfMemory;
    const argv = [_][]const u8{
        std.mem.span(std.c.getenv(helper_variable).?), "--scan", std.mem.span(std.c.getenv(library_variable).?), device.id, folder,
    } ++ number_args;
    progress.reset();
    const progress_path = std.fs.path.join(a, &.{ folder, "progress" }) catch return error.OutOfMemory;
    var poller: Poller = .{ .io = io, .path = progress_path, .progress = progress };
    const thread = std.Thread.spawn(.{}, Poller.run, .{&poller}) catch return error.Failed;
    defer {
        poller.stopped.store(true, .release);
        thread.join();
    }
    const result = std.process.run(gpa, io, .{
        .argv = &argv,
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch return error.Failed;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (result.term != .exited or result.term.exited != 0) {
        std.log.err("infrared acquisition failed ({any}): {s}", .{ result.term, result.stderr });
        return error.Failed;
    }
    const rgb_path = std.fs.path.join(a, &.{ folder, "rgb.ppm" }) catch return error.OutOfMemory;
    const ir_path = std.fs.path.join(a, &.{ folder, "infrared.pgm" }) catch return error.OutOfMemory;
    const rgb_bytes = std.Io.Dir.cwd().readFileAlloc(io, rgb_path, a, .limited(max_file_bytes)) catch return error.Failed;
    const ir_bytes = std.Io.Dir.cwd().readFileAlloc(io, ir_path, a, .limited(max_file_bytes)) catch return error.Failed;
    var rgb = pnm.decode(gpa, rgb_bytes) catch return error.Failed;
    errdefer rgb.scan.deinit(gpa);
    var infrared = pnm.readGray(gpa, ir_bytes) catch return error.Failed;
    errdefer infrared.deinit(gpa);
    if (rgb.scan.width != pixels[2] or rgb.scan.height != pixels[3] or
        infrared.width != rgb.scan.width or infrared.height != rgb.scan.height or
        rgb.depth != (if (request.deep) .sixteen else @as(@TypeOf(rgb.depth), .eight))) return error.Failed;
    return .{
        .scan = rgb.scan,
        .infrared = infrared,
        .depth = rgb.depth,
        .dpi = @splat(@as(f32, @floatFromInt(request.dpi))),
        .area = .{ .x = @as(f32, @floatFromInt(pixels[0])) / scale, .y = @as(f32, @floatFromInt(pixels[1])) / scale, .width = @as(f32, @floatFromInt(pixels[2])) / scale, .height = @as(f32, @floatFromInt(pixels[3])) / scale },
    };
}

test "infrared capture rejects unsupported film geometry before opening a device" {
    const good: scan.Request = .{ .source = .transparency, .dpi = 800, .area = .{ .x = 10, .y = 30, .width = 10, .height = 10 } };
    try validate(good);
    var bad = good;
    bad.dpi = 400;
    try std.testing.expectError(error.Unsupported, validate(bad));
    bad = good;
    bad.area.?.width = std.math.nan(f32);
    try std.testing.expectError(error.Unsupported, validate(bad));
    bad = good;
    bad.source = .flatbed;
    try std.testing.expectError(error.Unsupported, validate(bad));
}
