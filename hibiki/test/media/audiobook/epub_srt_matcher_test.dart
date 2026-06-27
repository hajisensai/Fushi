import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

AudioCue mkCue(int idx, String text) {
  return AudioCue()
    ..bookKey = 'test'
    ..chapterHref = 'srt://default'
    ..sentenceIndex = idx
    ..textFragmentId = 'srt://$idx'
    ..text = text
    ..startMs = idx * 1000
    ..endMs = idx * 1000 + 900
    ..audioFileIndex = 0;
}

EpubSection mkSection(int i, String text, {String? href}) {
  return EpubSection(
    index: i,
    href: href ?? 'ch${i + 1}.xhtml',
    text: text,
  );
}

void main() {
  group('EpubSrtMatcher.match', () {
    test('完美匹配：全命中，rate=1.0', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。名前はまだない。どこで生れたかとんと見当がつかぬ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, '名前はまだない。'),
        mkCue(2, 'どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.totalCues, 3);
      expect(r.matchedCues, 3);
      expect(r.matchRate, 1.0);
      for (final CueMatch m in r.matches) {
        expect(m.matched, isTrue);
        expect(m.sectionIndex, 0);
        expect(m.score, 1.0);
      }
      // cue 顺序单调
      expect(r.matches[0].normCharStart, lessThan(r.matches[1].normCharStart));
      expect(r.matches[1].normCharStart, lessThan(r.matches[2].normCharStart));
    });

    test('跨章节：cue 分布在两个 section 全命中', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。名前はまだない。'),
        mkSection(1, 'どこで生れたかとんと見当がつかぬ。何でも薄暗いじめじめした所で泣いていた事だけは記憶している。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, '名前はまだない。'),
        mkCue(2, 'どこで生れたかとんと見当がつかぬ。'),
        mkCue(3, '何でも薄暗いじめじめした所で泣いていた事だけは記憶している。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 4);
      expect(r.matches[0].sectionIndex, 0);
      expect(r.matches[1].sectionIndex, 0);
      expect(r.matches[2].sectionIndex, 1);
      expect(r.matches[3].sectionIndex, 1);
    });

    test('带噪音：cue 与 EPUB 有标点/空白差异仍命中（白名单 normalize 剥掉）', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は、猫である! 名前は、まだ無い。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である'),
        mkCue(1, '名前はまだ無い'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
    });

    test('SRT ＊ 前缀（叙述标记）被 normalize 剥掉后仍命中正文', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。名前はまだない。どこで生れたかとんと見当がつかぬ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '＊吾輩は猫である。'),
        mkCue(1, '＊名前はまだない。'),
        mkCue(2, '＊どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 3);
    });

    test('EPUB 有旁白插入（段落 gap）：cue 仍单调命中', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(
          0,
          '【前書き】この本は古典である。'
          '吾輩は猫である。'
          '（注：著者コメント）'
          '名前はまだない。'
          '『章末メモ』'
          'どこで生れたかとんと見当がつかぬ。',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, '名前はまだない。'),
        mkCue(2, 'どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult r = EpubSrtMatcher.match(
        sections: sections,
        cues: cues,
        searchWindow: 300,
      );

      expect(r.matchedCues, 3);
      expect(r.matches[0].normCharStart, lessThan(r.matches[1].normCharStart));
      expect(r.matches[1].normCharStart, lessThan(r.matches[2].normCharStart));
    });

    test('完全无关文本：matchRate ≈ 0', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(
            0, 'Hello world. The quick brown fox jumps over the lazy dog.'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, '名前はまだない。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 0);
      expect(r.matchRate, 0.0);
    });

    test('searchWindow 过小：大 gap 的后续 cue 漏匹配', () {
      final String padding = 'あ' * 1000;
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。$padding どこで生れたかとんと見当がつかぬ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, 'どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult rNarrow = EpubSrtMatcher.match(
        sections: sections,
        cues: cues,
        searchWindow: 50,
      );
      expect(rNarrow.matches[0].matched, isTrue);
      expect(rNarrow.matches[1].matched, isFalse);

      final MatchResult rWide = EpubSrtMatcher.match(
        sections: sections,
        cues: cues,
        searchWindow: 2000,
      );
      expect(rWide.matchedCues, 2);
    });

    test('空 cues 返回空结果', () {
      final MatchResult r = EpubSrtMatcher.match(
        sections: <EpubSection>[mkSection(0, 'abc')],
        cues: <AudioCue>[],
      );
      expect(r.matches, isEmpty);
      expect(r.matchRate, 0.0);
    });

    test('空 sections：所有 cue 未匹配', () {
      final MatchResult r = EpubSrtMatcher.match(
        sections: <EpubSection>[],
        cues: <AudioCue>[mkCue(0, '何か')],
      );
      expect(r.matches.length, 1);
      expect(r.matches[0].matched, isFalse);
      expect(r.matchRate, 0.0);
    });

    test('英文 ASCII 大小写差异视为等同', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, 'Hello World. This is a test sentence.'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, 'hello world'),
        mkCue(1, 'THIS IS A TEST SENTENCE'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
    });

    test('起点检测：音频前置的 OP 朗读 cue 不在 EPUB 里不会拖偏 cursor', () {
      // 前 3 条 cue 是音频开场白（书里没有），从第 4 条起是正文。probe
      // 阶段应找到第 4 条的全书位置（0），把 cursor 对到正文开头。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。名前はまだない。どこで生れたかとんと見当がつかぬ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, 'オーディオブック特典収録'),
        mkCue(1, '朗読スタジオ提供'),
        mkCue(2, '（効果音）'),
        mkCue(3, '吾輩は猫である。'),
        mkCue(4, '名前はまだない。'),
        mkCue(5, 'どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult r = EpubSrtMatcher.match(
        sections: sections,
        cues: cues,
        searchWindow: 100,
      );

      expect(r.matches[0].matched, isFalse);
      expect(r.matches[1].matched, isFalse);
      expect(r.matches[2].matched, isFalse);
      expect(r.matches[3].matched, isTrue);
      expect(r.matches[4].matched, isTrue);
      expect(r.matches[5].matched, isTrue);
    });

    test('一次失配不会让 cursor 跑飞：后续 cue 仍能命中', () {
      // 中间插一条根本不在 EPUB 里的 cue，cursor 不动，下一条正常命中。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。名前はまだない。どこで生れたかとんと見当がつかぬ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, '存在しないセリフ'),
        mkCue(2, '名前はまだない。'),
        mkCue(3, 'どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult r = EpubSrtMatcher.match(
        sections: sections,
        cues: cues,
      );

      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isFalse);
      expect(r.matches[2].matched, isTrue);
      expect(r.matches[3].matched, isTrue);
    });

    test('默认窗口 200：大旁白 gap 需要显式扩窗', () {
      final String padding = 'あ' * 800; // > 200 默认窗口
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。$paddingどこで生れたかとんと見当がつかぬ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, 'どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isFalse);
    });

    test('模糊兜底：夹在两条已命中 cue 之间的微差 cue 仍被补上', () {
      // 场景：SubPlz 把 "曇" 听成 "雲"，或 EPUB 排版多加一字，cue 前后都精确
      // 命中，中间这条靠单次 Dice 滑窗救回。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(
          0,
          '昨日は雨だった今日は晴れ時々曇りだった明日は雪の予報だ',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '昨日は雨だった'),
        mkCue(1, '今日は晴れ時々雲りだった'), // 曇 → 雲（1 char 差，sim≈0.818）
        mkCue(2, '明日は雪の予報だ'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isTrue, reason: '单次滑窗应当补上高于默认阈值的中间句');
      expect(r.matches[2].matched, isTrue);
      // 模糊命中的 score 介于阈值和 1.0 之间
      expect(r.matches[1].score,
          greaterThanOrEqualTo(EpubSrtMatcher.defaultSimilarityThreshold));
      expect(r.matches[1].score, lessThan(1.0));
      // 位置夹在前后锚点之间
      expect(r.matches[1].normCharStart,
          greaterThanOrEqualTo(r.matches[0].normCharEnd));
      expect(r.matches[1].normCharEnd,
          lessThanOrEqualTo(r.matches[2].normCharStart));
    });

    test('模糊兜底：相似度低于阈值不补（避免把噪音塞进 gap）', () {
      // gap 内文本与 cue 差一半以上字符，sim 远低于 0.85，应保持 unmatched。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(
          0,
          '昨日は雨だった全然違う文章がここに入る明日は雪の予報だ',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '昨日は雨だった'),
        mkCue(1, '今日は晴れ時々曇りだった'), // 与 gap 内文本毫不相关
        mkCue(2, '明日は雪の予報だ'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isFalse);
      expect(r.matches[2].matched, isTrue);
    });

    test('单次滑窗：同一 gap 内多条未匹配 cue 不回溯补齐', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(
          0,
          '最初の文はここにある第二の文が来て第三の文で締めくくる最後の文で終わる',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '最初の文はここにある'),
        // 以下两条各差 1 字，但当前 matcher 不做逐字回溯，避免 O(n²) 导入。
        mkCue(1, '第二の文が末て'), // 来→末
        mkCue(2, '第三の文で絞めくくる'), // 締→絞
        mkCue(3, '最後の文で終わる'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isFalse);
      expect(r.matches[2].matched, isFalse);
      expect(r.matches[3].matched, isTrue);
      expect(r.matches[3].normCharStart,
          greaterThanOrEqualTo(r.matches[0].normCharEnd));
    });

    test('起点检测：首条 cue 精确失败时从后续精确锚点开始', () {
      // 真实现象：EPUB 首句 `<b>…</b>` 后原作者多加 1 字标点/送り仮名差异，
      // SRT 听写与 EPUB 差 1 字 → exact 失败。当前 matcher 不回溯补首条，
      // 直接从后续精确锚点开始，避免导入时做指数级补救。
      // 注：あ→ア 的差异已被片假名归一化吸收，改用汉字差异来测试。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '最初の文はここにある二番目の文で続く最後の文で終わる'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '最初の文はここに有る'), // ある → 有る 差 1 字
        mkCue(1, '二番目の文で続く'),
        mkCue(2, '最後の文で終わる'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matches[0].matched, isFalse);
      expect(r.matches[1].matched, isTrue);
      expect(r.matches[2].matched, isTrue);
      expect(r.matches[1].normCharStart, 10);
    });

    test('模糊兜底：尾段无后锚仍可在章末窗口内兜底', () {
      // 最后一条 cue 精确失败，但后面再没有已匹配 cue。此时 gap 终点 = big.length，
      // 仍允许在正文末尾附近做一次模糊。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '最初の文はここにある最後の文で終了する'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '最初の文はここにある'),
        mkCue(1, '最後の文で終了すル'), // る → ル 差 1 字
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
    });

    test('全角/ASCII 交叉：EPUB 用半角 cue 用全角仍命中', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, 'Hello World 第1話が始まる'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, 'Ｈｅｌｌｏ　Ｗｏｒｌｄ'),
        mkCue(1, '第１話が始まる'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
    });

    test('片假名↔平假名：EPUB 用片假名 cue 用平假名仍命中', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, 'コーヒーを飲む。ケーキを食べる。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, 'こーひーを飲む。'),
        mkCue(1, 'けーきを食べる。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
      expect(r.matches[0].score, 1.0);
      expect(r.matches[1].score, 1.0);
    });

    test('片假名↔平假名：cue 用片假名 EPUB 用平假名仍命中', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, 'こーひーを飲む。けーきを食べる。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, 'コーヒーを飲む。'),
        mkCue(1, 'ケーキを食べる。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
    });

    test('normCharStart/End 在 section 内且单调', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, 'あいうえおかきくけこさしすせそ'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, 'あいうえお'),
        mkCue(1, 'かきくけこ'),
        mkCue(2, 'さしすせそ'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 3);
      for (final CueMatch m in r.matches) {
        expect(m.normCharStart, greaterThanOrEqualTo(0));
        expect(m.normCharEnd, greaterThan(m.normCharStart));
        expect(m.normCharEnd, lessThanOrEqualTo(15));
      }
      expect(r.matches[0].normCharStart, 0);
      expect(r.matches[1].normCharStart, 5);
      expect(r.matches[2].normCharStart, 10);
    });

    test('TODO-906 收紧虚高：短虚词 cue 不再被 unigram Dice 模糊命中', () {
      // 正文里根本没有「うん」「はい」这两条短 cue 的精确子串，但它们规范化后
      // 都 < defaultProbeMinLen(6)，旧实现走 unigram Dice 极易在正文任意位置
      // 凑够字符重叠误判命中，虚高匹配率。收紧后这类短 cue 只接受精确子串。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。名前はまだない。どこで生れたかとんと見当がつかぬ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, 'うん'), // 短虚词，正文无此精确子串
        mkCue(2, 'はい'), // 短虚词，正文无此精确子串
        mkCue(3, 'どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      // 两条正文长 cue 命中，两条短虚词 cue 不再误判命中。
      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isFalse, reason: '短虚词 cue 不走模糊不应命中');
      expect(r.matches[2].matched, isFalse, reason: '短虚词 cue 不走模糊不应命中');
      expect(r.matches[3].matched, isTrue);
      expect(r.matchedCues, 2);
    });

    test('TODO-906 收紧虚高：短 cue 若精确出现在正文仍命中（不误伤真命中）', () {
      // 「はい」精确出现在正文里，快速通道(精确 indexOf)仍应命中——收紧只关掉
      // 短 cue 的模糊兜底，不影响其精确命中。短 cue 放在长锚点之后，确保起点
      // 检测把 cursor 对到锚点开头（短 cue 不参与起点探测），随后短 cue 在窗口
      // 内精确命中。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, 'わたしは尋ねました。はい、それで終わりです。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, 'わたしは尋ねました。'),
        mkCue(1, 'はい'),
        mkCue(2, 'それで終わりです。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isTrue, reason: '短 cue 精确出现仍走快速通道命中');
      expect(r.matches[2].matched, isTrue);
      expect(r.matchedCues, 3);
    });

    test('TODO-906 两位小数：matchRate*100 格式化为两位小数字符串', () {
      // 显示层契约：toast 用 (matchRate*100).toStringAsFixed(2)。验证常见非整除
      // 比例格式化结果，确保 UI 落点稳定显示两位小数。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。名前はまだない。どこで生れたかとんと見当がつかぬ。'),
      ];
      // 3 条 cue 命中 2 条 → 2/3 = 0.6666... → 66.67%
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, 'この文は正文に存在しない長い別のセリフだ'),
        mkCue(2, 'どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
      expect(r.totalCues, 3);
      final String pctStr = (r.matchRate * 100).toStringAsFixed(2);
      expect(pctStr, '66.67');
    });

    test('TODO-906 两位小数：满匹配显示 100.00', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。名前はまだない。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, '名前はまだない。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect((r.matchRate * 100).toStringAsFixed(2), '100.00');
    });
  });
}
