import 'dart:convert';

/// ッツ 全局字符偏移 ↔ Hibiki (sectionIndex, normCharOffset) 双向转换。
///
/// ッツ 用 `exploredCharCount`（全书已读字符总数）表示进度；
/// Hibiki 用 `(sectionIndex, normCharOffset)` 表示（章节 + 章内 0-10000 归一化偏移）。
///
/// 转换依赖 `EpubBooks.chaptersJson` 中每章的 `characters` 字段。

const int _kMaxNormOffset = 10000;

class ChapterCharInfo {
  const ChapterCharInfo({required this.characters});
  final int characters;
}

List<ChapterCharInfo> parseChaptersJson(String chaptersJson) {
  final List<dynamic> list = jsonDecode(chaptersJson) as List;
  return list
      .cast<Map<String, dynamic>>()
      .map((m) => ChapterCharInfo(characters: m['characters'] as int))
      .toList();
}

int totalCharacterCount(List<ChapterCharInfo> chapters) {
  int total = 0;
  for (final c in chapters) {
    total += c.characters;
  }
  return total;
}

/// Hibiki → ッツ：`(sectionIndex, normCharOffset)` → `exploredCharCount`
int toExploredCharCount({
  required int sectionIndex,
  required int normCharOffset,
  required List<ChapterCharInfo> chapters,
}) {
  if (chapters.isEmpty) return 0;
  final int clampedSection = sectionIndex.clamp(0, chapters.length - 1);

  int count = 0;
  for (int i = 0; i < clampedSection; i++) {
    count += chapters[i].characters;
  }

  final int chapterChars = chapters[clampedSection].characters;
  final double fraction = normCharOffset / _kMaxNormOffset;
  count += (fraction * chapterChars).round();
  return count;
}

/// ッツ → Hibiki：`exploredCharCount` → `(sectionIndex, normCharOffset)`
({int sectionIndex, int normCharOffset}) fromExploredCharCount({
  required int exploredCharCount,
  required List<ChapterCharInfo> chapters,
}) {
  if (chapters.isEmpty) return (sectionIndex: 0, normCharOffset: 0);

  int remaining = exploredCharCount;
  for (int i = 0; i < chapters.length; i++) {
    final int chapterChars = chapters[i].characters;
    if (remaining <= chapterChars || i == chapters.length - 1) {
      final int normOffset = chapterChars > 0
          ? (remaining / chapterChars * _kMaxNormOffset)
              .round()
              .clamp(0, _kMaxNormOffset)
          : 0;
      return (sectionIndex: i, normCharOffset: normOffset);
    }
    remaining -= chapterChars;
  }

  return (sectionIndex: chapters.length - 1, normCharOffset: _kMaxNormOffset);
}
