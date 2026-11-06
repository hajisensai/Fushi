/// 阅读器「字数进度」状态：全书已读 / 总字数 + 每章字数与累计前缀。
///
/// 从 `_ReaderFushiPageState` 抽出（页面保留同名转发 getter/setter），把「本章已读 /
/// 本章总数 / 剩余字数」这类派生量收进一处，状态行、统计浮层、预计读完共用同一套
/// 算法，不再各自从四个裸字段里拼。纯 Dart，可单测。
library;

class ReaderProgressState {
  /// 全书已读字数（进度条分子）；未测得时 null。
  int? currentChars;

  /// 全书总字数（进度条分母）；未测得时 null。
  int? totalChars;

  /// 每章字数（TODO-131，开书后可能被后台重算覆盖）。
  List<int> chapterCharCounts = <int>[];

  /// 每章之前的累计字数前缀（`cumulative[i]` = 第 i 章之前所有章字数之和）。
  List<int> chapterCumulativeChars = <int>[];

  /// 落定每章字数并重建累计前缀（与旧 `_applyCharCounts` 同一算法）。
  void applyChapterCharCounts(List<int> counts) {
    chapterCharCounts = counts;
    int cumulative = 0;
    final List<int> prefix = <int>[];
    for (final int count in counts) {
      prefix.add(cumulative);
      cumulative += count;
    }
    chapterCumulativeChars = prefix;
  }

  /// 某章总字数；下标越界 / 未落定时 null。
  int? chapterTotal(int section) =>
      section >= 0 && section < chapterCharCounts.length
      ? chapterCharCounts[section]
      : null;

  /// 某章已读字数 = 全书已读 − 该章前累计，夹到 [0, 本章总数]；未知时 null。
  int? chapterCurrent(int section) {
    final int? current = currentChars;
    final int? total = chapterTotal(section);
    if (current == null ||
        total == null ||
        section >= chapterCumulativeChars.length) {
      return null;
    }
    return (current - chapterCumulativeChars[section]).clamp(0, total);
  }

  /// 本章剩余字数；未知时 null。
  int? remainingChapterChars(int section) {
    final int? total = chapterTotal(section);
    final int? current = chapterCurrent(section);
    return total == null || current == null ? null : total - current;
  }

  /// 全书剩余字数；未知时 null。
  int? get remainingBookChars {
    final int? total = totalChars;
    final int? current = currentChars;
    return total == null || current == null ? null : total - current;
  }
}
