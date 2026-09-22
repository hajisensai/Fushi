import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_audio/fushi_audio.dart';

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

    test('起点检测：片头出版社名只在书尾版权页精确命中，不把游标钉到书尾（第 13 卷 0% 事故）', () {
      // 真机复现（無職転生 13 卷，ASR 字幕 8221 条）：前 15 条 cue 里只有
      // 「株式会社KADOKAWA」精确命中，位置在最后一节版权页；旧起点检测取「任一精确
      // 命中的最小偏移」→ 游标 128600/128690，之后全部 miss、匹配率 0%。
      // 正文句子与 ASR 听写有假名/汉字差（精确失败），只能靠全书模糊佐证 + 余量检查。
      final String body = List<String>.generate(
        40,
        (int i) => '第$i段落は物語の本文であって聴き取りとほぼ同じである。',
      ).join();
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '無職転生　異世界行ったら本気だす　十三'),
        mkSection(
            1,
            '目覚め。それは甘美なる匂いによってもたらされた。'
            'まどろみの中でふわりと香る愛おしい匂いだ。'
            '驚きに目を開くと目の前に神がいた。$body'),
        mkSection(2, '発行　株式会社KADOKAWA　東京都千代田区富士見'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, 'オーディブルがお届けする最高のライトノベル'),
        mkCue(1, 'どうぞお楽しみください'),
        mkCue(2, '理不尽な孫の手チョ'),
        mkCue(3, '株式会社KADOKAW'), // 版权页精确命中（ASR 吞尾字也一样）
        mkCue(4, 'それは甘美なるにおいによってもたらされた'), // 匂い→におい
        mkCue(5, 'まどろみの中でふわりと香るいとおしい匂いだ'), // 愛おしい→いとおしい
        mkCue(6, '驚きに目を開くと目の前に神がいた'),
        for (int i = 0; i < 40; i++)
          mkCue(7 + i, '第$i段落は物語の本文であって聴き取りとほぼ同じである'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      // 正文全部命中；版权页那条不许成为起点（余量检查淘汰，且没有同伙佐证）。
      expect(r.matches[4].matched, isTrue);
      expect(r.matches[5].matched, isTrue);
      expect(r.matches[6].matched, isTrue);
      expect(r.matches[6].sectionIndex, 1);
      for (int i = 7; i < cues.length; i++) {
        expect(r.matches[i].matched, isTrue, reason: 'cue #$i');
      }
      expect(r.matchRate, greaterThan(0.9));
    });

    // 真机复现（『妹さえいればいい。』2 卷，ASR 4719 条）：片头「登場人物」页
    // 不在 EPUB 里，20 多条 cue 连 miss；其中「大野アシュリー」在正文第一次出现
    // 是第 18 节，旧恢复扫描（单条 cue 在 [cursor..] indexOf）就把游标钉到那里，
    // 序章起整段正文全 miss、之后每次恢复只会再往后跳，整本只命中 79/4719。
    // 现在恢复走聚簇佐证：序章 cue 在第 1 节互相佐证 20 多条，压过孤零零的人名。
    // 两档 filler：200 句（≈6000 字，人名在簇外）与 60 句（≈1800 字，人名落进
    // 序章簇的 3000 字内）——后者钉的是收敛规则：簇内乱序的撞中（cue 序最靠前、
    // 命中却在后）不许成为链首，否则序章前 20 条全落在游标之前。
    for (final int fillerSentences in <int>[200, 60]) {
      test(
          'BUG-2599 恢复扫描：片头登场人物页攒满 miss 后，单条人名精确命中不把游标钉到书中段（filler $fillerSentences 句）',
          () {
        final List<String> prologue = List<String>.generate(
          30,
          (int i) => '序章第$i文は朝起きて洗面所に行くと妹がいたという本文である。',
        );
        final String filler = List<String>.generate(
          fillerSentences,
          (int i) => '中盤第$i文は登場人物の名前を一切含まない埋め草である。',
        ).join();
        final List<EpubSection> sections = <EpubSection>[
          mkSection(0, '妹さえいればいい。２'),
          mkSection(1, prologue.join()),
          mkSection(2, filler),
          mkSection(3, '彼女──税理士・大野アシュリーは、サディスティックな笑みを浮かべながら会釈し、'),
        ];
        final List<String> intro = <String>[
          for (int i = 0; i < 22; i++) '登場人物その$i：架空の肩書きが読み上げられる',
        ];
        final List<AudioCue> cues = <AudioCue>[
          for (int i = 0; i < intro.length; i++) mkCue(i, intro[i]),
          mkCue(intro.length, '大野アシュリー'),
          for (int i = 0; i < prologue.length; i++)
            mkCue(intro.length + 1 + i, prologue[i]),
        ];

        final MatchResult r =
            EpubSrtMatcher.match(sections: sections, cues: cues);

        // 人名那条不许成为锚点。
        expect(r.matches[intro.length].matched, isFalse);
        for (int i = 0; i < prologue.length; i++) {
          final CueMatch m = r.matches[intro.length + 1 + i];
          expect(m.matched, isTrue, reason: '序章 cue #$i');
          expect(m.sectionIndex, 1, reason: '序章 cue #$i');
        }
      });
    }

    test('BUG-2599 恢复扫描：选错卷（全书零命中）时全书模糊扫描有整次总预算，不随 cue 数线性放大', () {
      // 每 20 条 miss 试一次恢复、每次最多 8 条全书 Dice：4700 条 cue × 8 万字正文
      // 单遍实测 58 s（旧实现 2.6 s），app 侧还要跑 4 遍。预算用完后恢复只靠精确
      // 命中；这里用 dice 探针计数验证总次数被 [recoverFuzzyBudgetTotal] 封顶。
      final String big = List<String>.generate(
        3000,
        (int i) => '別巻第$i文はこの音声とは無関係な本文が延々と続いている。',
      ).join();
      final List<EpubSection> sections = <EpubSection>[mkSection(0, big)];
      final List<AudioCue> cues = <AudioCue>[
        for (int i = 0; i < 1200; i++) mkCue(i, '音声側第$i文はどの本にも存在しない読み上げである。'),
      ];
      final Stopwatch clock = Stopwatch()..start();
      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);
      clock.stop();
      expect(r.matchedCues, 0);
      // 1200/20 = 60 次尝试 × 8 = 480 次全书 Dice 若不封顶；封顶后 ≤ 64 + 起点 24。
      // 单次全书 Dice 在这本 9 万字的书上约 20~40 ms：不封顶要十几秒。
      expect(clock.elapsed, lessThan(const Duration(seconds: 8)),
          reason: '恢复扫描的模糊配额必须有整次总预算');
    });

    test('BUG-2599 恢复扫描：音频章节顺序与 spine 不一致时，佐证够多允许游标回退', () {
      final List<String> ch1 = List<String>.generate(
        30,
        (int i) => '第一章第$i文は前半の物語であり読み上げと一致している。',
      );
      final List<String> ch2 = List<String>.generate(
        30,
        (int i) => '第二章第$i文は後半の物語であり読み上げと一致している。',
      );
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, ch1.join()),
        mkSection(1, ch2.join()),
      ];
      // 音频先读第二章再读第一章。
      final List<AudioCue> cues = <AudioCue>[
        for (int i = 0; i < ch2.length; i++) mkCue(i, ch2[i]),
        for (int i = 0; i < ch1.length; i++) mkCue(ch2.length + i, ch1[i]),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      for (int i = 0; i < ch2.length; i++) {
        expect(r.matches[i].sectionIndex, 1, reason: '第二章 cue #$i');
      }
      // 前 20 条第一章 cue 攒 miss，之后恢复扫描把游标搬回第 0 节。
      for (int i = EpubSrtMatcher.defaultMaxConsecutiveMisses;
          i < ch1.length;
          i++) {
        final CueMatch m = r.matches[ch2.length + i];
        expect(m.matched, isTrue, reason: '第一章 cue #$i');
        expect(m.sectionIndex, 0, reason: '第一章 cue #$i');
      }
    });

    test('BUG-2599 恢复扫描：只有一条泛用短语在远处撞中时游标不动，后续正文仍在原位命中', () {
      final List<String> body = List<String>.generate(
        40,
        (int i) => '本文第$i文は物語であって聴き取りとほぼ同じである。',
      );
      body[35] = 'ありがとうございます。';
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, body.join()),
      ];
      final List<AudioCue> cues = <AudioCue>[];
      int idx = 0;
      for (int i = 0; i < 5; i++) {
        cues.add(mkCue(idx++, body[i]));
      }
      // 20 条不在书里的旁白攒满 miss，紧接着一条泛用短语在 35 句之外精确命中。
      for (int i = 0; i < 20; i++) {
        cues.add(mkCue(idx++, '旁白その$i：本には存在しない語り'));
      }
      cues.add(mkCue(idx++, 'ありがとうございます'));
      // 再来一长串旁白，让这次恢复扫描的探测范围里只有那一条撞中。
      for (int i = 0; i < EpubSrtMatcher.recoverScanLimit; i++) {
        cues.add(mkCue(idx++, '続く旁白その$i：これも本にはない'));
      }
      final int bodyFrom = cues.length;
      for (int i = 5; i < 35; i++) {
        cues.add(mkCue(idx++, body[i]));
      }

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      // 旧实现：泛用短语把游标钉到第 35 句，正文第 5~34 句全部落在游标之后 miss。
      int matchedBody = 0;
      for (int i = bodyFrom; i < cues.length; i++) {
        if (r.matches[i].matched) matchedBody++;
      }
      expect(matchedBody, greaterThanOrEqualTo(25),
          reason: '正文第 5~34 句应大多命中（只允许攒 miss 期间的损失）');
      expect(r.matches[bodyFrom + 29].matched, isTrue);
    });

    test('起点检测：首条 cue 精确失败时仍从正文开头起步，首条靠窗口内模糊命中', () {
      // 真实现象：EPUB 首句 `<b>…</b>` 后原作者多加 1 字标点/送り仮名差异，
      // SRT 听写与 EPUB 差 1 字 → exact 失败。起点检测对精确失败的探测 cue 做全书
      // 模糊（≥ 阈值）——首条本身就把起点定到 0，主循环再在窗口内模糊命中它；
      // 旧实现只认精确，起点落到第二条、首条永远 miss。
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

      expect(r.matches[0].matched, isTrue);
      expect(r.matches[0].normCharStart, 0);
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

    test('TODO-906 收紧虚高：短 cue 散字异位时 gate 必须挡住模糊误命中（判别性）', () {
      // 判别性语料：needle「あい」(2字 < defaultProbeMinLen=6) 在正文里没有
      // 精确子串「あい」，但正文夹了异位散字「いあ」——含 あ/い 两字符却顺序
      // 颠倒。开模糊(allowFuzzy=true)时短 cue 走 unigram Dice，{あ,い} 对窗口
      // {い,あ} 完全重叠 → score=1.0 ≥ 0.8 误命中；当前 gate(allowFuzzy=false)
      // 关掉短 cue 的模糊兜底 → 只剩精确 indexOf，正文无「あい」精确子串 → 不命中。
      //
      // 【gate load-bearing】此断言锁住 epub_srt_matcher.dart 的 allowFuzzy 门控：
      // 若把 `nc.length >= defaultProbeMinLen` 改回 `true`（=移除 TODO-906 收紧），
      // 短 cue 会被 unigram Dice 误命中 → matchedCues 变 3、matches[1] 变 true →
      // 本测试变红。（上一版以「吾輩は猫である…」为语料的守卫对该门控 vacuous：
      // うん/はい 即使开模糊也凑不够 0.8 阈值，删门控不改变结果，故换成散字异位。）
      final List<EpubSection> sections = <EpubSection>[
        // 锚点1（精确命中推进 cursor）→ 异位散字「いあ」→ 锚点2。
        mkSection(0, 'わたしは尋ねました。いあそれで終わりです。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, 'わたしは尋ねました。'),
        mkCue(1, 'あい'), // 2 字短 cue：正文无精确「あい」，仅异位散字「いあ」
        mkCue(2, 'それで終わりです。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      // 两条锚点 cue 命中，短 cue 因 gate 挡住模糊兜底而不命中。
      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isFalse,
          reason: '短 cue 散字异位：gate 挡住模糊，精确子串又缺失，不应命中');
      expect(r.matches[2].matched, isTrue);
      expect(r.matchedCues, 2, reason: '移除 allowFuzzy 门控会让此值变 3（守卫即变红）');
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
