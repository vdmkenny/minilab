/*
 * minilab's JPEG compression and decompression through libjpeg, for the Zig binding
 * (`src/io/codecs/jpeg.zig`). libjpeg reports a fatal error by calling a function that must not
 * return, which in practice means `longjmp`, and Zig code cannot be jumped over safely. These
 * functions run libjpeg under `setjmp` in C and return what went wrong instead.
 */

#ifndef MINILAB_JPEG_SHIM_H
#define MINILAB_JPEG_SHIM_H

#include <stddef.h>

/* The room a message needs, libjpeg's `JMSG_LENGTH_MAX`. */
#define MINILAB_JPEG_MESSAGE_LENGTH 200

/* What a function returns. */
enum minilab_jpeg_result {
    MINILAB_JPEG_OK = 0,
    /* libjpeg failed; the message says why. */
    MINILAB_JPEG_FAILED = 1,
    /* An allocation failed. */
    MINILAB_JPEG_OUT_OF_MEMORY = 2,
};

/* An 8-bit RGB image to compress, and how. */
struct minilab_jpeg_compression {
    /* Red, green and blue for each pixel, row after row, top first. */
    const unsigned char *pixels;
    unsigned width;
    unsigned height;
    /* The bytes from one row's start to the next's. */
    size_t row_bytes;
    /* libjpeg's quality scale, 1 to 100. */
    int quality;
    /* Nonzero to store the colour at half resolution both ways (4:2:0), zero for full (4:4:4). */
    int subsample_chroma;
    /* An ICC profile to embed, or NULL. */
    const unsigned char *icc_profile;
    unsigned icc_profile_size;
};

/*
 * Compresses `image` into a JPEG file in memory. On success, `*jpeg` holds the file, `*jpeg_size`
 * bytes long, which the caller frees with `minilab_jpeg_free`. On failure, `*jpeg` is NULL and
 * `message`, MINILAB_JPEG_MESSAGE_LENGTH bytes, holds libjpeg's reason.
 */
enum minilab_jpeg_result minilab_jpeg_compress(const struct minilab_jpeg_compression *image,
                                               unsigned char **jpeg, unsigned long *jpeg_size,
                                               char *message);

/* A decompressed image. */
struct minilab_jpeg_image {
    /* Red, green and blue for each pixel, row after row, top first, 3 * width bytes a row. */
    unsigned char *pixels;
    unsigned width;
    unsigned height;
    /* The embedded ICC profile, or NULL. */
    unsigned char *icc_profile;
    unsigned icc_profile_size;
};

/*
 * Decompresses the JPEG file `jpeg`, `jpeg_size` bytes long, to 8-bit RGB. On success, the caller
 * frees `image->pixels` and `image->icc_profile` with `minilab_jpeg_free`. On failure, both are
 * NULL and `message`, MINILAB_JPEG_MESSAGE_LENGTH bytes, holds libjpeg's reason.
 */
enum minilab_jpeg_result minilab_jpeg_decompress(const unsigned char *jpeg, unsigned long jpeg_size,
                                                 struct minilab_jpeg_image *image, char *message);

/* Frees memory these functions returned. */
void minilab_jpeg_free(void *memory);

#endif
