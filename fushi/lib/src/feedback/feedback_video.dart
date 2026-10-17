// 反馈视频附件的本机准备：上传前转码成 720p（默认）或 1080p 的 H.264 + AAC mp4。
//
// 服务端（services/leaderboard 的 v0 槽位）只收 ≤ 50 MB 的 mp4 / webm / mov，每条反馈一个。
// 转码走项目现成的 ffmpeg 后端（resolveFfmpegBackend：桌面捆绑的 ffmpeg-min、移动端自编
// ffmpeg-kit，两边都编入了 libx264 + aac + mp4 muxer）；后端起不来 / 转码失败时**原样上传**，
// 但原件同样要过格式与 50 MB 上限，过不了就明说「太大 / 不是视频」，不偷偷截断。
//
// 码率按时长自适应：720p 的 2 Mbps 下 50 MB 只装得下约 3 分钟，更长的录屏把视频码率压低到
// 刚好装进上限（下限 250 kbps，再低也装不下就报太大），而不是转完才发现超了。1080p 只在
// 码率还够 1080p 用时才转（见 [FeedbackVideoQuality.p1080]），否则自动退回 720p 并告诉调用方。
//
// 速度：统一 FFmpeg 的硬件加速只用于解码（MediaCodec / VideoToolbox 给播放器），编码一律
// 软编（画质与跨设备一致性，见 docs/specs/2026-10-17-unified-ffmpeg.md），只能在 libx264
// 软编上省——见 [buildFeedbackVideoTranscodeArgs]。
//
// 取消：[prepareFeedbackVideo] 的 `cancel` 完成即强杀 ffmpeg 会话、删掉半成品，抛
// [FeedbackVideoCancelledException]（不会退回「原样上传」）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_engine/feedback/feedback_models.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/ffmpeg_watched_run.dart';
import 'package:path/path.dart' as p;

/// 压缩目标分辨率（短边）。720p 是默认；1080p 是用户显式选的高清档。
enum FeedbackVideoQuality {
  /// 720p：录屏 / 实拍在 2 Mbps 下文字仍清楚；码率下限 250 kbps（再低装不下就报太大）。
  p720(shortSide: 720, maxKbps: 2000, minKbps: 250, label: '720p'),

  /// 1080p：封顶 4 Mbps（50 MB 约装 1 分半）；码率掉到 2 Mbps（720p 的满码率）以下时
  /// 1080p 已不比 720p 清楚，此时退回 720p（约 3 分钟以上的视频）。
  p1080(shortSide: 1080, maxKbps: 4000, minKbps: 2000, label: '1080p');

  const FeedbackVideoQuality({
    required this.shortSide,
    required this.maxKbps,
    required this.minKbps,
    required this.label,
  });

  /// 视频短边上限（只缩不放）。
  final int shortSide;

  /// 视频码率上限（kbps）。
  final int maxKbps;

  /// 这一档能接受的最低视频码率（kbps）；按时长算出来更低就装不下这一档。
  final int minKbps;

  /// 界面上显示的名字（「720p」/「1080p」，不翻译）。
  final String label;
}

/// 目标视频码率上限（kbps）：720p 录屏 / 实拍在这个码率下文字仍清楚。
const int kFeedbackVideoMaxKbps = 2000;

/// 目标视频码率下限（kbps）：再低画面糊到看不出问题，不如直接告诉用户太长。
const int kFeedbackVideoMinKbps = 250;

/// 音频码率（kbps，AAC 双声道）。
const int kFeedbackVideoAudioKbps = 96;

/// 视频的短边上限（720p，默认档）。
const int kFeedbackVideoShortSide = 720;

/// 输出帧率上限：手机录屏常是 60 / 90 / 120 fps，反馈视频看清操作 30 fps 足够。
/// 源帧率高于它时在滤镜链**最前面**降帧（`fps=30`，先丢帧再缩放，缩放量随之减半；
/// `-fpsmax` 是输出端丢帧，缩放仍按原帧率做满，实测省不到一半）。不高于它 / 探不到帧率
/// 时不加滤镜（`fps` 滤镜会把低帧率素材补帧升上去）。
const int kFeedbackVideoMaxFps = 30;

/// x264 预设：移动端只有软编（见文件头），旧的 `veryfast` + 全帧率 + 双三次缩放在手机上
/// 压一段几分钟的 60 fps 录屏要好几分钟（反馈 B5mf2su2Cm「压缩巨慢」）。码率是 ABR 定死的，
/// 预设只换「同码率下的画质」而不影响大小上限。
const String kFeedbackVideoPreset = 'ultrafast';

/// 选的视频不是服务端收的格式（mp4 / webm / mov），而且转码也没成功。
class FeedbackVideoUnsupportedException implements Exception {
  const FeedbackVideoUnsupportedException();

  @override
  String toString() => 'FeedbackVideoUnsupportedException';
}

/// 视频超过 [FeedbackLimits.videoMaxBytes]（转码后仍然超，或转码不可用时原件超）。
class FeedbackVideoTooLargeException implements Exception {
  const FeedbackVideoTooLargeException(this.bytes);

  final int bytes;

  @override
  String toString() => 'FeedbackVideoTooLargeException($bytes)';
}

/// 用户取消了压缩（点了附件的 ×）。不是错误，不进错误日志。
class FeedbackVideoCancelledException implements Exception {
  const FeedbackVideoCancelledException();

  @override
  String toString() => 'FeedbackVideoCancelledException';
}

/// 准备好、可以上传的视频：[file] 在调用方给的工作目录里（调用方负责挪走 / 删除）。
class PreparedFeedbackVideo {
  const PreparedFeedbackVideo({
    required this.file,
    required this.contentType,
    required this.bytes,
    required this.transcoded,
    this.quality,
  });

  final File file;
  final String contentType;
  final int bytes;

  /// 是转码产物（false = 转码不可用 / 失败，原样上传）。
  final bool transcoded;

  /// 实际转成的档位（原样上传时为 null）。选 1080p 但退回 720p 时是 [FeedbackVideoQuality.p720]。
  final FeedbackVideoQuality? quality;
}

/// 让用户选一个视频（提交页「添加视频」与详情页「追加视频」共用）。`FileType.video`
/// 不按扩展名过滤；选中的文件当场转码 / 复制进 app 的待传区，原路径不长期引用（安卓上
/// file_picker 给的是缓存副本，用完即可丢）。取消返回 null。
Future<File?> pickFeedbackVideoFile() async {
  final FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.video,
  );
  final String? path = result?.files.firstOrNull?.path;
  return path == null ? null : File(path);
}

/// 按文件头判断视频容器，返回服务端认的 MIME；不认识返回 null。与服务端嗅探同一口径：
/// ISO BMFF（offset 4 是 `ftyp`，major brand `qt  ` 为 QuickTime）/ EBML（WebM）。
String? sniffFeedbackVideoType(List<int> head) {
  if (head.length >= 12 &&
      head[4] == 0x66 && // f
      head[5] == 0x74 && // t
      head[6] == 0x79 && // y
      head[7] == 0x70) {
    final bool quickTime =
        head[8] == 0x71 &&
        head[9] == 0x74 &&
        head[10] == 0x20 &&
        head[11] == 0x20;
    return quickTime ? 'video/quicktime' : 'video/mp4';
  }
  if (head.length >= 4 &&
      head[0] == 0x1a &&
      head[1] == 0x45 &&
      head[2] == 0xdf &&
      head[3] == 0xa3) {
    return 'video/webm';
  }
  return null;
}

/// 纯函数：按时长选视频码率（kbps），让「视频 + 音频」装进上限的 92%（留容器开销余量）。
/// 时长未知按 [quality] 的上限码率转；算出来低于 [FeedbackVideoQuality.minKbps] 时返回
/// null（这一档装不下）。
int? feedbackVideoBitrateKbps(
  int? durationMs, {
  int maxBytes = FeedbackLimits.videoMaxBytes,
  FeedbackVideoQuality quality = FeedbackVideoQuality.p720,
}) {
  if (durationMs == null || durationMs <= 0) return quality.maxKbps;
  final double seconds = durationMs / 1000;
  final double totalKbps = maxBytes * 8 * 0.92 / seconds / 1000;
  final int video = (totalKbps - kFeedbackVideoAudioKbps).floor();
  if (video < quality.minKbps) return null;
  return math.min(video, quality.maxKbps);
}

/// 纯函数：这段视频实际按哪一档转、视频码率多少。选 1080p 但码率不够 1080p 时退回 720p；
/// 720p 也装不下返回 null。
({FeedbackVideoQuality quality, int kbps})? planFeedbackVideoTranscode(
  int? durationMs,
  FeedbackVideoQuality requested, {
  int maxBytes = FeedbackLimits.videoMaxBytes,
}) {
  for (final FeedbackVideoQuality q in <FeedbackVideoQuality>[
    requested,
    if (requested != FeedbackVideoQuality.p720) FeedbackVideoQuality.p720,
  ]) {
    final int? kbps = feedbackVideoBitrateKbps(
      durationMs,
      maxBytes: maxBytes,
      quality: q,
    );
    if (kbps != null) return (quality: q, kbps: kbps);
  }
  return null;
}

/// 纯函数：转码参数表。源帧率 [sourceFps] 高于 [kFeedbackVideoMaxFps] 时先降帧，短边缩到
/// ≤ [quality] 的短边（只缩不放、保持比例、偶数维度、双线性——录屏缩小时与双三次肉眼无差、
/// 快得多），H.264 yuv420p 平均码率 [videoKbps]（maxrate 1.5 倍防尖峰，预设
/// [kFeedbackVideoPreset]），AAC 双声道；没有音轨的视频照样能转（`0:a:0?` 可选映射）；
/// `+faststart` 让开发者端边下边播。
List<String> buildFeedbackVideoTranscodeArgs({
  required String input,
  required String output,
  required int videoKbps,
  FeedbackVideoQuality quality = FeedbackVideoQuality.p720,
  double? sourceFps,
}) {
  final int s = quality.shortSide;
  final bool capFps =
      sourceFps != null && sourceFps > kFeedbackVideoMaxFps + 0.5;
  return <String>[
    '-y',
    '-hide_banner',
    '-i',
    input,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    '-vf',
    "${capFps ? 'fps=$kFeedbackVideoMaxFps,' : ''}"
        "scale=w='if(gte(iw,ih),-2,trunc(min($s,iw)/2)*2)'"
        ":h='if(gte(iw,ih),trunc(min($s,ih)/2)*2,-2)':flags=bilinear",
    '-c:v',
    'libx264',
    '-preset',
    kFeedbackVideoPreset,
    '-b:v',
    '${videoKbps}k',
    '-maxrate',
    '${videoKbps * 3 ~/ 2}k',
    '-bufsize',
    '${videoKbps * 2}k',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    '-b:a',
    '${kFeedbackVideoAudioKbps}k',
    '-ac',
    '2',
    '-movflags',
    '+faststart',
    '-f',
    'mp4',
    output,
  ];
}

/// 纯函数：从 ffmpeg 的输入信息里取时长（`Duration: HH:MM:SS.xx`），没有 / `N/A` 返回 null。
int? parseFeedbackVideoDurationMs(String log) {
  final RegExpMatch? m = RegExp(
    r'Duration:\s*(\d+):(\d{2}):(\d{2})\.(\d+)',
  ).firstMatch(log);
  if (m == null) return null;
  final int h = int.parse(m.group(1)!);
  final int min = int.parse(m.group(2)!);
  final int sec = int.parse(m.group(3)!);
  final String frac = m.group(4)!;
  final int ms = int.parse(frac) * 1000 ~/ math.pow(10, frac.length).toInt();
  return ((h * 60 + min) * 60 + sec) * 1000 + ms;
}

/// 纯函数：从 ffmpeg 的输入信息里取第一条视频流的帧率（`, 60 fps,` / `29.97 fps`），
/// 没有返回 null。
double? parseFeedbackVideoFps(String log) {
  for (final String line in const LineSplitter().convert(log)) {
    if (!line.contains('Video:')) continue;
    final RegExpMatch? m = RegExp(r'([\d.]+)\s*fps\b').firstMatch(line);
    return m == null ? null : double.tryParse(m.group(1)!);
  }
  return null;
}

Future<List<int>> _head(File f) async {
  final RandomAccessFile raf = await f.open();
  try {
    return await raf.read(16);
  } finally {
    await raf.close();
  }
}

/// 一次准备的取消状态：[cancel] 完成后 [cancelled] 置位（转码由 [FfmpegWatch.cancel]
/// 同一个 future 强杀）。
class _CancelFlag {
  _CancelFlag(Future<void>? cancel) {
    unawaited(cancel?.then((_) => cancelled = true));
  }

  bool cancelled = false;

  void check() {
    if (cancelled) throw const FeedbackVideoCancelledException();
  }
}

/// 准备上传：先按 [quality] 转码（[onProgress] 回报 0..1，时长未知时不回报），转不了就原样
/// 用原件（复制进 [workDir]，原件不动）。结果仍超 [FeedbackLimits.videoMaxBytes] 抛
/// [FeedbackVideoTooLargeException]；既不是视频、又转不了抛 [FeedbackVideoUnsupportedException]。
///
/// 选 1080p 而 1080p 装不进上限（太长，或转完仍超）时自动改转 720p，并调 [onDowngraded]。
/// [cancel] 完成即中止（强杀 ffmpeg、删掉半成品），抛 [FeedbackVideoCancelledException]。
Future<PreparedFeedbackVideo> prepareFeedbackVideo(
  File source, {
  required Directory workDir,
  FfmpegBackend? backend,
  void Function(double fraction)? onProgress,
  FeedbackVideoQuality quality = FeedbackVideoQuality.p720,
  void Function()? onDowngraded,
  Future<void>? cancel,
}) async {
  final _CancelFlag flag = _CancelFlag(cancel);
  await workDir.create(recursive: true);
  final String? sourceType = sniffFeedbackVideoType(await _head(source));
  final int sourceBytes = await source.length();
  final File out = File(p.join(workDir.path, 'feedback-video.mp4'));
  PreparedFeedbackVideo? transcoded;
  // 太长、最低码率也装不下：原件本身若已是 ≤ 上限的视频（低码率长录屏）照样能传。
  FeedbackVideoTooLargeException? tooLong;
  try {
    transcoded = await _transcode(
      source,
      out,
      backend ?? resolveFfmpegBackend(),
      onProgress,
      quality: quality,
      onDowngraded: onDowngraded,
      cancel: cancel,
      flag: flag,
    );
  } on FeedbackVideoCancelledException {
    await _deleteIfExists(out);
    rethrow;
  } on FeedbackVideoTooLargeException catch (e) {
    tooLong = e;
  } on Object catch (e, st) {
    // 后端起不来（Linux 没装 ffmpeg 等）/ 进程异常：退回原件。
    ErrorLogService.instance.log('feedback.video_transcode', e, st);
  }
  if (flag.cancelled) {
    await _deleteIfExists(out);
    flag.check();
  }
  if (transcoded != null &&
      transcoded.bytes > 0 &&
      transcoded.bytes <= FeedbackLimits.videoMaxBytes &&
      (sourceType == null || transcoded.bytes <= sourceBytes)) {
    return transcoded;
  }
  // 转码产物比原件还大（原件本来就是低码率 mp4）也用原件。
  if (sourceType == null) {
    if (transcoded != null &&
        transcoded.bytes <= FeedbackLimits.videoMaxBytes) {
      return transcoded;
    }
    throw tooLong ?? const FeedbackVideoUnsupportedException();
  }
  if (sourceBytes > FeedbackLimits.videoMaxBytes) {
    throw tooLong ?? FeedbackVideoTooLargeException(sourceBytes);
  }
  await _deleteIfExists(out);
  final String ext = switch (sourceType) {
    'video/webm' => 'webm',
    'video/quicktime' => 'mov',
    _ => 'mp4',
  };
  final File copy = await source.copy(
    p.join(workDir.path, 'feedback-video-original.$ext'),
  );
  if (flag.cancelled) {
    await _deleteIfExists(copy);
    flag.check();
  }
  return PreparedFeedbackVideo(
    file: copy,
    contentType: sourceType,
    bytes: sourceBytes,
    transcoded: false,
  );
}

Future<void> _deleteIfExists(File f) async {
  if (f.existsSync()) await f.delete();
}

/// 跑转码；失败返回 null（原因进错误日志），时长太长连最低码率都装不下抛
/// [FeedbackVideoTooLargeException]，被取消抛 [FeedbackVideoCancelledException]。
Future<PreparedFeedbackVideo?> _transcode(
  File source,
  File out,
  FfmpegBackend ffmpeg,
  void Function(double fraction)? onProgress, {
  required FeedbackVideoQuality quality,
  required void Function()? onDowngraded,
  required Future<void>? cancel,
  required _CancelFlag flag,
}) async {
  // 先取时长：定码率、算进度。`-i` 不给输出时 ffmpeg 以非零退出，但输入信息照样打印。
  final FfmpegRunResult info = await ffmpeg.run(<String>[
    '-hide_banner',
    '-i',
    source.path,
  ], const Duration(seconds: 30));
  flag.check();
  final int? durationMs = parseFeedbackVideoDurationMs(info.output);
  final double? sourceFps = parseFeedbackVideoFps(info.output);
  final ({FeedbackVideoQuality quality, int kbps})? plan =
      planFeedbackVideoTranscode(durationMs, quality);
  if (plan == null) {
    // 按最低码率也超：估算大小报给用户（服务端上限是硬的）。
    throw FeedbackVideoTooLargeException(
      ((kFeedbackVideoMinKbps + kFeedbackVideoAudioKbps) *
              1000 /
              8 *
              (durationMs! / 1000))
          .round(),
    );
  }
  if (plan.quality != quality) onDowngraded?.call();
  final PreparedFeedbackVideo? first = await _transcodeOnce(
    source,
    out,
    ffmpeg,
    onProgress,
    durationMs: durationMs,
    sourceFps: sourceFps,
    quality: plan.quality,
    kbps: plan.kbps,
    cancel: cancel,
    flag: flag,
  );
  if (first == null ||
      first.bytes <= FeedbackLimits.videoMaxBytes ||
      plan.quality == FeedbackVideoQuality.p720) {
    return first;
  }
  // 1080p 转完仍超（码率尖峰 / 容器开销超出预留）：改转 720p 再来一次。
  final ({FeedbackVideoQuality quality, int kbps})? fallback =
      planFeedbackVideoTranscode(durationMs, FeedbackVideoQuality.p720);
  if (fallback == null) return first;
  onDowngraded?.call();
  onProgress?.call(0);
  return _transcodeOnce(
    source,
    out,
    ffmpeg,
    onProgress,
    durationMs: durationMs,
    sourceFps: sourceFps,
    quality: fallback.quality,
    kbps: fallback.kbps,
    cancel: cancel,
    flag: flag,
  );
}

Future<PreparedFeedbackVideo?> _transcodeOnce(
  File source,
  File out,
  FfmpegBackend ffmpeg,
  void Function(double fraction)? onProgress, {
  required int? durationMs,
  required double? sourceFps,
  required FeedbackVideoQuality quality,
  required int kbps,
  required Future<void>? cancel,
  required _CancelFlag flag,
}) async {
  final List<String> args = buildFeedbackVideoTranscodeArgs(
    input: source.path,
    output: out.path,
    videoKbps: kbps,
    quality: quality,
    sourceFps: sourceFps,
  );
  final FfmpegRunResult result = switch (ffmpeg) {
    final FfmpegWatchedRunner watched => await watched.runWatched(
      args,
      FfmpegWatch(
        stallTimeout: const Duration(seconds: 60),
        onProgress: durationMs == null
            ? null
            : (Duration processed) => onProgress?.call(
                (processed.inMilliseconds / durationMs).clamp(0.0, 1.0),
              ),
        cancel: cancel,
      ),
    ),
    _ => await ffmpeg.run(args, const Duration(minutes: 30)),
  };
  flag.check();
  if (!result.isSuccess || !out.existsSync()) {
    ErrorLogService.instance.logDiagnostic(
      'feedback.video_transcode',
      result.failureSummary,
    );
    return null;
  }
  return PreparedFeedbackVideo(
    file: out,
    contentType: 'video/mp4',
    bytes: await out.length(),
    transcoded: true,
    quality: quality,
  );
}
