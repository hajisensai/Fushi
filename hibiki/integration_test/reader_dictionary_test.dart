import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

import 'test_helpers.dart';

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

  testWidgets('reader opens, content loads, dictionary search works',
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

      final bool homeReady = await waitForHome(tester);
      expect(homeReady, isTrue, reason: 'Home must render within 90s');
      await tester.pump(const Duration(seconds: 2));

      screenshotCount += await takeScreenshot(binding, 'reader_test_home');

      // ── Phase 1: Open a book from the shelf ──

      final Finder bookEntries = findBookEntries();

      if (bookEntries.evaluate().isEmpty) {
        fail('Reader test blocked: no books on shelf. '
            'Import the Kagami EPUB fixture first. '
            'See CLAUDE.md § 集成测试流程.');
      }

      debugPrint(
          '[reader] Found ${bookEntries.evaluate().length} book(s) on shelf');

      await tester.tap(bookEntries.first);
      await tester.pump(const Duration(seconds: 3));

      screenshotCount += await takeScreenshot(binding, 'reader_opening');

      // ── Phase 2: Verify Hoshi WebView loads ──

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

      // ── Phase 3: Wait for content ready ──

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

      screenshotCount += await takeScreenshot(binding, 'reader_content_ready');

      // Allow JS progress callback to arrive.
      await tester.pump(const Duration(seconds: 4));

      // Verify progress indicator.
      final Finder progressText =
          find.byKey(const ValueKey<String>('hoshi_progress'));
      if (progressText.evaluate().isNotEmpty) {
        final Text textWidget = tester.widget(progressText) as Text;
        debugPrint('[reader] Progress text: ${textWidget.data}');
        expect(textWidget.data, isNotNull,
            reason: 'Progress text must have content');
      }

      // ── Phase 4: Check play bar bounds (HBK-REG-001) ──

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

        screenshotCount +=
            await takeScreenshot(binding, 'reader_with_playbar');
      }

      // ── Phase 5: Navigate back and test dictionary ──

      // Go back to home.
      final NavigatorState nav = Navigator.of(
        tester.element(find.byType(Scaffold).first),
      );
      nav.pop();
      await tester.pump(const Duration(seconds: 3));

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

      screenshotCount += await takeScreenshot(binding, 'dict_search_field');

      // Type a known word and verify results appear.
      await tester.enterText(findSearchField(), '猫');
      await tester.pump(const Duration(seconds: 5));

      final int resultWidgets =
          find.byType(Card).evaluate().length +
              find.byType(ListTile).evaluate().length +
              find.byType(ExpansionTile).evaluate().length;

      debugPrint('[reader] Dict results: $resultWidgets widgets');

      if (resultWidgets == 0) {
        fail('Dictionary search for 猫 returned zero results. '
            'This test requires at least one dictionary imported. '
            'See CLAUDE.md § 集成测试流程.');
      }

      screenshotCount += await takeScreenshot(binding, 'dict_search_result');

      expect(screenshotCount, greaterThan(0),
          reason: 'At least one screenshot must succeed');

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
