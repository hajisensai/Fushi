// BUG-5081：Windows 本地视频一进全屏整窗只剩底色（控件也没有）。
//
// 根因：窗口侧与全屏路由都经 `_videoWithSubtitlePanel` 包画面，而它给画面挂了竖屏
// 版式用的 GlobalKey；全屏路由压上时窗口页仍挂载，同一 GlobalKey 同时出现在两个宿主，
// 两边的 `Video` 都被摘掉。本用例走真 app + runner 原生全屏，断言全屏后台上恰有一个
// 有尺寸的 `Video`，退出全屏后窗口侧 `Video` 仍在。
//
// 跑法：`tool/run_windows_itest.ps1 integration_test/video_fullscreen_blank_test.dart -Visible`
// （media_kit 需要 DWM 合成的实窗）。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

/// 台上（非 offstage）且已布局出非零尺寸的 `Video` 个数。
int _visibleVideoCount() {
  int count = 0;
  for (final Element e in find.byType(Video).evaluate()) {
    final RenderObject? ro = e.renderObject;
    if (ro is RenderBox && ro.attached && ro.hasSize && !ro.size.isEmpty) {
      count++;
    }
  }
  return count;
}

Future<String> _seedVideo(VideoBookRepository repo) async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory dir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('fushi_fixtures_')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  final String videoPath = '${dir.path}${Platform.pathSeparator}fsblank.mp4';
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=1280x720:rate=24',
    '-t',
    '20',
    '-c:v',
    'mpeg4',
    videoPath,
  ], const Duration(seconds: 120));
  if (!r.isSuccess) fail('ffmpeg: ${r.failureSummary}');
  final String uid = singleVideoBookUid(File(videoPath).absolute.path);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(uid),
      title: const Value('fsblank'),
      videoPath: Value(File(videoPath).absolute.path),
    ),
  );
  return uid;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('视频进全屏后画面仍在（BUG-5081）', (WidgetTester tester) async {
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final String uid = await _seedVideo(repo);

      final BuildContext ctx = tester.element(find.byType(Scaffold).first);
      unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
      for (int i = 0; i < 60 && _visibleVideoCount() == 0; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(_visibleVideoCount(), 1, reason: '窗口态应有一个可见 Video');
      await tester.pump(const Duration(seconds: 1));

      final FocusDriver driver = FocusDriver(tester);
      await driver.requestFocusInside(find.byType(Video));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (await WindowCaptionChannel.isFullscreen()) break;
      }
      expect(
        await WindowCaptionChannel.isFullscreen(),
        isTrue,
        reason: 'F 后应进入 runner 原生全屏',
      );
      await tester.pump(const Duration(seconds: 2));
      await captureFlutterFrame(tester, 'fs-blank-01-fullscreen');
      debugPrint(
        '[fs-blank] fullscreen visible videos=${_visibleVideoCount()}',
      );
      expect(
        _visibleVideoCount(),
        1,
        reason: '全屏路由里应恰有一个可见 Video（0 = 画面被 GlobalKey 抢走，整屏底色）',
      );
      expect(tester.takeException(), isNull, reason: '进全屏不应抛框架异常');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      for (int i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (!await WindowCaptionChannel.isFullscreen()) break;
      }
      await tester.pump(const Duration(seconds: 1));
      await captureFlutterFrame(tester, 'fs-blank-02-exited');
      expect(await WindowCaptionChannel.isFullscreen(), isFalse);
      expect(_visibleVideoCount(), 1, reason: '退出全屏后窗口侧 Video 应回来');
      expect(tester.takeException(), isNull, reason: '退全屏不应抛框架异常');
    } finally {
      if (await WindowCaptionChannel.isFullscreen()) {
        await WindowCaptionChannel.setFullscreen(false);
      }
    }
  });
}
