import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/media.dart';
import 'package:hibiki/src/epub/epub_importer.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/pages/implementations/reader_hibiki_page.dart';

import 'helpers/focus_driver.dart';
import 'helpers/generate_test_epub.dart' show EpubGenerator;
import 'test_helpers.dart';

/// TODO-975 floating/collapsible reader chrome — remaining interaction behaviors
/// device-layer (real-DOM) verification.
///
/// 975 core geometry (BUG-470 top progress first-load inset) already proven by
/// reader_top_progress_inset_dom_test.dart. This test covers behaviors NOT
/// covered there, all on a freshly imported paginated EPUB, asserting on the
/// real CSS variables injected into the WebView (--chrome-top-inset /
/// --chrome-bottom-inset) plus the body first-line getBoundingClientRect().top:
///
///  1. Reclaim blank: show_top_progress_bar ON->OFF reclaims the 18px reserve
///     (--chrome-top-inset -> 0, first line top -> ~0). reader_chrome_floating
///     topProgressReserve:48 returns 0 when progress disabled.
///  2. Floating does not take text space (975 core ask): top progress floating
///     false->true keeps --chrome-top-inset at 0 (floating reserve is 0); first
///     line top stays ~0 (strip overlays body, not pushed down).
///  3. Bottom tap-reveal no-layout-shift: tap_empty_hide_chrome false->true
///     drops --chrome-bottom-inset from (bar height ~56px) to system inset only;
///     onTapEmpty reveal keeps --chrome-bottom-inset unchanged.
///  4. auto-hide timing (best-effort): after reveal, pump the configured
///     duration; the floating bottom bar (hoshi_play_bar) auto-hides.
///
/// Triggering: prefs via ReaderHibikiSource.instance.toggleXxx() (fire-and-forget
/// async, pump to land); reader re-anchor via the same settings-UI notify entry
/// ReaderHibikiSource.onChromeReanchorLive?.call() (clears transient +
/// _applyChromeInsetsAndReanchor pushes new inset to WebView); bottom tap reveal
/// via the real JS bridge window.flutter_inappwebview.callHandler('onTapEmpty')
/// (reader_selection_scripts.dart:652 -> webview.part.dart:1320 onTapEmpty
/// handler -> _handleFloatingChromeReveal).
///
/// Run (Windows offscreen harness, non-blocking + auto proxy):
///   powershell -ExecutionPolicy Bypass -File tool/run_windows_itest.ps1
///       integration_test/reader_chrome_floating_itest.dart
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'TODO-975: floating/collapsible reader chrome — reclaim, no-layout-shift, '
    'tap-reveal, auto-hide (real DOM insets)',
    timeout: const Timeout(Duration(minutes: 6)),
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = [];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[CHROME975] FlutterError: ${details.exceptionAsString()}');
      };

      try {
        app.main();
        expect(await waitForHome(tester), isTrue, reason: 'Home within 90s');
        await tester.pump(const Duration(seconds: 2));

        // Defaults ARE the 975 baseline: top progress ON + squeeze (18px),
        // bottom squeeze (bar height), top floating off, bottom floating
        // (tap_empty_hide_chrome) off. Assert once so a silently-changed default
        // fails loudly here.
        expect(ReaderHibikiSource.instance.showTopProgressBar, isTrue,
            reason: 'top progress must default ON (975 baseline).');
        expect(ReaderHibikiSource.instance.topProgressFloating, isFalse,
            reason: 'top progress must default to squeeze (non-floating).');
        expect(ReaderHibikiSource.instance.tapEmptyToHideChrome, isFalse,
            reason: 'bottom bar must default to squeeze.');

        final FocusDriver driver = FocusDriver(tester);

        await _openBooksTab(tester, driver);
        final String bookKey = await _seedTestBook(tester);
        await _openBooksTab(tester, driver);

        final String seededKey =
            'book_entry_${ReaderHibikiSource.mediaIdentifierFor(bookKey)}';
        final Finder seededEntry = find.byKey(ValueKey<String>(seededKey));
        for (int i = 0; i < 40 && seededEntry.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(seededEntry, findsOneWidget,
            reason: 'freshly seeded paginated book must appear on the shelf');

        await _activateBook(tester, bookKey);
        await tester.pump(const Duration(seconds: 3));

        for (int i = 0;
            i < 40 && find.byType(ReaderHibikiPage).evaluate().isEmpty;
            i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(find.byType(ReaderHibikiPage), findsOneWidget,
            reason: 'ReaderHibikiPage must mount after openMedia.');

        const Key webViewKey = ValueKey<String>('hoshi_webview');
        bool webViewPresent = false;
        for (int i = 0; i < 180; i++) {
          await tester.pump(const Duration(milliseconds: 500));
          if (find.byKey(webViewKey).evaluate().isNotEmpty) {
            webViewPresent = true;
            break;
          }
          if (i % 20 == 0) debugPrint('[CHROME975] waiting for WebView i=$i');
        }
        expect(webViewPresent, isTrue, reason: 'WebView present');

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

        final eval = ReaderHibikiPage.debugEvaluateJavascript;
        expect(eval, isNotNull,
            reason: 'Reader debug JS hook must be set (debug/profile build).');

        // ── DOM probes ────────────────────────────────────────────────
        Future<double> readCssVar(String name) async {
          final Object? raw = await eval!(
            '(function(){var v=getComputedStyle(document.documentElement)'
            ".getPropertyValue('$name');return parseFloat(v)||0;})()",
          );
          return double.tryParse(raw.toString()) ?? -1;
        }

        Future<double> readChromeTopInset() => readCssVar('--chrome-top-inset');
        Future<double> readChromeBottomInset() =>
            readCssVar('--chrome-bottom-inset');

        Future<Map<String, dynamic>> readFirstTextLine() async {
          final Object? raw = await eval!(jsFirstTextLineProbe);
          final dynamic decoded = jsonDecode(raw.toString());
          return decoded == null
              ? <String, dynamic>{}
              : (decoded as Map<String, dynamic>);
        }

        Future<double> firstLineTop() async {
          final Map<String, dynamic> line = await readFirstTextLine();
          return (line['top'] as num?)?.toDouble() ?? -1;
        }

        // pump until a DOM reading stably satisfies a predicate, or time out.
        Future<double> settleCssVar(
          Future<double> Function() read,
          bool Function(double) ok, {
          int maxPolls = 40,
        }) async {
          double value = -1;
          for (int i = 0; i < maxPolls; i++) {
            await tester.pump(const Duration(milliseconds: 300));
            value = await read();
            if (ok(value)) break;
          }
          return value;
        }

        const double kTopReservePx = 18.0; // _infoFontSize(12) * 1.5
        const double kEps = 1.5;

        // ───────────────────────────────────────────────────────────────
        // Baseline: top squeeze ON -> top-inset has 18px reserve; bottom squeeze
        // -> bottom-inset has bar height (~56px). The 975 "old behavior" control.
        // ───────────────────────────────────────────────────────────────
        final double baseTopInset = await settleCssVar(
          readChromeTopInset,
          (v) => v >= kTopReservePx - 1.0,
        );
        final double baseBottomInset = await readChromeBottomInset();
        final double baseFirstTop = await firstLineTop();
        debugPrint('[CHROME975] BASELINE topInset=$baseTopInset '
            'bottomInset=$baseBottomInset firstTop=$baseFirstTop');

        expect(baseTopInset, greaterThanOrEqualTo(kTopReservePx - 1.0),
            reason: 'baseline: top squeeze ON, --chrome-top-inset has 18px. '
                'got=$baseTopInset');
        expect(baseFirstTop, greaterThanOrEqualTo(kTopReservePx - 1.0),
            reason:
                'baseline: first line top clears the strip. got=$baseFirstTop');
        // System bottom inset is usually 0 on desktop; assert "clearly > 0" with
        // a wide tolerance rather than coupling to the exact scaled height.
        expect(baseBottomInset, greaterThan(30.0),
            reason: 'baseline: bottom squeeze, --chrome-bottom-inset has bar '
                'height (~56px). got=$baseBottomInset');

        // ───────────────────────────────────────────────────────────────
        // Goal 1: reclaim blank. show_top_progress_bar ON->OFF -> top-inset
        // back to 0, first line top back to ~0.
        // ───────────────────────────────────────────────────────────────
        ReaderHibikiSource.instance.toggleShowTopProgressBar();
        await _pumpForPref(tester);
        expect(ReaderHibikiSource.instance.showTopProgressBar, isFalse,
            reason: 'progress-off pref must land false');
        ReaderHibikiSource.onChromeReanchorLive?.call();

        final double offTopInset = await settleCssVar(
          readChromeTopInset,
          (v) => v <= 1.0,
        );
        final double offFirstTop = await firstLineTop();
        debugPrint('[CHROME975] PROGRESS-OFF topInset=$offTopInset '
            'firstTop=$offFirstTop');

        expect(offTopInset, lessThanOrEqualTo(1.0),
            reason: 'goal1: progress OFF -> --chrome-top-inset reclaimed to 0. '
                'got=$offTopInset');
        expect(offFirstTop, lessThanOrEqualTo(kTopReservePx - 1.0),
            reason: 'goal1: progress OFF -> first line moves into former strip '
                'area (< 18px). got=$offFirstTop');

        // ───────────────────────────────────────────────────────────────
        // Goal 2: floating does not take text space. Restore progress ON (now
        // squeeze, 18px), then switch to floating -> top-inset back to 0, first
        // line top back to ~0 (strip overlays body, not pushed down).
        // ───────────────────────────────────────────────────────────────
        ReaderHibikiSource.instance.toggleShowTopProgressBar(); // restore ON
        await _pumpForPref(tester);
        expect(ReaderHibikiSource.instance.showTopProgressBar, isTrue);
        ReaderHibikiSource.onChromeReanchorLive?.call();
        final double reTopInset = await settleCssVar(
          readChromeTopInset,
          (v) => v >= kTopReservePx - 1.0,
        );
        expect(reTopInset, greaterThanOrEqualTo(kTopReservePx - 1.0),
            reason: 'precondition: restoring progress ON re-adds 18px. '
                'got=$reTopInset');

        ReaderHibikiSource.instance.toggleTopProgressFloating(); // to floating
        await _pumpForPref(tester);
        expect(ReaderHibikiSource.instance.topProgressFloating, isTrue,
            reason: 'top floating pref must land true');
        ReaderHibikiSource.onChromeReanchorLive?.call();

        final double floatTopInset = await settleCssVar(
          readChromeTopInset,
          (v) => v <= 1.0,
        );
        final double floatFirstTop = await firstLineTop();
        debugPrint('[CHROME975] TOP-FLOATING topInset=$floatTopInset '
            'firstTop=$floatFirstTop');

        expect(floatTopInset, lessThanOrEqualTo(1.0),
            reason: 'goal2: top floating -> --chrome-top-inset is 0 (floating '
                'reserve 0, strip overlays body). got=$floatTopInset');
        expect(floatFirstTop, lessThanOrEqualTo(kTopReservePx - 1.0),
            reason: 'goal2: floating -> first line not pushed down (< 18px), '
                'i.e. does not take text space. got=$floatFirstTop');

        await takeScreenshot(binding, 'todo975_top_floating_no_layout_shift');

        // ───────────────────────────────────────────────────────────────
        // Goal 3: bottom tap-reveal no-layout-shift. tap_empty_hide_chrome
        // false->true drops bottom-inset to system inset only; JS bridge
        // onTapEmpty reveals the bar -> bottom-inset unchanged (floating bottom
        // bar does not take text space, visible body height does not shrink).
        // ───────────────────────────────────────────────────────────────
        ReaderHibikiSource.instance.toggleTapEmptyToHideChrome();
        await _pumpForPref(tester);
        expect(ReaderHibikiSource.instance.tapEmptyToHideChrome, isTrue,
            reason: 'bottom floating pref must land true');
        ReaderHibikiSource.onChromeReanchorLive?.call();

        final double floatBottomInset = await settleCssVar(
          readChromeBottomInset,
          (v) => v <= 5.0,
        );
        debugPrint('[CHROME975] BOTTOM-FLOATING(hidden) '
            'bottomInset=$floatBottomInset');
        expect(floatBottomInset, lessThan(baseBottomInset - 20.0),
            reason:
                'goal3: bottom floating -> --chrome-bottom-inset drops from '
                'bar height ($baseBottomInset) to system inset only. '
                'got=$floatBottomInset');

        // Reveal the floating bottom bar via the real JS bridge.
        await eval!("window.flutter_inappwebview.callHandler('onTapEmpty')");
        for (int i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 200));
          if (find
              .byKey(const ValueKey<String>('hoshi_play_bar'))
              .evaluate()
              .isNotEmpty) {
            break;
          }
        }
        final bool barRevealed = find
            .byKey(const ValueKey<String>('hoshi_play_bar'))
            .evaluate()
            .isNotEmpty;
        final double revealedBottomInset = await readChromeBottomInset();
        debugPrint('[CHROME975] BOTTOM-FLOATING(revealed) '
            'barRevealed=$barRevealed bottomInset=$revealedBottomInset');

        expect(barRevealed, isTrue,
            reason: 'goal3: onTapEmpty must reveal the floating bottom bar '
                '(hoshi_play_bar appears).');
        // Core: inset unchanged after reveal (floating overlay does not push the
        // body / shrink the visible body height).
        expect((revealedBottomInset - floatBottomInset).abs(),
            lessThanOrEqualTo(kEps),
            reason: 'goal3: revealing the floating bottom bar must NOT change '
                '--chrome-bottom-inset (no layout shift). '
                'hidden=$floatBottomInset revealed=$revealedBottomInset');

        await takeScreenshot(binding, 'todo975_bottom_floating_revealed');

        // ───────────────────────────────────────────────────────────────
        // Goal 4: auto-hide timing (best-effort). After reveal, advance the
        // configured duration; the floating bottom bar should auto-hide.
        // _armChromeAutoHide uses a real Timer (not tester fake clock), so
        // advance wall-clock time then pump for the setState to rebuild.
        // ───────────────────────────────────────────────────────────────
        final int autoHideMs = ReaderHibikiSource.instance.autoHideChromeMillis;
        debugPrint('[CHROME975] auto-hide millis=$autoHideMs');
        await tester.pump(Duration(milliseconds: autoHideMs + 400));
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 200));
          if (find
              .byKey(const ValueKey<String>('hoshi_play_bar'))
              .evaluate()
              .isEmpty) {
            break;
          }
        }
        final bool barAutoHidden = find
            .byKey(const ValueKey<String>('hoshi_play_bar'))
            .evaluate()
            .isEmpty;
        debugPrint('[CHROME975] AUTO-HIDE barAutoHidden=$barAutoHidden');
        expect(barAutoHidden, isTrue,
            reason: 'goal4: after waiting auto-hide (${autoHideMs}ms), the '
                'floating bottom bar must auto-hide (hoshi_play_bar gone).');

        // ── Restore prefs + exit ────────────────────────────────────────
        ReaderHibikiSource.instance.toggleTopProgressFloating();
        ReaderHibikiSource.instance.toggleTapEmptyToHideChrome();
        await _pumpForPref(tester);

        final NavigatorState nav =
            Navigator.of(tester.element(find.byType(Scaffold).first));
        nav.pop();
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();

        assertStrictErrors(errors);
        debugPrint('[CHROME975] === TODO-975 FLOATING CHROME TEST PASSED ===');
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}

/// Give the fire-and-forget async pref setter a few frames to land.
Future<void> _pumpForPref(WidgetTester tester) async {
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// Locate the first visible body text block and return its client rect (JSON).
/// Same probe as reader_top_progress_inset_dom_test.dart.
const String jsFirstTextLineProbe = r'''
(function(){
  function visible(el){
    var r = el.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0) return false;
    var cs = getComputedStyle(el);
    if (cs.display === 'none' || cs.visibility === 'hidden') return false;
    return (el.textContent || '').trim().length > 0;
  }
  var nodes = document.querySelectorAll('p,div,span,li,blockquote,h1,h2,h3');
  for (var i = 0; i < nodes.length; i++) {
    var el = nodes[i];
    var hasChildBlock = false;
    for (var j = 0; j < el.children.length; j++) {
      if (visible(el.children[j])) { hasChildBlock = true; break; }
    }
    if (hasChildBlock) continue;
    if (!visible(el)) continue;
    var r = el.getBoundingClientRect();
    return JSON.stringify({
      top: r.top,
      bottom: r.bottom,
      tag: el.tagName,
      text: (el.textContent || '').trim().substr(0, 12)
    });
  }
  return JSON.stringify(null);
})()
''';

/// Bring the Books tab to front.
Future<void> _openBooksTab(WidgetTester tester, FocusDriver driver) async {
  final List<Finder> navTargets = findPrimaryNavigationTargets();
  if (navTargets.isEmpty) return;
  final bool focused = await driver.focusWidget(navTargets.first);
  expect(focused, isTrue, reason: 'Books tab must be reachable by focus');
  await driver.activate();
  await tester.pump(const Duration(milliseconds: 500));
}

/// Import a fresh synthetic EPUB (no audiobook), return its book key.
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
    fileName: 'test_chrome_floating.epub',
  );
  debugPrint('[CHROME975] Imported test EPUB as book key=$bookKey');

  container.invalidate(hibikiBooksProvider(appModel.targetLanguage));
  await tester.pumpAndSettle();
  return bookKey;
}

/// Deterministically open the shelf book (same approach as
/// reader_top_progress_inset_dom_test._activateBook): resolve MediaItem from key
/// and drive AppModel.openMedia directly (bypassing the focus tree, TODO-783).
Future<void> _activateBook(WidgetTester tester, String bookKey) async {
  final BuildContext appContext =
      tester.element(find.byType(MaterialApp).first);
  final ProviderContainer container = ProviderScope.containerOf(appContext);
  final AppModel appModel = container.read(appProvider);

  final ConsumerStatefulElement appElement = tester
      .element(find.byType(app.HoshiReaderApp)) as ConsumerStatefulElement;
  final WidgetRef ref = appElement;

  final MediaItem? item =
      await ReaderHibikiSource.instance.mediaItemForBookKey(bookKey);
  expect(item, isNotNull,
      reason: 'Seeded book must resolve to a MediaItem (key=$bookKey)');

  unawaited(appModel.openMedia(
    ref: ref,
    mediaSource: ReaderHibikiSource.instance,
    item: item!,
  ));
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}
