// BUG-5200：主线程忙时视频还能不能逐帧上屏（应用内反馈 q5f7uiRd__「平移镜头一卡一卡地
// 掉帧，同片源 PotPlayer 不卡」）。
//
// Windows 上 Dart UI 线程与平台主线程默认合并。原版引擎里视频每出一帧，纹理 mark 要先排进
// 主线程、再由主线程等 vsync 调一帧，主线程忙过一个视频帧间隔，这帧就被下一帧覆盖、永远
// 不上屏。补丁引擎（ci/patches/flutter-engine/3.47.6/engine-texture-frame-raster-thread.patch）
// 让 mark 直接在 raster 线程上重画，不再经主线程。
//
// 真 app、真 media_kit 画面、真原生计数（`VideoOutputManager.FrameStats`：mpv 出了几帧、
// raster 线程取走几帧、几帧没取走就被覆盖）。1080p 24 fps 素材边播边量两个 10 秒窗口：
//   idle — 什么也不做；
//   busy — Dart 主线程每 150 ms 忙等 60 ms（比 24 fps 的 41.7 ms 帧间隔长）。
// 结果以 `[present-probe]` 前缀打进 command.log，同时追加写
// `<FUSHI_TEST_ROOT>/present-probe-report.txt`。
//
// 跑法（Windows 离屏 runner）：
//   dart tool/heavy.dart --max-minutes=25 -- pwsh -File tool/run_windows_itest.ps1
//     integration_test/video_present_main_thread_busy_itest.dart
// 用原版 / 旧补丁引擎（没有 raster 线程 mark）跑，busy 窗口的 lost 会远超阈值——这正是
// 本条修复前的行为。
import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;

import 'helpers/library_fixture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[present-probe]';
const int _kVideoSeconds = 60;
const int _kWindowMs = 10000;
const int _kBusyEveryMs = 150;
const int _kBusyForMs = 60;

final String _testRoot =
    Platform.environment['FUSHI_TEST_ROOT'] ??
    const String.fromEnvironment('FUSHI_TEST_ROOT');

void _log(String line) {
  debugPrint('$_tag $line');
  if (_testRoot.isEmpty) return;
  File(
    '$_testRoot${Platform.pathSeparator}present-probe-report.txt',
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

Future<String> _seedVideo(VideoBookRepository repo) async {
  final Directory dir = Directory(
    _testRoot.isEmpty
        ? '${Directory.systemTemp.path}${Platform.pathSeparator}present-probe'
        : '$_testRoot${Platform.pathSeparator}fixtures',
  );
  await dir.create(recursive: true);
  final String videoPath =
      '${dir.path}${Platform.pathSeparator}present-probe.mp4';
  if (!File(videoPath).existsSync()) {
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
      '$_kVideoSeconds',
      '-c:v',
      'mpeg4',
      '-q:v',
      '5',
      '-c:a',
      'aac',
      videoPath,
    ], const Duration(seconds: 240));
    if (!r.isSuccess) fail('ffmpeg 生成素材失败: ${r.failureSummary}');
  }
  final String bookUid = singleVideoBookUid(videoPath);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: const Value('present-probe'),
      videoPath: Value(File(videoPath).absolute.path),
    ),
  );
  return bookUid;
}

bool _videoMounted() => find.byType(Video).evaluate().isNotEmpty;

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

Future<Map<String, int>?> _stats() async {
  final Video video = find.byType(Video).evaluate().first.widget as Video;
  return video.controller.notifier.value?.frameStats();
}

/// 一个窗口的增量；[busy] 时窗口内 Dart 主线程按节奏忙等。
Future<Map<String, int>> _measure(String label, {required bool busy}) async {
  final Map<String, int>? before = await _stats();
  if (before == null) fail('原生出帧计数不可用（非 Windows 硬件输出？）');
  Timer? hog;
  int stalls = 0;
  if (busy) {
    hog = Timer.periodic(const Duration(milliseconds: _kBusyEveryMs), (_) {
      final Stopwatch sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < _kBusyForMs) {}
      stalls++;
    });
  }
  await _wait(_kWindowMs);
  hog?.cancel();
  final Map<String, int>? after = await _stats();
  if (after == null) fail('原生出帧计数不可用');
  int d(String k) => (after[k] ?? 0) - (before[k] ?? 0);
  final Map<String, int> delta = <String, int>{
    'published': d('published'),
    'shown': d('shown'),
    'lost': d('lost'),
    'latencySumUs': d('latencySumUs'),
    'latencyMaxUs': after['latencyMaxUs'] ?? 0,
  };
  final int shown = delta['shown']!;
  final String avg = shown == 0
      ? '-'
      : (delta['latencySumUs']! / shown / 1000).toStringAsFixed(1);
  _log(
    '$label published=${delta['published']} shown=$shown '
    'lost=${delta['lost']} latency_avg=${avg}ms '
    'latency_max_total=${(delta['latencyMaxUs']! / 1000).toStringAsFixed(1)}ms '
    'stalls=$stalls',
  );
  return delta;
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('主线程忙时视频帧仍逐帧上屏', (WidgetTester tester) async {
    final FlutterExceptionHandler? frameworkOnError = FlutterError.onError;
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    final VideoBookRepository repo = VideoBookRepository(appModel.database);
    final String uid = await _seedVideo(repo);

    final BuildContext ctx = tester.element(find.byType(Scaffold).first);
    unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
    for (int i = 0; i < 60 && !_videoMounted(); i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    final bool videoReady = _videoMounted();
    VideoFushiTestHooks hooks() =>
        tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
            as VideoFushiTestHooks;
    if (videoReady) {
      for (int i = 0; i < 40 && hooks().debugPositionMs == null; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
    }

    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    Map<String, int> idle = const <String, int>{};
    Map<String, int> busy = const <String, int>{};
    if (videoReady) {
      _log(
        'mode=${kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug'} refresh=${tester.view.display.refreshRate}Hz '
        'busy=${_kBusyForMs}ms/${_kBusyEveryMs}ms',
      );
      await hooks().debugPlay();
      await hooks().debugSeekMs(0);
      await _wait(3000);
      idle = await _measure('idle', busy: false);
      busy = await _measure('busy', busy: true);
    }

    FlutterError.onError = frameworkOnError;
    expect(videoReady, isTrue, reason: '视频应在 30s 内就绪');
    // 24 fps × 10 s ≈ 240 帧；少于 150 说明根本没在正常播放，结论无效。
    expect(idle['published'], greaterThan(150), reason: 'idle 窗口应在播放');
    expect(busy['published'], greaterThan(150), reason: 'busy 窗口应在播放');
    // 主线程每 150 ms 堵 60 ms：修复前每次堵塞都会吞掉约 1 帧（10 s 里约 60 帧）。
    // 修复后视频帧不经主线程，只容许 raster 线程偶发的个别丢帧。
    final int allowed = (busy['published']! * 0.02).ceil();
    expect(
      busy['lost'],
      lessThanOrEqualTo(allowed),
      reason: '主线程忙时视频帧不应被覆盖丢掉（lost ≤ 2%）',
    );
  });
}
