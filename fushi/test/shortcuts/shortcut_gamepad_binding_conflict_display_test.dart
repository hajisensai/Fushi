import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/shortcut_settings_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_labels.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/shortcuts/visual/gamepad_glyphs.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// BUG-3619 / BUG-3621（反馈：Android 上 Xbox LB 的键位设置）。
///
/// BUG-3619：Android 的手柄按键（`gameButton*`、手柄来源的十字键）是 KeyEvent，
/// 此前在**键盘**分段行内录制 / 编辑对话框的键盘捕获区里被原样存成键盘绑定：
/// 冲突检测只扫键盘通道（看不到别的动作上的手柄 LB）→ 不提示重复；手柄键位图也
/// 看不到它，运行时却照样被 LB 触发。现在这类按键一律改投手柄通道。
///
/// BUG-3621：列表视图当前设备没有绑定、别的设备有时，行上只写「点按分配」，等于
/// 说这个动作什么都没绑。现在把别的设备上的绑定带设备图标只读列出。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  FushiShortcutRegistry buildRegistry() =>
      FushiShortcutRegistry()..loadDefaults(TargetPlatform.windows);

  /// 把 [button] 从 [scope] 冲突检测能看到的所有动作上摘掉，让它成为空闲按钮。
  void freeGamepadButton(
    FushiShortcutRegistry registry,
    ShortcutScope scope,
    GamepadButton button,
  ) {
    for (;;) {
      final ShortcutAction? owner = registry.hasGamepadConflict(
        scope,
        GamepadBinding(button),
        exclude: null,
      );
      if (owner == null) return;
      final ShortcutBindingSet set = registry.bindingsFor(owner);
      registry.updateBinding(
        owner,
        set.copyWith(
          gamepadBindings: set.gamepadBindings
              .where((GamepadBinding b) => b.button != button)
              .toList(),
        ),
      );
    }
  }

  Future<void> pumpBrowser(
    WidgetTester tester,
    FushiShortcutRegistry registry,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 900);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          theme: buildFushiFallbackTheme(
            Brightness.light,
          ).copyWith(platform: TargetPlatform.windows),
          home: Scaffold(
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
      find.byKey(ValueKey<String>('shortcut-nav-${ShortcutScope.video.name}')),
    );
    await tester.pumpAndSettle();
  }

  Finder row(ShortcutAction action) =>
      find.byKey(ValueKey<String>('shortcut-row-${action.name}'));

  Future<void> startRecording(
    WidgetTester tester,
    ShortcutAction action,
  ) async {
    await Scrollable.ensureVisible(tester.element(row(action)), alignment: 0.5);
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(of: row(action), matching: find.text(action.label)),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('shortcut-recorder')),
      findsOneWidget,
    );
  }

  /// 直接把带 [deviceType] 的 KeyDown 交给当前主焦点（录制区）的 onKeyEvent——
  /// `tester.sendKeyEvent` 造不出非键盘来源的事件，而十字键的手柄 / 键盘之分只在
  /// deviceType 上。
  void sendDeviceKeyDown(
    LogicalKeyboardKey key,
    ui.KeyEventDeviceType deviceType,
  ) {
    final FocusNode node = FocusManager.instance.primaryFocus!;
    node.onKeyEvent!(
      node,
      KeyDownEvent(
        physicalKey: const PhysicalKeyboardKey(0),
        logicalKey: key,
        timeStamp: Duration.zero,
        deviceType: deviceType,
      ),
    );
  }

  group('BUG-3619 inline recording on the keyboard tab', () {
    testWidgets(
      'LB owned by another action: surfaces the gamepad conflict instead of '
      'silently storing a keyboard "Game Button Left 1"',
      (WidgetTester tester) async {
        final FushiShortcutRegistry registry = buildRegistry();
        freeGamepadButton(registry, ShortcutScope.video, GamepadButton.lb);
        registry.updateBinding(
          ShortcutAction.videoSeekBackward,
          registry
              .bindingsFor(ShortcutAction.videoSeekBackward)
              .copyWith(
                gamepadBindings: const <GamepadBinding>[
                  GamepadBinding(GamepadButton.lb),
                ],
              ),
        );
        final List<InputBinding> keyboardBefore = registry
            .bindingsFor(ShortcutAction.videoScreenshot)
            .keyboardBindings;
        await pumpBrowser(tester, registry);

        await startRecording(tester, ShortcutAction.videoScreenshot);
        await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonLeft1);
        await tester.pumpAndSettle();

        expect(
          find.byKey(const ValueKey<String>('shortcut-conflict-strip')),
          findsOneWidget,
        );
        expect(
          find.text(
            t.shortcut_conflict(s: ShortcutAction.videoSeekBackward.label),
          ),
          findsOneWidget,
        );
        expect(
          registry.bindingsFor(ShortcutAction.videoScreenshot).keyboardBindings,
          keyboardBefore,
          reason: '手柄按键不得再落进键盘通道',
        );

        // 切到手柄分段后行序变了，冲突条可能在视口外：先像用户一样滚进来。
        await Scrollable.ensureVisible(
          tester.element(find.byKey(const Key('shortcut_conflict_replace'))),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('shortcut_conflict_replace')));
        await tester.pumpAndSettle();
        expect(
          registry.bindingsFor(ShortcutAction.videoScreenshot).gamepadBindings,
          contains(const GamepadBinding(GamepadButton.lb)),
        );
        expect(
          registry
              .bindingsFor(ShortcutAction.videoSeekBackward)
              .gamepadBindings,
          isNot(contains(const GamepadBinding(GamepadButton.lb))),
        );
      },
    );

    testWidgets(
      'free LB is appended to the gamepad channel and the tab follows it',
      (WidgetTester tester) async {
        final FushiShortcutRegistry registry = buildRegistry();
        freeGamepadButton(registry, ShortcutScope.video, GamepadButton.lb);
        registry.updateBinding(
          ShortcutAction.videoScreenshot,
          registry
              .bindingsFor(ShortcutAction.videoScreenshot)
              .copyWith(
                gamepadBindings: const <GamepadBinding>[
                  GamepadBinding(GamepadButton.thumbLeft),
                ],
              ),
        );
        final List<InputBinding> keyboardBefore = registry
            .bindingsFor(ShortcutAction.videoScreenshot)
            .keyboardBindings;
        await pumpBrowser(tester, registry);

        await startRecording(tester, ShortcutAction.videoScreenshot);
        await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonLeft1);
        await tester.pumpAndSettle();

        final ShortcutBindingSet after = registry.bindingsFor(
          ShortcutAction.videoScreenshot,
        );
        expect(after.keyboardBindings, keyboardBefore);
        expect(after.gamepadBindings, const <GamepadBinding>[
          GamepadBinding(GamepadButton.thumbLeft),
          GamepadBinding(GamepadButton.lb),
        ], reason: '追加而非替换：键盘分段里看不到的已有手柄绑定不能被静默冲掉');
        final FushiAdjustableSegmented<ShortcutInputDevice> devices = tester
            .widget<FushiAdjustableSegmented<ShortcutInputDevice>>(
              find.byKey(const Key('shortcut_device_toggle')),
            );
        expect(devices.selected, ShortcutInputDevice.gamepad);
      },
    );

    testWidgets(
      'controller D-pad records a gamepad dpad binding; a keyboard arrow '
      'stays a keyboard binding',
      (WidgetTester tester) async {
        final FushiShortcutRegistry registry = buildRegistry();
        freeGamepadButton(registry, ShortcutScope.video, GamepadButton.dpadUp);
        await pumpBrowser(tester, registry);

        await startRecording(tester, ShortcutAction.videoScreenshot);
        sendDeviceKeyDown(
          LogicalKeyboardKey.arrowUp,
          ui.KeyEventDeviceType.joystick,
        );
        await tester.pumpAndSettle();
        final ShortcutBindingSet afterPad = registry.bindingsFor(
          ShortcutAction.videoScreenshot,
        );
        expect(
          afterPad.gamepadBindings,
          contains(const GamepadBinding(GamepadButton.dpadUp)),
        );
        expect(
          afterPad.keyboardBindings,
          isNot(contains(const InputBinding(key: LogicalKeyboardKey.arrowUp))),
        );
      },
    );

    testWidgets('keyboard arrow keys keep recording as keyboard bindings', (
      WidgetTester tester,
    ) async {
      final FushiShortcutRegistry registry = buildRegistry();
      const InputBinding f9 = InputBinding(key: LogicalKeyboardKey.f9);
      for (final ShortcutAction action in ShortcutAction.actionsForScope(
        ShortcutScope.video,
      )) {
        final ShortcutBindingSet set = registry.bindingsFor(action);
        registry.updateBinding(
          action,
          set.copyWith(
            keyboardBindings: set.keyboardBindings
                .where((InputBinding b) => b != f9)
                .toList(),
          ),
        );
      }
      await pumpBrowser(tester, registry);

      await startRecording(tester, ShortcutAction.videoScreenshot);
      sendDeviceKeyDown(LogicalKeyboardKey.f9, ui.KeyEventDeviceType.keyboard);
      await tester.pumpAndSettle();
      expect(
        registry.bindingsFor(ShortcutAction.videoScreenshot).keyboardBindings,
        const <InputBinding>[f9],
      );
    });
  });

  group('BUG-3619 edit dialog keyboard capture', () {
    testWidgets(
      'an Android LB press lands in the gamepad draft, not keyboard',
      (WidgetTester tester) async {
        final FushiShortcutRegistry registry = buildRegistry();
        const ShortcutAction action = ShortcutAction.readerToggleFurigana;
        freeGamepadButton(registry, action.scope, GamepadButton.lb);
        await tester.pumpWidget(
          TranslationProvider(
            child: MaterialApp(
              home: Scaffold(
                body: Center(
                  child: ShortcutBindingEditDialog(
                    action: action,
                    registry: registry,
                    initial: const ShortcutBindingSet(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.widgetWithText(TextButton, t.shortcut_keyboard));
        await tester.pumpAndSettle();
        expect(find.text(t.shortcut_press_key), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonLeft1);
        await tester.pumpAndSettle();

        expect(
          find.widgetWithText(FushiTagChip, GamepadButton.lb.label),
          findsOneWidget,
        );
        expect(
          find.widgetWithText(
            FushiTagChip,
            const InputBinding(
              key: LogicalKeyboardKey.gameButtonLeft1,
            ).displayLabel,
          ),
          findsNothing,
        );
        expect(find.text(t.shortcut_press_key), findsNothing);
      },
    );
  });

  group('BUG-3621 list rows show bindings that live on another device', () {
    testWidgets(
      'keyboard tab row with only a gamepad binding shows it instead of '
      'pretending to be unbound',
      (WidgetTester tester) async {
        final FushiShortcutRegistry registry = buildRegistry();
        registry.updateBinding(
          ShortcutAction.videoScreenshot,
          const ShortcutBindingSet(
            gamepadBindings: <GamepadBinding>[GamepadBinding(GamepadButton.lb)],
          ),
        );
        await pumpBrowser(tester, registry);
        await Scrollable.ensureVisible(
          tester.element(row(ShortcutAction.videoScreenshot)),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();

        final String lbLabel = shortcutBindingLabel(
          const GamepadBinding(GamepadButton.lb),
          GamepadBrand.xbox,
        );
        expect(
          find.descendant(
            of: row(ShortcutAction.videoScreenshot),
            matching: find.byKey(
              ValueKey<String>(
                'elsewhere-${ShortcutAction.videoScreenshot.name}-'
                '${ShortcutInputDevice.gamepad.name}-$lbLabel',
              ),
            ),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: row(ShortcutAction.videoScreenshot),
            matching: find.text(t.shortcut_tap_to_assign),
          ),
          findsOneWidget,
          reason: '整行点按仍是给当前设备（键盘）录键',
        );
      },
    );

    testWidgets('a truly unbound row still shows only the assign hint', (
      WidgetTester tester,
    ) async {
      final FushiShortcutRegistry registry = buildRegistry();
      registry.updateBinding(
        ShortcutAction.videoScreenshot,
        const ShortcutBindingSet(),
      );
      await pumpBrowser(tester, registry);
      await Scrollable.ensureVisible(
        tester.element(row(ShortcutAction.videoScreenshot)),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: row(ShortcutAction.videoScreenshot),
          matching: find.byWidgetPredicate(
            (Widget w) =>
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith('elsewhere-'),
          ),
        ),
        findsNothing,
      );
    });
  });
}
