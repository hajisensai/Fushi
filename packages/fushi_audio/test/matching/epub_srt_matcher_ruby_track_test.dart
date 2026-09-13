import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

AudioCue _cue(int idx, String text) => AudioCue()
  ..bookKey = 'test'
  ..chapterHref = 'srt://default'
  ..sentenceIndex = idx
  ..textFragmentId = ''
  ..text = text
  ..startMs = idx * 1000
  ..endMs = idx * 1000 + 900
  ..audioFileIndex = 0;

List<AudioCue> _cues(List<String> texts) => <AudioCue>[
      for (int i = 0; i < texts.length; i++) _cue(i, texts[i]),
    ];

/// 正文（带 ruby 基底区间）：
/// `その子はなんでもできる、素敵な子。みんなその子と友達になりたがる。
///  周りの子がみんな息を吞む中、私に目配せをする。`
/// ruby：素敵→すてき、友達→ともだち、吞む→のむ、目配せ→めくばせ。
const String _text = 'その子はなんでもできる、素敵な子。みんなその子と友達になりたがる。'
    '周りの子がみんな息を吞む中、私に目配せをする。それから家に帰った。';

EpubRubySpan _ruby(String base, String reading) {
  final int at = _text.indexOf(base);
  expect(at, greaterThanOrEqualTo(0), reason: base);
  return EpubRubySpan(start: at, end: at + base.length, reading: reading);
}

final List<EpubSection> _withRuby = <EpubSection>[
  EpubSection(
    index: 0,
    href: 'ch0.xhtml',
    text: _text,
    rubies: <EpubRubySpan>[
      _ruby('素敵', 'すてき'),
      _ruby('友達', 'ともだち'),
      _ruby('吞', 'の'),
      _ruby('目配せ', 'めくばせ'),
    ],
  ),
];

final List<EpubSection> _baseOnly = <EpubSection>[
  const EpubSection(index: 0, href: 'ch0.xhtml', text: _text),
];

/// 基底轨归一化：その子はなんでもできる(0-11)素敵な子(11-15)みんなその子と友達に
/// なりたがる(15-30)周りの子がみんな息を吞む中(30-43)私に目配せをする(43-51)
/// それから家に帰った(51-60)。
void main() {
  group('读音轨', () {
    test('听写かな在读音轨精确命中，区间换算回基底轨（整个 ruby 为原子）', () {
      final MatchResult r = EpubSrtMatcher.match(
        sections: _withRuby,
        cues: _cues(<String>[
          'その子はなんでも',
          'できるすてきな子',
          'みんなその子とともだちになりたがる',
        ]),
      );
      expect(r.matchedCues, 3);
      // 「できるすてきな子」→ 基底 できる素敵な子 = [8, 15)。
      expect(r.matches[1].normCharStart, 8);
      expect(r.matches[1].normCharEnd, 15);
      expect(r.matches[1].score, 1);
      expect(r.matches[2].normCharStart, 15);
      expect(r.matches[2].normCharEnd, 30);
    });

    test('没有 ruby 时同一输入结果逐字段相同（基底轨行为不变）', () {
      const List<String> texts = <String>[
        'その子はなんでもできる',
        '素敵な子',
        'みんなその子と友達になりたがる',
        '周りの子がみんな息を吞む中',
        '私に目配せをする',
      ];
      final MatchResult a =
          EpubSrtMatcher.match(sections: _baseOnly, cues: _cues(texts));
      final MatchResult b =
          EpubSrtMatcher.match(sections: _withRuby, cues: _cues(texts));
      expect(a.matchedCues, 5);
      for (int i = 0; i < texts.length; i++) {
        expect(b.matches[i].sectionIndex, a.matches[i].sectionIndex);
        expect(b.matches[i].normCharStart, a.matches[i].normCharStart);
        expect(b.matches[i].normCharEnd, a.matches[i].normCharEnd);
        expect(b.matches[i].score, a.matches[i].score);
      }
    });

    test('基底轨 Dice 够不到阈值、读音轨够到：模糊通道也走读音轨', () {
      // 听写差一字：「めくばせ」正文写 目配せ；「私にめくばぜをする」只在读音轨上
      // 与「私にめくばせをする」相近（Dice 高），基底轨零重叠。
      // Dice：基底轨 0.40（私に/をす/する），读音轨 0.75；ASR 产物用建议阈值 0.6。
      final MatchResult r = EpubSrtMatcher.match(
        sections: _withRuby,
        cues: _cues(<String>['周りの子がみんな息をのむ中', '私にめくばぜをする']),
        similarityThreshold: 0.6,
      );
      expect(r.matchedCues, 2);
      expect(r.matches[0].normCharStart, 30);
      expect(r.matches[0].normCharEnd, 43);
      expect(r.matches[1].normCharStart, 43);
      expect(r.matches[1].normCharEnd, 51);
      expect(r.matches[1].score, lessThan(1));
      expect(r.matches[1].score, greaterThanOrEqualTo(0.6));
    });

    test('短 cue 不走读音轨（防全假名撞车）', () {
      final MatchResult r = EpubSrtMatcher.match(
        sections: _withRuby,
        cues: _cues(<String>['その子はなんでもできる', 'すてき']),
      );
      expect(r.matches[1].matched, isFalse);
    });

    test('命中落在读音中间时起终点吸附到整个 ruby 基底', () {
      // 「なんでもできるすてき」：末尾只覆盖到读音 すてき 的全部，基底终点 = 素敵 末。
      final MatchResult r = EpubSrtMatcher.match(
        sections: _withRuby,
        cues: _cues(<String>['なんでもできるすて']),
      );
      expect(r.matchedCues, 1);
      expect(r.matches[0].normCharStart, 4);
      expect(r.matches[0].normCharEnd, 13);
    });

    test('回填 + 换正文：读音轨命中的 cue 换回来的是漢字正文', () {
      final List<AudioCue> cues = _cues(<String>[
        'その子はなんでも',
        'できるすてきな子',
        'みんなその子とともだちになりたがる',
      ]);
      final MatchResult r =
          EpubCueMatcher.match(sections: _withRuby, cues: cues);
      replaceMatchedCueTextWithBookText(
          sections: _withRuby, cues: cues, result: r);
      expect(cues[1].text, 'できる、素敵な子。');
      expect(cues[2].text, 'みんなその子と友達になりたがる。');
    });
  });
}
