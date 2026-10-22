//! Small dense linear systems, for the least-squares steps of a fit.

const std = @import("std");

/// Solves `a` · x = `b` for x, in place: `a` is n × n row by row and is destroyed, and `b` becomes
/// x. Gaussian elimination with partial pivoting, in f64. Fails on a singular system.
pub fn solve(n: usize, a: []f64, b: []f64) error{Singular}!void {
    std.debug.assert(a.len == n * n and b.len == n);
    for (0..n) |column| {
        var pivot = column;
        for (column + 1..n) |row| {
            if (@abs(a[row * n + column]) > @abs(a[pivot * n + column])) pivot = row;
        }
        if (@abs(a[pivot * n + column]) < 1e-300) return error.Singular;
        if (pivot != column) {
            for (0..n) |k| std.mem.swap(f64, &a[pivot * n + k], &a[column * n + k]);
            std.mem.swap(f64, &b[pivot], &b[column]);
        }
        const p = a[column * n + column];
        for (column + 1..n) |row| {
            const factor = a[row * n + column] / p;
            if (factor == 0) continue;
            for (column..n) |k| a[row * n + k] -= factor * a[column * n + k];
            b[row] -= factor * b[column];
        }
    }
    var row = n;
    while (row > 0) {
        row -= 1;
        var sum = b[row];
        for (row + 1..n) |k| sum -= a[row * n + k] * b[k];
        b[row] = sum / a[row * n + row];
    }
}

test "a 3 × 3 system" {
    var a = [_]f64{ 2, 1, -1, -3, -1, 2, -2, 1, 2 };
    var b = [_]f64{ 8, -11, -3 };
    try solve(3, &a, &b);
    try std.testing.expectApproxEqAbs(@as(f64, 2), b[0], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 3), b[1], 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -1), b[2], 1e-12);
}
