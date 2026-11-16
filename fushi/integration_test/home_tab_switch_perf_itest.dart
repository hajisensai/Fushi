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
import 'test_helpers.dart';

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
    expect(await waitForHome(tester), isTrue);
    final AppModel appModel = await readyAppModel(tester);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await _wait(3000);

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
    switchTab();
    await _wait(trace ? 400 : 1600);
  }

  vm.Timeline? timeline;
  if (trace) {
    widgets.debugProfileBuildsEnabledUserWidgets = !profileLayout;
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
