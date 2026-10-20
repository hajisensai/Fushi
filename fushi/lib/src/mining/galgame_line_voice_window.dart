import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fushi/src/mining/galgame_audio_encode.dart' show PcmFormat;
import 'package:fushi/src/mining/galgame_audio_source.dart' show GalAudioSlice;

/// 一句台词语音的最长时长（毫秒）：逐行语音窗口在「没有下一句」时的上限。
///
/// 一句话真正的右界是**下一句到达**（玩家推进 = 这句播完或被跳过）。旧实现把窗口写死
/// 成「一句语音不超过几秒」——loopback 冻结 4s + 预卷 1s = 5s、引擎 PCM 前向 6s——于是
/// 长句一律被截在那个秒数上、短句完整（用户报：「句子长的卡音频被截断，短的完整」）。
/// 这里的上限只兜「迟迟没有下一句」：30s 覆盖长独白，又远小于 loopback 环容量（60s）。
/// 与 native `kUtteranceMaxForwardMs`（voice_hook_utterance_window.h）同值。
const int kGalLineVoiceMaxMs = 30000;

/// 底噪判据的分析帧长。
const int kGalVoiceTailFrameMs = 50;

/// 只有末尾「底噪级」的连续时长达到这么久才裁：短于它的低能量段可能只是句中换气 /
/// 演出停顿，宁可留着。
const int kGalVoiceTailMinQuietMs = 1500;

/// 裁剪后在最后一个有声帧之后保留的余量（拖音 / 混响衰减）。
const int kGalVoiceTailPadMs = 500;

/// 有声判据：帧 RMS 高于底噪的倍数（≈ +4 dB）。
const double kGalVoiceTailActiveRatio = 1.6;

/// 从 [slice] 末尾去掉 [dropMs] 毫秒（帧对齐）。用于把「窗口收口时刻之后」才被回取
/// 进来的那一截切掉：loopback 的 `grabRecent` 只能取「现在往前」，回取作业在串行队列
/// 里排队期间录进环的声音属于下一句。[dropMs] `<= 0` 原样返回。
GalAudioSlice dropPcmTailMs(GalAudioSlice slice, int dropMs) {
  if (dropMs <= 0 || slice.isEmpty) return slice;
  final PcmFormat format = slice.format;
  final int block = format.blockAlign;
  if (block <= 0 || format.byteRate <= 0) return slice;
  final int dropBytes = (dropMs * format.byteRate ~/ 1000) ~/ block * block;
  final int keep = math.max(0, slice.pcm.length - dropBytes) ~/ block * block;
  if (keep >= slice.pcm.length) return slice;
  return GalAudioSlice(
    pcm: Uint8List.sublistView(slice.pcm, 0, keep),
    format: format,
  );
}

/// 逐帧 RMS（满幅归一到 [0, 1]）。不认识的位深返回 null。
List<double>? pcmFrameRms(
  GalAudioSlice slice, {
  int frameMs = kGalVoiceTailFrameMs,
}) {
  final PcmFormat format = slice.format;
  final int block = format.blockAlign;
  if (block <= 0 || format.sampleRate <= 0 || format.channels <= 0) {
    return null;
  }
  final bool float32 = format.isFloat && format.bitsPerSample == 32;
  final bool int16 = !format.isFloat && format.bitsPerSample == 16;
  if (!float32 && !int16) return null;
  final ByteData data = ByteData.sublistView(slice.pcm);
  final int frames = slice.pcm.length ~/ block;
  final int perFrame = math.max(1, format.sampleRate * frameMs ~/ 1000);
  final int sampleBytes = format.bitsPerSample ~/ 8;
  final List<double> out = <double>[];
  for (int start = 0; start < frames; start += perFrame) {
    final int end = math.min(frames, start + perFrame);
    double sum = 0;
    int n = 0;
    for (int f = start; f < end; f++) {
      for (int c = 0; c < format.channels; c++) {
        final int offset = f * block + c * sampleBytes;
        final double v = float32
            ? data.getFloat32(offset, Endian.little)
            : data.getInt16(offset, Endian.little) / 32768.0;
        sum += v * v;
        n++;
      }
    }
    out.add(n == 0 ? 0 : math.sqrt(sum / n));
  }
  return out;
}

/// loopback（整机混音）逐行切片的**尾部底噪裁剪**。
///
/// 窗口右界改成「下一句到达 / 制卡时刻」之后，玩家在一句上停得越久，切片尾部就跟着越长
/// 一段语音已经结束后的 BGM / 静音。混音里分不出人声，但能分出「比底噪响」：底噪取
/// 整段逐帧 RMS 的第 10 百分位（BGM 或静音的水平），最后一个高于 底噪 ×
/// [kGalVoiceTailActiveRatio] 的帧就是语音的末尾，之后留 [kGalVoiceTailPadMs]。
///
/// 只在判据明确时才裁，否则原样返回（多留尾巴只是长，裁错是丢字）：
///  * 末尾底噪级时长不足 [kGalVoiceTailMinQuietMs]（可能是句中停顿 / 话没说完）；
///  * 位深不认识、整段静音、底噪与峰值分不开（BGM 一直盖过人声）。
GalAudioSlice trimLoopbackTrailingFloor(GalAudioSlice slice) {
  if (slice.isEmpty) return slice;
  final List<double>? rms = pcmFrameRms(slice);
  if (rms == null || rms.length < 4) return slice;
  final List<double> sorted = List<double>.of(rms)..sort();
  final double floor = sorted[(sorted.length * 0.1).floor()];
  final double peak = sorted.last;
  if (peak <= 0) return slice;
  final double threshold = math.max(floor * kGalVoiceTailActiveRatio, 1e-4);
  if (threshold >= peak) return slice;
  int lastActive = -1;
  for (int i = rms.length - 1; i >= 0; i--) {
    if (rms[i] > threshold) {
      lastActive = i;
      break;
    }
  }
  if (lastActive < 0) return slice;
  final int quietMs = (rms.length - 1 - lastActive) * kGalVoiceTailFrameMs;
  if (quietMs < kGalVoiceTailMinQuietMs) return slice;
  final int keepMs =
      (lastActive + 1) * kGalVoiceTailFrameMs + kGalVoiceTailPadMs;
  final int totalMs = slice.pcm.length * 1000 ~/ slice.format.byteRate;
  return dropPcmTailMs(slice, totalMs - keepMs);
}
