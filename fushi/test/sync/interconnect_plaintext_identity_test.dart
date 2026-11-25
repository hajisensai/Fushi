import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// V-B4：明文地址拿凭据前必须当场核对 hostId。
///
/// 一条明文 http 行标着 hostId `mine`、带着 `mine` 签发的 token，但这个地址此刻
/// 背后是**另一台** Fushi host（换了网络、DHCP 把 IP 给了别人）。单地址组升级前
/// 不做 ping 核对，Basic token 直接发了过去。真服务器 + 真 ping 探测走一遍。
void main() {
  late HttpServer server;
  late List<String?> authHeaders;
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    resetInterconnectRaceCache();
    authHeaders = <String?>[];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest request) async {
      if (request.uri.path == '/api/ping') {
        request.response
          ..headers.contentType = ContentType.json
          ..write(
            jsonEncode(<String, dynamic>{'app': 'fushi', 'hostId': 'other'}),
          );
      } else {
        authHeaders.add(request.headers.value('authorization'));
        request.response
          ..headers.contentType = ContentType.json
          ..write('{}');
      }
      await request.response.close();
    });
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(
        url: 'http://127.0.0.1:${server.port}',
        hostId: 'mine',
        token: 'secret',
      ),
    ]);
  });

  tearDown(() async {
    await server.close(force: true);
    await db.close();
    resetInterconnectRaceCache();
  });

  test('明文地址背后换了 host：凭据不发出，结局是「不可达」', () async {
    final InterconnectPostOutcome outcome =
        await InterconnectPostTransport(repo: repo).post(
          path: '/api/lookup',
          body: const <String, dynamic>{'term': '猫'},
          timeout: const Duration(seconds: 3),
          authErrorMessage: 'rejected',
        );

    expect(
      authHeaders.where((String? h) => h != null && h.startsWith('Basic')),
      isEmpty,
      reason: '没核对过身份的明文地址拿不到 token',
    );
    expect(outcome.json, isNull);
    expect(outcome.allUnreachable, isTrue);
    expect(outcome.mayHaveDelivered, isFalse);
  });

  test('查词 client 走同一道闸：抛不可达，进入失败冷却', () async {
    final FushiRemoteLookupClient client = FushiRemoteLookupClient(repo: repo);
    await expectLater(
      client.searchDictionary(term: '猫', wildcards: false, maximumTerms: 4),
      throwsA(isA<RemoteLookupUnreachableError>()),
    );
    expect(
      authHeaders.where((String? h) => h != null && h.startsWith('Basic')),
      isEmpty,
    );
  });
}
