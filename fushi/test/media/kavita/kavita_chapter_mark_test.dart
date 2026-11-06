// 章节手动标已读 / 未读（长按 / 右键菜单）后的本地对齐，以及系列页进度文案。
//
// 标未读若只改服务器、不动本地位置与同步基线，下次打开时本地旧页 != 基线会被
// resolveKavitaProgress 判成「本地动过」把旧进度推回服务器，等于标未读被撤销。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/kavita/kavita_book_binding.dart';
import 'package:fushi/src/media/kavita/kavita_book_service.dart';
import 'package:fushi/src/media/kavita/kavita_progress_resolver.dart';
import 'package:fushi/src/pages/implementations/kavita/kavita_book_series_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/kavita/kavita_models.dart';

KavitaChapter _chapter({required int pages, required int pagesRead}) =>
    KavitaChapter.fromJson(<String, Object?>{
      'id': 9,
      'volumeId': 1,
      'pages': pages,
      'pagesRead': pagesRead,
    });

void main() {
  group('chapter progress label', () {
    test('percent follows server pagesRead / pages', () {
      expect(kavitaChapterReadPercent(_chapter(pages: 10, pagesRead: 0)), 0);
      expect(kavitaChapterReadPercent(_chapter(pages: 10, pagesRead: 3)), 30);
      expect(kavitaChapterReadPercent(_chapter(pages: 0, pagesRead: 3)), 0);
      expect(kavitaChapterReadPercent(_chapter(pages: 10, pagesRead: 99)), 100);
    });

    test('read chapter is finished, unread is empty', () {
      expect(kavitaChapterProgressLabel(_chapter(pages: 10, pagesRead: 0)), '');
      expect(
        kavitaChapterProgressLabel(_chapter(pages: 10, pagesRead: 4)),
        contains('40'),
      );
      expect(
        kavitaChapterProgressLabel(_chapter(pages: 10, pagesRead: 10)),
        isNot(contains('%')),
      );
      expect(
        kavitaChapterProgressLabel(_chapter(pages: 10, pagesRead: 10)),
        isNotEmpty,
      );
    });
  });

  group('alignLocalWithServerMark', () {
    late FushiDatabase db;
    late KavitaBookService service;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      service = KavitaBookService(db: db, nowMs: () => 5000);
    });
    tearDown(() => db.close());

    Future<EpubBookRow> insert({int? localSection, int? baseline}) async {
      await db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: 'B',
          title: 'B',
          epubPath: '/x/B.epub',
          extractDir: '/x/B',
          chapterCount: 12,
          chaptersJson: '["c"]',
          importedAt: 0,
          sourceMetadata: Value<String?>(
            KavitaBookBinding(
              serverConfigId: 'srv',
              seriesId: 1,
              volumeId: 1,
              chapterId: 9,
              libraryId: 1,
              lastPushedPage: baseline,
            ).encode(),
          ),
        ),
      );
      final EpubBookRow row = (await db.getEpubBook('B'))!;
      if (localSection != null) {
        await db.upsertReaderPosition(
          ReaderPositionsCompanion(
            bookUid: Value(row.uid),
            sectionIndex: Value(localSection),
            normCharOffset: const Value(0),
            updatedAt: const Value(10),
          ),
        );
      }
      return row;
    }

    test('mark unread resets local position and baseline to 0', () async {
      final EpubBookRow row = await insert(localSection: 7, baseline: 7);
      await service.alignLocalWithServerMark(
        serverConfigId: 'srv',
        chapterId: 9,
        read: false,
        totalPages: 12,
      );
      final ReaderPositionRow? pos = await db.getReaderPosition(row.uid);
      expect(pos!.sectionIndex, 0);
      expect(pos.updatedAt, greaterThan(10));
      final KavitaBookBinding b = (await service.bindingFor('B'))!;
      expect(b.lastPushedPage, 0);
      // 下次打开：服务器 0 页、本地 0 页 = 不推旧进度。
      expect(
        resolveKavitaProgress(
          serverPage: 0,
          serverModifiedAt: 6000,
          localPage: pos.sectionIndex,
          localUpdatedAt: pos.updatedAt,
          lastSyncAt: b.lastPulledAt,
          lastSyncedPage: b.lastPushedPage,
        ).action,
        KavitaSyncAction.none,
      );
    });

    test('mark unread without a local position does not invent one', () async {
      final EpubBookRow row = await insert(baseline: 3);
      await service.alignLocalWithServerMark(
        serverConfigId: 'srv',
        chapterId: 9,
        read: false,
        totalPages: 12,
      );
      expect(await db.getReaderPosition(row.uid), isNull);
      expect((await service.bindingFor('B'))!.lastPushedPage, 0);
    });

    test('mark read moves local position and baseline to last page', () async {
      final EpubBookRow row = await insert(localSection: 2, baseline: 2);
      await service.alignLocalWithServerMark(
        serverConfigId: 'srv',
        chapterId: 9,
        read: true,
        totalPages: 12,
      );
      final ReaderPositionRow? pos = await db.getReaderPosition(row.uid);
      expect(pos!.sectionIndex, 11);
      expect((await service.bindingFor('B'))!.lastPushedPage, 11);
    });

    test('chapter without a local copy is a no-op', () async {
      await insert(localSection: 4, baseline: 4);
      await service.alignLocalWithServerMark(
        serverConfigId: 'srv',
        chapterId: 404,
        read: false,
        totalPages: 12,
      );
      expect((await service.bindingFor('B'))!.lastPushedPage, 4);
    });
  });
}
