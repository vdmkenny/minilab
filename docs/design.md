# minilab: design

This is how minilab works and why it works that way. minilab is an app for scanning and developing
film. It does four things:

- it scans a roll on any scanner the system can drive (SANE on macOS and Linux, TWAIN on Windows),
  or imports camera RAW files and scans made with other software;
- it finds the frames;
- it turns negatives into positives and corrects their colour, working in density (section 7
  explains what that means), with an inversion model based on darktable's;
- it exports finished files.

35mm is the default, and most other formats work too. It's written in Zig 0.17 with a Dear ImGui
interface.

Most of what's described here is built. Section 15 lists what isn't yet.

## 1. What we take from the reference apps

Two existing apps shaped the design. Neither is open source, so all we know about them is what
they publish.

[f8 Develop](https://develop.atf8.app/) (macOS). From its product page:

- it measures the film base (the clear film with nothing exposed on it, orange on a colour
  negative) from the rebate, the strip of film around the pictures, once per roll;
- it organises rolls as sessions with a film stock, date and location;
- it develops a whole roll in one go, without changing the scans, and you can develop it again
  later;
- it writes camera, lens, film stock and copyright metadata into the exported files;
- it exports HEIC, TIFF and JPEG, including HDR HEIC with Apple's adaptive gain map.

[Negative Lab Pro](https://www.negativelabpro.com/guide/basics/) (a Lightroom plugin). From its
guide, its presets come in independent layers:

- colour model: Basic, Frontier, Noritsu, B+W, None;
- pre-saturation;
- tone profile: Cinematic (log), LAB (standard, soft, hard and highlight/shadow variants), Linear
  (gamma, deep, flat);
- white balance: auto-neutral, auto-warm, auto-cool, auto-average, or fixed per film family
  (Standard, Kodak, Fuji, Cine-T, Cine-D);
- LUTs: Natural, Frontier, Crystal (Crystal Archive paper), Pakon;
- a "border buffer" that leaves the edges of the frame out of the analysis;
- separate colour balance for highlights, midtones and shadows.

We borrow the ideas: measuring the base from the film itself, a roll as the unit of work, layered
presets, syncing settings across a roll and colour balance per tonal range. We don't take any
preset values from either app. We don't have them and they aren't published. Every built-in preset
in minilab says where its numbers come from (section 9).

## 2. Scope

What's in:

- colour negative, B&W negative, colour positive (slide) and B&W positive film;
- scanners:
  - through SANE on macOS and Linux, so any scanner SANE supports. The Epson V200 goes through
    our build of Epson's epkowa backend and its plugin, unchanged.
  - through TWAIN on Windows, with the scanner maker's own driver.
- camera scans: RAW files from a camera pointed at the film over a light source, read with
  LibRaw;
- linear TIFFs from other scanning software (VueScan, SilverFast raw output);
- all common film sizes and formats, with one format per roll;
- automatic frame detection that keeps the format's aspect ratio, plus boxes drawn by hand;
- dust removal from the scan itself, for any scanner or camera, without an infrared channel;
- macOS, Linux and Windows, each on x86-64 and Arm.

What's out, at least for now:

- dust and scratch removal with an infrared channel (the V200 doesn't have one);
- grain, halation and other film simulation effects;
- stitching several camera shots of one medium format frame.

## 3. Architecture

```
     app/, ui/, platform/   the GUI: Dear ImGui via Dear Bindings, on SDL3 and SDL_GPU
     main.zig               the command line
                                         |
   ---------------------- the core: works without a window ----------------------
   core/      the colour pipeline, looks, rolls on disk, calibration, export
   frames/    film formats and frame detection
   scan/      scanners: SANE and TWAIN behind one interface
   io/        file formats: PNM and PNG in Zig; TIFF, JPEG, camera RAW and ICC
              profiles through the C libraries in deps/
   looks/     fitting a look to pairs of scans
   presets/   film stocks, the Frontier LUT and the list of bundled film looks
   -------------------------------------------------------------------------------
```

- **Zig 0.17, written idiomatically.** CONTRIBUTING.md has the conventions and the spelling
  rules.
- **The core** is everything you can test without a window: the pipeline, frame detection,
  scanner sessions and file handling. `zig build test` runs its tests without a scanner or a
  display.
- **The app** is one program. Run it with no arguments and you get the GUI. Commands such as
  `minilab develop`, `minilab detect` and `minilab scan` run the core from the command line, for
  batch work and for testing.
- **Dear ImGui.** Dear ImGui is C++, so we use it through Dear
  Bindings' C API. The translate-c package turns one header, `src/platform/c.h` (SDL3, `dcimgui.h`
  and its SDL3 and SDL_GPU backends), into the `c` module. We tried zgui, the Zig-native wrapper,
  but it doesn't build with Zig 0.17: it uses `std.meta.fields`, which 0.17 removed.
- **Threads.** The UI runs on the main thread. One scan thread owns the scanner, because SANE and
  TWAIN calls block and neither library can be called from two threads at once. A render splits
  the picture into bands of rows and develops them on all the cores at once (up to 16). Exports
  and look fitting run in the background.
- **Pixels.** Scans are 16 bits per channel, on disk and in memory. Developing works in 32-bit
  floats. Develop shows a copy reduced to about screen size, so moving a slider re-renders a few
  megapixels instead of the whole scan. Only export renders at full resolution.
- **CPU, not shaders.** The pipeline runs on the CPU, split over the cores. A 35mm frame at
  4800 dpi is 6803 × 4535 px, about 31 megapixels. Per pixel, the work is one log, a 3×3 matrix,
  one exp and a curve per channel, so a full render should take well under a second on 8 cores.
  We've measured the preview: Develop renders its 754 × 1131 preview with Frontier emulation in
  about 40 ms on a 12-core M-series Mac. Because there's only one implementation, the preview and
  the export always match, and both are testable. The GPU only draws the UI and shows the finished
  preview as a texture.

## 4. Workflow

The GUI has five workspaces. They're mocked up in the "minilab GUI" design canvas:

- **Rolls:** a contact sheet per roll, with its film strip, date and how many frames are
  developed. Frames you haven't developed yet show the raw scan.
- **Scan:** the scanner settings, the preview with the frames it found, the selected frame's crop,
  and the scan queue.
- **Develop:** the roll's frames, a viewer that can split the negative and the positive, and the
  develop settings.
- **Export:** which frames, the file settings and the metadata.
- **Looks:** the built-in and bundled looks, Frontier emulation, and fitting a look from reference
  pairs.

The steps for a roll on a scanner:

1. **New roll.** Film type, stock (optional), format, camera, lens, date and notes. These are
   saved in the roll's folder (section 11).
2. **Preview.** Scan the scanner's whole film area at low resolution.
   - On the V200 that's the 33.02 × 244.348 mm transparency window (the backend's `-x` and `-y`
     range). For comparison, Epson's own software previews a strip at 384 × 2885 px, 300 dpi.
   - The first scan after the scanner is switched on comes out about 1% brighter and a few pixels
     off (we measured this while working on the V200 driver). So the preview also warms the
     scanner up before the scans that matter.
3. **Detect frames** (section 6), and fix them by hand where needed. Untick Scan this frame for
   frames you don't want, to save time: they stay grey on the preview and the scan skips them.
4. **Scan.** One scan per frame at the resolution you chose: linear, 16-bit, with a margin around
   the detected box. Across the strip it takes the whole film area, or in a holder with several
   strips side by side, the frame's own strip and half the holder to the next one. The margin
   is there for two reasons:
   - the strip moves 11 to 14 lines between sessions (again from the driver work);
   - the margin takes in the gap between frames, which is where the film base gets measured.
5. **Refine.** Detect the frame again on each full-resolution scan, tighten the crop, and measure
   the film base in that scan's own margin.
6. **Develop.** minilab works out automatic settings for each frame. Adjust them, pick a look,
   remove dust if you want, and sync settings across the roll.
7. **Export.** TIFF (16 or 8 bit) or JPEG. HEIC with a gain map will come later; Export already
   shows it, greyed out.

Camera scans and imported files skip steps 2 and 4. You import RAWs, linear TIFFs or PNM scans
into a roll (`minilab import`, or drop them on the roll in the app), detect or draw the frames, and
carry on from step 5. A file with one frame on it becomes one frame. A strip, say from VueScan or a
flatbed, becomes one frame for every whole frame on it. Those frames share the one stored scan,
and each has its own crop and its own film base, from the gaps beside it.

## 5. Inputs

### Scanners

The scanner code (`src/scan/`) puts SANE and TWAIN behind one interface: a `Library` and a
`Scanner`, each a tagged union over the two. The rest of the app sees the same operations on every
OS: list the devices, read what a scanner can do, scan an area and cancel. A preview is just a
low-resolution scan of the whole area.

**SANE (macOS, Linux).**

- minilab loads libsane when it runs (`std.DynLib`), not when it's built, so it starts fine
  without SANE. The types come from `sane.h`, which is public domain.
- On macOS, where hardly anyone has SANE, the release carries its own in a `sane` folder next to
  the program: libsane and every sane-backends backend that builds on macOS, with libusb and
  libjpeg-turbo (`scripts/build-sane-macos.sh`, section 12). minilab tries it first. Before SANE
  starts, minilab points `SANE_CONFIG_DIR` and the dll backend's search path (`LD_LIBRARY_PATH`,
  which the dll backend reads on every system) at the bundle's folders first and then the
  system's (Homebrew's and MacPorts'). The bundle has no `dll.d`, so SANE reads the system's,
  which is where the V200's epkowa backend is switched on, and finds epkowa in the system's
  backend folder.
- If that SANE doesn't load, or on Linux, minilab loads the system's libsane, with the system's
  own configuration.
- Options are set by name. SANE's standard names (`source`, `mode`, `depth`, `resolution`,
  `tl-x`, `tl-y`, `br-x`, `br-y`, `preview`) work with every backend. Backend-specific ones, like
  epkowa's `film-type` and `gamma-correction`, come from a scanner profile or from raw setup
  (both below).
- Scan's resolution menu only lists what works raw. minilab puts the scanner in its raw setup,
  then tries each resolution the backend lists and keeps the ones it takes as they are, still at
  16 bits.
- Cancel calls `sane_cancel`. On the V200 the plugin then reads the rest of the scan anyway, so
  that the scanner stays usable. That takes as long as the rest of the scan would have, so the UI
  shows "finishing" until it's done.
- sane-backends ships a `test` backend that makes up frames (Homebrew has `libsane-test.so`).
  The tests use it where libsane is installed, so the SANE code gets tested without a scanner.

**TWAIN (Windows).**

- minilab loads the TWAIN data source manager (`TWAINDSM.dll`) when it runs, like other TWAIN
  apps do, and drives the maker's data source (its driver) with the driver's own window hidden,
  where the driver allows that (`CAP_UICONTROLLABLE`).
- The standard has capabilities for film: `ICAP_LIGHTPATH` (`TWLP_TRANSMISSIVE`),
  `ICAP_FILMTYPE` (positive, negative), `ICAP_BITDEPTH`, `ICAP_GAMMA` and `ICAP_FRAMES`. How much
  of that each maker's driver supports, we can only find out scanner by scanner.
- The resolution menu leaves out anything above the source's native resolution
  (`ICAP_XNATIVERESOLUTION`), where the driver makes pixels up.
- On Windows the V200 runs on Epson's own TWAIN driver (Epson Scan), not on our plugin. Whether
  Epson's driver gives linear 48-bit data without showing its own window, we won't know until
  someone tries it on Windows.
- `twain.h` carries the TWAIN Working Group's copyright but no licence terms, so we don't include
  it. Our Zig declarations of the structures and constants we use are written from the TWAIN
  specification.
- The TWAIN code is untested so far. It was written from the specification without a Windows
  machine or a TWAIN driver to try it on. It compiles for Windows, and its structure sizes are
  checked against the specification, but none of it has run yet.

**Scanner profiles.** A profile is the set of option values that makes one scanner model give
linear, unprocessed data. Profiles live in a table in `src/scan/root.zig`, matched by SANE backend
and model name. We have one so far, for the V200, from our own measurements:

- mode `Color`, `gamma-correction` `User defined (Gamma=1.0)`, scanning from the transparency
  unit at 16 bits per channel;
- the colour matrix set to the identity (`cct-1` to `cct-9`). The backend's default matrix mixes
  the channels to make the picture more saturated, which we don't want;
- film type `Positive Film` for every film, negatives included. `Negative Film` takes the orange
  mask out inside the scanner, so the film base can't be measured beside the frames any more, and
  it clips blue on B&W film. minilab inverts the raw scan itself;
- the film type is set before everything else, the way scanimage does it, in case the backend
  resets its colour settings when the film type changes.

The V200's backend offers 300, 2400 and 4800 dpi. We checked the profile on the V200 with a colour
strip: `minilab scan` gives the same values as `scanimage` with the same options, within 2% in
every channel.

**Scanners without a profile: raw setup.** minilab scans in colour at the deepest bit depth the
scanner has, and sets the rest from the options the backend lists (`rawControls` in
`src/scan/root.zig`): the film type to positive (first, as with a profile), gamma to 1.0 (a gamma
choice that says so, or the gamma tables filled with a straight line), colour correction off, and
brightness and contrast to 0 where 0 is the middle of their range. An option the scanner won't
take is skipped and logged. On the V200 this gives the same data as its profile.

The Scanner settings window on Scan sets any of those options another way, per scanner and driver,
for when raw setup guesses wrong. The changes are kept in the library's `scanners.json`.

A scanner that can't give linear data at all could still be used if we undid its curve: a scan of
a transmission step wedge (a strip of known densities, such as a Stouffer T2115) would measure
that curve. That isn't built yet.

### Camera scans

LibRaw decodes the RAW file with no white balance, no colour matrix and no gamma. That gives
linear 16-bit data in the camera's own channels, which is what the density stage wants
(section 7).

- LibRaw leaves the numbers unscaled, so we scale them to put the sensor's white level at full
  scale.
- A flat-field shot evens out the light. It's a shot of the light source with no film in front of
  it, at the same exposure as the frames. You take it once per session and the roll keeps it:
  `minilab import --flat`, or the New roll form for a camera roll. Frames imported after it are
  divided by it (section 7, Linearise). Frames already in the roll stay as they are.
- The film base comes from the rebate in the frame, same as for scans.
- For a colour slide, the frame keeps the RAW file's own colour information: the camera's white
  balance and its colour matrix (section 7).

### Files

minilab reads TIFFs from other software, RGB or greyscale, in any compression LibTIFF decodes, and
binary PNM, which is what SANE's scanimage writes. They should be 16-bit and linear. 8-bit files are
read too, with a warning: 8 bits is too few for linear data, so an 8-bit file almost always has a
gamma curve applied, and nothing undoes that yet.

A roll stores every raw scan as a 16-bit PPM, whatever it was imported from, so the rest of the app
only has to read one format.

**Finished scans.** Lab scans, and scans from a scanner that inverts by itself (say a Kodak slide
scanner), arrive as finished positives in JPEG. minilab doesn't invert them. The roll keeps the JPEG
exactly as it came, copied or moved into `scans/`, and reads it by undoing the sRGB curve, so the
pipeline works in linear light. Each frame is saved as developed, with `finished` settings: a
positive at an exposure of 1, which gives back the picture as it was. Automatic settings and Reset
leave a finished frame that way, and the look, saturation and exposure still work on top. A roll
that starts with JPEGs has Finished scans as its input; its film type and stock stay what the film
was, as metadata. A JPEG's embedded ICC profile isn't used yet: lab scans are almost always sRGB.

**Folders and the library on disk.** `minilab import` and a drop on a roll's row take folders: a
folder stands for the scans directly in it, in natural order (2 before 10). The app looks at the
library's folders every two seconds, and reads the rolls again when one was added, removed or
renamed, or a roll's frames changed. Saving a file in place doesn't count, so its own saves don't
trigger it.

## 6. Film formats and frame detection

A roll has one format. Frames of different formats never share a roll. The format is the starting
point for detection, but real frame sizes vary from camera to camera, which is why detection
measures them. Nominal picture sizes, in mm:

| Film size | Formats |
|---|---|
| 135 | full frame 36 × 24 (the default, 38 mm pitch), half frame 18 × 24, panorama 65 × 24, square 24 × 24 |
| 120 / 220 | 6×4.5 56 × 41.5, 6×6 56 × 56, 6×7 56 × 69.5, 6×8 56 × 76, 6×9 56 × 84, 6×12 56 × 112, 6×17 56 × 168 |
| 127 | 4×4 40 × 40, 4×6.5 40 × 65, 3×4 30 × 40 |
| 110 | 13 × 17 |
| 126 | 28 × 28 |
| APS | H 30.2 × 16.7, C 25.1 × 16.7, P 30.2 × 9.5 |
| Minox | 8 × 11 |
| Sheet film | 4×5 in, 5×7 in, 8×10 in, 9×12 cm, 13×18 cm; the picture area depends on the holder |
| Glass plate | quarter, half and whole plate; 6.5×9, 9×12 and 13×18 cm; lantern slides, 3¼×3¼ in and 3¼×4 in |

The pitch is the distance from one frame to the next. The V200's 33.02 mm window takes 35 mm wide
film (135 and 126), and narrower film (110 at 16 mm, APS at 24 mm, Minox at 9.2 mm) if a holder
keeps it flat. 120 and anything wider needs another scanner or a camera.

Film holders usually cover the edges of the film, but a little clear film beside the picture
still shows. So detection measures each picture: along the strip between the gaps either side of
it, and across from where the exposure starts. Scan's Frame detection menu then fits each frame
to its picture. Preserve aspect ratio puts the biggest box of the format's ratio inside it, and
Detect full frame takes the picture's own edges, so frames that aren't quite the format's size
need no cropping by hand.

Detection on a strip preview works like this for negatives (`src/frames/detect.zig`):

1. **Classify.** The holder, and anything else outside the film, lets almost no light through.
   The film base between frames is the clearest part of the film. The pictures are somewhere in
   between.
2. **Opening.** Fit lines to the two long edges of the light band. These are usually the holder's
   edges, not the film's, and they give the strip's angle and the frame height. Where 135's
   perforations (the sprocket holes) show, their bands are left out. A flatbed's film holder
   can have several openings side by side, like four rows of 35mm: each light band at least half
   a frame tall is one, and the steps below run on each opening with film in it. An opening with
   nothing in it shows flat, bare light.
3. **Gaps.** Walk along the strip and take the median density of each line across the band. A
   line counts as gap when it's at base density and flat (even a thin picture still has some
   texture). Where a strip is shorter than its opening, bare light shines past its end. That's
   lighter than any film, so it's left out before the base density is measured. Each run of
   picture between gaps has two ends. An end is sharp when the density
   steps up within half a millimetre, soft when it doesn't, or cut off by the end of the film or
   the scan.
4. **Measure the picture.** Along the strip, a frame's picture runs between its gaps. If its
   length is far from the strip's other pictures, it's marked for checking. One sharp end is
   enough to place a frame whose other end doesn't show. Across the strip, going in from the
   holder, the film shows its clear edge and then the picture: the edge is halfway up that step,
   so a blurry scanner doesn't make the picture bigger. The film sits in the same place across
   the holder for a whole strip, so an edge that doesn't show, like a dark scene there, takes the
   strip's usual one. This also finds pictures well short of the opening, like a compact
   camera's masked panorama.
5. **Weak frames.** A frame of a dark scene is close to base density, so its edges hardly show.
   Missing edges are filled in from the pitch: measured between sharp edges where they repeat,
   or else the format's fixed pitch. Those frames are marked for checking too. 120 and other films
   without perforations have no fixed pitch, so there you'll more often fix weak frames by hand.
6. **Inset.** By default there's none. In Scan you can take a share off each side of a frame,
   for when the opening is wider than the picture, like a 35mm holder with a 120 mask.

Positives take the same steps with the gap test turned around: on unmounted slide film the gaps
are unexposed, so they're dark instead of clear. Mounted slides are found by their openings
instead, each one measured on its own. A camera scan usually holds one frame, so the same steps
find its edges in that one picture and skip the pitch. A file with two or more whole frames on it
is treated as a strip: each whole frame becomes a frame of the roll, and frames cut off by the
edge of the scan are left out.

By hand, you can:

- drag a frame along the strip, and drag its edges and corners;
- add, delete and split frames;
- rotate them;
- lock the aspect ratio to the roll's format or a ratio of your own, or leave it free.

Frames you've edited by hand are kept when detection runs again.

## 7. The colour pipeline

### Why density

Density is how much light the film blocks, on a log scale: D = −log10(T), where T is the share of
light that gets through. A density of 1 lets 10% through and 2 lets 1% through. Film behaves
simply in density: over most of its range, each dye layer's density goes up in a straight line
with the log of the exposure, and dyes stacked on top of each other add their densities. So that's
where minilab does its colour work.

### The model we start from

We start from darktable's negative inversion model, as its documentation lays out the maths.
minilab's code is written from these equations, not translated from darktable's C, so minilab can
keep its own licence (section 13). T is the pixel's transmission and T_base the film base's, per
channel:

```
d   = log10(T / T_base)                                   (density above base, ≤ 0)
c   = (wb_high / D_max) · d  +  wb_high · offset · wb_low
p   = max(exposure · (1 + black − 10^c), 0) ^ gamma       (inversion)
out = p                                    if p ≤ s
      s + (1 − e^(−(p − s)/(1 − s))) · (1 − s)   otherwise  (s = highlight roll-off)
```

darktable's colour film preset sets D_max 1.6, offset −0.05, black 0.0755, gamma (contrast) 4.0,
roll-off 0.75 and exposure 0.9245. Its pickers work out:

- D_min from a sample of the base;
- D_max from the densest part of the negative;
- the offset from the least dense part;
- the two white balances (wb_high and wb_low) from neutral samples in the highlights and the
  shadows.

Dividing by the base cancels out any fixed gain per channel in the scanner. That's why the V200's
Negative Film mode, which changes the exposure per channel, makes no difference to the result,
apart from giving blue more levels.

### What minilab does

Each stage has its own settings. Dust removal, when it's on, works on the frame's scan before stage
2 (see Dust, below).

1. **Linearise.** Scans from a scanner with a profile are linear already, because the profile sets
   the scanner up that way. Camera scans are divided by the flat field here, on import. The flat
   field is smoothed first: it's averaged over a grid of 64 cells along its longer side, and the
   grid is blurred over each cell's neighbours. Past the grid's edges it's extended along its own
   slope, so the blur doesn't pull the edges towards the middle. Between cell centres it's
   interpolated, and then it's divided by its brightest value per channel, which gives a gain of
   at most 1 at each point. Dust on the light source and noise drop out, and the fall-off towards
   the edges stays, which is what we want to correct.
2. **Base.** Divide by T_base. Each frame's base is measured in the gaps beside it (section 4). The
   roll's base is the median over its frames. If a frame's own base is more than 15% off the
   roll's in any channel, say because a gap fell on the leader, a light leak or the holder, that
   frame uses the roll's base instead.
3. **Density.** d = −log10(T / T_base), in the scanner's or camera's own channels, before any
   colour matrix: the way a densitometer reads a negative. darktable applies the input profile
   before its inversion; we don't. Dye densities add up in log space, so mixing channels belongs
   in density (the next stage). A matrix on transmission values has no such meaning.
4. **Density correction.** A 3×3 matrix in density, the identity by default. It's there to correct
   crosstalk between the channels and the dyes' unwanted absorptions, and darktable's model has
   nothing like it. After that, if the roll's stock has datasheet curves, each layer's density is
   straightened by its curve (section 9).
5. **Inversion curve.** Each channel's density is scaled by the density range and balanced (a
   slope and an offset per channel, darktable's wb_high and wb_low), then goes through darktable's
   curve, `(1 + black − 10^c)^gamma`, with its highlight roll-off. With the same settings it gives
   the same result as darktable.
6. **Tone and colour.** The tone (section 9) changes the inversion curve's contrast. The colour
   of the light is set as a temperature in kelvin and a tint, separately for highlights, midtones
   and shadows.

   Here's the idea. If the light was warmer or cooler than daylight, every layer of the negative got
   a fixed amount more or less exposure. On the negative that's a fixed density offset per layer, so
   the inversion can undo it with a fixed shift per channel, added before the curve, just like a
   colour filter in a darkroom enlarger. The numbers: take the colour of a black body (an ideal
   light source; its colour depends only on its temperature) at 5500 K over its colour at the chosen
   temperature, per channel. 5500 K is daylight, which daylight film is balanced for, so at 5500 K
   nothing changes. Take the log10 of that, times a colour negative's contrast (0.6), over the
   density range, and that's the shift. The black body's colour comes from Kim et al.'s fit to the
   Planckian locus. The tint is ±100 for half a stop on green. The slider moves in mired (a million
   over the temperature), so equal steps on it are equal changes in colour.

   The three ranges are blended by tone, with weights that add up to 1, so the same light in all
   three is the same shift everywhere. A negative's film base already cancels the colour of the
   light behind the film, so for negatives the camera's white balance in a RAW file isn't used.

   After that comes the look (section 9), then saturation: each pixel mixed with its own
   luminance in linear light, which keeps its hue and its luminance.
7. **Output.** What Develop produces is linear light from 0 to 1, in the scanner's RGB, which we
   take as having Rec. 709's primaries. The viewer shows it sRGB-encoded. Export converts it to
   linear Rec. 2020 (with ITU-R BT.2087's matrix), and Little CMS then converts that to the export
   space: sRGB, Display P3, Adobe RGB or ProPhoto RGB. The space's ICC profile is embedded in the
   file.

B&W negatives use one channel's density (green by default, and you can pick another) and go
through the same stages, minus the colour.

Positives skip stages 2 to 5, the tone and the light: the scan's transmission, times the exposure,
is the picture. The look and saturation still apply. A colour slide shot with a camera needs one
more step, because the roll's scan of it is in the camera's own colour. So at import, the frame
keeps the RAW file's colour information (`develop.SlideColour`): the camera's white balance as shot,
for the light behind the film (or its daylight balance, where the file doesn't have one), then the
camera's matrix to sRGB. With a flat field, which has already made the light white, only the matrix
applies. Slides imported by development builds from before this was added keep the camera's raw
colour.

### Automatic settings

These are worked out for each frame on the middle of the frame (half its width and half its
height), away from the holder. That's the same idea as NLP's border buffer.

- **Base**: from the gaps, as above. Without gaps, the clearest film in the frame.
- **Density range and offset**: the density range from the densest 0.2% of the frame (the
  brightest highlights), and the offset from the clearest 0.5% (the deepest shadows). They do the
  same job as darktable's pickers, without any clicking.
- **White balance**, one of:
  - Auto neutral: makes the highlights and the shadows neutral. This is the default;
  - Auto warm and Auto cool: the same, then a little warmer or cooler;
  - Average: makes the frame's average density neutral;
  - Stock: the stock's own balance, on a calibrated scanner (section 9);
  - Picked: makes a point you click neutral.

These are our own algorithms, so they're written down in the code's docs and covered by tests,
not just buried in the code.

### The loupe

Develop's viewer shows a reduced copy of the scan, so even its 100% view isn't the scan's full
detail. The loupe is: with it on (L, or the Loupe box on the toolbar), a circle follows the cursor
over the picture and shows that spot at the scan's own resolution, one scan pixel to one screen
pixel. It's rendered on its own: the point under the cursor goes back through the turns, the
mirror and the crop to the scan (`Frame.scanPoint`), and a square of the full scan around it is
cut, turned and developed with the frame's settings and look, the same way the preview is. Over the
negative side of the viewer it shows the negative. The full scan is read the first time the loupe
is used on a frame, and kept while the frame is open. The loupe renders again only when the point
or the settings change. A pick (film base or neutral) still works with it on, at its centre.

### Dust

Dust on the film blocks light, so on a raw scan a speck is a small spot that's denser than the film
around it, on a negative or a slide alike. Develop's Dust section turns dust removal on for a
frame. It's off to begin with, it's saved with the frame's settings, and Sync copies it with the
rest (section 8). Without an infrared channel there's no sure way to tell dust from the picture,
so it's something you turn on where it helps, with three limits to keep the picture's own small
highlights:

- **Threshold:** how far above the grain around it a spot has to stand, from 6 to 20 times the
  grain. Lower finds fainter specks. Below 6, the clumps of a fast film's grain start to look like
  dust, so the slider stops there.
- **Max size:** the widest speck, as a share of the frame's longer side, from 0.2% to 1.2%. The
  default, 0.8%, is about 0.3 mm on 35mm film. A smaller size only ever leaves more alone.
- **Max density:** the most a speck can stand above the film around it, from 0.2 D up to Any (no
  limit), the default. The bulbs in a string of fairy lights usually stand further above the film
  than dust does, so a lower limit keeps lights, stars and the like.

How it works (`core/dust.zig`), on the frame's scan, cropped and turned:

1. Each pixel's density, averaged over the channels. A speck adds about the same density wherever
   it lands, on thin film or dense.
2. A grey opening (the minimum over a square as wide as Max size, then the maximum over the same
   square) takes away every bump narrower than the square and keeps the edges of anything bigger.
   The density minus its opening (the top hat) is just the small bumps.
3. The grain around each pixel is the top hat's mean and spread in a ring around it. The ring
   leaves out a square the size of a speck, so a speck doesn't count towards its own grain. A bump
   that stands Threshold times the spread above the mean is a speck, and its fainter edge goes
   with it.
4. Specks close together are grouped, and a group bigger than Max size is texture, so it stays. A
   thin fibre can be twice as long. A speck also stays if it's denser than Max density, if the film
   beside it is much denser on one side than another (it's a highlight on an edge), or if it's the
   peak of a bigger clump, like a lamp's bulb in its glow.
5. Each speck, and a pixel or two round it for its soft edge, is filled the way a healing brush
   does it: with the patch of film nearby whose ring of pixels best matches the ring round the
   speck, evened out to the speck's ring by the plane through the difference between the two. So
   grain, fine or coarse, and the picture's own texture, such as fur, carry on through the speck
   from real film. Where there's no patch to take (at the picture's edge, or among other specks),
   the speck is filled smoothly from its edge inwards. Nothing away from the specks changes.

The sizes are shares of the frame's longer side, so the same specks go at any resolution, from any
scanner or camera. Develop removes the dust from its reduced copy, and keeps the result until the
dust settings or the crop change. The loupe removes it from the full scan around its square, and
export from the frame at the size it's saved at. Thumbnails are usually too small to show dust, and
then they stay as they are. A finished picture, such as a lab's scan, is already a positive,
usually of a negative, so there dust is lighter than around it, and that's what it looks for.

The idea comes from Tea and Tech Time's [automatic sensor dust
removal](https://teaandtechtime.com/automatic-sensor-dust-removal/), for digital camera pictures:
threshold against the neighbourhood, merge busy areas into big blobs, and fill the small blobs that
are left. Its code is GPL-3.0 and uses OpenCV, so minilab's is written from the idea, not from the
code.

## 8. Settings and sync

Every frame has a settings file of its own. It holds the crop, the turns, the film base, the look
by name and every develop setting, fully worked out. So a frame you open again later renders the
same, even if a default changed in between.

The same file holds the frame's rating: 0 to 5 stars, and whether it's rejected. Rejecting keeps
the stars, as Lightroom does, so they come back if you take the reject back. A rating isn't a
develop setting, so it saves straight away, stays out of undo, doesn't count the frame as developed
and never syncs. Export uses it: a star filter chooses the frames with at least that many stars,
and rejected frames start out unchosen. A frame whose rating changes in Develop is chosen again by
the filter; frames you pick by hand otherwise stay picked.

Sync copies some of one frame's settings to the roll's other frames. You choose the groups: the
look (with tone and saturation), the white balance and dust removal are on by default; density,
film base, and crop with turns are there when you want them. Whatever isn't synced, each frame keeps: its own
saved settings, or, if it was never developed, automatic ones measured on its thumbnail. An
automatic white balance is always worked out again on each frame.

## 9. Presets

Presets come in layers, like NLP's, but they're ours, and their sources are written down.

**Film type:** colour negative, B&W negative, colour positive or B&W positive. This picks the path
through the pipeline and the scanner settings.

**Stock** (optional): each layer's characteristic curve, and on a calibrated scanner, the stock's
white balance. The stock presets are built into the program (`src/presets/stocks.zig`).

- **Curves** (`src/core/stock_curves.zig`). A characteristic curve plots a layer's density
  against the log of the exposure. It starts at the base, rises slowly at first (the toe), then
  follows a straight line, and some films flatten out again at the top (the shoulder). The
  inversion assumes the whole thing is a straight line. Read that way, the toe crushes the
  shadows, and since each layer has its own toe, it tints them as well.

  With a stock's datasheet curves, minilab takes each layer's density above the base back to its
  log exposure, then on to the density the curve's straight line would give at that exposure,
  measured from the base. So the base stays at 0, the toe opens up, and the straight part keeps
  its contrast. The straight line is fitted to the middle of the curve's density range (25 to 85
  percent), so it straightens the actual curve it comes from. Right at the base the toe is nearly
  flat: Superia X-TRA 400's would need stretching 15 to 35 times there, which would only blow up
  the grain, so the stretch stops at 3 times. Each layer becomes a 33-point table. It's applied
  after the density matrix, and the automatic settings use it too.
- Datasheet curves are in Status M density: density measured through the standard filters labs
  use for colour negatives. A scanner's channels see the dyes through different filters. On a
  calibrated scanner (see below), each layer's scale is 1 over its calibration factor, with green
  taken as reading Status M. Without a calibration, the scale is 1. On our V200's Superia X-TRA
  400 frames, the calibrated scale keeps neutrals neutral, where plain Status M leaves a slight
  magenta in the light greys.
- **Datasheet corrections** is a checkbox under Stock, on by default. Turning it off switches the
  curves and the stock's balance off for the roll, so the stock is just metadata.
- Choosing a stock, or calibrating, measures the roll's developed frames again with the curves:
  the density range, offset and balance. Your other settings stay. Frames you haven't developed
  yet get the curves when you open them. On a calibrated scanner, frames on Auto neutral switch to
  the stock's balance.
- Where the numbers come from: the makers' datasheets. The characteristic curves and figures are
  our own readings of the published charts. `data/stocks/README.md` records each stock's
  datasheet, its edition and how accurate the reading is. We don't store the PDFs.
- **Calibration** (`src/core/calibration.zig`). A datasheet gives each layer's contrast (its
  gamma: the slope of the straight part of the curve) in Status M density, and a scanner's
  channels don't match Status M. On our V200 a colour negative's red needs 1.3 to 1.7 times
  blue's slope, where Status M says 1.14. Used as they are, a stock's gammas turn skies cyan. So
  the Stock balance needs the scanner calibrated, once, on any roll of a stock that has a preset:
  - each frame's automatic balance gives the slopes that make that frame's neutrals neutral;
  - the median over the roll leaves out the colours of the scenes themselves;
  - divide that by the stock's datasheet slopes, and you get the scanner's factor per layer.

  A stock's balance on that scanner is then its datasheet slopes times those factors. This works
  for any scanner or camera whose channels each mostly see one dye. Each scanner is calibrated
  under the name its rolls record, and more rolls refine it, as the median over all of them.
  Calibrations are kept in the library's `calibration.json`. On the V200, a roll of Superia X-TRA
  400 gave red ×1.23 and blue ×0.94.
- The Stock balance keeps the light the roll was shot in: every frame gets the same layer slopes,
  and only its shadows are balanced on the frame itself. Auto neutral, the default, neutralises
  each frame instead.

**Look:** what comes after Develop's settings. Develop lists every look in one drop-down.

- **Neutral:** what Develop gives you, the inversion curve with nothing added.
- **LUT looks:** a LUT (lookup table) maps each input colour to an output colour. minilab reads
  .cube LUTs: 1D, 3D, or a 1D shaper followed by a 3D LUT, of any size and input range. The LUT is
  applied to Neutral's sRGB-encoded output, with tetrahedral interpolation between its points.
  Tone, balance and the rest of Develop's settings still apply under it. minilab ships Frontier
  emulation (section 10) and the film looks below, and you can import any .cube that expects sRGB
  or Rec. 709 input. Imported LUTs are copied into the library's `Looks/` folder.
- **Film looks:** LUTs from three free collections, listed in `src/presets/looks/bundled.zig`
  with each one's film, name and file:
  - GlassMeter (CC BY 4.0): 30 .cube files at 33³;
  - t3mujinpack (MIT): 51 HaldCLUTs at 144³. A HaldCLUT is a 3D LUT stored as a PNG picture;
  - Street Monochrome (CC BY 4.0): four .cube files at 64³.

  `build.zig.zon` fetches the collections at pinned commits. At build time,
  `src/bake_looks.zig` samples every look at 33³ with tetrahedral interpolation and writes them
  all as 16-bit values into one 18 MB file, which the program embeds. A look's table is decoded
  the first time a frame uses it. Develop's Look menu has a submenu per collection, grouped by
  film, and the Looks workspace shows each collection's credit, licence and what we changed.
- **Fitted looks:** made in the Looks workspace from pairs of our raw scans and a lab's scans of
  the same negatives. A fitted look takes over after the film base and density stages, with its
  own curves, a density matrix and optionally a 3D LUT. Tone and the inversion settings don't
  apply to it.

A frame keeps its look by name: `neutral`, `frontier`, `<collection>:<look>` (such as
`glassmeter:kodak-portra-400`), `cube:<name>` or `look:<name>`. A film look's name never changes
once it's released. If a look can't be read, the frame develops as Neutral, with a warning.

**Tone:** Standard is darktable's curve as set. Soft and Hard use 0.8 and 1.25 times its
contrast. Linear has no contrast curve and no roll-off, so it's linear in the film's exposure, and
Log stores the density itself, from 0 to 1. Linear and Log are flat starting points for grading in
other software.

**White balance:** the modes from section 7.

**Where presets live.** The stocks and the bundled looks are built into the program. Your imported
LUTs and fitted looks go in the library's `Looks/` folder, and scanner calibrations in the
library's `calibration.json`.

## 10. Frontier emulation

Frontier emulation (that's its name in the app) gives a frame the colour of a scan from a
Fujifilm Frontier, a common lab scanner. It's a subtle change on top of Neutral, not a
different development: tone, neutrals and lightness stay the same as Neutral's.

**Source.** The colour cube in the Frontier 350's scanning software (A1 7.6-0E-920, a licensed
copy). It's a 32³ table from the tone curve's 10-bit output to 8-bit monitor RGB, with the
software's saturation matrix in front of it. We use nothing else from the Frontier.

**Why only the cube.** The Frontier develops a negative through its own chain: density, a grey
axis set per roll, a film curve, a tone curve per channel, the saturation matrix and the cube.
Its tone curve and the cube's grey axis add up to a hard S-curve, and its curves expect the
Frontier scanner's densities. On another scanner's raw scans the whole chain comes out contrasty
and oversaturated. What makes a Frontier scan look like a Frontier scan is how the cube renders
colours compared with greys, and that part doesn't depend on the scanner.

**How the LUT is made** (`src/presets/looks/frontier.cube`, 33³). For Neutral's sRGB-encoded
value `d`:

    f = d + cube(S w) − grey(w),   w = grey⁻¹(d) per channel

Here `grey` is the cube's output along its grey axis, per channel, `grey⁻¹` goes back the other
way through the channels' mean, and `S` is the saturation matrix at the Frontier's standard setting
(1.2 on the diagonal, −0.1 everywhere else). A grey comes out the way it went in, and a cube that
treated each channel on its own would change nothing. The result keeps `d`'s Oklab lightness and
takes its hue and chroma from `f`.

**What it does.** Over sRGB's colours of middle lightness, the average chroma (how colourful they
are) ends up at 0.96 of Neutral's. The standard saturation puts back what the cube takes out
(without the saturation matrix it's 0.82). Greens lose about a fifth of their chroma and turn 10
to 15° towards teal. Skies, skin and yellows gain 5 to 20%, and reds turn a little towards orange.
On average the baked LUT is within a quarter of an 8-bit step of the exact transform, and greys
within 3·10⁻⁶.

**B&W.** The Frontier has no colour table for B&W. Its software runs B&W negatives through the
same chain, with a gentler straight line in its 10-bit density stage (slope 0.92) and a saturation
setting that turns the channels grey before the cube. So its B&W look is tone only, and Frontier
emulation leaves B&W frames the way Neutral has them. Going by their names and sizes, the
installer's other B&W files (`PARAM/imgp/*bw.dat`) are the skin, sky, grain, clipping and
sharpening settings, not colour tables.

**Checking it.** The plan is to take negatives that a lab has scanned on a Frontier, scan them raw
on the V200 too, and compare each pair in the Looks workspace, which lines the two scans up and
measures the difference (the median and 95th percentile of ΔE2000, a standard measure of colour
difference). The same workspace fits looks for labs whose software we can't get, such as a
Noritsu.

## 11. Files on disk

A library is a folder of rolls, and a roll is a folder:

```
Rolls/
  calibration.json       scanner calibrations (section 9)
  scanners.json          changes to raw setup, per scanner (section 5)
  Looks/                 imported LUTs and fitted looks
  2026-10-22 Portra 400 Ghent/
    roll.json            film type, stock, format, camera, lens, dates, notes, scanner, own fields
    flat.ppm             camera rolls only: the flat field, as shot
    scans/01.ppm ...     raw linear 16-bit scans, converted from TIFF or RAW on import and
                         never changed; the frames of a strip share one. Finished scans
                         are kept as their own JPEGs (scans/01.jpg)
    frames/01.json ...   crop, turns, film base, look, develop settings (worked out), rating
    thumbs/01.ppm ...    reduced copies of the scans, for quick previews
    preview.ppm          the last preview of the film holder, from Scan
    preview.json         the frames' boxes on that preview, hand edits included
    exports/
```

Exports carry the roll's metadata (camera, lens, film stock, date, copyright, how the frame was
developed, and its rating as `xmp:Rating`: 1 to 5 stars, or -1 for rejected, the way Lightroom and
Bridge read it). The roll's notes go in as the caption (`dc:description`), and fields of your own
as `minilab:Fields`, a list of name and value pairs. You can change the camera, lens, date shot,
copyright and notes, and the fields, in Export's Metadata section at any time; each one saves to
`roll.json` when you leave its box. EXIF and XMP both go inside the file. XMP is where the film
stock and develop settings go, since EXIF has no fields for them. There's no sidecar: Lightroom,
Capture One and darktable read XMP from inside a JPEG or TIFF. We
write both in Zig: we only need a handful of tags, and exiv2, the usual library for this, is C++.

## 12. What we reuse

| Part | What for | Licence |
|---|---|---|
| Dear ImGui, docking branch | the GUI | MIT |
| Dear Bindings | a C API over Dear ImGui, for translate-c | MIT |
| translate-c package | turns C headers into a Zig module | MIT |
| SDL3 (castholm/SDL's Zig build) | window, input, GPU (Metal, Vulkan, D3D12) | zlib |
| IBM Plex Sans, JetBrains Mono | the interface's fonts | SIL OFL 1.1 |
| sane-backends 1.4.0: libsane and its backends (carried by the macOS release, the system's elsewhere; loaded when minilab runs) | scanners on macOS and Linux | GPL-2.0+ with SANE's exception, 15 backends GPL-2.0 alone (section 13); `sane.h` public domain |
| libusb 1.0.30, libjpeg-turbo 3.2.0 (carried by the macOS release, for SANE) | USB, and JPEG for the backends that need it | LGPL-2.1+; IJG and BSD |
| our epkowa build and `libesint7A` | the V200, unchanged, loaded by libsane | GPL-2.0+ |
| TWAIN DSM (the system's, loaded when minilab runs) | scanners on Windows | LGPL-2.1 |
| darktable's negative inversion model | the equations and their defaults, written in Zig from the maths; no darktable code | (credited; nothing copied) |
| film makers' datasheets | stock presets: our own readings of the published charts (`data/stocks/README.md`) | the numbers are ours; the PDFs aren't stored |
| LibRaw | camera RAW | LGPL-2.1 or CDDL-1.0 (minilab uses it under LGPL-2.1) |
| libtiff, libjpeg-turbo, Little CMS 2, zlib | file I/O, colour management | BSD-like, BSD/IJG, MIT, zlib |
| the V200 driver repo: `tools/imgcompare`, test data | how to line up two scans; our V200 scans as test inputs | ours |
| GlassMeter Film Looks (Glass Works) | 30 film looks, baked in | CC BY 4.0 |
| t3mujinpack (João Almeida) | 51 film looks, baked in | MIT |
| Street Monochrome (Ivan Bogachev) | B&W looks, baked in | CC BY 4.0 |

`build.zig.zon` fetches the libraries, fonts and look collections at pinned versions, and
`zig build` builds the C and C++ ones:

- Little CMS and zlib come from allyourcodebase's Zig packages;
- libtiff, libjpeg-turbo and LibRaw are built from their upstream sources with our own build
  files in `deps/`. libjpeg-turbo is built without its SIMD code, so you don't need NASM.

SANE and the TWAIN DSM are the exceptions. They're loaded when minilab runs, and on Linux and
Windows they belong to the system, because the system's scanner configuration comes with them.
On macOS, where people don't have SANE, the release carries it. `scripts/build-sane-macos.sh`
builds it in the release workflow, for each Mac, from sane-backends, libusb and libjpeg-turbo
source archives pinned by version and SHA-256, so nothing comes from Homebrew. libjpeg-turbo is
built without its SIMD code, like ours, and linked into the backends that need it. libusb stays a
library of its own next to libsane. The `SANE for macOS` workflow builds it too whenever the
script changes, so a broken build shows up before a release.

## 13. Licence

minilab is MPL-2.0. The MPL works per file: a changed minilab file stays
MPL-2.0, but minilab can be combined with code under other licences.

What that rules out, and how minilab stays within it:

- No code is ported from GPL projects. The inversion follows darktable's published model, written
  from the equations (section 7).
- No data under the GPL or CC BY-SA. The stock presets are our own readings of the makers'
  datasheets (`data/stocks/README.md`).
- SANE is loaded when minilab runs, never linked into it. libsane and most backends carry SANE's
  exception to the GPL, which lets programs under any licence use them. Our V200 driver isn't
  shipped: people install it into their own SANE.
- The macOS download carries SANE with every backend that builds on macOS, so that as many
  scanners as possible work with nothing to install. Fifteen of those backends are under the GPL
  without the exception, and three have no licence notice at all (`scripts/build-sane-macos.sh`
  lists them). Several of them drive common film scanners: Plustek OpticFilm and Canon's film
  flatbeds (genesys), newer Epsons (epson2), Nikon Coolscans (coolscan3) and Reflecta (pieusb).
- The MPL allows that. Its section 3.3 lets an MPL program go out in a larger work with GPL code,
  and minilab's own files may then be shared under the GPL as well. The GPL asks for the source of
  the whole download: minilab's is public, the SANE, libusb and libjpeg-turbo archives are attached
  to every release, and the script that builds them is in this repository. The `sane` folder holds
  their licences and a README that says where the source is. Whether everything else in the
  program, like the CC BY looks and the OFL fonts, fits under the GPL in that larger work is a grey
  area. We chose to cover more scanners. If that ever has to change, the build script can leave
  the GPL-only backends out, and they'd load from the system's SANE where it's installed.
- libusb is under the LGPL-2.1 and stays a library of its own, so anyone can swap in their own.
- LibRaw is linked statically under the LGPL-2.1, which means users must be able to relink minilab
  with their own LibRaw. minilab's source and build are public, so they can.

The Frontier emulation LUT is minilab's own transform of the numbers in the Frontier software's
colour cube (section 10). None of Fujifilm's code or other tables are in the repository.

The film looks are under CC BY 4.0 and MIT. Both allow them in minilab on two conditions: the
credit and the licence go with them, and for CC BY, we say what we changed. The build installs
each collection's licence and `CREDITS-looks.txt` (credit, source and changes, from `bundled.zig`)
next to the program, and the Looks workspace shows the same. The collections' files aren't in the
repository; the build fetches them.

## 14. Build, platforms, tests

- **Build.** `zig build`, `zig build test`, `zig build run`, and `zig build check` for quick
  compile errors. A Makefile wraps them; `make help` lists what it does. The first build fetches
  and builds every library, and fetches and bakes the film looks. You don't need anything from
  Homebrew or apt except SANE itself, for scanning on Linux, or on a Mac with a build of your own
  (the macOS releases carry SANE, and `scripts/build-sane-macos.sh` builds the same one).
- **Platforms.** Each release has builds for macOS, Linux and Windows, each on x86-64 and Arm,
  made by GitHub Actions. CI runs the tests on Linux, macOS and Windows. Scanning on Windows can
  only be tried on a Windows machine with a scanner.
- **Updates.** Release builds (`-Dupdates`, which `release.yml` sets) ask GitHub's API for the
  latest release when they start, on a thread of their own (`src/app/update_worker.zig`), and say
  nothing if there's no connection. Installing (`src/update/root.zig`) downloads the platform's
  archive and only uses it if its SHA-256 matches the release's checksums file and GitHub's
  attestation for it verifies (`src/update/sigstore.zig`). That means:
  - the in-toto statement names the archive and its digest;
  - its signature verifies with the attestation's certificate;
  - the certificate chains to Fulcio's root at the time Rekor logged it, and names
    `release.yml` on main, issued through GitHub Actions' tokens;
  - Rekor's signed entry timestamp, inclusion proof and signed checkpoint all verify.

  Sigstore's trusted root is in `src/update/trusted_root.json`, from `gh attestation
  trusted-root`, and needs refreshing when Sigstore changes its keys. Only Rekor's original log is
  handled; if GitHub's attestations move to Rekor v2, updates refuse to install until the verifier
  reads those too ([#47](https://github.com/vdmkenny/minilab/issues/47)).
- **Installing an update** renames each of the archive's top-level files into the program's
  folder, and the old ones into `.previous`, which the next start deletes. Renaming a running
  program works on every system. The app then closes as usual and starts the new program with the
  same arguments: in place of itself on macOS and Linux, as a new process on Windows. Only macOS
  has been tried end to end ([#48](https://github.com/vdmkenny/minilab/issues/48)).
- **Tests**, in `test` blocks next to the code:
  - the pipeline against the formulas: the inversion model against the equations in section 7,
    worked out by hand for a few pixels;
  - golden images: frames of our raw V200 colour strip (`vendor/hw-scans/2026-10-22-colour/`),
    developed automatically on the base in their gaps, have to keep their average colours in
    Neutral and in Frontier emulation (`src/core/scans_test.zig`). The scans are private and
    large, so the test is skipped where they aren't there;
  - frame detection on generated strips with known boxes (`src/frames/synthetic.zig`), including
    dark frames. `src/frames/check_scans.zig` also runs detection on our V200 scans and prints what
    it finds, but it's a manual check, not part of the test suite;
  - the SANE code against SANE's `test` backend, where libsane is installed, and the V200 on real
    hardware;
  - linearity: scanning a step wedge on the V200 at gamma 1.0, to confirm that its output really
    is proportional to transmission. We haven't measured this yet.

## 15. Where things stand

The work was planned in phases, each ending with something usable:

1. **Core and command line:** TIFF and camera RAW in, flat field, base, the inversion model, the
   B&W and positive paths, TIFF and JPEG out with ICC profiles. Done, and tested on our V200
   scans.
2. **Frame detection** and `minilab detect`. Done.
3. **GUI on files:** roll browser, viewer, develop panel, histogram, before and after. Done.
4. **Scanning:** SANE with the V200 profile and raw setup for other scanners, preview,
   detection, batch scan. Done. TWAIN is written but hasn't been tried yet (section 5).
5. **Presets:** film types, tone and white balance modes, stock presets. Done.
6. **Looks:** Frontier emulation (section 10), imported .cube LUTs, the bundled film looks, and
   the tool for fitting looks to lab scans. Done.
7. **Export extras:** metadata is done. HDR with gain maps and export to Apple Photos aren't.

Still open:

- Frontier emulation has only been checked by eye so far. A lab's Frontier scans of our negatives
  would let us measure it.
- TWAIN needs a Windows machine with a scanner to test on.
- Undoing a non-linear scanner's curve from a step wedge scan (section 5) isn't built, and the
  V200's linearity hasn't been measured with a wedge.
- Slides use the scanner's colour as it is, or the camera's matrix. An input profile made from an
  IT8.7/1 transparency target isn't built.
- The viewer shows sRGB and doesn't use the display's ICC profile.
- HEIC with a gain map: the codecs minilab builds don't write HEIC yet.
- Exact stock values could come from a calibration frame on each stock (a grey card, bracketed
  over several stops), saved per stock and scanner. That isn't built.
- macOS's own scanner framework (ImageCaptureCore) would add scanners that SANE doesn't drive.
  It isn't planned, but it could be added as another kind of `Scanner` if needed.
