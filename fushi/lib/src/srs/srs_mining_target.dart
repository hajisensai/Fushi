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

  /// 未知值 / null 一律当 [anki]（最保守：不改变既有制卡去向）。
  ///
  /// 已退役的「两者都发」档的存量值 `'both'` 同样读成 [anki]（所有者 2026-10-16
  /// 拍板）：老用户本来就在往 Anki 发，更新后继续发 Anki，不加更新提示。只在读时
  /// 映射，不改写偏好。
  static SrsMiningTarget fromWire(String? wire) {
    for (final SrsMiningTarget t in SrsMiningTarget.values) {
      if (t.wire == wire) return t;
    }
    return SrsMiningTarget.anki;
  }
}

/// 制卡落到 Fushi 复习的哪里（偏好给出，按 profile 存）。
///
/// [deckId] / [noteTypeId] 为空 = 默认牌组 / 内置 Lapis。[fieldMappingsByType]
/// 按笔记类型 id 存「fieldId → 制卡内容模板」（模板语法与 Anki 字段映射同一套
/// handlebar）；Lapis 不读它，恒用 Lapis 默认映射。
class SrsMiningDestination {
  const SrsMiningDestination({
    this.deckId = '',
    this.noteTypeId = '',
    this.fieldMappingsByType = const <String, Map<String, String>>{},
  });

  final String deckId;
  final String noteTypeId;
  final Map<String, Map<String, String>> fieldMappingsByType;

  // 值相等：provider 用 `select` 订阅它，每次从偏好重建出的新对象不该算变化。
  @override
  bool operator ==(Object other) {
    if (other is! SrsMiningDestination ||
        other.deckId != deckId ||
        other.noteTypeId != noteTypeId ||
        other.fieldMappingsByType.length != fieldMappingsByType.length) {
      return false;
    }
    for (final MapEntry<String, Map<String, String>> e
        in fieldMappingsByType.entries) {
      final Map<String, String>? o = other.fieldMappingsByType[e.key];
      if (o == null || o.length != e.value.length) return false;
      for (final MapEntry<String, String> f in e.value.entries) {
        if (o[f.key] != f.value) return false;
      }
    }
    return true;
  }

  @override
  int get hashCode =>
      Object.hash(deckId, noteTypeId, fieldMappingsByType.length);
}
