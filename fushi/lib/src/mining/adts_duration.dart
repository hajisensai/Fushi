import 'dart:typed_data';

/// AAC ADTS 裸流（桌面制卡的 `.aac` 输出）的播放时长，毫秒；不是 ADTS 或帧头
/// 损坏时返回 null（调用方按「时长未知」处理，绝不猜）。
///
/// 只走帧头：每个 ADTS 帧固定 1024 个 PCM 采样（AAC-LC；HE-AAC 的 SBR 倍增这里
/// 不认——桌面 ffmpeg 编出的制卡音频是 AAC-LC，见 `pcmSliceToAacBytes`），
/// 采样率取帧头的 sampling_frequency_index。纯 Dart、O(帧数)，不起 ffprobe 子进程：
/// 制卡链路里它只用来决定动图该抓多长，不值得再拉一个进程。
int? adtsDurationMs(Uint8List bytes) {
  if (bytes.length < 7) return null;
  int offset = 0;
  int frames = 0;
  int? sampleRate;
  while (offset + 7 <= bytes.length) {
    // syncword 0xFFF（12 位）。
    if (bytes[offset] != 0xFF || (bytes[offset + 1] & 0xF0) != 0xF0) {
      return null;
    }
    final int frequencyIndex = (bytes[offset + 2] >> 2) & 0x0F;
    final int rate = _adtsSampleRates[frequencyIndex];
    if (rate == 0) return null;
    sampleRate ??= rate;
    final int frameLength = ((bytes[offset + 3] & 0x03) << 11) |
        (bytes[offset + 4] << 3) |
        ((bytes[offset + 5] & 0xE0) >> 5);
    if (frameLength < 7) return null;
    // 尾部被截断的最后一帧不计：它播不出完整的 1024 采样。
    if (offset + frameLength > bytes.length) break;
    frames++;
    offset += frameLength;
  }
  if (frames == 0 || sampleRate == null) return null;
  return (frames * 1024 * 1000) ~/ sampleRate;
}

/// ADTS `sampling_frequency_index` → Hz；13/14/15 保留值记 0。
const List<int> _adtsSampleRates = <int>[
  96000,
  88200,
  64000,
  48000,
  44100,
  32000,
  24000,
  22050,
  16000,
  12000,
  11025,
  8000,
  7350,
  0,
  0,
  0,
];
