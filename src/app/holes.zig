//! The film's holes, drawn the same way on the Rolls cards and on Scan's preview.

const c = @import("c");
const minilab = @import("minilab");
const gui = @import("../ui/gui.zig");
const theme = @import("../ui/theme.zig");

const formats = minilab.formats;

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
