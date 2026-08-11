import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

/// BUG-1550 守卫：互联凭据的**基数**必须与对端地址的基数一致。
///
/// host 侧 per-peer token（TODO-961 M1b）按 client 的稳定 deviceId 逐台派发，而
/// 「对端列表」里的地址可以属于不同的 host（LAN 发现里点谁配谁，每次都往同一个
/// 列表 append）。凭据若只有一个全局槽，配对第二台就把第一台的 token 覆盖掉——
/// 第一台地址仍排在候选前列、依然可达，却拿着第二台的 token 撞 401。
FushiDatabase _testDb() => FushiDatabase.forTesting(
      DatabaseConnection(NativeDatabase.memory()),
    );

void main() {
  group('FushiClientUrl.token wire 往返', () {
    test('token 随 toJson/fromJson 往返，不丢', () {
      const FushiClientUrl row = FushiClientUrl(
        url: 'http://peer:8765',
        fingerprintSha256: 'aa:bb',
        deviceName: 'Desktop',
        token: 'per-peer-token',
      );
      final FushiClientUrl back = FushiClientUrl.fromJson(row.toJson());
      expect(back.url, row.url);
      expect(back.fingerprintSha256, row.fingerprintSha256);
      expect(back.deviceName, row.deviceName);
      expect(back.token, 'per-peer-token');
    });

    test('无 token 的老配置解析成 null（additive，零破坏）', () {
      final FushiClientUrl back = FushiClientUrl.fromJson(
        <String, dynamic>{'url': 'http://legacy:8765', 'enabled': true},
      );
      expect(back.token, isNull);
    });

    test('空 token 不写进 wire（不产生噪声键）', () {
      const FushiClientUrl row =
          FushiClientUrl(url: 'http://peer:8765', token: '');
      expect(row.toJson().containsKey('token'), isFalse);
    });
  });

  group('interconnectTokenFor', () {
    test('地址行自带的 token 优先于全局键', () {
      expect(
        interconnectTokenFor(
          const FushiClientUrl(url: 'u', token: 'own'),
          'global',
        ),
        'own',
      );
    });

    test('行上没有 token 时回落全局键', () {
      expect(
        interconnectTokenFor(const FushiClientUrl(url: 'u'), 'global'),
        'global',
      );
    });

    test('两边都空 → null（调用方按未配置凭据处理）', () {
      expect(
          interconnectTokenFor(const FushiClientUrl(url: 'u'), null), isNull);
      expect(interconnectTokenFor(const FushiClientUrl(url: 'u'), ''), isNull);
      expect(
        interconnectTokenFor(const FushiClientUrl(url: 'u', token: ''), ''),
        isNull,
      );
    });
  });

  group('SyncRepository per-peer 凭据落库', () {
    test('配对第二台不再覆盖第一台的凭据', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://peer-a:8765'),
        FushiClientUrl(url: 'http://peer-b:8765'),
      ]);

      await repo.setFushiClientTokenForUrl('http://peer-a:8765', 'token-a');
      await repo.setFushiClientTokenForUrl('http://peer-b:8765', 'token-b');

      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      expect(urls[0].token, 'token-a',
          reason: '配对 B 不该把 A 的凭据抹掉——这正是 BUG-1550 的根因');
      expect(urls[1].token, 'token-b');
      // 全局键仍随最后一次配对更新，供行上没有 token 的老条目回落。
      expect(await repo.getFushiClientToken(), 'token-b');
    });

    test('地址不在列表里时只写全局键，不丢凭据', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientTokenForUrl('http://ghost:8765', 'tok');
      expect(await repo.getFushiClientToken(), 'tok');
      expect(await repo.getFushiClientUrls(), isEmpty);
    });

    test('手贴 token 清掉各行残留凭据（显式覆盖必须生效）', () async {
      final FushiDatabase db = _testDb();
      addTearDown(db.close);
      final SyncRepository repo = SyncRepository(db);
      await repo.setFushiClientUrls(const <FushiClientUrl>[
        FushiClientUrl(url: 'http://peer-a:8765', token: 'stale-a'),
        FushiClientUrl(
          url: 'http://peer-b:8765',
          token: 'stale-b',
          fingerprintSha256: 'aa:bb',
          deviceName: 'B',
        ),
      ]);

      await repo.clearFushiClientUrlTokens();

      final List<FushiClientUrl> urls = await repo.getFushiClientUrls();
      expect(urls.map((FushiClientUrl u) => u.token), everyElement(isNull));
      // 清的只是凭据，地址身份（指纹/展示名/启用位）一个都不能掉。
      expect(urls[1].fingerprintSha256, 'aa:bb');
      expect(urls[1].deviceName, 'B');
      expect(urls[1].enabled, isTrue);
    });
  });
}
