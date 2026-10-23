//! Moves files and folders to the system's Trash, so a deleted roll can still be put back:
//!
//! - macOS: NSFileManager's `trashItemAtURL`, the same as the Finder's Move to Trash, so Put Back
//!   works. It also handles folders on other disks, which have Trash folders of their own.
//! - Linux and the other Unix systems: the freedesktop.org Trash in the home folder
//!   (~/.local/share/Trash), which file managers show and can restore from.
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
        var operation: FileOperation = .{ .function = delete, .from = list.ptr, .flags = allow_undo | no_confirmation | silent | no_error_ui };
        if (SHFileOperationW(&operation) != 0 or operation.aborted != 0) return error.TrashFailed;
    }
};

const freedesktop = struct {
    /// Moves `path` into the Trash's files folder under a name no other trashed item has, and
    /// writes the info file that says where it came from and when, so it can be restored.
    fn move(gpa: std.mem.Allocator, io: std.Io, path: []const u8, home: []const u8) Error!void {
        const cwd = std.Io.Dir.cwd();
        const trash = std.fs.path.join(gpa, &.{ home, ".local", "share", "Trash" }) catch return error.OutOfMemory;
        defer gpa.free(trash);
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
            const text = infoFile(gpa, path, std.Io.Clock.real.now(io)) catch return error.OutOfMemory;
            defer gpa.free(text);
            cwd.writeFile(io, .{ .sub_path = info_path, .data = text }) catch return error.TrashFailed;
            cwd.rename(path, cwd, target, io) catch {
                cwd.deleteFile(io, info_path) catch {};
                return error.TrashFailed;
            };
            return;
        }
        return error.TrashFailed;
    }

    /// How many names to try before giving up.
    const max_tries = 1000;

    /// The `.trashinfo` file for `path` trashed at `now`: its path with anything but plain
    /// characters percent-encoded, and the time, in UTC.
    fn infoFile(gpa: std.mem.Allocator, path: []const u8, now: std.Io.Timestamp) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        const w = &out.writer;
        try w.writeAll("[Trash Info]\nPath=");
        for (path) |byte| {
            if (std.ascii.isAlphanumeric(byte) or std.mem.indexOfScalar(u8, "/-_.~", byte) != null) {
                try w.writeByte(byte);
            } else try w.print("%{X:0>2}", .{byte});
        }
        const seconds: u64 = @intCast(@max(0, @divFloor(now.nanoseconds, std.time.ns_per_s)));
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
    const text = try freedesktop.infoFile(gpa, "/home/kenny/Pictures/Rolls/Roll 002 & co", .{ .nanoseconds = 1_792_735_200 * std.time.ns_per_s });
    defer gpa.free(text);
    try std.testing.expectEqualStrings("[Trash Info]\nPath=/home/kenny/Pictures/Rolls/Roll%20002%20%26%20co\nDeletionDate=2026-10-23T06:00:00\n", text);
}

test "a folder in a freedesktop Trash gets a name of its own, and its info" {
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
        try freedesktop.move(gpa, io, roll, home);
    }
    try tmp.dir.access(io, ".local/share/Trash/files/Roll 1/frames", .{});
    try tmp.dir.access(io, ".local/share/Trash/files/Roll 1.2/frames", .{});
    try tmp.dir.access(io, ".local/share/Trash/info/Roll 1.2.trashinfo", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "Rolls/Roll 1", .{}));
}
