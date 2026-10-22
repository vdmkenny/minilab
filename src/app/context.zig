//! What each workspace's view gets every frame, and the things the views share: the list of
//! workspaces and the notice in the header.

const std = @import("std");
const c = @import("c");
const gui = @import("../ui/gui.zig");
const Library = @import("library.zig").Library;
const develop_view = @import("develop_view.zig");
const shortcuts = @import("shortcuts.zig");

pub const Workspace = enum {
    rolls,
    scan,
    develop,
    @"export",
    looks,

    pub fn label(workspace: Workspace) [:0]const u8 {
        return switch (workspace) {
            .rolls => "Rolls",
            .scan => "Scan",
            .develop => "Develop",
            .@"export" => "Export",
            .looks => "Looks",
        };
    }

    /// The shortcut that opens it.
    pub fn command(workspace: Workspace) shortcuts.Command {
        return switch (workspace) {
            .rolls => .rolls,
            .scan => .scan,
            .develop => .develop,
            .@"export" => .@"export",
            .looks => .looks,
        };
    }
};

/// How long a notice stays in the header.
const notice_ms = 6000;

/// A line in the header that says what just happened, for a few seconds.
pub const Notice = struct {
    line: gui.Line(256) = .{},
    until: u64 = 0,

    pub fn set(notice: *Notice, comptime format: []const u8, args: anytype) void {
        notice.line.set(format, args);
        notice.until = c.SDL_GetTicks() + notice_ms;
    }

    pub fn text(notice: *const Notice) ?[]const u8 {
        if (notice.line.len == 0 or c.SDL_GetTicks() > notice.until) return null;
        return notice.line.text();
    }
};

/// What a workspace's view gets each frame.
pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    gpu: *c.SDL_GPUDevice,
    library: *Library,
    /// Develop's state: which roll is open and which frame is selected.
    develop: *develop_view.State,
    /// The shortcuts pressed this frame.
    keys: std.EnumSet(shortcuts.Command),
    /// A line in the header that says what just happened.
    notice: *Notice,
};
