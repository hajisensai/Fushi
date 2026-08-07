import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/hibiki_remote_mining_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-1185：`FushiRemoteMiningClient.isDuplicate` 曾用裸 `catch (_) => false`
/// 把主机的 401 一起吞掉，于是「token 被拒、根本没查成」被冒充成「查过了、不重复」。
/// 用户看到 ➕ 会以为这张卡没做过。本组用真实 HTTP 状态码驱动，锁死三态映射。
FushiDatabase _testDb() {
  return FushiDatabase.forTesting(
    DatabaseConnection(NativeDatabase.memory()),
  );
}

Future<SyncRepository> _repo(FushiDatabase db) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setHibikiClientUrls(
      const <FushiClientUrl>[FushiClientUrl(url: 'http://host:8765')]);
  await repo.setHibikiClientToken('tok');
  return repo;
}

Future<RemoteDuplicateCheck> _check(
  FushiDatabase db,
  http.Response Function(http.Request request) respond,
) async {
  final FushiRemoteMiningClient client = FushiRemoteMiningClient(
    repo: await _repo(db),
    httpClient: MockClient((http.Request request) async => respond(request)),
  );
  return client.isDuplicate(expression: '猫', reading: 'ねこ');
}

http.Response _json(Map<String, dynamic> body, int status) =>
    http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: const <String, String>{
        'content-type': 'application/json; charset=utf-8',
      },
    );

void main() {
  test('BUG-1185 主机 401 → authRejected（绝不冒充 notDuplicate）', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    expect(
      await _check(db, (http.Request _) => http.Response('nope', 401)),
      RemoteDuplicateCheck.authRejected,
    );
  });

  test('主机确认命中 → duplicate', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    expect(
      await _check(db,
          (http.Request _) => _json(<String, dynamic>{'duplicate': true}, 200)),
      RemoteDuplicateCheck.duplicate,
    );
  });

  test('主机确认未命中 → notDuplicate', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    expect(
      await _check(
          db,
          (http.Request _) =>
              _json(<String, dynamic>{'duplicate': false}, 200)),
      RemoteDuplicateCheck.notDuplicate,
    );
  });

  test('可重试失败（503）仍 fail-soft → notDuplicate，不阻断查词', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    expect(
      await _check(db, (http.Request _) => http.Response('down', 503)),
      RemoteDuplicateCheck.notDuplicate,
    );
  });

  test('传输层失败（连接被拒）仍 fail-soft → notDuplicate', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final FushiRemoteMiningClient client = FushiRemoteMiningClient(
      repo: await _repo(db),
      httpClient: MockClient(
          (http.Request _) async => throw http.ClientException('boom')),
    );
    expect(
      await client.isDuplicate(expression: '猫', reading: 'ねこ'),
      RemoteDuplicateCheck.notDuplicate,
    );
  });

  test('未配置可达候选 → notDuplicate（不误报鉴权失败）', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final FushiRemoteMiningClient client = FushiRemoteMiningClient(
      repo: SyncRepository(db),
      httpClient: MockClient(
          (http.Request _) async => throw StateError('must not be called')),
    );
    expect(
      await client.isDuplicate(expression: '猫', reading: 'ねこ'),
      RemoteDuplicateCheck.notDuplicate,
    );
  });
}
