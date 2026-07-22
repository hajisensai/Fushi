// eink 下 HibikiCard 必须自带描边：eink scheme 把 surface container 全部塌缩为
// 背景色，无边卡片与页面融为一体（巡检 C1，docs/reviews/2026-07-22-ui-ux-survey.md）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_platform.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';

Widget _app({required bool eink, required Widget child}) {
  return MaterialApp(
    theme: ThemeData(
      extensions: <ThemeExtension<dynamic>>[HibikiEinkTheme(eink)],
    ),
    home: Scaffold(body: child),
  );
}

RoundedRectangleBorder _cardShape(WidgetTester tester) {
  final AnimatedContainer container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byType(HibikiCard),
      matching: find.byType(AnimatedContainer),
    ),
  );
  final ShapeDecoration decoration = container.decoration! as ShapeDecoration;
  return decoration.shape as RoundedRectangleBorder;
}

void main() {
  testWidgets('非 eink：默认无描边（现状不变）', (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: false,
      child: const HibikiCard(child: SizedBox(width: 80, height: 48)),
    ));
    expect(_cardShape(tester).side, BorderSide.none);
  });

  testWidgets('eink：自动补 1px 描边', (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: true,
      child: const HibikiCard(child: SizedBox(width: 80, height: 48)),
    ));
    final BorderSide side = _cardShape(tester).side;
    expect(side.style, BorderStyle.solid);
    expect(side.width, 1);
  });

  testWidgets('eink + selected：描边加粗到 2px（选中唯一可辨信号）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: true,
      child: const HibikiCard(
        selected: true,
        child: SizedBox(width: 80, height: 48),
      ),
    ));
    expect(_cardShape(tester).side.width, 2);
  });

  testWidgets('显式 borderColor 优先于 eink 默认边', (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: true,
      child: const HibikiCard(
        borderColor: Colors.red,
        child: SizedBox(width: 80, height: 48),
      ),
    ));
    expect(_cardShape(tester).side.color, Colors.red);
  });

  testWidgets('eink：状态动画时长归零（AnimatedContainer 不再连续重绘）',
      (WidgetTester tester) async {
    await tester.pumpWidget(_app(
      eink: true,
      child: const HibikiCard(child: SizedBox(width: 80, height: 48)),
    ));
    final AnimatedContainer container = tester.widget<AnimatedContainer>(
      find.descendant(
        of: find.byType(HibikiCard),
        matching: find.byType(AnimatedContainer),
      ),
    );
    expect(container.duration, Duration.zero);
  });
}
