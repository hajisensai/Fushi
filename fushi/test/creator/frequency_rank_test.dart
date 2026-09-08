import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

// 词频 rank 纯函数：制卡字段 `{frequency-harmonic-rank}` 与卡组新卡重排共用
// 这一份取值 / 复合规则。数值口径钉死在这里，两处消费方不再各写一份。

void main() {
  group('frequencyRankOf', () {
    test('displayValue 前导数字优先于 value', () {
      expect(frequencyRankOf(3, '1234㋕'), 1234);
      expect(frequencyRankOf(3, '42'), 42);
    });

    test('display 没有前导数字时用 value；都不是正整数则无', () {
      expect(frequencyRankOf(77, 'rare'), 77);
      expect(frequencyRankOf(0, ''), isNull);
      expect(frequencyRankOf(-5, 'x'), isNull);
      expect(frequencyRankOf(0, '0'), isNull, reason: '0 不是名次');
    });
  });

  test('dictionaryFrequencyRank 取一本词典内的最小值', () {
    expect(
      dictionaryFrequencyRank(const <FushiFrequency>[
        FushiFrequency(value: 900, displayValue: ''),
        FushiFrequency(value: 120, displayValue: '120'),
        FushiFrequency(value: 0, displayValue: ''),
      ]),
      120,
    );
    expect(dictionaryFrequencyRank(const <FushiFrequency>[]), isNull);
  });

  group('aggregateFrequencyRanks', () {
    test('调和平均 = floor(n / Σ1/v)，与 Yomitan 一致', () {
      // 2 / (1/100 + 1/300) = 150
      expect(
          aggregateFrequencyRanks(<int>[100, 300], FrequencyAggregate.harmonic),
          150);
      // 3 / (1/10 + 1/20 + 1/40) = 17.14 → 17
      expect(
          aggregateFrequencyRanks(
              <int>[10, 20, 40], FrequencyAggregate.harmonic),
          17);
    });

    test('取最小', () {
      expect(aggregateFrequencyRanks(<int>[100, 300], FrequencyAggregate.min),
          100);
    });

    test('只有一本时两种模式都退化成该值；空表为 null', () {
      for (final FrequencyAggregate m in FrequencyAggregate.values) {
        expect(aggregateFrequencyRanks(<int>[250], m), 250);
        expect(aggregateFrequencyRanks(<int>[], m), isNull);
      }
    });

    test('fromName 认名字，未知回落调和平均', () {
      expect(FrequencyAggregate.fromName('min'), FrequencyAggregate.min);
      expect(FrequencyAggregate.fromName(null), FrequencyAggregate.harmonic);
      expect(FrequencyAggregate.fromName('zzz'), FrequencyAggregate.harmonic);
    });
  });
}
