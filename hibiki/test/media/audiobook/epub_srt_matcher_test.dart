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
        expect(m.score, greaterThan(0.9));
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

    test('带噪音：cue 与 EPUB 有标点/空白差异仍命中', () {
      final List<EpubSection> sections = <EpubSection>[
        mkSection(0, '吾輩は、猫である! 名前は、まだ無い。'),
      ];
      final List<AudioCue> cues = <AudioCue>[
        mkCue(0, '吾輩は猫である'),
        mkCue(1, '名前はまだ無い'),
      ];

      final MatchResult r = EpubSrtMatcher.match(sections: sections, cues: cues);

      expect(r.matchedCues, 2);
      for (final CueMatch m in r.matches) {
        expect(m.score, greaterThan(0.6));
      }
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
