// 下载内容改名 / 移动、数据根迁移之后，下载任务表 `video_download_job_files.
// final_absolute_path` 必须与库里 `video_books.video_path` 一起改写。
//
// 任务与库行之间没有 id 级外键，唯一纽带就是这两列相等：下载后补抓字幕
// （download_subtitle_retry.dart）、库侧删除反查任务
// （video_download_pipeline_service.dart `_jobFilesMatching`）全靠它。以前两处
// 源头只改库、不改任务，纽带一断，补字幕永远对不上、删条目找不到要 skip 的文件。

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/download_relocate_service.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

/// 只实现改名 / 移动两条路径的后端：恒成功。
class _OkBackend implements TorrentBackend {
  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async => const TorrentStorageResult(ok: true);

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async => TorrentStorageResult(ok: true, path: newSavePath);

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<int> _seedJobFile(
  FushiDatabase db, {
  required String jobId,
  required String finalAbsolutePath,
}) async {
  await db.upsertVideoDownloadJob(
    VideoDownloadJobsCompanion.insert(
      jobId: jobId,
      resourceProvider: 'nyaa:test',
      selectedResourceId: 'r-$jobId',
      mediaKind: 'tv',
      title: 'Show',
      backendKind: 'embedded',
      fingerprint: 'fp-$jobId',
      lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
      stage: const Value<String>(VideoDownloadJobStage.scrape),
      createdAt: 1,
      updatedAt: 1,
    ),
  );
  await db.upsertVideoDownloadJobFile(
    VideoDownloadJobFilesCompanion.insert(
      jobId: jobId,
      backendFileIndex: const Value<int?>(0),
      originalRelativePath: p.basename(finalAbsolutePath),
      currentRelativePath: p.basename(finalAbsolutePath),
      finalAbsolutePath: Value<String?>(finalAbsolutePath),
      kind: const Value<String>('video'),
      status: const Value<String>(VideoDownloadJobFileStatus.imported),
      createdAt: 1,
      updatedAt: 1,
    ),
  );
  return (await db.getVideoDownloadJobFiles(jobId)).single.id;
}

Future<String?> _jobPath(FushiDatabase db, String jobId) async =>
    (await db.getVideoDownloadJobFiles(jobId)).single.finalAbsolutePath;

Future<String?> _bookPath(FushiDatabase db, String uid) async =>
    (await db.allVideoBooks())
        .firstWhere((VideoBookRow r) => r.bookUid == uid)
        .videoPath;

void main() {
  group('改名 / 移动：DownloadRelocateService → migrateMediaPaths', () {
    late FushiDatabase db;
    late DownloadRelocateService service;
    final String root = p.join(p.rootPrefix(p.current), 'dl', 'Show');
    final String elsewhere = p.join(p.rootPrefix(p.current), 'other', 'x.mkv');

    setUp(() async {
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      service = DownloadRelocateService(
        backendFactory: _OkBackend.new,
        migrateLibraryPaths:
            ({required String fromPath, required String toPath}) =>
                VideoBookRepository(
                  db,
                ).migrateMediaPaths(fromPath: fromPath, toPath: toPath),
      );
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/ep01',
          title: 'ep01',
          videoPath: p.join(root, 'ep01.mkv'),
        ),
      );
      await _seedJobFile(
        db,
        jobId: 'job-ep01',
        finalAbsolutePath: p.join(root, 'ep01.mkv'),
      );
      // 任务还在、库条目已被用户删掉：任务路径照样必须跟着走。
      await _seedJobFile(
        db,
        jobId: 'job-ep02',
        finalAbsolutePath: p.join(root, 'ep02.mkv'),
      );
      await _seedJobFile(db, jobId: 'job-other', finalAbsolutePath: elsewhere);
    });
    tearDown(() => db.close());

    test('改名单个文件：库行与对应任务行同步改写，其它任务不动', () async {
      final RelocateOutcome outcome = await service.renameFile(
        infoHash: 'abc',
        fileIndex: 0,
        currentRelativePath: 'ep01.mkv',
        newRelativePath: 'Show - 01.mkv',
        saveRoot: root,
      );
      expect(outcome.status, RelocateStatus.success);
      final String renamed = p.join(root, 'Show - 01.mkv');
      expect(await _bookPath(db, 'video/ep01'), renamed);
      expect(await _jobPath(db, 'job-ep01'), renamed);
      expect(await _jobPath(db, 'job-ep02'), p.join(root, 'ep02.mkv'));
      expect(await _jobPath(db, 'job-other'), elsewhere);
    });

    test('移动整个保存根：根下全部任务行重映射，根外的不动', () async {
      final String moved = p.join(p.rootPrefix(p.current), 'archive', 'Show');
      final RelocateOutcome outcome = await service.moveTorrent(
        infoHash: 'abc',
        currentSaveRoot: root,
        newSaveRoot: moved,
      );
      expect(outcome.status, RelocateStatus.success);
      expect(outcome.rowsMigrated, 1, reason: '返回值仍只计库行');
      expect(await _bookPath(db, 'video/ep01'), p.join(moved, 'ep01.mkv'));
      expect(await _jobPath(db, 'job-ep01'), p.join(moved, 'ep01.mkv'));
      expect(await _jobPath(db, 'job-ep02'), p.join(moved, 'ep02.mkv'));
      expect(await _jobPath(db, 'job-other'), elsewhere);
    });
  });

  group('数据根迁移：任务路径按搬移作用域 rebase', () {
    late Directory tmp;
    late Directory oldDocs;
    late Directory oldSupport;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fushi_jobpath_');
      oldDocs = Directory(p.join(tmp.path, 'Documents'))
        ..createSync(recursive: true);
      oldSupport = Directory(p.join(tmp.path, 'support'))
        ..createSync(recursive: true);
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('默认下载根（数据根内）下的任务视频与字幕被 rebase，外部下载根不动', () async {
      final String inside = p.join(
        oldDocs.path,
        'anime_downloads',
        'content',
        'Show',
        'ep01.mkv',
      );
      final String insideSub = p.setExtension(inside, '.ja.srt');
      final String outside = p.join(tmp.path, 'external', 'Show', 'ep02.mkv');
      final String outsideSub = p.setExtension(outside, '.ja.srt');

      final FushiDatabase seed = FushiDatabase(oldSupport.path);
      try {
        await _seedJobWithSubtitle(seed, 'job-in', inside, insideSub);
        await _seedJobWithSubtitle(seed, 'job-out', outside, outsideSub);
      } finally {
        await seed.close();
      }

      final String newDocs = p.join(tmp.path, 'newroot', 'Documents');
      await const DataRootMigrator().rebaseDatabasePathsForTesting(
        dbDirectory: oldSupport.path,
        oldDocumentsRoot: oldDocs.path,
        newDocumentsRoot: newDocs,
        newSupportRoot: oldSupport.path,
        documentsScopeEntries: AppPaths.fushiOwnedDocumentsEntries,
      );

      final FushiDatabase post = FushiDatabase(oldSupport.path);
      try {
        final String rebased = p.join(
          newDocs,
          'anime_downloads',
          'content',
          'Show',
          'ep01.mkv',
        );
        expect(await _jobPath(post, 'job-in'), rebased);
        expect(await _jobPath(post, 'job-out'), outside);
        final Map<String, VideoDownloadJobSubtitleRow> subs =
            <String, VideoDownloadJobSubtitleRow>{
              for (final VideoDownloadJobSubtitleRow row
                  in await post.select(post.videoDownloadJobSubtitles).get())
                row.jobId: row,
            };
        expect(subs['job-in']!.finalPath, p.setExtension(rebased, '.ja.srt'));
        expect(subs['job-in']!.stagedPath, p.setExtension(rebased, '.ja.srt'));
        expect(subs['job-out']!.finalPath, outsideSub);
        expect(subs['job-out']!.stagedPath, outsideSub);
      } finally {
        await post.close();
      }
    });
  });
}

Future<void> _seedJobWithSubtitle(
  FushiDatabase db,
  String jobId,
  String videoPath,
  String subtitlePath,
) async {
  final int fileId = await _seedJobFile(
    db,
    jobId: jobId,
    finalAbsolutePath: videoPath,
  );
  await db.upsertVideoDownloadJobSubtitle(
    VideoDownloadJobSubtitlesCompanion(
      subtitleId: Value<String>('$jobId:$fileId'),
      jobId: Value<String>(jobId),
      jobFileId: Value<int?>(fileId),
      provider: const Value<String>('auto'),
      stagedPath: Value<String?>(subtitlePath),
      finalPath: Value<String?>(subtitlePath),
      status: const Value<String>(VideoDownloadJobSubtitleStatus.placed),
      createdAt: const Value<int>(1),
      updatedAt: const Value<int>(1),
    ),
  );
}
