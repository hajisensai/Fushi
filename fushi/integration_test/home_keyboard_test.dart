import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';

import 'helpers/library_fixture.dart' show showBooksTab;
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
    // app.main() 会把 FlutterError.onError 换成 ErrorLogService 的处理器；
    // flutter_test binding 一旦发现 onError 被换而 _pendingExceptionDetails 为空，
    // 任何 TestFailure 都会变成一条不含真实原因的
    // `'_pendingExceptionDetails != null'` 断言（正是本测试此前在 macOS 上
    // 只报 [E] 无细节的机制）。与其它 itest 同范式：捕获并在 finally 恢复。
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      debugPrint('[home-kbd] FlutterError: ${details.exceptionAsString()}');
    };

    ShortcutBindingSet? origDict;
    ShortcutBindingSet? origBooks;
    AppModel? boundModel;
    try {
      app.main();

      final bool homeReady = await waitForHome(tester);
      expect(homeReady, isTrue, reason: 'Home must render');
      await tester.pump(const Duration(seconds: 1));

      // 冷启动落在 dashboard tab（HomeTab.home），书架是惰性构建的保活 tab——
      // 本测试写于 dashboard tab 引入之前，「Books tab (0) is the default」premise
      // 已过时。用确定性钩子先切到书架，再验证快捷键在两个 tab 间切换。
      await showBooksTab(tester);
      expect(find.byType(HomeReaderPage), findsOneWidget,
          reason: 'books tab must be selected before driving shortcuts');
      expect(find.byType(HomeDictionaryPage), findsNothing);

      // Bind two free keys at runtime (android home defaults are empty).
      final AppModel appModel = appModelOf(tester);
      boundModel = appModel;
      origDict =
          appModel.shortcutRegistry.bindingsFor(ShortcutAction.homeTabDict);
      origBooks =
          appModel.shortcutRegistry.bindingsFor(ShortcutAction.homeTabBooks);
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
          reason: 'KeyJ (homeTabDict) must switch to the dictionary tab');
      expect(find.byType(HomeReaderPage), findsNothing);

      // KeyB → back to the books tab.
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.pumpAndSettle();
      expect(find.byType(HomeReaderPage), findsOneWidget,
          reason: 'KeyB (homeTabBooks) must switch back to the books tab');
      expect(find.byType(HomeDictionaryPage), findsNothing);
    } finally {
      // 还原运行时绑定，不让 J/B 泄漏进共享测试 DB / 后续测试进程状态。
      if (boundModel != null && origDict != null && origBooks != null) {
        boundModel.shortcutRegistry
            .updateBinding(ShortcutAction.homeTabDict, origDict);
        boundModel.shortcutRegistry
            .updateBinding(ShortcutAction.homeTabBooks, origBooks);
      }
      FlutterError.onError = oldHandler;
    }
  });
}
