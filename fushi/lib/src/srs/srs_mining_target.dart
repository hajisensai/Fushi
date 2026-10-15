/// 「挖词目标」：复习模块开着时，查词 / 阅读器 / 视频制卡发往哪里。
///
/// 二选一：要么 Anki，要么 Fushi 复习。同一个词在两处各自排程是冗余，
/// 所以没有「两者都发」这一档（曾经有过，见 [SrsMiningTarget.fromWire] 的存量映射）。
///
/// 模块关着时这个偏好不被读取，制卡链路与没有复习模块时逐字节一致。
library;

/// 制卡目标（持久化名 [wire] 冻结）。
enum SrsMiningTarget {
  /// 只发往 Anki（默认，等于没有复习模块时的行为）。
  anki('anki'),

  /// 只进 Fushi 复习。
  srs('srs');

  const SrsMiningTarget(this.wire);

  final String wire;

  /// 已退役的「两者都发」档的存量 wire 值。
  static const String _legacyBothWire = 'both';

  /// 未知值 / null 一律当 [anki]（最保守：不改变既有制卡去向）。
  ///
  /// 存量 `'both'` 读成 [srs]：用户当初主动选过复习，保留复习这一边。
  static SrsMiningTarget fromWire(String? wire) {
    if (wire == _legacyBothWire) return SrsMiningTarget.srs;
    for (final SrsMiningTarget t in SrsMiningTarget.values) {
      if (t.wire == wire) return t;
    }
    return SrsMiningTarget.anki;
  }
}
