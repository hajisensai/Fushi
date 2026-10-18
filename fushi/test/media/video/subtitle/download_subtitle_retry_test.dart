/// 下载后缺字幕的定期重试（[retryUnavailableDownloadSubtitles]）。
///
/// 回归场景：连载番片源当晚下完，Jimaku 字幕一两天后才上传——流水线当时记了
/// `unavailable` 就再也没人回头找。这里钉死：哪些行会被重试（窗口 / 退避 / 只认
/// 自动选片 / 只认已完成任务），以及每种补字幕结局怎样改写这一行。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/subtitle/download_subtitle_retry.dart';
import 'package:fushi/src/media/video/subtitle/library_video_subtitle_backfill.dart'
    show subtitleSourceBlocksBackfill;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show VideoSubtitleBackfillReport;
import 'package:path/path.dart' as p;

void main() {
  late FushiDatabase db;
  late Directory tmp;
  final DateTime now = DateTime.utc(2026, 10, 17, 12);
  final int nowMs = now.millisecondsSinceEpoch;
  const int hour = 60 * 60 * 1000;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    tmp = await Directory.systemTemp.createTemp('fushi-subtitle-retry-');
  });
  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  /// 一集：已完成（或指定生命周期）的任务 + 视频文件行 + 字幕行 +（可选）库内视频。
  /// 返回字幕行 id。
  Future<String> seedEpisode(
    String name, {
    String lifecycle = VideoDownloadJobLifecycle.completed,
    String status = VideoDownloadJobSubtitleStatus.unavailable,
    String? selectedSubtitleId,
    int createdAgo = 24 * hour,
    int updatedAgo = 7 * hour,
    bool inLibrary = true,
    String? bookSubtitleSource,
  }) async {
    final File video = File(p.join(tmp.path, '$name.mkv'))
      ..writeAsBytesSync(<int>[1, 2, 3]);
    final String jobId = 'job-$name';
    await db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: jobId,
        resourceProvider: 'nyaa:test',
        selectedResourceId: 'r-$name',
        mediaKind: 'tv',
        title: 'Show',
        backendKind: 'embedded',
        fingerprint: 'fp',
        lifecycle: Value<String>(lifecycle),
        stage: const Value<String>(VideoDownloadJobStage.scrape),
        createdAt: nowMs - createdAgo,
        updatedAt: nowMs - createdAgo,
      ),
    );
    await db.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: '$name.mkv',
        currentRelativePath: '$name.mkv',
        finalAbsolutePath: Value<String?>(video.path),
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(3),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: nowMs - createdAgo,
        updatedAt: nowMs - createdAgo,
      ),
    );
    final int fileId = (await db.getVideoDownloadJobFiles(jobId)).single.id;
    final String subtitleId = '$jobId:$fileId';
    await db.upsertVideoDownloadJobSubtitle(
      VideoDownloadJobSubtitlesCompanion(
        subtitleId: Value<String>(subtitleId),
        jobId: Value<String>(jobId),
        jobFileId: Value<int?>(fileId),
        provider: const Value<String>('auto'),
        selectedSubtitleId: Value<String?>(selectedSubtitleId),
        season: const Value<int?>(1),
        episode: const Value<int?>(3),
        status: Value<String>(status),
        error: const Value<String?>('OpenSubtitles returned HTTP 400'),
        createdAt: Value<int>(nowMs - createdAgo),
        updatedAt: Value<int>(nowMs - updatedAgo),
      ),
    );
    if (inLibrary) {
      await db.upsertVideoBook(
        VideoBooksCompanion.insert(
          bookUid: 'video/$name',
          title: name,
          videoPath: video.path,
          subtitleSource: Value<String?>(bookSubtitleSource),
        ),
      );
    }
    return subtitleId;
  }

  Future<String?> bookSource(String name) async =>
      (await db.getVideoBookByBookUid('video/$name'))!.subtitleSource;

  Future<VideoDownloadJobSubtitleRow> row(String name) async =>
      (await db.getVideoDownloadJobSubtitles('job-$name')).single;

  test('只重试窗口内、退避到期、自动选片、任务已完成的 unavailable 行', () async {
    await seedEpisode('due');
    await seedEpisode('recent', updatedAgo: 1 * hour);
    await seedEpisode('stale', createdAgo: 20 * 24 * hour);
    await seedEpisode('manual', selectedSubtitleId: 'jimaku:1');
    await seedEpisode(
      'attention',
      lifecycle: VideoDownloadJobLifecycle.needsAttention,
    );
    await seedEpisode('placed', status: VideoDownloadJobSubtitleStatus.placed);

    final List<String> asked = <String>[];
    final DownloadSubtitleRetryReport report =
        await retryUnavailableDownloadSubtitles(
          database: db,
          backfill: (String videoId) async {
            asked.add(videoId);
            return const VideoSubtitleBackfillReport(outcome: 'noCandidate');
          },
          now: now,
        );

    expect(asked, <String>['video/due']);
    expect(report.attempted, 1);
    expect((await row('recent')).updatedAt, nowMs - 1 * hour, reason: '没到期不碰');
  });

  test('装上了 → placed，记下落盘路径与语言', () async {
    await seedEpisode('ep3');
    final String sidecar = p.join(tmp.path, 'ep3.ja.srt');

    final DownloadSubtitleRetryReport report =
        await retryUnavailableDownloadSubtitles(
          database: db,
          backfill: (String videoId) async => VideoSubtitleBackfillReport(
            outcome: 'installed',
            installedPath: sidecar,
            language: 'ja',
          ),
          now: now,
        );

    final VideoDownloadJobSubtitleRow after = await row('ep3');
    expect(report.installed, 1);
    expect(after.status, VideoDownloadJobSubtitleStatus.placed);
    expect(after.finalPath, sidecar);
    expect(after.language, 'ja');
    expect(after.error, isNull);
  });

  test('装上后主字幕源：空 / 内嵌轨选择改指新 sidecar；off: 与外挂路径不动', () async {
    await seedEpisode('none');
    // E03 实况：Crunchyroll 片源只有多语内嵌轨，库里存着英文的 embedded:0。
    await seedEpisode('embedded', bookSubtitleSource: 'embedded:0');
    await seedEpisode('off', bookSubtitleSource: 'off:');
    final String handPicked = p.join(tmp.path, 'hand.en.srt');
    await seedEpisode('file', bookSubtitleSource: handPicked);

    await retryUnavailableDownloadSubtitles(
      database: db,
      backfill: (String videoId) async => VideoSubtitleBackfillReport(
        outcome: 'installed',
        installedPath: p.join(tmp.path, '${videoId.substring(6)}.ja.srt'),
        language: 'ja',
      ),
      now: now,
    );

    expect(await bookSource('none'), p.join(tmp.path, 'none.ja.srt'));
    expect(await bookSource('embedded'), p.join(tmp.path, 'embedded.ja.srt'));
    expect(await bookSource('off'), 'off:', reason: '用户显式关闭字幕');
    expect(await bookSource('file'), handPicked, reason: '用户选的外挂文件');
  });

  test('subtitleSourceBlocksBackfill：空不挡，off: / 路径挡，内嵌轨按开关', () {
    expect(subtitleSourceBlocksBackfill(null), isFalse);
    expect(subtitleSourceBlocksBackfill('  '), isFalse);
    expect(subtitleSourceBlocksBackfill('off:'), isTrue);
    expect(
      subtitleSourceBlocksBackfill('off:', embeddedSelectionBlocks: false),
      isTrue,
    );
    expect(subtitleSourceBlocksBackfill(r'D:\v\a.ja.srt'), isTrue);
    expect(subtitleSourceBlocksBackfill('embedded:0'), isTrue);
    expect(
      subtitleSourceBlocksBackfill(
        'embedded:0',
        embeddedSelectionBlocks: false,
      ),
      isFalse,
    );
  });

  test('仍没有候选 → 留在 unavailable，刷新尝试时刻与原因，下一轮退避内不再试', () async {
    await seedEpisode('ep3');
    Future<VideoSubtitleBackfillReport?> none(String _) async =>
        const VideoSubtitleBackfillReport(
          outcome: 'noCandidate',
          detail: 'Jimaku has no file for episode 3 yet',
        );

    await retryUnavailableDownloadSubtitles(
      database: db,
      backfill: none,
      now: now,
    );
    final VideoDownloadJobSubtitleRow after = await row('ep3');
    expect(after.status, VideoDownloadJobSubtitleStatus.unavailable);
    expect(after.updatedAt, nowMs);
    expect(after.error, 'Jimaku has no file for episode 3 yet');

    int calls = 0;
    await retryUnavailableDownloadSubtitles(
      database: db,
      backfill: (String id) {
        calls++;
        return none(id);
      },
      now: now.add(const Duration(hours: 1)),
    );
    expect(calls, 0, reason: '6 小时退避内不重搜');

    await retryUnavailableDownloadSubtitles(
      database: db,
      backfill: (String id) {
        calls++;
        return none(id);
      },
      now: now.add(kDownloadSubtitleRetryInterval),
    );
    expect(calls, 1, reason: '退避到期再试');
  });

  test('视频已离库 / 已有字幕 → skipped，不再重试', () async {
    await seedEpisode('gone', inLibrary: false);
    await seedEpisode('hand');

    final List<String> asked = <String>[];
    final DownloadSubtitleRetryReport report =
        await retryUnavailableDownloadSubtitles(
          database: db,
          backfill: (String videoId) async {
            asked.add(videoId);
            return const VideoSubtitleBackfillReport(
              outcome: 'alreadyHasSubtitle',
            );
          },
          now: now,
        );

    expect(asked, <String>['video/hand'], reason: '不在库里的视频不去搜');
    expect(report.settled, 2);
    expect((await row('gone')).status, VideoDownloadJobSubtitleStatus.skipped);
    expect((await row('hand')).status, VideoDownloadJobSubtitleStatus.skipped);
  });
}
