# minilab

<img src="docs/icon.svg" alt="minilab's icon: an amber film strip on a dark tile" width="96">

minilab is an app for scanning and developing film. You scan a roll, or bring in photos of your
negatives taken with a camera, or scans you already have. minilab finds the frames, turns the
negatives into positives and exports the results. It handles colour and black and white negatives
and slides, and it works a roll at a time. It runs on macOS, Linux and Windows.

It's written in Zig 0.17 with a Dear ImGui interface. If you want to know how it works inside and
why, have a look at [docs/design.md](docs/design.md).

## Getting it

Download the archive for your system from the [latest release](../../releases/latest) and unpack
it. There are builds for Windows, macOS and Linux, on both x86-64 and Arm, plus a file with their
checksums so you can check your download.

The macOS builds aren't signed, so macOS blocks them the first time you open one. Run this once,
in the folder you unpacked, to let it through:

```bash
xattr -d com.apple.quarantine minilab
```

`minilab --version` tells you which version you have.

## Building it yourself

You need Zig 0.17. Then:

```sh
make build      # or: zig build --release=safe
make run        # builds and opens the app
make test       # runs the tests
make check      # formatting, the repository's file checks and the tests, like CI
```

The first build downloads and compiles every library minilab uses (SDL3, Dear ImGui,
libjpeg-turbo, libtiff, LibRaw and Little CMS) and the film look collections. You don't need to
install anything else, except SANE if you want to scan on macOS or Linux.

## Using the app

The app has five workspaces, roughly one per step:

- **Rolls** shows each roll as a contact sheet, with its film, its format and how many frames
  you've developed. Click New roll to start one.
- **Scan** shows the scanner's preview with the frames minilab found on it. You can fix any
  frame's box, then queue the frames up and scan them into a roll.
- **Develop** is where a negative becomes a picture. You see the negative and the positive side
  by side, and you set the film base, density, inversion curve, colour balance, saturation and a
  look. Sync copies some or all of those settings to the roll's other frames. You can also give a
  frame 1 to 5 stars or reject it, in the bar under the picture or with Lightroom's keys: 0 to 5
  for stars, X to reject, U to take the reject back.
- **Export** saves TIFF or JPEG files in sRGB, Display P3, Adobe RGB or ProPhoto RGB, with the
  roll's metadata in them, at full size or with the long edge cut down to a size you pick. A star
  filter picks the frames by rating, and rejected frames start out unticked.
- **Looks** lists the looks you can develop with, and lets you make your own (see below).

Picking a film stock in Develop does more than label the roll. Film doesn't respond to light in a
straight line in the shadows: the darkest tones get squeezed together on the negative. When
minilab has the stock's datasheet, it uses the datasheet's curves to undo that for each colour
layer, so the shadows open up instead of going muddy. If you only want the stock as a label,
untick Datasheet corrections.

`minilab open --shortcuts` lists the keyboard shortcuts. Where Lightroom has a shortcut for the
same thing, minilab uses the same key.

## Looks

A look is a colour style that goes on top of what you set in Develop. You pick one from Develop's
Look menu. Apart from Neutral, every look is a LUT (a lookup table that maps each colour to a new
colour) applied on top of Neutral.

- **Neutral:** just the inversion as Develop sets it, with nothing added.
- **Frontier emulation:** the colour of a Fujifilm Frontier lab scanner. Tones, greys and
  brightness stay the same as Neutral. Greens lean a little toward teal, and skin and skies get a
  little richer.
- **Film looks:** 85 film emulations from three free collections, each in its own menu:
  GlassMeter (30 colour negative, slide and B&W films), t3mujinpack (51) and Street Monochrome (4
  B&W looks). The Looks workspace shows who made each collection and its licence.
- **Imported LUTs:** any .cube LUT (3D or 1D, any size) made for sRGB or Rec. 709 input. Import one
  from the Look menu or the Looks workspace, and minilab copies it into the library's `Looks`
  folder.
- **Fitted looks:** your own looks, made in the Looks workspace. You give it pairs of scans of the
  same negatives, one from minilab and one from a lab, and minilab works out a look that makes
  ours match theirs.

## Command line

```
minilab import <roll name> <scan.ppm>... [--library <folder>] [--stock <name>] [--film colour|bw|slide]
minilab looks
minilab develop <scan.ppm> <out.tif|out.ppm> [--look <look>] [--depth 8|16]
minilab develop-roll <out folder> <scan.ppm>... [--look <look>]
minilab detect <scan.ppm> --dpi <n>
minilab scan --list
minilab scan <out.ppm> [--device <id or model>] [--dpi <n>] [--area x,y,w,h]
```

`minilab --help` lists every option, and every command takes `--verbose`. `--look` takes a look
name from `minilab looks`, like `glassmeter:kodak-portra-400`, or the path to a .cube file.

## Scanning

On macOS and Linux minilab scans through SANE, the usual scanner library there. It only loads
SANE when you scan, so the app starts fine without it, and it uses whatever scanner drivers your
SANE setup has. On Windows it uses TWAIN with the scanner maker's own driver.

For scanners minilab has a profile for (only the Epson Perfection V200 so far), it scans raw:
linear 16-bit data, with the scanner doing no inversion or colour correction of its own. That
leaves the film base (the colour of the bare film, orange on most colour negatives) untouched, so
minilab can measure it in the gaps between frames.

## Licence

minilab is under the Mozilla Public License 2.0 (see `LICENSE`). The libraries it builds keep
their own licences, and the build puts a copy of each next to the program. LibRaw is linked under
the LGPL 2.1, so you can relink minilab with your own LibRaw.

The film stock presets are our own readings of the makers' datasheets;
[data/stocks/README.md](data/stocks/README.md) explains how we read them. The film looks come from
GlassMeter by Glass Works and Street Monochrome by Ivan Bogachev, both under CC BY 4.0, and
t3mujinpack by João Almeida, under the MIT licence. The build downloads them and puts their
licences and `CREDITS-looks.txt` next to the program.
