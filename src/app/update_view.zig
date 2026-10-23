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
const Worker = @import("update_worker.zig").Worker;

const update = minilab.update;

/// The window's padding, the gap between its parts, the width its text wraps at, the tallest its
/// release notes get before they scroll, and its buttons' height.
const padding_x = 20;
const padding_y = 16;
const gap = 8;
const text_width = 440;
const notes_height = 180;
const button_height = 32;

pub const State = struct {
    open: bool = false,
};

/// What the header says about an update, or null when there's nothing to say.
pub fn headerLabel(worker: ?*const Worker) ?[:0]const u8 {
    const w = worker orelse return null;
    return switch (w.phase.load(.acquire)) {
        .checking, .none => null,
        .installed => "Restarting",
        .available, .downloading, .installing, .failed => gui.print("Update {s}", .{w.release.?.version}),
    };
}

/// Draws the update window when it's open. `busy` is set while a scan or an export runs, which
/// restarting would cut short. Returns true once the update is installed, for the app to restart
/// into it.
pub fn draw(state: *State, worker: *Worker, ctx: context.Context, busy: bool) bool {
    const phase = worker.phase.load(.acquire);
    if (phase == .installed) return true;
    if (!state.open) return false;
    const release = &(worker.release orelse return false);

    if (!c.ImGui_IsPopupOpen("update", 0)) _ = c.ImGui_OpenPopup("update", 0);
    // Centred every frame: it sizes itself to what it shows, which changes as an update goes on.
    c.ImGui_SetNextWindowPosEx(c.ImGuiViewport_GetCenter(c.ImGui_GetMainViewport()), c.ImGuiCond_Always, gui.vec2(0.5, 0.5));
    c.ImGui_PushStyleVarImVec2(c.ImGuiStyleVar_WindowPadding, gui.vec2(gui.px(padding_x), gui.px(padding_y)));
    defer c.ImGui_PopStyleVar();
    if (!c.ImGui_BeginPopupModal("update", null, c.ImGuiWindowFlags_AlwaysAutoResize | c.ImGuiWindowFlags_NoTitleBar)) {
        state.open = false;
        return false;
    }
    defer c.ImGui_EndPopup();
    c.ImGui_PushTextWrapPos(c.ImGui_GetCursorPosX() + gui.px(text_width));
    defer c.ImGui_PopTextWrapPos();

    gui.title(gui.print("minilab {s}", .{release.version}), fonts.title_size);
    gui.textColored(theme.text_tertiary, gui.print("Installed {s}", .{version.string}));
    c.ImGui_Dummy(gui.vec2(0, gui.px(gap)));
    drawNotes(release.notes);
    c.ImGui_Dummy(gui.vec2(0, gui.px(gap)));

    const working = phase == .downloading or phase == .installing;
    switch (phase) {
        .downloading => gui.textColored(theme.text_secondary, gui.print("Downloading {d} of {d} MB", .{ worker.downloaded.load(.acquire) / bytes_per_mb, release.archive.size / bytes_per_mb })),
        .installing => gui.textColored(theme.text_secondary, "Installing"),
        .failed => gui.paragraph(theme.accent, gui.print("Update failed · {s}", .{failureLabel(worker.failure)})),
        else => if (!worker.writable) {
            gui.textColored(theme.text_tertiary, "Folder not writable");
        } else if (busy) {
            gui.textColored(theme.text_tertiary, "Scan or export running");
        },
    }
    if (builtin.os.tag == .macos and !worker.signed) drawUnquarantine(ctx, worker.folder);
    c.ImGui_Dummy(gui.vec2(0, gui.px(gap)));

    if (worker.writable) {
        c.ImGui_BeginDisabled(busy or working);
        if (gui.buttonOf(.primary, "Update and restart", gui.vec2(0, button_height))) worker.install();
        c.ImGui_EndDisabled();
        c.ImGui_SameLineEx(0, gui.px(gap));
        if (gui.buttonOf(.normal, "Release notes", gui.vec2(0, button_height))) openPage(release.page);
    } else if (gui.buttonOf(.primary, "Download", gui.vec2(0, button_height))) openPage(release.page);
    c.ImGui_SameLineEx(0, gui.px(gap));
    if (gui.buttonOf(.normal, if (working) "Hide" else "Later", gui.vec2(0, button_height)) or c.ImGui_IsKeyPressed(c.ImGuiKey_Escape)) {
        state.open = false;
        c.ImGui_CloseCurrentPopup();
    }
    return false;
}

const bytes_per_mb = 1_000_000;

/// The release notes: headings, and each change after a dot. They scroll when there are many.
fn drawNotes(notes: []const update.Note) void {
    const width = gui.px(text_width);
    c.ImGui_SetNextWindowSizeConstraints(gui.vec2(width, 0), gui.vec2(width, gui.px(notes_height)), null, null);
    _ = c.ImGui_BeginChild("notes", gui.vec2(width, 0), c.ImGuiChildFlags_AutoResizeY, 0);
    defer c.ImGui_EndChild();
    for (notes) |note| switch (note.kind) {
        .heading => gui.textColored(theme.text_secondary, note.text),
        .change => gui.paragraph(theme.text, gui.print("· {s}", .{note.text})),
    };
}

/// The command that lets an unsigned build through macOS's quarantine, with a button to copy it.
fn drawUnquarantine(ctx: context.Context, folder: []const u8) void {
    const command = gui.print("xattr -dr com.apple.quarantine \"{s}\"", .{folder});
    gui.textColored(theme.text_secondary, "If macOS won't open it");
    fonts.pushSized(.mono, fonts.small_size);
    gui.paragraph(theme.text_tertiary, command);
    fonts.pop();
    if (gui.buttonOf(.normal, "Copy", gui.vec2(0, 0))) {
        _ = c.SDL_SetClipboardText(command);
        ctx.notice.set("Copied", .{});
    }
    if (c.ImGui_IsItemHovered(0)) c.ImGui_SetTooltip("For Terminal");
}

fn openPage(url: []const u8) void {
    const page = gui.print("{s}", .{url});
    if (!c.SDL_OpenURL(page)) std.log.err("can't open {s}: {s}", .{ url, c.SDL_GetError() });
}

/// Why an update failed, in a few words.
fn failureLabel(failure: ?anyerror) []const u8 {
    const err = failure orelse return "unknown";
    return switch (err) {
        error.Offline, error.BadStatus => "no connection to GitHub",
        error.ChecksumMissing, error.ChecksumMismatch => "checksum doesn't match",
        error.Malformed, error.Unsupported, error.NotForThisFile, error.BadSignature, error.UntrustedCertificate, error.WrongSigner, error.NotInLog => "attestation doesn't verify",
        error.NotWritable, error.AccessDenied, error.PermissionDenied => "can't write to minilab's folder",
        error.NotABuild, error.BadArchive => "download isn't a minilab build",
        error.TooLarge => "download too large",
        error.Cancelled => "cancelled",
        else => @errorName(err),
    };
}
