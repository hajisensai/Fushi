import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fushi_cli/fushi_cli.dart';
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
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/admin/admin_ops.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/ctl/admin_client.dart';
import 'package:fushi_server/src/ctl/ctl_commands.dart';
import 'package:fushi_server/src/download_host.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/server_subtitle_providers.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';

/// 在线字幕来源的设置入口（WebUI「设置」页 / `PUT /api/admin/settings` /
/// `ctl settings`）：写与 app 同名的偏好键；key / 密码永不回显；留空 = 不改、
/// `clearApiKey` 才清；AI 助手的设置操作碰不到凭据；经 admin 存的 key 下一个下载任务的
/// 字幕阶段就用上。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late File configFile;
  late ServerPrefs prefs;
  late AdminApi api;
  late AdminContext ctx;
  late ServerConfig config;

  const String jimakuSecret = 'jimaku-secret-123';
  const String subdlSecret = 'subdl-secret-456';
  const String osSecret = 'os-secret-789';
  const String osPassword = ' os pass word ';

  Future<void> buildAdmin({Map<String, String> env = const {}}) async {
    config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok');
    await config.save(configFile);
    prefs = ServerPrefs(db);
    await prefs.warmUp();
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    final HeadlessHost host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
      p2pAvailable: () => false,
    );
    ctx = AdminContext(
      config: config,
      configFile: configFile,
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
      db: db,
      identity: identity,
      host: host,
      startedAt: DateTime.now(),
      environment: env,
    );
    api = AdminApi(ctx);
  }

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_subs_');
    enginePaths = ServerPaths(p.join(tmp.path, 'data'));
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
  });

  tearDown(() async {
    await db.close();
    enginePaths = const UninstalledEnginePaths();
    try {
      await tmp.delete(recursive: true);
    } catch (_) {}
  });

  Future<({int status, String text, Map<String, dynamic> json})> call(
    String method, [
    Object? body,
  ]) async {
    final shelf.Response r = await api.handle(
      shelf.Request(
        method,
        Uri.parse('http://localhost/api/admin/settings'),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final String text = await r.readAsString();
    return (
      status: r.statusCode,
      text: text,
      json: Map<String, dynamic>.from(jsonDecode(text) as Map),
    );
  }

  Map<String, dynamic> providers(Map<String, dynamic> json) =>
      Map<String, dynamic>.from(json['subtitleProviders'] as Map);
  Map<String, dynamic> provider(Map<String, dynamic> json, String id) =>
      Map<String, dynamic>.from(providers(json)[id] as Map);

  group('admin API', () {
    setUp(() => buildAdmin());

    test('GET：三家都在，默认开着、没 key（OpenSubtitles 有内置 key 时才生效）', () async {
      final (:int status, text: _, :Map<String, dynamic> json) = await call(
        'GET',
      );
      expect(status, 200);
      expect(providers(json).keys, <String>[
        'opensubtitles',
        'subdl',
        'jimaku',
      ]);
      for (final String id in <String>['subdl', 'jimaku']) {
        expect(provider(json, id), <String, Object?>{
          'enabled': true,
          'apiKeySet': false,
          'apiKeyFromEnv': false,
          'active': false,
        });
      }
      expect(provider(json, 'opensubtitles')['apiKeySet'], isFalse);
      expect(provider(json, 'opensubtitles')['passwordSet'], isFalse);
      expect(
        (json['restartRequiredKeys'] as List).contains('subtitleProviders'),
        isFalse,
        reason: '保存即生效',
      );
    });

    test('PUT 存 key：写进与 app 同名的偏好键；响应 / 日志里没有明文', () async {
      final ({int status, String text, Map<String, dynamic> json}) put =
          await call('PUT', <String, Object?>{
            'subtitleProviders': <String, Object?>{
              'jimaku': <String, Object?>{'apiKey': ' $jimakuSecret '},
              'subdl': <String, Object?>{'apiKey': subdlSecret},
              'opensubtitles': <String, Object?>{
                'apiKey': osSecret,
                'username': 'me',
                'password': osPassword,
              },
            },
          });
      expect(put.status, 200, reason: put.text);
      for (final String secret in <String>[
        jimakuSecret,
        subdlSecret,
        osSecret,
        osPassword.trim(),
      ]) {
        expect(put.text, isNot(contains(secret)));
      }
      expect(provider(put.json, 'jimaku')['apiKeySet'], isTrue);
      expect(provider(put.json, 'jimaku')['active'], isTrue);
      expect(provider(put.json, 'subdl')['active'], isTrue);
      expect(provider(put.json, 'opensubtitles')['apiKeySet'], isTrue);
      expect(provider(put.json, 'opensubtitles')['passwordSet'], isTrue);
      expect(provider(put.json, 'opensubtitles')['username'], 'me');

      expect(prefs.getPref(kJimakuApiKeyPref), jimakuSecret);
      expect(prefs.getPref(kSubdlApiKeyPref), subdlSecret);
      final Map<String, Object?> os = Map<String, Object?>.from(
        jsonDecode(prefs.getPref(kOpenSubtitlesConfigPref) as String) as Map,
      );
      expect(os['apiKey'], osSecret);
      expect(os['password'], osPassword, reason: '密码原样存，不 trim');
      expect(os['username'], 'me');
      // 走的是生产凭据解析：下一轮字幕阶段就用这些。
      final SubsCredentials creds = resolveSubsCredentials(
        prefs,
        const <String, String>{},
      );
      expect(creds.jimakuApiKey, jimakuSecret);
      expect(creds.openSubtitles.effectiveApiKey, osSecret);

      final String got = (await call('GET')).text;
      expect(got, isNot(contains(jimakuSecret)));
      final File log = File(p.join(tmp.path, 'server.log'));
      if (log.existsSync()) {
        expect(log.readAsStringSync(), isNot(contains(jimakuSecret)));
      }
      expect(configFile.readAsStringSync(), isNot(contains(jimakuSecret)));
    });

    test('留空 = 不改；clearApiKey 才清；开关只改开关', () async {
      await call('PUT', <String, Object?>{
        'subtitleProviders': <String, Object?>{
          'jimaku': <String, Object?>{'apiKey': jimakuSecret},
        },
      });
      await call('PUT', <String, Object?>{
        'subtitleProviders': <String, Object?>{
          'jimaku': <String, Object?>{'apiKey': '', 'enabled': false},
        },
      });
      expect(prefs.getPref(kJimakuApiKeyPref), jimakuSecret);
      expect(prefs.getPref(kJimakuEnabledPref), isFalse);
      final Map<String, dynamic> off = (await call('GET')).json;
      expect(provider(off, 'jimaku')['apiKeySet'], isTrue);
      expect(provider(off, 'jimaku')['active'], isFalse, reason: '关着就不用');

      // 不相干的设置保存不碰字幕来源。
      await call('PUT', <String, Object?>{'deviceName': 'nas'});
      expect(prefs.getPref(kJimakuApiKeyPref), jimakuSecret);

      final Map<String, dynamic> cleared = (await call('PUT', <String, Object?>{
        'subtitleProviders': <String, Object?>{
          'jimaku': <String, Object?>{'clearApiKey': true, 'enabled': true},
        },
      })).json;
      expect(prefs.getPref(kJimakuApiKeyPref), '');
      expect(provider(cleared, 'jimaku')['apiKeySet'], isFalse);
      expect(provider(cleared, 'jimaku')['active'], isFalse);
    });

    test('OpenSubtitles：清密码不动 key；配置里别的字段原样保留', () async {
      await prefs.setPref(
        kOpenSubtitlesConfigPref,
        jsonEncode(<String, Object?>{
          'apiKey': osSecret,
          'password': 'pw',
          'username': 'u',
          'priority': 7,
        }),
      );
      await call('PUT', <String, Object?>{
        'subtitleProviders': <String, Object?>{
          'opensubtitles': <String, Object?>{'clearPassword': true},
        },
      });
      final Map<String, Object?> os = Map<String, Object?>.from(
        jsonDecode(prefs.getPref(kOpenSubtitlesConfigPref) as String) as Map,
      );
      expect(os['password'], '');
      expect(os['apiKey'], osSecret);
      expect(os['username'], 'u');
      expect(os['priority'], 7);
    });

    test('非法 → 400，整批一个字节都不写', () async {
      final List<Object?> bad = <Object?>[
        'nope',
        <String, Object?>{
          'jimaku': <String, Object?>{'apiKey': jimakuSecret},
          'subdl': <String, Object?>{'apiKey': 42},
        },
        <String, Object?>{
          'jimaku': <String, Object?>{'apiKey': jimakuSecret},
          'ajatt': <String, Object?>{'apiKey': 'x'},
        },
        <String, Object?>{
          'jimaku': <String, Object?>{'apiKey': jimakuSecret, 'baseUrl': 'x'},
        },
        <String, Object?>{
          'jimaku': <String, Object?>{
            'apiKey': jimakuSecret,
            'clearApiKey': true,
          },
        },
        <String, Object?>{
          'jimaku': <String, Object?>{'enabled': 'yes'},
        },
      ];
      for (final Object? body in bad) {
        final ({int status, String text, Map<String, dynamic> json}) r =
            await call('PUT', <String, Object?>{
              'subtitleProviders': body,
              'deviceName': 'should-not-save',
            });
        expect(r.status, 400, reason: '$body → ${r.text}');
        expect(r.text, isNot(contains(jimakuSecret)));
      }
      expect(prefs.getPref(kJimakuApiKeyPref), isNull);
      expect(prefs.getPref(kSubdlApiKeyPref), isNull);
      expect(ctx.config.deviceName, isNot('should-not-save'));
    });
  });

  test('环境变量照旧优先：GET 报 apiKeyFromEnv，存的 key 不被覆盖', () async {
    await buildAdmin(env: const <String, String>{kJimakuApiKeyEnv: 'from-env'});
    await call('PUT', <String, Object?>{
      'subtitleProviders': <String, Object?>{
        'jimaku': <String, Object?>{'apiKey': jimakuSecret},
      },
    });
    final Map<String, dynamic> json = (await call('GET')).json;
    expect(provider(json, 'jimaku')['apiKeyFromEnv'], isTrue);
    expect(provider(json, 'jimaku')['apiKeySet'], isTrue);
    expect(prefs.getPref(kJimakuApiKeyPref), jimakuSecret);
    expect(
      resolveSubsCredentials(prefs, ctx.environment).jimakuApiKey,
      'from-env',
    );
  });

  group('AI 助手的 server.settings.set', () {
    late List<String> forwarded;
    late CtlRoute route;

    setUp(() async {
      await buildAdmin();
      forwarded = <String>[];
      route =
          buildServerAdminOps(
            () => (shelf.Request request) async {
              forwarded.add(await request.readAsString());
              return api.handle(
                shelf.Request(
                  request.method,
                  request.requestedUri,
                  body: forwarded.last,
                ),
              );
            },
          ).routes.firstWhere(
            (CtlRoute r) =>
                r.method == 'PUT' && r.pattern == '/api/admin/settings',
          );
    });

    Future<Object?> invoke(Map<String, Object?> body) => route.handler(
      CtlCall(
        method: 'PUT',
        path: '/api/admin/settings',
        body: body,
        fromModel: true,
      ),
    );

    test('凭据 / 要重启的项一律 400、不转发、消息不带值', () async {
      for (final Map<String, Object?> body in <Map<String, Object?>>[
        <String, Object?>{
          'subtitleProviders': <String, Object?>{
            'jimaku': <String, Object?>{'apiKey': jimakuSecret},
          },
        },
        <String, Object?>{'tmdbApiKey': jimakuSecret},
        <String, Object?>{
          'subtitleLanguage': 'en',
          'ai': <String, Object?>{'apiKey': jimakuSecret},
        },
        <String, Object?>{'port': 1},
      ]) {
        await expectLater(
          invoke(body),
          throwsA(
            isA<CtlFailure>()
                .having((CtlFailure f) => f.status, 'status', 400)
                .having(
                  (CtlFailure f) => f.message ?? '',
                  'message',
                  isNot(contains(jimakuSecret)),
                ),
          ),
        );
      }
      expect(forwarded, isEmpty);
      expect(prefs.getPref(kJimakuApiKeyPref), isNull);
      expect(ctx.config.subtitleLanguage, isNot('en'));
    });

    test('白名单里的项照常转发', () async {
      await invoke(<String, Object?>{'subtitleLanguage': 'en'});
      expect(forwarded, hasLength(1));
      expect(ctx.config.subtitleLanguage, 'en');
    });
  });

  group('ctl settings', () {
    late HttpServer server;
    late AdminClient client;
    late StringBuffer out;
    late StringBuffer err;
    String? secret;

    setUp(() async {
      await buildAdmin();
      server = await shelf_io.serve(
        api.handle,
        InternetAddress.loopbackIPv4,
        0,
      );
      client = AdminClient(
        baseUri: Uri.parse('http://127.0.0.1:${server.port}'),
        token: 'tok',
      );
      out = StringBuffer();
      err = StringBuffer();
      secret = null;
    });

    tearDown(() async {
      client.close();
      await server.close(force: true);
    });

    Future<int> ctl(List<String> args) => runCtlAction(
      client,
      buildCtlParser().parse(args),
      out: out,
      err: err,
      readSecret: (String env) {
        expect(env, kJimakuApiKeyEnv);
        return secret;
      },
    );

    test('subtitle-key 从 stdin / 环境变量读 key（不进 argv）、存进偏好、不回显', () async {
      secret = jimakuSecret;
      expect(await ctl(<String>['settings', 'subtitle-key', 'jimaku']), 0);
      expect(prefs.getPref(kJimakuApiKeyPref), jimakuSecret);
      expect(out.toString(), contains('jimaku'));
      expect(out.toString(), contains('apiKeySet=true'));
      expect(out.toString(), isNot(contains(jimakuSecret)));

      out.clear();
      expect(await ctl(<String>['settings', 'get']), 0);
      expect(out.toString(), isNot(contains(jimakuSecret)));

      expect(
        await ctl(<String>['settings', 'subtitle-source', 'jimaku', 'off']),
        0,
      );
      expect(prefs.getPref(kJimakuEnabledPref), isFalse);

      expect(
        await ctl(<String>['settings', 'subtitle-key', 'jimaku', 'clear']),
        0,
      );
      expect(prefs.getPref(kJimakuApiKeyPref), '');
    });

    test('没读到 key / 未知来源：不发请求', () async {
      secret = '';
      expect(await ctl(<String>['settings', 'subtitle-key', 'jimaku']), 64);
      expect(await ctl(<String>['settings', 'subtitle-key', 'ajatt']), 64);
      expect(prefs.getPref(kJimakuApiKeyPref), isNull);
    });

    test("settings set '<json>' 同样能写（与 WebUI 同一个接口）", () async {
      expect(
        await ctl(<String>[
          'settings',
          'set',
          jsonEncode(<String, Object?>{
            'subtitleProviders': <String, Object?>{
              'subdl': <String, Object?>{'enabled': false},
            },
          }),
        ]),
        0,
      );
      expect(prefs.getPref(kSubdlEnabledPref), isFalse);
    });
  });

  test('经 admin 存的 key：下一个下载任务的字幕阶段就用上（真 host 类）', () async {
    await buildAdmin();
    final List<_RecordingProvider> built = <_RecordingProvider>[];
    final Directory videos = Directory(p.join(tmp.path, 'videos'))
      ..createSync(recursive: true);
    final int sourceId = await db.insertMediaSource(
      MediaSourcesCompanion.insert(
        label: 'Videos',
        mediaKind: 'video',
        rootPath: videos.path,
        createdAt: 1,
      ),
    );
    final ServerPaths paths = ServerPaths(config.dataDir);
    await paths.ensureLayout();
    final ServerDownloadHost downloads = ServerDownloadHost(
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
      // 生产装配，只换掉出网的 provider；环境变量置空。
      subtitleRegistryFactory: () => buildServerSubtitleRegistry(
        prefs,
        environment: const <String, String>{},
        providerFactory: (String id, SubsCredentials c) {
          final _RecordingProvider provider = _RecordingProvider(
            id,
            id == 'jimaku' ? c.jimakuApiKey : '',
          );
          built.add(provider);
          return provider;
        },
      ),
    );
    await downloads.start();
    addTearDown(downloads.stop);
    // OpenSubtitles 的内置 key 只在 CI 构建里有；关掉它，只看 Jimaku。
    await call('PUT', <String, Object?>{
      'subtitleProviders': <String, Object?>{
        'opensubtitles': <String, Object?>{'enabled': false},
      },
    });
    expect(downloads.subtitleProviderIds, isEmpty);

    final Map<String, dynamic> saved = (await call('PUT', <String, Object?>{
      'subtitleProviders': <String, Object?>{
        'jimaku': <String, Object?>{'apiKey': jimakuSecret},
      },
    })).json;
    expect(provider(saved, 'jimaku')['active'], isTrue);
    expect(downloads.subtitleProviderIds, <String>['jimaku']);

    const String jobId = 'job-after-admin-save';
    final Directory season = Directory(
      p.join(videos.path, 'Show (2026)', 'Season 01'),
    )..createSync(recursive: true);
    final File video = File(p.join(season.path, 'Show - S01E02.mkv'))
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
    final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
    while (DateTime.now().isBefore(deadline)) {
      final VideoDownloadJobRow? row = await db.getVideoDownloadJob(jobId);
      if (row != null && row.stage != VideoDownloadJobStage.subtitle) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final List<_RecordingProvider> searched = <_RecordingProvider>[
      for (final _RecordingProvider p in built)
        if (p.searchCalls > 0) p,
    ];
    expect(searched, hasLength(1));
    expect(searched.single.id, 'jimaku');
    expect(searched.single.key, jimakuSecret);
  });
}

class _RecordingProvider implements VideoSubtitleProvider {
  _RecordingProvider(this.id, this.key);

  @override
  final String id;
  final String key;
  int searchCalls = 0;

  @override
  int get priority => 0;

  @override
  bool get allowsFreeProbeDownload => false;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(
    VideoSubtitleSearchRequest request,
  ) async {
    searchCalls++;
    return ProviderBatchResult<VideoSubtitleCandidate>.success(
      const <VideoSubtitleCandidate>[],
    );
  }

  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) =>
      throw UnimplementedError();

  @override
  void close() {}
}

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
