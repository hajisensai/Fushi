import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_core/hibiki_core.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

void main() {
  group('updateEpubBookContentPaths (full-data backup restore)', () {
    test('rewrites only the supplied path columns', () async {
      final db = await _openDb();
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'Bk',
        title: 'Bk',
        epubPath: '/old/hoshi_books/Bk/original.epub',
        extractDir: '/old/hoshi_books/Bk',
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
        coverPath: const Value('/old/hoshi_books/Bk/cover.jpg'),
      ));

      await db.updateEpubBookContentPaths(
        'Bk',
        epubPath: '/new/hoshi_books/Bk/original.epub',
        extractDir: '/new/hoshi_books/Bk',
        coverPath: '/new/hoshi_books/Bk/cover.jpg',
      );

      final row = await db.getEpubBook('Bk');
      expect(row!.epubPath, '/new/hoshi_books/Bk/original.epub');
      expect(row.extractDir, '/new/hoshi_books/Bk');
      expect(row.coverPath, '/new/hoshi_books/Bk/cover.jpg');
      expect(row.title, 'Bk', reason: 'non-path columns untouched');
    });

    test('null arguments leave columns unchanged', () async {
      final db = await _openDb();
      await db.insertEpubBook(EpubBooksCompanion.insert(
        bookKey: 'Bk',
        title: 'Bk',
        epubPath: '/old/Bk.epub',
        extractDir: '/old/Bk',
        chapterCount: 1,
        chaptersJson: '["c"]',
        importedAt: 0,
        coverPath: const Value('/old/cover.jpg'),
      ));

      await db.updateEpubBookContentPaths('Bk', epubPath: '/new/Bk.epub');

      final row = await db.getEpubBook('Bk');
      expect(row!.epubPath, '/new/Bk.epub');
      expect(row.extractDir, '/old/Bk', reason: 'null → unchanged');
      expect(row.coverPath, '/old/cover.jpg', reason: 'null → unchanged');
    });
  });

  group('updateAudiobookPaths (full-data backup restore)', () {
    test('rewrites audioRoot/audioPathsJson/alignmentPath', () async {
      final db = await _openDb();
      await db.upsertAudiobook(AudiobooksCompanion.insert(
        bookKey: 'Bk',
        alignmentFormat: 'srt',
        alignmentPath: '/old/audiobooks/h/align.srt',
        audioRoot: const Value('/old/audiobooks/h'),
        audioPathsJson: const Value('["/old/audiobooks/h/a.mp3"]'),
      ));

      await db.updateAudiobookPaths(
        'Bk',
        audioRoot: '/new/audiobooks/h',
        audioPathsJson: '["/new/audiobooks/h/a.mp3"]',
        alignmentPath: '/new/audiobooks/h/align.srt',
      );

      final row = await db.getAudiobookByBookKey('Bk');
      expect(row!.audioRoot, '/new/audiobooks/h');
      expect(row.audioPathsJson, '["/new/audiobooks/h/a.mp3"]');
      expect(row.alignmentPath, '/new/audiobooks/h/align.srt');
      expect(row.alignmentFormat, 'srt', reason: 'non-path column untouched');
    });
  });
}
