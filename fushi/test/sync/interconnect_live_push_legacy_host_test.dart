/// BUG-4431：client live 写入对「旧 host」的兼容层。测试里起一个 dart:io 替身 host：
/// 位置 `GET` / `PUT` 用 [resolvePositionLww] 维护内存值，旧模式下 `PUT` 回 200 空体、
/// 不带 [kLiveWriteHeader]；新模式下带头并按 [resolveLivePositionWrite] 回执。记录
/// 请求序列，驱动真 [InterconnectSyncBackend]。
library;

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_playback_position_sync.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart';

/// 只认 `/api/library/videos/<id>/position` 的替身 host。
class _StubHost {
  _StubHost._(this._server) {
    _server.listen(_handle);
  }

  static Future<_StubHost> start() async =>
      _StubHost._(await HttpServer.bind(InternetAddress.loopbackIPv4, 0));

  final HttpServer _server;

  /// true = 模拟新 host（带头、回执、认前置条件）；false = 旧 host。
  bool advertise = false;
  int positionMs = 0;
  int updatedAtMs = 0;
  final List<String> requests = <String>[];

  String get base => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest req) async {
    final HttpResponse res = req.response;
    if (!req.uri.path.endsWith('/position')) {
      res.statusCode = 404;
      await res.close();
      return;
    }
    requests.add(req.method);
    if (advertise) res.headers.set(kLiveWriteHeader, '1');
    if (req.method == 'GET') {
      res.headers.contentType = ContentType.json;
      res.write(
        jsonEncode(<String, Object?>{
          'positionMs': positionMs,
          'positionUpdatedAtMs': updatedAtMs,
        }),
      );
      await res.close();
      return;
    }
    final Map<String, Object?> body =
        (jsonDecode(await utf8.decoder.bind(req).join()) as Map)
            .cast<String, Object?>();
    final int inPos = (body['positionMs']! as num).toInt();
    final int inTs = (body['positionUpdatedAtMs']! as num).toInt();
    if (!advertise) {
      final ({int positionMs, int updatedAtMs}) winner = resolvePositionLww(
        localPositionMs: positionMs,
        localUpdatedAtMs: updatedAtMs,
        remotePositionMs: inPos,
        remoteUpdatedAtMs: inTs,
      );
      positionMs = winner.positionMs;
      updatedAtMs = winner.updatedAtMs;
      await res.close();
      return;
    }
    final ({LiveWriteResult result, ({int positionMs, int updatedAtMs}) next})
    r = resolveLivePositionWrite(
      current: (positionMs: positionMs, updatedAtMs: updatedAtMs),
      positionMs: inPos,
      updatedAtMs: inTs,
      expectedPositionsMs: parseLiveExpectedPositionsMs(
        body[kLiveExpectedPositionsKey],
      ),
      nowMs: DateTime.now().millisecondsSinceEpoch,
    );
    positionMs = r.next.positionMs;
    updatedAtMs = r.next.updatedAtMs;
    if (r.result == LiveWriteResult.preconditionFailed) res.statusCode = 409;
    res.headers.contentType = ContentType.json;
    res.write(
      jsonEncode(
        LivePositionWriteOutcome(
          result: r.result,
          positionMs: positionMs,
          updatedAtMs: updatedAtMs,
        ).toJson(),
      ),
    );
    await res.close();
  }
}

void main() {
  late _StubHost host;
  late FushiDatabase db;
  late InterconnectSyncBackend backend;

  setUp(() async {
    host = await _StubHost.start();
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(url: host.base, enabled: true),
    ]);
    await repo.setFushiClientToken('stub-token');
    backend = InterconnectSyncBackend.withProbe(
      (String u, String t) async => true,
    );
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
  });

  tearDown(() async {
    await host.close();
    await db.close();
  });

  final int now = DateTime.now().millisecondsSinceEpoch;

  // 评审 correctness-1：前置 GET 核对过 host 停在期望位置，兼容层像新 host 一样
  // 不按戳拒收——上报戳不新于 host 已存戳时抬到「已存戳 + 1」再 PUT。修复前旧 host
  // 按 LWW 拒收（rejected），时钟偏慢的设备整场上报 held。
  test('旧 host 存了更新戳、位置在期望集合里：抬戳到已存戳 + 1，GET, PUT, GET 后判 confirmed', () async {
    host
      ..positionMs = 5000
      ..updatedAtMs = now + 60000;
    final LivePositionPush r = await backend.putLiveVideoPosition(
      'v1',
      7000,
      now,
      expectedPositionsMs: <int>[5000],
    );
    expect(r.status, LivePushStatus.confirmed);
    expect(host.requests, <String>['GET', 'PUT', 'GET']);
    expect(host.positionMs, 7000);
    expect(host.updatedAtMs, now + 60001);
    expect(r.hostNow, (positionMs: 7000, updatedAtMs: now + 60001));
  });

  test('旧 host 存的是超限毒戳：按 0 比较，上报戳原样发出', () async {
    host
      ..positionMs = 5000
      ..updatedAtMs = now + kSyncFutureStampToleranceMs * 10;
    await backend.putLiveVideoPosition(
      'v1',
      7000,
      now,
      expectedPositionsMs: <int>[5000],
    );
    // 毒戳不抬（否则 `毒戳 + 1` 会再被截成 now + 余量，进而写进 host）；旧 host
    // 自己按 LWW 拒收，host 不动。
    expect(host.requests, <String>['GET', 'PUT', 'GET']);
    expect(host.positionMs, 5000);
  });

  test('旧 host 上时钟偏慢的设备：实时上报不被戳拒收，基线推进，后续上报照常发出', () async {
    // 设备 B（时钟快 3 秒）刚把 host 推到 600；本机基线 = 600（开播已对齐）。
    host
      ..positionMs = 600
      ..updatedAtMs = now + 3000;
    final InterconnectPlaybackPositionSync sync =
        InterconnectPlaybackPositionSync(
          db: db,
          backend: backend,
          kind: PlaybackPositionKind.video,
        );
    await sync.recordBaseline('v1', 600);

    expect(
      await sync.reportLive('v1', (positionMs: 610, updatedAtMs: now + 1000)),
      LiveReportResult.confirmed,
    );
    expect(host.positionMs, 610);
    expect(await sync.baseline('v1'), 610);

    host.requests.clear();
    expect(
      await sync.reportLive('v1', (positionMs: 620, updatedAtMs: now + 2000)),
      LiveReportResult.confirmed,
    );
    expect(host.requests, <String>['GET', 'PUT', 'GET']);
    expect(host.positionMs, 620);
    expect(await sync.baseline('v1'), 620);
  });

  test('旧 host 位置不在期望集合里：只 GET，判 superseded，不发 PUT', () async {
    host
      ..positionMs = 5000
      ..updatedAtMs = now - 1000;
    final LivePositionPush r = await backend.putLiveVideoPosition(
      'v1',
      7000,
      now,
      expectedPositionsMs: <int>[4000],
    );
    expect(r.status, LivePushStatus.superseded);
    expect(r.hostNow?.positionMs, 5000);
    expect(host.requests, <String>['GET']);
    expect(host.positionMs, 5000);
  });

  test('旧 host 接受：GET, PUT, GET 后判 confirmed', () async {
    host
      ..positionMs = 5000
      ..updatedAtMs = now - 1000;
    final LivePositionPush r = await backend.putLiveVideoPosition(
      'v1',
      7000,
      now,
      expectedPositionsMs: <int>[5000],
    );
    expect(r.status, LivePushStatus.confirmed);
    expect(r.hostNow, (positionMs: 7000, updatedAtMs: now));
    expect(host.requests, <String>['GET', 'PUT', 'GET']);
  });

  test('新 host 降级成旧 host：PUT 空体后按确认 GET 判定并清掉能力缓存', () async {
    host
      ..advertise = true
      ..positionMs = 5000
      ..updatedAtMs = now - 1000;
    final LivePositionPush first = await backend.putLiveVideoPosition(
      'v1',
      6000,
      now,
      expectedPositionsMs: <int>[5000],
    );
    expect(first.status, LivePushStatus.confirmed);
    expect(host.requests, <String>['GET', 'PUT']);

    host
      ..advertise = false
      ..requests.clear();
    final LivePositionPush second = await backend.putLiveVideoPosition(
      'v1',
      7000,
      now + 1,
      expectedPositionsMs: <int>[6000],
    );
    expect(second.status, LivePushStatus.confirmed);
    expect(host.requests, <String>['PUT', 'GET']);

    host.requests.clear();
    await backend.putLiveVideoPosition(
      'v1',
      8000,
      now + 2,
      expectedPositionsMs: <int>[7000],
    );
    expect(host.requests, <String>['GET', 'PUT', 'GET']);
  });

  test('新 host 前置条件不符回 409：判 superseded，host 不被写', () async {
    host
      ..advertise = true
      ..positionMs = 5000
      ..updatedAtMs = now - 1000;
    // 先学到能力。
    await backend.remoteVideoPosition('v1');
    host.requests.clear();
    final LivePositionPush r = await backend.putLiveVideoPosition(
      'v1',
      7000,
      now,
      expectedPositionsMs: <int>[4000],
    );
    expect(r.status, LivePushStatus.superseded);
    expect(r.hostNow?.positionMs, 5000);
    expect(host.requests, <String>['PUT']);
    expect(host.positionMs, 5000);
  });

  test('旧方法 putRemoteVideoPosition 只发一次 PUT', () async {
    await backend.putRemoteVideoPosition('v1', 7000, now);
    expect(host.requests, <String>['PUT']);
  });
}
