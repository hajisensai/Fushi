import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/focus/fushi_focus_target.dart';

/// 反馈 1120 #i10：桌面鼠标按在 [FushiFocusTarget] 上（右键唤菜单 / 左键点选）
/// 会把方向导航焦点带过去（TODO-1113 P3），但这次按下**不能**顺带把目标
/// 「reveal」——指针按得到它，它就在屏幕上；reveal 是给键盘 / 手柄光标用的，
/// 对鼠标只会把页面滚走（库页里还连带收起浮动顶栏）。
void main() {
  Future<({ScrollController scroll, FushiFocusController focus})> pumpList(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    late FushiFocusController focus;
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: Builder(
            builder: (BuildContext context) {
              focus = FushiFocusRoot.controllerOf(context);
              // 非懒构建（全部行都登记进焦点控制器），行要能命中指针（ColoredBox）。
              return SingleChildScrollView(
                controller: scroll,
                child: Column(
                  children: <Widget>[
                    for (int i = 0; i < 30; i++)
                      FushiFocusTarget(
                        id: FushiFocusId('row-$i'),
                        child: ColoredBox(
                          key: ValueKey<String>('row-$i'),
                          color: const Color(0xFF808080),
                          child: const SizedBox(height: 100, width: 400),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (scroll: scroll, focus: focus);
  }

  for (final int buttons in <int>[kSecondaryMouseButton, kPrimaryMouseButton]) {
    testWidgets('鼠标按下（buttons=$buttons）带焦点但不滚动列表', (WidgetTester tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        final (:ScrollController scroll, :FushiFocusController focus) =
            await pumpList(tester);
        scroll.jumpTo(150);
        await tester.pumpAndSettle();
        // row-7 占 [700, 800)，滚 150 后在视口 [550, 650)：跨下沿、部分可见。
        final Rect rect = tester.getRect(
          find.byKey(const ValueKey<String>('row-7')),
        );
        expect(rect.top, lessThan(600));
        expect(rect.bottom, greaterThan(600));

        final TestGesture gesture = await tester.startGesture(
          Offset(rect.center.dx, rect.top + 10),
          kind: PointerDeviceKind.mouse,
          buttons: buttons,
        );
        await tester.pumpAndSettle();
        expect(focus.activeId, const FushiFocusId('row-7'), reason: '焦点照样带过去');
        expect(scroll.offset, 150, reason: '鼠标按下不 reveal、不滚动');
        await gesture.up();
        await tester.pumpAndSettle();
        expect(scroll.offset, 150);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('键盘 / 手柄显式 requestById 仍然 reveal（不受本修复影响）', (
    WidgetTester tester,
  ) async {
    final (:ScrollController scroll, :FushiFocusController focus) =
        await pumpList(tester);
    expect(focus.requestById(const FushiFocusId('row-20')), isTrue);
    await tester.pumpAndSettle();
    expect(scroll.offset, greaterThan(0), reason: '光标走到屏外目标要滚进视野');
  });
}
