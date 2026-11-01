// 视频页 push-aside 字幕列表开 / 关的帧时探针（BUG-3888 续）。
//
// 真 app、真 media_kit 画面、真字幕列表：播种一段视频 + 数百行字幕，暂停后按 `L`
// 开关字幕列表（焦点驱动，不点坐标），每个方向记：
//   - 引擎 [FrameTiming]（build / raster 各段）与相邻帧 vsync 间隔（找「几百毫秒没出新帧」）；
//   - 一轮带 `debugProfileBuildsEnabled` 等开关的 VM timeline，按事件名汇总 self 时间，
//     并列出单个 >8ms 的事件及其祖先链（定位是哪棵子树 / 哪个同步操作）。
// 结果以 `[sublist-perf]` 前缀打进 command.log。
//
// 跑法（Windows 离屏 runner，debug 模式——绝对耗时只作相对归因）：
//   dart tool/heavy.dart -- pwsh -File tool/run_windows_itest.ps1
//     integration_test/video_subtitle_list_toggle_perf_itest.dart -Visible
// 可选 `-DartDefine FUSHI_PROBE_VIDEO=<本地视频绝对路径>` 用真片代替生成的素材。
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart'
    show openLocalVideoBook;
import 'package:fushi_audio/fushi_audio.dart' show AudioCue;
import 'package:fushi_core/fushi_core.dart' show VideoBooksCompanion;
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit_video/media_kit_video.dart' show Video;
import 'package:vm_service/vm_service.dart' as vm;

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/media_fixtures.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const Key _kPanelKey = ValueKey<String>('video-subtitle-jump-panel');
const String _kProbeVideo = String.fromEnvironment('FUSHI_PROBE_VIDEO');
const String _tag = '[sublist-perf]';

/// `--dart-define=SUBLIST_TRACE=false`：首轮也不录 timeline（纯帧时对照用）。
const bool _kTraceFirstCycle = bool.fromEnvironment(
  'SUBLIST_TRACE',
  defaultValue: true,
);

Future<Directory> _fixturesDir() async {
  const String testRoot = String.fromEnvironment('FUSHI_TEST_ROOT');
  final Directory dir = testRoot.isEmpty
      ? await Directory.systemTemp.createTemp('fushi_fixtures_')
      : Directory('$testRoot${Platform.pathSeparator}fixtures');
  await dir.create(recursive: true);
  return dir;
}

/// 1080p、60 秒的素材 + 400 行 sidecar 字幕（接近一集动画的行数）。
Future<String> _seedVideo(VideoBookRepository repo, Directory dir) async {
  String videoPath = _kProbeVideo;
  if (videoPath.isEmpty) {
    videoPath = '${dir.path}${Platform.pathSeparator}sublist-perf.mp4';
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
    if (!r.isSuccess) {
      fail('ffmpeg 生成素材失败: ${r.failureSummary}');
    }
  }
  final String base = videoPath.substring(0, videoPath.lastIndexOf('.'));
  final File srt = File('$base.srt');
  if (!srt.existsSync()) {
    // 每行文本都不同、长短不一（真动画字幕几乎不重句）：行高缓存按文本作键，
    // 循环 5 句的样例会让首开只量 5 次，严重低估真实首开开销。
    final List<AudioCue> cues = buildSampleCues(
      bookKey: 'sublist-perf',
      count: 400,
    );
    for (int i = 0; i < cues.length; i++) {
      final String a = cues[i].text;
      final String b = cues[(i * 3 + 1) % cues.length].text;
      cues[i].text = '$a${b.substring(0, i % b.length)}（${i + 1}）';
    }
    await srt.writeAsString(cuesToSrt(cues));
  }
  final String bookUid = singleVideoBookUid(videoPath);
  await repo.saveVideoBook(
    VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: const Value('sublist-perf'),
      videoPath: Value(File(videoPath).absolute.path),
    ),
  );
  return bookUid;
}

bool _videoMounted() => find.byType(Video).evaluate().isNotEmpty;
bool _panelMounted() =>
    find.byKey(_kPanelKey, skipOffstage: false).evaluate().isNotEmpty;

/// 按 `L`（字幕列表开关）。显式给物理键：profile 模式下 flutter_test 的键事件模拟按
/// `debugName` 反查物理键，而 debugName 只在 debug 下有值，会空指针。
Future<void> _pressL(WidgetTester tester) => tester.sendKeyEvent(
  LogicalKeyboardKey.keyL,
  physicalKey: PhysicalKeyboardKey.keyL,
);

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// 一次开 / 关的帧记录。
class _FrameLog {
  final List<FrameTiming> timings = <FrameTiming>[];
  void _collect(List<FrameTiming> batch) => timings.addAll(batch);
  void start() => SchedulerBinding.instance.addTimingsCallback(_collect);
  void stop() => SchedulerBinding.instance.removeTimingsCallback(_collect);

  void report(String label, int t0Micros) {
    final List<FrameTiming> f = timings
        .where((FrameTiming t) => t.timestampInMicroseconds(_vsync) >= t0Micros)
        .toList();
    if (f.isEmpty) {
      debugPrint('$_tag $label frames=0');
      return;
    }
    int maxGap = 0;
    int prev = t0Micros;
    final StringBuffer rows = StringBuffer();
    for (final FrameTiming t in f) {
      final int vs = t.timestampInMicroseconds(_vsync);
      final int gap = vs - prev;
      if (gap > maxGap) maxGap = gap;
      prev = vs;
      rows.write(
        ' [+${((vs - t0Micros) / 1000).toStringAsFixed(0)}'
        ' gap=${(gap / 1000).toStringAsFixed(0)}'
        ' b=${t.buildDuration.inMicroseconds ~/ 1000}'
        ' r=${t.rasterDuration.inMicroseconds ~/ 1000}]',
      );
    }
    final int lastVs = f.last.timestampInMicroseconds(_vsync);
    final int maxBuild = f
        .map((FrameTiming t) => t.buildDuration.inMicroseconds)
        .reduce((int a, int b) => a > b ? a : b);
    final int maxRaster = f
        .map((FrameTiming t) => t.rasterDuration.inMicroseconds)
        .reduce((int a, int b) => a > b ? a : b);
    debugPrint(
      '$_tag $label frames=${f.length} '
      'span=${((lastVs - t0Micros) / 1000).toStringAsFixed(0)}ms '
      'maxGap=${(maxGap / 1000).toStringAsFixed(0)}ms '
      'maxBuild=${maxBuild ~/ 1000}ms maxRaster=${maxRaster ~/ 1000}ms',
    );
    debugPrint('$_tag $label perFrame:$rows');
  }
}

const FramePhase _vsync = FramePhase.vsyncStart;

/// 按键时刻（单调时钟微秒；Windows 上 Dart `Timeline.now` 与引擎 [FrameTiming]
/// 同走 QueryPerformanceCounter）。
int _nowMicros() => Timeline.now;

class _Ev {
  _Ev(this.name, this.tid, this.start, this.end);
  final String name;
  final int tid;
  final int start;
  int end;
  int childTotal = 0;
  _Ev? parent;
  int get dur => end - start;
  int get self => dur - childTotal;
}

/// 解析 Chrome trace 事件（'B'/'E' 配对与 'X' 完整事件），重建每线程嵌套。
List<_Ev> _parseTimeline(vm.Timeline tl) {
  final Map<int, List<Map<String, dynamic>>> byTid =
      <int, List<Map<String, dynamic>>>{};
  for (final vm.TimelineEvent e in tl.traceEvents ?? <vm.TimelineEvent>[]) {
    final Map<String, dynamic> j = e.json!;
    final String? ph = j['ph'] as String?;
    if (ph != 'B' && ph != 'E' && ph != 'X') continue;
    (byTid[j['tid'] as int? ?? 0] ??= <Map<String, dynamic>>[]).add(j);
  }
  final List<_Ev> out = <_Ev>[];
  byTid.forEach((int tid, List<Map<String, dynamic>> evs) {
    evs.sort(
      (Map<String, dynamic> a, Map<String, dynamic> b) =>
          (a['ts'] as int).compareTo(b['ts'] as int),
    );
    final List<_Ev> stack = <_Ev>[];
    final List<_Ev> xs = <_Ev>[];
    for (final Map<String, dynamic> j in evs) {
      final int ts = j['ts'] as int;
      switch (j['ph']) {
        case 'B':
          final _Ev ev = _Ev(j['name'] as String, tid, ts, ts);
          ev.parent = stack.isEmpty ? null : stack.last;
          stack.add(ev);
        case 'E':
          if (stack.isEmpty) break;
          final _Ev ev = stack.removeLast()..end = ts;
          out.add(ev);
        case 'X':
          xs.add(
            _Ev(j['name'] as String, tid, ts, ts + (j['dur'] as int? ?? 0)),
          );
      }
    }
    out.addAll(xs);
  });
  // 用区间包含关系重算父子（X 与 B/E 混排时 B/E 的 parent 不全）。
  final Map<int, List<_Ev>> perTid = <int, List<_Ev>>{};
  for (final _Ev e in out) {
    (perTid[e.tid] ??= <_Ev>[]).add(e);
  }
  perTid.forEach((int _, List<_Ev> evs) {
    evs.sort((_Ev a, _Ev b) {
      final int c = a.start.compareTo(b.start);
      return c != 0 ? c : b.end.compareTo(a.end);
    });
    final List<_Ev> stack = <_Ev>[];
    for (final _Ev e in evs) {
      while (stack.isNotEmpty && stack.last.end <= e.start) {
        stack.removeLast();
      }
      e.parent = stack.isEmpty ? null : stack.last;
      e.parent?.childTotal += e.dur;
      stack.add(e);
    }
  });
  return out;
}

void _reportTimeline(String label, vm.Timeline tl) {
  final List<_Ev> evs = _parseTimeline(tl);
  final Map<String, int> self = <String, int>{};
  final Map<String, int> count = <String, int>{};
  for (final _Ev e in evs) {
    self[e.name] = (self[e.name] ?? 0) + e.self;
    count[e.name] = (count[e.name] ?? 0) + 1;
  }
  final List<MapEntry<String, int>> top = self.entries.toList()
    ..sort(
      (MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value),
    );
  debugPrint(
    '$_tag $label timeline events=${evs.length} topSelf: ${top.take(30).map((MapEntry<String, int> e) => '${e.key}=${e.value ~/ 1000}ms/${count[e.key]}').join(', ')}',
  );
  // 顶层长事件（帧 / 消息处理）+ 其下最重的直接子事件链。
  final List<_Ev> roots =
      evs.where((_Ev e) => e.parent == null && e.dur > 6000).toList()
        ..sort((_Ev a, _Ev b) => a.start.compareTo(b.start));
  final int t0 = roots.isEmpty ? 0 : roots.first.start;
  for (final _Ev r in roots) {
    final StringBuffer chain = StringBuffer();
    _Ev cur = r;
    for (int depth = 0; depth < 40; depth++) {
      final List<_Ev> kids = evs.where((_Ev e) => e.parent == cur).toList();
      if (kids.isEmpty) break;
      kids.sort((_Ev a, _Ev b) => b.dur.compareTo(a.dur));
      final _Ev k = kids.first;
      if (k.dur < 2000) break;
      chain.write(' > ${k.name}(${k.dur ~/ 1000}ms self=${k.self ~/ 1000})');
      cur = k;
    }
    // 该根事件之下 self 时间最多的 6 个事件（谁真正在花时间）。
    bool under(_Ev e) {
      for (_Ev? p = e.parent; p != null; p = p.parent) {
        if (identical(p, r)) return true;
      }
      return false;
    }

    final List<_Ev> heavy = evs.where(under).toList()
      ..sort((_Ev a, _Ev b) => b.self.compareTo(a.self));
    final String heavyText = heavy
        .take(6)
        .map((_Ev e) => '${e.name}=${(e.self / 1000).toStringAsFixed(1)}')
        .join(', ');
    debugPrint(
      '$_tag $label long +${(r.start - t0) ~/ 1000}ms heavySelf[$heavyText] tid=${r.tid} '
      '${r.name}(${r.dur ~/ 1000}ms self=${r.self ~/ 1000})$chain',
    );
  }
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('字幕列表开 / 关帧时', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));
    final AppModel appModel = await readyAppModel(tester);
    final VideoBookRepository repo = VideoBookRepository(appModel.database);
    final String uid = await _seedVideo(repo, await _fixturesDir());

    final BuildContext ctx = tester.element(find.byType(Scaffold).first);
    unawaited(openLocalVideoBook(context: ctx, repo: repo, bookUid: uid));
    for (int i = 0; i < 60 && !_videoMounted(); i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }
    expect(_videoMounted(), isTrue, reason: '视频应在 30s 内就绪');
    await tester.pump(const Duration(seconds: 2));
    final Video video = tester.widget<Video>(find.byType(Video));
    await video.controller.player.pause();
    await tester.pump(const Duration(seconds: 1));

    final FocusDriver driver = FocusDriver(tester);
    await driver.requestFocusInside(find.byType(Video));
    await tester.pump(const Duration(milliseconds: 200));

    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    debugPrint(
      '$_tag size=${tester.view.physicalSize} dpr=${tester.view.devicePixelRatio} '
      'probeVideo=${_kProbeVideo.isNotEmpty}',
    );

    Future<void> toggle(
      String label, {
      required bool expectOpen,
      bool trace = false,
    }) async {
      final _FrameLog log = _FrameLog()..start();
      await _wait(300);
      final int t0 = _nowMicros();
      vm.Timeline? tl;
      if (trace) {
        // widget 级事件（每个 build / layout / paint 一条）会放大 UI 线程耗时，
        // 本轮帧时只看相对占比；绝对帧时看后面不带 trace 的轮次。
        debugProfileBuildsEnabled = true;
        debugProfileLayoutsEnabled = true;
        debugProfilePaintsEnabled = true;
        try {
          tl = await binding.traceTimeline(() async {
            await _pressL(tester);
            await _wait(1500);
          }, streams: const <String>['Dart', 'Embedder', 'GC']);
        } finally {
          debugProfileBuildsEnabled = false;
          debugProfileLayoutsEnabled = false;
          debugProfilePaintsEnabled = false;
        }
      } else {
        await _pressL(tester);
        await _wait(1500);
      }
      log.stop();
      expect(_panelMounted(), expectOpen, reason: '$label 后列表可见性');
      log.report(label, t0);
      if (tl != null) _reportTimeline(label, tl);
    }

    // 1. 首次开 / 关带 timeline（首开含整轨行高测量等一次性开销，要看清是谁）；
    // 2. 之后两轮不带 trace，量稳态帧时。
    await toggle('open#1', expectOpen: true, trace: _kTraceFirstCycle);
    await toggle('close#1', expectOpen: false, trace: _kTraceFirstCycle);
    await toggle('open#2', expectOpen: true);
    await toggle('close#2', expectOpen: false);
    await toggle('open#3', expectOpen: true);
    await toggle('close#3', expectOpen: false);

    // 3. 关闭动画中段抓一帧真像素：看被收缩的那一列画的是什么（真时钟，不用假时间泵）。
    await _pressL(tester);
    await _wait(1000);
    expect(_panelMounted(), isTrue);
    final double fullWidth =
        tester.view.physicalSize.width / tester.view.devicePixelRatio;
    await _pressL(tester);
    await _wait(70);
    final double videoWidth = tester.getSize(find.byType(Video)).width;
    final bool panelDuringClose = _panelMounted();
    final ObserveShot mid = await captureFlutterFrame(
      tester,
      'sublist-close-mid',
    );
    debugPrint(
      '$_tag closeMid videoWidth=${videoWidth.toStringAsFixed(0)}/'
      '${fullWidth.toStringAsFixed(0)} panelMounted=$panelDuringClose '
      'shot=${mid.path} nonBlank=${mid.nonBlank}',
    );
    await _wait(1000);
  });
}
