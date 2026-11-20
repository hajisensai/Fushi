// 状态监测（设置 › 诊断 › 状态监测，及可选的全局悬浮小窗）：实时看本进程 CPU、内存、
// 帧耗时与 UI 线程卡顿，以及**是谁在占用**，排查「为什么卡」。
//
// 只在有人看的时候采样：状态页打开或悬浮小窗开着时 [StatusMonitor.acquire]，都关了就停
// 计时器、摘掉帧耗时回调——关着时零开销。
//
// 每秒一个采样点，历史保留 [kStatusMonitorHistoryLength] 个：
// - CPU：两次 [processCpuTimeMicros] 之差 ÷ 墙钟间隔 ÷ 核数（与 Windows 任务管理器同口径，
//   100% = 所有核跑满）；另给单核口径方便看「某个线程打满一核」。
// - 各线程 CPU：[readThreadCpuTimes] 两次读数之差按线程组汇总（[summarizeThreadCpu]），
//   回答「CPU 是谁吃的」——UI 线程、光栅、mpv、Rust 核心、Dart 后台 isolate。读一次要遍历
//   全部线程，放后台 isolate。
// - 内存：进程 RSS（各平台）；Windows 另有私有提交与系统可用内存；Android 另有 malloc；
//   各平台都有 Flutter 解码图缓存；另附已有子系统探针读数（SRS 原生内核、anon/file/shm）。
// - 帧：本秒内实际渲染的帧数、超出刷新预算的卡顿帧数、最慢的构建 / 光栅耗时
//   （[SchedulerBinding.addTimingsCallback]，release 下同样可用）。Flutter 只在需要时出帧，
//   静止时帧数低是正常的，不是掉帧。
// - UI 线程延迟：1 s 周期计时器实际触发比预期晚了多少。主 isolate 被同步任务堵住时计时器
//   排不上队，这一项直接反映「点了没反应」那种卡。
//
// 卡顿记录：某一秒判为卡顿（[isStutterSample]）时，额外扫一遍 widget 树记下当时的可见页面与
// 活跃动画（[scanUiActivity]），连同最忙的线程存进 [StatusMonitor.stutters]。开着悬浮小窗正常
// 使用，卡了再回状态页就能看到卡在哪一页、谁在占 CPU。

import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show ImageCache, PaintingBinding;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:fushi/src/diagnostics/native_heap_probe.dart';
import 'package:fushi/src/diagnostics/previous_exit_log.dart'
    show processRssBreakdownProbe;
import 'package:fushi/src/diagnostics/process_cpu_time.dart';
import 'package:fushi/src/diagnostics/thread_cpu_sampler.dart';
import 'package:fushi/src/diagnostics/ui_activity_probe.dart';
import 'package:fushi/src/diagnostics/windows_memory_probe.dart';
import 'package:fushi/src/srs/srs_memory_probe.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 采样间隔。
const Duration kStatusMonitorInterval = Duration(seconds: 1);

/// 保留多少个历史采样点（= 秒数）。
const int kStatusMonitorHistoryLength = 120;

/// 保留多少条卡顿记录。
const int kStatusMonitorStutterLimit = 50;

/// 每个采样点保留几个最忙的线程组。
const int kStatusMonitorTopThreads = 8;

/// 悬浮小窗所在角落。
enum StatusMonitorOverlayCorner { topLeft, topRight, bottomLeft, bottomRight }

/// 一秒内的帧耗时汇总。
@immutable
class FrameWindowStats {
  const FrameWindowStats({
    required this.frames,
    required this.jankFrames,
    required this.worstBuildMs,
    required this.worstRasterMs,
  });

  static const FrameWindowStats empty = FrameWindowStats(
    frames: 0,
    jankFrames: 0,
    worstBuildMs: 0,
    worstRasterMs: 0,
  );

  /// 本窗口内实际渲染的帧数。
  final int frames;

  /// 构建或光栅任一项超出单帧预算的帧数。
  final int jankFrames;

  /// 最慢一帧的 UI 线程构建耗时（毫秒）。
  final double worstBuildMs;

  /// 最慢一帧的光栅线程耗时（毫秒）。
  final double worstRasterMs;
}

/// 把一批帧耗时（构建、光栅，微秒）汇总成 [FrameWindowStats]。[budgetMicros] 是单帧预算
/// （1e6 / 刷新率）；构建或光栅任一项超出即算一帧卡顿。
FrameWindowStats summarizeFrames(
  Iterable<(int buildMicros, int rasterMicros)> frames, {
  required int budgetMicros,
}) {
  int count = 0;
  int jank = 0;
  int worstBuild = 0;
  int worstRaster = 0;
  for (final (int build, int raster) in frames) {
    count++;
    if (build > budgetMicros || raster > budgetMicros) jank++;
    if (build > worstBuild) worstBuild = build;
    if (raster > worstRaster) worstRaster = raster;
  }
  return FrameWindowStats(
    frames: count,
    jankFrames: jank,
    worstBuildMs: worstBuild / 1000,
    worstRasterMs: worstRaster / 1000,
  );
}

/// CPU 占用百分比（所有核合计 = 100%）。任一读数缺失、墙钟没前进或 [cores] 非正时返回
/// null；计数回退（不应发生）按 0 处理。
double? computeCpuPercent({
  required int? previousCpuMicros,
  required int? currentCpuMicros,
  required int wallMicros,
  required int cores,
}) {
  if (previousCpuMicros == null || currentCpuMicros == null) return null;
  if (wallMicros <= 0 || cores <= 0) return null;
  final int delta = currentCpuMicros - previousCpuMicros;
  if (delta <= 0) return 0;
  return delta / wallMicros / cores * 100;
}

/// 一个采样点。取不到的项为 null。
@immutable
class StatusSample {
  const StatusSample({
    required this.time,
    required this.cpuPercent,
    required this.cores,
    required this.rssBytes,
    required this.privateBytes,
    required this.nativeHeapMb,
    required this.systemAvailBytes,
    required this.systemTotalBytes,
    required this.imageCacheBytes,
    required this.imageCacheLive,
    required this.frames,
    required this.frameBudgetMs,
    required this.uiLagMs,
    this.threads = const <ThreadGroupUsage>[],
    this.memoryNotes = const <String>[],
  });

  final DateTime time;

  /// 所有核合计口径（100% = 全部核跑满）。
  final double? cpuPercent;
  final int cores;
  final int rssBytes;

  /// Windows 进程私有提交。
  final int? privateBytes;

  /// Android malloc 已分配。
  final int? nativeHeapMb;

  /// Windows 系统可用物理内存 / 总物理内存。
  final int? systemAvailBytes;
  final int? systemTotalBytes;
  final int imageCacheBytes;
  final int imageCacheLive;
  final FrameWindowStats frames;
  final double frameBudgetMs;

  /// 周期计时器比预期晚触发的毫秒数（UI 线程被堵住的时长）。
  final int uiLagMs;

  /// 本秒最忙的线程组（单核口径降序，最多 [kStatusMonitorTopThreads] 个）；平台不支持或
  /// 还没有上一次读数时为空。
  final List<ThreadGroupUsage> threads;

  /// 已有子系统探针的原始读数（SRS 原生内核、anon/file/shm……），取不到的不列。
  final List<String> memoryNotes;

  /// 单核口径（100% = 一个核跑满）。
  double? get cpuPercentOfOneCore =>
      cpuPercent == null ? null : cpuPercent! * cores;
}

/// 这一秒算不算卡顿：UI 线程被堵 ≥100 ms，或有一帧构建 / 光栅 ≥50 ms（肉眼可见的顿），
/// 或一秒内 ≥5 帧超预算（持续掉帧）。
bool isStutterSample(StatusSample s) =>
    s.uiLagMs >= 100 ||
    math.max(s.frames.worstBuildMs, s.frames.worstRasterMs) >= 50 ||
    s.frames.jankFrames >= 5;

/// 一条卡顿记录：卡顿那一秒的采样，加上当时的可见页面（外层在前）与活跃动画持有者。
@immutable
class StutterEvent {
  const StutterEvent({
    required this.sample,
    required this.pages,
    required this.tickers,
  });

  final StatusSample sample;
  final List<String> pages;

  /// widget 类型名 → 活跃 ticker 数（动画在跑就会逐帧出帧）。
  final Map<String, int> tickers;
}

/// 采样所需的平台读数，测试里替换。
@immutable
class StatusMonitorSources {
  const StatusMonitorSources({
    required this.cpuMicros,
    required this.rssBytes,
    required this.windowsMemory,
    required this.nativeHeapMb,
    required this.imageCache,
    required this.cores,
    required this.refreshRate,
    this.threadTimes,
    this.uiActivity,
    this.memoryNotes,
  });

  static StatusMonitorSources platform() => StatusMonitorSources(
    cpuMicros: processCpuTimeMicros,
    rssBytes: () => ProcessInfo.currentRss,
    windowsMemory: readWindowsMemory,
    nativeHeapMb: nativeHeapAllocatedMb,
    imageCache: () => PaintingBinding.instance.imageCache,
    cores: Platform.numberOfProcessors,
    refreshRate: _currentRefreshRate,
    threadTimes: _platformThreadTimes(),
    uiActivity: () => scanUiActivity(WidgetsBinding.instance.rootElement),
    memoryNotes: _platformMemoryNotes,
  );

  final int? Function() cpuMicros;
  final int Function() rssBytes;
  final WindowsMemoryReading? Function() windowsMemory;
  final int? Function() nativeHeapMb;
  final ImageCache Function() imageCache;
  final int cores;
  final double Function() refreshRate;

  /// 各线程累计 CPU（后台读）；null = 不读。
  final Future<List<ThreadCpuTime>> Function()? threadTimes;

  /// 当前可见页面与活跃动画（只在卡顿那一秒调用）；null = 不扫。
  final UiActivitySnapshot Function()? uiActivity;

  /// 子系统内存读数；null = 不读。
  final List<String> Function()? memoryNotes;
}

/// 在主 isolate 上取一次自身线程 id（= UI 线程），后台 isolate 读线程时据此标出 UI 线程。
Future<List<ThreadCpuTime>> Function() _platformThreadTimes() {
  final int? ui = currentThreadId();
  return () => Isolate.run(() => readThreadCpuTimes(uiThreadId: ui));
}

List<String> _platformMemoryNotes() {
  final List<String> out = <String>[];
  for (final String? Function() probe in <String? Function()>[
    processRssBreakdownProbe,
    srsMemoryProbe,
  ]) {
    try {
      final String? v = probe();
      if (v != null && v.isNotEmpty) out.add(v);
    } on Object {
      // 原生库不可用等：这一项不列。
    }
  }
  return out;
}

double _currentRefreshRate() {
  final double rate =
      SchedulerBinding
          .instance
          .platformDispatcher
          .views
          .firstOrNull
          ?.display
          .refreshRate ??
      60;
  return rate > 0 ? rate : 60;
}

/// 状态监测的采样器 + 悬浮小窗偏好。
class StatusMonitor extends ChangeNotifier {
  /// [nowMicros] 是单调时钟（微秒），测试里替换；默认取一个常驻运行的 [Stopwatch]。
  StatusMonitor({StatusMonitorSources? sources, int Function()? nowMicros})
    : _sources = sources {
    _now = nowMicros ?? () => _watch.elapsedMicroseconds;
  }

  static final StatusMonitor instance = StatusMonitor();

  static const String _overlayKey = 'status_monitor_overlay_enabled';
  static const String _cornerKey = 'status_monitor_overlay_corner';

  StatusMonitorSources? _sources;
  StatusMonitorSources get _src => _sources ??= StatusMonitorSources.platform();
  final Stopwatch _watch = Stopwatch()..start();
  late final int Function() _now;

  final ListQueue<StatusSample> _history = ListQueue<StatusSample>();
  final ListQueue<StutterEvent> _stutters = ListQueue<StutterEvent>();
  final List<(int, int)> _pendingFrames = <(int, int)>[];
  Timer? _timer;
  int _holders = 0;
  int? _lastCpuMicros;
  int _lastTickMicros = 0;
  List<ThreadCpuTime>? _lastThreads;
  int _lastThreadMicros = 0;
  bool _sampling = false;

  /// 每次开始采样加一：停掉又重开后，上一轮还在后台读的线程结果作废。
  int _generation = 0;

  bool _overlayEnabled = false;
  StatusMonitorOverlayCorner _corner = StatusMonitorOverlayCorner.topRight;

  /// 悬浮小窗是否开着（持久化）。
  bool get overlayEnabled => _overlayEnabled;

  /// 悬浮小窗所在角落（持久化）。
  StatusMonitorOverlayCorner get overlayCorner => _corner;

  /// 是否正在采样。
  bool get running => _timer != null;

  /// 历史采样点，旧在前。
  List<StatusSample> get history => List<StatusSample>.unmodifiable(_history);

  /// 卡顿记录，新在前。
  List<StutterEvent> get stutters =>
      List<StutterEvent>.unmodifiable(_stutters.toList().reversed);

  /// 最近一个采样点；还没采过为 null。
  StatusSample? get latest => _history.isEmpty ? null : _history.last;

  /// 启动时读一次偏好；悬浮小窗开着就直接开始采样。
  Future<void> init() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _overlayEnabled = prefs.getBool(_overlayKey) ?? false;
    final int cornerIndex =
        prefs.getInt(_cornerKey) ?? StatusMonitorOverlayCorner.topRight.index;
    _corner =
        StatusMonitorOverlayCorner.values[cornerIndex.clamp(
          0,
          StatusMonitorOverlayCorner.values.length - 1,
        )];
    if (_overlayEnabled) acquire();
    notifyListeners();
  }

  /// 开 / 关悬浮小窗。
  Future<void> setOverlayEnabled(bool value) async {
    if (value == _overlayEnabled) return;
    _overlayEnabled = value;
    if (value) {
      acquire();
    } else {
      release();
    }
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_overlayKey, value);
  }

  /// 改悬浮小窗角落。
  Future<void> setOverlayCorner(StatusMonitorOverlayCorner corner) async {
    if (corner == _corner) return;
    _corner = corner;
    notifyListeners();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_cornerKey, corner.index);
  }

  /// 清空卡顿记录。
  void clearStutters() {
    if (_stutters.isEmpty) return;
    _stutters.clear();
    notifyListeners();
  }

  /// 有人要看：第一个持有者到来时开始采样。与 [release] 成对调用。
  void acquire() {
    _holders++;
    if (_holders == 1) _start();
  }

  /// 不看了：最后一个持有者离开时停止采样（历史保留，下次打开还能看到之前的曲线）。
  void release() {
    if (_holders == 0) return;
    _holders--;
    if (_holders == 0) _stop();
  }

  void _start() {
    _generation++;
    _lastTickMicros = _now();
    _lastCpuMicros = _readCpu();
    _lastThreads = null;
    _pendingFrames.clear();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(kStatusMonitorInterval, (_) => sample());
    unawaited(_readThreads(_generation));
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _pendingFrames.clear();
    _lastThreads = null;
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final FrameTiming t in timings) {
      _pendingFrames.add((
        t.buildDuration.inMicroseconds,
        t.rasterDuration.inMicroseconds,
      ));
    }
  }

  int? _readCpu() {
    try {
      return _src.cpuMicros();
    } on Object {
      return null;
    }
  }

  /// 读一次各线程 CPU，与上一次比出各线程组占用；第一次（或读失败）返回空表。
  Future<List<ThreadGroupUsage>> _readThreads(int generation) async {
    final Future<List<ThreadCpuTime>> Function()? read = _src.threadTimes;
    if (read == null) return const <ThreadGroupUsage>[];
    final List<ThreadCpuTime> now;
    try {
      now = await read();
    } on Object {
      return const <ThreadGroupUsage>[];
    }
    if (generation != _generation) return const <ThreadGroupUsage>[];
    final int t = _now();
    final List<ThreadCpuTime>? before = _lastThreads;
    final int wall = t - _lastThreadMicros;
    _lastThreads = now;
    _lastThreadMicros = t;
    if (before == null) return const <ThreadGroupUsage>[];
    final List<ThreadGroupUsage> all = summarizeThreadCpu(
      before,
      now,
      wallMicros: wall,
    );
    return all.length <= kStatusMonitorTopThreads
        ? all
        : all.sublist(0, kStatusMonitorTopThreads);
  }

  /// 采一个点（周期计时器调用；测试里直接调）。上一次还没采完（后台读线程未返回）时跳过。
  @visibleForTesting
  Future<void> sample() async {
    if (_sampling) return;
    _sampling = true;
    try {
      await _sample();
    } finally {
      _sampling = false;
    }
  }

  Future<void> _sample() async {
    final StatusMonitorSources src = _src;
    final int generation = _generation;
    final int nowMicros = _now();
    final int wall = nowMicros - _lastTickMicros;
    final int lagMs = ((wall - kStatusMonitorInterval.inMicroseconds) / 1000)
        .round()
        .clamp(0, 1 << 31);
    _lastTickMicros = nowMicros;

    final int? cpu = _readCpu();
    final double? cpuPercent = computeCpuPercent(
      previousCpuMicros: _lastCpuMicros,
      currentCpuMicros: cpu,
      wallMicros: wall,
      cores: src.cores,
    );
    _lastCpuMicros = cpu;

    WindowsMemoryReading? win;
    try {
      win = src.windowsMemory();
    } on Object {
      win = null;
    }
    int? heap;
    try {
      heap = src.nativeHeapMb();
    } on Object {
      heap = null;
    }
    List<String> notes = const <String>[];
    try {
      notes = src.memoryNotes?.call() ?? const <String>[];
    } on Object {
      notes = const <String>[];
    }

    final double rate = src.refreshRate();
    final int budgetMicros = (1000000 / rate).round();
    final FrameWindowStats frames = summarizeFrames(
      _pendingFrames,
      budgetMicros: budgetMicros,
    );
    _pendingFrames.clear();
    final ImageCache cache = src.imageCache();
    final int rss = src.rssBytes();
    final DateTime time = DateTime.now();

    final List<ThreadGroupUsage> threads = await _readThreads(generation);
    // 后台读线程期间被停掉（关页 / 关小窗）：这一点不要了。
    if (generation != _generation || !running) return;

    final StatusSample sample = StatusSample(
      time: time,
      cpuPercent: cpuPercent,
      cores: src.cores,
      rssBytes: rss,
      privateBytes: win?.privateBytes,
      nativeHeapMb: heap,
      systemAvailBytes: win?.availPhysBytes,
      systemTotalBytes: win?.totalPhysBytes,
      imageCacheBytes: cache.currentSizeBytes,
      imageCacheLive: cache.liveImageCount,
      frames: frames,
      frameBudgetMs: budgetMicros / 1000,
      uiLagMs: lagMs,
      threads: threads,
      memoryNotes: notes,
    );
    _history.addLast(sample);
    while (_history.length > kStatusMonitorHistoryLength) {
      _history.removeFirst();
    }
    if (isStutterSample(sample)) _recordStutter(sample);
    notifyListeners();
  }

  void _recordStutter(StatusSample sample) {
    UiActivitySnapshot? ui;
    try {
      ui = _src.uiActivity?.call();
    } on Object {
      ui = null;
    }
    _stutters.addLast(
      StutterEvent(
        sample: sample,
        pages: ui?.pages ?? const <String>[],
        tickers: ui?.tickers ?? const <String, int>{},
      ),
    );
    while (_stutters.length > kStatusMonitorStutterLimit) {
      _stutters.removeFirst();
    }
  }

  /// 把当前历史与卡顿记录写成纯文本（复制给开发者用）。
  String describeHistory() {
    final StringBuffer b = StringBuffer()
      ..writeln(
        'time cpu% rssMB privMB heapMB sysAvailMB imgMB frames jank '
        'buildMaxMs rasterMaxMs uiLagMs threads(1core%)',
      );
    for (final StatusSample s in _history) {
      b.writeln(_describeSample(s));
    }
    if (_stutters.isNotEmpty) {
      b.writeln('\nstutters:');
      for (final StutterEvent e in _stutters) {
        b.writeln(
          '${_hms(e.sample.time)} lag=${e.sample.uiLagMs}ms '
          'jank=${e.sample.frames.jankFrames} '
          'build=${e.sample.frames.worstBuildMs.toStringAsFixed(1)}ms '
          'raster=${e.sample.frames.worstRasterMs.toStringAsFixed(1)}ms '
          'page=[${e.pages.join('>')}] '
          'tick=[${e.tickers.isEmpty ? '' : describeTickerOwners(e.tickers)}] '
          'threads=[${describeThreadGroups(e.sample.threads)}]',
        );
      }
    }
    final StatusSample? last = latest;
    if (last != null && last.memoryNotes.isNotEmpty) {
      b.writeln('\nmemory: ${last.memoryNotes.join(' ')}');
    }
    return b.toString();
  }

  static String _hms(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static String _describeSample(StatusSample s) {
    String mb(int? bytes) => bytes == null ? '-' : '${bytes >> 20}';
    return <String>[
      _hms(s.time),
      s.cpuPercent?.toStringAsFixed(1) ?? '-',
      mb(s.rssBytes),
      mb(s.privateBytes),
      s.nativeHeapMb?.toString() ?? '-',
      mb(s.systemAvailBytes),
      mb(s.imageCacheBytes),
      '${s.frames.frames}',
      '${s.frames.jankFrames}',
      s.frames.worstBuildMs.toStringAsFixed(1),
      s.frames.worstRasterMs.toStringAsFixed(1),
      '${s.uiLagMs}',
      '[${describeThreadGroups(s.threads, max: 3)}]',
    ].join(' ');
  }

  /// 测试收尾：停采样、清历史与持有计数。
  @visibleForTesting
  void resetForTest() {
    if (_timer != null) _stop();
    _holders = 0;
    _history.clear();
    _stutters.clear();
    _overlayEnabled = false;
    _corner = StatusMonitorOverlayCorner.topRight;
  }
}

/// `1.ui 85%; 1.raster 30%; DartWorker×4 12%`：线程组单核口径占用。
String describeThreadGroups(List<ThreadGroupUsage> groups, {int max = 8}) =>
    groups
        .take(max)
        .map(
          (ThreadGroupUsage g) =>
              '${g.group.isEmpty ? '?' : g.group}'
              '${g.threads > 1 ? '×${g.threads}' : ''} '
              '${g.percentOfOneCore.toStringAsFixed(0)}%',
        )
        .join('; ');
