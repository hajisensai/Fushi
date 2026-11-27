import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:fushi_asr_core/asr_core.dart' as asr;
import 'package:fushi_engine/media/video/video_clip_exporter.dart'
    show resolveAudioMapIndex;

/// 「无字幕时间时的句子音频」（拍板台 lmJyeqpCaO）。
///
/// 没有字幕轨的视频（galgame 实况、硬字幕）做画面 OCR 查词制卡时，mpv 拿不到
/// `sub-start`，也没有任何 cue 可锚，制卡区间以前塌成 `0..0`：卡片只有当前帧静图。
/// 这里按设置从**暂停位置**附近猜一段句子音频：
///
/// - [UntimedSentenceAudioMode.off]（默认）：与以前完全一样，不截；
/// - [UntimedSentenceAudioMode.fixedWindow]：以暂停位置为准取固定长度，前 2/3、后
///   1/3（[untimedFixedWindow]）；
/// - [UntimedSentenceAudioMode.voiceDetection]：对暂停位置前后做人声检测（复用有声书
///   转写的 Silero VAD 与它的 640 KB 模型），取包含暂停位置的那段人声，暂停在停顿里就
///   取它前面最近的一段（[untimedVoiceWindow]）；检测失败退回固定窗口。
///
/// 有字幕轨（文本 / 图形字幕）的视频完全不走这里。纯函数与检测器都不依赖 Flutter
/// 页面，页面只负责在锚点为空时调用、并把结果当一条合成 cue 交给原有制卡链。
enum UntimedSentenceAudioMode {
  off('off'),
  fixedWindow('fixed_window'),
  voiceDetection('voice_detection');

  const UntimedSentenceAudioMode(this.wireName);

  /// 偏好里存的值（`mining_untimed_audio_mode`）。
  final String wireName;

  /// 未知 / 缺失值回退 [off]（= 现状）。
  static UntimedSentenceAudioMode fromWireName(String? name) {
    for (final UntimedSentenceAudioMode mode in values) {
      if (mode.wireName == name) return mode;
    }
    return UntimedSentenceAudioMode.off;
  }
}

/// 窗口长度 / 人声检测最长上限的取值范围与默认值（毫秒），设置滑条按秒走。
const int kUntimedSentenceAudioWindowMinMs = 2000;
const int kUntimedSentenceAudioWindowMaxMs = 15000;
const int kUntimedSentenceAudioWindowDefaultMs = 6000;
const int kUntimedSentenceAudioWindowStepMs = 1000;

/// 把存储值规整到 [kUntimedSentenceAudioWindowMinMs]..[kUntimedSentenceAudioWindowMaxMs]
/// 并取整到 [kUntimedSentenceAudioWindowStepMs]；null 回退默认。
int normalizeUntimedSentenceAudioWindowMs(int? ms) {
  if (ms == null) return kUntimedSentenceAudioWindowDefaultMs;
  final int stepped =
      (ms / kUntimedSentenceAudioWindowStepMs).round() *
      kUntimedSentenceAudioWindowStepMs;
  return stepped.clamp(
    kUntimedSentenceAudioWindowMinMs,
    kUntimedSentenceAudioWindowMaxMs,
  );
}

/// 这段区间是怎么来的（高级制卡里那行「来源」小字、快速制卡的提示据此选文案）。
enum UntimedSentenceAudioOrigin {
  /// 设置就是固定窗口。
  fixedWindow,

  /// 人声检测找到了包含（或紧挨在前的）那段人声。
  voiceDetection,

  /// 设置是人声检测，但检测失败 / 没有找到人声 / 当前来源测不了，退回了固定窗口。
  voiceDetectionFallback,
}

/// 猜出的句子音频区间（播放器时间轴，毫秒）。
@immutable
class UntimedSentenceAudioWindow {
  const UntimedSentenceAudioWindow({
    required this.startMs,
    required this.endMs,
    required this.origin,
  });

  final int startMs;
  final int endMs;
  final UntimedSentenceAudioOrigin origin;

  int get durationMs => endMs - startMs;

  @override
  bool operator ==(Object other) =>
      other is UntimedSentenceAudioWindow &&
      other.startMs == startMs &&
      other.endMs == endMs &&
      other.origin == origin;

  @override
  int get hashCode => Object.hash(startMs, endMs, origin);

  @override
  String toString() => 'UntimedSentenceAudioWindow($startMs..$endMs, $origin)';
}

/// 固定窗口：以 [positionMs]（暂停位置）为准，往前取 2/3、往后取 1/3——台词通常在
/// 画面文字出现时已经开始，偏向往前取。贴近片头 / 片尾时整体平移，保持长度不变
/// （[durationMs] 未知时只夹片头）。
UntimedSentenceAudioWindow untimedFixedWindow({
  required int positionMs,
  required int windowMs,
  int? durationMs,
  UntimedSentenceAudioOrigin origin = UntimedSentenceAudioOrigin.fixedWindow,
}) {
  final int length = normalizeUntimedSentenceAudioWindowMs(windowMs);
  final int pos = math.max(0, positionMs);
  int start = pos - length * 2 ~/ 3;
  if (start < 0) start = 0;
  int end = start + length;
  if (durationMs != null && durationMs > 0 && end > durationMs) {
    end = durationMs;
    start = math.max(0, end - length);
  }
  return UntimedSentenceAudioWindow(startMs: start, endMs: end, origin: origin);
}

/// 人声检测：从按时间排序的人声段 [segments]（未外扩的人声窗口，播放器轴毫秒）里取
/// 暂停位置 [positionMs] 那一句。
///
/// - 有段包含暂停位置 → 取它；否则取暂停位置之前最近的那段（暂停在句间停顿里，画面
///   上的字通常是刚说完的那句）；都没有 → null（调用方退回固定窗口）。
/// - 超过 [maxMs] 截断：包含暂停位置的段按「前 2/3、后 1/3」围着暂停位置截，之前的
///   段保留离暂停位置最近的末尾。
/// - 再按用户的句子音频开头 / 结尾余量（[headPadMs] / [tailPadMs]）外扩，但不越过
///   相邻人声段（与字幕制卡「余量不越过上一句 / 下一句」同一语义），也不早于 0。
UntimedSentenceAudioWindow? untimedVoiceWindow({
  required List<({int startMs, int endMs})> segments,
  required int positionMs,
  required int maxMs,
  int headPadMs = 0,
  int tailPadMs = 0,
}) {
  final List<({int startMs, int endMs})> valid =
      <({int startMs, int endMs})>[
        for (final ({int startMs, int endMs}) s in segments)
          if (s.endMs > s.startMs) s,
      ]..sort(
        (({int startMs, int endMs}) a, ({int startMs, int endMs}) b) =>
            a.startMs.compareTo(b.startMs),
      );
  int index = -1;
  bool containing = false;
  for (int i = 0; i < valid.length; i++) {
    final ({int startMs, int endMs}) s = valid[i];
    if (s.startMs <= positionMs && positionMs <= s.endMs) {
      index = i;
      containing = true;
      break;
    }
    if (s.endMs <= positionMs) index = i;
  }
  if (index < 0) return null;
  final ({int startMs, int endMs}) picked = valid[index];
  final int limit = normalizeUntimedSentenceAudioWindowMs(maxMs);
  int start = picked.startMs;
  int end = picked.endMs;
  if (end - start > limit) {
    if (containing) {
      start = math.max(picked.startMs, positionMs - limit * 2 ~/ 3);
      end = start + limit;
      if (end > picked.endMs) {
        end = picked.endMs;
        start = end - limit;
      }
    } else {
      start = end - limit;
    }
  }
  final int previousEnd = index > 0 ? valid[index - 1].endMs : 0;
  final int? nextStart = index + 1 < valid.length
      ? valid[index + 1].startMs
      : null;
  final int paddedStart = math.max(
    math.max(0, previousEnd),
    start - math.max(0, headPadMs),
  );
  final int rawPaddedEnd = end + math.max(0, tailPadMs);
  final int paddedEnd = nextStart == null
      ? rawPaddedEnd
      : math.min(rawPaddedEnd, math.max(end, nextStart));
  return UntimedSentenceAudioWindow(
    startMs: math.min(paddedStart, start),
    endMs: paddedEnd,
    origin: UntimedSentenceAudioOrigin.voiceDetection,
  );
}

/// 人声检测的分析窗口（播放器轴毫秒）：暂停位置前后各「最长上限 + 1 秒」，不超过
/// 15 秒（设计图「对暂停位置前后最多 15 秒做人声检测」）。分析范围只需覆盖截断后的
/// 结果：包含暂停位置的段会被截到上限以内，之前那段也只保留上限长的末尾。
({int startMs, int durationMs}) untimedVoiceAnalysisWindow({
  required int positionMs,
  required int maxMs,
  int? durationMs,
}) {
  final int radius = math.min(
    kUntimedSentenceAudioWindowMaxMs,
    normalizeUntimedSentenceAudioWindowMs(maxMs) + 1000,
  );
  final int start = math.max(0, positionMs - radius);
  int end = positionMs + radius;
  if (durationMs != null && durationMs > 0) end = math.min(end, durationMs);
  return (startMs: start, durationMs: math.max(0, end - start));
}

/// **纯函数**：构造「从 [source] 截 [startMs] 起 [durationMs] 长、16 kHz 单声道
/// s16 WAV」的 ffmpeg 参数。多音轨按 [resolveAudioMapIndex] 裁到正在听的那条（越界
/// 回退默认轨，与制卡裁音同一判据）。输入端 `-ss` 在转码时是精确 seek。
List<String> buildUntimedVoicePcmArgs({
  required String source,
  required String outputPath,
  required int startMs,
  required int durationMs,
  int? audioStreamIndex,
  int? audioStreamCount,
}) {
  final int? mapIndex = resolveAudioMapIndex(
    audioStreamIndex: audioStreamIndex,
    audioStreamCount: audioStreamCount,
  );
  return <String>[
    '-hide_banner',
    '-nostats',
    '-loglevel',
    'error',
    '-y',
    if (startMs > 0) ...<String>['-ss', (startMs / 1000).toStringAsFixed(3)],
    '-i',
    source,
    '-t',
    (durationMs / 1000).toStringAsFixed(3),
    if (mapIndex != null) ...<String>['-map', '0:a:$mapIndex'],
    '-vn',
    '-sn',
    '-dn',
    '-map_metadata',
    '-1',
    '-ac',
    '1',
    '-ar',
    '${asr.kAsrSampleRate}',
    '-c:a',
    'pcm_s16le',
    '-fflags',
    '+bitexact',
    '-f',
    'wav',
    outputPath,
  ];
}

/// **纯函数**：取 WAV 的 `data` 块（16 位 PCM）转成 float32。按 RIFF 子块逐个跳，不
/// 假设 44 字节头（ffmpeg 可能写 `LIST` 块）；不是 RIFF/WAVE 或没有 `data` 块抛
/// [FormatException]。流式输出把 `data` 长度写成 0 / 0xFFFFFFFF 时取到文件尾。
Float32List decodeWavPcm16(Uint8List bytes) {
  if (bytes.length < 12 ||
      String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
      String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }
  final ByteData view = ByteData.sublistView(bytes);
  int offset = 12;
  while (offset + 8 <= bytes.length) {
    final String id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    final int size = view.getUint32(offset + 4, Endian.little);
    final int body = offset + 8;
    if (id == 'data') {
      final int end = (size == 0 || size == 0xFFFFFFFF)
          ? bytes.length
          : math.min(bytes.length, body + size);
      return asr.pcmS16leToFloat32(Uint8List.sublistView(bytes, body, end));
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  throw const FormatException('WAV has no data chunk');
}
