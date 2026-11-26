//! The messages of the header and the notices in it, in English.

pub const Messages = struct {
    // The tooltip on the button that copies a command, for pasting into a terminal.
    copy_for_terminal: [:0]const u8 = "Copy, for Terminal",
    // The notices in the header. Keep them short, as the header has little room. Where one ends
    // in a reason after "·", the reason is an error's name from the code, in English.
    // {0} is a file's name and {1} why it couldn't be imported, like "file ends early".
    cant_import: [:0]const u8 = "Can't import {0} · {1}",
    // Scans dropped on the Rolls page, but not on a roll.
    drop_on_roll: [:0]const u8 = "Drop on a roll's row",
    flat_field_not_set: [:0]const u8 = "Flat field not set",
    // {0} is a roll's name. Trash is the system's trash, the Recycle Bin on Windows.
    moved_to_trash: [:0]const u8 = "Moved {0} to Trash",
    cant_move_to_trash: [:0]const u8 = "Can't move {0} to Trash · {1}",
    cant_read_dropped: [:0]const u8 = "Can't read what was dropped · {0}",
    // {0} scans were added, of the {1} dropped, to the roll called {2}.
    added_scans: [:0]const u8 = "Added {0} of {1} scans to {2}",
    // {0} frames came from {1} of the {2} scans dropped (a scan of a strip has many frames), and
    // went to the roll called {3}.
    added_frames: [:0]const u8 = "Added {0} frames from {1} of {2} scans to {3}",
};
