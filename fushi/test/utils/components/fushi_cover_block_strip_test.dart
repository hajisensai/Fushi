import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_cover_block.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';
import 'package:material_ui/material_ui.dart';

// 「继续」区（库页的继续阅读 / 继续观看 / 继续游戏）在封面色块版式下是一行半高
// 色块横滑（[FushiCoverBlockStrip] 的 leadingHero: false 排法）：不分主次、
// 不往下堆行，整段只占一行高（2026-11-12 用户：「继续阅读占空间太大了还是保持
// 跟之前一样侧滑」）。
void main() {
  const ValueKey<String> stripKey = ValueKey<String>('strip');

  Future<List<FushiCoverBlockSize>> pump(
    WidgetTester tester, {
    required double width,
    int count = 8,
  }) async {
    final List<FushiCoverBlockSize> sizes = <FushiCoverBlockSize>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: FushiCoverBlockStrip(
                leadingHero: false,
                staggerEntrance: false,
                stripKey: stripKey,
                itemCount: count,
                itemBuilder:
                    (BuildContext context, int i, FushiCoverBlockSize size) {
                      sizes.add(size);
                      return ColoredBox(
                        key: ValueKey<String>('block-$i'),
                        color: Colors.teal,
                      );
                    },
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return sizes;
  }

  testWidgets('宽屏：全部条目一行半高块横滑，整段只占一行高', (WidgetTester tester) async {
    final List<FushiCoverBlockSize> sizes = await pump(tester, width: 1200);
    expect(sizes, isNotEmpty);
    expect(
      sizes.every((FushiCoverBlockSize s) => s == FushiCoverBlockSize.half),
      isTrue,
    );
    expect(sizes, isNot(contains(FushiCoverBlockSize.hero)));
    expect(
      tester.getSize(find.byKey(stripKey)).height,
      FushiCoverBlockStrip.rowHeight(),
    );
    final Rect first = tester.getRect(
      find.byKey(const ValueKey<String>('block-0')),
    );
    final Rect second = tester.getRect(
      find.byKey(const ValueKey<String>('block-1')),
    );
    expect(first.width, kFushiCoverBlockStripTileWidth);
    expect(first.height, FushiCoverBlockStrip.rowHeight());
    // 同一行：第二块在第一块右边、顶边对齐。
    expect(second.top, first.top);
    expect(second.left, greaterThan(first.right));
    final ListView list = tester.widget<ListView>(find.byType(ListView));
    expect(list.scrollDirection, Axis.horizontal);
    expect(find.byType(GridView), findsNothing);
  });

  testWidgets('窄屏：仍是一行横滑，卡宽随窗宽收窄', (WidgetTester tester) async {
    final List<FushiCoverBlockSize> sizes = await pump(tester, width: 360);
    expect(
      sizes.every((FushiCoverBlockSize s) => s == FushiCoverBlockSize.half),
      isTrue,
    );
    expect(
      tester.getSize(find.byKey(stripKey)).height,
      FushiCoverBlockStrip.rowHeight(),
    );
    final Rect first = tester.getRect(
      find.byKey(const ValueKey<String>('block-0')),
    );
    expect(first.width, FushiCoverBlockStrip.compactTileWidth(360));
    expect(first.width, lessThan(kFushiCoverBlockStripTileWidth));
    expect(
      tester.widget<ListView>(find.byType(ListView)).scrollDirection,
      Axis.horizontal,
    );
  });

  testWidgets('只有一个条目：也是一块半高块，不升格成主块', (WidgetTester tester) async {
    final List<FushiCoverBlockSize> sizes = await pump(
      tester,
      width: 1200,
      count: 1,
    );
    expect(sizes, <FushiCoverBlockSize>[FushiCoverBlockSize.half]);
    expect(
      tester.getSize(find.byKey(stripKey)).height,
      FushiCoverBlockStrip.rowHeight(),
    );
  });

  // 2026-11-12 用户：「感觉一本书占太多位置了」——书架色块墙里单本书按
  // [kFushiCoverBlockTargetWidthSingle] 分栏，合集（isWideItem）占宽块。
  group('单本按 400 两端对齐、合集占宽块', () {
    List<FushiCoverBlockRow> plan(
      ShellContentLayout? layout,
      double width,
      int count, {
      Set<int> wide = const <int>{},
    }) => computeFushiCoverBlockPlan(
      width: width,
      itemCount: count,
      layout: layout,
      targetWidth: kFushiCoverBlockTargetWidthWide,
      narrowTargetWidth: kFushiCoverBlockTargetWidthSingle,
      isWideItem: wide.contains,
    );

    FushiCoverBlockCell cellOf(List<FushiCoverBlockRow> rows, int index) => rows
        .expand((FushiCoverBlockRow r) => r.cells)
        .firstWhere((FushiCoverBlockCell c) => c.index == index);

    test('拼贴：主块旁的半高卡宽度落在书名两行放得下的区间（不窄到 300 以下）', () {
      for (final double width in <double>[1100, 1300, 1400, 1700, 1900]) {
        final List<FushiCoverBlockRow> rows = plan(
          ShellContentLayout.collage,
          width,
          12,
        );
        final FushiCoverBlockCell half = cellOf(rows, 1);
        expect(half.size, FushiCoverBlockSize.half, reason: 'width $width');
        expect(
          half.rect.width,
          inInclusiveRange(330, 480),
          reason: 'width $width',
        );
        // 头部右侧铺满到行尾。
        final double right = rows.first.cells
            .map((FushiCoverBlockCell c) => c.rect.right)
            .reduce((double a, double b) => a > b ? a : b);
        expect(right, closeTo(width, 0.01), reason: 'width $width');
      }
    });

    test('等尺寸色块：单本约 400、合集约 600，整行两端对齐铺满', () {
      for (final double width in <double>[1000, 1300, 1600, 2000]) {
        final List<FushiCoverBlockRow> rows = plan(
          null,
          width,
          30,
          wide: <int>{2, 9, 15},
        );
        for (final FushiCoverBlockRow row in rows.take(rows.length - 1)) {
          expect(
            row.cells.last.rect.right,
            closeTo(width, 0.01),
            reason: 'width $width：非末行铺满整行',
          );
          for (final FushiCoverBlockCell cell in row.cells) {
            final bool isWide = <int>{2, 9, 15}.contains(cell.index);
            expect(
              cell.rect.width,
              isWide ? inInclusiveRange(480, 760) : inInclusiveRange(320, 500),
              reason: 'width $width index ${cell.index}',
            );
          }
        }
        expect(
          cellOf(rows, 2).rect.width,
          greaterThan(cellOf(rows, 0).rect.width * 1.3),
          reason: 'width $width：合集比单本宽',
        );
      }
    });

    test('末行放得下时不拉宽，保持自然宽', () {
      final List<FushiCoverBlockRow> rows = plan(null, 1300, 2);
      expect(rows, hasLength(1));
      expect(
        rows.single.cells.map((FushiCoverBlockCell c) => c.rect.width),
        <double>[
          kFushiCoverBlockTargetWidthSingle,
          kFushiCoverBlockTargetWidthSingle,
        ],
      );
    });

    test('不给 narrow 时与原排法一致（等宽块）', () {
      final List<FushiCoverBlockRow> rows = computeFushiCoverBlockPlan(
        width: 1300,
        itemCount: 4,
        layout: null,
        targetWidth: kFushiCoverBlockTargetWidthWide,
        isWideItem: (int i) => i == 1,
      );
      final Set<double> widths = rows
          .expand((FushiCoverBlockRow r) => r.cells)
          .map((FushiCoverBlockCell c) => c.rect.width)
          .toSet();
      expect(widths.length, 1);
    });
  });

  testWidgets('横滑行的滚动视口留足半高卡投影余量，投影不被裁出硬边', (WidgetTester tester) async {
    await pump(tester, width: 1200, count: 3);
    final Rect row = tester.getRect(find.byKey(stripKey));
    final Rect viewport = tester.getRect(
      find.descendant(
        of: find.byKey(stripKey),
        matching: find.byType(Scrollable),
      ),
    );
    expect(
      row.top - viewport.top,
      greaterThanOrEqualTo(kFushiCoverBlockHalfShadowExtent.top),
    );
    expect(
      viewport.bottom - row.bottom,
      greaterThanOrEqualTo(kFushiCoverBlockHalfShadowExtent.bottom),
    );
    final Rect first = tester.getRect(
      find.byKey(const ValueKey<String>('block-0')),
    );
    expect(first.top, row.top, reason: '内容起点不变');
    expect(first.left, row.left);
  });
}
