import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';

void main() {
  group('normalizeHref', () {
    test('trims whitespace', () {
      expect(normalizeHref('  path/to/file.xhtml  '), 'path/to/file.xhtml');
    });

    test('normalizes backslashes to forward slashes', () {
      expect(normalizeHref('OEBPS\\chapter1.xhtml'), 'OEBPS/chapter1.xhtml');
    });

    test('strips leading slash', () {
      expect(normalizeHref('/OEBPS/file.xhtml'), 'OEBPS/file.xhtml');
    });

    test('strips fragment identifier', () {
      expect(normalizeHref('ch1.xhtml#section2'), 'ch1.xhtml');
    });

    test('strips query string', () {
      expect(normalizeHref('ch1.xhtml?foo=bar'), 'ch1.xhtml');
    });

    test('handles combined: backslash + leading slash + fragment', () {
      expect(normalizeHref('/OEB\\ch.xhtml#frag'), 'OEB/ch.xhtml');
    });

    test('empty string returns empty', () {
      expect(normalizeHref(''), '');
    });
  });

  group('fallbackMimeType', () {
    test('returns text/css for .css', () {
      expect(fallbackMimeType('style.css'), 'text/css');
    });

    test('returns image/jpeg for .jpg', () {
      expect(fallbackMimeType('cover.jpg'), 'image/jpeg');
    });

    test('returns image/jpeg for .jpeg', () {
      expect(fallbackMimeType('photo.jpeg'), 'image/jpeg');
    });

    test('returns image/png for .png', () {
      expect(fallbackMimeType('icon.png'), 'image/png');
    });

    test('returns image/svg+xml for .svg', () {
      expect(fallbackMimeType('diagram.svg'), 'image/svg+xml');
    });

    test('returns font/woff2 for .woff2', () {
      expect(fallbackMimeType('font.woff2'), 'font/woff2');
    });

    test('returns text/html for .xhtml', () {
      expect(fallbackMimeType('chapter.xhtml'), 'text/html');
    });

    test('case insensitive extension matching', () {
      expect(fallbackMimeType('FILE.CSS'), 'text/css');
      expect(fallbackMimeType('cover.PNG'), 'image/png');
    });
  });

  group('EpubBook.chapterPlainText', () {
    test('extracts plain text from HTML', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '<html><body><p>Hello World</p></body></html>',
          ),
        ],
      );

      expect(book.chapterPlainText(0), 'Hello World');
    });

    test('strips ruby annotations (rt, rp, rtc)', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html:
                '<html><body><p><ruby>漢字<rt>かんじ</rt></ruby>を読む</p></body></html>',
          ),
        ],
      );

      final text = book.chapterPlainText(0);
      expect(text, contains('漢字'));
      expect(text, isNot(contains('かんじ')));
      expect(text, contains('を読む'));
    });

    test('collapses whitespace', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '<html><body><p>  Hello   World  </p></body></html>',
          ),
        ],
      );

      expect(book.chapterPlainText(0), 'Hello World');
    });

    test('returns empty for out-of-bounds index', () {
      final book = EpubBook(title: 'Test', chapters: []);

      expect(book.chapterPlainText(0), '');
      expect(book.chapterPlainText(-1), '');
    });
  });

  group('EpubBook.resolveInternalLink', () {
    test('resolves valid hoshi internal link to chapter index', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
          EpubChapter(
            id: 'ch2',
            href: 'OEBPS/ch2.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      final result =
          book.resolveInternalLink('https://hoshi.local/epub/OEBPS/ch2.xhtml');
      expect(result, isNotNull);
      expect(result!.chapterIndex, 1);
      expect(result.fragment, isNull);
    });

    test('resolves Apple custom-scheme internal link to chapter index', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
          EpubChapter(
            id: 'ch2',
            href: 'OEBPS/ch2.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      final result = book.resolveInternalLink(
        '${ReaderHibikiSource.kResourceScheme}://hoshi.local/epub/OEBPS/ch2.xhtml#frag',
      );
      expect(result, isNotNull);
      expect(result!.chapterIndex, 1);
      expect(result.fragment, 'frag');
    });

    test('resolves link with fragment', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      final result = book
          .resolveInternalLink('https://hoshi.local/epub/ch1.xhtml#section2');
      expect(result, isNotNull);
      expect(result!.chapterIndex, 0);
      expect(result.fragment, 'section2');
    });

    test('returns null for non-hoshi URL', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      expect(book.resolveInternalLink('https://example.com/page'), isNull);
    });

    test('returns null for malformed URL', () {
      final book = EpubBook(title: 'Test', chapters: []);
      expect(book.resolveInternalLink('://broken'), isNull);
    });

    test('returns null for href not matching any chapter', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      expect(
          book.resolveInternalLink(
              'https://hoshi.local/epub/nonexistent.xhtml'),
          isNull);
    });

    // BUG-097: the WebView resolves a relative `<a href>` against the document
    // URL, so the clicked link can carry `./` / `../` / duplicate slashes that
    // the canonicalized stored href does not. These must still resolve (else the
    // caller opens a blank OS browser for hoshi.local instead of jumping).
    group('BUG-097 path normalization (../ ./ // resolve, not external)', () {
      final book = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'ch1',
            href: 'OEBPS/ch1.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
          EpubChapter(
            id: 'ch2',
            href: 'OEBPS/text/ch2.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );

      test('parent-relative (../) link resolves to the chapter', () {
        final result = book.resolveInternalLink(
            'https://hoshi.local/epub/OEBPS/text/../ch1.xhtml');
        expect(result, isNotNull);
        expect(result!.chapterIndex, 0);
      });

      test('current-dir (./) link resolves to the chapter', () {
        final result = book.resolveInternalLink(
            'https://hoshi.local/epub/OEBPS/./text/ch2.xhtml#frag');
        expect(result, isNotNull);
        expect(result!.chapterIndex, 1);
        expect(result.fragment, 'frag');
      });

      test('duplicate slashes resolve to the chapter', () {
        final result = book
            .resolveInternalLink('https://hoshi.local/epub/OEBPS//ch1.xhtml');
        expect(result, isNotNull);
        expect(result!.chapterIndex, 0);
      });
    });
  });

  // TODO-796: the TOC sheet maps each entry's stored href to a spine chapter
  // index through [EpubBook.chapterIndexForHref], which must use the SAME
  // canonicalization as [resolveInternalLink]. A cover/front-matter TOC entry
  // whose href differs only by `./` / `%xx` / letter case previously resolved
  // to -1 with a raw `==`, was silently dropped from the flattened TOC, and the
  // real first chapter slid into row 0 — clicking "Cover" jumped to chapter 1.
  group('EpubBook.chapterIndexForHref (TODO-796 cover TOC matching)', () {
    final book = EpubBook(
      title: 'Test',
      chapters: [
        EpubChapter(
          id: 'cover',
          href: 'OEBPS/cover.xhtml',
          mediaType: 'application/xhtml+xml',
          html: '',
        ),
        EpubChapter(
          id: 'ch1',
          href: 'OEBPS/text/chapter1.xhtml',
          mediaType: 'application/xhtml+xml',
          html: '',
        ),
      ],
    );

    test('exact stored href resolves to its spine index', () {
      expect(book.chapterIndexForHref('OEBPS/cover.xhtml'), 0);
      expect(book.chapterIndexForHref('OEBPS/text/chapter1.xhtml'), 1);
    });

    test('cover href with fragment still resolves (not -1)', () {
      expect(book.chapterIndexForHref('OEBPS/cover.xhtml#top'), 0);
    });

    test('current-dir (./) cover href resolves', () {
      expect(book.chapterIndexForHref('OEBPS/./cover.xhtml'), 0);
    });

    test('parent-relative (../) href resolves', () {
      expect(book.chapterIndexForHref('OEBPS/text/../cover.xhtml'), 0);
    });

    test('duplicate slashes resolve', () {
      expect(book.chapterIndexForHref('OEBPS//cover.xhtml'), 0);
    });

    test('percent-encoded cover href resolves', () {
      // %2F is '/', %63%6F%76%65%72 is 'cover' — a TOC that points at an escaped
      // path must still land on the spine chapter, not -1.
      expect(book.chapterIndexForHref('OEBPS%2Fcover.xhtml'), 0);
    });

    test('case-only difference recovers the spine chapter (cover fallback)',
        () {
      // Filesystem-case-insensitive authoring: TOC says Cover.XHTML, spine has
      // cover.xhtml. resolveInternalLink stays case-sensitive (case-sensitive
      // FS), but the TOC matcher case-insensitive fallback recovers it so the
      // cover row is not dropped.
      expect(book.chapterIndexForHref('OEBPS/Cover.XHTML'), 0);
    });

    test('percent-encoded Japanese cover href resolves', () {
      final jpBook = EpubBook(
        title: 'Test',
        chapters: [
          EpubChapter(
            id: 'cover',
            href: '表紙.xhtml',
            mediaType: 'application/xhtml+xml',
            html: '',
          ),
        ],
      );
      expect(
        jpBook.chapterIndexForHref('%E8%A1%A8%E7%B4%99.xhtml'),
        0,
      );
    });

    test('null / empty href returns -1', () {
      expect(book.chapterIndexForHref(null), -1);
      expect(book.chapterIndexForHref(''), -1);
      expect(book.chapterIndexForHref('   '), -1);
    });

    test('href owned by no spine chapter returns -1 (dirty TOC item skipped)',
        () {
      // A cover entry pointing straight at the image (not a spine document) is
      // genuinely unlocatable and must still be skippable — but only AFTER the
      // canonical + case-insensitive passes both fail, never via a stale ==.
      expect(book.chapterIndexForHref('OEBPS/images/cover.jpg'), -1);
    });

    test('malformed percent escape degrades to literal compare (no throw)', () {
      // A stray '%' must not abort the whole jump; it falls back to a literal
      // canonical compare instead of throwing.
      expect(book.chapterIndexForHref('OEBPS/cover%.xhtml'), -1);
      expect(book.chapterIndexForHref('OEBPS/cover.xhtml'), 0);
    });
  });

  group('EpubResource.readBytes', () {
    test('returns in-memory bytes if available', () {
      final resource = EpubResource(
        mediaType: 'text/css',
        bytes: Uint8List.fromList([1, 2, 3]),
      );

      expect(resource.readBytes(), Uint8List.fromList([1, 2, 3]));
    });

    test('returns null if no bytes and no filePath', () {
      final resource = EpubResource(mediaType: 'text/css');

      expect(resource.readBytes(), isNull);
    });

    test('returns null if filePath does not exist', () {
      final resource = EpubResource(
        mediaType: 'text/css',
        filePath: '/nonexistent/path/file.css',
      );

      expect(resource.readBytes(), isNull);
    });
  });
}
