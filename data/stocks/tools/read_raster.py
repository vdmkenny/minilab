"""Read characteristic curves from a chart that is a raster image in the PDF.

For one chart (see charts.py), at a given resolution:

1. Render the page with pdftoppm at `dpi`. All positions in the chart's config are in PDF points
   (top-left origin), so the same config reads the page at any resolution.
2. Calibrate each axis. For every tick named in the config, the darkness profile across the
   tick (a gridline, a tick mark or the frame edge) is measured in a band given by the config,
   the peak nearest the expected position is found, and its sub-pixel centre is the darkness-
   weighted centroid over the line's width. A straight line value = a + b * position is fitted
   through the ticks by least squares, and every tick's residual is reported.
3. Build an "ink" image of the plot area:
   - black curves: darkness (1 - luminance);
   - coloured curves: one image per colour, how close each pixel is to the curve's colour.
   Gridlines are removed in one of three ways, chosen per chart: a binary opening that keeps
   only ink thicker than `open_pt` (gridlines and hairline text are thinner than the curves);
   painting out the gridlines found in step 2 by interpolating across them; or blanking given
   lines. Rectangles listed in `exclude` (text boxes, legends) are blanked.
4. Trace each curve column by column. Near `seed_x` a column must hold one run of ink per
   curve; they are assigned top to bottom in `order`. Each curve is then followed outward: in
   the next column, the run nearest the position extrapolated from the last few samples is
   taken, and its ink-weighted centroid is the sample. Runs thicker than `max_thickness_pt`
   (a label touching the curve, or two curves merging) are skipped unless the chart allows
   merged runs. The trace ends where no ink is found for `max_gap_pt`.
5. Where a chart draws curves over each other, the config says how they share a reading:
   `hidden_under` (a curve hidden under another takes that one's samples where it is lost),
   or `union_from_x` (from there on, all channels take the centre of the band the lines form).
6. Remove outliers (samples far from a running median of their neighbours) and map pixel
   centres to (log H, density).
"""

import subprocess
import tempfile

import numpy as np
from PIL import Image


def render(pdf_path, page, dpi):
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(
            ["pdftoppm", "-r", str(dpi), "-f", str(page), "-l", str(page), "-png", "-singlefile", pdf_path, f"{tmp}/p"],
            check=True,
        )
        img = Image.open(f"{tmp}/p.png").convert("RGB")
        return np.asarray(img, dtype=np.float64) / 255.0


def _darkness(rgb):
    lum = 0.299 * rgb[..., 0] + 0.587 * rgb[..., 1] + 0.114 * rgb[..., 2]
    return 1.0 - lum


def _colour_ink(rgb, colour, tol):
    """1 at the target colour, falling to 0 at distance `tol` (RGB, 0..1)."""
    d = np.sqrt(((rgb - np.asarray(colour)) ** 2).sum(axis=2))
    return np.clip(1.0 - d / tol, 0.0, 1.0)


def _line_centre(profile, guess, search, halfwidth):
    """Sub-pixel centre of the line in a 1-D darkness profile nearest to `guess`."""
    lo = max(0, int(guess - search))
    hi = min(len(profile), int(guess + search) + 1)
    seg = profile[lo:hi]
    if seg.size == 0 or seg.max() <= 0:
        raise ValueError("no line found")
    peak = lo + int(np.argmax(seg))
    a = max(0, peak - halfwidth)
    b = min(len(profile), peak + halfwidth + 1)
    w = profile[a:b] - np.median(profile[lo:hi])
    w = np.clip(w, 0, None)
    idx = np.arange(a, b)
    return float((w * idx).sum() / w.sum()), peak


def _calibrate(dark, ticks, axis, band, s, use=None, search_pt=2.0, halfwidth=3):
    """axis 'x': vertical lines, profile over columns using rows in band (pt); 'y': horizontal."""
    b0, b1 = int(band[0] * s), int(band[1] * s)
    if axis == "x":
        profile = dark[b0:b1, :].mean(axis=0)
    else:
        profile = dark[:, b0:b1].mean(axis=1)
    rows = []
    for value, approx in ticks:
        c, peak = _line_centre(profile, (approx * s) - 0.5, search_pt * s, halfwidth)
        rows.append((value, (c + 0.5) / s, peak))
    fit = rows if use is None else [r for r in rows if r[0] in use]
    v = np.array([r[0] for r in fit])
    p = np.array([r[1] for r in fit])
    slope, icpt = np.polyfit(p, v, 1)
    return float(icpt), float(slope), [(value, pos, value - (icpt + slope * pos)) for value, pos, _ in rows], [r[2] for r in rows]


def _paint_out(ink, positions, axis, width):
    """Interpolate across gridlines at pixel `positions` (vertical lines if axis == 'x')."""
    out = ink.copy()
    for p in positions:
        a, b = p - width, p + width
        if axis == "x":
            if a < 1 or b >= out.shape[1] - 1:
                continue
            left, right = out[:, a - 1], out[:, b + 1]
            for k, col in enumerate(range(a, b + 1)):
                t = (k + 1) / (b - a + 2)
                out[:, col] = (1 - t) * left + t * right
        else:
            if a < 1 or b >= out.shape[0] - 1:
                continue
            top, bottom = out[a - 1, :], out[b + 1, :]
            for k, row in enumerate(range(a, b + 1)):
                t = (k + 1) / (b - a + 2)
                out[row, :] = (1 - t) * top + t * bottom
    return out


def _open_thin(ink, threshold, length, axis):
    """Remove ink thinner than `length` pixels across `axis` (0: vertical extent, 1: horizontal).

    A pixel survives if it lies in some window of `length` consecutive pixels along that axis that
    are all ink (a binary opening with a line). Thin gridlines and hairline text go; curves drawn
    thicker than `length` stay, with their original darkness.
    """
    on = ink > threshold
    n = on.shape[axis]
    er = np.ones_like(on)
    for k in range(length):
        sl = [slice(None), slice(None)]
        sl[axis] = slice(k, n - length + 1 + k)
        er[tuple([slice(0, n - length + 1) if a == axis else slice(None) for a in range(2)])] &= on[tuple(sl)]
    er[tuple([slice(n - length + 1, None) if a == axis else slice(None) for a in range(2)])] = False
    keep = np.zeros_like(on)
    for k in range(length):
        sl = [slice(None), slice(None)]
        sl[axis] = slice(k, n - length + 1 + k)
        keep[tuple(sl)] |= er[tuple([slice(0, n - length + 1) if a == axis else slice(None) for a in range(2)])]
    return np.where(keep, ink, 0.0)


def _runs(col, threshold):
    on = col > threshold
    out = []
    i = 0
    n = len(col)
    while i < n:
        if on[i]:
            j = i
            while j < n and on[j]:
                j += 1
            w = col[i:j]
            out.append((i, j, float((w * np.arange(i, j)).sum() / w.sum())))
            i = j
        else:
            i += 1
    return out


def _despike(xs, ys, window=7, limit=1.5):
    xs = np.asarray(xs)
    ys = np.asarray(ys)
    keep = np.ones(len(ys), bool)
    for i in range(len(ys)):
        a, b = max(0, i - window), min(len(ys), i + window + 1)
        if abs(ys[i] - np.median(ys[a:b])) > limit:
            keep[i] = False
    return xs[keep], ys[keep]


def _track(inks, order, seed0, p, name):
    """Follow each curve across the columns of its ink image, starting at column seed0.

    Where all channels share one ink image, a column near the seed must have exactly one run per
    channel; they are assigned in `order` (top to bottom). Each curve is then followed outward:
    the next sample is the run nearest the position extrapolated from the last samples.
    """
    offsets = sorted(range(-p["search"], p["search"] + 1), key=abs)
    seeds, start = {}, {}
    if len({id(v) for v in inks.values()}) == 1:
        img = inks[order[0]]
        for off in offsets:
            if not 0 <= seed0 + off < img.shape[1]:
                continue
            runs = _runs(img[:, seed0 + off], p["thr"])
            if len(order) == 1 and runs:
                # one curve: the thickest run at the seed column
                runs = [max(runs, key=lambda r: r[1] - r[0])]
            if len(runs) == len(order):
                for ch, r in zip(order, runs):
                    seeds[ch], start[ch] = seed0 + off, r[2]
                break
        else:
            raise ValueError(f"{name}: no line near the seed has {len(order)} runs")
    else:
        for ch in order:
            for off in offsets:
                runs = _runs(inks[ch][:, seed0 + off], p["thr"])
                if runs:
                    seeds[ch], start[ch] = seed0 + off, max(runs, key=lambda r: r[1] - r[0])[2]
                    break
            else:
                raise ValueError(f"{name}: no {ch} ink near the seed")
    out = {}
    for ch in order:
        ink = inks[ch]
        seed = seeds[ch]
        found = {seed: start[ch]}
        for step in (1, -1):
            hist = [(seed, start[ch])]
            k = seed + step
            gap = 0
            while 0 <= k < ink.shape[1] and gap <= p["max_gap"]:
                pts = hist[-12:]
                if len(pts) >= 4:
                    kk = np.array([q[0] for q in pts], float)
                    yy = np.array([q[1] for q in pts], float)
                    sl, ic = np.polyfit(kk, yy, 1)
                    pred = sl * k + ic
                else:
                    pred = hist[-1][1]
                allr = _runs(ink[:, k], p["thr"])
                runs = [r for r in allr if r[1] - r[0] <= p["max_thick"]]
                best = min(runs, key=lambda r: abs(r[2] - pred)) if runs else None
                tol = p["max_jump"] + gap * 0.05
                if p["merged_thick"] and (best is None or abs(best[2] - pred) > tol):
                    # curves drawn over each other: take the thicker run that holds the prediction
                    held = [r for r in allr if r[1] - r[0] <= p["merged_thick"] and r[0] - 1 <= pred <= r[1] + 1]
                    best = held[0] if held else best
                if best is not None and abs(best[2] - pred) <= max(tol, (best[1] - best[0]) / 2 + 1):
                    found[k] = best[2]
                    hist.append((k, best[2]))
                    gap = 0
                else:
                    gap += 1
                k += step
        out[ch] = found
    return out


def read_chart(cfg, pdf_path, dpi=None):
    dpi = dpi or cfg.get("dpi", 600)
    s = dpi / 72.0
    rgb = render(pdf_path, cfg["page"], dpi)
    dark = _darkness(rgb)
    fx0, fy0, fx1, fy1 = cfg["frame"]
    xa, xb, xres, xpk = _calibrate(dark, cfg["x_ticks"], "x", cfg.get("x_band", (fy0 + 2, fy1 - 2)), s, cfg.get("x_fit"))
    ya, yb, yres, ypk = _calibrate(dark, cfg["y_ticks"], "y", cfg.get("y_band", (fx0 + 2, fx1 - 2)), s, cfg.get("y_fit"))

    # plot area, a little inside the frame
    inset = cfg.get("inset", 1.2)
    px0, px1 = int((cfg.get("trace_x", (fx0, fx1))[0] + inset) * s), int((cfg.get("trace_x", (fx0, fx1))[1] - inset) * s)
    py0, py1 = int((fy0 + inset) * s), int((fy1 - inset) * s)
    grid_w = max(1, int(round(cfg.get("grid_halfwidth_pt", 0.45) * s)))
    gx = [p for p in xpk if px0 + grid_w + 1 < p < px1 - grid_w - 1] if cfg.get("x_gridlines") else []
    gy = [p for p in ypk if py0 + grid_w + 1 < p < py1 - grid_w - 1] if cfg.get("y_gridlines") else []
    gx += [int(round(v * s)) for v in cfg.get("extra_x_lines", [])]
    gy += [int(round(v * s)) for v in cfg.get("extra_y_lines", [])]

    def prepared(ink):
        if cfg.get("open_pt"):
            # thin lines out: horizontal gridlines need a vertical run, vertical ones a horizontal run
            L = max(2, int(np.ceil(cfg["open_pt"] * s)))
            ink = np.maximum(_open_thin(ink, cfg.get("threshold", 0.45), L, 0), 0.0)
            ink = _open_thin(ink, cfg.get("threshold", 0.45), L, 1)
        ink = _paint_out(ink, gx, "x", grid_w)
        ink = _paint_out(ink, gy, "y", grid_w)
        for v in cfg.get("blank_y_lines", []):
            ink[int((v - cfg.get("blank_halfwidth_pt", 0.8)) * s) : int((v + cfg.get("blank_halfwidth_pt", 0.8)) * s) + 1, :] = 0.0
        for ex in cfg.get("exclude", []):
            a, b, c, d = (int(v * s) for v in ex)
            ink[b:d, a:c] = 0.0
        return ink[py0:py1, px0:px1]

    curves = {}
    order = cfg["order"]  # channel names, top (highest density) to bottom, at the seed column
    if all("colour" in cfg["curves"][ch] for ch in order):
        inks = {ch: prepared(_colour_ink(rgb, cfg["curves"][ch]["colour"], cfg["curves"][ch].get("tol", 0.45))) for ch in order}
    else:
        ink = prepared(dark)
        inks = {ch: ink for ch in order}
    thr = cfg.get("threshold", 0.45)
    params = {
        "thr": thr,
        "max_thick": cfg.get("max_thickness_pt", 2.5) * s,
        "max_jump": cfg.get("max_jump_pt", 1.5) * s,
        "max_gap": int(cfg.get("max_gap_pt", 4.0) * s),
        "merged_thick": cfg.get("merged_thickness_pt", 0.0) * s,
        "search": int(4 * s),
    }
    max_gap = params["max_gap"]

    diagnostics = {}
    for xd in cfg.get("debug_columns", []):
        k = int(xd * s) - px0
        diagnostics[f"runs_at_{xd}"] = [
            (round((py0 + a) / s, 2), round((b - a) / s, 2)) for a, b, _ in _runs(inks[order[0]][:, k], thr)
        ]
    if cfg.get("debug_only"):
        return {"diagnostics": diagnostics}
    # column by column: y as a function of x
    found = _track(inks, order, int(cfg["seed_x"] * s) - px0, params, cfg["id"])
    curves = {ch: [(px0 + k, py0 + v) for k, v in found[ch].items()] for ch in order}

    # where curves of one ink run together and cannot be told apart, follow the centre of the
    # band they form (ink-weighted centroid of all ink within `union_halfwidth_pt` of the last
    # position) and give that reading to every channel
    if "union_from_x" in cfg:
        ux = int(cfg["union_from_x"] * s)
        ink = inks[order[0]]
        half = cfg.get("union_halfwidth_pt", 3.0) * s
        lasts = [sorted(q for q in curves[ch] if q[0] < ux)[-1] for ch in order]
        cur = float(np.mean([q[1] for q in lasts])) - py0
        union = []
        k = ux - px0
        gap = 0
        while k < ink.shape[1] and gap <= params["max_gap"]:
            col = ink[:, k]
            lo, hi = max(0, int(cur - half)), min(len(col), int(cur + half) + 1)
            w = np.where(col[lo:hi] > thr, col[lo:hi], 0.0)
            if w.sum() > 0:
                cur = float((w * np.arange(lo, hi)).sum() / w.sum())
                union.append((px0 + k, py0 + cur))
                gap = 0
            else:
                gap += 1
            k += 1
        diagnostics["union_samples"] = len(union)
        for ch in order:
            curves[ch] = [q for q in curves[ch] if q[0] < ux] + union

    # a curve drawn underneath another one (and so hidden wherever the two coincide) takes the
    # other curve's reading where it cannot be seen for longer than a dash gap
    for ch, parent in cfg.get("hidden_under", {}).items():
        mine = np.array(sorted(x for x, _ in curves[ch]))
        extra = [(x, y) for x, y in curves[parent] if np.abs(mine - x).min() > max_gap]
        curves[ch] = curves[ch] + extra

    curves = {ch: ([x for x, _ in sorted(v)], [y for _, y in sorted(v)]) for ch, v in curves.items()}

    out = {}
    for ch, (xs, ys) in curves.items():
        if ch not in cfg.get("keep", curves):
            continue
        if len(xs) < 10:
            raise ValueError(f"{cfg['id']}: channel {ch}: only {len(xs)} samples")
        xs, ys = _despike(np.array(xs, float), np.array(ys, float), limit=cfg.get("despike_pt", 0.6) * s)
        xpt = (xs + 0.5) / s
        ypt = (ys + 0.5) / s
        out[ch] = {
            "log_h": (xa + xb * xpt).tolist(),
            "density": (ya + yb * ypt).tolist(),
            "samples": int(len(xs)),
        }
    return {
        "dpi": dpi,
        "x_calibration": {"a": xa, "b": xb, "ticks": xres},
        "y_calibration": {"a": ya, "b": yb, "ticks": yres},
        "curves": out,
        "diagnostics": diagnostics,
    }
