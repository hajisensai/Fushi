import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_controller.dart';
import 'package:fushi/src/onboarding/recommended_pack_download_row.dart';
import 'package:fushi/utils.dart';

/// BUG-2097：设置里那一行是「后台下载」唯一不依赖新手引导的可见入口。
void main() {
  late Directory packDir;

  setUp(() {
    packDir = Directory.systemTemp.createTempSync('recommended_pack_row');
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
        body: RecommendedPackDownloadRow(
          controller: controller,
          onImport: onImport,
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
          }) async => throw StateError('本用例不下载'),
      showOutcome: (String message, ToastSeverity severity) {},
    );
  }

  testWidgets('空闲时整行不渲染', (WidgetTester tester) async {
    final RecommendedPackDownloadController controller = newController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(host(controller, () {}));
    expect(find.byType(AdaptiveSettingsRow), findsNothing);
  });

  testWidgets('下载中报进度，取消按钮真的置位令牌', (WidgetTester tester) async {
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

    // 取消入口存在且指向 controller（真下载时它会置位 CancelToken）。
    await tester.tap(find.text(t.dialog_cancel));
    await tester.pump();
  });

  testWidgets('下完待导入时给出导入按钮', (WidgetTester tester) async {
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
}
