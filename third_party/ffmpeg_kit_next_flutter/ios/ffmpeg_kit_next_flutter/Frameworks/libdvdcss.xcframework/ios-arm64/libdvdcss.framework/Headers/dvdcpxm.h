/**
 * \file dvdcpxm.h
 * \author Maxim V.Anisiutkin <Maxim.Anisiutkin@gmail.com>
 * \author Saifelden Ismail <saifeldenmi@gmail.com>
 *
 * \brief Public types and functions that describe the API of the \e libdvdcss library for the DVD-Audio encryption scheme, CPXM.
 *
 */

/*
 * Copyright (C) 1999-2025 VideoLAN
 * Copyright (C) Maxim V.Anisiutkin <Maxim.Anisiutkin@gmail.com>
 * Copyright (C) 2025 Saifelden Ismail <saifeldenmi@gmail.com>
 *
 * This file is part of libdvdcss.
 *
 * libdvdcss is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * libdvdcss is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with libdvdcss; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

#ifndef _DVDCPXM_H
#define _DVDCPXM_H

#include <dvdcss/dvdcss.h>

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>
/* The block size of a DVD. */
#define DVDCPXM_BLOCK_SIZE     2048

/* The encrypted part of the block. */
#define DVDCPXM_ENCRYPTED_SIZE 1920

/* dvdcpxm_init() returns this value when unprotected media is loaded. */
#define DVDCPXM_MEDIA_UNPR     0

/* dvdcpxm_init() returns this value when CPPM protected media is loaded. */
#define DVDCPXM_MEDIA_CPPM     1

/* dvdcpxm_init() returns this value when CPRM protected media is loaded. */
#define DVDCPXM_MEDIA_CPRM     2

/* Flag to ask dvdcpxm_decrypt() to reset CCI byte of the data it processes. */
#define DVDCPXM_RESET_CCI      1

/* Flag to ask dvdcpxm_decrypt() to preserve CCI byte of the data it processes. */
#define DVDCPXM_PRESERVE_CCI   2

#define TITLES_MAX 9

/*
 * Exported prototypes.
 */

/* Called after the DVD is opened to initialize the cpxm struct, Must be run after dvdcss_open */
/* in the case of DVD-Audio, the MKB must be given as input, 
 * in the case of DVD-VR, the title key should be given as input */
LIBDVDCSS_EXPORT int dvdcpxm_init(dvdcss_t dvdcss, uint8_t *p_input);

/* Same as dvdcss_close but frees the cpxm struct as well */
LIBDVDCSS_EXPORT int dvdcpxm_close ( dvdcss_t dvdcss );


/* Uses dvdcpxm unencrypt instead of dvdcss unsramble */
LIBDVDCSS_EXPORT int dvdcpxm_read ( dvdcss_t dvdcss, void *p_buffer,
                                          int i_blocks,
                                          int i_flags );

/* is just pf_seek since are no title keys in cpxm, the steps from css are not needed */
LIBDVDCSS_EXPORT int dvdcpxm_seek ( dvdcss_t dvdcss, int i_blocks, int i_flags );

/* Uses dvdcpxm unencrypt instead of dvdcss unsramble */
LIBDVDCSS_EXPORT int dvdcpxm_readv ( dvdcss_t dvdcss, void *p_iovec,
                                           int i_blocks,
                                           int i_flags );

#ifdef __cplusplus
}
#endif

#endif /* <dvdcpxm.h> */

