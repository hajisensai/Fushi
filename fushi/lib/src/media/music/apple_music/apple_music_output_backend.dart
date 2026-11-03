/// MusicKit 播放后端（MusicKit 方案 §3.3）：`fushi-apple-music://song/<catalogId>` 曲目由 Apple
/// 授权的播放器（原生 `ApplicationMusicPlayer` / 网页 MusicKit JS）出声，这里只发控制命令、收进度。
///
/// - 桥里一次只有一首：同属本后端的「下一首」由这里记着，当前曲播完再 `play(next)` 并补发
///   [MusicBackendAdvanced]——**不无缝**（MusicKit 单曲队列，Fushi 队列是唯一真相）。
/// - 拿不到 PCM：信号路径、A-B 循环、均衡器、交叉淡入一概不支持（能力标志在路由上声明）。
/// - 音量：网页桥跟随软件音量；原生没有应用级音量，跟随系统。
/// - 换曲 / 停止命令串行下发、最后一个说了算（[_issue]）：桥不保证并发 setQueue 的完成顺序。
/// - 桥那一代没了（[AppleMusicSessionLost]）或账号断开：当前曲判失败，引擎下次按播放重新打开。
library;

import 'dart:async';

import 'package:fushi_engine/media/music/apple_music/apple_music_catalog_client.dart'
    show appleMusicSongIdFromPath, isAppleMusicTrackPath;

import 'package:fushi/src/media/music/apple_music/apple_music_bridge.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_routing_backend.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';

/// 路由名。
const String kAppleMusicBackendRoute = 'apple-music';

/// MusicKit 曲目的能力：没有音频信号可读、不能在音频时间轴上做 A-B 循环。
const MusicBackendCapabilities kAppleMusicBackendCapabilities =
    MusicBackendCapabilities(signalPath: false, abLoop: false);

/// Apple Music 整曲的路由（app 装配点用）。[bridge] 为 null（本平台没有 MusicKit 播放器）时
/// 不装这条路由：这类曲目落到默认链路，mpv 打不开它、按单曲失败处理。
MusicBackendRoute appleMusicBackendRoute(AppleMusicBridge Function() bridge) =>
    MusicBackendRoute(
      id: kAppleMusicBackendRoute,
      handles: (MusicPlayItem item) => isAppleMusicTrackPath(item.path),
      create: () => AppleMusicOutputBackend(bridge()),
      capabilities: kAppleMusicBackendCapabilities,
    );

class AppleMusicOutputBackend implements MusicOutputBackend {
  AppleMusicOutputBackend(this._bridge) {
    _sub = _bridge.events.listen(_onBridgeEvent);
  }

  final AppleMusicBridge _bridge;
  late final StreamSubscription<AppleMusicPlayerEvent> _sub;

  final StreamController<MusicBackendEvent> _events =
      StreamController<MusicBackendEvent>.broadcast();

  MusicPlayItem? _current;
  String? _currentSongId;
  MusicPlayItem? _next;

  /// 打开代次：后来的 openPair / stop 作废前一次还没回来的打开与接力。
  int _gen = 0;

  /// 正在打开（桥还在 setQueue）：这期间桥上的事件属于上一首，不转发。
  bool _opening = false;

  /// 已下发到桥、还没落地的最后一条换曲 / 停止命令。桥（原生 MusicKit 的 setQueue 在 await
  /// 处挂起、网页的 callAsyncJavaScript）不保证并发命令的完成顺序：连切 A→B 时 A 可能晚于 B
  /// 落地、把队列换回 A。所以命令一条接一条下发，轮到时已被更新的打开 / 停止作废就不再下发。
  Future<void> _bridgeChain = Future<void>.value();

  double _volume = 1;
  bool _disposed = false;

  @override
  Stream<MusicBackendEvent> get events => _events.stream;

  void _emit(MusicBackendEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  bool _isCurrent(String? songId) => songId == null || songId == _currentSongId;

  void _onBridgeEvent(AppleMusicPlayerEvent e) {
    if (_opening || _current == null) return;
    switch (e) {
      case AppleMusicProgress(:final int positionMs, :final int? durationMs):
        if (!_isCurrent(e.songId)) return;
        final int? dur = durationMs ?? _current?.durationMs;
        _emit(
          MusicBackendPosition(
            Duration(milliseconds: positionMs),
            dur == null ? null : Duration(milliseconds: dur),
          ),
        );
      case AppleMusicPlayingChanged(:final bool playing):
        if (!_isCurrent(e.songId)) return;
        _emit(MusicBackendPlaying(playing));
      case AppleMusicEnded():
        if (!_isCurrent(e.songId)) return;
        unawaited(_onEnded());
      case AppleMusicPlaybackError(:final String message):
        if (!_isCurrent(e.songId)) return;
        _emit(
          MusicBackendFailed(
            message,
            reason: MusicPlaybackFailure.trackUnavailable,
            trackUid: _current?.trackUid,
          ),
        );
      case AppleMusicSessionLost(:final String reason):
        _failCurrent(
          'Apple Music player was reset ($reason)',
          MusicPlaybackFailure.appleMusicSessionLost,
        );
      case AppleMusicAccountChanged(:final AppleMusicAccountState state):
        if (!state.isAuthorized) {
          _failCurrent(
            'Apple Music signed out',
            MusicPlaybackFailure.appleMusicSignedOut,
          );
        }
    }
  }

  /// 当前曲在桥上已经不存在（桥那一代没了 / 账号断开）：判失败并放下它。引擎据此停住、提示，
  /// 并把这首标成需重开——下次按播放走 openPair 重新 setQueue，而不是对桥发 resume / seek。
  void _failCurrent(String message, MusicPlaybackFailure reason) {
    final MusicPlayItem? item = _current;
    if (item == null) return;
    _gen++;
    _current = null;
    _currentSongId = null;
    _emit(MusicBackendFailed(message, reason: reason, trackUid: item.trackUid));
  }

  /// 按顺序下发一条桥命令：先等上一条落地（它自己的失败由它的调用方处理），轮到时 [gen]
  /// 已被作废就不下发、回 false。
  Future<bool> _issue(int gen, Future<void> Function() command) async {
    final Future<void> previous = _bridgeChain;
    final Completer<void> done = Completer<void>();
    _bridgeChain = done.future;
    try {
      await previous;
      if (gen != _gen) return false;
      await command();
      return true;
    } finally {
      done.complete();
    }
  }

  /// 当前曲播完：有排好的下一首就接着放并补发 Advanced，否则 Completed。
  Future<void> _onEnded() async {
    final MusicPlayItem? next = _next;
    if (next == null) {
      _emit(const MusicBackendCompleted());
      return;
    }
    final int gen = ++_gen;
    _next = null;
    try {
      await _open(next, play: true, gen: gen);
      if (gen != _gen) return;
      _emit(MusicBackendAdvanced(next.trackUid));
      _emit(const MusicBackendPlaying(true));
    } on MusicTrackOpenException catch (e) {
      if (gen != _gen) return;
      _emit(
        MusicBackendFailed(
          e.failure.message,
          reason: e.failure.reason,
          trackUid: next.trackUid,
        ),
      );
    }
  }

  /// 让桥换上 [item]。失败抛 [MusicTrackOpenException]；被更新的打开作废时静默返回。
  Future<void> _open(
    MusicPlayItem item, {
    required bool play,
    required int gen,
  }) async {
    final String? songId = appleMusicSongIdFromPath(item.path);
    if (songId == null) {
      throw MusicTrackOpenException(
        MusicBackendFailed(
          'not an Apple Music track: ${item.path}',
          reason: MusicPlaybackFailure.trackUnavailable,
          trackUid: item.trackUid,
        ),
      );
    }
    _opening = true;
    try {
      final bool issued = await _issue(
        gen,
        () => _bridge.play(songId, autoplay: play),
      );
      if (!issued) return;
    } on Object catch (e) {
      if (gen != _gen) return;
      throw MusicTrackOpenException(
        MusicBackendFailed(
          '$e',
          reason: MusicPlaybackFailure.trackUnavailable,
          trackUid: item.trackUid,
        ),
      );
    } finally {
      if (gen == _gen) _opening = false;
    }
    if (gen != _gen) return;
    _current = item;
    _currentSongId = songId;
    _emit(
      MusicBackendPosition(
        Duration.zero,
        item.durationMs == null
            ? null
            : Duration(milliseconds: item.durationMs!),
      ),
    );
  }

  @override
  Future<void> applySettings(MusicOutputSettings settings) async {
    final double v = (settings.volume / 100).clamp(0.0, 1.0);
    if (v == _volume) return;
    _volume = v;
    try {
      await _bridge.setVolume(v);
    } on Object {
      // 桥还没起来：下次 openPair 后由 play 默认音量放；不影响播放。
    }
  }

  @override
  Future<void> openPair(
    MusicPlayItem current,
    MusicPlayItem? next, {
    required bool play,
    bool crossfadeNext = false,
  }) async {
    final int gen = ++_gen;
    _current = null;
    _currentSongId = null;
    _next = next;
    await _open(current, play: play, gen: gen);
    if (gen == _gen && _volume != 1) {
      try {
        await _bridge.setVolume(_volume);
      } on Object {
        // 同上。
      }
    }
  }

  @override
  Future<void> replaceNext(
    MusicPlayItem? next, {
    bool crossfadeNext = false,
  }) async {
    _next = next;
  }

  @override
  Future<void> play() async {
    if (_current == null) return;
    await _bridge.resume();
  }

  @override
  Future<void> pause() async {
    if (_current == null) return;
    await _bridge.pause();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_current == null) return;
    await _bridge.seek(position.inMilliseconds);
  }

  /// 不支持（能力标志已让界面隐藏入口，引擎也会拒绝）。
  @override
  Future<void> setAbLoop(Duration? a, Duration? b) async {}

  @override
  Future<void> stop() async {
    final int gen = ++_gen;
    _opening = false;
    _current = null;
    _currentSongId = null;
    _next = null;
    // 排在还没落地的打开之后：否则那次打开晚到时又把曲目放起来。
    await _issue(gen, _bridge.stop);
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final int gen = ++_gen;
    await _sub.cancel();
    try {
      await _issue(gen, _bridge.stop);
    } on Object {
      // 退出时桥可能已经没了。
    }
    await _events.close();
  }

  @override
  Future<MusicSignalPathSnapshot?> readSignalPath() async => null;

  /// 输出设备由系统 / 浏览器选。
  @override
  Future<List<MusicAudioDevice>> listAudioDevices() async =>
      const <MusicAudioDevice>[];
}
