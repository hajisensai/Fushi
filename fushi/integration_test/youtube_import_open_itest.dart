// 真机集成测试：「粘贴 YouTube URL 导入 → 书架打开」完整路径（BUG-2507 取证用例）。
//
// 走真实导入对话框（`VideoImportDialog` 的流 URL 输入 + 提交）→ 落库（真标题 + 封面）
// → `VideoFushiPage.neutralized` 打开 → Windows 分流到内置网页播放器 `WebVideoFushiPage`
// 并在页面里出现视频标题。依赖真实网络（直连 YouTube），故**默认 skip**，仅在设
// FUSHI_YT_LIVE_ITEST=1 时跑：
//   $env:FUSHI_YT_LIVE_ITEST=1; .\tool\run_windows_itest.ps1 `
//     integration_test\youtube_import_open_itest.dart
// mpv 直连流（移动端路径）的真播放见 youtube_stream_playback_itest.dart。
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/pages/implementations/web_video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _kUrl = 'https://www.youtube.com/watch?v=fKMEsvCtlZA';

/// 仅在进程环境 FUSHI_YT_LIVE_ITEST=1 时跑（依赖真网络，默认 skip 不进 CI）。
bool get _live => Platform.environment['FUSHI_YT_LIVE_ITEST'] == '1';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'YouTube URL import lands a stream book and opens in the web player',
    (WidgetTester tester) async {
      final List<String> errors = <String>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details.exceptionAsString());
        debugPrint('[yt-import] FlutterError: ${details.exceptionAsString()}');
      };
      try {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));
        final AppModel appModel = await readyAppModel(tester);
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        final NavigatorState nav =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        final Future<Object?> dialogResult = nav.push<Object?>(
          MaterialPageRoute<Object?>(
            builder: (_) => Scaffold(body: VideoImportDialog(repo: repo)),
          ),
        );
        await tester.pump(const Duration(seconds: 1));

        // 流 URL 输入框（keyboardType=url 的第一个）→ 填 watch URL → 提交（onSubmitted
        // 与「导入」按钮走同一个 _doImport）。
        final Finder urlField = find.byWidgetPredicate((Widget w) =>
            w is TextField && w.keyboardType == TextInputType.url);
        for (int i = 0; i < 20 && urlField.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(urlField, findsWidgets, reason: 'URL 输入框应在 5s 内进树');
        await tester.enterText(urlField.first, _kUrl);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.testTextInput.receiveAction(TextInputAction.done);

        Object? bookUid;
        bool popped = false;
        unawaited(dialogResult.then((Object? v) {
          bookUid = v;
          popped = true;
        }));
        for (int i = 0; i < 120 && !popped; i++) {
          await tester.pump(const Duration(milliseconds: 500));
        }
        expect(popped, isTrue, reason: '导入对话框应在 60s 内关闭（导入完成）');
        final String uid = bookUid! as String;
        final VideoBookRow? row = await repo.getByBookUid(uid);
        expect(row, isNotNull, reason: '流媒体书应已落库');
        expect(row!.videoPath, _kUrl);
        debugPrint('[yt-import] imported uid=$uid title="${row.title}" '
            'cover=${row.coverPath}');

        // 打开：与书架点卡同一入口；Windows 上分流到网页播放器并显示视频标题。
        unawaited(nav.push<void>(MaterialPageRoute<void>(
          builder: (_) => VideoFushiPage.neutralized(bookUid: uid, repo: repo),
        )));
        bool titled = false;
        for (int i = 0; i < 20 && !titled; i++) {
          await tester.pump(const Duration(seconds: 1));
          titled = find.byType(WebVideoFushiPage).evaluate().isNotEmpty &&
              find.textContaining(row.title).evaluate().isNotEmpty;
        }
        await captureFlutterFrame(tester, 'yt-import-open');
        expect(titled, isTrue, reason: '20s 内应切到 WebVideoFushiPage 并显示视频标题');
        expect(errors, isEmpty);
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
    skip: !_live,
  );
}
