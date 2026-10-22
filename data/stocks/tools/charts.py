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
