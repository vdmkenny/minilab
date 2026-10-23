//! The .cube LUT format, the way Adobe and Resolve read it: a title, the input range, the grid
//! size, and then one output colour per line, with red changing fastest.

const std = @import("std");
const model = @import("model.zig");
const cube_lut = @import("../core/cube_lut.zig");

const Lut = model.Lut;

/// Writes `lut` as a .cube file titled `title`, with `comments` at the top, one per line. The
/// caller owns the returned bytes.
pub fn write(gpa: std.mem.Allocator, lut: *const Lut, title: []const u8, comments: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    for (comments) |line| try w.print("# {s}\n", .{line});
    // A double quote would end the title early in other software, so we write an apostrophe
    // instead.
    try w.writeAll("TITLE \"");
    for (title) |ch| try w.writeByte(if (ch == '"') '\'' else ch);
    try w.writeAll("\"\n");
    try w.print("LUT_3D_SIZE {d}\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n", .{model.lut_size});
    for (lut.values) |v| try w.print("{d:.6} {d:.6} {d:.6}\n", .{ v[0], v[1], v[2] });
    return out.toOwnedSlice();
}

pub const ReadError = cube_lut.ParseError || error{WrongSize};

/// Reads a .cube file holding a 33³ LUT over 0..1 into `lut`, with the core's parser.
pub fn read(gpa: std.mem.Allocator, bytes: []const u8, lut: *Lut) ReadError!void {
    var parsed = try cube_lut.Lut.parse(gpa, bytes);
    defer parsed.deinit(gpa);
    if (parsed.one != null) return error.NotACube;
    const three = parsed.three orelse return error.NotACube;
    if (three.size != model.lut_size) return error.WrongSize;
    for (three.min, three.max) |low, high| if (low != 0 or high != 1) return error.NotACube;
    @memcpy(&lut.values, three.values);
}

test "a LUT round-trips through a .cube file" {
    const gpa = std.testing.allocator;
    const lut = try gpa.create(Lut);
    defer gpa.destroy(lut);
    lut.setIdentity();
    lut.values[Lut.index(3, 5, 7)] = .{ 0.25, 0.5, 0.75 };
    const bytes = try write(gpa, lut, "Test", &.{"made by a test"});
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "LUT_3D_SIZE 33") != null);

    const again = try gpa.create(Lut);
    defer gpa.destroy(again);
    try read(gpa, bytes, again);
    try std.testing.expectEqual([3]f32{ 0.25, 0.5, 0.75 }, again.values[Lut.index(3, 5, 7)]);
    for (lut.values, again.values) |a, b| {
        for (a, b) |x, y| try std.testing.expectApproxEqAbs(x, y, 1e-6);
    }
    try std.testing.expectError(error.Truncated, read(gpa, bytes[0 .. bytes.len / 2], again));
}
