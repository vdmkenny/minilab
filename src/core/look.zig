//! The looks a frame can be developed with. Each starts from Develop's rendering:
//!
//! - Neutral: Develop's rendering as it is.
//! - A LUT look: a .cube LUT laid over Neutral's sRGB-encoded output (`cube_lut`). minilab comes
//!   with one, Frontier emulation (`presets/looks/frontier.cube`), and takes any .cube the user
//!   imports into the library's Looks folder.
//! - A fitted look from the Looks workspace (`looks.saved`). It takes over from Develop after the
//!   film base and density stages: the frame is rendered with the Log tone, and the look turns
//!   that into colour.
//!
//! A frame names its look by an `Id`. A `Catalog` reads the looks the ids name, once each.

const std = @import("std");
const image = @import("image.zig");
const develop = @import("develop.zig");
const encode = @import("encode.zig");
const cube_lut = @import("cube_lut.zig");
const model = @import("../looks/model.zig");
const saved = @import("../looks/saved.zig");

/// The looks minilab comes with.
pub const Builtin = enum {
    neutral,
    frontier,

    pub fn label(builtin: Builtin) []const u8 {
        return switch (builtin) {
            .neutral => "Neutral",
            .frontier => "Frontier emulation",
        };
    }

    /// The look's LUT, as a .cube file; null for Neutral.
    pub fn cubeFile(builtin: Builtin) ?[]const u8 {
        return switch (builtin) {
            .neutral => null,
            .frontier => @embedFile("../presets/looks/frontier.cube"),
        };
    }
};

/// What a frame keeps to name its look: a built-in's name, `cube:` and an imported LUT's name, or
/// `look:` and a fitted look's folder. Kept in place, so that frame settings copy as values, and
/// written to JSON as a string.
pub const Id = struct {
    bytes: [capacity]u8 = undefined,
    len: u8 = 0,

    pub const capacity = 160;
    const cube_prefix = "cube:";
    const fitted_prefix = "look:";

    pub const neutral: Id = .builtin(.neutral);
    pub const frontier: Id = .builtin(.frontier);

    pub const Kind = union(enum) {
        builtin: Builtin,
        /// An imported LUT, `<Looks>/<name>.cube`.
        cube: []const u8,
        /// A fitted look, `<Looks>/<name>/`.
        fitted: []const u8,
    };

    pub fn builtin(b: Builtin) Id {
        return ofText(@tagName(b)) catch unreachable;
    }

    pub fn ofCube(name: []const u8) error{NameTooLong}!Id {
        return prefixed(cube_prefix, name);
    }

    pub fn ofFitted(name: []const u8) error{NameTooLong}!Id {
        return prefixed(fitted_prefix, name);
    }

    fn prefixed(prefix: []const u8, name: []const u8) error{NameTooLong}!Id {
        var id: Id = .{};
        if (prefix.len + name.len > capacity) return error.NameTooLong;
        @memcpy(id.bytes[0..prefix.len], prefix);
        @memcpy(id.bytes[prefix.len..][0..name.len], name);
        id.len = @intCast(prefix.len + name.len);
        return id;
    }

    fn ofText(value: []const u8) error{NameTooLong}!Id {
        return prefixed("", value);
    }

    pub fn text(id: *const Id) []const u8 {
        return id.bytes[0..id.len];
    }

    /// What the id names. An id that names nothing minilab knows of is Neutral.
    pub fn kind(id: *const Id) Kind {
        const t = id.text();
        if (std.mem.startsWith(u8, t, cube_prefix) and t.len > cube_prefix.len) return .{ .cube = t[cube_prefix.len..] };
        if (std.mem.startsWith(u8, t, fitted_prefix) and t.len > fitted_prefix.len) return .{ .fitted = t[fitted_prefix.len..] };
        return .{ .builtin = std.meta.stringToEnum(Builtin, t) orelse .neutral };
    }

    pub fn eql(a: *const Id, b: *const Id) bool {
        return std.mem.eql(u8, a.text(), b.text());
    }

    pub fn isNeutral(id: *const Id) bool {
        return id.kind() == .builtin and id.kind().builtin == .neutral;
    }

    /// The look's name for people.
    pub fn label(id: *const Id) []const u8 {
        return switch (id.kind()) {
            .builtin => |b| b.label(),
            .cube, .fitted => |name| name,
        };
    }

    pub fn jsonStringify(id: Id, jw: anytype) !void {
        try jw.write(id.text());
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !Id {
        const text_value = try std.json.innerParse([]const u8, allocator, source, options);
        // Rolls from before looks were LUTs name Frontier emulation by its old tag.
        if (std.mem.eql(u8, text_value, "frontier_emulation")) return .frontier;
        return ofText(text_value) catch .neutral;
    }
};

/// A look ready to apply.
pub const Resolved = union(enum) {
    neutral,
    /// A LUT over Neutral's sRGB-encoded output.
    lut: *const cube_lut.Lut,
    /// A fitted look, applied to a rendering with the Log tone.
    fitted: *const model.Model,

    /// The settings to render with for this look: a fitted look starts from the Log tone.
    pub fn settingsFor(look: Resolved, settings: develop.Settings) develop.Settings {
        var out = settings;
        if (look == .fitted) out.tone = .log;
        return out;
    }

    /// Applies the look in place to `pixels`, Develop's linear output with `settingsFor`'s
    /// settings. They become linear sRGB.
    pub fn apply(look: Resolved, pixels: [][3]f32) void {
        switch (look) {
            .neutral => {},
            .lut => |lut| for (pixels) |*p| {
                var encoded: [3]f32 = undefined;
                for (&encoded, p.*) |*e, v| e.* = encode.srgb(v);
                const out = lut.lookup(encoded);
                for (p, out) |*v, o| v.* = encode.linearFromSrgb(o);
            },
            .fitted => |m| m.apply(pixels),
        }
    }

    /// A copy of the look in `arena`, for work on another thread while the catalog changes.
    pub fn copy(look: Resolved, arena: std.mem.Allocator) error{OutOfMemory}!Resolved {
        return switch (look) {
            .neutral => .neutral,
            .lut => |lut| .{ .lut = lut: {
                const c = try arena.create(cube_lut.Lut);
                c.* = try lut.clone(arena);
                break :lut c;
            } },
            .fitted => |m| .{ .fitted = fitted: {
                const c = try arena.create(model.Model);
                c.* = m.*;
                if (m.lut) |lut| {
                    const l = try arena.create(model.Lut);
                    l.* = lut.*;
                    c.lut = l;
                }
                break :fitted c;
            } },
        };
    }
};

/// Renders `scan` with `settings` and `look`: linear sRGB, on every core.
pub fn render(gpa: std.mem.Allocator, scan: image.Scan, settings: develop.Settings, look: Resolved) !image.Rendered {
    const rendered: image.Rendered = try .init(gpa, scan.width, scan.height);
    renderPixels(.init(look.settingsFor(settings)), look, scan.pixels, rendered.pixels);
    return rendered;
}

/// The most threads a render uses.
const max_threads = 16;
/// Below this many pixels, starting threads costs more than it saves.
const min_parallel_pixels = 64 * 1024;

/// Develops `raw` into `out`, applies `look` and then the saturation, split over the cores. Each pixel stands alone, so
/// the result is the same however it's split.
pub fn renderPixels(prepared: develop.Prepared, look: Resolved, raw: []const [3]u16, out: [][3]f32) void {
    std.debug.assert(raw.len == out.len);
    const cores = std.Thread.getCpuCount() catch 1;
    const count = @min(max_threads, cores, @max(1, raw.len / min_parallel_pixels));
    const share = (raw.len + count - 1) / count;
    var threads: [max_threads]?std.Thread = @splat(null);
    for (threads[0 .. count - 1], 0..) |*thread, i| {
        const from = i * share;
        const to = @min(raw.len, from + share);
        thread.* = std.Thread.spawn(.{}, renderBand, .{ prepared, look, raw[from..to], out[from..to] }) catch null;
        // Without a thread, the band is done here.
        if (thread.* == null) renderBand(prepared, look, raw[from..to], out[from..to]);
    }
    const last = (count - 1) * share;
    renderBand(prepared, look, raw[last..], out[last..]);
    for (threads[0 .. count - 1]) |thread| if (thread) |t| t.join();
}

fn renderBand(prepared: develop.Prepared, look: Resolved, raw: []const [3]u16, out: [][3]f32) void {
    for (out, raw) |*o, r| o.* = develop.pixel(prepared, r);
    look.apply(out);
    develop.saturate(prepared, out);
}

/// Develops `scan` with `look` and automatic settings measured on `area`, on the film base
/// `film_base` when it's known from elsewhere, such as the gaps between frames, or else the
/// thinnest film in `area`.
pub fn developFrame(gpa: std.mem.Allocator, scan: image.Scan, area: image.Area, kind: develop.FilmKind, look: Resolved, film_base: ?[3]f32) !image.Rendered {
    const stats = try develop.Statistics.measure(gpa, scan, area.centre(develop.measured_fraction));
    const whole = try develop.Statistics.measure(gpa, scan, area);
    return render(gpa, scan, develop.automatic(kind, film_base orelse whole.thinnest, stats), look);
}

/// The largest .cube file read, 64 MiB: a 129-point 3D LUT in text is about 60.
const max_cube_bytes = 64 << 20;

/// Reads the looks ids name, once each: the built-in ones from minilab itself, imported LUTs and
/// fitted looks from the library's Looks folder. One thread at a time.
pub const Catalog = struct {
    /// `<library>/Looks`; null without a library, when only the built-in looks are there.
    folder: ?[]u8 = null,
    builtins: std.EnumArray(Builtin, ?*cube_lut.Lut) = .initFill(null),
    /// The looks read from the folder, by id; null for one that couldn't be read.
    read: std.StringArrayHashMapUnmanaged(?Loaded) = .empty,

    const Loaded = union(enum) {
        lut: *cube_lut.Lut,
        fitted: *saved.Look,
    };

    pub fn init(gpa: std.mem.Allocator, library: ?[]const u8) !Catalog {
        return .{ .folder = if (library) |l| try saved.folderOf(gpa, l) else null };
    }

    pub fn deinit(catalog: *Catalog, gpa: std.mem.Allocator) void {
        for (&catalog.builtins.values) |*b| if (b.*) |lut| {
            lut.deinit(gpa);
            gpa.destroy(lut);
        };
        catalog.forgetAll(gpa);
        catalog.read.deinit(gpa);
        if (catalog.folder) |f| gpa.free(f);
        catalog.* = undefined;
    }

    /// The look `id` names, read if it isn't yet. One that can't be read is Neutral, with a
    /// warning the first time.
    pub fn resolve(catalog: *Catalog, gpa: std.mem.Allocator, io: std.Io, id: Id) Resolved {
        switch (id.kind()) {
            .builtin => |b| {
                const file = b.cubeFile() orelse return .neutral;
                const slot = catalog.builtins.getPtr(b);
                if (slot.* == null) slot.* = parsed(gpa, file) catch |err| {
                    std.log.err("the built-in look {s} doesn't read: {t}", .{ b.label(), err });
                    return .neutral;
                };
                return .{ .lut = slot.*.? };
            },
            .cube, .fitted => {},
        }
        const entry = catalog.read.getOrPut(gpa, id.text()) catch return .neutral;
        if (!entry.found_existing) {
            entry.key_ptr.* = gpa.dupe(u8, id.text()) catch {
                catalog.read.swapRemoveAt(entry.index);
                return .neutral;
            };
            entry.value_ptr.* = catalog.load(gpa, io, id) catch |err| loaded: {
                std.log.warn("the look {s} can't be read: {t}; developing with Neutral", .{ id.label(), err });
                break :loaded null;
            };
        }
        const loaded = entry.value_ptr.* orelse return .neutral;
        return switch (loaded) {
            .lut => |lut| .{ .lut = lut },
            .fitted => |look| .{ .fitted = &look.model },
        };
    }

    fn load(catalog: *Catalog, gpa: std.mem.Allocator, io: std.Io, id: Id) !Loaded {
        const folder = catalog.folder orelse return error.NoLibrary;
        switch (id.kind()) {
            .builtin => unreachable,
            .cube => |name| {
                const file = try std.fmt.allocPrint(gpa, "{s}.cube", .{name});
                defer gpa.free(file);
                const path = try std.fs.path.join(gpa, &.{ folder, file });
                defer gpa.free(path);
                const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(max_cube_bytes));
                defer gpa.free(bytes);
                return .{ .lut = try parsed(gpa, bytes) };
            },
            .fitted => |name| {
                const path = try std.fs.path.join(gpa, &.{ folder, name });
                defer gpa.free(path);
                const look = try gpa.create(saved.Look);
                errdefer gpa.destroy(look);
                look.* = try saved.Look.load(gpa, io, path);
                return .{ .fitted = look };
            },
        }
    }

    fn parsed(gpa: std.mem.Allocator, bytes: []const u8) !*cube_lut.Lut {
        const lut = try gpa.create(cube_lut.Lut);
        errdefer gpa.destroy(lut);
        lut.* = try cube_lut.Lut.parse(gpa, bytes);
        return lut;
    }

    /// Forgets the look `id`, so that it is read again when next asked for: after it changes.
    pub fn forget(catalog: *Catalog, gpa: std.mem.Allocator, id: Id) void {
        const index = catalog.read.getIndex(id.text()) orelse return;
        free(gpa, catalog.read.keys()[index], catalog.read.values()[index]);
        catalog.read.swapRemoveAt(index);
    }

    /// Forgets every look read from the folder.
    pub fn forgetAll(catalog: *Catalog, gpa: std.mem.Allocator) void {
        for (catalog.read.keys(), catalog.read.values()) |key, value| free(gpa, key, value);
        catalog.read.clearRetainingCapacity();
    }

    fn free(gpa: std.mem.Allocator, key: []const u8, value: ?Loaded) void {
        gpa.free(key);
        const loaded = value orelse return;
        switch (loaded) {
            .lut => |lut| {
                lut.deinit(gpa);
                gpa.destroy(lut);
            },
            .fitted => |look| {
                look.deinit(gpa);
                gpa.destroy(look);
            },
        }
    }

    /// A look to choose from.
    pub const Choice = struct {
        id: Id,
        group: Group,

        pub const Group = enum { builtin, imported, fitted };
    };

    /// Every look there is to choose from: the built-in ones, then imported LUTs and fitted looks
    /// by name. The caller frees the list.
    pub fn choices(catalog: *const Catalog, gpa: std.mem.Allocator, io: std.Io) !std.ArrayList(Choice) {
        var list: std.ArrayList(Choice) = .empty;
        errdefer list.deinit(gpa);
        for (std.enums.values(Builtin)) |b| try list.append(gpa, .{ .id = .builtin(b), .group = .builtin });
        const folder = catalog.folder orelse return list;
        var dir = std.Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return list;
        defer dir.close(io);
        var cubes: std.ArrayList(Choice) = .empty;
        defer cubes.deinit(gpa);
        var fitted: std.ArrayList(Choice) = .empty;
        defer fitted.deinit(gpa);
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            // Exactly as `load` and `remove` name the file, so that every LUT listed can be read.
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".cube")) {
                const id = Id.ofCube(entry.name[0 .. entry.name.len - ".cube".len]) catch continue;
                try cubes.append(gpa, .{ .id = id, .group = .imported });
            } else if (entry.kind == .directory) {
                // A fitted look is ready once its look.json is there.
                var look_dir = dir.openDir(io, entry.name, .{}) catch continue;
                defer look_dir.close(io);
                look_dir.access(io, saved.look_file, .{}) catch continue;
                const id = Id.ofFitted(entry.name) catch continue;
                try fitted.append(gpa, .{ .id = id, .group = .fitted });
            }
        }
        for ([_][]Choice{ cubes.items, fitted.items }) |group| {
            std.mem.sort(Choice, group, {}, byLabel);
            try list.appendSlice(gpa, group);
        }
        return list;
    }

    fn byLabel(_: void, a: Choice, b: Choice) bool {
        return std.ascii.lessThanIgnoreCase(a.id.label(), b.id.label());
    }

    /// Copies the .cube file at `path` into the Looks folder, checked first, under its own name or,
    /// when that's taken, its name and a number. Returns the new look's id.
    pub fn import(catalog: *Catalog, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !Id {
        const folder = catalog.folder orelse return error.NoLibrary;
        const cwd = std.Io.Dir.cwd();
        const bytes = try cwd.readFileAlloc(io, path, gpa, .limited(max_cube_bytes));
        defer gpa.free(bytes);
        var lut = try cube_lut.Lut.parse(gpa, bytes);
        lut.deinit(gpa);

        try cwd.createDirPath(io, folder);
        const stem = std.fs.path.stem(path);
        var number: usize = 1;
        while (true) : (number += 1) {
            const name = if (number == 1) try gpa.dupe(u8, stem) else try std.fmt.allocPrint(gpa, "{s} {d}", .{ stem, number });
            defer gpa.free(name);
            const id = try Id.ofCube(name);
            const file = try std.fmt.allocPrint(gpa, "{s}.cube", .{name});
            defer gpa.free(file);
            const target = try std.fs.path.join(gpa, &.{ folder, file });
            defer gpa.free(target);
            cwd.access(io, target, .{}) catch {
                try cwd.writeFile(io, .{ .sub_path = target, .data = bytes });
                catalog.forget(gpa, id);
                return id;
            };
        }
    }

    /// Deletes the imported LUT `id` from the Looks folder: the library's copy, not the file it was
    /// imported from.
    pub fn remove(catalog: *Catalog, gpa: std.mem.Allocator, io: std.Io, id: Id) !void {
        const folder = catalog.folder orelse return error.NoLibrary;
        const name = switch (id.kind()) {
            .cube => |n| n,
            else => return error.NotImported,
        };
        catalog.forget(gpa, id);
        const file = try std.fmt.allocPrint(gpa, "{s}.cube", .{name});
        defer gpa.free(file);
        const path = try std.fs.path.join(gpa, &.{ folder, file });
        defer gpa.free(path);
        try std.Io.Dir.cwd().deleteFile(io, path);
    }
};

test "ids keep their kind, and old rolls' Frontier tag reads as Frontier emulation" {
    try std.testing.expectEqual(Builtin.neutral, Id.neutral.kind().builtin);
    const imported = try Id.ofCube("Kodachrome-ish");
    try std.testing.expectEqualStrings("Kodachrome-ish", imported.kind().cube);
    try std.testing.expectEqualStrings("Kodachrome-ish", imported.label());
    const fitted = try Id.ofFitted("My lab");
    try std.testing.expectEqualStrings("My lab", fitted.kind().fitted);

    const gpa = std.testing.allocator;
    const Holder = struct { look: Id = .neutral };
    const written = try std.json.Stringify.valueAlloc(gpa, Holder{ .look = imported }, .{});
    defer gpa.free(written);
    try std.testing.expectEqualStrings("{\"look\":\"cube:Kodachrome-ish\"}", written);
    const back = try std.json.parseFromSlice(Holder, gpa, written, .{});
    defer back.deinit();
    try std.testing.expect(back.value.look.eql(&imported));
    const old = try std.json.parseFromSlice(Holder, gpa, "{\"look\":\"frontier_emulation\"}", .{});
    defer old.deinit();
    try std.testing.expect(old.value.look.eql(&Id.frontier));
}

test "a render split over threads is the same as one in one piece" {
    const gpa = std.testing.allocator;
    var scan: image.Scan = try .init(gpa, 400, 400);
    defer scan.deinit(gpa);
    for (scan.pixels, 0..) |*p, i| p.* = .{ @intCast(1000 + i % 30000), @intCast(800 + i % 20000), @intCast(500 + i % 9000) };
    var catalog: Catalog = try .init(gpa, null);
    defer catalog.deinit(gpa);
    const look = catalog.resolve(gpa, undefined, .frontier);
    const settings: develop.Settings = .{};
    var whole = try render(gpa, scan, settings, look);
    defer whole.deinit(gpa);
    const one = try gpa.alloc([3]f32, scan.pixels.len);
    defer gpa.free(one);
    renderBand(.init(settings), look, scan.pixels, one);
    try std.testing.expectEqualSlices([3]f32, one, whole.pixels);
}

test "Frontier emulation leaves neutrals and keeps close to Neutral" {
    const gpa = std.testing.allocator;
    var catalog: Catalog = try .init(gpa, null);
    defer catalog.deinit(gpa);
    const look = catalog.resolve(gpa, undefined, .frontier);
    try std.testing.expect(look == .lut);
    for ([_]f32{ 0.002, 0.05, 0.18, 0.5, 0.9 }) |v| {
        var pixels = [_][3]f32{.{ v, v, v }};
        look.apply(&pixels);
        for (pixels[0]) |o| try std.testing.expectApproxEqAbs(v, o, 1e-3 * @max(v, 0.05));
    }
    // A mid green moves, but not far.
    var green = [_][3]f32{.{ 0.12, 0.3, 0.06 }};
    look.apply(&green);
    try std.testing.expect(@abs(encode.srgb(green[0][1]) - encode.srgb(0.3)) < 0.05);
    try std.testing.expect(green[0][2] != 0.06);
}
