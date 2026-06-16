import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

// TODO-381 / TODO-422：词典管理行的布局守卫（不拉起整页 AppModel/Drift，只复刻
// 行的真实结构 = HibikiListItem(leading: 折叠按钮, title: Expanded 名字 +
// ellipsis, trailing: 一串图标按钮)）。行尾控件串末尾现在是独立删除按钮
// （TODO-422 取代旧三点菜单）。验证：① 折叠/展开按钮在最左（leading），在标题
// 之前；② 窄屏下长词典名不撑爆布局（无 RenderFlex overflow），名字由
// Expanded + ellipsis 优雅省略。
void main() {
  // 复刻 _buildDictionaryTile 的行结构（leading 折叠 + 中段名字 + 右侧控件串）。
  Widget buildRow({required double width}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: HibikiListItem(
              minHeight: 70,
              leading: const Icon(Icons.unfold_less, size: 20),
              title: const Text(
                'A Very Long Dictionary Name That Would Overflow On Narrow '
                'Widths 超长词典名称用来测试窄屏溢出',
              ),
              subtitle: const Text('rev 1.0'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: const <Widget>[
                  Icon(Icons.keyboard_arrow_up, size: 18),
                  Icon(Icons.keyboard_arrow_down, size: 18),
                  SizedBox(width: 40, child: Icon(Icons.toggle_on)),
                  // TODO-422：行尾独立删除按钮取代旧三点菜单。
                  Icon(Icons.delete_outline, size: 20),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('collapse leading icon is laid out left of the dictionary name',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildRow(width: 600));
    await tester.pump();

    expect(tester.takeException(), isNull);

    final double leadingX =
        tester.getTopLeft(find.byIcon(Icons.unfold_less)).dx;
    final double titleX = tester.getTopLeft(find.byType(Text).first).dx;
    expect(leadingX, lessThan(titleX),
        reason: 'collapse toggle must sit left of the name (leading/leftmost)');
  });

  testWidgets('long dictionary name does not overflow on a narrow width',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(320, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(buildRow(width: 280));
    await tester.pump();

    // 窄屏下名字被 Expanded + ellipsis 收住，行不会 RenderFlex 溢出报错。
    expect(tester.takeException(), isNull);
  });
}
