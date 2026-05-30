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

  testWidgets('popup cursor: caret + selection injected into the popup; '
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

      // ── Enter the reader cursor (the CaretSurface machine's entry) ───
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump(const Duration(milliseconds: 500));
      expect(surface(), 'reader', reason: 'Enter enters the reader cursor');

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
      expect(await typeOf('window.hoshiSelection.selectFromPosition'), 'function',
          reason: 'popup selection.js exposes selectFromPosition (caret lookup '
              'reuses it)');

      // NOTE (verification scope): the cursor-TRANSFER end-to-end leg (the popup
      // taking the cursor, in-popup navigation, B/Esc walking back) cannot be
      // exercised under `flutter drive`: the popup's own renderer (popup.js,
      // ~70KB) does not execute via its <script src> on the asset file:// URL in
      // this environment, so the popup renders no .glossary-content for the
      // cursor to land on, and writes via the popup's JS bridge are unreliable
      // here. dict-media.js + selection.js + our injected caret DO load (asserted
      // above). The transfer state machine is pure Dart (CaretSurface in
      // reader_hibiki_page.dart) and is covered by code review; the caret's own
      // DOM behaviour is proven on a real WebView by reader_caret_test.dart.

      await takeScreenshot(binding, 'popup_caret_injected');

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
