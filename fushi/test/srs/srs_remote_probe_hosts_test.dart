// 远程复习的主机探测（G10-1）：代对不上的主机不再悄悄滤掉，只有没应答 / 没有远程复习的才不列；
// filterSrsRemoteStoreTargets 只留能直接接上的。探测走注入的 probe，映射是真实的 probeSrsRemoteHosts。
import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_remote_store_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_remote_generation.dart';

InterconnectHostTarget _target(String id) => InterconnectHostTarget(
  hostId: id,
  displayName: id,
  peer: FushiClientUrl(url: 'http://$id.invalid', token: 't', hostId: id),
);

void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
  });
  tearDown(() => db.close());

  /// 六种输入：没应答、抛错、超时、没有远程复习、只声明 V1、声明 V2（V1 只是拒绝桩）。
  final List<InterconnectHostTarget> candidates = <InterconnectHostTarget>[
    for (final String id in <String>[
      'null',
      'throws',
      'timeout',
      'none',
      'v1',
      'v2',
    ])
      _target(id),
  ];

  Future<SrsRemoteHostGeneration?> probe(
    SyncRepository _,
    FushiClientUrl peer,
  ) {
    switch (peer.hostId) {
      case 'null':
        return Future<SrsRemoteHostGeneration?>.value();
      case 'throws':
        return Future<SrsRemoteHostGeneration?>.error(StateError('boom'));
      case 'timeout':
        return Completer<SrsRemoteHostGeneration?>().future;
      case 'none':
        return Future<SrsRemoteHostGeneration?>.value(
          SrsRemoteHostGeneration.none,
        );
      case 'v1':
        return Future<SrsRemoteHostGeneration?>.value(
          SrsRemoteHostGeneration.v1Only,
        );
      case 'v2':
        return Future<SrsRemoteHostGeneration?>.value(
          SrsRemoteHostGeneration.v2,
        );
    }
    throw StateError('unexpected ${peer.hostId}');
  }

  const Duration timeout = Duration(milliseconds: 50);

  test(
    'probeSrsRemoteHosts：代对不上的列出来并标明该升级哪边，没应答 / 抛错 / 超时 / 没有远程复习的不列',
    () async {
      // 本机这个构建说 V2（G10-2）：只声明 V1 的旧主机 → 主机需要升级。
      expect(kSrsRemoteClientWire, SrsRemoteWireVersion.v2);
      final Map<String, SrsRemoteHostCompat> compat = await probeSrsRemoteHosts(
        repo,
        candidates,
        probe: probe,
        timeout: timeout,
      );
      expect(compat, <String, SrsRemoteHostCompat>{
        'v1': SrsRemoteHostCompat.hostNeedsUpgrade,
        'v2': SrsRemoteHostCompat.ready,
      });
    },
  );

  test('filterSrsRemoteStoreTargets：只留能直接接上的，代对不上的不在内，顺序不变', () async {
    final List<InterconnectHostTarget> targets =
        await filterSrsRemoteStoreTargets(
          repo,
          <InterconnectHostTarget>[candidates[5], ...candidates.take(5)],
          probe: probe,
          timeout: timeout,
        );
    expect(targets.map((InterconnectHostTarget t) => t.hostId), <String>['v2']);
  });
}
