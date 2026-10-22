# minilab

minilab scans and develops film: colour and B&W negatives and slides, from a scanner, a camera or
files, a roll at a time. It runs on macOS, Linux and Windows. It is written in Zig 0.17, with a
Dear ImGui interface. `docs/design.md` describes how it works and why.

## Getting it

Download the archive for your system from the [latest release](../../releases/latest) and extract
it. There are builds for Windows, macOS and Linux, on x86-64 and Arm, each with its checksum. The
macOS builds aren't signed, so macOS blocks them at first: run `xattr -d com.apple.quarantine
minilab` once to allow them. `minilab --version` says which version you have.

## Building

```sh
make build      # or: zig build --release=safe
make run        # opens the app
make test       # zig build test
make check      # formatting, the repository's files and the tests
```

The first build fetches and builds every library it uses (SDL3, Dear ImGui, libjpeg-turbo, libtiff,
LibRaw, Little CMS). Nothing else is needed, except SANE for scanning on macOS and Linux.

## The app

Five workspaces:

- **Rolls:** each roll as a contact sheet, with its film, format and how many frames are
  developed. New roll makes one.
- **Scan:** the scanner's preview with the frames found on it, the frames' boxes to adjust, and the
  queue that scans them into a roll.
- **Develop:** a frame's negative and positive side by side, its film base, density, inversion
  curve, colour balance and saturation, a look, and Sync to give the roll's other frames some or
  all of those settings.
- **Export:** TIFF or JPEG in sRGB, Display P3, Adobe RGB or ProPhoto RGB, with the roll's
  metadata.
- **Looks:** the looks frames can be developed with, and fitting a look of your own from pairs of
  our scans and a lab's scans of the same negatives.

`minilab open --shortcuts` lists the keyboard shortcuts, which follow Lightroom's where it has one.

## Looks

A look is what follows Develop's settings. Develop's Look drop-down lists them all:

- **Neutral:** the inversion as Develop sets it, nothing added.
- **Frontier emulation:** the colour of a Fujifilm Frontier scan, as a LUT over Neutral. Tone,
  greys and lightness stay Neutral's; greens lean a little toward teal, skin and skies gain a
  little.
- **Imported LUTs:** any .cube LUT (3D or 1D, any size) that expects sRGB or Rec. 709 input. Import
  one from the Look drop-down or the Looks workspace; it's copied into the library's `Looks`
  folder.
- **Fitted looks:** made in the Looks workspace.

## Command line

```
minilab import <roll name> <scan.ppm>... [--library <folder>] [--stock <name>] [--film colour|bw|slide]
minilab develop <scan.ppm> <out.tif|out.ppm> [--look neutral|frontier|<file.cube>] [--depth 8|16]
minilab develop-roll <out folder> <scan.ppm>... [--look neutral|frontier|<file.cube>]
minilab detect <scan.ppm> --dpi <n>
minilab scan --list
minilab scan <out.ppm> [--device <id or model>] [--dpi <n>] [--area x,y,w,h]
```

`minilab --help` gives every option. Any command takes `--verbose`.

## Scanning

On macOS and Linux minilab loads the system's SANE library when it scans, so it starts without
SANE installed and uses SANE's own configuration of backends. On Windows it uses TWAIN and the
scanner maker's driver. Scanners minilab has a profile for (the Epson Perfection V200 so far) scan
raw: linear, 16 bits per channel, with no inversion or colour matrix in the scanner, so the film
base can be measured between the frames.

## Licence

minilab is under the Mozilla Public License 2.0 (`LICENSE`). The libraries it builds keep their own
licences, which the build installs beside the program. LibRaw is linked under the LGPL 2.1, so it
can be relinked. The film stock presets are our own readings of the makers' datasheets
(`data/stocks/README.md`).
