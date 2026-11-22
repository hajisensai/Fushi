/// 首页视图（[HomeView]）匹配要的批量查询：一轮首页载入一次，只在开关开着时调用。
library;

import 'package:drift/drift.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/models/home_view.dart';
import 'package:fushi/src/profile/language_binding.dart';

/// 读出书 / 字幕书的语言、全部标签映射与标签池（四条查询：两张书表各取两列，标签映射
/// 与标签池各一条）。
/// 视频与游戏的语言首页已在自己的行上，不在这里重复查。
Future<HomeViewLookup> loadHomeViewLookup(FushiDatabase db) async {
  final Future<List<TypedResult>> epubF =
      (db.selectOnly(db.epubBooks)
            ..addColumns(<Expression<Object>>[
              db.epubBooks.bookKey,
              db.epubBooks.language,
            ])
            ..where(db.epubBooks.language.isNotNull()))
          .get();
  final Future<List<TypedResult>> srtF =
      (db.selectOnly(db.srtBooks)
            ..addColumns(<Expression<Object>>[
              db.srtBooks.uid,
              db.srtBooks.language,
            ])
            ..where(db.srtBooks.language.isNotNull()))
          .get();
  final Future<List<TagAssignmentRow>> tagsF = db.getAllTagAssignments();
  final Future<List<BookTagRow>> tagNamesF = db.getAllTags();
  await Future.wait<Object?>(<Future<Object?>>[epubF, srtF, tagsF, tagNamesF]);

  final Map<String, String> languages = <String, String>{};
  for (final TypedResult row in await epubF) {
    final String? key = row.read(db.epubBooks.bookKey);
    final String? lang = row.read(db.epubBooks.language);
    if (key == null || lang == null) continue;
    languages['${TagHostKind.epub.dbValue}|$key'] = lang;
  }
  for (final TypedResult row in await srtF) {
    final String? key = row.read(db.srtBooks.uid);
    final String? lang = row.read(db.srtBooks.language);
    if (key == null || lang == null) continue;
    languages['${TagHostKind.srt.dbValue}|$key'] = lang;
  }
  final Map<String, Set<int>> tags = <String, Set<int>>{};
  for (final TagAssignmentRow row in await tagsF) {
    (tags['${row.mediaKind}|${row.entryKey}'] ??= <int>{}).add(row.tagId);
  }
  return HomeViewLookup(
    languages: languages,
    tags: tags,
    tagNames: <int, String>{
      for (final BookTagRow tag in await tagNamesF) tag.id: tag.name,
    },
  );
}

/// 视图编辑器可选的语言：库里（书 / 字幕书 / 视频 / 游戏）实际出现过的语言（归一化、
/// 去重、按键名排序），以及库里有没有没设语言的作品。
Future<({List<String> languages, bool hasNoLanguage})>
loadHomeViewLanguageOptions(FushiDatabase db) async {
  final Set<String> keys = <String>{};
  bool hasNoLanguage = false;
  Future<void> collect(
    TableInfo<Table, Object?> table,
    GeneratedColumn<String> column,
  ) async {
    final List<TypedResult> rows = await (db.selectOnly(
      table,
      distinct: true,
    )..addColumns(<Expression<Object>>[column])).get();
    for (final TypedResult row in rows) {
      final String key = normalizeLanguageBinding(row.read(column));
      if (key.isEmpty) {
        hasNoLanguage = true;
      } else {
        keys.add(key);
      }
    }
  }

  await collect(db.epubBooks, db.epubBooks.language);
  await collect(db.srtBooks, db.srtBooks.language);
  await collect(db.videoBooks, db.videoBooks.language);
  await collect(db.galgames, db.galgames.language);
  return (languages: keys.toList()..sort(), hasNoLanguage: hasNoLanguage);
}
