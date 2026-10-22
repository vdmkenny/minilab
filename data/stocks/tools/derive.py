"""Derive base_density, gamma and density_range from sampled characteristic curves.

The rules are the ones data/stocks/README.md describes:

- base_density: the density at the least-exposed end of the curve (the low-exposure end of a
  negative, the high-exposure end of a slide), accepted only if the curve has levelled off there:
  over the last 0.3 log H at that end the mean gradient must be below 0.1 density per log H.
- gamma: resample every 0.02 log H; find the steepest local gradient (least-squares slope over
  +-0.2 log H); find the longest interval on which the curve stays within 0.05 log H of a
  least-squares line (departure measured along log H, i.e. density departure / slope), with the
  line's slope at least half the steepest local gradient. Gamma is that line's slope, positive.
- density_range: negatives, density at the most-exposed end minus base_density; slides, D-max
  minus D-min with both ends levelled off. Null when base_density is null.
"""

import numpy as np

STEP = 0.02
LOCAL_HALF_WIDTH = 0.2
DEPARTURE_LOG_H = 0.05
LEVEL_SPAN = 0.3
LEVEL_GRADIENT = 0.1


def resample(x, d, step=STEP):
    x = np.asarray(x, float)
    d = np.asarray(d, float)
    n = int(np.floor((x[-1] - x[0]) / step + 1e-9))
    xs = x[0] + step * np.arange(n + 1)
    return xs, np.interp(xs, x, d)


def _slope(x, d):
    xm = x.mean()
    return float(((x - xm) * (d - d.mean())).sum() / ((x - xm) ** 2).sum())


def end_gradient(x, d, at_start):
    """Mean gradient over the last LEVEL_SPAN log H at one end (absolute value)."""
    x = np.asarray(x, float)
    d = np.asarray(d, float)
    if at_start:
        x1 = x[0] + LEVEL_SPAN
        return abs(float(np.interp(x1, x, d)) - d[0]) / LEVEL_SPAN
    x0 = x[-1] - LEVEL_SPAN
    return abs(d[-1] - float(np.interp(x0, x, d))) / LEVEL_SPAN


def gamma(x, d):
    """Straight-line slope (positive) and the interval it was fitted on."""
    xs, ds = resample(x, d)
    sign = 1.0 if ds[-1] > ds[0] else -1.0
    ds = sign * ds
    half = int(round(LOCAL_HALF_WIDTH / STEP))
    local = [_slope(xs[i - half : i + half + 1], ds[i - half : i + half + 1]) for i in range(half, len(xs) - half)]
    steepest = max(local)
    best = None
    n = len(xs)
    for i in range(n):
        for j in range(n - 1, i + 1, -1):
            length = xs[j] - xs[i]
            if best is not None and length < best[0] - 1e-9:
                break
            xx, dd = xs[i : j + 1], ds[i : j + 1]
            s = _slope(xx, dd)
            if s < 0.5 * steepest:
                continue
            c = dd.mean() - s * xx.mean()
            dep = float(np.abs(dd - (s * xx + c)).max() / s)
            if dep > DEPARTURE_LOG_H:
                continue
            cand = (length, -dep, s, xs[i], xs[j])
            if best is None or cand[:2] > best[:2]:
                best = cand
            break
    length, negdep, s, a, b = best
    return s, (a, b), -negdep, steepest


def derive(x, d, kind):
    """kind: 'negative' or 'positive' (slide). Returns base, gamma, range and diagnostics."""
    x = np.asarray(x, float)
    d = np.asarray(d, float)
    g, interval, dep, steepest = gamma(x, d)
    if kind == "negative":
        least_grad = end_gradient(x, d, at_start=True)
        base = float(d[0]) if least_grad < LEVEL_GRADIENT else None
        rng = float(d[-1]) - base if base is not None else None
        most_grad = end_gradient(x, d, at_start=False)
    else:
        least_grad = end_gradient(x, d, at_start=False)
        most_grad = end_gradient(x, d, at_start=True)
        dmin_ok = least_grad < LEVEL_GRADIENT
        dmax_ok = most_grad < LEVEL_GRADIENT
        base = float(d[-1]) if dmin_ok else None
        rng = float(d[0]) - base if (base is not None and dmax_ok) else None
    return {
        "base": base,
        "gamma": g,
        "range": rng,
        "interval": interval,
        "departure": dep,
        "steepest": steepest,
        "least_exposed_gradient": least_grad,
        "most_exposed_gradient": most_grad,
    }
