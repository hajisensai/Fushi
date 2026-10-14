/// 本地漫画分卷 → 系列的判据（纯函数，无 IO）。
///
/// 「志乃と恋 [3574f94a]」「志乃と恋 ２ [e11812e5]」「志乃と恋 3」「志乃と恋 第4巻」
/// 同属系列「志乃と恋」，卷号 1(隐含)/2/3/4。导入后按 [MangaSeriesKey.key] 相同
/// 把多卷收进同一个合集，卷号只决定合集内顺序。
library;

/// 一个分卷标题解析出的系列身份。
class MangaSeriesKey {
  const MangaSeriesKey({
    required this.key,
    required this.seriesTitle,
    required this.volume,
  });

  /// 比较用的归一化系列键（全角折半角、空白折叠、ASCII 小写）。
  final String key;

  /// 给合集起名用的系列名（原文写法，只去掉卷号与 CRC 后缀）。
  final String seriesTitle;

  /// 卷号；标题里没有卷号（通常是第 1 卷）为 null。
  final int? volume;
}

/// 发布文件名里的 8 位十六进制 CRC 标签（`志乃と恋 [3574f94a].cbz`，导入时
/// 文件名原样成了书名）。
final RegExp _hashSuffix = RegExp(r'\s*\[[0-9a-fA-F]{8}\]\s*$');

/// 结尾卷号：`2` / `第2巻` / `2巻` / `Vol.2` / `v02` / `(2)` / `#2`。
/// 数字前必须有分隔（空白、标点或卷标记），「86」这类纯数字书名不会被吃掉。
/// 只在全角已折半角的串上匹配。
final RegExp _volumeSuffix = RegExp(
  r'(?:\s+|[\s_\-:・]*(?:第|vol\.?\s*|v(?=\d)|#)|\s*\()'
  r'(\d{1,4})'
  r'\s*(?:巻|卷|册|冊)?\s*\)?\s*$',
  caseSensitive: false,
);

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
/// 改成 `~`）。
MangaSeriesKey? parseMangaSeriesKey(String title) {
  final String folded = _foldWidth(title);
  int end = _hashSuffix.firstMatch(folded)?.start ?? folded.length;
  int? volume;
  final RegExpMatch? m = _volumeSuffix.firstMatch(folded.substring(0, end));
  if (m != null) {
    volume = int.parse(m.group(1)!);
    end = m.start;
  }
  end = _trailingSeparators.firstMatch(folded.substring(0, end))?.start ?? end;
  final String key = folded.substring(0, end).trim();
  if (key.isEmpty) return null;
  return MangaSeriesKey(
    key: key.replaceAll(RegExp(r'\s+'), ' ').toLowerCase(),
    seriesTitle: title.substring(0, end).trim(),
    volume: volume,
  );
}
