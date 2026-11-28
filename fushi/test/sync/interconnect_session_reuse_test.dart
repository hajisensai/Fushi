import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/interconnect_peer_addresses.dart'
    show reportInterconnectCandidateReached;
import 'package:fushi/src/sync/sync_backend.dart'
    show SyncBackendError, SyncPeerUnreachableError;
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1183 根因守卫：`restoreAuth` 不得无条件作废已解析的地址。
///
/// 症状——每切一次页面，互联请求都要先把全部候选地址重探测一遍才发真正的业务请求。
/// 真根因：`_loadConfig` 末尾无条件 `_sessionResolved = false`，而 `restoreAuth` 是
/// 每个消费方（书架 / 视频页 / 首页 dashboard）取 client 的必经之路，且
/// [InterconnectSyncBackend] 是单例——三个页面互相把对方刚探明的会话踩掉。
///
/// 修复后的语义：会话该不该重来只取决于**配置是否真变**（地址集合 / 钉扎指纹 /
/// 令牌）。地址失联后的换路由径走 `clearCache()`，与本处正交。
void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://192.168.1.10:8384'),
    ]);
    await repo.setFushiClientToken('token-a');
  });

  tearDown(() async => db.close());

  test('配置未变时 restoreAuth 不触发全候选重探测', () async {
    int probes = 0;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      probes++;
      return true;
    });

    // 首次连接：必然要探一次。
    await backend.authenticate(repo: repo);
    expect(probes, 1);

    // 模拟「切到另一个页面」——该页面的 _resolveRemoteXClient 会先 restoreAuth。
    expect(await backend.restoreAuth(repo), isTrue);
    await backend.authenticate(repo: repo);
    expect(probes, 1, reason: 'BUG-1183：配置没变就不该把已探明可达的地址作废重探');

    // 再切两次页面，仍不该重探。
    await backend.restoreAuth(repo);
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    expect(probes, 1);
  });

  test('令牌变化触发重探测（凭据换了，会话必须重来）', () async {
    int probes = 0;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      probes++;
      return true;
    });

    await backend.authenticate(repo: repo);
    expect(probes, 1);

    await repo.setFushiClientToken('token-b');
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    expect(probes, 2, reason: '令牌变了必须重探，否则会拿旧凭据打新会话');
  });

  test('候选地址集合变化触发重探测（换了对端）', () async {
    int probes = 0;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      probes++;
      return true;
    });

    await backend.authenticate(repo: repo);
    expect(probes, 1);

    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://192.168.1.99:8384'),
    ]);
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    expect(probes, 2, reason: '地址集合变了必须重探');
  });

  test('钉扎指纹变化触发重解析（同地址换证书也是换身份）', () async {
    int probes = 0;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      probes++;
      return true;
    });

    await backend.authenticate(repo: repo);
    expect(probes, 1);

    // 给同一个地址挂上钉扎指纹 = 换了身份。
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(
        url: 'http://192.168.1.10:8384',
        fingerprintSha256: 'aa:bb:cc',
      ),
    ]);
    await backend.restoreAuth(repo);

    // 带指纹的候选**绕过**注入 probe，走 `_pinnedReachabilityProbe`（真实 TLS 握手），
    // 所以这里数不到 probe 次数。改断言「确实重新走了解析」——地址不可达导致抛错，
    // 正好证明它没有沿用上一次已解析的会话（沿用的话 authenticate 会直接返回）。
    await expectLater(
      backend.authenticate(repo: repo),
      throwsA(isA<SyncBackendError>()),
      reason: '指纹是地址身份的一部分，变了必须重新解析而不是沿用旧会话',
    );
  });

  test('仅对端展示名变化不触发重探测（deviceName 不进会话身份）', () async {
    int probes = 0;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      probes++;
      return true;
    });

    await backend.authenticate(repo: repo);
    expect(probes, 1);

    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(
        url: 'http://192.168.1.10:8384',
        deviceName: '书房台式机',
      ),
    ]);
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    expect(probes, 1, reason: '展示名是纯 UI 字段，改它不该引发一轮全候选探测');
  });

  // ── BUG-1559：restoreAuth 不得把已解析地址打回候选[0] ──────────
  //
  // BUG-1183 只修了一半：「要不要重探」已经改成看配置签名，但 restoreAuth 仍无条件
  // 重建临时句柄（候选[0]）。于是切一次页面：_ops 滑回候选[0]（常常是一条不可达
  // 的旧地址），_sessionResolved 却还是 true → [_ensureResolved] 直接 return → 永不重探。

  test('BUG-1559: restoreAuth 保留已解析的可达地址，不打回候选[0]', () async {
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://192.168.1.10:8384'), // 不可达
      const FushiClientUrl(url: 'http://192.168.1.20:8384'), // 可达
    ]);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      return url.contains('192.168.1.20');
    });

    await backend.authenticate(repo: repo);
    expect(
      backend.activeBaseUrl,
      contains('192.168.1.20'),
      reason: '首次解析应落在真可达的那台',
    );

    // 切页面 → restoreAuth。配置一字未改。
    expect(await backend.restoreAuth(repo), isTrue);
    expect(
      backend.activeBaseUrl,
      contains('192.168.1.20'),
      reason:
          'BUG-1559：会话已解析就不能被重建成候选[0]——'
          '那条不可达，而且 _sessionResolved 仍为 true，永不重探',
    );

    // 后续网络操作不需重探，且仍然打在可达地址上。
    await backend.ensureResolved();
    expect(backend.activeBaseUrl, contains('192.168.1.20'));
  });

  test('BUG-1559: 配置真变了仍旧重建句柄（不能把修复做成「永不更新」）', () async {
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://192.168.1.10:8384'),
      const FushiClientUrl(url: 'http://192.168.1.20:8384'),
    ]);
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      return !url.contains('192.168.1.10');
    });
    await backend.authenticate(repo: repo);
    expect(backend.activeBaseUrl, contains('192.168.1.20'));

    // 换到另一台对端（地址集合变了 → 会话身份变了）。
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://192.168.1.30:8384'),
    ]);
    expect(await backend.restoreAuth(repo), isTrue);
    expect(
      backend.activeBaseUrl,
      contains('192.168.1.30'),
      reason: '配置真变了就必须重建，否则会拿旧对端的句柄发请求',
    );
  });

  // ── BUG-1180：换对端必须让远端清单缓存失效 ────────────────────────────
  //
  // 这两条钉的是「换对端后旧清单不得被沿用」。分两半各自可负向验证：
  //   ① 后端半边——身份变了必须自增 `sessionIdentityRevision`（去掉 `_loadConfig`
  //      里的自增 → 本组三条全红）。
  //   ② 接线半边——provider 必须订阅它并 `invalidateAll`（去掉 provider 里的
  //      addListener → 「缓存随对端身份变化失效」红）。

  test('BUG-1180: 换对端地址自增会话身份版本号', () async {
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      return true;
    });
    await backend.restoreAuth(repo);
    final int before = backend.sessionIdentityRevision.value;

    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://192.168.1.99:8384'),
    ]);
    await backend.restoreAuth(repo);

    expect(
      backend.sessionIdentityRevision.value,
      greaterThan(before),
      reason: 'BUG-1180：换了对端，远端清单缓存必须收到失效信号',
    );
  });

  test('BUG-1180: 换令牌自增会话身份版本号', () async {
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      return true;
    });
    await backend.restoreAuth(repo);
    final int before = backend.sessionIdentityRevision.value;

    await repo.setFushiClientToken('token-b');
    await backend.restoreAuth(repo);

    expect(
      backend.sessionIdentityRevision.value,
      greaterThan(before),
      reason: '令牌是对端身份的一部分（局域网配对就是这么落库的）',
    );
  });

  test('BUG-1180: 配置没变不自增（否则每次切页面都白白清空缓存）', () async {
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      return true;
    });
    await backend.restoreAuth(repo);
    final int before = backend.sessionIdentityRevision.value;

    await backend.restoreAuth(repo);
    await backend.restoreAuth(repo);

    expect(
      backend.sessionIdentityRevision.value,
      before,
      reason: '配置没变还清缓存，等于把 BUG-1180 的缓存收益全退回去',
    );
  });

  test('signOut 后配置身份归零，下次连接必然重探', () async {
    int probes = 0;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      probes++;
      return true;
    });

    await backend.authenticate(repo: repo);
    expect(probes, 1);

    await backend.signOut(repo: repo);
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://192.168.1.10:8384'),
    ]);
    await repo.setFushiClientToken('token-a');
    await backend.restoreAuth(repo);
    await backend.authenticate(repo: repo);
    expect(probes, 2, reason: '登出抹掉会话身份，重新配上同样的地址也要重探一次');
  });
  test('未选路时并发调用共享同一轮选路（单飞，gap-remote-4 并行起播）', () async {
    int probes = 0;
    final Completer<bool> gate = Completer<bool>();
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) {
      probes++;
      return gate.future;
    });
    expect(await backend.restoreAuth(repo), isTrue);

    // 取流与开播位置同时撞上「还没选路」。
    final Future<void> a = backend.ensureResolved();
    final Future<void> b = backend.ensureResolved();
    await pumpEventQueue();
    gate.complete(true);
    await Future.wait(<Future<void>>[a, b]);
    expect(probes, 1, reason: '两轮选路会让后完成的那轮关掉前一轮交出去的连接句柄');

    // 已选路：直接返回，不再探。
    await backend.ensureResolved();
    expect(probes, 1);
  });

  test('单飞那轮失败后不残留：并发方都收到错误，下一次调用重新选路', () async {
    int probes = 0;
    bool reachable = false;
    final InterconnectSyncBackend backend = InterconnectSyncBackend.withProbe((
      String url,
      String token,
    ) async {
      probes++;
      await pumpEventQueue();
      return reachable;
    });
    expect(await backend.restoreAuth(repo), isTrue);

    final Future<void> a = backend.ensureResolved();
    final Future<void> b = backend.ensureResolved();
    await expectLater(a, throwsA(anything));
    await expectLater(b, throwsA(anything));
    final int failedProbes = probes;

    reachable = true;
    // 失败后进了选路退避：用户手动同步（或网络变化）清零后立即重新选路。
    backend.resetResolveBackoff();
    await backend.ensureResolved();
    expect(probes, greaterThan(failedProbes), reason: '失败的那轮必须清掉，不能被下一次调用复用');
  });

  group('选路失败退避', () {
    late Duration now;
    late int probes;
    late bool reachable;
    late InterconnectSyncBackend backend;

    setUp(() async {
      now = Duration.zero;
      probes = 0;
      reachable = false;
      backend = InterconnectSyncBackend.withProbe((
        String url,
        String token,
      ) async {
        probes++;
        return reachable;
      })..monotonicNow = () => now;
      expect(await backend.restoreAuth(repo), isTrue);
    });

    tearDown(() => backend.resetResolveBackoff());

    Future<void> expectUnreachable() => expectLater(
      backend.ensureResolved(),
      throwsA(isA<SyncPeerUnreachableError>()),
    );

    test('退避时长从 2 s 起翻倍，封顶', () {
      expect(InterconnectSyncBackend.resolveBackoffFor(0), Duration.zero);
      expect(
        InterconnectSyncBackend.resolveBackoffFor(1),
        const Duration(seconds: 2),
      );
      expect(
        InterconnectSyncBackend.resolveBackoffFor(2),
        const Duration(seconds: 4),
      );
      expect(
        InterconnectSyncBackend.resolveBackoffFor(3),
        const Duration(seconds: 8),
      );
      expect(
        InterconnectSyncBackend.resolveBackoffFor(7),
        InterconnectSyncBackend.resolveBackoffMax,
      );
      expect(
        InterconnectSyncBackend.resolveBackoffFor(1000),
        InterconnectSyncBackend.resolveBackoffMax,
      );
    });

    test('退避期内请求直接抛 SyncPeerUnreachableError、不发探测；到期后才重探，间隔逐次翻倍', () async {
      await expectUnreachable();
      expect(probes, 1);
      expect(backend.resolveBackoffRemaining, const Duration(seconds: 2));

      // 会话被打回未选路（连接出错 / 重试前 clearCache）后的连串请求：都不探测。
      backend.clearCache();
      for (int i = 0; i < 5; i++) {
        await expectUnreachable();
      }
      expect(probes, 1, reason: '退避期内不该逐个探测死地址');

      now = const Duration(seconds: 2);
      await expectUnreachable();
      expect(probes, 2, reason: '到期后重探一次');
      expect(backend.resolveBackoffRemaining, const Duration(seconds: 4));

      now += const Duration(seconds: 3);
      await expectUnreachable();
      expect(probes, 2);
      now += const Duration(seconds: 1);
      await expectUnreachable();
      expect(probes, 3);
      expect(backend.resolveBackoffRemaining, const Duration(seconds: 8));
    });

    test('多次失败后封顶在 resolveBackoffMax', () async {
      for (int i = 0; i < 12; i++) {
        await expectUnreachable();
        now += backend.resolveBackoffRemaining!;
      }
      expect(probes, 12);
      await expectUnreachable();
      expect(
        backend.resolveBackoffRemaining,
        InterconnectSyncBackend.resolveBackoffMax,
      );
    });

    test('resetResolveBackoff（手动同步 / 网络变化）立即重探；选路成功清零', () async {
      await expectUnreachable();
      await expectUnreachable();
      expect(probes, 1);

      backend.resetResolveBackoff();
      expect(backend.resolveBackoffRemaining, isNull);
      reachable = true;
      await backend.ensureResolved();
      expect(probes, 2);

      // 成功清零：再掉线时从 2 s 重新起算，而不是接着上次的次数翻倍。
      reachable = false;
      backend.clearCache();
      await expectUnreachable();
      expect(backend.resolveBackoffRemaining, const Duration(seconds: 2));
    });

    test('配置变了（重新配对 / 换地址）清零退避', () async {
      await expectUnreachable();
      expect(probes, 1);
      await repo.setFushiClientUrls(<FushiClientUrl>[
        const FushiClientUrl(url: 'http://192.168.1.11:8384'),
      ]);
      await backend.restoreAuth(repo);
      reachable = true;
      await backend.ensureResolved();
      expect(probes, 2);
    });

    test('显式认证（登录 / 测试连接）不受退避约束', () async {
      await expectUnreachable();
      reachable = true;
      await backend.authenticate(repo: repo);
      expect(probes, 2);
    });

    test('别的互联请求经这台 host 的地址拿到应答：退避作废', () async {
      await expectUnreachable();
      expect(backend.resolveBackoffRemaining, isNotNull);

      // 别的 host 的应答不算。
      reportInterconnectCandidateReached(
        const FushiClientUrl(url: 'http://10.9.9.9:8384'),
      );
      expect(backend.resolveBackoffRemaining, isNotNull);

      reportInterconnectCandidateReached(
        const FushiClientUrl(url: 'http://192.168.1.10:8384'),
      );
      expect(backend.resolveBackoffRemaining, isNull);
      reachable = true;
      await backend.ensureResolved();
      expect(probes, 2);
    });
  });
}
