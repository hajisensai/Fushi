import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/engine_paths.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_provider.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_resolver.dart';
import 'package:fushi_engine/media/video/metadata/video_scrape_sweep_ledger.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/media/video/subtitle/subdl_client.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/download_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/server_subtitle_providers.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 下载管线的字幕来源跟着运行期的偏好走：服务端起来之后才写进来的 key（互联 / WebUI /
/// ctl 写的都是同一张 preferences 表），下一个任务的字幕阶段就用上；删掉 key 就不再用；
/// 正在跑的那一轮不受中途改动影响。走的是生产的 [buildServerSubtitleRegistry]（偏好 →
/// 凭据 → 门控），只把出网的 provider 换成记录调用的假实现。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerPrefs prefs;
  late ServerDownloadHost host;
  late int sourceId;
  late List<_RecordingSubtitleProvider> built;
  Completer<void>? searchGate;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_subs_live_');
    enginePaths = ServerPaths(p.join(tmp.path, 'data'));
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    built = <_RecordingSubtitleProvider>[];
    searchGate = null;
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    );
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    prefs = ServerPrefs(db);
    await prefs.warmUp();
    final Directory videos = Directory(p.join(tmp.path, 'videos'))
      ..createSync(recursive: true);
    sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Videos',
        mediaKind: 'video',
        rootPath: videos.path,
        createdAt: 1,
      ),
    );
    host = ServerDownloadHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: await ServerIdentity.loadOrCreate(prefs),
      scrape: ServerVideoScrape(
        db: db,
        prefs: prefs,
        config: () => config,
        ledger: VideoScrapeSweepLedger(),
        coordinatorFactory: (scrapeConfig) => VideoSourceScrapeCoordinator(
          database: db,
          config: scrapeConfig,
          registry: VideoMetadataProviderRegistry(
            const <VideoMetadataProvider>[],
          ),
        ),
      ),
      backendOverride: _IdleTorrentBackend(),
      pollInterval: const Duration(milliseconds: 20),
      // 生产装配（偏好 → 凭据 → 只装开着且有 key 的来源），只换掉出网的 provider；
      // 环境变量置空，凭据只来自偏好表。
      subtitleRegistryFactory: () => buildServerSubtitleRegistry(
        prefs,
        environment: const <String, String>{},
        providerFactory: (String id, SubsCredentials credentials) {
          final _RecordingSubtitleProvider provider =
              _RecordingSubtitleProvider(
                id,
                key: switch (id) {
                  'jimaku' => credentials.jimakuApiKey,
                  kSubdlSubtitleProviderId => credentials.subdlApiKey,
                  _ => credentials.openSubtitles.effectiveApiKey,
                },
                gate: () => searchGate?.future,
              );
          built.add(provider);
          return provider;
        },
      ),
    );
    await host.start();
  });

  tearDown(() async {
    final Completer<void>? gate = searchGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    await host.stop();
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 一个停在 subtitle 阶段、磁盘上已有一集整理好视频的任务。
  Future<String> seedSubtitleStageJob(String jobId) async {
    final Directory season = Directory(
      p.join(tmp.path, 'videos', 'Show (2026)', 'Season 01'),
    )..createSync(recursive: true);
    final File video = File(p.join(season.path, '$jobId - S01E02.mkv'))
      ..writeAsBytesSync(<int>[0, 1, 2, 3]);
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: p.basename(video.path),
        currentRelativePath: p.basename(video.path),
        targetRelativePath: Value<String?>(p.basename(video.path)),
        finalAbsolutePath: Value<String?>(video.path),
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(2),
        sizeBytes: const Value<int?>(4),
        status: const Value<String>(VideoDownloadJobFileStatus.organized),
        createdAt: now,
        updatedAt: now,
      ),
    );
    await db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: jobId,
        resourceProvider: 'nyaa:test',
        selectedResourceId: 'release-1',
        metadataProvider: const Value<String?>('anilist'),
        externalId: const Value<String?>('100'),
        mediaKind: VideoMetadataMediaKind.tv.name,
        discoveryCategory: Value<String?>(VideoDiscoveryCategory.anime.name),
        title: 'Show',
        year: const Value<int?>(2026),
        season: const Value<int?>(1),
        backendKind: 'embedded',
        fingerprint: 'fp',
        targetSourceId: Value<int?>(sourceId),
        organizationPolicy: const Value<String>('library'),
        subtitlePolicy: const Value<String>('bestEffort'),
        lifecycle: const Value<String>(VideoDownloadJobLifecycle.active),
        stage: const Value<String>(VideoDownloadJobStage.subtitle),
        createdAt: now,
        updatedAt: now,
      ),
    );
    return jobId;
  }

  /// 等任务离开 subtitle 阶段（字幕阶段跑完，或任务本身停了）。
  Future<void> waitPastSubtitleStage(String jobId) async {
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final VideoDownloadJobRow? row = await db.getVideoDownloadJob(jobId);
      if (row != null &&
          (row.stage != VideoDownloadJobStage.subtitle ||
              row.lifecycle != VideoDownloadJobLifecycle.active)) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    throw TimeoutException(
      'job $jobId stuck: ${await db.getVideoDownloadJob(jobId)}',
    );
  }

  List<_RecordingSubtitleProvider> searched() => <_RecordingSubtitleProvider>[
    for (final _RecordingSubtitleProvider provider in built)
      if (provider.searchCalls > 0) provider,
  ];

  test('启动后才写进偏好的 key：下一个任务的字幕阶段就用上，不用重启', () async {
    expect(host.subtitleProviderIds, isEmpty);
    await waitPastSubtitleStage(await seedSubtitleStageJob('job-before-key'));
    expect(searched(), isEmpty, reason: '还没有 key：字幕阶段跳过');

    await prefs.setPref(kJimakuApiKeyPref, 'key-written-at-runtime');
    expect(host.subtitleProviderIds, <String>['jimaku']);
    await waitPastSubtitleStage(await seedSubtitleStageJob('job-after-key'));
    expect(searched(), hasLength(1));
    expect(searched().single.id, 'jimaku');
    expect(searched().single.key, 'key-written-at-runtime');
    expect(searched().single.closed, isTrue, reason: '字幕阶段借的 registry 用完即关');

    // 换 key：下一轮用新 key。
    await prefs.setPref(kJimakuApiKeyPref, 'rotated-key');
    await waitPastSubtitleStage(await seedSubtitleStageJob('job-rotated-key'));
    expect(searched().map((_RecordingSubtitleProvider p) => p.key), <String>[
      'key-written-at-runtime',
      'rotated-key',
    ]);
  });

  test('删掉 key / 关掉开关：下一个任务不再用这家', () async {
    await prefs.setPref(kJimakuApiKeyPref, 'k');
    await prefs.setPref(kSubdlApiKeyPref, 's');
    expect(host.subtitleProviderIds, <String>[
      kSubdlSubtitleProviderId,
      'jimaku',
    ]);

    await prefs.setPref(kJimakuApiKeyPref, '');
    expect(host.subtitleProviderIds, <String>[kSubdlSubtitleProviderId]);
    await waitPastSubtitleStage(await seedSubtitleStageJob('job-no-jimaku'));
    expect(searched().map((_RecordingSubtitleProvider p) => p.id), <String>[
      kSubdlSubtitleProviderId,
    ]);

    await prefs.setPref(kSubdlEnabledPref, false);
    expect(host.subtitleProviderIds, isEmpty);
    await waitPastSubtitleStage(await seedSubtitleStageJob('job-none'));
    expect(searched(), hasLength(1), reason: '一家都没有：字幕阶段跳过，不搜');
  });

  test('在飞的字幕阶段不受中途改动影响：用到结束才关', () async {
    await prefs.setPref(kJimakuApiKeyPref, 'k');
    searchGate = Completer<void>();
    final String jobId = await seedSubtitleStageJob('job-in-flight');
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (searched().isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final _RecordingSubtitleProvider inFlight = searched().single;

    await prefs.setPref(kJimakuApiKeyPref, '');
    expect(host.subtitleProviderIds, isEmpty, reason: '新的一轮已经看到删除');
    expect(inFlight.closed, isFalse, reason: '这一轮还拿着它，不能被拔掉');

    searchGate!.complete();
    await waitPastSubtitleStage(jobId);
    expect(inFlight.closed, isTrue);
    final List<VideoDownloadJobSubtitleRow> rows = await db
        .getVideoDownloadJobSubtitles(jobId);
    expect(
      rows.single.error,
      contains('no-result'),
      reason: '这一轮按借到的来源正常跑完（假来源搜不到 → 记暂无字幕）',
    );
  });
}

/// 记录调用、不出网的字幕来源；搜索永远空结果。
class _RecordingSubtitleProvider implements VideoSubtitleProvider {
  _RecordingSubtitleProvider(this.id, {required this.key, required this.gate});

  @override
  final String id;
  final String key;
  final Future<void>? Function() gate;
  int searchCalls = 0;
  bool closed = false;

  @override
  int get priority => 0;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    searchCalls += 1;
    await gate();
    if (closed) throw StateError('$id searched after close');
    return ProviderBatchResult<VideoSubtitleCandidate>.failure(
      ExternalProviderFailure(
        providerId: id,
        operation: 'search',
        kind: ExternalProviderFailureKind.notFound,
        message: '$id no-result',
      ),
    );
  }

  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) =>
      throw UnimplementedError();

  @override
  void close() => closed = true;
}

/// 字幕阶段用不到后端；只让管线认为后端已配好。
class _IdleTorrentBackend implements TorrentBackend {
  @override
  Future<bool> addTorrent(
    String magnetOrUrl, {
    required String category,
    String? savePath,
    bool sequential = false,
    bool firstLastPiecePrio = false,
  }) async => true;

  @override
  Future<List<TorrentSnapshot>> listTorrents({String? category}) async =>
      const <TorrentSnapshot>[];

  @override
  Future<List<TorrentFileEntry>> listFiles(String torrentId) async =>
      const <TorrentFileEntry>[];

  @override
  Future<bool> prepareCategory(String category) async => true;

  @override
  Future<String?> probeConnection() async => 'fake';

  @override
  Future<TorrentStorageResult> renameFile(
    String torrentId,
    int fileIndex,
    String newPath,
  ) async => TorrentStorageResult(ok: true, path: newPath);

  @override
  Future<TorrentStorageResult> moveStorage(
    String torrentId,
    String newSavePath,
  ) async => TorrentStorageResult(ok: true, path: newSavePath);

  @override
  void close() {}
}
