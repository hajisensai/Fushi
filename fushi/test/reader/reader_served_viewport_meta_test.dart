import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_resource_sanitizer.dart';

import '../helpers/source_guard.dart';
import '../pages/reader_fushi_page_source_corpus.dart';

/// BUG-2639：阅读器章节文档必须**交付时**就带 viewport meta。
///
/// 原先 viewport 只由各 shell 的 `initialize()` 事后用 JS 补上。在那之前
/// WKWebView 按默认 980 CSS px 布局——iOS 模拟器实测 `innerWidth=980 /
/// innerHeight=2131 / visualViewport.scale=0.41`，正是用户视频里竖排滚动模式的
/// 样子：42px 字只剩约 17pt、每列只占屏幕上部四成。真机上页面停在了这个布局里；
/// 交付时带 meta 后，文档从第一次布局起就是 device-width，不再依赖 JS 时序。
void main() {
  const String cloak = '<style id="fushi-cloak"></style>';
  const String tail = '<style id="reader"></style>';

  group('ReaderResourceSanitizer.injectReaderHead', () {
    test('cloak after <head>, tail before </head>, after book metas', () {
      const String html =
          '<html><head><title>t</title>'
          '<meta name="viewport" content="width=1200"/></head>'
          '<body>x</body></html>';
      final String out = ReaderResourceSanitizer.injectReaderHead(
        html,
        headStart: cloak,
        headEnd: tail,
      );
      expect(out.indexOf(cloak), lessThan(out.indexOf('<title>')));
      // WebKit 取最后一个 viewport meta：阅读器的必须排在书自带的之后。
      expect(out.indexOf(tail), greaterThan(out.indexOf('width=1200')));
      expect(out.indexOf(tail), lessThan(out.indexOf('</head>')));
      expect(out, endsWith('</head><body>x</body></html>'));
    });

    test('no </head>: both go right after <head>', () {
      final String out = ReaderResourceSanitizer.injectReaderHead(
        '<html><head><body>x</body></html>',
        headStart: cloak,
        headEnd: tail,
      );
      expect(out, '<html><head>\n$cloak\n$tail<body>x</body></html>');
    });

    test('no <head>: both are prepended', () {
      final String out = ReaderResourceSanitizer.injectReaderHead(
        '<p>x</p>',
        headStart: cloak,
        headEnd: tail,
      );
      expect(out, '$cloak\n$tail\n<p>x</p>');
    });
  });

  test('served meta and the shell rewrite declare the same viewport', () {
    expect(
      ReaderPaginationScripts.readerViewportMetaTag,
      contains('content="${ReaderPaginationScripts.readerViewportContent}"'),
    );
    expect(
      ReaderPaginationScripts.readerViewportContent,
      contains('width=device-width'),
    );
    expect(
      ReaderPaginationScripts.sharedInitViewportJs,
      contains("'${ReaderPaginationScripts.readerViewportContent}'"),
    );
  });

  test('chapter HTML builder serves the viewport meta in <head>', () {
    final String src = maskCommentsAndScriptLines(readReaderPageSource());
    final String body = methodBody(
      src,
      'Uint8List _buildSanitizedChapterHtmlBytes(',
    );
    expect(
      body,
      contains('ReaderResourceSanitizer.injectReaderHead('),
      reason: 'head injection must go through the unit-tested helper',
    );
    expect(
      body,
      contains('ReaderPaginationScripts.readerViewportMetaTag'),
      reason: 'the served chapter must carry the reader viewport meta',
    );
  });
}
