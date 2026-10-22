# Image libraries

minilab reads and writes TIFF, JPEG and camera raw files, and builds ICC profiles, with C
libraries that `zig build` compiles from source. Each upstream is fetched through `build.zig.zon`,
pinned to a release by URL, commit and hash. Nothing comes from the system.

| Folder | Library | Version | Upstream | Licence |
| --- | --- | --- | --- | --- |
| `libtiff/` | LibTIFF | 4.7.2 | gitlab.com/libtiff/libtiff, tag `v4.7.2` | LibTIFF licence (BSD-like) |
| `libjpeg-turbo/` | libjpeg-turbo | 3.2.0 | github.com/libjpeg-turbo/libjpeg-turbo, tag `3.2.0` | IJG licence, Modified BSD and zlib licences |
| `libraw/` | LibRaw | 0.22.2 | github.com/LibRaw/LibRaw, tag `0.22.2` | LGPL-2.1 or CDDL-1.0, minilab takes LGPL-2.1 |
| (by URL) | LittleCMS | 2.18 | allyourcodebase/lcms2, tag `v2.18.0` | MIT |
| (by URL) | zlib | 1.3.2 | allyourcodebase/zlib, tag `1.3.2` | zlib licence |
| `codecs/` | the four as one Zig module | | | minilab's own: MPL-2.0 |

zlib and LittleCMS use allyourcodebase's packages, which build with Zig 0.17 as they are. The
others have a small `build.zig` here, written from the upstream's CMake or automake files.

minilab is MPL-2.0. Every licence above allows minilab to link the library, on these terms:

- LibTIFF: keep its copyright and permission notice with copies, and don't use the names of Sam
  Leffler or Silicon Graphics in advertising.
- libjpeg-turbo: the documentation of a binary must say "this software is based in part on the
  work of the Independent JPEG Group" (`README.ijg`). The libjpeg API is under the IJG licence, the
  build system under the Modified BSD licence, and the SIMD code, which isn't built here, under
  the zlib licence.
- LibRaw: minilab uses it under LGPL-2.1. A statically linked LGPL library must be replaceable by
  its users; minilab's source and build are public, so anyone can relink with their own LibRaw. LibRaw contains code from dcraw, DCB and FBDD demosaicing (BSD 3-clause), the
  X3F library (BSD) and Adobe's DNG SDK (MIT), listed in its `COPYRIGHT`.
- LittleCMS: MIT.
- zlib: zlib licence.

The translate-c package (MIT), from codeberg.org/ziglang/translate-c, turns the C headers into Zig
at build time. Its small helper modules end up in the program.

## What each package builds

- **libjpeg-turbo** builds the static library `jpeg`: the libjpeg API (v6b ABI) with 8-, 12- and
  16-bit (lossless) precision and arithmetic coding. It is plain C: the SIMD extensions are left
  out, so no NASM is needed.
- **libtiff** builds the static library `tiff` with these codecs: none, PackBits, LZW, Deflate,
  PixarLog, JPEG and old-style JPEG (8- and 12-bit, through libjpeg-turbo), CCITT fax,
  ThunderScan, NeXT and LogLuv. It leaves out LERC, LZMA, ZSTD, WebP and JBIG. File access goes
  through `tif_unix.c` on every system, Windows too, so `tiffio.h` doesn't include `windows.h`.
- **libraw** builds the static library `raw`: C++17 (GNU dialect) on libc++, with zlib for
  floating-point DNG and libjpeg-turbo for lossy DNG. It leaves out OpenMP, LittleCMS, RawSpeed and
  the DNG SDK. Its C API is `libraw/libraw.h`. On Windows it links `ws2_32`.
- **codecs** translates `c.h` (`tiffio.h`, `jpeglib.h`, `lcms2.h`, `libraw/libraw.h` and
  `jpeg_shim.h`) into the Zig module `codecs`, which links all the libraries. `jpeg_shim.c` runs
  libjpeg inside C: libjpeg handles fatal errors with `longjmp`, which mustn't jump over Zig
  frames. The C libraries are built with `ReleaseFast` whatever the program's mode, as in
  OpenReliant, so that a debug build still decodes a camera file quickly. Each library's licence
  file is a named lazy path, and `licences` in `codecs/build.zig` lists them, so minilab can
  install them beside the program.

The bindings live in `src/io/codecs/`: `tiff.zig`, `jpeg.zig`, `icc.zig` and `raw.zig`.

## Building and testing

Each folder is a Zig package and builds on its own, for the host or another target:

```sh
cd deps/libraw
zig build -Dtarget=x86_64-windows-gnu
```

In `codecs/`, `zig build` compiles the bindings' tests for the target without running them, and
`zig build test` runs them. The RAW test decodes a camera file only when it is given one:

```sh
cd deps/codecs
zig build test -Draw-sample=/path/to/photo.nef
```

Every package builds for `aarch64-macos`, `x86_64-linux-gnu` and `x86_64-windows-gnu`.
