/// 「挖词目标」：复习模块开着时，查词 / 阅读器 / 视频制卡发往哪里。
///
/// 二选一：要么 Anki，要么 Fushi 复习。同一个词在两处各自排程是冗余，
/// 所以没有「两者都发」这一档（曾经有过，见 [SrsMiningTarget.fromWire] 的存量映射）。
///
/// 模块关着时这个偏好不被读取，制卡链路与没有复习模块时逐字节一致。
library;

/// 制卡目标（持久化名 [wire] 冻结）。
enum SrsMiningTarget {
  /// 只发往 Anki（等于没有复习模块时的行为；升级上来的老用户的默认）。
  anki('anki'),

  /// 只进 Fushi 复习（新安装的默认，所有者 2026-10-16）。
  srs('srs');

  const SrsMiningTarget(this.wire);

  final String wire;

  /// `null`（没设过）= [srs]：新默认（所有者 2026-10-16「默认就是 fushi srs」）。
  /// 偏好层读取时先用本安装的出厂默认补上缺省（老用户 'anki'，见
  /// `PreferencesRepository.srsMiningTarget`），所以 null 只在没有偏好层可问时才走到这里。
  ///
  /// 认不出的值（含已退役的「两者都发」档的存量值 `'both'`，所有者 2026-10-16 拍板）
  /// 一律当 [anki]：那是**有人显式设过**的值，设它的人此前一直在往 Anki 发，宁可照旧
  /// 发 Anki 也不把卡误切进复习。只在读时映射，不改写偏好。
  static SrsMiningTarget fromWire(String? wire) {
    if (wire == null) return SrsMiningTarget.srs;
    for (final SrsMiningTarget t in SrsMiningTarget.values) {
      if (t.wire == wire) return t;
    }
    return SrsMiningTarget.anki;
  }
}

/// 制卡落到 Fushi 复习的哪里（偏好给出，按 profile 存）。
///
/// [deckId] / [noteTypeId] 为空 = 默认牌组 / 内置 Fushi 卡片（从没选过时的默认；选择器
/// 写的是具体 id，选了 Lapis 存的是 Lapis 的 id，与「没选过」可区分）。[fieldMappingsByType]
/// 按笔记类型 id 存「fieldId → 制卡内容模板」（模板语法与 Anki 字段映射同一套
/// handlebar）；内置类型（Lapis、Fushi 卡片）不读它，恒用各自的默认映射。
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
