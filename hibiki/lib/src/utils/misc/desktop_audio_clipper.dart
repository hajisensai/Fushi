import 'dart:async';
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
    final int? code = await _runFfmpeg(
      buildFfmpegCoverArgs(inputPath: audioPath, outputPath: outputPath),
      const Duration(seconds: 30),
    );
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

/// Resolves the ffmpeg executable: `HIBIKI_FFMPEG` override, else `ffmpeg`.
String resolveFfmpegExecutable() {
  final String? override = Platform.environment['HIBIKI_FFMPEG']?.trim();
  if (override != null && override.isNotEmpty) return override;
  return 'ffmpeg';
}

/// Runs ffmpeg with [args], draining both pipes, and kills it if it does not
/// finish within [timeout]. Returns the exit code, or null on timeout. The
/// timeout bounds a hung/pathological encode (e.g. an unusually long clip on a
/// slow machine) so it can never block the mining flow indefinitely. Throws
/// [ProcessException] if ffmpeg is not installed — callers handle that.
Future<int?> _runFfmpeg(List<String> args, Duration timeout) async {
  final Process process = await Process.start(resolveFfmpegExecutable(), args);
  // Drain both pipes: a full OS pipe buffer (ffmpeg writes progress to stderr)
  // would otherwise deadlock the process before it can exit.
  unawaited(process.stdout.drain<void>());
  final Future<void> stderrDrained = process.stderr.drain<void>();
  try {
    final int code = await process.exitCode.timeout(timeout);
    await stderrDrained;
    return code;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    return null;
  }
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
    // 120s bounds a hung encode; even a several-minute clip re-encodes to AAC
    // far faster than real time, so this never truncates a legitimate clip.
    final int? code = await _runFfmpeg(
      buildFfmpegClipArgs(
        inputPath: inputPath,
        startMs: startMs,
        endMs: endMs,
        outputPath: outputPath,
      ),
      const Duration(seconds: 120),
    );
    if (code == 0 && output.existsSync() && output.lengthSync() > 0) {
      return outputPath;
    }
    if (output.existsSync()) {
      try {
        output.deleteSync();
      } catch (_) {}
    }
    ErrorLogService.instance.log(
      'extractAudioSegmentViaFfmpeg',
      code == null ? 'ffmpeg timed out' : 'ffmpeg exit $code',
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
