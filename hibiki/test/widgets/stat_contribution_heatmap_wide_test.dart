import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/utils/components/stat_contribution_heatmap.dart';

/// BUG-1073 病灶 1：4K 全屏下热力图「左边一大片死黑」。
///
/// 组件侧的两半根因守卫：
/// - 列数**无上限**自适应——卡内可用宽 ~1700 时铺出 110+ 列（两年多），而有数据的
///   只有最近几周，其余全是空格子；
/// - 列数封顶后又不吃满宽度的话，右侧同样留大片空白。
///
/// 所以本测试锁死：列数封顶 [StatContributionHeatmap.maxWeeks]（53 = 一年）、富余
/// 宽度分摊给格子边长（上限 maxCell）、且放大后点击命中仍与绘制对齐。
void main() {
  // 固定「现在」= 2026-07-15（周三），避免依赖真实时钟。
  final DateTime now = DateTime(2026, 7, 15, 10, 30);
  final String todayKey = statDateKey(DateTime(2026, 7, 15));

  const double cell = 12;
  const double spacing = 3;
  const double maxCell = 18;
  const int maxWeeks = 53;

  Widget buildHeatmap({
    required double width,
    void Function(String, int)? onDaySelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: StatContributionHeatmap(
              valueByDateKey: <String, int>{todayKey: 123},
              now: now,
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

  /// 网格（热力图内唯一 GestureDetector）。
  Finder gridFinder() => find.descendant(
        of: find.byType(StatContributionHeatmap),
        matching: find.byType(GestureDetector),
      );

  testWidgets('超宽（2000）：列数封顶 53 周，富余宽度分摊给格子（不再左侧死黑 + 右侧留白）',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildHeatmap(width: 2000));
    await tester.pump();

    final Size size = tester.getSize(gridFinder());
    // 2000 宽若不封顶会铺出 (2000+3)/15 = 133 列；封顶后恒 53 列。
    expect(size.width, maxWeeks * maxCell + (maxWeeks - 1) * spacing);
    expect(size.height, 7 * maxCell + 6 * spacing);
  });

  testWidgets('宽度恰好 53 列自然宽：不放大格子（保持 12px）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const double natural = maxWeeks * (cell + spacing) - spacing; // 792
    await tester.pumpWidget(buildHeatmap(width: natural));
    await tester.pump();

    final Size size = tester.getSize(gridFinder());
    expect(size.width, natural);
    expect(size.height, 7 * cell + 6 * spacing);
  });

  testWidgets('格子放大后点击命中仍对齐绘制（今天 = 末列周三）', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final List<(String, int)> calls = <(String, int)>[];
    await tester.pumpWidget(buildHeatmap(
      width: 2000,
      onDaySelected: (String dateKey, int value) => calls.add((dateKey, value)),
    ));
    await tester.pump();

    // 放大后的步长 = maxCell + spacing；今天在末列（索引 52）、周三（行索引 2）。
    const double step = maxCell + spacing;
    await tester.tapAt(
      tester.getTopLeft(gridFinder()) +
          const Offset(
            (maxWeeks - 1) * step + maxCell / 2,
            2 * step + maxCell / 2,
          ),
    );
    await tester.pump();

    expect(calls, <(String, int)>[(todayKey, 123)]);
  });
}
