import 'dart:io';

import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/mining/immersion_mining_request.dart'
    show MiningClipFormat;
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/utils/misc/desktop_audio_clipper.dart'
    show buildFfmpegRemoteInputArgs;

/// One timeline for the selected picture and sentence sound, in the container /
/// codecs of [format] (see [MiningClipFormat]). A pre-trimmed
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
  int audioChannels = 2,
  int maxWidth = 960,
  int fps = 24,
  bool decodeFromStart = false,
  String? cropFilter,
  Map<String, String> headers = const <String, String>{},
  Map<String, String> audioHeaders = const <String, String>{},
  String? tlsPinSha256,
  String? audioTlsPinSha256,
  MiningClipFormat format = MiningClipFormat.mp4H264,
}) {
  final String soundPath = audioPath ?? videoPath;
  // FFmpeg normalizes a source's start time and seek for both streams. Keep
  // their remaining relative timestamps when they share that source timeline.
  final bool sharedTimeline =
      soundPath == videoPath && (audioStartMs ?? startMs) == startMs;
  final Map<String, String> soundHeaders = audioPath == null
      ? headers
      : audioHeaders;
  final String? soundPin = audioPath == null ? tlsPinSha256 : audioTlsPinSha256;
  // Only reuse an input when its timeline AND access credentials match.
  // This avoids a second demux/seek (and HTTP connection) for muxed sources.
  final bool sharedInput =
      sharedTimeline &&
      soundPin == tlsPinSha256 &&
      soundHeaders.length == headers.length &&
      headers.entries.every((entry) => soundHeaders[entry.key] == entry.value);
  final String pts = sharedTimeline ? 'PTS' : 'PTS-STARTPTS';
  final String duration = ((endMs - startMs) / 1000).toStringAsFixed(3);
  List<String> input(
    String path,
    int offset,
    Map<String, String> requestHeaders,
    String? pin,
  ) {
    return <String>[
      // BUG-2625：请求头交给 [buildFfmpegRemoteInputArgs] 统一下发，不在这里自己拼
      // 第二个 `-headers`。本地这份旧实现把 `User-Agent`/`Referer` 也塞进 `-headers`，
      // 而那个函数**无条件**输出一个 `-user_agent`，同名头出现两次时以哪个为准取决于
      // ffmpeg 的选项解析顺序——把三者收在一处后，调用方给的 UA/Referer 走各自的专用
      // 选项并明确覆盖默认值，其余头才进 `-headers`。
      ...buildFfmpegRemoteInputArgs(
        path,
        tlsPinSha256: pin,
        httpHeaders: requestHeaders,
      ),
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
    if (!sharedInput)
      ...input(soundPath, audioStartMs ?? startMs, soundHeaders, soundPin),
    '-map', '0:v:0',
    // Required audio map: missing/wrong tracks fail instead of silently making
    // another mute animation or exporting an unrelated default-language track.
    '-map', '${sharedInput ? 0 : 1}:a:$audioStreamIndex',
    '-vf',
    'setpts=$pts,'
        '${cropFilter == null || cropFilter.isEmpty ? "" : "$cropFilter,"}'
        'fps=$fps,'
        "scale=w='trunc(min($maxWidth,iw)/2)*2':h=-2,"
        'format=yuv420p',
    '-af', 'asetpts=$pts',
    ...synchronizedClipVideoArgs(format),
    ...synchronizedClipAudioArgs(format, audioChannels: audioChannels),
    '-sn', '-dn', '-map_metadata', '-1', '-map_chapters', '-1',
    // No `-shortest`: every input is already bounded by its own `-t`, and on
    // FFmpeg 6.0 (Android / iOS ffmpeg-kit) its sync queue swallows every frame of
    // a raw ADTS input — the trimmed sentence `.aac` — so the clip came out with a
    // declared but empty audio track, exit code 0 (#1951; fixed upstream in 6.1).
    '-t', duration,
    if (format == MiningClipFormat.mp4H264)
      ...buildClipFaststartArgs(outputPath),
    '-f', format.fileExtension, outputPath,
  ];
}

/// 各 [MiningClipFormat] 的编码器参数（视频 + 音频）。
///
/// - MP4：H.264 + AAC，改动前的唯一形态，逐字节不变。
/// - WebM：视频 VP9 / AV1 + 音频 Opus——Anki 桌面 Qt WebEngine 无 H.264/AAC 解码器，
///   卡片内 `<video>` 只能放这一族。
List<String> synchronizedClipCodecArgs(MiningClipFormat format) => <String>[
  ...synchronizedClipVideoArgs(format),
  ...synchronizedClipAudioArgs(format),
];

/// 各格式的视频编码参数。
///
/// VP9 用 `-deadline realtime -cpu-used 8 -row-mt 1`：制卡是用户在等的前台操作，速度
/// 优先。捆绑 ffmpeg-min 实测（1080p30 实拍源、3.6 秒窗 → 960 宽 24fps，含两路解码）：
///
/// | 参数 | 耗时 | 体积 |
/// |---|---|---|
/// | VP9 `good` / cpu-used 5（旧值） | 10.2–11.7 s | 1.14 MB |
/// | VP9 `realtime` / cpu-used 8 | 2.3–2.9 s | 1.44 MB |
/// | AV1 SVT preset 8 | 5.0–5.5 s | 0.88 MB |
/// | H.264 veryfast（MP4 档） | 2.7 s | 1.25 MB |
///
/// `good` 档慢 4 倍只省 20% 体积，不值得让用户多等 8 秒。`-b:v 0` 让 `-crf` 走恒定质量。
/// AV1 与动图 AVIF 同一个 SVT-AV1 编码器与 preset。
List<String> synchronizedClipVideoArgs(MiningClipFormat format) =>
    switch (format) {
      MiningClipFormat.mp4H264 => const <String>[
        '-c:v',
        'libx264',
        '-preset',
        'veryfast',
        '-crf',
        '23',
        '-pix_fmt',
        'yuv420p',
      ],
      MiningClipFormat.webmVp9 => const <String>[
        '-c:v',
        'libvpx-vp9',
        '-deadline',
        'realtime',
        '-cpu-used',
        '8',
        '-row-mt',
        '1',
        '-crf',
        '34',
        '-b:v',
        '0',
        '-pix_fmt',
        'yuv420p',
      ],
      MiningClipFormat.webmAv1 => const <String>[
        '-c:v',
        'libsvtav1',
        '-preset',
        '8',
        '-crf',
        '36',
        '-pix_fmt',
        'yuv420p',
      ],
    };

/// 各格式的音频编码参数：MP4 → AAC 128k，WebM → Opus 96k（WebM 只容纳 Opus/Vorbis）。
List<String> synchronizedClipAudioArgs(
  MiningClipFormat format, {
  int audioChannels = 2,
}) => format == MiningClipFormat.mp4H264
    ? <String>[
        '-c:a',
        'aac',
        '-b:a',
        '128k',
        '-ac',
        '$audioChannels',
        '-ar',
        '48000',
      ]
    : <String>[
        '-c:a',
        'libopus',
        '-b:a',
        '96k',
        '-ac',
        '$audioChannels',
        '-ar',
        '48000',
      ];

/// 一次带降级的片段导出结果：[result] 是首个成功（或全失败时首个失败）的那次尝试，
/// [format] 是那次尝试的格式——调用方拿它拼文件名、判渲染方式，不从扩展名反推（AV1 与
/// VP9 同为 `.webm`）。
typedef ClipFormatExport = ({
  VideoClipExportResult result,
  MiningClipFormat format,
});

/// ffmpeg 报「编不出这种格式」的日志特征（小写比对，覆盖 FFmpeg 6.0 / 7.x 两代措辞）：
/// 缺编码器（`Unknown encoder 'libvpx-vp9'`、`Encoder not found`、`Default encoder for
/// format webm (codec vp9) is probably disabled`、`Automatic encoder selection failed`）
/// 与缺 muxer（6.0 `... is not a suitable output format`、7.x `Requested output format
/// 'webm' is not known`）。
const List<String> _kClipFormatUnsupportedMarkers = <String>[
  'unknown encoder',
  'encoder not found',
  'is probably disabled',
  'automatic encoder selection failed',
  'not a suitable output format',
  'requested output format',
];

/// 一次片段导出失败是否**因格式而起**：本机 ffmpeg 缺该格式的编码器或 muxer。
///
/// 只有这类失败换下一个格式才有意义。远端输入超时 / 打不开、区间越界、磁盘写不进、
/// ffmpeg 本身不可用……与格式无关，换格式只会把同一个错误再撞一遍（远端输入还要
/// 再拉一次流、再等一次超时），并把真实原因埋在最后一次尝试的报错后面。
bool isClipFormatUnsupportedFailure(VideoClipExportResult result) {
  if (result.failure != VideoClipExportFailure.ffmpegFailed) return false;
  final String detail = (result.detail ?? '').toLowerCase();
  return _kClipFormatUnsupportedMarkers.any(detail.contains);
}

/// 按 [format] 的 [MiningClipFormat.encodeAttempts] 逐个尝试 [attempt]，每次尝试的产物
/// 落在各自的 `$outputStem-<wireName>.<扩展名>`（互不覆盖：上一次超时残留的文件不会让
/// 下一次撞上「输出已存在」而被跳过），返回首个成功的那次。捆绑 ffmpeg 缺 VP9/Opus/AV1
/// 编码器或 WebM muxer（旧二进制、用户自带精简 ffmpeg、iOS ffmpeg-kit 无 libvpx /
/// SVT-AV1）时降级到下一个格式，而不是让整张卡失败。
///
/// 只在 [isClipFormatUnsupportedFailure] 时降级；其余失败（远端超时、输入打不开等）
/// 立即返回，不再换格式重跑。全失败返回**首个**失败（最接近根因——后面的多是它的
/// 连锁反应）。
///
/// [onDegrade] 在一次非末位尝试因格式失败、即将换下一个格式时收到 `(失败格式, 结果)`，
/// 供调用方写诊断日志。
Future<ClipFormatExport> exportWithClipFormatFallback({
  required MiningClipFormat format,
  required String outputStem,
  required Future<VideoClipExportResult> Function(
    MiningClipFormat format,
    String outputPath,
  )
  attempt,
  void Function(MiningClipFormat format, VideoClipExportResult result)?
  onDegrade,
}) async {
  ClipFormatExport? firstFailure;
  final List<MiningClipFormat> attempts = format.encodeAttempts;
  for (final MiningClipFormat candidate in attempts) {
    final VideoClipExportResult result = await attempt(
      candidate,
      '$outputStem-${candidate.wireName}.${candidate.fileExtension}',
    );
    if (result.isSuccess) return (result: result, format: candidate);
    firstFailure ??= (result: result, format: candidate);
    if (!isClipFormatUnsupportedFailure(result)) break;
    if (candidate != attempts.last) onDegrade?.call(candidate, result);
  }
  return firstFailure!;
}

/// Uses the same injected desktop/mobile backend as video clip export; codecs
/// follow [format]. Failure is explicit: callers must not label a mute fallback as
/// synchronized. [outputPath] is a new file owned by this export.
Future<VideoClipExportResult> exportSynchronizedVideoClip({
  required String videoPath,
  required int startMs,
  required int endMs,
  required String outputPath,
  String? audioPath,
  int? audioStartMs,
  int audioStreamIndex = 0,
  int audioChannels = 2,
  int maxWidth = 960,
  int fps = 24,
  bool decodeFromStart = false,
  String? cropFilter,
  Map<String, String> headers = const <String, String>{},
  Map<String, String> audioHeaders = const <String, String>{},
  String? tlsPinSha256,
  String? audioTlsPinSha256,
  MiningClipFormat format = MiningClipFormat.mp4H264,
  FfmpegBackend? backend,
  Duration timeout = const Duration(minutes: 2),
}) async {
  if (startMs < 0 ||
      endMs <= startMs ||
      (audioStartMs ?? startMs) < 0 ||
      (decodeFromStart && (startMs != 0 || (audioStartMs ?? startMs) != 0)) ||
      audioStreamIndex < 0 ||
      audioChannels < 1 ||
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
            audioChannels: audioChannels,
            maxWidth: maxWidth,
            fps: fps,
            decodeFromStart: decodeFromStart,
            cropFilter: cropFilter,
            headers: headers,
            audioHeaders: audioHeaders,
            tlsPinSha256: tlsPinSha256,
            audioTlsPinSha256: audioTlsPinSha256,
            format: format,
          ),
          timeout,
        );
    if (!result.isSuccess) {
      _deletePartial(output);
      return VideoClipExportResult.failure(
        VideoClipExportFailure.ffmpegFailed,
        detail: result.failureSummary,
      );
    }
    final String? missing = _missingSynchronizedOutput(output, result.output);
    if (missing == null) return VideoClipExportResult.success(outputPath);
    _deletePartial(output);
    return VideoClipExportResult.failure(
      VideoClipExportFailure.outputMissing,
      detail: '$missing; ${result.failureSummary}',
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

/// 退出码 0 的这次导出还缺什么；什么都不缺返回 null。
///
/// #1951：只看「文件存在且非空」会放过一份声明了 Opus 音轨、却一个音频包都没有的
/// webm（容器头本身就有几十 KB）——卡片照常落地，用户拿到的是没声音的同步片段。
/// 两路都是必选映射（`-map 0:v:0` / `-map 1:a:N`），判据就是两路都真的写进了数据。
/// 证据取这次 ffmpeg 自己的收尾统计行，不另起探测进程：移动端 ffmpeg-kit 与桌面 CLI
/// 都会把它交回 [FfmpegRunResult.output]，也不依赖平台上有没有 ffprobe。
String? _missingSynchronizedOutput(File output, String log) {
  if (!output.existsSync() || output.lengthSync() == 0) {
    return 'output file is empty';
  }
  return missingMuxedVideoAndAudio(log);
}

/// 一次「画面 + 声音都必选」的 ffmpeg 合成，按它自己的收尾统计行判还缺哪一路；
/// 两路都写进了数据返回 null。统计行缺失也算缺——没有证据不当成功。
String? missingMuxedVideoAndAudio(String log) {
  final FfmpegMuxedBytes? muxed = parseFfmpegMuxedBytes(log);
  if (muxed == null) return 'ffmpeg final stats missing';
  if (muxed.videoKiB <= 0) return 'no video data muxed';
  if (muxed.audioKiB <= 0) return 'no audio data muxed';
  return null;
}

/// ffmpeg 收尾统计行里各类流写进输出的数据量（KiB，ffmpeg 自己四舍五入到整数）。
typedef FfmpegMuxedBytes = ({double videoKiB, double audioKiB});

/// 解析 ffmpeg 收尾统计行：6.x 印 `video:85kB audio:24kB subtitle:0kB …`，7.x 起单位
/// 改成 `KiB`。日志里可能有多个输出 / 多次运行，取最后一行。流信息行里的
/// `Audio: aac` 后面不跟数字，不会误命中。没有这行（被截断、日志级别压低）返回 null。
FfmpegMuxedBytes? parseFfmpegMuxedBytes(String log) {
  final RegExpMatch? match = RegExp(
    r'video:\s*(\d+(?:\.\d+)?)\s*(?:kB|KiB)\s+'
    r'audio:\s*(\d+(?:\.\d+)?)\s*(?:kB|KiB)',
  ).allMatches(log).lastOrNull;
  if (match == null) return null;
  return (
    videoKiB: double.parse(match.group(1)!),
    audioKiB: double.parse(match.group(2)!),
  );
}

void _deletePartial(File output) {
  try {
    if (output.existsSync()) output.deleteSync();
  } on FileSystemException {
    // Preserve the export failure when a partial file cannot be removed.
  }
}
