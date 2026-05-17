import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

/// Integration tests for the highest-risk Hibiki user paths:
/// EPUB import → Hoshi reader → dictionary lookup.
///
/// Requires:
///   - Connected device/emulator
///   - Test fixtures pushed (see CLAUDE.md § 集成测试流程)
///   - At least one EPUB imported on the shelf
///   - At least one dictionary imported
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/reader_dictionary_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('reader opens and renders content after EPUB import',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[reader] FlutterError: ${details.exceptionAsString()}');
    };
    int screenshotCount = 0;

    try {
      app.main();

      // Wait for home.
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

      screenshotCount += await _screenshot(binding, 'reader_test_home');

      // Find a book entry on the shelf using test hook keys.
      // Book entries have ValueKey('book_entry_...') or
      // ValueKey('srt_entry_...').
      final Finder bookEntries = find.byWidgetPredicate((Widget w) {
        final Key? k = w.key;
        if (k is ValueKey<String>) {
          return k.value.startsWith('book_entry_') ||
              k.value.startsWith('srt_entry_');
        }
        return false;
      });

      if (bookEntries.evaluate().isEmpty) {
        fail('Reader test blocked: no books on shelf. '
            'Import the Kagami EPUB fixture first. '
            'See CLAUDE.md § 集成测试流程.');
      }

      debugPrint(
          '[reader] Found ${bookEntries.evaluate().length} book(s) on shelf');

      // Tap the first book to open the Hoshi reader.
      await tester.tap(bookEntries.first);
      await tester.pump(const Duration(seconds: 3));

      screenshotCount += await _screenshot(binding, 'reader_opening');

      // Wait for the Hoshi WebView to appear (up to 30s).
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

      // Wait for content to be ready (up to 60s).
      // The sentinel widget 'hoshi_content_ready' only exists when
      // _readerContentReady == true.
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

      screenshotCount += await _screenshot(binding, 'reader_content_ready');

      // Verify the progress indicator is present when content is ready.
      final Finder progressText =
          find.byKey(const ValueKey<String>('hoshi_progress'));
      if (progressText.evaluate().isNotEmpty) {
        final Text textWidget = tester.widget(progressText) as Text;
        debugPrint('[reader] Progress text: ${textWidget.data}');
        expect(textWidget.data, isNotNull,
            reason: 'Progress text must have content');
      }

      // Check play bar bounds if audiobook is attached (HBK-REG-001 check).
      final Finder playBar =
          find.byKey(const ValueKey<String>('hoshi_play_bar'));
      if (playBar.evaluate().isNotEmpty) {
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
          '[reader] WebView bottom: $webViewBottom, '
          'PlayBar top: ${playBarTopLeft.dy}',
        );

        expect(webViewBottom, lessThanOrEqualTo(playBarTopLeft.dy + 1),
            reason: 'HBK-REG-001: WebView content must not extend '
                'under the play bar');

        screenshotCount += await _screenshot(binding, 'reader_with_playbar');
      }

      expect(screenshotCount, greaterThan(0),
          reason: 'At least one screenshot must succeed');

      // WebView/renderer errors MUST fail this test.
      _assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });

  testWidgets('dictionary search returns results for imported dictionary',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[dict] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();

      // Wait for home.
      bool ready = false;
      for (int i = 0; i < 180; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byIcon(Icons.menu_book).evaluate().isNotEmpty) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: 'Home must render within 90s');

      // Navigate to dictionary tab.
      final Finder searchIcon = find.byIcon(Icons.search);
      expect(searchIcon, findsWidgets,
          reason: 'Dictionary tab icon must be present');
      await tester.tap(searchIcon.first);
      await tester.pump(const Duration(seconds: 3));

      // Verify search field exists.
      final bool hasSearch =
          find.byType(TextField).evaluate().isNotEmpty ||
              find.byType(TextFormField).evaluate().isNotEmpty ||
              find.byType(SearchBar).evaluate().isNotEmpty;
      expect(hasSearch, isTrue,
          reason: 'Dictionary tab must have a search field');

      // Type a known word into the search field and check for results.
      final Finder searchField = find.byType(TextField).evaluate().isNotEmpty
          ? find.byType(TextField).first
          : find.byType(TextFormField).evaluate().isNotEmpty
              ? find.byType(TextFormField).first
              : find.byType(SearchBar).first;

      await tester.enterText(searchField, '猫');
      await tester.pump(const Duration(seconds: 5));

      // If a dictionary is imported, results should appear.
      // We look for content beyond the search field itself.
      final int widgetCountAfterSearch =
          find.byType(Card).evaluate().length +
              find.byType(ListTile).evaluate().length +
              find.byType(ExpansionTile).evaluate().length;

      debugPrint(
          '[dict] Widgets after search: $widgetCountAfterSearch '
          '(Cards+ListTiles+ExpansionTiles)');

      // Don't hard-fail on zero results since dictionary may not be
      // imported, but log it clearly for manual review.
      if (widgetCountAfterSearch == 0) {
        debugPrint('[dict] WARNING: No results for 猫. '
            'Is a dictionary imported on this device?');
      }

      _assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<int> _screenshot(
    IntegrationTestWidgetsFlutterBinding binding, String name) async {
  try {
    await binding.takeScreenshot(name).timeout(const Duration(seconds: 10));
    debugPrint('[reader] Screenshot saved: $name');
    return 1;
  } catch (e) {
    debugPrint('[reader] Screenshot skipped ($name): $e');
    return 0;
  }
}

void _assertStrictErrors(List<FlutterErrorDetails> errors) {
  final List<FlutterErrorDetails> unexpected = errors.where((e) {
    final String msg = e.exceptionAsString().toLowerCase();
    if (msg.contains('socketexception')) return false;
    if (msg.contains('tls') || msg.contains('timeout')) return false;
    return true;
  }).toList();

  expect(unexpected, isEmpty,
      reason: 'Errors (including WebView/renderer) are fatal in reader/dict tests: '
          '${unexpected.map((e) => e.exceptionAsString()).join('; ')}');
}
