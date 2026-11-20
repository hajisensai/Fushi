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
import 'dart:isolate';
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

/// 有声判据：至少比该帧附近的背景（[kCrossAppAudioFloorWindowMs] 窗内帧 dB 的
/// [kCrossAppAudioFloorPercentile] 分位）高这么多分贝。手游几乎都垫着连续 BGM，BGM 只比
/// 人声低 6–15 dB，只看全局峰值会把 BGM 也当有声、一路截到缓冲开头。
const double kCrossAppAudioAboveFloorDb = 8.0;

/// 估背景用的滑动窗长（毫秒）。要比一句台词长得多，窗里多数帧才是背景。
const int kCrossAppAudioFloorWindowMs = 10000;

/// 估背景取窗内帧 dB 的这个分位（0–1）。取低分位而不是最小值：BGM 自身有起伏，
/// 最小值会落在 BGM 的弱拍上，阈值随之偏低、BGM 强拍被当成人声。
const double kCrossAppAudioFloorPercentile = 0.3;

/// 背景判据最多把阈值抬到峰值以下这么多分贝：整段都是同一响度（一直在说话、或
/// 只有 BGM 没人声）时背景 ≈ 峰值，不能因此一帧都不过阈。
const double kCrossAppAudioPeakHeadroomDb = 3.0;

/// 一次最多截这么长（毫秒，不含前后余量）。分不出人声时（只有 BGM、或人声被 BGM
/// 盖住）退回到查词前最近这一段，而不是把整段 30 秒挂到卡上；精确起止要等试听 /
/// 调起止（第二段）由用户来定。
const int kCrossAppAudioMaxClipMs = 15000;

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
/// 混音里分不出人声，但分得出「比背景响」：逐帧 RMS 转 dBFS，第 i 帧的阈值取
/// max(峰值 − [kCrossAppAudioRelDropDb],
///     min(背景_i + [kCrossAppAudioAboveFloorDb], 峰值 − [kCrossAppAudioPeakHeadroomDb]),
///     [kCrossAppAudioAbsFloorDb])，
/// 背景_i 是该帧附近的自适应噪声底（滑动分位数，见 [kCrossAppAudioFloorPercentile]）——
/// 垫着连续 BGM 时 BGM 落在背景里，只有压过 BGM 的人声过阈。从最后一个过阈帧往前
/// 走，停顿短于 [kCrossAppAudioMaxGapMs] 的并进同一句，直到遇到更长的安静段；截出的
/// 一句超过 [kCrossAppAudioMaxClipMs] 时只留结尾那一段。
/// 位深不认识时返回整段（多截一点由用户在卡片里听，不丢字）；整段没有一帧过阈值
/// （游戏拒绝被录 = 录到静音、或查词前根本没声音）返回 null——这张卡不该挂一段静音。
GalWaveformRange? crossAppAudioDefaultRange(GalAudioSlice slice) {
  final int totalMs = pcmDurationMs(slice.pcm.length, slice.format.byteRate);
  final GalWaveformRange full = GalWaveformRange(startMs: 0, endMs: totalMs);
  if (totalMs <= 0) return null;
  final List<double>? rms = pcmFrameRms(slice, frameMs: kCrossAppAudioFrameMs);
  if (rms == null || rms.isEmpty) return full;
  final List<double> db = <double>[
    for (final double r in rms) r <= 1e-6 ? -120.0 : 20 * _log10(r),
  ];
  final double peak = db.reduce(math.max);
  final List<double> floor = _slidingPercentile(
    db,
    window: kCrossAppAudioFloorWindowMs ~/ kCrossAppAudioFrameMs,
    percentile: kCrossAppAudioFloorPercentile,
  );
  final List<double> threshold = <double>[
    for (int i = 0; i < db.length; i++)
      math.max(
        math.max(
          peak - kCrossAppAudioRelDropDb,
          math.min(
            floor[i] + kCrossAppAudioAboveFloorDb,
            peak - kCrossAppAudioPeakHeadroomDb,
          ),
        ),
        kCrossAppAudioAbsFloorDb,
      ),
  ];
  int last = -1;
  for (int i = db.length - 1; i >= 0; i--) {
    if (db[i] >= threshold[i]) {
      last = i;
      break;
    }
  }
  if (last < 0) return null;
  const int maxGapFrames = kCrossAppAudioMaxGapMs ~/ kCrossAppAudioFrameMs;
  int first = last;
  int gap = 0;
  for (int i = last - 1; i >= 0; i--) {
    if (db[i] >= threshold[i]) {
      first = i;
      gap = 0;
    } else if (++gap > maxGapFrames) {
      break;
    }
  }
  const int maxClipFrames = kCrossAppAudioMaxClipMs ~/ kCrossAppAudioFrameMs;
  first = math.max(first, last + 1 - maxClipFrames);
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

/// 每个下标取以它为中心、长 [window] 的窗内 [values] 的 [percentile] 分位；窗碰到两端时
/// 整窗平移进界内（窗长不变，背景估计不因靠近缓冲末尾而退化成只看几帧）。
List<double> _slidingPercentile(
  List<double> values, {
  required int window,
  required double percentile,
}) {
  final int n = values.length;
  final int w = math.max(1, math.min(window, n));
  final int k = ((w - 1) * percentile).round();
  final List<double> out = List<double>.filled(n, 0);
  final List<double> buf = List<double>.filled(w, 0);
  for (int i = 0; i < n; i++) {
    final int start = math.max(0, math.min(i - w ~/ 2, n - w));
    for (int j = 0; j < w; j++) {
      buf[j] = values[start + j];
    }
    buf.sort();
    out[i] = buf[k];
  }
  return out;
}

/// 读 [snapshot] 的 PCM，截出 [range]（缺省 = [crossAppAudioDefaultRange]）并经 [encode]
/// 编码成 `<新临时目录>/sentence.<extension>`。快照文件已被清掉 / 整段静音 / 编码失败返回
/// null（这张卡不带句子音频，照常制）。调用方制卡后删 `dir`（[deleteCrossAppAudioDir]）。
Future<({String path, Directory dir})?> prepareCrossAppSentenceAudio(
  CrossAppAudioSnapshot snapshot, {
  required CrossAppAudioEncoder encode,
  GalWaveformRange? range,
  String extension = 'm4a',
}) async {
  // 读几 MB 快照 + 逐帧 RMS / 滑动分位数都是毫秒级以上的活，放后台 isolate，
  // 不卡查词窗的 UI isolate。
  final ({Uint8List? clip, String? readError}) cut = await _cutInBackground(
    snapshot.pcmPath,
    snapshot.format,
    range,
  );
  if (cut.readError != null) {
    // 快照被后面的查词挤掉了（原生只留最近几份）：这张卡不带语音。
    ErrorLogService.instance.log(
      'CrossAppAudio.readSnapshot',
      cut.readError!,
      StackTrace.current,
    );
    return null;
  }
  final Uint8List? clip = cut.clip;
  if (clip == null || clip.isEmpty) return null;
  final Directory dir = await Directory.systemTemp.createTemp(
    kCrossAppAudioTempPrefix,
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

/// 单独一层函数：送进 isolate 的闭包只捕获这三个可发送的参数（不带调用方的编码器等）。
Future<({Uint8List? clip, String? readError})> _cutInBackground(
  String pcmPath,
  PcmFormat format,
  GalWaveformRange? range,
) => Isolate.run(() => _readAndCut(pcmPath, format, range));

/// [prepareCrossAppSentenceAudio] 的后台部分：读快照、定范围、截 PCM。读失败把原因带回
/// （日志服务只在主 isolate 有），整段静音 / 空文件返回 `clip: null`。
({Uint8List? clip, String? readError}) _readAndCut(
  String pcmPath,
  PcmFormat format,
  GalWaveformRange? range,
) {
  final Uint8List pcm;
  try {
    pcm = File(pcmPath).readAsBytesSync();
  } on FileSystemException catch (error) {
    return (clip: null, readError: error.toString());
  }
  if (pcm.isEmpty) return (clip: null, readError: null);
  final GalWaveformRange? chosen =
      range ??
      crossAppAudioDefaultRange(GalAudioSlice(pcm: pcm, format: format));
  if (chosen == null) return (clip: null, readError: null);
  return (
    clip: slicePcmByMs(pcm, format, chosen.startMs, chosen.endMs),
    readError: null,
  );
}

/// 删掉 [prepareCrossAppSentenceAudio] 建的临时目录（Anki 后端已拷走媒体）。
/// [prepareCrossAppSentenceAudio] 临时目录的名字前缀。
const String kCrossAppAudioTempPrefix = 'fushi_cross_app_audio_';

/// 制卡中途进程被杀时，[prepareCrossAppSentenceAudio] 的临时目录（里面是从其他 app 的
/// 声音里截出来的句子音频）没人删。主引擎启动与停止采集时扫一遍：只删 [minAge] 之前建的
/// ——查词窗进程可能正在用刚建的那一个（编码 + 制卡是秒级的事）。返回删掉的目录数。
Future<int> sweepStaleCrossAppAudioDirs({
  Directory? root,
  Duration minAge = const Duration(minutes: 10),
  DateTime? now,
}) async {
  final Directory base = root ?? Directory.systemTemp;
  final DateTime cutoff = (now ?? DateTime.now()).subtract(minAge);
  int removed = 0;
  try {
    await for (final FileSystemEntity entity in base.list(followLinks: false)) {
      if (entity is! Directory) continue;
      if (!p.basename(entity.path).startsWith(kCrossAppAudioTempPrefix)) {
        continue;
      }
      final FileStat stat = await entity.stat();
      if (stat.modified.isAfter(cutoff)) continue;
      await entity.delete(recursive: true);
      removed++;
    }
  } on FileSystemException catch (error, stack) {
    ErrorLogService.instance.log('CrossAppAudio.sweep', error, stack);
  }
  return removed;
}

Future<void> deleteCrossAppAudioDir(Directory dir) async {
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } on FileSystemException catch (error, stack) {
    ErrorLogService.instance.log('CrossAppAudio.cleanup', error, stack);
  }
}
