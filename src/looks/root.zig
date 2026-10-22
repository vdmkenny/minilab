//! Looks fitted from references: a look made from pairs of images, our raw scan of a negative
//! and someone else's rendering of the same negative, such as a lab's Frontier or Noritsu scan.
//! None of it needs a window.
//!
//! - `model`: what a look does; `saved`: looks on disk, and applying one (`saved.Look`).
//! - `register`: lining a reference up with our scan.
//! - `fit`: fitting the curves, the matrix and the LUT, and checking the fit.
//! - `pairs`: reading a pair's images; `draft`: a look being made; `work`: doing it off the page.
//! - `colour`, `curve`, `cube`, `linear`: the parts.
//!
//! Everything but `pairs` and `work` uses the standard library alone; those two use minilab's
//! codecs and Develop.

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

/// A saved look, to apply to Develop's output.
pub const Look = saved.Look;

test {
    std.testing.refAllDecls(@This());
}
