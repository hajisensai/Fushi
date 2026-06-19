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

      final FocusDriver driver = FocusDriver(tester);

      Finder bookEntries = findBookEntries();
      if (bookEntries.evaluate().isEmpty) {
        await seedReaderBook(tester);
        bookEntries = findBookEntries();
      }
      expect(bookEntries, findsWidgets);
      final bool focusedBook = await driver.focusWidget(bookEntries.first);
      expect(focusedBook, isTrue,
          reason: 'Book card must be reachable by focus');
      await driver.activate();
      await tester.pump(const Duration(seconds: 3));

      const Key webViewKey = ValueKey<String>('hoshi_webview');
      await _waitFor(tester, find.byKey(webViewKey), 'Hoshi WebView');
      await _waitFor(
        tester,
        find.byKey(const ValueKey<String>('hoshi_content_ready')),
        'Hoshi content ready',
      );

      final eval = ReaderHibikiPage.debugEvaluateJavascript;
      expect(eval, isNotNull);
      await eval!(paginationHarnessJs);
      final PageData before = _firstPageData(
        await eval('window.hoshiTestHarness.fullChapterScan();') as String,
      );
      await eval('window.hoshiReader.paginate("forward");');
      await tester.pump(const Duration(seconds: 1));
      final PaginationState after = PaginationState.fromJson(
        jsonDecode(await eval(
          'window.hoshiTestHarness.getPaginationState();',
        ) as String) as Map<String, dynamic>,
      );
      expect(after.scroll, greaterThanOrEqualTo(before.state.scroll));

      final NavigatorState nav = Navigator.of(
        tester.element(find.byType(Scaffold).first),
      );
      nav.pop();
      await tester.pump(const Duration(seconds: 2));

      final List<Finder> navTargets = findPrimaryNavigationTargets();
      expect(navTargets.length, greaterThanOrEqualTo(2));
      final bool focusedDict = await driver.focusWidget(navTargets[1]);
      expect(focusedDict, isTrue,
          reason: 'Dictionary tab must be reachable by focus');
      await driver.activate();
      await tester.pump(const Duration(seconds: 2));
      await tester.enterText(findSearchField(), 'testword');
      await tester.pump(const Duration(seconds: 5));
      expect(findDictionaryResultEvidence(), findsWidgets);

      await takeScreenshot(binding, 'comprehensive_reader_lookup');
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<void> _waitFor(WidgetTester tester, Finder finder, String label) async {
  for (int i = 0; i < 120; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('$label did not appear');
}

PageData _firstPageData(String raw) {
  final List<PageData> pages = parseChapterScan(raw);
  expect(pages, isNotEmpty);
  return pages.first;
}
