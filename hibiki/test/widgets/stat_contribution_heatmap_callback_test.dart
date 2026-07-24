import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/utils/components/stat_contribution_heatmap.dart';

/// [StatContributionHeatmap.onDaySelected] 回调契约：
/// - 点真实日格 → 触发一次 (dateKey, 当日值)；
/// - 再点同格（收起气泡）→ 不触发；
/// - 点未来占位格 → 不触发；
/// - 不传回调（null）时点选行为不崩（其余消费者零变化）。
void main() {
  // 固定「现在」= 2026-07-15（周三），避免依赖真实时钟。
  final DateTime now = DateTime(2026, 7, 15, 10, 30);
  final String todayKey = statDateKey(DateTime(2026, 7, 15));

  const double cell = 12;
  const double spacing = 3;
  const int weeks = 4;
  // 精确约束宽度 = 4 列自然宽，让 LayoutBuilder 的自适应列数恰为 4、FittedBox
  // 不缩放（格子坐标可直接按自然坐标计算）。
  const double gridWidth = weeks * (cell + spacing) - spacing; // 57

  Widget buildHeatmap({void Function(String, int)? onDaySelected}) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: gridWidth,
            child: StatContributionHeatmap(
              valueByDateKey: <String, int>{todayKey: 123},
              now: now,
              weeks: weeks,
              baseColor: Colors.green,
              emptyColor: Colors.grey,
              valueLabel: (String dateKey, int value) => '$dateKey $value',
              onDaySelected: onDaySelected,
            ),
          ),
        ),
      ),
    );
  }

  /// 网格（唯一 GestureDetector）内某 (列,行) 格子中心的全局坐标。
  Offset cellCenter(WidgetTester tester, int col, int row) {
    final Finder grid = find.descendant(
      of: find.byType(StatContributionHeatmap),
      matching: find.byType(GestureDetector),
    );
    const double step = cell + spacing;
    return tester.getTopLeft(grid) +
        Offset(col * step + cell / 2, row * step + cell / 2);
  }

  testWidgets('点今天格触发一次回调；再点同格收起不触发', (WidgetTester tester) async {
    final List<(String, int)> calls = <(String, int)>[];
    await tester.pumpWidget(buildHeatmap(
      onDaySelected: (String dateKey, int value) => calls.add((dateKey, value)),
    ));

    // 今天 = 末列（索引 3）周三（行索引 2）。
    await tester.tapAt(cellCenter(tester, weeks - 1, 2));
    await tester.pump();
    expect(calls, <(String, int)>[(todayKey, 123)]);

    // 再点同格 → 气泡收起，不触发第二次。
    await tester.tapAt(cellCenter(tester, weeks - 1, 2));
    await tester.pump();
    expect(calls.length, 1);
  });

  testWidgets('点未来占位格不触发回调', (WidgetTester tester) async {
    final List<(String, int)> calls = <(String, int)>[];
    await tester.pumpWidget(buildHeatmap(
      onDaySelected: (String dateKey, int value) => calls.add((dateKey, value)),
    ));

    // 末列周五（行索引 4）在 2026-07-15（周三）之后 → 占位格。
    await tester.tapAt(cellCenter(tester, weeks - 1, 4));
    await tester.pump();
    expect(calls, isEmpty);
  });

  testWidgets('不传回调时点选不崩（既有气泡行为不变）', (WidgetTester tester) async {
    await tester.pumpWidget(buildHeatmap());
    await tester.tapAt(cellCenter(tester, weeks - 1, 2));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // 气泡文案照常出现。
    expect(find.text('$todayKey 123'), findsOneWidget);
  });
}
