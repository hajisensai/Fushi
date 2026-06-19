import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'test_helpers.dart';

/// Verifies that keyboard page-turn shortcuts actually reach the reader's
/// Focus.onKeyEvent — INCLUDING after the user has tapped into the WebView
/// content (the scenario where a platform view could plausibly steal focus).
///
/// STATUS: NOT YET VERIFIED on any device. `flutter analyze` is clean, but the
/// only available emulator (emulator-5556) crashes its WebView renderer while
/// loading reader content, so this never reached the keyboard phase. Treat as a
/// regression guard pending a run on a device with a working WebView. See
/// docs/REGRESSION_BUGS.md (HBK #1).
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/reader_keyboard_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<String?> readProgress(WidgetTester tester) async {
    final Finder progress =
        find.byKey(const ValueKey<String>('hoshi_progress'));
    if (progress.evaluate().isEmpty) return null;
    final Text widget = tester.widget(progress) as Text;
    return widget.data;
  }

  Future<void> sendPageForward(WidgetTester tester, int times) async {
    for (int i = 0; i < times; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 900));
    }
    await tester.pump(const Duration(seconds: 2));
  }

  testWidgets('reader page-turn shortcut works before and after WebView tap',
      (WidgetTester tester) async {
    int screenshots = 0;
    app.main();

    final bool homeReady = await waitForHome(tester);
    expect(homeReady, isTrue, reason: 'Home must render');
    await tester.pump(const Duration(seconds: 2));

    final FocusDriver driver = FocusDriver(tester);

    Finder books = findBookEntries();
    if (books.evaluate().isEmpty) {
      // Self-provision the synthetic marker EPUB so the test is hermetic on a
      // fresh install (no manual import step required).
      await seedReaderBook(tester);
      books = findBookEntries();
    }
    expect(books, findsWidgets,
        reason: 'A book must be on the shelf after seeding the fixture');
    final bool focusedBook = await driver.focusWidget(books.first);
    expect(focusedBook, isTrue, reason: 'Book card must be reachable by focus');
    await driver.activate();
    await tester.pump(const Duration(seconds: 3));

    const Key webViewKey = ValueKey<String>('hoshi_webview');
    bool webViewFound = false;
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(webViewKey).evaluate().isNotEmpty) {
        webViewFound = true;
        break;
      }
    }
    expect(webViewFound, isTrue, reason: 'WebView must appear');

    const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
    bool ready = false;
    for (int i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
        ready = true;
        break;
      }
    }
    expect(ready, isTrue, reason: 'Content must become ready');
    await tester.pump(const Duration(seconds: 4));

    screenshots += await takeScreenshot(binding, 'kbd_initial');
    final String? p0 = await readProgress(tester);
    debugPrint('[kbd] progress @start: $p0');

    // ── Phase A: page forward via keyboard BEFORE touching the WebView ──
    await sendPageForward(tester, 6);
    final String? p1 = await readProgress(tester);
    debugPrint('[kbd] progress after pre-tap page-forward: $p1');
    screenshots += await takeScreenshot(binding, 'kbd_after_pretap');

    final bool movedBeforeTap = p0 != null && p1 != null && p0 != p1;
    expect(movedBeforeTap, isTrue,
        reason: 'Keyboard page-forward must move the reader position '
            '(baseline). p0=$p0 p1=$p1');

    // ── Phase B: tap into the WebView content, then page forward again ──
    await tester.tap(find.byKey(
        webViewKey)); // itest-tap-allow: taps the platform WebView on purpose to prove it does not steal keyboard focus (HBK #1)
    await tester.pump(const Duration(seconds: 1));
    screenshots += await takeScreenshot(binding, 'kbd_after_webview_tap');

    await sendPageForward(tester, 6);
    final String? p2 = await readProgress(tester);
    debugPrint('[kbd] progress after post-tap page-forward: $p2');
    screenshots += await takeScreenshot(binding, 'kbd_after_posttap');

    final bool movedAfterTap = p1 != null && p2 != null && p1 != p2;
    expect(movedAfterTap, isTrue,
        reason: 'HBK #1: keyboard page-forward must STILL work after tapping '
            'into the WebView content. p1=$p1 p2=$p2');

    if (screenshotsAreRequired) {
      expect(screenshots, greaterThan(0));
    }
  });
}
