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
      repo: srtRepo,
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
}
