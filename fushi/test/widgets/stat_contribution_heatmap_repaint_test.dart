import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/stat_contribution_heatmap.dart';

/// BUG-1917：桌面拖边缩放时首页仪表盘每步都重画整张热力图。
///
/// 根因是 [StatHeatmapModel] 只有身份相等：`buildStatHeatmap` 每次 build 造新对象，
/// `_HeatmapPainter.shouldRepaint` 的 `old.model != model` 永远为真，RepaintBoundary
/// 缓存层每步作废，364 格 × 2 个圆角矩形全部重画。这里从两层守住：
/// 1. 模型必须值语义相等（同输入两次构造相等、任一格值变则不等）；
/// 2. 宿主重建（换底色 + 微调宽度但列数不变）后，构建 + 布局完成、绘制开始前，
///    网格 `RenderCustomPaint.debugNeedsPaint` 必须为假（shouldRepaint 没被触发）；
///    真改一天的值则必须为真。
void main() {
  final DateTime now = DateTime(2026, 8, 28, 12);
  final Map<String, int> values = <String, int>{
    '2026-08-27': 120,
    '2026-08-20': 60,
    '2026-07-01': 300,
  };

  group('BUG-1917 heatmap model value equality', () {
    test('same inputs build equal models', () {
      final StatHeatmapModel a = buildStatHeatmap(
        valueByDateKey: values,
        now: now,
        weeks: 30,
      );
      final StatHeatmapModel b = buildStatHeatmap(
        valueByDateKey: Map<String, int>.of(values),
        now: now,
        weeks: 30,
      );
      expect(identical(a, b), isFalse);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });

    test('a changed day value makes models unequal', () {
      final StatHeatmapModel a = buildStatHeatmap(
        valueByDateKey: values,
        now: now,
        weeks: 30,
      );
      final StatHeatmapModel b = buildStatHeatmap(
        valueByDateKey: <String, int>{...values, '2026-08-20': 61},
        now: now,
        weeks: 30,
      );
      expect(a, isNot(equals(b)));
    });

    test('a different week count makes models unequal', () {
      final StatHeatmapModel a = buildStatHeatmap(
        valueByDateKey: values,
        now: now,
        weeks: 30,
      );
      final StatHeatmapModel b = buildStatHeatmap(
        valueByDateKey: values,
        now: now,
        weeks: 31,
      );
      expect(a, isNot(equals(b)));
    });
  });

  testWidgets(
    'BUG-1917 a full-year grid is drawn with a handful of Skia ops, not one per cell',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // 一年 53 列都是真实日（now 取周日，末列 7 天全过去），每天都有值 → 每个
      // 等级都非空，空格描边也非空：逐格画法在这里是 371 个 fill + 空格 stroke。
      final Map<String, int> year = <String, int>{};
      final DateTime sunday = DateTime(2026, 8, 30, 12);
      for (int i = 0; i < 53 * 7; i++) {
        final DateTime d = sunday.subtract(Duration(days: i));
        year['${d.year.toString().padLeft(4, '0')}-'
            '${d.month.toString().padLeft(2, '0')}-'
            '${d.day.toString().padLeft(2, '0')}'] = i % 5 == 0
            ? 0
            : i % 5 * 25;
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 1110,
                child: StatContributionHeatmap(
                  valueByDateKey: year,
                  now: sunday,
                  baseColor: Colors.green,
                  emptyColor: const Color(0xFFEEEEEE),
                  emptyBorderColor: const Color(0xFFCCCCCC),
                  valueLabel: (String k, int v) => '$k $v',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final Finder gridPaint = find
          .descendant(
            of: find
                .descendant(
                  of: find.byType(StatContributionHeatmap),
                  matching: find.byType(RepaintBoundary),
                )
                .first,
            matching: find.byType(CustomPaint),
          )
          .first;
      int rrects = 0;
      int paths = 0;
      expect(
        tester.renderObject(gridPaint),
        paints..everything((Symbol method, List<dynamic> args) {
          if (method == #drawRRect) rrects++;
          if (method == #drawPath) paths++;
          return true;
        }),
      );
      // 5 个等级 + 1 条空格描边；选中框（drawRRect）此时没有。
      expect(
        paths,
        inInclusiveRange(1, 6),
        reason: 'cells must be batched per level into paths',
      );
      expect(
        rrects,
        0,
        reason:
            'no per-cell drawRRect — the raster thread replays every op '
            'of the retained picture on each resize step',
      );
    },
  );

  testWidgets(
    'BUG-1917 host rebuild with unchanged grid does not repaint the heatmap layer',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final Map<String, int> hostValues = Map<String, int>.of(values);
      late StateSetter setHost;
      double hostWidth = 600;
      Color hostColor = Colors.white;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                setHost = setState;
                return ColoredBox(
                  color: hostColor,
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: hostWidth,
                      child: StatContributionHeatmap(
                        valueByDateKey: hostValues,
                        now: now,
                        baseColor: Colors.green,
                        emptyColor: const Color(0xFFEEEEEE),
                        emptyBorderColor: const Color(0xFFCCCCCC),
                        valueLabel: (String k, int v) => '$k $v',
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pump();

      final Finder gridPaint = find
          .descendant(
            of: find
                .descendant(
                  of: find.byType(StatContributionHeatmap),
                  matching: find.byType(RepaintBoundary),
                )
                .first,
            matching: find.byType(CustomPaint),
          )
          .first;
      final RenderCustomPaint grid = tester.renderObject<RenderCustomPaint>(
        gridPaint,
      );
      expect(grid.debugNeedsPaint, isFalse);

      // 宿主重建：换底色让父级必须重画；宽度 600→605 仍是同一列数
      // （(w+3)/15 都取整到 40），所以网格内容完全不变——模拟拖边缩放的一步。
      setHost(() {
        hostWidth = 605;
        hostColor = Colors.black;
      });
      // 只推进到「构建 + 布局」，在绘制阶段之前读 debugNeedsPaint：
      // CustomPaint 换 painter 时只有 shouldRepaint 为真才会 markNeedsPaint。
      tester.binding.buildOwner!.buildScope(tester.binding.rootElement!);
      tester.binding.rootPipelineOwner.flushLayout();
      expect(
        grid.debugNeedsPaint,
        isFalse,
        reason:
            'an unchanged heatmap must not be marked for repaint on a host '
            'rebuild, or every resize step redraws hundreds of rounded rects',
      );
      await tester.pump();

      // 对照：真的改一天的值，同一条路径必须判「要重画」。
      setHost(() => hostColor = Colors.white);
      await tester.pump();
      hostValues['2026-08-20'] = 61;
      setHost(() => hostColor = Colors.black);
      tester.binding.buildOwner!.buildScope(tester.binding.rootElement!);
      tester.binding.rootPipelineOwner.flushLayout();
      expect(grid.debugNeedsPaint, isTrue);
      await tester.pump();
    },
  );
}
