import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiEinkTheme;
import 'package:fushi/src/utils/components/fushi_floating_chrome.dart'
    show FushiTopFadeScrim;
import 'package:fushi/src/utils/components/glass/fushi_glass_bars.dart';
import 'package:material_ui/material_ui.dart';

/// 墨水屏下 FushiAppBar 不走悬浮页头行（滚动逐帧收缩 + 模糊底板在墨水屏上
/// 只会残影），与 FushiPageScaffold / FushiToolScaffold 的墨水屏回落同一口径：
/// 画静态 AppBar；非墨水屏仍走悬浮页头行（带滚动渐隐遮罩）。
Future<void> _pumpBar(WidgetTester tester, {required bool eink}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        useMaterial3: true,
        extensions: <ThemeExtension<dynamic>>[FushiEinkTheme(eink)],
      ),
      home: Scaffold(
        appBar: const FushiAppBar(title: Text('页名')),
        body: ListView(
          children: List<Widget>.generate(
            40,
            (int i) => SizedBox(height: 48, child: Text('行 $i')),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('墨水屏：FushiAppBar 画静态 AppBar', (WidgetTester tester) async {
    await _pumpBar(tester, eink: true);
    expect(find.byType(AppBar), findsOneWidget);
    expect(find.byType(FushiTopFadeScrim), findsNothing);
    expect(find.text('页名'), findsOneWidget);
  });

  testWidgets('非墨水屏：FushiAppBar 走悬浮页头行（带渐隐遮罩）', (WidgetTester tester) async {
    await _pumpBar(tester, eink: false);
    expect(find.byType(FushiTopFadeScrim), findsOneWidget);
    expect(find.text('页名'), findsOneWidget);
  });
}
