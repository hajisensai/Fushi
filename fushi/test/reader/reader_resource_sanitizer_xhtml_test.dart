import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_resource_sanitizer.dart';

void main() {
  group('ReaderResourceSanitizer.sanitizeXhtml', () {
    test('converts self-closing <script/> to a paired tag so body survives',
        () {
      // BUG-079: Kadokawa/BookWalker XHTML ships a self-closing <script .../>
      // with no matching </script>. Served as text/html, the HTML5 parser
      // enters "script data" state and swallows everything to EOF (whole body),
      // rendering a blank page. Normalizing it to a paired tag fixes rendering.
      const String input =
          '<html><head><script xmlns="http://www.w3.org/1999/xhtml" '
          'type="text/javascript" src="../../js/kobo.js"/></head>'
          '<body><p>本文が見える</p></body></html>';

      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);

      expect(out, contains('</script>'),
          reason: 'self-closing script must become a paired tag');
      expect(out, contains('<p>本文が見える</p>'),
          reason: 'body content must be preserved verbatim');
      expect(out, isNot(contains('kobo.js"/>')),
          reason: 'the self-closing form must be gone');
    });

    test('normalizes self-closing <style/>, <title/>, <textarea/> too', () {
      const String input =
          '<head><title/><style/></head><body><textarea/></body>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, contains('<title></title>'));
      expect(out, contains('<style></style>'));
      expect(out, contains('<textarea></textarea>'));
    });

    test('leaves a well-formed paired <script>...</script> untouched', () {
      const String input =
          '<head><script src="a/b.js"></script></head><body>x</body>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, equals(input),
          reason:
              'paired tags (even with / in attribute values) are unchanged');
    });

    test('preserves attributes when expanding the self-closing form', () {
      const String input =
          '<script type="text/javascript" src="../../js/x.js"/>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(
          out,
          equals(
              '<script type="text/javascript" src="../../js/x.js"></script>'));
    });

    test('handles whitespace before the self-closing slash', () {
      const String input = '<script src="x.js" />';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, equals('<script src="x.js"></script>'));
    });

    test('does not corrupt a paired tag whose attribute value contains "/>"',
        () {
      // The self-closing detector must not mistake a literal `/>` inside a
      // quoted attribute value for the tag's own self-closing end.
      const String input =
          '<head><script data-x="a/>b"></script></head><body>x</body>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, equals(input),
          reason: 'a paired tag with "/>" inside an attribute is unchanged');
    });

    test('still expands a genuine self-close after a quoted attr value', () {
      const String input = '<script src="a/b.js"/>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, equals('<script src="a/b.js"></script>'));
    });

    test('does not touch genuine void elements like <br/> and <img/>', () {
      const String input = '<body><br/><img src="x.png"/></body>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, equals(input));
    });

    test('leaves the full void-element set self-closing', () {
      const String input = '<head><meta charset="utf-8"/>'
          '<link rel="stylesheet" href="s.css"/></head>'
          '<body><hr/><input type="text"/><br/></body>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, equals(input),
          reason: 'meta/link/hr/input/br are void — keep self-closing');
    });

    // BUG-737: a self-closing <a id="toc-N"/> (the per-chapter anchor in many
    // Japanese publisher EPUBs) is NOT a void element, so served as text/html it
    // becomes an unclosed <a> that the adoption-agency algorithm reconstructs
    // across every following block — wrapping the whole chapter's prose in an
    // <a>. The reader's tap-lookup (selectText) then bails on
    // elementFromPoint().closest('a'), so no word in the chapter can be looked
    // up. Closing the empty anchor here keeps the prose out of any <a>.
    test('closes a self-closing <a id=".."/> so it cannot wrap the prose', () {
      const String input =
          '<body><p><a id="toc-001"/><span>第一章</span></p>'
          '<p>本文の続き。</p></body>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, contains('<a id="toc-001"></a>'),
          reason: 'the empty anchor must be explicitly closed');
      expect(out, isNot(contains('id="toc-001"/>')),
          reason: 'no self-closing anchor may remain');
    });

    test('normalizes other self-closing non-void inline elements', () {
      const String input = '<body><p><span/><i/><b/>本文</p></body>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, contains('<span></span>'));
      expect(out, contains('<i></i>'));
      expect(out, contains('<b></b>'));
    });

    test('does not corrupt a self-closing <a> whose attr value contains "/>"',
        () {
      const String input = '<body><a href="a/>b"/>x</body>';
      final String out = ReaderResourceSanitizer.sanitizeXhtml(input);
      expect(out, equals('<body><a href="a/>b"></a>x</body>'),
          reason: 'the "/>" inside the quoted href is not the tag end');
    });
  });

  group('ReaderResourceSanitizer.injectImagesAfterBodyOpen (TODO-1174)', () {
    const String img = '<div class="fushi-merged-image">'
        '<img src="a.png" class="block-img"/></div>';

    test(
        'inserts the images right AFTER the <body> open tag, not before '
        '</body>', () {
      const String html = '<html><body><p>本文</p></body></html>';
      final String out =
          ReaderResourceSanitizer.injectImagesAfterBodyOpen(html, img);

      final int bodyOpenEnd = out.indexOf('<body>') + '<body>'.length;
      final int imgAt = out.indexOf('fushi-merged-image');
      final int paraAt = out.indexOf('<p>本文</p>');
      // The image lands at the very top of the flow: after <body>, before the
      // original first content — i.e. merged illustrations open the chapter.
      expect(imgAt, greaterThan(0));
      expect(imgAt, greaterThanOrEqualTo(bodyOpenEnd));
      expect(imgAt, lessThan(paraAt),
          reason: 'merged image must precede the chapter body content');
    });

    test('preserves <body> attributes and injects after the full open tag', () {
      const String html =
          '<html><body class="c" dir="rtl"><p>x</p></body></html>';
      final String out =
          ReaderResourceSanitizer.injectImagesAfterBodyOpen(html, img);
      expect(out, contains('<body class="c" dir="rtl">'));
      final int openEnd = out.indexOf('<body class="c" dir="rtl">') +
          '<body class="c" dir="rtl">'.length;
      expect(out.indexOf('fushi-merged-image'), greaterThanOrEqualTo(openEnd));
    });

    test('empty images string is a verbatim no-op', () {
      const String html = '<html><body><p>x</p></body></html>';
      expect(ReaderResourceSanitizer.injectImagesAfterBodyOpen(html, ''),
          equals(html));
    });

    test('no <body> tag falls back to prepending before the document', () {
      const String html = '<p>x</p>';
      final String out =
          ReaderResourceSanitizer.injectImagesAfterBodyOpen(html, img);
      expect(
          out.indexOf('fushi-merged-image'), lessThan(out.indexOf('<p>x</p>')));
    });
  });
}
