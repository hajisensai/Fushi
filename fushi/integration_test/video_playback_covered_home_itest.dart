// BUG-4895：从首页「继续」点开视频后，被播放页盖住的首页不得在播放期间重载。
//
// 真 app、真 media_kit 播放、真学习时钟：首页 tab 当前时打开一段带字幕的视频，边播
// 边数——
//   - 首页监听的表在播放期间被写了几次（播放断点每秒落一次 `video_books`）；
//   - 被盖住的首页重建了几次（debug 下的 `debugOnRebuildDirtyWidget`）；
//   - 播放窗口里 UI 线程的帧时（[FrameTiming]）与重建最多的 widget 类型。
// 断言：播放期间确实有写入（否则测试空转），而首页一次都没重建；播放页弹走后首页
// 补做一次重载。结果以 `[covered-home]` 前缀打进 command.log，同时落进
// `<测试根>/covered-home-report.txt`。
//
// 跑法（Windows 离屏 runner，debug 模式——绝对帧时只作相对参考）：
//   dart tool/heavy.dart -- pwsh -File tool/run_windows_itest.ps1
//     integration_test/video_playback_covered_home_itest.dart
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show FlutterExceptionHandler;
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_dashboard_page.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/library_fixture.dart';
import 'helpers/media_fixtures.dart';
import 'test_helpers.dart';
import 'support/test_app_launcher.dart';

const String _tag = '[covered-home]';

/// 播放多久（真时钟）。断点每秒落库一次，20 秒约 20 次写入。
const Duration _kPlayWindow = Duration(seconds: 20);

Future<Directory> _fixturesDir() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final String root = Platform.environment['FUSHI_TEST_ROOT'] ?? testRoot;
  final Directory dir = root.isEmpty
      ? await Directory.systemTemp.createTemp('fushi_fixtures_')
      : Directory('$root${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  return dir;
}

/// 1080p、24 fps、60 秒的素材 + 同名 sidecar 字幕（每 2.5 秒一句）。
Future<String> _seedVideo(VideoBookRepository repo, Directory dir) async {
  final String videoPath =
      '${dir.path}${Platform.pathSeparator}covered-home.mp4';
  final FfmpegRunResult r = await resolveFfmpegBackend().run(<String>[
    '-y',
    '-f',
    'lavfi',
    '-i',
    'testsrc2=size=1920x1080:rate=24',
    '-f',
    'lavfi',
    '-i',
    'anullsrc=r=44100:cl=mono',
    '-t',
    '60',
    '-c:v',
    'mpeg4',
    '-q:v',
    '5',
    '-c:a',
    'aac',
    videoPath,
  ], const Duration(seconds: 180));
  if (!r.isSuccess) fail('ffmpeg 生成素材失败: ${r.failureSummary}');
  final List<AudioCue> cues = buildSampleCues(
    bookKey: 'covered-home',
    count: 24,
  );
  await File(
    '${videoPath.substring(0, videoPath.lastIndexOf('.'))}.srt',
  ).writeAsString(cuesToSrt(cues));
  final String bookUid = singleVideoBookUid(videoPath);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: const Value('covered-home'),
      videoPath: Value(File(videoPath).absolute.path),
    ),
  );
  return bookUid;
}

bool _videoMounted() => find.byType(Video).evaluate().isNotEmpty;

Future<void> _wait(Duration d) => Future<void>.delayed(d);

/// 一段窗口里的重建计数（debug 专用钩子）与帧时。
class _Window {
  final Map<String, int> rebuilds = <String, int>{};
  final List<FrameTiming> timings = <FrameTiming>[];
  int dashboardBuilds = 0;

  void _onRebuild(Element e, bool builtOnce) {
    final String name = e.widget.runtimeType.toString();
    rebuilds.update(name, (int n) => n + 1, ifAbsent: () => 1);
    if (e.widget is HomeDashboardPage) dashboardBuilds++;
  }

  void _collect(List<FrameTiming> batch) => timings.addAll(batch);

  void start() {
    debugOnRebuildDirtyWidget = _onRebuild;
    SchedulerBinding.instance.addTimingsCallback(_collect);
  }

  void stop() {
    debugOnRebuildDirtyWidget = null;
    SchedulerBinding.instance.removeTimingsCallback(_collect);
  }

  void report(String label) {
    final List<int> build =
        timings.map((FrameTiming t) => t.buildDuration.inMicroseconds).toList()
          ..sort();
    String pct(double p) => build.isEmpty
        ? '-'
        : (build[((build.length - 1) * p).round()] / 1000).toStringAsFixed(1);
    final int slow = build.where((int us) => us > 16700).length;
    final List<MapEntry<String, int>> top = rebuilds.entries.toList()
      ..sort(
        (MapEntry<String, int> a, MapEntry<String, int> b) =>
            b.value.compareTo(a.value),
      );
    _report(
      '$label frames=${build.length} build(p50/p95/max)='
      '${pct(0.5)}/${pct(0.95)}/${pct(1)}ms slowBuilds=$slow '
      'dashboardBuilds=$dashboardBuilds',
    );
    _report(
      '$label topRebuilds: '
      '${top.take(25).map((MapEntry<String, int> e) => '${e.key}×${e.value}').join(', ')}',
    );
  }
}

/// 结果同时落进 `<测试根>/covered-home-report.txt`：`flutter test -d windows` 的
/// stdout 要等进程退出才整段刷出，测试中途卡住时只有这份文件能看。
void _report(String line) {
  debugPrint('$_tag $line');
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final String root = Platform.environment['FUSHI_TEST_ROOT'] ?? testRoot;
  if (root.isEmpty) return;
  File(
    '$root${Platform.pathSeparator}covered-home-report.txt',
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('首页被播放页盖住期间不重载，播放页弹走后补做', (WidgetTester tester) async {
    // app 的 main 会换掉 FlutterError.onError；断言前必须还原，否则失败的 expect
    // 报不回测试框架，整次运行挂死。
    final FlutterExceptionHandler? testHandler = FlutterError.onError;
    late final int writes;
    late final int positionAdvancedMs;
    late final _Window playing;
    late final _Window after;
    late final bool videoClosed;
    try {
      await launchFushiTestApp();
      expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
      await tester.pump(const Duration(seconds: 2));
      final AppModel appModel = await readyAppModel(tester);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      final String uid = await _seedVideo(repo, await _fixturesDir());

      // 用户的真实路径：首页 tab 当前，从首页点开视频。
      HomePage.debugSelectTab?.call(HomeTab.home);
      await tester.pump(const Duration(seconds: 3));
      expect(homeShellTabNotifier.value, HomeTab.home);
      expect(find.byType(HomeDashboardPage), findsOneWidget);

      int dataChanges = 0;
      final StreamSubscription<void> changesSub = appModel.database
          .watchDashboardDataChanges()
          .listen((_) => dataChanges++);
      addTearDown(changesSub.cancel);

      final BuildContext ctx = tester.element(find.byType(HomeDashboardPage));
      unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
      for (int i = 0; i < 60 && !_videoMounted(); i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(_videoMounted(), isTrue, reason: '视频应在 30s 内就绪');
      // 等开页转场走完、播放起稳：这之后首页才算「被完全盖住」。
      await tester.pump(const Duration(seconds: 3));
      final Video video = tester.widget<Video>(find.byType(Video));

      binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
      final int changesBefore = dataChanges;
      final int positionBefore =
          video.controller.player.state.position.inMilliseconds;
      _report(
        'start playing=${video.controller.player.state.playing} '
        'position=${positionBefore}ms '
        'duration=${video.controller.player.state.duration.inMilliseconds}ms',
      );
      playing = _Window()..start();
      await _wait(_kPlayWindow);
      playing.stop();
      writes = dataChanges - changesBefore;
      positionAdvancedMs =
          video.controller.player.state.position.inMilliseconds -
          positionBefore;
      _report(
        'playing window=${_kPlayWindow.inSeconds}s '
        'dashboardTableWrites=$writes positionAdvanced=${positionAdvancedMs}ms '
        'playing=${video.controller.player.state.playing} '
        'savedPosition=${(await repo.getByBookUid(uid))?.lastPositionMs}ms',
      );
      playing.report('playing');

      // 播放页弹走：首页补做一次重载。
      after = _Window()..start();
      Navigator.of(tester.element(find.byType(Video))).pop();
      for (int i = 0; i < 40 && _videoMounted(); i++) {
        await _wait(const Duration(milliseconds: 250));
      }
      await _wait(const Duration(seconds: 3));
      after.stop();
      after.report('after-pop');
      videoClosed = !_videoMounted();
    } finally {
      binding.framePolicy =
          LiveTestWidgetsFlutterBindingFramePolicy.fadePointers;
      FlutterError.onError = testHandler;
    }

    expect(
      positionAdvancedMs,
      greaterThan(10000),
      reason: '视频应在真播放（否则没有断点写入，本测试没在测东西）',
    );
    expect(
      writes,
      greaterThanOrEqualTo(5),
      reason: '播放期间断点每秒写一次首页监听的 video_books，否则本测试没在测东西',
    );
    expect(playing.dashboardBuilds, 0, reason: '首页被播放页盖住期间不得重载 / 重建（BUG-4895）');
    expect(videoClosed, isTrue, reason: '播放页应已关闭');
    expect(
      after.dashboardBuilds,
      greaterThanOrEqualTo(1),
      reason: '回到首页要补做被推迟的重载',
    );
  });
}
