import 'package:fushi_audio/fushi_audio.dart';
import 'package:test/test.dart';

AudioCue _cue(String text, int start, int end, {List<int>? offsets}) =>
    AudioCue()
      ..bookKey = 'b'
      ..chapterHref = ''
      ..sentenceIndex = 0
      ..textFragmentId = ''
      ..text = text
      ..startMs = start
      ..endMs = end
      ..audioFileIndex = 0
      ..tokenTiming = offsets == null
          ? null
          : CueTokenTiming(
              tokens: <String>[for (final int _ in offsets) 'x'],
              offsetsMs: offsets,
            );

CueMatch _m(int from, int to, {int section = 0}) => CueMatch(
  cueSentenceIndex: 0,
  sectionIndex: section,
  normCharStart: from,
  normCharEnd: to,
  score: 1,
);

MatchResult _result(List<CueMatch> ms) => MatchResult(
  matches: ms,
  totalCues: ms.length,
  matchedCues: ms.where((CueMatch m) => m.matched).length,
);

void main() {
  const CueFragmentMerger merger = CueFragmentMerger();

  test('句内短碎片并进下一条：文本、区间、token 时间首尾相接', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue('何か、', 1000, 1500, offsets: <int>[0, 200]),
      _cue('おかしい。', 1800, 3000, offsets: <int>[0, 300]),
    ];
    final r = merger.merge(
      cues: cues,
      result: _result(<CueMatch>[_m(0, 2), _m(2, 6)]),
    );
    expect(r.merged, 1);
    expect(r.cues, hasLength(1));
    final AudioCue c = r.cues.single;
    expect(c.text, '何か、おかしい。');
    expect((c.startMs, c.endMs), (1000, 3000));
    expect(c.tokenTiming!.offsetsMs, <int>[0, 200, 800, 1100]);
    final CueMatch m = r.result.matches.single;
    expect((m.normCharStart, m.normCharEnd), (0, 6));
    expect(r.result.totalCues, 1);
    expect(r.result.matchedCues, 1);
  });

  test('前一条是句末、两侧都够长、停顿太长、跨章或区间不相接时不并', () {
    MatchResult two({int s2 = 0, int from2 = 2}) =>
        _result(<CueMatch>[_m(0, 2), _m(from2, 6, section: s2)]);
    List<AudioCue> pair(String a, int aEnd, int bStart, int bEnd) => <AudioCue>[
      _cue(a, 0, aEnd),
      _cue('つづき。', bStart, bEnd),
    ];

    expect(
      merger.merge(cues: pair('はい。', 500, 600, 1500), result: two()).merged,
      0,
    );
    expect(
      merger.merge(cues: pair('はい」', 500, 600, 1500), result: two()).merged,
      0,
    );
    expect(
      merger.merge(cues: pair('だが、', 2000, 2100, 4000), result: two()).merged,
      0,
    );
    expect(
      merger.merge(cues: pair('だが、', 500, 2600, 3000), result: two()).merged,
      0,
    );
    expect(
      merger
          .merge(cues: pair('だが、', 500, 600, 1500), result: two(s2: 1))
          .merged,
      0,
    );
    expect(
      merger
          .merge(cues: pair('だが、', 500, 600, 1500), result: two(from2: 3))
          .merged,
      0,
    );
  });

  test('未命中的 cue 不参与', () {
    final r = merger.merge(
      cues: <AudioCue>[_cue('だが、', 0, 500), _cue('うん', 600, 900)],
      result: _result(<CueMatch>[_m(0, 2), CueMatch.unmatched]),
    );
    expect(r.merged, 0);
  });

  test('拉丁缩写后的句点不算句末：Ｍｓ．并进名字', () {
    expect(CueFragmentMerger.isSentenceEnd('Ｍｓ．'), isFalse);
    expect(CueFragmentMerger.isSentenceEnd('Mr.'), isFalse);
    expect(CueFragmentMerger.isSentenceEnd('そうだ．'), isTrue);
    expect(CueFragmentMerger.isSentenceEnd('だが──'), isFalse);
    expect(CueFragmentMerger.isSentenceEnd('「む？」'), isTrue);
  });

  test('连锁合并多段，但不超过字数上限', () {
    final List<AudioCue> cues = <AudioCue>[
      _cue('あ、', 0, 400),
      _cue('い、', 500, 900),
      _cue('う。', 1000, 1400),
    ];
    final r = merger.merge(
      cues: cues,
      result: _result(<CueMatch>[_m(0, 1), _m(1, 2), _m(2, 3)]),
    );
    expect(r.cues.single.text, 'あ、い、う。');

    final r2 = const CueFragmentMerger(maxChars: 4).merge(
      cues: cues,
      result: _result(<CueMatch>[_m(0, 1), _m(1, 2), _m(2, 3)]),
    );
    expect(r2.cues.map((AudioCue c) => c.text), <String>['あ、い、', 'う。']);
  });
}
