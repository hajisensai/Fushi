import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart' show SyncBackendError;
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
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
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
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
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
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
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
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
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
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
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
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
      return url.contains('192.168.1.20');
    });

    await backend.authenticate(repo: repo);
    expect(backend.activeBaseUrl, contains('192.168.1.20'),
        reason: '首次解析应落在真可达的那台');

    // 切页面 → restoreAuth。配置一字未改。
    expect(await backend.restoreAuth(repo), isTrue);
    expect(
      backend.activeBaseUrl,
      contains('192.168.1.20'),
      reason: 'BUG-1559：会话已解析就不能被重建成候选[0]——'
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
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
      return !url.contains('192.168.1.10');
    });
    await backend.authenticate(repo: repo);
    expect(backend.activeBaseUrl, contains('192.168.1.20'));

    // 换到另一台对端（地址集合变了 → 会话身份变了）。
    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://192.168.1.30:8384'),
    ]);
    expect(await backend.restoreAuth(repo), isTrue);
    expect(backend.activeBaseUrl, contains('192.168.1.30'),
        reason: '配置真变了就必须重建，否则会拿旧对端的句柄发请求');
  });

  // ── BUG-1180：换对端必须让远端清单缓存失效 ────────────────────────────
  //
  // 这两条钉的是「换对端后旧清单不得被沿用」。分两半各自可负向验证：
  //   ① 后端半边——身份变了必须自增 `sessionIdentityRevision`（去掉 `_loadConfig`
  //      里的自增 → 本组三条全红）。
  //   ② 接线半边——provider 必须订阅它并 `invalidateAll`（去掉 provider 里的
  //      addListener → 「缓存随对端身份变化失效」红）。

  test('BUG-1180: 换对端地址自增会话身份版本号', () async {
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
      return true;
    });
    await backend.restoreAuth(repo);
    final int before = backend.sessionIdentityRevision.value;

    await repo.setFushiClientUrls(<FushiClientUrl>[
      const FushiClientUrl(url: 'http://192.168.1.99:8384'),
    ]);
    await backend.restoreAuth(repo);

    expect(backend.sessionIdentityRevision.value, greaterThan(before),
        reason: 'BUG-1180：换了对端，远端清单缓存必须收到失效信号');
  });

  test('BUG-1180: 换令牌自增会话身份版本号', () async {
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
      return true;
    });
    await backend.restoreAuth(repo);
    final int before = backend.sessionIdentityRevision.value;

    await repo.setFushiClientToken('token-b');
    await backend.restoreAuth(repo);

    expect(backend.sessionIdentityRevision.value, greaterThan(before),
        reason: '令牌是对端身份的一部分（局域网配对就是这么落库的）');
  });

  test('BUG-1180: 配置没变不自增（否则每次切页面都白白清空缓存）', () async {
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
      return true;
    });
    await backend.restoreAuth(repo);
    final int before = backend.sessionIdentityRevision.value;

    await backend.restoreAuth(repo);
    await backend.restoreAuth(repo);

    expect(backend.sessionIdentityRevision.value, before,
        reason: '配置没变还清缓存，等于把 BUG-1180 的缓存收益全退回去');
  });

  test('signOut 后配置身份归零，下次连接必然重探', () async {
    int probes = 0;
    final InterconnectSyncBackend backend =
        InterconnectSyncBackend.withProbe((String url, String token) async {
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
}
