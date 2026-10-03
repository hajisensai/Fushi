import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/external_reader_import/external_reader_import_service.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_backup_archive.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_stat_segments.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/stats/stat_facts.dart';
import 'package:fushi_engine/stats/study_sessions.dart';
import 'package:fushi_engine/sync/ttu_filename.dart';
import 'package:path/path.dart' as p;

import 'hoshi_backup_fixture.dart';

const String _iosTitle = '吾輩は猫である';
const String _androidTitle = 'こころ';
const String _deletedTitle = '坊っちゃん';

int _ms(int y, int m, int d, [int h = 0, int min = 0]) =>
    DateTime(y, m, d, h, min).millisecondsSinceEpoch;

void main() {
  late Directory tempRoot;
  late FushiDatabase db;
  late int profileId;
  final int bookmarkAt = _ms(2026, 9, 3, 21);
  final int now = _ms(2026, 9, 20, 12);

  setUp(() async {
    tempRoot = Directory.systemTemp.createTempSync('ext_reader_import_');
    EpubStorage.debugBaseDirectoryOverride = p.join(tempRoot.path, 'books');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    profileId = await db.insertProfile(
      ProfilesCompanion.insert(name: 'Main', createdAt: 1, updatedAt: 1),
    );
    await db.setPref(kActiveProfileIdPrefKey, profileId.toString());
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  /// iOS 形态的书（会话统计 + 书签）、Android 形态的书（日记录）、一本
  /// `statistics_archive/` 里的已删书。
  String writeBackup({int bookmarkChars = 150}) {
    final String path = p.join(tempRoot.path, 'Books_2026-09-20.hoshi');
    writeHoshiBackup(path, <String, Object>{
      '$_iosTitle/metadata.json': <String, Object?>{
        'id': 'ios-uuid',
        'title': _iosTitle,
        'epub': 'neko.epub',
        'folder': _iosTitle,
        'lastAccess': appleSeconds(bookmarkAt),
      },
      '$_iosTitle/neko.epub': fixtureEpub(_iosTitle),
      '$_iosTitle/bookinfo.json': fixtureBookInfo(),
      '$_iosTitle/bookmark.json': <String, Object?>{
        'chapterIndex': 2,
        'progress': 0.9,
        'characterCount': bookmarkChars,
        'lastModified': appleSeconds(bookmarkAt),
      },
      '$_iosTitle/statistics.json': <String, Object?>{
        'S-1': <String, Object?>{
          'modified': _ms(2026, 9, 1, 11),
          'value': <String, Object?>{
            'startedAt': _ms(2026, 9, 1, 10, 30),
            'endedAt': _ms(2026, 9, 1, 11),
            'charactersRead': 500,
            'readingTime': 1500.0,
          },
        },
        'S-2': <String, Object?>{
          'modified': _ms(2026, 9, 2, 22),
          'value': <String, Object?>{
            'startedAt': _ms(2026, 9, 2, 21, 50),
            'endedAt': _ms(2026, 9, 2, 22, 10),
            'charactersRead': 300,
            'readingTime': 1200.0,
          },
        },
      },
      '$_androidTitle/metadata.json': <String, Object?>{
        'id': 'android-uuid',
        'title': _androidTitle,
        'folder': _androidTitle,
        'lastAccess': appleSeconds(bookmarkAt),
      },
      '$_androidTitle/$_androidTitle.epub': fixtureEpub(_androidTitle),
      '$_androidTitle/statistics.json': <Object?>[
        <String, Object?>{
          'title': _androidTitle,
          'dateKey': '2026-09-05',
          'charactersRead': 800,
          'readingTime': 2400.0,
          'lastStatisticModified': _ms(2026, 9, 5, 23),
        },
        <String, Object?>{
          'title': _androidTitle,
          'dateKey': '2026-09-06',
          'charactersRead': 200,
          'readingTime': 600.0,
          'lastStatisticModified': _ms(2026, 9, 6, 8),
        },
      ],
      'statistics_archive/$_deletedTitle/metadata.json': <String, Object?>{
        'id': 'deleted-uuid',
        'title': _deletedTitle,
        'lastAccess': 1,
      },
      'statistics_archive/$_deletedTitle/statistics.json': <Object?>[
        <String, Object?>{
          'title': _deletedTitle,
          'dateKey': '2026-08-30',
          'charactersRead': 42,
          'readingTime': 120.0,
          'lastStatisticModified': _ms(2026, 8, 30, 20),
        },
      ],
      'shelves.json': '[]',
    });
    return path;
  }

  ExternalReaderImportService service() =>
      ExternalReaderImportService(db: db, clock: () => now);

  Future<ExternalReaderImportReport> runImport(String path) async {
    final ExternalReaderBackup backup = await scanExternalReaderBackup(path);
    return service().run(backup);
  }

  Future<List<StudySegmentRow>> segmentsFor(String title) =>
      db.getStudySegmentsForMedia(
        mediaKind: kActivityMediaBook,
        mediaKey: sanitizeTtuFilename(title),
      );

  int sumChars(List<StudySegmentRow> rows) =>
      rows.fold<int>(0, (int a, StudySegmentRow r) => a + r.chars);
  int sumMs(List<StudySegmentRow> rows) =>
      rows.fold<int>(0, (int a, StudySegmentRow r) => a + r.durationMs);

  test('imports books, reading positions and statistics', () async {
    final String path = writeBackup();
    final ExternalReaderBackup backup = await scanExternalReaderBackup(path);
    final ExternalReaderImportPreview preview = await service().preview(backup);
    expect(preview.newBooks, 2);
    expect(preview.existingBooks, 0);
    expect(preview.statsOnlyBooks, 1);
    expect(preview.statRecords, 5);
    expect(preview.positions, 1);
    expect(preview.profileName, 'Main');

    final ExternalReaderImportReport report = await service().run(backup);
    expect(report.failures, isEmpty);
    expect(report.booksImported, 2);
    expect(report.positionsWritten, 1);
    expect(report.sessionsImported, 2);
    expect(report.daysImported, 3);

    // 书进库。
    final EpubBookRow ios = (await db.getEpubBook(
      sanitizeTtuFilename(_iosTitle),
    ))!;
    expect(ios.title, _iosTitle);
    expect(await db.getEpubBook(sanitizeTtuFilename(_androidTitle)), isNotNull);
    expect(await db.getEpubBook(sanitizeTtuFilename(_deletedTitle)), isNull);

    // 阅读位置：Hoshi spine 2 → Fushi 第 1 章（图片项被跳过），章内按字符偏移
    // (150 − 100) / 200；updatedAt 是 Hoshi 的时刻、charOffset 无精确锚。
    final ReaderPositionRow pos = (await db.getReaderPosition(ios.uid))!;
    expect(pos.sectionIndex, 1);
    expect(pos.normCharOffset, 2500);
    expect(pos.charOffset, -1);
    expect(pos.updatedAt, closeTo(bookmarkAt, 1));

    // 统计：总量与 Hoshi 一致，全部带导入专用 deviceId 与当前 Profile。
    final List<StudySegmentRow> iosRows = await segmentsFor(_iosTitle);
    expect(sumChars(iosRows), 800);
    expect(sumMs(iosRows), (1500 + 1200) * 1000);
    expect(
      iosRows.every(
        (StudySegmentRow r) =>
            r.deviceId == kExternalReaderImportDeviceId &&
            r.profileId == profileId &&
            BookFormat.parseOrEpub(r.format) == BookFormat.epub,
      ),
      isTrue,
    );
    // S-2 跨 22 点：按整点切成两片。
    expect(
      iosRows.where((StudySegmentRow r) => r.dateKey == '2026-09-02'),
      hasLength(2),
    );

    final List<StudySegmentRow> androidRows = await segmentsFor(_androidTitle);
    expect(sumChars(androidRows), 1000);
    expect(androidRows.map((StudySegmentRow r) => r.dateKey).toSet(), <String>{
      '2026-09-05',
      '2026-09-06',
    });

    final List<StudySegmentRow> deletedRows = await segmentsFor(_deletedTitle);
    expect(sumChars(deletedRows), 42);
    expect(deletedRows.single.title, _deletedTitle);

    // 读取面看得见（日面按书聚合）。
    final StatFacts facts = await loadStatFacts(db, activityLimit: 0);
    final int factChars = facts.daily
        .where((StatFact f) => f.mediaKey == sanitizeTtuFilename(_androidTitle))
        .fold<int>(0, (int a, StatFact f) => a + f.chars);
    expect(factChars, 1000);
    expect(
      facts.sessions.where(
        (StudySession s) => s.mediaKey == sanitizeTtuFilename(_iosTitle),
      ),
      hasLength(2),
    );
  });

  test('re-importing the same backup changes nothing', () async {
    final String path = writeBackup();
    await runImport(path);
    final List<StudySegmentRow> before = await db.getStudySegments(
      allProfiles: true,
    );

    final ExternalReaderImportReport again = await runImport(path);
    expect(again.booksImported, 0);
    expect(again.booksMatched, 2);
    expect(again.positionsWritten, 0);
    expect(again.positionsKept, 1);

    final List<StudySegmentRow> after = await db.getStudySegments(
      allProfiles: true,
    );
    expect(after, hasLength(before.length));
    expect(sumChars(after), sumChars(before));
    expect((await db.getEpubBookMetas()), hasLength(2));
  });

  test('sessions the user deleted in Fushi are not resurrected', () async {
    final String path = writeBackup();
    await runImport(path);
    final List<StudySegmentRow> iosRows = await segmentsFor(_iosTitle);
    // 会话流「删这一次」= 按 uid 写零（updatedAt = 删除时刻，晚于 Hoshi 的 modified）。
    await db.zeroStudySegmentsByUids(
      iosRows.map((StudySegmentRow r) => r.uid).toSet(),
    );
    await runImport(path);
    expect(sumChars(await segmentsFor(_iosTitle)), 0);
  });

  test(
    'a deleted-statistics tombstone suppresses the history and is reported',
    () async {
      await db.upsertStudySegmentTombstone(
        mediaKind: kActivityMediaBook,
        mediaKey: sanitizeTtuFilename(_androidTitle),
        deletedAt: _ms(2026, 9, 10),
      );
      final ExternalReaderImportReport report = await runImport(writeBackup());
      expect(await segmentsFor(_androidTitle), isEmpty);
      expect(report.segmentsSuppressedByDeletion, greaterThan(0));
      // 其它书不受影响。
      expect(sumChars(await segmentsFor(_iosTitle)), 800);
    },
  );

  test('days already synced into legacy statistics are skipped', () async {
    await db.setReadingStatistic(
      ReadingStatisticsCompanion.insert(
        title: _androidTitle,
        dateKey: '2026-09-05',
        charactersRead: 800,
        readingTimeMs: 2400000,
        lastStatisticModified: 1,
      ),
    );
    final ExternalReaderImportReport report = await runImport(writeBackup());
    expect(report.legacyRecordsSkipped, 1);
    final List<StudySegmentRow> rows = await segmentsFor(_androidTitle);
    expect(rows.map((StudySegmentRow r) => r.dateKey).toSet(), <String>{
      '2026-09-06',
    });
  });

  test(
    'matches a book already in the library and keeps a newer position',
    () async {
      final File epub = File(p.join(tempRoot.path, 'mine.epub'))
        ..writeAsBytesSync(fixtureEpub(_iosTitle));
      final String key = await EpubImporter.importFromPath(
        db: db,
        filePath: epub.path,
        fileName: 'mine.epub',
      );
      final String uid = (await db.resolveEpubBookUid(key))!;
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookUid: uid,
          sectionIndex: 0,
          normCharOffset: 1234,
          charOffset: const Value(55),
          updatedAt: bookmarkAt + 60000,
        ),
      );

      final ExternalReaderImportReport report = await runImport(writeBackup());
      expect(report.booksMatched, 1);
      expect(report.booksImported, 1);
      expect(report.positionsKept, 1);
      final ReaderPositionRow pos = (await db.getReaderPosition(uid))!;
      expect(pos.normCharOffset, 1234);
      expect(pos.charOffset, 55);
      expect(sumChars(await segmentsFor(_iosTitle)), 800);
    },
  );

  test('a finished Hoshi bookmark marks the book completed even when the Fushi '
      'position is kept (BUG-2870)', () async {
    final File epub = File(p.join(tempRoot.path, 'mine.epub'))
      ..writeAsBytesSync(fixtureEpub(_iosTitle));
    final String key = await EpubImporter.importFromPath(
      db: db,
      filePath: epub.path,
      fileName: 'mine.epub',
    );
    final String uid = (await db.resolveEpubBookUid(key))!;
    await db.upsertReaderPosition(
      ReaderPositionsCompanion.insert(
        bookUid: uid,
        sectionIndex: 0,
        normCharOffset: 1234,
        updatedAt: bookmarkAt + 60000,
      ),
    );

    // Hoshi 书签在全书末尾：Fushi 的位置更新、保留不写，但这本书读完了。
    final ExternalReaderImportReport report = await runImport(
      writeBackup(bookmarkChars: 300),
    );
    expect(report.positionsKept, 1);
    expect(report.booksMarkedCompleted, 1);
    expect((await db.getEpubBook(key))!.completedAt, isNotNull);
    expect((await db.getReaderPosition(uid))!.normCharOffset, 1234);
  });

  test(
    'an older Fushi position is replaced and its exact anchor cleared',
    () async {
      final File epub = File(p.join(tempRoot.path, 'mine.epub'))
        ..writeAsBytesSync(fixtureEpub(_iosTitle));
      final String key = await EpubImporter.importFromPath(
        db: db,
        filePath: epub.path,
        fileName: 'mine.epub',
      );
      final String uid = (await db.resolveEpubBookUid(key))!;
      await db.upsertReaderPosition(
        ReaderPositionsCompanion.insert(
          bookUid: uid,
          sectionIndex: 0,
          normCharOffset: 10,
          charOffset: const Value(3),
          updatedAt: bookmarkAt - 60000,
        ),
      );
      await runImport(writeBackup());
      final ReaderPositionRow pos = (await db.getReaderPosition(uid))!;
      expect(pos.sectionIndex, 1);
      expect(pos.normCharOffset, 2500);
      expect(pos.charOffset, -1);
    },
  );
}
