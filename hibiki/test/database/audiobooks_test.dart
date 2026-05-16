import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/database/database.dart';

Future<HibikiDatabase> _openDb() async {
  final db = HibikiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

AudiobooksCompanion _audiobook({String bookUid = 'book/1'}) {
  return AudiobooksCompanion.insert(
    bookUid: bookUid,
    alignmentFormat: 'srt',
    alignmentPath: '/tmp/align.srt',
  );
}

void main() {
  group('Audiobooks table', () {
    test('upsert and retrieve by bookUid', () async {
      final db = await _openDb();

      await db.upsertAudiobook(_audiobook());

      final row = await db.getAudiobookByBookUid('book/1');
      expect(row, isNotNull);
      expect(row!.alignmentFormat, 'srt');
    });

    test('getAudiobookByBookUid returns null for absent uid', () async {
      final db = await _openDb();

      expect(await db.getAudiobookByBookUid('missing'), isNull);
    });

    test('upsert replaces existing audiobook', () async {
      final db = await _openDb();
      await db.upsertAudiobook(_audiobook());
      await db.upsertAudiobook(AudiobooksCompanion.insert(
        bookUid: 'book/1',
        alignmentFormat: 'vtt',
        alignmentPath: '/tmp/new.vtt',
      ));

      final row = await db.getAudiobookByBookUid('book/1');
      expect(row!.alignmentFormat, 'vtt');
    });

    test('getAllAudiobooks returns all', () async {
      final db = await _openDb();
      await db.upsertAudiobook(_audiobook(bookUid: 'a'));
      await db.upsertAudiobook(_audiobook(bookUid: 'b'));

      expect(await db.getAllAudiobooks(), hasLength(2));
    });

    test('deleteAudiobookByBookUid removes the row', () async {
      final db = await _openDb();
      await db.upsertAudiobook(_audiobook());

      final count = await db.deleteAudiobookByBookUid('book/1');
      expect(count, 1);
      expect(await db.getAudiobookByBookUid('book/1'), isNull);
    });
  });

  group('AudioCues table', () {
    test('replaceCuesForBook inserts batch and getCuesForBook reads them',
        () async {
      final db = await _openDb();
      final cues = [
        AudioCuesCompanion.insert(
          bookUid: 'b1',
          chapterHref: 'ch1.xhtml',
          sentenceIndex: 0,
          textFragmentId: 'p1s1',
          cueText: 'Hello',
          startMs: 0,
          endMs: 1000,
          audioFileIndex: 0,
        ),
        AudioCuesCompanion.insert(
          bookUid: 'b1',
          chapterHref: 'ch1.xhtml',
          sentenceIndex: 1,
          textFragmentId: 'p1s2',
          cueText: 'World',
          startMs: 1000,
          endMs: 2000,
          audioFileIndex: 0,
        ),
      ];

      await db.replaceCuesForBook('b1', cues);

      final result = await db.getCuesForBook('b1');
      expect(result, hasLength(2));
    });

    test('getCuesForChapter filters by chapter href', () async {
      final db = await _openDb();
      await db.replaceCuesForBook('b1', [
        AudioCuesCompanion.insert(
          bookUid: 'b1',
          chapterHref: 'ch1.xhtml',
          sentenceIndex: 0,
          textFragmentId: 'f1',
          cueText: 'A',
          startMs: 0,
          endMs: 500,
          audioFileIndex: 0,
        ),
        AudioCuesCompanion.insert(
          bookUid: 'b1',
          chapterHref: 'ch2.xhtml',
          sentenceIndex: 0,
          textFragmentId: 'f2',
          cueText: 'B',
          startMs: 500,
          endMs: 1000,
          audioFileIndex: 0,
        ),
      ]);

      final ch1 = await db.getCuesForChapter('b1', 'ch1.xhtml');
      expect(ch1, hasLength(1));
      expect(ch1.single.cueText, 'A');
    });

    test('findCue locates specific cue by composite key', () async {
      final db = await _openDb();
      await db.replaceCuesForBook('b1', [
        AudioCuesCompanion.insert(
          bookUid: 'b1',
          chapterHref: 'ch1.xhtml',
          sentenceIndex: 3,
          textFragmentId: 'f3',
          cueText: 'Target',
          startMs: 3000,
          endMs: 4000,
          audioFileIndex: 0,
        ),
      ]);

      final cue = await db.findCue('b1', 'ch1.xhtml', 3);
      expect(cue, isNotNull);
      expect(cue!.cueText, 'Target');
    });

    test('findCue returns null when not found', () async {
      final db = await _openDb();

      expect(await db.findCue('x', 'y', 99), isNull);
    });

    test('replaceCuesForBook clears old cues before inserting', () async {
      final db = await _openDb();
      await db.replaceCuesForBook('b1', [
        AudioCuesCompanion.insert(
          bookUid: 'b1',
          chapterHref: 'ch1.xhtml',
          sentenceIndex: 0,
          textFragmentId: 'old',
          cueText: 'Old',
          startMs: 0,
          endMs: 1000,
          audioFileIndex: 0,
        ),
      ]);

      await db.replaceCuesForBook('b1', [
        AudioCuesCompanion.insert(
          bookUid: 'b1',
          chapterHref: 'ch1.xhtml',
          sentenceIndex: 0,
          textFragmentId: 'new',
          cueText: 'New',
          startMs: 0,
          endMs: 500,
          audioFileIndex: 0,
        ),
      ]);

      final all = await db.getCuesForBook('b1');
      expect(all, hasLength(1));
      expect(all.single.textFragmentId, 'new');
    });
  });
}
