import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi/src/sync/mine_to_server_target_picker.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:fushi_engine/sync/remote_mining_target.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 「制卡到已配对设备」的落点（docs/specs/2026-11-05-server-srs-design.md §4.8）：
/// - 没选过 = 主机默认，只带本机当前 profile 的 uid；
/// - 选过的按主机（hostId）带上所选；
/// - 查重与制卡用同一个落点；
/// - 主机说所选的它没有（`targetUnavailable`）时通知调用方退回主机默认。
const String kUid = '01928c3e-0000-7000-8000-00000000a0a0';

const ForwardedMinePayload _payload = ForwardedMinePayload(
  rawPayloadJson: '{"expression":"猫"}',
  sentence: 's',
);

void main() {
  late FushiDatabase db;
  late List<http.Request> sent;

  setUp(() {
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    sent = <http.Request>[];
  });

  tearDown(() => db.close());

  Future<FushiClientUrl> pair({String? hostId = 'host-a'}) async {
    final FushiClientUrl url = FushiClientUrl(
      url: 'http://host:8765',
      hostId: hostId,
    );
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[url]);
    await repo.setFushiClientToken('tok');
    return url;
  }

  FushiRemoteMiningClient client(
    Map<String, dynamic> reply, {
    Map<String, RemoteMiningTarget> chosen =
        const <String, RemoteMiningTarget>{},
    void Function(String hostId, RemoteMiningTarget? landed)? onUnavailable,
  }) => FushiRemoteMiningClient(
    repo: SyncRepository(db),
    httpClient: MockClient((http.Request r) async {
      sent.add(r);
      return http.Response(jsonEncode(reply), 200);
    }),
    activeProfileUid: () async => kUid,
    chosenTarget: (String hostId) => chosen[hostId],
    onTargetUnavailable: onUnavailable,
  );

  Map<String, dynamic> bodyOf(http.Request r) =>
      (jsonDecode(r.body) as Map).cast<String, dynamic>();

  test('没选过：制卡与查重都只带本机 profile uid（= 主机默认）', () async {
    await pair();
    final FushiRemoteMiningClient c = client(<String, dynamic>{
      'result': 'success',
      'duplicate': false,
    });
    await c.mineForward(_payload);
    await c.isDuplicate(expression: '猫', reading: 'ねこ');
    expect(sent.map((http.Request r) => r.url.path), <String>[
      '/api/mine/forward',
      '/api/duplicate',
    ]);
    for (final http.Request r in sent) {
      expect(bodyOf(r)['target'], <String, Object?>{'profile': kUid});
    }
    expect(bodyOf(sent.first)['rawPayloadJson'], _payload.rawPayloadJson);
  });

  test('给这台主机选过：带上所选；查重按同一个落点', () async {
    await pair();
    const RemoteMiningTarget chosen = RemoteMiningTarget(
      kind: kRemoteMiningKindReview,
      profile: '01928c3e-0000-7000-8000-00000000b0b0',
      deck: 'Mining',
    );
    final FushiRemoteMiningClient c = client(
      <String, dynamic>{'result': 'success', 'duplicate': true},
      chosen: const <String, RemoteMiningTarget>{'host-a': chosen},
    );
    await c.mineForward(_payload);
    expect(
      await c.isDuplicate(expression: '猫', reading: ''),
      RemoteDuplicateCheck.duplicate,
    );
    for (final http.Request r in sent) {
      expect(bodyOf(r)['target'], chosen.toJson());
    }
  });

  test('选择按主机记：老条目没有 hostId 时不套别的主机的选择', () async {
    await pair(hostId: null);
    final FushiRemoteMiningClient c = client(
      <String, dynamic>{'result': 'success'},
      chosen: const <String, RemoteMiningTarget>{
        'host-a': RemoteMiningTarget(kind: kRemoteMiningKindAnki),
      },
    );
    await c.mineForward(_payload);
    expect(bodyOf(sent.single)['target'], <String, Object?>{'profile': kUid});
  });

  test('主机说所选的它没有：通知调用方（带实际落点）', () async {
    await pair();
    String? resetHost;
    RemoteMiningTarget? landed;
    final FushiRemoteMiningClient c = client(
      <String, dynamic>{
        'result': 'success',
        'landed': <String, Object?>{'kind': 'review', 'profile': kUid},
        'targetUnavailable': true,
      },
      chosen: const <String, RemoteMiningTarget>{
        'host-a': RemoteMiningTarget(kind: kRemoteMiningKindAnki),
      },
      onUnavailable: (String host, RemoteMiningTarget? l) {
        resetHost = host;
        landed = l;
      },
    );
    expect((await c.mineForward(_payload))?['result'], 'success');
    expect(resetHost, 'host-a');
    expect(landed, const RemoteMiningTarget(kind: 'review', profile: kUid));
  });

  test('miningTargets 问主机并带回是哪台主机；选项按复习 profile / 牌组、Anki 摊开', () async {
    await pair();
    final FushiRemoteMiningClient c = client(<String, dynamic>{
      'default': <String, Object?>{'kind': 'review', 'profile': kUid},
      'review': <Object?>[
        <String, Object?>{
          'profile': kUid,
          'name': 'Japanese',
          'decks': <Object?>['Default', 'Mining'],
        },
      ],
      'anki': <String, Object?>{
        'decks': <Object?>['Core'],
      },
    });
    final RemoteMiningTargetsReply? reply = await c.miningTargets();
    expect(sent.single.url.path, '/api/mine/targets');
    expect(sent.single.method, 'POST');
    expect(reply?.hostId, 'host-a');

    final List<MineToServerTargetOption> options = mineToServerTargetOptions(
      reply!.json,
    );
    expect(options.map((MineToServerTargetOption o) => o.target), <Object?>[
      null,
      const RemoteMiningTarget(kind: 'review', profile: kUid),
      const RemoteMiningTarget(kind: 'review', profile: kUid, deck: 'Default'),
      const RemoteMiningTarget(kind: 'review', profile: kUid, deck: 'Mining'),
      const RemoteMiningTarget(kind: 'anki'),
      const RemoteMiningTarget(kind: 'anki', deck: 'Core'),
    ]);
    expect(options[3].label, contains('Japanese'));
    expect(options[3].label, contains('Mining'));
    expect(
      options.map((MineToServerTargetOption o) => o.key).toSet().length,
      options.length,
      reason: '选项值互不相同',
    );
  });

  test('主机不支持挑落点（404）→ null', () async {
    await pair();
    final FushiRemoteMiningClient c = FushiRemoteMiningClient(
      repo: SyncRepository(db),
      httpClient: MockClient((_) async => http.Response('nope', 404)),
    );
    expect(await c.miningTargets(), isNull);
  });
}
