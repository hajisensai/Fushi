import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/shortcut_settings_page.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// BUG-5189（反馈 KhJG0swJKT）：快捷键设置页行内录制时按 Esc 把整页退掉。
///
/// 按 app 的真实层级搭：根 Navigator 外包 [wrapWithGlobalNavigation]（Esc →
/// 注册表 globalBack → `maybePop`），其内是开着焦点导航的 [FushiFocusRoot]，
/// 浏览器在 push 出来的子路由里。焦点导航开着时 [FushiFocusTarget] 的鼠标
/// click-to-focus 会在录制中点一下录制条时把焦点从录制器拽回整行，Esc 就冒泡
/// 到全局返回。旧的 `shortcut_browser_test` 只挂裸 MaterialApp，测不出这条。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  const ShortcutAction action = ShortcutAction.videoScreenshot;
  Finder row() => find.byKey(ValueKey<String>('shortcut-row-${action.name}'));
  final Finder recorder = find.byKey(
    const ValueKey<String>('shortcut-recorder'),
  );

  Future<FushiShortcutRegistry> pumpSettingsRoute(WidgetTester tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiShortcutRegistry registry = FushiShortcutRegistry()
      ..loadDefaults(TargetPlatform.windows);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          theme: buildFushiFallbackTheme(
            Brightness.light,
          ).copyWith(platform: TargetPlatform.windows),
          builder: (BuildContext context, Widget? child) =>
              wrapWithGlobalNavigation(
                navigatorKey: navKey,
                registry: registry,
                child: FushiFocusRoot(child: child!),
              ),
          home: const Scaffold(body: Text('home')),
        ),
      ),
    );
    unawaited(
      navKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: ShortcutBindingsBrowser(
              registry: registry,
              scopes: ShortcutScope.values,
              platform: TargetPlatform.windows,
              onChanged: () async {},
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('shortcut-nav-video')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(tester.element(row()), alignment: 0.5);
    await tester.pumpAndSettle();
    return registry;
  }

  /// 鼠标点行开始录制，再在录制条的提示文字上点一下（用户把指针移进录制条
  /// 的自然动作）。录制条有脉冲动画，不能 pumpAndSettle。
  Future<void> startRecordingThenClickRecorder(WidgetTester tester) async {
    await tester.tap(
      find.descendant(of: row(), matching: find.text(action.label)),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump();
    expect(recorder, findsOneWidget);
    await tester.tap(
      find.text(t.shortcut_record_prompt),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // 录制期间录制器必须持有主焦点（键盘所有者）。
    expect(FocusManager.instance.primaryFocus?.debugLabel, 'shortcut-record');
  }

  testWidgets('Esc during inline recording cancels it and keeps the page', (
    WidgetTester tester,
  ) async {
    final FushiShortcutRegistry registry = await pumpSettingsRoute(tester);
    final List<InputBinding> before = registry
        .bindingsFor(action)
        .keyboardBindings;
    await startRecordingThenClickRecorder(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.byType(ShortcutBindingsBrowser), findsOneWidget);
    expect(find.text('home'), findsNothing);
    expect(recorder, findsNothing);
    expect(registry.bindingsFor(action).keyboardBindings, before);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('keys pressed while recording land in the recorder', (
    WidgetTester tester,
  ) async {
    final FushiShortcutRegistry registry = await pumpSettingsRoute(tester);
    // 先把 J 从所有动作上摘掉，保证它是空闲键：录进来就直接写入，不走冲突条。
    const InputBinding j = InputBinding(key: LogicalKeyboardKey.keyJ);
    for (final ShortcutAction a in ShortcutAction.values) {
      final List<InputBinding> keys = registry.bindingsFor(a).keyboardBindings;
      if (keys.contains(j)) {
        registry.updateBinding(
          a,
          registry
              .bindingsFor(a)
              .copyWith(
                keyboardBindings: keys
                    .where((InputBinding b) => b != j)
                    .toList(),
              ),
        );
      }
    }
    await tester.pump();
    await startRecordingThenClickRecorder(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(registry.bindingsFor(action).keyboardBindings, contains(j));
    expect(find.byType(ShortcutBindingsBrowser), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });
}
