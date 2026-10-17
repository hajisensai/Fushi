import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

import '../../pages/reader_fushi_page_source_corpus.dart';

/// BUG-3430（取代 BUG-2390 的「开书时音频位置为主」，对齐 Hoshi）：普通开书时阅读
/// 存档是恢复主位置；音频 cue 只在没有阅读存档时定起点，有声书位置改由首次按播放
/// 时的跟读把正文带过去。恢复锚在首个 WebView 文档之前决定，程序化跨过的正文不进入
/// 读字账本。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AudiobookSessionLauncher source selection', () {
    late FushiDatabase db;
    late Directory audioDir;

    setUp(() {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      audioDir = Directory.systemTemp.createTempSync('fushi_resume_point_');
    });

    tearDown(() async {
      await db.close();
      if (audioDir.existsSync()) audioDir.deleteSync(recursive: true);
    });

    File audioFile(String name) =>
        File('${audioDir.path}/$name')..writeAsBytesSync(const <int>[0]);

    test(
      'book without playable audiobook or SRT source resolves null',
      () async {
        expect(await AudiobookSessionLauncher(db).resolve('none'), isNull);
      },
    );

    test('audiobook row restores the position keyed by bookKey', () async {
      const String bookKey = 'epub-A';
      final AudiobookRepository repo = AudiobookRepository(db);
      await repo.ensureAudiobook(bookKey);
      await repo.replaceAudio(
        bookKey: bookKey,
        audioPaths: <String>[audioFile('row-a.mp3').path],
      );
      await db.setPrefTyped('audiobook_pos_$bookKey', 4200);
      final AudiobookSessionStartRequest? request =
          await AudiobookSessionLauncher(db).resolve(bookKey);
      expect(request, isNotNull);
      expect(request!.prefs.positionMs, 4200);
      expect(request.isSrtBookSource, isFalse);
    });

    test('paired SRT source restores its uid-keyed position', () async {
      const String bookKey = 'epub-B';
      final SrtBook book = SrtBook()
        ..uid = 'srtbook_epub_$bookKey'
        ..title = 'Paired'
        ..srtPath = '/src/paired.srt'
        ..importedAt = 1
        ..bookKey = bookKey
        ..audioPaths = <String>[audioFile('paired-b.mp3').path];
      await SrtBookRepository(db).save(book);
      await db.setPrefTyped('audiobook_pos_${book.uid}', 777);
      await db.setPrefTyped('audiobook_pos_$bookKey', 999);
      final AudiobookSessionStartRequest? request =
          await AudiobookSessionLauncher(db).resolve(bookKey);
      expect(request, isNotNull);
      expect(
        request!.prefs.positionMs,
        777,
        reason: 'the EPUB-keyed position belongs to a source not launched',
      );
      expect(request.isSrtBookSource, isTrue);
    });

    test(
      'playable audiobook row wins source selection over paired SRT',
      () async {
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
        await db.setPrefTyped('audiobook_pos_$bookKey', 10);
        await db.setPrefTyped('audiobook_pos_${book.uid}', 20);
        final AudiobookSessionStartRequest? request =
            await AudiobookSessionLauncher(db).resolve(bookKey);
        expect(request, isNotNull);
        expect(request!.prefs.positionMs, 10);
        expect(request.isSrtBookSource, isFalse);
      },
    );

    test(
      'missing audiobook files fall through to playable SRT source',
      () async {
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
        await db.setPrefTyped('audiobook_pos_$bookKey', 10);
        await db.setPrefTyped('audiobook_pos_${book.uid}', 20);
        final AudiobookSessionStartRequest? request =
            await AudiobookSessionLauncher(db).resolve(bookKey);
        expect(request, isNotNull);
        expect(request!.prefs.positionMs, 20);
        expect(request.isSrtBookSource, isTrue);
      },
    );
  });

  group('reader open-position arbitration (source guard)', () {
    late String source;

    setUpAll(() {
      source = readReaderPageSource();
    });

    test(
      'normal open restores the reader save; audio cue only without one',
      () {
        final int lookup = source.indexOf("'[ReaderFushi] restore lookup: ");
        final int end = source.indexOf("_openTrace.mark('position')", lookup);
        expect(lookup, isNonNegative);
        expect(end, greaterThan(lookup));
        final String block = source.substring(lookup, end);
        expect(
          block,
          isNot(contains('audiobookResumeWinsOverReader(')),
          reason:
              'reader/audio timestamps no longer arbitrate product position',
        );
        expect(block, isNot(contains('audioPositionAtFuture')));
        // 音频槽失败不能把整本书开失败：await 必须在 try 里。
        final int awaitSlot = block.indexOf('await audioSlotFuture;');
        final int tryIdx = block.lastIndexOf('try {', awaitSlot);
        expect(awaitSlot, isNonNegative);
        expect(
          tryIdx,
          isNonNegative,
          reason: 'audio slot failure must still open the book',
        );
        final int restoreSaved = block.indexOf('if (saved != null) {');
        final int restoreAudio = block.indexOf(
          'if (!restored) restored = _restoreFromCurrentAudioCue();',
        );
        expect(restoreSaved, isNonNegative);
        expect(
          restoreAudio,
          isNonNegative,
          reason: 'the audio cue is only the fallback when there is no save',
        );
        expect(awaitSlot, lessThan(restoreSaved));
        expect(
          restoreSaved,
          lessThan(restoreAudio),
          reason:
              'BUG-3430: the live player position must never override a '
              'reader save (it reads 0 until the restore seek lands)',
        );
        expect(
          block,
          isNot(contains('_readLedger.')),
          reason:
              'initial restore only establishes the first ledger unit; '
              'it must never credit or settle skipped text',
        );
        expect(
          source,
          contains('if (!_audioSlotResolved || _book == null ||'),
          reason:
              'the WebView body must not exist before the audio slot and '
              'audio-first anchor have settled',
        );
      },
    );

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

    test('an unchanged position does not create false sync progress', () async {
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
        'unchanged', () async {
      const String key = 'epub-E';
      await db.setPrefTyped('audiobook_pos_$key', 4000);
      final AudiobookRepository repo = AudiobookRepository(db);
      await repo.updatePositionMs(bookKey: key, positionMs: 4000);
      expect(await repo.readPositionUpdatedAtMs(key), 0);
    });
  });
}
