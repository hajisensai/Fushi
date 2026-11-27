import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart' as widgets;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:integration_test/integration_test.dart';
import 'package:vm_service/vm_service.dart' as vm;

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';

/// 顶层 tab 切换耗时探针（本地测速用，profile 构建跑）。
///
/// 复现 2026-11-16 群反馈录屏「切 tab 变卡了」：侧栏指示器到位后正文那一帧卡
/// 130～420 ms。与应用同一条 `_selectTab` 切页（经 [homeShellTabNotifier]），收引擎 [FrameTiming]（build /
/// raster 分段、帧间空档）与 timeline 里 UI 线程最长的事件，以 `[tab-perf]`
/// 前缀打进日志。第 0 轮是各页首次挂载，之后几轮是回访（保活页只换 Offstage）：
/// 第 1 轮是首次回访（首页攒着的延后重载在这一轮落地），抓 build 剖析；第 2、4 轮
/// 不抓 timeline、只收帧时间（没有剖析开销，拿它们比修前修后）；第 3 轮抓 layout
/// 剖析。
///
/// 跑法同 `detail_open_perf_itest.dart`（数据根用安装版真实库的只读拷贝）：
///   FUSHI_TEST_HIDDEN=1 FUSHI_TEST_ONSCREEN=1
///   FUSHI_WEBVIEW2_USER_DATA_FOLDER=<测试根>/webview2
///   flutter drive --profile -d windows --no-pub
///     --driver=test_driver/integration_test.dart
///     --target=integration_test/home_tab_switch_perf_itest.dart
///     --dart-define=FUSHI_TEST_ROOT=<测试根>
///   可选：--dart-define=FUSHI_PERF_DUMP=<目录> 把抓到的 timeline 落成 JSON。
///   可选：--dart-define=FUSHI_PERF_DESIGN=glass 先切到玻璃设计再测（外壳大标题
///   不叠在内容上、标题栏高度按 tab 变的那条路径），测完还原。
///   可选：--dart-define=FUSHI_PERF_NO_TRACE=true 五轮都不抓 timeline。抓 timeline
///   的轮次里，录制窗口一关探针自己要在 UI isolate 上取回并解码整段 timeline
///   （首页那轮 4 MB），看门狗会把这段记成 400 ms 之后的阻塞；要量「首次回访」
///   不带剖析开销的真实帧时间与阻塞就用这个开关。
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('home tab switch timing', (WidgetTester tester) async {
    await launchFushiTestApp();
    // 不用 waitForHome：它只认 Material / Cupertino 导航根，玻璃设计的真实库认不出。
    expect(await _waitForHomePage(tester), isTrue);
    final AppModel appModel = await readyAppModel(tester);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    // 首页出来后先空等多久再开切（默认 3 s）。量「刚启动就切」用 0，与等 30 s
    // 对照，分得清首切慢是「各页首次挂载本身贵」还是「启动后台活抢 UI 线程」。
    const int warmupMs = int.fromEnvironment(
      'FUSHI_PERF_WARMUP_MS',
      defaultValue: 3000,
    );
    // 不切页、只看 UI 线程：首页出来后的这段时间里事件循环被堵了多少次、多久。
    const int idleProbeMs = int.fromEnvironment('FUSHI_PERF_IDLE_PROBE_MS');
    if (idleProbeMs > 0) {
      await _idleProbe(binding, idleProbeMs);
      if (const bool.fromEnvironment('FUSHI_PERF_IDLE_ONLY')) return;
    }
    await _wait(warmupMs);

    // `HomePage.debugSelectTab` 只在 debug 构建注册（assert）；profile 下走生产
    // 的共享 notifier，它同样落到 `_selectTab`（`_onShellTabRequested`）。
    void select(HomeTab tab) => homeShellTabNotifier.value = tab;
    // 导航里在用的全部 tab，按导航顺序：保活页（首页 / 书架 / 漫画 / 视频 /
    // 音乐 / 游戏 / 浏览）回访只换 Offstage，其余（查词 / 复习 / 网页 / 设置）
    // 切走即销毁、每次切回都整页重建。
    final List<HomeTab> tabs = homeActiveTabs(appModel.moduleVisibility);
    final Size physical = tester.view.physicalSize;
    const String design = String.fromEnvironment('FUSHI_PERF_DESIGN');
    const bool noTrace = bool.fromEnvironment('FUSHI_PERF_NO_TRACE');
    final String designBefore = appModel.themeNotifier.designSystem;
    if (design.isNotEmpty) {
      await appModel.themeNotifier.setDesignSystem(design);
      await _wait(2000);
    }
    debugPrint(
      '[tab-perf] tabs=${tabs.map((HomeTab t) => t.name).join(",")} '
      'size=${physical.width}x${physical.height} '
      'dpr=${tester.view.devicePixelRatio} '
      'design=${appModel.themeNotifier.designSystem} trace=${!noTrace}',
    );

    try {
      for (int round = 0; round < 5; round++) {
        for (final HomeTab tab in tabs) {
          await _measure(
            binding,
            'r$round/${tab.name}',
            () => select(tab),
            trace: !noTrace && (round == 0 || round == 1 || round == 3),
            profileLayout: round == 3,
          );
        }
      }
    } finally {
      if (design.isNotEmpty) {
        await appModel.themeNotifier.setDesignSystem(designBefore);
      }
    }
    debugPrint('[tab-perf] done');
  });
}

/// 首页出来后不做任何操作，按 1 s 分桶报 UI 线程被堵的次数与最长一次。
Future<void> _idleProbe(
  IntegrationTestWidgetsFlutterBinding binding,
  int totalMs,
) async {
  // 可选：从第几毫秒起录一段 1.5 s 的 GC + Dart timeline，看堵塞是谁。
  const int traceAt = int.fromEnvironment(
    'FUSHI_PERF_IDLE_TRACE_AT_MS',
    defaultValue: -1,
  );
  final int origin = developer.Timeline.now;
  final List<({int at, int late})> stalls = <({int at, int late})>[];
  int lastBeat = origin;
  final Timer watchdog = Timer.periodic(const Duration(milliseconds: 2), (_) {
    final int now = developer.Timeline.now;
    if (now - lastBeat > 20000) {
      stalls.add((at: lastBeat - origin, late: now - lastBeat));
    }
    lastBeat = now;
  });
  if (traceAt >= 0 && traceAt + 1500 < totalMs) {
    await _wait(traceAt);
    final vm.Timeline timeline = await binding.traceTimeline(
      () => _wait(1500),
      streams: const <String>['Dart', 'GC', 'API', 'Isolate'],
    );
    _printLongEvents('idle-trace', timeline);
    _printGc('idle-trace', timeline);
    const String dump = String.fromEnvironment('FUSHI_PERF_DUMP');
    if (dump.isNotEmpty) {
      File('$dump/idle.json').writeAsStringSync(jsonEncode(timeline.toJson()));
    }
    await _wait(totalMs - traceAt - 1500);
  } else {
    await _wait(totalMs);
  }
  watchdog.cancel();
  final Map<int, List<int>> buckets = <int, List<int>>{};
  for (final ({int at, int late}) s in stalls) {
    (buckets[s.at ~/ 1000000] ??= <int>[]).add(s.late);
  }
  for (final int sec in buckets.keys.toList()..sort()) {
    final List<int> l = buckets[sec]!;
    final int total = l.fold(0, (int a, int b) => a + b);
    final int max = l.reduce((int a, int b) => a > b ? a : b);
    debugPrint(
      '[tab-perf] idle t=${sec}s stalls=${l.length} '
      'total=${_f(total / 1000)}ms max=${_f(max / 1000)}ms',
    );
  }
  debugPrint('[tab-perf] idle done stalls=${stalls.length}');
}

/// 等首页（[HomePage]）挂载，与设计系统无关。
Future<bool> _waitForHomePage(WidgetTester tester) async {
  for (int i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 100));
    if (find.byType(HomePage).evaluate().isNotEmpty) return true;
  }
  return false;
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

Future<void> _measure(
  IntegrationTestWidgetsFlutterBinding binding,
  String label,
  widgets.VoidCallback switchTab, {
  required bool trace,
  bool profileLayout = false,
}) async {
  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  // UI 线程看门狗：2 ms 一跳的定时器晚到多少，就是事件循环被堵了多久。帧间
  // 空档只说明「没出帧」，分不清是没人要帧还是线程在跑别的同步活。
  final List<({int at, int late})> stalls = <({int at, int late})>[];
  int lastBeat = developer.Timeline.now;
  int switchedAt = lastBeat;
  final Timer watchdog = Timer.periodic(const Duration(milliseconds: 2), (_) {
    final int now = developer.Timeline.now;
    if (now - lastBeat > 30000) {
      stalls.add((at: lastBeat, late: now - lastBeat));
    }
    lastBeat = now;
  });
  // timeline 只录切页后的前 400 ms：recorder 是定长环形缓冲，录久了开头被冲掉。
  Future<void> run() async {
    switchedAt = developer.Timeline.now;
    debugPrint(
      '[tab-perf] switch $label at=${DateTime.now().millisecondsSinceEpoch}',
    );
    switchTab();
    await _wait(trace ? _traceMs : 1600);
  }

  vm.Timeline? timeline;
  if (trace) {
    widgets.debugProfileBuildsEnabledUserWidgets =
        !profileLayout && !_plainTrace;
    debugProfileLayoutsEnabled = profileLayout;
    try {
      timeline = await binding.traceTimeline(
        run,
        streams: const <String>['Dart', 'GC'],
      );
    } finally {
      widgets.debugProfileBuildsEnabledUserWidgets = false;
      debugProfileLayoutsEnabled = false;
    }
    await _wait(1200);
  } else {
    await run();
  }
  // FrameTiming 每秒批量上报一次，多等一拍收齐。
  await _wait(1100);
  SchedulerBinding.instance.removeTimingsCallback(collect);
  watchdog.cancel();

  _printFrames(label, timings, switchedAt);
  debugPrint(
    '[tab-perf] $label stalls:'
    '${stalls.map((({int at, int late}) s) => ' @${_f((s.at - switchedAt) / 1000)}[${_f(s.late / 1000)}]').join()}',
  );
  if (timeline != null) {
    _printLongEvents(label, timeline);
    const String dump = String.fromEnvironment('FUSHI_PERF_DUMP');
    if (dump.isNotEmpty) {
      final String name = label.replaceAll('/', '_');
      File('$dump/$name.json').writeAsStringSync(jsonEncode(timeline.toJson()));
    }
  }
}

/// 抓 timeline 的轮次录多久（默认 400 ms；recorder 是定长环形缓冲）。
const int _traceMs = int.fromEnvironment(
  'FUSHI_PERF_TRACE_MS',
  defaultValue: 400,
);

/// 抓 timeline 时不开 build 剖析（事件少，能录更长的窗口）。
const bool _plainTrace = bool.fromEnvironment('FUSHI_PERF_PLAIN_TRACE');

String _f(num v) => v.toStringAsFixed(1);

void _printFrames(String label, List<FrameTiming> timings, int origin) {
  if (timings.isEmpty) {
    debugPrint('[tab-perf] $label frames=0');
    return;
  }
  final StringBuffer slow = StringBuffer();
  int? prevEnd;
  double maxGap = 0;
  double maxBuild = 0;
  double maxRaster = 0;
  int over = 0;
  for (final FrameTiming t in timings) {
    final int start = t.timestampInMicroseconds(FramePhase.buildStart);
    final double gap = prevEnd == null ? 0 : (start - prevEnd) / 1000;
    prevEnd = t.timestampInMicroseconds(FramePhase.rasterFinish);
    final double build = t.buildDuration.inMicroseconds / 1000;
    final double raster = t.rasterDuration.inMicroseconds / 1000;
    if (gap > maxGap) maxGap = gap;
    if (build > maxBuild) maxBuild = build;
    if (raster > maxRaster) maxRaster = raster;
    if (t.totalSpan.inMicroseconds > 16667) over++;
    if (build > 12 || raster > 12 || gap > 40) {
      slow.write(
        ' @${_f((start - origin) / 1000)}[b${_f(build)} r${_f(raster)} '
        'g${_f(gap)}]',
      );
    }
  }
  debugPrint(
    '[tab-perf] $label frames=${timings.length} over16ms=$over '
    'maxBuild=${_f(maxBuild)} maxRaster=${_f(maxRaster)} '
    'maxGap=${_f(maxGap)} slow:$slow',
  );
}

/// GC 事件按名字与线程汇总（次数 / 总时长 / 最长）。
void _printGc(String label, vm.Timeline timeline) {
  final Map<String, List<double>> byName = <String, List<double>>{};
  final Map<String, String> threadNames = <String, String>{};
  final Map<String, List<Map<String, dynamic>>> stacks =
      <String, List<Map<String, dynamic>>>{};
  for (final vm.TimelineEvent ev
      in timeline.traceEvents ?? <vm.TimelineEvent>[]) {
    final Map<String, dynamic> e = ev.json ?? <String, dynamic>{};
    final String tid = '${e['tid']}';
    final String ph = '${e['ph']}';
    if (ph == 'M' && e['name'] == 'thread_name') {
      final Object? args = e['args'];
      if (args is Map) threadNames[tid] = '${args['name']}';
      continue;
    }
    if (e['cat'] != 'GC') continue;
    double? ms;
    if (ph == 'X') {
      ms = ((e['dur'] as int?) ?? 0) / 1000;
    } else if (ph == 'B') {
      (stacks[tid] ??= <Map<String, dynamic>>[]).add(e);
    } else if (ph == 'E') {
      final List<Map<String, dynamic>>? st = stacks[tid];
      if (st != null && st.isNotEmpty) {
        final Map<String, dynamic> b = st.removeLast();
        ms = ((e['ts'] as int) - (b['ts'] as int)) / 1000;
        e['name'] = b['name'];
      }
    }
    if (ms == null) continue;
    (byName['${e['name']} @${threadNames[tid] ?? tid}'] ??= <double>[]).add(ms);
  }
  for (final MapEntry<String, List<double>> m in byName.entries) {
    final double total = m.value.fold(0, (double a, double b) => a + b);
    final double max = m.value.reduce((double a, double b) => a > b ? a : b);
    debugPrint(
      '[tab-perf] $label gc ${m.key} n=${m.value.length} '
      'total=${_f(total)}ms max=${_f(max)}ms',
    );
  }
}

/// UI / raster 线程上最长的同步事件（B/E 配对 + X 完整事件），按时长取前若干条。
void _printLongEvents(String label, vm.Timeline timeline) {
  final List<({String name, String thread, double ms, int depth})> spans =
      <({String name, String thread, double ms, int depth})>[];
  final Map<String, String> threadNames = <String, String>{};
  final Map<String, List<Map<String, dynamic>>> stacks =
      <String, List<Map<String, dynamic>>>{};
  for (final vm.TimelineEvent ev
      in timeline.traceEvents ?? <vm.TimelineEvent>[]) {
    final Map<String, dynamic> e = ev.json ?? <String, dynamic>{};
    final String tid = '${e['tid']}';
    final String ph = '${e['ph']}';
    if (ph == 'M' && e['name'] == 'thread_name') {
      final Object? args = e['args'];
      if (args is Map) threadNames[tid] = '${args['name']}';
      continue;
    }
    if (ph == 'B') {
      (stacks[tid] ??= <Map<String, dynamic>>[]).add(e);
    } else if (ph == 'E') {
      final List<Map<String, dynamic>>? s = stacks[tid];
      if (s == null || s.isEmpty) continue;
      final Map<String, dynamic> b = s.removeLast();
      final double ms = ((e['ts'] as int) - (b['ts'] as int)) / 1000;
      if (ms >= 3) {
        spans.add((name: '${b['name']}', thread: tid, ms: ms, depth: s.length));
      }
    } else if (ph == 'X') {
      final double ms = ((e['dur'] as int?) ?? 0) / 1000;
      if (ms >= 3) {
        spans.add((name: '${e['name']}', thread: tid, ms: ms, depth: -1));
      }
    }
  }
  spans.sort((a, b) => b.ms.compareTo(a.ms));
  for (final ({String name, String thread, double ms, int depth}) s
      in spans.take(45)) {
    debugPrint(
      '[tab-perf] $label   ev ${_f(s.ms)}ms d${s.depth} '
      '[${threadNames[s.thread] ?? s.thread}] ${s.name}',
    );
  }
}
