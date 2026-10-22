//! What an exported file says about itself besides its pixels: the roll's camera, lens, film
//! stock, date and copyright, how the frame was developed, its resolution and its colour space.
//!
//! It is written two ways. XMP, an XML packet, goes in a sidecar file next to the export and
//! inside it too: a TIFF holds it in tag 700, a JPEG in an APP1 segment. EXIF, a small TIFF
//! directory of numbered tags, goes inside both: in a TIFF, its tags join the file's own
//! directory; in a JPEG, it is another APP1 segment. The codecs write neither, so both are added
//! to the bytes the codecs make.
//!
//! EXIF has no field for the film stock or the develop settings; those are in the XMP only, in
//! minilab's own namespace.

const std = @import("std");
const image = @import("image.zig");
const develop = @import("develop.zig");
const look = @import("look.zig");
const icc = @import("../io/codecs/icc.zig");

pub const Metadata = struct {
    camera: ?[]const u8 = null,
    lens: ?[]const u8 = null,
    stock: ?[]const u8 = null,
    /// When the roll was shot, as the roll says it. Dates such as 2026, 2026-10 or 2026-10-22 are
    /// written as dates; anything else as text in minilab's namespace.
    shot: ?[]const u8 = null,
    copyright: ?[]const u8 = null,
    /// How the frame was developed.
    develop: ?Develop = null,
    /// Pixels per inch of film in the file, when the scan's resolution is known.
    dpi: ?f32 = null,
    /// The colour space of the pixels, which the embedded ICC profile describes too.
    space: icc.Space = .srgb,
    /// The file's size in pixels.
    width: usize = 0,
    height: usize = 0,
};

pub const Develop = struct {
    look: look.Id,
    kind: develop.FilmKind,
    /// The frame's saved settings, or null when it was never developed and the export worked out
    /// automatic ones.
    settings: ?develop.Settings = null,
    /// The scanner, as the roll names it.
    scanner: ?[]const u8 = null,
    /// The part of the scan exported, in the scan's pixels; null for all of it.
    crop: ?image.Area = null,
    quarter_turns: u2 = 0,
};

/// The name LittleCMS's profiles give each space, which XMP repeats.
pub fn spaceName(space: icc.Space) []const u8 {
    return switch (space) {
        .srgb => "sRGB",
        .display_p3 => "Display P3",
        .adobe_rgb => "Adobe RGB (compatible)",
        .prophoto => "ProPhoto RGB",
        .rec2020_linear => "Rec. 2020 linear",
    };
}

/// minilab's XMP namespace, for what no standard schema has a property for.
pub const namespace = "urn:minilab:xmp:1.0/";

// XMP ------------------------------------------------------------------------------------------

/// The XMP packet for `metadata`, as a sidecar file holds it and as it is embedded. The caller
/// owns the bytes.
pub fn xmp(gpa: std.mem.Allocator, metadata: Metadata) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeXmp(&out.writer, metadata) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeXmp(w: *std.Io.Writer, m: Metadata) std.Io.Writer.Error!void {
    // The packet header's id is fixed by the XMP specification; the byte-order mark tells
    // scanners the packet is UTF-8.
    try w.writeAll("<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n");
    try w.writeAll("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"minilab\">\n");
    try w.writeAll(" <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n");
    try w.writeAll("  <rdf:Description rdf:about=\"\"\n");
    try w.writeAll("    xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"\n");
    try w.writeAll("    xmlns:dc=\"http://purl.org/dc/elements/1.1/\"\n");
    try w.writeAll("    xmlns:tiff=\"http://ns.adobe.com/tiff/1.0/\"\n");
    try w.writeAll("    xmlns:exif=\"http://ns.adobe.com/exif/1.0/\"\n");
    try w.writeAll("    xmlns:exifEX=\"http://cipa.jp/exif/1.0/\"\n");
    try w.writeAll("    xmlns:aux=\"http://ns.adobe.com/exif/1.0/aux/\"\n");
    try w.writeAll("    xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"\n");
    try w.writeAll("    xmlns:minilab=\"" ++ namespace ++ "\"\n");
    try w.writeAll("    xmp:CreatorTool=\"minilab\"\n");
    try w.print("    photoshop:ICCProfile=\"{s}\"\n", .{spaceName(m.space)});
    if (m.width > 0) try w.print("    tiff:ImageWidth=\"{d}\"\n    tiff:ImageLength=\"{d}\"\n", .{ m.width, m.height });
    if (m.dpi) |dpi| {
        const r = rational(dpi);
        try w.print("    tiff:XResolution=\"{d}/{d}\"\n    tiff:YResolution=\"{d}/{d}\"\n    tiff:ResolutionUnit=\"2\"\n", .{ r[0], r[1], r[0], r[1] });
    }
    if (m.camera) |v| try attribute(w, "tiff:Model", v);
    if (m.lens) |v| {
        try attribute(w, "exifEX:LensModel", v);
        try attribute(w, "aux:Lens", v);
    }
    if (m.shot) |v| {
        if (isoDate(v) != null) {
            try attribute(w, "exif:DateTimeOriginal", v);
            try attribute(w, "photoshop:DateCreated", v);
        } else try attribute(w, "minilab:Shot", v);
    }
    if (m.stock) |v| try attribute(w, "minilab:FilmStock", v);
    if (m.develop) |d| try writeDevelop(w, d);
    try w.writeAll("  >\n");
    if (m.copyright) |v| {
        try w.writeAll("   <dc:rights>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">");
        try escaped(w, v);
        try w.writeAll("</rdf:li>\n    </rdf:Alt>\n   </dc:rights>\n");
    }
    try w.writeAll("  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>\n");
}

fn writeDevelop(w: *std.Io.Writer, d: Develop) std.Io.Writer.Error!void {
    try attribute(w, "minilab:Look", d.look.label());
    try w.print("    minilab:FilmType=\"{t}\"\n", .{d.kind});
    if (d.scanner) |v| try attribute(w, "minilab:Scanner", v);
    if (d.crop) |a| try w.print("    minilab:Crop=\"{d} {d} {d} {d}\"\n", .{ a.x, a.y, a.width, a.height });
    try w.print("    minilab:QuarterTurns=\"{d}\"\n", .{d.quarter_turns});
    const s = d.settings orelse {
        try w.writeAll("    minilab:Settings=\"automatic\"\n");
        return;
    };
    try w.writeAll("    minilab:Settings=\"saved\"\n");
    try w.print("    minilab:FilmBase=\"{d:.5} {d:.5} {d:.5}\"\n", .{ s.base[0], s.base[1], s.base[2] });
    try w.print("    minilab:BaseSource=\"{t}\"\n", .{s.base_source});
    try w.print("    minilab:Tone=\"{t}\"\n", .{s.tone});
    try w.print("    minilab:Saturation=\"{d:.2}\"\n", .{s.saturation});
    try w.print("    minilab:WhiteBalance=\"{t}\"\n", .{s.white_balance});
    try w.print("    minilab:DensityRange=\"{d:.4}\"\n", .{s.density_range});
    try w.print("    minilab:Offset=\"{d:.4}\"\n", .{s.offset});
    try w.print("    minilab:Contrast=\"{d:.4}\"\n", .{s.contrast});
    try w.print("    minilab:Black=\"{d:.4}\"\n", .{s.black});
    try w.print("    minilab:RollOff=\"{d:.4}\"\n", .{s.roll_off});
    try w.print("    minilab:Exposure=\"{d:.4}\"\n", .{s.exposure});
    try w.print("    minilab:HighlightBalance=\"{d:.4} {d:.4} {d:.4}\"\n", .{ s.highlight_balance[0], s.highlight_balance[1], s.highlight_balance[2] });
    try w.print("    minilab:ShadowBalance=\"{d:.4} {d:.4} {d:.4}\"\n", .{ s.shadow_balance[0], s.shadow_balance[1], s.shadow_balance[2] });
    // Highlights, midtones, shadows, as `develop.Range` orders them.
    try w.print("    minilab:Temperature=\"{d:.1} {d:.1} {d:.1}\"\n", .{ s.temperature[0], s.temperature[1], s.temperature[2] });
    try w.print("    minilab:Tint=\"{d:.1} {d:.1} {d:.1}\"\n", .{ s.tint[0], s.tint[1], s.tint[2] });
    try w.writeAll("    minilab:Matrix=\"");
    for (s.matrix, 0..) |row, i| {
        for (row, 0..) |v, j| try w.print("{s}{d:.4}", .{ if (i + j == 0) "" else " ", v });
    }
    try w.writeAll("\"\n");
}

fn attribute(w: *std.Io.Writer, name: []const u8, value: []const u8) std.Io.Writer.Error!void {
    try w.print("    {s}=\"", .{name});
    try escaped(w, value);
    try w.writeAll("\"\n");
}

/// `text` as XML character data or an attribute value: markup characters escaped, and control
/// characters, which XML 1.0 doesn't allow, as spaces.
fn escaped(w: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    for (text) |ch| switch (ch) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\t', '\n', '\r' => try w.writeByte(ch),
        0...8, 11, 12, 14...31, 127 => try w.writeByte(' '),
        else => try w.writeByte(ch),
    };
}

/// A date of ISO 8601's three precisions, as found in `text`.
const Date = struct { year: u16, month: ?u8 = null, day: ?u8 = null };

fn isoDate(text: []const u8) ?Date {
    if (text.len != 4 and text.len != 7 and text.len != 10) return null;
    var date: Date = .{ .year = std.fmt.parseInt(u16, text[0..4], 10) catch return null };
    if (text.len >= 7) {
        if (text[4] != '-') return null;
        const month = std.fmt.parseInt(u8, text[5..7], 10) catch return null;
        if (month < 1 or month > 12) return null;
        date.month = month;
    }
    if (text.len == 10) {
        if (text[7] != '-') return null;
        const day = std.fmt.parseInt(u8, text[8..10], 10) catch return null;
        if (day < 1 or day > 31) return null;
        date.day = day;
    }
    return date;
}

/// `value` as a fraction: whole numbers over 1, else to a hundredth.
fn rational(value: f32) [2]u32 {
    // Far beyond any scanner, and within a u32 a hundred times over.
    const v = std.math.clamp(value, 0, 1e7);
    if (@round(v) == v) return .{ @intFromFloat(v), 1 };
    return .{ @intFromFloat(@round(v * 100)), 100 };
}

// EXIF -----------------------------------------------------------------------------------------

/// TIFF's value types, as its directory entries number them.
const Type = enum(u16) {
    byte = 1,
    ascii = 2,
    short = 3,
    long = 4,
    rational = 5,
    undefined = 7,
};

/// One entry of a TIFF directory (IFD).
const Entry = struct {
    tag: u16,
    type: u16,
    count: u32,
    /// The value, little-endian. Up to four bytes go in the entry; longer values after the
    /// directory, with the entry pointing at them.
    value: []const u8,
    /// Whether `value` is the four value bytes of an entry read from a file, which may be an
    /// offset into that file: copied as they are.
    raw: bool = false,
};

/// The tags written, from TIFF 6.0 and EXIF 2.32.
const Tag = struct {
    const model = 272;
    const x_resolution = 282;
    const y_resolution = 283;
    const resolution_unit = 296;
    const software = 305;
    const xmp = 700;
    const copyright = 33432;
    const exif_ifd = 34665;
    const exif_version = 36864;
    const date_time_original = 36867;
    const colour_space = 40961;
    const pixel_x_dimension = 40962;
    const pixel_y_dimension = 40963;
    const lens_model = 42036;
};

const resolution_in_inches = 2;
/// EXIF's colour space values: sRGB, or anything else, which the ICC profile then says.
const exif_srgb = 1;
const exif_uncalibrated = 0xFFFF;
const exif_version = "0232";

/// Builds entries, their values kept in an arena.
const Entries = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Entry) = .empty,

    fn add(e: *Entries, tag: u16, kind: Type, count: u32, value: []const u8) !void {
        try e.list.append(e.arena, .{ .tag = tag, .type = @backingInt(kind), .count = count, .value = value });
    }

    fn ascii(e: *Entries, tag: u16, text: []const u8) !void {
        const value = try std.mem.concat(e.arena, u8, &.{ text, "\x00" });
        try e.add(tag, .ascii, std.math.cast(u32, value.len) orelse return error.OutOfMemory, value);
    }

    fn short(e: *Entries, tag: u16, v: u16) !void {
        const value = try e.arena.alloc(u8, 2);
        std.mem.writeInt(u16, value[0..2], v, .little);
        try e.add(tag, .short, 1, value);
    }

    fn long(e: *Entries, tag: u16, v: u32) !void {
        const value = try e.arena.alloc(u8, 4);
        std.mem.writeInt(u32, value[0..4], v, .little);
        try e.add(tag, .long, 1, value);
    }

    fn fraction(e: *Entries, tag: u16, v: [2]u32) !void {
        const value = try e.arena.alloc(u8, 8);
        std.mem.writeInt(u32, value[0..4], v[0], .little);
        std.mem.writeInt(u32, value[4..8], v[1], .little);
        try e.add(tag, .rational, 1, value);
    }
};

/// The EXIF sub-directory's entries.
fn exifEntries(e: *Entries, m: Metadata) !void {
    try e.add(Tag.exif_version, .undefined, exif_version.len, exif_version);
    if (m.shot) |text| if (isoDate(text)) |date| if (date.day) |day| {
        // EXIF wants the time too, and allows unknown parts as spaces.
        try e.ascii(Tag.date_time_original, try std.fmt.allocPrint(e.arena, "{d:0>4}:{d:0>2}:{d:0>2}   :  :  ", .{ date.year, date.month.?, day }));
    };
    try e.short(Tag.colour_space, if (m.space == .srgb) exif_srgb else exif_uncalibrated);
    if (m.width > 0) {
        try e.long(Tag.pixel_x_dimension, std.math.cast(u32, m.width) orelse 0);
        try e.long(Tag.pixel_y_dimension, std.math.cast(u32, m.height) orelse 0);
    }
    if (m.lens) |text| try e.ascii(Tag.lens_model, text);
}

/// The main directory's entries that EXIF adds, with a placeholder for the EXIF pointer.
fn mainEntries(e: *Entries, m: Metadata, software: bool) !void {
    if (m.camera) |text| try e.ascii(Tag.model, text);
    if (m.dpi) |dpi| {
        try e.fraction(Tag.x_resolution, rational(dpi));
        try e.fraction(Tag.y_resolution, rational(dpi));
        try e.short(Tag.resolution_unit, resolution_in_inches);
    }
    if (software) try e.ascii(Tag.software, "minilab");
    if (m.copyright) |text| try e.ascii(Tag.copyright, text);
    try e.long(Tag.exif_ifd, 0);
}

fn byTag(_: void, a: Entry, b: Entry) bool {
    return a.tag < b.tag;
}

pub const Error = error{
    OutOfMemory,
    /// The file isn't what the codec writes: a little-endian classic TIFF, or a JPEG.
    UnexpectedFile,
    /// The file has grown past what classic TIFF's 32-bit offsets reach.
    TooLarge,
};

/// Appends a directory of `entries` to `out` at an even offset from `base`, with the values too
/// long for their entries after it, and returns its offset from `base`. `entries` are sorted by
/// tag, as TIFF requires.
fn appendIfd(gpa: std.mem.Allocator, out: *std.ArrayList(u8), base: usize, entries: []Entry, next: u32) Error!u32 {
    std.mem.sort(Entry, entries, {}, byTag);
    if ((out.items.len - base) % 2 == 1) try out.append(gpa, 0);
    const at = out.items.len - base;
    const directory_size = 2 + entries.len * 12 + 4;
    var data_at = at + directory_size;
    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u16, bytes[0..2], @intCast(entries.len), .little);
    try out.appendSlice(gpa, bytes[0..2]);
    for (entries) |entry| {
        std.mem.writeInt(u16, bytes[0..2], entry.tag, .little);
        std.mem.writeInt(u16, bytes[2..4], entry.type, .little);
        std.mem.writeInt(u32, bytes[4..8], entry.count, .little);
        if (entry.raw) {
            @memcpy(bytes[8..12], entry.value[0..4]);
        } else if (entry.value.len <= 4) {
            @memset(bytes[8..12], 0);
            @memcpy(bytes[8..][0..entry.value.len], entry.value);
        } else {
            std.mem.writeInt(u32, bytes[8..12], std.math.cast(u32, data_at) orelse return error.TooLarge, .little);
            data_at += entry.value.len + entry.value.len % 2;
        }
        try out.appendSlice(gpa, &bytes);
    }
    std.mem.writeInt(u32, bytes[0..4], next, .little);
    try out.appendSlice(gpa, bytes[0..4]);
    for (entries) |entry| {
        if (entry.raw or entry.value.len <= 4) continue;
        try out.appendSlice(gpa, entry.value);
        if (entry.value.len % 2 == 1) try out.append(gpa, 0);
    }
    if (out.items.len - base > std.math.maxInt(u32)) return error.TooLarge;
    return std.math.cast(u32, at) orelse error.TooLarge;
}

/// Sets the four value bytes of the entry `tag` of the directory at `ifd` to `value`.
fn patchEntry(bytes: []u8, ifd: usize, tag: u16, value: u32) void {
    const count = std.mem.readInt(u16, bytes[ifd..][0..2], .little);
    for (0..count) |i| {
        const entry = bytes[ifd + 2 + i * 12 ..][0..12];
        if (std.mem.readInt(u16, entry[0..2], .little) != tag) continue;
        std.mem.writeInt(u32, entry[8..12], value, .little);
        return;
    }
    unreachable;
}

/// Adds `metadata` as EXIF and `packet` as XMP to `file`, a TIFF as `codecs.tiff.write` makes it:
/// a new main directory with the file's own entries and the new ones, and an EXIF directory, all
/// at the end of the file, and the header pointed at the new directory. The old one stays behind,
/// unused. The caller owns the bytes.
pub fn intoTiff(gpa: std.mem.Allocator, file: []const u8, metadata: Metadata, packet: ?[]const u8) Error![]u8 {
    const header = "II*\x00";
    if (file.len < 8 or !std.mem.eql(u8, file[0..4], header)) return error.UnexpectedFile;
    const first = std.mem.readInt(u32, file[4..8], .little);
    if (first + 2 > file.len) return error.UnexpectedFile;
    const count = std.mem.readInt(u16, file[first..][0..2], .little);
    if (first + 2 + @as(usize, count) * 12 + 4 > file.len) return error.UnexpectedFile;
    const next = std.mem.readInt(u32, file[first + 2 + @as(usize, count) * 12 ..][0..4], .little);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var added: Entries = .{ .arena = arena_state.allocator() };
    try mainEntries(&added, metadata, false);
    if (packet) |p| try added.add(Tag.xmp, .byte, std.math.cast(u32, p.len) orelse return error.TooLarge, p);

    // The file's own entries, unless a new one replaces them.
    var entries: Entries = .{ .arena = arena_state.allocator() };
    for (0..count) |i| {
        const raw = file[first + 2 + i * 12 ..][0..12];
        const tag = std.mem.readInt(u16, raw[0..2], .little);
        const replaced = for (added.list.items) |a| {
            if (a.tag == tag) break true;
        } else false;
        if (replaced) continue;
        try entries.list.append(entries.arena, .{
            .tag = tag,
            .type = std.mem.readInt(u16, raw[2..4], .little),
            .count = std.mem.readInt(u32, raw[4..8], .little),
            .value = raw[8..12],
            .raw = true,
        });
    }
    try entries.list.appendSlice(entries.arena, added.list.items);

    var out: std.ArrayList(u8) = try .initCapacity(gpa, file.len + 4096 + if (packet) |p| p.len else 0);
    errdefer out.deinit(gpa);
    out.appendSliceAssumeCapacity(file);
    const main = try appendIfd(gpa, &out, 0, entries.list.items, next);
    var exif: Entries = .{ .arena = arena_state.allocator() };
    try exifEntries(&exif, metadata);
    const exif_at = try appendIfd(gpa, &out, 0, exif.list.items, 0);
    patchEntry(out.items, main, Tag.exif_ifd, exif_at);
    std.mem.writeInt(u32, out.items[4..8], main, .little);
    return out.toOwnedSlice(gpa);
}

/// The JPEG markers met.
const soi = [2]u8{ 0xFF, 0xD8 };
const app0 = 0xE0;
const app1 = 0xE1;
const exif_header = "Exif\x00\x00";
const xmp_header = "http://ns.adobe.com/xap/1.0/\x00";
/// A segment's length field counts itself, and holds at most this.
const max_segment = std.math.maxInt(u16);
/// JFIF's density units: dots per inch.
const jfif_dots_per_inch = 1;

/// Adds `metadata` as EXIF and `packet` as XMP to `file`, a JPEG as `codecs.jpeg.write` makes it:
/// two APP1 segments after its JFIF segment, whose density becomes the resolution when it's
/// known. An XMP packet too big for one segment is left out. The caller owns the bytes.
pub fn intoJpeg(gpa: std.mem.Allocator, file: []const u8, metadata: Metadata, packet: ?[]const u8) Error![]u8 {
    if (file.len < 4 or !std.mem.eql(u8, file[0..2], &soi)) return error.UnexpectedFile;
    var insert_at: usize = 2;
    var jfif: ?usize = null;
    if (file[2] == 0xFF and file[3] == app0 and file.len >= 18 and std.mem.eql(u8, file[6..11], "JFIF\x00")) {
        jfif = 2;
        insert_at = 4 + std.mem.readInt(u16, file[4..6], .big);
        if (insert_at > file.len) return error.UnexpectedFile;
    }

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The EXIF block: a TIFF of its own, its offsets counted from its header.
    var tiff: std.ArrayList(u8) = .empty;
    try tiff.appendSlice(arena, "II*\x00\x00\x00\x00\x00");
    var main: Entries = .{ .arena = arena };
    try mainEntries(&main, metadata, true);
    const main_at = try appendIfd(arena, &tiff, 0, main.list.items, 0);
    var exif: Entries = .{ .arena = arena };
    try exifEntries(&exif, metadata);
    const exif_at = try appendIfd(arena, &tiff, 0, exif.list.items, 0);
    patchEntry(tiff.items, main_at, Tag.exif_ifd, exif_at);
    std.mem.writeInt(u32, tiff.items[4..8], main_at, .little);

    var out: std.ArrayList(u8) = try .initCapacity(gpa, file.len + tiff.items.len + 64 + if (packet) |p| p.len else 0);
    errdefer out.deinit(gpa);
    out.appendSliceAssumeCapacity(file[0..insert_at]);
    try segment(gpa, &out, app1, &.{ exif_header, tiff.items });
    if (packet) |p| {
        if (2 + xmp_header.len + p.len <= max_segment) try segment(gpa, &out, app1, &.{ xmp_header, p });
    }
    try out.appendSlice(gpa, file[insert_at..]);

    if (jfif) |at| if (metadata.dpi) |dpi| {
        const density: u16 = @intFromFloat(std.math.clamp(@round(dpi), 1, std.math.maxInt(u16)));
        // After the marker, the length, "JFIF\0" and the version.
        const units = at + 2 + 2 + 5 + 2;
        out.items[units] = jfif_dots_per_inch;
        std.mem.writeInt(u16, out.items[units + 1 ..][0..2], density, .big);
        std.mem.writeInt(u16, out.items[units + 3 ..][0..2], density, .big);
    };
    return out.toOwnedSlice(gpa);
}

fn segment(gpa: std.mem.Allocator, out: *std.ArrayList(u8), marker: u8, parts: []const []const u8) Error!void {
    var length: usize = 2;
    for (parts) |p| length += p.len;
    if (length > max_segment) return error.TooLarge;
    var head: [4]u8 = .{ 0xFF, marker, 0, 0 };
    std.mem.writeInt(u16, head[2..4], @intCast(length), .big);
    try out.appendSlice(gpa, &head);
    for (parts) |p| try out.appendSlice(gpa, p);
}

// Tests ----------------------------------------------------------------------------------------

const example: Metadata = .{
    .camera = "Nikon F3",
    .lens = "Nikkor 50mm f/1.4",
    .stock = "Kodak Portra 400",
    .shot = "2026-10-22",
    .copyright = "© Ana & Bo <studio>",
    .develop = .{ .look = .neutral, .kind = .colour_negative, .settings = .{}, .scanner = "Epson V600" },
    .dpi = 2400,
    .space = .display_p3,
    .width = 3,
    .height = 2,
};

/// The value of `tag` in the directory at `ifd` of the TIFF `bytes` starting at `base`: its type,
/// count and value bytes.
fn find(bytes: []const u8, base: usize, ifd: usize, tag: u16) ?struct { type: u16, count: u32, value: []const u8 } {
    const tiff = bytes[base..];
    const count = std.mem.readInt(u16, tiff[ifd..][0..2], .little);
    for (0..count) |i| {
        const entry = tiff[ifd + 2 + i * 12 ..][0..12];
        if (std.mem.readInt(u16, entry[0..2], .little) != tag) continue;
        const kind = std.mem.readInt(u16, entry[2..4], .little);
        const n = std.mem.readInt(u32, entry[4..8], .little);
        const size: usize = n * @as(usize, switch (kind) {
            3 => 2,
            4 => 4,
            5 => 8,
            else => 1,
        });
        const value = if (size <= 4) entry[8..][0..size] else tiff[std.mem.readInt(u32, entry[8..12], .little)..][0..size];
        return .{ .type = kind, .count = n, .value = value };
    }
    return null;
}

test "XMP escapes what the roll says and gives dates as dates" {
    const gpa = std.testing.allocator;
    const packet = try xmp(gpa, example);
    defer gpa.free(packet);
    try std.testing.expect(std.mem.indexOf(u8, packet, "© Ana &amp; Bo &lt;studio&gt;</rdf:li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "photoshop:DateCreated=\"2026-10-22\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "minilab:FilmStock=\"Kodak Portra 400\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "photoshop:ICCProfile=\"Display P3\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "minilab:Settings=\"saved\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, packet, "<?xpacket end=\"w\"?>\n"));

    var vague = example;
    vague.shot = "summer";
    const other = try xmp(gpa, vague);
    defer gpa.free(other);
    try std.testing.expect(std.mem.indexOf(u8, other, "DateCreated") == null);
    try std.testing.expect(std.mem.indexOf(u8, other, "minilab:Shot=\"summer\"") != null);
}

test "only ISO dates count as dates" {
    try std.testing.expectEqual(Date{ .year = 2026, .month = 10 }, isoDate("2026-10").?);
    try std.testing.expectEqual(@as(?Date, null), isoDate("2026-13"));
    try std.testing.expectEqual(@as(?Date, null), isoDate("Oct 2026"));
}

test "a TIFF gains EXIF and XMP and keeps its own tags" {
    const gpa = std.testing.allocator;
    const tiff_codec = @import("../io/codecs/tiff.zig");
    var pixels: image.Encoded8 = try .init(gpa, 3, 2);
    defer pixels.deinit(gpa);
    @memset(pixels.pixels, .{ 10, 20, 30 });
    const file = try tiff_codec.write(gpa, u8, pixels, .{ .icc_profile = "not really a profile" });
    defer gpa.free(file);
    const packet = try xmp(gpa, example);
    defer gpa.free(packet);
    const tagged = try intoTiff(gpa, file, example, packet);
    defer gpa.free(tagged);

    const main = std.mem.readInt(u32, tagged[4..8], .little);
    try std.testing.expectEqualStrings("Nikon F3\x00", find(tagged, 0, main, Tag.model).?.value);
    try std.testing.expectEqualStrings(packet, find(tagged, 0, main, Tag.xmp).?.value);
    const resolution = find(tagged, 0, main, Tag.x_resolution).?.value;
    try std.testing.expectEqual(@as(u32, 2400), std.mem.readInt(u32, resolution[0..4], .little));
    const exif_at = std.mem.readInt(u32, find(tagged, 0, main, Tag.exif_ifd).?.value[0..4], .little);
    try std.testing.expectEqualStrings("Nikkor 50mm f/1.4\x00", find(tagged, 0, exif_at, Tag.lens_model).?.value);
    try std.testing.expectEqualStrings("2026:10:22   :  :  \x00", find(tagged, 0, exif_at, Tag.date_time_original).?.value);

    // LibTIFF reads it back, pixels, profile and all.
    var decoded = try tiff_codec.read(gpa, tagged);
    defer decoded.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 3), decoded.scan.width);
    try std.testing.expectEqual([3]u16{ 10 * image.widen_8_to_16, 20 * image.widen_8_to_16, 30 * image.widen_8_to_16 }, decoded.scan.pixels[5]);
    try std.testing.expectEqualStrings("not really a profile", decoded.icc_profile.?);
}

test "a JPEG gains EXIF, XMP and its density, and still decodes" {
    const gpa = std.testing.allocator;
    const jpeg_codec = @import("../io/codecs/jpeg.zig");
    var pixels: image.Encoded8 = try .init(gpa, 16, 8);
    defer pixels.deinit(gpa);
    @memset(pixels.pixels, .{ 200, 100, 50 });
    const file = try jpeg_codec.write(gpa, pixels, .{ .icc_profile = "a profile" });
    defer gpa.free(file);
    const packet = try xmp(gpa, example);
    defer gpa.free(packet);
    const tagged = try intoJpeg(gpa, file, example, packet);
    defer gpa.free(tagged);

    // JFIF first, its density now 2400 dots per inch, then the EXIF segment.
    try std.testing.expectEqual(@as(u8, jfif_dots_per_inch), tagged[13]);
    try std.testing.expectEqual(@as(u16, 2400), std.mem.readInt(u16, tagged[14..16], .big));
    const exif_at = 4 + std.mem.readInt(u16, tagged[4..6], .big);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, app1 }, tagged[exif_at..][0..2]);
    const block = exif_at + 4 + exif_header.len;
    try std.testing.expectEqualStrings(exif_header, tagged[exif_at + 4 ..][0..exif_header.len]);
    const main = std.mem.readInt(u32, tagged[block + 4 ..][0..4], .little);
    try std.testing.expectEqualStrings("minilab\x00", find(tagged, block, main, Tag.software).?.value);
    try std.testing.expect(std.mem.indexOf(u8, tagged, xmp_header) != null);

    var decoded = try jpeg_codec.read(gpa, tagged);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualStrings("a profile", decoded.icc_profile.?);
}
