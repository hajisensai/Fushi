import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

/// Regression tests for documented bugs in docs/REGRESSION_BUGS.md.
///
/// These require a connected device/emulator with test fixtures pushed to
/// /sdcard/Download/hibiki-test/kagami/. See CLAUDE.md § 集成测试流程.
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/regression_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('HBK-REG-001: play bar must not overlap reader content',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[reg] FlutterError: ${details.exceptionAsString()}');
    };
    int screenshotCount = 0;

    try {
      app.main();

      // Wait for home screen.
      bool ready = false;
      for (int i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byIcon(Icons.menu_book).evaluate().isNotEmpty) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: 'Home must render within 90s');
      await tester.pump(const Duration(seconds: 2));

      screenshotCount += await _screenshot(binding, 'reg001_home');

      // Find a book entry using test hook keys.
      final Finder bookEntries = find.byWidgetPredicate((Widget w) {
        final Key? k = w.key;
        if (k is ValueKey<String>) {
          return k.value.startsWith('book_entry_') ||
              k.value.startsWith('srt_entry_');
        }
        return false;
      });

      if (bookEntries.evaluate().isEmpty) {
        fail('HBK-REG-001 blocked: no books on shelf. '
            'Push fixtures and import before running regression tests. '
            'See CLAUDE.md § 集成测试流程.');
      }

      // Open the first book.
      await tester.tap(bookEntries.first);
      await tester.pump(const Duration(seconds: 3));

      // Wait for Hoshi WebView.
      const Key webViewKey = ValueKey<String>('hoshi_webview');
      bool webViewFound = false;
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(webViewKey).evaluate().isNotEmpty) {
          webViewFound = true;
          break;
        }
      }
      expect(webViewFound, isTrue,
          reason: 'Hoshi WebView must appear after opening a book');

      // Wait for content ready.
      const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
      bool contentReady = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          contentReady = true;
          break;
        }
      }
      expect(contentReady, isTrue,
          reason: 'Reader content must become ready within 60s');

      screenshotCount += await _screenshot(binding, 'reg001_reader_ready');

      // Check play bar vs WebView bounds.
      final Finder playBar =
          find.byKey(const ValueKey<String>('hoshi_play_bar'));
      if (playBar.evaluate().isEmpty) {
        debugPrint('[reg] No play bar found — audiobook may not be attached. '
            'For full HBK-REG-001 verification, import Kagami with '
            'm4b + srt before running.');
      } else {
        final RenderBox playBarBox =
            tester.renderObject(playBar) as RenderBox;
        final Offset playBarTopLeft =
            playBarBox.localToGlobal(Offset.zero);

        final RenderBox webViewBox =
            tester.renderObject(find.byKey(webViewKey)) as RenderBox;
        final Offset webViewTopLeft =
            webViewBox.localToGlobal(Offset.zero);
        final double webViewBottom =
            webViewTopLeft.dy + webViewBox.size.height;

        debugPrint(
          '[reg] WebView bottom: $webViewBottom, '
          'PlayBar top: ${playBarTopLeft.dy}, '
          'PlayBar height: ${playBarBox.size.height}',
        );

        expect(webViewBottom, lessThanOrEqualTo(playBarTopLeft.dy + 1),
            reason: 'HBK-REG-001: Reader WebView must not extend '
                'under the audiobook play bar. '
                'WebView bottom=$webViewBottom, '
                'PlayBar top=${playBarTopLeft.dy}');

        screenshotCount += await _screenshot(binding, 'reg001_bounds_check');
      }

      expect(screenshotCount, greaterThan(0),
          reason: 'At least one screenshot must succeed');

      // WebView errors are NOT allowed in reader regression tests.
      _assertNoWebViewErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<int> _screenshot(
    IntegrationTestWidgetsFlutterBinding binding, String name) async {
  try {
    await binding.takeScreenshot(name).timeout(const Duration(seconds: 10));
    debugPrint('[reg] Screenshot saved: $name');
    return 1;
  } catch (e) {
    debugPrint('[reg] Screenshot skipped ($name): $e');
    return 0;
  }
}

void _assertNoWebViewErrors(List<FlutterErrorDetails> errors) {
  final List<FlutterErrorDetails> unexpected = errors.where((e) {
    final String msg = e.exceptionAsString().toLowerCase();
    if (msg.contains('socketexception')) return false;
    if (msg.contains('tls') || msg.contains('timeout')) return false;
    return true;
  }).toList();

  expect(unexpected, isEmpty,
      reason: 'Reader regression test must not have errors (including WebView): '
          '${unexpected.map((e) => e.exceptionAsString()).join('; ')}');
}
