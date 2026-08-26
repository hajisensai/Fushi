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

      final int deleted = await repo.deleteVideoBooksAndReclaimAssets(
        <String>['video/movie'],
        deleteLocalFiles: true,
        compactDatabase: false,
        onLocalFilesDeleted: (Set<String> paths) async => reported = paths,
      );

      expect(deleted, 1);
      expect(v.existsSync(), isFalse);
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
        onLocalFilesDeleted: (_) async => called = true,
      );
      expect(v.existsSync(), isTrue);
      expect(called, isFalse);
      expect(await repo.getByBookUid('video/ext/b'), isNotNull);
    });

    test('远端流行：勾了也没有文件可删，不回调', () async {
      await insertVideo('video/remote', 'https://host/stream?token=1');
      bool called = false;
      await repo.deleteVideoBooksAndReclaimAssets(
        <String>['video/remote'],
        deleteLocalFiles: true,
        compactDatabase: false,
        onLocalFilesDeleted: (_) async => called = true,
      );
      expect(called, isFalse);
    });
  });
}
