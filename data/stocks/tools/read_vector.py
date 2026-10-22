"""Read characteristic curves drawn as vector paths in a PDF.

For one chart (see charts.py):

1. Replay the page's drawing (pdfvec.page_paths).
2. Calibrate each axis: every tick named in the chart's config is snapped to the nearest tick
   mark, gridline or frame edge actually drawn in the PDF (within 1 pt), and a straight line
   value = a + b * position is fitted through them by least squares. The residual of every tick
   is reported.
3. Pick the curve paths with the chart's selectors, map them to (log H, density) and keep their
   full drawn extent.
"""

import numpy as np

from pdfvec import page_paths

SNAP = 1.0


def _axis_candidates(paths, frame, vertical):
    """Positions of axis-aligned straight marks near the frame (tick marks, gridlines, edges)."""
    x0, y0, x1, y1 = frame
    out = []
    for p in paths:
        for sp in p["subpaths"]:
            if len(sp) < 2:
                continue
            for a, b in zip(sp[:-1], sp[1:]):
                dx, dy = abs(b[0] - a[0]), abs(b[1] - a[1])
                if vertical and dx < 0.15 and dy > 0.8:
                    x = 0.5 * (a[0] + b[0])
                    if x0 - 3 <= x <= x1 + 3 and min(a[1], b[1]) <= y1 + 12 and max(a[1], b[1]) >= y0 - 12:
                        out.append(x)
                if not vertical and dy < 0.15 and dx > 0.8:
                    y = 0.5 * (a[1] + b[1])
                    if y0 - 3 <= y <= y1 + 3 and min(a[0], b[0]) <= x1 + 12 and max(a[0], b[0]) >= x0 - 12:
                        out.append(y)
    return np.array(sorted(out))


def calibrate(ticks, candidates, use=None):
    """ticks: [(value, approx_position)]. Returns (a, b, rows) with value = a + b * pos."""
    rows = []
    for value, approx in ticks:
        if len(candidates) == 0:
            raise ValueError("no tick marks found")
        i = int(np.argmin(np.abs(candidates - approx)))
        if abs(candidates[i] - approx) > SNAP:
            raise ValueError(f"no tick near {approx} for value {value}")
        rows.append((value, float(candidates[i])))
    fit_rows = rows if use is None else [r for r in rows if r[0] in use]
    v = np.array([r[0] for r in fit_rows])
    p = np.array([r[1] for r in fit_rows])
    b, a = np.polyfit(p, v, 1)
    out = [(value, pos, value - (a + b * pos)) for value, pos in rows]
    return float(a), float(b), out


def _curve_candidates(paths, frame, min_points):
    x0, y0, x1, y1 = frame
    out = []
    for i, p in enumerate(paths):
        if not p["stroked"]:
            continue
        for j, sp in enumerate(p["subpaths"]):
            if len(sp) < min_points:
                continue
            if sp[:, 0].min() < x0 - 1 or sp[:, 0].max() > x1 + 1 or sp[:, 1].min() < y0 - 1 or sp[:, 1].max() > y1 + 1:
                continue
            if sp[:, 0].max() - sp[:, 0].min() < 0.2 * (x1 - x0):
                continue
            out.append({"id": f"{i}.{j}", "pts": sp, "dash": p["dash"], "width": p["width"], "stroke": p["stroke"]})
    return out


def _as_function(pts):
    """Turn a drawn polyline into x-sorted samples (drop repeated points)."""
    order = np.argsort(pts[:, 0], kind="stable")
    x = pts[order, 0]
    y = pts[order, 1]
    keep = np.concatenate([[True], np.diff(x) > 1e-6])
    return x[keep], y[keep]


def read_chart(cfg, pdf_path):
    paths = page_paths(pdf_path, cfg["page"])
    frame = cfg["frame"]
    xa, xb, xres = calibrate(cfg["x_ticks"], _axis_candidates(paths, frame, True), cfg.get("x_fit"))
    ya, yb, yres = calibrate(cfg["y_ticks"], _axis_candidates(paths, frame, False), cfg.get("y_fit"))
    cands = _curve_candidates(paths, frame, cfg.get("min_points", 8))
    curves = {}
    for channel, sel in cfg["curves"].items():
        if "path" in sel:
            chosen = [c for c in cands if c["id"] == sel["path"]]
        elif "dash" in sel:
            chosen = [c for c in cands if len(c["dash"]) == len(sel["dash"]) and np.allclose(c["dash"], sel["dash"], atol=0.05)]
            if "rank" in sel:
                chosen = sorted(chosen, key=lambda c: c["pts"][np.argmin(c["pts"][:, 0]), 1])[sel["rank"] : sel["rank"] + 1]
        else:
            # rank by density at the left end (0 = highest density)
            ordered = sorted(cands, key=lambda c: c["pts"][np.argmin(c["pts"][:, 0]) if sel.get("at", "left") == "left" else np.argmax(c["pts"][:, 0]), 1])
            chosen = [ordered[sel["rank"]]]
        if len(chosen) != 1:
            raise ValueError(f"{cfg['id']}: selector {sel} matched {len(chosen)} paths: {[c['id'] for c in cands]}")
        c = chosen[0]
        px, py = _as_function(c["pts"])
        curves[channel] = {
            "path": c["id"],
            "log_h": (xa + xb * px).tolist(),
            "density": (ya + yb * py).tolist(),
        }
    return {
        "x_calibration": {"a": xa, "b": xb, "ticks": xres},
        "y_calibration": {"a": ya, "b": yb, "ticks": yres},
        "curves": curves,
    }
