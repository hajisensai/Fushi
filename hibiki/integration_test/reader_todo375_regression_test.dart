import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';
import 'package:hibiki/src/media/media_item.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'helpers/focus_driver.dart';
import 'helpers/pagination_test_harness.dart';
import 'test_helpers.dart';

/// TODO-375 reader regression verification (real Windows desktop app).
///
/// Drives the REAL reader (InAppWebView Windows fork, EPUB rendered) and
/// asserts the reported symptoms behave correctly after the fix
/// (commit 72e5e5cfc, BUG-285):
///   sym2 in-chapter page turn must NOT jump chapter (sectionIndex stays 0).
///   sym1 same-section save must keep a precise charOffset (>=0), not the
///        clobbered -1 that degrades per-cue audio follow to chapter-start
///        granularity (this is _persistPosition's TODO-375 null guard).
///   sym3 best-effort: paginate("forward") stays functional (returns scrolled).
///
/// Uses the proven pagination harness (builds metrics before reading) and only
/// small-return calls (paginate -> 'scrolled'/'limit', getPaginationState ->
/// 7-field object). The big-JSON fullChapterScan does not marshal through the
/// Windows WebView2 fork, so it is avoided. WebView console errors are tolerated;
/// reader behavior is asserted via DB.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'TODO-375: in-chapter page turn keeps section + precise charOffset',
      timeout: const Timeout(Duration(minutes: 6)),
      (WidgetTester tester) async {
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      debugPrint(
          '[t375] FlutterError (non-fatal): ${details.exceptionAsString()}');
    };
    try {
      app.main();

      final bool homeReady = await waitForHome(tester);
      expect(homeReady, isTrue, reason: 'Home must render');
      await tester.pump(const Duration(seconds: 2));
      final FocusDriver driver = FocusDriver(tester);

      await _openBooksTab(tester, driver);
      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      for (int i = 0; i < 120 && !appModel.isInitialised; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(appModel.isInitialised, isTrue);

      final String bookKey = await EpubImporter.import(
        db: appModel.database,
        bytes: EpubGenerator().generate(),
        fileName: 'todo375_regression.epub',
      );
      debugPrint('[t375] imported bookKey=$bookKey');
      container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
      await tester.pumpAndSettle();

      // Start from a clean baseline so charOffset assertions are unambiguous.
      final ReaderPositionRepository posRepo =
          ReaderPositionRepository(appModel.database);
      await posRepo.delete(bookKey);

      // Open the reader via the SOURCE's real launch page (the exact widget the
      // shelf pushes). Avoids relying on focus traversal through a crowded
      // shelf, which is what failed when prior runs accumulated duplicate books.
      final ReaderHibikiSource source = ReaderHibikiSource.instance;
      final MediaItem item = MediaItem(
        mediaIdentifier: ReaderHibikiSource.mediaIdentifierFor(bookKey),
        title: bookKey,
        mediaTypeIdentifier: source.mediaType.uniqueKey,
        mediaSourceIdentifier: source.uniqueKey,
        position: 0,
        duration: 0,
        canDelete: false,
        canEdit: true,
      );
      final NavigatorState navOpen =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navOpen.push<void>(MaterialPageRoute<void>(
        builder: (_) => source.buildLaunchPage(item: item),
      )));
      await tester.pump(const Duration(seconds: 3));

      const Key webViewKey = ValueKey<String>('hoshi_webview');
      for (int i = 0;
          i < 60 && find.byKey(webViewKey).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.byKey(webViewKey), findsOneWidget);
      const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
      bool contentReady = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          contentReady = true;
          break;
        }
      }
      expect(contentReady, isTrue, reason: 'Reader content must become ready');
      await tester.pump(const Duration(seconds: 4));

      final runJs = ReaderHibikiPage.debugEvaluateJavascript;
      expect(runJs, isNotNull, reason: 'Reader JS hook must be set');

      // Inject the harness (builds metrics safely before reading state).
      final dynamic injected = await runJs!(paginationHarnessJs);
      debugPrint('[t375] harness inject -> $injected');

      Future<Map<String, dynamic>?> readState() async {
        final dynamic raw =
            await runJs('window.hoshiTestHarness.getPaginationState();');
        final String? s = raw as String?;
        if (s == null || s == 'null') return null;
        return jsonDecode(s) as Map<String, dynamic>;
      }

      final Map<String, dynamic>? s0 = await readState();
      debugPrint('[t375] baseline state=$s0');

      // === sym2 + sym1: page forward inside chapter 0 ===
      int scrolledCount = 0;
      for (int i = 0; i < 6; i++) {
        final dynamic r =
            await runJs('window.hoshiReader.paginate("forward");');
        final String result = (r as String?) ?? 'null';
        debugPrint('[t375] paginate forward #$i -> $result');
        if (result == 'scrolled') scrolledCount++;
        await tester.pump(const Duration(milliseconds: 400));
        if (result == 'limit') break;
      }
      // sym3: the page-turn path is alive (paginate moved the page).
      expect(scrolledCount, greaterThan(0),
          reason: 'sym3/page-turn path: paginate("forward") must scroll at '
              'least once inside the chapter.');

      final Map<String, dynamic>? sAfter = await readState();
      debugPrint('[t375] state after page turns=$sAfter');

      // Let the debounced persist flush.
      await tester.pump(const Duration(seconds: 2));

      final ReaderPosition? saved = await posRepo.findByBookKey(bookKey);
      debugPrint('[t375] saved DB: section=${saved?.sectionIndex} '
          'normOffset=${saved?.normCharOffset} charOffset=${saved?.charOffset}');
      expect(saved, isNotNull, reason: 'Reader must persist a position');

      // sym2: still in chapter 0 after in-chapter page turns.
      expect(saved!.sectionIndex, 0,
          reason: 'sym2: in-chapter page turns must NOT jump chapter '
              '(sectionIndex stayed 0).');

      // sym1 root cause: precise char anchor survives (DB -1 -> model null).
      expect(saved.charOffset, isNotNull,
          reason: 'sym1: same-section save must preserve a precise charOffset '
              '(>=0); a clobbered -1 (-> null) degrades audio follow to '
              'chapter-start granularity.');
      expect(saved.charOffset, greaterThanOrEqualTo(0));

      // === restore round-trip: close + confirm anchor not clobbered ===
      final NavigatorState nav =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      nav.pop();
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpAndSettle();

      final ReaderPosition? afterClose = await posRepo.findByBookKey(bookKey);
      debugPrint('[t375] after-close DB: section=${afterClose?.sectionIndex} '
          'charOffset=${afterClose?.charOffset}');
      expect(afterClose?.sectionIndex, 0);
      expect(afterClose?.charOffset, isNotNull,
          reason: 'Closing the reader must not clobber the precise anchor.');

      // === sym3 (continuous/scroll mode): page turn must still work ===
      // Switch the reader into continuous mode via its real pref, refresh the
      // live settings snapshot, reopen the same book, and confirm paginate
      // still scrolls (BUG-239/TODO-345 re-added scrollBy for this mode).
      await appModel.database
          .setPref('src:reader_ttu:ttu_view_mode', 'continuous');
      await ReaderHibikiSource.readerSettings?.refreshFromDb();
      expect(ReaderHibikiSource.readerSettings?.isContinuousMode, isTrue,
          reason: 'continuous mode must be active after pref + refresh');

      final NavigatorState navOpen2 =
          tester.state<NavigatorState>(find.byType(Navigator).first);
      unawaited(navOpen2.push<void>(MaterialPageRoute<void>(
        builder: (_) => source.buildLaunchPage(item: item),
      )));
      await tester.pump(const Duration(seconds: 3));
      for (int i = 0;
          i < 60 && find.byKey(webViewKey).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.byKey(webViewKey), findsOneWidget,
          reason: 'continuous-mode reader WebView must mount');
      // The reopened continuous reader installs a fresh JS hook. content_ready
      // may already have fired during the first poll window, so instead of
      // gating on the key we wait until the reopened reader's hook is usable
      // AND hoshiReader is present, then drive paginate. Generous fixed settle
      // covers the headless reopen + WebView2 init latency.
      await tester.pump(const Duration(seconds: 8));
      final runJs2 = ReaderHibikiPage.debugEvaluateJavascript;
      expect(runJs2, isNotNull,
          reason: 'reopened reader must reinstall the JS hook');

      // Wait until hoshiReader is live in the reopened WebView (small string
      // return marshals fine through the Windows fork).
      bool readerLive = false;
      for (int i = 0; i < 40; i++) {
        final dynamic probe = await runJs2!(
            'typeof window.hoshiReader !== "undefined" ? "yes" : "no"');
        if ((probe as String?) == 'yes') {
          readerLive = true;
          break;
        }
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(readerLive, isTrue,
          reason: 'continuous-mode hoshiReader must come alive');
      await tester.pump(const Duration(seconds: 2));

      int contScrolled = 0;
      for (int i = 0; i < 6; i++) {
        final dynamic r =
            await runJs2!('window.hoshiReader.paginate("forward");');
        final String result = (r as String?) ?? 'null';
        debugPrint('[t375][continuous] paginate forward #$i -> $result');
        if (result == 'scrolled') contScrolled++;
        await tester.pump(const Duration(milliseconds: 400));
        if (result == 'limit') break;
      }
      expect(contScrolled, greaterThan(0),
          reason: 'sym3: continuous/scroll mode paginate("forward") must '
              'still turn pages (was reported broken).');
      debugPrint('[t375][continuous] === PASSED: scroll-mode page turn alive '
          '(scrolled=$contScrolled) ===');

      // Restore the user's default mode (do not leave continuous behind).
      await appModel.database
          .setPref('src:reader_ttu:ttu_view_mode', 'paginated');
      await ReaderHibikiSource.readerSettings?.refreshFromDb();

      debugPrint('[t375] === PASSED: section kept + precise charOffset '
          'preserved; page-turn alive (scrolled=$scrolledCount) ===');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<void> _openBooksTab(WidgetTester tester, FocusDriver driver) async {
  final List<Finder> navTargets = findPrimaryNavigationTargets();
  if (navTargets.isEmpty) return;
  await driver.focusWidget(navTargets.first);
  await driver.activate();
  await tester.pump(const Duration(milliseconds: 500));
}
