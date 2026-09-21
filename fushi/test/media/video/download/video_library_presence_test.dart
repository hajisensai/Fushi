import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:sqlite3/common.dart' show CommonDatabase;

import 'package:fushi_engine/media/video/download/video_library_presence.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';

const int _nowAt = 1000;
const String _provider = 'anilist';
const String _externalId = 'media-presence';

Future<FushiDatabase> _openDatabase() async {
  final FushiDatabase database = FushiDatabase.forTesting(
    NativeDatabase.memory(
      setup: (CommonDatabase raw) => raw.execute('PRAGMA foreign_keys = ON'),
    ),
  );
  addTearDown(database.close);
  return database;
}

Future<int> _insertVideoSource(FushiDatabase database) =>
    database.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Managed videos',
        mediaKind: 'video',
        rootPath: r'D:\Videos',
        createdAt: _nowAt,
      ),
    );

/// 造一条同身份的下载任务并直接改 lifecycle：生产里由流水线/用户操作写，这里
/// 只关心判据怎么读它。
Future<void> _insertJob(
  FushiDatabase database, {
  required String jobId,
  required String lifecycle,
  String provider = _provider,
  String externalId = _externalId,
}) async {
  await database.upsertVideoDownloadJob(
    VideoDownloadJobsCompanion.insert(
      jobId: jobId,
      resourceProvider: 'nyaa',
      selectedResourceId: 'resource-$jobId',
      metadataProvider: Value<String?>(provider),
      externalId: Value<String?>(externalId),
      mediaKind: 'tv',
      title: 'Example Show',
      backendKind: 'embedded',
      backendProfileId: const Value<String?>('embedded'),
      fingerprint: 'backend-fingerprint',
      createdAt: _nowAt,
      updatedAt: _nowAt,
    ),
  );
  await database.customStatement(
    'UPDATE video_download_jobs SET lifecycle = ? WHERE job_id = ?',
    <Object?>[lifecycle, jobId],
  );
}

Future<void> _insertJobFile(
  FushiDatabase database, {
  required String jobId,
  required int season,
  required int episode,
  String status = VideoDownloadJobFileStatus.downloaded,
}) =>
    database.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        originalRelativePath: 'Example.S0${season}E0$episode.mkv',
        currentRelativePath: 'Example.S0${season}E0$episode.mkv',
        kind: const Value<String>('video'),
        season: Value<int?>(season),
        episode: Value<int?>(episode),
        status: Value<String>(status),
        createdAt: _nowAt,
        updatedAt: _nowAt,
      ),
    );

/// 建作品 + provider 身份 + 合集，并把给定文件名的视频条目挂进合集。
Future<({int workId, int collectionId})> _insertLibraryWork(
  FushiDatabase database, {
  required List<String> videoFileNames,
  String provider = _provider,
  String externalId = _externalId,
}) async {
  final int sourceId = await _insertVideoSource(database);
  final int collectionId = await database.createMediaCollection(
    'Example Show',
    collectionType: 'playlist',
  );
  for (final String fileName in videoFileNames) {
    final String bookUid = 'video/${fileName.toLowerCase()}';
    await database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: Value<String>(bookUid),
        title: Value<String>(fileName),
        videoPath: Value<String>('D:\\Videos\\$fileName'),
        sourceId: Value<int?>(sourceId),
      ),
    );
    await database.addToCollection(collectionId, MediaKind.video, bookUid);
  }
  final int workId = await database.upsertVideoMetadataWork(
    VideoMetadataWorksCompanion.insert(
      collectionId: Value<int?>(collectionId),
      mediaType: 'tv',
      title: 'Example Show',
      updatedAt: _nowAt,
    ),
  );
  await database.replaceVideoMetadataProviderIdentities(
    workId: workId,
    identities: <VideoMetadataProviderIdentitiesCompanion>[
      VideoMetadataProviderIdentitiesCompanion.insert(
        identityKey: 'work:$workId:$provider',
        provider: provider,
        externalId: externalId,
        isPrimary: const Value<bool>(true),
        updatedAt: _nowAt,
      ),
    ],
  );
  return (workId: workId, collectionId: collectionId);
}

Future<VideoLibraryPresence> _resolve(
  FushiDatabase database, {
  String provider = _provider,
  String externalId = _externalId,
  VideoMetadataMediaKind mediaKind = VideoMetadataMediaKind.tv,
}) =>
    resolveVideoLibraryPresence(
      database,
      metadataProvider: provider,
      externalId: externalId,
      mediaKind: mediaKind,
    );

void main() {
  test('videoEpisodeKey pads season and episode to two digits', () {
    expect(videoEpisodeKey(1, 5), 'S01E05');
    expect(videoEpisodeKey(12, 103), 'S12E103');
  });

  test('none has no episodes, no library membership and no highest episode',
      () {
    expect(VideoLibraryPresence.none.managedEpisodeKeys, isEmpty);
    expect(VideoLibraryPresence.none.inLibrary, isFalse);
    expect(VideoLibraryPresence.none.highestEpisode, isNull);
    expect(VideoLibraryPresence.none.workId, isNull);
  });

  test('highestEpisode takes the largest episode number across keys', () {
    const VideoLibraryPresence presence = VideoLibraryPresence(
      managedEpisodeKeys: <String>{'S01E02', 'S01E11', 'S02E03'},
    );
    expect(presence.highestEpisode, 11);
  });

  test('only files of active / completed jobs count as managed', () async {
    final FushiDatabase database = await _openDatabase();
    for (final (String jobId, String lifecycle, int episode)
        in <(String, String, int)>[
      ('job-active', VideoDownloadJobLifecycle.active, 1),
      ('job-completed', VideoDownloadJobLifecycle.completed, 2),
      ('job-cancelled', VideoDownloadJobLifecycle.cancelled, 3),
      ('job-failed', VideoDownloadJobLifecycle.failed, 4),
      ('job-attention', VideoDownloadJobLifecycle.needsAttention, 5),
    ]) {
      await _insertJob(database, jobId: jobId, lifecycle: lifecycle);
      await _insertJobFile(
        database,
        jobId: jobId,
        season: 1,
        episode: episode,
      );
    }

    final VideoLibraryPresence presence = await _resolve(database);

    expect(presence.managedEpisodeKeys, <String>{'S01E01', 'S01E02'},
        reason: 'cancelled / failed / needsAttention 的任务不算「文件有人管」');
    expect(presence.inLibrary, isFalse, reason: '只有任务、没有作品入库');
    expect(presence.workId, isNull);
    expect(presence.highestEpisode, 2);
  });

  test('failed / skipped files of an active job do not count', () async {
    final FushiDatabase database = await _openDatabase();
    await _insertJob(
      database,
      jobId: 'job-1',
      lifecycle: VideoDownloadJobLifecycle.active,
    );
    await _insertJobFile(database, jobId: 'job-1', season: 1, episode: 1);
    await _insertJobFile(
      database,
      jobId: 'job-1',
      season: 1,
      episode: 2,
      status: VideoDownloadJobFileStatus.failed,
    );
    await _insertJobFile(
      database,
      jobId: 'job-1',
      season: 1,
      episode: 3,
      status: VideoDownloadJobFileStatus.skipped,
    );
    await _insertJobFile(
      database,
      jobId: 'job-1',
      season: 1,
      episode: 4,
      status: VideoDownloadJobFileStatus.pending,
    );

    final VideoLibraryPresence presence = await _resolve(database);

    expect(presence.managedEpisodeKeys, <String>{'S01E01', 'S01E04'});
  });

  test('jobs of another identity are ignored', () async {
    final FushiDatabase database = await _openDatabase();
    await _insertJob(
      database,
      jobId: 'job-other',
      lifecycle: VideoDownloadJobLifecycle.completed,
      externalId: 'media-other',
    );
    await _insertJobFile(database, jobId: 'job-other', season: 1, episode: 1);

    final VideoLibraryPresence presence = await _resolve(database);

    expect(presence.managedEpisodeKeys, isEmpty);
  });

  test('library collection episodes are parsed from file names', () async {
    final FushiDatabase database = await _openDatabase();
    final ({int workId, int collectionId}) ids = await _insertLibraryWork(
      database,
      videoFileNames: <String>[
        'Example.S03E02.mkv',
        '[Group] Example Show - 07 [1080p].mkv',
        'Example.Extras.mkv',
      ],
    );

    final VideoLibraryPresence presence = await _resolve(database);

    expect(presence.inLibrary, isTrue);
    expect(presence.workId, ids.workId);
    expect(presence.collectionId, ids.collectionId);
    expect(presence.managedEpisodeKeys, <String>{'S03E02', 'S01E07'},
        reason: '无季号的文件名默认 S01；解析不出集号的条目不计');
    expect(presence.highestEpisode, 7);
  });

  test('job files and library episodes are merged into one set', () async {
    final FushiDatabase database = await _openDatabase();
    await _insertLibraryWork(
      database,
      videoFileNames: <String>['Example.S01E01.mkv'],
    );
    await _insertJob(
      database,
      jobId: 'job-1',
      lifecycle: VideoDownloadJobLifecycle.active,
    );
    await _insertJobFile(database, jobId: 'job-1', season: 1, episode: 2);

    final VideoLibraryPresence presence = await _resolve(database);

    expect(presence.managedEpisodeKeys, <String>{'S01E01', 'S01E02'});
    expect(presence.inLibrary, isTrue);
    expect(presence.highestEpisode, 2);
  });

  test('a work bound to a single book reports workId but not inLibrary',
      () async {
    final FushiDatabase database = await _openDatabase();
    final int sourceId = await _insertVideoSource(database);
    // 作品要么挂合集要么挂单本；单本作品没有合集，集号无从解析。
    await database.upsertVideoBook(
      VideoBooksCompanion(
        bookUid: const Value<String>('video/example-single'),
        title: const Value<String>('Example Show'),
        videoPath: const Value<String>(r'D:\Videos\Example.S01E01.mkv'),
        sourceId: Value<int?>(sourceId),
      ),
    );
    final int workId = await database.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: const Value<String?>('video/example-single'),
        mediaType: 'tv',
        title: 'Example Show',
        updatedAt: _nowAt,
      ),
    );
    await database.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:$_provider',
          provider: _provider,
          externalId: _externalId,
          isPrimary: const Value<bool>(true),
          updatedAt: _nowAt,
        ),
      ],
    );

    final VideoLibraryPresence presence = await _resolve(database);

    expect(presence.workId, workId);
    expect(presence.collectionId, isNull);
    // 单本作品也是「已刮到」：inLibrary 看作品身份，不看合集归属。
    expect(presence.inLibrary, isTrue);
    expect(presence.managedEpisodeKeys, isEmpty);
  });

  test('movies keep the work identity but never carry episode keys', () async {
    final FushiDatabase database = await _openDatabase();
    await _insertLibraryWork(
      database,
      videoFileNames: <String>['Example.S01E01.mkv'],
    );
    await _insertJob(
      database,
      jobId: 'job-1',
      lifecycle: VideoDownloadJobLifecycle.completed,
    );
    await _insertJobFile(database, jobId: 'job-1', season: 1, episode: 2);

    final VideoLibraryPresence presence = await _resolve(
      database,
      mediaKind: VideoMetadataMediaKind.movie,
    );

    // 剧场版没有集可扫，但作品身份照查：AI 下载流程靠 inLibrary 拦重复下载。
    expect(presence.managedEpisodeKeys, isEmpty);
    expect(presence.workId, isNotNull);
    expect(presence.inLibrary, isTrue);
  });

  test('highestEpisodeOf is per season while highestEpisode spans seasons', () {
    const VideoLibraryPresence presence = VideoLibraryPresence(
      managedEpisodeKeys: <String>{'S01E24', 'S02E03', 'S02E11'},
    );
    expect(presence.highestEpisode, 24);
    expect(presence.highestEpisodeOf(1), 24);
    expect(presence.highestEpisodeOf(2), 11);
    expect(presence.highestEpisodeOf(3), isNull);
  });

  test('blank provider or external id resolves to none', () async {
    final FushiDatabase database = await _openDatabase();
    await _insertJob(
      database,
      jobId: 'job-1',
      lifecycle: VideoDownloadJobLifecycle.completed,
    );
    await _insertJobFile(database, jobId: 'job-1', season: 1, episode: 1);

    expect(
      await _resolve(database, provider: '  '),
      same(VideoLibraryPresence.none),
    );
    expect(
      await _resolve(database, externalId: ''),
      same(VideoLibraryPresence.none),
    );
  });

  test('provider case and surrounding whitespace are normalized', () async {
    final FushiDatabase database = await _openDatabase();
    await _insertLibraryWork(
      database,
      videoFileNames: <String>['Example.S01E01.mkv'],
    );
    await _insertJob(
      database,
      jobId: 'job-1',
      lifecycle: VideoDownloadJobLifecycle.active,
      provider: 'AniList ',
      externalId: ' $_externalId ',
    );
    await _insertJobFile(database, jobId: 'job-1', season: 1, episode: 2);

    final VideoLibraryPresence presence = await _resolve(
      database,
      provider: ' AniList',
      externalId: ' $_externalId',
    );

    expect(presence.managedEpisodeKeys, <String>{'S01E01', 'S01E02'},
        reason: '任务扫描与作品身份查询都用归一后的 provider / externalId');
    expect(presence.inLibrary, isTrue);
  });
}
