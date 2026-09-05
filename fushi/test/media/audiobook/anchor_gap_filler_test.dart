import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

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

EpubSection _section(int i, String text) =>
    EpubSection(index: i, href: 'ch$i.xhtml', text: text);

/// 手工构造第一遍结果：[hits] 给「cue 序号 → 正文里的精确子串」，其余未命中。
/// 归一化偏移按 [AudioTextNormalizer] 在第 0 节里 indexOf 得到，与匹配器同口径。
MatchResult _firstPass(
  List<EpubSection> sections,
  List<AudioCue> cues,
  Map<int, String> hits,
) {
  final String norm = AudioTextNormalizer.normalize(sections.single.text);
  final List<CueMatch> matches = <CueMatch>[];
  for (final AudioCue c in cues) {
    final String? hit = hits[c.sentenceIndex];
    if (hit == null) {
      matches.add(CueMatch.unmatched);
      continue;
    }
    final String nh = AudioTextNormalizer.normalize(hit);
    final int at = norm.indexOf(nh);
    expect(at, greaterThanOrEqualTo(0), reason: '夹具错误：正文里没有 $hit');
    matches.add(
      CueMatch(
        cueSentenceIndex: c.sentenceIndex,
        sectionIndex: 0,
        normCharStart: at,
        normCharEnd: at + nh.length,
        score: 1,
      ),
    );
  }
  return MatchResult(
    matches: matches,
    totalCues: cues.length,
    matchedCues: hits.length,
  );
}

/// 按 cue 位置取结果（未命中项是 [CueMatch.unmatched]，序号为 -1，不能按序号键）。
Map<int, CueMatch> _byCue(MatchResult r, List<AudioCue> cues) =>
    <int, CueMatch>{
      for (int i = 0; i < cues.length; i++) cues[i].sentenceIndex: r.matches[i],
    };

void main() {
  const AnchorGapFiller filler = AnchorGapFiller();

  group('AnchorGapFiller', () {
    final List<EpubSection> sections = <EpubSection>[
      _section(
        0,
        '俺は三十四歳、住所不定無職。人生を後悔している真っ最中だ。'
        '着のみ着のまま家から叩き出された。多分、そうだろう。'
        '五人兄弟の四番目として生まれた。小学生の頃は成績も良かった。',
      ),
    ];

    test('两锚点之间的听写差 cue 被回填到正确区间，文本可换成正文', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, '俺は三十四歳住所不定無職'),
        _cue(1, '人生を後悔している真っ最中だ'),
        _cue(2, '着のみ着のまま家からたたき出された'), // 叩き→たたき
        _cue(3, 'たぶん'), // 多分（短 cue）
        _cue(4, 'そうだろう'),
        _cue(5, '五人きょうだいの四番目として生まれた'), // 兄弟→きょうだい
        _cue(6, '小学生のころは成績も良かった'), // 頃→ころ
      ];
      final MatchResult first = _firstPass(sections, cues, <int, String>{
        0: '俺は三十四歳、住所不定無職',
        1: '人生を後悔している真っ最中だ',
        4: 'そうだろう',
      });
      final MatchResult filled = filler.fill(
        sections: sections,
        cues: cues,
        result: first,
      );
      final Map<int, CueMatch> after = _byCue(filled, cues);
      // 2、3 夹在 1 与 4 之间：回填；5、6 在末尾没有后锚点：保持未命中。
      expect(after[2]!.matched, isTrue);
      expect(after[3]!.matched, isTrue);
      expect(after[5]!.matched, isFalse);
      expect(after[6]!.matched, isFalse);
      expect(filled.matchedCues, 5);
      expect(after[2]!.score, lessThan(1.0));
      expect(after[2]!.score, greaterThanOrEqualTo(filler.minSimilarity));
      // 区间单调不重叠，且落在两锚点之间。
      expect(
        after[2]!.normCharStart,
        greaterThanOrEqualTo(after[1]!.normCharEnd),
      );
      expect(
        after[3]!.normCharStart,
        greaterThanOrEqualTo(after[2]!.normCharEnd),
      );
      expect(after[3]!.normCharEnd, lessThanOrEqualTo(after[4]!.normCharStart));
      // 第一遍已命中的原样保留。
      expect(after[0], same(first.matches[0]));

      replaceMatchedCueTextWithBookText(
        sections: sections,
        cues: cues,
        result: filled,
      );
      expect(cues[0].text, '俺は三十四歳、住所不定無職。');
      expect(cues[2].text, '着のみ着のまま家から叩き出された。');
      expect(cues[3].text, '多分、');
      expect(cues[4].text, 'そうだろう。');
      // 未命中的保留听写文本。
      expect(cues[5].text, '五人きょうだいの四番目として生まれた');
    });

    test('开头没有前锚点的未命中串保持未命中（片头/书名不在正文里）', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 'オーディブルがお届けする'),
        _cue(1, '朗読'),
        _cue(2, '俺は三十四歳住所不定無職'),
        _cue(3, '人生を後悔している真っ最中だ'),
      ];
      final MatchResult first = _firstPass(sections, cues, <int, String>{
        2: '俺は三十四歳、住所不定無職',
        3: '人生を後悔している真っ最中だ',
      });
      final MatchResult filled = filler.fill(
        sections: sections,
        cues: cues,
        result: first,
      );
      final Map<int, CueMatch> after = _byCue(filled, cues);
      expect(after[0]!.matched, isFalse);
      expect(after[1]!.matched, isFalse);
      expect(filled.matchedCues, 2);
    });

    test('间隙远长于 cue（正文被跳读）时只认领相似的子串，剩余不硬塞', () {
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, '俺は三十四歳住所不定無職'),
        // 朗读者跳过了「人生を後悔…」「着のみ着のまま家から」，只读了「たたき出された」。
        _cue(1, 'たたき出された'),
        _cue(2, 'そうだろう'),
      ];
      final MatchResult first = _firstPass(sections, cues, <int, String>{
        0: '俺は三十四歳、住所不定無職',
        2: 'そうだろう',
      });
      final MatchResult filled = filler.fill(
        sections: sections,
        cues: cues,
        result: first,
      );
      final CueMatch m = _byCue(filled, cues)[1]!;
      // 间隙约 33 字、cue 7 字：长度比不合理，不整段认领；滑窗找到「叩き出された」。
      expect(m.matched, isTrue);
      expect(m.normCharEnd - m.normCharStart, inInclusiveRange(5, 8));
      replaceMatchedCueTextWithBookText(
        sections: sections,
        cues: cues,
        result: filled,
      );
      // 「ら叩き出された」与「叩き出された」编辑距离同为 2（前者把首字 た 换成
      // 邻句尾字 ら，后者删掉一个 た），纯文本无法分辨；真实链路里前一句会先吃掉
      // 「ら」。这里只钉住「落在正确区间、没整段硬塞」。
      expect(cues[1].text, contains('叩き出された'));
    });

    test('单 cue 独占合理长度的间隙：整段认领，不看相似度', () {
      final List<EpubSection> secs = <EpubSection>[
        _section(0, 'あいうえお。かきくけこ。さしすせそ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 'あいうえお'),
        _cue(1, 'xxxxx'), // 听写完全错，但夹在两锚点之间
        _cue(2, 'さしすせそ'),
      ];
      final MatchResult first = _firstPass(secs, cues, <int, String>{
        0: 'あいうえお',
        2: 'さしすせそ',
      });
      final MatchResult filled = filler.fill(
        sections: secs,
        cues: cues,
        result: first,
      );
      final CueMatch m = _byCue(filled, cues)[1]!;
      expect(m.matched, isTrue);
      expect(m.normCharStart, 5);
      expect(m.normCharEnd, 10);
      replaceMatchedCueTextWithBookText(
        sections: secs,
        cues: cues,
        result: filled,
      );
      expect(cues[1].text, 'かきくけこ。');
    });

    test('单 cue 间隙长度比不合理时不硬塞（正文里两句被跳读）', () {
      final List<EpubSection> secs = <EpubSection>[
        _section(0, 'あいうえお。かきくけこ、たちつてと、なにぬねの。さしすせそ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 'あいうえお'),
        _cue(1, 'zz'),
        _cue(2, 'さしすせそ'),
      ];
      final MatchResult first = _firstPass(secs, cues, <int, String>{
        0: 'あいうえお',
        2: 'さしすせそ',
      });
      final MatchResult filled = filler.fill(
        sections: secs,
        cues: cues,
        result: first,
      );
      expect(_byCue(filled, cues)[1]!.matched, isFalse);
    });
  });

  group('AudioTextNormalizer.normalizeWithOffsets', () {
    test('偏移能把归一化区间换回原文（含标点与星光面字符）', () {
      const String original = '「目の前に崖がある。」踏み出して\n𠮷野家へ。';
      final NormalizedTextWithOffsets n =
          AudioTextNormalizer.normalizeWithOffsets(original);
      expect(n.text, AudioTextNormalizer.normalize(original));
      expect(n.starts.length, n.text.length);
      final int a = n.text.indexOf('目');
      expect(n.originalSlice(original, a, a + 8), '目の前に崖がある');
      // 星光面 𠮷 在归一化文本里占两个码元，两个码元映同一原文区间。
      final int y = n.text.indexOf('𠮷');
      expect(n.originalSlice(original, y, y + 2), '𠮷');
      expect(n.originalSlice(original, y, y + 3), '𠮷野');
    });
  });
}
