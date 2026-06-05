import 'package:flutter/foundation.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

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

  /// 当前播放位置（毫秒）；未 load 为 null。
  int? get positionMs;

  /// 媒体总时长（毫秒）；未 load / 未解析媒体头时为 null 或 0。
  int? get durationMs;
}
