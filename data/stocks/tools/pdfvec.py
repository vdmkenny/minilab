"""Read the vector drawing and the words of one PDF page.

Coordinates are PDF points with the origin at the top-left of the page and y pointing down, the
same frame `pdftotext -bbox` uses, so that words and paths can be compared directly.

`page_paths` replays the page's drawing operators (including form XObjects), applies every
coordinate transform, and returns each painted path as a list of polylines, together with its
stroke colour, fill colour, line width and dash pattern. Bezier segments are flattened into
short straight pieces.
"""

import html
import re
import subprocess

import numpy as np
from pypdf import PdfReader
from pypdf.generic import ContentStream

BEZIER_STEPS = 24


def _mat(a, b, c, d, e, f):
    return np.array([[a, b, 0.0], [c, d, 0.0], [e, f, 1.0]])


def _apply(m, x, y):
    v = np.array([x, y, 1.0]) @ m
    return float(v[0]), float(v[1])


def _colour(operands, space):
    vals = [float(v) for v in operands if not hasattr(v, "startswith")]
    if space == "gray" or len(vals) == 1:
        g = vals[0] if vals else 0.0
        return (g, g, g)
    if space == "cmyk" or len(vals) == 4:
        c, m, y, k = vals[:4]
        return ((1 - c) * (1 - k), (1 - m) * (1 - k), (1 - y) * (1 - k))
    if len(vals) >= 3:
        return tuple(vals[:3])
    return (0.0, 0.0, 0.0)


class _State:
    def __init__(self):
        self.ctm = np.identity(3)
        self.stroke = (0.0, 0.0, 0.0)
        self.fill = (0.0, 0.0, 0.0)
        self.stroke_space = "gray"
        self.fill_space = "gray"
        self.width = 1.0
        self.dash = ()

    def copy(self):
        s = _State()
        s.__dict__.update(self.__dict__)
        s.ctm = self.ctm.copy()
        return s


def _space_name(name, resources):
    name = str(name)
    if name in ("/DeviceGray", "/CalGray", "/G"):
        return "gray"
    if name in ("/DeviceCMYK", "/CMYK"):
        return "cmyk"
    if name in ("/DeviceRGB", "/CalRGB", "/RGB"):
        return "rgb"
    try:
        cs = resources["/ColorSpace"][name]
        cs = cs.get_object() if hasattr(cs, "get_object") else cs
        if isinstance(cs, list) and str(cs[0]) == "/ICCBased":
            n = int(cs[1].get_object()["/N"])
            return {1: "gray", 3: "rgb", 4: "cmyk"}[n]
        if isinstance(cs, list) and str(cs[0]) in ("/Separation", "/DeviceN"):
            return "sep"
    except Exception:
        pass
    return "rgb"


def _walk(reader, content, resources, state, out, depth=0):
    ops = ContentStream(content, reader).operations
    stack = []
    subpaths = []
    current = []
    start = None
    pos = None

    def flush_current():
        nonlocal current
        if len(current) >= 2:
            subpaths.append(current)
        current = []

    def to_page(x, y):
        return _apply(state.ctm, x, y)

    for operands, op in ops:
        op = op.decode() if isinstance(op, bytes) else op
        if op == "q":
            stack.append(state.copy())
        elif op == "Q":
            if stack:
                state = stack.pop()
        elif op == "cm":
            state.ctm = _mat(*[float(v) for v in operands]) @ state.ctm
        elif op == "w":
            state.width = float(operands[0])
        elif op == "d":
            state.dash = tuple(float(v) for v in operands[0])
        elif op == "RG":
            state.stroke, state.stroke_space = _colour(operands, "rgb"), "rgb"
        elif op == "rg":
            state.fill, state.fill_space = _colour(operands, "rgb"), "rgb"
        elif op == "G":
            state.stroke, state.stroke_space = _colour(operands, "gray"), "gray"
        elif op == "g":
            state.fill, state.fill_space = _colour(operands, "gray"), "gray"
        elif op == "K":
            state.stroke, state.stroke_space = _colour(operands, "cmyk"), "cmyk"
        elif op == "k":
            state.fill, state.fill_space = _colour(operands, "cmyk"), "cmyk"
        elif op == "CS":
            state.stroke_space = _space_name(operands[0], resources)
            state.stroke = (0.0, 0.0, 0.0)
        elif op == "cs":
            state.fill_space = _space_name(operands[0], resources)
            state.fill = (0.0, 0.0, 0.0)
        elif op in ("SC", "SCN"):
            if state.stroke_space == "sep":
                t = float(operands[0]) if operands else 1.0
                state.stroke = (1 - t, 1 - t, 1 - t)
            else:
                state.stroke = _colour(operands, state.stroke_space)
        elif op in ("sc", "scn"):
            if state.fill_space == "sep":
                t = float(operands[0]) if operands else 1.0
                state.fill = (1 - t, 1 - t, 1 - t)
            else:
                state.fill = _colour(operands, state.fill_space)
        elif op == "m":
            flush_current()
            pos = (float(operands[0]), float(operands[1]))
            start = pos
            current = [to_page(*pos)]
        elif op == "l":
            pos = (float(operands[0]), float(operands[1]))
            if not current:
                current = [to_page(*pos)]
            else:
                current.append(to_page(*pos))
        elif op in ("c", "v", "y"):
            vals = [float(v) for v in operands]
            p0 = pos
            if op == "c":
                p1, p2, p3 = (vals[0], vals[1]), (vals[2], vals[3]), (vals[4], vals[5])
            elif op == "v":
                p1, p2, p3 = p0, (vals[0], vals[1]), (vals[2], vals[3])
            else:
                p1, p2, p3 = (vals[0], vals[1]), (vals[2], vals[3]), (vals[2], vals[3])
            for i in range(1, BEZIER_STEPS + 1):
                t = i / BEZIER_STEPS
                u = 1 - t
                x = u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0]
                y = u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1]
                current.append(to_page(x, y))
            pos = p3
        elif op == "h":
            if current and start is not None:
                current.append(to_page(*start))
            flush_current()
        elif op == "re":
            flush_current()
            x, y, w, h = [float(v) for v in operands]
            subpaths.append([to_page(x, y), to_page(x + w, y), to_page(x + w, y + h), to_page(x, y + h), to_page(x, y)])
        elif op in ("S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"):
            if op in ("s", "b", "b*") and current and start is not None:
                current.append(to_page(*start))
            flush_current()
            if op != "n" and subpaths:
                # line width in page units: scale by the CTM's mean scale
                scale = float(np.sqrt(abs(np.linalg.det(state.ctm[:2, :2]))))
                out.append(
                    {
                        "subpaths": [np.array(sp) for sp in subpaths],
                        "stroked": op in ("S", "s", "B", "B*", "b", "b*"),
                        "filled": op in ("f", "F", "f*", "B", "B*", "b", "b*"),
                        "stroke": state.stroke,
                        "fill": state.fill,
                        "width": state.width * scale,
                        "dash": tuple(d * scale for d in state.dash),
                    }
                )
            subpaths = []
            current = []
        elif op == "Do" and depth < 8:
            try:
                xobj = resources["/XObject"][operands[0]].get_object()
            except Exception:
                continue
            if xobj.get("/Subtype") != "/Form":
                continue
            sub = state.copy()
            if "/Matrix" in xobj:
                sub.ctm = _mat(*[float(v) for v in xobj["/Matrix"]]) @ sub.ctm
            res = xobj.get("/Resources", resources)
            res = res.get_object() if hasattr(res, "get_object") else res
            _walk(reader, xobj, res, sub, out, depth + 1)
    return out


def page_paths(pdf_path, page_number):
    """Painted paths on a page (1-based), in top-left page points."""
    reader = PdfReader(pdf_path)
    page = reader.pages[page_number - 1]
    box = page.mediabox
    height = float(box.top)
    left = float(box.left)
    resources = page.get("/Resources", {})
    resources = resources.get_object() if hasattr(resources, "get_object") else resources
    paths = _walk(reader, page.get_contents(), resources, _State(), [])
    for p in paths:
        p["subpaths"] = [np.column_stack([sp[:, 0] - left, height - sp[:, 1]]) for sp in p["subpaths"]]
    return paths


_WORD = re.compile(r'<word xMin="([\d.]+)" yMin="([\d.]+)" xMax="([\d.]+)" yMax="([\d.]+)">(.*?)</word>')


def page_words(pdf_path, page_number):
    """Words on a page as (text, x0, y0, x1, y1) in top-left page points, from pdftotext -bbox."""
    out = subprocess.run(
        ["pdftotext", "-bbox", "-f", str(page_number), "-l", str(page_number), pdf_path, "-"],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    return [(html.unescape(m[4]), float(m[0]), float(m[1]), float(m[2]), float(m[3])) for m in _WORD.findall(out)]
