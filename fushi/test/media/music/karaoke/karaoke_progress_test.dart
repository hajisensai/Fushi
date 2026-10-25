import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/lyrics/karaoke/karaoke_progress.dart';
import 'package:fushi_music/fushi_music.dart';

LyricLine _line(
  int start,
  int end,
  List<LyricSyllable> s, {
  LyricRole role = LyricRole.main,
}) => LyricLine(startMs: start, endMs: end, syllables: s, role: role);

void main() {
  group('音节擦色进度', () {
    const LyricSyllable sweep = LyricSyllable(
      text: 'a',
      startMs: 1000,
      endMs: 2000,
    );
    const LyricSyllable instant = LyricSyllable(
      text: 'b',
      startMs: 1000,
      endMs: 2000,
      fill: LyricFill.instant,
    );
    const LyricSyllable outline = LyricSyllable(
      text: 'c',
      startMs: 1000,
      endMs: 2000,
      fill: LyricFill.outline,
    );

    // 与 libass 一致（真 libmpv 截帧：music_karaoke_stage_real_test）：\kf 擦色，
    // \k 与 \ko 都在音节起点瞬间切换。
    test('Sweep 线性，Instant / Outline 在起点整字切换', () {
      expect(karaokeSyllableProgress(sweep, 999), 0);
      expect(karaokeSyllableProgress(sweep, 1250), closeTo(0.25, 1e-9));
      expect(karaokeSyllableProgress(sweep, 2000), 1);
      expect(karaokeSyllableProgress(outline, 999), 0);
      expect(karaokeSyllableProgress(outline, 1000), 1);
      expect(karaokeSyllableProgress(outline, 1500), 1);
      expect(karaokeSyllableProgress(instant, 999), 0);
      expect(karaokeSyllableProgress(instant, 1000), 1);
      expect(karaokeSyllableProgress(instant, 1999), 1);
    });

    test('零时长音节到点即满', () {
      const LyricSyllable z = LyricSyllable(text: 'z', startMs: 5, endMs: 5);
      expect(karaokeSyllableProgress(z, 5), 1);
    });

    test('行级估计：线性 / 关掉时整行到点高亮', () {
      final LyricLine l = _line(0, 4000, const <LyricSyllable>[
        LyricSyllable(text: 'line', startMs: 0, endMs: 4000),
      ]);
      expect(karaokeLineLevelProgress(l, 1000), closeTo(0.25, 1e-9));
      expect(karaokeLineLevelProgress(l, 1000, sweep: false), 1);
      expect(karaokeLineLevelProgress(l, -1), 0);
    });

    test('长音呼吸只作用于 > 1 s 的音节，中段最大', () {
      const LyricSyllable long = LyricSyllable(
        text: 'o',
        startMs: 0,
        endMs: 2000,
      );
      expect(karaokeBreathScale(sweep, 0.5), 1);
      expect(
        karaokeBreathScale(long, 0.5),
        closeTo(1 + kKaraokeBreathScale, 1e-9),
      );
      expect(karaokeBreathScale(long, 0), 1);
      expect(karaokeBreathScale(long, 1), 1);
    });
  });

  group('偏移与当前行', () {
    final LyricTimeline t = LyricTimeline(
      format: 'ttml',
      timingQuality: LyricTimingQuality.syllable,
      lines: <LyricLine>[
        _line(1000, 2000, const <LyricSyllable>[
          LyricSyllable(text: 'a', startMs: 1000, endMs: 2000),
        ]),
        _line(1500, 2500, const <LyricSyllable>[
          LyricSyllable(text: '(bg)', startMs: 1500, endMs: 2500),
        ], role: LyricRole.background),
        _line(3000, 4000, const <LyricSyllable>[
          LyricSyllable(text: 'b', startMs: 3000, endMs: 4000),
        ]),
        _line(5000, 6000, const <LyricSyllable>[
          LyricSyllable(text: 'c', startMs: 5000, endMs: 6000),
        ]),
      ],
    );
    final List<KaraokeRowSpan> rows = karaokeRows(t);

    test('和声行并进前一主行组', () {
      expect(rows.length, 3);
      expect(rows[0].main, 0);
      expect(rows[0].backgrounds, <int>[1]);
      expect(rows[1].main, 2);
    });

    int cur(int pos, {int offset = 0}) => karaokeCurrentRow(
      timeline: t,
      rows: rows,
      positionMs: pos,
      offsetMs: offset,
    );

    test('起点已到的最后一组；间奏保持上一组', () {
      expect(cur(500), -1);
      expect(cur(1000), 0);
      expect(cur(2800), 0);
      expect(cur(3000), 1);
      expect(cur(9999), 2);
    });

    test('整首偏移正 = 歌词提前', () {
      expect(cur(2500, offset: 500), 1);
      expect(cur(2500), 0);
    });

    test('跳转位置抵消偏移，且不为负', () {
      expect(karaokeSeekPositionForLine(line: t.lines[2], offsetMs: 500), 2500);
      expect(karaokeSeekPositionForLine(line: t.lines[0], offsetMs: 5000), 0);
    });

    test('是否正在唱（含和声行）', () {
      expect(
        karaokeRowIsSinging(
          timeline: t,
          row: rows[0],
          positionMs: 2200,
          offsetMs: 0,
        ),
        isTrue,
        reason: '主行已唱完但和声行还在',
      );
      expect(
        karaokeRowIsSinging(
          timeline: t,
          row: rows[0],
          positionMs: 2800,
          offsetMs: 0,
        ),
        isFalse,
      );
    });

    test('无时间歌词没有当前行', () {
      final LyricTimeline u = LyricTimeline(
        format: 'txt',
        timingQuality: LyricTimingQuality.unsynced,
        lines: t.lines,
      );
      expect(
        karaokeCurrentRow(
          timeline: u,
          rows: karaokeRows(u),
          positionMs: 9999,
          offsetMs: 0,
        ),
        -1,
      );
    });
  });
}
