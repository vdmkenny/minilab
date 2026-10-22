# Contributing to minilab

minilab scans and develops film: colour and B&W negatives and slides, from a scanner, a camera or
files. This guide gives the project's conventions, and is written for people and coding agents
alike: `AGENTS.md` and `CLAUDE.md` point agents here. [docs/design.md](docs/design.md) says what
minilab does and why.

## Getting started

- Install [Zig 0.17](https://ziglang.org). `zig build` builds minilab, `zig build test` runs the
  tests, and `zig build check -fincremental --watch` reports compile errors moments after a save.
  The first build fetches the libraries `build.zig.zon` names and builds the C and C++ ones.
- Run `make hooks` once. It installs a pre-commit hook that keeps scans and other files out of the
  repository. `make help` lists the other workflows.
- `make run` opens the app on your library (`~/Pictures/Rolls`, or `ARGS='open --library
  <folder>'`). Scanning needs SANE on macOS and Linux, or the scanner maker's TWAIN driver on
  Windows.

## How minilab is put together

- `src/core/` holds everything that works without a window: the colour pipeline (`develop.zig`),
  looks (`look.zig`, `cube_lut.zig`), rolls on disk (`roll.zig`), frame detection's use
  (`framing.zig`), scanner calibration (`calibration.zig`) and export.
- `src/frames/`, `src/scan/`, `src/io/` and `src/looks/` are frame detection, scanners, file
  formats and fitting looks. `src/presets/` holds the film stocks and the built-in LUTs.
- `src/app/` is the interface, one file per workspace, and `src/ui/` its controls and theme.
- `src/main.zig` is the command line.

### The design is the reference

The screens follow the "minilab GUI" design: its colours, sizes, text and order. Check a screen
against it with `--screenshot`, which draws without a window:

```bash
zig-out/bin/minilab open --library <folder> --roll <name> --workspace develop --screenshot develop.png
```

### Text on screen

Labels and short fragments rather than sentences: `Shadows clipped 6.9%`, `Crop to check`. The
text on screen uses American spelling; docs and comments use British spelling.

## Writing Zig

Write idiomatic Zig 0.17: name every number, give an id space an `enum` and switch over it
exhaustively, use tagged unions for variants and optionals for "none", check invariants with
`comptime`, and share code rather than copy it. `src/core/look.zig` is a good example.

C comes in through `src/platform/c.h`, which the build translates into the `c` module with SDL3 and
Dear Bindings' C API for Dear ImGui, and through `deps/codecs` for JPEG, TIFF, camera RAW and ICC
profiles.

Add `test` blocks next to the code in the same change, with inputs built by hand so that they run
without anyone's scans. `src/core/scans_test.zig` checks the colour pipeline against our own
scans when they're present in `vendor/`, and is skipped where they aren't.

## Documentation

Document what minilab does in [`docs/`](docs), in plain, present-tense reference style: the way
you would explain the code to a colleague, with normal word order, common words and short
sentences. The project's text uses colons, commas, parentheses or a second sentence in place of em
and en dashes, which `make check-files` refuses.

## Checks

Before you open a pull request, run:

```bash
make check
```

It checks the formatting, the repository's files and the tests. CI runs the same on Linux, macOS
and Windows, and the tests in ReleaseFast too.

## Commits and pull requests

- Branch from `main` (`feat/stock-balance`, `fix/...`, `docs/...`) and open a pull request. `main`
  changes only through squash-merged pull requests.
- Title the pull request in [Conventional Commits](https://www.conventionalcommits.org) form:
  `feat: Stock balance from a calibrated scanner`. Keep the body short, and end it with `Closes #N`
  for each issue it finishes.
- File an issue for each gap you leave, and link it from the code where the gap is.
- Releases come from [release-please](https://github.com/googleapis/release-please)
  ([`release.yml`](.github/workflows/release.yml),
  [`release-please-config.json`](release-please-config.json)): it keeps a release pull request open
  with the next version and its changelog, and merging it tags the version and attaches the builds
  for Windows, macOS and Linux, on x86-64 and Arm, with their checksums. `build.zig.zon` holds the
  version being worked towards, which `--version` reports; the first release is 0.0.1.
- The repository holds minilab's code, its data and its docs. Scans, camera files and pictures,
  the makers' datasheet PDFs, and any scanner maker's software or firmware stay out: the
  pre-commit hook, `make check-files` and CI see to it.
