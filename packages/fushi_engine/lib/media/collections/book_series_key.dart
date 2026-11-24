/// 书 / 漫画分卷 → 系列的判据（纯函数，无 IO）。
///
/// 「志乃と恋 [3574f94a]」「志乃と恋 ２」「志乃と恋 第4巻」同属系列「志乃と恋」；
/// 「安達としまむら」「安達としまむら10」「安達としまむら13 (電撃文庫)」同属
/// 「安達としまむら」。导入后按 [BookSeriesKey.key] 相同把多卷收进同一个合集，卷号
/// 只决定合集内顺序。
///
/// 书名的形态（[parseBookSeriesKey] 按这个文法从外往里剥，不是一串互不相干的
/// 「结尾正则」）：
///
/// ```
/// 书名   := 『正篇』特典后缀            → 正篇的特典册（[BookSeriesKey.bonus]）
///         | 正篇 [CRC]
/// 正篇   := 系列名 { 卷号 | 话号 | 标签 | 副标题 }      （花括号内任意顺序）
///         | 系列名 卷号 空白 自由副标题
/// 标签   := (電撃文庫) | 【電子限定特典付き】 | <上>
/// 副标题 := ～…～ | ─…─ | ␣-…-
/// ```
///
/// 系列身份只取「系列名」：副标题不进系列键——同一套书中途换副标题很常见
/// （「週に一度クラスメイトを買う話」1–4 卷「～ふたりの時間、言い訳の五千円～」、
/// 5 卷起「～ふたりの秘密は一つ屋根の下～」），带着副标题比就永远凑不成一组。
library;

import 'package:fushi_engine/media/collections/shelf_sort.dart'
    show naturalCompare;
import 'package:fushi_engine/media/collections/store_series_annotation.dart';
import 'package:fushi_engine/media/titles/media_title_clean.dart';

/// 一个分卷标题解析出的系列身份。
class BookSeriesKey {
  const BookSeriesKey({
    required this.key,
    required this.seriesTitle,
    required this.volume,
    this.episode,
    this.split = 0,
    this.bonus = false,
  });

  /// 比较用的归一化系列键（全角折半角、空白折叠、ASCII 小写）。
  final String key;

  /// 给合集起名用的系列名（原文写法，只去掉卷号、话号、出版标签、副标题与 CRC
  /// 后缀）。
  final String seriesTitle;

  /// 卷号（可带一位小数，如「99.9」）；标题里没有卷号（通常是第 1 卷）为 null。
  final num? volume;

  /// 话号：漫画按话发布时书名结尾的「第N話」（可带「前編 / 中編 / 後編」分段），
  /// 如「十歳の最強魔導師 第1話 前編 [c36675f0]」→ `(number: 1, part: 1)`；没有
  /// 话号为 null。
  ///
  /// 话号与卷号分开存：卷号会被追踪（按卷推进度）与有声书配对拿去用，第 12 话
  /// 不是第 12 卷。话号只参与合集内排序（[compareBookSeriesPosition]）。
  final BookEpisodeNumber? episode;

  /// 分册：书名结尾的「上 / 中 / 下」（`X 上`、`X (下)`、`X 上巻`、`X 下册`），1 = 上、
  /// 2 = 中、3 = 下，没有为 0（BUG-5377）。
  ///
  /// 不折成卷号：只看一个书名不知道「下」是第 2 卷还是第 3 卷（上下两册 / 上中下
  /// 三册）。排序排在卷号之后（`第2巻 上` < `第2巻 下`），续读卡的「第 N 卷」按同系列
  /// 兄弟里的名次算（[collectionMemberVolumeNumber]）。
  final int split;

  /// 特典册：书名是「『正篇书名』+ 店铺特典后缀」
  /// （`『週に一度クラスメイトを買う話２　～…～』BOOK☆WALKER限定書き下ろしショートストーリー`）。
  /// 系列键与卷号取引号里的正篇，所以它与正篇同组；合集内排在同卷正篇之后
  /// （[compareBookSeriesPosition]）。
  final bool bonus;
}

/// 话号与同话分段：[part] 为 0（无分段）、1（前編）、2（中編）、3（後編）。
typedef BookEpisodeNumber = ({num number, int part});

/// 一卷在系列里的位置：卷号、分册、话号、同话分段、是否特典册。
typedef BookSeriesPosition = ({
  num? volume,
  int split,
  num? episode,
  int part,
  bool bonus,
});

/// 同系列两卷在合集里的先后：卷号（无卷号当第 0 卷）→ 分册（上 / 中 / 下）→ 话号
/// （无话号当第 0 话）→ 同话分段 → 正篇先于同卷的特典册。相等返回 0，调用方再按书名等兜底。
int compareBookSeriesPosition(BookSeriesKey a, BookSeriesKey b) =>
    compareBookSeriesPositionParts(
      volumeA: a.volume,
      episodeA: a.episode,
      splitA: a.split,
      bonusA: a.bonus,
      volumeB: b.volume,
      episodeB: b.episode,
      splitB: b.split,
      bonusB: b.bonus,
    );

/// [compareBookSeriesPosition] 的拆开版：调用方只存了卷号与话号（AI 合集排序的
/// 成员）时用，判据只有这一份。
int compareBookSeriesPositionParts({
  required num? volumeA,
  required BookEpisodeNumber? episodeA,
  required num? volumeB,
  required BookEpisodeNumber? episodeB,
  int splitA = 0,
  int splitB = 0,
  bool bonusA = false,
  bool bonusB = false,
}) {
  final int v = (volumeA ?? 0).compareTo(volumeB ?? 0);
  if (v != 0) return v;
  final int s = splitA.compareTo(splitB);
  if (s != 0) return s;
  final int e = (episodeA?.number ?? 0).compareTo(episodeB?.number ?? 0);
  if (e != 0) return e;
  final int p = (episodeA?.part ?? 0).compareTo(episodeB?.part ?? 0);
  if (p != 0) return p;
  return (bonusA ? 1 : 0).compareTo(bonusB ? 1 : 0);
}

/// 「按卷号」排序用的预解析键：原书名 + [parseBookSeriesKey] 的结果（解析不出为
/// null）。排序前对每个成员算一次（[bookVolumeSortKey]），比较器里不再跑正则。
typedef BookVolumeSortKey = ({String title, BookSeriesKey? series});

/// [title] 的「按卷号」排序键。
BookVolumeSortKey bookVolumeSortKey(String title) =>
    (title: title, series: parseBookSeriesKey(title));

/// 合集成员「按卷号」的先后（合集详情页「按卷号」、一键整理 / 存为手动顺序、
/// 组合成合集落盘共用这一份）：系列键 natural → 系列内位置
/// （[compareBookSeriesPositionParts]：卷号 → 话号 → 分段 → 正篇先于同卷特典册）
/// → 书名 natural。解析不出系列的书名以整串当系列键、位置当第 0 卷——每个书名
/// 都映射成同一形状的元组逐位比，是全序（`List.sort` 不会因不传递而乱序）。
///
/// 此前「按卷号」只是显示名 natural：`『週に一度クラスメイトを買う話２　～…～』
/// BOOK☆WALKER限定…` 九本特典册的 `『`（U+300E）码元小于正篇的 `週`（U+9031），
/// 整组排到第 1 卷前面（反馈 WiApB3TljP）。
int compareBookVolumeSortKeys(BookVolumeSortKey a, BookVolumeSortKey b) {
  final BookSeriesKey? sa = a.series;
  final BookSeriesKey? sb = b.series;
  final int g = naturalCompare(sa?.key ?? a.title, sb?.key ?? b.title);
  if (g != 0) return g;
  final int p = compareBookSeriesPositionParts(
    volumeA: sa?.volume,
    episodeA: sa?.episode,
    splitA: sa?.split ?? 0,
    bonusA: sa?.bonus ?? false,
    volumeB: sb?.volume,
    episodeB: sb?.episode,
    splitB: sb?.split ?? 0,
    bonusB: sb?.bonus ?? false,
  );
  if (p != 0) return p;
  return naturalCompare(a.title, b.title);
}

/// [key] 在系列里的位置，供「同系列各卷位置互不重复」判定；书名里既无卷号也无
/// 话号、又不是特典册时 null（无卷号的特典册挂在无卷号的正篇后面，位置确定）。
BookSeriesPosition? bookSeriesPosition(BookSeriesKey key) =>
    bookSeriesPositionOf(
      volume: key.volume,
      episode: key.episode,
      split: key.split,
      bonus: key.bonus,
    );

/// [bookSeriesPosition] 的拆开版（同 [compareBookSeriesPositionParts]）。
BookSeriesPosition? bookSeriesPositionOf({
  required num? volume,
  required BookEpisodeNumber? episode,
  int split = 0,
  bool bonus = false,
}) {
  if (volume == null && episode == null && split == 0 && !bonus) return null;
  return (
    volume: volume,
    split: split,
    episode: episode?.number,
    part: episode?.part ?? 0,
    bonus: bonus,
  );
}

/// 发布文件名末尾的 8 位十六进制 CRC 标签（`志乃と恋 [3574f94a].cbz`，导入时
/// 文件名原样成了书名）。判据是全媒体共用的 [trailingCrcTagsPattern]（方括号 /
/// 圆括号、大小写都认、可连续多段；此前这里只认一段方括号）。
final RegExp _hashSuffix = trailingCrcTagsPattern;

/// 结尾卷号：`2` / `第2巻` / `2巻` / `Vol.2` / `Vol-2` / `Volume 2` / `v02` /
/// `(2)` / `#2`、连字符 / 下划线卷号 `Karakai-Jouzu-Takagi-san-02` / `Series_02`，
/// 以及直接贴在汉字 / 假名后的 `安達としまむら10`。数字前必须有分隔或非 ASCII
/// 字符，「86」这类纯数字书名、「Catch22」这类拉丁字母贴数字的书名尾数不会被吃掉
/// （「Fahrenheit 451」「Spider-Man 2099」「Spider-Man-2099」会被读成卷号，但归组
/// 要求同系列 ≥2 卷，单本不受影响）。只在全角已折半角的串上匹配。
///
/// 连字符 / 下划线分隔只认紧跟在字母、`)` / `]` 或非 ASCII 字符之后的一个 `-` /
/// `_`（vECncM6f8Y：mokuro.moe 卷名是连字符化的 slug，`…-02` 以前不认，每卷系列键
/// 各不相同、整套散在书架上）；数字后的 `-`（`2-02`）不算，免得把编号拆开。
final RegExp _volumeSuffix = RegExp(
  r'(?:\s+|[\s_\-:・]*(?:第|vol(?:ume)?[\s._\-]*|v(?=\d)|#)|\s*\(|'
  r'(?<=[A-Za-z)\]]|[^\x00-\x7F])[\-_]\s*|(?<=[^\x00-\x7F]))'
  r'(\d{1,4}(?:\.\d)?)'
  r'\s*(?:巻|卷|册|冊)?\s*\)?\s*$',
  caseSensitive: false,
);

/// 结尾话号：`第1話` / `第1话` / `第12話 前編` / `第3話・後編` / `第2.5話`。只在
/// [parseBookSeriesKey] 用——目录语境（[parseBookVolumeFolderName]）里「第1話」
/// 是章节子目录、不是分卷，所以不进共用的 [_volumeSuffix]。只在全角已折半角、
/// 已去掉 CRC 后缀的串上匹配；话号前必须有分隔或非 ASCII 字符。
final RegExp _episodeSuffix = RegExp(
  r'(?:[\s_\-:・]+|(?<=[^\x00-\x7F]))'
  r'第\s*(\d{1,4}(?:\.\d)?)\s*[話话]'
  r'(?:[\s_\-:・]*([前中後后])[編编篇])?\s*$',
);

/// 同话分段字 → [BookEpisodeNumber.part]。
int _episodePart(String? mark) => switch (mark) {
  '前' => 1,
  '中' => 2,
  '後' || '后' => 3,
  _ => 0,
};

/// 结尾的出版 / 版本标签：`(電撃文庫)`、`<上>`、`【特装版】`。
final RegExp _trailingLabel = RegExp(r'\s*[(\[【<][^()\[\]【】<>]*[)\]】>]\s*$');

/// 结尾分册：`X 上` / `X (中)` / `X <下>` / `X〈上〉` / `X 上巻` / `X下巻` / `X 上卷` /
/// `X 下册` / `X 上集`。分册字前须有空白或左括号，或者后面紧跟巻 / 卷 / 册 / 冊 / 集
/// ——「本好きの下剋上」这种以「上」结尾的书名不算。只在全角已折半角的串上匹配。
final RegExp _splitSuffix = RegExp(
  r'(?:(?:\s+|\s*[(\[<〈【]\s*)([上中下])(?:\s*[巻卷册冊集])?|\s*([上中下])[巻卷册冊集])'
  r'\s*[)\]>〉】]?\s*$',
);

int _splitPart(String mark) => switch (mark) {
  '上' => 1,
  '中' => 2,
  _ => 3,
};

final RegExp _trailingSeparators = RegExp(r'[\s_\-:・]+$');

/// 全角 ASCII 折半角、全角空格折空格。逐码元 1:1 替换，下标与原串对齐。
String _foldWidth(String s) => String.fromCharCodes(<int>[
  for (final int c in s.codeUnits)
    c >= 0xFF01 && c <= 0xFF5E
        ? c - 0xFEE0
        : c == 0x3000
        ? 0x20
        : c,
]);

/// 结尾成对的副标题：`～ふたりの時間、言い訳の五千円～`、`─エイティシックス─`、
/// ` -虚実-`。只在全角已折半角的串上匹配（`～` 已折成 `~`）。ASCII 连字符必须前有
/// 空白，免得把 slug（`a-b-`）当副标题；副标题里不含同种定界符。
final RegExp _trailingSubtitle = RegExp(
  r'(?:\s+-[^\-]+-|\s*([~〜─―—])[^~〜─―—]+\1)\s*$',
);

/// 卷号夹在系列名与自由副标题之间：`ソードアート・オンライン3 フェアリィ・ダンス`、
/// `魔法科高校の劣等生(3) 九校戦編`、`Overlord 3 The Bloody Valkyrie`。只在结尾认不出
/// 卷号时才试，取第一处；数字前须是非 ASCII 字符或空白（`Catch22 x`、`R2 x` 不算），
/// 数字后须有空白再跟正文（`100万ドル`、`2-02` 不算），至多三位（`0083`、`2099`
/// 这种年份 / 型号不算）。认错的单本不会成组——归组要求同系列 ≥2 卷。
final RegExp _midVolume = RegExp(
  r'(?:(?:(?<=[^\x00-\x7F])|\s+)(\d{1,3}(?:\.\d)?)\s+|'
  r'\s*\((\d{1,3}(?:\.\d)?)\)\s*)(?=\S)',
);

/// 在折叠串 [folded] 上切出「系列名结束下标 + 卷号」：[parseBookSeriesKey] 与
/// [parseBookVolumeFolderName] 共用，卷号判据只有这一份。
///
/// 从结尾往里一层层剥，直到剥不动：卷号（至多一个）、出版 / 版本标签、成对副标题，
/// 三者任意顺序——`安達としまむら13 (電撃文庫)`、`魔法少女にあこがれて【電子限定特典付き】 (1)`、
/// `X２　～副标题～`、`X ～副标题～ 1 (ヤングチャンピオン・コミックス)` 都落到同一个系列名。
/// 以前是「卷号匹配不上才剥一层标签、剥完就停」，卷号后面还有东西、或卷号前夹着
/// 标签的书名每卷系列键各不相同，整套散在书架上。剥到系列名为空就不剥（`(仮)`）。
///
/// [deep] 为 false（目录语境，[parseBookVolumeFolderName]）时只做旧的两步：卷号前
/// 那段要拿去和系列目录名**原样**比较，不能把目录名里的标签 / 副标题剥掉。
({int end, num? volume, int split}) _splitVolumeSuffix(
  String folded, {
  bool deep = true,
}) {
  int end = _hashSuffix.firstMatch(folded)?.start ?? folded.length;
  num? volume;
  int split = 0;
  bool labelPeeled = false;
  while (true) {
    final String head = folded.substring(0, end);
    if (volume == null) {
      final RegExpMatch? m = _volumeSuffix.firstMatch(head);
      if (m != null) {
        volume = num.parse(m.group(1)!);
        end = m.start;
        if (!deep) break;
        continue;
      }
      // 分册在卷号外侧（`第2巻 上`）：剥掉后继续找卷号。
      final RegExpMatch? s = deep && split == 0
          ? _splitSuffix.firstMatch(head)
          : null;
      if (s != null && head.substring(0, s.start).trim().isNotEmpty) {
        split = _splitPart((s.group(1) ?? s.group(2))!);
        end = s.start;
        continue;
      }
    }
    if (!deep && labelPeeled) break;
    final RegExpMatch? label = _trailingLabel.firstMatch(head);
    if (label != null &&
        (!deep || head.substring(0, label.start).trim().isNotEmpty)) {
      end = label.start;
      labelPeeled = true;
      continue;
    }
    if (!deep) break;
    final RegExpMatch? subtitle = _trailingSubtitle.firstMatch(head);
    if (subtitle != null &&
        head.substring(0, subtitle.start).trim().isNotEmpty) {
      end = subtitle.start;
      continue;
    }
    break;
  }
  if (deep && volume == null) {
    final String head = folded.substring(0, end);
    final RegExpMatch? m = _midVolume.firstMatch(head);
    if (m != null && head.substring(0, m.start).trim().isNotEmpty) {
      volume = num.parse((m.group(1) ?? m.group(2))!);
      end = m.start;
    }
  }
  end = _trailingSeparators.firstMatch(folded.substring(0, end))?.start ?? end;
  return (end: end, volume: volume, split: split);
}

/// 比较用的归一化系列键：去首尾空白、空白折叠、ASCII 小写（[folded] 须已折半角）。
String _normalizeSeriesKey(String folded) =>
    folded.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// 解析 [title]；去掉卷号后系列名为空时返回 null（不参与归组）。
///
/// 匹配在折叠串上做，合集名按同一下标从**原文**截取（不把用户书名里的 `～`
/// 改成 `~`）。
BookSeriesKey? parseBookSeriesKey(String title) {
  final BookSeriesKey? bonus = _seriesFromQuotedTitle(title);
  if (bonus != null) return bonus;
  final String folded = _foldWidth(title);
  final int end = _hashSuffix.firstMatch(folded)?.start ?? folded.length;
  final BookSeriesKey? store = _seriesFromStoreAnnotation(
    title.substring(0, end),
  );
  if (store != null) return store;
  final BookSeriesKey? labelled = _seriesFromTrailingLabel(title, folded, end);
  if (labelled != null) return labelled;
  final BookSeriesKey? episodic = _seriesFromEpisodeSuffix(title, folded);
  if (episodic != null) return episodic;
  final ({int end, num? volume, int split}) cut = _splitVolumeSuffix(folded);
  final String key = folded.substring(0, cut.end).trim();
  if (key.isEmpty) return null;
  return BookSeriesKey(
    key: _normalizeSeriesKey(key),
    seriesTitle: title.substring(0, cut.end).trim(),
    volume: cut.volume,
    split: cut.split,
  );
}

/// 书店系列注记：`Re：ゼロから始める異世界生活 1<Re：ゼロから始める異世界生活> (MF文庫J)`
/// ——正文 + 卷号、尖括号里的系列名、最后文库名（判据见
/// [splitStoreSeriesAnnotation]，与显示名清洗共用一份）。
///
/// 以前只有 [_seriesFromTrailingLabel] 认结尾标签，它只看**最后一个**括号：这里最后
/// 一个是 `(MF文庫J)`，不是正文前缀，判不成系列名；卷号路径剥掉文库标签后结尾是
/// `<…>`，卷号也读不出，整串原样成了系列键——每卷互不相同，导入后不归合集
/// （BUG book-series-key-store-annotation）。系列名取尖括号里的写法，卷号从正文
/// 末尾读。
BookSeriesKey? _seriesFromStoreAnnotation(String title) {
  final ({String body, String series})? split = splitStoreSeriesAnnotation(
    title,
  );
  if (split == null) return null;
  final RegExpMatch? volume = _volumeSuffix.firstMatch(_foldWidth(split.body));
  return BookSeriesKey(
    key: _normalizeSeriesKey(_foldWidth(split.series)),
    seriesTitle: split.series,
    volume: volume == null ? null : num.parse(volume.group(1)!),
  );
}

/// 整个书名是「『正篇书名』+ 后缀」时的系列身份：系列键、卷号、话号都取引号里的
/// 正篇；引号后还有文字（店铺特典后缀）就是特典册（[BookSeriesKey.bonus]），没有
/// 则只是书名被引号包着。不是这个形态返回 null。
///
/// 用户书架实报：`『週に一度クラスメイトを買う話２　～…～』BOOK☆WALKER限定書き下ろし
/// ショートストーリー` 九本以前整串当系列名，与正篇、彼此之间都不同组。
BookSeriesKey? _seriesFromQuotedTitle(String title) {
  final String t = title.trimLeft();
  if (t.isEmpty) return null;
  final String? close = switch (t[0]) {
    '『' => '』',
    '「' => '」',
    _ => null,
  };
  if (close == null) return null;
  final int closeAt = t.indexOf(close, 1);
  if (closeAt < 0) return null;
  final BookSeriesKey? inner = parseBookSeriesKey(t.substring(1, closeAt));
  if (inner == null) return null;
  // 引号后只剩卷号 / 标签（`『志乃と恋』 ２ (電撃文庫)`）不是特典后缀：前置空格让
  // 贴着引号的卷号也走正则的空白分支，剥完还有字才算后缀。
  final String tail = ' ${_foldWidth(t.substring(closeAt + 1))}';
  final ({int end, num? volume, int split}) split = _splitVolumeSuffix(tail);
  final bool hasSuffix = tail.substring(0, split.end).trim().isNotEmpty;
  return BookSeriesKey(
    key: inner.key,
    seriesTitle: inner.seriesTitle,
    volume: inner.volume ?? (hasSuffix ? null : split.volume),
    episode: inner.episode,
    split: inner.split,
    bonus: inner.bonus || hasSuffix,
  );
}

/// 书名结尾是话号（[_episodeSuffix]）时的系列身份：系列名取话号前面那段，话号
/// 前若还有卷号（`X 第3巻 第12話`）照常读成卷号。不是话号形态返回 null。
///
/// 按话发布的漫画（「十歳の最強魔導師 第1話 前編 [c36675f0]」）以前整串去掉
/// CRC 后就当系列名，每话的系列键各不相同，一组都凑不成（rT5chqFYOK）。
BookSeriesKey? _seriesFromEpisodeSuffix(String title, String folded) {
  int end = _hashSuffix.firstMatch(folded)?.start ?? folded.length;
  RegExpMatch? m = _episodeSuffix.firstMatch(folded.substring(0, end));
  if (m == null) {
    // 同卷号（[_splitVolumeSuffix]）：话号后跟出版标签时先剥一层再试
    // （`十歳の最強魔導師 第1話 前編 (少年マガジン)`）。
    end = _trailingLabel.firstMatch(folded.substring(0, end))?.start ?? end;
    m = _episodeSuffix.firstMatch(folded.substring(0, end));
  }
  if (m == null) return null;
  final ({int end, num? volume, int split}) split = _splitVolumeSuffix(
    folded.substring(0, m.start),
  );
  final String key = folded.substring(0, split.end).trim();
  if (key.isEmpty) return null;
  return BookSeriesKey(
    key: _normalizeSeriesKey(key),
    seriesTitle: title.substring(0, split.end).trim(),
    volume: split.volume,
    episode: (number: num.parse(m.group(1)!), part: _episodePart(m.group(2))),
  );
}

/// 结尾标签就是系列名：`青春ブタ野郎はバニーガール先輩の夢を見ない<青春ブタ野郎>`。
///
/// 日文轻小说常见写法——每卷副标题各不相同、没有卷号，系列名放在结尾的 `<…>` /
/// `(…)` 里。以前标签一律当出版标签丢掉，各卷 key 互不相同，整套散在书架上
/// （n4KC1azJvw）。判据只认「标签内容是正文的**真前缀**」：`(電撃文庫)`、`<上>`
/// 不是正文前缀，照旧按出版标签处理；不用「多卷共享同一标签」当判据，否则同一文库
/// 的不同作品会被并成一组。正文末尾若还有卷号，照常读成卷号。
BookSeriesKey? _seriesFromTrailingLabel(String title, String folded, int end) {
  final String head = folded.substring(0, end);
  final RegExpMatch? label = _trailingLabel.firstMatch(head);
  if (label == null) return null;
  final int close = head.trimRight().length - 1;
  final int open = head.lastIndexOf(RegExp(r'[(\[【<]'), close);
  if (open < label.start || open >= close) return null;
  final String inner = head.substring(open + 1, close).trim();
  final String body = head.substring(0, label.start).trim();
  // 至少两个字符：单字标签（`<上>`）碰巧是正文首字（`上野さんは…<上>`）不算系列名。
  if (inner.length < 2 ||
      body.length <= inner.length ||
      !body.startsWith(inner)) {
    return null;
  }
  final RegExpMatch? volume = _volumeSuffix.firstMatch(body);
  final int innerStart = head.indexOf(inner, open + 1);
  return BookSeriesKey(
    key: _normalizeSeriesKey(inner),
    seriesTitle: title.substring(innerStart, innerStart + inner.length),
    volume: volume == null ? null : num.parse(volume.group(1)!),
  );
}

/// 网址 slug：只由 ASCII 字母数字词经 `-` / `_` 连成、至少两个词、不含空白
/// （`Karakai-Jouzu-Takagi-san`、`one_piece`）。
final RegExp _slugToken = RegExp(r'^[A-Za-z0-9]+(?:[\-_][A-Za-z0-9]+)+$');

/// slug / 书名里的拉丁词（小写，按非字母数字切）。
List<String> _latinWords(String s) => s
    .toLowerCase()
    .split(RegExp(r'[^a-z0-9]+'))
    .where((String w) => w.isNotEmpty)
    .toList(growable: false);

/// 自动合集名：把系列名 [seriesTitle]（[BookSeriesKey.seriesTitle]）里的网址
/// slug 规整成可读名；不像 slug 的原样返回（去首尾空白）。只改**显示用的合集名**，
/// 归组用的 [BookSeriesKey.key] 不变。
///
/// 两种 slug（vECncM6f8Y 后续拍板：合集名里的网址 slug 自动美化）：
/// - 系列名后面挂着它自己的 slug：`Karakai Jouzu no Takagi-san Karakai-Jouzu-Takagi-san`
///   （mokuro.moe 旧口径卷名，书 key 冻结不改）→ `Karakai Jouzu no Takagi-san`。
///   判据同 mokuro 下载器的卷名规整：slug 的每个词都在前面的正文里出现过（slug
///   常省掉 `no` 之类虚词，按「子集」比）；前缀切不出拉丁词（日文书名）不动。
/// - 整个系列名就是一个 slug：含 `_`（`one_piece`），或至少两个 `-`
///   （`karakai-jouzu-takagi-san`）→ 分隔换空格；全小写时每词首字母大写。只有
///   一个 `-` 的（`Spider-Man`、`Takagi-san`）是正常拼写，不动。
String readableSeriesTitle(String seriesTitle) {
  final String t = seriesTitle.trim();
  final int lastSpace = t.lastIndexOf(RegExp(r'\s'));
  if (lastSpace < 0) return _readableWholeSlug(t) ?? t;
  final String tail = t.substring(lastSpace + 1);
  if (!_slugToken.hasMatch(tail)) return t;
  final String prefix = t.substring(0, lastSpace).trim();
  final Set<String> prefixWords = _latinWords(prefix).toSet();
  final List<String> slugWords = _latinWords(tail);
  if (prefixWords.isEmpty || !slugWords.every(prefixWords.contains)) return t;
  return prefix;
}

/// 整串 slug → 可读名；不算 slug 时 null。
String? _readableWholeSlug(String t) {
  if (!_slugToken.hasMatch(t) || !t.contains(RegExp(r'[A-Za-z]'))) return null;
  if (!t.contains('_') && '-'.allMatches(t).length < 2) return null;
  final bool lower = t == t.toLowerCase();
  return t
      .split(RegExp(r'[\-_]'))
      .map((String w) => lower ? w[0].toUpperCase() + w.substring(1) : w)
      .join(' ');
}

/// 「系列目录/卷目录/页图」布局里，目录名 [name] 作为系列目录 [seriesFolderName]
/// 之下的**卷目录**时的卷号；不像卷目录返回 null。
///
/// 卷号判据与 [parseBookSeriesKey] 是同一条正则（[_splitVolumeSuffix]），只多两点
/// 目录语境下的差别：
/// - 纯数字目录名（`01`、`2`）算卷号——书名「86」刻意不当卷号，但系列目录下一排
///   `01` / `02` 子目录就是分卷；
/// - 卷号前剩下的部分必须为空（`Vol.01`、`Volume 6`、`第3巻`、`3巻`、`v02`、`#4`、
///   `（5）`），或与系列目录名归一化后相同（`ONE PIECE/ONE PIECE 01`）。否则不算：
///   `Chapter 01` / `Episode 2` 是章节目录，`Extra 2` 是附录，同样带尾数但不是卷；
///   `ch01`、`第1話`、`extra`、`images` 连卷号都解析不出。
///
/// `namesSeries` 为真表示目录名自己已带系列名（上面第二种），调用方起卷标题时
/// 不必再拼系列名。
({num volume, bool namesSeries})? parseBookVolumeFolderName(
  String name, {
  required String seriesFolderName,
}) {
  // 前置一个空格，让纯数字名也能走正则的空白分支；下标整体右移一位，这里只取
  // 卷号前缀做比较，不受影响。
  final String folded = ' ${_foldWidth(name)}';
  final ({int end, num? volume, int split}) split = _splitVolumeSuffix(
    folded,
    deep: false,
  );
  final num? volume = split.volume;
  if (volume == null) return null;
  final String prefix = _normalizeSeriesKey(folded.substring(0, split.end));
  if (prefix.isEmpty) return (volume: volume, namesSeries: false);
  if (prefix == _normalizeSeriesKey(_foldWidth(seriesFolderName))) {
    return (volume: volume, namesSeries: true);
  }
  return null;
}

/// 书包里**声明**的系列（EPUB OPF `belongs-to-collection` / `calibre:series`，见
/// `epub_series.dart`）的系列身份：比较键与 [parseBookSeriesKey] 同一套归一化，
/// 声明名与标题解析出的系列名相同时两条路归到同一组。[index] 为空时退回从
/// [title] 解析卷号。
BookSeriesKey declaredBookSeriesKey({
  required String name,
  required num? index,
  required String title,
}) => BookSeriesKey(
  key: _normalizeSeriesKey(_foldWidth(name)),
  seriesTitle: name.trim(),
  volume: index ?? parseBookSeriesKey(title)?.volume,
);

/// [titles] 是否全都是同一系列的分卷（每个都解析得出 [BookSeriesKey] 且 `key` 相同）：
/// 是则返回该系列键，否则（含空输入、任一解析不出）null。
///
/// 系列合集的「同系列」判据只有这一份：`BookSeriesOrder` 判合集能否按卷号定序时
/// 经它（「第 N 卷」标签的卷号判据见 [collectionMemberVolumeNumber]）。
String? sharedBookSeriesKey(Iterable<String> titles) {
  String? shared;
  for (final String title in titles) {
    final String? key = parseBookSeriesKey(title)?.key;
    if (key == null || (shared != null && key != shared)) return null;
    shared = key;
  }
  return shared;
}

/// 合集成员「第 N 卷」标签里的 N（首页续读卡徽标、书架合集卡「读到第 N 卷」共用
/// 这一份，不各写一套）。
///
/// [title] 是该成员显示的书名，[memberTitles] 是合集全部成员的显示书名（含本卷，
/// 合集内顺序），[memberOrdinal] 是该成员在合集内第几个（1 起，与合集详情页同序）。
///
/// N 是**卷号**，不是存储位置：本卷书名解析出的系列（[parseBookSeriesKey]）在合集
/// 里至少有两卷（本卷 + 一个同系列兄弟）时，取书名卷号；书名没卷号、而同系列兄弟
/// 都带卷号且没有第 1 卷，它就是第 1 卷（`安達としまむら` + `安達としまむら2…`）。
/// 其余——主题合集里只此一本的「Fahrenheit 451」、番外 / 外传（`安達としまむらSS`
/// 系列键与正篇不同、合集里只此一本）、无卷号且认不出是第几卷——退回合集内序号。
///
/// 用户实报（BUG continue-card-volume-number）：「安達としまむら」合集混了番外，旧
/// 判据要求**全体**成员同系列，一混番外就整组退回位置；合集顺序又被打乱，正在读的
/// 第 3 卷排在第 13 位，续读卡显示「第 13 卷」。只看本卷所在系列，不看全体是否同系列。
num collectionMemberVolumeNumber({
  required String title,
  required List<String> memberTitles,
  required int memberOrdinal,
}) {
  final BookSeriesKey? own = parseBookSeriesKey(title);
  if (own == null) return memberOrdinal;
  // 同系列成员（含本卷）；本卷在 [memberTitles] 里出现一次即计一次。
  final List<BookSeriesKey> siblings = <BookSeriesKey>[
    for (final String member in memberTitles)
      if (parseBookSeriesKey(member) case final BookSeriesKey k
          when k.key == own.key)
        k,
  ];
  final List<num?> siblingVolumes = <num?>[
    for (final BookSeriesKey k in siblings) k.volume,
  ];
  if (siblingVolumes.length < 2) return memberOrdinal;
  final num? volume = own.volume;
  if (volume != null) return volume;
  // 无卷号的分册（上 / 中 / 下）：按同系列分册里的名次算，上下两册的「下」是第 2 卷、
  // 上中下三册的「下」是第 3 卷（BUG-5377）。
  if (own.split > 0) {
    final Set<int> splits = <int>{
      for (final BookSeriesKey k in siblings)
        if (k.volume == null && k.split > 0) k.split,
    };
    return splits.where((int s) => s < own.split).length + 1;
  }
  // 无卷号的卷：同系列里恰好只有它没卷号、且没有别的卷自称第 1 卷，才是第 1 卷。
  final bool onlyUnnumbered =
      siblingVolumes.where((num? v) => v == null).length == 1;
  final bool hasVolumeOne = siblingVolumes.any((num? v) => v == 1);
  return onlyUnnumbered && !hasVolumeOne ? 1 : memberOrdinal;
}
