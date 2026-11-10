import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi_engine/sync/fushi_sync_server.dart';
import 'package:fushi/i18n/strings.g.dart';

/// 配对 PIN 跟着会话走（host 审批框不再读全局单槽）：
/// - 常驻显示 PIN 的框只被**同源**请求取代；不同来源的新请求被拒，框里仍是原 PIN。
/// - server 的收起回调带会话 id，只收起本会话的框。
/// - 同源（同 sourceKey，IPv6 同一 /64 换了地址）重新配对仍能取代常驻框（BUG-708 / 987）。
/// - BUG-4389：回环来源的审批框加一行提醒（原 interconnect_pair_loopback_hint_test）。
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

  Future<FushiSyncServerController> pumpHost(WidgetTester tester) async {
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
    return controller;
  }

  const FushiPairRequest s1 = FushiPairRequest(
    deviceName: 'Phone A',
    remoteAddress: '203.0.113.7',
    pinRequired: true,
    sessionId: 'S1',
    pin: '482913',
    sourceKey: 'ip:203.0.113.7',
  );

  /// 批准 S1 → 框进入常驻 PIN 阶段。
  Future<void> approveS1(
    WidgetTester tester,
    FushiSyncServerController controller,
  ) async {
    final Future<bool> first = controller.debugPromptPairApproval(s1);
    await tester.pump();
    expect(find.text('482913'), findsOneWidget);
    await tester.tap(find.text(t.sync_pair_allow_interconnect_only));
    await tester.pump();
    expect(await first, isTrue);
    expect(find.text(t.sync_pair_pin_waiting), findsOneWidget);
  }

  Future<void> closeDialog(WidgetTester tester) async {
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();
  }

  testWidgets('不同来源的请求不取代常驻 PIN 框、拿不到上屏机会', (WidgetTester tester) async {
    final FushiSyncServerController controller = await pumpHost(tester);
    await approveS1(tester, controller);

    final Future<bool> second = controller.debugPromptPairApproval(
      const FushiPairRequest(
        deviceName: 'Attacker',
        remoteAddress: '198.51.100.9',
        pinRequired: true,
        sessionId: 'S2',
        pin: '771122',
        sourceKey: 'ip:198.51.100.9',
      ),
    );
    await tester.pumpAndSettle();

    expect(await second, isFalse, reason: '不同来源不得顶掉正等对方输入的 PIN 框');
    expect(find.text('482913'), findsOneWidget, reason: '框里仍是 S1 的 PIN');
    expect(find.text('771122'), findsNothing, reason: '别人的 PIN 不得上屏');
    await closeDialog(tester);
  });

  testWidgets('收起回调只收起本会话的框', (WidgetTester tester) async {
    final FushiSyncServerController controller = await pumpHost(tester);
    await approveS1(tester, controller);

    controller.debugPairSessionResolved('S2');
    await tester.pumpAndSettle();
    expect(
      find.text('482913'),
      findsOneWidget,
      reason: '别的会话 confirm 不收起 S1 的框',
    );

    controller.debugPairSessionResolved('S1');
    await tester.pumpAndSettle();
    expect(find.text('482913'), findsNothing, reason: 'S1 自己 confirm 才收起');
  });

  testWidgets('同源（IPv6 同一 /64 换地址）重新配对仍取代常驻框', (WidgetTester tester) async {
    final FushiSyncServerController controller = await pumpHost(tester);
    const String key = 'ip6:2001:db8:1:2::/64';
    final Future<bool> first = controller.debugPromptPairApproval(
      const FushiPairRequest(
        deviceName: 'Phone A',
        remoteAddress: '2001:db8:1:2::10',
        pinRequired: true,
        sessionId: 'S1',
        pin: '482913',
        sourceKey: key,
      ),
    );
    await tester.pump();
    await tester.tap(find.text(t.sync_pair_allow_interconnect_only));
    await tester.pump();
    expect(await first, isTrue);

    final Future<bool> second = controller.debugPromptPairApproval(
      const FushiPairRequest(
        deviceName: 'Phone A',
        remoteAddress: '2001:db8:1:2::99',
        pinRequired: true,
        sessionId: 'S2',
        pin: '771122',
        sourceKey: key,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('771122'), findsOneWidget);
    expect(find.text('482913'), findsNothing);

    // 被取代的 S1 迟到的收起回调不碰新框。
    controller.debugPairSessionResolved('S1');
    await tester.pumpAndSettle();
    expect(find.text('771122'), findsOneWidget);

    await tester.tap(find.text(t.sync_pair_allow_interconnect_only));
    await tester.pump();
    expect(await second, isTrue);
    await closeDialog(tester);
  });

  Future<void> expectLoopbackHint(
    WidgetTester tester,
    String remote, {
    required bool shown,
  }) async {
    final FushiSyncServerController controller = await pumpHost(tester);
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

  testWidgets('回环来源显示提醒（BUG-4389）', (WidgetTester tester) async {
    await expectLoopbackHint(tester, '127.0.0.1', shown: true);
    await expectLoopbackHint(tester, '::1', shown: true);
    await expectLoopbackHint(tester, '127.0.0.1 (proxied)', shown: true);
  });

  testWidgets('局域网与 P2P 隧道来源不显示提醒（BUG-4389）', (WidgetTester tester) async {
    await expectLoopbackHint(tester, '192.168.1.20', shown: false);
    await expectLoopbackHint(tester, kFushiP2pRemoteAddress, shown: false);
  });
}
