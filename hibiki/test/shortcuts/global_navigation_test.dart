import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/shortcuts/gamepad_service.dart';
import 'package:hibiki/src/shortcuts/global_navigation.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart';

void main() {
  KeyDownEvent keyDown(
    LogicalKeyboardKey key,
    ui.KeyEventDeviceType deviceType,
  ) =>
      KeyDownEvent(
        physicalKey: const PhysicalKeyboardKey(0),
        logicalKey: key,
        timeStamp: Duration.zero,
        deviceType: deviceType,
      );

  testWidgets('gameButtonB pops the top route', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('home')),
      builder: (context, child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    ));
    navKey.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('second')),
    ));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('gameButtonB on root route does not crash',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: const Scaffold(body: Text('home')),
      builder: (context, child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    ));
    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonB);
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  // Regression for "管理音频来源里按方向键上下动不了": a focused single-line text
  // field used to trap up/down arrows (the framework's text-editing shortcuts
  // consume them as no-op caret moves), so focus could never leave the field for
  // the rows above or the buttons below. The global wrapper now lets up/down
  // escape a single-line field while left/right still drive the caret.
  //
  // Layout stand-in for the dialog: [box above] / [single-line field] / [box
  // below], so an escape has a geometric target in each vertical direction.
  Future<void> pumpFieldBetweenButtons(
    WidgetTester tester, {
    required GlobalKey<NavigatorState> navKey,
    required FocusNode above,
    required FocusNode below,
    required TextEditingController controller,
    int? maxLines = 1,
  }) async {
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: Scaffold(
        body: Column(
          children: <Widget>[
            OutlinedButton(
                focusNode: above, onPressed: () {}, child: const Text('above')),
            TextField(controller: controller, maxLines: maxLines),
            OutlinedButton(
                focusNode: below, onPressed: () {}, child: const Text('below')),
          ],
        ),
      ),
      builder: (BuildContext context, Widget? child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    ));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focusedEditableText(), isNotNull,
        reason: 'the text field must hold focus for this scenario');
  }

  testWidgets(
      'arrow-up escapes a focused single-line text field upward (BUG-030 — the '
      'field no longer traps vertical arrows)', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode above = FocusNode(debugLabel: 'above');
    final FocusNode below = FocusNode(debugLabel: 'below');
    final TextEditingController controller = TextEditingController();
    addTearDown(above.dispose);
    addTearDown(below.dispose);
    addTearDown(controller.dispose);

    await pumpFieldBetweenButtons(tester,
        navKey: navKey, above: above, below: below, controller: controller);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(focusedEditableText(), isNull,
        reason: 'focus must leave the field — it is no longer trapped');
    expect(FocusManager.instance.primaryFocus, above,
        reason: 'arrow-up must move focus to the control above the field');
  });

  testWidgets(
      'arrow-down escapes a focused single-line text field downward (BUG-030)',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode above = FocusNode(debugLabel: 'above');
    final FocusNode below = FocusNode(debugLabel: 'below');
    final TextEditingController controller = TextEditingController();
    addTearDown(above.dispose);
    addTearDown(below.dispose);
    addTearDown(controller.dispose);

    await pumpFieldBetweenButtons(tester,
        navKey: navKey, above: above, below: below, controller: controller);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(focusedEditableText(), isNull,
        reason: 'focus must leave the field — it is no longer trapped');
    expect(FocusManager.instance.primaryFocus, below,
        reason: 'arrow-down must move focus to the control below the field');
  });

  testWidgets(
      'left/right stay with the caret in a focused single-line field '
      '(BUG-030 — horizontal arrows are not hijacked for focus nav)',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode above = FocusNode(debugLabel: 'above');
    final FocusNode below = FocusNode(debugLabel: 'below');
    final TextEditingController controller = TextEditingController();
    addTearDown(above.dispose);
    addTearDown(below.dispose);
    addTearDown(controller.dispose);

    await pumpFieldBetweenButtons(tester,
        navKey: navKey, above: above, below: below, controller: controller);
    final FocusNode? field = FocusManager.instance.primaryFocus;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, field,
        reason: 'left must drive the caret, not move focus');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, field,
        reason: 'right must drive the caret, not move focus');
  });

  testWidgets(
      'up/down stay with the caret in a focused MULTI-LINE field (BUG-030 — '
      'line navigation is preserved)', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FocusNode above = FocusNode(debugLabel: 'above');
    final FocusNode below = FocusNode(debugLabel: 'below');
    final TextEditingController controller =
        TextEditingController(text: 'line1\nline2');
    addTearDown(above.dispose);
    addTearDown(below.dispose);
    addTearDown(controller.dispose);

    await pumpFieldBetweenButtons(tester,
        navKey: navKey,
        above: above,
        below: below,
        controller: controller,
        maxLines: null); // unbounded = multi-line
    final FocusNode? field = FocusManager.instance.primaryFocus;

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, field,
        reason: 'down must move the caret between lines in a multi-line field, '
            'not steal focus');
  });

  testWidgets('native gameButton keys dispatch GamepadButtonIntent',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    GamepadButton? received;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: Scaffold(
        body: Actions(
          actions: <Type, Action<Intent>>{
            GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
              onInvoke: (GamepadButtonIntent intent) {
                received = intent.button;
                return true;
              },
            ),
          },
          child: const Focus(
            autofocus: true,
            child: Text('target'),
          ),
        ),
      ),
      builder: (context, child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    ));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.gameButtonX);
    await tester.pump();

    expect(received, GamepadButton.x);
  });

  testWidgets('keyboard arrows are not dispatched as native D-pad',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    GamepadButton? received;
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: Scaffold(
        body: Actions(
          actions: <Type, Action<Intent>>{
            GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
              onInvoke: (GamepadButtonIntent intent) {
                received = intent.button;
                return true;
              },
            ),
          },
          child: const Focus(
            autofocus: true,
            child: Text('target'),
          ),
        ),
      ),
      builder: (context, child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    ));
    await tester.pump();

    final KeyEventResult result = dispatchNativeGamepadButtonIntent(
      keyDown(LogicalKeyboardKey.arrowRight, ui.KeyEventDeviceType.keyboard),
    );

    expect(result, KeyEventResult.ignored);
    expect(received, isNull);
  });

  testWidgets('directionalPad and gamepad arrows dispatch native D-pad',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final List<GamepadButton> received = <GamepadButton>[];
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navKey,
      home: Scaffold(
        body: Actions(
          actions: <Type, Action<Intent>>{
            GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
              onInvoke: (GamepadButtonIntent intent) {
                received.add(intent.button);
                return true;
              },
            ),
          },
          child: const Focus(
            autofocus: true,
            child: Text('target'),
          ),
        ),
      ),
      builder: (context, child) =>
          wrapWithGlobalNavigation(navigatorKey: navKey, child: child!),
    ));
    await tester.pump();

    expect(
      dispatchNativeGamepadButtonIntent(
        keyDown(
          LogicalKeyboardKey.arrowLeft,
          ui.KeyEventDeviceType.directionalPad,
        ),
      ),
      KeyEventResult.handled,
    );
    expect(
      dispatchNativeGamepadButtonIntent(
        keyDown(LogicalKeyboardKey.arrowRight, ui.KeyEventDeviceType.gamepad),
      ),
      KeyEventResult.handled,
    );

    expect(received, <GamepadButton>[
      GamepadButton.dpadLeft,
      GamepadButton.dpadRight,
    ]);
  });
}
