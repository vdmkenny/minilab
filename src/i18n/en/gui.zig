//! The messages of the controls shared by every page, in English.

pub const Messages = struct {
    // A page that needs a roll, when none is open, and its button to the Rolls page.
    no_roll_open: [:0]const u8 = "No roll open",
    go_to_rolls: [:0]const u8 = "Go to Rolls",
    // In a menu you can search, when nothing matches what's typed.
    no_matches: [:0]const u8 = "No matches",
    // The tooltip of a setting's reset button. {0} is the value it resets to, like "0" or "Any".
    reset_to: [:0]const u8 = "Reset to {0}",
    // The calendar. Its heading: {0} is the month's name and {1} the year, like "November 2026".
    month_heading: [:0]const u8 = "{0} {1}",
    // The button that picks today's date.
    today: [:0]const u8 = "Today",
    month: struct {
        january: [:0]const u8 = "January",
        february: [:0]const u8 = "February",
        march: [:0]const u8 = "March",
        april: [:0]const u8 = "April",
        may: [:0]const u8 = "May",
        june: [:0]const u8 = "June",
        july: [:0]const u8 = "July",
        august: [:0]const u8 = "August",
        september: [:0]const u8 = "September",
        october: [:0]const u8 = "October",
        november: [:0]const u8 = "November",
        december: [:0]const u8 = "December",
    } = .{},
    // The days of the week, as the calendar's columns head them, Monday first. Each column is
    // 32 pixels wide, so keep them to two or three letters.
    weekday: struct {
        monday: [:0]const u8 = "Mo",
        tuesday: [:0]const u8 = "Tu",
        wednesday: [:0]const u8 = "We",
        thursday: [:0]const u8 = "Th",
        friday: [:0]const u8 = "Fr",
        saturday: [:0]const u8 = "Sa",
        sunday: [:0]const u8 = "Su",
    } = .{},
};
