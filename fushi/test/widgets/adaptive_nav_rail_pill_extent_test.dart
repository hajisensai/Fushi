import 'package:material_ui/material_ui.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart';

// 2026-10-05 用户反馈（录屏：Windows 左侧侧栏）：选中项的强调色药丸只包住
// 图标 + 文字，鼠标悬停 / 按下时 InkWell 的灰色状态层却是整行宽，选中项上叠出
// 「一短一长」两条胶囊。要求灰色反馈范围与选中高亮完全一致。
//
// 判据：MD3 展开 rail 每一行的药丸（选中 / 未选中都是同一个 AnimatedContainer）
// 与承载悬停 / 按压 / 焦点状态层的 InkWell 同尺寸、同圆角。
void main() {
  const List<AdaptiveNavItem> items = <AdaptiveNavItem>[
    AdaptiveNavItem(icon: Icons.home_outlined, label: '首页'),
    AdaptiveNavItem(icon: Icons.menu_book_outlined, label: '书架'),
    AdaptiveNavItem(icon: Icons.movie_outlined, label: '视频'),
    AdaptiveNavItem(icon: Icons.tune_outlined, label: '设置'),
  ];

  Future<void> pumpRail(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: Scaffold(
            body: Row(
              children: <Widget>[
                Builder(
                  builder: (BuildContext context) => adaptiveNavRail(
                    context: context,
                    currentIndex: 2,
                    onTap: (_) {},
                    items: items,
                  ),
                ),
                const Expanded(child: SizedBox.expand()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder pillOf(String label) => find
      .ancestor(of: find.text(label), matching: find.byType(AnimatedContainer))
      .first;

  Finder inkOf(String label) => find
      .ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((Widget w) => w is InkWell),
      )
      .first;

  testWidgets('选中药丸与悬停 / 按压状态层同尺寸同圆角', (WidgetTester tester) async {
    await pumpRail(tester);
    expect(tester.takeException(), isNull);

    for (final AdaptiveNavItem item in items) {
      final Size pill = tester.getSize(pillOf(item.label));
      final Size ink = tester.getSize(inkOf(item.label));
      expect(pill, ink, reason: '${item.label}：药丸与状态层尺寸不一致');

      final AnimatedContainer container = tester.widget<AnimatedContainer>(
        pillOf(item.label),
      );
      final BoxDecoration decoration = container.decoration! as BoxDecoration;
      final InkWell inkWell = tester.widget<InkWell>(inkOf(item.label));
      expect(
        decoration.borderRadius,
        inkWell.borderRadius,
        reason: '${item.label}：药丸与状态层圆角不一致',
      );
    }

    // 选中项只有一枚指示器：药丸有实底，且与整行同宽（不会再露出更长的灰底）。
    final AnimatedContainer selected = tester.widget<AnimatedContainer>(
      pillOf('视频'),
    );
    expect((selected.decoration! as BoxDecoration).color!.a, greaterThan(0));
  });

  testWidgets('悬停未选中项：灰色状态层与选中药丸同尺寸', (WidgetTester tester) async {
    await pumpRail(tester);
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(mouse.removePointer);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(inkOf('书架')));
    await tester.pumpAndSettle();

    expect(
      tester.getSize(inkOf('书架')),
      tester.getSize(pillOf('视频')),
      reason: '悬停反馈区域必须与选中高亮一样大',
    );
    expect(tester.getRect(inkOf('书架')).left, tester.getRect(pillOf('视频')).left);
  });

  // MD3 底栏 / 收起 rail：整格是点击区，但悬停 / 按压状态层（含涟漪）只画在
  // 指示器药丸上，与选中高亮同尺寸（M3 NavigationBar 的 indicator ink）。
  Rect stateLayerRect(WidgetTester tester, String label) {
    final Finder ink = inkOf(label);
    final InkWell inkWell = tester.widget<InkWell>(ink);
    final RenderBox ref = tester.renderObject<RenderBox>(ink);
    final RectCallback? callback = inkWell.getRectCallback(ref);
    final Rect local = callback == null ? Offset.zero & ref.size : callback();
    return local.shift(ref.localToGlobal(Offset.zero));
  }

  Rect selectedPillRect(WidgetTester tester, String label) {
    final Finder pill = find
        .ancestor(of: find.text(label), matching: find.byType(Column))
        .first;
    // Column 的第一个孩子是药丸槽（pillWidth × 32）。
    final Finder slot = find
        .descendant(of: pill, matching: find.byType(SizedBox))
        .first;
    return tester.getRect(slot);
  }

  Future<void> expectIndicatorInk(WidgetTester tester) async {
    final Rect selected = selectedPillRect(tester, '视频');
    for (final AdaptiveNavItem item in items) {
      final Rect layer = stateLayerRect(tester, item.label);
      expect(layer.size, selected.size, reason: '${item.label}：状态层与选中药丸尺寸不一致');
      expect(
        layer,
        selectedPillRect(tester, item.label),
        reason: '${item.label}：状态层没有落在自己的药丸上',
      );
      final InkWell inkWell = tester.widget<InkWell>(inkOf(item.label));
      expect(
        inkWell.borderRadius,
        BorderRadius.circular(selected.height / 2),
        reason: '${item.label}：状态层圆角与药丸不一致',
      );
    }
  }

  testWidgets('MD3 底栏：状态层裁到指示器药丸', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: Scaffold(
            body: const SizedBox.expand(),
            bottomNavigationBar: Builder(
              builder: (BuildContext context) => adaptiveBottomBar(
                context: context,
                currentIndex: 2,
                onTap: (_) {},
                items: items,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectIndicatorInk(tester);
  });

  testWidgets('MD3 收起 rail：状态层裁到指示器药丸', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: FushiFocusRoot(
          child: Scaffold(
            body: Row(
              children: <Widget>[
                Builder(
                  builder: (BuildContext context) => adaptiveNavRail(
                    context: context,
                    currentIndex: 2,
                    onTap: (_) {},
                    items: items,
                    extended: false,
                  ),
                ),
                const Expanded(child: SizedBox.expand()),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectIndicatorInk(tester);
  });
}
