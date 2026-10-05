import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/pages/implementations/home_page.dart';

import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 库页滚轮滚动帧时间探针（本地测速用，profile 构建跑才有意义）。
///
/// 复现协作者 2026-10-05 录屏的操作：指针停在页面内容上（游戏库停在「继续游戏」
/// 横版卡上），鼠标滚轮一档一档往下拨再往上拨，走根部 `SmoothWheelScrollScope`
/// 的 140ms 补间——与真实滚轮同一条路径。帧时间取引擎 [FrameTiming]，结果以
/// `[scroll-perf]` 前缀打进日志。
///
/// 跑法（数据根用带真实库的副本）：
///   flutter drive --profile -d windows --no-pub
///     --driver=test_driver/integration_test.dart
///     --target=integration_test/library_scroll_perf_itest.dart
///     --dart-define=FUSHI_TEST_ROOT=D:\hibiki-dev-data-sh
///
/// 本机 2026-10-05 Flutter 3.44 的 windows-x64-profile `gen_snapshot` 编本 app
/// 必栈溢出（0xC00000FD），profile 构建出不来；退而用 debug 离屏 runner 跑
/// （`FUSHI_TEST_HIDDEN=1 flutter test <本文件> -d windows`）。debug 下 build 段
/// 是 JIT 不可信，**只看 raster 段**（引擎同为优化编译，模糊卷积全在 raster）。
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('library pages wheel-scroll frame timing', (
    WidgetTester tester,
  ) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await _wait(2000);
    final double refresh = tester.view.display.refreshRate > 0
        ? tester.view.display.refreshRate
        : 60;
    final double budgetMs = 1000 / refresh;
    debugPrint(
      '[scroll-perf] refresh=${refresh.toStringAsFixed(1)}Hz '
      'size=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio}',
    );

    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    const List<HomeTab> tabs = <HomeTab>[
      HomeTab.games,
      HomeTab.video,
      HomeTab.books,
      HomeTab.dictionaries,
    ];
    for (int round = 0; round < 2; round++) {
      for (final HomeTab tab in tabs) {
        HomePage.debugSelectTab?.call(tab);
        // 等进场动画走完、封面解码完。
        await _wait(3500);
        final Offset? at = _pickPointerTarget(tester, tab);
        if (at == null) {
          debugPrint('[scroll-perf] r$round/${tab.name} no scrollable');
          continue;
        }
        await tester.sendEventToBinding(mouse.hover(at));
        await _wait(600);
        await _measure('r$round/${tab.name}', budgetMs, () async {
          for (int cycle = 0; cycle < 4; cycle++) {
            for (final double dy in <double>[100, -100]) {
              for (int notch = 0; notch < 5; notch++) {
                await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
                await _wait(120);
              }
              await _wait(250);
            }
          }
        });
      }
    }
    debugPrint('[scroll-perf] done');
  });
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// 指针落点：游戏库优先停在「继续游戏」卡上（录屏里指针就停在那），其余页取
/// 指针下可命中的最大纵向滚动区中心。
Offset? _pickPointerTarget(WidgetTester tester, HomeTab tab) {
  if (tab == HomeTab.games) {
    final Finder continueCard = find.byWidgetPredicate(
      (Widget w) =>
          w.key is ValueKey<String> &&
          (w.key! as ValueKey<String>).value.startsWith('games_continue_card_'),
    );
    if (continueCard.evaluate().isNotEmpty) {
      return tester.getCenter(continueCard.first);
    }
  }
  Offset? best;
  double bestArea = 0;
  for (final Element e in find.byType(Scrollable).evaluate()) {
    final ScrollableState state =
        (e as StatefulElement).state as ScrollableState;
    if (state.axisDirection != AxisDirection.down) continue;
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
  String label,
  double budgetMs,
  Future<void> Function() body,
) async {
  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  await body();
  // FrameTiming 批量回报有延迟，留时间把最后一批收齐。
  await _wait(1200);
  SchedulerBinding.instance.removeTimingsCallback(collect);
  if (timings.isEmpty) {
    debugPrint('[scroll-perf] $label frames=0');
    return;
  }
  List<double> ms(Duration Function(FrameTiming) pick) =>
      timings.map((FrameTiming t) => pick(t).inMicroseconds / 1000).toList()
        ..sort();
  double pct(List<double> v, double p) =>
      v[((v.length - 1) * p).round().clamp(0, v.length - 1)];
  final List<double> build = ms((FrameTiming t) => t.buildDuration);
  final List<double> raster = ms((FrameTiming t) => t.rasterDuration);
  final List<double> total = ms((FrameTiming t) => t.totalSpan);
  final int overBudget = timings
      .where((FrameTiming t) => t.totalSpan.inMicroseconds / 1000 > budgetMs)
      .length;
  String f(double v) => v.toStringAsFixed(2);
  debugPrint(
    '[scroll-perf] $label frames=${timings.length} '
    'build p50=${f(pct(build, .5))} p90=${f(pct(build, .9))} '
    'max=${f(build.last)} | raster p50=${f(pct(raster, .5))} '
    'p90=${f(pct(raster, .9))} p99=${f(pct(raster, .99))} '
    'max=${f(raster.last)} | total p90=${f(pct(total, .9))} '
    '| over=$overBudget/${timings.length} '
    '(${(overBudget * 100 / timings.length).toStringAsFixed(1)}%)',
  );
}
