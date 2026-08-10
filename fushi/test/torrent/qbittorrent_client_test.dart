import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/qbittorrent_client.dart';
import 'package:fushi/src/media/torrent/torrent_backend.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 造一个「登录永远成功」的 MockClient，非登录请求交给 [handler]。
/// [loginLog] 每次登录成功 +1，第 n 次登录发的 SID 是 `tok<n>`。
MockClient _mockWithLogin(
  List<int> loginLog,
  Future<http.Response> Function(http.Request request) handler,
) {
  return MockClient((http.Request request) async {
    if (request.url.path == '/api/v2/auth/login') {
      loginLog.add(loginLog.length + 1);
      return http.Response(
        'Ok.',
        200,
        headers: <String, String>{
          'set-cookie': 'SID=tok${loginLog.length}; HttpOnly; path=/',
        },
      );
    }
    return handler(request);
  });
}

/// 大小写不敏感取请求头（MockClient 的 headers 键大小写因版本而异）。
String? _header(http.Request request, String name) {
  for (final MapEntry<String, String> e in request.headers.entries) {
    if (e.key.toLowerCase() == name.toLowerCase()) return e.value;
  }
  return null;
}

void main() {
  group('normalizeQbBaseUrl', () {
    test('strips trailing slashes', () {
      expect(
          normalizeQbBaseUrl('http://qb.local:8080/'), 'http://qb.local:8080');
      expect(normalizeQbBaseUrl('http://qb.local:8080///'),
          'http://qb.local:8080');
      expect(normalizeQbBaseUrl('  http://qb.local:8080 '),
          'http://qb.local:8080');
    });

    test('leaves clean url untouched', () {
      expect(normalizeQbBaseUrl('https://nas/qb'), 'https://nas/qb');
    });
  });

  group('extractSidCookie', () {
    test('extracts SID from a single cookie', () {
      expect(extractSidCookie('SID=abc123; HttpOnly; path=/'), 'abc123');
    });

    test('extracts SID from a joined multi-cookie header', () {
      // package:http 会把多个 Set-Cookie 用 ", " 连成一串。
      const String header =
          'theme=dark; path=/, SID=xyz789; HttpOnly; path=/, lang=ja; path=/';
      expect(extractSidCookie(header), 'xyz789');
    });

    test('returns null when no SID present', () {
      expect(extractSidCookie('theme=dark; path=/'), isNull);
      expect(extractSidCookie(''), isNull);
      expect(extractSidCookie(null), isNull);
    });

    test('does not match SID as a suffix of another cookie name', () {
      expect(extractSidCookie('QSID=nope; path=/'), isNull);
    });
  });

  group('login', () {
    test('times out a stalled WebUI request without throwing', () async {
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        requestTimeout: const Duration(milliseconds: 10),
        client: MockClient((http.Request request) async {
          await Future<void>.delayed(const Duration(seconds: 1));
          return http.Response('Ok.', 200);
        }),
      );
      final Stopwatch stopwatch = Stopwatch()..start();
      expect(await client.login(), isFalse);
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 500)));
      client.close();
    });

    test('succeeds on 200 Ok. with SID cookie and sends Referer + form',
        () async {
      late http.Request seen;
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080/',
        username: 'admin',
        password: 'secret',
        client: MockClient((http.Request request) async {
          seen = request;
          expect(
              request.url.toString(), 'http://qb.local:8080/api/v2/auth/login');
          return http.Response(
            'Ok.',
            200,
            headers: <String, String>{'set-cookie': 'SID=tok1; path=/'},
          );
        }),
      );
      expect(await client.login(), isTrue);
      expect(_header(seen, 'Referer'), 'http://qb.local:8080');
      expect(seen.bodyFields,
          <String, String>{'username': 'admin', 'password': 'secret'});
      client.close();
    });

    test('fails on 200 Fails. body (wrong credentials)', () async {
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'wrong',
        // 真实 qb：登录失败回 200 Fails.；未认证访问业务接口回 403。
        client: MockClient((http.Request request) async =>
            request.url.path == '/api/v2/auth/login'
                ? http.Response('Fails.', 200)
                : http.Response('Forbidden', 403)),
      );
      expect(await client.login(), isFalse);
      // BUG-1495：失败原因可读，不再折叠成裸 null。
      expect(client.lastFailure, contains('rejected'));
      // 登录失败 + 匿名也 403 → 依赖会话的调用失败而不是抛异常。
      expect(await client.fetchVersion(), isNull);
      client.close();
    });

    test('fails on network exception without throwing', () async {
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: MockClient((http.Request request) async {
          throw http.ClientException('connection refused');
        }),
      );
      expect(await client.login(), isFalse);
      // BUG-1495：网络异常原样透出（与账密错区分开）。
      expect(client.lastFailure, contains('connection refused'));
      expect(await client.fetchVersion(), isNull);
      expect(await client.addTorrents(<String>['magnet:?xt=x']), isFalse);
      expect(await client.fetchTorrents(), isEmpty);
      client.close();
    });

    test('reports qBittorrent IP ban distinctly (BUG-1495)', () async {
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: MockClient((http.Request request) async => http.Response(
            'Your IP address has been banned after too many failed '
            'authentication attempts.',
            403)),
      );
      expect(await client.fetchVersion(), isNull);
      expect(client.lastFailure, contains('banned'));
      client.close();
    });
  });

  group('anonymous fallback（qb localhost 免密，BUG-1495）', () {
    test('login Fails. 但接口匿名可用 → 探测成功且不带 Cookie', () async {
      final List<http.Request> versionRequests = <http.Request>[];
      int loginAttempts = 0;
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: '',
        password: '',
        client: MockClient((http.Request request) async {
          if (request.url.path == '/api/v2/auth/login') {
            loginAttempts++;
            // localhost bypass 下登录接口仍校验账密：空账密 = Fails.
            return http.Response('Fails.', 200);
          }
          expect(request.url.path, '/api/v2/app/version');
          versionRequests.add(request);
          return http.Response('v5.0.4', 200);
        }),
      );
      expect(await client.fetchVersion(), 'v5.0.4');
      for (final http.Request r in versionRequests) {
        expect(_header(r, 'Cookie'), isNull, reason: '匿名直连不应带 SID cookie');
      }
      // 匿名态被缓存：后续调用不再反复撞登录门（避免触发 qb 失败计数封 IP）。
      expect(await client.fetchVersion(), 'v5.0.4');
      expect(loginAttempts, 1);
      client.close();
    });

    test('登录与匿名都不通 → null + 保留登录失败原因', () async {
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'wrong',
        client: MockClient((http.Request request) async =>
            request.url.path == '/api/v2/auth/login'
                ? http.Response('Fails.', 200)
                : http.Response('Forbidden', 403)),
      );
      expect(await client.fetchVersion(), isNull);
      expect(client.lastFailure, contains('rejected'));
      client.close();
    });
  });

  group('fetchVersion / 403 re-login', () {
    test('returns version and attaches SID cookie', () async {
      final List<int> logins = <int>[];
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          expect(request.url.path, '/api/v2/app/version');
          expect(_header(request, 'Cookie'), 'SID=tok1');
          return http.Response('v4.6.5', 200);
        }),
      );
      expect(await client.fetchVersion(), 'v4.6.5');
      expect(logins.length, 1);
      client.close();
    });

    test('403 triggers exactly one re-login then retry succeeds', () async {
      final List<int> logins = <int>[];
      int versionCalls = 0;
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          versionCalls++;
          // 第一枚 SID 已过期：只有重登后的 tok2 放行。
          if (_header(request, 'Cookie') == 'SID=tok2') {
            return http.Response('v4.6.5', 200);
          }
          return http.Response('Forbidden', 403);
        }),
      );
      expect(await client.fetchVersion(), 'v4.6.5');
      expect(logins.length, 2);
      expect(versionCalls, 2);
      client.close();
    });

    test('persistent 403 fails after a single retry, no infinite loop',
        () async {
      final List<int> logins = <int>[];
      int versionCalls = 0;
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          versionCalls++;
          return http.Response('Forbidden', 403);
        }),
      );
      expect(await client.fetchVersion(), isNull);
      expect(logins.length, 2);
      expect(versionCalls, 2);
      client.close();
    });
  });

  group('addTorrents', () {
    test('posts urls joined by newline with category and savepath', () async {
      final List<int> logins = <int>[];
      late http.Request seen;
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          expect(request.url.path, '/api/v2/torrents/add');
          seen = request;
          return http.Response('Ok.', 200);
        }),
      );
      final bool ok = await client.addTorrents(
        <String>['magnet:?xt=urn:btih:aaa', 'magnet:?xt=urn:btih:bbb'],
        category: 'hibiki-anime',
        savePath: '/downloads/anime',
      );
      expect(ok, isTrue);
      expect(seen.bodyFields, <String, String>{
        'urls': 'magnet:?xt=urn:btih:aaa\nmagnet:?xt=urn:btih:bbb',
        'category': 'hibiki-anime',
        'savepath': '/downloads/anime',
      });
      client.close();
    });

    test('sequentialDownload / firstLastPiecePrio flags land in form',
        () async {
      final List<int> logins = <int>[];
      late http.Request seen;
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          seen = request;
          return http.Response('Ok.', 200);
        }),
      );
      expect(
        await client.addTorrents(
          <String>['magnet:?xt=x'],
          category: 'hibiki',
          sequentialDownload: true,
          firstLastPiecePrio: true,
        ),
        isTrue,
      );
      expect(seen.bodyFields, <String, String>{
        'urls': 'magnet:?xt=x',
        'category': 'hibiki',
        'sequentialDownload': 'true',
        'firstLastPiecePrio': 'true',
      });
      client.close();
    });

    test('omits optional fields and fails on non-Ok body', () async {
      final List<int> logins = <int>[];
      late http.Request seen;
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          seen = request;
          return http.Response('', 415);
        }),
      );
      expect(await client.addTorrents(<String>['magnet:?xt=x']), isFalse);
      expect(seen.bodyFields, <String, String>{'urls': 'magnet:?xt=x'});
      expect(await client.addTorrents(const <String>[]), isFalse);
      client.close();
    });
  });

  group('pauseTorrent / resumeTorrent（TODO-2481）', () {
    test('posts hashes to /torrents/pause and /torrents/resume', () async {
      final List<int> logins = <int>[];
      final List<String> paths = <String>[];
      late http.Request seen;
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          paths.add(request.url.path);
          seen = request;
          return http.Response('', 200);
        }),
      );
      expect(await client.pauseTorrent('abc123'), isTrue);
      expect(paths.last, '/api/v2/torrents/pause');
      expect(seen.bodyFields, <String, String>{'hashes': 'abc123'});
      expect(await client.resumeTorrent('abc123'), isTrue);
      expect(paths.last, '/api/v2/torrents/resume');
      expect(seen.bodyFields, <String, String>{'hashes': 'abc123'});
      client.close();
    });

    test('qb 5.0 移除旧端点：404 时回退 /torrents/stop 与 /torrents/start', () async {
      final List<int> logins = <int>[];
      final List<String> paths = <String>[];
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          paths.add(request.url.path);
          final bool renamed = request.url.path.endsWith('/stop') ||
              request.url.path.endsWith('/start');
          return http.Response('', renamed ? 200 : 404);
        }),
      );
      expect(await client.pauseTorrent('abc123'), isTrue);
      expect(
        paths,
        <String>['/api/v2/torrents/pause', '/api/v2/torrents/stop'],
      );
      paths.clear();
      expect(await client.resumeTorrent('abc123'), isTrue);
      expect(
        paths,
        <String>['/api/v2/torrents/resume', '/api/v2/torrents/start'],
      );
      client.close();
    });

    test('双端点都失败 / 空 hash 返回 false', () async {
      final List<int> logins = <int>[];
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(
          logins,
          (http.Request request) async => http.Response('', 404),
        ),
      );
      expect(await client.pauseTorrent('abc123'), isFalse);
      expect(await client.pauseTorrent(''), isFalse);
      expect(await client.resumeTorrent(''), isFalse);
      client.close();
    });

    test('非 404 失败（如 403 后重登仍失败）不再重试新端点', () async {
      final List<int> logins = <int>[];
      final List<String> paths = <String>[];
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          paths.add(request.url.path);
          return http.Response('', 500);
        }),
      );
      expect(await client.pauseTorrent('abc123'), isFalse);
      expect(paths, <String>['/api/v2/torrents/pause'],
          reason: '500 不是「端点已改名」的证据，盲目重试只会放大故障');
      client.close();
    });
  });

  group('ensureCategory', () {
    test('200 and 409 (already exists) both count as success', () async {
      final List<int> logins = <int>[];
      int status = 200;
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          expect(request.url.path, '/api/v2/torrents/createCategory');
          expect(request.bodyFields['category'], 'hibiki-anime');
          return http.Response('', status);
        }),
      );
      expect(await client.ensureCategory('hibiki-anime'), isTrue);
      status = 409;
      expect(await client.ensureCategory('hibiki-anime'), isTrue);
      status = 400;
      expect(await client.ensureCategory('hibiki-anime'), isFalse);
      expect(await client.ensureCategory(''), isFalse);
      client.close();
    });
  });

  group('fetchTorrents / parseQbTorrentInfos', () {
    test('passes category query and parses torrents', () async {
      final List<int> logins = <int>[];
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'hash': 'aaa111',
          'name': 'Show S01',
          'progress': 0.5,
          'state': 'downloading',
          'save_path': '/downloads',
          'content_path': '/downloads/Show S01',
          'amount_left': 1024,
          'total_size': 4096,
        },
      ]);
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          expect(request.url.path, '/api/v2/torrents/info');
          expect(request.url.queryParameters['category'], 'hibiki-anime');
          return http.Response(body, 200);
        }),
      );
      final List<TorrentSnapshot> infos =
          await client.fetchTorrents(category: 'hibiki-anime');
      expect(infos, hasLength(1));
      expect(infos.first.hash, 'aaa111');
      expect(infos.first.name, 'Show S01');
      expect(infos.first.progress, 0.5);
      expect(infos.first.state, 'downloading');
      expect(infos.first.savePath, '/downloads');
      expect(infos.first.contentPath, '/downloads/Show S01');
      expect(infos.first.amountLeft, 1024);
      expect(infos.first.totalSizeBytes, 4096);
      client.close();
    });

    test('parses integer progress as double', () {
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{'hash': 'h1', 'progress': 1, 'state': 'downloading'},
      ]);
      final List<TorrentSnapshot> infos = parseQbTorrentInfos(body);
      expect(infos.single.progress, 1.0);
    });

    test('parses speed/traffic/peer fields (BUG-1494)', () {
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'hash': 'h1',
          'state': 'downloading',
          'dlspeed': 1048576,
          'upspeed': 2048,
          'downloaded': 734003200,
          'uploaded': 1024,
          'num_seeds': 3,
          'num_leechs': 2,
        },
      ]);
      final TorrentSnapshot info = parseQbTorrentInfos(body).single;
      expect(info.downRateBps, 1048576);
      expect(info.upRateBps, 2048);
      expect(info.downloadedBytes, 734003200);
      expect(info.uploadedBytes, 1024);
      expect(info.numPeers, 5);
      // 字段缺省 → 安全 0，不影响老响应。
      final TorrentSnapshot bare =
          parseQbTorrentInfos('[{"hash":"h2"}]').single;
      expect(bare.downRateBps, 0);
      expect(bare.upRateBps, 0);
      expect(bare.downloadedBytes, 0);
      expect(bare.uploadedBytes, 0);
      expect(bare.numPeers, 0);
    });

    test('tolerates bad JSON, non-list JSON and missing fields', () {
      expect(parseQbTorrentInfos('not json'), isEmpty);
      expect(parseQbTorrentInfos('{"a":1}'), isEmpty);
      expect(parseQbTorrentInfos('[1, "x", null]'), isEmpty);
      // 缺 hash 的条目跳过；其余字段缺省用安全默认值。
      final List<TorrentSnapshot> infos =
          parseQbTorrentInfos('[{"name":"no hash"},{"hash":"h2"}]');
      expect(infos, hasLength(1));
      expect(infos.single.hash, 'h2');
      expect(infos.single.name, '');
      expect(infos.single.progress, 0.0);
      expect(infos.single.state, '');
      expect(infos.single.savePath, '');
      expect(infos.single.contentPath, '');
      expect(infos.single.amountLeft, -1);
      // amount_left 未知（-1）不应误判为完成。
      expect(infos.single.isComplete, isFalse);
    });
  });

  group('TorrentSnapshot.isComplete', () {
    TorrentSnapshot make({
      double progress = 0,
      String state = 'downloading',
      int amountLeft = -1,
    }) {
      return TorrentSnapshot(
        hash: 'h',
        name: 'n',
        progress: progress,
        state: state,
        savePath: '',
        contentPath: '',
        amountLeft: amountLeft,
      );
    }

    test('seeding-family states are complete regardless of progress', () {
      for (final String state in <String>[
        'uploading',
        'stalledUP',
        'pausedUP',
        'stoppedUP',
        'queuedUP',
        'forcedUP',
      ]) {
        expect(make(state: state, progress: 0.99).isComplete, isTrue,
            reason: state);
      }
    });

    test('full progress or zero amount_left is complete', () {
      expect(make(progress: 1.0).isComplete, isTrue);
      expect(make(progress: 0.3, amountLeft: 0).isComplete, isTrue);
    });

    test('incomplete and error states are not complete', () {
      expect(make(progress: 0.5, amountLeft: 100).isComplete, isFalse);
      expect(make(state: 'error', progress: 1.0, amountLeft: 0).isComplete,
          isFalse);
      expect(
          make(state: 'missingFiles', progress: 1.0, amountLeft: 0).isComplete,
          isFalse);
    });
  });

  group('fetchTorrentFiles / parseQbTorrentFiles', () {
    test('passes hash query and parses files', () async {
      final List<int> logins = <int>[];
      final String body = jsonEncode(<Map<String, dynamic>>[
        <String, dynamic>{
          'index': 0,
          'name': 'Season 01/EP01.mkv',
          'size': 734003200,
          'progress': 1.0,
        },
        <String, dynamic>{
          'index': 1,
          'name': 'Season 01/EP02.mkv',
          'size': 734003201,
          'progress': 0.25,
        },
      ]);
      final QBittorrentClient client = QBittorrentClient(
        baseUrl: 'http://qb.local:8080',
        username: 'admin',
        password: 'secret',
        client: _mockWithLogin(logins, (http.Request request) async {
          expect(request.url.path, '/api/v2/torrents/files');
          expect(request.url.queryParameters['hash'], 'aaa111');
          return http.Response(body, 200);
        }),
      );
      final List<TorrentFileEntry> files =
          await client.fetchTorrentFiles('aaa111');
      expect(files, hasLength(2));
      expect(files.first.name, 'Season 01/EP01.mkv');
      expect(files.first.size, 734003200);
      expect(files.first.progress, 1.0);
      expect(files.first.index, 0);
      expect(files.last.index, 1);
      expect(await client.fetchTorrentFiles(''), isEmpty);
      client.close();
    });

    test('tolerates bad JSON and missing fields', () {
      expect(parseQbTorrentFiles('not json'), isEmpty);
      expect(parseQbTorrentFiles('{"a":1}'), isEmpty);
      final List<TorrentFileEntry> files =
          parseQbTorrentFiles('[{"size":1},{"name":"only-name.mkv"}]');
      expect(files, hasLength(1));
      expect(files.single.name, 'only-name.mkv');
      expect(files.single.size, 0);
      expect(files.single.progress, 0.0);
      expect(files.single.index, -1);
    });
  });
}
