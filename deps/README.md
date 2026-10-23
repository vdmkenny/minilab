# Image libraries

minilab uses a few C libraries to read and write TIFF, JPEG and camera RAW files and to build ICC
profiles (the files that describe a colour space). `zig build` compiles them all from source.
Each one is fetched through `build.zig.zon` and pinned to a release by URL, commit and hash, so
nothing comes from your system.

| Folder | Library | Version | Upstream | Licence |
| --- | --- | --- | --- | --- |
| `libtiff/` | LibTIFF | 4.7.2 | gitlab.com/libtiff/libtiff, tag `v4.7.2` | LibTIFF licence (BSD-like) |
| `libjpeg-turbo/` | libjpeg-turbo | 3.2.0 | github.com/libjpeg-turbo/libjpeg-turbo, tag `3.2.0` | IJG licence, Modified BSD and zlib licences |
| `libraw/` | LibRaw | 0.22.2 | github.com/LibRaw/LibRaw, tag `0.22.2` | LGPL-2.1 or CDDL-1.0, minilab takes LGPL-2.1 |
| (by URL) | LittleCMS | 2.18 | allyourcodebase/lcms2, tag `v2.18.0` | MIT |
| (by URL) | zlib | 1.3.2 | allyourcodebase/zlib, tag `1.3.2` | zlib licence |
| `codecs/` | the four as one Zig module | | | minilab's own: MPL-2.0 |

For zlib and LittleCMS we use the allyourcodebase packages, which already build with Zig 0.17.
The others each have a small `build.zig` in this folder, written by following the upstream's
CMake or automake files.

minilab is under the MPL-2.0, and every licence above lets minilab link the library. Here's what
each one asks of us:

- **LibTIFF:** keep its copyright and permission notice with every copy, and don't use the names
  of Sam Leffler or Silicon Graphics in advertising.
- **libjpeg-turbo:** the documentation that comes with a binary has to say "this software is based
  in part on the work of the Independent JPEG Group" (`README.ijg`). The libjpeg API is under the
  IJG licence and the build system under the Modified BSD licence. The SIMD code is under the zlib
  licence, but we don't build it.
- **LibRaw:** we use it under the LGPL-2.1. When you link an LGPL library statically, users have
  to be able to swap in their own copy. minilab's source and build are public, so anyone can
  relink it with their own LibRaw. LibRaw includes code from dcraw, the DCB and FBDD demosaicing
  code (BSD 3-clause), the X3F library (BSD) and Adobe's DNG SDK (MIT); its `COPYRIGHT` file lists
  them.
- **LittleCMS:** MIT.
- **zlib:** zlib licence.

The build also uses the translate-c package (MIT, from codeberg.org/ziglang/translate-c) to turn
the C headers into Zig. A few of its small helper modules end up in the program.

## What each package builds

- **libjpeg-turbo** builds the static library `jpeg`: the libjpeg API (v6b ABI) with 8-bit, 12-bit
  and 16-bit (lossless) precision and arithmetic coding. It's plain C. We leave the SIMD
  extensions out, so you don't need NASM.
- **libtiff** builds the static library `tiff` with these codecs: none, PackBits, LZW, Deflate,
  PixarLog, JPEG and old-style JPEG (8-bit and 12-bit, through libjpeg-turbo), CCITT fax,
  ThunderScan, NeXT and LogLuv. It leaves out LERC, LZMA, ZSTD, WebP and JBIG. File access goes
  through `tif_unix.c` on every system, Windows included, so that `tiffio.h` doesn't pull in
  `windows.h`.
- **libraw** builds the static library `raw`: C++17 (the GNU dialect) on libc++, with zlib for
  floating-point DNG and libjpeg-turbo for lossy DNG. It leaves out OpenMP, LittleCMS, RawSpeed
  and the DNG SDK. Its C API is in `libraw/libraw.h`. On Windows it also links `ws2_32`.
- **codecs** translates `c.h` (which includes `tiffio.h`, `jpeglib.h`, `lcms2.h`,
  `libraw/libraw.h` and `jpeg_shim.h`) into the Zig module `codecs`, and links all the libraries.
  - `jpeg_shim.c` exists because libjpeg handles fatal errors with `longjmp`, and a `longjmp` must
    never jump over Zig code. So the shim runs libjpeg entirely inside C.
  - The C libraries are always built with `ReleaseFast`, whatever mode you build minilab in. That
    way a debug build still decodes a camera file quickly.
  - Each library's licence file is a named lazy path, and `licences` in `codecs/build.zig` lists
    them, so the minilab build can install them next to the program.

The Zig bindings for all this are in `src/io/codecs/`: `tiff.zig`, `jpeg.zig`, `icc.zig` and
`raw.zig`.

## Building and testing

Each folder is a Zig package of its own, so you can build it by itself, for your machine or for
another target:

```sh
cd deps/libraw
zig build -Dtarget=x86_64-windows-gnu
```

In `codecs/`, `zig build` compiles the bindings' tests for the target without running them, and
`zig build test` runs them. The RAW test only decodes a camera file if you give it one:

```sh
cd deps/codecs
zig build test -Draw-sample=/path/to/photo.nef
```

Every package builds for the six targets the releases are made for: x86-64 and Arm on macOS, on
Linux with glibc and on Windows with MinGW.
