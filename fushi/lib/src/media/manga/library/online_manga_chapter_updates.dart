/// 在线漫画「哪几章是这次刷新才出现的」——纯函数，v101 更新提醒的漫画侧判据。
///
/// 不需要新建「已见章节」表：一次刷新里旧章节列表（库里的 `sourceMetadata`）与新
/// 章节列表同时在手（见 `OnlineMangaLibraryService.refresh`），diff 当场就能算。
/// 加一张表去记「上次见过什么」等于把同一事实存两处，还得自己维护一致性。
library;

import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';

/// 相对 [previous] 而言，[current] 里新出现的章（按源内 `key` 判断）。
///
/// 两个刻意的空返回：
/// * **[previous] 为空**：这是刚加入书架的第一次拉取，整本书的章都是「新」的，
///   但用户是自己点的加入，不该被自己的动作提醒一次。
/// * **两侧完全无交集**（旧的一章都不在新列表里）：这不是「更新了 200 章」，而是
///   源换了章节 key 的编法（改域名、改 url 规则、换 scanlator 分支）。此时把整本
///   书报成更新是纯噪音，而漏报的代价只是这一次不提醒——下一次真更新照常命中。
List<OnlineMangaChapter> newlyAppearedChapters({
  required List<OnlineMangaChapter> previous,
  required List<OnlineMangaChapter> current,
}) {
  if (previous.isEmpty || current.isEmpty) {
    return const <OnlineMangaChapter>[];
  }
  final Set<String> seen = <String>{
    for (final OnlineMangaChapter chapter in previous) chapter.key,
  };
  final List<OnlineMangaChapter> fresh = <OnlineMangaChapter>[
    for (final OnlineMangaChapter chapter in current)
      if (!seen.contains(chapter.key)) chapter,
  ];
  if (fresh.length == current.length) {
    // 无交集 = 身份漂移，见上面的注释。
    return const <OnlineMangaChapter>[];
  }
  return fresh;
}

/// 章节在提醒里的显示名。源给了名字就用名字，没有就退回「第 N 话」的数字，
/// 两者都没有时给空串（调用方据此只显示作品名）。
String mangaChapterDisplayName(OnlineMangaChapter chapter) {
  if (chapter.name.trim().isNotEmpty) return chapter.name.trim();
  final double? number = chapter.number;
  if (number == null) return '';
  // 12.0 → '12'，12.5 → '12.5'：整数章号不带小数点。
  return number == number.roundToDouble()
      ? number.toInt().toString()
      : number.toString();
}
