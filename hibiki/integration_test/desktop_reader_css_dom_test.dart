import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

/// Phase 2 Step 3 — desktop T3 effect probe (the last mile T1 can't reach).
///
/// T1 (`reader_content_styles_test`) proves the CSS *string* is generated
/// correctly. This proves the generated CSS is actually APPLIED by the real
/// WebView engine: inject `ReaderContentStyles.css` for two font sizes into a
/// live [InAppWebView] and read back `getComputedStyle(document.body).fontSize`
/// — the computed DOM value must follow the setting (the reader sets
/// `body { font-size: <fontSize>px !important; }`, reader_content_styles.dart).
/// On Windows this exercises the forked flutter_inappwebview_windows engine.
///
/// Run (PowerShell, from hibiki/):
///   $env:HIBIKI_TEST_HIDDEN = "1"
///   flutter test integration_test/desktop_reader_css_dom_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String html =
      '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
      '<body><p>本文のテスト文字列</p></body></html>';

  testWidgets(
      'generated reader CSS really applies in a live WebView (computed font-size '
      'follows the setting)', (WidgetTester tester) async {
    final HibikiDatabase db =
        HibikiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ReaderSettings settings = ReaderSettings(db);
    await settings.refreshFromDb();

    final Completer<void> driven = Completer<void>();
    String? computedAt20;
    String? computedAt40;

    // Injects the current ReaderContentStyles.css into the page (replacing any
    // previous injection) and returns getComputedStyle(body).fontSize.
    Future<String?> applyAndMeasure(
        InAppWebViewController controller, double fontSize) async {
      await settings.setFontSize(fontSize);
      final String css = ReaderContentStyles.css(settings: settings);
      await controller.evaluateJavascript(source: '''
        (function() {
          var s = document.getElementById('hibiki-test-style');
          if (!s) {
            s = document.createElement('style');
            s.id = 'hibiki-test-style';
            document.head.appendChild(s);
          }
          s.textContent = ${jsonEncode(css)};
        })();
      ''');
      final Object? v = await controller.evaluateJavascript(
        source: 'getComputedStyle(document.body).fontSize',
      );
      return v?.toString();
    }

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(data: html),
          onLoadStop: (InAppWebViewController controller, WebUri? url) async {
            computedAt20 = await applyAndMeasure(controller, 20);
            computedAt40 = await applyAndMeasure(controller, 40);
            if (!driven.isCompleted) driven.complete();
          },
        ),
      ),
    ));

    for (int i = 0; i < 150 && !driven.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(driven.isCompleted, isTrue,
        reason: 'WebView did not load + apply CSS within 15s');
    await tester.pump(const Duration(seconds: 1));

    double pxOf(String? v) =>
        double.tryParse((v ?? '').replaceAll('px', '').trim()) ?? -1;

    final double at20 = pxOf(computedAt20);
    final double at40 = pxOf(computedAt40);
    debugPrint('[reader-css-dom] computed font-size: '
        'fontSize=20 -> $computedAt20 ; fontSize=40 -> $computedAt40');

    expect(at20, closeTo(20, 0.5),
        reason: 'fontSize=20 setting must compute to ~20px in the live DOM');
    expect(at40, closeTo(40, 0.5),
        reason: 'fontSize=40 setting must compute to ~40px in the live DOM');
    expect(at40, greaterThan(at20),
        reason: 'raising the font-size setting must raise the computed DOM '
            'font-size — proves the generated CSS is applied, not just emitted');
  });
}
