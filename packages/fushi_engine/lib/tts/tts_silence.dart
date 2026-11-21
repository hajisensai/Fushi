/// 没有要念的内容时的静音：纯标点句判定与静音 WAV（制作、朗读、漫画共用）。
library;

import 'dart:typed_data';

/// 能念出声的字符：标点、符号、空白、控制 / 格式字符、附加符号以外的一切（字母、
/// 假名、汉字、数字……）。附加符号（\p{M}）单独念不出声，而且要排除：emoji / 符号
/// 后的变体选择符（「❤️」= U+2764 U+FE0F、「♪︎」）属于 \p{Mn}，不排除会把纯符号句
/// 当成有字可念送进引擎。
final RegExp _speakable = RegExp(
  r'[^\p{P}\p{S}\p{Z}\p{C}\p{M}]',
  unicode: true,
);

/// 这句没有任何能念的字（「！」「……」「♪」这类纯标点 / 符号句）：不送引擎（有的引擎
/// 直接 400 拒收，送了也只会得到空白），按一段停顿处理，也不算「没配上」——它本来
/// 就没有要念的内容。
bool ttsTextIsSilent(String text) => !_speakable.hasMatch(text);

/// 纯标点句在朗读里用的静音 WAV 采样率（单声道）。
const int kTtsSilentLineSampleRate = 24000;

/// [ms] 毫秒的 16-bit PCM 静音 WAV。
Uint8List buildTtsSilenceWav({
  required int ms,
  required int sampleRate,
  required int channels,
}) {
  final int frames = (sampleRate * ms / 1000).round();
  final int dataBytes = frames * channels * 2;
  final ByteData b = ByteData(44 + dataBytes);
  void ascii(int at, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little);
  b.setUint16(22, channels, Endian.little);
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * channels * 2, Endian.little);
  b.setUint16(32, channels * 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}
