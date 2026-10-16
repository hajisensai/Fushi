/// 「挖词目标」：复习模块开着时，查词 / 阅读器 / 视频制卡发往哪里。
///
/// 模块关着时这个偏好不被读取，制卡链路与没有复习模块时逐字节一致。
library;

/// 制卡目标（持久化名 [wire] 冻结）。
enum SrsMiningTarget {
  /// 只发往 Anki（默认，等于没有复习模块时的行为）。
  anki('anki'),

  /// 只进 Fushi 复习。
  srs('srs'),

  /// 两边都发（同一个词在两处各自排程）。
  both('both');

  const SrsMiningTarget(this.wire);

  final String wire;

  bool get includesSrs => this != SrsMiningTarget.anki;
  bool get includesAnki => this != SrsMiningTarget.srs;

  /// 未知值 / null 一律当 [anki]（最保守：不改变既有制卡去向）。
  static SrsMiningTarget fromWire(String? wire) {
    for (final SrsMiningTarget t in SrsMiningTarget.values) {
      if (t.wire == wire) return t;
    }
    return SrsMiningTarget.anki;
  }
}
