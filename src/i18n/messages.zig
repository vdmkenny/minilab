//! The interface's messages, in English: what every translation translates. Each group is the
//! messages of one part of the app, in its own file in en/. A message's field name is its key in
//! a translation's file.

pub const Messages = struct {
    common: @import("en/common.zig").Messages = .{},
    app: @import("en/app.zig").Messages = .{},
    settings: @import("en/settings.zig").Messages = .{},
    rolls: @import("en/rolls.zig").Messages = .{},
    scan: @import("en/scan.zig").Messages = .{},
    develop: @import("en/develop.zig").Messages = .{},
    @"export": @import("en/export.zig").Messages = .{},
    looks: @import("en/looks.zig").Messages = .{},
    shortcuts: @import("en/shortcuts.zig").Messages = .{},
    update: @import("en/update.zig").Messages = .{},
    labels: @import("en/labels.zig").Messages = .{},
    gui: @import("en/gui.zig").Messages = .{},
};
