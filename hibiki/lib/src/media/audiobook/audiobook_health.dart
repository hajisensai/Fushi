import 'package:hibiki/src/media/audiobook/audiobook_model.dart';

/// 一本有声书的对齐健康度语义。
///
/// 上游 Sasayaki 只有"match rate / search window"两个原始数字；hibiki 把它
/// 抽象成 kind + 可选 ratePct + reason 三段：
///
/// - UI 永远 `switch(kind)`，不会因为某种格式没有 ratePct 就瘫掉。
/// - SRT/LRC/VTT/ASS 走 matcher，有真实 ratePct；
/// - SMIL 只能报 fragment id 存活率（仍然能归纳成 ratePct）；
/// - JSON 静态检查时 ratePct 填 selector 存在性百分比，懒 DOM 命中率等
///   PR8 落地后再写；
/// - CuesToEpub 生成的合成书不需要匹配，直接 notApplicable。
enum HealthKind {
  /// 从未跑过匹配 / 字段都是 null。旧记录第一次读出来就是这个。
  unrun,

  /// 正在跑（为未来的异步重跑留位，当前导入链路同步完成不会看到）。
  running,

  /// 匹配率 ≥ 接受阈值（`AudiobookHealth.okThreshold`）。
  ok,

  /// 匹配率低于阈值但 > 0。UI 在书卡上挂黄色角标。
  partial,

  /// 匹配率为 0 或跑不起来（ttu IDB 读失败、文件格式错误等）。reason
  /// 里放具体原因。
  failed,

  /// 对齐路径本身不需要匹配（字幕→EPUB 生成书、内嵌 SMIL 等）。UI 不显示
  /// 角标。
  notApplicable,
}

/// 健康度值对象。
///
/// 在内存里用它，落到 Isar 时拆成 [Audiobook.healthKindRaw] / matchRatePct /
/// healthMeasuredAt / healthReason 四个字段（见 [packInto] / [fromAudiobook]）。
class AudiobookHealth {
  const AudiobookHealth({
    required this.kind,
    this.ratePct,
    this.reason,
    required this.measuredAt,
  });

  final HealthKind kind;

  /// 0..100。仅当 [kind] ∈ {ok, partial, failed} 时有意义；其他取值为 null
  /// 或被调用方忽略。
  final int? ratePct;

  /// 给人看的理由；ok 时可以为 null。
  final String? reason;

  final DateTime measuredAt;

  /// 匹配率 ≥ 该阈值视为 [HealthKind.ok]。来自上游 Sasayaki 的经验值——
  /// 低于 80% 一般就得让用户调 search window 或换 alignment，此时 UI 必须
  /// 能醒目提醒。
  static const int okThreshold = 80;

  /// 从匹配率百分比直接分档。nul/负数/0 →  failed；≥ 阈值 → ok；其余
  /// → partial。
  factory AudiobookHealth.fromRatePct({
    required int ratePct,
    String? reason,
    DateTime? measuredAt,
  }) {
    final DateTime t = measuredAt ?? DateTime.now();
    if (ratePct <= 0) {
      return AudiobookHealth(
        kind: HealthKind.failed,
        ratePct: ratePct,
        reason: reason,
        measuredAt: t,
      );
    }
    if (ratePct >= okThreshold) {
      return AudiobookHealth(
        kind: HealthKind.ok,
        ratePct: ratePct,
        reason: reason,
        measuredAt: t,
      );
    }
    return AudiobookHealth(
      kind: HealthKind.partial,
      ratePct: ratePct,
      reason: reason,
      measuredAt: t,
    );
  }

  factory AudiobookHealth.notApplicable({String? reason, DateTime? measuredAt}) {
    return AudiobookHealth(
      kind: HealthKind.notApplicable,
      reason: reason,
      measuredAt: measuredAt ?? DateTime.now(),
    );
  }

  factory AudiobookHealth.failed({required String reason, DateTime? measuredAt}) {
    return AudiobookHealth(
      kind: HealthKind.failed,
      ratePct: 0,
      reason: reason,
      measuredAt: measuredAt ?? DateTime.now(),
    );
  }

  /// 旧记录 / 字段全 null 时的回退值。UI 用灰色 `?` 角标表示。
  factory AudiobookHealth.unrun() {
    return AudiobookHealth(
      kind: HealthKind.unrun,
      measuredAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }

  /// 把字段拆进 [Audiobook]（供 `audiobook_repository.updateHealth` 使用）。
  void packInto(Audiobook ab) {
    ab.healthKindRaw = kind.name;
    ab.matchRatePct = ratePct;
    ab.healthMeasuredAt = measuredAt;
    ab.healthReason = reason;
  }

  /// 从 [Audiobook] 字段还原。字段全 null → [AudiobookHealth.unrun]。
  ///
  /// matchRatePct 被 clamp 到 [0, 100]：历史上 "两次 put 写坏记录" 的 bug
  /// 会把回读值弄成 33554526 这种值，无脑显示会让 UI 出现荒谬百分比。
  /// 落库前本就 0..100，越界即视为脏数据。
  static AudiobookHealth fromAudiobook(Audiobook ab) {
    final String? raw = ab.healthKindRaw;
    if (raw == null) {
      return AudiobookHealth.unrun();
    }
    final HealthKind kind = HealthKind.values.firstWhere(
      (HealthKind k) => k.name == raw,
      orElse: () => HealthKind.unrun,
    );
    final int? rawPct = ab.matchRatePct;
    final int? pct = (rawPct == null || rawPct < 0 || rawPct > 100)
        ? null
        : rawPct;
    return AudiobookHealth(
      kind: kind,
      ratePct: pct,
      reason: ab.healthReason,
      measuredAt: ab.healthMeasuredAt ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}
