import 'dart:io';

import 'package:drift/drift.dart' show DatabaseConnection, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/ops/ctl_data_wire.dart' show peerHostUrlToWire;
import 'package:fushi/src/sync/interconnect_link_pairing.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/interconnect_host_addresses.dart';
import 'package:fushi_engine/sync/pairing/fushi_pair_v2_client.dart';
import 'package:fushi_engine/sync/pairing/fushi_ping_client.dart';
import 'package:fushi_engine/sync/tls/fushi_tls_identity.dart';

import 'sync_settings_schema_source_corpus.dart';

const String kHostName = 'Study-PC';
const String kHostId = 'device-name-host';
const String kSharedToken = 'device-name-shared-token';

/// BUG-4234：用手动地址（`https://host:38765`）配对的 host 没有设备名——`peer ls` 不列名字、复习 ›「复习已配对
/// 设备的卡组」标题显示 URL 主机名。host 在 `/api/ping` 里本来就报了展示名，设置页的配对收尾却写死
/// `deviceName: null`（扫码 / 深链那条路径照写）。已经这样配过的条目在下次学地址（`/api/host/addresses`）时补名。
///
/// 真 host（FushiSyncServer，TLS 自签 + per-peer token）+ 真 v2 配对客户端 + 真地址学习器。
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory dataDir;
  late FushiSyncServer server;
  late String fingerprint;
  late String baseUrl;
  late Set<String> peerTokens;
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    InterconnectAddressLearner.resetForTest();
    dataDir = Directory.systemTemp.createTempSync('fushi_host_device_name_');
    final ({String certificatePem, String privateKeyPem}) cert =
        FushiSelfSignedCertGenerator.generate(
          commonName: 'fushi-device-name',
          sanIpAddresses: <String>['127.0.0.1'],
        );
    fingerprint = FushiTlsIdentityStore.fingerprintOf(cert.certificatePem);
    peerTokens = <String>{};
    server =
        FushiSyncServer(
            syncDataDir: dataDir.path,
            port: 0,
            token: kSharedToken,
            allowLan: true,
            deviceName: kHostName,
            securityContext: SecurityContext()
              ..useCertificateChainBytes(cert.certificatePem.codeUnits)
              ..usePrivateKeyBytes(cert.privateKeyPem.codeUnits),
            hostFingerprint: fingerprint,
          )
          ..hostId = kHostId
          ..onPairRequest = ((FushiPairRequest r) async => true)
          ..lanRequiresPinProvider = (() async => false)
          ..onPeerPaired = ((FushiPairedPeerRegistration reg) async {
            peerTokens.add(reg.token);
          })
          ..pairedPeerTokensProvider = (() async => peerTokens);
    await server.start();
    baseUrl = 'https://127.0.0.1:${server.port}';
    db = FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));
    repo = SyncRepository(db);
  });

  tearDown(() async {
    await server.stop();
    await db.close();
    try {
      dataDir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放：留给系统清理。
    }
  });

  test('手动地址配对：host 在 /api/ping 报的展示名随配对落库，peer ls 列出它', () async {
    // 设置页 `_attemptManualPair` 的同一串：ping 探测 → v2 配对 → `_onPairSuccess`（recordInterconnectPairing）。
    final FushiPingResult ping = (await probeFushiPing(
      baseUrl,
      pinnedFingerprint: fingerprint,
    )).result!;
    expect(ping.deviceName, kHostName, reason: 'host 本来就在 ping 里报展示名');
    final FushiPairV2Outcome outcome = await FushiPairV2Client(
      baseUrl: baseUrl,
      expectedFingerprint: fingerprint,
    ).pair(deviceName: 'Steam Deck', clientDeviceId: 'deck-1');
    final String token = (outcome as FushiPairV2Success).token;

    await recordInterconnectPairing(
      repo,
      baseUrl: baseUrl,
      token: token,
      fingerprint: fingerprint,
      deviceName: ping.deviceName,
      hostId: ping.hostId,
    );

    final FushiClientUrl entry = (await repo.getFushiClientUrls()).single;
    expect(entry.deviceName, kHostName);
    expect(entry.token, token);
    expect(entry.fingerprintSha256, fingerprint);
    expect(peerHostUrlToWire(entry)['deviceName'], kHostName);
  });

  test('设置页配对收尾把 ping 的展示名传下去，不再写死 null（手动地址 / LAN 发现两条入口）', () {
    final String source = readSyncSettingsSchemaSource();
    final int start = source.indexOf('Future<String> _onPairSuccess(');
    expect(start, greaterThanOrEqualTo(0));
    final String body = source.substring(
      start,
      source.indexOf('return t.sync_pair_success;', start),
    );
    expect(body, contains('recordInterconnectPairing('));
    expect(body, contains('deviceName: deviceName,'));
    expect(body, isNot(contains('deviceName: null')));
    final int run = source.indexOf('Future<void> _runPairingV2({');
    final String runBody = source.substring(
      run,
      source.indexOf('Future<bool> _ensurePinnedFingerprintTrusted(', run),
    );
    expect(
      RegExp(
        r'_onPairSuccess\([^;]*deviceName: deviceName,[^;]*\);',
      ).hasMatch(runBody),
      isTrue,
      reason: '_runPairingV2 拿到的 ping 展示名必须交给 _onPairSuccess',
    );
  });

  test('已配对、没名字的老条目：下次学地址时从 /api/host/addresses 补上名字', () async {
    final FushiPairV2Outcome outcome = await FushiPairV2Client(
      baseUrl: baseUrl,
      expectedFingerprint: fingerprint,
    ).pair(deviceName: 'Steam Deck', clientDeviceId: 'deck-1');
    final String token = (outcome as FushiPairV2Success).token;
    // 升级前手动地址配对留下的条目：有 token、指纹，没有展示名。
    await repo.setFushiClientUrls(<FushiClientUrl>[
      FushiClientUrl(
        url: baseUrl,
        fingerprintSha256: fingerprint,
        token: token,
      ),
    ]);

    final FushiClientUrl anchor = (await repo.getFushiClientUrls()).single;
    expect(anchor.deviceName, isNull);
    expect(await InterconnectAddressLearner(repo).refresh(anchor), isTrue);

    final List<FushiClientUrl> after = await repo.getFushiClientUrls();
    final FushiClientUrl filled = after.firstWhere(
      (FushiClientUrl u) => u.url == baseUrl,
    );
    expect(filled.deviceName, kHostName);
    expect(filled.hostId, kHostId);
    for (final FushiClientUrl u in after) {
      expect(u.deviceName, kHostName, reason: '${u.url} 是同一台 host 学到的地址');
    }
  });

  test('补名只补没名字的：已有的名字不被 host 的回包改写；老 host 不带名字时不动', () {
    const InterconnectHostAddress lan = InterconnectHostAddress(
      url: 'https://192.168.0.10:38765',
      kind: InterconnectAddressKind.lan,
    );
    final List<FushiClientUrl> named = mergeLearnedHostAddresses(
      <FushiClientUrl>[
        const FushiClientUrl(
          url: 'https://a:38765',
          deviceName: 'Study PC',
          token: 't',
        ),
      ],
      anchorUrl: 'https://a:38765',
      hostId: kHostId,
      addresses: const <InterconnectHostAddress>[lan],
      deviceName: kHostName,
    );
    expect(named.first.deviceName, 'Study PC');
    expect(named.last.deviceName, 'Study PC', reason: '学到的地址继承锚点的名字');

    final List<FushiClientUrl> legacyHost = mergeLearnedHostAddresses(
      <FushiClientUrl>[
        const FushiClientUrl(url: 'https://a:38765', token: 't'),
      ],
      anchorUrl: 'https://a:38765',
      hostId: kHostId,
      addresses: const <InterconnectHostAddress>[lan],
    );
    expect(legacyHost.first.deviceName, isNull);
  });
}
