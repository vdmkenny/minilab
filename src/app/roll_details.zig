//! The boxes for a roll's details: its camera, lens, date shot, copyright and notes. New roll,
//! the Rolls page's details panel and Export's Metadata all use them, so a detail is filled in
//! the same way everywhere.

const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const Library = @import("library.zig").Library;
const clock = @import("../platform/clock.zig");

const roll = minilab.roll;
const Detail = roll.Detail;

/// The longest detail a box holds. One that's longer, edited by hand, is shown cut short and
/// can't be edited here (`showCut`).
pub const capacity = 1024;

pub fn label(which: Detail) [:0]const u8 {
    return switch (which) {
        .camera => "Camera",
        .lens => "Lens",
        .shot => "Date shot",
        .copyright => "Copyright",
        .notes => "Notes",
    };
}

/// The field for `which`: the camera, lens and copyright suggest what the library's other rolls
/// have, the date shot has a calendar, and the notes are plain text. `width` is in the design's
/// pixels, and 0 fills the row.
pub fn field(which: Detail, buffer: anytype, hint: [:0]const u8, width: f32, library: *const Library, io: std.Io) gui.TextEdit {
    return switch (which) {
        .camera, .lens, .copyright => gui.suggestField(@tagName(which), buffer, hint, width, library.suggestions(which)),
        .shot => gui.dateField(@tagName(which), buffer, hint, width, clock.today(io)),
        .notes => notes: {
            _ = gui.textField(@tagName(which), buffer, hint, width);
            break :notes .ofLastItem();
        },
    };
}

/// A roll's details, each in its box. A box shows the roll's value, except while you're typing
/// in it, and saves it to the roll when you leave it or pick a suggestion.
pub const Boxes = struct {
    text: std.EnumArray(Detail, [capacity:0]u8) = .initFill(@splat(0)),
    /// The box being typed in, if any.
    editing: ?Detail = null,

    /// Draws `which`'s box for roll `r` at the cursor, `width` design pixels wide (0 fills the
    /// row), and saves what's typed when it's done.
    pub fn draw(boxes: *Boxes, which: Detail, r: *roll.Roll, library: *const Library, io: std.Io, hint: [:0]const u8, width: f32) void {
        const buffer = boxes.text.getPtr(which);
        const value = r.detail(which) orelse "";
        // A value too long for the box can't be edited here, so a shortened copy never gets saved
        // over it.
        const fits = value.len <= buffer.len;
        if (boxes.editing != which) showCut(buffer, value);
        c.ImGui_BeginDisabled(!fits);
        const edit = field(which, buffer, hint, width, library, io);
        c.ImGui_EndDisabled();
        if (edit.active) {
            boxes.editing = which;
        } else if (boxes.editing == which) {
            boxes.editing = null;
        }
        if (edit.done and fits) r.setDetail(io, which, std.mem.sliceTo(buffer, 0)) catch |err| std.log.err("can't save {s}'s {t}: {t}", .{ r.info.name, which, err });
    }
};

/// Puts `value` into a text box, cut short at a whole character if it doesn't fit. Only for
/// showing: a box holding a cut value mustn't be saved.
pub fn showCut(buffer: [:0]u8, value: []const u8) void {
    var end = @min(value.len, buffer.len);
    // Back off to the start of a character, so the cut doesn't split one.
    while (end < value.len and end > 0 and value[end] & 0xc0 == 0x80) end -= 1;
    @memcpy(buffer[0..end], value[0..end]);
    buffer[end] = 0;
}

test "a value cut short for showing keeps whole characters" {
    var box: [6:0]u8 = @splat(0);
    showCut(&box, "Gent");
    try std.testing.expectEqualStrings("Gent", std.mem.sliceTo(&box, 0));
    // "è" is two bytes, the sixth and seventh, so a cut after six would split it.
    showCut(&box, "Gentsè, Belgium");
    try std.testing.expectEqualStrings("Gents", std.mem.sliceTo(&box, 0));
    showCut(&box, "Ghent, Belgium");
    try std.testing.expectEqualStrings("Ghent,", std.mem.sliceTo(&box, 0));
}
