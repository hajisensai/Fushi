import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/media.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'helpers/focus_driver.dart';
import 'helpers/pagination_test_harness.dart';
import 'test_helpers.dart';

/// M1: Reader Pagination tests.
///
/// Opens a book, injects the JS test harness through the reader's debug
/// evaluate hook, pages through the whole chapter, and validates pagination
/// invariants (scroll alignment, marker continuity, coverage, progress
/// monotonicity, trailing space, page-count sanity).
///
/// The scroll-alignment + drift checks (I1) are what catch the
/// "翻页越翻越偏" regression — scroll position drifting away from the
/// column pitch as pages turn. These work on ANY book. Marker continuity
/// (I2) and coverage (I3) only fire when the book embeds [id^="m"] markers
/// (the synthetic test EPUB); on real books they are skipped gracefully.
///
/// Requires:
///   - Connected device/emulator
///   - At least one book imported on the shelf
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/reader_pagination_test.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('M1: Reader pagination invariants hold across page turns',
      timeout: const Timeout(Duration(minutes: 5)),
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = [];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[M1] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      app.main();

      final bool homeReady = await waitForHome(tester);
      expect(homeReady, isTrue, reason: 'Home must render within 90s');
      await tester.pump(const Duration(seconds: 2));
      debugPrint('[M1] Home ready');
      final FocusDriver driver = FocusDriver(tester);

      // === Open first book ===
      // Ensure we're on the Books tab before looking for entries (home may
      // default to another tab; the shelf list also lazy-loads).
      await _openBooksTab(tester, driver);

      // Always import and open this run's marker EPUB. Windows off-screen tests
      // reuse the user's app data, so opening the first existing shelf book can
      // silently downgrade marker coverage to a real-book smoke test.
      debugPrint('[M1] Importing synthetic marker EPUB');
      final String bookKey = await _seedTestBook(tester);
      await _openBooksTab(tester, driver);
      final String seededEntryKey =
          'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
      final Finder seededEntry = find.byKey(ValueKey<String>(seededEntryKey));
      for (int i = 0; i < 20 && seededEntry.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      if (seededEntry.evaluate().isEmpty) {
        fail('M1 blocked: seeded test EPUB did not appear on shelf '
            '($seededEntryKey).');
      }

      await _activateBook(tester, bookKey);
      await tester.pump(const Duration(seconds: 3));

      // === Reader route ready ===
      // _activateBook opens the reader via appModel.openMedia (the deterministic
      // off-screen path). Before waiting on the WebView, assert the reader page
      // itself mounted, so a silent open failure shows up here as a missing
      // ReaderHibikiPage rather than being misread downstream as a WebView
      // mount timeout.
      for (int i = 0;
          i < 40 && find.byType(ReaderHibikiPage).evaluate().isEmpty;
          i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(find.byType(ReaderHibikiPage), findsOneWidget,
          reason: 'ReaderHibikiPage must mount after openMedia — if this '
              'fails the reader never opened (not a WebView timeout).');
      debugPrint('[M1] ReaderHibikiPage mounted');

      // === Wait for WebView ===
      const Key webViewKey = ValueKey<String>('hoshi_webview');
      for (int i = 0; i < 60; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(webViewKey).evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.byKey(webViewKey), findsOneWidget,
          reason: 'WebView must be present');

      // === Wait for content ready ===
      const Key contentReadyKey = ValueKey<String>('hoshi_content_ready');
      bool contentReady = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 500));
        if (find.byKey(contentReadyKey).evaluate().isNotEmpty) {
          contentReady = true;
          break;
        }
      }
      expect(contentReady, isTrue,
          reason: 'Reader content must become ready within 60s');

      await tester.pump(const Duration(seconds: 4));
      debugPrint('[M1] Reader content ready');

      // === Acquire JS evaluator hook ===
      final eval = ReaderHibikiPage.debugEvaluateJavascript;
      expect(eval, isNotNull,
          reason: 'Reader debug JS hook must be set when WebView is created. '
              'Run in a debug/profile build (asserts enabled).');

      // === Inject the harness ===
      final injectResult = await eval!(paginationHarnessJs);
      debugPrint('[M1] Harness inject result: $injectResult');

      // === Full chapter scan ===
      debugPrint('[M1] === Full Chapter Scan ===');
      final scanRaw = await eval('window.hoshiTestHarness.fullChapterScan();');
      final List<PageData> pages = parseChapterScan(scanRaw as String);
      debugPrint('[M1] Scanned ${pages.length} pages');
      expect(pages.length, greaterThan(0),
          reason: 'Chapter scan must produce at least one page');

      // Log layout + first pages for context in CI output.
      final settingsRaw =
          await eval('window.hoshiTestHarness.validateRenderedSettings();')
              as String;
      debugPrint('[M1] rendered: $settingsRaw');
      for (int i = 0; i < pages.length && i < 4; i++) {
        final p = pages[i];
        debugPrint('[M1] page ${p.pageNumber} '
            'scroll=${p.state.scroll} pitch=${p.state.columnPitch} '
            'markers=${p.markers.join(",")}');
      }

      // Detect marker count for coverage (I3). Real books have no markers,
      // so coverage is skipped by passing 0.
      int markerCount = 0;
      final allMarkers = <String>{};
      for (final p in pages) {
        allMarkers.addAll(p.markers);
      }
      if (allMarkers.isNotEmpty) {
        markerCount = allMarkers
            .map((m) => int.tryParse(m.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0)
            .fold<int>(0, (a, b) => a > b ? a : b);
      }
      debugPrint('[M1] Distinct markers seen: ${allMarkers.length} '
          '(max index $markerCount)');

      final violations =
          validateChapterScan(pages, expectedMarkerCount: markerCount);

      // Report grouped by invariant.
      final byInv = <String, List<InvariantViolation>>{};
      for (final v in violations) {
        byInv.putIfAbsent(v.invariant, () => []).add(v);
      }
      for (final inv in ['I1', 'I2', 'I3', 'I4', 'I5', 'I6', 'I7']) {
        final vs = byInv[inv];
        if (vs == null || vs.isEmpty) {
          debugPrint('[M1] ✓ $inv passed');
        } else {
          for (final v in vs) {
            debugPrint('[M1] ✗ $v');
          }
        }
      }

      // I1 (alignment), I4 (monotonicity) and I6 (constant step) are the
      // regression detectors for "翻页越翻越偏". They must hold on every book.
      final i1 = byInv['I1'] ?? const [];
      final i4 = byInv['I4'] ?? const [];
      final i6 = byInv['I6'] ?? const [];
      expect(i1, isEmpty,
          reason: 'I1 scroll-alignment violations: ${i1.join("; ")}');
      expect(i4, isEmpty,
          reason: 'I4 monotonicity violations: ${i4.join("; ")}');
      expect(i6, isEmpty,
          reason: 'I6 constant-step (drift) violations: ${i6.join("; ")}');

      // I5 (trailing space) and I7 (page-count sanity) are quality checks.
      final i5 = byInv['I5'] ?? const [];
      final i7 = byInv['I7'] ?? const [];
      expect(i5, isEmpty,
          reason: 'I5 trailing-space violations: ${i5.join("; ")}');
      expect(i7, isEmpty, reason: 'I7 page-count violations: ${i7.join("; ")}');

      // Marker continuity/coverage only when synthetic markers present.
      if (allMarkers.isNotEmpty) {
        final i2 = byInv['I2'] ?? const [];
        final i3 = byInv['I3'] ?? const [];
        expect(i2, isEmpty,
            reason: 'I2 marker-continuity violations: ${i2.join("; ")}');
        expect(i3, isEmpty, reason: 'I3 coverage violations: ${i3.join("; ")}');
        debugPrint('[M1] ✓ Marker continuity + coverage validated');
      } else {
        debugPrint('[M1] ⚠ No markers in book — I2/I3 skipped '
            '(import synthetic test EPUB for full coverage)');
      }

      await takeScreenshot(binding, 'm1_pagination_scan');

      // === I9: Position restoration across chrome toggle ===
      debugPrint('[M1] === I9: Position Restoration ===');
      final beforeState = PaginationState.fromJson(
        _decode(await eval('window.hoshiTestHarness.getPaginationState();')
            as String),
      );
      final beforeMarkers = parseMarkers(
          await eval('window.hoshiTestHarness.getVisibleMarkers();') as String);

      // Toggle reader chrome on/off via the real reader keyboard shortcut.
      // Coordinate taps are banned for off-screen integration tests because
      // overlays, platform windows, and layout drift can make them miss.
      await _toggleReaderChrome(tester, find.byKey(webViewKey));
      await tester.pump(const Duration(seconds: 1));
      await _toggleReaderChrome(tester, find.byKey(webViewKey));
      await tester.pump(const Duration(seconds: 1));

      final afterState = PaginationState.fromJson(
        _decode(await eval('window.hoshiTestHarness.getPaginationState();')
            as String),
      );
      debugPrint('[M1] Scroll before=${beforeState.scroll} '
          'after=${afterState.scroll}');

      if (beforeMarkers.isNotEmpty) {
        final afterMarkers = parseMarkers(
            await eval('window.hoshiTestHarness.getVisibleMarkers();')
                as String);
        final restoreViolations = validatePositionRestoration(
          beforeMarkers: beforeMarkers,
          afterMarkers: afterMarkers,
        );
        expect(restoreViolations, isEmpty,
            reason: 'I9 restoration: ${restoreViolations.join("; ")}');
        debugPrint('[M1] ✓ I9: position restored (marker-based)');
      } else {
        // Without markers, fall back to scroll proximity (within one pitch).
        final drift = (afterState.scroll - beforeState.scroll).abs();
        expect(drift, lessThanOrEqualTo(beforeState.columnPitch + 1),
            reason: 'I9: scroll drifted $drift px across chrome toggle '
                '(pitch ${beforeState.columnPitch})');
        debugPrint('[M1] ✓ I9: scroll within one pitch ($drift px)');
      }

      // === I10: position survives RAPID chrome toggles ===
      // Symptom "快速变动UI回章节开头": rapid toggles fire setChromeInsets again
      // before the previous inset relayout settles, which transiently reset
      // scrollTop to 0 — the stale read then snapped the reader to the chapter
      // start. Unlike I9 (a single settled toggle), this taps repeatedly with
      // only one frame between taps to exercise the race.
      debugPrint('[M1] === I10: Rapid Chrome Toggle ===');
      // Page back into the middle so a regression to chapter start is
      // unambiguous (the I9 step left us at the chapter end).
      for (int i = 0; i < 18; i++) {
        await eval('window.hoshiReader.paginate("backward");');
      }
      await tester.pump(const Duration(milliseconds: 300));
      final midState = PaginationState.fromJson(
        _decode(await eval('window.hoshiTestHarness.getPaginationState();')
            as String),
      );
      final midMarkers = parseMarkers(
          await eval('window.hoshiTestHarness.getVisibleMarkers();') as String);
      expect(midState.scroll, greaterThan(0),
          reason: 'I10 setup: reader must be mid-chapter before rapid toggle');
      debugPrint('[M1] I10 mid scroll=${midState.scroll} '
          'markers=${midMarkers.join(",")}');

      // Fire 8 chrome toggles with only one frame between taps (no settle).
      for (int i = 0; i < 8; i++) {
        await _toggleReaderChrome(tester, find.byKey(webViewKey));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.pump(const Duration(seconds: 1));

      final afterRapid = PaginationState.fromJson(
        _decode(await eval('window.hoshiTestHarness.getPaginationState();')
            as String),
      );
      final afterRapidMarkers = parseMarkers(
          await eval('window.hoshiTestHarness.getVisibleMarkers();') as String);
      debugPrint('[M1] I10 after rapid toggle scroll=${afterRapid.scroll} '
          'markers=${afterRapidMarkers.join(",")}');
      expect(afterRapid.scroll, greaterThan(0),
          reason: 'I10: rapid chrome toggle reset the reader to the chapter '
              'start (scroll=${afterRapid.scroll}, was ${midState.scroll})');
      final i10 = validatePositionRestoration(
        beforeMarkers: midMarkers,
        afterMarkers: afterRapidMarkers,
      );
      expect(i10, isEmpty,
          reason: 'I10 rapid-toggle restoration: ${i10.join("; ")}');
      debugPrint('[M1] ✓ I10: position survived rapid chrome toggles');

      // Navigate back
      final NavigatorState nav = Navigator.of(
        tester.element(find.byType(Scaffold).first),
      );
      nav.pop();
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      assertStrictErrors(errors);
      debugPrint('[M1] === PAGINATION TESTS PASSED ===');
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}

Future<void> _openBooksTab(
  WidgetTester tester,
  FocusDriver driver,
) async {
  final List<Finder> navTargets = findPrimaryNavigationTargets();
  if (navTargets.isEmpty) return;
  final bool focused = await driver.focusWidget(navTargets.first);
  expect(focused, isTrue, reason: 'Books tab must be reachable by focus');
  await driver.activate();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Open the seeded reader book deterministically.
///
/// The shelf book card's Enter→activate→openMedia binding is only installed
/// when the card lives under a [HibikiFocusRoot]; the shelf does not wrap its
/// cards in one, so a focus-driven Enter is a no-op and the reader never opens
/// (TODO-783). Bypass the UI focus tree entirely: resolve the book's
/// [MediaItem] from its key and drive [AppModel.openMedia] directly — the same
/// call the real card tap makes — which pushes [ReaderHibikiPage] onto the
/// navigator regardless of focus-tree state.
Future<void> _activateBook(
  WidgetTester tester,
  String bookKey,
) async {
  final BuildContext appContext =
      tester.element(find.byType(MaterialApp).first);
  final ProviderContainer container = ProviderScope.containerOf(appContext);
  final AppModel appModel = container.read(appProvider);

  // openMedia requires a WidgetRef but never dereferences it on the open path
  // (it routes through the app's navigatorKey context, not ref). The root
  // [HoshiReaderApp] is a ConsumerStatefulWidget, so its element IS a WidgetRef.
  final ConsumerStatefulElement appElement = tester
      .element(find.byType(app.HoshiReaderApp)) as ConsumerStatefulElement;
  final WidgetRef ref = appElement;

  final MediaItem? item =
      await ReaderHibikiSource.instance.mediaItemForBookKey(bookKey);
  expect(item, isNotNull,
      reason: 'Seeded book must resolve to a MediaItem (key=$bookKey)');

  // Do NOT await openMedia to completion: it awaits Navigator.push, whose
  // future only resolves when the reader route is popped, so awaiting it here
  // would block the linear test body forever. Fire it (the same call the real
  // card onTap makes) and pump frames so the push and the reader's async
  // _initBook run; the route-lifetime future is intentionally unawaited.
  unawaited(appModel.openMedia(
    ref: ref,
    mediaSource: ReaderHibikiSource.instance,
    item: item,
  ));
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

Future<void> _toggleReaderChrome(
  WidgetTester tester,
  Finder webView,
) async {
  _focusReaderSurface(webView);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
}

void _focusReaderSurface(Finder webView) {
  final Iterable<Element> matches = webView.evaluate();
  expect(matches, isNotEmpty, reason: 'Reader WebView must be mounted');
  bool focused = false;
  matches.single.visitAncestorElements((Element ancestor) {
    final Widget widget = ancestor.widget;
    if (widget is Focus && widget.onKeyEvent != null) {
      widget.focusNode?.requestFocus();
      focused = true;
      return false;
    }
    return true;
  });
  expect(focused, isTrue, reason: 'Reader focus surface must wrap WebView');
}

Map<String, dynamic> _decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// Imports the synthetic marker EPUB directly into the app database, then
/// refreshes the shelf provider so the book appears. Keeps the pagination
/// test self-contained on an otherwise-empty fresh install.
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
    fileName: 'test_pagination.epub',
  );
  debugPrint('[M1] Imported test EPUB as book key=$bookKey');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  // Bounded pump instead of pumpAndSettle: off-screen the shelf keeps
  // scheduling frames (cover image loads / periodic providers), so an
  // unbounded pumpAndSettle never reaches quiescence and silently eats the
  // whole test budget. A fixed pump lets the invalidated books provider
  // rebuild without waiting for a steady state that never arrives.
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  debugPrint('[M1] Shelf refreshed after seed');
  return bookKey;
}
