# Changes to sane-backends

`build-sane-macos.sh` applies these to the sane-backends release it builds for the macOS
download, in order. Each is meant to go upstream, and comes out of here once a release has it.
They're under sane-backends' own licence, like the files they change.

- **`epson2-infrared.patch`** turns on epson2's infrared mode, for the GT-X700, GT-X800, GT-X900
  (Perfection V700 and V750) and GT-X980, from the film unit. epson2 had the code for it, but
  only behind `SANE_FRAME_IR`, a frame type SANE doesn't define yet, so it was never built. The
  patch offers the mode always and returns the scan as a gray frame, as pixma does for the
  CanoScan 9000F, and gives the mode a gray scan's bit depths: it had line art's, one bit. Only
  the GT-X800 was ever tested, by the code's own note, so it needs checking on each model.
