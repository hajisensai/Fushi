import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';

/// BUG-2813：本地 OCR 的多列竖排块，点哪一列的字就要命中哪一列。
///
/// 从引擎产物（[OcrPageResult]）走 manga.json 组装（[buildMangaPayloadFromResults]）
/// 到覆盖层逐字命中框（[mangaEffectiveTextRegions]），整条数据链一起钉住。
void main() {
  MangaOcrTextRegion hitAt(
    List<MangaOcrTextRegion> regions,
    double x,
    double y,
  ) => regions.firstWhere(
    (MangaOcrTextRegion r) =>
        x >= r.rectangle.left &&
        x <= r.rectangle.right &&
        y >= r.rectangle.top &&
        y <= r.rectangle.bottom,
  );

  MokuroBlock blockOf(OcrBlock block) => buildMangaPayloadFromResults(
    <MangaOcrPageFile>[
      MangaOcrPageFile(file: File('p.png'), relativeUrl: 'p.png'),
    ],
    <OcrPageResult>[
      OcrPageResult(
        pageIndex: 0,
        imageWidth: 400,
        imageHeight: 600,
        blocks: <OcrBlock>[block],
      ),
    ],
  ).images.single.blocks.single;

  const OcrRect box = OcrRect(left: 100, top: 50, right: 180, bottom: 250);

  test('带行框的两列块：点左列第一格命中第二列首字「え」', () {
    final MokuroBlock block = blockOf(
      const OcrBlock(
        box: box,
        vertical: true,
        lines: <String>['あいう', 'えお'],
        lineBoxes: <OcrRect>[
          OcrRect(left: 140, top: 50, right: 180, bottom: 170),
          OcrRect(left: 100, top: 50, right: 140, bottom: 130),
        ],
      ),
    );
    final String sentence = block.lines.join();
    final List<MangaOcrTextRegion> regions = mangaEffectiveTextRegions(block);
    final MangaOcrTextRegion left = hitAt(regions, 120, 60);
    expect(sentence.substring(left.utf16Start, left.utf16End), 'え');
    final MangaOcrTextRegion right = hitAt(regions, 160, 120);
    expect(sentence.substring(right.utf16Start, right.utf16End), 'い');
  });

  test('没有行框的旧结果仍按整块均铺（兼容旧 manga.json，不崩）', () {
    final MokuroBlock block = blockOf(
      const OcrBlock(box: box, vertical: true, lines: <String>['あいうえお']),
    );
    expect(block.linesCoords, isNull);
    final List<MangaOcrTextRegion> regions = mangaEffectiveTextRegions(block);
    expect(regions, hasLength(5));
    // 整块均铺时左列顶部落在第一个字上——这正是 BUG-2813 的错位形态。
    final MangaOcrTextRegion left = hitAt(regions, 120, 60);
    expect(left.utf16Start, 0);
  });
}
