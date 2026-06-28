import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// TODO-616 B(排序) + A(系列) shelf_entries / series DAO 守卫：
///  - upsertShelfOrder / setSeriesForEntry 的部分更新（不互相清空）。
///  - migrateShelfEntryKey 的四条路径（迁移 / 新行已存在不覆盖 / 等键 no-op /
///    无旧行 no-op）。
///  - 四个删书 DAO 方法同事务清 shelf_entry（删后无孤儿），含幂等删 0 行。
///  - deleteSeries FK setNull 把成员 seriesId 归 NULL（散回，不连坐删）。
void main() {
  late HibikiDatabase db;

  setUp(() {
    // FK setNull (deleteSeries 散回成员) only fires when foreign_keys is ON,
    // mirroring production (database.dart sets `PRAGMA foreign_keys = ON`).
    db = HibikiDatabase.forTesting(
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
      await db.setSeriesForEntry('epub', 'A', sid);
      await db.upsertShelfOrder('epub', 'A', 5);

      final row = (await db.getShelfEntry('epub', 'A'))!;
      expect(row.sortOrder, 5);
      expect(row.seriesId, sid, reason: 'upsertShelfOrder 部分更新不得清空已有 seriesId');

      // 全新条目 upsert 建行，seriesId 默认 NULL。
      await db.upsertShelfOrder('video', 'V', 9);
      final v = (await db.getShelfEntry('video', 'V'))!;
      expect(v.sortOrder, 9);
      expect(v.seriesId, isNull);
    });

    test('setSeriesForEntry 部分更新不清 sortOrder；null 移出系列', () async {
      await db.upsertShelfOrder('epub', 'B', 7);
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry('epub', 'B', sid);

      final row = (await db.getShelfEntry('epub', 'B'))!;
      expect(row.sortOrder, 7, reason: 'setSeriesForEntry 不得重置已有 sortOrder');
      expect(row.seriesId, sid);

      await db.setSeriesForEntry('epub', 'B', null);
      final cleared = (await db.getShelfEntry('epub', 'B'))!;
      expect(cleared.seriesId, isNull);
      expect(cleared.sortOrder, 7);
    });

    test('batchUpsertShelfOrder 单事务批量回写：建行 + 改行 + 不清 seriesId', () async {
      // 预置一行带 seriesId，验证批量回写只改 sortOrder 不清归属。
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry('epub', 'X', sid);
      await db.batchUpsertShelfOrder(
        <({String mediaType, String entryKey, int sortOrder})>[
          (mediaType: 'epub', entryKey: 'X', sortOrder: 0),
          (mediaType: 'srt', entryKey: 'Y', sortOrder: 1),
          (mediaType: 'video', entryKey: 'Z', sortOrder: 2),
        ],
      );
      final x = (await db.getShelfEntry('epub', 'X'))!;
      expect(x.sortOrder, 0);
      expect(x.seriesId, sid, reason: '批量回写部分更新不清 seriesId');
      expect((await db.getShelfEntry('srt', 'Y'))!.sortOrder, 1);
      expect((await db.getShelfEntry('video', 'Z'))!.sortOrder, 2);
    });
  });

  group('migrateShelfEntryKey (远端书改键迁移 §0🔴2)', () {
    test('旧行迁移到新键，sortOrder/seriesId 延续，旧行删除', () async {
      final int sid = await db.createSeries('S');
      await db.upsertShelfOrder('epub', 'old', 3);
      await db.setSeriesForEntry('epub', 'old', sid);

      await db.migrateShelfEntryKey('epub', 'old', 'new');

      expect(await db.getShelfEntry('epub', 'old'), isNull,
          reason: '旧 downloadId 行迁移后删除');
      final moved = (await db.getShelfEntry('epub', 'new'))!;
      expect(moved.sortOrder, 3);
      expect(moved.seriesId, sid, reason: '归属延续');
    });

    test('新行已存在 → 本地优先不覆盖，仅删旧行', () async {
      await db.upsertShelfOrder('epub', 'old', 3);
      await db.upsertShelfOrder('epub', 'new', 99);

      await db.migrateShelfEntryKey('epub', 'old', 'new');

      expect(await db.getShelfEntry('epub', 'old'), isNull);
      final kept = (await db.getShelfEntry('epub', 'new'))!;
      expect(kept.sortOrder, 99, reason: '已存在的本地新行不被旧行覆盖');
    });

    test('等键 no-op', () async {
      await db.upsertShelfOrder('epub', 'same', 4);
      await db.migrateShelfEntryKey('epub', 'same', 'same');
      final row = (await db.getShelfEntry('epub', 'same'))!;
      expect(row.sortOrder, 4);
    });

    test('无旧行 no-op（importer 降级 / localBookKey==null 后旧行已是孤儿）', () async {
      await db.migrateShelfEntryKey('epub', 'absent', 'target');
      expect(await db.getShelfEntry('epub', 'target'), isNull);
      expect(await db.getAllShelfEntries(), isEmpty);
    });

    // TODO-616 A3：远端书先归入系列（以 downloadId 登记），下载后 bookKey 漂移，
    // 改键迁移后系列归属延续——getShelfEntriesBySeries 反映新键、旧键不再属系列。
    test('远端书归系列 → 下载改键后系列归属延续（A3 路径）', () async {
      final int sid = await db.createSeries('远端系列');
      const String downloadId = 'remote-download-id';
      const String localBookKey = 'local_book_key_after_import';
      await db.setSeriesForEntry('epub', downloadId, sid);

      await db.migrateShelfEntryKey('epub', downloadId, localBookKey);

      final List<ShelfEntryRow> members = await db.getShelfEntriesBySeries(sid);
      expect(members, hasLength(1));
      expect(members.single.entryKey, localBookKey,
          reason: '系列成员改键到本地 bookKey');
      expect(await db.getShelfEntry('epub', downloadId), isNull,
          reason: '旧 downloadId 行迁移后删除，不再属系列');
    });
  });

  group('删书四方法同事务清 shelf_entry（无孤儿 §0🔴3）', () {
    test('deleteEpubBook 删 epub shelf_entry', () async {
      final String key = await insertEpub('E');
      await db.upsertShelfOrder('epub', key, 1);
      expect(await db.getShelfEntry('epub', key), isNotNull);

      await db.deleteEpubBook(key);
      expect(await db.getShelfEntry('epub', key), isNull,
          reason: 'deleteEpubBook 必须同事务清 epub shelf_entry');
    });

    test('deleteVideoBook 删 video shelf_entry', () async {
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'vid1',
        title: 'Vid',
        videoPath: '/v.mp4',
      ));
      await db.upsertShelfOrder('video', 'vid1', 1);

      await db.deleteVideoBook('vid1');
      expect(await db.getShelfEntry('video', 'vid1'), isNull);
    });

    test('deleteSrtBookByUid 删 srt shelf_entry', () async {
      await db.customStatement(
        'INSERT INTO srt_books (uid, title, srt_path, imported_at, book_key) '
        "VALUES ('su1', 'Srt', '/s.srt', 0, '')",
      );
      await db.upsertShelfOrder('srt', 'su1', 1);

      await db.deleteSrtBookByUid('su1');
      expect(await db.getShelfEntry('srt', 'su1'), isNull);
    });

    test('deleteAudiobookByBookKey 删纯有声书 srt shelf_entry（entryKey=bookKey）',
        () async {
      await db.customStatement(
        'INSERT INTO audiobooks (book_key, alignment_format, alignment_path) '
        "VALUES ('ab1', 'srt', '/a.srt')",
      );
      // 纯有声书登记键 = bookKey（mediaType='srt'）。
      await db.upsertShelfOrder('srt', 'ab1', 1);

      await db.deleteAudiobookByBookKey('ab1');
      expect(await db.getShelfEntry('srt', 'ab1'), isNull,
          reason: '独立有声书删除唯一汇聚点必须清其 shelf_entry');
    });

    test('deleteShelfEntry 幂等：删不存在的行不报错', () async {
      final int removed = await db.deleteShelfEntry('epub', 'nope');
      expect(removed, 0);
    });
  });

  group('deleteSeries FK setNull（成员散回不连坐删）', () {
    test('删系列后成员 seriesId 归 NULL，shelf_entry 行仍在', () async {
      final int sid = await db.createSeries('S');
      await db.setSeriesForEntry('epub', 'M', sid);
      expect((await db.getShelfEntry('epub', 'M'))!.seriesId, sid);

      await db.deleteSeries(sid);

      final survivor = await db.getShelfEntry('epub', 'M');
      expect(survivor, isNotNull, reason: '删系列不连坐删成员条目');
      expect(survivor!.seriesId, isNull, reason: 'FK onDelete:setNull 散回');
    });
  });
}
