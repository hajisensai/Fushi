import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:test/test.dart';

/// novel-9：书架 / 归组器的瘦投影。
///
/// 书架以前对每本书整行读 `epub_books`（含几十到几百 KB 的 `chapters_json` /
/// `toc_json`），再在 UI isolate 上 `jsonDecode` 整段章节 JSON 只为取每章字数。
/// [FushiDatabase.getEpubBookShelfRows] 改在 SQLite 侧用 `json_each` 抽字数；
/// 这里钉住它与旧 Dart 解码口径一致（含坏数据不炸整架），以及随包 SQLite 确实
/// 带 JSON 函数（不带的话这些用例当场报 `no such function: json_each`）。
Future<void> _insert(
  FushiDatabase db, {
  required String key,
  required String chaptersJson,
  required int importedAt,
  String format = 'epub',
  String? sourceMetadata,
  String? author,
  String? coverPath,
  int chapterCount = 1,
}) async {
  await db
      .into(db.epubBooks)
      .insert(
        EpubBooksCompanion.insert(
          bookKey: key,
          uid: Value<String>('u_$key'),
          title: 'T $key',
          epubPath: '/m/$key.epub',
          extractDir: '/m/$key',
          chapterCount: chapterCount,
          chaptersJson: chaptersJson,
          importedAt: importedAt,
          format: Value<String>(format),
          author: Value<String?>(author),
          coverPath: Value<String?>(coverPath),
          sourceMetadata: Value<String?>(sourceMetadata),
        ),
      );
}

void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  test('每章字数按数组顺序抽出，和整行字段一致', () async {
    final String chapters = jsonEncode(<Map<String, Object>>[
      for (int i = 0; i < 40; i++)
        <String, Object>{
          'id': 'c$i',
          'href': 'Text/c$i.xhtml',
          'mediaType': 'application/xhtml+xml',
          'characters': (i * 37) % 1000 + i,
          'charCaliber': 2,
        },
    ]);
    await _insert(
      db,
      key: 'a',
      chaptersJson: chapters,
      importedAt: 10,
      author: '作者',
      coverPath: 'OEBPS/cover.jpg',
      chapterCount: 40,
      sourceMetadata: '{"series":"S"}',
    );

    final List<EpubBookShelfRow> rows = await db.getEpubBookShelfRows();
    expect(rows, hasLength(1));
    final EpubBookShelfRow r = rows.single;
    final EpubBookRow full = (await db.getEpubBook('a'))!;
    expect(r.sectionChars, <int>[
      for (final dynamic c in jsonDecode(full.chaptersJson) as List<dynamic>)
        (c as Map<String, dynamic>)['characters'] as int,
    ]);
    expect(r.bookKey, full.bookKey);
    expect(r.uid, full.uid);
    expect(r.uid, isNotEmpty);
    expect(r.title, full.title);
    expect(r.author, '作者');
    expect(r.coverPath, 'OEBPS/cover.jpg');
    expect(r.extractDir, full.extractDir);
    expect(r.chapterCount, 40);
    expect(r.format, 'epub');
    expect(r.sourceMetadata, '{"series":"S"}');
  });

  test('坏章节 JSON 只让那一本没有字数，不炸整个书架查询', () async {
    await _insert(db, key: 'empty', chaptersJson: '', importedAt: 1);
    await _insert(db, key: 'none', chaptersJson: '[]', importedAt: 2);
    await _insert(
      db,
      key: 'broken',
      chaptersJson: '[{"characters":',
      importedAt: 3,
    );
    await _insert(
      db,
      key: 'object',
      chaptersJson: '{"characters":5}',
      importedAt: 4,
    );
    await _insert(
      db,
      key: 'mixed',
      chaptersJson:
          '["abc", 7, null, {"id":"x"}, {"characters":"12"}, '
          '{"characters":12.9}, {"characters":30}]',
      importedAt: 5,
    );

    final Map<String, List<int>> chars = <String, List<int>>{
      for (final EpubBookShelfRow r in await db.getEpubBookShelfRows())
        r.bookKey: r.sectionChars,
    };
    expect(chars['empty'], isEmpty);
    expect(chars['none'], isEmpty);
    expect(chars['broken'], isEmpty);
    expect(chars['object'], isEmpty);
    // 非对象 / 缺字段 / 字符串字段记 0；小数按 Dart `toInt()` 同口径截断。
    expect(chars['mixed'], <int>[0, 0, 0, 0, 0, 12, 30]);
  });

  test('与 getAllEpubBooks 同序（importedAt 降序），bookKey 过滤只取一本', () async {
    await _insert(db, key: 'old', chaptersJson: '[]', importedAt: 1);
    await _insert(
      db,
      key: 'new',
      chaptersJson: '[{"characters":3}]',
      importedAt: 9,
    );
    await _insert(db, key: 'mid', chaptersJson: '[]', importedAt: 5);

    expect(
      (await db.getEpubBookShelfRows()).map((EpubBookShelfRow r) => r.bookKey),
      (await db.getAllEpubBooks()).map((EpubBookRow r) => r.bookKey),
    );
    final List<EpubBookShelfRow> one = await db.getEpubBookShelfRows(
      bookKey: 'new',
    );
    expect(one.map((EpubBookShelfRow r) => r.bookKey), <String>['new']);
    expect(one.single.sectionChars, <int>[3]);
    expect(await db.getEpubBookShelfRows(bookKey: 'missing'), isEmpty);
  });

  test('归组投影带 sourceMetadata / format / uid，与全行同序', () async {
    await _insert(
      db,
      key: 'm',
      chaptersJson: '[]',
      importedAt: 2,
      format: 'manga',
      sourceMetadata: '{"k":"v"}',
    );
    await _insert(db, key: 'e', chaptersJson: '[]', importedAt: 7);

    final List<EpubBookSeriesFacts> facts = await db.getEpubBookSeriesFacts();
    final List<EpubBookRow> full = await db.getAllEpubBooks();
    expect(
      facts.map((EpubBookSeriesFacts f) => f.bookKey),
      full.map((EpubBookRow r) => r.bookKey),
    );
    for (int i = 0; i < full.length; i++) {
      expect(facts[i].uid, full[i].uid);
      expect(facts[i].title, full[i].title);
      expect(facts[i].format, full[i].format);
      expect(facts[i].sourceMetadata, full[i].sourceMetadata);
    }
  });
}
