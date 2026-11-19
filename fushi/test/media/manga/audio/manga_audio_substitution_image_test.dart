import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:fushi/src/media/manga/audio/manga_audio_substitution_image.dart';
import 'package:fushi_compute/fushi_compute.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/tts/cast/cast_text_substitution.dart';

const List<CastTextSubstitution> _table = <CastTextSubstitution>[
  CastTextSubstitution(source: 'セーラー服', replacement: '制服'),
  CastTextSubstitution(source: '服', replacement: 'ふく'),
  CastTextSubstitution(source: 'keep', replacement: 'changed', enabled: false),
];

MokuroBlock _block(
  MokuroRect rect,
  List<String> text, {
  bool vertical = false,
}) => MokuroBlock(
  rectangle: rect,
  isVertical: vertical,
  fontSize: 26,
  zIndex: 0,
  lines: text,
);

MokuroImage _page() => MokuroImage(
  url: 'p.png',
  size: const MokuroSize(600, 400),
  blocks: <MokuroBlock>[
    _block(const MokuroRect.fromLTRB(40, 40, 280, 100), <String>['セーラー', '服']),
    _block(const MokuroRect.fromLTRB(400, 40, 480, 320), <String>[
      'セーラー服の少女',
    ], vertical: true),
    _block(const MokuroRect.fromLTRB(40, 220, 180, 280), <String>['keep']),
  ],
);

int _offset(int x, int y) => (y * 300 + x) * 4;

Future<Uint8List> _source() async {
  final ui.PictureRecorder recorder = ui.PictureRecorder();
  final ui.Canvas canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xff5588bb), ui.BlendMode.src);
  // 两个原字块；保留一处角落墨迹，测试替换时连旧字边缘也完全覆盖。
  final ui.Paint white = ui.Paint()..color = const ui.Color(0xffffffff);
  canvas.drawRect(const ui.Rect.fromLTRB(20, 20, 140, 50), white);
  canvas.drawRect(const ui.Rect.fromLTRB(200, 20, 240, 160), white);
  void paintText(String text, double x, double y) {
    final ui.Paragraph paragraph =
        (ui.ParagraphBuilder(
                ui.ParagraphStyle(
                  textDirection: ui.TextDirection.ltr,
                  fontFamily: 'Yu Gothic',
                  fontSize: 14,
                ),
              )
              ..pushStyle(ui.TextStyle(color: const ui.Color(0xff000000)))
              ..addText(text))
            .build()
          ..layout(const ui.ParagraphConstraints(width: 120));
    canvas.drawParagraph(paragraph, ui.Offset(x, y));
    paragraph.dispose();
  }

  paintText('セーラー服', 28, 25);
  final List<String> vertical = 'セーラー服の少女'.split('');
  for (int i = 0; i < vertical.length; i++) {
    paintText(vertical[i], 212, 23 + i * 16);
  }
  canvas.drawRect(
    const ui.Rect.fromLTRB(20, 20, 23, 23),
    ui.Paint()..color = const ui.Color(0xff000000),
  );
  final ui.Picture picture = recorder.endRecording();
  try {
    final ui.Image image = await picture.toImage(300, 200);
    try {
      final ByteData png = (await image.toByteData(
        format: ui.ImageByteFormat.png,
      ))!;
      return png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final String? font = Platform.environment['FUSHI_SUBSTITUTION_TEST_FONT'];
    if (font != null) {
      final FontLoader loader = FontLoader('Yu Gothic')
        ..addFont(
          File(font).readAsBytes().then(
            (Uint8List bytes) => ByteData.sublistView(bytes),
          ),
        );
      await loader.load();
    }
  });

  test('跨行词命中，停用规则不生效；横竖排遮盖与坐标缩放正确', () async {
    final MokuroImage page = _page();
    expect(mangaPageHasSubstitutions(page, _table), isTrue);
    final Uint8List overlay = (await renderMangaSubstitutionOverlay(
      page: page,
      width: 300,
      height: 200,
      substitutions: _table,
    ))!;
    expect(overlay.length, 300 * 200 * 4);
    expect(overlay.sublist(_offset(0, 0), _offset(0, 0) + 4), <int>[
      0,
      0,
      0,
      0,
    ]);
    expect(overlay[_offset(50, 125) + 3], 0); // 停用的 keep 块不重绘。
    for (final ({int left, int top, int right, int bottom}) box
        in <({int left, int top, int right, int bottom})>[
          (left: 20, top: 20, right: 140, bottom: 50),
          (left: 200, top: 20, right: 240, bottom: 160),
        ]) {
      int black = 0;
      int white = 0;
      for (int y = box.top; y < box.bottom; y++) {
        for (int x = box.left; x < box.right; x++) {
          final int i = _offset(x, y);
          expect(overlay[i + 3], 255); // 旧字所在区域完全不透明。
          if (overlay[i] < 64) black++;
          if (overlay[i] > 240) white++;
        }
      }
      expect(black, greaterThan(0)); // 替换后的字实际画进了像素。
      expect(white, greaterThan(0));
    }
    expect(page.blocks.first.lines, <String>['セーラー', '服']);
  });

  test('上传 JPEG 真正覆盖旧字，未命中区域不改，源字节不变', () async {
    final Uint8List source = await _source();
    final Uint8List original = Uint8List.fromList(source);
    final Uint8List jpeg = (await prepareMangaSubstitutionImage(
      bytes: source,
      page: _page(),
      substitutions: _table,
      quality: 100,
    ))!;
    final FfcDecodedImage decoded = FushiComputeImage.instance.decode(jpeg)!;
    expect((decoded.width, decoded.height), (300, 200));
    const int outside = (180 * 300 + 280) * 3;
    for (int c = 0; c < 3; c++) {
      expect(decoded.pixels[outside + c], closeTo(<int>[85, 136, 187][c], 3));
    }
    const int erased = (21 * 300 + 21) * 3;
    expect(decoded.pixels[erased], greaterThan(245));
    expect(source, orderedEquals(original));
    final String? evidence =
        Platform.environment['FUSHI_SUBSTITUTION_EVIDENCE_DIR'];
    if (evidence != null) {
      final Directory dir = Directory(evidence)..createSync(recursive: true);
      await File('${dir.path}/source.png').writeAsBytes(source);
      await File('${dir.path}/upload.jpg').writeAsBytes(jpeg);
    }
  });

  test('斜排多边形与字格超出块框的原字也覆盖', () async {
    final MokuroImage page = MokuroImage(
      url: 'p.png',
      size: const MokuroSize(600, 400),
      blocks: <MokuroBlock>[
        MokuroBlock(
          rectangle: const MokuroRect.fromLTRB(40, 40, 100, 100),
          isVertical: false,
          fontSize: 20,
          zIndex: 0,
          lines: <String>['セーラー服'],
          linesCoords: <List<List<double>>>[
            <List<double>>[
              <double>[30, 30],
              <double>[120, 30],
              <double>[120, 110],
              <double>[30, 110],
            ],
          ],
          regions: const <MangaOcrTextRegion>[
            MangaOcrTextRegion(
              rectangle: MokuroRect.fromLTRB(120, 30, 140, 110),
              utf16Start: 0,
              utf16End: 1,
            ),
          ],
        ),
      ],
    );
    final Uint8List overlay = (await renderMangaSubstitutionOverlay(
      page: page,
      width: 300,
      height: 200,
      substitutions: const <CastTextSubstitution>[
        CastTextSubstitution(source: 'セーラー服', replacement: ''),
      ],
    ))!;
    expect(overlay[_offset(16, 16) + 3], 255);
    expect(overlay[_offset(69, 54) + 3], 255);
    expect(overlay[_offset(80, 60) + 3], 0);
  });

  test('替换为空时只有白底；无规则与坏坐标不回传原图', () async {
    final MokuroImage page = MokuroImage(
      url: 'p.png',
      size: const MokuroSize(600, 400),
      blocks: <MokuroBlock>[_page().blocks.first],
    );
    final Uint8List overlay = (await renderMangaSubstitutionOverlay(
      page: page,
      width: 300,
      height: 200,
      substitutions: const <CastTextSubstitution>[
        CastTextSubstitution(source: 'セーラー服', replacement: ''),
      ],
    ))!;
    for (int y = 20; y < 50; y++) {
      for (int x = 20; x < 140; x++) {
        expect(overlay.sublist(_offset(x, y), _offset(x, y) + 4), <int>[
          255,
          255,
          255,
          255,
        ]);
      }
    }
    expect(
      mangaPageHasSubstitutions(page, const <CastTextSubstitution>[]),
      isFalse,
    );
    expect(
      await renderMangaSubstitutionOverlay(
        page: page,
        width: 300,
        height: 200,
        substitutions: const <CastTextSubstitution>[],
      ),
      isNull,
    );
    final MokuroImage invalid = MokuroImage(
      url: 'p.png',
      size: const MokuroSize(600, 400),
      blocks: <MokuroBlock>[
        _block(const MokuroRect.fromLTRB(0, 0, 0, 0), <String>['セーラー服']),
      ],
    );
    expect(
      await prepareMangaSubstitutionImage(
        bytes: await _source(),
        page: invalid,
        substitutions: _table,
      ),
      isNull,
    );
  });
}
