/// 词频 rank 的纯计算：单条值 → rank、多本词典 → 复合 rank。
///
/// 这里是「按词频排序」语义的唯一真相：制卡字段 `{frequency-harmonic-rank}`
/// （`FrequencyField`）与 Anki 卡组新卡重排（`AnkiDeckReposition`）共用同一套
/// 取值与复合规则，两处不再各写一份调和平均。
library;

import '../engine/fushidicts.dart' show FushiFrequency;

/// 多本词频词典的复合方式。
enum FrequencyAggregate {
  /// 调和平均（Yomitan `frequency-harmonic-rank` 同款）：
  /// `floor(n / Σ(1/rank))`。默认。
  harmonic,

  /// 取最小：任一词典认为常见就按常见算。
  min;

  static FrequencyAggregate fromName(String? name) => FrequencyAggregate.values
      .firstWhere((FrequencyAggregate v) => v.name == name,
          orElse: () => FrequencyAggregate.harmonic);
}

/// 一条词频值对应的排序 rank。
///
/// [display] 的前导数字优先（JPDB 之类词典把 `value` 当序号、真实名次写在
/// `displayValue` 里），其次 [value]；两者都不是正整数则视为没有 rank。
int? frequencyRankOf(int value, String display) {
  final RegExpMatch? m = RegExp(r'^\d+').firstMatch(display);
  if (m != null) {
    final int? parsed = int.tryParse(m.group(0)!);
    if (parsed != null && parsed > 0) return parsed;
  }
  return value > 0 ? value : null;
}

/// 一本词典内多条值（不同读音 / 形态）取**最小** rank；无可用值返回 null。
int? dictionaryFrequencyRank(Iterable<FushiFrequency> frequencies) {
  int? best;
  for (final FushiFrequency f in frequencies) {
    final int? r = frequencyRankOf(f.value, f.displayValue);
    if (r != null && (best == null || r < best)) best = r;
  }
  return best;
}

/// 多本词典的 rank 按 [mode] 复合；[ranks] 为空返回 null。
///
/// 只勾一本时两种模式都退化成该本的值。
int? aggregateFrequencyRanks(List<int> ranks, FrequencyAggregate mode) {
  if (ranks.isEmpty) return null;
  // 只有一本：调和平均在数学上就等于它本身，但 1/(1.0/n) 的浮点往返会把
  // 1..100000 里 5850 个整数（93 / 99 / 105 / 117 …）算成 n-1。直接短路。
  if (ranks.length == 1) return ranks.single;
  switch (mode) {
    case FrequencyAggregate.min:
      return ranks.reduce((int a, int b) => a < b ? a : b);
    case FrequencyAggregate.harmonic:
      final double reciprocalSum =
          ranks.fold<double>(0, (double sum, int v) => sum + 1 / v);
      final double mean = ranks.length / reciprocalSum;
      // 同一个浮点误差在多本时同样存在（[10,15] 真值 12，裸 floor 给 11）。
      // 落在整数的 1e-9 邻域内就吸附回去，再向下取整。
      // 这个数以前只是制卡的展示字段，误差无害；现在它是新卡队列的**排序键**，
      // 算小 1 会让本该有序的两个词并成 tie、退回旧 due 序，而且
      // source: field 与 source: dictionaries 会给同一张卡不同的数。
      final double nearest = mean.roundToDouble();
      if ((mean - nearest).abs() <= 1e-9 * (nearest.abs() + 1)) {
        return nearest.toInt();
      }
      return mean.floor();
  }
}
