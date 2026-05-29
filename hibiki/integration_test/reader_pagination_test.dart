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

import 'helpers/generate_test_epub.dart' show EpubGenerator;
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

      // === Open first book ===
      // Ensure we're on the Books tab before looking for entries (home may
      // default to another tab; the shelf list also lazy-loads).
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

      // flutter drive installs a fresh, empty app each run, so seed the
      // synthetic marker EPUB ourselves to keep the test hermetic.
      if (bookEntries.evaluate().isEmpty) {
        debugPrint('[M1] Shelf empty — importing synthetic marker EPUB');
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
        fail('M1 blocked: failed to seed test EPUB onto shelf.');
      }

      await tester.tap(bookEntries.first);
      await tester.pump(const Duration(seconds: 3));

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
      final scanRaw =
          await eval('window.hoshiTestHarness.fullChapterScan();');
      final List<PageData> pages = parseChapterScan(scanRaw as String);
      debugPrint('[M1] Scanned ${pages.length} pages');
      expect(pages.length, greaterThan(0),
          reason: 'Chapter scan must produce at least one page');

      // Log layout + first pages for context in CI output.
      final settingsRaw = await eval(
          'window.hoshiTestHarness.validateRenderedSettings();') as String;
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
      expect(i7, isEmpty,
          reason: 'I7 page-count violations: ${i7.join("; ")}');

      // Marker continuity/coverage only when synthetic markers present.
      if (allMarkers.isNotEmpty) {
        final i2 = byInv['I2'] ?? const [];
        final i3 = byInv['I3'] ?? const [];
        expect(i2, isEmpty,
            reason: 'I2 marker-continuity violations: ${i2.join("; ")}');
        expect(i3, isEmpty,
            reason: 'I3 coverage violations: ${i3.join("; ")}');
        debugPrint('[M1] ✓ Marker continuity + coverage validated');
      } else {
        debugPrint('[M1] ⚠ No markers in book — I2/I3 skipped '
            '(import synthetic test EPUB for full coverage)');
      }

      await takeScreenshot(binding, 'm1_pagination_scan');

      // === I9: Position restoration across chrome toggle ===
      debugPrint('[M1] === I9: Position Restoration ===');
      final beforeState = PaginationState.fromJson(
        _decode(await eval(
            'window.hoshiTestHarness.getPaginationState();') as String),
      );
      final beforeMarkers = parseMarkers(
          await eval('window.hoshiTestHarness.getVisibleMarkers();')
              as String);

      // Toggle reader chrome on/off (center tap) without changing settings.
      final centerTap = Offset(
        tester.view.physicalSize.width / tester.view.devicePixelRatio / 2,
        tester.view.physicalSize.height / tester.view.devicePixelRatio / 2,
      );
      await tester.tapAt(centerTap);
      await tester.pump(const Duration(seconds: 1));
      await tester.tapAt(centerTap);
      await tester.pump(const Duration(seconds: 1));

      final afterState = PaginationState.fromJson(
        _decode(await eval(
            'window.hoshiTestHarness.getPaginationState();') as String),
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

Map<String, dynamic> _decode(String json) =>
    jsonDecode(json) as Map<String, dynamic>;

/// Imports the synthetic marker EPUB directly into the app database, then
/// refreshes the shelf provider so the book appears. Keeps the pagination
/// test self-contained on an otherwise-empty fresh install.
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
    fileName: 'test_pagination.epub',
  );
  debugPrint('[M1] Imported test EPUB as book id=$bookId');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  await tester.pumpAndSettle();
}
