//! The user's looks on disk, in the library's Looks folder, one folder each:
//!
//!     Looks/<name>/draft.json     the pairs and choices it is fitted from (draft.zig)
//!     Looks/<name>/look.json      the look: its curves and matrix, and how well it fitted
//!     Looks/<name>/residual.cube  its 33³ LUT, when the fit kept one
//!     Looks/<name>/look.cube      the whole look as one 33³ LUT, for other software
//!
//! A look takes over from Develop after the film base and density stages (model.zig). To apply
//! one, render the frame with Develop's Log tone, then `Look.apply` the linear output.

const std = @import("std");
const Io = std.Io;
const model = @import("model.zig");
const cube = @import("cube.zig");
const fit = @import("fit.zig");

pub const looks_folder = "Looks";
pub const draft_file = "draft.json";
pub const look_file = "look.json";
pub const lut_file = "residual.cube";
pub const baked_file = "look.cube";

const json_options: std.json.Stringify.Options = .{ .whitespace = .indent_2 };
const max_json_bytes = 4 << 20;
const max_cube_bytes = 8 << 20;

/// look.json as it is written.
pub const File = struct {
    name: []const u8,
    /// What the look expects, for whoever reads the file.
    input: []const u8 = "Density 0..1 per channel, as minilab's Log tone stores it, sRGB-encoded",
    output: []const u8 = "sRGB",
    /// Density in, mixed: each row adds up to 1.
    matrix: model.Matrix,
    /// R, G and B: 33 points each over density 0..1, to sRGB-encoded output.
    curves: [3]model.Curve,
    /// The LUT on the curves' output, when there is one: its file in the same folder.
    lut: ?[]const u8 = null,
    /// ΔE2000 over the held-out pairs, when there were some.
    median: ?f32 = null,
    p95: ?f32 = null,
    fitted_pairs: usize = 0,
    held_out_pairs: usize = 0,
};

/// A saved look, read back to apply.
pub const Look = struct {
    name: []u8,
    model: model.Model,
    lut: ?*model.Lut,

    /// Reads the look in `folder`, such as `<library>/Looks/<name>`.
    pub fn load(gpa: std.mem.Allocator, io: Io, folder: []const u8) !Look {
        var arena: std.heap.ArenaAllocator = .init(gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const cwd = Io.Dir.cwd();
        const bytes = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ folder, look_file }), a, .limited(max_json_bytes));
        const file = try std.json.parseFromSliceLeaky(File, a, bytes, .{ .ignore_unknown_fields = true });
        const name = try gpa.dupe(u8, file.name);
        errdefer gpa.free(name);
        var look: Look = .{ .name = name, .model = .{ .matrix = file.matrix, .curves = file.curves }, .lut = null };
        if (file.lut) |lut_name| {
            const lut = try gpa.create(model.Lut);
            errdefer gpa.destroy(lut);
            const lut_bytes = try cwd.readFileAlloc(io, try std.fs.path.join(a, &.{ folder, std.fs.path.basename(lut_name) }), a, .limited(max_cube_bytes));
            try cube.read(lut_bytes, lut);
            look.lut = lut;
            look.model.lut = lut;
        }
        return look;
    }

    pub fn deinit(look: *Look, gpa: std.mem.Allocator) void {
        gpa.free(look.name);
        if (look.lut) |l| gpa.destroy(l);
        look.* = undefined;
    }

    /// Applies the look in place to `pixels`: the linear output of `develop.render` with
    /// `.tone = .log`. They become linear sRGB 0..1, ready for `encode`.
    pub fn apply(look: *const Look, pixels: [][3]f32) void {
        var m = look.model;
        m.lut = look.lut;
        m.apply(pixels);
    }
};

/// Writes `result` as the look `name` into `folder`, made if need be: look.json, the LUT if the
/// fit kept one, and the whole look baked into one .cube.
pub fn save(gpa: std.mem.Allocator, io: Io, folder: []const u8, name: []const u8, result: *const fit.Result) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, folder);

    const file: File = .{
        .name = name,
        .matrix = result.model.matrix,
        .curves = result.model.curves,
        .lut = if (result.lut != null) lut_file else null,
        .median = result.report.median,
        .p95 = result.report.p95,
        .fitted_pairs = result.report.fitted_pairs,
        .held_out_pairs = result.report.held_out_pairs,
    };
    if (result.lut) |lut| {
        const bytes = try cube.write(a, lut, name, &.{
            "minilab look: what the curves and matrix leave, applied to the curves' output.",
            "Input and output: sRGB-encoded 0..1.",
        });
        try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ folder, lut_file }), .data = bytes });
    }

    const baked = try a.create(model.Lut);
    for (&baked.values, 0..) |*v, i| v.* = result.model.encoded(model.Lut.input(i), @splat(0));
    const baked_bytes = try cube.write(a, baked, name, &.{
        "minilab look, whole: density matrix, channel curves and LUT in one.",
        "Input: density 0..1 per channel, as minilab's Log tone writes it. Output: sRGB.",
    });
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ folder, baked_file }), .data = baked_bytes });

    const json = try std.json.Stringify.valueAlloc(a, file, json_options);
    try cwd.writeFile(io, .{ .sub_path = try std.fs.path.join(a, &.{ folder, look_file }), .data = json });
}

/// A look's folder in the library.
pub const Entry = struct {
    name: []u8,
    path: []u8,
    /// Whether look.json is there: the look can be applied.
    saved: bool,

    pub fn deinit(entry: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(entry.name);
        gpa.free(entry.path);
    }
};

/// The folder of looks in `library`.
pub fn folderOf(gpa: std.mem.Allocator, library: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ library, looks_folder });
}

/// The looks in `library`, by name: folders under Looks with a look.json or a draft.json.
pub fn list(gpa: std.mem.Allocator, io: Io, library: []const u8) !std.ArrayList(Entry) {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }
    const root = try folderOf(gpa, library);
    defer gpa.free(root);
    var dir = Io.Dir.cwd().openDir(io, root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return entries,
        else => return err,
    };
    defer dir.close(io);
    var each = dir.iterate();
    while (try each.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        const saved = exists(io, dir, entry.name, look_file);
        if (!saved and !exists(io, dir, entry.name, draft_file)) continue;
        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        const path = try std.fs.path.join(gpa, &.{ root, entry.name });
        errdefer gpa.free(path);
        try entries.append(gpa, .{ .name = name, .path = path, .saved = saved });
    }
    std.mem.sort(Entry, entries.items, {}, byName);
    return entries;
}

fn exists(io: Io, dir: Io.Dir, folder: []const u8, file: []const u8) bool {
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buffer, "{s}/{s}", .{ folder, file }) catch return false;
    dir.access(io, path, .{}) catch return false;
    return true;
}

fn byName(_: void, a: Entry, b: Entry) bool {
    return std.ascii.lessThanIgnoreCase(a.name, b.name);
}

test "a look saved and loaded applies the same" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const library = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(library);
    const folder = try std.fs.path.join(gpa, &.{ library, looks_folder, "Test look" });
    defer gpa.free(folder);

    const lut = try gpa.create(model.Lut);
    lut.setIdentity();
    for (&lut.values) |*v| v[2] = @min(1, v[2] + 0.05);
    var curves: [3]model.Curve = undefined;
    for (&curves, 0..) |*c, k| {
        for (c, 0..) |*v, i| v.* = std.math.pow(f32, @as(f32, @floatFromInt(i)) / 32, 0.8 + 0.1 * @as(f32, @floatFromInt(k)));
    }
    var result: fit.Result = .{
        .model = .{ .matrix = .{ .{ 0.9, 0.1, 0 }, .{ 0, 1, 0 }, .{ 0, 0.05, 0.95 } }, .curves = curves, .lut = lut },
        .lut = lut,
        .balance = try gpa.alloc([3]f32, 0),
        .report = .{ .median = 1.5, .p95 = 3, .fitted_pairs = 4, .held_out_pairs = 1 },
    };
    defer result.deinit(gpa);
    try save(gpa, io, folder, "Test look", &result);

    var look = try Look.load(gpa, io, folder);
    defer look.deinit(gpa);
    try std.testing.expectEqualStrings("Test look", look.name);
    var a = [_][3]f32{.{ 0.05, 0.2, 0.6 }};
    var b = a;
    look.apply(&a);
    result.model.apply(&b);
    for (a[0], b[0]) |x, y| try std.testing.expectApproxEqAbs(y, x, 1e-5);

    var entries = try list(gpa, io, library);
    defer {
        for (entries.items) |*e| e.deinit(gpa);
        entries.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 1), entries.items.len);
    try std.testing.expect(entries.items[0].saved);
}
