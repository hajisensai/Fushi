import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;

/// galgame 一键制卡（docs/specs/galgame-mining）波形数据桥。
///
/// 视频波形 UI 复用的是 `downsampleEnergyEnvelope`（`audio_energy_probe.dart`），它吃的是
/// **逐帧 RMS dBFS 序列**（视频那边由 ffmpeg astats 产出）。loopback 给的是裸 PCM，所以这里
/// 补上等价的一步：把 PCM 切成 [windowMs] 的窗，逐窗算 RMS 并转 dBFS（≤0，越大越响），产出
/// 和 ffmpeg 同构的能量帧，下游 `downsampleEnergyEnvelope` + `SubtitleWaveformPainter` 原样
/// 复用。纯函数、无 IO，可单测。

/// 波形能量窗（毫秒），与视频波形对齐用的 `kSubtitleWaveformWindowMs` 一致（20ms）。
const int kGalWaveformWindowMs = 20;

/// 把裸 PCM 转成逐窗 RMS dBFS 能量帧（喂 `downsampleEnergyEnvelope`）。
///
/// 支持 WASAPI 共享模式常见格式：16-bit 整型、32-bit 整型、32-bit float。其它位深无法可靠
/// 解码时返回空列表（下游据此画空波形，不崩、不乱画）。[silenceDb] 为静音地板（RMS 为 0 的
/// 窗返回它），结果每帧 ∈ [silenceDb, 0]。
List<double> pcmToEnergyEnvelope(
  Uint8List pcm,
  PcmFormat format, {
  int windowMs = kGalWaveformWindowMs,
  double silenceDb = -120.0,
}) {
  final int bytesPerSample = format.bitsPerSample ~/ 8;
  final int channels = format.channels;
  if (pcm.isEmpty ||
      channels <= 0 ||
      bytesPerSample <= 0 ||
      format.sampleRate <= 0 ||
      windowMs <= 0) {
    return const <double>[];
  }
  // 解码单个采样到 [-1,1]；不支持的格式返回 null（整体降级为空包络）。
  final ByteData bd = ByteData.sublistView(pcm);
  double? Function(int byteOffset)? decode;
  if (format.isFloat && format.bitsPerSample == 32) {
    decode = (o) => bd.getFloat32(o, Endian.little).toDouble();
  } else if (!format.isFloat && format.bitsPerSample == 16) {
    decode = (o) => bd.getInt16(o, Endian.little) / 32768.0;
  } else if (!format.isFloat && format.bitsPerSample == 32) {
    decode = (o) => bd.getInt32(o, Endian.little) / 2147483648.0;
  }
  if (decode == null) {
    return const <double>[];
  }

  final int frameBytes = channels * bytesPerSample;
  final int totalFrames = pcm.length ~/ frameBytes;
  if (totalFrames == 0) {
    return const <double>[];
  }
  final int framesPerWindow =
      math.max(1, (format.sampleRate * windowMs) ~/ 1000);
  final double floorAmp = math.pow(10.0, silenceDb / 20.0).toDouble();

  final List<double> envelope = <double>[];
  for (int f0 = 0; f0 < totalFrames; f0 += framesPerWindow) {
    final int f1 = math.min(totalFrames, f0 + framesPerWindow);
    double sumSq = 0.0;
    int count = 0;
    for (int f = f0; f < f1; f++) {
      final int frameOffset = f * frameBytes;
      for (int c = 0; c < channels; c++) {
        final double s = decode(frameOffset + c * bytesPerSample)!;
        sumSq += s * s;
        count++;
      }
    }
    final double rms = count > 0 ? math.sqrt(sumSq / count) : 0.0;
    final double amp = rms < floorAmp ? floorAmp : rms;
    double db = 20.0 * (math.log(amp) / math.ln10);
    if (db > 0.0) db = 0.0;
    if (db < silenceDb) db = silenceDb;
    envelope.add(db);
  }
  return envelope;
}
