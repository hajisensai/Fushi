import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

// 反馈包装契约：MD3 下是原进度条 / tooltip；玻璃下是 GlassProgressIndicator
// （颜色取 colorScheme，不是库默认 iOS 蓝），tooltip 气泡是 GlassContainer。

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
        child: Scaffold(
          body: Center(child: SizedBox(width: 300, child: child)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('MD3 builds the original indicators and tooltip', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const Column(
        children: <Widget>[
          FushiLinearProgressIndicator(value: 0.4, minHeight: 6),
          FushiCircularProgressIndicator(value: 0.5, strokeWidth: 2),
          FushiCircularProgressIndicator.adaptive(value: 0.5),
          FushiTooltip(message: 'tip', child: Text('anchor')),
        ],
      ),
      glass: false,
    );
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNWidgets(2));
    expect(find.byType(Tooltip), findsOneWidget);
    expect(find.byType(GlassProgressIndicator), findsNothing);
  });

  testWidgets('glass builds GlassProgressIndicator with scheme colors', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const Column(
        children: <Widget>[
          FushiLinearProgressIndicator(value: 0.4, minHeight: 6),
          FushiCircularProgressIndicator(strokeWidth: 2),
          FushiCircularProgressIndicator.adaptive(value: 0.5),
          FushiCircularProgressIndicator(value: 0.2, color: Colors.orange),
        ],
      ),
      glass: true,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    final List<GlassProgressIndicator> all = tester
        .widgetList<GlassProgressIndicator>(find.byType(GlassProgressIndicator))
        .toList();
    expect(all, hasLength(4));
    final BuildContext ctx = tester.element(find.byType(Column));
    final Color primary = Theme.of(ctx).colorScheme.primary;
    expect(all[0].color, primary);
    expect(all[0].height, 6);
    expect(all[0].value, 0.4);
    expect(all[1].strokeWidth, 2);
    expect(all[1].value, isNull);
    expect(all[2].color, primary);
    expect(all[3].color, Colors.orange);
    // 线性条撑满父级宽度（与 Material 一致）。
    expect(
      tester.getSize(find.byType(GlassProgressIndicator).first).width,
      300,
    );
    // 不定态动画在跑，不能 pumpAndSettle。
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('glass tooltip keeps Tooltip behaviour with a glass bubble', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      const FushiTooltip(
        message: 'Glass tip',
        triggerMode: TooltipTriggerMode.tap,
        child: Text('anchor'),
      ),
      glass: true,
    );
    expect(find.byType(Tooltip), findsOneWidget);
    // 无障碍提示仍是消息文本。
    expect(
      tester.getSemantics(find.text('anchor')),
      matchesSemantics(tooltip: 'Glass tip', label: 'anchor'),
    );
    await tester.tap(find.text('anchor'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Glass tip'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Glass tip'),
        matching: find.byType(GlassContainer),
      ),
      findsOneWidget,
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  });
}
