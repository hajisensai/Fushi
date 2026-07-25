import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/components/galgame_poster_card.dart';

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

  testWidgets('overlayText 有值时显示排序浮层，空时不显示',
      (WidgetTester tester) async {
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
}
