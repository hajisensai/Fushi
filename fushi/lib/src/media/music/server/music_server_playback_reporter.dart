/// 服务器曲目的播放上报（Jellyfin `/Sessions/Playing*`、Subsonic `scrobble`）：播放次数、
/// 最近播放、服务器仪表盘的「正在播放」由服务器自己统计。
///
/// 接在 `MusicSession` 的曲目生命周期上（开播 [trackStarted] / 换下 [trackLeft] / 引擎
/// 状态变化 [engineChanged]），所以单曲循环重播、无缝推进、停止都按一次播放算。
/// - 只上报服务器曲目：播放项经 [MusicServerTrackResolver] 认回服务器与曲目 id（从服务器
///   页、曲库里的服务器曲目、最近播放重播都一样），本地 / 插件 / 网络来源曲目认不出就什么
///   都不发；
/// - 不挡播放：全部请求在后台串行队列里发，失败只记一次日志；这一首的开播上报失败后，后面
///   的进度 / 停止都不再发（不在断网时每 10 秒刷一次错）；
/// - 不刷屏：进度按 [kMusicServerProgressInterval]（与 Jellyfin web 同一档）节流，暂停 /
///   继续各报一次，暂停期间不报；上一条还没回来时不叠新的进度。
library;

import 'dart:async';
import 'dart:math';

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
    Future<MusicServerTrackRef?> Function(MusicPlayItem item);

/// 上报失败的日志出口（app 装配：`ErrorLogService`）。
typedef MusicServerReportErrorSink = void Function(Object error, StackTrace st);

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

  /// 认出来的服务器曲目（认不出 / 不支持上报为 null，此后什么都不发）。
  Future<({MusicServerPlaybackReporting server, MusicServerStreamRef ref})?>?
  target;

  /// [target] 已落地且可上报（同步判断用：进度 / 暂停只在它之后才发）。
  bool ready = false;

  /// 有一条上报失败过：这次播放不再发任何上报。
  bool failed = false;

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
  }) : _engine = engine,
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
    if (prev != null) _finish(prev, _engine.listenedBeforeStart);
    if (!musicServerTrackCandidate(item.trackUid, item.path)) {
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
    _enqueue(play, (MusicServerPlaybackReporting s, MusicServerStreamRef r) {
      final int pos = identical(_play, play)
          ? _engine.position.inMilliseconds
          : 0;
      return s.reportPlaybackStarted(_report(play, r, pos));
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
      (MusicServerPlaybackReporting s, MusicServerStreamRef r) => s
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
      _finish(play, _engine.position);
    }
    await _queue.timeout(kMusicServerFlushTimeout, onTimeout: () {});
  }

  void _finish(_Play play, Duration? position) {
    final int pos = (position ?? Duration.zero).inMilliseconds;
    _enqueue(
      play,
      (MusicServerPlaybackReporting s, MusicServerStreamRef r) =>
          s.reportPlaybackStopped(_report(play, r, pos)),
    );
  }

  Future<({MusicServerPlaybackReporting server, MusicServerStreamRef ref})?>
  _resolve(_Play play) async {
    try {
      final MusicServerTrackRef? ref = await _lookup(play.item);
      final MusicServerBrowser? b = ref?.browser;
      if (ref == null || b is! MusicServerPlaybackReporting) return null;
      play.ready = true;
      return (server: b as MusicServerPlaybackReporting, ref: ref.stream);
    } on Object catch (e, st) {
      play.failed = true;
      _onError?.call(e, st);
      return null;
    }
  }

  MusicServerPlaybackReport _report(
    _Play play,
    MusicServerStreamRef ref,
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
      MusicServerStreamRef ref,
    )
    send,
  ) {
    _queue = _queue.then((_) async {
      final ({MusicServerPlaybackReporting server, MusicServerStreamRef ref})?
      target = await play.target;
      if (target == null || play.failed) return;
      try {
        await send(target.server, target.ref);
      } on Object catch (e, st) {
        // 只记第一次失败；这次播放后面的上报都不再发。
        play.failed = true;
        _onTargetFailure?.call();
        _onError?.call(e, st);
      }
    });
  }
}
