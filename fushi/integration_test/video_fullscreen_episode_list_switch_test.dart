// 全屏 → 打开剧集列表 → 焦点选第 2 集（`_handleEpisodeListTap` → `_switchEpisode`）
// 的离屏复现 / 验收（用户报「剧集列表跳转集数会退出全屏」）。经 `tool/run_windows_itest.ps1 -Visible` 跑（media_kit 需 DWM
// 合成实窗）。每 500ms 记一条时间线（当前页 uid / 就绪 / 原生全屏 / 字幕面板是否在树）
// 并在关键点抓 Flutter 帧，落 `<evidence>/screenshots/`。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show HitTestEntry, HitTestResult, PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
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
import 'package:fushi/src/utils/fushi_icons.dart';
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

const Key _kEpisode1CardKey = ValueKey<String>('video-episode-card-0');

/// [finder] 匹配到的控件里，**命中测试点得中**的那一个的中心点；一个都点不中返回 null。
///
/// 全屏路由下面的视频页同样在树里（同 key 卡片 / 同图标按钮各有两份），收起的剧集
/// 横轨也常驻挂载（[FadingChromeGate] 只淡出 + 屏蔽指针），所以「找得到」不等于
/// 「用户看得见、点得到」。逐个做命中测试才挑得出用户真正会点到的那一个。
Offset? _hittableCenter(Finder finder, int viewId, String label) {
  for (final Element e in finder.evaluate()) {
    final RenderObject? ro = e.renderObject;
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) continue;
    final Offset c = ro.localToGlobal(ro.size.center(Offset.zero));
    final HitTestResult hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, c, viewId);
    final bool hits = hit.path.any(
      (HitTestEntry entry) => identical(entry.target, ro),
    );
    debugPrint('[fs-eplist] $label candidate center=$c hittable=$hits');
    if (hits) return c;
  }
  return null;
}

/// 合成鼠标在 [at] 处按下 / 抬起一次（先移过去，让 hover 态与真实点击一致）。
Future<void> _mouseClick(
  WidgetTester tester,
  TestGesture mouse,
  Offset at,
) async {
  await mouse.moveTo(at);
  await tester.pump(const Duration(milliseconds: 100));
  await mouse.down(at);
  await tester.pump(const Duration(milliseconds: 80));
  await mouse.up();
}

/// 在当前（全屏）集页上：hover 唤控制条 → **鼠标**点控制条剧集按钮打开横轨 →
/// **鼠标**点 [cardKey] 卡片。之后每 500ms 采样一次，返回原生全屏掉线的采样数。
Future<int> _switchByMouseClick(
  WidgetTester tester,
  TestGesture mouse, {
  required Key cardKey,
  required String targetUid,
  required String tag,
}) async {
  final int viewId = tester.view.viewId;
  final Finder episodeButton = find.byIcon(
    FushiIcons.playlist,
    skipOffstage: false,
  );
  final RenderBox videoBox = tester.renderObject<RenderBox>(
    find.byType(Video).last,
  );
  final Offset center = videoBox.localToGlobal(
    videoBox.size.center(Offset.zero),
  );
  Offset? buttonAt;
  for (int i = 0; i < 20 && buttonAt == null; i++) {
    await mouse.moveTo(center + Offset(i.toDouble(), 10));
    await tester.pump(const Duration(milliseconds: 150));
    buttonAt = _hittableCenter(episodeButton, viewId, '[$tag] button');
  }
  expect(buttonAt, isNotNull, reason: '[$tag] 全屏控制条应有点得中的剧集按钮');
  await _mouseClick(tester, mouse, buttonAt!);

  final Finder card = find.byKey(cardKey, skipOffstage: false);
  Offset? cardAt;
  for (int i = 0; i < 20 && cardAt == null; i++) {
    await tester.pump(const Duration(milliseconds: 150));
    cardAt = _hittableCenter(card, viewId, '[$tag] card');
  }
  await captureFlutterFrame(tester, 'fs-eplist-02-$tag-list-open');
  expect(cardAt, isNotNull, reason: '[$tag] 剧集横轨应打开且目标卡片点得中');
  expect(
    await WindowCaptionChannel.isFullscreen(),
    isTrue,
    reason: '[$tag] 打开剧集横轨不应退全屏',
  );
  // 等横轨 slide-in 走完再按，位置才是终态。
  await tester.pump(const Duration(milliseconds: 300));
  cardAt = _hittableCenter(card, viewId, '[$tag] card(settled)') ?? cardAt;
  await _mouseClick(tester, mouse, cardAt!);
  debugPrint('[fs-eplist] [$tag] clicked card at $cardAt');

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

      // 用户真实输入是**鼠标点剧集卡片**：焦点驱动在全屏剧集横轨里落不到卡片上
      // （实测 requestFocus 后 primary 仍是 videoKeyboard，Enter 不换集），且被测的
      // 嫌疑正好在指针路径上，所以这里刻意用合成鼠标（与
      // video_keyboard_controls_keepalive_itest 同范式）。来回各换一次集：
      // ep1 → ep2 覆盖「初始全屏路由」的接管，ep2 → ep1 覆盖「接管来的全屏」再接管。
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

      final int drops2 = await _switchByMouseClick(
        tester,
        mouse,
        cardKey: _kEpisode2CardKey,
        targetUid: ep2,
        tag: 'to-ep2',
      );
      expect(_currentPageUid(), ep2, reason: '鼠标点卡片后应已换到第 2 集页');
      expect(drops2, 0, reason: '换到第 2 集时原生全屏掉了 $drops2 个采样点（应恒为全屏）');
      expect(_videoMounted(), isTrue, reason: '第 2 集应就绪');
      expect(
        await WindowCaptionChannel.isFullscreen(),
        isTrue,
        reason: '换到第 2 集后应仍在原生全屏',
      );

      final int drops1 = await _switchByMouseClick(
        tester,
        mouse,
        cardKey: _kEpisode1CardKey,
        targetUid: ep1,
        tag: 'to-ep1',
      );
      expect(_currentPageUid(), ep1, reason: '鼠标点卡片后应已换回第 1 集页');
      expect(drops1, 0, reason: '换回第 1 集时原生全屏掉了 $drops1 个采样点（应恒为全屏）');
      expect(
        await WindowCaptionChannel.isFullscreen(),
        isTrue,
        reason: '换回第 1 集后应仍在原生全屏',
      );
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
