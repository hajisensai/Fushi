import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi/src/stats/study_diag_log.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 浏览器扩展 `POST /api/extension/study` 的一条播放样本（网页视频的沉浸时间进
/// 学习统计）。扩展在视频播放时每 ~1s、以及 play / pause / seek / ended 时刻各发
/// 一条；app 侧原样喂给 [VideoWatchTracker]（与本地 / 网页档视频页同一采集器、
/// 同一「只计首次覆盖」口径，BUG-2108）。
///
/// 字段契约（[tryParse] 校验，任一不合即整条丢弃）：
///  * `mediaKind`：目前只接受 `'video'`；
///  * `mediaKey`：非空字符串，扩展已加 `web:` 前缀，app 侧**原样**用作
///    `study_segments.media_key`（不再加前缀）；
///  * `title`：字符串，可空串（缺省当空串；空串时展示用 [mediaKey] 兜底）；
///  * `positionMs`：整数 ≥ 0；`durationMs`：整数或 null（直播 Infinity 时扩展发 null）；
///  * `playing`：bool；`speed`：数字 > 0（缺省 1.0）；
///  * `ended`：bool（缺省 false；true = 页面卸载 / 换视频，立刻停表）。
class BrowserVideoSample {
  const BrowserVideoSample({
    required this.mediaKey,
    required this.title,
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.speed,
    required this.ended,
  });

  final String mediaKey;
  final String title;
  final int positionMs;
  final int? durationMs;
  final bool playing;
  final double speed;
  final bool ended;

  /// 统计里的显示标题：扩展拿不到页面标题时用 [mediaKey] 兜底，不落空串。
  String get displayTitle => title.isEmpty ? mediaKey : title;

  /// 从请求体解析；任一字段不合契约返回 null（调用方回 400）。
  static BrowserVideoSample? tryParse(Map<String, dynamic> body) {
    if (body['mediaKind'] != 'video') return null;
    final Object? key = body['mediaKey'];
    if (key is! String || key.isEmpty) return null;
    final Object? title = body['title'];
    if (title != null && title is! String) return null;
    final int? positionMs = _integerOf(body['positionMs']);
    if (positionMs == null || positionMs < 0) return null;
    final Object? rawDuration = body['durationMs'];
    int? durationMs;
    if (rawDuration != null) {
      durationMs = _integerOf(rawDuration);
      if (durationMs == null || durationMs < 0) return null;
    }
    final Object? playing = body['playing'];
    if (playing is! bool) return null;
    final Object? rawSpeed = body['speed'];
    double speed = 1.0;
    if (rawSpeed != null) {
      if (rawSpeed is! num || !rawSpeed.isFinite || rawSpeed <= 0) return null;
      speed = rawSpeed.toDouble();
    }
    final Object? rawEnded = body['ended'];
    if (rawEnded != null && rawEnded is! bool) return null;
    return BrowserVideoSample(
      mediaKey: key,
      title: (title as String?) ?? '',
      positionMs: positionMs,
      durationMs: durationMs,
      playing: playing,
      speed: speed,
      ended: rawEnded == true,
    );
  }

  /// JSON 数字 → 整数：int 原样；double 只接受有限且为整数值的（`12345.0`，JS 侧
  /// `Math.round` 后经某些序列化器仍可能带 `.0`）；其它一律 null。
  static int? _integerOf(Object? raw) {
    if (raw is int) return raw;
    if (raw is double && raw.isFinite && raw == raw.roundToDouble()) {
      return raw.toInt();
    }
    return null;
  }
}

/// 由扩展样本驱动的只读播放源：[VideoWatchTracker] 经 [VideoPlaybackSource] 接口
/// 采位置 / 播放态 / 倍速；网页视频没有 app 侧字幕轨，cue 恒空（字幕字数不计）。
/// 每条样本 [apply] 后通知一次 = tracker 的一个采样点（与生产 controller 的
/// play / pause / seek 通知同构）。
class RemoteVideoPlaybackSource extends ChangeNotifier
    implements VideoPlaybackSource {
  RemoteVideoPlaybackSource({DateTime Function()? now})
      : _now = now ?? DateTime.now;

  final DateTime Function() _now;
  bool _isPlaying = false;
  int? _positionMs;
  int? _durationMs;
  double _speed = 1.0;
  DateTime? _appliedAt;

  @override
  bool get isPlaying => _isPlaying;

  @override
  int get currentCueIndex => -1;

  @override
  AudioCue? get currentCue => null;

  /// 播放中按「上条样本位置 + 经过墙钟 × 倍速」外推，与 app 内 controller 的活位置
  /// 同语义。没有这条时 tracker 每秒的定时采样读到的是静态快照：位置没变 → 该窗
  /// 不记，但墙钟基准已被挪到 tick 时刻；下一条扩展样本只剩 tick→样本那截墙钟，
  /// 两个 1s 定时器的相位差决定每窗记 0%~100%，期望只记到四成左右。
  @override
  int? get positionMs {
    final int? base = _positionMs;
    final DateTime? at = _appliedAt;
    if (base == null || at == null || !_isPlaying) return base;
    final int elapsedMs = _now().difference(at).inMilliseconds;
    if (elapsedMs <= 0) return base;
    final double rate = _speed > 0 ? _speed : 1.0;
    final int extrapolated = base + (elapsedMs * rate).round();
    final int? duration = _durationMs;
    if (duration != null && duration > 0 && extrapolated > duration) {
      return duration;
    }
    return extrapolated;
  }

  @override
  int? get durationMs => _durationMs;

  @override
  double get speed => _speed;

  /// 用最新样本覆盖状态并通知监听者。`ended` 样本按「已暂停」落状态：停表由
  /// [BrowserVideoStudyBridge] 负责，这里只保证最后一次采样不再把窗口算成在播。
  void apply(BrowserVideoSample sample) {
    _isPlaying = sample.playing && !sample.ended;
    _positionMs = sample.positionMs;
    _durationMs = sample.durationMs;
    _speed = sample.speed;
    _appliedAt = _now();
    notifyListeners();
  }
}

/// 一条正在被统计的网页视频：tracker + 它的播放源 + 空闲计时器。
class _ActiveSession {
  _ActiveSession({
    required this.mediaKey,
    required this.tracker,
    required this.source,
  });

  final String mediaKey;
  final VideoWatchTracker tracker;
  final RemoteVideoPlaybackSource source;
  Timer? idle;
}

/// 浏览器扩展视频沉浸时间 → 学习统计的桥（新写入面 = 新的 [StudyClock] 实例，
/// 不是新表；`docs/agent/statistics.md`「写入面」）。
///
/// 每个 `mediaKey` 一个 [VideoWatchTracker]（`StudyAccrual.explicit`、只计首次覆盖，
/// 覆盖并集按 [videoWatchCoveragePrefKey] 偏好持久化——与本地 / 网页档视频页同一
/// 装配，统计语义不因播放宿主是浏览器而分叉）。换 `mediaKey` 先封上一条再开新的；
/// 样本 `ended` 或超过 [idleTimeout] 没有新样本（页面被关 / 扩展断连、没来得及发
/// ended）即停表释放。网页视频没有库条目：完成标记 no-op、不报单集完成。
class BrowserVideoStudyBridge {
  BrowserVideoStudyBridge({
    required FushiDatabase Function() database,
    DateTime Function()? now,
    this.idleTimeout = const Duration(seconds: 20),
  })  : _database = database,
        _now = now ?? DateTime.now;

  /// 延迟取库：注入点在 [AppModel] 建 server manager 时，那时 `database` 已开；
  /// 仍用闭包而不是直接持有实例，避免把 late getter 的求值时机提前到构造期。
  final FushiDatabase Function() _database;
  final DateTime Function() _now;

  /// 这么久没有新样本就当页面已关 / 扩展断连，停表释放。扩展播放中每 ~1s 一条，
  /// 20s 足够宽（网络抖动 / 标签页被节流）又不至于把关掉的页面挂着不封段。
  final Duration idleTimeout;

  _ActiveSession? _active;

  /// 已发起但尚未完成的停表写链（换 key / 空闲 / ended 触发的 stop），[stopAll]
  /// 统一 await，保证进程退出前最后一笔落库完成。
  Future<void> _stopChain = Future<void>.value();

  /// 测试钩子：新 tracker 建好（attach + start 之前）时回调，供注入受控墙钟
  /// （`debugNowForTesting`）/ 等覆盖加载。
  @visibleForTesting
  void Function(VideoWatchTracker tracker)? debugOnTrackerCreated;

  /// 当前正在统计的 mediaKey（测试 / 诊断）。
  @visibleForTesting
  String? get debugActiveMediaKey => _active?.mediaKey;

  /// 处理一条扩展样本（端点已鉴权、已解析）。同步入口：换 key / 停表的落库在
  /// 后台写链上串行进行，不阻塞 HTTP 响应。
  void onSample(BrowserVideoSample sample) {
    _ActiveSession? session = _active;
    if (session != null && session.mediaKey != sample.mediaKey) {
      _stopSession(session, reason: 'switch → ${sample.mediaKey}');
      session = null;
    }
    if (sample.ended) {
      // 只对「正在统计的那条」停表；没开过的 ended（页面开了没播就关）什么也不做，
      // 不为它建一条零时长的段。
      if (session != null) {
        session.source.apply(sample);
        _stopSession(session, reason: 'ended');
      }
      return;
    }
    session ??= _startSession(sample);
    session.source.apply(sample);
    _armIdle(session);
  }

  /// 进程退出 / server 停止：封掉正在统计的段并等最后一笔写完成。可重复调用。
  Future<void> stopAll() async {
    final _ActiveSession? session = _active;
    if (session != null) _stopSession(session, reason: 'stopAll');
    await _stopChain;
  }

  _ActiveSession _startSession(BrowserVideoSample sample) {
    final FushiDatabase db = _database();
    final String key = sample.mediaKey;
    final RemoteVideoPlaybackSource source =
        RemoteVideoPlaybackSource(now: _now);
    final VideoWatchTracker tracker = VideoWatchTracker(
      bookUid: key,
      clock: StudyClock(
        database: db,
        mediaKind: kActivityMediaVideo,
        mediaKey: key,
        title: sample.displayTitle,
        accrual: StudyAccrual.explicit,
        now: _now,
        onWriteError: (Object e, StackTrace st) => ErrorLogService.instance
            .log('StudyClock.write(browser-video)', e, st),
      ),
      loadCoverage: () => db.getPref(videoWatchCoveragePrefKey(key)),
      saveCoverage: (String json) =>
          db.setPref(videoWatchCoveragePrefKey(key), json),
      // 网页视频没有库条目：无处标「看完」。
      markCompleted: (_) async {},
    );
    debugOnTrackerCreated?.call(tracker);
    tracker
      ..attach(source)
      ..start();
    final _ActiveSession session = _ActiveSession(
      mediaKey: key,
      tracker: tracker,
      source: source,
    );
    _active = session;
    studyDiag('browser-video', 'start $key title=${sample.displayTitle}');
    return session;
  }

  void _stopSession(_ActiveSession session, {required String reason}) {
    if (identical(_active, session)) _active = null;
    session.idle?.cancel();
    session.idle = null;
    studyDiag('browser-video', 'stop ${session.mediaKey} ($reason)');
    _stopChain = _stopChain.then((_) async {
      try {
        await session.tracker.stop();
      } catch (e, st) {
        // fail-open：停表落库失败不影响后续样本开新段；写失败本身已由
        // StudyClock.onWriteError 记录，这里兜的是 stop 链上的其它异常。
        ErrorLogService.instance.log('BrowserVideoStudyBridge.stop', e, st);
      }
      session.tracker.dispose();
      session.source.dispose();
    });
  }

  void _armIdle(_ActiveSession session) {
    session.idle?.cancel();
    session.idle = Timer(idleTimeout, () {
      if (!identical(_active, session)) return;
      _stopSession(session, reason: 'idle ${idleTimeout.inSeconds}s');
    });
  }
}
