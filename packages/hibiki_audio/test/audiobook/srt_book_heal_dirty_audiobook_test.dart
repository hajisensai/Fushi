import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/src/audiobook/audiobook_model.dart';
import 'package:hibiki_audio/src/audiobook/audiobook_repository.dart';
import 'package:hibiki_audio/src/audiobook/srt_book_model.dart';
import 'package:hibiki_audio/src/audiobook/srt_book_repository.dart';
import 'package:hibiki_audio/src/parsers/srt_parser.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;

/// TODO-1032 PR2: replaceAudio heals (deletes) the dirty same-bookKey
/// Audiobook row left by the legacy shelf audioOnly import, so resolve
/// (Audiobooks first, SrtBooks fallback) lands on the SrtBook correct audio.
///
/// Isolation guards pinned at the repository layer:
/// - heal only fires when non-empty audio was just written (empty pick = no-op,
///   otherwise we'd delete into "neither side has audio");
/// - only EPUB-paired SRT books (non-empty bookKey) are healed (standalone
///   subtitle books have empty bookKey and never own an Audiobook row);
/// - only Audiobook rows WITHOUT alignment are deleted (a real EPUB-backed
///   audiobook always carries alignmentPath/alignmentFormat and must survive);
/// - cue isolation: Audiobook cues live in the bookKey namespace, SrtBook cues
///   in the uid namespace, so deleting the dirty row's cues never touches the
///   SrtBook's own cues.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late HibikiDatabase db;

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp('hibiki_heal_dirty_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return docsDir.path;
        }
        return null;
      },
    );
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      null,
    );
    if (docsDir.existsSync()) docsDir.deleteSync(recursive: true);
  });

  Future<void> seedPairedSrtBook(
    SrtBookRepository repo, {
    required String bookKey,
  }) async {
    final SrtBook book = SrtBook()
      ..uid = 'srtbook_epub_$bookKey'
      ..title = 'Paired'
      ..srtPath = '/src/paired.srt'
      ..importedAt = 1
      ..bookKey = bookKey;
    await repo.save(book);
  }

  Future<void> insertAudiobookRow({
    required String bookKey,
    required String alignmentFormat,
    required String alignmentPath,
    required List<String> audioPaths,
  }) async {
    final Audiobook ab = Audiobook()
      ..bookKey = bookKey
      ..alignmentFormat = alignmentFormat
      ..alignmentPath = alignmentPath
      ..audioPaths = audioPaths;
    await AudiobookRepository(db).saveAudiobook(ab);
  }

  AudioCue makeCue({
    required String bookKey,
    required String chapterHref,
    required int sentenceIndex,
    required int startMs,
    required int endMs,
  }) {
    return AudioCue()
      ..bookKey = bookKey
      ..chapterHref = chapterHref
      ..sentenceIndex = sentenceIndex
      ..textFragmentId = ''
      ..text = ''
      ..startMs = startMs
      ..endMs = endMs
      ..audioFileIndex = 0;
  }

  Future<List<String>> doReplaceAudio(
    SrtBookRepository repo, {
    required String bookKey,
  }) async {
    final Directory srcDir = Directory(p.join(docsDir.path, 'src'))
      ..createSync(recursive: true);
    final File a = File(p.join(srcDir.path, 'new01.mp3'))
      ..writeAsStringSync('NEW');
    return repo.replaceAudio(
      uid: 'srtbook_epub_$bookKey',
      pickedPaths: <String>[a.path],
    );
  }

  test(
      'heals: replaceAudio deletes the dirty (no-alignment) Audiobook row for '
      'the same bookKey', () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    await seedPairedSrtBook(repo, bookKey: 'A');
    await insertAudiobookRow(
      bookKey: 'A',
      alignmentFormat: '',
      alignmentPath: '',
      audioPaths: <String>['/old/wrong.mp3'],
    );
    expect(await db.getAudiobookByBookKey('A'), isNotNull);

    await doReplaceAudio(repo, bookKey: 'A');

    expect(await db.getAudiobookByBookKey('A'), isNull,
        reason: 'dirty audioOnly Audiobook row must be healed away');
    final SrtBook? srt = await repo.findByBookKey('A');
    expect(srt!.audioPaths, isNotNull);
    expect(srt.audioPaths!.single, contains('new01.mp3'),
        reason: 'SrtBook now owns the freshly imported audio');
  });

  test(
      'does NOT heal a real EPUB-backed audiobook row (has alignment) for the '
      'same bookKey', () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    await seedPairedSrtBook(repo, bookKey: 'A');
    await insertAudiobookRow(
      bookKey: 'A',
      alignmentFormat: 'srt',
      alignmentPath: '/abs/persist/A/aligned.srt',
      audioPaths: <String>['/abs/persist/A/disc1.mp3'],
    );

    await doReplaceAudio(repo, bookKey: 'A');

    final AudiobookRow? abRow = await db.getAudiobookByBookKey('A');
    expect(abRow, isNotNull,
        reason: 'real audiobook (with alignment) must never be deleted');
    expect(abRow!.alignmentPath, '/abs/persist/A/aligned.srt');
  });

  test('does NOT heal when the freshly written audio set is empty (no-op)',
      () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    await seedPairedSrtBook(repo, bookKey: 'A');
    await insertAudiobookRow(
      bookKey: 'A',
      alignmentFormat: '',
      alignmentPath: '',
      audioPaths: <String>['/old/wrong.mp3'],
    );

    final List<String> persisted =
        await repo.replaceAudio(uid: 'srtbook_epub_A', pickedPaths: <String>[]);
    expect(persisted, isEmpty);

    expect(await db.getAudiobookByBookKey('A'), isNotNull,
        reason: 'empty import must not heal anything');
  });

  test('does NOT heal for a standalone SRT book (empty bookKey)', () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    final SrtBook standalone = SrtBook()
      ..uid = 'srtbook_999'
      ..title = 'Standalone'
      ..srtPath = '/src/s.srt'
      ..importedAt = 1
      ..bookKey = '';
    await repo.save(standalone);
    await insertAudiobookRow(
      bookKey: '',
      alignmentFormat: '',
      alignmentPath: '',
      audioPaths: <String>['/old/x.mp3'],
    );

    final Directory srcDir = Directory(p.join(docsDir.path, 'src'))
      ..createSync(recursive: true);
    final File a = File(p.join(srcDir.path, 'sa.mp3'))..writeAsStringSync('S');
    await repo.replaceAudio(uid: 'srtbook_999', pickedPaths: <String>[a.path]);

    expect(await db.getAudiobookByBookKey(''), isNotNull,
        reason: 'standalone (empty bookKey) must never trigger heal');
  });

  test(
      'cue isolation: healing a dirty Audiobook row deletes only the bookKey '
      'cues, never the SrtBook uid cues', () async {
    final SrtBookRepository repo = SrtBookRepository(db);
    await seedPairedSrtBook(repo, bookKey: 'A');
    await insertAudiobookRow(
      bookKey: 'A',
      alignmentFormat: '',
      alignmentPath: '',
      audioPaths: <String>['/old/wrong.mp3'],
    );

    await repo.saveCues(uid: 'srtbook_epub_A', cues: <AudioCue>[
      makeCue(
        bookKey: 'srtbook_epub_A',
        chapterHref: SrtParser.defaultChapter,
        sentenceIndex: 0,
        startMs: 0,
        endMs: 1000,
      ),
    ]);

    await AudiobookRepository(db).saveCues(bookKey: 'A', cues: <AudioCue>[
      makeCue(
        bookKey: 'A',
        chapterHref: 'c.xhtml',
        sentenceIndex: 0,
        startMs: 0,
        endMs: 500,
      ),
    ]);

    await doReplaceAudio(repo, bookKey: 'A');

    final List<AudioCue> remainingDirty =
        await AudiobookRepository(db).cuesForBook('A');
    expect(remainingDirty, isEmpty,
        reason: 'dirty bookKey cues deleted with the row');
    final List<AudioCue> remainingSrt = await repo.cuesFor('srtbook_epub_A');
    expect(remainingSrt, hasLength(1),
        reason: 'SrtBook uid cues must survive (different namespace)');
  });
}
