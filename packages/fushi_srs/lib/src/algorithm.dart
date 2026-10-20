/// 排程算法：FSRS-7 / FSRS-6 / RWKV-Instant。
///
/// RWKV-Instant（2026-10-19 用户定支持，只做 Instant 不做 Curve）：原生推理库在
/// native/fushi_rwkv（AGPL-3.0-or-later），Dart 绑定 packages/fushi_rwkv。它只给 R（回忆概率），
/// 间隔在作答时由「以该评分作答后 R 第一次 ≤ 目标保留率的天数」外推（见
/// `SrsCardOps.preview` 的 `rwkvIntervalDays`）；记忆状态（stability / difficulty，出队排序与统计
/// 用）照旧由 FSRS-7 维护，见 [SrsAlgorithm.memoryAlgorithm]。
///
/// 持久化名是 [wire]，冻结；不认识的值（更新版本的 app 写来的）原样保留、不改写，
/// 本机按 [srsLocalAlgorithmFallbackOrder] 取第一个能用的算法排程（铁律 F）。
enum SrsAlgorithm {
  fsrs7('fsrs7', 34),
  fsrs6('fsrs6', 21),

  /// 参数组是 FSRS-7 的（影子记忆状态用）。
  rwkv('rwkv', 34);

  const SrsAlgorithm(this.wire, this.paramCount);

  final String wire;
  final int paramCount;

  /// 维护记忆状态（stability / difficulty）的 FSRS 算法：RWKV 用 FSRS-7，其余是自己。
  /// 凡是交给 FSRS 引擎的调用都用它。
  SrsAlgorithm get memoryAlgorithm => this == rwkv ? fsrs7 : this;

  /// 间隔由 RWKV 推出（需要 RWKV 运行时；不可用时按 [memoryAlgorithm] 回退）。
  bool get usesRwkv => this == rwkv;

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
