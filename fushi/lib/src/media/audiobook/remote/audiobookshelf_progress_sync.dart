/// 流式书的收听进度与 Audiobookshelf 服务器同步。
///
/// - 接上时开一个播放会话（direct play），拿到服务器记的续播位置：**服务器明显更靠前
///   且当前没在播**才跳过去（别的设备听得更远）；本机更靠前就保持，下一次同步会把本机
///   位置写回服务器；
/// - 播放中每 [interval] 同步一次，暂停的那一刻立即同步一次；
/// - 会话被服务器清掉（404）或根本开不了（离线）时退回「直接写进度」；
/// - 结束时同步最后一次位置并关闭会话。
///
/// 所有网络步骤都是 best-effort：失败只记一次日志，**绝不**影响播放。位置一律用
/// 全书时间轴上的真实秒数（轨偏移 + 轨内位置），不用控制器的 `globalPosition`（那是按
/// cue 推出来的时长算的，比真实时长短）。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/audiobook/remote/audiobook_remote_playback.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_api.dart';
import 'package:fushi_engine/media/audiobook/audiobookshelf/audiobookshelf_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

/// 服务器位置比本机靠前超过这么多才跳过去（秒）。
const double kAudiobookshelfResumeJumpThresholdSeconds = 5;

typedef ProgressTimerFactory =
    Timer Function(Duration interval, void Function() onTick);

Timer _periodicTimer(Duration interval, void Function() onTick) =>
    Timer.periodic(interval, (Timer _) => onTick());

class AudiobookshelfProgressSync {
  AudiobookshelfProgressSync({
    required this.api,
    required this.binding,
    required Future<String> Function() deviceId,
    this.interval = const Duration(seconds: 30),
    DateTime Function()? now,
    ProgressTimerFactory? timerFactory,
    void Function(String what, Object error)? onError,
  }) : _deviceId = deviceId,
       _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? _periodicTimer,
       _onError = onError;

  final AudiobookshelfApi api;
  final RemoteAudioBinding binding;
  final Duration interval;
  final Future<String> Function() _deviceId;
  final DateTime Function() _now;
  final ProgressTimerFactory _timerFactory;
  final void Function(String what, Object error)? _onError;

  RemotePlaybackHost? _host;
  Timer? _timer;
  AudiobookshelfPlaySession? _session;
  bool _closed = false;
  bool _flushing = false;
  bool _reportedFailure = false;

  bool _wasPlaying = false;
  DateTime _lastAccountAt = DateTime.fromMillisecondsSinceEpoch(0);
  Duration _pendingListened = Duration.zero;
  double? _lastSyncedPosition;

  /// 测试 / 诊断：当前是否持有服务器播放会话。
  bool get hasSession => _session != null;

  double get _durationSeconds {
    final AudiobookshelfPlaySession? session = _session;
    if (session != null && session.durationSeconds > 0) {
      return session.durationSeconds;
    }
    final List<RemoteAudioTrack> tracks = binding.tracks;
    return tracks.isEmpty ? 0 : tracks.last.endOffsetMs / 1000;
  }

  /// 把播放器接上来：开会话、按需续播、起定时器。可在后台跑（不阻塞开书）。
  Future<void> attach(RemotePlaybackHost host) async {
    if (_closed) return;
    _host = host;
    _lastAccountAt = _now();
    _wasPlaying = host.isPlaying();
    host.addListener(_onHostChanged);
    _timer = _timerFactory(interval, () => unawaited(flush()));

    try {
      final AudiobookshelfPlaySession session = await api.startPlay(
        binding.itemId,
        deviceId: await _deviceId(),
        episodeId: binding.episodeId,
      );
      if (_closed) {
        // 等会话的功夫书已经关了：别留一个无人收尾的服务器会话。
        unawaited(_closeQuietly(session));
        return;
      }
      _session = session;
      await _resumeFrom(session.currentTimeSeconds);
    } catch (e) {
      _report('startPlay', e);
    }
  }

  Future<void> _resumeFrom(double serverSeconds) async {
    final RemotePlaybackHost? host = _host;
    if (host == null || _closed || host.isPlaying()) return;
    if (serverSeconds <=
        _absoluteSeconds() + kAudiobookshelfResumeJumpThresholdSeconds) {
      return;
    }
    final ({int fileIndex, int positionMs})? target = locate(
      binding.tracks,
      serverSeconds,
    );
    if (target == null) return;
    await host.restoreTo(target.fileIndex, target.positionMs);
  }

  /// 全书时间轴上的秒数 → （第几轨，轨内毫秒）。超过全书末尾落在最后一轨末尾。
  @visibleForTesting
  static ({int fileIndex, int positionMs})? locate(
    List<RemoteAudioTrack> tracks,
    double seconds,
  ) {
    if (tracks.isEmpty) return null;
    final int ms = (seconds * 1000).round();
    for (int i = tracks.length - 1; i >= 0; i--) {
      if (tracks[i].startOffsetMs <= ms) {
        final int local = (ms - tracks[i].startOffsetMs).clamp(
          0,
          tracks[i].durationMs,
        );
        return (fileIndex: i, positionMs: local);
      }
    }
    return (fileIndex: 0, positionMs: 0);
  }

  double _absoluteSeconds() {
    final RemotePlaybackHost? host = _host;
    if (host == null || binding.tracks.isEmpty) return 0;
    final ({int fileIndex, int positionMs}) at = host.filePosition();
    final int index = at.fileIndex.clamp(0, binding.tracks.length - 1);
    return (binding.tracks[index].startOffsetMs + at.positionMs) / 1000;
  }

  /// 把截至此刻的「在播时长」记进账（只在播放状态变化 / 同步时调用）。
  void _accrue() {
    final DateTime now = _now();
    if (_wasPlaying) _pendingListened += now.difference(_lastAccountAt);
    _lastAccountAt = now;
  }

  void _onHostChanged() {
    final RemotePlaybackHost? host = _host;
    if (host == null || _closed) return;
    final bool playing = host.isPlaying();
    if (playing == _wasPlaying) return;
    _accrue();
    _wasPlaying = playing;
    // 暂停的那一刻立即同步：用户常常暂停后就退出，等定时器就丢了这一段。
    if (!playing) unawaited(flush());
  }

  /// 立即同步一次（定时器 / 暂停触发）。进行中的同步不重入。
  Future<void> flush() async {
    if (_flushing || _closed || _host == null) return;
    _flushing = true;
    try {
      _accrue();
      final double position = _absoluteSeconds();
      final double listened = _pendingListened.inMilliseconds / 1000;
      final double? last = _lastSyncedPosition;
      // 没在听、位置也没动：不发无意义的请求。
      if (listened <= 0 && last != null && (position - last).abs() < 1) return;
      await _send(position, listened);
    } finally {
      _flushing = false;
    }
  }

  Future<void> _send(double position, double listened) async {
    final AudiobookshelfPlaySession? session = _session;
    try {
      if (session != null) {
        await api.syncSession(
          session.id,
          currentTimeSeconds: position,
          timeListenedSeconds: listened,
          durationSeconds: _durationSeconds,
        );
      } else {
        await _patch(position);
      }
      _pendingListened = Duration.zero;
      _lastSyncedPosition = position;
      _reportedFailure = false;
    } on ExternalProviderFailure catch (failure) {
      if (failure.kind == ExternalProviderFailureKind.notFound &&
          session != null) {
        // 会话被服务器清掉了：改用直接写进度，下一轮起都走这条。
        _session = null;
        try {
          await _patch(position);
          _pendingListened = Duration.zero;
          _lastSyncedPosition = position;
          return;
        } catch (e) {
          _report('patchProgress', e);
          return;
        }
      }
      _report('sync', failure);
    } catch (e) {
      _report('sync', e);
    }
  }

  Future<void> _patch(double position) => api.patchProgress(
    binding.itemId,
    episodeId: binding.episodeId,
    currentTimeSeconds: position,
    durationSeconds: _durationSeconds,
  );

  /// 结束：同步最后一次位置并关闭服务器会话。重复调用无副作用。
  Future<void> close() async {
    if (_closed) return;
    final RemotePlaybackHost? host = _host;
    // 先收尾后置位：flush 要在 _closed 之前读完最后的状态。
    _timer?.cancel();
    _timer = null;
    host?.removeListener(_onHostChanged);
    double? position;
    double listened = 0;
    if (host != null) {
      _accrue();
      position = _absoluteSeconds();
      listened = _pendingListened.inMilliseconds / 1000;
    }
    _closed = true;
    final AudiobookshelfPlaySession? session = _session;
    _session = null;
    if (position == null) return;
    try {
      if (session != null) {
        await api
            .closeSession(
              session.id,
              currentTimeSeconds: position,
              timeListenedSeconds: listened,
              durationSeconds: _durationSeconds,
            )
            .timeout(const Duration(seconds: 8));
      } else {
        await _patch(position).timeout(const Duration(seconds: 8));
      }
    } catch (e) {
      _report('close', e);
    }
  }

  Future<void> _closeQuietly(AudiobookshelfPlaySession session) async {
    try {
      await api.closeSession(
        session.id,
        currentTimeSeconds: session.currentTimeSeconds,
        timeListenedSeconds: 0,
        durationSeconds: session.durationSeconds,
      );
    } catch (_) {}
  }

  /// 同一串连续失败只报一次（离线时每 30 秒一次会刷屏）。
  void _report(String what, Object error) {
    if (_reportedFailure) return;
    _reportedFailure = true;
    _onError?.call(what, error);
  }
}
