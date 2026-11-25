import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/reader/manga_fushi_page.dart';
import 'package:fushi/src/reader/page_curl/page_curl.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';

/// 卷页的纸面只有页图本身：漫画留黑边时黑边不卷（用户 2026-11-03 截图：卷起的纸
/// 一直伸进上下黑边，「跟画面大小不一致」）。
void main() {
  const Size view = Size(400, 800);

  test('a single page image is the whole paper', () {
    expect(
      mangaCurlPaperFrom(
        <Object>[
          <Object>[0, 0.25, 1, 0.75],
        ],
        view,
        mirror: false,
      ),
      const PageCurlPaper(Rect.fromLTRB(0, 200, 400, 600)),
    );
  });

  // 双页：只翻外侧那一页（像实体书），靠里那页是对面页。
  test('two facing pages: the outer page turns, the inner one is facing', () {
    final List<Object> pair = <Object>[
      <Object>[0.5, 0, 1, 1],
      <Object>[0, 0, 0.5, 1],
    ];
    expect(
      mangaCurlPaperFrom(pair, view, mirror: false),
      const PageCurlPaper(
        Rect.fromLTRB(200, 0, 400, 800),
        facing: Rect.fromLTRB(0, 0, 200, 800),
      ),
      reason: '从左往右读：外侧是右页',
    );
    expect(
      mangaCurlPaperFrom(pair, view, mirror: true),
      const PageCurlPaper(
        Rect.fromLTRB(0, 0, 200, 800),
        facing: Rect.fromLTRB(200, 0, 400, 800),
      ),
      reason: '右开：外侧是左页',
    );
  });

  test('malformed or empty results fall back to the whole viewport', () {
    expect(mangaCurlPaperFrom(null, view, mirror: false), isNull);
    expect(mangaCurlPaperFrom(<Object>[], view, mirror: false), isNull);
    expect(
      mangaCurlPaperFrom(
        <Object>[
          <Object>[0, 0, 1],
        ],
        view,
        mirror: false,
      ),
      isNull,
    );
    expect(
      mangaCurlPaperFrom(
        <Object>[
          <Object>[0, 0, 'x', 1],
        ],
        view,
        mirror: false,
      ),
      isNull,
    );
    expect(
      mangaCurlPaperFrom(
        <Object>[
          <Object>[0.5, 0.5, 0.5, 1],
        ],
        view,
        mirror: false,
      ),
      isNull,
    );
    expect(
      mangaCurlPaperFrom(
        <Object>[
          <Object>[0, 0, double.nan, 1],
        ],
        view,
        mirror: false,
      ),
      isNull,
    );
    expect(
      mangaCurlPaperFrom(
        <Object>[
          <Object>[0, 0, 0.3, 1],
          <Object>[0.3, 0, 0.6, 1],
          <Object>[0.6, 0, 1, 1],
        ],
        view,
        mirror: false,
      ),
      isNull,
      reason: '一个跨页最多两张页图',
    );
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
