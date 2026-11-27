//! Moves files and folders to the system's Trash, so a deleted roll can still be put back:
//!
//! - macOS: NSFileManager's `trashItemAtURL`, the same as the Finder's Move to Trash, so Put Back
//!   works. It also handles folders on other disks, which have Trash folders of their own.
//! - Linux and the other Unix systems: the freedesktop.org Trash in the user's data folder
//!   (~/.local/share/Trash), which file managers show and can restore from. On Linux, something
//!   on another disk goes to that disk's own Trash (`.Trash-<user id>` at its top).
//! - Windows: the Recycle Bin, through the shell's `SHFileOperationW`.

const std = @import("std");
const builtin = @import("builtin");

pub const Error = error{ OutOfMemory, TrashFailed, NoHomeFolder, NameTooLong };

/// Moves the file or folder at `path` (absolute) to the Trash. `home` is the user's home folder,
/// which the freedesktop Trash lives in.
pub fn move(gpa: std.mem.Allocator, io: std.Io, path: []const u8, home: ?[]const u8) Error!void {
    switch (builtin.os.tag) {
        .macos => return macos.move(gpa, path),
        .windows => return windows.move(gpa, path),
        else => return freedesktop.move(gpa, io, path, home orelse return error.NoHomeFolder),
    }
}

const macos = struct {
    const Id = ?*anyopaque;
    const Sel = ?*anyopaque;

    extern "objc" fn objc_getClass(name: [*:0]const u8) Id;
    extern "objc" fn sel_registerName(name: [*:0]const u8) Sel;
    extern "objc" fn objc_msgSend() void;
    extern "objc" fn objc_autoreleasePoolPush() ?*anyopaque;
    extern "objc" fn objc_autoreleasePoolPop(pool: ?*anyopaque) void;

    /// `objc_msgSend` as a function of the given type: each message's arguments and result.
    fn send(comptime Function: type) *const Function {
        return @ptrCast(&objc_msgSend);
    }

    fn move(gpa: std.mem.Allocator, path: []const u8) Error!void {
        const terminated = try gpa.dupeSentinel(u8, path, 0);
        defer gpa.free(terminated);
        const pool = objc_autoreleasePoolPush();
        defer objc_autoreleasePoolPop(pool);
        // [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]]
        const string = send(fn (Id, Sel, [*:0]const u8) callconv(.c) Id)(objc_getClass("NSString"), sel_registerName("stringWithUTF8String:"), terminated);
        const url = send(fn (Id, Sel, Id) callconv(.c) Id)(objc_getClass("NSURL"), sel_registerName("fileURLWithPath:"), string);
        // [[NSFileManager defaultManager] trashItemAtURL:url resultingItemURL:nil error:nil]
        const manager = send(fn (Id, Sel) callconv(.c) Id)(objc_getClass("NSFileManager"), sel_registerName("defaultManager"));
        // BOOL is a signed char on Intel Macs and a bool on Apple silicon: either way, 0 is NO.
        const done = send(fn (Id, Sel, Id, ?*Id, ?*Id) callconv(.c) i8)(manager, sel_registerName("trashItemAtURL:resultingItemURL:error:"), url, null, null);
        if (done == 0) return error.TrashFailed;
    }
};

const windows = struct {
    /// The shell's SHFILEOPSTRUCTW, laid out naturally as it is on 64-bit Windows.
    const FileOperation = extern struct {
        window: ?*anyopaque = null,
        function: u32,
        from: [*]const u16,
        to: ?[*]const u16 = null,
        flags: u16,
        aborted: i32 = 0,
        name_mappings: ?*anyopaque = null,
        progress_title: ?[*:0]const u16 = null,
    };
    const delete = 3;
    const allow_undo = 0x40;
    const no_confirmation = 0x10;
    const silent = 0x4;
    const no_error_ui = 0x400;
    /// Asks before deleting for good something the Recycle Bin can't take (it's too big, on a
    /// network drive, or the bin is off). Without it the shell deletes it without a word.
    const want_nuke_warning = 0x4000;

    extern "shell32" fn SHFileOperationW(operation: *FileOperation) callconv(.winapi) c_int;

    fn move(gpa: std.mem.Allocator, path: []const u8) Error!void {
        const wide = std.unicode.utf8ToUtf16LeAlloc(gpa, path) catch return error.TrashFailed;
        defer gpa.free(wide);
        // The shell takes a list of paths, each ended by a 0, with one more 0 after the last.
        const list = try gpa.alloc(u16, wide.len + 2);
        defer gpa.free(list);
        @memcpy(list[0..wide.len], wide);
        list[wide.len] = 0;
        list[wide.len + 1] = 0;
        var operation: FileOperation = .{ .function = delete, .from = list.ptr, .flags = allow_undo | no_confirmation | silent | no_error_ui | want_nuke_warning };
        if (SHFileOperationW(&operation) != 0 or operation.aborted != 0) return error.TrashFailed;
    }
};

const freedesktop = struct {
    /// Moves `path` to the Trash in the user's data folder, or, when it's on another disk, to that
    /// disk's own Trash. A folder can't be renamed from one disk to another, and copying a roll's
    /// scans across to delete them would take minutes.
    fn move(gpa: std.mem.Allocator, io: std.Io, path: []const u8, home: []const u8) Error!void {
        return moveWith(gpa, io, path, home, if (std.c.getenv("XDG_DATA_HOME")) |value| std.mem.span(value) else null);
    }

    /// `move`, with `data_home` as the `XDG_DATA_HOME` variable's value.
    fn moveWith(gpa: std.mem.Allocator, io: std.Io, path: []const u8, home: []const u8, data_home: ?[]const u8) Error!void {
        const offset = localOffset(std.Io.Clock.real.now(io));
        const data = dataFolder(gpa, home, data_home) catch return error.OutOfMemory;
        defer gpa.free(data);
        const home_trash = std.fs.path.join(gpa, &.{ data, "Trash" }) catch return error.OutOfMemory;
        defer gpa.free(home_trash);
        if (moveInto(gpa, io, path, home_trash, path, offset)) |_| return else |err| switch (err) {
            error.OtherDisk => {},
            else => |e| return e,
        }

        // The path's own disk, from the system's list of where each disk is mounted. Only Linux
        // has that list as a file.
        const mounts = std.Io.Dir.cwd().readFileAlloc(io, mounts_file, gpa, .limited(max_mounts_bytes)) catch return error.TrashFailed;
        defer gpa.free(mounts);
        const top = mountPointOf(gpa, mounts, path) catch return error.OutOfMemory;
        defer if (top) |t| gpa.free(t);
        const disk = top orelse return error.TrashFailed;
        const folder = std.fmt.allocPrint(gpa, ".Trash-{d}", .{std.c.getuid()}) catch return error.OutOfMemory;
        defer gpa.free(folder);
        const disk_trash = std.fs.path.join(gpa, &.{ disk, folder }) catch return error.OutOfMemory;
        defer gpa.free(disk_trash);
        // In a disk's own Trash, the info file gives the path from the top of that disk.
        const from_top = std.mem.trimStart(u8, path[disk.len..], "/");
        moveInto(gpa, io, path, disk_trash, from_top, offset) catch |err| switch (err) {
            error.OtherDisk => return error.TrashFailed,
            else => |e| return e,
        };
    }

    /// Where the system lists its mounted disks.
    const mounts_file = "/proc/mounts";
    const max_mounts_bytes = 1 << 20;

    /// The user's data folder: `data_home` (the `XDG_DATA_HOME` variable) when it's set to a full
    /// path, as the specification asks, and otherwise `.local/share` in `home`.
    fn dataFolder(gpa: std.mem.Allocator, home: []const u8, data_home: ?[]const u8) ![]u8 {
        if (data_home) |folder| if (std.fs.path.isAbsolute(folder)) return gpa.dupe(u8, folder);
        return std.fs.path.join(gpa, &.{ home, ".local", "share" });
    }

    /// The folder the disk holding `path` is mounted at: the longest mount point in `mounts` (the
    /// text of /proc/mounts) that `path` is in. Null if there's none. The caller frees it.
    fn mountPointOf(gpa: std.mem.Allocator, mounts: []const u8, path: []const u8) !?[]u8 {
        var best: ?[]u8 = null;
        errdefer if (best) |b| gpa.free(b);
        var lines = std.mem.tokenizeScalar(u8, mounts, '\n');
        while (lines.next()) |line| {
            // Each line is the device, where it's mounted, and more we don't need.
            var fields = std.mem.tokenizeScalar(u8, line, ' ');
            _ = fields.next() orelse continue;
            const point = try unescaped(gpa, fields.next() orelse continue);
            const inside = std.mem.eql(u8, point, "/") or std.mem.eql(u8, path, point) or
                (std.mem.startsWith(u8, path, point) and path[point.len] == '/');
            if (inside and (best == null or point.len > best.?.len)) {
                if (best) |b| gpa.free(b);
                best = point;
            } else gpa.free(point);
        }
        return best;
    }

    /// A mount point as /proc/mounts writes it, with its escapes undone: a space, a tab, a new
    /// line and a backslash are written as a backslash and three octal digits.
    fn unescaped(gpa: std.mem.Allocator, text: []const u8) ![]u8 {
        const out = try gpa.alloc(u8, text.len);
        var length: usize = 0;
        var i: usize = 0;
        while (i < text.len) : (length += 1) {
            const digits = if (text[i] == '\\' and i + octal_digits < text.len) text[i + 1 ..][0..octal_digits] else "";
            if (std.fmt.parseInt(u8, digits, 8)) |byte| {
                out[length] = byte;
                i += 1 + octal_digits;
            } else |_| {
                out[length] = text[i];
                i += 1;
            }
        }
        return gpa.realloc(out, length);
    }

    const octal_digits = 3;

    /// Moves `path` into the files folder of the Trash at `trash`, under a name no other trashed
    /// item has, and writes the info file that says where it came from (`shown`) and when, so it
    /// can be restored. `error.OtherDisk` means `trash` is on another disk than `path`, and
    /// nothing was changed.
    fn moveInto(gpa: std.mem.Allocator, io: std.Io, path: []const u8, trash: []const u8, shown: []const u8, offset: i64) (Error || error{OtherDisk})!void {
        const cwd = std.Io.Dir.cwd();
        const files = std.fs.path.join(gpa, &.{ trash, "files" }) catch return error.OutOfMemory;
        defer gpa.free(files);
        const info = std.fs.path.join(gpa, &.{ trash, "info" }) catch return error.OutOfMemory;
        defer gpa.free(info);
        cwd.createDirPath(io, files) catch return error.TrashFailed;
        cwd.createDirPath(io, info) catch return error.TrashFailed;

        const base = std.fs.path.basename(path);
        var number: usize = 1;
        while (number < max_tries) : (number += 1) {
            const name = if (number == 1) gpa.dupe(u8, base) catch return error.OutOfMemory else std.fmt.allocPrint(gpa, "{s}.{d}", .{ base, number }) catch return error.OutOfMemory;
            defer gpa.free(name);
            const info_name = std.fmt.allocPrint(gpa, "{s}.trashinfo", .{name}) catch return error.OutOfMemory;
            defer gpa.free(info_name);
            const info_path = std.fs.path.join(gpa, &.{ info, info_name }) catch return error.OutOfMemory;
            defer gpa.free(info_path);
            const target = std.fs.path.join(gpa, &.{ files, name }) catch return error.OutOfMemory;
            defer gpa.free(target);
            // Taken already, by another trashed item of the same name.
            if (cwd.access(io, info_path, .{})) |_| continue else |_| {}
            if (cwd.access(io, target, .{})) |_| continue else |_| {}
            const text = infoFile(gpa, shown, std.Io.Clock.real.now(io), offset) catch return error.OutOfMemory;
            defer gpa.free(text);
            cwd.writeFile(io, .{ .sub_path = info_path, .data = text }) catch return error.TrashFailed;
            cwd.rename(path, cwd, target, io) catch |err| {
                cwd.deleteFile(io, info_path) catch {};
                return if (err == error.CrossDevice) error.OtherDisk else error.TrashFailed;
            };
            return;
        }
        return error.TrashFailed;
    }

    /// How many names to try before giving up.
    const max_tries = 1000;

    /// The C library's broken-down time, as Linux, the BSDs and macOS lay it out.
    const Tm = extern struct {
        sec: c_int,
        min: c_int,
        hour: c_int,
        mday: c_int,
        mon: c_int,
        year: c_int,
        wday: c_int,
        yday: c_int,
        isdst: c_int,
        /// Seconds east of UTC.
        gmtoff: c_long,
        zone: ?[*:0]const u8,
    };
    extern "c" fn localtime_r(time: *const c_long, result: *Tm) ?*Tm;

    /// How far the user's clock is ahead of UTC at `now`, in seconds, or 0 if the system won't
    /// say.
    fn localOffset(now: std.Io.Timestamp) i64 {
        const seconds: c_long = @intCast(@divFloor(now.nanoseconds, std.time.ns_per_s));
        var local: Tm = undefined;
        return if (localtime_r(&seconds, &local)) |_| local.gmtoff else 0;
    }

    /// The `.trashinfo` file for an item from `path`, trashed at `now`: its path with anything but
    /// plain characters percent-encoded, and the time on the user's own clock, which is `offset`
    /// seconds ahead of UTC, as the specification asks.
    fn infoFile(gpa: std.mem.Allocator, path: []const u8, now: std.Io.Timestamp, offset: i64) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("[Trash Info]\nPath=");
        for (path) |byte| {
            if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-_.~", byte) != null) {
                try w.writeByte(byte);
            } else try w.print("%{X:0>2}", .{byte});
        }
        const seconds: u64 = @intCast(@max(0, @divFloor(now.nanoseconds, std.time.ns_per_s) + offset));
        const epoch: std.time.epoch.EpochSeconds = .{ .secs = seconds };
        const day = epoch.getEpochDay().calculateYearDay();
        const month = day.calculateMonthDay();
        const time = epoch.getDaySeconds();
        try w.print("\nDeletionDate={d}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}\n", .{ day.year, month.month.numeric(), month.day_index + 1, time.getHoursIntoDay(), time.getMinutesIntoHour(), time.getSecondsIntoMinute() });
        return out.toOwnedSlice();
    }
};

test "a freedesktop info file has the path encoded and the time" {
    const gpa = std.testing.allocator;
    // 2026-10-23 06:00:00 UTC.
    const now: std.Io.Timestamp = .{ .nanoseconds = 1_792_735_200 * std.time.ns_per_s };
    const text = try freedesktop.infoFile(gpa, "/home/kenny/Pictures/Rolls/Roll 002 & co", now, 0);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("[Trash Info]\nPath=/home/kenny/Pictures/Rolls/Roll%20002%20%26%20co\nDeletionDate=2026-10-23T06:00:00\n", text);
    // On a clock two hours ahead of UTC, and one five hours behind, which is still the day before.
    const ahead = try freedesktop.infoFile(gpa, "Rolls/Roll 1", now, 2 * std.time.s_per_hour);
    defer gpa.free(ahead);
    try std.testing.expectEqualStrings("[Trash Info]\nPath=Rolls/Roll%201\nDeletionDate=2026-10-23T08:00:00\n", ahead);
    const behind = try freedesktop.infoFile(gpa, "x", .{ .nanoseconds = (1_792_735_200 - 4 * std.time.s_per_hour) * std.time.ns_per_s }, -5 * std.time.s_per_hour);
    defer gpa.free(behind);
    try std.testing.expectEqualStrings("[Trash Info]\nPath=x\nDeletionDate=2026-10-22T21:00:00\n", behind);
}

test "the Trash is in the data folder the user chose, when it's a full path" {
    const gpa = std.testing.allocator;
    for ([_]struct { ?[]const u8, []const u8 }{
        .{ null, "/home/kenny/.local/share" },
        .{ "/data/kenny", "/data/kenny" },
        // The specification says to ignore one that isn't a full path.
        .{ "share", "/home/kenny/.local/share" },
    }) |case| {
        const folder = try freedesktop.dataFolder(gpa, "/home/kenny", case[0]);
        defer gpa.free(folder);
        try std.testing.expectEqualStrings(case[1], folder);
    }
}

test "a path's disk is the longest mount point it's in" {
    const gpa = std.testing.allocator;
    const mounts =
        \\/dev/sda2 / ext4 rw,relatime 0 0
        \\proc /proc proc rw 0 0
        \\/dev/sdb1 /mnt/photos ext4 rw 0 0
        \\/dev/sdc1 /mnt/photos/My\040Scans exfat rw 0 0
        \\
    ;
    for ([_]struct { []const u8, []const u8 }{
        .{ "/home/kenny/Rolls/Roll 1", "/" },
        .{ "/mnt/photos/Rolls/Roll 1", "/mnt/photos" },
        .{ "/mnt/photos/My Scans/Rolls/Roll 1", "/mnt/photos/My Scans" },
        // A folder whose name only starts like a mount point isn't on that disk.
        .{ "/mnt/photos2/Roll 1", "/" },
    }) |case| {
        const point = (try freedesktop.mountPointOf(gpa, mounts, case[0])).?;
        defer gpa.free(point);
        try std.testing.expectEqualStrings(case[1], point);
    }
    try std.testing.expectEqual(@as(?[]u8, null), try freedesktop.mountPointOf(gpa, "", "/home"));
}

test "the clock's lead on UTC is within a day" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const offset = freedesktop.localOffset(.{ .nanoseconds = 1_792_735_200 * std.time.ns_per_s });
    try std.testing.expect(@abs(offset) <= std.time.s_per_day);
}

test "a folder in a freedesktop Trash gets a name of its own, and its info" {
    // It asks the C library for the user's id and the local time, which Windows' doesn't have.
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(home);
    for (0..2) |_| {
        try tmp.dir.createDirPath(io, "Rolls/Roll 1/frames");
        const roll = try std.fs.path.join(gpa, &.{ home, "Rolls", "Roll 1" });
        defer gpa.free(roll);
        try freedesktop.moveWith(gpa, io, roll, home, null);
    }
    try tmp.dir.access(io, ".local/share/Trash/files/Roll 1/frames", .{});
    try tmp.dir.access(io, ".local/share/Trash/files/Roll 1.2/frames", .{});
    try tmp.dir.access(io, ".local/share/Trash/info/Roll 1.2.trashinfo", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "Rolls/Roll 1", .{}));
}
