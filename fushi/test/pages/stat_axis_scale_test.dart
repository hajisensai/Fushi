import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/stat_charts.dart';

/// 守卫柱状图纵轴刻度表 [StatAxisScale] 的三条不变式。
///
/// 事故：旧实现把数据最大值直接四等分（`maxValue * i / 4`）再让**每个刻度各自**
/// 挑单位，于是「最近 30 天」图上出现 `2.9h / 2.2h / 1.5h / 43m` —— 非整数、且同
/// 一条轴上 h 与 m 混用。三个域 tab 各自的 max 不同，混法还各不相同（`3.4h…51m`、
/// `1.4h…20m`），横着看四个 tab 完全对不上。
///
/// 现在刻度是整条轴的属性：步长取自然值 → 刻度恒为步长整数倍 → 标签恒为整数，
/// 且整条轴共用一个单位。
void main() {
  /// 一条轴上出现的单位后缀集合（`0` 无单位，不计）。
  Set<String> unitsOf(StatAxisScale scale) => <String>{
        for (final String label in scale.labels)
          if (label != '0') label.replaceAll(RegExp(r'^[\d.]+'), ''),
      };

  group('statDurationAxisScale', () {
    test('整条轴只有一个单位，且刻度全是整数（旧实现出 2.9h/43m 混排）', () {
      // 截图里三个 tab 的真实 max：2.9h / 3.4h / 1.4h。
      for (final int maxMs in <int>[10440000, 12240000, 5040000]) {
        final StatAxisScale scale = statDurationAxisScale(maxMs);
        expect(unitsOf(scale).length, 1,
            reason: 'maxMs=$maxMs 的轴混用了单位：${scale.labels}');
        for (final String label in scale.labels) {
          expect(label.contains('.'), isFalse,
              reason: 'maxMs=$maxMs 的刻度出现小数：$label');
        }
      }
    });

    test('轴顶盖住数据最大值，刻度等距升序、首项为 0', () {
      for (final int maxMs in <int>[0, 1, 45000, 90000, 5040000, 12240000]) {
        final StatAxisScale scale = statDurationAxisScale(maxMs);
        expect(scale.ticks.first, 0);
        expect(scale.max, greaterThanOrEqualTo(maxMs));
        expect(scale.max, greaterThan(0), reason: '轴顶为 0 会让柱高除零');
        final int step = scale.ticks[1];
        for (int i = 0; i < scale.ticks.length; i++) {
          expect(scale.ticks[i], step * i);
        }
        expect(scale.ticks.length, scale.labels.length);
      }
    });

    test('标签不重复（BUG-892 的「…2h 2h」在新范式下结构上不可能出现）', () {
      for (final int maxMs in <int>[10200000, 5040000, 90000, 3600000]) {
        final StatAxisScale scale = statDurationAxisScale(maxMs);
        expect(scale.labels.toSet().length, scale.labels.length,
            reason: 'maxMs=$maxMs 出现重复标签：${scale.labels}');
      }
    });

    test('不足 1 分钟走秒，不再整除成一排 0m', () {
      final StatAxisScale scale = statDurationAxisScale(90000);
      expect(unitsOf(scale).single, 's');
      expect(scale.labels.where((String l) => l != '0'), isNotEmpty);
    });

    test('半小时步长走分钟而不是 0.5h', () {
      // max=1.4h → 步长 30m、轴顶 2h。按轴顶选单位会得到 0.5h/1h/1.5h/2h；
      // 按步长选单位得到整数分钟。
      final StatAxisScale scale = statDurationAxisScale(5040000);
      expect(scale.labels, <String>['0', '30m', '60m', '90m', '120m']);
    });
  });

  group('statCountAxisScale', () {
    test('步长取 1/2/5 × 10^n，刻度等距且盖住最大值', () {
      for (final int maxValue in <int>[0, 7, 2224, 68000, 909000]) {
        final StatAxisScale scale = statCountAxisScale(maxValue);
        expect(scale.ticks.first, 0);
        expect(scale.max, greaterThanOrEqualTo(maxValue));
        expect(scale.max, greaterThan(0));
        final int step = scale.ticks[1];
        final String digits = step.toString().replaceAll(RegExp(r'0+$'), '');
        expect(<String>['1', '2', '5'].contains(digits), isTrue,
            reason: 'maxValue=$maxValue 的步长 $step 不是 1/2/5 × 10^n');
        for (int i = 0; i < scale.ticks.length; i++) {
          expect(scale.ticks[i], step * i);
        }
      }
    });
  });
}
