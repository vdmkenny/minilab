# negscan: design

Working name. A film scanning and inversion app:

- scan a roll on any scanner the system can drive (SANE on macOS and Linux, TWAIN on Windows),
  the V200 included, or import camera RAW files and existing scans;
- find the frames;
- invert and colour-correct them in density, with an inversion model based on darktable's;
- export finished files.

35mm by default, other formats supported. Written in Zig 0.17 with a Dear ImGui interface, built
the way openreliant-editor is. Status: design only, nothing written yet. Section 15 lists the
phases and what's still open.

## 1. What we take from the reference apps

[f8 Develop](https://develop.atf8.app/) (macOS, closed source), from its product page:

- it measures the film base from the rebate visible in the scan, per roll;
- rolls are organised as sessions with film stock, date and location;
- it develops a whole roll in a batch, non-destructively, and can develop it again later;
- it writes camera, lens, film stock and copyright metadata into the exported files;
- it exports HEIC, TIFF and JPEG, including HDR HEIC with Apple's adaptive gain map.

[Negative Lab Pro](https://www.negativelabpro.com/guide/basics/) (Lightroom plugin, closed source),
from its guide. Its presets come in independent layers:

- colour model: Basic, Frontier, Noritsu, B+W, None;
- pre-saturation;
- tone profile: Cinematic (log), LAB (standard, soft, hard and highlight/shadow variants), Linear
  (gamma, deep, flat);
- white balance: auto-neutral, auto-warm, auto-cool, auto-average, or fixed per film family
  (Standard, Kodak, Fuji, Cine-T, Cine-D);
- LUTs: Natural, Frontier, Crystal (Crystal Archive paper), Pakon;
- a "border buffer" that leaves the frame edges out of the analysis;
- separate colour balance for highlights, midtones and shadows.

We copy the ideas: base measured from the rebate, roll-level sessions, layered presets, batch
sync and per-region colour balance. No preset values come from either product: we don't have
them, and they aren't published. Every built-in preset in negscan says where its numbers come from
(section 9).

## 2. Scope

In:

- colour negative, B&W negative, colour positive (slide) and B&W positive;
- scanners:
  - through SANE on macOS and Linux, so any scanner SANE supports. The V200 goes through our
    epkowa build and plugin, unchanged.
  - through TWAIN on Windows, with the scanner maker's own driver.
- camera scans: RAW files from a camera over a light source, through LibRaw;
- importing linear TIFFs from other scanning software (VueScan, SilverFast raw output);
- all common film sizes and formats, one format per roll;
- automatic frame detection that keeps the roll format's aspect ratio, plus custom boxes;
- macOS (arm64, x86_64), Linux (x86_64, arm64) and Windows (x86_64).

Out, at least for now:

- dust and scratch removal with an infrared channel (the V200 has none);
- grain, halation and other film simulation effects;
- stitching several camera shots of one medium format frame.

## 3. Architecture

```
          app: GUI (Dear ImGui via Dear Bindings, SDL3 + SDL_GPU)  and  CLI subcommands
                                          |
   ------------------------------- core module (Zig) ------------------------------
   scan/      scanners: SANE, TWAIN, camera tethering later; one tagged union over them
   input/     TIFF, camera RAW (LibRaw)
   frames/    strip and frame detection, formats, crops
   develop/   the colour pipeline: base, density, inversion, tone, output
   presets/   preset files, layering, resolving to parameters
   roll/      on-disk roll layout, sidecars, EXIF/XMP
   output/    TIFF, JPEG, ICC                (libtiff, libjpeg-turbo, lcms2)
   --------------------------------------------------------------------------------
```

- **Zig 0.17, idiomatic, with OpenReliant's conventions.** Name every number, give an id space an
  `enum` and switch over it exhaustively, use tagged unions for variants and optionals for
  "none", check invariants with `comptime`, and put `test` blocks next to the code.
  British spelling in docs and comments, American on screen.
- **The core module** holds everything that can be tested without a window: the pipeline, frame
  detection, scanner sessions and file handling. `zig build test` runs its tests with no scanner
  and no display.
- **The app** is one executable. With no arguments it opens the GUI. Subcommands
  (`negscan develop`, `negscan detect`, `negscan scan`) run the core from the command line, for
  batch work and for the tests.
- **Dear ImGui as in openreliant-editor.** It is C++, so Dear Bindings' C API wraps it, and the
  translate-c package turns one header (`src/platform/c.h`: SDL3, `dcimgui.h` and its SDL3 and
  SDL_GPU backends, and our shims) into the `c` module. ImPlot and the few internal ImGui calls go
  through small C shims. zgui, the Zig-native wrapper, doesn't build with Zig 0.17: tried here, it
  fails on `std.meta.fields`, which 0.17 removed.
- **Threads.** The UI runs on the main thread. One scan thread owns the scanner, since SANE and
  TWAIN calls block. A worker pool runs the pipeline. The UI never waits on either.
- **Pixels.** Raw scans stay 16-bit on disk. In memory the pipeline uses 32-bit float RGB. The
  viewer works on a proxy at screen size, so a slider change re-renders a few megapixels, not the
  full scan. A full-resolution render happens only on export.
- **CPU, not shaders.** The pipeline runs on the CPU, multi-threaded, with `@Vector` where it
  helps. A 35mm frame at 4800 dpi is 6803 × 4535 px, 31 MP. The per-pixel work is one log, a 3×3
  matrix, one exp and a curve lookup per channel. So a full render should take well under a
  second on 8 cores, and a 3 MP proxy a few milliseconds (an estimate; phase 1 measures it).
  With one implementation the preview and the export are identical and testable. The GPU only
  draws the UI and shows the finished proxy as a texture.
  Measured: Develop renders its 754 × 1131 preview with Frontier emulation in about 40 ms on a
  12-core M-series Mac, split over the cores by rows.

## 4. Workflow

The GUI has five workspaces, mocked up in the "negscan GUI" design canvas:

- **Rolls:** a contact sheet per roll, with its filmstrip, date and how many frames are
  developed. Undeveloped frames show the raw scan.
- **Scan:** scanner settings, the preview with detected frames, the selected frame's crop, and
  the scan queue.
- **Develop:** frames, viewer with a negative/positive split, and the develop settings.
- **Export:** frame selection, file settings and metadata.
- **Looks:** the built-in looks, Frontier emulation, and fitting a look from reference pairs.

The steps:

1. **New roll.** Film type, stock (optional), format, camera, lens, date, notes. Stored in the
   roll directory (section 11).
2. **Preview.** Scan the scanner's whole film area at low resolution.
   - On the V200 this is the 33.02 × 244.348 mm transparency window (the backend's `-x`/`-y`
     range). The Epson stack's own preview of a strip was 384 × 2885 px at 300 dpi (recording
     `10-preview-negative`).
   - The first scan after power-on is about 1% brighter and shifted a few pixels (phase3.md), so
     the preview also serves as the warm-up before the scans that matter.
3. **Detect frames** (section 6), and correct them by hand where needed.
4. **Scan.** One scan per frame at the chosen resolution, linear, 16-bit, with a margin around the
   detected box. The margin covers two things:
   - the strip moves 11 to 14 lines between sessions (phase3.md);
   - the margin includes the gap between frames, which is where the film base is measured.
5. **Refine.** Run edge detection again on each full-resolution scan, refine the crop, and measure
   the film base in that scan's own margin.
6. **Develop.** Pick a preset; auto values are computed per frame; adjust; sync settings across
   the roll.
7. **Export.** TIFF 16-bit or JPEG. HEIC with a gain map comes later (phase 7).

Camera scans and imported files skip steps 2 and 4: import RAWs, linear TIFFs or PNM scans into a
roll (`negscan import`, or drop them on the roll in the app), detect or draw the frames, and
continue from step 5. A file of one frame becomes one frame. A strip, from VueScan or a flatbed,
becomes one frame per whole frame on it; they share the one stored scan, each with its own crop and
the film base from the gaps beside it.

## 5. Inputs

### Scanners

Scanners are one tagged union, `Scanner = union(enum) { sane, twain }`. Each OS builds only the
variants it has. The rest of the app sees the same operations on every OS: list devices, read
capabilities, preview, scan an area, cancel.

**SANE (macOS, Linux).**

- The app loads the system's libsane at run time (`std.DynLib`), so it starts without SANE
  installed and uses the system's backend configuration (`dll.d`), which is where the V200's
  epkowa backend is enabled. The types come from `sane.h`, which is public domain.
- Options by name. SANE's standard names (`source`, `mode`, `depth`, `resolution`, `tl-x`, `tl-y`,
  `br-x`, `br-y`, `preview`) work everywhere. Backend-specific ones, such as epkowa's `film-type`
  and `gamma-correction`, come from a scanner profile.
- Cancel is `sane_cancel`. On the V200 the plugin then reads the rest of the scan so the scanner
  stays usable. That takes as long as the rest of the scan would have (install.md), so the UI
  shows "finishing" until it's done.
- sane-backends ships a `test` backend that generates frames (Homebrew has `libsane-test.so`).
  The tests use it, so the SANE layer is tested without a scanner.

**TWAIN (Windows).**

- The app loads the TWAIN data source manager (`TWAINDSM.dll`) at run time, as TWAIN applications
  do, and drives the maker's data source with its UI hidden where the source allows that
  (`CAP_UICONTROLLABLE`).
- The film capabilities exist in the standard: `ICAP_LIGHTPATH` (`TWLP_TRANSMISSIVE`),
  `ICAP_FILMTYPE` (positive, negative), `ICAP_BITDEPTH`, `ICAP_GAMMA` and `ICAP_FRAMES`. How much
  of this each maker's source supports is something we can only find out per scanner.
- On Windows the V200 runs on Epson's own TWAIN driver (Epson Scan), not on our plugin. Whether
  Epson's source gives linear 48-bit data without its own window is unknown until it's tried on a
  Windows machine.
- `twain.h` carries the TWAIN Working Group's copyright with no licence terms in it, so we don't
  vendor it. The Zig declarations for the structures and constants we use are written from the
  TWAIN specification.

**Scanner profiles.** One small text file per model: which option values give linear raw data
per film type, the film area, holder layouts, and preview and scan resolutions. The V200 profile,
from our own measurements:

- source `Transparency Unit`, mode `Color`, depth 16, `gamma-correction` `User defined (Gamma=1.0)`;
- the colour matrix as the identity (`cct-1` … `cct-9`). The backend's default matrix mixes the
  channels for a more saturated picture;
- resolutions 300, 2400 and 4800 dpi (the backend's option list);
- film type `Positive Film` for every film. `Negative Film` takes the orange mask out in the
  scanner, so the film base can't be measured beside the frames, and it clips blue on B&W film
  (phase1.md). negscan inverts the raw scan itself.
- The film type is set before the rest, as scanimage does, in case the backend resets its colour
  settings for a film type.

Checked on the V200 with a colour strip: `negscan scan` with this profile gives the same values as
`scanimage` with the same options, within 2% in every channel.

**Scanners without a profile.** The app shows what the scanner offers and picks the obvious
values: colour, the highest depth, and the transparency source if there is one. If there's no way
to get linear output, a calibration scan of a transmission step wedge (such as a Stouffer T2115)
gives the scanner's curve, which the pipeline then undoes. Without either, the app says the data
isn't known to be linear.

### Camera scans

LibRaw decodes the RAW file with no white balance, no colour matrix and no gamma: linear 16-bit
data in the camera's own channels, which is what the density stage wants (section 7).

- LibRaw leaves the numbers unscaled; they're scaled so that the sensor's white level is full
  scale.
- A flat-field shot (the light source with no film, same exposure) corrects uneven light and lens
  vignetting. It's taken once per session and stored with the roll: `negscan import --flat`, or
  the New roll form for a camera roll. Frames imported after it are divided by it (section 7,
  Linearise); frames already in the roll stay as they are.
- The film base comes from the rebate in the frame, as for scans.
- For positives the camera's own matrix from LibRaw is the input profile, unless the user has an
  IT8 target shot.

### Files

16-bit linear TIFFs from other software, RGB or greyscale, in any compression LibTIFF decodes.
8-bit TIFFs and PNMs are read too, with a warning that they're probably not linear. The user says
whether the file is linear. If it isn't, the step wedge calibration applies, as for scanners (not
built yet).

A roll keeps every scan as a 16-bit PPM, whatever it was imported from, so the rest of the app
reads one format.

## 6. Film formats and frame detection

A roll has one format; frames of different formats never share a roll. The format seeds the
detection. Real frame sizes vary by camera, which is why detection measures them. Nominal image
sizes in mm:

| Film size | Formats |
|---|---|
| 135 | full frame 36 × 24 (default, 38 mm pitch), half frame 18 × 24, panorama 65 × 24, square 24 × 24 |
| 120 / 220 | 6×4.5 56 × 41.5, 6×6 56 × 56, 6×7 56 × 69.5, 6×8 56 × 76, 6×9 56 × 84, 6×12 56 × 112, 6×17 56 × 168 |
| 127 | 4×4 40 × 40, 4×6.5 40 × 65, 3×4 30 × 40 |
| 110 | 13 × 17 |
| 126 | 28 × 28 |
| APS | H 30.2 × 16.7, C 25.1 × 16.7, P 30.2 × 9.5 |
| Minox | 8 × 11 |
| Sheet film | 4×5 in, 5×7 in, 8×10 in, 9×12 cm, 13×18 cm; image area depends on the holder |
| Custom | any size, with a locked ratio or free |

The V200's 33.02 mm window takes 35 mm wide film (135, 126), and narrower film (110 at 16 mm, APS
at 24 mm, Minox at 9.2 mm) if a holder keeps it flat. 120 and wider need another scanner or a
camera.

Film holders usually cover the film edges, so the scan shows no rebate across the strip. The
default crop therefore uses the full height of the holder opening, and only the gaps between
frames set the ends.

Detection on a strip preview, for negatives:

1. **Classify.** Holder and anything outside the film transmit almost nothing. The film base
   between frames is the most transparent part of the film. The image area sits in between.
2. **Opening.** Fit lines to the two long edges of the light band. Usually these are the
   holder's edges, not the film's: they give the strip's angle and the frame height. Where the
   film edge does show, the perforation bands are left out by their repeating pattern.
3. **Gaps.** Along the strip, take the median density of each row across the band. Runs at base
   density, about as long as a frame gap, are frame boundaries.
4. **Snap to the roll's format.** The frame gets the full height of the opening, and the
   format's ratio gives its length, centred between its gaps. A frame whose measured length is
   far from that keeps its measured box and is marked for checking.
5. **Weak frames.** A frame of a dark scene is close to base density, so its edges barely show.
   Missing boundaries are filled in from the pitch of the confident neighbours, and those frames
   are marked for checking. 120 and other films without perforations have no fixed pitch, so
   their weak frames rely more on the user.
6. **Inset.** None across the height by default. An inset can be set when an opening is wider
   than the image, such as a 35mm holder with a 120 mask.

For positives in mounts, the mount is opaque and the aperture is the frame. For unmounted slide
film the gaps are unexposed, so they're opaque instead of clear. The steps are the same with the
test inverted. A camera scan usually holds one frame. The same steps find its edges in the one
image and skip the pitch. A file with two or more whole frames on it is a strip: each whole frame
becomes a frame of the roll, and frames cut off by the edge of the scan are left out.

By hand, the user can:

- drag edges and corners;
- add, delete and split frames;
- rotate;
- lock the aspect ratio to a format or a custom ratio, or leave it free.

Hand edits are kept when detection runs again.

## 7. The colour pipeline

### The model we start from

darktable's negative inversion model, as its documentation sets out the maths. negscan's code is
written from these equations, not translated from darktable's C, so it can carry negscan's own
licence (section 13). T is the pixel's transmission and T_base the film base, per channel:

```
d   = log10(T / T_base)                                   (density above base, ≤ 0)
c   = (wb_high / D_max) · d  +  wb_high · offset · wb_low
p   = max(exposure · (1 + black − 10^c), 0) ^ gamma       (inversion)
out = p                                    if p ≤ s
      s + (1 − e^(−(p − s)/(1 − s))) · (1 − s)   otherwise  (s = highlight roll-off)
```

Its colour film preset sets D_max 1.6, offset −0.05, black 0.0755, gamma (contrast) 4.0, roll-off
0.75 and exposure 0.9245. Its pickers derive:

- D_min from a base sample;
- D_max from the densest part of the negative;
- offset from the least dense part;
- the two white balances from neutral samples in the shadows and highlights.

Dividing by the base sample cancels any constant per-channel gain in the scanner. That's why the
V200's Negative Film mode, which changes the exposure per channel, makes no difference to the
result, apart from giving blue more levels.

### What ours does

Each stage has its own parameters; presets set some or all of them.

1. **Linearise.** The scanner profile's curve, or nothing for linear input. Camera scans are
   divided by the flat field here, on import. The flat field is averaged over a grid of 64 cells
   along its longer side, blurred over each cell's neighbours (the grid continued past its edges
   along its own slope, so the edges aren't pulled towards the middle), interpolated between cell
   centres, and divided by its brightest value per channel: a gain of at most 1 at each point.
   Dust on the light source and noise drop out; the fall-off stays.
2. **Base.** Divide by T_base, measured from the scan's own margin (section 4).
   - The roll's base is the median over its frames.
   - A frame that differs from it by more than the scan-to-scan variation gets flagged.
3. **Density.** d = −log10(T / T_base), in the scanner's or camera's own channels, before any
   colour matrix, the way a densitometer reads a negative. darktable applies the input profile
   before its inversion; we don't. Dye densities add in log space, so channel mixing belongs in
   density (stage 4). A matrix on transmission values has no such meaning.
4. **Density correction.** Per-channel slope and offset, as in darktable's model, plus a 3×3 matrix in
   density space, identity by default. The matrix corrects channel crosstalk and the dyes'
   unwanted absorptions. darktable's model has no equivalent.
5. **Inversion curve.** Per-channel curves from density to positive values, as tables.
   - darktable's `(1 + black − 10^c)^gamma` with highlight roll-off is one curve shape. It stays the default,
     and gives the same output as darktable for the same parameters.
   - A table lets the curves come from datasheet data or a fitted lab scanner instead.
6. **Tone and colour.** Tone profile curve, highlight/midtone/shadow balance. Then the look
   (section 9), then saturation: each pixel mixed with its own luminance in linear light, which
   keeps its hue and luminance.
7. **Output.** Linear Rec.2020 internally.
   - lcms2 converts to the display profile for the viewer (SDL3 provides the window's ICC
     profile).
   - lcms2 converts to the export space (sRGB, Display P3, Adobe RGB, ProPhoto) and the profile
     is embedded.
   - Values above 1 are kept up to this stage, for HDR export later.

B&W negatives use one channel's density (selectable, green by default) through the same stages.
Positives skip stages 2 to 5. Their transmission goes through an input profile (an IT8.7/1
transparency target if the user has one, otherwise a matrix) and then the tone stage.

### Auto values

Computed per frame, inside the crop minus a border buffer, as NLP describes its analysis:

- **base**: from the margin, as above;
- **D_max and offset**: from low and high density percentiles. They play the same role as
  darktable's pickers, without the clicking.
- **white balance**, one of:
  - auto-neutral: balance the low-chroma areas, in density;
  - auto-warm and auto-cool: the same with a bias;
  - average: grey world;
  - fixed, from the stock preset;
  - a picked neutral.

These are our own algorithms. Their definitions go in the docs and tests, not only in the code.

## 8. Settings and sync

Every frame has a sidecar with the preset names and versions and every resolved parameter. A
frame opened again later renders the same, even after a preset changed. "Sync" copies chosen
groups to the roll's other frames: look, tone and saturation, and white balance by default;
density, film base, and crop with turns when asked. What isn't synced each frame keeps, or
measures for itself on its thumbnail if it was never developed. An automatic white balance is
worked out on each frame.

## 9. Presets

Layered like NLP, but ours, with their sources written down.

**Film type:** colour negative, B&W negative, colour positive, B&W positive. Picks the pipeline
path and the scanner settings.

**Stock** (optional): starting values for the per-channel slopes and the base, and the fixed
white balance.

- Source: the makers' datasheets. The characteristic curves and figures are our own readings of
  the published charts, with each stock's datasheet, edition and reading error recorded in
  `data/stocks/README.md`. The PDFs aren't stored.
- Datasheet densities are measured through standard filters (Status M), and a scanner's channels
  aren't the same: on our V200 a colour negative's red needs 1.3 to 1.7 times blue's slope where
  Status M says 1.14. Used directly, a stock's gammas turn skies cyan. So Stock balance needs the
  scanner calibrated, once, on any roll of a stock with a preset (`src/core/calibration.zig`):
  - each frame's automatic balance gives the slopes that make its neutrals neutral;
  - their median over the roll leaves out the scenes' own colours;
  - divided by the stock's datasheet slopes, it gives the scanner's factors, per layer.
  A stock's balance on that scanner is then its datasheet slopes times the factors. This holds for
  any scanner or camera whose channels each read mainly one dye; each is calibrated by the name its
  rolls record, and more rolls refine it (the median over them). The calibrations live in the
  library's `calibration.json`. On the V200, from a roll of Superia X-TRA 400: red ×1.23, blue
  ×0.94.
- Stock balance keeps the roll's light: each frame gets the same layer slopes, and only its
  shadows are balanced on the frame. Auto neutral, the default, neutralises each frame instead.
- Exact values come from a calibration frame on that stock: a grey card bracketed over several
  stops. The app saves the result as a personal preset per stock and scanner.

**Look:** what follows Develop's settings. Develop lists every look in one drop-down.

- **Neutral:** Develop's rendering as it is: the inversion curve and nothing added.
- **LUT looks:** a .cube LUT (1D, 3D, or a 1D shaper and a 3D LUT, any size and input range)
  laid over Neutral's sRGB-encoded output, read with tetrahedral interpolation. Tone, balance and
  the rest of Develop's settings still apply. negscan ships one, Frontier emulation (section 10),
  and the user can import any .cube that expects sRGB or Rec. 709 input. Imported LUTs are copied
  into the library's `Looks/` folder.
- **Fitted looks:** made in the Looks workspace from pairs of our raw scans and a lab's scans of
  the same negatives. They take over after the film base and density stages: curves, a density
  matrix and an optional 3D LUT. Tone and the inversion settings don't apply to them.

A frame keeps its look by name (`neutral`, `frontier`, `cube:<name>` or `look:<name>`). A look
that can't be read develops as Neutral, with a warning.

**Tone profile:** standard, soft, hard, linear, log. Parametric curves, defined in the docs.

**White balance:** the auto modes and fixed values from section 7.

**Positives:** neutral, or a per-stock IT8 profile, then the same tone profiles.

Preset files are plain text with a version number. Built-in ones are installed with the app; saved
and fitted ones go in the user's directory.

## 10. Frontier emulation

Frontier emulation (its name in the app) gives a frame the colour of a Fujifilm Frontier scan. It is
a subtle difference over Neutral, not a different development: tone, neutrals and lightness stay
Neutral's.

**Source.** The colour cube in the Frontier 350's scanning software (A1 7.6-0E-920, the user's
licensed copy): a 32³ table from the tone curve's 10-bit output to 8-bit monitor RGB, with the
software's saturation matrix in front of it. Nothing else of the Frontier is used.

**Why only the cube.** The Frontier develops a negative through its own chain: density, a gray
axis set per roll, a film curve, a per-channel tone curve, the saturation matrix and the cube. Its
tone curve and the cube's grey axis together are a hard S-curve, and its curves expect the
Frontier scanner's densities. On another scanner's raw scans the whole chain comes out contrasty
and over-saturated. What makes a Frontier scan look like one is how the cube renders colours
compared with greys, and that part doesn't depend on the scanner.

**How the LUT is made** (`src/presets/looks/frontier.cube`, 33³). For Neutral's sRGB-encoded value
`d`:

    f = d + cube(S w) − grey(w),   w = grey⁻¹(d) per channel

where `grey` is the cube's output along its grey axis, per channel, `grey⁻¹` goes back through the
channels' mean, and `S` is the saturation matrix at the Frontier's standard setting (1.2 on the
diagonal, −0.1 elsewhere). A grey comes out as it went in, and a cube that treated the channels
apart would change nothing. The result keeps `d`'s Oklab lightness and takes its hue and chroma
from `f`.

**What it does.** Over sRGB's mid-lightness colours, the mean chroma ends up at 0.96 of Neutral's.
The standard saturation puts back what the cube takes out (with no saturation matrix it's 0.82).
Greens lose about a fifth of their chroma and turn 10 to 15° toward teal. Skies, skin and yellows gain
5 to 20%, and reds turn a little toward orange. The baked LUT is within a quarter of an 8-bit step of
the exact transform on average, and greys within 3·10⁻⁶.

**B&W.** The Frontier has no B&W colour table. Its software runs B&W negatives through the same
chain, with a gentler straight line in its 10-bit density stage (slope 0.92) and a saturation preference
that makes the channels grey before the cube. Its B&W look is therefore tone only, and Frontier
emulation leaves B&W frames as Neutral has them. The installer's other B&W files
(`PARAM/imgp/*bw.dat`) are, by their names and sizes, the skin, sky, grain, clipping and
sharpening parameters, not colour tables.

**Checking it.** Lab Frontier scans of negatives the user still has are scanned raw on the V200 as
well, and each pair is registered and compared (ΔE2000 median and 95th percentile) in the Looks
workspace. The same workspace fits looks for labs whose software isn't available, such as a
Noritsu.

## 11. Files on disk

```
Rolls/2026-10-22 Portra 400 Ghent/
  roll.json            film type, stock, format, camera, lens, date, notes, scanner, base
  flat.ppm             camera scans only: the flat field, as shot
  scans/01.ppm ...     raw linear 16-bit scans, converted from TIFF or RAW on import, never
                       modified; the frames of a strip share one
  frames/01.json ...   crop, rotation, develop settings (resolved), preset names and versions
  exports/
```

Exports carry the metadata (camera, lens, film stock, copyright) as EXIF and XMP. We write these
ourselves in Zig: we only need a handful of tags, and exiv2, the usual library, is C++.

## 12. What we reuse

| Part | Use | Licence |
|---|---|---|
| openreliant-editor | the build setup: `build.zig`, `c.h`, the Dear Bindings and ImPlot shims, the SDL3/SDL_GPU window, the Makefile; patterns for `gui.zig` | MPL-2.0 (yours) |
| Dear ImGui, docking branch | GUI, docking layout | MIT |
| Dear Bindings | C API over Dear ImGui, for translate-c | MIT |
| ImPlot | histograms, curve editor | MIT |
| translate-c package | C headers into a Zig module | MIT |
| SDL3 (castholm/SDL's Zig build) | window, input, GPU (Metal, Vulkan, D3D12) | zlib |
| libsane (system's, loaded at run time) | scanners on macOS and Linux | GPL-2.0+ with SANE's exception; `sane.h` public domain |
| our epkowa build and `libesint7A` | the V200, unchanged, loaded by libsane | GPL-2.0+ |
| TWAIN DSM (system's, loaded at run time) | scanners on Windows | LGPL-2.1 |
| darktable's negative inversion model | the equations and their defaults, written in Zig from the maths; no darktable code | (credited; nothing copied) |
| film makers' datasheets | stock presets: our own readings of the published charts (`data/stocks/README.md`) | the numbers are ours; the PDFs aren't stored |
| LibRaw | camera RAW | LGPL-2.1 or CDDL-1.0 (negscan takes LGPL-2.1) |
| libtiff, libjpeg-turbo, little-cms2, zlib | file I/O, colour management | BSD-like, BSD/IJG, MIT, zlib |
| driver repo: `tools/imgcompare`, test data | registration approach; our V200 scans as test inputs | ours |

`build.zig.zon` fetches all of these at pinned versions and `zig build` builds the C and C++ ones,
as in openreliant-editor and OpenReliant:

- lcms2 and zlib from allyourcodebase's Zig packages;
- libtiff, libjpeg-turbo and LibRaw from their upstream sources with our own build files in
  `deps/`, as OpenReliant does for FreeType and libarchive. libjpeg-turbo's SIMD code needs NASM
  on x86, so it builds without it at first.

libsane and the TWAIN DSM are the exceptions: they belong to the system, because the system's
scanner configuration comes with them.

## 13. Licence

MPL-2.0, as openreliant-editor. The licence is per file: a changed negscan file stays MPL-2.0, and
negscan can be combined with code under other licences.

What that rules out, and how negscan keeps to it:

- No code is ported from GPL projects. The inversion follows darktable's published model, written
  from the equations (section 7).
- No data under the GPL or CC BY-SA. The stock presets are our own readings of the makers'
  datasheets (`data/stocks/README.md`).
- GPL programs stay outside negscan: SANE and its backends, our V200 driver among them, are loaded
  at run time, and SANE's licence makes an exception for programs that use its library.
- LibRaw is linked statically under LGPL-2.1, which needs users to be able to relink it with
  their own LibRaw. negscan's source and build are public, which allows that.

The Frontier emulation LUT is negscan's own transform of the colour cube's numbers from the
Frontier software (section 10). None of Fujifilm's code or other tables are in the repository.

## 14. Build, platforms, tests

- **Build.** `zig build`, `zig build test`, `zig build run`, and `zig build check` for fast
  compile errors. A Makefile wraps them with `make help`, as in the editor. The first build
  fetches and builds every library. Nothing is needed from Homebrew or apt except SANE itself,
  for scanning.
- **Platforms.** macOS arm64/x86_64, Linux x86_64/arm64 and Windows x86_64. All of them can be
  cross-compiled from the Mac, as the editor is. Scanning on Windows can only be tried on a
  Windows machine.
- **Tests**, in `test` blocks next to the code:
  - the pipeline against reference formulas: the inversion model against the equations in
    section 7, worked by hand for a few pixels.
  - golden images: frames of our raw V200 colour strip (`vendor/hw-scans/2026-10-22-colour/`),
    developed automatically on the base in their gaps, keep their mean colours in Neutral and
    Frontier emulation (`src/core/scans_test.zig`, skipped where the scans aren't present);
  - frame detection: recorded previews with hand-marked boxes, plus generated strips with known
    boxes, dark frames and mixed panoramas;
  - the SANE layer against SANE's `test` backend, and the V200 on hardware;
  - linearity: a step wedge scanned on the V200 at gamma 1.0, to confirm the output is
    proportional to transmission. This hasn't been measured yet.

## 15. Phases and open items

Phases, each ending with something usable:

1. **Core and CLI:** TIFF and camera RAW in, flat field, base, the inversion model, B&W and
   positive paths, TIFF and JPEG out with ICC. Tested on our V200 scans.
2. **Frame detection** and `negscan detect`.
3. **GUI on files:** roll browser, viewer, develop panel, histogram, before/after.
4. **Scanning:** SANE with the V200 profile, preview, detection, batch scan; then TWAIN.
5. **Presets:** film types, tone and WB modes, stock starting points.
6. **Looks:** Frontier emulation (section 10), imported .cube LUTs, and the fitting tool to check
   it against lab scans and make looks of the user's own.
7. **Export extras:** metadata, HDR with gain maps, and Apple Photos on macOS.

Open items:

- Frontier emulation is checked only by eye so far. A lab's Frontier scans of the user's
  negatives would measure it.
- Windows scanning needs a Windows machine with a scanner for testing.
- macOS's own scanner framework (ImageCaptureCore) would add scanners SANE doesn't drive. It's
  not in the plan; it can be added as another variant of `Scanner` if needed.
- The app's name. "Negative Space" is taken by something close: negativespaceapp.com announces
  "the complete workflow tool for analog photographers" (rolls, scans, archive). DarkSlide is
  an existing film negative converter on GitHub.
