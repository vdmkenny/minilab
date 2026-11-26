# Infrared dust removal

Some scanners, and some scanning software, take a fourth pass in infrared. minilab can use that
pass to find dust and scratches, instead of guessing them from the picture the way its ordinary
dust removal does (`design.md`, Dust). This page says why it works, what's built so far, how it
works, and where the facts come from. Issue #90 has the plan for the rest.

## Why it works

The dyes in colour film are close to transparent in the near infrared, but dust, hairs and
scratches block or scatter it. So a scan in infrared is a clear sheet with the defects on it: a
map of exactly what to remove, how big and how dense, with nothing to guess. Digital ICE, iSRD and
VueScan's infrared cleaning all build on this.

It doesn't suit every film:

- **Silver black and white** (HP5, Tri-X and the like): the silver grains block infrared too, so
  the picture itself looks like a defect.
- **Kodachrome**: its cyan dye absorbs well into the infrared, so picture detail shows up in the
  plane. Plain infrared cleaning softens its fine detail.
- **Chromogenic black and white** (XP2, BW400CN) is made of dye, and works like colour film.

## What's built

- **The plane in a roll.** A scan's infrared plane is kept next to it as `scans/01.ir.tif`: a
  16-bit greyscale TIFF the size of the scan, lined up with it when it's saved. The frame's file
  names it in `infrared`. Frames without one work as before.
- **Planes from files.** Importing a TIFF picks up an infrared plane stored in either of the two
  ways scanning software does it:
  - as a fourth sample after red, green and blue, when it isn't marked as alpha (an alpha sample
    stays alpha). VueScan writes these without the ExtraSamples tag that should describe the
    fourth sample, so a missing or "unspecified" one counts as infrared;
  - as a later page of the same size, flagged as a mask, as SilverFast's HDRi files have it;
  - in a 16-bit greyscale TIFF of its own, next to the scan. Software that saves it this way, like
    VueScan's "16 bit Infrared" output, lets you name the file, so minilab's rule is the scan's
    name with an infrared marker before the extension: `scan0001_ir.tif` for `scan0001.tif`, and
    `-ir`, `.ir`, ` ir` or `_infrared` work too, in any case. A file like that is never imported
    as a frame of its own when its scan is beside it, so a whole folder can be imported as it is.
- **The cleaning** (`core/infrared.zig`), below.
- **Develop.** A frame whose scan has a plane gets a choice under Remove dust: Find with Infrared
  or Shape. It starts on Infrared, unless the roll's stock is silver black and white. Infrared has
  two sliders, Threshold and Grow. The viewer and the loupe clean with the plane too, and the info
  line says "+ IR". Frames without a plane look as they always did.
- **Show what's removed.** The eye on Remove dust's heading tints everything dust removal
  changes in amber, in the viewer and the loupe, with either finder.
- **Warnings.** On silver black and white the choice is greyed out and says why; on Kodachrome it
  warns that fine detail may soften; and a plane that turns out not to be a map of dust says so,
  and the frame is left as it is.
- **Export.** With dust removal on and its finder set to infrared, export cleans with the plane,
  cropped, turned and reduced the same way as the scan.

Still to come: scanners.

Which films suit infrared comes from the stock presets: each says what its picture is made of
(`material`: dye, or silver for black and white unless it says otherwise, as XP2 does), and
Kodachrome says it's poor for infrared (`presets/stocks.zig`).

## How it works

On a frame's scan and its plane, lined up and the same size, in density (−log10 of the
transmission), like ordinary dust removal:

1. **Line up.** The plane can sit a pixel or so off the scan, more so when it comes from a
   separate pass. When a plane is saved, the shift (up to 4 pixels each way) that best lines its
   fine detail up with the red channel's is worked out, and the plane is saved moved by it. Both
   show the dust, and the plane a little of the picture too.
2. **Take the picture out.** The plane carries a faint copy of the picture, mostly from the cyan
   dye. How much is fitted from the steps in density from one pixel to the next in the plane and
   the red channel, away from the defects, so it's the grain and fine detail that count, not the
   picture's broad shapes. That much of the red's density comes off the plane's. If the plane
   follows the red by more than half, the film isn't one infrared works on.
3. **Measure against clear film.** The plane's opening (the minimum over a square, then the
   maximum) is the film without its defects. What stands up from it is how much infrared each
   defect blocks.
4. **Undo or fill.** A defect that lets some light through dimmed the picture under it by about as
   much as it dimmed the infrared, so dividing by that brings the picture back, with nothing made
   up. One that blocks more than 0.5 D (two thirds of the light) leaves too little to bring back,
   and is filled from the film nearby with ordinary dust removal's fill (`dust.fillMask`), grown a
   little round each defect.
5. **Refuse.** If more than 5% of the frame stands out, or the plane follows the picture too
   closely, it isn't a map of defects, and the frame is left as it is.

Two settings, saved with the frame's dust settings:

- **Threshold:** how much infrared a defect has to block to count, from 0.03 D to 0.3 D, 0.05 D
  to begin with.
- **Grow:** how far round each filled defect the fill reaches, from 0 to 0.3% of the frame's
  longer side, 0.05% to begin with (about 3 pixels on a 35mm frame at 4000 dpi).

The core patents (US 5,266,805, 5,673,336 and 6,442,301) expired between 2012 and 2017, going by
Google Patents. "Digital ICE" is a trademark, so minilab just calls this infrared.

## Sources

- Rüfenacht, Trumpy, Gschwind and Süsstrunk, ICIP 2013, on dyes and silver in the infrared:
  https://infoscience.epfl.ch/record/188640/files/ICIP2013_defects_final.pdf
- US 5,266,805, the infrared defect map: https://patents.google.com/patent/US5266805A
- US 5,673,336, the picture's copy in the infrared plane: https://patents.google.com/patent/US5673336A/en
- US 6,442,301, dividing out thin defects: https://patents.google.com/patent/US6442301
- Kodachrome: https://filmscanner.info/en/Kodachrome.html
- VueScan's file types: https://www.hamrick.com/vuescan/html/vuesc24.htm
- VueScan files without ExtraSamples, and SilverFast's mask page:
  https://github.com/rsilvabr/jxl-photo, https://discuss.pixls.us/t/a-question-about-silverfast-hdr/32186
- ExtraSamples: https://awaresystems.be/imaging/tiff/tifftags/extrasamples.html
