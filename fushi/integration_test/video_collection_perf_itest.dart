import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show ProcessInfo;
import 'dart:ui';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/baked_surface.dart';
import 'package:fushi/src/utils/system_transparency.dart';
import 'package:fushi/src/diagnostics/windows_memory_probe.dart';
import 'package:fushi/src/utils/components/prebaked_blur_image.dart';
import 'package:fushi/src/media/video/video_specs_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/home_tab.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/video_work_detail_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vm_service/vm_service.dart' as vm;

import 'helpers/library_fixture.dart';
import 'helpers/ui_cpu_profile.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 视频库 / 视频合集详情页滚动与打开耗时探针（本地测速用，profile 构建跑）。
///
/// 复现 2026-11-22 反馈「视频合集滚动很卡、页面切换很卡」：走与库页同一条
/// `VideoWorkDetailPage(VideoWorkRef.collection)` 入口（带真 [VideoSpecsService]），
/// 打开合集后鼠标滚轮一档一档往下拨到底再拨回，收引擎 [FrameTiming]、UI 线程
/// 看门狗（事件循环被堵多久）与 timeline 里 UI 线程最长的事件，以 `[coll-perf]`
/// 前缀打进日志。视频库主页也按同样方式滚一遍。
///
/// 跑法（数据根用安装版真实库的只读拷贝，见 `detail_open_perf_itest.dart`）：
///   FUSHI_TEST_HIDDEN=1 FUSHI_TEST_ONSCREEN=1
///   FUSHI_WEBVIEW2_USER_DATA_FOLDER=<测试根>/webview2
///   flutter drive --profile -d windows --no-pub
///     --driver=test_driver/integration_test.dart
///     --target=integration_test/video_collection_perf_itest.dart
///     --dart-define=FUSHI_TEST_ROOT=<测试根>
///     --dart-define=FUSHI_PERF_COLLECTION=<合集 id>
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('video collection scroll timing', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    final AppModel appModel = await readyAppModel(tester);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await _wait(3000);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp).first),
    );
    const int collectionId = int.fromEnvironment(
      'FUSHI_PERF_COLLECTION',
      defaultValue: 76,
    );
    debugPrint(
      '[coll-perf] collection=$collectionId '
      'size=${tester.view.physicalSize.width.toStringAsFixed(0)}x${tester.view.physicalSize.height.toStringAsFixed(0)} dpr=${tester.view.devicePixelRatio} '
      'design=${appModel.themeNotifier.designSystem}',
    );
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);

    // 0) 各页静置与切页：CPU 采样看 UI isolate 在忙什么。
    // 对照实验：关掉磨砂（BackdropFilter）看滚动 raster / 内存是否随之消失。
    if (const bool.fromEnvironment('FUSHI_PERF_NO_GLASS')) {
      SystemTransparency.reduceTransparency.value = true;
    }
    if (!const bool.fromEnvironment('FUSHI_PERF_COLLECTION_ONLY')) {
      homeShellTabNotifier.value = HomeTab.settings;
      await _wait(4000);
      for (final HomeTab tab in <HomeTab>[
        HomeTab.video,
        HomeTab.home,
        HomeTab.video,
      ]) {
        await _measure(
          binding,
          'switch-${tab.name}',
          () async {
            homeShellTabNotifier.value = tab;
            await _wait(1500);
          },
          trace: false,
          cpu: true,
        );
        await _wait(1500);
      }

      // 1) 视频库主页滚动。
      homeShellTabNotifier.value = HomeTab.video;
      await _wait(5000);
      for (int round = 0; round < 2; round++) {
        final Offset? at = _pickPointerTarget(tester);
        if (at == null) {
          debugPrint('[coll-perf] library no scrollable');
          break;
        }
        await tester.sendEventToBinding(mouse.hover(at));
        await _measure(
          binding,
          'library/r$round',
          () => _wheel(tester, mouse, notches: 12),
          trace: round == 1,
          cpu: round == 0,
        );
      }
    }

    // 2) 合集详情：打开 + 滚动。
    final NavigatorState nav = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    final VideoBookRepository repo = VideoBookRepository(appModel.database);
    for (int round = 0; round < 3; round++) {
      Future<void>? pushed;
      await _measure(
        binding,
        'open/r$round',
        () async {
          pushed = nav.push<void>(
            adaptivePageRoute<void>(
              context: nav.context,
              builder: (_) => VideoWorkDetailPage(
                database: appModel.database,
                videoSpecs: container.read(videoSpecsProvider),
                repository: repo,
                workRef: const VideoWorkRef.collection(collectionId),
                onChanged: () {},
              ),
            ),
          );
          await _wait(2500);
        },
        trace: round == 2,
        cpu: round == 1,
      );
      if (round == 0) _dumpLayerEffects();
      final Offset? at = _pickPointerTarget(tester);
      if (at == null) {
        debugPrint('[coll-perf] collection no scrollable');
      } else {
        await tester.sendEventToBinding(mouse.hover(at));
        await _wait(400);
        await _measure(
          binding,
          'scroll/r$round',
          () => _wheel(tester, mouse, notches: 25),
          trace: round == 2,
          cpu: round == 1,
        );
      }
      await _measure(binding, 'pop/r$round', () async {
        nav.pop();
        await pushed;
        await _wait(1200);
      }, trace: false);
    }
    debugPrint('[coll-perf] done');
  });
}

/// 列出会开离屏层（saveLayer）的 render object：类型、尺寸、外层 widget 链。
/// 离屏层的范围若是整段滚动内容（几万像素高），每帧都要申请几百 MB 的临时纹理。
void _dumpLayerEffects() {
  final Map<String, int> counts = <String, int>{};
  final Map<String, Set<String>> owners = <String, Set<String>>{};
  void visitLayer(Layer layer) {
    final String type = '${layer.runtimeType}';
    counts[type] = (counts[type] ?? 0) + 1;
    if (layer is ContainerLayer) {
      Layer? child = layer.firstChild;
      while (child != null) {
        visitLayer(child);
        child = child.nextSibling;
      }
    }
  }

  void visitElement(Element e, List<String> chain) {
    final List<String> next = <String>[...chain, '${e.widget.runtimeType}'];
    if (next.length > 400) return;
    if (e is RenderObjectElement) {
      final RenderObject ro = e.renderObject;
      if (ro is RenderBox &&
          ro.hasSize &&
          (ro.size.height > 2500 || ro.size.width > 4000) &&
          (ro is RenderDecoratedBox ||
              ro is RenderCustomPaint ||
              ro is RenderPhysicalModel ||
              ro is RenderPhysicalShape ||
              ro is RenderClipPath ||
              ro is RenderClipRRect ||
              ro is RenderOpacity ||
              ro is RenderAnimatedOpacity ||
              '${ro.runtimeType}'.contains('Superellipse') ||
              '${ro.runtimeType}'.contains('Shadow'))) {
        String extra = '';
        if (ro is RenderDecoratedBox) extra = ' deco=${ro.decoration}';
        if (ro is RenderCustomPaint) {
          extra =
              ' painter=${ro.painter?.runtimeType} '
              'fg=${ro.foregroundPainter?.runtimeType}';
        }
        if (ro is RenderPhysicalShape) extra = ' elev=${ro.elevation}';
        if (ro is RenderPhysicalModel) extra = ' elev=${ro.elevation}';
        debugPrint(
          '[coll-perf] big ${ro.runtimeType} '
          '${ro.size.width.toStringAsFixed(0)}x'
          '${ro.size.height.toStringAsFixed(0)}$extra <- '
          '${next.reversed.take(14).join(" < ")}',
        );
      }
      // ignore: invalid_use_of_protected_member
      final Layer? own = ro.layer;
      if (own != null && (own is! OffsetLayer || own is OpacityLayer)) {
        final String type = own is OpacityLayer
            ? 'OpacityLayer(a=${own.alpha})'
            : '${own.runtimeType}';
        final String owner = next.reversed
            .where((String w) => !w.startsWith('_'))
            .take(6)
            .join(' < ');
        (owners[type] ??= <String>{}).add(owner);
      }
    }
    e.visitChildren((Element c) => visitElement(c, next));
  }

  for (final RenderView view in RendererBinding.instance.renderViews) {
    // ignore: invalid_use_of_protected_member
    final Layer? root = view.layer;
    if (root != null) visitLayer(root);
  }
  WidgetsBinding.instance.rootElement?.visitChildren(
    (Element c) => visitElement(c, const <String>[]),
  );
  debugPrint('[coll-perf] layer-counts $counts');
  owners.forEach((String type, Set<String> set) {
    for (final String o in set.take(12)) {
      debugPrint('[coll-perf] layer-owner $type <- $o');
    }
  });
  debugPrint('[coll-perf] layer-dump shown=${counts.length}');
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

Future<void> _wheel(
  WidgetTester tester,
  TestPointer mouse, {
  required int notches,
}) async {
  for (final double dy in <double>[100, -100]) {
    for (int notch = 0; notch < notches; notch++) {
      await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
      await _wait(110);
      if (const bool.fromEnvironment('FUSHI_PERF_RSS_TRACE') &&
          dy > 0 &&
          notch == 12) {
        _dumpLayerEffects();
      }
      if (const bool.fromEnvironment('FUSHI_PERF_RSS_TRACE')) {
        debugPrint(
          '[coll-perf] wheel dy=$dy notch=$notch '
          'rss=${ProcessInfo.currentRss >> 20}MB ${windowsMemoryProbe()} '
          '${imageCacheProbe()} bakes=$prebakedBlurBakeCount '
          'bakeCache=$prebakedBlurCacheLength '
          'surfaceBakes=${RenderBakedSurface.debugBakeCount}',
        );
      }
    }
    await _wait(300);
  }
}

/// 指针下可命中的最大纵向滚动区中心。
Offset? _pickPointerTarget(WidgetTester tester) {
  Offset? best;
  double bestArea = 0;
  for (final Element e in find.byType(Scrollable).evaluate()) {
    final ScrollableState state =
        (e as StatefulElement).state as ScrollableState;
    if (state.axisDirection != AxisDirection.down) continue;
    if (!state.position.hasContentDimensions) continue;
    if (state.position.maxScrollExtent <= 0) continue;
    final RenderBox? box = e.renderObject as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) continue;
    final Offset center = box.localToGlobal(box.size.center(Offset.zero));
    final HitTestResult hit = tester.hitTestOnBinding(center);
    if (!hit.path.any((HitTestEntry entry) => entry.target == box)) continue;
    final double area = box.size.width * box.size.height;
    if (area > bestArea) {
      bestArea = area;
      best = center;
    }
  }
  return best;
}

Future<void> _measure(
  IntegrationTestWidgetsFlutterBinding binding,
  String label,
  Future<void> Function() body, {
  required bool trace,
  bool cpu = false,
}) async {
  // FUSHI_PERF_PLAIN：不抓 timeline、不收 CPU 采样，只收帧时间（无剖析开销）。
  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  final List<int> stalls = <int>[];
  int lastBeat = developer.Timeline.now;
  final Timer watchdog = Timer.periodic(const Duration(milliseconds: 2), (_) {
    final int now = developer.Timeline.now;
    if (now - lastBeat > 30000) stalls.add(now - lastBeat);
    lastBeat = now;
  });
  const bool plain = bool.fromEnvironment('FUSHI_PERF_PLAIN');
  if (plain) {
    trace = false;
    cpu = false;
  }
  vm.Timeline? timeline;
  if (cpu) {
    await profileUiCpu('coll-perf', label, body);
  } else if (trace) {
    debugProfileBuildsEnabledUserWidgets = true;
    try {
      timeline = await binding.traceTimeline(
        body,
        streams: const <String>['Dart', 'GC', 'Embedder'],
      );
    } finally {
      debugProfileBuildsEnabledUserWidgets = false;
    }
  } else {
    await body();
  }
  watchdog.cancel();
  await _wait(1000);
  SchedulerBinding.instance.removeTimingsCallback(collect);
  _printFrames(label, timings, stalls);
  if (timeline != null) _printLongEvents(label, timeline);
}

String _f(num v) => v.toStringAsFixed(1);

void _printFrames(String label, List<FrameTiming> timings, List<int> stalls) {
  if (timings.isEmpty) {
    debugPrint('[coll-perf] $label frames=0');
    return;
  }
  List<double> ms(Duration Function(FrameTiming) pick) =>
      timings.map((FrameTiming t) => pick(t).inMicroseconds / 1000).toList()
        ..sort();
  double pct(List<double> v, double p) =>
      v[((v.length - 1) * p).round().clamp(0, v.length - 1)];
  final List<double> build = ms((FrameTiming t) => t.buildDuration);
  final List<double> raster = ms((FrameTiming t) => t.rasterDuration);
  final int over = timings
      .where((FrameTiming t) => t.totalSpan.inMicroseconds > 16667)
      .length;
  stalls.sort();
  debugPrint(
    '[coll-perf] $label frames=${timings.length} over16=$over '
    'build p50=${_f(pct(build, .5))} p90=${_f(pct(build, .9))} '
    'max=${_f(build.last)} | raster p50=${_f(pct(raster, .5))} '
    'p90=${_f(pct(raster, .9))} max=${_f(raster.last)} | '
    'rss=${ProcessInfo.currentRss >> 20}MB '
    'stalls=${stalls.length} worst=${stalls.reversed.take(6).map((int s) => _f(s / 1000)).join(",")}',
  );
}

/// UI / raster 线程上最长的同步事件（B/E 配对 + X 完整事件），按时长取前若干条。
void _printLongEvents(String label, vm.Timeline timeline) {
  final List<({String name, String thread, double ms, int depth})> spans =
      <({String name, String thread, double ms, int depth})>[];
  final Map<String, String> threadNames = <String, String>{};
  final Map<String, List<Map<String, dynamic>>> stacks =
      <String, List<Map<String, dynamic>>>{};
  final Map<String, double> totals = <String, double>{};
  final Map<String, int> counts = <String, int>{};
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
      final String key = '${threadNames[tid] ?? tid}|${b['name']}';
      totals[key] = (totals[key] ?? 0) + ms;
      counts[key] = (counts[key] ?? 0) + 1;
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
  final List<MapEntry<String, double>> byName =
      totals.entries
          .where((MapEntry<String, double> e) => e.key.contains('raster'))
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));
  for (final MapEntry<String, double> e in byName.take(45)) {
    debugPrint(
      '[coll-perf] $label   sum ${_f(e.value)}ms n=${counts[e.key]} ${e.key}',
    );
  }
  spans.sort((a, b) => b.ms.compareTo(a.ms));
  for (final ({String name, String thread, double ms, int depth}) s
      in spans.take(80)) {
    debugPrint(
      '[coll-perf] $label   ev ${_f(s.ms)}ms d${s.depth} '
      '[${threadNames[s.thread] ?? s.thread}] ${s.name}',
    );
  }
}
