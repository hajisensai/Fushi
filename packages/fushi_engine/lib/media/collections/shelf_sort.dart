/// 排序交互重设计层次 A（docs/specs/2026-07-12-sorting-interaction-redesign.md）：
/// 库页「排序方式」纯函数层——模式 enum + natural 文本比较 + 组级排序键比较器，
/// widget-free 单测。书架/视频页共用同一套；两页只差 `recent` 的语义与文案
/// （书架=最近阅读=历史序，视频=最近观看=watch-stats）。
library;

/// 库页排序方式。`.name` 即偏好持久化值（shelf_sort_mode / video_sort_mode）。
enum ShelfSortMode {
  /// 最近（默认）：书架=最近阅读（`reader_positions.updatedAt`，没读过退导入
  /// 时间，BUG-777），视频=最近观看（watch-stats，无记录退导入时间）。
  recent,

  /// 名称（natural 排序：卷1 < 卷2 < 卷10）。
  title,

  /// 导入时间（新导入在前）。
  imported,

  /// 手动：用户在排序模式里拖出来的顺序（[compareShelfSortKeys] 的
  /// `manualRanks`）。不在手动序里的单元（排好之后新导入的）排在最前、按导入
  /// 时间倒序，新东西不会沉到底。
  manual;

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
  /// 书架=`reader_positions.updatedAt` 毫秒戳（没读过退 importedAt，BUG-777：
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
///
/// [ShelfSortMode.manual] 按 [manualRanks]（tieKey → 手动序下标）升序；没有名次
/// 的排在有名次的前面，彼此按 imported→title。
int compareShelfSortKeys(
  ShelfSortKey a,
  ShelfSortKey b,
  ShelfSortMode mode, {
  Map<String, int> manualRanks = const <String, int>{},
}) {
  int c;
  switch (mode) {
    case ShelfSortMode.manual:
      final int? ra = manualRanks[a.tieKey];
      final int? rb = manualRanks[b.tieKey];
      if (ra != null && rb != null) {
        c = ra.compareTo(rb);
      } else if (ra != null || rb != null) {
        c = ra == null ? -1 : 1;
      } else {
        c = b.importedAt.compareTo(a.importedAt);
        if (c == 0) c = naturalCompare(a.title, b.title);
      }
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

/// 全角 ASCII（U+FF01–FF5E）折成半角、全角空格（U+3000）折成空格，再把 ASCII
/// 大写折小写；其余码元原样（CJK 无大小写概念，直接码元序）。日文书名里
/// 「志乃と恋 ２」与「志乃と恋 3」混用全角 / 半角数字是常态，不折叠就排成 3 < ２。
int _folded(int codeUnit) {
  int c = codeUnit;
  if (c >= 0xFF01 && c <= 0xFF5E) {
    c -= 0xFEE0;
  } else if (c == 0x3000) {
    c = 0x20;
  }
  return (c >= 0x41 && c <= 0x5A) ? c | 0x20 : c;
}

bool _isDigitAt(String s, int index) {
  final int c = _folded(s.codeUnitAt(index));
  return c >= 0x30 && c <= 0x39;
}

/// Natural 文本比较：数字段（半角或全角）按数值比较（跳前导零、先长度后逐位，
/// 无溢出），其余按全角折半角、ASCII 不分大小写的码元序。
/// 「第1卷 < 第２卷 < 第10卷」。汉字数字（一二三）不做数值化，按码元序。
int naturalCompare(String a, String b) {
  int i = 0;
  int j = 0;
  while (i < a.length && j < b.length) {
    if (_isDigitAt(a, i) && _isDigitAt(b, j)) {
      // 消费两侧完整数字段。
      int endA = i;
      int endB = j;
      while (endA < a.length && _isDigitAt(a, endA)) {
        endA++;
      }
      while (endB < b.length && _isDigitAt(b, endB)) {
        endB++;
      }
      // 跳前导零（至少留一位）。
      int numA = i;
      int numB = j;
      while (numA < endA - 1 && _folded(a.codeUnitAt(numA)) == 0x30) {
        numA++;
      }
      while (numB < endB - 1 && _folded(b.codeUnitAt(numB)) == 0x30) {
        numB++;
      }
      final int lenA = endA - numA;
      final int lenB = endB - numB;
      if (lenA != lenB) return lenA - lenB;
      for (int k = 0; k < lenA; k++) {
        final int d =
            _folded(a.codeUnitAt(numA + k)) - _folded(b.codeUnitAt(numB + k));
        if (d != 0) return d;
      }
      i = endA;
      j = endB;
    } else {
      final int d = _folded(a.codeUnitAt(i)) - _folded(b.codeUnitAt(j));
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

/// BUG-777：继续阅读 hero 的候选选择——在候选里选 [lastReadAt] 最大者（严格
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

/// 书架条目的阅读状态（书 / 漫画 / 有声书共用一个口径）。书架 / 漫画库搜索栏
/// 「阅读状态」下拉的档位也是它（null = 全部）。
enum ShelfReadStatus { unread, reading, finished }

/// 条目阅读状态的**唯一判据**，书架概览统计（[tallyShelfProgress]）与阅读状态
/// 筛选共用：
/// * [completed]（`EpubBooks.completedAt` 非 null，手动标记或读到末尾自动写入）
///   → 读完，不受进度约束；
/// * `duration<=0`（无进度维度，如纯字幕书）→ 未读；
/// * `position>=duration` → 读完；`0<position<duration` → 在读；其余未读。
ShelfReadStatus classifyShelfReadStatus({
  required bool completed,
  required int position,
  required int duration,
}) {
  if (completed) return ShelfReadStatus.finished;
  if (duration <= 0 || position <= 0) return ShelfReadStatus.unread;
  return position >= duration
      ? ShelfReadStatus.finished
      : ShelfReadStatus.reading;
}

/// 书架概览统计（在读数 / 读完数 / 在读候选列表）。
///
/// BUG-804：输入必须是**全量 EPUB-backed 书**——含有声书（EPUB 正文 + SRT
/// 字幕同 bookKey，走阅读器落 `reader_positions`，有真实 position/duration）。旧
/// 实现只喂 srt 过滤后的纯 EPUB 列表（`epubBooks`），把有声书整类排除，导致读了
/// 有声书回书架「继续阅读」hero 永不更新（有声书虽有进度与 lastReadAt 却进不了
/// 候选）。过滤到纯 EPUB 只为主网格卡去重（有声书渲染成 SRT 卡），与概览统计/
/// hero 选书无关，不能复用到这里。
///
/// 分类：`duration<=0` 跳过（无进度维度，如纯字幕、无 EPUB 正文的书）；
/// `position>=duration` 计读完；`0<position<duration` 计在读并进候选。
class ShelfProgressTally<T> {
  const ShelfProgressTally({
    required this.reading,
    required this.finished,
    required this.inProgress,
  });

  final int reading;
  final int finished;
  final List<T> inProgress;
}

/// [isCompleted]（可选）= 该书是否被显式标记「读完」（EpubBooks.completedAt 非
/// null，用户手动标记或读到末尾自动写入）。命中即计读完、不进在读候选，且**不受
/// 进度约束**——跳过后记/附录、进度停在 99% 的手动标记书也能计入 Completed，正是
/// 「读到最后一字才算完成」这一临时派生判据无法覆盖的场景。未传则退回纯进度派生
/// （旧行为，向后兼容）。
ShelfProgressTally<T> tallyShelfProgress<T>(
  Iterable<T> epubBackedBooks,
  int Function(T) position,
  int Function(T) duration, {
  bool Function(T)? isCompleted,
}) {
  int reading = 0;
  int finished = 0;
  final List<T> inProgress = <T>[];
  for (final T book in epubBackedBooks) {
    switch (classifyShelfReadStatus(
      completed: isCompleted != null && isCompleted(book),
      position: position(book),
      duration: duration(book),
    )) {
      case ShelfReadStatus.finished:
        finished++;
      case ShelfReadStatus.reading:
        reading++;
        inProgress.add(book);
      case ShelfReadStatus.unread:
        break;
    }
  }
  return ShelfProgressTally<T>(
    reading: reading,
    finished: finished,
    inProgress: inProgress,
  );
}

/// 手动序的持久化形态（换行分隔的 tieKey 列表）→ 名次表。
Map<String, int> decodeShelfManualOrder(String raw) {
  final Map<String, int> ranks = <String, int>{};
  if (raw.isEmpty) return ranks;
  for (final String key in raw.split(_manualOrderSeparator)) {
    if (key.isNotEmpty) ranks.putIfAbsent(key, () => ranks.length);
  }
  return ranks;
}

/// 名次表 → 持久化形态。tieKey 里可能有逗号（文件路径），故用换行分隔。
String encodeShelfManualOrder(List<String> order) =>
    order.join(_manualOrderSeparator);

/// 手动序持久化的分隔符：换行（tieKey 不含换行）。
const String _manualOrderSeparator = '\n';

/// 排序模式里的一次拖动：[visible] 是当前显示的单元（tieKey，显示顺序），把
/// 下标 [from] 的移到 [to]；[all] 是**全部**单元按当前手动序排好的 tieKey（筛选 /
/// 搜索藏起来的也在内）。返回新的完整手动序：[visible] 占的槽位按移动后的顺序
/// 依次回填，被筛掉的单元原位不动（与合集成员的筛选态拖排同一合并语义）。
List<String> moveInShelfManualOrder({
  required List<String> all,
  required List<String> visible,
  required int from,
  required int to,
}) {
  final List<String> moved = List<String>.of(visible);
  if (from < 0 || from >= moved.length) return List<String>.of(all);
  final String item = moved.removeAt(from);
  moved.insert(to.clamp(0, moved.length), item);
  final Set<String> named = moved.toSet();
  int next = 0;
  return <String>[
    for (final String key in all)
      if (named.contains(key)) moved[next++] else key,
  ];
}
