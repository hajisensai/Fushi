import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/reader_settings.dart';

import 'test_helpers.dart';

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
///   $env:FUSHI_TEST_HIDDEN = "1"
///   flutter test integration_test/desktop_reader_css_dom_test.dart -d windows
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String html = '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
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

  testWidgets(
      'BUG-803: dimensionless inline gaiji ignores dictionary 15em width and '
      '2em end margin in the live WebView engine', (WidgetTester tester) async {
    final String popupJs = await rootBundle.loadString('assets/popup/popup.js');
    final String popupCss =
        await rootBundle.loadString('assets/popup/popup.css');
    final String dictMediaJs =
        await rootBundle.loadString('assets/popup/dict-media.js');
    final Completer<InAppWebViewController> ready =
        Completer<InAppWebViewController>();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: InAppWebView(
          initialData: InAppWebViewInitialData(
            data: '<!DOCTYPE html><html><head><meta charset="utf-8"></head>'
                '<body style="font-size:20px"></body></html>',
          ),
          onLoadStop: (InAppWebViewController controller, WebUri? url) {
            if (!ready.isCompleted) ready.complete(controller);
          },
        ),
      ),
    ));
    for (int i = 0; i < 150 && !ready.isCompleted; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(ready.isCompleted, isTrue,
        reason: 'WebView did not load within 15s');
    final InAppWebViewController controller = await ready.future;

    await controller.evaluateJavascript(source: '''
      window.flutter_inappwebview = {
        callHandler: function() { return Promise.resolve(true); }
      };
    ''');
    await controller.evaluateJavascript(
      source: '$dictMediaJs\n$popupJs\nwindow.__bug803CreateDefinitionImage = '
          'createDefinitionImage;',
    );
    final Object? raw = await controller.evaluateJavascript(source: '''
      (function() {
        try {
        var base = document.createElement('style');
        base.textContent = ${jsonEncode(popupCss)};
        document.head.appendChild(base);

        var dictionary = document.createElement('style');
        dictionary.textContent =
          'span[data-sc-img][data-sc-class="gaiji"] .gloss-image-container {' +
          'width: 15em !important; margin-inline-end: 2em; }';
        document.head.appendChild(dictionary);

        var row = document.createElement('div');
        row.style.whiteSpace = 'nowrap';
        var gaiji = document.createElement('span');
        gaiji.dataset.scImg = '';
        gaiji.dataset.scClass = 'gaiji';
        gaiji.appendChild(window.__bug803CreateDefinitionImage({
          tag: 'img',
          path: 'gaiji/対義語.svg',
          background: false,
          collapsed: false,
          collapsible: false,
          data: {
            img: '', gaiji: '', class: 'gaiji',
            alt: '［対義語］', src: 'gaiji/対義語.svg'
          }
        }, '明鏡国語辞典 第三版', false));
        var reference = document.createElement('a');
        reference.textContent = '以内';
        row.appendChild(gaiji);
        row.appendChild(reference);
        document.body.replaceChildren(row);

        var imageContainer = gaiji.querySelector('.gloss-image-container');
        var rowRect = row.getBoundingClientRect();
        var imageRect = imageContainer.getBoundingClientRect();
        var referenceRect = reference.getBoundingClientRect();
        return JSON.stringify({
          imageWidth: imageRect.width,
          referenceOffset: referenceRect.left - rowRect.left,
          referenceGap: referenceRect.left - imageRect.right,
          computedWidth: getComputedStyle(imageContainer).width,
          computedMarginInlineEnd:
            getComputedStyle(imageContainer).marginInlineEnd,
          inlinePriority: imageContainer.style.getPropertyPriority('width'),
          marginPriority:
            imageContainer.style.getPropertyPriority('margin-inline-end')
        });
        } catch (error) {
          return JSON.stringify({
            error: String(error),
            stack: String(error && error.stack),
            createType: typeof window.__bug803CreateDefinitionImage
          });
        }
      })();
    ''');
    await tester.pump(const Duration(seconds: 2));
    await takeScreenshot(binding, 'bug803_inline_gaiji_webview2_verified');

    final Map<String, dynamic> geometry =
        jsonDecode(raw?.toString() ?? '{}') as Map<String, dynamic>;
    debugPrint('[BUG-803] inline gaiji geometry: ${jsonEncode(geometry)}');
    expect(geometry['error'], isNull,
        reason: 'the real popup renderer must execute in WebView2');
    final double imageWidth = (geometry['imageWidth'] as num).toDouble();
    final double referenceOffset =
        (geometry['referenceOffset'] as num).toDouble();
    final double referenceGap = (geometry['referenceGap'] as num).toDouble();
    expect(geometry['inlinePriority'], 'important');
    expect(geometry['marginPriority'], 'important');
    expect(geometry['computedMarginInlineEnd'], '0px');
    expect(imageWidth, lessThan(40),
        reason: '20px text should keep the inline gaiji near 1.2em, not 15em');
    expect(referenceOffset, lessThan(40),
        reason: 'the adjacent 以内 link must remain next to the gaiji label');
    expect(referenceGap.abs(), lessThan(1),
        reason:
            'dictionary margin-inline-end must not leave a gap after gaiji');
  });
}
