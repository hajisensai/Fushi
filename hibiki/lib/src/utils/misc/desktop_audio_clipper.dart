import 'dart:io';

import 'package:hibiki/src/utils/misc/error_log_service.dart';

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
List<String> buildFfmpegClipArgs({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
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
    '-c:a',
    'aac',
    outputPath,
  ];
}

/// Resolves the ffmpeg executable: `HIBIKI_FFMPEG` override, else `ffmpeg`.
String resolveFfmpegExecutable() {
  final String? override = Platform.environment['HIBIKI_FFMPEG']?.trim();
  if (override != null && override.isNotEmpty) return override;
  return 'ffmpeg';
}

/// Cuts `[startMs, endMs)` out of [inputPath] into [outputPath] using ffmpeg.
/// Returns [outputPath] on success, or null if the range is invalid, the input
/// is missing, ffmpeg is not installed, or the cut produced no output.
Future<String?> extractAudioSegmentViaFfmpeg({
  required String inputPath,
  required int startMs,
  required int endMs,
  required String outputPath,
}) async {
  if (endMs <= startMs) return null;
  if (!File(inputPath).existsSync()) return null;

  final File output = File(outputPath);
  try {
    output.parent.createSync(recursive: true);
    final ProcessResult result = await Process.run(
      resolveFfmpegExecutable(),
      buildFfmpegClipArgs(
        inputPath: inputPath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
      ),
    );
    if (result.exitCode == 0 &&
        output.existsSync() &&
        output.lengthSync() > 0) {
      return outputPath;
    }
    ErrorLogService.instance.log(
      'extractAudioSegmentViaFfmpeg',
      'ffmpeg exit ${result.exitCode}: ${result.stderr}',
      StackTrace.current,
    );
    return null;
  } on ProcessException catch (e, stack) {
    // ffmpeg not installed / not on PATH — graceful no-audio fallback.
    ErrorLogService.instance.log('extractAudioSegmentViaFfmpeg', e, stack);
    return null;
  } catch (e, stack) {
    ErrorLogService.instance.log('extractAudioSegmentViaFfmpeg', e, stack);
    return null;
  }
}
