import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/sync/manual_sync_ui.dart';
import 'package:fushi/src/sync/sync_auto_trigger.dart';

import '../helpers/test_platform_services.dart';

/// [runManualSyncWithFeedback] 的 busy 分支行为。
///
/// 这条分支是加「下拉 = 手动同步」时新引入的：设置页原来的实现遇到 `syncInProgress`
/// 直接 `return` 且什么都不说，而下拉刷新需要在同样的情况下**不打断用户**，同时仍要
/// 如实返回 busy 让调用方知道这次没跑同步。两种口径靠 `announceBusy` 区分，所以要钉住
/// 「busy 时绝不触发第二次同步」和「announceBusy 决定是否出声」这两点。
///
/// 注：只测 busy 分支 —— 它在碰 `appModel.database` 之前就返回，因此不需要一个初始化
/// 过的 AppModel。真正跑同步的路径依赖完整 DB + 后端，属于集成测试范围。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppModel appModel;

  setUp(() {
    LocaleSettings.setLocale(AppLocale.en);
    appModel = AppModel(testPlatformServices());
    syncInProgress.value = false;
  });

  tearDown(() => syncInProgress.value = false);

  Future<ManualSyncOutcome> callWith(
    WidgetTester tester, {
    required bool announceBusy,
  }) async {
    late ManualSyncOutcome outcome;
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () async {
                  outcome = await runManualSyncWithFeedback(
                    context: context,
                    appModel: appModel,
                    announceBusy: announceBusy,
                  );
                },
                child: const Text('go'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    return outcome;
  }

  testWidgets('同步已在飞时返回 busy 且不再触发第二次同步', (WidgetTester tester) async {
    syncInProgress.value = true;
    final ManualSyncOutcome outcome =
        await callWith(tester, announceBusy: false);

    expect(outcome, ManualSyncOutcome.busy);
    // 第二次触发必须是彻底的 no-op：连 SnackBar 都不该有（下拉刷新的口径）。
    expect(find.byType(SnackBar), findsNothing);
    // 没有把全局标志改坏 —— 在飞的那次同步还得靠它复位自己的进度条。
    expect(syncInProgress.value, isTrue);
  });

  testWidgets('announceBusy 打开时给出可见提示（设置页口径）', (WidgetTester tester) async {
    syncInProgress.value = true;
    final ManualSyncOutcome outcome =
        await callWith(tester, announceBusy: true);

    expect(outcome, ManualSyncOutcome.busy);
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
