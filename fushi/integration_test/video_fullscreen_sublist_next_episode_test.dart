// 全屏 + 字幕列表打开 → 换下一集（本地合集，自动连播倒计时归零走 `_switchEpisode`）
// 的离屏复现 / 验收。经 `tool/run_windows_itest.ps1 -Visible` 跑（media_kit 需 DWM
// 合成实窗）。每 500ms 记一条时间线（当前页 uid / 就绪 / 原生全屏 / 字幕面板是否在树）
// 并在关键点抓 Flutter 帧，落 `<evidence>/screenshots/`。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart'
    show VideoFushiPage;
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi_core/fushi_core.dart' show MediaKind, VideoBooksCompanion;
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/media_fixtures.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const Key _kSubtitlePanelKey = ValueKey<String>('video-subtitle-jump-panel');

Future<Directory> _fixturesDir() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory dir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('hibiki_fixtures_')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  return dir;
}

/// 播种一集：ffmpeg 造 mp4 + 同名 sidecar .srt（让字幕列表真有行），写 VideoBooks 行。
Future<String> _seedEpisode(
  VideoBookRepository repo,
  Directory dir,
  String title,
  Duration duration,
) async {
  final String videoPath = '${dir.path}${Platform.pathSeparator}$title.mp4';
  final File videoFile = await generateTestVideo(
    outPath: videoPath,
    duration: duration,
  );
  final String srt = cuesToSrt(buildSampleCues(bookKey: title, count: 5));
  await File(
    '${dir.path}${Platform.pathSeparator}$title.srt',
  ).writeAsString(srt);
  final String bookUid = singleVideoBookUid(videoFile.path);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(title),
      videoPath: Value(videoFile.absolute.path),
    ),
  );
  return bookUid;
}

String? _currentPageUid() {
  // 全屏路由压在页面之上时页面是 offstage，仍要算。
  final Iterable<Element> pages = find
      .byType(VideoFushiPage, skipOffstage: false)
      .evaluate();
  if (pages.isEmpty) return null;
  return (pages.last.widget as VideoFushiPage).bookUid;
}

bool _videoMounted() => find.byType(Video).evaluate().isNotEmpty;

bool _subtitlePanelMounted() =>
    find.byKey(_kSubtitlePanelKey, skipOffstage: false).evaluate().isNotEmpty;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('全屏 + 字幕列表 → 下一集：新页就绪、仍全屏、列表仍在', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[fs-sublist] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      final AppModel appModel = await readyAppModel(tester);
      await appModel.setVideoAutoPlayNext(true);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final Directory dir = await _fixturesDir();
      final String ep1 = await _seedEpisode(
        repo,
        dir,
        'fs-ep1',
        const Duration(seconds: 4),
      );
      final String ep2 = await _seedEpisode(
        repo,
        dir,
        'fs-ep2',
        const Duration(seconds: 6),
      );
      final int collectionId = await appModel.database.createMediaCollection(
        'fs-sublist-series',
      );
      await appModel.database.addToCollection(
        collectionId,
        MediaKind.video,
        ep1,
      );
      await appModel.database.addToCollection(
        collectionId,
        MediaKind.video,
        ep2,
      );
      debugPrint(
        '[fs-sublist] seeded ep1=$ep1 ep2=$ep2 collection=$collectionId',
      );

      // 与视频卡 onTap 同一入口开第 1 集（带 playlistCollectionId → 有上下集/连播）。
      final BuildContext ctx = tester.element(find.byType(Scaffold).first);
      if (!ctx.mounted) fail('主页 Scaffold context 已卸载');
      unawaited(
        openLocalVideoBook(
          context: ctx,
          repo: repo,
          bookUid: ep1,
          playlistCollectionId: collectionId,
        ),
      );

      // 等第 1 集就绪（Video 挂载 = _videoReadyToShow）。
      for (int i = 0; i < 60 && !_videoMounted(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(_videoMounted(), isTrue, reason: '第 1 集应在 30s 内就绪');
      expect(_currentPageUid(), ep1);
      await tester.pump(const Duration(seconds: 1));

      // 键盘通道挂在页级 Focus.onKeyEvent，primaryFocus 必须在页内：离屏窗口
      // 非激活，就绪后的焦点认领不一定落下，故显式把焦点请求进 Video 的节点。
      final FocusDriver driver = FocusDriver(tester);
      final bool focused = await driver.requestFocusInside(find.byType(Video));
      await tester.pump(const Duration(milliseconds: 200));
      debugPrint(
        '[fs-sublist] focusInsideVideo=$focused '
        'primaryFocus=${primaryFocus?.debugLabel}',
      );

      // F → 全屏路由 + 原生全屏。
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
      await tester.pump(const Duration(milliseconds: 500));

      // L → push-aside 字幕列表。
      await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
      for (int i = 0; i < 20 && !_subtitlePanelMounted(); i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(_subtitlePanelMounted(), isTrue, reason: 'L 后字幕列表应打开');
      final ObserveShot before = await captureFlutterFrame(
        tester,
        'fs-sublist-01-before-switch',
      );
      debugPrint(
        '[fs-sublist] before=${before.path} nonBlank=${before.nonBlank}',
      );

      // 第 1 集 4s 播完 → 5s 倒计时 → _switchEpisode(ep2)。时间线每 500ms 一条，
      // 最多等 40s；新页就绪 + 全屏后再多观察 2s 抓终态。
      final Stopwatch sw = Stopwatch()..start();
      bool sawLoading = false;
      bool switched = false;
      int settledTicks = 0;
      int nativeFullscreenDrops = 0;
      while (sw.elapsed < const Duration(seconds: 40)) {
        await tester.pump(const Duration(milliseconds: 500));
        final String? uid = _currentPageUid();
        final bool mounted = _videoMounted();
        final bool fs = await WindowCaptionChannel.isFullscreen();
        final bool panel = _subtitlePanelMounted();
        if (!fs) nativeFullscreenDrops++;
        debugPrint(
          '[fs-sublist] t=${sw.elapsed.inMilliseconds}ms '
          'page=${uid == ep2
              ? 'ep2'
              : uid == ep1
              ? 'ep1'
              : uid} '
          'video=$mounted fullscreen=$fs panel=$panel',
        );
        if (uid == ep2 && !mounted && !sawLoading) {
          sawLoading = true;
          final ObserveShot loading = await captureFlutterFrame(
            tester,
            'fs-sublist-02-loading',
          );
          debugPrint('[fs-sublist] loading=${loading.path}');
        }
        if (uid == ep2 && mounted && fs) {
          switched = true;
          if (++settledTicks >= 4) break;
        }
      }
      final ObserveShot after = await captureFlutterFrame(
        tester,
        'fs-sublist-03-after-switch',
      );
      debugPrint(
        '[fs-sublist] after=${after.path} nonBlank=${after.nonBlank} '
        'switched=$switched panel=${_subtitlePanelMounted()} '
        'errors=${errors.length}',
      );

      expect(_currentPageUid(), ep2, reason: '应已换到第 2 集页');
      // BUG-2043：换集全程不得退出原生全屏（旧实现先退再进，窗口尺寸来回抖两轮）。
      expect(
        nativeFullscreenDrops,
        0,
        reason: '换集过程中原生全屏掉了 $nativeFullscreenDrops 个采样点（应恒为全屏）',
      );
      expect(sawLoading || switched, isTrue, reason: '应观察到换集发生');
      expect(_videoMounted(), isTrue, reason: '第 2 集应就绪（不卡在「正在准备」）');
      expect(
        await WindowCaptionChannel.isFullscreen(),
        isTrue,
        reason: '换集后应仍在原生全屏',
      );
      expect(_subtitlePanelMounted(), isTrue, reason: '换集后字幕列表应仍打开');
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
