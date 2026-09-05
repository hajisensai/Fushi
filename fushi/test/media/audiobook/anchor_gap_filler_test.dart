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

    test('邻句区间吞掉短句（间隙为空）时，连同两侧邻句用编辑距离重切', () {
      final List<EpubSection> secs = <EpubSection>[
        _section(0, 'ＭＰが増えていくものだ。しかし、この世界では増えないらしい。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 'mpが増えていくものだ'),
        _cue(1, 'しかし'),
        _cue(2, 'この世界では増えないらしい'),
      ];
      // 第一遍 Dice 的 ±1 长度容忍让前一句多吃了「しか」、后一句从「し」起——
      // 短句「しかし」独占的间隙为零。
      final MatchResult first = _firstPass(secs, cues, <int, String>{
        0: 'mpが増えていくものだしか',
        2: 'しこの世界では増えないらしい',
      });
      final MatchResult filled = filler.fill(
        sections: secs,
        cues: cues,
        result: first,
      );
      final Map<int, CueMatch> by = _byCue(filled, cues);
      expect(filled.matchedCues, 3);
      expect(by[1]!.matched, isTrue);
      final String norm = AudioTextNormalizer.normalize(secs.single.text);
      expect(norm.substring(by[1]!.normCharStart, by[1]!.normCharEnd), 'しかし');
      // 邻句边界被纠正到字。
      expect(norm.substring(by[0]!.normCharStart, by[0]!.normCharEnd),
          'mpが増えていくものだ');
      expect(norm.substring(by[2]!.normCharStart, by[2]!.normCharEnd),
          'この世界では増えないらしい');
    });

    test('重切放不下任何中间句时锚点原样保留（不是正文里的感叹词）', () {
      final List<EpubSection> secs = <EpubSection>[
        _section(0, '家族三人でお出迎え。彼女の姿を見て。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, '家族三人でお出迎え'),
        _cue(1, 'ああ'),
        _cue(2, '彼女の姿を見て'),
      ];
      final MatchResult first = _firstPass(secs, cues, <int, String>{
        0: '家族三人でお出迎え',
        2: '彼女の姿を見て',
      });
      final MatchResult filled = filler.fill(
        sections: secs,
        cues: cues,
        result: first,
      );
      expect(filled.matchedCues, 2);
      expect(_byCue(filled, cues)[1]!.matched, isFalse);
      for (final int k in <int>[0, 2]) {
        expect(filled.matches[k].normCharStart, first.matches[k].normCharStart);
        expect(filled.matches[k].normCharEnd, first.matches[k].normCharEnd);
      }
    });

    test('整串纯かな⇄漢字零重叠但总长相称时按长度比例切开', () {
      final List<EpubSection> secs = <EpubSection>[
        _section(0, '召喚できるのは、魔獣、精霊、そして悪魔だ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, '召喚できるのは'),
        _cue(1, 'まじゅう'),
        _cue(2, 'せいれい'),
        _cue(3, 'そして悪魔だ'),
      ];
      final MatchResult first = _firstPass(secs, cues, <int, String>{
        0: '召喚できるのは',
        3: 'そして悪魔だ',
      });
      final MatchResult filled = filler.fill(
        sections: secs,
        cues: cues,
        result: first,
      );
      final Map<int, CueMatch> by = _byCue(filled, cues);
      expect(filled.matchedCues, 4);
      final String norm = AudioTextNormalizer.normalize(secs.single.text);
      expect(norm.substring(by[1]!.normCharStart, by[1]!.normCharEnd), '魔獣');
      expect(norm.substring(by[2]!.normCharStart, by[2]!.normCharEnd), '精霊');
    });

    test('邻句让位：多读出来的字从「替换邻句正文」改成「删除」，把正文让给中间句', () {
      final List<EpubSection> secs = <EpubSection>[
        _section(
          0,
          'ロキシーは続けた。まず魔術というのは古代長耳族が創りだしたものだと言われています。当時は違ったそうです。',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, 'ロキシーは続けた'),
        _cue(1, 'まず魔術というのは'),
        _cue(2, '古代ナガミミ族'), // 正文 古代長耳族（ルビ读法），字符几乎零重叠
        _cue(3, 'ハイエルフが作り出したものだといわれています'), // 朗读者把 長耳族 读成 ハイエルフ
        _cue(4, '当時は違ったそうです'),
      ];
      // 第一遍把「はいえるふ」替换到「は古代長耳族」上——与删掉它们代价相同，
      // 但更长的区间在 max(needle, 区间) 分母下相似度更高，Dice/编辑距离都会选它。
      final MatchResult first = _firstPass(secs, cues, <int, String>{
        0: 'ロキシーは続けた',
        1: 'まず魔術というの',
        3: 'は古代長耳族が創りだしたものだと言われています',
        4: '当時は違ったそうです',
      });
      final MatchResult filled = filler.fill(
        sections: secs,
        cues: cues,
        result: first,
      );
      final Map<int, CueMatch> by = _byCue(filled, cues);
      expect(filled.matchedCues, 5);
      final String norm = AudioTextNormalizer.normalize(secs.single.text);
      expect(
        norm.substring(by[2]!.normCharStart, by[2]!.normCharEnd),
        contains('古代長耳族'),
      );
      expect(
        norm.substring(by[3]!.normCharStart, by[3]!.normCharEnd),
        'が創りだしたものだと言われています',
      );
    });

    test('软锚点被重排丢弃后，剩余子串的比例认领要重新找邻句（不能拿被丢的锚当邻句）', () {
      final List<EpubSection> secs = <EpubSection>[
        _section(
          0,
          '前の文章はここまでである。次の長い文章がここに続いている。'
          'さらに別の長い文章もここに続いている。最後の文章で終わる。',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, '前の文章はここまでである'),
        _cue(1, 'うん'), // 正文里没有；第一遍却以 0.5 抢到了「うぜ」之类
        _cue(2, 'ざわざわ'), // 旁白拟声，正文没有 → 永远放不下
        _cue(3, '次の長い文章がここにつづいている'), // 続→つづ
        _cue(4, 'さらに別の長い文章もここにつづいている'),
        _cue(5, '最後の文章で終わる'),
      ];
      final MatchResult first = _firstPass(secs, cues, <int, String>{
        0: '前の文章はここまでである',
        1: 'る次', // 伪命中：跨句吃字（である 的尾 + 次 的头）
        5: '最後の文章で終わる',
      });
      // 之前这里在 _splitProportionally 里读被丢弃锚点的区间 → RangeError(-1)。
      final MatchResult filled = filler.fill(
        sections: secs,
        cues: cues,
        result: first,
      );
      final Map<int, CueMatch> by = _byCue(filled, cues);
      expect(by[3]!.matched, isTrue);
      expect(by[4]!.matched, isTrue);
      expect(by[1]!.matched, isFalse, reason: 'うん 正文里没有，重排后应被丢弃');
      expect(by[2]!.matched, isFalse);
      expect(filled.matchedCues, 4);
    });

    test('伪短锚点（うん 命中到别处）连同串一起重排，长句先落位、短句退回自己的位置', () {
      final List<EpubSection> secs = <EpubSection>[
        _section(
          0,
          '遠まわしな皮肉とかもやめておいたほうがいいですね。ふむ。すごい癇癪持ちなのだろうか。しかし迫害を受けているという話だ。',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0, '遠回しな皮肉とかもやめておいた方がいいですね'),
        _cue(1, 'うん'), // 正文 ふむ
        _cue(2, 'すごいかんしゃく持ちなのだろうか'),
        _cue(3, 'しかし迫害を受けているという話だ'),
      ];
      // 第一遍：うん 以 0.5 抢到了「うか」（だろうか 的尾巴），把 2 挤到零间隙。
      final String norm = AudioTextNormalizer.normalize(secs.single.text);
      final MatchResult first = _firstPass(secs, cues, <int, String>{
        0: '遠まわしな皮肉とかもやめておいたほうがいいですね',
        1: 'うか',
        3: 'しかし迫害を受けているという話だ',
      });
      final MatchResult filled = filler.fill(
        sections: secs,
        cues: cues,
        result: first,
      );
      final Map<int, CueMatch> by = _byCue(filled, cues);
      expect(
        norm.substring(by[2]!.normCharStart, by[2]!.normCharEnd),
        'すごい癇癪持ちなのだろうか',
      );
      // うん 退回 ふむ（长度相称整段认领）。
      expect(norm.substring(by[1]!.normCharStart, by[1]!.normCharEnd), 'ふむ');
      expect(filled.matchedCues, 4);
    });
  });

  group('replaceMatchedCueTextWithBookText 的空白折叠', () {
    test('英文正文：词间空白保留一个空格，换行/缩进折成空格，首尾空白去掉', () {
      final List<EpubSection> en = <EpubSection>[
        _section(
          0,
          'Mr. and Mrs. Dursley, of number four, Privet Drive,\n'
          '    were proud to say that they were perfectly normal, thank you very much. '
          'They were the last people you’d expect to be involved in anything strange.',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        _cue(0,
            'Mr. and Mrs. Dursley, of No. 4 Privet Drive, were proud to say that they were perfectly normal'),
        _cue(1,
            'They were the last people you would expect to be involved in anything strange'),
      ];
      final MatchResult first = _firstPass(en, cues, <int, String>{
        0: 'Mr. and Mrs. Dursley, of number four, Privet Drive, were proud to say that they were perfectly normal',
        1: 'They were the last people you’d expect to be involved in anything strange',
      });
      replaceMatchedCueTextWithBookText(
          sections: en, cues: cues, result: first);
      expect(
        cues[0].text,
        // 归一化区间只到 normal；逗号属于本句，后面的空格与下一句一起留下。
        'Mr. and Mrs. Dursley, of number four, Privet Drive, '
        'were proud to say that they were perfectly normal,',
      );
      expect(
        cues[1].text,
        'They were the last people you’d expect to be involved in anything strange.',
      );
    });

    test('日文正文：换行/全角空格照旧去掉，不在假名汉字之间塞空格', () {
      final List<EpubSection> ja = <EpubSection>[
        _section(0, '　俺は三十四歳、\n住所不定無職。\n人生を後悔している。'),
      ];
      final List<AudioCue> cues = <AudioCue>[_cue(0, '俺は三十四歳住所不定無職')];
      final MatchResult first = _firstPass(ja, cues, <int, String>{
        0: '俺は三十四歳、住所不定無職',
      });
      replaceMatchedCueTextWithBookText(
          sections: ja, cues: cues, result: first);
      expect(cues[0].text, '俺は三十四歳、住所不定無職。');
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
