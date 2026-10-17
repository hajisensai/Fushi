import 'dart:ui' show FramePhase;

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/reader_fushi_page.dart'
    show ReaderFushiPage;
import 'package:fushi/src/reader/reader_settings_ia.dart' show ReaderSettingsTab;
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSlider;
import 'package:fushi/utils.dart' show FushiGlassMaterial;
import 'package:integration_test/integration_test.dart';

import 'package:flutter/services.dart';
import 'package:fushi_engine/epub/epub_importer.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'helpers/library_fixture.dart'
    show openBookViaProductionPath, readyAppModel;
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 小说阅读器「阅读设置」侧栏的真机帧时间探针（Android 卡顿反馈）。
///
/// 开一本书 → 打开设置面板（压在正文 WebView 平台视图上）→ 依次测：打开、静置、
/// 外观页上下甩动滚动、切页签、字号 +/-、翻页与手势页拖滑块。Apple 液态
/// 与 MD3 下各跑一遍。帧时间来自引擎 [FrameTiming]（须 profile 构建），以
/// `[sheet-perf]` 前缀打进 logcat。
///
/// Run (from fushi/):
///   flutter drive --profile --driver=test_driver/integration_test.dart \
///     --target=integration_test/reader_settings_sheet_perf_itest.dart -d <id>
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets(
    'reader settings side sheet frame timing',
    timeout: const Timeout(Duration(minutes: 15)),
    (WidgetTester tester) async {
      final FlutterExceptionHandler? previousOnError = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails d) {
        // profile 构建把异常摘要成 ErrorSummary，这里把原文与 fushi 栈帧打出来。
        final String frames = (d.stack?.toString() ?? '')
            .split(String.fromCharCode(10))
            .where((String l) => l.contains('package:fushi'))
            .take(6)
            .join(' | ');
        debugPrint(
          '[sheet-perf] FLUTTER-ERROR ${d.exceptionAsString()} '
          'ctx=${d.context?.toDescription()} at $frames',
        );
        previousOnError?.call(d);
      };
      addTearDown(() => FlutterError.onError = previousOnError);
      try {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        await _settle(tester, 2000);
        final AppModel appModel = await readyAppModel(tester);
        final double refresh = tester.view.display.refreshRate > 0
            ? tester.view.display.refreshRate
            : 60;
        final double budgetMs = 1000 / refresh;
        debugPrint(
          '[sheet-perf] refresh=${refresh.toStringAsFixed(1)}Hz '
          'budget=${budgetMs.toStringAsFixed(2)}ms '
          'size=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio}',
        );
        await appModel.themeNotifier.setEinkMode(false);
        await appModel.themeNotifier.setBrightnessMode('dark');

        // profile 构建没有 assert 里注册的 HomePage.debugSelectTab，不经书架直接入库。
        final String bookKey = await EpubImporter.import(
          db: appModel.database,
          bytes: EpubGenerator().generate(),
          fileName: 'sheet_perf.epub',
        );
        final List<({String name, String design, FushiGlassMaterial tier})>
        configs = <({String name, String design, FushiGlassMaterial tier})>[
          (name: 'liquid', design: 'glass', tier: FushiGlassMaterial.liquid),
          (name: 'md3', design: 'material', tier: FushiGlassMaterial.liquid),
        ];

        for (int round = 0; round < 1; round++) {
          for (final config in configs) {
            await appModel.themeNotifier.setGlassMaterial(config.tier);
            await appModel.themeNotifier.setDesignSystem(config.design);
            await _settle(tester, 1500);
            // 先切主题再开书：与用户「本来就在该材质下开书」同一顺序。
            await openBookViaProductionPath(tester, bookKey);
            for (int i = 0; i < 120; i++) {
              await _settle(tester, 500);
              if (find
                      .byKey(const ValueKey<String>('fushi_content_ready'))
                      .evaluate()
                      .isNotEmpty &&
                  find.byType(ReaderFushiPage).evaluate().isNotEmpty) {
                break;
              }
            }
            await _settle(tester, 2000);
            final String tag =
                'r$round/${config.name} resolved=${appModel.glassMaterial.name}';

            // 阅读器快捷键 T = readerOpenMenu（与用户点齿轮同一 _showAppearanceSheet）。
            // Android 的键码表在 flutter_test 里缺物理键映射，用 windows 键格式模拟。
            await _measure(tester, '$tag open', budgetMs, () async {
              await tester.sendKeyEvent(
                LogicalKeyboardKey.keyT,
                platform: 'windows',
              );
              await _settle(tester, 1000);
            });
            final Finder sheet = find.byKey(
              const ValueKey<String>('fushi_reader_side_sheet'),
            );
            _reportErrorWidgets('$tag open');
            expect(sheet, findsOneWidget, reason: 'settings side sheet open');

            await _measure(tester, '$tag idle', budgetMs, () async {
              await _settle(tester, 1500);
            });

            Finder tab(ReaderSettingsTab which) => find.descendant(
              of: find.byKey(const ValueKey<String>('fushi_side_sheet_tabs')),
              matching: find.text(which.label),
            );
            Finder page(ReaderSettingsTab which) => find.byKey(
              PageStorageKey<String>('fushi_side_sheet_tab_${which.id}'),
            );
            Future<void> goTab(ReaderSettingsTab which) async {
              if (tab(which).evaluate().isEmpty) return;
              await tester.tap(tab(which).first); // itest-tap-allow: perf probe times the real touch path
              await _settle(tester, 900);
            }

            await goTab(ReaderSettingsTab.appearance);
            await _measure(tester, '$tag scroll', budgetMs, () async {
              for (int i = 0; i < 4; i++) {
                await tester.timedDrag(
                  page(ReaderSettingsTab.appearance),
                  const Offset(0, -500),
                  const Duration(milliseconds: 400),
                );
                await _settle(tester, 700);
                await tester.timedDrag(
                  page(ReaderSettingsTab.appearance),
                  const Offset(0, 500),
                  const Duration(milliseconds: 400),
                );
                await _settle(tester, 700);
              }
            });

            await _measure(tester, '$tag tabs', budgetMs, () async {
              for (int i = 0; i < 2; i++) {
                for (final ReaderSettingsTab which in <ReaderSettingsTab>[
                  ReaderSettingsTab.layout,
                  ReaderSettingsTab.gestures,
                  ReaderSettingsTab.lookup,
                  ReaderSettingsTab.appearance,
                ]) {
                  await goTab(which);
                }
              }
            });

            // 字号 +/-：每次改值都实时推进正文 WebView 重排。
            final Finder plus = find.descendant(
              of: page(ReaderSettingsTab.appearance),
              matching: find.byTooltip(t.increase),
            );
            final Finder minus = find.descendant(
              of: page(ReaderSettingsTab.appearance),
              matching: find.byTooltip(t.decrease),
            );
            if (plus.evaluate().isNotEmpty && minus.evaluate().isNotEmpty) {
              await tester.ensureVisible(plus.first);
              await _settle(tester, 500);
              await _measure(tester, '$tag fontstep', budgetMs, () async {
                for (int i = 0; i < 3; i++) {
                  await tester.tap(plus.first); // itest-tap-allow: perf probe times the real touch path
                  await _settle(tester, 600);
                  await tester.tap(minus.first); // itest-tap-allow: perf probe times the real touch path
                  await _settle(tester, 600);
                }
              });
            } else {
              debugPrint('[sheet-perf] $tag stepper not found');
            }

            await goTab(ReaderSettingsTab.gestures);
            final Finder slider = find.descendant(
              of: page(ReaderSettingsTab.gestures),
              matching: find.byType(FushiSlider),
            );
            if (slider.evaluate().isNotEmpty) {
              final Finder target = slider.first;
              await tester.ensureVisible(target);
              await _settle(tester, 500);
              await _measure(tester, '$tag slider', budgetMs, () async {
                for (int i = 0; i < 3; i++) {
                  await tester.timedDrag(
                    target,
                    const Offset(80, 0),
                    const Duration(milliseconds: 600),
                  );
                  await _settle(tester, 300);
                  await tester.timedDrag(
                    target,
                    const Offset(-80, 0),
                    const Duration(milliseconds: 600),
                  );
                  await _settle(tester, 300);
                }
              });
            } else {
              debugPrint('[sheet-perf] $tag slider not found');
            }
            await goTab(ReaderSettingsTab.appearance);

            _reportErrorWidgets('$tag end');
            Navigator.of(tester.element(sheet)).pop();
            await _settle(tester, 1200);
            await Navigator.of(
              tester.element(find.byType(ReaderFushiPage)),
            ).maybePop();
            await _settle(tester, 2500);
          }
        }

        await appModel.themeNotifier.setDesignSystem('glass');
        await appModel.themeNotifier.setGlassMaterial(
          FushiGlassMaterial.liquid,
        );
        await _settle(tester, 1000);
        debugPrint('[sheet-perf] done');
      } catch (e, st) {
        debugPrint('[sheet-perf] FAILED $e');
        debugPrint('[sheet-perf] STACK $st');
        rethrow;
      }
    },
  );
}

Future<void> _settle(WidgetTester tester, int ms) async {
  final int steps = (ms / 16).ceil();
  for (int i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    final Object? error = tester.takeException();
    if (error != null) {
      debugPrint('[sheet-perf] EXCEPTION $error');
      _reportErrorWidgets('after exception');
    }
  }
}

/// 树里的 [ErrorWidget]（profile 下是灰块）连同祖先链打出来，定位哪个控件
/// build 抛了异常。
void _reportErrorWidgets(String label) {
  final List<Element> errors = find.byType(ErrorWidget).evaluate().toList();
  if (errors.isEmpty) return;
  debugPrint('[sheet-perf] $label: ${errors.length} ErrorWidget(s)');
  for (final Element e in errors.take(3)) {
    final List<String> chain = <String>[];
    e.visitAncestorElements((Element a) {
      final String name = a.widget.runtimeType.toString();
      if (!name.startsWith('_') || chain.length < 6) chain.add(name);
      return chain.length < 40;
    });
    debugPrint('[sheet-perf] chain: ${chain.join(' < ')}');
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
  final Stopwatch wall = Stopwatch()..start();
  await body();
  wall.stop();
  await _settle(tester, 1200);
  SchedulerBinding.instance.removeTimingsCallback(collect);
  if (timings.isEmpty) {
    debugPrint('[sheet-perf] $label frames=0');
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
      .where(
        (FrameTiming t) =>
            t.buildDuration.inMicroseconds / 1000 > budgetMs ||
            t.rasterDuration.inMicroseconds / 1000 > budgetMs,
      )
      .length;
  String f(double v) => v.toStringAsFixed(2);
  // 相邻帧 vsync 间隔：连续出帧时它就是系统实际给本 app 的刷新周期
  // （8.3ms = 120Hz，16.7ms = 60Hz），> 1.5 个周期的算掉帧。
  final List<double> gaps = <double>[];
  for (int i = 1; i < timings.length; i++) {
    gaps.add(
      (timings[i].timestampInMicroseconds(FramePhase.vsyncStart) -
              timings[i - 1].timestampInMicroseconds(FramePhase.vsyncStart)) /
          1000,
    );
  }
  gaps.sort();
  final double gapMin = gaps.isEmpty ? 0 : gaps.first;
  final int dropped = gaps
      .where((double g) => g > budgetMs * 1.5 && g < 200)
      .length;
  debugPrint(
    '[sheet-perf] $label vsync-gap min=${f(gapMin)} '
    'p10=${f(gaps.isEmpty ? 0 : pct(gaps, .1))} '
    'p50=${f(gaps.isEmpty ? 0 : pct(gaps, .5))} '
    'p90=${f(gaps.isEmpty ? 0 : pct(gaps, .9))} late(<200ms)=$dropped',
  );
  debugPrint(
    '[sheet-perf] $label frames=${timings.length} '
    'fps=${(timings.length * 1000 / (wall.elapsedMilliseconds + 1200)).toStringAsFixed(1)} '
    'build p50=${f(pct(build, .5))} p90=${f(pct(build, .9))} '
    'p99=${f(pct(build, .99))} | raster p50=${f(pct(raster, .5))} '
    'p90=${f(pct(raster, .9))} p99=${f(pct(raster, .99))} '
    'max=${f(raster.last)} | total p50=${f(pct(total, .5))} '
    'p90=${f(pct(total, .9))} | over=$overBudget/${timings.length} '
    '(${(overBudget * 100 / timings.length).toStringAsFixed(1)}%)',
  );
}
