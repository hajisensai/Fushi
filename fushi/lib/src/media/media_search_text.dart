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

import 'package:fushi_core/fushi_core.dart' show foldMediaTitle;

/// 搜索归一化：全角 ASCII → 半角、大写 → 小写、片假名 → 平假名、丢掉空白与常见
/// 标点。实现住 `fushi_core` 的 [foldMediaTitle]（AI 整理分组键与它同一口径）。
String normalizeMediaSearchText(String raw) => foldMediaTitle(raw);

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
      .where(
        (T it) => titles(
          it,
        ).any((String t) => normalizeMediaSearchText(t).contains(needle)),
      )
      .toList(growable: false);
}
