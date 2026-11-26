//! How formats, films and stocks are written in the interface, in the language it's in.

const std = @import("std");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const i18n = @import("../i18n/i18n.zig");

const formats = minilab.formats;
const develop = minilab.develop;
const looks = minilab.look;

/// The format's name and its size in mm, along the film × across it, like "Full frame, 36 × 24".
/// Sheet film and plate names already include their size.
pub fn format(id: formats.Standard) [:0]const u8 {
    const f = id.format();
    const name = formatName(id);
    if (namesSize(f.size)) return gui.print("{s}", .{name});
    var name_buffer: [64]u8 = undefined;
    return gui.print("{s}, {d} × {d}", .{ capitalised(&name_buffer, name), f.width_mm, f.height_mm });
}

/// The film size and the format, like "135 · full frame, 36 × 24", for the roll cards.
pub fn filmAndFormat(id: formats.Standard) [:0]const u8 {
    const f = id.format();
    const name = formatName(id);
    if (namesSize(f.size)) return gui.print("{s} · {s}", .{ filmSizeName(f.size), name });
    return gui.print("{s} · {s}, {d} × {d}", .{ filmSizeName(f.size), name, f.width_mm, f.height_mm });
}

/// The size and the ratio, like "36 × 24 mm · 3:2", for the viewer's info line.
pub fn sizeAndRatio(id: formats.Standard) [:0]const u8 {
    const f = id.format();
    return gui.print("{d} × {d} mm · {s}", .{ f.width_mm, f.height_mm, ratio(f.ratio()) });
}

/// Whether the formats of film `size` have their size in their name, as sheet film and plates do.
fn namesSize(size: formats.FilmSize) bool {
    return switch (size) {
        .sheet, .plate => true,
        .@"135", .@"120", .@"127", .@"110", .@"126", .aps, .minox => false,
    };
}

/// The format's name: translated when it has words in it, like "full frame", and as it is when
/// it's only a size, like "6×6".
pub fn formatName(id: formats.Standard) []const u8 {
    const Names = @TypeOf(i18n.t.labels.format);
    return switch (id) {
        inline else => |tag| if (@hasField(Names, @tagName(tag))) @field(i18n.t.labels.format, @tagName(tag)) else tag.format().name,
    };
}

/// The name of format `f`, translated like `formatName` when it's a standard one.
fn nameOf(f: formats.Format) []const u8 {
    for (std.enums.values(formats.Standard)) |id| {
        const standard = id.format();
        if (standard.size == f.size and std.mem.eql(u8, standard.name, f.name)) return formatName(id);
    }
    return f.name;
}

/// A ratio the way people say it (3:2, 4:3, 1:1), or else just the number.
pub fn ratio(r: f32) []const u8 {
    const known = [_]struct { f32, []const u8 }{ .{ 1.5, "3:2" }, .{ 1.0, "1:1" }, .{ 4.0 / 3.0, "4:3" }, .{ 0.75, "3:4" }, .{ 2.0 / 3.0, "2:3" }, .{ 1.25, "5:4" }, .{ 0.8, "4:5" }, .{ 2.0, "2:1" }, .{ 3.0, "3:1" } };
    for (known) |k| if (@abs(r - k[0]) < 0.02) return k[1];
    return gui.print("{d:.2}:1", .{r});
}

/// A frame's number, like "03", for frame `index` counting from 0.
pub fn frameNumber(index: usize) [:0]const u8 {
    return gui.print("{d:0>2}", .{index + 1});
}

/// A frame of a roll, like "Roll 002 / 03", for frame `index` counting from 0.
pub fn rollFrame(roll_name: []const u8, index: usize) [:0]const u8 {
    return gui.print("{s} / {d:0>2}", .{ roll_name, index + 1 });
}

/// The note under the frames, like "35mm full frame · 3:2 · whole roll".
pub fn rollFormatNote(id: formats.Standard) [:0]const u8 {
    const f = id.format();
    return gui.print("{s} · {s} · {s}", .{ filmAndName(f), ratio(f.ratio()), i18n.t.labels.whole_roll });
}

/// The film and the format's name, like "35mm full frame" or "Glass plate · Half plate, 4¾×6½ in".
pub fn filmAndName(f: formats.Format) [:0]const u8 {
    if (namesSize(f.size)) return gui.print("{s} · {s}", .{ filmSizeName(f.size), nameOf(f) });
    return gui.print("{s} {s}", .{ filmSize(f.size), nameOf(f) });
}

/// The film size as people say it: "35mm" rather than "135".
pub fn filmSize(size: formats.FilmSize) []const u8 {
    return if (size == .@"135") "35mm" else filmSizeName(size);
}

/// The film size's name, like "120/220" or "Sheet film", as the Rolls page's filter lists it.
pub fn filmSizeName(size: formats.FilmSize) []const u8 {
    return switch (size) {
        .sheet => i18n.t.labels.film_size.sheet,
        .plate => i18n.t.labels.film_size.plate,
        .@"135", .@"120", .@"127", .@"110", .@"126", .aps, .minox => size.label(),
    };
}

fn capitalised(buffer: []u8, name: []const u8) []const u8 {
    const n = @min(buffer.len, name.len);
    @memcpy(buffer[0..n], name[0..n]);
    if (n > 0) buffer[0] = std.ascii.toUpper(buffer[0]);
    return buffer[0..n];
}

pub fn filmKind(kind: develop.FilmKind) []const u8 {
    return i18n.label(i18n.t.labels.film_kind, kind);
}

/// The film types, in the order the menus list them.
pub const film_kinds = [_]develop.FilmKind{ .colour_negative, .bw_negative, .colour_positive, .bw_positive };

/// A film size as the roll form lists it, like "135 (35mm)".
pub fn filmSizeChoice(size: formats.FilmSize) []const u8 {
    return switch (size) {
        .@"135" => "135 (35mm)",
        else => filmSizeName(size),
    };
}

/// A stock you can pick for a roll: its name, its film type and, if the maker publishes the
/// numbers for one, its preset.
pub const StockChoice = struct {
    name: []const u8,
    kind: develop.FilmKind,
    preset: ?*const minilab.stocks.Stock = null,
};

/// Common stocks whose makers don't publish the numbers for a preset. You can still name a roll
/// after them.
const unmeasured = [_]StockChoice{
    .{ .name = "Kentmere Pan 100", .kind = .bw_negative },
    .{ .name = "Kentmere Pan 200", .kind = .bw_negative },
    .{ .name = "Kentmere Pan 400", .kind = .bw_negative },
    .{ .name = "Agfa APX 100", .kind = .bw_negative },
    .{ .name = "Agfa APX 400", .kind = .bw_negative },
    .{ .name = "ADOX CMS 20 II", .kind = .bw_negative },
    .{ .name = "ADOX HR-50", .kind = .bw_negative },
    .{ .name = "ADOX Silvermax", .kind = .bw_negative },
    .{ .name = "Foma Retropan 320 Soft", .kind = .bw_negative },
    .{ .name = "Lucky New SHD100", .kind = .bw_negative },
    .{ .name = "Lucky New SHD400", .kind = .bw_negative },
    .{ .name = "Kodak ColorPlus 200", .kind = .colour_negative },
    .{ .name = "Kodak Kodacolor 100", .kind = .colour_negative },
    .{ .name = "Kodak Kodacolor 200", .kind = .colour_negative },
    .{ .name = "Harman Phoenix II", .kind = .colour_negative },
    .{ .name = "CineStill 400D", .kind = .colour_negative },
    .{ .name = "Lomography Color Negative 100", .kind = .colour_negative },
    .{ .name = "Lomography Color Negative 400", .kind = .colour_negative },
    .{ .name = "Lomography Color Negative 800", .kind = .colour_negative },
    .{ .name = "Lucky C200", .kind = .colour_negative },
    .{ .name = "Lucky C400", .kind = .colour_negative },
};

/// Every stock you can pick: the presets, the other names they're sold under, then the rest. A
/// name that has a preset now is left out of the rest.
pub const stock_choices = blk: {
    @setEvalBranchQuota(1_000_000);
    const presets = minilab.stocks.stocks;
    const aliases = minilab.stocks.aliases;
    var all: [presets.len + aliases.len + unmeasured.len]StockChoice = undefined;
    for (&presets, 0..) |*preset, i| all[i] = .{ .name = preset.name, .kind = preset.kind, .preset = preset };
    for (aliases, presets.len..) |alias, i| {
        const preset = minilab.stocks.named(alias.of).?;
        all[i] = .{ .name = alias.name, .kind = preset.kind, .preset = preset };
    }
    var n = presets.len + aliases.len;
    for (unmeasured) |choice| {
        const has_preset = for (presets) |preset| {
            if (std.mem.eql(u8, preset.name, choice.name)) break true;
        } else false;
        if (has_preset) continue;
        all[n] = choice;
        n += 1;
    }
    const final = all[0..n].*;
    break :blk final;
};

/// Writes the names of the stocks of film type `kind` into `buffer`, followed by `last`, and
/// returns them.
pub fn stockNames(kind: develop.FilmKind, last: []const u8, buffer: *[stock_choices.len + 1][]const u8) [][]const u8 {
    var n: usize = 0;
    for (stock_choices) |choice| {
        if (choice.kind != kind) continue;
        buffer[n] = choice.name;
        n += 1;
    }
    buffer[n] = last;
    return buffer[0 .. n + 1];
}

/// The stock called `name`, if there is one.
pub fn findStock(name: []const u8) ?StockChoice {
    for (stock_choices) |choice| if (std.mem.eql(u8, choice.name, name)) return choice;
    return null;
}

/// How well the stock called `name` suits infrared dust removal, or null when it's not a preset
/// and there's no telling.
pub fn infraredFit(name: ?[]const u8) ?minilab.infrared.Fit {
    const choice = findStock(name orelse return null) orelse return null;
    const preset = choice.preset orelse return null;
    return preset.infraredFit();
}

/// How dust is found, as the dust section's choice names it.
pub fn dustFinder(finder: minilab.dust.Finder) [:0]const u8 {
    return i18n.label(i18n.t.labels.dust_finder, finder);
}

/// The datasheet gammas of the stock called `name`, when its preset has them.
pub fn stockGamma(name: ?[]const u8) ?[3]f32 {
    const choice = findStock(name orelse return null) orelse return null;
    const preset = choice.preset orelse return null;
    return preset.gamma;
}

/// Bytes in a megabyte, as sizes on screen count them.
const bytes_per_megabyte = 1_000_000;

/// `bytes` in whole megabytes.
pub fn megabytes(bytes: u64) u64 {
    return bytes / bytes_per_megabyte;
}

/// Why a .cube file couldn't be imported, for the notice.
pub fn importError(err: anyerror) []const u8 {
    const says = &i18n.t.labels.import_error;
    return switch (err) {
        error.NotACube => says.not_a_cube,
        error.BadSize => gui.say(says.bad_size, .{ minilab.cube_lut.min_size, minilab.cube_lut.max_size_3d }),
        error.Truncated => says.truncated,
        error.TooMuchData => says.too_much_data,
        error.InvalidNumber => says.invalid_number,
        error.FileTooBig => gui.say(says.file_too_big, .{looks.max_cube_bytes >> 20}),
        error.NoLibrary => says.no_library,
        else => @errorName(err),
    };
}

// The names of the core's choices, for the screen. The core's own `label` functions stay in
// English, for the command line.

pub fn tone(t: develop.Tone) []const u8 {
    return i18n.label(i18n.t.labels.tone, t);
}

pub fn whiteBalance(balance: develop.WhiteBalance) []const u8 {
    return i18n.label(i18n.t.labels.white_balance, balance);
}

pub fn range(r: develop.Range) []const u8 {
    return i18n.label(i18n.t.labels.range, r);
}

/// Where a roll's scans come from.
pub fn input(i: minilab.roll.Input) []const u8 {
    return i18n.label(i18n.t.labels.input, i);
}

/// The look's name: a built-in look's translated, any other's as it is.
pub fn look(id: *const looks.Id) []const u8 {
    return switch (id.kind()) {
        .builtin => |b| builtinLook(b),
        .bundled, .cube, .fitted => id.label(),
    };
}

pub fn builtinLook(b: looks.Builtin) []const u8 {
    return i18n.label(i18n.t.labels.builtin_look, b);
}

/// The kind of film a bundled look emulates.
pub fn lookFilm(film: minilab.bundled_looks.Film) []const u8 {
    return i18n.label(i18n.t.labels.look_film, film);
}

pub fn holder(h: minilab.frames.Holder) [:0]const u8 {
    return i18n.label(i18n.t.labels.holder, h);
}

pub fn exportStage(stage: minilab.@"export".Stage) []const u8 {
    return i18n.label(i18n.t.labels.export_stage, stage);
}

/// How a reference picture is turned or mirrored, or nothing when it's upright.
pub fn orientation(o: minilab.looks.register.Orientation) []const u8 {
    return switch (o) {
        .upright => "",
        inline else => |tag| @field(i18n.t.labels.orientation, @tagName(tag)),
    };
}

/// Where a look's reference pictures come from, as the menu lists it.
pub fn references(source: minilab.looks.draft.Source) []const u8 {
    return i18n.label(i18n.t.labels.references, source);
}

/// The same, shortened for the list of looks.
pub fn referencesShort(source: minilab.looks.draft.Source) []const u8 {
    return i18n.label(i18n.t.labels.references_short, source);
}

/// A single reference picture from `source`, for a column header or a caption.
pub fn referenceOne(source: minilab.looks.draft.Source) []const u8 {
    return i18n.label(i18n.t.labels.reference_one, source);
}

test "formats, sizes and ratios read the way people say them" {
    try std.testing.expectEqualStrings("Full frame, 36 × 24", format(.@"135_full_frame"));
    try std.testing.expectEqualStrings("135 · full frame, 36 × 24", filmAndFormat(.@"135_full_frame"));
    try std.testing.expectEqualStrings("36 × 24 mm · 3:2", sizeAndRatio(.@"135_full_frame"));
    try std.testing.expectEqualStrings("35mm full frame · 3:2 · whole roll", rollFormatNote(.@"135_full_frame"));
    try std.testing.expectEqualStrings("Glass plate · Half plate, 4¾×6½ in", filmAndName(formats.Standard.plate_half.format()));
    try std.testing.expectEqualStrings("Sheet film · 4×5 in", filmAndFormat(.sheet_4x5in));
    try std.testing.expectEqualStrings("Glass plate · Quarter plate, 3¼×4¼ in", filmAndFormat(.plate_quarter));
    try std.testing.expectEqualStrings("Lantern slide, 3¼×3¼ in", format(.lantern_slide));
    try std.testing.expectEqualStrings("4:5", ratio(0.8));
    try std.testing.expectEqualStrings("1.85:1", ratio(1.85));
    try std.testing.expectEqualStrings("135 (35mm)", filmSizeChoice(.@"135"));
    try std.testing.expectEqualStrings("120/220", filmSizeChoice(.@"120"));
}

test "frames are numbered from 01" {
    try std.testing.expectEqualStrings("01", frameNumber(0));
    try std.testing.expectEqualStrings("12", frameNumber(11));
    try std.testing.expectEqualStrings("Roll 002 / 03", rollFrame("Roll 002", 2));
}

test "stocks are listed by film type, with the last choice after them" {
    var buffer: [stock_choices.len + 1][]const u8 = undefined;
    const names = stockNames(.colour_negative, "Other", &buffer);
    try std.testing.expectEqualStrings("Other", names[names.len - 1]);
    for (names[0 .. names.len - 1]) |name| try std.testing.expectEqual(develop.FilmKind.colour_negative, findStock(name).?.kind);
    try std.testing.expect(findStock("Kodak Portra 400").?.preset != null);
    try std.testing.expectEqualStrings("Kodak Portra 400", findStock("Kodak Ektacolor Pro 400").?.preset.?.name);
    try std.testing.expectEqual(@as(?StockChoice, null), findStock("Not a stock"));
    try std.testing.expectEqual(@as(?[3]f32, null), stockGamma(null));
}

test "import errors say what's wrong" {
    try std.testing.expectEqualStrings("size outside 2 to 129 points a side", importError(error.BadSize));
    try std.testing.expectEqualStrings("over 64 MB", importError(error.FileTooBig));
    try std.testing.expectEqualStrings("AccessDenied", importError(error.AccessDenied));
}
