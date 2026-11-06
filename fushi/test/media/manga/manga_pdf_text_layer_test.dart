/// PDF 文字层 → 漫画文字块（`manga_pdf_text_layer.dart`）与写回保留。
///
/// 背景：PDF 转成漫画后原先只能靠 OCR 出字框，OCR 只给行框、逐字格按字数均分，
/// 竖排里「、」「……」高度和普通字不同，越往列尾偏得越多。带文字层的 PDF 每个字的
/// 位置是已知的——这里钉住：逐字命中区就落在那个字上（不漂），且 OCR / 向导重写
/// manga.json 时文字层不被冲掉。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi_engine/media/manga/manga_pdf_text_layer.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:path/path.dart' as p;

/// 竖排一列：从 (x, top) 往下排 [text]，字高随字变（标点矮），字距 [gap]。
List<PdfTextLayerGlyph> _column(
  String text, {
  required double x,
  required double top,
  double size = 20,
  double gap = 4,
}) {
  final List<PdfTextLayerGlyph> glyphs = <PdfTextLayerGlyph>[];
  double y = top;
  for (final int rune in text.runes) {
    final String ch = String.fromCharCode(rune);
    // 句读只占字格右上角一小块——正是均分字格会漂的那类字。
    final bool punct = ch == '、' || ch == '。';
    final MokuroRect rect = punct
        ? MokuroRect.fromLTWH(x + size * 0.55, y, size * 0.35, size * 0.35)
        : MokuroRect.fromLTWH(x, y, size, size);
    glyphs.add(PdfTextLayerGlyph(text: ch, rect: rect));
    y += (punct ? size * 0.5 : size) + gap;
  }
  return glyphs;
}

MokuroBlock _ocrBlock(MokuroRect rect, String text) => MokuroBlock(
  rectangle: rect,
  isVertical: true,
  fontSize: 20,
  zIndex: 0,
  lines: <String>[text],
);

void main() {
  group('buildPdfTextLayerBlocks', () {
    test('竖排三列合成一个段落块，逐字命中区落在各自的字上（不随列长漂移）', () {
      final List<PdfTextLayerGlyph> col1 = _column(
        '今夜は私にとって、貴重で大切で、特別な時間。',
        x: 300,
        top: 10,
      );
      final List<PdfTextLayerGlyph> col2 = _column(
        '理由は単純。社会人になってひとり暮らし',
        x: 270,
        top: 10,
      );
      final List<PdfTextLayerGlyph> col3 = _column('を始めた私の家に', x: 240, top: 10);
      final List<PdfTextLayerGlyph> glyphs = <PdfTextLayerGlyph>[
        ...col1,
        ...col2,
        ...col3,
      ];

      final List<MokuroBlock> blocks = buildPdfTextLayerBlocks(glyphs);

      expect(blocks, hasLength(1));
      final MokuroBlock block = blocks.single;
      expect(block.isVertical, isTrue);
      expect(block.pdfTextLayer, isTrue);
      expect(block.lines, <String>[
        '今夜は私にとって、貴重で大切で、特別な時間。',
        '理由は単純。社会人になってひとり暮らし',
        'を始めた私の家に',
      ]);
      final List<MangaOcrTextRegion> regions = block.regions!;
      expect(regions, hasLength(glyphs.length));
      for (int i = 0; i < glyphs.length; i++) {
        final MokuroRect glyph = glyphs[i].rect;
        final MokuroPoint c = regions[i].rectangle.center;
        expect(
          c.dy >= glyph.top - 3 && c.dy <= glyph.bottom + 3,
          isTrue,
          reason:
              '第 $i 个字「${glyphs[i].text}」的命中区中心 y=${c.dy} '
              '应落在字框 ${glyph.top}..${glyph.bottom} 上',
        );
        expect(
          regions[i].rectangle.left <= glyph.left &&
              regions[i].rectangle.right >= glyph.right,
          isTrue,
          reason: '命中区横向撑满整列、覆盖字框',
        );
      }
      // 覆盖层直接采用这份逐字区域，而不是退回「行框按字数均分」。
      expect(
        mangaTextRegionsMatchSentence(regions, block.lines.join()),
        isTrue,
      );
      expect(identical(mangaEffectiveTextRegions(block), regions), isTrue);
    });

    test('注音（明显更细的列）单独成块，不并进正文', () {
      final List<PdfTextLayerGlyph> glyphs = <PdfTextLayerGlyph>[
        ..._column('私の家に恋が泊まりに', x: 300, top: 10),
        // 「恋」右侧的读音「れん」：字宽只有正文一半。
        ..._column('れん', x: 322, top: 106, size: 9, gap: 1),
        ..._column('来ているからだ。', x: 270, top: 10),
      ];

      final List<MokuroBlock> blocks = buildPdfTextLayerBlocks(glyphs);

      expect(
        blocks.map((MokuroBlock b) => b.lines.join()).toList(),
        containsAll(<String>['れん']),
      );
      expect(
        blocks
            .where((MokuroBlock b) => b.lines.join().contains('れん'))
            .single
            .lines,
        <String>['れん'],
        reason: '读音并进正文就会被插进例句里',
      );
    });

    test('横排：按行合块，逐字命中区左右相接', () {
      final List<PdfTextLayerGlyph> glyphs = <PdfTextLayerGlyph>[
        for (int i = 0; i < 6; i++)
          PdfTextLayerGlyph(
            text: 'Hello!'[i],
            rect: MokuroRect.fromLTWH(10.0 + i * 12, 50, 10, 16),
          ),
        for (int i = 0; i < 5; i++)
          PdfTextLayerGlyph(
            text: 'World'[i],
            rect: MokuroRect.fromLTWH(10.0 + i * 12, 70, 10, 16),
          ),
      ];

      final MokuroBlock block = buildPdfTextLayerBlocks(glyphs).single;

      expect(block.isVertical, isFalse);
      expect(block.lines, <String>['Hello!', 'World']);
      final List<MangaOcrTextRegion> r = block.regions!;
      expect(r[0].rectangle.right, r[1].rectangle.left, reason: '字间无缝');
    });

    test('空字表 → 无块', () {
      expect(buildPdfTextLayerBlocks(const <PdfTextLayerGlyph>[]), isEmpty);
    });
  });

  group('pdfTextLayerGlyphs', () {
    const MokuroRect a = MokuroRect.fromLTRB(0, 0, 10, 10);
    const MokuroRect b = MokuroRect.fromLTRB(0, 12, 10, 22);

    test('逐 UTF-16 单元给框：补充平面字符两半合成一个字', () {
      final List<PdfTextLayerGlyph> glyphs = pdfTextLayerGlyphs(
        '𠮟る',
        <MokuroRect>[a, a, b],
      );
      expect(glyphs.map((PdfTextLayerGlyph g) => g.text).toList(), <String>[
        '𠮟',
        'る',
      ]);
    });

    test('逐码点给框也认', () {
      final List<PdfTextLayerGlyph> glyphs = pdfTextLayerGlyphs(
        '𠮟る',
        <MokuroRect>[a, b],
      );
      expect(glyphs.map((PdfTextLayerGlyph g) => g.rect).toList(), <MokuroRect>[
        a,
        b,
      ]);
    });

    test('空白与空框（PDFium 生成的换行）丢弃', () {
      final List<PdfTextLayerGlyph> glyphs = pdfTextLayerGlyphs(
        'あ\r\nい',
        <MokuroRect>[a, MokuroRect.zero, MokuroRect.zero, b],
      );
      expect(glyphs.map((PdfTextLayerGlyph g) => g.text).join(), 'あい');
    });

    test('框数对不上 → 空表（交回 OCR，不拿错位的框）', () {
      expect(pdfTextLayerGlyphs('あいう', <MokuroRect>[a, b]), isEmpty);
    });
  });

  group('合并规则', () {
    const MokuroSize size = MokuroSize(400, 600);
    final List<MokuroBlock> fullLayer = buildPdfTextLayerBlocks(
      _column('今夜は私にとって、貴重で大切で、特別な時間でした', x: 300, top: 10),
    );
    final List<MokuroBlock> smallLayer = buildPdfTextLayerBlocks(
      _column('三六', x: 370, top: 560),
    );

    test('完整文字层页：OCR 块全部丢弃', () {
      final MokuroImage page = composePdfTextLayerPage(
        MokuroImage(
          url: 'images/page_000000.png',
          size: size,
          blocks: <MokuroBlock>[
            _ocrBlock(const MokuroRect.fromLTRB(10, 10, 40, 300), '挿絵の文字'),
          ],
        ),
        fullLayer,
      );
      expect(page.blocks.every((MokuroBlock b) => b.pdfTextLayer), isTrue);
    });

    test('只嵌了页码的扫描页：保留不重叠的 OCR 块，丢掉与文字层重叠的', () {
      final MokuroBlock body = _ocrBlock(
        const MokuroRect.fromLTRB(10, 10, 300, 500),
        '本文',
      );
      final MokuroBlock pageNumberDup = _ocrBlock(
        const MokuroRect.fromLTRB(368, 558, 392, 610),
        '三六',
      );
      final MokuroImage page = composePdfTextLayerPage(
        MokuroImage(
          url: 'images/page_000000.png',
          size: size,
          blocks: <MokuroBlock>[body, pageNumberDup],
        ),
        smallLayer,
      );
      expect(page.blocks, contains(body));
      expect(page.blocks, isNot(contains(pageNumberDup)));
      expect(page.blocks.where((MokuroBlock b) => b.pdfTextLayer), isNotEmpty);
    });

    test('preservePdfTextLayer：OCR 结果覆写时沿用磁盘上的文字层', () {
      final MokuroPayload existing = MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'images/page_000000.png',
            size: size,
            blocks: fullLayer,
          ),
        ],
        pdfTextLayerVersion: kPdfTextLayerVersion,
      );
      final MokuroPayload ocr = MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'images/page_000000.png',
            size: size,
            blocks: <MokuroBlock>[
              _ocrBlock(const MokuroRect.fromLTRB(290, 5, 330, 600), '今夜は私'),
            ],
          ),
        ],
        ocr: const MangaOcrMetadata(
          engine: 'google_lens',
          engineSignature: 'x',
          schemaVersion: 1,
        ),
      );

      final MokuroPayload merged = preservePdfTextLayer(
        incoming: ocr,
        existing: existing,
      );

      expect(merged.pdfTextLayerVersion, kPdfTextLayerVersion);
      expect(merged.ocr?.engine, 'google_lens');
      expect(merged.images.single.blocks, fullLayer);
    });

    test('preservePdfTextLayer：页图尺寸变了就不套旧文字层', () {
      final MokuroPayload existing = MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'images/page_000000.png',
            size: size,
            blocks: fullLayer,
          ),
        ],
      );
      final MokuroImage incomingPage = MokuroImage(
        url: 'images/page_000000.png',
        size: const MokuroSize(800, 1200),
        blocks: const <MokuroBlock>[],
      );
      final MokuroPayload merged = preservePdfTextLayer(
        incoming: MokuroPayload(images: <MokuroImage>[incomingPage]),
        existing: existing,
      );
      expect(merged.images.single.blocks, isEmpty);
    });

    test('preservePdfTextLayer：两边都没有文字层时原样返回', () {
      final MokuroPayload incoming = MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'a.png',
            size: size,
            blocks: <MokuroBlock>[
              _ocrBlock(const MokuroRect.fromLTRB(0, 0, 10, 10), 'x'),
            ],
          ),
        ],
      );
      expect(
        identical(
          preservePdfTextLayer(incoming: incoming, existing: incoming),
          incoming,
        ),
        isTrue,
      );
    });
  });

  group('mangaVolumeOcrSettled', () {
    const MokuroSize size = MokuroSize(400, 600);
    final List<MokuroBlock> fullLayer = buildPdfTextLayerBlocks(
      _column('今夜は私にとって、貴重で大切で、特別な時間でした', x: 300, top: 10),
    );
    final List<MokuroBlock> pageNumber = buildPdfTextLayerBlocks(
      _column('三六', x: 370, top: 560),
    );

    MokuroImage page(List<MokuroBlock> blocks) =>
        MokuroImage(url: 'p.png', size: size, blocks: blocks);

    test('整本都是完整文字层：不再排 OCR', () {
      expect(
        mangaVolumeOcrSettled(
          MokuroPayload(
            images: <MokuroImage>[page(fullLayer), page(fullLayer)],
          ),
        ),
        isTrue,
      );
    });

    test('扫描页只有页码文字层：文字层块不算识别结果，仍要 OCR', () {
      expect(
        mangaVolumeOcrSettled(
          MokuroPayload(
            images: <MokuroImage>[page(fullLayer), page(pageNumber)],
          ),
        ),
        isFalse,
      );
    });

    test('没有文字层的卷：判据与原来一致（有块或有 OCR 元数据即已识别）', () {
      expect(
        mangaVolumeOcrSettled(
          MokuroPayload(images: <MokuroImage>[page(const <MokuroBlock>[])]),
        ),
        isFalse,
      );
      expect(
        mangaVolumeOcrSettled(
          MokuroPayload(
            images: <MokuroImage>[
              page(<MokuroBlock>[
                _ocrBlock(const MokuroRect.fromLTRB(0, 0, 10, 10), 'x'),
              ]),
            ],
          ),
        ),
        isTrue,
      );
    });
  });

  test('manga.json 往返保留 pdf_text_layer 与版本号', () {
    final MokuroPayload payload = MokuroPayload(
      images: <MokuroImage>[
        MokuroImage(
          url: 'images/page_000000.png',
          size: const MokuroSize(400, 600),
          blocks: buildPdfTextLayerBlocks(_column('今夜は', x: 300, top: 10)),
        ),
      ],
      pdfTextLayerVersion: kPdfTextLayerVersion,
    );
    final MokuroPayload parsed = parseMangaJson(
      jsonEncode(mangaPayloadToJson(payload)),
    );
    expect(parsed.pdfTextLayerVersion, kPdfTextLayerVersion);
    expect(parsed.images.single.blocks.single.pdfTextLayer, isTrue);
    expect(parsed.images.single.blocks.single.regions, hasLength(3));
  });

  test('writeMangaJsonAtomically：OCR 整份覆写也冲不掉磁盘上的文字层', () async {
    final Directory dir = Directory.systemTemp.createTempSync(
      'pdf_text_layer_',
    );
    addTearDown(() => dir.deleteSync(recursive: true));
    final String path = p.join(dir.path, 'manga.json');
    final List<MokuroBlock> layer = buildPdfTextLayerBlocks(
      _column('今夜は私にとって、貴重で大切で、特別な時間でした', x: 300, top: 10),
    );
    await writeMangaJsonAtomically(
      path,
      MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'images/page_000000.png',
            size: const MokuroSize(400, 600),
            blocks: layer,
          ),
        ],
        pdfTextLayerVersion: kPdfTextLayerVersion,
      ),
    );

    final MokuroPayload written = await writeMangaJsonAtomically(
      path,
      MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'images/page_000000.png',
            size: const MokuroSize(400, 600),
            blocks: <MokuroBlock>[
              _ocrBlock(const MokuroRect.fromLTRB(290, 5, 330, 600), '今夜は私'),
            ],
          ),
        ],
      ),
    );

    final MokuroPayload onDisk = parseMangaJson(File(path).readAsStringSync());
    expect(onDisk.pdfTextLayerVersion, kPdfTextLayerVersion);
    expect(
      onDisk.images.single.blocks.every((MokuroBlock b) => b.pdfTextLayer),
      isTrue,
    );
    expect(written.images.single.blocks, hasLength(layer.length));
  });
}
