/// OPDS 发现源对真实 Komga 1.29.1 的兼容契约（BUG-3526 / 3535 / 3521）。
///
/// fixture `test/fixtures/opds/komga/` 是从真 Komga 1.29.1 抓下来的原始响应
/// （v1.2 根目录 / 系列页、v2 根目录 / 系列页），不是手写的「理想 OPDS」——
/// 本文件钉的几条行为恰恰都是理想 feed 里不会出现的服务端方言：
/// - 根地址回 200 HTML、带结尾斜杠回 404，只有 `/opds/v2/catalog`、
///   `/opds/v1.2/catalog` 是目录（BUG-3526）；
/// - 封面无凭据回 401（BUG-3535）；
/// - API key 只认 `X-API-Key` 头（BUG-3521）；
/// - v1.2 的 acquisition 一律标 `application/zip`；v2 作者放在 `contributor`。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:fushi/src/media/discovery/opds_server_config.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_atom_parser.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_feed.dart';
import 'package:fushi/src/media/discovery/sources/opds/opds_json_parser.dart';
import 'package:fushi/src/media/discovery/sources/opds_discovery_source.dart';
import 'package:fushi_engine/media/discovery/discovery_models.dart';
import 'package:fushi_engine/media/external_provider.dart';

String _fixture(String name) =>
    File('test/fixtures/opds/komga/$name').readAsStringSync();

const String _host = 'http://localhost:25600';
const String _apiKey = '2067b06fcf974915bd4012b87dcd745e';

OpdsServerConfig _config(
  String url, {
  String username = '',
  String password = '',
  String apiKey = '',
}) => OpdsServerConfig(
  id: 'komga',
  name: 'Komga',
  catalogUrl: Uri.parse(url),
  username: username,
  password: password,
  apiKey: apiKey,
);

/// 一台按真 Komga 1.29.1 行为回话的假服务器：
/// - `/` → 200 text/html（Komga 的 Web UI）；
/// - `/opds/v2/catalog` / `/opds/v1.2/catalog` → 目录，要 `X-API-Key` 或邮箱 Basic；
/// - 其余（含 `/opds`、`/opds/v2`、带结尾斜杠的 catalog）→ 404。
class _FakeKomga {
  final List<String> requested = <String>[];
  final List<Map<String, String>> headersSeen = <Map<String, String>>[];

  static const String _basicEmail =
      'Basic YWRtaW5AZXhhbXBsZS5vcmc6c2VjcmV0MTIz'; // admin@example.org:secret123

  bool _authorized(http.Request request) =>
      request.headers['X-API-Key'] == _apiKey ||
      request.headers['Authorization'] == _basicEmail;

  late final MockClient client = MockClient((http.Request request) async {
    requested.add(request.url.path);
    headersSeen.add(Map<String, String>.of(request.headers));
    switch (request.url.path) {
      case '':
      case '/':
        return http.Response(
          '<!DOCTYPE html><html><head><title>Komga</title></head></html>',
          200,
          headers: <String, String>{'content-type': 'text/html'},
        );
      case '/opds/v2/catalog':
        if (!_authorized(request)) return http.Response('', 401);
        return http.Response.bytes(
          File('test/fixtures/opds/komga/v2root.json').readAsBytesSync(),
          200,
          headers: <String, String>{'content-type': 'application/opds+json'},
        );
      case '/opds/v1.2/catalog':
        if (!_authorized(request)) return http.Response('', 401);
        return http.Response.bytes(
          File('test/fixtures/opds/komga/v1root.xml').readAsBytesSync(),
          200,
          headers: <String, String>{'content-type': 'application/atom+xml'},
        );
      default:
        return http.Response('', 404);
    }
  });
}

void main() {
  group('BUG-3526 目录地址探测', () {
    test('候选：原样地址打头，去结尾斜杠其次，再是根与各级前缀上的已知端点', () {
      final List<String> fromRoot = opdsCatalogUrlCandidates(
        Uri.parse('$_host/'),
      ).map((Uri u) => u.toString()).toList();
      expect(fromRoot.first, '$_host/');
      expect(
        fromRoot,
        containsAllInOrder(<String>[
          '$_host/opds/v2/catalog',
          '$_host/opds/v1.2/catalog',
          '$_host/opds',
        ]),
      );

      final List<String> trailing = opdsCatalogUrlCandidates(
        Uri.parse('$_host/opds/v1.2/catalog/'),
      ).map((Uri u) => u.toString()).toList();
      expect(trailing.take(2), <String>[
        '$_host/opds/v1.2/catalog/',
        '$_host/opds/v1.2/catalog',
      ]);

      // 反代子路径：/komga 前缀上的端点也要在候选里。
      expect(
        opdsCatalogUrlCandidates(
          Uri.parse('https://h.example/komga'),
        ).map((Uri u) => u.toString()),
        contains('https://h.example/komga/opds/v2/catalog'),
      );

      // Kavita 的端点路径里带 key：只在配了 API key 时才出现。
      expect(
        opdsCatalogUrlCandidates(
          Uri.parse('https://k.example'),
        ).any((Uri u) => u.path.startsWith('/api/opds/')),
        isFalse,
      );
      // 候选里是占位段而不是 key 明文（打通后会被写回配置）。
      final List<Uri> kavita = opdsCatalogUrlCandidates(
        Uri.parse('https://k.example'),
        apiKey: 'abc',
      );
      expect(
        kavita.map((Uri u) => u.pathSegments.join('/')),
        contains('api/opds/$kOpdsApiKeyPlaceholder'),
      );
      expect(
        kavita.map((Uri u) => u.toString()).join(' '),
        isNot(contains('abc')),
      );

      // 去重：没有重复候选（每条都是一次真请求）。
      expect(fromRoot.toSet(), hasLength(fromRoot.length));
    });

    for (final String given in <String>[
      _host,
      '$_host/',
      '$_host/opds',
      '$_host/opds/v1.2/catalog/',
    ]) {
      test('填 "$given" 也能打通，并回调写回打通的目录地址', () async {
        final _FakeKomga komga = _FakeKomga();
        final List<Uri> resolved = <Uri>[];
        final OpdsDiscoverySource source = OpdsDiscoverySource(
          config: _config(given, apiKey: _apiKey),
          client: komga.client,
          onCatalogUrlResolved: resolved.add,
        );
        final ProviderBatchResult<DiscoveryResultPage> page = await source
            .browse(const DiscoveryRequest(kind: DiscoveryMediaKind.manga));
        expect(page.items.single.entries, isNotEmpty);
        final String expected = given.endsWith('/opds/v1.2/catalog/')
            ? '$_host/opds/v1.2/catalog'
            : '$_host/opds/v2/catalog';
        expect(source.resolvedCatalogUrl.toString(), expected);
        expect(resolved.map((Uri u) => u.toString()), <String>[expected]);

        // 第二次浏览不再探测：直接打已确认的地址。
        komga.requested.clear();
        await source.browse(
          const DiscoveryRequest(kind: DiscoveryMediaKind.manga),
        );
        expect(komga.requested, <String>[Uri.parse(expected).path]);
        expect(resolved, hasLength(1), reason: '写回只发生一次');
      });
    }

    test('填对了地址：零额外请求、不回调写回', () async {
      final _FakeKomga komga = _FakeKomga();
      final List<Uri> resolved = <Uri>[];
      final OpdsDiscoverySource source = OpdsDiscoverySource(
        config: _config('$_host/opds/v2/catalog', apiKey: _apiKey),
        client: komga.client,
        onCatalogUrlResolved: resolved.add,
      );
      await source.browse(
        const DiscoveryRequest(kind: DiscoveryMediaKind.manga),
      );
      expect(komga.requested, <String>['/opds/v2/catalog']);
      expect(resolved, isEmpty);
    });

    test('凭据错时停在第一条 401，不再挨个试剩下的路径', () async {
      final _FakeKomga komga = _FakeKomga();
      final OpdsDiscoverySource source = OpdsDiscoverySource(
        config: _config(_host, username: 'admin', password: 'secret123'),
        client: komga.client,
      );
      await expectLater(
        source.browse(const DiscoveryRequest(kind: DiscoveryMediaKind.manga)),
        throwsA(
          isA<ExternalProviderFailure>().having(
            (ExternalProviderFailure f) => f.kind,
            'kind',
            ExternalProviderFailureKind.unauthorized,
          ),
        ),
      );
      expect(komga.requested, <String>['', '/opds/v2/catalog']);
    });

    test('只有网页没有目录：报 OpdsWebPageFailure（UI 据此给本地化说明）', () async {
      final MockClient htmlOnly = MockClient((http.Request request) async {
        if (request.url.path.isEmpty || request.url.path == '/') {
          return http.Response(
            '<!doctype html><html><body>blog</body></html>',
            200,
            headers: <String, String>{'content-type': 'text/html'},
          );
        }
        return http.Response('', 404);
      });
      final OpdsDiscoverySource source = OpdsDiscoverySource(
        config: _config('http://localhost:8080'),
        client: htmlOnly,
      );
      await expectLater(
        source.browse(const DiscoveryRequest(kind: DiscoveryMediaKind.novel)),
        throwsA(isA<OpdsWebPageFailure>()),
      );
    });

    test('Content-Type 标 text/html 的真 Atom feed 照常解析（嗅探优先，不误判网页）', () async {
      final MockClient mislabeled = MockClient(
        (http.Request request) async => http.Response.bytes(
          File('test/fixtures/opds/komga/v1seriesM.xml').readAsBytesSync(),
          200,
          headers: <String, String>{'content-type': 'text/html'},
        ),
      );
      final OpdsDiscoverySource source = OpdsDiscoverySource(
        config: _config('$_host/opds/v1.2/series/x'),
        client: mislabeled,
      );
      final ProviderBatchResult<DiscoveryResultPage> page = await source.browse(
        const DiscoveryRequest(kind: DiscoveryMediaKind.manga),
      );
      expect(page.items.single.entries, hasLength(3));
    });
  });

  group('BUG-3521 API key', () {
    test('X-API-Key 只发给目录自己的 origin；Basic 与 API key 可并存', () {
      final OpdsServerConfig config = _config(
        '$_host/opds/v2/catalog',
        username: 'admin@example.org',
        password: 'secret123',
        apiKey: _apiKey,
      );
      expect(
        config.credentialHeadersFor(Uri.parse('$_host/opds/v2/books/1/file')),
        <String, String>{
          'Authorization': _FakeKomga._basicEmail,
          'X-API-Key': _apiKey,
        },
      );
      expect(
        config.credentialHeadersFor(Uri.parse('https://cdn.example/x.jpg')),
        isEmpty,
      );
      expect(
        config.credentialHeadersFor(Uri.parse('http://localhost:25601/x')),
        isEmpty,
        reason: '端口不同即不同 origin',
      );
    });

    test('只配 API key（不填账号）就能打通 Komga', () async {
      final _FakeKomga komga = _FakeKomga();
      final OpdsDiscoverySource source = OpdsDiscoverySource(
        config: _config('$_host/opds/v2/catalog', apiKey: _apiKey),
        client: komga.client,
      );
      await source.browse(
        const DiscoveryRequest(kind: DiscoveryMediaKind.manga),
      );
      expect(komga.headersSeen.single['X-API-Key'], _apiKey);
      expect(komga.headersSeen.single.containsKey('Authorization'), isFalse);
    });

    test('JSON 往返保留 API key（遮蔽存放），旧配置没有该字段时为空', () {
      final OpdsServerConfig config = _config(
        '$_host/opds/v2/catalog',
        apiKey: _apiKey,
      );
      final Map<String, Object?> json = config.toJson();
      expect(json.containsKey('apiKey'), isFalse, reason: '不以明文字段名存放');
      expect(json['apiKeyB64'], isNot(_apiKey));
      expect(OpdsServerConfig.fromJson(json).apiKey, _apiKey);

      final OpdsServerConfig legacy =
          OpdsServerConfig.fromJson(<String, Object?>{
            'id': 'old',
            'name': '',
            'url': 'https://books.example.com/opds',
            'username': 'u',
            'passwordB64': 'cHc=',
          });
      expect(legacy.apiKey, isEmpty);
      expect(legacy.password, 'pw');
    });

    test('feed 请求跨 origin 重定向时不把 X-API-Key 带过去', () async {
      final List<(String, Map<String, String>)> seen =
          <(String, Map<String, String>)>[];
      final MockClient redirecting = MockClient((http.Request request) async {
        seen.add((
          request.url.toString(),
          Map<String, String>.of(request.headers),
        ));
        if (request.url.host == 'localhost') {
          return http.Response(
            '',
            302,
            headers: <String, String>{
              'location': 'https://mirror.example/catalog.json',
            },
          );
        }
        return http.Response.bytes(
          File('test/fixtures/opds/komga/v2seriesM.json').readAsBytesSync(),
          200,
          headers: <String, String>{'content-type': 'application/opds+json'},
        );
      });
      final OpdsDiscoverySource source = OpdsDiscoverySource(
        config: _config('$_host/opds/v2/catalog', apiKey: _apiKey),
        client: redirecting,
      );
      await source.browse(
        const DiscoveryRequest(kind: DiscoveryMediaKind.manga),
      );
      expect(seen, hasLength(2));
      expect(seen.first.$2['X-API-Key'], _apiKey);
      expect(seen.last.$1, 'https://mirror.example/catalog.json');
      expect(seen.last.$2.containsKey('X-API-Key'), isFalse);
    });
  });

  group('Kavita：路径里带 key 的目录地址不落盘 key 明文', () {
    const String kavitaHost = 'https://kavita.example';
    const String oldKey = 'OLDKEY0123456789';
    const String newKey = 'NEWKEY9876543210';

    /// 只认 `/api/opds/<当前 key>` 的假 Kavita；其余一律 404。
    MockClient fakeKavita(String acceptedKey, List<String> requested) =>
        MockClient((http.Request request) async {
          requested.add(request.url.path);
          if (request.url.path == '/api/opds/$acceptedKey') {
            return http.Response.bytes(
              File('test/fixtures/opds/komga/v1root.xml').readAsBytesSync(),
              200,
              headers: <String, String>{'content-type': 'application/atom+xml'},
            );
          }
          return http.Response('', 404);
        });

    test('探测打通后：请求带真 key，写回 / resolvedCatalogUrl 是占位形态', () async {
      final List<String> requested = <String>[];
      final List<Uri> written = <Uri>[];
      final OpdsDiscoverySource source = OpdsDiscoverySource(
        config: _config(kavitaHost, apiKey: oldKey),
        client: fakeKavita(oldKey, requested),
        onCatalogUrlResolved: written.add,
      );
      final ProviderBatchResult<DiscoveryResultPage> page = await source.browse(
        const DiscoveryRequest(kind: DiscoveryMediaKind.manga),
      );
      expect(page.items.single.entries, isNotEmpty);
      expect(requested.last, '/api/opds/$oldKey');
      expect(written, hasLength(1));
      expect(written.single.toString(), isNot(contains(oldKey)));
      expect(written.single.pathSegments, <String>[
        'api',
        'opds',
        kOpdsApiKeyPlaceholder,
      ]);
      expect(source.resolvedCatalogUrl.toString(), isNot(contains(oldKey)));
    });

    test('写回的占位地址换 key 后直接用新 key，不卡在旧 key 的 401/404', () async {
      // 模拟上一轮写回后的持久化形态：地址是占位段，key 已换成新值。
      final OpdsServerConfig persisted = OpdsServerConfig.fromJson(
        _config(kavitaHost, apiKey: oldKey)
            .copyWith(catalogUrl: Uri.parse('$kavitaHost/api/opds/$oldKey'))
            .copyWith(apiKey: newKey)
            .toJson(),
      );
      expect(persisted.catalogUrl.toString(), isNot(contains(oldKey)));
      final List<String> requested = <String>[];
      final OpdsDiscoverySource source = OpdsDiscoverySource(
        config: persisted,
        client: fakeKavita(newKey, requested),
      );
      await source.browse(
        const DiscoveryRequest(kind: DiscoveryMediaKind.manga),
      );
      expect(requested, <String>['/api/opds/$newKey'], reason: '一次命中，不重探');
    });

    test('配置构造时把路径里等于 key 的段收成占位段（旧写回 / 用户粘贴的地址）', () {
      final OpdsServerConfig pasted = _config(
        '$kavitaHost/api/opds/$oldKey',
        apiKey: oldKey,
      );
      expect(pasted.catalogUrl.toString(), isNot(contains(oldKey)));
      expect(pasted.toJson()['url'], isNot(contains(oldKey)));
      expect(
        expandOpdsApiKeyPlaceholder(pasted.catalogUrl, oldKey).toString(),
        '$kavitaHost/api/opds/$oldKey',
      );
      // 没配 key 时不猜哪段是 key：原样保留。
      expect(
        _config('$kavitaHost/api/opds/$oldKey').catalogUrl.toString(),
        '$kavitaHost/api/opds/$oldKey',
      );
    });
  });

  group('BUG-3535 封面凭据', () {
    test('同源封面带凭据头，跨源封面不带', () async {
      final MockClient client = MockClient(
        (http.Request request) async => http.Response(
          '''
<feed xmlns="http://www.w3.org/2005/Atom">
  <entry><title>A</title><id>a</id>
    <link rel="http://opds-spec.org/image" href="/opds/v1.2/books/a/thumbnail"/>
    <link rel="http://opds-spec.org/acquisition" type="application/zip"
          href="/opds/v1.2/books/a/file/A.cbz"/>
  </entry>
  <entry><title>B</title><id>b</id>
    <link rel="http://opds-spec.org/image" href="https://cdn.example/b.jpg"/>
    <link rel="http://opds-spec.org/acquisition" type="application/zip"
          href="/opds/v1.2/books/b/file/B.cbz"/>
  </entry>
</feed>''',
          200,
          headers: <String, String>{'content-type': 'application/atom+xml'},
        ),
      );
      final OpdsDiscoverySource source = OpdsDiscoverySource(
        config: _config('$_host/opds/v1.2/catalog', apiKey: _apiKey),
        client: client,
      );
      final List<DiscoveryResourceItem> items = (await source.browse(
        const DiscoveryRequest(kind: DiscoveryMediaKind.manga),
      )).items.single.entries.whereType<DiscoveryResourceItem>().toList();
      expect(items, hasLength(2));
      expect(items.first.coverUrl, '$_host/opds/v1.2/books/a/thumbnail');
      expect(items.first.coverHeaders, <String, String>{'X-API-Key': _apiKey});
      expect(items.last.coverHeaders, isEmpty);
    });
  });

  group('真 Komga feed 方言', () {
    test('v1.2：application/zip + .cbz 末段 → 漫画 cbz，可下载', () {
      final OpdsFeed feed = parseOpdsAtomFeed(
        _fixture('v1seriesM.xml'),
        baseUri: Uri.parse('$_host/opds/v1.2/series/0RZ7B15JRFQGJ'),
      );
      final List<OpdsPublicationEntry> pubs = feed.entries
          .whereType<OpdsPublicationEntry>()
          .toList();
      expect(pubs, hasLength(3));
      for (final OpdsPublicationEntry pub in pubs) {
        expect(
          pub.bestLinkFor(DiscoveryMediaKind.manga)?.fileType,
          OpdsFileType.cbz,
        );
      }
    });

    test('v1.2：application/zip + .zip 末段的漫画不再被整条滤掉', () {
      final String zipped = _fixture(
        'v1seriesM.xml',
      ).replaceAll('MangaSeries%20v01.cbz', 'MangaSeries%20v01.zip');
      final OpdsFeed feed = parseOpdsAtomFeed(
        zipped,
        baseUri: Uri.parse('$_host/opds/v1.2/series/0RZ7B15JRFQGJ'),
      );
      final OpdsPublicationEntry first = feed.entries
          .whereType<OpdsPublicationEntry>()
          .first;
      expect(first.links.single.href, endsWith('.zip'));
      expect(
        first.bestLinkFor(DiscoveryMediaKind.manga)?.fileType,
        OpdsFileType.cbz,
      );
    });

    test('通用 zip 容器 MIME 不压过扩展名：application/zip + .epub 仍是 EPUB', () {
      expect(
        OpdsFileType.resolve(
          mediaType: 'application/zip',
          path: '/books/1/file/Novel.epub',
        ),
        OpdsFileType.epub,
      );
      expect(
        OpdsFileType.resolve(
          mediaType: 'application/octet-stream',
          path: '/books/1/file',
        ),
        isNull,
        reason: 'octet-stream 没有任何类型信息，不编造',
      );
      expect(
        OpdsFileType.resolve(mediaType: 'application/zip', path: '/b/1/file'),
        OpdsFileType.cbz,
      );
      expect(
        OpdsFileType.resolve(
          mediaType: 'application/epub+zip',
          path: '/b/1/file.cbz',
        ),
        OpdsFileType.epub,
        reason: '具体 MIME 优先于扩展名',
      );
    });

    test('v2：作者取自 metadata.contributor（Komga 不发 author）', () {
      final OpdsFeed feed = parseOpdsJsonFeed(
        _fixture('v2root.json'),
        baseUri: Uri.parse('$_host/opds/v2/catalog'),
      );
      final OpdsPublicationEntry novel = feed.entries
          .whereType<OpdsPublicationEntry>()
          .firstWhere((OpdsPublicationEntry e) => e.title == 'テスト小説');
      expect(novel.author, '作者');
    });

    test('v2：系列页 publications 与封面地址', () {
      final OpdsFeed feed = parseOpdsJsonFeed(
        _fixture('v2seriesM.json'),
        baseUri: Uri.parse('$_host/opds/v2/series/0RZ7B15JRFQGJ'),
      );
      final List<OpdsPublicationEntry> pubs = feed.entries
          .whereType<OpdsPublicationEntry>()
          .toList();
      expect(pubs, hasLength(3));
      expect(pubs.first.coverHref, endsWith('/thumbnail'));
      expect(
        pubs.first.bestLinkFor(DiscoveryMediaKind.manga)?.fileType,
        OpdsFileType.cbz,
      );
      expect(feed.searchTemplate, '$_host/opds/v2/search?query={searchTerms}');
    });
  });
}
