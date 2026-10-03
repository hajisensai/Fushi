import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
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

/// admin API 的资源索引器面（内置源启停 + Torznab）：读写往返与 app 同一存储格式、
/// API key 不回显 / 留空不改、非法输入 400 不落半截，以及保存后对正在跑的
/// 下载 host 立即生效（registry 换新、互联 server 早先捕获的订阅面跟着变）。
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

  test('GET 默认：三个内置源全开、没有 Torznab、host 未运行时 applied=false', () async {
    final AdminApi api = await buildApi();
    final (:int status, :Map<String, dynamic> json, raw: _) = await call(api, 'GET');
    expect(status, 200);
    expect(
      (json['builtin'] as List).map((Object? b) => (b! as Map)['id']).toList(),
      <String>['nyaa', 'apibay', 'knaben'],
    );
    expect((json['builtin'] as List).every((Object? b) => (b! as Map)['enabled'] == true), isTrue);
    expect(json['torznab'], isEmpty);
    expect(json['applied'], isFalse);
    expect(json['providers'], isNull);
  });

  test('PUT 往返：与 app 同一编码落库；key 从 ?apikey= 拆出、永不回显；留空沿用、clearApiKey 才清', () async {
    final AdminApi api = await buildApi();
    final ({int status, Map<String, dynamic> json, String raw}) saved = await call(api, 'PUT', <String, Object?>{
      'builtin': <String, bool>{'apibay': false},
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
    expect(
      (saved.json['builtin'] as List).firstWhere((Object? b) => (b! as Map)['id'] == 'apibay'),
      containsPair('enabled', false),
    );

    // 存储格式 = app 的读侧能直接解（同一个 reader），停用清单是排序逗号串。
    expect(rawPref(kVideoResourceDisabledSourcesPref), 'apibay');
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
    expect(rawPref(kVideoResourceDisabledSourcesPref), 'apibay', reason: '没带 builtin = 不改停用清单');

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
    await writeVideoResourceDisabledSourceIds(prefs, <String>['knaben']);
    await writeTorznabIndexerConfigs(prefs, <TorznabIndexerConfig>[
      TorznabIndexerConfig(id: 'keep', name: 'Keep', endpoint: Uri.parse('https://keep.example/api'), apiKey: 'k'),
    ]);
    final String? beforeTorznab = rawPref(kVideoResourceTorznabConfigPref);
    final String? beforeDisabled = rawPref(kVideoResourceDisabledSourcesPref);

    Map<String, Object?> good() => <String, Object?>{'name': 'OK', 'endpoint': 'https://ok.example/api'};
    final List<Map<String, Object?>> bad = <Map<String, Object?>>[
      // 第二条非法：前一条合法也不能落。
      <String, Object?>{'builtin': <String, bool>{'nyaa': false}, 'torznab': <Object?>[good(), <String, Object?>{'name': 'x', 'endpoint': 'ftp://x.example/api'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': 'lan', 'endpoint': 'http://192.168.1.2:9117/api'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': 'q', 'endpoint': 'https://x.example/api?t=search'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': '', 'endpoint': 'https://x.example/api'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': 'c', 'endpoint': 'https://x.example/api', 'categories': '5070,-1'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'name': 'p', 'endpoint': 'https://x.example/api', 'priority': 'high'}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'id': 'a', ...good()}, <String, Object?>{'id': 'a', ...good()}]},
      <String, Object?>{'torznab': <Object?>[<String, Object?>{'id': 'a:b', ...good()}]},
      <String, Object?>{'builtin': <String, bool>{'bangumi': false}},
      <String, Object?>{'builtin': <String, Object?>{'nyaa': 'off'}},
      <String, Object?>{'torznab': 'nope'},
    ];
    for (final Map<String, Object?> body in bad) {
      final ({int status, Map<String, dynamic> json, String raw}) r = await call(api, 'PUT', body);
      expect(r.status, 400, reason: '${jsonEncode(body)} → ${r.raw}');
      expect(rawPref(kVideoResourceTorznabConfigPref), beforeTorznab, reason: jsonEncode(body));
      expect(rawPref(kVideoResourceDisabledSourcesPref), beforeDisabled, reason: jsonEncode(body));
    }

    // 显式允许明文 HTTP 的局域网 indexer 是合法的（与 app 同一判据）。
    final ({int status, Map<String, dynamic> json, String raw}) lan = await call(api, 'PUT', <String, Object?>{
      'torznab': <Object?>[<String, Object?>{'name': 'lan', 'endpoint': 'http://192.168.1.2:9117/api', 'allowInsecureHttp': true}],
    });
    expect(lan.status, 200, reason: lan.raw);
  });

  test('停用清单里服务端不认识的 id（新版 app 同步来的）原样保留', () async {
    final AdminApi api = await buildApi();
    await prefs.setPref(kVideoResourceDisabledSourcesPref, 'future-src');
    final ({int status, Map<String, dynamic> json, String raw}) r = await call(api, 'PUT', <String, Object?>{
      'builtin': <String, bool>{'nyaa': false, 'apibay': true},
    });
    expect(r.status, 200, reason: r.raw);
    expect(rawPref(kVideoResourceDisabledSourcesPref), 'future-src,nyaa');
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
      expect(await providers(captured), <String>['nyaa', 'apibay', 'knaben']);
      expect((await captured.capability())['supported'], isTrue);

      await writeVideoResourceDisabledSourceIds(prefs, <String>['apibay']);
      await writeTorznabIndexerConfigs(prefs, <TorznabIndexerConfig>[
        TorznabIndexerConfig(id: 'idx1', name: 'One', endpoint: Uri.parse('https://one.example/api'), apiKey: 'k'),
      ]);
      await downloads.reloadResourceIndexers();

      expect(await providers(captured), <String>['nyaa', 'knaben', 'torznab:idx1']);
      expect(downloads.availableResourceProviderIds, <String>['nyaa', 'knaben', 'torznab:idx1']);
      expect((await captured.capability())['supported'], isTrue, reason: '管线与订阅服务已按新 registry 重启');
      await expectLater(
        captured.create(const HostSubscriptionCreateRequest(
          title: 'X',
          searchQuery: 'X 1080p',
          mediaKind: 'tv',
          resourceProvider: 'apibay',
        )),
        throwsA(isA<HostSubscriptionRejected>().having((HostSubscriptionRejected e) => e.reason, 'reason', 'provider_unavailable')),
      );

      // 连续两次保存串行执行，终态以最后一次为准。
      await writeVideoResourceDisabledSourceIds(prefs, const <String>[]);
      final Future<void> a = downloads.reloadResourceIndexers();
      await writeTorznabIndexerConfigs(prefs, const <TorznabIndexerConfig>[]);
      final Future<void> b = downloads.reloadResourceIndexers();
      await Future.wait(<Future<void>>[a, b]);
      expect(await providers(captured), <String>['nyaa', 'apibay', 'knaben']);
    });
  });
}
