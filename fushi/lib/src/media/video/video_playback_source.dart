import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// 视频播放只读视图，供 [VideoWatchTracker] 采集统计用。抽成接口让 tracker
/// 不直接依赖 media_kit 的 `VideoPlayerController`（其状态读 libmpv player，
/// 测试宿主无法实例化），从而可用 fake 纯单测采集逻辑。
abstract interface class VideoPlaybackSource implements Listenable {
  /// 是否正在播放（暂停 / 未 load 为 false）。观看时长仅在播放时累加。
  bool get isPlaying;

  /// 当前字幕 cue 下标（-1 = 无 / gap）。
  int get currentCueIndex;

  /// 当前字幕 cue（null = 无）。
  AudioCue? get currentCue;

  /// 当前播放位置（毫秒，视频时间轴）；未 load 为 null。
  int? get positionMs;

  /// 主字幕调轴（毫秒；正值 = 字幕延后显示）。[currentCue] 的起止时刻在**字幕
  /// 时间轴**上，`positionMs - subtitleDelayMs` 才是同一根轴上的位置（与播放器求
  /// 当前 cue 用的 `effectiveSubtitlePositionMs` 同一换算）。外挂字幕最常调轴，
  /// 混用两根轴会让停留量恒为 0、字幕字数永远计不上（9rdFBLEnVg）。
  int get subtitleDelayMs;

  /// 媒体总时长（毫秒）；未 load / 未解析媒体头时为 null 或 0。
  int? get durationMs;

  /// 播放倍速（1.0 = 原速）。tracker 用它判「位置推进是连续播放还是 seek 跳变」：
  /// 一个采样间隔里媒体时间最多前进 墙钟 × 倍速（+ 余量），超出即跳变、不算看过。
  double get speed;
}
