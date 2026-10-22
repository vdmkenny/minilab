/*
 * negscan's JPEG compression and decompression through libjpeg (see jpeg_shim.h). The pattern is
 * libjpeg's own (`example.c`): the error manager's `error_exit` formats the message and jumps back
 * to the `setjmp` in the function that started the work, which cleans up and returns.
 */

#include "jpeg_shim.h"

#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <jpeglib.h>

/* The red, green and blue samples of a pixel. */
#define CHANNELS 3
/* The marker an ICC profile travels in, APP2. */
#define ICC_MARKER (JPEG_APP0 + 2)
/* The longest a marker can be. */
#define MARKER_LENGTH_MAX 0xFFFF

struct error_manager {
    struct jpeg_error_mgr pub;
    jmp_buf jump;
    char *message;
};

static void exit_with_error(j_common_ptr cinfo)
{
    struct error_manager *errors = (struct error_manager *)cinfo->err;
    (*cinfo->err->format_message)(cinfo, errors->message);
    longjmp(errors->jump, 1);
}

/* Warnings, such as for a file cut short, would go to stderr: they stay quiet. */
static void ignore_message(j_common_ptr cinfo)
{
    (void)cinfo;
}

static void set_up_errors(struct error_manager *errors, char *message)
{
    jpeg_std_error(&errors->pub);
    errors->pub.error_exit = exit_with_error;
    errors->pub.output_message = ignore_message;
    errors->message = message;
    message[0] = '\0';
}

enum negscan_jpeg_result negscan_jpeg_compress(const struct negscan_jpeg_compression *image,
                                               unsigned char **jpeg, unsigned long *jpeg_size,
                                               char *message)
{
    struct jpeg_compress_struct cinfo;
    struct error_manager errors;

    *jpeg = NULL;
    *jpeg_size = 0;
    set_up_errors(&errors, message);
    cinfo.err = &errors.pub;
    if (setjmp(errors.jump)) {
        jpeg_destroy_compress(&cinfo);
        /* The memory destination keeps its latest buffer in `*jpeg`. */
        free(*jpeg);
        *jpeg = NULL;
        *jpeg_size = 0;
        return NEGSCAN_JPEG_FAILED;
    }

    jpeg_create_compress(&cinfo);
    jpeg_mem_dest(&cinfo, jpeg, jpeg_size);
    cinfo.image_width = image->width;
    cinfo.image_height = image->height;
    cinfo.input_components = CHANNELS;
    cinfo.in_color_space = JCS_RGB;
    jpeg_set_defaults(&cinfo);
    jpeg_set_quality(&cinfo, image->quality, TRUE);
    /* The defaults sample the luminance at twice the colour's resolution both ways. */
    if (!image->subsample_chroma) {
        cinfo.comp_info[0].h_samp_factor = 1;
        cinfo.comp_info[0].v_samp_factor = 1;
    }
    cinfo.optimize_coding = TRUE;

    jpeg_start_compress(&cinfo, TRUE);
    if (image->icc_profile != NULL)
        jpeg_write_icc_profile(&cinfo, image->icc_profile, image->icc_profile_size);
    while (cinfo.next_scanline < cinfo.image_height) {
        JSAMPROW row = (JSAMPROW)(image->pixels + (size_t)cinfo.next_scanline * image->row_bytes);
        jpeg_write_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_compress(&cinfo);
    jpeg_destroy_compress(&cinfo);
    return NEGSCAN_JPEG_OK;
}

enum negscan_jpeg_result negscan_jpeg_decompress(const unsigned char *jpeg, unsigned long jpeg_size,
                                                 struct negscan_jpeg_image *image, char *message)
{
    struct jpeg_decompress_struct cinfo;
    struct error_manager errors;
    size_t row_bytes;

    image->pixels = NULL;
    image->width = 0;
    image->height = 0;
    image->icc_profile = NULL;
    image->icc_profile_size = 0;
    set_up_errors(&errors, message);
    cinfo.err = &errors.pub;
    if (setjmp(errors.jump)) {
        jpeg_destroy_decompress(&cinfo);
        free(image->pixels);
        image->pixels = NULL;
        free(image->icc_profile);
        image->icc_profile = NULL;
        image->icc_profile_size = 0;
        return NEGSCAN_JPEG_FAILED;
    }

    jpeg_create_decompress(&cinfo);
    jpeg_mem_src(&cinfo, jpeg, jpeg_size);
    jpeg_save_markers(&cinfo, ICC_MARKER, MARKER_LENGTH_MAX);
    jpeg_read_header(&cinfo, TRUE);
    jpeg_read_icc_profile(&cinfo, &image->icc_profile, &image->icc_profile_size);
    cinfo.out_color_space = JCS_RGB;
    jpeg_start_decompress(&cinfo);

    row_bytes = (size_t)cinfo.output_width * CHANNELS;
    if (cinfo.output_height != 0 && row_bytes > SIZE_MAX / cinfo.output_height)
        image->pixels = NULL;
    else
        image->pixels = malloc(row_bytes * cinfo.output_height);
    if (image->pixels == NULL) {
        jpeg_destroy_decompress(&cinfo);
        free(image->icc_profile);
        image->icc_profile = NULL;
        image->icc_profile_size = 0;
        return NEGSCAN_JPEG_OUT_OF_MEMORY;
    }
    image->width = cinfo.output_width;
    image->height = cinfo.output_height;
    while (cinfo.output_scanline < cinfo.output_height) {
        JSAMPROW row = image->pixels + (size_t)cinfo.output_scanline * row_bytes;
        jpeg_read_scanlines(&cinfo, &row, 1);
    }
    jpeg_finish_decompress(&cinfo);
    jpeg_destroy_decompress(&cinfo);
    return NEGSCAN_JPEG_OK;
}

void negscan_jpeg_free(void *memory)
{
    free(memory);
}
