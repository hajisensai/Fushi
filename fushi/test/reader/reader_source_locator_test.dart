import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi/src/reader/reader_source_locator.dart';
import 'package:fushi_anki/fushi_anki.dart';

EpubBook _book(String body) => EpubBook(
      title: 'Source',
      chapters: <EpubChapter>[
        EpubChapter(
            id: 'c',
            href: 'c.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '<html><body>$body</body></html>'),
      ],
    );

CardSourceLink _link({int chapter = 0, int start = 0, int? length}) =>
    CardSourceLink(
        kind: CardSourceKind.book,
        uid: 'book-1',
        sourceId: '11111111-1111-4111-8111-111111111111',
        chapterIndex: chapter,
        charOffset: start,
        charLength: length);

void main() {
  test('a missing chapter is rejected instead of using a saved position', () {
    expect(() => validateReaderSourceLocator(_book('本文'), _link(chapter: 1)),
        throwsFormatException);
  });

  test('ruby and punctuation do not extend a source character range', () {
    final EpubBook book =
        _book('<p>「<ruby>猫<rt>ねこ</rt><rp>（</rp></ruby>だ。」</p>');
    validateReaderSourceLocator(book, _link(start: 1, length: 1));
    expect(() => validateReaderSourceLocator(book, _link(start: 2)),
        throwsFormatException);
    expect(() => validateReaderSourceLocator(book, _link(start: 1, length: 2)),
        throwsFormatException);
  });

  test('Latin units preserve DOM node boundaries used by normalized offsets',
      () {
    final EpubBook book = _book('<p>hel<b>lo</b> world!</p>');
    // Three text-node units; neither raw HTML length nor the two words in
    // flattened chapterPlainText is the reader selection coordinate.
    validateReaderSourceLocator(book, _link(start: 2, length: 1));
    expect(() => validateReaderSourceLocator(book, _link(start: 3)),
        throwsFormatException);
  });

  test('empty image chapter permits its origin but no character selection', () {
    final EpubBook book = _book('<img src="cover.jpg"/>');
    validateReaderSourceLocator(book, _link());
    expect(() => validateReaderSourceLocator(book, _link(length: 1)),
        throwsFormatException);
    expect(() => validateReaderSourceLocator(book, _link(start: 1)),
        throwsFormatException);
  });

  test('reader rejects stale sources before audio start and bookmark fallback',
      () {
    final String source = File(
      'lib/src/pages/implementations/reader_fushi_page.dart',
    ).readAsStringSync();
    final int init = source.indexOf('Future<void> _initBookInner()');
    final int validate =
        source.indexOf('validateReaderSourceLocator(_book!, sourceLink)', init);
    expect(validate, greaterThan(init));
    expect(
        validate, lessThan(source.indexOf('_resolveAudioSlot().then', init)));
    expect(validate, lessThan(source.indexOf('final Bookmark? bm =', init)));
  });
}
