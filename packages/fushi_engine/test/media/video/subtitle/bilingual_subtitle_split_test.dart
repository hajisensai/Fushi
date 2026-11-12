// 反馈 E1pq561P2q：从中日双语字幕里拆出日语轨（字幕工作台「拆出双语字幕中的日语」）。
import 'package:test/test.dart';

import 'package:fushi_engine/media/video/subtitle/bilingual_subtitle_split.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_content_language.dart';

SubtitleTextCue _c(int start, String text) =>
    SubtitleTextCue(startMs: start, endMs: start + 1000, text: text);

void main() {
  group('extractJapaneseFromBilingual', () {
    test('same-cue two lines, Japanese on top: keeps the Japanese line', () {
      final BilingualSplitResult r = extractJapaneseFromBilingual(
        <SubtitleTextCue>[_c(0, 'おはよう\n早上好'), _c(2000, '行ってきます\n我出门了')],
      );
      expect(r.japanesePosition, BilingualJapanesePosition.first);
      expect(r.cues.map((SubtitleTextCue c) => c.text), <String>[
        'おはよう',
        '行ってきます',
      ]);
      expect(r.cues.first.startMs, 0);
      expect(r.cues.first.endMs, 1000);
      expect(r.droppedCues, 0);
    });

    test('Japanese at the bottom and ASS literal \\N separators', () {
      final BilingualSplitResult r = extractJapaneseFromBilingual(
        <SubtitleTextCue>[_c(0, r'早上好\Nおはよう'), _c(2000, r'我出门了\Nいってきます')],
      );
      expect(r.japanesePosition, BilingualJapanesePosition.last);
      expect(r.cues.map((SubtitleTextCue c) => c.text), <String>[
        'おはよう',
        'いってきます',
      ]);
    });

    test('kanji-only Japanese line follows the film-wide position', () {
      final BilingualSplitResult r = extractJapaneseFromBilingual(
        <SubtitleTextCue>[
          _c(0, 'おはよう\n早上好'),
          _c(2000, '了解\n明白'),
          _c(4000, '行ってきます\n我出门了'),
        ],
      );
      expect(r.cues.map((SubtitleTextCue c) => c.text), <String>[
        'おはよう',
        '了解',
        '行ってきます',
      ]);
    });

    test('separate cues with identical timing are merged before picking', () {
      final BilingualSplitResult r = extractJapaneseFromBilingual(
        <SubtitleTextCue>[
          _c(0, 'おはよう'),
          _c(0, '早上好'),
          _c(2000, '行ってきます'),
          _c(2000, '我出门了'),
        ],
      );
      expect(r.cues, <SubtitleTextCue>[_c(0, 'おはよう'), _c(2000, '行ってきます')]);
      expect(r.droppedCues, 0);
    });

    test('Chinese-only single cues (signs, notes) are dropped and counted', () {
      final BilingualSplitResult r = extractJapaneseFromBilingual(
        <SubtitleTextCue>[
          _c(0, 'おはよう\n早上好'),
          _c(2000, '字幕组：翻译校对'),
          _c(4000, '♪～'),
        ],
      );
      expect(r.cues.map((SubtitleTextCue c) => c.text), <String>['おはよう', '♪～']);
      expect(r.droppedCues, 1);
    });

    test('neutral lines follow their neighbouring track', () {
      final BilingualSplitResult r = extractJapaneseFromBilingual(
        <SubtitleTextCue>[_c(0, '……\nえっ\n……\n诶')],
      );
      // 首个「……」挨着日语行，留；第二个「……」前后都是一行之隔，取前面的日语行。
      expect(r.cues.single.text, '……\nえっ\n……');
    });

    test('Japanese text and timing are never altered', () {
      const String line = '　これは、テスト！　';
      final BilingualSplitResult r = extractJapaneseFromBilingual(
        <SubtitleTextCue>[
          const SubtitleTextCue(
            startMs: 1234,
            endMs: 5678,
            text: '$line\n这是测试',
          ),
        ],
      );
      expect(r.cues.single.text, line.trim());
      expect(r.cues.single.startMs, 1234);
      expect(r.cues.single.endMs, 5678);
    });

    test('output is detected as Japanese, not bilingual', () {
      final List<SubtitleTextCue> input = <SubtitleTextCue>[
        for (int i = 0; i < 6; i++) _c(i * 2000, 'これはテストです$i\n这是测试第$i句话'),
      ];
      final String before = subtitleTextCuesToSrt(input);
      expect(
        detectSubtitleContentLanguage(before),
        SubtitleContentLanguage.bilingualJaZh,
      );
      final String after = subtitleTextCuesToSrt(
        extractJapaneseFromBilingual(input).cues,
      );
      expect(
        detectSubtitleContentLanguage(after),
        SubtitleContentLanguage.japanese,
      );
    });
  });

  test('subtitleTextCuesToSrt writes numbered SRT blocks', () {
    expect(
      subtitleTextCuesToSrt(<SubtitleTextCue>[
        const SubtitleTextCue(startMs: 3723004, endMs: 3725000, text: 'あ\nい'),
      ]),
      '1\n01:02:03,004 --> 01:02:05,000\nあ\nい\n\n',
    );
  });
}
