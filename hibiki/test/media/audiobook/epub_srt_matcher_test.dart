import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/epub_srt_matcher.dart';

AudioCue mkCue(int idx, String text) {
  return AudioCue()
    ..bookUid = 'test'
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

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

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

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

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

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

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

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

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
        mkSection(0, 'Hello world. The quick brown fox jumps over the lazy dog.'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, '名前はまだない。'),
      ];

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

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

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

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

    test('默认窗口 1500：旁白段 gap 无需显式扩窗', () {
      final String padding = 'あ' * 800; // < 1500 默认窗口
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は猫である。$paddingどこで生れたかとんと見当がつかぬ。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である。'),
        mkCue(1, 'どこで生れたかとんと見当がつかぬ。'),
      ];

      final MatchResult r =
          EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
    });

    test('模糊兜底：夹在两条已命中 cue 之间的微差 cue 仍被补上', () {
      // 场景：SubPlz 把 "曇" 听成 "雲"，或 EPUB 排版多加一字，cue 前后都精确
      // 命中，中间这条靠 gap-fill 救回。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(
          0,
          '昨日は雨だった今日は晴れ時々曇りだった明日は雪の予報だ',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '昨日は雨だった'),
        mkCue(1, '今日は晴れ時々雲りだった'), // 曇 → 雲（1 char 差，sim=0.917）
        mkCue(2, '明日は雪の予報だ'),
      ];

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isTrue,
          reason: 'gap-fill 应当补上相似度 0.917 的中间句');
      expect(r.matches[2].matched, isTrue);
      // 模糊命中的 score 介于阈值和 1.0 之间
      expect(r.matches[1].score, greaterThanOrEqualTo(0.85));
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

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matches[0].matched, isTrue);
      expect(r.matches[1].matched, isFalse);
      expect(r.matches[2].matched, isTrue);
    });

    test('模糊兜底：同一 gap 内多条未匹配 cue 顺序命中，不会错位', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(
          0,
          '最初の文はここにある第二の文が来て第三の文で締めくくる最後の文で終わる',
        ),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '最初の文はここにある'),
        // 以下两条各差 1 字，exact 失败，gap-fill 应按顺序补
        mkCue(1, '第二の文が末て'), // 来→末
        mkCue(2, '第三の文で絞めくくる'), // 締→絞
        mkCue(3, '最後の文で終わる'),
      ];

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 4);
      // 顺序单调
      for (int i = 1; i < 4; i++) {
        expect(r.matches[i].normCharStart,
            greaterThanOrEqualTo(r.matches[i - 1].normCharEnd),
            reason: 'cue $i 应落在 cue ${i - 1} 之后');
      }
    });

    test('模糊兜底：首条 cue 精确失败，靠后续锚点也能被补上（bolded 首句场景）', () {
      // 真实现象：EPUB 首句 `<b>…</b>` 后原作者多加 1 字标点/送り仮名差异，
      // SRT 听写与 EPUB 差 1 字 → exact 失败。旧 gap-fill 把 gapStart 钉在
      // probe 起点（= 首条已匹配 cue 的位置），gap 为空跳过。新版允许从
      // nextAnchor - searchWindow 开始向前兜底。
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '最初の文はここにある二番目の文で続く最後の文で終わる'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '最初の文はここにアる'), // る → ア 差 1 字
        mkCue(1, '二番目の文で続く'),
        mkCue(2, '最後の文で終わる'),
      ];

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matches[0].matched, isTrue, reason: '首条靠 gap-fill 补上');
      expect(r.matches[1].matched, isTrue);
      expect(r.matches[2].matched, isTrue);
      expect(r.matches[0].normCharStart, 0);
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

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

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

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

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
  });
}
