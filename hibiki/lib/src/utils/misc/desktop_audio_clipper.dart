import 'dart:io';

import 'package:hibiki/src/media/video/ffmpeg_backend.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';

// resolveFfmpegExecutable 已移到 ffmpeg_backend.dart（执行配置的自然归宿）；
// 从这里 re-export 让既有 importer 与测试仍从本文件解析它。
export 'package:hibiki/src/media/video/ffmpeg_backend.dart'
    show resolveFfmpegExecutable;

typedef FfmpegFailureReporter = void Function(String summary);

void _reportFfmpegFailure(
  String source,
  FfmpegRunResult result,
  FfmpegFailureReporter? onFailure,
) {
  final String summary = result.failureSummary;
  onFailure?.call(summary);
  ErrorLogService.instance.log(source, summary, StackTrace.current);
}

void _reportFfmpegProcessException(
  String source,
  ProcessException exception,
  StackTrace stack,
  FfmpegFailureReporter? onFailure,
) {
  final String summary = describeFfmpegProcessException(exception);
  onFailure?.call(summary);
  ErrorLogService.instance.log(source, summary, stack);
}

void _reportFfmpegUnexpectedException(
  String source,
  Object error,
  StackTrace stack,
  FfmpegFailureReporter? onFailure,
) {
  final String summary = error.toString();
  onFailure?.call(summary);
  ErrorLogService.instance.log(source, error, stack);
}

/// Desktop (Windows/Linux/macOS) audio-clip extraction via ffmpeg.
///
/// On Android the sentence-audio clip used for Anki mining is cut by the native
/// `TtsChannelHandler` (MediaExtractor + AacAdtsCueAudioRewriter). There is no
/// native handler off Android, so desktop builds fall back to ffmpeg here.
///
/// ffmpeg is resolved from the `HIBIKI_FFMPEG` env var (absolute path), else
/// `ffmpeg` on PATH. If ffmpeg is absent the call returns null — the same
/// no-audio outcome as before, never a crash.

/// Builds the ffmpeg argument list to cut `[startMs, endMs)` out of [inputPath]
/// and re-encode it to AAC at [outputPath]. Pure (no IO) so it is unit-testable.
///
/// `-ss`/`-t` precede `-i` for fast input seeking (a multi-hour audiobook is not
/// decoded from 0); audio seeking is frame-accurate enough for sentence clips.
///
/// [audioStreamIndex] selects which audio stream to cut (ffmpeg `-map
/// 0:a:<idx>`, 0-based ordinal among the input's audio streams). null/negative
/// leaves ffmpeg's default audio-stream selection (the first / default track) —
/// used for audiobook clips (single audio) and when the user has not switched
/// the video's audio track. A multi-audio video (e.g. JP + EN dub) passes the
/// currently-selected track's ordinal so the clip matches what the user hears.
List<String> buildFfmpegClipArgs({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
}) {
  final double startSeconds = startMs / 1000.0;
  final double durationSeconds = (endMs - startMs) / 1000.0;
  return <String>[
    '-y',
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-t',
    durationSeconds.toStringAsFixed(3),
    '-i',
    inputPath,
    '-vn',
    if (audioStreamIndex != null && audioStreamIndex >= 0) ...<String>[
      '-map',
      '0:a:$audioStreamIndex',
    ],
    '-c:a',
    'aac',
    outputPath,
  ];
}

/// Builds the ffmpeg argument list to extract the embedded cover art of
/// [inputPath] into [outputPath] (re-encoded to the output extension, e.g. jpg).
List<String> buildFfmpegCoverArgs({
  required String inputPath,
  required String outputPath,
}) {
  return <String>[
    '-y',
    '-i',
    inputPath,
    '-an',
    '-frames:v',
    '1',
    '-update',
    '1',
    outputPath,
  ];
}

/// Extracts the embedded cover art of [audioPath] into [outputPath] via ffmpeg.
/// Returns [outputPath] if a cover was written, else null (no cover / no ffmpeg
/// / error). Does not treat a non-zero ffmpeg exit as fatal — a file with no
/// cover stream simply produces no output.
Future<String?> extractEmbeddedCoverViaFfmpeg({
  required String audioPath,
  required String outputPath,
}) async {
  if (!File(audioPath).existsSync()) return null;
  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegCoverArgs(inputPath: audioPath, outputPath: outputPath),
      const Duration(seconds: 30),
    );
    final int? code = result.returnCode;
    if (code == null) {
      // Timed out / killed: drop any partial output.
      if (output.existsSync()) {
        try {
          output.deleteSync();
        } catch (_) {}
      }
      return null;
    }
    // ffmpeg exits non-zero when there is no cover stream; rely on the output.
    if (output.existsSync() && output.lengthSync() > 0) return outputPath;
    return null;
  } on ProcessException catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedCoverViaFfmpeg', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedCoverViaFfmpeg', e, stack);
    return null;
  }
}

/// Builds the ffmpeg argument list to extract the **embedded cover art** of a
/// video container (e.g. an mkv with a `cover.jpg`/`cover.png` attachment, or an
/// mp4 with an `attached_pic` poster) into [outputPath]. Pure (no IO) so it is
/// unit-testable.
///
/// `-map 0:v:disp:attached_pic` selects **only** the video stream(s) whose
/// disposition is `attached_pic` — the cover art. Crucially there is **no**
/// trailing `?`: when the input has no cover art the map matches no stream and
/// ffmpeg exits non-zero **without writing any file**, so the caller can tell
/// "no embedded cover" apart from "extracted a cover" and fall back to a frame
/// grab. (A trailing `?` would make ffmpeg silently fall through to the main
/// video's first frame, defeating the prefer-embedded distinction.)
///
/// Matroska stores cover art as a file **attachment** (`filename=cover.*`,
/// `mimetype=image/*`); ffmpeg surfaces it as a video stream tagged
/// `(attached pic)` with the `attached_pic` disposition, which this selector
/// matches. `-vcodec copy` is intentionally **not** used: re-encoding to the
/// output extension (jpg) normalises png/webp/etc. covers to a uniform thumbnail
/// the shelf can display, same as the frame-grab path.
List<String> buildFfmpegEmbeddedCoverArgs({
  required String inputPath,
  required String outputPath,
}) {
  return <String>[
    '-y',
    '-i',
    inputPath,
    '-an',
    '-map',
    '0:v:disp:attached_pic',
    '-frames:v',
    '1',
    '-update',
    '1',
    outputPath,
  ];
}

/// Extracts the **embedded cover art** of the video [inputPath] into
/// [outputPath] via ffmpeg (see [buildFfmpegEmbeddedCoverArgs]). Returns
/// [outputPath] if a cover was written, else null — null specifically means
/// "this container has no embedded cover art" (the map matched no stream), so
/// the import flow falls back to [extractVideoFrameViaFfmpeg].
///
/// Mirrors [extractVideoFrameViaFfmpeg]: bounded timeout, drops partial output
/// on timeout, never throws for the caller (no ffmpeg on mobile / no cover both
/// yield null, not a crash). A non-zero ffmpeg exit (no matching cover stream)
/// is treated as "no cover", not fatal.
Future<String?> extractEmbeddedVideoCoverViaFfmpeg({
  required String inputPath,
  required String outputPath,
}) async {
  if (!File(inputPath).existsSync()) return null;
  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegEmbeddedCoverArgs(
        inputPath: inputPath,
        outputPath: outputPath,
      ),
      const Duration(seconds: 30),
    );
    final int? code = result.returnCode;
    if (code == null) {
      if (output.existsSync()) {
        try {
          output.deleteSync();
        } catch (_) {}
      }
      return null;
    }
    // No-cover containers exit non-zero ("Stream map matches no streams") and
    // write nothing; rely on the output file to discriminate.
    if (output.existsSync() && output.lengthSync() > 0) return outputPath;
    return null;
  } on ProcessException catch (e, stack) {
    ErrorLogService.instance
        .log('extractEmbeddedVideoCoverViaFfmpeg', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance
        .log('extractEmbeddedVideoCoverViaFfmpeg', e, stack);
    return null;
  }
}

/// Builds the ffmpeg argument list to grab a single frame from [inputPath] at
/// [atSeconds] (input seek, fast) and write it to [outputPath] (the output
/// extension, e.g. `.jpg`, picks the encoder). Pure (no IO) so it is
/// unit-testable.
///
/// `-ss <atSeconds>` precedes `-i` for fast input seeking (a multi-GB episode is
/// not decoded from 0). [atSeconds] is clamped to >= 0 so a tiny/short video
/// never seeks negative; seeking past the end yields no frame (the extractor
/// then reports null). A non-zero default (e.g. 10s) avoids a black intro frame.
List<String> buildFfmpegFrameArgs({
  required String inputPath,
  required String outputPath,
  double atSeconds = 0.0,
}) {
  final double seek = atSeconds < 0 ? 0.0 : atSeconds;
  return <String>[
    '-y',
    '-ss',
    seek.toStringAsFixed(3),
    '-i',
    inputPath,
    '-an',
    '-frames:v',
    '1',
    '-update',
    '1',
    outputPath,
  ];
}

/// Grabs a single video frame from [inputPath] at [atSeconds] into [outputPath]
/// via ffmpeg (used as the shelf cover thumbnail). Returns [outputPath] on
/// success, or null if the input is missing, ffmpeg is not installed, or no
/// frame was written (e.g. seek past the end).
///
/// Mirrors [extractEmbeddedCoverViaFfmpeg]: bounded timeout, drops partial
/// output on timeout / failure, never throws for the caller (no ffmpeg on
/// mobile simply means no thumbnail, not a crash).
Future<String?> extractVideoFrameViaFfmpeg({
  required String inputPath,
  required String outputPath,
  double atSeconds = 10.0,
}) async {
  if (!File(inputPath).existsSync()) return null;
  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegFrameArgs(
        inputPath: inputPath,
        outputPath: outputPath,
        atSeconds: atSeconds,
      ),
      const Duration(seconds: 30),
    );
    final int? code = result.returnCode;
    if (code == null) {
      if (output.existsSync()) {
        try {
          output.deleteSync();
        } catch (_) {}
      }
      return null;
    }
    if (output.existsSync() && output.lengthSync() > 0) return outputPath;
    return null;
  } on ProcessException catch (e, stack) {
    ErrorLogService.instance.log('extractVideoFrameViaFfmpeg', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('extractVideoFrameViaFfmpeg', e, stack);
    return null;
  }
}

/// 视频制卡用：把 `[startMs, endMs)` 这段 cue 时间窗导出成**循环动图 GIF**
/// （用户要的「cue 时间段的动图」而非单帧截图）。纯函数（无 IO），可单测。
///
/// 单次 ffmpeg 调用内做两遍调色板（`palettegen`/`paletteuse`）以避免低质抖动：
/// `fps=[fps],scale=[width]:-2:lanczos,split → palettegen → paletteuse`。
/// `-2` 让高度按宽度等比且取偶（gif 编码要求偶数维度）。`-ss`/`-t` 置于 `-i` 前做
/// 快速输入定位（多 GB 剧集不从 0 解码）。时长 clamp 到 `(0, maxDurationMs]`：cue 太长
/// 时只取前段，避免 gif 体积/耗时爆炸；endMs<=startMs 时调用方应已拦截。
List<String> buildFfmpegClipGifArgs({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int fps = 12,
  int width = 480,
  int maxDurationMs = 10000,
}) {
  final double startSeconds = (startMs < 0 ? 0 : startMs) / 1000.0;
  final int rawDur = endMs - startMs;
  final int clampedDur =
      rawDur > maxDurationMs ? maxDurationMs : (rawDur < 1 ? 1 : rawDur);
  final double durationSeconds = clampedDur / 1000.0;
  final String filter = 'fps=$fps,scale=$width:-2:flags=lanczos,'
      'split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse';
  return <String>[
    '-y',
    '-ss',
    startSeconds.toStringAsFixed(3),
    '-t',
    durationSeconds.toStringAsFixed(3),
    '-i',
    inputPath,
    '-an',
    '-filter_complex',
    filter,
    '-loop',
    '0',
    outputPath,
  ];
}

/// 把 [inputPath] 的 `[startMs, endMs)` 段导出成循环 GIF 到 [outputPath]（见
/// [buildFfmpegClipGifArgs]）。成功返回 [outputPath]，否则 null（范围非法 / 输入缺失 /
/// ffmpeg 不存在（移动端无 CLI ffmpeg）/ 编码无输出）——调用方据此回退单帧截图。
///
/// 镜像 [extractAudioSegmentViaFfmpeg]：有界超时、失败/超时清理半成品、对调用方不抛。
Future<String?> extractClipGifViaFfmpeg({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  FfmpegFailureReporter? onFailure,
}) async {
  if (endMs <= startMs) return null;
  if (!File(inputPath).existsSync()) return null;

  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegClipGifArgs(
        inputPath: inputPath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
      ),
      const Duration(seconds: 120),
    );
    final int? code = result.returnCode;
    if (code == 0 && output.existsSync() && output.lengthSync() > 0) {
      return outputPath;
    }
    if (output.existsSync()) {
      try {
        output.deleteSync();
      } catch (_) {}
    }
    _reportFfmpegFailure('extractClipGifViaFfmpeg', result, onFailure);
    return null;
  } on ProcessException catch (e, stack) {
    // 移动端无 CLI ffmpeg：优雅回退（调用方改用单帧截图）。
    _reportFfmpegProcessException(
      'extractClipGifViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  } catch (e, stack) {
    _reportFfmpegUnexpectedException(
      'extractClipGifViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  }
}

/// Builds the ffmpeg argument list to demux the [streamIndex]-th subtitle track
/// of [inputPath] into [outputPath]. Pure (no IO) so it is unit-testable.
///
/// `0:s:$streamIndex` selects the Nth subtitle stream of the (only) input;
/// ffmpeg infers the output subtitle format from [outputPath]'s extension
/// (e.g. `.ass` → ASS), so an embedded ASS track round-trips losslessly.
List<String> buildFfmpegSubtitleArgs({
  required String inputPath,
  required int streamIndex,
  required String outputPath,
}) {
  return <String>[
    '-y',
    '-i',
    inputPath,
    '-map',
    '0:s:$streamIndex',
    outputPath,
  ];
}

/// Demuxes the [streamIndex]-th embedded subtitle track of [inputPath] into
/// [outputPath] via ffmpeg. Returns [outputPath] on success, or null if the
/// input is missing, the stream index is out of range, ffmpeg is not installed,
/// or no subtitle text was written.
///
/// Mirrors [extractAudioSegmentViaFfmpeg]: bounded timeout, drops partial
/// output on timeout / failure, never throws for the caller (a video with no
/// subtitle track is a no-op fallback, not a crash).
Future<String?> extractEmbeddedSubtitleViaFfmpeg({
  required String inputPath,
  required int streamIndex,
  required String outputPath,
}) async {
  if (!File(inputPath).existsSync()) return null;

  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    // 30s bounds a hung demux; subtitle demuxing is text-only (no re-encode of
    // the multi-GB video), so even a long episode finishes in well under this.
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegSubtitleArgs(
        inputPath: inputPath,
        streamIndex: streamIndex,
        outputPath: outputPath,
      ),
      const Duration(seconds: 30),
    );
    final int? code = result.returnCode;
    if (code == 0 && output.existsSync() && output.lengthSync() > 0) {
      return outputPath;
    }
    if (output.existsSync()) {
      try {
        output.deleteSync();
      } catch (_) {}
    }
    _reportFfmpegFailure('extractEmbeddedSubtitleViaFfmpeg', result, null);
    return null;
  } on ProcessException catch (e, stack) {
    // ffmpeg not installed / not on PATH — graceful no-subtitle fallback.
    ErrorLogService.instance.log('extractEmbeddedSubtitleViaFfmpeg', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedSubtitleViaFfmpeg', e, stack);
    return null;
  }
}

/// Builds the ffmpeg argument list to demux MANY embedded subtitle tracks of
/// [inputPath] in a **single pass** — one `-i`, then `-map 0:s:i out_i` repeated.
/// Pure (no IO) so it is unit-testable.
///
/// [outputs] maps each subtitle relative stream index (`-map 0:s:N`) to its
/// output path; the path extension drives ffmpeg's output muxer (`.srt`→SubRip,
/// `.ass`→ASS…). Maps are emitted in ascending stream-index order for
/// deterministic args. The whole point: an interleaved multi-GB container is
/// read **once** for every track at once (the read dominates wall-clock), so
/// extracting 8 tracks costs the same as extracting one — switching among tracks
/// no longer re-reads the file each time (BUG-104).
List<String> buildFfmpegMultiSubtitleArgs({
  required String inputPath,
  required Map<int, String> outputs,
}) {
  final List<String> args = <String>['-y', '-i', inputPath];
  final List<int> indices = outputs.keys.toList()..sort();
  for (final int idx in indices) {
    args.addAll(<String>['-map', '0:s:$idx', outputs[idx]!]);
  }
  return args;
}

/// Demuxes ALL requested embedded subtitle tracks of [inputPath] in one ffmpeg
/// pass (see [buildFfmpegMultiSubtitleArgs]). Returns the subset of [outputs]
/// actually written (file exists and non-empty); a partially-failed batch (one
/// corrupt track) still yields the tracks that succeeded rather than dropping
/// everything.
///
/// [timeout] bounds a hung demux. Unlike single-clip encodes, the read time of a
/// big interleaved container grows with its size, so callers pass a size-scaled
/// timeout (see `subtitleExtractTimeoutForBytes`). Never throws for the caller:
/// missing input / absent ffmpeg / error all yield an empty map (no-subtitle
/// fallback, not a crash).
Future<Map<int, String>> extractEmbeddedSubtitlesViaFfmpeg({
  required String inputPath,
  required Map<int, String> outputs,
  Duration timeout = const Duration(seconds: 180),
}) async {
  if (outputs.isEmpty) return const <int, String>{};
  if (!File(inputPath).existsSync()) return const <int, String>{};
  try {
    for (final String out in outputs.values) {
      File(out).parent.createSync(recursive: true);
    }
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegMultiSubtitleArgs(inputPath: inputPath, outputs: outputs),
      timeout,
    );
    // Filter by what actually landed: even a non-zero exit (one bad track) can
    // leave the other tracks written — keep them, drop empty stubs.
    final Map<int, String> written = <int, String>{};
    outputs.forEach((int idx, String out) {
      final File f = File(out);
      if (f.existsSync() && f.lengthSync() > 0) {
        written[idx] = out;
      } else if (f.existsSync()) {
        try {
          f.deleteSync();
        } catch (_) {}
      }
    });
    if (written.isEmpty) {
      _reportFfmpegFailure(
        'extractEmbeddedSubtitlesViaFfmpeg',
        result,
        null,
      );
    }
    return written;
  } on ProcessException catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedSubtitlesViaFfmpeg', e, stack);
    return const <int, String>{};
  } catch (e, stack) {
    ErrorLogService.instance.log('extractEmbeddedSubtitlesViaFfmpeg', e, stack);
    return const <int, String>{};
  }
}

/// Runs ffmpeg with [args] via the active [FfmpegBackend] and returns the exit
/// code (null on timeout). Behaviour is unchanged from the historical inline
/// `Process.start` path — [CliFfmpegBackend] replicates it; the mobile
/// [KitFfmpegBackend] (self-built ffmpeg-kit) slots in transparently. Throws
/// [ProcessException] when ffmpeg is unavailable — callers handle that.
Future<FfmpegRunResult> _runFfmpeg(List<String> args, Duration timeout) async {
  final FfmpegRunResult result =
      await resolveFfmpegBackend().run(args, timeout);
  return result;
}

/// Cuts `[startMs, endMs)` out of [inputPath] into [outputPath] using ffmpeg.
/// Returns [outputPath] on success, or null if the range is invalid, the input
/// is missing, ffmpeg is not installed, or the cut produced no output.
Future<String?> extractAudioSegmentViaFfmpeg({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  int? audioStreamIndex,
  FfmpegFailureReporter? onFailure,
}) async {
  if (endMs <= startMs) return null;
  if (!File(inputPath).existsSync()) return null;

  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    // 120s bounds a hung encode; even a several-minute clip re-encodes to AAC
    // far faster than real time, so this never truncates a legitimate clip.
    final FfmpegRunResult result = await _runFfmpeg(
      buildFfmpegClipArgs(
        inputPath: inputPath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
        audioStreamIndex: audioStreamIndex,
      ),
      const Duration(seconds: 120),
    );
    final int? code = result.returnCode;
    if (code == 0 && output.existsSync() && output.lengthSync() > 0) {
      return outputPath;
    }
    if (output.existsSync()) {
      try {
        output.deleteSync();
      } catch (_) {}
    }
    _reportFfmpegFailure('extractAudioSegmentViaFfmpeg', result, onFailure);
    return null;
  } on ProcessException catch (e, stack) {
    // ffmpeg not installed / not on PATH — graceful no-audio fallback.
    _reportFfmpegProcessException(
      'extractAudioSegmentViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  } catch (e, stack) {
    _reportFfmpegUnexpectedException(
      'extractAudioSegmentViaFfmpeg',
      e,
      stack,
      onFailure,
    );
    return null;
  }
}
