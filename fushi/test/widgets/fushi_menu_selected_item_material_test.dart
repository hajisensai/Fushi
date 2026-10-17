import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart'
    show showFushiMenu;
import 'package:material_ui/material_ui.dart';

/// MD3 菜单的当前项（initialValue）底色必须由 [Material] 承载：此前用 DecoratedBox
/// 包着菜单项，项里的 ListTile / InkWell 把底色与水波画在更外层的菜单 Material 上，
/// 被装饰盒盖住——按下无水波，ListTile 还报 debug 断言「ListTile background color
/// or ink splashes may be invisible」（SRS 卡面外观页的颜色选择菜单截图巡检）。
void main() {
  testWidgets('MD3 菜单当前项：内含 ListTile 不触发断言，底色由 Material 承载', (
    WidgetTester tester,
  ) async {
    late BuildContext host;
    final ThemeData theme = ThemeData(useMaterial3: true);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) {
              host = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    showFushiMenu<int>(
      context: host,
      position: const RelativeRect.fromLTRB(20, 20, 300, 300),
      initialValue: 1,
      items: const <PopupMenuEntry<int>>[
        PopupMenuItem<int>(value: 0, child: ListTile(title: Text('Alpha'))),
        PopupMenuItem<int>(value: 1, child: ListTile(title: Text('Beta'))),
      ],
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    Material nearestMaterial(String text) => tester.widget<Material>(
      find.ancestor(of: find.text(text), matching: find.byType(Material)).first,
    );
    expect(
      nearestMaterial('Beta').color,
      theme.colorScheme.secondaryContainer,
      reason: '当前项的底色在离 ListTile 最近的 Material 上，水波可见',
    );
    expect(
      nearestMaterial('Alpha').color,
      isNot(theme.colorScheme.secondaryContainer),
    );

    // 按下当前项：水波画在当前项自己的 Material 上（不再被装饰盒挡住）。
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('Beta')),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
    await gesture.up();
    await tester.pumpAndSettle();
  });
}
