import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-829：getAllFavoriteWords 全量倒序（供收藏夹导出）。
Future<HibikiDatabase> _openDb() async {
  final HibikiDatabase db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('FavoriteWords getAllFavoriteWords', () {
    test('returns all rows newest-first across sources', () async {
      final HibikiDatabase db = await _openDb();

      await db.addFavoriteWord(
        expression: '古い',
        reading: 'ふるい',
        glossary: 'old',
        sourceType: 'book',
        dateKey: '2026-06-20',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await db.addFavoriteWord(
        expression: '新しい',
        reading: 'あたらしい',
        glossary: 'new',
        sourceType: 'video',
        dateKey: '2026-06-21',
      );

      final List<FavoriteWordRow> rows = await db.getAllFavoriteWords();
      expect(rows.length, 2);
      // createdAt 倒序：最近收藏的「新しい」在前。
      expect(rows.first.expression, '新しい');
      expect(rows.last.expression, '古い');
      // 跨来源都在。
      expect(rows.map((FavoriteWordRow r) => r.sourceType).toSet(),
          <String>{'book', 'video'});
    });

    test('returns empty list when there are no favorite words', () async {
      final HibikiDatabase db = await _openDb();
      expect(await db.getAllFavoriteWords(), isEmpty);
    });
  });
}
