import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';
import 'package:fushi_core/fushi_core.dart';

/// 视频模块页头遥控按钮的目标探测：已配对、可达、声明 `videoRemoteControlV1`，
/// 同一台 host 只出一条；本机做互联 host 或互联未启用时一条都没有。
void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    await repo.setInterconnectEnabled(true);
  });

  tearDown(() async {
    await db.close();
  });

  const FushiClientUrl pcLan = FushiClientUrl(
    url: 'https://192.168.1.10:8765',
    hostId: 'pc',
    deviceName: 'Desk PC',
    fingerprintSha256: 'aa:bb',
    token: 'tok-pc',
  );
  const FushiClientUrl pcP2p = FushiClientUrl(
    url: 'http://127.0.0.1:40001',
    hostId: 'pc',
    token: 'tok-pc',
    learned: true,
  );
  const FushiClientUrl laptop = FushiClientUrl(
    url: 'https://192.168.1.20:8765',
    hostId: 'laptop',
    fingerprintSha256: 'cc:dd',
    token: 'tok-laptop',
  );

  test('每台 host 只探一次、只列声明能力的', () async {
    await repo.setFushiClientUrls(<FushiClientUrl>[pcLan, pcP2p, laptop]);
    final List<String> probed = <String>[];
    final List<VideoRemoteTarget> targets = await probeVideoRemoteTargets(
      repository: repo,
      probe: (SyncRepository _, FushiClientUrl peer) async {
        probed.add(peer.hostId!);
        return peer.hostId == 'pc';
      },
    );
    expect(probed, unorderedEquals(<String>['pc', 'laptop']));
    expect(targets, hasLength(1));
    final VideoRemoteTarget pc = targets.single;
    expect(pc.hostId, 'pc');
    expect(pc.displayName, 'Desk PC');
    expect(pc.peer.url, pcLan.url, reason: '身份代表取手输条目而非 learned');
    expect(pc.peer.token, 'tok-pc');
    expect(pc.peer.fingerprintSha256, 'aa:bb');
  });

  test('代表地址没有指纹时沿用同 host 的配对指纹；无设备名用主机名', () async {
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(
        url: 'http://127.0.0.1:40002',
        hostId: 'pc',
        token: 'tok-pc',
      ),
      pcLan.copyWith(learned: true),
    ]);
    final List<VideoRemoteTarget> targets = await probeVideoRemoteTargets(
      repository: repo,
      probe: (SyncRepository _, FushiClientUrl peer) async => true,
    );
    expect(targets.single.peer.url, 'http://127.0.0.1:40002');
    expect(targets.single.peer.fingerprintSha256, 'aa:bb');
    expect(targets.single.displayName, '127.0.0.1');
  });

  test('全局 token 回落；禁用、无 hostId、无凭据的条目不探', () async {
    await repo.setFushiClientToken('global');
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'https://10.0.0.1:8765', hostId: 'a'),
      const FushiClientUrl(
        url: 'https://10.0.0.2:8765',
        hostId: 'b',
        enabled: false,
      ),
      const FushiClientUrl(url: 'https://10.0.0.3:8765'),
    ]);
    final List<String> probed = <String>[];
    final List<VideoRemoteTarget> targets = await probeVideoRemoteTargets(
      repository: repo,
      probe: (SyncRepository _, FushiClientUrl peer) async {
        probed.add(peer.url);
        return true;
      },
    );
    expect(probed, <String>['https://10.0.0.1:8765']);
    expect(targets.single.peer.token, 'global');
  });

  test('并发探测：超时、抛错、无应答都静默视为不可用', () async {
    await repo.setFushiClientUrls(<FushiClientUrl>[pcLan, laptop]);
    final Completer<bool?> never = Completer<bool?>();
    final List<VideoRemoteTarget> targets = await probeVideoRemoteTargets(
      repository: repo,
      timeout: const Duration(milliseconds: 50),
      probe: (SyncRepository _, FushiClientUrl peer) {
        if (peer.hostId == 'pc') return never.future;
        throw StateError('offline');
      },
    );
    expect(targets, isEmpty);

    final List<VideoRemoteTarget> unknown = await probeVideoRemoteTargets(
      repository: repo,
      probe: (SyncRepository _, FushiClientUrl peer) async => null,
    );
    expect(unknown, isEmpty);
  });

  test('本机正在做互联 host 或互联未启用：不探、不列', () async {
    await repo.setFushiClientUrls(<FushiClientUrl>[pcLan]);
    int calls = 0;
    Future<bool?> probe(SyncRepository _, FushiClientUrl peer) async {
      calls++;
      return true;
    }

    await repo.setServerEnabled(true);
    expect(
      await probeVideoRemoteTargets(repository: repo, probe: probe),
      isEmpty,
    );
    await repo.setServerEnabled(false);
    await repo.setInterconnectEnabled(false);
    expect(
      await probeVideoRemoteTargets(repository: repo, probe: probe),
      isEmpty,
    );
    expect(calls, 0);

    await repo.setInterconnectEnabled(true);
    expect(
      await probeVideoRemoteTargets(repository: repo, probe: probe),
      hasLength(1),
    );
  });

  test('上次选择的 host 存设备本地偏好', () async {
    expect(await repo.getVideoRemoteLastHostId(), isNull);
    await repo.setVideoRemoteLastHostId('pc');
    expect(await repo.getVideoRemoteLastHostId(), 'pc');
    expect(
      SyncRepository.deviceLocalPrefKeys,
      contains('video_remote_last_host_id'),
    );
  });
}
