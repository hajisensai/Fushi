import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_mini_bar.dart';
import 'package:fushi/utils.dart';

/// BUG-2165：推荐包 9.5 GB 的下载在 BUG-2097 之后确实活过了新手引导，但可见入口
/// 只剩「设置 → 系统 → 通用第 5 项」——而新用户走完引导正好落在首页，屏幕上一个
/// 像素都不说明它还在下。这条迷你条挂在首页 shell 三套布局共用的底部，是那个
/// 「能看进度的地方」。
void main() {
  late Directory packDir;

  setUp(() {
    packDir = Directory.systemTemp.createTempSync('recommended_pack_bar');
  });

  tearDown(() {
    if (packDir.existsSync()) packDir.deleteSync(recursive: true);
  });

  Widget host(
    RecommendedPackDownloadController controller,
    VoidCallback onImport,
  ) {
    return MaterialApp(
      home: Scaffold(
        body: Column(
          children: <Widget>[
            const Expanded(child: SizedBox.expand()),
            RecommendedPackDownloadMiniBarView(
              controller: controller,
              onImport: onImport,
            ),
          ],
        ),
      ),
    );
  }

  RecommendedPackDownloadController newController() {
    return RecommendedPackDownloadController(
      packDirectory: () => packDir,
      runner:
          ({
            required Directory packDir,
            required ValueNotifier<double> progress,
            required ValueNotifier<int> receivedBytes,
            required CancelToken cancelToken,
          }) async => throw StateError('本用例不该真去下载'),
      showOutcome: (String message, ToastSeverity severity) {},
    );
  }

  testWidgets('空闲时不渲染，也不占布局', (WidgetTester tester) async {
    final RecommendedPackDownloadController controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(controller, () {}));

    expect(find.byType(Material), findsWidgets);
    expect(find.text(t.onboarding_pack_status_downloading), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('下载中：进度条 + 已下字节 + 取消', (WidgetTester tester) async {
    final RecommendedPackDownloadController controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(controller, () {}));
    controller.stage.value = RecommendedPackDownloadStage.downloading;
    controller.progress.value = 0.34;
    controller.receivedBytes.value = 3 * 1024 * 1024 * 1024;
    await tester.pump();

    expect(find.text(t.onboarding_pack_status_downloading), findsOneWidget);
    expect(find.text('3.0 GB (34%)'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.text(t.dialog_cancel), findsOneWidget);
  });

  testWidgets('已暂停：报已下字节并给出「继续下载」', (WidgetTester tester) async {
    final RecommendedPackDownloadController controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(controller, () {}));
    controller.stage.value = RecommendedPackDownloadStage.paused;
    controller.receivedBytes.value = 3 * 1024 * 1024 * 1024;
    await tester.pump();

    expect(find.text(t.onboarding_pack_status_paused), findsOneWidget);
    expect(find.text('3.0 GB'), findsOneWidget);
    expect(find.text(t.onboarding_pack_download_resume), findsOneWidget);
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: '没在下就不该画一条不动的进度条',
    );
  });

  testWidgets('下完待导入：导入按钮回调宿主', (WidgetTester tester) async {
    final RecommendedPackDownloadController controller = newController();
    addTearDown(controller.dispose);
    int imports = 0;

    await tester.pumpWidget(host(controller, () => imports += 1));
    controller.stage.value = RecommendedPackDownloadStage.downloaded;
    await tester.pump();

    expect(find.text(t.onboarding_pack_status_ready), findsOneWidget);
    await tester.tap(find.text(t.onboarding_pack_import_now));
    await tester.pump();
    expect(imports, 1);
  });

  testWidgets('收起只收这条，不动下载本身', (WidgetTester tester) async {
    final RecommendedPackDownloadController controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(controller, () {}));
    controller.stage.value = RecommendedPackDownloadStage.downloading;
    controller.receivedBytes.value = 1024;
    await tester.pump();
    expect(find.text(t.onboarding_pack_status_downloading), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.text(t.onboarding_pack_status_downloading), findsNothing);
    expect(
      controller.stage.value,
      RecommendedPackDownloadStage.downloading,
      reason: '「不想看」不等于「不想下」——收起绝不能掐断 9.5 GB 的下载',
    );
    expect(controller.isActive, isTrue, reason: '设置 → 系统那一行照旧显示，收起只作用于首页这条');
  });

  testWidgets('下完之后重新出现，即使之前被收起过', (WidgetTester tester) async {
    final RecommendedPackDownloadController controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(controller, () {}));
    controller.stage.value = RecommendedPackDownloadStage.downloading;
    await tester.pump();
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(find.text(t.onboarding_pack_status_downloading), findsNothing);

    // 那次收起针对的是当时那个状态；「可以导入了」是新消息。
    controller.stage.value = RecommendedPackDownloadStage.downloaded;
    controller.miniBarDismissed.value = false;
    await tester.pump();

    expect(find.text(t.onboarding_pack_status_ready), findsOneWidget);
  });
}
