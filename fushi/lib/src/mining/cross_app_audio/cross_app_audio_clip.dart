/// 跨应用语音挖掘（拍板 oqk37s3QFL）的平台无关核心：查词那一刻从「最近一段声音」
/// 落下的快照里，找出查词前最后一句语音、截出来编码成句子音频文件。
///
/// 声音从哪来与这里无关：Android 是 AudioPlaybackCapture 录的其他 app 播放
/// （`CrossAppAudioService`），桌面是 WASAPI loopback 混音
/// （`audio_loopback_capture.cpp`）——两边都只交出「裸 PCM + 格式」，截取与编码的
/// 判据只在这一处写，桌面接入应用外查词时复用同一套（[CrossAppAudioEncoder] 换成
/// ffmpeg 实现即可）。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/mining/galgame_audio_encode.dart'
    show PcmFormat, pcmDurationMs, slicePcmByMs;
import 'package:fushi/src/mining/galgame_audio_source.dart'
    show GalAudioSlice, parseGalPcmFormat;
import 'package:fushi/src/mining/galgame_line_voice_window.dart'
    show pcmFrameRms;
import 'package:fushi/src/mining/galgame_waveform_select.dart'
    show GalWaveformRange;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:path/path.dart' as p;

/// 查词时往回取多长（毫秒）。截屏识字要先等识别、再点字，语音往往在十几秒前就播完了；
/// 30 秒仍远小于原生环容量（60 秒）。
const int kCrossAppAudioLookbackMs = 30000;

/// 语音检测的分析帧长（毫秒）。
const int kCrossAppAudioFrameMs = 50;

/// 同一句话里允许的最长停顿：短于它的低能量段（换气、词间停顿）并进同一句。
const int kCrossAppAudioMaxGapMs = 700;

/// 截出的语音前后各留的余量（毫秒），防句首辅音 / 句尾拖音被切。
const int kCrossAppAudioPadMs = 250;

/// 有声判据：比整段峰值低这么多分贝以内算「有声」。
const double kCrossAppAudioRelDropDb = 20.0;

/// 有声判据的绝对下限（dBFS）：峰值本身很轻时不把底噪当语音。
const double kCrossAppAudioAbsFloorDb = -45.0;

/// 查词那一刻落下的一段声音：原生写在 app 缓存目录的裸 PCM 文件 + 它的格式。
class CrossAppAudioSnapshot {
  const CrossAppAudioSnapshot({required this.pcmPath, required this.format});

  final String pcmPath;
  final PcmFormat format;

  /// 解析原生 `snapshot` 的回包（`{path, sampleRate, channels, bitsPerSample, isFloat}`）；
  /// 缺字段 / 格式不合法返回 null。
  static CrossAppAudioSnapshot? fromNative(Object? raw) {
    if (raw is! Map<Object?, Object?>) return null;
    final Object? path = raw['path'];
    if (path is! String || path.isEmpty) return null;
    final PcmFormat? format = parseGalPcmFormat(raw);
    if (format == null) return null;
    return CrossAppAudioSnapshot(pcmPath: path, format: format);
  }
}

/// 把截好的一段 PCM 编码写到 [outputPath]；成功返回 true。
typedef CrossAppAudioEncoder =
    Future<bool> Function(GalAudioSlice clip, String outputPath);

/// 在 [slice] 里找**最后一句**语音的范围（毫秒，已含前后余量）。
///
/// 混音里分不出人声，但分得出「响」：逐帧 RMS 转 dBFS，阈值取
/// max(峰值 − [kCrossAppAudioRelDropDb], [kCrossAppAudioAbsFloorDb])；从最后一个过阈帧往前
/// 走，停顿短于 [kCrossAppAudioMaxGapMs] 的并进同一句，直到遇到更长的安静段。
/// 判不出来（位深不认识、整段静音）时返回整段——多截一点由用户在卡片里听，不丢字。
GalWaveformRange crossAppAudioDefaultRange(GalAudioSlice slice) {
  final int totalMs = pcmDurationMs(slice.pcm.length, slice.format.byteRate);
  final GalWaveformRange full = GalWaveformRange(startMs: 0, endMs: totalMs);
  if (totalMs <= 0) return full;
  final List<double>? rms = pcmFrameRms(slice, frameMs: kCrossAppAudioFrameMs);
  if (rms == null || rms.isEmpty) return full;
  final List<double> db = <double>[
    for (final double r in rms) r <= 1e-6 ? -120.0 : 20 * _log10(r),
  ];
  final double peak = db.reduce(math.max);
  final double threshold = math.max(
    peak - kCrossAppAudioRelDropDb,
    kCrossAppAudioAbsFloorDb,
  );
  int last = -1;
  for (int i = db.length - 1; i >= 0; i--) {
    if (db[i] >= threshold) {
      last = i;
      break;
    }
  }
  if (last < 0) return full;
  const int maxGapFrames = kCrossAppAudioMaxGapMs ~/ kCrossAppAudioFrameMs;
  int first = last;
  int gap = 0;
  for (int i = last - 1; i >= 0; i--) {
    if (db[i] >= threshold) {
      first = i;
      gap = 0;
    } else if (++gap > maxGapFrames) {
      break;
    }
  }
  final int startMs = math.max(
    0,
    first * kCrossAppAudioFrameMs - kCrossAppAudioPadMs,
  );
  final int endMs = math.min(
    totalMs,
    (last + 1) * kCrossAppAudioFrameMs + kCrossAppAudioPadMs,
  );
  return endMs > startMs
      ? GalWaveformRange(startMs: startMs, endMs: endMs)
      : full;
}

double _log10(double x) => math.log(x) / math.ln10;

/// 读 [snapshot] 的 PCM，截出 [range]（缺省 = [crossAppAudioDefaultRange]）并经 [encode]
/// 编码成 `<新临时目录>/sentence.<extension>`。快照文件已被清掉 / 没有声音 / 编码失败返回
/// null（这张卡不带句子音频，照常制）。调用方制卡后删 `dir`（[deleteCrossAppAudioDir]）。
Future<({String path, Directory dir})?> prepareCrossAppSentenceAudio(
  CrossAppAudioSnapshot snapshot, {
  required CrossAppAudioEncoder encode,
  GalWaveformRange? range,
  String extension = 'm4a',
}) async {
  final Uint8List pcm;
  try {
    pcm = await File(snapshot.pcmPath).readAsBytes();
  } on FileSystemException catch (error, stack) {
    // 快照被后面的查词挤掉了（原生只留最近几份）：这张卡不带语音。
    ErrorLogService.instance.log('CrossAppAudio.readSnapshot', error, stack);
    return null;
  }
  if (pcm.isEmpty) return null;
  final GalAudioSlice slice = GalAudioSlice(pcm: pcm, format: snapshot.format);
  final GalWaveformRange chosen = range ?? crossAppAudioDefaultRange(slice);
  final Uint8List clip = slicePcmByMs(
    pcm,
    snapshot.format,
    chosen.startMs,
    chosen.endMs,
  );
  if (clip.isEmpty) return null;
  final Directory dir = await Directory.systemTemp.createTemp(
    'fushi_cross_app_audio_',
  );
  final String out = p.join(dir.path, 'sentence.$extension');
  bool ok = false;
  try {
    ok = await encode(GalAudioSlice(pcm: clip, format: snapshot.format), out);
    ok = ok && await File(out).exists();
  } finally {
    if (!ok) await deleteCrossAppAudioDir(dir);
  }
  return ok ? (path: out, dir: dir) : null;
}

/// 删掉 [prepareCrossAppSentenceAudio] 建的临时目录（Anki 后端已拷走媒体）。
Future<void> deleteCrossAppAudioDir(Directory dir) async {
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } on FileSystemException catch (error, stack) {
    ErrorLogService.instance.log('CrossAppAudio.cleanup', error, stack);
  }
}
