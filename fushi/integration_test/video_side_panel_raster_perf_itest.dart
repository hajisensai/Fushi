// 视频侧栏帧时探针（用户 2026-11-27「视频点出这个侧边栏掉帧」）。
//
// 真 app、真 media_kit 画面：Apple 设计系统下，边播 1080p@24 素材边量各 8 秒稳态的
// 引擎 [FrameTiming]（build / raster 分位、超 1 帧预算的帧数、vsync 间隔超 1.5 帧的
// 次数）。顺序：面板关（premium）→ 开字幕设置面板，按玻璃画质档 premium → standard
// → minimal → premium 复测交替量——同一次运行里对照「厚材质面板走哪条玻璃渲染
// 路径」的成本，抵掉跨进程的噪声。最后暂停在固定位置抓一张面板开着的真像素帧，
// 供修前修后对比观感。
//
// 结果以 `[panel-perf]` 前缀打进 command.log，同时追加写到
// `<FUSHI_TEST_ROOT>/panel-perf-report.txt`。
//
// 跑法（Windows 离屏 runner，debug 模式——绝对耗时偏大，只看各档的相对变化）：
//   dart tool/heavy.dart --max-minutes=25 -- pwsh -File tool/run_windows_itest.ps1
//     integration_test/video_side_panel_raster_perf_itest.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_quick_settings_sheet.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart' show HomePage;
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;
import 'package:vm_service/vm_service.dart' as vm;

import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';

const String _tag = '[panel-perf]';
const int _kVideoSeconds = 90;
const int _kWindowMs = 8000;

final String _testRoot =
    Platform.environment['FUSHI_TEST_ROOT'] ??
    const String.fromEnvironment('FUSHI_TEST_ROOT');

void _log(String line) {
  debugPrint('$_tag $line');
  if (_testRoot.isEmpty) return;
  File(
    '$_testRoot${Platform.pathSeparator}panel-perf-report.txt',
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

Future<String> _seedVideo(VideoBookRepository repo) async {
  final Directory dir = Directory(
    _testRoot.isEmpty
        ? '${Directory.systemTemp.path}${Platform.pathSeparator}panel-perf'
        : '$_testRoot${Platform.pathSeparator}fixtures',
  );
  await dir.create(recursive: true);
  final String videoPath = '${dir.path}${Platform.pathSeparator}panel-perf.mp4';
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
      title: const Value('panel-perf'),
      videoPath: Value(File(videoPath).absolute.path),
    ),
  );
  return bookUid;
}

/// 等首页（[HomePage]）挂载，与设计系统无关。
Future<bool> _waitForHomePage(WidgetTester tester) async {
  for (int i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (find.byType(HomePage).evaluate().isNotEmpty) {
      await tester.pump(const Duration(seconds: 1));
      return true;
    }
  }
  return false;
}

bool _videoMounted() => find.byType(Video).evaluate().isNotEmpty;

bool _panelMounted() =>
    find.byType(VideoQuickSettingsSheet).evaluate().isNotEmpty;

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

String _q(List<int> sortedMicros, double q) {
  if (sortedMicros.isEmpty) return '-';
  final int i = ((sortedMicros.length - 1) * q).round();
  return (sortedMicros[i] / 1000).toStringAsFixed(1);
}

Future<void> _measure(String label, double budgetMs) async {
  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  await _wait(_kWindowMs);
  SchedulerBinding.instance.removeTimingsCallback(collect);

  final int budgetUs = (budgetMs * 1000).round();
  final List<int> build =
      timings.map((FrameTiming t) => t.buildDuration.inMicroseconds).toList()
        ..sort();
  final List<int> raster =
      timings.map((FrameTiming t) => t.rasterDuration.inMicroseconds).toList()
        ..sort();
  int overRaster = 0;
  int missed = 0;
  int? prev;
  for (final FrameTiming t in timings) {
    if (t.rasterDuration.inMicroseconds > budgetUs) overRaster++;
    final int vs = t.timestampInMicroseconds(FramePhase.vsyncStart);
    if (prev != null && vs - prev > budgetUs * 1.5) missed++;
    prev = vs;
  }
  _log(
    '$label panel=${_panelMounted()} frames=${timings.length} '
    'build p50/p95=${_q(build, .5)}/${_q(build, .95)}ms '
    'raster p50/p95/max=${_q(raster, .5)}/${_q(raster, .95)}/${_q(raster, 1)}ms '
    'overBudget raster=$overRaster vsyncGap>1.5f=$missed',
  );
}

/// 量「点出侧栏」那一下：开面板起 1.5 秒内的每一帧（挂载帧 + 进场动画），关掉
/// 再等 1 秒，重复 [cycles] 次。逐次打出最重的三帧（build / raster）与超预算帧数。
Future<void> _measureOpen(
  String label,
  double budgetMs,
  VideoFushiTestHooks Function() hooks, {
  int cycles = 3,
}) async {
  final int budgetUs = (budgetMs * 1000).round();
  for (int c = 0; c < cycles; c++) {
    final List<FrameTiming> timings = <FrameTiming>[];
    void collect(List<FrameTiming> batch) => timings.addAll(batch);
    SchedulerBinding.instance.addTimingsCallback(collect);
    final Stopwatch sw = Stopwatch()..start();
    hooks().debugOpenSubtitleSettings();
    await _wait(1500);
    SchedulerBinding.instance.removeTimingsCallback(collect);
    final bool mounted = _panelMounted();
    hooks().debugHideSidePanel();
    await _wait(1000);

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
    final List<FrameTiming> worst = List<FrameTiming>.of(timings)
      ..sort(
        (FrameTiming a, FrameTiming b) =>
            b.totalSpan.inMicroseconds.compareTo(a.totalSpan.inMicroseconds),
      );
    String ms(Duration d) => (d.inMicroseconds / 1000).toStringAsFixed(1);
    final String top = worst
        .take(3)
        .map(
          (FrameTiming t) =>
              'b${ms(t.buildDuration)}/r${ms(t.rasterDuration)}'
              '/span${ms(t.totalSpan)}',
        )
        .join(' ');
    if (c == 0) {
      // 每轮首开逐帧打出：看卡顿是 build（UI 线程）还是 raster，落在第几帧。
      final int t0 = timings.isEmpty
          ? 0
          : timings.first.timestampInMicroseconds(FramePhase.vsyncStart);
      _log(
        '$label open#0 frames: '
        '${timings.map((FrameTiming t) => '+${((t.timestampInMicroseconds(FramePhase.vsyncStart) - t0) / 1000).round()}'
            ':b${ms(t.buildDuration)}/r${ms(t.rasterDuration)}').join(' ')}',
      );
    }
    _log(
      '$label open#$c mounted=$mounted frames=${timings.length} '
      'elapsed=${sw.elapsedMilliseconds}ms worst3=[$top] '
      'overBudget build=$overBuild raster=$overRaster vsyncGap>1.5f=$missed',
    );
  }
}

/// 录一次打开的 timeline（只给用户代码里的 widget 打 build 事件，窗口 1.5 秒，
/// 避开约 3.2 万事件的环形缓冲被冲掉）：打出慢帧的阶段拆分（vsync→build 开始 /
/// build / build 结束→raster 开始 / raster）与 UI、raster 线程上最长的同步事件，
/// 原始 JSON 落到测试根，供逐事件细看。
Future<void> _traceOpen(
  String label,
  IntegrationTestWidgetsFlutterBinding binding,
  VideoFushiTestHooks Function() hooks,
) async {
  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  debugProfileBuildsEnabledUserWidgets = true;
  vm.Timeline timeline;
  try {
    timeline = await binding.traceTimeline(() async {
      hooks().debugOpenSubtitleSettings();
      await _wait(1500);
    }, streams: const <String>['Dart', 'GC', 'Embedder']);
  } finally {
    debugProfileBuildsEnabledUserWidgets = false;
  }
  await _wait(800);
  SchedulerBinding.instance.removeTimingsCallback(collect);
  hooks().debugHideSidePanel();
  await _wait(1000);

  String ms(int us) => (us / 1000).toStringAsFixed(1);
  for (final FrameTiming t in timings) {
    if (t.totalSpan.inMicroseconds < 20000) continue;
    final int vs = t.timestampInMicroseconds(FramePhase.vsyncStart);
    final int bs = t.timestampInMicroseconds(FramePhase.buildStart);
    final int bf = t.timestampInMicroseconds(FramePhase.buildFinish);
    final int rs = t.timestampInMicroseconds(FramePhase.rasterStart);
    final int rf = t.timestampInMicroseconds(FramePhase.rasterFinish);
    _log(
      '$label slowFrame span=${ms(rf - vs)} vsync->build=${ms(bs - vs)} '
      'build=${ms(bf - bs)} build->raster=${ms(rs - bf)} raster=${ms(rf - rs)}',
    );
  }

  final List<({String name, String thread, double ms, int depth})> spans =
      <({String name, String thread, double ms, int depth})>[];
  final Map<String, String> threadNames = <String, String>{};
  final Map<String, List<Map<String, dynamic>>> stacks =
      <String, List<Map<String, dynamic>>>{};
  for (final vm.TimelineEvent ev
      in timeline.traceEvents ?? <vm.TimelineEvent>[]) {
    final Map<String, dynamic> e = ev.json ?? <String, dynamic>{};
    final String tid = '${e['tid']}';
    final String ph = '${e['ph']}';
    if (ph == 'M' && e['name'] == 'thread_name') {
      final Object? args = e['args'];
      if (args is Map) threadNames[tid] = '${args['name']}';
      continue;
    }
    if (ph == 'B') {
      (stacks[tid] ??= <Map<String, dynamic>>[]).add(e);
    } else if (ph == 'E') {
      final List<Map<String, dynamic>>? s = stacks[tid];
      if (s == null || s.isEmpty) continue;
      final Map<String, dynamic> b = s.removeLast();
      final double d = ((e['ts'] as int) - (b['ts'] as int)) / 1000;
      if (d >= 3) {
        spans.add((name: '${b['name']}', thread: tid, ms: d, depth: s.length));
      }
    } else if (ph == 'X') {
      final double d = ((e['dur'] as int?) ?? 0) / 1000;
      if (d >= 3) {
        spans.add((name: '${e['name']}', thread: tid, ms: d, depth: -1));
      }
    }
  }
  spans.sort((a, b) => b.ms.compareTo(a.ms));
  for (final ({String name, String thread, double ms, int depth}) s
      in spans.take(80)) {
    _log(
      '$label   ev ${s.ms.toStringAsFixed(1)}ms d${s.depth} '
      '[${threadNames[s.thread] ?? s.thread}] ${s.name}',
    );
  }
  if (_testRoot.isNotEmpty) {
    File(
      '$_testRoot${Platform.pathSeparator}${label.replaceAll(' ', '_')}.json',
    ).writeAsStringSync(jsonEncode(timeline.toJson()));
  }
}

/// 打开过程中「谁把面板标脏了」：[debugOnRebuildDirtyWidget] 在每个被重建的
/// element 上回调，回调时仍 [Element.dirty] 的才是被 markNeedsBuild 的根（父级
/// 连带重建的子树不是）。窗口结束后取字幕面板的祖先链，打出每帧里落在这条链上
/// 的脏根——正是它们让整块面板重建。类型名在回调当场记下（窗口结束时元素可能已
/// 卸载，再读 widget 会抛）。
///
/// 同时开 [debugPrintScheduleBuildForStacks]、临时接管 [debugPrint]，截下
/// 「页面 State / media_kit 视图参数」被 markNeedsBuild 时的调用栈（只留 fushi 帧）。
///
/// 返回挂载帧之后面板祖先链上出现的「整页 / 整个控件层」脏根（[VideoFushiPage] 的
/// State 或 media_kit 的 `VideoViewParameters`）——BUG-5590 修好后应为空。
Future<List<String>> _dirtyRootsOpen(
  String label,
  VideoFushiTestHooks Function() hooks,
) async {
  final List<(Duration, Element, String)> roots =
      <(Duration, Element, String)>[];
  final RebuildDirtyWidgetCallback? previous = debugOnRebuildDirtyWidget;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    previous?.call(e, builtOnce);
    if (e.dirty) {
      roots.add((
        SchedulerBinding.instance.currentFrameTimeStamp,
        e,
        e is StatefulElement
            ? '${e.widget.runtimeType}(${e.state.runtimeType})'
            : '${e.widget.runtimeType}',
      ));
    }
  };
  final List<String> stacks = <String>[];
  final DebugPrintCallback previousPrint = debugPrint;
  bool captureNext = false;
  String pendingLabel = '';
  debugPrint = (String? message, {int? wrapWidth}) {
    final String m = message ?? '';
    if (m.startsWith('scheduleBuildFor() called for')) {
      captureNext =
          m.contains('VideoFushiPage') || m.contains('VideoViewParameters');
      pendingLabel = m.length > 160 ? m.substring(0, 160) : m;
      return;
    }
    if (captureNext) {
      captureNext = false;
      final String frames = m
          .split('\n')
          .where((String l) => l.contains('package:fushi/'))
          .take(12)
          .join(' <- ');
      stacks.add('$pendingLabel :: $frames');
      return;
    }
    if (m.startsWith('BuildOwner.scheduleBuildFor() called;')) return;
    if (m.startsWith('#')) return;
    previousPrint(message, wrapWidth: wrapWidth);
  };
  debugPrintScheduleBuildForStacks = true;
  try {
    hooks().debugOpenSubtitleSettings();
    await _wait(1500);
  } catch (e) {
    _log('$label error=$e');
  } finally {
    debugPrintScheduleBuildForStacks = false;
    debugPrint = previousPrint;
    debugOnRebuildDirtyWidget = previous;
  }
  final Set<Element> chain = <Element>{};
  final Iterable<Element> sheets = find
      .byType(VideoQuickSettingsSheet)
      .evaluate();
  if (sheets.isNotEmpty) {
    final Element sheet = sheets.first;
    chain.add(sheet);
    sheet.visitAncestorElements((Element a) {
      chain.add(a);
      return true;
    });
  }
  final Map<Duration, List<(Element, String)>> byFrame =
      <Duration, List<(Element, String)>>{};
  for (final (Duration ts, Element e, String name) in roots) {
    (byFrame[ts] ??= <(Element, String)>[]).add((e, name));
  }
  final Duration t0 = byFrame.keys.isEmpty ? Duration.zero : byFrame.keys.first;
  final List<String> wholeTree = <String>[];
  for (final MapEntry<Duration, List<(Element, String)>> f in byFrame.entries) {
    final List<String> onChain = <String>[
      for (final (Element e, String name) in f.value)
        if (chain.contains(e)) name,
    ];
    if (onChain.isEmpty) continue;
    if (f.key != t0) {
      wholeTree.addAll(
        onChain.where(
          (String n) =>
              n.startsWith('VideoFushiPage(') ||
              n.contains('VideoViewParameters'),
        ),
      );
    }
    _log(
      '$label frame+${(f.key - t0).inMilliseconds}ms '
      'dirtyRoots=${f.value.length} onSheetChain=[${onChain.join(', ')}]',
    );
  }
  for (final String st in stacks) {
    _log('$label markNeedsBuild $st');
  }
  hooks().debugHideSidePanel();
  await _wait(1000);
  return wholeTree;
}

/// 抓根图层真像素（视频在播，settle 等不到，不走 [captureFlutterFrame]）。
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

  testWidgets('视频侧栏各玻璃档帧时', (WidgetTester tester) async {
    final FlutterExceptionHandler? frameworkOnError = FlutterError.onError;
    await launchFushiTestApp(
      seedPrefs: const <String, String>{
        'design_system': 's:glass',
        'glass_quality': 's:premium',
      },
    );
    // 玻璃设计系统下 [waitForHome] 认不出主导航，改等 [HomePage] 挂载。
    expect(await _waitForHomePage(tester), isTrue, reason: '主页应在 90s 内出现');
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
    bool panelOpened = false;
    final List<String> wholeTreeRebuilds = <String>[];
    if (videoReady) {
      await hooks().debugPlay();
      await hooks().debugSeekMs(0);
      await _wait(2000);
      await _measure('closed premium', budgetMs);

      // 进程内首开与一次重复打开各录一段 timeline，看卡在哪个 widget / 阶段。
      wholeTreeRebuilds
        ..addAll(await _dirtyRootsOpen('dirty first-open', hooks))
        ..addAll(await _dirtyRootsOpen('dirty repeat-open', hooks));
      await _traceOpen('trace first-open', binding, hooks);
      await _traceOpen('trace repeat-open', binding, hooks);

      // 打开过程（挂载 + 进场动画）：premium 与 minimal 交替，抵掉跨轮噪声。
      for (final FushiGlassMaterial m in <FushiGlassMaterial>[
        FushiGlassMaterial.premium,
        FushiGlassMaterial.minimal,
        FushiGlassMaterial.premium,
      ]) {
        await appModel.setGlassMaterial(m);
        await _wait(1000);
        await _measureOpen('opening ${m.name}', budgetMs, hooks);
      }

      hooks().debugOpenSubtitleSettings();
      await _wait(2000); // 进场动画走完，进入稳态
      panelOpened = _panelMounted();
      await _measure('open premium#1', budgetMs);

      for (final FushiGlassMaterial m in <FushiGlassMaterial>[
        FushiGlassMaterial.standard,
        FushiGlassMaterial.minimal,
        FushiGlassMaterial.premium,
      ]) {
        await appModel.setGlassMaterial(m);
        await _wait(1500);
        await _measure('open ${m.name}', budgetMs);
      }

      await hooks().debugPause();
      await hooks().debugSeekMs(20000);
      await _wait(2500);
      shot = await _captureFrame('panel-perf-open-premium', dpr);
      _log('shot path=$shot');
    }

    FlutterError.onError = frameworkOnError;
    expect(videoReady, isTrue, reason: '视频应在 30s 内就绪');
    expect(panelOpened, isTrue, reason: '字幕设置面板应已打开');
    expect(shot, isNotNull);
    expect(
      wholeTreeRebuilds,
      isEmpty,
      reason: '打开字幕面板期间不应整页 / 整个控件层重建（BUG-5590）',
    );
  });
}
