// 下载内容改名 / 移动、数据根迁移之后，下载任务表必须与库里
// `video_books` 一起改写。
//
// 任务与库行之间没有 id 级外键，纽带全靠路径：`final_absolute_path` 与
// `video_path` 相等（下载后补抓字幕 download_subtitle_retry.dart、库侧删除反查任务
// video_download_pipeline_service.dart `_jobFilesMatching` 全靠它），任务行的
// `observed_save_path` + 文件行的 `current_relative_path` 拼出任务删除 / 打开位置
// 用的路径（BUG-3540）。另外只改引擎真实搬动的文件：不在种子里的字幕 sidecar
// 原地不动，库里的字幕列也不许被改到一个没有文件的位置（BUG-3538）。

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/download_relocate_service.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/storage/data_root_migrator.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/download/video_download_path_mapping.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:path/path.dart' as p;

/// 只实现改名 / 移动 / 列文件三条路径的后端：恒成功。
class _OkBackend implements TorrentBackend {
  _OkBackend(this.files);

  final List<TorrentFileEntry> files;

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
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async => files;

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<int> _seedJobFile(
  FushiDatabase db, {
  required String jobId,
  required String finalAbsolutePath,
  String? torrentHash,
  String? observedSavePath,
  String? currentRelativePath,
  int backendFileIndex = 0,
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
      torrentHash: Value<String?>(torrentHash),
      backendTaskId: Value<String?>(torrentHash),
      observedSavePath: Value<String?>(observedSavePath),
      lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
      stage: const Value<String>(VideoDownloadJobStage.scrape),
      createdAt: 1,
      updatedAt: 1,
    ),
  );
  await db.upsertVideoDownloadJobFile(
    VideoDownloadJobFilesCompanion.insert(
      jobId: jobId,
      backendFileIndex: Value<int?>(backendFileIndex),
      originalRelativePath:
          currentRelativePath ?? p.basename(finalAbsolutePath),
      currentRelativePath: currentRelativePath ?? p.basename(finalAbsolutePath),
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

Future<VideoBookRow> _book(FushiDatabase db, String uid) async =>
    (await db.allVideoBooks()).firstWhere((VideoBookRow r) => r.bookUid == uid);

void main() {
  group('改名 / 移动：DownloadRelocateService → applyDownloadRelocation', () {
    late Directory tmp;
    late FushiDatabase db;
    late String root;
    late String elsewhere;

    DownloadRelocateService serviceFor(List<TorrentFileEntry> files) =>
        DownloadRelocateService(
          backendFactory: () => _OkBackend(files),
          pathMappings: () async => const <VideoDownloadPathMapping>[],
          applyRelocation: VideoBookRepository(db).applyDownloadRelocation,
        );

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('fushi_jobreloc_');
      // 内置引擎 / 同机后端：save_path 就是本机目录（真实存在 → 同机映射成立）。
      root = p.join(tmp.path, 'dl');
      Directory(p.join(root, 'Show')).createSync(recursive: true);
      elsewhere = p.join(tmp.path, 'other', 'x.mkv');
      db = FushiDatabase.forTesting(NativeDatabase.memory());
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/ep01',
          title: 'ep01',
          videoPath: p.join(root, 'Show', 'ep01.mkv'),
          // Fushi 下载后放在视频旁的字幕：不在种子里，引擎不搬。
          subtitleSource: Value<String?>(p.join(root, 'Show', 'ep01.zh.srt')),
          // 种子里自带的字幕：引擎一起搬。
          secondarySubtitleSource: Value<String?>(
            p.join(root, 'Show', 'ep01.ja.ass'),
          ),
        ),
      );
      await _seedJobFile(
        db,
        jobId: 'job-ep01',
        finalAbsolutePath: p.join(root, 'Show', 'ep01.mkv'),
        torrentHash: 'abc',
        observedSavePath: root,
        currentRelativePath: 'Show/ep01.mkv',
      );
      // 任务还在、库条目已被用户删掉：任务路径照样必须跟着走。
      await _seedJobFile(
        db,
        jobId: 'job-ep02',
        finalAbsolutePath: p.join(root, 'Show', 'ep02.mkv'),
        torrentHash: 'abc',
        observedSavePath: root,
        currentRelativePath: 'Show/ep02.mkv',
        backendFileIndex: 1,
      );
      await _seedJobFile(
        db,
        jobId: 'job-other',
        finalAbsolutePath: elsewhere,
        torrentHash: 'def',
        observedSavePath: p.dirname(elsewhere),
      );
    });
    tearDown(() async {
      await db.close();
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('改名单个文件：库行、任务文件路径与种子内相对路径同步改写，其它不动', () async {
      final RelocateOutcome outcome =
          await serviceFor(const <TorrentFileEntry>[]).renameFile(
            infoHash: 'abc',
            fileIndex: 0,
            currentRelativePath: 'Show/ep01.mkv',
            newRelativePath: 'Show/Show - 01.mkv',
            backendSaveRoot: root,
          );
      expect(outcome.status, RelocateStatus.success);
      final String renamed = p.join(root, 'Show', 'Show - 01.mkv');
      final VideoBookRow book = await _book(db, 'video/ep01');
      expect(book.videoPath, renamed);
      expect(
        book.subtitleSource,
        p.join(root, 'Show', 'ep01.zh.srt'),
        reason: '改名只动那一个文件，字幕原地不动',
      );
      expect(await _jobPath(db, 'job-ep01'), renamed);
      expect(
        (await db.getVideoDownloadJobFiles(
          'job-ep01',
        )).single.currentRelativePath,
        'Show/Show - 01.mkv',
        reason: 'BUG-3540：任务删除 / 打开位置按 save_path + 当前相对路径拼路径',
      );
      expect(
        (await db.getVideoDownloadJobFiles(
          'job-ep02',
        )).single.currentRelativePath,
        'Show/ep02.mkv',
      );
      expect(await _jobPath(db, 'job-ep02'), p.join(root, 'Show', 'ep02.mkv'));
      expect(await _jobPath(db, 'job-other'), elsewhere);
    });

    test('移动整个种子：只改种子自己的文件，sidecar 字幕不动，任务保存位置跟着换', () async {
      final String moved = p.join(tmp.path, 'archive');
      final RelocateOutcome outcome =
          await serviceFor(<TorrentFileEntry>[
            const TorrentFileEntry(
              name: 'Show/ep01.mkv',
              size: 1,
              progress: 1,
              index: 0,
            ),
            const TorrentFileEntry(
              name: 'Show/ep02.mkv',
              size: 1,
              progress: 1,
              index: 1,
            ),
            const TorrentFileEntry(
              name: 'Show/ep01.ja.ass',
              size: 1,
              progress: 1,
              index: 2,
            ),
          ]).moveTorrent(
            infoHash: 'abc',
            backendSaveRoot: root,
            newLocalSaveRoot: moved,
          );
      expect(outcome.status, RelocateStatus.success);
      expect(outcome.rowsMigrated, 1, reason: '返回值仍只计库行');

      final VideoBookRow book = await _book(db, 'video/ep01');
      expect(book.videoPath, p.join(moved, 'Show', 'ep01.mkv'));
      expect(
        book.subtitleSource,
        p.join(root, 'Show', 'ep01.zh.srt'),
        reason: 'BUG-3538：sidecar 不在种子里、引擎不搬，库不能改到没有文件的新位置',
      );
      expect(
        book.secondarySubtitleSource,
        p.join(moved, 'Show', 'ep01.ja.ass'),
        reason: '种子自带的字幕被引擎一起搬走，库跟着改',
      );

      expect(await _jobPath(db, 'job-ep01'), p.join(moved, 'Show', 'ep01.mkv'));
      expect(await _jobPath(db, 'job-ep02'), p.join(moved, 'Show', 'ep02.mkv'));
      expect(await _jobPath(db, 'job-other'), elsewhere);

      final String? expectedRemote = videoDownloadLocalToRemote(
        effectiveVideoDownloadPathMappings(
          const <VideoDownloadPathMapping>[],
          sameMachineAnchors: <String?>[root],
        ),
        moved,
      );
      for (final String jobId in <String>['job-ep01', 'job-ep02']) {
        expect(
          (await db.getVideoDownloadJob(jobId))!.observedSavePath,
          expectedRemote,
          reason: 'BUG-3540：任务记的后端保存位置必须换成移动后的位置',
        );
      }
      expect(
        (await db.getVideoDownloadJob('job-other'))!.observedSavePath,
        p.dirname(elsewhere),
      );
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
