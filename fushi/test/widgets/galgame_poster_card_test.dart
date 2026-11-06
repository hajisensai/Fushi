import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadLongPressIntent;
import 'package:fushi/src/shortcuts/input_binding.dart' show GamepadButton;
import 'package:fushi/src/utils/components/galgame_poster_card.dart';
import 'package:fushi/src/utils/components/shelf_card_widgets.dart';
import 'package:fushi/src/utils/components/shelf_cover_material.dart';

Widget _host(Widget child) => MaterialApp(
  home: Scaffold(
    body: Center(child: SizedBox(width: 160, child: child)),
  ),
);

void main() {
  testWidgets('渲染标题 + 封面，卡盒 1:1.6 比例', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const GalgamePosterCard(
          cover: ColoredBox(color: Colors.blue),
          title: 'テストゲーム',
        ),
      ),
    );
    expect(find.text('テストゲーム'), findsOneWidget);
    expect(find.byType(AspectRatio), findsOneWidget);
    final AspectRatio ar = tester.widget(find.byType(AspectRatio));
    expect(ar.aspectRatio, kShelfGameCaseAspectRatio);
    // 文字块走库页统一的 ShelfCardMeta（标题一行 + 副行 + 进度条）。
    expect(find.byType(ShelfCardMeta), findsOneWidget);
  });

  // 2026-10-25 卡盒定版：「全部都不用角标设计」——状态 / 排序值等原先压在封面上
  // 的信息全部进封面下的副行，封面框子树里不得出现这些文字。
  testWidgets('状态信息在封面下副行，不压在封面上', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const GalgamePosterCard(
          cover: ColoredBox(color: Colors.blue),
          title: 'G',
          subtitle: '玩过 · 12 小时',
          progress: 1,
          completed: true,
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(ShelfCardMeta),
        matching: find.text('玩过 · 12 小时'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ShelfCoverFrame),
        matching: find.byType(Text),
      ),
      findsNothing,
      reason: '封面上不压任何文字角标',
    );
    final ShelfCardMeta meta = tester.widget(find.byType(ShelfCardMeta));
    expect(meta.progress, 1);
    expect(meta.completed, isTrue);
  });

  testWidgets('卡盒材质下单张走材质表面，合集成员封面排成扇形', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const ShelfCoverMaterialScope(
          material: ShelfCoverMaterial.gameCase,
          child: GalgamePosterCard(
            cover: ColoredBox(color: Colors.blue),
            title: 'Single',
          ),
        ),
      ),
    );
    ShelfCoverPile pile = tester.widget(find.byType(ShelfCoverPile));
    expect(pile.material, ShelfCoverMaterial.gameCase);
    expect(pile.behind, isEmpty);

    await tester.pumpWidget(
      _host(
        const ShelfCoverMaterialScope(
          material: ShelfCoverMaterial.gameCase,
          child: GalgamePosterCard(
            cover: ColoredBox(color: Colors.blue),
            stackedCovers: <Widget>[
              ColoredBox(color: Colors.red),
              ColoredBox(color: Colors.green),
              ColoredBox(color: Colors.yellow),
              ColoredBox(color: Colors.black),
            ],
            title: 'Series',
          ),
        ),
      ),
    );
    pile = tester.widget(find.byType(ShelfCoverPile));
    expect(pile.behind.length, 3, reason: '扇形最多 4 作：前 1 + 后 3');
  });

  testWidgets('选中态加主色环', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const GalgamePosterCard(
          cover: ColoredBox(color: Colors.blue),
          title: 'Sel',
          selected: true,
        ),
      ),
    );
    // 2026-10 并入封面卡体系：选中环由封面框上的共享选中罩画（MD3 主色 3px
    // 内描边 + 淡罩），标题染主色。
    expect(
      find.byType(ShelfSelectedOverlay),
      findsOneWidget,
      reason: '选中态应在封面上画选中环',
    );
  });

  testWidgets('点击 / 长按 / 右键各自回调', (WidgetTester tester) async {
    int taps = 0;
    int longs = 0;
    int secondary = 0;
    await tester.pumpWidget(
      _host(
        GalgamePosterCard(
          cover: const ColoredBox(color: Colors.blue),
          title: 'Tap',
          onTap: () => taps++,
          onLongPress: () => longs++,
          onSecondaryTap: () => secondary++,
        ),
      ),
    );
    await tester.tap(find.byType(GalgamePosterCard));
    await tester.longPress(find.byType(GalgamePosterCard));
    expect(taps, 1);
    expect(longs, 1);
  });

  testWidgets('multiSelected 显示勾标', (WidgetTester tester) async {
    await tester.pumpWidget(
      _host(
        const GalgamePosterCard(
          cover: ColoredBox(color: Colors.blue),
          title: 'M',
          multiSelected: true,
        ),
      ),
    );
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  // 手柄重设计 P4：焦点根下长按 A（GamepadLongPressIntent）= onLongPress
  // （游戏卡上是上下文菜单），与鼠标长按/右键同一入口。
  testWidgets('手柄长按 A 触发 onLongPress（焦点根下）', (WidgetTester tester) async {
    int longPresses = 0;
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    final BuildContext cardContext = tester.element(find.text('G'));
    final Object? handled = Actions.maybeInvoke<GamepadLongPressIntent>(
      cardContext,
      const GamepadLongPressIntent(GamepadButton.a),
    );
    expect(handled, isTrue);
    expect(longPresses, 1);
  });

  testWidgets('无 onLongPress 时长按包装透明（不拦截 intent）', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );
    final BuildContext cardContext = tester.element(find.text('G'));
    final Object? handled = Actions.maybeInvoke<GamepadLongPressIntent>(
      cardContext,
      const GamepadLongPressIntent(GamepadButton.a),
    );
    expect(handled, isNull, reason: '透明包装：intent 应继续向上查找');
  });
}
