// 视频弹幕层帧时探针（BUG-4852，应用内反馈 j2plixDqML「开弹幕后掉帧更明显」）。
//
// 真 app、真 media_kit 画面、真 sidecar 弹幕：生成一段 1080p 素材 + 同名
// `.danmaku.xml`（前 30 秒约每秒 3.5 条、后 30 秒约每秒 9 条滚动弹幕，文本各不相同），
// 边播边按「弹幕关 → 开（低密度）→ 开（高密度）→ 关」各量 10 秒稳态的引擎
// [FrameTiming]（build / raster 分位、超 1 帧预算的帧数、vsync 间隔超 1.5 帧的次数），
// 每个窗口中段数一次屏上弹幕条数。最后暂停在固定位置抓一张真像素帧，供修前修后
// 对比观感（阴影、位置、清晰度）。
//
// 结果以 `[danmaku-perf]` 前缀打进 command.log，同时追加写到
// `<FUSHI_TEST_ROOT>/danmaku-perf-report.txt`（`flutter test -d windows` 的 stdout
// 要等进程退出才刷出，卡住时看这个文件）。
//
// 跑法（Windows 离屏 runner，debug 模式——绝对耗时偏大，只看开 / 关的相对变化）：
//   dart tool/heavy.dart --max-minutes=25 -- pwsh -File tool/run_windows_itest.ps1
//     integration_test/video_danmaku_raster_perf_itest.dart
//
// 不切全屏：离屏 runner 的窗口一旦进全屏会盖住使用者的整块显示器。弹幕层的开销与
// 屏上条数、DPR 成正比，与是否全屏无关；窗口尺寸 / DPR / 刷新率打在报告第一行。
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_danmaku_overlay.dart';
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
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[danmaku-perf]';
const int _kVideoSeconds = 90;
const int _kWindowMs = 10000;

/// 低 / 高两档密度的分界（毫秒）与各自的发弹速率（条 / 秒）。默认 8 秒滚完一屏，
/// 屏上条数 ≈ 速率 × 8（被行占满时更少，实际条数以探针数出来的为准）。
const int _kDenseFromMs = 30000;
const double _kSparseRate = 3.5;
const double _kDenseRate = 9.0;

final String _testRoot =
    Platform.environment['FUSHI_TEST_ROOT'] ??
    const String.fromEnvironment('FUSHI_TEST_ROOT');

final StringBuffer _report = StringBuffer();

void _log(String line) {
  debugPrint('$_tag $line');
  _report.writeln(line);
  if (_testRoot.isEmpty) return;
  File(
    '$_testRoot${Platform.pathSeparator}danmaku-perf-report.txt',
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

const List<String> _kPhrases = <String>[
  '好可爱',
  '下头女没救了',
  '男主人真好',
  '这么能吃到时候你付钱哈',
  '什么护食哈基米',
  '0帧起手',
  '你一直都在失态啊喂！',
  '拳头硬了',
  '温水：不是姐们，我没吃啊',
  '这我掏钱买的啊，还不让我吃',
  '踏饭虾头女。。。',
  '好啊，付了钱东西还一口没吃到哈哈哈',
  '哈哈哈哈',
  '可怜男主一秒',
  '你要我付钱我转头就走',
  '感觉男主要哭了哈哈哈哈',
  '温水：我是一口没吃啊',
  '好逗啊，旁观喜剧',
  '不也挺好吗',
  '一口都不给啊 CS啊 让我看着你吃完',
  '护食了有点',
  '等一下这份薯条',
  '失去高光',
  'ftft',
];

const List<int> _kColors = <int>[
  0xFFFFFF,
  0xFFFFFF,
  0xFFFFFF,
  0xFFFFFF,
  0xFFFFFF,
  0xFE0302,
  0x00CD00,
  0x4266BE,
  0xFFAA02,
];

/// Bilibili XML：`<d p="秒,模式,字号,颜色,...">文本</d>`，模式 1 = 滚动。文本带序号，
/// 每条都不同（真弹幕几乎不重句，文本缓存帮不上忙）。
String _danmakuXml() {
  final StringBuffer xml = StringBuffer(
    '<?xml version="1.0" encoding="UTF-8"?>\n<i>\n',
  );
  int n = 0;
  double t = 0;
  while (t < _kVideoSeconds) {
    final double rate = t * 1000 < _kDenseFromMs ? _kSparseRate : _kDenseRate;
    final String text =
        '${_kPhrases[n % _kPhrases.length]}${n % 7 == 0 ? '' : n}';
    final int color = _kColors[n % _kColors.length];
    xml.writeln(
      '<d p="${t.toStringAsFixed(3)},1,25,$color,0,0,0,$n">$text</d>',
    );
    n++;
    // 不等间隔（真弹幕成团出现）：围绕平均间隔在 0.4×～1.6× 之间摆动。
    t += (1 / rate) * (0.4 + 1.2 * ((n * 37) % 11) / 10);
  }
  xml.writeln('</i>');
  return xml.toString();
}

Future<String> _seedVideo(VideoBookRepository repo) async {
  final Directory dir = Directory(
    _testRoot.isEmpty
        ? '${Directory.systemTemp.path}${Platform.pathSeparator}danmaku-perf'
        : '$_testRoot${Platform.pathSeparator}fixtures',
  );
  await dir.create(recursive: true);
  final String videoPath =
      '${dir.path}${Platform.pathSeparator}danmaku-perf.mp4';
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
  await File(
    '${dir.path}${Platform.pathSeparator}danmaku-perf.danmaku.xml',
  ).writeAsString(_danmakuXml());
  final String bookUid = singleVideoBookUid(videoPath);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: const Value('danmaku-perf'),
      videoPath: Value(File(videoPath).absolute.path),
    ),
  );
  return bookUid;
}

bool _videoMounted() => find.byType(Video).evaluate().isNotEmpty;

/// 屏上弹幕条数：弹幕层下的 [Text] 个数。
int _onScreenDanmaku() => find
    .descendant(
      of: find.byType(VideoDanmakuOverlay),
      matching: find.byType(Text),
    )
    .evaluate()
    .length;

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

String _q(List<int> sortedMicros, double q) {
  if (sortedMicros.isEmpty) return '-';
  final int i = ((sortedMicros.length - 1) * q).round();
  return (sortedMicros[i] / 1000).toStringAsFixed(1);
}

/// 量一个 10 秒窗口。窗口中段数一次屏上条数。
Future<void> _measure(String label, double budgetMs) async {
  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  await _wait(_kWindowMs ~/ 2);
  final int midCount = _onScreenDanmaku();
  await _wait(_kWindowMs - _kWindowMs ~/ 2);
  SchedulerBinding.instance.removeTimingsCallback(collect);

  final int budgetUs = (budgetMs * 1000).round();
  final List<int> build =
      timings.map((FrameTiming t) => t.buildDuration.inMicroseconds).toList()
        ..sort();
  final List<int> raster =
      timings.map((FrameTiming t) => t.rasterDuration.inMicroseconds).toList()
        ..sort();
  int overBuild = 0;
  int overRaster = 0;
  int missed = 0;
  int? prev;
  for (final FrameTiming t in timings) {
    if (t.buildDuration.inMicroseconds > budgetUs) overBuild++;
    if (t.rasterDuration.inMicroseconds > budgetUs) overRaster++;
    final int vs = t.timestampInMicroseconds(FramePhase.vsyncStart);
    if (prev != null && vs - prev > budgetUs * 1.5) missed++;
    prev = vs;
  }
  _log(
    '$label onScreen=$midCount frames=${timings.length} '
    'build p50/p95/max=${_q(build, .5)}/${_q(build, .95)}/${_q(build, 1)}ms '
    'raster p50/p95/max=${_q(raster, .5)}/${_q(raster, .95)}/${_q(raster, 1)}ms '
    'overBudget build=$overBuild raster=$overRaster vsyncGap>1.5f=$missed',
  );
}

/// 抓根图层真像素。不走 [captureFlutterFrame]：它先 `pumpAndSettle`，而弹幕层开着时
/// 每帧都有动画，settle 永远等不到。
Future<String> _captureFrame(String name, double pixelRatio) async {
  final RenderView view = RendererBinding.instance.renderViews.first;
  final OffsetLayer layer = view.debugLayer! as OffsetLayer;
  final ui.Image image = await layer.toImage(
    view.paintBounds,
    pixelRatio: pixelRatio,
  );
  try {
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    final String path = '${observeScreenshotDir().path}/$name.png';
    await File(path).writeAsBytes(png!.buffer.asUint8List(), flush: true);
    return path;
  } finally {
    image.dispose();
  }
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('弹幕层开 / 关帧时', (WidgetTester tester) async {
    // app 的 main 会换掉 FlutterError.onError；断言前还原，失败才报得回框架。
    final FlutterExceptionHandler? frameworkOnError = FlutterError.onError;
    await launchFushiTestApp(
      seedPrefs: const <String, String>{
        'video_danmaku_enabled': 'b:true',
        'video_danmaku_online_enabled': 'b:false',
      },
    );
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
    final double dpr = tester.view.devicePixelRatio;
    final double refresh = tester.view.display.refreshRate;
    final double budgetMs = 1000 / refresh;
    _report.clear();
    _log(
      'env size=${tester.view.physicalSize.width.round()}x'
      '${tester.view.physicalSize.height.round()} dpr=$dpr '
      'refresh=${refresh.toStringAsFixed(1)}Hz budget=${budgetMs.toStringAsFixed(2)}ms '
      'mode=${kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug'} '
      'videoReady=$videoReady',
    );

    String? shot;
    int onAfterEnable = 0;
    if (videoReady) {
      await hooks().debugPlay();
      await appModel.setVideoDanmakuEnabled(false);
      await hooks().debugSeekMs(0);
      await _wait(2000);
      await _measure('off#1 pos0-12s', budgetMs);

      await appModel.setVideoDanmakuEnabled(true);
      await hooks().debugSeekMs(1000);
      await _wait(9000); // 第一条弹幕滚完一屏，屏上条数进入稳态
      onAfterEnable = _onScreenDanmaku();
      await _measure('on-sparse pos10-20s', budgetMs);

      await hooks().debugSeekMs(_kDenseFromMs + 1000);
      await _wait(9000);
      await _measure('on-dense pos40-50s', budgetMs);

      await appModel.setVideoDanmakuEnabled(false);
      await _wait(1000);
      await _measure('off#2 pos51-61s', budgetMs);

      // 观感对照帧：暂停在固定位置，修前修后同一画面。
      await appModel.setVideoDanmakuEnabled(true);
      await hooks().debugPause();
      await hooks().debugSeekMs(45000);
      await _wait(2500);
      _log('shot onScreen=${_onScreenDanmaku()}');
      shot = await _captureFrame('danmaku-perf-paused-45s', dpr);
      _log('shot path=$shot');
    }

    FlutterError.onError = frameworkOnError;
    expect(videoReady, isTrue, reason: '视频应在 30s 内就绪');
    expect(onAfterEnable, greaterThan(0), reason: '开弹幕后屏上应有弹幕');
    expect(shot, isNotNull);
  });
}
