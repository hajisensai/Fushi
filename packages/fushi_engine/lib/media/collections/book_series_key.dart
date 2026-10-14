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

/// 结尾卷号：`2` / `第2巻` / `2巻` / `Vol.2` / `v02` / `(2)` / `#2`，以及直接贴在
/// 汉字 / 假名后的 `安達としまむら10`。数字前必须有分隔或非 ASCII 字符，「86」
/// 这类纯数字书名、「Catch22」这类拉丁字母贴数字的书名尾数不会被吃掉（「Fahrenheit
/// 451」会被读成卷号，但归组要求同系列 ≥2 卷，单本不受影响）。只在全角已折半角的
/// 串上匹配。
final RegExp _volumeSuffix = RegExp(
  r'(?:\s+|[\s_\-:・]*(?:第|vol\.?\s*|v(?=\d)|#)|\s*\(|(?<=[^\x00-\x7F]))'
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

/// 解析 [title]；去掉卷号后系列名为空时返回 null（不参与归组）。
///
/// 匹配在折叠串上做，合集名按同一下标从**原文**截取（不把用户书名里的 `～`
/// 改成 `~`）。卷号匹配不上时先剥一层结尾标签再试（`安達としまむら13 (電撃文庫)`）。
BookSeriesKey? parseBookSeriesKey(String title) {
  final String folded = _foldWidth(title);
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
  final String key = folded.substring(0, end).trim();
  if (key.isEmpty) return null;
  return BookSeriesKey(
    key: key.replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
    seriesTitle: title.substring(0, end).trim(),
    volume: volume,
  );
}
