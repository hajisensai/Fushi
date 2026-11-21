import 'dart:typed_data';

import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:fushi_engine/ocr/manga_ai_ocr_refiner.dart';
import 'package:fushi_engine/ocr/ocr_types.dart';
import 'package:image/image.dart' as img;
import 'package:test/test.dart';

import '../media/image_kernels/synthetic_images.dart';

/// 视频暂停 OCR 的大模型重读从播放器截帧的 RGBA 直接裁块（[cropMangaAiOcrBlocksRgba]，
/// 原生 `ffc_image_ai_crops_rgba`），不再把整帧编 PNG 再解码。裁出来的块必须与「编 PNG →
/// [cropMangaAiOcrBlocks]」逐像素相同：送给大模型的图不因省掉编码而变。

/// 同一张图的 RGBA（alpha 255）。
OcrRgbaImage _rgbaOf(img.Image rgb) {
  final img.Image rgba = rgb.convert(numChannels: 4, alpha: 255);
  return OcrRgbaImage(
    rgba: rgba.getBytes(order: img.ChannelOrder.rgba),
    width: rgba.width,
    height: rgba.height,
  );
}

/// 裁块解码成 RGB 像素（比的是像素，不是 PNG 压缩流）。
List<Uint8List?> _pixels(List<Uint8List?> crops) => <Uint8List?>[
  for (final Uint8List? crop in crops)
    crop == null
        ? null
        : img
              .decodePng(crop)!
              .convert(numChannels: 3)
              .getBytes(order: img.ChannelOrder.rgb),
];

void main() {
  const List<MokuroRect> boxes = <MokuroRect>[
    MokuroRect.fromLTRB(100, 120, 400, 900), // 普通块
    MokuroRect.fromLTRB(10, 10, 30, 50), // 短边不足：立方放大
    MokuroRect.fromLTRB(0, 0, 1300, 1800), // 长边超限：均值缩小
    MokuroRect.fromLTRB(-50, -50, 5, 5), // 贴边外扩
    MokuroRect.fromLTRB(2000, 2000, 2100, 2100), // 图外
    MokuroRect.fromLTRB(40, 700, 1290, 760), // 宽扁
  ];

  for (final (double pw, double ph) in <(double, double)>[
    (1300, 1800),
    (650, 900),
    (0, 0),
  ]) {
    test('RGBA 直接裁块与编 PNG 后裁块逐像素相同（页坐标 ${pw}x$ph）', () {
      final img.Image page = synthImage(1300, 1800, 3, 17);
      final List<Uint8List?> viaPng = cropMangaAiOcrBlocks(
        img.encodePng(page),
        pageWidth: pw,
        pageHeight: ph,
        boxes: boxes,
      );
      final List<Uint8List?> viaRgba = cropMangaAiOcrBlocksRgba(
        _rgbaOf(page),
        pageWidth: pw,
        pageHeight: ph,
        boxes: boxes,
      );
      expect(viaRgba.length, boxes.length);
      expect(viaRgba.map((Uint8List? c) => c == null), <bool>[
        for (final Uint8List? c in viaPng) c == null,
      ]);
      expect(_pixels(viaRgba), _pixels(viaPng));
      for (final Uint8List? crop in viaRgba) {
        if (crop == null) continue;
        expect(img.decodePng(crop)!.numChannels, 3, reason: '不透明帧裁成 RGB PNG');
      }
    });
  }

  test('坐标非有限照旧抛 UnsupportedError', () {
    expect(
      () => cropMangaAiOcrBlocksRgba(
        _rgbaOf(synthImage(60, 40, 3, 83)),
        pageWidth: 60,
        pageHeight: 40,
        boxes: const <MokuroRect>[MokuroRect.fromLTRB(double.nan, 0, 10, 10)],
      ),
      throwsUnsupportedError,
    );
  });

  test('OcrRgbaImage 拒收长度对不上的像素', () {
    expect(
      () => OcrRgbaImage(rgba: Uint8List(10), width: 2, height: 2),
      throwsArgumentError,
    );
  });
}
