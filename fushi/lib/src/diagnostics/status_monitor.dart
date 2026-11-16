// 状态监测（设置 › 诊断 › 状态监测，及可选的全局悬浮小窗）：实时看本进程 CPU、内存、
// 帧耗时与 UI 线程卡顿，排查「为什么卡」。
//
// 只在有人看的时候采样：状态页打开或悬浮小窗开着时 [StatusMonitor.acquire]，都关了就停
// 计时器、摘掉帧耗时回调——关着时零开销。
//
// 每秒一个采样点，历史保留 [kStatusMonitorHistoryLength] 个：
// - CPU：两次 [processCpuTimeMicros] 之差 ÷ 墙钟间隔 ÷ 核数（与 Windows 任务管理器同口径，
//   100% = 所有核跑满）；另给单核口径方便看「某个线程打满一核」。
// - 内存：进程 RSS（各平台）；Windows 另有私有提交与系统可用内存；Android 另有 malloc；
//   各平台都有 Flutter 解码图缓存。
// - 帧：本秒内实际渲染的帧数、超出刷新预算的卡顿帧数、最慢的构建 / 光栅耗时
//   （[SchedulerBinding.addTimingsCallback]，release 下同样可用）。Flutter 只在需要时出帧，
//   静止时帧数低是正常的，不是掉帧。
// - UI 线程延迟：1 s 周期计时器实际触发比预期晚了多少。主 isolate 被同步任务堵住时计时器
//   排不上队，这一项直接反映「点了没反应」那种卡。

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show ImageCache, PaintingBinding;
import 'package:flutter/scheduler.dart';
import 'package:fushi/src/diagnostics/native_heap_probe.dart';
import 'package:fushi/src/diagnostics/process_cpu_time.dart';
import 'package:fushi/src/diagnostics/windows_memory_probe.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 采样间隔。
const Duration kStatusMonitorInterval = Duration(seconds: 1);

/// 保留多少个历史采样点（= 秒数）。
const int kStatusMonitorHistoryLength = 120;

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

  /// 单核口径（100% = 一个核跑满）。
  double? get cpuPercentOfOneCore =>
      cpuPercent == null ? null : cpuPercent! * cores;
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
  });

  static StatusMonitorSources platform() => StatusMonitorSources(
    cpuMicros: processCpuTimeMicros,
    rssBytes: () => ProcessInfo.currentRss,
    windowsMemory: readWindowsMemory,
    nativeHeapMb: nativeHeapAllocatedMb,
    imageCache: () => PaintingBinding.instance.imageCache,
    cores: Platform.numberOfProcessors,
    refreshRate: _currentRefreshRate,
  );

  final int? Function() cpuMicros;
  final int Function() rssBytes;
  final WindowsMemoryReading? Function() windowsMemory;
  final int? Function() nativeHeapMb;
  final ImageCache Function() imageCache;
  final int cores;
  final double Function() refreshRate;
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
  final List<(int, int)> _pendingFrames = <(int, int)>[];
  Timer? _timer;
  int _holders = 0;
  int? _lastCpuMicros;
  int _lastTickMicros = 0;

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
    _lastTickMicros = _now();
    _lastCpuMicros = _readCpu();
    _pendingFrames.clear();
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    _timer = Timer.periodic(kStatusMonitorInterval, (_) => sample());
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    _pendingFrames.clear();
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

  /// 采一个点（周期计时器调用；测试里直接调）。
  @visibleForTesting
  void sample() {
    final StatusMonitorSources src = _src;
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

    final double rate = src.refreshRate();
    final int budgetMicros = (1000000 / rate).round();
    final FrameWindowStats frames = summarizeFrames(
      _pendingFrames,
      budgetMicros: budgetMicros,
    );
    _pendingFrames.clear();

    final ImageCache cache = src.imageCache();
    _history.addLast(
      StatusSample(
        time: DateTime.now(),
        cpuPercent: cpuPercent,
        cores: src.cores,
        rssBytes: src.rssBytes(),
        privateBytes: win?.privateBytes,
        nativeHeapMb: heap,
        systemAvailBytes: win?.availPhysBytes,
        systemTotalBytes: win?.totalPhysBytes,
        imageCacheBytes: cache.currentSizeBytes,
        imageCacheLive: cache.liveImageCount,
        frames: frames,
        frameBudgetMs: budgetMicros / 1000,
        uiLagMs: lagMs,
      ),
    );
    while (_history.length > kStatusMonitorHistoryLength) {
      _history.removeFirst();
    }
    notifyListeners();
  }

  /// 把当前历史写成纯文本（复制给开发者用）。
  String describeHistory() {
    final StringBuffer b = StringBuffer()
      ..writeln(
        'time cpu% rssMB privMB heapMB sysAvailMB imgMB frames jank '
        'buildMaxMs rasterMaxMs uiLagMs',
      );
    String two(int v) => v.toString().padLeft(2, '0');
    String mb(int? bytes) => bytes == null ? '-' : '${bytes >> 20}';
    for (final StatusSample s in _history) {
      b.writeln(
        <String>[
          '${two(s.time.hour)}:${two(s.time.minute)}:${two(s.time.second)}',
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
        ].join(' '),
      );
    }
    return b.toString();
  }

  /// 测试收尾：停采样、清历史与持有计数。
  @visibleForTesting
  void resetForTest() {
    if (_timer != null) _stop();
    _holders = 0;
    _history.clear();
    _overlayEnabled = false;
    _corner = StatusMonitorOverlayCorner.topRight;
  }
}
