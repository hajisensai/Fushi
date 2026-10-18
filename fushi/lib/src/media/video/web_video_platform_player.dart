// 网页视频的 media_kit 播放器后端：原生播放器页 / 控制条原封不动地跑在网页站点的
// <video> 上。画面由垫在 Flutter 下面的 WebView2 子窗口自己画（底层合成），所以它是
// [ExternallyRenderedPlatformPlayer]——VideoController 不为它建纹理、不要 mpv 句柄。
//
// 状态：页面 glue 每 ~250 ms 上报一次（[applySnapshot]），播放中按倍速外推位置，
// 进度条不一跳一跳。动作：play / pause / seek / rate / volume 转成页面 JS 命令
// （[evaluate]），先乐观更新状态让按钮即时响应，下一次上报再校正。
import 'dart:async';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show ExternallyRenderedPlatformPlayer;

import 'package:fushi/src/media/video/web_video_bridge.dart';

class WebVideoPlatformPlayer extends PlatformPlayer
    implements ExternallyRenderedPlatformPlayer {
  WebVideoPlatformPlayer({required this.evaluate})
    : super(configuration: const PlayerConfiguration());

  /// 在站点页面里执行一条 `window.__fushiWebVideo.*` 命令。
  final Future<void> Function(String js) evaluate;

  /// 外推时钟的基准：最近一次权威位置与它的时刻。
  Duration _anchor = Duration.zero;
  final Stopwatch _sinceAnchor = Stopwatch();
  Timer? _ticker;
  bool _disposed = false;

  /// 页面上报一次播放状态。[volume] 0–1；[buffering] 来自 readyState / seeking。
  void applySnapshot(
    WebVideoPlaybackState s, {
    double? volume,
    bool? muted,
    bool buffering = false,
  }) {
    if (_disposed) return;
    final Duration position = Duration(milliseconds: s.positionMs ?? 0);
    final Duration duration = Duration(milliseconds: s.durationMs ?? 0);
    final bool playing = s.hasVideo && !s.paused;
    _anchor = position;
    _sinceAnchor
      ..reset()
      ..start();
    _setPosition(position);
    if (state.duration != duration) {
      state = state.copyWith(duration: duration);
      _add(durationController, duration);
    }
    _setPlaying(playing);
    if ((state.rate - s.rate).abs() > 0.001) {
      state = state.copyWith(rate: s.rate);
      _add(rateController, s.rate);
    }
    if (volume != null) {
      final double v = (muted ?? false) ? 0 : (volume * 100).clamp(0, 100);
      if ((state.volume - v).abs() > 0.01) {
        state = state.copyWith(volume: v);
        _add(volumeController, v);
      }
    }
    if (state.buffering != buffering) {
      state = state.copyWith(buffering: buffering);
      _add(bufferingController, buffering);
    }
    _setSize(s.videoWidth, s.videoHeight);
    final bool completed =
        s.hasVideo &&
        s.paused &&
        duration > Duration.zero &&
        position >= duration - const Duration(milliseconds: 500);
    if (state.completed != completed) {
      state = state.copyWith(completed: completed);
      _add(completedController, completed);
    }
  }

  void _setPosition(Duration p) {
    state = state.copyWith(position: p);
    _add(positionController, p);
    // 页面没有可靠的缓冲区间：缓冲进度跟着播放位置走（进度条不画假缓冲）。
    state = state.copyWith(buffer: p);
    _add(bufferController, p);
  }

  void _setPlaying(bool playing) {
    if (state.playing == playing) return;
    state = state.copyWith(playing: playing);
    _add(playingController, playing);
    if (playing) {
      _ticker ??= Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _extrapolate(),
      );
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  void _extrapolate() {
    if (_disposed || !state.playing) return;
    final int ms =
        _anchor.inMilliseconds +
        (_sinceAnchor.elapsedMilliseconds * state.rate).round();
    final Duration p = Duration(milliseconds: ms);
    final Duration capped = state.duration > Duration.zero && p > state.duration
        ? state.duration
        : p;
    _setPosition(capped);
  }

  void _setSize(int w, int h) {
    if (w <= 0 || h <= 0) return;
    if (state.width == w && state.height == h) return;
    final VideoParams params = VideoParams(w: w, h: h, dw: w, dh: h);
    state = state.copyWith(width: w, height: h, videoParams: params);
    _add(widthController, w);
    _add(heightController, h);
    _add(videoParamsController, params);
  }

  void _add<T>(StreamController<T> c, T value) {
    if (!c.isClosed) c.add(value);
  }

  // ── 动作：转成页面 JS ─────────────────────────────────────────────────

  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final Playlist playlist = playable is Playlist
        ? playable
        : Playlist(<Media>[playable as Media]);
    state = state.copyWith(playlist: playlist);
    _add(playlistController, playlist);
    if (!completer.isCompleted) completer.complete();
    // 站点自己起播（页面导航即播放）；play=false 时暂停在开头。
    if (!play) await pause();
  }

  @override
  Future<void> play() async {
    _setPlaying(true);
    await evaluate('window.__fushiWebVideo.play()');
  }

  @override
  Future<void> pause() async {
    _anchor = state.position;
    _setPlaying(false);
    await evaluate('window.__fushiWebVideo.pause()');
  }

  @override
  Future<void> playOrPause() => state.playing ? pause() : play();

  @override
  Future<void> seek(Duration duration) async {
    final Duration target = duration < Duration.zero ? Duration.zero : duration;
    _anchor = target;
    _sinceAnchor
      ..reset()
      ..start();
    _setPosition(target);
    await evaluate('window.__fushiWebVideo.seek(${target.inMilliseconds})');
  }

  @override
  Future<void> setRate(double rate) async {
    // 换倍速前把外推基准落到当前位置，否则旧倍速的已走时长会按新倍速重算。
    _anchor = state.position;
    _sinceAnchor
      ..reset()
      ..start();
    state = state.copyWith(rate: rate);
    _add(rateController, rate);
    await evaluate('window.__fushiWebVideo.setRate($rate)');
  }

  /// media_kit 口径 0–100。
  @override
  Future<void> setVolume(double volume) async {
    final double v = volume.clamp(0, 100).toDouble();
    state = state.copyWith(volume: v);
    _add(volumeController, v);
    await evaluate('window.__fushiWebVideo.setVolume(${v / 100}, ${v == 0})');
  }

  @override
  Future<void> stop() => pause();

  @override
  Future<void> setPitch(double pitch) async {}

  @override
  Future<void> setPlaylistMode(PlaylistMode playlistMode) async {}

  @override
  Future<void> setShuffle(bool shuffle) async {}

  @override
  Future<void> setAudioDevice(AudioDevice audioDevice) async {}

  @override
  Future<void> setVideoTrack(VideoTrack track) async {}

  @override
  Future<void> setAudioTrack(AudioTrack track) async {}

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  /// 画面在站点（硬件 DRM 截不到）；截帧走制卡重放的可捕获档。
  @override
  Future<Uint8List?> screenshot({
    String? format = 'image/jpeg',
    bool includeLibassSubtitles = false,
  }) async => null;

  /// 没有 mpv 句柄：任何把它当 mpv 用的路径都该在此失败，而不是拿野指针。
  @override
  Future<int> get handle =>
      Future<int>.error(UnsupportedError('web video player has no mpv handle'));

  @override
  Future<void> dispose() async {
    _disposed = true;
    _ticker?.cancel();
    _ticker = null;
    await super.dispose();
  }
}
