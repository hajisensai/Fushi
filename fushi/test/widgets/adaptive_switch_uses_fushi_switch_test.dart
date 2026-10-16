// adaptiveSwitch 的 Material（M3E）分支必须走 FushiSwitch：直接 new 一个裸
// Material Switch 会绕过 Expressive 开关（关态叉号、圆钮尺寸）与设计系统分派，
// 和其它 FushiSwitch 调用点观感不一致。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_toggles.dart'
    show FushiSwitch;
import 'package:material_ui/material_ui.dart';

Widget _harness(Widget Function(BuildContext) builder) {
  return MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      platform: TargetPlatform.android,
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF386A58)),
    ),
    home: Scaffold(
      body: Center(child: Builder(builder: builder)),
    ),
  );
}

void main() {
  testWidgets('Material 分支渲染 FushiSwitch 并把值 / 回调 / 颜色透传', (
    WidgetTester tester,
  ) async {
    bool value = false;
    await tester.pumpWidget(
      _harness(
        (BuildContext context) => adaptiveSwitch(
          context: context,
          value: value,
          onChanged: (bool v) => value = v,
          activeColor: const Color(0xFF123456),
        ),
      ),
    );
    final Finder finder = find.byType(FushiSwitch);
    expect(finder, findsOneWidget);
    final FushiSwitch sw = tester.widget<FushiSwitch>(finder);
    expect(sw.value, isFalse);
    expect(sw.activeColor, const Color(0xFF123456));
    expect(sw.onChanged, isNotNull);

    await tester.tap(finder);
    await tester.pumpAndSettle();
    expect(value, isTrue, reason: '点击必须经 FushiSwitch 把新值回调出来');
  });

  testWidgets('onChanged 为 null 时 FushiSwitch 处于禁用态', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _harness(
        (BuildContext context) =>
            adaptiveSwitch(context: context, value: true, onChanged: null),
      ),
    );
    final FushiSwitch sw = tester.widget<FushiSwitch>(find.byType(FushiSwitch));
    expect(sw.onChanged, isNull);
  });
}
