import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi_engine/sync/pairing/fushi_pairing_protocol.dart';
import 'package:fushi/utils.dart';

/// host 配对审批的「允许 · 这是我的设备」/「仅互联」：选择只写进**本会话**的
/// [FushiPairOwnerDeviceGrant]（server 在 confirm 时结合设备钥匙验签结论落成
/// [FushiPairedPeerRegistration.ownerDevice]），controller 落库时只认 registration——
/// 不再按 deviceId 记全局账（PR #2258 审查问题 1）。只有被标记、且配对时证明过设备
/// 钥匙的 peer 能跟随本机 Fushi 账户自动登录（`/api/interconnect/leaderboard-link`）。
void main() {
  late FushiDatabase db;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    db = FushiDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() => db.close());

  FushiSyncServerController buildController(GlobalKey<NavigatorState> navKey) =>
      FushiSyncServerController(
        navigatorKey: navKey,
        database: () => db,
        syncDataDir: () => '.',
        remoteLookupServiceFactory: () =>
            throw UnimplementedError('lookup not used in this test'),
      );

  Future<void> pumpApp(WidgetTester tester, GlobalKey<NavigatorState> navKey) =>
      tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            navigatorKey: navKey,
            home: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      );

  FushiPairRequest request(
    String deviceId, {
    FushiPairOwnerDeviceGrant? grant,
  }) => FushiPairRequest(
    deviceName: 'Phone',
    remoteAddress: '192.168.1.20',
    pinVerified: true,
    clientDeviceId: deviceId,
    ownerDeviceGrant: grant,
  );

  FushiPairedPeerRegistration registration(
    String deviceId,
    String token, {
    bool ownerDevice = false,
    String? fingerprint,
  }) => FushiPairedPeerRegistration(
    peerId: deviceId,
    token: token,
    deviceName: 'Phone',
    remoteAddress: '192.168.1.20',
    ownerDevice: ownerDevice,
    deviceKeyFingerprint: fingerprint,
  );

  Future<bool> approve(
    WidgetTester tester,
    FushiSyncServerController controller,
    FushiPairRequest req,
    String button,
  ) async {
    final Future<bool> approved = controller.debugPromptPairApproval(req);
    await tester.pump();
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
    return approved;
  }

  testWidgets('选「这是我的设备」只写进本会话的 grant，不碰别的会话', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await pumpApp(tester, navKey);

    final FushiPairOwnerDeviceGrant grant = FushiPairOwnerDeviceGrant();
    final Future<bool> approved = controller.debugPromptPairApproval(
      request('dev-a', grant: grant),
    );
    await tester.pump();
    expect(find.text(t.sync_pair_allow_owner_device), findsOneWidget);
    expect(find.text(t.sync_pair_allow_interconnect_only), findsOneWidget);
    await tester.tap(find.text(t.sync_pair_allow_owner_device));
    await tester.pumpAndSettle();
    expect(await approved, isTrue);
    expect(grant.granted, isTrue);

    // 审批本身不落任何标记：同一 deviceId 之后的落库（例如免审批的扫码票据配对）
    // 只认它自己 registration 上的结论。
    await tester.runAsync(() async {
      await controller.debugPersistPairedPeer(
        registration('dev-a', 'tok-a', fingerprint: 'fp-a'),
      );
      expect(await controller.ownerDevicePeerIds(), isEmpty);
      expect(await SyncRepository(db).isOwnerDevicePeerToken('tok-a'), isFalse);
    });
  });

  testWidgets('选「仅互联」：grant 保持 false', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await pumpApp(tester, navKey);

    final FushiPairOwnerDeviceGrant grant = FushiPairOwnerDeviceGrant();
    expect(
      await approve(
        tester,
        controller,
        request('dev-b', grant: grant),
        t.sync_pair_allow_interconnect_only,
      ),
      isTrue,
    );
    expect(grant.granted, isFalse);
  });

  testWidgets('会话不提供 grant（旧 client 无设备钥匙）：不出现「我的设备」按钮', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await pumpApp(tester, navKey);

    final Future<bool> approved = controller.debugPromptPairApproval(
      request('dev-legacy'),
    );
    await tester.pump();
    expect(find.text(t.sync_pair_allow_owner_device), findsNothing);
    await tester.tap(find.text(t.sync_pair_allow_interconnect_only));
    await tester.pumpAndSettle();
    expect(await approved, isTrue);
  });

  testWidgets('落库按 registration 显式重写；没验签的 peer 标不上；吊销清掉标记与指纹', (
    WidgetTester tester,
  ) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await pumpApp(tester, navKey);

    await tester.runAsync(() async {
      final SyncRepository repo = SyncRepository(db);
      // server 核实过（本会话选了我的设备 + 设备钥匙验签通过）→ 我的设备。
      await controller.debugPersistPairedPeer(
        registration('dev', 'tok-1', ownerDevice: true, fingerprint: 'fp'),
      );
      expect(await controller.ownerDevicePeerIds(), <String>{'dev'});
      expect(await repo.isOwnerDevicePeerToken('tok-1'), isTrue);

      // 同一 peerId 重新配对（票据 / 仅互联）→ 显式去掉，不沿用旧标记。
      await controller.debugPersistPairedPeer(
        registration('dev', 'tok-2', fingerprint: 'fp'),
      );
      expect(await controller.ownerDevicePeerIds(), isEmpty);
      // 证明过设备钥匙 → 列表里可以手动标记。
      expect(await controller.setOwnerDevicePeer('dev', true), isTrue);
      expect(await repo.isOwnerDevicePeerToken('tok-2'), isTrue);

      // 没证明设备钥匙的重新配对：指纹被清，标记也没了，且再也标不上。
      await controller.debugPersistPairedPeer(registration('dev', 'tok-3'));
      expect(await controller.ownerDevicePeerIds(), isEmpty);
      expect(await controller.setOwnerDevicePeer('dev', true), isFalse);
      expect(await repo.isOwnerDevicePeerToken('tok-3'), isFalse);
      // registration 自称 ownerDevice 但没有指纹：不生效（纵深防御）。
      await controller.debugPersistPairedPeer(
        registration('dev', 'tok-4', ownerDevice: true),
      );
      expect(await repo.isOwnerDevicePeerToken('tok-4'), isFalse);

      // 升级前配对过的 peer：表里有行、没有指纹 → 标不上。
      await db.upsertPairedPeer(
        FushiPairedPeersCompanion.insert(
          peerId: 'old',
          token: 'tok-old',
          pairedAtMs: 1,
        ),
      );
      expect(await controller.setOwnerDevicePeer('old', true), isFalse);
      expect(await repo.isOwnerDevicePeerToken('tok-old'), isFalse);
      expect(await repo.isOwnerDevicePeerToken('tok-x'), isFalse);

      await controller.debugPersistPairedPeer(
        registration('dev', 'tok-5', ownerDevice: true, fingerprint: 'fp'),
      );
      expect(await controller.revokePeer('dev'), isTrue);
      expect(await controller.ownerDevicePeerIds(), isEmpty);
      expect(await controller.deviceKeyVerifiedPeerIds(), isEmpty);
    });
  });
}
