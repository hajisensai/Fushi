import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
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
  late HibikiDatabase db;

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
    final Audiobook dirty = Audiobook()
      ..bookKey = bookKey
      ..alignmentFormat = ''
      ..alignmentPath = ''
      ..audioPaths = <String>[staleAudio.path];
    await AudiobookRepository(db).saveAudiobook(dirty);

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
}
