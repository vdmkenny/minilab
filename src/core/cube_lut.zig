//! LUTs from .cube files, as Resolve, Adobe and most grading tools write them: a 3D LUT, a 1D
//! LUT, or a 1D shaper followed by a 3D LUT, of any size and over any input range.
//!
//! A look made of one is laid over Neutral's sRGB-encoded output, so it should expect sRGB or
//! Rec. 709 input with a display gamma, as most film and creative LUTs do. 3D LUTs are read with
//! tetrahedral interpolation, which keeps greys on the grey axis.

const std = @import("std");

/// The largest 3D LUT read: 129 points a side, as the biggest common ones have.
pub const max_size_3d = 129;
pub const max_size_1d = 65536;

pub const ParseError = error{ NotACube, BadSize, Truncated, TooMuchData, InvalidNumber, OutOfMemory };

pub const Lut = struct {
    title: []u8,
    /// A 1D LUT per channel, applied first; alone, it is the whole LUT.
    one: ?Table = null,
    /// The 3D LUT, red changing fastest, then green, then blue.
    three: ?Table = null,

    pub const Table = struct {
        size: usize,
        min: [3]f32 = @splat(0),
        max: [3]f32 = @splat(1),
        values: [][3]f32,
    };

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) ParseError!Lut {
        var title: []const u8 = "";
        var one_size: ?usize = null;
        var three_size: ?usize = null;
        var one_range: [2][3]f32 = .{ @splat(0), @splat(1) };
        var three_range: [2][3]f32 = .{ @splat(0), @splat(1) };
        var data_lines: usize = 0;

        // First the keywords, then the data, which follows them.
        var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#') continue;
            if (isDataLine(line)) {
                data_lines += 1;
                continue;
            }
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const keyword = fields.next().?;
            if (std.mem.eql(u8, keyword, "TITLE")) {
                title = std.mem.trim(u8, line["TITLE".len..], " \t\"");
            } else if (std.mem.eql(u8, keyword, "LUT_3D_SIZE")) {
                three_size = try sizeOf(fields.next(), 2, max_size_3d);
            } else if (std.mem.eql(u8, keyword, "LUT_1D_SIZE")) {
                one_size = try sizeOf(fields.next(), 2, max_size_1d);
            } else if (std.mem.eql(u8, keyword, "DOMAIN_MIN")) {
                const v = try triple(&fields);
                one_range[0] = v;
                three_range[0] = v;
            } else if (std.mem.eql(u8, keyword, "DOMAIN_MAX")) {
                const v = try triple(&fields);
                one_range[1] = v;
                three_range[1] = v;
            } else if (std.mem.eql(u8, keyword, "LUT_1D_INPUT_RANGE")) {
                const range = try pair(&fields);
                one_range = .{ @splat(range[0]), @splat(range[1]) };
            } else if (std.mem.eql(u8, keyword, "LUT_3D_INPUT_RANGE")) {
                const range = try pair(&fields);
                three_range = .{ @splat(range[0]), @splat(range[1]) };
            }
            // Other keywords, such as LUT_IN_VIDEO_RANGE, change nothing here.
        }
        if (one_size == null and three_size == null) return error.NotACube;
        const one_count = one_size orelse 0;
        const three_count = if (three_size) |s| s * s * s else 0;
        if (data_lines < one_count + three_count) return error.Truncated;
        if (data_lines > one_count + three_count) return error.TooMuchData;
        for (one_range[0], one_range[1]) |lo, hi| if (!(hi > lo)) return error.NotACube;
        for (three_range[0], three_range[1]) |lo, hi| if (!(hi > lo)) return error.NotACube;

        var lut: Lut = .{ .title = try gpa.dupe(u8, title) };
        errdefer lut.deinit(gpa);
        if (one_size) |size| lut.one = .{ .size = size, .min = one_range[0], .max = one_range[1], .values = try gpa.alloc([3]f32, size) };
        if (three_size) |size| lut.three = .{ .size = size, .min = three_range[0], .max = three_range[1], .values = try gpa.alloc([3]f32, three_count) };

        var filled: usize = 0;
        lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
        while (lines.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t");
            if (line.len == 0 or line[0] == '#' or !isDataLine(line)) continue;
            var fields = std.mem.tokenizeAny(u8, line, " \t");
            const v = try triple(&fields);
            if (filled < one_count) lut.one.?.values[filled] = v else lut.three.?.values[filled - one_count] = v;
            filled += 1;
        }
        return lut;
    }

    pub fn deinit(lut: *Lut, gpa: std.mem.Allocator) void {
        gpa.free(lut.title);
        if (lut.one) |t| gpa.free(t.values);
        if (lut.three) |t| gpa.free(t.values);
        lut.* = undefined;
    }

    /// A copy in `gpa`, for another thread.
    pub fn clone(lut: *const Lut, gpa: std.mem.Allocator) error{OutOfMemory}!Lut {
        var copy: Lut = .{ .title = try gpa.dupe(u8, lut.title) };
        errdefer copy.deinit(gpa);
        if (lut.one) |t| copy.one = .{ .size = t.size, .min = t.min, .max = t.max, .values = try gpa.dupe([3]f32, t.values) };
        if (lut.three) |t| copy.three = .{ .size = t.size, .min = t.min, .max = t.max, .values = try gpa.dupe([3]f32, t.values) };
        return copy;
    }

    /// The LUT's output for `rgb`.
    pub fn lookup(lut: *const Lut, rgb: [3]f32) [3]f32 {
        var v = rgb;
        if (lut.one) |*t| {
            for (&v, 0..) |*x, c| x.* = oneD(t, c, x.*);
        }
        if (lut.three) |*t| v = threeD(t, v);
        return v;
    }

    /// "3D, 33 points a side" or "1D, 4096 points", for people.
    pub fn describe(lut: *const Lut, buffer: []u8) []const u8 {
        if (lut.three) |t| return std.fmt.bufPrint(buffer, "3D, {d} points a side", .{t.size}) catch "3D";
        return std.fmt.bufPrint(buffer, "1D, {d} points", .{lut.one.?.size}) catch "1D";
    }
};

fn isDataLine(line: []const u8) bool {
    return switch (line[0]) {
        '0'...'9', '-', '+', '.' => true,
        else => false,
    };
}

fn sizeOf(field: ?[]const u8, min: usize, max: usize) ParseError!usize {
    const size = std.fmt.parseInt(usize, field orelse return error.BadSize, 10) catch return error.BadSize;
    if (size < min or size > max) return error.BadSize;
    return size;
}

fn triple(fields: *std.mem.TokenIterator(u8, .any)) ParseError![3]f32 {
    var v: [3]f32 = undefined;
    for (&v) |*x| {
        const field = fields.next() orelse return error.Truncated;
        x.* = std.fmt.parseFloat(f32, field) catch return error.InvalidNumber;
        if (!std.math.isFinite(x.*)) return error.InvalidNumber;
    }
    return v;
}

fn pair(fields: *std.mem.TokenIterator(u8, .any)) ParseError![2]f32 {
    var v: [2]f32 = undefined;
    for (&v) |*x| {
        const field = fields.next() orelse return error.Truncated;
        x.* = std.fmt.parseFloat(f32, field) catch return error.InvalidNumber;
        if (!std.math.isFinite(x.*)) return error.InvalidNumber;
    }
    return v;
}

/// Where `x` falls on a table's grid of `size` points over `min`..`max`: the cell and how far in.
fn position(x: f32, min: f32, max: f32, size: usize) struct { usize, f32 } {
    const top: f32 = @floatFromInt(size - 1);
    const t = std.math.clamp((x - min) / (max - min), 0, 1) * top;
    const i: usize = @min(@as(usize, @intFromFloat(t)), size - 2);
    return .{ i, t - @as(f32, @floatFromInt(i)) };
}

fn oneD(t: *const Lut.Table, channel: usize, x: f32) f32 {
    const i, const f = position(x, t.min[channel], t.max[channel], t.size);
    return t.values[i][channel] * (1 - f) + t.values[i + 1][channel] * f;
}

/// Tetrahedral interpolation: the cell is cut into six tetrahedra along its grey diagonal, and the
/// four corners of the one `rgb` falls in are weighted.
fn threeD(t: *const Lut.Table, rgb: [3]f32) [3]f32 {
    var cell: [3]usize = undefined;
    var f: [3]f32 = undefined;
    for (&cell, &f, rgb, 0..) |*i, *frac, x, c| i.*, frac.* = position(x, t.min[c], t.max[c], t.size);
    const n = t.size;
    const corner = struct {
        fn at(table: *const Lut.Table, size: usize, base: [3]usize, dr: usize, dg: usize, db: usize) [3]f32 {
            return table.values[((base[2] + db) * size + base[1] + dg) * size + base[0] + dr];
        }
    }.at;
    const fr = f[0];
    const fg = f[1];
    const fb = f[2];
    const c000 = corner(t, n, cell, 0, 0, 0);
    const c111 = corner(t, n, cell, 1, 1, 1);
    // The tetrahedron's two middle corners and the weights of all four.
    var a: [3]f32 = undefined;
    var b: [3]f32 = undefined;
    var w: [4]f32 = undefined;
    if (fr > fg) {
        if (fg > fb) {
            a = corner(t, n, cell, 1, 0, 0);
            b = corner(t, n, cell, 1, 1, 0);
            w = .{ 1 - fr, fr - fg, fg - fb, fb };
        } else if (fr > fb) {
            a = corner(t, n, cell, 1, 0, 0);
            b = corner(t, n, cell, 1, 0, 1);
            w = .{ 1 - fr, fr - fb, fb - fg, fg };
        } else {
            a = corner(t, n, cell, 0, 0, 1);
            b = corner(t, n, cell, 1, 0, 1);
            w = .{ 1 - fb, fb - fr, fr - fg, fg };
        }
    } else {
        if (fb > fg) {
            a = corner(t, n, cell, 0, 0, 1);
            b = corner(t, n, cell, 0, 1, 1);
            w = .{ 1 - fb, fb - fg, fg - fr, fr };
        } else if (fb > fr) {
            a = corner(t, n, cell, 0, 1, 0);
            b = corner(t, n, cell, 0, 1, 1);
            w = .{ 1 - fg, fg - fb, fb - fr, fr };
        } else {
            a = corner(t, n, cell, 0, 1, 0);
            b = corner(t, n, cell, 1, 1, 0);
            w = .{ 1 - fg, fg - fr, fr - fb, fb };
        }
    }
    var out: [3]f32 = undefined;
    for (&out, c000, a, b, c111) |*o, p0, p1, p2, p3| o.* = w[0] * p0 + w[1] * p1 + w[2] * p2 + w[3] * p3;
    return out;
}

const test_identity_2 =
    \\# An identity, the smallest there is.
    \\TITLE "Identity"
    \\LUT_3D_SIZE 2
    \\
++ test_identity_data;

const test_identity_data =
    \\0 0 0
    \\1 0 0
    \\0 1 0
    \\1 1 0
    \\0 0 1
    \\1 0 1
    \\0 1 1
    \\1 1 1
    \\
;

test "an identity 3D LUT gives back its input" {
    const gpa = std.testing.allocator;
    var lut = try Lut.parse(gpa, test_identity_2);
    defer lut.deinit(gpa);
    try std.testing.expectEqualStrings("Identity", lut.title);
    for ([_][3]f32{ .{ 0.2, 0.55, 0.91 }, .{ 0.9, 0.1, 0.4 }, .{ 0, 1, 0.5 } }) |rgb| {
        const out = lut.lookup(rgb);
        for (out, rgb) |o, i| try std.testing.expectApproxEqAbs(i, o, 1e-6);
    }
}

test "tetrahedral interpolation keeps greys grey" {
    const gpa = std.testing.allocator;
    // A LUT that moves every off-grey corner, but leaves the grey ones.
    var lut = try Lut.parse(gpa,
        \\LUT_3D_SIZE 2
        \\0 0 0
        \\0.9 0.2 0.1
        \\0.1 0.8 0.3
        \\0.7 0.9 0.2
        \\0.2 0.1 0.9
        \\0.8 0.3 0.7
        \\0.2 0.9 0.8
        \\1 1 1
        \\
    );
    defer lut.deinit(gpa);
    for ([_]f32{ 0.1, 0.5, 0.77 }) |v| {
        const out = lut.lookup(.{ v, v, v });
        for (out) |o| try std.testing.expectApproxEqAbs(v, o, 1e-6);
    }
}

test "1D LUTs, input ranges and a shaper before a 3D LUT" {
    const gpa = std.testing.allocator;
    var one = try Lut.parse(gpa,
        \\LUT_1D_SIZE 3
        \\DOMAIN_MIN 0 0 0
        \\DOMAIN_MAX 2 2 2
        \\0 0 0
        \\0.25 0.5 0.75
        \\1 1 1
        \\
    );
    defer one.deinit(gpa);
    const out = one.lookup(.{ 1, 0.5, 2 });
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), out[0], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), out[1], 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), out[2], 1e-6);

    var both = try Lut.parse(gpa, "LUT_1D_SIZE 2\nLUT_3D_SIZE 2\n0 0 0\n0.5 0.5 0.5\n" ++ test_identity_data);
    defer both.deinit(gpa);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), both.lookup(.{ 0.5, 0.5, 0.5 })[1], 1e-6);
}

test "broken files are refused" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(error.NotACube, Lut.parse(gpa, "hello\n"));
    try std.testing.expectError(error.Truncated, Lut.parse(gpa, "LUT_3D_SIZE 2\n0 0 0\n"));
    try std.testing.expectError(error.TooMuchData, Lut.parse(gpa, test_identity_2 ++ "1 1 1\n"));
    try std.testing.expectError(error.BadSize, Lut.parse(gpa, "LUT_3D_SIZE 1000\n"));
    try std.testing.expectError(error.InvalidNumber, Lut.parse(gpa, "LUT_3D_SIZE 2\n0 0 x\n" ++ test_identity_data[6..]));
}
