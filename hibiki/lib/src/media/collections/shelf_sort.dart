/// 排序交互重设计层次 A（docs/specs/2026-07-12-sorting-interaction-redesign.md）：
/// 库页「排序方式」纯函数层——模式 enum + natural 文本比较 + 组级排序键比较器，
/// widget-free 单测。书架/视频页共用同一套；两页只差 `recent` 的语义与文案
/// （书架=最近阅读=历史序，视频=最近观看=watch-stats）。
library;

/// 库页排序方式。`.name` 即偏好持久化值（shelf_sort_mode / video_sort_mode）。
enum ShelfSortMode {
  /// 最近（默认）：书架=最近阅读（`reader_positions.updatedAt`，没读过退导入
  /// 时间，BUG-756），视频=最近观看（watch-stats，无记录退导入时间）。
  recent,

  /// 名称（natural 排序：卷1 < 卷2 < 卷10）。
  title,

  /// 导入时间（新导入在前）。
  imported;

  /// 从持久化 `.name` 解析；未知值（含旧版本残留）退默认 [recent]。
  static ShelfSortMode fromName(String name) => values.firstWhere(
        (ShelfSortMode m) => m.name == name,
        orElse: () => ShelfSortMode.recent,
      );
}

/// 一个展示单元（散卡或合集行）参与库页排序的键。合集行取成员聚合：
/// [recentScore] / [importedAt] 取成员 max，[title] 取合集名。
class ShelfSortKey {
  const ShelfSortKey({
    required this.recentScore,
    required this.title,
    required this.importedAt,
    required this.tieKey,
  });

  /// 「最近」量纲，越大越新。视频=watch-stats 毫秒戳（无记录退 importedAt）；
  /// 书架=`reader_positions.updatedAt` 毫秒戳（没读过退 importedAt，BUG-756：
  /// 旧实现把 provider 下标当历史名次，实际是导入序）。
  final int recentScore;

  final String title;

  /// 导入毫秒戳，越大越新（无值传 0）。
  final int importedAt;

  /// 确定性兜底（entryKey / 'c<collectionId>'），保证任何模式下全序稳定。
  final String tieKey;
}

/// 按 [mode] 比较两个排序键。各模式的次级键固定（recent→imported→title、
/// title→imported、imported→title），最后恒以 [ShelfSortKey.tieKey] 决出全序。
int compareShelfSortKeys(ShelfSortKey a, ShelfSortKey b, ShelfSortMode mode) {
  int c;
  switch (mode) {
    case ShelfSortMode.recent:
      c = b.recentScore.compareTo(a.recentScore);
      if (c == 0) c = b.importedAt.compareTo(a.importedAt);
      if (c == 0) c = naturalCompare(a.title, b.title);
    case ShelfSortMode.title:
      c = naturalCompare(a.title, b.title);
      if (c == 0) c = b.importedAt.compareTo(a.importedAt);
    case ShelfSortMode.imported:
      c = b.importedAt.compareTo(a.importedAt);
      if (c == 0) c = naturalCompare(a.title, b.title);
  }
  if (c != 0) return c;
  return a.tieKey.compareTo(b.tieKey);
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// ASCII 大写折小写；其余码元原样（CJK 无大小写概念，直接码元序）。
int _lowered(int codeUnit) =>
    (codeUnit >= 0x41 && codeUnit <= 0x5A) ? codeUnit | 0x20 : codeUnit;

/// Natural 文本比较：ASCII 数字段按数值比较（跳前导零、先长度后逐位，无溢出），
/// 其余按 ASCII 不分大小写的码元序。「第1卷 < 第2卷 < 第10卷」。全角/汉字数字
/// 不做数值化（按码元序），诚实边界。
int naturalCompare(String a, String b) {
  int i = 0;
  int j = 0;
  while (i < a.length && j < b.length) {
    if (_isDigit(a.codeUnitAt(i)) && _isDigit(b.codeUnitAt(j))) {
      // 消费两侧完整数字段。
      int endA = i;
      int endB = j;
      while (endA < a.length && _isDigit(a.codeUnitAt(endA))) {
        endA++;
      }
      while (endB < b.length && _isDigit(b.codeUnitAt(endB))) {
        endB++;
      }
      // 跳前导零（至少留一位）。
      int numA = i;
      int numB = j;
      while (numA < endA - 1 && a.codeUnitAt(numA) == 0x30) {
        numA++;
      }
      while (numB < endB - 1 && b.codeUnitAt(numB) == 0x30) {
        numB++;
      }
      final int lenA = endA - numA;
      final int lenB = endB - numB;
      if (lenA != lenB) return lenA - lenB;
      for (int k = 0; k < lenA; k++) {
        final int d = a.codeUnitAt(numA + k) - b.codeUnitAt(numB + k);
        if (d != 0) return d;
      }
      i = endA;
      j = endB;
    } else {
      final int d = _lowered(a.codeUnitAt(i)) - _lowered(b.codeUnitAt(j));
      if (d != 0) return d;
      i++;
      j++;
    }
  }
  final int rem = (a.length - i) - (b.length - j);
  if (rem != 0) return rem;
  // 数值等值（前导零）/大小写全等 → 原文比较兜底确定性。
  return a.compareTo(b);
}

/// BUG-756：继续阅读 hero 的候选选择——在候选里选 [lastReadAt] 最大者（严格
/// 大于才替换）；并列（含全部无时间戳 = 0）保留先出现者，退化为调用方列表序。
/// 候选为空返回 null。
T? mostRecentlyReadCandidate<T>(
  Iterable<T> candidates,
  int Function(T) lastReadAt,
) {
  T? best;
  int bestAt = -1;
  for (final T candidate in candidates) {
    final int at = lastReadAt(candidate);
    if (at > bestAt) {
      best = candidate;
      bestAt = at;
    }
  }
  return best;
}
