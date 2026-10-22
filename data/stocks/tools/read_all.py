"""Read every chart in charts.py and write one JSON file per chart.

usage: read_all.py PDF_DIR OUT_DIR [ID...]

PDF_DIR holds the makers' PDFs (searched recursively by file name). For each chart the JSON file
has the axis calibration with its tick residuals, the curves as read, the grid values that go into
stocks.zig, and the derived base density, gamma and density range. Raster charts are read twice,
at `dpi` and at `dpi2`, and the difference between the two reads is recorded.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import numpy as np  # noqa: E402

import charts  # noqa: E402
import read_raster  # noqa: E402
import read_vector  # noqa: E402
from derive import derive  # noqa: E402
from grid import dense, resample  # noqa: E402


def find(pdf_dir, name):
    for root, _, files in os.walk(pdf_dir):
        if name in files:
            return os.path.join(root, name)
    raise FileNotFoundError(name)


def finish(cfg, result, raster):
    for ch, c in result["curves"].items():
        x = np.array(c["log_h"])
        d = np.array(c["density"])
        o = np.argsort(x)
        x, d = x[o], d[o]
        lim = cfg.get("channel_x_limits", {}).get(ch, cfg.get("x_limits"))
        if lim:
            m = (x >= lim[0]) & (x <= lim[1])
            x, d = x[m], d[m]
        c["log_h"], c["density"] = x.tolist(), d.tolist()
        xs, ds = dense(x, d, raster)
        c["dense"] = {"log_h": xs.tolist(), "density": ds.tolist()}
        step, g, v = resample(x, d, raster, cfg.get("grid_step"))
        c["grid"] = {"step": step, "log_h": g.tolist(), "density": v.tolist()}
        c["derived"] = derive(xs, ds, cfg["kind"]) if xs[-1] - xs[0] > 0.6 else None
    return result


def compare(a, b):
    """Largest and mean absolute density difference between two reads, over their common range."""
    worst, total, n = 0.0, 0.0, 0
    for ch in a["curves"]:
        xa, da = np.array(a["curves"][ch]["dense"]["log_h"]), np.array(a["curves"][ch]["dense"]["density"])
        xb, db = np.array(b["curves"][ch]["dense"]["log_h"]), np.array(b["curves"][ch]["dense"]["density"])
        lo, hi = max(xa[0], xb[0]), min(xa[-1], xb[-1])
        m = (xa >= lo) & (xa <= hi)
        diff = np.abs(da[m] - np.interp(xa[m], xb, db))
        worst = max(worst, float(diff.max()))
        total += float(diff.sum())
        n += int(m.sum())
    return {"max": worst, "mean": total / max(n, 1)}


def main():
    pdf_dir, out_dir = sys.argv[1], sys.argv[2]
    only = set(sys.argv[3:])
    os.makedirs(out_dir, exist_ok=True)
    for cfg in charts.VECTOR + charts.RASTER:
        if only and cfg["id"] not in only:
            continue
        path = find(pdf_dir, cfg["pdf"])
        raster = cfg in charts.RASTER
        if raster:
            result = finish(cfg, read_raster.read_chart(cfg, path, cfg.get("dpi", 600)), True)
            second = finish(cfg, read_raster.read_chart(cfg, path, cfg.get("dpi2", 300)), True)
            result["second_read"] = {"dpi": second["dpi"], "difference": compare(result, second)}
        else:
            result = finish(cfg, read_vector.read_chart(cfg, path), False)
        result.update({"id": cfg["id"], "pdf": cfg["pdf"], "page": cfg["page"], "kind": cfg["kind"], "raster": raster})
        with open(os.path.join(out_dir, cfg["id"] + ".json"), "w") as f:
            json.dump(result, f, indent=1)
        xr = max(abs(t[2]) for t in result["x_calibration"]["ticks"])
        yr = max(abs(t[2]) for t in result["y_calibration"]["ticks"])
        extra = ""
        if raster:
            sd = result["second_read"]["difference"]
            ext = {ch: (round(c["log_h"][0], 2), round(c["log_h"][-1], 2)) for ch, c in second["curves"].items()}
            extra = f"; {result['dpi']} vs {result['second_read']['dpi']} dpi: max {sd['max']:.4f} mean {sd['mean']:.4f} D; second read extents {ext}"
        print(f"{cfg['id']}: worst tick residual log H {xr:.4f}, density {yr:.4f}{extra}")
        for ch, c in result["curves"].items():
            d = c["derived"]
            if d is None:
                print(f"  {ch:2} log H {c['log_h'][0]:+.3f}..{c['log_h'][-1]:+.3f}: too short to derive")
                continue
            fmt = lambda v: "null" if v is None else f"{v:.3f}"
            print(
                f"  {ch:2} log H {c['log_h'][0]:+.3f}..{c['log_h'][-1]:+.3f} ({len(c['grid']['log_h'])} pts @{c['grid']['step']})"
                f"  D {c['density'][0]:.3f}..{c['density'][-1]:.3f}"
                f"  base {fmt(d['base'])} gamma {d['gamma']:.3f} on {d['interval'][0]:+.2f}..{d['interval'][1]:+.2f} range {fmt(d['range'])}"
                f"  end grads {d['least_exposed_gradient']:.3f}/{d['most_exposed_gradient']:.3f}"
            )


if __name__ == "__main__":
    main()
