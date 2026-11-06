import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/torrent/bt_site_config.dart';
import 'package:fushi_engine/media/torrent/torznab_client.dart';
import 'package:fushi_engine/media/torrent/video_resource_provider.dart';
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
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

/// 分类下拉式 HTML 搜索页（只有动画与真人两个大类）。
const String _categoryPageHtml = '''<!doctype html><html><body>
<form><select name="c">
<option value="0_0" title="All categories" selected>All categories</option>
<option value="1_0" title="Anime">Anime</option>
<option value="1_2" title="Anime - English">- English-translated</option>
<option value="4_0" title="Live Action">Live Action</option>
</select></form><h3>No results found</h3></body></html>''';

/// 假站点群（按主机名分）：
/// - `html.example.com`：GET `/?q=…` 回带分类下拉的搜索页；
/// - `json.example.com`：GET `/q.php` 回首项带 info_hash / name 的 JSON 数组；
/// - `post.example.com`：POST `/v1` 回 `{"hits": []}`；
/// - 其它（如 `blank.example.com`）：一张什么结构都没有的普通网页。
http.Response _fakeSites(http.Request request) {
  final Uri u = request.url;
  switch (u.host) {
    case 'html.example.com'
        when request.method == 'GET' &&
            u.path == '/' &&
            u.queryParameters['q'] != null:
      return http.Response(
        _categoryPageHtml,
        200,
        headers: const <String, String>{
          'content-type': 'text/html; charset=utf-8',
        },
      );
    case 'json.example.com' when request.method == 'GET' && u.path == '/q.php':
      return http.Response(
        jsonEncode(<Object?>[
          <String, Object?>{
            'id': '1',
            'name': 'x',
            'info_hash': 'ABCDEF0123456789ABCDEF0123456789ABCDEF01',
          },
        ]),
        200,
      );
    case 'post.example.com' when request.method == 'POST' && u.path == '/v1':
      return http.Response(
        jsonEncode(<String, Object?>{'hits': <Object?>[]}),
        200,
      );
    case 'blank.example.com':
      return http.Response(
        '<html><body>hello</body></html>',
        200,
        headers: const <String, String>{
          'content-type': 'text/html; charset=utf-8',
        },
      );
  }
  return http.Response('not found', 404);
}

/// admin API 的资源索引器面（用户 BT 站 + Torznab）：BT 站增删改与自动探测（不回显地址
/// 整串 / 接口格式、探测失败文案中性）、Torznab 读写往返与 app 同一存储格式、API key 不回显
/// / 留空不改、非法输入 400 不落半截，以及保存后对正在跑的下载 host 立即生效（registry
/// 换新、互联 server 早先捕获的订阅面跟着变）。
void main() {
  late Directory tmp;
  late FushiDatabase db;
  late ServerPrefs prefs;
  late List<http.Request> probeRequests;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('fushi_admin_ri_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    prefs = ServerPrefs(db);
    probeRequests = <http.Request>[];
  });

  tearDown(() async {
    await db.close();
    await tmp.delete(recursive: true);
  });

  Future<AdminApi> buildApi() async {
    final ServerConfig config = ServerConfig.defaults(
      dataDir: p.join(tmp.path, 'data'),
    ).copyWith(adminToken: 'tok');
    final File configFile = File(p.join(tmp.path, 'fushi_server.yaml'));
    await config.save(configFile);
    final ServerIdentity identity = await ServerIdentity.loadOrCreate(prefs);
    final ServerPaths paths = ServerPaths(config.dataDir);
    final HeadlessHost host = HeadlessHost(
      config: config,
      paths: paths,
      db: db,
      prefs: prefs,
      identity: identity,
    );
    return AdminApi(
      AdminContext(
        config: config,
        configFile: configFile,
        paths: paths,
        log: ServerLog(file: File(p.join(tmp.path, 'server.log'))),
        db: db,
        identity: identity,
        host: host,
        startedAt: DateTime.now(),
      ),
      btSiteProbeClient: () => MockClient((http.Request r) async {
        probeRequests.add(r);
        return _fakeSites(r);
      }),
    );
  }

  Future<({int status, Map<String, dynamic> json, String raw})> call(
    AdminApi api,
    String method, [
    Object? body,
    String sub = '',
  ]) async {
    final shelf.Response r = await api.handle(
      shelf.Request(
        method,
        Uri.parse('http://localhost/api/admin/resource-indexers$sub'),
        body: body == null ? null : jsonEncode(body),
      ),
    );
    final String raw = await r.readAsString();
    return (
      status: r.statusCode,
      json: Map<String, dynamic>.from(jsonDecode(raw) as Map),
      raw: raw,
    );
  }

  String? rawPref(String key) => prefs.getPref(key) as String?;

  test('GET 默认：没有 BT 站、没有 Torznab、没有内置源；host 未运行时 applied=false', () async {
    final AdminApi api = await buildApi();
    final (:int status, :Map<String, dynamic> json, raw: _) = await call(
      api,
      'GET',
    );
    expect(status, 200);
    expect(json['btSites'], isEmpty);
    expect(json.containsKey('builtin'), isFalse);
    expect(json['torznab'], isEmpty);
    expect(json['applied'], isFalse);
    expect(json['providers'], isNull);
  });

  group('BT 站', () {
    test('添加：自动探测成功才落库；只回显主机名与名称，不回显地址整串 / query / 接口格式', () async {
      final AdminApi api = await buildApi();
      final ({int status, Map<String, dynamic> json, String raw}) r =
          await call(api, 'POST', <String, Object?>{
            'url': 'https://html.example.com/?passkey=SECRET-PASS',
            'name': ' Mine ',
            'domains': <String>['anime', 'movie', 'tv', 'game'],
          }, '/bt-sites');
      expect(r.status, 200, reason: r.raw);
      expect(r.raw, isNot(contains('SECRET-PASS')));
      expect(r.raw, isNot(contains('html.example.com/')), reason: '不回显地址整串');
      final Map<String, dynamic> site = Map<String, dynamic>.from(
        r.json['site'] as Map,
      );
      expect(site.keys, isNot(contains('format')));
      expect(site.keys, isNot(contains('url')));
      expect(site['name'], 'Mine');
      expect(site['displayName'], 'Mine');
      expect(site['host'], 'html.example.com');
      expect(site['domains'], <String>['anime', 'movie', 'tv', 'game']);
      // 站点下拉里没有游戏分类：勾了也不生效，如实报出来。
      expect(site['effectiveDomains'], <String>['anime', 'movie', 'tv']);
      expect(site['enabled'], isTrue);
      expect(site['active'], isNull, reason: 'host 未运行时运行态未知');
      expect((r.json['btSites'] as List).single, site);

      // 存储 = app 同一份 codec；格式是内部字段（落库但不出境）。
      final BtSiteConfig stored = readBtSiteConfigs(prefs).single;
      expect(stored.id, site['id']);
      expect(isValidBtSiteId(stored.id), isTrue);
      expect(stored.format, BtSiteFormat.nyaa);
      expect(stored.baseUrl.query, isEmpty);
      expect(stored.nyaaCategories[BtSiteDomain.anime], '1_0');
      expect(probeRequests, isNotEmpty);
    });

    test('添加：省略 domains = 全部媒体域；接口只服务电影 / 剧集的站点如实报生效域', () async {
      final AdminApi api = await buildApi();
      final ({int status, Map<String, dynamic> json, String raw}) r =
          await call(api, 'POST', <String, Object?>{
            'url': 'json.example.com',
          }, '/bt-sites');
      expect(r.status, 200, reason: r.raw);
      final Map<String, dynamic> site = Map<String, dynamic>.from(
        r.json['site'] as Map,
      );
      expect(
        site['domains'],
        BtSiteDomain.values.map((BtSiteDomain d) => d.name).toList(),
      );
      expect(site['effectiveDomains'], <String>['movie', 'tv']);
      expect(site['displayName'], 'json.example.com');
      expect(readBtSiteConfigs(prefs).single.format, BtSiteFormat.apibay);

      final ({int status, Map<String, dynamic> json, String raw}) post =
          await call(api, 'POST', <String, Object?>{
            'url': 'https://post.example.com',
            'domains': <String>['movie'],
          }, '/bt-sites');
      expect(post.status, 200, reason: post.raw);
      expect(
        readBtSiteConfigs(prefs).map((BtSiteConfig s) => s.format),
        <BtSiteFormat>[BtSiteFormat.apibay, BtSiteFormat.knaben],
      );
      expect((post.json['btSites'] as List).length, 2);
    });

    test('认不出 / 地址非法 / 明文 HTTP：422 + 中性文案，一个字节都不写', () async {
      final AdminApi api = await buildApi();
      final ({int status, Map<String, dynamic> json, String raw}) r =
          await call(api, 'POST', <String, Object?>{
            'url': 'https://blank.example.com',
          }, '/bt-sites');
      expect(r.status, 422, reason: r.raw);
      expect(r.json['reason'], 'unrecognized');
      expect(r.json['error'], 'Unable to recognize this site');
      for (final String word in <String>[
        'nyaa',
        'apibay',
        'knaben',
        'sukebei',
        'pirate',
        'format',
      ]) {
        expect(
          r.raw.toLowerCase(),
          isNot(contains(word)),
          reason: '探测失败文案不得提站名 / 格式',
        );
      }
      expect(rawPref(kResourceBtSitesPref), isNull);

      final ({int status, Map<String, dynamic> json, String raw}) insecure =
          await call(api, 'POST', <String, Object?>{
            'url': 'http://html.example.com',
          }, '/bt-sites');
      expect(insecure.status, 422, reason: insecure.raw);
      expect(insecure.json['reason'], 'insecureHttp');

      final ({int status, Map<String, dynamic> json, String raw}) invalid =
          await call(api, 'POST', <String, Object?>{
            'url': 'ftp://html.example.com',
          }, '/bt-sites');
      expect(invalid.status, 422, reason: invalid.raw);
      expect(invalid.json['reason'], 'invalidUrl');

      for (final Map<String, Object?> body in <Map<String, Object?>>[
        <String, Object?>{},
        <String, Object?>{
          'url': 'https://html.example.com',
          'domains': <String>[],
        },
        <String, Object?>{
          'url': 'https://html.example.com',
          'domains': <String>['podcast'],
        },
        <String, Object?>{'url': 'https://html.example.com', 'enabled': 'yes'},
      ]) {
        final ({int status, Map<String, dynamic> json, String raw}) bad =
            await call(api, 'POST', body, '/bt-sites');
        expect(bad.status, 400, reason: '${jsonEncode(body)} → ${bad.raw}');
      }
      expect(rawPref(kResourceBtSitesPref), isNull);
    });

    test('编辑：不带地址不探测；带新地址重新探测，认不出则不改；重新检测；删除', () async {
      final AdminApi api = await buildApi();
      final String id =
          ((await call(api, 'POST', <String, Object?>{
                    'url': 'https://html.example.com',
                    'domains': <String>['anime'],
                  }, '/bt-sites')).json['site']
                  as Map)['id']
              as String;

      probeRequests.clear();
      final ({int status, Map<String, dynamic> json, String raw}) edited =
          await call(api, 'PUT', <String, Object?>{
            'name': 'Renamed',
            'domains': <String>['anime', 'tv'],
            'enabled': false,
          }, '/bt-sites/$id');
      expect(edited.status, 200, reason: edited.raw);
      expect(probeRequests, isEmpty, reason: '没改地址不重新探测');
      final BtSiteConfig afterEdit = readBtSiteConfigs(prefs).single;
      expect(afterEdit.name, 'Renamed');
      expect(afterEdit.domains, <BtSiteDomain>{
        BtSiteDomain.anime,
        BtSiteDomain.tv,
      });
      expect(afterEdit.enabled, isFalse);
      expect(afterEdit.format, BtSiteFormat.nyaa);

      final String before = rawPref(kResourceBtSitesPref)!;
      final ({int status, Map<String, dynamic> json, String raw}) badUrl =
          await call(api, 'PUT', <String, Object?>{
            'url': 'https://blank.example.com',
          }, '/bt-sites/$id');
      expect(badUrl.status, 422, reason: badUrl.raw);
      expect(rawPref(kResourceBtSitesPref), before);

      final ({int status, Map<String, dynamic> json, String raw}) moved =
          await call(api, 'PUT', <String, Object?>{
            'url': 'https://json.example.com',
          }, '/bt-sites/$id');
      expect(moved.status, 200, reason: moved.raw);
      final BtSiteConfig afterMove = readBtSiteConfigs(prefs).single;
      expect(afterMove.id, id, reason: '换地址不换身份（订阅按 id 记）');
      expect(afterMove.format, BtSiteFormat.apibay);
      expect(afterMove.name, 'Renamed');
      expect(afterMove.enabled, isFalse);

      probeRequests.clear();
      final ({int status, Map<String, dynamic> json, String raw}) reprobed =
          await call(api, 'POST', null, '/bt-sites/$id/reprobe');
      expect(reprobed.status, 200, reason: reprobed.raw);
      expect(probeRequests, isNotEmpty);
      expect(readBtSiteConfigs(prefs).single.format, BtSiteFormat.apibay);

      expect(
        (await call(api, 'PUT', <String, Object?>{
          'name': 'x',
        }, '/bt-sites/nope')).status,
        404,
      );
      expect(
        (await call(api, 'POST', null, '/bt-sites/nope/reprobe')).status,
        404,
      );
      expect((await call(api, 'DELETE', null, '/bt-sites/nope')).status, 404);

      final ({int status, Map<String, dynamic> json, String raw}) removed =
          await call(api, 'DELETE', null, '/bt-sites/$id');
      expect(removed.status, 200, reason: removed.raw);
      expect(removed.json['btSites'], isEmpty);
      expect(readBtSiteConfigs(prefs), isEmpty);
    });

    test('编辑：关掉明文放行而地址仍是明文 → 400 不落库', () async {
      final AdminApi api = await buildApi();
      await writeBtSiteConfigs(prefs, <BtSiteConfig>[
        BtSiteConfig(
          id: 'lan',
          baseUrl: Uri.parse('http://192.168.1.2:8080'),
          format: BtSiteFormat.apibay,
          domains: <BtSiteDomain>{BtSiteDomain.movie},
          allowInsecureHttp: true,
        ),
      ]);
      final String before = rawPref(kResourceBtSitesPref)!;
      final ({int status, Map<String, dynamic> json, String raw}) r =
          await call(api, 'PUT', <String, Object?>{
            'allowInsecureHttp': false,
          }, '/bt-sites/lan');
      expect(r.status, 400, reason: r.raw);
      expect(rawPref(kResourceBtSitesPref), before);
    });
  });

  test(
    'PUT 往返：与 app 同一编码落库；key 从 ?apikey= 拆出、永不回显；留空沿用、clearApiKey 才清',
    () async {
      final AdminApi api = await buildApi();
      final ({int status, Map<String, dynamic> json, String raw})
      saved = await call(api, 'PUT', <String, Object?>{
        'torznab': <Object?>[
          <String, Object?>{
            'name': ' Jackett ',
            'endpoint':
                'https://idx.example/api/v2.0/indexers/all/results/torznab/api?apikey=SECRET-KEY',
            'priority': 5,
            'categories': '5070, 2000',
          },
        ],
      });
      expect(saved.status, 200, reason: saved.raw);
      expect(
        saved.raw,
        isNot(contains('SECRET-KEY')),
        reason: 'API key 不得出现在响应里',
      );
      final Map<String, dynamic> row = Map<String, dynamic>.from(
        (saved.json['torznab'] as List).single as Map,
      );
      expect(row['name'], 'Jackett');
      expect(
        row['endpoint'],
        'https://idx.example/api/v2.0/indexers/all/results/torznab/api',
      );
      expect(row['apiKeySet'], isTrue);
      expect(row.containsKey('apiKey'), isFalse);
      expect(row['priority'], 5);
      expect(row['categories'], <int>[5070, 2000]);
      expect((row['id'] as String).startsWith('torznab-'), isTrue);

      // 存储格式 = app 的读侧能直接解（同一个 reader）。
      final List<TorznabIndexerConfig> stored = readTorznabIndexerConfigs(
        prefs,
      );
      expect(stored.single.apiKey, 'SECRET-KEY');
      expect(
        jsonDecode(rawPref(kVideoResourceTorznabConfigPref)!),
        encodeTorznabIndexerConfigs(stored),
      );

      // 同 id 再存、key 留空 → 沿用旧 key；改名照常生效。
      final String id = row['id'] as String;
      final ({int status, Map<String, dynamic> json, String raw}) kept =
          await call(api, 'PUT', <String, Object?>{
            'torznab': <Object?>[
              <String, Object?>{
                'id': id,
                'name': 'Renamed',
                'endpoint': row['endpoint'],
                'apiKey': '',
              },
            ],
          });
      expect(kept.status, 200, reason: kept.raw);
      expect(readTorznabIndexerConfigs(prefs).single.apiKey, 'SECRET-KEY');
      expect(readTorznabIndexerConfigs(prefs).single.name, 'Renamed');

      final ({int status, Map<String, dynamic> json, String raw}) cleared =
          await call(api, 'PUT', <String, Object?>{
            'torznab': <Object?>[
              <String, Object?>{
                'id': id,
                'name': 'Renamed',
                'endpoint': row['endpoint'],
                'clearApiKey': true,
              },
            ],
          });
      expect(cleared.status, 200, reason: cleared.raw);
      expect(readTorznabIndexerConfigs(prefs).single.apiKey, '');
      expect(
        ((cleared.json['torznab'] as List).single as Map)['apiKeySet'],
        isFalse,
      );
    },
  );

  test('非法输入一律 400，且偏好一个字节都不动（旧的 builtin 开关明确拒绝）', () async {
    final AdminApi api = await buildApi();
    await writeTorznabIndexerConfigs(prefs, <TorznabIndexerConfig>[
      TorznabIndexerConfig(
        id: 'keep',
        name: 'Keep',
        endpoint: Uri.parse('https://keep.example/api'),
        apiKey: 'k',
      ),
    ]);
    final String? beforeTorznab = rawPref(kVideoResourceTorznabConfigPref);

    Map<String, Object?> good() => <String, Object?>{
      'name': 'OK',
      'endpoint': 'https://ok.example/api',
    };
    final List<Map<String, Object?>> bad = <Map<String, Object?>>[
      // 第二条非法：前一条合法也不能落。
      <String, Object?>{
        'torznab': <Object?>[
          good(),
          <String, Object?>{'name': 'x', 'endpoint': 'ftp://x.example/api'},
        ],
      },
      <String, Object?>{
        'torznab': <Object?>[
          <String, Object?>{
            'name': 'lan',
            'endpoint': 'http://192.168.1.2:9117/api',
          },
        ],
      },
      <String, Object?>{
        'torznab': <Object?>[
          <String, Object?>{
            'name': 'q',
            'endpoint': 'https://x.example/api?t=search',
          },
        ],
      },
      <String, Object?>{
        'torznab': <Object?>[
          <String, Object?>{'name': '', 'endpoint': 'https://x.example/api'},
        ],
      },
      <String, Object?>{
        'torznab': <Object?>[
          <String, Object?>{
            'name': 'c',
            'endpoint': 'https://x.example/api',
            'categories': '5070,-1',
          },
        ],
      },
      <String, Object?>{
        'torznab': <Object?>[
          <String, Object?>{
            'name': 'p',
            'endpoint': 'https://x.example/api',
            'priority': 'high',
          },
        ],
      },
      <String, Object?>{
        'torznab': <Object?>[
          <String, Object?>{'id': 'a', ...good()},
          <String, Object?>{'id': 'a', ...good()},
        ],
      },
      <String, Object?>{
        'torznab': <Object?>[
          <String, Object?>{'id': 'a:b', ...good()},
        ],
      },
      <String, Object?>{
        'builtin': <String, bool>{'x': false},
        'torznab': <Object?>[good()],
      },
      <String, Object?>{'torznab': 'nope'},
    ];
    for (final Map<String, Object?> body in bad) {
      final ({int status, Map<String, dynamic> json, String raw}) r =
          await call(api, 'PUT', body);
      expect(r.status, 400, reason: '${jsonEncode(body)} → ${r.raw}');
      expect(
        rawPref(kVideoResourceTorznabConfigPref),
        beforeTorznab,
        reason: jsonEncode(body),
      );
    }

    // 显式允许明文 HTTP 的局域网 indexer 是合法的（与 app 同一判据）。
    final ({int status, Map<String, dynamic> json, String raw}) lan =
        await call(api, 'PUT', <String, Object?>{
          'torznab': <Object?>[
            <String, Object?>{
              'name': 'lan',
              'endpoint': 'http://192.168.1.2:9117/api',
              'allowInsecureHttp': true,
            },
          ],
        });
    expect(lan.status, 200, reason: lan.raw);
  });

  group('运行中的下载 host', () {
    late ServerDownloadHost downloads;
    late ServerVideoScrape scrape;

    // `.invalid` 保留域名：万一真发出搜索请求也只会立即解析失败，不碰外网。
    BtSiteConfig categorySite(
      String id,
      Set<BtSiteDomain> domains, {
      bool enabled = true,
    }) => BtSiteConfig(
      id: id,
      name: 'Site $id',
      baseUrl: Uri.parse('https://$id.invalid'),
      format: BtSiteFormat.nyaa,
      domains: domains,
      nyaaCategories: const <BtSiteDomain, String>{
        BtSiteDomain.anime: '1_0',
        BtSiteDomain.tv: '4_0',
        BtSiteDomain.novel: '3_0',
      },
      enabled: enabled,
    );

    Future<void> startDownloads() async {
      // qBittorrent 只配地址：start 只起管线、不连后端（后端按任务懒解析）。
      final ServerConfig config =
          ServerConfig.defaults(dataDir: p.join(tmp.path, 'data')).copyWith(
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
    }

    tearDown(() async {
      await downloads.stop();
      scrape.close();
    });

    Future<List<String>> providers(HostSubscriptionHost host) async =>
        List<String>.from((await host.capability())['providers']! as List);

    test('装配从 resource_bt_sites 偏好读站点：只注册启用且对视频域生效的站点，没有站点就没有 BT 来源', () async {
      await writeBtSiteConfigs(prefs, <BtSiteConfig>[
        categorySite('a', <BtSiteDomain>{BtSiteDomain.anime}),
        categorySite('off', <BtSiteDomain>{BtSiteDomain.anime}, enabled: false),
        categorySite('books', <BtSiteDomain>{BtSiteDomain.novel}),
      ]);
      await startDownloads();
      expect(downloads.activeBtSiteIds, <String>['a']);
      expect(
        downloads.registry!.providers.map((VideoResourceProvider p) => p.id),
        <String>['nyaa:a'],
      );
      expect(await providers(downloads.subscriptions), <String>['nyaa']);

      await writeBtSiteConfigs(prefs, const <BtSiteConfig>[]);
      await downloads.reloadResourceIndexers();
      expect(downloads.activeBtSiteIds, isEmpty);
      expect(
        await providers(downloads.subscriptions),
        isEmpty,
        reason: 'Fushi 不内置任何 BT 站',
      );
    });

    test('保存后 registry 立即换新：早先捕获的订阅面能力位与在场校验都跟着新配置', () async {
      await startDownloads();
      // 互联 server 启动时捕获的就是这个对象；重载后不重新取。
      final HostSubscriptionHost captured = downloads.subscriptions;
      expect(await providers(captured), isEmpty);
      expect((await captured.capability())['supported'], isTrue);

      await writeBtSiteConfigs(prefs, <BtSiteConfig>[
        categorySite('a', <BtSiteDomain>{BtSiteDomain.anime, BtSiteDomain.tv}),
      ]);
      await writeTorznabIndexerConfigs(prefs, <TorznabIndexerConfig>[
        TorznabIndexerConfig(
          id: 'idx1',
          name: 'One',
          endpoint: Uri.parse('https://one.example/api'),
          apiKey: 'k',
        ),
      ]);
      await downloads.reloadResourceIndexers();

      expect(await providers(captured), <String>['nyaa', 'torznab:idx1']);
      expect(downloads.availableResourceProviderIds, <String>[
        'nyaa',
        'torznab:idx1',
      ]);
      expect(
        (await captured.capability())['supported'],
        isTrue,
        reason: '管线与订阅服务已按新 registry 重启',
      );
      // 没有同格式站点的旧内置 provider id 订阅不进来。
      await expectLater(
        captured.create(
          const HostSubscriptionCreateRequest(
            title: 'X',
            searchQuery: 'X 1080p',
            mediaKind: 'tv',
            resourceProvider: 'apibay',
          ),
        ),
        throwsA(
          isA<HostSubscriptionRejected>().having(
            (HostSubscriptionRejected e) => e.reason,
            'reason',
            'provider_unavailable',
          ),
        ),
      );

      // 连续两次保存串行执行，终态以最后一次为准。
      await writeBtSiteConfigs(prefs, const <BtSiteConfig>[]);
      final Future<void> a = downloads.reloadResourceIndexers();
      await writeTorznabIndexerConfigs(prefs, const <TorznabIndexerConfig>[]);
      final Future<void> b = downloads.reloadResourceIndexers();
      await Future.wait(<Future<void>>[a, b]);
      expect(await providers(captured), isEmpty);
    });
  });
}
