import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/torrent/torrent_backend.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
import 'package:fushi_engine/media/video/acquisition/video_acquisition_prefs.dart';
import 'package:fushi_engine/media/video/discovery/video_discovery_provider.dart';
import 'package:fushi_engine/media/video/download/video_download_backend_identity.dart';
import 'package:fushi_engine/media/video/download/video_download_pipeline_service.dart';
import 'package:fushi_engine/media/video/download/video_resource_registry.dart';
import 'package:fushi_engine/media/video/metadata/video_metadata_models.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_coordinator.dart';
import 'package:fushi_engine/sync/assistant/host_assistant.dart';
import 'package:fushi_engine/sync/assistant/video_acquisition_assistant_host.dart';
import 'package:fushi_server/src/assistant_host.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:test/test.dart';

/// 无头服务端的「AI 下视频」助手会话（`/api/assistant`）：
/// - 没配 `ai:` 段 / 没配全 → 能力位 no_provider、开会话被拒、AI 端点零请求；
/// - 配了 → 一句话经**服务端自己的** AI 解析，状态机在服务端跑，确认后任务真的进了
///   服务端下载管线（`video_download_jobs` 行），不是手机本机。
void main() {
  late FushiDatabase db;
  late _FakeAiEndpoint ai;
  late VideoDownloadPipelineService pipeline;
  late VideoResourceRegistry registry;
  late int sourceId;
  late _MemoryPrefs prefs;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    ai = await _FakeAiEndpoint.start();
    registry = VideoResourceRegistry(<VideoResourceProvider>[_FakeResources()]);
    pipeline = VideoDownloadPipelineService(
      database: db,
      resourceRegistry: registry,
      backendResolver: (_) async => null,
      scrapeCoordinator: VideoSourceScrapeCoordinator(
        database: db,
        config: const VideoSourceScrapeGlobalConfig(),
      ),
    );
    sourceId = await db.insertMediaSource(MediaSourcesCompanion(
      label: const Value('fushi_server downloads'),
      mediaKind: const Value('video'),
      transport: const Value('local'),
      rootPath: Value(Directory.systemTemp.path),
      recursive: const Value(true),
      createdAt: Value(DateTime.now().millisecondsSinceEpoch),
    ));
    // 画质 / 字幕语言已有默认：对话不再追问，一句话直接走到「就这个？」。
    prefs = _MemoryPrefs(<String, Object?>{
      kAiVideoDownloadQualityPref: '1080p',
      kAiVideoDownloadSubtitleLanguagePref: 'ja',
    });
  });

  tearDown(() async {
    await pipeline.dispose(drainTimeout: Duration.zero);
    await ai.close();
    await db.close();
  });

  ServerConfig config(ServerAiConfig? aiConfig) =>
      ServerConfig.defaults(dataDir: Directory.systemTemp.path).copyWith(ai: aiConfig);

  ServerAiConfig fakeAi({String? apiKey = 'sk-test'}) => ServerAiConfig(
        preset: 'custom',
        baseUrl: ai.baseUrl,
        model: 'fake-model',
        apiKey: apiKey,
        webKnowledge: false,
      );

  VideoAcquisitionAssistantHost host(ServerConfig Function() cfg, {List<String>? discoveryLocales}) =>
      createServerAssistantHostWith(
        config: cfg,
        prefs: prefs,
        db: db,
        downloads: _FakeDownloads(pipeline, registry, db, sourceId),
        discovery: (String locale) {
          discoveryLocales?.add(locale);
          return (
            search: (VideoDiscoveryRequest request) async =>
                ProviderBatchResult<VideoDiscoveryPage>.success(<VideoDiscoveryPage>[
                  VideoDiscoveryPage(items: <VideoDiscoveryItem>[_finishedShow()], page: 1, hasMore: false),
                ]),
            service: null,
            release: () {},
          );
        },
      );

  test('没配 ai 段 / 只配了一半 → no_provider，开会话被拒，AI 端点零请求', () async {
    for (final ServerAiConfig? aiConfig in <ServerAiConfig?>[null, fakeAi(apiKey: null)]) {
      final VideoAcquisitionAssistantHost provider = host(() => config(aiConfig));
      final Map<String, Object?> cap = await provider.capability();
      expect(cap['supported'], isFalse, reason: '$aiConfig');
      expect(cap['reason'], kHostAssistantReasonNoProvider);
      expect(cap['features'], isEmpty);
      await expectLater(
        provider.open(kHostAssistantFeatureVideoAcquire, locale: 'zh-CN'),
        throwsA(isA<HostAssistantUnavailable>()
            .having((HostAssistantUnavailable e) => e.reason, 'reason', kHostAssistantReasonNoProvider)),
      );
    }
    expect(ai.requests, isEmpty, reason: '所有者规则：未指派提供商不发任何 AI 请求');
  });

  test('下载管线没起来 → not_ready（AI 配好了也不开会话）', () async {
    final VideoAcquisitionAssistantHost provider = createServerAssistantHostWith(
      config: () => config(fakeAi()),
      prefs: prefs,
      db: db,
      downloads: _FakeDownloads(null, null, db, null),
      discovery: (_) => throw StateError('must not open discovery'),
    );
    final Map<String, Object?> cap = await provider.capability();
    expect(cap['reason'], kHostAssistantReasonNotReady);
    expect(ai.requests, isEmpty);
  });

  test('配了 AI → 一句话经服务端 AI 解析 → 确认 → 任务进服务端下载管线', () async {
    final List<String> discoveryLocales = <String>[];
    final HostAssistantSessions sessions = HostAssistantSessions(
      host(() => config(fakeAi()), discoveryLocales: discoveryLocales),
    );
    addTearDown(sessions.dispose);
    final Map<String, Object?> cap = await sessions.capability();
    expect(cap['supported'], isTrue);
    expect(cap['features'], <String>[kHostAssistantFeatureVideoAcquire]);

    final Map<String, Object?> opened = await sessions.open(kHostAssistantFeatureVideoAcquire, locale: 'ja-JP');
    final String id = opened['id']! as String;
    expect(discoveryLocales, <String>['ja-JP'], reason: '发现 / AI 提示词按手机的语言');

    await sessions.act(id, <String, Object?>{'type': 'text', 'text': '下 Show'});
    final Map<String, Object?> asked = await _viewWhere(sessions, id, (Map<String, Object?> v) => v['stage'] == 'awaitingResourceConfirm');
    expect(ai.requests, hasLength(1), reason: '一句话交给的是服务端配置的 AI');
    expect(ai.requests.single, contains('下 Show'));
    expect(ai.authorizations.single, 'Bearer sk-test');
    expect((asked['question']! as Map<String, Object?>)['slot'], 'resource');

    await sessions.act(id, <String, Object?>{'type': 'confirm'});
    await _viewWhere(sessions, id, (Map<String, Object?> v) => v['stage'] == 'done');
    final List<VideoDownloadJobRow> jobs = await db.select(db.videoDownloadJobs).get();
    expect(jobs, hasLength(3), reason: '三集都入了服务端的管线');
    expect(jobs.map((VideoDownloadJobRow j) => j.targetSourceId).toSet(), <int>{sourceId});
    expect(jobs.map((VideoDownloadJobRow j) => j.title).toSet(), <String>{'Show'});
    expect(prefs.values[kServerSeriesSubtitleLanguagesPref], contains('ja'), reason: '每系列字幕语言记忆写进服务端偏好');
  });

  test('ai 段 yaml 往返：API key 写回配置文件、admin 形状不回显', () {
    final ServerConfig original = config(const ServerAiConfig(
      preset: 'openai',
      model: 'gpt-x',
      apiKey: 'sk-secret',
      webKnowledge: false,
    ));
    final ServerConfig parsed = ServerConfig.parse(original.toYaml(), configDir: Directory.systemTemp.path);
    final ServerAiConfig back = parsed.ai!;
    expect(back.preset, 'openai');
    expect(back.model, 'gpt-x');
    expect(back.apiKey, 'sk-secret');
    expect(back.webKnowledge, isFalse);
    expect(back.baseUrl, isNull, reason: '没写 base_url = 跟随预设');
    expect(back.effectiveBaseUrl, 'https://api.openai.com/v1');
    expect(back.provider(), isNotNull);
    final String admin = jsonEncode(back.toAdminJson());
    expect(admin, isNot(contains('sk-secret')));
    expect(back.toAdminJson()['apiKeySet'], isTrue);
    expect(ServerConfig.parse('port: 1\n', configDir: '.').ai, isNull, reason: '没有 ai 段 = 未配置');
  });
}

Future<Map<String, Object?>> _viewWhere(
  HostAssistantSessions sessions,
  String id,
  bool Function(Map<String, Object?> view) test,
) async {
  final DateTime deadline = DateTime.now().add(const Duration(seconds: 10));
  while (true) {
    final Map<String, Object?> envelope = (await sessions.read(id))!;
    final Map<String, Object?> view = envelope['view']! as Map<String, Object?>;
    if (test(view)) return view;
    if (DateTime.now().isAfter(deadline)) fail('view never matched: $view');
    await sessions.read(id, after: envelope['revision']! as int, wait: const Duration(seconds: 1));
  }
}

/// OpenAI 兼容的假端点：每个请求都回「provide + workQueries=[Show]」的意图。
class _FakeAiEndpoint {
  _FakeAiEndpoint._(this._server);

  final HttpServer _server;
  final List<String> requests = <String>[];
  final List<String?> authorizations = <String?>[];

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  static Future<_FakeAiEndpoint> start() async {
    final _FakeAiEndpoint endpoint = _FakeAiEndpoint._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));
    endpoint._server.listen(endpoint._handle);
    return endpoint;
  }

  Future<void> _handle(HttpRequest request) async {
    requests.add(await utf8.decodeStream(request));
    authorizations.add(request.headers.value(HttpHeaders.authorizationHeader));
    const String intent = '{"intent": "provide", "workQueries": ["Show"]}';
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(<String, Object?>{
        'choices': <Object?>[
          <String, Object?>{
            'message': <String, Object?>{'role': 'assistant', 'content': intent},
          },
        ],
      }));
    await request.response.close();
  }

  Future<void> close() => _server.close(force: true);
}

class _FakeDownloads implements ServerAssistantDownloads {
  _FakeDownloads(this.pipeline, this.registry, this._db, this._sourceId);

  @override
  final VideoDownloadPipelineService? pipeline;
  @override
  final VideoResourceRegistry? registry;
  final FushiDatabase _db;
  final int? _sourceId;

  @override
  Future<MediaSourceRow?> downloadSource() async => _sourceId == null ? null : _db.getMediaSourceById(_sourceId);

  @override
  VideoDownloadBackendTarget backendTarget() => const VideoDownloadBackendTarget(
        category: 'fushi',
        identity: VideoDownloadBackendIdentity(kind: 'embedded', profileId: 'test', fingerprint: 'fp-test'),
      );

  @override
  Future<void> checkSubscriptionsNow() async {}
}

class _MemoryPrefs implements PrefStore {
  _MemoryPrefs(this.values);

  final Map<String, Object?> values;

  @override
  dynamic getPref(String key, {dynamic defaultValue}) => values[key] ?? defaultValue;

  @override
  Future<void> setPref(String key, dynamic value) async => values[key] = value;
}

class _FakeResources implements VideoResourceProvider {
  @override
  String get id => 'nyaa';
  @override
  int get priority => 100;
  @override
  Set<VideoDiscoveryCategory> get categories => VideoDiscoveryCategory.values.toSet();
  @override
  Future<ProviderBatchResult<VideoResourceCandidate>> search(VideoResourceSearchRequest request) async =>
      ProviderBatchResult<VideoResourceCandidate>.success(<VideoResourceCandidate>[_Candidate(1), _Candidate(2), _Candidate(3)]);
  @override
  Future<TorrentAddPayload> resolve(VideoResourceCandidate candidate) => throw UnimplementedError();
  @override
  void close() {}
}

VideoDiscoveryItem _finishedShow() {
  final VideoMetadataWork work = VideoMetadataWork(
    provider: VideoMetadataProviderKind.mal,
    kind: VideoMetadataMediaKind.tv,
    title: 'Show',
    status: 'Finished Airing',
    ids: const <VideoMetadataId>[VideoMetadataId(type: 'mal', value: '1', isDefault: true)],
  );
  return VideoDiscoveryItem(
    reference: VideoMediaReference(
      providerId: 'mal',
      mediaId: '1',
      mediaKind: VideoMetadataMediaKind.tv,
      discoveryCategory: VideoDiscoveryCategory.anime,
      title: 'Show',
      year: 2026,
    ),
    metadataWork: work,
  );
}

class _Candidate extends VideoResourceCandidate {
  _Candidate(int episode)
      : super(
          providerId: 'nyaa',
          providerInstanceId: 'nyaa',
          remoteId: 'r$episode',
          title: '[Group] Show - ${episode.toString().padLeft(2, '0')} (1080p)',
          providerPriority: 100,
          releaseGroup: 'Group',
          resolution: '1080p',
          trusted: true,
          seeders: 10,
          infoHash: '${'a' * 39}$episode',
          magnetUri: 'magnet:?xt=urn:btih:${'a' * 39}$episode',
        );
}
