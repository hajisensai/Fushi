/*
 * Copyright (c) 2024 ARTHENICA LTD
 * Copyright (c) 2026 Taner Sener
 *
 * This file is part of FFmpegKitNext.
 *
 * FFmpegKitNext is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * FFmpegKitNext is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General License for more details.
 *
 * You should have received a copy of the GNU Lesser General License
 * along with FFmpegKitNext. If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * FFmpegKitNext changes:
 *
 * 06.2026
 * --------------------------------------------------------
 * - FFmpeg 7.1.5 migration updated this file for wrapper API,
 *   callbacks, cancellation and thread/session-local execution state.
 */

#ifndef FFMPEG_CONTEXT_H
#define FFMPEG_CONTEXT_H

#include "fftools/ffmpeg.h"
#include "libavformat/avio.h"
#include "libavutil/dict.h"

extern __thread BenchmarkTimeStamps current_time;
#if HAVE_TERMIOS_H
#include <termios.h>
extern __thread struct termios oldtty;
#endif
extern __thread int restore_tty;
extern __thread volatile int received_sigterm;
extern __thread volatile int received_nb_signals;
extern __thread atomic_int transcode_init_done;
extern __thread volatile int ffmpeg_exited;
extern __thread int64_t copy_ts_first_pts;
extern __thread int nb_hw_devices;
extern __thread HWDevice **hw_devices;
extern __thread struct EncStatsFile *enc_stats_files;
extern __thread int nb_enc_stats_files;
extern __thread int file_overwrite;
extern __thread int no_file_overwrite;
extern __thread int filter_buffered_frames;
extern __thread int print_graphs;
extern __thread char *print_graphs_file;
extern __thread char *print_graphs_format;
extern __thread FILE *report_file;
extern __thread int report_file_level;
extern __thread int warned_cfg;
extern __thread long globalSessionId;

typedef struct FFmpegContext {

    // cmdutils.c
    char *program_name;
    int program_birth_year;
    AVDictionary *sws_dict;
    AVDictionary *swr_opts;
    AVDictionary *format_opts, *codec_opts;
    int hide_banner;
#if HAVE_COMMANDLINETOARGVW && defined(_WIN32)
    /* Will be leaked on exit */
    char **win32_argv_utf8;
    int win32_argc;
#endif

    // ffmpeg.c
    FILE *vstats_file;
    atomic_uint *nb_output_dumped_ref;
    BenchmarkTimeStamps current_time;
    AVIOContext *progress_avio;
    InputFile **input_files;
    int nb_input_files;
    OutputFile **output_files;
    int nb_output_files;
    FilterGraph **filtergraphs;
    int nb_filtergraphs;
    Decoder **decoders;
    int nb_decoders;
#if HAVE_TERMIOS_H
    /* init terminal so that we can grab keys */
    struct termios oldtty;
    int restore_tty;
#endif
    volatile int received_sigterm;
    volatile int received_nb_signals;
    atomic_int transcode_init_done;
    volatile int ffmpeg_exited;
    int64_t copy_ts_first_pts;

    // ffmpeg_hw.c
    int nb_hw_devices;
    HWDevice **hw_devices;

    // ffmpeg_mux_init.c
    struct EncStatsFile *enc_stats_files;
    int nb_enc_stats_files;

    // ffmpeg_opt.c
    const OptionDef *options;
    HWDevice *filter_hw_device;
    char *vstats_filename;
    float dts_delta_threshold;
    float dts_error_threshold;
    float frame_drop_threshold;
    int do_benchmark;
    int do_benchmark_all;
    int do_hex_dump;
    int do_pkt_dump;
    int copy_ts;
    int start_at_zero;
    int copy_tb;
    int debug_ts;
    int exit_on_error;
    int abort_on_flags;
    int print_stats;
    int stdin_interaction;
    float max_error_rate;
    char *filter_nbthreads;
    int filter_complex_nbthreads;
    int filter_buffered_frames;
    int vstats_version;
    int print_graphs;
    char *print_graphs_file;
    char *print_graphs_format;
    int auto_conversion_filters;
    int64_t stats_period;
    int file_overwrite;
    int no_file_overwrite;
    int ignore_unknown_streams;
    int copy_unknown_streams;
    int recast_media;

    // opt_common.c
    FILE *report_file;
    int report_file_level;
    int warned_cfg;

    // FFmpegKit session context
    long globalSessionId;

    void *arg;

} FFmpegContext;

FFmpegContext *saveFFmpegContext(void *arg);
void *loadFFmpegContext(FFmpegContext *context);

#endif // FFMPEG_CONTEXT_H
