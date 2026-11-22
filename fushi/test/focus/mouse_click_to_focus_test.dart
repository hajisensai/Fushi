import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';

/// TODO-1113 P3: keyboard/gamepad focus navigation should also support the
/// mouse. On desktop, clicking a [FushiFocusTarget] carries directional-
/// navigation focus there (so subsequent arrow/gamepad traversal continues from
/// what the user clicked) WITHOUT double-activating the child, and the focus
/// ring stays lit on that press so the placed focus is visible. Hover/move do
/// not light the ring (conservative option b). Mobile/touch keep plain-tap.
void main() {
  group('FushiFocusTarget mouse click-to-focus (desktop-gated)', () {
    testWidgets(
      'a mouse click on a desktop target carries focus without double-firing',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

        final FocusNode first = FocusNode(debugLabel: 'first');
        final FocusNode second = FocusNode(debugLabel: 'second');
        addTearDown(first.dispose);
        addTearDown(second.dispose);

        int secondTaps = 0;
        late FushiFocusController controller;
        await tester.pumpWidget(
          MaterialApp(
            home: FushiFocusRoot(
              child: Builder(
                builder: (BuildContext context) {
                  controller = FushiFocusRoot.controllerOf(context);
                  return Column(
                    children: <Widget>[
                      FushiFocusTarget(
                        id: const FushiFocusId('first'),
                        focusNode: first,
                        child: const SizedBox(width: 40, height: 40),
                      ),
                      FushiFocusTarget(
                        id: const FushiFocusId('second'),
                        focusNode: second,
                        child: GestureDetector(
                          onTap: () => secondTaps++,
                          behavior: HitTestBehavior.opaque,
                          child: const SizedBox(width: 40, height: 40),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();

        first.requestFocus();
        await tester.pump();
        expect(controller.activeId, const FushiFocusId('first'));

        await tester.tap(
          find.byType(GestureDetector),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();

        expect(controller.activeId, const FushiFocusId('second'));
        expect(second.hasPrimaryFocus, isTrue);
        expect(first.hasPrimaryFocus, isFalse);
        expect(secondTaps, 1);

        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'on a mobile platform a mouse click does NOT change focus navigation',
      (WidgetTester tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;

        final FocusNode first = FocusNode(debugLabel: 'first');
        final FocusNode second = FocusNode(debugLabel: 'second');
        addTearDown(first.dispose);
        addTearDown(second.dispose);

        int secondTaps = 0;
        late FushiFocusController controller;
        await tester.pumpWidget(
          MaterialApp(
            home: FushiFocusRoot(
              child: Builder(
                builder: (BuildContext context) {
                  controller = FushiFocusRoot.controllerOf(context);
                  return Column(
                    children: <Widget>[
                      FushiFocusTarget(
                        id: const FushiFocusId('first'),
                        focusNode: first,
                        child: const SizedBox(width: 40, height: 40),
                      ),
                      FushiFocusTarget(
                        id: const FushiFocusId('second'),
                        focusNode: second,
                        child: GestureDetector(
                          onTap: () => secondTaps++,
                          behavior: HitTestBehavior.opaque,
                          child: const SizedBox(width: 40, height: 40),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
        await tester.pump();

        first.requestFocus();
        await tester.pump();
        expect(controller.activeId, const FushiFocusId('first'));

        await tester.tap(
          find.byType(GestureDetector),
          kind: PointerDeviceKind.mouse,
        );
        await tester.pump();

        expect(secondTaps, 1);
        expect(controller.activeId, const FushiFocusId('first'));
        expect(second.hasPrimaryFocus, isFalse);

        debugDefaultTargetPlatformOverride = null;
      },
    );

    // BUG-5189：焦点已在目标子孙上（快捷键设置的行内录制区）时，在目标子树里按下
    // 鼠标不能把焦点拽回外层目标——否则随后的 Esc 绕过录制器冒泡到全局返回。
    testWidgets('a mouse press inside a target keeps focus on its focused '
        'descendant', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;

      final FocusNode row = FocusNode(debugLabel: 'row');
      final FocusNode inner = FocusNode(debugLabel: 'inner');
      addTearDown(row.dispose);
      addTearDown(inner.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: FushiFocusRoot(
            child: Center(
              child: FushiFocusTarget(
                id: const FushiFocusId('row'),
                focusNode: row,
                child: SizedBox(
                  width: 200,
                  height: 80,
                  child: Column(
                    children: <Widget>[
                      const ColoredBox(
                        key: Key('row-title'),
                        color: Color(0x00000000),
                        child: SizedBox(width: 200, height: 40),
                      ),
                      Focus(
                        focusNode: inner,
                        child: const ColoredBox(
                          key: Key('inner-region'),
                          color: Color(0x00000000),
                          child: SizedBox(width: 200, height: 40),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 前置：点击确实会走到目标的 click-to-focus（焦点不在子孙上时照旧带过去），
      // 否则下面的断言会在「点击根本没命中」时空转变绿。
      await tester.tap(
        find.byKey(const Key('row-title')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(row.hasPrimaryFocus, isTrue);

      inner.requestFocus();
      await tester.pump();
      expect(inner.hasPrimaryFocus, isTrue);

      await tester.tap(
        find.byKey(const Key('inner-region')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(inner.hasPrimaryFocus, isTrue, reason: '按在聚焦子孙上');

      await tester.tap(
        find.byKey(const Key('row-title')),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();
      expect(inner.hasPrimaryFocus, isTrue, reason: '按在同一目标的别处');
      expect(row.hasPrimaryFocus, isFalse);

      debugDefaultTargetPlatformOverride = null;
    });
  });

  group('GamepadService pointer ring behaviour (TODO-1113 P3)', () {
    tearDown(() {
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.automatic;
    });

    testWidgets('with focus navigation ON, a mouse DOWN keeps the ring lit', (
      WidgetTester tester,
    ) async {
      final GamepadService service = GamepadService(
        navigatorKey: GlobalKey<NavigatorState>(),
        focusNavigationEnabled: () => true,
      );
      service.start();
      addTearDown(service.dispose);

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Center(child: Text('x'))),
        ),
      );
      await tester.pump();

      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;

      final TestGesture gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await gesture.down(tester.getCenter(find.text('x')));
      await tester.pump();

      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTraditional,
        reason: 'a click that carries focus must keep the ring visible',
      );

      await gesture.moveBy(const Offset(10, 10));
      await tester.pump();
      expect(
        FocusManager.instance.highlightStrategy,
        FocusHighlightStrategy.alwaysTouch,
        reason: 'hover/move must not carry a focus ring',
      );

      await gesture.up();
      service.dispose();
    });

    testWidgets(
      'with focus navigation OFF, a mouse DOWN drops the ring (old behaviour)',
      (WidgetTester tester) async {
        final GamepadService service = GamepadService(
          navigatorKey: GlobalKey<NavigatorState>(),
          focusNavigationEnabled: () => false,
        );
        service.start();
        addTearDown(service.dispose);

        await tester.pumpWidget(
          const MaterialApp(
            home: Scaffold(body: Center(child: Text('x'))),
          ),
        );
        await tester.pump();

        FocusManager.instance.highlightStrategy =
            FocusHighlightStrategy.alwaysTraditional;

        final TestGesture gesture = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await gesture.down(tester.getCenter(find.text('x')));
        await tester.pump();

        expect(
          FocusManager.instance.highlightStrategy,
          FocusHighlightStrategy.alwaysTouch,
          reason: 'with focus navigation off, any pointer hides the ring',
        );

        await gesture.up();
        service.dispose();
      },
    );
  });
}
