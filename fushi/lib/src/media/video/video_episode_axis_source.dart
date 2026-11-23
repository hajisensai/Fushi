import 'package:flutter/foundation.dart';
import 'package:fushi_audio/fushi_audio.dart';

import 'package:fushi/src/media/video/video_playback_source.dart';

/// 「原盘分集时间轴」上的播放源视图（BUG-5340）：播放器播的是一条被扫描切成集的
/// 整条播放列表（原盘菜单「全部播放」），库身份却是其中一集——这一集在播放列表上
/// 占 `[startMs, startMs + lengthMs)`。把位置 / 时长 / 当前句都平移到这一集自己的
/// 时间轴上，[VideoWatchTracker] 的完成判定（按集长 90%）、覆盖并集（按集键存）、
/// 字幕停留量就与直接打开这一集时同一根轴。
///
/// 区间在构造时定死：播放头跨进下一集时宿主按新身份另建采集器与新视图，旧采集器
/// 离开时的最后一次采样仍按旧集的区间算（越过集尾夹成集长 = 看完），不会被新集的
/// 偏移改写。位置夹在 `[0, lengthMs]` 内：换身份前后那一两秒里的越界位置不并进
/// 这一集的覆盖并集之外。
class EpisodeAxisPlaybackSource implements VideoPlaybackSource {
  EpisodeAxisPlaybackSource(
    this._inner, {
    required this.startMs,
    required this.lengthMs,
  }) : assert(lengthMs > 0, '分集区间长度必须为正');

  final VideoPlaybackSource _inner;

  /// 这一集在播放列表时间轴上的起点（毫秒）。
  final int startMs;

  /// 这一集的长度（毫秒）。
  final int lengthMs;

  /// 当前句的平移副本（按原句身份缓存，同一句不反复分配）。
  AudioCue? _cueSource;
  AudioCue? _cueShifted;

  /// 播放列表时间轴上的 [playlistMs] 在这一集时间轴上的位置（夹在集长内）。
  int toEpisodeMs(int playlistMs) {
    final int relative = playlistMs - startMs;
    return relative < 0 ? 0 : (relative > lengthMs ? lengthMs : relative);
  }

  @override
  bool get isPlaying => _inner.isPlaying;

  @override
  int get currentCueIndex => _inner.currentCueIndex;

  @override
  AudioCue? get currentCue {
    final AudioCue? cue = _inner.currentCue;
    if (cue == null) return null;
    if (identical(cue, _cueSource)) return _cueShifted;
    _cueSource = cue;
    return _cueShifted = shiftAudioCue(cue, -startMs);
  }

  @override
  int? get positionMs {
    final int? position = _inner.positionMs;
    return position == null ? null : toEpisodeMs(position);
  }

  @override
  int get subtitleDelayMs => _inner.subtitleDelayMs;

  @override
  int? get durationMs => lengthMs;

  @override
  double get speed => _inner.speed;

  @override
  void addListener(VoidCallback listener) => _inner.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _inner.removeListener(listener);
}

/// 给 [VideoWatchTracker] 用的 [cue] 平移 [deltaMs] 副本：只带停留门 / 去重 / 覆盖
/// 比对读的文本与起止（同 `BrowserVideoCue.toAudioCue`）。字幕解析出的 cue 未必填全
/// 每个 `late` 字段，逐字段照抄会撞未初始化。
AudioCue shiftAudioCue(AudioCue cue, int deltaMs) => AudioCue()
  ..bookKey = ''
  ..chapterHref = ''
  ..sentenceIndex = 0
  ..textFragmentId = ''
  ..text = cue.text
  ..startMs = cue.startMs + deltaMs
  ..endMs = cue.endMs + deltaMs
  ..audioFileIndex = 0;
