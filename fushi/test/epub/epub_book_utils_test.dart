import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';

import '../pages/reader_fushi_page_source_corpus.dart';

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

    // BUG-1203（承接 BUG-1199）：阅读器拦截器判「这是不是一个该走 HTML 处理链的
    // 内容文档」的**真相源是 EPUB 自己声明的 media-type**，扩展名表只在声明缺失时
    // 兜底。BUG-1199 只往扩展名表补了 `.htm` / `.xht`，那是治标——EPUB 不规定内容
    // 文档的扩展名，只规定 media-type，下一本用别的怪扩展名（甚至无扩展名）的书会
    // 以完全相同的方式整本空白且不写任何错误日志。
    //
    // 本组不复刻拦截器的谓词（复刻会漂移，是假绿的常见来源），而是：
    // ① 直接测拦截器真正调用的那个公开谓词 [isHtmlMediaType]；
    // ② 直接测拦截器真正走的那条查找链 [EpubBook.mediaType]（声明优先 / 扩展名兜底）；
    // ③ 用源码守卫钉住拦截器方法体里的**新契约**（media-type 优先 + 一律以
    //    text/html 下发），实现侧退回旧的「只按扩展名」写法立刻转红。
    group('BUG-1203: content documents are classified by declared media-type',
        () {
      test('isHtmlMediaType accepts every EPUB content-document media-type',
          () {
        expect(isHtmlMediaType('application/xhtml+xml'), isTrue);
        expect(isHtmlMediaType('text/html'), isTrue);
        // `+html` 结构化后缀（EPUB 2 遗留 / 厂商变体）。
        expect(isHtmlMediaType('application/vnd.pub+html'), isTrue);
        // 大小写与首尾空白由 OPF 手写而来，必须容忍。
        expect(isHtmlMediaType('  APPLICATION/XHTML+XML '), isTrue);
      });

      test('isHtmlMediaType rejects non-document media-types', () {
        expect(isHtmlMediaType('image/jpeg'), isFalse);
        expect(isHtmlMediaType('text/css'), isFalse);
        expect(isHtmlMediaType('application/octet-stream'), isFalse);
        // 「像 html」但不是内容文档：不能靠 contains('html') 之类的松判据放行。
        expect(isHtmlMediaType('text/htmlish'), isFalse);
        expect(isHtmlMediaType('application/xhtml+xml-fragment'), isFalse);
      });

      // 根治判据：扩展名再怪、甚至根本没有扩展名，只要 OPF 声明了内容文档
      // media-type，拦截器就必须把它当网页处理。这条是 BUG-1199 的扩展名白名单
      // **永远做不到**的。
      for (final String href in <String>[
        'OEBPS/text/chapter1', // 无扩展名
        'OEBPS/text/chapter1.xml',
        'OEBPS/text/chapter1.chapter',
      ]) {
        test('declared media-type wins for unusual href "$href"', () {
          final EpubBook book = EpubBook(
            title: 'T',
            chapters: const <EpubChapter>[],
            resources: <String, EpubResource>{
              href: EpubResource(mediaType: 'application/xhtml+xml'),
            },
          );
          expect(fallbackMimeType(href), isNot('text/html'),
              reason: '前提：这个 href 靠扩展名表是判不出 HTML 的，'
                  '否则本用例证明不了 media-type 优先');
          expect(isHtmlMediaType(book.mediaType(href)), isTrue,
              reason: 'OPF 声明是内容文档，拦截器必须当网页处理'
                  '（否则整本正文空白且无错误日志）');
        });
      }

      // 兜底契约：OPF 缺项 / 资源不在 manifest 时退回扩展名表——BUG-1199 补的
      // `.htm` / `.xht` 仍然是这条兜底路径上必须成立的行为。
      for (final String ext in <String>['xhtml', 'html', 'htm', 'xht']) {
        test('.$ext falls back to HTML when the OPF declares nothing', () {
          final EpubBook book = EpubBook(
            title: 'T',
            chapters: const <EpubChapter>[],
            resources: const <String, EpubResource>{}, // manifest 查不到
          );
          expect(isHtmlMediaType(book.mediaType('OEBPS/c01.$ext')), isTrue,
              reason: '.$ext must not fall back to octet-stream — the reader '
                  'would skip sanitize/style injection and render blank');
        });
      }

      test('a malformed OPF declaration cannot un-classify a known extension',
          () {
        // 只放宽不收紧：OPF 把 xhtml 错标成 text/plain 时，扩展名仍须兜住，
        // 否则「换成 media-type 优先」本身会变成新的空白页来源。
        final EpubBook book = EpubBook(
          title: 'T',
          chapters: const <EpubChapter>[],
          resources: <String, EpubResource>{
            'OEBPS/c01.xhtml': EpubResource(mediaType: 'text/plain'),
          },
        );
        final String declared = book.mediaType('OEBPS/c01.xhtml');
        final String ext = fallbackMimeType('OEBPS/c01.xhtml');
        expect(isHtmlMediaType(declared) || isHtmlMediaType(ext), isTrue);
      });

      test('the shared predicate has no parallel copy in the parser', () {
        final String parser =
            File('lib/src/epub/epub_parser.dart').readAsStringSync();
        expect(parser.contains('_isHtmlMediaType'), isFalse,
            reason: '解析器又抄回了一份私有谓词——两份判据必然漂开，'
                '一边认怪 media-type 另一边不认就是静默空白页');
        expect(parser.contains('isHtmlMediaType('), isTrue,
            reason: '解析器筛 spine 必须走共享谓词');
      });

      test('interceptor classifies by media-type and still serves text/html',
          () {
        final String reader = readReaderPageSource();
        final int payloadIdx = reader
            .indexOf('Future<_ReaderResourceResponse> _readerResourcePayload(');
        expect(payloadIdx, greaterThan(0),
            reason: '_readerResourcePayload 被改名/搬走——本组守卫已失去锚点');
        final int endIdx =
            reader.indexOf('Future<WebResourceResponse?> _interceptRequest(');
        expect(endIdx, greaterThan(payloadIdx));
        final String payloadBody = reader.substring(payloadIdx, endIdx);

        expect(payloadBody.contains('_book?.mediaType('), isTrue,
            reason: '拦截器不再读 EPUB 声明的 media-type，退回「按扩展名猜」——'
                'BUG-1203 的根因原样复活');
        expect(payloadBody.contains('isHtmlMediaType('), isTrue,
            reason: '拦截器必须复用共享谓词 isHtmlMediaType，'
                '不得在本地另写一份平行判据');
        expect(payloadBody.contains('fallbackMimeType(filePath)'), isTrue,
            reason: 'OPF 允许缺 media-type，扩展名兜底不能被删掉');
        expect(payloadBody.contains("isHtmlDocument ? 'text/html'"), isTrue,
            reason: '内容文档必须一律以 text/html 下发；一旦改成回声 OPF 声明的'
                ' application/xhtml+xml，渲染器切严格 XML 解析，'
                'BUG-079 / BUG-737 的 sanitizeXhtml 补偿失效');
        // 只禁 **Dart 字符串字面量**形式（注释里为解释约束会写到这个词，
        // 用反引号包裹，不带单引号，故不会误伤自己）。
        expect(payloadBody.contains("'application/xhtml+xml'"), isFalse,
            reason: '拦截器方法体里出现这个字符串字面量，几乎必然是把它当成了下发的'
                ' Content-Type 或又抄了一份本地谓词——两者都不允许');
        expect(
            payloadBody
                .contains("mime == 'text/html' || mime.contains('xhtml')"),
            isFalse,
            reason: '旧的纯扩展名谓词回来了——BUG-1203 的根因原样复活');
      });
    });

    test('case insensitive extension matching', () {
      expect(fallbackMimeType('FILE.CSS'), 'text/css');
      expect(fallbackMimeType('cover.PNG'), 'image/png');
      expect(fallbackMimeType('CHAPTER.HTM'), 'text/html');
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
          book.resolveInternalLink('https://fushi.local/epub/OEBPS/ch2.xhtml');
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
        '${ReaderFushiSource.kResourceScheme}://fushi.local/epub/OEBPS/ch2.xhtml#frag',
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
          .resolveInternalLink('https://fushi.local/epub/ch1.xhtml#section2');
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
              'https://fushi.local/epub/nonexistent.xhtml'),
          isNull);
    });

    // BUG-097: the WebView resolves a relative `<a href>` against the document
    // URL, so the clicked link can carry `./` / `../` / duplicate slashes that
    // the canonicalized stored href does not. These must still resolve (else the
    // caller opens a blank OS browser for fushi.local instead of jumping).
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
            'https://fushi.local/epub/OEBPS/text/../ch1.xhtml');
        expect(result, isNotNull);
        expect(result!.chapterIndex, 0);
      });

      test('current-dir (./) link resolves to the chapter', () {
        final result = book.resolveInternalLink(
            'https://fushi.local/epub/OEBPS/./text/ch2.xhtml#frag');
        expect(result, isNotNull);
        expect(result!.chapterIndex, 1);
        expect(result.fragment, 'frag');
      });

      test('duplicate slashes resolve to the chapter', () {
        final result = book
            .resolveInternalLink('https://fushi.local/epub/OEBPS//ch1.xhtml');
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
