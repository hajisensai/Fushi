import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

/// BUG-2033 守卫：[FushiPageHeader] 的前导键（返回箭头）与动作键必须与标题
/// **垂直居中**对齐。
///
/// 回归态：整行 `CrossAxisAlignment.start` + 给 leading 写死 `top: gap / 2`。
/// 那是拿常数去凑「48 高 BackButton 的图标中心（距顶 24）」与「pageTitle 行盒
/// 中心（22 × 1.27 / 2 ≈ 14）」之差，凑完仍差 ~14px，箭头恒比标题低一截
/// （用户实报「左上角文字和返回箭头没对齐」，新手引导页截图）。
///
/// 这里断言的是**渲染几何**（两者中心 dy 相等），不是源码字面量：字号档位、
/// 文字缩放、按钮尺寸怎么变，判据都成立。
void main() {
  Widget wrap(Widget child, {double width = 900, double textScale = 1.0}) {
    return MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: MediaQuery(
        data: MediaQueryData(
          size: Size(width, 800),
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: width, child: child),
          ),
        ),
      ),
    );
  }

  testWidgets('BUG-2033: 返回箭头中心与标题中心同高（单行标题）', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        FushiPageHeader(
          title: '新手引导',
          leading: BackButton(onPressed: () {}),
        ),
      ),
    );

    final double arrowCenter = tester.getCenter(find.byType(BackButton)).dy;
    final double titleCenter = tester.getCenter(find.text('新手引导')).dy;
    expect(
      arrowCenter,
      moreOrLessEquals(titleCenter, epsilon: 0.5),
      reason: '返回箭头与页面标题必须垂直居中对齐（BUG-2033）',
    );
  });

  testWidgets('BUG-2033: 文字放大到 1.6 倍仍对齐（判据不含常数）', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        FushiPageHeader(
          title: '新手引导',
          leading: BackButton(onPressed: () {}),
        ),
        textScale: 1.6,
      ),
    );

    expect(
      tester.getCenter(find.byType(BackButton)).dy,
      moreOrLessEquals(tester.getCenter(find.text('新手引导')).dy, epsilon: 0.5),
      reason: '放大字号后箭头仍须与标题同高——写死常数的实现会在这一档失配',
    );
  });

  testWidgets('BUG-2033: 动作键中心与标题中心同高', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        FushiPageHeader(
          title: '书架',
          leading: BackButton(onPressed: () {}),
          actions: <Widget>[
            FushiIconButton(
              tooltip: 'Import',
              icon: Icons.library_add_outlined,
              onTap: () {},
            ),
          ],
        ),
      ),
    );

    final double titleCenter = tester.getCenter(find.text('书架')).dy;
    expect(
      tester.getCenter(find.byIcon(Icons.library_add_outlined)).dy,
      moreOrLessEquals(titleCenter, epsilon: 0.5),
      reason: '页头动作键与标题必须垂直居中对齐（BUG-2033）',
    );
    expect(
      tester.getCenter(find.byType(BackButton)).dy,
      moreOrLessEquals(titleCenter, epsilon: 0.5),
      reason: '同一行里前导键与动作键都应落在标题中心线上（BUG-2033）',
    );
  });

  testWidgets('BUG-2033: 带副标题时前导键落在标题块中心', (WidgetTester tester) async {
    await tester.pumpWidget(
      wrap(
        FushiPageHeader(
          title: '词典管理',
          subtitle: '导入与排序',
          leading: BackButton(onPressed: () {}),
        ),
      ),
    );

    final double arrowCenter = tester.getCenter(find.byType(BackButton)).dy;
    // 标题块 = 标题文字顶 → 副标题文字底。箭头须落在这个块的正中
    // （ListTile / 两行 AppBar 的既有做法），而不是被顶到标题上方。
    // 用「块中心」而不是「在两行之间」当判据：后者在回归态（顶对齐，箭头中心
    // 恰好也落在两行之间）同样成立，等于空转。
    final double blockCenter = (tester.getRect(find.text('词典管理')).top +
            tester.getRect(find.text('导入与排序')).bottom) /
        2;
    expect(
      arrowCenter,
      moreOrLessEquals(blockCenter, epsilon: 0.5),
      reason: '带副标题时前导键应与整个标题块垂直居中（BUG-2033）',
    );
  });
}
