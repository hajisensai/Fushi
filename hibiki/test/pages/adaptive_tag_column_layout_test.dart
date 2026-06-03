import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
