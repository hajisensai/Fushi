import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/pages/implementations/reader_hibiki_page.dart';

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

      // 书架是惰性构建的保活 tab，冷启动落在 dashboard；不先切过去，
      // `book_entry_*` 书卡不在树中，seedReaderBook 的可见性轮询必然超时
      // （与 macos_reader_screenshot / macos_todo1375 同根因同修法）。
      await showBooksTab(tester);

      final String bookKey = await seedReaderBook(tester);
      expect(findBookEntries(), findsWidgets,
          reason: 'seeded book card must appear on the books shelf');

      const Key webViewKey = ValueKey<String>('fushi_webview');
      // 书卡的 Enter→activate 未挂在 FushiFocusRoot 下（TODO-783），且已入库
      // fixture 可能被书架排序排到视口外——走生产同一调用 openMedia 打开
      // （openBookViaProductionPath，同 abe553a5c 的解耦理由）。
      await openBookViaProductionPath(tester, bookKey);
      await _waitFor(tester, find.byKey(webViewKey), 'Hoshi WebView');
      await _waitFor(
        tester,
        find.byKey(const ValueKey<String>('fushi_content_ready')),
        'Hoshi content ready',
      );

      final eval = ReaderHibikiPage.debugEvaluateJavascript;
      expect(eval, isNotNull);
      await eval!(paginationHarnessJs);
      final PaginationState before = PaginationState.fromJson(
        jsonDecode(await eval(
          'window.fushiTestHarness.getPaginationState();',
        ) as String) as Map<String, dynamic>,
      );
      await eval('window.fushiReader.paginate("forward");');
      await tester.pump(const Duration(seconds: 1));
      final PaginationState after = PaginationState.fromJson(
        jsonDecode(await eval(
          'window.fushiTestHarness.getPaginationState();',
        ) as String) as Map<String, dynamic>,
      );
      expect(after.scroll, greaterThanOrEqualTo(before.scroll));

      final NavigatorState nav = Navigator.of(
        tester.element(find.byType(Scaffold).first),
      );
      nav.pop();
      await tester.pump(const Duration(seconds: 2));

      final lookup = await (await readyAppModel(tester)).searchDictionary(
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
