//! Fitting a look to pairs of images. From every pair we take samples of our density and the
//! reference's colour at the same places.
//!
//! The steps, in order:
//!
//! 1. Channel curves. With the matrix at the identity and no balance, each channel's curve is a
//!    least-squares fit from density to the reference's encoded value, made monotone.
//! 2. The density matrix and the per-frame balance. With the curves fixed, we take Gauss-Newton
//!    steps on each channel's row of the matrix (its two crosstalk terms; the row adds up to 1)
//!    and on that channel's offset for every frame. Crosstalk has a small cost of its own, so
//!    where the pairs can hardly tell one matrix from another, the matrix stays near the
//!    identity. The offsets stand for whatever the reference's software did to each frame on its
//!    own, and aren't part of the look. Their mean is held at 0, so the curves keep the look's own
//!    balance.
//!
//!    Steps 1 and 2 take turns for a few rounds, and the curves are fitted once more at the end.
//! 3. The LUT, only when it's asked for and only when the leftover error shows some structure.
//!    The errors the matrix and curves leave are averaged into a 33³ grid, smoothed, and tried out
//!    of fold: fitted on half the fitted pairs and checked on the other half. We keep the LUT if
//!    it removes at least a tenth of the error there. Noise doesn't.
//!
//! Held-out pairs take no part in the fit. Each one gets its own balance offsets, fitted with the
//! look fixed, since the balance isn't part of the look. Then the ΔE2000 between the look and the
//! reference over its samples tells us how good the fit is.

const std = @import("std");
const curve = @import("curve.zig");
const model_ = @import("model.zig");
const colour = @import("colour.zig");
const linear = @import("linear.zig");

const Model = model_.Model;
const Lut = model_.Lut;

/// One sample: a single place in one pair.
pub const Sample = struct {
    /// Our density there, 0..1 per channel, as Develop's Log tone gives it.
    density: [3]f32,
    /// The reference's colour there, sRGB-encoded 0..1.
    target: [3]f32,
    weight: f32 = 1,
    /// The pair it comes from.
    pair: u16,
};

/// What the fit is allowed to change: the choices in the page's Model section.
pub const Options = struct {
    balance: bool = true,
    curves: bool = true,
    matrix: bool = true,
    lut: bool = false,
};

/// What happened to the LUT.
pub const LutVerdict = enum {
    not_asked,
    kept,
    /// The leftover error is just noise: a LUT didn't help out of fold.
    no_structure,
    /// Trying a LUT out of fold needs at least two fitted pairs.
    too_few_pairs,
};

pub const Report = struct {
    /// The median and 95th percentile of ΔE2000 over the held-out pairs' samples, or null when no
    /// pair is held out.
    median: ?f32 = null,
    p95: ?f32 = null,
    /// The median ΔE2000 over the fitted pairs, for comparison.
    fitted_median: f32 = 0,
    /// The root weighted mean squared error over the fitted pairs, in encoded values. This is what
    /// the fit minimises.
    fitted_rms: f32 = 0,
    fitted_pairs: usize = 0,
    held_out_pairs: usize = 0,
    lut: LutVerdict = .not_asked,
    /// The share of the error the LUT removed out of fold, when it was tried.
    lut_gain: f32 = 0,
};

pub const Result = struct {
    model: Model,
    /// The model's LUT. The result owns it.
    lut: ?*Lut,
    /// Each pair's balance offsets in density.
    balance: [][3]f32,
    report: Report,

    pub fn deinit(result: *Result, gpa: std.mem.Allocator) void {
        if (result.lut) |l| gpa.destroy(l);
        gpa.free(result.balance);
        result.* = undefined;
    }
};

const rounds = 8;
const steps_per_round = 2;
/// How much the curves resist bending, relative to the samples.
const smoothness = 2e-5;
/// The cost of a crosstalk term, squared, compared with the mean squared error per sample. A term
/// of 0.1 costs as much as an error of 0.0014 on every sample.
const crosstalk_cost = 2e-4;
/// We keep the LUT when it removes at least this share of the error out of fold.
const lut_threshold = 0.1;

/// Fits a look to `samples`. `held_out` has one entry per pair, true for the pairs left out of the
/// fit so we can check it.
pub fn fit(gpa: std.mem.Allocator, samples: []const Sample, held_out: []const bool, options: Options) !Result {
    const balance = try gpa.alloc([3]f32, held_out.len);
    @memset(balance, @splat(0));
    var result: Result = .{ .model = .{}, .lut = null, .balance = balance, .report = .{} };
    // If anything below fails, this frees the balance, and the LUT once there is one.
    errdefer result.deinit(gpa);

    const counts = try gpa.alloc(usize, held_out.len);
    defer gpa.free(counts);
    @memset(counts, 0);
    for (samples) |s| counts[s.pair] += 1;
    for (counts, held_out) |n, out| {
        if (n == 0) continue;
        if (out) result.report.held_out_pairs += 1 else result.report.fitted_pairs += 1;
    }
    if (result.report.fitted_pairs == 0) return error.NothingToFit;

    for (0..rounds) |_| {
        if (options.curves) fitCurves(&result.model, samples, balance, held_out);
        if (options.matrix or options.balance) {
            for (0..steps_per_round) |_| {
                for (0..3) |channel| try stepRow(gpa, &result.model, samples, balance, held_out, counts, options, channel);
            }
        }
    }
    if (options.curves) fitCurves(&result.model, samples, balance, held_out);
    if (options.balance) balanceHeldOut(&result.model, samples, balance, held_out);

    if (options.lut) {
        result.report.lut = .too_few_pairs;
        if (result.report.fitted_pairs >= 2) {
            const gain = try crossValidateLut(gpa, &result.model, samples, balance, held_out, counts);
            result.report.lut_gain = gain;
            result.report.lut = .no_structure;
            if (gain >= lut_threshold) {
                const lut = try gpa.create(Lut);
                result.lut = lut;
                try fitLut(gpa, &result.model, samples, balance, held_out, null, lut);
                result.model.lut = lut;
                result.report.lut = .kept;
            }
        }
    }

    try report(gpa, &result, samples, held_out);
    return result;
}

fn fitCurves(model: *Model, samples: []const Sample, balance: []const [3]f32, held_out: []const bool) void {
    var fitters: [3]curve.Fitter = .{ .{}, .{}, .{} };
    for (samples) |s| {
        if (held_out[s.pair]) continue;
        const m = model.mixed(s.density, balance[s.pair]);
        for (&fitters, m, s.target) |*f, x, y| f.add(x, y, s.weight);
    }
    for (&model.curves, &fitters) |*c, *f| c.* = f.solve(smoothness);
}

/// Returns one channel's weighted squared error over the fitted pairs, plus a penalty that holds
/// the balance's mean at 0, plus the crosstalk's cost.
fn channelLoss(model: *const Model, samples: []const Sample, balance: []const [3]f32, held_out: []const bool, channel: usize, gauge: f64) f64 {
    var loss: f64 = 0;
    var total: f64 = 0;
    for (samples) |s| {
        if (held_out[s.pair]) continue;
        total += s.weight;
        const m = model.mixed(s.density, balance[s.pair])[channel];
        const r = curve.eval(&model.curves[channel], m) - s.target[channel];
        loss += s.weight * r * r;
    }
    var mean: f64 = 0;
    for (balance, held_out) |b, out| {
        if (!out) mean += b[channel];
    }
    var crosstalk: f64 = 0;
    for (model.matrix[channel], 0..) |v, j| {
        if (j != channel) crosstalk += v * v;
    }
    return loss + gauge * mean * mean + crosstalk_cost * total * crosstalk;
}

/// Takes one damped Gauss-Newton step on one channel's matrix row and balance offsets.
fn stepRow(gpa: std.mem.Allocator, model: *Model, samples: []const Sample, balance: [][3]f32, held_out: []const bool, counts: []const usize, options: Options, channel: usize) !void {
    // The unknowns: the row's two crosstalk terms, then one offset per fitted pair with samples.
    const others = [3][2]usize{ .{ 1, 2 }, .{ 0, 2 }, .{ 0, 1 } };
    const crosstalk: usize = if (options.matrix) 2 else 0;
    const slot = try gpa.alloc(?usize, held_out.len);
    defer gpa.free(slot);
    var n = crosstalk;
    for (slot, held_out, counts) |*s, out, count| {
        s.* = null;
        if (!options.balance or out or count == 0) continue;
        s.* = n;
        n += 1;
    }
    if (n == 0) return;
    const a = try gpa.alloc(f64, n * n);
    defer gpa.free(a);
    const g = try gpa.alloc(f64, n);
    defer gpa.free(g);
    @memset(a, 0);
    @memset(g, 0);

    var total: f64 = 0;
    const c = &model.curves[channel];
    for (samples) |s| {
        if (held_out[s.pair]) continue;
        const m = model.mixed(s.density, balance[s.pair])[channel];
        const r: f64 = curve.eval(c, m) - s.target[channel];
        const d: f64 = curve.slope(c, m);
        const w: f64 = s.weight;
        total += w;
        var jacobian: [3]f64 = undefined;
        var index: [3]usize = undefined;
        var k: usize = 0;
        if (options.matrix) {
            for (others[channel]) |j| {
                jacobian[k] = d * (s.density[j] - s.density[channel]);
                index[k] = k;
                k += 1;
            }
        }
        if (slot[s.pair]) |at| {
            jacobian[k] = d;
            index[k] = at;
            k += 1;
        }
        for (jacobian[0..k], index[0..k]) |ja, ia| {
            g[ia] -= w * ja * r;
            for (jacobian[0..k], index[0..k]) |jb, ib| a[ia * n + ib] += w * ja * jb;
        }
    }
    if (total == 0) return;

    // Hold the balance's mean at 0, and keep the crosstalk from wandering where the samples
    // don't pin it down.
    const gauge = total;
    var mean: f64 = 0;
    for (balance, held_out) |b, out| {
        if (!out) mean += b[channel];
    }
    for (slot) |sa| {
        const ia = sa orelse continue;
        g[ia] -= gauge * mean;
        for (slot) |sb| {
            const ib = sb orelse continue;
            a[ia * n + ib] += gauge;
        }
    }
    var trace: f64 = 0;
    for (0..n) |i| trace += a[i * n + i];
    const damping = 1e-3 * trace / @as(f64, @floatFromInt(n)) + 1e-9 * total;
    for (0..n) |i| a[i * n + i] += damping;
    for (0..crosstalk) |i| {
        a[i * n + i] += crosstalk_cost * total;
        g[i] -= crosstalk_cost * total * model.matrix[channel][others[channel][i]];
    }
    linear.solve(n, a, g) catch return;

    // Take the step, or part of it, if that lowers the error.
    const before = channelLoss(model, samples, balance, held_out, channel, gauge);
    const row = model.matrix[channel];
    const saved = try gpa.dupe([3]f32, balance);
    defer gpa.free(saved);
    var share: f64 = 1;
    for (0..6) |_| {
        if (options.matrix) {
            var next = row;
            for (others[channel], 0..) |j, i| next[j] = row[j] + @as(f32, @floatCast(share * g[i]));
            next[channel] = 1 - next[others[channel][0]] - next[others[channel][1]];
            model.matrix[channel] = next;
        }
        for (balance, saved, slot) |*b, old, s| {
            if (s) |at| b[channel] = old[channel] + @as(f32, @floatCast(share * g[at]));
        }
        if (channelLoss(model, samples, balance, held_out, channel, gauge) < before) return;
        share /= 2;
    }
    model.matrix[channel] = row;
    @memcpy(balance, saved);
}

/// Fits each held-out pair's balance offsets with the look fixed, using a few Newton steps per
/// channel.
fn balanceHeldOut(model: *const Model, samples: []const Sample, balance: [][3]f32, held_out: []const bool) void {
    for (held_out, 0..) |out, pair| {
        if (!out) continue;
        for (0..3) |channel| {
            for (0..8) |_| {
                var gradient: f64 = 0;
                var hessian: f64 = 0;
                for (samples) |s| {
                    if (s.pair != pair) continue;
                    const m = model.mixed(s.density, balance[pair])[channel];
                    const r: f64 = curve.eval(&model.curves[channel], m) - s.target[channel];
                    const d: f64 = curve.slope(&model.curves[channel], m);
                    gradient += s.weight * d * r;
                    hessian += s.weight * d * d;
                }
                if (hessian <= 0) break;
                const step = -gradient / (hessian * 1.001);
                balance[pair][channel] += @floatCast(std.math.clamp(step, -0.1, 0.1));
                if (@abs(step) < 1e-6) break;
            }
        }
    }
}

/// One fold of the fitted pairs, for fitting a LUT to. Where a `?Fold` is null, the LUT is fitted
/// to all of them.
const Fold = struct { which: u1, of: []const ?u1 };

/// Fits the LUT to the error the matrix and curves leave over the fitted pairs, or over one fold
/// of them. Each sample's error is shared out over the grid points around it. Then the grid is
/// smoothed, so points with few samples follow their neighbours and empty ones fade back to no
/// change.
fn fitLut(gpa: std.mem.Allocator, model: *const Model, samples: []const Sample, balance: []const [3]f32, held_out: []const bool, fold: ?Fold, lut: *Lut) !void {
    const size = model_.lut_size;
    const sum = try gpa.alloc([3]f64, model_.lut_entries);
    defer gpa.free(sum);
    const weight = try gpa.alloc(f64, model_.lut_entries);
    defer gpa.free(weight);
    const offset = try gpa.alloc([3]f64, model_.lut_entries);
    defer gpa.free(offset);
    @memset(sum, @splat(0));
    @memset(weight, 0);
    @memset(offset, @splat(0));

    var total: f64 = 0;
    var used: usize = 0;
    for (samples) |s| {
        if (held_out[s.pair]) continue;
        if (fold) |f| {
            const side = f.of[s.pair] orelse continue;
            if (side != f.which) continue;
        }
        const o = model.curved(s.density, balance[s.pair]);
        var base: [3]usize = undefined;
        var frac: [3]f32 = undefined;
        for (&base, &frac, o) |*b, *fr, v| {
            const t = std.math.clamp(v, 0, 1) * (size - 1);
            b.* = @min(@as(usize, @intFromFloat(t)), size - 2);
            fr.* = t - @as(f32, @floatFromInt(b.*));
        }
        for (0..8) |corner| {
            const dr = corner & 1;
            const dg = corner >> 1 & 1;
            const db = corner >> 2 & 1;
            const w: f64 = s.weight * (if (dr == 1) frac[0] else 1 - frac[0]) *
                (if (dg == 1) frac[1] else 1 - frac[1]) *
                (if (db == 1) frac[2] else 1 - frac[2]);
            if (w == 0) continue;
            const i = Lut.index(base[0] + dr, base[1] + dg, base[2] + db);
            for (&sum[i], s.target, o) |*acc, t, v| acc.* += w * (t - v);
            weight[i] += w;
        }
        total += s.weight;
        used += 1;
    }
    // Shrinking and smoothing are measured in units of an average sample.
    const unit = if (used > 0) total / @as(f64, @floatFromInt(used)) else 1;
    const shrink = 2 * unit;
    const smooth = 1 * unit;
    for (0..60) |_| {
        for (0..model_.lut_entries) |i| {
            const at = [3]usize{ i % size, i / size % size, i / (size * size) };
            var neighbours: [3]f64 = @splat(0);
            var count: f64 = 0;
            for (0..3) |axis| {
                for ([_]i2{ -1, 1 }) |dir| {
                    if (dir < 0 and at[axis] == 0) continue;
                    if (dir > 0 and at[axis] == size - 1) continue;
                    var next = at;
                    next[axis] = if (dir < 0) at[axis] - 1 else at[axis] + 1;
                    const v = offset[Lut.index(next[0], next[1], next[2])];
                    for (&neighbours, v) |*nb, x| nb.* += x;
                    count += 1;
                }
            }
            const denominator = weight[i] + shrink + smooth * count;
            for (&offset[i], sum[i], neighbours) |*o, total_offset, nb| o.* = (total_offset + smooth * nb) / denominator;
        }
    }
    for (&lut.values, offset, 0..) |*v, o, i| {
        const in = Lut.input(i);
        for (v, in, o) |*out, x, d| out.* = std.math.clamp(x + @as(f32, @floatCast(d)), 0, 1);
    }
}

/// Returns the share of the error a LUT removes out of fold. The LUT is fitted on half the fitted
/// pairs and tried on the other half, both ways round.
fn crossValidateLut(gpa: std.mem.Allocator, model: *const Model, samples: []const Sample, balance: []const [3]f32, held_out: []const bool, counts: []const usize) !f32 {
    const folds = try gpa.alloc(?u1, held_out.len);
    defer gpa.free(folds);
    var next: u1 = 0;
    for (folds, held_out, counts) |*f, out, n| {
        f.* = null;
        if (out or n == 0) continue;
        f.* = next;
        next +%= 1;
    }
    const lut = try gpa.create(Lut);
    defer gpa.destroy(lut);
    var trial = model.*;
    trial.lut = lut;
    var before: f64 = 0;
    var after: f64 = 0;
    for ([_]u1{ 0, 1 }) |which| {
        try fitLut(gpa, model, samples, balance, held_out, .{ .which = which, .of = folds }, lut);
        for (samples) |s| {
            const f = folds[s.pair] orelse continue;
            if (f == which) continue;
            const plain = model.encoded(s.density, balance[s.pair]);
            const looked = trial.encoded(s.density, balance[s.pair]);
            for (plain, looked, s.target) |p, l, t| {
                before += s.weight * (p - t) * (p - t);
                after += s.weight * (l - t) * (l - t);
            }
        }
    }
    if (before <= 0) return 0;
    return @floatCast(1 - after / before);
}

fn report(gpa: std.mem.Allocator, result: *Result, samples: []const Sample, held_out: []const bool) !void {
    var fitted: std.ArrayList(f32) = .empty;
    defer fitted.deinit(gpa);
    var checked: std.ArrayList(f32) = .empty;
    defer checked.deinit(gpa);
    var squares: f64 = 0;
    var weights: f64 = 0;
    for (samples) |s| {
        if (s.weight <= 0) continue;
        const out = result.model.encoded(s.density, result.balance[s.pair]);
        if (!held_out[s.pair]) {
            for (out, s.target) |o, t| squares += s.weight * (o - t) * (o - t);
            weights += 3 * s.weight;
        }
        const e = colour.deltaE2000(colour.lab(out), colour.lab(s.target));
        try (if (held_out[s.pair]) &checked else &fitted).append(gpa, e);
    }
    result.report.fitted_median = colour.percentile(fitted.items, 0.5);
    if (weights > 0) result.report.fitted_rms = @floatCast(@sqrt(squares / weights));
    if (checked.items.len > 0) {
        result.report.median = colour.percentile(checked.items, 0.5);
        result.report.p95 = colour.percentile(checked.items, 0.95);
    }
}

/// A test look: a matrix whose rows add up to 1, and three different monotone curves.
const Synthetic = struct {
    const matrix: model_.Matrix = .{ .{ 0.86, 0.10, 0.04 }, .{ 0.06, 0.90, 0.04 }, .{ 0.03, 0.12, 0.85 } };
    const strength = [3]f32{ 2.5, 1.8, 1.2 };

    fn curveAt(channel: usize, x: f32) f32 {
        const k = strength[channel];
        const v = std.math.clamp(x, 0, 1);
        return 0.03 + 0.94 * (1 - @exp(-k * v)) / (1 - @exp(-k));
    }

    fn render(density: [3]f32, balance: [3]f32) [3]f32 {
        var out: [3]f32 = undefined;
        for (&out, matrix, balance, 0..) |*o, row, b, i| {
            o.* = curveAt(i, row[0] * density[0] + row[1] * density[1] + row[2] * density[2] + b);
        }
        return out;
    }

    /// Makes samples for `pairs` pairs. The densities are spread like a photograph's (a level
    /// with some colour around it), and each pair has its own balance, which adds up to 0 over
    /// the fitted pairs.
    fn samples(gpa: std.mem.Allocator, pairs: usize, per_pair: usize, balances: []const [3]f32, twist: bool) ![]Sample {
        var prng = std.Random.DefaultPrng.init(7);
        const random = prng.random();
        const out = try gpa.alloc(Sample, pairs * per_pair);
        for (out, 0..) |*s, i| {
            const pair = i / per_pair;
            const level = 0.1 + 0.8 * random.float(f32);
            var d: [3]f32 = undefined;
            for (&d) |*v| v.* = std.math.clamp(level + (random.float(f32) - 0.5) * 0.4, 0.02, 0.98);
            var target = render(d, balances[pair]);
            if (twist) {
                // Something the matrix and curves can't do: greens get bluer, but only where
                // green is the strongest channel.
                const lead = @max(0, target[1] - @max(target[0], target[2]));
                target[2] = @min(1, target[2] + 1.5 * lead);
            }
            s.* = .{ .density = d, .target = target, .pair = @intCast(pair) };
        }
        return out;
    }
};

const test_balances = [_][3]f32{
    .{ 0.03, -0.02, 0.01 },
    .{ -0.01, 0.02, -0.03 },
    .{ -0.02, 0.01, 0.02 },
    .{ 0.01, -0.03, 0.01 },
    .{ -0.01, 0.02, -0.01 },
    // Held out.
    .{ 0.02, 0.01, -0.02 },
};

test "a known curve and matrix come back from synthetic pairs" {
    const gpa = std.testing.allocator;
    const samples = try Synthetic.samples(gpa, test_balances.len, 3000, &test_balances, false);
    defer gpa.free(samples);
    const held_out = [_]bool{ false, false, false, false, false, true };
    var result = try fit(gpa, samples, &held_out, .{});
    defer result.deinit(gpa);

    for (result.model.matrix, Synthetic.matrix) |row, expected| {
        for (row, expected) |v, e| try std.testing.expectApproxEqAbs(e, v, 0.005);
    }
    for (0..3) |channel| {
        for (2..9) |i| {
            const x = @as(f32, @floatFromInt(i)) / 10;
            try std.testing.expectApproxEqAbs(Synthetic.curveAt(channel, x), curve.eval(&result.model.curves[channel], x), 0.005);
        }
    }
    for (result.balance[0..5], test_balances[0..5]) |b, expected| {
        for (b, expected) |v, e| try std.testing.expectApproxEqAbs(e, v, 0.002);
    }
    try std.testing.expect(result.report.median.? < 0.1);
    try std.testing.expect(result.report.p95.? < 0.3);
    try std.testing.expectEqual(@as(usize, 5), result.report.fitted_pairs);
    try std.testing.expectEqual(@as(usize, 1), result.report.held_out_pairs);
}

test "the LUT is kept only when the residual has structure" {
    const gpa = std.testing.allocator;
    const held_out = [_]bool{ false, false, false, false, false, true };

    const plain = try Synthetic.samples(gpa, test_balances.len, 2000, &test_balances, false);
    defer gpa.free(plain);
    var prng = std.Random.DefaultPrng.init(3);
    for (plain) |*s| {
        for (&s.target) |*t| t.* = std.math.clamp(t.* + (prng.random().float(f32) - 0.5) * 0.02, 0, 1);
    }
    var noisy = try fit(gpa, plain, &held_out, .{ .lut = true });
    defer noisy.deinit(gpa);
    try std.testing.expectEqual(LutVerdict.no_structure, noisy.report.lut);
    try std.testing.expect(noisy.model.lut == null);

    const twisted = try Synthetic.samples(gpa, test_balances.len, 2000, &test_balances, true);
    defer gpa.free(twisted);
    var without = try fit(gpa, twisted, &held_out, .{});
    defer without.deinit(gpa);
    var with = try fit(gpa, twisted, &held_out, .{ .lut = true });
    defer with.deinit(gpa);
    try std.testing.expectEqual(LutVerdict.kept, with.report.lut);
    try std.testing.expect(with.report.median.? < 0.75 * without.report.median.?);
}
