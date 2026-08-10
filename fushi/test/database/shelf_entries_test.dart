import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// TODO-616 B(排序) + A(系列) shelf_entries / series DAO 守卫：
///  - upsertShelfOrder / setSeriesForEntry 的部分更新（不互相清空）。
///  - 四个删书 DAO 方法同事务清 shelf_entry（删后无孤儿），含幂等删 0 行。
///    v83 起 epub 域 entryKey = epub_books.uid（deleteEpubBook 按 uid 清行）。
///  - deleteSeries FK setNull 把成员 seriesId 归 NULL（散回，不连坐删）。
/// （migrateShelfEntryKey 四路径组已随该 DAO 在 v83 删除，见下方组注释。）
void main() {
  late FushiDatabase db;

  setUp(() {
    // FK setNull (deleteSeries 散回成员) only fires when foreign_keys is ON,
    // mirroring production (database.dart sets `PRAGMA foreign_keys = ON`).
    db = FushiDatabase.forTesting(
      NativeDatabase.memory(
        setup: (rawDb) => rawDb.execute('PRAGMA foreign_keys = ON'),
      ),
    );
  });
  tearDown(() => db.close());

  Future<String> insertEpub(String key) => db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '/$key.epub',
          extractDir: '/$key',
          chapterCount: 1,
          chaptersJson: '[]',
          importedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );

  group('ShelfEntries DAO 守卫', () {
    test('upsertShelfOrder 按需建行，重复只改 sortOrder 不清 seriesId', () async {
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry(MediaKind.epub, 'A', sid);
      await db.upsertShelfOrder(MediaKind.epub, 'A', 5);

      final row = (await db.getShelfEntry(MediaKind.epub, 'A'))!;
      expect(row.sortOrder, 5);
      expect(row.seriesId, sid, reason: 'upsertShelfOrder 部分更新不得清空已有 seriesId');

      // 全新条目 upsert 建行，seriesId 默认 NULL。
      await db.upsertShelfOrder(MediaKind.video, 'V', 9);
      final v = (await db.getShelfEntry(MediaKind.video, 'V'))!;
      expect(v.sortOrder, 9);
      expect(v.seriesId, isNull);
    });

    test('setSeriesForEntry 部分更新不清 sortOrder；null 移出系列', () async {
      await db.upsertShelfOrder(MediaKind.epub, 'B', 7);
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry(MediaKind.epub, 'B', sid);

      final row = (await db.getShelfEntry(MediaKind.epub, 'B'))!;
      expect(row.sortOrder, 7, reason: 'setSeriesForEntry 不得重置已有 sortOrder');
      expect(row.seriesId, sid);

      await db.setSeriesForEntry(MediaKind.epub, 'B', null);
      final cleared = (await db.getShelfEntry(MediaKind.epub, 'B'))!;
      expect(cleared.seriesId, isNull);
      expect(cleared.sortOrder, 7);
    });

    test('batchUpsertShelfOrder 单事务批量回写：建行 + 改行 + 不清 seriesId', () async {
      // 预置一行带 seriesId，验证批量回写只改 sortOrder 不清归属。
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry(MediaKind.epub, 'X', sid);
      await db.batchUpsertShelfOrder(
        <({MediaKind mediaType, String entryKey, int sortOrder})>[
          (mediaType: MediaKind.epub, entryKey: 'X', sortOrder: 0),
          (mediaType: MediaKind.srt, entryKey: 'Y', sortOrder: 1),
          (mediaType: MediaKind.video, entryKey: 'Z', sortOrder: 2),
        ],
      );
      final x = (await db.getShelfEntry(MediaKind.epub, 'X'))!;
      expect(x.sortOrder, 0);
      expect(x.seriesId, sid, reason: '批量回写部分更新不清 seriesId');
      expect((await db.getShelfEntry(MediaKind.srt, 'Y'))!.sortOrder, 1);
      expect((await db.getShelfEntry(MediaKind.video, 'Z'))!.sortOrder, 2);
    });
  });

  // v83：migrateShelfEntryKey 已随「远端书下载改键路径」删除（epub 域
  // entryKey 换稳定 uid 后导入时刻定死、不再漂移；该路径删除前已恒 no-op）。

  group('删书四方法同事务清 shelf_entry（无孤儿 §0🔴3）', () {
    test('deleteEpubBook 删 epub shelf_entry（v83：行键 = uid）', () async {
      final String key = await insertEpub('E');
      // v83：shelf_entries 的 epub 域 entryKey = epub_books.uid（导入时生成），
      // deleteEpubBook 按 uid 清行——种子行必须落在 uid 键上才是真实域。
      final String uid = (await db.resolveEpubBookUid(key))!;
      await db.upsertShelfOrder(MediaKind.epub, uid, 1);
      expect(await db.getShelfEntry(MediaKind.epub, uid), isNotNull);

      await db.deleteEpubBook(key);
      expect(await db.getShelfEntry(MediaKind.epub, uid), isNull,
          reason: 'deleteEpubBook 必须同事务清 epub shelf_entry（uid 键）');
    });

    test('deleteVideoBook 删 video shelf_entry', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'vid1',
        title: 'Vid',
        videoPath: '/v.mp4',
      ));
      await db.upsertShelfOrder(MediaKind.video, 'vid1', 1);

      await db.deleteVideoBook('vid1');
      expect(await db.getShelfEntry(MediaKind.video, 'vid1'), isNull);
    });

    test('deleteSrtBookByUid 删 srt shelf_entry', () async {
      await db.customStatement(
        'INSERT INTO srt_books (uid, title, srt_path, imported_at, book_key) '
        "VALUES ('su1', 'Srt', '/s.srt', 0, '')",
      );
      await db.upsertShelfOrder(MediaKind.srt, 'su1', 1);

      await db.deleteSrtBookByUid('su1');
      expect(await db.getShelfEntry(MediaKind.srt, 'su1'), isNull);
    });

    test('deleteAudiobookByBookKey 删纯有声书 srt shelf_entry（entryKey=bookKey）',
        () async {
      await db.customStatement(
        'INSERT INTO audiobooks (book_key, alignment_format, alignment_path) '
        "VALUES ('ab1', 'srt', '/a.srt')",
      );
      // 纯有声书登记键 = bookKey（mediaType='srt'）。
      await db.upsertShelfOrder(MediaKind.srt, 'ab1', 1);

      await db.deleteAudiobookByBookKey('ab1');
      expect(await db.getShelfEntry(MediaKind.srt, 'ab1'), isNull,
          reason: '独立有声书删除唯一汇聚点必须清其 shelf_entry');
    });

    test('deleteShelfEntry 幂等：删不存在的行不报错', () async {
      final int removed = await db.deleteShelfEntry(MediaKind.epub, 'nope');
      expect(removed, 0);
    });
  });

  group('deleteSeries FK setNull（成员散回不连坐删）', () {
    test('删系列后成员 seriesId 归 NULL，shelf_entry 行仍在', () async {
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry(MediaKind.epub, 'M', sid);
      expect((await db.getShelfEntry(MediaKind.epub, 'M'))!.seriesId, sid);

      await db.deleteSeries(sid);

      final survivor = await db.getShelfEntry(MediaKind.epub, 'M');
      expect(survivor, isNotNull, reason: '删系列不连坐删成员条目');
      expect(survivor!.seriesId, isNull, reason: 'FK onDelete:setNull 散回');
    });
  });
}
