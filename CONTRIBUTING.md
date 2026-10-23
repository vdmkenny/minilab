# Contributing to minilab

Thanks for helping out. This guide covers how the project is set up and the conventions we stick
to. It's written for people and coding agents alike: `AGENTS.md` and `CLAUDE.md` point agents
here. For what minilab does and why, see [docs/design.md](docs/design.md).

## Getting started

- Install [Zig 0.17](https://ziglang.org). `zig build` builds minilab and `zig build test` runs
  the tests. While you work, `zig build check -fincremental --watch` shows compile errors a moment
  after you save.
- The first build takes a while. It downloads the libraries and look collections that
  `build.zig.zon` lists (the looks alone are about 75 MB), compiles the C and C++ libraries and
  bakes the looks into the program.
- Run `make hooks` once. It installs a pre-commit hook that stops scans and other files that don't
  belong from getting committed. `make help` lists the other `make` targets.
- `make run` opens the app on your library (`~/Pictures/Rolls`), or on another folder with
  `ARGS='open --library <folder>'`. To scan you need SANE on macOS and Linux (the README's
  "Building it yourself" has how to build it on a Mac), or the scanner maker's TWAIN driver on
  Windows.

## Where things are

- `src/core/` is everything that works without a window: the colour pipeline (`develop.zig`),
  looks (`look.zig`, `cube_lut.zig`), rolls on disk (`roll.zig`), frame detection as the app uses
  it (`framing.zig`), scanner calibration (`calibration.zig`) and export.
- `src/frames/` is frame detection, `src/scan/` talks to scanners, `src/io/` reads and writes file
  formats, and `src/looks/` fits looks.
- `src/presets/` has the film stocks, the built-in LUT and the list of looks from other
  collections (`looks/bundled.zig`). At build time `src/bake_looks.zig` bakes those looks into
  the program.
- `src/app/` is the interface, one file per workspace, and `src/ui/` has its controls and theme.
- `src/main.zig` is the command line.

### The design is the reference

The screens follow the "minilab GUI" design: its colours, sizes, text and layout. To check a
screen against it, use `--screenshot`, which draws the screen to a file without opening a window:

```bash
zig-out/bin/minilab open --library <folder> --roll <name> --workspace develop --screenshot develop.png
```

### Text on screen

Keep it to labels and short fragments, not full sentences: `Shadows clipped 6.9%`,
`Crop to check`. Text on screen uses American spelling; docs and comments use British spelling.

## Writing Zig

Write idiomatic Zig 0.17. In practice that means:

- give every number a name;
- give a set of ids an `enum`, and switch over it exhaustively;
- use tagged unions for things that come in variants, and optionals for "none";
- check invariants with `comptime` where you can;
- share code rather than copying it.

`src/core/look.zig` is a good example to follow.

C code comes in two ways. `src/platform/c.h` is translated by the build into the `c` module, which
has SDL3 and Dear Bindings' C API for Dear ImGui. `deps/codecs` covers JPEG, TIFF, camera RAW and
ICC profiles.

Add `test` blocks next to the code in the same change. Build their inputs by hand, so the tests
run without anyone's scans. The one exception is `src/core/scans_test.zig`: it checks the colour
pipeline against our own scans when they're in `vendor/`, and skips itself when they aren't.

## Docs

Docs go in [`docs/`](docs). Write them the way you'd explain the code to a colleague: plain and
simple, a bit informal is fine, with normal word order, common words and short sentences. Explain
what something is and why it matters before you get into the details.

We don't use em or en dashes anywhere in the project's text. Use a colon, a comma, parentheses
or a second sentence instead. `make check-files` fails if it finds one.

## Checks

Before you open a pull request, run:

```bash
make check
```

It checks the formatting, the repository's files and the tests. CI runs the tests on Linux, macOS
and Windows, in ReleaseFast as well, and checks the formatting and the files once, on Linux.

## Commits and pull requests

- Branch off `main` (`feat/stock-balance`, `fix/...`, `docs/...`) and open a pull request. `main`
  only changes through squash-merged pull requests.
- Give the pull request a [Conventional Commits](https://www.conventionalcommits.org) title, like
  `feat: Stock balance from a calibrated scanner`. Keep the description short, and end it with
  `Closes #N` for each issue it fixes.
- If you leave a gap, file an issue for it and link the issue from the code where the gap is.
- Releases are handled by [release-please](https://github.com/googleapis/release-please) (see
  [`release.yml`](.github/workflows/release.yml) and
  [`release-please-config.json`](release-please-config.json)). It keeps a release pull request
  open with the next version number and its changelog. Merging that pull request tags the version
  and attaches builds for Windows, macOS and Linux, on x86-64 and Arm, with their checksums.
  `build.zig.zon` holds the version we're working towards, which is what `--version` prints.
- The repository holds minilab's code, data and docs, and nothing else. Scans, camera files and
  pictures, the makers' datasheet PDFs, and any scanner maker's software or firmware stay out. The
  pre-commit hook, `make check-files` and CI all check for that.
