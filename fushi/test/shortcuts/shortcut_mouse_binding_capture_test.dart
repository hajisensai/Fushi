import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/pages/implementations/shortcut_settings_page.dart';
import 'package:fushi/src/shortcuts/input_binding.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

// TODO-1088: capturing and binding a mouse button in the shortcut assignment
// dialog. Exercises the real ShortcutBindingEditDialog capture region and the
// write-through path (updateBindingWithReassignments) via a host button, plus
// the mobile degradation (no capture entry, no crash).
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  // Sets the platform override for a testWidgets body. The caller MUST call
  // resetPlatform() before the body returns: testWidgets checks the foundation
  // debug vars are unset BEFORE addTearDown runs, so an addTearDown reset is too
  // late (throws "a foundation debug variable was changed by the test").
  void usePlatform(TargetPlatform platform) {
    debugDefaultTargetPlatformOverride = platform;
  }

  void resetPlatform() {
    debugDefaultTargetPlatformOverride = null;
  }

  FushiShortcutRegistry buildRegistry(TargetPlatform platform) =>
      FushiShortcutRegistry()..loadDefaults(platform);

  Future<void> pumpDialog(
    WidgetTester tester,
    FushiShortcutRegistry registry, {
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
            body: Center(
              child: ShortcutBindingEditDialog(
                action: action,
                registry: registry,
                initial: initial,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> pumpDialogHost(
    WidgetTester tester,
    FushiShortcutRegistry registry, {
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

  Future<void> pressMouseButton(WidgetTester tester, int buttons) async {
    final Offset center = tester.getCenter(
      find.byKey(const Key('shortcut_mouse_capture_region')),
    );
    final TestGesture gesture = await tester.startGesture(
      center,
      buttons: buttons,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
  }

  // 捕获用例统一挂在 readerDismissDict 上：mouse 通道现在只对 reader / audiobook
  // 开放（它们是 WebView 宿主，`resolveMouse` 真有解析入口），而 readerDismissDict
  // 正是 reader 侧那个真消费者（webview.part.dart 的 onPointerSeek）。曾用的
  // homeFocusSearch 所在的 home scope 已不再开放 mouse 通道（无任何 Flutter 侧
  // 鼠标派发管线），捕获入口不再渲染。
  //
  // 按键选右键(2)/后退键(3)：reader 与 audiobook 同属一个 co-active 组，而
  // audiobookSeekToClickedSentence 默认占着中键(1)，中键会走冲突改绑流程而非直接
  // 落 chip。
  testWidgets(
      'desktop: capturing the right button records a MouseBinding(2) chip',
      (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final FushiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.readerDismissDict,
    );

    await tester.tap(find.byKey(const Key('shortcut_add_mouse')));
    await tester.pumpAndSettle();
    expect(find.text(t.shortcut_press_mouse_button), findsOneWidget);

    await pressMouseButton(tester, kSecondaryMouseButton);

    expect(find.text(t.shortcut_mouse_right), findsOneWidget);
    expect(find.text(t.shortcut_press_mouse_button), findsNothing);

    resetPlatform();
  });

  testWidgets('desktop: the primary (left) button is not bindable',
      (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final FushiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.readerDismissDict,
    );

    await tester.tap(find.byKey(const Key('shortcut_add_mouse')));
    await tester.pumpAndSettle();

    await pressMouseButton(tester, kPrimaryMouseButton);

    expect(find.text(t.shortcut_press_mouse_button), findsOneWidget);
    expect(find.text(t.shortcut_mouse_left), findsNothing);

    resetPlatform();
  });

  testWidgets('desktop: captured mouse binding is written through the registry',
      (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final FushiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.readerDismissDict,
    );

    await tester.tap(find.byKey(const Key('shortcut_add_mouse')));
    await tester.pumpAndSettle();
    await pressMouseButton(tester, kBackMouseButton); // DOM button 3 = back

    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    expect(
      registry.bindingsFor(ShortcutAction.readerDismissDict).mouseBindings,
      contains(const MouseBinding(3)),
    );

    resetPlatform();
  });

  // 通道没开的 scope 上，历史快照里的鼠标绑定**不隐身、仍可删**（Never break
  // userspace）：捕获入口不出现，但老用户当年配下的绑定仍要能看见并删掉——否则那条
  // 永不触发的死绑定就永远删不掉了。
  //
  // 锚点几经辗转：home → globalExternalLookup → dpadUp。前两个都是因为**后来真的接上
  // 了鼠标解析入口**而被迫让位（home / global / universal / manga 是 BUG-1995 那轮；
  // globalExternal 是 TODO-1066 那轮——app 外查词的鼠标侧键触发走 native RawInput +
  // RIDEV_INPUTSINK，通道随之打开）。
  //
  // `gamepad` scope（dpad 四向）是目前唯一**按构造**开不了鼠标的那个：它的唯一消费者
  // 是 `GamepadService._dispatchButton` 按 `GamepadButton` 解析，键盘/鼠标绑定在那里
  // 没有也不可能有读取方（见 ShortcutScope.channels 的 gamepad case）。
  testWidgets('desktop: 通道未开的 scope 仍显示并可删除历史鼠标绑定（但没有捕获入口）',
      (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final FushiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    // 前提自检：取样的 scope 必须真的没开 mouse，否则本用例测的是另一件事（假绿）。
    expect(
      ShortcutAction.dpadUp.scope.channels,
      isNot(contains(ShortcutChannel.mouse)),
    );
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.dpadUp,
      initial: const ShortcutBindingSet(
        mouseBindings: <MouseBinding>[MouseBinding(2)],
      ),
    );

    expect(find.text(t.shortcut_mouse_right), findsOneWidget);
    expect(find.byKey(const Key('shortcut_add_mouse')), findsNothing);
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    expect(
      registry.bindingsFor(ShortcutAction.dpadUp).mouseBindings,
      isEmpty,
    );

    resetPlatform();
  });

  testWidgets(
      'mobile: no mouse capture entry and inherited bindings still render',
      (WidgetTester tester) async {
    usePlatform(TargetPlatform.android);
    final FushiShortcutRegistry registry =
        buildRegistry(TargetPlatform.android);
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.audiobookSeekToClickedSentence,
      initial: const ShortcutBindingSet(
        mouseBindings: <MouseBinding>[MouseBinding(1)],
      ),
    );

    expect(find.text(t.shortcut_mouse_middle), findsOneWidget);
    expect(find.byKey(const Key('shortcut_add_mouse')), findsNothing);
    expect(
        find.byKey(const Key('shortcut_mouse_capture_region')), findsNothing);

    resetPlatform();
  });
}
