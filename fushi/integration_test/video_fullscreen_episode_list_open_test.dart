// 全屏 → 鼠标点控制条「剧集列表」按钮 → 横轨应打开、主线程不卡死（反馈 X5OX9t9lEG：
// 「全屏模式下看完了想要换下一集，点剧集列表就卡住了」，窗口标题变成「未响应」）。
//
// 用户路径：12 集合集、播到第 5 集片尾、原生全屏、鼠标点顶栏剧集按钮。本用例按同一
// 形状播种 12 集，经 `tool/run_windows_itest.ps1 -Visible` 跑（media_kit 需要 DWM 合成的
// 实窗）。每一次 pump 都计墙钟：主线程卡死时 pump 不会返回，单次超过阈值即判失败。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart'
    show HitTestEntry, HitTestResult, PointerDeviceKind;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/media/video/video_episode_panel.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
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

const int _kEpisodeCount = 12;
const int _kStartEpisode = 4; // 第 5 集（下标 4），与反馈截图一致。

Future<Directory> _fixturesDir() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory dir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('hibiki_fixtures_')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  return dir;
}

Future<String> _seedEpisode(
  VideoBookRepository repo,
  Directory dir,
  String title,
) async {
  final String sep = Platform.pathSeparator;
  final String videoPath = '${dir.path}$sep$title.mp4';
  final String coverPath = '${dir.path}$sep$title.jpg';
  final FfmpegBackend backend = resolveFfmpegBackend();
  // 贴近反馈现场：720p 画面 + 每集一张 1080p 封面（剧集卡走真实图片解码）。
  final FfmpegRunResult video = await backend.run(<String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc=size=1280x720:rate=24',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=r=44100:cl=stereo',
    '-t',
    '30',
    '-c:v',
    'mpeg4',
    '-q:v',
    '5',
    '-c:a',
    'aac',
    videoPath,
  ], const Duration(seconds: 120));
  if (!video.isSuccess) fail('ffmpeg video: ${video.failureSummary}');
  final FfmpegRunResult cover = await backend.run(<String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=1920x1080',
    '-frames:v',
    '1',
    coverPath,
  ], const Duration(seconds: 60));
  if (!cover.isSuccess) fail('ffmpeg cover: ${cover.failureSummary}');
  final String srt = cuesToSrt(buildSampleCues(bookKey: title, count: 5));
  await File('${dir.path}$sep$title.srt').writeAsString(srt);
  final String bookUid = singleVideoBookUid(File(videoPath).absolute.path);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(title),
      videoPath: Value(File(videoPath).absolute.path),
      coverPath: Value(File(coverPath).absolute.path),
    ),
  );
  return bookUid;
}

bool _videoMounted() => find.byType(Video).evaluate().isNotEmpty;

/// 主线程卡死时 [WidgetTester.pump] 不会返回；单次 pump 超过本阈值即判卡顿。
const Duration _kPumpStallLimit = Duration(seconds: 3);

/// 计时 pump：返回本次墙钟耗时并打点。
Future<Duration> _timedPump(
  WidgetTester tester,
  Duration step,
  String tag,
) async {
  final Stopwatch sw = Stopwatch()..start();
  await tester.pump(step);
  sw.stop();
  if (sw.elapsed > step + const Duration(milliseconds: 400)) {
    debugPrint('[fs-eplist-open] $tag slow pump ${sw.elapsedMilliseconds}ms');
  }
  return sw.elapsed;
}

/// 命中测试点得中的那一个的中心点；一个都点不中返回 null。
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
    debugPrint('[fs-eplist-open] $label candidate center=$c hittable=$hits');
    if (hits) return c;
  }
  return null;
}

/// 诊断：两份剧集面板（全屏路由 + 其下的窗口侧）各自的 visible、几何与卡片命中路径。
void _dumpPanels(WidgetTester tester, String tag) {
  final int viewId = tester.view.viewId;
  int i = 0;
  for (final Element e
      in find.byType(VideoEpisodePanel, skipOffstage: false).evaluate()) {
    final VideoEpisodePanel w = e.widget as VideoEpisodePanel;
    final RenderObject? ro = e.renderObject;
    String geo = 'no-box';
    if (ro is RenderBox && ro.hasSize && ro.attached) {
      geo = '${ro.localToGlobal(Offset.zero)} ${ro.size}';
    }
    bool offstage = false;
    e.visitAncestorElements((Element a) {
      if (a.widget is Offstage && (a.widget as Offstage).offstage) {
        offstage = true;
        return false;
      }
      return true;
    });
    debugPrint(
      '[fs-eplist-open] $tag panel#$i visible=${w.visible} '
      'episodes=${w.episodes.length} current=${w.currentIndex} '
      'offstage=$offstage geo=$geo',
    );
    i++;
  }
  final Finder card = find.byKey(
    const ValueKey<String>('video-episode-card-${_kStartEpisode + 1}'),
    skipOffstage: false,
  );
  for (final Element e in card.evaluate()) {
    final RenderObject? ro = e.renderObject;
    if (ro is! RenderBox || !ro.hasSize) continue;
    final Offset c = ro.localToGlobal(ro.size.center(Offset.zero));
    final HitTestResult hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, c, viewId);
    final String top = hit.path
        .take(6)
        .map((HitTestEntry h) => h.target.runtimeType.toString())
        .join(' > ');
    debugPrint('[fs-eplist-open] $tag card@$c top: $top');
  }
  debugPrint(
    '[fs-eplist-open] $tag primaryFocus=${FocusManager.instance.primaryFocus}',
  );
}

/// 窗口态对照：hover 唤控制条 → 鼠标点剧集按钮，返回横轨是否翻成可见；随后再点一次关掉。
Future<bool> _windowedControlClick(WidgetTester tester) async {
  final int viewId = tester.view.viewId;
  final RenderBox videoBox = tester.renderObject<RenderBox>(
    find.byType(Video).last,
  );
  final Offset center = videoBox.localToGlobal(
    videoBox.size.center(Offset.zero),
  );
  final TestGesture mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
    pointer: 7303,
  );
  await mouse.addPointer(location: center - const Offset(0, 40));
  final Finder episodeButton = find.byWidgetPredicate(
    (Widget w) =>
        w is Icon &&
        (w.icon == FushiIcons.playlist || w.icon == Icons.playlist_play),
  );
  Offset? at;
  for (int i = 0; i < 20 && at == null; i++) {
    await mouse.moveTo(center + Offset(i.toDouble(), 10));
    await tester.pump(const Duration(milliseconds: 150));
    at = _hittableCenter(episodeButton, viewId, 'windowed-button');
  }
  if (at == null) {
    await mouse.removePointer();
    return false;
  }
  await mouse.moveTo(at);
  await tester.pump(const Duration(milliseconds: 120));
  await mouse.down(at);
  await tester.pump(const Duration(milliseconds: 80));
  await mouse.up();
  bool opened = false;
  for (int f = 0; f < 10 && !opened; f++) {
    await tester.pump(const Duration(milliseconds: 16));
    opened = find
        .byType(VideoEpisodePanel, skipOffstage: false)
        .evaluate()
        .any((Element e) => (e.widget as VideoEpisodePanel).visible);
  }
  debugPrint('[fs-eplist-open] windowed click opened=$opened');
  // 关掉：Esc 走 _closeEpisodeList。
  await tester.sendKeyEvent(LogicalKeyboardKey.escape);
  await tester.pump(const Duration(milliseconds: 500));
  await mouse.removePointer();
  return opened;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  debugPrint = debugPrintSynchronously;

  testWidgets('全屏 → 鼠标点剧集列表按钮：横轨打开、主线程不卡死', (WidgetTester tester) async {
    final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
    final FlutterExceptionHandler? oldHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      errors.add(details);
      debugPrint(
        '[fs-eplist-open] FlutterError: ${details.exceptionAsString()}',
      );
    };

    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));

      final AppModel appModel = await readyAppModel(tester);
      await appModel.setVideoAutoPlayNext(false);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final Directory dir = await _fixturesDir();
      final List<String> uids = <String>[];
      for (int i = 1; i <= _kEpisodeCount; i++) {
        uids.add(
          await _seedEpisode(
            repo,
            dir,
            'fso-ep${i.toString().padLeft(2, '0')}',
          ),
        );
      }
      final int collectionId = await appModel.database.createMediaCollection(
        'fs-eplist-open-series',
      );
      for (final String uid in uids) {
        await appModel.database.addToCollection(
          collectionId,
          MediaKind.video,
          uid,
        );
      }

      final BuildContext ctx = tester.element(find.byType(Scaffold).first);
      if (!ctx.mounted) fail('主页 Scaffold context 已卸载');
      unawaited(
        openLocalVideoBook(
          context: ctx,
          repo: repo,
          bookUid: uids[_kStartEpisode],
          playlistCollectionId: collectionId,
        ),
      );
      for (int i = 0; i < 60 && !_videoMounted(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(_videoMounted(), isTrue, reason: '第 5 集应在 30s 内就绪');
      await tester.pump(const Duration(seconds: 1));

      final FocusDriver driver = FocusDriver(tester);
      await driver.requestFocusInside(find.byType(Video));
      await tester.pump(const Duration(milliseconds: 200));

      final bool windowedOpened = await _windowedControlClick(tester);
      await driver.requestFocusInside(find.byType(Video));
      await tester.pump(const Duration(milliseconds: 300));

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
      await tester.pump(const Duration(milliseconds: 800));
      final Size view = tester.view.physicalSize / tester.view.devicePixelRatio;
      debugPrint('[fs-eplist-open] logical view=$view');

      // 用户的真实输入是鼠标点顶栏剧集按钮（焦点驱动够不到这枚 hover 才出现的按钮，
      // 被测嫌疑也正好在指针 → 打开横轨这条路径上）。
      final int viewId = tester.view.viewId;
      final RenderBox videoBox = tester.renderObject<RenderBox>(
        find.byType(Video).last,
      );
      final Offset center = videoBox.localToGlobal(
        videoBox.size.center(Offset.zero),
      );
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 7302,
      );
      await mouse.addPointer(location: center - const Offset(0, 40));
      addTearDown(() => mouse.removePointer());

      final Finder episodeButton = find.byWidgetPredicate(
        (Widget w) =>
            w is Icon &&
            (w.icon == FushiIcons.playlist || w.icon == Icons.playlist_play),
        skipOffstage: false,
      );
      Offset? buttonAt;
      for (int i = 0; i < 20 && buttonAt == null; i++) {
        await mouse.moveTo(center + Offset(i.toDouble(), 10));
        await tester.pump(const Duration(milliseconds: 150));
        buttonAt = _hittableCenter(episodeButton, viewId, 'button');
      }
      if (buttonAt == null) {
        for (final Element e
            in find.byType(Icon, skipOffstage: false).evaluate()) {
          final Icon icon = e.widget as Icon;
          debugPrint(
            '[fs-eplist-open] icon 0x${icon.icon?.codePoint.toRadixString(16)} '
            '${icon.icon?.fontFamily}',
          );
        }
      }
      expect(buttonAt, isNotNull, reason: '全屏顶栏应有点得中的剧集列表按钮');

      _dumpPanels(tester, 'before-click');
      String vis() => find
          .byType(VideoEpisodePanel, skipOffstage: false)
          .evaluate()
          .map((Element e) => (e.widget as VideoEpisodePanel).visible)
          .join(',');
      await mouse.moveTo(buttonAt!);
      await tester.pump(const Duration(milliseconds: 120));
      buttonAt =
          _hittableCenter(episodeButton, viewId, 'button(re)') ?? buttonAt;
      await mouse.down(buttonAt);
      for (int f = 0; f < 5; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        debugPrint('[fs-eplist-open] down+${f}f visible=${vis()}');
      }
      debugPrint('[fs-eplist-open] click episode button at $buttonAt');
      final Stopwatch clickSw = Stopwatch()..start();
      await mouse.up();
      for (int f = 0; f < 10; f++) {
        await tester.pump(const Duration(milliseconds: 16));
        debugPrint('[fs-eplist-open] up+${f}f visible=${vis()}');
      }
      _dumpPanels(tester, 'after-up');
      await tester.pump(const Duration(milliseconds: 16));
      _dumpPanels(tester, 'after-1-frame');

      // 点击后逐帧计时 3 秒：任何一次 pump 卡过阈值都是主线程停泵。
      Duration worst = Duration.zero;
      while (clickSw.elapsed < const Duration(seconds: 3)) {
        final Duration took = await _timedPump(
          tester,
          const Duration(milliseconds: 16),
          'after-click t=${clickSw.elapsedMilliseconds}ms',
        );
        if (took > worst) worst = took;
      }
      debugPrint(
        '[fs-eplist-open] worst pump after click=${worst.inMilliseconds}ms',
      );
      _dumpPanels(tester, 'after-3s');
      await captureFlutterFrame(tester, 'fs-eplist-open-02-list-open');
      expect(
        worst,
        lessThan(_kPumpStallLimit),
        reason: '点剧集按钮后主线程停泵 ${worst.inMilliseconds}ms',
      );

      final Finder card = find.byKey(
        const ValueKey<String>('video-episode-card-${_kStartEpisode + 1}'),
        skipOffstage: false,
      );
      expect(
        _hittableCenter(card, viewId, 'next-card'),
        isNotNull,
        reason: '剧集横轨应已打开、下一集卡片点得中',
      );
      expect(
        await WindowCaptionChannel.isFullscreen(),
        isTrue,
        reason: '打开剧集横轨不应退全屏',
      );
      expect(windowedOpened, isTrue, reason: '窗口态点剧集按钮应打开横轨（对照）');
      assertStrictErrors(errors);
    } finally {
      FlutterError.onError = oldHandler;
    }
  });
}
