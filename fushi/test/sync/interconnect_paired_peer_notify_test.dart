import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi_core/fushi_core.dart';

import '../helpers/source_guard.dart';
import 'sync_settings_schema_source_corpus.dart';

/// BUG-1558：host 审批通过一台新设备后，`fushi_paired_peers` 落了库，但
/// [FushiSyncServerController] 一声不吭 —— 设置页的「已配对设备」列表是进页那一刻的
/// 快照，只在 `_loadSettings` / 吊销后才重拉。用户开着设置页看对方配对成功，列表里却
/// 压根没有这台，只能以为没配上、再配一遍。
///
/// 修复：配对表的**任何**变动都从 controller 广播（落库 + 吊销两处），视图监听即可。
void main() {
  late FushiDatabase db;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  FushiSyncServerController buildController() => FushiSyncServerController(
        navigatorKey: GlobalKey<NavigatorState>(),
        database: () => db,
        syncDataDir: () => Directory.systemTemp.path,
        remoteLookupServiceFactory: () =>
            throw UnimplementedError('lookup not used in this test'),
      );

  test('新设备配对落库后通知监听者（列表能当场刷新）', () async {
    final FushiSyncServerController controller = buildController();
    addTearDown(controller.dispose);
    int notified = 0;
    controller.addListener(() => notified++);

    await controller.debugPersistPairedPeer(const FushiPairedPeerRegistration(
      peerId: 'device-a',
      token: 'peer-token-a',
      deviceName: 'Phone A',
      remoteAddress: '192.168.1.50',
    ));

    expect(
        (await controller.pairedPeers())
            .map((FushiPairedPeerRow p) => p.peerId),
        <String>['device-a']);
    expect(notified, greaterThan(0),
        reason: 'BUG-1558：不通知就等于「配对成功了但设置页永远看不到这台设备」');
  });

  test('吊销已配对设备同样通知（同一条广播契约）', () async {
    final FushiSyncServerController controller = buildController();
    addTearDown(controller.dispose);
    await controller.debugPersistPairedPeer(const FushiPairedPeerRegistration(
      peerId: 'device-b',
      token: 'peer-token-b',
      deviceName: 'Phone B',
      remoteAddress: '192.168.1.51',
    ));

    int notified = 0;
    controller.addListener(() => notified++);
    expect(await controller.revokePeer('device-b'), isTrue);
    expect(notified, greaterThan(0));
    expect(await controller.pairedPeers(), isEmpty);
  });

  test('吊销一台不存在的设备不广播（无变化不吵醒视图）', () async {
    final FushiSyncServerController controller = buildController();
    addTearDown(controller.dispose);
    int notified = 0;
    controller.addListener(() => notified++);
    expect(await controller.revokePeer('never-paired'), isFalse);
    expect(notified, 0);
  });

  test('重复配对同一设备只轮换其 token，仍然广播', () async {
    final FushiSyncServerController controller = buildController();
    addTearDown(controller.dispose);
    await controller.debugPersistPairedPeer(const FushiPairedPeerRegistration(
      peerId: 'device-c',
      token: 'token-old',
      deviceName: 'Tablet',
      remoteAddress: '192.168.1.60',
    ));
    int notified = 0;
    controller.addListener(() => notified++);
    await controller.debugPersistPairedPeer(const FushiPairedPeerRegistration(
      peerId: 'device-c',
      token: 'token-new',
      deviceName: 'Tablet',
      remoteAddress: '192.168.1.61',
    ));
    final List<FushiPairedPeerRow> peers = await controller.pairedPeers();
    expect(peers.length, 1, reason: 'peerId UNIQUE：重复配对不该多出一行');
    expect(peers.single.token, 'token-new');
    expect(notified, greaterThan(0));
  });

  group('接线半边：广播得真有人听（否则 notifyListeners 白发）', () {
    test('设置页收到 controller 通知时重拉已配对设备列表', () {
      final String source = maskComments(readSyncSettingsSchemaSource());
      final int start = source.indexOf('  void _onServerChanged() {');
      expect(start, greaterThanOrEqualTo(0), reason: '_onServerChanged 丢失');
      final int end = source.indexOf('Future<void> _loadSettings()', start);
      expect(end, greaterThan(start));
      final String handler = source.substring(start, end);
      expect(handler.contains('_reloadPairedPeers()'), isTrue,
          reason: 'BUG-1558：只 setState 不重拉，列表永远是进页那一刻的快照');
    });

    test('取代旧审批框超时时按失败收尾，不拖悬挂态往下走', () {
      final String source = maskComments(
          File('lib/src/sync/fushi_server_controller.dart').readAsStringSync());
      final int start = source.indexOf(
          '  Future<bool> _promptPairApproval(FushiPairRequest request) async {');
      expect(start, greaterThanOrEqualTo(0), reason: '_promptPairApproval 丢失');
      final int end = source.indexOf('bool _isSamePairSource(', start);
      expect(end, greaterThan(start));
      final String body = source.substring(start, end);
      expect(body.contains('onTimeout:'), isTrue,
          reason: '等旧弹窗 teardown 必须有超时，否则一个卡住的弹窗能挂死配对 handler');
      expect(body.contains('if (!closedInTime) return false;'), isTrue,
          reason: '超时后继续往下走 = 把新会话的 PIN 写进仍属于旧弹窗的共享单值态，'
              '旧弹窗 teardown 时又把它清掉——悬挂弹窗 + PIN 错乱两头落空');
      expect(body.contains('if (identical(_pairDialogClosed, closed))'), isTrue,
          reason: '超时的 completer 必须从共享字段摘掉，否则旧弹窗真 teardown 时会去'
              'complete 下一个请求的 completer');
    });
  });
}
