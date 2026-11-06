/// 流式书的收听进度与 Audiobookshelf 服务器同步。
///
/// - 接上时开一个播放会话（direct play），拿到服务器记的续播位置；与本机差超过
///   [kAudiobookshelfResumeJumpThresholdSeconds] 时判断「谁动过」，**两边各用各的
///   时钟**：服务器 `lastUpdate` 比上次对齐时记下的 [RemoteAudioBinding.serverProgressAt]
///   新 = 别的设备写过（服务器时钟比服务器时钟）；本机 `localProgressAt` 比上次对齐的
///   [RemoteAudioBinding.progressSyncedAt] 新 = 本机有没推上去的进度（本机时钟比本机
///   时钟）。只有服务器动过 → 跳过去；只有本机动过 → 留在本机；两边都动过才是冲突，
///   才退回按时刻比（[kAudiobookshelfClockSkewTolerance]）。刚开书的头
///   [kAudiobookshelfResumeWhilePlayingWindow] 内正在播也照跳；
/// - 每次推送成功后读回服务器那条进度：位置是自己刚推的，就把它的 `lastUpdate` 记成
///   新基线（`onSynced` 落库）；
/// - 暂停很久后再按播放时再看一眼服务器：位置和本机上次写进去的不一样，说明别的设备
///   动过，跳过去；
/// - 本机听过 / 拖过就记下时间（哪怕发不出去），所以只在离线听的位置不会被下次开书时
///   服务器上更旧的记录盖掉；
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

/// 服务器位置与本机相差超过这么多才跳过去（秒）。
const double kAudiobookshelfResumeJumpThresholdSeconds = 5;

/// 刚开书的这段时间里，即使已经在播也允许按服务器位置续播。
const Duration kAudiobookshelfResumeWhilePlayingWindow = Duration(seconds: 30);

/// 暂停超过这么久再按播放，才去问一次服务器有没有被别的设备改过。
const Duration kAudiobookshelfRecheckAfterPause = Duration(seconds: 45);

/// **只用于冲突**（服务器与本机自上次对齐后都动过）：服务器记录比本机最后一次写入
/// 旧过这么多，就认为是本机后听的。这里不得不跨两台机器的时钟比，所以留出余量；
/// 非冲突的情形一律不走这条。
const Duration kAudiobookshelfClockSkewTolerance = Duration(minutes: 5);

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
    Future<void> Function(int nowMs)? onPushed,
    Future<void> Function(int serverProgressAt, int syncedAt)? onSynced,
  }) : _deviceId = deviceId,
       _now = now ?? DateTime.now,
       _timerFactory = timerFactory ?? _periodicTimer,
       _onError = onError,
       _onPushed = onPushed,
       _onSynced = onSynced,
       _localProgressAtOnOpen = binding.localProgressAt,
       _serverProgressAtOnOpen = binding.serverProgressAt,
       _progressSyncedAtOnOpen = binding.progressSyncedAt;

  final AudiobookshelfApi api;
  final RemoteAudioBinding binding;
  final Duration interval;
  final Future<String> Function() _deviceId;
  final DateTime Function() _now;
  final ProgressTimerFactory _timerFactory;
  final void Function(String what, Object error)? _onError;

  /// 一次同步成功后调用（落库本机最后写入时间，下次开书判断谁更新）。
  final Future<void> Function(int nowMs)? _onPushed;

  /// 本机与服务器进度对齐了（推送成功并读回、或采用了服务器位置）：落库
  /// `serverProgressAt`（服务器时钟）与 `syncedAt`（本机时钟），下次开书据此各自判断
  /// 两边有没有动过。
  final Future<void> Function(int serverProgressAt, int syncedAt)? _onSynced;

  /// 开书**之前**本机最后一次写进度的时刻（null = 从没写过）。续播判定只认它：本次
  /// 会话里刚听的几秒会被 [_stampLocalWrite] 落库，但不能反过来让本次判定误以为
  /// 「本机比服务器新」。
  final int? _localProgressAtOnOpen;

  /// 开书前最后一次对齐时服务器的 `lastUpdate`（服务器时钟）；null = 从没对齐过。
  final int? _serverProgressAtOnOpen;

  /// 开书前最后一次对齐的本机时刻（本机时钟）；null = 从没对齐过。
  final int? _progressSyncedAtOnOpen;

  /// 续播判定（读服务器进度 + 开会话 + 决定跳不跳）还没做完。期间不往服务器推任何
  /// 位置：推上去的是开书时的旧位置，会盖掉别的设备刚写的新进度，随后读回来的
  /// 又是自己刚推的那条，续播就永远跳不过去了。
  bool _resolving = false;

  /// 在途的那次同步；[close] 先等它落定，免得同一段收听时长被算两次。
  Future<void>? _inFlight;

  /// [close] 时采样的最终位置；开会话途中就关书时，补关会话要带它而不是会话里的旧位置。
  double? _finalPosition;
  Duration _finalListened = Duration.zero;
  int _finalSampledAt = 0;
  DateTime _attachedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _pausedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _checkingServer = false;

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
    _attachedAt = _now();
    _wasPlaying = host.isPlaying();
    host.addListener(_onHostChanged);
    _timer = _timerFactory(interval, () => unawaited(flush()));

    _resolving = true;
    try {
      final AudiobookshelfMediaProgress? stored = await _readProgress();
      final AudiobookshelfPlaySession session = await api.startPlay(
        binding.itemId,
        deviceId: await _deviceId(),
        episodeId: binding.episodeId,
      );
      if (_closed) {
        // 等会话的功夫书已经关了：用关书那一刻的位置把会话收尾（close() 在续播判定
        // 完成前不发网络请求，最终位置只能经这里写上服务器）。
        unawaited(_closeQuietly(session));
        return;
      }
      _session = session;
      await _resumeFrom(
        stored?.currentTimeSeconds ?? session.currentTimeSeconds,
        lastUpdateMs: stored?.lastUpdateMs,
      );
    } catch (e) {
      _report('startPlay', e);
    } finally {
      _resolving = false;
    }
  }

  /// 服务器上这条的进度记录；读不到（离线 / 没记录）为 null，退回会话给的续播位置。
  Future<AudiobookshelfMediaProgress?> _readProgress() async {
    try {
      return await api.getProgress(
        binding.itemId,
        episodeId: binding.episodeId,
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _resumeFrom(double serverSeconds, {int? lastUpdateMs}) async {
    final RemotePlaybackHost? host = _host;
    if (host == null || _closed) return;
    if (host.isPlaying() &&
        _now().difference(_attachedAt) >
            kAudiobookshelfResumeWhilePlayingWindow) {
      return;
    }
    if ((serverSeconds - _absoluteSeconds()).abs() <=
        kAudiobookshelfResumeJumpThresholdSeconds) {
      // 两边位置一致：此刻就是对齐的。
      _markInSync(lastUpdateMs, _now().millisecondsSinceEpoch);
      return;
    }
    // 服务器上还是本机上次对齐的那条：本机的位置不旧于它，留在本机（本机动过的话
    // 随后的同步会推上去）。
    if (!_serverMovedSinceSync(lastUpdateMs)) return;
    // 两边都动过（冲突）：只能按时刻比。服务器那条比本机（开书前）最后一次写入旧得
    // 多 = 本机后听的，别拿旧位置覆盖它。
    final int? localAt = _localProgressAtOnOpen;
    if (_localMovedSinceSync() &&
        localAt != null &&
        lastUpdateMs != null &&
        lastUpdateMs <
            localAt - kAudiobookshelfClockSkewTolerance.inMilliseconds) {
      return;
    }
    await _jumpTo(serverSeconds);
    _markInSync(lastUpdateMs, _now().millisecondsSinceEpoch);
  }

  /// 服务器那条进度自上次对齐后是否被写过——只在服务器时钟域里比：读到的
  /// `lastUpdate` 与上次对齐时记下的 `lastUpdate` 都是服务器给的时刻。任何一个未知
  /// （从没对齐过 / 读不到进度记录）都按「动过」处理，交给后面的规则决定。
  bool _serverMovedSinceSync(int? lastUpdateMs) {
    final int? baseline = _serverProgressAtOnOpen;
    if (lastUpdateMs == null || baseline == null) return true;
    return lastUpdateMs > baseline;
  }

  /// 本机自上次对齐后是否听过 / 拖过——只在本机时钟域里比：两个时刻都是本机记的。
  /// 从没对齐过而本机写过进度，按「动过」处理。
  bool _localMovedSinceSync() {
    final int? localAt = _localProgressAtOnOpen;
    if (localAt == null) return false;
    final int? syncedAt = _progressSyncedAtOnOpen;
    return syncedAt == null || localAt > syncedAt;
  }

  /// 记下「此刻两边对齐」：[serverAt] 是服务器时钟的 `lastUpdate`，[localAt] 是本机
  /// 时钟。服务器时刻未知时不记（没法当基线）。
  void _markInSync(int? serverAt, int localAt) {
    final Future<void> Function(int, int)? hook = _onSynced;
    if (serverAt == null || hook == null) return;
    unawaited(
      hook(
        serverAt,
        localAt,
      ).catchError((Object e) => _onError?.call('mark', e)),
    );
  }

  /// 推送成功后读回服务器那条进度：位置就是刚推上去的，才把它的 `lastUpdate` 当新
  /// 基线（推送与读回之间别的设备又写了，位置会不同——不认，下次开书照样看得出来）。
  /// [sampledAt] 是推上去的那个位置的本机采样时刻。读不到只是这次不更新基线。
  Future<void> _adoptServerBaseline(double pushed, int sampledAt) async {
    final AudiobookshelfMediaProgress? stored = await _readProgress();
    if (stored == null) return;
    if ((stored.currentTimeSeconds - pushed).abs() >= 1) return;
    _markInSync(stored.lastUpdateMs, sampledAt);
  }

  Future<void> _jumpTo(double serverSeconds) async {
    final RemotePlaybackHost? host = _host;
    if (host == null) return;
    final ({int fileIndex, int positionMs})? target = locate(
      binding.tracks,
      serverSeconds,
    );
    if (target == null) return;
    await host.restoreTo(target.fileIndex, target.positionMs);
    _lastSyncedPosition = serverSeconds;
  }

  /// 暂停很久后又要播放：服务器位置和本机上次写进去的不一样 = 别的设备动过。
  Future<void> _recheckServer() async {
    if (_checkingServer || _closed || _session == null) return;
    final double? mine = _lastSyncedPosition;
    if (mine == null) return;
    _checkingServer = true;
    try {
      final AudiobookshelfMediaProgress? stored = await _readProgress();
      if (stored == null || _closed) return;
      if ((stored.currentTimeSeconds - mine).abs() >
          kAudiobookshelfResumeJumpThresholdSeconds) {
        await _jumpTo(stored.currentTimeSeconds);
      }
      _markInSync(stored.lastUpdateMs, _now().millisecondsSinceEpoch);
    } catch (e) {
      // 这里是 unawaited 调用的：不接住就成了未处理的异步异常。跳转失败（例如服务器
      // 记的时长比本机实际解码出来的长，restoreTo 越界）照常记日志、不打断播放。
      _report('recheck', e);
    } finally {
      _checkingServer = false;
    }
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
    if (!playing) {
      _pausedAt = _now();
      unawaited(flush());
    } else if (_now().difference(_pausedAt) >
        kAudiobookshelfRecheckAfterPause) {
      unawaited(_recheckServer());
    }
  }

  /// 立即同步一次（定时器 / 暂停触发）。进行中的同步不重入。
  Future<void> flush() {
    if (_flushing || _closed || _resolving || _host == null) {
      return Future<void>.value();
    }
    return _inFlight = _flushOnce();
  }

  Future<void> _flushOnce() async {
    _flushing = true;
    try {
      _accrue();
      final int sampledAt = _now().millisecondsSinceEpoch;
      final double position = _absoluteSeconds();
      final Duration listened = _pendingListened;
      final double? last = _lastSyncedPosition;
      // 没在听、位置也没动：不发无意义的请求。
      if (listened <= Duration.zero &&
          last != null &&
          (position - last).abs() < 1) {
        return;
      }
      // 先记「本机写过位置」再发：离线时发不出去，本机的位置也比服务器旧记录新。
      if (_movedLocally(position, _seconds(listened))) {
        _stampLocalWrite(sampledAt);
      }
      await _send(position, listened, sampledAt);
    } finally {
      _flushing = false;
      _inFlight = null;
    }
  }

  static double _seconds(Duration d) => d.inMilliseconds / 1000;

  /// 一次同步成功：只扣掉这次发出去的那段时长——请求在途期间新攒的不能一起清掉。
  void _markSent(double position, Duration sent) {
    _pendingListened -= sent;
    if (_pendingListened < Duration.zero) _pendingListened = Duration.zero;
    _lastSyncedPosition = position;
  }

  Future<void> _send(double position, Duration listened, int sampledAt) async {
    final AudiobookshelfPlaySession? session = _session;
    try {
      if (session != null) {
        await api.syncSession(
          session.id,
          currentTimeSeconds: position,
          timeListenedSeconds: _seconds(listened),
          durationSeconds: _durationSeconds,
        );
      } else {
        await _patch(position);
      }
      _markSent(position, listened);
      _reportedFailure = false;
      await _adoptServerBaseline(position, sampledAt);
    } on ExternalProviderFailure catch (failure) {
      if (failure.kind == ExternalProviderFailureKind.notFound &&
          session != null) {
        // 会话被服务器清掉了：改用直接写进度，下一轮起都走这条。
        _session = null;
        try {
          await _patch(position);
          _markSent(position, listened);
          await _adoptServerBaseline(position, sampledAt);
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

  /// 这次是否真的听过 / 拖过（暂停着挂机不算，别拿它去压服务器上更新的进度）。
  bool _movedLocally(double position, double listened) {
    if (listened > 0) return true;
    final double? last = _lastSyncedPosition;
    return last != null && (position - last).abs() >= 1;
  }

  /// 记下本机最后一次写位置的时间（落库），下次开书据此判断谁的位置更新。
  void _stampLocalWrite(int nowMs) {
    final Future<void> Function(int nowMs)? hook = _onPushed;
    if (hook != null) {
      unawaited(
        hook(nowMs).catchError((Object e) => _onError?.call('stamp', e)),
      );
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
    // 在途的同步先落定：它成功后会扣掉自己发出去的时长，否则下面再算一遍就重复了。
    final Future<void>? inFlight = _inFlight;
    if (inFlight != null) {
      try {
        await inFlight.timeout(const Duration(seconds: 8));
      } on TimeoutException {
        // 超时就按没发成处理：那段时长仍留在 _pendingListened 里由 close 带上。
      }
    }
    double? position;
    Duration listened = Duration.zero;
    final int sampledAt = _now().millisecondsSinceEpoch;
    if (host != null) {
      _accrue();
      position = _absoluteSeconds();
      listened = _pendingListened;
    }
    if (position != null && _movedLocally(position, _seconds(listened))) {
      _stampLocalWrite(sampledAt);
    }
    _closed = true;
    _finalPosition = position;
    _finalListened = listened;
    _finalSampledAt = sampledAt;
    final AudiobookshelfPlaySession? session = _session;
    _session = null;
    // 会话还没开出来（续播判定没做完）：此刻不知道服务器上是不是别的设备的新进度，
    // 不推。attach 等到会话后会用 [_finalPosition] 收尾（见 [_closeQuietly]）；会话
    // 开不出来（离线）时本机写入时间已经落库，下次开书照样以本机为准。
    if (position == null || (_resolving && session == null)) return;
    try {
      if (session != null) {
        await api
            .closeSession(
              session.id,
              currentTimeSeconds: position,
              timeListenedSeconds: _seconds(listened),
              durationSeconds: _durationSeconds,
            )
            .timeout(const Duration(seconds: 8));
      } else {
        await _patch(position).timeout(const Duration(seconds: 8));
      }
      await _adoptServerBaseline(
        position,
        sampledAt,
      ).timeout(const Duration(seconds: 8));
    } catch (e) {
      _report('close', e);
    }
  }

  Future<void> _closeQuietly(AudiobookshelfPlaySession session) async {
    try {
      final double? finalPosition = _finalPosition;
      await api.closeSession(
        session.id,
        currentTimeSeconds: finalPosition ?? session.currentTimeSeconds,
        timeListenedSeconds: _seconds(_finalListened),
        durationSeconds: session.durationSeconds,
      );
      // 只有关书时确有本机位置才算「推上去并对齐」；否则推的是会话里服务器自己的位置。
      if (finalPosition != null) {
        await _adoptServerBaseline(finalPosition, _finalSampledAt);
      }
    } catch (e) {
      _report('close', e);
    }
  }

  /// 同一串连续失败只报一次（离线时每 30 秒一次会刷屏）。
  void _report(String what, Object error) {
    if (_reportedFailure) return;
    _reportedFailure = true;
    _onError?.call(what, error);
  }
}
