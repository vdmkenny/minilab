//! The names of film types, sizes, formats and other choices, in English. Each group has a
//! message for each of its choices, named as the choice is in the code.

pub const Messages = struct {
    appearance: struct {
        system: [:0]const u8 = "System",
        dark: [:0]const u8 = "Dark",
        light: [:0]const u8 = "Light",
    } = .{},
    // The workspaces, as the header's tabs name them. Keep them short: they sit side by side.
    workspace: struct {
        rolls: [:0]const u8 = "Rolls",
        scan: [:0]const u8 = "Scan",
        develop: [:0]const u8 = "Develop",
        @"export": [:0]const u8 = "Export",
        looks: [:0]const u8 = "Looks",
    } = .{},
    // How dust is found: by its shape on the scan, or with the scan's infrared plane. They sit
    // side by side in a small box, so keep them short.
    dust_finder: struct {
        shape: [:0]const u8 = "Shape",
        infrared: [:0]const u8 = "Infrared",
    } = .{},
    // A roll's details, as the boxes for them are labelled. They sit in a column 96 pixels wide.
    detail: struct {
        camera: [:0]const u8 = "Camera",
        lens: [:0]const u8 = "Lens",
        shot: [:0]const u8 = "Date shot",
        copyright: [:0]const u8 = "Copyright",
        notes: [:0]const u8 = "Notes",
    } = .{},
    // The film types a roll can be.
    film_kind: struct {
        colour_negative: [:0]const u8 = "Color negative",
        bw_negative: [:0]const u8 = "B&W negative",
        colour_positive: [:0]const u8 = "Color positive",
        bw_positive: [:0]const u8 = "B&W positive",
    } = .{},
    // The film sizes that have a name rather than a number.
    film_size: struct {
        sheet: [:0]const u8 = "Sheet film",
        plate: [:0]const u8 = "Glass plate",
    } = .{},
    // The formats that have a name rather than just a size. The 35mm ones come after the film
    // size, as in "35mm full frame", and are capitalised on their own, as in "Full frame, 36 × 24".
    format: struct {
        @"135_full_frame": [:0]const u8 = "full frame",
        @"135_half_frame": [:0]const u8 = "half frame",
        @"135_panorama": [:0]const u8 = "panorama",
        @"135_masked_panorama": [:0]const u8 = "masked panorama",
        @"135_square": [:0]const u8 = "square",
        plate_quarter: [:0]const u8 = "Quarter plate, 3¼×4¼ in",
        plate_half: [:0]const u8 = "Half plate, 4¾×6½ in",
        plate_whole: [:0]const u8 = "Whole plate, 6½×8½ in",
        lantern_slide: [:0]const u8 = "Lantern slide, 3¼×3¼ in",
        lantern_slide_us: [:0]const u8 = "Lantern slide, 3¼×4 in",
    } = .{},
    // After the format, in the note under the frames: "35mm full frame · 3:2 · whole roll".
    whole_roll: [:0]const u8 = "whole roll",
    // Where a roll's scans come from.
    input: struct {
        scanner: [:0]const u8 = "Scanner",
        camera_raw: [:0]const u8 = "Camera RAW",
        tiff_files: [:0]const u8 = "TIFF files",
        finished: [:0]const u8 = "Finished scans",
    } = .{},
    // How the tone curve is shaped.
    tone: struct {
        standard: [:0]const u8 = "Standard",
        soft: [:0]const u8 = "Soft",
        hard: [:0]const u8 = "Hard",
        linear: [:0]const u8 = "Linear",
        log: [:0]const u8 = "Log",
    } = .{},
    // Where the automatic white balance comes from.
    white_balance: struct {
        auto_neutral: [:0]const u8 = "Auto neutral",
        auto_warm: [:0]const u8 = "Auto warm",
        auto_cool: [:0]const u8 = "Auto cool",
        average: [:0]const u8 = "Average",
        // The film stock's own balance.
        stock: [:0]const u8 = "Stock",
        // A point picked in the picture.
        picked: [:0]const u8 = "Picked",
    } = .{},
    // The tonal ranges the light's colour applies to. Three share a row a third of the panel wide.
    range: struct {
        highlights: [:0]const u8 = "Highlights",
        midtones: [:0]const u8 = "Midtones",
        shadows: [:0]const u8 = "Shadows",
    } = .{},
    // The looks minilab comes with.
    builtin_look: struct {
        neutral: [:0]const u8 = "Neutral",
        frontier: [:0]const u8 = "Frontier emulation",
    } = .{},
    // The kind of film a look emulates. The look menu groups looks under these.
    look_film: struct {
        colour_negative: [:0]const u8 = "Color negative",
        slide: [:0]const u8 = "Slide",
        bw: [:0]const u8 = "Black and white",
    } = .{},
    // How the film sits in the scanner.
    holder: struct {
        // A strip of film in a holder.
        strip: [:0]const u8 = "Strip",
        // Slides in mounts.
        mounted: [:0]const u8 = "Mounted",
    } = .{},
    // How far along a frame's export is, after "Exporting 3 of 36 · frame.jpg · ".
    export_stage: struct {
        reading: [:0]const u8 = "reading the scan",
        developing: [:0]const u8 = "developing",
        encoding: [:0]const u8 = "encoding",
        writing: [:0]const u8 = "writing",
    } = .{},
    // How a reference picture is turned or mirrored, after its name. An upright one says nothing.
    orientation: struct {
        quarter: [:0]const u8 = "turned 90°",
        half: [:0]const u8 = "turned 180°",
        three_quarters: [:0]const u8 = "turned 270°",
        mirrored: [:0]const u8 = "mirrored",
        mirrored_quarter: [:0]const u8 = "mirrored, turned 90°",
        mirrored_half: [:0]const u8 = "mirrored, turned 180°",
        mirrored_three_quarters: [:0]const u8 = "mirrored, turned 270°",
    } = .{},
    // Where the reference pictures for fitting a look come from, as the menu lists them.
    references: struct {
        // Our scans run through the Frontier scanner's own software.
        frontier_software: [:0]const u8 = "Frontier software, test runs",
        lab_scans: [:0]const u8 = "Lab scans of my negatives",
    } = .{},
    // The same, shortened for the list of looks.
    references_short: struct {
        frontier_software: [:0]const u8 = "Frontier software",
        lab_scans: [:0]const u8 = "Lab scans",
    } = .{},
    // A single reference picture, in a table's column header and a figure's caption.
    reference_one: struct {
        frontier_software: [:0]const u8 = "Frontier output",
        lab_scans: [:0]const u8 = "Lab scan",
    } = .{},
    // Why a .cube file couldn't be imported, after "Can't import name.cube · ".
    import_error: struct {
        not_a_cube: [:0]const u8 = "not a .cube LUT",
        // {0} and {1} are the smallest and largest number of points.
        bad_size: [:0]const u8 = "size outside {0} to {1} points a side",
        truncated: [:0]const u8 = "file ends early",
        too_much_data: [:0]const u8 = "more values than its size",
        invalid_number: [:0]const u8 = "value not a number",
        // {0} is a number of megabytes.
        file_too_big: [:0]const u8 = "over {0} MB",
        no_library: [:0]const u8 = "no library open",
    } = .{},
};
