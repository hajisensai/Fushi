import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/pagination_test_harness.dart';
import 'test_helpers.dart';

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('comprehensive reader page turn and dictionary lookup',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[comprehensive-reader] ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));
      expect(await seedDictionary(tester), isTrue);
      final appModel = await readyAppModel(tester);
      await appModel.setExperimentalFocusNavigationEnabled(true);
      for (int i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }

      final FocusDriver driver = FocusDriver(tester);

      Finder bookEntries = findBookEntries();
      if (bookEntries.evaluate().isEmpty) {
        await seedReaderBook(tester);
        bookEntries = findBookEntries();
      }
      expect(bookEntries, findsWidgets);

      const Key webViewKey = ValueKey<String>('hoshi_webview');
      await _openBookEntry(
        tester,
        driver,
        bookEntries.first,
        find.byKey(webViewKey),
      );
      await _waitFor(tester, find.byKey(webViewKey), 'Hoshi WebView');
      await _waitFor(
        tester,
        find.byKey(const ValueKey<String>('hoshi_content_ready')),
        'Hoshi content ready',
      );

      final eval = ReaderHibikiPage.debugEvaluateJavascript;
      expect(eval, isNotNull);
      await eval!(paginationHarnessJs);
      final PaginationState before = PaginationState.fromJson(
        jsonDecode(await eval(
          'window.hoshiTestHarness.getPaginationState();',
        ) as String) as Map<String, dynamic>,
      );
      await eval('window.hoshiReader.paginate("forward");');
      await tester.pump(const Duration(seconds: 1));
      final PaginationState after = PaginationState.fromJson(
        jsonDecode(await eval(
          'window.hoshiTestHarness.getPaginationState();',
        ) as String) as Map<String, dynamic>,
      );
      expect(after.scroll, greaterThanOrEqualTo(before.scroll));

      final NavigatorState nav = Navigator.of(
        tester.element(find.byType(Scaffold).first),
      );
      nav.pop();
      await tester.pump(const Duration(seconds: 2));

      final lookup = await appModel.searchDictionary(
        searchTerm: 'testword',
        searchWithWildcards: false,
        allowRemoteLookup: false,
        useCache: false,
      );
      expect(lookup.entries, isNotEmpty,
          reason: 'Generated test dictionary must resolve "testword"');

      await takeScreenshot(binding, 'comprehensive_reader_lookup');
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<void> _openBookEntry(
  WidgetTester tester,
  FocusDriver driver,
  Finder bookEntry,
  Finder webView,
) async {
  final bool focusedBook = await driver.requestFocusInside(
    bookEntry,
    debugLabelContains: 'reader-shelf-',
  );
  expect(focusedBook, isTrue, reason: 'Book card must be reachable by focus');

  await driver.activate();
  if (await _waitForOptional(tester, webView,
      polls: 12, interval: const Duration(milliseconds: 250))) {
    return;
  }

  if (await driver.activateIntent()) {
    if (await _waitForOptional(tester, webView,
        polls: 12, interval: const Duration(milliseconds: 250))) {
      return;
    }
  }
}

Future<void> _waitFor(WidgetTester tester, Finder finder, String label) async {
  final bool found = await _waitForOptional(
    tester,
    finder,
    polls: 120,
    interval: const Duration(milliseconds: 500),
  );
  if (!found) fail('$label did not appear');
}

Future<bool> _waitForOptional(
  WidgetTester tester,
  Finder finder, {
  required int polls,
  required Duration interval,
}) async {
  for (int i = 0; i < polls; i++) {
    await tester.pump(interval);
    if (finder.evaluate().isNotEmpty) return true;
  }
  return false;
}
