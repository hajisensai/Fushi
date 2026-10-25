/*
 * This file is part of libdvdcss
 * Copyright (C) 2015 VideoLAN
 *
 * This file is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library. If not, see
 * <http://www.gnu.org/licenses/>.
 */

#ifndef DVDCSS_VERSION_H_
#define DVDCSS_VERSION_H_

#define DVDCSS_VERSION_CODE(major, minor, micro) \
    (((major) * 10000) +                         \
     ((minor) *   100) +                         \
     ((micro) *     1))

#define DVDCSS_VERSION_MAJOR 1
#define DVDCSS_VERSION_MINOR 6
#define DVDCSS_VERSION_MICRO 0

#define DVDCSS_VERSION_STRING "1.6.0"

#define DVDCSS_VERSION \
    DVDCSS_VERSION_CODE(DVDCSS_VERSION_MAJOR, DVDCSS_VERSION_MINOR, DVDCSS_VERSION_MICRO)

#endif /* DVDCSS_VERSION_H_ */
