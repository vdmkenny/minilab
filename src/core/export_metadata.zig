//! The metadata an exported file carries besides its pixels: the roll's camera, lens, film stock,
//! date and copyright, how the frame was developed, its resolution and its colour space.
//!
//! We write it two ways. XMP (an XML packet) goes in a sidecar file next to the export, and inside
//! the export too: a TIFF holds it in tag 700, a JPEG in an APP1 segment. EXIF (a small TIFF
//! directory of numbered tags) goes inside both. In a TIFF its tags join the file's own directory,
//! and in a JPEG it's another APP1 segment. The codecs write neither, so we add both to the bytes
//! the codecs produce.
//!
//! EXIF has no fields for the film stock or the develop settings, so those only go in the XMP, in
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
    /// When the roll was shot, as the roll gives it. Dates like 2026, 2026-10 or 2026-10-22 are
    /// written as dates, and anything else as text in minilab's namespace.
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
    /// The frame's rating as `xmp:Rating` takes it: -1 for rejected, or 1 to 5 stars. Null leaves
    /// it out.
    rating: ?i8 = null,
    /// The roll's notes, written as the caption (`dc:description`).
    notes: ?[]const u8 = null,
    /// Fields of your own. Ones without a name are left out.
    fields: []const Field = &.{},
};

/// A metadata field of your own: a name and a value. XMP gets them as a list in minilab's
/// namespace, since they aren't any standard property.
pub const Field = struct {
    name: []const u8,
    value: []const u8,
};

pub const Develop = struct {
    look: look.Id,
    kind: develop.FilmKind,
    /// The frame's saved settings, or null if it was never developed and the export worked out
    /// automatic ones.
    settings: ?develop.Settings = null,
    /// The scanner, as the roll names it.
    scanner: ?[]const u8 = null,
    /// The part of the scan that was exported, in the scan's pixels, or null for all of it.
    crop: ?image.Area = null,
    quarter_turns: u2 = 0,
};

/// The name the space's profile gives it. The XMP repeats it.
pub const spaceName = icc.nameOf;

/// minilab's XMP namespace, for things no standard schema has a property for.
pub const namespace = "urn:minilab:xmp:1.0/";

// XMP ------------------------------------------------------------------------------------------

/// Returns the XMP packet for `metadata`. It's the same for the sidecar file and for embedding.
/// The caller owns the bytes.
pub fn xmp(gpa: std.mem.Allocator, metadata: Metadata) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    writeXmp(&out.writer, metadata) catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeXmp(w: *std.Io.Writer, m: Metadata) std.Io.Writer.Error!void {
    // The XMP specification fixes the packet header's id. The byte-order mark tells anything
    // scanning for the packet that it's UTF-8.
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
    if (m.rating) |v| try w.print("    xmp:Rating=\"{d}\"\n", .{v});
    if (m.develop) |d| try writeDevelop(w, d);
    try w.writeAll("  >\n");
    if (m.notes) |v| {
        try w.writeAll("   <dc:description>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">");
        try escaped(w, v);
        try w.writeAll("</rdf:li>\n    </rdf:Alt>\n   </dc:description>\n");
    }
    try writeFields(w, m.fields);
    if (m.copyright) |v| {
        try w.writeAll("   <dc:rights>\n    <rdf:Alt>\n     <rdf:li xml:lang=\"x-default\">");
        try escaped(w, v);
        try w.writeAll("</rdf:li>\n    </rdf:Alt>\n   </dc:rights>\n");
    }
    try w.writeAll("  </rdf:Description>\n </rdf:RDF>\n</x:xmpmeta>\n<?xpacket end=\"w\"?>\n");
}

/// Writes the fields with a name as `minilab:Fields`, a bag of name and value pairs.
fn writeFields(w: *std.Io.Writer, fields: []const Field) std.Io.Writer.Error!void {
    var named: usize = 0;
    for (fields) |f| named += @intFromBool(f.name.len > 0);
    if (named == 0) return;
    try w.writeAll("   <minilab:Fields>\n    <rdf:Bag>\n");
    for (fields) |f| {
        if (f.name.len == 0) continue;
        try w.writeAll("     <rdf:li rdf:parseType=\"Resource\">\n      <minilab:Name>");
        try escaped(w, f.name);
        try w.writeAll("</minilab:Name>\n      <minilab:Value>");
        try escaped(w, f.value);
        try w.writeAll("</minilab:Value>\n     </rdf:li>\n");
    }
    try w.writeAll("    </rdf:Bag>\n   </minilab:Fields>\n");
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
    // Highlights, midtones and shadows, in `develop.Range`'s order.
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

/// Writes `text` as XML character data or an attribute value. Markup characters are escaped, and
/// control characters (which XML 1.0 doesn't allow) become spaces.
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

/// A date in one of ISO 8601's three precisions (a year, a month or a day), as `isoDate` finds it.
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

/// Returns `value` as a fraction: whole numbers over 1, and anything else to a hundredth.
fn rational(value: f32) [2]u32 {
    // Far beyond any scanner, and it still fits in a u32 a hundred times over.
    const v = std.math.clamp(value, 0, 1e7);
    if (@round(v) == v) return .{ @intFromFloat(v), 1 };
    return .{ @intFromFloat(@round(v * 100)), 100 };
}

// EXIF -----------------------------------------------------------------------------------------

/// TIFF's value types, with the numbers its directory entries use for them. A file can have
/// others.
const Type = enum(u16) {
    byte = 1,
    ascii = 2,
    short = 3,
    long = 4,
    rational = 5,
    undefined = 7,
    _,

    /// The bytes one value takes.
    fn size(t: Type) usize {
        return switch (t) {
            .byte, .ascii, .undefined, _ => 1,
            .short => 2,
            .long => 4,
            .rational => 8,
        };
    }
};

/// A directory (IFD) is a count of its entries, the entries, and the offset of the next
/// directory.
const ifd_count_bytes = 2;
const ifd_next_bytes = 4;
/// An entry is its tag, its type, its count, and its value or the value's offset.
const entry_bytes = 12;
const entry_type_at = 2;
const entry_count_at = 4;
const entry_value_at = 8;
/// The longest value that goes in its entry instead of after the directory.
const inline_value_bytes = 4;

/// The size of a directory of `count` entries.
fn ifdSize(count: usize) usize {
    return ifd_count_bytes + count * entry_bytes + ifd_next_bytes;
}

/// Entry `i` of the directory at `ifd` in `bytes`.
fn entryAt(bytes: []const u8, ifd: usize, i: usize) *const [entry_bytes]u8 {
    return bytes[ifd + ifd_count_bytes + i * entry_bytes ..][0..entry_bytes];
}

fn tagOf(entry: *const [entry_bytes]u8) Tag {
    return @fromBackingInt(std.mem.readInt(u16, entry[0..entry_type_at], .little));
}

/// One entry of a TIFF directory (IFD).
const Entry = struct {
    tag: Tag,
    type: Type,
    count: u32,
    /// The value, little-endian. Up to four bytes go in the entry itself. Longer values go after
    /// the directory, and the entry points at them.
    value: []const u8,
    /// Whether `value` is the four value bytes of an entry read from a file. Those may be an
    /// offset into that file, so they're copied as they are.
    raw: bool = false,
};

/// The tags we write, from TIFF 6.0 and EXIF 2.32. A file has others.
const Tag = enum(u16) {
    model = 272,
    x_resolution = 282,
    y_resolution = 283,
    resolution_unit = 296,
    software = 305,
    xmp = 700,
    copyright = 33432,
    exif_ifd = 34665,
    exif_version = 36864,
    date_time_original = 36867,
    colour_space = 40961,
    pixel_x_dimension = 40962,
    pixel_y_dimension = 40963,
    lens_model = 42036,
    _,
};

const resolution_in_inches = 2;
/// EXIF's colour space values: sRGB, or anything else, in which case the ICC profile says which.
const exif_srgb = 1;
const exif_uncalibrated = 0xFFFF;
const exif_version = "0232";

/// Builds entries, keeping their values in an arena.
const Entries = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Entry) = .empty,

    fn add(e: *Entries, tag: Tag, kind: Type, count: u32, value: []const u8) !void {
        try e.list.append(e.arena, .{ .tag = tag, .type = kind, .count = count, .value = value });
    }

    fn ascii(e: *Entries, tag: Tag, text: []const u8) !void {
        const value = try std.mem.concat(e.arena, u8, &.{ text, "\x00" });
        try e.add(tag, .ascii, std.math.cast(u32, value.len) orelse return error.OutOfMemory, value);
    }

    fn short(e: *Entries, tag: Tag, v: u16) !void {
        const value = try e.arena.alloc(u8, 2);
        std.mem.writeInt(u16, value[0..2], v, .little);
        try e.add(tag, .short, 1, value);
    }

    fn long(e: *Entries, tag: Tag, v: u32) !void {
        const value = try e.arena.alloc(u8, 4);
        std.mem.writeInt(u32, value[0..4], v, .little);
        try e.add(tag, .long, 1, value);
    }

    fn fraction(e: *Entries, tag: Tag, v: [2]u32) !void {
        const value = try e.arena.alloc(u8, 8);
        std.mem.writeInt(u32, value[0..4], v[0], .little);
        std.mem.writeInt(u32, value[4..8], v[1], .little);
        try e.add(tag, .rational, 1, value);
    }
};

/// The EXIF sub-directory's entries.
fn exifEntries(e: *Entries, m: Metadata) !void {
    try e.add(.exif_version, .undefined, exif_version.len, exif_version);
    if (m.shot) |text| if (isoDate(text)) |date| if (date.day) |day| {
        // EXIF wants the time too, and lets unknown parts be spaces.
        try e.ascii(.date_time_original, try std.fmt.allocPrint(e.arena, "{d:0>4}:{d:0>2}:{d:0>2}   :  :  ", .{ date.year, date.month.?, day }));
    };
    try e.short(.colour_space, if (m.space == .srgb) exif_srgb else exif_uncalibrated);
    if (m.width > 0) {
        try e.long(.pixel_x_dimension, std.math.cast(u32, m.width) orelse 0);
        try e.long(.pixel_y_dimension, std.math.cast(u32, m.height) orelse 0);
    }
    if (m.lens) |text| try e.ascii(.lens_model, text);
}

/// The entries EXIF adds to the main directory, with a placeholder for the EXIF pointer.
fn mainEntries(e: *Entries, m: Metadata, software: bool) !void {
    if (m.camera) |text| try e.ascii(.model, text);
    if (m.dpi) |dpi| {
        try e.fraction(.x_resolution, rational(dpi));
        try e.fraction(.y_resolution, rational(dpi));
        try e.short(.resolution_unit, resolution_in_inches);
    }
    if (software) try e.ascii(.software, "minilab");
    if (m.copyright) |text| try e.ascii(.copyright, text);
    try e.long(.exif_ifd, 0);
}

fn byTag(_: void, a: Entry, b: Entry) bool {
    return @backingInt(a.tag) < @backingInt(b.tag);
}

pub const Error = error{
    OutOfMemory,
    /// The file isn't what the codec writes (a little-endian classic TIFF, or a JPEG).
    UnexpectedFile,
    /// The file has grown past what classic TIFF's 32-bit offsets can reach.
    TooLarge,
};

/// Appends a directory of `entries` to `out`, at an even offset from `base`, followed by the
/// values too long to fit in their entries. Returns the directory's offset from `base`. It sorts
/// `entries` by tag first, as TIFF requires.
fn appendIfd(gpa: std.mem.Allocator, out: *std.ArrayList(u8), base: usize, entries: []Entry, next: u32) Error!u32 {
    std.mem.sort(Entry, entries, {}, byTag);
    if ((out.items.len - base) % 2 == 1) try out.append(gpa, 0);
    const at = out.items.len - base;
    var data_at = at + ifdSize(entries.len);
    var count: [ifd_count_bytes]u8 = undefined;
    std.mem.writeInt(u16, &count, @intCast(entries.len), .little);
    try out.appendSlice(gpa, &count);
    for (entries) |entry| {
        var bytes: [entry_bytes]u8 = undefined;
        std.mem.writeInt(u16, bytes[0..entry_type_at], @backingInt(entry.tag), .little);
        std.mem.writeInt(u16, bytes[entry_type_at..entry_count_at], @backingInt(entry.type), .little);
        std.mem.writeInt(u32, bytes[entry_count_at..entry_value_at], entry.count, .little);
        const value = bytes[entry_value_at..];
        if (entry.raw) {
            @memcpy(value, entry.value[0..inline_value_bytes]);
        } else if (entry.value.len <= inline_value_bytes) {
            @memset(value, 0);
            @memcpy(value[0..entry.value.len], entry.value);
        } else {
            std.mem.writeInt(u32, value, std.math.cast(u32, data_at) orelse return error.TooLarge, .little);
            data_at += entry.value.len + entry.value.len % 2;
        }
        try out.appendSlice(gpa, &bytes);
    }
    var next_bytes: [ifd_next_bytes]u8 = undefined;
    std.mem.writeInt(u32, &next_bytes, next, .little);
    try out.appendSlice(gpa, &next_bytes);
    for (entries) |entry| {
        if (entry.raw or entry.value.len <= inline_value_bytes) continue;
        try out.appendSlice(gpa, entry.value);
        if (entry.value.len % 2 == 1) try out.append(gpa, 0);
    }
    if (out.items.len - base > std.math.maxInt(u32)) return error.TooLarge;
    return std.math.cast(u32, at) orelse error.TooLarge;
}

/// Sets the four value bytes of entry `tag`, in the directory at `ifd`, to `value`.
fn patchEntry(bytes: []u8, ifd: usize, tag: Tag, value: u32) void {
    const count = std.mem.readInt(u16, bytes[ifd..][0..ifd_count_bytes], .little);
    for (0..count) |i| {
        if (tagOf(entryAt(bytes, ifd, i)) != tag) continue;
        const at = ifd + ifd_count_bytes + i * entry_bytes + entry_value_at;
        std.mem.writeInt(u32, bytes[at..][0..4], value, .little);
        return;
    }
    unreachable;
}

/// Adds `metadata` as EXIF and `packet` as XMP to `file`, a TIFF as `codecs.tiff.write` makes it.
/// We append a new main directory (the file's own entries plus the new ones) and an EXIF
/// directory, then point the header at the new main directory. The old one stays behind, unused.
/// The caller owns the bytes.
pub fn intoTiff(gpa: std.mem.Allocator, file: []const u8, metadata: Metadata, packet: ?[]const u8) Error![]u8 {
    const header = "II*\x00";
    if (file.len < 8 or !std.mem.eql(u8, file[0..4], header)) return error.UnexpectedFile;
    const first = std.mem.readInt(u32, file[4..8], .little);
    if (first + ifd_count_bytes > file.len) return error.UnexpectedFile;
    const count = std.mem.readInt(u16, file[first..][0..ifd_count_bytes], .little);
    if (first + ifdSize(count) > file.len) return error.UnexpectedFile;
    const next = std.mem.readInt(u32, file[first + ifdSize(count) - ifd_next_bytes ..][0..ifd_next_bytes], .little);

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var added: Entries = .{ .arena = arena_state.allocator() };
    try mainEntries(&added, metadata, false);
    if (packet) |p| try added.add(.xmp, .byte, std.math.cast(u32, p.len) orelse return error.TooLarge, p);

    // The file's own entries, except where a new one replaces them.
    var entries: Entries = .{ .arena = arena_state.allocator() };
    for (0..count) |i| {
        const raw = entryAt(file, first, i);
        const tag = tagOf(raw);
        const replaced = for (added.list.items) |a| {
            if (a.tag == tag) break true;
        } else false;
        if (replaced) continue;
        try entries.list.append(entries.arena, .{
            .tag = tag,
            .type = @fromBackingInt(std.mem.readInt(u16, raw[entry_type_at..entry_count_at], .little)),
            .count = std.mem.readInt(u32, raw[entry_count_at..entry_value_at], .little),
            .value = raw[entry_value_at..],
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
    patchEntry(out.items, main, .exif_ifd, exif_at);
    std.mem.writeInt(u32, out.items[4..8], main, .little);
    return out.toOwnedSlice(gpa);
}

/// The JPEG markers we deal with.
const soi = [2]u8{ 0xFF, 0xD8 };
const app0 = 0xE0;
const app1 = 0xE1;
const exif_header = "Exif\x00\x00";
const xmp_header = "http://ns.adobe.com/xap/1.0/\x00";
/// A segment's length field counts its own two bytes too, and can hold at most this.
const max_segment = std.math.maxInt(u16);
/// JFIF's density units: dots per inch.
const jfif_dots_per_inch = 1;

/// Adds `metadata` as EXIF and `packet` as XMP to `file`, a JPEG as `codecs.jpeg.write` makes it.
/// They go in two APP1 segments after the JFIF segment, and the JFIF density is set to the
/// resolution when it's known. An XMP packet too big for one segment is left out. The caller owns
/// the bytes.
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

    // The EXIF block is a TIFF of its own, with offsets counted from its own header.
    var tiff: std.ArrayList(u8) = .empty;
    try tiff.appendSlice(arena, "II*\x00\x00\x00\x00\x00");
    var main: Entries = .{ .arena = arena };
    try mainEntries(&main, metadata, true);
    const main_at = try appendIfd(arena, &tiff, 0, main.list.items, 0);
    var exif: Entries = .{ .arena = arena };
    try exifEntries(&exif, metadata);
    const exif_at = try appendIfd(arena, &tiff, 0, exif.list.items, 0);
    patchEntry(tiff.items, main_at, .exif_ifd, exif_at);
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

/// Finds `tag` in the directory at `ifd` of the TIFF in `bytes` that starts at `base`, and returns
/// its type, count and value bytes.
fn find(bytes: []const u8, base: usize, ifd: usize, tag: Tag) ?struct { type: Type, count: u32, value: []const u8 } {
    const tiff = bytes[base..];
    const count = std.mem.readInt(u16, tiff[ifd..][0..ifd_count_bytes], .little);
    for (0..count) |i| {
        const entry = entryAt(tiff, ifd, i);
        if (tagOf(entry) != tag) continue;
        const kind: Type = @fromBackingInt(std.mem.readInt(u16, entry[entry_type_at..entry_count_at], .little));
        const n = std.mem.readInt(u32, entry[entry_count_at..entry_value_at], .little);
        const size = n * kind.size();
        const value = if (size <= inline_value_bytes) entry[entry_value_at..][0..size] else tiff[std.mem.readInt(u32, entry[entry_value_at..], .little)..][0..size];
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
    try std.testing.expect(std.mem.indexOf(u8, other, "xmp:Rating") == null);

    var described = example;
    described.notes = "Rain & fog";
    described.fields = &.{ .{ .name = "Developer", .value = "Cs41 <fresh>" }, .{ .name = "", .value = "left out" } };
    const with_fields = try xmp(gpa, described);
    defer gpa.free(with_fields);
    try std.testing.expect(std.mem.indexOf(u8, with_fields, "<rdf:li xml:lang=\"x-default\">Rain &amp; fog</rdf:li>") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_fields, "<minilab:Name>Developer</minilab:Name>") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_fields, "<minilab:Value>Cs41 &lt;fresh&gt;</minilab:Value>") != null);
    try std.testing.expect(std.mem.indexOf(u8, with_fields, "left out") == null);

    var rejected = example;
    rejected.rating = -1;
    const flagged = try xmp(gpa, rejected);
    defer gpa.free(flagged);
    try std.testing.expect(std.mem.indexOf(u8, flagged, "xmp:Rating=\"-1\"") != null);
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
    try std.testing.expectEqualStrings("Nikon F3\x00", find(tagged, 0, main, .model).?.value);
    try std.testing.expectEqualStrings(packet, find(tagged, 0, main, .xmp).?.value);
    const resolution = find(tagged, 0, main, .x_resolution).?.value;
    try std.testing.expectEqual(@as(u32, 2400), std.mem.readInt(u32, resolution[0..4], .little));
    const exif_at = std.mem.readInt(u32, find(tagged, 0, main, .exif_ifd).?.value[0..4], .little);
    try std.testing.expectEqualStrings("Nikkor 50mm f/1.4\x00", find(tagged, 0, exif_at, .lens_model).?.value);
    try std.testing.expectEqualStrings("2026:10:22   :  :  \x00", find(tagged, 0, exif_at, .date_time_original).?.value);

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

    // JFIF comes first, with its density now 2400 dots per inch, then the EXIF segment.
    try std.testing.expectEqual(@as(u8, jfif_dots_per_inch), tagged[13]);
    try std.testing.expectEqual(@as(u16, 2400), std.mem.readInt(u16, tagged[14..16], .big));
    const exif_at = 4 + std.mem.readInt(u16, tagged[4..6], .big);
    try std.testing.expectEqualSlices(u8, &.{ 0xFF, app1 }, tagged[exif_at..][0..2]);
    const block = exif_at + 4 + exif_header.len;
    try std.testing.expectEqualStrings(exif_header, tagged[exif_at + 4 ..][0..exif_header.len]);
    const main = std.mem.readInt(u32, tagged[block + 4 ..][0..4], .little);
    try std.testing.expectEqualStrings("minilab\x00", find(tagged, block, main, .software).?.value);
    try std.testing.expect(std.mem.indexOf(u8, tagged, xmp_header) != null);

    var decoded = try jpeg_codec.read(gpa, tagged);
    defer decoded.deinit(gpa);
    try std.testing.expectEqualStrings("a profile", decoded.icc_profile.?);
}
