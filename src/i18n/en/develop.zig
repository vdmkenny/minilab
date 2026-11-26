//! The messages of the Develop page, in English.

pub const Messages = struct {
    // A frame's name, in the info line and in notices. {0} is its number.
    frame_name: [:0]const u8 = "Frame {0}",

    // The frames column. Headings are in capitals, as the design writes them.
    frames_heading: [:0]const u8 = "FRAMES",
    // How many of the roll's frames are developed. {0} is the developed ones, {1} all of them.
    developed_count: [:0]const u8 = "{0} of {1}",
    developed_count_help: [:0]const u8 = "Developed of all frames",
    no_scans: [:0]const u8 = "No scans",
    // Notes at the bottom of the column, on where the film base comes from. The film base is the
    // color of the bare film, between and around the pictures.
    base_measured_per_frame: [:0]const u8 = "Base measured per frame",
    base_from_gaps: [:0]const u8 = "Base from the gaps between frames",
    base_picked: [:0]const u8 = "Base picked on this frame",
    loose_scans: [:0]const u8 = "Loose scans · not saved",

    // The viewer's toolbar. The view switch: the negative, the positive, or the two side by
    // side. They also label the two halves of the split.
    compare: struct {
        split: [:0]const u8 = "Split",
        negative: [:0]const u8 = "Negative",
        positive: [:0]const u8 = "Positive",
    } = .{},
    // A button: fit the whole frame in the viewer. Keep it short.
    fit: [:0]const u8 = "Fit",
    fit_help: [:0]const u8 = "Whole frame",
    actual_size_help: [:0]const u8 = "Actual pixels · drag to move",
    clipping: [:0]const u8 = "Clipping",
    clipping_help: [:0]const u8 = "Clipped highlights red, shadows blue",
    loupe_help: [:0]const u8 = "Loupe · full resolution",
    crop_help: [:0]const u8 = "Crop and turn",
    rotate_left: [:0]const u8 = "Rotate left",
    rotate_right: [:0]const u8 = "Rotate right",
    // A button in the crop tool that finds the frame on the scan. Keep it short.
    auto_crop: [:0]const u8 = "Auto",
    auto_crop_help: [:0]const u8 = "Detect the frame",
    // A verb: mirror the picture left to right.
    flip: [:0]const u8 = "Flip",
    keep_crop_help: [:0]const u8 = "Keeps the crop",
    // The color pipeline, at the right of the toolbar. "Scanner RGB" and "sRGB" are color spaces.
    // {0} is the look's name.
    pipeline: [:0]const u8 = "Scanner RGB, linear → sRGB",
    pipeline_with_look: [:0]const u8 = "Scanner RGB, linear → {0} → sRGB",

    // Over the picture.
    // {0} is the frame's number.
    failed_to_load: [:0]const u8 = "Frame {0} failed to load",
    pick_base_hint: [:0]const u8 = "Click the film base · Esc to cancel",
    pick_neutral_hint: [:0]const u8 = "Click something neutral gray · Esc to cancel",
    // The crop tool's note on what happens to the crop once it's done. {0} is an angle in
    // degrees, like 90.
    mirrored_after_cropping: [:0]const u8 = "Mirrored after cropping",
    turned_after_cropping: [:0]const u8 = "Turned {0}° after cropping",
    mirrored_and_turned_after_cropping: [:0]const u8 = "Mirrored and turned {0}° after cropping",

    // The info line under the picture, in lower case. {0} and {1} are the width and height in
    // pixels.
    info_scan: [:0]const u8 = "scan {0} × {1} px, 48-bit linear",
    // The same, for a scan with an infrared plane (IR).
    info_scan_infrared: [:0]const u8 = "scan {0} × {1} px, 48-bit linear + IR",
    // {2} is info_turned or nothing, and {3} is info_mirrored or nothing.
    info_crop: [:0]const u8 = "crop {0} × {1} px{2}{3}",
    // {0} is an angle in degrees, like 90.
    info_turned: [:0]const u8 = ", turned {0}°",
    info_mirrored: [:0]const u8 = ", mirrored",
    // The rating's reject button.
    reject: [:0]const u8 = "Reject",
    clear_reject: [:0]const u8 = "Clear reject",

    // The histogram. {0} is a percentage, like 6.9.
    shadows_clipped: [:0]const u8 = "Shadows clipped {0}%",
    highlights_clipped: [:0]const u8 = "Highlights clipped {0}%",

    // The Preset section. Row labels fit in 96 pixels.
    preset_heading: [:0]const u8 = "PRESET",
    film_type: [:0]const u8 = "Film type",
    // A scan that's already a positive picture, with no film to invert.
    finished_scan: [:0]const u8 = "Finished scan",
    // The film stock, like Kodak Portra 400.
    stock: [:0]const u8 = "Stock",
    search_stocks: [:0]const u8 = "Search stocks",
    // A film stock with no numbers from its maker's datasheet.
    no_datasheet: [:0]const u8 = "No datasheet numbers",
    datasheet_corrections: [:0]const u8 = "Datasheet corrections",
    datasheet_corrections_help: [:0]const u8 = "Per-layer datasheet curves",
    look: [:0]const u8 = "Look",
    // The look menu's groups, and the item that imports a .cube file as a look.
    looks_built_in: [:0]const u8 = "Built in",
    looks_film: [:0]const u8 = "Film looks",
    looks_imported: [:0]const u8 = "Imported LUTs",
    looks_fitted: [:0]const u8 = "Fitted looks",
    import_cube: [:0]const u8 = "Import .cube…",
    import_cube_help: [:0]const u8 = "3D or 1D · sRGB or Rec. 709",
    tone: [:0]const u8 = "Tone",
    white_balance: [:0]const u8 = "White balance",
    // The Stock white balance, which uses the film's datasheet. {0} is the film's maker, like
    // Kodak.
    stock_balance_of: [:0]const u8 = "Stock ({0})",
    stock_balance_no_preset: [:0]const u8 = "Stock (no preset)",
    stock_balance_calibrate_first: [:0]const u8 = "Stock (calibrate first)",
    // The scanner's calibration for the Stock white balance. {0} is the scanner's name and {1}
    // a number of rolls.
    stock_balance_no_scanner: [:0]const u8 = "Stock balance · no scanner on this roll",
    not_calibrated: [:0]const u8 = "{0} not calibrated",
    calibrated_from_one_roll: [:0]const u8 = "{0} calibrated from {1} roll",
    calibrated_from_rolls: [:0]const u8 = "{0} calibrated from {1} rolls",
    // {0} is one of the two messages above.
    this_roll_included: [:0]const u8 = "{0} · this one included",
    calibrate_from_roll: [:0]const u8 = "Calibrate from this roll",
    measure_roll_again: [:0]const u8 = "Measure this roll again",
    add_roll: [:0]const u8 = "Add this roll",
    // {0} is how many frames were measured, {1} how many it needs.
    frames_needed: [:0]const u8 = "Measured {0} of {1} frames needed",
    // {0} is the reason, as a programmer's error name.
    calibration_not_saved: [:0]const u8 = "Calibration not saved: {0}",
    // {0} is how many frames, {1} and {2} are factors like 1.02.
    calibration_measured: [:0]const u8 = "Measured {0} frames · red ×{1}, blue ×{2} against the datasheet",
    fitted_note: [:0]const u8 = "Fitted look · no Tone or Inversion",

    // The film base: the color of the bare film, which the inversion takes as its black point.
    film_base: [:0]const u8 = "Film base",
    base_thinnest: [:0]const u8 = "Thinnest film in this frame",
    base_from_roll_gaps: [:0]const u8 = "From the gaps between the roll's frames",
    base_from_frame_gaps: [:0]const u8 = "From the gaps beside this frame",
    base_picked_here: [:0]const u8 = "Picked on this frame",
    pick_base_help: [:0]const u8 = "Pick the film base",

    // The Density section. Row labels fit in 96 pixels.
    density_heading: [:0]const u8 = "DENSITY",
    // D max is the film's density range, from the thinnest to the densest part, as in
    // densitometry. Usually left as "D max".
    d_max: [:0]const u8 = "D max",
    d_max_help: [:0]const u8 = "Lower brightens highlights · higher keeps them from clipping",
    // A shift of the densities before they're inverted.
    offset: [:0]const u8 = "Offset",
    offset_help: [:0]const u8 = "Higher sends more shadows to black · lower lifts them",
    // The color matrix that mixes the film's three density channels.
    matrix: [:0]const u8 = "Matrix",
    // The matrix as it is: unchanged (the identity matrix) or changed by hand. Identity is also
    // the button that puts it back.
    identity: [:0]const u8 = "Identity",
    custom: [:0]const u8 = "Custom",
    density_matrix_heading: [:0]const u8 = "DENSITY MATRIX",
    inversion_heading: [:0]const u8 = "INVERSION",
    contrast: [:0]const u8 = "Contrast",
    contrast_help: [:0]const u8 = "Higher adds contrast · lower flattens it",
    // The black point.
    black: [:0]const u8 = "Black",
    black_help: [:0]const u8 = "Higher lifts black toward gray · lower deepens it",
    // How gently the highlights ease off towards white, as the shoulder of a film curve.
    highlight_roll_off: [:0]const u8 = "Highlight roll-off",
    highlight_roll_off_help: [:0]const u8 = "Lower eases highlights off sooner · higher keeps them until they clip",
    exposure: [:0]const u8 = "Exposure",
    exposure_help: [:0]const u8 = "Higher brightens the picture · lower darkens it",

    // The Color balance section.
    color_balance_heading: [:0]const u8 = "COLOR BALANCE",
    saturation: [:0]const u8 = "Saturation",
    saturation_help: [:0]const u8 = "Higher is more colorful · 0 gray, 1 unchanged",
    // The white balance's color temperature, in kelvin.
    temperature: [:0]const u8 = "Temperature",
    temperature_help: [:0]const u8 = "Lower for warm light, like tungsten · higher for shade",
    tint: [:0]const u8 = "Tint",
    tint_help: [:0]const u8 = "Higher is more magenta · lower more green",

    // The dust section. Its heading is a check box.
    remove_dust_heading: [:0]const u8 = "REMOVE DUST",
    threshold: [:0]const u8 = "Threshold",
    threshold_help: [:0]const u8 = "Lower removes fainter specks · higher only obvious ones",
    max_size: [:0]const u8 = "Max size",
    max_size_help: [:0]const u8 = "Larger specks are kept · percent of the frame's long side",
    max_density: [:0]const u8 = "Max density",
    max_density_help: [:0]const u8 = "Stronger specks are kept · lower to protect lights and stars",
    // The button that tints what dust removal takes out, on the picture.
    show_removed: [:0]const u8 = "Show what's removed",
    // The row choosing how dust is found, for a frame whose scan has an infrared plane.
    find_with: [:0]const u8 = "Find with",
    // Infrared's sliders. Threshold is the same word as above; grow is how far round each
    // defect the fill reaches.
    infrared_threshold_help: [:0]const u8 = "Lower removes fainter dust · higher only dense specks",
    grow: [:0]const u8 = "Grow",
    grow_help: [:0]const u8 = "How far round each speck it fills · percent of the frame's long side",
    // Warnings under the finder. Silver black and white film blocks infrared; Kodachrome's dye
    // shows in it; and a plane can turn out not to be a map of dust at all.
    silver_blocks_infrared: [:0]const u8 = "Silver film blocks infrared",
    infrared_softens_kodachrome: [:0]const u8 = "May soften Kodachrome's detail",
    infrared_not_usable: [:0]const u8 = "Infrared not usable on this film",
    // Max density at its highest: specks of any density are removed.
    any_density: [:0]const u8 = "Any",

    // The bar under the settings, and the Sync menu it opens.
    sync_to_roll: [:0]const u8 = "Sync to roll…",
    sync_to_roll_help: [:0]const u8 = "Sync to roll",
    sync_heading: [:0]const u8 = "SYNC TO ROLL",
    // {0} is the number of frames, {1} the roll's name.
    sync_to_one_other: [:0]const u8 = "To the {0} other frame of {1}",
    sync_to_others: [:0]const u8 = "To the {0} other frames of {1}",
    // What Sync copies. White balance and Film base above are the others.
    sync_look: [:0]const u8 = "Look, tone and saturation",
    sync_density: [:0]const u8 = "Density: D max and offset",
    sync_dust: [:0]const u8 = "Dust removal",
    sync_geometry: [:0]const u8 = "Crop, turns and mirror",
    // A verb, on the button that syncs.
    sync: [:0]const u8 = "Sync",

    // Notices from the keyboard shortcuts. {0} is the frame's name.
    copied_settings: [:0]const u8 = "Copied settings of {0}",
    nothing_copied: [:0]const u8 = "Nothing copied yet",
    no_previous_frame: [:0]const u8 = "No previous frame",
    previous_not_developed: [:0]const u8 = "Previous frame not developed",
};
