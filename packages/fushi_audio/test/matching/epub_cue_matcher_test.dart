import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

/// [EpubCueMatcher]（生产入口 = 第一遍 Dice 匹配 + 锚点间隙回填）的对照测试。
///
/// 上游审查 A3：此前回填只有手工夹具测试，没有任何「同一输入、回填前后逐条
/// [CueMatch] 一致」的用例。这里以 [EpubSrtMatcher.match]（不含回填）为基准，
/// 断言回填**只增不改**：第一遍命中的硬锚点逐字段不变，软锚点不丢且不出界，
/// 未命中的只能变成命中。
AudioCue _cue(int idx, String text) {
  return AudioCue()
    ..bookKey = 'test'
    ..chapterHref = 'srt://default'
    ..sentenceIndex = idx
    ..textFragmentId = ''
    ..text = text
    ..startMs = idx * 1000
    ..endMs = idx * 1000 + 900
    ..audioFileIndex = 0;
}

List<AudioCue> _cues(List<String> texts) => <AudioCue>[
      for (int i = 0; i < texts.length; i++) _cue(i, texts[i]),
    ];

EpubSection _section(int i, String text) =>
    EpubSection(index: i, href: 'ch$i.xhtml', text: text);

/// 三节小书（无職転生 01 开头改写）。
final List<EpubSection> _book = <EpubSection>[
  _section(
    0,
    '俺は三十四歳、住所不定無職。人生を後悔している真っ最中だ。'
    '着のみ着のまま家から叩き出された。多分、そうだろう。',
  ),
  _section(
    1,
    '五人兄弟の四番目として生まれた。小学生の頃は成績も良かった。'
    '周囲からは神童と呼ばれていた。',
  ),
  _section(
    2,
    '中学生になってから、俺は変わってしまった。'
    'いじめられて、学校に行かなくなった。',
  ),
];

/// 文本即正文的 cue（非 ASR：人工字幕）。
const List<String> _exactCueTexts = <String>[
  '俺は三十四歳、住所不定無職。',
  '人生を後悔している真っ最中だ。',
  '着のみ着のまま家から叩き出された。',
  '多分、そうだろう。',
  '五人兄弟の四番目として生まれた。',
  '小学生の頃は成績も良かった。',
  '周囲からは神童と呼ばれていた。',
  '中学生になってから、俺は変わってしまった。',
  'いじめられて、学校に行かなくなった。',
];

/// ASR 风格：かな⇄漢字听写差，bigram Dice 落到 0.8 以下的那几条第一遍会漏。
const List<String> _asrCueTexts = <String>[
  '俺は三十四歳住所不定無職',
  '人生を後悔している真っ最中だ',
  '着のみ着のまま家からたたき出された', // 叩き→たたき（±1 长度容忍下 Dice 0.84：模糊命中 → 软锚点）
  'たぶんそうだろう', // 多分→たぶん（Dice 0.6）
  '五人きょうだいの四番目として生まれた', // 兄弟→きょうだい（Dice 0.69）
  '小学生のころは成績も良かった', // 頃→ころ（Dice 恰好 0.8：模糊命中 → 软锚点）
  '周囲からはしんどうと呼ばれていた', // 神童→しんどう（Dice 0.69）
  '中学生になってから俺は変わってしまった',
  'いじめられて学校に行かなくなった',
];

bool _sameMatch(CueMatch a, CueMatch b) =>
    a.sectionIndex == b.sectionIndex &&
    a.normCharStart == b.normCharStart &&
    a.normCharEnd == b.normCharEnd &&
    a.score == b.score;

/// 全书归一化拼接 + 每节起点，把 [CueMatch] 换成全局偏移。
class _Norm {
  _Norm(List<EpubSection> sections) {
    final StringBuffer buf = StringBuffer();
    for (final EpubSection s in sections) {
      starts.add(buf.length);
      AudioTextNormalizer.appendNormalized(buf, s.text);
    }
    big = buf.toString();
  }

  late final String big;
  final List<int> starts = <int>[];

  int start(CueMatch m) => starts[m.sectionIndex] + m.normCharStart;
  int end(CueMatch m) => starts[m.sectionIndex] + m.normCharEnd;
  String text(CueMatch m) => big.substring(start(m), end(m));
}

/// 断言回填只增不改：硬锚点逐字段不变；软锚点仍命中、≥ anchorMinSimilarity、
/// 不越过第一遍相邻命中 cue；未命中只能变命中。伪锚点（≤ softAnchorMaxLen）
/// 是设计上唯一可挪/可丢的，这里的夹具没有。
void _expectFillOnlyAdds(
  List<EpubSection> sections,
  List<AudioCue> cues,
  MatchResult first,
  MatchResult filled, {
  AnchorGapFiller filler = EpubCueMatcher.gapFiller,
}) {
  expect(filled.matches.length, first.matches.length);
  expect(filled.gapFill, isNotNull);
  expect(filled.gapFill!.invariantViolated, isFalse);
  final _Norm norm = _Norm(sections);
  for (int i = 0; i < cues.length; i++) {
    final CueMatch f = first.matches[i];
    final CueMatch o = filled.matches[i];
    final int len = AudioTextNormalizer.normalize(cues[i].text).length;
    if (!f.matched) continue;
    expect(o.matched, isTrue, reason: 'cue $i 第一遍命中、回填后丢失');
    expect(len, greaterThan(filler.softAnchorMaxLen), reason: '夹具里不该有伪锚点');
    if (f.score >= 1.0) {
      expect(_sameMatch(o, f), isTrue, reason: 'cue $i 硬锚点被改动');
      continue;
    }
    if (_sameMatch(o, f)) continue;
    expect(o.score, greaterThanOrEqualTo(filler.anchorMinSimilarity));
    int prevEnd = 0;
    for (int p = i - 1; p >= 0; p--) {
      if (first.matches[p].matched) {
        prevEnd = norm.end(first.matches[p]);
        break;
      }
    }
    int nextStart = norm.big.length;
    for (int p = i + 1; p < cues.length; p++) {
      if (first.matches[p].matched) {
        nextStart = norm.start(first.matches[p]);
        break;
      }
    }
    expect(norm.start(o), greaterThanOrEqualTo(prevEnd),
        reason: 'cue $i 软锚点向前出界');
    expect(norm.end(o), lessThanOrEqualTo(nextStart), reason: 'cue $i 软锚点向后出界');
  }
  // 命中数与逐条结果一致。
  expect(
    filled.matchedCues,
    filled.matches.where((CueMatch m) => m.matched).length,
  );
  expect(filled.matchedCues, greaterThanOrEqualTo(first.matchedCues));
}

/// [count] 条正文里绝对没有的 cue（片假名重复，bigram 与正文零重叠、精确
/// indexOf 必败），每条 ≥ 6 字以便第一遍的恢复扫描也会拿它去试。
List<String> _garbageCues(int count) => <String>[
      for (int i = 0; i < count; i++) 'ヴェ' * (3 + i % 3),
    ];

/// 两条唯一的长句锚点中间夹 [fillerSentences] 句埋草正文。
List<EpubSection> _bookWithHugeGap(int fillerSentences) => <EpubSection>[
      _section(0, '俺は三十四歳、住所不定無職。人生を後悔している真っ最中だ。'),
      _section(1, 'この文章は埋め草である。' * fillerSentences),
      _section(2, '最後の文章で終わるのだった。それから何も起きなかった。'),
    ];

/// 前锚点 + [garbage] 条正文里没有的 cue + 后锚点。垃圾 cue ≥ 20 条才会触发
/// 第一遍的恢复扫描（[EpubSrtMatcher.defaultMaxConsecutiveMisses]）让后锚点
/// 命中——否则后锚点在 200 字窗口里根本看不见。
List<AudioCue> _cuesWithGarbage(int garbage) => _cues(<String>[
      '俺は三十四歳住所不定無職',
      '人生を後悔している真っ最中だ',
      ..._garbageCues(garbage),
      '最後の文章で終わるのだった',
      'それから何も起きなかった',
    ]);

void main() {
  group('EpubCueMatcher 对 EpubSrtMatcher：回填只增不改', () {
    test('(a) 非 ASR 夹具：全部精确命中时回填后逐条一致', () {
      final List<AudioCue> cues = _cues(_exactCueTexts);
      final MatchResult first = EpubSrtMatcher.match(
        sections: _book,
        cues: _cues(_exactCueTexts),
      );
      final MatchResult filled = EpubCueMatcher.match(
        sections: _book,
        cues: cues,
      );
      expect(first.matchedCues, cues.length, reason: '夹具应全部精确命中');
      _expectFillOnlyAdds(_book, cues, first, filled);
      for (int i = 0; i < cues.length; i++) {
        expect(_sameMatch(filled.matches[i], first.matches[i]), isTrue);
      }
      expect(filled.gapFill!.runs, 0);
    });

    test('(a) 非 ASR 夹具 + 正文里没有的行：未命中保持、命中逐条一致', () {
      final List<String> texts = <String>[
        'オーディブルがお届けする', // 片头：没有前锚点
        ..._exactCueTexts.sublist(0, 4),
        'ざわざわ', // 零间隙里的旁白拟声：两锚点之间放不下
        ..._exactCueTexts.sublist(4),
        'ナレーション終わり', // 片尾：没有后锚点
      ];
      final List<AudioCue> cues = _cues(texts);
      final MatchResult first = EpubSrtMatcher.match(
        sections: _book,
        cues: _cues(texts),
      );
      final MatchResult filled = EpubCueMatcher.match(
        sections: _book,
        cues: cues,
      );
      expect(first.matchedCues, _exactCueTexts.length);
      _expectFillOnlyAdds(_book, cues, first, filled);
      for (int i = 0; i < cues.length; i++) {
        expect(_sameMatch(filled.matches[i], first.matches[i]), isTrue,
            reason: 'cue $i "${texts[i]}"');
      }
      expect(filled.matchedCues, first.matchedCues);
      expect(filled.gapFill!.runs, 1);
      expect(filled.gapFill!.abandonedRuns, 1);
    });

    test('(b) ASR 夹具：听写差 cue 被回填、第一遍命中的原样保留', () {
      final List<AudioCue> cues = _cues(_asrCueTexts);
      final MatchResult first = EpubSrtMatcher.match(
        sections: _book,
        cues: _cues(_asrCueTexts),
      );
      // 夹具前提：3/4/6 第一遍漏掉，2/5 是模糊命中（软锚点）。
      for (final int i in <int>[3, 4, 6]) {
        expect(first.matches[i].matched, isFalse, reason: 'cue $i 应第一遍漏掉');
      }
      for (final int i in <int>[2, 5]) {
        expect(first.matches[i].matched, isTrue, reason: 'cue $i 应模糊命中');
        expect(first.matches[i].score, lessThan(1.0));
      }
      final MatchResult filled = EpubCueMatcher.match(
        sections: _book,
        cues: cues,
      );
      _expectFillOnlyAdds(_book, cues, first, filled);
      expect(filled.matchedCues, greaterThan(first.matchedCues));
      final _Norm norm = _Norm(_book);
      expect(norm.text(filled.matches[2]), '着のみ着のまま家から叩き出された');
      expect(norm.text(filled.matches[4]), '五人兄弟の四番目として生まれた');
      expect(norm.text(filled.matches[6]), '周囲からは神童と呼ばれていた');
      expect(filled.matchedCues, cues.length);
    });

    test('(c) 两个硬锚点夹着 ≥ 50000 字 region：有限时间返回、锚点逐字段不变', () {
      final List<EpubSection> book = _bookWithHugeGap(5000); // 11 字 × 5000
      final _Norm norm = _Norm(book);
      expect(norm.starts[2] - norm.starts[1], greaterThanOrEqualTo(50000));
      final List<AudioCue> cues = _cuesWithGarbage(30);
      final MatchResult first = EpubSrtMatcher.match(
        sections: book,
        cues: _cuesWithGarbage(30),
      );
      expect(first.matches[1].score, 1.0);
      expect(first.matches[cues.length - 2].score, 1.0,
          reason: '后锚点应由恢复扫描精确命中');
      final Stopwatch sw = Stopwatch()..start();
      final MatchResult filled = EpubCueMatcher.match(
        sections: book,
        cues: cues,
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(2000));
      _expectFillOnlyAdds(book, cues, first, filled);
      for (int i = 0; i < cues.length; i++) {
        expect(_sameMatch(filled.matches[i], first.matches[i]), isTrue,
            reason: 'cue $i');
      }
      final GapFillStats stats = filled.gapFill!;
      expect(stats.runs, 1);
      expect(stats.oversizeRuns, 1, reason: '超限串必须可观测，不能静默');
      expect(stats.filledRuns, 0);
      expect(stats.work, 0);
    });

    test('(c) region 在上限内时真的跑 Sellers：30 条垃圾 cue × 3000 字仍有限时间', () {
      final List<EpubSection> book = _bookWithHugeGap(270); // ≈ 2970 字
      final List<AudioCue> cues = _cuesWithGarbage(30);
      final MatchResult first = EpubSrtMatcher.match(
        sections: book,
        cues: _cuesWithGarbage(30),
      );
      final Stopwatch sw = Stopwatch()..start();
      final MatchResult filled = EpubCueMatcher.match(
        sections: book,
        cues: cues,
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(2000));
      _expectFillOnlyAdds(book, cues, first, filled);
      final GapFillStats stats = filled.gapFill!;
      expect(stats.runs, 1);
      expect(stats.oversizeRuns, 0);
      expect(stats.work, greaterThan(0));
      // 垃圾 cue 与正文零重叠、总长与间隙不相称：一条都不该被硬塞。
      for (int i = 2; i < cues.length - 2; i++) {
        expect(filled.matches[i].matched, isFalse, reason: 'cue $i');
      }
      for (final int i in <int>[0, 1, cues.length - 2, cues.length - 1]) {
        expect(_sameMatch(filled.matches[i], first.matches[i]), isTrue);
      }
    });

    test('工作量预算耗尽后剩余串跳过并可观测', () {
      const AnchorGapFiller tight = AnchorGapFiller(maxTotalWork: 1);
      final List<AudioCue> cues = _cues(_asrCueTexts);
      final MatchResult first = EpubSrtMatcher.match(
        sections: _book,
        cues: cues,
      );
      final MatchResult filled = tight.fill(
        sections: _book,
        cues: cues,
        result: first,
      );
      expect(filled.gapFill!.budgetSkippedRuns, filled.gapFill!.runs);
      expect(filled.gapFill!.runs, greaterThan(0));
      expect(filled.gapFill!.skippedAny, isTrue);
      for (int i = 0; i < cues.length; i++) {
        expect(_sameMatch(filled.matches[i], first.matches[i]), isTrue);
      }
    });

    test('(d) matchInIsolate 与同步 match 逐条一致', () async {
      final MatchResult sync = EpubCueMatcher.match(
        sections: _book,
        cues: _cues(_asrCueTexts),
      );
      final MatchResult iso = await EpubCueMatcher.matchInIsolate(
        sections: _book,
        cues: _cues(_asrCueTexts),
      );
      expect(iso.matches.length, sync.matches.length);
      for (int i = 0; i < sync.matches.length; i++) {
        expect(_sameMatch(iso.matches[i], sync.matches[i]), isTrue,
            reason: 'cue $i');
        expect(
            iso.matches[i].cueSentenceIndex, sync.matches[i].cueSentenceIndex);
      }
      expect(iso.matchedCues, sync.matchedCues);
      expect(iso.gapFill, isNotNull, reason: 'isolate 里也做了回填');
      expect(iso.gapFill!.runs, sync.gapFill!.runs);
      expect(iso.gapFill!.filledRuns, sync.gapFill!.filledRuns);
    });

    test('(d) probeInIsolate 的 bestResult 已含回填，与同步 probe + fill 一致', () async {
      final List<AudioCue> cues = _cues(_asrCueTexts);
      final ProbeResult syncProbe = EpubSrtMatcher.probe(
        sections: _book,
        cues: cues,
        windows: EpubCueMatcher.defaultProbeWindows,
      );
      final MatchResult sync = EpubCueMatcher.gapFiller.fill(
        sections: _book,
        cues: cues,
        result: syncProbe.bestResult!,
      );
      final ProbeResult iso = await EpubCueMatcher.probeInIsolate(
        sections: _book,
        cues: _cues(_asrCueTexts),
      );
      expect(iso.perWindow, syncProbe.perWindow);
      final MatchResult best = iso.bestResult!;
      expect(best.gapFill, isNotNull);
      for (int i = 0; i < cues.length; i++) {
        expect(_sameMatch(best.matches[i], sync.matches[i]), isTrue,
            reason: 'cue $i');
      }
      expect(best.matchedCues, sync.matchedCues);
      expect(best.matchedCues, greaterThan(syncProbe.bestResult!.matchedCues));
    });
  });
}
