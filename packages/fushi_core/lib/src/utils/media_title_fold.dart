import 'jp_codepoint_fold.dart';

/// 媒体标题折叠（库页搜索与 AI 整理分组键共用一个口径，原住 app 的
/// `media_search_text.dart`，v124 AI 整理库下沉到这里，让无 Flutter 的引擎算分组键时
/// 与库页搜索逐字节一致）。
///
/// 搜索归一化：全角 ASCII → 半角、大写 → 小写、片假名 → 平假名、丢掉空白与常见
/// 标点。目的是让「Fate／stay night」「fate stay night」「ＦＡＴＥ・ｓｔａｙ」
/// 互相能命中，而不引入任何模糊匹配依赖。
///
/// 片假名折叠只做基本区（U+30A1..U+30F6 平移 -0x60），长音符 `ー`、中点 `・`
/// 这类连接符直接丢弃——它们在标题里出现与否全凭排版习惯。
String foldMediaTitle(String raw) {
  if (raw.isEmpty) return '';
  final StringBuffer out = StringBuffer();
  for (final int code in raw.runes) {
    // 全角 ASCII（U+FF01..U+FF5E）→ 半角（共享原语，范围外原样）。
    int c = fullwidthAsciiToHalfwidth(code);
    // 全角空格 → 视作空白（下面被丢弃）。
    if (c == 0x3000) {
      continue;
    }
    // 片假名 → 平假名（基本区，共享原语）。
    c = katakanaToHiragana(c);
    final String ch = String.fromCharCode(c);
    if (_isDroppedSearchChar(ch, c)) {
      continue;
    }
    out.write(ch.toLowerCase());
  }
  return out.toString();
}

/// 归一化时丢弃的字符：空白 + 常见分隔/装饰标点（含日文全角标点）。
bool _isDroppedSearchChar(String ch, int code) {
  if (code <= 0x20) return true; // 控制字符与空格
  return _kDroppedSearchChars.contains(ch);
}

/// 见 [_isDroppedSearchChar]。
const Set<String> _kDroppedSearchChars = <String>{
  '!',
  '"',
  '#',
  '\$',
  '%',
  '&',
  "'",
  '(',
  ')',
  '*',
  '+',
  ',',
  '-',
  '.',
  '/',
  ':',
  ';',
  '<',
  '=',
  '>',
  '?',
  '@',
  '[',
  '\\',
  ']',
  '^',
  '_',
  '`',
  '{',
  '|',
  '}',
  '~',
  '・',
  'ー',
  '、',
  '。',
  '「',
  '」',
  '『',
  '』',
  '〜',
  '＝',
  '−',
  '–',
  '—',
  '“',
  '”',
  '‘',
  '’',
  '…',
};
