// 全屏 → 打开剧集列表 → 焦点选第 2 集（`_handleEpisodeListTap` → `_switchEpisode`）
// 的离屏复现 / 验收（用户报「剧集列表跳转集数会退出全屏」）。经 `tool/run_windows_itest.ps1 -Visible` 跑（media_kit 需 DWM
// 合成实窗）。每 500ms 记一条时间线（当前页 uid / 就绪 / 原生全屏 / 字幕面板是否在树）
// 并在关键点抓 Flutter 帧，落 `<evidence>/screenshots/`。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
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

const Key _kEpisode2CardKey = ValueKey<String>('video-episode-card-1');

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

bool _episodeCardMounted() =>
    find.byKey(_kEpisode2CardKey).evaluate().isNotEmpty;

const Key _kEpisode1CardKey = ValueKey<String>('video-episode-card-0');

/// 在当前（全屏）集页上：hover 唤控制条 → 焦点 + Enter 打开剧集列表 → **鼠标**
/// 按下 / 抬起 [cardKey] 卡片。之后每 500ms 采样一次，返回原生全屏掉线的采样数。
Future<int> _switchByMouseClick(
  WidgetTester tester,
  FocusDriver driver,
  TestGesture mouse,
  Finder episodeButton, {
  required Key cardKey,
  required String targetUid,
  required String tag,
}) async {
  final RenderBox videoBox = tester.renderObject<RenderBox>(
    find.byType(Video).last,
  );
  final Offset center = videoBox.localToGlobal(
    videoBox.size.center(Offset.zero),
  );
  for (int i = 0; i < 20 && episodeButton.evaluate().isEmpty; i++) {
    await mouse.moveTo(center + Offset(i.toDouble(), 10));
    await tester.pump(const Duration(milliseconds: 150));
  }
  expect(episodeButton.evaluate(), isNotEmpty, reason: '[$tag] 应有剧集按钮');
  expect(await driver.requestFocusInside(episodeButton.first), isTrue);
  await driver.activate();
  final Finder card = find.byKey(cardKey);
  for (int i = 0; i < 20 && card.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  expect(card.evaluate(), isNotEmpty, reason: '[$tag] 剧集列表应有目标卡片');
  // 等横轨 slide-in 动画走完再取几何。
  await tester.pump(const Duration(milliseconds: 400));
  final Offset cardCenter = tester.getCenter(card);
  await mouse.moveTo(cardCenter);
  await tester.pump(const Duration(milliseconds: 100));
  await mouse.down(cardCenter);
  await tester.pump(const Duration(milliseconds: 80));
  await mouse.up();
  debugPrint('[fs-eplist] [$tag] clicked card at $cardCenter');

  final Stopwatch sw = Stopwatch()..start();
  int drops = 0;
  int settled = 0;
  while (sw.elapsed < const Duration(seconds: 30)) {
    await tester.pump(const Duration(milliseconds: 500));
    final String? uid = _currentPageUid();
    final bool mounted = _videoMounted();
    final bool fs = await WindowCaptionChannel.isFullscreen();
    if (!fs) drops++;
    debugPrint(
      '[fs-eplist] [$tag] t=${sw.elapsed.inMilliseconds}ms '
      'page=${uid == targetUid ? 'target' : uid} video=$mounted fullscreen=$fs',
    );
    if (uid == targetUid && mounted && fs && ++settled >= 6) break;
  }
  await captureFlutterFrame(tester, 'fs-eplist-03-$tag-after-switch');
  return drops;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('全屏 → 剧集列表选第 2 集：换集全程不退原生全屏、新页仍全屏', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint('[fs-eplist] FlutterError: ${details.exceptionAsString()}');
    };

    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      final AppModel appModel = await readyAppModel(tester);
      // 关掉连播：本用例只走「列表选集」这一条换集入口。
      await appModel.setVideoAutoPlayNext(false);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final Directory dir = await _fixturesDir();
      final String ep1 = await _seedEpisode(
        repo,
        dir,
        'fsl-ep1',
        const Duration(seconds: 30),
      );
      final String ep2 = await _seedEpisode(
        repo,
        dir,
        'fsl-ep2',
        const Duration(seconds: 30),
      );
      final int collectionId = await appModel.database.createMediaCollection(
        'fs-eplist-series',
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
        '[fs-eplist] seeded ep1=$ep1 ep2=$ep2 collection=$collectionId',
      );

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

      for (int i = 0; i < 60 && !_videoMounted(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(_videoMounted(), isTrue, reason: '第 1 集应在 30s 内就绪');
      expect(_currentPageUid(), ep1);
      await tester.pump(const Duration(seconds: 1));

      final FocusDriver driver = FocusDriver(tester);
      await driver.requestFocusInside(find.byType(Video));
      await tester.pump(const Duration(milliseconds: 200));

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

      // 控制条剧集按钮（默认在右上角）：焦点到按钮 → Enter。
      final Finder episodeButton = find.byIcon(Icons.playlist_play);
      // 控制条自动隐藏时顶栏按钮不在树里：用真实鼠标 hover 唤起（与
      // video_keyboard_controls_keepalive_itest 同范式，只 hover 不点击）。
      final RenderBox videoBox = tester.renderObject<RenderBox>(
        find.byType(Video).last,
      );
      final Offset center = videoBox.localToGlobal(
        videoBox.size.center(Offset.zero),
      );
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 7301,
      );
      await mouse.addPointer(location: center - const Offset(0, 40));
      addTearDown(() => mouse.removePointer());
      for (int i = 0; i < 20 && episodeButton.evaluate().isEmpty; i++) {
        await mouse.moveTo(center + Offset(i.toDouble(), 0));
        await tester.pump(const Duration(milliseconds: 150));
      }
      expect(episodeButton.evaluate(), isNotEmpty, reason: '全屏控制条应有剧集按钮');
      final bool buttonFocused = await driver.requestFocusInside(
        episodeButton.first,
      );
      debugPrint(
        '[fs-eplist] episodeButtonFocused=$buttonFocused '
        'primary=${primaryFocus?.debugLabel}',
      );
      expect(buttonFocused, isTrue, reason: '剧集按钮应能获得焦点');
      await driver.activate();
      for (int i = 0; i < 20 && !_episodeCardMounted(); i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      expect(_episodeCardMounted(), isTrue, reason: '剧集列表应打开并有第 2 集卡片');
      expect(
        await WindowCaptionChannel.isFullscreen(),
        isTrue,
        reason: '打开剧集列表不应退全屏',
      );
      await captureFlutterFrame(tester, 'fs-eplist-01-list-open');

      // 焦点到第 2 集卡片 → Enter（InkWell canRequestFocus → ActivateIntent → onTap）。
      final bool cardFocused = await driver.requestFocusInside(
        find.byKey(_kEpisode2CardKey),
      );
      debugPrint(
        '[fs-eplist] cardFocused=$cardFocused '
        'primary=${primaryFocus?.debugLabel}',
      );
      expect(cardFocused, isTrue, reason: '第 2 集卡片应能获得焦点');
      await driver.activate();

      final Stopwatch sw = Stopwatch()..start();
      int nativeFullscreenDrops = 0;
      int settledTicks = 0;
      while (sw.elapsed < const Duration(seconds: 30)) {
        await tester.pump(const Duration(milliseconds: 500));
        final String? uid = _currentPageUid();
        final bool mounted = _videoMounted();
        final bool fs = await WindowCaptionChannel.isFullscreen();
        if (!fs) nativeFullscreenDrops++;
        final String page = uid == ep2
            ? 'ep2'
            : uid == ep1
            ? 'ep1'
            : '$uid';
        debugPrint(
          '[fs-eplist] t=${sw.elapsed.inMilliseconds}ms '
          'page=$page video=$mounted fullscreen=$fs',
        );
        if (uid == ep2 && mounted && fs) {
          if (++settledTicks >= 6) break;
        }
      }
      final ObserveShot after = await captureFlutterFrame(
        tester,
        'fs-eplist-02-after-switch',
      );
      debugPrint(
        '[fs-eplist] after=${after.path} drops=$nativeFullscreenDrops '
        'errors=${errors.length}',
      );

      expect(_currentPageUid(), ep2, reason: '应已换到第 2 集页');
      expect(
        nativeFullscreenDrops,
        0,
        reason: '换集过程中原生全屏掉了 $nativeFullscreenDrops 个采样点（应恒为全屏）',
      );
      expect(_videoMounted(), isTrue, reason: '第 2 集应就绪');
      expect(
        await WindowCaptionChannel.isFullscreen(),
        isTrue,
        reason: '换集后应仍在原生全屏',
      );

      // 第二段：用户真实输入是**鼠标点卡片**（焦点 + Enter 走不到指针路径）。
      // 在第 2 集页上重开剧集列表，鼠标按下 / 抬起第 1 集卡片切回去。这里刻意
      // 用合成鼠标而非焦点驱动：被测的正是指针路径。
      final int drops1 = await _switchByMouseClick(
        tester,
        driver,
        mouse,
        episodeButton,
        cardKey: _kEpisode1CardKey,
        targetUid: ep1,
        tag: 'mouse',
      );
      expect(_currentPageUid(), ep1, reason: '鼠标点卡片后应已换回第 1 集页');
      expect(drops1, 0, reason: '鼠标点卡片换集时原生全屏掉了 $drops1 个采样点（应恒为全屏）');
      expect(
        await WindowCaptionChannel.isFullscreen(),
        isTrue,
        reason: '鼠标点卡片换集后应仍在原生全屏',
      );
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
