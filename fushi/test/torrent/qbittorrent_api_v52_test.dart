// BUG-1705：qBittorrent 5.2 换了 WebUI API 的成败编码，客户端此前只认 200。
//
// 上游根因（qbittorrent/qBittorrent release-5.2.3）：
// - `APIController::setResult(const QString &)` 把 `QString()` 存进 `QVariant`，
//   而 null QString 让 `QVariant::isNull()` 为真；`WebApplication` 见到 null
//   data 就回 **204 No Content**。凡是「做完了没东西可回」的接口——
//   `auth/login`、`torrents/{delete,stop,start,setLocation,renameFile,
//   filePrio,createCategory,recheck}`——在 5.2 全部从 200 变 204。
// - `auth/login` 的失败编码也变了：`throw APIError(APIErrorType::Unauthorized)`
//   → **401**，不再是 5.1 的 `200` + body `Fails.`。
// - `torrents/add` 从纯文本 `Ok.` / `Fails.` 变成统计 JSON，且磁力链元数据
//   未到手时走 `APIStatus::Async` → **202**，全失败时抛 Conflict → **409**。
//
// 本文件两头都钉死：5.2 的新编码必须判成成功，5.1 的老编码不能被判坏
// （Never break userspace）。

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/torrent/qbittorrent_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// qBittorrent 5.2.x 行为的最小仿真：登录回 204 + SID，动作接口回 204 空体。
///
/// [seen] 按路径记下收到的请求，供调用方断言参数。
MockClient _qb52Server({
  Map<String, http.Request>? seen,
  Set<String> absentEndpoints = const <String>{},
}) {
  return MockClient((http.Request request) async {
    final String path = request.url.path;
    seen?[path] = request;
    if (path == '/api/v2/auth/login') {
      // 5.2：成功 = 204 空 body，SID 仍在 Set-Cookie 里。
      return http.Response(
        '',
        204,
        headers: <String, String>{'set-cookie': 'SID=v52tok; path=/'},
      );
    }
    if (absentEndpoints.contains(path)) {
      return http.Response('Not Found', 404);
    }
    if (path == '/api/v2/app/version') return http.Response('v5.2.3', 200);
    if (path == '/api/v2/torrents/add') {
      return http.Response(
        jsonEncode(<String, Object>{
          'success_count': 1,
          'failure_count': 0,
          'pending_count': 0,
          'added_torrent_ids': <String>['abc'],
        }),
        200,
      );
    }
    // 其余动作接口：5.2 一律 204 空体。
    return http.Response('', 204);
  });
}

/// qBittorrent 5.1.x 行为的最小仿真（回归护栏：老服务器不能被改坏）。
MockClient _qb51Server() {
  return MockClient((http.Request request) async {
    final String path = request.url.path;
    if (path == '/api/v2/auth/login') {
      return http.Response(
        'Ok.',
        200,
        headers: <String, String>{'set-cookie': 'SID=v51tok; path=/'},
      );
    }
    if (path == '/api/v2/app/version') return http.Response('v5.1.2', 200);
    if (path == '/api/v2/torrents/add') return http.Response('Ok.', 200);
    // 5.1：动作接口 200 + 空 body。
    return http.Response('', 200);
  });
}

QBittorrentClient _client(http.Client inner) => QBittorrentClient(
      baseUrl: 'http://qb.local:1236',
      username: 'admin',
      password: 'secret',
      client: inner,
    );

void main() {
  group('classifyQbLoginFailure（登录成败判读，两代协议）', () {
    test('qb ≥5.2：204 空 body = 登录成功', () {
      expect(classifyQbLoginFailure(204, ''), isNull);
    });

    test('qb ≤5.1：200 + Ok. = 登录成功', () {
      expect(classifyQbLoginFailure(200, 'Ok.'), isNull);
    });

    test('qb ≥5.2：401 = 账密错误，说人话不是裸 HTTP 码', () {
      expect(
        classifyQbLoginFailure(401, ''),
        'login rejected (wrong username/password)',
      );
    });

    test('qb ≤5.1：200 + Fails. = 账密错误', () {
      expect(
        classifyQbLoginFailure(200, 'Fails.'),
        'login rejected (wrong username/password)',
      );
    });

    test('两代相同：403 + banned 单独报，别让用户反复重试续期封禁', () {
      final String? reason = classifyQbLoginFailure(
        403,
        'Your IP address has been banned after too many failed '
        'authentication attempts.',
      );
      expect(reason, contains('IP banned by qBittorrent'));
    });

    test('403 但不是封禁：原样透出状态码与 body', () {
      expect(classifyQbLoginFailure(403, 'nope'), 'HTTP 403: nope');
    });

    test('其它状态码：带上 body 便于自查', () {
      expect(classifyQbLoginFailure(500, 'boom'), 'HTTP 500: boom');
      expect(classifyQbLoginFailure(502, ''), 'HTTP 502');
    });
  });

  group('isQbActionSuccess（无返回体的动作接口）', () {
    test('200（≤5.1）与 204（≥5.2）都算成功', () {
      expect(isQbActionSuccess(200), isTrue);
      expect(isQbActionSuccess(204), isTrue);
    });

    test('404 / 403 / 409 / 500 都不算成功', () {
      expect(isQbActionSuccess(404), isFalse);
      expect(isQbActionSuccess(403), isFalse);
      expect(isQbActionSuccess(409), isFalse);
      expect(isQbActionSuccess(500), isFalse);
    });
  });

  group('isQbAddAccepted（torrents/add 两代返回体）', () {
    test('qb ≤5.1：200 Ok. 收下，200 Fails. 不收', () {
      expect(isQbAddAccepted(200, 'Ok.'), isTrue);
      expect(isQbAddAccepted(200, 'Fails.'), isFalse);
    });

    test('qb ≥5.2：200 + success_count>0 的统计 JSON 收下', () {
      expect(
        isQbAddAccepted(
          200,
          '{"success_count":2,"failure_count":0,"pending_count":0,'
          '"added_torrent_ids":["a","b"]}',
        ),
        isTrue,
      );
    });

    test('qb ≥5.2：磁力链元数据待拉取的 202 也算已入列', () {
      expect(
        isQbAddAccepted(
          202,
          '{"success_count":0,"failure_count":0,"pending_count":1,'
          '"added_torrent_ids":[]}',
        ),
        isTrue,
      );
    });

    test('一个都没加进去（全 0 / 409）不算成功', () {
      expect(
        isQbAddAccepted(
          200,
          '{"success_count":0,"failure_count":3,"pending_count":0,'
          '"added_torrent_ids":[]}',
        ),
        isFalse,
      );
      expect(isQbAddAccepted(409, ''), isFalse);
    });

    test('坏 JSON / 非对象 JSON 不吞异常也不误判成功', () {
      expect(isQbAddAccepted(200, '{not json'), isFalse);
      expect(isQbAddAccepted(200, '{"success_count":"many"}'), isFalse);
    });
  });

  group('对 qBittorrent 5.2 服务器的端到端行为', () {
    test('204 登录被判成功：后续请求带上 SID 直接可用', () async {
      final Map<String, http.Request> seen = <String, http.Request>{};
      final QBittorrentClient client = _client(_qb52Server(seen: seen));
      expect(await client.login(), isTrue);
      expect(client.lastFailure, isNull);
      expect(await client.fetchVersion(), 'v5.2.3');
      expect(
        seen['/api/v2/app/version']!
            .headers
            .entries
            .firstWhere(
                (MapEntry<String, String> e) => e.key.toLowerCase() == 'cookie')
            .value,
        'SID=v52tok',
      );
      client.close();
    });

    test('回 204 的动作接口全部判成功（此前全被判失败）', () async {
      final QBittorrentClient client = _client(_qb52Server());
      expect(await client.deleteTorrent('h1'), isTrue);
      expect(await client.ensureCategory('fushi'), isTrue);
      expect(
        await client.setFilePriority(
            hash: 'h1', fileIndexes: <int>[0], priority: 7),
        isTrue,
      );
      expect(
        await client.renameFile(hash: 'h1', oldPath: 'a', newPath: 'b'),
        (true, null),
      );
      expect(
        await client.setLocation(hash: 'h1', location: 'E:/Anime'),
        (true, null),
      );
      client.close();
    });

    test('暂停/恢复：旧端点 404 回退新端点后仍认 204', () async {
      final QBittorrentClient client = _client(_qb52Server(
        absentEndpoints: <String>{
          '/api/v2/torrents/pause',
          '/api/v2/torrents/resume',
        },
      ));
      expect(await client.pauseTorrent('h1'), isTrue);
      expect(await client.resumeTorrent('h1'), isTrue);
      client.close();
    });

    test('torrents/add 回统计 JSON 也算添加成功', () async {
      final QBittorrentClient client = _client(_qb52Server());
      expect(await client.addTorrents(<String>['magnet:?xt=x']), isTrue);
      client.close();
    });
  });

  group('对 qBittorrent 5.1 服务器的回归护栏（不许改坏老服务器）', () {
    test('200 Ok. 登录、200 空体动作、200 Ok. 添加全部照旧成功', () async {
      final QBittorrentClient client = _client(_qb51Server());
      expect(await client.login(), isTrue);
      expect(await client.fetchVersion(), 'v5.1.2');
      expect(await client.deleteTorrent('h1'), isTrue);
      expect(await client.ensureCategory('fushi'), isTrue);
      expect(await client.pauseTorrent('h1'), isTrue);
      expect(await client.addTorrents(<String>['magnet:?xt=x']), isTrue);
      expect(
        await client.setLocation(hash: 'h1', location: 'E:/Anime'),
        (true, null),
      );
      client.close();
    });

    test('200 Fails. 的错误账密仍被判成登录失败', () async {
      final QBittorrentClient client = _client(
        MockClient(
            (http.Request request) async => http.Response('Fails.', 200)),
      );
      expect(await client.login(), isFalse);
      expect(client.lastFailure, contains('wrong username/password'));
      client.close();
    });
  });
}
