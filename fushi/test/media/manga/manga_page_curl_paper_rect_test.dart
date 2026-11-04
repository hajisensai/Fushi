import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 卷页的纸面只有页图本身：漫画留黑边时黑边不卷（用户 2026-11-03 截图：卷起的纸
/// 一直伸进上下黑边，「跟画面大小不一致」）。
void main() {
  const Size view = Size(400, 800);

  test('the JS page rect maps to overlay coordinates', () {
    expect(
      mangaCurlPaperRectFrom(<Object>[0, 0.25, 1, 0.75], view),
      const Rect.fromLTRB(0, 200, 400, 600),
    );
  });

  test('malformed or empty results fall back to the whole viewport', () {
    expect(mangaCurlPaperRectFrom(null, view), isNull);
    expect(mangaCurlPaperRectFrom(<Object>[0, 0, 1], view), isNull);
    expect(mangaCurlPaperRectFrom(<Object>[0, 0, 'x', 1], view), isNull);
    expect(mangaCurlPaperRectFrom(<Object>[0.5, 0.5, 0.5, 1], view), isNull);
    expect(mangaCurlPaperRectFrom(<Object>[0, 0, double.nan, 1], view), isNull);
  });

  test('the invocation asks for the given spread', () {
    expect(
      mangaCurlPaperRectInvocation(7),
      contains('__mangaCurlPaperRect(7)'),
    );
  });

  test('the reader document defines the page-rect probe', () {
    final String html = mangaWindowDocument(
      <MokuroImage>[
        const MokuroImage(
          url: 'p.png',
          size: MokuroSize(1000, 1414),
          blocks: <MokuroBlock>[],
        ),
      ],
      <String>['p0.png'],
      mode: MangaReadingMode.spread,
      spreadDirection: 'rtl',
      inlineSelectionJs: '',
    );
    expect(html, contains('window.__mangaCurlPaperRect = function(i)'));
    // 量的是 .manga-page 盒子（页图本身），不是整个跨页槽。
    expect(html, contains(".manga-page[data-spread=\"'+i+'\"]"));
  });
}
