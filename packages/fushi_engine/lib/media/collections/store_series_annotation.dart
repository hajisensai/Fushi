/// 电子书店书名里的系列注记：`正文<系列名> (文库名)`（纯函数，无 IO）。
///
/// Kindle / BookWalker 卖的轻小说，书名一律写成
/// 「Re：ゼロから始める異世界生活 1<Re：ゼロから始める異世界生活> (MF文庫J)」——
/// 正文 + 卷号，后面尖括号里再写一遍系列名，最后是文库名。EPUB 元数据原样带进
/// `epub_books.title`。这一个写法有两个消费方，判据只在这里写一份：
///
/// - 显示名清洗（`fushi` 的 `display_title_store_series.dart`，设计稿 H4）：只留
///   「Re：ゼロから始める異世界生活 1」；
/// - 分卷归组（[parseBookSeriesKey]）：尖括号里的就是系列名，正文末尾是卷号。
library;

/// 末尾的 `<系列名>`（可再跟一个 `(文库名)`）。半角 / 全角括号都认。
final RegExp _kTrailingStoreSeries = RegExp(
  r'\s*[<＜]([^<>＜＞]+)[>＞]\s*(?:[(（][^()（）]*[)）])?\s*$',
);

/// 把 [title] 拆成「正文」与「系列名」（均为原文写法、已去首尾空白）；不是书店
/// 系列注记写法时返回 null。
///
/// 只在三个条件同时成立时认：
/// - 尖括号里至少两个字符（「本の題名<上>」的 `<上>` 是分卷，不是系列名）；
/// - 尖括号前面还有正文；
/// - 尖括号里的系列名就是正文的前缀（归一化全角 / 空白后比较）——书店注记的
///   特征；「タイトル<限定版>」这类不是前缀的标签不认。
({String body, String series})? splitStoreSeriesAnnotation(String title) {
  final ({int start, String body, String series})? m = _matchAnnotation(title);
  return m == null ? null : (body: m.body, series: m.series);
}

/// 去掉 [title] 末尾的书店系列注记；不是这种写法原样返回。
String stripStoreSeriesAnnotation(String title) {
  final ({int start, String body, String series})? m = _matchAnnotation(title);
  return m == null ? title : title.substring(0, m.start).trimRight();
}

/// [splitStoreSeriesAnnotation] 的判据本体；`start` 是注记在原串里的起点。
({int start, String body, String series})? _matchAnnotation(String title) {
  final RegExpMatch? match = _kTrailingStoreSeries.firstMatch(title);
  if (match == null) return null;
  final String series = match.group(1)!.trim();
  final String body = title.substring(0, match.start).trim();
  if (series.runes.length < 2 || body.isEmpty) return null;
  final String normalizedSeries = _normalize(series);
  if (normalizedSeries.isEmpty ||
      !_normalize(body).startsWith(normalizedSeries)) {
    return null;
  }
  return (start: match.start, body: body, series: series);
}

/// 比较用：全角 ASCII 折半角、全角空格折空格、去掉所有空白、ASCII 小写。
String _normalize(String s) {
  final StringBuffer out = StringBuffer();
  for (final int unit in s.codeUnits) {
    int c = unit;
    if (c >= 0xFF01 && c <= 0xFF5E) c -= 0xFEE0;
    if (c == 0x3000) c = 0x20;
    if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) continue;
    out.writeCharCode(c);
  }
  return out.toString().toLowerCase();
}
