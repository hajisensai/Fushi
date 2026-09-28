import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

/// v114：`favorite_words` 加收藏上下文（原句 `sentence` + 与收藏句同口径的定位锚点
/// `section_index` / `norm_char_offset` / `norm_char_length`）。此前弹窗 ☆ 只落词形，
/// 收藏夹里的词没有上下文、不能跳回原文。存量行取默认值，不回填。
void main() {
  test(
    'v113 → v114 adds the context columns and keeps existing favorites',
    () async {
      final Directory directory = Directory.systemTemp.createTempSync('fav114');
      addTearDown(() => directory.deleteSync(recursive: true));
      final String path = '${directory.path}/test.db';

      final FushiDatabase original = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      await original.addFavoriteWord(
        expression: '古い',
        reading: 'ふるい',
        glossary: 'old',
        sourceType: 'book',
        dateKey: '2026-09-01',
      );
      await original.close();

      // 退回 v113 形态：没有四个上下文列。
      final sqlite.Database raw = sqlite.sqlite3.open(path);
      for (final String column in <String>[
        'sentence',
        'section_index',
        'norm_char_offset',
        'norm_char_length',
      ]) {
        raw.execute('ALTER TABLE favorite_words DROP COLUMN $column');
      }
      raw.execute('PRAGMA user_version = 113');
      raw.dispose();

      final FushiDatabase migrated = FushiDatabase.atFile(
        path,
        isMainProcess: false,
      );
      addTearDown(migrated.close);
      expect(migrated.schemaVersion, 115);

      final List<FavoriteWordRow> rows = await migrated.getAllFavoriteWords();
      expect(rows, hasLength(1));
      expect(rows.single.expression, '古い');
      expect(rows.single.glossary, 'old');
      expect(rows.single.sentence, '');
      expect(rows.single.sectionIndex, isNull);
      expect(rows.single.normCharOffset, isNull);
      expect(rows.single.normCharLength, isNull);

      await migrated.addFavoriteWord(
        expression: '新しい',
        reading: 'あたらしい',
        glossary: 'new',
        sourceType: 'video',
        dateKey: '2026-09-02',
        sentence: '新しい朝が来た',
        sectionIndex: 2,
        normCharOffset: 61000,
        normCharLength: 2500,
      );
      final FavoriteWordRow added = (await migrated.getAllFavoriteWords())
          .firstWhere((FavoriteWordRow r) => r.expression == '新しい');
      expect(added.sentence, '新しい朝が来た');
      expect(added.sectionIndex, 2);
      expect(added.normCharOffset, 61000);
      expect(added.normCharLength, 2500);
    },
  );

  test('fresh database stores favorite context', () async {
    final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.addFavoriteWord(
      expression: '読む',
      reading: 'よむ',
      glossary: '【辞書】to read',
      sourceType: 'book',
      dateKey: '2026-09-28',
      bookKey: 'hoshi://book/x',
      title: 'X',
      sentence: '本を読む。',
      sectionIndex: 3,
      normCharOffset: 120,
      normCharLength: 5,
    );
    final FavoriteWordRow row = (await db.getAllFavoriteWords()).single;
    expect(row.glossary, '【辞書】to read');
    expect(row.sentence, '本を読む。');
    expect(row.sectionIndex, 3);
    expect(row.normCharOffset, 120);
    expect(row.normCharLength, 5);
  });
}
