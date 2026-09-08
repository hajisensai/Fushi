/// Nyaa Literature（`3_x`）条目的「小说 vs 漫画」启发式分类器。
///
/// nyaa 的 Literature 分类把轻小说、扫图漫画、同人志图包混放，站方没有
/// 「小说 vs 漫画」维度；实测 3_1 做种榜前 75 条约 54 漫画 / 21 小说，不过滤
/// 的话小说域发现页大半是漫画。业界没有现成分类器（Jackett/Prowlarr 一律映射
/// 成 Books；chaptr 用出版社词表并自注「stick/lucaz 假阳性高」），这里按
/// 设计稿 `docs/specs/2026-09-08-nyaa-novel-discovery-filters.md` 第 3 节的
/// 规则表打分：
///
/// - 漫画分 M、小说分 N 各自累加（同一判据只记一次）；
/// - `M − N ≥ 2` → manga，`N − M ≥ 2` → novel，其余 undecided（保留显示）；
/// - `Audiobook|MP3|M4B|FLAC|M4A` → audiobook，不参与判定。
///
/// 关键取舍：**发布组名不是信号**——`LuCaZ / Stick / Ushi / Oak / nao` 两种都发
/// （chaptr 语料把 `Youjo Senki v24-27 (2024-2025) (Digital) (Ushi)` 错标成 LN
/// 正是这个反例），只能靠括号形状：wotaku 命名规范里 `()` 漫画、`[]` 轻小说。
///
/// 纯函数，无 IO；不做逐条 `/view/<id>` 文件列表抓取（每条一次请求，二期再说）。
library;

import 'package:html_unescape/html_unescape.dart';

import 'package:fushi/src/media/discovery/discovery_models.dart';

/// 一条标题的打分明细。[hint] 是最终判定。
class NyaaLiteratureScore {
  const NyaaLiteratureScore({
    required this.manga,
    required this.novel,
    required this.audiobook,
  });

  /// 漫画分 M。
  final int manga;

  /// 小说分 N。
  final int novel;

  /// 命中有声书判据（此时 [manga] / [novel] 仍会算出来，但不参与判定）。
  final bool audiobook;

  DiscoveryContentHint get hint {
    if (audiobook) return DiscoveryContentHint.audiobook;
    if (manga - novel >= 2) return DiscoveryContentHint.manga;
    if (novel - manga >= 2) return DiscoveryContentHint.novel;
    return DiscoveryContentHint.undecided;
  }

  @override
  String toString() =>
      'NyaaLiteratureScore(manga: $manga, novel: $novel, audiobook: $audiobook)';
}

/// 判定一条 Nyaa Literature 条目是小说还是漫画。见库注释。
///
/// [title] 先做 HTML 反转义（nyaa 标题里 `&amp;` 常见），正则一律不区分大小写。
/// [sizeBytes] 参与体积规则（null 跳过）。[categoryId] 为 nyaa 分类 id：`2_x`
/// （Audio）直接判 audiobook，其余不影响打分——`3_1/3_2/3_3` 只区分译文语言，
/// 与「小说 vs 漫画」无关。
DiscoveryContentHint classifyNyaaLiterature({
  required String title,
  int? sizeBytes,
  String? categoryId,
}) =>
    scoreNyaaLiterature(
      title: title,
      sizeBytes: sizeBytes,
      categoryId: categoryId,
    ).hint;

/// [classifyNyaaLiterature] 的打分版本，测试/调试看明细用。
NyaaLiteratureScore scoreNyaaLiterature({
  required String title,
  int? sizeBytes,
  String? categoryId,
}) {
  final String text = _unescape.convert(title).trim();
  final bool audiobook =
      _audiobook.hasMatch(text) || (categoryId?.startsWith('2_') ?? false);

  int manga = 0;
  int novel = 0;
  for (final RegExp rule in _strongManga) {
    if (rule.hasMatch(text)) manga += 3;
  }
  if (_hasNonYearNumberRange(text)) manga += 3;
  for (final RegExp rule in _mediumManga) {
    if (rule.hasMatch(text)) manga += 2;
  }
  for (final RegExp rule in _strongNovel) {
    if (rule.hasMatch(text)) novel += 3;
  }
  for (final RegExp rule in _mediumNovel) {
    if (rule.hasMatch(text)) novel += 2;
  }
  for (final RegExp rule in _weakNovel) {
    if (rule.hasMatch(text)) novel += 1;
  }

  final (int, int) sizeScore = _sizeScore(text, sizeBytes);
  manga += sizeScore.$1;
  novel += sizeScore.$2;

  return NyaaLiteratureScore(manga: manga, novel: novel, audiobook: audiobook);
}

final HtmlUnescape _unescape = HtmlUnescape();

RegExp _ci(String source) => RegExp(source, caseSensitive: false);

final RegExp _audiobook = _ci(r'\b(Audiobook|MP3|M4B|FLAC|M4A)\b');

/// 强漫画 +3（每条判据独立计分）。
final List<RegExp> _strongManga = <RegExp>[
  // 括号源标签：(Digital) / (Digital-Compilation) / (c2c) / (Scan) / (Colored)。
  _ci(r'\((Digital(?:-[\w ]+)?|c2c|Scans?(?:ned)?|Colou?red(?: Manga| Comics)?)\)'),
  // 漫画容器名。
  _ci(r'\b(cbz|cbr|cb7|cbt)\b'),
  // 类型词（英文）。
  _ci(r'\b(Manga|Manhwa|Manhua|Webtoon|Doujinshi?|Scanlations?|Tankobon|Omake|One-?shot)\b'),
  // 类型词（日文：`\b` 对 CJK 无效，直接子串）。
  _ci('一般コミック|コミック|漫画|週刊|月刊|雑誌|ジャンプ|マガジン|サンデー'),
  // 章节编号：c12 / ch.12 / Chapter 12 / c12.5。
  _ci(r'\b(?:c|ch|chapter)\.?\s?\d{1,4}(?:\.\d)?\b'),
  // 「001-050 as v01」形态的章节→卷映射。
  _ci(r'\d{3}-\d{3}\s+as\s+v\d{2}'),
  // 周更包。
  _ci(r'Weekly .*Chapter Updates|\bWeek \d{1,2}\b'),
];

/// 三到四位数区间（章节区间 `101-150`）。年份区间 `(2024-2025)` 形状相同，
/// 设计稿把它单列为中漫画 +2，这里必须排除掉，否则一条 `Title (2020-2023)
/// [Yen Press]` 会白拿 +3 强漫画分。
final RegExp _numberRange = RegExp(r'\b(\d{3,4})\s*[-–~]\s*(\d{3,4})\b');

bool _isYear(int value) => value >= 1900 && value <= 2099;

bool _hasNonYearNumberRange(String text) {
  for (final RegExpMatch m in _numberRange.allMatches(text)) {
    final int first = int.parse(m.group(1)!);
    final int second = int.parse(m.group(2)!);
    if (!(_isYear(first) && _isYear(second))) return true;
  }
  return false;
}

/// 中漫画 +2。
final List<RegExp> _mediumManga = <RegExp>[
  // 年份括号后紧跟另一个括号：`(2024-2025) (Digital)` 是漫画命名规范的骨架。
  _ci(r'\(\d{4}(?:-\d{4})?\)\s*\('),
  // 图片格式。
  _ci(r'\b(JXL|JPEG-?XL|WebP)\b'),
  // 漫画专属发布组（`PapriKa+` 末尾是 `+`，`\b` 接不上，用显式非字词环视）。
  _ci(r'(?<!\w)(1r0n|\w+-Empire|\w+-DCP|Shizu|Kaos|Rillant|Trite|0v3r|Colored Council|PapriKa\+|Chromatique|aKraa|Kileko)(?!\w)'),
  // 版本词。
  _ci(r'\b(Omnibus|Deluxe Edition|Perfect Edition|Master Edition|2-in-1)\b'),
];

/// 强小说 +3。
final List<RegExp> _strongNovel = <RegExp>[
  // 类型词（英文）。`Graphic Novel` / `Visual Novel` 不算。
  _ci(r'\b(Light ?Novels?|LNs?|WN|Web Novel|Ranobe)\b'),
  _ci(r'(?<!Graphic |Visual )\bNovels?\b'),
  // 类型词（日/中文）。
  _ci('ライトノベル|ラノベ|一般小説|小説|轻小说|輕小說'),
  // 电子书格式。
  _ci(r'\b(EPUB|AZW3?|MOBI)\b'),
  // LN 专属出版社（方括号可有可无）。
  _ci(r'(?<!\w)(Yen Press|Yen On|J-?Novel Club|Cross Infinite World|Tentai Books|Hanashi Media|One Peace Books|Sol Press|Airship)(?!\w)'),
  // LN 专属发布者。
  _ci(r'\b(CleanBookGuy|faratnis|Antithetical|Zaphkiel|vgperson|Skeweds|Mochiguma|SpicyEPUBs|Baka-Tsuki|LNWNCentral)\b'),
];

/// 中小说 +2。
final List<RegExp> _mediumNovel = <RegExp>[
  // 尾部连续 ≥2 个不含数字的方括号：`[Yen Press] [Stick]`（`[ABCD1234]` 不算）。
  _ci(r'(\[[^\]\d]{2,}\]\s*){2,}$'),
  // 双栖出版社只在方括号里才算小说信号（括号形状即类型）。
  _ci(r'\[(Seven Seas(?: Siren)?|Vertical|Kodansha|Viz|Square Enix|Dark Horse)\]'),
  // J-Novel Club 分级。
  _ci(r'\b(Premium|Prepub)\b'),
  // 阅读平台。
  _ci(r'\b(Kobo|Kindle(?:HQ)?|iBooks|Google Play)\b'),
];

/// 弱小说 +1。`LuCaZ / Stick / Ushi / Oak / nao` 刻意 0 分。
final List<RegExp> _weakNovel = <RegExp>[
  _ci(r'\bPDF\b'),
  _ci(r'(?<!\w)BookWalker(?!\w)'),
];

const int _mib = 1024 * 1024;
const int _gib = 1024 * _mib;

/// 合集/图包：体积与卷数无关，跳过体积规则。
final RegExp _sizeSkip =
    _ci(r'\b(Collection|Pack|Dump|Anthology|Bundle|SiteRip)\b');

/// 单文件形态：标题以文件扩展名结尾。
final RegExp _singleFile =
    _ci(r'\.(cbz|cbr|cb7|cbt|epub|pdf|azw3?|mobi|zip|rar|7z)$');

final RegExp _volumeRange = _ci(r'\bv(\d{1,3})\s*[-–~]\s*v?(\d{1,3})\b');
final RegExp _jpVolumeRange = RegExp(r'第(\d{1,3})\s*[-–~]\s*(\d{1,3})巻');
final RegExp _singleVolume = _ci(r'\bv\d{1,3}\b|第\d{1,3}巻');

/// 从标题解析卷数 n；认不出返回 null。
int? _volumeCount(String text) {
  for (final RegExp range in <RegExp>[_volumeRange, _jpVolumeRange]) {
    final RegExpMatch? m = range.firstMatch(text);
    if (m == null) continue;
    final int first = int.parse(m.group(1)!);
    final int second = int.parse(m.group(2)!);
    if (second >= first) return second - first + 1;
  }
  if (_singleVolume.hasMatch(text)) return 1;
  return null;
}

/// 体积规则 → (漫画加分, 小说加分)。
///
/// LN EPUB 每卷 p50 14.8 MiB、p99 45 MiB；英文数字版漫画 70–500 MiB/卷；
/// 日文生肉漫画 50–220；30–60 MiB 是重叠区、不给分。
(int, int) _sizeScore(String text, int? sizeBytes) {
  if (sizeBytes == null || sizeBytes <= 0) return (0, 0);
  if (_sizeSkip.hasMatch(text)) return (0, 0);
  final int? volumes = _volumeCount(text);
  if (volumes == null) {
    if (sizeBytes > 2 * _gib) return (0, 0);
    if (sizeBytes > 150 * _mib && _singleFile.hasMatch(text)) return (2, 0);
    if (sizeBytes < 30 * _mib) return (0, 1);
    return (0, 0);
  }
  final double perVolume = sizeBytes / volumes;
  if (perVolume < 25 * _mib) return (0, 2);
  if (perVolume <= 60 * _mib) return (0, 0);
  if (perVolume <= 150 * _mib) return (2, 0);
  return (3, 0);
}
