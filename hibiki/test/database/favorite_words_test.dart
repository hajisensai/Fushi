import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

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

  // TODO-1252：per-book/video 收藏归属（bookKey / title 随收藏落库），供统计页
  // per-book/video tile 按 title 聚合展示「收藏 N」。取消收藏即删行 → 聚合活行回落。
  group('FavoriteWords per-book attribution (TODO-1252)', () {
    // 按 title 聚合活行的收藏数（复刻统计页 tile 的聚合口径）。
    Map<String, int> aggByTitle(List<FavoriteWordRow> rows) {
      final Map<String, int> out = <String, int>{};
      for (final FavoriteWordRow r in rows) {
        if (r.title.isEmpty) continue;
        out[r.title] = (out[r.title] ?? 0) + 1;
      }
      return out;
    }

    test('addFavoriteWord persists bookKey + title', () async {
      final HibikiDatabase db = await _openDb();
      await db.addFavoriteWord(
        expression: '語',
        reading: 'ご',
        glossary: 'word',
        sourceType: 'book',
        dateKey: '2026-07-06',
        bookKey: 'book/こころ',
        title: 'こころ',
      );
      final List<FavoriteWordRow> rows =
          await db.getFavoriteWordsBySource('book');
      expect(rows, hasLength(1));
      expect(rows.single.bookKey, 'book/こころ');
      expect(rows.single.title, 'こころ');
    });

    test('omitting bookKey/title defaults to null/empty (no tile attribution)',
        () async {
      final HibikiDatabase db = await _openDb();
      // 无书来源（首页 / 独立查词 / 同步回灌）不传归属 → title 空 → 只进汇总。
      await db.addFavoriteWord(
        expression: '無所属',
        reading: 'むしょぞく',
        glossary: 'x',
        sourceType: 'book',
        dateKey: '2026-07-06',
      );
      final List<FavoriteWordRow> rows =
          await db.getFavoriteWordsBySource('book');
      expect(rows.single.bookKey, isNull);
      expect(rows.single.title, '');
      expect(aggByTitle(rows), isEmpty);
    });

    test('aggregates favorites per title; empty title excluded', () async {
      final HibikiDatabase db = await _openDb();
      await db.addFavoriteWord(
        expression: 'A',
        reading: 'a',
        glossary: '',
        sourceType: 'book',
        dateKey: '2026-07-06',
        bookKey: 'book/X',
        title: 'X',
      );
      await db.addFavoriteWord(
        expression: 'B',
        reading: 'b',
        glossary: '',
        sourceType: 'book',
        dateKey: '2026-07-06',
        bookKey: 'book/X',
        title: 'X',
      );
      await db.addFavoriteWord(
        expression: 'C',
        reading: 'c',
        glossary: '',
        sourceType: 'book',
        dateKey: '2026-07-06',
        bookKey: 'book/Y',
        title: 'Y',
      );
      // 无书归属，不计入任何 tile。
      await db.addFavoriteWord(
        expression: 'D',
        reading: 'd',
        glossary: '',
        sourceType: 'book',
        dateKey: '2026-07-06',
      );
      final Map<String, int> agg =
          aggByTitle(await db.getFavoriteWordsBySource('book'));
      expect(agg, <String, int>{'X': 2, 'Y': 1});
    });

    test('unfavorite removes the row so per-title count falls back', () async {
      final HibikiDatabase db = await _openDb();
      await db.addFavoriteWord(
        expression: 'A',
        reading: 'a',
        glossary: '',
        sourceType: 'book',
        dateKey: '2026-07-06',
        bookKey: 'book/X',
        title: 'X',
      );
      await db.addFavoriteWord(
        expression: 'B',
        reading: 'b',
        glossary: '',
        sourceType: 'book',
        dateKey: '2026-07-06',
        bookKey: 'book/X',
        title: 'X',
      );
      expect(aggByTitle(await db.getFavoriteWordsBySource('book')),
          <String, int>{'X': 2});
      // 取消收藏 A → 活行删除 → X 计数回落到 1（收藏是集合，非单调计数器）。
      await db.removeFavoriteWord(
          expression: 'A', reading: 'a', sourceType: 'book');
      expect(aggByTitle(await db.getFavoriteWordsBySource('book')),
          <String, int>{'X': 1});
    });

    test('global dedup unchanged: same word twice stays one row', () async {
      final HibikiDatabase db = await _openDb();
      final bool first = await db.addFavoriteWord(
        expression: '重複',
        reading: 'ちょうふく',
        glossary: '',
        sourceType: 'book',
        dateKey: '2026-07-06',
        bookKey: 'book/X',
        title: 'X',
      );
      // 同 (expression, reading, sourceType) 再收藏（另一本书上下文）→ 幂等 no-op，
      // uniqueKey 不变 = 汇总计数 / 同步契约零变化，归属仍是首次那本 X。
      final bool second = await db.addFavoriteWord(
        expression: '重複',
        reading: 'ちょうふく',
        glossary: '',
        sourceType: 'book',
        dateKey: '2026-07-06',
        bookKey: 'book/Y',
        title: 'Y',
      );
      expect(first, isTrue);
      expect(second, isFalse);
      final List<FavoriteWordRow> rows =
          await db.getFavoriteWordsBySource('book');
      expect(rows, hasLength(1));
      expect(rows.single.title, 'X');
    });
  });
}
