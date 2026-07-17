import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/torrent/qb_torrent_backend.dart';
import 'package:hibiki/src/media/torrent/qbittorrent_client.dart';
import 'package:hibiki/src/media/torrent/torrent_backend.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 用 MockClient 驱动真实 [QBittorrentClient] 的假 qb 后端：登录永远成功，
/// 记录每个非登录请求供转发断言。
class _FakeQbServer {
  final List<http.Request> requests = <http.Request>[];

  /// path → 响应体（默认 200）；未登记的 path 返回 404。
  final Map<String, http.Response> responses = <String, http.Response>{};

  late final MockClient mock = MockClient((http.Request request) async {
    if (request.url.path == '/api/v2/auth/login') {
      return http.Response('Ok.', 200,
          headers: <String, String>{'set-cookie': 'SID=tok1; path=/'});
    }
    requests.add(request);
    return responses[request.url.path] ?? http.Response('not found', 404);
  });

  /// 建一个包着真实 qb 客户端的 [QbTorrentBackend]。
  TorrentBackend backend() {
    return QbTorrentBackend(QBittorrentClient(
      baseUrl: 'http://qb.local:8080',
      username: 'admin',
      password: 'secret',
      client: mock,
    ));
  }
}

void main() {
  group('QbTorrentBackend 转发', () {
    late _FakeQbServer server;
    late TorrentBackend backend;

    setUp(() {
      server = _FakeQbServer();
      backend = server.backend();
    });

    tearDown(() => backend.close());

    test('probeConnection 走 app/version 并返回版本号', () async {
      server.responses['/api/v2/app/version'] = http.Response('v4.6.5', 200);
      expect(await backend.probeConnection(), 'v4.6.5');
      expect(server.requests.single.url.path, '/api/v2/app/version');
    });

    test('probeConnection 失败返回 null 不抛', () async {
      // 未登记 path → 404。
      expect(await backend.probeConnection(), isNull);
    });

    test('prepareCategory 转发 createCategory；409 已存在也算成功', () async {
      server.responses['/api/v2/torrents/createCategory'] =
          http.Response('', 409);
      expect(await backend.prepareCategory('hibiki-anime'), isTrue);
      final http.Request seen = server.requests.single;
      expect(seen.url.path, '/api/v2/torrents/createCategory');
      expect(seen.bodyFields['category'], 'hibiki-anime');
    });

    test('addTorrent 拼出 sequentialDownload / firstLastPiecePrio 表单', () async {
      server.responses['/api/v2/torrents/add'] = http.Response('Ok.', 200);
      expect(
        await backend.addTorrent(
          'magnet:?xt=urn:btih:aaa',
          category: 'hibiki-anime',
          sequential: true,
          firstLastPiecePrio: true,
        ),
        isTrue,
      );
      final http.Request seen = server.requests.single;
      expect(seen.url.path, '/api/v2/torrents/add');
      expect(seen.bodyFields, <String, String>{
        'urls': 'magnet:?xt=urn:btih:aaa',
        'category': 'hibiki-anime',
        'sequentialDownload': 'true',
        'firstLastPiecePrio': 'true',
      });
    });

    test('addTorrent 默认关顺序下载：表单不带两个开关键', () async {
      server.responses['/api/v2/torrents/add'] = http.Response('Ok.', 200);
      expect(
        await backend.addTorrent('magnet:?xt=urn:btih:bbb', category: 'hibiki'),
        isTrue,
      );
      expect(server.requests.single.bodyFields, <String, String>{
        'urls': 'magnet:?xt=urn:btih:bbb',
        'category': 'hibiki',
      });
    });

    test('listTorrents 传 category 并解析成 TorrentSnapshot', () async {
      server.responses['/api/v2/torrents/info'] = http.Response(
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'hash': 'aaa111',
            'name': 'Show S01',
            'progress': 0.5,
            'state': 'downloading',
            'save_path': '/downloads',
            'content_path': '/downloads/Show S01',
            'amount_left': 1024,
          },
        ]),
        200,
      );
      final List<TorrentSnapshot> torrents =
          await backend.listTorrents(category: 'hibiki-anime');
      expect(server.requests.single.url.queryParameters['category'],
          'hibiki-anime');
      expect(torrents.single.hash, 'aaa111');
      expect(torrents.single.savePath, '/downloads');
      expect(torrents.single.isComplete, isFalse);
    });

    test('listTorrents 不传 category 时无 query', () async {
      server.responses['/api/v2/torrents/info'] = http.Response('[]', 200);
      expect(await backend.listTorrents(), isEmpty);
      expect(server.requests.single.url.queryParameters, isEmpty);
    });

    test('listFiles 传 hash 并解析成 TorrentFileEntry', () async {
      server.responses['/api/v2/torrents/files'] = http.Response(
        jsonEncode(<Map<String, dynamic>>[
          <String, dynamic>{
            'index': 0,
            'name': 'Season 01/EP01.mkv',
            'size': 734003200,
            'progress': 1.0,
          },
        ]),
        200,
      );
      final List<TorrentFileEntry> files = await backend.listFiles('aaa111');
      expect(server.requests.single.url.queryParameters['hash'], 'aaa111');
      expect(files.single.name, 'Season 01/EP01.mkv');
      expect(files.single.index, 0);
    });
  });
}
