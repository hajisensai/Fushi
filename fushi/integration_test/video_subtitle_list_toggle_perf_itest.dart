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
//
// 复现用户环境（profile、可见窗口、补丁引擎）时再加：
//   SUBLIST_PREFS=<json 文件>  启动前写入的 preferences 原始行（`{"design_system":"s:material"}`）；
//   SUBLIST_PLAY=true          不暂停，边播边开关（用户的真实路径）；
//   SUBLIST_WIDGET_TRACE=false 不开 widget 级 build/layout/paint 事件，只看引擎（含 raster 线程）；
//   SUBLIST_TRACE_ALL=true     每一轮开关都录 timeline。
import 'dart:async';
import 'dart:convert' show jsonDecode, jsonEncode;
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
import 'helpers/layer_tree_probe.dart';
import 'helpers/library_fixture.dart';
import 'helpers/media_fixtures.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const Key _kPanelKey = ValueKey<String>('video-subtitle-jump-panel');

/// 探针开关：先读进程环境变量，再退回 `--dart-define`。环境变量让同一份预编译
/// 二进制（`flutter drive --use-application-binary`，便于换补丁引擎 DLL）跑多组对照。
String _knob(String name, String compiled) =>
    Platform.environment[name] ?? compiled;
bool _flag(String name, bool compiled) {
  final String? v = Platform.environment[name];
  return v == null ? compiled : v == 'true' || v == '1';
}

final String _kProbeVideo = _knob(
  'FUSHI_PROBE_VIDEO',
  const String.fromEnvironment('FUSHI_PROBE_VIDEO'),
);
const String _tag = '[sublist-perf]';

/// `--dart-define=SUBLIST_TRACE=false`：首轮也不录 timeline（纯帧时对照用）。
final bool _kTraceFirstCycle = _flag(
  'SUBLIST_TRACE',
  const bool.fromEnvironment('SUBLIST_TRACE', defaultValue: true),
);
final bool _kTraceAll = _flag(
  'SUBLIST_TRACE_ALL',
  const bool.fromEnvironment('SUBLIST_TRACE_ALL'),
);
final bool _kWidgetTrace = _flag(
  'SUBLIST_WIDGET_TRACE',
  const bool.fromEnvironment('SUBLIST_WIDGET_TRACE', defaultValue: true),
);
final bool _kPlay = _flag(
  'SUBLIST_PLAY',
  const bool.fromEnvironment('SUBLIST_PLAY'),
);
final String _kSeedPrefsPath = _knob(
  'SUBLIST_PREFS',
  const String.fromEnvironment('SUBLIST_PREFS'),
);

/// `SUBLIST_DPR=2.0`：覆盖框架看到的 DPR（物理窗口不变，只改布局缩放），让不同
/// 显示器缩放下的轮次可比。空 = 用显示器真实 DPR。
final String _kDprOverride = _knob(
  'SUBLIST_DPR',
  const String.fromEnvironment('SUBLIST_DPR'),
);

/// `SUBLIST_CYCLES=10`：开 / 关循环次数（默认 3）。尖峰逐次波动大，比较变体要看分布。
final int _kCycles =
    int.tryParse(
      _knob('SUBLIST_CYCLES', const String.fromEnvironment('SUBLIST_CYCLES')),
    ) ??
    3;

/// `SUBLIST_LAYERS=true`：关列表的轮次逐帧抓 layer 树（离屏层 / 纹理 / 平台视图）。
final bool _kLayers = _flag(
  'SUBLIST_LAYERS',
  const bool.fromEnvironment('SUBLIST_LAYERS'),
);

Map<String, String> _seedPrefs() {
  if (_kSeedPrefsPath.isEmpty) return const <String, String>{};
  final Map<String, dynamic> raw =
      jsonDecode(File(_kSeedPrefsPath).readAsStringSync())
          as Map<String, dynamic>;
  return raw.map((String k, dynamic v) => MapEntry<String, String>(k, '$v'));
}

Future<Directory> _fixturesDir() async {
  final String testRoot = _knob(
    'FUSHI_TEST_ROOT',
    const String.fromEnvironment('FUSHI_TEST_ROOT'),
  );
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
final Map<int, String> _threadNames = <int, String>{};

List<_Ev> _parseTimeline(vm.Timeline tl) {
  final Map<int, List<Map<String, dynamic>>> byTid =
      <int, List<Map<String, dynamic>>>{};
  for (final vm.TimelineEvent e in tl.traceEvents ?? <vm.TimelineEvent>[]) {
    final Map<String, dynamic> j = e.json!;
    final String? ph = j['ph'] as String?;
    if (ph == 'M' && j['name'] == 'thread_name') {
      final Object? args = j['args'];
      if (args is Map && args['name'] is String) {
        _threadNames[j['tid'] as int? ?? 0] = args['name'] as String;
      }
      continue;
    }
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
      '$_tag $label long +${(r.start - t0) ~/ 1000}ms heavySelf[$heavyText] '
      'tid=${r.tid}(${_threadNames[r.tid] ?? '?'}) '
      '${r.name}(${r.dur ~/ 1000}ms self=${r.self ~/ 1000})$chain',
    );
  }
}

/// 原始 Chrome trace 落盘（`<测试根>/sublist-trace-<轮次>.json`），离线看全部线程
/// 与 GPU 计时事件；探针里的汇总只挑长事件。
Future<void> _dumpTimeline(String label, vm.Timeline tl) async {
  final String root = _knob(
    'FUSHI_TEST_ROOT',
    const String.fromEnvironment('FUSHI_TEST_ROOT'),
  );
  if (root.isEmpty) return;
  final String events = (tl.traceEvents ?? <vm.TimelineEvent>[])
      .map((vm.TimelineEvent e) => jsonEncode(e.json))
      .join(',\n');
  final File out = File(
    '$root${Platform.pathSeparator}sublist-trace-${label.replaceAll('#', '')}.json',
  );
  await out.writeAsString('{"traceEvents":[\n$events\n]}');
  debugPrint('$_tag $label traceFile=${out.path}');
}

/// 关列表一轮的 layer 树报告：四个时点的全量清单（带 widget 归属）+ 逐帧计数与增删。
void _reportLayers(
  String label,
  int t0,
  LayerFrame before,
  Map<int, String> beforeOwners,
  LayerFrameRecorder rec,
) {
  final List<(int, bool, LayerFrame)> fs = rec.frames;
  if (fs.isEmpty) {
    debugPrint('$_tag $label layers frames=0');
    return;
  }
  final int unmountIdx = fs.indexWhere(((int, bool, LayerFrame) f) => !f.$2);
  final StringBuffer rows = StringBuffer();
  LayerFrame prev = before;
  for (int i = 0; i < fs.length; i++) {
    final (int vs, bool panel, LayerFrame f) = fs[i];
    final String diff = diffLayerFrames(prev, f, 5);
    rows.write(
      ' {#$i +${((vs - t0) / 1000).toStringAsFixed(0)} p=${panel ? 1 : 0} '
      '${countsOf(f)}${diff.isEmpty ? '' : ' $diff'}}',
    );
    prev = f;
  }
  debugPrint('$_tag $label layers unmountAt=#$unmountIdx frames:$rows');

  // 归属在录制时就地做（element 树还在）；这里把到第 idx 帧为止的归属合起来查。
  Map<int, String> ownersUpTo(int idx) {
    final Map<int, String> m = <int, String>{...beforeOwners};
    final List<int> keys = rec.owners.keys.where((int k) => k <= idx).toList()
      ..sort();
    for (final int k in keys) {
      m.addAll(rec.owners[k]!);
    }
    return m;
  }

  void snapshot(String phase, LayerFrame f, Map<int, String> owners) {
    final List<ProbeLayer> sorted = f.layers.toList()
      ..sort((ProbeLayer a, ProbeLayer b) => b.area.compareTo(a.area));
    final String body = sorted
        .where(
          (ProbeLayer l) =>
              l.kind != ProbeLayerKind.offscreen ||
              l.area / f.rootArea * 100 >= 1,
        )
        .map((ProbeLayer l) => '${l.brief(f.rootArea)} <= ${owners[l.id]}')
        .join(' || ');
    debugPrint('$_tag $label layers@$phase ${countsOf(f)} :: $body');
  }

  snapshot('before', before, beforeOwners);
  final int mid = unmountIdx > 0 ? unmountIdx ~/ 2 : fs.length ~/ 4;
  snapshot('mid#$mid', fs[mid].$3, ownersUpTo(mid));
  if (unmountIdx >= 0) {
    snapshot('unmount#$unmountIdx', fs[unmountIdx].$3, ownersUpTo(unmountIdx));
  }
  final int last = fs.length - 1;
  snapshot('after#$last', fs[last].$3, ownersUpTo(last));

  // 有增删的帧逐条带归属列出（被删的层用删之前的归属）。
  final List<int> changed = rec.owners.keys.where((int k) => k > 0).toList()
    ..sort();
  for (final int k in changed) {
    final Map<int, String> owners = ownersUpTo(k);
    final LayerFrame p = fs[k - 1].$3;
    final LayerFrame c = fs[k].$3;
    final String diff = diffLayerFrames(p, c, 5);
    if (diff.isEmpty) continue;
    final Set<int> ids = <int>{
      for (final ProbeLayer l in c.layers) l.id,
      for (final ProbeLayer l in p.layers) l.id,
    };
    final String who = ids
        .where((int id) => diff.contains('#${id.toRadixString(16)}['))
        .map((int id) => '${id.toRadixString(16)}=${owners[id]}')
        .join(' | ');
    debugPrint('$_tag $label layers change#$k $diff :: $who');
  }
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('字幕列表开 / 关帧时', (WidgetTester tester) async {
    await launchFushiTestApp(seedPrefs: _seedPrefs());
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
    if (!_kPlay) await video.controller.player.pause();
    await tester.pump(const Duration(seconds: 1));

    final FocusDriver driver = FocusDriver(tester);
    await driver.requestFocusInside(find.byType(Video));
    await tester.pump(const Duration(milliseconds: 200));

    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final double nativeDpr = tester.view.devicePixelRatio;
    final double? dprOverride = double.tryParse(_kDprOverride);
    if (dprOverride != null) {
      tester.view.devicePixelRatio = dprOverride;
      await tester.pump(const Duration(seconds: 1));
    }
    final LayerFrameRecorder layers = LayerFrameRecorder()
      ..panelMounted = _panelMounted;
    debugPrint(
      '$_tag size=${tester.view.physicalSize.width.round()}x'
      '${tester.view.physicalSize.height.round()} nativeDpr=$nativeDpr '
      'dpr=${tester.view.devicePixelRatio} '
      'probeVideo=${_kProbeVideo.isNotEmpty} play=$_kPlay '
      'seedPrefs=${_seedPrefs().length} widgetTrace=$_kWidgetTrace',
    );

    Future<void> toggle(
      String label, {
      required bool expectOpen,
      bool trace = false,
    }) async {
      // 不置顶跑时窗口留在屏上，用户的鼠标路过会把焦点带走（`L` 落空、断言红）。
      // 每轮按键前把焦点放回画面：只校正测试输入，不碰被测路径。
      await driver.requestFocusInside(find.byType(Video));
      await _wait(100);
      final _FrameLog log = _FrameLog()..start();
      final bool recordLayers = _kLayers && !expectOpen;
      LayerFrame? before;
      Map<int, String> beforeOwners = const <int, String>{};
      if (recordLayers) {
        before = captureLayerFrame();
        beforeOwners = attributeLayers(before.layers);
        layers.start();
      }
      await _wait(300);
      final int t0 = _nowMicros();
      vm.Timeline? tl;
      if (trace) {
        // widget 级事件（每个 build / layout / paint 一条）会放大 UI 线程耗时，
        // 本轮帧时只看相对占比；绝对帧时看后面不带 trace 的轮次。
        debugProfileBuildsEnabled = _kWidgetTrace;
        debugProfileLayoutsEnabled = _kWidgetTrace;
        debugProfilePaintsEnabled = _kWidgetTrace;
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
      layers.active = false;
      expect(_panelMounted(), expectOpen, reason: '$label 后列表可见性');
      log.report(label, t0);
      if (recordLayers && before != null) {
        _reportLayers(label, t0, before, beforeOwners, layers);
      }
      if (tl != null) {
        _reportTimeline(label, tl);
        await _dumpTimeline(label, tl);
      }
    }

    // 1. 首次开 / 关带 timeline（首开含整轨行高测量等一次性开销，要看清是谁）；
    // 2. 之后两轮不带 trace，量稳态帧时。
    await toggle('open#1', expectOpen: true, trace: _kTraceFirstCycle);
    await toggle('close#1', expectOpen: false, trace: _kTraceFirstCycle);
    for (int i = 2; i <= _kCycles; i++) {
      await toggle('open#$i', expectOpen: true, trace: _kTraceAll);
      await toggle('close#$i', expectOpen: false, trace: _kTraceAll);
    }

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
