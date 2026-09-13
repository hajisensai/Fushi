/// 互联 host「借出本机扩展源」端点（`/api/manga-sources/**`）的真 HTTP 往返：
/// 假 [HostMangaSourceHost] 挂在真 [FushiSyncServer] 上，对面用真
/// [InterconnectMangaSourceClient]（候选地址 / 凭据来自内存 DB 的 SyncRepository）。
///
/// 覆盖：能力位 / 未鉴权 401 / 未接线 404 / 清单 / 浏览分页 / 详情 / 页表 / 页图字节
/// / 封面字节 / 对端 Cloudflare 结构化错误 / 源已停用 404 → 结构化异常。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:fushi/src/media/manga/interconnect/interconnect_manga_source_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/manga_sources/host_manga_source_host.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeHost implements HostMangaSourceHost {
  final List<String> calls = <String>[];

  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'version': 1,
    'runtimes': <String>['mihon'],
  };

  @override
  Future<List<RemoteMangaSourceInfo>> listSources() async =>
      const <RemoteMangaSourceInfo>[
        RemoteMangaSourceInfo(
          id: 'mihon:eu.kanade.tachiyomi.extension.ja.rawkuma:1234',
          runtime: 'mihon',
          name: 'Rawkuma',
          language: 'ja',
          baseUrl: 'https://rawkuma.example',
          supportsFilters: true,
        ),
        RemoteMangaSourceInfo(
          id: 'mihon:pkg.cf:99',
          runtime: 'mihon',
          name: 'Cloudflared',
          language: 'en',
        ),
      ];

  void _require(String sourceId) {
    if (sourceId != 'mihon:eu.kanade.tachiyomi.extension.ja.rawkuma:1234' &&
        sourceId != 'mihon:pkg.cf:99') {
      throw HostMangaSourceException(
        HostMangaSourceException.codeSourceNotFound,
        'no $sourceId',
      );
    }
    if (sourceId == 'mihon:pkg.cf:99') {
      throw const HostMangaSourceException(
        HostMangaSourceException.codeCloudflare,
        'Cloudflare challenge on host',
      );
    }
  }

  @override
  Future<List<Map<String, Object?>>> filters(String sourceId) async {
    _require(sourceId);
    return <Map<String, Object?>>[
      <String, Object?>{
        'name': 'Genre',
        'type': 'select',
        'values': <String>['a', 'b'],
      },
    ];
  }

  @override
  Future<RemoteMangaBrowsePage> browse(
    String sourceId, {
    required RemoteMangaBrowseMode mode,
    required int page,
    String query = '',
    List<Map<String, Object?>> filters = const <Map<String, Object?>>[],
  }) async {
    _require(sourceId);
    calls.add('browse:${mode.name}:$page:$query:${filters.length}');
    return RemoteMangaBrowsePage(
      items: <Map<String, Object?>>[
        <String, Object?>{
          'key': '/manga/$page-${mode.name}',
          'title': 'Title $page ${query.isEmpty ? mode.name : query}',
          'coverUrl': 'https://rawkuma.example/c$page.jpg',
          'raw': <String, Object?>{'url': '/manga/$page-${mode.name}'},
        },
      ],
      hasNextPage: page < 2,
    );
  }

  @override
  Future<RemoteMangaSeriesDetail> details(
    String sourceId,
    Map<String, Object?> series,
  ) async {
    _require(sourceId);
    return RemoteMangaSeriesDetail(
      series: <String, Object?>{...series, 'author': 'Someone'},
      chapters: <Map<String, Object?>>[
        <String, Object?>{
          'key': '/ch/1',
          'name': 'Ch. 1',
          'number': 1,
          'raw': <String, Object?>{'url': '/ch/1'},
        },
        <String, Object?>{
          'key': '/ch/2',
          'name': 'Ch. 2',
          'number': 2,
          'raw': <String, Object?>{'url': '/ch/2'},
        },
      ],
    );
  }

  @override
  Future<List<Map<String, Object?>>> pages(
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
  ) async {
    _require(sourceId);
    calls.add('pages:${series['key']}:${chapter['key']}');
    return <Map<String, Object?>>[
      <String, Object?>{'index': 0, 'url': 'p0'},
      <String, Object?>{'index': 1, 'url': 'p1'},
    ];
  }

  @override
  Future<RemoteMangaImage> pageImage(
    String sourceId,
    Map<String, Object?> series,
    Map<String, Object?> chapter,
    Map<String, Object?> page,
  ) async {
    _require(sourceId);
    final int index = (page['index'] as num).toInt();
    return RemoteMangaImage(
      bytes: Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, index]),
      contentType: 'image/jpeg',
    );
  }

  @override
  Future<RemoteMangaImage> coverImage(
    String sourceId,
    Map<String, Object?> series,
    String url,
  ) async {
    _require(sourceId);
    calls.add('cover:${series['key']}:$url');
    return RemoteMangaImage(
      bytes: Uint8List.fromList(<int>[0x89, 0x50, ...utf8.encode(url)]),
      contentType: 'image/png',
    );
  }
}

void main() {
  // 刻意**不**装 TestWidgetsFlutterBinding：它会把所有 HttpClient 请求短路成 400。
  const String token = 'manga-sources-token';
  late _FakeHost host;
  late FushiSyncServer server;
  late String base;
  late FushiDatabase db;
  late SyncRepository repo;
  late InterconnectMangaSourceClient client;

  Future<HttpClientResponse> rawGet(
    String path, {
    bool authorize = true,
  }) async {
    final HttpClient http = HttpClient();
    final HttpClientRequest req = await http.getUrl(Uri.parse('$base$path'));
    if (authorize) {
      req.headers.set(
        'authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      );
    }
    final HttpClientResponse res = await req.close();
    http.close();
    return res;
  }

  Future<FushiSyncServer> startServer({required bool withHost}) async {
    final FushiSyncServer s = FushiSyncServer(
      syncDataDir: Directory.systemTemp.createTempSync('hbk_mangasources').path,
      port: 0,
      token: token,
      allowLan: false,
      mangaSources: withHost ? host : null,
    );
    await s.start();
    return s;
  }

  setUp(() async {
    host = _FakeHost();
    server = await startServer(withHost: true);
    base = 'http://127.0.0.1:${server.port}';
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: base, deviceName: 'Desk'),
      // 一条没人听的地址：探测必须并发跳过它，不能让它拖垮整轮。
      const FushiClientUrl(url: 'http://127.0.0.1:9', deviceName: 'Dead'),
    ]);
    await repo.setFushiClientToken(token);
    client = InterconnectMangaSourceClient(
      repo: repo,
      probeTimeout: const Duration(seconds: 3),
    );
  });

  tearDown(() async {
    await server.stop();
    await db.close();
  });

  test('capabilities 带 mangaSources；未鉴权 401', () async {
    final HttpClientResponse ok = await rawGet('/api/capabilities');
    final Map<String, Object?> json =
        jsonDecode(await utf8.decodeStream(ok)) as Map<String, Object?>;
    expect(json['mangaSources'], <String, Object?>{
      'version': 1,
      'runtimes': <String>['mihon'],
    });
    final HttpClientResponse denied = await rawGet(
      '/api/manga-sources',
      authorize: false,
    );
    expect(denied.statusCode, 401);
    await denied.drain<void>();
  });

  test('未接线的 host：端点 404、能力位无 mangaSources、client 不列它', () async {
    await server.stop();
    server = await startServer(withHost: false);
    base = 'http://127.0.0.1:${server.port}';
    await repo.setFushiClientUrls(<FushiClientUrl>[FushiClientUrl(url: base)]);
    final HttpClientResponse res = await rawGet('/api/manga-sources');
    expect(res.statusCode, 404);
    await res.drain<void>();
    final HttpClientResponse caps = await rawGet('/api/capabilities');
    final Map<String, Object?> json =
        jsonDecode(await utf8.decodeStream(caps)) as Map<String, Object?>;
    expect(json.containsKey('mangaSources'), isFalse);
    expect(await client.probe(), isEmpty);
  });

  test('probe 只返回带能力位的对端 + 它的源清单', () async {
    final List<InterconnectMangaSourcePeer> peers = await client.probe();
    expect(peers, hasLength(1));
    final InterconnectMangaSourcePeer peer = peers.single;
    expect(peer.baseUrl, base);
    expect(peer.displayName, 'Desk');
    expect(peer.sources.map((RemoteMangaSourceInfo s) => s.id), <String>[
      'mihon:eu.kanade.tachiyomi.extension.ja.rawkuma:1234',
      'mihon:pkg.cf:99',
    ]);
    expect(peer.sources.first.supportsFilters, isTrue);
  });

  test('浏览 / 过滤器 / 详情 / 页表 / 页图 / 封面逐字往返', () async {
    final InterconnectMangaSourcePeer peer = (await client.probe()).single;
    const String id = 'mihon:eu.kanade.tachiyomi.extension.ja.rawkuma:1234';

    final List<Map<String, Object?>> filters = await client.filters(peer, id);
    expect(filters.single['name'], 'Genre');

    final RemoteMangaBrowsePage popular = await client.browse(
      peer,
      id,
      mode: RemoteMangaBrowseMode.popular,
      page: 1,
    );
    expect(popular.hasNextPage, isTrue);
    expect(popular.items.single['title'], 'Title 1 popular');

    final RemoteMangaBrowsePage search = await client.browse(
      peer,
      id,
      mode: RemoteMangaBrowseMode.search,
      page: 2,
      query: 'yotsuba',
      filters: filters,
    );
    expect(search.hasNextPage, isFalse);
    expect(search.items.single['title'], 'Title 2 yotsuba');
    expect(host.calls, contains('browse:search:2:yotsuba:1'));

    final RemoteMangaSeriesDetail detail = await client.details(
      peer,
      id,
      popular.items.single,
    );
    expect(detail.series['author'], 'Someone');
    expect(detail.chapters.map((Map<String, Object?> c) => c['key']), <String>[
      '/ch/1',
      '/ch/2',
    ]);

    final List<Map<String, Object?>> pages = await client.pages(
      peer,
      id,
      popular.items.single,
      detail.chapters.first,
    );
    expect(pages, hasLength(2));
    expect(host.calls, contains('pages:/manga/1-popular:/ch/1'));

    final Uint8List page1 = await client.pageImage(
      peer,
      id,
      popular.items.single,
      detail.chapters.first,
      pages[1],
    );
    expect(page1, <int>[0xFF, 0xD8, 0xFF, 1]);

    final Uint8List cover = await client.coverImage(
      peer,
      id,
      popular.items.single,
      'https://rawkuma.example/c1.jpg',
    );
    // 作品随封面请求一起到对端（Aidoku 封面要作品页当 Referer）。
    expect(
      host.calls,
      contains('cover:/manga/1-popular:https://rawkuma.example/c1.jpg'),
    );
    expect(cover.sublist(0, 2), <int>[0x89, 0x50]);
    expect(utf8.decode(cover.sublist(2)), 'https://rawkuma.example/c1.jpg');
  });

  test('对端 Cloudflare → 502 结构化错误 → client 按 code 分型', () async {
    final InterconnectMangaSourcePeer peer = (await client.probe()).single;
    await expectLater(
      client.browse(
        peer,
        'mihon:pkg.cf:99',
        mode: RemoteMangaBrowseMode.popular,
        page: 1,
      ),
      throwsA(
        isA<InterconnectMangaSourceException>()
            .having(
              (InterconnectMangaSourceException e) => e.isCloudflare,
              'isCloudflare',
              isTrue,
            )
            .having(
              (InterconnectMangaSourceException e) => e.message,
              'message',
              'Cloudflare challenge on host',
            ),
      ),
    );
  });

  test('对端已停用该源 → 404 → source_not_found', () async {
    final InterconnectMangaSourcePeer peer = (await client.probe()).single;
    await expectLater(
      client.details(peer, 'mihon:gone:1', <String, Object?>{'key': 'x'}),
      throwsA(
        isA<InterconnectMangaSourceException>().having(
          (InterconnectMangaSourceException e) => e.isSourceNotFound,
          'isSourceNotFound',
          isTrue,
        ),
      ),
    );
  });

  test('错 token → auth', () async {
    final InterconnectMangaSourcePeer bad = InterconnectMangaSourcePeer(
      baseUrl: base,
      token: 'wrong',
      sources: const <RemoteMangaSourceInfo>[],
    );
    await expectLater(
      client.filters(bad, 'mihon:pkg:1'),
      throwsA(
        isA<InterconnectMangaSourceException>().having(
          (InterconnectMangaSourceException e) => e.code,
          'code',
          InterconnectMangaSourceException.codeAuth,
        ),
      ),
    );
  });

  test('路由层：坏 body 400、错方法 405、未知动作 404', () async {
    Future<int> post(String path, String body) async {
      final HttpClient http = HttpClient();
      final HttpClientRequest req = await http.postUrl(Uri.parse('$base$path'));
      req.headers.set(
        'authorization',
        'Basic ${base64Encode(utf8.encode('hibiki:$token'))}',
      );
      req.headers.contentType = ContentType.json;
      req.write(body);
      final HttpClientResponse res = await req.close();
      await res.drain<void>();
      http.close();
      return res.statusCode;
    }

    const String id = 'mihon%3Aeu.kanade.tachiyomi.extension.ja.rawkuma%3A1234';
    expect(await post('/api/manga-sources/$id/browse', '[]'), 400);
    expect(
      await post('/api/manga-sources/$id/browse', '{"mode":"bogus"}'),
      400,
    );
    expect(await post('/api/manga-sources/$id/nope', '{}'), 404);
    final HttpClientResponse wrongMethod = await rawGet(
      '/api/manga-sources/$id/browse',
    );
    expect(wrongMethod.statusCode, 405);
    await wrongMethod.drain<void>();
  });
}
