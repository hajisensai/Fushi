import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';

void main() {
  group('parseMokuro', () {
    test('parses a complete two-page mokuro document', () {
      const String jsonStr = '''
{
  "version": "0.2.1",
  "title": "テスト漫画",
  "title_uuid": "t-uuid",
  "volume": "第1巻",
  "volume_uuid": "v-uuid",
  "pages": [
    {
      "img_width": 1200,
      "img_height": 1700,
      "img_path": "vol1/p001.jpg",
      "blocks": [
        {
          "box": [100, 200, 300, 500],
          "vertical": true,
          "font_size": 32,
          "lines": ["１行目", "２行目"]
        },
        {
          "box": [400, 600, 700, 800],
          "vertical": false,
          "font_size": 24,
          "lines": ["横書き"]
        }
      ]
    },
    {
      "img_width": 1200,
      "img_height": 1700,
      "img_path": "vol1/p002.jpg",
      "blocks": []
    }
  ]
}
''';

      final MokuroPayload payload = parseMokuro(jsonStr);

      expect(payload.images.length, 2);

      final MokuroImage page0 = payload.images[0];
      expect(page0.url, 'vol1/p001.jpg');
      expect(page0.size, const Size(1200, 1700));
      expect(page0.blocks.length, 2);

      final MokuroBlock block0 = page0.blocks[0];
      expect(block0.rectangle, const Rect.fromLTRB(100, 200, 300, 500));
      expect(block0.isVertical, isTrue);
      expect(block0.fontSize, 32.0);
      expect(block0.zIndex, 0);
      expect(block0.lines, <String>['１行目', '２行目']);

      final MokuroBlock block1 = page0.blocks[1];
      expect(block1.isVertical, isFalse);
      expect(block1.fontSize, 24.0);
      expect(block1.zIndex, 1);
      expect(block1.lines, <String>['横書き']);

      expect(payload.images[1].blocks, isEmpty);
    });

    test('tolerates missing font_size, vertical and lines', () {
      const String jsonStr = '''
{
  "pages": [
    {
      "img_width": 800,
      "img_height": 1200,
      "img_path": "p.jpg",
      "blocks": [
        { "box": [0, 0, 10, 10] }
      ]
    }
  ]
}
''';

      final MokuroPayload payload = parseMokuro(jsonStr);
      final MokuroBlock block = payload.images.single.blocks.single;

      expect(block.isVertical, isFalse);
      expect(block.fontSize, 0.0);
      expect(block.zIndex, 0);
      expect(block.lines, isEmpty);
      expect(block.linesCoords, isNull);
    });

    test('coerces integer font_size and numeric box to double Rect', () {
      const String jsonStr = '''
{
  "pages": [
    {
      "img_width": 100,
      "img_height": 200,
      "img_path": "p.jpg",
      "blocks": [
        { "box": [1, 2, 3, 4], "font_size": 40, "vertical": true, "lines": ["x"] }
      ]
    }
  ]
}
''';

      final MokuroBlock block =
          parseMokuro(jsonStr).images.single.blocks.single;
      expect(block.rectangle, const Rect.fromLTRB(1, 2, 3, 4));
      expect(block.fontSize, isA<double>());
      expect(block.fontSize, 40.0);
    });

    test('handles a document with no pages key as empty payload', () {
      final MokuroPayload payload = parseMokuro('{}');
      expect(payload.images, isEmpty);
    });

    test('handles a top-level array/scalar as empty payload (no throw)', () {
      expect(parseMokuro('[]').images, isEmpty);
      expect(parseMokuro('42').images, isEmpty);
    });

    test('normalises back-slash img_path to forward-slash url (portability)',
        () {
      const String jsonStr = '''
{
  "pages": [
    {
      "img_width": 100,
      "img_height": 100,
      "img_path": "vol2\\\\p003.jpg",
      "blocks": []
    }
  ]
}
''';
      final MokuroPayload payload = parseMokuro(jsonStr);
      // Windows back-slash path must become a forward-slash relative url so it
      // is portable / does not collide with same-name pages elsewhere.
      expect(payload.images.single.url, 'vol2/p003.jpg');
      expect(payload.images.single.url.contains('\\'), isFalse);
    });

    test('preserves sub-directory structure (no basename flattening)', () {
      const String jsonStr = '''
{
  "pages": [
    { "img_width": 1, "img_height": 1, "img_path": "vol1/p001.jpg", "blocks": [] },
    { "img_width": 1, "img_height": 1, "img_path": "vol2/p001.jpg", "blocks": [] }
  ]
}
''';
      final MokuroPayload payload = parseMokuro(jsonStr);
      // Two same-name pages under different sub-dirs must stay distinct urls.
      expect(payload.images[0].url, 'vol1/p001.jpg');
      expect(payload.images[1].url, 'vol2/p001.jpg');
    });

    test('retains optional lines_coords when present', () {
      const String jsonStr = '''
{
  "pages": [
    {
      "img_width": 100,
      "img_height": 100,
      "img_path": "p.jpg",
      "blocks": [
        {
          "box": [0, 0, 50, 50],
          "font_size": 10,
          "lines": ["あ"],
          "lines_coords": [
            [[0, 0], [50, 0], [50, 50], [0, 50]]
          ]
        }
      ]
    }
  ]
}
''';
      final MokuroBlock block =
          parseMokuro(jsonStr).images.single.blocks.single;
      expect(block.linesCoords, isNotNull);
      expect(block.linesCoords!.length, 1);
      expect(block.linesCoords!.single.length, 4);
      expect(block.linesCoords!.single.first, <double>[0, 0]);
      expect(block.linesCoords!.single[2], <double>[50, 50]);
    });
  });

  group('mangaPayloadToJson', () {
    test(
        'serialises the internal manga.json shape (forward-slash url + '
        'z_index)', () {
      const MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'vol1/p001.jpg',
            size: Size(1200, 1700),
            blocks: <MokuroBlock>[
              MokuroBlock(
                rectangle: Rect.fromLTRB(100, 200, 300, 500),
                isVertical: true,
                fontSize: 32,
                zIndex: 0,
                lines: <String>['あ', 'い'],
              ),
            ],
          ),
        ],
      );
      final Map<String, Object?> json = mangaPayloadToJson(payload);
      final List<Object?> pages = json['pages']! as List<Object?>;
      expect(pages.length, 1);
      final Map<String, Object?> page0 =
          (pages.first! as Map).cast<String, Object?>();
      expect(page0['url'], 'vol1/p001.jpg');
      expect(page0['width'], 1200.0);
      expect(page0['height'], 1700.0);
      final Map<String, Object?> block0 =
          ((page0['blocks']! as List).first! as Map).cast<String, Object?>();
      expect(block0['box'], <double>[100, 200, 300, 500]);
      expect(block0['vertical'], isTrue);
      expect(block0['font_size'], 32.0);
      expect(block0['z_index'], 0);
      expect(block0['lines'], <String>['あ', 'い']);
      // lines_coords absent → not emitted.
      expect(block0.containsKey('lines_coords'), isFalse);
    });

    test('emits lines_coords only when present', () {
      const MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'p.jpg',
            size: Size(100, 100),
            blocks: <MokuroBlock>[
              MokuroBlock(
                rectangle: Rect.fromLTRB(0, 0, 10, 10),
                isVertical: false,
                fontSize: 10,
                zIndex: 0,
                lines: <String>['x'],
                linesCoords: <List<List<double>>>[
                  <List<double>>[
                    <double>[0, 0],
                    <double>[10, 10],
                  ],
                ],
              ),
            ],
          ),
        ],
      );
      final Map<String, Object?> json = mangaPayloadToJson(payload);
      final Map<String, Object?> block0 =
          ((((json['pages']! as List).first! as Map)['blocks']! as List).first!
                  as Map)
              .cast<String, Object?>();
      expect(block0.containsKey('lines_coords'), isTrue);
      expect(block0['lines_coords'], isA<List<Object?>>());
    });
  });

  group('parseMangaJson', () {
    test('round-trips parseMokuro → mangaPayloadToJson → parseMangaJson', () {
      const String mokuro = '''
{
  "title": "t",
  "pages": [
    {
      "img_width": 1200,
      "img_height": 1700,
      "img_path": "vol1/p001.jpg",
      "blocks": [
        { "box": [100, 200, 300, 500], "vertical": true, "font_size": 32, "lines": ["一", "二"] },
        { "box": [400, 600, 700, 800], "vertical": false, "font_size": 24, "lines": ["横"] }
      ]
    }
  ]
}
''';
      final MokuroPayload original = parseMokuro(mokuro);
      final String serialized = jsonEncode(mangaPayloadToJson(original));
      final MokuroPayload restored = parseMangaJson(serialized);

      expect(restored.images.length, original.images.length);
      final MokuroImage page = restored.images.single;
      expect(page.url, 'vol1/p001.jpg');
      expect(page.size, const Size(1200, 1700));
      expect(page.blocks.length, 2);
      expect(page.blocks[0].rectangle, const Rect.fromLTRB(100, 200, 300, 500));
      expect(page.blocks[0].isVertical, isTrue);
      expect(page.blocks[0].fontSize, 32.0);
      expect(page.blocks[0].zIndex, 0);
      expect(page.blocks[0].lines, <String>['一', '二']);
      expect(page.blocks[1].zIndex, 1);
      expect(page.blocks[1].isVertical, isFalse);
    });

    test('reads explicit z_index (not array index)', () {
      const String mangaJson = '''
{
  "pages": [
    {
      "url": "p.jpg",
      "width": 100,
      "height": 100,
      "blocks": [
        { "box": [0, 0, 10, 10], "vertical": false, "font_size": 10, "z_index": 5, "lines": ["a"] }
      ]
    }
  ]
}
''';
      final MokuroBlock block =
          parseMangaJson(mangaJson).images.single.blocks.single;
      // z_index=5 must win over the array index 0.
      expect(block.zIndex, 5);
    });

    test('round-trips lines_coords through manga.json', () {
      const MokuroPayload payload = MokuroPayload(
        images: <MokuroImage>[
          MokuroImage(
            url: 'p.jpg',
            size: Size(100, 100),
            blocks: <MokuroBlock>[
              MokuroBlock(
                rectangle: Rect.fromLTRB(0, 0, 50, 50),
                isVertical: true,
                fontSize: 10,
                zIndex: 0,
                lines: <String>['あ'],
                linesCoords: <List<List<double>>>[
                  <List<double>>[
                    <double>[0, 0],
                    <double>[50, 0],
                    <double>[50, 50],
                    <double>[0, 50],
                  ],
                ],
              ),
            ],
          ),
        ],
      );
      final String serialized = jsonEncode(mangaPayloadToJson(payload));
      final MokuroBlock restored =
          parseMangaJson(serialized).images.single.blocks.single;
      expect(restored.linesCoords, isNotNull);
      expect(restored.linesCoords!.single.length, 4);
      expect(restored.linesCoords!.single[2], <double>[50, 50]);
    });

    test('empty / malformed manga.json is empty payload', () {
      expect(parseMangaJson('{}').images, isEmpty);
      expect(parseMangaJson('[]').images, isEmpty);
    });

    test('round-trips optional OCR metadata and UTF-16 regions', () {
      const MokuroPayload source = MokuroPayload(
        ocr: MangaOcrMetadata(
          engine: 'google_lens',
          engineSignature: 'google-lens-v1-ja',
          schemaVersion: 1,
        ),
        images: <MokuroImage>[
          MokuroImage(
            url: 'images/p1.png',
            size: Size(100, 200),
            blocks: <MokuroBlock>[
              MokuroBlock(
                rectangle: Rect.fromLTWH(10, 20, 30, 40),
                isVertical: false,
                fontSize: 12,
                zIndex: 0,
                lines: <String>['日本'],
                regions: <MangaOcrTextRegion>[
                  MangaOcrTextRegion(
                    rectangle: Rect.fromLTWH(10, 20, 15, 40),
                    utf16Start: 0,
                    utf16End: 1,
                  ),
                ],
              ),
            ],
          ),
        ],
      );
      final MokuroPayload parsed =
          parseMangaJson(jsonEncode(mangaPayloadToJson(source)));
      expect(parsed.ocr?.engine, 'google_lens');
      expect(parsed.ocr?.engineSignature, 'google-lens-v1-ja');
      final MangaOcrTextRegion region =
          parsed.images.single.blocks.single.regions!.single;
      expect(region.rectangle, const Rect.fromLTWH(10, 20, 15, 40));
      expect(region.utf16Start, 0);
      expect(region.utf16End, 1);
    });
  });

  group('normalizeMangaUrl', () {
    test('converts back-slashes and strips leading slash', () {
      expect(normalizeMangaUrl(r'vol1\p001.jpg'), 'vol1/p001.jpg');
      expect(normalizeMangaUrl('/vol1/p001.jpg'), 'vol1/p001.jpg');
      expect(normalizeMangaUrl('vol1/p001.jpg'), 'vol1/p001.jpg');
    });
  });
}
