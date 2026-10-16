import 'package:drift/native.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi/utils.dart';

/// host 配对审批的「允许 · 这是我的设备」/「仅互联」：选择随 per-peer 凭据落库成
/// peer 级「我的设备」标记——只有被标记的 peer 能跟随本机 Fushi 账户自动登录
/// （`/api/interconnect/leaderboard-link` 的第五道门）。历史 peer 默认「仅互联」。
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

  FushiPairRequest request(String deviceId) => FushiPairRequest(
    deviceName: 'Phone',
    remoteAddress: '192.168.1.20',
    pinVerified: true,
    clientDeviceId: deviceId,
  );

  FushiPairedPeerRegistration registration(String deviceId, String token) =>
      FushiPairedPeerRegistration(
        peerId: deviceId,
        token: token,
        deviceName: 'Phone',
        remoteAddress: '192.168.1.20',
      );

  Future<bool> approve(
    WidgetTester tester,
    FushiSyncServerController controller,
    String deviceId,
    String button,
  ) async {
    final Future<bool> approved = controller.debugPromptPairApproval(
      request(deviceId),
    );
    await tester.pump();
    expect(find.text(t.sync_pair_allow_owner_device), findsOneWidget);
    expect(find.text(t.sync_pair_allow_interconnect_only), findsOneWidget);
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
    return approved;
  }

  testWidgets('选「这是我的设备」：落库后标记为我的设备，凭据可代绑', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await pumpApp(tester, navKey);

    expect(
      await approve(
        tester,
        controller,
        'dev-a',
        t.sync_pair_allow_owner_device,
      ),
      isTrue,
    );
    await tester.runAsync(() async {
      await controller.debugPersistPairedPeer(registration('dev-a', 'tok-a'));
      expect(await controller.ownerDevicePeerIds(), <String>{'dev-a'});
      expect(await SyncRepository(db).isOwnerDevicePeerToken('tok-a'), isTrue);
    });
  });

  testWidgets('选「仅互联」：配对照常成功，但不是我的设备、不能代绑', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await pumpApp(tester, navKey);

    expect(
      await approve(
        tester,
        controller,
        'dev-b',
        t.sync_pair_allow_interconnect_only,
      ),
      isTrue,
    );
    await tester.runAsync(() async {
      await controller.debugPersistPairedPeer(registration('dev-b', 'tok-b'));
      expect(await controller.ownerDevicePeerIds(), isEmpty);
      expect(await SyncRepository(db).isOwnerDevicePeerToken('tok-b'), isFalse);
    });
  });

  testWidgets('历史 peer 默认仅互联；重新配对按新选择显式重写；吊销清掉标记', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await pumpApp(tester, navKey);

    await tester.runAsync(() async {
      // 升级前就配对过的 peer：表里有行，标记集合里没有。
      await db.upsertPairedPeer(
        FushiPairedPeersCompanion.insert(
          peerId: 'old',
          token: 'tok-old',
          pairedAtMs: 1,
        ),
      );
      expect(
        await SyncRepository(db).isOwnerDevicePeerToken('tok-old'),
        isFalse,
      );
      // 列表里手动标记 → 可代绑；未知 token 恒 false。
      await controller.setOwnerDevicePeer('old', true);
      expect(
        await SyncRepository(db).isOwnerDevicePeerToken('tok-old'),
        isTrue,
      );
      expect(await SyncRepository(db).isOwnerDevicePeerToken('tok-x'), isFalse);
    });

    // 同一台设备重新配对、这次选「仅互联」：旧标记被显式去掉。
    expect(
      await approve(
        tester,
        controller,
        'old',
        t.sync_pair_allow_interconnect_only,
      ),
      isTrue,
    );
    await tester.runAsync(() async {
      await controller.debugPersistPairedPeer(registration('old', 'tok-old2'));
      expect(await controller.ownerDevicePeerIds(), isEmpty);

      // 没经过审批弹窗的落库（扫码票据配对）也一律不是我的设备。
      await controller.setOwnerDevicePeer('old', true);
      await controller.debugPersistPairedPeer(registration('old', 'tok-old3'));
      expect(await controller.ownerDevicePeerIds(), isEmpty);

      await controller.setOwnerDevicePeer('old', true);
      expect(await controller.revokePeer('old'), isTrue);
      expect(await controller.ownerDevicePeerIds(), isEmpty);
    });
  });
}
