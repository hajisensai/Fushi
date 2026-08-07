import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/utils/components/stat_contribution_heatmap.dart';

Future<({ui.Image image, ByteData bytes})> _captureGridImage(
  WidgetTester tester,
  Finder grid, {
  double pixelRatio = 1,
}) async {
  final Finder repaint = find
      .descendant(
        of: grid,
        matching: find.byType(RepaintBoundary),
      )
      .first;
  final RenderRepaintBoundary boundary =
      tester.renderObject<RenderRepaintBoundary>(repaint);
  expect(boundary.debugNeedsPaint, isFalse);

  final ({ui.Image image, ByteData bytes})? raster =
      await tester.runAsync(() async {
    final ui.Image image = boundary.toImageSync(pixelRatio: pixelRatio);
    final ByteData? bytes =
        await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(bytes, isNotNull);
    return (image: image, bytes: bytes!);
  });
  expect(raster, isNotNull);
  return raster!;
}

Color _pixelAt(
  ({ui.Image image, ByteData bytes}) raster,
  int logicalX,
  int logicalY, {
  double pixelRatio = 1,
}) {
  final int x = (logicalX * pixelRatio).round();
  final int y = (logicalY * pixelRatio).round();
  final int offset = (y * raster.image.width + x) * 4;
  return Color.fromARGB(
    raster.bytes.getUint8(offset + 3),
    raster.bytes.getUint8(offset),
    raster.bytes.getUint8(offset + 1),
    raster.bytes.getUint8(offset + 2),
  );
}

int _red(Color color) => (color.toARGB32() >> 16) & 0xff;
int _green(Color color) => (color.toARGB32() >> 8) & 0xff;
int _blue(Color color) => color.toARGB32() & 0xff;
int _alpha(Color color) => (color.toARGB32() >> 24) & 0xff;

void _expectNearColor(
  Color actual,
  Color expected, {
  int tolerance = 3,
  String? reason,
}) {
  expect(
    (_red(actual) - _red(expected)).abs(),
    lessThanOrEqualTo(tolerance),
    reason: reason,
  );
  expect(
    (_green(actual) - _green(expected)).abs(),
    lessThanOrEqualTo(tolerance),
    reason: reason,
  );
  expect(
    (_blue(actual) - _blue(expected)).abs(),
    lessThanOrEqualTo(tolerance),
    reason: reason,
  );
  expect(
    (_alpha(actual) - _alpha(expected)).abs(),
    lessThanOrEqualTo(tolerance),
    reason: reason,
  );
}

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
    Map<String, int>? valueByDateKey,
    Color backgroundColor = Colors.white,
    Color emptyColor = Colors.grey,
    Color baseColor = Colors.green,
    Color? emptyBorderColor,
    void Function(String, int)? onDaySelected,
  }) {
    return MaterialApp(
      home: Scaffold(
        backgroundColor: backgroundColor,
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            key: const ValueKey<String>('heatmap-host'),
            width: width,
            child: StatContributionHeatmap(
              valueByDateKey: valueByDateKey ?? <String, int>{todayKey: 123},
              now: now,
              baseColor: baseColor,
              emptyColor: emptyColor,
              emptyBorderColor: emptyBorderColor,
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

  testWidgets('BUG-1276：空格四边内描边可见、中心仍黑且 spacing 不受污染',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildHeatmap(
      width: maxWeeks * (cell + spacing) - spacing,
      valueByDateKey: <String, int>{todayKey: 4},
      backgroundColor: Colors.black,
      emptyColor: Colors.black,
      emptyBorderColor: Colors.white,
    ));
    await tester.pump();

    final ({ui.Image image, ByteData bytes}) raster =
        await _captureGridImage(tester, gridFinder());
    addTearDown(raster.image.dispose);
    for (final (int x, int y) in <(int, int)>[
      (6, 0),
      (6, 11),
      (0, 6),
      (11, 6),
    ]) {
      final Color edge = _pixelAt(raster, x, y);
      expect(_red(edge), greaterThan(220), reason: 'edge ($x,$y)');
      expect(_green(edge), greaterThan(220), reason: 'edge ($x,$y)');
      expect(_blue(edge), greaterThan(220), reason: 'edge ($x,$y)');
      expect(_alpha(edge), greaterThan(220), reason: 'edge ($x,$y)');
    }
    _expectNearColor(_pixelAt(raster, 6, 6), Colors.black);

    // 下一格从 x=15 开始；内收描边可占 x=15，但不得泄漏到 spacing 的 x=14。
    expect(_alpha(_pixelAt(raster, 14, 6)), 0);
  });

  testWidgets('BUG-1276：active levels 1..4 不得收到 level-0 outline',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final DateTime previousMonday = DateTime(2026, 7, 6);
    await tester.pumpWidget(buildHeatmap(
      width: maxWeeks * (cell + spacing) - spacing,
      valueByDateKey: <String, int>{
        for (int row = 0; row < 4; row++)
          statDateKey(previousMonday.add(Duration(days: row))): row + 1,
      },
      backgroundColor: Colors.black,
      emptyColor: Colors.black,
      baseColor: Colors.green,
      emptyBorderColor: Colors.white,
    ));
    await tester.pump();

    final ({ui.Image image, ByteData bytes}) raster =
        await _captureGridImage(tester, gridFinder());
    addTearDown(raster.image.dispose);
    const int activeColumnCenter = 51 * 15 + 6;
    for (int row = 0; row < 4; row++) {
      final int top = row * 15;
      final Color edge = _pixelAt(raster, activeColumnCenter, top);
      final Color center = _pixelAt(raster, activeColumnCenter, top + 6);
      _expectNearColor(edge, center, reason: 'active level ${row + 1}');
      expect(_red(edge), lessThan(100), reason: 'active level ${row + 1}');
      expect(_blue(edge), lessThan(100), reason: 'active level ${row + 1}');
    }
  });

  testWidgets('BUG-1276：null border 保持旧的纯填充像素', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const Color legacyEmpty = Color(0xff242424);
    await tester.pumpWidget(buildHeatmap(
      width: maxWeeks * (cell + spacing) - spacing,
      valueByDateKey: <String, int>{todayKey: 4},
      backgroundColor: legacyEmpty,
      emptyColor: legacyEmpty,
    ));
    await tester.pump();

    final ({ui.Image image, ByteData bytes}) raster =
        await _captureGridImage(tester, gridFinder());
    addTearDown(raster.image.dispose);
    _expectNearColor(_pixelAt(raster, 6, 0), legacyEmpty);
    _expectNearColor(_pixelAt(raster, 6, 6), legacyEmpty);
    _expectNearColor(_pixelAt(raster, 0, 6), legacyEmpty);
  });

  testWidgets('BUG-1276：dark、light 与 e-ink 调色板保持 fill/outline 角色',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    for (final ({
      String label,
      Color background,
      Color empty,
      Color border,
    }) palette in <({
      String label,
      Color background,
      Color empty,
      Color border,
    })>[
      (
        label: 'dark',
        background: const Color(0xff000000),
        empty: const Color(0xff000000),
        border: const Color(0xff777777),
      ),
      (
        label: 'light',
        background: const Color(0xfffafafa),
        empty: const Color(0xfffafafa),
        border: const Color(0xff666666),
      ),
      (
        label: 'e-ink',
        background: const Color(0xffffffff),
        empty: const Color(0xffffffff),
        border: const Color(0xff000000),
      ),
    ]) {
      await tester.pumpWidget(buildHeatmap(
        width: maxWeeks * (cell + spacing) - spacing,
        valueByDateKey: <String, int>{todayKey: 4},
        backgroundColor: palette.background,
        emptyColor: palette.empty,
        emptyBorderColor: palette.border,
      ));
      await tester.pump();

      final ({ui.Image image, ByteData bytes}) raster =
          await _captureGridImage(tester, gridFinder());
      addTearDown(raster.image.dispose);
      _expectNearColor(
        _pixelAt(raster, 6, 6),
        palette.empty,
        reason: '${palette.label} center',
      );
      _expectNearColor(
        _pixelAt(raster, 6, 0),
        palette.border,
        tolerance: 12,
        reason: '${palette.label} edge',
      );
    }
  });

  testWidgets('BUG-1276：常见 raster DPR 下 outline 保持可见且中心不变亮',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(buildHeatmap(
      width: maxWeeks * (cell + spacing) - spacing,
      valueByDateKey: <String, int>{todayKey: 4},
      backgroundColor: Colors.black,
      emptyColor: Colors.black,
      emptyBorderColor: Colors.white,
    ));
    await tester.pump();

    for (final double dpr in <double>[1, 1.25, 2, 3]) {
      final ({ui.Image image, ByteData bytes}) raster = await _captureGridImage(
        tester,
        gridFinder(),
        pixelRatio: dpr,
      );
      addTearDown(raster.image.dispose);
      final Color edge = _pixelAt(raster, 6, 0, pixelRatio: dpr);
      expect(_red(edge), greaterThan(180), reason: 'DPR=$dpr');
      expect(_alpha(edge), greaterThan(180), reason: 'DPR=$dpr');
      _expectNearColor(
        _pixelAt(raster, 6, 6, pixelRatio: dpr),
        Colors.black,
        reason: 'DPR=$dpr center',
      );
    }
  });

  testWidgets('BUG-1276：窄屏、53周自然宽与超宽布局均有界且无溢出', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(2400, 1000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const double natural = maxWeeks * (cell + spacing) - spacing;
    for (final double width in <double>[120, natural, 2000]) {
      await tester.pumpWidget(buildHeatmap(
        width: width,
        valueByDateKey: <String, int>{todayKey: 4},
        backgroundColor: Colors.black,
        emptyColor: Colors.black,
        emptyBorderColor: Colors.white,
      ));
      await tester.pump();

      expect(tester.takeException(), isNull, reason: 'width=$width');
      expect(
        tester
            .getSize(find.byKey(const ValueKey<String>('heatmap-host')))
            .width,
        width,
      );
      final Size grid = tester.getSize(gridFinder());
      expect(grid.width, lessThanOrEqualTo(1110), reason: 'width=$width');
      expect(grid.height, lessThanOrEqualTo(144), reason: 'width=$width');
    }
  });
}
