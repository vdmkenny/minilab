/*
 * The C APIs of the image libraries, which translate-c turns into the Zig module "codecs": LibTIFF,
 * libjpeg-turbo's libjpeg API, LittleCMS 2 and LibRaw's C API, and negscan's JPEG shim. One header
 * holds them all, so that the types they share, such as `FILE`, are the same Zig types.
 */

#include <stddef.h>
#include <stdio.h>

#include <tiffio.h>

/* libjpeg's header needs `size_t` and `FILE` declared first. */
#include <jpeglib.h>

#include <lcms2.h>

#include <libraw/libraw.h>

#include "jpeg_shim.h"
