//! How formats, films and stocks are written in the interface.

const std = @import("std");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");

const formats = minilab.formats;
const develop = minilab.develop;

/// The format's name and its size in mm, along the film × across it, like "Full frame, 36 × 24".
/// Sheet film names already include their size.
pub fn format(id: formats.Standard) [:0]const u8 {
    const f = id.format();
    if (f.size == .sheet) return gui.print("{s}", .{f.name});
    var name_buffer: [32]u8 = undefined;
    const name = capitalised(&name_buffer, f.name);
    return gui.print("{s}, {d} × {d}", .{ name, f.width_mm, f.height_mm });
}

/// The film size and the format, like "135 · full frame, 36 × 24", for the roll cards.
pub fn filmAndFormat(id: formats.Standard) [:0]const u8 {
    const f = id.format();
    if (f.size == .sheet) return gui.print("Sheet film · {s}", .{f.name});
    return gui.print("{s} · {s}, {d} × {d}", .{ f.size.label(), f.name, f.width_mm, f.height_mm });
}

/// The size and the ratio, like "36 × 24 mm · 3:2", for the viewer's info line.
pub fn sizeAndRatio(id: formats.Standard) [:0]const u8 {
    const f = id.format();
    return gui.print("{d} × {d} mm · {s}", .{ f.width_mm, f.height_mm, ratio(f.ratio()) });
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
    return gui.print("{s} {s} · {s} · whole roll", .{ filmSize(f.size), f.name, ratio(f.ratio()) });
}

/// The film size as people say it: "35mm" rather than "135".
pub fn filmSize(size: formats.FilmSize) []const u8 {
    return if (size == .@"135") "35mm" else size.label();
}

fn capitalised(buffer: []u8, name: []const u8) []const u8 {
    const n = @min(buffer.len, name.len);
    @memcpy(buffer[0..n], name[0..n]);
    if (n > 0) buffer[0] = std.ascii.toUpper(buffer[0]);
    return buffer[0..n];
}

pub fn filmKind(kind: develop.FilmKind) []const u8 {
    return switch (kind) {
        .colour_negative => "Color negative",
        .bw_negative => "B&W negative",
        .colour_positive => "Color positive",
        .bw_positive => "B&W positive",
    };
}

/// The film types, in the order the menus list them.
pub const film_kinds = [_]develop.FilmKind{ .colour_negative, .bw_negative, .colour_positive, .bw_positive };

/// A film size as the roll form lists it, like "135 (35mm)".
pub fn filmSizeChoice(size: formats.FilmSize) []const u8 {
    return switch (size) {
        .@"135" => "135 (35mm)",
        else => size.label(),
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
    .{ .name = "Ilford HP5 Plus", .kind = .bw_negative },
    .{ .name = "Ilford FP4 Plus", .kind = .bw_negative },
    .{ .name = "Ilford Delta 100 Professional", .kind = .bw_negative },
    .{ .name = "Ilford Delta 3200 Professional", .kind = .bw_negative },
    .{ .name = "Ilford Pan F Plus", .kind = .bw_negative },
    .{ .name = "Ilford XP2 Super", .kind = .bw_negative },
    .{ .name = "Kentmere Pan 100", .kind = .bw_negative },
    .{ .name = "Kentmere Pan 400", .kind = .bw_negative },
    .{ .name = "Kodak T-Max P3200", .kind = .bw_negative },
    .{ .name = "Fujifilm Acros 100 II", .kind = .bw_negative },
    .{ .name = "Kodak ColorPlus 200", .kind = .colour_negative },
    .{ .name = "Kodak Pro Image 100", .kind = .colour_negative },
    .{ .name = "Fujifilm Superia 200", .kind = .colour_negative },
    .{ .name = "Harman Phoenix 200", .kind = .colour_negative },
    .{ .name = "CineStill 400D", .kind = .colour_negative },
    .{ .name = "CineStill 50D", .kind = .colour_negative },
    .{ .name = "Lomography Color Negative 100", .kind = .colour_negative },
    .{ .name = "Lomography Color Negative 400", .kind = .colour_negative },
    .{ .name = "Lomography Color Negative 800", .kind = .colour_negative },
    .{ .name = "Fujichrome Velvia 50", .kind = .colour_positive },
};

/// Every stock you can pick: the presets first, then the rest. A name that has a preset now is
/// left out of the rest.
pub const stock_choices = blk: {
    @setEvalBranchQuota(1_000_000);
    const presets = minilab.stocks.stocks;
    var all: [presets.len + unmeasured.len]StockChoice = undefined;
    for (&presets, 0..) |*preset, i| all[i] = .{ .name = preset.name, .kind = preset.kind, .preset = preset };
    var n = presets.len;
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

/// The datasheet gammas of the stock called `name`, when its preset has them.
pub fn stockGamma(name: ?[]const u8) ?[3]f32 {
    const choice = findStock(name orelse return null) orelse return null;
    const preset = choice.preset orelse return null;
    return preset.gamma;
}

/// Why a .cube file couldn't be imported, for the notice.
pub fn importError(err: anyerror) []const u8 {
    return switch (err) {
        error.NotACube => "not a .cube LUT",
        error.BadSize => gui.print("size outside {d} to {d} points a side", .{ minilab.cube_lut.min_size, minilab.cube_lut.max_size_3d }),
        error.Truncated => "file ends early",
        error.TooMuchData => "more values than its size",
        error.InvalidNumber => "value not a number",
        error.FileTooBig => gui.print("over {d} MB", .{minilab.look.max_cube_bytes >> 20}),
        error.NoLibrary => "no library open",
        else => @errorName(err),
    };
}

test "formats, sizes and ratios read the way people say them" {
    try std.testing.expectEqualStrings("Full frame, 36 × 24", format(.@"135_full_frame"));
    try std.testing.expectEqualStrings("135 · full frame, 36 × 24", filmAndFormat(.@"135_full_frame"));
    try std.testing.expectEqualStrings("36 × 24 mm · 3:2", sizeAndRatio(.@"135_full_frame"));
    try std.testing.expectEqualStrings("35mm full frame · 3:2 · whole roll", rollFormatNote(.@"135_full_frame"));
    try std.testing.expectEqualStrings("Sheet film · 4×5 in", filmAndFormat(.sheet_4x5in));
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
    try std.testing.expectEqual(@as(?StockChoice, null), findStock("Not a stock"));
    try std.testing.expectEqual(@as(?[3]f32, null), stockGamma(null));
}

test "import errors say what's wrong" {
    try std.testing.expectEqualStrings("size outside 2 to 129 points a side", importError(error.BadSize));
    try std.testing.expectEqualStrings("over 64 MB", importError(error.FileTooBig));
    try std.testing.expectEqualStrings("AccessDenied", importError(error.AccessDenied));
}
