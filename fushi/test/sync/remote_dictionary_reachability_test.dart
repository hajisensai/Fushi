import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart';
import 'package:fushi/src/sync/remote_dictionary_reachability.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// BUG-4275：查词路径与目录服务共用一份词典服务器可达性。这里验追踪器本身
/// （跳过判据、后台再探测节奏、立即探测、revision 只在状态变化时 bump）与查词客户端
/// 的挂钩（含弹窗进程用的后台探测 [FushiRemoteLookupClient.probeDictionaryHost]）。
/// 目录服务回前台 / 配对列表变化调 [RemoteDictionaryReachability.probeUnreachableNow]
/// 的真实路径见 `remote_dictionary_catalog_service_test.dart`。
void main() {
  group('RemoteDictionaryReachability', () {
    test('没挂探测函数：判死后只在再探测间隔内跳过，过了间隔放行一次查词', () {
      DateTime now = DateTime.fromMillisecondsSinceEpoch(1000000);
      final RemoteDictionaryReachability r = RemoteDictionaryReachability(
        now: () => now,
        reprobeInterval: const Duration(seconds: 45),
      );
      expect(r.shouldSkip('h'), isFalse, reason: '没试过的 host 照常查');
      r.note('h', reachable: false);
      expect(r.isUnreachable('h'), isTrue);
      expect(r.shouldSkip('h'), isTrue);
      expect(r.allSkipped(<String>{'h'}), isTrue);
      expect(r.allSkipped(<String>{'h', 'other'}), isFalse);
      expect(r.allSkipped(const <String>{}), isFalse);
      now = now.add(const Duration(seconds: 46));
      expect(r.shouldSkip('h'), isFalse);
      r.note('h', reachable: true);
      expect(r.isUnreachable('h'), isFalse);
      expect(r.hosts['h']!.reachable, isTrue);
    });

    test('挂着探测函数：判死后一直跳过，按间隔在后台探测，探通即恢复', () {
      fakeAsync((FakeAsync async) {
        final DateTime start = DateTime.fromMillisecondsSinceEpoch(1000000);
        final RemoteDictionaryReachability r = RemoteDictionaryReachability(
          now: () => start.add(async.elapsed),
          reprobeInterval: const Duration(seconds: 45),
        );
        final List<String> probed = <String>[];
        bool hostUp = false;
        r.probe = (String hostId) async {
          probed.add(hostId);
          r.note(hostId, reachable: hostUp);
        };

        r.note('h', reachable: false);
        async.elapse(const Duration(seconds: 44));
        expect(probed, isEmpty, reason: '间隔内不探');
        expect(r.shouldSkip('h'), isTrue);
        async.elapse(const Duration(seconds: 1));
        expect(probed, <String>['h'], reason: '到了间隔探一次');
        // 仍然连不上：间隔到了再探，期间查词照样跳过（没有「过了间隔放行查词」）。
        async.elapse(const Duration(seconds: 100));
        expect(r.shouldSkip('h'), isTrue);
        expect(probed, <String>['h', 'h', 'h']);
        hostUp = true;
        async.elapse(const Duration(seconds: 45));
        expect(probed, hasLength(4));
        expect(r.shouldSkip('h'), isFalse);
        expect(r.hosts['h']!.reachable, isTrue);
        // 恢复后不再探。
        async.elapse(const Duration(minutes: 10));
        expect(probed, hasLength(4));
        r.dispose();
      });
    });

    test('成功往返立刻取消待探测；probeUnreachableNow 立即探且与在跑的探测共用；解除配对不再探', () {
      fakeAsync((FakeAsync async) {
        final RemoteDictionaryReachability r = RemoteDictionaryReachability(
          reprobeInterval: const Duration(seconds: 45),
        );
        final List<String> probed = <String>[];
        r.probe = (String hostId) async => probed.add(hostId);

        r.record(<String, bool>{'a': false, 'b': false});
        r.note('a', reachable: true); // 例如目录刷新成功
        bool done = false;
        r.probeUnreachableNow().then((_) => done = true);
        r.probeUnreachableNow(); // 撞上在跑的那次：共用，不重复探
        async.flushMicrotasks();
        expect(probed, <String>['b'], reason: '只探仍判死的 host，且立刻探');
        expect(done, isTrue, reason: '返回的 Future 等这批探测结束');

        // 探测没留下结局（例如候选为空）：照常排下一次，不让探测断掉。
        async.elapse(const Duration(seconds: 45));
        expect(probed, <String>['b', 'b']);

        r.retainHosts(<String>{'a'});
        expect(r.hosts.keys, <String>['a']);
        async.elapse(const Duration(minutes: 5));
        expect(probed, hasLength(2), reason: '解除配对的 host 不再探');

        r.note('a', reachable: false);
        r.dispose();
        async.elapse(const Duration(minutes: 5));
        expect(probed, hasLength(2), reason: 'dispose 后不再有后台探测');
      });
    });
  });

  group('RemoteDictionaryReachability.revision', () {
    test('只在可见状态变化时 bump：重复的成功 / 失败不重建来源卡片', () {
      final RemoteDictionaryReachability r = RemoteDictionaryReachability();
      int bumps = 0;
      void listener() => bumps++;
      RemoteDictionaryReachability.revision.addListener(listener);
      addTearDown(
        () => RemoteDictionaryReachability.revision.removeListener(listener),
      );

      r.note('h', reachable: true);
      expect(bumps, 1, reason: '新出现的 host');
      r.note('h', reachable: true);
      r.record(<String, bool>{'h': true});
      expect(bumps, 1, reason: '一直在线：每次查词都记，但不 bump');
      r.note('h', reachable: false);
      expect(bumps, 2, reason: '在线 → 连不上');
      r.note('h', reachable: false);
      expect(bumps, 2, reason: '仍连不上（failingSince 不变）');
      r.note('h', reachable: true);
      expect(bumps, 3, reason: '连不上 → 在线');
      r.record(<String, bool>{'h': true, 'other': false});
      expect(bumps, 4, reason: '一批里有一台变了就 bump 一次');
      r.dispose();
    });
  });

  group('FushiRemoteLookupClient 可达性挂钩', () {
    late FushiDatabase db;
    late SyncRepository repo;

    setUp(() async {
      db = FushiDatabase.forTesting(
        DatabaseConnection(NativeDatabase.memory()),
      );
      repo = SyncRepository(db);
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://down:8765', hostId: 'host-down'),
        FushiClientUrl(url: 'http://up:8765', hostId: 'host-up'),
      ]);
      await repo.setFushiClientToken('tok');
    });
    tearDown(() => db.close());

    test('按 host 报传输层结局；判死的 host 不再发请求', () async {
      final List<String> requested = <String>[];
      final RemoteDictionaryReachability reach = RemoteDictionaryReachability();
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          requested.add(request.url.host);
          if (request.url.host == 'down') {
            throw http.ClientException('connection refused', request.url);
          }
          return http.Response(
            jsonEncode(<String, dynamic>{'type': 'dictionaryResult'}),
            200,
          );
        }),
        skipDictionaryHost: reach.shouldSkip,
        onDictionaryHostOutcomes: reach.record,
      );

      expect(
        await client.searchDictionary(
          term: '猫',
          wildcards: false,
          maximumTerms: 10,
        ),
        isNull,
      );
      expect(requested, <String>['down', 'up']);
      expect(reach.isUnreachable('host-down'), isTrue);
      expect(reach.hosts['host-up']!.reachable, isTrue);

      requested.clear();
      await client.searchDictionary(
        term: '猫',
        wildcards: false,
        maximumTerms: 10,
      );
      expect(requested, <String>['up'], reason: '判死的 host 被跳过，不再付它的连接超时');
    });

    test('弹窗进程：查词客户端的后台探测挂上追踪器，判死后查词零请求，探通即恢复', () {
      fakeAsync((FakeAsync async) {
        final List<String> requested = <String>[];
        bool downIsBack = false;
        final RemoteDictionaryReachability reach = RemoteDictionaryReachability(
          now: () =>
              DateTime.fromMillisecondsSinceEpoch(1000000).add(async.elapsed),
          reprobeInterval: const Duration(seconds: 45),
        );
        final FushiRemoteLookupClient client = FushiRemoteLookupClient(
          repo: repo,
          httpClient: MockClient((http.Request request) async {
            requested.add(
              '${request.method} ${request.url.host}${request.url.path}',
            );
            if (request.url.host == 'down' && !downIsBack) {
              throw http.ClientException('connection refused', request.url);
            }
            return http.Response(
              request.url.path == kRemoteDictionaryCatalogPath
                  ? '[]'
                  : jsonEncode(<String, dynamic>{'type': 'dictionaryResult'}),
              200,
            );
          }),
          skipDictionaryHost: reach.shouldSkip,
          onDictionaryHostOutcomes: reach.record,
        );
        reach.probe = client.probeDictionaryHost;

        void lookup() {
          client.searchDictionary(
            term: '猫',
            wildcards: false,
            maximumTerms: 10,
          );
          async.flushMicrotasks();
        }

        lookup();
        expect(reach.isUnreachable('host-down'), isTrue);

        // 过了再探测间隔：没有目录服务也不放行查词去碰死 host，改由后台探测去问。
        requested.clear();
        async.elapse(const Duration(seconds: 46));
        expect(requested, <String>[
          'GET down$kRemoteDictionaryCatalogPath',
        ], reason: '后台探测只打 down 的目录端点');
        requested.clear();
        lookup();
        expect(requested, <String>[
          'POST up/api/lookup/dictionary',
        ], reason: '查词仍跳过判死的 host');

        downIsBack = true;
        requested.clear();
        async.elapse(const Duration(seconds: 45));
        expect(requested, <String>['GET down$kRemoteDictionaryCatalogPath']);
        expect(reach.hosts['host-down']!.reachable, isTrue);
        requested.clear();
        lookup();
        expect(requested, <String>[
          'POST down/api/lookup/dictionary',
        ], reason: '恢复后首个候选 down 直接回答');
        reach.dispose();
      });
    });

    test('全部 host 判死：零请求、返回 null、不抛 RemoteLookupUnreachableError', () async {
      int requests = 0;
      final RemoteDictionaryReachability reach = RemoteDictionaryReachability()
        ..record(<String, bool>{'host-down': false, 'host-up': false});
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient((http.Request request) async {
          requests++;
          return http.Response('{}', 200);
        }),
        skipDictionaryHost: reach.shouldSkip,
        onDictionaryHostOutcomes: reach.record,
      );
      expect(
        await client.searchDictionary(
          term: '猫',
          wildcards: false,
          maximumTerms: 10,
        ),
        isNull,
      );
      expect(requests, 0);
    });

    test('首次发现全部不可达仍抛 RemoteLookupUnreachableError，并记下两台都判死', () async {
      final RemoteDictionaryReachability reach = RemoteDictionaryReachability();
      final FushiRemoteLookupClient client = FushiRemoteLookupClient(
        repo: repo,
        httpClient: MockClient(
          (http.Request request) async =>
              throw http.ClientException('refused', request.url),
        ),
        skipDictionaryHost: reach.shouldSkip,
        onDictionaryHostOutcomes: reach.record,
      );
      await expectLater(
        client.searchDictionary(term: '猫', wildcards: false, maximumTerms: 10),
        throwsA(isA<RemoteLookupUnreachableError>()),
      );
      expect(reach.isUnreachable('host-down'), isTrue);
      expect(reach.isUnreachable('host-up'), isTrue);
    });
  });
}
