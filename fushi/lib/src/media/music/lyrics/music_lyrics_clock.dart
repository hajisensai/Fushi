/// 歌词渲染用的本地插值时钟（设计 §4.1「逐帧渲染不跨 FFI」）：引擎的位置事件只有每秒
/// 若干次，逐字擦色需要每帧一个连续时间——在两次事件之间按墙钟外推，暂停时停住。
library;

import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;

/// 外推一次最多补这么久（事件流卡住时不让歌词一路跑飞）。
const Duration kMusicLyricsClockMaxExtrapolation = Duration(seconds: 2);

/// 纯函数：从「上次事件的位置 + 距今墙钟」外推当前位置。
Duration extrapolateMusicPosition({
  required Duration lastPosition,
  required Duration sinceLastEvent,
  required bool playing,
  Duration? duration,
  Duration maxExtrapolation = kMusicLyricsClockMaxExtrapolation,
}) {
  if (!playing) return lastPosition;
  final Duration step = sinceLastEvent < Duration.zero
      ? Duration.zero
      : (sinceLastEvent > maxExtrapolation ? maxExtrapolation : sinceLastEvent);
  final Duration p = lastPosition + step;
  if (duration != null && duration > Duration.zero && p > duration) {
    return duration;
  }
  return p;
}

/// 监听 [MusicPlayerEngine] 的插值时钟。用完调 [dispose]。
class MusicLyricsClock implements FushiPlaybackClock {
  MusicLyricsClock(this._engine, {Stopwatch? stopwatch})
    : _watch = stopwatch ?? Stopwatch() {
    _watch.start();
    _sync();
    _engine.addListener(_sync);
  }

  final MusicPlayerEngine _engine;
  final Stopwatch _watch;
  Duration _last = Duration.zero;
  Duration _lastAt = Duration.zero;
  Duration? _seenEnginePosition;
  bool _seenPlaying = false;

  /// 引擎每次 notify 都可能只是别的状态变了（队列、错误）：只有位置真变了才以它为新基准，
  /// 否则基准被反复重置成同一个旧位置，显示时间会周期性往回跳。从播放变暂停时把外推值
  /// 定格成基准，避免暂停瞬间回退到上一次事件的位置。
  void _sync() {
    final Duration enginePos = _engine.position;
    final bool playing = _engine.isPlaying;
    if (enginePos != _seenEnginePosition) {
      _last = enginePos;
      _lastAt = _watch.elapsed;
    } else if (_seenPlaying && !playing) {
      _last = extrapolateMusicPosition(
        lastPosition: _last,
        sinceLastEvent: _watch.elapsed - _lastAt,
        playing: true,
        duration: _engine.duration,
      );
      _lastAt = _watch.elapsed;
    } else if (!_seenPlaying && playing) {
      _lastAt = _watch.elapsed;
    }
    _seenEnginePosition = enginePos;
    _seenPlaying = playing;
  }

  @override
  Duration get position => extrapolateMusicPosition(
    lastPosition: _last,
    sinceLastEvent: _watch.elapsed - _lastAt,
    playing: _engine.isPlaying,
    duration: _engine.duration,
  );

  @override
  Duration get duration => _engine.duration ?? Duration.zero;

  void dispose() => _engine.removeListener(_sync);
}
