import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show buildFfmpegRemoteInputArgs;

/// One MP4 timeline for the selected picture and sentence sound. A pre-trimmed
/// sentence file must pass [audioStartMs] = 0; original audio defaults to [startMs].
/// Each stream is decoded at its own precise seek point, never keyframe-copied.
List<String> buildSynchronizedVideoClipArgs({
  required String videoPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  String? audioPath,
  int? audioStartMs,
  int audioStreamIndex = 0,
  int maxWidth = 960,
  int fps = 24,
  bool decodeFromStart = false,
  String? cropFilter,
  Map<String, String> headers = const <String, String>{},
  Map<String, String> audioHeaders = const <String, String>{},
  String? tlsPinSha256,
  String? audioTlsPinSha256,
}) {
  final String soundPath = audioPath ?? videoPath;
  // FFmpeg normalizes a source's start time and seek for both streams. Keep
  // their remaining relative timestamps when they share that source timeline.
  final bool sharedTimeline =
      soundPath == videoPath && (audioStartMs ?? startMs) == startMs;
  final String pts = sharedTimeline ? 'PTS' : 'PTS-STARTPTS';
  final String duration = ((endMs - startMs) / 1000).toStringAsFixed(3);
  List<String> input(
    String path,
    int offset,
    Map<String, String> requestHeaders,
    String? pin,
  ) {
    return <String>[
      ...buildFfmpegRemoteInputArgs(path, tlsPinSha256: pin),
      if (_isRemote(path) && requestHeaders.isNotEmpty) ...<String>[
        '-headers',
        requestHeaders.entries
            .map((MapEntry<String, String> e) => '${e.key}: ${e.value}\r\n')
            .join(),
      ],
      if (!(decodeFromStart && offset == 0)) ...<String>[
        '-ss',
        (offset / 1000).toStringAsFixed(3),
      ],
      '-t',
      duration,
      '-i',
      path,
    ];
  }

  return <String>[
    '-hide_banner', '-y',
    ...input(videoPath, startMs, headers, tlsPinSha256),
    ...input(
      soundPath,
      audioStartMs ?? startMs,
      audioPath == null ? headers : audioHeaders,
      audioPath == null ? tlsPinSha256 : audioTlsPinSha256,
    ),
    '-map', '0:v:0',
    // Required audio map: missing/wrong tracks fail instead of silently making
    // another mute animation or exporting an unrelated default-language track.
    '-map', '1:a:$audioStreamIndex',
    '-vf',
    'setpts=$pts,'
        '${cropFilter == null || cropFilter.isEmpty ? "" : "$cropFilter,"}'
        "scale=w='trunc(min($maxWidth,iw)/2)*2':h=-2,"
        'fps=$fps,format=yuv420p',
    '-af', 'asetpts=$pts',
    '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23',
    '-pix_fmt', 'yuv420p',
    '-c:a', 'aac', '-b:a', '128k', '-ac', '2', '-ar', '48000',
    '-sn', '-dn', '-map_metadata', '-1',
    '-t', duration, '-shortest',
    ...buildClipFaststartArgs(outputPath),
    '-f', 'mp4', outputPath,
  ];
}

/// Uses the same injected desktop/mobile backend and H.264 encoder as video
/// clip export. Failure is explicit: callers must not label a mute fallback as
/// synchronized. [outputPath] is a new file owned by this export.
Future<VideoClipExportResult> exportSynchronizedVideoClip({
  required String videoPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  String? audioPath,
  int? audioStartMs,
  int audioStreamIndex = 0,
  int maxWidth = 960,
  int fps = 24,
  bool decodeFromStart = false,
  String? cropFilter,
  Map<String, String> headers = const <String, String>{},
  Map<String, String> audioHeaders = const <String, String>{},
  String? tlsPinSha256,
  String? audioTlsPinSha256,
  FfmpegBackend? backend,
  Duration timeout = const Duration(minutes: 2),
}) async {
  if (startMs < 0 ||
      endMs <= startMs ||
      (audioStartMs ?? startMs) < 0 ||
      (decodeFromStart && (startMs != 0 || (audioStartMs ?? startMs) != 0)) ||
      audioStreamIndex < 0 ||
      maxWidth < 2 ||
      fps < 1 ||
      fps > 60) {
    return const VideoClipExportResult.failure(
      VideoClipExportFailure.invalidRange,
    );
  }
  for (final String path in <String>[videoPath, audioPath ?? videoPath]) {
    if (path.isEmpty || (!_isRemote(path) && !File(path).existsSync())) {
      return const VideoClipExportResult.failure(
        VideoClipExportFailure.inputMissing,
      );
    }
  }
  final File output = File(outputPath);
  if (output.existsSync()) {
    return const VideoClipExportResult.failure(
      VideoClipExportFailure.ffmpegFailed,
      detail: 'Output already exists',
    );
  }
  try {
    await output.parent.create(recursive: true);
    final FfmpegRunResult result = await (backend ?? resolveFfmpegBackend())
        .run(
          buildSynchronizedVideoClipArgs(
            videoPath: videoPath,
            startMs: startMs,
            endMs: endMs,
            outputPath: outputPath,
            audioPath: audioPath,
            audioStartMs: audioStartMs,
            audioStreamIndex: audioStreamIndex,
            maxWidth: maxWidth,
            fps: fps,
            decodeFromStart: decodeFromStart,
            cropFilter: cropFilter,
            headers: headers,
            audioHeaders: audioHeaders,
            tlsPinSha256: tlsPinSha256,
            audioTlsPinSha256: audioTlsPinSha256,
          ),
          timeout,
        );
    if (result.isSuccess && output.existsSync() && output.lengthSync() > 0) {
      return VideoClipExportResult.success(outputPath);
    }
    _deletePartial(output);
    return VideoClipExportResult.failure(
      result.isSuccess
          ? VideoClipExportFailure.outputMissing
          : VideoClipExportFailure.ffmpegFailed,
      detail: result.failureSummary,
    );
  } on ProcessException catch (error) {
    _deletePartial(output);
    return VideoClipExportResult.failure(
      VideoClipExportFailure.ffmpegUnavailable,
      detail: error.message,
    );
  } catch (error) {
    _deletePartial(output);
    return VideoClipExportResult.failure(
      VideoClipExportFailure.ffmpegFailed,
      detail: error.toString(),
    );
  }
}

bool _isRemote(String path) =>
    path.startsWith('https://') || path.startsWith('http://');

void _deletePartial(File output) {
  try {
    if (output.existsSync()) output.deleteSync();
  } on FileSystemException {
    // Preserve the export failure when a partial file cannot be removed.
  }
}
