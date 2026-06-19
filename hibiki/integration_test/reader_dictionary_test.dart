import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
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

      final FocusDriver driver = FocusDriver(tester);

      screenshotCount += await takeScreenshot(binding, 'reader_test_home');

      // Self-provision the synthetic book + the dictionary the runner pushed to
      // /sdcard/Download/test_dict.zip, so the test is hermetic on a fresh
      // install (no manual import step required).
      final bool dictSeeded = await seedDictionary(tester);
      expect(dictSeeded, isTrue,
          reason: 'Dictionary fixture must import. Push a Yomitan zip to '
              '/sdcard/Download/test_dict.zip (the runner does this).');

      // ── Phase 1: Open a book from the shelf ──

      Finder bookEntries = findBookEntries();

      if (bookEntries.evaluate().isEmpty) {
        await seedReaderBook(tester);
        bookEntries = findBookEntries();
      }
      expect(bookEntries, findsWidgets,
          reason: 'A book must be on the shelf after seeding the fixture');

      debugPrint(
          '[reader] Found ${bookEntries.evaluate().length} book(s) on shelf');

      final bool focusedBook = await driver.focusWidget(bookEntries.first);
      expect(focusedBook, isTrue,
          reason: 'Book card must be reachable by focus');
      await driver.activate();
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
        final RenderBox playBarBox = tester.renderObject(playBar) as RenderBox;
        final Offset playBarTopLeft = playBarBox.localToGlobal(Offset.zero);

        final RenderBox webViewBox =
            tester.renderObject(find.byKey(webViewKey)) as RenderBox;
        final Offset webViewTopLeft = webViewBox.localToGlobal(Offset.zero);
        final double webViewBottom = webViewTopLeft.dy + webViewBox.size.height;

        debugPrint(
          '[reader] WebView bottom: $webViewBottom, '
          'PlayBar top: ${playBarTopLeft.dy}',
        );

        expect(webViewBottom, lessThanOrEqualTo(playBarTopLeft.dy + 1),
            reason: 'HBK-REG-001: WebView content must not extend '
                'under the play bar');

        screenshotCount += await takeScreenshot(binding, 'reader_with_playbar');
      }

      // ── Phase 5: Navigate back and test dictionary ──

      // Go back to home.
      final NavigatorState nav = Navigator.of(
        tester.element(find.byType(Scaffold).first),
      );
      nav.pop();
      await tester.pump(const Duration(seconds: 3));

      // Navigate to dictionary tab.
      final List<Finder> navTargets = findPrimaryNavigationTargets();
      expect(navTargets.length, greaterThanOrEqualTo(2),
          reason: 'Dictionary tab navigation target must be present');
      final bool focusedTab = await driver.focusWidget(navTargets[1]);
      expect(focusedTab, isTrue,
          reason: 'Dictionary tab must be reachable by focus');
      await driver.activate();
      await tester.pump(const Duration(seconds: 3));

      // Verify search field exists.
      final bool hasSearch = find.byType(TextField).evaluate().isNotEmpty ||
          find.byType(TextFormField).evaluate().isNotEmpty ||
          find.byType(SearchBar).evaluate().isNotEmpty;
      expect(hasSearch, isTrue,
          reason: 'Dictionary tab must have a search field');

      screenshotCount += await takeScreenshot(binding, 'dict_search_field');

      // Type a known word and verify results appear.
      await tester.enterText(findSearchField(), '猫');
      await tester.pump(const Duration(seconds: 5));

      final Finder resultEvidence = findDictionaryResultEvidence();
      final int resultCount = resultEvidence.evaluate().length;
      debugPrint('[reader] Dict result evidence: $resultCount widgets');

      if (resultCount == 0) {
        fail('Dictionary search for 猫 returned zero results. '
            'This test requires at least one dictionary imported. '
            'See CLAUDE.md § 集成测试流程.');
      }

      screenshotCount += await takeScreenshot(binding, 'dict_search_result');

      // Screenshots are best-effort evidence, not a pass/fail signal: the
      // integration_test binding's takeScreenshot needs
      // convertFlutterSurfaceToImage(), which is incompatible with the live
      // Hoshi WebView platform view (it throws "Call
      // convertFlutterSurfaceToImage() before taking a screenshot"), so on a
      // WebView screen screenshotCount legitimately stays 0. The real behaviour
      // — dictionary search returning results — is asserted above. Matches the
      // best-effort screenshot handling in the other reader integration tests.
      debugPrint('[reader] screenshots captured: $screenshotCount');

      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
