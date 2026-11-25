import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/modes/claddagh/claddagh_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

import 'visualizer_test_helpers.dart';

LyricVisualizerContext _ctx({LyricVisualizerAudio? audio, int offsetMs = 0}) =>
    visualizerContextFor(
      claddaghVisualizerEntry,
      clock: FakeVisualizerClock(),
      audio: audio,
      offsetMs: offsetMs,
    );

void main() {
  group('folia resolveBeatFxAccentGain', () {
    test('rhythmic gate, weak-beat floor and track scale', () {
      expect(
        lyricVisualizerBeatAccentGain(
          impact: 1,
          rhythmic: false,
          trackScale: 1,
        ),
        0,
      );
      expect(
        lyricVisualizerBeatAccentGain(
          impact: null,
          rhythmic: true,
          trackScale: 0.6,
        ),
        0.6,
      );
      expect(
        lyricVisualizerBeatAccentGain(
          impact: 0,
          rhythmic: true,
          trackScale: 0.8,
        ),
        closeTo(0.35 * 0.8, 1e-12),
      );
      expect(
        lyricVisualizerBeatAccentGain(
          impact: 0.5,
          rhythmic: true,
          trackScale: 1,
        ),
        closeTo(0.35 + 0.65 * 0.5, 1e-12),
      );
    });
  });

  group('folia mergeBeatFxEvents', () {
    test('drops non-pulse beats, marks downbeats, counts bar position', () {
      final List<LyricVisualizerBeatEvent> e = lyricVisualizerMergeBeatEvents(
        beats: const <LyricVisualizerBeat>[
          LyricVisualizerBeat(timeMs: 0, downbeat: true, impact: 1),
          LyricVisualizerBeat(
            timeMs: 250,
            downbeat: false,
            impact: 0.2,
            pulse: false,
          ),
          LyricVisualizerBeat(
            timeMs: 500,
            downbeat: false,
            impact: 0.5,
            rhythmic: false,
          ),
          LyricVisualizerBeat(
            timeMs: 1000,
            downbeat: true,
            impact: 0,
            lowShare: 0.8,
            midShare: 0.1,
            highShare: 0.1,
          ),
        ],
        downbeatTimesMs: const <int>[0, 1000, 1700],
        trackScale: 0.5,
        offsetMs: 100,
      );
      expect(e.map((LyricVisualizerBeatEvent x) => x.audioMs), <int>[
        0,
        500,
        1000,
        1700,
      ]);
      expect(e.map((LyricVisualizerBeatEvent x) => x.displayMs), <int>[
        100,
        600,
        1100,
        1800,
      ]);
      expect(e.map((LyricVisualizerBeatEvent x) => x.downbeat), <bool>[
        true,
        false,
        true,
        true,
      ]);
      expect(e.map((LyricVisualizerBeatEvent x) => x.barPos), <int?>[
        0,
        1,
        0,
        0,
      ]);
      expect(e[0].gain, closeTo(0.5, 1e-12));
      expect(e[1].gain, 0); // 没有节奏的小节。
      expect(e[2].gain, closeTo(0.35 * 0.5, 1e-12));
      expect(e[2].lowShare, 0.8);
      // 孤立强拍：没有重音，增益 = trackScale。
      expect(e[3].impact, isNull);
      expect(e[3].gain, 0.5);
      expect(e.map((LyricVisualizerBeatEvent x) => x.ordinal), <int>[
        0,
        1,
        2,
        3,
      ]);
    });

    test('without accents every beat stays and gains the track scale', () {
      final List<LyricVisualizerBeatEvent> e = lyricVisualizerMergeBeatEvents(
        beats: const <LyricVisualizerBeat>[
          LyricVisualizerBeat(timeMs: 0, downbeat: true),
          LyricVisualizerBeat(timeMs: 500, downbeat: false),
        ],
        downbeatTimesMs: const <int>[0],
        trackScale: 1,
      );
      expect(e, hasLength(2));
      expect(e.every((LyricVisualizerBeatEvent x) => x.gain == 1), isTrue);
      expect(e.every((LyricVisualizerBeatEvent x) => x.barPos == null), isTrue);
    });
  });

  group('LyricVisualizerBeats', () {
    test('window queries, envelopes and rotation follow the folia clock', () {
      final SyntheticVisualizerAudio audio = SyntheticVisualizerAudio();
      final LyricVisualizerBeats b = LyricVisualizerBeats.of(
        _ctx(audio: audio, offsetMs: 40),
      );
      expect(b.hasBeats, isTrue);
      expect(b.fromLyrics, isFalse);
      // 拍 0 在显示 40 ms，强拍，impact 1 × trackScale 0.8。
      expect(b.events.first.displayMs, 40);
      expect(b.beatImpactAt(40), closeTo(0.8, 1e-9));
      expect(b.beatImpactAt(40 + 160), closeTo(0.8 * math.exp(-2.3), 1e-9));
      // 拍 1（540 ms）弱拍：(0.35 + 0.65 × 0.4) × 0.8。
      expect(b.beatImpactAt(540), closeTo((0.35 + 0.26) * 0.8, 1e-9));
      expect(b.downbeatImpactAt(540), lessThan(0.01));
      expect(b.downbeatImpactAt(2040), closeTo(0.8, 1e-9));
      // (40, 1040]：拍 1、拍 2。
      expect(
        b
            .beatsBetween(40, 1040)
            .map((LyricVisualizerBeatEvent e) => e.displayMs),
        <int>[540, 1040],
      );
      expect(b.beatsBetween(1040, 1040), isEmpty);
      expect(b.rotationSignAt(0), 1);
      expect(b.rotationSignAt(40), -1);
      expect(b.rotationSignAt(540), 1);
      // 鼓击按种类过滤。
      final List<LyricVisualizerDrumHitEvent> hits = b.drumHitsBetween(0, 1100);
      expect(
        hits.map((LyricVisualizerDrumHitEvent h) => h.kind),
        <LyricVisualizerDrumKind>[
          LyricVisualizerDrumKind.kick,
          LyricVisualizerDrumKind.hat,
          LyricVisualizerDrumKind.snare,
          LyricVisualizerDrumKind.hat,
          LyricVisualizerDrumKind.kick,
        ],
      );
      expect(
        b
            .drumHitsBetween(
              0,
              1100,
              kinds: <LyricVisualizerDrumKind>{LyricVisualizerDrumKind.snare},
            )
            .single
            .displayMs,
        540,
      );
      expect(
        b.drumImpactAt(
          540 + 100,
          kinds: <LyricVisualizerDrumKind>{LyricVisualizerDrumKind.kick},
        ),
        closeTo(math.exp(-600 / 150), 1e-9),
      );
      expect(b.vocalOnsetsMs.first, 290);
    });

    test('is cached per audio and offset', () {
      final SyntheticVisualizerAudio audio = SyntheticVisualizerAudio();
      final LyricVisualizerContext c = _ctx(audio: audio);
      expect(
        identical(LyricVisualizerBeats.of(c), LyricVisualizerBeats.of(c)),
        isTrue,
      );
      final LyricVisualizerBeats shifted = LyricVisualizerBeats.of(
        c.copyWith(offsetMs: 500),
      );
      expect(shifted.events.first.displayMs, 500);
    });

    test(
      'without beats: no events, envelopes fall back to the lyric pulse',
      () {
        final LyricVisualizerContext c = _ctx();
        final LyricVisualizerBeats b = LyricVisualizerBeats.of(c);
        expect(b.hasBeats, isFalse);
        expect(b.fromLyrics, isTrue);
        expect(b.beatsBetween(0, 100000), isEmpty);
        expect(b.drumImpactAt(5000), 0);
        final LyricVisualizerRuntime r = c.runtime;
        final int start = r.lines.first.startMs;
        expect(b.beatImpactAt(start), r.pulseAt(start, decayMs: 180));
        expect(b.downbeatImpactAt(start), closeTo(1, 1e-9));
        // 节拍网格还没就绪的音频同样回落。
        final LyricVisualizerBeats notReady = LyricVisualizerBeats.of(
          _ctx(audio: SyntheticVisualizerAudio(beatsReady: false)),
        );
        expect(notReady.hasBeats, isFalse);
      },
    );
  });

  test('frame lowMid / upperMid default to the merged mid', () {
    const LyricVisualizerAudioFrame f = LyricVisualizerAudioFrame(
      power: 0,
      low: 0,
      mid: 0.4,
      high: 0,
      vocal: 0,
      onset: 0,
      beatImpact: 0,
      downbeatImpact: 0,
      drumImpact: 0,
    );
    expect(f.lowMid, 0.4);
    expect(f.upperMid, 0.4);
    const LyricVisualizerAudioFrame g = LyricVisualizerAudioFrame(
      power: 0,
      low: 0,
      mid: 0.4,
      lowMid: 0.7,
      upperMid: 0.1,
      high: 0,
      vocal: 0,
      onset: 0,
      beatImpact: 0,
      downbeatImpact: 0,
      drumImpact: 0,
    );
    expect(g.lowMid, 0.7);
    expect(g.upperMid, 0.1);
    expect(g == f, isFalse);
  });
}
