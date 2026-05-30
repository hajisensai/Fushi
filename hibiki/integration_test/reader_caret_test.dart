import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

/// Char-level reading cursor — real-DOM verification.
///
/// Opens a book and drives [ReaderCaretScripts] (`window.hoshiCaret`) through the
/// reader's debug JS hook on a real WebView, asserting the parts that the Dart
/// unit tests cannot reach: enter lands on a visible character, forward/backward
/// round-trip, the writing-mode physical→logical mapping is live, look-up reuses
/// the selection pipeline, the focus ring shows/hides, and the Flutter Enter key
/// actually drives the cursor through `_handleKeyEvent` end-to-end.
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/reader_caret_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Reader char caret: enter / move / writing-mode / lookup / ring',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[CARET] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: 'Home within 90s');
      await tester.pump(const Duration(seconds: 2));

      final navTargets = findPrimaryNavigationTargets();
      if (navTargets.isNotEmpty) {
        await tester.tap(navTargets.first);
        await tester.pumpAndSettle();
      }

      var bookEntries = findBookEntries();
      for (int i = 0; i < 20 && bookEntries.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        bookEntries = findBookEntries();
      }
      if (bookEntries.evaluate().isEmpty) {
        await _seedTestBook(tester);
        if (navTargets.isNotEmpty) {
          await tester.tap(navTargets.first);
          await tester.pumpAndSettle();
        }
        bookEntries = findBookEntries();
        for (int i = 0; i < 20 && bookEntries.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          bookEntries = findBookEntries();
        }
      }
      if (bookEntries.evaluate().isEmpty) {
        fail('CARET blocked: failed to seed a test EPUB onto the shelf.');
      }

      await tester.tap(bookEntries.first);
      await tester.pump(const Duration(seconds: 3));

      const Key webViewKey = ValueKey<String>('hoshi_webview');
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(webViewKey).evaluate().isNotEmpty) break;
      }
      expect(find.byKey(webViewKey), findsOneWidget, reason: 'WebView present');

      const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
      bool contentReady = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          contentReady = true;
          break;
        }
      }
      expect(contentReady, isTrue, reason: 'Reader content ready within 60s');
      await tester.pump(const Duration(seconds: 3));

      final eval = ReaderHibikiPage.debugEvaluateJavascript;
      expect(eval, isNotNull,
          reason: 'Reader debug JS hook must be set (debug/profile build).');

      // The caret module is injected by the reader setup script.
      final caretType = (await eval!('typeof window.hoshiCaret')).toString();
      expect(caretType, 'object', reason: 'window.hoshiCaret must be injected');

      Future<Map<String, dynamic>> sig() async {
        final raw = await eval(
          'JSON.stringify({active:window.hoshiCaret.isActive(),'
          'off:window.hoshiCaret.offset,'
          'len:(window.hoshiCaret.node?window.hoshiCaret.node.textContent.length:0),'
          'ch:(window.hoshiCaret.node?'
          'window.hoshiCaret.node.textContent.substr(window.hoshiCaret.offset,1):null)})',
        );
        return jsonDecode(raw as String) as Map<String, dynamic>;
      }

      Future<String> ringDisplay() async => (await eval(
            "(function(){var r=document.getElementById('hoshi-caret-ring');"
            "return r?(r.style.display||'block'):'none';})()",
          ))
          .toString();

      // ── enter() lands on a visible character ──────────────────────────
      final enterRaw = await eval(ReaderCaretScripts.enterInvocation());
      expect(ReaderCaretScripts.moveStatus(enterRaw), 'moved',
          reason: 'enter() must land on a visible character');
      final start = await sig();
      debugPrint('[CARET] enter sig=$start ring=${await ringDisplay()}');
      expect(start['active'], isTrue);
      expect(start['ch'], isNotNull);
      expect(await ringDisplay(), 'block', reason: 'ring visible after enter');

      // ── forward / backward round-trip ─────────────────────────────────
      final fwd = ReaderCaretScripts.moveStatus(
          await eval(ReaderCaretScripts.moveInvocation('forward')));
      expect(fwd == 'moved' || fwd == 'pageForward', isTrue,
          reason: 'forward must advance or turn the page (got $fwd)');
      final afterFwd = await sig();
      expect(afterFwd['off'] != start['off'] || afterFwd['len'] != start['len'],
          isTrue,
          reason: 'forward must change the caret position');

      // Only assert a clean round-trip when forward stayed on the same page
      // (a page turn re-anchors to the page edge, which is not reversible 1:1).
      if (fwd == 'moved') {
        final back = ReaderCaretScripts.moveStatus(
            await eval(ReaderCaretScripts.moveInvocation('backward')));
        expect(back == 'moved' || back == 'pageBackward', isTrue);
        if (back == 'moved') {
          final afterBack = await sig();
          expect(afterBack['off'], start['off'],
              reason: 'forward then backward returns to the same character');
          expect(afterBack['ch'], start['ch']);
        }
      }

      // ── writing-mode physical→logical mapping on real geometry ────────
      final bool vertical =
          (await eval('window.hoshiCaret._vertical()')) == true;
      debugPrint('[CARET] writing-mode vertical-rl=$vertical');
      // Reading-axis keys: vertical-rl DOWN advances / UP retreats; horizontal
      // RIGHT advances / LEFT retreats. Advance one char then retreat — must land
      // back on the same character. This drives the ACTUAL writing-mode geometry
      // (the part most prone to vertical/horizontal axis bugs), not just the
      // mapping string. Default reader layout is vertical-rl, so this exercises
      // the vertical path on a real DOM.
      await eval(ReaderCaretScripts.exitInvocation());
      await eval(ReaderCaretScripts.enterInvocation());
      final String advanceKey = vertical ? 'down' : 'right';
      final String retreatKey = vertical ? 'up' : 'left';
      final axisStart = await sig();
      final adv = ReaderCaretScripts.moveStatus(
          await eval(ReaderCaretScripts.moveInvocation(advanceKey)));
      expect(adv == 'moved' || adv == 'pageForward', isTrue,
          reason: '$advanceKey must advance the caret in '
              '${vertical ? "vertical-rl" : "horizontal"} mode (got $adv)');
      if (adv == 'moved') {
        final afterAdv = await sig();
        expect(
            afterAdv['off'] != axisStart['off'] ||
                afterAdv['len'] != axisStart['len'],
            isTrue,
            reason: 'advance key must change the caret position');
        final ret = ReaderCaretScripts.moveStatus(
            await eval(ReaderCaretScripts.moveInvocation(retreatKey)));
        if (ret == 'moved') {
          final afterRet = await sig();
          expect(afterRet['off'], axisStart['off'],
              reason: '$retreatKey must reverse $advanceKey '
                  '(writing-mode reading axis)');
          expect(afterRet['ch'], axisStart['ch']);
        }
      }
      // Cross-axis (line) key must be recognised: from a mid position it either
      // moves to an adjacent line, turns the page, or is blocked at an edge — all
      // valid statuses, none throws.
      final String lineKey = vertical ? 'left' : 'down';
      final lineStatus = ReaderCaretScripts.moveStatus(
          await eval(ReaderCaretScripts.moveInvocation(lineKey)));
      debugPrint('[CARET] line-move ($lineKey) status=$lineStatus');
      expect(
        const <String>['moved', 'pageForward', 'pageBackward', 'blocked']
            .contains(lineStatus),
        isTrue,
        reason: 'line-move must return a known status',
      );

      // ── lookup() reuses the selection pipeline ────────────────────────
      await eval(ReaderCaretScripts.enterInvocation()); // re-seed if needed
      final lookupOk = await eval(ReaderCaretScripts.lookupInvocation());
      expect(lookupOk == true, isTrue,
          reason: 'lookup() must select the word at the caret');
      final selText = await eval(
        'JSON.stringify(window.hoshiSelection && window.hoshiSelection.selection'
        ' ? window.hoshiSelection.selection.text : null)',
      );
      final decodedSel = jsonDecode(selText as String);
      debugPrint('[CARET] lookup selection=$decodedSel');
      expect(decodedSel, isNotNull,
          reason: 'caret lookup must populate hoshiSelection (tap pipeline)');

      // ── exit() hides the ring ─────────────────────────────────────────
      await eval(ReaderCaretScripts.exitInvocation());
      expect((await sig())['active'], isFalse);
      expect(await ringDisplay(), 'none', reason: 'ring hidden after exit');

      await takeScreenshot(binding, 'caret_js_verified');

      // ── Flutter Enter key drives the cursor end-to-end ────────────────
      // Sends a real key event through _handleKeyEvent → _enterCaret → JS.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 400));
      final bool activeAfterEnter =
          (await eval('window.hoshiCaret.isActive()')) == true;
      debugPrint('[CARET] active after Flutter Enter=$activeAfterEnter');
      expect(activeAfterEnter, isTrue,
          reason: 'Flutter Enter must enter the cursor via _handleKeyEvent');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      expect((await eval('window.hoshiCaret.isActive()')) == true, isFalse,
          reason: 'Escape must leave the cursor');

      await takeScreenshot(binding, 'caret_keypath_verified');

      final NavigatorState nav =
          Navigator.of(tester.element(find.byType(Scaffold).first));
      nav.pop();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      assertStrictErrors(errors);
      debugPrint('[CARET] === CARET TESTS PASSED ===');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<void> _seedTestBook(WidgetTester tester) async {
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  final AppModel appModel = container.read(appProvider);
  for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
  expect(appModel.isInitialised, isTrue,
      reason: 'AppModel must be initialised before importing a book');

  final Uint8List bytes = EpubGenerator().generate();
  final int bookId = await EpubImporter.import(
    db: appModel.database,
    bytes: bytes,
    fileName: 'test_caret.epub',
  );
  debugPrint('[CARET] Imported test EPUB as book id=$bookId');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  await tester.pumpAndSettle();
}
