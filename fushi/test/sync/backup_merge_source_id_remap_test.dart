import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/backup_merge_engine.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

import 'temp_dir_cleanup.dart';

/// BUG-5392（反馈 AXlWkmbUmY / hfLuOcL7n0）：合并导入把 `epub_books` /
/// `video_books` 的 `source_id`（备份库 media_sources 的自增 id）原样搬进本机，
/// 而 media_sources 本身不合并——视频 / 书挂到本机碰巧同号的另一个来源上。
/// 两库来源 id 故意错位：src 的 1 号来源在本机是另一个不相干的 1 号来源。
void main() {
  int now() => DateTime.now().millisecondsSinceEpoch;

  MediaSourcesCompanion source(
    String kind,
    String root, {
    String transport = 'local',
    String grouping = 'series',
    bool private = false,
  }) => MediaSourcesCompanion.insert(
    label: p.basename(root),
    mediaKind: kind,
    transport: Value(transport),
    rootPath: root,
    videoGroupingMode: Value(grouping),
    isPrivate: Value(private),
    createdAt: now(),
  );

  Future<void> insertVideo(
    FushiDatabase db,
    String uid, {
    int? sourceId,
    String? grouping,
  }) => db
      .into(db.videoBooks)
      .insert(
        VideoBooksCompanion.insert(
          bookUid: uid,
          title: uid,
          // 网络流地址：不需要随包文件就算「本机可达」，合并一定插入。
          videoPath: 'https://media.example/$uid.mp4',
          sourceId: Value(sourceId),
          videoGroupingMode: Value(grouping),
        ),
      );

  Future<void> insertBook(FushiDatabase db, String key, {int? sourceId}) =>
      db.insertEpubBook(
        EpubBooksCompanion.insert(
          bookKey: key,
          title: key,
          epubPath: '$key.epub',
          extractDir: '/books/$key',
          chapterCount: 1,
          chaptersJson: '["c"]',
          importedAt: now(),
          sourceId: Value(sourceId),
        ),
      );

  late int srcOnlyInBackup;
  late int srcAnime;
  late int srcPrivateNas;
  late int srcBooks;

  Future<String> buildSrcDb() async {
    final Directory dir = await Directory.systemTemp.createTemp('srcmap_src_');
    addTearDown(() => cleanupTempDir(dir));
    final FushiDatabase src = FushiDatabase(dir.path);
    srcOnlyInBackup = await src.insertMediaSource(
      source('video', 'E:/OnlyOnBackupDevice', grouping: 'folder'),
    );
    srcAnime = await src.insertMediaSource(source('video', 'D:/Anime'));
    srcPrivateNas = await src.insertMediaSource(
      source(
        'video',
        'sftp://nas/anime',
        transport: 'sftp',
        grouping: 'folder',
        private: true,
      ),
    );
    srcBooks = await src.insertMediaSource(source('book', 'D:/Books'));

    await insertVideo(src, 'video/orphaned', sourceId: srcOnlyInBackup);
    await insertVideo(src, 'video/anime', sourceId: srcAnime);
    await insertVideo(src, 'video/private', sourceId: srcPrivateNas);
    await insertVideo(src, 'video/manual', grouping: 'folder');
    await insertBook(src, 'book-from-source', sourceId: srcBooks);
    await insertBook(src, 'book-manual');
    await src.close();
    return p.join(dir.path, 'fushi.db');
  }

  Future<void> attachAndMerge(FushiDatabase target, String srcDbPath) async {
    final String safe = srcDbPath.replaceAll(r'\', '/').replaceAll("'", "''");
    await target.customStatement("ATTACH DATABASE '$safe' AS mergesrc");
    await BackupMergeEngine(target).merge();
    await target.customStatement('DETACH DATABASE mergesrc');
  }

  Future<({int? sourceId, String? grouping})> videoRow(
    FushiDatabase db,
    String uid,
  ) async {
    final VideoBookRow row = await (db.select(
      db.videoBooks,
    )..where((t) => t.bookUid.equals(uid))).getSingle();
    return (sourceId: row.sourceId, grouping: row.videoGroupingMode);
  }

  Future<int?> bookSource(FushiDatabase db, String key) async =>
      (await (db.select(
        db.epubBooks,
      )..where((t) => t.bookKey.equals(key))).getSingle()).sourceId;

  test('source_id 按来源身份换成本机 id；本机没有的来源落 NULL 并保留分组与私密', () async {
    final String srcDbPath = await buildSrcDb();

    final FushiDatabase target = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(target.close);
    // 本机来源与 src 错位：本机 1 号是不相干的视频来源，src 的 1 号（只在备份设备上
    // 存在的来源）若原样搬进来就会挂到它头上。
    final int tgtUnrelated = await target.insertMediaSource(
      source('video', 'C:/Unrelated'),
    );
    final int tgtBooks = await target.insertMediaSource(
      source('book', 'D:/Books'),
    );
    final int tgtAnime = await target.insertMediaSource(
      source('video', 'D:/Anime'),
    );
    expect(tgtUnrelated, srcOnlyInBackup, reason: '两库 id 必须撞上才测得到错挂');
    expect(tgtAnime, isNot(srcAnime));
    expect(tgtBooks, isNot(srcBooks));
    expect(tgtAnime, srcPrivateNas, reason: '隐私来源的 id 在本机是另一个公开来源');

    await attachAndMerge(target, srcDbPath);

    Future<void> verify() async {
      // 本机有同一个来源（同种类 + 传输方式 + 根路径）：换成本机那一行的 id。
      expect((await videoRow(target, 'video/anime')).sourceId, tgtAnime);
      expect(await bookSource(target, 'book-from-source'), tgtBooks);

      // 本机没有这个来源：不挂到同号的不相干来源上，落 NULL；来源的分组方式
      // 落到行上（照「移除来源」的语义），不会换一种分组方式归组。
      final ({int? sourceId, String? grouping}) orphaned = await videoRow(
        target,
        'video/orphaned',
      );
      expect(orphaned.sourceId, isNull);
      expect(orphaned.grouping, 'folder');

      // 隐私来源本机没有：source_id 落 NULL，私密意图写成作品级标记。
      final ({int? sourceId, String? grouping}) private = await videoRow(
        target,
        'video/private',
      );
      expect(private.sourceId, isNull);
      expect(private.grouping, 'folder');
      expect(
        await target.isMediaPrivate(TagHostKind.video, 'video/private'),
        isTrue,
      );
      expect(
        await target.isMediaPrivate(TagHostKind.video, 'video/anime'),
        isFalse,
      );

      // 本就无来源的行原样：source_id NULL、行上的分组方式不动。
      final ({int? sourceId, String? grouping}) manual = await videoRow(
        target,
        'video/manual',
      );
      expect(manual.sourceId, isNull);
      expect(manual.grouping, 'folder');
      expect(await bookSource(target, 'book-manual'), isNull);

      // 不相干的本机来源一条都没被挂上。
      expect(
        await target.countMediaBySourceId(tgtUnrelated, 'video'),
        0,
        reason: '备份里的视频不得挂到本机同号的不相干来源上',
      );
      expect(await target.countMediaBySourceId(tgtAnime, 'video'), 1);
    }

    await verify();
    // 重复导入同一份备份：幂等，不改已落地的归属。
    await attachAndMerge(target, srcDbPath);
    await verify();
  });

  test('本机已有作品私密时钟行（用户表过态）时不改写', () async {
    final String srcDbPath = await buildSrcDb();
    final FushiDatabase target = FushiDatabase.forTesting(
      NativeDatabase.memory(),
    );
    addTearDown(target.close);
    // 用户在本机明确取消过这部作品的私密。
    await target.setMediaPrivate(
      TagHostKind.video,
      'video/private',
      false,
      at: 1,
    );

    await attachAndMerge(target, srcDbPath);

    expect(
      await target.isMediaPrivate(TagHostKind.video, 'video/private'),
      isFalse,
    );
  });
}
