//! The messages shared by many parts of the app, in English: buttons and words like Cancel and
//! Done. A message that only one part uses goes in that part's file instead.

pub const Messages = struct {
    cancel: [:0]const u8 = "Cancel",
    done: [:0]const u8 = "Done",
    close: [:0]const u8 = "Close",
    reset: [:0]const u8 = "Reset",
    edit: [:0]const u8 = "Edit",
    remove: [:0]const u8 = "Remove",
    rename: [:0]const u8 = "Rename",
    choose: [:0]const u8 = "Choose",
    refresh: [:0]const u8 = "Refresh",
    copied: [:0]const u8 = "Copied",
    none: [:0]const u8 = "None",
    not_set: [:0]const u8 = "Not set",
    select_all: [:0]const u8 = "Select all",
    select_none: [:0]const u8 = "Select none",
};
