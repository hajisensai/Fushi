import 'dart:developer' show Timeline;
import 'dart:math' as math;
import 'dart:ui' show FramePhase, FrameTiming;

import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_line_layout.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_lyrics_view.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_progress.dart';
import 'package:fushi/src/utils/components/fushi_m3e_player.dart'
    show FushiPlaybackClock;
import 'package:fushi_music/fushi_music.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

/// 逐字歌词 [KaraokeLyricsView] 帧时间探针（设计 §6.1 / §13 P1 退出标准：120 Hz 不掉帧）。
///
/// 不起整个 app：直接 `runApp` 一个只装歌词视图的 MaterialApp，喂一份字级时间轴
/// （40 组行、每行 10–14 音节、每音节 150–300 ms，含和声行与 >1 s 长音），用按
/// [Stopwatch] 走的 [FushiPlaybackClock] 播放，每个场景跑 [_kScenarioSeconds] 秒（覆盖
/// 多次换行弹簧滚动），帧时间取引擎 [FrameTiming]，结果以 `[karaoke-perf]` 前缀打进日志。
///
/// 跑法（profile 才可信；`FUSHI_TEST_HIDDEN=1` 让窗口停在屏外、不抢前台）：
///   FUSHI_TEST_HIDDEN=1 flutter drive --profile -d windows --no-pub
///     --driver=test_driver/integration_test.dart
///     --target=integration_test/karaoke_lyrics_perf_itest.dart
///
/// 判定：屏外窗口的 vsync 不一定是真实刷新率，所以逐帧以「build 与 raster 各自是否
/// 超过 8.33 ms（120 Hz 帧预算）」判掉帧，同时打出 `display.refreshRate` 与实际帧数。
void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('karaoke lyrics view frame timing', (WidgetTester tester) async {
    binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;
    final LyricTimeline timeline = _buildTimeline();
    final int syllables = timeline.lines.fold(
      0,
      (int n, LyricLine l) => n + l.syllables.length,
    );
    final int bgLines = timeline.lines.where((LyricLine l) {
      return l.isBackground;
    }).length;
    final int longNotes = timeline.lines.fold(
      0,
      (int n, LyricLine l) =>
          n +
          l.syllables.where((LyricSyllable s) => s.durationMs > 1000).length,
    );
    final double refresh = tester.view.display.refreshRate;
    debugPrint(
      '[karaoke-perf] refresh=${refresh.toStringAsFixed(1)}Hz '
      'size=${tester.view.physicalSize.width.toStringAsFixed(0)}x'
      '${tester.view.physicalSize.height.toStringAsFixed(0)} '
      'dpr=${tester.view.devicePixelRatio} '
      'lines=${timeline.lines.length} bg=$bgLines syllables=$syllables '
      'long=$longNotes budget=${_kBudgetMs.toStringAsFixed(2)}ms',
    );

    final List<int> rowStarts = <int>[
      for (final KaraokeRowSpan r in karaokeRows(timeline))
        timeline.lines[r.main].startMs,
    ];
    for (final _Scenario s in _scenarios) {
      final _StopwatchClock clock = _StopwatchClock();
      await tester.pumpWidget(
        _Harness(
          key: ValueKey<String>(s.label),
          timeline: timeline,
          clock: clock,
          appearance: s.appearance,
        ),
      );
      // 首帧排版 + 字体回退加载，不计入。
      await _wait(1500);
      final int layoutsBefore = KaraokeLineLayout.debugLayoutCount;
      Future<void> run() => _measure(
        s.label,
        s.appearance == null ? const <int>[] : rowStarts,
        () async {
          clock.restart();
          await _wait(_kScenarioSeconds * 1000);
        },
      );
      if (_kTrace && s.appearance != null) {
        // 定位超预算帧用：引擎 raster 线程事件进 build/integration_response_data.json。
        await binding.traceAction(
          run,
          streams: const <String>['Embedder', 'Dart'],
          reportKey: 'timeline:${s.label}',
        );
      } else {
        await run();
      }
      debugPrint(
        '[karaoke-perf] ${s.label} relayouts-during-run='
        '${KaraokeLineLayout.debugLayoutCount - layoutsBefore}',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
    debugPrint('[karaoke-perf] done');
  });
}

const int _kScenarioSeconds = 25;

/// `--dart-define=KARAOKE_TRACE=true`：给歌词场景录 VM timeline（只为定位，平时关）。
const bool _kTrace = bool.fromEnvironment('KARAOKE_TRACE');
const double _kBudgetMs = 1000 / 120;

class _Scenario {
  const _Scenario(this.label, this.appearance);
  final String label;

  /// null = 对照组（只有一条不定进度条在动），量本机负载下的噪声底。
  final KaraokeLyricsAppearance? appearance;
}

const List<_Scenario> _scenarios = <_Scenario>[
  _Scenario('control(progress-bar)', null),
  _Scenario(
    'default(blur+glow)',
    KaraokeLyricsAppearance(activeColor: Color(0xFFFFFFFF)),
  ),
  _Scenario(
    'noBlur',
    KaraokeLyricsAppearance(
      activeColor: Color(0xFFFFFFFF),
      blurInactive: false,
    ),
  ),
];

/// 按 [Stopwatch] 走的播放时钟（模拟已插值的播放位置）。
class _StopwatchClock implements FushiPlaybackClock {
  final Stopwatch _sw = Stopwatch();

  void restart() {
    _sw
      ..reset()
      ..start();
  }

  @override
  Duration get position => _sw.elapsed;

  @override
  Duration get duration => const Duration(minutes: 4);
}

class _Harness extends StatelessWidget {
  const _Harness({
    super.key,
    required this.timeline,
    required this.clock,
    required this.appearance,
  });

  final LyricTimeline timeline;
  final FushiPlaybackClock clock;
  final KaraokeLyricsAppearance? appearance;

  @override
  Widget build(BuildContext context) {
    final KaraokeLyricsAppearance? a = appearance;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: const Color(0xFF15181E),
        body: a == null
            ? const Center(child: LinearProgressIndicator())
            : KaraokeLyricsView(
                timeline: timeline,
                clock: clock,
                playing: true,
                appearance: a,
              ),
      ),
    );
  }
}

const List<(String, String?)> _kana = <(String, String?)>[
  ('夜', 'よ'),
  ('空', 'ぞら'),
  ('に', null),
  ('光', 'ひかり'),
  ('る', null),
  ('星', 'ほし'),
  ('の', null),
  ('声', 'こえ'),
  ('を', null),
  ('聴', 'き'),
  ('い', null),
  ('て', null),
  ('遠', 'とお'),
  ('く', null),
  ('ま', null),
  ('で', null),
  ('歌', 'うた'),
  ('う', null),
  ('よ', null),
  ('君', 'きみ'),
  ('と', null),
  ('明', 'あ'),
  ('日', 'す'),
  ('へ', null),
];

/// 40 组行（主行 + 每 5 行一条和声行），每行 10–14 音节、每音节 150–300 ms，
/// 每行最后一个音节有一定概率是 >1 s 的长音（触发呼吸）。
LyricTimeline _buildTimeline() {
  final math.Random rnd = math.Random(20261024);
  final List<LyricLine> lines = <LyricLine>[];
  int t = 800;
  for (int row = 0; row < 40; row++) {
    final int count = 10 + rnd.nextInt(5);
    final List<LyricSyllable> syl = <LyricSyllable>[];
    int at = t;
    for (int k = 0; k < count; k++) {
      final (String text, String? ruby) = _kana[rnd.nextInt(_kana.length)];
      final bool long = k == count - 1 && rnd.nextInt(3) == 0;
      final int dur = long ? 1200 + rnd.nextInt(600) : 150 + rnd.nextInt(151);
      syl.add(
        LyricSyllable(
          text: text,
          startMs: at,
          endMs: at + dur,
          fill: k % 7 == 6 ? LyricFill.outline : LyricFill.sweep,
          ruby: ruby,
        ),
      );
      at += dur;
    }
    lines.add(
      LyricLine(
        startMs: t,
        endMs: at,
        syllables: syl,
        agent: row.isEven ? 0 : 1,
        translations: <LyricTranslation>[
          LyricTranslation('en', 'Hearing the voice of stars in row $row'),
        ],
        romanization: 'yozora ni hikaru hoshi no koe wo kiite $row',
      ),
    );
    if (row % 5 == 2) {
      final List<LyricSyllable> bg = <LyricSyllable>[];
      int b = t + 300;
      for (int k = 0; k < 6; k++) {
        final int dur = 200 + rnd.nextInt(100);
        bg.add(LyricSyllable(text: 'ああ', startMs: b, endMs: b + dur));
        b += dur;
      }
      lines.add(
        LyricLine(
          startMs: t + 300,
          endMs: b,
          syllables: bg,
          agent: row.isEven ? 0 : 1,
          role: LyricRole.background,
        ),
      );
    }
    t = at + 200;
  }
  return LyricTimeline(
    format: 'ttml',
    timingQuality: LyricTimingQuality.syllable,
    agents: const <LyricAgent>[
      LyricAgent(id: 'v1'),
      LyricAgent(id: 'v2'),
    ],
    lines: lines,
  );
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

/// [rowStarts]：各行组起点（毫秒，相对时钟起点），用来判超预算帧是否落在换行时刻。
Future<void> _measure(
  String label,
  List<int> rowStarts,
  Future<void> Function() body,
) async {
  final List<FrameTiming> timings = <FrameTiming>[];
  final List<int> paintsPerFrame = <int>[];
  int lastPaints = karaokeDebugRowPaintCount;
  void collect(List<FrameTiming> batch) => timings.addAll(batch);
  void onFrame(Duration _) {
    paintsPerFrame.add(karaokeDebugRowPaintCount - lastPaints);
    lastPaints = karaokeDebugRowPaintCount;
  }

  bool sampling = true;
  void schedule() {
    SchedulerBinding.instance.addPostFrameCallback((Duration d) {
      if (!sampling) return;
      onFrame(d);
      schedule();
    });
  }

  SchedulerBinding.instance.addTimingsCallback(collect);
  final int t0 = Timeline.now;
  final Stopwatch wall = Stopwatch()..start();
  schedule();
  await body();
  sampling = false;
  wall.stop();
  // FrameTiming 批量回报有延迟，留时间把最后一批收齐。
  await _wait(1200);
  SchedulerBinding.instance.removeTimingsCallback(collect);
  if (timings.isEmpty) {
    debugPrint('[karaoke-perf] $label frames=0');
    return;
  }
  List<double> ms(Duration Function(FrameTiming) pick) =>
      timings.map((FrameTiming t) => pick(t).inMicroseconds / 1000).toList()
        ..sort();
  double pct(List<double> v, double p) =>
      v[((v.length - 1) * p).round().clamp(0, v.length - 1)];
  final List<double> build = ms((FrameTiming t) => t.buildDuration);
  final List<double> raster = ms((FrameTiming t) => t.rasterDuration);
  final int overBuild = build.where((double v) => v > _kBudgetMs).length;
  final int overRaster = raster.where((double v) => v > _kBudgetMs).length;
  final int overAny = timings.where((FrameTiming t) {
    return t.buildDuration.inMicroseconds / 1000 > _kBudgetMs ||
        t.rasterDuration.inMicroseconds / 1000 > _kBudgetMs;
  }).length;
  final List<int> paints = paintsPerFrame.toList()..sort();
  String f(double v) => v.toStringAsFixed(2);
  // 超预算帧逐条列出：相对起点的时刻、build / raster、离最近一次换行多远。
  for (final FrameTiming t in timings) {
    final double b = t.buildDuration.inMicroseconds / 1000;
    final double r = t.rasterDuration.inMicroseconds / 1000;
    if (b <= _kBudgetMs && r <= _kBudgetMs) continue;
    final double at =
        (t.timestampInMicroseconds(FramePhase.buildStart) - t0) / 1000;
    int? nearest;
    for (final int rs in rowStarts) {
      final int d = (at - rs).round();
      if (nearest == null || d.abs() < nearest.abs()) nearest = d;
    }
    debugPrint(
      '[karaoke-perf] $label slow-frame at=${at.toStringAsFixed(0)}ms '
      'build=${f(b)} raster=${f(r)} '
      'fromRowSwitch=${nearest == null ? '-' : '${nearest}ms'}',
    );
  }
  String stats(List<double> v) =>
      'p50=${f(pct(v, .5))} p90=${f(pct(v, .9))} '
      'p99=${f(pct(v, .99))} max=${f(v.last)}';
  final double fps = timings.length * 1000 / wall.elapsedMilliseconds;
  debugPrint(
    '[karaoke-perf] $label frames=${timings.length} '
    'wall=${wall.elapsedMilliseconds}ms fps=${fps.toStringAsFixed(1)} '
    '| build ${stats(build)} | raster ${stats(raster)} '
    '| overBuild=$overBuild overRaster=$overRaster '
    'overAny=$overAny/${timings.length} '
    '(${(overAny * 100 / timings.length).toStringAsFixed(2)}%) '
    '| rowPaints/frame p50=${paints[paints.length ~/ 2]} '
    'max=${paints.last} total=${paints.fold(0, (int a, int b) => a + b)}',
  );
  if (rowStarts.isEmpty) return;
  // 换行窗口（起点后 400 ms：重建 + 弹簧滚动 + 透明度过渡）与其余帧分开统计。
  final List<double> switchPeaks = <double>[];
  final List<double> steady = <double>[];
  final Map<int, double> peakBySwitch = <int, double>{};
  for (final FrameTiming t in timings) {
    final double at =
        (t.timestampInMicroseconds(FramePhase.buildStart) - t0) / 1000;
    final double r = t.rasterDuration.inMicroseconds / 1000;
    int? hit;
    for (final int rs in rowStarts) {
      if (at >= rs - 5 && at < rs + 400) hit = rs;
    }
    if (hit == null) {
      steady.add(r);
    } else {
      peakBySwitch[hit] = math.max(peakBySwitch[hit] ?? 0, r);
    }
  }
  switchPeaks
    ..addAll(peakBySwitch.values)
    ..sort();
  steady.sort();
  if (switchPeaks.isEmpty || steady.isEmpty) return;
  debugPrint(
    '[karaoke-perf] $label switches=${switchPeaks.length} '
    'peakRaster p50=${f(pct(switchPeaks, .5))} max=${f(switchPeaks.last)} '
    'over=${switchPeaks.where((double v) => v > _kBudgetMs).length} '
    '| steady raster p99=${f(pct(steady, .99))} max=${f(steady.last)} '
    'over=${steady.where((double v) => v > _kBudgetMs).length}/${steady.length} '
    '| peaks=${peakBySwitch.values.map(f).join(',')}',
  );
}
