import 'package:fushi/src/stats/stat_facts.dart';

/// 学习活动的**来源**维度：供跨来源首页汇总与来源拆分纯函数使用。
///
/// 四个来源摊平成同一形状，消费方再明确选择自己的域：阅读统计页只取
/// [book]/[manga]，视频与游戏由各自统计页读取各自事实；首页跨来源目标可取并集。
///
/// 每个来源都带**两个独立量纲**（字数 + 时长），漫画额外带页数：
/// - [book]：EPUB / PDF 等书内阅读（`format != 'manga'` 的书事实）。
/// - [manga]：漫画（`format == 'manga'`），OCR 字数 + 页数 + 时长。
/// - [video]：视频，字幕字数 + 观看时长。
/// - [game]：galgame hook 文本字数 + 游玩时长。
enum StatBreakdownSource { book, manga, video, game }

/// 一个来源在某个窗口（某天 / 今日 / 本周 / 全部）内的量纲合计。
///
/// 可变是刻意的：聚合就是逐行累加，不为每行造一个新对象。
class StatSourceTotals {
  StatSourceTotals({this.chars = 0, this.timeMs = 0, this.pages = 0});

  /// 字数（各来源各自的字数口径：书/漫画=实义字符，视频=字幕字符，游戏=hook 文本）。
  int chars;

  /// 时长（毫秒）。
  int timeMs;

  /// 页数。目前只有漫画产出（EPUB 无页概念，视频/游戏不适用），恒 >= 0。
  int pages;

  void add(StatSourceTotals other) {
    chars += other.chars;
    timeMs += other.timeMs;
    pages += other.pages;
  }

  bool get isEmpty => chars == 0 && timeMs == 0 && pages == 0;
}

/// 事实 → 来源桶。书事实按 [StatFact.format] 拆普通书 / 漫画（legacy 行反查库表
/// 失败的 format '' 归普通书——宁可算进阅读，也不凭 `pages > 0` 这类二元标志猜身份）。
StatBreakdownSource statSourceOf(StatFact f) {
  if (f.isVideo) return StatBreakdownSource.video;
  if (f.isGame) return StatBreakdownSource.game;
  return f.isManga ? StatBreakdownSource.manga : StatBreakdownSource.book;
}

/// 逐来源、逐日的统计合计（v92：输入是统一事实面的**日面**，不再各表各读）。
Map<StatBreakdownSource, Map<String, StatSourceTotals>>
aggregateStatSourceDaily(Iterable<StatFact> daily) {
  final Map<StatBreakdownSource, Map<String, StatSourceTotals>> out =
      <StatBreakdownSource, Map<String, StatSourceTotals>>{
        for (final StatBreakdownSource s in StatBreakdownSource.values)
          s: <String, StatSourceTotals>{},
      };
  for (final StatFact f in daily) {
    final StatSourceTotals b = out[statSourceOf(f)]!.putIfAbsent(
      f.dateKey,
      StatSourceTotals.new,
    );
    b.chars += f.chars;
    b.timeMs += f.ms;
    b.pages += f.pages;
  }
  return out;
}

/// 把逐日合计压成一个窗口的合计：[inWindow] 决定哪些 dateKey 计入。
StatSourceTotals sumStatSourceTotals(
  Map<String, StatSourceTotals> byDay,
  bool Function(String dateKey) inWindow,
) {
  final StatSourceTotals total = StatSourceTotals();
  byDay.forEach((String dateKey, StatSourceTotals value) {
    if (inWindow(dateKey)) total.add(value);
  });
  return total;
}

/// 全部来源在某窗口的合计（跨来源首页目标等场景使用）。
StatSourceTotals sumAllStatSources(
  Map<StatBreakdownSource, Map<String, StatSourceTotals>> daily,
  bool Function(String dateKey) inWindow,
) {
  final StatSourceTotals total = StatSourceTotals();
  for (final Map<String, StatSourceTotals> byDay in daily.values) {
    total.add(sumStatSourceTotals(byDay, inWindow));
  }
  return total;
}

/// 所有来源出现过的日期键并集（跨来源活跃天数使用）。
Set<String> allStatSourceDateKeys(
  Map<StatBreakdownSource, Map<String, StatSourceTotals>> daily,
) {
  final Set<String> keys = <String>{};
  for (final Map<String, StatSourceTotals> byDay in daily.values) {
    for (final MapEntry<String, StatSourceTotals> e in byDay.entries) {
      if (!e.value.isEmpty) keys.add(e.key);
    }
  }
  return keys;
}
