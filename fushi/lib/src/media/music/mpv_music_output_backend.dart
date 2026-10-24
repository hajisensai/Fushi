/// libmpv 输出后端（设计 §4.2 / §7）：音乐专用的独立 [Player] 实例，`vo=null` 纯音频，
/// 不与视频页抢同一个 mpv。播放列表恒为「当前 + 下一首」两项，`gapless-audio=weak` +
/// `prefetch-playlist=yes` 让同格式曲目真无缝；ReplayGain 交给 mpv 读标签
/// （`replaygain=album|track`，`replaygain-clip=no`）。
///
/// CUE 虚拟曲目用 mpv 的逐文件 `start` / `end` 选项（media_kit [Media] 的 start / end），
/// 上报位置时减去曲目起点、seek 时加回，所以对引擎来说每首都从 0 开始。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:media_kit/media_kit.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';

/// 纯函数：一首曲目 → mpv 的 [Media]（CUE 起止作为逐文件选项）。
Media musicMediaOf(MusicPlayItem item) => Media(
  item.path,
  start: item.startMs == null ? null : Duration(milliseconds: item.startMs!),
  end: item.endMs == null ? null : Duration(milliseconds: item.endMs!),
);

/// 纯函数：输出设置 → 要下发的 mpv 属性。
Map<String, String> musicMpvProperties(MusicOutputSettings settings) =>
    <String, String>{
      'gapless-audio': settings.gapless ? 'weak' : 'no',
      'prefetch-playlist': settings.gapless ? 'yes' : 'no',
      'replaygain': settings.replayGain.mpvValue,
      'replaygain-clip': 'no',
      'replaygain-preamp': settings.replayGainPreampDb.toStringAsFixed(2),
      // 纯音频实例：没有画面，也不要封面当视频轨解码。
      'audio-display': 'no',
    };

class MpvMusicOutputBackend implements MusicOutputBackend {
  /// [initialProperties] 在第一次下发设置前写一次（测试用 `ao=null` 免得真出声）。
  MpvMusicOutputBackend({
    PlayerConfiguration configuration = const PlayerConfiguration(
      vo: 'null',
      title: 'Fushi Music',
    ),
    Map<String, String> initialProperties = const <String, String>{},
  }) : _player = Player(configuration: configuration),
       _initialProperties = initialProperties {
    _subs.add(_player.stream.position.listen(_onPosition));
    _subs.add(
      _player.stream.playing.listen(
        (bool p) => _events.add(MusicBackendPlaying(p)),
      ),
    );
    _subs.add(_player.stream.playlist.listen(_onPlaylist));
    _subs.add(
      _player.stream.completed.listen((bool done) {
        if (done && _next == null) _events.add(const MusicBackendCompleted());
      }),
    );
    _subs.add(
      _player.stream.error.listen(
        (String e) => _events.add(MusicBackendFailed(e)),
      ),
    );
  }

  final Player _player;
  final Map<String, String> _initialProperties;
  bool _initialised = false;

  /// 底层 mpv 播放器（测试读属性 / 日志用）。
  @visibleForTesting
  Player get debugPlayer => _player;
  final StreamController<MusicBackendEvent> _events =
      StreamController<MusicBackendEvent>.broadcast();
  final List<StreamSubscription<Object?>> _subs =
      <StreamSubscription<Object?>>[];

  MusicPlayItem? _current;
  MusicPlayItem? _next;

  /// 我们自己发起的播放列表变更期间不把 index 变化当成「无缝推进」。
  bool _rewiring = false;
  int _lastIndex = 0;

  @override
  Stream<MusicBackendEvent> get events => _events.stream;

  NativePlayer? get _native => _player.platform is NativePlayer
      ? _player.platform! as NativePlayer
      : null;

  Future<void> _ensureInitialised() async {
    if (_initialised) return;
    _initialised = true;
    final NativePlayer? native = _native;
    if (native == null) return;
    for (final MapEntry<String, String> e in _initialProperties.entries) {
      await native.setProperty(e.key, e.value);
    }
  }

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {
    await _ensureInitialised();
    final NativePlayer? native = _native;
    if (native == null) return;
    for (final MapEntry<String, String> e in musicMpvProperties(
      settings,
    ).entries) {
      await native.setProperty(e.key, e.value);
    }
  }

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
  }) async {
    await _ensureInitialised();
    _rewiring = true;
    try {
      _current = current;
      _next = next;
      _lastIndex = 0;
      await _player.open(
        Playlist(<Media>[
          musicMediaOf(current),
          if (next != null) musicMediaOf(next),
        ]),
        play: play,
      );
    } finally {
      _rewiring = false;
    }
  }

  @override
  Future<void> replaceNext(MusicPlayItem? next) async {
    _rewiring = true;
    try {
      final int count = _player.state.playlist.medias.length;
      final int index = _player.state.playlist.index;
      // 已播完的前项与旧的「下一首」都移掉，只留正在播的那一项。
      for (int i = count - 1; i > index; i--) {
        await _player.remove(i);
      }
      for (int i = index - 1; i >= 0; i--) {
        await _player.remove(i);
      }
      _lastIndex = 0;
      _next = next;
      if (next != null) await _player.add(musicMediaOf(next));
    } finally {
      _rewiring = false;
    }
  }

  void _onPlaylist(Playlist playlist) {
    if (_rewiring) {
      _lastIndex = playlist.index;
      return;
    }
    if (playlist.index > _lastIndex && _next != null) {
      _current = _next;
      _next = null;
      _lastIndex = playlist.index;
      _events.add(const MusicBackendAdvanced());
      return;
    }
    _lastIndex = playlist.index;
  }

  void _onPosition(Duration absolute) {
    final MusicPlayItem? item = _current;
    final int startMs = item?.startMs ?? 0;
    final Duration relative = absolute - Duration(milliseconds: startMs);
    final Duration? duration = item?.durationMs == null
        ? (_player.state.duration > Duration.zero
              ? _player.state.duration - Duration(milliseconds: startMs)
              : null)
        : Duration(milliseconds: item!.durationMs!);
    _events.add(
      MusicBackendPosition(
        relative < Duration.zero ? Duration.zero : relative,
        duration,
      ),
    );
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) =>
      _player.seek(position + Duration(milliseconds: _current?.startMs ?? 0));

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> dispose() async {
    for (final StreamSubscription<Object?> s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    await _events.close();
    await _player.dispose();
  }
}
