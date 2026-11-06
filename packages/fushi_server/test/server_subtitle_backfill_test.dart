import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart' show kAiCustomPresetId;
import 'package:fushi_engine/ai/ai_video_search_assistant.dart'
    show AiClientFactory;
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/jimaku_subtitle_provider.dart'
    show JimakuVideoSubtitleProvider;
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart'
    show VideoScrapedWorkNotice;
import 'package:fushi_engine/media/video/metadata/video_source_work_planner.dart'
    show VideoSourceScrapeWork;
import 'package:fushi_engine/media/video/subtitle/download_subtitle_retry.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/server_subtitle_backfill.dart';
import 'package:fushi_server/src/server_subtitle_providers.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 服务端补字幕的三条自动 / AI 接线（server_subtitle_backfill.dart）：
/// - 刮完下载来的作品 → 补字幕（只认下载任务导入过的文件，开关 / 来源闸门）；
/// - 下载后缺字幕的定期重试（同一开关；一轮真去补、把任务字幕行标 placed）；
/// - AI 重排候选只在配置了 `ai:` 段时发请求。
///
/// 全程不联网：字幕来源是假 provider，AI 走 MockClient。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerPrefs prefs;
  late _FakeSubtitleProvider provider;
  late int registriesBuilt;
  final DateTime now = DateTime.utc(2026, 11, 5, 12);
  final int nowMs = now.millisecondsSinceEpoch;
  const int hour = 60 * 60 * 1000;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_server_sub_backfill_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = ServerPrefs(db);
    // 假视频没有内嵌字幕轨，关掉对齐免得去跑 ffmpeg。
    await prefs.setPref(kSubtitleReferenceSyncEnabledPref, false);
    provider = _FakeSubtitleProvider();
    registriesBuilt = 0;
  });

  tearDown(() async {
    await db.close();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  ServerSubtitleBackfill backfill({
    ServerAiConfig? ai,
    AiClientFactory? aiClientFactory,
    bool noProviders = false,
  }) => ServerSubtitleBackfill(
    db: db,
    prefs: prefs,
    config: () => ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(ai: ai),
    registryFactory: () {
      registriesBuilt++;
      return VideoSubtitleRegistry(<VideoSubtitleProvider>[
        if (!noProviders) provider,
      ]);
    },
    aiClientFactory: aiClientFactory,
    clock: () => now,
  );

  /// 库里一集视频（文件真实存在）。
  Future<VideoBookRow> addVideo(String name) async {
    final File video = File(p.join(tmp.path, 'videos', '$name.mkv'))
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(List<int>.filled(4096, 0));
    await db.upsertVideoBook(
      VideoBooksCompanion.insert(
        bookUid: 'video/$name',
        title: name,
        videoPath: video.path,
      ),
    );
    return (await db.getVideoBookByBookUid('video/$name'))!;
  }

  /// 一条已完成的下载任务导入了 [book] 的文件；带一条 `unavailable` 的字幕行
  /// （下载那一刻没搜到字幕，7 小时前试过）。返回字幕行 id。
  Future<String> markDownloaded(VideoBookRow book) async {
    final String jobId = 'job-${book.bookUid}';
    await db.upsertVideoDownloadJob(
      VideoDownloadJobsCompanion.insert(
        jobId: jobId,
        resourceProvider: 'nyaa:test',
        selectedResourceId: 'r-${book.bookUid}',
        mediaKind: 'tv',
        title: 'Show',
        backendKind: 'embedded',
        fingerprint: 'fp',
        lifecycle: const Value<String>(VideoDownloadJobLifecycle.completed),
        stage: const Value<String>(VideoDownloadJobStage.scrape),
        createdAt: nowMs - 24 * hour,
        updatedAt: nowMs - 24 * hour,
      ),
    );
    await db.upsertVideoDownloadJobFile(
      VideoDownloadJobFilesCompanion.insert(
        jobId: jobId,
        backendFileIndex: const Value<int?>(0),
        originalRelativePath: p.basename(book.videoPath),
        currentRelativePath: p.basename(book.videoPath),
        finalAbsolutePath: Value<String?>(book.videoPath),
        kind: const Value<String>('video'),
        season: const Value<int?>(1),
        episode: const Value<int?>(3),
        status: const Value<String>(VideoDownloadJobFileStatus.imported),
        createdAt: nowMs - 24 * hour,
        updatedAt: nowMs - 24 * hour,
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
        season: const Value<int?>(1),
        episode: const Value<int?>(3),
        status: const Value<String>(VideoDownloadJobSubtitleStatus.unavailable),
        error: const Value<String?>('no candidate'),
        createdAt: Value<int>(nowMs - 24 * hour),
        updatedAt: Value<int>(nowMs - 7 * hour),
      ),
    );
    return subtitleId;
  }

  /// 刮削结论落库（单文件作品挂在这一集上），重试按它补身份。
  Future<void> scrapeIntoLibrary(VideoBookRow book) async {
    final int workId = await db.upsertVideoMetadataWork(
      VideoMetadataWorksCompanion.insert(
        bookUid: Value<String?>(book.bookUid),
        mediaType: 'tv',
        title: 'Show',
        updatedAt: nowMs,
      ),
    );
    await db.replaceVideoMetadataProviderIdentities(
      workId: workId,
      identities: <VideoMetadataProviderIdentitiesCompanion>[
        VideoMetadataProviderIdentitiesCompanion.insert(
          identityKey: 'work:$workId:anilist',
          workId: Value<int?>(workId),
          provider: 'anilist',
          externalId: '154587',
          isPrimary: const Value<bool>(true),
          updatedAt: nowMs,
        ),
      ],
    );
  }

  VideoScrapedWorkNotice noticeFor(VideoBookRow book) => VideoScrapedWorkNotice(
    work: VideoSourceScrapeWork(
      source: null,
      title: 'Show',
      members: <VideoBookRow>[book],
    ),
    metadata: VideoMetadataWork(
      provider: VideoMetadataProviderKind.anidb,
      kind: VideoMetadataMediaKind.tv,
      title: 'Show',
      ids: const <VideoMetadataId>[
        VideoMetadataId(type: 'anilist', value: '154587'),
      ],
    ),
  );

  group('刮削后补字幕（onWorkScraped）', () {
    test('下载来的作品：按刮削身份搜、装上 sidecar', () async {
      final VideoBookRow book = await addVideo('Show - 03');
      await markDownloaded(book);

      await backfill().onWorkScraped(noticeFor(book));

      expect(provider.requests, hasLength(1));
      expect(provider.requests.single.media?.anilistId, 154587);
      expect(
        File(p.join(tmp.path, 'videos', 'Show - 03.ja.srt')).existsSync(),
        isTrue,
      );
    });

    test('不是下载来的作品（库根扫描刮出来的）：不搜', () async {
      final VideoBookRow book = await addVideo('Show - 03');

      await backfill().onWorkScraped(noticeFor(book));

      expect(provider.requests, isEmpty);
    });

    test('「自动获取字幕」关了：不搜', () async {
      final VideoBookRow book = await addVideo('Show - 03');
      await markDownloaded(book);
      await prefs.setPref(kVideoSubtitleBackfillAfterScrapePref, false);

      await backfill().onWorkScraped(noticeFor(book));

      expect(provider.requests, isEmpty);
      expect(registriesBuilt, 0);
    });

    test('一家字幕来源都没配：什么都不做', () async {
      final VideoBookRow book = await addVideo('Show - 03');
      await markDownloaded(book);

      await backfill(noProviders: true).onWorkScraped(noticeFor(book));

      expect(
        File(p.join(tmp.path, 'videos', 'Show - 03.ja.srt')).existsSync(),
        isFalse,
      );
    });
  });

  group('下载后缺字幕的定期重试', () {
    test('到期的 unavailable 行：真去补，装上后标 placed、指向新 sidecar', () async {
      final VideoBookRow book = await addVideo('Show - 03');
      final String subtitleId = await markDownloaded(book);
      await scrapeIntoLibrary(book);

      final DownloadSubtitleRetryReport? report = await backfill()
          .retryDownloadsOnce();

      expect(report, isNotNull);
      expect(report!.attempted, 1);
      expect(report.installed, 1);
      final VideoDownloadJobSubtitleRow row =
          (await db.getVideoDownloadJobSubtitles('job-${book.bookUid}')).single;
      expect(row.subtitleId, subtitleId);
      expect(row.status, VideoDownloadJobSubtitleStatus.placed);
      final String sidecar = p.join(tmp.path, 'videos', 'Show - 03.ja.srt');
      expect(row.finalPath, sidecar);
      expect(
        (await db.getVideoBookByBookUid(book.bookUid))!.subtitleSource,
        sidecar,
      );
    });

    test('开关关了 / 没配来源：整轮跳过（返回 null），不动任务行', () async {
      final VideoBookRow book = await addVideo('Show - 03');
      await markDownloaded(book);
      await scrapeIntoLibrary(book);

      expect(await backfill(noProviders: true).retryDownloadsOnce(), isNull);
      await prefs.setPref(kVideoSubtitleBackfillAfterScrapePref, false);
      expect(await backfill().retryDownloadsOnce(), isNull);

      expect(provider.requests, isEmpty);
      final VideoDownloadJobSubtitleRow row =
          (await db.getVideoDownloadJobSubtitles('job-${book.bookUid}')).single;
      expect(row.status, VideoDownloadJobSubtitleStatus.unavailable);
      expect(row.updatedAt, nowMs - 7 * hour);
    });

    test('上一轮还没跑完时不叠加', () async {
      final VideoBookRow book = await addVideo('Show - 03');
      await markDownloaded(book);
      await scrapeIntoLibrary(book);
      final ServerSubtitleBackfill service = backfill();

      final Future<DownloadSubtitleRetryReport?> first = service
          .retryDownloadsOnce();
      expect(await service.retryDownloadsOnce(), isNull);
      expect((await first)?.attempted, 1);
      await service.stop();
    });
  });

  group('AI 重排候选', () {
    const ServerAiConfig ai = ServerAiConfig(
      preset: kAiCustomPresetId,
      baseUrl: 'https://ai.example.test/v1',
      model: 'm',
      apiKey: 'sk-test',
    );

    test('服务端那一家 AI 指派给了「视频搜索辅助」', () {
      final ServerAiSettings settings = ServerAiSettings(() => ai);
      expect(
        settings.aiFeatureAssignments.resolve(
          AiFeature.videoSearch,
          settings.aiProviders,
        ),
        isNotNull,
      );
      final ServerAiSettings none = ServerAiSettings(() => null);
      expect(
        none.aiFeatureAssignments.resolve(
          AiFeature.videoSearch,
          none.aiProviders,
        ),
        isNull,
      );
    });

    test('没有 ai: 段：一个 AI 请求都不发', () async {
      final VideoBookRow book = await addVideo('Show - 03');
      await markDownloaded(book);
      int clients = 0;

      await backfill(
        aiClientFactory: () {
          clients++;
          return AiChatClient(
            client: MockClient((_) async => http.Response('', 500)),
          );
        },
      ).onWorkScraped(noticeFor(book));

      expect(provider.requests, hasLength(1), reason: '确实走到了有两条候选的那一步');
      expect(clients, 0);
    });

    test('配了 ai: 段：下载前把候选交给那一家排序；AI 失败仍按原序装上', () async {
      final VideoBookRow book = await addVideo('Show - 03');
      await markDownloaded(book);
      final List<Uri> aiRequests = <Uri>[];

      await backfill(
        ai: ai,
        aiClientFactory: () => AiChatClient(
          client: MockClient((http.Request request) async {
            aiRequests.add(request.url);
            return http.Response('{"error":"bad request"}', 400);
          }),
        ),
      ).onWorkScraped(noticeFor(book));

      expect(aiRequests, isNotEmpty);
      expect(aiRequests.first.host, 'ai.example.test');
      expect(
        File(p.join(tmp.path, 'videos', 'Show - 03.ja.srt')).existsSync(),
        isTrue,
      );
    });
  });

  test('Jimaku 来源是与 app 同一个 provider（按 AniList / TMDB id 直查条目）', () {
    final VideoSubtitleProvider jimaku = createSubsProvider(
      'jimaku',
      resolveSubsCredentials(prefs, const <String, String>{
        kJimakuApiKeyEnv: 'jk',
      }),
    );
    addTearDown(jimaku.close);
    expect(jimaku, isA<JimakuVideoSubtitleProvider>());
  });
}

/// 每次搜索回两条日语候选（AI 重排只在 ≥2 条时介入），下载回一段日语 SRT。
class _FakeSubtitleProvider implements VideoSubtitleProvider {
  final List<VideoSubtitleSearchRequest> requests =
      <VideoSubtitleSearchRequest>[];

  @override
  String get id => 'jimaku';

  @override
  int get priority => 100;

  @override
  bool get allowsFreeProbeDownload => true;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    requests.add(request);
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      <VideoSubtitleCandidate>[
        _Candidate('a', request.episode),
        _Candidate('b', request.episode),
      ],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(
    VideoSubtitleCandidate candidate,
  ) async => VideoSubtitleDownload(
    bytes: Uint8List.fromList(
      utf8.encode(
        '1\n00:00:01,000 --> 00:00:03,000\nこんにちは、元気ですか。\n\n'
        '2\n00:00:04,000 --> 00:00:06,000\n今日はいい天気ですね。\n',
      ),
    ),
    fileName: '${candidate.remoteId}.ja.srt',
    language: 'ja',
  );

  @override
  void close() {}
}

class _Candidate extends VideoSubtitleCandidate {
  _Candidate(String remoteId, int? episode)
    : super(
        providerId: 'jimaku',
        remoteId: remoteId,
        fileName: 'Show - 03 [$remoteId].ja.srt',
        language: 'ja',
        providerPriority: 100,
        episode: episode,
      );
}
