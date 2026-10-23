//! minilab's icon: the film strip from the logo, amber on a dark tile. The window uses it, and so
//! does the Windows program. We draw it in code instead of keeping image files, so every size
//! comes out sharp and the repository holds no images. `docs/icon.svg` is the same drawing.

const std = @import("std");

/// The amber of the logo and the dark grey of the tile, in sRGB.
const amber = [3]u8{ 0xE8, 0xA3, 0x3D };
const ground = [3]u8{ 0x1D, 0x1D, 0x1F };

/// The tile's margin, as a share of the icon's size, and its corner radius, as a share of the
/// tile's size. macOS draws app icons with these proportions.
const margin = 0.09;
const corner = 0.225;
/// How much of the tile the logo's 20-unit box takes up.
const logo_share = 0.8;
/// The logo's drawing, in its own 20-unit box: the stroke width and the film strip. The strip is
/// an outline, two rails along it, and the frame edges between each rail and the outline. The
/// app's header draws it from these too.
pub const logo_box = 20.0;
pub const stroke = 1.5;
/// The thinnest we draw a stroke, in pixels, so the lines don't vanish at small sizes.
const min_stroke_px = 1.2;
pub const outline = struct {
    pub const centre = [2]f32{ 10, 10 };
    pub const half = [2]f32{ 8, 6 };
    pub const radius = 1.5;
};
pub const segments = [_][2][2]f32{
    .{ .{ 2, 7 }, .{ 18, 7 } },
    .{ .{ 2, 13 }, .{ 18, 13 } },
    .{ .{ 5, 4 }, .{ 5, 7 } },
    .{ .{ 9, 4 }, .{ 9, 7 } },
    .{ .{ 13, 4 }, .{ 13, 7 } },
    .{ .{ 5, 13 }, .{ 5, 16 } },
    .{ .{ 9, 13 }, .{ 9, 16 } },
    .{ .{ 13, 13 }, .{ 13, 16 } },
};

/// Draws the icon into `pixels`, `side` pixels square, as RGBA rows from the top down. Everything
/// outside the tile is transparent.
pub fn render(side: usize, pixels: [][4]u8) void {
    std.debug.assert(pixels.len == side * side);
    const size: f32 = @floatFromInt(side);
    const tile = size * (1 - 2 * margin);
    const middle = size / 2;
    const unit = tile * logo_share / logo_box;
    const half_stroke = @max(stroke * unit, min_stroke_px) / 2;
    for (pixels, 0..) |*pixel, i| {
        const p = [2]f32{ @as(f32, @floatFromInt(i % side)) + 0.5, @as(f32, @floatFromInt(i / side)) + 0.5 };
        // How much of this pixel the tile covers, with its edge smoothed over one pixel.
        const to_tile = roundedBox(.{ p[0] - middle, p[1] - middle }, .{ tile / 2, tile / 2 }, tile * corner);
        const cover = std.math.clamp(0.5 - to_tile, 0, 1);
        // The pixel's position in the logo's units, with the middle of the logo's box on the
        // middle of the tile.
        const u = [2]f32{ (p[0] - middle) / unit + logo_box / 2, (p[1] - middle) / unit + logo_box / 2 };
        var nearest = @abs(roundedBox(.{ u[0] - outline.centre[0], u[1] - outline.centre[1] }, outline.half, outline.radius));
        for (segments) |s| nearest = @min(nearest, toSegment(u, s[0], s[1]));
        const ink = std.math.clamp(half_stroke + 0.5 - nearest * unit, 0, 1);
        for (pixel[0..3], ground, amber) |*out, g, a| {
            out.* = @intFromFloat(@round(@as(f32, @floatFromInt(g)) * (1 - ink) + @as(f32, @floatFromInt(a)) * ink));
        }
        pixel[3] = @intFromFloat(@round(cover * 255));
    }
}

/// Returns the distance from `p` to a box centred on 0, with half-size `half` and corners of
/// `radius`. It's negative inside the box.
fn roundedBox(p: [2]f32, half: [2]f32, radius: f32) f32 {
    const q = [2]f32{ @abs(p[0]) - half[0] + radius, @abs(p[1]) - half[1] + radius };
    const outside = std.math.hypot(@max(q[0], 0), @max(q[1], 0));
    return outside + @min(@max(q[0], q[1]), 0) - radius;
}

/// Returns the distance from `p` to the segment from `a` to `b`.
fn toSegment(p: [2]f32, a: [2]f32, b: [2]f32) f32 {
    const ab = [2]f32{ b[0] - a[0], b[1] - a[1] };
    const ap = [2]f32{ p[0] - a[0], p[1] - a[1] };
    const t = std.math.clamp((ap[0] * ab[0] + ap[1] * ab[1]) / (ab[0] * ab[0] + ab[1] * ab[1]), 0, 1);
    return std.math.hypot(ap[0] - t * ab[0], ap[1] - t * ab[1]);
}

/// The sizes we put in the Windows icon file.
pub const windows_sizes = [_]u16{ 16, 24, 32, 48, 64, 128, 256 };

/// Returns the icon as a Windows .ico file, with one image for each size in `windows_sizes`. Each
/// one is an uncompressed 32-bit bitmap, which every version of Windows can read. The caller frees
/// the result.
pub fn windowsIcon(gpa: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    const directory_bytes = 6;
    const entry_bytes = 16;
    const header_bytes = 40;
    try w.writeInt(u16, 0, .little);
    try w.writeInt(u16, 1, .little); // An icon, not a cursor.
    try w.writeInt(u16, windows_sizes.len, .little);
    var offset: u32 = directory_bytes + entry_bytes * windows_sizes.len;
    for (windows_sizes) |side| {
        const bytes = header_bytes + imageBytes(side);
        try w.writeByte(if (side == 256) 0 else @intCast(side)); // 0 stands for 256.
        try w.writeByte(if (side == 256) 0 else @intCast(side));
        try w.writeByte(0); // No palette.
        try w.writeByte(0);
        try w.writeInt(u16, 1, .little); // Planes.
        try w.writeInt(u16, 32, .little); // Bits per pixel.
        try w.writeInt(u32, bytes, .little);
        try w.writeInt(u32, offset, .little);
        offset += bytes;
    }
    for (windows_sizes) |side| {
        const pixels = try gpa.alloc([4]u8, @as(usize, side) * side);
        defer gpa.free(pixels);
        render(side, pixels);
        // The bitmap header. The height is doubled, because the colour image is followed by a
        // mask.
        try w.writeInt(u32, header_bytes, .little);
        try w.writeInt(i32, side, .little);
        try w.writeInt(i32, @as(i32, side) * 2, .little);
        try w.writeInt(u16, 1, .little);
        try w.writeInt(u16, 32, .little);
        try w.writeInt(u32, 0, .little); // Uncompressed.
        try w.writeInt(u32, imageBytes(side), .little);
        try w.splatByteAll(0, 16);
        // The colours, as BGRA, starting from the bottom row.
        var row: usize = side;
        while (row > 0) {
            row -= 1;
            for (pixels[row * side ..][0..side]) |p| try w.writeAll(&.{ p[2], p[1], p[0], p[3] });
        }
        // The mask, all zeros: the alpha channel already says what's transparent.
        try w.splatByteAll(0, maskBytes(side));
    }
    return out.toOwnedSlice();
}

fn imageBytes(side: u16) u32 {
    return @as(u32, side) * side * 4 + maskBytes(side);
}

/// Returns the size of a 1-bit mask in bytes, with each row padded to 32 bits.
fn maskBytes(side: u16) u32 {
    return (@as(u32, side) + 31) / 32 * 4 * side;
}

test "the strip is amber on the dark tile, and the corners clear" {
    const gpa = std.testing.allocator;
    const side = 64;
    const pixels = try gpa.alloc([4]u8, side * side);
    defer gpa.free(pixels);
    render(side, pixels);
    // A corner is outside the tile.
    try std.testing.expectEqual(@as(u8, 0), pixels[0][3]);
    // The middle is between the rails, so it's dark and opaque.
    const middle = pixels[side / 2 * side + side / 2];
    try std.testing.expectEqual(@as(u8, 255), middle[3]);
    try std.testing.expectEqualSlices(u8, &ground, middle[0..3]);
    // On the upper rail (y 7 in the logo's units), halfway across, it's amber.
    const unit = side * (1 - 2 * margin) * logo_share / logo_box;
    const rail_y: usize = @intFromFloat(@as(f32, side) / 2 + (7 - logo_box / 2) * unit);
    try std.testing.expectEqualSlices(u8, &amber, pixels[rail_y * side + side / 2][0..3]);
}

test "a Windows icon holds every size, where its directory says" {
    const gpa = std.testing.allocator;
    const file = try windowsIcon(gpa);
    defer gpa.free(file);
    try std.testing.expectEqual(@as(u16, windows_sizes.len), std.mem.readInt(u16, file[4..6], .little));
    var expected_offset: u32 = 6 + 16 * windows_sizes.len;
    for (windows_sizes, 0..) |side, i| {
        const entry = file[6 + 16 * i ..][0..16];
        try std.testing.expectEqual(expected_offset, std.mem.readInt(u32, entry[12..16], .little));
        try std.testing.expectEqual(@as(i32, side), std.mem.readInt(i32, file[expected_offset + 4 ..][0..4], .little));
        expected_offset += std.mem.readInt(u32, entry[8..12], .little);
    }
    try std.testing.expectEqual(@as(usize, expected_offset), file.len);
}
