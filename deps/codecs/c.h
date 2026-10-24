/*
 * The C APIs of the image libraries, which translate-c turns into the Zig module "codecs": LibTIFF,
 * zlib, libjpeg-turbo's libjpeg API, LittleCMS 2 and LibRaw's C API, and minilab's JPEG shim. One
 * header holds them all, so that the types they share, such as `FILE`, are the same Zig types.
 */

#include <stddef.h>
#include <stdio.h>

#include <tiffio.h>

/* For compressing a TIFF's strips on several threads, the way LibTIFF's Deflate would. */
#include <zlib.h>

/* libjpeg's header needs `size_t` and `FILE` declared first. */
#include <jpeglib.h>

#include <lcms2.h>

#include <libraw/libraw.h>

#include "jpeg_shim.h"
