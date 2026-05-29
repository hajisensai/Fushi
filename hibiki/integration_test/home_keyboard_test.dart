import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';

import 'test_helpers.dart';

/// Real-device verification of HOME keyboard shortcuts (no WebView involved).
///
/// This is the part of the shortcut feature an emulator CAN verify: home/global
/// shortcuts never touch the reader WebView (whose renderer crashes on this
/// emulator). It runs on the real Android Flutter engine with the android
/// platform defaults loaded, exercising key dispatch → registry resolution →
/// _handleKeyEvent → tab switch, and confirms the #4 fix (home Focus autofocus
/// on mobile) lets a freshly-launched home receive hardware keys.
///
/// Android home defaults have no keyboard bindings, so the test binds keys at
/// runtime via the live registry, then drives them with sendKeyEvent.
///
/// STATUS: VERIFIED on emulator-5556 (Android) on 2026-05-29 — "All tests
/// passed". Unlike reader_keyboard_test.dart this path needs no WebView, so it
/// runs cleanly on the emulator.
///
/// Run:
///   flutter drive --driver=test_driver/integration_test.dart \
///       --target=integration_test/home_keyboard_test.dart
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  AppModel appModelOf(WidgetTester tester) {
    final element = tester.element(find.byType(HomePage).first);
    return ProviderScope.containerOf(element, listen: false).read(appProvider);
  }

  testWidgets('home keyboard shortcuts switch tabs on real Android',
      (WidgetTester tester) async {
    app.main();

    final bool homeReady = await waitForHome(tester);
    expect(homeReady, isTrue, reason: 'Home must render');
    await tester.pump(const Duration(seconds: 1));

    // Books tab (0) is the default: reader-home content shown, dictionary not.
    expect(find.byType(HomeReaderPage), findsOneWidget,
        reason: 'should start on the books tab');
    expect(find.byType(HomeDictionaryPage), findsNothing);

    // Bind two free keys at runtime (android home defaults are empty).
    final AppModel appModel = appModelOf(tester);
    appModel.shortcutRegistry.updateBinding(
      ShortcutAction.homeTabDict,
      const ShortcutBindingSet(keyboardBindings: <InputBinding>[
        InputBinding(key: LogicalKeyboardKey.keyJ),
      ]),
    );
    appModel.shortcutRegistry.updateBinding(
      ShortcutAction.homeTabBooks,
      const ShortcutBindingSet(keyboardBindings: <InputBinding>[
        InputBinding(key: LogicalKeyboardKey.keyB),
      ]),
    );
    await tester.pump();

    // KeyJ → dictionary tab.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pumpAndSettle();
    expect(find.byType(HomeDictionaryPage), findsOneWidget,
        reason:
            'KeyJ (homeTabDict) must switch to the dictionary tab on a real '
            'Android device');
    expect(find.byType(HomeReaderPage), findsNothing);

    // KeyB → back to the books tab.
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.pumpAndSettle();
    expect(find.byType(HomeReaderPage), findsOneWidget,
        reason: 'KeyB (homeTabBooks) must switch back to the books tab');
    expect(find.byType(HomeDictionaryPage), findsNothing);
  });
}
