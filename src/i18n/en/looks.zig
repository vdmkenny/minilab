//! The messages of the Looks page, in English.

pub const Messages = struct {
    // The list of looks. Headings are in capitals, as the design writes them.
    built_in_heading: [:0]const u8 = "BUILT IN",
    film_looks_heading: [:0]const u8 = "FILM LOOKS",
    imported_heading: [:0]const u8 = "IMPORTED LUTS",
    fitted_heading: [:0]const u8 = "FITTED LOOKS",
    // The name of minilab's own look, which the rest of the app shows too.
    neutral: [:0]const u8 = "Neutral",
    frontier_emulation: [:0]const u8 = "Frontier emulation",
    inversion_curve: [:0]const u8 = "Inversion curve",
    // {0} is the LUT's size, like "33³".
    color_lut: [:0]const u8 = "Color LUT, {0}",
    // {0} is how many looks a collection has, {1} its license, like "CC BY 4.0".
    pack_looks: [:0]const u8 = "{0} looks · {1}",
    // An imported LUT's size. {0} is a number of points.
    lut_3d: [:0]const u8 = "3D, {0} points a side",
    lut_1d: [:0]const u8 = "1D, {0} points",
    cant_be_read: [:0]const u8 = "Can't be read",
    // A fitted look's state, on its badge and in the list.
    status_draft: [:0]const u8 = "Draft",
    status_fitted: [:0]const u8 = "Fitted",
    status_saved: [:0]const u8 = "Saved",
    // Where a fitted look's references come from, short, in the list.
    source_short: struct {
        frontier_software: [:0]const u8 = "Frontier software",
        lab_scans: [:0]const u8 = "Lab scans",
    } = .{},
    new_look: [:0]const u8 = "New look from references",
    new_look_tooltip: [:0]const u8 = "Fitted from pairs",
    import_cube: [:0]const u8 = "Import .cube LUT",
    import_cube_tooltip: [:0]const u8 = "3D or 1D · sRGB or Rec. 709",

    // The look's header: its badge and description.
    built_in: [:0]const u8 = "Built in",
    film_looks: [:0]const u8 = "Film looks",
    imported_lut: [:0]const u8 = "Imported LUT",
    neutral_about: [:0]const u8 = "minilab's inversion · film base, density matrix, inversion curve · no added color",
    frontier_about: [:0]const u8 = "Fujifilm Frontier color, over Neutral",
    imported_about: [:0]const u8 = "LUT over Neutral's sRGB output",
    fitted_to: struct {
        frontier_software: [:0]const u8 = "Fitted to Frontier software output",
        lab_scans: [:0]const u8 = "Fitted to lab scans",
    } = .{},
    click_to_rename: [:0]const u8 = "Click to rename",
    remove_from_library: [:0]const u8 = "Remove from library",
    remove_from_library_tooltip: [:0]const u8 = "Removes the library's copy",

    // A collection's credits, in a column next to their values.
    credit: [:0]const u8 = "Credit",
    license: [:0]const u8 = "License",
    source: [:0]const u8 = "Source",
    changes: [:0]const u8 = "Changes",

    // The previews of the frame open in Develop.
    no_frame: [:0]const u8 = "No frame open in Develop",
    // {0} is a frame's name, {1} its roll's.
    frame_of_roll: [:0]const u8 = "{0} of {1}",
    // {0} is the frame, like "Frame 3 of Roll 012".
    previews_on: [:0]const u8 = "On {0} · Develop's settings",
    // A button and a tooltip. {0} is the frame's name, like "Frame 3".
    use_on: [:0]const u8 = "Use on {0}",
    in_use_on: [:0]const u8 = "In use on {0}",

    // The rename dialog.
    rename_heading: [:0]const u8 = "RENAME LOOK",
    name_hint: [:0]const u8 = "Name",

    // The references bar over the pairs.
    references: [:0]const u8 = "References",
    // A verb: adds pairs of scans and references.
    add_pairs: [:0]const u8 = "Add pairs",
    add_pairs_tooltip: [:0]const u8 = "References (JPEG, TIFF) · with our scans (PPM)",
    // The file type in the Add pairs file dialog.
    pair_files: [:0]const u8 = "Scans and references (PPM, JPEG, TIFF)",
    // {0} is how many pairs are read so far, {1} how many there are.
    reading_pairs: [:0]const u8 = "Reading and lining up pairs, {0} of {1}…",
    finding_frames: [:0]const u8 = "Finding the frames the references show…",
    fitting: [:0]const u8 = "Fitting…",
    no_pairs_yet: [:0]const u8 = "No pairs yet",
    // {0} is the number of pairs, {1} how many of them are held out.
    pair_count_one: [:0]const u8 = "{0} pair · {1} held out to check the fit",
    pair_count_many: [:0]const u8 = "{0} pairs · {1} held out to check the fit",

    // The table of pairs: its column headers, then its cells.
    our_raw_scan: [:0]const u8 = "Our raw scan",
    // What one reference is called, in the reference column's header and a figure's caption.
    source_one: struct {
        frontier_software: [:0]const u8 = "Frontier output",
        lab_scans: [:0]const u8 = "Lab scan",
    } = .{},
    stock: [:0]const u8 = "Stock",
    registration: [:0]const u8 = "Registration",
    // A noun: whether the pair is used to fit the look or held out to check it.
    use: [:0]const u8 = "Use",
    no_pairs: [:0]const u8 = "No pairs",
    // The Use column's two values. "Fit" says the pair is used to fit the look.
    held_out: [:0]const u8 = "Held out",
    fit: [:0]const u8 = "Fit",
    held_out_tooltip: [:0]const u8 = "Held out to check the fit · click to fit with it",
    fit_tooltip: [:0]const u8 = "Used in the fit · click to hold out",
    // A pair's menu.
    use_to_fit: [:0]const u8 = "Use to fit",
    hold_out: [:0]const u8 = "Hold out to check the fit",
    remove_pair: [:0]const u8 = "Remove pair",
    // How well a pair's reference lines up with our scan. {0} is a correlation, like "0.93".
    cant_read: [:0]const u8 = "Can't read",
    not_aligned_yet: [:0]const u8 = "Not aligned yet",
    aligned: [:0]const u8 = "Aligned · {0}",
    // "Check" asks the user to check the pair: it lined up, but not well.
    check: [:0]const u8 = "Check · {0}",
    not_aligned: [:0]const u8 = "Not aligned · {0}",
    // The tooltip over a pair. {0} is the reference's file, {1} the correlation, like "0.93",
    // {2} the correlation that counts as good, {3} a percentage and {4} how the reference is
    // turned, like "turned 90°". Keep the line breaks.
    alignment: [:0]const u8 = "{0}\nCorrelation {1} of 1 · good above {2}\nReference covers {3}% of our scan's width",
    alignment_turned: [:0]const u8 = "{0}\nCorrelation {1} of 1 · good above {2}\nReference {4}, covers {3}% of our scan's width",

    // The figures under the table, and their captions.
    neutral_figure: [:0]const u8 = "minilab, Neutral look",
    // {0} is what one reference is called, like "Lab scan".
    reference_aligned: [:0]const u8 = "{0}, aligned to ours",
    reference_not_aligned: [:0]const u8 = "{0}, not aligned yet",
    difference: [:0]const u8 = "Difference, ΔE2000",
    // {0} is a ΔE2000, like "2.4".
    difference_median: [:0]const u8 = "Difference, ΔE2000 · median {0}",
    difference_after_fit: [:0]const u8 = "Difference map after fitting",

    // The model panel.
    model_heading: [:0]const u8 = "MODEL",
    // What the built-in and other looks are made of.
    film_base: [:0]const u8 = "Film base",
    film_base_note: [:0]const u8 = "Measured on each frame, or picked",
    density_matrix: [:0]const u8 = "Density matrix",
    density_matrix_note: [:0]const u8 = "3 × 3, for crosstalk between channels",
    inversion_curve_note: [:0]const u8 = "Contrast, black and highlight roll-off",
    as_set_in_develop: [:0]const u8 = "As set in Develop",
    frontier_color_lut: [:0]const u8 = "Frontier color LUT",
    // {0} is a collection's name, like "GlassMeter".
    pack_lut: [:0]const u8 = "{0} LUT",
    lut: [:0]const u8 = "LUT",
    // {0} is the LUT's size, like "33³".
    on_neutral_output: [:0]const u8 = "{0}, on Neutral's sRGB output",
    // What a fit may change, with a note under each.
    balance: [:0]const u8 = "Per-frame balance",
    balance_note: struct {
        frontier_software: [:0]const u8 = "3 offsets per frame, for the Frontier's own correction · not part of the look",
        lab_scans: [:0]const u8 = "3 offsets per frame, for the lab's own correction · not part of the look",
    } = .{},
    channel_curves: [:0]const u8 = "Channel curves",
    // {0} is a number of points.
    channel_curves_note: [:0]const u8 = "R, G and B, monotone, {0} points each",
    residual_lut: [:0]const u8 = "3D LUT for what's left",
    // The residual LUT's note. {0} is its size, like "17³".
    residual_maybe: [:0]const u8 = "{0} · only if the residual shows structure",
    // {1} is a percentage.
    residual_kept: [:0]const u8 = "{0} · kept, removed {1}% of the remaining error out of fold",
    residual_noise: [:0]const u8 = "{0} · left out, residual is noise",
    residual_too_few: [:0]const u8 = "{0} · left out, needs two fitted pairs",
    // The chart of curves: its label, then its axes. The axes' labels are tiny, so keep them
    // short.
    chart_default: [:0]const u8 = "default settings",
    // {0} is a number of points.
    chart_fitted: [:0]const u8 = "fitted, {0} points each",
    chart_identity: [:0]const u8 = "identity, not fitted",
    chart_density_in: [:0]const u8 = "density in",
    chart_out: [:0]const u8 = "out",
    // The figures for the held-out pairs.
    held_out_median: [:0]const u8 = "Held-out ΔE2000, median",
    held_out_p95: [:0]const u8 = "Held-out ΔE2000, 95th percentile",
    after_fit: [:0]const u8 = "after fit",
    no_pair_held_out: [:0]const u8 = "no pair held out",
    out_of_date: [:0]const u8 = "Out of date",
    // {0} is the number of fitted pairs, {1} the held-out ones, {2} a ΔE2000, like "1.84".
    fit_summary_one: [:0]const u8 = "{0} pair fitted · {1} held out · fitted median {2}",
    fit_summary_many: [:0]const u8 = "{0} pairs fitted · {1} held out · fitted median {2}",
    // The buttons at the bottom.
    fit_look: [:0]const u8 = "Fit look",
    no_pair_to_fit: [:0]const u8 = "No pair to fit",
    checked_on_held_out: [:0]const u8 = "Checked on held-out pairs",
    save: [:0]const u8 = "Save as .cube and curves",
    // {0} is the folder, like "Looks/Look 1".
    save_to: [:0]const u8 = "To {0}",

    // The default name of a new look. {0} is a number.
    look_name: [:0]const u8 = "Look {0}",
    // Notices in the header. {0} is a look's name and the last value is what went wrong, like
    // "AccessDenied".
    made: [:0]const u8 = "Made {0}",
    cant_make: [:0]const u8 = "Can't make a look · {0}",
    invalid_name: [:0]const u8 = "Invalid name",
    cant_rename: [:0]const u8 = "Can't rename the look · {0}",
    not_saved: [:0]const u8 = "{0} not saved · {1}",
    nothing_to_save: [:0]const u8 = "Nothing to save",
    cant_save: [:0]const u8 = "Can't save {0} · {1}",
    // {1} lists the files, {2} is the folder, like "Looks/Look 1".
    saved: [:0]const u8 = "Saved {0} · {1} in {2}",
    // {0} is an imported LUT's name.
    imported: [:0]const u8 = "Imported {0}",
    removed: [:0]const u8 = "Removed {0}",
    cant_remove: [:0]const u8 = "Can't remove {0} · {1}",
    // Adding pairs.
    not_own_look: [:0]const u8 = "Not a look of your own",
    busy: [:0]const u8 = "Busy",
    no_references: [:0]const u8 = "No references · JPEG or TIFF",
    // {0} is the number of scans, {1} of references.
    counts_differ: [:0]const u8 = "{0} scans, {1} references · counts differ",
    // {0} is how many were added, {1} how many there were, {2} what went wrong.
    added_some_pairs: [:0]const u8 = "Added {0} of {1} pairs · {2}",
    // {0} is how many pairs, {1} the look's name.
    added_pairs: [:0]const u8 = "Added {0} pairs to {1}",
    no_frames_to_match: [:0]const u8 = "No frames to match",
    cant_match: [:0]const u8 = "Can't match · {0}",
    matching_stopped: [:0]const u8 = "Matching stopped · {0}",
    // {0} is a number of references.
    found_all_frames: [:0]const u8 = "Found frames for all {0} references",
    // {0} is how many were found, {1} how many references there were.
    found_some_frames: [:0]const u8 = "Found frames for {0} of {1} references",
    fit_failed: [:0]const u8 = "Fit failed · {0}",
};
