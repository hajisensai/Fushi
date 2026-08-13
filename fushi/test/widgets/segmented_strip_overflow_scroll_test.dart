import 'package:fading_edge_scrollview/fading_edge_scrollview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';

/// 分段条溢出滚动的可发现性补强（2026-08-13 手机顶栏显示不全）：
/// 装不下时的横向滚动必须带渐隐边缘（明示还有更多段），且选中段自动滚入可视区
/// （打开即可见选中段、程序切段后不停留在看不见选中段的位置）。
void main() {
  Widget host({required int selected, ValueChanged<int>? onChanged}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 160,
            child: FushiSegmentedStrip<int>(
              segments: <ButtonSegment<int>>[
                for (int i = 0; i < 8; i++)
                  ButtonSegment<int>(value: i, label: Text('分段$i')),
              ],
              selected: selected,
              onChanged: onChanged ?? (_) {},
            ),
          ),
        ),
      ),
    );
  }

  ScrollController controllerOf(WidgetTester tester) {
    final SingleChildScrollView scrollView = tester.widget<SingleChildScrollView>(
      find.descendant(
        of: find.byType(FadingEdgeScrollView),
        matching: find.byType(SingleChildScrollView),
      ),
    );
    return scrollView.controller!;
  }

  testWidgets('装不下时滚动兜底带渐隐边缘', (WidgetTester tester) async {
    await tester.pumpWidget(host(selected: 0));
    await tester.pump();
    expect(find.byType(FadingEdgeScrollView), findsOneWidget,
        reason: '截断的分段条必须有「还有更多」的渐隐提示');
  });

  testWidgets('打开时选中段自动滚入可视区；切回首段滚回起点', (WidgetTester tester) async {
    await tester.pumpWidget(host(selected: 7));
    // 首帧 post-frame jumpTo 定位。
    await tester.pump();
    expect(controllerOf(tester).offset, greaterThan(0),
        reason: '选中尾段时不应停在起点（选中段在可视区外）');

    await tester.pumpWidget(host(selected: 0));
    await tester.pumpAndSettle();
    expect(controllerOf(tester).offset, 0,
        reason: '切回首段应动画滚回起点让它可见');
  });
}
