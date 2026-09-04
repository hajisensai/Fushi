import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:fushi_core/fushi_core.dart';

/// 单个 tick 允许的最大连续窗口。学习时长由 [StudyClock] 的 60s 定时器驱动，正常窗口
/// ≈ 60s。超过此上限说明定时器跨越了**非连续前台窗口**（app 后台挂起 / 系统睡眠 /
/// 熄屏 / 长 GC 停顿致定时器被冻结后一次性补发），该段用户是否真在学习未知，整窗丢弃。
///
/// 阅读侧此前缺失，导致整夜后台挂起被一次性计入阅读时长（BUG-892）；视频侧的
/// `kMaxWatchGap` 与本常量同值同义，v92 起统一只剩这一个。
const Duration kMaxReadingGap = Duration(seconds: 120);

/// 「到达即计」治理的统一停留门（BUG-1761 漫画 / BUG-1763 视频）。
///
/// 产品裁定：到达 ≠ 读过 / 看过。三个域各自的机制不同（EPUB 按字数水位 + 速度封顶、
/// 漫画按当前页停留、视频按 cue 的真实播放停留），但「多久才算停留过」是同一条产品
/// 判据，只应有一个数。此前漫画的 `_kPageDwellThreshold` 与视频的 `kCueDwellMs` 是两
/// 个互不相干的 1500 字面量——同值不同名，正是日后必漂的形状。
///
/// 用毫秒 int 而不是 Duration：`Duration.inMilliseconds` 是 getter、不能 const 求值，
/// 而消费端两侧一个要 int、一个要 Duration，只有 int 能让两边都真正引用同一个数
/// （`Duration(milliseconds: kArrivalDwellMs)` 仍是 const）。
const int kArrivalDwellMs = 1500;

/// 阅读空闲门默认值：这么久没有任何输入（翻页 / 滚动 / 查词 / 听书播放态）就视为
/// 没在读，之后的 tick 不入账。用户可在设置里改（偏好键见 [kStudyIdleTimeoutPrefKey]）。
/// 只对阅读面生效；视频面以播放态为准（切走仍在播就照常计时，用户拍板）。
const Duration kDefaultReadingIdleTimeout = Duration(minutes: 10);

/// 阅读空闲门的偏好键（分钟，int 字符串；缺省 = [kDefaultReadingIdleTimeout]）。
const String kStudyIdleTimeoutPrefKey = 'stats_reading_idle_timeout_minutes';

/// 纯谓词：[start]..[now] 是否是一次正常的连续窗口。
///
/// 过滤异常大间隔（见 [kMaxReadingGap]）：返回 false 时调用方应整窗丢弃、不累加时长，
/// 避免把后台挂起 / 熄屏 / 睡眠时长凭空计入。同时保证 [splitReadingTime] 永远只看到
/// ≤ [kMaxReadingGap] 的输入——单次至多跨一个小时/天边界，其单边界拆桶假设始终成立。
bool isContinuousReadingGap(DateTime start, DateTime now) {
  final Duration d = now.difference(start);
  return d > Duration.zero && d <= kMaxReadingGap;
}

/// 把 [start]..[now] 的时长按小时/天边界拆成 (dateKey, hour, ms) 桶。
///
/// 抽成纯函数便于单测。调用方须先用 [isContinuousReadingGap] 门控，保证输入
/// ≤ [kMaxReadingGap]（单次至多跨一个边界，单边界拆桶假设成立）。
List<(String, int, int)> splitReadingTime(DateTime start, DateTime now) {
  final int elapsed = now.difference(start).inMilliseconds;
  if (elapsed <= 0) return const <(String, int, int)>[];
  if (start.hour != now.hour || start.day != now.day) {
    final DateTime boundary = hourBoundaryAfter(start);
    final int firstMs = boundary.difference(start).inMilliseconds;
    final int secondMs = now.difference(boundary).inMilliseconds;
    return <(String, int, int)>[
      if (firstMs > 0)
        (FushiDatabase.statDateKeyOf(start), start.hour, firstMs),
      if (secondMs > 0) (FushiDatabase.statDateKeyOf(now), now.hour, secondMs),
    ];
  }
  return <(String, int, int)>[
    (FushiDatabase.statDateKeyOf(start), start.hour, elapsed),
  ];
}

/// [t] 所在小时之后的第一个整点（本地时区）。段边界 / 拆桶共用。
DateTime hourBoundaryAfter(DateTime t) =>
    DateTime(t.year, t.month, t.day, t.hour + 1);

/// 落库回调：v92 起所有学习时长 / 字数 / 页数只经 [FushiDatabase.upsertStudySegment]
/// 一个口进 `study_segments`；抽成 typedef 是给纯单测注入 fake。
typedef StudySegmentSink = Future<void> Function(StudySegmentsCompanion row);

/// [StudyClock] 的时长来源。
enum StudyAccrual {
  /// 墙钟窗口：每个 tick 把 `[上次 tick, now]` 整窗计入（经断档 / 活跃态 / 空闲三道
  /// 守卫）。阅读 / 漫画 / PDF 面用——「页面开着、没空闲」就是在读。
  wallClock,

  /// 显式记账：时长只由消费方经 [StudyClock.addActiveMs] 推入，tick 不再按墙钟计。
  /// 视频面用（BUG-2108）：观看时长 = 位置推进到**首次覆盖**的片内区间所花的墙钟
  /// 时间，由 `VideoWatchTracker` 按 1s 采样位置算出；回放 / 拖回 / 重看不推、不计。
  /// 此前视频面按 tick 末刻 `isPlaying` 整窗计——一个 20s 回放可能记 60s 也可能记
  /// 0s，且重听照计。
  explicit,
}

/// 当前打开的段：内存里的**绝对值**累计器，每次 tick 原样写回同一 [uid]。
class _OpenSegment {
  _OpenSegment({
    required this.uid,
    required this.startAt,
    required this.dateKey,
    required this.hour,
  }) : endAt = startAt;

  final String uid;
  final DateTime startAt;
  final String dateKey;
  final int hour;
  DateTime endAt;
  int durationMs = 0;
  int chars = 0;
  int pages = 0;

  /// 有未落库的改动。写失败保持 true，下个 tick 用绝对值重写——重试不会翻倍。
  bool dirty = false;
}

/// 学习时长 / 字数 / 页数的**唯一计时器**（v92 统计域重构）。
///
/// 取代 `ReadingTimeTracker`（阅读小时桶）+ `VideoWatchTracker` 的计时部分 + 各页面
/// 自己持有的 `_sessionReadingMs` / `_sessionCharsRead` 会话累计器：三处各算各的账正是
/// BUG-1052 / BUG-1107 那类「时长被重锚吃掉 / 字数与时长分叉」的形状。现在只有一个时钟、
/// 一个累计器（[_open]）、一种写法（绝对值 upsert）。
///
/// 段（segment）的生命周期：首个被接受的 tick 打开一段（新 uid）→ 每个 tick 把绝对值
/// 写回同一 uid → 遇到 [stop] / 小时边界 / 任一守卫拒绝 tick 就封段（丢引用），下一个
/// 被接受的 tick 开新段。重复 flush = 同 uid 同值 = no-op；两条并发 [stop]（dispose 与
/// 进程退出）第二条见 `_open == null` 直接返回——幂等在结构上成立，不靠标志位。
///
/// 三道守卫（任一拒绝即整窗丢弃 + 封段）：
///  * 断档：[isContinuousReadingGap]（BUG-892，睡眠 / 挂起后的补发 tick）；
///  * 活跃态：[isActive]（视频 = 正在播放；阅读 / 游戏不传 = 恒活跃，前台门由
///    生命周期的 stop/start 承担——桌面窗口失焦、移动端进后台都会 stop）；
///  * 空闲：[idleTimeout]（阅读面 10 分钟无 [touch] 即不入账；视频不设）。
///
/// 字数 / 页数经 [addChars] / [addPages] 记到当前打开段（没有就以 0 时长开一段），
/// 与时长同一行、同一 uid、同一次写。
class StudyClock {
  StudyClock({
    required FushiDatabase database,
    required String mediaKind,
    required String mediaKey,
    required String title,
    String format = '',
    this.accrual = StudyAccrual.wallClock,
    this.isActive,
    this.idleTimeout,
    this.onTick,
    this.onWriteError,
    Duration tick = const Duration(seconds: 60),
    StudySegmentSink? sink,
    Future<String> Function()? deviceId,
    DateTime Function()? now,
    String Function()? uidFactory,
  }) : assert(
         accrual == StudyAccrual.wallClock || (isActive == null && idleTimeout == null),
         '显式记账模式下活跃态 / 空闲门无意义：时长全由 addActiveMs 决定',
       ),
       _mediaKind = mediaKind,
       _mediaKey = mediaKey,
       _title = title,
       _format = format,
       _tick = tick,
       _sink = sink ?? database.upsertStudySegment,
       _deviceId = deviceId ?? database.getOrCreateStudyDeviceId,
       _now = now ?? DateTime.now,
       _uidFactory = uidFactory ?? FushiDatabase.newStudySegmentUid;

  final String _mediaKind;
  final String _mediaKey;
  final String _title;
  final String _format;
  final Duration _tick;
  final StudySegmentSink _sink;
  final Future<String> Function() _deviceId;
  final DateTime Function() _now;
  final String Function() _uidFactory;

  /// 时长来源（见 [StudyAccrual]）。
  final StudyAccrual accrual;

  /// 显式记账模式：本 tick 窗口内是否收到过 [addActiveMs]。没有 = 这一分钟没看新
  /// 内容（暂停 / 回放 / 拖动），与墙钟模式「守卫拒绝整窗」同律：封段，下次记账开新段。
  bool _creditedSinceTick = false;

  /// 活跃态判据（每个 tick 问一次，仅墙钟模式）。null = 恒活跃。
  bool Function()? isActive;

  /// 空闲门：距上次 [touch] 超过它的 tick 不入账。null = 不设（视频 / 游戏）。
  Duration? idleTimeout;

  /// 每个 tick（无论是否入账）后回调，给消费方挂周期性检查（视频完成判定）。
  void Function(DateTime now)? onTick;

  /// 落库失败回调（fail-open 之外的诊断出口）：本包不依赖 app 层的
  /// ErrorLogService，页面把它接上让 DB 写异常线上可查（BUG-911 纪律）。
  void Function(Object error, StackTrace stack)? onWriteError;

  Timer? _timer;
  DateTime? _tickStart;
  DateTime? _lastTouch;
  _OpenSegment? _open;
  String? _cachedDeviceId;

  /// 写链：绝对值写按时间序串行落地，防止旧 tick 的写晚于新 tick 落地把值倒回去。
  Future<void> _writeChain = Future<void>.value();

  /// 计时中（已 [start] 且未 [stop]）。停表期间恒 false，后台时长永不入账。
  bool get isRunning => _timer != null;

  /// 当前打开段的 uid（测试 / 诊断）。
  @visibleForTesting
  String? get debugOpenUid => _open?.uid;

  /// 当前打开段的累计（测试 / 诊断）。
  @visibleForTesting
  ({int durationMs, int chars, int pages})? get debugOpenTotals {
    final _OpenSegment? s = _open;
    if (s == null) return null;
    return (durationMs: s.durationMs, chars: s.chars, pages: s.pages);
  }

  void start() {
    if (_timer != null) return;
    final DateTime now = _now();
    _tickStart = now;
    _lastTouch ??= now;
    _timer = Timer.periodic(_tick, (_) => unawaited(_onTimer()));
  }

  /// 停表：先把「上一次 tick 到现在」的部分窗口结算进当前段，再封段落库。
  ///
  /// 返回的 Future 在最后一次 DB 写完成后才完成，供进程退出路径 await
  /// （TODO-086/BUG-191）。同步段（取值 / 清引用 / 取消定时器）全部在第一个 await
  /// 之前——并发的第二次 [stop] 看到的是已清空的状态，不会重复写。
  Future<void> stop() async {
    final Timer? timer = _timer;
    _timer = null;
    timer?.cancel();
    _accrue(_now());
    _tickStart = null;
    final _OpenSegment? seg = _open;
    _open = null;
    if (seg != null && seg.dirty && _worthWriting(seg)) _enqueueWrite(seg);
    await _writeChain;
  }

  void dispose() {
    unawaited(stop());
  }

  /// 用户输入（翻页 / 滚动 / 查词 / 听书播放态）：喂空闲门。
  void touch() {
    _lastTouch = _now();
  }

  /// 记字数到当前打开段（没有就开一段）。字数本身就是一次输入，顺带 [touch]。
  void addChars(int chars) {
    if (chars <= 0) return;
    touch();
    _ensureOpen(_now()).chars += chars;
    _open!.dirty = true;
  }

  /// 记页数到当前打开段（漫画 / PDF 翻页）。
  void addPages(int pages) {
    if (pages <= 0) return;
    touch();
    _ensureOpen(_now()).pages += pages;
    _open!.dirty = true;
  }

  /// 显式记账（仅 [StudyAccrual.explicit]）：把 [ms] 墙钟毫秒计到当前打开段（没有 /
  /// 已跨小时就开新段）。消费方按自己的采样节奏（≤ 1s 一次）推入，不会跨小时边界
  /// 拆分——单次记账最多几百毫秒，落在 `now` 所在小时即可。
  void addActiveMs(int ms) {
    assert(accrual == StudyAccrual.explicit, '墙钟模式的时长由 tick 结算，不许外推');
    if (ms <= 0) return;
    final DateTime now = _now();
    final _OpenSegment seg = _ensureOpen(now);
    seg.durationMs += ms;
    seg.endAt = now;
    seg.dirty = true;
    _creditedSinceTick = true;
  }

  /// 立刻结算当前部分窗口并落库（不停表、不封段）。页面在章导航 / 生命周期节点调用，
  /// 让「上一次 tick 到现在」这段不因随后的 dispose 而丢。
  Future<void> flushNow() async {
    _accrue(_now());
    final _OpenSegment? seg = _open;
    if (seg != null && seg.dirty && _worthWriting(seg)) _enqueueWrite(seg);
    await _writeChain;
  }

  Future<void> _onTimer() async {
    final DateTime now = _now();
    _accrue(now);
    final _OpenSegment? seg = _open;
    if (seg != null && seg.dirty && _worthWriting(seg)) _enqueueWrite(seg);
    onTick?.call(now);
    await _writeChain;
  }

  /// 把 [_tickStart]..[now] 的窗口按守卫结算进段（同步，不写库）。
  void _accrue(DateTime now) {
    final DateTime? start = _tickStart;
    if (start == null) return;
    // 零长度窗口（同一时刻连续 flushNow / stop）是 no-op，不是断档：不能封段，否则
    // 紧随其后的正常窗口会开新 uid 把一次阅读切碎。
    if (!now.isAfter(start)) return;
    _tickStart = now;
    if (accrual == StudyAccrual.explicit) {
      // 时长已由 addActiveMs 逐次推入；tick 只裁决段的生命周期：这一窗一次记账都
      // 没有 = 没在看新内容，封段（与墙钟模式守卫拒绝整窗同律）。
      if (!_creditedSinceTick) _seal();
      _creditedSinceTick = false;
      return;
    }
    final bool accepted =
        isContinuousReadingGap(start, now) &&
        (isActive?.call() ?? true) &&
        !_isIdle(now);
    if (!accepted) {
      // 整窗丢弃 + 封段：下一个被接受的窗口开新段（活动流按 30 分钟 gap 归并，
      // 封段不会把一次阅读拆成多条）。
      _seal();
      return;
    }
    DateTime bucketStart = start;
    for (final (String dateKey, int hour, int ms) in splitReadingTime(
      start,
      now,
    )) {
      _OpenSegment? seg = _open;
      if (seg == null || seg.dateKey != dateKey || seg.hour != hour) {
        _seal();
        seg = _openNew(bucketStart, dateKey, hour);
      }
      seg.durationMs += ms;
      seg.endAt = bucketStart.add(Duration(milliseconds: ms));
      seg.dirty = true;
      bucketStart = hourBoundaryAfter(start);
    }
  }

  bool _isIdle(DateTime now) {
    final Duration? timeout = idleTimeout;
    final DateTime? last = _lastTouch;
    if (timeout == null || last == null) return false;
    return now.difference(last) > timeout;
  }

  /// 当前打开段；没有或已跨小时 / 跨天（段不跨小时边界）就封旧开新。
  _OpenSegment _ensureOpen(DateTime now) {
    final String dateKey = FushiDatabase.statDateKeyOf(now);
    final _OpenSegment? seg = _open;
    if (seg != null && seg.dateKey == dateKey && seg.hour == now.hour) {
      return seg;
    }
    _seal();
    return _openNew(now, dateKey, now.hour);
  }

  _OpenSegment _openNew(DateTime startAt, String dateKey, int hour) {
    final _OpenSegment seg = _OpenSegment(
      uid: _uidFactory(),
      startAt: startAt,
      dateKey: dateKey,
      hour: hour,
    );
    _open = seg;
    return seg;
  }

  /// 封当前段：有脏数据先排队落库，然后丢引用。
  void _seal() {
    final _OpenSegment? seg = _open;
    if (seg == null) return;
    _open = null;
    if (seg.dirty && _worthWriting(seg)) _enqueueWrite(seg);
  }

  /// 落库门槛（与 v92 前各页面「<1s 且无内容账的段不记账」同一条判据）：不足 1 秒
  /// 又没有字数 / 页数的段是生命周期抖动（开书秒关、失焦回焦），不值一行；
  /// [flushNow] 下段仍开着、保持 dirty 留到下次，[stop] / 封段则直接丢弃。
  /// 这也让「打开页面立刻 dispose」的路径零 DB 写——测试 harness 的 FakeAsync 在
  /// teardown 后不再推进，dispose 里起的事务会把 `db.close()` 挂死。
  static bool _worthWriting(_OpenSegment seg) =>
      seg.durationMs >= 1000 || seg.chars > 0 || seg.pages > 0;

  void _enqueueWrite(_OpenSegment seg) {
    seg.dirty = false;
    final DateTime now = _now();
    _writeChain = _writeChain.then((_) => _write(seg, now)).catchError((
      Object e,
      StackTrace stack,
    ) {
      // fail-open：不冒泡、不阻塞阅读 / 播放；段留 dirty，下个 tick 用绝对值重写。
      seg.dirty = true;
      debugPrint('[study-clock] write error: $e\n$stack');
      onWriteError?.call(e, stack);
    });
  }

  Future<void> _write(_OpenSegment seg, DateTime now) async {
    final String deviceId = _cachedDeviceId ??= await _deviceId();
    await _sink(
      StudySegmentsCompanion(
        uid: Value(seg.uid),
        deviceId: Value(deviceId),
        mediaKind: Value(_mediaKind),
        mediaKey: Value(_mediaKey),
        format: Value(_format),
        title: Value(_title),
        startAt: Value(seg.startAt.millisecondsSinceEpoch),
        endAt: Value(seg.endAt.millisecondsSinceEpoch),
        dateKey: Value(seg.dateKey),
        hour: Value(seg.hour),
        durationMs: Value(seg.durationMs),
        chars: Value(seg.chars),
        pages: Value(seg.pages),
        updatedAt: Value(now.millisecondsSinceEpoch),
      ),
    );
  }
}
