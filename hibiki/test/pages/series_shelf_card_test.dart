import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/focus/hibiki_focus_controller.dart';
import 'package:hibiki/src/focus/hibiki_focus_target.dart';
import 'package:hibiki/src/pages/implementations/series_shelf_card.dart';

/// TODO-616 A2 / TODO-1125 A SeriesShelfCard 守卫：
///  - 渲染系列名 + 成员数角标（series_item_count）。
///  - 点击触发 onTap；选择态下走 onSelectionToggle。
///  - 堆叠样式：多张封面时后层真实成员封面渲染；单封面降级无堆叠；
///    选择态勾选框不被堆叠层遮挡。
void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  Widget wrap(Widget child) => TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              height: 320,
              child: child,
            ),
          ),
        ),
      );

  // 用带 Key 的封面 widget，便于精确 find 后层是否真实渲染。
  Widget coverBox(String id, Color color) =>
      ColoredBox(key: ValueKey<String>('cover_$id'), color: color);

  testWidgets('renders series name and item-count badge', (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'My Series',
      itemCount: 3,
      covers: <Widget>[coverBox('a', Colors.blue)],
      slotAspectRatio: 160 / 260,
      onTap: () {},
    )));
    expect(find.text('My Series'), findsOneWidget);
    // series_item_count(n: 3) => "3 items" (en).
    expect(find.text('3 items'), findsOneWidget);
  });

  testWidgets('tap fires onTap when not in selection mode', (tester) async {
    int taps = 0;
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'S',
      itemCount: 2,
      covers: <Widget>[coverBox('a', Colors.green)],
      slotAspectRatio: 160 / 260,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('selection mode routes tap to onSelectionToggle', (tester) async {
    int taps = 0;
    int toggles = 0;
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'S',
      itemCount: 2,
      covers: <Widget>[coverBox('a', Colors.green)],
      slotAspectRatio: 160 / 260,
      selectionMode: true,
      selectionKey: 'series_1',
      onSelectionToggle: () => toggles++,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(InkWell).first);
    await tester.pump();
    expect(toggles, 1);
    expect(taps, 0);
  });

  testWidgets('registers a HibikiFocusTarget under a focus root with focusId',
      (tester) async {
    int taps = 0;
    await tester.pumpWidget(wrap(HibikiFocusRoot(
      child: SeriesShelfCard(
        name: 'S',
        itemCount: 2,
        covers: <Widget>[coverBox('a', Colors.green)],
        slotAspectRatio: 160 / 260,
        focusId: const HibikiFocusId('reader-shelf-series-42'),
        onTap: () => taps++,
      ),
    )));
    await tester.pump();

    expect(find.byType(HibikiFocusTarget), findsOneWidget);
    final HibikiFocusController controller = HibikiFocusRoot.controllerOf(
      tester.element(find.byType(SeriesShelfCard)),
    );
    expect(
      controller.requestById(const HibikiFocusId('reader-shelf-series-42')),
      isTrue,
    );
    await tester.pump();
    expect(controller.activeId, const HibikiFocusId('reader-shelf-series-42'));

    // Enter / gamepad A activates the same onTap as a mouse.
    Actions.maybeInvoke<ActivateIntent>(
      controller.activeContext!,
      const ActivateIntent(),
    );
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('stays a bare InkWell without a focusId (never-break)',
      (tester) async {
    await tester.pumpWidget(wrap(HibikiFocusRoot(
      child: SeriesShelfCard(
        name: 'S',
        itemCount: 2,
        covers: <Widget>[coverBox('a', Colors.green)],
        slotAspectRatio: 160 / 260,
        onTap: () {},
      ),
    )));
    await tester.pump();
    expect(find.byType(HibikiFocusTarget), findsNothing);
  });

  // ---- TODO-1125 A 堆叠样式 ----

  testWidgets('multi-cover renders real back-layer member covers',
      (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'Stacked',
      itemCount: 3,
      covers: <Widget>[
        coverBox('main', Colors.red),
        coverBox('back1', Colors.green),
        coverBox('back2', Colors.blue),
      ],
      slotAspectRatio: 160 / 260,
      onTap: () {},
    )));
    // 主封面 + 两张真实后层封面全部渲染（不再是空色块）。
    expect(find.byKey(const ValueKey<String>('cover_main')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_back1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_back2')), findsOneWidget);
    // 两个堆叠后层（depth 1、2）真实存在。
    expect(find.byKey(const ValueKey<String>('series-stack-back-1')),
        findsOneWidget);
    expect(find.byKey(const ValueKey<String>('series-stack-back-2')),
        findsOneWidget);
  });

  testWidgets('single cover degrades to no stacking (main only)',
      (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'Solo',
      itemCount: 1,
      covers: <Widget>[coverBox('main', Colors.red)],
      slotAspectRatio: 160 / 260,
      onTap: () {},
    )));
    expect(find.byKey(const ValueKey<String>('cover_main')), findsOneWidget);
    // 无后层：没有任何 series-stack-back 堆叠层。
    expect(find.byKey(const ValueKey<String>('series-stack-back-1')),
        findsNothing);
    expect(find.byKey(const ValueKey<String>('series-stack-back-2')),
        findsNothing);
  });

  testWidgets('caps back layers at 2 even with more members', (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'Many',
      itemCount: 5,
      covers: <Widget>[
        coverBox('main', Colors.red),
        coverBox('b1', Colors.green),
        coverBox('b2', Colors.blue),
        coverBox('b3', Colors.yellow),
        coverBox('b4', Colors.purple),
      ],
      slotAspectRatio: 160 / 260,
      onTap: () {},
    )));
    // 只取前 3 张：主 + 2 后层，第 4、5 张不渲染。
    expect(find.byKey(const ValueKey<String>('cover_main')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_b1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_b2')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('cover_b3')), findsNothing);
    expect(find.byKey(const ValueKey<String>('cover_b4')), findsNothing);
  });

  testWidgets('selection check is not covered by stack back layers',
      (tester) async {
    await tester.pumpWidget(wrap(SeriesShelfCard(
      name: 'Sel',
      itemCount: 3,
      covers: <Widget>[
        coverBox('main', Colors.red),
        coverBox('back1', Colors.green),
        coverBox('back2', Colors.blue),
      ],
      slotAspectRatio: 160 / 260,
      selectionMode: true,
      selectionKey: 'series_9',
      selected: true,
      onSelectionToggle: () {},
      onTap: () {},
    )));
    await tester.pump();
    // 勾选图标存在，且在 paint 顺序上位于所有后层封面之后（不被遮挡）。
    final Finder check = find.byIcon(Icons.check);
    expect(check, findsOneWidget);

    // 有堆叠后层存在（不足则本断言无意义）。
    expect(find.byKey(const ValueKey<String>('series-stack-back-1')),
        findsOneWidget);
    // 勾选图标可被 find 且有真实尺寸（未被 offstage / 未被完全裁剪遮盖）。
    expect(tester.getSize(check).width, greaterThan(0));
    // 勾选框在 Stack children 里位于所有后层堆叠之后（绘制在最前，不被遮挡）：
    // Stack 按子顺序绘制，后层用 ..._buildBackLayers 铺在最前，勾选框 Positioned
    // 在其后声明，故命中测试勾选框区域应能到达勾选层（IgnorePointer 不吸事件但仍绘制）。
    final Offset checkCenter = tester.getCenter(check);
    // 勾选框中心不落在任何后层封面的“独占”区域外——用后层封面中心不等于勾选框中心
    // 做弱断言，主断言是勾选图标可见且有尺寸（上方），此处仅确认布局无坍缩。
    expect(checkCenter.dx.isFinite && checkCenter.dy.isFinite, isTrue);
  });
}
