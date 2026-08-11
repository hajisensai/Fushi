import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/interconnect_url.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';
import 'sync_settings_schema_source_corpus.dart';

/// BUG-1557：TOFU 指纹的两处生命周期缺陷。
///
/// ① **比对顺序倒置**：client 对一个**已知** host 本该「先拿已存指纹比、不符立刻中止」，
///    实际却是拿本次握手看到的新指纹把整套流程跑完（确认身份 → 输 PIN → pair/v2 把本机
///    设备名 + deviceId 送出去 → host 把 peer 行都落了库），最后才在
///    `addFushiClientUrl` 里发现指纹不符。那时中止已经晚了：冒充者拿到了我的设备标识。
/// ② **编辑地址留旧指纹且无清除入口**：把某条地址改指另一台机器后，旧指纹仍钉在那一行，
///    https 握手每次都失败，而 UI 里没有任何清指纹的入口 —— 那条 URL 就此永久连不上，
///    用户只能删了重加（且不会知道要这么做）。
void main() {
  late FushiDatabase db;
  late SyncRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = SyncRepository(db);
  });

  tearDown(() async => db.close());

  group('已存指纹的读取与清除（②的落脚点）', () {
    test('getFushiClientFingerprint 读回该条地址钉扎的指纹', () async {
      await repo.setFushiClientUrls(<FushiClientUrl>[
        const FushiClientUrl(
          url: 'https://192.168.1.10:8384',
          fingerprintSha256: 'aa:bb:cc',
        ),
        const FushiClientUrl(url: 'http://192.168.1.20:8384'),
      ]);
      expect(await repo.getFushiClientFingerprint('https://192.168.1.10:8384'),
          'aa:bb:cc');
      expect(await repo.getFushiClientFingerprint('http://192.168.1.20:8384'),
          isNull);
      expect(await repo.getFushiClientFingerprint('http://nope:1'), isNull);
    });

    test('clearFushiClientFingerprint 只清指纹，保留启用态/展示名/该行令牌', () async {
      await repo.setFushiClientUrls(<FushiClientUrl>[
        const FushiClientUrl(
          url: 'https://192.168.1.10:8384',
          enabled: false,
          fingerprintSha256: 'aa:bb:cc',
          deviceName: '书房台式机',
          token: 'peer-token',
        ),
      ]);

      expect(
          await repo.clearFushiClientFingerprint('https://192.168.1.10:8384'),
          isTrue);
      final FushiClientUrl row = (await repo.getFushiClientUrls()).single;
      expect(row.fingerprintSha256, isNull, reason: '指纹必须真的清掉，否则重新信任无从谈起');
      expect(row.enabled, isFalse);
      expect(row.deviceName, '书房台式机');
      expect(row.token, 'peer-token',
          reason: '同一台 host 换 IP 时那份 per-peer 凭据仍有效');
    });

    test('没有指纹可清时返回 false（幂等，不白写盘）', () async {
      await repo.setFushiClientUrls(<FushiClientUrl>[
        const FushiClientUrl(url: 'http://192.168.1.10:8384'),
      ]);
      expect(await repo.clearFushiClientFingerprint('http://192.168.1.10:8384'),
          isFalse);
      expect(
          await repo.clearFushiClientFingerprint('http://absent:1'), isFalse);
    });

    test('清掉后可重新 TOFU 记录一张新证书（不再撞 MITM 守卫）', () async {
      await repo.setFushiClientUrls(<FushiClientUrl>[
        const FushiClientUrl(
          url: 'https://192.168.1.10:8384',
          fingerprintSha256: 'aa:bb:cc',
        ),
      ]);
      // 不清指纹直接写新指纹 → 必须被 MITM 守卫挡下（这条不变量不许动）。
      await expectLater(
        repo.addFushiClientUrl('https://192.168.1.10:8384',
            fingerprint: 'dd:ee:ff'),
        throwsA(isA<FushiFingerprintMismatchException>()),
      );
      await repo.clearFushiClientFingerprint('https://192.168.1.10:8384');
      await repo.addFushiClientUrl('https://192.168.1.10:8384',
          fingerprint: 'dd:ee:ff');
      expect((await repo.getFushiClientUrls()).single.fingerprintSha256,
          'dd:ee:ff');
    });
  });

  group('isSameInterconnectEndpoint：编辑地址后该不该留指纹', () {
    test('同端点（补斜杠 / 改大小写 / 显式默认端口）→ 保留', () {
      expect(
          isSameInterconnectEndpoint(
              'http://192.168.1.10:8384', 'http://192.168.1.10:8384/'),
          isTrue);
      expect(
          isSameInterconnectEndpoint(
              'https://Host.local:8384', 'https://host.local:8384'),
          isTrue);
      expect(
          isSameInterconnectEndpoint(
              'https://host.local', 'https://host.local:443'),
          isTrue);
    });

    test('换 host / 换端口 / 换 scheme → 不是同端点（必须清指纹）', () {
      expect(
          isSameInterconnectEndpoint(
              'http://192.168.1.10:8384', 'http://192.168.1.11:8384'),
          isFalse);
      expect(
          isSameInterconnectEndpoint(
              'http://192.168.1.10:8384', 'http://192.168.1.10:9000'),
          isFalse);
      expect(
          isSameInterconnectEndpoint(
              'https://192.168.1.10:8384', 'http://192.168.1.10:8384'),
          isFalse);
    });
  });

  group('①比对顺序：配对编排必须在握手前先判已存指纹', () {
    // 切片前先过共享的 maskComments（等长掉注释）：把调用注释掉、或在注释里提一句
    // 方法名，都骗不过守卫。
    // 这一段是纯 UI 编排（`_runPairingV2` 在设置页 part 里的私有 mixin），没有可低成本
    // 落地的行为测试；用源码切片钉住调用顺序——顺序正是本 bug 的全部内容。
    //
    String pairingFlowSource() {
      final String source = maskComments(readSyncSettingsSchemaSource());
      final int start = source.indexOf('  Future<void> _runPairingV2({');
      expect(start, greaterThanOrEqualTo(0), reason: '_runPairingV2 丢失');
      final int end = source.indexOf('Future<String> _onPairSuccess(', start);
      expect(end, greaterThan(start));
      return source.substring(start, end);
    }

    test('_ensurePinnedFingerprintTrusted 在身份确认与 pair/v2 之前', () {
      final String flow = pairingFlowSource();
      final int gate = flow.indexOf('_ensurePinnedFingerprintTrusted(');
      final int identity = flow.indexOf('_confirmPairIdentity(');
      final int handshake = flow.indexOf('FushiPairV2Client(');
      expect(gate, greaterThanOrEqualTo(0),
          reason: 'BUG-1557：配对编排缺少「握手前先比已存指纹」的闸——'
              '指纹不符要到 _onPairSuccess 才发现，那时设备名/deviceId 早送出去了');
      expect(identity, greaterThan(gate), reason: '已存指纹比对必须排在第一重确认之前');
      expect(handshake, greaterThan(gate), reason: '已存指纹比对必须排在 pair/v2 握手之前');
    });

    test('不符时中止并给出「清除已存指纹重新信任」的出口', () {
      final String source = maskComments(readSyncSettingsSchemaSource());
      final int start =
          source.indexOf('  Future<bool> _ensurePinnedFingerprintTrusted(');
      expect(start, greaterThanOrEqualTo(0));
      final int end =
          source.indexOf('Future<bool> _confirmFingerprintRetrust(', start);
      expect(end, greaterThan(start));
      final String gate = source.substring(start, end);
      expect(gate.contains('fingerprintEquals('), isTrue,
          reason: '比对必须复用钉扎层的归一化，别再手写第二份');
      expect(gate.contains('t.sync_pair_fingerprint_changed'), isTrue,
          reason: '中止时要说清是证书变了，而不是笼统的「配对失败」');
      expect(gate.contains('clearFushiClientFingerprint('), isTrue,
          reason: 'BUG-1557：没有清除入口，host 真换了证书时那条地址永远修不好');
    });

    test('编辑地址换端点时清掉该行指纹', () {
      final String source = maskComments(readSyncSettingsSchemaSource());
      final int start =
          source.indexOf('  Future<void> _addOrEditUrl({int? index}) async {');
      expect(start, greaterThanOrEqualTo(0), reason: '_addOrEditUrl 丢失');
      final int end = source.indexOf('Future<void> _attemptManualPair(', start);
      expect(end, greaterThan(start));
      final String edit = source.substring(start, end);
      expect(edit.contains('isSameInterconnectEndpoint('), isTrue,
          reason: 'BUG-1557：编辑保存无条件 copyWith 会把旧指纹钉到新机器上，那条地址就此死掉');
    });
  });
}
