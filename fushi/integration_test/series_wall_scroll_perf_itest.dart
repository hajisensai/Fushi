// 视频「系列」墙滚轮滚动卡顿探针（应用内反馈 eBQtk9r7Z2，BUG 见 docs/bugs）。
//
// 复现反馈现场：约 45 个系列合集（每个合集 = 2:3 海报做前层 + 3 集 16:9 截帧做
// 叠层后两本，与刮削过的真实库同形），窗口按 1336×851 逻辑 @1.75（覆盖
// `tester.view` 的 physicalSize / devicePixelRatio，与反馈机 3840×2160 @150% 下
// 的窗口同几何、同纹理尺寸），打开 视频 → 媒体库 → 系列，指针停在网格上，按
// Windows 一档滚轮（100 物理 px ÷ DPR）每 250 ms 一档连续上下滚动——与真实滚轮
// 同一条路径（根部 `SmoothWheelScrollScope` 的 140 ms 补间）。
//
// 每一轮记：
//   - 引擎 [FrameTiming]：build / raster p50 / p95 / max；
//   - 每档滚轮之后「该出帧却没出」的最长空档（stall：从派发这一档到补间 + 一帧
//     落定窗口内相邻两帧 rasterFinish 的最大间隔），>100 ms / >200 ms 的档数；
//   - UI isolate 事件循环滞后（16 ms 定时器的迟到量）；
//   - 图片解码次数（探针 binding 计 `instantiateImageCodecWithSize`）、
//     [RenderBakedSurface] 离屏烘焙次数、imageCache 占用。
// 结果以 `[series-perf]` 前缀打进日志，同时写到 `<FUSHI_TEST_ROOT>/series_wall_scroll_perf.txt`。
//
// 跑法（profile，数字才可信；安装版开着时设 FUSHI_TEST_HIDDEN 走测试 runner）：
//   FUSHI_TEST_HIDDEN=1 FUSHI_TEST_ONSCREEN=1
//   FUSHI_WEBVIEW2_USER_DATA_FOLDER=<测试根>/webview2
//   dart tool/heavy.dart --max-minutes=40 -- flutter drive --profile -d windows
//     --no-pub --driver=test_driver/integration_test.dart
//     --target=integration_test/series_wall_scroll_perf_itest.dart
//     --dart-define=FUSHI_TEST_ROOT=<空目录>
// 也可走 debug 离屏 runner（build 段是 JIT，只看 raster / 计数）：
//   dart tool/heavy.dart --max-minutes=25 -- pwsh -File tool/run_windows_itest.ps1
//     integration_test/series_wall_scroll_perf_itest.dart
// 可选 `SERIES_PERF_NOTCHES=40`（单向档数）、`SERIES_PERF_ROUNDS=2`（每组轮数）。
import 'dart:async';
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart'
    show FlutterExceptionHandler, kProfileMode, kReleaseMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart'
    show singleVideoBookUid;
import 'package:fushi/src/media/video/video_library_section.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/home_video_page.dart';
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/utils/components/baked_surface.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/focus_driver.dart';
import 'helpers/library_fixture.dart';
import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _tag = '[series-perf]';

/// 反馈机窗口：1336×851 逻辑 @1.75。
const double _kDpr = 1.75;
const Size _kLogicalWindow = Size(1336, 851);

/// Windows 一档滚轮 = 系统「每次滚动 3 行」× 100/3 物理 px，框架交给
/// [PointerScrollEvent] 的是物理 px ÷ DPR。
const double _kNotchLogical = 100 / _kDpr;

const int _kCollections = 45;
const int _kEpisodesPerCollection = 3;

int _intKnob(String name, int fallback) =>
    int.tryParse(Platform.environment[name] ?? '') ?? fallback;

final int _kNotches = _intKnob('SERIES_PERF_NOTCHES', 40);
final int _kRounds = _intKnob('SERIES_PERF_ROUNDS', 2);

/// 探针 binding：在 [IntegrationTestWidgetsFlutterBinding] 之上数图片解码。
class _ProbeBinding extends IntegrationTestWidgetsFlutterBinding {
  static int decodes = 0;

  @override
  Future<ui.Codec> instantiateImageCodecWithSize(
    ui.ImmutableBuffer buffer, {
    ui.TargetImageSizeCallback? getTargetSize,
  }) {
    decodes++;
    return super.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: getTargetSize,
    );
  }
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

final StringBuffer _report = StringBuffer();

void _log(String line) {
  debugPrint('$_tag $line');
  _report.writeln(line);
}

Future<Directory> _fixturesDir() async {
  final String? root = fushiTestRootPath();
  final Directory dir = root == null || root.isEmpty
      ? await Directory.systemTemp.createTemp('fushi_series_perf_')
      : Directory('$root${Platform.pathSeparator}series-fixtures');
  await dir.create(recursive: true);
  return dir;
}

Future<void> _ffmpeg(List<String> args) async {
  final FfmpegRunResult r = await resolveFfmpegBackend().run(
    args,
    const Duration(minutes: 5),
  );
  if (!r.isSuccess) fail('ffmpeg 失败: ${r.failureSummary}');
}

/// 造库：每个合集一张 1000×1500 海报（合集自有封面）+ 3 集，每集一张 1920×1080
/// 截帧封面。图上叠时变噪点，jpg 体积与解码量接近真实海报 / 截帧（纯色测试图
/// 会被编码成几 KB，低估解码成本）。视频文件是同一段 1 秒小片的拷贝。
Future<int> _seedLibrary(AppModel appModel) async {
  final Directory dir = await _fixturesDir();
  final String sep = Platform.pathSeparator;
  final String clip = '${dir.path}${sep}clip.mp4';
  if (!File(clip).existsSync()) {
    await _ffmpeg(<String>[
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=320x180:rate=12',
      '-t',
      '1',
      '-c:v',
      'mpeg4',
      clip,
    ]);
  }
  if (!File('${dir.path}${sep}poster_${_kCollections - 1}.jpg').existsSync()) {
    await _ffmpeg(<String>[
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc2=size=1000x1500:rate=5',
      '-vf',
      'noise=alls=22:allf=t+u,hue=H=2*PI*t/9',
      '-frames:v',
      '$_kCollections',
      '-q:v',
      '3',
      '-start_number',
      '0',
      '${dir.path}${sep}poster_%d.jpg',
    ]);
  }
  const int thumbs = _kCollections * _kEpisodesPerCollection;
  if (!File('${dir.path}${sep}thumb_${thumbs - 1}.jpg').existsSync()) {
    await _ffmpeg(<String>[
      '-y',
      '-f',
      'lavfi',
      '-i',
      'testsrc=size=1920x1080:rate=5',
      '-vf',
      'noise=alls=18:allf=t+u,hue=H=2*PI*t/13:s=0.8',
      '-frames:v',
      '$thumbs',
      '-q:v',
      '3',
      '-start_number',
      '0',
      '${dir.path}${sep}thumb_%d.jpg',
    ]);
  }
  final VideoBookRepository repo = VideoBookRepository(appModel.database);
  final List<int> clipBytes = File(clip).readAsBytesSync();
  for (int c = 0; c < _kCollections; c++) {
    final String name = 'Series ${(c + 1).toString().padLeft(2, '0')}';
    final int id = await appModel.database.createMediaCollection(name);
    await appModel.database.updateMediaCollectionCoverPath(
      id,
      File('${dir.path}${sep}poster_$c.jpg').absolute.path,
    );
    for (int e = 0; e < _kEpisodesPerCollection; e++) {
      final int n = c * _kEpisodesPerCollection + e;
      final File video = File('${dir.path}${sep}s${c}_e$e.mp4');
      if (!video.existsSync()) video.writeAsBytesSync(clipBytes);
      final String path = video.absolute.path;
      final String uid = singleVideoBookUid(path);
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: Value(uid),
          title: Value('$name - ${(e + 1).toString().padLeft(2, '0')}'),
          videoPath: Value(path),
          coverPath: Value(File('${dir.path}${sep}thumb_$n.jpg').absolute.path),
        ),
      );
      await appModel.database.addToCollection(id, MediaKind.video, uid);
    }
  }
  return _kCollections;
}

const String _kVideoSubNav = 'video-library-subview';

Finder _videoNav() => find.byWidgetPredicate(
  (Widget widget) =>
      widget is FushiAdjustableSegmented<VideoLibrarySection> &&
      widget.focusIdPrefix == _kVideoSubNav,
);

Finder _collectionCards() => find.byWidgetPredicate(
  (Widget w) =>
      w.key is ValueKey<String> &&
      (w.key! as ValueKey<String>).value.startsWith(
        'home_video_collection_card_',
      ),
);

Future<bool> _waitFor(
  WidgetTester tester,
  bool Function() predicate, {
  int ticks = 120,
}) async {
  for (int i = 0; i < ticks; i++) {
    if (predicate()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return predicate();
}

/// 焦点驱动切到「系列」：二级胶囊上按方向键，直到选中 series。
Future<void> _openSeries(WidgetTester tester) async {
  final FocusDriver driver = FocusDriver(tester);
  expect(
    await _waitFor(tester, () => _videoNav().evaluate().isNotEmpty),
    isTrue,
    reason: '视频库二级导航应出现',
  );
  for (int i = 0; i < 4; i++) {
    final VideoLibrarySection selected = tester
        .widget<FushiAdjustableSegmented<VideoLibrarySection>>(_videoNav())
        .selected;
    if (selected == VideoLibrarySection.series) return;
    expect(
      // 不按 debugLabel 过滤：FocusNode.debugLabel 只在 debug 构建有值。二级胶囊
      // 整排是单个焦点停靠点（各段被 ExcludeFocus 移出遍历），第一个能拿到焦点
      // 的就是它。
      await driver.requestFocusInside(_videoNav()),
      isTrue,
    );
    // 显式给物理键：profile 下 flutter_test 按 debugName 反查物理键会空指针
    // （FocusDriver.adjust 不带物理键）。
    final bool forward = selected.index < VideoLibrarySection.series.index;
    await tester.sendKeyEvent(
      forward ? LogicalKeyboardKey.arrowRight : LogicalKeyboardKey.arrowLeft,
      physicalKey: forward
          ? PhysicalKeyboardKey.arrowRight
          : PhysicalKeyboardKey.arrowLeft,
    );
    await tester.pump(const Duration(milliseconds: 400));
  }
  expect(
    tester
        .widget<FushiAdjustableSegmented<VideoLibrarySection>>(_videoNav())
        .selected,
    VideoLibrarySection.series,
  );
}

/// 指针下可命中的最大纵向滚动区中心。
Offset? _pickPointerTarget(WidgetTester tester) {
  Offset? best;
  double bestArea = 0;
  for (final Element e in find.byType(Scrollable).evaluate()) {
    final ScrollableState state =
        (e as StatefulElement).state as ScrollableState;
    if (state.axisDirection != AxisDirection.down) continue;
    if (state.position.maxScrollExtent <= 0) continue;
    final RenderBox? box = e.renderObject as RenderBox?;
    if (box == null || !box.hasSize || !box.attached) continue;
    final Offset center = box.localToGlobal(box.size.center(Offset.zero));
    final HitTestResult hit = tester.hitTestOnBinding(center);
    if (!hit.path.any((HitTestEntry entry) => entry.target == box)) continue;
    final double area = box.size.width * box.size.height;
    if (area > bestArea) {
      bestArea = area;
      best = center;
    }
  }
  return best;
}

/// 计数器快照。
class _Counters {
  _Counters.now()
    : decodes = _ProbeBinding.decodes,
      bakes = RenderBakedSurface.debugBakeCount;

  final int decodes;
  final int bakes;

  String diff(_Counters later) =>
      'decodes=${later.decodes - decodes} bakes=${later.bakes - bakes}';
}

/// UI isolate 事件循环滞后：16 ms 定时器每次迟到多少。
class _LoopLag {
  Timer? _timer;
  final Stopwatch _sw = Stopwatch();
  int _last = 0;
  int maxLagUs = 0;
  int over100 = 0;

  void start() {
    _sw.start();
    _last = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      final int now = _sw.elapsedMicroseconds;
      final int lag = now - _last - 16000;
      _last = now;
      if (lag > maxLagUs) maxLagUs = lag;
      if (lag > 100000) over100++;
    });
  }

  void stop() {
    _timer?.cancel();
    _sw.stop();
  }
}

double _pct(List<double> sorted, double p) => sorted.isEmpty
    ? 0
    : sorted[((sorted.length - 1) * p).round().clamp(0, sorted.length - 1)];

String _f(double v) => v.toStringAsFixed(1);

/// 一轮的统计结果（汇总表用）。
class _RoundStats {
  _RoundStats(this.label);
  final String label;
  int frames = 0;
  double buildP50 = 0, buildP95 = 0, buildMax = 0;
  double rasterP50 = 0, rasterP95 = 0, rasterMax = 0;
  double stallMax = 0;
  int stall100 = 0, stall200 = 0;
  double lagMax = 0;
  int lag100 = 0;
  String counters = '';
  int bakes = 0;
}

final List<_RoundStats> _allRounds = <_RoundStats>[];
final List<FrameTiming> _timings = <FrameTiming>[];

/// 跑一轮：[notches] 档往下、再 [notches] 档往上，每 250 ms 一档。
Future<_RoundStats> _round(
  WidgetTester tester,
  TestPointer mouse,
  String label,
) async {
  final _RoundStats s = _RoundStats(label);
  final _LoopLag lag = _LoopLag()..start();
  final _Counters before = _Counters.now();
  final List<int> notchAt = <int>[];
  final List<_Counters> notchCounters = <_Counters>[];
  final int t0 = Timeline.now;
  for (final double dy in <double>[_kNotchLogical, -_kNotchLogical]) {
    for (int n = 0; n < _kNotches; n++) {
      notchCounters.add(_Counters.now());
      notchAt.add(Timeline.now);
      await tester.sendEventToBinding(mouse.scroll(Offset(0, dy)));
      await _wait(250);
    }
  }
  notchCounters.add(_Counters.now());
  await _wait(600);
  final int t1 = Timeline.now;
  lag.stop();
  // FrameTiming 批量回报有延迟。
  await _wait(800);
  final _Counters after = _Counters.now();

  final List<FrameTiming> f =
      _timings
          .where(
            (FrameTiming t) =>
                t.timestampInMicroseconds(ui.FramePhase.vsyncStart) >= t0 &&
                t.timestampInMicroseconds(ui.FramePhase.vsyncStart) <= t1,
          )
          .toList()
        ..sort(
          (FrameTiming a, FrameTiming b) => a
              .timestampInMicroseconds(ui.FramePhase.rasterFinish)
              .compareTo(b.timestampInMicroseconds(ui.FramePhase.rasterFinish)),
        );
  s.frames = f.length;
  List<double> ms(Duration Function(FrameTiming) pick) =>
      f.map((FrameTiming t) => pick(t).inMicroseconds / 1000).toList()..sort();
  final List<double> build = ms((FrameTiming t) => t.buildDuration);
  final List<double> raster = ms((FrameTiming t) => t.rasterDuration);
  s.buildP50 = _pct(build, .5);
  s.buildP95 = _pct(build, .95);
  s.buildMax = build.isEmpty ? 0 : build.last;
  s.rasterP50 = _pct(raster, .5);
  s.rasterP95 = _pct(raster, .95);
  s.rasterMax = raster.isEmpty ? 0 : raster.last;

  // 每档的 stall：派发时刻 → 补间（140 ms）+ 收尾一帧窗口内，相邻两次 rasterFinish
  // 的最长间隔（第一段从派发时刻算起）。窗口之外的空档是「没东西要画」的空闲。
  final List<int> finishes = <int>[
    for (final FrameTiming t in f)
      t.timestampInMicroseconds(ui.FramePhase.rasterFinish),
  ];
  final List<({int notch, double stall, String counters})> perNotch =
      <({int notch, double stall, String counters})>[];
  for (int i = 0; i < notchAt.length; i++) {
    final int start = notchAt[i];
    final int windowEnd = start + 200000;
    int prev = start;
    int worst = 0;
    for (final int fin in finishes) {
      if (fin <= start) continue;
      final int gap = fin - prev;
      if (gap > worst) worst = gap;
      prev = fin;
      if (fin >= windowEnd) break;
    }
    // 窗口里一帧都没出完：空档至少延续到窗口结束之后的第一帧。
    if (prev == start) {
      final int next = finishes.firstWhere(
        (int fin) => fin > start,
        orElse: () => t1,
      );
      worst = next - start;
    }
    final double stallMs = worst / 1000;
    perNotch.add((
      notch: i,
      stall: stallMs,
      counters: notchCounters[i].diff(notchCounters[i + 1]),
    ));
    if (stallMs > s.stallMax) s.stallMax = stallMs;
    if (stallMs > 100) s.stall100++;
    if (stallMs > 200) s.stall200++;
  }
  s.lagMax = lag.maxLagUs / 1000;
  s.lag100 = lag.over100;
  s.counters = before.diff(after);
  s.bakes = after.bakes - before.bakes;
  final ImageCache cache = PaintingBinding.instance.imageCache;
  _log(
    '$label frames=${s.frames} '
    'build p50=${_f(s.buildP50)} p95=${_f(s.buildP95)} max=${_f(s.buildMax)} | '
    'raster p50=${_f(s.rasterP50)} p95=${_f(s.rasterP95)} '
    'max=${_f(s.rasterMax)} | stall max=${_f(s.stallMax)} '
    '>100=${s.stall100} >200=${s.stall200} /${notchAt.length} | '
    'loopLag max=${_f(s.lagMax)} >100=${s.lag100} | ${s.counters} | '
    'imageCache=${(cache.currentSizeBytes / 1048576).toStringAsFixed(0)}MB/'
    '${(cache.maximumSizeBytes / 1048576).toStringAsFixed(0)}MB '
    'n=${cache.currentSize} live=${cache.liveImageCount}',
  );
  perNotch.sort(
    (
      ({int notch, double stall, String counters}) a,
      ({int notch, double stall, String counters}) b,
    ) => b.stall.compareTo(a.stall),
  );
  for (final ({int notch, double stall, String counters}) n in perNotch.take(
    5,
  )) {
    _log('$label   worst notch#${n.notch} stall=${_f(n.stall)} ${n.counters}');
  }
  _allRounds.add(s);
  return s;
}

void main() {
  _ProbeBinding();
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('series wall wheel-scroll stalls', (WidgetTester tester) async {
    // app 的 main 会换掉 FlutterError.onError；失败的 expect 要报回框架，断言前还原。
    final FlutterExceptionHandler? originalOnError = FlutterError.onError;
    // 启动页设成视频模块：`HomePage.debugSelectTab` 只在 debug 构建注册，profile
    // 下切不了 tab。视频页监听库表变化，播种后自己重列。
    await launchFushiTestApp(
      seedPrefs: <String, String>{
        ModuleId.startupPrefKey: 's:${ModuleId.video.prefKey}',
        // 一次性「库页默认改为封面网格」弹窗会盖住网格、吞掉滚轮。
        'library_layout_default_notice_handled': 'b:true',
      },
    );
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    final AppModel appModel = await readyAppModel(tester);
    final int seeded = await _seedLibrary(appModel);

    HomePage.debugSelectTab?.call(HomeTab.video);
    await tester.pump(const Duration(seconds: 2));
    await _openSeries(tester);
    HomeVideoPage.debugRefreshVideos?.call();
    final bool cardsShown = await _waitFor(
      tester,
      () => _collectionCards().evaluate().length >= 10,
    );

    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final Size nativePhysical = tester.view.physicalSize;
    final double nativeDpr = tester.view.devicePixelRatio;
    tester.view.devicePixelRatio = _kDpr;
    tester.view.physicalSize = _kLogicalWindow * _kDpr;
    // 进场动画 / 存在性探测 / 首屏解码落定。
    await _wait(4000);
    SchedulerBinding.instance.addTimingsCallback(_timings.addAll);
    _log(
      'seeded=$seeded cards=${_collectionCards().evaluate().length} '
      'nativeWindow=${nativePhysical.width.round()}x'
      '${nativePhysical.height.round()}@$nativeDpr '
      'override=${(_kLogicalWindow * _kDpr).width.round()}x'
      '${(_kLogicalWindow * _kDpr).height.round()}@$_kDpr '
      'notchLogical=${_kNotchLogical.toStringAsFixed(2)} notches=$_kNotches '
      'rounds=$_kRounds refresh=${tester.view.display.refreshRate} '
      'mode=${kReleaseMode
          ? 'release'
          : kProfileMode
          ? 'profile'
          : 'debug'}',
    );
    final ObserveShot before = await captureFlutterFrame(
      tester,
      'series-wall-rest',
      pixelRatio: _kDpr,
    );
    _log('shot rest=${before.path} nonBlank=${before.nonBlank}');

    final Offset at =
        _pickPointerTarget(tester) ??
        tester.getCenter(_collectionCards().hitTestable().first);
    _log('pointer at=${at.dx},${at.dy}');
    final TestPointer mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(at));
    await _wait(800);

    // 第一轮是冷的：存在性探测、首轮解码、首次烘焙都在里面。
    await _round(tester, mouse, 'cold');
    for (int r = 0; r < _kRounds; r++) {
      await _round(tester, mouse, 'warm#$r');
    }

    // 关键帧真像素：停在中段一档滚完之后。
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 400)));
    await _wait(1500);
    await tester.sendEventToBinding(mouse.hover(Offset.zero));
    await _wait(1500);
    final ObserveShot mid = await captureFlutterFrame(
      tester,
      'series-wall-mid',
      pixelRatio: _kDpr,
    );
    _log('shot mid=${mid.path} nonBlank=${mid.nonBlank}');

    SchedulerBinding.instance.removeTimingsCallback(_timings.addAll);
    _log('summary:');
    _log(
      'label | frames | build p50/p95/max | raster p50/p95/max | '
      'stall max / >100 / >200 | loopLag max / >100 | counters',
    );
    for (final _RoundStats s in _allRounds) {
      _log(
        '${s.label} | ${s.frames} | ${_f(s.buildP50)}/${_f(s.buildP95)}/'
        '${_f(s.buildMax)} | ${_f(s.rasterP50)}/${_f(s.rasterP95)}/'
        '${_f(s.rasterMax)} | ${_f(s.stallMax)} / ${s.stall100} / '
        '${s.stall200} | ${_f(s.lagMax)} / ${s.lag100} | ${s.counters}',
      );
    }
    final String? root = fushiTestRootPath();
    if (root != null && root.isNotEmpty) {
      final File out = File(
        '$root${Platform.pathSeparator}series_wall_scroll_perf.txt',
      );
      out.writeAsStringSync(_report.toString());
      debugPrint('$_tag report=${out.path}');
    }
    tester.view.reset();

    FlutterError.onError = originalOnError;
    expect(cardsShown, isTrue, reason: '系列墙应渲染出合集卡');
    expect(seeded, _kCollections);
    expect(_allRounds.every((_RoundStats s) => s.frames > 0), isTrue);
    // 热轮里只有新滚进视口的面才该离屏烘焙：一屏两行、每张合集卡 3 面，上下各
    // [_kNotches] 档总共换进来十几行。修复前每档都把整屏重烘（约 15 次 / 档，
    // 一轮 1100+ 次）。
    for (final _RoundStats s in _allRounds.where(
      (_RoundStats s) => s.label.startsWith('warm'),
    )) {
      expect(
        s.bakes,
        lessThanOrEqualTo(_kNotches * 4),
        reason: '${s.label}：一轮烘焙 ${s.bakes} 次（${s.counters}）',
      );
    }
    expect(before.saved && mid.saved, isTrue);
  });
}
