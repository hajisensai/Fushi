import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/backup_service.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// TODO-1358: the export/import dialogs describe "what is inside" a backup and
/// the overwrite import lets the user skip restoring individual sidecar file
/// trees. This locks down (1) the pure archive manifest counter and (2) the
/// per-category gating of [BackupService.importBackupFiles].
void main() {
  group('summarizeBackupArchive (pure manifest)', () {
    test('counts distinct dirs / files per category, normalizing separators',
        () {
      final List<String> names = <String>[
        'hibiki.db',
        'backup_meta.json',
        'dictionaryResources/JMdict/index.bin',
        'dictionaryResources/JMdict/tag.json',
        'dictionaryResources/Daijirin/y.bin',
        'hoshi_books/BookA/original.epub',
        'hoshi_books/BookA/chapters/1.html',
        'hoshi_books/BookB/original.epub',
        r'audiobooks\hashA\a.mp3',
        'custom_fonts/F1.ttf',
        'custom_fonts/F2.otf',
        'videos/uid1/1-a.mp4',
        'videos/uid1/2-b.mkv',
        'localAudio/local_audio_1.db',
        'localAudio/local_audio_1.db-wal',
        'localAudio/local_audio_2.db',
      ];
      final BackupContentSummary s =
          BackupService.summarizeBackupArchive(names, null);
      expect(s.countFor(BackupCategory.dictionary), 2);
      expect(s.countFor(BackupCategory.books), 2);
      expect(s.countFor(BackupCategory.audiobooks), 1);
      expect(s.countFor(BackupCategory.fonts), 2);
      // No meta -> counts the leaf video files.
      expect(s.countFor(BackupCategory.videos), 2);
      // The -wal sidecar is not a separate database.
      expect(s.countFor(BackupCategory.localAudio), 2);
      expect(s.present, <BackupCategory>{
        BackupCategory.dictionary,
        BackupCategory.books,
        BackupCategory.audiobooks,
        BackupCategory.fonts,
        BackupCategory.videos,
        BackupCategory.localAudio,
      });
    });

    test('videos count uses meta.videoFiles when present', () {
      final BackupMeta meta = BackupMeta(
        appVersion: '1',
        schemaVersion: 1,
        createdAt: DateTime(2020),
        bookCount: 0,
        statsCount: 0,
        videoFiles: <String, String>{
          '/src/a.mp4': 'uid1/1-a.mp4',
          '/src/b.mkv': 'uid1/2-b.mkv',
          '/src/c.mkv': 'uid2/1-c.mkv',
        },
      );
      final BackupContentSummary s = BackupService.summarizeBackupArchive(
        <String>['videos/uid1/1-a.mp4'],
        meta,
      );
      expect(s.countFor(BackupCategory.videos), 3);
    });

    test('db-only archive marks nothing present', () {
      final BackupContentSummary s =
          BackupService.summarizeBackupArchive(<String>['hibiki.db'], null);
      expect(s.present, isEmpty);
      expect(s.countFor(BackupCategory.books), 0);
    });
  });

  group('importBackupFiles per-category gating', () {
    late Directory src;
    late Directory dst;
    setUp(() async {
      src = await Directory.systemTemp.createTemp('bk_impcat_src_');
      dst = await Directory.systemTemp.createTemp('bk_impcat_dst_');
    });
    tearDown(() async {
      for (final Directory d in <Directory>[src, dst]) {
        if (d.existsSync()) await cleanupTempDir(d);
      }
    });

    Future<void> writeFile(String path, String content) async {
      final File f = File(path);
      f.parent.createSync(recursive: true);
      await f.writeAsString(content);
    }

    test('unticking videos + audiobooks skips those trees; books still restore',
        () async {
      final String dbDir = p.join(src.path, 'db');
      final String books = p.join(src.path, 'hoshi_books');
      final String audio = p.join(src.path, 'audiobooks');
      final String videos = p.join(src.path, 'ext_videos');
      Directory(dbDir).createSync(recursive: true);
      await writeFile(p.join(books, 'Bk', 'original.epub'), 'EPUB');
      await writeFile(p.join(audio, 'h', 'a.mp3'), 'MP3');
      await writeFile(p.join(videos, 'Film.mp4'), 'MP4');

      final HibikiDatabase db =
          HibikiDatabase.forTesting(NativeDatabase.memory());
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'Bk',
        title: 'Bk',
        epubPath: p.join(books, 'Bk', 'original.epub'),
        extractDir: p.join(books, 'Bk'),
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
      ));
      await db.upsertAudiobook(AudiobooksCompanion.insert(
        bookKey: 'Bk',
        alignmentFormat: 'srt',
        alignmentPath: p.join(audio, 'h', 'align.srt'),
        audioRoot: Value(p.join(audio, 'h')),
      ));
      await db.upsertVideoBook(VideoBooksCompanion.insert(
        bookUid: 'video/film',
        title: 'Film',
        videoPath: p.join(videos, 'Film.mp4'),
      ));

      final BackupService service = BackupService(
        db: db,
        dbDirectory: dbDir,
        appVersion: '1.0.0',
        booksRootDirectory: books,
        audiobooksRootDirectory: audio,
      );
      final String zip = p.join(src.path, 'all.zip');
      await service.exportBackup(zip); // null categories = everything
      await db.close();

      final String dstDbDir = p.join(dst.path, 'db');
      final String dstBooks = p.join(dst.path, 'hoshi_books');
      final String dstAudio = p.join(dst.path, 'audiobooks');
      final String dstVideos = p.join(dst.path, 'videos');
      Directory(dstDbDir).createSync(recursive: true);

      await BackupService.importBackupFiles(
        dbDirectory: dstDbDir,
        zipPath: zip,
        categories: <BackupCategory>{BackupCategory.books},
        booksRootDirectory: dstBooks,
        audiobooksRootDirectory: dstAudio,
        videosRootDirectory: dstVideos,
      );

      expect(File(p.join(dstBooks, 'Bk', 'original.epub')).existsSync(), isTrue,
          reason: 'books ticked - epub restored');
      expect(Directory(dstAudio).existsSync(), isFalse,
          reason: 'audiobooks unticked - audio tree not restored');
      expect(Directory(dstVideos).existsSync(), isFalse,
          reason: 'videos unticked - video tree not restored');

      // The DB library index still restored the book row wholesale.
      final HibikiDatabase restored = HibikiDatabase(dstDbDir);
      try {
        expect((await restored.getAllEpubBooks()).length, 1);
      } finally {
        await restored.close();
      }
    });
  });
}
