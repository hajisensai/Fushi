import 'package:hibiki_core/hibiki_core.dart';

/// 学习统计的**来源**维度：阅读统计页与首页仪表盘的字数/时长口径由此统一。
///
/// 背景：统计页此前只读 `reading_statistics`（书内阅读），却在编辑与首页共用的
/// 每日目标——首页把 阅读 + 视频字幕 + 游戏文本 三源合计当分子，统计页只算书，
/// 同一个目标两个页面两套分子。这里把四个来源摊平成同一形状，两边共用。
///
/// 每个来源都带**两个独立量纲**（字数 + 时长），漫画额外带页数：
/// - [book]：EPUB / PDF 等书内阅读（`reading_statistics` 中 `format != 'manga'`）。
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

/// 逐来源、逐日的统计合计。
///
/// [formatByTitle] 是 `epub_books.title -> format`（`'epub'` / `'pdf'` / `'manga'`）；
/// 统计行只存 title，靠它反查书身份。查不到的 title（书已删、统计还在）按 [book]
/// 归类——宁可算进阅读，也不凭 `pagesRead > 0` 这类二元标志猜身份。
Map<StatBreakdownSource, Map<String, StatSourceTotals>>
    aggregateStatSourceDaily({
  required List<ReadingStatisticRow> reading,
  required Map<String, String> formatByTitle,
  required List<VideoWatchStatisticRow> video,
  required List<(String, int, int)> gameDaily,
}) {
  final Map<StatBreakdownSource, Map<String, StatSourceTotals>> out =
      <StatBreakdownSource, Map<String, StatSourceTotals>>{
    for (final StatBreakdownSource s in StatBreakdownSource.values)
      s: <String, StatSourceTotals>{},
  };

  StatSourceTotals bucket(StatBreakdownSource source, String dateKey) =>
      out[source]!.putIfAbsent(dateKey, StatSourceTotals.new);

  for (final ReadingStatisticRow r in reading) {
    final bool isManga = formatByTitle[r.title] == 'manga';
    final StatSourceTotals b = bucket(
      isManga ? StatBreakdownSource.manga : StatBreakdownSource.book,
      r.dateKey,
    );
    b.chars += r.charactersRead;
    b.timeMs += r.readingTimeMs;
    b.pages += r.pagesRead;
  }

  for (final VideoWatchStatisticRow w in video) {
    final StatSourceTotals b = bucket(StatBreakdownSource.video, w.dateKey);
    b.chars += w.subtitleChars;
    b.timeMs += w.watchTimeMs;
  }

  for (final (String dateKey, int charsDelta, int durationMs) in gameDaily) {
    final StatSourceTotals b = bucket(StatBreakdownSource.game, dateKey);
    b.chars += charsDelta;
    b.timeMs += durationMs;
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

/// 全部来源在某窗口的合计（首页每日目标 / 统计页 KPI 的同一口径分子）。
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

/// 所有来源出现过的日期键并集（连续天数 / 活跃天数用：看了视频、玩了游戏的那天
/// 也是学习日，不该因为没读书就断签）。
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
