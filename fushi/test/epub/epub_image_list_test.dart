import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_book.dart';

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

    test('resolves ./ and %xx in src against chapter dir', () {
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body>'
            '<img src="./images/p%201.png"/>'
            '</body></html>',
      ]);
      // Chapter href is the root-level `ch0.xhtml` (dir = `.`), so `./images/...`
      // resolves to `images/...`. The percent-escape survives verbatim in [src]
      // (resolution is path-only) because that is what the WebView must request;
      // the decoded form is the reveal key, which is what identifies the file on
      // disk.
      expect(book.images.single.src, 'images/p%201.png');
      expect(book.images.single.revealKey, 'images/p 1.png');
    });

    test('drops a reference that escapes the book root', () {
      // `../shared/x.png` resolves outside the extracted directory, so no file
      // can back it: the image viewer's path guard rejects it and the gallery
      // could only ever draw a broken-image placeholder. It also has no valid
      // reveal key, so its spoiler state could not be stored either.
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body>'
            '<img src="../shared/x.png#frag"/>'
            '<img src="ok.png"/>'
            '</body></html>',
      ]);
      expect(book.images.map((EpubImageRef r) => r.src).toList(),
          <String>['ok.png']);
    });

    // BUG-2559: the reader's illustration gallery and the shelf-side
    // illustration library must list the same set of images. The gallery reads
    // [EpubBook.images]; the library walks the extracted directory. These tests
    // pin the cases where the two used to disagree -- each showed up to the user
    // as "the gallery is missing illustrations the shelf shows".

    test('collects SVG <image xlink:href> and <image href>', () {
      // Japanese fixed-layout books wrap a full-page JPEG in an SVG viewport and
      // carry no <img> at all -- covers and colour plates especially. Missing
      // these left such a book with an empty or near-empty gallery while its
      // shelf-side library showed every plate.
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body><div>'
            '<svg viewBox="0 0 1440 2048">'
            '<image width="1440" height="2048" xlink:href="image/plate.jpg"/>'
            '</svg>'
            '</div></body></html>',
        '<html><body>'
            '<svg><image href="image/svg2.jpg"/></svg>'
            '</body></html>',
      ]);
      expect(book.images.map((EpubImageRef r) => r.src).toList(),
          <String>['image/plate.jpg', 'image/svg2.jpg']);
    });

    test('collects an inline background-image', () {
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body>'
            "<div style=\"background-image:url('bg.jpg')\"></div>"
            '</body></html>',
      ]);
      expect(book.images.single.src, 'bg.jpg');
    });

    test('lists an image once, at its earliest occurrence', () {
      // A decorative separator reused in every chapter used to get one gallery
      // card per occurrence (85 cards for 22 files in one real book) while the
      // shelf side -- which walks files on disk -- showed it once.
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body><img src="sep.png"/><img src="a.png"/></body></html>',
        '<html><body><img src="sep.png"/></body></html>',
        '<html><body><img src="sep.png"/><img src="b.png"/></body></html>',
      ]);
      final List<EpubImageRef> imgs = book.images;
      expect(imgs.map((EpubImageRef r) => r.src).toList(),
          <String>['sep.png', 'a.png', 'b.png']);
      // Earliest occurrence wins, so "have I read past it?" is answered from the
      // first place the reader could have seen it.
      expect(imgs.first.chapterIndex, 0);
      expect(
          imgs.map((EpubImageRef r) => r.orderInBook).toList(), <int>[0, 1, 2]);
    });

    test('includes an OPF cover no chapter references, before the body', () {
      final EpubBook book = EpubBook(
        title: 'T',
        coverHref: 'images/cover.jpg',
        chapters: <EpubChapter>[
          EpubChapter(
            id: 'c0',
            href: 'text/ch0.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '<html><body><img src="../images/p1.png"/></body></html>',
          ),
        ],
      );
      final List<EpubImageRef> imgs = book.images;
      expect(imgs.map((EpubImageRef r) => r.src).toList(),
          <String>['images/cover.jpg', 'images/p1.png']);
      // The cover precedes the whole spine, so it is never "not read yet"...
      expect(imgs.first.chapterIndex, kEpubCoverChapterIndex);
      // ...but jumping to it still has to land on a real chapter.
      expect(imgs.first.jumpChapterIndex, 0);
    });

    test('a cover a chapter does reference keeps its cover position', () {
      final EpubBook book = EpubBook(
        title: 'T',
        coverHref: 'images/cover.jpg',
        chapters: <EpubChapter>[
          EpubChapter(
            id: 'c0',
            href: 'text/cover.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '<html><body>'
                '<svg><image xlink:href="../images/cover.jpg"/></svg>'
                '</body></html>',
          ),
        ],
      );
      expect(book.images.single.chapterIndex, kEpubCoverChapterIndex);
    });

    test('carries the in-chapter position on the reader-position scale', () {
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body>'
            '<img src="head.png"/>'
            '<p>あいうえおかきくけこ</p>'
            '<img src="middle.png"/>'
            '<p>さしすせそたちつてと</p>'
            '</body></html>',
      ]);
      final List<EpubImageRef> imgs = book.images;
      expect(imgs[0].normCharOffset, 0);
      // 10 of the chapter's 20 study characters precede it. Ruby readings are
      // not counted (same caliber as chapterCharacterCount), so this lands on
      // the same ruler as a stored reader position.
      expect(imgs[1].normCharOffset, 5000);
    });

    test('ruby readings do not shift an illustration position', () {
      final EpubBook book = _bookWithChapterHtml(<String>[
        '<html><body>'
            '<p><ruby>漢字<rt>かんじ</rt></ruby>あいうえおかきく</p>'
            '<img src="mid.png"/>'
            '<p>さしすせそたちつてと</p>'
            '</body></html>',
      ]);
      // Base text before the image is 2 + 8 = 10 of the chapter's 20 study
      // characters. Counting the three-kana reading too would make it 13/23 and
      // unblur the plate at the wrong moment.
      expect(book.images.single.normCharOffset, 5000);
    });

    test('an unreadable chapter does not take the whole list with it', () {
      final EpubBook book = EpubBook(
        title: 'T',
        chapters: <EpubChapter>[
          EpubChapter.lazy(
            id: 'c0',
            href: 'ch0.xhtml',
            mediaType: 'application/xhtml+xml',
            filePath: 'no/such/file.xhtml',
          ),
          EpubChapter(
            id: 'c1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '<html><body><img src="ok.png"/></body></html>',
          ),
        ],
      );
      expect(book.images.single.src, 'ok.png');
      expect(book.images.single.chapterIndex, 1);
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
