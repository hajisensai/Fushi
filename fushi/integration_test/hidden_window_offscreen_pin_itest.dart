import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/src/startup/test_root_shared_preferences.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/legacy_support_dir_migration.dart';
import 'package:fushi/utils.dart';
import 'package:fushi_core/fushi_core.dart' show FushiDatabase;
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'test_helpers.dart';

/// BUG-3704: the FUSHI_TEST_HIDDEN main window must stay where the runner
/// parked it (off-screen at -32000) after Dart startup placement ran —
/// `applyInitialPlacement` centres it in a work area and, with a saved
/// maximized state, maximizes it. Before the fix the window landed on the
/// user's desktop two seconds after launch.
///
/// Run (default off-screen mode only; `-Visible` deliberately leaves the
/// window movable):
///   .\tool\run_windows_itest.ps1 integration_test\hidden_window_offscreen_pin_itest.dart
///   ... -DartDefine PROBE_MAXIMIZED=true   (saved maximized state variant)
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hidden test window stays off-screen after startup placement', (
    WidgetTester tester,
  ) async {
    UpdateChecker.disableAutoCheckForTesting = true;
    const bool seedMaximized = bool.fromEnvironment('PROBE_MAXIMIZED');
    final bool onscreen =
        Platform.environment['FUSHI_TEST_ONSCREEN']?.isNotEmpty == true;
    isolateSharedPreferencesUnderTestRoot();
    await migrateLegacySupportDir();
    final AppPaths paths = await AppPaths.resolve();
    final FushiDatabase db = FushiDatabase(paths.supportRoot.path);
    try {
      await db.setPrefTyped<bool>('first_time_setup', false);
      await db.setPrefTyped<bool>('onboarding_completed', true);
    } finally {
      await db.close();
    }
    if (seedMaximized) {
      // An on-screen saved geometry plus the maximized flag: the strongest
      // pull towards the desktop the placement code has.
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('desktop_main_window_x', 100);
      await prefs.setDouble('desktop_main_window_y', 100);
      await prefs.setDouble('desktop_main_window_width', 1200);
      await prefs.setDouble('desktop_main_window_height', 800);
      await prefs.setBool('desktop_main_window_maximized', true);
    }
    debugPrint('[probe] pid=$pid seedMaximized=$seedMaximized');
    // app.main() installs its own FlutterError.onError; a failing expect
    // with it still installed is reported as "A test overrode
    // FlutterError.onError" instead of the real mismatch.
    final FlutterExceptionHandler? testOnError = FlutterError.onError;
    app.main();
    expect(await waitForHome(tester), isTrue);

    final List<Rect> samples = <Rect>[];
    for (int i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 2));
      final Rect b = await windowManager.getBounds();
      final bool max = await windowManager.isMaximized();
      debugPrint('[probe] t=${i * 2}s bounds=$b maximized=$max');
      samples.add(b);
    }
    FlutterError.onError = testOnError;
    if (onscreen) return;
    for (final Rect b in samples) {
      // window_manager reports logical pixels; -32000 physical is at most
      // -32000/scale logical, far left of any real monitor either way.
      expect(b.left, lessThan(-5000), reason: 'window moved on-screen: $b');
      expect(b.top, lessThan(-5000), reason: 'window moved on-screen: $b');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
