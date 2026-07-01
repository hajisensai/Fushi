import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/pages/implementations/shortcut_settings_page.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';

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

  HibikiShortcutRegistry buildRegistry(TargetPlatform platform) =>
      HibikiShortcutRegistry()..loadDefaults(platform);

  Future<void> pumpDialog(
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

  testWidgets(
      'desktop: capturing the middle button records a MouseBinding(1) chip',
      (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final HibikiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    // homeFocusSearch is in the home scope, which is not coactive with the
    // audiobook scope that ships the only default MouseBinding(1), so middle
    // click is conflict-free here.
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.homeFocusSearch,
    );

    await tester.tap(find.byKey(const Key('shortcut_add_mouse')));
    await tester.pumpAndSettle();
    expect(find.text(t.shortcut_press_mouse_button), findsOneWidget);

    await pressMouseButton(tester, kMiddleMouseButton);

    expect(find.text(t.shortcut_mouse_middle), findsOneWidget);
    expect(find.text(t.shortcut_press_mouse_button), findsNothing);

    resetPlatform();
  });

  testWidgets('desktop: the primary (left) button is not bindable',
      (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final HibikiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    await pumpDialog(
      tester,
      registry,
      action: ShortcutAction.homeFocusSearch,
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
    final HibikiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.homeFocusSearch,
    );

    await tester.tap(find.byKey(const Key('shortcut_add_mouse')));
    await tester.pumpAndSettle();
    await pressMouseButton(tester, kBackMouseButton); // DOM button 3 = back

    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    expect(
      registry.bindingsFor(ShortcutAction.homeFocusSearch).mouseBindings,
      contains(const MouseBinding(3)),
    );

    resetPlatform();
  });

  testWidgets('desktop: deleting a mouse chip removes it from the draft',
      (WidgetTester tester) async {
    usePlatform(TargetPlatform.windows);
    final HibikiShortcutRegistry registry =
        buildRegistry(TargetPlatform.windows);
    await pumpDialogHost(
      tester,
      registry,
      action: ShortcutAction.homeFocusSearch,
      initial: const ShortcutBindingSet(
        mouseBindings: <MouseBinding>[MouseBinding(2)],
      ),
    );

    expect(find.text(t.shortcut_mouse_right), findsOneWidget);
    await tester.tap(find.byIcon(Icons.close).first);
    await tester.pumpAndSettle();

    await tester.tap(find.text('OK').last);
    await tester.pumpAndSettle();

    expect(
      registry.bindingsFor(ShortcutAction.homeFocusSearch).mouseBindings,
      isEmpty,
    );

    resetPlatform();
  });

  testWidgets(
      'mobile: no mouse capture entry and inherited bindings still render',
      (WidgetTester tester) async {
    usePlatform(TargetPlatform.android);
    final HibikiShortcutRegistry registry =
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
