/**
 * \file dvdcss.h
 * \author Stéphane Borel <stef@via.ecp.fr>
 * \author Sam Hocevar <sam@zoy.org>
 *
 * \brief The \e libdvdcss public header.
 *
 * Public types and functions that describe the API of the \e libdvdcss library.
 */

/*
 * Copyright (C) 1998-2008 VideoLAN
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

#ifndef DVDCSS_DVDCSS_H
#ifndef _DOXYGEN_SKIP_ME
#define DVDCSS_DVDCSS_H 1
#endif

#include <stdint.h>

#include <dvdcss/version.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Library instance handle, to be used for each library call. */
typedef struct dvdcss_s* dvdcss_t;

/** Set of callbacks to access DVDs in custom ways. */
typedef struct dvdcss_stream_cb
{
    /** custom seek callback */
    int ( *pf_seek )  ( void *p_stream, uint64_t i_pos);
    /** custom read callback */
    int ( *pf_read )  ( void *p_stream, void *buffer, int i_read);
    /** custom vectored read callback */
    int ( *pf_readv ) ( void *p_stream, const void *p_iovec, int i_blocks);
} dvdcss_stream_cb;


/** The block size of a DVD. */
#define DVDCSS_BLOCK_SIZE      2048

/** The default flag to be used by \e libdvdcss functions. */
#define DVDCSS_NOFLAGS         0

/** Flag to ask dvdcss_read() to decrypt the data it reads. */
#define DVDCSS_READ_DECRYPT    (1 << 0)

/** Flag to tell dvdcss_seek() it is seeking in MPEG data. */
#define DVDCSS_SEEK_MPEG       (1 << 0)

/** Flag to ask dvdcss_seek() to check the current title key. */
#define DVDCSS_SEEK_KEY        (1 << 1)


/** Macro for setting symbol storage-class or visibility.
 * Define LIBDVDCSS_IMPORTS before importing this header to get the
 * correct DLL storage-class when using \e libdvdcss from MSVC. */
#if defined(LIBDVDCSS_EXPORTS)
#define LIBDVDCSS_EXPORT __declspec(dllexport) extern
#elif defined(LIBDVDCSS_IMPORTS)
#define LIBDVDCSS_EXPORT __declspec(dllimport) extern
#elif defined(SUPPORT_ATTRIBUTE_VISIBILITY_DEFAULT)
#define LIBDVDCSS_EXPORT __attribute__((visibility("default"))) extern
#else
#define LIBDVDCSS_EXPORT extern
#endif


/*
 * Exported prototypes.
 */
LIBDVDCSS_EXPORT dvdcss_t dvdcss_open  ( const char *psz_target );
LIBDVDCSS_EXPORT dvdcss_t dvdcss_open_stream( void *p_stream,
                                              dvdcss_stream_cb *p_stream_cb );
LIBDVDCSS_EXPORT int      dvdcss_close ( dvdcss_t );
LIBDVDCSS_EXPORT int      dvdcss_seek  ( dvdcss_t,
                               int i_blocks,
                               int i_flags );
LIBDVDCSS_EXPORT int      dvdcss_read  ( dvdcss_t,
                               void *p_buffer,
                               int i_blocks,
                               int i_flags );
LIBDVDCSS_EXPORT int      dvdcss_readv ( dvdcss_t,
                               void *p_iovec,
                               int i_blocks,
                               int i_flags );
LIBDVDCSS_EXPORT const char *dvdcss_error ( const dvdcss_t );

LIBDVDCSS_EXPORT int      dvdcss_is_scrambled ( dvdcss_t );

LIBDVDCSS_EXPORT int dvdcss_get_encryption_type ( dvdcss_t );

#ifdef __cplusplus
}
#endif

#endif /* DVDCSS_DVDCSS_H  */
