//! A look being made: the pairs it is fitted from and the choices for the fit, kept in its
//! folder as draft.json as they change, so that work on a look survives closing the app.

const std = @import("std");
const Io = std.Io;
const fit = @import("fit.zig");
const register = @import("register.zig");
const saved = @import("saved.zig");
const image = @import("../core/image.zig");

/// Where the references come from.
pub const Source = enum {
    /// Our scans run through the Frontier's own software.
    frontier_software,
    /// A lab's scans of the same negatives.
    lab_scans,

    pub fn label(source: Source) []const u8 {
        return switch (source) {
            .frontier_software => "Frontier software, test runs",
            .lab_scans => "Lab scans of my negatives",
        };
    }

    /// As the list of looks says it.
    pub fn short(source: Source) []const u8 {
        return switch (source) {
            .frontier_software => "Frontier software",
            .lab_scans => "Lab scans",
        };
    }

    /// What one reference is called: the table's column, and the figure's caption.
    pub fn one(source: Source) []const u8 {
        return switch (source) {
            .frontier_software => "Frontier output",
            .lab_scans => "Lab scan",
        };
    }

    /// Whose correction of each frame the balance stands for.
    pub fn corrector(source: Source) []const u8 {
        return switch (source) {
            .frontier_software => "the Frontier's",
            .lab_scans => "the lab's",
        };
    }
};

/// Our raw scan of a negative and a reference rendering of the same negative.
/// Where a frame lies on its scan, and its film base, as its roll has them. Frames of a strip share
/// their scan, and each has its own place on it.
pub const Placement = struct {
    /// In the scan's pixels; null for all of it.
    crop: ?image.Area = null,
    /// The scan's size, which the crop is measured in, for smaller copies of the scan.
    width: usize = 0,
    height: usize = 0,
    quarter_turns: u2 = 0,
    mirrored: bool = false,
    film_base: ?[3]f32 = null,

    /// `scan`, a copy of the scan at any size, cut to the frame and turned. The caller frees it.
    pub fn apply(placement: Placement, gpa: std.mem.Allocator, scan: image.Scan) !image.Scan {
        const area: image.Area = if (placement.crop != null and placement.width > 0) placement.crop.?.rescale(placement.width, scan.width, scan.width, scan.height) else .whole(scan.width, scan.height);
        var cut = try scan.crop(gpa, area);
        defer cut.deinit(gpa);
        return cut.orient(gpa, placement.quarter_turns, placement.mirrored);
    }
};

pub const Pair = struct {
    /// Our raw scan's path.
    ours: []const u8,
    /// How the table names it: "Roll 014 / 03", or the file's name for a scan outside a roll.
    label: []const u8,
    /// The reference's path.
    theirs: []const u8,
    /// The film, as its roll says.
    stock: ?[]const u8 = null,
    /// Kept out of the fit, to check it.
    held_out: bool = false,
    /// Where the reference lies on ours, once it's been worked out.
    alignment: ?register.Alignment = null,
    /// Where our frame lies on its scan; null for a scan outside a roll, whose frame is found.
    placement: ?Placement = null,
};

pub const Draft = struct {
    references: Source = .frontier_software,
    options: fit.Options = .{},
    pairs: []const Pair = &.{},
};

/// Reads the draft in `folder`, allocated in `arena`; an empty draft when there's none.
pub fn load(arena: std.mem.Allocator, io: Io, folder: []const u8) !Draft {
    const path = try std.fs.path.join(arena, &.{ folder, saved.draft_file });
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(4 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    return std.json.parseFromSliceLeaky(Draft, arena, bytes, .{ .ignore_unknown_fields = true, .allocate = .alloc_always });
}

pub fn save(gpa: std.mem.Allocator, io: Io, folder: []const u8, draft: Draft) !void {
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, folder);
    const bytes = try std.json.Stringify.valueAlloc(gpa, draft, .{ .whitespace = .indent_2 });
    defer gpa.free(bytes);
    const path = try std.fs.path.join(gpa, &.{ folder, saved.draft_file });
    defer gpa.free(path);
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
}

/// Every third pair from the third on is held out: about a third of them, and none while there
/// are only two.
pub fn heldOutByDefault(index: usize) bool {
    return index % 3 == 2;
}

test "a draft round-trips" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const folder = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(folder);
    const pairs = [_]Pair{
        .{ .ours = "/r/Roll 1/scans/01.ppm", .label = "Roll 1 / 01", .theirs = "/x/fr_0001.jpg", .stock = "Kodak Portra 400" },
        .{ .ours = "/r/Roll 1/scans/02.ppm", .label = "Roll 1 / 02", .theirs = "/x/fr_0002.jpg", .held_out = true, .alignment = .{ .orientation = .quarter, .scale = 0.8, .offset = .{ 0.1, 0.05 }, .quality = 0.93 } },
    };
    try save(gpa, io, folder, .{ .references = .lab_scans, .options = .{ .lut = true }, .pairs = &pairs });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const again = try load(arena.allocator(), io, folder);
    try std.testing.expectEqual(Source.lab_scans, again.references);
    try std.testing.expect(again.options.lut);
    try std.testing.expectEqual(@as(usize, 2), again.pairs.len);
    try std.testing.expectEqualStrings("Roll 1 / 02", again.pairs[1].label);
    try std.testing.expectEqual(register.Orientation.quarter, again.pairs[1].alignment.?.orientation);
    try std.testing.expect(again.pairs[0].alignment == null);
}
