# Infrared dust removal on the Epson V600

On Linux, the Scan workspace can capture the V600's infrared channel alongside
its colour image. Turn on **Infrared dust removal** before scanning frames.
Previews still use SANE. Infrared capture uses square pixels at 800, 1600 or
3200 dpi. Turning it off restores the normal SANE resolution controls.

Use this with colour negatives and suitable colour slides. Silver-based B&W
film and Kodachrome are unsuitable. The option is disabled for B&W rolls.
Capture takes two passes, so it takes longer than a normal scan.
Intermediate raw files are limited to 512 MiB each. Use frame-sized areas at
higher resolutions; a full film bed at 3200 dpi exceeds that limit.

The original RGB scan is kept unchanged. The roll also keeps a grayscale
infrared PGM and a separate corrected TIFF. In Develop, **INFRARED DUST
REMOVAL** switches between the original and corrected colour image, keeping
your crop and develop settings. Thumbnails and exports follow that choice.
The existing **REMOVE DUST** controls are a separate, image-based correction.

The correction is minilab's own conservative dust mask and interpolation. It
does not use Epson's Digital ICE image-processing plug-in. Small dark defects
in infrared are masked, their edges are expanded slightly, and only those RGB
pixels are filled from their surroundings. A mask covering more than 5% of the
image is refused. Review fine detail and large defects before exporting.
If that happens, the original and IR are still saved in the roll, and the
queue reports that the correction was rejected.

## Driver setup

The normal V600 SANE driver, including its interpreter, must already work.
Install Epson Scan 2 with its non-free interpreter and firmware as well. None
of those driver files are distributed with minilab.

Linux builds install `minilab-epson-ir` next to `minilab`. Set these environment
variables before starting the app:

```sh
export MINILAB_EPSON_IR_HELPER=/path/to/bin/minilab-epson-ir
export MINILAB_EPSON_COMMAND_LIBRARY=/path/to/epsonscan2/libes2command.so
```

On NixOS the helper needs the same dynamic-loader wrapper as minilab. Point
`MINILAB_EPSON_IR_HELPER` at that wrapper. The command library and its adjacent
`non-free-exec/es2intif` must come from the same Epson installation.

The option appears only for a V600 or GT-X820 opened through `epkowa`, when
both paths exist. The helper matches the selected USB address to its serial
number and refuses ambiguous devices without a serial. SANE releases its
handle before the helper starts. An acquisition error or helper crash fails
that frame without terminating the app or silently falling back to RGB-only.
IR capture uses linear gamma and no colour matrix, rather than custom SANE
raw settings. RGB stays at the requested depth, including 16 bits; Epson's IR
pass is 8-bit and is stored losslessly widened to 16-bit.

The command line also takes `--infrared`, defaulting to 800 dpi:

```sh
minilab scan frame.tiff --infrared --dpi 800 --area 10,30,10,10
```

It saves the corrected image, `frame.tiff.original.tiff` and
`frame.tiff.infrared.pgm`. The original and IR are saved before correction, so
they remain available if the correction is refused.

The integration was checked with Epson Scan 2 6.7.70 and a real V600 at 800 dpi,
with 16-bit RGB and a separate IR image. Larger scans and other film stocks
need their own visual checks. The helper uses the Linux C++ binary interface
declared by that Epson version; incompatible future versions may need changes.
