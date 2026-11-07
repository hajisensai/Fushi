import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:fushi/src/media/video/video_playback_source.dart';
import 'package:fushi/src/media/video/video_study_accrual_arbiter.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi/src/stats/study_diag_log.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 浏览器扩展 `POST /api/extension/study` 的一条播放样本（网页视频的沉浸时间进
/// 学习统计）。扩展在视频播放时每 ~1s、以及 play / pause / seek / ended 时刻各发
/// 一条；app 侧原样喂给 [VideoWatchTracker]（与本地 / 网页档视频页同一采集器、
/// 同一墙钟口径，见 [BrowserVideoStudyBridge]）。
///
/// 字段契约（[tryParse] 校验，任一不合即整条丢弃）：
///  * `mediaKind`：目前只接受 `'video'`；
///  * `mediaKey`：非空字符串，扩展已加 `web:` 前缀，app 侧**原样**用作
///    `study_segments.media_key`（不再加前缀）；
///  * `title`：字符串，可空串（缺省当空串；空串时展示用 [mediaKey] 兜底）；
///  * `positionMs`：整数 ≥ 0；`durationMs`：整数或 null（直播 Infinity 时扩展发 null）；
///  * `playing`：bool；`speed`：数字 > 0（缺省 1.0）；
///  * `ended`：bool（缺省 false；true = 页面卸载 / 换视频，立刻停表）；
///  * `cue`：null 或 `{index, startMs, endMs, text}`——此刻 Fushi 在页面上出的那一句
///    （视频轴，已套用户的时轴偏移）。缺省 / null = 没有在出字幕，不计字（反馈
///    jk4rTLHPZ_：此前契约里没有这一项，网页视频的字幕字数恒为 0）。
class BrowserVideoSample {
  const BrowserVideoSample({
    required this.mediaKey,
    required this.title,
    required this.positionMs,
    required this.durationMs,
    required this.playing,
    required this.speed,
    required this.ended,
    this.cue,
  });

  final String mediaKey;
  final String title;
  final int positionMs;
  final int? durationMs;
  final bool playing;
  final double speed;
  final bool ended;

  /// 此刻正在出的字幕句；null = 没有。
  final BrowserVideoCue? cue;

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
    final Object? rawCue = body['cue'];
    BrowserVideoCue? cue;
    if (rawCue != null) {
      cue = BrowserVideoCue.tryParse(rawCue);
      if (cue == null) return null;
    }
    return BrowserVideoSample(
      mediaKey: key,
      title: (title as String?) ?? '',
      positionMs: positionMs,
      durationMs: durationMs,
      playing: playing,
      speed: speed,
      ended: rawEnded == true,
      cue: cue,
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

/// 样本里「此刻正在出的那一句」（[BrowserVideoSample.cue]）。
@immutable
class BrowserVideoCue {
  const BrowserVideoCue({
    required this.index,
    required this.startMs,
    required this.endMs,
    required this.text,
  });

  /// 页面活动字幕轨里的句序。
  final int index;
  final int startMs;
  final int endMs;
  final String text;

  /// 一句字幕最多多长：再长就不是一句字幕（坏轨 / 恶意页面），整条样本按不合契约丢弃。
  static const int maxTextLength = 1000;

  static BrowserVideoCue? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final int? index = BrowserVideoSample._integerOf(raw['index']);
    final int? start = BrowserVideoSample._integerOf(raw['startMs']);
    final int? end = BrowserVideoSample._integerOf(raw['endMs']);
    final Object? text = raw['text'];
    if (index == null || index < 0) return null;
    if (start == null || end == null || start < 0 || end < start) return null;
    if (text is! String || text.length > maxTextLength) return null;
    return BrowserVideoCue(
      index: index,
      startMs: start,
      endMs: end,
      text: text,
    );
  }

  /// 给 [VideoWatchTracker] 用的 [AudioCue]（只填停留门读的起止与文本）。
  AudioCue toAudioCue() => AudioCue()
    ..bookKey = ''
    ..chapterHref = ''
    ..sentenceIndex = index
    ..textFragmentId = ''
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

/// 由扩展样本驱动的只读播放源：[VideoWatchTracker] 经 [VideoPlaybackSource] 接口
/// 采位置 / 播放态 / 倍速 / 当前句。当前句就是样本里页面正在出的那一句
/// （[BrowserVideoSample.cue]，已在视频轴上，所以 [subtitleDelayMs] 恒 0），字幕字数
/// 与视频页同一道停留门。每条样本 [apply] 后通知一次 = tracker 的一个采样点（与生产
/// controller 的 play / pause / seek / 换句通知同构）。
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
  int _cueIndex = -1;
  AudioCue? _cue;

  @override
  bool get isPlaying => _isPlaying;

  @override
  int get currentCueIndex => _cueIndex;

  @override
  AudioCue? get currentCue => _cue;

  /// 样本里的句已在视频轴上（页面套过用户的时轴偏移）。
  @override
  int get subtitleDelayMs => 0;

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
    final BrowserVideoCue? cue = sample.cue;
    _cueIndex = cue?.index ?? -1;
    _cue = cue?.toAudioCue();
    notifyListeners();
  }
}

/// 一条正在被统计的网页视频：tracker + 它的播放源 + 空闲计时器。
class _ActiveSession {
  _ActiveSession({
    required this.mediaKey,
    required this.tracker,
    required this.source,
    required this.claim,
  });

  final String mediaKey;
  final VideoWatchTracker tracker;
  final RemoteVideoPlaybackSource source;

  /// 本会话在视频跨面入账仲裁里的登记（时钟 `isActive` 读它），会话结束即释放。
  final VideoStudyAccrualClaim claim;
  Timer? idle;
}

/// 浏览器扩展视频沉浸时间 → 学习统计的桥（新写入面 = 新的 [StudyClock] 实例，
/// 不是新表；`docs/agent/statistics.md`「写入面」）。
///
/// 每个 `mediaKey` 一个 [VideoWatchTracker]（墙钟时钟，2026-11-07 取代「只计首次覆盖」：
/// 时长 = 会话存活期间的实际时间；覆盖并集仍按 [videoWatchCoveragePrefKey] 偏好持久化，
/// 只给字幕字数去重——与本地 / 网页档视频页同一装配，统计语义不因播放宿主是浏览器而
/// 分叉）。
///
/// **同一时刻至多一条在计时**（[_active] 只有一个）：换 `mediaKey` 先封上一条再开新的，
/// 所以两个标签页同时放视频也不会两份墙钟叠加——后发样本的那条抢走计时、前一条封段
/// （来回抢会切碎段，但时长不重复）。样本 `ended` 或超过 [idleTimeout] 没有新样本
/// （暂停后扩展不再发样本 / 页面被关 / 扩展断连、没来得及发 ended）即停表释放。
///
/// 暂停的取舍：扩展只在播放中每 ~1s 发样本、暂停那一刻发一条，此后静默——app 侧无从
/// 知道用户是不是还在页面前查词。所以暂停后的时间按会话存活计、最多 [idleTimeout]
/// （默认 20s），之后停表；再播放开新会话。代价：标签页被直接关掉又没发出 `ended` 时，
/// 最后 ≤ [idleTimeout] 的空档也被计入。网页视频没有库条目：完成标记 no-op、不报
/// 单集完成。
///
/// 与 app 内视频同时在播：时长只一边入账，裁决归 [VideoStudyAccrualArbiter]（本 app
/// 持有焦点且 app 内视频在计时 → app 内入账、这里不入账；否则这里入账）。字幕字数
/// 两边照常各自计。
class BrowserVideoStudyBridge {
  BrowserVideoStudyBridge({
    required FushiDatabase Function() database,
    DateTime Function()? now,
    this.idleTimeout = const Duration(seconds: 20),
    VideoStudyAccrualArbiter? arbiter,
  }) : _database = database,
       _now = now ?? DateTime.now,
       _arbiter = arbiter ?? VideoStudyAccrualArbiter.instance;

  /// 延迟取库：注入点在 [AppModel] 建 server manager 时，那时 `database` 已开；
  /// 仍用闭包而不是直接持有实例，避免把 late getter 的求值时机提前到构造期。
  final FushiDatabase Function() _database;
  final DateTime Function() _now;
  final VideoStudyAccrualArbiter _arbiter;

  /// 这么久没有新样本就当页面已关 / 扩展断连，停表释放。扩展播放中每 ~1s 一条，
  /// 20s 足够宽（网络抖动 / 标签页被节流）又不至于把关掉的页面挂着不封段。
  final Duration idleTimeout;

  _ActiveSession? _active;

  /// 已发起但尚未完成的停表写链（换 key / 空闲 / ended 触发的 stop），[stopAll]
  /// 统一 await，保证进程退出前最后一笔落库完成。
  Future<void> _stopChain = Future<void>.value();

  /// 测试钩子：新 tracker 建好（attach + start + 起表之前）时回调，供注入受控墙钟
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
    final RemoteVideoPlaybackSource source = RemoteVideoPlaybackSource(
      now: _now,
    );
    // settle 在 tracker 建好后才有对象可结算；登记先于时钟，时钟的 isActive 读它。
    VideoWatchTracker? created;
    final VideoStudyAccrualClaim claim = _arbiter.claim(
      surface: VideoStudySurface.browser,
      settle: () => created?.clock.flushNow(),
    );
    final VideoWatchTracker tracker = VideoWatchTracker(
      bookUid: key,
      clock: StudyClock(
        database: db,
        mediaKind: kActivityMediaVideo,
        mediaKey: key,
        title: sample.displayTitle,
        // 不设空闲门：会话本身由 [idleTimeout] 收口（无新样本即停表），播放中的
        // 样本也经 tracker 的采样 touch；再叠一道 10 分钟门没有意义。
        // 与 app 内视频同时播放时只一边入账时长（[VideoStudyAccrualArbiter]）。
        isActive: () => claim.timeAllowed,
        now: _now,
        onWriteError: (Object e, StackTrace st) => ErrorLogService.instance.log(
          'StudyClock.write(browser-video)',
          e,
          st,
        ),
      ),
      loadCoverage: () => db.getPref(videoWatchCoveragePrefKey(key)),
      saveCoverage: (String json) =>
          db.setPref(videoWatchCoveragePrefKey(key), json),
    );
    created = tracker;
    debugOnTrackerCreated?.call(tracker);
    tracker
      ..attach(source)
      ..start();
    // tracker.start() 只起采样；浏览器桥没有页面遮挡 / 生命周期可言（扩展只在页面
    // 播放时发样本），会话存活即计时。
    tracker.clock.start();
    claim.update(running: true);
    final _ActiveSession session = _ActiveSession(
      mediaKey: key,
      tracker: tracker,
      source: source,
      claim: claim,
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
    // 先离场再停表：stop 的最后一窗仍按离场前的结论结算（release 只重算别的面）。
    session.claim.release();
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
