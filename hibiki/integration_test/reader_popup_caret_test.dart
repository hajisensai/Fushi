import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import 'helpers/focus_driver.dart';
import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

/// Dictionary-popup char caret — real-WebView verification of the integration
/// that the Dart unit tests cannot reach: that the SAME char caret
/// ([ReaderCaretScripts]) and the refactored selection pipeline are actually
/// injected into the dictionary popup's WebView, and that a lookup made while
/// the reader cursor is active opens that popup. The cursor-transfer STATE
/// MACHINE itself (reader↔popup↔back) is pure Dart and is covered by review +
/// unit tests; see the note at the lookup step for why its end-to-end leg cannot
/// run under `flutter drive`.
///
/// Self-contained: generates a tiny Yomitan term dictionary in memory so a
/// lookup resolves a known word.
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/reader_popup_caret_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String knownWord = 'テスト語';

  testWidgets(
      'popup cursor: caret + selection injected into the popup; '
      'lookup opens it while the reader cursor is active',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[POPUP-CARET] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();
      expect(await waitForHome(tester), isTrue, reason: 'Home within 90s');
      await tester.pump(const Duration(seconds: 2));

      final FocusDriver driver = FocusDriver(tester);

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(appModel.isInitialised, isTrue);

      // ── Ensure a term dictionary with our known word exists ──────────
      var probe = await appModel.searchDictionary(
          searchTerm: knownWord, searchWithWildcards: false);
      if (probe.entries.isEmpty) {
        await _importTestDictionary(tester, appModel);
        probe = await appModel.searchDictionary(
            searchTerm: knownWord, searchWithWildcards: false);
      }
      expect(probe.entries, isNotEmpty,
          reason: 'the generated dictionary must resolve "$knownWord"');

      // ── Open a book ──────────────────────────────────────────────────
      // Always import a FRESH EPUB (no audiobook) and open that exact book, so
      // the reader is the paginated chapter view. Tapping a pre-existing shelf
      // book is unsafe: one with a saved audiobook reopens in lyrics mode, which
      // loads the lyrics page (not a chapter) and never injects window.hoshiCaret.
      final String bookKey = await _seedTestBook(tester, appModel);
      final navTargets = findPrimaryNavigationTargets();
      if (navTargets.isNotEmpty) {
        final bool focusedTab = await driver.focusWidget(navTargets.first);
        expect(focusedTab, isTrue,
            reason: 'Books tab must be reachable by focus');
        await driver.activate();
        await tester.pumpAndSettle();
      }
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

      const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
      bool contentReady = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          contentReady = true;
          break;
        }
      }
      expect(contentReady, isTrue, reason: 'reader content ready');
      await tester.pump(const Duration(seconds: 3));

      final eval = ReaderHibikiPage.debugEvaluateJavascript;
      expect(eval, isNotNull);
      String? surface() => ReaderHibikiPage.debugCaretSurface?.call();

      // ── Enter the reader cursor (the CaretSurface machine's entry) ───
      // Verified on both Android and Windows (WebView2): the reader setup script
      // runs and window.hoshiCaret is defined for a paginated book. Entry is an
      // async evaluateJavascript round-trip, so poll the surface state.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      bool enteredReader = false;
      // First caret entry on a cold reader (a full setup-script round-trip), so
      // allow a generous budget before failing.
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 150));
        if (surface() == 'reader') {
          enteredReader = true;
          break;
        }
      }
      expect(enteredReader, isTrue, reason: 'Enter enters the reader cursor');

      // ── A lookup made while the cursor is active opens a popup ───────
      // Invoke the reader's onTextSelected handler directly with a word the
      // dictionary resolves (bypasses EPUB glyph hit-testing).
      await eval!(
        "window.flutter_inappwebview.callHandler('onTextSelected',"
        "JSON.stringify({text:'$knownWord',sentence:'$knownWord これはテストです。',"
        'rect:null,normalizedOffset:null,normalizedLength:null,sentenceOffset:0,'
        'sentenceNormalizedOffset:null,sentenceNormalizedLength:null}))',
      );

      // Wait for the popup WebView to mount, load (onLoadStop injects the caret)
      // and become reachable via the reader's topPopupState. Poll on the actual
      // injected marker (window.hoshiCaret) so we don't race the load.
      bool popupShown = false;
      String caretType = 'no-popup';
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (find.byType(DictionaryPopupWebView).evaluate().isEmpty) continue;
        final eval2 = ReaderHibikiPage.debugEvaluateTopPopup;
        if (eval2 == null) continue;
        popupShown = true;
        caretType = (await eval2('typeof window.hoshiCaret')).toString();
        if (caretType == 'object') break;
      }
      expect(popupShown, isTrue,
          reason: 'a popup WebView opens for the lookup');
      final popupEval = ReaderHibikiPage.debugEvaluateTopPopup!;

      // ── The SAME caret + selection are injected into the popup ───────
      // These read-only checks verify the new integration points: the reader
      // injects window.hoshiCaret on the popup's load, and selection.js exposes
      // the refactored selectFromPosition the caret lookup reuses.
      expect(caretType, 'object',
          reason: 'the char caret module is injected into the popup WebView');

      Future<String> typeOf(String expr) async =>
          (await popupEval('typeof ($expr)')).toString();
      expect(await typeOf('window.hoshiCaret.init'), 'function');
      expect(await typeOf('window.hoshiCaret.enter'), 'function');
      expect(await typeOf('window.hoshiCaret.move'), 'function');
      expect(await typeOf('window.hoshiCaret.lookup'), 'function');
      expect(
          await typeOf('window.hoshiSelection.selectFromPosition'), 'function',
          reason: 'popup selection.js exposes selectFromPosition (caret lookup '
              'reuses it)');

      await takeScreenshot(binding, 'popup_caret_injected');

      // ── Full transfer — only where the popup's own renderer runs ─────
      // On Windows desktop the popup inlines its scripts (popup.js executes), so
      // it renders .glossary-content and the cursor auto-transfers onto it; we
      // then verify in-popup navigation and B/Esc walking back to the reader.
      // Under `flutter drive` on Android that renderer (popup.js, ~70KB) does NOT
      // execute via its <script src> on the asset file:// URL — dict-media.js +
      // selection.js + our injected caret DO load (asserted above) but
      // window.renderPopup is undefined, so the popup renders nothing for the
      // cursor to land on and this leg is skipped there. The transfer state
      // machine (CaretSurface) is pure Dart and is also covered by code review;
      // the caret's DOM behaviour is proven on a real WebView by
      // reader_caret_test.dart.
      final String renderType =
          (await popupEval('typeof window.renderPopup')).toString();
      if (renderType == 'function') {
        bool transferred = false;
        for (int i = 0; i < 60; i++) {
          await tester.pump(const Duration(milliseconds: 300));
          if (surface() == 'popup') {
            transferred = true;
            break;
          }
        }
        final String d = 'surface=${surface()} '
            "gc=${await popupEval("document.querySelectorAll('.glossary-content').length")} "
            'active=${await popupEval('!!(window.hoshiCaret&&window.hoshiCaret.isActive())')}';
        expect(transferred, isTrue,
            reason: 'cursor must auto-transfer onto the rendered popup [$d]');
        expect(
            (await popupEval(
                    '!!(window.hoshiCaret&&window.hoshiCaret.isActive())')) ==
                true,
            isTrue,
            reason: 'popup cursor active after transfer [$d]');
        // The popup cursor now navigates the whole popup (no scopeSelector), so
        // a gamepad can reach interactive controls and every kanji, not just the
        // definition body.
        expect(await popupEval('window.hoshiCaret.scopeSelector'), isNull);

        // Arrow keys move the popup cursor; it stays on the popup.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump(const Duration(milliseconds: 400));
        expect(surface(), 'popup', reason: 'arrows move the popup cursor');

        // Escape walks the cursor back to the reader.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        bool back = false;
        for (int i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 300));
          if (surface() == 'reader') {
            back = true;
            break;
          }
        }
        expect(back, isTrue, reason: 'Escape returns the cursor to the reader');
        await takeScreenshot(binding, 'popup_caret_full_transfer');
        debugPrint('[POPUP-CARET] === FULL TRANSFER VERIFIED (rendered popup)');
      }

      // Leave cursor mode cleanly.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump(const Duration(milliseconds: 400));

      final NavigatorState nav =
          Navigator.of(tester.element(find.byType(Scaffold).first));
      nav.pop();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      assertStrictErrors(errors);
      debugPrint('[POPUP-CARET] === POPUP CARET INJECTION VERIFIED ===');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

/// Builds a minimal Yomitan term dictionary (one known word) in memory, writes
/// it to the app cache dir, and imports it — no host files or adb push needed.
Future<void> _importTestDictionary(
    WidgetTester tester, AppModel appModel) async {
  final Map<String, dynamic> index = <String, dynamic>{
    'title': 'HibikiCaretTestDict',
    'format': 3,
    'revision': 'caret-test-1',
    'sequenced': false,
  };
  final List<List<dynamic>> termBank = <List<dynamic>>[
    <dynamic>[
      'テスト語',
      'てすとご',
      '',
      '',
      0,
      <String>['テスト用の語釈。'],
      0,
      ''
    ],
    <dynamic>[
      '言葉',
      'ことば',
      '',
      '',
      0,
      <String>['言語。ことば。'],
      1,
      ''
    ],
  ];

  final Archive archive = Archive()
    ..addFile(_jsonFile('index.json', index))
    ..addFile(_jsonFile('term_bank_1.json', termBank));
  final List<int> zipBytes = ZipEncoder().encode(archive)!;

  final Directory cache = await getTemporaryDirectory();
  final File zipFile = File('${cache.path}/hibiki_caret_test_dict.zip');
  await zipFile.writeAsBytes(zipBytes, flush: true);

  final Completer<void> done = Completer<void>();
  await appModel.importDictionary(
    file: zipFile,
    progressNotifier: ValueNotifier<String>(''),
    onImportSuccess: () {
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future.timeout(const Duration(seconds: 90));
  await tester.pump(const Duration(seconds: 1));
}

ArchiveFile _jsonFile(String name, Object json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}

Future<String> _seedTestBook(WidgetTester tester, AppModel appModel) async {
  final Uint8List bytes = EpubGenerator().generate();
  final String bookKey = await EpubImporter.import(
    db: appModel.database,
    bytes: bytes,
    fileName: 'test_popup_caret.epub',
  );
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  await tester.pumpAndSettle();
  return bookKey;
}
