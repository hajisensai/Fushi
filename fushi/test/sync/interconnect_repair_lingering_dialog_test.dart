import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/sync/fushi_server_controller.dart';
import 'package:fushi/src/sync/fushi_sync_server.dart';
import 'package:fushi/utils.dart';

/// TODO-1330 / BUG-708：公网 PIN 配对被取消 / 从未 confirm 后，host 那个「已允许、常驻
/// 显示 PIN 等对方输入」的弹窗不该继续占住审批槽，把随后的「重新配对」静默挡成拒绝。
///
/// 行为复现：批准第一次配对 → 弹窗进入常驻 PIN 阶段（未 confirm）→ 再发起第二次配对 →
/// 必须收起旧常驻弹窗并弹出**新审批弹窗（显示新 PIN）**，而不是被 `_pairDialogOpen` 挡下。
/// 修复前 second 立刻返回 false 且界面仍是旧 PIN；修复后 second 能正常走审批。
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

  testWidgets('重新配对不被上一个常驻 PIN 弹窗挡成拒绝（BUG-708）', (WidgetTester tester) async {
    final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
    final FushiSyncServerController controller = buildController(navKey);
    addTearDown(controller.dispose);

    await tester.pumpWidget(TranslationProvider(
      child: MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    ));

    const FushiPairRequest wanReq = FushiPairRequest(
      deviceName: 'Phone A',
      remoteAddress: '203.0.113.7',
      pinRequired: true,
    );

    // 第一次配对：host 弹审批 + 显示 PIN 482913 → 允许 → 弹窗常驻等对方输入。
    final Future<bool> first =
        controller.debugPromptPairApproval(wanReq, seedPin: '482913');
    await tester.pump();
    expect(find.text('482913'), findsOneWidget, reason: '第一次审批弹窗应显示 PIN');
    expect(find.text(t.sync_pair_allow), findsOneWidget);

    await tester.tap(find.text(t.sync_pair_allow));
    await tester.pump();
    expect(await first, isTrue, reason: 'host 允许 → 审批返回 true');
    // 常驻阶段：仍显示同一 PIN + 「等对方输入」文案（client 尚未 confirm）。
    expect(find.text('482913'), findsOneWidget);
    expect(find.text(t.sync_pair_pin_waiting), findsOneWidget);

    // 第二次配对（重新配对）：客户端取消上一次、从未 confirm，host 常驻弹窗仍在。
    final Future<bool> second =
        controller.debugPromptPairApproval(wanReq, seedPin: '771122');
    await tester.pumpAndSettle();

    expect(find.text('771122'), findsOneWidget,
        reason: '重新配对必须弹出新审批弹窗并显示新 PIN（修复前会被静默拒绝）');
    expect(find.text('482913'), findsNothing, reason: '旧常驻弹窗应已收起');

    await tester.tap(find.text(t.sync_pair_allow));
    await tester.pump();
    expect(await second, isTrue, reason: '重新配对的审批应能正常允许，而非被挡成拒绝');

    // 清理：收起第二个常驻弹窗，取消其 lingerTimeout，避免测试结束时挂起 Timer。
    expect(find.text(t.dialog_close), findsOneWidget);
    await tester.tap(find.text(t.dialog_close));
    await tester.pumpAndSettle();
  });
}
