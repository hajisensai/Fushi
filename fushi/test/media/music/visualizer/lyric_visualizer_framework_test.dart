import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_music/fushi_music.dart';

import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_registry.dart';
import 'package:fushi/src/media/music/lyrics/visualizer/lyric_visualizer_runtime.dart';

import 'visualizer_test_helpers.dart';

void main() {
  group('LyricVisualizerRuntime', () {
    final LyricVisualizerRuntime rt = LyricVisualizerRuntime(
      sampleWordTimeline(),
    );

    test('和声行并入前一主行', () {
      expect(rt.lines, hasLength(3));
      expect(rt.lines[1].backgroundLines, hasLength(1));
      // 和声行并进去后，列表位置与原始时间轴下标不同。
      expect(rt.lines[2].timelineIndex, 3);
      expect(rt.lines[2].position, 2);
    });

    test('position 就是 runtime.lines 里的位置（时间轴有和声行 / 空行时也是）', () {
      final LyricVisualizerRuntime withGaps = LyricVisualizerRuntime(
        LyricTimeline(
          format: 'lrc',
          lines: <LyricLine>[
            const LyricLine(
              startMs: 0,
              endMs: 500,
              syllables: <LyricSyllable>[],
            ),
            ...sampleWordTimeline().lines,
          ],
        ),
      );
      for (int i = 0; i < withGaps.lines.length; i++) {
        final LyricVisualizerLine l = withGaps.lines[i];
        expect(l.position, i);
        expect(identical(withGaps.lines[l.position], l), isTrue);
      }
      // 空行 + 和声行：最后一行在时间轴里是 4，在列表里是 2；拿时间轴下标索引列表会越界。
      expect(withGaps.lines.last.timelineIndex, 4);
      expect(withGaps.lines.last.position, 2);
      expect(
        withGaps.lines.last.timelineIndex,
        greaterThanOrEqualTo(withGaps.lines.length),
      );
      expect(withGaps.upcomingLineAt(8000)?.position, 2);
    });

    test('当前行 / 间奏 / 上一句 / 下一句', () {
      expect(rt.activeLineAt(500), -1);
      expect(rt.lastStartedLineAt(500), -1);
      expect(rt.upcomingLineAt(500)?.position, 0);
      expect(rt.activeLineAt(1500), 0);
      // 间奏：没有在唱的行，停在上一句
      expect(rt.activeLineAt(8000), -1);
      expect(rt.lastStartedLineAt(8000), 1);
      expect(rt.recentCompletedLineAt(8000)?.position, 1);
      expect(rt.upcomingLineAt(8000)?.position, 2);
      expect(rt.upcomingLineAt(8000)?.timelineIndex, 3);
      expect(rt.upcomingLinesAt(1500, count: 5), hasLength(2));
    });

    test('逐字时间线：音节内均分，空白不占时长', () {
      final LyricVisualizerLine en = rt.lines[1];
      final List<LyricVisualizerGlyph> hello = en.glyphs.sublist(0, 6);
      expect(hello.map((LyricVisualizerGlyph g) => g.text).join(), 'Hello ');
      expect(hello.first.startMs, 3400);
      expect(hello[4].endMs, 3800);
      expect(hello[5].isSpace, isTrue);
      expect(en.words.map((LyricVisualizerWord w) => w.text), <String>[
        'Hello',
        'bright',
        'world',
      ]);
    });

    test('CJK 每字一词', () {
      expect(rt.lines[0].words.map((LyricVisualizerWord w) => w.text), <String>[
        '夜',
        '空',
        'に',
        '光',
      ]);
      expect(rt.lines[0].words[3].progress(2500), closeTo(0.5, 0.01));
    });

    test('行级歌词按 folia buildTimedWords 加权（CJK 字 1、标点 0、拉丁词 1+0.15×长度）', () {
      final LyricVisualizerRuntime lrc = LyricVisualizerRuntime(
        sampleLineTimeline(),
      );
      // 七个汉字等权：行时长 2500 的 90% 平分，最后一个字在 2750 结束。
      final List<LyricVisualizerGlyph> g = lrc.lines[0].glyphs;
      expect(g.first.startMs, 500);
      expect(g.last.endMs, 2750);
      expect(g[1].startMs, (500 + 2250 / 7).round());
      // 拉丁行：词按长度加权，词内字形均分。
      final LyricVisualizerLine latin = lrc.lines[1];
      final LyricVisualizerWord a = latin.words.first;
      final LyricVisualizerWord wrapping = latin.words.last;
      expect(a.text, 'A');
      expect(wrapping.text, 'wrapping');
      expect(
        wrapping.durationMs / a.durationMs,
        closeTo((1 + 8 * 0.15) / (1 + 1 * 0.15), 0.02),
      );
      expect(latin.words.first.startMs, 3000);
      expect(latin.glyphs.last.endMs, closeTo(3000 + 2700, 1));
      // 空白不占时长。
      expect(
        latin.glyphs
            .where((LyricVisualizerGlyph x) => x.isSpace)
            .every((LyricVisualizerGlyph x) => x.durationMs == 0),
        isTrue,
      );
    });

    test('行级歌词：CJK 标点权重 0、只占 50 ms', () {
      final List<LyricVisualizerGlyph> g = buildLyricVisualizerLineLevelGlyphs(
        '你好\uFF0C世界',
        0,
        1000,
      );
      expect(g.map((LyricVisualizerGlyph x) => x.startMs).toList(), <int>[
        0,
        225,
        450,
        500,
        725,
      ]);
      expect(g[2].endMs, 500);
      expect(g.last.endMs, 950);
    });

    test('歌词节拍包络：起字时 1，之后回落', () {
      expect(rt.pulseAt(1000), closeTo(1, 1e-9));
      expect(rt.pulseAt(1250), lessThan(0.5));
      expect(rt.pulseAt(500), 0);
    });

    test('种子稳定', () {
      expect(lyricVisualizerSeedOf('abc'), lyricVisualizerSeedOf('abc'));
      final LyricVisualizerRandom a = LyricVisualizerRandom(7);
      final LyricVisualizerRandom b = LyricVisualizerRandom(7);
      for (int i = 0; i < 5; i++) {
        final double x = a.next();
        expect(x, b.next());
        expect(x, inInclusiveRange(0, 1));
      }
    });
  });

  group('LyricVisualizerTuning', () {
    const List<LyricVisualizerTuningSpec> specs = <LyricVisualizerTuningSpec>[
      LyricVisualizerSliderSpec(
        key: 's',
        label: _l,
        min: 0,
        max: 2,
        initial: 1,
      ),
      LyricVisualizerToggleSpec(key: 'b', label: _l, initial: true),
      LyricVisualizerChoiceSpec(
        key: 'c',
        label: _l,
        options: <(String, String Function())>[('x', _l), ('y', _l)],
        initial: 'x',
      ),
    ];

    test('坏值回落默认、越界夹紧', () {
      final LyricVisualizerTuning t = LyricVisualizerTuning(
        specs,
        const <String, Object?>{'s': 9, 'b': 'nope', 'c': 'z'},
      );
      expect(t.number('s', -1), 2);
      expect(t.flag('b', false), isTrue);
      expect(t.choice('c', ''), 'x');
    });
  });

  test('注册表与枚举一一对应，落库值唯一', () {
    expect(
      lyricVisualizerRegistry.keys.toSet(),
      LyricVisualizerMode.values.toSet(),
    );
    for (final MapEntry<LyricVisualizerMode, LyricVisualizerEntry> e
        in lyricVisualizerRegistry.entries) {
      expect(e.value.mode, e.key);
      final Set<String> keys = <String>{};
      for (final LyricVisualizerTuningSpec s in e.value.tunings) {
        expect(keys.add(s.key), isTrue, reason: '${e.key} 参数 key 重复');
      }
    }
    expect(
      LyricVisualizerMode.values
          .map((LyricVisualizerMode m) => m.prefValue)
          .toSet(),
      hasLength(LyricVisualizerMode.values.length),
    );
    expect(LyricVisualizerMode.fromPref('bogus'), LyricVisualizerMode.luminous);
  });

  // 每个样式：逐字 / 行级歌词、动态开 / 关、窄屏，各时间点都能画、卸载干净。
  for (final LyricVisualizerMode mode in LyricVisualizerMode.values) {
    group('样式 ${mode.name} 冒烟', () {
      final LyricVisualizerEntry entry = lyricVisualizerEntryOf(mode);
      testWidgets('逐字 + 动态', (WidgetTester tester) async {
        await pumpVisualizerAcross(tester, entry);
      });
      testWidgets('行级 + 减弱动态 + 暂停', (WidgetTester tester) async {
        await pumpVisualizerAcross(
          tester,
          entry,
          timeline: sampleLineTimeline(),
          motion: false,
          playing: false,
        );
      });
      testWidgets('窄屏竖屏', (WidgetTester tester) async {
        await pumpVisualizerAcross(tester, entry, size: const Size(390, 844));
      });
    });
  }
}

String _l() => 'label';
