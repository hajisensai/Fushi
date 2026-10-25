import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/fushi_page_backdrop.dart';

/// 路由层统一垫的页面背景（[FushiBackdropPageTransitionsBuilder] →
/// [FushiPageBackdrop] → `LibraryShapeBackdrop`）必须对布局透明：路由给页面的
/// 紧约束原样传到页面根部。曾因 `Stack` 默认 `StackFit.loose` 把约束放松，根部
/// 不是 Scaffold 的页面缩成内容大小贴到左上角。
void main() {
  ThemeData theme() => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    eink: false,
  );

  testWidgets('route page root keeps tight full-screen constraints under the '
      'app-wide backdrop', (WidgetTester tester) async {
    BoxConstraints? pageConstraints;
    await tester.pumpWidget(
      MaterialApp(
        theme: theme(),
        home: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            pageConstraints = constraints;
            return TextButton(onPressed: () {}, child: const Text('open'));
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(FushiPageBackdrop), findsOneWidget);
    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(pageConstraints, BoxConstraints.tight(screen));
    // 根部按钮撑满整页，文字居中，不缩到左上角。
    expect(tester.getSize(find.byType(TextButton)), screen);
    expect(
      tester.getCenter(find.text('open')),
      Offset(screen.width / 2, screen.height / 2),
    );
  });
}
