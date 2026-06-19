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
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';

import 'helpers/focus_driver.dart';
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

      final FocusDriver driver = FocusDriver(tester);

      // Always import a FRESH EPUB (no audiobook) and open that exact book, so
      // we deterministically exercise the paginated chapter reader. Tapping a
      // pre-existing shelf book is unsafe: a book with a saved audiobook reopens
      // in lyrics mode (_lyricsMode restored from its saved state), which loads
      // the lyrics page instead of a chapter and never injects window.hoshiCaret
      // — a stale shelf book is exactly what made this test spuriously fail.
      final String bookKey = await _seedTestBook(tester);
      final navTargets = findPrimaryNavigationTargets();
      if (navTargets.isNotEmpty) {
        final bool focusedTab = await driver.focusWidget(navTargets.first);
        expect(focusedTab, isTrue,
            reason: 'Books tab must be reachable by focus');
        await driver.activate();
        await tester.pumpAndSettle();
      }

      // Shelf entries key off the media identifier (hoshi://book/<id>), not the
      // raw row id — see reader_hibiki_history_page.dart `book_entry_<mediaId>`.
      final String seededKey =
          'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
      final Finder seededEntry = find.byKey(ValueKey<String>(seededKey));
      for (int i = 0; i < 40 && seededEntry.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(seededEntry, findsOneWidget,
          reason: 'freshly seeded paginated book must appear on the shelf');

      final bool focusedBook = await driver.focusWidget(seededEntry);
      expect(focusedBook, isTrue,
          reason: 'Book card must be reachable by focus');
      await driver.activate();
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
      // Re-anchor to the first visible character first: the moves above may have
      // parked the caret on a punctuation/boundary glyph, where look-up correctly
      // returns nothing (same as tapping punctuation). The page's first visible
      // char is a content glyph (logged as a kanji on entry), so look-up there is
      // a real word.
      await eval(ReaderCaretScripts.reanchorInvocation('forward'));
      final caretChar = await eval(
        '(window.hoshiCaret.node?window.hoshiCaret.node.textContent'
        '.substr(window.hoshiCaret.offset,1):null)',
      );
      debugPrint('[CARET] lookup at char=$caretChar');
      final lookupOk = await eval(ReaderCaretScripts.lookupInvocation());
      expect(lookupOk == true, isTrue,
          reason: 'lookup() must select the word at the caret '
              '(char=$caretChar)');
      final selText = await eval(
        'JSON.stringify(window.hoshiSelection && window.hoshiSelection.selection'
        ' ? window.hoshiSelection.selection.text : null)',
      );
      final decodedSel = jsonDecode(selText as String);
      debugPrint('[CARET] lookup selection=$decodedSel');
      expect(decodedSel, isNotNull,
          reason: 'caret lookup must populate hoshiSelection (tap pipeline)');

      // ── activate() — the A/Enter "context click" — routes plain text to the
      // same lookup on the real WebView (a hyperlink would instead navigate, a
      // control would be clicked). The caret is on a content kanji here.
      await eval(ReaderCaretScripts.reanchorInvocation('forward'));
      final activateResult =
          (await eval(ReaderCaretScripts.activateInvocation())).toString();
      debugPrint('[CARET] activate result=$activateResult');
      expect(activateResult, 'lookup',
          reason:
              'A/Enter on plain text must context-click into a word lookup');

      // ── exit() hides the ring ─────────────────────────────────────────
      await eval(ReaderCaretScripts.exitInvocation());
      expect((await sig())['active'], isFalse);
      expect(await ringDisplay(), 'none', reason: 'ring hidden after exit');

      // The eval-direct lookup() above opened a real dictionary popup (lookup
      // fires the same onTextSelected pipeline). Dismiss it via Escape so the key
      // path starts clean. Focus right after a popup mount is not deterministic —
      // an Escape can land inside the popup's own WebView instead of the Flutter
      // dismiss handler — so retry Escape until the popup is actually gone rather
      // than assuming one press lands. Each Escape is given time to take effect,
      // and we re-check before sending another so a closed popup never leaks an
      // extra Escape into the reader. (If the popup never dismisses, the Enter
      // below would dismiss it instead of entering the cursor, so this guards the
      // following assertion against a misattributed failure.)
      bool popupDismissed =
          find.byType(DictionaryPopupWebView).evaluate().isEmpty;
      for (int attempt = 0; attempt < 6 && !popupDismissed; attempt++) {
        if (find.byType(DictionaryPopupWebView).evaluate().isEmpty) {
          popupDismissed = true;
          break;
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        // Generous per-Escape wait: a single press should fully dismiss the
        // popup before the outer loop considers another, so a stray Escape never
        // leaks to the reader (where Escape toggles the chrome) and steals focus.
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 150));
          if (find.byType(DictionaryPopupWebView).evaluate().isEmpty) {
            popupDismissed = true;
            break;
          }
        }
      }
      expect(popupDismissed, isTrue,
          reason: 'the eval-lookup popup must dismiss before the key path');
      // Let onAllPopupsDismissed return Flutter focus to the reading content
      // before the key path, so Enter enters the cursor (not a chrome button).
      await tester.pump(const Duration(milliseconds: 500));

      await takeScreenshot(binding, 'caret_js_verified');

      // ── Flutter Enter key drives the cursor end-to-end ────────────────
      // Sends a real key event through _handleKeyEvent → _enterCaret → JS.
      // The earlier eval-lookup + Escape dismissal can transiently leave focus on
      // the bottom bar (where Enter would activate a chrome button, not the
      // cursor). Up deterministically returns focus to the reading content (from
      // the bar; on the content it just pages back, which is harmless), so press
      // Up then Enter, and retry — _enterCaret is an async round-trip, so poll.
      bool activeAfterEnter = false;
      for (int attempt = 0; attempt < 4 && !activeAfterEnter; attempt++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 150));
          if ((await eval('window.hoshiCaret.isActive()')) == true) {
            activeAfterEnter = true;
            break;
          }
        }
      }
      debugPrint('[CARET] active after Flutter Enter=$activeAfterEnter');
      expect(activeAfterEnter, isTrue,
          reason: 'Flutter Enter must enter the cursor via _handleKeyEvent');

      // Confirm the cursor is active right before the leaving Escape, so the
      // poll below tests a real active→inactive transition rather than passing
      // trivially on an already-inactive cursor.
      expect((await eval('window.hoshiCaret.isActive()')) == true, isTrue,
          reason: 'cursor must be active before the leaving Escape');
      // Escape leaves the cursor. The earlier eval-lookup can leave a dictionary
      // result showing; the correct B/Esc order is "Escape closes the popup
      // first, then a further Escape leaves the cursor" (see _caretDismissOrExit:
      // clears the dictionary when shown, else exits). So send Escape until the
      // cursor is actually inactive instead of assuming a single press leaves it.
      bool inactiveAfterEscape = false;
      for (int attempt = 0; attempt < 6 && !inactiveAfterEscape; attempt++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        for (int i = 0; i < 14; i++) {
          await tester.pump(const Duration(milliseconds: 150));
          if ((await eval('window.hoshiCaret.isActive()')) != true) {
            inactiveAfterEscape = true;
            break;
          }
        }
      }
      expect(inactiveAfterEscape, isTrue,
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

Future<String> _seedTestBook(WidgetTester tester) async {
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
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: bytes,
    fileName: 'test_caret.epub',
  );
  debugPrint('[CARET] Imported test EPUB as book key=$bookKey');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  await tester.pumpAndSettle();
  return bookKey;
}
