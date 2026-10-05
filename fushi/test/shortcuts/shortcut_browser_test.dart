import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/shortcut_settings_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_defaults.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';

/// 快捷键设置页 2026-10 单页重设计的行为测试：直接挂 [ShortcutBindingsBrowser]
/// （页面 state 绑着 live AppModel，浏览器只吃注册表与回调）。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  const InputBinding ctrlF = InputBinding(
    key: LogicalKeyboardKey.keyF,
    modifiers: <ModifierKey>{ModifierKey.ctrl},
  );

  Future<int Function()> pumpBrowser(
    WidgetTester tester,
    FushiShortcutRegistry registry, {
    Size size = const Size(1600, 900),
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.reset);
    int saves = 0;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiFallbackTheme(Brightness.light).copyWith(
            platform: TargetPlatform.windows,
          ),
          home: Scaffold(
            body: ShortcutBindingsBrowser(
              registry: registry,
              scopes: ShortcutScope.values,
              platform: TargetPlatform.windows,
              onChanged: () async => saves++,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return () => saves;
  }

  FushiShortcutRegistry buildRegistry() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  void setKeyboard(
    FushiShortcutRegistry registry,
    ShortcutAction action,
    List<InputBinding> keys,
  ) {
    registry.updateBinding(
      action,
      registry.bindingsFor(action).copyWith(keyboardBindings: keys),
    );
  }

  Finder row(ShortcutAction action) =>
      find.byKey(ValueKey<String>('shortcut-row-${action.name}'));

  Future<void> selectDomain(WidgetTester tester, ShortcutScope scope) async {
    await tester
        .tap(find.byKey(ValueKey<String>('shortcut-nav-${scope.name}')));
    await tester.pumpAndSettle();
  }

  Future<void> startRecording(
      WidgetTester tester, ShortcutAction action) async {
    await tester.tap(
      find.descendant(of: row(action), matching: find.text(action.label)),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets('wide layout shows the domain rail, narrow shows chips',
      (WidgetTester tester) async {
    await pumpBrowser(tester, buildRegistry());
    expect(find.byKey(const ValueKey<String>('shortcut-browser-wide')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('shortcut-domain-nav')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('shortcut-domain-chips')),
        findsNothing);

    await pumpBrowser(tester, buildRegistry(), size: const Size(420, 900));
    expect(find.byKey(const ValueKey<String>('shortcut-browser-narrow')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('shortcut-domain-nav')),
        findsNothing);
    expect(find.byKey(const ValueKey<String>('shortcut-domain-chips')),
        findsOneWidget);
  });

  testWidgets('search filters rows by action name',
      (WidgetTester tester) async {
    await pumpBrowser(tester, buildRegistry());
    await tester.enterText(
      find.byKey(const Key('shortcut_search_field')),
      ShortcutAction.videoScreenshot.label,
    );
    await tester.pumpAndSettle();
    expect(row(ShortcutAction.videoScreenshot), findsOneWidget);
    expect(row(ShortcutAction.homeFocusSearch), findsNothing);
    expect(row(ShortcutAction.videoTogglePlayPause), findsNothing);
  });

  testWidgets('pressing a combo in key lookup lists what it is bound to',
      (WidgetTester tester) async {
    final FushiShortcutRegistry registry = buildRegistry();
    setKeyboard(
        registry, ShortcutAction.homeFocusSearch, <InputBinding>[ctrlF]);
    setKeyboard(
      registry,
      ShortcutAction.readerOpenNavigation,
      <InputBinding>[ctrlF],
    );
    await pumpBrowser(tester, registry);

    await tester.tap(find.byKey(const Key('shortcut_key_search_button')));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('shortcut-key-search-capture')),
      findsOneWidget,
    );
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('shortcut-key-filter')),
        findsOneWidget);
    expect(row(ShortcutAction.homeFocusSearch), findsOneWidget);
    expect(row(ShortcutAction.readerOpenNavigation), findsOneWidget);
    expect(row(ShortcutAction.videoTogglePlayPause), findsNothing);
  });

  testWidgets('inline recording replaces the binding and saves immediately',
      (WidgetTester tester) async {
    final FushiShortcutRegistry registry = buildRegistry();
    setKeyboard(registry, ShortcutAction.videoScreenshot, const <InputBinding>[
      InputBinding(key: LogicalKeyboardKey.keyW),
    ]);
    final int Function() saves = await pumpBrowser(tester, registry);
    await selectDomain(tester, ShortcutScope.video);

    await startRecording(tester, ShortcutAction.videoScreenshot);
    expect(find.byKey(const ValueKey<String>('shortcut-recorder')),
        findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f12);
    await tester.pumpAndSettle();

    expect(
      registry.bindingsFor(ShortcutAction.videoScreenshot).keyboardBindings,
      const <InputBinding>[InputBinding(key: LogicalKeyboardKey.f12)],
    );
    expect(saves(), 1);
  });

  testWidgets('bare Esc cancels inline recording without writing',
      (WidgetTester tester) async {
    final FushiShortcutRegistry registry = buildRegistry();
    final List<InputBinding> before =
        registry.bindingsFor(ShortcutAction.videoScreenshot).keyboardBindings;
    final int Function() saves = await pumpBrowser(tester, registry);
    await selectDomain(tester, ShortcutScope.video);

    await startRecording(tester, ShortcutAction.videoScreenshot);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(
        find.byKey(const ValueKey<String>('shortcut-recorder')), findsNothing);
    expect(
      registry.bindingsFor(ShortcutAction.videoScreenshot).keyboardBindings,
      before,
    );
    expect(saves(), 0);
  });

  testWidgets('a conflicting combo shows the inline strip; swap trades keys',
      (WidgetTester tester) async {
    final FushiShortcutRegistry registry = buildRegistry();
    const InputBinding q = InputBinding(key: LogicalKeyboardKey.keyQ);
    const InputBinding w = InputBinding(key: LogicalKeyboardKey.keyW);
    // 同一 co-active 组（video）里，Q 在「播放 / 暂停」上，截图当前是 W。
    for (final ShortcutAction action
        in ShortcutAction.actionsForScope(ShortcutScope.video)) {
      setKeyboard(
        registry,
        action,
        registry
            .bindingsFor(action)
            .keyboardBindings
            .where((InputBinding b) => b != q && b != w)
            .toList(),
      );
    }
    setKeyboard(
        registry, ShortcutAction.videoTogglePlayPause, const <InputBinding>[q]);
    setKeyboard(
        registry, ShortcutAction.videoScreenshot, const <InputBinding>[w]);
    await pumpBrowser(tester, registry);
    await selectDomain(tester, ShortcutScope.video);

    await startRecording(tester, ShortcutAction.videoScreenshot);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyQ);
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey<String>('shortcut-conflict-strip')),
        findsOneWidget);
    expect(
      find.text(
          t.shortcut_conflict(s: ShortcutAction.videoTogglePlayPause.label)),
      findsOneWidget,
    );
    // 同 scope 撞键没有「都保留」（枚举序靠后的永远解析不到）。
    expect(find.byKey(const Key('shortcut_conflict_keep_both')), findsNothing);

    await tester.tap(find.byKey(const Key('shortcut_conflict_swap')));
    await tester.pumpAndSettle();

    expect(
      registry.bindingsFor(ShortcutAction.videoScreenshot).keyboardBindings,
      const <InputBinding>[q],
    );
    expect(
      registry
          .bindingsFor(ShortcutAction.videoTogglePlayPause)
          .keyboardBindings,
      const <InputBinding>[w],
    );
  });

  testWidgets('a customised row shows a per-action restore default',
      (WidgetTester tester) async {
    final FushiShortcutRegistry registry = buildRegistry();
    setKeyboard(registry, ShortcutAction.videoScreenshot, const <InputBinding>[
      InputBinding(key: LogicalKeyboardKey.f11),
    ]);
    final int Function() saves = await pumpBrowser(tester, registry);
    await selectDomain(tester, ShortcutScope.video);

    final Finder reset = find.byKey(
      ValueKey<String>('shortcut-reset-${ShortcutAction.videoScreenshot.name}'),
    );
    expect(reset, findsOneWidget);
    await tester.tap(reset);
    await tester.pumpAndSettle();

    final ShortcutBindingSet defaults = ShortcutDefaults.forPlatform(
            TargetPlatform.windows)[ShortcutAction.videoScreenshot] ??
        const ShortcutBindingSet();
    expect(
      shortcutBindingSetsEquivalent(
        registry.bindingsFor(ShortcutAction.videoScreenshot),
        defaults,
      ),
      isTrue,
    );
    expect(saves(), 1);
    expect(reset, findsNothing);
  });
}
