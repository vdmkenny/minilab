//! The update notice in the header, and the window that shows what's new and installs it.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const version = @import("../version.zig");
const context = @import("context.zig");
const labels = @import("labels.zig");
const i18n = @import("../i18n/i18n.zig");
const Worker = @import("update_worker.zig").Worker;

const update = minilab.update;

/// The width the window's text wraps at, and the tallest its release notes get before they
/// scroll, in the design's pixels.
const text_width = 440;
const notes_height = 180;

pub const State = struct {
    open: bool = false,
};

/// What the header says about an update, or null when there's nothing to say.
pub fn headerLabel(worker: ?*const Worker) ?[:0]const u8 {
    const w = worker orelse return null;
    return switch (w.phase.load(.acquire)) {
        .checking, .none => null,
        .installed => i18n.t.update.restarting,
        .available, .downloading, .installing, .failed => gui.say(i18n.t.update.update_available, .{w.release.?.version}),
    };
}

/// Draws the update window when it's open. `busy` is set while a scan or an export runs, which
/// restarting would cut short. Returns true once the update is installed, for the app to restart
/// into it.
pub fn draw(state: *State, worker: *Worker, ctx: context.Context, busy: bool) bool {
    const phase = worker.phase.load(.acquire);
    if (phase == .installed) return true;
    if (!state.open) return false;
    const release = if (worker.release) |*r| r else return false;
    if (!gui.beginDialog("update")) {
        state.open = false;
        return false;
    }
    defer c.ImGui_EndPopup();
    c.ImGui_PushTextWrapPos(c.ImGui_GetCursorPosX() + gui.px(text_width));
    defer c.ImGui_PopTextWrapPos();

    const says = &i18n.t.update;
    gui.title(gui.print("minilab {s}", .{release.version}), fonts.title_size);
    gui.textColored(theme.colors.text_tertiary, gui.say(says.installed, .{version.string}));
    gap();
    drawNotes(release.notes);
    gap();

    const working = phase == .downloading or phase == .installing;
    switch (phase) {
        .downloading => gui.textColored(theme.colors.text_secondary, gui.say(says.downloading, .{ labels.megabytes(worker.downloaded.load(.acquire)), labels.megabytes(release.archive.size) })),
        .installing => gui.textColored(theme.colors.text_secondary, says.installing),
        .failed => gui.paragraph(theme.colors.accent, gui.say(says.failed, .{failureLabel(worker.failure)})),
        else => if (!worker.writable) {
            gui.textColored(theme.colors.text_tertiary, says.folder_not_writable);
        } else if (busy) {
            gui.textColored(theme.colors.text_tertiary, says.busy);
        },
    }
    if (builtin.os.tag == .macos and !worker.signed) drawUnquarantine(ctx, worker.folder);
    gap();

    const button = gui.vec2(0, gui.button_height);
    if (worker.writable) {
        c.ImGui_BeginDisabled(busy or working);
        if (gui.buttonOf(.primary, says.update_and_restart, button)) worker.install();
        c.ImGui_EndDisabled();
        c.ImGui_SameLineEx(0, gui.px(gui.dialog.gap));
        if (gui.buttonOf(.normal, says.release_notes, button)) gui.openUrl(release.page);
    } else if (gui.buttonOf(.primary, says.download, button)) gui.openUrl(release.page);
    c.ImGui_SameLineEx(0, gui.px(gui.dialog.gap));
    if (gui.buttonOf(.normal, if (working) says.hide else says.later, button) or c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
        state.open = false;
        c.ImGui_CloseCurrentPopup();
    }
    return false;
}

fn gap() void {
    c.ImGui_Dummy(gui.vec2(0, gui.px(gui.dialog.gap)));
}

/// The release notes: headings, and each change after a dot. They scroll when there are many.
fn drawNotes(notes: []const update.Note) void {
    const width = gui.px(text_width);
    c.ImGui_SetNextWindowSizeConstraints(gui.vec2(width, 0), gui.vec2(width, gui.px(notes_height)), null, null);
    _ = c.ImGui_BeginChild("notes", gui.vec2(width, 0), c.ImGuiChildFlags_AutoResizeY, 0);
    defer c.ImGui_EndChild();
    for (notes) |note| switch (note.kind) {
        .heading => gui.textColored(theme.colors.text_secondary, note.text),
        .change => gui.paragraph(theme.colors.text, gui.print("· {s}", .{note.text})),
    };
}

/// The command that lets an unsigned build through macOS's quarantine, with a button to copy it.
fn drawUnquarantine(ctx: context.Context, folder: []const u8) void {
    const command = gui.print("xattr -dr com.apple.quarantine \"{s}\"", .{folder});
    gui.textColored(theme.colors.text_secondary, i18n.t.update.gatekeeper);
    fonts.pushSized(.mono, fonts.small_size);
    gui.paragraph(theme.colors.text_tertiary, command);
    fonts.pop();
    context.copyButton(ctx.notice, command);
}

/// Why an update failed, in a few words.
fn failureLabel(failure: ?anyerror) []const u8 {
    const says = &i18n.t.update.failure;
    const err = failure orelse return says.unknown;
    if (err == error.OutOfMemory) return says.out_of_memory;
    if (inSet(update.sigstore.Error, err)) return says.attestation;
    return switch (err) {
        error.Offline, error.BadStatus => says.offline,
        error.ChecksumMissing, error.ChecksumMismatch => says.checksum,
        error.NotWritable, error.AccessDenied, error.PermissionDenied => says.not_writable,
        error.NotABuild, error.BadArchive => says.not_a_build,
        error.TooLarge => says.too_large,
        error.Cancelled => says.cancelled,
        else => @errorName(err),
    };
}

/// Whether `err` is one of the errors in `Set`.
fn inSet(comptime Set: type, err: anyerror) bool {
    inline for (@typeInfo(Set).error_set.error_names.?) |name| {
        if (err == @field(anyerror, name)) return true;
    }
    return false;
}

test "failures get a few words each" {
    try std.testing.expectEqualStrings("attestation doesn't verify", failureLabel(error.WrongSigner));
    try std.testing.expectEqualStrings("checksum doesn't match", failureLabel(error.ChecksumMismatch));
    try std.testing.expectEqualStrings("out of memory", failureLabel(error.OutOfMemory));
    try std.testing.expectEqualStrings("unknown", failureLabel(null));
}
