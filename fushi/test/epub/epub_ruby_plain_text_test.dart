import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_book.dart';

EpubBook _bookWithHtml(String html) {
  return EpubBook(
    title: 'test',
    chapters: <EpubChapter>[
      EpubChapter(
        id: 'ch1',
        href: 'ch1.xhtml',
        mediaType: 'application/xhtml+xml',
        html: html,
      ),
    ],
  );
}

/// 守卫：[EpubBook.chapterPlainTextWithRuby] 的文本必须与 [EpubBook.chapterPlainText]
/// 逐码元相同——`fushi-cue://` 偏移、阅读位置、统计水位都建立在后者之上。
void main() {
  const List<String> corpus = <String>[
    '<p><ruby>漢字<rt>かんじ</rt></ruby>を読む</p>',
    '<p><ruby>漢<rt>かん</rt>字<rt>じ</rt></ruby></p>',
    '<p><ruby><rb>漢字</rb><rp>（</rp><rt>かんじ</rt><rp>）</rp></ruby></p>',
    '<p><ruby>漢字<rtc><rt>かんじ</rt></rtc></ruby></p>',
    '<p>  私は <ruby> 猫 <rt> ねこ </rt></ruby>\n\tである。  </p>',
    '<div>\n　<ruby>眩<rt>まぶ</rt></ruby>しい 光</div><p>次</p>',
    '<p>&amp;<ruby>A&lt;B<rt>x</rt></ruby>&#x6F22;&#23383;</p>',
    '<p><ruby>外<rt>そと</rt></ruby><ruby>側<rt>がわ</rt></ruby></p>',
    '<p>ruby <ruby><rt>だけ</rt></ruby> 空基底</p>',
    '<p><ruby>読<rt></rt></ruby>み</p>',
    '<p><ruby>頭<rt>あたま</rt></ruby></p>',
    '<p><span><ruby>微笑<rt>ほほえ</rt></ruby>み<ruby>浮<rt>う</rt></ruby>かべ</span></p>',
  ];

  test('文本与 chapterPlainText 逐码元相同', () {
    for (final String html in corpus) {
      final EpubBook book = _bookWithHtml(html);
      expect(
        book.chapterPlainTextWithRuby(0).text,
        book.chapterPlainText(0),
        reason: html,
      );
    }
  });

  test('ruby 区间指向纯文本里的基底、读音取 rt', () {
    final EpubPlainTextWithRuby r =
        _bookWithHtml(corpus[0]).chapterPlainTextWithRuby(0);
    expect(r.text, '漢字を読む');
    expect(r.rubies, hasLength(1));
    expect(r.text.substring(r.rubies[0].start, r.rubies[0].end), '漢字');
    expect(r.rubies[0].reading, 'かんじ');
  });

  test('mono-ruby 多段 rt 拼成一处整词读音', () {
    final EpubPlainTextWithRuby r =
        _bookWithHtml(corpus[1]).chapterPlainTextWithRuby(0);
    expect(r.rubies.single.reading, 'かんじ');
    expect(r.text.substring(r.rubies.single.start, r.rubies.single.end), '漢字');
  });

  test('rb / rp / rtc 形态与空白折叠下区间仍指向基底', () {
    for (final String html in <String>[
      corpus[2],
      corpus[3],
      corpus[4],
      corpus[5]
    ]) {
      final EpubPlainTextWithRuby r =
          _bookWithHtml(html).chapterPlainTextWithRuby(0);
      expect(r.rubies, hasLength(1), reason: html);
      final EpubRubyAnnotation a = r.rubies.single;
      expect(
        r.text.substring(a.start, a.end).trim(),
        r.text.substring(a.start, a.end),
        reason: '区间不含首尾空白: $html',
      );
    }
    final EpubPlainTextWithRuby cat =
        _bookWithHtml(corpus[4]).chapterPlainTextWithRuby(0);
    expect(cat.text, '私は 猫 である。');
    expect(cat.text.substring(cat.rubies.single.start, cat.rubies.single.end),
        '猫');
    expect(cat.rubies.single.reading, 'ねこ');
    final EpubPlainTextWithRuby glare =
        _bookWithHtml(corpus[5]).chapterPlainTextWithRuby(0);
    expect(
        glare.text
            .substring(glare.rubies.single.start, glare.rubies.single.end),
        '眩');
  });

  test('相邻两处 ruby 各自独立、按序', () {
    final EpubPlainTextWithRuby r =
        _bookWithHtml(corpus[7]).chapterPlainTextWithRuby(0);
    expect(r.rubies.map((EpubRubyAnnotation a) => a.reading),
        <String>['そと', 'がわ']);
    expect(r.rubies[0].end, lessThanOrEqualTo(r.rubies[1].start));
  });

  test('空基底或空读音的 ruby 不产出区间', () {
    expect(
        _bookWithHtml(corpus[8]).chapterPlainTextWithRuby(0).rubies, isEmpty);
    expect(
        _bookWithHtml(corpus[9]).chapterPlainTextWithRuby(0).rubies, isEmpty);
  });

  test('越界章号返回空', () {
    final EpubBook book = _bookWithHtml(corpus[0]);
    expect(book.chapterPlainTextWithRuby(-1).text, '');
    expect(book.chapterPlainTextWithRuby(3).rubies, isEmpty);
  });
}
