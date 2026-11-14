/// R9：能力探测把凭据失效、证书不符、老版本、连不上都折成「没有可用主机」，界面
/// 只能笼统地说「没有 host」。改为带原因的 [InterconnectCapabilityOutcome]，下载与
/// 订阅两个 client 都经 [InterconnectHostChannel] 探，原因一路带到入口。
///
/// 对真实 [FushiSyncServer] 跑（行的 hostId 与服务器一致，明文地址按步骤 3 当场
/// ping 核对身份），https 用例起真实自签证书。
library;

import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/interconnect_host_channel.dart';
import 'package:fushi/src/sync/interconnect_subscription_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/downloads/host_download_host.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/subscriptions/host_subscription_host.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';
import 'package:path/path.dart' as p;

const String _hostId = 'host-outcome-1';
const String _token = 'tok';

class _DownloadHost implements HostDownloadHost {
  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'supported': true,
    'backend': 'embedded',
    'kinds': <String>['video'],
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

class _SubscriptionHost implements HostSubscriptionHost {
  @override
  Future<Map<String, Object?>> capability() async => <String, Object?>{
    'supported': true,
    'backend': 'embedded',
    'providers': <String>['nyaa'],
  };

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi-capability-outcome-');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
  });

  tearDown(() async {
    await db.close();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<FushiSyncServer> startServer({
    bool downloads = true,
    bool subscriptions = true,
    SecurityContext? securityContext,
    String? fingerprint,
  }) async {
    final FushiSyncServer server = FushiSyncServer(
      syncDataDir: p.join(tmp.path, 'sync-${DateTime.now().microsecond}'),
      port: 0,
      token: _token,
      downloads: downloads ? _DownloadHost() : null,
      subscriptions: subscriptions ? _SubscriptionHost() : null,
      securityContext: securityContext,
      hostFingerprint: fingerprint,
      deviceName: 'PC',
    )..hostId = _hostId;
    await server.start();
    addTearDown(server.stop);
    return server;
  }

  Future<void> pairRow(String url, {String? token, String? fingerprint}) async {
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(
        url: url,
        deviceName: 'PC',
        hostId: _hostId,
        token: token ?? _token,
        fingerprintSha256: fingerprint,
      ),
    ]);
  }

  InterconnectCapabilityUnavailable<T> unavailableOf<T>(
    List<InterconnectCapabilityOutcome<T>> outcomes,
  ) {
    expect(outcomes, hasLength(1));
    expect(outcomes.single, isA<InterconnectCapabilityUnavailable<T>>());
    return outcomes.single as InterconnectCapabilityUnavailable<T>;
  }

  test('能答复且宣告能力 → Available（下载 / 订阅都带 host 身份）', () async {
    final FushiSyncServer server = await startServer();
    await pairRow('http://127.0.0.1:${server.port}');
    final InterconnectDownloadClient dl = InterconnectDownloadClient(
      repo: repo,
    );
    final InterconnectSubscriptionClient sub = InterconnectSubscriptionClient(
      repo: repo,
    );
    addTearDown(dl.close);
    addTearDown(sub.close);

    final List<InterconnectCapabilityOutcome<HostDownloadTarget>> d = await dl
        .probeAllOutcomes();
    expect(
      d.single,
      isA<InterconnectCapabilityAvailable<HostDownloadTarget>>(),
    );
    final List<InterconnectCapabilityOutcome<HostSubscriptionTarget>> s =
        await sub.probeAllOutcomes();
    final HostSubscriptionTarget target =
        (s.single as InterconnectCapabilityAvailable<HostSubscriptionTarget>)
            .target;
    expect(target.hostRef.hostId, _hostId);
    expect(target.providers, <String>['nyaa']);
    expect(await sub.probeAll(), hasLength(1));
  });

  test('错误 token → Unavailable(authRejected)，不再折成「没有 host」', () async {
    final FushiSyncServer server = await startServer();
    await pairRow('http://127.0.0.1:${server.port}', token: 'wrong');
    final InterconnectDownloadClient dl = InterconnectDownloadClient(
      repo: repo,
    );
    final InterconnectSubscriptionClient sub = InterconnectSubscriptionClient(
      repo: repo,
    );
    addTearDown(dl.close);
    addTearDown(sub.close);

    expect(
      unavailableOf(await dl.probeAllOutcomes()).failure,
      InterconnectHostFailure.authRejected,
    );
    final InterconnectCapabilityUnavailable<HostSubscriptionTarget> s =
        unavailableOf(await sub.probeAllOutcomes());
    expect(s.failure, InterconnectHostFailure.authRejected);
    expect(s.label, 'PC');
    expect(await sub.probeAll(), isEmpty, reason: 'probeAll 签名与语义不变');
  });

  test('host 没挂该能力 → Unavailable(unsupported)', () async {
    final FushiSyncServer server = await startServer(
      downloads: false,
      subscriptions: false,
    );
    await pairRow('http://127.0.0.1:${server.port}');
    final InterconnectDownloadClient dl = InterconnectDownloadClient(
      repo: repo,
    );
    final InterconnectSubscriptionClient sub = InterconnectSubscriptionClient(
      repo: repo,
    );
    addTearDown(dl.close);
    addTearDown(sub.close);

    expect(
      unavailableOf(await dl.probeAllOutcomes()).failure,
      InterconnectHostFailure.unsupported,
    );
    expect(
      unavailableOf(await sub.probeAllOutcomes()).failure,
      InterconnectHostFailure.unsupported,
    );
  });

  test('死端口 → Unavailable(unreachable)', () async {
    final ServerSocket dead = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final int port = dead.port;
    await dead.close();
    await pairRow('http://127.0.0.1:$port');
    final InterconnectSubscriptionClient sub = InterconnectSubscriptionClient(
      repo: repo,
      probeTimeout: const Duration(seconds: 2),
    );
    final InterconnectDownloadClient dl = InterconnectDownloadClient(
      repo: repo,
      probeTimeout: const Duration(seconds: 2),
    );
    addTearDown(dl.close);
    addTearDown(sub.close);

    expect(
      unavailableOf(await sub.probeAllOutcomes()).failure,
      InterconnectHostFailure.unreachable,
    );
    expect(
      unavailableOf(await dl.probeAllOutcomes()).failure,
      InterconnectHostFailure.unreachable,
    );
  });

  test('https host + 错误指纹 → Unavailable(certificateMismatch)', () async {
    final ({String certificatePem, String privateKeyPem}) generated =
        FushiSelfSignedCertGenerator.generate(
          commonName: 'fushi-outcome',
          sanIpAddresses: <String>['127.0.0.1'],
        );
    final String realFingerprint = FushiTlsIdentityStore.fingerprintOf(
      generated.certificatePem,
    );
    final SecurityContext ctx = SecurityContext()
      ..useCertificateChainBytes(generated.certificatePem.codeUnits)
      ..usePrivateKeyBytes(generated.privateKeyPem.codeUnits);
    final FushiSyncServer server = await startServer(
      securityContext: ctx,
      fingerprint: realFingerprint,
    );
    final String wrong = List<String>.filled(32, 'ab').join(':');
    expect(wrong, isNot(realFingerprint));
    await pairRow('https://127.0.0.1:${server.port}', fingerprint: wrong);
    final InterconnectSubscriptionClient sub = InterconnectSubscriptionClient(
      repo: repo,
    );
    final InterconnectDownloadClient dl = InterconnectDownloadClient(
      repo: repo,
    );
    addTearDown(dl.close);
    addTearDown(sub.close);

    expect(
      unavailableOf(await sub.probeAllOutcomes()).failure,
      InterconnectHostFailure.certificateMismatch,
    );
    expect(
      unavailableOf(await dl.probeAllOutcomes()).failure,
      InterconnectHostFailure.certificateMismatch,
    );

    // 指纹对上就通：钉扎走的是真实 TLS 路径，不是一律拒绝。
    await pairRow(
      'https://127.0.0.1:${server.port}',
      fingerprint: realFingerprint,
    );
    final InterconnectSubscriptionClient ok = InterconnectSubscriptionClient(
      repo: repo,
    );
    addTearDown(ok.close);
    expect(
      (await ok.probeAllOutcomes()).single,
      isA<InterconnectCapabilityAvailable<HostSubscriptionTarget>>(),
    );
  });

  test('订阅 client 经通道请求：401 → auth_rejected 码；close 后抛 cancelled', () async {
    final FushiSyncServer server = await startServer();
    final String url = 'http://127.0.0.1:${server.port}';
    await pairRow(url, token: 'wrong');
    final InterconnectSubscriptionClient sub = InterconnectSubscriptionClient(
      repo: repo,
    );
    final HostSubscriptionTarget target = HostSubscriptionTarget(
      baseUrl: url,
      deviceName: 'PC',
      backend: 'embedded',
      providers: const <String>['nyaa'],
    );
    await expectLater(
      sub.list(target),
      throwsA(
        isA<HostSubscriptionException>().having(
          (HostSubscriptionException e) => e.code,
          'code',
          'auth_rejected',
        ),
      ),
    );
    sub.close();
    await expectLater(
      sub.list(target),
      throwsA(
        isA<HostSubscriptionException>().having(
          (HostSubscriptionException e) => e.code,
          'code',
          'cancelled',
        ),
      ),
    );
  });
}
