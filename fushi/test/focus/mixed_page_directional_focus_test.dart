import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart';

/// 混排页：同一路由上既有受管目标（FushiFocusTarget），又有未登记的原生
/// Material 控件。手柄方向键必须从**真实主焦点**出发做几何移焦，而不是从
/// 陈旧的受管 activeId 或插入顺序第一个目标出发。
void main() {
  Future<void> pumpMixedPage(
    WidgetTester tester, {
    required FocusNode managedTop,
    required FocusNode managedBottom,
    required FocusNode nativeMiddle,
    required FocusNode nativeRight,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: Scaffold(
            body: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                FushiFocusTarget(
                  id: const FushiFocusId('managed-top'),
                  focusNode: managedTop,
                  child: const SizedBox(width: 100, height: 40),
                ),
                const SizedBox(height: 20),
                Row(
                  children: <Widget>[
                    TextButton(
                      focusNode: nativeMiddle,
                      onPressed: () {},
                      child: const Text('native-middle'),
                    ),
                    const SizedBox(width: 200),
                    TextButton(
                      focusNode: nativeRight,
                      onPressed: () {},
                      child: const Text('native-right'),
                    ),
                  ],
                ),
                const SizedBox(height: 20),
                FushiFocusTarget(
                  id: const FushiFocusId('managed-bottom'),
                  focusNode: managedBottom,
                  child: const SizedBox(width: 100, height: 40),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  late FocusNode managedTop;
  late FocusNode managedBottom;
  late FocusNode nativeMiddle;
  late FocusNode nativeRight;

  setUp(() {
    managedTop = FocusNode(debugLabel: 'managed-top');
    managedBottom = FocusNode(debugLabel: 'managed-bottom');
    nativeMiddle = FocusNode(debugLabel: 'native-middle');
    nativeRight = FocusNode(debugLabel: 'native-right');
  });

  tearDown(() {
    managedTop.dispose();
    managedBottom.dispose();
    nativeMiddle.dispose();
    nativeRight.dispose();
  });

  BuildContext ctx(WidgetTester tester) =>
      FocusManager.instance.primaryFocus!.context!;

  testWidgets('D-pad Down from managed target enters native row', (
    WidgetTester tester,
  ) async {
    await pumpMixedPage(
      tester,
      managedTop: managedTop,
      managedBottom: managedBottom,
      nativeMiddle: nativeMiddle,
      nativeRight: nativeRight,
    );
    managedTop.requestFocus();
    await tester.pump();

    gamepadMoveFocusInDirection(ctx(tester), TraversalDirection.down);
    await tester.pump();

    expect(
      nativeMiddle.hasPrimaryFocus,
      isTrue,
      reason: 'primary=${FocusManager.instance.primaryFocus?.debugLabel}',
    );
  });

  testWidgets(
    'D-pad Right from a native control moves to its native neighbour',
    (WidgetTester tester) async {
      await pumpMixedPage(
        tester,
        managedTop: managedTop,
        managedBottom: managedBottom,
        nativeMiddle: nativeMiddle,
        nativeRight: nativeRight,
      );
      managedTop.requestFocus();
      await tester.pump();
      nativeMiddle.requestFocus();
      await tester.pump();

      gamepadMoveFocusInDirection(ctx(tester), TraversalDirection.right);
      await tester.pump();

      expect(
        nativeRight.hasPrimaryFocus,
        isTrue,
        reason: 'primary=${FocusManager.instance.primaryFocus?.debugLabel}',
      );
    },
  );

  testWidgets(
    'D-pad Down from a native control reaches the managed target below',
    (WidgetTester tester) async {
      await pumpMixedPage(
        tester,
        managedTop: managedTop,
        managedBottom: managedBottom,
        nativeMiddle: nativeMiddle,
        nativeRight: nativeRight,
      );
      managedTop.requestFocus();
      await tester.pump();
      nativeRight.requestFocus();
      await tester.pump();

      gamepadMoveFocusInDirection(ctx(tester), TraversalDirection.down);
      await tester.pump();

      expect(
        managedBottom.hasPrimaryFocus,
        isTrue,
        reason: 'primary=${FocusManager.instance.primaryFocus?.debugLabel}',
      );
    },
  );

  testWidgets(
    'D-pad Up from a native control reaches the managed target above',
    (WidgetTester tester) async {
      await pumpMixedPage(
        tester,
        managedTop: managedTop,
        managedBottom: managedBottom,
        nativeMiddle: nativeMiddle,
        nativeRight: nativeRight,
      );
      managedBottom.requestFocus();
      await tester.pump();
      nativeMiddle.requestFocus();
      await tester.pump();

      gamepadMoveFocusInDirection(ctx(tester), TraversalDirection.up);
      await tester.pump();

      expect(
        managedTop.hasPrimaryFocus,
        isTrue,
        reason: 'primary=${FocusManager.instance.primaryFocus?.debugLabel}',
      );
    },
  );
}
