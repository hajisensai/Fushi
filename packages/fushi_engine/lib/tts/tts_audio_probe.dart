/// 合成产物的容器校验与时长探测（纯 Dart，不起 ffprobe）。
///
/// cue 时间轴直接取这里的时长，所以只信解析得出的数据：头不完整、数据区为空、
/// MP3 一帧都找不到一律当坏文件（返回 null），由缓存层丢弃重合成。
library;

import 'dart:typed_data';

import 'package:fushi_engine/tts/tts_types.dart';

/// 按内容判断容器格式（不信扩展名 / Content-Type）。
TtsAudioFormat? sniffTtsAudioFormat(Uint8List bytes) {
  if (bytes.length >= 12 &&
      _ascii(bytes, 0, 4) == 'RIFF' &&
      _ascii(bytes, 8, 4) == 'WAVE') {
    return TtsAudioFormat.wav;
  }
  if (bytes.length >= 3 && _ascii(bytes, 0, 3) == 'ID3') {
    return TtsAudioFormat.mp3;
  }
  if (bytes.length >= 2 && bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0) {
    return TtsAudioFormat.mp3;
  }
  return null;
}

/// 时长（毫秒）。坏文件返回 null。
int? probeTtsAudioDurationMs(Uint8List bytes, TtsAudioFormat format) =>
    switch (format) {
      TtsAudioFormat.wav => _wavDurationMs(bytes),
      TtsAudioFormat.mp3 => _mp3DurationMs(bytes),
    };

String _ascii(Uint8List b, int start, int length) =>
    String.fromCharCodes(b.sublist(start, start + length));

int? _wavDurationMs(Uint8List bytes) {
  if (sniffTtsAudioFormat(bytes) != TtsAudioFormat.wav) return null;
  final ByteData data = ByteData.sublistView(bytes);
  int? byteRate;
  int offset = 12;
  while (offset + 8 <= bytes.length) {
    final String id = _ascii(bytes, offset, 4);
    int size = data.getUint32(offset + 4, Endian.little);
    final int body = offset + 8;
    if (id == 'fmt ') {
      if (body + 16 > bytes.length) return null;
      byteRate = data.getUint32(body + 8, Endian.little);
    } else if (id == 'data') {
      if (byteRate == null || byteRate <= 0) return null;
      // 流式写出的 WAV 常把 data 长度写成 0 或 0xFFFFFFFF：按实际剩余字节算。
      final int available = bytes.length - body;
      if (size == 0 || size > available) size = available;
      if (size <= 0) return null;
      return (size * 1000 / byteRate).round();
    }
    offset = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

const List<int> _mpeg1L3Kbps = <int>[
  0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 0, //
];
const List<int> _mpeg2L3Kbps = <int>[
  0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160, 0, //
];

int? _mp3DurationMs(Uint8List bytes) {
  int offset = 0;
  if (bytes.length >= 10 && _ascii(bytes, 0, 3) == 'ID3') {
    final int size =
        (bytes[6] & 0x7F) << 21 |
        (bytes[7] & 0x7F) << 14 |
        (bytes[8] & 0x7F) << 7 |
        (bytes[9] & 0x7F);
    offset = 10 + size;
  }
  int frames = 0;
  double seconds = 0;
  while (offset + 4 <= bytes.length) {
    final int b1 = bytes[offset + 1], b2 = bytes[offset + 2];
    if (bytes[offset] != 0xFF || (b1 & 0xE0) != 0xE0) {
      offset++;
      continue;
    }
    final int version = (b1 >> 3) & 0x3; // 3 = MPEG1, 2 = MPEG2, 0 = MPEG2.5
    final int layer = (b1 >> 1) & 0x3; // 1 = Layer III
    final int bitrateIndex = (b2 >> 4) & 0xF;
    final int rateIndex = (b2 >> 2) & 0x3;
    final int padding = (b2 >> 1) & 0x1;
    if (version == 1 || layer != 1 || rateIndex == 3) {
      offset++;
      continue;
    }
    final bool mpeg1 = version == 3;
    final int kbps = (mpeg1 ? _mpeg1L3Kbps : _mpeg2L3Kbps)[bitrateIndex];
    if (kbps == 0) {
      offset++;
      continue;
    }
    const List<int> baseRates = <int>[44100, 48000, 32000];
    final int sampleRate =
        baseRates[rateIndex] ~/ (mpeg1 ? 1 : (version == 2 ? 2 : 4));
    final int samplesPerFrame = mpeg1 ? 1152 : 576;
    final int frameLength =
        (samplesPerFrame ~/ 8) * kbps * 1000 ~/ sampleRate + padding;
    if (frameLength <= 4) {
      offset++;
      continue;
    }
    frames++;
    seconds += samplesPerFrame / sampleRate;
    offset += frameLength;
  }
  if (frames == 0) return null;
  return (seconds * 1000).round();
}
