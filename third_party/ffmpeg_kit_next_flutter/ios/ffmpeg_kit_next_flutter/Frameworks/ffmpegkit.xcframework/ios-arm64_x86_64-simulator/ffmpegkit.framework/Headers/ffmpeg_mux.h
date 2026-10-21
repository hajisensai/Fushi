/*
 * Original FFmpeg source:
 * Derived from FFmpeg source file fftools/ffmpeg_mux.h.
 *
 * FFmpegKitNext modifications:
 * Copyright (c) 2022, 2026 Taner Sener
 * Copyright (c) 2023-2024 ARTHENICA LTD
 *
 * This modified file is part of FFmpegKitNext.
 * It is derived from FFmpeg's fftools/ffmpeg_mux.h at tag n9.0.1.
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
 * - FFmpeg 8.1.2 changes migrated
 * - Files moved under apple/src/fftools using upstream filenames
 * - FFmpegKitNext integration updates preserved, including wrapper API,
 *   callbacks, cancellation and thread/session-local execution where applicable
 *
 * 06.2026
 * --------------------------------------------------------
 * - FFmpeg 7.1.5 changes migrated
 * - FFmpegKitNext integration updates preserved, including wrapper API,
 *   callbacks, cancellation and thread/session-local execution where applicable
 *
 * ffmpeg-kit changes by ARTHENICA LTD
 *
 * 11.2024
 * --------------------------------------------------------
 * - FFmpeg 6.1 changes migrated
 *
 * 07.2023
 * --------------------------------------------------------
 * - FFmpeg 6.0 changes migrated
 * - fftools header names updated
 * - want_sdp made thread-local
 * - EncStatsFile declaration migrated from ffmpeg_mux_init.c
 * - WARN_MULTIPLE_OPT_USAGE, MATCH_PER_STREAM_OPT, MATCH_PER_TYPE_OPT,
 * SPECIFIER_OPT_FMT declarations migrated from ffmpeg.h
 * - ms_from_ost migrated to ffmpeg_mux.c
 */

#ifndef FFTOOLS_FFMPEG_MUX_H
#define FFTOOLS_FFMPEG_MUX_H

#include <stdatomic.h>
#include <stdint.h>

#include "ffmpeg_sched.h"

#include "libavformat/avformat.h"

#include "libavcodec/packet.h"

#include "libavutil/dict.h"
#include "libavutil/fifo.h"

typedef struct MuxStream {
    OutputStream    ost;

    /**
     * Codec parameters for packets submitted to the muxer (i.e. before
     * bitstream filtering, if any).
     */
    AVCodecParameters *par_in;

    // name used for logging
    char            log_name[32];

    AVBSFContext   *bsf_ctx;
    AVPacket       *bsf_pkt;

    AVPacket       *pkt;

    EncStats        stats;

    int             sch_idx;
    int             sch_idx_enc;
    int             sch_idx_src;

    int             sq_idx_mux;

    int64_t         max_frames;

    // timestamp from which the streamcopied streams should start,
    // in AV_TIME_BASE_Q;
    // everything before it should be discarded
    int64_t         ts_copy_start;

    /* dts of the last packet sent to the muxer, in the stream timebase
     * used for making up missing dts values */
    int64_t         last_mux_dts;

    int64_t         stream_duration;
    AVRational      stream_duration_tb;

    // state for av_rescale_delta() call for audio in write_packet()
    int64_t         ts_rescale_delta_last;

    // combined size of all the packets sent to the muxer
    uint64_t        data_size_mux;

    int             copy_initial_nonkeyframes;
    int             copy_prior_start;
    int             streamcopy_started;

    AVRational      frame_rate;
    AVRational      max_frame_rate;
    int             force_fps;

    const char     *apad;
} MuxStream;

typedef struct Muxer {
    OutputFile              of;

    // name used for logging
    char                    log_name[32];

    AVFormatContext        *fc;

    Scheduler              *sch;
    unsigned                sch_idx;

    // OutputStream indices indexed by scheduler stream indices
    int                    *sch_stream_idx;
    int                  nb_sch_stream_idx;

    AVDictionary           *opts;

    // used to validate that all encoder avoptions have been actually used
    AVDictionary           *enc_opts_used;

    /* filesize limit expressed in bytes */
    int64_t                 limit_filesize;
    atomic_int_least64_t    last_filesize;
    int                     header_written;

    SyncQueue              *sq_mux;
    AVPacket               *sq_pkt;
} Muxer;

int mux_check_init(void *arg);

static inline MuxStream *ms_from_ost(OutputStream *ost)
{
    return (MuxStream*)ost;
}

#endif /* FFTOOLS_FFMPEG_MUX_H */
