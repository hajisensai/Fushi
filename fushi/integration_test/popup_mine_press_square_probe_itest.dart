import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'support/test_app_launcher.dart';
import 'package:fushi/models.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'test_helpers.dart';

/// BUG-3308 真机探针：真实 OS 鼠标按下/松开查词结果区的「+」制卡按钮，用桌面级
/// 截屏（合成后的像素）取证按下中、松开后各时刻按钮背后是否出现直角底色。
/// 环境变量：PRESS_SCRIPT（press_capture.ps1 路径）、PRESS_OUT（证据目录）、
/// PRESS_VARIANTS（逗号分隔：default,dark,cupertino,cupertino-dark）。
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.shouldPropagateDevicePointerEvents = true;

  testWidgets('mine button press leaves no square background', (
    WidgetTester tester,
  ) async {
    final String script = Platform.environment['PRESS_SCRIPT'] ?? '';
    final String outDir = Platform.environment['PRESS_OUT'] ?? '';
    final List<String> variants =
        (Platform.environment['PRESS_VARIANTS'] ?? 'default').split(',');

    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue);
    await tester.pump(const Duration(seconds: 2));
    await enableFocusNavigation(tester);
    final FocusDriver driver = FocusDriver(tester);
    expect(await seedDictionary(tester), isTrue);

    expect(
      await driver.focusWidget(findNavTargetForTab(HomeTab.dictionaries)),
      isTrue,
    );
    await driver.activate();
    await tester.pump(const Duration(seconds: 3));

    final AppModel appModel = ProviderScope.containerOf(
      tester.element(find.byType(Scaffold).first),
    ).read(appProvider);
    final String origDesign = appModel.themeNotifier.designSystem;
    final String origBrightness = appModel.themeNotifier.brightnessMode;
    debugPrint('[press-probe] design=$origDesign brightness=$origBrightness');

    try {
      for (final String variant in variants) {
        final bool dark = variant.contains('dark');
        final bool cupertino = variant.startsWith('cupertino');
        await appModel.themeNotifier.setDesignSystem(
          cupertino ? 'cupertino' : origDesign,
        );
        await appModel.themeNotifier.setBrightnessMode(dark ? 'dark' : 'light');
        await tester.pump(const Duration(seconds: 2));

        final HomeDictionarySearchDebug searchDebug =
            tester.state(find.byType(HomeDictionaryPage))
                as HomeDictionarySearchDebug;
        await searchDebug.debugSearch('testword', writeHistory: false);
        await tester.pump(const Duration(seconds: 5));

        final Finder wv = find.byType(DictionaryPopupWebView);
        expect(wv, findsWidgets);
        final DictionaryPopupWebViewState state =
            tester.state(wv.first) as DictionaryPopupWebViewState;
        Map<Object?, Object?>? r;
        for (int i = 0; i < 60 && r == null; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          final dynamic raw = await state.debugEval(r'''
(() => { const b = document.querySelector('.mine-button');
  if (!b) return null; const r = b.getBoundingClientRect();
  return {x: r.left + r.width / 2, y: r.top + r.height / 2,
    w: r.width, h: r.height, cls: document.documentElement.className,
    text: b.textContent}; })()''');
          if (raw is Map) r = raw.cast<Object?, Object?>();
        }
        expect(r, isNotNull, reason: 'mine button must render');
        final Rect wvRect = tester.getRect(wv.first);
        final double dpr = tester.view.devicePixelRatio;
        final double lx = wvRect.left + (r!['x']! as num).toDouble();
        final double ly = wvRect.top + (r['y']! as num).toDouble();
        debugPrint(
          '[press-probe] variant=$variant wvRect=$wvRect btn=$r '
          'dpr=$dpr logical=($lx,$ly)',
        );

        final Future<ProcessResult> proc = Process.run('powershell', <String>[
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script,
          '-TargetPid',
          '$pid',
          '-LogicalX',
          '$lx',
          '-LogicalY',
          '$ly',
          '-Dpr',
          '$dpr',
          '-OutDir',
          outDir,
          '-Tag',
          variant,
        ]);
        ProcessResult? res;
        proc.then((ProcessResult v) => res = v);
        for (int i = 0; i < 900 && res == null; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        debugPrint(
          '[press-probe] ps exit=${res?.exitCode} '
          'out=${res?.stdout} err=${res?.stderr}',
        );
        final dynamic after = await state.debugEval(r'''
(() => ({sel: String(getSelection()), active: document.activeElement &&
  (document.activeElement.tagName + '.' + document.activeElement.className),
  ring: (() => { const g = document.getElementById('fushi-caret-ring');
    return g ? g.style.cssText : null; })(),
  mine: document.querySelector('.mine-button')?.className}))()''');
        debugPrint('[press-probe] variant=$variant after=$after');
      }
    } finally {
      await appModel.themeNotifier.setDesignSystem(origDesign);
      await appModel.themeNotifier.setBrightnessMode(origBrightness);
    }
  });
}
