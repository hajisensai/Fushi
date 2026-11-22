/// 跨应用语音缓存 · 制卡前试听 + 调起止（拍板 design-cross-app-audio-trim-ui，方案 A）。
///
/// 应用外查词卡（电脑端 WebView2 覆盖窗、Android `:popup` 查词窗）都是 popup.js 画的，
/// 「调整句子音频」面板也画在 popup.js 里：不抢游戏的前台焦点、两端一份实现。这里是它的
/// 宿主侧——两根桥的数据：
/// - `crossAppAudioAvailable`：这次查词有没有录到声音（面板入口按钮据此显隐）；
/// - `crossAppAudioPreview`：波形峰值 + 自动截句的默认区间 + 一段可直接播的 WAV。
///
/// 用户在面板里拖出的起止以**相对自动截句的偏移**随制卡字段走
/// （`MiningRequestOverrides.audioStartDeltaMs` / `audioEndDeltaMs`，与 app 内「高级制卡」
/// 同一条线），制卡时 [prepareCrossAppSentenceAudio] 从同一份快照重算默认区间再加偏移。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/mining/cross_app_audio/cross_app_audio_clip.dart';
import 'package:fushi/src/mining/galgame_audio_encode.dart'
    show PcmFormat, buildWavBytes, pcmDurationMs;
import 'package:fushi/src/mining/galgame_audio_source.dart' show GalAudioSlice;
import 'package:fushi/src/mining/galgame_line_voice_window.dart'
    show pcmFrameRms;
import 'package:fushi/src/mining/galgame_waveform_select.dart'
    show GalWaveformRange;
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 波形最多画这么多根柱（查词卡宽几百像素，再多也画不出来，只白白加大桥上的回包）。
const int kCrossAppAudioPreviewMaxPeaks = 480;

/// 波形一根柱至少覆盖这么多毫秒（短快照不必切得比 RMS 能分辨的更细）。
const int kCrossAppAudioPreviewMinPeakMs = 10;

/// 试听音频降到的目标采样率（Hz）：只用来听「截到哪了」，16 kHz 单声道足够听清人声，
/// 30 秒约 1 MB，经 WebView 桥一次送达。
const int kCrossAppAudioPreviewSampleRate = 16000;

/// 波形柱高的显示下限（dBFS）：低于它画成平线。
const double kCrossAppAudioPreviewFloorDb = -60.0;

/// 试听面板一次要的全部数据。
class CrossAppAudioPreview {
  const CrossAppAudioPreview({
    required this.totalMs,
    required this.defaultRange,
    required this.peaks,
    required this.wav,
  });

  /// 快照总时长（毫秒）。
  final int totalMs;

  /// 一键「+」会截的那段（[crossAppAudioDefaultRange]）；面板的偏移都相对它。
  final GalWaveformRange defaultRange;

  /// 均匀切成的波形柱高（0..1，按 dBFS 线性映射，见 [kCrossAppAudioPreviewFloorDb]）。
  final List<double> peaks;

  /// 整段快照降成 16 kHz 单声道 16-bit 的 WAV（面板据此试听任意区间）。
  final Uint8List wav;

  /// `crossAppAudioPreview` 桥的回包（popup.js `openCrossAppAudioPanel` 读）。
  Map<String, Object?> toBridgeJson() => <String, Object?>{
    'totalMs': totalMs,
    'startMs': defaultRange.startMs,
    'endMs': defaultRange.endMs,
    'minClipMs': kCrossAppAudioMinClipMs,
    'peaks': peaks,
    'audio': 'data:audio/wav;base64,${base64Encode(wav)}',
  };
}

/// 由一段快照 PCM 算出试听数据（纯函数，可单测）。整段静音（自动截句返回 null，
/// 这张卡本来就不带句子音频）或位深不认识（波形与试听都解不出）返回 null。
CrossAppAudioPreview? buildCrossAppAudioPreview(GalAudioSlice slice) {
  final int totalMs = pcmDurationMs(slice.pcm.length, slice.format.byteRate);
  if (totalMs <= 0) return null;
  final GalWaveformRange? range = crossAppAudioDefaultRange(slice);
  if (range == null) return null;
  final int peakMs = math.max(
    kCrossAppAudioPreviewMinPeakMs,
    (totalMs / kCrossAppAudioPreviewMaxPeaks).ceil(),
  );
  final List<double>? rms = pcmFrameRms(slice, frameMs: peakMs);
  final Uint8List? mono = _downmixForPreview(slice);
  if (rms == null || rms.isEmpty || mono == null) return null;
  return CrossAppAudioPreview(
    totalMs: totalMs,
    defaultRange: range,
    peaks: <double>[for (final double r in rms) _peakHeight(r)],
    wav: buildWavBytes(
      mono,
      PcmFormat(
        sampleRate: _previewRate(slice.format.sampleRate),
        channels: 1,
        bitsPerSample: 16,
        isFloat: false,
      ),
    ),
  );
}

/// RMS → 柱高：dBFS 在 [[kCrossAppAudioPreviewFloorDb], 0] 线性映射到 0..1，保留三位小数
/// （回包是 JSON，十几位小数纯属浪费）。
double _peakHeight(double rms) {
  if (rms <= 1e-6) return 0;
  const double floor = kCrossAppAudioPreviewFloorDb;
  final double db = 20 * math.log(rms) / math.ln10;
  final double height = ((db - floor) / -floor).clamp(0.0, 1.0);
  return (height * 1000).round() / 1000;
}

/// 试听音频的实际采样率：原采样率按整数倍抽取到不低于 [kCrossAppAudioPreviewSampleRate]
/// 的最低一档（48k → 16k，44.1k → 22.05k，本来就低的不动）。
int _previewRate(int sampleRate) =>
    sampleRate ~/ math.max(1, sampleRate ~/ kCrossAppAudioPreviewSampleRate);

/// 混成单声道、按整数倍抽取（抽取前对这几帧取平均，等于一个简单的低通，防混叠刺耳），
/// 写成 16-bit 小端整型。只认 16-bit 整型与 32-bit 浮点（与 [pcmFrameRms] 同口径）。
Uint8List? _downmixForPreview(GalAudioSlice slice) {
  final PcmFormat format = slice.format;
  final bool float32 = format.isFloat && format.bitsPerSample == 32;
  final bool int16 = !format.isFloat && format.bitsPerSample == 16;
  final int block = format.blockAlign;
  if ((!float32 && !int16) || block <= 0 || format.channels <= 0) return null;
  final int step = math.max(
    1,
    format.sampleRate ~/ _previewRate(format.sampleRate),
  );
  final int frames = slice.pcm.length ~/ block;
  final int outFrames = frames ~/ step;
  final ByteData data = ByteData.sublistView(slice.pcm);
  final ByteData out = ByteData(outFrames * 2);
  final int sampleBytes = format.bitsPerSample ~/ 8;
  final int perOut = step * format.channels;
  for (int o = 0; o < outFrames; o++) {
    double sum = 0;
    final int firstFrame = o * step;
    for (int f = firstFrame; f < firstFrame + step; f++) {
      for (int c = 0; c < format.channels; c++) {
        final int offset = f * block + c * sampleBytes;
        sum += float32
            ? data.getFloat32(offset, Endian.little)
            : data.getInt16(offset, Endian.little) / 32768.0;
      }
    }
    final int v = (sum / perOut * 32767).round().clamp(-32768, 32767);
    out.setInt16(o * 2, v, Endian.little);
  }
  return out.buffer.asUint8List();
}

/// 把 [snapshot] 落成试听数据：钉住型快照先落进一个临时目录（读完即删），读 PCM 与
/// 算波形 / 抽取都在后台 isolate。快照已失效 / 静音 / 格式不认识返回 null。
Future<CrossAppAudioPreview?> loadCrossAppAudioPreview(
  CrossAppAudioSnapshot snapshot,
) async {
  final Directory dir = await Directory.systemTemp.createTemp(
    kCrossAppAudioTempPrefix,
  );
  try {
    final CrossAppAudioFileSnapshot? file = await snapshot.materialize(dir);
    if (file == null) return null;
    final String path = file.pcmPath;
    final PcmFormat format = file.format;
    return await Isolate.run(() {
      final Uint8List pcm = File(path).readAsBytesSync();
      return buildCrossAppAudioPreview(GalAudioSlice(pcm: pcm, format: format));
    });
  } finally {
    await deleteCrossAppAudioDir(dir);
  }
}

/// 同一份快照的试听回包只算一次（用户关了面板再打开不重读、不重算）。
final Expando<Future<Map<String, Object?>?>> _previewReplies =
    Expando<Future<Map<String, Object?>?>>('crossAppAudioPreview');

/// `crossAppAudioAvailable` 桥：这次查词的快照有没有东西。没开缓存 / 不是应用外查词 /
/// 快照失败都回 false（面板入口不显示）。
Future<bool> crossAppAudioAvailableReply(
  Future<CrossAppAudioSnapshot?>? snapshot,
) async => await _takeSnapshot(snapshot) != null;

/// `crossAppAudioPreview` 桥：[CrossAppAudioPreview.toBridgeJson]；取不到回 null
/// （面板就地说「这次查词没有录到声音」）。
Future<Map<String, Object?>?> crossAppAudioPreviewReply(
  Future<CrossAppAudioSnapshot?>? snapshot,
) async {
  final CrossAppAudioSnapshot? taken = await _takeSnapshot(snapshot);
  if (taken == null) return null;
  return _previewReplies[taken] ??= _buildPreviewReply(taken);
}

Future<Map<String, Object?>?> _buildPreviewReply(
  CrossAppAudioSnapshot snapshot,
) async {
  try {
    return (await loadCrossAppAudioPreview(snapshot))?.toBridgeJson();
  } on Exception catch (error, stack) {
    ErrorLogService.instance.log('CrossAppAudio.preview', error, stack);
    return null;
  }
}

Future<CrossAppAudioSnapshot?> _takeSnapshot(
  Future<CrossAppAudioSnapshot?>? snapshot,
) async {
  if (snapshot == null) return null;
  try {
    return await snapshot;
  } on Exception catch (error, stack) {
    ErrorLogService.instance.log('CrossAppAudio.previewSnapshot', error, stack);
    return null;
  }
}
