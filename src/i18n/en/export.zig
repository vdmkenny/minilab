//! The messages of the Export page, in English.

pub const Messages = struct {
    // The page's title without a roll, and with one: {0} is the roll's name.
    title: [:0]const u8 = "Export",
    title_roll: [:0]const u8 = "Export {0}",
    // {0} is how many frames are chosen, {1} how many the roll has.
    selected: [:0]const u8 = "{0} of {1} frames selected",
    // The star filter, in a 120 px drop-down. {0} is a number of stars, 1 to 5.
    any_rating: [:0]const u8 = "Any rating",
    stars_or_more: [:0]const u8 = "{0}+ stars",
    stars_exactly: [:0]const u8 = "{0} stars",
    filter_tooltip: [:0]const u8 = "Rejected left out",

    // A frame's card. {0} is its number, {1} its look, or not_developed.
    frame_tooltip: [:0]const u8 = "Frame {0} · {1}",
    not_developed: [:0]const u8 = "not developed · automatic settings",
    // Under a frame that's rejected, in place of its stars.
    rejected: [:0]const u8 = "Rejected",

    // The bottom of the page, while an export runs. {0} is the frame's number.
    canceling: [:0]const u8 = "Canceling after frame {0}…",
    // {0} is the file it's on, {1} how many files, {2} the file's name, {3} what it's doing.
    exporting_file: [:0]const u8 = "Exporting {0} of {1} · {2} · {3}",
    // Before anything is exported, and after. A link, 120 px from the end of the line.
    nothing_exported: [:0]const u8 = "Nothing exported yet",
    show_in_folder: [:0]const u8 = "Show in folder",
    // What the last export did. {0} is how many files it wrote, {1} what it wrote (like "JPEG,
    // Display P3"), and in last_export_failed {2} the frame that failed and {3} why.
    last_export_one: [:0]const u8 = "Last export · {0} file · {1}",
    last_export_many: [:0]const u8 = "Last export · {0} files · {1}",
    last_export_failed: [:0]const u8 = "Last export · {0} of {1} files · {2} · frame {3} failed ({4})",

    // The notices when an export ends. {0} is how many files were written, and {1} the
    // folder, or how many there were to write. {2} is the frame that failed, {3} why. The
    // reason is the program's own word for it, in English.
    exported_one: [:0]const u8 = "Exported {0} file to {1}",
    exported_many: [:0]const u8 = "Exported {0} files to {1}",
    export_frame_failed: [:0]const u8 = "Exported {0} of {1} files · frame {2} failed ({3})",
    // Also the summary's first part, with what it wrote after it.
    export_canceled: [:0]const u8 = "Export canceled · {0} of {1} files",
    // {0} is why, in the program's own words.
    export_folder_failed: [:0]const u8 = "Export failed · can't create folder ({0})",
    cant_export: [:0]const u8 = "Can't export · {0}",
    cant_start: [:0]const u8 = "Can't start export · {0}",

    // The settings panel, under its FILE heading.
    file_heading: [:0]const u8 = "FILE",
    not_available: [:0]const u8 = "Not available yet",
    // A note on the file type. {0} in jpeg_note is the quality, 1 to 100.
    jpeg_note: [:0]const u8 = "8-bit · quality {0} · ICC profile",
    tiff_note: [:0]const u8 = "16-bit · ZIP · ICC profile",
    heic_note: [:0]const u8 = "HDR with gain map · not available yet",
    // Added to the note for ProPhoto RGB in an 8-bit file.
    banding_risk: [:0]const u8 = "banding risk in 8-bit",
    // The rows' labels, in a 110 px column.
    quality: [:0]const u8 = "Quality",
    quality_tooltip: [:0]const u8 = "Higher is sharper and larger · 90 and up keep full color",
    color_space: [:0]const u8 = "Color space",
    size: [:0]const u8 = "Size",
    // The sizes. {0} is a number of pixels.
    full_resolution: [:0]const u8 = "Full resolution",
    long_edge_of: [:0]const u8 = "Long edge {0} px",
    custom_long_edge: [:0]const u8 = "Custom long edge",
    long_edge: [:0]const u8 = "Long edge",
    // The range a custom long edge can take, in pixels.
    long_edge_range: [:0]const u8 = "{0} to {1} px",
    file_names: [:0]const u8 = "File names",
    // The tooltip on the file name pattern: what each {field} in it becomes. The fields
    // themselves stay as they are, in the pattern and in frame_missing.
    pattern_roll: [:0]const u8 = "roll name, lowercase",
    pattern_name: [:0]const u8 = "roll name",
    pattern_frame: [:0]const u8 = "frame number",
    pattern_frame_digits: [:0]const u8 = "two digits",
    pattern_stock: [:0]const u8 = "film stock",
    pattern_date: [:0]const u8 = "date shot",
    // What's wrong with the pattern.
    frame_missing: [:0]const u8 = "{frame} missing",
    unknown_field: [:0]const u8 = "Unknown field",
    unclosed_brace: [:0]const u8 = "Unclosed brace",
    folder: [:0]const u8 = "Folder",
    folder_tooltip: [:0]const u8 = "Relative to the library",

    // The METADATA heading and its rows. The names sit in a 100 px column.
    metadata_heading: [:0]const u8 = "METADATA",
    film_stock: [:0]const u8 = "Film stock",
    stock_set_in_develop: [:0]const u8 = "Set in Develop",
    // The develop settings, and what they hold.
    settings: [:0]const u8 = "Settings",
    settings_note: [:0]const u8 = "Look, base, scanner",
    rating: [:0]const u8 = "Rating",
    rating_note: [:0]const u8 = "Stars, rejected",
    // The roll's own fields, each a name and a value, written to XMP.
    own_fields: [:0]const u8 = "Own fields",
    add_field: [:0]const u8 = "Add field",
    add_field_tooltip: [:0]const u8 = "Written to XMP",
    field_name_hint: [:0]const u8 = "Name",
    field_value_hint: [:0]const u8 = "Value",
    metadata_note: [:0]const u8 = "EXIF and XMP in each file",

    // The Export button. {0} is how many frames are chosen.
    export_one: [:0]const u8 = "Export 1 frame",
    export_many: [:0]const u8 = "Export {0} frames",
    exporting: [:0]const u8 = "Exporting…",
    // Why Export is off, in its tooltip.
    under_way: [:0]const u8 = "Export under way",
    no_frames_selected: [:0]const u8 = "No frames selected",
    invalid_pattern: [:0]const u8 = "Invalid file name pattern",
    no_folder: [:0]const u8 = "No folder chosen",
};
