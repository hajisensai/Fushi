/// 书 / 漫画刮削的搜索词改写（纯函数，无 IO）。
///
/// 书架上的书名是给人看的单卷名，直接拿去搜在线源常常零结果（BUG-5372 实测）：
///
/// - 卷号后缀（`第01巻` / `第1卷` / `第1集` / `1권` / `Vol.1`）：系列级源（MangaBaka、
///   AniList）按系列存条目，带卷号一律查不到；
/// - 中英 / 日英 / 韩英混写（`Horimiya ホリミヤ`、`Solo Leveling 我独自升级`）：
///   Bangumi 与 MangaBaka 对混写名都可能零结果，拆开后任一半都能命中；
/// - 打头的作者 / 分类标签（`[川原礫] …`、`【漫画】…`）。
///
/// [bookSearchQueries] 按源的条目粒度给出一串候选词，调用方依次试、第一个有结果的
/// 为准（失败照常抛出，不吞）。候选只在原词零结果时才继续，所以本来能搜到的书名
/// 不受影响；条数有上限，免得一次搜索把源站限流额度用光。
library;

import 'package:fushi_engine/media/collections/book_series_key.dart'
    show BookSeriesKey, parseBookSeriesKey;

/// 搜索源的条目粒度（决定候选词怎么排）。
enum BookSearchGranularity {
  /// 条目是整部系列（MangaBaka 系列 / AniList media）：搜系列名，不带卷号。
  series,

  /// 条目是单卷（Bangumi 单行本 / NDL / 楽天）：原词优先，再试「系列名 卷号」。
  volume,
}

/// 一次搜索最多试几个词（含原词）。
const int kBookSearchMaxQueries = 4;

/// 打头的标签组：`[作者]`、`【漫画】`、`(同人誌)`、`（Comic）`，可连续多组。
final RegExp _leadingTags = RegExp(
  r'^(?:\s*(?:\[[^\[\]]*\]|【[^【】]*】|\([^()]*\)|（[^（）]*）))+\s*',
);

/// 汉字（含扩展 A、兼容区）、平 / 片假名（含半角）、谚文：中日韩文字。
final RegExp _cjk = RegExp(
  '[぀-ヿㇰ-ㇿ㐀-䶿一-鿿豈-﫿'
  'ｦ-ﾟᄀ-ᇿ㄰-㆏가-힯]',
);

/// 拉丁字母（含带变音符的拉丁扩展）。
final RegExp _latin = RegExp('[A-Za-zÀ-ɏ]');

/// 去掉打头的标签组；去完什么都不剩（整个书名都在括号里）时原样返回。
String stripLeadingBookTags(String title) {
  final String trimmed = title.trim();
  final String rest = trimmed.replaceFirst(_leadingTags, '').trim();
  return rest.isEmpty ? trimmed : rest;
}

/// 混写书名按空白切词后拆成「中日韩部分」与「拉丁部分」；只有两种都在时才拆
/// （`Horimiya ホリミヤ` → (ホリミヤ, Horimiya)），否则 null。一个词里同时有两种
/// 文字的（`Re:ゼロから始める異世界生活`、`SPY×FAMILY`）按含中日韩字算、不切开；
/// 纯数字 / 符号的词两边都不要。
({String cjk, String latin})? splitBookTitleScripts(String title) {
  final List<String> cjk = <String>[];
  final List<String> latin = <String>[];
  for (final String token in title.trim().split(RegExp(r'\s+'))) {
    if (token.isEmpty) continue;
    if (_cjk.hasMatch(token)) {
      cjk.add(token);
    } else if (_latin.hasMatch(token)) {
      latin.add(token);
    }
  }
  if (cjk.isEmpty || latin.isEmpty) return null;
  return (cjk: cjk.join(' '), latin: latin.join(' '));
}

/// 书名解析出的系列身份：先去掉打头标签再交给书架分卷归组的 [parseBookSeriesKey]
/// （卷号判据只有那一份）。整个书名都在括号里时（去掉标签只剩卷号）用
/// 「括号里的书名 + 剩下的部分」再解析（`[Comic][进击的巨人] Vol.01` →
/// 进击的巨人 · 第 1 卷）。
BookSeriesKey? parseBookSearchSeries(String title) {
  final String stripped = stripLeadingBookTags(title);
  final BookSeriesKey? key = parseBookSeriesKey(stripped);
  if (key != null && key.seriesTitle.trim().isNotEmpty) return key;
  final String? tag = _longestLeadingTag(title);
  if (tag == null) return key;
  return parseBookSeriesKey(stripped == title.trim() ? tag : '$tag $stripped');
}

/// 整个书名都在括号里时（`[Comic][进击的巨人][諫山創] Vol.01`，去掉标签后只剩卷号），
/// 取一组括号内容当系列名：含中日韩字的组优先（`Comic` / `DL版` 这类拉丁标签让位），
/// 同类里取最长；书名在括号外时为 null。
String? _longestLeadingTag(String title) {
  final RegExpMatch? m = _leadingTags.firstMatch(title.trim());
  if (m == null) return null;
  String? best;
  int rank(String s) => (_cjk.hasMatch(s) ? 1000 : 0) + s.length;
  for (final RegExpMatch g in RegExp(
    r'\[([^\[\]]*)\]|【([^【】]*)】|\(([^()]*)\)|（([^（）]*)）',
  ).allMatches(m.group(0)!)) {
    final String inner = (g.group(1) ?? g.group(2) ?? g.group(3) ?? g.group(4))!
        .trim();
    if (inner.isNotEmpty && (best == null || rank(inner) > rank(best))) {
      best = inner;
    }
  }
  return best;
}

/// 卷号的搜索写法：整数不带小数点（`1`），带小数的照写（`10.5`）。
String _volumeText(num volume) =>
    volume == volume.truncate() ? '${volume.truncate()}' : '$volume';

/// [query] 在 [granularity] 源上依次要试的搜索词（去重，至多
/// [kBookSearchMaxQueries] 个，第一个总是最可能命中的那个）。
///
/// - 系列级：系列名 → 混写时再试中日韩部分、拉丁部分。原词带卷号时不试原词
///   （系列级源带卷号必然零结果）。
/// - 单卷级：原词 → 「名 卷号」→ 名；混写时「名」取中日韩部分（Bangumi / NDL
///   都是中日文目录），最后补拉丁部分。
List<String> bookSearchQueries(
  String query, {
  required BookSearchGranularity granularity,
}) {
  final String original = query.trim();
  if (original.isEmpty) return const <String>[];
  final BookSeriesKey? key = parseBookSearchSeries(original);
  final String series = (key?.seriesTitle.trim().isNotEmpty ?? false)
      ? key!.seriesTitle.trim()
      : stripLeadingBookTags(original);
  final num? volume = key?.volume;
  final ({String cjk, String latin})? split = splitBookTitleScripts(series);
  final List<String> out = <String>[];
  void add(String q) {
    final String t = q.trim();
    if (t.isNotEmpty && !out.contains(t)) out.add(t);
  }

  switch (granularity) {
    case BookSearchGranularity.series:
      add(series);
      if (split != null) {
        add(split.cjk);
        add(split.latin);
      }
    case BookSearchGranularity.volume:
      add(original);
      final String name = split?.cjk ?? series;
      if (volume != null) add('$name ${_volumeText(volume)}');
      add(name);
      if (split != null) add(split.latin);
  }
  return out.length > kBookSearchMaxQueries
      ? out.sublist(0, kBookSearchMaxQueries)
      : out;
}
