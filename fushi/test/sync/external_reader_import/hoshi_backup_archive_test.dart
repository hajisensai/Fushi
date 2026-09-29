import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/external_reader_import/hoshi_backup_archive.dart';
import 'package:path/path.dart' as p;

import 'hoshi_backup_fixture.dart';

void main() {
  late Directory tempRoot;

  setUp(() {
    tempRoot = Directory.systemTemp.createTempSync('hoshi_backup_archive_');
  });

  tearDown(() {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  String backupPath(String name) => p.join(tempRoot.path, name);

  test(
    'parses iOS session map, Android daily array and statistics_archive',
    () {
      final int bookmarkAt = DateTime(2026, 9, 1, 21).millisecondsSinceEpoch;
      writeHoshiBackup(backupPath('Books.hoshi'), <String, Object>{
        // iOS：epub 名是用户当初选的源文件名，靠 metadata.epub 找。
        'iOS Book/metadata.json': <String, Object?>{
          'id': 'A7C2F0F0-0000-0000-0000-000000000001',
          'title': 'iOS Book',
          'author': '夏目漱石',
          'epub': 'source-file.epub',
          'folder': 'iOS Book',
          'lastAccess': appleSeconds(bookmarkAt),
          'renamedTitle': 'Renamed',
        },
        'iOS Book/source-file.epub': fixtureEpub('iOS Book'),
        'iOS Book/bookinfo.json': fixtureBookInfo(),
        'iOS Book/bookmark.json': <String, Object?>{
          'chapterIndex': 2,
          'progress': 0.3,
          'characterCount': 150,
          'lastModified': appleSeconds(bookmarkAt),
        },
        'iOS Book/statistics.json': <String, Object?>{
          'session-b': <String, Object?>{
            'modified': 2000,
            'value': <String, Object?>{
              'startedAt': 5000,
              'endedAt': 9000,
              'charactersRead': 30,
              'readingTime': 3.5,
            },
          },
          'session-a': <String, Object?>{
            'modified': 1000,
            'value': <String, Object?>{
              'startedAt': 1000,
              'endedAt': 4000,
              'charactersRead': 20,
              'readingTime': 2.0,
            },
          },
          // Hoshi 的删除标记。
          'session-deleted': <String, Object?>{'modified': 3000, 'value': null},
        },
        // Android：`<folder>.epub`，ッツ日记录数组（含重复 dateKey / 坏元素）。
        'Android Book/metadata.json': <String, Object?>{
          'id': 'uuid-android',
          'title': 'Android Book',
          'folder': 'Android Book',
          'lastAccess': appleSeconds(bookmarkAt),
        },
        'Android Book/Android Book.epub': fixtureEpub('Android Book'),
        'Android Book/statistics.json': <Object?>[
          <String, Object?>{
            'title': 'Android Book',
            'dateKey': '2026-09-01',
            'charactersRead': 100,
            'readingTime': 600.0,
            'lastStatisticModified': 10,
          },
          <String, Object?>{
            'title': 'Android Book',
            'dateKey': '2026-09-01',
            'charactersRead': 150,
            'readingTime': 900.0,
            'lastStatisticModified': 20,
          },
          <String, Object?>{'title': 'x', 'dateKey': '2026-9-2'},
          null,
          'garbage',
        ],
        // 老 Android 书：metadata 里没有 title，退回目录名。
        'No Title/metadata.json': <String, Object?>{
          'id': 'uuid-3',
          'lastAccess': 0,
        },
        'statistics_archive/Deleted Book/metadata.json': <String, Object?>{
          'id': 'uuid-4',
          'title': 'Deleted Book',
          'lastAccess': 1,
        },
        'statistics_archive/Deleted Book/statistics.json': <Object?>[
          <String, Object?>{
            'title': 'Deleted Book',
            'dateKey': '2026-08-31',
            'charactersRead': 42,
            'readingTime': 60.0,
            'lastStatisticModified': 5,
          },
        ],
        'shelves.json': '[]',
        '.sync.json': '{}',
        '__MACOSX/iOS Book/._metadata.json': 'junk',
      });

      final ExternalReaderBackup backup = scanExternalReaderBackupSync(
        backupPath('Books.hoshi'),
      );
      expect(backup.kind, ExternalReaderBackupKind.hoshi);
      final Map<String, ExternalReaderBook> byTitle =
          <String, ExternalReaderBook>{
            for (final ExternalReaderBook b in backup.books) b.title: b,
          };
      expect(
        byTitle.keys,
        unorderedEquals(<String>[
          'iOS Book',
          'Android Book',
          'No Title',
          'Deleted Book',
        ]),
      );

      final ExternalReaderBook ios = byTitle['iOS Book']!;
      expect(ios.epubEntry, 'iOS Book/source-file.epub');
      expect(ios.author, '夏目漱石');
      expect(ios.renamedTitle, 'Renamed');
      expect(ios.isArchived, isFalse);
      expect(ios.lastAccessAt, closeTo(bookmarkAt, 1));
      expect(ios.bookmark!.chapterIndex, 2);
      expect(ios.bookmark!.characterCount, 150);
      expect(ios.bookmark!.lastModifiedAt, closeTo(bookmarkAt, 1));
      expect(ios.bookInfo!.characterCount, 300);
      expect(
        ios.bookInfo!.chapters.map(
          (ExternalReaderChapterSpan c) => c.spineIndex,
        ),
        <int>[0, 2],
      );
      // 删除标记被剔除，其余按 startedAt 排序。
      expect(ios.sessions.map((ExternalReaderSession s) => s.id), <String>[
        'session-a',
        'session-b',
      ]);
      expect(ios.sessions.last.readingTimeSec, 3.5);
      expect(ios.dailyRecords, isEmpty);

      final ExternalReaderBook android = byTitle['Android Book']!;
      expect(android.epubEntry, 'Android Book/Android Book.epub');
      expect(android.bookmark, isNull);
      expect(android.sessions, isEmpty);
      // 同一 dateKey 取 lastStatisticModified 大者；非法 dateKey / 坏元素丢弃。
      expect(android.dailyRecords, hasLength(1));
      expect(android.dailyRecords.single.charactersRead, 150);

      expect(byTitle['No Title']!.epubEntry, isNull);
      expect(byTitle['No Title']!.hasStatistics, isFalse);

      final ExternalReaderBook archived = byTitle['Deleted Book']!;
      expect(archived.isArchived, isTrue);
      expect(archived.epubEntry, isNull);
      expect(archived.dailyRecords.single.charactersRead, 42);
    },
  );

  test(
    'tolerates a wrapping Books/ directory and reports bad json per book',
    () {
      writeHoshiBackup(backupPath('wrapped.zip'), <String, Object>{
        'Books/Only/metadata.json': <String, Object?>{
          'id': 'x',
          'title': 'Only',
        },
        'Books/Only/Only.epub': fixtureEpub('Only'),
        'Books/Only/statistics.json': '{not json',
      });
      final ExternalReaderBackup backup = scanExternalReaderBackupSync(
        backupPath('wrapped.zip'),
      );
      final ExternalReaderBook book = backup.books.single;
      expect(book.directory, 'Books/Only');
      expect(book.epubEntry, 'Books/Only/Only.epub');
      expect(book.hasStatistics, isFalse);
      expect(book.problems.single, startsWith('statistics.json: invalid json'));
    },
  );

  test('rejects files that are not a Hoshi library backup', () {
    final File notZip = File(backupPath('plain.hoshi'))
      ..writeAsStringSync('hello');
    expect(
      () => scanExternalReaderBackupSync(notZip.path),
      throwsA(isA<ExternalReaderBackupFormatException>()),
    );
    writeHoshiBackup(backupPath('empty.zip'), <String, Object>{
      'readme.txt': 'no books here',
    });
    expect(
      () => scanExternalReaderBackupSync(backupPath('empty.zip')),
      throwsA(isA<ExternalReaderBackupFormatException>()),
    );
  });

  test('extracts one entry byte-for-byte', () async {
    final List<int> epub = fixtureEpub('Extract');
    writeHoshiBackup(backupPath('one.hoshi'), <String, Object>{
      'Extract/metadata.json': <String, Object?>{'id': 'x', 'title': 'Extract'},
      'Extract/Extract.epub': epub,
    });
    final String out = p.join(tempRoot.path, 'out', 'book.epub');
    await extractExternalReaderBackupEntry(
      archivePath: backupPath('one.hoshi'),
      entryName: 'Extract/Extract.epub',
      outPath: out,
    );
    expect(File(out).readAsBytesSync(), epub);
  });
}
