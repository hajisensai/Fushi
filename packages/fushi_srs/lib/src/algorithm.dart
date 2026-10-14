/// 排程算法。只支持 FSRS-7 / FSRS-6（用户 2026-10-14 定，不做 RWKV）。
///
/// 持久化名是 [wire]，冻结；不认识的值（更新版本的 app 写来的）原样保留、不改写，
/// 本机按 [srsLocalAlgorithmFallbackOrder] 取第一个能用的算法排程（铁律 F）。
enum SrsAlgorithm {
  fsrs7('fsrs7', 34),
  fsrs6('fsrs6', 21);

  const SrsAlgorithm(this.wire, this.paramCount);

  final String wire;
  final int paramCount;

  static SrsAlgorithm? tryParse(String? wire) {
    for (final SrsAlgorithm a in values) {
      if (a.wire == wire) return a;
    }
    return null;
  }
}

/// 回退顺序只在这里写一次：fsrs7 → fsrs6。
const List<SrsAlgorithm> srsLocalAlgorithmFallbackOrder = <SrsAlgorithm>[
  SrsAlgorithm.fsrs7,
  SrsAlgorithm.fsrs6,
];

/// 新建牌组的默认算法。
const SrsAlgorithm srsDefaultAlgorithm = SrsAlgorithm.fsrs7;

/// 牌组设置里的算法字段（可能是本机不认识的 wire 值）解析成本机实际用来排程的算法。
SrsAlgorithm resolveLocalAlgorithm(String? wire) {
  final SrsAlgorithm? known = SrsAlgorithm.tryParse(wire);
  if (known != null) return known;
  return srsLocalAlgorithmFallbackOrder.first;
}
