// 网页视频的 media_kit 播放器后端：原生播放器页 / 控制条原封不动地跑在网页站点的
// <video> 上。画面由垫在 Flutter 下面的 WebView2 子窗口自己画（底层合成），所以它是
// [ExternallyRenderedPlatformPlayer]——VideoController 不为它建纹理、不要 mpv 句柄。
//
// 状态：页面 glue 每 ~250 ms 上报一次（[applySnapshot]），播放中按倍速外推位置，
// 进度条不一跳一跳。动作：play / pause / seek / rate / volume / 音轨 转成页面 JS 命令
// （[evaluate]），先乐观更新状态让按钮即时响应。
//
// 乐观状态与上报的冲突用**确定的在途状态**裁决，不用计时器：
// · seek 发出后到「落地」之前，上报里的旧位置不回灌（Netflix 的 seek 要 1–2 s 才落地，旧做法
//   250 ms 后就把进度条拽回原处）。落地 = 上报位置进入目标的容差（[kWebVideoSeekLandingTolerance]）
//   或收到这次 seek 的回执（[applySeekDone]，成败都算结束；失败记日志）；命令根本没发出去
//   （glue 返回 no-video / no-player / null）立即结束。换了视频（videoKey 变）也结束。
// · play / pause 同理：在途期间上报的反向播放态不回灌，上报与目标一致即结束；命令没发出去或页面
//   回报失败（[applyCommandFailed]）立即结束。
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart'
    show ExternallyRenderedPlatformPlayer;

import 'package:fushi/src/media/video/web_video_bridge.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';

/// 上报位置离 seek 目标（按在途期间的播放外推）多近算「已落地」。
const Duration kWebVideoSeekLandingTolerance = Duration(milliseconds: 1500);

/// glue 命令的结果码里表示「已发出」的那些（seek 的回执随后由 seekDone 送达）。
const Set<String> _kSeekSent = <String>{'bridge', 'direct'};

/// 站点画面能不能在页面里截帧（canvas 导出）：Netflix 是硬件 DRM（PlayReady），只能拿到黑帧；
/// 其余站点（YouTube 等 MSE 同源流）可以。
bool webVideoFrameCaptureSupported(String href) {
  final String host = (Uri.tryParse(href)?.host ?? '').toLowerCase();
  if (host.isEmpty) return false;
  return !kWebVideoNetflixHosts.any(
    (String h) => host == h || host.endsWith('.$h'),
  );
}

/// 解出 glue `captureFrame` 返回的 data URL 字节；结果码（'drm' / 'tainted' / 'no-video'）或
/// 格式不对返回 null。
@visibleForTesting
Uint8List? decodeWebVideoFrameDataUrl(Object? result) {
  if (result is! String || !result.startsWith('data:image/')) return null;
  final int comma = result.indexOf(',');
  if (comma < 0 || !result.substring(0, comma).endsWith(';base64')) {
    return null;
  }
  try {
    final Uint8List bytes = base64Decode(result.substring(comma + 1));
    return bytes.isEmpty ? null : bytes;
  } on FormatException {
    return null;
  }
}

class WebVideoPlatformPlayer extends PlatformPlayer
    implements ExternallyRenderedPlatformPlayer {
  WebVideoPlatformPlayer({required this.evaluate})
    : super(configuration: const PlayerConfiguration());

  /// 在站点页面里执行一条 `window.__fushiWebVideo.*` 命令，返回命令的结果码（没发出去为 null）。
  final Future<Object?> Function(String js) evaluate;

  /// 外推时钟的基准：最近一次权威位置与它的时刻。
  Duration _anchor = Duration.zero;
  final Stopwatch _sinceAnchor = Stopwatch();
  Timer? _ticker;
  bool _disposed = false;

  /// 在途的 seek：目标与序号（只认最后一次 seek 的回执）。
  int _seekSeq = 0;
  int? _pendingSeekId;

  /// 在途的播放 / 暂停：要达到的播放态。
  bool? _pendingPlaying;

  /// 上一份快照的视频身份：换视频时在途状态全部作废。
  String? _lastVideoKey;

  /// 站点音轨（目前只有 Netflix）：media_kit 的 [Tracks.audio] 只放真实轨（没有 auto / no）。
  List<WebVideoSiteTrack> _siteAudioTracks = const <WebVideoSiteTrack>[];

  /// 当前站点画面能否在页面里截帧（[webVideoFrameCaptureSupported]，随快照更新）。
  bool get frameCaptureSupported => _frameCaptureSupported;
  bool _frameCaptureSupported = false;

  @visibleForTesting
  bool get debugSeekInFlight => _pendingSeekId != null;

  @visibleForTesting
  bool get debugPlayPauseInFlight => _pendingPlaying != null;

  /// 页面上报一次播放状态。[volume] 0–1；[buffering] 来自 readyState / seeking。
  void applySnapshot(
    WebVideoPlaybackState s, {
    double? volume,
    bool? muted,
    bool buffering = false,
  }) {
    if (_disposed) return;
    if (_lastVideoKey != null && _lastVideoKey != s.videoKey) {
      _pendingSeekId = null;
      _pendingPlaying = null;
    }
    _lastVideoKey = s.videoKey;
    _frameCaptureSupported =
        s.hasVideo && webVideoFrameCaptureSupported(s.href);
    final Duration reported = Duration(milliseconds: s.positionMs ?? 0);
    final Duration duration = Duration(milliseconds: s.durationMs ?? 0);
    if (_pendingSeekId != null) {
      final Duration expected = _extrapolatedPosition();
      if ((reported - expected).abs() <= kWebVideoSeekLandingTolerance) {
        _pendingSeekId = null;
      }
    }
    if (_pendingSeekId == null) {
      _anchor = reported;
      _sinceAnchor
        ..reset()
        ..start();
      _setPosition(reported);
    }
    if (state.duration != duration) {
      state = state.copyWith(duration: duration);
      _add(durationController, duration);
    }
    final bool playing = s.hasVideo && !s.paused;
    final bool? wanted = _pendingPlaying;
    if (wanted == null || wanted == playing) {
      _pendingPlaying = null;
      _setPlaying(playing);
    }
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
    _applySiteAudioTracks(s.siteAudioTracks, s.siteAudioTrackCurrent);
    final Duration position = state.position;
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

  /// glue 的 seek 回执：是在途那一次的（或旧 glue 不带序号）就结束在途；失败记日志，下一份上报
  /// 的真实位置照常回灌（seek 没成，进度条回到实际位置才是对的）。
  void applySeekDone(WebVideoSeekDone done) {
    if (_disposed) return;
    if (!done.ok) {
      ErrorLogService.instance.log(
        'web_video',
        'seek failed (id=${done.id}): ${done.err}',
      );
    }
    if (done.id == null || done.id == _pendingSeekId) _pendingSeekId = null;
  }

  /// 页面命令异步失败（play 被自动播放策略拒绝）：结束对应的在途播放态。
  void applyCommandFailed(String command) {
    if (_disposed) return;
    if (command == 'play' && _pendingPlaying == true) _pendingPlaying = null;
  }

  Duration _extrapolatedPosition() {
    if (!state.playing) return _anchor;
    final int ms =
        _anchor.inMilliseconds +
        (_sinceAnchor.elapsedMilliseconds * state.rate).round();
    final Duration p = Duration(milliseconds: ms);
    return state.duration > Duration.zero && p > state.duration
        ? state.duration
        : p;
  }

  void _applySiteAudioTracks(List<WebVideoSiteTrack> tracks, String current) {
    if (!listEquals(tracks, _siteAudioTracks)) {
      _siteAudioTracks = tracks;
      final Tracks next = Tracks(
        video: state.tracks.video,
        audio: <AudioTrack>[
          for (final WebVideoSiteTrack t in tracks)
            AudioTrack(t.id, t.name.isEmpty ? null : t.name, t.lang),
        ],
        subtitle: state.tracks.subtitle,
      );
      state = state.copyWith(tracks: next);
      _add(tracksController, next);
    }
    if (current.isNotEmpty && state.track.audio.id != current) {
      final AudioTrack? selected = state.tracks.audio
          .where((AudioTrack t) => t.id == current)
          .firstOrNull;
      if (selected != null) {
        final Track next = state.track.copyWith(audio: selected);
        state = state.copyWith(track: next);
        _add(trackController, next);
      }
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
    _setPosition(_extrapolatedPosition());
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

  /// 外推基准落到当前（乐观）位置：之后按新的播放态 / 倍速往前走。
  void _rebaseAnchor() {
    _anchor = state.position;
    _sinceAnchor
      ..reset()
      ..start();
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
  Future<void> play() => _setPlayingCommand(true);

  @override
  Future<void> pause() => _setPlayingCommand(false);

  Future<void> _setPlayingCommand(bool playing) async {
    _rebaseAnchor();
    _pendingPlaying = playing;
    _setPlaying(playing);
    final Object? result = await evaluate(
      playing
          ? 'window.__fushiWebVideo.play()'
          : 'window.__fushiWebVideo.pause()',
    );
    if (_disposed) return;
    if (result != 'ok' && _pendingPlaying == playing) {
      ErrorLogService.instance.log(
        'web_video',
        '${playing ? 'play' : 'pause'} not sent: $result',
      );
      _pendingPlaying = null;
    }
  }

  @override
  Future<void> playOrPause() => state.playing ? pause() : play();

  @override
  Future<void> seek(Duration duration) async {
    final Duration target = duration < Duration.zero ? Duration.zero : duration;
    final int id = ++_seekSeq;
    _pendingSeekId = id;
    _anchor = target;
    _sinceAnchor
      ..reset()
      ..start();
    _setPosition(target);
    final Object? result = await evaluate(
      'window.__fushiWebVideo.seek(${target.inMilliseconds}, $id)',
    );
    if (_disposed) return;
    if (!_kSeekSent.contains(result) && _pendingSeekId == id) {
      ErrorLogService.instance.log('web_video', 'seek not sent: $result');
      _pendingSeekId = null;
    }
  }

  @override
  Future<void> setRate(double rate) async {
    // 换倍速前把外推基准落到当前位置，否则旧倍速的已走时长会按新倍速重算。
    _rebaseAnchor();
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

  /// 站点音轨：让站点播放器切过去（Netflix 播放器 API）。只接受站点上报过的轨；乐观更新当前轨，
  /// 下一份上报按站点真实当前轨校正。
  @override
  Future<void> setAudioTrack(AudioTrack track) async {
    if (!_siteAudioTracks.any((WebVideoSiteTrack t) => t.id == track.id)) {
      return;
    }
    final Track next = state.track.copyWith(audio: track);
    state = state.copyWith(track: next);
    _add(trackController, next);
    final Object? result = await evaluate(
      'window.__fushiWebVideo.selectNetflixAudioTrack(${jsonEncode(track.id)})',
    );
    if (result != true) {
      ErrorLogService.instance.log(
        'web_video',
        'audio track ${track.id} not selected: $result',
      );
    }
  }

  @override
  Future<void> setSubtitleTrack(SubtitleTrack track) async {}

  /// 画面在站点页面里：非 DRM 站点用页面 canvas 截当前帧（暂停 OCR / 识别画面文字用）；Netflix
  /// 硬件 DRM 截不到，返回 null（制卡截帧另走重放的可捕获档）。站点字幕不在视频帧里，
  /// [includeLibassSubtitles] 无意义。
  @override
  Future<Uint8List?> screenshot({
    String? format = 'image/jpeg',
    bool includeLibassSubtitles = false,
  }) async {
    if (_disposed || !_frameCaptureSupported) return null;
    final String type = format == 'image/png' ? 'image/png' : 'image/jpeg';
    return decodeWebVideoFrameDataUrl(
      await evaluate("window.__fushiWebVideo.captureFrame('$type')"),
    );
  }

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
