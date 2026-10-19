// EPUB 章节扫描（ffc_parse_epub_chapter）的 FFI 往返。派生量逐字对旧实现的回归在
// packages/fushi_engine/test/epub/chapter_scan_vectors_test.dart，这里只钉 ABI：请求位、
// 输出编码、wantedIds 编码、解析失败的状态映射。
//
// 原生库是硬依赖：找不到库这里直接失败，不 skip。
@TestOn('vm')
library;

import 'package:fushi_compute/fushi_compute.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    expect(
      () => EpubChapterScanner.instance,
      returnsNormally,
      reason: 'set $kFushiComputeLibEnv to the built fushi_compute library',
    );
  });

  test('text, ruby track, anchors, images and search text round-trip', () {
    const String html =
        '<html><head><style>p{background:url(bg.png)}</style></head><body>'
        '<h2 id="h">見出し</h2>'
        '<p>a<ruby>漢<rp>(</rp><rt>か ん</rt><rp>)</rp></ruby>　字</p>'
        '<p>◇</p>'
        '<p>「<img src=" i.jpg "/>」</p>'
        '<svg><image xlink:href="s.jpg"/></svg>'
        '</body></html>';
    final EpubChapterScan scan = EpubChapterScanner.instance.scan(
      html,
      EpubScanRequest.text |
          EpubScanRequest.ruby |
          EpubScanRequest.anchors |
          EpubScanRequest.images |
          EpubScanRequest.imageRefs |
          EpubScanRequest.searchText,
      wantedIds: const <String>['missing', 'h'],
    );
    expect(scan.text, '見出しa漢 字◇「」');
    expect(scan.studyChars, 6);
    expect(scan.rubies, hasLength(1));
    expect((scan.rubies!.single.start, scan.rubies!.single.end), (4, 5));
    expect(scan.rubies!.single.reading, 'かん');
    expect(scan.sceneBreaks, <int>[8]);
    expect(scan.anchorOffsets, <int, int>{1: 0});
    expect(
      <String>[for (final EpubScanImageHit h in scan.imageHits!) h.src],
      <String>['i.jpg', 's.jpg'],
    );
    expect(scan.imageHits!.first.sharesLineWithText, isTrue);
    expect(scan.imageHits!.last.sharesLineWithText, isFalse);
    expect(scan.imageTotalChars, 6);
    expect(scan.imageRefs, <String>['i.jpg', 's.jpg', 'bg.png']);
    expect(scan.searchText, '見出しa漢　字◇「」');
  });

  test('unrequested parts stay null', () {
    final EpubChapterScan scan = EpubChapterScanner.instance.scan(
      '<p>x</p>',
      EpubScanRequest.searchText,
    );
    expect(scan.searchText, 'x');
    expect(scan.text, isNull);
    expect(scan.imageHits, isNull);
  });

  test('input the old parser threw on throws FormatException', () {
    expect(
      () => EpubChapterScanner.instance.scan(
        '<p>&#99999999999999999999;</p>',
        EpubScanRequest.text,
      ),
      throwsFormatException,
    );
  });
}
