import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';

/// TODO-723: builds an [EpubBook] whose chapters carry the given inline XHTML
/// bodies (eager constructor, so [EpubChapter.html] returns them verbatim).
EpubBook _bookWithChapterHtml(List<String> htmls) {
  return EpubBook(
    title: 'T',
    chapters: <EpubChapter>[
      for (int i = 0; i < htmls.length; i++)
        EpubChapter(
          id: 'c$i',
          href: 'ch$i.xhtml',
          mediaType: 'application/xhtml+xml',
          html: htmls[i],
        ),
    ],
  );
}

void main() {
  group('EpubBook.images', () {
    test('empty book -> empty list', () {
      expect(_bookWithChapterHtml(<String>[]).images, isEmpty);
    });

    test('chapters with no <img> contribute nothing', () {
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body><p>no images here</p></body></html>',
        '<html><body><p>still nothing</p></body></html>',
      ]);
      expect(book.images, isEmpty);
    });

    test('collects every <img> in spine + DOM order with continuous order', () {
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body><img src="a.png"/><p>x</p><img src="b.png"/></body></html>',
        '<html><body><p>no image chapter</p></body></html>',
        '<html><body><img src="c.jpg"/></body></html>',
      ]);
      final List<EpubImageRef> imgs = book.images;
      expect(imgs.map((EpubImageRef r) => r.src).toList(),
          <String>['a.png', 'b.png', 'c.jpg']);
      expect(
          imgs.map((EpubImageRef r) => r.orderInBook).toList(), <int>[0, 1, 2]);
      expect(imgs.map((EpubImageRef r) => r.chapterIndex).toList(),
          <int>[0, 0, 2]);
    });

    test('skips empty / whitespace-only src', () {
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body><img src=""/><img src="   "/><img src="ok.png"/></body></html>',
      ]);
      expect(book.images.map((EpubImageRef r) => r.src).toList(),
          <String>['ok.png']);
      expect(book.images.single.orderInBook, 0);
    });

    test('resolves ./, %xx and #fragment in src against chapter dir', () {
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body>'
            '<img src="./images/p%201.png"/>'
            '<img src="../shared/x.png#frag"/>'
            '</body></html>',
      ]);
      final List<EpubImageRef> imgs = book.images;
      expect(imgs.length, 2);
      // Chapter href is the root-level `ch0.xhtml` (dir = `.`), so `./images/...`
      // resolves to `images/...`; `../shared/...` keeps the leading `..` segment.
      // Percent-escapes and `#fragment` survive verbatim (resolution is path-only).
      expect(imgs[0].src, 'images/p%201.png');
      expect(imgs[1].src, '../shared/x.png#frag');
    });

    test('is cached -- same instance returned on second access', () {
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body><img src="a.png"/></body></html>',
      ]);
      final List<EpubImageRef> first = book.images;
      final List<EpubImageRef> second = book.images;
      expect(identical(first, second), isTrue);
    });
  });

  group('resolveImageHref', () {
    test('nested chapter + ../images sibling -> root-relative', () {
      expect(resolveImageHref('OEBPS/text/ch1.xhtml', '../images/p1.png'),
          'OEBPS/images/p1.png');
    });

    test('nested chapter + ./ same dir -> chapter dir', () {
      expect(resolveImageHref('OEBPS/text/ch1.xhtml', './img.png'),
          'OEBPS/text/img.png');
    });

    test('nested chapter + bare name -> chapter dir', () {
      expect(resolveImageHref('OEBPS/text/ch1.xhtml', 'img.png'),
          'OEBPS/text/img.png');
    });

    test('root-level chapter + subdir src -> subdir from root', () {
      expect(resolveImageHref('ch.xhtml', 'images/x.png'), 'images/x.png');
    });

    test('root-level chapter + bare name -> bare name', () {
      expect(resolveImageHref('ch0.xhtml', 'a.png'), 'a.png');
    });

    test('strips a leading slash on the chapter href', () {
      expect(resolveImageHref('/OEBPS/text/ch1.xhtml', '../images/p1.png'),
          'OEBPS/images/p1.png');
    });

    test('book.images holds the resolved root-relative href', () {
      final EpubBook book = EpubBook(
        title: 'T',
        chapters: <EpubChapter>[
          EpubChapter(
            id: 'c0',
            href: 'OEBPS/text/ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '<html><body><img src="../images/p1.png"/></body></html>',
          ),
        ],
      );
      expect(book.images.single.src, 'OEBPS/images/p1.png');
    });
  });
}
