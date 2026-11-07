/// 「查词时暂停」在歌词页之外的生效点（桌面歌词点词查词）。
///
/// 规则与歌词页 `_onLookup` / `clearDictionaryResult` 同口径：设置开着且正在播才暂停；
/// 只有这次暂停是查词造成的，关卡时才恢复播放。额外一条：查词卡开着期间用户自己
/// 恢复了播放，就不再归本类管（之后用户再暂停，关卡也不替用户续播）。
library;

import 'package:flutter/foundation.dart';

class MusicLookupPause {
  MusicLookupPause({
    required Listenable playback,
    required bool Function() isPlaying,
    required Future<void> Function() play,
    required Future<void> Function() pause,
    required bool Function() settingEnabled,
  }) : _playback = playback,
       _isPlaying = isPlaying,
       _play = play,
       _pause = pause,
       _settingEnabled = settingEnabled,
       _wasPlaying = isPlaying() {
    _playback.addListener(_onPlaybackChanged);
  }

  final Listenable _playback;
  final bool Function() _isPlaying;
  final Future<void> Function() _play;
  final Future<void> Function() _pause;
  final bool Function() _settingEnabled;

  bool _wasPlaying;
  bool _pausedForLookup = false;

  /// 这次暂停是否由查词造成（关卡时据此决定要不要续播）。
  bool get pausedForLookup => _pausedForLookup;

  /// 一张查词卡已经弹出（或正在弹出）。
  void lookupStarted() {
    if (_pausedForLookup) return;
    if (!_settingEnabled() || !_isPlaying()) return;
    _pausedForLookup = true;
    _pause().ignore();
  }

  /// 用户关掉了查词卡。
  void lookupClosed() {
    if (!_pausedForLookup) return;
    _pausedForLookup = false;
    _play().ignore();
  }

  void _onPlaybackChanged() {
    final bool playing = _isPlaying();
    // 停 → 播的跳变只可能来自外部（本类暂停后在 lookupClosed 里先清标志再 play）。
    if (playing && !_wasPlaying) _pausedForLookup = false;
    _wasPlaying = playing;
  }

  void dispose() {
    _playback.removeListener(_onPlaybackChanged);
  }
}
