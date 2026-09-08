import 'dart:io';

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
    late Directory audioDir;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      audioDir = Directory.systemTemp.createTempSync('hibiki_resume_point_');
    });

    tearDown(() async {
      await db.close();
      if (audioDir.existsSync()) audioDir.deleteSync(recursive: true);
    });

    // 来源裁决与 resolve() 同源：Audiobook 行只有在音频文件真实存在时才算数。
    File audioFile(String name) =>
        File('${audioDir.path}/$name')..writeAsBytesSync(const <int>[0]);

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
      await repo.replaceAudio(
        bookKey: bookKey,
        audioPaths: <String>[audioFile('row-a.mp3').path],
      );
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
        ..bookKey = bookKey
        ..audioPaths = <String>[audioFile('paired-b.mp3').path];
      await SrtBookRepository(db).save(book);
      await db.setPrefTyped('audiobook_pos_at_${book.uid}', 777);
      await db.setPrefTyped('audiobook_pos_at_$bookKey', 999);
      // epub 键上的值属于一个不会被启动的来源，不得赢下仲裁。
      expect(
        await AudiobookSessionLauncher(db).readPositionUpdatedAtMs(bookKey),
        777,
      );
    });

    test('both rows present → the stamp of the source resolve() would start '
        '(audiobook row with playable audio wins over the srt uid)', () async {
      const String bookKey = 'epub-C';
      final AudiobookRepository abRepo = AudiobookRepository(db);
      await abRepo.ensureAudiobook(bookKey);
      await abRepo.replaceAudio(
        bookKey: bookKey,
        audioPaths: <String>[audioFile('both-c.mp3').path],
      );
      final SrtBook book = SrtBook()
        ..uid = 'srtbook_epub_$bookKey'
        ..title = 'Paired'
        ..srtPath = '/src/paired.srt'
        ..importedAt = 1
        ..bookKey = bookKey
        ..audioPaths = <String>[audioFile('both-c-srt.mp3').path];
      await SrtBookRepository(db).save(book);
      await db.setPrefTyped('audiobook_pos_at_$bookKey', 10);
      // SRT 重导入会给 uid 键盖新时间戳（位置 0）；会话却按 resolve() 优先序加载
      // bookKey 键——取两键较大值会让一个从不被加载的时间戳赢下仲裁。
      await db.setPrefTyped('audiobook_pos_at_${book.uid}', 20);
      expect(
        await AudiobookSessionLauncher(db).readPositionUpdatedAtMs(bookKey),
        10,
      );
    });

    test('audiobook row whose audio is missing falls through to the srt row, '
        'exactly like resolve()', () async {
      const String bookKey = 'epub-F';
      final AudiobookRepository abRepo = AudiobookRepository(db);
      await abRepo.ensureAudiobook(bookKey);
      await abRepo.replaceAudio(
        bookKey: bookKey,
        audioPaths: <String>['/definitely/missing/audio.mp3'],
      );
      final SrtBook book = SrtBook()
        ..uid = 'srtbook_epub_$bookKey'
        ..title = 'Paired'
        ..srtPath = '/src/paired.srt'
        ..importedAt = 1
        ..bookKey = bookKey
        ..audioPaths = <String>[audioFile('fallthrough-f.mp3').path];
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
      // 音频起点算不出时仍回退存档：存档赋值必须门在 !restored 之后。
      expect(block, contains('if (!restored && saved != null)'));
      // 音频槽失败不能把整本书开失败：await 必须在 try 里。
      final int awaitSlot = block.indexOf('await audioSlotFuture;');
      final int tryIdx = block.lastIndexOf('try {', awaitSlot);
      expect(awaitSlot, isNonNegative);
      expect(
        tryIdx,
        isNonNegative,
        reason: 'audio slot failure must fall back to the saved position',
      );
    });

    test('every open-resume branch writes the anchor set through the single '
        '_setOpenResumePoint entry (a stale charOffset can never leak)', () {
      final int start = source.indexOf('void _setOpenResumePoint({');
      expect(start, isNonNegative);
      final String body = source.substring(start, start + 900);
      for (final String field in <String>[
        '_currentChapter = chapter;',
        '_initialProgress = progress;',
        '_initialCharOffset = charOffset;',
        '_initialCharOffsetEnd = charOffsetEnd;',
        '_lastProgressSection = chapter;',
        '_lastProgressValue = progress;',
        '_lastProgressCharOffset = charOffset;',
      ]) {
        expect(body, contains(field));
      }
      // 起点字段只允许从这一处写：书签 / 存档 / 三条 cue 反查路径都走它。
      final int restoreStart = source.indexOf(
        'final Bookmark? bm = widget.initialBookmarkJump;',
      );
      final int restoreEnd = source.indexOf(
        "_openTrace.mark('position')",
        restoreStart,
      );
      final String restoreBlock = source.substring(restoreStart, restoreEnd);
      expect(
        restoreBlock,
        isNot(contains('_initialCharOffset =')),
        reason: 'restore branches must not assign anchor fields directly',
      );
      expect(
        '_setOpenResumePoint('.allMatches(source).length,
        greaterThanOrEqualTo(6),
        reason: 'definition + bookmark + saved + 3 audio cue paths',
      );
    });
  });

  group('AudiobookRepository.updatePositionMs stamp semantics', () {
    late FushiDatabase db;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async {
      await db.close();
    });

    test('an unchanged position does not re-stamp (exit flush order must not '
        'decide the LWW)', () async {
      const String key = 'epub-D';
      final AudiobookRepository repo = AudiobookRepository(db);
      await repo.updatePositionMs(bookKey: key, positionMs: 5000);
      final int first = await repo.readPositionUpdatedAtMs(key);
      expect(first, greaterThan(0));
      // 让墙钟至少走 1ms，再以相同位置 flush（关书 / 退后台 / stop 路径都会这么做）。
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await repo.updatePositionMs(bookKey: key, positionMs: 5000);
      expect(
        await repo.readPositionUpdatedAtMs(key),
        first,
        reason: 'same position → stamp untouched',
      );
      await Future<void>.delayed(const Duration(milliseconds: 2));
      await repo.updatePositionMs(bookKey: key, positionMs: 6000);
      expect(await repo.readPositionMs(key), 6000);
      expect(
        await repo.readPositionUpdatedAtMs(key),
        greaterThan(first),
        reason: 'position moved → stamp advances',
      );
    });

    test('legacy row without a stamp stays unstamped while the position is '
        'unchanged (never claims to be newer than the reader)', () async {
      const String key = 'epub-E';
      await db.setPrefTyped('audiobook_pos_$key', 4000);
      final AudiobookRepository repo = AudiobookRepository(db);
      await repo.updatePositionMs(bookKey: key, positionMs: 4000);
      expect(await repo.readPositionUpdatedAtMs(key), 0);
    });
  });
}
