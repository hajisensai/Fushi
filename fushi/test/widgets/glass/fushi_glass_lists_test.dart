import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_apple_palette.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_lists.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 列表与容器包装契约：MD3 下是原 ListTile / ExpansionTile / Divider / Card /
// Badge；玻璃下按 Apple 26 内容层规则是实色——列表行是 [FushiAppleRow]、
// 卡片是 [FushiAppleGroupSurface]（secondaryGroupedBackground）、分隔线是
// separator 细线，都不是玻璃组件；只有 Badge 是 GlassBadge。列表行可 Tab
// 聚焦、Enter 激活，选中态有可见高亮。

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required bool glass,
}) async {
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(body: ListView(children: <Widget>[child])),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('FushiListTileControl', () {
    testWidgets('MD3 builds the original ListTile', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FushiListTileControl(title: const Text('row'), onTap: () {}),
        glass: false,
      );
      expect(find.byType(ListTile), findsOneWidget);
      expect(find.byType(GlassListTile), findsNothing);
    });

    testWidgets('glass renders a solid Apple row with all slots', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        FushiListTileControl(
          leading: const Icon(Icons.book),
          title: const Text('Title'),
          subtitle: const Text('Subtitle'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () {},
        ),
        glass: true,
      );
      expect(find.byType(ListTile), findsNothing);
      expect(find.byType(InkWell), findsNothing);
      expect(find.byType(GlassListTile), findsNothing);
      expect(find.byType(FushiAppleRow), findsOneWidget);
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('Subtitle'), findsOneWidget);
      expect(find.byIcon(Icons.book), findsOneWidget);
      expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    });

    testWidgets('glass tile taps, long-presses and activates with Enter', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      int longPresses = 0;
      final List<bool> focus = <bool>[];
      await _pump(
        tester,
        FushiListTileControl(
          title: const Text('row'),
          onTap: () => taps++,
          onLongPress: () => longPresses++,
          onFocusChange: focus.add,
        ),
        glass: true,
      );
      await tester.tap(find.text('row'));
      await tester.pump();
      expect(taps, 1);
      await tester.longPress(find.text('row'));
      await tester.pump();
      expect(longPresses, 1);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focus, contains(true));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 2);
    });

    testWidgets('disabled glass tile ignores taps and is not focusable', (
      WidgetTester tester,
    ) async {
      int taps = 0;
      final List<bool> focus = <bool>[];
      await _pump(
        tester,
        FushiListTileControl(
          title: const Text('row'),
          enabled: false,
          onTap: () => taps++,
          onFocusChange: focus.add,
        ),
        glass: true,
      );
      await tester.tap(find.text('row'));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(taps, 0);
      expect(focus, isEmpty);
    });

    // 选中态两种口径：选择型（默认）= 不铺底、行尾强调色对勾、文字不变色；
    // 导航型（调用点给 selectedTileColor）= 整行铺该底色。
    testWidgets('selected glass tile gets a visible highlight', (
      WidgetTester tester,
    ) async {
      Future<Color?> fillOf(bool selected, {Color? selectedTileColor}) async {
        await _pump(
          tester,
          FushiListTileControl(
            title: const Text('row'),
            selected: selected,
            selectedTileColor: selectedTileColor,
            onTap: () {},
          ),
          glass: true,
        );
        final AnimatedContainer box = tester.widget<AnimatedContainer>(
          find
              .descendant(
                of: find.byType(FushiAppleRow),
                matching: find.byType(AnimatedContainer),
              )
              .first,
        );
        return (box.decoration! as BoxDecoration).color;
      }

      final Color? unselected = await fillOf(false);
      expect(unselected!.a, 0);
      expect(find.byType(FushiAppleCheckmark), findsNothing);

      final Color? selected = await fillOf(true);
      expect(selected!.a, 0);
      expect(find.byType(FushiAppleCheckmark), findsOneWidget);
      final Text title = tester.widget<Text>(find.text('row'));
      expect(title.style, isNull); // 颜色来自 DefaultTextStyle
      final DefaultTextStyle style = tester.widget<DefaultTextStyle>(
        find
            .ancestor(
              of: find.text('row'),
              matching: find.byType(DefaultTextStyle),
            )
            .first,
      );
      final BuildContext ctx = tester.element(find.text('row'));
      expect(style.style.color, appleColorsOf(ctx).label);

      const Color navFill = Color(0xFF3366CC);
      final Color? navSelected = await fillOf(true, selectedTileColor: navFill);
      expect(navSelected, navFill);
      expect(find.byType(FushiAppleCheckmark), findsNothing);
    });
  });

  group('FushiExpansionTile', () {
    testWidgets('MD3 builds the original ExpansionTile', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const FushiExpansionTile(title: Text('head'), children: <Widget>[]),
        glass: false,
      );
      expect(find.byType(ExpansionTile), findsOneWidget);
    });

    testWidgets('glass expands / collapses on tap and Enter', (
      WidgetTester tester,
    ) async {
      final List<bool> changes = <bool>[];
      await _pump(
        tester,
        FushiExpansionTile(
          title: const Text('head'),
          onExpansionChanged: changes.add,
          children: const <Widget>[Text('child')],
        ),
        glass: true,
      );
      expect(find.byType(ExpansionTile), findsNothing);
      expect(find.byType(FushiAppleRow), findsOneWidget);
      expect(find.text('child'), findsNothing);

      await tester.tap(find.text('head'));
      await tester.pumpAndSettle();
      expect(changes, <bool>[true]);
      expect(find.text('child'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(changes, <bool>[true, false]);
      expect(find.text('child'), findsNothing);
    });

    testWidgets('glass honours initiallyExpanded and an external controller', (
      WidgetTester tester,
    ) async {
      final ExpansibleController controller = ExpansibleController();
      addTearDown(controller.dispose);
      await _pump(
        tester,
        FushiExpansionTile(
          title: const Text('head'),
          initiallyExpanded: true,
          controller: controller,
          children: const <Widget>[Text('child')],
        ),
        glass: true,
      );
      expect(find.text('child'), findsOneWidget);
      controller.collapse();
      await tester.pumpAndSettle();
      expect(find.text('child'), findsNothing);
    });
  });

  group('Divider / Card / Badge', () {
    testWidgets('MD3 builds the originals', (WidgetTester tester) async {
      await _pump(
        tester,
        const Column(
          children: <Widget>[
            FushiDividerControl(height: 1),
            SizedBox(height: 20, child: FushiVerticalDivider(width: 1)),
            FushiCardControl(child: Text('card')),
            FushiBadgeControl(child: Icon(Icons.mail)),
            FushiBadgeControl.count(count: 3, child: Icon(Icons.inbox)),
          ],
        ),
        glass: false,
      );
      expect(find.byType(Divider), findsOneWidget);
      expect(find.byType(VerticalDivider), findsOneWidget);
      expect(find.byType(Card), findsOneWidget);
      expect(find.byType(Badge), findsNWidgets(2));
      expect(find.byType(GlassCard), findsNothing);
    });

    testWidgets('glass builds solid Apple content widgets', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Column(
          children: <Widget>[
            FushiDividerControl(height: 1),
            SizedBox(height: 20, child: FushiVerticalDivider(width: 1)),
            FushiCardControl.outlined(child: Text('card')),
            FushiBadgeControl(child: Icon(Icons.mail)),
            FushiBadgeControl.count(count: 3, child: Icon(Icons.inbox)),
            FushiBadgeControl(label: Text('7'), child: Icon(Icons.alarm)),
            FushiBadgeControl(label: Text('new'), child: Icon(Icons.star)),
            FushiBadgeControl.count(
              count: 2,
              isLabelVisible: false,
              child: Icon(Icons.home),
            ),
          ],
        ),
        glass: true,
      );
      expect(find.byType(Divider), findsNothing);
      expect(find.byType(VerticalDivider), findsNothing);
      expect(find.byType(Card), findsNothing);
      expect(find.byType(Badge), findsNothing);
      // 内容层是实色：分隔线与卡片都不是玻璃组件。
      expect(find.byType(GlassDivider), findsNothing);
      expect(find.byType(GlassCard), findsNothing);
      expect(find.byType(FushiAppleGroupSurface), findsOneWidget);
      expect(find.text('card'), findsOneWidget);
      final BuildContext ctx = tester.element(find.text('card'));
      final Material surface = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(FushiAppleGroupSurface),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(surface.color, appleColorsOf(ctx).secondaryGroupedBackground);
      // 圆点、count、纯数字 label → GlassBadge；isLabelVisible:false 不出徽标。
      expect(find.byType(GlassBadge), findsNWidgets(3));
      expect(find.text('3'), findsOneWidget);
      expect(find.text('7'), findsOneWidget);
      // 任意 label → 玻璃胶囊保住内容。
      expect(find.text('new'), findsOneWidget);
      expect(find.text('2'), findsNothing);
    });

    testWidgets('toggling a glass badge keeps the child mounted (focus)', (
      WidgetTester tester,
    ) async {
      final FocusNode node = FocusNode();
      addTearDown(node.dispose);
      Widget build(bool visible) => FushiBadgeControl.count(
        count: 4,
        isLabelVisible: visible,
        child: Focus(focusNode: node, child: const Text('target')),
      );
      await _pump(tester, build(false), glass: true);
      node.requestFocus();
      await tester.pump();
      final State before = tester.state(find.byType(Focus).last);
      await _pump(tester, build(true), glass: true);
      expect(find.text('4'), findsOneWidget);
      expect(node.hasFocus, isTrue);
      expect(tester.state(find.byType(Focus).last), same(before));
    });
  });
}
