import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/shortcut_settings_page.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';

/// 查词弹窗「上/下一个词条」的**改键入口**：在快捷键设置的绑定对话框里录一条
/// 「修饰键 + 滚轮方向」。与鼠标按钮捕获同形（shortcut_mouse_binding_capture_test），
/// 差别只在事件是 PointerSignal 而非 PointerDown。
///
/// 同时钉住两条设计约束：
///   * 裸滚轮不可绑定（弹窗里裸滚轮永远滚内容，绑了必然是死绑定）；
///   * dictionaryPopup scope 只渲染滚轮章节，不给键盘/手柄入口（同理由）。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  void usePlatform(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
  }

  void resetPlatform() {
    debugDefaultTargetPlatformOverride = null;
  }

  HibikiShortcutRegistry buildRegistry(TargetPlatform platform) =>
      HibikiShortcutRegistry()..loadDefaults(platform);

  Future<void> pumpDialogHost(
    WidgetTester tester,
    HibikiShortcutRegistry registry, {
    required ShortcutAction action,
    ShortcutBindingSet initial = const ShortcutBindingSet(),
  }) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () async {
                  final ShortcutBindingEditResult? result =
                      await showAppDialog<ShortcutBindingEditResult>(
                    context: context,
                    builder: (BuildContext ctx) => ShortcutBindingEditDialog(
                      action: action,
                      registry: registry,
                      initial: initial,
                    ),
                  );
                  if (result == null) return;
                  registry.updateBindingWithReassignments(
                    action,
                    result.bindings,
                    removeKeyboardConflicts: result.keyboardReassignments,
                    removeGamepadConflicts: result.gamepadReassignments,
                    removeMouseConflicts: result.mouseReassignments,
                    removeWheelConflicts: result.wheelReassignments,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// 在滚轮捕获区上滚一格。[modifier] 非空时按住该修饰键再滚（滚完抬起）。
  Future<void> scrollCaptureRegion(
    WidgetTester tester, {
    required double dy,
    LogicalKeyboardKey? modifier,
  }) async {
    final Offset center = tester.getCenter(
      find.byKey(const Key('shortcut_wheel_capture_region')),
    );
    if (modifier != null) {
      await tester.sendKeyDownEvent(modifier);
    }
    final TestPointer pointer = TestPointer(1, PointerDeviceKind.mouse);
    pointer.hover(center);
    await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
    await tester.pumpAndSettle();
    if (modifier != null) {
      await tester.sendKeyUpEvent(modifier);
    }
  }

  testWidgets('Alt+滚轮下被录成 Alt+WheelDown 并写穿注册表', (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final HibikiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    // 先清空默认，避免录同一条时命中「已绑定到本动作」的重复分支。
    registry.updateBinding(
        ShortcutAction.popupNextEntry, const ShortcutBindingSet());
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.popupNextEntry,
    );

    await tester.tap(find.byKey(const Key('shortcut_add_wheel')));
    await tester.pumpAndSettle();
    expect(find.text(t.shortcut_press_wheel), findsOneWidget);

    await scrollCaptureRegion(tester,
        dy: 120, modifier: LogicalKeyboardKey.altLeft);

    // 捕获结束 + chip 出现（"Alt+Wheel down"）。
    expect(find.text(t.shortcut_press_wheel), findsNothing);
    expect(find.textContaining(t.shortcut_wheel_down), findsOneWidget);

    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    expect(
      registry.bindingsFor(ShortcutAction.popupNextEntry).wheelBindings,
      contains(const WheelBinding(WheelDirection.down,
          modifiers: <ModifierKey>{ModifierKey.alt})),
    );

    resetPlatform();
  });

  testWidgets('裸滚轮不记录绑定，只提示需要修饰键（捕获保持开启）', (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final HibikiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    registry.updateBinding(
        ShortcutAction.popupNextEntry, const ShortcutBindingSet());
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.popupNextEntry,
    );

    await tester.tap(find.byKey(const Key('shortcut_add_wheel')));
    await tester.pumpAndSettle();
    await scrollCaptureRegion(tester, dy: -120);

    expect(find.text(t.shortcut_wheel_needs_modifier), findsOneWidget);
    expect(find.text(t.shortcut_press_wheel), findsOneWidget);

    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    expect(
      registry.bindingsFor(ShortcutAction.popupNextEntry).wheelBindings,
      isEmpty,
    );

    resetPlatform();
  });

  testWidgets('冲突：Alt+滚轮上已属「上一个词条」，重分配后从旧动作摘掉', (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final HibikiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.popupNextEntry,
      initial: registry.bindingsFor(ShortcutAction.popupNextEntry),
    );

    await tester.tap(find.byKey(const Key('shortcut_add_wheel')));
    await tester.pumpAndSettle();
    await scrollCaptureRegion(tester,
        dy: -120, modifier: LogicalKeyboardKey.altLeft);

    // 冲突确认对话框 → 确认重分配。
    expect(
      find.text(t.shortcut_conflict(s: t.shortcut_action_popup_prev_entry)),
      findsWidgets,
    );
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();
    // 编辑对话框自身的 OK（写穿）。
    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    const WheelBinding altUp = WheelBinding(WheelDirection.up,
        modifiers: <ModifierKey>{ModifierKey.alt});
    expect(registry.bindingsFor(ShortcutAction.popupNextEntry).wheelBindings,
        contains(altUp));
    expect(registry.bindingsFor(ShortcutAction.popupPrevEntry).wheelBindings,
        isNot(contains(altUp)));

    resetPlatform();
  });

  testWidgets('弹窗 scope 给滚轮 + 键盘入口，不给手柄/鼠标入口（不造死绑定）',
      (WidgetTester tester) async {
    // 契约变更（制卡快捷键）：本 scope 早先只开滚轮。加入 popupMineEntry（= 点弹窗里的
    // 「＋」，默认 Ctrl+Enter）后键盘通道有了真实消费者，故键盘入口出现。
    //
    // 关键点是「不造死绑定」这个约束本身没有松动，只是满足方式变了：通道是按 **scope**
    // 开的，所以开键盘就等于给本 scope 每个动作都开。为此 popup_settings_injection 的
    // 键盘绑定表覆盖三个动作（mine/next/prev）、popup.js 统一分派——词条导航同样能绑键盘
    // 并真的生效，而不是渲染出一个按了没反应的入口。手柄/鼠标仍无解析入口，保持不给。
    usePlatform(TargetPlatform.windows);
    final HibikiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.popupNextEntry,
    );

    expect(find.byKey(const Key('shortcut_add_wheel')), findsOneWidget);
    expect(find.text(t.shortcut_keyboard), findsWidgets);
    expect(find.text(t.shortcut_gamepad), findsNothing);
    expect(find.byKey(const Key('shortcut_add_mouse')), findsNothing);

    resetPlatform();
  });

  testWidgets('页面 scope 不因新通道而多出滚轮入口（既有对话框不变）', (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final HibikiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.homeFocusSearch,
    );

    expect(find.text(t.shortcut_keyboard), findsWidgets);
    expect(find.byKey(const Key('shortcut_add_wheel')), findsNothing);

    resetPlatform();
  });
}
