import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

/// TODO-1032 PR2 regression: pins down "re-imported audio is wrong" at the
/// read path. AudiobookSessionLauncher.resolve queries Audiobooks first, then
/// falls back to SrtBooks. A legacy shelf audioOnly import left a dirty
/// Audiobook row (old/wrong audio) for the same bookKey, so resolve kept
/// returning the stale audio even after the user re-located the correct audio
/// onto the SrtBook. PR2 heals that dirty row inside replaceAudio, so resolve
/// now lands on the SrtBook's freshly imported audio.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;
  late FushiDatabase db;

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp('hibiki_launcher_heal_');
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
    db = FushiDatabase.forTesting(NativeDatabase.memory());
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

  test(
      'after replaceAudio heals the dirty Audiobook row, resolve(bookKey) '
      'returns the SrtBook freshly imported audio (not the stale row)',
      () async {
    const String bookKey = 'A';
    final SrtBookRepository srtRepo = SrtBookRepository(db);

    // EPUB-paired SRT book (no audio yet) the user will re-import audio onto.
    final SrtBook book = SrtBook()
      ..uid = 'srtbook_epub_$bookKey'
      ..title = 'Paired'
      ..srtPath = '/src/paired.srt'
      ..importedAt = 1
      ..bookKey = bookKey;
    await srtRepo.save(book);

    // Dirty Audiobook row (legacy audioOnly import): same bookKey, no
    // alignment, pointing at a real-but-stale audio file so resolve would
    // otherwise return it first.
    final Directory staleDir = Directory(p.join(docsDir.path, 'stale'))
      ..createSync(recursive: true);
    final File staleAudio = File(p.join(staleDir.path, 'old.mp3'))
      ..writeAsStringSync('STALE');
    // 「脏行」= 有音频、没对齐字幕。窄写入下这件事只能这么表达：ensure 建行
    // （alignment 两列留空串），再单独写音频——想给它加上对齐都得多调一个方法。
    final AudiobookRepository dirtyRepo = AudiobookRepository(db);
    await dirtyRepo.ensureAudiobook(bookKey);
    await dirtyRepo
        .replaceAudio(bookKey: bookKey, audioPaths: <String>[staleAudio.path]);

    // Pre-condition: resolve returns the stale Audiobook audio.
    final AudiobookSessionLauncher launcher = AudiobookSessionLauncher(db);
    final AudiobookSessionStartRequest? before =
        await launcher.resolve(bookKey);
    expect(before, isNotNull);
    expect(before!.audioFiles.single.path, staleAudio.path,
        reason: 'before heal, resolve returns the dirty Audiobook audio');

    // User re-imports the correct audio onto the SrtBook (the only write path).
    final Directory srcDir = Directory(p.join(docsDir.path, 'src'))
      ..createSync(recursive: true);
    final File correct = File(p.join(srcDir.path, 'correct.mp3'))
      ..writeAsStringSync('CORRECT');
    await srtRepo.replaceAudio(
      uid: 'srtbook_epub_$bookKey',
      pickedPaths: <String>[correct.path],
    );

    // Post-condition: the dirty row is healed away, so resolve falls through to
    // the SrtBook and returns the freshly imported audio.
    expect(await db.getAudiobookByBookKey(bookKey), isNull);
    final AudiobookSessionStartRequest? after = await launcher.resolve(bookKey);
    expect(after, isNotNull);
    expect(after!.audioFiles, hasLength(1));
    expect(p.basename(after.audioFiles.single.path), 'correct.mp3',
        reason: 'after heal, resolve returns the SrtBook freshly imported '
            'audio, not the stale Audiobook audio');
    expect(after.audioFiles.single.path, isNot(staleAudio.path));
  });

  test(
      'resolve marks an EPUB Audiobook row as audiobook source even when '
      'its alignment format is srt', () async {
    const String bookKey = 'epub-audio';
    final Directory srcDir = Directory(p.join(docsDir.path, 'epub_audio'))
      ..createSync(recursive: true);
    final File audio = File(p.join(srcDir.path, 'audio.mp3'))
      ..writeAsStringSync('AUDIO');
    final File alignment = File(p.join(srcDir.path, 'align.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nHello\n');

    final AudiobookRepository realRepo = AudiobookRepository(db);
    await realRepo.replaceAlignment(
        bookKey: bookKey, format: 'srt', path: alignment.path);
    await realRepo
        .replaceAudio(bookKey: bookKey, audioPaths: <String>[audio.path]);

    final AudiobookSessionLauncher launcher = AudiobookSessionLauncher(db);
    final AudiobookSessionStartRequest? request =
        await launcher.resolve(bookKey);

    expect(request, isNotNull);
    expect(request!.isSrtBookSource, isFalse,
        reason: 'SRT is an alignment format here; the row still came from '
            'Audiobooks and reader cue loading must use AudiobookRepository.');
  });

  test('resolve marks SrtBook fallback as srt book source', () async {
    const String bookKey = 'epub-paired';
    const String uid = 'srtbook_epub_$bookKey';
    final Directory srcDir = Directory(p.join(docsDir.path, 'srt_book'))
      ..createSync(recursive: true);
    final File audio = File(p.join(srcDir.path, 'audio.mp3'))
      ..writeAsStringSync('AUDIO');
    final File srt = File(p.join(srcDir.path, 'book.srt'))
      ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nHello\n');

    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = 'Paired SRT'
      ..srtPath = srt.path
      ..audioPaths = <String>[audio.path]
      ..importedAt = 1
      ..bookKey = bookKey;
    await SrtBookRepository(db).save(book);

    final AudiobookSessionLauncher launcher = AudiobookSessionLauncher(db);
    final AudiobookSessionStartRequest? request =
        await launcher.resolve(bookKey);

    expect(request, isNotNull);
    expect(request!.isSrtBookSource, isTrue);
    expect(request.info.bookKey, uid);
  });
}
