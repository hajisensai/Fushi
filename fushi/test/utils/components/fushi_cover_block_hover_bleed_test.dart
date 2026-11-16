import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/utils/components/fushi_cover_block_layout.dart';

/// 色块悬停余量吃进页边距（2026-11-16 合集详情：色块成员墙比页边再缩进一截）：
/// [computeFushiCoverBlockPlacement] 的 `hoverBleed` 是块外已有的空白，只有超出
/// 它的溢出量才往行里留边；够用时行首块贴着 sliver 起点，与页面其它内容同一条竖线。
void main() {
  FushiCoverBlockPlacement place(double bleed) =>
      computeFushiCoverBlockPlacement(
        width: 900,
        itemCount: 1,
        layout: null,
        targetWidth: kFushiCoverBlockTargetWidthSingle,
        hoverBleed: bleed,
      );

  test('不给页边余量：两侧照旧留出悬停溢出', () {
    expect(place(0).inset, greaterThan(0));
  });

  test('页边余量够用：不再往行里留边，块从 sliver 起点排', () {
    final FushiCoverBlockPlacement p = place(200);
    expect(p.inset, 0);
    expect(p.rows.first.cells.first.rect.left, 0);
  });

  test('页边余量不够：只留超出的那部分', () {
    final double full = place(0).inset;
    final double partial = place(full / 2).inset;
    expect(partial, lessThan(full));
    expect(partial, greaterThan(0));
  });
}
