import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart'
    show ReaderHibikiSource;
import 'package:hibiki/src/models/app_model.dart' show AppModel;
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart'
    show ReaderHibikiPage;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart' show readyAppModel, seedReaderBook;
import 'support/itest_startup_guard.dart';
import 'test_helpers.dart';

/// 用户报告：在书里改「布局设置」（例如上下边距）不立即生效，必须退出书籍重开才应用。
///
/// 本测试沿真实产品路径复现：开书 → 读 body 的 computed `padding-top/bottom`
/// 与 `column-width`（竖排列宽由上下边距驱动）→ 走产品 setter
/// `setReaderMarginTop/Bottom`（内部 fire `onSettingsChangedLive` = `_applyStylesLive`
/// 的同一条实时通道）→ **不重开** → 再读 padding，断言即时变化。
///
/// 对照组：同一路径改 `fontSize`，验证 body `font-size` 是否即时变化，以确认
/// 「字号即时、边距不即时」的不对称是否真实存在。
///
/// Run (Android 模拟器):
///   flutter test integration_test/reader_margin_live_apply_itest.dart -d emulator-5554
/// Run (Windows 离屏):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1 \
///       integration_test/reader_margin_live_apply_itest.dart

bool _webViewShown() =>
    find.byKey(const ValueKey<String>('hoshi_webview')).evaluate().isNotEmpty;

bool _contentReady() => find
    .byKey(const ValueKey<String>('hoshi_content_ready'))
    .evaluate()
    .isNotEmpty;

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready,
  String label, {
  int maxPolls = 120,
}) async {
  for (int i = 0; i < maxPolls; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (ready()) {
      debugPrint('[margin] $label ready after ${i * 500}ms');
      return;
    }
  }
  fail('$label did not become ready');
}

// Reads the live computed geometry that top/bottom margins drive.
const String _measureJs = r'''
(function () {
  var cs = getComputedStyle(document.body);
  var styleEl = document.getElementById('hoshi-reader-style');
  return JSON.stringify({
    innerHeight: window.innerHeight,
    innerWidth: window.innerWidth,
    paddingTop: cs.paddingTop,
    paddingBottom: cs.paddingBottom,
    paddingLeft: cs.paddingLeft,
    paddingRight: cs.paddingRight,
    columnWidth: cs.columnWidth,
    fontSize: cs.fontSize,
    writingMode: cs.writingMode,
    // Does the injected <style> textContent itself carry the new value?
    styleHasMt: styleEl ? (styleEl.textContent.indexOf('${TOKEN}') >= 0) : null
  });
})();
''';

double _px(dynamic v) {
  final String s = v.toString();
  final Match? m = RegExp(r'([-0-9.]+)').firstMatch(s);
  return m == null ? double.nan : double.parse(m.group(1)!);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'reader top/bottom margin change applies live without reopening the book',
    (WidgetTester tester) async {
      await runHibikiItest(
        label: 'margin',
        body: () async {
          app.main();
          expect(await waitForHome(tester), isTrue,
              reason: 'home (nav bar) must render');
          await tester.pump(const Duration(seconds: 2));

          final AppModel appModel = await readyAppModel(tester);
          await appModel.setExperimentalFocusNavigationEnabled(true);
          for (int i = 0; i < 8; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          // Capture originals so we restore global prefs at the end.
          final ReaderHibikiSource src = ReaderHibikiSource.instance;
          final double origMt = src.ttuMarginTop;
          final double origMb = src.ttuMarginBottom;
          final double origFont = src.ttuFontSize;

          await seedReaderBook(tester, fileName: 'margin_live_apply.epub');
          final FocusDriver driver = FocusDriver(tester);

          final List<Finder> navTargets = findPrimaryNavigationTargets();
          if (navTargets.isNotEmpty) {
            await driver.focusWidget(navTargets.first);
            await driver.activate();
            await tester.pump(const Duration(seconds: 1));
          }

          final Finder bookEntries = findBookEntries();
          for (int i = 0; i < 40; i++) {
            await tester.pump(const Duration(milliseconds: 500));
            if (bookEntries.evaluate().isNotEmpty) break;
          }
          expect(bookEntries, findsWidgets,
              reason: 'seeded book must appear on the shelf');
          expect(await driver.focusWidget(bookEntries.first), isTrue,
              reason: 'book card must be reachable by focus');
          await driver.activate();
          await tester.pump(const Duration(seconds: 3));

          await _waitFor(tester, _webViewShown, 'reader WebView');
          await _waitFor(tester, _contentReady, 'hoshi content');

          final Future<dynamic> Function(String source)? runJs =
              ReaderHibikiPage.debugEvaluateJavascript;
          expect(runJs, isNotNull,
              reason: 'reader must expose debugEvaluateJavascript hook');

          // Distinctive target values so we can detect the exact string in CSS
          // and unambiguous px deltas in computed padding.
          const double targetMt = 17;
          const double targetMb = 13;
          const double targetFont = 34;

          Future<Map<String, dynamic>> measure(String label) async {
            await runJs!('void document.body.offsetHeight;');
            await tester.pump(const Duration(milliseconds: 300));
            final String js =
                _measureJs.replaceAll('\${TOKEN}', '${targetMt}vh');
            final Object? raw = await runJs(js);
            final Map<String, dynamic> m =
                jsonDecode(raw.toString()) as Map<String, dynamic>;
            debugPrint('[margin] === $label ===');
            debugPrint('[margin] $m');
            return m;
          }

          final Map<String, dynamic> before =
              await measure('BEFORE margin change');
          final double innerH = _px(before['innerHeight']);
          final double beforePadTop = _px(before['paddingTop']);
          final double beforePadBottom = _px(before['paddingBottom']);
          final double beforeColW = _px(before['columnWidth']);

          // ── Real product path: change top/bottom margin. The setter fires
          //    onSettingsChangedLive == _applyStylesLive (the exact hook the
          //    settings schema onChanged drives via notifyReaderSettingsChanged).
          await src.setReaderMarginTop(targetMt);
          await src.setReaderMarginBottom(targetMb);
          // Let _applyStylesLive + beginStyleReanchor + postFrame commit settle.
          for (int i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }

          final Map<String, dynamic> afterMargin =
              await measure('AFTER margin change (no reopen)');
          final double afterPadTop = _px(afterMargin['paddingTop']);
          final double afterPadBottom = _px(afterMargin['paddingBottom']);
          final double afterColW = _px(afterMargin['columnWidth']);
          final bool styleHasMt = afterMargin['styleHasMt'] == true;

          // ── Control: change font size on the same live path.
          final Map<String, dynamic> beforeFont = afterMargin;
          final double beforeFontPx = _px(beforeFont['fontSize']);
          await src.setReaderFontSize(targetFont);
          for (int i = 0; i < 12; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          final Map<String, dynamic> afterFont =
              await measure('AFTER font change (no reopen)');
          final double afterFontPx = _px(afterFont['fontSize']);

          // Restore global prefs so we don't pollute the user's real settings.
          await src.setReaderMarginTop(origMt);
          await src.setReaderMarginBottom(origMb);
          await src.setReaderFontSize(origFont);
          for (int i = 0; i < 4; i++) {
            await tester.pump(const Duration(milliseconds: 200));
          }

          // body padding-top = calc(mt vh + chrome-top-inset); padding-bottom =
          // calc(mb vh + fontSize + chrome-bottom-inset). The chrome/font terms
          // are identical between BEFORE and AFTER-margin (font unchanged until
          // the later control step), so the DELTA isolates exactly the margin
          // contribution: Δpad-top ≈ targetMt% of innerHeight, Δpad-bottom ≈
          // targetMb% — robust to whatever chrome insets the platform applies.
          final double expectedDeltaTop = innerH * targetMt / 100.0;
          final double expectedDeltaBottom = innerH * targetMb / 100.0;
          final double actualDeltaTop = afterPadTop - beforePadTop;
          final double actualDeltaBottom = afterPadBottom - beforePadBottom;

          debugPrint('[margin] innerH=$innerH');
          debugPrint('[margin] padTop  before=$beforePadTop after=$afterPadTop '
              'Δ=$actualDeltaTop expectedΔ≈$expectedDeltaTop');
          debugPrint(
              '[margin] padBot  before=$beforePadBottom after=$afterPadBottom '
              'Δ=$actualDeltaBottom expectedΔ≈$expectedDeltaBottom');
          debugPrint('[margin] colW    before=$beforeColW after=$afterColW');
          debugPrint(
              '[margin] styleTextContent carries ${targetMt}vh: $styleHasMt');
          debugPrint(
              '[margin] fontSize before=$beforeFontPx after=$afterFontPx '
              'target=$targetFont');

          // ── Assertions ──────────────────────────────────────────────────
          // 1) The injected <style> must literally carry the new margin value
          //    after a live change (proves _applyStylesLive regenerated + the
          //    paginated shell's beginStyleReanchor swapped the CSS). If false →
          //    CSS was never swapped = the reported "must reopen" bug (BUG-849:
          //    paginated shell lacked beginStyleReanchor entirely).
          expect(styleHasMt, isTrue,
              reason: 'live CSS swap missing: #hoshi-reader-style textContent '
                  'does not carry ${targetMt}vh after setReaderMarginTop');

          // 2) Computed body padding-top/bottom must grow by the new margins
          //    WITHOUT reopening the book (delta isolates the margin term).
          expect((actualDeltaTop - expectedDeltaTop).abs(),
              lessThan(innerH * 0.03),
              reason:
                  'top margin did NOT apply live: Δpadding-top=$actualDeltaTop '
                  '(expected ≈$expectedDeltaTop). This is the reported '
                  '"must reopen the book" bug.');
          expect((actualDeltaBottom - expectedDeltaBottom).abs(),
              lessThan(innerH * 0.03),
              reason: 'bottom margin did NOT apply live: '
                  'Δpadding-bottom=$actualDeltaBottom (expected ≈$expectedDeltaBottom).');

          // 3) Control: font size must apply live on the same path.
          expect((afterFontPx - targetFont).abs(), lessThan(2.0),
              reason: 'font size did NOT apply live either → shared live-CSS '
                  'channel is broken, not a margin-specific bug.');
        },
      );
    },
  );
}
