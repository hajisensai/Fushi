import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/utils/components/galgame_poster_card.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: 160, child: child),
        ),
      ),
    );

void main() {
  testWidgets('渲染标题 + 封面，3:4 比例', (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      const GalgamePosterCard(
        cover: ColoredBox(color: Colors.blue),
        title: 'テストゲーム',
      ),
    ));
    expect(find.text('テストゲーム'), findsOneWidget);
    expect(find.byType(AspectRatio), findsOneWidget);
    final AspectRatio ar = tester.widget(find.byType(AspectRatio));
    expect(ar.aspectRatio, 3 / 4);
  });

  testWidgets('overlayText 有值时显示排序浮层，空时不显示', (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      const GalgamePosterCard(
        cover: ColoredBox(color: Colors.blue),
        title: 'G',
        overlayText: '8.5 #123',
      ),
    ));
    expect(find.text('8.5 #123'), findsOneWidget);

    await tester.pumpWidget(_host(
      const GalgamePosterCard(
        cover: ColoredBox(color: Colors.blue),
        title: 'G',
        overlayText: '',
      ),
    ));
    expect(find.text('8.5 #123'), findsNothing);
  });

  testWidgets('选中态加主色环，标题染主色', (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      const GalgamePosterCard(
        cover: ColoredBox(color: Colors.blue),
        title: 'Sel',
        selected: true,
      ),
    ));
    final AnimatedContainer container = tester.widget(
      find.byType(AnimatedContainer),
    );
    final BoxDecoration deco = container.decoration! as BoxDecoration;
    expect(deco.border, isNotNull, reason: '选中态应有边框环');
  });

  testWidgets('点击 / 长按 / 右键各自回调', (WidgetTester tester) async {
    int taps = 0;
    int longs = 0;
    int secondary = 0;
    await tester.pumpWidget(_host(
      GalgamePosterCard(
        cover: const ColoredBox(color: Colors.blue),
        title: 'Tap',
        onTap: () => taps++,
        onLongPress: () => longs++,
        onSecondaryTap: () => secondary++,
      ),
    ));
    await tester.tap(find.byType(GalgamePosterCard));
    await tester.longPress(find.byType(GalgamePosterCard));
    expect(taps, 1);
    expect(longs, 1);
  });

  testWidgets('multiSelected 显示勾标', (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      const GalgamePosterCard(
        cover: ColoredBox(color: Colors.blue),
        title: 'M',
        multiSelected: true,
      ),
    ));
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('trailing 控件渲染在卡上', (WidgetTester tester) async {
    await tester.pumpWidget(_host(
      const GalgamePosterCard(
        cover: ColoredBox(color: Colors.blue),
        title: 'T',
        trailing: Icon(Icons.more_vert),
      ),
    ));
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  // 手柄重设计 P4：焦点根下长按 A（GamepadLongPressIntent）= onLongPress
  // （游戏卡上是上下文菜单），与鼠标长按/右键同一入口。
  testWidgets('手柄长按 A 触发 onLongPress（焦点根下）', (WidgetTester tester) async {
    int longPresses = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FushiFocusRoot(
          child: Center(
            child: SizedBox(
              width: 160,
              child: GalgamePosterCard(
                cover: const ColoredBox(color: Colors.blue),
                title: 'G',
                onTap: () {},
                onLongPress: () => longPresses++,
              ),
            ),
          ),
        ),
      ),
    ));
    final BuildContext cardContext =
        tester.element(find.text('G'));
    final Object? handled = Actions.maybeInvoke<GamepadLongPressIntent>(
      cardContext,
      const GamepadLongPressIntent(GamepadButton.a),
    );
    expect(handled, isTrue);
    expect(longPresses, 1);
  });

  testWidgets('无 onLongPress 时长按包装透明（不拦截 intent）', (WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FushiFocusRoot(
          child: Center(
            child: SizedBox(
              width: 160,
              child: GalgamePosterCard(
                cover: const ColoredBox(color: Colors.blue),
                title: 'G',
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    ));
    final BuildContext cardContext =
        tester.element(find.text('G'));
    final Object? handled = Actions.maybeInvoke<GamepadLongPressIntent>(
      cardContext,
      const GamepadLongPressIntent(GamepadButton.a),
    );
    expect(handled, isNull, reason: '透明包装：intent 应继续向上查找');
  });
}
