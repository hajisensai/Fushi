import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_resume_point.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../pages/reader_fushi_page_source_corpus.dart';

/// BUG-2258：打开带有声书的书时，起点必须在「阅读进度」与「有声书进度」之间按写入
/// 时刻 LWW 仲裁，而不是有阅读存档就永远忽略音频位置（用户症状：每次点进去都不是
/// 听到的地方，按播放后才被 cue 拽过去）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('audiobookResumeWinsOverReader', () {
    test('audio strictly newer than reader wins', () {
      expect(
        audiobookResumeWinsOverReader(
          readerUpdatedAt: 100,
          audioUpdatedAt: 101,
        ),
        isTrue,
      );
    });

    test('reader newer or equal keeps reader (ties and 0/0 are reader)', () {
      expect(
        audiobookResumeWinsOverReader(
          readerUpdatedAt: 101,
          audioUpdatedAt: 100,
        ),
        isFalse,
      );
      expect(
        audiobookResumeWinsOverReader(
          readerUpdatedAt: 100,
          audioUpdatedAt: 100,
        ),
        isFalse,
      );
      expect(
        audiobookResumeWinsOverReader(readerUpdatedAt: 0, audioUpdatedAt: 0),
        isFalse,
      );
    });

    test('legacy audio position without timestamp (0) never beats a saved '
        'reader position', () {
      expect(
        audiobookResumeWinsOverReader(readerUpdatedAt: 1, audioUpdatedAt: 0),
        isFalse,
      );
    });
  });

  group('AudiobookSessionLauncher.readPositionUpdatedAtMs', () {
    late FushiDatabase db;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('book without audiobook or srt book → 0', () async {
      expect(
        await AudiobookSessionLauncher(db).readPositionUpdatedAtMs('none'),
        0,
      );
    });

    test('audiobook row → its audiobook_pos_at_<bookKey> stamp', () async {
      const String bookKey = 'epub-A';
      final AudiobookRepository repo = AudiobookRepository(db);
      await repo.ensureAudiobook(bookKey);
      await db.setPrefTyped('audiobook_pos_at_$bookKey', 4200);
      expect(
        await AudiobookSessionLauncher(db).readPositionUpdatedAtMs(bookKey),
        4200,
      );
    });

    test('srt book paired to an epub → stamp keyed by the srt uid, '
        'not the epub bookKey', () async {
      const String bookKey = 'epub-B';
      final SrtBook book = SrtBook()
        ..uid = 'srtbook_epub_$bookKey'
        ..title = 'Paired'
        ..srtPath = '/src/paired.srt'
        ..importedAt = 1
        ..bookKey = bookKey;
      await SrtBookRepository(db).save(book);
      await db.setPrefTyped('audiobook_pos_at_${book.uid}', 777);
      // 误写在 epub 键上的值不应被当成 SRT 会话的进度。
      expect(
        await AudiobookSessionLauncher(db).readPositionUpdatedAtMs(bookKey),
        777,
      );
    });

    test('both rows present → the newer of the two stamps', () async {
      const String bookKey = 'epub-C';
      await AudiobookRepository(db).ensureAudiobook(bookKey);
      final SrtBook book = SrtBook()
        ..uid = 'srtbook_epub_$bookKey'
        ..title = 'Paired'
        ..srtPath = '/src/paired.srt'
        ..importedAt = 1
        ..bookKey = bookKey;
      await SrtBookRepository(db).save(book);
      await db.setPrefTyped('audiobook_pos_at_$bookKey', 10);
      await db.setPrefTyped('audiobook_pos_at_${book.uid}', 20);
      expect(
        await AudiobookSessionLauncher(db).readPositionUpdatedAtMs(bookKey),
        20,
      );
    });
  });

  group('reader open-position arbitration (source guard)', () {
    late String source;

    setUpAll(() {
      source = readReaderPageSource();
    });

    test('saved reader position no longer short-circuits the audio cue '
        'restore; the LWW helper decides', () {
      final int lookup = source.indexOf("'[ReaderFushi] restore lookup: ");
      final int end = source.indexOf("_openTrace.mark('position')", lookup);
      expect(lookup, isNonNegative);
      expect(end, greaterThan(lookup));
      final String block = source.substring(lookup, end);
      expect(block, contains('audiobookResumeWinsOverReader('));
      expect(block, contains('restored = _restoreFromCurrentAudioCue()'));
      expect(
        block,
        isNot(contains('} else {\n        // 没有保存位置')),
        reason: 'audio cue restore must not live only in the no-saved branch',
      );
      // 音频起点算不出时仍回退存档：存档赋值必须门在 !restored 之后。
      expect(block, contains('if (!restored && saved != null)'));
    });

    test('audio cue resume point clears the precise char anchor so a stale '
        'saved charOffset cannot override it', () {
      final int start = source.indexOf('void _applyAudioCueResumePoint({');
      expect(start, isNonNegative);
      final String body = source.substring(start, start + 700);
      expect(body, contains('_initialCharOffset = -1;'));
      expect(body, contains('_initialCharOffsetEnd = -1;'));
      expect(body, contains('_lastProgressCharOffset = -1;'));
    });
  });
}
