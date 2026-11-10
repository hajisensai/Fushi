/// 音乐播放器上的「只播 [start, end) 这一段」（高级制卡试听句子音频，反馈 l8XrV_IfXH）。
///
/// 与视频 `playRangeMs` / 有声书 `playRange` 同一份契约：起播后交回 [RangePlayback]，
/// 它在这段**播完或被打断**时完成一次。结束只由引擎的真实事件判定（位置越过终点 /
/// 换曲 / 被暂停 / 显式 [MusicRangePreview.stop]），不按时长估算。
///
/// A-B 循环会把播放头拽回循环起点：试听前撤下循环、试听收尾后恢复由歌词页负责（循环
/// 状态归歌词页所有，见 `_MusicLyricsPageState`），本类只管这一段的起停。
library;

import 'dart:async';

import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/range_playback.dart';

class MusicRangePreview {
  MusicRangePreview(this._engine);

  final MusicPlayerEngine _engine;

  RangePlayback? _active;
  Duration _end = Duration.zero;
  String? _trackUid;
  bool _listening = false;

  /// 是否有一段试听正在播（还没结束）。
  bool get active => _active != null && !_active!.isEnded;

  /// 从 [start] 播到 [end]。上一段还在播时先按「被顶掉」结束它。当前没有曲目、不能
  /// 拖动（直播电台）或区间为空时返回一个已结束的句柄（[RangePlaybackEnd.interrupted]），
  /// 不碰播放器。
  Future<RangePlayback> play(Duration start, Duration end) async {
    _finish(RangePlaybackEnd.interrupted);
    if (_engine.current == null || !_engine.canSeek || end <= start) {
      return RangePlayback.ended(RangePlaybackEnd.interrupted);
    }
    final RangePlayback playback = RangePlayback();
    _active = playback;
    _end = end;
    _trackUid = _engine.current?.trackUid;
    await _engine.seek(start);
    if (!identical(_active, playback)) return playback;
    await _engine.play();
    if (!identical(_active, playback)) return playback;
    if (!_engine.isPlaying || _engine.current?.trackUid != _trackUid) {
      // 起播失败（后端重开失败 / 换曲）：如实结束，不留一个永远不完成的句柄。
      _finish(RangePlaybackEnd.interrupted);
      return playback;
    }
    _engine.addListener(_onEngine);
    _listening = true;
    // seek / play 之间位置已经越过终点（极短区间）：立刻按播完收尾。
    _onEngine();
    return playback;
  }

  /// 停下正在播的那段（暂停播放器，句柄按「被打断」结束）。没有在播的试听时什么都不做。
  Future<void> stop() async {
    if (!active) return;
    _finish(RangePlaybackEnd.interrupted);
    if (_engine.isPlaying) await _engine.pause();
  }

  void _onEngine() {
    final RangePlayback? playback = _active;
    if (playback == null || playback.isEnded) return;
    if (_engine.current?.trackUid != _trackUid) {
      _finish(RangePlaybackEnd.interrupted);
      return;
    }
    if (_engine.position >= _end) {
      _finish(RangePlaybackEnd.reachedEnd);
      unawaited(_engine.pause());
      return;
    }
    if (!_engine.isPlaying) {
      // 被别处暂停（系统媒体键 / 耳机拔出 / 曲目播完）。
      _finish(RangePlaybackEnd.interrupted);
    }
  }

  void _finish(RangePlaybackEnd reason) {
    final RangePlayback? playback = _active;
    _active = null;
    if (_listening) {
      _listening = false;
      _engine.removeListener(_onEngine);
    }
    playback?.finish(reason);
  }

  /// 页面销毁：结束句柄、摘监听，不碰播放器（音乐在页面外照常播）。
  void dispose() => _finish(RangePlaybackEnd.interrupted);
}
