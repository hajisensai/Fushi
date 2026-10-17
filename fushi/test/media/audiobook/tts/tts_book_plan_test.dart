import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/tts/tts_book_plan.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_engine/epub/epub_book.dart';

EpubPlainTextWithRuby _plain(
  String text, [
  List<EpubRubyAnnotation> rubies = const <EpubRubyAnnotation>[],
]) =>
    EpubPlainTextWithRuby(text: text, rubies: rubies);

EpubChapter _chapter(String id, String body, {bool nav = false}) =>
    EpubChapter(
      id: id,
      href: '$id.xhtml',
      mediaType: 'application/xhtml+xml',
      html: '<html><body>$body</body></html>',
      isNav: nav,
    );

void main() {
  group('splitTtsText', () {
    test('splits at sentence enders and keeps closing quotes', () {
      final List<TtsTextSegment> segs = splitTtsText(
        _plain('「おはよう。」と言った。次の文！'),
        maxLength: 120,
      );
      expect(
        segs.map((TtsTextSegment s) => s.text),
        <String>['「おはよう。」', 'と言った。', '次の文！'],
      );
      for (final TtsTextSegment s in segs) {
        expect(s.spokenText, s.text);
      }
    });

    test('a closing quote ends a line even without a full stop', () {
      final List<TtsTextSegment> segs = splitTtsText(
        _plain('ないわー」「うるせ、お前だろーが。'),
        maxLength: 120,
      );
      expect(
        segs.map((TtsTextSegment s) => s.text),
        <String>['ないわー」', '「うるせ、お前だろーが。'],
      );
    });

    test('ruby bases stay whole: spoken text uses the reading', () {
      // 漢字 at [0,2) read かんじ.
      final List<TtsTextSegment> segs = splitTtsText(
        _plain('漢字を読む。', const <EpubRubyAnnotation>[
          EpubRubyAnnotation(start: 0, end: 2, reading: 'かんじ'),
        ]),
        maxLength: 120,
      );
      expect(segs, hasLength(1));
      expect(segs.single.text, '漢字を読む。');
      expect(segs.single.spokenText, 'かんじを読む。');
      expect(segs.single.start, 0);
      expect(segs.single.end, 6);
    });

    test('over-long sentences break at a comma before the hard limit', () {
      final String text = '${'あ' * 10}、${'い' * 10}。';
      final List<TtsTextSegment> segs = splitTtsText(
        _plain(text),
        maxLength: 15,
      );
      expect(segs.first.text, '${'あ' * 10}、');
      expect(segs.map((TtsTextSegment s) => s.text).join(), text);
      for (final TtsTextSegment s in segs) {
        expect(s.spokenText.length, lessThanOrEqualTo(15));
      }
    });

    test('whitespace between sentences is not part of any segment', () {
      final List<TtsTextSegment> segs = splitTtsText(
        _plain('一つ目。 二つ目。'),
        maxLength: 120,
      );
      expect(segs.map((TtsTextSegment s) => s.text), <String>['一つ目。', '二つ目。']);
      expect(segs[1].start, 5);
    });
  });

  group('buildTtsBookPlanSync', () {
    test('skips nav chapters and encodes normalized match offsets', () {
      final EpubBook book = EpubBook(
        title: 'b',
        chapters: <EpubChapter>[
          _chapter('nav', '<p>目次</p>', nav: true),
          _chapter('c1', '<p>今日は晴れ。</p><p>明日は雨！</p>'),
        ],
      );
      final TtsBookPlan plan = buildTtsBookPlanSync(book, maxLength: 120);
      expect(plan.length, 2);
      expect(plan.sentences.every((TtsPlanSentence s) => s.section == 1), isTrue);

      final String plain = book.chapterPlainText(1);
      final String normalized = AudioTextNormalizer.normalize(plain);
      for (final TtsPlanSentence s in plan.sentences) {
        // 句子的匹配区间切出来的归一化文本 == 句子原文归一化：阅读器高亮靠它对上正文。
        expect(
          normalized.substring(s.matchStart, s.matchEnd),
          AudioTextNormalizer.normalize(s.text),
        );
        expect(s.href, 'c1.xhtml');
      }
      expect(plan.sentences[0].matchEnd, plan.sentences[1].matchStart);
    });

    test('block boundaries split sentences and mark paragraph ends', () {
      final EpubBook book = EpubBook(
        title: 'b',
        chapters: <EpubChapter>[
          _chapter(
            'c0',
            '<h2>第一章</h2><p>一。二。</p><p>◆◆◆</p><p>三</p><p>四。</p>',
          ),
        ],
      );
      final TtsBookPlan plan = buildTtsBookPlanSync(book, maxLength: 120);
      // 标题、不带句号的段落各自成句；分隔行不进计划也不粘到下一句。
      expect(
        plan.sentences.map((TtsPlanSentence s) => s.text),
        <String>['第一章', '一。', '二。', '三', '四。'],
      );
      expect(
        plan.sentences.map((TtsPlanSentence s) => s.endsParagraph),
        <bool>[true, false, true, true, true],
      );
      expect(
        plan.sentences.map((TtsPlanSentence s) => s.sceneBreakAfter),
        <bool>[false, false, true, false, false],
      );
    });

    test('start lookups find the sentence at or after a position', () {
      final EpubBook book = EpubBook(
        title: 'b',
        chapters: <EpubChapter>[
          _chapter('c0', '<p>一。二。</p>'),
          _chapter('c1', '<p>三。</p>'),
        ],
      );
      final TtsBookPlan plan = buildTtsBookPlanSync(book, maxLength: 120);
      expect(plan.length, 3);
      expect(plan.indexAtStudyOffset(0, 0), 0);
      expect(plan.indexAtStudyOffset(1, 0), 2);
      expect(plan.indexAtStudyOffset(5, 0), -1);
      final TtsPlanSentence second = plan.sentences[1];
      expect(plan.indexAtMatchStart(second.section, second.matchStart), 1);
    });
  });

  group('mergeShortTtsSentences', () {
    test('merges short sentences inside a paragraph only', () {
      final EpubBook book = EpubBook(
        title: 'b',
        chapters: <EpubChapter>[
          _chapter('c0', '<p>はい。うん。そうだね、今日はとても良い天気だと思う。</p><p>次。</p>'),
        ],
      );
      final TtsBookPlan raw = buildTtsBookPlanSync(book, maxLength: 120);
      expect(raw.length, 4);
      final TtsBookPlan merged = mergeShortTtsSentences(raw, maxLength: 120);
      expect(merged.length, 2, reason: 'short lines merge, the next paragraph stays');
      expect(merged.sentences.first.text, startsWith('はい。うん。'));
      expect(merged.sentences.first.matchStart, raw.sentences.first.matchStart);
      expect(merged.sentences.first.matchEnd, raw.sentences[2].matchEnd);
      expect(merged.sentences.last.text, '次。');
    });

    test('never exceeds the engine input limit', () {
      final EpubBook book = EpubBook(
        title: 'b',
        chapters: <EpubChapter>[_chapter('c0', '<p>あ。い。う。え。お。</p>')],
      );
      final TtsBookPlan merged = mergeShortTtsSentences(
        buildTtsBookPlanSync(book, maxLength: 120),
        maxLength: 4,
      );
      for (final TtsPlanSentence s in merged.sentences) {
        expect(s.spokenText.length, lessThanOrEqualTo(4));
      }
    });
  });
}
