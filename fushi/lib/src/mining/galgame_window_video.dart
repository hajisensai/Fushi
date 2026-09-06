import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/media/video/ffmpeg_backend.dart'
    show FfmpegBackend, FfmpegRunResult, resolveFfmpegBackend;
import 'package:fushi/src/mining/window_capture_channel.dart'
    show WindowRecordingExport, WindowRecordingFrame;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// galgame 场景卡「视频片段」产物：mp4 字节 + 扩展名（恒 `mp4`，带出来是让调用方
/// 与动图 / 静图那两条链同一手法拼文件名——**扩展名跟随实际产物**，不由调用方猜）。
typedef GalWindowVideoClip = ({Uint8List bytes, String extension});

/// 视频起点相对台词到达时刻的提前量：台词文本 hook 到达与画面切换之间有渲染延迟，
/// 提前 300ms 把「上一句结束 → 这句出现」的切换也收进片段。
const int kGalWindowVideoLeadMs = 300;

/// 无 hook 时间戳（纯 loopback 会话 / 历史行时间戳已淘汰）时的回退窗口：从「现在」
/// 往回取「句子音频时长 + 1 秒」；连音频都没有时取 6 秒。
const int kGalWindowVideoFallbackTailMs = 1000;
const int kGalWindowVideoFallbackWindowMs = 6000;

/// 最后一帧至少停留多久：录制帧的最后一帧没有「下一帧」给它定时长，取 200ms 保底。
const int kGalWindowVideoMinLastFrameMs = 200;

/// ffmpeg 编码超时。片段通常几秒、几十帧，veryfast 档 1080p 也只需数秒；给 2 分钟
/// 是留给低配机 / 长句（10 秒以上台词 + 高帧率录制）。
const Duration kGalWindowVideoEncodeTimeout = Duration(minutes: 2);

/// 音频时长探测超时（解码几秒 AAC 只要几十毫秒，30 秒是给磁盘冷启动留的）。
const Duration kGalWindowVideoProbeTimeout = Duration(seconds: 30);

/// 计划中的一条 concat 条目：帧文件 + 它在片段里停留的毫秒数。
typedef GalWindowVideoFrameEntry = ({String path, int durationMs});

/// 纯函数：录制帧列表 → concat 条目（每帧时长 = 与下一帧的 tick 差；最后一帧时长 =
/// `max(200ms, 音频总时长 - 视频已覆盖时长)`，保证视频长度 ≥ 音频长度，混流后不会
/// 出现「画面停了声音还在」被播放器截断的情况）。
///
/// 取帧规则：
/// - 只取 `tick ∈ [fromTickMs, toTickMs]` 的帧；
/// - 若 [fromTickMs] 之前还有帧，把**最后那一帧**也收进来并把它的 tick 钉到
///   [fromTickMs]——它就是 `fromTickMs` 那一刻屏幕上正显示的画面（录制是按固定间隔
///   采样的，区间起点几乎不会正好落在某一帧上）；
/// - tick 相同（或乱序）的帧只留第一张：concat demuxer 不接受 0 时长条目。
///
/// 不足 2 帧返回空列表（单帧不成片段，调用方降级动图 / 静图）。
List<GalWindowVideoFrameEntry> planGalWindowVideoFrames({
  required List<WindowRecordingFrame> frames,
  required int fromTickMs,
  required int toTickMs,
  required int? audioDurationMs,
  int minLastFrameMs = kGalWindowVideoMinLastFrameMs,
}) {
  if (toTickMs < fromTickMs) return const <GalWindowVideoFrameEntry>[];
  final List<WindowRecordingFrame> sorted =
      List<WindowRecordingFrame>.of(frames)
        ..sort(
          (WindowRecordingFrame a, WindowRecordingFrame b) =>
              a.tickMs.compareTo(b.tickMs),
        );

  final List<({String path, int tickMs})> picked =
      <({String path, int tickMs})>[];
  WindowRecordingFrame? leading;
  for (final WindowRecordingFrame frame in sorted) {
    if (frame.tickMs < fromTickMs) {
      leading = frame;
      continue;
    }
    if (frame.tickMs > toTickMs) break;
    picked.add((path: frame.path, tickMs: frame.tickMs));
  }
  if (leading != null && (picked.isEmpty || picked.first.tickMs > fromTickMs)) {
    picked.insert(0, (path: leading.path, tickMs: fromTickMs));
  }

  // 去掉 tick 不递增的帧（0 时长条目 concat demuxer 不吃）。
  final List<({String path, int tickMs})> monotonic =
      <({String path, int tickMs})>[];
  for (final ({String path, int tickMs}) frame in picked) {
    if (monotonic.isNotEmpty && frame.tickMs <= monotonic.last.tickMs) continue;
    monotonic.add(frame);
  }
  if (monotonic.length < 2) return const <GalWindowVideoFrameEntry>[];

  final List<GalWindowVideoFrameEntry> entries = <GalWindowVideoFrameEntry>[];
  for (int i = 0; i < monotonic.length - 1; i++) {
    entries.add((
      path: monotonic[i].path,
      durationMs: monotonic[i + 1].tickMs - monotonic[i].tickMs,
    ));
  }
  final int coveredMs = monotonic.last.tickMs - monotonic.first.tickMs;
  final int lastMs = math.max(
    minLastFrameMs,
    (audioDurationMs ?? 0) - coveredMs,
  );
  entries.add((path: monotonic.last.path, durationMs: lastMs));
  return List<GalWindowVideoFrameEntry>.unmodifiable(entries);
}

/// 纯函数：concat demuxer 列表文本（`ffconcat version 1.0` 头 + `file`/`duration`
/// 对）。最后一帧的 `duration` 只有在其后再跟一条 `file` 时才被 demuxer 采纳，故末尾
/// 重复最后一帧的 `file` 行（ffmpeg 官方 wiki 的同款写法）。
///
/// 路径统一转正斜杠并按 concat 的单引号转义规则处理（`'` → `'\''`），Windows 绝对路径
/// 配 `-safe 0` 使用。
String buildGalWindowConcatList(List<GalWindowVideoFrameEntry> entries) {
  String quote(String path) {
    final String normalized = path.replaceAll('\\', '/');
    return "'${normalized.replaceAll("'", r"'\''")}'";
  }

  final StringBuffer buffer = StringBuffer('ffconcat version 1.0\n');
  for (final GalWindowVideoFrameEntry entry in entries) {
    buffer
      ..writeln('file ${quote(entry.path)}')
      ..writeln('duration ${(entry.durationMs / 1000).toStringAsFixed(3)}');
  }
  if (entries.isNotEmpty) {
    buffer.writeln('file ${quote(entries.last.path)}');
  }
  return buffer.toString();
}

/// 纯函数：「concat 帧列表（+ 句子音频）→ H.264/AAC mp4」的 ffmpeg 参数表（可单测）。
///
/// - `libx264 veryfast crf 26 yuv420p`：Anki 桌面（mpv）与 AnkiDroid（VideoView →
///   MediaCodec）都只保证 H.264 + yuv420p 可播；
/// - `scale=trunc(iw/2)*2:trunc(ih/2)*2`：libx264 yuv420p 要求偶数维度，窗口尺寸任意；
/// - `aac 128k`：句子音频（ADTS `.aac` / `.m4a`）重封装进 mp4；
/// - `+faststart`：moov 前置，播放器不必读完整个文件才能起播。
List<String> buildGalWindowVideoArgs({
  required String listPath,
  required String outputPath,
  String? audioPath,
}) {
  return <String>[
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    listPath,
    if (audioPath != null) ...<String>['-i', audioPath],
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '26',
    '-pix_fmt',
    'yuv420p',
    '-vf',
    'scale=trunc(iw/2)*2:trunc(ih/2)*2',
    if (audioPath != null) ...<String>['-c:a', 'aac', '-b:a', '128k'],
    '-movflags',
    '+faststart',
    outputPath,
  ];
}

/// 纯函数：从 ffmpeg 日志解析媒体时长（毫秒）。
///
/// 优先取**最后一条**进度行的 `time=HH:MM:SS.xx`——它来自 `-f null -` 全量解码，对 ADTS
/// 裸流（容器里没有时长字段，`Duration:` 只是按码率估的）是唯一准的来源；没有进度行
/// 时退回 `Duration: HH:MM:SS.xx`。两者都没有（`N/A` / 解析失败）返回 null。
int? parseFfmpegDurationMs(String log) {
  final RegExp clock = RegExp(r'(\d+):(\d{2}):(\d{2})\.(\d+)');
  int? toMs(RegExpMatch m) {
    final int? h = int.tryParse(m.group(1)!);
    final int? min = int.tryParse(m.group(2)!);
    final int? s = int.tryParse(m.group(3)!);
    final String fraction = m.group(4)!;
    if (h == null || min == null || s == null) return null;
    final int frac =
        (int.parse(fraction) * 1000 ~/ math.pow(10, fraction.length).toInt());
    return ((h * 60 + min) * 60 + s) * 1000 + frac;
  }

  final Iterable<RegExpMatch> progress = RegExp(
    r'time=\s*(\d+:\d{2}:\d{2}\.\d+)',
  ).allMatches(log);
  if (progress.isNotEmpty) {
    final RegExpMatch? m = clock.firstMatch(progress.last.group(1)!);
    if (m != null) return toMs(m);
  }
  final RegExpMatch? duration = RegExp(
    r'Duration:\s*(\d+:\d{2}:\d{2}\.\d+)',
  ).firstMatch(log);
  if (duration != null) {
    final RegExpMatch? m = clock.firstMatch(duration.group(1)!);
    if (m != null) return toMs(m);
  }
  return null;
}

/// 探测 [audioPath] 的时长（毫秒）：`ffmpeg -i audio -f null -` 全量解码后读最后一条
/// 进度行（理由见 [parseFfmpegDurationMs]）。探不出 / 异常返回 null——时长只用来把
/// 最后一帧拉长到覆盖音频，探不到就退回 200ms 保底，不让片段跟着失败。
Future<int?> probeGalWindowAudioDurationMs(
  FfmpegBackend backend,
  String audioPath, {
  Duration timeout = kGalWindowVideoProbeTimeout,
}) async {
  try {
    final FfmpegRunResult result = await backend.run(<String>[
      '-hide_banner',
      '-i',
      audioPath,
      '-f',
      'null',
      '-',
    ], timeout);
    return parseFfmpegDurationMs(result.output);
  } catch (e, stack) {
    ErrorLogService.instance.logDiagnostic(
      'probeGalWindowAudioDurationMs',
      'audio duration probe failed: $e\n$stack',
    );
    return null;
  }
}

/// 纯函数：无 hook 台词时间戳时的片段起点——从 [toTickMs] 往回「音频时长 + 1 秒」，
/// 无音频则 6 秒（见 [kGalWindowVideoFallbackWindowMs]）。不早于 0。
int fallbackGalWindowVideoFromTick({
  required int toTickMs,
  required int? audioDurationMs,
}) {
  final int window = audioDurationMs == null
      ? kGalWindowVideoFallbackWindowMs
      : audioDurationMs + kGalWindowVideoFallbackTailMs;
  return math.max(0, toTickMs - window);
}

/// galgame「视频片段」封面：把会话录制导出的 JPEG 帧（[export]，按 tick 升序）按真实
/// 时间轴拼成 H.264 mp4，并把句子音频 [audioBytes]（已封装的 AAC/m4a 容器字节，扩展名
/// [audioExtension]）混流进去。
///
/// [fromTickMs] 为 null 表示没有 hook 台词时间戳，起点按
/// [fallbackGalWindowVideoFromTick] 从终点倒推；[toTickMs] `<= 0` 表示「现在」
/// （= [WindowRecordingExport.nowTickMs]）。
///
/// **fail-open**：帧不足 2 张 / 导出失败 / ffmpeg 缺失 / 编码失败 / 任何异常都返回
/// null 而不抛，调用方据此降级到动图 → 静图（与 `captureWindowGifBytes` 同一条纪律）。
/// [workDir] 由调用方负责创建与清理（列表文件、音频、产物都写在里面）。
Future<GalWindowVideoClip?> buildGalWindowVideoClip({
  required WindowRecordingExport export,
  required int? fromTickMs,
  required int toTickMs,
  Uint8List? audioBytes,
  required String audioExtension,
  required Directory workDir,
  FfmpegBackend? backend,
  Duration encodeTimeout = kGalWindowVideoEncodeTimeout,
}) async {
  try {
    if (!export.ok) {
      ErrorLogService.instance.logDiagnostic(
        'buildGalWindowVideoClip',
        'recording export unavailable: ${export.error ?? 'unknown'}',
      );
      return null;
    }
    if (export.frames.length < 2) return null;
    final FfmpegBackend ffmpeg = backend ?? resolveFfmpegBackend();
    final int to = toTickMs <= 0 ? export.nowTickMs : toTickMs;

    String? audioPath;
    int? audioDurationMs;
    if (audioBytes != null && audioBytes.isNotEmpty) {
      audioPath = p.join(workDir.path, 'sentence.$audioExtension');
      await File(audioPath).writeAsBytes(audioBytes, flush: true);
      audioDurationMs = await probeGalWindowAudioDurationMs(ffmpeg, audioPath);
    }

    final int from = fromTickMs ??
        fallbackGalWindowVideoFromTick(
          toTickMs: to,
          audioDurationMs: audioDurationMs,
        );
    final List<GalWindowVideoFrameEntry> plan = planGalWindowVideoFrames(
      frames: export.frames,
      fromTickMs: from,
      toTickMs: to,
      audioDurationMs: audioDurationMs,
    );
    if (plan.length < 2) {
      ErrorLogService.instance.logDiagnostic(
        'buildGalWindowVideoClip',
        'not enough recorded frames in [$from, $to]: ${plan.length}',
      );
      return null;
    }

    final String listPath = p.join(workDir.path, 'frames.ffconcat');
    await File(
      listPath,
    ).writeAsString(buildGalWindowConcatList(plan), flush: true);
    final String outputPath = p.join(workDir.path, 'clip.mp4');
    final FfmpegRunResult result = await ffmpeg.run(
      buildGalWindowVideoArgs(
        listPath: listPath,
        audioPath: audioPath,
        outputPath: outputPath,
      ),
      encodeTimeout,
    );
    final File output = File(outputPath);
    if (result.returnCode != 0 ||
        !output.existsSync() ||
        output.lengthSync() == 0) {
      ErrorLogService.instance.log(
        'buildGalWindowVideoClip',
        'mp4 encode failed: ${result.failureSummary}',
        StackTrace.current,
      );
      return null;
    }
    return (bytes: await output.readAsBytes(), extension: 'mp4');
  } catch (e, stack) {
    ErrorLogService.instance.log('buildGalWindowVideoClip', e, stack);
    return null;
  }
}
