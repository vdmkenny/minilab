"""Resample a curve as read onto the log H grid stored in stocks.zig.

The grid is every 0.1 log H, at multiples of 0.1, over the range the curve is drawn. Where that
would give more than 41 points (the most stocks.zig's tests allow), it is every 0.15 log H
(half a camera stop) instead. Nothing outside the drawn range is produced.

Vector readings are exact, so they are interpolated linearly. Raster readings carry pixel
noise, so each grid value is a least-squares line through the samples within +-0.025 log H.
"""

import numpy as np

MAX_POINTS = 41


def grid_for(x0, x1):
    for step in (0.1, 0.15):
        first = np.ceil(round(x0 / step, 6)) * step
        n = int(np.floor(round((x1 - first) / step, 6))) + 1
        if n <= MAX_POINTS:
            return step, np.round(first + step * np.arange(n), 6)
    raise ValueError("curve too long for the grid")


def smooth_at(x, d, xq, half=0.025):
    x = np.asarray(x, float)
    d = np.asarray(d, float)
    out = []
    for q in np.atleast_1d(xq):
        m = np.abs(x - q) <= half
        if m.sum() >= 3 and np.ptp(x[m]) > 0:
            sl, ic = np.polyfit(x[m], d[m], 1)
            out.append(sl * q + ic)
        else:
            out.append(float(np.interp(q, x, d)))
    return np.array(out)


def resample(x, d, raster, step=None):
    x = np.asarray(x, float)
    d = np.asarray(d, float)
    if step is None:
        step, g = grid_for(x[0], x[-1])
    else:
        first = np.ceil(round(x[0] / step, 6)) * step
        n = int(np.floor(round((x[-1] - first) / step, 6))) + 1
        g = np.round(first + step * np.arange(n), 6)
    vals = smooth_at(x, d, g) if raster else np.interp(g, x, d)
    return step, g, vals


def dense(x, d, raster, step=0.01):
    """Evenly spaced version of the reading, for deriving gamma and comparing reads."""
    x = np.asarray(x, float)
    d = np.asarray(d, float)
    n = int(np.floor((x[-1] - x[0]) / step + 1e-9))
    xs = x[0] + step * np.arange(n + 1)
    if x[-1] - xs[-1] > 1e-6:
        xs = np.append(xs, x[-1])  # keep the drawn end
    return xs, (smooth_at(x, d, xs) if raster else np.interp(xs, x, d))
