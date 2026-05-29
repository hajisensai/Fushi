import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/pages/implementations/shortcut_settings_page.dart';

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
/// STATUS: NOT YET DEVICE-VERIFIED. The mechanism is verified by the two widget
/// tests above (real Flutter key pipeline). A full-app `flutter drive` run on
/// emulator-5556 was attempted 2026-05-29 but the whole-app build was blocked by
/// an unrelated compile error in another work-in-progress file (sync backend),
/// not by this feature. Re-run once the tree compiles; expected to pass.
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
    for (final LogicalKeyboardKey k in dirs) {
      await tester.sendKeyEvent(k);
      await tester.pumpAndSettle();
      seen.add(FocusManager.instance.primaryFocus);
    }
    expect(seen.length, greaterThan(1),
        reason: 'directional keys must move focus across distinct home '
            'widgets (the UI is gamepad-traversable without taps)');

    // ── gameButtonB pops a pushed route via the global pop intent ──
    final BuildContext ctx = tester.element(find.byType(HomePage).first);
    Navigator.of(ctx).push(MaterialPageRoute<void>(
      builder: (_) => const ShortcutSettingsPage(),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ShortcutSettingsPage), findsOneWidget,
        reason: 'a route is pushed to be popped by gamepad B');

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.byType(ShortcutSettingsPage), findsNothing,
        reason: 'gameButtonB must pop the route via HibikiPopIntent');
    expect(find.byType(HomePage), findsOneWidget);
  });
}
