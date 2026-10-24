//! The film's holes and edge print, drawn the same way on the Rolls cards and on Scan's preview.

const std = @import("std");
const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");
const fonts = @import("../ui/fonts.zig");
const labels = @import("labels.zig");

const formats = minilab.formats;

/// The edge print's text as a share of the edge it's on, and the smallest size it's drawn at, in
/// screen pixels. Smaller than that, it's just noise.
const edge_text_share = 0.6;
const min_edge_text = 3;
/// Where a frame's number goes after the frame starts, and the space after it, in mm.
const edge_lead_mm = 1;
const edge_space_mm = 2;
/// The arrow before the half-frame number, as a share of the text's size.
const edge_arrow_share = 0.5;
/// The longest stock name the edge print holds.
const max_edge_name = 48;

/// A maker whose edge print comes out in a colour of its own on a contact print, and the name it
/// prints when that's not how its stocks' names start.
const EdgeMaker = struct { maker: []const u8, ink: theme.Color, written: ?[]const u8 = null };
const edge_makers = [_]EdgeMaker{
    .{ .maker = "Kodak", .ink = theme.edge_kodak },
    .{ .maker = "Fujifilm", .ink = theme.edge_fuji, .written = "FUJI" },
};

/// A strip of film on screen. Along is the film's length and across is its width.
pub const Strip = struct {
    /// The screen axis the film runs along.
    axis: enum { x, y },
    /// The strip's ends along the film, in screen pixels.
    start: f32,
    end: f32,
    /// The strip's edges across the film, in screen pixels.
    near: f32,
    far: f32,
    /// Screen pixels per millimetre, along the film and across it.
    along_per_mm: f32,
    across_per_mm: f32,

    /// Fills the rectangle from `from` to `to` along the film and `top` to `bottom` across it,
    /// cut off at the strip's ends.
    fn fill(strip: Strip, list: *c.ImDrawList, from: f32, to: f32, top: f32, bottom: f32, colour: theme.Color, rounding: f32) void {
        const first = @max(from, strip.start);
        const last = @min(to, strip.end);
        if (last <= first) return;
        const min, const max = switch (strip.axis) {
            .x => .{ gui.vec2(first, top), gui.vec2(last, bottom) },
            .y => .{ gui.vec2(top, first), gui.vec2(bottom, last) },
        };
        c.ImDrawList_AddRectFilledEx(list, min, max, theme.imU32(colour), rounding, 0);
    }

    /// Draws `text` in the current font, `size` high, from `at` along the film and centred on
    /// `middle` across it, reading along the film. Returns its length. Text that would run past
    /// the strip's ends isn't drawn.
    fn label(strip: Strip, list: *c.ImDrawList, at: f32, middle: f32, size: f32, colour: u32, text: [:0]const u8) f32 {
        const length = c.ImGui_CalcTextSize(text).x;
        if (at < strip.start or at + length > strip.end) return length;
        switch (strip.axis) {
            .x => c.ImDrawList_AddText(list, gui.vec2(at, middle - size / 2), colour, text),
            .y => {
                // Drawn level, then turned to read down the film.
                const pivot = gui.vec2(middle + size / 2, at);
                const first = list.*.VtxBuffer.Size;
                c.ImDrawList_AddText(list, pivot, colour, text);
                gui.turnSince(list, first, pivot, .down);
            },
        }
        return length;
    }

    /// Draws an arrow pointing along the film, `size` long, starting at `at` along it and centred
    /// on `middle` across it.
    fn arrow(strip: Strip, list: *c.ImDrawList, at: f32, middle: f32, size: f32, colour: u32) void {
        if (at < strip.start or at + size > strip.end) return;
        const half = size / 2;
        switch (strip.axis) {
            .x => c.ImDrawList_AddTriangleFilled(list, gui.vec2(at, middle - half), gui.vec2(at, middle + half), gui.vec2(at + size, middle), colour),
            .y => c.ImDrawList_AddTriangleFilled(list, gui.vec2(middle + half, at), gui.vec2(middle - half, at), gui.vec2(middle, at + size), colour),
        }
    }
};

/// Draws rows of perforations along both edges of `strip`, one of them starting at `phase`, so
/// they keep in step with the frames the way a camera advances the film.
pub fn rows(list: *c.ImDrawList, strip: Strip, holes: formats.Perforations, phase: f32, colour: theme.Color) void {
    const pitch = holes.pitch_mm * strip.along_per_mm;
    const length = holes.length_mm * strip.along_per_mm;
    const inset = holes.inset_mm * strip.across_per_mm;
    const height = holes.height_mm * strip.across_per_mm;
    const radius = @min(length, height) / 4;
    var at = phase - @ceil((phase - strip.start) / pitch) * pitch;
    while (at < strip.end) : (at += pitch) {
        strip.fill(list, at, at + length, strip.near + inset, strip.near + inset + height, colour, radius);
        strip.fill(list, at, at + length, strip.far - inset - height, strip.far - inset, colour, radius);
    }
}

/// Draws `count` registration holes along the near edge of `strip`, centred on `start`, where a
/// frame starts.
pub fn atFrame(list: *c.ImDrawList, strip: Strip, count: usize, start: f32, colour: theme.Color) void {
    // These sizes are our own drawing sizes, since we don't have the formats' real ones to hand.
    const hole = formats.registration_hole;
    const side = hole.size_mm * strip.across_per_mm;
    const top = strip.near + hole.inset_mm * strip.across_per_mm;
    for (0..count) |k| {
        const offset = (@as(f32, @floatFromInt(k)) - @as(f32, @floatFromInt(count - 1)) / 2) * hole.spacing_mm * strip.along_per_mm;
        strip.fill(list, start + offset - side / 2, start + offset + side / 2, top, top + side, colour, side / 4);
    }
}

/// What a film's maker prints along its edge: the stock's name the way the maker writes it, and
/// the colour it comes out on a contact print.
pub const EdgePrint = struct {
    buffer: [max_edge_name + 1]u8 = @splat(0),
    len: usize = 0,
    ink: theme.Color = theme.edge_plain,

    /// The edge print for a roll of `stock`, or just the frame numbers when there's no stock.
    /// Notes in brackets, like a push, aren't printed, and Fujifilm writes FUJI.
    pub fn of(stock: ?[]const u8) EdgePrint {
        var print: EdgePrint = .{};
        const full = stock orelse return print;
        const name = std.mem.trim(u8, full[0 .. std.mem.indexOfScalar(u8, full, '(') orelse full.len], " ");
        const first = name[0 .. std.mem.indexOfScalar(u8, name, ' ') orelse name.len];
        // The preset knows the maker of a stock sold under another name, like Eastman's. Other
        // stocks start with their maker's name.
        const preset = if (labels.findStock(full)) |choice| choice.preset else null;
        const maker = if (preset) |p| p.maker else first;
        var written = first;
        for (edge_makers) |known| {
            if (!std.ascii.eqlIgnoreCase(known.maker, maker)) continue;
            print.ink = known.ink;
            if (std.ascii.eqlIgnoreCase(known.maker, first)) written = known.written orelse first;
        }
        for ([_][]const u8{ written, name[first.len..] }) |part| {
            for (part) |ch| {
                if (print.len == max_edge_name) break;
                print.buffer[print.len] = std.ascii.toUpper(ch);
                print.len += 1;
            }
        }
        return print;
    }

    /// The stock's name as it's printed.
    pub fn text(print: *const EdgePrint) [:0]const u8 {
        return print.buffer[0..print.len :0];
    }
};

/// How wide the edge print's edge is on film of `size`, in mm: between the film's edge and its
/// holes, or the clear film beside a picture `picture_mm` high. Null for film with no edge to
/// print on, like sheet film.
pub fn edgeMm(size: formats.FilmSize, picture_mm: f32) ?f32 {
    if (size.perforations()) |p| return p.inset_mm;
    const film = size.filmWidthMm() orelse return null;
    const edge = (film - picture_mm) / 2;
    return if (edge > 0) edge else null;
}

/// Draws one frame's edge print along the far edge of `strip`, `edge_mm` wide, in `ink`: the
/// frame's number where it starts, the stock's name after it, and its half-frame number after an
/// arrow, halfway to the next frame `pitch` on.
pub fn edgePrint(list: *c.ImDrawList, strip: Strip, print: *const EdgePrint, start: f32, pitch: f32, number: usize, edge_mm: f32, ink: theme.Color) void {
    const edge = edge_mm * strip.across_per_mm;
    const size = edge * edge_text_share;
    if (size < min_edge_text) return;
    const middle = strip.far - edge / 2;
    fonts.pushPixels(.semibold, size);
    defer fonts.pop();
    const colour = theme.imU32(ink);
    var at = start + edge_lead_mm * strip.along_per_mm;
    at += strip.label(list, at, middle, size, colour, gui.print("{d}", .{number})) + edge_space_mm * strip.along_per_mm;
    const half = start + pitch / 2;
    const name = print.text();
    if (name.len > 0 and at + c.ImGui_CalcTextSize(name).x < half - size) _ = strip.label(list, at, middle, size, colour, name);
    strip.arrow(list, half - size, middle, size * edge_arrow_share, colour);
    _ = strip.label(list, half, middle, size, colour, gui.print("{d}A", .{number}));
}

test "the edge print reads the way the maker writes it, in the maker's ink" {
    const portra: EdgePrint = .of("Kodak Portra 800 (push 1, EI 1600)");
    try std.testing.expectEqualStrings("KODAK PORTRA 800", portra.text());
    try std.testing.expectEqual(theme.edge_kodak, portra.ink);
    const superia: EdgePrint = .of("Fujifilm Superia X-TRA 400");
    try std.testing.expectEqualStrings("FUJI SUPERIA X-TRA 400", superia.text());
    try std.testing.expectEqual(theme.edge_fuji, superia.ink);
    const hp5: EdgePrint = .of("Ilford HP5 Plus");
    try std.testing.expectEqualStrings("ILFORD HP5 PLUS", hp5.text());
    try std.testing.expectEqual(theme.edge_plain, hp5.ink);
    // Sold under another name, in its maker's ink.
    const double_x: EdgePrint = .of("Eastman Double-X 5222");
    try std.testing.expectEqualStrings("EASTMAN DOUBLE-X 5222", double_x.text());
    try std.testing.expectEqual(theme.edge_kodak, double_x.ink);
    const velvia: EdgePrint = .of("Fujichrome Velvia 50");
    try std.testing.expectEqualStrings("FUJICHROME VELVIA 50", velvia.text());
    try std.testing.expectEqual(theme.edge_fuji, velvia.ink);
    // A stock with no preset goes by the first word of its name.
    const colorplus: EdgePrint = .of("Kodak ColorPlus 200");
    try std.testing.expectEqualStrings("KODAK COLORPLUS 200", colorplus.text());
    try std.testing.expectEqual(theme.edge_kodak, colorplus.ink);
    // Without a stock, only the frame numbers are printed.
    try std.testing.expectEqualStrings("", EdgePrint.of(null).text());
}

test "the edge print goes between the film's edge and its holes, or beside the picture" {
    try std.testing.expectEqual(formats.FilmSize.@"135".perforations().?.inset_mm, edgeMm(.@"135", 24).?);
    // 120 has no holes: the clear film beside a 56 mm picture.
    const film_120 = formats.FilmSize.@"120".filmWidthMm().?;
    try std.testing.expectApproxEqAbs((film_120 - 56) / 2, edgeMm(.@"120", 56).?, 1e-4);
}
