//! The system's open-file and open-folder dialogs, through SDL.

const std = @import("std");
const c = @import("c");

/// What "Import .cube" offers, in Develop and Looks.
pub const cube_files = [_]c.SDL_DialogFileFilter{
    .{ .name = "LUTs (.cube)", .pattern = "cube" },
};

/// The system's dialog, which answers on its own time, maybe on another thread.
pub const Dialog = struct {
    kind: Kind = .file,
    /// The kinds of file offered, for a file dialog. SDL keeps the pointer while the dialog is up.
    filters: []const c.SDL_DialogFileFilter = &.{},
    /// Whether more than one can be chosen.
    many: bool = false,
    mutex: std.Io.Mutex = .init,
    /// The paths chosen, waiting to be taken on the page's thread.
    chosen: std.ArrayList([]u8) = .empty,
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    showing: std.atomic.Value(bool) = .init(false),

    pub const Kind = enum { file, folder };

    pub fn show(dialog: *Dialog, gpa: std.mem.Allocator, io: std.Io) void {
        dialog.showAt(gpa, io, null);
    }

    /// Shows the dialog starting at `start`, a folder or a file. SDL copies it.
    pub fn showAt(dialog: *Dialog, gpa: std.mem.Allocator, io: std.Io, start: ?[:0]const u8) void {
        if (dialog.isShowing()) return;
        dialog.gpa = gpa;
        dialog.io = io;
        dialog.showing.store(true, .release);
        const window = c.SDL_GetKeyboardFocus();
        const location: [*c]const u8 = if (start) |s| s.ptr else null;
        switch (dialog.kind) {
            .file => c.SDL_ShowOpenFileDialog(answered, dialog, window, dialog.filters.ptr, @intCast(dialog.filters.len), location, dialog.many),
            .folder => c.SDL_ShowOpenFolderDialog(answered, dialog, window, location, dialog.many),
        }
    }

    pub fn isShowing(dialog: *const Dialog) bool {
        return dialog.showing.load(.acquire);
    }

    fn answered(userdata: ?*anyopaque, list: [*c]const [*c]const u8, filter: c_int) callconv(.c) void {
        _ = filter;
        const dialog: *Dialog = @ptrCast(@alignCast(userdata));
        defer dialog.showing.store(false, .release);
        // A null list is an error, an empty one a cancel.
        if (list == null) {
            std.log.err("the file dialog failed: {s}", .{c.SDL_GetError()});
            return;
        }
        dialog.mutex.lockUncancelable(dialog.io);
        defer dialog.mutex.unlock(dialog.io);
        var i: usize = 0;
        while (list[i] != null) : (i += 1) {
            const path = dialog.gpa.dupe(u8, std.mem.span(list[i])) catch continue;
            dialog.chosen.append(dialog.gpa, path) catch dialog.gpa.free(path);
        }
    }

    /// The paths chosen since the last time, which the caller frees with `free`.
    pub fn take(dialog: *Dialog, gpa: std.mem.Allocator, io: std.Io) [][]u8 {
        dialog.mutex.lockUncancelable(io);
        defer dialog.mutex.unlock(io);
        return dialog.chosen.toOwnedSlice(gpa) catch &.{};
    }

    /// Frees what `take` returned.
    pub fn free(gpa: std.mem.Allocator, paths: [][]u8) void {
        for (paths) |p| gpa.free(p);
        gpa.free(paths);
    }

    pub fn deinit(dialog: *Dialog, gpa: std.mem.Allocator) void {
        for (dialog.chosen.items) |p| gpa.free(p);
        dialog.chosen.deinit(gpa);
    }
};
