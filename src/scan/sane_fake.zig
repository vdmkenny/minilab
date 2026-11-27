//! A scanner made up for the tests: SANE's functions (`sane.Api`) over a `Fake`, with no libsane
//! behind them. The tests in `sane.zig` that use libsane's own test backend only run where SANE
//! is installed. These run everywhere, so `Scanner.scan` is tested on every platform and in CI.
//!
//! A `Fake` has the options scanners have (mode, source, depth, resolution, the area's corners,
//! and an infrared switch if asked for), and sends frames the way its `Model` says: colour in one
//! frame or three, and the infrared in each of the ways drivers send it (`sane.InfraredWay`). It
//! keeps count of what's done to it, above all whether `sane_cancel` came while it was still
//! sending, which leaves a real V200 stuck until it's switched off.

const std = @import("std");
const builtin = @import("builtin");
const sane = @import("sane.zig");
const interface = @import("root.zig");
const image = @import("../core/image.zig");

const Word = sane.Word;
const Int = sane.Int;

/// The scan modes, sources and switch the options are named after.
const colour_mode = "Color";
const infrared_mode = "Infrared";
const rgbi_mode = "RGBI";
const flatbed_source = "Flatbed";
const film_source = "Transparency Unit";
const infrared_source = "Transparency Unit Infrared";
const infrared_switch = "infrared";

/// The longest string option value, with its 0.
const string_size = 64;
/// The most values a string option lists.
const max_strings = 4;
/// The area's corners go from 0 to this, in mm.
const bed_mm = 100;
/// How many scans' worth of starts the fake remembers the settings of.
const max_starts = 8;

/// How the made-up scanner behaves.
const Model = struct {
    /// The size every scan comes out at, whatever area is asked for.
    width: usize = 5,
    height: usize = 4,
    /// Red, green and blue as three frames, as three-pass scanners send them.
    three_pass: bool = false,
    /// How it offers an infrared pass, if it does.
    infrared: enum {
        none,
        /// A scan mode that sends four samples a pixel, like pieusb's.
        rgbi_mode,
        /// A scan mode for a grey scan of its own, like epson2's and pixma's.
        mode,
        /// A light source for a scan of its own, like genesys's.
        source,
        /// A switch that adds a fourth sample to each pixel.
        switch_fourth_sample,
        /// A switch that adds a grey frame once the colour frame has ended as the last one.
        switch_frame_after_last,
        /// A switch that adds a grey frame, with the colour frame saying another follows.
        switch_second_frame,
    } = .none,
    /// Bytes at the end of each line that aren't samples.
    padding: usize = 0,
    /// Whether it says how many lines are coming. Hand scanners and some feeders don't.
    knows_height: bool = true,
    /// The most bytes one read gives. A small odd number makes lines span reads.
    chunk: usize = 7,
    /// What the first start returns, if not success.
    start_status: sane.Status = .good,
    /// A read fails with this once so many bytes of a frame are sent.
    read_failure: ?struct { after: usize, status: sane.Status } = null,
};

const FrameKind = enum {
    rgb,
    rgbi,
    red,
    green,
    blue,
    /// A grey frame of infrared.
    infrared,

    fn samples(kind: FrameKind) usize {
        return switch (kind) {
            .rgb => 3,
            .rgbi => 4,
            .red, .green, .blue, .infrared => 1,
        };
    }

    fn format(kind: FrameKind) sane.FrameFormat {
        return switch (kind) {
            .rgb, .rgbi => .rgb,
            .red => .red,
            .green => .green,
            .blue => .blue,
            .infrared => .gray,
        };
    }

    /// Which of a pixel's four values (red, green, blue, infrared) sample `index` of this frame
    /// is.
    fn channel(kind: FrameKind, index: usize) usize {
        return switch (kind) {
            .rgb, .rgbi => index,
            .red => 0,
            .green => 1,
            .blue => 2,
            .infrared => infrared_channel,
        };
    }
};

const infrared_channel = 3;

/// The value the scanner sends for channel `c` (red, green, blue, infrared) of pixel (`x`, `y`),
/// as `Scanner.scan` should return it: every value different, and 8-bit ones widened.
fn valueAt(depth: image.Depth, x: usize, y: usize, c: usize) u16 {
    const mixed: u16 = @truncate(1 + x * 257 + y * 4099 + c * 13001);
    return switch (depth) {
        .sixteen => mixed,
        .eight => @as(u16, @as(u8, @truncate(mixed))) * image.widen_8_to_16,
    };
}

const Option = struct {
    name: [:0]const u8,
    descriptor: sane.OptionDescriptor,
    word: Word = 0,
    string: [string_size]u8 = @splat(0),
    /// A string option's values, ended by a null.
    list: [max_strings + 1]?[*:0]const u8 = @splat(null),
};

const Id = enum(usize) { count, mode, source, depth, resolution, tl_x, tl_y, br_x, br_y, infrared };

/// What the scanner was set to when a frame was started: copies, since the options change after.
const Started = struct {
    mode_text: [string_size]u8,
    source_text: [string_size]u8,
    switched_on: bool,

    fn mode(started: *const Started) []const u8 {
        return std.mem.sliceTo(&started.mode_text, 0);
    }

    fn source(started: *const Started) []const u8 {
        return std.mem.sliceTo(&started.source_text, 0);
    }
};

pub const Fake = struct {
    model: Model,
    options: [std.enums.values(Id).len]Option,
    /// How many options it has: the switch, the last one, only on models with one.
    count: Word,
    depths: [3]Word = .{ 2, 8, 16 },
    resolutions: [3]Word = .{ 2, 100, 200 },
    bed: sane.Range = .{ .min = 0, .max = bed_mm * sane.fixed_one, .quant = 0 },
    api: sane.Api = functions,

    /// The frames of the scan under way, and which one is next.
    plan: [3]FrameKind = undefined,
    planned: usize = 0,
    next_frame: usize = 0,
    /// The frame being sent, and how many of its bytes have gone.
    frame: FrameKind = .rgb,
    sent: usize = 0,
    /// Whether a frame has started and hasn't ended yet, in its last line or in an error.
    sending: bool = false,

    starts: usize = 0,
    started: [max_starts]Started = undefined,
    cancels: usize = 0,
    /// Cancels that came while a frame was being sent. There should never be one.
    cancels_while_sending: usize = 0,

    /// Sets `fake` up in place: its options point into it, so it can't move afterwards.
    fn init(fake: *Fake, model: Model) void {
        fake.* = .{ .model = model, .options = undefined, .count = undefined };
        fake.addWord(.count, "", .int, .none);
        fake.addString(.mode, "mode", switch (model.infrared) {
            .rgbi_mode => &.{ colour_mode, rgbi_mode },
            .mode => &.{ colour_mode, infrared_mode },
            else => &.{colour_mode},
        });
        fake.addString(.source, "source", if (model.infrared == .source) &.{ flatbed_source, film_source, infrared_source } else &.{ flatbed_source, film_source });
        fake.addWord(.depth, "depth", .int, .word_list);
        fake.option(.depth).descriptor.constraint = .{ .word_list = &fake.depths };
        fake.option(.depth).word = 8;
        fake.addWord(.resolution, "resolution", .int, .word_list);
        fake.option(.resolution).descriptor.constraint = .{ .word_list = &fake.resolutions };
        fake.option(.resolution).word = 100;
        for ([_]Id{ .tl_x, .tl_y, .br_x, .br_y }, [_][:0]const u8{ "tl-x", "tl-y", "br-x", "br-y" }) |id, name| {
            fake.addWord(id, name, .fixed, .range);
            fake.option(id).descriptor.constraint = .{ .range = &fake.bed };
        }
        fake.addWord(.infrared, infrared_switch, .bool, .none);
        const has_switch = switch (model.infrared) {
            .switch_fourth_sample, .switch_frame_after_last, .switch_second_frame => true,
            else => false,
        };
        fake.count = @intCast(fake.options.len - @intFromBool(!has_switch));
    }

    fn option(fake: *Fake, id: Id) *Option {
        return &fake.options[@backingInt(id)];
    }

    fn addWord(fake: *Fake, id: Id, name: [:0]const u8, kind: sane.ValueType, constraint: sane.ConstraintType) void {
        fake.option(id).* = .{ .name = name, .descriptor = .{
            .name = name.ptr,
            .title = name.ptr,
            .desc = name.ptr,
            .type = kind,
            .unit = .none,
            .size = @sizeOf(Word),
            .cap = sane.cap_soft_select,
            .constraint_type = constraint,
            .constraint = undefined,
        } };
    }

    /// Adds a string option that takes `values`, set to the first of them.
    fn addString(fake: *Fake, id: Id, name: [:0]const u8, values: []const [:0]const u8) void {
        fake.addWord(id, name, .string, .string_list);
        const added = fake.option(id);
        added.descriptor.size = string_size;
        for (values, added.list[0..values.len]) |value, *entry| entry.* = value.ptr;
        added.descriptor.constraint = .{ .string_list = &added.list };
        @memcpy(added.string[0..values[0].len], values[0]);
    }

    fn text(fake: *Fake, id: Id) []const u8 {
        return std.mem.sliceTo(&fake.option(id).string, 0);
    }

    /// The scanner, as `sane.Library.open` would return it, with no profile.
    fn scanner(fake: *Fake) sane.Scanner {
        return .{ .api = &fake.api, .handle = fake, .profile = null };
    }

    fn depth(fake: *Fake) image.Depth {
        return if (fake.option(.depth).word == 16) .sixteen else .eight;
    }

    fn lineBytes(fake: *Fake, kind: FrameKind) usize {
        return fake.model.width * kind.samples() * fake.depth().bytes() + fake.model.padding;
    }

    /// Works out the frames of a new scan from what the scanner is set to.
    fn planScan(fake: *Fake) void {
        const switched_on = fake.option(.infrared).word != 0;
        const frames: []const FrameKind = if (std.mem.eql(u8, fake.text(.mode), infrared_mode) or std.mem.eql(u8, fake.text(.source), infrared_source))
            &.{.infrared}
        else if (std.mem.eql(u8, fake.text(.mode), rgbi_mode))
            &.{.rgbi}
        else if (switched_on) switch (fake.model.infrared) {
            .switch_fourth_sample => &.{.rgbi},
            .switch_frame_after_last, .switch_second_frame => &.{ .rgb, .infrared },
            else => unreachable,
        } else if (fake.model.three_pass)
            &.{ .red, .green, .blue }
        else
            &.{.rgb};
        @memcpy(fake.plan[0..frames.len], frames);
        fake.planned = frames.len;
        fake.next_frame = 0;
    }

    /// Whether the frame being sent says it's the scan's last. A switch's grey frame can come
    /// after a colour frame that says so.
    fn lastFrame(fake: *Fake) bool {
        if (fake.next_frame == fake.planned) return true;
        return fake.model.infrared == .switch_frame_after_last and fake.frame == .rgb;
    }

    const functions: sane.Api = .{
        .init = saneInit,
        .exit = saneExit,
        .get_devices = getDevices,
        .open = open,
        .close = close,
        .get_option_descriptor = getOptionDescriptor,
        .control_option = controlOption,
        .get_parameters = getParameters,
        .start = start,
        .read = read,
        .cancel = cancel,
    };

    fn of(handle: sane.Handle) *Fake {
        return @ptrCast(@alignCast(handle));
    }

    fn saneInit(_: ?*Int, _: ?*const anyopaque) callconv(.c) sane.Status {
        return .good;
    }

    fn saneExit() callconv(.c) void {}

    fn getDevices(_: *?[*:null]const ?*const sane.RawDevice, _: sane.Bool) callconv(.c) sane.Status {
        return .unsupported;
    }

    fn open(_: [*:0]const u8, _: *?sane.Handle) callconv(.c) sane.Status {
        return .unsupported;
    }

    fn close(_: sane.Handle) callconv(.c) void {}

    fn getOptionDescriptor(handle: sane.Handle, index: Int) callconv(.c) ?*const sane.OptionDescriptor {
        const fake = of(handle);
        if (index < 0 or index >= fake.count) return null;
        return &fake.options[@intCast(index)].descriptor;
    }

    fn controlOption(handle: sane.Handle, index: Int, action: sane.Action, value: ?*anyopaque, _: ?*Int) callconv(.c) sane.Status {
        const fake = of(handle);
        if (index < 0 or index >= fake.count) return .inval;
        const chosen = &fake.options[@intCast(index)];
        const pointer = value orelse return .inval;
        if (chosen.descriptor.type == .string) {
            const bytes: *[string_size]u8 = @ptrCast(pointer);
            switch (action) {
                .get_value => bytes.* = chosen.string,
                .set_value => chosen.string = bytes.*,
                .set_auto => return .unsupported,
            }
            return .good;
        }
        const word: *Word = @ptrCast(@alignCast(pointer));
        switch (action) {
            .get_value => word.* = if (index == 0) fake.count else chosen.word,
            .set_value => chosen.word = word.*,
            .set_auto => return .unsupported,
        }
        return .good;
    }

    fn getParameters(handle: sane.Handle, parameters: *sane.Parameters) callconv(.c) sane.Status {
        const fake = of(handle);
        parameters.* = .{
            .format = fake.frame.format(),
            .last_frame = @intFromBool(fake.lastFrame()),
            .bytes_per_line = @intCast(fake.lineBytes(fake.frame)),
            .pixels_per_line = @intCast(fake.model.width),
            .lines = if (fake.model.knows_height) @intCast(fake.model.height) else -1,
            .depth = fake.depth().bits(),
        };
        return .good;
    }

    fn start(handle: sane.Handle) callconv(.c) sane.Status {
        const fake = of(handle);
        if (fake.sending) return .device_busy;
        if (fake.starts == 0 and fake.model.start_status != .good) {
            fake.starts += 1;
            return fake.model.start_status;
        }
        // After a scan's last frame, a start is the start of another scan.
        if (fake.next_frame == fake.planned) fake.planScan();
        fake.frame = fake.plan[fake.next_frame];
        fake.next_frame += 1;
        fake.sent = 0;
        fake.sending = true;
        if (fake.starts < max_starts) fake.started[fake.starts] = .{ .mode_text = fake.option(.mode).string, .source_text = fake.option(.source).string, .switched_on = fake.option(.infrared).word != 0 };
        fake.starts += 1;
        return .good;
    }

    fn read(handle: sane.Handle, data: [*]u8, max_length: Int, length: *Int) callconv(.c) sane.Status {
        const fake = of(handle);
        length.* = 0;
        if (!fake.sending) return .inval;
        if (fake.model.read_failure) |failure| if (fake.sent >= failure.after) {
            fake.sending = false;
            return failure.status;
        };
        const line_bytes = fake.lineBytes(fake.frame);
        const total = line_bytes * fake.model.height;
        if (fake.sent == total) {
            fake.sending = false;
            return .eof;
        }
        const sample_bytes = fake.depth().bytes();
        const count = @min(fake.model.chunk, @as(usize, @intCast(max_length)), total - fake.sent);
        for (data[0..count], fake.sent..) |*byte, at| {
            const in_line = at % line_bytes;
            const index = in_line / sample_bytes;
            if (index >= fake.model.width * fake.frame.samples()) {
                // Padding: something that would show if it were read as a sample.
                byte.* = 0xEE;
                continue;
            }
            const value = valueAt(fake.depth(), index / fake.frame.samples(), at / line_bytes, fake.frame.channel(index % fake.frame.samples()));
            byte.* = switch (fake.depth()) {
                .eight => @intCast(value / image.widen_8_to_16),
                .sixteen => std.mem.asBytes(&value)[in_line % sample_bytes],
            };
        }
        fake.sent += count;
        length.* = @intCast(count);
        return .good;
    }

    fn cancel(handle: sane.Handle) callconv(.c) void {
        const fake = of(handle);
        fake.cancels += 1;
        if (fake.sending) fake.cancels_while_sending += 1;
        // Back to idle: the next start is a new scan's.
        fake.sending = false;
        fake.next_frame = fake.planned;
    }

    /// Checks that `picture` is the colour the fake sends, at `depth`, and that its infrared pass
    /// is there, or not, as `with_infrared` says.
    fn expectPicture(fake: *Fake, picture: interface.Image, at_depth: image.Depth, with_infrared: bool) !void {
        try std.testing.expectEqual(at_depth, picture.depth);
        try std.testing.expectEqual(fake.model.width, picture.scan.width);
        try std.testing.expectEqual(fake.model.height, picture.scan.height);
        for (0..fake.model.height) |y| {
            for (picture.scan.row(y), 0..) |pixel, x| {
                try std.testing.expectEqual([3]u16{ valueAt(at_depth, x, y, 0), valueAt(at_depth, x, y, 1), valueAt(at_depth, x, y, 2) }, pixel);
            }
        }
        if (!with_infrared) return std.testing.expectEqual(@as(?image.Plane, null), picture.infrared);
        const plane = picture.infrared orelse return error.TestExpectedInfrared;
        try std.testing.expectEqual(fake.model.width, plane.width);
        try std.testing.expectEqual(fake.model.height, plane.height);
        for (0..fake.model.height) |y| {
            for (plane.row(y), 0..) |sample, x| try std.testing.expectEqual([1]u16{valueAt(at_depth, x, y, infrared_channel)}, sample);
        }
    }
};

/// A scan of film at the fake's lower resolution, with or without an infrared pass.
fn request(infrared: bool) interface.Request {
    return .{ .source = .transparency, .dpi = 100, .infrared = infrared };
}

test "a colour scan comes back as sent, with lines that span reads, padding and no height given" {
    const gpa = std.testing.allocator;
    var fake: Fake = undefined;
    fake.init(.{ .padding = 3, .knows_height = false });
    var scanner = fake.scanner();
    var progress: interface.Progress = .{};
    var picture = try scanner.scan(gpa, request(false), &progress);
    defer picture.deinit(gpa);
    try fake.expectPicture(picture, .sixteen, false);
    try std.testing.expectEqual(@as(u32, @intCast(fake.model.height)), progress.lines.load(.acquire));
    try std.testing.expectEqualStrings(film_source, fake.text(.source));
    try std.testing.expectEqual([2]f32{ 100, 100 }, picture.dpi);
    // One start, and one cancel once the last line is in, to put the scanner back to idle.
    try std.testing.expectEqual(@as(usize, 1), fake.starts);
    try std.testing.expectEqual(@as(usize, 1), fake.cancels);
    try std.testing.expectEqual(@as(usize, 0), fake.cancels_while_sending);
}

test "an 8-bit scan is widened to 16 bits" {
    const gpa = std.testing.allocator;
    var fake: Fake = undefined;
    fake.init(.{});
    var scanner = fake.scanner();
    var progress: interface.Progress = .{};
    var asked = request(false);
    asked.deep = false;
    var picture = try scanner.scan(gpa, asked, &progress);
    defer picture.deinit(gpa);
    try fake.expectPicture(picture, .eight, false);
    try std.testing.expectEqual(@as(u32, @intCast(fake.model.height)), progress.total.load(.acquire));
}

test "a three-pass scanner's frames make one picture" {
    const gpa = std.testing.allocator;
    var fake: Fake = undefined;
    fake.init(.{ .three_pass = true });
    var scanner = fake.scanner();
    var progress: interface.Progress = .{};
    var picture = try scanner.scan(gpa, request(false), &progress);
    defer picture.deinit(gpa);
    try fake.expectPicture(picture, .sixteen, false);
    try std.testing.expectEqual(@as(usize, 3), fake.starts);
    try std.testing.expectEqual(@as(usize, 0), fake.cancels_while_sending);
    // Its progress counts all three frames' lines.
    try std.testing.expectEqual(@as(u32, @intCast(3 * fake.model.height)), progress.total.load(.acquire));
    try std.testing.expectEqual(@as(u32, @intCast(3 * fake.model.height)), progress.lines.load(.acquire));
}

test "a scan that won't start, or stops part-way, fails without a cancel in the middle" {
    const gpa = std.testing.allocator;
    var progress: interface.Progress = .{};

    var busy: Fake = undefined;
    busy.init(.{ .start_status = .device_busy });
    var busy_scanner = busy.scanner();
    try std.testing.expectError(error.Busy, busy_scanner.scan(gpa, request(false), &progress));
    try std.testing.expectEqual(@as(usize, 0), busy.cancels_while_sending);
    // It scans the next time.
    var picture = try busy_scanner.scan(gpa, request(false), &progress);
    defer picture.deinit(gpa);
    try busy.expectPicture(picture, .sixteen, false);

    var jammed: Fake = undefined;
    jammed.init(.{ .read_failure = .{ .after = 20, .status = .jammed } });
    var jammed_scanner = jammed.scanner();
    try std.testing.expectError(error.Jammed, jammed_scanner.scan(gpa, request(false), &progress));
    // The scanner had stopped sending by then, so the cancel that puts it back to idle is safe.
    try std.testing.expectEqual(@as(usize, 1), jammed.cancels);
    try std.testing.expectEqual(@as(usize, 0), jammed.cancels_while_sending);
}

test "infrared as a fourth sample comes with the scan, from a mode or a switch" {
    const gpa = std.testing.allocator;
    var progress: interface.Progress = .{};

    var mode: Fake = undefined;
    mode.init(.{ .infrared = .rgbi_mode, .padding = 2 });
    var mode_scanner = mode.scanner();
    var from_mode = try mode_scanner.scan(gpa, request(true), &progress);
    defer from_mode.deinit(gpa);
    try mode.expectPicture(from_mode, .sixteen, true);
    try std.testing.expectEqual(@as(usize, 1), mode.starts);
    try std.testing.expectEqualStrings(rgbi_mode, mode.started[0].mode());
    try std.testing.expectEqual(@as(usize, 0), mode.cancels_while_sending);

    var switched: Fake = undefined;
    switched.init(.{ .infrared = .switch_fourth_sample });
    var switched_scanner = switched.scanner();
    var from_switch = try switched_scanner.scan(gpa, request(true), &progress);
    defer from_switch.deinit(gpa);
    try switched.expectPicture(from_switch, .sixteen, true);
    try std.testing.expectEqual(@as(usize, 1), switched.starts);
    try std.testing.expect(switched.started[0].switched_on);
    try std.testing.expectEqual(@as(usize, 0), switched.cancels_while_sending);
}

test "the infrared switch and mode go off again for a scan that doesn't ask for infrared" {
    const gpa = std.testing.allocator;
    var progress: interface.Progress = .{};
    for ([_]@FieldType(Model, "infrared"){ .switch_fourth_sample, .rgbi_mode }) |way| {
        var fake: Fake = undefined;
        fake.init(.{ .infrared = way });
        var scanner = fake.scanner();
        var with = try scanner.scan(gpa, request(true), &progress);
        defer with.deinit(gpa);
        try fake.expectPicture(with, .sixteen, true);
        // A preview, say. Read with the switch still on, its four samples a pixel would come out
        // as three, with the colours shifted along.
        var without = try scanner.scan(gpa, request(false), &progress);
        defer without.deinit(gpa);
        try fake.expectPicture(without, .sixteen, false);
        try std.testing.expectEqual(@as(usize, 2), fake.starts);
        try std.testing.expect(!fake.started[1].switched_on);
        try std.testing.expectEqualStrings(colour_mode, fake.started[1].mode());
    }
}

test "infrared as a grey frame after the colour is read as the infrared pass" {
    const gpa = std.testing.allocator;
    var progress: interface.Progress = .{};
    // The colour frame can say it's the last, or that another follows. Either way the grey frame
    // is the infrared, and there are two starts, with no cancel between them.
    for ([_]@FieldType(Model, "infrared"){ .switch_frame_after_last, .switch_second_frame }) |way| {
        var fake: Fake = undefined;
        fake.init(.{ .infrared = way });
        var scanner = fake.scanner();
        var picture = try scanner.scan(gpa, request(true), &progress);
        defer picture.deinit(gpa);
        try fake.expectPicture(picture, .sixteen, true);
        try std.testing.expectEqual(@as(usize, 2), fake.starts);
        try std.testing.expectEqual(@as(usize, 1), fake.cancels);
        try std.testing.expectEqual(@as(usize, 0), fake.cancels_while_sending);
    }
}

test "infrared in a mode or from a light of its own is a second scan, and only that" {
    const gpa = std.testing.allocator;
    var progress: interface.Progress = .{};
    for ([_]@FieldType(Model, "infrared"){ .mode, .source }) |way| {
        var fake: Fake = undefined;
        fake.init(.{ .infrared = way });
        var scanner = fake.scanner();
        var picture = try scanner.scan(gpa, request(true), &progress);
        defer picture.deinit(gpa);
        try fake.expectPicture(picture, .sixteen, true);
        // The colour scan, then the infrared one. A third start would be a scan the scanner
        // wasn't set up for, cancelled while it's sending.
        try std.testing.expectEqual(@as(usize, 2), fake.starts);
        try std.testing.expectEqual(@as(usize, 0), fake.cancels_while_sending);
        try std.testing.expectEqualStrings(colour_mode, fake.started[0].mode());
        try std.testing.expectEqualStrings(film_source, fake.started[0].source());
        switch (way) {
            .mode => try std.testing.expectEqualStrings(infrared_mode, fake.started[1].mode()),
            .source => try std.testing.expectEqualStrings(infrared_source, fake.started[1].source()),
            else => unreachable,
        }
        // The next scan is in colour from the film's own light again.
        var after = try scanner.scan(gpa, request(false), &progress);
        defer after.deinit(gpa);
        try fake.expectPicture(after, .sixteen, false);
        try std.testing.expectEqualStrings(colour_mode, fake.started[2].mode());
        try std.testing.expectEqualStrings(film_source, fake.started[2].source());
    }
}

test "a scanner with no infrared scans in colour when infrared is asked for" {
    const gpa = std.testing.allocator;
    var fake: Fake = undefined;
    fake.init(.{});
    var scanner = fake.scanner();
    var progress: interface.Progress = .{};
    var picture = try scanner.scan(gpa, request(true), &progress);
    defer picture.deinit(gpa);
    try fake.expectPicture(picture, .sixteen, false);
    try std.testing.expectEqual(@as(usize, 1), fake.starts);
    try std.testing.expectEqual(@as(usize, 0), fake.cancels_while_sending);
}
