import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:fushi_engine/media/import/epub_backed_srt_book.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// EPUB 有声书「只换音频」的引擎入口 [replaceAudiobookAudio]（app ctl 路由与服务端
/// 有声书库根重扫共用）与换字幕后回收旧持久副本的 [deletePersistedSubtitleCopy]。
void main() {
  late Directory tmp;
  late FushiDatabase db;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_replace_ab_audio_');
    AudiobookStorage.documentsRootResolver = () async => tmp;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
    AudiobookStorage.documentsRootResolver = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String source(String name) {
    final File f = File(p.join(tmp.path, 'library', 'Book', name))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[1, 2, 3]);
    return f.path;
  }

  test('references the audio and updates the audiobook row and its paired '
      'SrtBook together, leaving importedAt alone', () async {
    final String a = source('01.mp3');
    final String b = source('02.mp3');
    final AudiobookRepository abRepo = AudiobookRepository(db);
    final SrtBookRepository srtRepo = SrtBookRepository(db);
    await abRepo.replaceAudio(bookKey: 'Book', audioPaths: <String>[a]);
    await writeEpubBackedSrtBook(
      db: db,
      bookKey: 'Book',
      title: 'Book',
      author: null,
      srtPath: '/persist/book.srt',
      audioPaths: <String>[a],
    );
    final int importedAt = (await srtRepo.findByBookKey('Book'))!.importedAt;
    await abRepo.updatePositionMs(bookKey: 'Book', positionMs: 900);

    final List<String> out = await replaceAudiobookAudio(
      db: db,
      bookKey: 'Book',
      audioPaths: <String>[a, b],
      copyAudio: false,
    );

    expect(out, <String>[a, b]);
    expect((await abRepo.findByBookKey('Book'))!.audioPaths, <String>[a, b]);
    final SrtBook paired = (await srtRepo.findByUid(
      epubBackedSrtBookUid('Book'),
    ))!;
    expect(paired.audioPaths, <String>[
      a,
      b,
    ], reason: '互联导出两行的音频都打包，配对行不换就把旧清单发给对端');
    expect(paired.importedAt, importedAt);
    expect(await abRepo.readPositionMs('Book'), 900, reason: '追加分段不丢进度');
    final Directory persist = await AudiobookStorage.ensurePersistDir('Book');
    expect(
      persist.listSync().whereType<File>().where(
        (File f) => AudiobookStorage.isAudioFile(f.path),
      ),
      isEmpty,
      reason: '引用导入不往持久目录拷音频',
    );
  });

  test('deletePersistedSubtitleCopy only removes a replaced copy inside the '
      'persist dir', () async {
    final Directory persist = await AudiobookStorage.ensurePersistDir('Book');
    final File old = File(p.join(persist.path, 'book.srt'))
      ..writeAsStringSync('old');
    final File fresh = File(p.join(persist.path, 'book _1.srt'))
      ..writeAsStringSync('new');
    final File outside = File(p.join(tmp.path, 'library', 'user.srt'))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('user');

    await deletePersistedSubtitleCopy(
      persistDir: persist,
      oldPath: fresh.path,
      keepPath: fresh.path,
    );
    expect(fresh.existsSync(), isTrue, reason: '新副本就是旧路径时不删');
    await deletePersistedSubtitleCopy(
      persistDir: persist,
      oldPath: outside.path,
      keepPath: fresh.path,
    );
    expect(outside.existsSync(), isTrue, reason: '持久目录外的是用户原件，绝不删');
    await deletePersistedSubtitleCopy(
      persistDir: persist,
      oldPath: old.path,
      keepPath: fresh.path,
    );
    expect(old.existsSync(), isFalse);
  });

  // ── BUG-4810：拷新 → 写库 → 删旧，失败原样撤回 ─────────────────────────

  /// 持久目录的全貌（相对路径 → 内容）。
  Map<String, String> snapshot(Directory dir) => <String, String>{
    for (final FileSystemEntity f in dir.listSync(recursive: true))
      if (f is File)
        p.relative(f.path, from: dir.path).replaceAll(r'\', '/'): f
            .readAsStringSync(),
  };

  File writeFile(String relative, String body) =>
      File(p.join(tmp.path, 'library', relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(body);

  String srt(String text) => '1\n00:00:01,000 --> 00:00:02,000\n$text\n\n';

  /// 让 AIFF 的「拷贝」失败：转码器抛错。
  void failTranscode() {
    AudiobookStorage.flacTranscoder = (String src, String dest) async =>
        throw const FileSystemException('disk full');
  }

  Future<AudiobookAlignmentResult> align({
    required String subtitle,
    required List<String> audio,
  }) => alignAndPersistAudiobook(
    db: db,
    audiobookRepo: AudiobookRepository(db),
    bookKey: 'Book',
    title: 'Book',
    subtitlePath: subtitle,
    audioPaths: audio,
  );

  test('replaceAudiobookAudio: a copy that fails midway keeps both rows and '
      'the old audio', () async {
    final AudiobookRepository abRepo = AudiobookRepository(db);
    final List<String> first = await replaceAudiobookAudio(
      db: db,
      bookKey: 'Book',
      audioPaths: <String>[writeFile('old.mp3', 'OLD').path],
    );
    final Directory persist = await AudiobookStorage.ensurePersistDir('Book');
    final Map<String, String> before = snapshot(persist);
    failTranscode();
    addTearDown(() => AudiobookStorage.flacTranscoder = null);

    await expectLater(
      replaceAudiobookAudio(
        db: db,
        bookKey: 'Book',
        audioPaths: <String>[
          writeFile('new1.mp3', 'NEW-1').path,
          writeFile('new2.aiff', 'NEW-2').path,
        ],
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect((await abRepo.findByBookKey('Book'))!.audioPaths, first);
    expect(snapshot(persist), before);
  });

  test('alignAndPersistAudiobook: a copy that fails midway keeps the old '
      'subtitle, audio, cues and row', () async {
    final AudiobookRepository abRepo = AudiobookRepository(db);
    await align(
      subtitle: writeFile('book.srt', srt('旧句')).path,
      audio: <String>[writeFile('old.mp3', 'OLD').path],
    );
    final Audiobook before = (await abRepo.findByBookKey('Book'))!;
    final Directory persist = await AudiobookStorage.ensurePersistDir('Book');
    final Map<String, String> filesBefore = snapshot(persist);
    failTranscode();
    addTearDown(() => AudiobookStorage.flacTranscoder = null);

    await expectLater(
      align(
        subtitle: writeFile('v2/book.srt', srt('新句')).path,
        audio: <String>[
          writeFile('new1.mp3', 'NEW-1').path,
          writeFile('new2.aiff', 'NEW-2').path,
        ],
      ),
      throwsA(isA<FileSystemException>()),
    );

    final Audiobook after = (await abRepo.findByBookKey('Book'))!;
    expect(after.alignmentPath, before.alignmentPath);
    expect(after.audioPaths, before.audioPaths);
    expect(
      (await abRepo.cuesForBook('Book')).map((AudioCue c) => c.text),
      <String>['旧句'],
    );
    expect(snapshot(persist), filesBefore, reason: '新落的字幕副本与新音频都要收走，旧的原样');
  });

  test('alignAndPersistAudiobook: the six row writes are one commit, and a '
      'failed commit rolls the files back', () async {
    final AudiobookRepository abRepo = AudiobookRepository(db);
    await align(
      subtitle: writeFile('book.srt', srt('旧句')).path,
      audio: <String>[writeFile('old.mp3', 'OLD').path],
    );
    final Audiobook before = (await abRepo.findByBookKey('Book'))!;
    final Directory persist = await AudiobookStorage.ensurePersistDir('Book');
    final Map<String, String> filesBefore = snapshot(persist);
    // cue 是第五步：前四步（对齐列、音频列、health、配对行）此时都已写过。
    await db.customStatement(
      'CREATE TRIGGER fail_cues BEFORE INSERT ON audio_cues '
      "BEGIN SELECT RAISE(ABORT, 'injected'); END",
    );

    await expectLater(
      align(
        subtitle: writeFile('v2/book.srt', srt('新句')).path,
        audio: <String>[writeFile('new.mp3', 'NEW').path],
      ),
      throwsA(anything),
    );

    await db.customStatement('DROP TRIGGER fail_cues');
    final Audiobook after = (await abRepo.findByBookKey('Book'))!;
    expect(after.alignmentPath, before.alignmentPath, reason: '前几步的写入必须一起回滚');
    expect(after.audioPaths, before.audioPaths);
    expect(
      (await SrtBookRepository(
        db,
      ).findByUid(epubBackedSrtBookUid('Book')))!.srtPath,
      before.alignmentPath,
    );
    expect(
      (await abRepo.cuesForBook('Book')).map((AudioCue c) => c.text),
      <String>['旧句'],
    );
    expect(snapshot(persist), filesBefore);
  });

  test('alignAndPersistAudiobook: a successful swap leaves exactly the new '
      'subtitle and audio', () async {
    final AudiobookRepository abRepo = AudiobookRepository(db);
    await align(
      subtitle: writeFile('book.srt', srt('旧句')).path,
      audio: <String>[writeFile('01.mp3', 'OLD').path],
    );

    await align(
      subtitle: writeFile('v2/book.srt', srt('新句')).path,
      audio: <String>[writeFile('v2/01.mp3', 'NEW').path],
    );

    final Audiobook after = (await abRepo.findByBookKey('Book'))!;
    final Directory persist = await AudiobookStorage.ensurePersistDir('Book');
    expect(snapshot(persist), <String, String>{
      p.basename(after.alignmentPath): srt('新句'),
      '01.mp3': 'NEW',
    });
    expect(after.audioPaths!.map(p.basename), <String>['01.mp3']);
  });
}
