import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/utils.dart';

import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

/// 玻璃设计系统真机帧时间探针（本地测速用，不入库）。
///
/// 同一套焦点驱动动作分别在 MD3 / 毛玻璃 / 液态下跑：主导航来回切、设置页
/// 方向键滚动、对话框反复开关。帧时间来自引擎 FrameTiming（profile 构建），
/// 结果以 `[glass-perf]` 前缀打进 logcat。
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('glass design system frame timing', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    final ProviderContainer container = ProviderScope.containerOf(
      tester.element(find.byType(MaterialApp).first),
    );
    final AppModel appModel = container.read(appProvider);
    await appModel.setExperimentalFocusNavigationEnabled(true);
    await _settle(tester, 2000);
    final FocusDriver driver = FocusDriver(tester);
    final double refresh =
        tester.view.display.refreshRate > 0 ? tester.view.display.refreshRate : 60;
    final double budgetMs = 1000 / refresh;
    debugPrint('[glass-perf] refresh=${refresh.toStringAsFixed(1)}Hz '
        'budget=${budgetMs.toStringAsFixed(2)}ms '
        'size=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio}');

    final List<({String name, String design, FushiGlassMaterial tier})>
        configs = <({String name, String design, FushiGlassMaterial tier})>[
      (name: 'md3', design: 'material', tier: FushiGlassMaterial.liquid),
      (name: 'frosted', design: 'glass', tier: FushiGlassMaterial.frosted),
      (name: 'liquid', design: 'glass', tier: FushiGlassMaterial.liquid),
    ];

    for (int round = 0; round < 2; round++) {
      for (final config in configs) {
        await appModel.themeNotifier.setGlassMaterial(config.tier);
        await appModel.themeNotifier.setDesignSystem(config.design);
        await _settle(tester, 1500);
        final String tag = 'r$round/${config.name} '
            'resolved=${appModel.glassMaterial.name}';

        await _measure(tester, '$tag nav', budgetMs, () async {
          final List<Finder> targets = findPrimaryNavigationTargets();
          for (int pass = 0; pass < 2; pass++) {
            for (final Finder target in targets.take(5)) {
              if (await driver.focusWidget(target)) {
                await driver.activate();
                await _settle(tester, 600);
              }
              if (homeShellTabNotifier.value == HomeTab.settings) {
                await driver.back();
                await _settle(tester, 400);
              }
            }
          }
        });

        await _measure(tester, '$tag settings-scroll', budgetMs, () async {
          final Finder settings = findNavTargetForTab(HomeTab.settings);
          if (await driver.focusWidget(settings)) {
            await driver.activate();
            await _settle(tester, 800);
          }
          for (int i = 0; i < 40; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
            await _settle(tester, 120);
          }
          for (int i = 0; i < 40; i++) {
            await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
            await _settle(tester, 120);
          }
          if (homeShellTabNotifier.value == HomeTab.settings) {
            await driver.back();
            await _settle(tester, 600);
          }
        });

        await _measure(tester, '$tag dialog', budgetMs, () async {
          for (int i = 0; i < 6; i++) {
            showAppDialog<void>(
              context: tester.element(find.byType(HomePage)),
              builder: (_) => AlertDialog(
                title: const Text('Glass'),
                content: const Text('frame timing probe'),
                actions: <Widget>[
                  TextButton(onPressed: () {}, child: const Text('OK')),
                ],
              ),
            );
            await _settle(tester, 700);
            await driver.back();
            await _settle(tester, 700);
          }
        });
      }
    }

    await appModel.themeNotifier.setDesignSystem('glass');
    await appModel.themeNotifier.setGlassMaterial(FushiGlassMaterial.liquid);
    await _settle(tester, 1000);
    debugPrint('[glass-perf] done');
  });
}

Future<void> _settle(WidgetTester tester, int ms) async {
  final int steps = (ms / 16).ceil();
  for (int i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _measure(
  WidgetTester tester,
  String label,
  double budgetMs,
  Future<void> Function() body,
) async {
  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  await body();
  // FrameTiming 批量回报有延迟，留时间把最后一批收齐。
  await _settle(tester, 1200);
  SchedulerBinding.instance.removeTimingsCallback(collect);
  if (timings.isEmpty) {
    debugPrint('[glass-perf] $label frames=0');
    return;
  }
  List<double> ms(Duration Function(FrameTiming) pick) =>
      timings.map((FrameTiming t) => pick(t).inMicroseconds / 1000).toList()
        ..sort();
  double pct(List<double> v, double p) =>
      v[((v.length - 1) * p).round().clamp(0, v.length - 1)];
  final List<double> build = ms((FrameTiming t) => t.buildDuration);
  final List<double> raster = ms((FrameTiming t) => t.rasterDuration);
  final int overBudget = timings
      .where((FrameTiming t) =>
          t.buildDuration.inMicroseconds / 1000 > budgetMs ||
          t.rasterDuration.inMicroseconds / 1000 > budgetMs)
      .length;
  String f(double v) => v.toStringAsFixed(2);
  debugPrint('[glass-perf] $label frames=${timings.length} '
      'build p50=${f(pct(build, .5))} p90=${f(pct(build, .9))} '
      'p99=${f(pct(build, .99))} | raster p50=${f(pct(raster, .5))} '
      'p90=${f(pct(raster, .9))} p99=${f(pct(raster, .99))} '
      'max=${f(raster.last)} | over=$overBudget/${timings.length} '
      '(${(overBudget * 100 / timings.length).toStringAsFixed(1)}%)');
}
