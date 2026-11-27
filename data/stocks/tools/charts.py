"""Where each chart is and how to read it.

`pdf` is the file name of the maker's PDF; data/stocks/README.md gives the URL each was
downloaded from. Positions are PDF points from the top-left of the page (vector charts) or
pixels of a render at `dpi` (raster charts). Tick positions are approximate: the readers snap
them to the tick marks, gridlines or frame edges actually drawn.
"""

STOP = 0.30103  # log10(2): one camera stop in log H


def _stops(left_edge, first_tick, last_tick, right_edge):
    """Camera-stop ticks -8..8 (frame edges at +-8, tick marks at -7..7), as relative log H."""
    step = (last_tick - first_tick) / 14
    ticks = [(-8 * STOP, left_edge)]
    ticks += [(k * STOP, first_tick + (k + 7) * step) for k in range(-7, 8)]
    ticks += [(8 * STOP, right_edge)]
    return ticks


def _even(values, first, last):
    step = (last - first) / (len(values) - 1)
    return [(v, first + i * step) for i, v in enumerate(values)]


VECTOR = [
    # Kodak VISION3, July 2015 editions: Status M, ECN-2. The frame spans -8 to +8 camera stops,
    # with tick marks every stop; that axis is used, at 0.30103 log H per stop, relative to
    # normal exposure. (The top log H labels disagree with the stop axis; see the README.)
    {
        "id": "kodak_vision3_50d",
        "pdf": "h1-5203t_vision3_50d_2015-07.pdf",
        "page": 4,
        "frame": (356.13, 122.29, 540.60, 306.78),
        "x_ticks": _stops(356.13, 367.64, 529.05, 540.60),
        "y_ticks": [(0.0, 306.78), (1.0, 244.71), (2.0, 182.55), (3.0, 122.29)],
        "y_fit": [0.0, 1.0, 2.0],
        "curves": {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}},
        "kind": "negative",
    },
    {
        "id": "kodak_vision3_250d",
        "pdf": "h1-5207t_vision3_250d_2015-07.pdf",
        "page": 4,
        "frame": (357.07, 125.23, 541.59, 309.72),
        "x_ticks": _stops(357.07, 368.57, 530.09, 541.59),
        "y_ticks": [(0.0, 309.72), (1.0, 248.23), (2.0, 186.73), (3.0, 125.23)],
        "curves": {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}},
        "kind": "negative",
    },
    {
        "id": "kodak_vision3_200t",
        "pdf": "h1-5213t_vision3_200t_2015-07.pdf",
        "page": 4,
        "frame": (357.49, 120.44, 542.08, 304.92),
        "x_ticks": _stops(357.49, 369.05, 530.56, 542.08),
        "y_ticks": [(0.0, 304.92), (1.0, 243.43), (2.0, 181.94), (3.0, 120.44)],
        "curves": {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}},
        "kind": "negative",
    },
    {
        "id": "kodak_vision3_500t",
        "pdf": "h1-5219t_vision3_500t_2015-07.pdf",
        "page": 4,
        "frame": (353.63, 122.30, 538.15, 306.79),
        "x_ticks": _stops(353.63, 365.13, 526.65, 538.15),
        "y_ticks": [(0.0, 306.79), (1.0, 245.29), (2.0, 183.80), (3.0, 122.30)],
        "curves": {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}},
        "kind": "negative",
    },
    # Kodak E-88, June 2009: Kodachrome 64, Status A, K-14, daylight 1/50 s.
    {
        "id": "kodak_kodachrome_64",
        "pdf": "e88_kodak_20160909.pdf",
        "page": 4,
        "frame": (71.27, 136.49, 255.78, 321.00),
        "x_ticks": _even([-3.0, -2.0, -1.0, 0.0, 1.0], 71.27, 255.78),
        "y_ticks": _even([4.0, 3.0, 2.0, 1.0, 0.0], 136.49, 321.00),
        "curves": {"r": {"rank": 0}, "g": {"rank": 1}, "b": {"rank": 2}},
        "kind": "positive",
    },
    # Kodak E-4L, July 1997: Pro Image 100, Status M, C-41, daylight.
    {
        "id": "kodak_pro_image_100",
        "pdf": "e4L_pro_image_100_1997-07_snap2016.pdf",
        "page": 3,
        "frame": (86.73, 75.34, 287.19, 259.84),
        "x_ticks": _even([-3.0, -2.0, -1.0, 0.0, 1.0], 102.88, 287.19),
        "y_ticks": _even([4.0, 3.0, 2.0, 1.0, 0.0], 75.34, 259.84),
        "curves": {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}},
        "kind": "negative",
    },
    # Kodak Alaris F-4001, March 2018: T-MAX P3200, T-MAX Developer, small tank, 20 C, 12 min
    # (the solid curve), diffuse visual density.
    {
        "id": "kodak_t_max_p3200",
        "pdf": "f4001_tmax_p3200_2018-03.pdf",
        "page": 8,
        "frame": (355.81, 50.06, 540.25, 234.49),
        "x_ticks": _even([-4.0, -3.0, -2.0, -1.0, 0.0, 1.0], 355.81, 540.25),
        "y_ticks": _even([3.0, 2.0, 1.0, 0.0], 50.06, 234.49),
        "curves": {"bw": {"dash": ()}},
        "kind": "negative",
    },
]

# Ilford (HARMAN technology) black-and-white datasheets, 2010 editions, where the curve is a
# vector drawing. Density against relative log exposure, gridlines every 0.5 on both axes.
_HALF = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
_DENS = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]


def _grid(values, positions):
    return list(zip(values, positions))


VECTOR += [
    # HP5 Plus, April 2010: 35 mm, ILFOTEC HC 1+31, 6.5 min, 20 C, intermittent agitation.
    {
        "id": "ilford_hp5_plus",
        "pdf": "hp5_plus_ed2010-04_20106281054152313.pdf",
        "page": 5,
        "frame": (326.52, 313.38, 511.20, 435.48),
        "x_ticks": _grid(_HALF, [326.52, 347.10, 367.62, 388.20, 408.72, 429.30, 449.82, 470.40, 490.92]),
        "y_ticks": _grid(_DENS, [435.48, 415.26, 394.98, 375.00, 354.72, 334.20, 313.38]),
        "curves": {"bw": {"rank": 0}},
        "kind": "negative",
    },
    # FP4 Plus, July 2010: rollfilm, ILFOTEC HC 1+31, 8 min, 20 C.
    {
        "id": "ilford_fp4_plus",
        "pdf": "fp4_plus_ed2010-07_2010712125850702.pdf",
        "page": 4,
        "frame": (328.02, 562.56, 512.94, 684.90),
        "x_ticks": _grid(_HALF, [328.02, 348.66, 369.12, 389.76, 410.28, 430.92, 451.56, 472.02, 492.60]),
        "y_ticks": _grid(_DENS, [684.90, 664.44, 644.22, 624.30, 603.90, 583.38, 562.56]),
        "curves": {"bw": {"rank": 0}},
        "kind": "negative",
    },
    # Pan F Plus, June 2010: rollfilm, ILFOTEC HC 1+31, 4 min, 20 C.
    {
        "id": "ilford_pan_f_plus",
        "pdf": "panf_plus_ed2010-06_20114271111491224.pdf",
        "page": 4,
        "frame": (326.28, 299.70, 510.72, 424.56),
        "x_ticks": _grid(_HALF, [326.28, 346.62, 367.14, 387.66, 408.12, 428.58, 449.10, 469.62, 490.08]),
        "y_ticks": _grid(_DENS, [424.56, 403.56, 382.80, 361.98, 341.16, 320.52, 299.70]),
        "curves": {"bw": {"rank": 0}},
        "kind": "negative",
    },
    # XP2 Super, June 2010: standard C-41 chemicals.
    {
        "id": "ilford_xp2_super",
        "pdf": "xp2_super_ed2010-06_201142711321939.pdf",
        "page": 2,
        "frame": (327.48, 452.88, 511.38, 574.50),
        "x_ticks": _grid(_HALF, [327.48, 347.94, 368.40, 388.86, 409.32, 429.78, 450.24, 470.82, 491.22]),
        "y_ticks": _grid(_DENS, [574.50, 554.40, 534.18, 514.32, 494.10, 473.64, 452.88]),
        "curves": {"bw": {"rank": 0}},
        "kind": "negative",
    },
    # Delta 3200, May 2010: MICROPHEN stock, 7/9/12/16 min at 20 C; the 9 min curve (the
    # development table's time for EI 3200) is third from the top at the right-hand end.
    {
        "id": "ilford_delta_3200",
        "pdf": "delta3200_ed2010-05_201071394723115.pdf",
        "page": 6,
        "frame": (86.40, 308.88, 270.72, 430.32),
        "x_ticks": _grid(_HALF, [86.40, 106.08, 126.72, 147.24, 167.82, 188.40, 208.98, 229.56, 250.08]),
        "y_ticks": _grid(_DENS, [430.32, 409.98, 389.70, 369.48, 349.20, 328.92, 308.88]),
        "curves": {"bw": {"rank": 2, "at": "right"}},
        "kind": "negative",
    },
]

# Fujifilm datasheets whose characteristic curves are vector drawings. Their labels are drawn as
# outlines, not text, so the tick values are given here from the printed labels.
VECTOR += [
    # Pro 400H, AF3-176E (January 2005): Status M, C-41, daylight 1/125 s.
    {
        "id": "fujifilm_pro_400h",
        "pdf": "pro400h_eu.pdf",
        "page": 8,
        "frame": (78.63, 105.04, 285.52, 249.57),
        "x_ticks": _grid([-4.0, -3.5, -3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0],
                         [78.63, 99.00, 120.35, 141.41, 161.91, 182.41, 203.19, 223.69, 244.47, 264.75, 285.52]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5],
                         [249.57, 228.73, 208.24, 187.46, 166.67, 146.46, 125.40, 105.04]),
        "curves": {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}},
        "kind": "negative",
    },
    # Velvia 100, AF3-202E (February 2005): Status A, E-6, daylight. R solid, G dash-dot, B dashed.
    {
        "id": "fujifilm_velvia_100",
        "pdf": "velvia100_us_AF3-202E.pdf",
        "page": 8,
        "frame": (86.04, 174.22, 281.87, 347.49),
        "x_ticks": _grid([-3.5, -3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0],
                         [86.04, 107.57, 129.46, 151.63, 172.94, 194.83, 216.43, 238.32, 259.92, 281.80]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
                         [347.49, 326.29, 304.59, 282.75, 261.13, 239.57, 217.74, 195.66, 174.22]),
        "curves": {"r": {"dash": ()}, "g": {"dash": (9.0, 1.5, 2.5, 1.5)}, "b": {"dash": (3.0, 1.5)}},
        "kind": "positive",
    },
]

VECTOR += [
    # Kodak AS-2652 (October 2009): AEROCOLOR IV 2460, an aerial colour negative film with no
    # integral mask. The page prints three charts; this is "Developed for Low Contrast": C-41,
    # 3'15" (the standard C-41 developer time), Status M, daylight. The labels B, G and R at the
    # left-hand end are stacked in that order, top to bottom.
    {
        "id": "kodak_aerocolor_iv_2460",
        "pdf": "kodak_aerocolor_2460.pdf",
        "page": 6,
        "frame": (81.52, 336.88, 265.99, 521.32),
        "x_ticks": _grid([-4.0, -3.0, -2.0, -1.0, 0.0, 1.0], [81.52, 118.43, 155.30, 192.21, 229.08, 265.99]),
        "y_ticks": _grid([0.0, 1.0, 2.0, 3.0, 4.0], [521.32, 475.21, 429.10, 382.99, 336.88]),
        "curves": {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}},
        "kind": "negative",
    },
]

# InovisCoat WOLFEN datasheets (Word documents with an embedded chart): C-41, Status M,
# daylight, log H in lux-seconds. Each curve is a 30-point polyline, and the gridlines every
# 1.0 on both axes are drawn as vectors. Labelled blue above green above red.
VECTOR += [
    # WOLFEN NC400 data sheet (undated; the PDF was made in November 2022).
    {
        "id": "orwo_wolfen_nc400",
        "pdf": "orwo_nc400.pdf",
        "page": 2,
        "frame": (90.36, 147.60, 286.80, 322.56),
        "x_ticks": _grid([-4.0, -3.0, -2.0, -1.0, 0.0, 1.0], [90.36, 129.60, 168.96, 208.20, 247.44, 286.80]),
        "y_ticks": _grid([0.0, 1.0, 2.0, 3.0, 4.0], [322.56, 278.76, 234.96, 191.28, 147.60]),
        "curves": {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}},
        "kind": "negative",
    },
    # WOLFEN NC500 Datenblatt (German, undated; the PDF was made in October 2022). Its curves bend
    # into a long shoulder, so its straight part is short.
    {
        "id": "orwo_wolfen_nc500",
        "pdf": "orwo_nc500.pdf",
        "page": 2,
        "frame": (87.24, 163.44, 283.68, 339.60),
        "x_ticks": _grid([-4.0, -3.0, -2.0, -1.0, 0.0, 1.0], [87.24, 126.48, 165.84, 205.08, 244.32, 283.68]),
        "y_ticks": _grid([0.0, 1.0, 2.0, 3.0, 4.0], [339.60, 295.44, 251.40, 207.48, 163.44]),
        "curves": {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}},
        "kind": "negative",
    },
]

# Kodak still-film datasheets: Status M colour negatives, Status A slides and diffuse visual
# density for black-and-white. Each chart has a gridline (or tick mark) every 1.0 on both axes,
# and the frame is the outer one. The colour curves are stacked blue, green, red from the top at
# the left-hand end.
_KODAK_RGB = {"b": {"rank": 0}, "g": {"rank": 1}, "r": {"rank": 2}}


def _kodak(cid, pdf, page, frame, x_values, kind="negative", curves=None):
    x0, y0, x1, y1 = frame
    return {
        "id": cid,
        "pdf": pdf,
        "page": page,
        "frame": frame,
        "x_ticks": _even(list(x_values), x0, x1),
        "y_ticks": _even([4.0, 3.0, 2.0, 1.0, 0.0], y0, y1),
        "curves": curves or _KODAK_RGB,
        "kind": kind,
    }


_KODAK_4_TO_1 = (-4.0, -3.0, -2.0, -1.0, 0.0, 1.0)
VECTOR += [
    # Portra 160, E-4051 (January 2025): C-41, daylight. The inner density gridlines are 46.4 pt
    # apart, and the bottom one 45.3 pt; the frame spans 4.0 D in 184.5 pt, as on Kodak's other
    # sheets. So the density axis is fitted to the frame (0.0 and 4.0) only.
    {**_kodak("kodak_portra_160", "e4051.pdf", 4, (81.45, 102.12, 266.01, 286.60), _KODAK_4_TO_1), "y_fit": [0.0, 4.0]},
    # Portra 400, E-4050 (January 2025).
    _kodak("kodak_portra_400", "e4050.pdf", 4, (81.16, 102.85, 265.63, 287.37), _KODAK_4_TO_1),
    # Portra 800, E-4040 (January 2025): page 4 has three charts, for EI 800, 1600 (push 1) and
    # 3200 (push 2). On the EI 800 chart the -3.0 and -2.0 labels are printed the wrong way
    # round; its gridlines are evenly spaced, so the axis runs -4 to +1 as on the other two.
    _kodak("kodak_portra_800", "e4040.pdf", 4, (81.64, 74.47, 266.17, 258.89), _KODAK_4_TO_1),
    _kodak("kodak_portra_800_push_1", "e4040.pdf", 4, (81.13, 314.06, 265.63, 498.52), _KODAK_4_TO_1),
    _kodak("kodak_portra_800_push_2", "e4040.pdf", 4, (357.65, 70.98, 542.19, 255.52), _KODAK_4_TO_1),
    # Ektar 100, E-4046 (January 2025).
    _kodak("kodak_ektar_100", "e4046.pdf", 4, (81.19, 107.92, 265.70, 292.41), (-3.0, -2.0, -1.0, 0.0, 1.0, 2.0)),
    # Gold 200, E-7022 (June 2023). The log H labels are printed without their minus signs.
    _kodak("kodak_gold_200", "e7022_gold_200.pdf", 4, (81.68, 71.93, 266.18, 256.43), (-3.0, -2.0, -1.0, 0.0, 1.0)),
    # UltraMax 400, E-7023 (February 2016).
    _kodak("kodak_ultramax_400", "e7023_ultramax_400.pdf", 4, (81.09, 112.75, 265.90, 297.35), _KODAK_4_TO_1),
    # Ektachrome E100, E-4000 (August 2018): Status A, E-6, daylight.
    _kodak("kodak_ektachrome_e100", "e4000_ektachrome_100.pdf", 3, (368.72, 358.60, 553.91, 542.97), (-3.0, -2.0, -1.0, 0.0, 1.0), kind="positive"),
    # Tri-X 400, F-4017 (October 2021): 35 mm, T-MAX Developer, small tank, 6 min, 20 C (the
    # table's starting point), the solid curve. The log H labels lost their minus signs.
    _kodak("kodak_tri_x_400", "f4017_trix_320400.pdf", 8, (354.42, 63.48, 538.85, 247.98), _KODAK_4_TO_1, curves={"bw": {"path": "103.0"}}),
    # T-Max 100, F-4016 (June 2018): D-76, small tank, 6 min, 20 C.
    _kodak("kodak_t_max_100", "f4016_tmax_100.pdf", 8, (355.61, 57.01, 540.04, 241.48), _KODAK_4_TO_1, curves={"bw": {"path": "115.0"}}),
    # T-Max 400, F-4043 (February 2016): T-MAX RS Developer and Replenisher, large tank, 5 min,
    # 24 C (the table's starting point for that developer).
    _kodak("kodak_t_max_400", "f4043_tmax_400.pdf", 8, (83.24, 308.44, 267.66, 492.95), _KODAK_4_TO_1, curves={"bw": {"path": "29.0"}}),
    # Verita 200D 5206, brochure K-1216 (April 2026): Status M, ECN-2, 5500 K daylight 1/50 s.
    # Each curve is a filled outline, clipped by the frame. The frame and the camera-stop tick
    # marks are thin filled rectangles, each counted once, at its centre. The top
    # axis gives log H in lux-seconds, -2.915 at the left edge (-8 stops) to 1.885 at the right
    # (+8 stops), so the 17 stop marks are 0.3 log H apart.
    {
        "id": "kodak_verita_200d",
        "pdf": "k1216_verita_200d.pdf",
        "page": 2,
        "frame": (45.90, 484.36, 200.71, 622.86),
        "x_ticks": _even([round(-2.915 + 0.3 * k, 3) for k in range(17)], 45.90, 200.71),
        "y_ticks": [(0.0, 622.86), (1.0, 580.25), (2.0, 537.63), (3.0, 495.02)],
        "thin_rects": 0.5,
        "curves": {"b": {"outline": ["11.0"]}, "g": {"outline": ["10.0"]}, "r": {"outline": ["9.0"]}},
        "kind": "negative",
    },
]

# More Fujifilm datasheets with vector curves and labels drawn as outlines. Gridlines every 0.5
# on both axes. Status M, CN-16, daylight 1/125 s. The curves are stacked blue, green, red from
# the top at the left-hand end.
_HALF_LOG_H = [-4.0, -3.5, -3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5]
_HALF_D = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]
VECTOR += [
    # Fujifilm 200, AF3-0261E (9 February 2022).
    {
        "id": "fujifilm_200",
        "pdf": "fujifilm_200_af3-0261e.pdf",
        "page": 5,
        "frame": (60.17, 127.00, 288.49, 304.58),
        "x_ticks": _even(_HALF_LOG_H, 60.17, 288.49),
        "y_ticks": _even(_HALF_D[:8], 304.58, 127.00),
        "curves": _KODAK_RGB,
        "kind": "negative",
    },
    # Fujifilm 400, AF3-0262E (1 April 2023).
    {
        "id": "fujifilm_400",
        "pdf": "fujifilm_400_af3-0262e.pdf",
        "page": 6,
        "frame": (60.10, 122.94, 287.96, 300.16),
        "x_ticks": _even(_HALF_LOG_H, 60.10, 287.96),
        "y_ticks": _even(_HALF_D[:8], 300.16, 122.94),
        "curves": _KODAK_RGB,
        "kind": "negative",
    },
    # Superia X-TRA 400, 013AR0316A (Japanese). The inner density gridlines are uneven by up to
    # 0.7 pt, so the density axis is fitted to the frame (0.0 and 4.0) only.
    {
        "id": "fujifilm_superia_xtra_400",
        "pdf": "superia_xtra_400_jp.pdf",
        "page": 5,
        "frame": (89.64, 214.57, 285.49, 387.60),
        "x_ticks": _grid(_HALF_LOG_H, [89.64, 111.18, 133.07, 155.24, 176.56, 198.44, 220.05, 241.94, 263.54, 285.49]),
        "y_ticks": _grid(_HALF_D, [387.60, 366.39, 344.97, 322.84, 301.21, 279.66, 257.82, 235.73, 214.57]),
        "y_fit": [0.0, 4.0],
        "curves": _KODAK_RGB,
        "kind": "negative",
    },
    # Pro 160NS, 163AR109A (Japanese). The frame is drawn up to 0.8 pt off the inner gridlines,
    # so both axes are fitted to the inner gridlines only.
    {
        "id": "fujifilm_pro_160ns",
        "pdf": "pro_160ns_jp.pdf",
        "page": 8,
        "frame": (88.39, 117.70, 287.52, 295.86),
        "x_ticks": _grid(_HALF_LOG_H, [88.39, 110.74, 132.93, 155.13, 177.32, 199.51, 221.70, 243.90, 266.09, 287.52]),
        "y_ticks": _grid(_HALF_D, [295.86, 273.78, 251.59, 229.39, 207.20, 185.00, 162.81, 140.61, 117.70]),
        "x_fit": _HALF_LOG_H[1:-1],
        "y_fit": _HALF_D[1:-1],
        "curves": _KODAK_RGB,
        "kind": "negative",
    },
    # Fujicolor 100, 013AR0317A (Japanese): log H -3.5 to 1.0. Drawn like Superia X-TRA 400, so
    # the density axis is fitted to the frame only.
    {
        "id": "fujifilm_fujicolor_100",
        "pdf": "fujicolor_100_jp.pdf",
        "page": 5,
        "frame": (89.95, 214.57, 285.77, 387.59),
        "x_ticks": _grid([v + 0.5 for v in _HALF_LOG_H], [89.95, 111.49, 133.38, 155.54, 176.85, 198.74, 220.34, 242.22, 263.82, 285.77]),
        "y_ticks": _grid(_HALF_D, [387.59, 366.39, 344.96, 322.83, 301.21, 279.65, 257.81, 235.73, 214.57]),
        "y_fit": [0.0, 4.0],
        "curves": _KODAK_RGB,
        "kind": "negative",
    },
]


# Foma datasheets: "log rel. exposure", densitometry not stated. Gridlines every 1.0 inside an
# unlabelled frame. On the negative sheets the 1.0 density gridline leans by about 0.4 pt, so the
# density axis is fitted to 0 and 2 only (the residual shows where the leaning line is). The frame
# is drawn as thin filled rectangles, each counted once, at its centre. Each curve is a
# filled outline in several pieces.
def _foma(cid, pdf, frame, x_ticks, y_ticks, pieces, kind="negative"):
    return {
        "id": cid,
        "pdf": pdf,
        "page": 1,
        "frame": frame,
        "x_ticks": x_ticks,
        "y_ticks": y_ticks,
        "max_tilt": 0.5,
        "thin_rects": 1.0,
        "y_fit": [0.0, 2.0],
        "curves": {"bw": {"outline": pieces}},
        "kind": kind,
    }


VECTOR += [
    # Fomapan 100, 200 and 400: Microphen stock, 20 C, the middle of the three curves (7, 6 and 9
    # min). All three sheets print the same drawing.
    _foma("foma_fomapan_100", "fomapan_100.pdf", (333.89, 384.27, 505.88, 545.63),
          [(-3.0, 344.63), (-2.0, 398.41), (-1.0, 452.15)], [(0.0, 545.63), (1.0, 491.62), (2.0, 438.79)],
          [f"194.{k}" for k in range(7)]),
    _foma("foma_fomapan_200", "fomapan_200.pdf", (325.00, 272.84, 495.56, 432.90),
          [(-3.0, 335.64), (-2.0, 388.99), (-1.0, 442.28)], [(0.0, 432.90), (1.0, 379.32), (2.0, 326.92)],
          [f"167.{k}" for k in range(7)]),
    _foma("foma_fomapan_400", "fomapan_400.pdf", (333.68, 381.18, 505.64, 542.02),
          [(-3.0, 344.43), (-2.0, 398.19), (-1.0, 451.92)], [(0.0, 542.02), (1.0, 488.18), (2.0, 435.53)],
          [f"158.{k}" for k in range(7)]),
    # Fomapan R 100: process R-100.
    _foma("foma_fomapan_r_100", "fomapan_r_100.pdf", (330.41, 367.73, 504.47, 531.16),
          [(0.0, 340.85), (1.0, 395.53), (2.0, 450.20)], [(0.0, 531.16), (1.0, 476.81), (2.0, 422.46)],
          ["290.0", "290.1", "290.2"], kind="positive"),
]

VECTOR += [
    # Tri-X 320 (320TXP, sheets), F-4017 (October 2021): HC-110 Dilution B, large tank, 20 C, 4,
    # 6, 9 and 14 min. None is at a table time; the table's large-tank starting point for HC-110
    # (B) is 4 1/4 min, and the 4 min curve (solid) is the closest. The log H labels lost their
    # minus signs.
    _kodak("kodak_tri_x_320", "f4017_trix_320400.pdf", 9, (364.92, 338.99, 549.35, 523.49), _KODAK_4_TO_1, curves={"bw": {"dash": ()}}),
    # Neopan 400 Presto, 163AR0120A (Japanese): D-76, 20 C, small tank, 7 1/2, 8 3/4 and 12 min.
    # The 7 1/2 min curve (the lowest; printed G-bar 0.54) is the table's time for EI 400; 8 3/4
    # min (G-bar 0.65) is its time for EI 800. Labels drawn as outlines; gridlines every 0.5 on
    # both axes, log H -3.5 to 1.5 and density 0 to 3.0. The curves end together at the left edge.
    {
        "id": "fujifilm_neopan_400_presto",
        "pdf": "neopan_400_presto_jp.pdf",
        "page": 4,
        "frame": (88.02, 269.07, 265.81, 375.76),
        "x_ticks": _even([-3.5, -3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5], 88.02, 265.81),
        "y_ticks": _even([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0], 375.76, 269.07),
        "curves": {"bw": {"rank": 2, "at": "right"}},
        "kind": "negative",
    },
]

# Filmotec ORWO black-and-white datasheets (Word documents with an Excel chart): "log H rel",
# ORWO instruction 1182 (D-96), densitometry not stated. Gridlines every 0.3 log H and 0.5 D. The
# curve is drawn as 14 smoothed pieces, one per 0.3 log H, whose ends sit 0.33 pt (0.007 log H)
# left of the gridlines they belong on.
_ORWO_LOG_H = [round(0.3 * k, 1) for k in range(15)]
_ORWO_D = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0]
VECTOR += [
    {
        "id": "orwo_un54",
        "pdf": "orwo_un54.pdf",
        "page": 2,
        "frame": (345.60, 252.24, 534.81, 376.60),
        "x_ticks": _even(_ORWO_LOG_H, 345.60, 534.81),
        "y_ticks": _even(_ORWO_D, 376.60, 252.24),
        "curves": {"bw": {"pieces": [f"{k}.0" for k in range(49, 63)]}},
        "kind": "negative",
    },
    {
        "id": "orwo_n74_plus",
        "pdf": "orwo_n74_plus.pdf",
        "page": 2,
        "frame": (336.47, 318.30, 525.56, 449.36),
        "x_ticks": _even(_ORWO_LOG_H, 336.47, 525.56),
        "y_ticks": _even(_ORWO_D, 449.36, 318.30),
        "curves": {"bw": {"pieces": [f"{k}.0" for k in range(49, 63)]}},
        "kind": "negative",
    },
]

RASTER = [
    # Fujicolor C200, AF3-0249E (May 2017): Status M, CN-16, daylight 1/125 s. Black curves,
    # blue above green above red; the chart image is 600 ppi.
    {
        "id": "fujifilm_c200",
        "pdf": "c200_eu.pdf",
        "page": 6,
        "dpi": 600,
        "dpi2": 300,
        "frame": (82.98, 117.90, 278.10, 290.34),
        "x_ticks": _grid([-4.0, -3.5, -3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5],
                         [82.98, 104.58, 126.54, 148.50, 169.74, 191.70, 212.94, 234.90, 256.50, 278.10]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
                         [290.34, 269.46, 247.86, 225.90, 204.30, 182.70, 160.74, 138.78, 117.90]),
        "x_gridlines": True,
        "y_gridlines": True,
        "exclude": [(88, 120, 215, 152)],
        "order": ["b", "g", "r"],
        "curves": {"b": {}, "g": {}, "r": {}},
        "seed_x": 117.0,
        "kind": "negative",
    },
]

RASTER += [
    # Provia 100F, AF3-036E (October 2000): Fuji FAD-30S densitometer (Status A), E-6, daylight 1/50 s.
    # Coloured curves on a grey ground, 300 ppi. Green and blue are drawn under red, so where
    # they coincide with it only red shows; there they take the red reading.
    {
        "id": "fujifilm_provia_100f",
        "pdf": "provia100f_us_AF3-036E.pdf",
        "page": 6,
        "dpi": 600,
        "dpi2": 300,
        "frame": (83.40, 171.72, 285.24, 350.28),
        "x_ticks": _grid([-3.5, -3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0],
                         [83.40, 105.72, 128.04, 150.36, 172.92, 195.24, 218.04, 240.60, 262.92, 285.24]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
                         [350.28, 328.20, 305.64, 283.56, 261.00, 238.92, 216.36, 194.28, 171.72]),
        "exclude": [(85, 304, 150, 332)],
        "order": ["r", "g", "b"],
        "curves": {"r": {"colour": (0.9, 0.2, 0.2), "tol": 0.4}, "g": {"colour": (0.0, 0.65, 0.3), "tol": 0.4}, "b": {"colour": (0.2, 0.25, 0.6), "tol": 0.35}},
        "hidden_under": {"g": "r", "b": "r"},
        "max_gap_pt": 12.0,
        "seed_x": 100.0,
        "kind": "positive",
    },
]

RASTER += [
    # Velvia 50, AF3-0221E2 (March 2007): Status A, E-6/CR-56, daylight. Black curves, R solid,
    # G long dashes, B short dashes, 600 ppi. They are separate in the shoulder. From log H -1.6
    # on they run together, crossing and overlapping within about a line width, and cannot be
    # told apart; there all three take the centre of the band the lines form.
    {
        "id": "fujichrome_velvia_50",
        "pdf": "velvia50_us_AF3-0221E2.pdf",
        "page": 8,
        "dpi": 600,
        "dpi2": 300,
        "frame": (86.76, 109.32, 285.00, 286.20),
        "x_ticks": _grid([-3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5],
                         [86.76, 108.60, 130.92, 152.52, 175.08, 196.92, 219.24, 241.32, 263.16, 285.00]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
                         [286.20, 264.12, 242.04, 219.72, 197.64, 175.32, 153.48, 131.64, 109.32]),
        "x_gridlines": True,
        "y_gridlines": True,
        "exclude": [(88, 243, 114, 264), (180, 112, 284, 140)],
        "order": ["g", "b", "r"],
        "curves": {"g": {}, "b": {}, "r": {}},
        "seed_x": 95.0,
        "union_from_x": 148.5,
        "union_halfwidth_pt": 3.5,
        "kind": "positive",
    },
]

RASTER += [
    # Superia 200, AF3-026E (October 1998): Status M, CN-16, daylight 1/125 s. Black curves, blue above
    # green above red; the chart image is 600 ppi.
    {
        "id": "fujifilm_superia_200",
        "pdf": "superia200_ca_AF3-026E.pdf",
        "page": 4,
        "dpi": 600,
        "dpi2": 300,
        "frame": (66.84, 236.04, 272.52, 381.48),
        "x_ticks": _grid([-4.0, -3.5, -3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0],
                         [66.84, 86.76, 107.64, 128.52, 148.92, 169.08, 189.72, 210.36, 231.24, 252.12, 272.52]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5],
                         [381.48, 360.36, 340.0, 319.32, 298.68, 278.28, 257.16, 236.04]),
        "open_pt": 0.45,
        "exclude": [(68, 238, 204, 266)],
        "order": ["b", "g", "r"],
        "curves": {"b": {}, "g": {}, "r": {}},
        "seed_x": 84.0,
        "max_gap_pt": 8.0,
        # the blue curve ends on the 3.0 gridline at log H +0.34; past that the trace would
        # follow the gridline
        "channel_x_limits": {"b": (-9.0, 0.34)},
        "kind": "negative",
    },
]

RASTER += [
    # Neopan 100 Acros II, AF3-0258E (February 2020): Microfine, 20 C, small tank, 5/10/15/20 min.
    # The 10 min curve is the development table's time for EI 100 at 20 C. Densitometry is not
    # stated. The four curves run together in the toe; there they share one reading.
    {
        "id": "fujifilm_acros_100_ii",
        "pdf": "acros2_135_ca_AF3-0258E.pdf",
        "page": 3,
        "dpi": 600,
        "dpi2": 300,
        "frame": (68.52, 332.76, 250.20, 441.72),
        "x_ticks": _grid([-4.0, -3.5, -3.0, -2.5, -2.0, -1.5, -1.0, -0.5, 0.0, 0.5, 1.0],
                         [68.52, 86.76, 104.76, 123.00, 141.24, 159.24, 177.48, 195.72, 213.72, 231.96, 250.20]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0], [441.72, 423.72, 405.48, 387.48, 369.24, 351.00, 332.76]),
        "open_pt": 0.6,
        "order": ["t20", "t15", "bw", "t5"],
        "keep": ["bw"],
        "curves": {"t20": {}, "t15": {}, "bw": {}, "t5": {}},
        "seed_x": 200.0,
        "merged_thickness_pt": 4.0,
        "kind": "negative",
    },
]

# Ilford and HARMAN charts that are raster images in every edition found.
_HALF9 = [0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 4.5]
RASTER += [
    # Delta 100 Professional, April 2023: rollfilm, ID-11 stock, 8.5 min, 20 C (the development
    # table's time for EI 100). The chart is a 168 ppi JPEG, gridlines every 0.5.
    {
        "id": "ilford_delta_100",
        "pdf": "ilford_delta_100.pdf",
        "page": 4,
        "dpi": 600,
        "dpi2": 300,
        "frame": (58.23, 689.85, 242.73, 811.17),
        "x_ticks": _grid(_HALF9, [58.23, 77.67, 98.73, 119.07, 139.77, 160.11, 180.99, 201.33, 222.03, 242.73]),
        "y_ticks": _grid(_DENS, [811.17, 790.65, 771.21, 750.51, 730.17, 709.65, 689.85]),
        "open_pt": 1.1,
        # the 0.5 and 2.5 gridlines are drawn heavier than the rest; blank them out
        "blank_y_lines": [790.95, 709.98],
        "max_thickness_pt": 4.0,
        "max_jump_pt": 3.0,
        "order": ["bw"],
        "curves": {"bw": {}},
        "seed_x": 190.0,
        "kind": "negative",
    },
]

RASTER += [
    # SFX 200, November 2018: ID-11 stock, 10 min, 20 C. The chart is a 185 ppi image.
    {
        "id": "ilford_sfx_200",
        "pdf": "ilford_sfx_200.pdf",
        "page": 2,
        "dpi": 600,
        "dpi2": 300,
        "frame": (56.97, 624.87, 224.55, 735.03),
        "x_ticks": _grid(_HALF9, [56.97, 74.43, 93.51, 112.41, 131.13, 149.49, 168.57, 186.93, 205.83, 224.55]),
        "y_ticks": _grid(_DENS, [735.03, 716.49, 698.49, 679.77, 661.41, 642.87, 624.87]),
        "open_pt": 0.6,
        "order": ["bw"],
        "curves": {"bw": {}},
        "seed_x": 150.0,
        "max_thickness_pt": 4.0,
        "max_jump_pt": 3.0,
        "kind": "negative",
    },
]

RASTER += [
    # HARMAN Phoenix 200, September 2024: "standard C41 type chemicals"; the densitometry is not
    # stated. Black curves on grey gridlines (216 ppi image); labels at the right-hand end: green
    # above blue above red. Blue and red are drawn over each other up to relative log H 0.9; there
    # they share one reading.
    {
        "id": "harman_phoenix_200",
        "pdf": "harman_phoenix_200.pdf",
        "page": 3,
        "dpi": 600,
        "dpi2": 300,
        "frame": (65.2, 93.87, 288.27, 232.7),
        "x_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0], [65.2, 101.97, 139.59, 176.31, 213.93, 250.65, 288.27]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
                         [232.7, 215.37, 197.91, 180.45, 163.17, 146.07, 128.43, 111.15, 93.87]),
        "threshold": 0.7,
        "order": ["g", "b", "r"],
        "curves": {"g": {}, "b": {}, "r": {}},
        "seed_x": 191.6,
        "merged_thickness_pt": 3.0,
        "kind": "negative",
    },
]


# Cross-checks, not used in stocks.zig: raster charts of editions whose curves were also read
# from a vector drawing. checks.py compares each with that reading.
def _vision3_2026(cid, pdf, x0, y0, x1, y1, against):
    third = (y1 - y0) / 3
    return {
        "id": cid,
        "check_against": against,
        "pdf": pdf,
        "page": 3,
        "dpi": 600,
        "dpi2": 300,
        "frame": (x0, y0, x1, y1),
        # the frame spans -8 to +8 camera stops, as in the 2015 edition
        "x_ticks": [(-8 * STOP, x0), (8 * STOP, x1)],
        "y_ticks": [(0.0, y1), (1.0, y1 - third), (2.0, y1 - 2 * third), (3.0, y0)],
        "y_band": (x0 + 0.9, x0 + 3.5),
        "exclude": [(x0 + 2, y0 + 2, x0 + 95, y0 + 40)],
        "order": ["b", "g", "r"],
        "curves": {"b": {}, "g": {}, "r": {}},
        "seed_x": x0 + 0.5 * (x1 - x0),
        "kind": "negative",
    }


RASTER += [
    _vision3_2026("check_vision3_50d_2026", "kc_VISION3-50D-5203-7203-technical-information.pdf", 383.40, 527.64, 549.96, 693.72, "kodak_vision3_50d"),
    _vision3_2026("check_vision3_250d_2026", "kc_VISION3-250D-5207-7207-technical-information.pdf", 377.88, 533.88, 550.20, 706.44, "kodak_vision3_250d"),
    _vision3_2026("check_vision3_200t_2026", "kc_VISION3-200T-5213-7213-technical-information.pdf", 381.24, 528.12, 549.00, 695.40, "kodak_vision3_200t"),
    _vision3_2026("check_vision3_500t_2026", "kc_VISION3-5219-7219-technical-information.pdf", 375.96, 531.24, 554.04, 709.56, "kodak_vision3_500t"),
]

RASTER += [
    # HP5 Plus, November 2018 edition (raster) of the April 2010 vector chart.
    {
        "id": "check_hp5_plus_2018",
        "check_against": "ilford_hp5_plus",
        "pdf": "ilford_hp5_plus.pdf",
        "page": 5,
        "dpi": 600,
        "dpi2": 300,
        "frame": (57.51, 85.95, 229.59, 200.43),
        "x_ticks": _grid(_HALF9, [57.51, 76.23, 95.49, 114.93, 134.37, 153.09, 172.53, 191.25, 211.23, 229.59]),
        "y_ticks": _grid(_DENS, [200.43, 181.71, 162.09, 143.37, 124.65, 105.57, 85.95]),
        "open_pt": 0.6,
        "order": ["bw"],
        "curves": {"bw": {}},
        "seed_x": 150.0,
        "max_thickness_pt": 4.0,
        "max_jump_pt": 3.0,
        "kind": "negative",
    },
]

RASTER += [
    # Ortho Plus, October 2019: "Pictorial contrast", ID-11 stock, 8 and 10 min, 20 C; the 8 min
    # curve is the lower one, labelled G-bar 0.62 (the entry's stated contrast). Black curves on
    # grey gridlines (199 ppi image); the two run together in the toe and share one reading there.
    {
        "id": "ilford_ortho_plus",
        "pdf": "ilford_ortho_plus.pdf",
        "page": 3,
        "dpi": 600,
        "dpi2": 300,
        "frame": (94.95, 383.13, 248.13, 491.6),
        "x_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0], [94.95, 114.21, 133.29, 152.37, 171.27, 190.89, 209.43, 229.05, 248.13]),
        # the toe runs just above the grey 0.0 line, so that line is left out of the calibration;
        # grey lines are lighter than the threshold, so the plot area can reach the frame
        "y_ticks": _grid([0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5], [476.19, 460.53, 445.05, 429.5, 413.91, 398.25, 383.13]),
        "threshold": 0.7,
        "inset": 0.3,
        "exclude": [(224, 451.5, 247.5, 460)],
        "order": ["t10", "bw"],
        "keep": ["bw"],
        "curves": {"t10": {}, "bw": {}},
        "seed_x": 198.4,
        "merged_thickness_pt": 3.0,
        "kind": "negative",
    },
]

RASTER += [
    # HARMAN Phoenix 125 (August 2026 sheet), a check only: its chart is the Phoenix 200 chart
    # again (the readings agree within 0.003 D), so it says nothing of its own about Phoenix 125.
    # Set up like Phoenix 200, with the frame about 1 pt higher on the page.
    {
        "id": "check_phoenix_125",
        "check_against": "harman_phoenix_200",
        "pdf": "harman_phoenix_125.pdf",
        "page": 3,
        "dpi": 600,
        "dpi2": 300,
        "frame": (65.2, 92.88, 288.30, 231.44),
        "x_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0], [65.2, 101.94, 139.44, 176.34, 213.66, 250.62, 288.30]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0],
                         [231.44, 214.14, 196.74, 179.34, 162.06, 145.02, 127.26, 110.10, 92.88]),
        "threshold": 0.7,
        "order": ["g", "b", "r"],
        "curves": {"g": {}, "b": {}, "r": {}},
        "seed_x": 191.6,
        "merged_thickness_pt": 3.0,
        "kind": "negative",
    },
    # ORWO N 75 (Filmotec, February 2020): ORWO instruction 1182 (D-96), "log H rel", the chart
    # an image (200 ppi). Gridlines every 0.3 log H and 0.5 D.
    {
        "id": "orwo_n75",
        "pdf": "orwo_n75.pdf",
        "page": 2,
        "dpi": 600,
        "dpi2": 300,
        "frame": (375.42, 301.86, 528.80, 421.02),
        "x_ticks": _grid([round(0.3 * k, 1) for k in range(15)],
                         [375.42, 386.58, 397.50, 408.30, 419.46, 430.26, 441.06, 452.22, 463.02, 474.18, 484.98, 495.90, 506.94, 517.86, 528.80]),
        "y_ticks": _grid([0.0, 0.5, 1.0, 1.5, 2.0, 2.5, 3.0], [421.02, 401.34, 381.42, 361.62, 341.82, 322.02, 301.86]),
        "open_pt": 0.6,
        "order": ["bw"],
        "curves": {"bw": {}},
        "seed_x": 470.0,
        "max_thickness_pt": 4.0,
        "max_jump_pt": 3.0,
        "kind": "negative",
    },
    # Lucky New SHD100 (scanned sheet, 200 ppi): LK HB-17 or D-76, 5, 7, 9 and 11 min; 5 min (the
    # lowest) is the processing paragraph's time. Visual diffuse density. The log H labels lost
    # their minus signs (exposure grows to the right, so they read -2.0 and -1.0; the next
    # gridline, labelled "lgH", is then 0.0). Density is labelled 1.0 and 2.0 only.
    {
        "id": "lucky_shd100",
        "pdf": "lucky_shd100.pdf",
        "page": 1,
        "dpi": 600,
        "dpi2": 300,
        "frame": (173.04, 673.50, 278.52, 748.62),
        "x_ticks": _grid([-2.0, -1.0, 0.0], [195.84, 228.90, 261.84]),
        "y_ticks": _grid([0.0, 1.0, 2.0], [748.62, 717.54, 686.10]),
        # fitted to the labelled lines only; the frame (density 0) and the "lgH" line (0.0)
        # show how well the inferred values agree
        "x_fit": [-2.0, -1.0],
        "y_fit": [1.0, 2.0],
        "open_pt": 0.85,
        "exclude": [(205, 676, 253, 685)],
        "order": ["t11", "t9", "t7", "bw"],
        "keep": ["bw"],
        "curves": {"t11": {}, "t9": {}, "t7": {}, "bw": {}},
        "seed_x": 255.0,
        "merged_thickness_pt": 4.0,
        "kind": "negative",
    },
]
