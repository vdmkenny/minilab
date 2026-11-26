//! The messages of the keyboard shortcuts and their help, in English.

pub const Messages = struct {
    // The help panel's title, and the line under it: the keys are the same as those apps'.
    title: [:0]const u8 = "Keyboard shortcuts",
    subtitle: [:0]const u8 = "As in Lightroom and Bridge",
    // The help panel's groups of shortcuts. Headings are in capitals, as the design writes them.
    heading: struct {
        workspaces: [:0]const u8 = "WORKSPACES",
        frames: [:0]const u8 = "FRAMES",
        viewer: [:0]const u8 = "VIEWER",
        tools: [:0]const u8 = "TOOLS",
        settings: [:0]const u8 = "SETTINGS",
        rating: [:0]const u8 = "RATING",
        library: [:0]const u8 = "LIBRARY",
        window: [:0]const u8 = "WINDOW",
    } = .{},
    // What each shortcut does, in the help panel and in tooltips, with the keys beside it. The
    // help panel's columns leave about 200 pixels for them. The workspaces, Settings and Keyboard
    // shortcuts use their names from elsewhere.
    command: struct {
        // Frames.
        previous: [:0]const u8 = "Previous frame",
        next: [:0]const u8 = "Next frame",
        first: [:0]const u8 = "First frame",
        last: [:0]const u8 = "Last frame",
        select_all: [:0]const u8 = "Select all frames",
        select_none: [:0]const u8 = "Select no frames",
        // The viewer.
        zoom_toggle: [:0]const u8 = "Fit or 100%",
        zoom_in: [:0]const u8 = "Zoom to 100%",
        zoom_out: [:0]const u8 = "Zoom to fit",
        clipping: [:0]const u8 = "Show clipping",
        // A magnifier over part of the frame.
        loupe: [:0]const u8 = "Loupe",
        // Shows the negative in place of the positive, and back.
        before: [:0]const u8 = "Negative or positive",
        split: [:0]const u8 = "Split view",
        // Tools.
        white_balance: [:0]const u8 = "Pick white balance",
        base: [:0]const u8 = "Pick film base",
        // A verb: crop the frame.
        crop: [:0]const u8 = "Crop",
        turn_left: [:0]const u8 = "Turn left",
        turn_right: [:0]const u8 = "Turn right",
        mirror: [:0]const u8 = "Mirror left to right",
        confirm: [:0]const u8 = "Finish the crop",
        // A frame's settings.
        undo: [:0]const u8 = "Undo",
        redo: [:0]const u8 = "Redo",
        copy_settings: [:0]const u8 = "Copy settings",
        paste_settings: [:0]const u8 = "Paste settings",
        paste_previous: [:0]const u8 = "Paste from previous frame",
        sync: [:0]const u8 = "Sync settings to roll",
        reset: [:0]const u8 = "Reset settings",
        automatic: [:0]const u8 = "Automatic settings",
        // Rating frames.
        no_stars: [:0]const u8 = "No stars",
        one_star: [:0]const u8 = "1 star",
        two_stars: [:0]const u8 = "2 stars",
        three_stars: [:0]const u8 = "3 stars",
        four_stars: [:0]const u8 = "4 stars",
        five_stars: [:0]const u8 = "5 stars",
        // A verb: mark the frame as rejected.
        reject: [:0]const u8 = "Reject",
        unreject: [:0]const u8 = "Clear reject",
        // The library.
        new_roll: [:0]const u8 = "New roll",
        find: [:0]const u8 = "Find rolls",
        // Import goes to the Scan page.
        import: [:0]const u8 = "Import (Scan)",
        // The window.
        hide_panels: [:0]const u8 = "Hide side panels",
        hide_all: [:0]const u8 = "Hide all panels",
        full_screen: [:0]const u8 = "Full screen",
        quit: [:0]const u8 = "Quit",
        // What Esc does.
        cancel: [:0]const u8 = "Cancel a pick, close a panel",
    } = .{},
};
