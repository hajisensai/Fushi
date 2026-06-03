import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/reader/reader_settings.dart';

import 'helpers/effect_probes.dart';
import 'helpers/focus_driver.dart';
import 'test_helpers.dart';

/// Phase 2 Step 2 — desktop, background, real app, effect-verified.
///
/// Proves the Phase 2 foundation end-to-end on the REAL Windows app (not a
/// widget-test AppModel): under HIBIKI_TEST_HIDDEN the runner lives off-screen
/// and never steals foreground (see win32_window.cpp), so this runs while the
/// machine is in use. Asserts three things the widget-level Phase 1 tests
/// can't:
///   1. the real, fully-initialised app renders home in the hidden runner;
///   2. focus TRAVERSAL works on the live UI (FocusDriver / synthetic Tab —
///      no coordinate taps), reaching multiple real focus targets;
///   3. a reading-setting change on the LIVE [ReaderHibikiSource.readerSettings]
///      flows into the render pipeline — [ReaderContentStyles.css] really
///      changes (T1 effect probe on the real settings instance + real DB),
///      not just a persisted value.
///
/// KNOWN GAP (Step 2b, tracked in the Phase 2 plan): driving the *activation*
/// of the live UI by key is blocked on Windows. The app's nav/list activation
/// resolves ActivateIntent from gameButtonA via the gamepad service, and
/// gameButtonA has no Windows physical-key mapping, so it can't be synthesized
/// in a desktop integration test; plain Enter/Space did not navigate the
/// gamepad-owned nav either. So this test focus-TRAVERSES (proven) but applies
/// the setting change through the live settings instance the UI shares, rather
/// than focus-ACTIVATING the control. Closing Step 2b needs a keyboard
/// activation path (and may surface a real desktop keyboard-a11y gap).
///
/// Run (PowerShell, from hibiki/):
///   $env:HIBIKI_TEST_HIDDEN = "1"
///   flutter test integration_test/desktop_settings_smoke_test.dart -d windows
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'desktop hidden runner: real app inits, focus traverses, reading setting '
      'takes real effect on the live instance',
      (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[desktop-settings] FlutterError: '
          '${details.exceptionAsString()}');
    };

    // The setting we flip lives in the user's real DB; restore it in finally so
    // an assertion failure can never leave the writing mode changed.
    ReaderSettings? liveSettings;
    String? originalMode;
    try {
      app.main();

      // 1) Real app initialises + renders home in the off-screen runner.
      final bool homeReady = await waitForHome(tester);
      expect(homeReady, isTrue, reason: 'Home must render within 90s');
      await tester.pump(const Duration(seconds: 2));

      // 2) Focus traversal works on the live UI (synthetic Tab only).
      final FocusDriver driver = FocusDriver(tester);
      final List<FocusNode> reached = await driver.reachAll(maxSteps: 40);
      debugPrint('[desktop-settings] focus traversal reached '
          '${reached.length} targets');
      expect(reached.length, greaterThanOrEqualTo(3),
          reason: 'Focus-driven Tab traversal must reach multiple real targets '
              'on the live home (proves the focus net is alive in the hidden '
              'runner)');

      // 3) The live reader-settings instance the app actually renders from.
      liveSettings = ReaderHibikiSource.readerSettings;
      expect(liveSettings, isNotNull,
          reason: 'Real app should wire ReaderHibikiSource.readerSettings');
      await liveSettings!.refreshFromDb();

      final ReaderCssEffectProbe probe =
          ReaderCssEffectProbe(() => ReaderHibikiSource.readerSettings!);
      final EffectSnapshot before = probe.capture();

      // Flip the writing mode on the live instance (the same instance the UI
      // mutates) and prove it reaches the render pipeline. writingMode toggles
      // both the `writing-mode` declaration and the vertical-only gated block,
      // so the generated CSS must differ.
      originalMode = liveSettings.writingMode;
      final String flipped =
          originalMode.startsWith('vertical') ? 'horizontal-tb' : 'vertical-rl';
      await liveSettings.setWritingMode(flipped);
      await ReaderHibikiSource.readerSettings!.refreshFromDb();

      final EffectVerdict verdict = probe.compare(before, probe.capture());
      debugPrint('[desktop-settings] effect changed=${verdict.changed} '
          'evidence=${verdict.evidence}');
      expect(verdict.changed, isTrue,
          reason: 'A reading-setting change on the live instance must alter the '
              'live ReaderContentStyles.css (real effect, not just persist)');

      assertStrictErrors(errors);
      debugPrint('[desktop-settings] PASS — real app, hidden runner, focus '
          'traversal alive, live reading-setting effect-verified');
    } finally {
      // Restore the user's real writing mode no matter how the test exits.
      if (liveSettings != null && originalMode != null) {
        await liveSettings.setWritingMode(originalMode);
      }
      FlutterError.onError = oldHandler;
    }
  });
}
