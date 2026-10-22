"""Write the readings into src/presets/stocks.zig.

usage: make_zig.py READINGS_DIR STOCKS_ZIG [--dry-run]

For every stock in stocks_meta.py: the table entry (base_density, gamma and density_range from
the reading, rounded to 0.001) and its curve constant. An entry or constant that already exists
under that name is replaced in place; a new entry goes after the entry named in `after`, and a
new constant at the end of `curve_data`. Run `zig fmt` afterwards to align the number columns.
"""

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from stocks_meta import STOCKS  # noqa: E402

BW = ("bw_negative", "bw_positive")


def fmt3(v):
    return f"{v:.3f}"


def triple(vals):
    if vals is None or any(v is None for v in vals):
        return "null"
    return ".{ " + ", ".join(fmt3(v) for v in vals) + " }"


def rows(vals, indent):
    out = []
    for i in range(0, len(vals), 10):
        out.append(indent + ", ".join(fmt3(v) for v in vals[i : i + 10]) + ",")
    return "\n".join(out)


def sampled(c, indent):
    return (
        f"{indent}sampled(&.{{\n{rows(c['grid']['log_h'], indent + '    ')}\n"
        f"{indent}}}, &.{{\n{rows(c['grid']['density'], indent + '    ')}\n{indent}}})"
    )


def entry_and_const(meta, reading):
    curves = reading["curves"]
    bw = meta["kind"] in BW
    chans = ["bw", "bw", "bw"] if bw else ["r", "g", "b"]
    d = [curves[ch]["derived"] for ch in chans]
    base = [x["base"] for x in d]
    gamma = [x["gamma"] for x in d]
    rng = [x["range"] for x in d]
    if any(v is None for v in base):
        base, rng = None, None
    if rng is not None and any(v is None for v in rng):
        rng = None
    entry = (
        "    .{\n"
        f'        .name = "{meta["name"]}",\n'
        f'        .maker = "{meta["maker"]}",\n'
        f"        .kind = .{meta['kind']},\n"
        f"        .iso = {meta['iso']},\n"
        f"        .base_density = {triple(base)},\n"
        f"        .gamma = {triple(gamma)},\n"
        f"        .density_range = {triple(rng)},\n"
        f"        .curves = curve_data.{meta['const']},\n"
        f"        .source = {json.dumps(meta['source'], ensure_ascii=False)},\n"
        "    },\n"
    )
    name = meta["const"]
    if meta.get("shared_curves"):
        const = None
    elif bw:
        const = (
            f"    const {name}_curve = {sampled(curves['bw'], '    ').lstrip()};\n"
            f"    const {name}: [3][]const Point = .{{ {name}_curve, {name}_curve, {name}_curve }};\n"
        )
    else:
        const = f"    const {name}: [3][]const Point = .{{\n"
        for ch in "rgb":
            const += sampled(curves[ch], "        ") + ",\n"
        const += "    };\n"
    return entry, const


def find_entry(src, name):
    m = re.search(r"    \.\{\n        \.name = " + re.escape(json.dumps(name, ensure_ascii=False)) + r",\n.*?\n    \},\n", src, re.S)
    return m


def find_const(src, name):
    m = re.search(r"    const " + re.escape(name) + r": \[3\]\[\]const Point = \.\{\n.*?\n    \};\n", src, re.S)
    if m:
        return m
    m = re.search(
        r"    const " + re.escape(name) + r"_curve = sampled\(.*?\}\);\n    const " + re.escape(name) + r": \[3\]\[\]const Point = [^\n]*\n",
        src,
        re.S,
    )
    return m


def main():
    rdir, zig = sys.argv[1], sys.argv[2]
    dry = "--dry-run" in sys.argv
    src = open(zig, encoding="utf-8").read()
    new_consts = []
    for meta in STOCKS:
        with open(os.path.join(rdir, meta["reading"] + ".json")) as f:
            reading = json.load(f)
        entry, const = entry_and_const(meta, reading)
        m = find_entry(src, meta["name"])
        if m:
            src = src[: m.start()] + entry + src[m.end() :]
            action = "replaced"
        else:
            a = find_entry(src, meta["after"])
            if not a:
                raise SystemExit(f"no entry {meta['after']!r} to insert {meta['name']!r} after")
            src = src[: a.end()] + entry + src[a.end() :]
            action = f"inserted after {meta['after']}"
        if const is not None:
            c = find_const(src, meta["const"])
            if c:
                src = src[: c.start()] + const + src[c.end() :]
                caction = "curves replaced"
            else:
                new_consts.append(const)
                caction = "curves added"
        else:
            caction = f"curves shared ({meta['const']})"
        print(f"{meta['name']}: {action}; {caction}")
    if new_consts:
        end = re.search(r"\n\};\n\n/// Zips a log exposure grid", src)
        src = src[: end.start() + 1] + "".join(new_consts) + src[end.start() + 1 :]
    if not dry:
        with open(zig, "w", encoding="utf-8") as f:
            f.write(src)


if __name__ == "__main__":
    main()
