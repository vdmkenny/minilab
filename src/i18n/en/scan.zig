//! The messages of the Scan page, in English.

pub const Messages = struct {
    // The header's scanner line. It shows the scanner's name, then what it's doing.
    no_scanner: [:0]const u8 = "No scanner",
    looking_for_scanners: [:0]const u8 = "Looking for scanners",
    // What the scanner is doing, after its name in the header, in lower case: "Perfection V200 ·
    // ready".
    doing: struct {
        opening: [:0]const u8 = "opening",
        not_ready: [:0]const u8 = "not ready",
        ready: [:0]const u8 = "ready",
        previewing: [:0]const u8 = "previewing",
        scanning: [:0]const u8 = "scanning",
        finishing: [:0]const u8 = "finishing",
    } = .{},

    // Why the scanner can't be used, in the scanner panel and as a notice.
    problems: struct {
        start: [:0]const u8 = "Scan thread failed to start",
        list: [:0]const u8 = "Scanner search failed",
        open: [:0]const u8 = "Can't open scanner · busy or in use elsewhere",
        preview: [:0]const u8 = "Preview failed",
        scan: [:0]const u8 = "Scan failed",
    } = .{},

    // Notices.
    scanning_canceled: [:0]const u8 = "Scanning canceled",
    // {0} is how many frames were scanned, {1} how many were wanted.
    scanned_frames: [:0]const u8 = "Scanned {0} of {1} frames",
    preview_kept: [:0]const u8 = "Preview kept with its roll",
    roll_not_found: [:0]const u8 = "Roll not found",
    settings_not_saved: [:0]const u8 = "Scanner settings not saved",

    // The scanner panel, on the left. Headings are in capitals, as the design writes them.
    scanner_heading: [:0]const u8 = "SCANNER",
    // The scanner menu, when it has no scanners to list.
    looking_for_scanners_menu: [:0]const u8 = "Looking for scanners…",
    no_scanner_drivers: [:0]const u8 = "No scanner drivers",
    no_scanner_found: [:0]const u8 = "No scanner found",
    // {0} is the scanner profile's description, from its maker's settings.
    profile: [:0]const u8 = "Profile: {0}",
    // What raw setup sets on a scanner without a profile.
    raw_not_linear: [:0]const u8 = "No profile · data may not be linear",
    raw_linear: [:0]const u8 = "Raw · gamma 1.0",
    raw_linear_colour_off: [:0]const u8 = "Raw · gamma 1.0 · color correction off",
    scanner_settings: [:0]const u8 = "Scanner settings",
    // What fits on the scanner's film area. {0} is its width in mm, like "33.02".
    // {1} is a film size, like "120", and {2} that film's frame height in mm.
    film_area_too_narrow: [:0]const u8 = "Film area {0} mm · too narrow for {1} ({2} mm)",
    // {1} is the frame height in mm.
    film_area_edges_hidden: [:0]const u8 = "Film area {0} mm · {1} mm frames fit, edges under the holder",
    film_area_narrow: [:0]const u8 = "Film area {0} mm · 135 and narrower",
    // {0} by {1}, in mm.
    film_area: [:0]const u8 = "Film area {0} × {1} mm",

    // Setting up scanner drivers, when none load.
    driver_needed: [:0]const u8 = "Scanner driver needed",
    twain_driver: [:0]const u8 = "Scanner's TWAIN driver",
    // SANE is the name of the driver collection.
    drivers_needed_sane: [:0]const u8 = "Scanner drivers needed: SANE",
    // {0} is the name of the package to install, "sane-backends".
    sane_package: [:0]const u8 = "{0} package",
    // A setup step is done: Homebrew is on the computer.
    installed: [:0]const u8 = "Installed",
    // A button. Homebrew is a name.
    get_homebrew: [:0]const u8 = "Get Homebrew",

    // The film type.
    film_type: [:0]const u8 = "Film type",
    film_types: struct {
        colour_negative: [:0]const u8 = "Color negative",
        bw_negative: [:0]const u8 = "B&W negative",
        positive: [:0]const u8 = "Positive",
    } = .{},
    // What minilab does with each film type, after the scanner's mode.
    film_types_why: struct {
        colour_negative: [:0]const u8 = "raw, orange mask kept",
        bw_negative: [:0]const u8 = "raw, inverted in minilab",
        positive: [:0]const u8 = "no inversion",
    } = .{},
    // The scanner has no setting for the film.
    no_film_mode: [:0]const u8 = "No film mode",
    // {0} is the scanner's film mode, as its driver names it, like "Positive Film". {1} says
    // what minilab does with the film, like "raw, orange mask kept".
    scanner_mode: [:0]const u8 = "Scanner mode: {0} · {1}",
    // The scanner's film mode, before there's a scanner to name it.
    positive_film: [:0]const u8 = "Positive Film",

    resolution: [:0]const u8 = "Resolution",
    // How big each frame's scan will be. {0} by {1} is its size in pixels, and {2} its size in
    // MB. "About" when the size is from the roll's format, not a frame on the preview.
    size_about: [:0]const u8 = "About {0} × {1} px per frame",
    size_about_mb: [:0]const u8 = "About {0} × {1} px · {2} MB per frame",
    size: [:0]const u8 = "{0} × {1} px per frame",
    size_mb: [:0]const u8 = "{0} × {1} px · {2} MB per frame",
    margin: [:0]const u8 = "Margin around frames",

    // How detected frames fit their pictures.
    frame_detection: [:0]const u8 = "Frame detection",
    // {0} is the roll's aspect ratio, like "3:2".
    fit_format_ratio: [:0]const u8 = "Preserve aspect ratio ({0})",
    fit_format: [:0]const u8 = "Preserve aspect ratio",
    fit_whole: [:0]const u8 = "Detect full frame",

    // The buttons at the foot of the scanner panel. Preview and Detect frames share the panel's
    // width, about 130 pixels each.
    preview: [:0]const u8 = "Preview",
    // {0} is how far the preview is, in percent.
    previewing: [:0]const u8 = "Previewing {0}%",
    detect_frames: [:0]const u8 = "Detect frames",
    scan: [:0]const u8 = "Scan",
    scanning: [:0]const u8 = "Scanning…",
    scan_one_frame: [:0]const u8 = "Scan 1 frame",
    // {0} is how many frames, two or more.
    scan_frames: [:0]const u8 = "Scan {0} frames",

    // The scanner settings dialog.
    nothing_to_set: [:0]const u8 = "Nothing to set",
    // The first choice for a setting: what raw setup picks. {0} is that value.
    auto_value: [:0]const u8 = "Auto · {0}",
    driver_default: [:0]const u8 = "Driver default",
    on: [:0]const u8 = "On",
    off: [:0]const u8 = "Off",
    // A colour matrix that leaves colours as they are.
    identity: [:0]const u8 = "Identity",
    // A gamma table that leaves values as they are.
    straight: [:0]const u8 = "Straight",
    // The colour matrix's options, from the first to the last, like "cct-1 to cct-9".
    option_range: [:0]const u8 = "{0} to {1}",

    // The preview, in the middle. {0} is its resolution.
    preview_dpi: [:0]const u8 = "Preview · {0} dpi",
    // The tooltip of the button that goes to the Rolls page.

    // The selected frame, next to the preview.
    no_preview_yet: [:0]const u8 = "No preview yet",
    no_preview: [:0]const u8 = "No preview",
    detect_or_add: [:0]const u8 = "Detect frames, or add them by hand",
    // Why detection found no frames.
    detect_notes: struct {
        no_opening: [:0]const u8 = "No film on the preview",
        bad_resolution: [:0]const u8 = "Preview resolution unknown · preview again",
        out_of_memory: [:0]const u8 = "Detection out of memory",
        none_found: [:0]const u8 = "No frames found",
    } = .{},
    // {0} is the frame's number.
    frame: [:0]const u8 = "Frame {0}",
    // After the frame's number: {0} is the film and format, like "135 Full frame", and {1} its
    // shape, like "3:2" or "measured".
    frame_detail: [:0]const u8 = "{0} · {1}",
    frame_detail_rotated: [:0]const u8 = "{0} · {1}, shown rotated",
    // A frame's shape when it's measured on the film rather than set.
    measured: [:0]const u8 = "measured",
    scan_this_frame: [:0]const u8 = "Scan this frame",
    // Why a frame needs checking.
    check_cut: [:0]const u8 = "Check · runs off the preview",
    check_length: [:0]const u8 = "Check · length far from the format, measured box kept",
    check_pitch_format: [:0]const u8 = "Check · faint edges, placed from the format's pitch",
    check_pitch_next: [:0]const u8 = "Check · faint edges, placed from the next frames' pitch",
    check_pitch_previous: [:0]const u8 = "Check · faint edges, placed from the previous frames' pitch",
    // {0} is the pitch in mm, {1} and {2} the numbers of the frames it's measured between.
    check_pitch_frames: [:0]const u8 = "Check · faint edges, placed from the {0} mm pitch of frames {1} and {2}",

    // The frame's shape. {0} is the roll's aspect ratio, like "3:2".
    shape: [:0]const u8 = "Shape",
    shape_roll: [:0]const u8 = "Roll format, {0}",
    shape_free: [:0]const u8 = "Free",
    shape_custom: [:0]const u8 = "Custom ratio",
    // The sliders. Their labels have a 110 pixel column.
    inset: [:0]const u8 = "Inset",
    inset_help: [:0]const u8 = "Higher trims more off each side",
    rotation: [:0]const u8 = "Rotation",
    rotation_help: [:0]const u8 = "Straightens a tilted frame · resets to the detected angle",
    ratio: [:0]const u8 = "Ratio",
    ratio_help: [:0]const u8 = "Width over height · resets to the roll's format",
    full_height: [:0]const u8 = "Full height of the opening",
    // The frame tools, in one row of buttons.
    add_frame: [:0]const u8 = "Add frame",
    // A verb: cuts the frame in two.
    split: [:0]const u8 = "Split",
    delete_frame: [:0]const u8 = "Delete frame",
    detect_again: [:0]const u8 = "Detect again",

    // The queue, on the right.
    queue_heading: [:0]const u8 = "QUEUE",
    // {0} is the roll's name, {1} its film stock or kind of film.
    into_roll: [:0]const u8 = "Into {0} · {1}",
    // What the scan makes. {0} is the resolution and {1} the bits per pixel, like 48.
    queue_one_frame: [:0]const u8 = "1 frame · {0} dpi · {1}-bit",
    // {0} is how many frames, {1} the resolution and {2} the bits per pixel, like 48.
    queue_frames: [:0]const u8 = "{0} frames · {1} dpi · {2}-bit",
    finishing_frame: [:0]const u8 = "Finishing frame…",
    // Where each frame in the queue is. The row elides what doesn't fit.
    waiting: [:0]const u8 = "Waiting",
    skipped: [:0]const u8 = "Skipped",
    starting: [:0]const u8 = "Starting",
    scanning_frame: [:0]const u8 = "Scanning",
    finishing_scan: [:0]const u8 = "Finishing",
    checking_edges: [:0]const u8 = "Checking edges",
    scanned: [:0]const u8 = "Scanned, base measured",
    scanned_check_crop: [:0]const u8 = "Scanned · crop to check",
    // {0} says what went wrong, like "jammed".
    failed: [:0]const u8 = "Failed: {0}",
    canceled: [:0]const u8 = "Canceled",
    // A link, a verb: opens the frame to check its crop.
    check: [:0]const u8 = "Check",
    edges_not_found: [:0]const u8 = "Edges not found",
    // What went wrong with a frame's scan, after "Failed:".
    errors: struct {
        busy: [:0]const u8 = "scanner busy",
        jammed: [:0]const u8 = "jammed",
        cover_open: [:0]const u8 = "cover open",
        unsupported: [:0]const u8 = "not supported",
        out_of_memory: [:0]const u8 = "out of memory",
        not_found: [:0]const u8 = "scanner gone",
    } = .{},
};
