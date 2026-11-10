import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi/i18n/strings.g.dart';

/// BUG-4279：app 端回环对端仍算局域网（同机多实例 / 本机联调），但本机跑着反代 /
/// 穿透时它可能来自外网。审批框对回环来源加一行提醒，局域网来源不加。
void main() {
  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
  });

  FushiSyncServerController buildController(GlobalKey<NavigatorState> navKey) {
    return FushiSyncServerController(
      navigatorKey: navKey,
      database: () => throw UnimplementedError('db not used in this test'),
      syncDataDir: () => '.',
      remoteLookupServiceFactory: () =>
          throw UnimplementedError('lookup not used in this test'),
    );
  }

  Future<void> expectHint(
    WidgetTester tester,
    String remote, {
    required bool shown,
  }) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          home: const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );

    final Future<bool> approval = controller.debugPromptPairApproval(
      FushiPairRequest(deviceName: 'Phone', remoteAddress: remote),
    );
    await tester.pump();
    expect(find.text('Phone · $remote'), findsOneWidget);
    expect(
      find.text(t.sync_pair_source_loopback_hint),
      shown ? findsOneWidget : findsNothing,
      reason: remote,
    );

    await tester.tap(find.text(t.sync_pair_deny));
    await tester.pumpAndSettle();
    expect(await approval, isFalse);
  }

  testWidgets('回环来源显示提醒', (WidgetTester tester) async {
    await expectHint(tester, '127.0.0.1', shown: true);
  });

  testWidgets('IPv6 回环与带 (proxied) 的回环来源也显示提醒', (WidgetTester tester) async {
    await expectHint(tester, '::1', shown: true);
    await expectHint(tester, '127.0.0.1 (proxied)', shown: true);
  });

  testWidgets('局域网来源不显示提醒', (WidgetTester tester) async {
    await expectHint(tester, '192.168.1.20', shown: false);
  });

  testWidgets('P2P 隧道来源不显示提醒', (WidgetTester tester) async {
    await expectHint(tester, kFushiP2pRemoteAddress, shown: false);
  });
}
