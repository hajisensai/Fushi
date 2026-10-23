/// 书 / 漫画分卷 → 系列的判据（纯函数，无 IO）。
///
/// 「志乃と恋 [3574f94a]」「志乃と恋 ２」「志乃と恋 第4巻」同属系列「志乃と恋」；
/// 「安達としまむら」「安達としまむら10」「安達としまむら13 (電撃文庫)」同属
/// 「安達としまむら」。导入后按 [BookSeriesKey.key] 相同把多卷收进同一个合集，卷号
/// 只决定合集内顺序。
library;

/// 一个分卷标题解析出的系列身份。
class BookSeriesKey {
  const BookSeriesKey({
    required this.key,
    required this.seriesTitle,
    required this.volume,
  });

  /// 比较用的归一化系列键（全角折半角、空白折叠、ASCII 小写）。
  final String key;

  /// 给合集起名用的系列名（原文写法，只去掉卷号、出版标签与 CRC 后缀）。
  final String seriesTitle;

  /// 卷号（可带一位小数，如「99.9」）；标题里没有卷号（通常是第 1 卷）为 null。
  final num? volume;
}

/// 发布文件名里的 8 位十六进制 CRC 标签（`志乃と恋 [3574f94a].cbz`，导入时
/// 文件名原样成了书名）。
final RegExp _hashSuffix = RegExp(r'\s*\[[0-9a-fA-F]{8}\]\s*$');

/// 结尾卷号：`2` / `第2巻` / `2巻` / `Vol.2` / `Vol-2` / `Volume 2` / `v02` /
/// `(2)` / `#2`，以及直接贴在汉字 / 假名后的 `安達としまむら10`。数字前必须有
/// 分隔或非 ASCII 字符，「86」这类纯数字书名、「Catch22」这类拉丁字母贴数字的
/// 书名尾数不会被吃掉（「Fahrenheit 451」会被读成卷号，但归组要求同系列 ≥2 卷，
/// 单本不受影响）。只在全角已折半角的串上匹配。
final RegExp _volumeSuffix = RegExp(
  r'(?:\s+|[\s_\-:・]*(?:第|vol(?:ume)?[\s._\-]*|v(?=\d)|#)|\s*\(|(?<=[^\x00-\x7F]))'
  r'(\d{1,4}(?:\.\d)?)'
  r'\s*(?:巻|卷|册|冊)?\s*\)?\s*$',
  caseSensitive: false,
);

/// 结尾的出版 / 版本标签：`(電撃文庫)`、`<上>`、`【特装版】`。
final RegExp _trailingLabel = RegExp(r'\s*[(\[【<][^()\[\]【】<>]*[)\]】>]\s*$');

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

/// 在折叠串 [folded] 上切出「系列名结束下标 + 卷号」：[parseBookSeriesKey] 与
/// [parseBookVolumeFolderName] 共用，卷号判据只有这一份。
///
/// 卷号匹配不上时先剥一层结尾标签再试（`安達としまむら13 (電撃文庫)`）。
({int end, num? volume}) _splitVolumeSuffix(String folded) {
  int end = _hashSuffix.firstMatch(folded)?.start ?? folded.length;
  RegExpMatch? m = _volumeSuffix.firstMatch(folded.substring(0, end));
  if (m == null) {
    end = _trailingLabel.firstMatch(folded.substring(0, end))?.start ?? end;
    m = _volumeSuffix.firstMatch(folded.substring(0, end));
  }
  num? volume;
  if (m != null) {
    volume = num.parse(m.group(1)!);
    end = m.start;
  }
  end = _trailingSeparators.firstMatch(folded.substring(0, end))?.start ?? end;
  return (end: end, volume: volume);
}

/// 比较用的归一化系列键：去首尾空白、空白折叠、ASCII 小写（[folded] 须已折半角）。
String _normalizeSeriesKey(String folded) =>
    folded.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

/// 解析 [title]；去掉卷号后系列名为空时返回 null（不参与归组）。
///
/// 匹配在折叠串上做，合集名按同一下标从**原文**截取（不把用户书名里的 `～`
/// 改成 `~`）。
BookSeriesKey? parseBookSeriesKey(String title) {
  final String folded = _foldWidth(title);
  final BookSeriesKey? labelled = _seriesFromTrailingLabel(
    title,
    folded,
    _hashSuffix.firstMatch(folded)?.start ?? folded.length,
  );
  if (labelled != null) return labelled;
  final ({int end, num? volume}) split = _splitVolumeSuffix(folded);
  final String key = folded.substring(0, split.end).trim();
  if (key.isEmpty) return null;
  return BookSeriesKey(
    key: _normalizeSeriesKey(key),
    seriesTitle: title.substring(0, split.end).trim(),
    volume: split.volume,
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
  final ({int end, num? volume}) split = _splitVolumeSuffix(folded);
  final num? volume = split.volume;
  if (volume == null) return null;
  final String prefix = _normalizeSeriesKey(folded.substring(0, split.end));
  if (prefix.isEmpty) return (volume: volume, namesSeries: false);
  if (prefix == _normalizeSeriesKey(_foldWidth(seriesFolderName))) {
    return (volume: volume, namesSeries: true);
  }
  return null;
}

/// [titles] 是否全都是同一系列的分卷（每个都解析得出 [BookSeriesKey] 且 `key` 相同）：
/// 是则返回该系列键，否则（含空输入、任一解析不出）null。
///
/// 系列合集的「同系列」判据只有这一份：`BookSeriesOrder` 判合集能否按卷号定序、
/// 首页续读卡判书名尾数能否当卷号，都经它。
String? sharedBookSeriesKey(Iterable<String> titles) {
  String? shared;
  for (final String title in titles) {
    final String? key = parseBookSeriesKey(title)?.key;
    if (key == null || (shared != null && key != shared)) return null;
    shared = key;
  }
  return shared;
}
