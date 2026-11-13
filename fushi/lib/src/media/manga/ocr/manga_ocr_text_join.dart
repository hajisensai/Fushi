// 漫画 OCR 文本的拼接规则：OCR 按行 / 按块给文字，行尾不带空格。日文直接拼接无缝；
// 拉丁文等空格分词脚本在行界要补一个词间空格，否则查词引擎面对的是粘成一串的单词。
// OCR 解码（Google Lens 段落）、叠加层字格 DOM、整句文本共用这一个判据。
library;

import 'package:characters/characters.dart';

/// 空格分词脚本（拉丁 / 希腊 / 西里尔 / 亚美尼亚 / 希伯来 / 阿拉伯 / 格鲁吉亚）的字母或
/// ASCII 数字。与 `native/fushidicts/fushidicts_src/scan/word_scan.cpp` 的
/// `is_space_delimited_letter` 同一组脚本：引擎不在两个这类字母之间切词。
final RegExp _spaceDelimitedWordChar = RegExp(
  r'^[\p{Script=Latin}\p{Script=Greek}\p{Script=Cyrillic}'
  r'\p{Script=Armenian}\p{Script=Hebrew}\p{Script=Arabic}'
  r'\p{Script=Georgian}0-9]',
  unicode: true,
);

/// 拉丁文句内标点（逗号、句号、右引号 / 右括号……）后面紧接下一行的词时同样隔一个空格。
final RegExp _wordGapPunctuation = RegExp(r"""^[.,!?;:…'"’”)\]]$""");

/// 反馈 vXYKPudf7U：OCR 文本 [before] 与 [after] 相接处（换行 / 相邻文本块）是否是一个
/// 词间空格。OCR 的 `lines` 按行给、行尾不带空格；日文直接拼接无缝，拉丁文却是「行尾词 +
/// 行首词」——不补空格就把 `SO` / `LONG` 粘成 `SOLONG`，引擎（[_spaceDelimitedWordChar]
/// 那组脚本不在词中切）整串查不到。
///
/// 断字连字符（`LET-` / `TER`）走 [mangaOcrIsDehyphenationBreak]：既不补空格，也不保留
/// 连字符——见该函数的说明。
bool mangaOcrNeedsWordGap(String before, String after) {
  if (before.isEmpty || after.isEmpty) return false;
  if (mangaOcrIsDehyphenationBreak(before, after)) return false;
  final String last = before.characters.last;
  final String first = after.characters.first;
  if (!_spaceDelimitedWordChar.hasMatch(first)) return false;
  return _spaceDelimitedWordChar.hasMatch(last) ||
      _wordGapPunctuation.hasMatch(last);
}

/// 空格分词脚本的**字母**（不含数字）：断字判定专用。数字区间 `1990-1995` 不是断词，
/// 用 [mangaOcrNeedsWordGap] 那套含数字的字符集会把连字符误删。
final RegExp _spaceDelimitedLetterOnly = RegExp(
  r'^(?=\p{Letter})[\p{Script=Latin}\p{Script=Greek}\p{Script=Cyrillic}'
  r'\p{Script=Armenian}\p{Script=Hebrew}\p{Script=Arabic}'
  r'\p{Script=Georgian}]',
  unicode: true,
);

/// 断字连字符（`-` U+002D、`‐` U+2010、`‑` U+2011；不含破折号 `–` / `—`）。
const String kMangaDehyphenationHyphens = '-\u2010\u2011';

/// [before] 与 [after] 相接处是否是**行尾断字**：上一段以连字符结尾、下一段以空格分词
/// 字母开头，例如 `Under-` / `stands`、`EVERY-` / `ONE'S`。
///
/// 判据只用 OCR 自带的行 / 块边界，不依赖字框几何：行是 OCR 分好的，不存在「坐标猜错
/// 行」。已知取舍：真复合词恰好断在两行时也会被合并（`well-` / `known` → `wellknown`）；
/// 同一行内的连字符保持原样。
bool mangaOcrIsDehyphenationBreak(String before, String after) {
  if (before.isEmpty || after.isEmpty) return false;
  if (!kMangaDehyphenationHyphens.contains(before.characters.last)) {
    return false;
  }
  return _spaceDelimitedLetterOnly.hasMatch(after.characters.first);
}

/// 把 OCR 文本片段（一个块的各行 / 一句话的各块）按阅读顺序拼成一句：拉丁文行界补词间
/// 空格（[mangaOcrNeedsWordGap]），行尾断字去掉连字符（[mangaOcrIsDehyphenationBreak]），
/// 日文照旧无缝拼接。
String mangaJoinOcrText(Iterable<String> parts) {
  final StringBuffer buffer = StringBuffer();
  String previous = '';
  for (final String part in parts) {
    if (part.isEmpty) continue;
    if (mangaOcrIsDehyphenationBreak(previous, part)) {
      // 去掉上一段末尾的连字符：`Under-` + `stands` → `Understands`。
      final String text = buffer.toString();
      final String hyphen = previous.characters.last;
      buffer
        ..clear()
        ..write(text.substring(0, text.length - hyphen.length));
    } else if (mangaOcrNeedsWordGap(previous, part)) {
      buffer.write(' ');
    }
    buffer.write(part);
    previous = part;
  }
  return buffer.toString();
}
