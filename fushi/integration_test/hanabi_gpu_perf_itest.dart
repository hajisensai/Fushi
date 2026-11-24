// 全屏歌词动画「花火」GPU 开销探针（BUG：花火样式 GPU 占用超高）。
//
// 不起整个 app：`runApp` 一个只装歌词动画样式的 MaterialApp（黑底，不叠共享背景），窗口拉到
// 约 2000×1125 物理像素，按 Stopwatch 走的时钟「播放」一首 80 行的逐字歌词。每个场景先热身
// [_kWarmupMs]，再量 [_kWindowMs]：引擎 [FrameTiming] 的 build / raster 分位与帧数，外加
// Windows 性能计数器 `\GPU Engine(pid_<本进程>*engtype_3D)\Utilization Percentage`（逐秒采样求平均，
// 本进程所有 3D 引擎实例相加）。
//
// 场景：基线样式（流光 / 绘光）播放中；花火默认参数播放中；花火关全屏辉光播放中；花火暂停（开动态）；
// 花火暂停 + 关动态。结果以 `[hanabi-perf]` 前缀打进日志，并追加写到
// `<FUSHI_TEST_ROOT>/hanabi-perf-report.txt`。
//
// 跑法（profile 才可信；`FUSHI_TEST_HIDDEN=1` 让窗口停在屏外、不抢前台）：
//   FUSHI_TEST_HIDDEN=1 FUSHI_TEST_ROOT=<测试根> dart tool/heavy.dart --
//     flutter drive --profile -d windows --no-pub
//     --dart-define=FUSHI_TEST_ROOT=<测试根>
//     --driver=test_driver/integration_test.dart
//     --target=integration_test/hanabi_gpu_perf_itest.dart
import 'dart:io';

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_registry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:window_manager/window_manager.dart';

const String _tag = '[hanabi-perf]';
const int _kWarmupMs = 3000;
const int _kWindowMs = 8000;

final String _testRoot =
    Platform.environment['FUSHI_TEST_ROOT'] ??
    const String.fromEnvironment('FUSHI_TEST_ROOT');

void _log(String line) {
  debugPrint('$_tag $line');
  if (_testRoot.isEmpty) return;
  File(
    '$_testRoot${Platform.pathSeparator}hanabi-perf-report.txt',
  ).writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
}

/// 按 Stopwatch 走的播放时钟；[playing] 为 false 时停在当前位置。
class _WallClock implements LyricVisualizerClock {
  _WallClock(this._baseMs);

  int _baseMs;
  final Stopwatch _sw = Stopwatch();

  void play() => _sw.start();

  void pause() {
    _baseMs += _sw.elapsedMilliseconds;
    _sw
      ..stop()
      ..reset();
  }

  @override
  Duration get position =>
      Duration(milliseconds: _baseMs + _sw.elapsedMilliseconds);

  @override
  Duration get duration => const Duration(minutes: 4);
}

const List<String> _kVerses = <String>[
  '夜空に咲いた花火',
  '君の声が聞こえる',
  'hello summer night',
  '揺れる光の中で',
  '忘れないでいて',
  'また会おうね',
  '遠い街の灯り',
  '風が運ぶ歌声',
];

/// 80 行逐字歌词，每行约 3 秒，四句一组反复（副歌启发式能找到重复句）。
LyricTimeline _song() {
  final List<LyricLine> lines = <LyricLine>[];
  int t = 2000;
  for (int i = 0; i < 80; i++) {
    final String text = _kVerses[(i % 4) + (i ~/ 8 % 2) * 4];
    final List<String> chars = text.split('');
    final int per = (2400 / chars.length).round();
    final List<LyricSyllable> syl = <LyricSyllable>[
      for (int c = 0; c < chars.length; c++)
        LyricSyllable(
          text: chars[c],
          startMs: t + c * per,
          endMs: t + (c + 1) * per,
        ),
    ];
    lines.add(
      LyricLine(startMs: t, endMs: t + chars.length * per, syllables: syl),
    );
    t += 3000;
  }
  return LyricTimeline(
    format: 'ttml',
    timingQuality: LyricTimingQuality.word,
    lines: lines,
  );
}

class _Scenario {
  const _Scenario(
    this.name,
    this.mode, {
    this.playing = true,
    this.motion = true,
    this.tuning = const <String, Object?>{},
  });

  final String name;
  final LyricVisualizerMode mode;
  final bool playing;
  final bool motion;
  final Map<String, Object?> tuning;
}

const List<_Scenario> _kScenarios = <_Scenario>[
  _Scenario('luminous playing', LyricVisualizerMode.luminous),
  _Scenario('lumiere playing', LyricVisualizerMode.lumiere),
  _Scenario('hanabi playing', LyricVisualizerMode.hanabi),
  _Scenario(
    'hanabi playing bloom=0',
    LyricVisualizerMode.hanabi,
    tuning: <String, Object?>{'bloom': 0.0, 'chorusBloom': 0.0},
  ),
  _Scenario('hanabi paused', LyricVisualizerMode.hanabi, playing: false),
  _Scenario(
    'hanabi paused motion-off',
    LyricVisualizerMode.hanabi,
    playing: false,
    motion: false,
  ),
];

/// 本进程 3D 引擎占用（逐秒采样、所有实例相加后求平均）；拿不到时返回 null。
Future<double?> _gpu3dPercent(int seconds) async {
  final String path =
      '\\GPU Engine(pid_${pid}_*engtype_3D)\\Utilization Percentage';
  final String script =
      "\$s = Get-Counter '$path' -SampleInterval 1 -MaxSamples $seconds; "
      r'$s | ForEach-Object { ($_.CounterSamples | Measure-Object CookedValue -Sum).Sum }';
  try {
    final ProcessResult r = await Process.run('powershell', <String>[
      '-NoProfile',
      '-Command',
      script,
    ]);
    final List<double> v = <double>[
      for (final String l in (r.stdout as String).split(RegExp(r'\s+')))
        ?double.tryParse(l.trim()),
    ];
    if (v.isEmpty) return null;
    return v.reduce((double a, double b) => a + b) / v.length;
  } on Object {
    return null;
  }
}

double _pct(List<double> sorted, double q) {
  if (sorted.isEmpty) return 0;
  final int i = ((sorted.length - 1) * q).round();
  return sorted[i];
}

Future<void> _measure(
  WidgetTester tester,
  _Scenario s,
  LyricTimeline timeline,
) async {
  final _WallClock clock = _WallClock(25000);
  if (s.playing) clock.play();
  final LyricVisualizerEntry entry = lyricVisualizerEntryOf(s.mode);
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: Brightness.dark,
  );
  final LyricVisualizerContext c = LyricVisualizerContext(
    timeline: timeline,
    runtime: LyricVisualizerRuntime(timeline),
    clock: clock,
    offsetMs: 0,
    playing: s.playing,
    palette: LyricVisualizerPalette.fromScheme(scheme),
    tuning: LyricVisualizerTuning(entry.tunings, s.tuning),
    seed: lyricVisualizerSeedOf('perf-track'),
    motion: s.motion,
    title: 'Perf title',
    artist: 'Perf artist',
    album: 'Perf album',
  );
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: SizedBox.expand(
          child: RepaintBoundary(
            key: ValueKey<String>(s.name),
            child: entry.builder(c),
          ),
        ),
      ),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: _kWarmupMs));

  final List<FrameTiming> timings = <FrameTiming>[];
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  SchedulerBinding.instance.addTimingsCallback(collect);
  final Future<double?> gpu = _gpu3dPercent(_kWindowMs ~/ 1000 - 1);
  await Future<void>.delayed(const Duration(milliseconds: _kWindowMs));
  final double? gpuPct = await gpu;
  await Future<void>.delayed(const Duration(milliseconds: 300));
  SchedulerBinding.instance.removeTimingsCallback(collect);

  List<double> ms(Duration Function(FrameTiming) pick) =>
      timings.map((FrameTiming t) => pick(t).inMicroseconds / 1000).toList()
        ..sort();
  final List<double> build = ms((FrameTiming t) => t.buildDuration);
  final List<double> raster = ms((FrameTiming t) => t.rasterDuration);
  final double fps = timings.length / (_kWindowMs / 1000);
  _log(
    '${s.name.padRight(26)} frames=${timings.length.toString().padLeft(4)} '
    '(${fps.toStringAsFixed(1)}/s) '
    'build p50=${_pct(build, 0.5).toStringAsFixed(2)} '
    'p90=${_pct(build, 0.9).toStringAsFixed(2)} ms  '
    'raster p50=${_pct(raster, 0.5).toStringAsFixed(2)} '
    'p90=${_pct(raster, 0.9).toStringAsFixed(2)} '
    'max=${raster.isEmpty ? 0 : raster.last.toStringAsFixed(2)} ms  '
    'gpu3d=${gpuPct == null ? 'n/a' : '${gpuPct.toStringAsFixed(1)}%'}',
  );
  _log('    rss=${(ProcessInfo.currentRss / 1048576).toStringAsFixed(0)}MB');
  runApp(const SizedBox.shrink());
  await Future<void>.delayed(const Duration(milliseconds: 500));
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hanabi gpu cost vs baselines', (WidgetTester tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    await windowManager.ensureInitialized();
    final double dpr = tester.view.devicePixelRatio;
    await windowManager.setSize(Size(2000 / dpr, 1125 / dpr));
    await Future<void>.delayed(const Duration(milliseconds: 800));
    _log(
      '--- ${DateTime.now().toIso8601String()} '
      'size=${tester.view.physicalSize.width.toStringAsFixed(0)}x'
      '${tester.view.physicalSize.height.toStringAsFixed(0)} dpr=$dpr '
      'refresh=${tester.view.display.refreshRate.toStringAsFixed(1)}Hz '
      'window=${_kWindowMs}ms',
    );
    final LyricTimeline timeline = _song();
    final String only = Platform.environment['HANABI_PERF_ONLY'] ?? '';
    for (final _Scenario s in _kScenarios) {
      if (only.isNotEmpty && !s.name.contains(only)) continue;
      await _measure(tester, s, timeline);
    }
  });
}
