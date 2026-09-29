import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// `mineForward` 的失败分类：null 在契约里只表示「确定没送到」——调用方
/// （RemoteMiningAnkiRepository → 待发制卡队列）据此把卡入队重发。主机可能已经落卡
/// 的情形必须抛 [RemoteMineOutcomeUnknown]，否则重发会造出重复卡。
Future<FushiRemoteMiningClient> _client(
  FushiDatabase db,
  Future<http.Response> Function(http.Request) handler,
) async {
  final SyncRepository repo = SyncRepository(db);
  await repo.setFushiClientUrls(const <FushiClientUrl>[
    FushiClientUrl(url: 'http://host:8765'),
  ]);
  await repo.setFushiClientToken('tok');
  return FushiRemoteMiningClient(repo: repo, httpClient: MockClient(handler));
}

const ForwardedMinePayload _payload = ForwardedMinePayload(
  rawPayloadJson: '{"expression":"猫"}',
  sentence: 's',
);

void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
  });

  tearDown(() => db.close());

  test('主机连不上 → null（可入队重发）', () async {
    final FushiRemoteMiningClient client = await _client(
      db,
      (_) async => throw http.ClientException('Connection refused'),
    );
    expect(await client.mineForward(_payload), isNull);
  });

  test('主机回了非 2xx → 结果未知，抛 RemoteMineOutcomeUnknown', () async {
    final FushiRemoteMiningClient client = await _client(
      db,
      (_) async => http.Response('boom', 500),
    );
    expect(
      () => client.mineForward(_payload),
      throwsA(isA<RemoteMineOutcomeUnknown>()),
    );
  });

  test('主机给出结果 → 原样返回', () async {
    final FushiRemoteMiningClient client = await _client(
      db,
      (_) async => http.Response(
        jsonEncode(<String, dynamic>{'result': 'success'}),
        200,
      ),
    );
    expect((await client.mineForward(_payload))?['result'], 'success');
  });
}
