import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/hibiki_server_controller.dart';
import 'package:fushi/src/sync/hibiki_sync_server.dart';
import 'package:fushi/utils.dart';

/// BUG-987：互联首次配对被发起端放弃（超时/断网/取消）后，host 那个仍「审批未决」的
/// 申请框会驻留至 60s autoDeny；期间同一 client「重新刷新」重发的配对全被 `_pairDialogOpen`
/// 挡成 declined、看不到新申请框，用户只见「失败」。
///
/// 修复：`_promptPairApproval` 把「先收起旧框再开新框」的取代条件从「仅 lingering(已允许
/// 常驻 PIN)」扩到「lingering 或**同源(remoteAddress)**」——同一 client 重试即取代滞留的
/// 未决框、重开新框；不同来源仍走防叠弹拒绝（防恶意 peer 顶掉别人正在审批的框）。
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

  Future<void> pumpHost(
      WidgetTester tester, GlobalKey<NavigatorState> navKey) async {
    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    ));
  }

  testWidgets('同源重试取代滞留的未决申请框、重开新框（BUG-987）', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await pumpHost(tester, navKey);

    // 第一次配对（LAN 免 PIN，审批未决）：故意不点「允许」，模拟发起端超时/取消放弃。
    const FushiPairRequest firstReq = FushiPairRequest(
      deviceName: 'Phone A',
      remoteAddress: '192.168.1.50',
      pinRequired: false,
    );
    final Future<bool> first = controller.debugPromptPairApproval(firstReq);
    await tester.pump();
    expect(find.text('Phone A · 192.168.1.50'), findsOneWidget,
        reason: '第一次申请框应弹出、处于审批未决');
    expect(find.text(t.sync_pair_allow), findsOneWidget);

    // 第二次同源重试（同 remoteAddress，展示名不同以便区分是新框）：修复前会命中
    // `if (_pairDialogOpen) return false` 被静默拒绝、界面仍是旧框；修复后应收起旧框、弹新框。
    const FushiPairRequest retryReq = FushiPairRequest(
      deviceName: 'Phone A (retry)',
      remoteAddress: '192.168.1.50',
      pinRequired: false,
    );
    final Future<bool> second = controller.debugPromptPairApproval(retryReq);
    await tester.pumpAndSettle();

    // 旧未决框被取代 → 其审批 future 归为 false（拒绝，client 早已放弃这条）。
    expect(await first, isFalse, reason: '滞留的未决框被同源重试取代 → 判 declined');
    // 新框在，且是新请求的标签（旧标签已消失）。
    expect(find.text('Phone A (retry) · 192.168.1.50'), findsOneWidget,
        reason: '同源重试必须弹出新申请框（修复前被静默拒绝、无新框）');
    expect(find.text('Phone A · 192.168.1.50'), findsNothing,
        reason: '旧未决框应已收起');

    // 新框可正常允许（而非被挡成拒绝）。
    expect(find.text(t.sync_pair_allow), findsOneWidget);
    await tester.tap(find.text(t.sync_pair_allow));
    await tester.pump();
    expect(await second, isTrue, reason: '同源重试的审批应能正常允许');
  });

  testWidgets('不同来源的新请求仍被防叠弹拒绝、旧未决框保留（BUG-987 未回退防护）',
      (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);
    await pumpHost(tester, navKey);

    const FushiPairRequest reqA = FushiPairRequest(
      deviceName: 'Phone A',
      remoteAddress: '192.168.1.50',
      pinRequired: false,
    );
    final Future<bool> first = controller.debugPromptPairApproval(reqA);
    await tester.pump();
    expect(find.text('Phone A · 192.168.1.50'), findsOneWidget);

    // 不同来源(不同 IP)在旧框未决时发起 → 应立即被防叠弹拒绝(false)，旧框不受影响。
    const FushiPairRequest reqB = FushiPairRequest(
      deviceName: 'Attacker B',
      remoteAddress: '192.168.1.99',
      pinRequired: false,
    );
    final Future<bool> second = controller.debugPromptPairApproval(reqB);
    await tester.pump();
    expect(await second, isFalse, reason: '不同来源不得取代别人正在审批的框');
    expect(find.text('Attacker B · 192.168.1.99'), findsNothing,
        reason: '不同来源不应弹出新框');
    expect(find.text('Phone A · 192.168.1.50'), findsOneWidget,
        reason: '原未决框应仍在');

    // 原框仍可正常允许。
    await tester.tap(find.text(t.sync_pair_allow));
    await tester.pump();
    expect(await first, isTrue);
  });
}
