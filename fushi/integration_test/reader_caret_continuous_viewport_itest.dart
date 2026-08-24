import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/reader/reader_caret_scripts.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'continuous caret enters a visible glyph after scrolling beyond one viewport',
    (WidgetTester tester) async {
      final Completer<void> ready = Completer<void>();
      InAppWebViewController? controller;
      const String html = '''<!doctype html>
<html><head><meta charset="utf-8"><style>
html { overflow-y: auto; }
body { margin: 0; }
#spacer { height: 5000px; }
#target { margin: 0; font-size: 32px; line-height: 1.8; height: 1200px; }
</style></head><body>
<div id="spacer"></div>
<p id="target">連続スクロール後も文字カーソルが見える位置を選べます。</p>
</body></html>''';

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InAppWebView(
              initialData: InAppWebViewInitialData(data: html),
              onLoadStop: (InAppWebViewController value, WebUri? url) {
                controller = value;
                if (!ready.isCompleted) ready.complete();
              },
            ),
          ),
        ),
      );

      for (int i = 0; i < 150 && !ready.isCompleted; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(ready.isCompleted, isTrue, reason: 'WebView did not load in 15s');
      final InAppWebViewController webView = controller!;
      await webView.evaluateJavascript(source: ReaderCaretScripts.source());
      await webView.evaluateJavascript(
        source: '''
        document.getElementById('target').scrollIntoView();
        window.scrollBy(0, -120);
      ''',
      );
      await tester.pump(const Duration(milliseconds: 500));

      final Object? raw = await webView.evaluateJavascript(
        source: '''
        (function () {
          var target = document.getElementById('target').getBoundingClientRect();
          var status = window.fushiCaret.enter();
          return JSON.stringify({
            scrollY: window.scrollY,
            innerHeight: window.innerHeight,
            bodyTop: document.body.getBoundingClientRect().top,
            targetTop: target.top,
            targetBottom: target.bottom,
            paged: window.fushiCaret._paged(),
            enter: status,
            char: window.fushiCaret.node
              ? window.fushiCaret.node.textContent.substr(window.fushiCaret.offset, 1)
              : null
          });
        })();
      ''',
      );
      final Map<String, dynamic> state =
          jsonDecode(raw as String) as Map<String, dynamic>;

      expect(state['paged'], isFalse);
      expect(state['scrollY'] as num, greaterThan(state['innerHeight'] as num));
      expect(state['bodyTop'] as num, lessThan(-(state['innerHeight'] as num)));
      expect(state['targetTop'] as num, lessThan(state['innerHeight'] as num));
      expect(state['targetBottom'] as num, greaterThan(0));
      expect(ReaderCaretScripts.moveStatus(state['enter']), 'moved');
      expect(state['char'], isNotNull);
    },
  );
}
