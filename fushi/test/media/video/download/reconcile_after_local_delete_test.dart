/// 库侧删视频 + 「同时删除本地文件」→ 原始文件真从磁盘消失 → 下载任务按路径对账：
/// 部分集被删 → 文件行标 skipped、任务保留；全部视频没了 → 任务整条删除。
/// 以及仓储层护栏：仍被别的行引用的文件不删；不勾就一个文件都不动。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_local_files.dart'
    show LocalVideoFileDeleteHooks;
import 'package:fushi_core/fushi_core.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FushiDatabase db;
  late VideoBookRepository repo;
  late Directory tmp;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = VideoBookRepository(db);
    tmp = await Directory.systemTemp.createTemp('fushi-reconcile-');
  });
  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  File touch(String name) =>
      File(p.join(tmp.path, name))..writeAsStringSync(name);

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
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> insertFile(String jobId, File file, {int index = 0}) {
    final int now = DateTime.now().millisecondsSinceEpoch;
    return db.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: Value<int?>(index),
        originalRelativePath: p.basename(file.path),
        currentRelativePath: p.basename(file.path),
        finalAbsolutePath: Value<String?>(file.path),
        kind: const Value<String>('video'),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: now,
        updatedAt: now,
      ),
    );
  }

  Future<void> insertVideo(String uid, String path) => repo.saveVideoBook(
    VideoBooksCompanion.insert(bookUid: uid, title: uid, videoPath: path),
  );

  group('reconcileVideoDownloadJobsAfterLocalDelete', () {
    test('部分集被删 → 命中的文件行 skipped、任务保留', () async {
      final File e1 = touch('e1.mkv');
      final File e2 = touch('e2.mkv');
      await insertJob('job', lifecycle: VideoDownloadJobLifecycle.completed);
      await insertFile('job', e1, index: 0);
      await insertFile('job', e2, index: 1);
      e1.deleteSync();

      await reconcileVideoDownloadJobsAfterLocalDelete(
        database: db,
        deletedPaths: <String>{e1.path},
      );

      expect(await db.getVideoDownloadJob('job'), isNotNull);
      final List<VideoDownloadJobFileRow> files = await db
          .getVideoDownloadJobFiles('job');
      final Map<String, String> status = <String, String>{
        for (final VideoDownloadJobFileRow f in files)
          f.originalRelativePath: f.status,
      };
      expect(status['e1.mkv'], VideoDownloadJobFileStatus.skipped);
      expect(status['e2.mkv'], VideoDownloadJobFileStatus.imported);
      expect(e2.existsSync(), isTrue);
    });

    test('视频文件全没了 → 任务整条删除（db-only 路径）', () async {
      final File e1 = touch('e1.mkv');
      final File e2 = touch('e2.mkv');
      final File sub = touch('e1.srt');
      await insertJob('job', lifecycle: VideoDownloadJobLifecycle.completed);
      await insertFile('job', e1, index: 0);
      await insertFile('job', e2, index: 1);
      // 附带的字幕行：任务整删时随 deleteFiles:true 一起清。
      final int now = DateTime.now().millisecondsSinceEpoch;
      final int e1RowId = (await db.getVideoDownloadJobFiles('job'))
          .firstWhere(
            (VideoDownloadJobFileRow f) => f.originalRelativePath == 'e1.mkv',
          )
          .id;
      await db.upsertVideoDownloadJobSubtitle(
        VideoDownloadJobSubtitlesCompanion.insert(
          subtitleId: 'sub1',
          jobId: 'job',
          jobFileId: Value<int?>(e1RowId),
          provider: 'jimaku',
          finalPath: Value<String?>(sub.path),
          status: const Value<String>(VideoDownloadJobSubtitleStatus.placed),
          createdAt: now,
          updatedAt: now,
        ),
      );
      e1.deleteSync();
      e2.deleteSync();

      await reconcileVideoDownloadJobsAfterLocalDelete(
        database: db,
        deletedPaths: <String>{e1.path, e2.path},
      );

      expect(await db.getVideoDownloadJob('job'), isNull);
      expect(sub.existsSync(), isFalse, reason: '整任务删除连残余字幕一起清');
    });

    test('任务还在跑 → 只标 skipped，绝不整删', () async {
      final File e1 = touch('e1.mkv');
      await insertJob('job', lifecycle: VideoDownloadJobLifecycle.active);
      await insertFile('job', e1);
      e1.deleteSync();

      await reconcileVideoDownloadJobsAfterLocalDelete(
        database: db,
        deletedPaths: <String>{e1.path},
      );

      expect(await db.getVideoDownloadJob('job'), isNotNull);
      expect(
        (await db.getVideoDownloadJobFiles('job')).single.status,
        VideoDownloadJobFileStatus.skipped,
      );
    });

    test('别的集被改名/移走（DB 路径已过期）→ 归属判据不翻转，绝不整删', () async {
      // 这是「拿存在性检查当归属判据」的具体炸法：用户在资源管理器里改名/移动
      // 了 e2，或者换了盘符、qB 改了保存路径——DB 里那条路径就指不到文件了。
      // 旧判据据此认定「别的视频都没了」，于是删一集连整个种子的数据一起删。
      final File e1 = touch('e1.mkv');
      final File e2 = touch('e2.mkv');
      await insertJob('job', lifecycle: VideoDownloadJobLifecycle.completed);
      await insertFile('job', e1, index: 0);
      await insertFile('job', e2, index: 1);
      e1.deleteSync();
      final String renamed = p.join(tmp.path, 'e2-renamed.mkv');
      e2.renameSync(renamed);

      await reconcileVideoDownloadJobsAfterLocalDelete(
        database: db,
        deletedPaths: <String>{e1.path},
      );

      expect(
        await db.getVideoDownloadJob('job'),
        isNotNull,
        reason: '本次删除只覆盖了 e1，e2 那条 video 行没被覆盖 → 任务不能整删',
      );
      expect(File(renamed).existsSync(), isTrue, reason: '改名后的那一集必须还在');
      final Map<String, String> status = <String, String>{
        for (final VideoDownloadJobFileRow f
            in await db.getVideoDownloadJobFiles('job'))
          f.originalRelativePath: f.status,
      };
      expect(status['e1.mkv'], VideoDownloadJobFileStatus.skipped);
      expect(status['e2.mkv'], VideoDownloadJobFileStatus.imported);
    });

    test('有 kind=video 行没记落盘路径 → 不算被覆盖，不整删', () async {
      // `finalAbsolutePath` 为空的行以前被 `continue` 当成「不存在」，是同方向的
      // 第二个洞：判不出它指向哪，就不能拿它当整删的依据。
      final File e1 = touch('e1.mkv');
      await insertJob('job', lifecycle: VideoDownloadJobLifecycle.completed);
      await insertFile('job', e1, index: 0);
      final int now = DateTime.now().millisecondsSinceEpoch;
      await db.upsertVideoDownloadJobFile(
        VideoDownloadJobFilesCompanion.insert(
          jobId: 'job',
          backendFileIndex: const Value<int?>(1),
          originalRelativePath: 'e2.mkv',
          currentRelativePath: 'e2.mkv',
          kind: const Value<String>('video'),
          status: const Value<String>(VideoDownloadJobFileStatus.pending),
          createdAt: now,
          updatedAt: now,
        ),
      );
      e1.deleteSync();

      await reconcileVideoDownloadJobsAfterLocalDelete(
        database: db,
        deletedPaths: <String>{e1.path},
      );

      expect(await db.getVideoDownloadJob('job'), isNotNull);
    });

    test('大小写不同的路径仍然命中同一条文件行（Windows）', () async {
      final File e1 = touch('Ep01.mkv');
      await insertJob('job', lifecycle: VideoDownloadJobLifecycle.active);
      await insertFile('job', e1, index: 0);
      e1.deleteSync();

      await reconcileVideoDownloadJobsAfterLocalDelete(
        database: db,
        deletedPaths: <String>{e1.path.toLowerCase()},
      );

      final String status =
          (await db.getVideoDownloadJobFiles('job')).single.status;
      expect(
        status,
        Platform.isWindows
            ? VideoDownloadJobFileStatus.skipped
            : VideoDownloadJobFileStatus.imported,
        reason: 'Windows 上大小写不同 = 同一个文件；大小写敏感平台上不是',
      );
    });

    test('路径不命中任何任务 → 无副作用', () async {
      final File e1 = touch('e1.mkv');
      await insertJob('job', lifecycle: VideoDownloadJobLifecycle.completed);
      await insertFile('job', e1);
      await reconcileVideoDownloadJobsAfterLocalDelete(
        database: db,
        deletedPaths: <String>{p.join(tmp.path, 'other.mkv')},
      );
      expect(await db.getVideoDownloadJob('job'), isNotNull);
      expect(
        (await db.getVideoDownloadJobFiles('job')).single.status,
        VideoDownloadJobFileStatus.imported,
      );
    });
  });

  group('VideoBookRepository.deleteVideoBooksAndReclaimAssets', () {
    test('deleteLocalFiles=true → 原件删掉并回调路径', () async {
      final File v = touch('movie.mkv');
      await insertVideo('video/movie', v.path);
      Set<String>? reported;

      List<String>? prepared;
      final int deleted = await repo.deleteVideoBooksAndReclaimAssets(
        <String>['video/movie'],
        deleteLocalFiles: true,
        compactDatabase: false,
        localFileHooks: LocalVideoFileDeleteHooks(
          beforeDelete: (List<String> candidates) async {
            // 删磁盘之前跑，此刻文件必须还在——先让引用方放手，再销毁实体。
            prepared = candidates;
            expect(v.existsSync(), isTrue);
          },
          afterDelete: (LocalFileDeleteReport report) async =>
              reported = report.removedSet,
        ),
      );

      expect(deleted, 1);
      expect(v.existsSync(), isFalse);
      expect(prepared, <String>[v.path]);
      expect(reported, <String>{v.path});
      expect(await repo.getByBookUid('video/movie'), isNull);
    });

    test('默认不删原件（现有语义一个字不变）', () async {
      final File v = touch('movie.mkv');
      await insertVideo('video/movie', v.path);
      await repo.deleteVideoBooksAndReclaimAssets(<String>[
        'video/movie',
      ], compactDatabase: false);
      expect(v.existsSync(), isTrue);
    });

    test('仍被别的行引用的文件不删、也不回调', () async {
      final File v = touch('shared.mkv');
      await insertVideo('video/a', v.path);
      await insertVideo('video/ext/b', v.path.replaceAll('\\', '/'));
      bool called = false;
      await repo.deleteVideoBooksAndReclaimAssets(
        <String>['video/a'],
        deleteLocalFiles: true,
        compactDatabase: false,
        localFileHooks: LocalVideoFileDeleteHooks(
          beforeDelete: (_) async => called = true,
          afterDelete: (_) async => called = true,
        ),
      );
      expect(v.existsSync(), isTrue);
      expect(called, isFalse, reason: '一个候选都不剩时前后挂钩都不该跑');
      expect(await repo.getByBookUid('video/ext/b'), isNotNull);
    });

    test('远端流行：勾了也没有文件可删，不回调', () async {
      await insertVideo('video/remote', 'https://host/stream?token=1');
      bool called = false;
      await repo.deleteVideoBooksAndReclaimAssets(
        <String>['video/remote'],
        deleteLocalFiles: true,
        compactDatabase: false,
        localFileHooks: LocalVideoFileDeleteHooks(
          beforeDelete: (_) async => called = true,
          afterDelete: (_) async => called = true,
        ),
      );
      expect(called, isFalse);
    });
  });
}
