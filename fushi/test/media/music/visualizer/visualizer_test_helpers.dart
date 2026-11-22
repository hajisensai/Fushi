/// 全屏歌词动画测试的共享素材：样例时间轴、可拨的假时钟、挂载一个样式的 harness。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:material_ui/material_ui.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

/// 合成的音频分析（120 BPM、每 4 拍一个强拍、响度按拍起伏）：给样式测试「有音频」分支用。
class SyntheticVisualizerAudio implements LyricVisualizerAudio {
  SyntheticVisualizerAudio({this.envelopeReady = true, this.beatsReady = true});

  @override
  final bool envelopeReady;

  @override
  final bool beatsReady;

  @override
  final List<int> beatTimesMs = <int>[for (int t = 0; t < 240000; t += 500) t];

  @override
  late final List<int> downbeatTimesMs = <int>[
    for (int i = 0; i < beatTimesMs.length; i += 4) beatTimesMs[i],
  ];

  @override
  double? get bpm => 120;

  @override
  LyricVisualizerAudioFrame frameAt(int audioMs) {
    final double beat = lyricVisualizerImpactAt(beatTimesMs, audioMs);
    final double down = lyricVisualizerImpactAt(downbeatTimesMs, audioMs);
    return LyricVisualizerAudioFrame(
      power: 0.3 + 0.6 * beat,
      low: beat,
      mid: 0.5,
      high: 0.2 + 0.3 * beat,
      vocal: 0.4,
      onset: beat,
      beatImpact: beat,
      downbeatImpact: down,
      drumImpact: beat,
      bpm: 120,
      envelopeReady: envelopeReady,
      beatsReady: beatsReady,
      drumsReady: true,
      vocalReady: true,
    );
  }
}

/// 手动拨的时钟。
class FakeVisualizerClock implements LyricVisualizerClock {
  FakeVisualizerClock([this.positionMs = 0]);

  int positionMs;

  @override
  Duration get position => Duration(milliseconds: positionMs);

  @override
  Duration get duration => const Duration(minutes: 4);
}

LyricLine _wordLine(
  int start,
  List<(String, int)> parts, {
  String? translation,
  int? agent,
  LyricRole role = LyricRole.main,
}) {
  final List<LyricSyllable> syl = <LyricSyllable>[];
  int t = start;
  for (final (String text, int d) in parts) {
    syl.add(LyricSyllable(text: text, startMs: t, endMs: t + d));
    t += d;
  }
  return LyricLine(
    startMs: start,
    endMs: t,
    syllables: syl,
    agent: agent,
    role: role,
    translations: translation == null
        ? const <LyricTranslation>[]
        : <LyricTranslation>[LyricTranslation('zh', translation)],
  );
}

/// 逐字时间轴：日文 / 英文混排、带译文、两位演唱者、一行和声、一段长间奏、一个长音。
LyricTimeline sampleWordTimeline() => LyricTimeline(
  format: 'ttml',
  timingQuality: LyricTimingQuality.word,
  agents: const <LyricAgent>[
    LyricAgent(id: 'v1', name: 'A', kind: LyricAgentKind.person),
    LyricAgent(id: 'v2', name: 'B', kind: LyricAgentKind.person),
  ],
  lines: <LyricLine>[
    _wordLine(
      1000,
      <(String, int)>[('夜', 300), ('空', 300), ('に', 200), ('光', 1400)],
      translation: '夜空中的光',
      agent: 0,
    ),
    _wordLine(
      3400,
      <(String, int)>[('Hello ', 400), ('bright ', 400), ('world', 600)],
      translation: '你好，明亮的世界',
      agent: 1,
    ),
    _wordLine(4900, <(String, int)>[
      ('(ah', 300),
      (' ah)', 300),
    ], role: LyricRole.background),
    // 长间奏后
    _wordLine(12000, <(String, int)>[
      ('ま', 250),
      ('た', 250),
      ('会', 300),
      ('お', 250),
      ('う', 900),
    ], agent: 0),
  ],
);

/// 行级时间轴（LRC）。
LyricTimeline sampleLineTimeline() => const LyricTimeline(
  format: 'lrc',
  lines: <LyricLine>[
    LyricLine(
      startMs: 500,
      endMs: 3000,
      syllables: <LyricSyllable>[
        LyricSyllable(text: '一行级歌词测试', startMs: 500, endMs: 3000),
      ],
    ),
    LyricLine(
      startMs: 3000,
      endMs: 6000,
      syllables: <LyricSyllable>[
        LyricSyllable(
          text: 'A line level lyric that is rather long to force wrapping',
          startMs: 3000,
          endMs: 6000,
        ),
      ],
    ),
  ],
);

/// 造一个样式输入。
LyricVisualizerContext visualizerContextFor(
  LyricVisualizerEntry entry, {
  required FakeVisualizerClock clock,
  LyricTimeline? timeline,
  bool motion = true,
  bool playing = true,
  Map<String, Object?> tuning = const <String, Object?>{},
  double fontScale = 1,
  LyricVisualizerIntensity intensity = LyricVisualizerIntensity.normal,
  LyricVisualizerTheme? theme,
  LyricVisualizerAudio? audio,
  int offsetMs = 0,
}) {
  final LyricTimeline t = timeline ?? sampleWordTimeline();
  final ColorScheme scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6750A4),
    brightness: Brightness.dark,
  );
  return LyricVisualizerContext(
    timeline: t,
    runtime: LyricVisualizerRuntime(t),
    clock: clock,
    offsetMs: offsetMs,
    playing: playing,
    palette: LyricVisualizerPalette.fromScheme(
      scheme,
    ).applyOverride(theme?.palette),
    tuning: LyricVisualizerTuning(entry.tunings, tuning),
    seed: lyricVisualizerSeedOf('test-track'),
    motion: motion,
    title: 'Test title',
    artist: 'Test artist',
    album: 'Test album',
    fontScale: fontScale,
    intensity: theme?.intensity ?? intensity,
    theme: theme,
    audio: audio,
  );
}

/// 挂载 [entry] 并在 [timesMs] 各时间点逐一拨钟、推帧，断言不抛异常。
Future<void> pumpVisualizerAcross(
  WidgetTester tester,
  LyricVisualizerEntry entry, {
  LyricTimeline? timeline,
  bool motion = true,
  bool playing = true,
  Size size = const Size(1280, 720),
  List<int> timesMs = const <int>[
    0,
    1100,
    1900,
    2900,
    3600,
    5000,
    8000,
    12300,
    14500,
    30000,
  ],
  Map<String, Object?> tuning = const <String, Object?>{},
  double fontScale = 1,
  LyricVisualizerIntensity intensity = LyricVisualizerIntensity.normal,
  LyricVisualizerTheme? theme,
  LyricVisualizerAudio? audio,
  int offsetMs = 0,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final FakeVisualizerClock clock = FakeVisualizerClock();
  final LyricVisualizerContext c = visualizerContextFor(
    entry,
    clock: clock,
    timeline: timeline,
    motion: motion,
    playing: playing,
    tuning: tuning,
    fontScale: fontScale,
    intensity: intensity,
    theme: theme,
    audio: audio,
    offsetMs: offsetMs,
  );
  await tester.pumpWidget(
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(size: size, disableAnimations: !motion),
        child: Scaffold(
          backgroundColor: Colors.black,
          body: SizedBox.expand(child: entry.builder(c)),
        ),
      ),
    ),
  );
  for (final int t in timesMs) {
    clock.positionMs = t;
    await tester.pump(const Duration(milliseconds: 16));
    await tester.pump(const Duration(milliseconds: 200));
    expect(tester.takeException(), isNull, reason: '${entry.mode} @ ${t}ms');
  }
  // 卸载：Ticker / 动画控制器都要释放干净。
  await tester.pumpWidget(const SizedBox.shrink());
  expect(tester.takeException(), isNull);
}
