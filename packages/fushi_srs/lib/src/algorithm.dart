/// 排程算法：FSRS-7 / FSRS-6 / RWKV。
///
/// RWKV（2026-10-19 用户定支持，2026-10-20 定为 RWKV-Instant 并设为默认）：原生推理库在
/// native/fushi_rwkv（AGPL-3.0-or-later），Dart 绑定 packages/fushi_rwkv。它不给间隔，决定的是复习卡
/// **什么时候进队**：排队时按当前状态查每张复习卡此刻的回忆率，R ≤ 目标保留率的才出（不看到期日，
/// 见 fushi_engine `SrsDbStore._instantReviews`）。存下的到期日与记忆状态（stability / difficulty，
/// 统计、同步与 RWKV 不可用时排队用）照旧由 FSRS-7 维护，见 [SrsAlgorithm.memoryAlgorithm]。
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

  /// 复习卡按 RWKV 此刻的回忆率进队（需要 RWKV 运行时；不可用时按 [memoryAlgorithm] 存下的
  /// 到期日排队）。
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

/// 默认算法（新建牌组与没明确选过算法的牌组）：RWKV（Instant 排队，2026-10-20 用户拍板）。
/// 本机 RWKV 还没准备好（首次下载权重 / 回放历史）时这些牌组照旧按 FSRS-7 存下的到期日排队。
const SrsAlgorithm srsDefaultAlgorithm = SrsAlgorithm.rwkv;

/// 牌组设置里的算法字段（可能是本机不认识的 wire 值）解析成本机实际用来排程的算法。
SrsAlgorithm resolveLocalAlgorithm(String? wire) {
  final SrsAlgorithm? known = SrsAlgorithm.tryParse(wire);
  if (known != null) return known;
  return srsLocalAlgorithmFallbackOrder.first;
}
