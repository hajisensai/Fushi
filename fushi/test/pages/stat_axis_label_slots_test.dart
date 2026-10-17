import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';

/// 2026-10-04 用户截图：「统计中心 › 总览」时长柱状图在手机上末尾两个日期标签
/// 压在一起（「09-07」与强制补画的末柱「09-28」重叠），且末柱标签伸出画布右缘。
/// [statXAxisLabelSlots] 按实测宽度排布横轴标签，钉住三条不变式。
void main() {
  void expectNoOverlapInside(
    List<StatAxisLabelSlot> slots,
    double width,
    double minX,
    double maxX,
  ) {
    for (int k = 1; k < slots.length; k++) {
      expect(
        slots[k - 1].left + width,
        lessThanOrEqualTo(slots[k].left),
        reason: '标签 ${slots[k - 1].index} 与 ${slots[k].index} 重叠',
      );
    }
    for (final StatAxisLabelSlot s in slots) {
      expect(s.left, greaterThanOrEqualTo(minX));
      expect(s.left + width, lessThanOrEqualTo(maxX));
    }
  }

  test('手机宽度 40 根柱：不重叠、不出界、末柱恒标', () {
    // 截图同形：约 390dp 屏、左轴 36、40 周柱、标签「MM-DD」约 44px 宽。
    const int count = 40;
    const double leftPadding = 36;
    const double maxX = 350;
    const double labelWidth = 44;
    const double step = (maxX - leftPadding) / count;
    final List<StatAxisLabelSlot> slots = statXAxisLabelSlots(
      count: count,
      minEvery: (count / 7).ceil(),
      centerOf: (int i) => leftPadding + i * step + step / 2,
      widthOf: (_) => labelWidth,
      minX: leftPadding - 4,
      maxX: maxX,
    );
    expect(slots.last.index, count - 1, reason: '最新一根必须有标签');
    expect(slots.first.index, 0);
    expectNoOverlapInside(slots, labelWidth, leftPadding - 4, maxX);
  });

  test('末柱紧挨上一个抽中的柱时让掉前一个，而不是叠画', () {
    // 10 根、每 3 根标一个 → 0,3,6,9：末柱 9 天然在网格上；改 11 根 → 0,3,6,9,10，
    // 9 与 10 相撞，应让掉 9。
    const double step = 30;
    final List<StatAxisLabelSlot> slots = statXAxisLabelSlots(
      count: 11,
      minEvery: 3,
      centerOf: (int i) => i * step + step / 2,
      widthOf: (_) => 40,
      minX: 0,
      maxX: 11 * step,
    );
    expect(slots.map((StatAxisLabelSlot s) => s.index), <int>[0, 3, 6, 10]);
    expectNoOverlapInside(slots, 40, 0, 11 * step);
  });

  test('宽画布不额外抽稀：保持调用方给的最小步长', () {
    final List<StatAxisLabelSlot> slots = statXAxisLabelSlots(
      count: 7,
      minEvery: 1,
      centerOf: (int i) => i * 100.0 + 50,
      widthOf: (_) => 40,
      minX: 0,
      maxX: 700,
    );
    expect(slots.length, 7);
  });

  test('极窄画布只标最新一根', () {
    final List<StatAxisLabelSlot> slots = statXAxisLabelSlots(
      count: 5,
      minEvery: 1,
      centerOf: (int i) => i * 10.0 + 5,
      widthOf: (_) => 40,
      minX: 0,
      maxX: 50,
    );
    expect(slots.single.index, 4);
    expect(slots.single.left + 40, lessThanOrEqualTo(50));
  });
}
