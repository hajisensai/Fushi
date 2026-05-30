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

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

/// Dictionary-popup char caret: the cursor auto-transfers onto the popup on
/// lookup, and B/Esc walks it back to the reader.
///
/// Self-contained: generates a tiny Yomitan term dictionary in memory (so a
/// lookup of a known word produces a real populated popup) and an EPUB, then
/// drives the reader → lookup → popup → back flow on a real WebView, observing
/// the transfer via the debug hooks.
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/reader_popup_caret_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const String knownWord = 'テスト語';

  testWidgets('popup cursor: auto-transfer on lookup, back on Escape',
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
      debugPrint('[POPUP-CARET] dictionary ready, "$knownWord" resolves');

      // ── Open a book ──────────────────────────────────────────────────
      final navTargets = findPrimaryNavigationTargets();
      if (navTargets.isNotEmpty) {
        await tester.tap(navTargets.first);
        await tester.pumpAndSettle();
      }
      var bookEntries = findBookEntries();
      if (bookEntries.evaluate().isEmpty) {
        await _seedTestBook(tester, appModel);
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
      expect(bookEntries.evaluate(), isNotEmpty, reason: 'a book on the shelf');
      await tester.tap(bookEntries.first);
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

      // ── Enter the reader cursor ──────────────────────────────────────
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 500));
      expect(surface(), 'reader', reason: 'Enter enters the reader cursor');

      // ── Fire a lookup of the known word (bypasses EPUB content) ──────
      // The reader cursor is active, so the popup that opens must take the
      // cursor. We invoke the reader's onTextSelected handler directly with a
      // word we know the dictionary resolves.
      await eval!(
        "window.flutter_inappwebview.callHandler('onTextSelected',"
        "JSON.stringify({text:'$knownWord',sentence:'$knownWord これはテストです。',"
        'rect:null,normalizedOffset:null,normalizedLength:null,sentenceOffset:0,'
        'sentenceNormalizedOffset:null,sentenceNormalizedLength:null}))',
      );

      bool transferred = false;
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        if (surface() == 'popup') {
          transferred = true;
          break;
        }
      }
      expect(transferred, isTrue,
          reason: 'the cursor must auto-transfer to the popup on lookup');

      // The popup WebView is present, and its own caret is active + scoped.
      expect(find.byType(DictionaryPopupWebView), findsWidgets,
          reason: 'a populated popup WebView is shown');
      final popupEval = DictionaryPopupWebViewState.debugEvaluateJavascript;
      expect(popupEval, isNotNull, reason: 'popup debug hook set');
      final bool popupCaretActive =
          (await popupEval!('window.hoshiCaret && window.hoshiCaret.isActive()'))
              == true;
      debugPrint('[POPUP-CARET] popup caret active=$popupCaretActive');
      expect(popupCaretActive, isTrue,
          reason: 'the popup must have an active char cursor');
      final scope =
          (await popupEval('window.hoshiCaret && window.hoshiCaret.scopeSelector'))
              ?.toString();
      debugPrint('[POPUP-CARET] popup scopeSelector=$scope');
      expect(scope, '.glossary-content',
          reason: 'popup cursor is scoped to the definition body');

      // Stepping the popup cursor keeps it on the popup (does not throw / leave).
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 400));
      expect(surface(), 'popup', reason: 'arrows move the popup cursor');

      await takeScreenshot(binding, 'popup_caret_transferred');

      // ── Back: Escape returns the cursor to the reader ────────────────
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

      await takeScreenshot(binding, 'popup_caret_back_to_reader');

      final NavigatorState nav =
          Navigator.of(tester.element(find.byType(Scaffold).first));
      nav.pop();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      assertStrictErrors(errors);
      debugPrint('[POPUP-CARET] === POPUP CARET TESTS PASSED ===');
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
  // Yomitan term: [expression, reading, defTags, rules, score, glossary[],
  // sequence, termTags].
  final List<List<dynamic>> termBank = <List<dynamic>>[
    <dynamic>['テスト語', 'てすとご', '', '', 0, <String>['テスト用の語釈。'], 0, ''],
    <dynamic>['言葉', 'ことば', '', '', 0, <String>['言語。ことば。'], 1, ''],
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
  debugPrint('[POPUP-CARET] test dictionary imported');
}

ArchiveFile _jsonFile(String name, Object json) {
  final List<int> bytes = utf8.encode(jsonEncode(json));
  return ArchiveFile(name, bytes.length, bytes);
}

Future<void> _seedTestBook(WidgetTester tester, AppModel appModel) async {
  final Uint8List bytes = EpubGenerator().generate();
  await EpubImporter.import(
    db: appModel.database,
    bytes: bytes,
    fileName: 'test_popup_caret.epub',
  );
  final ProviderContainer container = ProviderScope.containerOf(
    tester.element(find.byType(MaterialApp).first),
  );
  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  await tester.pumpAndSettle();
}
