/// 漫画有声播放用的静音文件（页停留 / `lead` / 句间停顿）。
///
/// 为什么是文件而不是 just_audio 的 `SilenceAudioSource`：桌面后端
/// （just_audio_media_kit）与 iOS（AVQueuePlayer）都不实现它，只有 Android 认。
/// 静音按时长去重（同一个时长只写一个文件、播放列表里重复引用），放在成品目录下的
/// 子目录里，随成品一起删；成品音频本身不改（设计 §2：静音不烘焙进音频）。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

/// 静音 WAV 的采样率：8 kHz 单声道 16 位，1 秒 16 KB。三个平台的解码器都认。
const int kMangaSilenceSampleRate = 8000;

/// 成品目录下放静音文件的子目录名。
const String kMangaSilenceDirName = '.playback_silence';

/// [durationMs] 毫秒静音的 PCM WAV 字节。
Uint8List mangaSilenceWavBytes(int durationMs) {
  final int samples = (kMangaSilenceSampleRate * durationMs / 1000).round();
  final int dataBytes = samples * 2;
  final ByteData b = ByteData(44 + dataBytes);
  void ascii(int offset, String s) {
    for (int i = 0; i < s.length; i++) {
      b.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  b.setUint32(4, 36 + dataBytes, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, kMangaSilenceSampleRate, Endian.little);
  b.setUint32(28, kMangaSilenceSampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  b.setUint32(40, dataBytes, Endian.little);
  return b.buffer.asUint8List();
}

/// [manifestDir] 下 [durationMs] 毫秒静音文件的路径（不保证已存在）。
String mangaSilencePath(String manifestDir, int durationMs) =>
    p.join(manifestDir, kMangaSilenceDirName, 'silence_$durationMs.wav');

/// 保证 [durations] 里每个时长都有静音文件（已有且大小对的不重写）。
Future<void> ensureMangaSilenceFiles(
  String manifestDir,
  Iterable<int> durations,
) async {
  final Directory dir = Directory(p.join(manifestDir, kMangaSilenceDirName));
  await dir.create(recursive: true);
  for (final int ms in durations) {
    if (ms <= 0) continue;
    final File f = File(mangaSilencePath(manifestDir, ms));
    final Uint8List bytes = mangaSilenceWavBytes(ms);
    if (await f.exists() && await f.length() == bytes.length) continue;
    final File tmp = File('${f.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(f.path);
  }
}
