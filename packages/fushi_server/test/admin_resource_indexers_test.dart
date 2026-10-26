import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/rss_search_site.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/video/download/video_resource_prefs.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_routes.dart';
import 'package:fushi_server/src/admin/admin_api.dart';
import 'package:fushi_server/src/admin/admin_context.dart';
import 'package:fushi_server/src/config/server_config.dart';
import 'package:fushi_server/src/download_host.dart';
import 'package:fushi_server/src/headless_host.dart';
import 'package:fushi_server/src/server_identity.dart';
import 'package:fushi_server/src/server_log.dart';
import 'package:fushi_server/src/server_paths.dart';
import 'package:fushi_server/src/server_prefs.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// admin API 的资源索引器面（RSS 搜索站 + Torznab；不内置任何 BT 搜索站）：读写往返与
/// app 同一存储格式、`{query}` 模板校验、API key 不回显 / 留空不改、非法输入 400 不落半截，
/// 以及保存后对正在跑的下载 host 立即生效（registry 换新、互联 server 早先捕获的订阅面跟着变）。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerPrefs prefs;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_ri_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = ServerPrefs(db);
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<AdminApi> buildApi() async {
    final ServerConfig config = ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(adminToken: 'tok');
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    await config.save(configFile);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    final HeadlessHost host = HeadlessHost(config: config, paths: paths, db: db, prefs: prefs, identity: identity);
    return AdminApi(AdminContext(
      config: config,
      configFile: configFile,
      paths: paths,
      log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
      db: db,
      identity: identity,
      host: host,
      startedAt: DateTime.now(),
    ));
  }

  Future<({int status, Map<String, dynamic> json, String raw})> call(AdminApi api, String method, [Object? body]) async {
    final shelf.Response r = await api.handle(shelf.Request(
      method,
      Uri.parse('http://localhost/api/admin/resource-indexers'),
      body: body == null ? null : jsonEncode(body),
    ));
    final String raw = await r.readAsString();
    return (status: r.statusCode, json: Map<String, dynamic>.from(jsonDecode(raw) as Map), raw: raw);
  }

  String? rawPref(String key) => prefs.getPref(key) as String?;

  test('GET 默认：没有任何内置源、没有 RSS 站与 Torznab、host 未运行时 applied=false', () async {
    final AdminApi api = await buildApi();
    final (:int status, :Map<String, dynamic> json, raw: _) = await call(api, 'GET');
    expect(status, 200);
    expect(json.containsKey('builtin'), isFalse, reason: '内置 BT 搜索站已全部移除');
    expect(json['rss'], isEmpty);
    expect(json['rssDomains'], <String>['anime', 'movie', 'tv', 'novel', 'audiobook', 'manga', 'game']);
    expect(json['torznab'], isEmpty);
    expect(json['applied'], isFalse);
    expect(json['providers'], isNull);
  });

  test('RSS 站 PUT 往返：与 app 同一编码落库，新行自动发 id，域与模板原样保存', () async {
    final AdminApi api = await buildApi();
    final ({int status, Map<String, dynamic> json, String raw}) saved = await call(api, 'PUT', <String, Object?>{
      'rss': <Object?>[
        <String, Object?>{
          'name': ' Nyaa ',
          'urlTemplate': 'https://nyaa.si/?page=rss&q={query}&c=1_0&f=0',
          'domains': <String>['anime'],
          'priority': 10,
        },
        <String, Object?>{
          'id': 'mikan',
          'name': 'Mikan',
          'urlTemplate': 'https://mikanani.me/RSS/Search?searchstr={query}',
          'domains': 'anime, novel',
          'enabled': false,
        },
      ],
    });
    expect(saved.status, 200, reason: saved.raw);
    final List<Map<String, dynamic>> rows =
        (saved.json['rss'] as List).map((Object? r) => Map<String, dynamic>.from(r! as Map)).toList();
    expect(rows.first['name'], 'Nyaa');
    expect((rows.first['id'] as String).startsWith('rss-'), isTrue);
    expect(rows.first['urlTemplate'], 'https://nyaa.si/?page=rss&q={query}&c=1_0&f=0');
    expect(rows.first['domains'], <String>['anime']);
    expect(rows.first['priority'], 10);
    expect(rows.last['id'], 'mikan');
    expect(rows.last['domains'], <String>['anime', 'novel']);
    expect(rows.last['enabled'], isFalse);

    final List<RssSearchSiteConfig> stored = readRssSearchSiteConfigs(prefs);
    expect(stored.map((RssSearchSiteConfig c) => c.id), <String>[rows.first['id'] as String, 'mikan']);
    expect(jsonDecode(rawPref(kResourceRssSitesPref)!), encodeRssSearchSiteConfigs(stored));

    // 只带 torznab 不动 RSS 清单。
    final ({int status, Map<String, dynamic> json, String raw}) other = await call(api, 'PUT', <String, Object?>{
      'torznab': <Object?>[],
    });
    expect(other.status, 200, reason: other.raw);
    expect(readRssSearchSiteConfigs(prefs), hasLength(2));
  });

  test('PUT 往返：与 app 同一编码落库；key 从 ?apikey= 拆出、永不回显；留空沿用、clearApiKey 才清', () async {
    final AdminApi api = await buildApi();
    final ({int status, Map<String, dynamic> json, String raw}) saved = await call(api, 'PUT', <String, Object?>{
      'torznab': <Object?>[
        <String, Object?>{
          'name': ' Jackett ',
          'endpoint': 'https://idx.example/api/v2.0/indexers/all/results/torznab/api?apikey=SECRET-KEY',
          'priority': 5,
          'categories': '5070, 2000',
        },
      ],
    });
    expect(saved.status, 200, reason: saved.raw);
    expect(saved.raw, isNot(contains('SECRET-KEY')), reason: 'API key 不得出现在响应里');
    final Map<String, dynamic> row = Map<String, dynamic>.from((saved.json['torznab'] as List).single as Map);
    expect(row['name'], 'Jackett');
    expect(row['endpoint'], 'https://idx.example/api/v2.0/indexers/all/results/torznab/api');
    expect(row['apiKeySet'], isTrue);
    expect(row.containsKey('apiKey'), isFalse);
    expect(row['priority'], 5);
    expect(row['categories'], <int>[5070, 2000]);
    expect((row['id'] as String).startsWith('torznab-'), isTrue);

    // 存储格式 = app 的读侧能直接解（同一个 reader）。
    final List<TorznabIndexerConfig> stored = readTorznabIndexerConfigs(prefs);
    expect(stored.single.apiKey, 'SECRET-KEY');
    expect(jsonDecode(rawPref(kVideoResourceTorznabConfigPref)!), encodeTorznabIndexerConfigs(stored));

    // 同 id 再存、key 留空 → 沿用旧 key；改名照常生效。
    final String id = row['id'] as String;
    final ({int status, Map<String, dynamic> json, String raw}) kept = await call(api, 'PUT', <String, Object?>{
      'torznab': <Object?>[
        <String, Object?>{'id': id, 'name': 'Renamed', 'endpoint': row['endpoint'], 'apiKey': ''},
      ],
    });
    expect(kept.status, 200, reason: kept.raw);
    expect(readTorznabIndexerConfigs(prefs).single.apiKey, 'SECRET-KEY');
    expect(readTorznabIndexerConfigs(prefs).single.name, 'Renamed');

    final ({int status, Map<String, dynamic> json, String raw}) cleared = await call(api, 'PUT', <String, Object?>{
      'torznab': <Object?>[
        <String, Object?>{'id': id, 'name': 'Renamed', 'endpoint': row['endpoint'], 'clearApiKey': true},
      ],
    });
    expect(cleared.status, 200, reason: cleared.raw);
    expect(readTorznabIndexerConfigs(prefs).single.apiKey, '');
    expect(((cleared.json['torznab'] as List).single as Map)['apiKeySet'], isFalse);
  });

  test('非法输入一律 400，且两个偏好键一个字节都不动', () async {
    final AdminApi api = await buildApi();
    await writeRssSearchSiteConfigs(prefs, <RssSearchSiteConfig>[
      RssSearchSiteConfig(id: 'keep-rss', name: 'Keep', urlTemplate: 'https://keep.example/rss?q={query}', domains: <RssSearchDomain>[RssSearchDomain.anime]),
    ]);
    await writeTorznabIndexerConfigs(prefs, <TorznabIndexerConfig>[
      TorznabIndexerConfig(id: 'keep', name: 'Keep', endpoint: Uri.parse('https://keep.example/api'), apiKey: 'k'),
    ]);
    final String? beforeTorznab = rawPref(kVideoResourceTorznabConfigPref);
    final String? beforeRss = rawPref(kResourceRssSitesPref);

    Map<String, Object?> good() => <String, Object?>{'name': 'OK', 'endpoint': 'https://ok.example/api'};
    Map<String, Object?> goodRss() => <String, Object?>{'name': 'OK', 'urlTemplate': 'https://ok.example/rss?q={query}', 'domains': <String>['anime']};
    final List<Map<String, Object?>> bad = <Map<String, Object?>>[
      // 第二条非法：前一条合法也不能落。
      <String, Object?>{'rss': <Object?>[goodRss()], 'torznab': <Object?>[good(), <String, Object?>{'name': 'x', 'endpoint': 'ftp://x.example/api'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': 'lan', 'endpoint': 'http://192.168.1.2:9117/api'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': 'q', 'endpoint': 'https://x.example/api?t=search'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': '', 'endpoint': 'https://x.example/api'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': 'c', 'endpoint': 'https://x.example/api', 'categories': '5070,-1'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': 'p', 'endpoint': 'https://x.example/api', 'priority': 'high'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'id': 'a', ...good()}, <String, Object?>{'id': 'a', ...good()}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'id': 'a:b', ...good()}]},
      <String, Object?>{'torznab': 'nope'},
      // 内置源已移除：旧 WebUI 的 builtin 开关按 400 拒，不静默吞掉。
      <String, Object?>{'builtin': <String, bool>{'nyaa': false}},
      // RSS 模板：缺 {query} / 非 http(s) / 明文 HTTP 未放行 / 带 user info。
      <String, Object?>{'rss': <Object?>[goodRss(), <String, Object?>{'name': 'n', 'urlTemplate': 'https://x.example/rss?q=fixed'}]},
      <String, Object?>{'rss': <Object?>[<String, Object?>{'name': 'f', 'urlTemplate': 'ftp://x.example/{query}'}]},
      <String, Object?>{'rss': <Object?>[<String, Object?>{'name': 'h', 'urlTemplate': 'http://x.example/rss?q={query}'}]},
      <String, Object?>{'rss': <Object?>[<String, Object?>{'name': 'u', 'urlTemplate': 'https://u:p@x.example/rss?q={query}'}]},
      <String, Object?>{'rss': <Object?>[<String, Object?>{'name': '', 'urlTemplate': 'https://x.example/rss?q={query}'}]},
      <String, Object?>{'rss': <Object?>[<String, Object?>{'name': 'd', 'urlTemplate': 'https://x.example/rss?q={query}', 'domains': <String>['music']}]},
      <String, Object?>{'rss': <Object?>[<String, Object?>{'id': 'r', ...goodRss()}, <String, Object?>{'id': 'r', ...goodRss()}]},
      <String, Object?>{'rss': <Object?>[<String, Object?>{'id': 'r:1', ...goodRss()}]},
      <String, Object?>{'rss': 'nope'},
    ];
    for (final Map<String, Object?> body in bad) {
      final ({int status, Map<String, dynamic> json, String raw}) r = await call(api, 'PUT', body);
      expect(r.status, 400, reason: '${jsonEncode(body)} → ${r.raw}');
      expect(rawPref(kVideoResourceTorznabConfigPref), beforeTorznab, reason: jsonEncode(body));
      expect(rawPref(kResourceRssSitesPref), beforeRss, reason: jsonEncode(body));
    }

    // 显式允许明文 HTTP 的局域网 indexer / RSS 站是合法的（与 app 同一判据）。
    final ({int status, Map<String, dynamic> json, String raw}) lan = await call(api, 'PUT', <String, Object?>{
      'torznab': <Object?>[<String, Object?>{'name': 'lan', 'endpoint': 'http://192.168.1.2:9117/api', 'allowInsecureHttp': true}],
      'rss': <Object?>[<String, Object?>{'name': 'lan', 'urlTemplate': 'http://192.168.1.2/rss?q={query}&p={page}', 'allowInsecureHttp': true}],
    });
    expect(lan.status, 200, reason: lan.raw);
  });

  group('运行中的下载 host', () {
    late ServerDownloadHost downloads;
    late ServerVideoScrape scrape;

    setUp(() async {
      // qBittorrent 只配地址：start 只起管线、不连后端（后端按任务懒解析）。
      final ServerConfig config = ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
        torrentEngine: ServerConfig.torrentEngineQbittorrent,
        qbittorrentUrl: 'http://127.0.0.1:9',
      );
      final ServerPaths paths = ServerPaths(config.dataDir);
      await paths.ensureLayout();
      scrape = ServerVideoScrape(db: db, prefs: prefs, config: () => config);
      downloads = ServerDownloadHost(
        config: config,
        paths: paths,
        db: db,
        prefs: prefs,
        identity: await ServerIdentity.loadOrCreate(prefs),
        scrape: scrape,
      );
      await downloads.start();
    });

    tearDown(() async {
      await downloads.stop();
      scrape.close();
    });

    Future<List<String>> providers(HostSubscriptionHost host) async =>
        List<String>.from((await host.capability())['providers']! as List);

    test('保存后 registry 立即换新：早先捕获的订阅面能力位与在场校验都跟着新配置', () async {
      // 互联 server 启动时捕获的就是这个对象；重载后不重新取。
      final HostSubscriptionHost captured = downloads.subscriptions;
      expect(await providers(captured), isEmpty, reason: '不内置任何搜索站：没配就没有可订阅的源');
      expect((await captured.capability())['supported'], isTrue);

      await writeRssSearchSiteConfigs(prefs, <RssSearchSiteConfig>[
        RssSearchSiteConfig(id: 'nyaa-rss', name: 'Nyaa', urlTemplate: 'https://nyaa.si/?page=rss&q={query}', domains: <RssSearchDomain>[RssSearchDomain.anime]),
        // 停用的站与只勾了非视频域的站都不参与订阅，能力位不报。
        RssSearchSiteConfig(id: 'off', name: 'Off', urlTemplate: 'https://off.example/rss?q={query}', enabled: false, domains: <RssSearchDomain>[RssSearchDomain.anime]),
        RssSearchSiteConfig(id: 'books', name: 'Books', urlTemplate: 'https://books.example/rss?q={query}', domains: <RssSearchDomain>[RssSearchDomain.novel]),
      ]);
      await writeTorznabIndexerConfigs(prefs, <TorznabIndexerConfig>[
        TorznabIndexerConfig(id: 'idx1', name: 'One', endpoint: Uri.parse('https://one.example/api'), apiKey: 'k'),
      ]);
      await downloads.reloadResourceIndexers();

      expect(await providers(captured), <String>['rss:nyaa-rss', 'torznab:idx1']);
      expect(downloads.availableResourceProviderIds, <String>['rss:nyaa-rss', 'torznab:idx1']);
      expect((await captured.capability())['supported'], isTrue, reason: '管线与订阅服务已按新 registry 重启');
      // host 上没有的 RSS 站（客户端自己配的）拒建，而不是建出一条永远搜不到的订阅。
      await expectLater(
        captured.create(const HostSubscriptionCreateRequest(
          title: 'X',
          searchQuery: 'X 1080p',
          mediaKind: 'tv',
          resourceProvider: 'rss:off',
        )),
        throwsA(isA<HostSubscriptionRejected>().having((HostSubscriptionRejected e) => e.reason, 'reason', 'provider_unavailable')),
      );
      // 已移除的内置源：明确的 provider_removed，而不是「没配置」。
      await expectLater(
        captured.create(const HostSubscriptionCreateRequest(
          title: 'X',
          searchQuery: 'X 1080p',
          mediaKind: 'tv',
          resourceProvider: 'nyaa:nyaa.si',
        )),
        throwsA(isA<HostSubscriptionRejected>().having((HostSubscriptionRejected e) => e.reason, 'reason', 'provider_removed')),
      );

      // 连续两次保存串行执行，终态以最后一次为准。
      await writeRssSearchSiteConfigs(prefs, const <RssSearchSiteConfig>[]);
      final Future<void> a = downloads.reloadResourceIndexers();
      await writeTorznabIndexerConfigs(prefs, const <TorznabIndexerConfig>[]);
      final Future<void> b = downloads.reloadResourceIndexers();
      await Future.wait(<Future<void>>[a, b]);
      expect(await providers(captured), isEmpty);
    });
  });
}
