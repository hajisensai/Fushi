import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'reader_history_source_corpus.dart';

import 'package:hibiki/src/pages/implementations/reader_hibiki_history_page.dart';

/// 书本打标签后封面卡片渲染异常的回归测试。
///
/// 根因：标签覆盖层 `_adaptiveTagColumn` 用 `Positioned(top, left)`（无 bottom/
/// height）挂进封面卡片的 `Stack(fit: StackFit.expand)`，子树拿到 unbounded
/// `maxHeight == infinity`；旧实现 `(maxHeight * 0.55 / 22).floor()` 在 Infinity 上
/// 抛 `UnsupportedError: Infinity or NaN toInt`。覆盖层只在书本带 tag 时存在，故异常
/// 只在「打 tag 之后」出现，用户感知为封面展示异常。修复：纯函数 [adaptiveTagSlots]
/// 加 `isFinite` 守卫，无界时渲染全部标签。
void main() {
  group('adaptiveTagSlots', () {
    test('unbounded height renders all tags (no Infinity.floor throw)', () {
      // 修复前 (Infinity * 0.55 / 22).floor() 抛 UnsupportedError。
      expect(adaptiveTagSlots(maxHeight: double.infinity, tagCount: 1), 1);
      expect(adaptiveTagSlots(maxHeight: double.infinity, tagCount: 8), 8);
      // NaN 同属 non-finite，不得抛。
      expect(adaptiveTagSlots(maxHeight: double.nan, tagCount: 3), 3);
    });

    test('bounded height clamps to available slots (min 1)', () {
      expect(adaptiveTagSlots(maxHeight: 100, tagCount: 8),
          (100 * 0.55 / 22.0).floor().clamp(1, 8));
      expect(adaptiveTagSlots(maxHeight: 0, tagCount: 3), 1);
    });

    test('zero tags returns zero', () {
      expect(adaptiveTagSlots(maxHeight: double.infinity, tagCount: 0), 0);
    });
  });

  testWidgets(
      'tag column under Positioned(top,left) in StackFit.expand does not throw',
      (WidgetTester tester) async {
    int reportedSlots = -1;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 200,
            height: 300,
            child: Stack(
              fit: StackFit.expand,
              children: <Widget>[
                // 封面 sibling：StackFit.expand 下被强制满尺寸。
                const ColoredBox(key: Key('cover'), color: Colors.grey),
                // 标签覆盖层：只设 top+left → 拿到 unbounded 约束（复刻生产）。
                Positioned(
                  top: 6,
                  left: 6,
                  child: LayoutBuilder(
                    builder:
                        (BuildContext context, BoxConstraints constraints) {
                      reportedSlots = adaptiveTagSlots(
                        maxHeight: constraints.maxHeight,
                        tagCount: 3,
                      );
                      return Column(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          for (int i = 0; i < reportedSlots; i++)
                            const SizedBox(height: 22, child: Text('tag')),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    expect(tester.takeException(), isNull,
        reason: '无界约束下标签列不得抛 UnsupportedError: Infinity or NaN toInt');
    expect(reportedSlots, 3, reason: '无界约束应走 isFinite 守卫渲染全部标签');
    // 封面 sibling 仍按 Stack 全尺寸布局，不被标签层异常波及。
    expect(
        tester.getSize(find.byKey(const Key('cover'))), const Size(200, 300));
  });

  group('BUG-220 子2: 卡片标签竖排统一宽度(消除参差)', () {
    testWidgets('IntrinsicWidth + stretch 让不同文字宽度的标签 chip 渲染成同一宽度',
        (WidgetTester tester) async {
      // 复刻修复后的 _uniformWidthTagColumn 结构：用最宽 chip 决定列宽，
      // 其余被 stretch 拉到同宽（修复前用 crossAxisAlignment.start，
      // 各 chip 宽=自身文字宽 → 一行长一行短）。
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: IntrinsicWidth(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Container(key: const Key('a'), child: const Text('SF')),
                    Container(
                        key: const Key('b'),
                        child: const Text('A much longer tag name')),
                    Container(key: const Key('c'), child: const Text('x')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final double wA = tester.getSize(find.byKey(const Key('a'))).width;
      final double wB = tester.getSize(find.byKey(const Key('b'))).width;
      final double wC = tester.getSize(find.byKey(const Key('c'))).width;
      // 修复前三者宽度互不相等(参差)。修复后全部等于最宽 chip 的宽度。
      expect(wA, wB);
      expect(wC, wB);
      expect(wB, greaterThan(0));
    });
  });

  group('BUG-220 子2 源码守卫', () {
    test('_adaptiveTagColumn 走统一宽度列(IntrinsicWidth + stretch)而非裸 start 列', () {
      final String source = readReaderHistorySource();
      // 统一宽度 helper 存在且用 IntrinsicWidth + stretch。
      expect(source, contains('Widget _uniformWidthTagColumn('));
      expect(source, contains('IntrinsicWidth('));
      expect(source, contains('CrossAxisAlignment.stretch'));
      // _adaptiveTagColumn 不再直接构造 start 对齐的标签列(防参差回归)。
      final int start = source.indexOf('Widget _adaptiveTagColumn(');
      final int end = source.indexOf('Widget _uniformWidthTagColumn(');
      expect(start, isNonNegative);
      expect(end, greaterThan(start));
      final String body = source.substring(start, end);
      expect(body, isNot(contains('CrossAxisAlignment.start')),
          reason: '_adaptiveTagColumn 不得再用 start 对齐的 Column(那是参差根因)');
      expect(body, contains('_uniformWidthTagColumn('));
    });
  });
}
