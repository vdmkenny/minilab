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
fn ratio(r: f32) []const u8 {
    const known = [_]struct { f32, []const u8 }{ .{ 1.5, "3:2" }, .{ 1.0, "1:1" }, .{ 4.0 / 3.0, "4:3" }, .{ 0.75, "3:4" }, .{ 2.0 / 3.0, "2:3" }, .{ 1.25, "5:4" }, .{ 2.0, "2:1" }, .{ 3.0, "3:1" } };
    for (known) |k| if (@abs(r - k[0]) < 0.02) return k[1];
    return gui.print("{d:.2}:1", .{r});
}

/// The note under the frames, like "35mm full frame, 3:2, for the whole roll."
pub fn rollFormatNote(id: formats.Standard) [:0]const u8 {
    const f = id.format();
    return gui.print("{s} {s}, {s}, for the whole roll.", .{ filmSize(f.size), f.name, ratio(f.ratio()) });
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

pub const film_kinds = [_]develop.FilmKind{ .colour_negative, .bw_negative, .colour_positive, .bw_positive };
pub const film_kind_labels = blk: {
    var names: [film_kinds.len][]const u8 = undefined;
    for (&names, film_kinds) |*n, k| n.* = filmKind(k);
    break :blk names;
};

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
    for (&presets, 0..) |*preset, i| all[i] = .{ .name = preset.name, .kind = @field(develop.FilmKind, @tagName(preset.kind)), .preset = preset };
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
