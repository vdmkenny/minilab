"""Check derive.py against entries whose values were derived from vector charts earlier.

usage: check_derive.py STOCKS_ZIG NAME... (curve_data constant names)
"""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np
from derive import derive

src = open(sys.argv[1]).read()
for name in sys.argv[2:]:
    m = re.search(r"const %s: \[3\]\[\]const Point = \.\{(.*?)\n    \};" % name, src, re.S)
    body = m.group(1)
    chans = re.findall(r"sampled\(&\.\{(.*?)\}, &\.\{(.*?)\}\)", body, re.S)
    out = []
    for xs, ds in chans:
        x = np.array([float(v) for v in xs.replace("\n", " ").split(",") if v.strip()])
        d = np.array([float(v) for v in ds.replace("\n", " ").split(",") if v.strip()])
        kind = "negative" if d[-1] > d[0] else "positive"
        r = derive(x, d, kind)
        out.append(r)
    print(name, "gamma", [round(r["gamma"], 3) for r in out], "base", [None if r["base"] is None else round(r["base"], 3) for r in out], "range", [None if r["range"] is None else round(r["range"], 3) for r in out])
