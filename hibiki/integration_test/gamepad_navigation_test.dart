import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/pages.dart';

import 'test_helpers.dart';

/// Real-device verification of the universal gamepad/keyboard navigation layer
/// on the HOME surface (no WebView involved — the only emulator available
/// crashes its WebView renderer, see docs/REGRESSION_BUGS.md HBK #1).
///
/// Proves, on the real Android Flutter engine, that:
///   1. directional keys (D-pad maps to arrow logical keys) move focus among
///      the real home widgets — i.e. the UI is traversable without taps;
///   2. gameButtonB pops a pushed route via the global HibikiPopIntent.
///
/// gameButtonA activation is covered device-independently by
/// test/shortcuts/gamepad_navigation_flow_test.dart and
/// test/widgets/hibiki_focusable_test.dart.
///
/// STATUS (2026-05-29): mechanism verified by the two widget tests above (real
/// Flutter key pipeline). This `flutter drive` run is the device path and uses
/// in-engine `WidgetTester.sendKeyEvent` — the ONLY reliable way to drive the
/// Flutter focus system. Note: raw `adb shell input keyevent` was empirically
/// found NOT to drive this Flutter app on emulator-5556 (DPAD/Tab/Back produced
/// no focus change despite the app holding window focus), matching the repo
/// testing architecture (UI interaction goes through `flutter drive`, not adb).
/// Device runs here were also slowed by cold Windows builds; the test itself is
/// expected to pass on a stable tree.
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/gamepad_navigation_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('directional keys traverse the home; gameButtonB pops',
      (WidgetTester tester) async {
    app.main();

    final bool homeReady = await waitForHome(tester);
    expect(homeReady, isTrue, reason: 'Home must render');
    await tester.pump(const Duration(seconds: 1));

    // ── Directional traversal moves focus among real home widgets ──
    final Set<FocusNode?> seen = <FocusNode?>{
      FocusManager.instance.primaryFocus,
    };
    const List<LogicalKeyboardKey> dirs = <LogicalKeyboardKey>[
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowDown,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowLeft,
    ];
    // Bounded pumps (NOT pumpAndSettle): the live home may host a perpetual
    // animation (sync indicator, image fade) that never settles, which would
    // hang pumpAndSettle until its 10-minute timeout.
    for (final LogicalKeyboardKey k in dirs) {
      await tester.sendKeyEvent(k);
      await tester.pump(const Duration(milliseconds: 400));
      seen.add(FocusManager.instance.primaryFocus);
    }
    expect(seen.length, greaterThan(1),
        reason: 'directional keys must move focus across distinct home '
            'widgets (the UI is gamepad-traversable without taps)');

    // ── gameButtonB pops a pushed route via the global pop intent ──
    final NavigatorState navigator = Navigator.of(
      tester.element(find.byType(HomePage).first),
    );
    navigator.push(MaterialPageRoute<void>(
      builder: (_) => const ShortcutSettingsPage(),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ShortcutSettingsPage), findsOneWidget,
        reason: 'a route is pushed to be popped by gamepad B');

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(ShortcutSettingsPage), findsNothing,
        reason: 'gameButtonB must pop the route via HibikiPopIntent');
    expect(find.byType(HomePage), findsOneWidget);
  });
}
