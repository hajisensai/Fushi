/// 服务器曲目的播放上报（Jellyfin `/Sessions/Playing*`、Subsonic `scrobble`）：播放次数、
/// 最近播放、服务器仪表盘的「正在播放」由服务器自己统计。
///
/// 接在 `MusicSession` 的曲目生命周期上（开播 [trackStarted] / 换下 [trackLeft] / 引擎
/// 状态变化 [engineChanged]），所以单曲循环重播、无缝推进、停止都按一次播放算。
/// - 只上报服务器曲目：播放项经 [MusicServerTrackResolver] 认回服务器与曲目 id（从服务器
///   页、曲库里的服务器曲目、最近播放重播、离线副本都一样），本地 / 插件 / 网络来源曲目认不出
///   就什么都不发；
/// - 离线副本（本机文件）照样上报（`PlayMethod` 为直放）；服务器连不上时（网络错误）不记
///   错误日志——离线听下载的曲目是正常用法。
/// - **没送达的播放不丢**：一次听够门槛（[musicScrobbleThresholdReached]）的播放，若计次的那条
///   上报没到服务器（Jellyfin 在开播时计、Subsonic 在停止时计，[MusicServerPlayMarking.countsPlayOnStart]）——
///   服务器连不上，或这台设备上已经没有那台服务器的配置（播放项仍带着服务器身份）——就交给
///   [onUndelivered] 记进离线补发队列（`music_server_offline_queue.dart`），之后按原开播时刻
///   补记。服务器回了错误（不是连不上）的不入队，照旧记日志。
/// - 对一台服务器的上报成功过一次，就经 [onDelivered] 通知（补发队列借机把那台服务器积压的
///   条目发出去）。
/// - 不挡播放：全部请求在后台串行队列里发，失败只记一次日志；这一首的开播上报失败后，后面
///   的进度 / 停止都不再发（不在断网时每 10 秒刷一次错）；
/// - 不刷屏：进度按 [kMusicServerProgressInterval]（与 Jellyfin web 同一档）节流，暂停 /
///   继续各报一次，暂停期间不报；上一条还没回来时不叠新的进度。
library;

import 'dart:async';
import 'dart:io' show HandshakeException, HttpException, SocketException;
import 'dart:math';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http show ClientException;

import 'package:fushi_engine/media/music/server/music_server.dart';

import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_player_engine.dart';
import 'package:fushi/src/media/music/server/music_server_track_ref.dart';

/// 进度上报的最小间隔。
const Duration kMusicServerProgressInterval = Duration(seconds: 10);

/// 退出时等最后一条停止上报的上限（不拖住退出）。
const Duration kMusicServerFlushTimeout = Duration(seconds: 3);

/// 播放项 → 服务器曲目（app 装配：`MusicServerTrackResolver.resolve`）。
typedef MusicServerTrackLookup =
    Future<MusicServerResolvedTrack?> Function(MusicPlayItem item);

/// 连不上服务器一类的错误（离线）。传输层自己包过的（Jellyfin 的 transport 异常）由 app 装配
/// 时经 `isUnreachable` 补进来。
bool musicServerReportUnreachable(Object e) =>
    e is SocketException ||
    e is TimeoutException ||
    e is HandshakeException ||
    e is HttpException ||
    e is http.ClientException;

/// 上报失败的日志出口（app 装配：`ErrorLogService`）。
typedef MusicServerReportErrorSink = void Function(Object error, StackTrace st);

/// 一次听够门槛、却没送达服务器的播放（app 装配：记进离线补发队列）。
typedef MusicServerUndeliveredPlay =
    Future<void> Function(MusicServerTrackRef ref, int playedAtMs);

/// 一次播放（开播到换下）。
class _Play {
  _Play({
    required this.item,
    required this.sessionId,
    required this.startedAtMs,
  });

  final MusicPlayItem item;
  final String sessionId;
  final int startedAtMs;

  /// 放的是离线副本（本机文件）：服务器连不上时静默。
  bool get offlineCopy =>
      !item.path.startsWith('http://') && !item.path.startsWith('https://');

  /// 认出来的服务器曲目（认不出 / 不支持上报为 null，此后什么都不发）。
  Future<
    ({MusicServerPlaybackReporting server, MusicServerResolvedTrack ref})?
  >?
  target;

  /// [target] 已落地且可上报（同步判断用：进度 / 暂停只在它之后才发）。
  bool ready = false;

  /// 有一条上报失败过：这次播放不再发任何上报。
  bool failed = false;

  /// 失败的原因是连不上服务器（或认服务器时出错）：计次没送达时入离线队列。
  bool unreachable = false;

  /// 开播 / 停止上报送达了服务器。
  bool startDelivered = false;
  bool stopDelivered = false;

  /// 这次播放有一条上报送达过（只通知一次 [MusicServerPlaybackReporter._onDelivered]）。
  bool delivered = false;

  /// 有一条进度上报还在路上。
  bool progressInFlight = false;
  bool paused = false;
  DateTime? lastProgressAt;
}

class MusicServerPlaybackReporter {
  MusicServerPlaybackReporter({
    required MusicPlayerEngine engine,
    required MusicServerTrackLookup lookup,
    MusicServerReportErrorSink? onError,
    void Function()? onTargetFailure,
    DateTime Function()? now,
    String Function()? sessionIds,
    bool Function(Object error)? isUnreachable,
    MusicServerUndeliveredPlay? onUndelivered,
    void Function(MusicServerBrowser server)? onDelivered,
  }) : _engine = engine,
       _onUndelivered = onUndelivered,
       _onDelivered = onDelivered,
       _isUnreachable = isUnreachable ?? musicServerReportUnreachable,
       _lookup = lookup,
       _onError = onError,
       _onTargetFailure = onTargetFailure,
       _now = now ?? DateTime.now,
       _sessionIds = sessionIds ?? _randomSessionId;

  final MusicPlayerEngine _engine;
  final MusicServerTrackLookup _lookup;
  final MusicServerReportErrorSink? _onError;

  /// 上报失败时调用（app 装配成让解析器下次重读服务器配置：令牌可能换了）。
  final void Function()? _onTargetFailure;
  final DateTime Function() _now;
  final String Function() _sessionIds;
  final bool Function(Object error) _isUnreachable;
  final MusicServerUndeliveredPlay? _onUndelivered;
  final void Function(MusicServerBrowser server)? _onDelivered;

  static final Random _random = Random.secure();

  static String _randomSessionId() {
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 16; i++) {
      b.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return b.toString();
  }

  _Play? _play;

  /// 串行发送队列：同一次播放的开始 / 进度 / 停止按提交顺序到达服务器。
  Future<void> _queue = Future<void>.value();

  /// 测试用：等已提交的上报全部发完。
  Future<void> get idle => _queue;

  /// 一首开始播（引擎 `onTrackStarted`）。
  void trackStarted(MusicPlayItem item) {
    final _Play? prev = _play;
    if (prev != null) {
      _finish(prev, _engine.listenedBeforeStart, prev.item.durationMs);
    }
    if (!musicServerTrackCandidate(
      item.trackUid,
      item.path,
      serverTrack: item.serverTrack,
    )) {
      _play = null;
      return;
    }
    final _Play play = _Play(
      item: item,
      sessionId: _sessionIds(),
      startedAtMs: _now().millisecondsSinceEpoch,
    );
    // 开播上报本身就带位置：第一条心跳从开播起算一个间隔。
    play.lastProgressAt = _now();
    _play = play;
    play.target = _resolve(play);
    _enqueue(play, (
      MusicServerPlaybackReporting s,
      MusicServerResolvedTrack r,
    ) {
      final int pos = identical(_play, play)
          ? _engine.position.inMilliseconds
          : 0;
      return s
          .reportPlaybackStarted(_report(play, r, pos))
          .then((_) => play.startDelivered = true);
    });
  }

  /// 一首被换下（引擎 `onTrackLeft`）：报停止。后端自然推进（听完）时报曲长，让服务器按
  /// 播完结算（交叉淡入推进时位置停在淡入起点）。
  void trackLeft(MusicTrackLeave leave) {
    final _Play? play = _play;
    if (play == null || play.item.trackUid != leave.item.trackUid) return;
    _play = null;
    final Duration? duration = leave.duration;
    _finish(
      play,
      leave.completed && duration != null ? duration : leave.position,
      duration?.inMilliseconds ?? play.item.durationMs,
    );
  }

  /// 引擎状态变了（约 10 Hz 的位置推送也走这里）：暂停 / 继续各报一次；在播时按间隔报
  /// 进度。
  void engineChanged() {
    final _Play? play = _play;
    if (play == null || !play.ready || play.failed) return;
    if (_engine.startedItem?.trackUid != play.item.trackUid) return;
    final bool paused = !_engine.isPlaying;
    final DateTime now = _now();
    MusicServerPlaybackEvent? event;
    if (paused != play.paused) {
      play.paused = paused;
      event = paused
          ? MusicServerPlaybackEvent.pause
          : MusicServerPlaybackEvent.unpause;
    } else if (paused ||
        play.progressInFlight ||
        now.difference(play.lastProgressAt!) < kMusicServerProgressInterval) {
      return;
    }
    play.lastProgressAt = now;
    play.progressInFlight = true;
    final int pos = _engine.position.inMilliseconds;
    _enqueue(
      play,
      (MusicServerPlaybackReporting s, MusicServerResolvedTrack r) => s
          .reportPlaybackProgress(_report(play, r, pos), event: event)
          .whenComplete(() => play.progressInFlight = false),
    );
  }

  /// 退出 / 进后台被杀前：把正在播的这一首报停止并等发完（至多
  /// [kMusicServerFlushTimeout]）。
  Future<void> flush() async {
    final _Play? play = _play;
    if (play != null) {
      _play = null;
      _finish(
        play,
        _engine.position,
        _engine.duration?.inMilliseconds ?? play.item.durationMs,
      );
    }
    await _queue.timeout(kMusicServerFlushTimeout, onTimeout: () {});
  }

  void _finish(_Play play, Duration? position, int? durationMs) {
    final int pos = (position ?? Duration.zero).inMilliseconds;
    _enqueue(
      play,
      (MusicServerPlaybackReporting s, MusicServerResolvedTrack r) => s
          .reportPlaybackStopped(_report(play, r, pos))
          .then((_) => play.stopDelivered = true),
    );
    _queue = _queue.then((_) => _settle(play, pos, durationMs));
  }

  /// 一次播放结束、它的上报都发完之后：听够门槛而计次那条没到服务器（连不上 / 这台设备上没有
  /// 那台服务器的配置）时交给离线补发队列。
  Future<void> _settle(_Play play, int positionMs, int? durationMs) async {
    final MusicServerUndeliveredPlay? undelivered = _onUndelivered;
    if (undelivered == null || play.item.isPreview) return;
    if (!musicScrobbleThresholdReached(positionMs, durationMs)) return;
    final ({MusicServerPlaybackReporting server, MusicServerResolvedTrack ref})?
    target = await play.target;
    final MusicServerTrackRef? ref = target?.ref.ref ?? play.item.serverTrack;
    if (ref == null) return;
    if (target != null) {
      final Object server = target.server;
      final bool counted = server is MusicServerPlayMarking
          ? (server.countsPlayOnStart
                ? play.startDelivered
                : play.stopDelivered)
          : true;
      // 服务器回了错误（不是连不上）：照旧只记日志，不补发。
      if (counted || !play.unreachable) return;
    }
    try {
      await undelivered(ref, play.startedAtMs);
    } on Object catch (e, st) {
      _onError?.call(e, st);
    }
  }

  Future<({MusicServerPlaybackReporting server, MusicServerResolvedTrack ref})?>
  _resolve(_Play play) async {
    try {
      final MusicServerResolvedTrack? ref = await _lookup(play.item);
      final MusicServerBrowser? b = ref?.browser;
      if (ref == null || b is! MusicServerPlaybackReporting) return null;
      play.ready = true;
      return (server: b as MusicServerPlaybackReporting, ref: ref);
    } on Object catch (e, st) {
      // 认不出服务器（读配置出错）：这次播放不上报，计次交给离线队列（[_settle]）。
      play.failed = true;
      play.unreachable = true;
      _onError?.call(e, st);
      return null;
    }
  }

  MusicServerPlaybackReport _report(
    _Play play,
    MusicServerResolvedTrack ref,
    int positionMs,
  ) => MusicServerPlaybackReport(
    trackId: ref.trackId,
    playSessionId: play.sessionId,
    positionMs: positionMs < 0 ? 0 : positionMs,
    startedAtMs: play.startedAtMs,
    durationMs: _engine.duration != null && identical(_play, play)
        ? _engine.duration!.inMilliseconds
        : play.item.durationMs,
    paused: play.paused,
    transcoded: ref.transcoded,
  );

  void _enqueue(
    _Play play,
    Future<void> Function(
      MusicServerPlaybackReporting server,
      MusicServerResolvedTrack ref,
    )
    send,
  ) {
    _queue = _queue.then((_) async {
      final ({
        MusicServerPlaybackReporting server,
        MusicServerResolvedTrack ref,
      })?
      target = await play.target;
      if (target == null || play.failed) return;
      try {
        await send(target.server, target.ref);
        if (!play.delivered) {
          play.delivered = true;
          _onDelivered?.call(target.ref.browser);
        }
      } on Object catch (e, st) {
        // 只记第一次失败；这次播放后面的上报都不再发。
        play.failed = true;
        if (_isUnreachable(e)) {
          play.unreachable = true;
          if (play.offlineCopy) {
            // 离线听下载的曲目：服务器不在是常态，不记错、不让解析器重读配置。
            debugPrint(
              '[music-report] server unreachable (offline copy); '
              'a completed play will be queued',
            );
            return;
          }
        }
        _onTargetFailure?.call();
        _onError?.call(e, st);
      }
    });
  }
}
