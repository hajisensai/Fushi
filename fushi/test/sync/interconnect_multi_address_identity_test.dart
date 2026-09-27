import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_mining_client.dart';
import 'package:fushi/src/sync/interconnect_download_client.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 同一台 host 经多条地址到达时，凡是「记住这台 host」的地方都不能把某一条地址
/// 当身份（docs/specs/2026-09-28-interconnect-remote-reach.md，URL 身份审计）。
FushiDatabase _testDb() =>
    FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

void main() {
  setUp(resetInterconnectRaceCache);

  group('同步目录缓存（folderId 是绝对 URL）', () {
    Future<InterconnectSyncBackend> backendAt(String base) async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        FushiClientUrl(url: base),
      ]);
      await repo.setFushiClientToken('tok');
      final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe(
        (String u, String t) async => true,
      );
      await backend.restoreAuth(repo);
      return backend;
    }

    test('只恢复与当前基址同源的条目（别的地址 / 上次的 P2P 转发口一律丢弃）', () async {
      final InterconnectSyncBackend backend = await backendAt(
        'http://127.0.0.1:9',
      );
      backend.restoreCache(
        rootFolderId: 'http://127.0.0.1:9/fushi-data/',
        titleToFolderId: <String, String>{
          'same': 'http://127.0.0.1:9/fushi-data/same/',
          'stale-port': 'http://127.0.0.1:5555/fushi-data/x/',
          'other-host': 'http://192.168.1.5:9/fushi-data/y/',
        },
      );
      expect(backend.cachedRootFolderId, 'http://127.0.0.1:9/fushi-data/');
      expect(backend.cachedFolderIds.keys, <String>['same']);
    });

    test('根目录不同源 → 不恢复根（下一轮按名重建）', () async {
      final InterconnectSyncBackend backend = await backendAt(
        'http://127.0.0.1:9',
      );
      backend.restoreCache(rootFolderId: 'http://127.0.0.1:5555/fushi-data/');
      expect(backend.cachedRootFolderId, isNull);
    });
  });

  group('制卡源编辑草稿的 host 身份', () {
    test('带 hostId：身份与经哪条地址到达无关', () {
      const FushiClientUrl lan = FushiClientUrl(
        url: 'http://192.168.1.5:38765',
        token: 'T',
        hostId: 'A',
      );
      const FushiClientUrl v6 = FushiClientUrl(
        url: 'http://[2408::5]:38765',
        token: 'T',
        hostId: 'A',
      );
      expect(sourcePeerPairingIdentity(lan), sourcePeerPairingIdentity(v6));
      expect(
        sourcePeerPairingIdentity(lan),
        isNot(sourcePeerPairingIdentity(lan.copyWith(token: 'OTHER'))),
      );
    });

    test('无 hostId 的老条目仍是 v1（升级前保存的草稿身份不变）', () {
      const FushiClientUrl legacy = FushiClientUrl(
        url: 'http://192.168.1.5:38765',
        token: 'T',
      );
      expect(
        sourcePeerPairingIdentity(legacy),
        legacySourcePeerPairingIdentity(legacy),
      );
      expect(
        sourcePeerPairingIdentity(legacy.copyWith(hostId: 'A')),
        isNot(legacySourcePeerPairingIdentity(legacy)),
        reason: '学到 hostId 后 v2 不同——续草稿时两种都要认',
      );
    });
  });

  test('onlyCandidate 带 hostId：认 host，不认某一条地址', () async {
    final FushiDatabase db = _testDb();
    addTearDown(db.close);
    final SyncRepository repo = SyncRepository(db);
    await repo.setFushiClientUrls(const <FushiClientUrl>[
      FushiClientUrl(url: 'http://127.0.0.1:1', token: 'tok', hostId: 'A'),
      FushiClientUrl(
        url: 'http://127.0.0.2:1',
        token: 'tok',
        hostId: 'A',
        learned: true,
      ),
      FushiClientUrl(url: 'http://127.0.0.3:1', token: 'tok', hostId: 'B'),
    ]);
    final List<String> hosts = <String>[];
    final InterconnectPostTransport transport = InterconnectPostTransport(
      repo: repo,
      httpClient: MockClient((http.Request request) async {
        hosts.add(request.url.host);
        if (request.url.host == '127.0.0.1') return http.Response('down', 503);
        return http.Response(jsonEncode(<String, dynamic>{'ok': true}), 200);
      }),
    );
    final InterconnectPostOutcome outcome = await transport.post(
      path: '/api/probe',
      body: const <String, dynamic>{},
      timeout: const Duration(seconds: 3),
      authErrorMessage: 'rejected',
      onlyCandidate: const FushiClientUrl(
        url: 'http://127.0.0.1:1',
        token: 'tok',
        hostId: 'A',
      ),
    );
    expect(outcome.json?['ok'], isTrue);
    expect(hosts, <String>[
      '127.0.0.1',
      '127.0.0.2',
    ], reason: '同一台 host 的另一条地址顶上；B 绝不被碰');
  });

  test('HostDownloadTarget.isPeer：按 host 认偏好里的那条地址', () {
    const HostDownloadTarget target = HostDownloadTarget(
      baseUrl: 'http://[2408::5]:38765',
      deviceName: 'PC',
      backend: 'embedded',
      peerUrls: <String>{'http://[2408::5]:38765', 'http://192.168.1.5:38765'},
    );
    expect(target.isPeer('http://192.168.1.5:38765'), isTrue);
    expect(target.isPeer('http://10.0.0.9:38765'), isFalse);
    expect(target.isPeer(null), isFalse);
  });
}
