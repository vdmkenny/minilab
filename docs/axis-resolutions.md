# Separate X and Y resolutions

On SANE scanners with separate resolution controls, Scan also shows native X and Y menus.
For an Epson V600 with the epkowa driver, these can reach 6400 and 9600 dpi respectively.
Only resolutions the driver accepts without rounding or dropping the bit depth are listed.
The ordinary resolution menu still requests the same resolution in both directions.

When X and Y differ, the roll keeps two files in `scans/`: the untouched native pixel grid
in a `.native.tiff`, with separate TIFF resolution tags, and a square-pixel working scan.
The working scan interpolates only the lower-density axis to the higher density. It does
not add optical detail, but keeps the native detail from both axes while maintaining the
correct proportions in frame detection, Develop and exports. The frame's JSON records
`native_scan` and `capture_dpi`. A square-pixel capture keeps the existing single-file layout.

The command line can save a native TIFF directly:

```sh
minilab scan frame.tiff --dpi 6400 --dpi-y 9600
```

Different X and Y resolutions require a TIFF destination because PPM cannot record their
pixel aspect ratio. A setting accepted by a driver still needs a scan on that hardware to
confirm the resulting image. Scanner options alone do not start a scan.

The size estimate includes both uncompressed 16-bit TIFFs for rectangular scans.
Actual disk use depends on TIFF compression. When changing source or reopening
a scanner, a native pair is kept only if the new source offers both values.
Normal scans and previews explicitly reset active X/Y controls to the common dpi.
If saving the native archive fails, the app reports that failure and keeps the
working frame with its crop and turns.

When an infrared pass is available, its native grid is also archived as a
`.native.ir.tif`. The working plane is resampled to the working RGB image
before the roll aligns it. The estimate includes both infrared files as well.
