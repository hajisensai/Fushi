import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

/// v118 `localAddedAt`（本机开始拥有的时刻）的写入单点：
/// `insertEpubBook` / `upsertSrtBook` / `upsertVideoBook`。
///
/// 契约：插入时未携带 → 当时 now；冲突转更新（整行 save、同 uid 重复登记）**永不
/// 改写**；改 importedAt（互联下载沿用对端入库时刻）不碰它；删了再加 = 重新拥有，
/// 记新的时刻。
void main() {
  late FushiDatabase db;

  setUp(() => db = FushiDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  int nowMs() => DateTime.now().millisecondsSinceEpoch;

  EpubBooksCompanion book(String key, {int importedAt = 1000}) =>
      EpubBooksCompanion.insert(
        bookKey: key,
        title: key,
        epubPath: '$key.epub',
        extractDir: '/abs/$key',
        chapterCount: 1,
        chaptersJson: '[]',
        importedAt: importedAt,
      );

  group('insertEpubBook', () {
    test('未携带 → 记成插入那一刻（与 importedAt 无关）', () async {
      final int before = nowMs();
      await db.insertEpubBook(book('A', importedAt: 1000));
      final int after = nowMs();
      final EpubBookRow row = (await db.getEpubBook('A'))!;
      expect(row.importedAt, 1000);
      expect(row.localAddedAt, inInclusiveRange(before, after));
    });

    test('显式携带 → 原样落库', () async {
      await db.insertEpubBook(
        book('B').copyWith(localAddedAt: const Value<int?>(4242)),
      );
      expect((await db.getEpubBook('B'))!.localAddedAt, 4242);
    });

    test('互联下载把 importedAt 改写成对端入库时刻：localAddedAt 不动', () async {
      await db.insertEpubBook(
        book('C').copyWith(localAddedAt: const Value<int?>(9000)),
      );
      await (db.update(db.epubBooks)..where((t) => t.bookKey.equals('C')))
          .write(const EpubBooksCompanion(importedAt: Value<int>(10)));
      final EpubBookRow row = (await db.getEpubBook('C'))!;
      expect(row.importedAt, 10);
      expect(row.localAddedAt, 9000);
    });

    test('瘦投影 getEpubBookMetas 带出 localAddedAt', () async {
      await db.insertEpubBook(
        book('D').copyWith(localAddedAt: const Value<int?>(777)),
      );
      final EpubBookMeta meta = (await db.getEpubBookMetas()).single;
      expect(meta.localAddedAt, 777);
    });
  });

  group('upsertVideoBook', () {
    VideoBooksCompanion video({int? importedAt}) => VideoBooksCompanion(
      bookUid: const Value<String>('v1'),
      title: const Value<String>('V'),
      videoPath: const Value<String>('/abs/v.mp4'),
      importedAt: Value<int?>(importedAt),
    );

    test('插入未携带 → now；同 bookUid 重复登记只更新其它列、不改写 localAddedAt', () async {
      final int before = nowMs();
      await db.upsertVideoBook(video(importedAt: 1000));
      final int after = nowMs();
      final int first = (await db.getVideoBookByBookUid('v1'))!.localAddedAt!;
      expect(first, inInclusiveRange(before, after));

      await db.upsertVideoBook(
        video(importedAt: 5).copyWith(localAddedAt: const Value<int?>(1)),
      );
      final VideoBookRow row = (await db.getVideoBookByBookUid('v1'))!;
      expect(row.importedAt, 5, reason: '其它列照常按 upsert 覆盖');
      expect(row.localAddedAt, first, reason: '重复登记不是重新拥有');
    });
  });

  group('upsertSrtBook', () {
    test('插入未携带 → now；按 id 整行 save 不改写 localAddedAt', () async {
      final int before = nowMs();
      await db.upsertSrtBook(
        SrtBooksCompanion.insert(
          uid: 's1',
          title: 'S',
          srtPath: '/abs/s.srt',
          importedAt: 1000,
        ),
      );
      final int after = nowMs();
      final SrtBookRow inserted = (await db.getSrtBookByUid('s1'))!;
      expect(inserted.localAddedAt, inInclusiveRange(before, after));

      await db.upsertSrtBook(
        SrtBooksCompanion(
          id: Value<int>(inserted.id),
          uid: const Value<String>('s1'),
          title: const Value<String>('S renamed'),
          srtPath: const Value<String>('/abs/s.srt'),
          importedAt: const Value<int>(2000),
          localAddedAt: const Value<int?>(1),
        ),
      );
      final SrtBookRow saved = (await db.getSrtBookByUid('s1'))!;
      expect(saved.title, 'S renamed');
      expect(saved.importedAt, 2000);
      expect(saved.localAddedAt, inserted.localAddedAt);
    });
  });
}
