/// 发现搜索结果的统一相关度判据（反馈 80S7Esbdec）。
///
/// 为什么要在**聚合层**判：各发现源把「站点搜索接口返回了什么」原样转成
/// [DiscoveryEntry]，而站点后端的匹配口径五花八门——真红小站（shinnku）是字符级
/// 模糊匹配，搜「ユリアリス」会把零散命中 リ / ア / ス 的「天文時計のアリア」
/// 「ユニオリズム」一起返回；Nyaa / AList / OPDS 各有各的口径。发现页此前没有
/// 任何相关度判据，于是哪个源最松，哪个源的噪声就整页透出来。
///
/// 判据只看用户能读到的文字（标题 / 文件名 / 源给的一句话标注），两侧都过
/// [normalizeMediaSearchText]（全半角、大小写、片假名→平假名、去空白与标点，与
/// 库页搜索同一口径），然后：
///
/// 1. 归一后的整条查询词作为**连续子串**出现在任一文字里 → 命中（最强）；
/// 2. 否则按空白把查询拆成词，按**字符数加权**算有多少词出现（覆盖率），
///    覆盖率 ≥ [kDiscoveryTokenCoverageThreshold] 也算命中（词序颠倒、
///    中间夹了副标题 / 版本号的标题）。
///
/// 不按单字 / n-gram 打分：那正是 shinnku 后端出错的口径——日文标题共用的假名
/// 太多，按单字算永远「有点像」。
///
/// 不命中的条目**不删**：源有时按标题之外的字段（作者、系列、简介）命中，聚合层
/// 看不到那些字段。服务层只把它们排到源内末尾，发现页把它们折叠进「已隐藏 N 条
/// 疑似不相关」，用户一点即可展开（与死种 / 疑似漫画同一个折叠行）。
library;

import 'package:collection/collection.dart' show mergeSort;
import 'package:fushi_engine/media/discovery/discovery_models.dart';

import 'package:fushi/src/media/media_search_text.dart';

/// 分词覆盖率阈值。
///
/// 0.6 的来由：命中必须覆盖查询里**过半**的有效字符，所以只撞上一个短修饰词
/// （「汉化」、季号、版本号）的条目进不来；但允许漏掉一个较短的修饰词——
/// 「ユリアリス 汉化」对只叫「ユリアリス」的条目覆盖 5/7≈0.71，仍算命中。
/// 两个等长词只命中一个是 0.5，判为不相关（不知道用户要的是哪一半）。
const double kDiscoveryTokenCoverageThreshold = 0.6;

/// 查询词的分词界：半角 / 全角空白。标点不当分界——归一化本来就会丢掉它们，
/// `Fate/stay` 这种写法在连续子串那一步已经能命中。
final RegExp _queryTokenSeparators = RegExp(r'[\s　]+');

/// 一条结果相对一次查询的相关度。
class DiscoverySearchRelevance implements Comparable<DiscoverySearchRelevance> {
  const DiscoverySearchRelevance({
    required this.contiguous,
    required this.coverage,
  });

  /// 连续子串命中（含空查询：不是搜索时恒相关、恒满分）。
  static const DiscoverySearchRelevance full = DiscoverySearchRelevance(
    contiguous: true,
    coverage: 1,
  );

  /// 一个词都没撞上。
  static const DiscoverySearchRelevance none = DiscoverySearchRelevance(
    contiguous: false,
    coverage: 0,
  );

  /// 归一化后的整条查询词作为连续子串出现。
  final bool contiguous;

  /// 按字符数加权的分词覆盖率，0..1。[contiguous] 为真时恒为 1。
  final double coverage;

  /// 是否算命中（低于阈值的由 UI 折叠，不直接删）。
  bool get isRelevant =>
      contiguous || coverage >= kDiscoveryTokenCoverageThreshold;

  /// 连续子串命中 > 分词覆盖率高 > 覆盖率低。
  @override
  int compareTo(DiscoverySearchRelevance other) {
    if (contiguous != other.contiguous) return contiguous ? 1 : -1;
    return coverage.compareTo(other.coverage);
  }

  @override
  String toString() =>
      'DiscoverySearchRelevance(contiguous: $contiguous, coverage: $coverage)';
}

/// 计算 [texts]（一条结果的全部可读文字）相对 [query] 的相关度。纯函数。
DiscoverySearchRelevance discoverySearchRelevance({
  required String query,
  required Iterable<String> texts,
}) {
  final String needle = normalizeMediaSearchText(query);
  if (needle.isEmpty) return DiscoverySearchRelevance.full;
  final List<String> haystacks = texts
      .map(normalizeMediaSearchText)
      .where((String folded) => folded.isNotEmpty)
      .toList(growable: false);
  if (haystacks.isEmpty) return DiscoverySearchRelevance.none;
  if (haystacks.any((String h) => h.contains(needle))) {
    return DiscoverySearchRelevance.full;
  }
  int total = 0;
  int hit = 0;
  for (final String raw in query.split(_queryTokenSeparators)) {
    final String token = normalizeMediaSearchText(raw);
    if (token.isEmpty) continue;
    // 按码点数加权（不按 UTF-16 单元）：补充平面汉字与基本区字符同权。
    final int weight = token.runes.length;
    total += weight;
    if (haystacks.any((String h) => h.contains(token))) hit += weight;
  }
  if (total == 0) return DiscoverySearchRelevance.none;
  return DiscoverySearchRelevance(contiguous: false, coverage: hit / total);
}

/// 一条发现结果参与相关度判定的文字：标题、源给的标注（作者 / 简介 / 平台），
/// 直链资源再加真实文件名（标题被源改写过时，文件名仍是站点上的原名）。
List<String> discoveryEntrySearchTexts(DiscoveryEntry entry) {
  final List<String> texts = <String>[entry.title];
  switch (entry) {
    case DiscoveryFolder(:final String? note):
      if (note != null) texts.add(note);
    case DiscoveryResourceItem(
      :final String? note,
      :final DiscoveryPayload? payload,
    ):
      if (note != null) texts.add(note);
      if (payload is DiscoveryHttpPayload && payload.fileName != null) {
        texts.add(payload.fileName!);
      }
  }
  return texts;
}

/// [entry] 相对 [query] 的相关度（[discoverySearchRelevance] 的条目版）。
DiscoverySearchRelevance discoveryEntryRelevance(
  String query,
  DiscoveryEntry entry,
) => discoverySearchRelevance(
  query: query,
  texts: discoveryEntrySearchTexts(entry),
);

/// 按相关度降序**稳定**重排 [entries]（同档保持源给出的原序）。空查询原样返回。
/// 不删条目——见库注释「不命中的条目不删」。纯函数。
List<DiscoveryEntry> rankDiscoveryEntriesByRelevance(
  String query,
  List<DiscoveryEntry> entries,
) {
  if (normalizeMediaSearchText(query).isEmpty || entries.length < 2) {
    return entries;
  }
  final List<(DiscoveryEntry, DiscoverySearchRelevance)> scored =
      <(DiscoveryEntry, DiscoverySearchRelevance)>[
        for (final DiscoveryEntry e in entries)
          (e, discoveryEntryRelevance(query, e)),
      ];
  // List.sort 不稳定，同档会打乱源给的顺序（Nyaa 已按做种排过）。
  mergeSort<(DiscoveryEntry, DiscoverySearchRelevance)>(
    scored,
    compare:
        (
          (DiscoveryEntry, DiscoverySearchRelevance) a,
          (DiscoveryEntry, DiscoverySearchRelevance) b,
        ) => b.$2.compareTo(a.$2),
  );
  return <DiscoveryEntry>[
    for (final (DiscoveryEntry, DiscoverySearchRelevance) s in scored) s.$1,
  ];
}
