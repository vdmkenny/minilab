//! Looks fitted from references. A fitted look is made from pairs of images: our raw scan of a
//! negative, and someone else's rendering of the same negative, such as a lab's Frontier or
//! Noritsu scan. None of this needs a window.
//!
//! - `model`: what a look does. `saved`: looks on disk, and applying one (`saved.Look`).
//! - `register`: lining a reference up with our scan.
//! - `fit`: fitting the curves, the matrix and the LUT, and checking the fit.
//! - `pairs`: reading a pair's images. `draft`: a look that's still being made. `work`: running
//!   all that off the page's thread.
//! - `colour`, `curve`, `cube`, `linear`: the building blocks.
//!
//! Everything except `pairs` and `work` only uses the standard library. Those two also use
//! minilab's codecs and Develop.

const std = @import("std");

pub const colour = @import("colour.zig");
pub const curve = @import("curve.zig");
pub const linear = @import("linear.zig");
pub const model = @import("model.zig");
pub const cube = @import("cube.zig");
pub const fit = @import("fit.zig");
pub const register = @import("register.zig");
pub const saved = @import("saved.zig");
pub const draft = @import("draft.zig");
pub const pairs = @import("pairs.zig");
pub const work = @import("work.zig");

/// A saved look, ready to apply to Develop's output.
pub const Look = saved.Look;

test {
    std.testing.refAllDecls(@This());
}
