import 'package:test/test.dart';
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

/// BUG-2928（『やはり俺の青春ラブコメはまちがっている。』1 卷，用户 VN 模式录屏）：
/// 正文 ruby 按传统排版不用小書き仮名（「オイレン・シルフイード」「きようがく」），
/// ASR 吐的是现代写法「シルフィード」「きょうがく」。同一读音的 ruby 在一段里出现三次，
/// 后两次紧挨着。
const String _text = '「そういえば聞いたことがある……。風を意のままに操る伝説の技、'
    'その名も『風を継ぐ者・風精悪戯』!!」'
    '空気を読まない材木座だけが大声を張り上げた。'
    '勝手に名前付けんなよ。台無しもいいところだ。'
    '「ありえないし……」'
    '三浦が驚愕のあまり呟く。それを皮切りにギャラリーもざわざわと小さな声をあげ、'
    'それがやがて『風精悪戯？』『風精悪戯！』という単語に変わっていく。'
    'いや、受け入れちゃダメだろ。';

const String _ruby = '風精悪戯';

List<EpubRubySpan> _rubies() {
  final List<EpubRubySpan> out = <EpubRubySpan>[];
  int at = _text.indexOf(_ruby);
  while (at >= 0) {
    out.add(EpubRubySpan(
      start: at,
      end: at + _ruby.length,
      reading: 'オイレン・シルフイード',
    ));
    at = _text.indexOf(_ruby, at + _ruby.length);
  }
  void add(String base, String reading) {
    final int i = _text.indexOf(base);
    out.add(EpubRubySpan(start: i, end: i + base.length, reading: reading));
  }

  add('材木座', 'ざいもくざ');
  add('驚愕', 'きようがく');
  add('呟', 'つぶや');
  out.sort((EpubRubySpan a, EpubRubySpan b) => a.start - b.start);
  return out;
}

final List<EpubSection> _sections = <EpubSection>[
  EpubSection(index: 0, href: 'part0039.html', text: _text, rubies: _rubies()),
];

/// 原文第 [nth] 处 [needle] 在基底轨归一化串里的 `[start, end)`。
(int, int) _normRange(String needle, [int nth = 0]) {
  int at = -1;
  for (int i = 0; i <= nth; i++) {
    at = _text.indexOf(needle, at + 1);
  }
  expect(at, greaterThanOrEqualTo(0), reason: needle);
  final int s = AudioTextNormalizer.normalize(_text.substring(0, at)).length;
  return (s, s + AudioTextNormalizer.normalize(needle).length);
}

// 与用户库里 transcript.srt 第 5624..5636 条逐字一致（含听写差）。
const List<String> _asr = <String>[
  'そういえば聞いたことがある',
  '風を意のままに操る伝説の技',
  'その名も',
  '風を継ぐ者',
  'おいれんシルフィード',
  '空気を読まない材木座だけが大声を張り上げた',
  '勝手に名前つけんなよ台なしもいいところだ',
  'ありえないし',
  '三浦が驚がくのあまりつぶやく',
  'それを皮切りにギャラリーもザワザワと小さな声を上げそれがやがてい',
  'オイレンシルフィード',
  'おいらんシルフィード',
  'という単語に変わっていく',
  'いや受け入れちゃダメだろ',
];

void main() {
  group('BUG-2928 ruby 並字读音 vs ASR 小書き仮名', () {
    test('第一处 ruby 就地命中，游标不越过中间正文', () {
      final MatchResult r = EpubSrtMatcher.match(
        sections: _sections,
        cues: _cues(_asr),
      );
      // 「おいれんシルフィード」落在第一处 風精悪戯（旧实现：0.78 过不了阈值，
      // 骑在后两处之间的窗口凑出 0.82，游标越过七句正文）。
      final (int r0s, int r0e) = _normRange(_ruby);
      expect(r.matches[4].matched, isTrue);
      expect(r.matches[4].normCharStart, r0s);
      expect(r.matches[4].normCharEnd, r0e);
      expect(r.matches[4].score, 1);
      // 夹在中间的句子按序落在第一、二处 ruby 之间（「勝手に…」「三浦が驚がく…」
      // 听写差太多，第一遍不命中，交给回填，见下面的回填用例）。
      final (int kuuki, _) = _normRange('空気を読まない');
      final (int r1s, int r1e) = _normRange(_ruby, 1);
      expect(r.matches[5].normCharStart, kuuki);
      int last = r0e;
      for (final int i in <int>[5, 7, 9]) {
        final CueMatch m = r.matches[i];
        expect(m.matched, isTrue, reason: _asr[i]);
        expect(m.normCharStart, greaterThanOrEqualTo(last), reason: _asr[i]);
        expect(m.normCharEnd, lessThanOrEqualTo(r1s), reason: _asr[i]);
        last = m.normCharEnd;
      }
      // 第二处 ruby 归「オイレンシルフィード」。
      expect(r.matches[10].normCharStart, r1s);
      expect(r.matches[10].normCharEnd, r1e);
    });

    test('读音轨命中不落回前一条命中的同一处 ruby', () {
      final MatchResult r = EpubSrtMatcher.match(
        sections: _sections,
        cues: _cues(_asr),
      );
      // 「おいらんシルフィード」只有骑在两处 ruby 之间的窗口够得到阈值；那个窗口
      // 换回基底轨会叠在上一条（第二处 ruby）上，宁可不命中交给回填。
      final CueMatch prev = r.matches[10];
      final CueMatch m = r.matches[11];
      if (m.matched) {
        expect(m.normCharStart, greaterThanOrEqualTo(prev.normCharEnd));
      }
      expect(r.matches[12].matched, isTrue);
    });

    test('回填后第三处 ruby 归「おいらんシルフィード」', () {
      final MatchResult r = EpubCueMatcher.match(
        sections: _sections,
        cues: _cues(_asr),
      );
      final (int r2s, int r2e) = _normRange(_ruby, 2);
      expect(r.matches[11].normCharStart, r2s);
      expect(r.matches[11].normCharEnd, r2e);
      for (int i = 0; i < _asr.length; i++) {
        expect(r.matches[i].matched, isTrue, reason: _asr[i]);
      }
    });

    test('小書き仮名折叠只在匹配器内部：共享归一化保持原值', () {
      // 阅读器 JS 的 foldCodePoint 与 AudioTextNormalizer 逐值对齐，不能被这次放宽带走。
      expect(AudioTextNormalizer.normalize('シルフィード'), 'しるふぃーど');
      expect(AudioTextNormalizer.normalize('きょうがく'), 'きょうがく');
    });
  });
}
