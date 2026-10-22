# Film stock presets: where the numbers come from

`src/presets/stocks.zig` has one entry per film stock. Each entry holds a few numbers per colour
channel (the film's minimum density, its contrast and its density range) and, when the maker
publishes them, the film's characteristic curves. This file explains where each number comes from,
how we got it, and how to redo the work.

One rule runs through all of it: a number only goes in the table if a published source states it,
or if we read it off a published curve with the method below. When we read it off a curve, we
record how accurate the reading is. We never eyeball a value off a plot. If no source supports a
value, it's `null`, and the entry's `source` string says why.

## A quick primer

If you haven't worked with film datasheets before, here's the vocabulary used below.

- **Density** is how dark the film is: log10 of how much light it blocks. Density 1 lets a tenth
  of the light through, density 2 a hundredth.
- **Status M** and **Status A** are standard ways to measure colour density, each with its own set
  of red, green and blue filters. Makers use Status M for negatives and Status A for slides.
  Black-and-white datasheets often use **diffuse visual density** instead, which measures the
  silver the way the eye sees it.
- **Log exposure** (log H) is log10 of how much light reached the film, in lux-seconds. One stop
  is 0.30103 log H (log10 of 2).
- A **characteristic curve** plots density against log exposure. Colour datasheets print one curve
  per layer: red, green and blue.
- On a negative, the curve starts flat at the film's minimum density, bends upwards through the
  **toe**, then runs in a fairly **straight line**. On some films it flattens again at the top: the
  **shoulder**.
- **Base + fog** is the density of film that got no light at all: the film base itself, plus the
  little bit of fog that develops anyway. A slide runs the other way round, so its lowest density
  (**D-min**) is at the most-exposed end, and its highest (**D-max**) at the least-exposed end.
- **Gamma** is the slope of the straight part: how much density goes up per unit of log exposure.
  It's the film's contrast. Makers also quote related figures (contrast index, G-bar, beta), which
  we'll get to below.

## What the values mean

**Densities.** Colour negatives use Status M and colour slides use Status A, as printed on the
makers' curves. Two charts don't say how density was measured: HARMAN Phoenix 200 (a colour
negative) and Fujifilm Acros 100 II. For black-and-white, Kodak's curves are diffuse visual
density. Ilford, Foma, Rollei and ADOX don't say how they measured, and Kodak measures Double-X
gamma with Status M blue. Each entry's `source` says which of these applies. Black-and-white
entries repeat the same value for R, G and B.

**Log exposure.** The curves keep the maker's own exposure axis, log10 of lux-seconds, with these
exceptions:

- Kodak Vision3 and CineStill 800T: log H relative to normal exposure, taken from the chart's
  camera-stop axis at 0.30103 log H per stop. Here's why. The July 2015 charts have two exposure
  scales. The bottom one is in camera stops, -8 to +8, with an evenly spaced tick every stop, and
  it spans the frame exactly. The top one is in lux-seconds, but it only has a few labels, and they
  don't agree with the stop scale or with each other: across the frame, 50D spans 5.04 log H, 500T
  5.0, and 250D and 200T 4.8. On 500T the ticks in between are also uneven by up to 0.06 log H.
  Sixteen stops should be 4.82 log H, so we went with the stop scale.
- Fomapan 100, 200, 400 and R: Foma labels its axis "log relative exposure".
- Ilford and HARMAN: "relative log exposure".

**`base_density`** (base + fog for negatives, D-min for slides). This is the density at the
least-exposed end of the published curve: the low-exposure end on a negative, the high-exposure
end on a slide.

The catch is that datasheet curves often stop before the toe has flattened out, and then the end
of the curve sits above the real minimum. So we only accept the value if the curve has flattened
out: over the last 0.3 log H at that end, the average slope has to be below 0.1 density per log H.
That's about a sixth of a negative's gamma, which puts the end density within roughly 0.03 of the
real minimum. If any channel fails the test, `base_density` is null for that stock. That happens
for:

- Fujifilm 400: the blue curve is still rising at 0.12 per log H where it starts.
- Fujifilm Superia 200: the green curve is still rising at 0.105 per log H where it starts.
- Ektachrome E100: D-min is still falling at the right-hand end.
- Kodachrome 64: neither end is flat.
- All three Fomapan negatives and Fomapan R.

On Kodak Gold 200, the blue curve dips by 0.03 just after it starts, then rises. We use the start
value (0.991) as its base, since that's the density of unexposed film.

**`gamma`** is the slope of the straight part of the curve, in density per log H. It's positive
for slides too, even though their density falls as exposure goes up. For stocks with curves, we
work it out from our reading like this:

1. Resample the curve every 0.02 log H, interpolating linearly.
2. Find the steepest local slope, using a least-squares fit over ±0.2 log H around each point.
3. Find the longest stretch of log H over which the curve stays within 0.05 log H (1/6 stop) of a
   straight least-squares line. We measure how far it strays along the exposure axis: the density
   error divided by the slope. The line's slope has to be at least half the steepest local slope,
   which keeps the flat toe and shoulder out.
4. Gamma is that line's slope.

For negatives, that stretch is 1.1 to 3.3 log H wide, about 4 to 11 stops. Phoenix 200 has short,
steep curves and gives the narrowest. There, 0.05 log H works out to 0.03 to 0.06 density. For
slides the stretch is 1.0 to 1.5 log H. Measuring along log H matters for slides: their curves are
three to four times steeper, and this way they get a tolerance on the same footing as negatives.
`tools/derive.py` does all this. Run on the vector-read Kodak and Fujifilm curves, it reproduces
their stored gammas to within 0.007.

For stocks without curves, `gamma` is the figure the maker states, and `source` says which kind of
figure it is:

- Kodak and Foma give gamma.
- Ilford gives G-bar, an average slope.
- ADOX gives beta, a mean slope.
- Rollei gives an "average contrast γ".

These aren't quite the same thing. An average slope takes in part of the toe, so it usually comes
out a few hundredths lower than the straight-line slope. For example, Kodak states a contrast
index of 0.56 for Tri-X's starting-point development, while the slope we get from its curve is
0.583.

**`density_range`**:

- For negatives: the density at the most-exposed end of the published curve, minus
  `base_density`. That's how far the maker's curve goes, not the film's maximum density. Kodak's
  still-film curves stop about 6 stops above normal exposure, Vision3 and Verita curves run to +8
  stops, and the T-Max P3200 curve runs off the top of the chart at density 3.0.
- For slides: D-max minus D-min. Both ends have to pass the flattened-out test above.
- If `base_density` is null, so is `density_range`.

**`curves`** have 28 to 41 points per channel, and never go past what the maker draws.

- We sample them every 0.1 log H, at multiples of 0.1, across the drawn range.
- If that would give more than 41 points (the most the tests in `stocks.zig` allow), the step goes
  up to 0.15 log H (half a stop), at multiples of 0.15. That's the case for Vision3, Verita, HP5
  Plus, Pan F Plus, XP2 Super, Delta 3200, SFX 200, Pro 400H, Provia 100F and Velvia 100, whose
  curves span more than 4.0 log H.
- Curves traced from images are only smoothed at the grid points: each stored value comes from a
  least-squares line through the traced samples within ±0.025 log H of that point.

## How the curves were read

### 1. Vector drawings (exact)

A lot of datasheets draw their curves as vector paths rather than images. That means we can read
them exactly:

- We replay the page's drawing commands with pypdf, applying all the coordinate transforms
  (`tools/pdfvec.py`).
- We map each axis to data units using the labelled ticks or gridlines drawn in the PDF. The label
  positions come from `pdftotext -bbox`, or from the rendered page when the labels are drawn as
  outlines (Fujifilm does this).
- The mapping is a least-squares line through all the ticks, and we record how far off each tick
  is (its residual).
- We evaluate each curve's path along its whole length, whether it's made of line segments or
  cubic Béziers.
- We tell R, G and B apart by the channel labels printed at one end of the curves, matched to the
  order the curves are stacked in at that end, or by the line style the legend gives (Velvia 100:
  R solid, G dash-dot, B dashed). Each curve is its own path, so curves that cross later on (as
  Kodachrome's do near D-min) keep the right channel.
- Foma and Kodak sometimes draw curves as filled outlines. There we take the centre of the
  outline.

Tick residuals are below 0.001, except for these:

- Portra 160: the density ticks are drawn unevenly spaced, so ±0.02 D.
- Superia X-TRA 400 and Fujicolor 100: the gridlines are slightly uneven, so ±0.015 D.
- Pro 160NS: the frame is drawn off the inner grid, so ±0.017 D.
- Fomapan 100, 200 and 400: the 1.0 density gridline is drawn slightly tilted, so ±0.015 D.
- Vision3 50D: the top of the frame, labelled 3.0, is drawn 0.03 D too low. We left it out of the
  fit; the 0, 1.0 and 2.0 ticks agree to 0.0015 D.
- Ilford 2010 editions (HP5 Plus, FP4 Plus, Pan F Plus, XP2 Super, Delta 3200): the gridlines every
  0.5 are uneven by up to 0.011 D and 0.013 log H.
- Fujifilm Pro 400H: up to 0.013 log H and 0.006 D. Velvia 100: up to 0.008 log H and 0.008 D.

We drew every reading back onto a render of its page (`tools/overlay.py`), and the points sit on
the printed lines. For Superia X-TRA 400, the Japanese and English sheets give the same curves to
within 0.0001 D.

### 2. Chart images (traced)

When every edition we could find prints the chart as an image, we traced the curves from renders
of the page (`tools/read_raster.py`). For each chart:

1. Render the page with pdftoppm at 600 dpi. (The chart images themselves are 168 to 600 ppi.)
2. Calibrate each axis. For every labelled tick, gridline or frame edge, look for the dark line
   near where it should be, and take the line's darkness-weighted centre, which gets it to a
   fraction of a pixel. Fit a straight line through the ticks by least squares and record each
   tick's residual.
3. Make an "ink" image of the plot area: darkness for black curves, or closeness to the curve's
   colour for coloured ones (Provia 100F draws red, green and blue curves). Remove the gridlines,
   either with a binary opening that keeps only ink thicker than a gridline, or by interpolating
   across the gridlines found in step 2. Blank out text boxes and legends.
4. Trace each curve column by column. Start at a column where the curves are clearly apart, and
   assign them top to bottom (or by colour). Then follow each curve outwards: in the next column,
   take the run of ink closest to where the last few samples are heading, and use its ink-weighted
   centre. A label touching a curve makes the run thicker, and we skip those. The trace stops where
   the curve does.
5. Where a chart draws curves on top of each other, they share one reading there (see the table).
6. Drop outliers by comparing with a running median, map the pixel centres to (log H, density), and
   resample onto the grid.

We read each chart twice, at 600 and at 300 dpi, and compared the two. The table gives the worst
axis residual, and the largest and mean density difference between the two reads.

| Stock | Chart image | Axis residual (log H / D) | 600 vs 300 dpi, max / mean D | Notes |
|---|---|---|---|---|
| Fujicolor C200 | 600 ppi | 0.009 / 0.009 | 0.010 / 0.001 | |
| Superia 200 | 600 ppi, scanned | 0.010 / 0.012 | 0.002 / 0.002 | The blue trace stops at log H +0.34, where the curve ends on the 3.0 gridline. |
| Provia 100F | 300 ppi, one layer per colour | 0.006 / 0.004 | 0.062 / 0.004 | Green and blue are drawn under red. Where they coincide with it (from about log H -2.1 for blue and -1.5 for green), only red shows, so they take its reading. The largest difference is on the steep part, where green is partly covered by red: 0.06 D there is 0.03 log H. |
| Velvia 50 | 600 ppi | 0.006 / 0.006 | 0.064 / 0.002 | R is solid, G and B are dashed. They're separate in the shoulder. From log H -1.6 on they run together, crossing and overlapping within about a line width, and you can't tell them apart; there all three take the centre of the band the lines make. The largest difference is where that starts. |
| Acros 100 II | 300 ppi | 0.002 / 0.002 | 0.039 / 0.001 | The 5, 10, 15 and 20 min curves run together in the toe and share a reading there. |
| Delta 100 | 168 ppi JPEG | 0.016 / 0.005 | 0.008 / 0.001 | The 0.5 and 2.5 gridlines are drawn heavier, so they're blanked out. |
| SFX 200 | 185 ppi | 0.014 / 0.003 | 0.002 / 0.001 | |
| Ortho Plus | 199 ppi | 0.003 / 0.006 | 0.010 / 0.002 | The 8 and 10 min curves share a reading in the toe. The 0.0 gridline is hidden by the toe, so we left it out of the fit. |
| Phoenix 200 | 216 ppi | 0.002 / 0.001 | 0.002 / 0.001 | Blue and red are drawn on top of each other up to relative log H 0.9 and share a reading there. |

We also checked the method against exact readings of the same curves. Kodak's March 2026 Vision3
sheets reprint the July 2015 charts as 225 ppi images, and the November 2018 HP5 Plus sheet prints
the April 2010 vector chart as an image. Traced the same way, they agree with the vector readings:

| Image | Vector reading | Max / mean difference, D |
|---|---|---|
| Vision3 50D, March 2026 | July 2015 | 0.018 / 0.007 |
| Vision3 250D, March 2026 | July 2015 | 0.002 / 0.001 |
| Vision3 200T, March 2026 | July 2015 | 0.004 / 0.002 |
| Vision3 500T, March 2026 | July 2015 | 0.002 / 0.001 |
| HP5 Plus, November 2018 | April 2010 | 0.007 / 0.001 |

The 2026 images are mapped with the frame spanning ±8 stops, same as in 2015. Gammas from the image
readings match the vector ones to within 0.005.

### 3. Checks against numbers the datasheets state

The datasheets state very few numbers in their text. Where they do, `tools/checks.py` compares our
readings with them.

- **Grey-card density.** Kodak E-4L says a correctly exposed grey card reads 1.03 to 1.23 red
  density on Pro Image 100, and Fujifilm AF3-026E says 0.97 to 1.16 on Superia 200. At box speed,
  an 18 % grey card gets an exposure of H = 8.1 / S lux-seconds (meter constant 12.5, lens factor
  0.65). At that exposure our readings give 1.017 for Pro Image 100, which is 0.013 below Kodak's
  range, and 1.050 for Superia 200, which is inside Fujifilm's.
- **Ilford's contrast aim.** Ilford's developer leaflets say the times in their tables aim at
  G-bar 0.62. Measured from the point 0.1 above base + fog over the next 1.5 log H, our readings
  give 0.594 (HP5 Plus), 0.670 (FP4 Plus), 0.708 (Pan F Plus), 0.653 (Delta 100), 0.636
  (SFX 200), and 0.655 for Delta 3200 at its EI 3200 time. The Ortho Plus curve that the chart
  itself labels G-bar 0.62 gives 0.584. Ilford doesn't define G-bar in these sheets, so this is a
  rough check of the scale, not of the third decimal.
- **Speed placement.** On the charts in lux-seconds, the ISO 5800 speed point (0.15 above minimum
  density, S = √2 / H_M) comes out 1.2 to 1.3 stops faster than box speed for Pro Image 100, C200
  and Superia 200, and 0.95 stop slower for Pro 400H. This ignores ISO 5800's contrast
  conditions, so it tells you where the charts put the curves, not what the film's speed is. The
  Pro 400H chart sits about two stops to the right of the other three. We checked its axis labels
  on the render, and the entry keeps it as drawn.

Kodak's Vision3 sheets state no densities or contrast for the camera negative, and neither do the
Kodachrome, Velvia and Provia sheets.

## Documents used

The PDFs are the makers' copyright and aren't openly licensed, so we don't keep them here. The
numbers we read from them are our own measurements of published data.

| Stock | Document | Read from | URL |
|---|---|---|---|
| Portra 160 | Kodak E-4051, January 2025 | vector | https://www.kodakprofessional.com/sites/default/files/2025-07/e4051.pdf |
| Portra 400 | Kodak E-4050, January 2025 | vector | https://www.kodakprofessional.com/sites/default/files/2025-07/e4050.pdf |
| Portra 800, push 1, push 2 | Kodak E-4040, January 2025 | vector | https://www.kodakprofessional.com/sites/default/files/2025-07/e4040.pdf |
| Ektar 100 | Kodak E-4046, January 2025 | vector | https://www.kodakprofessional.com/sites/default/files/2025-07/e4046.pdf |
| Gold 200 | Kodak E-7022, June 2023 | vector | https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/E7022%20Gold%20tech%20sheet.pdf |
| UltraMax 400 | Kodak E-7023, February 2016 | vector | https://www.kodakprofessional.com/sites/default/files/wysiwyg/KodakUltraMax400TechSheet-1.pdf |
| Pro Image 100 | Kodak E-4L, July 1997 | vector | https://web.archive.org/web/20160508203549id_/http://www.kodak.com:80/global/en/professional/support/techPubs/e4L/e4L.pdf |
| Vision3 50D 5203 | Kodak H-1-5203, July 2015 | vector | https://www.kodak.com/content/products-brochures/Film/VISION3-50D-Color-Negative-Film-7203-TECHNICAL-DATA.pdf |
| Vision3 250D 5207 | Kodak H-1-5207, July 2015 | vector | https://web.archive.org/web/20200326032933id_/https://www.kodak.com/uploadedFiles/Motion/Products/Camera_Films/5207/Resources/5207_ti2650.pdf |
| Vision3 200T 5213 | Kodak H-1-5213, July 2015 | vector | https://www.kodak.com/content/products-brochures/Film/VISION3-200T-Color-Negative-Film-7213-TECHNICAL-DATA.pdf |
| Vision3 500T 5219, CineStill 800T | Kodak H-1-5219, July 2015 | vector | https://www.kodak.com/content/products-brochures/Film/VISION3-500T-Color-Negative-Film-7219-TECHNICAL-DATA.pdf |
| (check only) Vision3, all four | Kodak H-1-52xx, March 2026 | image | kodak.com motion-picture product pages; the download URLs weren't recorded |
| Verita 200D 5206 | Kodak brochure K-1216 (April 2026); data sheet H-1-5206 | vector | https://www.kodak.com/content/pdfs/motion/KODAK-VERITA-200D-5206-7206-brochure.pdf |
| Ektachrome E100 | Kodak E-4000, August 2018 | vector | https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/e4000_ektachrome_100.pdf |
| Kodachrome 64 | Kodak E-88, June 2009 | vector | https://web.archive.org/web/20160909064512id_/http://www.kodak.com/global/en/consumer/products/pdf/e88.pdf |
| Tri-X 400 | Kodak F-4017, October 2021 | vector | https://www.kodakprofessional.com/sites/default/files/wysiwyg/film/f4017_trix_320400.pdf |
| T-Max 100 | Kodak F-4016, June 2018 | vector | https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4016_TMax_100.pdf |
| T-Max 400 | Kodak F-4043, February 2016 | vector | https://www.kodakprofessional.com/sites/default/files/wysiwyg/pro/resources/f4043_TMax_400.pdf |
| T-Max P3200 | Kodak Alaris F-4001, March 2018 | vector | https://web.archive.org/web/20180404002836id_/http://imaging.kodakalaris.com:80/sites/prod/files/files/products/F4001.pdf |
| Fujifilm 200 | Fujifilm AF3-0261E, 9 February 2022 | vector | https://asset.fujifilm.com/www/us/files/2022-02/f4606a5c43dacb389a1d9eb35e0b18db/fujifilm-200-speed-film_data-sheet.pdf |
| Fujifilm 400 | Fujifilm AF3-0262E, 1 April 2023 | vector | https://www.ishootfujifilm.com/uploads/SUPERIA%20400%20Data%20Sheet.pdf (Fujifilm North America; the file name says Superia, but the content is AF3-0262E) |
| Superia X-TRA 400 | Fujifilm 013AR0316A (Japanese), same curves as AF3-0217E | vector | https://asset.fujifilm.com/www/jp/files/2024-04/e3d01e65a65f6825eeb14c6bbd05e523/datasheet_superiax-tra400_01.pdf |
| Superia 200 | Fujifilm AF3-026E, October 1998 | image | https://asset.fujifilm.com/www/ca/files/2020-09/1b80436a2e0cefe4d8348f094c345795/AF3-026E.pdf |
| Fujicolor C200 | Fujifilm AF3-0249E, May 2017 | image | https://asset.fujifilm.com/www/uk/files/2019-09/cce1e1943550fc3e76c22411066f0100/films_c200_datasheet_01.pdf |
| Pro 400H | Fujifilm AF3-176E, January 2005 | vector | https://asset.fujifilm.com/www/uk/files/2019-09/d68b00b13f1b6234629342317be9cf2b/films_pro-400h_datasheet_01.pdf |
| Pro 160NS | Fujifilm 163AR109A (Japanese only) | vector | https://asset.fujifilm.com/www/jp/files/2024-04/6b75b1c1cb4253623fb2cd7a56ff7443/datasheet_pro160ns_01.pdf |
| Fujicolor 100 | Fujifilm 013AR0317A (Japanese only) | vector | https://asset.fujifilm.com/www/jp/files/2019-12/05b4b671ff6c0e53b8f7df233d57dfd7/datasheet_fujicolor100_01.pdf |
| Provia 100F | Fujifilm AF3-036E, October 2000 | image | https://asset.fujifilm.com/www/us/files/2020-03/dc6e1c21c643f82b7fb393cef94d524a/Provia100FAF3-036E.pdf |
| Velvia 100 | Fujifilm AF3-202E, February 2005 | vector | https://asset.fujifilm.com/www/us/files/2020-03/0a569e6e2a9921af89a81a75a526611c/AF3-202E.pdf |
| Velvia 50 | Fujifilm AF3-0221E2, March 2007 | image | https://asset.fujifilm.com/www/us/files/2020-03/742f83fe2440fce58fbcc08f7370a7e6/AF3-0221E2Velvia50PIB.pdf |
| Acros 100 II | Fujifilm AF3-0258E, February 2020 | image | https://asset.fujifilm.com/www/ca/files/2020-07/fb477bd9803b3c27ab592edcf9f3567c/AF3-0258E_PIB-NEOPAN-100-ACROSII-135-3_data-sheet.pdf |
| HP5 Plus | Ilford datasheet, April 2010 | vector | https://web.archive.org/web/20101124173605id_/http://ilfordphoto.com/Webfiles/20106281054152313.pdf |
| (check only) HP5 Plus | Ilford datasheet, November 2018 | image | ilfordphoto.com; the download URL wasn't recorded |
| FP4 Plus | Ilford datasheet, July 2010 | vector | https://web.archive.org/web/20100725011828id_/http://www.ilfordphoto.com:80/Webfiles/2010712125850702.pdf |
| Pan F Plus | Ilford datasheet, June 2010 | vector | https://web.archive.org/web/20131022050050id_/http://ilfordphoto.com/Webfiles/20114271111491224.pdf |
| Delta 3200 Professional | Ilford datasheet, May 2010 | vector | https://web.archive.org/web/20100821151625id_/http://www.ilfordphoto.com:80/Webfiles/201071394723115.pdf |
| XP2 Super | Ilford datasheet, June 2010 | vector | https://web.archive.org/web/20120907070033id_/http://www.ilfordphoto.com:80/Webfiles/201142711321939.pdf |
| Delta 100 Professional | Ilford datasheet, April 2023 | image | ilfordphoto.com; the download URL wasn't recorded |
| SFX 200 | Ilford datasheet, November 2018 | image | ilfordphoto.com; the download URL wasn't recorded |
| Ortho Plus | Harman datasheet, October 2019 | image | https://ilfordphoto.com/amfile/file/download/file/1948/product/698 |
| Phoenix 200 | HARMAN datasheet, September 2024 | image | ilfordphoto.com; the download URL wasn't recorded |
| Fomapan 100 Classic | Foma datasheet, 05/22 | vector | https://www.foma.cz/en/fomapan-100 |
| Fomapan 200 Creative | Foma datasheet, 05/22 | vector | https://www.foma.cz/en/fomapan-200 |
| Fomapan 400 Action | Foma datasheet, 04/23 | vector | https://www.foma.cz/en/fomapan-400 |
| Fomapan R 100 | Foma datasheet, 01/25 | vector | https://www.foma.cz/en/fomapan-R-100 |

The Ilford 2010 editions draw the same curves, with the same captions, as the current editions,
which print them as images. We traced the current HP5 Plus image as a check (section 2).

## Which curve we picked

Datasheets often print several curves, one per developer or development time. Here's which one
each entry uses, and why.

- **Tri-X 400**: the 35 mm curve for KODAK PROFESSIONAL T-MAX Developer, small tank, 6 min at
  20 °C. It's the only printed curve whose time matches a starting point in the development table,
  and Kodak says those starting points aim at contrast index 0.56.
- **T-Max 400**: T-MAX RS Developer and Replenisher, large tank, 5 min at 24 °C. That matches the
  table's starting point for that developer.
- **T-Max 100**: none of the printed curves matches a starting point, so we used D-76, small tank,
  6 min. The table's D-76 small-tank time is 6½ min, and there's no curve printed for that.
- **T-Max P3200**: the March 2018 F-4001 prints curves for T-MAX Developer, small tank, 20 °C, at 6,
  7, 10 and 12 min. 12 min is the table's starting point for EI 3200, the speed in the film's name,
  so the entry is for EI 3200 (Kodak gives the nominal speed as EI 800 to 1000). The July 2018 and
  April 2019 editions print an older set of curves instead (8, 9, 11 and 13 min, as in F-4016 of
  2007), and none of those is at a table time. Kodak's J-86 says its developers aim at contrast
  index 0.56 "for the other films", but that's for normal development, not this push.
- **Delta 3200**: the May 2010 sheet prints MICROPHEN stock and ILFOTEC DD-X curves at 7, 9, 12 and
  16 min. MICROPHEN 9 min at 20 °C is the table's time for EI 3200, so we used that curve, and the
  entry is for EI 3200 (the film's ISO speed is 1000).
- **Acros 100 II**: Microfine, 20 °C, small tank, 10 min: the table's time for EI 100.
- **Delta 100**: ID-11 stock, 8½ min at 20 °C: the table's time for EI 100.
- **Ortho Plus**: the "Pictorial contrast" chart, ID-11 stock, 8 min, which the chart labels G-bar
  0.62. Like every other entry with a curve, its gamma is the straight-line slope we work out from
  the curve. The `source` string still quotes the stated G-bar.
- **Superia X-TRA 400**: we use the current sheet (013AR0316A).
- **Vision3**: we use the July 2015 sheets because they draw the curves as vectors. The March 2026
  sheets print the same curves as images (section 2).
- **CineStill 800T**: CineStill doesn't publish curves. Its FAQ (archived 5 November 2020,
  https://web.archive.org/web/20201105160705id_/https://cinestillfilm.com/pages/frequently-asked-questions)
  says "Vision 3 5219 is the 3rd generation of tungsten balanced EI 500 color negative motion
  picture film stock behind CineStill 800Tungsten emulsion". So the entry uses the 5219 reading and
  shares its curves. It's only an approximation: CineStill film goes through C-41, not ECN-2, which
  changes the contrast and base density, and CineStill says its current films combine specs from
  several films.
- **Fomapan 100, 200 and 400**: see the Fomapan section below.

## Stocks with only the maker's contrast figure

These stocks have no usable curve and no published base density. The only number we have is the
contrast the maker states for a named development.

| Stock | Stated contrast | Development | Document |
|---|---|---|---|
| Eastman Double-X 5222 | gamma 0.65; control gamma 0.65 to 0.70, measured with Status M blue | D-96, 7 min, 21 °C | Kodak H-1-5222, March 2026, https://www.kodak.com/content/products-brochures/motion-picture/EASTMAN-DOUBLE-X-technical-information.pdf |
| Ilford Delta 400 Professional | G-bar 0.62 for the times printed in bold | e.g. ID-11 stock, 9½ min, 20 °C | Harman datasheet, Nov 2018, https://ilfordphoto.com/amfile/file/download/file/1915/product/424 |
| Rollei RPX 25 / RPX 100 / RPX 400 | average contrast γ 0.65 | Rollei Supergrain 1+12, 20 °C: 5½ / 6½ / 7 min | Rollei datasheets R210701, https://www.rolleianalog.com/downloads/ |
| Rollei Retro 80S / Retro 400S | average contrast γ 0.65 | Rollei Supergrain 1+12, 20 °C: 8 / 10 min | as above |
| Rollei Infrared | average contrast γ 0.65 | Rollei Supergrain 1+12, 11 min, 20 °C, at ISO 400 | https://www.rolleianalog.com/wp-content/uploads/2025/06/230821_INFRARED_Datenblatt_EN_2025.pdf |
| ADOX CHS 100 II | beta (mean gradient) 0.65 | e.g. ADOX ADONAL 1+25, 5½ to 6 min, 20 °C | ADOX datasheet, 11 July 2024, https://www.fotoimpex.com/shop/images/products/media/44450_4_PDF-Datenblatt.pdf (linked from adox.de) |
| Fomapan R 100 | gradation 1.1 on the straight part | process R-100, first developer Fomadon LQR 1+10, 9 to 10 min, 20 °C | Foma datasheet, 01/25 |

We didn't add Delta 400's curve. Every edition prints it for ID-11 stock, 8 min at **24 °C**.
That's more development than the 9½ min at 20 °C that the stated G-bar 0.62 belongs to, so the
curve and the stated contrast would describe two different negatives.

### Fomapan 100, 200 and 400

For these three we wanted Foma's own numbers: base density, a characteristic curve, and gamma for a
typical development. Here's what Foma publishes, and what the entries hold.

- **Characteristic curve: published, with a catch.** Each datasheet prints curves for Ilford
  Microphen stock at 20 °C at three times: 5, 7 and 11 min (100), 4, 6 and 8 min (200), and 7, 9
  and 11 min (400). The entries keep the middle curve: 7, 6 and 9 min. Those times are at the top
  end of Foma's recommended Microphen times for each film.
  - We read the curves exactly from the vector drawing. The worst axis residual is 0.015 D.
  - **The catch: all three datasheets print the same drawing**, with only the time labels
    changed. Once mapped, the three agree to within 0.001 D.
  - The drawing's straight part has a slope of about 0.96, well above the γ Foma itself states
    for these developments.
  - So the curve shows the general shape Foma publishes, not a measurement of each film, and none
    of the entry's numbers comes from it. (The app's Datasheet corrections do still use its shape
    to straighten the toe.)
- **Gamma: published.** Foma's products catalogue (2020) states γ ranges for each film in Ilford
  Microphen stock:
  - Fomapan 100: 5 to 7 min, γ 0.60 to 0.66.
  - Fomapan 200: 5 to 6 min, γ 0.58 to 0.64.
  - Fomapan 400: 8 to 9 min, γ 0.66 to 0.69.

  The catalogue notes that the longer time gives the higher gradient, so the entries take 0.66,
  0.64 and 0.69 to go with the curves we kept.

  For Foma's own developer, the same catalogue gives γ 0.65 ("medium contrast") with Fomadon R 09
  1+25 at 20 °C: 4 min for 100, 5 min for 200, 6 min for 400. The catalogue is at
  https://www.foma.cz/en/catalogue_bw_photo_materials_and_developing_information.
- **Base + fog density: not published.** No Foma document gives a base + fog or D-min figure, and
  the printed curves start at the edge of the frame while still rising, so they can't give us one
  either. The entries leave it null.
- **Density range: not published,** so that's null too.
- **Densitometry: not stated.** Foma doesn't say how it measured.

Fomapan R 100 is in the same boat. Its curve is specific to that film, but its slope (about 1.6)
disagrees with the stated gradation of 1.1, and it doesn't flatten out at either end, so D-min and
D-max are null.

## Stocks in the menu without a preset

The stock menu also lists common stocks that have no preset, so you can still name a roll after
them. They're in the `unmeasured` list in `src/app/labels.zig`. Once one of them gets a preset, the
menu shows the preset instead.

For each one, we first searched the makers' datasheets and other technical publications for stated
numbers (contrast index, G-bar or gamma per development, base + fog, D-max, speed points), and then
for a characteristic curve. Here's what turned up:

| Stock | Result |
|---|---|
| Ilford HP5 Plus, FP4 Plus, Delta 100, Delta 3200, Pan F Plus, XP2 Super | Now presets, read from the curves. No sheet states a contrast for a particular development. Ilford's developer leaflets (ID-11 2004, ILFOTEC HC 2003, ILFOTEC DD, RT RAPID, the powder and liquid developer leaflets of 2003 to 2010, DD-X 2019, LC29 2020, Ilfosol 3 2019) only say that their times aim at G-bar 0.62 for all films. They also give FP4 Plus control-strip values for seasoned developers, but those describe the strip, not the film. |
| Kentmere Pan 100, Pan 400 | Nothing usable. No edition prints a characteristic curve, a contrast-time graph or a contrast figure: January 2009 (kentmere.co.uk, archived), January 2019 and the current sheets only have reciprocity, temperature and time tables. Tried: https://web.archive.org/web/20121116050051id_/http://www.kentmere.co.uk/Webfiles/20091291713401332.pdf, https://web.archive.org/web/20121120120022id_/http://www.kentmere.co.uk/Webfiles/20091291714152280.pdf, https://web.archive.org/web/20220709053530id_/https://www.ilfordphoto.com/amfile/file/download/file/1921/product/696/, https://web.archive.org/web/20201112030440id_/https://www.ilfordphoto.com/amfile/file/download/file/1922/product/697/; kentmerephoto.com and kentmere.com didn't connect and have no archived captures. |
| Kodak T-Max P3200 | Now a preset, read from the curve. Stated numbers: nominal speed EI 1000 in T-MAX developers (F-4001, F-4016), and Kodak J-86's blanket contrast-index aim of 0.56 for "the other films" (October 2002, https://web.archive.org/web/20160615035416id_/http://www.kodak.com/global/en/professional/support/techPubs/j86/j86.pdf). |
| Fujifilm Acros 100 II | Now a preset, read from the curve. AF3-0258E only states granularity and resolving power; its time-Ḡ graph is an image. |
| Kodak ColorPlus 200 | Nothing found from Kodak or Kodak Alaris. None of the archived PDF folders on Kodak Alaris's domains has a ColorPlus sheet, the current "everyday film" pages only list Gold 200 and UltraMax 400, the Kodak Alaris site search finds nothing for "colorplus" or "kodacolor", and the imaging.kodakalaris.com product page returns 404. |
| Kodak Pro Image 100 | Now a preset, read from the vector curve in E-4L (July 1997, archived from kodak.com). It states red densities for judging exposure, which section 3 uses. There's no Kodak Alaris sheet for the current product (the imaging.kodakalaris.com product page returns 404). |
| Fujifilm Superia 200 | Now a preset, read from the chart image in AF3-026E. Its only stated number is the grey-card red density (section 3). AF3-008E, archived from fujifilm.com, states the same. |
| Harman Phoenix 200 | Now a preset, read from the chart image. The sheet states ISO 200 and that the film works best between EI 100 and 200; it doesn't say how density was measured. |
| CineStill 400D | Nothing. CineStill doesn't name a base stock for 400D and hosts no datasheet for it; its only 400D PDF is a 4x5 handling sheet with no data (https://cdn.shopify.com/s/files/1/0339/5113/files/CineStill_400D_4x5_Handling_Tips.pdf). https://cinestillfilm.com/pages/datasheets returns 404. |
| CineStill 50D | Left out. CineStill's 50D product page (archived 26 February 2018, https://web.archive.org/web/20180226220131id_/https://cinestillfilm.com/products/50daylight-36exp-135-fine-grain-color-film-35mm-roll) says "Original fresh stock from Kodak 50D, prepped and rolled for clean safe C-41 standard development as an ISO 50 film." It says Kodak 50D but not Vision3 50D or 5203, and the current page only says "Based on the original motion picture emulsion". Kodak's only 50D camera film is Vision3 50D 5203/7203, so if you accept that reading of CineStill's wording, the entry could use the Vision3 50D reading, the way 800T uses 5219. |
| Lomography Color Negative 100, 400, 800 | Nothing usable. Lomography's film guides (https://cdn.downloads.lomography.com/downloads/color-negative-100-film-guide.pdf, and the same with -400- and -800-) only give ISO and C-41 and show sample photos. We didn't find a datasheet: lomography.com and shop.lomography.com returned 403, guessed datasheet names on cdn.downloads.lomography.com returned 404, and the web.archive.org index searches were offline. |
| Fujichrome Velvia 50 | Now a preset, read from the chart image in AF3-0221E2. The sheet only states granularity and resolving power; the Japanese edition (163AR0128B) states the same. |

Ilford SFX 200 and the Ortho Plus curve were added the same way.

## Stocks left out

| Stock | Why |
|---|---|
| Kentmere Pan 100, Pan 400 | No figures and no curves (see above). |
| Kodak ColorPlus 200 | No Kodak datasheet found. |
| CineStill 50D, 400D | See above. |
| Lomography Color Negative 100/400/800, Lomochrome Purple, Lady Grey, Berlin Kino, Earl Grey | No datasheet found. |
| Fujifilm Neopan 400 Presto | Discontinued. Its Japanese sheet has stated G-bar values and a vector curve, so it could be added. |
| Harman Phoenix 125 | Not added yet. Its sheet has a raster curve and no figures; it could be read like Phoenix 200. |
| CineStill BwXX | CineStill calls it "Double-X" but gives no data. Kodak Double-X is included. |
| ADOX Silvermax, HR-50 / Scala 50 | The contrast column (0,65) has no heading, so it isn't clear what it measures. |
| ADOX CMS 20 II, Color Mission | No contrast figure, or no datasheet. |
| Agfa APX 100, 400 | The sheets the distributor hosts don't state any numbers. |
| Foma Retropan 320 | No γ, and the curve's axis labels don't agree with each other. |

## Redoing the readings

The scripts are in `tools/`, and the commands below assume you're in `data/stocks`. They need
Python 3 with numpy, Pillow, pypdf and cryptography (one Fujifilm PDF is encrypted), plus poppler's
`pdftoppm` and `pdftotext`. Download the PDFs listed above into one folder. The scripts find them by
file name, and `tools/charts.py` gives the file name for each chart.

- `tools/charts.py`: one entry per chart, saying where the chart is on its page, where its axis
  ticks are and how to tell its curves apart, with comments on anything unusual.
- `tools/read_all.py PDF_DIR OUT_DIR [ID...]`: reads every chart (vector ones with
  `read_vector.py` and `pdfvec.py`, images with `read_raster.py` at two resolutions), resamples
  them with `grid.py`, works out base density, gamma and density range with `derive.py`, and writes
  one JSON file per chart with the tick residuals and the comparison of the two reads.
- `tools/checks.py OUT_DIR`: the cross-checks between editions and the checks against stated
  figures from section 3.
- `tools/make_zig.py OUT_DIR ../../src/presets/stocks.zig`: writes the entries and curve data
  listed in `tools/stocks_meta.py` into `stocks.zig`, replacing any entry with the same name. Add
  `--dry-run` to try it without writing the file. Run `zig fmt` afterwards.
- `tools/overlay.py PDF_DIR READING_JSON OUT_PNG`: draws a reading back onto its page, so you can
  check it by eye.
- `tools/explore_vector.py`, `tools/explore_raster.py`, `tools/colours.py` and
  `tools/compare_reads.py`: helpers for setting up a new chart's entry in `charts.py`.
- `tools/check_derive.py STOCKS_ZIG NAME...`: runs `derive.py` on curves that are already in
  `stocks.zig`, picked by their names in `curve_data`.

Run them with `python -I`, since the PDFs are third-party files.

## Licences and attribution

minilab is MPL-2.0. The makers' datasheets are their copyright, and they aren't stored in this
repository. The numbers in `stocks.zig` are our own readings of the charts and figures the makers
publish, made with the scripts in `tools/`. Those scripts are part of minilab and MPL-2.0 like the
rest of it. Kodak, Eastman, Vision3, Kodachrome, Ektachrome, Fujifilm, Fujicolor, Fujichrome,
Ilford, Harman, Kentmere, Foma, Fomapan, Rollei, ADOX, CineStill, Lomography and the product names
are trademarks of their owners.
