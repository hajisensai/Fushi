// BUG-3802（反馈 fuQcFmZZxb）：删一部动漫只删了正片，特典与其余资源留在目录里。
//
// 钉子：
// ① 作品被整体删除时，绑定在作品上的本地特典行（来源扫描建的 `Extras/` 视频行）跟着
//    一起删，勾了「同时删除本地文件」时连原件；只删部分集一条不碰；
// ② 下载任务的视频产物被整体删除时，任务记过的 `kind: 'extra'` 附件对应的行跟着删；
// ③ 任务停在 needsAttention（刮削待确认 / 失败）时也整删：非视频资源一并删除，整理器
//    留下的空目录回收，来源根与用户自己放的文件不动。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_library_delete.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/media/video/video_work_companions.dart';
import 'package:fushi_engine/sync/deletion_propagation.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late VideoBookRepository repo;
  late Directory root;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    root = await Directory.systemTemp.createTemp('fushi-work-companions-');
  });
  tearDown(() async {
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  File touch(String relative) {
    final File file = File(
      p.joinAll(<String>[root.path, ...relative.split('/')]),
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(relative);
    return file;
  }

  Future<void> insertVideo(String uid, File file) => db.upsertVideoBook(
    VideoBooksCompanion.insert(bookUid: uid, title: uid, videoPath: file.path),
  );

  /// 两集合集 + 作品 + 一条绑定在作品上的本地特典行。
  Future<({File ep1, File ep2, File extra})> seedSeriesWithLocalExtra() async {
    final File ep1 = touch('Show (2013)/Season 01/Show (2013) - S01E01.mkv');
    final File ep2 = touch('Show (2013)/Season 01/Show (2013) - S01E02.mkv');
    final File extra = touch('Show (2013)/Extras/SPs/Show NCOP.mkv');
    await insertVideo('ep1', ep1);
    await insertVideo('ep2', ep2);
    await insertVideo('extra', extra);
    final int collectionId = await db.createMediaCollection('Show (2013)');
    await db.addToCollection(collectionId, MediaKind.video, 'ep1');
    await db.addToCollection(collectionId, MediaKind.video, 'ep2');
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        collectionId: Value<int?>(collectionId),
        mediaType: 'tv',
        title: 'Show',
        updatedAt: 1,
      ),
    );
    await db.upsertVideoMetadataExtra(
      VideoMetadataExtrasCompanion.insert(
        extraKey: 'local:extra',
        workId: workId,
        bookUid: const Value<String?>('extra'),
        kind: 'extra',
        sourceKind: 'local',
        title: 'Show NCOP',
        updatedAt: 1,
      ),
    );
    return (ep1: ep1, ep2: ep2, extra: extra);
  }

  Future<void> insertJob(String jobId, {required String lifecycle}) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: jobId,
        resourceProvider: 'nyaa:test',
        selectedResourceId: 'r1',
        mediaKind: 'tv',
        title: 'Show',
        backendKind: 'embedded',
        fingerprint: 'fp',
        lifecycle: Value<String>(lifecycle),
        stage: const Value<String>(VideoDownloadJobStage.scrape),
        // 整理后任务记的后端保存位置就是来源根（BUG-3540），同机视角。
        observedSavePath: Value<String?>(root.path),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> insertJobFile(
    String jobId,
    String relative, {
    required int index,
    required String kind,
    bool organized = true,
  }) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return db.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: Value<int?>(index),
        originalRelativePath: relative,
        currentRelativePath: relative,
        finalAbsolutePath: Value<String?>(
          organized
              ? p.joinAll(<String>[root.path, ...relative.split('/')])
              : null,
        ),
        kind: Value<String>(kind),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  group('videoWorkCompanionBookUids', () {
    test('整部剧集删除 → 绑定在作品上的本地特典', () async {
      await seedSeriesWithLocalExtra();
      expect(
        await videoWorkCompanionBookUids(db, <String>['ep1', 'ep2']),
        <String>['extra'],
      );
    });

    test('只删部分集 → 一条不碰', () async {
      await seedSeriesWithLocalExtra();
      expect(await videoWorkCompanionBookUids(db, <String>['ep1']), isEmpty);
    });

    test('电影作品删除 → 它的本地特典', () async {
      final File movie = touch('Movie (2020)/Movie (2020).mkv');
      final File trailer = touch('Movie (2020)/Extras/Trailer.mkv');
      await insertVideo('movie', movie);
      await insertVideo('trailer', trailer);
      final int workId = await db.upsertVideoMetadataWork(
        VideoMetadataWorksCompanion.insert(
          bookUid: const Value<String?>('movie'),
          mediaType: 'movie',
          title: 'Movie',
          updatedAt: 1,
        ),
      );
      await db.upsertVideoMetadataExtra(
        VideoMetadataExtrasCompanion.insert(
          extraKey: 'local:trailer',
          workId: workId,
          bookUid: const Value<String?>('trailer'),
          kind: 'trailer',
          sourceKind: 'local',
          title: 'Trailer',
          updatedAt: 1,
        ),
      );
      expect(await videoWorkCompanionBookUids(db, <String>['movie']), <String>[
        'trailer',
      ]);
    });

    test('下载任务的视频全在删除集合里 → 任务记过的 extra 附件行（未绑作品也算）', () async {
      final File ep1 = touch('Show (2013)/Season 01/Show (2013) - S01E01.mkv');
      final File extra = touch('Show (2013)/Extras/Menu/Menu01.mkv');
      await insertVideo('ep1', ep1);
      await insertVideo('menu', extra);
      await insertJob('job', lifecycle: VideoDownloadJobLifecycle.completed);
      await insertJobFile(
        'job',
        'Show (2013)/Season 01/Show (2013) - S01E01.mkv',
        index: 0,
        kind: 'video',
      );
      await insertJobFile(
        'job',
        'Show (2013)/Extras/Menu/Menu01.mkv',
        index: 1,
        kind: 'extra',
      );
      expect(await videoWorkCompanionBookUids(db, <String>['ep1']), <String>[
        'menu',
      ]);
    });

    test('下载任务还有视频不在删除集合里（含同包并列作品）→ 附件一条不碰', () async {
      final File ep1 = touch('Show (2013)/Season 01/Show (2013) - S01E01.mkv');
      final File sequel = touch('Show (2013)/Sequel [1080p]/Sequel [01].mkv');
      final File extra = touch('Show (2013)/Extras/Menu/Menu01.mkv');
      await insertVideo('ep1', ep1);
      await insertVideo('sequel', sequel);
      await insertVideo('menu', extra);
      await insertJob('job', lifecycle: VideoDownloadJobLifecycle.completed);
      await insertJobFile(
        'job',
        'Show (2013)/Season 01/Show (2013) - S01E01.mkv',
        index: 0,
        kind: 'video',
      );
      await insertJobFile(
        'job',
        'Show (2013)/Sequel [1080p]/Sequel [01].mkv',
        index: 1,
        kind: 'video',
      );
      await insertJobFile(
        'job',
        'Show (2013)/Extras/Menu/Menu01.mkv',
        index: 2,
        kind: 'extra',
      );
      expect(await videoWorkCompanionBookUids(db, <String>['ep1']), isEmpty);
    });
  });

  group('deleteVideoBooksWithDecision', () {
    test('删整部剧集 + 删本地文件 → 特典行与特典文件一并删除', () async {
      final ({File ep1, File ep2, File extra}) files =
          await seedSeriesWithLocalExtra();

      final VideoLibraryDeleteResult result =
          await deleteVideoBooksWithDecision(
            repo: repo,
            database: db,
            pipeline: null,
            bookUids: <String>['ep1', 'ep2'],
            decision: const DeleteDecision(
              scope: DeleteScope.keepLocalOnly,
              deleteLocalFiles: true,
            ),
            compactDatabase: false,
          );

      expect(result.deleted, 3);
      expect(await repo.getByBookUid('extra'), isNull);
      expect(files.ep1.existsSync(), isFalse);
      expect(files.extra.existsSync(), isFalse, reason: '特典文件不能留在目录里');
    });

    test('只删本机副本（成员行保留）→ 不扩到特典', () async {
      final ({File ep1, File ep2, File extra}) files =
          await seedSeriesWithLocalExtra();

      await deleteVideoBooksWithDecision(
        repo: repo,
        database: db,
        pipeline: null,
        bookUids: <String>['ep1', 'ep2'],
        decision: const DeleteDecision(
          scope: DeleteScope.keepLocalOnly,
          deleteLocalFiles: true,
        ),
        compactDatabase: false,
        removeFromCollections: false,
      );

      expect(await repo.getByBookUid('extra'), isNotNull);
      expect(files.extra.existsSync(), isTrue);
    });

    test('needsAttention 的下载任务：视频删光后整删，非视频资源与空目录回收，'
        '来源根与用户文件保留', () async {
      const String ep1Rel = 'Show (2013)/Season 01/Show (2013) - S01E01.mkv';
      const String extraRel = 'Show (2013)/Extras/SPs/Show NCOP.mkv';
      // 非视频资源：整理器不改名，原样随种子落在来源根下的发布目录里。
      const String scanRel = '[Grp] Show [BD]/Scans/cover.jpg';
      final File ep1 = touch(ep1Rel);
      final File extra = touch(extraRel);
      final File scan = touch(scanRel);
      // 用户自己放在作品目录里的文件：不属于任务，绝不能删，所在目录也保留。
      final File userNote = touch('Show (2013)/notes.txt');
      await insertVideo('ep1', ep1);
      await insertVideo('extra', extra);
      await insertJob(
        'job',
        lifecycle: VideoDownloadJobLifecycle.needsAttention,
      );
      await insertJobFile('job', ep1Rel, index: 0, kind: 'video');
      await insertJobFile('job', extraRel, index: 1, kind: 'extra');
      await insertJobFile(
        'job',
        scanRel,
        index: 2,
        kind: 'other',
        organized: false,
      );

      await deleteVideoBooksWithDecision(
        repo: repo,
        database: db,
        pipeline: null,
        bookUids: <String>['ep1'],
        decision: const DeleteDecision(
          scope: DeleteScope.keepLocalOnly,
          deleteLocalFiles: true,
        ),
        compactDatabase: false,
      );

      expect(await db.getVideoDownloadJob('job'), isNull);
      expect(await repo.getByBookUid('extra'), isNull);
      expect(extra.existsSync(), isFalse);
      expect(scan.existsSync(), isFalse, reason: '扫图等非视频资源随任务删除');
      // 整理器建的空壳目录回收。
      expect(
        Directory(p.join(root.path, 'Show (2013)', 'Season 01')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(root.path, 'Show (2013)', 'Extras')).existsSync(),
        isFalse,
      );
      expect(
        Directory(p.join(root.path, '[Grp] Show [BD]')).existsSync(),
        isFalse,
      );
      // 用户文件与其所在目录、来源根保留。
      expect(userNote.existsSync(), isTrue);
      expect(root.existsSync(), isTrue);
    });
  });
}
