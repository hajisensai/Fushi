/// 有声书删除 + 「同时删除本地文件」的端到端契约（仓库层）：
/// ① 只删这条记录**显式登记**的原件，同目录里别的书的音频绝不牵连；
/// ② app 持久目录里的副本不算原件（由 deletePersistDir 回收）；
/// ③ 墓碑排在**所有**磁盘操作之前——磁盘尾活会抛（权限拒绝 / 网络盘掉线 / 句柄
///    占用），排在它后面一次失败就静默吞掉用户「从所有设备删除」的意图。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  late AudiobookRepository repo;
  late Directory tmp;
  late Directory docs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = AudiobookRepository(db);
    tmp = await Directory.systemTemp.createTemp('fushi-ab-del-');
    docs = Directory(p.join(tmp.path, 'documents'))
      ..createSync(recursive: true);
    AudiobookStorage.documentsRootResolver = () async => docs;
  });
  tearDown(() async {
    AudiobookStorage.documentsRootResolver = null;
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  Future<void> insertAudiobook({
    required String bookKey,
    List<String>? audioPaths,
    String? audioRoot,
  }) =>
      db.upsertAudiobook(
        AudiobooksCompanion.insert(
          bookKey: bookKey,
          alignmentFormat: 'srt',
          alignmentPath: p.join(tmp.path, 'align.srt'),
          audioPathsJson: Value<String?>(
            audioPaths == null ? null : jsonEncode(audioPaths),
          ),
          audioRoot: Value<String?>(audioRoot),
        ),
      );

  Future<List<SyncDeletionTombstoneRow>> tombstones() =>
      db.getSyncDeletionTombstonesOfType(SyncTombstoneKind.audiobook.dbValue);

  test('只删登记的那几个；同一 audioRoot 下别的书的音频原样保留', () async {
    final Directory music = Directory(p.join(tmp.path, 'music'))
      ..createSync(recursive: true);
    final File mine = File(p.join(music.path, 'A-01.mp3'))
      ..writeAsStringSync('1');
    final File others = File(p.join(music.path, 'B-01.mp3'))
      ..writeAsStringSync('2');
    await insertAudiobook(
      bookKey: 'book/a',
      audioPaths: <String>[mine.path],
      audioRoot: music.path,
    );

    final LocalFileDeleteReport report = await repo.deleteAudiobook(
      'book/a',
      deleteLocalFiles: true,
    );

    expect(report.removedSet, <String>{mine.path});
    expect(mine.existsSync(), isFalse);
    expect(
      others.existsSync(),
      isTrue,
      reason: '旧版按 audioRoot 做目录清扫，删 A 会把 B 的音频一起删掉',
    );
    expect(music.existsSync(), isTrue, reason: '只删文件，绝不删目录');
  });

  test('纯 audioRoot 的旧行：一个文件都不删（没有可安全删除的清单）', () async {
    final Directory music = Directory(p.join(tmp.path, 'legacy'))
      ..createSync(recursive: true);
    final File a = File(p.join(music.path, '01.mp3'))..writeAsStringSync('1');
    final File b = File(p.join(music.path, '02.mp3'))..writeAsStringSync('2');
    await insertAudiobook(bookKey: 'book/legacy', audioRoot: music.path);

    final LocalFileDeleteReport report = await repo.deleteAudiobook(
      'book/legacy',
      deleteLocalFiles: true,
    );

    expect(report.isEmpty, isTrue);
    expect(a.existsSync(), isTrue);
    expect(b.existsSync(), isTrue);
  });

  test('坏 audioPaths JSON 不得回落成目录清扫', () async {
    final Directory music = Directory(p.join(tmp.path, 'broken'))
      ..createSync(recursive: true);
    final File a = File(p.join(music.path, '01.mp3'))..writeAsStringSync('1');
    await db.upsertAudiobook(
      AudiobooksCompanion.insert(
        bookKey: 'book/broken',
        alignmentFormat: 'srt',
        alignmentPath: p.join(tmp.path, 'align.srt'),
        audioPathsJson: const Value<String?>('{not json'),
        audioRoot: Value<String?>(music.path),
      ),
    );

    // 一次 JSON 解码失败绝不能把爆炸半径从「删这几个文件」升级成
    // 「删这个目录里全部音频」。
    final SrtBookRepository srt = SrtBookRepository(db);
    await db.upsertSrtBook(
      SrtBooksCompanion.insert(
        uid: 'srt/broken',
        title: 'broken',
        srtPath: p.join(tmp.path, 'x.srt'),
        importedAt: 0,
        audioPathsJson: const Value<String?>('{not json'),
        audioRoot: Value<String?>(music.path),
      ),
    );
    final SrtBookDeleteResult result = await srt.delete(
      'srt/broken',
      deleteLocalFiles: true,
    );

    expect(result.localFiles.isEmpty, isTrue);
    expect(a.existsSync(), isTrue);
  });

  test('app 持久目录里的副本不算用户原件', () async {
    final Directory persist = await AudiobookStorage.ensurePersistDir(
      'book/copy',
    );
    final File copy = File(p.join(persist.path, '01.mp3'))
      ..writeAsStringSync('1');
    await insertAudiobook(
        bookKey: 'book/copy', audioPaths: <String>[copy.path]);

    final LocalFileDeleteReport report = await repo.deleteAudiobook(
      'book/copy',
      deleteLocalFiles: true,
    );

    expect(
      report.isEmpty,
      isTrue,
      reason: '副本由 deletePersistDir 回收，不该在原件删除里重复计数',
    );
    expect(persist.existsSync(), isFalse, reason: '持久目录整个被回收');
  });

  test('磁盘清理抛异常时 audiobook 墓碑仍然写下去', () async {
    await insertAudiobook(bookKey: 'book/throws');
    AudiobookStorage.documentsRootResolver =
        () async => throw const FileSystemException('boom');

    await expectLater(
      repo.deleteAudiobook('book/throws', propagateDeletion: true),
      throwsA(isA<FileSystemException>()),
    );

    final List<SyncDeletionTombstoneRow> rows = await tombstones();
    expect(rows, hasLength(1), reason: '尾活炸了，但用户的删除意图必须已经落账');
    expect(rows.single.itemKey, 'book/throws');
    expect(await db.getAudiobookByBookKey('book/throws'), isNull);
  });
}
