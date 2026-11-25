import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/webdav_ops.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/host_update/host_update_protocol.dart';

/// BUG-4457 残余：互联后端是单例，会话落在「此刻可达的那台 host」上。主机版本行跟踪
/// 一轮更新时被更新的 host 在重启，会话换到另一台已配对 host，那台答的版本号被当成
/// 「已更新到 X」。后端的状态 / 触发接口带上答话 host 的身份，并支持只认某一台：
/// 会话连的是另一台时不发请求。
///
/// 真 [InterconnectSyncBackend] + 两个本机 HTTP 服务（对 `/api/host/update` 一律
/// 404 = 不提供远程更新，够用来数请求）；选路探测用假的。
void main() {
  late FushiDatabase db;
  late SyncRepository repo;
  late _CountingHost hostA;
  late _CountingHost hostB;

  setUp(() async {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
    hostA = await _CountingHost.start();
    hostB = await _CountingHost.start();
  });

  tearDown(() async {
    await hostA.close();
    await hostB.close();
    await db.close();
  });

  InterconnectSyncBackend backend() =>
      InterconnectSyncBackend.withProbe((String url, String token) async {
        return true;
      });

  // 不带 hostId 的条目：身份退到所连地址，且选路不做组内探测（不碰真网络）。
  Future<void> pair(_CountingHost host) => repo.setFushiClientUrls(
    <FushiClientUrl>[FushiClientUrl(url: host.url, enabled: true, token: 't')],
  );

  test('应答带上答话那台 host 的身份', () async {
    final InterconnectSyncBackend b = backend();
    await pair(hostA);

    final HostUpdateAnswer answer = await b.getRemoteHostUpdateStatus(
      repo: repo,
    );
    expect(answer.host, WebDavOps.normalizeUrl(hostA.url));
    expect(answer.host, await b.connectedHostIdentity());
    expect(answer.status, isNull, reason: '404 = 这台 host 不提供远程更新');
    expect(hostA.updateGets, 1);
  });

  test('钉在原 host 上、会话已换到另一台：状态与触发都抛、都不发请求', () async {
    final InterconnectSyncBackend b = backend();
    await pair(hostA);
    final String a = (await b.getRemoteHostUpdateStatus(repo: repo)).host;

    // 会话换到另一台（这里用改配对触发；生产上是原 host 掉线后重新选路）。
    await pair(hostB);

    await expectLater(
      b.getRemoteHostUpdateStatus(repo: repo, onlyHost: a),
      throwsA(
        isA<HostUpdateOtherHost>()
            .having((HostUpdateOtherHost e) => e.expected, 'expected', a)
            .having(
              (HostUpdateOtherHost e) => e.actual,
              'actual',
              WebDavOps.normalizeUrl(hostB.url),
            ),
      ),
    );
    await expectLater(
      b.triggerRemoteHostUpdate(repo: repo, nonce: 'n', onlyHost: a),
      throwsA(isA<HostUpdateOtherHost>()),
    );
    expect(hostB.updateGets, 0, reason: '另一台 host 没被问到');
    expect(hostB.updatePosts, 0, reason: '更没有被触发更新');
    expect(hostA.updateGets, 1, reason: '只有换 host 之前那一次');
  });

  test('钉的就是此刻连着的那台：照常发请求', () async {
    final InterconnectSyncBackend b = backend();
    await pair(hostB);
    final String host = WebDavOps.normalizeUrl(hostB.url);

    final HostUpdateAnswer answer = await b.getRemoteHostUpdateStatus(
      repo: repo,
      onlyHost: host,
    );
    expect(answer.host, host);
    expect(hostB.updateGets, 1);

    // 触发：host 回 404 → 按「不支持」拒绝；请求确实到了这台。
    await expectLater(
      b.triggerRemoteHostUpdate(repo: repo, nonce: 'n', onlyHost: host),
      throwsA(
        isA<HostUpdateRejected>().having(
          (HostUpdateRejected e) => e.denial,
          'denial',
          HostUpdateDenial.unsupported,
        ),
      ),
    );
    expect(hostB.updatePosts, 1);
  });
}

/// 本机 HTTP 服务：数 `/api/host/update` 的 GET / POST，一律回 404。
class _CountingHost {
  _CountingHost._(this._server);

  static Future<_CountingHost> start() async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _CountingHost host = _CountingHost._(server);
    host._sub = server.listen(host._handle);
    return host;
  }

  final HttpServer _server;
  late final StreamSubscription<HttpRequest> _sub;
  int updateGets = 0;
  int updatePosts = 0;

  String get url => 'http://127.0.0.1:${_server.port}';

  Future<void> _handle(HttpRequest request) async {
    await request.drain<void>();
    if (request.uri.path == kHostUpdatePath) {
      if (request.method == 'GET') updateGets++;
      if (request.method == 'POST') updatePosts++;
    }
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> close() async {
    await _sub.cancel();
    await _server.close(force: true);
  }
}
