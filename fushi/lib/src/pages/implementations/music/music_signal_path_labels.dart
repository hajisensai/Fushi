/// 信号通路规格的纯文字格式化（无 i18n、无状态）：信号通路面板与音质快切共用。
///
/// 单独成文件、只依赖值类型：音质快切若为这几个函数 import 读 `AppModel` 的信号通路
/// 面板，会被拖进 `lib/` 的最大 import 环（`import_cycle_guard_test`）。
library;

import 'package:fushi/src/media/music/music_signal_path.dart';

/// 纯函数：采样率（Hz）→ `96 kHz` / `44.1 kHz`。
String musicKhzLabel(int hz) {
  final double k = hz / 1000;
  return k == k.roundToDouble()
      ? '${k.round()} kHz'
      : '${k.toStringAsFixed(1)} kHz';
}

/// 纯函数：mpv 格式 → 一行（`s32 · 96 kHz · stereo`）。
String musicAudioFormatLabel(MusicAudioFormat f) =>
    '${f.packedFormat} · ${musicKhzLabel(f.sampleRate)} · ${f.channels ?? '${f.channelCount} ch'}';

/// 纯函数：源一行（容器 / 编码 / 采样率 / 位深 / 声道 / 码率），缺的项不写。
String musicSourceLabel(MusicSignalPathSnapshot s) => <String>[
  if (s.codecDescription != null || s.codec != null)
    (s.codec ?? s.codecDescription)!,
  if (s.fileFormat != null) s.fileFormat!,
  if (s.sourceSampleRate != null) musicKhzLabel(s.sourceSampleRate!),
  if (s.sourceBitDepth != null) '${s.sourceBitDepth} bit',
  if (s.sourceChannelCount != null) '${s.sourceChannelCount} ch',
  if (s.bitrate != null && s.bitrate! > 0)
    '${(s.bitrate! / 1000).round()} kbps',
].join(' · ');
