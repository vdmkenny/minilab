//! Frames: film formats and finding the frames on a strip preview (design section 6).

const std = @import("std");

pub const formats = @import("formats.zig");
pub const detect = @import("detect.zig");

pub const FilmSize = formats.FilmSize;
pub const Format = formats.Format;
pub const Standard = formats.Standard;
pub const Kind = detect.Kind;
pub const Holder = detect.Holder;
pub const Axis = detect.Axis;
pub const Confidence = detect.Confidence;
pub const Frame = detect.Frame;
pub const Options = detect.Options;
pub const Detection = detect.Detection;

test {
    std.testing.refAllDecls(@This());
}
