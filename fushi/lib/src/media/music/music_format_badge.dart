/// 专辑 / 曲目的格式徽章（设计 §11.2：`FLAC 24/96`、`DSD64`、`Hi-Res`）。纯函数。
library;

/// 显示用的编码名。
String musicCodecLabel(String? codec) => switch (codec) {
  null || '' || 'unknown' => '',
  'flac' => 'FLAC',
  'alac' => 'ALAC',
  'ape' => 'APE',
  'wavpack' => 'WavPack',
  'tak' => 'TAK',
  'tta' => 'TTA',
  'pcm' => 'PCM',
  'dsd' => 'DSD',
  'mp3' => 'MP3',
  'aac' => 'AAC',
  'opus' => 'Opus',
  'vorbis' => 'Vorbis',
  'musepack' => 'Musepack',
  final String other => other.toUpperCase(),
};

/// `44100` → `44.1`，`96000` → `96`。
String _khz(int sampleRate) {
  final double k = sampleRate / 1000;
  return k == k.roundToDouble() ? k.toStringAsFixed(0) : k.toStringAsFixed(1);
}

/// 主徽章：
/// - DSD：按 44.1 kHz 的倍数报 `DSD64` / `DSD128` …；
/// - 其它无损：`FLAC 24/96`（缺位深或采样率时只报编码名）；
/// - 有损：`MP3 320k`（缺码率只报编码名）。
String musicFormatBadge({
  required String? codec,
  required bool isLossless,
  int? sampleRate,
  int? bitDepth,
  int? bitrateKbps,
}) {
  final String name = musicCodecLabel(codec);
  if (codec == 'dsd' && sampleRate != null && sampleRate > 0) {
    return 'DSD${(sampleRate / 44100).round()}';
  }
  if (isLossless) {
    if (sampleRate != null &&
        sampleRate > 0 &&
        bitDepth != null &&
        bitDepth > 0) {
      return '$name $bitDepth/${_khz(sampleRate)}'.trim();
    }
    return name;
  }
  if (bitrateKbps != null && bitrateKbps > 0) {
    return '$name ${bitrateKbps}k'.trim();
  }
  return name;
}

/// 是否标「Hi-Res」：无损且位深 ≥ 24 或采样率 > 48 kHz（JAS / 日本音频协会口径）。
/// DSD 一律算。
bool musicIsHiRes({
  required String? codec,
  required bool isLossless,
  int? sampleRate,
  int? bitDepth,
}) {
  if (codec == 'dsd') return true;
  if (!isLossless) return false;
  return (bitDepth ?? 0) >= 24 || (sampleRate ?? 0) > 48000;
}
