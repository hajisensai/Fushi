/// 库页搜索的**共享**归一化与匹配（P5-A）：书架 / 视频 / 游戏三个库页同一口径。
///
/// 此前这套实现只长在游戏库页（`galgame_library_query.dart` 的
/// `normalizeGalgameSearchText`），书架与视频页**根本没有搜索**。补搜索时不该
/// 各写一套「大概也做全角转半角」的近似实现——同一个库、同一批日文标题，在三个
/// 页面搜出不同结果比没有搜索更难解释。故把已在游戏页验证过的实现原样上提到
/// 媒体层，游戏侧改为委托（行为逐字节不变）。
///
/// 刻意**不引入**模糊匹配 / 拼音 / 分词依赖：目标只是让排版差异（全角、片假名、
/// 中点、长音符）不再挡住命中。
library;

import 'package:hibiki_core/hibiki_core.dart'
    show fullwidthAsciiToHalfwidth, katakanaToHiragana;

/// 搜索归一化：全角 ASCII → 半角、大写 → 小写、片假名 → 平假名、丢掉空白与常见
/// 标点。目的是让「Fate／stay night」「fate stay night」「ＦＡＴＥ・ｓｔａｙ」
/// 互相能命中，而不引入任何模糊匹配依赖。
///
/// 片假名折叠只做基本区（U+30A1..U+30F6 平移 -0x60），长音符 `ー`、中点 `・`
/// 这类连接符直接丢弃——它们在标题里出现与否全凭排版习惯。
String normalizeMediaSearchText(String raw) {
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

/// 候选标题里是否有一条命中 [query]：两侧都经 [normalizeMediaSearchText] 后做
/// 子串匹配。**空查询恒命中**（搜索框为空 = 不过滤）。纯函数。
///
/// [titles] 传该条目的全部可搜标题（原名 / 显示名 / 别名 / 译名…），任意一条命中
/// 即算命中——用户记得住哪个名字是随机的。
bool matchesMediaSearch({
  required String query,
  required Iterable<String> titles,
}) {
  final String needle = normalizeMediaSearchText(query);
  if (needle.isEmpty) return true;
  for (final String title in titles) {
    if (normalizeMediaSearchText(title).contains(needle)) {
      return true;
    }
  }
  return false;
}

/// 泛型列表筛选：按 [matchesMediaSearch] 同一口径过滤 [items]（G6：mokuro.moe
/// 在线目录 / jimaku 字幕 / 字体筛选三个搜索框此前是裸
/// `toLowerCase().contains`，同一批日文标题在库页能搜到、在这些框搜不到）。
/// 空/纯空白查询原样返回。纯函数，便于单测。
///
/// [titles] 返回该条目的全部可搜文案（文件名 / 系列名 / 别名…），任一命中即留。
List<T> filterByMediaSearch<T>(
  List<T> items,
  String query,
  Iterable<String> Function(T) titles,
) {
  final String needle = normalizeMediaSearchText(query);
  if (needle.isEmpty) return items;
  return items
      .where((T it) => titles(it)
          .any((String t) => normalizeMediaSearchText(t).contains(needle)))
      .toList(growable: false);
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
