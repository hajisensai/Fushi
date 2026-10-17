/*
 * This file is part of FFmpeg.
 *
 * FFmpeg is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * FFmpeg is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FFmpeg; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#ifndef AVUTIL_FILE_H
#define AVUTIL_FILE_H

#include <stddef.h>
#include <stdint.h>

#include "attributes.h"

/**
 * @file
 * Misc file utilities.
 */

/**
 * Read the file with name filename, and put its content in a newly
 * allocated buffer or map it with mmap() when available.
 * In case of success set *bufptr to the read or mmapped buffer, and
 * *size to the size in bytes of the buffer in *bufptr.
 * Unlike mmap this function succeeds with zero sized files, in this
 * case *bufptr will be set to NULL and *size will be set to 0.
 * The returned buffer must be released with av_file_unmap().
 *
 * @param filename path to the file
 * @param[out] bufptr pointee is set to the mapped or allocated buffer
 * @param[out] size pointee is set to the size in bytes of the buffer
 * @param log_offset loglevel offset used for logging
 * @param log_ctx context used for logging
 * @return a non negative number in case of success, a negative value
 * corresponding to an AVERROR error code in case of failure
 */
av_warn_unused_result
int av_file_map(const char *filename, uint8_t **bufptr, size_t *size,
                int log_offset, void *log_ctx);

/**
 * Unmap or free the buffer bufptr created by av_file_map().
 *
 * @param bufptr the buffer previously created with av_file_map()
 * @param size size in bytes of bufptr, must be the same as returned
 * by av_file_map()
 */
void av_file_unmap(uint8_t *bufptr, size_t size);

#endif /* AVUTIL_FILE_H */
/*
 * Copyright (c) 2021 Taner Sener
 *
 * This file is part of FFmpegKit.
 *
 * FFmpegKit is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * FFmpegKit is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with FFmpegKit.  If not, see <http://www.gnu.org/licenses/>.
 */

#ifndef AVUTIL_FILE_FFMPEG_KIT_PROTOCOLS_H
#define AVUTIL_FILE_FFMPEG_KIT_PROTOCOLS_H

typedef int (*saf_open_function)(int);

typedef int (*saf_close_function)(int);

typedef int (*ffkit_protocol_open_function)(int64_t, int, void **);

typedef int (*ffkit_protocol_read_function)(void *, unsigned char *, int);

typedef int (*ffkit_protocol_write_function)(void *, const unsigned char *, int);

typedef int64_t (*ffkit_protocol_seek_function)(void *, int64_t, int);

typedef int (*ffkit_protocol_close_function)(void *);

saf_open_function av_get_saf_open(void);

saf_close_function av_get_saf_close(void);

void av_set_saf_open(saf_open_function);

void av_set_saf_close(saf_close_function);

ffkit_protocol_open_function av_get_ffkitmem_open(void);

ffkit_protocol_read_function av_get_ffkitmem_read(void);

ffkit_protocol_write_function av_get_ffkitmem_write(void);

ffkit_protocol_seek_function av_get_ffkitmem_seek(void);

ffkit_protocol_close_function av_get_ffkitmem_close(void);

void av_set_ffkitmem_functions(ffkit_protocol_open_function,
                               ffkit_protocol_read_function,
                               ffkit_protocol_write_function,
                               ffkit_protocol_seek_function,
                               ffkit_protocol_close_function);

ffkit_protocol_open_function av_get_ffkitstream_open(void);

ffkit_protocol_read_function av_get_ffkitstream_read(void);

ffkit_protocol_write_function av_get_ffkitstream_write(void);

ffkit_protocol_seek_function av_get_ffkitstream_seek(void);

ffkit_protocol_close_function av_get_ffkitstream_close(void);

void av_set_ffkitstream_functions(ffkit_protocol_open_function,
                                  ffkit_protocol_read_function,
                                  ffkit_protocol_write_function,
                                  ffkit_protocol_seek_function,
                                  ffkit_protocol_close_function);

#endif /* AVUTIL_FILE_FFMPEG_KIT_PROTOCOLS_H */
