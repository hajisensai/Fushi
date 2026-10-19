import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ocr_folder_job.dart';
import 'package:fushi_engine/ocr/ocr_glyph_boxes.dart';
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

  group('逐行 CTC 给的逐字命中格（字格中心落在对应 token 区间）', () {
    // 单行横排标题「第13話 ロック」：数字与空格两侧字距很不均匀，按行宽均分的字格
    // 会整体偏到隔壁字上。
    const OcrRect titleLine = OcrRect(
      left: 100,
      top: 20,
      right: 900,
      bottom: 70,
    );
    const String title = '第13話 ロック';
    // 识别器 token 区间（页面 x）：第、1、3、話、（空格无 token）、ロ、ッ、ク。
    const List<(int, double, double)> tokens = <(int, double, double)>[
      (0, 110, 150),
      (1, 165, 185),
      (2, 195, 215),
      (3, 230, 280),
      (5, 520, 570),
      (6, 600, 640),
      (7, 690, 740),
    ];

    List<OcrGlyphBox> glyphsOf() {
      final List<OcrGlyphBox>? glyphs = ocrLineGlyphBoxes(
        text: title,
        tokens: <OcrLineToken>[
          for (final (int start, double l, double r) in tokens)
            OcrLineToken(
              start: start,
              end: start + 1,
              left: l - 100,
              right: r - 100,
            ),
        ],
        line: titleLine,
        vertical: false,
        alongOrigin: 100,
        utf16Offset: 0,
      );
      return glyphs!;
    }

    OcrBlock titleBlock({double tilt = 0}) => OcrBlock(
      box: titleLine,
      vertical: false,
      lines: const <String>[title],
      lineBoxes: const <OcrRect>[titleLine],
      lineTilt: tilt,
      glyphBoxes: glyphsOf(),
    );

    test('每个 token 的中心点下去，命中的就是这个字', () {
      final MokuroBlock block = blockOf(titleBlock());
      expect(block.regions, isNotNull);
      final List<MangaOcrTextRegion> regions = mangaEffectiveTextRegions(block);
      expect(regions, same(block.regions));
      for (final (int start, double l, double r) in tokens) {
        final MangaOcrTextRegion hit = hitAt(regions, (l + r) / 2, 45);
        expect(
          title.substring(hit.utf16Start, hit.utf16End),
          title.substring(start, start + 1),
          reason: 'x=${(l + r) / 2}',
        );
        // 字格中心也落在该 token 的区间里。
        expect(hit.rectangle.center.dx, inInclusiveRange(l, r));
      }
    });

    test('对照：没有字格时按行宽均分，「ロ」的位置会命中别的字', () {
      final OcrBlock withGlyphs = titleBlock();
      final MokuroBlock block = blockOf(
        OcrBlock(
          box: withGlyphs.box,
          vertical: false,
          lines: withGlyphs.lines,
          lineBoxes: withGlyphs.lineBoxes,
        ),
      );
      expect(block.regions, isNull);
      final MangaOcrTextRegion hit = hitAt(
        mangaEffectiveTextRegions(block),
        545,
        45,
      );
      expect(title.substring(hit.utf16Start, hit.utf16End), isNot('ロ'));
    });

    test('manga.json 往返保留字格；斜行不写字格（覆盖层沿斜线切更贴字）', () {
      final MokuroPayload payload = buildMangaPayloadFromResults(
        <MangaOcrPageFile>[
          MangaOcrPageFile(file: File('p.png'), relativeUrl: 'p.png'),
        ],
        <OcrPageResult>[
          OcrPageResult(
            pageIndex: 0,
            imageWidth: 900,
            imageHeight: 600,
            blocks: <OcrBlock>[titleBlock()],
          ),
        ],
      );
      final MokuroBlock back = parseMangaJson(
        jsonEncode(mangaPayloadToJson(payload)),
      ).images.single.blocks.single;
      expect(back.regions, hasLength(7));
      final MangaOcrTextRegion ro = hitAt(
        mangaEffectiveTextRegions(back),
        545,
        45,
      );
      expect(title.substring(ro.utf16Start, ro.utf16End), 'ロ');

      expect(blockOf(titleBlock(tilt: 0.1)).regions, isNull);
    });
  });
}
