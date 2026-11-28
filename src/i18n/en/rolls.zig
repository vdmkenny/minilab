//! The messages of the Rolls page, New roll and a roll's details, in English.

pub const Messages = struct {
    // The title row: the page's title, then how many rolls the library has. {0} is the number.
    title: [:0]const u8 = "Rolls",
    roll_count_one: [:0]const u8 = "{0} roll",
    roll_count_many: [:0]const u8 = "{0} rolls",
    search_hint: [:0]const u8 = "Search name, stock, camera",
    search_tooltip: [:0]const u8 = "Search rolls",
    // The film size filter's first choice, in a 130 px drop-down.
    all_film_sizes: [:0]const u8 = "All film sizes",
    // The button that opens the New roll panel, and the panel's title.
    new_roll: [:0]const u8 = "New roll",
    // When the page has no rolls to show.
    no_rolls: [:0]const u8 = "No rolls yet",
    no_matching_rolls: [:0]const u8 = "No matching rolls",

    // A roll's card. {0} is how many frames are developed, {1} how many the roll has.
    developed: [:0]const u8 = "{0} of {1} developed",
    // The tooltips of the small buttons on a card.
    delete_roll: [:0]const u8 = "Delete roll",
    edit_details: [:0]const u8 = "Edit details",
    // The filmstrip beside the card. {0} is how many frames don't fit; the box is sized for
    // two digits.
    more_frames: [:0]const u8 = "+{0} more",

    // Asking before Delete. {0} is the roll's name, then how many frames it has.
    delete_title: [:0]const u8 = "Delete {0}?",
    frame_count_one: [:0]const u8 = "{0} frame",
    frame_count_many: [:0]const u8 = "{0} frames",
    move_to_trash: [:0]const u8 = "Move to Trash",

    // New roll. The labels sit in a 96 px column. The roll's name starts as default_name,
    // where {0} is the roll's number in three digits, like 012; it's also the roll's folder.
    default_name: [:0]const u8 = "Roll {0}",
    name: [:0]const u8 = "Name",
    film_type: [:0]const u8 = "Film type",
    stock: [:0]const u8 = "Stock",
    search_stocks: [:0]const u8 = "Search stocks",
    film_size: [:0]const u8 = "Film size",
    format: [:0]const u8 = "Format",
    // Hints in the empty boxes. The date is typed year, month, day, as digits.
    camera_hint: [:0]const u8 = "[Camera]",
    lens_hint: [:0]const u8 = "[Lens]",
    date_hint: [:0]const u8 = "YYYY-MM-DD",
    copyright_hint: [:0]const u8 = "[Your name]",
    input: [:0]const u8 = "Input",
    // A camera roll's flat field: a shot of the light source with no film. It's optional.
    flat_field: [:0]const u8 = "Flat field",
    choose_shot: [:0]const u8 = "Choose a shot…",
    optional: [:0]const u8 = "Optional",
    // The button at the bottom; it scans straight away for a scanner roll.
    create_and_scan: [:0]const u8 = "Create roll and scan",
    create: [:0]const u8 = "Create roll",
    // Why Create didn't make the roll, under its name.
    name_used: [:0]const u8 = "Name already used",
    invalid_name: [:0]const u8 = "Invalid name",
    not_created: [:0]const u8 = "Roll not created",
    name_not_saved: [:0]const u8 = "Name could not be saved",
};
