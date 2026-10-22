//! The looks minilab ships from free collections of film looks. The build fetches each collection
//! (see `build.zig.zon`), and `bake_looks.zig` turns these looks into one file of tables that the
//! app embeds. This list gives each look its place in that file, its id and its name.

const std = @import("std");

/// The number of points along each side of every baked LUT.
pub const size = 33;
/// The number of values in one baked LUT: an RGB triple for each of the `size`³ points, with red
/// changing fastest.
pub const lut_values = size * size * size * 3;
/// The size of one baked LUT in bytes. Each value is a little-endian u16 over 0..1.
pub const lut_bytes = lut_values * @sizeOf(u16);

/// A collection, with what its licence asks of us.
pub const Pack = enum {
    glassmeter,
    t3mujinpack,
    street_monochrome,

    pub fn info(pack: Pack) Info {
        return switch (pack) {
            .glassmeter => .{
                .name = "GlassMeter",
                .author = "Glass Works",
                .about = "Film looks from GlassMeter, an iPhone light meter and film camera. Each is an original curve set (a channel mixer, tone curves, saturation and a characteristic curve) after the film's published character, made for sRGB pictures.",
                .licence = "CC BY 4.0",
                .credit = "Film simulations from GlassMeter by Glass Works (glass-works.ai)",
                .changes = "The collection's 33³ .cube files, stored at 16 bits a value.",
                .url = "https://github.com/TrondW/glassmeter-film-looks",
            },
            .t3mujinpack => .{
                .name = "t3mujinpack",
                .author = "João Almeida",
                .about = "Film emulations made as darktable styles and published as HaldCLUT images. Some are strong: they bring the film's own contrast as well as its color.",
                .licence = "MIT",
                .credit = "t3mujinpack, copyright (c) 2017 João Almeida, MIT License",
                .changes = "Resampled from the collection's 144³ HaldCLUT images to 33³. Kodachrome and Agfa are spelled as the makers spell them.",
                .url = "https://github.com/t3mujinpack/t3mujinpack",
            },
            .street_monochrome => .{
                .name = "Street Monochrome",
                .author = "Ivan Bogachev",
                .about = "Black and white looks for street photography, from the author's darktable styles. From brightest to darkest: Standard, Landscape (darker blues, like a red filter), Flat and Eerie.",
                .licence = "CC BY 4.0",
                .credit = "Street Monochrome, copyright (c) 2026 Ivan Bogachev, CC BY 4.0",
                .changes = "Resampled from the collection's 64³ .cube files to 33³.",
                .url = "https://github.com/sfi0zy/street-monochrome",
            },
        };
    }
};

pub const Info = struct {
    name: []const u8,
    author: []const u8,
    /// What the collection is, for the Looks workspace. This and the fields below are shown on
    /// screen, so they're in American spelling.
    about: []const u8,
    licence: []const u8,
    /// The credit the licence asks for, shown with the collection.
    credit: []const u8,
    /// How minilab's copy differs from the collection's files, as CC BY asks us to say.
    changes: []const u8,
    url: []const u8,
};

/// The kind of film a look emulates. The menus group looks by it.
pub const Film = enum {
    colour_negative,
    slide,
    bw,

    pub fn label(film: Film) []const u8 {
        return switch (film) {
            .colour_negative => "Color negative",
            .slide => "Slide",
            .bw => "Black and white",
        };
    }
};

pub const Look = struct {
    pack: Pack,
    film: Film,
    /// The id frames store, `<pack>:<slug>`. It never changes once it's released.
    id: []const u8,
    name: []const u8,
    /// The name plus the collection, for places that show the look on its own:
    /// "Kodak Portra 400 · GlassMeter".
    label: []const u8,
    /// The file in the collection's folder.
    file: []const u8,

    fn of(comptime pack: Pack, film: Film, comptime slug: []const u8, comptime name: []const u8, comptime file: []const u8) Look {
        return .{
            .pack = pack,
            .film = film,
            .id = @tagName(pack) ++ ":" ++ slug,
            .name = name,
            .label = name ++ " · " ++ pack.info().name,
            .file = file,
        };
    }

    fn glassmeter(film: Film, comptime slug: []const u8, comptime name: []const u8) Look {
        return .of(.glassmeter, film, slug, name, "luts/cube-srgb-33/" ++ slug ++ ".cube");
    }

    /// `file_name` is the image's name in the collection, when it differs from `name`.
    fn t3mujinpack(comptime film: Film, comptime slug: []const u8, comptime name: []const u8, comptime file_name: ?[]const u8) Look {
        const category = switch (film) {
            .colour_negative => "Color Negative",
            .slide => "Color Slide",
            .bw => "Black and White",
        };
        return .of(.t3mujinpack, film, slug, name, "haldcluts/t3mujinpack - " ++ category ++ " - " ++ (file_name orelse name) ++ ".png");
    }

    fn streetMonochrome(comptime slug: []const u8, comptime name: []const u8) Look {
        return .of(.street_monochrome, .bw, slug, name, "lut/Street Monochrome " ++ name ++ ".cube");
    }
};

/// Every look, sorted by collection and then by film, in the same order as the baked file.
pub const looks = [_]Look{
    .glassmeter(.colour_negative, "cinestill-50d", "CineStill 50D"),
    .glassmeter(.colour_negative, "cinestill-400d", "CineStill 400D"),
    .glassmeter(.colour_negative, "cinestill-800t", "CineStill 800T"),
    .glassmeter(.colour_negative, "fuji-industrial-100", "Fujicolor Industrial 100"),
    .glassmeter(.colour_negative, "fuji-pro-400h", "Fujifilm Pro 400H"),
    .glassmeter(.colour_negative, "fuji-superia-xtra-400", "Fujifilm Superia X-TRA 400"),
    .glassmeter(.colour_negative, "kodak-colorplus-200", "Kodak ColorPlus 200"),
    .glassmeter(.colour_negative, "kodak-ektar-100", "Kodak Ektar 100"),
    .glassmeter(.colour_negative, "kodak-gold-200", "Kodak Gold 200"),
    .glassmeter(.colour_negative, "kodak-portra-160", "Kodak Portra 160"),
    .glassmeter(.colour_negative, "kodak-portra-400", "Kodak Portra 400"),
    .glassmeter(.colour_negative, "kodak-portra-800", "Kodak Portra 800"),
    .glassmeter(.colour_negative, "kodak-ultramax-400", "Kodak UltraMax 400"),
    .glassmeter(.slide, "fuji-provia-100f", "Fuji Provia 100F"),
    .glassmeter(.slide, "fuji-velvia-50", "Fuji Velvia 50"),
    .glassmeter(.slide, "fuji-velvia-100", "Fuji Velvia 100"),
    .glassmeter(.slide, "kodak-ektachrome-e100", "Kodak Ektachrome E100"),
    .glassmeter(.bw, "fuji-acros-100-ii", "Fujifilm Neopan Acros 100 II"),
    .glassmeter(.bw, "ilford-delta-100-v2", "Ilford Delta 100"),
    .glassmeter(.bw, "ilford-delta-400", "Ilford Delta 400"),
    .glassmeter(.bw, "ilford-delta-3200-v2", "Ilford Delta 3200"),
    .glassmeter(.bw, "ilford-fp4-125-v2", "Ilford FP4 Plus"),
    .glassmeter(.bw, "ilford-hp5-400-v2", "Ilford HP5 Plus"),
    .glassmeter(.bw, "ilford-panf-50", "Ilford Pan F Plus"),
    .glassmeter(.bw, "ilford-xp2-super-400", "Ilford XP2 Super"),
    .glassmeter(.bw, "kodak-double-x-v2", "Kodak Double-X"),
    .glassmeter(.bw, "kodak-tmax-100-v2", "Kodak T-MAX 100"),
    .glassmeter(.bw, "kodak-tmax-400-v2", "Kodak T-MAX 400"),
    .glassmeter(.bw, "kodak-tmax-p3200", "Kodak T-MAX P3200"),
    .glassmeter(.bw, "kodak-trix-400-v2", "Kodak Tri-X 400"),
    .t3mujinpack(.colour_negative, "agfa-vista-100", "Agfa Vista 100", null),
    .t3mujinpack(.colour_negative, "agfa-vista-200", "Agfa Vista 200", null),
    .t3mujinpack(.colour_negative, "agfa-vista-400", "Agfa Vista 400", null),
    .t3mujinpack(.colour_negative, "fuji-pro-160c", "Fuji Pro 160C", null),
    .t3mujinpack(.colour_negative, "fuji-pro-400h", "Fuji Pro 400H", null),
    .t3mujinpack(.colour_negative, "fuji-pro-800z", "Fuji Pro 800Z", null),
    .t3mujinpack(.colour_negative, "fuji-superia-100", "Fuji Superia 100", null),
    .t3mujinpack(.colour_negative, "fuji-superia-200", "Fuji Superia 200", null),
    .t3mujinpack(.colour_negative, "fuji-superia-400", "Fuji Superia 400", null),
    .t3mujinpack(.colour_negative, "fuji-superia-800", "Fuji Superia 800", null),
    .t3mujinpack(.colour_negative, "fuji-superia-1600", "Fuji Superia 1600", null),
    .t3mujinpack(.colour_negative, "fuji-superia-hg-1600", "Fuji Superia HG 1600", null),
    .t3mujinpack(.colour_negative, "kodak-colorplus-200", "Kodak ColorPlus 200", null),
    .t3mujinpack(.colour_negative, "kodak-ektar-100", "Kodak Ektar 100", null),
    .t3mujinpack(.colour_negative, "kodak-gold-200", "Kodak Gold 200", null),
    .t3mujinpack(.colour_negative, "kodak-portra-160", "Kodak Portra 160", null),
    .t3mujinpack(.colour_negative, "kodak-portra-160-nc", "Kodak Portra 160 NC", null),
    .t3mujinpack(.colour_negative, "kodak-portra-160-vc", "Kodak Portra 160 VC", null),
    .t3mujinpack(.colour_negative, "kodak-portra-400", "Kodak Portra 400", null),
    .t3mujinpack(.colour_negative, "kodak-portra-400-nc", "Kodak Portra 400 NC", null),
    .t3mujinpack(.colour_negative, "kodak-portra-400-uc", "Kodak Portra 400 UC", null),
    .t3mujinpack(.colour_negative, "kodak-portra-400-vc", "Kodak Portra 400 VC", null),
    .t3mujinpack(.colour_negative, "kodak-portra-800", "Kodak Portra 800", null),
    .t3mujinpack(.colour_negative, "kodak-ultra-max-400", "Kodak Ultra Max 400", null),
    .t3mujinpack(.slide, "fuji-astia-100f", "Fuji Astia 100F", null),
    .t3mujinpack(.slide, "fuji-fortia-sp-50", "Fuji Fortia SP 50", null),
    .t3mujinpack(.slide, "fuji-provia-100f", "Fuji Provia 100F", null),
    .t3mujinpack(.slide, "fuji-provia-400f", "Fuji Provia 400F", null),
    .t3mujinpack(.slide, "fuji-provia-400x", "Fuji Provia 400X", null),
    .t3mujinpack(.slide, "fuji-sensia-100", "Fuji Sensia 100", null),
    .t3mujinpack(.slide, "fuji-velvia-50", "Fuji Velvia 50", null),
    .t3mujinpack(.slide, "fuji-velvia-100", "Fuji Velvia 100", null),
    .t3mujinpack(.slide, "kodak-ektachrome-100-g", "Kodak Ektachrome 100 G", null),
    .t3mujinpack(.slide, "kodak-ektachrome-100-gx", "Kodak Ektachrome 100 GX", null),
    .t3mujinpack(.slide, "kodak-ektachrome-100-vs", "Kodak Ektachrome 100 VS", null),
    .t3mujinpack(.slide, "kodak-elite-chrome-400", "Kodak Elite Chrome 400", null),
    .t3mujinpack(.slide, "kodak-kodachrome-25", "Kodak Kodachrome 25", "Kodak Kodakchrome 25"),
    .t3mujinpack(.slide, "kodak-kodachrome-64", "Kodak Kodachrome 64", "Kodak Kodakchrome 64"),
    .t3mujinpack(.slide, "kodak-kodachrome-200", "Kodak Kodachrome 200", "Kodak Kodakchrome 200"),
    .t3mujinpack(.bw, "agfa-apx-25", "Agfa APX 25", "AGFA APX 25"),
    .t3mujinpack(.bw, "agfa-apx-100", "Agfa APX 100", "AGFA APX 100"),
    .t3mujinpack(.bw, "fuji-neopan-1600", "Fuji Neopan 1600", null),
    .t3mujinpack(.bw, "fuji-neopan-acros-100", "Fuji Neopan Acros 100", null),
    .t3mujinpack(.bw, "ilford-delta-100", "Ilford Delta 100", null),
    .t3mujinpack(.bw, "ilford-delta-400", "Ilford Delta 400", null),
    .t3mujinpack(.bw, "ilford-delta-3200", "Ilford Delta 3200", null),
    .t3mujinpack(.bw, "ilford-fp4-125", "Ilford FP4 125", null),
    .t3mujinpack(.bw, "ilford-hp5-plus-400", "Ilford HP5 Plus 400", null),
    .t3mujinpack(.bw, "ilford-xp2", "Ilford XP2", null),
    .t3mujinpack(.bw, "kodak-t-max-3200", "Kodak T-Max 3200", null),
    .t3mujinpack(.bw, "kodak-tri-x-400", "Kodak Tri-X 400", null),
    .streetMonochrome("standard", "Standard"),
    .streetMonochrome("landscape", "Landscape"),
    .streetMonochrome("flat", "Flat"),
    .streetMonochrome("eerie", "Eerie"),
};

/// The full-scale value of a baked u16.
const full_scale = std.math.maxInt(u16);

/// Writes one LUT's values (`lut_values / 3` triples over 0..1) the way the baked file stores them.
pub fn encode(values: []const [3]f32, out: *[lut_bytes]u8) void {
    std.debug.assert(values.len * 3 == lut_values);
    for (values, 0..) |triple, i| for (triple, 0..) |v, c| {
        const sample: u16 = @intFromFloat(@round(std.math.clamp(v, 0, 1) * full_scale));
        std.mem.writeInt(u16, out[(i * 3 + c) * 2 ..][0..2], sample, .little);
    };
}

/// Reads one baked LUT's values back.
pub fn decode(bytes: *const [lut_bytes]u8, values: [][3]f32) void {
    std.debug.assert(values.len * 3 == lut_values);
    for (values, 0..) |*triple, i| for (triple, 0..) |*v, c| {
        const sample = std.mem.readInt(u16, bytes[(i * 3 + c) * 2 ..][0..2], .little);
        v.* = @as(f32, @floatFromInt(sample)) / full_scale;
    };
}

/// Finds the look with the id `id`, and returns its index in `looks`.
pub fn find(id: []const u8) ?usize {
    return by_id.get(id);
}

const by_id: std.StaticStringMap(usize) = .initComptime(pairs: {
    var pairs: [looks.len]struct { []const u8, usize } = undefined;
    for (&pairs, looks, 0..) |*p, look, i| p.* = .{ look.id, i };
    break :pairs pairs;
});

comptime {
    // Each id and each label names exactly one look.
    @setEvalBranchQuota(100_000);
    for (looks, 0..) |a, i| for (looks[i + 1 ..]) |b| {
        if (std.mem.eql(u8, a.id, b.id)) @compileError("two looks have the id " ++ a.id);
        if (std.mem.eql(u8, a.label, b.label)) @compileError("two looks have the label " ++ a.label);
    };
}

test "ids find their looks, and each pack has looks" {
    for (looks, 0..) |look, i| try std.testing.expectEqual(i, find(look.id).?);
    try std.testing.expectEqual(null, find("glassmeter:nothing"));
    try std.testing.expectEqualStrings("Kodak Portra 400 · GlassMeter", looks[find("glassmeter:kodak-portra-400").?].label);
    try std.testing.expectEqualStrings("haldcluts/t3mujinpack - Black and White - AGFA APX 25.png", looks[find("t3mujinpack:agfa-apx-25").?].file);
    for (std.enums.values(Pack)) |pack| {
        var count: usize = 0;
        for (looks) |look| count += @intFromBool(look.pack == pack);
        try std.testing.expect(count > 0);
    }
}

test "a baked LUT reads back within half a 16-bit step" {
    const gpa = std.testing.allocator;
    const values = try gpa.alloc([3]f32, lut_values / 3);
    defer gpa.free(values);
    for (values, 0..) |*v, i| {
        const x: f32 = @floatFromInt(i % 1000);
        v.* = .{ x / 999, 1 - x / 999, 0.5 };
    }
    // Out-of-range values are clamped.
    values[0] = .{ -0.1, 1.2, 0.5 };
    const bytes = try gpa.create([lut_bytes]u8);
    defer gpa.destroy(bytes);
    encode(values, bytes);
    const back = try gpa.alloc([3]f32, lut_values / 3);
    defer gpa.free(back);
    decode(bytes, back);
    try std.testing.expectEqual([3]f32{ 0, 1, @as(f32, @round(0.5 * full_scale)) / full_scale }, back[0]);
    for (values[1..], back[1..]) |v, b| for (v, b) |x, y| try std.testing.expectApproxEqAbs(x, y, 0.5 / @as(f32, full_scale));
}
