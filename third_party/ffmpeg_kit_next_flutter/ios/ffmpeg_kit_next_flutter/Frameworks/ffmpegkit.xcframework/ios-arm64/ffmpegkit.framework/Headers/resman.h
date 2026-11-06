/*
 * Original FFmpeg source:
 * Copyright (c) 2025 - softworkz
 *
 * FFmpegKitNext modifications:
 * Copyright (c) 2026 Taner Sener
 *
 * This modified file is part of FFmpegKitNext.
 * It is derived from FFmpeg's fftools/resources/resman.h at tag n9.0.1.
 *
 * The original FFmpeg source is licensed under the GNU Lesser General
 * Public License version 2.1 or later. FFmpegKitNext distributes this
 * modified file under the GNU Lesser General Public License version 3 or
 * later, as permitted by that original "or later" license.
 *
 * This file is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This file is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with FFmpegKitNext. If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * Modification history:
 *
 * ffmpeg-kit changes by Taner Sener
 *
 * 08.2026
 * --------------------------------------------------------
 * - FFmpeg 9.0.1 changes migrated
 * - FFmpegKitNext integration updates preserved, including wrapper API,
 *   callbacks, cancellation and thread/session-local execution where applicable
 *
 * 07.2026
 * --------------------------------------------------------
 * - FFmpeg 8.1.2 resource manager declarations migrated
 * - Platform source layout updates preserved
 */

#ifndef FFTOOLS_RESMAN_H
#define FFTOOLS_RESMAN_H

#include <stdint.h>

#include "config.h"
#include "fftools/ffmpeg.h"
#include "libavutil/avutil.h"
#include "libavutil/bprint.h"
#include "fftools/textformat/avtextformat.h"

typedef enum {
    FF_RESOURCE_GRAPH_CSS,
    FF_RESOURCE_GRAPH_HTML,
} FFResourceId;

typedef struct FFResourceDefinition {
    FFResourceId resource_id;
    const char *name;

    const unsigned char *data;
    const unsigned *data_len;

} FFResourceDefinition;

void ff_resman_uninit(void);

char *ff_resman_get_string(FFResourceId resource_id);

#endif /* FFTOOLS_RESMAN_H */
